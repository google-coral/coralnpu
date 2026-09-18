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
import sys
import time

from elftools.elf.elffile import ELFFile
from bazel_tools.tools.python.runfiles import runfiles
try:
    from coralnpu_hw.coralnpu_test_utils.run_binary import BinaryRunner
except ImportError:
    from coralnpu_test_utils.run_binary import BinaryRunner
from fpga.sw.flash_tool_lib import FlashTool


def get_symbol_addr(elf, name):
    symtab = elf.get_section_by_name(".symtab")
    if not symtab:
        raise ValueError("No symbol table found in ELF.")
    syms = symtab.get_symbol_by_name(name)
    if not syms:
        raise ValueError(f"Symbol '{name}' not found.")
    return syms[0].entry["st_value"]


def main():
    parser = argparse.ArgumentParser(
        description="Flash tool for FPGA via FTDI (Nexus Loader version)."
    )
    parser.add_argument(
        "--usb-serial",
        required=True,
        help="USB serial number of the FTDI device."
    )
    parser.add_argument(
        "--ftdi-port",
        type=int,
        default=1,
        help="Port number of the FTDI device."
    )
    parser.add_argument("image", help="Path to the binary image to program.")
    args = parser.parse_args()

    logging.basicConfig(
        level=logging.INFO, format="%(levelname)s: %(message)s"
    )

    if not os.path.exists(args.image):
        logging.error(f"HOST: Error: Image file '{args.image}' not found.")
        sys.exit(1)

    r = runfiles.Create()
    elf_path = r.Rlocation("coralnpu_hw/fpga/flash_tool.elf")
    if not elf_path or not os.path.exists(elf_path):
        elf_path = r.Rlocation("com_google_coralnpu_hw/fpga/flash_tool.elf")
        if not elf_path or not os.path.exists(elf_path):
            raise FileNotFoundError(
                f"Could not find flash_tool.elf in runfiles"
            )

    csr_base_addr = 0x200000  # Required highmem

    logging.info(
        f"HOST: Loading and starting flash_tool.elf via BinaryRunner..."
    )
    runner = BinaryRunner(
        elf_path,
        args.usb_serial,
        args.ftdi_port,
        csr_base_addr,
        exit_after_start=True
    )
    runner.run_binary()

    driver = runner.spi_master

    try:
        symbols = {}
        with open(elf_path, "rb") as f:
            elf = ELFFile(f)
            symbols["ready"] = get_symbol_addr(elf, "flash_tool_ready")
            symbols["cmd"] = get_symbol_addr(elf, "flash_tool_cmd")
            symbols["resp"] = get_symbol_addr(elf, "flash_tool_resp")
            symbols["buffer"] = get_symbol_addr(elf, "flash_tool_buffer")
            logging.info(f"HOST: Symbols: {symbols}")

        tool = FlashTool(driver, symbols)
        tool.wait_for_ready()
        tool.hello()
        tool.get_info()

        with open(args.image, "rb") as f:
            image_data = f.read()

        image_size = len(image_data)
        logging.info(f"HOST: Image size: {image_size} bytes")

        if image_size > tool.capacity:
            logging.error(
                f"HOST: Error: Image size ({image_size}) exceeds flash capacity ({tool.capacity})."
            )
            sys.exit(1)

        start_time = time.time()
        tool.program_data(0, image_data)
        duration = time.time() - start_time

        rate = (image_size / 1024.0) / duration if duration > 0 else 0
        logging.info(
            f"HOST: Programmed {image_size} bytes in {duration:.2f} seconds ({rate:.2f} KB/s)."
        )
        logging.info("HOST: Flash programming completed successfully.")

    except Exception as e:
        logging.error(f"HOST: Error: {e}")
        sys.exit(1)
    finally:
        driver.close()


if __name__ == "__main__":
    main()
