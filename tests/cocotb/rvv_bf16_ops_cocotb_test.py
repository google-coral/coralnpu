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

import cocotb
import ml_dtypes
import numpy as np
from coralnpu_test_utils.sim_test_fixture import Fixture
from bazel_tools.tools.python.runfiles import runfiles


async def run_bfloat16_ops_test_case(dut, op_name, lmul, num_elements=64):
    """Executes a high-coverage BFloat16 operation test case on Verilator simulator."""
    fixture = await Fixture.Create(dut)
    r = runfiles.Create()
    elf_name = f"rvv_bf16_{op_name}_{lmul}.elf"
    elf_path = r.Rlocation(
        f"coralnpu_hw/tests/cocotb/rvv/arithmetics/{elf_name}"
    )

    symbols = ['in_buf_1', 'in_buf_2', 'in_indices', 'out_buf', 'out_buf_f32']
    await fixture.load_elf_and_lookup_symbols(elf_path, symbols)

    total_buf_len = num_elements * 2 if op_name in [
        "strided", "indexed"
    ] else num_elements

    # Generate input float data truncated to BF16 precision
    op1_bf16 = np.array([1.0 + (i * 0.125) for i in range(total_buf_len)],
                        dtype=np.float32).astype(ml_dtypes.bfloat16)
    op2_bf16 = np.array([0.5 + (i * 0.0625) for i in range(total_buf_len)],
                        dtype=np.float32).astype(ml_dtypes.bfloat16)

    op1_bf16_u16 = op1_bf16.view(np.uint16)
    op2_bf16_u16 = op2_bf16.view(np.uint16)

    # Float32 representations for reference calculations
    op1_floats = op1_bf16.astype(np.float32)
    op2_floats = op2_bf16.astype(np.float32)

    # Load input buffers
    await fixture.core_mini_axi.write(
        fixture.symbols['in_buf_1'], op1_bf16_u16.view(np.uint8)
    )
    await fixture.core_mini_axi.write(
        fixture.symbols['in_buf_2'], op2_bf16_u16.view(np.uint8)
    )

    # Indices for gather/scatter test (stride 2 byte offset = 4 bytes per element)
    if op_name == "indexed":
        indices = (np.arange(num_elements, dtype=np.uint16) * 4)
        await fixture.core_mini_axi.write(
            fixture.symbols['in_indices'], indices.view(np.uint8)
        )

    # Clear accumulator/outputs
    if op_name in ["mac_vv", "mac_vf"]:
        await fixture.core_mini_axi.write(
            fixture.symbols['out_buf_f32'],
            np.zeros(num_elements * 4, dtype=np.uint8)
        )

    cycles = await fixture.run_to_halt(timeout_cycles=200000)
    dut._log.info(
        f"Test case rvv_bf16_{op_name}_{lmul} completed in {cycles} cycles."
    )

    # Calculate expected values and perform vectorized verification
    if op_name == "mac_vv":
        expected = op1_floats[:num_elements] * op2_floats[:num_elements]
        raw_bytes = await fixture.core_mini_axi.read(
            fixture.symbols['out_buf_f32'], num_elements * 4
        )
        actual = np.frombuffer(raw_bytes, dtype=np.float32)
        np.testing.assert_allclose(actual, expected, rtol=1e-2, atol=1e-2)

    elif op_name == "mac_vf":
        scalar = op2_floats[0]
        expected = op1_floats[:num_elements] * scalar
        raw_bytes = await fixture.core_mini_axi.read(
            fixture.symbols['out_buf_f32'], num_elements * 4
        )
        actual = np.frombuffer(raw_bytes, dtype=np.float32)
        np.testing.assert_allclose(actual, expected, rtol=1e-2, atol=1e-2)

    elif op_name == "pipeline":
        expected = (op1_floats[:num_elements] *
                    op2_floats[:num_elements]) + op1_floats[:num_elements]
        raw_bytes = await fixture.core_mini_axi.read(
            fixture.symbols['out_buf'], num_elements * 2
        )
        actual = (
            np.frombuffer(raw_bytes,
                          dtype=np.uint16).view(ml_dtypes.bfloat16
                                                ).astype(np.float32)
        )
        np.testing.assert_allclose(actual, expected, rtol=1e-2, atol=1e-2)

    elif op_name == "strided":
        expected = op1_floats[::2][:num_elements] * op2_floats[::2
                                                               ][:num_elements]
        raw_bytes = await fixture.core_mini_axi.read(
            fixture.symbols['out_buf'], num_elements * 2 * 2
        )
        actual = (
            np.frombuffer(raw_bytes,
                          dtype=np.uint16)[::2].view(ml_dtypes.bfloat16
                                                     ).astype(np.float32)
        )
        np.testing.assert_allclose(actual, expected, rtol=1e-2, atol=1e-2)

    elif op_name == "indexed":
        expected = op1_floats[::2][:num_elements] * op2_floats[::2
                                                               ][:num_elements]
        raw_bytes = await fixture.core_mini_axi.read(
            fixture.symbols['out_buf'], num_elements * 2 * 2
        )
        actual = (
            np.frombuffer(raw_bytes,
                          dtype=np.uint16)[::2].view(ml_dtypes.bfloat16
                                                     ).astype(np.float32)
        )
        np.testing.assert_allclose(actual, expected, rtol=1e-2, atol=1e-2)

    dut._log.info(f"SUCCESS: rvv_bf16_{op_name}_{lmul} passed!")


@cocotb.test()
async def rvv_bf16_ops_test(dut):
    """Executes BFloat16 operation test suite across operations and LMULs."""
    for op in ["mac_vv", "mac_vf", "pipeline", "strided", "indexed"]:
        for lmul in ["mf2", "m1", "m2", "m4"]:
            await run_bfloat16_ops_test_case(dut, op, lmul)
