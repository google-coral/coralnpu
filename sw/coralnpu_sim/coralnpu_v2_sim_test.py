# Copyright 2026 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

import threading
import time
import unittest

from bazel_tools.tools.python.runfiles import runfiles
from coralnpu_v2_sim_utils import CoralNPUV2Simulator
import numpy as np


class TestCoralNPUV2SimPybind(unittest.TestCase):

    def setUp(self):
        self.sim = CoralNPUV2Simulator()
        self.r = runfiles.Create()
        self.elf_path = self.r.Rlocation(
            "coralnpu_hw/tests/cocotb/rvv/arithmetics/rvv_add_int8_m1.elf"
        )

    def _load_program(self):
        """Loads the test ELF program and returns entry point & symbol map."""
        entry_point, symbol_map = self.sim.get_elf_entry_and_symbol(
            self.elf_path, ["in_buf_1", "in_buf_2", "out_buf"]
        )
        self.sim.load_program(self.elf_path, entry_point)
        return entry_point, symbol_map

    def _read_pc(self):
        """Helper to read the current PC value."""
        return int(self.sim.read_register("pc"), 16)

    def test_add_kernel(self):
        """Verifies end-to-end execution of a vector add kernel."""
        _, symbol_map = self._load_program()
        # 1. Prepare Input
        input_size = 16
        in1 = np.arange(input_size, dtype=np.uint8)
        in2 = np.arange(input_size, dtype=np.uint8) * 2
        self.sim.write_memory(symbol_map["in_buf_1"], in1)
        self.sim.write_memory(symbol_map["in_buf_2"], in2)

        # 2. Run
        self.sim.run()
        self.sim.wait()

        # 3. Verify Output
        expected_out = in1 + in2
        actual_out = self.sim.read_memory(symbol_map["out_buf"], input_size)
        np.testing.assert_array_equal(
            actual_out, expected_out, "Output should match expected sum"
        )

        # 4. Verify Cycles
        cycle_count = self.sim.get_cycle_count()
        # Cycle count observed around 148
        self.assertTrue(
            140 < cycle_count < 160,
            f"Cycle count {cycle_count} should be ~148"
        )

    def test_check_input_type(self):
        """Verifies inputs are validated."""
        with self.assertRaisesRegex(TypeError, "data must be a numpy array"):
            self.sim.write_memory(0x1000, [1, 2, 3])

    def test_step(self):
        """Verifies single stepping."""
        self._load_program()
        self.assertEqual(self.sim.step(10), 10)
        self.assertGreater(self.sim.get_cycle_count(), 0)

    def test_read_write_register(self):
        """Verifies register access."""
        self._load_program()

        # Write & Read Back
        test_val = 0xDEADBEEF
        self.sim.write_register("t0", test_val)
        self.assertEqual(int(self.sim.read_register("t0"), 16), test_val)

    def test_breakpoint(self):
        """Verifies software breakpoints pause execution."""
        entry_point, _ = self._load_program()

        # 1. Set Breakpoint & Run
        self.sim.set_sw_breakpoint(entry_point)
        self.sim.run()
        self.sim.wait()

        # Should stop at entry point
        self.assertEqual(
            self._read_pc(), entry_point, "Simulator should stop at breakpoint"
        )

        # 2. Clear Breakpoint & Resume
        self.sim.clear_sw_breakpoint(entry_point)
        self.sim.run()
        self.sim.wait()

        # Should have advanced past entry point
        self.assertNotEqual(
            self._read_pc(), entry_point,
            "Simulator should resume after clearing breakpoint"
        )

    def test_halt(self):
        """Verifies asynchronous halt."""
        self._load_program()

        # Run is non-blocking
        self.sim.run()

        # Allow some execution time then Halt
        time.sleep(0.1)
        self.sim.halt()
        self.sim.wait()

        # Verify execution stopped
        cycle_count_before = self.sim.get_cycle_count()
        time.sleep(0.1)
        cycle_count_after = self.sim.get_cycle_count()
        self.assertEqual(
            cycle_count_before, cycle_count_after, "Simulator failed to halt"
        )

    def test_htif_semihosting(self):
        """Verifies HTIF semihosting functionality."""
        htif_elf_path = self.r.Rlocation(
            "coralnpu_hw/tests/verilator_sim/htif_semihosting_test.elf"
        )
        self.assertTrue(htif_elf_path is not None, "HTIF ELF not found")

        # Initialize simulator with semihost_htif enabled
        sim = CoralNPUV2Simulator(semihost_htif=True)
        entry_point, _ = sim.get_elf_entry_and_symbol(htif_elf_path, [])
        sim.load_program(htif_elf_path, entry_point)

        # Run the simulator
        sim.run()
        sim.wait()

        # If it finishes, it means EBREAK was hit (which semihosting uses for exit)
        # or the simulation reached its end.
        self.assertGreater(sim.get_cycle_count(), 0)


class TestCoralNPUV2Vrgather(unittest.TestCase):
    """Test suite exposing and verifying vrgather behaviors in CoralNPUSimulator.

    RISC-V Vector Spec (v1.0) Section 16.4:
      vrgather.vv vd, vs2, vs1, vm   # vd[i] = (vs1[i] >= VLMAX) ? 0 : vs2[vs1[i]]
      vrgather.vx vd, vs2, rs1, vm   # vd[i] = (rs1 >= VLMAX) ? 0 : vs2[rs1]
      vrgather.vi vd, vs2, uimm, vm  # vd[i] = (uimm >= VLMAX) ? 0 : vs2[uimm]
      vrgatherei16.vv vd, vs2, vs1, vm

    Key rules:
    1. Source vector vs2 can be read at any element index < VLMAX regardless of vl.
    2. Any element index >= VLMAX must write 0 to the destination element.
    3. The number of elements written to destination vd is governed by vl.
    """

    def setUp(self):
        self.r = runfiles.Create()
        self.elf_path = self.r.Rlocation(
            "coralnpu_hw/tests/cocotb/rvv/vrgather_test.elf"
        )
        self.assertTrue(
            self.elf_path is not None, "vrgather_test.elf not found"
        )
        self.symbols = [
            "vs2_buf",
            "vs1_buf",
            "vs1_ei16_buf",
            "vd_buf",
            "v0_mask_buf",
            "scalar_idx",
            "req_vl",
            "test_fn",
            "run_vrgather_vv_masked",
            "run_vrgather_vv_unmasked",
            "run_vrgather_vv_partial_vl",
            "run_vrgatherei16_vv_masked",
            "run_vrgatherei16_vv_unmasked",
            "run_vrgather_vx",
            "run_vrgather_vi_5",
            "run_vrgather_vi_20",
            "run_vrgather_vv_lmul4",
        ]

    def _setup_sim(self, target_fn_name):
        sim = CoralNPUV2Simulator()
        entry_point, symbol_map = sim.get_elf_entry_and_symbol(
            self.elf_path, self.symbols
        )
        sim.load_program(self.elf_path, entry_point)
        # Write test_fn pointer to dispatch target function in main()
        fn_addr = symbol_map[target_fn_name]
        sim.write_word(symbol_map["test_fn"], np.uint32(fn_addr))
        return sim, symbol_map

    def test_vrgather_vv_unmasked(self):
        """Tests vrgather.vv unmasked with SEW=8, LMUL=2 (VLMAX=32, vl=32)."""
        sim, syms = self._setup_sim("run_vrgather_vv_unmasked")

        # vs2 has 128 distinct sequential values [0..127] across loaded registers
        vs2_data = np.arange(128, dtype=np.uint8)
        sim.write_memory(syms["vs2_buf"], vs2_data)

        # vs1 index vector (32 elements for LMUL=2):
        # - Elements 0..7: indices 0..7 (< vl) -> in-bounds, should return 0..7
        # - Elements 8..15: indices 16..23 (< VLMAX=32) -> in-bounds, should return 16..23
        # - Elements 16..23: indices 32..39 (>= VLMAX=32) -> out-of-bounds, MUST return 0
        # - Elements 24..31: indices 40..47 (>= VLMAX=32) -> out-of-bounds, MUST return 0
        vs1_data = np.zeros(128, dtype=np.uint8)
        vs1_data[0:8] = np.arange(0, 8, dtype=np.uint8)
        vs1_data[8:16] = np.arange(16, 24, dtype=np.uint8)
        vs1_data[16:24] = np.arange(32, 40, dtype=np.uint8)
        vs1_data[24:32] = np.arange(40, 48, dtype=np.uint8)
        sim.write_memory(syms["vs1_buf"], vs1_data)

        # Initialize vd_buf to non-zero sentinel
        vd_init = np.full(128, 0xEE, dtype=np.uint8)
        sim.write_memory(syms["vd_buf"], vd_init)

        sim.write_word(syms["req_vl"], np.uint32(32))

        sim.run()
        sim.wait()

        # Expected output per RISC-V spec:
        expected = np.zeros(32, dtype=np.uint8)
        expected[0:8] = np.arange(0, 8, dtype=np.uint8)
        expected[8:16] = np.arange(16, 24, dtype=np.uint8)
        expected[16:24] = 0  # Out of bounds (>= VLMAX=32)
        expected[24:32] = 0  # Out of bounds (>= VLMAX=32)

        actual = sim.read_memory(syms["vd_buf"], 32)
        np.testing.assert_array_equal(
            actual,
            expected,
            f"vrgather.vv output mismatch.\nActual:   {actual.tolist()}\nExpected: {expected.tolist()}",
        )

    def test_vrgather_vv_masked(self):
        """Tests vrgather.vv masked with SEW=8, LMUL=2 (VLMAX=32, vl=32)."""
        sim, syms = self._setup_sim("run_vrgather_vv_masked")

        vs2_data = np.arange(128, dtype=np.uint8)
        sim.write_memory(syms["vs2_buf"], vs2_data)

        vs1_data = np.zeros(128, dtype=np.uint8)
        vs1_data[0:8] = np.arange(0, 8, dtype=np.uint8)
        vs1_data[8:16] = np.arange(16, 24, dtype=np.uint8)
        vs1_data[16:24] = np.arange(32, 40, dtype=np.uint8)
        vs1_data[24:32] = np.arange(40, 48, dtype=np.uint8)
        sim.write_memory(syms["vs1_buf"], vs1_data)

        # Mask: alternating enabled elements (0x55 = 0b01010101)
        mask = np.full(16, 0x55, dtype=np.uint8)
        sim.write_memory(syms["v0_mask_buf"], mask)

        # Initialize vd_buf to 0xFF (mask-undisturbed/inactive elements)
        vd_init = np.full(128, 0xFF, dtype=np.uint8)
        sim.write_memory(syms["vd_buf"], vd_init)

        sim.write_word(syms["req_vl"], np.uint32(32))

        sim.run()
        sim.wait()

        # Expected output: even indices (0, 2, 4, ...) are active; odd indices are undisturbed (0xFF)
        expected = np.full(32, 0xFF, dtype=np.uint8)
        for i in range(32):
            if (i % 2) == 0:  # active under mask 0x55
                idx = vs1_data[i]
                expected[i] = vs2_data[idx] if idx < 32 else 0

        actual = sim.read_memory(syms["vd_buf"], 32)
        np.testing.assert_array_equal(
            actual,
            expected,
            f"vrgather.vv (masked) output mismatch.\nActual:   {actual.tolist()}\nExpected: {expected.tolist()}",
        )

    def test_vrgather_vv_partial_vl(self):
        """Tests reading elements with index >= vl and index < VLMAX when vl < VLMAX."""
        sim, syms = self._setup_sim("run_vrgather_vv_partial_vl")

        vs2_data = np.arange(128, dtype=np.uint8)
        sim.write_memory(syms["vs2_buf"], vs2_data)

        # vs1 has indices [16..31] in the first 16 elements (which are >= vl=16, but < VLMAX=32)
        vs1_data = np.zeros(128, dtype=np.uint8)
        vs1_data[0:16] = np.arange(16, 32, dtype=np.uint8)
        sim.write_memory(syms["vs1_buf"], vs1_data)

        vd_init = np.full(128, 0xEE, dtype=np.uint8)
        sim.write_memory(syms["vd_buf"], vd_init)

        # Set vl = 16 (< VLMAX=32)
        sim.write_word(syms["req_vl"], np.uint32(16))

        sim.run()
        sim.wait()

        # Destination elements 0..15 should receive vs2[16..31]
        actual = sim.read_memory(syms["vd_buf"], 16)
        expected = np.arange(16, 32, dtype=np.uint8)
        np.testing.assert_array_equal(
            actual,
            expected,
            f"vrgather.vv partial vl gathering mismatch.\nActual:   {actual.tolist()}\nExpected: {expected.tolist()}",
        )

    def test_vrgatherei16_vv_unmasked(self):
        """Tests vrgatherei16.vv with SEW=8, LMUL=2 (index EEW=16, EMUL=4, VLMAX=32)."""
        sim, syms = self._setup_sim("run_vrgatherei16_vv_unmasked")

        vs2_data = np.arange(128, dtype=np.uint8)
        sim.write_memory(syms["vs2_buf"], vs2_data)

        # 16-bit indices
        vs1_ei16 = np.zeros(64, dtype=np.uint16)
        vs1_ei16[0:8] = np.arange(0, 8, dtype=np.uint16)
        vs1_ei16[8:16] = np.arange(16, 24, dtype=np.uint16)
        vs1_ei16[16:24] = np.arange(32, 40, dtype=np.uint16)  # >= VLMAX (32)
        vs1_ei16[24:32] = np.array([50, 100, 255, 300, 500, 1000, 2000, 65535],
                                   dtype=np.uint16)
        sim.write_memory(syms["vs1_ei16_buf"], vs1_ei16.view(np.uint8))

        vd_init = np.full(128, 0xEE, dtype=np.uint8)
        sim.write_memory(syms["vd_buf"], vd_init)

        sim.write_word(syms["req_vl"], np.uint32(32))

        sim.run()
        sim.wait()

        expected = np.zeros(32, dtype=np.uint8)
        expected[0:8] = np.arange(0, 8, dtype=np.uint8)
        expected[8:16] = np.arange(16, 24, dtype=np.uint8)
        expected[16:24] = 0  # >= VLMAX (32) -> 0
        expected[24:32] = 0  # >= VLMAX (32) -> 0

        actual = sim.read_memory(syms["vd_buf"], 32)
        np.testing.assert_array_equal(
            actual,
            expected,
            f"vrgatherei16.vv output mismatch.\nActual:   {actual.tolist()}\nExpected: {expected.tolist()}",
        )

    def test_vrgatherei16_vv_masked(self):
        """Tests vrgatherei16.vv masked with SEW=8, LMUL=2 (index EEW=16, EMUL=4, VLMAX=32)."""
        sim, syms = self._setup_sim("run_vrgatherei16_vv_masked")

        vs2_data = np.arange(128, dtype=np.uint8)
        sim.write_memory(syms["vs2_buf"], vs2_data)

        vs1_ei16 = np.zeros(64, dtype=np.uint16)
        vs1_ei16[0:8] = np.arange(0, 8, dtype=np.uint16)
        vs1_ei16[8:16] = np.arange(16, 24, dtype=np.uint16)
        vs1_ei16[16:24] = np.arange(32, 40, dtype=np.uint16)  # >= VLMAX (32)
        vs1_ei16[24:32] = np.array([50, 100, 255, 300, 500, 1000, 2000, 65535],
                                   dtype=np.uint16)
        sim.write_memory(syms["vs1_ei16_buf"], vs1_ei16.view(np.uint8))

        mask = np.full(16, 0x55, dtype=np.uint8)
        sim.write_memory(syms["v0_mask_buf"], mask)

        vd_init = np.full(128, 0xFF, dtype=np.uint8)
        sim.write_memory(syms["vd_buf"], vd_init)

        sim.write_word(syms["req_vl"], np.uint32(32))

        sim.run()
        sim.wait()

        expected = np.full(32, 0xFF, dtype=np.uint8)
        for i in range(32):
            if (i % 2) == 0:
                idx = vs1_ei16[i]
                expected[i] = vs2_data[idx] if idx < 32 else 0

        actual = sim.read_memory(syms["vd_buf"], 32)
        np.testing.assert_array_equal(
            actual,
            expected,
            f"vrgatherei16.vv (masked) output mismatch.\nActual:   {actual.tolist()}\nExpected: {expected.tolist()}",
        )

    def test_vrgather_vx(self):
        """Tests vrgather.vx with in-bounds and out-of-bounds scalar index."""
        # Case 1: In-bounds index (scalar_idx = 20 < VLMAX=32)
        sim, syms = self._setup_sim("run_vrgather_vx")
        vs2_data = np.arange(128, dtype=np.uint8)
        sim.write_memory(syms["vs2_buf"], vs2_data)
        sim.write_word(syms["req_vl"], np.uint32(32))
        sim.write_word(syms["scalar_idx"], np.uint32(20))

        sim.run()
        sim.wait()

        actual = sim.read_memory(syms["vd_buf"], 32)
        expected = np.full(32, 20, dtype=np.uint8)
        np.testing.assert_array_equal(actual, expected)

        # Case 2: Out-of-bounds index (scalar_idx = 35 >= VLMAX=32) -> must return 0
        sim, syms = self._setup_sim("run_vrgather_vx")
        sim.write_memory(syms["vs2_buf"], vs2_data)
        sim.write_word(syms["req_vl"], np.uint32(32))
        sim.write_word(syms["scalar_idx"], np.uint32(35))

        sim.run()
        sim.wait()

        actual = sim.read_memory(syms["vd_buf"], 32)
        expected = np.zeros(32, dtype=np.uint8)
        np.testing.assert_array_equal(
            actual,
            expected,
            f"vrgather.vx with scalar_idx >= VLMAX must produce 0.\nActual: {actual.tolist()}",
        )

    def test_vrgather_vi(self):
        """Tests vrgather.vi with uimm < VLMAX and uimm >= VLMAX (LMUL=1, VLMAX=16)."""
        # Case 1: uimm = 5 < VLMAX=16 -> must return vs2[5] = 5
        sim, syms = self._setup_sim("run_vrgather_vi_5")
        vs2_data = np.arange(128, dtype=np.uint8)
        sim.write_memory(syms["vs2_buf"], vs2_data)
        sim.write_word(syms["req_vl"], np.uint32(16))

        sim.run()
        sim.wait()

        actual = sim.read_memory(syms["vd_buf"], 16)
        expected = np.full(16, 5, dtype=np.uint8)
        np.testing.assert_array_equal(actual, expected)

        # Case 2: uimm = 20 >= VLMAX=16 -> must return 0
        sim, syms = self._setup_sim("run_vrgather_vi_20")
        sim.write_memory(syms["vs2_buf"], vs2_data)
        sim.write_word(syms["req_vl"], np.uint32(16))

        sim.run()
        sim.wait()

        actual = sim.read_memory(syms["vd_buf"], 16)
        expected = np.zeros(16, dtype=np.uint8)
        np.testing.assert_array_equal(
            actual,
            expected,
            f"vrgather.vi with uimm >= VLMAX must produce 0.\nActual: {actual.tolist()}",
        )

    def test_vrgather_vv_lmul4(self):
        """Tests vrgather.vv with LMUL=4 and vs2=v8 (VLMAX=64).

        In MPACT, reg 8 % 8 = 0 causes max_index = 128 instead of 64,
        causing out-of-bounds indices [64..79] to overgather instead of zeroing.
        """
        sim, syms = self._setup_sim("run_vrgather_vv_lmul4")

        vs2_data = np.arange(128, dtype=np.uint8)
        sim.write_memory(syms["vs2_buf"], vs2_data)

        # vs1 has:
        # - Elements 0..47: in-bounds indices 0..47 (< VLMAX=64)
        # - Elements 48..63: out-of-bounds indices 64..79 (>= VLMAX=64)
        vs1_data = np.zeros(128, dtype=np.uint8)
        vs1_data[0:48] = np.arange(0, 48, dtype=np.uint8)
        vs1_data[48:64] = np.arange(64, 80, dtype=np.uint8)
        sim.write_memory(syms["vs1_buf"], vs1_data)

        sim.write_word(syms["req_vl"], np.uint32(64))

        sim.run()
        sim.wait()

        # Elements 0..47 should be 0..47; elements 48..63 must be 0
        expected = np.zeros(64, dtype=np.uint8)
        expected[0:48] = np.arange(0, 48, dtype=np.uint8)
        expected[48:64] = 0

        actual = sim.read_memory(syms["vd_buf"], 64)
        np.testing.assert_array_equal(
            actual,
            expected,
            f"vrgather.vv LMUL=4 over-gather mismatch.\nActual:   {actual.tolist()}\nExpected: {expected.tolist()}",
        )


if __name__ == "__main__":
    import sys
    import os

    # Bazel passes the test filter in the TESTBRIDGE_TEST_ONLY environment variable.
    # If it's set, we can use it to filter the tests.
    if "TESTBRIDGE_TEST_ONLY" in os.environ:
        test_filter = os.environ["TESTBRIDGE_TEST_ONLY"]
        # unittest.main expects the filter as a positional argument.
        # We replace any '.' with '/' if it's a full path, but usually it's just Class.method
        # which unittest handles if passed as a positional arg.
        argv = [sys.argv[0], test_filter]
        unittest.main(argv=argv)
    else:
        unittest.main()
