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

from coralnpu_test_utils.coralflow.runner import coralflow_main, coralflow_test
import itertools
import numpy as np
import tqdm

from bazel_tools.tools.python.runfiles import runfiles
from coralnpu_test_utils.rvv_type_util import construct_vtype, DTYPE_TO_SEW, SEWS, SEW_TO_LMULS_AND_VLMAXS, LMUL_TO_EMUL


async def vector_load_store(
    fixture,
    elf_name: str,
    dtype,
    in_size: int,
    out_size: int,
    pattern: list[int],
):
    """RVV load-store test template.

    Each test performs some kind of patterned copy from `in_buf` to `out_buf`.
    """
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
    fixture,
    elf_name: str,
    cases: list[dict],  # keys: impl, vl, in_size, out_size, pattern.
    dtype,
):
    """RVV load-store test template.

    Each test performs some kind of patterned copy from `in_buf` to `out_buf`.
    """
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
    fixture,
    elf_name: str,
    cases: list[dict],  # keys: impl, vl, segments, in_bytes, out_size.
    dtype,
    index_dtype,
):
    """RVV load-store test template for segmented indexed loads.

    Each test performs a gather-unzip operation and writes the result to an output.
    """
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
    fixture,
    elf_name: str,
    cases: list[dict],  # keys: impl, vl, segments, out_size.
    data_dtype,
    index_dtype,
):
    """RVV load-store test template for segmented indexed stores.

    Each test loads indices and data and performs a scatter operation.
    """
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


@coralflow_test
async def load_store_bits(fixture):
    """Test vlm/vsm usage accessible from intrinsics."""
    # mask is not accessible from here.
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


@coralflow_test
async def load_unit_masked(fixture):
    """Test masked unit stores."""

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

    axi_options = [False, True] if hasattr(fixture,
                                           'core_mini_axi') else [False]
    all_cases = itertools.product(axi_options, cases)
    total_loops = len(axi_options) * len(cases)

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


@coralflow_test
async def load_unit_ff(fixture):
    """Test fault-only-first unit loads (vle8ff.v, vle16ff.v, vle32ff.v) across all SEWs and LMULs."""

    r = runfiles.Create()

    await fixture.load_elf_and_lookup_symbols(
        r.
        Rlocation('coralnpu_hw/tests/cocotb/rvv/load_store/load_unit_ff.elf'),
        [
            "impl",
            "vtype",
            "load_data",
            "load_addr",
            "vl",
            "load_filler",
            "mask_data",
            "store_data",
            "test_unit_load8_ff",
            "test_unit_load16_ff",
            "test_unit_load32_ff",
            "test_unit_load8_ff_unmasked",
            "test_unit_load16_ff_unmasked",
            "test_unit_load32_ff_unmasked",
        ],
    )

    cases = [
        # SEW8
        (np.uint8, 0b110, 4),  # SEW8, mf4, vlmax=4
        (np.uint8, 0b110, 3),  # SEW8, mf4, partial vl
        (np.uint8, 0b111, 8),  # SEW8, mf2, vlmax=8
        (np.uint8, 0b111, 7),  # SEW8, mf2, partial vl
        (np.uint8, 0b000, 16),  # SEW8, m1, vlmax=16
        (np.uint8, 0b000, 15),  # SEW8, m1, partial vl
        (np.uint8, 0b000, 1),  # SEW8, m1, single element vl=1
        (np.uint8, 0b001, 32),  # SEW8, m2, vlmax=32
        (np.uint8, 0b001, 31),  # SEW8, m2, partial vl
        (np.uint8, 0b010, 64),  # SEW8, m4, vlmax=64
        (np.uint8, 0b010, 63),  # SEW8, m4, partial vl
        (np.uint8, 0b011, 128),  # SEW8, m8, vlmax=128
        (np.uint8, 0b011, 127),  # SEW8, m8, partial vl
        # SEW16
        (np.uint16, 0b111, 4),  # SEW16, mf2, vlmax=4
        (np.uint16, 0b111, 3),  # SEW16, mf2, partial vl
        (np.uint16, 0b000, 8),  # SEW16, m1, vlmax=8
        (np.uint16, 0b000, 7),  # SEW16, m1, partial vl
        (np.uint16, 0b000, 1),  # SEW16, m1, single element vl=1
        (np.uint16, 0b001, 16),  # SEW16, m2, vlmax=16
        (np.uint16, 0b001, 15),  # SEW16, m2, partial vl
        (np.uint16, 0b010, 32),  # SEW16, m4, vlmax=32
        (np.uint16, 0b010, 31),  # SEW16, m4, partial vl
        (np.uint16, 0b011, 64),  # SEW16, m8, vlmax=64
        (np.uint16, 0b011, 63),  # SEW16, m8, partial vl
        # SEW32
        (np.uint32, 0b000, 4),  # SEW32, m1, vlmax=4
        (np.uint32, 0b000, 3),  # SEW32, m1, partial vl
        (np.uint32, 0b000, 1),  # SEW32, m1, single element vl=1
        (np.uint32, 0b001, 8),  # SEW32, m2, vlmax=8
        (np.uint32, 0b001, 7),  # SEW32, m2, partial vl
        (np.uint32, 0b010, 16),  # SEW32, m4, vlmax=16
        (np.uint32, 0b010, 15),  # SEW32, m4, partial vl
        (np.uint32, 0b011, 32),  # SEW32, m8, vlmax=32
        (np.uint32, 0b011, 31),  # SEW32, m8, partial vl
    ]

    dtype_to_masked_function = {
        np.uint8: "test_unit_load8_ff",
        np.uint16: "test_unit_load16_ff",
        np.uint32: "test_unit_load32_ff",
    }
    dtype_to_unmasked_function = {
        np.uint8: "test_unit_load8_ff_unmasked",
        np.uint16: "test_unit_load16_ff_unmasked",
        np.uint32: "test_unit_load32_ff_unmasked",
    }

    rng = np.random.default_rng(42)

    axi_options = [False, True] if hasattr(fixture,
                                           'core_mini_axi') else [False]

    # 1. Unmasked fault-only-first loads across TCM and AXI
    unmasked_tests = list(itertools.product(axi_options, cases))
    for use_axi, (dtype, lmul, vl) in tqdm.tqdm(unmasked_tests,
                                                desc="load_unit_ff unmasked"):
        vtype = construct_vtype(0, 0, DTYPE_TO_SEW[dtype], lmul)
        min_value = np.iinfo(dtype).min
        max_value = np.iinfo(dtype).max + 1
        load_data = rng.integers(min_value, max_value, vl, dtype=dtype)
        load_filler = np.iinfo(dtype).max

        if use_axi:
            await fixture.write_word(
                'load_addr', fixture.core_mini_axi.memory_base_addr
            )
        else:
            await fixture.write_ptr('load_addr', 'load_data')

        await fixture.write_ptr('impl', dtype_to_unmasked_function[dtype])
        await fixture.write_word('vl', vl)
        await fixture.write_word('load_filler', load_filler)
        await fixture.write_word('vtype', vtype)
        if use_axi:
            load_data_size = vl * np.dtype(dtype).itemsize
            fixture.core_mini_axi.memory[0:load_data_size] = (
                load_data.view(np.uint8)
            )
        else:
            await fixture.write('load_data', load_data)

        await fixture.run_to_halt()

        actual_output = (
            await fixture.read('store_data',
                               vl * np.dtype(dtype).itemsize)
        ).view(dtype)

        assert np.array_equal(
            load_data, actual_output
        ), f"unmasked mismatch at vl={vl}, dtype={dtype}, lmul={lmul}, axi={use_axi}"

    # 2. Masked fault-only-first loads across TCM and AXI with random mask, all-ones, and all-zeros
    mask_modes = ['random', 'all_ones', 'all_zeros']
    for mask_mode in mask_modes:
        # For all_ones and all_zeros, testing on TCM is sufficient to keep test runtime lean.
        tested_axi = axi_options if mask_mode == 'random' else [False]
        masked_tests = list(itertools.product(tested_axi, cases))
        for use_axi, (dtype, lmul, vl) in tqdm.tqdm(
                masked_tests, desc=f"load_unit_ff masked_{mask_mode}"):
            vtype = construct_vtype(0, 0, DTYPE_TO_SEW[dtype], lmul)
            mask_bytes = (vl + 7) // 8
            if mask_mode == 'random':
                mask_data = rng.integers(0, 256, mask_bytes, dtype=np.uint8)
            elif mask_mode == 'all_ones':
                mask_data = np.full(mask_bytes, 0xFF, dtype=np.uint8)
            else:  # all_zeros
                mask_data = np.zeros(mask_bytes, dtype=np.uint8)

            min_value = np.iinfo(dtype).min
            max_value = np.iinfo(dtype).max + 1
            load_data = rng.integers(min_value, max_value, vl, dtype=dtype)
            load_filler = np.iinfo(dtype).max

            if use_axi:
                await fixture.write_word(
                    'load_addr', fixture.core_mini_axi.memory_base_addr
                )
            else:
                await fixture.write_ptr('load_addr', 'load_data')

            await fixture.write_ptr('impl', dtype_to_masked_function[dtype])
            await fixture.write_word('vl', vl)
            await fixture.write_word('load_filler', load_filler)
            await fixture.write_word('vtype', vtype)
            if use_axi:
                load_data_size = vl * np.dtype(dtype).itemsize
                fixture.core_mini_axi.memory[0:load_data_size] = (
                    load_data.view(np.uint8)
                )
            else:
                await fixture.write('load_data', load_data)
            await fixture.write('mask_data', mask_data)

            await fixture.run_to_halt()

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
                    assert load_data[i] == actual_output[i], (
                        f"mismatch at element {i} (mask_mode={mask_mode}, axi={use_axi}): "
                        f"expected load_data {load_data[i]}, got {actual_output[i]}"
                    )
                else:
                    assert load_filler == actual_output[i], (
                        f"mismatch at masked element {i} (mask_mode={mask_mode}, axi={use_axi}): "
                        f"expected filler {load_filler}, got {actual_output[i]}"
                    )

    # 3. Diverse alignments and intermediate vector lengths across TCM and AXI
    # Tests non-zero byte offsets (unaligned addresses: +1, +2, +3, +7) across varied
    # vector lengths vl (1..15) ensuring intermediate ff_tail_index values (1..15)
    # between 0 and p.rvvVlenb (16) operate correctly with unaligned memory accesses.
    alignment_cases = [
        # (dtype, lmul, vl, byte_offset)
        # SEW8: ff_tail_index = 1, 2, 3, 5, 7, 9, 11, 13, 15
        (np.uint8, 0b000, 1, 1),
        (np.uint8, 0b000, 2, 2),
        (np.uint8, 0b000, 3, 3),
        (np.uint8, 0b000, 5, 1),
        (np.uint8, 0b000, 7, 7),
        (np.uint8, 0b000, 9, 3),
        (np.uint8, 0b000, 11, 2),
        (np.uint8, 0b000, 13, 1),
        (np.uint8, 0b000, 15, 7),
        # SEW16: ff_tail_index = 2, 6, 10, 14
        (np.uint16, 0b000, 1, 1),
        (np.uint16, 0b000, 3, 2),
        (np.uint16, 0b000, 5, 3),
        (np.uint16, 0b000, 7, 7),
        # SEW32: ff_tail_index = 4, 8, 12
        (np.uint32, 0b000, 1, 1),
        (np.uint32, 0b000, 2, 2),
        (np.uint32, 0b000, 3, 3),
    ]

    alignment_tests = list(itertools.product(axi_options, alignment_cases))
    load_data_base_tcm = fixture.symbols['load_data']
    for use_axi, (dtype, lmul, vl, byte_offset) in tqdm.tqdm(
            alignment_tests, desc="load_unit_ff unaligned_and_lengths"):
        vtype = construct_vtype(0, 0, DTYPE_TO_SEW[dtype], lmul)
        min_value = np.iinfo(dtype).min
        max_value = np.iinfo(dtype).max + 1
        load_data = rng.integers(min_value, max_value, vl, dtype=dtype)
        load_filler = np.iinfo(dtype).max
        load_data_bytes = load_data.view(np.uint8)

        if use_axi:
            load_addr = fixture.core_mini_axi.memory_base_addr + byte_offset
            fixture.core_mini_axi.memory[byte_offset:byte_offset +
                                         len(load_data_bytes)
                                         ] = load_data_bytes
        else:
            load_addr = load_data_base_tcm + byte_offset
            await fixture.write(load_addr, load_data)

        await fixture.write_word('load_addr', load_addr)
        await fixture.write_ptr('impl', dtype_to_unmasked_function[dtype])
        await fixture.write_word('vl', vl)
        await fixture.write_word('load_filler', load_filler)
        await fixture.write_word('vtype', vtype)

        await fixture.run_to_halt()

        actual_output = (
            await fixture.read('store_data',
                               vl * np.dtype(dtype).itemsize)
        ).view(dtype)

        assert np.array_equal(
            load_data, actual_output
        ), f"unaligned mismatch at vl={vl}, offset={byte_offset}, dtype={dtype}, axi={use_axi}"


@coralflow_test
async def store_unit_masked(fixture):
    """Test masked unit stores."""
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

    axi_options = [False, True] if hasattr(fixture,
                                           'core_mini_axi') else [False]
    all_cases = itertools.product(axi_options, cases)
    total_loops = len(axi_options) * len(cases)

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


@coralflow_test
async def load8_stride0_m1(fixture):
    await vector_load_store(
        fixture=fixture,
        elf_name='load8_stride0_m1.elf',
        dtype=np.uint8,
        in_size=32,
        out_size=16,
        pattern=[0] * 16,
    )


@coralflow_test
async def load8_stride0strict_m1(fixture):
    await vector_load_store(
        fixture=fixture,
        elf_name='load8_stride0strict_m1.elf',
        dtype=np.uint8,
        in_size=32,
        out_size=16,
        pattern=[0] * 16,
    )


@coralflow_test
async def load8_stride2_m1(fixture):
    await vector_load_store(
        fixture=fixture,
        elf_name='load8_stride2_m1.elf',
        dtype=np.uint8,
        in_size=32,
        out_size=16,
        pattern=list(range(0, 31, 2)),
    )


@coralflow_test
async def load8_stride2_m1_partial(fixture):
    await vector_load_store(
        fixture=fixture,
        elf_name='load8_stride2_m1_partial.elf',
        dtype=np.uint8,
        in_size=32,
        out_size=16,
        pattern=list(range(0, 29, 2)),
    )


@coralflow_test
async def load8_stride2_mf4(fixture):
    await vector_load_store(
        fixture=fixture,
        elf_name='load8_stride2_mf4.elf',
        dtype=np.uint8,
        in_size=32,
        out_size=16,
        pattern=[0, 2, 4, 6],
    )


@coralflow_test
async def load16_stride4_m1(fixture):
    await vector_load_store(
        fixture=fixture,
        elf_name='load16_stride4_m1.elf',
        dtype=np.uint16,
        in_size=16,
        out_size=8,
        pattern=list(range(0, 15, 2)),
    )


@coralflow_test
async def load16_stride4_m1_partial(fixture):
    await vector_load_store(
        fixture=fixture,
        elf_name='load16_stride4_m1_partial.elf',
        dtype=np.uint16,
        in_size=16,
        out_size=8,
        pattern=list(range(0, 13, 2)),
    )


@coralflow_test
async def load16_stride4_mf2(fixture):
    await vector_load_store(
        fixture=fixture,
        elf_name='load16_stride4_mf2.elf',
        dtype=np.uint16,
        in_size=16,
        out_size=8,
        pattern=[0, 2, 4, 6],
    )


@coralflow_test
async def load32_stride8_m1(fixture):
    await vector_load_store(
        fixture=fixture,
        elf_name='load32_stride8_m1.elf',
        dtype=np.uint32,
        in_size=8,
        out_size=4,
        pattern=[0, 2, 4, 6],
    )


@coralflow_test
async def load32_stride8_m1_partial(fixture):
    await vector_load_store(
        fixture=fixture,
        elf_name='load32_stride8_m1_partial.elf',
        dtype=np.uint32,
        in_size=8,
        out_size=4,
        pattern=[0, 2, 4],
    )


@coralflow_test
async def load_store8_unit_m2(fixture):
    await vector_load_store(
        fixture=fixture,
        elf_name='load_store8_unit_m2.elf',
        dtype=np.uint8,
        in_size=64,
        out_size=64,
        pattern=list(range(0, 32)),
    )


@coralflow_test
async def load_store16_unit_m2(fixture):
    await vector_load_store(
        fixture=fixture,
        elf_name='load_store16_unit_m2.elf',
        dtype=np.uint16,
        in_size=32,
        out_size=32,
        pattern=list(range(0, 16)),
    )


@coralflow_test
async def load_store32_unit_m2(fixture):
    await vector_load_store(
        fixture=fixture,
        elf_name='load_store32_unit_m2.elf',
        dtype=np.uint32,
        in_size=16,
        out_size=16,
        pattern=list(range(0, 8)),
    )


@coralflow_test
async def load8_index8(fixture):
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
        fixture=fixture,
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


@coralflow_test
async def load8_index8_seg(fixture):
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
        fixture=fixture,
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


@coralflow_test
async def load8_index16(fixture):
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
        fixture=fixture,
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


@coralflow_test
async def load8_index16_seg(fixture):
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
        fixture=fixture,
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


@coralflow_test
async def load8_seg_unit(fixture):
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
        fixture=fixture,
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


@coralflow_test
async def load8_index32(fixture):
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
        fixture=fixture,
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


@coralflow_test
async def load8_index32_seg(fixture):
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
        fixture=fixture,
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


@coralflow_test
async def load16_index8(fixture):
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
        fixture=fixture,
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


@coralflow_test
async def load16_index8_seg(fixture):
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
        fixture=fixture,
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


@coralflow_test
async def load16_index16_seg(fixture):
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
        fixture=fixture,
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


@coralflow_test
async def load16_index32_seg(fixture):
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
        fixture=fixture,
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


@coralflow_test
async def load16_seg_unit(fixture):
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
        fixture=fixture,
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


@coralflow_test
async def load32_index8(fixture):
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
        fixture=fixture,
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


@coralflow_test
async def load32_index8_seg(fixture):
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
        fixture=fixture,
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


@coralflow_test
async def load32_index16_seg(fixture):
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
        fixture=fixture,
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


@coralflow_test
async def load32_index32_seg(fixture):
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
        fixture=fixture,
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


@coralflow_test
async def load32_seg_unit(fixture):
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
        fixture=fixture,
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


@coralflow_test
async def load8_segment2_stride6_m1(fixture):
    await vector_load_store(
        fixture=fixture,
        elf_name='load8_segment2_stride6_m1.elf',
        dtype=np.uint8,
        in_size=256,
        out_size=64,
        pattern=([i * 6 for i in range(16)] + [i * 6 + 1 for i in range(16)]),
    )


@coralflow_test
async def load16_segment2_stride6_m1(fixture):
    await vector_load_store(
        fixture=fixture,
        elf_name='load16_segment2_stride6_m1.elf',
        dtype=np.uint16,
        in_size=128,
        out_size=32,
        pattern=([i * 3 for i in range(8)] + [i * 3 + 1 for i in range(8)]),
    )


@coralflow_test
async def store8_index8(fixture):
    """Test vs*xei8_v_u8 usage accessible from intrinsics."""

    def make_test_case(impl: str, vl: int):
        return {
            'impl': impl,
            'vl': vl,
            'segments': 1,
            'out_size': 512,
        }

    await vector_store_segmented_indexed(
        fixture=fixture,
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


@coralflow_test
async def store8_index8_seg(fixture):
    """Test vs*xseg*ei8_v_u8 usage accessible from intrinsics."""

    def make_test_case(impl: str, vl: int, segs: int):
        return {
            'impl': impl,
            'vl': vl,
            'segments': segs,
            'out_size': 512,
        }

    await vector_store_segmented_indexed(
        fixture=fixture,
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


@coralflow_test
async def store8_index16(fixture):
    """Test vs*xei16_v_u8 usage accessible from intrinsics."""

    def make_test_case(impl: str, vl: int):
        return {
            'impl': impl,
            'vl': vl,
            'segments': 1,
            'out_size': 30000,
        }

    await vector_store_segmented_indexed(
        fixture=fixture,
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


@coralflow_test
async def store8_index32(fixture):
    """Test vs*xei32_v_u8 usage accessible from intrinsics."""

    def make_test_case(impl: str, vl: int):
        return {
            'impl': impl,
            'vl': vl,
            'segments': 1,
            'out_size': 30000,
        }

    await vector_store_segmented_indexed(
        fixture=fixture,
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


@coralflow_test
async def store16_index8(fixture):
    """Test vs*xei8_v_u16 usage accessible from intrinsics."""

    def make_test_case(impl: str, vl: int):
        return {
            'impl': impl,
            'vl': vl,
            'segments': 1,
            'out_size': 256,
        }

    await vector_store_segmented_indexed(
        fixture=fixture,
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


@coralflow_test
async def store16_index16(fixture):
    """Test vs*xei16_v_u16 usage accessible from intrinsics."""

    def make_test_case(impl: str, vl: int):
        return {
            'impl': impl,
            'vl': vl,
            'segments': 1,
            'out_size': 15000,
        }

    await vector_store_segmented_indexed(
        fixture=fixture,
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


@coralflow_test
async def store16_index32(fixture):
    """Test vs*xei32_v_u16 usage accessible from intrinsics."""

    def make_test_case(impl: str, vl: int):
        return {
            'impl': impl,
            'vl': vl,
            'segments': 1,
            'out_size': 15000,
        }

    await vector_store_segmented_indexed(
        fixture=fixture,
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


@coralflow_test
async def store32_index8(fixture):
    """Test vs*xei8_v_u32 usage accessible from intrinsics."""

    def make_test_case(impl: str, vl: int):
        return {
            'impl': impl,
            'vl': vl,
            'segments': 1,
            'out_size': 512,
        }

    await vector_store_segmented_indexed(
        fixture=fixture,
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


@coralflow_test
async def store32_index16(fixture):
    """Test vs*xei16_v_u32 usage accessible from intrinsics."""

    def make_test_case(impl: str, vl: int):
        return {
            'impl': impl,
            'vl': vl,
            'segments': 1,
            'out_size': 7000,
        }

    await vector_store_segmented_indexed(
        fixture=fixture,
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


@coralflow_test
async def store32_index32(fixture):
    """Test vs*xei32_v_u32 usage accessible from intrinsics."""

    def make_test_case(impl: str, vl: int):
        return {
            'impl': impl,
            'vl': vl,
            'segments': 1,
            'out_size': 7000,
        }

    await vector_store_segmented_indexed(
        fixture=fixture,
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


@coralflow_test
async def store8_seg_unit(fixture):
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
        fixture=fixture,
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


@coralflow_test
async def store16_seg_unit(fixture):
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
        fixture=fixture,
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


@coralflow_test
async def store32_seg_unit(fixture):
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
        fixture=fixture,
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


async def _setup_lsu_fault_fixture(fixture):
    r = runfiles.Create()
    await fixture.load_elf_and_lookup_symbols(
        r.Rlocation(
            'coralnpu_hw/tests/cocotb/rvv/load_store/lsu_fault_cases.elf'
        ),
        [
            '__data_start__',
            'boundary_scratch',
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
            'faulting_insn_vleff',
            'faulting_insn_scalar_mixed',
            'faulting_insn_scalar_scalar',
            'run_scalar_fault_preserves_vstart',
            'run_unit_stride_fault_rs_flush',
            'run_negative_stride_mid_vstart_fault',
            'run_indexed_mid_vstart_fault',
            'run_seg3_negative_stride_mid_vstart_fault',
            'run_seg5_negative_stride_mid_vstart_fault',
            'run_vector_load_fault_rs_flush',
            'run_vleff_fault_rs_flush',
            'run_scalar_mixed_fault_rs_flush',
            'run_scalar_to_scalar_fault_rs_flush',
        ],
    )
    assert (
        fixture.symbols['boundary_scratch'] ==
        fixture.symbols['__data_start__']
    ), (
        'Expected boundary_scratch at __data_start__ '
        f"({hex(fixture.symbols['__data_start__'])}), "
        f"got {hex(fixture.symbols['boundary_scratch'])}"
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
        await fixture.write(
            target_in_addr, np.random.randint(0, 255, count, dtype=np.uint8)
        )
        await fixture.write(
            'in_ptr', np.array([target_in_addr], dtype=np.uint32)
        )
        await fixture.write('vl', np.array([vl], dtype=np.uint32))

    await fixture.write_ptr('test_fn', test_fn_symbol)
    await fixture.run_to_halt()

    fault_count = await fixture.read_word('fault_count')
    assert fault_count == 1, f"Expected exactly 1 fault, got {fault_count}"

    fault_mcause = await fixture.read_word('fault_mcause')
    assert fault_mcause == expected_mcause, (
        f"Expected mcause={expected_mcause}, got {fault_mcause}"
    )

    fault_mepc = await fixture.read_word('fault_mepc')
    expected_pc = fixture.symbols[faulting_insn_symbol]
    assert fault_mepc == expected_pc, (
        f"Expected PC {hex(expected_pc)}, got {hex(fault_mepc)}"
    )

    fault_mtval = await fixture.read_word('fault_mtval')
    assert fault_mtval == expected_mtval, (
        f"Expected mtval {hex(expected_mtval)}, got {hex(fault_mtval)}"
    )

    fault_vstart = await fixture.read_word('fault_vstart')
    assert fault_vstart == expected_vstart, (
        f"Expected vstart={expected_vstart}, got {fault_vstart}"
    )


@coralflow_test
async def lsu_fault_scalar_preserves_vstart(fixture):
    """Testbench to verify scalar memory fault preserves non-zero vstart."""
    await _setup_lsu_fault_fixture(fixture)
    await _run_and_verify_lsu_fault(
        fixture,
        test_fn_symbol='run_scalar_fault_preserves_vstart',
        faulting_insn_symbol='faulting_insn_scalar',
        expected_mcause=7,
        expected_mtval=fixture.symbols['__data_start__'] - 4,
        expected_vstart=3,
    )


@coralflow_test
async def lsu_fault_unit_stride_rs_flush(fixture):
    """Testbench to verify unit-stride vector store fault purges subsequent stores in RS (Vector -> Vector)."""
    await _setup_lsu_fault_fixture(fixture)
    await _run_and_verify_lsu_fault(
        fixture,
        test_fn_symbol='run_unit_stride_fault_rs_flush',
        faulting_insn_symbol='faulting_insn_unit',
        expected_mcause=7,
        expected_mtval=(fixture.symbols['__data_start__'] - 4) & ~0xF,
        expected_vstart=0,
    )


@coralflow_test
async def lsu_fault_negative_stride_mid_vstart(fixture):
    """Testbench to verify negative-stride vector store crossing boundary calculates mid-vector vstart."""
    await _setup_lsu_fault_fixture(fixture)
    await _run_and_verify_lsu_fault(
        fixture,
        test_fn_symbol='run_negative_stride_mid_vstart_fault',
        faulting_insn_symbol='faulting_insn_neg_stride',
        expected_mcause=7,
        expected_mtval=(fixture.symbols['__data_start__'] - 4) & ~0xF,
        expected_vstart=3,
        vl=8,
    )


@coralflow_test
async def lsu_fault_indexed_mid_vstart(fixture):
    """Testbench to verify indexed vector store calculates mid-vector vstart."""
    await _setup_lsu_fault_fixture(fixture)
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


@coralflow_test
async def lsu_fault_seg3_negative_stride_mid_vstart(fixture):
    """Testbench to verify segment store with NF=3 calculates mid-vector vstart via NF=3 division."""
    await _setup_lsu_fault_fixture(fixture)
    await _run_and_verify_lsu_fault(
        fixture,
        test_fn_symbol='run_seg3_negative_stride_mid_vstart_fault',
        faulting_insn_symbol='faulting_insn_seg3',
        expected_mcause=7,
        expected_mtval=(fixture.symbols['__data_start__'] - 6) & ~0xF,
        expected_vstart=4,
        vl=8,
    )


@coralflow_test
async def lsu_fault_seg5_negative_stride_mid_vstart(fixture):
    """Testbench to verify segment store with NF=5 calculates mid-vector vstart via NF=5 division."""
    await _setup_lsu_fault_fixture(fixture)
    await _run_and_verify_lsu_fault(
        fixture,
        test_fn_symbol='run_seg5_negative_stride_mid_vstart_fault',
        faulting_insn_symbol='faulting_insn_seg5',
        expected_mcause=7,
        expected_mtval=(fixture.symbols['__data_start__'] - 10) & ~0xF,
        expected_vstart=3,
        vl=8,
    )


@coralflow_test
async def lsu_fault_vector_load_rs_flush(fixture):
    """Testbench to verify vector load fault purges follow-on scalar store in RS (Vector -> Scalar)."""
    await _setup_lsu_fault_fixture(fixture)
    await _run_and_verify_lsu_fault(
        fixture,
        test_fn_symbol='run_vector_load_fault_rs_flush',
        faulting_insn_symbol='faulting_insn_load',
        expected_mcause=5,
        expected_mtval=0xA0000000,
        expected_vstart=0,
    )


@coralflow_test
async def lsu_fault_vleff_rs_flush(fixture):
    """Testbench to verify fault-only-first load fault on element 0 purges follow-on scalar store and raises exception."""
    await _setup_lsu_fault_fixture(fixture)
    await _run_and_verify_lsu_fault(
        fixture,
        test_fn_symbol='run_vleff_fault_rs_flush',
        faulting_insn_symbol='faulting_insn_vleff',
        expected_mcause=5,
        expected_mtval=0xA0000000,
        expected_vstart=0,
        vl=16,
    )


@coralflow_test
async def lsu_fault_scalar_mixed_rs_flush(fixture):
    """Testbench to verify scalar store fault purges follow-on vector store in RS (Scalar -> Vector)."""
    await _setup_lsu_fault_fixture(fixture)
    await _run_and_verify_lsu_fault(
        fixture,
        test_fn_symbol='run_scalar_mixed_fault_rs_flush',
        faulting_insn_symbol='faulting_insn_scalar_mixed',
        expected_mcause=7,
        expected_mtval=fixture.symbols['__data_start__'] - 4,
        expected_vstart=0,
    )


@coralflow_test
async def lsu_fault_scalar_to_scalar_rs_flush(fixture):
    """Testbench to verify scalar store fault purges follow-on scalar stores in RS (Scalar -> Scalar)."""
    await _setup_lsu_fault_fixture(fixture)
    await _run_and_verify_lsu_fault(
        fixture,
        test_fn_symbol='run_scalar_to_scalar_fault_rs_flush',
        faulting_insn_symbol='faulting_insn_scalar_scalar',
        expected_mcause=7,
        expected_mtval=fixture.symbols['__data_start__'] - 4,
        expected_vstart=0,
    )


@coralflow_test
async def lsu_decode_test(fixture):
    """Testbench to verify illegal RVV load/store encodings and vtype configurations raise mcause=2."""
    subtests = [
        'vluxei64_v',
        'vsuxei64_v',
        'vluxei16_emul_over_8',
        'vsuxei16_emul_over_8',
        'vloxei32_emul_over_8',
        'vsoxei32_emul_over_8',
        'vlm_invalid_eew16',
        'vsm_invalid_eew16',
        'vl1re64_v',
        'vs1r_invalid_eew16',
        'vs1r_invalid_eew32',
        'vs1r_invalid_eew64',
        'vl3re8_invalid_nf',
        'vs3r_invalid_nf',
        'vl2re16_unaligned_vd',
        'vs4r_unaligned_vs3',
        'vl1re8_masked_vm0',
        'vs1r_masked_vm0',
        'vsbff_invalid_store_ff',
        'vle16_emul_over_8',
        'vse16_emul_over_8',
        'vlse32_emul_over_8',
        'vsse32_emul_over_8',
        'vlseg2e16_emul_over_8',
        'vle8_emul_under_mf4',
        'vluxei8_emul_under_mf4',
        'vle16_unaligned_vd',
        'vluxei16_unaligned_vs2',
        'vlseg4e8_vd_wrap',
        'vle8_masked_vd_v0',
        'vluxei16_narrow_overlap',
        'vluxei8_widen_low_overlap',
        'vluxei8_widen_frac_overlap',
        'vluxseg2ei8_overlap',
    ]

    r = runfiles.Create()
    await fixture.load_elf_and_lookup_symbols(
        r.Rlocation(
            'coralnpu_hw/tests/cocotb/rvv/load_store/lsu_decode_test.elf'
        ),
        ['test_fn', 'fault_count', 'fault_mcause'] + subtests,
    )

    for subtest in subtests:
        await fixture.write_word('fault_count', 0)
        await fixture.write_word('fault_mcause', 0)
        await fixture.write_ptr('test_fn', subtest)
        await fixture.run_to_halt()

        fault_count = await fixture.read_word('fault_count')
        assert fault_count == 1, (
            f"[{subtest}] Expected 1 illegal-instruction fault, got {fault_count}"
        )
        fault_mcause = await fixture.read_word('fault_mcause')
        assert fault_mcause == 2, (
            f"[{subtest}] Expected mcause=2 (Illegal instruction), got {fault_mcause}"
        )


@coralflow_test
async def load_store8_test(fixture):
    """Testbench to test RVV load."""
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

    await fixture.write(target_in_addr, input_data)
    await fixture.write('in_ptr', np.array([target_in_addr], dtype=np.uint32))
    await fixture.write(
        'out_ptr', np.array([target_out_addr], dtype=np.uint32)
    )
    await fixture.write('vl', np.array([vl], dtype=np.uint32))

    await fixture.run_to_halt()

    routputs = (await fixture.read(target_out_addr, vl)).view(np.uint8)
    assert (input_data == routputs).all()


@coralflow_test
async def load_unit_all_vtypes_test(fixture):
    """Testbench to test RVV Unit/segmented loads, with all vtypes."""
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


@coralflow_test
async def store_unit_all_vtypes_test(fixture):
    """Testbench to test RVV Unit/segmented stores, with all vtypes."""
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


@coralflow_test
async def load_strided_all_vtypes_test(fixture):
    """Testbench to test RVV strided/segmented loads, with all vtypes."""
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


@coralflow_test
async def store_strided_all_vtypes_test(fixture):
    """Testbench to test RVV strided/segmented store, with all vtypes."""
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


@coralflow_test
async def load_store_whole_register_test(fixture):
    """Testbench to test RVV strided/segmented store, with all vtypes."""
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
        ['vl', 'vtype', 'load_data', 'store_data', 'impl'] +
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


@coralflow_test
async def whole_reg_repro(fixture):
    """Testbench to run whole_reg_repro."""
    r = runfiles.Create()
    await fixture.load_elf_and_lookup_symbols(
        r.Rlocation(
            'coralnpu_hw/tests/cocotb/rvv/load_store/whole_reg_repro.elf'
        ),
        [],
    )
    await fixture.run_to_halt()


async def load_store_stride_masked_param(fixture, cases):
    """Testbench for parameterized load store stride mask usage accessible from intrinsics."""
    r = runfiles.Create()
    await fixture.load_elf_and_lookup_symbols(
        r.Rlocation(
            'coralnpu_hw/tests/cocotb/rvv/load_store/load_store_stride_masked_param.elf'
        ),
        [
            'rvv_stride_mask',
            'input_data8',
            'output_data8',
            'output_stride_store8',
            'input_data16',
            'output_data16',
            'output_stride_store16',
            'input_data32',
            'output_data32',
            'output_stride_store32',
            'input_stride',
            'input_mask',
            'n',
        ] + [c['rvv_stride_mask'] for c in cases],
    )
    rng = np.random.default_rng()
    for c in tqdm.tqdm(cases):
        stride_mask = c['rvv_stride_mask']
        n = c['n']
        bstride = c['bstride']
        dtype = c['dtype']

        input_stride = 'input_stride'
        input_mask = 'input_mask'
        if dtype == np.uint8:
            input_data_buf = 'input_data8'
            output_data_buf = 'output_data8'
            output_stride_store_buf = 'output_stride_store8'
        elif dtype == np.uint16:
            input_data_buf = 'input_data16'
            output_data_buf = 'output_data16'
            output_stride_store_buf = 'output_stride_store16'
        elif dtype == np.uint32:
            input_data_buf = 'input_data32'
            output_data_buf = 'output_data32'
            output_stride_store_buf = 'output_stride_store32'

        array_size = 1024
        itemsize = np.dtype(dtype).itemsize
        mask_bytes = rng.integers(0, 256, size=32, dtype=np.uint8)
        data_unmodified = np.arange(array_size, dtype=dtype)
        expected_output = np.zeros(n, dtype=dtype)
        stride_step = bstride // itemsize
        span_elements = ((n - 1) * stride_step + 1) if n > 0 else 0
        expected_stride_output = np.zeros(span_elements, dtype=dtype)
        for i in range(n):
            is_active = bool((mask_bytes[i // 8] >> (i % 8)) & 1)
            if is_active:
                src_idx = i * stride_step
                expected_output[i] = data_unmodified[src_idx]
                expected_stride_output[src_idx] = expected_output[i]
        await fixture.write(output_data_buf, np.zeros(n, dtype=dtype))
        await fixture.write(
            output_stride_store_buf, np.zeros(span_elements, dtype=dtype)
        )
        await fixture.write_ptr('rvv_stride_mask', stride_mask)
        await fixture.write_word('n', n)
        await fixture.write(input_stride, np.array([bstride], dtype=np.uint32))
        await fixture.write("input_mask", mask_bytes)
        await fixture.write(input_data_buf, data_unmodified)
        await fixture.run_to_halt()
        actual_output = np.array(
            await fixture.read(output_data_buf,
                               n * np.dtype(dtype).itemsize)
        ).view(dtype)
        stride_output = np.array(
            await fixture.read(
                output_stride_store_buf,
                (span_elements) * np.dtype(dtype).itemsize
            )
        ).view(dtype)
        debug_msg = str({
            'rvv_stride_mask': stride_mask,
            'input_data': input_data_buf,
            'n': n,
            'input_stride': bstride,
            'input_mask': input_mask,
            'actual_output': actual_output,
            'expected_output': expected_output,
            'stride_output': stride_output,
            'expected_stride_output': expected_stride_output,
        })
        assert (actual_output == expected_output).all(), debug_msg
        assert (stride_output == expected_stride_output).all(), debug_msg


@coralflow_test
async def load_store_stride_masked_param_test(fixture):
    """Testbench cases for parameterized load store stride mask."""
    cases = [{
        'rvv_stride_mask': 'vstride_mask_u8mf4',
        'n': n,
        'bstride': bstride,
        'dtype': np.uint8,
    }
             for n in range(0, 6, 2)
             for bstride in range(0, 18, 2)] + [{
                 'rvv_stride_mask': 'vstride_mask_u8mf2',
                 'n': n,
                 'bstride': bstride,
                 'dtype': np.uint8,
             } for n in range(0, 10, 2) for bstride in range(0, 18, 2)] + [
                 {
                     'rvv_stride_mask': 'vstride_mask_u8m1',
                     'n': n,
                     'bstride': bstride,
                     'dtype': np.uint8,
                 } for n in range(0, 18, 2) for bstride in range(0, 18, 2)
             ] + [{
                 'rvv_stride_mask': 'vstride_mask_u8m2',
                 'n': n,
                 'bstride': bstride,
                 'dtype': np.uint8,
             } for n in range(0, 34, 2) for bstride in range(0, 18, 2)] + [
                 {
                     'rvv_stride_mask': 'vstride_mask_u8m4',
                     'n': n,
                     'bstride': bstride,
                     'dtype': np.uint8,
                 } for n in range(0, 66, 2) for bstride in range(0, 18, 2)
             ] + [{
                 'rvv_stride_mask': 'vstride_mask_u8m8',
                 'n': n,
                 'bstride': bstride,
                 'dtype': np.uint8,
             } for n in range(0, 66, 2) for bstride in range(0, 18, 2)] + [
                 {
                     'rvv_stride_mask': 'vstride_mask_u16mf2',
                     'n': n,
                     'bstride': bstride,
                     'dtype': np.uint16,
                 } for n in range(0, 6, 2) for bstride in range(0, 18, 2)
             ] + [{
                 'rvv_stride_mask': 'vstride_mask_u16m1',
                 'n': n,
                 'bstride': bstride,
                 'dtype': np.uint16,
             } for n in range(0, 10, 2) for bstride in range(0, 18, 2)] + [
                 {
                     'rvv_stride_mask': 'vstride_mask_u16m2',
                     'n': n,
                     'bstride': bstride,
                     'dtype': np.uint16,
                 } for n in range(0, 18, 2) for bstride in range(0, 18, 2)
             ] + [{
                 'rvv_stride_mask': 'vstride_mask_u16m4',
                 'n': n,
                 'bstride': bstride,
                 'dtype': np.uint16,
             } for n in range(0, 34, 2) for bstride in range(0, 18, 2)] + [
                 {
                     'rvv_stride_mask': 'vstride_mask_u16m8',
                     'n': n,
                     'bstride': bstride,
                     'dtype': np.uint16,
                 } for n in range(0, 66, 2) for bstride in range(0, 18, 2)
             ] + [{
                 'rvv_stride_mask': 'vstride_mask_u32m1',
                 'n': n,
                 'bstride': bstride,
                 'dtype': np.uint32,
             } for n in range(0, 6, 2) for bstride in range(0, 24, 4)] + [
                 {
                     'rvv_stride_mask': 'vstride_mask_u32m2',
                     'n': n,
                     'bstride': bstride,
                     'dtype': np.uint32,
                 } for n in range(0, 10, 2) for bstride in range(0, 24, 4)
             ] + [{
                 'rvv_stride_mask': 'vstride_mask_u32m4',
                 'n': n,
                 'bstride': bstride,
                 'dtype': np.uint32,
             }
                  for n in range(0, 18, 2)
                  for bstride in range(0, 24, 4)] + [{
                      'rvv_stride_mask': 'vstride_mask_u32m8',
                      'n': n,
                      'bstride': bstride,
                      'dtype': np.uint32,
                  } for n in range(0, 34, 2) for bstride in range(0, 24, 4)]
    await load_store_stride_masked_param(fixture, cases)


@coralflow_test
async def load_store_stride_masked_test(fixture):
    """Testbench for constant load store stride mask usage accessible from intrinsics."""
    r = runfiles.Create()
    await fixture.load_elf_and_lookup_symbols(
        r.Rlocation(
            'coralnpu_hw/tests/cocotb/rvv/load_store/load_store_stride_masked.elf'
        ), [
            'input_data',
            'output_data',
            'output_stride_store',
            'input_stride',
            'input_mask',
            'n',
        ]
    )
    n = 'n'

    itemsize = np.dtype(np.uint32).itemsize
    data_unmodified = np.arange(512, dtype=np.uint32)
    bstride = 8
    mask_array = 0b1111111111111111
    expected_output = np.zeros(512, dtype=np.uint32)
    expected_stride_output = np.zeros(512, dtype=np.uint32)
    n_elements = 10
    for i in range(n_elements):
        is_active = (mask_array >> i) & 1

        if is_active:
            expected_output[i] = data_unmodified[i * (bstride // itemsize)]
            expected_stride_output[i * (bstride // itemsize)
                                   ] = expected_output[i]

    input_data_buf = 'input_data'
    output_data_buf = 'output_data'
    output_stride_store_buf = 'output_stride_store'
    input_stride = 'input_stride'
    input_mask = 'input_mask'

    await fixture.write(input_data_buf, data_unmodified)
    await fixture.write(input_stride, np.array([bstride], dtype=np.uint32))
    await fixture.write(input_mask, np.array([mask_array], dtype=np.uint32))
    await fixture.run_to_halt()
    actual_output = (await fixture.read(output_data_buf,
                                        512 * itemsize)).view(np.uint32)
    stride_output = (
        await fixture.read(output_stride_store_buf, 512 * itemsize)
    ).view(np.uint32)

    debug_msg = str({
        'input_data': input_data_buf,
        'n': n,
        'input_stride': input_stride,
        'input_mask': input_mask,
        'actual': actual_output,
        'expected': expected_output,
        'output_stride_store': output_stride_store_buf,
        'expected_stride_store': expected_stride_output,
    })
    assert (actual_output == expected_output).all(), debug_msg
    assert (stride_output == expected_stride_output).all(), debug_msg


@coralflow_test
async def load_unit_ff_fault(fixture):
    """Verify RVV §7.7 & §7.8 fault-only-first load behavior."""
    r = runfiles.Create()
    await fixture.load_elf_and_lookup_symbols(
        r.Rlocation(
            'coralnpu_hw/tests/cocotb/rvv/load_store/load_unit_ff_fault.elf'
        ),
        [
            'impl',
            'fault_count',
            'fault_mcause',
            'fault_mtval',
            'fault_vstart',
            'req_vl',
            'req_vtype',
            'req_vstart',
            'load_filler',
            'load_addr',
            'post_vl',
            'post_vstart',
            'mask_data',
            'dtcm_top_snap',
            'store_data',
            'dep_data',
            'test_vle8ff_unmasked',
            'test_vle16ff_unmasked',
            'test_vle32ff_unmasked',
            'test_vle8ff_masked',
            'test_vle16ff_masked',
            'test_vlseg2e16ff_unmasked',
            'test_vlseg3e32ff_unmasked',
        ],
    )

    axi_base = fixture.core_mini_axi.memory_base_addr
    axi_size = len(fixture.core_mini_axi.memory)
    axi_end = axi_base + axi_size
    dtcm_end = 0x00018000

    # Seed the last 128 bytes of AXI memory with deterministic non-trivial values.
    pattern = np.array([(i * 13 + 0x21) & 0xFF for i in range(128)],
                       dtype=np.uint8)
    fixture.core_mini_axi.memory[axi_size - 128:axi_size] = pattern

    async def run_ff_case(
        fn_name,
        vtype,
        vl,
        addr,
        vstart=0,
        mask_bytes=None,
        filler=0x5A5A5A5A
    ):
        if mask_bytes is None:
            mask_arr = np.full(16, 0xFF, dtype=np.uint8)
        else:
            mask_arr = np.zeros(16, dtype=np.uint8)
            mask_arr[:len(mask_bytes)] = np.array(mask_bytes, dtype=np.uint8)
        await fixture.write_ptr('impl', fn_name)
        await fixture.write_word('req_vl', vl)
        await fixture.write_word('req_vtype', vtype)
        await fixture.write_word('req_vstart', vstart)
        await fixture.write_word('load_filler', filler)
        await fixture.write_word('load_addr', addr)
        await fixture.write('mask_data', mask_arr)
        await fixture.run_to_halt()
        fc = await fixture.read_word('fault_count')
        f_mcause = await fixture.read_word('fault_mcause')
        f_mtval = await fixture.read_word('fault_mtval')
        p_vl = await fixture.read_word('post_vl')
        p_vs = await fixture.read_word('post_vstart')
        v8_dump = await fixture.read('store_data', 128)
        v16_dump = await fixture.read('dep_data', 128)
        return fc, f_mcause, f_mtval, p_vl, p_vs, v8_dump, v16_dump

    # 1. Unmasked vle8ff / vle16ff / vle32ff faulting at element k > 0 (vta=0 and vta=1, m1 and m2)
    unmasked_cases = [
        # (fn, dtype, lmul_enc, vta, req_vl, valid_elems)
        ('test_vle8ff_unmasked', np.uint8, 0b000, 0, 16, 5),
        ('test_vle8ff_unmasked', np.uint8, 0b001, 1, 32, 19),
        ('test_vle16ff_unmasked', np.uint16, 0b000, 0, 8, 3),
        ('test_vle16ff_unmasked', np.uint16, 0b001, 1, 16, 11),
        ('test_vle32ff_unmasked', np.uint32, 0b000, 0, 4, 2),
        ('test_vle32ff_unmasked', np.uint32, 0b001, 0, 8, 5),
    ]
    for fn, dtype, lmul_enc, vta, req_vl, k in unmasked_cases:
        ebytes = np.dtype(dtype).itemsize
        valid_bytes = k * ebytes
        addr = axi_end - valid_bytes
        vtype = construct_vtype(1, vta, DTYPE_TO_SEW[dtype], lmul_enc)
        fc, mcause, _, p_vl, p_vs, v8_raw, v16_raw = await run_ff_case(
            fn, vtype, req_vl, addr
        )
        assert fc == 0, f"{fn} (k={k}, vta={vta}) trapped unexpectedly with mcause={mcause}"
        assert p_vl == k, f"{fn} expected post_vl={k}, got {p_vl}"
        assert p_vs == 0, f"{fn} expected post_vstart=0, got {p_vs}"

        expected_load = pattern[128 - valid_bytes:128].view(dtype)
        actual_v8 = v8_raw.view(dtype)
        actual_v16 = v16_raw.view(dtype)
        assert np.array_equal(
            actual_v8[:k], expected_load
        ), f"{fn} active prefix mismatch: got {actual_v8[:k]}, expected {expected_load}"
        mask_mod = (1 << (8 * ebytes)) - 1
        undisturbed_val = 0x5A5A5A5A & mask_mod
        allowed_tail = (undisturbed_val,
                        mask_mod) if vta else (undisturbed_val, )
        for idx in range(k, req_vl):
            assert int(actual_v8[idx]) in allowed_tail, (
                f"{fn} tail elem {idx} expected one of {[hex(v) for v in allowed_tail]}, "
                f"got 0x{int(actual_v8[idx]):x}"
            )
        # Dependent vadd.vi v16, v8, 1 WITHOUT vsetvl must only update elements 0..k-1
        # (if ffPending interlock were missing, v16[idx>=k] would become (v8[idx]+1) = 0x5b/0x00).
        for idx in range(k):
            exp_dep = (int(expected_load[idx]) + 1) & mask_mod
            assert int(actual_v16[idx]) == exp_dep, (
                f"{fn} dep v16[{idx}] expected 0x{exp_dep:x}, got 0x{int(actual_v16[idx]):x}"
            )
        dep_init = 0x33333333 & mask_mod
        allowed_dep_tail = (dep_init, mask_mod) if vta else (dep_init, )
        for idx in range(k, req_vl):
            assert int(actual_v16[idx]) in allowed_dep_tail, (
                f"{fn} dep tail v16[{idx}] overwritten (missing decode interlock?): "
                f"got 0x{int(actual_v16[idx]):x}, expected one of {[hex(v) for v in allowed_dep_tail]}"
            )

    # 2. Unaligned cross-boundary element fault: vle32ff at axi_end - 6 (elem 0 valid, elem 1 half-valid/half-fault)
    vtype_e32_tu = construct_vtype(1, 0, DTYPE_TO_SEW[np.uint32], 0b000)
    fc, mcause, _, p_vl, _, v8_raw, _ = await run_ff_case(
        'test_vle32ff_unmasked', vtype_e32_tu, 4, axi_end - 6
    )
    assert fc == 0, f"unaligned vle32ff trapped unexpectedly: mcause={mcause}"
    assert p_vl == 1, f"unaligned vle32ff expected vl=1, got {p_vl}"
    v8_u32 = v8_raw.view(np.uint32)
    exp_elem0 = pattern[128 - 6:128 - 2].view(np.uint32)[0]
    assert v8_u32[0] == exp_elem0
    assert v8_u32[
        1
    ] == 0x5A5A5A5A, f"unaligned vle32ff corrupted partial faulting elem 1: 0x{int(v8_u32[1]):08x}"

    # 3. Fast DTCM (0x17FF0..0x17FFF) -> slow ebus (0x18000 SLVERR) cross-bus race check
    vtype_e8_m2_tu = construct_vtype(1, 0, DTYPE_TO_SEW[np.uint8], 0b001)
    fc, mcause, _, p_vl, _, v8_raw, _ = await run_ff_case(
        'test_vle8ff_unmasked', vtype_e8_m2_tu, 24, dtcm_end - 12
    )
    dtcm_tail = await fixture.read('dtcm_top_snap', 16)
    assert fc == 0 and p_vl == 12, f"DTCM->ebus vle8ff failed: fc={fc}, mcause={mcause}, vl={p_vl}"
    assert np.array_equal(v8_raw[:12], dtcm_tail[4:16])
    assert np.all(v8_raw[12:24] == 0x5A)

    # 4. Masked vle8ff / vle16ff cases
    vtype_e8_mu_tu = construct_vtype(0, 0, DTYPE_TO_SEW[np.uint8], 0b000)
    # 4a: Masked-off elements at >= k (faulting addresses) must NOT fault or reduce vl!
    fc, _, _, p_vl, _, v8_raw, _ = await run_ff_case(
        'test_vle8ff_masked',
        vtype_e8_mu_tu,
        8,
        axi_end - 4,
        mask_bytes=[0b00001111]
    )
    assert fc == 0 and p_vl == 8, f"masked-off tail should not reduce vl: fc={fc}, vl={p_vl}"
    assert np.array_equal(v8_raw[:4], pattern[124:128])
    assert np.all(v8_raw[4:8] == 0x5A)

    # 4b: Element 0 masked-off at faulting address, element 2 active at faulting address -> NO trap, vl=2!
    fc, mcause, _, p_vl, _, v8_raw, _ = await run_ff_case(
        'test_vle8ff_masked',
        vtype_e8_mu_tu,
        8,
        axi_end,
        mask_bytes=[0b00000100]
    )
    assert fc == 0 and p_vl == 2, f"elem0 masked-off + elem2 fault failed: fc={fc}, mcause={mcause}, vl={p_vl}"
    assert np.all(v8_raw[:8] == 0x5A)

    # 4c: Mixed active/inactive before active fault at k=5
    fc, _, _, p_vl, _, v8_raw, _ = await run_ff_case(
        'test_vle8ff_masked',
        vtype_e8_mu_tu,
        8,
        axi_end - 5,
        mask_bytes=[0b00101011]
    )
    assert fc == 0 and p_vl == 5, f"masked active fault at k=5 failed: fc={fc}, vl={p_vl}"
    for idx in range(5):
        exp_b = pattern[123 + idx] if ((0b00101011 >> idx) & 1) else 0x5A
        assert v8_raw[idx] == exp_b
    assert np.all(v8_raw[5:8] == 0x5A)

    # 5. vstart = 2 < k = 5 on vle16ff: prestart 0..1 preserved, 2..4 loaded, >=5 undisturbed, vl=5, vstart=0
    vtype_e16_tu = construct_vtype(1, 0, DTYPE_TO_SEW[np.uint16], 0b000)
    fc, _, _, p_vl, p_vs, v8_raw, _ = await run_ff_case(
        'test_vle16ff_unmasked', vtype_e16_tu, 8, axi_end - 10, vstart=2
    )
    assert fc == 0 and p_vl == 5 and p_vs == 0, f"vstart=2 vle16ff failed: fc={fc}, vl={p_vl}, vs={p_vs}"
    v8_u16 = v8_raw.view(np.uint16)
    exp_u16 = pattern[118:128].view(np.uint16)
    assert v8_u16[0] == 0x5A5A and v8_u16[1] == 0x5A5A
    assert np.array_equal(v8_u16[2:5], exp_u16[2:5])
    assert np.all(v8_u16[5:8] == 0x5A5A)

    # 6. Segment fault-only-first: vlseg3e32ff faulting on field 2 of segment k=1 (fields 0..1 in valid AXI!)
    # Segment 0: 12B at axi_end - 20 .. axi_end - 9 (OK)
    # Segment 1: field 0 at -8..-5 (OK), field 1 at -4..-1 (OK), field 2 at axi_end (FAULT!)
    fc, mcause, _, p_vl, _, v8_raw, _ = await run_ff_case(
        'test_vlseg3e32ff_unmasked', vtype_e32_tu, 4, axi_end - 20
    )
    assert fc == 0 and p_vl == 1, f"vlseg3e32ff seg1 field2 fault failed: fc={fc}, mcause={mcause}, vl={p_vl}"
    seg_u32 = v8_raw.view(np.uint32)
    exp_seg0 = pattern[108:120].view(np.uint32)
    # v8 = seg_u32[0..3], v9 = seg_u32[4..7], v10 = seg_u32[8..11]
    for f in range(3):
        assert seg_u32[f * 4 + 0] == exp_seg0[f]
        assert np.all(seg_u32[f * 4 + 1:f * 4 + 4] == 0x5A5A5A5A
                      ), (f"vlseg3e32ff field {f} corrupted at segment >= 1!")

    # 7. Element 0 / Segment 0 active fault MUST trap with mcause=5, preserve vl, and NOT overwrite vd!
    # 7a: vle8ff at axi_end
    fc, mcause, mtval, p_vl, _, v8_raw, _ = await run_ff_case(
        'test_vle8ff_unmasked',
        construct_vtype(1, 0, DTYPE_TO_SEW[np.uint8], 0b000), 12, axi_end
    )
    assert fc == 1 and mcause == 5 and mtval == axi_end and p_vl == 12, (
        f"vle8ff elem0 fault mismatch: fc={fc}, mcause={mcause}, mtval=0x{mtval:x}, vl={p_vl}"
    )
    assert np.all(v8_raw[:16] == 0x5A)

    # 7b: vlseg3e32ff at dtcm_end - 8 (segment 0 fields 0..1 in fast DTCM, field 2 at 0x18000 faults!)
    fc, mcause, mtval, p_vl, _, v8_raw, _ = await run_ff_case(
        'test_vlseg3e32ff_unmasked', vtype_e32_tu, 4, dtcm_end - 8
    )
    assert fc == 1 and mcause == 5 and mtval == dtcm_end and p_vl == 4, (
        f"vlseg3e32ff seg0 field2 fault mismatch: fc={fc}, mcause={mcause}, mtval=0x{mtval:x}, vl={p_vl}"
    )
    assert np.all(v8_raw.view(np.uint32)[:12] == 0x5A5A5A5A
                  ), ("vlseg3e32ff seg0 trap leaked early writeback to VRF!")


if __name__ == "__main__":
    coralflow_main()
