#!/usr/bin/env python3
# Copyright 2026 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

import argparse
import logging
import os
import signal
import socket
import subprocess
import sys
import threading
import time

from elftools.elf.elffile import ELFFile
from bazel_tools.tools.python.runfiles import runfiles
try:
    from coralnpu_hw.utils.coralnpu_soc_loader.spi_driver import SPIDriver
except ImportError:
    try:
        from utils.coralnpu_soc_loader.spi_driver import SPIDriver
    except ImportError:
        from spi_driver import SPIDriver
from fpga.sw.flash_tool_lib import FlashTool


def find_free_port():
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("", 0))
        return s.getsockname()[1]


def get_symbol_addr(elf, name):
    symtab = elf.get_section_by_name(".symtab")
    if not symtab:
        raise ValueError("No symbol table found in ELF.")
    syms = symtab.get_symbol_by_name(name)
    if not syms:
        raise ValueError(f"Symbol '{name}' not found.")
    return syms[0].entry["st_value"]


def stream_reader(pipe, prefix, ready_event=None, ready_line=None):
    try:
        for line in iter(pipe.readline, ""):
            logging.info(f"[{prefix}] {line.strip()}")
            if ready_event and ready_line and ready_line in line:
                ready_event.set()
    finally:
        pipe.close()


def tail_uart(deadline):
    try:
        path = "uart1.log"
        while time.time() < deadline and not os.path.exists(path):
            time.sleep(0.1)
        if not os.path.exists(path):
            logging.warning("HOST: uart1.log not found")
            return
        logging.info(f"HOST: Tailing {path}")
        with open(path, "r") as f:
            while time.time() < deadline:
                line = f.readline()
                if not line:
                    time.sleep(0.05)
                    continue
                logging.info(f"[UART] {line.strip()}")
    except Exception as e:
        logging.error(f"HOST: Error tailing UART: {e}")


def write_word(driver, addr, val):
    line_addr = (addr // 16) * 16
    offset = addr % 16
    line_data = int.from_bytes(bytes(driver.v2_read(line_addr, 1)), "little")
    mask = 0xFFFFFFFF << (offset * 8)
    new_line = (line_data & ~mask) | ((val & 0xFFFFFFFF) << (offset * 8))
    driver.v2_write(line_addr, new_line.to_bytes(16, "little"))


def main():
    parser = argparse.ArgumentParser(
        description="Host tool for flash tool simulation."
    )
    parser.add_argument("elf", help="Path to the flash_tool ELF binary.")
    parser.add_argument("--itcm_size_kbytes", type=int, default=1024)
    parser.add_argument("--dtcm_size_kbytes", type=int, default=1024)
    parser.add_argument("--sim_timeout", type=int, default=120)
    args = parser.parse_args()

    logging.basicConfig(
        level=logging.INFO, format="%(levelname)s: %(message)s"
    )

    r = runfiles.Create()
    sim_bin_path = r.Rlocation("coralnpu_hw/fpga/Vchip_verilator_highmem")
    if not sim_bin_path or not os.path.exists(sim_bin_path):
        sim_bin_path = r.Rlocation(
            "coralnpu_hw/fpga/build_chip_verilator_highmem/com.google.coralnpu_fpga_chip_verilator_0.1/sim-verilator/Vchip_verilator"
        )
        if not sim_bin_path or not os.path.exists(sim_bin_path):
            raise FileNotFoundError(
                "Could not find simulator binary in runfiles."
            )

    port = find_free_port()
    sim_env = os.environ.copy()
    sim_env["SPI_DPI_PORT"] = str(port)

    sim_proc = None
    threads = []
    try:
        logging.info(f"HOST: Starting simulator on port {port}")
        sim_proc = subprocess.Popen(
            [sim_bin_path, "--trace=/tmp/trace.fst"],
            env=sim_env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )

        sim_ready = threading.Event()
        threads.append(
            threading.Thread(
                target=stream_reader,
                args=(
                    sim_proc.stdout,
                    "SIM",
                    sim_ready,
                    f"DPI: Server listening on port {port}",
                ),
            )
        )
        threads.append(
            threading.Thread(
                target=stream_reader, args=(sim_proc.stderr, "SIM_ERR")
            )
        )

        uart_deadline = time.time() + args.sim_timeout + 60
        threads.append(
            threading.Thread(target=tail_uart, args=(uart_deadline, ))
        )

        for t in threads:
            t.daemon = True
            t.start()

        if not sim_ready.wait(timeout=60):
            raise RuntimeError("Timeout waiting for simulator ready.")
        logging.info("HOST: Simulator ready.")

        driver = SPIDriver(port=port)

        with open(args.elf, "rb") as f:
            elf = ELFFile(f)
            entry_point = elf.header.e_entry
            symbols = {
                "ready": get_symbol_addr(elf, "flash_tool_ready"),
                "cmd": get_symbol_addr(elf, "flash_tool_cmd"),
                "resp": get_symbol_addr(elf, "flash_tool_resp"),
                "buffer": get_symbol_addr(elf, "flash_tool_buffer"),
            }
            logging.info(f"HOST: Symbols: {symbols}")

            for segment in elf.iter_segments(type="PT_LOAD"):
                paddr = segment.header.p_paddr
                data = segment.data()
                if not data:
                    continue
                if len(data) % 16 != 0:
                    data += b"\x00" * (16 - (len(data) % 16))
                driver.v2_write(paddr, data)

        tool = FlashTool(driver, symbols)

        csr_base = (args.itcm_size_kbytes + args.dtcm_size_kbytes) * 1024
        write_word(driver, csr_base + 4, entry_point)  # PC
        write_word(driver, csr_base, 1)  # Release clock gate
        write_word(driver, csr_base, 0)  # Release reset
        logging.info("HOST: Core started.")

        tool.wait_for_ready()
        tool.hello()
        tool.get_info()

        logging.info("HOST: Flash tool test completed successfully.")
        print("PASS")
        return 0

    except Exception as e:
        logging.error(f"HOST: Error: {e}")
        return 1
    finally:
        if sim_proc:
            sim_proc.send_signal(signal.SIGINT)
            try:
                sim_proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                sim_proc.kill()
        for t in threads:
            t.join(timeout=1)
        logging.info("HOST: Shutdown complete.")


if __name__ == "__main__":
    sys.exit(main())
