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
"""Loads and runs an arbitrary ELF binary on CoralNPU FPGA Hardware."""

import argparse
import logging
import os
import sys

# To support execution without Bazel runfiles:
_script_dir = os.path.dirname(os.path.abspath(__file__))
_project_root = os.path.dirname(_script_dir)
if _project_root not in sys.path:
    sys.path.insert(0, _project_root)

from coralnpu_test_utils.fpga_test_fixture import FpgaTestFixture

logger = logging.getLogger(__name__)


def main():
    parser = argparse.ArgumentParser(
        description="Load and run a binary on CoralNPU FPGA Hardware."
    )
    parser.add_argument("elf_file", help="Path to the ELF file to run.")
    parser.add_argument(
        "--usb-serial",
        required=True,
        help="USB serial number of the FTDI device (e.g. Nexus-FTDI-12).",
    )
    parser.add_argument(
        "--ftdi-port",
        type=int,
        default=1,
        help="Port number of the FTDI device.",
    )
    parser.add_argument(
        "--csr-base-addr",
        type=lambda x: int(x, 0),
        default=None,
        help=
        "Base address for CSR registers (defaults to 0x200000 for highmem, 0x30000 for lowmem).",
    )
    parser.add_argument(
        "--highmem",
        action="store_true",
        help="Use high memory (0x200000) for CSR base address.",
    )
    parser.add_argument(
        "--verify",
        action="store_true",
        help="Verify the ELF load by reading back memory.",
    )
    parser.add_argument(
        "--exit-after-start",
        action="store_true",
        help="Exit immediately after starting the core.",
    )
    parser.add_argument(
        "--verbose",
        action="store_true",
        help="Enable verbose logging.",
    )
    parser.add_argument(
        "--reset",
        action="store_true",
        help=
        "Perform hardware reset (toggle PROG_B) before loading (will wipe DDR).",
    )
    args = parser.parse_args()

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s - %(name)s - %(levelname)s - %(message)s",
    )

    try:
        fixture = FpgaTestFixture.create(
            usb_serial=args.usb_serial,
            highmem=args.highmem,
            ftdi_port=args.ftdi_port,
            csr_base_addr=args.csr_base_addr,
            auto_recovery=True,
        )

        if args.reset:
            logger.info(
                "Performing requested hardware reset (toggle PROG_B)..."
            )
            fixture.reset_hardware(hard_reset=True)

        logger.info(f"Loading ELF file: {args.elf_file}")
        fixture.load_elf_and_lookup_symbols(
            args.elf_file,
            symbols=[],
            optional_symbols=[
                "cycle_count",
                "cycle_count_lo",
                "cycle_count_hi",
                "csr_cycle_count",
            ],
            verify=args.verify,
        )

        if args.exit_after_start:
            logger.info("Starting core execution and exiting immediately...")
            fixture.spi_master.set_entry_point(fixture.entry_point)
            fixture.spi_master.start_core()
            logger.info("Exiting after start as requested.")
            return

        logger.info("Starting core and polling for halt (timeout 60.0s)...")
        if not fixture.run_to_halt(timeout_sec=60.0):
            raise RuntimeError(
                "Binary execution FAILED: Core did not halt within timeout."
            )

        logger.info("Binary execution COMPLETED: Core halted successfully.")

        cycles = fixture.get_cycle_count()
        if cycles is not None:
            logger.info(f"Execution Cycles: {cycles}")

    except Exception as e:
        logger.error(f"Error: {e}")
        import traceback
        traceback.print_exc()
        sys.exit(1)


if __name__ == "__main__":
    main()
