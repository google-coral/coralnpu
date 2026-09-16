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
import numpy as np
from coralnpu_test_utils.core_mini_axi_interface import CoreMiniAxiInterface
from bazel_tools.tools.python.runfiles import runfiles


@cocotb.test()
async def csr_read_write_test(dut):
    """Test CSR read/write operations."""

    core_mini_axi = CoreMiniAxiInterface(dut)
    await core_mini_axi.init()
    await core_mini_axi.reset()
    cocotb.start_soon(core_mini_axi.clock.start())

    r = runfiles.Create()
    elf_path = r.Rlocation(
        "coralnpu_hw/tests/cocotb/csr_test/csr_test_program.elf"
    )
    if not elf_path:
        raise ValueError("Could not find ELF file. Build the target first.")

    with open(elf_path, "rb") as f:
        entry_point = await core_mini_axi.load_elf(f)

    with open(elf_path, "rb") as f:
        results_addr = core_mini_axi.lookup_symbol(f, "csr_results")

    await core_mini_axi.execute_from(entry_point)
    await core_mini_axi.wait_for_halted()

    results_bytes = await core_mini_axi.read(results_addr, 11 * 4)
    results = results_bytes.view(np.uint32)

    test_1_write = int(results[0])
    test_1_read = int(results[1])
    test_2_write = int(results[2])
    test_2_read = int(results[3])
    test_3_write = int(results[4])
    test_3_read = int(results[5])
    test_4_write = int(results[6])
    test_4_read = int(results[7])
    test_5_write = int(results[8])
    test_5_read = int(results[9])
    test_status = int(results[10])

    cocotb.log.info(
        f"[CSR Test] Test 1 (FCSR): written=0x{test_1_write:08x} read=0x{test_1_read:08x}"
    )
    cocotb.log.info(
        f"[CSR Test] Test 2 (FFLAGS): written=0x{test_2_write:08x} read=0x{test_2_read:08x}"
    )
    cocotb.log.info(
        f"[CSR Test] Test 3 (MSCRATCH): written=0x{test_3_write:08x} read=0x{test_3_read:08x}"
    )
    cocotb.log.info(
        f"[CSR Test] Test 4 (MSTATUSH): written=0x{test_4_write:08x} read=0x{test_4_read:08x}"
    )
    cocotb.log.info(
        f"[CSR Test] Test 5 (MEPC): written=0x{test_5_write:08x} read=0x{test_5_read:08x}"
    )
    cocotb.log.info(
        f"[CSR Test] Overall status: {'PASS' if test_status == 0 else 'FAIL'}"
    )

    assert (test_1_read & test_1_write) == test_1_write, \
        f"Test 1 failed: 0x{test_1_write:08x} != 0x{test_1_read:08x}"
    assert (test_2_read & test_2_write) == test_2_write, \
        f"Test 2 failed: 0x{test_2_write:08x} != 0x{test_2_read:08x}"
    assert (test_3_read & test_3_write) == test_3_write, \
        f"Test 3 failed: 0x{test_3_write:08x} != 0x{test_3_read:08x}"
    assert (test_4_read == 0x00000000), \
        f"Test 4 failed: 0x{test_4_write:08x} != 0x{test_4_read:08x}"
    assert (test_5_read == (test_5_write & ~0x3)), \
        f"Test 5 failed: 0x{test_5_write:08x} != 0x{test_5_read:08x}"
    assert test_status == 0, "CSR test failed in program"

    cocotb.log.info("[CSR Test] ✓ All tests passed!")
