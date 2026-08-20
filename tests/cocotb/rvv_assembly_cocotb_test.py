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
        input_1_data = np.random.randint(
            min_value, max_value, num_values, dtype=data_type
        )
        await core_mini_axi.write(input_1_addr, input_1_data)
        if intial_pass:
            intial_pass = False
            await core_mini_axi.execute_from(entry_point)

        await core_mini_axi.wait_for_wfi()
        routputs = (await core_mini_axi.read(input_1_addr,
                                             num_test_bytes)).view(data_type)
        print(f"loaded inputs are {routputs}", flush=True)
        print(
            f" number of values supposed to be printed {num_values}",
            flush=True
        )
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
        input_1_data = np.random.randint(
            min_value, max_value, num_values, dtype=data_type
        )
        input_2_data = np.random.randint(
            min_value, max_value, num_values, dtype=data_type
        )

        await core_mini_axi.write(input_1_addr, input_1_data)
        if intial_pass:
            intial_pass = False
            await core_mini_axi.execute_from(entry_point)
        await core_mini_axi.wait_for_wfi()
        routputs = (await core_mini_axi.read(input_1_addr,
                                             num_test_bytes)).view(data_type)
        print(f"loaded inputs are {routputs}", flush=True)
        routputs2 = (await core_mini_axi.read(input_1_addr,
                                              num_test_bytes)).view(data_type)
        print(f"loaded inputs are {routputs2}", flush=True)
        print(
            f" number of values supposed to be printed {num_values}",
            flush=True
        )
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
        np.iinfo(np.uint8).min, np.iinfo(np.uint8).max, 16, dtype=np.uint8
    )
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
            t.set_postfix({
                'ma': ma,
                'ta': ta,
                'sew': bin(sew),
                'lmul': bin(lmul)
            })
            await core_mini_axi.write_word(vma_addr, ma)
            await core_mini_axi.write_word(vta_addr, ta)
            await core_mini_axi.write_word(sew_addr, sew)
            await core_mini_axi.write_word(lmul_addr, lmul)
            # TODO(derekjchow): Pick random VL
            await core_mini_axi.write_word(vl_addr, 1)

            await core_mini_axi.execute_from(entry_point)
            await core_mini_axi.wait_for_halted()

            vtype_result = (await core_mini_axi.read_word(vtype_addr)).view(
                np.uint32
            )[0]

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
                    vl = 4  # TODO(derekjchow): Pick random VL
                    vstart = 1  # Non-zero to trigger failure

                    await core_mini_axi.write_word(vma_addr, ma)
                    await core_mini_axi.write_word(vta_addr, ta)
                    await core_mini_axi.write_word(sew_addr, sew)
                    await core_mini_axi.write_word(lmul_addr, lmul)
                    await core_mini_axi.write_word(vl_addr, vl)
                    await core_mini_axi.write_word(vstart_addr, vstart)

                    await core_mini_axi.execute_from(entry_point)
                    await core_mini_axi.wait_for_halted()

                    faulted_result = (
                        await core_mini_axi.read_word(faulted_addr)
                    ).view(np.uint32)[0]
                    assert (faulted_result == 1)
                    mcause_result = (
                        await core_mini_axi.read_word(mcause_addr)
                    ).view(np.uint32)[0]
                    assert (mcause_result == 0x2)


@cocotb.test()
async def core_mini_viota_test(dut):
    """Testbench to test vstart!=0 viota."""
    await test_vstart_not_zero_failure(
        dut, "coralnpu_hw/tests/cocotb/rvv/viota_test.elf"
    )


@cocotb.test()
async def core_mini_vfirst_test(dut):
    """Testbench to test vstart!=0 vfirst."""
    await test_vstart_not_zero_failure(
        dut, "coralnpu_hw/tests/cocotb/rvv/vfirst_test.elf"
    )


@cocotb.test()
async def core_mini_vcpop_exception_test(dut):
    """Testbench to test vstart!=0 vcpop."""
    await test_vstart_not_zero_failure(
        dut, "coralnpu_hw/tests/cocotb/rvv/vcpop_exception_test.elf"
    )


@cocotb.test()
async def core_mini_vcpop_test(dut):
    """Test vcpop usage accessible from intrinsics."""
    # mask is not accessible from here.
    fixture = await Fixture.Create(dut)
    r = runfiles.Create()
    cases = [
        {
            'impl': 'vcpop_m_b1',
            'vl': 128
        },
        {
            'impl': 'vcpop_m_b1',
            'vl': 121
        },
        {
            'impl': 'vcpop_m_b1',
            'vl': 120
        },
        {
            'impl': 'vcpop_m_b2',
            'vl': 64
        },
        {
            'impl': 'vcpop_m_b2',
            'vl': 57
        },
        {
            'impl': 'vcpop_m_b2',
            'vl': 56
        },
        {
            'impl': 'vcpop_m_b4',
            'vl': 32
        },
        {
            'impl': 'vcpop_m_b4',
            'vl': 25
        },
        {
            'impl': 'vcpop_m_b4',
            'vl': 24
        },
        {
            'impl': 'vcpop_m_b8',
            'vl': 16
        },
        {
            'impl': 'vcpop_m_b8',
            'vl': 9
        },
        {
            'impl': 'vcpop_m_b8',
            'vl': 8
        },
        {
            'impl': 'vcpop_m_b16',
            'vl': 8
        },
        {
            'impl': 'vcpop_m_b16',
            'vl': 1
        },
        {
            'impl': 'vcpop_m_b32',
            'vl': 4
        },
        {
            'impl': 'vcpop_m_b32',
            'vl': 1
        },
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
            low=0, high=256, size=in_bytes, dtype=np.uint8
        )
        input_data_trimmed = input_data
        input_data_trimmed[-1] = input_data_trimmed[-1] & last_byte_mask
        expected_output = np.sum(np.bitwise_count(input_data), dtype=np.uint32)

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
        dut, "coralnpu_hw/tests/cocotb/rvv/vcompress_test.elf"
    )


@cocotb.test()
async def core_mini_vmsbf_test(dut):
    """Testbench to test vstart!=0 vmsbf."""
    await test_vstart_not_zero_failure(
        dut, "coralnpu_hw/tests/cocotb/rvv/vmsbf_test.elf"
    )


@cocotb.test()
async def core_mini_vmsof_test(dut):
    """Testbench to test vstart!=0 vmsof."""
    await test_vstart_not_zero_failure(
        dut, "coralnpu_hw/tests/cocotb/rvv/vmsof_test.elf"
    )


@cocotb.test()
async def core_mini_vmsif_test(dut):
    """Testbench to test vstart!=0 vmsbf."""
    await test_vstart_not_zero_failure(
        dut, "coralnpu_hw/tests/cocotb/rvv/vmsif_test.elf"
    )


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

    faulted_result = (await
                      core_mini_axi.read_word(faulted_addr)).view(np.uint32)[0]
    assert (faulted_result == 1)
    mcause_result = (await
                     core_mini_axi.read_word(mcause_addr)).view(np.uint32)[0]
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
        (0b000, 0b110, 4),  # SEW8, mf4, vlmax=4
        (0b000, 0b111, 8),  # SEW8, mf2, vlmax=8
        (0b000, 0b000, 16),  # SEW8, m1, vlmax=16
        (0b000, 0b001, 32),  # SEW8, m2, vlmax=32
        (0b000, 0b010, 64),  # SEW8, m4, vlmax=64
        (0b000, 0b011, 128),  # SEW8, m8, vlmax=128
        (0b001, 0b111, 4),  # SEW16, mf2, vlmax=4
        (0b001, 0b000, 8),  # SEW16, m1, vlmax=8
        (0b001, 0b001, 16),  # SEW16, m2, vlmax=16
        (0b001, 0b010, 32),  # SEW16, m4, vlmax=32
        (0b001, 0b011, 64),  # SEW16, m8, vlmax=64
        (0b010, 0b000, 4),  # SEW32, m1, vlmax=4
        (0b010, 0b001, 8),  # SEW32, m2, vlmax=8
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
        vl_result = (await
                     core_mini_axi.read_word(result_vl_addr)).view(np.uint32
                                                                   )[0]
        assert (vl_result == vlmax)

        # Test vlmax
        await core_mini_axi.write_word(vl_addr, vlmax)
        await core_mini_axi.execute_from(entry_point)
        await core_mini_axi.wait_for_halted()
        vl_result = (await
                     core_mini_axi.read_word(result_vl_addr)).view(np.uint32
                                                                   )[0]
        assert (vl_result == vlmax)

        # Test below vlmax
        await core_mini_axi.write_word(vl_addr, vlmax - 1)
        await core_mini_axi.execute_from(entry_point)
        await core_mini_axi.wait_for_halted()
        vl_result = (await
                     core_mini_axi.read_word(result_vl_addr)).view(np.uint32
                                                                   )[0]
        assert (vl_result == (vlmax - 1))


@cocotb.test()
async def vsetvl_test(dut):
    cases = [{
        'impl': 'vsetvl_max',
        'vtype': construct_vtype(1, 1, sew, lmul),
        'vlmax': vlmax,
    } for sew, t in SEW_TO_LMULS_AND_VLMAXS.items() for lmul, vlmax in t] + [
        {
            'impl': 'vsetvl_keep',
            'vtype': construct_vtype(1, 1, sew, lmul),
            'avl': vlmax - 1,
            'vlmax': vlmax,
        } for sew, t in SEW_TO_LMULS_AND_VLMAXS.items() for lmul, vlmax in t
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
        list({c['impl']
              for c in cases}),
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
            actual_vl2 = (await fixture.read_word('vl_out1')).view(np.uint32)
            actual_vtype = (await
                            fixture.read_word('vtype_out')).view(np.uint32)

            assert (actual_vl1 == expected_vl)
            assert (actual_vl2 == expected_vl)
            assert (actual_vtype == vtype)


async def vslide_test(dut, cases, expfunc):
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
        vlmax = c.get('vlmax', vl)

        src_data = rng.integers(
            low=np.iinfo(dtype).min,
            high=np.iinfo(dtype).max + 1,
            size=vlmax,
            dtype=dtype
        )
        dest_data = rng.integers(
            low=np.iinfo(dtype).min,
            high=np.iinfo(dtype).max + 1,
            size=vlmax,
            dtype=dtype
        )
        scalar = rng.integers(
            low=np.iinfo(dtype).min,
            high=np.iinfo(dtype).max + 1,
            size=1,
            dtype=dtype
        )
        expected_output = expfunc(
            dest_data, src_data, scalar, vl, offset, vlmax
        )

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
            await fixture.read(dest_buf,
                               vl * np.dtype(dtype).itemsize)
        ).view(dtype)

        debug_msg = str({
            'impl': impl,
            'vl': vl,
            'vlmax': vlmax,
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

    def expfunc(dest, src, scalar, vl, offset, vlmax):
        return np.concat((dest[0:min(vl, offset)], src[0:max(vl - offset, 0)]))

    cases = [{
        'impl': 'vslideup_i8mf4',
        'dtype': np.int8,
        'vlmax': 4,
        'vl': vl,
        'offset': offset
    } for vl in [4, 3, 2, 1] for offset in [0, 1, 2, 4]] + [{
        'impl': 'vslideup_i8mf2',
        'dtype': np.int8,
        'vlmax': 8,
        'vl': vl,
        'offset': offset
    } for vl in [8, 7, 4, 2, 1] for offset in [0, 2, 6, 8]] + [{
        'impl': 'vslideup_i8m1',
        'dtype': np.int8,
        'vlmax': 16,
        'vl': vl,
        'offset': offset
    } for vl in [16, 15, 8, 4, 2, 1] for offset in [0, 3, 8, 14, 16]] + [
        {
            'impl': 'vslideup_i8m2',
            'dtype': np.int8,
            'vlmax': 32,
            'vl': vl,
            'offset': offset
        } for vl in [32, 31, 16, 8, 4] for offset in [0, 4, 16, 30, 32]
    ] + [{
        'impl': 'vslideup_i8m4',
        'dtype': np.int8,
        'vlmax': 64,
        'vl': vl,
        'offset': offset
    } for vl in [64, 63, 32, 16, 4] for offset in [0, 5, 32, 62, 64]] + [
        {
            'impl': 'vslideup_i8m8',
            'dtype': np.int8,
            'vlmax': 128,
            'vl': vl,
            'offset': offset
        } for vl in [128, 127, 64, 32, 8] for offset in [0, 6, 64, 126, 128]
    ] + [{
        'impl': 'vslideup_i16mf2',
        'dtype': np.int16,
        'vlmax': 4,
        'vl': vl,
        'offset': offset
    } for vl in [4, 3, 2, 1] for offset in [0, 1, 2, 4]] + [{
        'impl': 'vslideup_i16m1',
        'dtype': np.int16,
        'vlmax': 8,
        'vl': vl,
        'offset': offset
    } for vl in [8, 7, 4, 2, 1] for offset in [0, 2, 4, 6, 8]] + [
        {
            'impl': 'vslideup_i16m2',
            'dtype': np.int16,
            'vlmax': 16,
            'vl': vl,
            'offset': offset
        } for vl in [16, 15, 8, 4, 2] for offset in [0, 3, 8, 14, 16]
    ] + [{
        'impl': 'vslideup_i16m4',
        'dtype': np.int16,
        'vlmax': 32,
        'vl': vl,
        'offset': offset
    } for vl in [32, 31, 16, 8, 4] for offset in [0, 4, 16, 30, 32]] + [
        {
            'impl': 'vslideup_i16m8',
            'dtype': np.int16,
            'vlmax': 64,
            'vl': vl,
            'offset': offset
        } for vl in [64, 63, 32, 16, 8] for offset in [0, 5, 32, 62, 64]
    ] + [{
        'impl': 'vslideup_i32m1',
        'dtype': np.int32,
        'vlmax': 4,
        'vl': vl,
        'offset': offset
    } for vl in [4, 3, 2, 1] for offset in [0, 1, 2, 4]] + [{
        'impl': 'vslideup_i32m2',
        'dtype': np.int32,
        'vlmax': 8,
        'vl': vl,
        'offset': offset
    } for vl in [8, 7, 4, 2, 1] for offset in [0, 2, 4, 6, 8]] + [
        {
            'impl': 'vslideup_i32m4',
            'dtype': np.int32,
            'vlmax': 16,
            'vl': vl,
            'offset': offset
        } for vl in [16, 15, 8, 4, 2] for offset in [0, 3, 8, 14, 16]
    ] + [{
        'impl': 'vslideup_i32m8',
        'dtype': np.int32,
        'vlmax': 32,
        'vl': vl,
        'offset': offset
    } for vl in [32, 31, 16, 8, 4] for offset in [0, 4, 16, 30, 32]]
    await vslide_test(dut, cases, expfunc)


@cocotb.test()
async def vslidedown_test(dut):
    """Test slidedown usage accessible from intrinsics."""

    def expfunc(dest, src, scalar, vl, offset, vlmax):
        res = np.zeros(vl, dtype=src.dtype)
        for i in range(vl):
            if i + offset < vlmax:
                res[i] = src[i + offset]
            else:
                res[i] = 0
        return res

    cases = [{
        'impl': 'vslidedown_i8mf4',
        'dtype': np.int8,
        'vlmax': 4,
        'vl': vl,
        'offset': offset
    } for vl in [4, 3, 2, 1] for offset in [0, 1, 2, 4, 5]] + [{
        'impl': 'vslidedown_i8mf2',
        'dtype': np.int8,
        'vlmax': 8,
        'vl': vl,
        'offset': offset
    } for vl in [8, 7, 4, 2, 1] for offset in [0, 2, 6, 8, 9]] + [
        {
            'impl': 'vslidedown_i8m1',
            'dtype': np.int8,
            'vlmax': 16,
            'vl': vl,
            'offset': offset
        } for vl in [16, 15, 8, 4, 2, 1] for offset in [0, 2, 7, 14, 16, 17]
    ] + [{
        'impl': 'vslidedown_i8m2',
        'dtype': np.int8,
        'vlmax': 32,
        'vl': vl,
        'offset': offset
    } for vl in [32, 31, 16, 8, 4] for offset in [0, 4, 16, 30, 32, 33]] + [
        {
            'impl': 'vslidedown_i8m4',
            'dtype': np.int8,
            'vlmax': 64,
            'vl': vl,
            'offset': offset
        } for vl in [64, 63, 32, 16, 4] for offset in [0, 5, 32, 62, 64, 65]
    ] + [{
        'impl': 'vslidedown_i8m8',
        'dtype': np.int8,
        'vlmax': 128,
        'vl': vl,
        'offset': offset
    }
         for vl in [128, 127, 64, 32, 8]
         for offset in [0, 6, 64, 126, 128, 129]] + [{
             'impl': 'vslidedown_i16mf2',
             'dtype': np.int16,
             'vlmax': 4,
             'vl': vl,
             'offset': offset
         } for vl in [4, 3, 2, 1] for offset in [0, 1, 2, 4, 5]] + [
             {
                 'impl': 'vslidedown_i16m1',
                 'dtype': np.int16,
                 'vlmax': 8,
                 'vl': vl,
                 'offset': offset
             } for vl in [8, 7, 4, 3, 2, 1] for offset in [0, 2, 4, 6, 8, 9]
         ] + [{
             'impl': 'vslidedown_i16m2',
             'dtype': np.int16,
             'vlmax': 16,
             'vl': vl,
             'offset': offset
         } for vl in [16, 15, 8, 4, 2] for offset in [0, 3, 8, 14, 16, 17]] + [
             {
                 'impl': 'vslidedown_i16m4',
                 'dtype': np.int16,
                 'vlmax': 32,
                 'vl': vl,
                 'offset': offset
             }
             for vl in [32, 31, 16, 8, 4]
             for offset in [0, 4, 16, 30, 32, 33]
         ] + [{
             'impl': 'vslidedown_i16m8',
             'dtype': np.int16,
             'vlmax': 64,
             'vl': vl,
             'offset': offset
         }
              for vl in [64, 63, 32, 16, 8]
              for offset in [0, 5, 32, 62, 64, 65]] + [{
                  'impl': 'vslidedown_i32m1',
                  'dtype': np.int32,
                  'vlmax': 4,
                  'vl': vl,
                  'offset': offset
              } for vl in [4, 3, 2, 1] for offset in [0, 1, 2, 4, 5]] + [
                  {
                      'impl': 'vslidedown_i32m2',
                      'dtype': np.int32,
                      'vlmax': 8,
                      'vl': vl,
                      'offset': offset
                  } for vl in [8, 7, 4, 2, 1] for offset in [0, 2, 4, 6, 8, 9]
              ] + [{
                  'impl': 'vslidedown_i32m4',
                  'dtype': np.int32,
                  'vlmax': 16,
                  'vl': vl,
                  'offset': offset
              }
                   for vl in [16, 15, 8, 4, 2]
                   for offset in [0, 3, 8, 14, 16, 17]] + [
                       {
                           'impl': 'vslidedown_i32m8',
                           'dtype': np.int32,
                           'vlmax': 32,
                           'vl': vl,
                           'offset': offset
                       }
                       for vl in [32, 31, 16, 8, 4]
                       for offset in [0, 4, 16, 30, 32, 33]
                   ]
    await vslide_test(dut, cases, expfunc)


@cocotb.test()
async def vslide1up_test(dut):
    """Test slide1up usage accessible from intrinsics."""

    def expfunc(dest, src, scalar, vl, offset, vlmax):
        if vl == 0:
            return np.array([], dtype=src.dtype)
        return np.concat((scalar, src[0:max(vl - 1, 0)]))

    cases = [{
        'impl': 'vslide1up_i8mf4',
        'dtype': np.int8,
        'vlmax': 4,
        'vl': vl,
        'offset': 0
    } for vl in [4, 3, 2, 1]] + [{
        'impl': 'vslide1up_i8mf2',
        'dtype': np.int8,
        'vlmax': 8,
        'vl': vl,
        'offset': 0
    } for vl in [8, 7, 4, 2, 1]] + [{
        'impl': 'vslide1up_i8m1',
        'dtype': np.int8,
        'vlmax': 16,
        'vl': vl,
        'offset': 0
    } for vl in [16, 15, 8, 4, 2, 1]] + [{
        'impl': 'vslide1up_i8m2',
        'dtype': np.int8,
        'vlmax': 32,
        'vl': vl,
        'offset': 0
    } for vl in [32, 31, 16, 8, 4]] + [{
        'impl': 'vslide1up_i8m4',
        'dtype': np.int8,
        'vlmax': 64,
        'vl': vl,
        'offset': 0
    } for vl in [64, 63, 32, 16, 4]] + [{
        'impl': 'vslide1up_i8m8',
        'dtype': np.int8,
        'vlmax': 128,
        'vl': vl,
        'offset': 0
    } for vl in [128, 127, 64, 32, 8]] + [{
        'impl': 'vslide1up_i16mf2',
        'dtype': np.int16,
        'vlmax': 4,
        'vl': vl,
        'offset': 0
    } for vl in [4, 3, 2, 1]] + [{
        'impl': 'vslide1up_i16m1',
        'dtype': np.int16,
        'vlmax': 8,
        'vl': vl,
        'offset': 0
    } for vl in [8, 7, 4, 2, 1]] + [{
        'impl': 'vslide1up_i16m2',
        'dtype': np.int16,
        'vlmax': 16,
        'vl': vl,
        'offset': 0
    } for vl in [16, 15, 8, 4, 2]] + [{
        'impl': 'vslide1up_i16m4',
        'dtype': np.int16,
        'vlmax': 32,
        'vl': vl,
        'offset': 0
    } for vl in [32, 31, 16, 8, 4]] + [{
        'impl': 'vslide1up_i16m8',
        'dtype': np.int16,
        'vlmax': 64,
        'vl': vl,
        'offset': 0
    } for vl in [64, 63, 32, 16, 8]] + [{
        'impl': 'vslide1up_i32m1',
        'dtype': np.int32,
        'vlmax': 4,
        'vl': vl,
        'offset': 0
    } for vl in [4, 3, 2, 1]] + [{
        'impl': 'vslide1up_i32m2',
        'dtype': np.int32,
        'vlmax': 8,
        'vl': vl,
        'offset': 0
    } for vl in [8, 7, 4, 2, 1]] + [{
        'impl': 'vslide1up_i32m4',
        'dtype': np.int32,
        'vlmax': 16,
        'vl': vl,
        'offset': 0
    } for vl in [16, 15, 8, 4, 2]] + [{
        'impl': 'vslide1up_i32m8',
        'dtype': np.int32,
        'vlmax': 32,
        'vl': vl,
        'offset': 0
    } for vl in [32, 31, 16, 8, 4]]
    await vslide_test(dut, cases, expfunc)


@cocotb.test()
async def vslide1down_test(dut):
    """Test slide1down usage accessible from intrinsics."""

    def expfunc(dest, src, scalar, vl, offset, vlmax):
        res = np.zeros(vl, dtype=src.dtype)
        for i in range(vl):
            if i == vl - 1:
                res[i] = scalar[0]
            elif i + 1 < vlmax:
                res[i] = src[i + 1]
            else:
                res[i] = 0
        return res

    cases = [{
        'impl': 'vslide1down_i8mf4',
        'dtype': np.int8,
        'vlmax': 4,
        'vl': vl,
        'offset': 0
    } for vl in [4, 3, 2, 1]] + [{
        'impl': 'vslide1down_i8mf2',
        'dtype': np.int8,
        'vlmax': 8,
        'vl': vl,
        'offset': 0
    } for vl in [8, 7, 4, 2, 1]] + [{
        'impl': 'vslide1down_i8m1',
        'dtype': np.int8,
        'vlmax': 16,
        'vl': vl,
        'offset': 0
    } for vl in [16, 15, 8, 4, 2, 1]] + [{
        'impl': 'vslide1down_i8m2',
        'dtype': np.int8,
        'vlmax': 32,
        'vl': vl,
        'offset': 0
    } for vl in [32, 31, 16, 8, 4]] + [{
        'impl': 'vslide1down_i8m4',
        'dtype': np.int8,
        'vlmax': 64,
        'vl': vl,
        'offset': 0
    } for vl in [64, 63, 32, 16, 4]] + [{
        'impl': 'vslide1down_i8m8',
        'dtype': np.int8,
        'vlmax': 128,
        'vl': vl,
        'offset': 0
    } for vl in [128, 127, 64, 32, 8]] + [{
        'impl': 'vslide1down_i16mf2',
        'dtype': np.int16,
        'vlmax': 4,
        'vl': vl,
        'offset': 0
    } for vl in [4, 3, 2, 1]] + [{
        'impl': 'vslide1down_i16m1',
        'dtype': np.int16,
        'vlmax': 8,
        'vl': vl,
        'offset': 0
    } for vl in [8, 7, 4, 2, 1]] + [{
        'impl': 'vslide1down_i16m2',
        'dtype': np.int16,
        'vlmax': 16,
        'vl': vl,
        'offset': 0
    } for vl in [16, 15, 8, 4, 2]] + [{
        'impl': 'vslide1down_i16m4',
        'dtype': np.int16,
        'vlmax': 32,
        'vl': vl,
        'offset': 0
    } for vl in [32, 31, 16, 8, 4]] + [{
        'impl': 'vslide1down_i16m8',
        'dtype': np.int16,
        'vlmax': 64,
        'vl': vl,
        'offset': 0
    } for vl in [64, 63, 32, 16, 8]] + [{
        'impl': 'vslide1down_i32m1',
        'dtype': np.int32,
        'vlmax': 4,
        'vl': vl,
        'offset': 0
    } for vl in [4, 3, 2, 1]] + [{
        'impl': 'vslide1down_i32m2',
        'dtype': np.int32,
        'vlmax': 8,
        'vl': vl,
        'offset': 0
    } for vl in [8, 7, 4, 2, 1]] + [{
        'impl': 'vslide1down_i32m4',
        'dtype': np.int32,
        'vlmax': 16,
        'vl': vl,
        'offset': 0
    } for vl in [16, 15, 8, 4, 2]] + [{
        'impl': 'vslide1down_i32m8',
        'dtype': np.int32,
        'vlmax': 32,
        'vl': vl,
        'offset': 0
    } for vl in [32, 31, 16, 8, 4]]
    await vslide_test(dut, cases, expfunc)


@cocotb.test()
async def vslide_boundary_test(dut):
    """Test vslide boundary, dynamic LMUL reduction, and masked operations."""
    fixture = await Fixture.Create(dut)
    r = runfiles.Create()
    await fixture.load_elf_and_lookup_symbols(
        r.Rlocation('coralnpu_hw/tests/cocotb/rvv/vslide_boundary_test.elf'),
        [
            'op_type',
            'use_mask',
            'vma',
            'vta',
            'sew',
            'lmul',
            'vl',
            'offset',
            'scalar',
            'mask_data',
            'vs2_data',
            'vd_orig_data',
            'result_data',
        ],
    )
    rng = np.random.default_rng(42)

    # --------------------------------------------------------------------------
    # Explicit Reproduction Case for Bug (e16, m1, avl=4, offset=2, mask=4'b0101)
    # --------------------------------------------------------------------------
    repro_sew = 1  # e16
    repro_lmul = 0  # m1
    repro_vl = 4  # AVL=4, VLMAX=8
    repro_offset = 2
    repro_vma = 0  # mu (mask undisturbed)
    repro_vta = 1  # ta
    repro_use_mask = 1
    repro_mask = np.zeros(16, dtype=np.uint8)
    repro_mask[
        0] = 0x05  # 4'b0101 -> elements 0 and 2 enabled, 1 and 3 masked out

    repro_vs2 = np.zeros(64, dtype=np.int16)
    repro_vd_orig = np.zeros(64, dtype=np.int16)
    for k in range(64):
        repro_vs2[k] = np.int16((0x1000 + k) & 0xFFFF)
        repro_vd_orig[k] = np.int16((0x2000 + k) & 0xFFFF)
    repro_vs2[2] = np.int16(-2)  # 0xFFFE
    repro_vs2[4] = np.int16(0x4BC1)  # 0x4BC1

    await fixture.write_word('op_type', 1)  # vslidedown.vi 2
    await fixture.write_word('use_mask', repro_use_mask)
    await fixture.write_word('vma', repro_vma)
    await fixture.write_word('vta', repro_vta)
    await fixture.write_word('sew', repro_sew)
    await fixture.write_word('lmul', repro_lmul)
    await fixture.write_word('vl', repro_vl)
    await fixture.write_word('offset', repro_offset)
    await fixture.write_word('scalar', 0)
    await fixture.write('mask_data', repro_mask)
    await fixture.write('vs2_data', repro_vs2)
    await fixture.write('vd_orig_data', repro_vd_orig)

    await fixture.run_to_halt()

    repro_actual = (await fixture.read('result_data',
                                       128)).view(np.int16)[:repro_vl]
    assert repro_actual[0] == np.int16(
        -2
    ), f"Repro failed at vd[0]: {hex(int(repro_actual[0]))}"
    assert repro_actual[1] == np.int16(
        0x2001
    ), f"Repro failed at vd[1]: {hex(int(repro_actual[1]))}"
    assert repro_actual[2] == np.int16(
        0x4BC1
    ), f"Repro failed at vd[2]: {hex(int(repro_actual[2]))}"
    assert repro_actual[3] == np.int16(
        0x2003
    ), f"Repro failed at vd[3]: {hex(int(repro_actual[3]))}"

    # --------------------------------------------------------------------------
    # Parameterized Sweep over SEW, LMUL, VL, Offset, and Masking Policies
    # --------------------------------------------------------------------------
    configs = [
        # (sew_val, lmul_val, lmul_factor, dtype)
        (0, 7, 0.5, np.int8),  # e8, mf2 -> VLMAX = 8
        (0, 0, 1.0, np.int8),  # e8, m1  -> VLMAX = 16
        (0, 2, 4.0, np.int8),  # e8, m4  -> VLMAX = 64
        (1, 7, 0.5, np.int16),  # e16, mf2 -> VLMAX = 4
        (1, 0, 1.0,
         np.int16),  # e16, m1  -> VLMAX = 8 (Exact bug configuration)
        (1, 1, 2.0, np.int16),  # e16, m2  -> VLMAX = 16
        (1, 3, 8.0, np.int16),  # e16, m8  -> VLMAX = 64
        (2, 0, 1.0, np.int32),  # e32, m1  -> VLMAX = 4
        (2, 2, 4.0, np.int32),  # e32, m4  -> VLMAX = 16
    ]

    mask_modes = [
        (0, 0),  # unmasked
        (1, 0),  # masked (mu - undisturbed)
        (1, 1),  # masked (ma - agnostic)
    ]

    for sew_val, lmul_val, lmul_factor, dtype in tqdm.tqdm(configs):
        itemsize = np.dtype(dtype).itemsize
        vlmax = int(lmul_factor * 128 / (itemsize * 8))

        vl_list = sorted(list(set([1, max(1, vlmax // 2), vlmax])))
        offset_list = sorted(
            list(set([0, 2, max(1, vlmax // 2), vlmax, vlmax + 1]))
        )

        for vl in vl_list:
            for offset in offset_list:
                for use_mask, vma in mask_modes:
                    num_elements = 128 // itemsize
                    vs2_data = rng.integers(
                        low=np.iinfo(dtype).min,
                        high=np.iinfo(dtype).max + 1,
                        size=num_elements,
                        dtype=dtype
                    )
                    vd_orig_data = rng.integers(
                        low=np.iinfo(dtype).min,
                        high=np.iinfo(dtype).max + 1,
                        size=num_elements,
                        dtype=dtype
                    )
                    scalar_val = int(
                        rng.integers(
                            low=np.iinfo(dtype).min,
                            high=np.iinfo(dtype).max + 1,
                            size=1,
                            dtype=dtype
                        )[0]
                    )

                    mask_bytes = np.array(
                        [0x55] * 16, dtype=np.uint8
                    ) if use_mask else np.array([0xFF] * 16, dtype=np.uint8)

                    ops_to_test = [0]
                    if offset == 2:
                        ops_to_test.append(1)
                    if offset <= vl:
                        ops_to_test.append(2)
                    if offset == 0:
                        ops_to_test.append(3)
                        ops_to_test.append(4)

                    for op in ops_to_test:
                        expected_vl = np.zeros(vl, dtype=dtype)
                        for i in range(vl):
                            mask_bit = 1 if not use_mask else (
                                (mask_bytes[i // 8] >> (i % 8)) & 1
                            )
                            if mask_bit == 0 and vma == 0:  # mu
                                expected_vl[i] = vd_orig_data[i]
                            elif mask_bit == 0 and vma == 1:  # ma
                                expected_vl[i] = vd_orig_data[i]
                            else:
                                if op in (0, 1):  # vslidedown
                                    eff_offset = 2 if op == 1 else offset
                                    if i + eff_offset < vlmax:
                                        expected_vl[i] = vs2_data[i +
                                                                  eff_offset]
                                    else:
                                        expected_vl[i] = 0
                                elif op == 2:  # vslideup
                                    if i < offset:
                                        expected_vl[i] = vd_orig_data[i]
                                    else:
                                        expected_vl[i] = vs2_data[i - offset]
                                elif op == 3:  # vslide1down
                                    if i == vl - 1:
                                        expected_vl[i] = scalar_val
                                    elif i + 1 < vlmax:
                                        expected_vl[i] = vs2_data[i + 1]
                                    else:
                                        expected_vl[i] = 0
                                elif op == 4:  # vslide1up
                                    if i == 0:
                                        expected_vl[i] = scalar_val
                                    else:
                                        expected_vl[i] = vs2_data[i - 1]

                        await fixture.write_word('op_type', op)
                        await fixture.write_word('use_mask', use_mask)
                        await fixture.write_word('vma', vma)
                        await fixture.write_word('vta', 1)
                        await fixture.write_word('sew', sew_val)
                        await fixture.write_word('lmul', lmul_val)
                        await fixture.write_word('vl', vl)
                        await fixture.write_word('offset', offset)
                        await fixture.write_word(
                            'scalar', scalar_val & 0xFFFFFFFF
                        )
                        await fixture.write('mask_data', mask_bytes)
                        await fixture.write('vs2_data', vs2_data)
                        await fixture.write('vd_orig_data', vd_orig_data)

                        await fixture.run_to_halt()

                        actual_data = (await
                                       fixture.read('result_data',
                                                    128)).view(dtype)[:vl]

                        for i in range(vl):
                            mask_bit = 1 if not use_mask else (
                                (mask_bytes[i // 8] >> (i % 8)) & 1
                            )
                            if mask_bit == 1 or vma == 0:
                                assert actual_data[i] == expected_vl[i], (
                                    f"Mismatch at element {i}: actual={hex(int(actual_data[i]))}, "
                                    f"expected={hex(int(expected_vl[i]))}, op={op}, use_mask={use_mask}, "
                                    f"sew={sew_val}, lmul={lmul_val}, vl={vl}, offset={offset}, vlmax={vlmax}"
                                )


async def vgather1_test(dut, cases):
    """Test gather usage accessible from intrinsics."""
    fixture = await Fixture.Create(dut)
    r = runfiles.Create()
    await fixture.load_elf_and_lookup_symbols(
        r.Rlocation('coralnpu_hw/tests/cocotb/rvv/vgather.elf'),
        [
            'rvv_shuffle',
            'input_value8',
            'input_index8',
            'output_value8',
            'input_value16',
            'input_index16',
            'output_value16',
            'n',
        ] + [c['rvv_shuffle'] for c in cases],
    )
    rng = np.random.default_rng()
    for c in tqdm.tqdm(cases):
        rvv_shuffle = c['rvv_shuffle']
        n = c['n']
        dtype = c['dtype']
        values = np.array(rng.choice(np.arange(0, 255), size=n), dtype=dtype)
        index = np.array(
            rng.choice(np.arange(0, n), size=n, replace=False), dtype=dtype
        )
        expected_output = np.take_along_axis(values, index)
        if dtype == np.uint8:
            input_value_buf = 'input_value8'
            input_index_buf = 'input_index8'
            output_value_buf = 'output_value8'
        elif dtype == np.uint16:
            input_value_buf = 'input_value16'
            input_index_buf = 'input_index16'
            output_value_buf = 'output_value16'
        await fixture.write_ptr('rvv_shuffle', rvv_shuffle)
        await fixture.write_word('n', n)
        await fixture.write(input_value_buf, values)
        await fixture.write(input_index_buf, index)
        await fixture.run_to_halt()
        actual_output = (
            await fixture.read(output_value_buf,
                               n * np.dtype(dtype).itemsize)
        ).view(dtype)
        debug_msg = str({
            'rvv_shuffle': rvv_shuffle,
            'n': n,
            'input_value': values,
            'input_index': index,
            'output_value': output_value_buf,
            'expected': expected_output,
            'actual': actual_output,
        })
        assert (actual_output == expected_output).all(), debug_msg


@cocotb.test()
async def vgather_test(dut):
    """Test gather usage accessible from intrinsics."""
    cases = [{
        'rvv_shuffle': 'vgather_d8mf2_i8mf2',
        'n': n,
        'dtype': np.uint8,
    } for n in [2, 4, 8]] + [{
        'rvv_shuffle': 'vgather_d8m1_i8m1',
        'n': n,
        'dtype': np.uint8,
    } for n in [2, 4, 8]] + [{
        'rvv_shuffle': 'vgather_d8m2_i8m2',
        'n': n,
        'dtype': np.uint8,
    } for n in [2, 4, 8]] + [{
        'rvv_shuffle': 'vgather_d8m4_i8m4',
        'n': n,
        'dtype': np.uint8,
    } for n in [2, 4, 8]] + [{
        'rvv_shuffle': 'vgather_d8m8_i8m8',
        'n': n,
        'dtype': np.uint8,
    } for n in [2, 4, 8]] + [{
        'rvv_shuffle': 'vgather_d16mf2_i16mf2',
        'n': n,
        'dtype': np.uint16,
    } for n in [2, 4]] + [{
        'rvv_shuffle': 'vgather_d16m1_i16m1',
        'n': n,
        'dtype': np.uint16,
    } for n in [2, 4, 8]] + [{
        'rvv_shuffle': 'vgather_d16m2_i16m2',
        'n': n,
        'dtype': np.uint16,
    } for n in [2, 4, 8, 16]] + [{
        'rvv_shuffle': 'vgather_d16m4_i16m4',
        'n': n,
        'dtype': np.uint16,
    } for n in [2, 4, 8, 16]] + [{
        'rvv_shuffle': 'vgather_d16m8_i16m8',
        'n': n,
        'dtype': np.uint16,
    } for n in [2, 4, 8, 16]]
    await vgather1_test(dut, cases)


@cocotb.test()
async def vstart_test(dut):
    """Test vstart usage."""
    fixture = await Fixture.Create(dut)
    r = runfiles.Create()
    await fixture.load_elf_and_lookup_symbols(
        r.Rlocation('coralnpu_hw/tests/cocotb/rvv/vstart_test.elf'), [
            'vstart',
            'vstart_reset',
            'data_input',
            'reg',
            'n',
        ]
    )
    for test_vstart_val in range(1, 8, 1):
        n = 'n'
        test_vstart_val = test_vstart_val
        data_array = np.zeros(128, dtype=np.uint16)
        data_array[8:16] = np.arange(80, 72, -1)
        data_array[16:24] = np.arange(70, 62, -1)
        expected_output = np.zeros(128, dtype=np.uint16)
        expected_output[0:8] = data_array[8:16]
        expected_output[18:26] = data_array[16:24]
        expected_output[36 + test_vstart_val:44] = data_array[
            8 + test_vstart_val:16] + data_array[16 + test_vstart_val:24]
        expected_output[54 + test_vstart_val:62] = data_array[
            8 + test_vstart_val:16] + data_array[16 + test_vstart_val:24]

        data_input_buf = 'data_input'
        reg_buf = 'reg'
        vstart_buf = 'vstart'

        await fixture.write(data_input_buf, data_array)
        await fixture.write(
            vstart_buf, np.array([test_vstart_val], dtype=np.uint32)
        )
        await fixture.run_to_halt()
        actual_data = (
            await
            fixture.read(data_input_buf, 128 * np.dtype(np.uint16).itemsize)
        ).view(np.uint16)
        actual_output = (
            await fixture.read(reg_buf, 128 * np.dtype(np.uint16).itemsize)
        ).view(np.uint16)
        actual_vstart = (
            await fixture.read(vstart_buf,
                               np.dtype(np.uint32).itemsize)
        ).view(np.uint32)

        debug_msg = str({
            'data_input': data_input_buf,
            'output': actual_output,
            'reg': reg_buf,
            'n': n,
            'vstart': actual_vstart,
        })
        assert (actual_output == expected_output).all(), (
            f"Output mismatch!\n{debug_msg}\n"
            f"Actual (indices 0-127):\n{actual_output[0:127]}\n"
            f"Expected (indices 0-127):\n{expected_output[0:127]}"
        )
