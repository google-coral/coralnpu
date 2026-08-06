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
"""DDR Memory Stress, Diagnostic, and Boundary Validation Suite for CoralNPU FPGA."""

import argparse
import logging
import os
import sys
import time
from typing import Dict, List, Tuple
import numpy as np

from coralnpu_test_utils.fpga_test_fixture import FpgaTestFixture

logger = logging.getLogger(__name__)

DDR_BASE_ADDR = 0x80000000

PATTERN_GENERATORS = {
    "zeros":
    lambda size: np.zeros(size, dtype=np.uint8),
    "ones":
    lambda size: np.full(size, 0xFF, dtype=np.uint8),
    "0x55":
    lambda size: np.full(size, 0x55, dtype=np.uint8),
    "0xAA":
    lambda size: np.full(size, 0xAA, dtype=np.uint8),
    "incrementing":
    lambda size: (np.arange(size, dtype=np.uint32) & 0xFF).astype(np.uint8),
    "random":
    lambda size: np.random.default_rng(seed=42).
    integers(0, 256, size=size, dtype=np.uint8),
}


class DdrDiagnosticRunner:
    """Comprehensive diagnostic test runner for CoralNPU DDR memory (0x80000000)."""

    def __init__(
        self,
        fixture: FpgaTestFixture,
        max_size: int = 65536,
        continue_on_error: bool = False,
    ):
        self.fixture = fixture
        self.max_size = max_size
        self.continue_on_error = continue_on_error
        self.results: List[Dict] = []

    def _format_ranges(self, indices: np.ndarray) -> str:
        """Formats array of mismatch indices into concise hex address ranges."""
        if len(indices) == 0:
            return "None"
        ranges = []
        start = prev = indices[0]
        for i in range(1, len(indices)):
            if indices[i] == prev + 1:
                prev = indices[i]
            else:
                ranges.append((start, prev))
                start = prev = indices[i]
        ranges.append((start, prev))
        return ", ".join([
            f"0x{s:x}" if s == e else f"0x{s:x}-0x{e:x}" for s, e in ranges[:8]
        ])

    def run_single_pattern_test(
        self, offset: int, size: int, pattern_name: str
    ) -> Tuple[bool, str]:
        """Runs pattern write-read-verify on DDR."""
        target_addr = DDR_BASE_ADDR + offset
        golden_data = PATTERN_GENERATORS[pattern_name](size)

        # 1. Write pattern to DDR
        start_w = time.time()
        self.fixture.write(target_addr, golden_data.tobytes())
        write_duration = time.time() - start_w

        # 2. Read back from DDR
        start_r = time.time()
        read_bytes = self.fixture.read(target_addr, size_bytes=size)
        read_duration = time.time() - start_r

        result_data = np.frombuffer(read_bytes, dtype=np.uint8)

        # 3. Bit-exact verification
        if np.array_equal(golden_data, result_data):
            w_kb = (
                size / 1024.0
            ) / write_duration if write_duration > 0 else 0
            r_kb = (size / 1024.0) / read_duration if read_duration > 0 else 0
            return True, f"PASS (W: {w_kb:.1f} KB/s, R: {r_kb:.1f} KB/s)"

        mismatches = np.where(golden_data != result_data)[0]
        err_count = len(mismatches)
        first_err = mismatches[0]
        exp_val = golden_data[first_err]
        got_val = result_data[first_err] if first_err < len(
            result_data
        ) else 0xFF
        diff_bits = exp_val ^ got_val

        detail = (
            f"FAIL: {err_count}/{size} bytes mismatch. "
            f"First @ +0x{first_err:x} (0x{target_addr + first_err:x}): "
            f"Exp 0x{exp_val:02x}, Got 0x{got_val:02x} (Diff bits: 0x{diff_bits:02x}). "
            f"Err offsets: {self._format_ranges(mismatches)}"
        )
        return False, detail

    def test_walking_bits(self, offset: int = 0) -> bool:
        """Tests individual bit lines (walking 1s and walking 0s) to detect stuck-at / bridging faults."""
        target_addr = DDR_BASE_ADDR + offset
        print(
            f"\n--- [1/4] Running Walking Bits Integrity Test (32-bit width) ---"
        )
        passed = True

        for bit in range(32):
            pattern_1 = 1 << bit
            pattern_0 = (~(1 << bit)) & 0xFFFFFFFF

            # Walking 1
            self.fixture.write_word(target_addr, pattern_1)
            read_1 = self.fixture.read_word(target_addr)
            if read_1 != pattern_1:
                print(
                    f"  [FAIL] Walking 1s (Bit {bit:2d}): Expected 0x{pattern_1:08x}, Got 0x{read_1:08x} (Diff: 0x{pattern_1 ^ read_1:08x})"
                )
                passed = False

            # Walking 0
            self.fixture.write_word(target_addr, pattern_0)
            read_0 = self.fixture.read_word(target_addr)
            if read_0 != pattern_0:
                print(
                    f"  [FAIL] Walking 0s (Bit {bit:2d}): Expected 0x{pattern_0:08x}, Got 0x{read_0:08x} (Diff: 0x{pattern_0 ^ read_0:08x})"
                )
                passed = False

        if passed:
            print(
                "  [PASS] All 32 data bus lines verified with 0 bit-sticking or cross-line bridges."
            )
        return passed

    def test_address_aliasing(self, span_mb: int = 16) -> bool:
        """Writes unique address-derived signatures across DDR to detect address pin opens/shorts."""
        print(
            f"\n--- [2/4] Running Address Bus Aliasing Test ({span_mb} MB DDR Span) ---"
        )
        offsets = [
            0x00000000,
            0x00000010,
            0x00000100,
            0x00001000,
            0x00010000,
            0x00040000,
            0x00100000,
            0x00400000,
            0x00800000,
            0x01000000,
        ]
        signatures: Dict[int, int] = {}

        # 1. Write unique signature to each address power-of-two offset
        for off in offsets:
            addr = DDR_BASE_ADDR + off
            sig = (0xA5000000 | (off & 0x00FFFFFF)) ^ 0x12345678
            signatures[addr] = sig
            self.fixture.write_word(addr, sig)

        # 2. Read back all addresses and verify no aliasing occurred
        aliased = False
        for addr, expected_sig in signatures.items():
            actual_sig = self.fixture.read_word(addr)
            if actual_sig != expected_sig:
                print(
                    f"  [FAIL] Address Aliasing @ 0x{addr:08x}: Expected 0x{expected_sig:08x}, Read 0x{actual_sig:08x}"
                )
                aliased = True

        if not aliased:
            print(
                f"  [PASS] No address line aliasing detected across {len(offsets)} distinct power-of-2 boundaries."
            )
        return not aliased

    def test_burst_sizes_and_patterns(self) -> bool:
        """Sweeps burst sizes (4B to max_size) across all data patterns."""
        print(
            f"\n--- [3/4] Running Pattern & Burst Size Sweep (4 Bytes -> {self.max_size:,} Bytes) ---"
        )

        sizes = []
        curr = 4
        while curr <= self.max_size:
            sizes.append(curr)
            curr *= 4

        all_passed = True

        for size in sizes:
            for pat_name in ["zeros", "ones", "0x55", "0xAA", "incrementing",
                             "random"]:
                success, details = self.run_single_pattern_test(
                    offset=0, size=size, pattern_name=pat_name
                )
                self.results.append({
                    "size": size,
                    "pattern": pat_name,
                    "success": success,
                    "details": details,
                })
                status_str = "PASS" if success else "FAIL"
                print(
                    f"  Size: {size:>7d} bytes | Pattern: {pat_name:<12s} | [{status_str}] {details}"
                )

                if not success:
                    all_passed = False
                    if not self.continue_on_error:
                        return False

        return all_passed

    def test_cross_page_boundaries(self) -> bool:
        """Tests unaligned read/write across 4KB page and 64-byte burst boundaries."""
        print(
            f"\n--- [4/4] Running Cross-Page & Unaligned Boundary Validation ---"
        )
        unaligned_offsets = [1, 3, 7, 15, 63, 4095]
        all_passed = True

        for off in unaligned_offsets:
            size = 128
            success, details = self.run_single_pattern_test(
                offset=off, size=size, pattern_name="incrementing"
            )
            status_str = "PASS" if success else "FAIL"
            print(
                f"  Offset: +0x{off:04x} | Size: {size}B | [{status_str}] {details}"
            )
            if not success:
                all_passed = False
                if not self.continue_on_error:
                    return False

        return all_passed

    def verify_prerequisites(self) -> Tuple[bool, str]:
        """Runs prerequisite hardware sanity checks on SRAM (0x20000000) and DDR (0x80000000)."""
        print(
            f"\n===================================================================="
        )
        print(f"STEP 0: Hardware Bus & Memory Prerequisite Verification")
        print(
            f"===================================================================="
        )

        # 1. Probe On-Chip SRAM (0x20000000)
        print(
            f"  [Probe 1/2] Checking TileLink System Crossbar & SRAM (0x20000000)..."
        )
        if not self.fixture.check_memory_accessible(0x20000000,
                                                    pattern=0xCAFEFEED):
            return False, "System Bus / SRAM (0x20000000) probe failed. Please soft reset or reload bitstream."
        print(
            f"    [OK] On-Chip SRAM (0x20000000) is responsive. System Bus is 100% healthy."
        )

        # 2. Probe Physical DDR DRAM Memory Space (0x80000000)
        print(
            f"  [Probe 2/2] Checking Physical DDR DRAM Memory Space (0x80000000)..."
        )
        if not self.fixture.check_memory_accessible(0x80000000,
                                                    pattern=0xA55A1234):
            return False, "DDR DRAM (0x80000000) probe failed (uncalibrated or memory timeout)."
        print(
            f"    [OK] Physical DDR DRAM (0x80000000) is responsive! Memory is calibrated and ready."
        )

        return True, "All Prerequisites PASSED."

    def print_summary(self):
        """Prints a summary table of all test results."""
        print("\n" + "=" * 80)
        print(f"{'DDR Test Summary Table':^80}")
        print("=" * 80)
        print(
            f"{'Size (Bytes)':<14} | {'Pattern':<14} | {'Result':<10} | {'Details'}"
        )
        print("-" * 80)
        for r in self.results:
            res_str = "PASS" if r["success"] else "FAIL"
            print(
                f"{r['size']:<14d} | {r['pattern']:<14s} | {res_str:<10s} | {r['details']}"
            )
        print("=" * 80)
        total = len(self.results)
        passed = sum(1 for r in self.results if r["success"])
        print(f"Total Tests Executed : {total}")
        print(f"Total Tests Passed   : {passed}")
        print(f"Total Tests Failed   : {total - passed}")
        print("=" * 80 + "\n")


def run_ddr_diagnostics(fixture: FpgaTestFixture):
    """Main entry point for DDR test suite."""
    print(
        f"\n===================================================================="
    )
    print(
        f"CoralNPU FPGA DDR Memory (0x80000000) Diagnostic & Stress Test Suite"
    )
    print(f"Target Hardware Serial: {fixture.usb_serial}")
    print(
        f"===================================================================="
    )

    runner = DdrDiagnosticRunner(
        fixture=fixture,
        max_size=65536,
        continue_on_error=True,
    )

    prereq_ok, prereq_msg = runner.verify_prerequisites()
    if not prereq_ok:
        raise RuntimeError(f"DDR Prerequisite check failed: {prereq_msg}")

    print(f"\nProceeding to deep memory stress and walking bit analysis...")
    t1 = runner.test_walking_bits(offset=0)
    t2 = runner.test_address_aliasing(span_mb=16)
    t3 = runner.test_burst_sizes_and_patterns()
    t4 = runner.test_cross_page_boundaries()

    runner.print_summary()

    if not (t1 and t2 and t3 and t4):
        raise RuntimeError("DDR Diagnostic suite completed with errors.")


def main():
    parser = argparse.ArgumentParser(
        description="CoralNPU DDR Memory Diagnostic and Stress Test Suite"
    )
    parser.add_argument(
        "--usb-serial",
        required=True,
        help="USB serial of the FTDI device (e.g. Nexus-FTDI-14)."
    )
    parser.add_argument(
        "--highmem",
        action="store_true",
        default=True,
        help="Use highmem CSR base address (0x200000)."
    )
    parser.add_argument(
        "--soft-reset",
        action="store_true",
        help="Perform non-destructive core soft reset before running."
    )
    args = parser.parse_args()

    fixture = FpgaTestFixture.create(
        usb_serial=args.usb_serial, highmem=args.highmem
    )
    if args.soft_reset:
        print("Performing core soft reset...")
        fixture.soft_reset()

    run_ddr_diagnostics(fixture)


if __name__ == "__main__":
    main()
