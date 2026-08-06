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
"""Optimized FP32 & BF16 RVV Matrix Multiplication on CoralNPU FPGA Hardware (Zero DDR, DTCM-Resident)."""

import logging
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

logger = logging.getLogger(__name__)


def run_float_matmul_fpga(fixture: FpgaTestFixture):
    """Executes optimized FP32 RVV matrix multiplication in DTCM SRAM."""
    core_freq_mhz = fixture.get_core_frequency_mhz()
    core_freq_hz = fixture.get_core_frequency_hz()
    elf_file = "tests/cocotb/rvv/ml_ops/rvv_float_matmul_optimized.elf"

    print(
        f"\n===================================================================="
    )
    print(
        f"CoralNPU FPGA Optimized FP32 Matrix Multiplication Test (DTCM-Resident)"
    )
    print(
        f"FPGA Core Clock Frequency: {core_freq_mhz} MHz ({core_freq_hz:,} Hz)"
    )
    print(f"ELF Kernel: {elf_file}")
    print(f"Target Hardware: {fixture.usb_serial}")
    print(
        f"====================================================================\n"
    )

    # 1. Load ELF and lookup symbols (Zero DDR accesses, DTCM only)
    fixture.load_elf_and_lookup_symbols(
        elf_file,
        symbols=[
            "lhs_input", "rhs_input", "result_output", "lhs_rows", "rhs_cols",
            "inner"
        ],
        verify=True,
    )

    # 2. Configure Dimensions (Max 16x48x16 in DTCM)
    lhs_rows = 16
    rhs_cols = 16
    inner = 48
    print(
        f"Executing FP32 Matrix Multiplication: {lhs_rows}x{inner} x {inner}x{rhs_cols}"
    )

    # 3. Generate random FP32 inputs in range [-1.5, 1.5]
    rng = np.random.default_rng(seed=42)
    lhs_input = rng.uniform(
        -1.5, 1.5, size=(lhs_rows, inner)
    ).astype(np.float32)
    rhs_input = rng.uniform(
        -1.5, 1.5, size=(inner, rhs_cols)
    ).astype(np.float32)
    golden_output = np.matmul(lhs_input, rhs_input)

    # 4. Upload dimensions and matrix data to DTCM (.data at 0x10000)
    fixture.write("lhs_rows", lhs_rows)
    fixture.write("rhs_cols", rhs_cols)
    fixture.write("inner", inner)
    fixture.write("lhs_input", lhs_input.flatten())
    fixture.write("rhs_input", rhs_input.flatten())
    fixture.write("result_output", np.zeros_like(golden_output).flatten())

    # 5. Execute kernel and wait for core to halt
    print("Starting execution on FPGA hardware...")
    if not fixture.run_to_halt(timeout_sec=20.0):
        raise RuntimeError(
            "TEST FAILED: Core timed out executing FP32 kernel."
        )

    # 6. Read back FP32 result matrix from DTCM
    result = fixture.read(
        "result_output",
        dtype=np.float32,
        shape=(lhs_rows, rhs_cols),
    )

    # 7. Numerical verification with float tolerance
    print("\nVerifying numerical output against NumPy reference...")
    np.testing.assert_allclose(
        result,
        golden_output,
        rtol=1e-3,
        atol=1e-3,
        err_msg="FP32 Output does not match golden reference!",
    )
    print("NUMERICAL VERIFICATION PASSED! (Verified shape:", result.shape, ")")

    # 8. Performance metrics
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
            test_name=
            f"[FPGA] rvv_float_matmul_opt_{lhs_rows}x{rhs_cols}x{inner}",
            cycles=cycles,
            lhs_rows=lhs_rows,
            rhs_cols=rhs_cols,
            inner=inner,
        )


if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(
        description=
        "Run Optimized FP32 RVV Matrix Multiplication test on CoralNPU FPGA Hardware"
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
    run_float_matmul_fpga(fixture)
