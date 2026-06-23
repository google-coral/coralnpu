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
"""Smoke test for the VME (Zvt) non-tile state and mset* instructions.

The companion ELF (`vme_test_program.cc`) iterates over an input table written
into memory by this harness, executes msetmtype/msettn/msettm/msettk on each
row, and records the resulting mtype CSR value and rd writebacks into a
matching result table. This bench writes the input table, runs the program,
reads the results, and asserts per-row expected values.

The fifth instruction in the family, msetmtypei, has its operands encoded as
immediates, so it can't be parameterized from memory. The program runs a
single hard-coded variant and the harness verifies the readback separately.
"""

import cocotb
import numpy as np
from coralnpu_test_utils.core_mini_axi_interface import CoreMiniAxiInterface
from bazel_tools.tools.python.runfiles import runfiles

# struct VmeMsetCase   = 5 x uint32  (mtype, vtype, msettn_avl, msettm, msettk)
# struct VmeMsetResult = 6 x uint32
CASE_WORDS = 5
RESULT_WORDS = 6


def _pack_mtype(tm, tk, mtwiden):
    """Pack tm/tk/mtwiden into the mtype CSR bit layout (Zvt §15.1.1.2)."""
    return ((tm & 0x3FFF) << 10) | ((tk & 0x7) << 5) | (mtwiden & 0x3)


def _build_cases():
    """Test matrix. Each entry is (inputs, expected_results).

    Inputs (5 uint32 each, in struct order): mtype_value, vtype_value,
    msettn_avl, msettm_arg, msettk_arg.

    Expected results (6 uint32 each, in struct order):
      mtype_after_msetmtype, rd_after_msettn,
      rd_after_msettm, mtype_after_msettm,
      rd_after_msettk, mtype_after_msettk.
    """
    return [
        # Case 0: SEW8/LMUL1, mtype = tm=1 / tk=1 / mtwiden=1.
        # vlmax = VLENB >> sew = 16, so msettn(16) = 16.
        # msettm and msettk write their fields verbatim.
        dict(
            inputs=(
                _pack_mtype(tm=1, tk=1, mtwiden=1),  # mtype_value
                0x00,  # vtype: SEW8/LMUL1/vta=0/vma=0
                16,  # msettn avl
                5,  # msettm arg
                2,  # msettk arg
            ),
            expected=(
                _pack_mtype(tm=1, tk=1, mtwiden=1),  # mtype_after_msetmtype
                16,  # rd_after_msettn
                5,  # rd_after_msettm
                _pack_mtype(tm=5, tk=1, mtwiden=1),  # mtype_after_msettm
                2,  # rd_after_msettk
                _pack_mtype(tm=5, tk=2, mtwiden=1),  # mtype_after_msettk
            ),
        ),
        # Case 1: SEW16/LMUL1, vlmax = VLENB/2 = 8. msettn(100) clamps to 8.
        # msettm gets a near-max 14-bit value; msettk gets >3 and clamps to 3
        # (the 2-bit field, matching the literal spec layout we follow).
        dict(
            inputs=(
                _pack_mtype(tm=3, tk=2, mtwiden=2),  # mtype_value
                0x08,  # vtype: SEW16/LMUL1
                100,  # msettn avl  -> clamps to vlmax
                0x3FFF,  # msettm arg  -> stays at 0x3FFF
                10,  # msettk arg  -> clamps to 3
            ),
            expected=(
                _pack_mtype(tm=3, tk=2, mtwiden=2),
                8,
                0x3FFF,
                _pack_mtype(tm=0x3FFF, tk=2, mtwiden=2),
                3,
                _pack_mtype(tm=0x3FFF, tk=3, mtwiden=2),
            ),
        ),
    ]


@cocotb.test()
async def vme_mset_csr_test(dut):
    """Drive a table of mset* operands and check the per-row CSR/rd snapshots."""

    core_mini_axi = CoreMiniAxiInterface(dut)
    await core_mini_axi.init()
    await core_mini_axi.reset()
    cocotb.start_soon(core_mini_axi.clock.start())

    r = runfiles.Create()
    elf_path = r.Rlocation(
        "coralnpu_hw/tests/cocotb/vme_test/vme_test_program.elf"
    )
    if not elf_path:
        raise ValueError("Could not find ELF file. Build the target first.")

    with open(elf_path, "rb") as f:
        entry_point = await core_mini_axi.load_elf(f)

    with open(elf_path, "rb") as f:
        num_cases_addr = core_mini_axi.lookup_symbol(f, "vme_num_cases")
        inputs_addr = core_mini_axi.lookup_symbol(f, "vme_inputs")
        results_addr = core_mini_axi.lookup_symbol(f, "vme_results")
        msetmtypei_addr = core_mini_axi.lookup_symbol(
            f, "vme_msetmtypei_result"
        )

    cases = _build_cases()
    num_cases = len(cases)

    # Pack inputs and push them into the program's input table.
    inputs_packed = np.array([c["inputs"] for c in cases],
                             dtype=np.uint32).flatten()
    await core_mini_axi.write(inputs_addr, inputs_packed)
    await core_mini_axi.write(
        num_cases_addr, np.array([num_cases], dtype=np.uint32)
    )

    await core_mini_axi.execute_from(entry_point)
    await core_mini_axi.wait_for_halted()

    # Pull results back: num_cases rows of RESULT_WORDS uint32 each.
    raw = await core_mini_axi.read(results_addr, num_cases * RESULT_WORDS * 4)
    results = np.frombuffer(
        raw, dtype=np.uint32
    ).reshape(num_cases, RESULT_WORDS)

    field_names = [
        "mtype_after_msetmtype",
        "rd_after_msettn",
        "rd_after_msettm",
        "mtype_after_msettm",
        "rd_after_msettk",
        "mtype_after_msettk",
    ]
    for i, case in enumerate(cases):
        expected = case["expected"]
        actual = [int(x) for x in results[i]]
        cocotb.log.info(f"[VME case {i}] inputs={case['inputs']}")
        for name, exp, act in zip(field_names, expected, actual):
            cocotb.log.info(
                f"  {name:<22s} expected=0x{exp:08x} actual=0x{act:08x}"
            )
        for name, exp, act in zip(field_names, expected, actual):
            assert act == exp, (
                f"case {i} field `{name}` mismatch: "
                f"got 0x{act:08x}, expected 0x{exp:08x}"
            )

    # msetmtypei is single-shot (immediates can't be parameterized from memory).
    raw = await core_mini_axi.read(msetmtypei_addr, 4)
    msetmtypei_result = int(np.frombuffer(raw, dtype=np.uint32)[0])
    EXPECTED_MTYPE_AFTER_MSETMTYPEI = 3  # mtwiden=3, tk=0, tm=0
    cocotb.log.info(
        f"[VME msetmtypei] expected=0x{EXPECTED_MTYPE_AFTER_MSETMTYPEI:08x} "
        f"actual=0x{msetmtypei_result:08x}"
    )
    assert msetmtypei_result == EXPECTED_MTYPE_AFTER_MSETMTYPEI, (
        f"msetmtypei mtype mismatch: got 0x{msetmtypei_result:08x}, "
        f"expected 0x{EXPECTED_MTYPE_AFTER_MSETMTYPEI:08x}"
    )

    cocotb.log.info(
        f"[VME] ✓ All {num_cases} parameterized cases + msetmtypei passed"
    )
