import cocotb
import itertools
import numpy as np
import tqdm
from coralnpu_test_utils.core_mini_axi_interface import CoreMiniAxiInterface
from coralnpu_test_utils.rvv_type_util import construct_vtype, DTYPE_TO_SEW, SEWS, SEW_TO_LMULS_AND_VLMAXS, LMUL_TO_EMUL
from coralnpu_test_utils.sim_test_fixture import Fixture
from bazel_tools.tools.python.runfiles import runfiles

SEWS = [
    0b000,  # SEW8
    0b001,  # SEW16
    0b010,  # SEW32
]

# See 3.4.2. Vector Register Grouping of RVV Spec
LMULS = [
    0b100,  # Reserved
    0b101,  # LMUL1/8
    0b110,  # LMUL1/4
    0b111,  # LMUL1/2
    0b000,  # LMUL1
    0b001,  # LMUL2
    0b010,  # LMUL4
    0b011,  # LMUL8
]

def _illegal_vtype(sew, lmul):
    # SEW must be SEW8,16,32. Others are illegal
    if not ((sew == 0b000) or (sew == 0b001) or (sew == 0b010)):
      return True

    # Reserved or LMUL=1/8 always illegal
    if (lmul == 0b100) or (lmul == 0b101):
      return True

    # LMUL=1/4 is illegal for SEW16 and SEW32
    if (sew != 0b000) and (lmul == 0b110):
      return True

    # LMUL=1/2 is illegal for SEW32
    if (sew == 0b010) and (lmul == 0b111):
      return True

    return False


@cocotb.test()
async def core_mini_rvv_load(dut):
    """Testbench to test RVV load intrinsics.

    This test loads 16 bytes of data and read back from the input address.
    Todo: update the test with store unit.
    """
    # Test bench setup
    core_mini_axi = CoreMiniAxiInterface(dut)
    await core_mini_axi.init()
    await core_mini_axi.reset()
    cocotb.start_soon(core_mini_axi.clock.start())
    r = runfiles.Create()

    elf_path = r.Rlocation("coralnpu_hw/tests/cocotb/rvv/rvv_load.elf")
    num_test_bytes = 16
    intial_pass = True
    if not elf_path:
        raise ValueError("elf_path must consist a valid path")
    with open(elf_path, "rb") as f:
        entry_point = await core_mini_axi.load_elf(f)

    #Write your program inputs
    with open(elf_path, "rb") as f:
        input_1_addr = core_mini_axi.lookup_symbol(f, "input_1")
        output_1_addr = core_mini_axi.lookup_symbol(f, "output_1")

    for data_type in [np.int8, np.int16, np.int32]:

        num_bytes = np.dtype(data_type).itemsize
        min_value = np.iinfo(data_type).min
        max_value = np.iinfo(data_type).max
        num_values = int(num_test_bytes / num_bytes)
        input_1_data = np.random.randint(min_value, max_value, num_values, dtype=data_type)
        await core_mini_axi.write(input_1_addr, input_1_data)
        if intial_pass:
            intial_pass = False
            await core_mini_axi.execute_from(entry_point)

        await core_mini_axi.wait_for_wfi()
        routputs = (await core_mini_axi.read(input_1_addr, num_test_bytes)).view(data_type)
        print(f"loaded inputs are {routputs}", flush=True)
        print(f" number of values supposed to be printed {num_values}", flush=True)
        await core_mini_axi.raise_irq()
    await core_mini_axi.wait_for_halted()


@cocotb.test()
async def core_mini_rvv_add(dut):
    """Testbench to test RVV add intrinsics.

    This test loads 16 bytes of data from each input buffer and saved result into a register.

    Todo: update the test with store unit.
    """
    # Test bench setup
    core_mini_axi = CoreMiniAxiInterface(dut)
    await core_mini_axi.init()
    await core_mini_axi.reset()
    cocotb.start_soon(core_mini_axi.clock.start())
    r = runfiles.Create()

    elf_path = r.Rlocation("coralnpu_hw/tests/cocotb/rvv/rvv_add.elf")
    num_test_bytes = 16
    intial_pass = True

    if not elf_path:
      raise ValueError("elf_path must consist a valid path ")
    with open(elf_path, "rb") as f:
      entry_point = await core_mini_axi.load_elf(f)

    #Write your program inputs
    with open(elf_path, "rb") as f:
      input_1_addr = core_mini_axi.lookup_symbol(f, "input_1")
      input_2_addr = core_mini_axi.lookup_symbol(f, "input_2")
      output_1_addr = core_mini_axi.lookup_symbol(f, "output_1")

    # todo ,np.uint8, np.uint16, np.uint32
    for data_type in [np.int8, np.int16, np.int32]:

        num_bytes = np.dtype(data_type).itemsize
        min_value = np.iinfo(data_type).min
        max_value = np.iinfo(data_type).max
        num_values = int(num_test_bytes / num_bytes)
        input_1_data = np.random.randint(min_value, max_value, num_values, dtype=data_type)
        input_2_data = np.random.randint(min_value, max_value, num_values, dtype=data_type)

        await core_mini_axi.write(input_1_addr, input_1_data)
        if intial_pass:
            intial_pass = False
            await core_mini_axi.execute_from(entry_point)
        await core_mini_axi.wait_for_wfi()
        routputs = (await core_mini_axi.read(input_1_addr, num_test_bytes)).view(data_type)
        print(f"loaded inputs are {routputs}", flush=True)
        routputs2 = (await core_mini_axi.read(input_1_addr, num_test_bytes)).view(data_type)
        print(f"loaded inputs are {routputs2}", flush=True)
        print(f" number of values supposed to be printed {num_values}", flush=True)
        await core_mini_axi.raise_irq()
    await core_mini_axi.wait_for_halted()


@cocotb.test()
async def core_mini_vstart_store(dut):
    """Testbench to test vstart store.
    """
    # Test bench setup
    core_mini_axi = CoreMiniAxiInterface(dut)
    await core_mini_axi.init()
    await core_mini_axi.reset()
    cocotb.start_soon(core_mini_axi.clock.start())
    r = runfiles.Create()

    elf_path = r.Rlocation("coralnpu_hw/tests/cocotb/rvv/vstart_store.elf")
    if not elf_path:
        raise ValueError("elf_path must consist a valid path")
    with open(elf_path, "rb") as f:
        entry_point = await core_mini_axi.load_elf(f)

    #Write your program inputs
    with open(elf_path, "rb") as f:
        input_addr = core_mini_axi.lookup_symbol(f, "input_data")
        output_addr = core_mini_axi.lookup_symbol(f, "output_data")

    input_data = np.random.randint(
        np.iinfo(np.uint8).min, np.iinfo(np.uint8).max, 16, dtype=np.uint8)
    await core_mini_axi.write(input_addr, input_data)
    await core_mini_axi.write(output_addr, np.zeros(16, dtype=np.uint8))

    await core_mini_axi.execute_from(entry_point)
    await core_mini_axi.wait_for_wfi()

    output_data = (await core_mini_axi.read(output_addr, 16)).view(np.uint8)

    # vstart is 4, so first 4 elements are skipped.
    # 12 elements are stored.
    assert np.array_equal(output_data[0:4], np.zeros(4, dtype=np.uint8))
    assert np.array_equal(output_data[4:], input_data[4:])

    await core_mini_axi.raise_irq()
    await core_mini_axi.wait_for_halted()


@cocotb.test()
async def core_mini_vcsr_test(dut):
    """Testbench to test vcsr is set correctly."""
    # Test bench setup
    core_mini_axi = CoreMiniAxiInterface(dut)
    await core_mini_axi.init()
    await core_mini_axi.reset()
    cocotb.start_soon(core_mini_axi.clock.start())
    r = runfiles.Create()

    elf_path = r.Rlocation("coralnpu_hw/tests/cocotb/rvv/vcsr_test.elf")
    if not elf_path:
        raise ValueError("elf_path must consist a valid path")
    with open(elf_path, "rb") as f:
        entry_point = await core_mini_axi.load_elf(f)
        vma_addr = core_mini_axi.lookup_symbol(f, "vma")
        vta_addr = core_mini_axi.lookup_symbol(f, "vta")
        sew_addr = core_mini_axi.lookup_symbol(f, "sew")
        lmul_addr = core_mini_axi.lookup_symbol(f, "lmul")
        vl_addr = core_mini_axi.lookup_symbol(f, "vl")
        vtype_addr = core_mini_axi.lookup_symbol(f, "vtype")

    combined_loops = itertools.product(range(2), range(2), SEWS, LMULS)
    total_loops = 2 * 2 * len(SEWS) * len(LMULS)
    with tqdm.tqdm(combined_loops, total=total_loops) as t:
        for ma, ta, sew, lmul in t:
            t.set_postfix(
                {'ma': ma, 'ta': ta, 'sew': bin(sew), 'lmul': bin(lmul) })
            await core_mini_axi.write_word(vma_addr, ma)
            await core_mini_axi.write_word(vta_addr, ta)
            await core_mini_axi.write_word(sew_addr, sew)
            await core_mini_axi.write_word(lmul_addr, lmul)
            # TODO(derekjchow): Pick random VL
            await core_mini_axi.write_word(vl_addr, 1)

            await core_mini_axi.execute_from(entry_point)
            await core_mini_axi.wait_for_halted()

            vtype_result = (
                await core_mini_axi.read_word(vtype_addr)).view(np.uint32)[0]

            # Check if vtype is legal
            expected_illegal = _illegal_vtype(sew, lmul)
            result_illegal = (vtype_result & (1 << 31)) >> 31
            assert (expected_illegal == result_illegal)

            ma_result = (vtype_result & (1 << 7)) >> 7
            ta_result = (vtype_result & (1 << 6)) >> 6
            sew_result = (vtype_result & (0b111 << 3)) >> 3
            lmul_result = (vtype_result & 0b111)

            if expected_illegal:
                assert (ma_result == 0)
                assert (ta_result == 0)
                assert (sew_result == 0)
                assert (lmul_result == 0)
            else:
                assert (ma == ma_result)
                assert (ta == ta_result)
                assert (sew == sew_result)
                assert (lmul == lmul_result)


async def test_vstart_not_zero_failure(dut, binary):
    core_mini_axi = CoreMiniAxiInterface(dut)
    await core_mini_axi.init()
    await core_mini_axi.reset()
    cocotb.start_soon(core_mini_axi.clock.start())
    r = runfiles.Create()

    elf_path = r.Rlocation(binary)
    if not elf_path:
        raise ValueError("elf_path must consist a valid path")
    with open(elf_path, "rb") as f:
        entry_point = await core_mini_axi.load_elf(f)
        vma_addr = core_mini_axi.lookup_symbol(f, "vma")
        vta_addr = core_mini_axi.lookup_symbol(f, "vta")
        sew_addr = core_mini_axi.lookup_symbol(f, "sew")
        lmul_addr = core_mini_axi.lookup_symbol(f, "lmul")
        vl_addr = core_mini_axi.lookup_symbol(f, "vl")
        vstart_addr = core_mini_axi.lookup_symbol(f, "vstart")
        faulted_addr = core_mini_axi.lookup_symbol(f, "faulted")
        mcause_addr = core_mini_axi.lookup_symbol(f, "mcause")

    for ma in range(2):
      for ta in range(2):
        for sew in SEWS:
          for lmul in LMULS:
            vl = 4 # TODO(derekjchow): Pick random VL
            vstart = 1 # Non-zero to trigger failure

            await core_mini_axi.write_word(vma_addr, ma)
            await core_mini_axi.write_word(vta_addr, ta)
            await core_mini_axi.write_word(sew_addr, sew)
            await core_mini_axi.write_word(lmul_addr, lmul)
            await core_mini_axi.write_word(vl_addr, vl)
            await core_mini_axi.write_word(vstart_addr, vstart)

            await core_mini_axi.execute_from(entry_point)
            await core_mini_axi.wait_for_halted()

            faulted_result = (
                await core_mini_axi.read_word(faulted_addr)).view(np.uint32)[0]
            assert (faulted_result == 1)
            mcause_result = (
                await core_mini_axi.read_word(mcause_addr)).view(np.uint32)[0]
            assert (mcause_result == 0x2)


@cocotb.test()
async def core_mini_viota_test(dut):
    """Testbench to test vstart!=0 viota."""
    await test_vstart_not_zero_failure(
        dut, "coralnpu_hw/tests/cocotb/rvv/viota_test.elf")


@cocotb.test()
async def core_mini_vfirst_test(dut):
    """Testbench to test vstart!=0 vfirst."""
    await test_vstart_not_zero_failure(
        dut, "coralnpu_hw/tests/cocotb/rvv/vfirst_test.elf")


@cocotb.test()
async def core_mini_vcpop_exception_test(dut):
    """Testbench to test vstart!=0 vcpop."""
    await test_vstart_not_zero_failure(
        dut, "coralnpu_hw/tests/cocotb/rvv/vcpop_exception_test.elf")


@cocotb.test()
async def core_mini_vcpop_test(dut):
    """Test vcpop usage accessible from intrinsics."""
    # mask is not accessible from here.
    fixture = await Fixture.Create(dut)
    r = runfiles.Create()
    cases = [
        {'impl': 'vcpop_m_b1', 'vl': 128},
        {'impl': 'vcpop_m_b1', 'vl': 121},
        {'impl': 'vcpop_m_b1', 'vl': 120},
        {'impl': 'vcpop_m_b2', 'vl': 64},
        {'impl': 'vcpop_m_b2', 'vl': 57},
        {'impl': 'vcpop_m_b2', 'vl': 56},
        {'impl': 'vcpop_m_b4', 'vl': 32},
        {'impl': 'vcpop_m_b4', 'vl': 25},
        {'impl': 'vcpop_m_b4', 'vl': 24},
        {'impl': 'vcpop_m_b8', 'vl': 16},
        {'impl': 'vcpop_m_b8', 'vl': 9},
        {'impl': 'vcpop_m_b8', 'vl': 8},
        {'impl': 'vcpop_m_b16', 'vl': 8},
        {'impl': 'vcpop_m_b16', 'vl': 1},
        {'impl': 'vcpop_m_b32', 'vl': 4},
        {'impl': 'vcpop_m_b32', 'vl': 1},
    ]
    await fixture.load_elf_and_lookup_symbols(
        r.Rlocation('coralnpu_hw/tests/cocotb/rvv/vcpop_test.elf'),
        ['vl', 'in_buf', 'result', 'impl'] + [c['impl'] for c in cases],
    )
    rng = np.random.default_rng()
    for c in cases:
        impl = c['impl']
        vl = c['vl']
        in_bytes = (vl + 7) // 8
        last_byte_mask = (1 << (vl % 8) - 1) if vl % 8 else 0xFF

        input_data = rng.integers(
            low=0, high=256, size=in_bytes, dtype=np.uint8)
        input_data_trimmed = input_data
        input_data_trimmed[-1] = input_data_trimmed[-1] & last_byte_mask
        expected_output = np.sum(
            np.bitwise_count(input_data), dtype=np.uint32)

        await fixture.write_ptr('impl', impl)
        await fixture.write_word('vl', vl)
        await fixture.write('in_buf', input_data)
        await fixture.write_word('result', 0)

        await fixture.run_to_halt()

        actual_output = (await fixture.read_word('result')).view(np.uint32)

        debug_msg = str({
            'impl': impl,
            'input': input_data,
            'expected': expected_output,
            'actual': actual_output,
        })
        assert (actual_output == expected_output), debug_msg


@cocotb.test()
async def core_mini_vcompress_test(dut):
    """Testbench to test vstart!=0 vcompress."""
    await test_vstart_not_zero_failure(
        dut, "coralnpu_hw/tests/cocotb/rvv/vcompress_test.elf")


@cocotb.test()
async def core_mini_vmsbf_test(dut):
    """Testbench to test vstart!=0 vmsbf."""
    await test_vstart_not_zero_failure(
        dut, "coralnpu_hw/tests/cocotb/rvv/vmsbf_test.elf")


@cocotb.test()
async def core_mini_vmsof_test(dut):
    """Testbench to test vstart!=0 vmsof."""
    await test_vstart_not_zero_failure(
        dut, "coralnpu_hw/tests/cocotb/rvv/vmsof_test.elf")


@cocotb.test()
async def core_mini_vmsif_test(dut):
    """Testbench to test vstart!=0 vmsbf."""
    await test_vstart_not_zero_failure(
        dut, "coralnpu_hw/tests/cocotb/rvv/vmsif_test.elf")


@cocotb.test()
async def core_mini_vill_test(dut):
    core_mini_axi = CoreMiniAxiInterface(dut)
    await core_mini_axi.init()
    await core_mini_axi.reset()
    cocotb.start_soon(core_mini_axi.clock.start())
    r = runfiles.Create()

    elf_path = r.Rlocation("coralnpu_hw/tests/cocotb/rvv/vill_test.elf")
    if not elf_path:
        raise ValueError("elf_path must consist a valid path")
    with open(elf_path, "rb") as f:
        entry_point = await core_mini_axi.load_elf(f)
        faulted_addr = core_mini_axi.lookup_symbol(f, "faulted")
        mcause_addr = core_mini_axi.lookup_symbol(f, "mcause")

    await core_mini_axi.execute_from(entry_point)
    await core_mini_axi.wait_for_halted()

    faulted_result = (
        await core_mini_axi.read_word(faulted_addr)).view(np.uint32)[0]
    assert (faulted_result == 1)
    mcause_result = (
        await core_mini_axi.read_word(mcause_addr)).view(np.uint32)[0]
    assert (mcause_result == 0x2)


@cocotb.test()
async def core_mini_vl_test(dut):
    """Testbench to test vsetvl instruciton saturate vl correctly."""
    # Test bench setup
    core_mini_axi = CoreMiniAxiInterface(dut)
    await core_mini_axi.init()
    await core_mini_axi.reset()
    cocotb.start_soon(core_mini_axi.clock.start())
    r = runfiles.Create()

    elf_path = r.Rlocation("coralnpu_hw/tests/cocotb/rvv/vcsr_test.elf")
    with open(elf_path, "rb") as f:
        entry_point = await core_mini_axi.load_elf(f)
        sew_addr = core_mini_axi.lookup_symbol(f, "sew")
        lmul_addr = core_mini_axi.lookup_symbol(f, "lmul")
        vl_addr = core_mini_axi.lookup_symbol(f, "vl")
        vtype_addr = core_mini_axi.lookup_symbol(f, "vtype")
        result_vl_addr = core_mini_axi.lookup_symbol(f, "result_vl")

    cases = [
        (0b000, 0b110, 4),   # SEW8, mf4, vlmax=4
        (0b000, 0b111, 8),   # SEW8, mf2, vlmax=8
        (0b000, 0b000, 16),  # SEW8, m1, vlmax=16
        (0b000, 0b001, 32),  # SEW8, m2, vlmax=32
        (0b000, 0b010, 64),  # SEW8, m4, vlmax=64
        (0b000, 0b011, 128), # SEW8, m8, vlmax=128
        (0b001, 0b111, 4),   # SEW16, mf2, vlmax=4
        (0b001, 0b000, 8),   # SEW16, m1, vlmax=8
        (0b001, 0b001, 16),  # SEW16, m2, vlmax=16
        (0b001, 0b010, 32),  # SEW16, m4, vlmax=32
        (0b001, 0b011, 64),  # SEW16, m8, vlmax=64
        (0b010, 0b000, 4),   # SEW32, m1, vlmax=4
        (0b010, 0b001, 8),   # SEW32, m2, vlmax=8
        (0b010, 0b010, 16),  # SEW32, m4, vlmax=16
        (0b010, 0b011, 32),  # SEW32, m8, vlmax=32
    ]
    for sew, lmul, vlmax in tqdm.tqdm(cases):
        await core_mini_axi.write_word(sew_addr, sew)
        await core_mini_axi.write_word(lmul_addr, lmul)

        # Test saturation above vlmax
        vl_to_set = vlmax + 1
        await core_mini_axi.write_word(vl_addr, vl_to_set)
        await core_mini_axi.execute_from(entry_point)
        await core_mini_axi.wait_for_halted()
        vl_result = (
            await core_mini_axi.read_word(result_vl_addr)).view(np.uint32)[0]
        assert(vl_result == vlmax)

        # Test vlmax
        await core_mini_axi.write_word(vl_addr, vlmax)
        await core_mini_axi.execute_from(entry_point)
        await core_mini_axi.wait_for_halted()
        vl_result = (
            await core_mini_axi.read_word(result_vl_addr)).view(np.uint32)[0]
        assert(vl_result == vlmax)

        # Test below vlmax
        await core_mini_axi.write_word(vl_addr, vlmax - 1)
        await core_mini_axi.execute_from(entry_point)
        await core_mini_axi.wait_for_halted()
        vl_result = (
            await core_mini_axi.read_word(result_vl_addr)).view(np.uint32)[0]
        assert(vl_result == (vlmax - 1))


@cocotb.test()
async def vsetvl_test(dut):
    cases = [
        {
            'impl': 'vsetvl_max',
            'vtype': construct_vtype(1, 1, sew, lmul),
            'vlmax': vlmax,
        }
        for sew, t in SEW_TO_LMULS_AND_VLMAXS.items()
        for lmul, vlmax in t
    ] + [
        {
            'impl': 'vsetvl_keep',
            'vtype': construct_vtype(1, 1, sew, lmul),
            'avl': vlmax - 1,
            'vlmax': vlmax,
        }
        for sew, t in SEW_TO_LMULS_AND_VLMAXS.items()
        for lmul, vlmax in t
    ] + [
        # TODO(davidgao): lookup vlmax and generate impl names
        {
            'impl': 'vsetvli_max_e8mf4',
            'vtype': construct_vtype(1, 1, sew=0b000, lmul=0b110),
            'vlmax': 4,
        },
        {
            'impl': 'vsetvli_max_e8mf2',
            'vtype': construct_vtype(1, 1, sew=0b000, lmul=0b111),
            'vlmax': 8,
        },
        {
            'impl': 'vsetvli_max_e8m1',
            'vtype': construct_vtype(1, 1, sew=0b000, lmul=0b000),
            'vlmax': 16,
        },
        {
            'impl': 'vsetvli_max_e8m2',
            'vtype': construct_vtype(1, 1, sew=0b000, lmul=0b001),
            'vlmax': 32,
        },
        {
            'impl': 'vsetvli_max_e8m4',
            'vtype': construct_vtype(1, 1, sew=0b000, lmul=0b010),
            'vlmax': 64,
        },
        {
            'impl': 'vsetvli_max_e8m8',
            'vtype': construct_vtype(1, 1, sew=0b000, lmul=0b011),
            'vlmax': 128,
        },
        {
            'impl': 'vsetvli_max_e16mf2',
            'vtype': construct_vtype(1, 1, sew=0b001, lmul=0b111),
            'vlmax': 4,
        },
        {
            'impl': 'vsetvli_max_e16m1',
            'vtype': construct_vtype(1, 1, sew=0b001, lmul=0b000),
            'vlmax': 8,
        },
        {
            'impl': 'vsetvli_max_e16m2',
            'vtype': construct_vtype(1, 1, sew=0b001, lmul=0b001),
            'vlmax': 16,
        },
        {
            'impl': 'vsetvli_max_e16m4',
            'vtype': construct_vtype(1, 1, sew=0b001, lmul=0b010),
            'vlmax': 32,
        },
        {
            'impl': 'vsetvli_max_e16m8',
            'vtype': construct_vtype(1, 1, sew=0b001, lmul=0b011),
            'vlmax': 64,
        },
        {
            'impl': 'vsetvli_max_e32m1',
            'vtype': construct_vtype(1, 1, sew=0b010, lmul=0b000),
            'vlmax': 4,
        },
        {
            'impl': 'vsetvli_max_e32m2',
            'vtype': construct_vtype(1, 1, sew=0b010, lmul=0b001),
            'vlmax': 8,
        },
        {
            'impl': 'vsetvli_max_e32m4',
            'vtype': construct_vtype(1, 1, sew=0b010, lmul=0b010),
            'vlmax': 16,
        },
        {
            'impl': 'vsetvli_max_e32m8',
            'vtype': construct_vtype(1, 1, sew=0b010, lmul=0b011),
            'vlmax': 32,
        },
        # TODO(davidgao): do we wan to test all vtype pairs for this one?
        {
            'impl': 'vsetvli_keep',
            'vtype': construct_vtype(1, 1, sew=0b000, lmul=0b000),
            'avl': 15,
            'vlmax': 16,
        },
    ]

    fixture = await Fixture.Create(dut)
    r = runfiles.Create()
    await fixture.load_elf_and_lookup_symbols(
        r.Rlocation('coralnpu_hw/tests/cocotb/rvv/vsetvl_test.elf'),
        ['impl', 'vtype', 'avl', 'vl_out1', 'vl_out2', 'vtype_out'] +
            list({c['impl'] for c in cases}),
    )

    with tqdm.tqdm(cases) as t:
        for c in t:
            impl = c['impl']
            vtype = c['vtype']
            vlmax = c['vlmax']

            t.set_postfix({
                'impl': impl,
                'vtype': vtype,
            })

            await fixture.write_ptr('impl', impl)
            await fixture.write_word('vtype', vtype)
            if 'avl' in c:
                avl = c['avl']
                expected_vl = min(avl, vlmax)
                await fixture.write_word('avl', avl)
            else:
                expected_vl = vlmax

            await fixture.run_to_halt()

            actual_vl1 = (await fixture.read_word('vl_out1')).view(np.uint32)
            actual_vl2 = (await fixture.read_word('vl_out2')).view(np.uint32)
            actual_vtype = (await fixture.read_word('vtype_out')).view(np.uint32)

            assert(actual_vl1 == expected_vl)
            assert(actual_vl2 == expected_vl)
            assert(actual_vtype == vtype)


async def vslide_test(dut, cases, expfunc, ignore_tail=False):
    """Test slide[1]{up,down} usage accessible from intrinsics."""
    # mask is not accessible from here.
    fixture = await Fixture.Create(dut)
    r = runfiles.Create()
    await fixture.load_elf_and_lookup_symbols(
        r.Rlocation('coralnpu_hw/tests/cocotb/rvv/vslide.elf'),
        [
            'impl',
            'vl',
            'offset',
            'buf_dest8',
            'buf_dest16',
            'buf_dest32',
            'buf_src8',
            'buf_src16',
            'buf_src32',
            'scalar8',
            'scalar16',
            'scalar32',
        ] + [c['impl'] for c in cases],
    )
    rng = np.random.default_rng()
    for c in tqdm.tqdm(cases):
        impl = c['impl']
        vl = c['vl']
        offset = c['offset']
        dtype = c['dtype']

        src_data = rng.integers(
            low=np.iinfo(dtype).min,
            high=np.iinfo(dtype).max+1, size=vl, dtype=dtype)
        dest_data = rng.integers(
            low=np.iinfo(dtype).min,
            high=np.iinfo(dtype).max+1, size=vl, dtype=dtype)
        scalar = rng.integers(
            low=np.iinfo(dtype).min,
            high=np.iinfo(dtype).max+1, size=1, dtype=dtype)
        expected_output = expfunc(dest_data, src_data, scalar, vl, offset)

        if dtype == np.int8:
            dest_buf = 'buf_dest8'
            src_buf = 'buf_src8'
            scalar_sym = 'scalar8'
        elif dtype == np.int16:
            dest_buf = 'buf_dest16'
            src_buf = 'buf_src16'
            scalar_sym = 'scalar16'
        elif dtype == np.int32:
            dest_buf = 'buf_dest32'
            src_buf = 'buf_src32'
            scalar_sym = 'scalar32'

        await fixture.write_ptr('impl', impl)
        await fixture.write_word('vl', vl)
        await fixture.write_word('offset', offset)
        await fixture.write(dest_buf, dest_data)
        await fixture.write(src_buf, src_data)
        await fixture.write(scalar_sym, scalar)

        await fixture.run_to_halt()

        actual_output = (
            await fixture.read(dest_buf, vl * np.dtype(dtype).itemsize)
        ).view(dtype)

        if ignore_tail:
            expected_output = expected_output[0:max(vl-offset, 0)]
            actual_output = actual_output[0:max(vl-offset, 0)]
        debug_msg = str({
            'impl': impl,
            'vl': vl,
            'offset': offset,
            'src': src_data,
            'dest': dest_data,
            'expected': expected_output,
            'actual': actual_output,
        })
        assert (actual_output == expected_output).all(), debug_msg


@cocotb.test()
async def vslideup_test(dut):
    """Test slideup usage accessible from intrinsics."""
    def expfunc(dest, src, scalar, vl, offset):
        return np.concat((
            dest[0:offset], src[0:max(vl-offset, 0)]))

    cases = [
        {'impl': 'vslideup_i8mf4', 'dtype': np.int8, 'vl': vl, 'offset': offset}
        for vl in [4, 3] for offset in [0, 1, 2, 4]
    ] + [
        {'impl': 'vslideup_i8mf2', 'dtype': np.int8, 'vl': vl, 'offset': offset}
        for vl in [8, 7] for offset in [0, 2, 6, 8]
    ] + [
        {'impl': 'vslideup_i8m1', 'dtype': np.int8, 'vl': vl, 'offset': offset}
        for vl in [16, 15] for offset in [0, 3, 14, 16]
    ] + [
        {'impl': 'vslideup_i8m2', 'dtype': np.int8, 'vl': vl, 'offset': offset}
        for vl in [32, 31] for offset in [0, 4, 30, 32]
    ] + [
        {'impl': 'vslideup_i8m4', 'dtype': np.int8, 'vl': vl, 'offset': offset}
        for vl in [64, 63] for offset in [0, 5, 62, 64]
    ] + [
        {'impl': 'vslideup_i8m8', 'dtype': np.int8, 'vl': vl, 'offset': offset}
        for vl in [128, 127] for offset in [0, 6, 126, 128]
    ] + [
        {'impl': 'vslideup_i16mf2', 'dtype': np.int16, 'vl': vl, 'offset': offset}
        for vl in [4, 3] for offset in [0, 1, 2, 4]
    ] + [
        {'impl': 'vslideup_i16m1', 'dtype': np.int16, 'vl': vl, 'offset': offset}
        for vl in [8, 7] for offset in [0, 2, 6, 8]
    ] + [
        {'impl': 'vslideup_i16m2', 'dtype': np.int16, 'vl': vl, 'offset': offset}
        for vl in [16, 15] for offset in [0, 3, 14, 16]
    ] + [
        {'impl': 'vslideup_i16m4', 'dtype': np.int16, 'vl': vl, 'offset': offset}
        for vl in [32, 31] for offset in [0, 4, 30, 32]
    ] + [
        {'impl': 'vslideup_i16m8', 'dtype': np.int16, 'vl': vl, 'offset': offset}
        for vl in [64, 63] for offset in [0, 5, 62, 64]
    ] + [
        {'impl': 'vslideup_i32m1', 'dtype': np.int32, 'vl': vl, 'offset': offset}
        for vl in [4, 3] for offset in [0, 1, 2, 4]
    ] + [
        {'impl': 'vslideup_i32m2', 'dtype': np.int32, 'vl': vl, 'offset': offset}
        for vl in [8, 7] for offset in [0, 2, 6, 8]
    ] + [
        {'impl': 'vslideup_i32m4', 'dtype': np.int32, 'vl': vl, 'offset': offset}
        for vl in [16, 15] for offset in [0, 3, 14, 16]
    ] + [
        {'impl': 'vslideup_i32m8', 'dtype': np.int32, 'vl': vl, 'offset': offset}
        for vl in [32, 31] for offset in [0, 4, 30, 32]
    ]
    await vslide_test(dut, cases, expfunc)


@cocotb.test()
async def vslidedown_test(dut):
    """Test slidedown usage accessible from intrinsics."""
    def expfunc(dest, src, scalar, vl, offset):
        return np.concat((
            src[offset:max(vl, offset)],
            np.zeros(max(offset, 0), dtype=src.dtype)))

    cases = [
        {'impl': 'vslidedown_i8mf4', 'dtype': np.int8, 'vl': vl, 'offset': offset}
        for vl in [4, 3] for offset in [1, 2]
    ] + [
        {'impl': 'vslidedown_i8mf2', 'dtype': np.int8, 'vl': vl, 'offset': offset}
        for vl in [8, 7] for offset in [0, 2, 6, 8]
    ] + [
        {'impl': 'vslidedown_i8m1', 'dtype': np.int8, 'vl': vl, 'offset': offset}
        for vl in [16, 15] for offset in [0, 3, 14, 16]
    ] + [
        {'impl': 'vslidedown_i8m2', 'dtype': np.int8, 'vl': vl, 'offset': offset}
        for vl in [32, 31] for offset in [0, 4, 30, 32]
    ] + [
        {'impl': 'vslidedown_i8m4', 'dtype': np.int8, 'vl': vl, 'offset': offset}
        for vl in [64, 63] for offset in [0, 5, 62, 64]
    ] + [
        {'impl': 'vslidedown_i8m8', 'dtype': np.int8, 'vl': vl, 'offset': offset}
        for vl in [128, 127] for offset in [0, 6, 126, 128]
    ] + [
        {'impl': 'vslidedown_i16mf2', 'dtype': np.int16, 'vl': vl, 'offset': offset}
        for vl in [4, 3] for offset in [0, 1, 2, 4]
    ] + [
        {'impl': 'vslidedown_i16m1', 'dtype': np.int16, 'vl': vl, 'offset': offset}
        for vl in [8, 7] for offset in [0, 2, 6, 8]
    ] + [
        {'impl': 'vslidedown_i16m2', 'dtype': np.int16, 'vl': vl, 'offset': offset}
        for vl in [16, 15] for offset in [0, 3, 14, 16]
    ] + [
        {'impl': 'vslidedown_i16m4', 'dtype': np.int16, 'vl': vl, 'offset': offset}
        for vl in [32, 31] for offset in [0, 4, 30, 32]
    ] + [
        {'impl': 'vslidedown_i16m8', 'dtype': np.int16, 'vl': vl, 'offset': offset}
        for vl in [64, 63] for offset in [0, 5, 62, 64]
    ] + [
        {'impl': 'vslidedown_i32m1', 'dtype': np.int32, 'vl': vl, 'offset': offset}
        for vl in [4, 3] for offset in [0, 1, 2, 4]
    ] + [
        {'impl': 'vslidedown_i32m2', 'dtype': np.int32, 'vl': vl, 'offset': offset}
        for vl in [8, 7] for offset in [0, 2, 6, 8]
    ] + [
        {'impl': 'vslidedown_i32m4', 'dtype': np.int32, 'vl': vl, 'offset': offset}
        for vl in [16, 15] for offset in [0, 3, 14, 16]
    ] + [
        {'impl': 'vslidedown_i32m8', 'dtype': np.int32, 'vl': vl, 'offset': offset}
        for vl in [32, 31] for offset in [0, 4, 30, 32]
    ]
    await vslide_test(dut, cases, expfunc, ignore_tail=True)


@cocotb.test()
async def vslide1up_test(dut):
    """Test slide1up usage accessible from intrinsics."""
    def expfunc(dest, src, scalar, vl, offset):
        return np.concat((scalar, src[0:max(vl-1, 0)]))

    cases = [
        {'impl': 'vslide1up_i8mf4', 'dtype': np.int8, 'vl': vl, 'offset': 0}
        for vl in [4, 3]
    ] + [
        {'impl': 'vslide1up_i8mf2', 'dtype': np.int8, 'vl': vl, 'offset': 0}
        for vl in [8, 7]
    ] + [
        {'impl': 'vslide1up_i8m1', 'dtype': np.int8, 'vl': vl, 'offset': 0}
        for vl in [16, 15]
    ] + [
        {'impl': 'vslide1up_i8m2', 'dtype': np.int8, 'vl': vl, 'offset': 0}
        for vl in [32, 31]
    ] + [
        {'impl': 'vslide1up_i8m4', 'dtype': np.int8, 'vl': vl, 'offset': 0}
        for vl in [64, 63]
    ] + [
        {'impl': 'vslide1up_i8m8', 'dtype': np.int8, 'vl': vl, 'offset': 0}
        for vl in [128, 127]
    ] + [
        {'impl': 'vslide1up_i16mf2', 'dtype': np.int16, 'vl': vl, 'offset': 0}
        for vl in [4, 3]
    ] + [
        {'impl': 'vslide1up_i16m1', 'dtype': np.int16, 'vl': vl, 'offset': 0}
        for vl in [8, 7]
    ] + [
        {'impl': 'vslide1up_i16m2', 'dtype': np.int16, 'vl': vl, 'offset': 0}
        for vl in [16, 15]
    ] + [
        {'impl': 'vslide1up_i16m4', 'dtype': np.int16, 'vl': vl, 'offset': 0}
        for vl in [32, 31]
    ] + [
        {'impl': 'vslide1up_i16m8', 'dtype': np.int16, 'vl': vl, 'offset': 0}
        for vl in [64, 63]
    ] + [
        {'impl': 'vslide1up_i32m1', 'dtype': np.int32, 'vl': vl, 'offset': 0}
        for vl in [4, 3]
    ] + [
        {'impl': 'vslide1up_i32m2', 'dtype': np.int32, 'vl': vl, 'offset': 0}
        for vl in [8, 7]
    ] + [
        {'impl': 'vslide1up_i32m4', 'dtype': np.int32, 'vl': vl, 'offset': 0}
        for vl in [16, 15]
    ] + [
        {'impl': 'vslide1up_i32m8', 'dtype': np.int32, 'vl': vl, 'offset': 0}
        for vl in [32, 31]
    ]
    await vslide_test(dut, cases, expfunc)


@cocotb.test()
async def vslide1down_test(dut):
    """Test slide1down usage accessible from intrinsics."""
    def expfunc(dest, src, scalar, vl, offset):
        return np.concat((src[1:max(vl, 1)], scalar))

    cases = [
        {'impl': 'vslide1down_i8mf4', 'dtype': np.int8, 'vl': vl, 'offset': 0}
        for vl in [4, 3]
    ] + [
        {'impl': 'vslide1down_i8mf2', 'dtype': np.int8, 'vl': vl, 'offset': 0}
        for vl in [8, 7]
    ] + [
        {'impl': 'vslide1down_i8m1', 'dtype': np.int8, 'vl': vl, 'offset': 0}
        for vl in [16, 15]
    ] + [
        {'impl': 'vslide1down_i8m2', 'dtype': np.int8, 'vl': vl, 'offset': 0}
        for vl in [32, 31]
    ] + [
        {'impl': 'vslide1down_i8m4', 'dtype': np.int8, 'vl': vl, 'offset': 0}
        for vl in [64, 63]
    ] + [
        {'impl': 'vslide1down_i8m8', 'dtype': np.int8, 'vl': vl, 'offset': 0}
        for vl in [128, 127]
    ] + [
        {'impl': 'vslide1down_i16mf2', 'dtype': np.int16, 'vl': vl, 'offset': 0}
        for vl in [4, 3]
    ] + [
        {'impl': 'vslide1down_i16m1', 'dtype': np.int16, 'vl': vl, 'offset': 0}
        for vl in [8, 7]
    ] + [
        {'impl': 'vslide1down_i16m2', 'dtype': np.int16, 'vl': vl, 'offset': 0}
        for vl in [16, 15]
    ] + [
        {'impl': 'vslide1down_i16m4', 'dtype': np.int16, 'vl': vl, 'offset': 0}
        for vl in [32, 31]
    ] + [
        {'impl': 'vslide1down_i16m8', 'dtype': np.int16, 'vl': vl, 'offset': 0}
        for vl in [64, 63]
    ] + [
        {'impl': 'vslide1down_i32m1', 'dtype': np.int32, 'vl': vl, 'offset': 0}
        for vl in [4, 3]
    ] + [
        {'impl': 'vslide1down_i32m2', 'dtype': np.int32, 'vl': vl, 'offset': 0}
        for vl in [8, 7]
    ] + [
        {'impl': 'vslide1down_i32m4', 'dtype': np.int32, 'vl': vl, 'offset': 0}
        for vl in [16, 15]
    ] + [
        {'impl': 'vslide1down_i32m8', 'dtype': np.int32, 'vl': vl, 'offset': 0}
        for vl in [32, 31]
    ]
    await vslide_test(dut, cases, expfunc)
