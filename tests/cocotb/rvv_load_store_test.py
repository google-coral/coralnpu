# Copyright 2025 Google LLC
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

import cocotb
import itertools
import numpy as np
import tqdm

from bazel_tools.tools.python.runfiles import runfiles
from coralnpu_test_utils.rvv_type_util import construct_vtype, DTYPE_TO_SEW, SEWS, SEW_TO_LMULS_AND_VLMAXS, LMUL_TO_EMUL
from coralnpu_test_utils.sim_test_fixture import Fixture


async def vector_load_store(
    dut,
    elf_name: str,
    dtype,
    in_size: int,
    out_size: int,
    pattern: list[int],
):
    """RVV load-store test template.

    Each test performs some kind of patterned copy from `in_buf` to `out_buf`.
    """
    fixture = await Fixture.Create(dut)
    r = runfiles.Create()
    await fixture.load_elf_and_lookup_symbols(
        r.Rlocation('coralnpu_hw/tests/cocotb/rvv/load_store/' + elf_name),
        ['in_buf', 'out_buf'],
    )

    min_value = np.iinfo(dtype).min
    max_value = np.iinfo(dtype).max + 1  # One above.
    rng = np.random.default_rng()
    input_data = rng.integers(min_value, max_value, in_size, dtype=dtype)
    expected_outputs = input_data[pattern]
    sbz = np.zeros(out_size - len(pattern), dtype=dtype)
    expected_outputs = np.concat((expected_outputs, sbz))

    await fixture.write('in_buf', input_data)
    await fixture.write('out_buf', np.zeros([out_size], dtype=dtype))

    await fixture.run_to_halt()

    actual_outputs = (
        await fixture.read('out_buf',
                           out_size * np.dtype(dtype).itemsize)
    ).view(dtype)
    debug_msg = str({
        'input': input_data,
        'expected': expected_outputs,
        'actual': actual_outputs,
    })

    assert (actual_outputs == expected_outputs).all(), debug_msg


async def vector_load_store_v2(
    dut,
    elf_name: str,
    cases: list[dict],  # keys: impl, vl, in_size, out_size, pattern.
    dtype,
):
    """RVV load-store test template.

    Each test performs some kind of patterned copy from `in_buf` to `out_buf`.
    """
    fixture = await Fixture.Create(dut)
    r = runfiles.Create()
    await fixture.load_elf_and_lookup_symbols(
        r.Rlocation('coralnpu_hw/tests/cocotb/rvv/load_store/' + elf_name),
        ['impl', 'vl', 'in_buf', 'out_buf'] + list({c['impl']
                                                    for c in cases}),
    )

    min_value = np.iinfo(dtype).min
    max_value = np.iinfo(dtype).max + 1  # One above.
    rng = np.random.default_rng()
    for c in tqdm.tqdm(cases):
        impl = c['impl']
        vl = c['vl']
        in_size = c['in_size']
        out_size = c['out_size']
        pattern = c['pattern']

        input_data = rng.integers(min_value, max_value, in_size, dtype=dtype)
        expected_outputs = input_data[pattern]
        sbz = np.zeros(out_size - len(pattern), dtype=dtype)
        expected_outputs = np.concat((expected_outputs, sbz))

        await fixture.write_ptr('impl', impl)
        await fixture.write_word('vl', vl)
        await fixture.write('in_buf', input_data)
        await fixture.write('out_buf', np.zeros([out_size], dtype=dtype))

        await fixture.run_to_halt()

        actual_outputs = (
            await fixture.read('out_buf',
                               out_size * np.dtype(dtype).itemsize)
        ).view(dtype)

        debug_msg = str({
            'impl': impl,
            'input': input_data,
            'expected': expected_outputs,
            'actual': actual_outputs,
        })
        assert (actual_outputs == expected_outputs).all(), debug_msg


async def vector_load_segmented_indexed(
    dut,
    elf_name: str,
    cases: list[dict],  # keys: impl, vl, segments, in_bytes, out_size.
    dtype,
    index_dtype,
):
    """RVV load-store test template for segmented indexed loads.

    Each test performs a gather-unzip operation and writes the result to an output.
    """
    fixture = await Fixture.Create(dut)
    r = runfiles.Create()
    await fixture.load_elf_and_lookup_symbols(
        r.Rlocation('coralnpu_hw/tests/cocotb/rvv/load_store/' + elf_name),
        ['impl', 'vl', 'in_buf', 'out_buf', 'index_buf'] +
        list({c['impl']
              for c in cases}),
    )

    rng = np.random.default_rng()
    for c in tqdm.tqdm(cases):
        impl = c['impl']
        vl = c['vl']
        segments = c['segments']
        in_bytes = c['in_bytes']
        out_size = c['out_size']

        # Don't go beyond the buffer.
        index_max = min(
            in_bytes - segments * np.dtype(dtype).itemsize,
            np.iinfo(index_dtype).max
        )
        # TODO(davidgao): currently assuming the vl is supported.
        # We'll eventually want to test unsupported vl.
        indices = rng.integers(0, index_max + 1, out_size, dtype=index_dtype)
        # Index is in bytes so input needs to be in bytes.
        input_data = rng.integers(0, 256, in_bytes, dtype=np.uint8)
        # Input needs to be reinterpreted. Note indices in use can reach
        # beyond index_dtype when dtype is wider than uint8 or when segments
        # is >1.
        indices_in_use = \
            np.arange(segments).reshape(-1, 1, 1) * np.dtype(dtype).itemsize + \
            indices[:vl].reshape(1, -1, 1) + \
            np.arange(np.dtype(dtype).itemsize).reshape(1, 1, -1)
        indices_in_use = indices_in_use.reshape(-1)
        expected_outputs = input_data[indices_in_use].view(dtype)
        sbz = np.zeros(out_size - vl * segments, dtype=dtype)
        expected_outputs = np.concat((expected_outputs, sbz))

        await fixture.write_ptr('impl', impl)
        await fixture.write_word('vl', vl)
        await fixture.write('index_buf', indices)
        await fixture.write('in_buf', input_data)
        await fixture.write('out_buf', np.zeros([out_size], dtype=dtype))

        await fixture.run_to_halt()

        actual_outputs = (
            await fixture.read('out_buf',
                               out_size * np.dtype(dtype).itemsize)
        ).view(dtype)

        debug_msg = str({
            'impl': impl,
            'input': input_data,
            'indices': indices,
            'indices_in_use': indices_in_use[..., 0],
            'expected': expected_outputs,
            'actual': actual_outputs,
        })
        assert (actual_outputs == expected_outputs).all(), debug_msg


async def vector_store_segmented_indexed(
    dut,
    elf_name: str,
    cases: list[dict],  # keys: impl, vl, segments, out_size.
    data_dtype,
    index_dtype,
):
    """RVV load-store test template for segmented indexed stores.

    Each test loads indices and data and performs a scatter operation.
    """
    fixture = await Fixture.Create(dut)
    r = runfiles.Create()
    await fixture.load_elf_and_lookup_symbols(
        r.Rlocation('coralnpu_hw/tests/cocotb/rvv/load_store/' + elf_name),
        ['impl', 'vl', 'in_buf', 'out_buf', 'index_buf'] +
        list({c['impl']
              for c in cases}),
    )

    rng = np.random.default_rng()
    for c in tqdm.tqdm(cases):
        impl = c['impl']
        vl = c['vl']
        segments = c['segments']
        out_size = c['out_size']

        struct_bytes = np.dtype(data_dtype).itemsize * segments
        # Don't go beyond the buffer.
        index_max = min(
            np.iinfo(index_dtype).max,
            out_size * np.dtype(data_dtype).itemsize
        )
        assert vl * struct_bytes <= index_max
        index_max = index_max - struct_bytes
        # TODO(davidgao): currently assuming the vl is supported.
        # We'll eventually want to test unsupported vl.
        indices = rng.integers(0, index_max + 1, vl, dtype=index_dtype)
        # Deal with overlapping indices by rerunning them
        exclusion_set = set()
        retries = 0
        for i in range(vl):
            # If the scatter range is too dense and we're struggling to find
            # space, the test could timeout and become flaky. Flag it here
            # to be reconfigured.
            assert retries < 10000
            while (indices[i] in exclusion_set or \
               indices[i] + struct_bytes - 1 in exclusion_set):
                indices[i] = rng.integers(0, index_max + 1, 1)[0]
                retries = retries + 1
            exclusion_set = exclusion_set.union(
                range(indices[i], indices[i] + struct_bytes)
            )
        input_data = rng.integers(
            0, np.iinfo(data_dtype).max + 1, segments * vl, dtype=data_dtype
        )
        # Index is in bytes so output needs to be in bytes.
        output_data = np.zeros(
            out_size * np.dtype(data_dtype).itemsize, dtype=np.uint8
        )
        # Compute expected outputs. Note that indices are in bytes for all stores.
        expected_outputs = output_data.copy()
        elem_size = np.dtype(data_dtype).itemsize
        input_data_bytes = input_data.view(np.uint8)
        indices_in_use = indices.astype(np.uint32)
        indices_in_use = np.arange(segments).reshape(-1, 1, 1) * elem_size + \
                         indices_in_use.reshape(1, -1, 1) + \
                         np.arange(elem_size).reshape(1, 1, -1)
        indices_in_use = indices_in_use.reshape(-1)
        np.put_along_axis(
            expected_outputs, indices_in_use, input_data_bytes, None
        )
        expected_outputs = expected_outputs.view(data_dtype)

        await fixture.write_ptr('impl', impl)
        await fixture.write_word('vl', vl)
        await fixture.write('index_buf', indices)
        await fixture.write('in_buf', input_data)
        await fixture.write('out_buf', output_data)

        await fixture.run_to_halt()

        actual_outputs = (
            await
            fixture.read('out_buf',
                         out_size * np.dtype(data_dtype).itemsize)
        ).view(data_dtype)

        debug_msg = str({
            'impl': impl,
            'input': input_data,
            'indices': indices,
            'expected': expected_outputs,
            'actual': actual_outputs,
        })

        assert (actual_outputs == expected_outputs).all(), debug_msg


@cocotb.test()
async def load_store_bits(dut):
    """Test vlm/vsm usage accessible from intrinsics."""
    # mask is not accessible from here.
    fixture = await Fixture.Create(dut)
    r = runfiles.Create()
    cases = [
        {
            'impl': 'vlm_vsm_v_b1',
            'vl': 128
        },
        {
            'impl': 'vlm_vsm_v_b1',
            'vl': 121
        },
        {
            'impl': 'vlm_vsm_v_b1',
            'vl': 120
        },
        {
            'impl': 'vlm_vsm_v_b2',
            'vl': 64
        },
        {
            'impl': 'vlm_vsm_v_b2',
            'vl': 57
        },
        {
            'impl': 'vlm_vsm_v_b2',
            'vl': 56
        },
        {
            'impl': 'vlm_vsm_v_b4',
            'vl': 32
        },
        {
            'impl': 'vlm_vsm_v_b4',
            'vl': 25
        },
        {
            'impl': 'vlm_vsm_v_b4',
            'vl': 24
        },
        {
            'impl': 'vlm_vsm_v_b8',
            'vl': 16
        },
        {
            'impl': 'vlm_vsm_v_b8',
            'vl': 9
        },
        {
            'impl': 'vlm_vsm_v_b8',
            'vl': 8
        },
        {
            'impl': 'vlm_vsm_v_b16',
            'vl': 8
        },
        {
            'impl': 'vlm_vsm_v_b16',
            'vl': 1
        },
        {
            'impl': 'vlm_vsm_v_b32',
            'vl': 4
        },
        {
            'impl': 'vlm_vsm_v_b32',
            'vl': 1
        },
    ]
    await fixture.load_elf_and_lookup_symbols(
        r.Rlocation(
            'coralnpu_hw/tests/cocotb/rvv/load_store/load_store_bits.elf'
        ),
        ['vl', 'in_buf', 'out_buf', 'impl'] + list({c['impl']
                                                    for c in cases}),
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
        expected_output = input_data
        expected_output[-1] = expected_output[-1] & last_byte_mask

        await fixture.write_ptr('impl', impl)
        await fixture.write_word('vl', vl)
        await fixture.write('in_buf', input_data)
        await fixture.write('out_buf', np.zeros([in_bytes], dtype=np.uint8))

        await fixture.run_to_halt()

        actual_output = (await fixture.read('out_buf',
                                            in_bytes)).view(np.uint8)

        debug_msg = str({
            'impl': impl,
            'input': input_data,
            'expected': expected_output,
            'actual': actual_output,
        })
        assert (actual_output == expected_output).all(), debug_msg


@cocotb.test()
async def load_unit_masked(dut):
    """Test masked unit stores."""

    fixture = await Fixture.Create(dut)
    r = runfiles.Create()

    await fixture.load_elf_and_lookup_symbols(
        r.Rlocation(
            'coralnpu_hw/tests/cocotb/rvv/load_store/load_unit_masked.elf'
        ),
        [
            "impl", "vtype", "load_data", "load_addr", "vl", "load_filler",
            "mask_data", "store_data", "test_unit_load8", "test_unit_load16",
            "test_unit_load32"
        ],
    )

    cases = [
        (np.uint8, 0b110, 4),  # SEW8, mf4
        (np.uint8, 0b110, 3),  # SEW8, mf4
        (np.uint8, 0b111, 8),  # SEW8, mf2
        (np.uint8, 0b111, 7),  # SEW8, mf2
        (np.uint8, 0b000, 16),  # SEW8, m1
        (np.uint8, 0b000, 15),  # SEW8, m1
        (np.uint8, 0b001, 32),  # SEW8, m2
        (np.uint8, 0b001, 31),  # SEW8, m2
        (np.uint8, 0b010, 64),  # SEW8, m4
        (np.uint8, 0b010, 63),  # SEW8, m4
        (np.uint8, 0b011, 128),  # SEW8, m8
        (np.uint8, 0b011, 127),  # SEW8, m8
        (np.uint16, 0b111, 4),  # SEW16, mf2
        (np.uint16, 0b111, 3),  # SEW16, mf2
        (np.uint16, 0b000, 8),  # SEW16, m1
        (np.uint16, 0b000, 7),  # SEW16, m1
        (np.uint16, 0b001, 16),  # SEW16, m2
        (np.uint16, 0b001, 15),  # SEW16, m2
        (np.uint16, 0b010, 32),  # SEW16, m4
        (np.uint16, 0b010, 31),  # SEW16, m4
        (np.uint16, 0b011, 64),  # SEW16, m8
        (np.uint16, 0b011, 63),  # SEW16, m8
        (np.uint32, 0b000, 4),  # SEW32, m1
        (np.uint32, 0b000, 3),  # SEW32, m1
        (np.uint32, 0b001, 8),  # SEW32, m2
        (np.uint32, 0b001, 7),  # SEW32, m2
        (np.uint32, 0b010, 16),  # SEW32, m4
        (np.uint32, 0b010, 15),  # SEW32, m4
        (np.uint32, 0b011, 32),  # SEW32, m8
        (np.uint32, 0b011, 31),  # SEW32, m8
    ]

    dtype_to_function = {
        np.uint8: "test_unit_load8",
        np.uint16: "test_unit_load16",
        np.uint32: "test_unit_load32",
    }

    all_cases = itertools.product([False, True], cases)
    total_loops = 2 * len(cases)

    rng = np.random.default_rng()
    for use_axi, (dtype, lmul, vl) in tqdm.tqdm(all_cases, total=total_loops):
        # mask and tail undisturbed for this test.
        vtype = construct_vtype(0, 0, DTYPE_TO_SEW[dtype], lmul)
        mask_bytes = (vl + 7) // 8
        mask_data = rng.integers(0, 256, mask_bytes, dtype=np.uint8)
        min_value = np.iinfo(dtype).min
        max_value = np.iinfo(dtype).max + 1
        load_data = rng.integers(min_value, max_value, vl, dtype=dtype)
        load_filler = np.iinfo(dtype).max

        if use_axi:
            await fixture.write_word(
                'load_addr', fixture.core_mini_axi.memory_base_addr
            )

        await fixture.write_ptr('impl', dtype_to_function[dtype])
        await fixture.write_word('vl', vl)
        await fixture.write_word('load_filler', load_filler)
        await fixture.write_word('vtype', vtype)
        if use_axi:
            load_data_size = vl * np.dtype(dtype).itemsize
            fixture.core_mini_axi.memory[0:load_data_size] = \
                load_data.view(np.uint8)
        else:
            await fixture.write('load_data', load_data)
        await fixture.write('mask_data', mask_data)

        await fixture.run_to_halt()

        actual_output = (
            await fixture.read('store_data',
                               vl * np.dtype(dtype).itemsize)
        ).view(dtype)

        mask_bits = np.concat([
            list(reversed(np.unpackbits(x))) for x in mask_data
        ])
        for i in range(vl):
            if mask_bits[i]:
                assert load_data[i] == actual_output[i]
            else:
                assert load_filler == actual_output[i]


@cocotb.test()
async def store_unit_masked(dut):
    """Test masked unit stores."""
    fixture = await Fixture.Create(dut)
    r = runfiles.Create()

    await fixture.load_elf_and_lookup_symbols(
        r.Rlocation(
            'coralnpu_hw/tests/cocotb/rvv/load_store/store_unit_masked.elf'
        ),
        [
            "impl", "vtype", "load_data", "vl", "mask_data", "store_data",
            "store_addr", "test_unit_store8", "test_unit_store16",
            "test_unit_store32"
        ],
    )

    cases = [
        (np.uint8, 0b110, 4),  # SEW8, mf4
        (np.uint8, 0b110, 3),  # SEW8, mf4
        (np.uint8, 0b111, 8),  # SEW8, mf2
        (np.uint8, 0b111, 7),  # SEW8, mf2
        (np.uint8, 0b000, 16),  # SEW8, m1
        (np.uint8, 0b000, 15),  # SEW8, m1
        (np.uint8, 0b001, 32),  # SEW8, m2
        (np.uint8, 0b001, 31),  # SEW8, m2
        (np.uint8, 0b010, 64),  # SEW8, m4
        (np.uint8, 0b010, 63),  # SEW8, m4
        (np.uint8, 0b011, 128),  # SEW8, m8
        (np.uint8, 0b011, 127),  # SEW8, m8
        (np.uint16, 0b111, 4),  # SEW16, mf2
        (np.uint16, 0b111, 3),  # SEW16, mf2
        (np.uint16, 0b000, 8),  # SEW16, m1
        (np.uint16, 0b000, 7),  # SEW16, m1
        (np.uint16, 0b001, 16),  # SEW16, m2
        (np.uint16, 0b001, 15),  # SEW16, m2
        (np.uint16, 0b010, 32),  # SEW16, m4
        (np.uint16, 0b010, 31),  # SEW16, m4
        (np.uint16, 0b011, 64),  # SEW16, m8
        (np.uint16, 0b011, 63),  # SEW16, m8
        (np.uint32, 0b000, 4),  # SEW32, m1
        (np.uint32, 0b000, 3),  # SEW32, m1
        (np.uint32, 0b001, 8),  # SEW32, m2
        (np.uint32, 0b001, 7),  # SEW32, m2
        (np.uint32, 0b010, 16),  # SEW32, m4
        (np.uint32, 0b010, 15),  # SEW32, m4
        (np.uint32, 0b011, 32),  # SEW32, m8
        (np.uint32, 0b011, 31),  # SEW32, m8
    ]

    dtype_to_function = {
        np.uint8: "test_unit_store8",
        np.uint16: "test_unit_store16",
        np.uint32: "test_unit_store32",
    }

    all_cases = itertools.product([False, True], cases)
    total_loops = 2 * len(cases)

    rng = np.random.default_rng()
    for use_axi, (dtype, lmul, vl) in tqdm.tqdm(all_cases, total=total_loops):
        vtype = construct_vtype(1, 1, DTYPE_TO_SEW[dtype], lmul)
        mask_bytes = (vl + 7) // 8
        mask_data = rng.integers(0, 256, mask_bytes, dtype=np.uint8)
        min_value = np.iinfo(dtype).min
        max_value = np.iinfo(dtype).max + 1
        load_data = rng.integers(min_value, max_value, vl, dtype=dtype)

        if use_axi:
            await fixture.write_word(
                'store_addr', fixture.core_mini_axi.memory_base_addr
            )

        await fixture.write_ptr('impl', dtype_to_function[dtype])
        await fixture.write_word('vl', vl)
        await fixture.write_word('vtype', vtype)
        await fixture.write('load_data', load_data)
        await fixture.write('mask_data', mask_data)

        await fixture.run_to_halt()

        if use_axi:
            output_size = vl * np.dtype(dtype).itemsize
            actual_output = \
                fixture.core_mini_axi.memory[0:output_size].view(dtype)
        else:
            actual_output = (
                await
                fixture.read('store_data',
                             vl * np.dtype(dtype).itemsize)
            ).view(dtype)

        mask_bits = np.concat([
            list(reversed(np.unpackbits(x))) for x in mask_data
        ])
        for i in range(vl):
            if mask_bits[i]:
                assert load_data[i] == actual_output[i]


@cocotb.test()
async def load8_stride0_m1(dut):
    await vector_load_store(
        dut=dut,
        elf_name='load8_stride0_m1.elf',
        dtype=np.uint8,
        in_size=32,
        out_size=16,
        pattern=[0] * 16,
    )


@cocotb.test()
async def load8_stride0strict_m1(dut):
    await vector_load_store(
        dut=dut,
        elf_name='load8_stride0strict_m1.elf',
        dtype=np.uint8,
        in_size=32,
        out_size=16,
        pattern=[0] * 16,
    )


@cocotb.test()
async def load8_stride2_m1(dut):
    await vector_load_store(
        dut=dut,
        elf_name='load8_stride2_m1.elf',
        dtype=np.uint8,
        in_size=32,
        out_size=16,
        pattern=list(range(0, 31, 2)),
    )


@cocotb.test()
async def load8_stride2_m1_partial(dut):
    await vector_load_store(
        dut=dut,
        elf_name='load8_stride2_m1_partial.elf',
        dtype=np.uint8,
        in_size=32,
        out_size=16,
        pattern=list(range(0, 29, 2)),
    )


@cocotb.test()
async def load8_stride2_mf4(dut):
    await vector_load_store(
        dut=dut,
        elf_name='load8_stride2_mf4.elf',
        dtype=np.uint8,
        in_size=32,
        out_size=16,
        pattern=[0, 2, 4, 6],
    )


@cocotb.test()
async def load16_stride4_m1(dut):
    await vector_load_store(
        dut=dut,
        elf_name='load16_stride4_m1.elf',
        dtype=np.uint16,
        in_size=16,
        out_size=8,
        pattern=list(range(0, 15, 2)),
    )


@cocotb.test()
async def load16_stride4_m1_partial(dut):
    await vector_load_store(
        dut=dut,
        elf_name='load16_stride4_m1_partial.elf',
        dtype=np.uint16,
        in_size=16,
        out_size=8,
        pattern=list(range(0, 13, 2)),
    )


@cocotb.test()
async def load16_stride4_mf2(dut):
    await vector_load_store(
        dut=dut,
        elf_name='load16_stride4_mf2.elf',
        dtype=np.uint16,
        in_size=16,
        out_size=8,
        pattern=[0, 2, 4, 6],
    )


@cocotb.test()
async def load32_stride8_m1(dut):
    await vector_load_store(
        dut=dut,
        elf_name='load32_stride8_m1.elf',
        dtype=np.uint32,
        in_size=8,
        out_size=4,
        pattern=[0, 2, 4, 6],
    )


@cocotb.test()
async def load32_stride8_m1_partial(dut):
    await vector_load_store(
        dut=dut,
        elf_name='load32_stride8_m1_partial.elf',
        dtype=np.uint32,
        in_size=8,
        out_size=4,
        pattern=[0, 2, 4],
    )


@cocotb.test()
async def load_store8_unit_m2(dut):
    await vector_load_store(
        dut=dut,
        elf_name='load_store8_unit_m2.elf',
        dtype=np.uint8,
        in_size=64,
        out_size=64,
        pattern=list(range(0, 32)),
    )


@cocotb.test()
async def load_store16_unit_m2(dut):
    await vector_load_store(
        dut=dut,
        elf_name='load_store16_unit_m2.elf',
        dtype=np.uint16,
        in_size=32,
        out_size=32,
        pattern=list(range(0, 16)),
    )


@cocotb.test()
async def load_store32_unit_m2(dut):
    await vector_load_store(
        dut=dut,
        elf_name='load_store32_unit_m2.elf',
        dtype=np.uint32,
        in_size=16,
        out_size=16,
        pattern=list(range(0, 8)),
    )


@cocotb.test()
async def load8_index8(dut):
    """Test vl*xei8_v_u8 usage accessible from intrinsics."""

    def make_test_case(impl: str, vl: int):
        return {
            'impl': impl,
            'vl': vl,
            'segments': 1,
            'in_bytes': 256,
            'out_size': vl * 2,
        }

    await vector_load_segmented_indexed(
        dut=dut,
        elf_name='load8_index8.elf',
        cases=[
            # Unordered
            make_test_case('vluxei8_v_u8mf4', vl=4),
            make_test_case('vluxei8_v_u8mf4', vl=3),
            make_test_case('vluxei8_v_u8mf2', vl=8),
            make_test_case('vluxei8_v_u8mf2', vl=7),
            make_test_case('vluxei8_v_u8m1', vl=16),
            make_test_case('vluxei8_v_u8m1', vl=15),
            make_test_case('vluxei8_v_u8m2', vl=32),
            make_test_case('vluxei8_v_u8m2', vl=31),
            make_test_case('vluxei8_v_u8m4', vl=64),
            make_test_case('vluxei8_v_u8m4', vl=63),
            make_test_case('vluxei8_v_u8m8', vl=128),
            make_test_case('vluxei8_v_u8m8', vl=127),
            # Ordered
            make_test_case('vloxei8_v_u8mf4', vl=4),
            make_test_case('vloxei8_v_u8mf4', vl=3),
            make_test_case('vloxei8_v_u8mf2', vl=8),
            make_test_case('vloxei8_v_u8mf2', vl=7),
            make_test_case('vloxei8_v_u8m1', vl=16),
            make_test_case('vloxei8_v_u8m1', vl=15),
            make_test_case('vloxei8_v_u8m2', vl=32),
            make_test_case('vloxei8_v_u8m2', vl=31),
            make_test_case('vloxei8_v_u8m4', vl=64),
            make_test_case('vloxei8_v_u8m4', vl=63),
            make_test_case('vloxei8_v_u8m8', vl=128),
            make_test_case('vloxei8_v_u8m8', vl=127),
        ],
        dtype=np.uint8,
        index_dtype=np.uint8,
    )


@cocotb.test()
async def load8_index8_seg(dut):
    """Test vl*xseg*ei8_v_u8 usage accessible from intrinsics."""

    def make_test_case(impl: str, vl: int, n_segs: int):
        return {
            'impl': impl,
            'vl': vl,
            'segments': n_segs,
            'in_bytes': 263,
            'out_size': vl * n_segs * 2,
        }

    await vector_load_segmented_indexed(
        dut=dut,
        elf_name='load8_index8_seg.elf',
        cases=[
            # Unordered, segment 2
            make_test_case('vluxseg2ei8_v_u8mf4x2', vl=4, n_segs=2),
            make_test_case('vluxseg2ei8_v_u8mf4x2', vl=3, n_segs=2),
            make_test_case('vluxseg2ei8_v_u8mf2x2', vl=8, n_segs=2),
            make_test_case('vluxseg2ei8_v_u8mf2x2', vl=7, n_segs=2),
            make_test_case('vluxseg2ei8_v_u8m1x2', vl=16, n_segs=2),
            make_test_case('vluxseg2ei8_v_u8m1x2', vl=15, n_segs=2),
            make_test_case('vluxseg2ei8_v_u8m2x2', vl=32, n_segs=2),
            make_test_case('vluxseg2ei8_v_u8m2x2', vl=31, n_segs=2),
            make_test_case('vluxseg2ei8_v_u8m4x2', vl=64, n_segs=2),
            make_test_case('vluxseg2ei8_v_u8m4x2', vl=63, n_segs=2),
            # Unordered, segment 3
            make_test_case('vluxseg3ei8_v_u8mf4x3', vl=4, n_segs=3),
            make_test_case('vluxseg3ei8_v_u8mf4x3', vl=3, n_segs=3),
            make_test_case('vluxseg3ei8_v_u8mf2x3', vl=8, n_segs=3),
            make_test_case('vluxseg3ei8_v_u8mf2x3', vl=7, n_segs=3),
            make_test_case('vluxseg3ei8_v_u8m1x3', vl=16, n_segs=3),
            make_test_case('vluxseg3ei8_v_u8m1x3', vl=15, n_segs=3),
            make_test_case('vluxseg3ei8_v_u8m2x3', vl=32, n_segs=3),
            make_test_case('vluxseg3ei8_v_u8m2x3', vl=31, n_segs=3),
            # Unordered, segment 4
            make_test_case('vluxseg4ei8_v_u8mf4x4', vl=4, n_segs=4),
            make_test_case('vluxseg4ei8_v_u8mf4x4', vl=3, n_segs=4),
            make_test_case('vluxseg4ei8_v_u8mf2x4', vl=8, n_segs=4),
            make_test_case('vluxseg4ei8_v_u8mf2x4', vl=7, n_segs=4),
            make_test_case('vluxseg4ei8_v_u8m1x4', vl=16, n_segs=4),
            make_test_case('vluxseg4ei8_v_u8m1x4', vl=15, n_segs=4),
            make_test_case('vluxseg4ei8_v_u8m2x4', vl=32, n_segs=4),
            make_test_case('vluxseg4ei8_v_u8m2x4', vl=31, n_segs=4),
            # Unordered, segment 5
            make_test_case('vluxseg5ei8_v_u8mf4x5', vl=4, n_segs=5),
            make_test_case('vluxseg5ei8_v_u8mf4x5', vl=3, n_segs=5),
            make_test_case('vluxseg5ei8_v_u8mf2x5', vl=8, n_segs=5),
            make_test_case('vluxseg5ei8_v_u8mf2x5', vl=7, n_segs=5),
            make_test_case('vluxseg5ei8_v_u8m1x5', vl=16, n_segs=5),
            make_test_case('vluxseg5ei8_v_u8m1x5', vl=15, n_segs=5),
            # Unordered, segment 6
            make_test_case('vluxseg6ei8_v_u8mf4x6', vl=4, n_segs=6),
            make_test_case('vluxseg6ei8_v_u8mf4x6', vl=3, n_segs=6),
            make_test_case('vluxseg6ei8_v_u8mf2x6', vl=8, n_segs=6),
            make_test_case('vluxseg6ei8_v_u8mf2x6', vl=7, n_segs=6),
            make_test_case('vluxseg6ei8_v_u8m1x6', vl=16, n_segs=6),
            make_test_case('vluxseg6ei8_v_u8m1x6', vl=15, n_segs=6),
            # Unordered, segment 7
            make_test_case('vluxseg7ei8_v_u8mf4x7', vl=4, n_segs=7),
            make_test_case('vluxseg7ei8_v_u8mf4x7', vl=3, n_segs=7),
            make_test_case('vluxseg7ei8_v_u8mf2x7', vl=8, n_segs=7),
            make_test_case('vluxseg7ei8_v_u8mf2x7', vl=7, n_segs=7),
            make_test_case('vluxseg7ei8_v_u8m1x7', vl=16, n_segs=7),
            make_test_case('vluxseg7ei8_v_u8m1x7', vl=15, n_segs=7),
            # Unordered, segment 8
            make_test_case('vluxseg8ei8_v_u8mf4x8', vl=4, n_segs=8),
            make_test_case('vluxseg8ei8_v_u8mf4x8', vl=3, n_segs=8),
            make_test_case('vluxseg8ei8_v_u8mf2x8', vl=8, n_segs=8),
            make_test_case('vluxseg8ei8_v_u8mf2x8', vl=7, n_segs=8),
            make_test_case('vluxseg8ei8_v_u8m1x8', vl=16, n_segs=8),
            make_test_case('vluxseg8ei8_v_u8m1x8', vl=15, n_segs=8),
            # Ordered, segment 2
            make_test_case('vloxseg2ei8_v_u8mf4x2', vl=4, n_segs=2),
            make_test_case('vloxseg2ei8_v_u8mf4x2', vl=3, n_segs=2),
            make_test_case('vloxseg2ei8_v_u8mf2x2', vl=8, n_segs=2),
            make_test_case('vloxseg2ei8_v_u8mf2x2', vl=7, n_segs=2),
            make_test_case('vloxseg2ei8_v_u8m1x2', vl=16, n_segs=2),
            make_test_case('vloxseg2ei8_v_u8m1x2', vl=15, n_segs=2),
            make_test_case('vloxseg2ei8_v_u8m2x2', vl=32, n_segs=2),
            make_test_case('vloxseg2ei8_v_u8m2x2', vl=31, n_segs=2),
            make_test_case('vloxseg2ei8_v_u8m4x2', vl=64, n_segs=2),
            make_test_case('vloxseg2ei8_v_u8m4x2', vl=63, n_segs=2),
            # Ordered, segment 3
            make_test_case('vloxseg3ei8_v_u8mf4x3', vl=4, n_segs=3),
            make_test_case('vloxseg3ei8_v_u8mf4x3', vl=3, n_segs=3),
            make_test_case('vloxseg3ei8_v_u8mf2x3', vl=8, n_segs=3),
            make_test_case('vloxseg3ei8_v_u8mf2x3', vl=7, n_segs=3),
            make_test_case('vloxseg3ei8_v_u8m1x3', vl=16, n_segs=3),
            make_test_case('vloxseg3ei8_v_u8m1x3', vl=15, n_segs=3),
            make_test_case('vloxseg3ei8_v_u8m2x3', vl=32, n_segs=3),
            make_test_case('vloxseg3ei8_v_u8m2x3', vl=31, n_segs=3),
            # Ordered, segment 4
            make_test_case('vloxseg4ei8_v_u8mf4x4', vl=4, n_segs=4),
            make_test_case('vloxseg4ei8_v_u8mf4x4', vl=3, n_segs=4),
            make_test_case('vloxseg4ei8_v_u8mf2x4', vl=8, n_segs=4),
            make_test_case('vloxseg4ei8_v_u8mf2x4', vl=7, n_segs=4),
            make_test_case('vloxseg4ei8_v_u8m1x4', vl=16, n_segs=4),
            make_test_case('vloxseg4ei8_v_u8m1x4', vl=15, n_segs=4),
            make_test_case('vloxseg4ei8_v_u8m2x4', vl=32, n_segs=4),
            make_test_case('vloxseg4ei8_v_u8m2x4', vl=31, n_segs=4),
            # Ordered, segment 5
            make_test_case('vloxseg5ei8_v_u8mf4x5', vl=4, n_segs=5),
            make_test_case('vloxseg5ei8_v_u8mf4x5', vl=3, n_segs=5),
            make_test_case('vloxseg5ei8_v_u8mf2x5', vl=8, n_segs=5),
            make_test_case('vloxseg5ei8_v_u8mf2x5', vl=7, n_segs=5),
            make_test_case('vloxseg5ei8_v_u8m1x5', vl=16, n_segs=5),
            make_test_case('vloxseg5ei8_v_u8m1x5', vl=15, n_segs=5),
            # Ordered, segment 6
            make_test_case('vloxseg6ei8_v_u8mf4x6', vl=4, n_segs=6),
            make_test_case('vloxseg6ei8_v_u8mf4x6', vl=3, n_segs=6),
            make_test_case('vloxseg6ei8_v_u8mf2x6', vl=8, n_segs=6),
            make_test_case('vloxseg6ei8_v_u8mf2x6', vl=7, n_segs=6),
            make_test_case('vloxseg6ei8_v_u8m1x6', vl=16, n_segs=6),
            make_test_case('vloxseg6ei8_v_u8m1x6', vl=15, n_segs=6),
            # Ordered, segment 7
            make_test_case('vloxseg7ei8_v_u8mf4x7', vl=4, n_segs=7),
            make_test_case('vloxseg7ei8_v_u8mf4x7', vl=3, n_segs=7),
            make_test_case('vloxseg7ei8_v_u8mf2x7', vl=8, n_segs=7),
            make_test_case('vloxseg7ei8_v_u8mf2x7', vl=7, n_segs=7),
            make_test_case('vloxseg7ei8_v_u8m1x7', vl=16, n_segs=7),
            make_test_case('vloxseg7ei8_v_u8m1x7', vl=15, n_segs=7),
            # Ordered, segment 8
            make_test_case('vloxseg8ei8_v_u8mf4x8', vl=4, n_segs=8),
            make_test_case('vloxseg8ei8_v_u8mf4x8', vl=3, n_segs=8),
            make_test_case('vloxseg8ei8_v_u8mf2x8', vl=8, n_segs=8),
            make_test_case('vloxseg8ei8_v_u8mf2x8', vl=7, n_segs=8),
            make_test_case('vloxseg8ei8_v_u8m1x8', vl=16, n_segs=8),
            make_test_case('vloxseg8ei8_v_u8m1x8', vl=15, n_segs=8),
        ],
        dtype=np.uint8,
        index_dtype=np.uint8,
    )


@cocotb.test()
async def load8_index16(dut):
    """Test vl*xei16_v_u8 usage accessible from intrinsics."""

    def make_test_case(impl: str, vl: int):
        return {
            'impl': impl,
            'vl': vl,
            'segments': 1,
            'in_bytes': 32000,  # DTCM is 32KB
            'out_size': vl * 2,
        }

    await vector_load_segmented_indexed(
        dut=dut,
        elf_name='load8_index16.elf',
        cases=[
            # Unordered
            make_test_case('vluxei16_v_u8mf4', vl=4),
            make_test_case('vluxei16_v_u8mf4', vl=3),
            make_test_case('vluxei16_v_u8mf2', vl=8),
            make_test_case('vluxei16_v_u8mf2', vl=7),
            make_test_case('vluxei16_v_u8m1', vl=16),
            make_test_case('vluxei16_v_u8m1', vl=15),
            make_test_case('vluxei16_v_u8m2', vl=32),
            make_test_case('vluxei16_v_u8m2', vl=31),
            make_test_case('vluxei16_v_u8m4', vl=64),
            make_test_case('vluxei16_v_u8m4', vl=63),
            # Ordered
            make_test_case('vloxei16_v_u8mf4', vl=4),
            make_test_case('vloxei16_v_u8mf4', vl=3),
            make_test_case('vloxei16_v_u8mf2', vl=8),
            make_test_case('vloxei16_v_u8mf2', vl=7),
            make_test_case('vloxei16_v_u8m1', vl=16),
            make_test_case('vloxei16_v_u8m1', vl=15),
            make_test_case('vloxei16_v_u8m2', vl=32),
            make_test_case('vloxei16_v_u8m2', vl=31),
            make_test_case('vloxei16_v_u8m4', vl=64),
            make_test_case('vloxei16_v_u8m4', vl=63),
        ],
        dtype=np.uint8,
        index_dtype=np.uint16,
    )


@cocotb.test()
async def load8_index16_seg(dut):
    """Test vl*xseg*ei16_v_u8 usage accessible from intrinsics."""

    def make_test_case(impl: str, vl: int, n_segs: int):
        return {
            'impl': impl,
            'vl': vl,
            'segments': n_segs,
            'in_bytes': 30000,
            'out_size': vl * n_segs * 2,
        }

    await vector_load_segmented_indexed(
        dut=dut,
        elf_name='load8_index16_seg.elf',
        cases=[
            # Unordered, segment 2
            make_test_case('vluxseg2ei16_v_u8mf4x2', vl=4, n_segs=2),
            make_test_case('vluxseg2ei16_v_u8mf4x2', vl=3, n_segs=2),
            make_test_case('vluxseg2ei16_v_u8mf2x2', vl=8, n_segs=2),
            make_test_case('vluxseg2ei16_v_u8mf2x2', vl=7, n_segs=2),
            make_test_case('vluxseg2ei16_v_u8m1x2', vl=16, n_segs=2),
            make_test_case('vluxseg2ei16_v_u8m1x2', vl=15, n_segs=2),
            make_test_case('vluxseg2ei16_v_u8m2x2', vl=32, n_segs=2),
            make_test_case('vluxseg2ei16_v_u8m2x2', vl=31, n_segs=2),
            make_test_case('vluxseg2ei16_v_u8m4x2', vl=64, n_segs=2),
            make_test_case('vluxseg2ei16_v_u8m4x2', vl=63, n_segs=2),
            # Unordered, segment 3
            make_test_case('vluxseg3ei16_v_u8mf4x3', vl=4, n_segs=3),
            make_test_case('vluxseg3ei16_v_u8mf4x3', vl=3, n_segs=3),
            make_test_case('vluxseg3ei16_v_u8mf2x3', vl=8, n_segs=3),
            make_test_case('vluxseg3ei16_v_u8mf2x3', vl=7, n_segs=3),
            make_test_case('vluxseg3ei16_v_u8m1x3', vl=16, n_segs=3),
            make_test_case('vluxseg3ei16_v_u8m1x3', vl=15, n_segs=3),
            make_test_case('vluxseg3ei16_v_u8m2x3', vl=32, n_segs=3),
            make_test_case('vluxseg3ei16_v_u8m2x3', vl=31, n_segs=3),
            # Unordered, segment 4
            make_test_case('vluxseg4ei16_v_u8mf4x4', vl=4, n_segs=4),
            make_test_case('vluxseg4ei16_v_u8mf4x4', vl=3, n_segs=4),
            make_test_case('vluxseg4ei16_v_u8mf2x4', vl=8, n_segs=4),
            make_test_case('vluxseg4ei16_v_u8mf2x4', vl=7, n_segs=4),
            make_test_case('vluxseg4ei16_v_u8m1x4', vl=16, n_segs=4),
            make_test_case('vluxseg4ei16_v_u8m1x4', vl=15, n_segs=4),
            make_test_case('vluxseg4ei16_v_u8m2x4', vl=32, n_segs=4),
            make_test_case('vluxseg4ei16_v_u8m2x4', vl=31, n_segs=4),
            # Unordered, segment 5
            make_test_case('vluxseg5ei16_v_u8mf4x5', vl=4, n_segs=5),
            make_test_case('vluxseg5ei16_v_u8mf4x5', vl=3, n_segs=5),
            make_test_case('vluxseg5ei16_v_u8mf2x5', vl=8, n_segs=5),
            make_test_case('vluxseg5ei16_v_u8mf2x5', vl=7, n_segs=5),
            make_test_case('vluxseg5ei16_v_u8m1x5', vl=16, n_segs=5),
            make_test_case('vluxseg5ei16_v_u8m1x5', vl=15, n_segs=5),
            # Unordered, segment 6
            make_test_case('vluxseg6ei16_v_u8mf4x6', vl=4, n_segs=6),
            make_test_case('vluxseg6ei16_v_u8mf4x6', vl=3, n_segs=6),
            make_test_case('vluxseg6ei16_v_u8mf2x6', vl=8, n_segs=6),
            make_test_case('vluxseg6ei16_v_u8mf2x6', vl=7, n_segs=6),
            make_test_case('vluxseg6ei16_v_u8m1x6', vl=16, n_segs=6),
            make_test_case('vluxseg6ei16_v_u8m1x6', vl=15, n_segs=6),
            # Unordered, segment 7
            make_test_case('vluxseg7ei16_v_u8mf4x7', vl=4, n_segs=7),
            make_test_case('vluxseg7ei16_v_u8mf4x7', vl=3, n_segs=7),
            make_test_case('vluxseg7ei16_v_u8mf2x7', vl=8, n_segs=7),
            make_test_case('vluxseg7ei16_v_u8mf2x7', vl=7, n_segs=7),
            make_test_case('vluxseg7ei16_v_u8m1x7', vl=16, n_segs=7),
            make_test_case('vluxseg7ei16_v_u8m1x7', vl=15, n_segs=7),
            # Unordered, segment 8
            make_test_case('vluxseg8ei16_v_u8mf4x8', vl=4, n_segs=8),
            make_test_case('vluxseg8ei16_v_u8mf4x8', vl=3, n_segs=8),
            make_test_case('vluxseg8ei16_v_u8mf2x8', vl=8, n_segs=8),
            make_test_case('vluxseg8ei16_v_u8mf2x8', vl=7, n_segs=8),
            make_test_case('vluxseg8ei16_v_u8m1x8', vl=16, n_segs=8),
            make_test_case('vluxseg8ei16_v_u8m1x8', vl=15, n_segs=8),
            # Ordered, segment 2
            make_test_case('vloxseg2ei16_v_u8mf4x2', vl=4, n_segs=2),
            make_test_case('vloxseg2ei16_v_u8mf4x2', vl=3, n_segs=2),
            make_test_case('vloxseg2ei16_v_u8mf2x2', vl=8, n_segs=2),
            make_test_case('vloxseg2ei16_v_u8mf2x2', vl=7, n_segs=2),
            make_test_case('vloxseg2ei16_v_u8m1x2', vl=16, n_segs=2),
            make_test_case('vloxseg2ei16_v_u8m1x2', vl=15, n_segs=2),
            make_test_case('vloxseg2ei16_v_u8m2x2', vl=32, n_segs=2),
            make_test_case('vloxseg2ei16_v_u8m2x2', vl=31, n_segs=2),
            make_test_case('vloxseg2ei16_v_u8m4x2', vl=64, n_segs=2),
            make_test_case('vloxseg2ei16_v_u8m4x2', vl=63, n_segs=2),
            # Ordered, segment 3
            make_test_case('vloxseg3ei16_v_u8mf4x3', vl=4, n_segs=3),
            make_test_case('vloxseg3ei16_v_u8mf4x3', vl=3, n_segs=3),
            make_test_case('vloxseg3ei16_v_u8mf2x3', vl=8, n_segs=3),
            make_test_case('vloxseg3ei16_v_u8mf2x3', vl=7, n_segs=3),
            make_test_case('vloxseg3ei16_v_u8m1x3', vl=16, n_segs=3),
            make_test_case('vloxseg3ei16_v_u8m1x3', vl=15, n_segs=3),
            make_test_case('vloxseg3ei16_v_u8m2x3', vl=32, n_segs=3),
            make_test_case('vloxseg3ei16_v_u8m2x3', vl=31, n_segs=3),
            # Ordered, segment 4
            make_test_case('vloxseg4ei16_v_u8mf4x4', vl=4, n_segs=4),
            make_test_case('vloxseg4ei16_v_u8mf4x4', vl=3, n_segs=4),
            make_test_case('vloxseg4ei16_v_u8mf2x4', vl=8, n_segs=4),
            make_test_case('vloxseg4ei16_v_u8mf2x4', vl=7, n_segs=4),
            make_test_case('vloxseg4ei16_v_u8m1x4', vl=16, n_segs=4),
            make_test_case('vloxseg4ei16_v_u8m1x4', vl=15, n_segs=4),
            make_test_case('vloxseg4ei16_v_u8m2x4', vl=32, n_segs=4),
            make_test_case('vloxseg4ei16_v_u8m2x4', vl=31, n_segs=4),
            # Ordered, segment 5
            make_test_case('vloxseg5ei16_v_u8mf4x5', vl=4, n_segs=5),
            make_test_case('vloxseg5ei16_v_u8mf4x5', vl=3, n_segs=5),
            make_test_case('vloxseg5ei16_v_u8mf2x5', vl=8, n_segs=5),
            make_test_case('vloxseg5ei16_v_u8mf2x5', vl=7, n_segs=5),
            make_test_case('vloxseg5ei16_v_u8m1x5', vl=16, n_segs=5),
            make_test_case('vloxseg5ei16_v_u8m1x5', vl=15, n_segs=5),
            # Ordered, segment 6
            make_test_case('vloxseg6ei16_v_u8mf4x6', vl=4, n_segs=6),
            make_test_case('vloxseg6ei16_v_u8mf4x6', vl=3, n_segs=6),
            make_test_case('vloxseg6ei16_v_u8mf2x6', vl=8, n_segs=6),
            make_test_case('vloxseg6ei16_v_u8mf2x6', vl=7, n_segs=6),
            make_test_case('vloxseg6ei16_v_u8m1x6', vl=16, n_segs=6),
            make_test_case('vloxseg6ei16_v_u8m1x6', vl=15, n_segs=6),
            # Ordered, segment 7
            make_test_case('vloxseg7ei16_v_u8mf4x7', vl=4, n_segs=7),
            make_test_case('vloxseg7ei16_v_u8mf4x7', vl=3, n_segs=7),
            make_test_case('vloxseg7ei16_v_u8mf2x7', vl=8, n_segs=7),
            make_test_case('vloxseg7ei16_v_u8mf2x7', vl=7, n_segs=7),
            make_test_case('vloxseg7ei16_v_u8m1x7', vl=16, n_segs=7),
            make_test_case('vloxseg7ei16_v_u8m1x7', vl=15, n_segs=7),
            # Ordered, segment 8
            make_test_case('vloxseg8ei16_v_u8mf4x8', vl=4, n_segs=8),
            make_test_case('vloxseg8ei16_v_u8mf4x8', vl=3, n_segs=8),
            make_test_case('vloxseg8ei16_v_u8mf2x8', vl=8, n_segs=8),
            make_test_case('vloxseg8ei16_v_u8mf2x8', vl=7, n_segs=8),
            make_test_case('vloxseg8ei16_v_u8m1x8', vl=16, n_segs=8),
            make_test_case('vloxseg8ei16_v_u8m1x8', vl=15, n_segs=8),
        ],
        dtype=np.uint8,
        index_dtype=np.uint16,
    )


@cocotb.test()
async def load8_seg_unit(dut):
    """Test vlseg*e8 usage accessible from intrinsics."""

    def make_test_case(impl: str, vl: int, n_segs: int):
        return {
            'impl':
            impl,
            'vl':
            vl,
            'in_size':
            vl * n_segs * 2,
            'out_size':
            vl * n_segs * 2,
            'pattern': [
                elem * n_segs + seg
                for seg in range(n_segs)
                for elem in range(vl)
            ]
        }

    await vector_load_store_v2(
        dut=dut,
        elf_name='load8_seg_unit.elf',
        cases=[
            # Seg 2
            make_test_case('vlseg2e8_v_u8mf4x2', vl=4, n_segs=2),
            make_test_case('vlseg2e8_v_u8mf4x2', vl=3, n_segs=2),
            make_test_case('vlseg2e8_v_u8mf4x2', vl=1, n_segs=2),
            make_test_case('vlseg2e8_v_u8mf2x2', vl=8, n_segs=2),
            make_test_case('vlseg2e8_v_u8mf2x2', vl=7, n_segs=2),
            make_test_case('vlseg2e8_v_u8mf2x2', vl=1, n_segs=2),
            make_test_case('vlseg2e8_v_u8m1x2', vl=16, n_segs=2),
            make_test_case('vlseg2e8_v_u8m1x2', vl=15, n_segs=2),
            make_test_case('vlseg2e8_v_u8m1x2', vl=1, n_segs=2),
            make_test_case('vlseg2e8_v_u8m2x2', vl=32, n_segs=2),
            make_test_case('vlseg2e8_v_u8m2x2', vl=31, n_segs=2),
            make_test_case('vlseg2e8_v_u8m2x2', vl=1, n_segs=2),
            make_test_case('vlseg2e8_v_u8m4x2', vl=64, n_segs=2),
            make_test_case('vlseg2e8_v_u8m4x2', vl=63, n_segs=2),
            make_test_case('vlseg2e8_v_u8m4x2', vl=1, n_segs=2),
            # Seg 3
            make_test_case('vlseg3e8_v_u8mf4x3', vl=4, n_segs=3),
            make_test_case('vlseg3e8_v_u8mf4x3', vl=3, n_segs=3),
            make_test_case('vlseg3e8_v_u8mf4x3', vl=1, n_segs=3),
            make_test_case('vlseg3e8_v_u8mf2x3', vl=8, n_segs=3),
            make_test_case('vlseg3e8_v_u8mf2x3', vl=7, n_segs=3),
            make_test_case('vlseg3e8_v_u8mf2x3', vl=1, n_segs=3),
            make_test_case('vlseg3e8_v_u8m1x3', vl=16, n_segs=3),
            make_test_case('vlseg3e8_v_u8m1x3', vl=15, n_segs=3),
            make_test_case('vlseg3e8_v_u8m1x3', vl=1, n_segs=3),
            make_test_case('vlseg3e8_v_u8m2x3', vl=32, n_segs=3),
            make_test_case('vlseg3e8_v_u8m2x3', vl=31, n_segs=3),
            make_test_case('vlseg3e8_v_u8m2x3', vl=1, n_segs=3),
            # Seg 4
            make_test_case('vlseg4e8_v_u8mf4x4', vl=4, n_segs=4),
            make_test_case('vlseg4e8_v_u8mf4x4', vl=3, n_segs=4),
            make_test_case('vlseg4e8_v_u8mf4x4', vl=1, n_segs=4),
            make_test_case('vlseg4e8_v_u8mf2x4', vl=8, n_segs=4),
            make_test_case('vlseg4e8_v_u8mf2x4', vl=7, n_segs=4),
            make_test_case('vlseg4e8_v_u8mf2x4', vl=1, n_segs=4),
            make_test_case('vlseg4e8_v_u8m1x4', vl=16, n_segs=4),
            make_test_case('vlseg4e8_v_u8m1x4', vl=15, n_segs=4),
            make_test_case('vlseg4e8_v_u8m1x4', vl=1, n_segs=4),
            make_test_case('vlseg4e8_v_u8m2x4', vl=32, n_segs=4),
            make_test_case('vlseg4e8_v_u8m2x4', vl=31, n_segs=4),
            make_test_case('vlseg4e8_v_u8m2x4', vl=1, n_segs=4),
            # Seg 5
            make_test_case('vlseg5e8_v_u8mf4x5', vl=4, n_segs=5),
            make_test_case('vlseg5e8_v_u8mf4x5', vl=3, n_segs=5),
            make_test_case('vlseg5e8_v_u8mf4x5', vl=1, n_segs=5),
            make_test_case('vlseg5e8_v_u8mf2x5', vl=8, n_segs=5),
            make_test_case('vlseg5e8_v_u8mf2x5', vl=7, n_segs=5),
            make_test_case('vlseg5e8_v_u8mf2x5', vl=1, n_segs=5),
            make_test_case('vlseg5e8_v_u8m1x5', vl=16, n_segs=5),
            make_test_case('vlseg5e8_v_u8m1x5', vl=15, n_segs=5),
            make_test_case('vlseg5e8_v_u8m1x5', vl=1, n_segs=5),
            # Seg 6
            make_test_case('vlseg6e8_v_u8mf4x6', vl=4, n_segs=6),
            make_test_case('vlseg6e8_v_u8mf4x6', vl=3, n_segs=6),
            make_test_case('vlseg6e8_v_u8mf4x6', vl=1, n_segs=6),
            make_test_case('vlseg6e8_v_u8mf2x6', vl=8, n_segs=6),
            make_test_case('vlseg6e8_v_u8mf2x6', vl=7, n_segs=6),
            make_test_case('vlseg6e8_v_u8mf2x6', vl=1, n_segs=6),
            make_test_case('vlseg6e8_v_u8m1x6', vl=16, n_segs=6),
            make_test_case('vlseg6e8_v_u8m1x6', vl=15, n_segs=6),
            make_test_case('vlseg6e8_v_u8m1x6', vl=1, n_segs=6),
            # Seg 7
            make_test_case('vlseg7e8_v_u8mf4x7', vl=4, n_segs=7),
            make_test_case('vlseg7e8_v_u8mf4x7', vl=3, n_segs=7),
            make_test_case('vlseg7e8_v_u8mf4x7', vl=1, n_segs=7),
            make_test_case('vlseg7e8_v_u8mf2x7', vl=8, n_segs=7),
            make_test_case('vlseg7e8_v_u8mf2x7', vl=7, n_segs=7),
            make_test_case('vlseg7e8_v_u8mf2x7', vl=1, n_segs=7),
            make_test_case('vlseg7e8_v_u8m1x7', vl=16, n_segs=7),
            make_test_case('vlseg7e8_v_u8m1x7', vl=15, n_segs=7),
            make_test_case('vlseg7e8_v_u8m1x7', vl=1, n_segs=7),
            # Seg 8
            make_test_case('vlseg8e8_v_u8mf4x8', vl=4, n_segs=8),
            make_test_case('vlseg8e8_v_u8mf4x8', vl=3, n_segs=8),
            make_test_case('vlseg8e8_v_u8mf4x8', vl=1, n_segs=8),
            make_test_case('vlseg8e8_v_u8mf2x8', vl=8, n_segs=8),
            make_test_case('vlseg8e8_v_u8mf2x8', vl=7, n_segs=8),
            make_test_case('vlseg8e8_v_u8mf2x8', vl=1, n_segs=8),
            make_test_case('vlseg8e8_v_u8m1x8', vl=16, n_segs=8),
            make_test_case('vlseg8e8_v_u8m1x8', vl=15, n_segs=8),
            make_test_case('vlseg8e8_v_u8m1x8', vl=1, n_segs=8),
        ],
        dtype=np.uint8,
    )


@cocotb.test()
async def load8_index32(dut):
    """Test vl*xei32_v_u8 usage accessible from intrinsics."""

    def make_test_case(impl: str, vl: int):
        return {
            'impl': impl,
            'vl': vl,
            'segments': 1,
            'in_bytes': 32000,  # DTCM is 32KB
            'out_size': vl * 2,
        }

    await vector_load_segmented_indexed(
        dut=dut,
        elf_name='load8_index32.elf',
        cases=[
            # Unordered
            make_test_case('vluxei32_v_u8mf4', vl=4),
            make_test_case('vluxei32_v_u8mf4', vl=3),
            make_test_case('vluxei32_v_u8mf2', vl=8),
            make_test_case('vluxei32_v_u8mf2', vl=7),
            make_test_case('vluxei32_v_u8m1', vl=16),
            make_test_case('vluxei32_v_u8m1', vl=15),
            make_test_case('vluxei32_v_u8m2', vl=32),
            make_test_case('vluxei32_v_u8m2', vl=31),
            # Ordered
            make_test_case('vloxei32_v_u8mf4', vl=4),
            make_test_case('vloxei32_v_u8mf4', vl=3),
            make_test_case('vloxei32_v_u8mf2', vl=8),
            make_test_case('vloxei32_v_u8mf2', vl=7),
            make_test_case('vloxei32_v_u8m1', vl=16),
            make_test_case('vloxei32_v_u8m1', vl=15),
            make_test_case('vloxei32_v_u8m2', vl=32),
            make_test_case('vloxei32_v_u8m2', vl=31),
        ],
        dtype=np.uint8,
        index_dtype=np.uint32,
    )


@cocotb.test()
async def load8_index32_seg(dut):
    """Test vl*xseg*ei32_v_u8 usage accessible from intrinsics."""

    def make_test_case(impl: str, vl: int, n_segs: int):
        return {
            'impl': impl,
            'vl': vl,
            'segments': n_segs,
            'in_bytes': 30000,
            'out_size': vl * n_segs * 2,
        }

    await vector_load_segmented_indexed(
        dut=dut,
        elf_name='load8_index32_seg.elf',
        cases=[
            # Unordered, segment 2
            make_test_case('vluxseg2ei32_v_u8mf4x2', vl=4, n_segs=2),
            make_test_case('vluxseg2ei32_v_u8mf4x2', vl=3, n_segs=2),
            make_test_case('vluxseg2ei32_v_u8mf2x2', vl=8, n_segs=2),
            make_test_case('vluxseg2ei32_v_u8mf2x2', vl=7, n_segs=2),
            make_test_case('vluxseg2ei32_v_u8m1x2', vl=16, n_segs=2),
            make_test_case('vluxseg2ei32_v_u8m1x2', vl=15, n_segs=2),
            make_test_case('vluxseg2ei32_v_u8m2x2', vl=32, n_segs=2),
            make_test_case('vluxseg2ei32_v_u8m2x2', vl=31, n_segs=2),
            # Unordered, segment 3
            make_test_case('vluxseg3ei32_v_u8mf4x3', vl=4, n_segs=3),
            make_test_case('vluxseg3ei32_v_u8mf4x3', vl=3, n_segs=3),
            make_test_case('vluxseg3ei32_v_u8mf2x3', vl=8, n_segs=3),
            make_test_case('vluxseg3ei32_v_u8mf2x3', vl=7, n_segs=3),
            make_test_case('vluxseg3ei32_v_u8m1x3', vl=16, n_segs=3),
            make_test_case('vluxseg3ei32_v_u8m1x3', vl=15, n_segs=3),
            make_test_case('vluxseg3ei32_v_u8m2x3', vl=32, n_segs=3),
            make_test_case('vluxseg3ei32_v_u8m2x3', vl=31, n_segs=3),
            # Unordered, segment 4
            make_test_case('vluxseg4ei32_v_u8mf4x4', vl=4, n_segs=4),
            make_test_case('vluxseg4ei32_v_u8mf4x4', vl=3, n_segs=4),
            make_test_case('vluxseg4ei32_v_u8mf2x4', vl=8, n_segs=4),
            make_test_case('vluxseg4ei32_v_u8mf2x4', vl=7, n_segs=4),
            make_test_case('vluxseg4ei32_v_u8m1x4', vl=16, n_segs=4),
            make_test_case('vluxseg4ei32_v_u8m1x4', vl=15, n_segs=4),
            make_test_case('vluxseg4ei32_v_u8m2x4', vl=32, n_segs=4),
            make_test_case('vluxseg4ei32_v_u8m2x4', vl=31, n_segs=4),
            # Unordered, segment 5
            make_test_case('vluxseg5ei32_v_u8mf4x5', vl=4, n_segs=5),
            make_test_case('vluxseg5ei32_v_u8mf4x5', vl=3, n_segs=5),
            make_test_case('vluxseg5ei32_v_u8mf2x5', vl=8, n_segs=5),
            make_test_case('vluxseg5ei32_v_u8mf2x5', vl=7, n_segs=5),
            make_test_case('vluxseg5ei32_v_u8m1x5', vl=16, n_segs=5),
            make_test_case('vluxseg5ei32_v_u8m1x5', vl=15, n_segs=5),
            # Unordered, segment 6
            make_test_case('vluxseg6ei32_v_u8mf4x6', vl=4, n_segs=6),
            make_test_case('vluxseg6ei32_v_u8mf4x6', vl=3, n_segs=6),
            make_test_case('vluxseg6ei32_v_u8mf2x6', vl=8, n_segs=6),
            make_test_case('vluxseg6ei32_v_u8mf2x6', vl=7, n_segs=6),
            make_test_case('vluxseg6ei32_v_u8m1x6', vl=16, n_segs=6),
            make_test_case('vluxseg6ei32_v_u8m1x6', vl=15, n_segs=6),
            # Unordered, segment 7
            make_test_case('vluxseg7ei32_v_u8mf4x7', vl=4, n_segs=7),
            make_test_case('vluxseg7ei32_v_u8mf4x7', vl=3, n_segs=7),
            make_test_case('vluxseg7ei32_v_u8mf2x7', vl=8, n_segs=7),
            make_test_case('vluxseg7ei32_v_u8mf2x7', vl=7, n_segs=7),
            make_test_case('vluxseg7ei32_v_u8m1x7', vl=16, n_segs=7),
            make_test_case('vluxseg7ei32_v_u8m1x7', vl=15, n_segs=7),
            # Unordered, segment 8
            make_test_case('vluxseg8ei32_v_u8mf4x8', vl=4, n_segs=8),
            make_test_case('vluxseg8ei32_v_u8mf4x8', vl=3, n_segs=8),
            make_test_case('vluxseg8ei32_v_u8mf2x8', vl=8, n_segs=8),
            make_test_case('vluxseg8ei32_v_u8mf2x8', vl=7, n_segs=8),
            make_test_case('vluxseg8ei32_v_u8m1x8', vl=16, n_segs=8),
            make_test_case('vluxseg8ei32_v_u8m1x8', vl=15, n_segs=8),
            # Ordered, segment 2
            make_test_case('vloxseg2ei32_v_u8mf4x2', vl=4, n_segs=2),
            make_test_case('vloxseg2ei32_v_u8mf4x2', vl=3, n_segs=2),
            make_test_case('vloxseg2ei32_v_u8mf2x2', vl=8, n_segs=2),
            make_test_case('vloxseg2ei32_v_u8mf2x2', vl=7, n_segs=2),
            make_test_case('vloxseg2ei32_v_u8m1x2', vl=16, n_segs=2),
            make_test_case('vloxseg2ei32_v_u8m1x2', vl=15, n_segs=2),
            make_test_case('vloxseg2ei32_v_u8m2x2', vl=32, n_segs=2),
            make_test_case('vloxseg2ei32_v_u8m2x2', vl=31, n_segs=2),
            # Ordered, segment 3
            make_test_case('vloxseg3ei32_v_u8mf4x3', vl=4, n_segs=3),
            make_test_case('vloxseg3ei32_v_u8mf4x3', vl=3, n_segs=3),
            make_test_case('vloxseg3ei32_v_u8mf2x3', vl=8, n_segs=3),
            make_test_case('vloxseg3ei32_v_u8mf2x3', vl=7, n_segs=3),
            make_test_case('vloxseg3ei32_v_u8m1x3', vl=16, n_segs=3),
            make_test_case('vloxseg3ei32_v_u8m1x3', vl=15, n_segs=3),
            make_test_case('vloxseg3ei32_v_u8m2x3', vl=32, n_segs=3),
            make_test_case('vloxseg3ei32_v_u8m2x3', vl=31, n_segs=3),
            # Ordered, segment 4
            make_test_case('vloxseg4ei32_v_u8mf4x4', vl=4, n_segs=4),
            make_test_case('vloxseg4ei32_v_u8mf4x4', vl=3, n_segs=4),
            make_test_case('vloxseg4ei32_v_u8mf2x4', vl=8, n_segs=4),
            make_test_case('vloxseg4ei32_v_u8mf2x4', vl=7, n_segs=4),
            make_test_case('vloxseg4ei32_v_u8m1x4', vl=16, n_segs=4),
            make_test_case('vloxseg4ei32_v_u8m1x4', vl=15, n_segs=4),
            make_test_case('vloxseg4ei32_v_u8m2x4', vl=32, n_segs=4),
            make_test_case('vloxseg4ei32_v_u8m2x4', vl=31, n_segs=4),
            # Ordered, segment 5
            make_test_case('vloxseg5ei32_v_u8mf4x5', vl=4, n_segs=5),
            make_test_case('vloxseg5ei32_v_u8mf4x5', vl=3, n_segs=5),
            make_test_case('vloxseg5ei32_v_u8mf2x5', vl=8, n_segs=5),
            make_test_case('vloxseg5ei32_v_u8mf2x5', vl=7, n_segs=5),
            make_test_case('vloxseg5ei32_v_u8m1x5', vl=16, n_segs=5),
            make_test_case('vloxseg5ei32_v_u8m1x5', vl=15, n_segs=5),
            # Ordered, segment 6
            make_test_case('vloxseg6ei32_v_u8mf4x6', vl=4, n_segs=6),
            make_test_case('vloxseg6ei32_v_u8mf4x6', vl=3, n_segs=6),
            make_test_case('vloxseg6ei32_v_u8mf2x6', vl=8, n_segs=6),
            make_test_case('vloxseg6ei32_v_u8mf2x6', vl=7, n_segs=6),
            make_test_case('vloxseg6ei32_v_u8m1x6', vl=16, n_segs=6),
            make_test_case('vloxseg6ei32_v_u8m1x6', vl=15, n_segs=6),
            # Ordered, segment 7
            make_test_case('vloxseg7ei32_v_u8mf4x7', vl=4, n_segs=7),
            make_test_case('vloxseg7ei32_v_u8mf4x7', vl=3, n_segs=7),
            make_test_case('vloxseg7ei32_v_u8mf2x7', vl=8, n_segs=7),
            make_test_case('vloxseg7ei32_v_u8mf2x7', vl=7, n_segs=7),
            make_test_case('vloxseg7ei32_v_u8m1x7', vl=16, n_segs=7),
            make_test_case('vloxseg7ei32_v_u8m1x7', vl=15, n_segs=7),
            # Ordered, segment 8
            make_test_case('vloxseg8ei32_v_u8mf4x8', vl=4, n_segs=8),
            make_test_case('vloxseg8ei32_v_u8mf4x8', vl=3, n_segs=8),
            make_test_case('vloxseg8ei32_v_u8mf2x8', vl=8, n_segs=8),
            make_test_case('vloxseg8ei32_v_u8mf2x8', vl=7, n_segs=8),
            make_test_case('vloxseg8ei32_v_u8m1x8', vl=16, n_segs=8),
            make_test_case('vloxseg8ei32_v_u8m1x8', vl=15, n_segs=8),
        ],
        dtype=np.uint8,
        index_dtype=np.uint32,
    )


@cocotb.test()
async def load16_index8(dut):
    """Test vl*xei8_v_u16 usage accessible from intrinsics."""

    def make_test_case(impl: str, vl: int):
        return {
            'impl': impl,
            'vl': vl,
            'segments': 1,
            'in_bytes': 257,  # 2 bytes at offset 255 reachable.
            'out_size': vl * 2,
        }

    await vector_load_segmented_indexed(
        dut=dut,
        elf_name='load16_index8.elf',
        cases=[
            # Unordered
            make_test_case('vluxei8_v_u16mf2', vl=4),
            make_test_case('vluxei8_v_u16mf2', vl=3),
            make_test_case('vluxei8_v_u16m1', vl=8),
            make_test_case('vluxei8_v_u16m1', vl=7),
            make_test_case('vluxei8_v_u16m2', vl=16),
            make_test_case('vluxei8_v_u16m2', vl=15),
            make_test_case('vluxei8_v_u16m4', vl=32),
            make_test_case('vluxei8_v_u16m4', vl=31),
            make_test_case('vluxei8_v_u16m8', vl=64),
            make_test_case('vluxei8_v_u16m8', vl=63),
            # Ordered
            make_test_case('vloxei8_v_u16mf2', vl=4),
            make_test_case('vloxei8_v_u16mf2', vl=3),
            make_test_case('vloxei8_v_u16m1', vl=8),
            make_test_case('vloxei8_v_u16m1', vl=7),
            make_test_case('vloxei8_v_u16m2', vl=16),
            make_test_case('vloxei8_v_u16m2', vl=15),
            make_test_case('vloxei8_v_u16m4', vl=32),
            make_test_case('vloxei8_v_u16m4', vl=31),
            make_test_case('vloxei8_v_u16m8', vl=64),
            make_test_case('vloxei8_v_u16m8', vl=63),
        ],
        dtype=np.uint16,
        index_dtype=np.uint8,
    )


@cocotb.test()
async def load16_index8_seg(dut):
    """Test vl*xseg*ei8_v_u16 usage accessible from intrinsics."""

    def make_test_case(impl: str, vl: int, n_segs: int):
        return {
            'impl': impl,
            'vl': vl,
            'segments': n_segs,
            'in_bytes': 271,
            'out_size': vl * n_segs * 2,
        }

    await vector_load_segmented_indexed(
        dut=dut,
        elf_name='load16_index8_seg.elf',
        cases=[
            # Unordered, segment 2
            make_test_case('vluxseg2ei8_v_u16mf2x2', vl=4, n_segs=2),
            make_test_case('vluxseg2ei8_v_u16mf2x2', vl=3, n_segs=2),
            make_test_case('vluxseg2ei8_v_u16m1x2', vl=8, n_segs=2),
            make_test_case('vluxseg2ei8_v_u16m1x2', vl=7, n_segs=2),
            make_test_case('vluxseg2ei8_v_u16m2x2', vl=16, n_segs=2),
            make_test_case('vluxseg2ei8_v_u16m2x2', vl=15, n_segs=2),
            make_test_case('vluxseg2ei8_v_u16m4x2', vl=32, n_segs=2),
            make_test_case('vluxseg2ei8_v_u16m4x2', vl=31, n_segs=2),
            # Unordered, segment 3
            make_test_case('vluxseg3ei8_v_u16mf2x3', vl=4, n_segs=3),
            make_test_case('vluxseg3ei8_v_u16mf2x3', vl=3, n_segs=3),
            make_test_case('vluxseg3ei8_v_u16m1x3', vl=8, n_segs=3),
            make_test_case('vluxseg3ei8_v_u16m1x3', vl=7, n_segs=3),
            make_test_case('vluxseg3ei8_v_u16m2x3', vl=16, n_segs=3),
            make_test_case('vluxseg3ei8_v_u16m2x3', vl=15, n_segs=3),
            # Unordered, segment 4
            make_test_case('vluxseg4ei8_v_u16mf2x4', vl=4, n_segs=4),
            make_test_case('vluxseg4ei8_v_u16mf2x4', vl=3, n_segs=4),
            make_test_case('vluxseg4ei8_v_u16m1x4', vl=8, n_segs=4),
            make_test_case('vluxseg4ei8_v_u16m1x4', vl=7, n_segs=4),
            make_test_case('vluxseg4ei8_v_u16m2x4', vl=16, n_segs=4),
            make_test_case('vluxseg4ei8_v_u16m2x4', vl=15, n_segs=4),
            # Unordered, segment 5
            make_test_case('vluxseg5ei8_v_u16mf2x5', vl=4, n_segs=5),
            make_test_case('vluxseg5ei8_v_u16mf2x5', vl=3, n_segs=5),
            make_test_case('vluxseg5ei8_v_u16m1x5', vl=8, n_segs=5),
            make_test_case('vluxseg5ei8_v_u16m1x5', vl=7, n_segs=5),
            # Unordered, segment 6
            make_test_case('vluxseg6ei8_v_u16mf2x6', vl=4, n_segs=6),
            make_test_case('vluxseg6ei8_v_u16mf2x6', vl=3, n_segs=6),
            make_test_case('vluxseg6ei8_v_u16m1x6', vl=8, n_segs=6),
            make_test_case('vluxseg6ei8_v_u16m1x6', vl=7, n_segs=6),
            # Unordered, segment 7
            make_test_case('vluxseg7ei8_v_u16mf2x7', vl=4, n_segs=7),
            make_test_case('vluxseg7ei8_v_u16mf2x7', vl=3, n_segs=7),
            make_test_case('vluxseg7ei8_v_u16m1x7', vl=8, n_segs=7),
            make_test_case('vluxseg7ei8_v_u16m1x7', vl=7, n_segs=7),
            # Unordered, segment 8
            make_test_case('vluxseg8ei8_v_u16mf2x8', vl=4, n_segs=8),
            make_test_case('vluxseg8ei8_v_u16mf2x8', vl=3, n_segs=8),
            make_test_case('vluxseg8ei8_v_u16m1x8', vl=8, n_segs=8),
            make_test_case('vluxseg8ei8_v_u16m1x8', vl=7, n_segs=8),
            # Ordered, segment 2
            make_test_case('vloxseg2ei8_v_u16mf2x2', vl=4, n_segs=2),
            make_test_case('vloxseg2ei8_v_u16mf2x2', vl=3, n_segs=2),
            make_test_case('vloxseg2ei8_v_u16m1x2', vl=8, n_segs=2),
            make_test_case('vloxseg2ei8_v_u16m1x2', vl=7, n_segs=2),
            make_test_case('vloxseg2ei8_v_u16m2x2', vl=16, n_segs=2),
            make_test_case('vloxseg2ei8_v_u16m2x2', vl=15, n_segs=2),
            make_test_case('vloxseg2ei8_v_u16m4x2', vl=32, n_segs=2),
            make_test_case('vloxseg2ei8_v_u16m4x2', vl=31, n_segs=2),
            # Ordered, segment 3
            make_test_case('vloxseg3ei8_v_u16mf2x3', vl=4, n_segs=3),
            make_test_case('vloxseg3ei8_v_u16mf2x3', vl=3, n_segs=3),
            make_test_case('vloxseg3ei8_v_u16m1x3', vl=8, n_segs=3),
            make_test_case('vloxseg3ei8_v_u16m1x3', vl=7, n_segs=3),
            make_test_case('vloxseg3ei8_v_u16m2x3', vl=16, n_segs=3),
            make_test_case('vloxseg3ei8_v_u16m2x3', vl=15, n_segs=3),
            # Ordered, segment 4
            make_test_case('vloxseg4ei8_v_u16mf2x4', vl=4, n_segs=4),
            make_test_case('vloxseg4ei8_v_u16mf2x4', vl=3, n_segs=4),
            make_test_case('vloxseg4ei8_v_u16m1x4', vl=8, n_segs=4),
            make_test_case('vloxseg4ei8_v_u16m1x4', vl=7, n_segs=4),
            make_test_case('vloxseg4ei8_v_u16m2x4', vl=16, n_segs=4),
            make_test_case('vloxseg4ei8_v_u16m2x4', vl=15, n_segs=4),
            # Ordered, segment 5
            make_test_case('vloxseg5ei8_v_u16mf2x5', vl=4, n_segs=5),
            make_test_case('vloxseg5ei8_v_u16mf2x5', vl=3, n_segs=5),
            make_test_case('vloxseg5ei8_v_u16m1x5', vl=8, n_segs=5),
            make_test_case('vloxseg5ei8_v_u16m1x5', vl=7, n_segs=5),
            # Ordered, segment 6
            make_test_case('vloxseg6ei8_v_u16mf2x6', vl=4, n_segs=6),
            make_test_case('vloxseg6ei8_v_u16mf2x6', vl=3, n_segs=6),
            make_test_case('vloxseg6ei8_v_u16m1x6', vl=8, n_segs=6),
            make_test_case('vloxseg6ei8_v_u16m1x6', vl=7, n_segs=6),
            # Ordered, segment 7
            make_test_case('vloxseg7ei8_v_u16mf2x7', vl=4, n_segs=7),
            make_test_case('vloxseg7ei8_v_u16mf2x7', vl=3, n_segs=7),
            make_test_case('vloxseg7ei8_v_u16m1x7', vl=8, n_segs=7),
            make_test_case('vloxseg7ei8_v_u16m1x7', vl=7, n_segs=7),
            # Ordered, segment 8
            make_test_case('vloxseg8ei8_v_u16mf2x8', vl=4, n_segs=8),
            make_test_case('vloxseg8ei8_v_u16mf2x8', vl=3, n_segs=8),
            make_test_case('vloxseg8ei8_v_u16m1x8', vl=8, n_segs=8),
            make_test_case('vloxseg8ei8_v_u16m1x8', vl=7, n_segs=8),
        ],
        dtype=np.uint16,
        index_dtype=np.uint8,
    )


@cocotb.test()
async def load16_index16_seg(dut):
    """Test vl*xseg*ei16_v_u16 usage accessible from intrinsics."""

    def make_test_case(impl: str, vl: int, n_segs: int):
        return {
            'impl': impl,
            'vl': vl,
            'segments': n_segs,
            'in_bytes': 30000,
            'out_size': vl * n_segs * 2,
        }

    await vector_load_segmented_indexed(
        dut=dut,
        elf_name='load16_index16_seg.elf',
        cases=[
            # Unordered, segment 2
            make_test_case('vluxseg2ei16_v_u16mf2x2', vl=4, n_segs=2),
            make_test_case('vluxseg2ei16_v_u16mf2x2', vl=3, n_segs=2),
            make_test_case('vluxseg2ei16_v_u16m1x2', vl=8, n_segs=2),
            make_test_case('vluxseg2ei16_v_u16m1x2', vl=7, n_segs=2),
            make_test_case('vluxseg2ei16_v_u16m2x2', vl=16, n_segs=2),
            make_test_case('vluxseg2ei16_v_u16m2x2', vl=15, n_segs=2),
            make_test_case('vluxseg2ei16_v_u16m4x2', vl=32, n_segs=2),
            make_test_case('vluxseg2ei16_v_u16m4x2', vl=31, n_segs=2),
            # Unordered, segment 3
            make_test_case('vluxseg3ei16_v_u16mf2x3', vl=4, n_segs=3),
            make_test_case('vluxseg3ei16_v_u16mf2x3', vl=3, n_segs=3),
            make_test_case('vluxseg3ei16_v_u16m1x3', vl=8, n_segs=3),
            make_test_case('vluxseg3ei16_v_u16m1x3', vl=7, n_segs=3),
            make_test_case('vluxseg3ei16_v_u16m2x3', vl=16, n_segs=3),
            make_test_case('vluxseg3ei16_v_u16m2x3', vl=15, n_segs=3),
            # Unordered, segment 4
            make_test_case('vluxseg4ei16_v_u16mf2x4', vl=4, n_segs=4),
            make_test_case('vluxseg4ei16_v_u16mf2x4', vl=3, n_segs=4),
            make_test_case('vluxseg4ei16_v_u16m1x4', vl=8, n_segs=4),
            make_test_case('vluxseg4ei16_v_u16m1x4', vl=7, n_segs=4),
            make_test_case('vluxseg4ei16_v_u16m2x4', vl=16, n_segs=4),
            make_test_case('vluxseg4ei16_v_u16m2x4', vl=15, n_segs=4),
            # Unordered, segment 5
            make_test_case('vluxseg5ei16_v_u16mf2x5', vl=4, n_segs=5),
            make_test_case('vluxseg5ei16_v_u16mf2x5', vl=3, n_segs=5),
            make_test_case('vluxseg5ei16_v_u16m1x5', vl=8, n_segs=5),
            make_test_case('vluxseg5ei16_v_u16m1x5', vl=7, n_segs=5),
            # Unordered, segment 6
            make_test_case('vluxseg6ei16_v_u16mf2x6', vl=4, n_segs=6),
            make_test_case('vluxseg6ei16_v_u16mf2x6', vl=3, n_segs=6),
            make_test_case('vluxseg6ei16_v_u16m1x6', vl=8, n_segs=6),
            make_test_case('vluxseg6ei16_v_u16m1x6', vl=7, n_segs=6),
            # Unordered, segment 7
            make_test_case('vluxseg7ei16_v_u16mf2x7', vl=4, n_segs=7),
            make_test_case('vluxseg7ei16_v_u16mf2x7', vl=3, n_segs=7),
            make_test_case('vluxseg7ei16_v_u16m1x7', vl=8, n_segs=7),
            make_test_case('vluxseg7ei16_v_u16m1x7', vl=7, n_segs=7),
            # Unordered, segment 8
            make_test_case('vluxseg8ei16_v_u16mf2x8', vl=4, n_segs=8),
            make_test_case('vluxseg8ei16_v_u16mf2x8', vl=3, n_segs=8),
            make_test_case('vluxseg8ei16_v_u16m1x8', vl=8, n_segs=8),
            make_test_case('vluxseg8ei16_v_u16m1x8', vl=7, n_segs=8),
            # Ordered, segment 2
            make_test_case('vloxseg2ei16_v_u16mf2x2', vl=4, n_segs=2),
            make_test_case('vloxseg2ei16_v_u16mf2x2', vl=3, n_segs=2),
            make_test_case('vloxseg2ei16_v_u16m1x2', vl=8, n_segs=2),
            make_test_case('vloxseg2ei16_v_u16m1x2', vl=7, n_segs=2),
            make_test_case('vloxseg2ei16_v_u16m2x2', vl=16, n_segs=2),
            make_test_case('vloxseg2ei16_v_u16m2x2', vl=15, n_segs=2),
            make_test_case('vloxseg2ei16_v_u16m4x2', vl=32, n_segs=2),
            make_test_case('vloxseg2ei16_v_u16m4x2', vl=31, n_segs=2),
            # Ordered, segment 3
            make_test_case('vloxseg3ei16_v_u16mf2x3', vl=4, n_segs=3),
            make_test_case('vloxseg3ei16_v_u16mf2x3', vl=3, n_segs=3),
            make_test_case('vloxseg3ei16_v_u16m1x3', vl=8, n_segs=3),
            make_test_case('vloxseg3ei16_v_u16m1x3', vl=7, n_segs=3),
            make_test_case('vloxseg3ei16_v_u16m2x3', vl=16, n_segs=3),
            make_test_case('vloxseg3ei16_v_u16m2x3', vl=15, n_segs=3),
            # Ordered, segment 4
            make_test_case('vloxseg4ei16_v_u16mf2x4', vl=4, n_segs=4),
            make_test_case('vloxseg4ei16_v_u16mf2x4', vl=3, n_segs=4),
            make_test_case('vloxseg4ei16_v_u16m1x4', vl=8, n_segs=4),
            make_test_case('vloxseg4ei16_v_u16m1x4', vl=7, n_segs=4),
            make_test_case('vloxseg4ei16_v_u16m2x4', vl=16, n_segs=4),
            make_test_case('vloxseg4ei16_v_u16m2x4', vl=15, n_segs=4),
            # Ordered, segment 5
            make_test_case('vloxseg5ei16_v_u16mf2x5', vl=4, n_segs=5),
            make_test_case('vloxseg5ei16_v_u16mf2x5', vl=3, n_segs=5),
            make_test_case('vloxseg5ei16_v_u16m1x5', vl=8, n_segs=5),
            make_test_case('vloxseg5ei16_v_u16m1x5', vl=7, n_segs=5),
            # Ordered, segment 6
            make_test_case('vloxseg6ei16_v_u16mf2x6', vl=4, n_segs=6),
            make_test_case('vloxseg6ei16_v_u16mf2x6', vl=3, n_segs=6),
            make_test_case('vloxseg6ei16_v_u16m1x6', vl=8, n_segs=6),
            make_test_case('vloxseg6ei16_v_u16m1x6', vl=7, n_segs=6),
            # Ordered, segment 7
            make_test_case('vloxseg7ei16_v_u16mf2x7', vl=4, n_segs=7),
            make_test_case('vloxseg7ei16_v_u16mf2x7', vl=3, n_segs=7),
            make_test_case('vloxseg7ei16_v_u16m1x7', vl=8, n_segs=7),
            make_test_case('vloxseg7ei16_v_u16m1x7', vl=7, n_segs=7),
            # Ordered, segment 8
            make_test_case('vloxseg8ei16_v_u16mf2x8', vl=4, n_segs=8),
            make_test_case('vloxseg8ei16_v_u16mf2x8', vl=3, n_segs=8),
            make_test_case('vloxseg8ei16_v_u16m1x8', vl=8, n_segs=8),
            make_test_case('vloxseg8ei16_v_u16m1x8', vl=7, n_segs=8),
        ],
        dtype=np.uint16,
        index_dtype=np.uint16,
    )


@cocotb.test()
async def load16_index32_seg(dut):
    """Test vl*xseg*ei32_v_u16 usage accessible from intrinsics."""

    def make_test_case(impl: str, vl: int, n_segs: int):
        return {
            'impl': impl,
            'vl': vl,
            'segments': n_segs,
            'in_bytes': 30000,
            'out_size': vl * n_segs * 2,
        }

    await vector_load_segmented_indexed(
        dut=dut,
        elf_name='load16_index32_seg.elf',
        cases=[
            # Unordered, segment 2
            make_test_case('vluxseg2ei32_v_u16mf2x2', vl=4, n_segs=2),
            make_test_case('vluxseg2ei32_v_u16mf2x2', vl=3, n_segs=2),
            make_test_case('vluxseg2ei32_v_u16m1x2', vl=8, n_segs=2),
            make_test_case('vluxseg2ei32_v_u16m1x2', vl=7, n_segs=2),
            make_test_case('vluxseg2ei32_v_u16m2x2', vl=16, n_segs=2),
            make_test_case('vluxseg2ei32_v_u16m2x2', vl=15, n_segs=2),
            make_test_case('vluxseg2ei32_v_u16m4x2', vl=32, n_segs=2),
            make_test_case('vluxseg2ei32_v_u16m4x2', vl=31, n_segs=2),
            # Unordered, segment 3
            make_test_case('vluxseg3ei32_v_u16mf2x3', vl=4, n_segs=3),
            make_test_case('vluxseg3ei32_v_u16mf2x3', vl=3, n_segs=3),
            make_test_case('vluxseg3ei32_v_u16m1x3', vl=8, n_segs=3),
            make_test_case('vluxseg3ei32_v_u16m1x3', vl=7, n_segs=3),
            make_test_case('vluxseg3ei32_v_u16m2x3', vl=16, n_segs=3),
            make_test_case('vluxseg3ei32_v_u16m2x3', vl=15, n_segs=3),
            # Unordered, segment 4
            make_test_case('vluxseg4ei32_v_u16mf2x4', vl=4, n_segs=4),
            make_test_case('vluxseg4ei32_v_u16mf2x4', vl=3, n_segs=4),
            make_test_case('vluxseg4ei32_v_u16m1x4', vl=8, n_segs=4),
            make_test_case('vluxseg4ei32_v_u16m1x4', vl=7, n_segs=4),
            make_test_case('vluxseg4ei32_v_u16m2x4', vl=16, n_segs=4),
            make_test_case('vloxseg4ei32_v_u16m2x4', vl=15, n_segs=4),
            # Unordered, segment 5
            make_test_case('vluxseg5ei32_v_u16mf2x5', vl=4, n_segs=5),
            make_test_case('vluxseg5ei32_v_u16mf2x5', vl=3, n_segs=5),
            make_test_case('vluxseg5ei32_v_u16m1x5', vl=8, n_segs=5),
            make_test_case('vluxseg5ei32_v_u16m1x5', vl=7, n_segs=5),
            # Unordered, segment 6
            make_test_case('vluxseg6ei32_v_u16mf2x6', vl=4, n_segs=6),
            make_test_case('vluxseg6ei32_v_u16mf2x6', vl=3, n_segs=6),
            make_test_case('vluxseg6ei32_v_u16m1x6', vl=8, n_segs=6),
            make_test_case('vluxseg6ei32_v_u16m1x6', vl=7, n_segs=6),
            # Unordered, segment 7
            make_test_case('vluxseg7ei32_v_u16mf2x7', vl=4, n_segs=7),
            make_test_case('vluxseg7ei32_v_u16mf2x7', vl=3, n_segs=7),
            make_test_case('vluxseg7ei32_v_u16m1x7', vl=8, n_segs=7),
            make_test_case('vluxseg7ei32_v_u16m1x7', vl=7, n_segs=7),
            # Unordered, segment 8
            make_test_case('vluxseg8ei32_v_u16mf2x8', vl=4, n_segs=8),
            make_test_case('vluxseg8ei32_v_u16mf2x8', vl=3, n_segs=8),
            make_test_case('vluxseg8ei32_v_u16m1x8', vl=8, n_segs=8),
            make_test_case('vluxseg8ei32_v_u16m1x8', vl=7, n_segs=8),
            # Ordered, segment 2
            make_test_case('vloxseg2ei32_v_u16mf2x2', vl=4, n_segs=2),
            make_test_case('vloxseg2ei32_v_u16mf2x2', vl=3, n_segs=2),
            make_test_case('vloxseg2ei32_v_u16m1x2', vl=8, n_segs=2),
            make_test_case('vloxseg2ei32_v_u16m1x2', vl=7, n_segs=2),
            make_test_case('vloxseg2ei32_v_u16m2x2', vl=16, n_segs=2),
            make_test_case('vloxseg2ei32_v_u16m2x2', vl=15, n_segs=2),
            make_test_case('vloxseg2ei32_v_u16m4x2', vl=32, n_segs=2),
            make_test_case('vloxseg2ei32_v_u16m4x2', vl=31, n_segs=2),
            # Ordered, segment 3
            make_test_case('vloxseg3ei32_v_u16mf2x3', vl=4, n_segs=3),
            make_test_case('vloxseg3ei32_v_u16mf2x3', vl=3, n_segs=3),
            make_test_case('vloxseg3ei32_v_u16m1x3', vl=8, n_segs=3),
            make_test_case('vloxseg3ei32_v_u16m1x3', vl=7, n_segs=3),
            make_test_case('vloxseg3ei32_v_u16m2x3', vl=16, n_segs=3),
            make_test_case('vloxseg3ei32_v_u16m2x3', vl=15, n_segs=3),
            # Ordered, segment 4
            make_test_case('vloxseg4ei32_v_u16mf2x4', vl=4, n_segs=4),
            make_test_case('vloxseg4ei32_v_u16mf2x4', vl=3, n_segs=4),
            make_test_case('vloxseg4ei32_v_u16m1x4', vl=8, n_segs=4),
            make_test_case('vloxseg4ei32_v_u16m1x4', vl=7, n_segs=4),
            make_test_case('vloxseg4ei32_v_u16m2x4', vl=16, n_segs=4),
            make_test_case('vloxseg4ei32_v_u16m2x4', vl=15, n_segs=4),
            # Ordered, segment 5
            make_test_case('vloxseg5ei32_v_u16mf2x5', vl=4, n_segs=5),
            make_test_case('vloxseg5ei32_v_u16mf2x5', vl=3, n_segs=5),
            make_test_case('vloxseg5ei32_v_u16m1x5', vl=8, n_segs=5),
            make_test_case('vloxseg5ei32_v_u16m1x5', vl=7, n_segs=5),
            # Ordered, segment 6
            make_test_case('vloxseg6ei32_v_u16mf2x6', vl=4, n_segs=6),
            make_test_case('vloxseg6ei32_v_u16mf2x6', vl=3, n_segs=6),
            make_test_case('vloxseg6ei32_v_u16m1x6', vl=8, n_segs=6),
            make_test_case('vloxseg6ei32_v_u16m1x6', vl=7, n_segs=6),
            # Ordered, segment 7
            make_test_case('vloxseg7ei32_v_u16mf2x7', vl=4, n_segs=7),
            make_test_case('vloxseg7ei32_v_u16mf2x7', vl=3, n_segs=7),
            make_test_case('vloxseg7ei32_v_u16m1x7', vl=8, n_segs=7),
            make_test_case('vloxseg7ei32_v_u16m1x7', vl=7, n_segs=7),
            # Ordered, segment 8
            make_test_case('vloxseg8ei32_v_u16mf2x8', vl=4, n_segs=8),
            make_test_case('vloxseg8ei32_v_u16mf2x8', vl=3, n_segs=8),
            make_test_case('vloxseg8ei32_v_u16m1x8', vl=8, n_segs=8),
            make_test_case('vloxseg8ei32_v_u16m1x8', vl=7, n_segs=8),
        ],
        dtype=np.uint16,
        index_dtype=np.uint32,
    )


@cocotb.test()
async def load16_seg_unit(dut):
    """Test vlseg*e16 usage accessible from intrinsics."""

    def make_test_case(impl: str, vl: int, n_segs: int):
        return {
            'impl':
            impl,
            'vl':
            vl,
            'in_size':
            vl * n_segs * 2,
            'out_size':
            vl * n_segs * 2,
            'pattern': [
                elem * n_segs + seg
                for seg in range(n_segs)
                for elem in range(vl)
            ]
        }

    await vector_load_store_v2(
        dut=dut,
        elf_name='load16_seg_unit.elf',
        cases=[
            # Seg 2
            make_test_case('vlseg2e16_v_u16mf2x2', vl=4, n_segs=2),
            make_test_case('vlseg2e16_v_u16mf2x2', vl=3, n_segs=2),
            make_test_case('vlseg2e16_v_u16mf2x2', vl=1, n_segs=2),
            make_test_case('vlseg2e16_v_u16m1x2', vl=8, n_segs=2),
            make_test_case('vlseg2e16_v_u16m1x2', vl=7, n_segs=2),
            make_test_case('vlseg2e16_v_u16m1x2', vl=1, n_segs=2),
            make_test_case('vlseg2e16_v_u16m2x2', vl=16, n_segs=2),
            make_test_case('vlseg2e16_v_u16m2x2', vl=15, n_segs=2),
            make_test_case('vlseg2e16_v_u16m2x2', vl=1, n_segs=2),
            make_test_case('vlseg2e16_v_u16m4x2', vl=32, n_segs=2),
            make_test_case('vlseg2e16_v_u16m4x2', vl=31, n_segs=2),
            make_test_case('vlseg2e16_v_u16m4x2', vl=1, n_segs=2),
            # Seg 3
            make_test_case('vlseg3e16_v_u16mf2x3', vl=4, n_segs=3),
            make_test_case('vlseg3e16_v_u16mf2x3', vl=3, n_segs=3),
            make_test_case('vlseg3e16_v_u16mf2x3', vl=1, n_segs=3),
            make_test_case('vlseg3e16_v_u16m1x3', vl=8, n_segs=3),
            make_test_case('vlseg3e16_v_u16m1x3', vl=7, n_segs=3),
            make_test_case('vlseg3e16_v_u16m1x3', vl=1, n_segs=3),
            make_test_case('vlseg3e16_v_u16m2x3', vl=16, n_segs=3),
            make_test_case('vlseg3e16_v_u16m2x3', vl=15, n_segs=3),
            make_test_case('vlseg3e16_v_u16m2x3', vl=1, n_segs=3),
            # Seg 4
            make_test_case('vlseg4e16_v_u16mf2x4', vl=4, n_segs=4),
            make_test_case('vlseg4e16_v_u16mf2x4', vl=3, n_segs=4),
            make_test_case('vlseg4e16_v_u16mf2x4', vl=1, n_segs=4),
            make_test_case('vlseg4e16_v_u16m1x4', vl=8, n_segs=4),
            make_test_case('vlseg4e16_v_u16m1x4', vl=7, n_segs=4),
            make_test_case('vlseg4e16_v_u16m1x4', vl=1, n_segs=4),
            make_test_case('vlseg4e16_v_u16m2x4', vl=16, n_segs=4),
            make_test_case('vlseg4e16_v_u16m2x4', vl=15, n_segs=4),
            make_test_case('vlseg4e16_v_u16m2x4', vl=1, n_segs=4),
            # Seg 5
            make_test_case('vlseg5e16_v_u16mf2x5', vl=4, n_segs=5),
            make_test_case('vlseg5e16_v_u16mf2x5', vl=3, n_segs=5),
            make_test_case('vlseg5e16_v_u16mf2x5', vl=1, n_segs=5),
            make_test_case('vlseg5e16_v_u16m1x5', vl=8, n_segs=5),
            make_test_case('vlseg5e16_v_u16m1x5', vl=7, n_segs=5),
            make_test_case('vlseg5e16_v_u16m1x5', vl=1, n_segs=5),
            # Seg 6
            make_test_case('vlseg6e16_v_u16mf2x6', vl=4, n_segs=6),
            make_test_case('vlseg6e16_v_u16mf2x6', vl=3, n_segs=6),
            make_test_case('vlseg6e16_v_u16mf2x6', vl=1, n_segs=6),
            make_test_case('vlseg6e16_v_u16m1x6', vl=8, n_segs=6),
            make_test_case('vlseg6e16_v_u16m1x6', vl=7, n_segs=6),
            make_test_case('vlseg6e16_v_u16m1x6', vl=1, n_segs=6),
            # Seg 7
            make_test_case('vlseg7e16_v_u16mf2x7', vl=4, n_segs=7),
            make_test_case('vlseg7e16_v_u16mf2x7', vl=3, n_segs=7),
            make_test_case('vlseg7e16_v_u16mf2x7', vl=1, n_segs=7),
            make_test_case('vlseg7e16_v_u16m1x7', vl=8, n_segs=7),
            make_test_case('vlseg7e16_v_u16m1x7', vl=7, n_segs=7),
            make_test_case('vlseg7e16_v_u16m1x7', vl=1, n_segs=7),
            # Seg 8
            make_test_case('vlseg8e16_v_u16mf2x8', vl=4, n_segs=8),
            make_test_case('vlseg8e16_v_u16mf2x8', vl=3, n_segs=8),
            make_test_case('vlseg8e16_v_u16mf2x8', vl=1, n_segs=8),
            make_test_case('vlseg8e16_v_u16m1x8', vl=8, n_segs=8),
            make_test_case('vlseg8e16_v_u16m1x8', vl=7, n_segs=8),
            make_test_case('vlseg8e16_v_u16m1x8', vl=1, n_segs=8),
        ],
        dtype=np.uint16,
    )


@cocotb.test()
async def load32_index8(dut):
    """Test vl*xei8_v_u32 usage accessible from intrinsics."""

    def make_test_case(impl: str, vl: int):
        return {
            'impl': impl,
            'vl': vl,
            'segments': 1,
            'in_bytes': 259,  # 4 bytes at offset 255 reachable.
            'out_size': vl * 2,
        }

    await vector_load_segmented_indexed(
        dut=dut,
        elf_name='load32_index8.elf',
        cases=[
            # Unordered
            make_test_case('vluxei8_v_u32m1', vl=4),
            make_test_case('vluxei8_v_u32m1', vl=3),
            make_test_case('vluxei8_v_u32m2', vl=8),
            make_test_case('vluxei8_v_u32m2', vl=7),
            make_test_case('vluxei8_v_u32m4', vl=16),
            make_test_case('vluxei8_v_u32m4', vl=15),
            make_test_case('vluxei8_v_u32m8', vl=32),
            make_test_case('vluxei8_v_u32m8', vl=31),
            # Ordered
            make_test_case('vloxei8_v_u32m1', vl=4),
            make_test_case('vloxei8_v_u32m1', vl=3),
            make_test_case('vloxei8_v_u32m2', vl=8),
            make_test_case('vloxei8_v_u32m2', vl=7),
            make_test_case('vloxei8_v_u32m4', vl=16),
            make_test_case('vloxei8_v_u32m4', vl=15),
            make_test_case('vloxei8_v_u32m8', vl=32),
            make_test_case('vloxei8_v_u32m8', vl=31),
        ],
        dtype=np.uint32,
        index_dtype=np.uint8,
    )


@cocotb.test()
async def load32_index8_seg(dut):
    """Test vl*xseg*ei32_v_u32 usage accessible from intrinsics."""

    def make_test_case(impl: str, vl: int, n_segs: int):
        return {
            'impl': impl,
            'vl': vl,
            'segments': n_segs,
            'in_bytes': 271,
            'out_size': vl * n_segs * 2,
        }

    await vector_load_segmented_indexed(
        dut=dut,
        elf_name='load32_index8_seg.elf',
        cases=[
            # Unordered, segment 2
            make_test_case('vluxseg2ei8_v_u32m1x2', vl=4, n_segs=2),
            make_test_case('vluxseg2ei8_v_u32m1x2', vl=3, n_segs=2),
            make_test_case('vluxseg2ei8_v_u32m2x2', vl=8, n_segs=2),
            make_test_case('vluxseg2ei8_v_u32m2x2', vl=7, n_segs=2),
            make_test_case('vluxseg2ei8_v_u32m4x2', vl=16, n_segs=2),
            make_test_case('vluxseg2ei8_v_u32m4x2', vl=15, n_segs=2),
            # Unordered, segment 3
            make_test_case('vluxseg3ei8_v_u32m1x3', vl=4, n_segs=3),
            make_test_case('vluxseg3ei8_v_u32m1x3', vl=3, n_segs=3),
            make_test_case('vluxseg3ei8_v_u32m2x3', vl=8, n_segs=3),
            make_test_case('vluxseg3ei8_v_u32m2x3', vl=7, n_segs=3),
            # Unordered, segment 4
            make_test_case('vluxseg4ei8_v_u32m1x4', vl=4, n_segs=4),
            make_test_case('vluxseg4ei8_v_u32m1x4', vl=3, n_segs=4),
            make_test_case('vluxseg4ei8_v_u32m2x4', vl=8, n_segs=4),
            make_test_case('vluxseg4ei8_v_u32m2x4', vl=7, n_segs=4),
            # Unordered, segment 5
            make_test_case('vluxseg5ei8_v_u32m1x5', vl=4, n_segs=5),
            make_test_case('vluxseg5ei8_v_u32m1x5', vl=3, n_segs=5),
            # Unordered, segment 6
            make_test_case('vluxseg6ei8_v_u32m1x6', vl=4, n_segs=6),
            make_test_case('vluxseg6ei8_v_u32m1x6', vl=3, n_segs=6),
            # Unordered, segment 7
            make_test_case('vluxseg7ei8_v_u32m1x7', vl=4, n_segs=7),
            make_test_case('vluxseg7ei8_v_u32m1x7', vl=3, n_segs=7),
            # Unordered, segment 8
            make_test_case('vluxseg8ei8_v_u32m1x8', vl=4, n_segs=8),
            make_test_case('vluxseg8ei8_v_u32m1x8', vl=3, n_segs=8),
            # Ordered, segment 2
            make_test_case('vloxseg2ei8_v_u32m1x2', vl=4, n_segs=2),
            make_test_case('vloxseg2ei8_v_u32m1x2', vl=3, n_segs=2),
            make_test_case('vloxseg2ei8_v_u32m2x2', vl=8, n_segs=2),
            make_test_case('vloxseg2ei8_v_u32m2x2', vl=7, n_segs=2),
            make_test_case('vloxseg2ei8_v_u32m4x2', vl=16, n_segs=2),
            make_test_case('vloxseg2ei8_v_u32m4x2', vl=15, n_segs=2),
            # Ordered, segment 3
            make_test_case('vloxseg3ei8_v_u32m1x3', vl=4, n_segs=3),
            make_test_case('vloxseg3ei8_v_u32m1x3', vl=3, n_segs=3),
            make_test_case('vloxseg3ei8_v_u32m2x3', vl=8, n_segs=3),
            make_test_case('vloxseg3ei8_v_u32m2x3', vl=7, n_segs=3),
            # Ordered, segment 4
            make_test_case('vloxseg4ei8_v_u32m1x4', vl=4, n_segs=4),
            make_test_case('vloxseg4ei8_v_u32m1x4', vl=3, n_segs=4),
            make_test_case('vloxseg4ei8_v_u32m2x4', vl=8, n_segs=4),
            make_test_case('vloxseg4ei8_v_u32m2x4', vl=7, n_segs=4),
            # Ordered, segment 5
            make_test_case('vloxseg5ei8_v_u32m1x5', vl=4, n_segs=5),
            make_test_case('vloxseg5ei8_v_u32m1x5', vl=3, n_segs=5),
            # Ordered, segment 6
            make_test_case('vloxseg6ei8_v_u32m1x6', vl=4, n_segs=6),
            make_test_case('vloxseg6ei8_v_u32m1x6', vl=3, n_segs=6),
            # Ordered, segment 7
            make_test_case('vloxseg7ei8_v_u32m1x7', vl=4, n_segs=7),
            make_test_case('vloxseg7ei8_v_u32m1x7', vl=3, n_segs=7),
            # Ordered, segment 8
            make_test_case('vloxseg8ei8_v_u32m1x8', vl=4, n_segs=8),
            make_test_case('vloxseg8ei8_v_u32m1x8', vl=3, n_segs=8),
        ],
        dtype=np.uint32,
        index_dtype=np.uint8,
    )


@cocotb.test()
async def load32_index16_seg(dut):
    """Test vl*xseg*ei32_v_u32 usage accessible from intrinsics."""

    def make_test_case(impl: str, vl: int, n_segs: int):
        return {
            'impl': impl,
            'vl': vl,
            'segments': n_segs,
            'in_bytes': 28000,
            'out_size': vl * n_segs * 2,
        }

    await vector_load_segmented_indexed(
        dut=dut,
        elf_name='load32_index16_seg.elf',
        cases=[
            # Unordered, segment 2
            make_test_case('vluxseg2ei16_v_u32m1x2', vl=4, n_segs=2),
            make_test_case('vluxseg2ei16_v_u32m1x2', vl=3, n_segs=2),
            make_test_case('vluxseg2ei16_v_u32m2x2', vl=8, n_segs=2),
            make_test_case('vluxseg2ei16_v_u32m2x2', vl=7, n_segs=2),
            # Unordered, segment 3
            make_test_case('vluxseg3ei16_v_u32m1x3', vl=4, n_segs=3),
            make_test_case('vluxseg3ei16_v_u32m1x3', vl=3, n_segs=3),
            make_test_case('vluxseg3ei16_v_u32m2x3', vl=8, n_segs=3),
            make_test_case('vluxseg3ei16_v_u32m2x3', vl=7, n_segs=3),
            # Unordered, segment 4
            make_test_case('vluxseg4ei16_v_u32m1x4', vl=4, n_segs=4),
            make_test_case('vluxseg4ei16_v_u32m1x4', vl=3, n_segs=4),
            make_test_case('vluxseg4ei16_v_u32m2x4', vl=8, n_segs=4),
            make_test_case('vluxseg4ei16_v_u32m2x4', vl=7, n_segs=4),
            # Unordered, segment 5
            make_test_case('vluxseg5ei16_v_u32m1x5', vl=4, n_segs=5),
            make_test_case('vluxseg5ei16_v_u32m1x5', vl=3, n_segs=5),
            # Unordered, segment 6
            make_test_case('vluxseg6ei16_v_u32m1x6', vl=4, n_segs=6),
            make_test_case('vluxseg6ei16_v_u32m1x6', vl=3, n_segs=6),
            # Unordered, segment 7
            make_test_case('vluxseg7ei16_v_u32m1x7', vl=4, n_segs=7),
            make_test_case('vluxseg7ei16_v_u32m1x7', vl=3, n_segs=7),
            # Unordered, segment 8
            make_test_case('vluxseg8ei16_v_u32m1x8', vl=4, n_segs=8),
            make_test_case('vluxseg8ei16_v_u32m1x8', vl=3, n_segs=8),
            # Ordered, segment 2
            make_test_case('vloxseg2ei16_v_u32m1x2', vl=4, n_segs=2),
            make_test_case('vloxseg2ei16_v_u32m1x2', vl=3, n_segs=2),
            make_test_case('vloxseg2ei16_v_u32m2x2', vl=8, n_segs=2),
            make_test_case('vloxseg2ei16_v_u32m2x2', vl=7, n_segs=2),
            # Ordered, segment 3
            make_test_case('vloxseg3ei16_v_u32m1x3', vl=4, n_segs=3),
            make_test_case('vloxseg3ei16_v_u32m1x3', vl=3, n_segs=3),
            make_test_case('vloxseg3ei16_v_u32m2x3', vl=8, n_segs=3),
            make_test_case('vloxseg3ei16_v_u32m2x3', vl=7, n_segs=3),
            # Ordered, segment 4
            make_test_case('vloxseg4ei16_v_u32m1x4', vl=4, n_segs=4),
            make_test_case('vloxseg4ei16_v_u32m1x4', vl=3, n_segs=4),
            make_test_case('vloxseg4ei16_v_u32m2x4', vl=8, n_segs=4),
            make_test_case('vloxseg4ei16_v_u32m2x4', vl=7, n_segs=4),
            # Ordered, segment 5
            make_test_case('vloxseg5ei16_v_u32m1x5', vl=4, n_segs=5),
            make_test_case('vloxseg5ei16_v_u32m1x5', vl=3, n_segs=5),
            # Ordered, segment 6
            make_test_case('vloxseg6ei16_v_u32m1x6', vl=4, n_segs=6),
            make_test_case('vloxseg6ei16_v_u32m1x6', vl=3, n_segs=6),
            # Ordered, segment 7
            make_test_case('vloxseg7ei16_v_u32m1x7', vl=4, n_segs=7),
            make_test_case('vloxseg7ei16_v_u32m1x7', vl=3, n_segs=7),
            # Ordered, segment 8
            make_test_case('vloxseg8ei16_v_u32m1x8', vl=4, n_segs=8),
            make_test_case('vloxseg8ei16_v_u32m1x8', vl=3, n_segs=8),
        ],
        dtype=np.uint32,
        index_dtype=np.uint16,
    )


@cocotb.test()
async def load32_index32_seg(dut):
    """Test vl*xseg*ei32_v_u32 usage accessible from intrinsics."""

    def make_test_case(impl: str, vl: int, n_segs: int):
        return {
            'impl': impl,
            'vl': vl,
            'segments': n_segs,
            'in_bytes': 28000,
            'out_size': vl * n_segs * 2,
        }

    await vector_load_segmented_indexed(
        dut=dut,
        elf_name='load32_index32_seg.elf',
        cases=[
            # Unordered, segment 2
            make_test_case('vluxseg2ei32_v_u32m1x2', vl=4, n_segs=2),
            make_test_case('vluxseg2ei32_v_u32m1x2', vl=3, n_segs=2),
            make_test_case('vluxseg2ei32_v_u32m2x2', vl=8, n_segs=2),
            make_test_case('vluxseg2ei32_v_u32m2x2', vl=7, n_segs=2),
            make_test_case('vluxseg2ei32_v_u32m4x2', vl=16, n_segs=2),
            make_test_case('vluxseg2ei32_v_u32m4x2', vl=15, n_segs=2),
            # Unordered, segment 3
            make_test_case('vluxseg3ei32_v_u32m1x3', vl=4, n_segs=3),
            make_test_case('vluxseg3ei32_v_u32m1x3', vl=3, n_segs=3),
            make_test_case('vluxseg3ei32_v_u32m2x3', vl=8, n_segs=3),
            make_test_case('vluxseg3ei32_v_u32m2x3', vl=7, n_segs=3),
            # Unordered, segment 4
            make_test_case('vluxseg4ei32_v_u32m1x4', vl=4, n_segs=4),
            make_test_case('vluxseg4ei32_v_u32m1x4', vl=3, n_segs=4),
            make_test_case('vluxseg4ei32_v_u32m2x4', vl=8, n_segs=4),
            make_test_case('vluxseg4ei32_v_u32m2x4', vl=7, n_segs=4),
            # Unordered, segment 5
            make_test_case('vluxseg5ei32_v_u32m1x5', vl=4, n_segs=5),
            make_test_case('vluxseg5ei32_v_u32m1x5', vl=3, n_segs=5),
            # Unordered, segment 6
            make_test_case('vluxseg6ei32_v_u32m1x6', vl=4, n_segs=6),
            make_test_case('vluxseg6ei32_v_u32m1x6', vl=3, n_segs=6),
            # Unordered, segment 7
            make_test_case('vluxseg7ei32_v_u32m1x7', vl=4, n_segs=7),
            make_test_case('vluxseg7ei32_v_u32m1x7', vl=3, n_segs=7),
            # Unordered, segment 8
            make_test_case('vluxseg8ei32_v_u32m1x8', vl=4, n_segs=8),
            make_test_case('vluxseg8ei32_v_u32m1x8', vl=3, n_segs=8),
            # Ordered, segment 2
            make_test_case('vloxseg2ei32_v_u32m1x2', vl=4, n_segs=2),
            make_test_case('vloxseg2ei32_v_u32m1x2', vl=3, n_segs=2),
            make_test_case('vloxseg2ei32_v_u32m2x2', vl=8, n_segs=2),
            make_test_case('vloxseg2ei32_v_u32m2x2', vl=7, n_segs=2),
            make_test_case('vloxseg2ei32_v_u32m4x2', vl=16, n_segs=2),
            make_test_case('vloxseg2ei32_v_u32m4x2', vl=15, n_segs=2),
            # Ordered, segment 3
            make_test_case('vloxseg3ei32_v_u32m1x3', vl=4, n_segs=3),
            make_test_case('vloxseg3ei32_v_u32m1x3', vl=3, n_segs=3),
            make_test_case('vloxseg3ei32_v_u32m2x3', vl=8, n_segs=3),
            make_test_case('vloxseg3ei32_v_u32m2x3', vl=7, n_segs=3),
            # Ordered, segment 4
            make_test_case('vloxseg4ei32_v_u32m1x4', vl=4, n_segs=4),
            make_test_case('vloxseg4ei32_v_u32m1x4', vl=3, n_segs=4),
            make_test_case('vloxseg4ei32_v_u32m2x4', vl=8, n_segs=4),
            make_test_case('vloxseg4ei32_v_u32m2x4', vl=7, n_segs=4),
            # Ordered, segment 5
            make_test_case('vloxseg5ei32_v_u32m1x5', vl=4, n_segs=5),
            make_test_case('vloxseg5ei32_v_u32m1x5', vl=3, n_segs=5),
            # Ordered, segment 6
            make_test_case('vloxseg6ei32_v_u32m1x6', vl=4, n_segs=6),
            make_test_case('vloxseg6ei32_v_u32m1x6', vl=3, n_segs=6),
            # Ordered, segment 7
            make_test_case('vloxseg7ei32_v_u32m1x7', vl=4, n_segs=7),
            make_test_case('vloxseg7ei32_v_u32m1x7', vl=3, n_segs=7),
            # Ordered, segment 8
            make_test_case('vloxseg8ei32_v_u32m1x8', vl=4, n_segs=8),
            make_test_case('vloxseg8ei32_v_u32m1x8', vl=3, n_segs=8),
        ],
        dtype=np.uint32,
        index_dtype=np.uint32,
    )


@cocotb.test()
async def load32_seg_unit(dut):
    """Test vlseg*e32 usage accessible from intrinsics."""

    def make_test_case(impl: str, vl: int, n_segs: int):
        return {
            'impl':
            impl,
            'vl':
            vl,
            'in_size':
            vl * n_segs * 2,
            'out_size':
            vl * n_segs * 2,
            'pattern': [
                elem * n_segs + seg
                for seg in range(n_segs)
                for elem in range(vl)
            ]
        }

    await vector_load_store_v2(
        dut=dut,
        elf_name='load32_seg_unit.elf',
        cases=[
            # Seg 2
            make_test_case('vlseg2e32_v_u32m1x2', vl=4, n_segs=2),
            make_test_case('vlseg2e32_v_u32m1x2', vl=3, n_segs=2),
            make_test_case('vlseg2e32_v_u32m1x2', vl=1, n_segs=2),
            make_test_case('vlseg2e32_v_u32m2x2', vl=8, n_segs=2),
            make_test_case('vlseg2e32_v_u32m2x2', vl=7, n_segs=2),
            make_test_case('vlseg2e32_v_u32m2x2', vl=1, n_segs=2),
            make_test_case('vlseg2e32_v_u32m4x2', vl=16, n_segs=2),
            make_test_case('vlseg2e32_v_u32m4x2', vl=15, n_segs=2),
            make_test_case('vlseg2e32_v_u32m4x2', vl=1, n_segs=2),
            # Seg 3
            make_test_case('vlseg3e32_v_u32m1x3', vl=4, n_segs=3),
            make_test_case('vlseg3e32_v_u32m1x3', vl=3, n_segs=3),
            make_test_case('vlseg3e32_v_u32m1x3', vl=1, n_segs=3),
            make_test_case('vlseg3e32_v_u32m2x3', vl=8, n_segs=3),
            make_test_case('vlseg3e32_v_u32m2x3', vl=7, n_segs=3),
            make_test_case('vlseg3e32_v_u32m2x3', vl=1, n_segs=3),
            # Seg 4
            make_test_case('vlseg4e32_v_u32m1x4', vl=4, n_segs=4),
            make_test_case('vlseg4e32_v_u32m1x4', vl=3, n_segs=4),
            make_test_case('vlseg4e32_v_u32m1x4', vl=1, n_segs=4),
            make_test_case('vlseg4e32_v_u32m2x4', vl=8, n_segs=4),
            make_test_case('vlseg4e32_v_u32m2x4', vl=7, n_segs=4),
            make_test_case('vlseg4e32_v_u32m2x4', vl=1, n_segs=4),
            # Seg 5
            make_test_case('vlseg5e32_v_u32m1x5', vl=4, n_segs=5),
            make_test_case('vlseg5e32_v_u32m1x5', vl=3, n_segs=5),
            make_test_case('vlseg5e32_v_u32m1x5', vl=1, n_segs=5),
            # Seg 6
            make_test_case('vlseg6e32_v_u32m1x6', vl=4, n_segs=6),
            make_test_case('vlseg6e32_v_u32m1x6', vl=3, n_segs=6),
            make_test_case('vlseg6e32_v_u32m1x6', vl=1, n_segs=6),
            # Seg 7
            make_test_case('vlseg7e32_v_u32m1x7', vl=4, n_segs=7),
            make_test_case('vlseg7e32_v_u32m1x7', vl=3, n_segs=7),
            make_test_case('vlseg7e32_v_u32m1x7', vl=1, n_segs=7),
            # Seg 8
            make_test_case('vlseg8e32_v_u32m1x8', vl=4, n_segs=8),
            make_test_case('vlseg8e32_v_u32m1x8', vl=3, n_segs=8),
            make_test_case('vlseg8e32_v_u32m1x8', vl=1, n_segs=8),
        ],
        dtype=np.uint32,
    )


@cocotb.test()
async def load8_segment2_stride6_m1(dut):
    await vector_load_store(
        dut=dut,
        elf_name='load8_segment2_stride6_m1.elf',
        dtype=np.uint8,
        in_size=256,
        out_size=64,
        pattern=([i * 6 for i in range(16)] + [i * 6 + 1 for i in range(16)]),
    )


@cocotb.test()
async def load16_segment2_stride6_m1(dut):
    await vector_load_store(
        dut=dut,
        elf_name='load16_segment2_stride6_m1.elf',
        dtype=np.uint16,
        in_size=128,
        out_size=32,
        pattern=([i * 3 for i in range(8)] + [i * 3 + 1 for i in range(8)]),
    )


@cocotb.test()
async def store8_index8(dut):
    """Test vs*xei8_v_u8 usage accessible from intrinsics."""

    def make_test_case(impl: str, vl: int):
        return {
            'impl': impl,
            'vl': vl,
            'segments': 1,
            'out_size': 512,
        }

    await vector_store_segmented_indexed(
        dut=dut,
        elf_name='store8_index8.elf',
        cases=[
            # Unordered
            make_test_case('vsuxei8_v_u8mf4', vl=4),
            make_test_case('vsuxei8_v_u8mf4', vl=3),
            make_test_case('vsuxei8_v_u8mf2', vl=8),
            make_test_case('vsuxei8_v_u8mf2', vl=7),
            make_test_case('vsuxei8_v_u8m1', vl=16),
            make_test_case('vsuxei8_v_u8m1', vl=15),
            make_test_case('vsuxei8_v_u8m2', vl=32),
            make_test_case('vsuxei8_v_u8m2', vl=31),
            make_test_case('vsuxei8_v_u8m4', vl=64),
            make_test_case('vsuxei8_v_u8m4', vl=63),
            make_test_case('vsuxei8_v_u8m8', vl=128),
            make_test_case('vsuxei8_v_u8m8', vl=127),
            # Ordered
            make_test_case('vsoxei8_v_u8mf2', vl=4),
            make_test_case('vsoxei8_v_u8mf2', vl=3),
            make_test_case('vsoxei8_v_u8mf2', vl=8),
            make_test_case('vsoxei8_v_u8mf2', vl=7),
            make_test_case('vsoxei8_v_u8m1', vl=16),
            make_test_case('vsoxei8_v_u8m1', vl=15),
            make_test_case('vsoxei8_v_u8m2', vl=32),
            make_test_case('vsoxei8_v_u8m2', vl=31),
            make_test_case('vsoxei8_v_u8m4', vl=64),
            make_test_case('vsoxei8_v_u8m4', vl=63),
            make_test_case('vsoxei8_v_u8m8', vl=128),
            make_test_case('vsoxei8_v_u8m8', vl=127),
        ],
        data_dtype=np.uint8,
        index_dtype=np.uint8,
    )


@cocotb.test()
async def store8_index8_seg(dut):
    """Test vs*xseg*ei8_v_u8 usage accessible from intrinsics."""

    def make_test_case(impl: str, vl: int, segs: int):
        return {
            'impl': impl,
            'vl': vl,
            'segments': segs,
            'out_size': 512,
        }

    await vector_store_segmented_indexed(
        dut=dut,
        elf_name='store8_index8_seg.elf',
        cases=[
            # Unordered, segment 2
            make_test_case('vsuxseg2ei8_v_u8mf4x2', vl=4, segs=2),
            make_test_case('vsuxseg2ei8_v_u8mf4x2', vl=3, segs=2),
            make_test_case('vsuxseg2ei8_v_u8mf2x2', vl=8, segs=2),
            make_test_case('vsuxseg2ei8_v_u8mf2x2', vl=7, segs=2),
            make_test_case('vsuxseg2ei8_v_u8m1x2', vl=16, segs=2),
            make_test_case('vsuxseg2ei8_v_u8m1x2', vl=15, segs=2),
            make_test_case('vsuxseg2ei8_v_u8m2x2', vl=32, segs=2),
            make_test_case('vsuxseg2ei8_v_u8m2x2', vl=31, segs=2),
            make_test_case('vsuxseg2ei8_v_u8m4x2', vl=64, segs=2),
            make_test_case('vsuxseg2ei8_v_u8m4x2', vl=63, segs=2),
            # Unordered, segment 3
            make_test_case('vsuxseg3ei8_v_u8mf4x3', vl=4, segs=3),
            make_test_case('vsuxseg3ei8_v_u8mf4x3', vl=3, segs=3),
            make_test_case('vsuxseg3ei8_v_u8mf2x3', vl=8, segs=3),
            make_test_case('vsuxseg3ei8_v_u8mf2x3', vl=7, segs=3),
            make_test_case('vsuxseg3ei8_v_u8m1x3', vl=16, segs=3),
            make_test_case('vsuxseg3ei8_v_u8m1x3', vl=15, segs=3),
            make_test_case('vsuxseg3ei8_v_u8m2x3', vl=32, segs=3),
            make_test_case('vsuxseg3ei8_v_u8m2x3', vl=31, segs=3),
            # Unordered, segment 4
            make_test_case('vsuxseg4ei8_v_u8mf4x4', vl=4, segs=4),
            make_test_case('vsuxseg4ei8_v_u8mf4x4', vl=3, segs=4),
            make_test_case('vsuxseg4ei8_v_u8mf2x4', vl=8, segs=4),
            make_test_case('vsuxseg4ei8_v_u8mf2x4', vl=7, segs=4),
            make_test_case('vsuxseg4ei8_v_u8m1x4', vl=16, segs=4),
            make_test_case('vsuxseg4ei8_v_u8m1x4', vl=15, segs=4),
            make_test_case('vsuxseg4ei8_v_u8m2x4', vl=32, segs=4),
            make_test_case('vsuxseg4ei8_v_u8m2x4', vl=31, segs=4),
            # Unordered, segment 5
            make_test_case('vsuxseg5ei8_v_u8mf4x5', vl=4, segs=5),
            make_test_case('vsuxseg5ei8_v_u8mf4x5', vl=3, segs=5),
            make_test_case('vsuxseg5ei8_v_u8mf2x5', vl=8, segs=5),
            make_test_case('vsuxseg5ei8_v_u8mf2x5', vl=7, segs=5),
            make_test_case('vsuxseg5ei8_v_u8m1x5', vl=16, segs=5),
            make_test_case('vsuxseg5ei8_v_u8m1x5', vl=15, segs=5),
            # Unordered, segment 6
            make_test_case('vsuxseg6ei8_v_u8mf4x6', vl=4, segs=6),
            make_test_case('vsuxseg6ei8_v_u8mf4x6', vl=3, segs=6),
            make_test_case('vsuxseg6ei8_v_u8mf2x6', vl=8, segs=6),
            make_test_case('vsuxseg6ei8_v_u8mf2x6', vl=7, segs=6),
            make_test_case('vsuxseg6ei8_v_u8m1x6', vl=16, segs=6),
            make_test_case('vsuxseg6ei8_v_u8m1x6', vl=15, segs=6),
            # Unordered, segment 7
            make_test_case('vsuxseg7ei8_v_u8mf4x7', vl=4, segs=7),
            make_test_case('vsuxseg7ei8_v_u8mf4x7', vl=3, segs=7),
            make_test_case('vsuxseg7ei8_v_u8mf2x7', vl=8, segs=7),
            make_test_case('vsuxseg7ei8_v_u8mf2x7', vl=7, segs=7),
            make_test_case('vsuxseg7ei8_v_u8m1x7', vl=16, segs=7),
            make_test_case('vsuxseg7ei8_v_u8m1x7', vl=15, segs=7),
            # Unordered, segment 8
            make_test_case('vsuxseg8ei8_v_u8mf4x8', vl=4, segs=8),
            make_test_case('vsuxseg8ei8_v_u8mf4x8', vl=3, segs=8),
            make_test_case('vsuxseg8ei8_v_u8mf2x8', vl=8, segs=8),
            make_test_case('vsuxseg8ei8_v_u8mf2x8', vl=7, segs=8),
            make_test_case('vsuxseg8ei8_v_u8m1x8', vl=16, segs=8),
            make_test_case('vsuxseg8ei8_v_u8m1x8', vl=15, segs=8),
            # Ordered, segment 2
            make_test_case('vsoxseg2ei8_v_u8mf4x2', vl=4, segs=2),
            make_test_case('vsoxseg2ei8_v_u8mf4x2', vl=3, segs=2),
            make_test_case('vsoxseg2ei8_v_u8mf2x2', vl=8, segs=2),
            make_test_case('vsoxseg2ei8_v_u8mf2x2', vl=7, segs=2),
            make_test_case('vsoxseg2ei8_v_u8m1x2', vl=16, segs=2),
            make_test_case('vsoxseg2ei8_v_u8m1x2', vl=15, segs=2),
            make_test_case('vsoxseg2ei8_v_u8m2x2', vl=32, segs=2),
            make_test_case('vsoxseg2ei8_v_u8m2x2', vl=31, segs=2),
            make_test_case('vsoxseg2ei8_v_u8m4x2', vl=64, segs=2),
            make_test_case('vsoxseg2ei8_v_u8m4x2', vl=63, segs=2),
            # Ordered, segment 3
            make_test_case('vsoxseg3ei8_v_u8mf4x3', vl=4, segs=3),
            make_test_case('vsoxseg3ei8_v_u8mf4x3', vl=3, segs=3),
            make_test_case('vsoxseg3ei8_v_u8mf2x3', vl=8, segs=3),
            make_test_case('vsoxseg3ei8_v_u8mf2x3', vl=7, segs=3),
            make_test_case('vsoxseg3ei8_v_u8m1x3', vl=16, segs=3),
            make_test_case('vsoxseg3ei8_v_u8m1x3', vl=15, segs=3),
            make_test_case('vsoxseg3ei8_v_u8m2x3', vl=32, segs=3),
            make_test_case('vsoxseg3ei8_v_u8m2x3', vl=31, segs=3),
            # Ordered, segment 4
            make_test_case('vsoxseg4ei8_v_u8mf4x4', vl=4, segs=4),
            make_test_case('vsoxseg4ei8_v_u8mf4x4', vl=3, segs=4),
            make_test_case('vsoxseg4ei8_v_u8mf2x4', vl=8, segs=4),
            make_test_case('vsoxseg4ei8_v_u8mf2x4', vl=7, segs=4),
            make_test_case('vsoxseg4ei8_v_u8m1x4', vl=16, segs=4),
            make_test_case('vsoxseg4ei8_v_u8m1x4', vl=15, segs=4),
            make_test_case('vsoxseg4ei8_v_u8m2x4', vl=32, segs=4),
            make_test_case('vsoxseg4ei8_v_u8m2x4', vl=31, segs=4),
            # Ordered, segment 5
            make_test_case('vsoxseg5ei8_v_u8mf4x5', vl=4, segs=5),
            make_test_case('vsoxseg5ei8_v_u8mf4x5', vl=3, segs=5),
            make_test_case('vsoxseg5ei8_v_u8mf2x5', vl=8, segs=5),
            make_test_case('vsoxseg5ei8_v_u8mf2x5', vl=7, segs=5),
            make_test_case('vsoxseg5ei8_v_u8m1x5', vl=16, segs=5),
            make_test_case('vsoxseg5ei8_v_u8m1x5', vl=15, segs=5),
            # Ordered, segment 6
            make_test_case('vsoxseg6ei8_v_u8mf4x6', vl=4, segs=6),
            make_test_case('vsoxseg6ei8_v_u8mf4x6', vl=3, segs=6),
            make_test_case('vsoxseg6ei8_v_u8mf2x6', vl=8, segs=6),
            make_test_case('vsoxseg6ei8_v_u8mf2x6', vl=7, segs=6),
            make_test_case('vsoxseg6ei8_v_u8m1x6', vl=16, segs=6),
            make_test_case('vsoxseg6ei8_v_u8m1x6', vl=15, segs=6),
            # Ordered, segment 7
            make_test_case('vsoxseg7ei8_v_u8mf4x7', vl=4, segs=7),
            make_test_case('vsoxseg7ei8_v_u8mf4x7', vl=3, segs=7),
            make_test_case('vsoxseg7ei8_v_u8mf2x7', vl=8, segs=7),
            make_test_case('vsoxseg7ei8_v_u8mf2x7', vl=7, segs=7),
            make_test_case('vsoxseg7ei8_v_u8m1x7', vl=16, segs=7),
            make_test_case('vsoxseg7ei8_v_u8m1x7', vl=15, segs=7),
            # Ordered, segment 8
            make_test_case('vsoxseg8ei8_v_u8mf4x8', vl=4, segs=8),
            make_test_case('vsoxseg8ei8_v_u8mf4x8', vl=3, segs=8),
            make_test_case('vsoxseg8ei8_v_u8mf2x8', vl=8, segs=8),
            make_test_case('vsoxseg8ei8_v_u8mf2x8', vl=7, segs=8),
            make_test_case('vsoxseg8ei8_v_u8m1x8', vl=16, segs=8),
            make_test_case('vsoxseg8ei8_v_u8m1x8', vl=15, segs=8),
        ],
        data_dtype=np.uint8,
        index_dtype=np.uint8,
    )


@cocotb.test()
async def store8_index16(dut):
    """Test vs*xei16_v_u8 usage accessible from intrinsics."""

    def make_test_case(impl: str, vl: int):
        return {
            'impl': impl,
            'vl': vl,
            'segments': 1,
            'out_size': 30000,
        }

    await vector_store_segmented_indexed(
        dut=dut,
        elf_name='store8_index16.elf',
        cases=[
            # Unordered
            make_test_case('vsuxei16_v_u8mf4', vl=4),
            make_test_case('vsuxei16_v_u8mf4', vl=3),
            make_test_case('vsuxei16_v_u8mf2', vl=8),
            make_test_case('vsuxei16_v_u8mf2', vl=7),
            make_test_case('vsuxei16_v_u8m1', vl=16),
            make_test_case('vsuxei16_v_u8m1', vl=15),
            make_test_case('vsuxei16_v_u8m2', vl=32),
            make_test_case('vsuxei16_v_u8m2', vl=31),
            make_test_case('vsuxei16_v_u8m4', vl=64),
            make_test_case('vsuxei16_v_u8m4', vl=63),
            # Ordered
            make_test_case('vsoxei16_v_u8mf2', vl=4),
            make_test_case('vsoxei16_v_u8mf2', vl=3),
            make_test_case('vsoxei16_v_u8mf2', vl=8),
            make_test_case('vsoxei16_v_u8mf2', vl=7),
            make_test_case('vsoxei16_v_u8m1', vl=16),
            make_test_case('vsoxei16_v_u8m1', vl=15),
            make_test_case('vsoxei16_v_u8m2', vl=32),
            make_test_case('vsoxei16_v_u8m2', vl=31),
            make_test_case('vsoxei16_v_u8m4', vl=64),
            make_test_case('vsoxei16_v_u8m4', vl=63),
        ],
        data_dtype=np.uint8,
        index_dtype=np.uint16,
    )


@cocotb.test()
async def store8_index32(dut):
    """Test vs*xei32_v_u8 usage accessible from intrinsics."""

    def make_test_case(impl: str, vl: int):
        return {
            'impl': impl,
            'vl': vl,
            'segments': 1,
            'out_size': 30000,
        }

    await vector_store_segmented_indexed(
        dut=dut,
        elf_name='store8_index32.elf',
        cases=[
            # Unordered
            make_test_case('vsuxei32_v_u8mf4', vl=4),
            make_test_case('vsuxei32_v_u8mf4', vl=3),
            make_test_case('vsuxei32_v_u8mf2', vl=8),
            make_test_case('vsuxei32_v_u8mf2', vl=7),
            make_test_case('vsuxei32_v_u8m1', vl=16),
            make_test_case('vsuxei32_v_u8m1', vl=15),
            make_test_case('vsuxei32_v_u8m2', vl=32),
            make_test_case('vsuxei32_v_u8m2', vl=31),
            # Ordered
            make_test_case('vsoxei32_v_u8mf2', vl=4),
            make_test_case('vsoxei32_v_u8mf2', vl=3),
            make_test_case('vsoxei32_v_u8mf2', vl=8),
            make_test_case('vsoxei32_v_u8mf2', vl=7),
            make_test_case('vsoxei32_v_u8m1', vl=16),
            make_test_case('vsoxei32_v_u8m1', vl=15),
            make_test_case('vsoxei32_v_u8m2', vl=32),
            make_test_case('vsoxei32_v_u8m2', vl=31),
        ],
        data_dtype=np.uint8,
        index_dtype=np.uint32,
    )


@cocotb.test()
async def store16_index8(dut):
    """Test vs*xei8_v_u16 usage accessible from intrinsics."""

    def make_test_case(impl: str, vl: int):
        return {
            'impl': impl,
            'vl': vl,
            'segments': 1,
            'out_size': 256,
        }

    await vector_store_segmented_indexed(
        dut=dut,
        elf_name='store16_index8.elf',
        cases=[
            # Unordered
            make_test_case('vsuxei8_v_u16mf2', vl=4),
            make_test_case('vsuxei8_v_u16mf2', vl=3),
            make_test_case('vsuxei8_v_u16m1', vl=8),
            make_test_case('vsuxei8_v_u16m1', vl=7),
            make_test_case('vsuxei8_v_u16m2', vl=16),
            make_test_case('vsuxei8_v_u16m2', vl=15),
            make_test_case('vsuxei8_v_u16m4', vl=32),
            make_test_case('vsuxei8_v_u16m4', vl=31),
            make_test_case('vsuxei8_v_u16m8', vl=64),
            make_test_case('vsuxei8_v_u16m8', vl=63),
            # Ordered
            make_test_case('vsoxei8_v_u16mf2', vl=4),
            make_test_case('vsoxei8_v_u16mf2', vl=3),
            make_test_case('vsoxei8_v_u16m1', vl=8),
            make_test_case('vsoxei8_v_u16m1', vl=7),
            make_test_case('vsoxei8_v_u16m2', vl=16),
            make_test_case('vsoxei8_v_u16m2', vl=15),
            make_test_case('vsoxei8_v_u16m4', vl=32),
            make_test_case('vsoxei8_v_u16m4', vl=31),
            make_test_case('vsoxei8_v_u16m8', vl=64),
            make_test_case('vsoxei8_v_u16m8', vl=63),
        ],
        data_dtype=np.uint16,
        index_dtype=np.uint8,
    )


@cocotb.test()
async def store16_index16(dut):
    """Test vs*xei16_v_u16 usage accessible from intrinsics."""

    def make_test_case(impl: str, vl: int):
        return {
            'impl': impl,
            'vl': vl,
            'segments': 1,
            'out_size': 15000,
        }

    await vector_store_segmented_indexed(
        dut=dut,
        elf_name='store16_index16.elf',
        cases=[
            # Unordered
            make_test_case('vsuxei16_v_u16mf2', vl=4),
            make_test_case('vsuxei16_v_u16mf2', vl=3),
            make_test_case('vsuxei16_v_u16m1', vl=8),
            make_test_case('vsuxei16_v_u16m1', vl=7),
            make_test_case('vsuxei16_v_u16m2', vl=16),
            make_test_case('vsuxei16_v_u16m2', vl=15),
            make_test_case('vsuxei16_v_u16m4', vl=32),
            make_test_case('vsuxei16_v_u16m4', vl=31),
            make_test_case('vsuxei16_v_u16m8', vl=64),
            make_test_case('vsuxei16_v_u16m8', vl=63),
            # Ordered
            make_test_case('vsoxei16_v_u16mf2', vl=4),
            make_test_case('vsoxei16_v_u16mf2', vl=3),
            make_test_case('vsoxei16_v_u16m1', vl=8),
            make_test_case('vsoxei16_v_u16m1', vl=7),
            make_test_case('vsoxei16_v_u16m2', vl=16),
            make_test_case('vsoxei16_v_u16m2', vl=15),
            make_test_case('vsoxei16_v_u16m4', vl=32),
            make_test_case('vsoxei16_v_u16m4', vl=31),
            make_test_case('vsoxei16_v_u16m8', vl=64),
            make_test_case('vsoxei16_v_u16m8', vl=63),
        ],
        data_dtype=np.uint16,
        index_dtype=np.uint16,
    )


@cocotb.test()
async def store16_index32(dut):
    """Test vs*xei32_v_u16 usage accessible from intrinsics."""

    def make_test_case(impl: str, vl: int):
        return {
            'impl': impl,
            'vl': vl,
            'segments': 1,
            'out_size': 15000,
        }

    await vector_store_segmented_indexed(
        dut=dut,
        elf_name='store16_index32.elf',
        cases=[
            # Unordered
            make_test_case('vsuxei32_v_u16mf2', vl=4),
            make_test_case('vsuxei32_v_u16mf2', vl=3),
            make_test_case('vsuxei32_v_u16m1', vl=8),
            make_test_case('vsuxei32_v_u16m1', vl=7),
            make_test_case('vsuxei32_v_u16m2', vl=16),
            make_test_case('vsuxei32_v_u16m2', vl=15),
            make_test_case('vsuxei32_v_u16m4', vl=32),
            make_test_case('vsuxei32_v_u16m4', vl=31),
            # Ordered
            make_test_case('vsoxei32_v_u16mf2', vl=4),
            make_test_case('vsoxei32_v_u16mf2', vl=3),
            make_test_case('vsoxei32_v_u16m1', vl=8),
            make_test_case('vsoxei32_v_u16m1', vl=7),
            make_test_case('vsoxei32_v_u16m2', vl=16),
            make_test_case('vsoxei32_v_u16m2', vl=15),
            make_test_case('vsoxei32_v_u16m4', vl=32),
            make_test_case('vsoxei32_v_u16m4', vl=31),
        ],
        data_dtype=np.uint16,
        index_dtype=np.uint32,
    )


@cocotb.test()
async def store32_index8(dut):
    """Test vs*xei8_v_u32 usage accessible from intrinsics."""

    def make_test_case(impl: str, vl: int):
        return {
            'impl': impl,
            'vl': vl,
            'segments': 1,
            'out_size': 512,
        }

    await vector_store_segmented_indexed(
        dut=dut,
        elf_name='store32_index8.elf',
        cases=[
            # Unordered
            make_test_case('vsuxei8_v_u32m1', vl=4),
            make_test_case('vsuxei8_v_u32m1', vl=3),
            make_test_case('vsuxei8_v_u32m2', vl=8),
            make_test_case('vsuxei8_v_u32m2', vl=7),
            make_test_case('vsuxei8_v_u32m4', vl=16),
            make_test_case('vsuxei8_v_u32m4', vl=15),
            make_test_case('vsuxei8_v_u32m8', vl=32),
            make_test_case('vsuxei8_v_u32m8', vl=31),
            # Ordered
            make_test_case('vsoxei8_v_u32m1', vl=4),
            make_test_case('vsoxei8_v_u32m1', vl=3),
            make_test_case('vsoxei8_v_u32m2', vl=8),
            make_test_case('vsoxei8_v_u32m2', vl=7),
            make_test_case('vsoxei8_v_u32m4', vl=16),
            make_test_case('vsoxei8_v_u32m4', vl=15),
            make_test_case('vsoxei8_v_u32m8', vl=32),
            make_test_case('vsoxei8_v_u32m8', vl=31),
        ],
        data_dtype=np.uint32,
        index_dtype=np.uint8,
    )


@cocotb.test()
async def store32_index16(dut):
    """Test vs*xei16_v_u32 usage accessible from intrinsics."""

    def make_test_case(impl: str, vl: int):
        return {
            'impl': impl,
            'vl': vl,
            'segments': 1,
            'out_size': 7000,
        }

    await vector_store_segmented_indexed(
        dut=dut,
        elf_name='store32_index16.elf',
        cases=[
            # Unordered
            make_test_case('vsuxei16_v_u32m1', vl=4),
            make_test_case('vsuxei16_v_u32m1', vl=3),
            make_test_case('vsuxei16_v_u32m2', vl=8),
            make_test_case('vsuxei16_v_u32m2', vl=7),
            make_test_case('vsuxei16_v_u32m4', vl=16),
            make_test_case('vsuxei16_v_u32m4', vl=15),
            make_test_case('vsuxei16_v_u32m8', vl=32),
            make_test_case('vsuxei16_v_u32m8', vl=31),
            # Ordered
            make_test_case('vsoxei16_v_u32m1', vl=4),
            make_test_case('vsoxei16_v_u32m1', vl=3),
            make_test_case('vsoxei16_v_u32m2', vl=8),
            make_test_case('vsoxei16_v_u32m2', vl=7),
            make_test_case('vsoxei16_v_u32m4', vl=16),
            make_test_case('vsoxei16_v_u32m4', vl=15),
            make_test_case('vsoxei16_v_u32m8', vl=32),
            make_test_case('vsoxei16_v_u32m8', vl=31),
        ],
        data_dtype=np.uint32,
        index_dtype=np.uint16,
    )


@cocotb.test()
async def store32_index32(dut):
    """Test vs*xei32_v_u32 usage accessible from intrinsics."""

    def make_test_case(impl: str, vl: int):
        return {
            'impl': impl,
            'vl': vl,
            'segments': 1,
            'out_size': 7000,
        }

    await vector_store_segmented_indexed(
        dut=dut,
        elf_name='store32_index32.elf',
        cases=[
            # Unordered
            make_test_case('vsuxei32_v_u32m1', vl=4),
            make_test_case('vsuxei32_v_u32m1', vl=3),
            make_test_case('vsuxei32_v_u32m2', vl=8),
            make_test_case('vsuxei32_v_u32m2', vl=7),
            make_test_case('vsuxei32_v_u32m4', vl=16),
            make_test_case('vsuxei32_v_u32m4', vl=15),
            make_test_case('vsuxei32_v_u32m8', vl=32),
            make_test_case('vsuxei32_v_u32m8', vl=31),
            # Ordered
            make_test_case('vsoxei32_v_u32m1', vl=4),
            make_test_case('vsoxei32_v_u32m1', vl=3),
            make_test_case('vsoxei32_v_u32m2', vl=8),
            make_test_case('vsoxei32_v_u32m2', vl=7),
            make_test_case('vsoxei32_v_u32m4', vl=16),
            make_test_case('vsoxei32_v_u32m4', vl=15),
            make_test_case('vsoxei32_v_u32m8', vl=32),
            make_test_case('vsoxei32_v_u32m8', vl=31),
        ],
        data_dtype=np.uint32,
        index_dtype=np.uint32,
    )


@cocotb.test()
async def store8_seg_unit(dut):
    """Test vsseg*e8 usage accessible from intrinsics."""

    def make_test_case(impl: str, vl: int, n_segs: int):
        return {
            'impl':
            impl,
            'vl':
            vl,
            'in_size':
            vl * n_segs * 2,
            'out_size':
            vl * n_segs * 2,
            'pattern':
            [seg * vl + elem for elem in range(vl) for seg in range(n_segs)]
        }

    await vector_load_store_v2(
        dut=dut,
        elf_name='store8_seg_unit.elf',
        cases=[
            # Seg 2
            make_test_case('vsseg2e8_v_u8mf4x2', vl=4, n_segs=2),
            make_test_case('vsseg2e8_v_u8mf4x2', vl=3, n_segs=2),
            make_test_case('vsseg2e8_v_u8mf4x2', vl=1, n_segs=2),
            make_test_case('vsseg2e8_v_u8mf2x2', vl=8, n_segs=2),
            make_test_case('vsseg2e8_v_u8mf2x2', vl=7, n_segs=2),
            make_test_case('vsseg2e8_v_u8mf2x2', vl=1, n_segs=2),
            make_test_case('vsseg2e8_v_u8m1x2', vl=16, n_segs=2),
            make_test_case('vsseg2e8_v_u8m1x2', vl=15, n_segs=2),
            make_test_case('vsseg2e8_v_u8m1x2', vl=1, n_segs=2),
            make_test_case('vsseg2e8_v_u8m2x2', vl=32, n_segs=2),
            make_test_case('vsseg2e8_v_u8m2x2', vl=31, n_segs=2),
            make_test_case('vsseg2e8_v_u8m2x2', vl=1, n_segs=2),
            make_test_case('vsseg2e8_v_u8m4x2', vl=64, n_segs=2),
            make_test_case('vsseg2e8_v_u8m4x2', vl=63, n_segs=2),
            make_test_case('vsseg2e8_v_u8m4x2', vl=1, n_segs=2),
            # Seg 3
            make_test_case('vsseg3e8_v_u8mf4x3', vl=4, n_segs=3),
            make_test_case('vsseg3e8_v_u8mf4x3', vl=3, n_segs=3),
            make_test_case('vsseg3e8_v_u8mf4x3', vl=1, n_segs=3),
            make_test_case('vsseg3e8_v_u8mf2x3', vl=8, n_segs=3),
            make_test_case('vsseg3e8_v_u8mf2x3', vl=7, n_segs=3),
            make_test_case('vsseg3e8_v_u8mf2x3', vl=1, n_segs=3),
            make_test_case('vsseg3e8_v_u8m1x3', vl=16, n_segs=3),
            make_test_case('vsseg3e8_v_u8m1x3', vl=15, n_segs=3),
            make_test_case('vsseg3e8_v_u8m1x3', vl=1, n_segs=3),
            make_test_case('vsseg3e8_v_u8m2x3', vl=32, n_segs=3),
            make_test_case('vsseg3e8_v_u8m2x3', vl=31, n_segs=3),
            make_test_case('vsseg3e8_v_u8m2x3', vl=1, n_segs=3),
            # Seg 4
            make_test_case('vsseg4e8_v_u8mf4x4', vl=4, n_segs=4),
            make_test_case('vsseg4e8_v_u8mf4x4', vl=3, n_segs=4),
            make_test_case('vsseg4e8_v_u8mf4x4', vl=1, n_segs=4),
            make_test_case('vsseg4e8_v_u8mf2x4', vl=8, n_segs=4),
            make_test_case('vsseg4e8_v_u8mf2x4', vl=7, n_segs=4),
            make_test_case('vsseg4e8_v_u8mf2x4', vl=1, n_segs=4),
            make_test_case('vsseg4e8_v_u8m1x4', vl=16, n_segs=4),
            make_test_case('vsseg4e8_v_u8m1x4', vl=15, n_segs=4),
            make_test_case('vsseg4e8_v_u8m1x4', vl=1, n_segs=4),
            make_test_case('vsseg4e8_v_u8m2x4', vl=32, n_segs=4),
            make_test_case('vsseg4e8_v_u8m2x4', vl=31, n_segs=4),
            make_test_case('vsseg4e8_v_u8m2x4', vl=1, n_segs=4),
            # Seg 5
            make_test_case('vsseg5e8_v_u8mf4x5', vl=4, n_segs=5),
            make_test_case('vsseg5e8_v_u8mf4x5', vl=3, n_segs=5),
            make_test_case('vsseg5e8_v_u8mf4x5', vl=1, n_segs=5),
            make_test_case('vsseg5e8_v_u8mf2x5', vl=8, n_segs=5),
            make_test_case('vsseg5e8_v_u8mf2x5', vl=7, n_segs=5),
            make_test_case('vsseg5e8_v_u8mf2x5', vl=1, n_segs=5),
            make_test_case('vsseg5e8_v_u8m1x5', vl=16, n_segs=5),
            make_test_case('vsseg5e8_v_u8m1x5', vl=15, n_segs=5),
            make_test_case('vsseg5e8_v_u8m1x5', vl=1, n_segs=5),
            # Seg 6
            make_test_case('vsseg6e8_v_u8mf4x6', vl=4, n_segs=6),
            make_test_case('vsseg6e8_v_u8mf4x6', vl=3, n_segs=6),
            make_test_case('vsseg6e8_v_u8mf4x6', vl=1, n_segs=6),
            make_test_case('vsseg6e8_v_u8mf2x6', vl=8, n_segs=6),
            make_test_case('vsseg6e8_v_u8mf2x6', vl=7, n_segs=6),
            make_test_case('vsseg6e8_v_u8mf2x6', vl=1, n_segs=6),
            make_test_case('vsseg6e8_v_u8m1x6', vl=16, n_segs=6),
            make_test_case('vsseg6e8_v_u8m1x6', vl=15, n_segs=6),
            make_test_case('vsseg6e8_v_u8m1x6', vl=1, n_segs=6),
            # Seg 7
            make_test_case('vsseg7e8_v_u8mf4x7', vl=4, n_segs=7),
            make_test_case('vsseg7e8_v_u8mf4x7', vl=3, n_segs=7),
            make_test_case('vsseg7e8_v_u8mf4x7', vl=1, n_segs=7),
            make_test_case('vsseg7e8_v_u8mf2x7', vl=8, n_segs=7),
            make_test_case('vsseg7e8_v_u8mf2x7', vl=7, n_segs=7),
            make_test_case('vsseg7e8_v_u8mf2x7', vl=1, n_segs=7),
            make_test_case('vsseg7e8_v_u8m1x7', vl=16, n_segs=7),
            make_test_case('vsseg7e8_v_u8m1x7', vl=15, n_segs=7),
            make_test_case('vsseg7e8_v_u8m1x7', vl=1, n_segs=7),
            # Seg 8
            make_test_case('vsseg8e8_v_u8mf4x8', vl=4, n_segs=8),
            make_test_case('vsseg8e8_v_u8mf4x8', vl=3, n_segs=8),
            make_test_case('vsseg8e8_v_u8mf4x8', vl=1, n_segs=8),
            make_test_case('vsseg8e8_v_u8mf2x8', vl=8, n_segs=8),
            make_test_case('vsseg8e8_v_u8mf2x8', vl=7, n_segs=8),
            make_test_case('vsseg8e8_v_u8mf2x8', vl=1, n_segs=8),
            make_test_case('vsseg8e8_v_u8m1x8', vl=16, n_segs=8),
            make_test_case('vsseg8e8_v_u8m1x8', vl=15, n_segs=8),
            make_test_case('vsseg8e8_v_u8m1x8', vl=1, n_segs=8),
        ],
        dtype=np.uint8,
    )


@cocotb.test()
async def store16_seg_unit(dut):
    """Test vsseg*e16 usage accessible from intrinsics."""

    def make_test_case(impl: str, vl: int, n_segs: int):
        return {
            'impl':
            impl,
            'vl':
            vl,
            'in_size':
            vl * n_segs * 2,
            'out_size':
            vl * n_segs * 2,
            'pattern':
            [seg * vl + elem for elem in range(vl) for seg in range(n_segs)]
        }

    await vector_load_store_v2(
        dut=dut,
        elf_name='store16_seg_unit.elf',
        cases=[
            # Seg 2
            make_test_case('vsseg2e16_v_u16mf2x2', vl=4, n_segs=2),
            make_test_case('vsseg2e16_v_u16mf2x2', vl=3, n_segs=2),
            make_test_case('vsseg2e16_v_u16mf2x2', vl=1, n_segs=2),
            make_test_case('vsseg2e16_v_u16m1x2', vl=8, n_segs=2),
            make_test_case('vsseg2e16_v_u16m1x2', vl=7, n_segs=2),
            make_test_case('vsseg2e16_v_u16m1x2', vl=1, n_segs=2),
            make_test_case('vsseg2e16_v_u16m2x2', vl=16, n_segs=2),
            make_test_case('vsseg2e16_v_u16m2x2', vl=15, n_segs=2),
            make_test_case('vsseg2e16_v_u16m2x2', vl=1, n_segs=2),
            make_test_case('vsseg2e16_v_u16m4x2', vl=32, n_segs=2),
            make_test_case('vsseg2e16_v_u16m4x2', vl=31, n_segs=2),
            make_test_case('vsseg2e16_v_u16m4x2', vl=1, n_segs=2),
            # Seg 3
            make_test_case('vsseg3e16_v_u16mf2x3', vl=4, n_segs=3),
            make_test_case('vsseg3e16_v_u16mf2x3', vl=3, n_segs=3),
            make_test_case('vsseg3e16_v_u16mf2x3', vl=1, n_segs=3),
            make_test_case('vsseg3e16_v_u16m1x3', vl=8, n_segs=3),
            make_test_case('vsseg3e16_v_u16m1x3', vl=7, n_segs=3),
            make_test_case('vsseg3e16_v_u16m1x3', vl=1, n_segs=3),
            make_test_case('vsseg3e16_v_u16m2x3', vl=16, n_segs=3),
            make_test_case('vsseg3e16_v_u16m2x3', vl=15, n_segs=3),
            make_test_case('vsseg3e16_v_u16m2x3', vl=1, n_segs=3),
            # Seg 4
            make_test_case('vsseg4e16_v_u16mf2x4', vl=4, n_segs=4),
            make_test_case('vsseg4e16_v_u16mf2x4', vl=3, n_segs=4),
            make_test_case('vsseg4e16_v_u16mf2x4', vl=1, n_segs=4),
            make_test_case('vsseg4e16_v_u16m1x4', vl=8, n_segs=4),
            make_test_case('vsseg4e16_v_u16m1x4', vl=7, n_segs=4),
            make_test_case('vsseg4e16_v_u16m1x4', vl=1, n_segs=4),
            make_test_case('vsseg4e16_v_u16m2x4', vl=16, n_segs=4),
            make_test_case('vsseg4e16_v_u16m2x4', vl=15, n_segs=4),
            make_test_case('vsseg4e16_v_u16m2x4', vl=1, n_segs=4),
            # Seg 5
            make_test_case('vsseg5e16_v_u16mf2x5', vl=4, n_segs=5),
            make_test_case('vsseg5e16_v_u16mf2x5', vl=3, n_segs=5),
            make_test_case('vsseg5e16_v_u16mf2x5', vl=1, n_segs=5),
            make_test_case('vsseg5e16_v_u16m1x5', vl=8, n_segs=5),
            make_test_case('vsseg5e16_v_u16m1x5', vl=7, n_segs=5),
            make_test_case('vsseg5e16_v_u16m1x5', vl=1, n_segs=5),
            # Seg 6
            make_test_case('vsseg6e16_v_u16mf2x6', vl=4, n_segs=6),
            make_test_case('vsseg6e16_v_u16mf2x6', vl=3, n_segs=6),
            make_test_case('vsseg6e16_v_u16mf2x6', vl=1, n_segs=6),
            make_test_case('vsseg6e16_v_u16m1x6', vl=8, n_segs=6),
            make_test_case('vsseg6e16_v_u16m1x6', vl=7, n_segs=6),
            make_test_case('vsseg6e16_v_u16m1x6', vl=1, n_segs=6),
            # Seg 7
            make_test_case('vsseg7e16_v_u16mf2x7', vl=4, n_segs=7),
            make_test_case('vsseg7e16_v_u16mf2x7', vl=3, n_segs=7),
            make_test_case('vsseg7e16_v_u16mf2x7', vl=1, n_segs=7),
            make_test_case('vsseg7e16_v_u16m1x7', vl=8, n_segs=7),
            make_test_case('vsseg7e16_v_u16m1x7', vl=7, n_segs=7),
            make_test_case('vsseg7e16_v_u16m1x7', vl=1, n_segs=7),
            # Seg 8
            make_test_case('vsseg8e16_v_u16mf2x8', vl=4, n_segs=8),
            make_test_case('vsseg8e16_v_u16mf2x8', vl=3, n_segs=8),
            make_test_case('vsseg8e16_v_u16mf2x8', vl=1, n_segs=8),
            make_test_case('vsseg8e16_v_u16m1x8', vl=8, n_segs=8),
            make_test_case('vsseg8e16_v_u16m1x8', vl=7, n_segs=8),
            make_test_case('vsseg8e16_v_u16m1x8', vl=1, n_segs=8),
        ],
        dtype=np.uint16,
    )


@cocotb.test()
async def store32_seg_unit(dut):
    """Test vsseg*e32 usage accessible from intrinsics."""

    def make_test_case(impl: str, vl: int, n_segs: int):
        return {
            'impl':
            impl,
            'vl':
            vl,
            'in_size':
            vl * n_segs * 2,
            'out_size':
            vl * n_segs * 2,
            'pattern':
            [seg * vl + elem for elem in range(vl) for seg in range(n_segs)]
        }

    await vector_load_store_v2(
        dut=dut,
        elf_name='store32_seg_unit.elf',
        cases=[
            # Seg 2
            make_test_case('vsseg2e32_v_u32m1x2', vl=4, n_segs=2),
            make_test_case('vsseg2e32_v_u32m1x2', vl=3, n_segs=2),
            make_test_case('vsseg2e32_v_u32m1x2', vl=1, n_segs=2),
            make_test_case('vsseg2e32_v_u32m2x2', vl=8, n_segs=2),
            make_test_case('vsseg2e32_v_u32m2x2', vl=7, n_segs=2),
            make_test_case('vsseg2e32_v_u32m2x2', vl=1, n_segs=2),
            make_test_case('vsseg2e32_v_u32m4x2', vl=16, n_segs=2),
            make_test_case('vsseg2e32_v_u32m4x2', vl=15, n_segs=2),
            make_test_case('vsseg2e32_v_u32m4x2', vl=1, n_segs=2),
            # Seg 3
            make_test_case('vsseg3e32_v_u32m1x3', vl=4, n_segs=3),
            make_test_case('vsseg3e32_v_u32m1x3', vl=3, n_segs=3),
            make_test_case('vsseg3e32_v_u32m1x3', vl=1, n_segs=3),
            make_test_case('vsseg3e32_v_u32m2x3', vl=8, n_segs=3),
            make_test_case('vsseg3e32_v_u32m2x3', vl=7, n_segs=3),
            make_test_case('vsseg3e32_v_u32m2x3', vl=1, n_segs=3),
            # Seg 4
            make_test_case('vsseg4e32_v_u32m1x4', vl=4, n_segs=4),
            make_test_case('vsseg4e32_v_u32m1x4', vl=3, n_segs=4),
            make_test_case('vsseg4e32_v_u32m1x4', vl=1, n_segs=4),
            make_test_case('vsseg4e32_v_u32m2x4', vl=8, n_segs=4),
            make_test_case('vsseg4e32_v_u32m2x4', vl=7, n_segs=4),
            make_test_case('vsseg4e32_v_u32m2x4', vl=1, n_segs=4),
            # Seg 5
            make_test_case('vsseg5e32_v_u32m1x5', vl=4, n_segs=5),
            make_test_case('vsseg5e32_v_u32m1x5', vl=3, n_segs=5),
            make_test_case('vsseg5e32_v_u32m1x5', vl=1, n_segs=5),
            # Seg 6
            make_test_case('vsseg6e32_v_u32m1x6', vl=4, n_segs=6),
            make_test_case('vsseg6e32_v_u32m1x6', vl=3, n_segs=6),
            make_test_case('vsseg6e32_v_u32m1x6', vl=1, n_segs=6),
            # Seg 7
            make_test_case('vsseg7e32_v_u32m1x7', vl=4, n_segs=7),
            make_test_case('vsseg7e32_v_u32m1x7', vl=3, n_segs=7),
            make_test_case('vsseg7e32_v_u32m1x7', vl=1, n_segs=7),
            # Seg 8
            make_test_case('vsseg8e32_v_u32m1x8', vl=4, n_segs=8),
            make_test_case('vsseg8e32_v_u32m1x8', vl=3, n_segs=8),
            make_test_case('vsseg8e32_v_u32m1x8', vl=1, n_segs=8),
        ],
        dtype=np.uint32,
    )


async def _setup_lsu_fault_fixture(dut):
    fixture = await Fixture.Create(dut)
    r = runfiles.Create()
    await fixture.load_elf_and_lookup_symbols(
        r.Rlocation(
            'coralnpu_hw/tests/cocotb/rvv/load_store/lsu_fault_cases.elf'
        ),
        [
            '__data_start__',
            'buffer',
            'in_ptr',
            'out_ptr',
            'vl',
            'test_fn',
            'fault_count',
            'fault_mcause',
            'fault_mtval',
            'fault_mepc',
            'fault_vstart',
            'faulting_insn_scalar',
            'faulting_insn_unit',
            'faulting_insn_neg_stride',
            'faulting_insn_indexed',
            'faulting_insn_seg3',
            'faulting_insn_seg5',
            'faulting_insn_load',
            'faulting_insn_scalar_mixed',
            'faulting_insn_scalar_scalar',
            'run_scalar_fault_preserves_vstart',
            'run_unit_stride_fault_rs_flush',
            'run_negative_stride_mid_vstart_fault',
            'run_indexed_mid_vstart_fault',
            'run_seg3_negative_stride_mid_vstart_fault',
            'run_seg5_negative_stride_mid_vstart_fault',
            'run_vector_load_fault_rs_flush',
            'run_scalar_mixed_fault_rs_flush',
            'run_scalar_to_scalar_fault_rs_flush',
        ],
    )
    return fixture


async def _run_and_verify_lsu_fault(
    fixture,
    test_fn_symbol: str,
    faulting_insn_symbol: str,
    expected_mcause: int,
    expected_mtval: int,
    expected_vstart: int = 0,
    vl: int | None = None,
    num_input_bytes: int | None = None,
):
    """Helper to run a fault test function and verify architectural fault state."""
    if vl is not None:
        count = num_input_bytes if num_input_bytes is not None else vl
        target_in_addr = fixture.symbols['buffer']
        await fixture.core_mini_axi.write(
            target_in_addr, np.random.randint(0, 255, count, dtype=np.uint8)
        )
        await fixture.write(
            'in_ptr', np.array([target_in_addr], dtype=np.uint32)
        )
        await fixture.write('vl', np.array([vl], dtype=np.uint32))

    await fixture.write_ptr('test_fn', test_fn_symbol)
    await fixture.run_to_halt()

    fault_count = (await fixture.read_word('fault_count')).view(np.int32)[0]
    assert fault_count == 1, f"Expected exactly 1 fault, got {fault_count}"

    fault_mcause = (await fixture.read_word('fault_mcause')).view(np.uint32)[0]
    assert fault_mcause == expected_mcause, (
        f"Expected mcause={expected_mcause}, got {fault_mcause}"
    )

    fault_mepc = (await fixture.read_word('fault_mepc')).view(np.uint32)[0]
    expected_pc = fixture.symbols[faulting_insn_symbol]
    assert fault_mepc == expected_pc, (
        f"Expected PC {hex(expected_pc)}, got {hex(fault_mepc)}"
    )

    fault_mtval = (await fixture.read_word('fault_mtval')).view(np.uint32)[0]
    assert fault_mtval == expected_mtval, (
        f"Expected mtval {hex(expected_mtval)}, got {hex(fault_mtval)}"
    )

    fault_vstart = (await fixture.read_word('fault_vstart')).view(np.uint32)[0]
    assert fault_vstart == expected_vstart, (
        f"Expected vstart={expected_vstart}, got {fault_vstart}"
    )


@cocotb.test()
async def lsu_fault_scalar_preserves_vstart(dut):
    """Testbench to verify scalar memory fault preserves non-zero vstart."""
    fixture = await _setup_lsu_fault_fixture(dut)
    await _run_and_verify_lsu_fault(
        fixture,
        test_fn_symbol='run_scalar_fault_preserves_vstart',
        faulting_insn_symbol='faulting_insn_scalar',
        expected_mcause=7,
        expected_mtval=fixture.symbols['__data_start__'] - 4,
        expected_vstart=3,
    )


@cocotb.test()
async def lsu_fault_unit_stride_rs_flush(dut):
    """Testbench to verify unit-stride vector store fault purges subsequent stores in RS (Vector -> Vector)."""
    fixture = await _setup_lsu_fault_fixture(dut)
    await _run_and_verify_lsu_fault(
        fixture,
        test_fn_symbol='run_unit_stride_fault_rs_flush',
        faulting_insn_symbol='faulting_insn_unit',
        expected_mcause=7,
        expected_mtval=fixture.symbols['__data_start__'] - 4,
        expected_vstart=0,
    )


@cocotb.test()
async def lsu_fault_negative_stride_mid_vstart(dut):
    """Testbench to verify negative-stride vector store crossing boundary calculates mid-vector vstart."""
    fixture = await _setup_lsu_fault_fixture(dut)
    await _run_and_verify_lsu_fault(
        fixture,
        test_fn_symbol='run_negative_stride_mid_vstart_fault',
        faulting_insn_symbol='faulting_insn_neg_stride',
        expected_mcause=7,
        expected_mtval=(fixture.symbols['__data_start__'] - 4) & ~0xF,
        expected_vstart=3,
        vl=8,
    )


@cocotb.test()
async def lsu_fault_indexed_mid_vstart(dut):
    """Testbench to verify indexed vector store calculates mid-vector vstart."""
    fixture = await _setup_lsu_fault_fixture(dut)
    await _run_and_verify_lsu_fault(
        fixture,
        test_fn_symbol='run_indexed_mid_vstart_fault',
        faulting_insn_symbol='faulting_insn_indexed',
        expected_mcause=7,
        expected_mtval=0xA0000000,
        expected_vstart=5,
        vl=8,
        num_input_bytes=32,
    )


@cocotb.test()
async def lsu_fault_seg3_negative_stride_mid_vstart(dut):
    """Testbench to verify segment store with NF=3 calculates mid-vector vstart via NF=3 division."""
    fixture = await _setup_lsu_fault_fixture(dut)
    await _run_and_verify_lsu_fault(
        fixture,
        test_fn_symbol='run_seg3_negative_stride_mid_vstart_fault',
        faulting_insn_symbol='faulting_insn_seg3',
        expected_mcause=7,
        expected_mtval=(fixture.symbols['__data_start__'] - 6) & ~0xF,
        expected_vstart=4,
        vl=8,
    )


@cocotb.test()
async def lsu_fault_seg5_negative_stride_mid_vstart(dut):
    """Testbench to verify segment store with NF=5 calculates mid-vector vstart via NF=5 division."""
    fixture = await _setup_lsu_fault_fixture(dut)
    await _run_and_verify_lsu_fault(
        fixture,
        test_fn_symbol='run_seg5_negative_stride_mid_vstart_fault',
        faulting_insn_symbol='faulting_insn_seg5',
        expected_mcause=7,
        expected_mtval=(fixture.symbols['__data_start__'] - 10) & ~0xF,
        expected_vstart=3,
        vl=8,
    )


@cocotb.test()
async def lsu_fault_vector_load_rs_flush(dut):
    """Testbench to verify vector load fault purges follow-on scalar store in RS (Vector -> Scalar)."""
    fixture = await _setup_lsu_fault_fixture(dut)
    await _run_and_verify_lsu_fault(
        fixture,
        test_fn_symbol='run_vector_load_fault_rs_flush',
        faulting_insn_symbol='faulting_insn_load',
        expected_mcause=5,
        expected_mtval=0xA0000000,
        expected_vstart=0,
    )


@cocotb.test()
async def lsu_fault_scalar_mixed_rs_flush(dut):
    """Testbench to verify scalar store fault purges follow-on vector store in RS (Scalar -> Vector)."""
    fixture = await _setup_lsu_fault_fixture(dut)
    await _run_and_verify_lsu_fault(
        fixture,
        test_fn_symbol='run_scalar_mixed_fault_rs_flush',
        faulting_insn_symbol='faulting_insn_scalar_mixed',
        expected_mcause=7,
        expected_mtval=fixture.symbols['__data_start__'] - 4,
        expected_vstart=0,
    )


@cocotb.test()
async def lsu_fault_scalar_to_scalar_rs_flush(dut):
    """Testbench to verify scalar store fault purges follow-on scalar stores in RS (Scalar -> Scalar)."""
    fixture = await _setup_lsu_fault_fixture(dut)
    await _run_and_verify_lsu_fault(
        fixture,
        test_fn_symbol='run_scalar_to_scalar_fault_rs_flush',
        faulting_insn_symbol='faulting_insn_scalar_scalar',
        expected_mcause=7,
        expected_mtval=fixture.symbols['__data_start__'] - 4,
        expected_vstart=0,
    )


@cocotb.test()
async def load_store8_test(dut):
    """Testbench to test RVV load."""
    fixture = await Fixture.Create(dut)
    r = runfiles.Create()
    await fixture.load_elf_and_lookup_symbols(
        r.Rlocation(
            'coralnpu_hw/tests/cocotb/rvv/load_store/load_store8_test.elf'
        ),
        ['buffer', 'in_ptr', 'out_ptr', 'vl'],
    )

    vl = 16
    input_data = np.random.randint(0, 255, vl, dtype=np.uint8)
    target_in_addr = fixture.symbols['buffer'] + 16
    target_out_addr = fixture.symbols['buffer'] + 64

    await fixture.core_mini_axi.write(target_in_addr, input_data)
    await fixture.write('in_ptr', np.array([target_in_addr], dtype=np.uint32))
    await fixture.write(
        'out_ptr', np.array([target_out_addr], dtype=np.uint32)
    )
    await fixture.write('vl', np.array([vl], dtype=np.uint32))

    await fixture.run_to_halt()

    routputs = (await fixture.core_mini_axi.read(target_out_addr,
                                                 vl)).view(np.uint8)
    assert (input_data == routputs).all()


@cocotb.test()
async def load_unit_all_vtypes_test(dut):
    """Testbench to test RVV Unit/segmented loads, with all vtypes."""
    fixture = await Fixture.Create(dut)
    r = runfiles.Create()
    functions = [
        ("test_vle8", np.uint8, 1),
        ("test_vlseg2e8", np.uint8, 2),
        ("test_vlseg3e8", np.uint8, 3),
        ("test_vlseg4e8", np.uint8, 4),
        ("test_vlseg5e8", np.uint8, 5),
        ("test_vlseg6e8", np.uint8, 6),
        ("test_vlseg7e8", np.uint8, 7),
        ("test_vlseg8e8", np.uint8, 8),
        ("test_vle16", np.uint16, 1),
        ("test_vlseg2e16", np.uint16, 2),
        ("test_vlseg3e16", np.uint16, 3),
        ("test_vlseg4e16", np.uint16, 4),
        ("test_vlseg5e16", np.uint16, 5),
        ("test_vlseg6e16", np.uint16, 6),
        ("test_vlseg7e16", np.uint16, 7),
        ("test_vlseg8e16", np.uint16, 8),
        ("test_vle32", np.uint32, 1),
        ("test_vlseg2e32", np.uint32, 2),
        ("test_vlseg3e32", np.uint32, 3),
        ("test_vlseg4e32", np.uint32, 4),
        ("test_vlseg5e32", np.uint32, 5),
        ("test_vlseg6e32", np.uint32, 6),
        ("test_vlseg7e32", np.uint32, 7),
        ("test_vlseg8e32", np.uint32, 8),
    ]

    await fixture.load_elf_and_lookup_symbols(
        r.Rlocation(
            'coralnpu_hw/tests/cocotb/rvv/load_store/load_unit_vtype.elf'
        ),
        ['vl', 'vtype', 'load_data', 'store_data', 'impl'] +
        list(f[0] for f in functions),
    )

    vlenb = 16
    with tqdm.tqdm(functions) as t:
        for (function, dtype, segments) in t:
            for sew in SEWS:
                for lmul, vlmax in SEW_TO_LMULS_AND_VLMAXS[sew]:
                    eew = DTYPE_TO_SEW[dtype]  # eew in sew encoding
                    emul_data = (lmul + 8 + eew - sew) % 8
                    # emul_data's lower limit is controlled with lmul.
                    if (emul_data in [0b100, 0b101]):
                        continue
                    # The fictional operand is not going through segments
                    if (LMUL_TO_EMUL[emul_data] * segments) > 8:
                        continue

                    t.set_postfix({
                        'function': function,
                        'sew': sew,
                        'lmul': lmul,
                    })
                    vtype = construct_vtype(1, 1, sew, lmul)
                    await fixture.write_ptr('impl', function)
                    await fixture.write_word('vtype', vtype)
                    await fixture.write_word('vl', vlmax)
                    load_data = np.random.randint(
                        0, 255, 256, dtype=np.uint8
                    ).view(dtype)
                    await fixture.write('load_data', load_data)
                    await fixture.write(
                        'store_data', np.zeros(256, dtype=np.uint8)
                    )

                    await fixture.run_to_halt()

                    store_data = (await fixture.read('store_data', 256))

                    regsize = vlenb * LMUL_TO_EMUL[emul_data]
                    for segment in range(segments):
                        segment_reg = store_data[segment *
                                                 regsize:(segment + 1) *
                                                 regsize]
                        store_result = segment_reg.view(dtype)[0:vlmax]
                        expected_result = load_data[segment:segments *
                                                    vlmax:segments]
                        assert (store_result == expected_result).all()


@cocotb.test()
async def store_unit_all_vtypes_test(dut):
    """Testbench to test RVV Unit/segmented stores, with all vtypes."""
    fixture = await Fixture.Create(dut)
    r = runfiles.Create()
    functions = [
        ("test_vse8", np.uint8, 1),
        ("test_vsseg2e8", np.uint8, 2),
        ("test_vsseg3e8", np.uint8, 3),
        ("test_vsseg4e8", np.uint8, 4),
        ("test_vsseg5e8", np.uint8, 5),
        ("test_vsseg6e8", np.uint8, 6),
        ("test_vsseg7e8", np.uint8, 7),
        ("test_vsseg8e8", np.uint8, 8),
        ("test_vse16", np.uint16, 1),
        ("test_vsseg2e16", np.uint16, 2),
        ("test_vsseg3e16", np.uint16, 3),
        ("test_vsseg4e16", np.uint16, 4),
        ("test_vsseg5e16", np.uint16, 5),
        ("test_vsseg6e16", np.uint16, 6),
        ("test_vsseg7e16", np.uint16, 7),
        ("test_vsseg8e16", np.uint16, 8),
        ("test_vse32", np.uint32, 1),
        ("test_vsseg2e32", np.uint32, 2),
        ("test_vsseg3e32", np.uint32, 3),
        ("test_vsseg4e32", np.uint32, 4),
        ("test_vsseg5e32", np.uint32, 5),
        ("test_vsseg6e32", np.uint32, 6),
        ("test_vsseg7e32", np.uint32, 7),
        ("test_vsseg8e32", np.uint32, 8),
    ]

    await fixture.load_elf_and_lookup_symbols(
        r.Rlocation(
            'coralnpu_hw/tests/cocotb/rvv/load_store/store_unit_vtype.elf'
        ),
        ['vl', 'vtype', 'load_data', 'store_data', 'impl'] +
        list(f[0] for f in functions),
    )

    vlenb = 16
    with tqdm.tqdm(functions) as t:
        for (function, dtype, segments) in t:
            for sew in SEWS:
                for lmul, vlmax in SEW_TO_LMULS_AND_VLMAXS[sew]:
                    eew = DTYPE_TO_SEW[dtype]  # eew in sew encoding
                    emul_data = (lmul + 8 + eew - sew) % 8
                    # emul_data's lower limit is controlled with lmul.
                    if (emul_data in [0b100, 0b101]):
                        continue
                    # The fictional operand is not going through segments
                    if (LMUL_TO_EMUL[emul_data] * segments) > 8:
                        continue

                    t.set_postfix({
                        'function': function,
                        'sew': sew,
                        'lmul': lmul,
                    })

                    vtype = construct_vtype(1, 1, sew, lmul)
                    await fixture.write_ptr('impl', function)
                    await fixture.write_word('vtype', vtype)
                    await fixture.write_word('vl', vlmax)
                    load_data = np.random.randint(
                        0, 255, 256, dtype=np.uint8
                    ).view(dtype)
                    await fixture.write('load_data', load_data)
                    await fixture.write(
                        'store_data', np.zeros(256, dtype=np.uint8)
                    )

                    await fixture.run_to_halt()

                    store_data = (
                        await fixture.read(
                            'store_data',
                            segments * vlmax * np.dtype(dtype).itemsize
                        )
                    ).view(dtype)

                    # Load and transpose stored segments
                    regsize = vlenb * LMUL_TO_EMUL[
                        emul_data] // np.dtype(dtype).itemsize
                    segment_regs = [
                        load_data[x * regsize:(x * regsize) + vlmax]
                        for x in range(segments)
                    ]
                    expected_result = np.transpose(np.stack(segment_regs)
                                                   ).flatten()
                    assert (expected_result == store_data).all()


@cocotb.test()
async def load_strided_all_vtypes_test(dut):
    """Testbench to test RVV strided/segmented loads, with all vtypes."""
    fixture = await Fixture.Create(dut)
    r = runfiles.Create()
    functions = [
        ("test_vlse8", np.uint8, 1),
        ("test_vlsseg2e8", np.uint8, 2),
        ("test_vlsseg3e8", np.uint8, 3),
        ("test_vlsseg4e8", np.uint8, 4),
        ("test_vlsseg5e8", np.uint8, 5),
        ("test_vlsseg6e8", np.uint8, 6),
        ("test_vlsseg7e8", np.uint8, 7),
        ("test_vlsseg8e8", np.uint8, 8),
        ("test_vlse16", np.uint16, 1),
        ("test_vlsseg2e16", np.uint16, 2),
        ("test_vlsseg3e16", np.uint16, 3),
        ("test_vlsseg4e16", np.uint16, 4),
        ("test_vlsseg5e16", np.uint16, 5),
        ("test_vlsseg6e16", np.uint16, 6),
        ("test_vlsseg7e16", np.uint16, 7),
        ("test_vlsseg8e16", np.uint16, 8),
        ("test_vlse32", np.uint32, 1),
        ("test_vlsseg2e32", np.uint32, 2),
        ("test_vlsseg3e32", np.uint32, 3),
        ("test_vlsseg4e32", np.uint32, 4),
        ("test_vlsseg5e32", np.uint32, 5),
        ("test_vlsseg6e32", np.uint32, 6),
        ("test_vlsseg7e32", np.uint32, 7),
        ("test_vlsseg8e32", np.uint32, 8),
    ]

    await fixture.load_elf_and_lookup_symbols(
        r.Rlocation(
            'coralnpu_hw/tests/cocotb/rvv/load_store/load_stride_vtype.elf'
        ),
        ['vl', 'vtype', 'stride', 'load_data', 'store_data', 'impl'] +
        list(f[0] for f in functions),
    )

    vlenb = 16
    with tqdm.tqdm(functions) as t:
        for (function, dtype, segments) in t:
            for sew in SEWS:
                for lmul, vlmax in SEW_TO_LMULS_AND_VLMAXS[sew]:
                    eew = DTYPE_TO_SEW[dtype]  # eew in sew encoding
                    emul_data = (lmul + 8 + eew - sew) % 8
                    # emul_data's lower limit is controlled with lmul.
                    if (emul_data in [0b100, 0b101]):
                        continue
                    # The fictional operand is not going through segments
                    if (LMUL_TO_EMUL[emul_data] * segments) > 8:
                        continue

                    t.set_postfix({
                        'function': function,
                        'sew': sew,
                        'lmul': lmul,
                    })
                    vtype = construct_vtype(1, 1, sew, lmul)
                    stride = 32
                    await fixture.write_ptr('impl', function)
                    await fixture.write_word('vtype', vtype)
                    await fixture.write_word('vl', vlmax)
                    await fixture.write_word('stride', stride)
                    load_data = np.random.randint(0, 255, 8192, dtype=np.uint8)
                    await fixture.write('load_data', load_data)
                    await fixture.write(
                        'store_data', np.zeros(256, dtype=np.uint8)
                    )

                    await fixture.run_to_halt()

                    segment_size = segments * np.dtype(dtype).itemsize
                    expected_segment_data = [
                        load_data[(stride * i):(stride * i) +
                                  segment_size].view(dtype)
                        for i in range(vlmax)
                    ]
                    expected_segment_data = np.transpose(
                        np.stack(expected_segment_data)
                    )

                    store_data = (await fixture.read('store_data', 256))

                    regsize = vlenb * LMUL_TO_EMUL[emul_data]
                    for segment in range(segments):
                        segment_reg = store_data[segment *
                                                 regsize:(segment + 1) *
                                                 regsize]
                        store_result = segment_reg.view(dtype)[0:vlmax]
                        expected_result = expected_segment_data[segment]
                        assert (store_result == expected_result).all()


@cocotb.test()
async def store_strided_all_vtypes_test(dut):
    """Testbench to test RVV strided/segmented store, with all vtypes."""
    fixture = await Fixture.Create(dut)
    r = runfiles.Create()
    functions = [
        ("test_vsse8", np.uint8, 1),
        ("test_vssseg2e8", np.uint8, 2),
        ("test_vssseg3e8", np.uint8, 3),
        ("test_vssseg4e8", np.uint8, 4),
        ("test_vssseg5e8", np.uint8, 5),
        ("test_vssseg6e8", np.uint8, 6),
        ("test_vssseg7e8", np.uint8, 7),
        ("test_vssseg8e8", np.uint8, 8),
        ("test_vsse16", np.uint16, 1),
        ("test_vssseg2e16", np.uint16, 2),
        ("test_vssseg3e16", np.uint16, 3),
        ("test_vssseg4e16", np.uint16, 4),
        ("test_vssseg5e16", np.uint16, 5),
        ("test_vssseg6e16", np.uint16, 6),
        ("test_vssseg7e16", np.uint16, 7),
        ("test_vssseg8e16", np.uint16, 8),
        ("test_vsse32", np.uint32, 1),
        ("test_vssseg2e32", np.uint32, 2),
        ("test_vssseg3e32", np.uint32, 3),
        ("test_vssseg4e32", np.uint32, 4),
        ("test_vssseg5e32", np.uint32, 5),
        ("test_vssseg6e32", np.uint32, 6),
        ("test_vssseg7e32", np.uint32, 7),
        ("test_vssseg8e32", np.uint32, 8),
    ]

    await fixture.load_elf_and_lookup_symbols(
        r.Rlocation(
            'coralnpu_hw/tests/cocotb/rvv/load_store/store_strided_vtype.elf'
        ),
        ['vl', 'vtype', 'stride', 'load_data', 'store_data', 'impl'] +
        list(f[0] for f in functions),
    )

    vlenb = 16
    with tqdm.tqdm(functions) as t:
        for (function, dtype, segments) in t:
            for sew in SEWS:
                for lmul, vlmax in SEW_TO_LMULS_AND_VLMAXS[sew]:
                    eew = DTYPE_TO_SEW[dtype]  # eew in sew encoding
                    emul_data = (lmul + 8 + eew - sew) % 8
                    # emul_data's lower limit is controlled with lmul.
                    if (emul_data in [0b100, 0b101]):
                        continue
                    # The fictional operand is not going through segments
                    if (LMUL_TO_EMUL[emul_data] * segments) > 8:
                        continue

                    t.set_postfix({
                        'function': function,
                        'sew': sew,
                        'lmul': lmul,
                    })
                    vtype = construct_vtype(1, 1, sew, lmul)
                    stride = 32
                    await fixture.write_ptr('impl', function)
                    await fixture.write_word('vtype', vtype)
                    await fixture.write_word('vl', vlmax)
                    await fixture.write_word('stride', stride)
                    load_data = np.random.randint(0, 255, 256, dtype=np.uint8)
                    await fixture.write('load_data', load_data)
                    await fixture.write(
                        'store_data', np.zeros(8192, dtype=np.uint8)
                    )

                    await fixture.run_to_halt()

                    regstride = vlenb * LMUL_TO_EMUL[emul_data]
                    regsize = vlmax * np.dtype(dtype).itemsize
                    regs = [
                        load_data[(i * regstride):(i * regstride) +
                                  regsize].view(dtype)
                        for i in range(segments)
                    ]
                    segment_regs = np.transpose(np.stack(regs)).copy()
                    expected_store_data = np.zeros(8192, dtype=np.uint8)
                    for v in range(vlmax):
                        data = segment_regs[v].view(np.uint8)
                        expected_store_data[(v * stride):(v * stride) +
                                            len(data)] = data

                    store_data = (await fixture.read('store_data', 8192))
                    assert (expected_store_data == store_data).all()


@cocotb.test()
async def load_store_whole_register_test(dut):
    """Testbench to test RVV strided/segmented store, with all vtypes."""
    fixture = await Fixture.Create(dut)
    r = runfiles.Create()
    functions = [
        # Name, store, n_registers
        ("test_vl1r", False, 1),
        ("test_vl2r", False, 2),
        ("test_vl4r", False, 4),
        ("test_vl8r", False, 8),
        ("test_vs1r", True, 1),
        ("test_vs2r", True, 2),
        ("test_vs4r", True, 4),
        ("test_vs8r", True, 8),
    ]

    await fixture.load_elf_and_lookup_symbols(
        r.Rlocation(
            'coralnpu_hw/tests/cocotb/rvv/load_store/load_store_whole_register.elf'
        ),
        ['vl', 'vtype', 'stride', 'load_data', 'store_data', 'impl'] +
        list(f[0] for f in functions),
    )

    vlenb = 16
    with tqdm.tqdm(functions) as t:
        for (function, store, n_registers) in t:
            for sew in SEWS:
                for lmul, _ in SEW_TO_LMULS_AND_VLMAXS[sew]:
                    t.set_postfix({
                        'function': function,
                        'sew': sew,
                        'lmul': lmul,
                    })

                    await fixture.write_ptr('impl', function)
                    vtype = construct_vtype(1, 1, sew, lmul)
                    await fixture.write_word('vtype', vtype)
                    await fixture.write_word('vl', 1)

                    load_data = np.random.randint(0, 255, 128, dtype=np.uint8)
                    await fixture.write('load_data', load_data)
                    await fixture.write(
                        'store_data', 0xFF * np.ones(128, dtype=np.uint8)
                    )

                    await fixture.run_to_halt()

                    store_data = (await fixture.read('store_data', 128))

                    data_written = vlenb * n_registers
                    assert (
                        load_data[0:data_written] == store_data[0:data_written]
                    ).all()
                    if store:
                        assert (store_data[data_written:] == 0xFF).all()
                    else:
                        assert (store_data[data_written:] == 0x00).all()
