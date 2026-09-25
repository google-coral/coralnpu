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
from coralnpu_test_utils.sim_backends.verilator_test_fixture import VerilatorTestFixture
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
        # Case 1: SEW16 with mtwiden=2 derives LMUL=2 (vlmax = 2 * (VLENB/2) = 16).
        # msettn(100) clamps to 16 (previously was 8 when LMUL was not derived).
        # msettm(0x3FFF) clamps to TE=16; msettk(10) clamps to KMAX=2 for SEW16.
        dict(
            inputs=(
                _pack_mtype(tm=3, tk=2, mtwiden=2),  # mtype_value
                0x08,  # vtype: SEW16/LMUL1 passed in rs2
                100,  # msettn avl  -> clamps to vlmax (16)
                0x3FFF,  # msettm arg  -> clamps to TE=16
                10,  # msettk arg  -> clamps to KMAX=2
            ),
            expected=(
                _pack_mtype(tm=3, tk=2, mtwiden=2),
                16,
                16,  # rd_after_msettm clamps to 16
                _pack_mtype(tm=16, tk=2, mtwiden=2),
                2,
                _pack_mtype(tm=16, tk=2, mtwiden=2),
            ),
        ),
        # Case 2: SEW32 with mtwiden=1 derives LMUL=4 (vlmax = 4 * (128/32) = 16).
        # Even if LMUL1 is passed in rs2 (vtype=0x10), msetmtype derives LMUL=4.
        # msettn(8) should set rd = vl = min(8, vlmax) = 8.
        dict(
            inputs=(
                0x2021,  # mtype_value: tm=8, tk=1, mtwiden=1
                0x10,  # vtype_value: SEW32, LMUL1 (0x10)
                8,  # msettn avl = 8
                8,  # msettm arg = 8
                1,  # msettk arg = 1
            ),
            expected=(
                0x2021,  # mtype_after_msetmtype
                8,  # rd_after_msettn (must be 8, not 4!)
                8,  # rd_after_msettm
                0x2021,  # mtype_after_msettm
                1,  # rd_after_msettk
                0x2021,  # mtype_after_msettk
            ),
        ),
        # Case 3: SEW32 with LMUL4 clamps to vlmax = 16 for avl >= 16.
        dict(
            inputs=(
                0x2021,  # mtype_value: tm=8, tk=1, mtwiden=1
                0x10,  # vtype_value: SEW32, LMUL1 (0x10)
                100,  # msettn avl = 100 -> clamps to vlmax (16)
                8,  # msettm arg = 8
                1,  # msettk arg = 1
            ),
            expected=(
                0x2021,  # mtype_after_msetmtype
                16,  # rd_after_msettn
                8,  # rd_after_msettm
                0x2021,  # mtype_after_msettm
                1,  # rd_after_msettk
                0x2021,  # mtype_after_msettk
            ),
        ),
        # Case 4: Unconfigured matrix unit (mtwiden=0).
        # mtype is zeroed. vtype retains rs2 (SEW32, LMUL1) as in vsetvl.
        # vlmax = 4. msettn(100) clamps to 4.
        dict(
            inputs=(
                0x0000,  # mtype_value: mtwiden=0
                0x10,  # vtype_value: SEW32, LMUL1
                100,  # msettn avl = 100 -> clamps to vlmax (4)
                0,  # msettm arg
                0,  # msettk arg
            ),
            expected=(
                0x0000,  # mtype_after_msetmtype is 0
                4,  # rd_after_msettn (vlmax=4 under LMUL1)
                0,  # rd_after_msettm
                0x0000,  # mtype_after_msettm
                0,  # rd_after_msettk
                0x0000,  # mtype_after_msettk
            ),
        ),
        # Case 5: SEW8 with mtwiden=3 (TWIDEN=4, TEW=32, KMAX=4).
        # mtype = 0x4083 (tm=16, tk=4, mtwiden=3).
        # msettk(4) should clamp to min(4, KMAX=4) = 4, not 3.
        dict(
            inputs=(
                0x4083,  # mtype_value: tm=16, tk=4, mtwiden=3
                0x00,  # vtype_value: SEW8, LMUL1 (0x00)
                16,  # msettn avl = 16
                16,  # msettm arg = 16
                4,  # msettk arg = 4
            ),
            expected=(
                0x4083,  # mtype_after_msetmtype
                16,  # rd_after_msettn
                16,  # rd_after_msettm
                0x4083,  # mtype_after_msettm
                4,  # rd_after_msettk
                0x4083,  # mtype_after_msettk
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
    fixture = await VerilatorTestFixture.Create(dut)
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
        "opve_invalid_funct3",
        "vfwmacc_vv_vill",
    ]

    r = runfiles.Create()
    elf_path = r.Rlocation(
        "coralnpu_hw/tests/cocotb/vme_test/vme_decode_test.elf"
    )
    fixture = await VerilatorTestFixture.Create(dut)
    await fixture.load_elf_and_lookup_symbols(
        elf_path,
        ["test_fn", "trap_count", "last_mcause", "last_mtval"] + test_names,
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
        last_mtval_val = int.from_bytes(
            (await fixture.read_word("last_mtval")).tobytes(),
            "little",
        )
        assert not fixture.fault(), f"[{name}] Core faulted unexpectedly"
        assert trap_count_val == 1, f"[{name}] Expected 1 trap, got {trap_count_val}"
        assert last_mcause_val == 2, f"[{name}] Expected mcause=2 (illegal), got {last_mcause_val}"
        if name == "vfwmacc_vv_vill":
            opcode = last_mtval_val & 0x7F
            assert opcode == 0x57, (
                f"[{name}] Expected mtval opcode 0x57 (OP-V), but got 0x{opcode:02x} "
                f"(mtval=0x{last_mtval_val:08x}). Round-trip reconstruction corrupted opcode!"
            )
        elif name == "opve_invalid_funct3":
            opcode = last_mtval_val & 0x7F
            assert opcode == 0x77, (
                f"[{name}] Expected mtval opcode 0x77 (OP-VE), but got 0x{opcode:02x} "
                f"(mtval=0x{last_mtval_val:08x})"
            )


@cocotb.test()
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
    fixture = await VerilatorTestFixture.Create(dut)
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


@cocotb.test()
async def vme_transpose_test(dut):
    """Verify 16x16 matrix transposition across EEW8, EEW16, EEW32."""
    test_cases = [
        # EEW8
        {
            "name": "test_transpose_e8_row_to_col",
            "dtype": np.int8
        },
        {
            "name": "test_transpose_e8_col_to_row",
            "dtype": np.int8
        },
        # EEW16
        {
            "name": "test_transpose_e16_row_to_col",
            "dtype": np.int16
        },
        {
            "name": "test_transpose_e16_col_to_row",
            "dtype": np.int16
        },
        # EEW32
        {
            "name": "test_transpose_e32_row_to_col",
            "dtype": np.int32
        },
        {
            "name": "test_transpose_e32_col_to_row",
            "dtype": np.int32
        },
    ]

    test_names = [tc["name"] for tc in test_cases]

    r = runfiles.Create()
    elf_path = r.Rlocation(
        "coralnpu_hw/tests/cocotb/vme_test/vme_transpose_test.elf"
    )
    fixture = await VerilatorTestFixture.Create(dut)
    await fixture.load_elf_and_lookup_symbols(
        elf_path,
        ["test_fn", "trap_count", "last_mcause", "in_buf", "out_buf"] +
        test_names,
    )

    zeros = np.zeros(1024, dtype=np.uint8)

    for tc in tqdm(test_cases, desc="VME transpose tests"):
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
        await fixture.run_to_halt(timeout_cycles=3000)

        trap_count_val = int.from_bytes(
            (await fixture.read_word("trap_count")).tobytes(),
            "little",
        )
        assert not fixture.fault(), f"[{name}] Core faulted unexpectedly"
        assert trap_count_val == 0, f"[{name}] Expected no traps, got {trap_count_val}"

        out = (await fixture.read("out_buf", 1024)).view(dtype)

        # 16x16 matrix transpose verification
        in_mat = in_data[:256].reshape((16, 16))
        expected = in_mat.T.flatten()
        actual = out[:256]

        np.testing.assert_array_equal(
            actual, expected, err_msg=f"[{name}] Output mismatch"
        )


@cocotb.test()
async def vme_msettk_clamp_test(dut):
    """Test msettk clamping and msetmtype tk unpack.

    msettk should set rd and mtype.tk to min(rs1, KMAX).
    For SEW=8, KMAX=4:
      msettk(4) must give tk=4 (the design previously gave 3).
      msettk(7) must clamp to KMAX=4.
    Also tests msetmtype unpack of tk (bits [7:5]).
    """
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

    # Test sequence:
    #   li   x6, 0x4083
    #   li   x9, 0x0
    #   .word 0x82937057              # msetmtype x6, x9 (SEW=8, TWIDEN=4, KMAX=4)
    #   li   x10, 16
    #   .word 0x840575D7              # msettn x11, x10
    #   li   x14, 16
    #   .word 0x841776D7              # msettm x13, x14
    #   li   x16, 4
    #   .word 0x842877D7              # msettk x15, x16
    #   # Expected: vl=tn=16, tm=16, tk=4
    cases = [
        dict(
            inputs=(
                0x4083,  # mtype_value: tm=16, tk=4, mtwiden=3
                0x00,  # vtype_value: SEW8, LMUL1
                16,  # msettn avl
                16,  # msettm arg
                4,  # msettk arg (min(4, 4) = 4)
            ),
            expected=(
                0x4083,  # mtype_after_msetmtype
                16,  # rd_after_msettn
                16,  # rd_after_msettm
                0x4083,  # mtype_after_msettm
                4,  # rd_after_msettk (was 3 in buggy design)
                0x4083,  # mtype_after_msettk
            ),
        ),
        dict(
            inputs=(
                0x4083,  # mtype_value: tm=16, tk=4, mtwiden=3
                0x00,  # vtype_value: SEW8, LMUL1
                16,  # msettn avl
                16,  # msettm arg
                7,  # msettk arg: clamped to KMAX=4
            ),
            expected=(
                0x4083,  # mtype_after_msetmtype
                16,  # rd_after_msettn
                16,  # rd_after_msettm
                0x4083,  # mtype_after_msettm
                4,  # rd_after_msettk: clamped to KMAX=4
                0x4083,  # mtype_after_msettk
            ),
        ),
    ]

    num_cases = len(cases)
    inputs_packed = np.array([c["inputs"] for c in cases],
                             dtype=np.uint32).flatten()
    await core_mini_axi.write(inputs_addr, inputs_packed)
    await core_mini_axi.write(
        num_cases_addr, np.array([num_cases], dtype=np.uint32)
    )

    await core_mini_axi.execute_from(entry_point)
    await core_mini_axi.wait_for_halted()

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
        cocotb.log.info(f"[msettk_clamp case {i}] inputs={case['inputs']}")
        for name, exp, act in zip(field_names, expected, actual):
            cocotb.log.info(
                f"  {name:<22s} expected=0x{exp:08x} actual=0x{act:08x}"
            )
        for name, exp, act in zip(field_names, expected, actual):
            assert act == exp, (
                f"case {i} field `{name}` mismatch: "
                f"got 0x{act:08x}, expected 0x{exp:08x}"
            )

    cocotb.log.info(f"[msettk_clamp] ✓ All {num_cases} test cases passed")


@cocotb.test()
async def vme_msettm_clamp_test(dut):
    """Directed tests for msettm clamping behavior:

    1. Clamping check:
       msetmtype clamps tm to TE=16 (min(rs1, 16)).
       msettm must also clamp to 16.
       Passing msettm(32) or msettm(100) must clamp to 16.

    2. Tile dimension bounds:
       Ensures tm is clamped within hardware tile bounds (TE=16).
    """
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

    # We test:
    # Case 0: msettm(32) -> Should clamp to 16 (just like msetmtype does).
    # Expected: rd_after_msettm = 16, mtype_after_msettm has tm=16.
    cases = [
        dict(
            desc="msettm(32) should clamp to TE=16 (min(32, 16))",
            inputs=(
                0x4083,  # mtype: tm=16, tk=4, mtwiden=3
                0x00,  # vtype: SEW8, LMUL1
                16,  # msettn avl
                32,  # msettm arg = 32
                4,  # msettk arg
            ),
            expected=(
                0x4083,  # mtype_after_msetmtype
                16,  # rd_after_msettn
                16,  # rd_after_msettm: EXPECTED TO CLAMP TO 16
                0x4083,  # mtype_after_msettm: EXPECTED tm=16 (0x4083)
                4,  # rd_after_msettk
                0x4083,  # mtype_after_msettk
            ),
        ),
        dict(
            desc="msettm(100) should clamp to TE=16 (min(100, 16))",
            inputs=(
                0x4083,  # mtype: tm=16, tk=4, mtwiden=3
                0x00,  # vtype: SEW8, LMUL1
                16,  # msettn avl
                100,  # msettm arg = 100
                4,  # msettk arg
            ),
            expected=(
                0x4083,  # mtype_after_msetmtype
                16,  # rd_after_msettn
                16,  # rd_after_msettm: EXPECTED TO CLAMP TO 16
                0x4083,  # mtype_after_msettm: EXPECTED tm=16 (0x4083)
                4,  # rd_after_msettk
                0x4083,  # mtype_after_msettk
            ),
        ),
    ]

    num_cases = len(cases)
    inputs_packed = np.array([c["inputs"] for c in cases],
                             dtype=np.uint32).flatten()
    await core_mini_axi.write(inputs_addr, inputs_packed)
    await core_mini_axi.write(
        num_cases_addr, np.array([num_cases], dtype=np.uint32)
    )

    await core_mini_axi.execute_from(entry_point)
    await core_mini_axi.wait_for_halted()

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
        cocotb.log.info(f"[{case['desc']}]")
        for name, exp, act in zip(field_names, expected, actual):
            cocotb.log.info(
                f"  {name:<22s} expected=0x{exp:08x} actual=0x{act:08x}"
            )
        for name, exp, act in zip(field_names, expected, actual):
            assert act == exp, (
                f"case {i} ({case['desc']}) field `{name}` mismatch: "
                f"got 0x{act:08x}, expected 0x{exp:08x}"
            )


@cocotb.test()
async def vme_msettm_matmul_test(dut):
    """Verifies Matmul execution with msettm.

    When msettm(32) is invoked, M=32 saturates to the hardware maximum
    tile height TE=16, computing a full 16x16 tile update.
    """
    fixture = await _load_matmul_fixture(dut)
    rng = np.random.default_rng(42)

    a = rng.integers(1, 10, MM_ROWS * MM_DIM, dtype=np.uint8)
    b = rng.integers(1, 10, MM_ROWS * MM_DIM, dtype=np.uint8)
    c_init = rng.integers(100, 200, MM_DIM * MM_DIM, dtype=np.uint32)

    case = dict(impl="vtmmu_mt0", signed_a=False, init=1, tm=32, tn=16, tk=3)

    # Expected: tm=32 clamps to 16, computing full C[:16, :16] += A.T @ B.
    expected = _int_matmul_ref(
        a,
        b,
        c_init,
        min(case["tm"], MM_DIM),  # Clamped to 16
        case["tn"],
        case["tk"],
        case["signed_a"],
    )

    actual = await _run_matmul_case(fixture, case, a, b, c_init)

    cocotb.log.info(
        "Checking whether msettm(32) updated the tile accumulator..."
    )
    _check_matmul_result("int8", case, actual, expected)


@cocotb.test()
async def vme_altfmt_test(dut):
    """Test VME altfmt configuration via msetmtype, vtype CSR, and vill/mtwiden=0 handling."""
    core_mini_axi = CoreMiniAxiInterface(dut)
    await core_mini_axi.init()
    await core_mini_axi.reset()
    cocotb.start_soon(core_mini_axi.clock.start())

    r = runfiles.Create()
    elf_path = r.Rlocation(
        "coralnpu_hw/tests/cocotb/vme_test/vme_altfmt_test_program.elf"
    )
    if not elf_path:
        raise ValueError("Could not find ELF file. Build the target first.")

    with open(elf_path, "rb") as f:
        entry_point = await core_mini_axi.load_elf(f)

    with open(elf_path, "rb") as f:
        num_cases_addr = core_mini_axi.lookup_symbol(f, "vme_altfmt_num_cases")
        inputs_addr = core_mini_axi.lookup_symbol(f, "vme_altfmt_inputs")
        results_addr = core_mini_axi.lookup_symbol(f, "vme_altfmt_results")

    # struct VmeAltfmtCase { uint32_t mtype_value; uint32_t vtype_value; };
    # struct VmeAltfmtResult { uint32_t mtype_readback; uint32_t vtype_readback; };
    # vtype CSR Bit Layout (RV32 with VME / Zvt §1.2 & §15.1.1.4):
    #   [31]   : vill
    #   [30:9] : reserved (0)
    #   [8]    : altfmt
    #   [7]    : vma (forced to 1 when mtwiden != 0)
    #   [6]    : vta (forced to 1 when mtwiden != 0)
    #   [5:3]  : vsew (001 for SEW16)
    #   [2:0]  : vlmul (derived as LMUL2 = 001 for SEW16 when mtwiden != 0)
    #
    # Case 0: Normal configuration with altfmt=1:
    #   mtype in rs1: 0x4042 (tm=16, tk=2, mtwiden=2)
    #   vtype in rs2: 0x108 (altfmt=1, sew=16, lmul=1)
    #   Expected mtype: 0x4042
    #   Expected vtype: 0x1C9 (altfmt=1, ma=1, ta=1, sew=16, derived lmul=2)
    #
    # Case 1: Normal configuration with altfmt=0:
    #   mtype in rs1: 0x4042 (tm=16, tk=2, mtwiden=2)
    #   vtype in rs2: 0x008 (altfmt=0, sew=16, lmul=1)
    #   Expected mtype: 0x4042
    #   Expected vtype: 0x0C9 (altfmt=0, ma=1, ta=1, sew=16, derived lmul=2)
    #
    # Case 2: vill edge case (illegal configuration):
    #   mtype: tm=16, tk=4, mtwiden=3 (TWIDEN=4) with sew=16 (0x108, altfmt=1)
    #   SEW16 * TWIDEN4 = 64 > ELEN32 -> vill = 1.
    #   When vill=1, RISC-V vector spec 3.4 requires vtype[31]=1 and vtype[30:0]=0.
    #   So altfmt must be cleared to 0, mtype must be cleared to 0.
    #   Expected mtype: 0x0
    #   Expected vtype: 0x80000000
    #
    # Case 3: unconfigured matrix unit (mtwiden=0):
    #   mtype: 0x0 (mtwiden=0)
    #   vtype in rs2: 0x108 (altfmt=1, sew=16, lmul=0)
    #   When mtwiden == 0, matrix unit is unconfigured, so altfmt should be 0.
    #   Expected mtype: 0x0
    #   Expected vtype: 0x008 (altfmt=0, ma=0, ta=0, sew=16, lmul=1)
    cases = [
        dict(
            desc="altfmt=1 with valid mtwiden=2 (sew=16)",
            mtype=0x4042,
            vtype=0x108,
            expected_mtype=0x4042,
            expected_vtype=0x1C9,
        ),
        dict(
            desc="altfmt=0 with valid mtwiden=2 (sew=16)",
            mtype=0x4042,
            vtype=0x008,
            expected_mtype=0x4042,
            expected_vtype=0x0C9,
        ),
        dict(
            desc="vill edge case: sew=16 with mtwiden=3 (TEW=64 > ELEN=32)",
            mtype=0x4083,
            vtype=0x108,
            expected_mtype=0x0000,
            expected_vtype=0x80000000,
        ),
        dict(
            desc="unconfigured matrix unit (mtwiden=0) clears altfmt",
            mtype=0x0000,
            vtype=0x108,
            expected_mtype=0x0000,
            expected_vtype=0x008,
        ),
    ]

    num_cases = len(cases)
    inputs_packed = np.array([[c["mtype"], c["vtype"]] for c in cases],
                             dtype=np.uint32).flatten()
    await core_mini_axi.write(inputs_addr, inputs_packed)
    await core_mini_axi.write(
        num_cases_addr, np.array([num_cases], dtype=np.uint32)
    )

    await core_mini_axi.execute_from(entry_point)
    await core_mini_axi.wait_for_halted()

    raw = await core_mini_axi.read(results_addr, num_cases * 2 * 4)
    results = np.frombuffer(raw, dtype=np.uint32).reshape(num_cases, 2)

    for i, case in enumerate(cases):
        actual_mtype = int(results[i][0])
        actual_vtype = int(results[i][1])
        cocotb.log.info(
            f"[altfmt case {i}: {case['desc']}]\n"
            f"  mtype expected=0x{case['expected_mtype']:08x} actual=0x{actual_mtype:08x}\n"
            f"  vtype expected=0x{case['expected_vtype']:08x} actual=0x{actual_vtype:08x}"
        )
        assert actual_mtype == case["expected_mtype"], (
            f"case {i} ({case['desc']}) mtype mismatch: "
            f"got 0x{actual_mtype:08x}, expected 0x{case['expected_mtype']:08x}"
        )
        assert actual_vtype == case["expected_vtype"], (
            f"case {i} ({case['desc']}) vtype mismatch: "
            f"got 0x{actual_vtype:08x}, expected 0x{case['expected_vtype']:08x}"
        )

    cocotb.log.info(f"[altfmt] ✓ All {num_cases} test cases passed")


@cocotb.test()
async def vme_vset_mtype_reset_test(dut):
    """Verify vsetvli, vsetivli, and vsetvl instructions clear mtype CSR to zero."""

    core_mini_axi = CoreMiniAxiInterface(dut)
    await core_mini_axi.init()
    await core_mini_axi.reset()
    cocotb.start_soon(core_mini_axi.clock.start())

    r = runfiles.Create()
    elf_path = r.Rlocation(
        "coralnpu_hw/tests/cocotb/vme_test/vme_vset_mtype_reset_test_program.elf"
    )
    if not elf_path:
        raise ValueError("Could not find ELF file. Build the target first.")

    with open(elf_path, "rb") as f:
        entry_point = await core_mini_axi.load_elf(f)

    with open(elf_path, "rb") as f:
        results_addr = core_mini_axi.lookup_symbol(f, "vme_vset_results")

    await core_mini_axi.execute_from(entry_point)
    await core_mini_axi.wait_for_halted()

    # struct VmeResetMtypeResult: 4 x uint32 per case (configured, mtype, vtype, vl)
    num_cases = 3
    words_per_case = 4
    raw = await core_mini_axi.read(
        results_addr, num_cases * words_per_case * 4
    )
    results = np.frombuffer(
        raw, dtype=np.uint32
    ).reshape(num_cases, words_per_case)

    case_names = ["vsetvli", "vsetivli", "vsetvl"]
    for i, name in enumerate(case_names):
        configured_mtype = int(results[i][0])
        actual_mtype = int(results[i][1])
        actual_vtype = int(results[i][2])
        actual_vl = int(results[i][3])
        cocotb.log.info(
            f"[{name}] configured_mtype=0x{configured_mtype:08x}, "
            f"mtype_after=0x{actual_mtype:08x}, vtype=0x{actual_vtype:08x}, vl={actual_vl}"
        )
        assert configured_mtype != 0, f"{name}: configured_mtype unexpectedly zero"
        assert actual_mtype == 0, (
            f"{name} failed to reset mtype to 0: got 0x{actual_mtype:08x}"
        )

    cocotb.log.info(
        "✓ All vset instructions successfully cleared mtype to zero"
    )


@cocotb.test()
async def vme_mset_retire_test(dut):
    """Verify msettm and msettk are handled solely in frontend and not sent to backend.

    Configuration instructions msettm and msettk only update matrix dimension
    state in the front-end and do not generate backend execution commands.
    Verifies that executing msetmtype, msettn, msettm, msettk, and vtzero succeeds
    without taking illegal instruction traps or causing double retirement.
    """
    r = runfiles.Create()
    elf_path = r.Rlocation(
        "coralnpu_hw/tests/cocotb/vme_test/vme_decode_test.elf"
    )
    fixture = await VerilatorTestFixture.Create(dut)
    await fixture.load_elf_and_lookup_symbols(
        elf_path,
        ["test_fn", "trap_count", "last_mcause", "mset_dimension_config"],
    )

    await fixture.write_ptr("test_fn", "mset_dimension_config")
    await fixture.run_to_halt()

    trap_count_val = int.from_bytes(
        (await fixture.read_word("trap_count")).tobytes(),
        "little",
    )
    last_mcause_val = int.from_bytes(
        (await fixture.read_word("last_mcause")).tobytes(),
        "little",
    )
    assert not fixture.fault(), "Core faulted unexpectedly"
    assert trap_count_val == 0, f"Expected 0 traps, got {trap_count_val} (last_mcause={last_mcause_val})"


@cocotb.test()
async def vme_mset_vtmmu_sequence_test(dut):
    """Verify execution of mset configuration, vtzero, and vtmmu sequence.

    Tests sequence: msetmtype (SEW16, altfmt=1), msettn, msettm, msettk, vtzero,
    vector operand moves, and vtmmu matrix multiplies to verify decoding,
    mtype CSR retirement, tile zeroing, and tile matrix accumulation.
    """
    r = runfiles.Create()
    elf_path = r.Rlocation(
        "coralnpu_hw/tests/cocotb/vme_test/vme_mset_vtmmu_sequence_test.elf"
    )
    fixture = await VerilatorTestFixture.Create(dut)
    await fixture.load_elf_and_lookup_symbols(elf_path, [])
    await fixture.run_to_halt()

    assert not fixture.fault(), "Core faulted unexpectedly"


@cocotb.test()
async def vme_mstatus_ms_test(dut):
    """Verify mstatus.MS state transitions, SD calculation, and MS==Off trap gating."""
    r = runfiles.Create()
    elf_path = r.Rlocation(
        "coralnpu_hw/tests/cocotb/vme_test/vme_mstatus_ms_test.elf"
    )
    fixture = await VerilatorTestFixture.Create(dut)

    ms_off_trap_tests = [
        "ms_off_vtle",
        "ms_off_vtse",
        "ms_off_vtzero",
        "ms_off_vtmv_v_t",
        "ms_off_vtmv_t_v",
        "ms_off_vtmmu",
        "ms_off_vtdiscard",
        "vill1_vtdiscard",
    ]

    await fixture.load_elf_and_lookup_symbols(
        elf_path,
        [
            "test_fn", "trap_count", "last_mcause", "last_mtval",
            "mstatus_val", "mstatus_ms_transitions", "ms_off_mset_allowed"
        ] + ms_off_trap_tests,
    )

    # 1. Verify MS == Off illegal instruction trap behavior
    for name in tqdm(ms_off_trap_tests, desc="mstatus.MS Off trap tests"):
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

    # Also verify that non-tile instructions (mset*) do NOT trap when MS == Off
    await fixture.write_ptr("test_fn", "ms_off_mset_allowed")
    await fixture.run_to_halt()
    trap_count_val = int.from_bytes(
        (await fixture.read_word("trap_count")).tobytes(),
        "little",
    )
    assert not fixture.fault(
    ), "[ms_off_mset_allowed] Core faulted unexpectedly"
    assert trap_count_val == 0, f"[ms_off_mset_allowed] Expected 0 traps, got {trap_count_val}"

    # 2. Verify mstatus.MS state transitions
    await fixture.write_ptr("test_fn", "mstatus_ms_transitions")
    await fixture.run_to_halt()

    trap_count_val = int.from_bytes(
        (await fixture.read_word("trap_count")).tobytes(),
        "little",
    )
    assert not fixture.fault(), "Core faulted unexpectedly"
    assert trap_count_val == 0, f"Expected 0 traps, got {trap_count_val}"

    # Read the 5 recorded mstatus values (5 * 4 = 20 bytes)
    raw_bytes = (await fixture.read("mstatus_val", 20)).tobytes()
    mstatus_words = [
        int.from_bytes(raw_bytes[i * 4:(i + 1) * 4], "little")
        for i in range(5)
    ]

    for idx, w in enumerate(mstatus_words):
        cocotb.log.info(
            f"mstatus_words[{idx}] = 0x{w:08x} (SD={w>>31}, MS={(w>>29)&3}, FS={(w>>13)&3}, VS={(w>>9)&3})"
        )

    # Step 0: Initial state: MS = 2'b01 (Initial), SD = 0
    ms_step0 = (mstatus_words[0] >> 29) & 0x3
    sd_step0 = (mstatus_words[0] >> 31) & 0x1
    assert ms_step0 == 1, f"Step 0: Expected MS=1 (Initial), got {ms_step0}"
    assert sd_step0 == 0, f"Step 0: Expected SD=0, got {sd_step0}"

    # Step 1: After vtzero: MS = 2'b11 (Dirty), SD = 1
    ms_step1 = (mstatus_words[1] >> 29) & 0x3
    sd_step1 = (mstatus_words[1] >> 31) & 0x1
    assert ms_step1 == 3, f"Step 1: Expected MS=3 (Dirty), got {ms_step1}"
    assert sd_step1 == 1, f"Step 1: Expected SD=1, got {sd_step1}"

    # Step 2: After write MS=Clean (2'b10): MS = 2'b10 (Clean), SD = 0
    ms_step2 = (mstatus_words[2] >> 29) & 0x3
    sd_step2 = (mstatus_words[2] >> 31) & 0x1
    assert ms_step2 == 2, f"Step 2: Expected MS=2 (Clean), got {ms_step2}"
    assert sd_step2 == 0, f"Step 2: Expected SD=0, got {sd_step2}"

    # Step 3: After vtdiscard: MS = 2'b01 (Initial), SD = 0
    ms_step3 = (mstatus_words[3] >> 29) & 0x3
    sd_step3 = (mstatus_words[3] >> 31) & 0x1
    assert ms_step3 == 1, f"Step 3: Expected MS=1 (Initial), got {ms_step3}"
    assert sd_step3 == 0, f"Step 3: Expected SD=0, got {sd_step3}"

    # Step 4: After write MS=Off (2'b00): MS = 2'b00 (Off), SD = 0
    ms_step4 = (mstatus_words[4] >> 29) & 0x3
    sd_step4 = (mstatus_words[4] >> 31) & 0x1
    assert ms_step4 == 0, f"Step 4: Expected MS=0 (Off), got {ms_step4}"
    assert sd_step4 == 0, f"Step 4: Expected SD=0, got {sd_step4}"

    cocotb.log.info("✓ mstatus.MS transitions verified successfully")
