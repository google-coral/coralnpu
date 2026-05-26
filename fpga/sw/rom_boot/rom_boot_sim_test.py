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
from bazel_tools.tools.python.runfiles import runfiles

def find_free_port():
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("", 0))
        return s.getsockname()[1]

def stream_reader(pipe, prefix, ready_event=None, ready_line=None, failure_event=None, failure_line=None):
    try:
        for line in iter(pipe.readline, ""):
            logging.info(f"[{prefix}] {line.strip()}")
            if ready_event and ready_line and ready_line in line:
                ready_event.set()
            if failure_event and failure_line and failure_line in line:
                logging.error(f"[{prefix}] DETECTED FAILURE: {line.strip()}")
                failure_event.set()
    finally:
        pipe.close()

def tail_uart(path, expected_string, deadline, failure_event=None):
    logging.info(f"HOST: Waiting for {path}...")
    while time.time() < deadline and not os.path.exists(path):
        if failure_event and failure_event.is_set():
            logging.error("HOST: Aborting tail_uart due to failure event")
            return False
        os.makedirs(os.path.dirname(path) if os.path.dirname(path) else '.', exist_ok=True)
        time.sleep(0.1)
    
    if not os.path.exists(path):
        logging.error(f"HOST: {path} not found")
        return False

    logging.info(f"HOST: Tailing {path}")
    with open(path, "r") as f:
        while time.time() < deadline:
            if failure_event and failure_event.is_set():
                logging.error("HOST: Aborting tail_uart due to failure event")
                return False
            line = f.readline()
            if not line:
                time.sleep(0.1)
                continue
            logging.info(f"[UART] {line.strip()}")
            if expected_string in line:
                logging.info(f"HOST: Found expected string: {expected_string}")
                return True
    return False

def main():
    parser = argparse.ArgumentParser(description="ROM boot simulation test.")
    parser.add_argument("--sim_timeout", type=int, default=240)
    parser.add_argument("--sim_binary", type=str, help="Path to simulator binary (Rlocation)")
    parser.add_argument("--rom_vmem", type=str, help="Path to ROM vmem image (Rlocation)")
    parser.add_argument("--flash_image", type=str, default="coralnpu_hw/fpga/flash_boot.bin", help="Path to flash image (Rlocation)")
    args = parser.parse_args()

    logging.basicConfig(level=logging.INFO, format="%(levelname)s: %(message)s")

    r = runfiles.Create()
    # Path to the ROM-based simulator binary
    if args.sim_binary:
        sim_bin_path = r.Rlocation(args.sim_binary)
    else:
        sim_bin_path = r.Rlocation("coralnpu_hw/fpga/Vchip_verilator_rom")

    if not sim_bin_path or not os.path.exists(sim_bin_path):
        if not args.sim_binary:
            sim_bin_path = r.Rlocation("coralnpu_hw/fpga/build_chip_verilator_rom/com.google.coralnpu_fpga_chip_verilator_0.1/sim-verilator/Vchip_verilator")
        
        if not sim_bin_path or not os.path.exists(sim_bin_path):
            raise FileNotFoundError(f"Could not find simulator binary in runfiles: {sim_bin_path}")

    rom_vmem_path = None
    if args.rom_vmem:
        rom_vmem_path = r.Rlocation(args.rom_vmem)
        if not rom_vmem_path or not os.path.exists(rom_vmem_path):
            raise FileNotFoundError(f"Could not find ROM vmem image in runfiles: {args.rom_vmem}")

    flash_bin_path = r.Rlocation(args.flash_image)
    if not flash_bin_path or not os.path.exists(flash_bin_path):
        raise FileNotFoundError(f"Could not find flash image in runfiles: {args.flash_image}")

    # Remove old uart log if exists to avoid false positives
    if os.path.exists("uart1.log"):
        os.remove("uart1.log")

    port = find_free_port()
    jtag_port = find_free_port()
    sim_env = os.environ.copy()
    sim_env["SPI_DPI_PORT"] = str(port)
    sim_env["FLASH_INIT_FILE"] = flash_bin_path

    sim_proc = None
    threads = []
    try:
        logging.info(f"HOST: Starting simulator on SPI port {port}, JTAG port {jtag_port}: {sim_bin_path}")
        logging.info(f"HOST: Using flash image: {flash_bin_path}")
        sim_cmd = [sim_bin_path, "+UARTDPI_LOG_uart1=uart1.log", f"+jtagdpi_port={jtag_port}"]
        if rom_vmem_path:
            sim_cmd.append(f"--meminit=rom,{rom_vmem_path}")

        sim_proc = subprocess.Popen(
            sim_cmd,
            env=sim_env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            preexec_fn=os.setsid
        )

        sim_ready = threading.Event()
        sim_failure = threading.Event()
        threads.append(threading.Thread(target=stream_reader, 
                                        args=(sim_proc.stdout, "SIM", sim_ready, f"DPI: Server listening on port {port}", sim_failure, "$readmem file not found")))
        threads.append(threading.Thread(target=stream_reader, args=(sim_proc.stderr, "SIM_ERR", None, None, sim_failure, "$readmem file not found")))

        for t in threads:
            t.daemon = True
            t.start()

        # Wait for either ready or failure
        while not sim_ready.is_set() and not sim_failure.is_set():
            if sim_proc.poll() is not None:
                logging.error("HOST: Simulator process exited unexpectedly")
                return 1
            time.sleep(0.1)

        if sim_failure.is_set():
            logging.error("HOST: Simulator reported failure during startup")
            return 1

        if not sim_ready.is_set():
            raise RuntimeError("Timeout waiting for simulator ready.")
        logging.info("HOST: Simulator ready. Core should release automatically via autoboot.")

        deadline = time.time() + args.sim_timeout
        # Look for loader progress (J = Jump to entry)
        success = tail_uart("uart1.log", "J", deadline, failure_event=sim_failure)
        if success:
             # If loader reached jump, wait for actual PASS from payload
             success = tail_uart("uart1.log", "PASS", deadline, failure_event=sim_failure)

        if success:
            logging.info("HOST: ROM boot test PASSED")
            print("PASS")
            return 0
        else:
            logging.error("HOST: ROM boot test FAILED (timeout or message not found)")
            return 1

    except Exception as e:
        logging.error(f"HOST: Error during simulation: {e}")
        return 1
    finally:
        if sim_proc:
            logging.info("HOST: Terminating simulator...")
            try:
                os.killpg(os.getpgid(sim_proc.pid), signal.SIGINT)
                sim_proc.wait(timeout=5)
            except Exception:
                try:
                    os.killpg(os.getpgid(sim_proc.pid), signal.SIGKILL)
                except Exception:
                    pass
        logging.info("HOST: Shutdown complete.")

if __name__ == "__main__":
    sys.exit(main())
