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
"""Lean integration tests for UvmTestFixture against uvm_sim_verilator.

Validates end-to-end simulation orchestration, ELF symbol loading, in-memory
staging, and 3-way co-simulation (RTL vs. MPACT vs. Spike ISS).
"""

import unittest
import numpy as np

from coralnpu_test_utils.uvm_test_fixture import UvmTestFixture


class TestUvmIntegration(unittest.IsolatedAsyncioTestCase):
    """Lean integration test suite validating UvmTestFixture functionality."""

    # 1. RVV MatMul kernel (Scalar & array memory staging, 3-way co-simulation)
    async def test_uvm_matmul(self):
        fixture = await UvmTestFixture.Create(
            simulator="verilator", enable_spike_cosim=True
        )
        await fixture.load_elf_and_lookup_symbols(
            "tests/cocotb/rvv/ml_ops/rvv_matmul.elf",
            symbols=[
                "lhs_input", "rhs_input", "result_output", "lhs_rows",
                "rhs_cols", "inner"
            ],
        )

        lhs_rows, inner, rhs_cols = 16, 16, 16
        await fixture.write_word("lhs_rows", lhs_rows)
        await fixture.write_word("rhs_cols", rhs_cols)
        await fixture.write_word("inner", inner)

        lhs_input = np.random.randint(
            -128, 127, size=(lhs_rows, inner), dtype=np.int8
        )
        rhs_input = np.random.randint(
            -128, 127, size=(inner, rhs_cols), dtype=np.int8
        )

        await fixture.write("lhs_input", lhs_input)
        await fixture.write("rhs_input", rhs_input.flatten(order="F"))

        success = await fixture.run_to_halt(timeout_sec=5.0)
        self.assertTrue(success, "UVM Matmul test failed")

        # Verify scalar read_word()
        self.assertEqual(await fixture.read_word("lhs_rows"), lhs_rows)
        self.assertEqual(await fixture.read_word("rhs_cols"), rhs_cols)
        self.assertEqual(await fixture.read_word("inner"), inner)

        # Verify raw bytes read()
        raw_bytes = await fixture.read(
            "result_output", size=lhs_rows * rhs_cols * 4
        )
        self.assertIsInstance(raw_bytes, bytes)
        self.assertEqual(len(raw_bytes), lhs_rows * rhs_cols * 4)

        # Verify structured array read()
        result = await fixture.read(
            "result_output",
            dtype=np.int32,
            shape=(lhs_rows, rhs_cols),
        )
        golden_output = np.matmul(
            lhs_input.astype(np.int32), rhs_input.astype(np.int32)
        )
        np.testing.assert_array_equal(result, golden_output)

    # 2. RVV MatMul kernel (Int8 Handcrafted Assembly)
    async def test_uvm_matmul_assembly(self):
        fixture = await UvmTestFixture.Create(
            simulator="verilator", enable_spike_cosim=True
        )
        await fixture.load_elf_and_lookup_symbols(
            "tests/cocotb/rvv/ml_ops/rvv_matmul_assembly.elf",
            symbols=[
                "lhs_input", "rhs_input", "result_output", "lhs_rows",
                "rhs_cols", "inner"
            ],
        )

        lhs_rows, inner, rhs_cols = 16, 16, 16
        await fixture.write_word("lhs_rows", lhs_rows)
        await fixture.write_word("rhs_cols", rhs_cols)
        await fixture.write_word("inner", inner)

        lhs_input = np.random.randint(
            -128, 127, size=(lhs_rows, inner), dtype=np.int8
        )
        rhs_input = np.random.randint(
            -128, 127, size=(inner, rhs_cols), dtype=np.int8
        )

        await fixture.write("lhs_input", lhs_input)
        await fixture.write("rhs_input", rhs_input.flatten(order="F"))

        success = await fixture.run_to_halt(timeout_sec=5.0)
        self.assertTrue(success, "UVM Matmul Assembly test failed")

        result = await fixture.read(
            "result_output",
            dtype=np.int32,
            shape=(lhs_rows, rhs_cols),
        )
        golden_output = np.matmul(
            lhs_input.astype(np.int32), rhs_input.astype(np.int32)
        )
        np.testing.assert_array_equal(result, golden_output)

    # 3. Floating-point RVV MatMul kernel (FP32 C intrinsics)
    async def test_uvm_float_matmul(self):
        fixture = await UvmTestFixture.Create(
            simulator="verilator", enable_spike_cosim=True
        )
        await fixture.load_elf_and_lookup_symbols(
            "tests/cocotb/rvv/ml_ops/rvv_float_matmul.elf",
            symbols=[
                "lhs_input", "rhs_input", "result_output", "lhs_rows",
                "rhs_cols", "inner"
            ],
        )

        lhs_rows, inner, rhs_cols = 16, 16, 16
        await fixture.write_word("lhs_rows", lhs_rows)
        await fixture.write_word("rhs_cols", rhs_cols)
        await fixture.write_word("inner", inner)

        lhs_input = np.random.uniform(
            -5.0, 5.0, size=(lhs_rows, inner)
        ).astype(np.float32)
        rhs_input = np.random.uniform(
            -5.0, 5.0, size=(inner, rhs_cols)
        ).astype(np.float32)

        await fixture.write("lhs_input", lhs_input)
        await fixture.write("rhs_input", rhs_input.flatten(order="F"))

        success = await fixture.run_to_halt(timeout_sec=10.0)
        self.assertTrue(success, "UVM Float Matmul test failed")

        result = await fixture.read(
            "result_output",
            dtype=np.float32,
            shape=(lhs_rows, rhs_cols),
        )
        golden_output = np.matmul(lhs_input, rhs_input)
        np.testing.assert_allclose(result, golden_output, rtol=1e-5, atol=1e-5)

    # 4. Floating-point RVV MatMul kernel (FP32 4x4 unrolled & optimized)
    async def test_uvm_float_matmul_optimized(self):
        fixture = await UvmTestFixture.Create(
            simulator="verilator", enable_spike_cosim=True
        )
        await fixture.load_elf_and_lookup_symbols(
            "tests/cocotb/rvv/ml_ops/rvv_float_matmul_optimized.elf",
            symbols=[
                "lhs_input", "rhs_input", "result_output", "lhs_rows",
                "rhs_cols", "inner"
            ],
        )

        lhs_rows, inner, rhs_cols = 16, 16, 16
        await fixture.write_word("lhs_rows", lhs_rows)
        await fixture.write_word("rhs_cols", rhs_cols)
        await fixture.write_word("inner", inner)

        lhs_input = np.random.uniform(
            -5.0, 5.0, size=(lhs_rows, inner)
        ).astype(np.float32)
        rhs_input = np.random.uniform(
            -5.0, 5.0, size=(inner, rhs_cols)
        ).astype(np.float32)

        await fixture.write("lhs_input", lhs_input)
        await fixture.write("rhs_input", rhs_input.flatten(order="F"))

        success = await fixture.run_to_halt(timeout_sec=5.0)
        self.assertTrue(success, "UVM Float Matmul Optimized test failed")

        result = await fixture.read(
            "result_output",
            dtype=np.float32,
            shape=(lhs_rows, rhs_cols),
        )
        golden_output = np.matmul(lhs_input, rhs_input)
        np.testing.assert_allclose(result, golden_output, rtol=1e-5, atol=1e-5)

    # 5. Vector arithmetic addition operator test (Int32 vadd.vv)
    async def test_uvm_arithmetic_add_int32(self):
        fixture = await UvmTestFixture.Create(
            simulator="verilator", enable_spike_cosim=True
        )
        await fixture.load_elf_and_lookup_symbols(
            "tests/cocotb/rvv/arithmetics/rvv_add_int32_m1.elf",
            symbols=["in_buf_1", "in_buf_2", "out_buf"],
        )

        # Note: CoralNPU hardware has VLEN=128 bits. For 32-bit types with LMUL=1 (m1),
        # vl = 128 / 32 = 4 elements. The rvv_arithmetic_template kernel executes a single
        # vector instruction with num_operands=4, computing and writing only the first 4 elements.
        in_buf_1 = np.random.randint(-1000, 1000, size=(4, ), dtype=np.int32)
        in_buf_2 = np.random.randint(-1000, 1000, size=(4, ), dtype=np.int32)

        await fixture.write("in_buf_1", in_buf_1)
        await fixture.write("in_buf_2", in_buf_2)

        success = await fixture.run_to_halt(timeout_sec=5.0)
        self.assertTrue(success, "UVM Arithmetic Add Int32 failed")

        result = await fixture.read("out_buf", dtype=np.int32, shape=(4, ))
        np.testing.assert_array_equal(result, in_buf_1 + in_buf_2)

    # 6. Vector arithmetic subtraction operator test (Int32 vsub.vv)
    async def test_uvm_arithmetic_sub_int32(self):
        fixture = await UvmTestFixture.Create(
            simulator="verilator", enable_spike_cosim=True
        )
        await fixture.load_elf_and_lookup_symbols(
            "tests/cocotb/rvv/arithmetics/rvv_sub_int32_m1.elf",
            symbols=["in_buf_1", "in_buf_2", "out_buf"],
        )

        # Note: VLEN=128, SEW=32, LMUL=1 -> vl = 4 elements computed by kernel.
        in_buf_1 = np.random.randint(-1000, 1000, size=(4, ), dtype=np.int32)
        in_buf_2 = np.random.randint(-1000, 1000, size=(4, ), dtype=np.int32)

        await fixture.write("in_buf_1", in_buf_1)
        await fixture.write("in_buf_2", in_buf_2)

        success = await fixture.run_to_halt(timeout_sec=5.0)
        self.assertTrue(success, "UVM Arithmetic Sub Int32 failed")

        result = await fixture.read("out_buf", dtype=np.int32, shape=(4, ))
        np.testing.assert_array_equal(result, in_buf_1 - in_buf_2)

    # 7. Vector arithmetic multiplication operator test (Int32 vmul.vv)
    async def test_uvm_arithmetic_mul_int32(self):
        fixture = await UvmTestFixture.Create(
            simulator="verilator", enable_spike_cosim=True
        )
        await fixture.load_elf_and_lookup_symbols(
            "tests/cocotb/rvv/arithmetics/rvv_mul_int32_m1.elf",
            symbols=["in_buf_1", "in_buf_2", "out_buf"],
        )

        # Note: VLEN=128, SEW=32, LMUL=1 -> vl = 4 elements computed by kernel.
        in_buf_1 = np.random.randint(-100, 100, size=(4, ), dtype=np.int32)
        in_buf_2 = np.random.randint(-100, 100, size=(4, ), dtype=np.int32)

        await fixture.write("in_buf_1", in_buf_1)
        await fixture.write("in_buf_2", in_buf_2)

        success = await fixture.run_to_halt(timeout_sec=5.0)
        self.assertTrue(success, "UVM Arithmetic Mul Int32 failed")

        result = await fixture.read("out_buf", dtype=np.int32, shape=(4, ))
        np.testing.assert_array_equal(result, in_buf_1 * in_buf_2)

    # 8. Vector bitwise logical XOR operator test (Int32 vxor.vv)
    async def test_uvm_bitwise_xor_int32(self):
        fixture = await UvmTestFixture.Create(
            simulator="verilator", enable_spike_cosim=True
        )
        await fixture.load_elf_and_lookup_symbols(
            "tests/cocotb/rvv/arithmetics/rvv_xor_int32_m1.elf",
            symbols=["in_buf_1", "in_buf_2", "out_buf"],
        )

        # Note: VLEN=128, SEW=32, LMUL=1 -> vl = 4 elements computed by kernel.
        in_buf_1 = np.random.randint(0, 0x7FFFFFFF, size=(4, ), dtype=np.int32)
        in_buf_2 = np.random.randint(0, 0x7FFFFFFF, size=(4, ), dtype=np.int32)

        await fixture.write("in_buf_1", in_buf_1)
        await fixture.write("in_buf_2", in_buf_2)

        success = await fixture.run_to_halt(timeout_sec=5.0)
        self.assertTrue(success, "UVM Bitwise XOR Int32 failed")

        result = await fixture.read("out_buf", dtype=np.int32, shape=(4, ))
        np.testing.assert_array_equal(result, in_buf_1 ^ in_buf_2)

    # 9. Vector arithmetic signed maximum operator test (Int32 vmax.vv)
    async def test_uvm_arithmetic_max_int32(self):
        fixture = await UvmTestFixture.Create(
            simulator="verilator", enable_spike_cosim=True
        )
        await fixture.load_elf_and_lookup_symbols(
            "tests/cocotb/rvv/arithmetics/rvv_max_int32_m1.elf",
            symbols=["in_buf_1", "in_buf_2", "out_buf"],
        )

        # Note: VLEN=128, SEW=32, LMUL=1 -> vl = 4 elements computed by kernel.
        in_buf_1 = np.random.randint(-1000, 1000, size=(4, ), dtype=np.int32)
        in_buf_2 = np.random.randint(-1000, 1000, size=(4, ), dtype=np.int32)

        await fixture.write("in_buf_1", in_buf_1)
        await fixture.write("in_buf_2", in_buf_2)

        success = await fixture.run_to_halt(timeout_sec=5.0)
        self.assertTrue(success, "UVM Arithmetic Max Int32 failed")

        result = await fixture.read("out_buf", dtype=np.int32, shape=(4, ))
        np.testing.assert_array_equal(result, np.maximum(in_buf_1, in_buf_2))

    # 10. Vector floating-point addition operator test (FP32 vfadd.vv with RNE rounding)
    async def test_uvm_float_fadd(self):
        fixture = await UvmTestFixture.Create(
            simulator="verilator", enable_spike_cosim=True
        )
        await fixture.load_elf_and_lookup_symbols(
            "tests/cocotb/rvv/arithmetics/rvv_fadd_float_rne_m1.elf",
            symbols=["in_buf_1", "in_buf_2", "out_buf"],
        )

        # Note: VLEN=128, SEW=32, LMUL=1 -> vl = 4 elements computed by kernel.
        in_buf_1 = np.random.uniform(
            -10.0, 10.0, size=(4, )
        ).astype(np.float32)
        in_buf_2 = np.random.uniform(
            -10.0, 10.0, size=(4, )
        ).astype(np.float32)

        await fixture.write("in_buf_1", in_buf_1)
        await fixture.write("in_buf_2", in_buf_2)

        success = await fixture.run_to_halt(timeout_sec=5.0)
        self.assertTrue(success, "UVM Float FAdd test failed")

        result = await fixture.read("out_buf", dtype=np.float32, shape=(4, ))
        np.testing.assert_allclose(
            result, in_buf_1 + in_buf_2, rtol=1e-5, atol=1e-5
        )


if __name__ == "__main__":
    unittest.main()
