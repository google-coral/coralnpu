#!/usr/bin/env python3
# Copyright 2025 Google LLC
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
"""Matrix Multiplication Test on CoralNPU FPGA Hardware."""

import os
import sys
import numpy as np

# To support execution without Bazel runfiles:
_script_dir = os.path.dirname(os.path.abspath(__file__))
_project_root = os.path.dirname(_script_dir)
if _project_root not in sys.path:
    sys.path.insert(0, _project_root)

from coralnpu_test_utils.fpga_test_fixture import FpgaTestFixture
from sw.utils.metrics import log_matmul_metrics

TEST_SHAPES = [
    (16, 48, 16, "Standard 16x48x16 Baseline"),
    (32, 64, 32, "Mid-size 32x64x32 Tile"),
    (32, 128, 32, "Large 32x128x32 Max DTCM (131k MACs)"),
]


def run_matmul_test(fixture: FpgaTestFixture):
    """Executes the matrix multiplication test logic on FPGA hardware across multiple shapes."""
    core_freq_mhz = fixture.get_core_frequency_mhz()
    core_freq_hz = fixture.get_core_frequency_hz()

    elf_file = (
        "tests/cocotb/rvv/ml_ops/rvv_matmul_highmem.elf"
        if fixture.highmem else "tests/cocotb/rvv/ml_ops/rvv_matmul.elf"
    )

    print(
        f"\n===================================================================="
    )
    print(f"CoralNPU FPGA RVV Matrix Multiplication Test Suite")
    print(
        f"FPGA Core Clock Frequency: {core_freq_mhz} MHz ({core_freq_hz:,} Hz)"
    )
    print(f"ELF Kernel: {elf_file}")
    print(f"Target Hardware: {fixture.usb_serial}")
    print(
        f"====================================================================\n"
    )

    # 1. Load ELF and lookup required symbols
    fixture.load_elf_and_lookup_symbols(
        elf_file,
        symbols=[
            "lhs_input", "rhs_input", "result_output", "lhs_rows", "rhs_cols",
            "inner"
        ],
        verify=True,
    )

    passed_count = 0

    for lhs_rows, inner, rhs_cols, desc in TEST_SHAPES:
        print(
            f"\n--- Testing Shape: {desc} (M={lhs_rows}, K={inner}, N={rhs_cols}) ---"
        )

        # 2. Generate random int8 input data & compute int32 golden output
        lhs_input = np.random.randint(
            -128, 127, size=(lhs_rows, inner), dtype=np.int8
        )
        rhs_input = np.random.randint(
            -128, 127, size=(inner, rhs_cols), dtype=np.int8
        )
        golden_output = np.matmul(
            lhs_input.astype(np.int32), rhs_input.astype(np.int32)
        )

        # 3. Upload dimensions and input matrices to hardware
        fixture.write("lhs_rows", lhs_rows)
        fixture.write("rhs_cols", rhs_cols)
        fixture.write("inner", inner)
        fixture.write("lhs_input", lhs_input)
        fixture.write("rhs_input", rhs_input.flatten(order="F"))
        fixture.write("result_output", np.zeros_like(golden_output).flatten())

        # 4. Execute kernel and wait for core to halt
        print(
            f"Starting core execution for shape {lhs_rows}x{inner}x{rhs_cols}..."
        )
        if not fixture.run_to_halt():
            raise RuntimeError(
                f"TEST FAILED: Core did not halt within timeout for shape {lhs_rows}x{inner}x{rhs_cols}."
            )

        # 5. Read back result matrix and verify against golden reference
        result = fixture.read(
            "result_output",
            dtype=golden_output.dtype,
            shape=golden_output.shape,
        )

        # 6. Verify result
        if np.array_equal(golden_output, result):
            print(
                f"Shape {lhs_rows}x{inner}x{rhs_cols} PASSED! (Verified shape: {result.shape})"
            )
        else:
            print("Golden Reference:\n", golden_output)
            print("Received Output:\n", result)
            raise RuntimeError(
                f"TEST FAILED: Output mismatch for shape {lhs_rows}x{inner}x{rhs_cols}."
            )

        # 7. Log performance metrics
        cycles = fixture.get_cycle_count()
        if cycles is not None:
            macs = lhs_rows * inner * rhs_cols
            latency_ms = (cycles / core_freq_hz) * 1000.0
            macs_per_cycle = macs / cycles if cycles else 0.0
            print(f"  Execution Cycles: {cycles:,} cycles")
            print(
                f"  Execution Latency: {latency_ms:.3f} ms (@ {core_freq_mhz} MHz)"
            )
            print(f"  Throughput:       {macs_per_cycle:.2f} MACs/cycle")
            log_matmul_metrics(
                fixture,
                test_name=f"[FPGA] rvv_matmul_{lhs_rows}x{rhs_cols}x{inner}",
                cycles=cycles,
                lhs_rows=lhs_rows,
                rhs_cols=rhs_cols,
                inner=inner,
            )

        passed_count += 1

    print(
        f"\n===================================================================="
    )
    print(
        f"ALL {passed_count}/{len(TEST_SHAPES)} MATMUL SHAPES PASSED ON FPGA HARDWARE ({core_freq_mhz} MHz)!"
    )
    print(
        f"====================================================================\n"
    )


if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(
        description=
        "Run RVV Matrix Multiplication test on CoralNPU FPGA Hardware"
    )
    parser.add_argument(
        "--usb-serial",
        required=True,
        help="USB serial of the FTDI device (e.g. Nexus-FTDI-12)."
    )
    parser.add_argument(
        "--highmem",
        action="store_true",
        help="Use highmem CSR base address (0x200000)."
    )
    parser.add_argument(
        "--timeout",
        type=float,
        default=60.0,
        help="Execution timeout in seconds."
    )
    args = parser.parse_args()

    fixture = FpgaTestFixture.create(
        usb_serial=args.usb_serial, highmem=args.highmem
    )
    fixture.default_timeout = args.timeout
    run_matmul_test(fixture)
