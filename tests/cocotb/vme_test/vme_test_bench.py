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
from coralnpu_test_utils.sim_test_fixture import Fixture
from bazel_tools.tools.python.runfiles import runfiles
from tqdm import tqdm

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


# -----------------------------------------------------------------------------
# Matrix arithmetic tests (vtmmu/vtmms/vtfmm + vtzero + vtmv moves).
#
# The companion ELF (`vme_matmul_test_program.cc`) runs one case per
# run_to_halt: it initializes an accumulator tile (vtzero, or a preload of
# `mm_c_init` through vtmv.t.v), loads A/B operand rows into vector registers
# with ordinary vle, executes one matmul, and reads the 16x16 tile back into
# `mm_out` via vtmv.v.t + vse32. All tile accesses are register-to-register.
# -----------------------------------------------------------------------------

MM_DIM = 16  # TE at VLEN=128
MM_ROWS = 4  # A/B row slots in the program's operand buffers

_MM_IMPLS = ["vtmmu_mt0", "vtmmu_mt4", "vtmms_mt0", "vtfmm_mt0", "vtfmm_mt8"]
_MM_SYMBOLS = [
    "mm_a",
    "mm_b",
    "mm_c_init",
    "mm_out",
    "mm_tm",
    "mm_tn",
    "mm_tk",
    "mm_init_mode",
    "mm_impl",
] + _MM_IMPLS


async def _load_matmul_fixture(dut):
    fixture = await Fixture.Create(dut)
    r = runfiles.Create()
    elf_path = r.Rlocation(
        "coralnpu_hw/tests/cocotb/vme_test/vme_matmul_test_program.elf"
    )
    if not elf_path:
        raise ValueError("Could not find ELF file. Build the target first.")
    await fixture.load_elf_and_lookup_symbols(elf_path, _MM_SYMBOLS)
    return fixture


async def _run_matmul_case(fixture, case, a, b, c_init):
    """Write one case's inputs, run to halt, and return mm_out as uint32."""
    await fixture.write("mm_a", a)
    await fixture.write("mm_b", b)
    await fixture.write("mm_c_init", c_init)
    await fixture.write_word("mm_tm", case["tm"])
    await fixture.write_word("mm_tn", case["tn"])
    await fixture.write_word("mm_tk", case.get("tk", 1))
    await fixture.write_word("mm_init_mode", case["init"])
    # Clear the output buffer so stale data from a previous case can't pass.
    await fixture.write("mm_out", np.zeros(MM_DIM * MM_DIM, dtype=np.uint32))
    await fixture.write_ptr("mm_impl", case["impl"])
    await fixture.run_to_halt(timeout_cycles=100000)
    raw = await fixture.read("mm_out", MM_DIM * MM_DIM * 4)
    return np.frombuffer(raw, dtype=np.uint32).reshape(MM_DIM, MM_DIM)


def _check_matmul_result(name, case, actual, expected):
    mism = np.argwhere(actual != expected)
    if mism.size:
        rows = "\n".join(
            f"  [{m},{n}] expected=0x{expected[m, n]:08x} actual=0x{actual[m, n]:08x}"
            for m, n in mism[:16]
        )
        raise AssertionError(
            f"{name} case {case}: {len(mism)} mismatching tile elements "
            f"(first {min(len(mism), 16)}):\n{rows}"
        )
    cocotb.log.info(f"[VME matmul] ✓ {name} {case}")


def _int_matmul_ref(a, b, c_init, tm, tn, tk, signed_a):
    """C[:tm,:tn] += castA(A[:tk,:tm]).T @ uint8(B[:tk,:tn]), int32 wraparound.

    B is always unsigned here: vtype.altfmt (which would make B signed) is not
    settable in the current RTL.
    """
    a_rows = a.reshape(MM_ROWS, MM_DIM)
    b_rows = b.reshape(MM_ROWS, MM_DIM)
    a_cast = (a_rows.astype(np.int8) if signed_a else a_rows).astype(np.int64)
    b_cast = b_rows.astype(np.int64)
    ref = c_init.astype(np.int64).reshape(MM_DIM, MM_DIM).copy()
    ref[:tm, :tn] += a_cast[:tk, :tm].T @ b_cast[:tk, :tn]
    return (ref & 0xFFFFFFFF).astype(np.uint32)


def _fp_matmul_ref(a, b, c_init, tm, tn):
    """C[:tm,:tn] += outer(A[:tm], B[:tn]) in fp32 (tk=1 for SEW32)."""
    a_row = a.view(np.float32)[:MM_DIM]
    b_row = b.view(np.float32)[:MM_DIM]
    ref = c_init.view(np.float32).reshape(MM_DIM, MM_DIM).copy()
    ref[:tm, :tn] += np.outer(a_row[:tm], b_row[:tn]).astype(np.float32)
    return ref.view(np.uint32)


@cocotb.test()
async def vme_matmul_int8_test(dut):
    """vtmmu/vtmms int8 outer-product accumulate into an int32 tile."""
    fixture = await _load_matmul_fixture(dut)
    rng = np.random.default_rng(42)

    cases = [
        # vtzero-initialized full-tile multiply, max configurable tk.
        dict(impl="vtmmu_mt0", signed_a=False, init=0, tm=16, tn=16, tk=3),
        # Accumulate onto a preloaded tile (exercises vtmv.t.v), tile mt4.
        dict(impl="vtmmu_mt4", signed_a=False, init=1, tm=16, tn=16, tk=2),
        # Signed A operand.
        dict(impl="vtmms_mt0", signed_a=True, init=1, tm=16, tn=16, tk=3),
        # Tail case: elements outside [0,tm)x[0,tn) must keep their preload.
        dict(impl="vtmms_mt0", signed_a=True, init=1, tm=5, tn=7, tk=3),
        # tk=1 single-row dot product.
        dict(impl="vtmmu_mt0", signed_a=False, init=1, tm=16, tn=16, tk=1),
    ]

    for case in cases:
        # Full random operand buffers: row slots >= tk and elements >= tm/tn
        # carry garbage the hardware must mask off.
        a = rng.integers(0, 256, MM_ROWS * MM_DIM, dtype=np.uint8)
        b = rng.integers(0, 256, MM_ROWS * MM_DIM, dtype=np.uint8)
        c_init = rng.integers(0, 1 << 32, MM_DIM * MM_DIM, dtype=np.uint32)
        expected = _int_matmul_ref(
            a,
            b,
            c_init if case["init"] else np.zeros_like(c_init),
            case["tm"],
            case["tn"],
            case["tk"],
            case["signed_a"],
        )
        actual = await _run_matmul_case(fixture, case, a, b, c_init)
        _check_matmul_result("int8", case, actual, expected)


@cocotb.test()
async def vme_matmul_fp32_test(dut):
    """vtfmm fp32 outer-product accumulate into an fp32 tile."""
    fixture = await _load_matmul_fixture(dut)
    rng = np.random.default_rng(1234)

    cases = [
        dict(impl="vtfmm_mt0", init=0, tm=16, tn=16),
        # Accumulate + tail on tile mt8.
        dict(impl="vtfmm_mt8", init=1, tm=9, tn=11),
    ]

    for case in cases:
        # Small integer-valued floats: products and sums are exact in fp32,
        # so the numpy reference matches bit-for-bit regardless of rounding.
        a = (rng.integers(-8, 9, MM_DIM).astype(np.float32).view(np.uint8))
        b = (rng.integers(-8, 9, MM_DIM).astype(np.float32).view(np.uint8))
        c_init = (
            rng.integers(-100, 101,
                         MM_DIM * MM_DIM).astype(np.float32).view(np.uint32)
        )
        expected = _fp_matmul_ref(
            a,
            b,
            c_init if case["init"] else np.zeros_like(c_init),
            case["tm"],
            case["tn"],
        )
        actual = await _run_matmul_case(fixture, case, a, b, c_init)
        _check_matmul_result("fp32", case, actual, expected)


@cocotb.test()
async def vme_decode_test(dut):
    """Load and run vme_decode_test to verify illegal instruction trap behavior."""
    test_names = [
        "vtle64",
        "vtse64",
        "vtle_invalid_nf100",
        "vtse_invalid_nf100",
        "vtle_invalid_nf111",
        "vtse_invalid_nf111",
        "vtle8_masked_vm0",
        "vtse8_masked_vm0",
        "vtle8_nonzero_vd_vs3",
        "vtse8_nonzero_vd_vs3",
        "vtle8_nonzero_mop10",
        "vtse8_nonzero_mop01",
        "mew0_width7_load",
        "mew0_width7_store",
        "vill1_load",
        "vill1_store",
    ]

    r = runfiles.Create()
    elf_path = r.Rlocation(
        "coralnpu_hw/tests/cocotb/vme_test/vme_decode_test.elf"
    )
    fixture = await Fixture.Create(dut)
    await fixture.load_elf_and_lookup_symbols(
        elf_path,
        ["test_fn", "trap_count", "last_mcause"] + test_names,
    )

    for name in tqdm(test_names, desc="VME decode tests"):
        await fixture.write_ptr("test_fn", name)
        await fixture.run_to_halt()

        trap_count_val = int.from_bytes(
            (await fixture.read_word("trap_count")).tobytes(),
            "little",
        )
        last_mcause_val = int.from_bytes(
            (await fixture.read_word("last_mcause")).tobytes(),
            "little",
        )
        assert not fixture.fault(), f"[{name}] Core faulted unexpectedly"
        assert trap_count_val == 1, f"[{name}] Expected 1 trap, got {trap_count_val}"
        assert last_mcause_val == 2, f"[{name}] Expected mcause=2 (illegal), got {last_mcause_val}"


@cocotb.test(expect_fail=True)
async def vme_load_store_test(dut):
    """Load and run valid vtle and vtse instructions, verifying memory."""
    vlen = 128
    vl = vlen // 8  # Assuming TE = VLEN / 8 = 16 elements

    test_cases = [
        # EEW8
        {
            "name": "test_vtle8_row",
            "dtype": np.int8
        },
        {
            "name": "test_vtle8_col",
            "dtype": np.int8
        },
        {
            "name": "test_vtse8_row",
            "dtype": np.int8
        },
        {
            "name": "test_vtse8_col",
            "dtype": np.int8
        },
        # EEW16
        {
            "name": "test_vtle16_row",
            "dtype": np.int16
        },
        {
            "name": "test_vtle16_col",
            "dtype": np.int16
        },
        {
            "name": "test_vtse16_row",
            "dtype": np.int16
        },
        {
            "name": "test_vtse16_col",
            "dtype": np.int16
        },
        # EEW32
        {
            "name": "test_vtle32_row",
            "dtype": np.int32
        },
        {
            "name": "test_vtle32_col",
            "dtype": np.int32
        },
        {
            "name": "test_vtse32_row",
            "dtype": np.int32
        },
        {
            "name": "test_vtse32_col",
            "dtype": np.int32
        },
        # Roundtrip (Direct Memory <-> Tile)
        {
            "name": "test_roundtrip_e8_row",
            "dtype": np.int8
        },
        {
            "name": "test_roundtrip_e8_col",
            "dtype": np.int8
        },
        {
            "name": "test_roundtrip_e16_row",
            "dtype": np.int16
        },
        {
            "name": "test_roundtrip_e16_col",
            "dtype": np.int16
        },
        {
            "name": "test_roundtrip_e32_row",
            "dtype": np.int32
        },
        {
            "name": "test_roundtrip_e32_col",
            "dtype": np.int32
        },
    ]

    test_names = [tc["name"] for tc in test_cases]

    r = runfiles.Create()
    elf_path = r.Rlocation(
        "coralnpu_hw/tests/cocotb/vme_test/vme_load_store_test.elf"
    )
    fixture = await Fixture.Create(dut)
    await fixture.load_elf_and_lookup_symbols(
        elf_path,
        ["test_fn", "trap_count", "last_mcause", "in_buf", "out_buf"] +
        test_names,
    )

    zeros = np.zeros(1024, dtype=np.uint8)

    for tc in tqdm(test_cases, desc="VME load store tests"):
        name = tc["name"]
        dtype = tc["dtype"]

        iinfo = np.iinfo(dtype)
        num_elements = 1024 // np.dtype(dtype).itemsize
        in_data = np.random.randint(
            iinfo.min, iinfo.max + 1, size=num_elements, dtype=dtype
        )

        await fixture.write("in_buf", in_data)
        await fixture.write("out_buf", zeros)

        await fixture.write_ptr("test_fn", name)
        await fixture.run_to_halt()

        trap_count_val = int.from_bytes(
            (await fixture.read_word("trap_count")).tobytes(),
            "little",
        )
        assert not fixture.fault(), f"[{name}] Core faulted unexpectedly"
        assert trap_count_val == 0, f"[{name}] Expected no traps, got {trap_count_val}"

        out = (await fixture.read("out_buf", 1024)).view(dtype)

        expected = in_data[:vl]
        actual = out[:vl]

        np.testing.assert_array_equal(
            actual, expected, err_msg=f"[{name}] Output mismatch"
        )
