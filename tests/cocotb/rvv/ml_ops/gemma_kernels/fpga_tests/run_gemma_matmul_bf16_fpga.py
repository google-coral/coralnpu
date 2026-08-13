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
"""BF16 Gemma Transformer Matrix Multiplication (GeMV & Tiled GEMM) FPGA Hardware Test."""

import argparse
import ml_dtypes
import numpy as np
from coralnpu_test_utils.fpga_test_fixture import FpgaTestFixture
from sw.utils.metrics import log_matmul_metrics

# Standard Gemma Transformer matrix shapes (M, K, N, Description)
GEMMA_TEST_SHAPES = [
    (1, 640, 512, "Gemma 3 270M Single-Token GeMV Decode"),
    (1, 1024, 64, "1D Attention Output Projection"),
    (12, 640, 512, "Gemma 3 12-Token Prompt Prefill GEMM"),
    (32, 32, 32, "Square Tile Baseline"),
    (64, 256, 512, "Deep Tiled GEMM"),
]


def run_gemma_matmul_bf16_fpga(fixture: FpgaTestFixture, verify: bool = False):
    """Executes BF16 Gemma GeMV (1D) and Tiled GEMM (2D) kernels across multiple shapes."""
    core_freq_mhz = fixture.get_core_frequency_mhz()
    core_freq_hz = fixture.get_core_frequency_hz()

    print(
        f"\n===================================================================="
    )
    print(f"CoralNPU FPGA Gemma BF16 Matrix Multiplication Test Suite")
    print(
        f"FPGA Core Clock Frequency: {core_freq_mhz} MHz ({core_freq_hz:,} Hz)"
    )
    print(f"Target Hardware: {fixture.usb_serial}")
    print(
        f"====================================================================\n"
    )

    fixture.load_elf_and_lookup_symbols(
        "tests/cocotb/rvv/ml_ops/gemma_kernels/rvv_bf16_matmul.elf",
        symbols=[
            "lhs_input", "rhs_input", "result_output", "active_m", "active_k",
            "active_n", "cycle_count"
        ],
        verify=verify,
    )

    rng = np.random.default_rng(seed=42)

    for M, K, N, desc in GEMMA_TEST_SHAPES:
        print(f"\n--- Testing Shape: {desc} (M={M}, K={K}, N={N}) ---")

        # 1. Generate random FP32 inputs and convert to exact BF16
        lhs_fp32 = rng.uniform(-2.0, 2.0, size=(M, K)).astype(np.float32)
        rhs_fp32 = rng.uniform(-2.0, 2.0, size=(K, N)).astype(np.float32)

        lhs_bf16 = lhs_fp32.astype(ml_dtypes.bfloat16)
        rhs_bf16 = rhs_fp32.astype(ml_dtypes.bfloat16)

        lhs_exact = lhs_bf16.astype(np.float32)
        rhs_exact = rhs_bf16.astype(np.float32)
        golden = (lhs_exact @ rhs_exact).astype(ml_dtypes.bfloat16
                                                ).astype(np.float32)

        # 2. Upload dimensions and BF16 raw data (as uint16) to hardware
        fixture.write_word("active_m", M)
        fixture.write_word("active_k", K)
        fixture.write_word("active_n", N)
        fixture.write("lhs_input", lhs_bf16.view(np.uint16).flatten())
        fixture.write("rhs_input", rhs_bf16.view(np.uint16).flatten())
        fixture.write(
            "result_output",
            np.zeros((M, N), dtype=np.uint16).flatten()
        )

        # 3. Execute kernel and wait for core to halt
        print(f"Executing kernel on hardware (M={M}, K={K}, N={N})...")
        if not fixture.run_to_halt():
            raise RuntimeError(
                f"TEST FAILED: Core timed out executing shape ({M}x{K}x{N})."
            )

        # 4. Verify output numerically
        actual_u16 = fixture.read(
            "result_output", dtype=np.uint16, shape=(M, N)
        )
        actual = actual_u16.view(ml_dtypes.bfloat16).astype(np.float32)
        np.testing.assert_allclose(
            actual,
            golden,
            rtol=1e-2,
            atol=1e-2,
            err_msg=f"Mismatch @ {M}x{K}x{N}"
        )

        # 5. Log metrics using runner cycle_count symbol and FPGA frequency
        cycles = fixture.read_word("cycle_count")
        macs = M * K * N
        latency_ms = (cycles / core_freq_hz) * 1000.0 if cycles else 0.0
        macs_per_cycle = macs / cycles if cycles else 0.0
        print(
            f"Shape {M}x{K}x{N} PASSED! ({cycles:,} cycles, {latency_ms:.3f} ms, {macs_per_cycle:.2f} MACs/cyc @ {core_freq_mhz} MHz)"
        )
        log_matmul_metrics(
            fixture, f"[FPGA] Gemma_BF16_MatMul_{M}x{K}x{N}", cycles, M, N, K
        )

    print(
        f"\n===================================================================="
    )
    print(
        f"ALL {len(GEMMA_TEST_SHAPES)}/{len(GEMMA_TEST_SHAPES)} GEMMA BF16 SHAPES PASSED ON FPGA HARDWARE ({core_freq_mhz} MHz)!"
    )
    print(
        f"====================================================================\n"
    )


if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description=
        "Run BF16 Gemma Matrix Multiplication tests on CoralNPU FPGA Hardware"
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
        "--verify",
        action="store_true",
        help="Verify ELF loading by reading back memory segments."
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
    run_gemma_matmul_bf16_fpga(fixture, verify=args.verify)
