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
import tqdm
import re
import numpy as np
import os

from bazel_tools.tools.python.runfiles import runfiles
from coralnpu_test_utils.sim_test_fixture import Fixture

STR_TO_NP_TYPE = {
    "int8": np.int8,
    "int16": np.int16,
    "int32": np.int32,
    "uint8": np.uint8,
    "uint16": np.uint16,
    "uint32": np.uint32,
    "float": np.float32,
}


def _get_math_result(x: np.array, y: np.array, symbol: str, dtype=None):
    if symbol == "add" or symbol == "fadd":
        return np.add(x, y, dtype=dtype)
    elif symbol == "sub" or symbol == "fsub":
        return np.subtract(x, y, dtype=dtype)
    elif symbol == "mul" or symbol == "fmul":
        return np.multiply(x, y, dtype=dtype)
    elif symbol == "fdiv":
        orig_settings = np.seterr(divide="ignore")
        divide_output = np.divide(x, y, dtype=dtype)
        np.seterr(**orig_settings)
        return divide_output
    elif symbol == "and":
        return np.bitwise_and(x, y)
    elif symbol == "or":
        return np.bitwise_or(x, y)
    elif symbol == "xor":
        return np.bitwise_xor(x, y)
    elif symbol == "min" or symbol == "minu":
        return np.minimum(x, y)
    elif symbol == "max" or symbol == "maxu":
        return np.maximum(x, y)
    elif symbol == "sadd" or symbol == "saddu":
        return reference_sadd(x, y)
    elif symbol == "ssub" or symbol == "ssubu":
        return reference_ssub(x, y)
    elif symbol == "aadd" or symbol == "aaddu":
        return reference_aadd(x, y)
    elif symbol == "asub" or symbol == "asubu":
        return reference_asub(x, y)
    elif symbol == "smul":
        return reference_smul(x, y)
    elif symbol == "ssra":
        return reference_ssra(x, y)
    elif symbol == "ssrl":
        return reference_ssrl(x, y)
    elif symbol == "mulh" or symbol == "mulhu":
        return reference_vmulh(x, y)
    elif symbol == "div" or symbol == "divu":
        return reference_div(x, y)
    elif symbol == "sll":
        return reference_sll(x, y)
    elif symbol == "srl":
        return reference_srl(x, y)
    elif symbol == "sra":
        return reference_sra(x, y)
    elif symbol == "rem" or symbol == "remu":
        return reference_rem(x, y)
    elif symbol == "redsum" or symbol == "fredusum":
        return y[0] + np.add.reduce(x)
    elif symbol == "redmin" or symbol == "fredmin":
        return np.min(np.concatenate((x, y)))
    elif symbol == "redmax" or symbol == "fredmax":
        return np.max(np.concatenate((x, y)))
    elif symbol == "redand":
        return np.bitwise_and.reduce(np.concatenate((x, y)))
    elif symbol == "redor":
        return np.bitwise_or.reduce(np.concatenate((x, y)))
    elif symbol == "redxor":
        return np.bitwise_xor.reduce(np.concatenate((x, y)))
    raise ValueError(f"Unsupported math symbol: {symbol}")


async def arithmetic_m1_vanilla_ops_test(dut, dtypes, math_ops: list, num_bytes: int):
    """RVV arithmetic test template.

    Each test performs a math op loading `in_buf_1` and `in_buf_2` and storing the output to `out_buf`.
    """
    m1_vanilla_op_elfs = [
        f"rvv_{math_op}_{dtype}_m1.elf"
        for math_op in math_ops
        for dtype in dtypes
        if not (math_op == "smul" and dtype.startswith("u"))
        and not (math_op in ["sra", "ssra"] and dtype.startswith("u"))
        and not (math_op in ["srl", "ssrl"] and dtype.startswith("i"))
    ]
    pattern_extract = re.compile("rvv_(.*)_(.*)_m1.elf")

    r = runfiles.Create()
    fixture = await Fixture.Create(dut)
    with tqdm.tqdm(m1_vanilla_op_elfs) as t:
        for elf_name in tqdm.tqdm(m1_vanilla_op_elfs):
            t.set_postfix({"binary": os.path.basename(elf_name)})
            elf_path = r.Rlocation(
                "coralnpu_hw/tests/cocotb/rvv/arithmetics/" + elf_name
            )
            await fixture.load_elf_and_lookup_symbols(
                elf_path,
                ["in_buf_1", "in_buf_2", "out_buf"],
            )
            math_op, dtype = pattern_extract.match(elf_name).groups()
            np_type = STR_TO_NP_TYPE[dtype]
            num_test_values = int(num_bytes / np.dtype(np_type).itemsize)
            if np.issubdtype(np_type, np.integer):
                min_value = np.iinfo(np_type).min
                max_value = np.iinfo(np_type).max + 1  # One above.
                input_1 = np.random.randint(
                    min_value, max_value, num_test_values, dtype=np_type
                )
                input_2 = np.random.randint(
                    min_value, max_value, num_test_values, dtype=np_type
                )
            else:
                input_1 = np.random.uniform(-10, 10, num_test_values).astype(np_type)
                input_2 = np.random.uniform(-10, 10, num_test_values).astype(np_type)

            expected_output = np.asarray(
                _get_math_result(input_1, input_2, math_op), dtype=np_type
            )

            await fixture.write("in_buf_1", input_1)
            await fixture.write("in_buf_2", input_2)
            await fixture.write("out_buf", np.zeros([num_test_values], dtype=np_type))

            await fixture.run_to_halt()

            actual_output = (await fixture.read("out_buf", num_bytes)).view(np_type)
            debug_msg = str(
                {
                    "input_1": input_1,
                    "input_2": input_2,
                    "expected": expected_output,
                    "actual": actual_output,
                }
            )

            if np.issubdtype(np_type, np.integer):
                assert (actual_output == expected_output).all(), debug_msg
            else:
                assert np.allclose(
                    actual_output, expected_output, rtol=1e-5, atol=1e-8
                ), debug_msg


@cocotb.test()
async def arithmetic_m1_vanilla_ops(dut):
    await arithmetic_m1_vanilla_ops_test(
        dut=dut,
        dtypes=["int8", "int16", "int32", "uint8", "uint16", "uint32"],
        math_ops=[
            "add",
            "sub",
            "mul",
            "div",
            "and",
            "or",
            "xor",
            "min",
            "max",
            "sadd",
            "ssub",
            "aadd",
            "asub",
            "smul",
            "mulh",
            "rem",
            "sll",
            "srl",
            "sra",
            "ssra",
            "ssrl",
        ],
        num_bytes=16,
    )


@cocotb.test()
async def float32_arithmetic_m1_vanilla_ops(dut):
    await arithmetic_m1_vanilla_ops_test(
        dut=dut,
        dtypes=["float"],
        math_ops=["fadd", "fsub", "fmul", "fdiv"],
        num_bytes=16,
    )


async def reduction_m1_vanilla_ops_test(dut, dtypes, math_ops: list, num_bytes: int):
    """RVV reduction test template.

    Each test performs a reduction op loading `in_buf_1` and storing the output to `out_buf`.
    """
    m1_vanilla_op_elfs = [
        f"rvv_{math_op}_{dtype}_m1.elf"
        for math_op in math_ops
        for dtype in dtypes
        if not (math_op == "smul" and dtype.startswith("u"))
        and not (math_op in ["sra", "ssra"] and dtype.startswith("u"))
        and not (math_op in ["srl", "ssrl"] and dtype.startswith("i"))
    ]
    pattern_extract = re.compile("rvv_(.*)_(.*)_m1.elf")

    r = runfiles.Create()
    fixture = await Fixture.Create(dut)
    with tqdm.tqdm(m1_vanilla_op_elfs) as t:
        for elf_name in tqdm.tqdm(m1_vanilla_op_elfs):
            t.set_postfix({"binary": os.path.basename(elf_name)})
            elf_path = r.Rlocation(
                f"coralnpu_hw/tests/cocotb/rvv/arithmetics/{elf_name}"
            )
            await fixture.load_elf_and_lookup_symbols(
                elf_path,
                ["in_buf_1", "scalar_input", "out_buf"],
            )
            math_op, dtype = pattern_extract.match(elf_name).groups()
            np_type = STR_TO_NP_TYPE[dtype]
            itemsize = np.dtype(np_type).itemsize
            num_test_values = int(num_bytes / np.dtype(np_type).itemsize)
            if np.issubdtype(np_type, np.integer):
                min_value = np.iinfo(np_type).min
                max_value = np.iinfo(np_type).max + 1  # One above.
                input_1 = np.random.randint(min_value,
                                            max_value,
                                            num_test_values,
                                            dtype=np_type)
                input_2 = np.random.randint(min_value, max_value, 1, dtype=np_type)
            else:
                input_1 = np.random.uniform(-10, 10, num_test_values).astype(np_type)
                input_2 = np.random.uniform(-10, 10, 1).astype(np_type)

            expected_output = np.asarray(_get_math_result(
                input_1, input_2, math_op),
                                         dtype=np_type)

            await fixture.write('in_buf_1', input_1)
            await fixture.write('scalar_input', input_2)
            await fixture.write('out_buf', np.zeros(1, dtype=np_type))
            try:
                await fixture.run_to_halt(timeout_cycles=1000000)
            except AssertionError as e:
                # If it failed to halt, check if it faulted
                try:
                    faulted = (await fixture.read('faulted', 4)).view(np.uint32)[0]
                    mcause = (await fixture.read('mcause', 4)).view(np.uint32)[0]
                    if faulted:
                        raise RuntimeError(f"Test faulted with mcause 0x{mcause:x}")
                except Exception:
                    pass
                raise e

            actual_output = (await fixture.read("out_buf", itemsize)).view(np_type)
            debug_msg = str(
                {
                    "input_1": input_1,
                    "input_2": input_2,
                    "expected": expected_output,
                    "actual": actual_output,
                }
            )
            if np.issubdtype(np_type, np.integer):
                assert (actual_output == expected_output).all(), debug_msg
            else:
                assert np.allclose(
                    actual_output, expected_output, rtol=1e-5, atol=1e-8
                ), debug_msg


@cocotb.test()
async def reduction_m1_vanilla_ops(dut):
    await reduction_m1_vanilla_ops_test(
        dut=dut,
        dtypes=["int8", "int16", "int32", "uint8", "uint16", "uint32"],
        math_ops=["redsum", "redmin", "redmax", "redand", "redor", "redxor"],
        num_bytes=16,
    )


@cocotb.test()
async def float32_reduction_m1_vanilla_ops(dut):
    await reduction_m1_vanilla_ops_test(
        dut=dut,
        dtypes=["float"],
        math_ops=["fredusum", "fredmin", "fredmax"],
        num_bytes=16,
    )


async def reduction_m1_failure_test(dut, dtypes, math_ops: str, num_bytes: int):
    """RVV reduction test template.

    Each test performs a reduction op loading `in_buf_1` and storing the output to `out_buf`.
    """
    m1_failure_op_elfs = [
        f"rvv_{math_op}_{dtype}_m1.elf" for math_op in math_ops
        for dtype in dtypes
    ]
    pattern_extract = re.compile("rvv_(.*)_(.*)_m1.elf")

    r = runfiles.Create()
    fixture = await Fixture.Create(dut)

    with tqdm.tqdm(m1_failure_op_elfs) as t:
        for elf_name in t:
            t.set_postfix({"binary": os.path.basename(elf_name)})
            elf_path = r.Rlocation(
                f"coralnpu_hw/tests/cocotb/rvv/arithmetics/{elf_name}")
            await fixture.load_elf_and_lookup_symbols(
                elf_path,
                ['in_buf_1', 'scalar_input', 'out_buf', 'vstart', 'vl',
                 'faulted', 'mcause'],
            )
            math_op, dtype = pattern_extract.match(elf_name).groups()
            np_type = STR_TO_NP_TYPE[dtype]
            itemsize = np.dtype(np_type).itemsize
            num_test_values = int(num_bytes / np.dtype(np_type).itemsize)

            min_value = np.iinfo(np_type).min
            max_value = np.iinfo(np_type).max + 1  # One above.
            input_1 = np.random.randint(min_value,
                                        max_value,
                                        num_test_values,
                                        dtype=np_type)
            input_2 = np.random.randint(min_value, max_value, 1, dtype=np_type)

            await fixture.write('in_buf_1', input_1)
            await fixture.write('scalar_input', input_2)
            await fixture.write('vstart', np.array([1], dtype=np.uint32))
            await fixture.write('out_buf', np.zeros(1, dtype=np_type))

            await fixture.run_to_halt()
            faulted = (await fixture.read('faulted', 4)).view(np.uint32)
            mcause = (await fixture.read('mcause', 4)).view(np.uint32)
            assert(faulted == True)
            assert(mcause == 0x2) # Invalid instruction


@cocotb.test()
async def reduction_m1_failure_ops(dut):
    await reduction_m1_failure_test(
        dut=dut,
        dtypes=["int8", "int16", "int32", "uint8", "uint16", "uint32"],
        math_ops=["redsum", "redmin", "redmax"],
        num_bytes=16)


async def _widen_math_ops_test_impl(
    dut,
    dtypes,
    math_ops: str,
    num_test_values: int = 256,
):
    """RVV widen arithmetic test template.

    Each test performs a widen math op on 256 random inputs and stores into output buffer.
    """
    widen_op_elfs = [
        f"rvv_widen_{math_op}_{in_dtype}_{out_dtype}.elf"
        for math_op in math_ops for in_dtype, out_dtype in dtypes
    ]
    pattern_extract = re.compile("rvv_widen_(.*)_(.*)_(.*).elf")

    r = runfiles.Create()
    fixture = await Fixture.Create(dut)
    with tqdm.tqdm(widen_op_elfs) as t:
        for elf_name in tqdm.tqdm(widen_op_elfs):
            t.set_postfix({"binary": os.path.basename(elf_name)})
            elf_path = r.Rlocation("coralnpu_hw/tests/cocotb/rvv/arithmetics/" +
                                   elf_name)
            await fixture.load_elf_and_lookup_symbols(
                elf_path,
                ['in_buf_1', 'in_buf_2', 'out_buf_widen'],
            )
            math_op, in_dtype, out_dtype = pattern_extract.match(
                elf_name).groups()
            in_np_type = STR_TO_NP_TYPE[in_dtype]
            out_np_type = STR_TO_NP_TYPE[out_dtype]

            min_value = np.iinfo(in_np_type).min
            max_value = np.iinfo(in_np_type).max + 1  # One above.
            input_1 = np.random.randint(min_value,
                                        max_value,
                                        num_test_values,
                                        dtype=in_np_type)
            input_2 = np.random.randint(min_value,
                                        max_value,
                                        num_test_values,
                                        dtype=in_np_type)
            expected_output = np.asarray(_get_math_result(input_1,
                                                          input_2,
                                                          math_op,
                                                          dtype=out_np_type),
                                         dtype=out_np_type)
            await fixture.write('in_buf_1', input_1)
            await fixture.write('in_buf_2', input_2)
            await fixture.write('out_buf_widen',
                                np.zeros([num_test_values], dtype=out_np_type))
            await fixture.run_to_halt()

            actual_output = (await fixture.read(
                'out_buf_widen',
                num_test_values *
                np.dtype(out_np_type).itemsize)).view(out_np_type)
            debug_msg = str({
                'input_1': input_1,
                'input_2': input_2,
                'expected': expected_output,
                'actual': actual_output,
            })

            assert (actual_output == expected_output).all(), debug_msg


@cocotb.test()
async def widen_math_ops_test_impl(dut):
    await _widen_math_ops_test_impl(dut=dut,
                                    dtypes=[['int8', 'int16'],
                                            ['int16', 'int32']],
                                    math_ops=['add', 'sub', 'mul'])


async def test_narrowing_math_op(
        dut,
        elf_name: str,
        cases: list[dict],  # keys: impl, vl, in_dtype, maxshift, vxs, saturate
):
    """RVV narrowing instructions test template.

    All these instructions narrow down the input vector elements into half
    width output elements, with:
    - a right shift (A or L, by immediate, scalar or vector)
    - an optional saturation (signed or unsigned accordingly)
      if saturation is selected, the shift result is rounded (see vxrm)
    """
    fixture = await Fixture.Create(dut)
    r = runfiles.Create()
    await fixture.load_elf_and_lookup_symbols(
        r.Rlocation('coralnpu_hw/tests/cocotb/rvv/arithmetics/' + elf_name),
        [
            'impl', 'vl', 'shift_scalar',
            'buf8', 'buf16', 'buf32',
            'buf_shift8', 'buf_shift16'
        ] + list({c['impl'] for c in cases}),
    )

    rng = np.random.default_rng()
    for c in tqdm.tqdm(cases):
        impl = c['impl']
        vl = c['vl']
        in_dtype = c['in_dtype']
        maxshift = c['maxshift']
        vxs = c['vxs']
        saturate = c['saturate']
        if in_dtype == np.int16:
            out_dtype = np.int8
        elif in_dtype == np.uint16:
            out_dtype = np.uint8
        elif in_dtype == np.int32:
            out_dtype = np.int16
        elif in_dtype == np.uint32:
            out_dtype = np.uint16
        else:
            assert False, f"Unsupported in_dtype {in_dtype}"

        input_data = rng.integers(
            0, np.iinfo(in_dtype).max + 1, vl, dtype=in_dtype)
        shift_scalar = rng.integers(0, maxshift + 1, 1, dtype=np.uint32)[0]
        shifts = rng.integers(0, maxshift + 1, vl, dtype=out_dtype)
        if (vxs):
            shift_results = np.bitwise_right_shift(input_data, shift_scalar)
        else:
            shift_results = np.bitwise_right_shift(input_data, shifts)
        if saturate:
            shift_results = np.minimum(shift_results, np.iinfo(out_dtype).max)
            shift_results = np.maximum(shift_results, np.iinfo(out_dtype).min)
        expected_outputs = shift_results.astype(out_dtype)

        await fixture.write_ptr('impl', impl)
        await fixture.write_word('vl', vl)
        await fixture.write_word('shift_scalar', shift_scalar)
        if (in_dtype == np.int16) or (in_dtype == np.uint16):
            await fixture.write('buf16', input_data)
            await fixture.write('buf_shift8', shifts)
        elif (in_dtype == np.int32) or (in_dtype == np.uint32):
            await fixture.write('buf32', input_data)
            await fixture.write('buf_shift16', shifts)

        await fixture.run_to_halt()

        if (out_dtype == np.int8) or (out_dtype == np.uint8):
            actual_outputs = (await fixture.read('buf8', vl))
        elif (out_dtype == np.int16) or (out_dtype == np.uint16):
            actual_outputs = (await fixture.read('buf16', vl * 2))
        actual_outputs = actual_outputs.view(out_dtype)

        debug_msg = str({
            'impl': impl,
            'input': input_data,
            'shift_scalar': shift_scalar,
            'shifts': shifts,
            'expected': expected_outputs,
            'actual': actual_outputs,
        })
        assert (actual_outputs == expected_outputs).all(), debug_msg


@cocotb.test()
async def vnsra_test(dut):
    """Test vnsra usage accessible from intrinsics.

    This covers vncvt (signed).
    """
    def make_test_case(impl, vl, in_dtype, vxs):
        if in_dtype == np.int16:
            maxshift = 15
        elif in_dtype == np.int32:
            maxshift = 31
        else:
            assert False, "Unsupported in_dtype"
        return {
            'impl': impl,
            'vl': vl,
            'in_dtype': in_dtype,
            'maxshift': maxshift,
            'vxs': vxs,
            'saturate': False,
        }

    await test_narrowing_math_op(
        dut = dut,
        elf_name = 'vnsra_test.elf',
        cases = [
            # 32 to 16, vxv
            make_test_case('vnsra_wv_i16mf2', 4, np.int32, vxs=False),
            make_test_case('vnsra_wv_i16mf2', 3, np.int32, vxs=False),
            make_test_case('vnsra_wv_i16m1', 8, np.int32, vxs=False),
            make_test_case('vnsra_wv_i16m1', 7, np.int32, vxs=False),
            make_test_case('vnsra_wv_i16m2', 16, np.int32, vxs=False),
            make_test_case('vnsra_wv_i16m2', 15, np.int32, vxs=False),
            make_test_case('vnsra_wv_i16m4', 32, np.int32, vxs=False),
            make_test_case('vnsra_wv_i16m4', 31, np.int32, vxs=False),
            # 32 to 16, vxs
            make_test_case('vnsra_wx_i16mf2', 4, np.int32, vxs=True),
            make_test_case('vnsra_wx_i16mf2', 3, np.int32, vxs=True),
            make_test_case('vnsra_wx_i16m1', 8, np.int32, vxs=True),
            make_test_case('vnsra_wx_i16m1', 7, np.int32, vxs=True),
            make_test_case('vnsra_wx_i16m2', 16, np.int32, vxs=True),
            make_test_case('vnsra_wx_i16m2', 15, np.int32, vxs=True),
            make_test_case('vnsra_wx_i16m4', 32, np.int32, vxs=True),
            make_test_case('vnsra_wx_i16m4', 31, np.int32, vxs=True),
            # 16 to 8, vxv
            make_test_case('vnsra_wv_i8mf4', 4, np.int16, vxs=False),
            make_test_case('vnsra_wv_i8mf4', 3, np.int16, vxs=False),
            make_test_case('vnsra_wv_i8mf2', 8, np.int16, vxs=False),
            make_test_case('vnsra_wv_i8mf2', 7, np.int16, vxs=False),
            make_test_case('vnsra_wv_i8m1', 16, np.int16, vxs=False),
            make_test_case('vnsra_wv_i8m1', 15, np.int16, vxs=False),
            make_test_case('vnsra_wv_i8m2', 32, np.int16, vxs=False),
            make_test_case('vnsra_wv_i8m2', 31, np.int16, vxs=False),
            make_test_case('vnsra_wv_i8m4', 64, np.int16, vxs=False),
            make_test_case('vnsra_wv_i8m4', 63, np.int16, vxs=False),
            # 16 to 8, vxv
            make_test_case('vnsra_wx_i8mf4', 4, np.int16, vxs=True),
            make_test_case('vnsra_wx_i8mf4', 3, np.int16, vxs=True),
            make_test_case('vnsra_wx_i8mf2', 8, np.int16, vxs=True),
            make_test_case('vnsra_wx_i8mf2', 7, np.int16, vxs=True),
            make_test_case('vnsra_wx_i8m1', 16, np.int16, vxs=True),
            make_test_case('vnsra_wx_i8m1', 15, np.int16, vxs=True),
            make_test_case('vnsra_wx_i8m2', 32, np.int16, vxs=True),
            make_test_case('vnsra_wx_i8m2', 31, np.int16, vxs=True),
            make_test_case('vnsra_wx_i8m4', 64, np.int16, vxs=True),
            make_test_case('vnsra_wx_i8m4', 63, np.int16, vxs=True),
        ],
    )


@cocotb.test()
async def vnsrl_test(dut):
    """Test vnsrl usage accessible from intrinsics.

    This covers vncvt (unsigned).
    """
    def make_test_case(impl, vl, in_dtype, vxs):
        if in_dtype == np.uint16:
            maxshift = 15
        elif in_dtype == np.uint32:
            maxshift = 31
        else:
            assert False, "Unsupported in_dtype"
        return {
            'impl': impl,
            'vl': vl,
            'in_dtype': in_dtype,
            'maxshift': maxshift,
            'vxs': vxs,
            'saturate': False,
        }

    await test_narrowing_math_op(
        dut = dut,
        elf_name = 'vnsrl_test.elf',
        cases = [
            # 32 to 16, vxv
            make_test_case('vnsrl_wv_u16mf2', 4, np.uint32, vxs=False),
            make_test_case('vnsrl_wv_u16mf2', 3, np.uint32, vxs=False),
            make_test_case('vnsrl_wv_u16m1', 8, np.uint32, vxs=False),
            make_test_case('vnsrl_wv_u16m1', 7, np.uint32, vxs=False),
            make_test_case('vnsrl_wv_u16m2', 16, np.uint32, vxs=False),
            make_test_case('vnsrl_wv_u16m2', 15, np.uint32, vxs=False),
            make_test_case('vnsrl_wv_u16m4', 32, np.uint32, vxs=False),
            make_test_case('vnsrl_wv_u16m4', 31, np.uint32, vxs=False),
            # 32 to 16, vxs
            make_test_case('vnsrl_wx_u16mf2', 4, np.uint32, vxs=True),
            make_test_case('vnsrl_wx_u16mf2', 3, np.uint32, vxs=True),
            make_test_case('vnsrl_wx_u16m1', 8, np.uint32, vxs=True),
            make_test_case('vnsrl_wx_u16m1', 7, np.uint32, vxs=True),
            make_test_case('vnsrl_wx_u16m2', 16, np.uint32, vxs=True),
            make_test_case('vnsrl_wx_u16m2', 15, np.uint32, vxs=True),
            make_test_case('vnsrl_wx_u16m4', 32, np.uint32, vxs=True),
            make_test_case('vnsrl_wx_u16m4', 31, np.uint32, vxs=True),
            # 16 to 8, vxv
            make_test_case('vnsrl_wv_u8mf4', 4, np.uint16, vxs=False),
            make_test_case('vnsrl_wv_u8mf4', 3, np.uint16, vxs=False),
            make_test_case('vnsrl_wv_u8mf2', 8, np.uint16, vxs=False),
            make_test_case('vnsrl_wv_u8mf2', 7, np.uint16, vxs=False),
            make_test_case('vnsrl_wv_u8m1', 16, np.uint16, vxs=False),
            make_test_case('vnsrl_wv_u8m1', 15, np.uint16, vxs=False),
            make_test_case('vnsrl_wv_u8m2', 32, np.uint16, vxs=False),
            make_test_case('vnsrl_wv_u8m2', 31, np.uint16, vxs=False),
            make_test_case('vnsrl_wv_u8m4', 64, np.uint16, vxs=False),
            make_test_case('vnsrl_wv_u8m4', 63, np.uint16, vxs=False),
            # 16 to 8, vxv
            make_test_case('vnsrl_wx_u8mf4', 4, np.uint16, vxs=True),
            make_test_case('vnsrl_wx_u8mf4', 3, np.uint16, vxs=True),
            make_test_case('vnsrl_wx_u8mf2', 8, np.uint16, vxs=True),
            make_test_case('vnsrl_wx_u8mf2', 7, np.uint16, vxs=True),
            make_test_case('vnsrl_wx_u8m1', 16, np.uint16, vxs=True),
            make_test_case('vnsrl_wx_u8m1', 15, np.uint16, vxs=True),
            make_test_case('vnsrl_wx_u8m2', 32, np.uint16, vxs=True),
            make_test_case('vnsrl_wx_u8m2', 31, np.uint16, vxs=True),
            make_test_case('vnsrl_wx_u8m4', 64, np.uint16, vxs=True),
            make_test_case('vnsrl_wx_u8m4', 63, np.uint16, vxs=True),
        ],
    )


@cocotb.test()
async def vnclip_test(dut):
    """Test vnclip usage accessible from intrinsics."""
    # TODO(davidgao): test different vxrm here too.
    def make_test_case(impl, vl, in_dtype, vxs):
        if in_dtype == np.int16:
            maxshift = 15
        elif in_dtype == np.int32:
            maxshift = 31
        else:
            assert False, "Unsupported in_dtype"
        return {
            'impl': impl,
            'vl': vl,
            'in_dtype': in_dtype,
            'maxshift': maxshift,
            'vxs': vxs,
            'saturate': True,
        }

    await test_narrowing_math_op(
        dut = dut,
        elf_name = 'vnclip_test.elf',
        cases = [
            # 32 to 16, vxv
            make_test_case('vnclip_wv_i16mf2', 4, np.int32, vxs=False),
            make_test_case('vnclip_wv_i16mf2', 3, np.int32, vxs=False),
            make_test_case('vnclip_wv_i16m1', 8, np.int32, vxs=False),
            make_test_case('vnclip_wv_i16m1', 7, np.int32, vxs=False),
            make_test_case('vnclip_wv_i16m2', 16, np.int32, vxs=False),
            make_test_case('vnclip_wv_i16m2', 15, np.int32, vxs=False),
            make_test_case('vnclip_wv_i16m4', 32, np.int32, vxs=False),
            make_test_case('vnclip_wv_i16m4', 31, np.int32, vxs=False),
            # 32 to 16, vxs
            make_test_case('vnclip_wx_i16mf2', 4, np.int32, vxs=True),
            make_test_case('vnclip_wx_i16mf2', 3, np.int32, vxs=True),
            make_test_case('vnclip_wx_i16m1', 8, np.int32, vxs=True),
            make_test_case('vnclip_wx_i16m1', 7, np.int32, vxs=True),
            make_test_case('vnclip_wx_i16m2', 16, np.int32, vxs=True),
            make_test_case('vnclip_wx_i16m2', 15, np.int32, vxs=True),
            make_test_case('vnclip_wx_i16m4', 32, np.int32, vxs=True),
            make_test_case('vnclip_wx_i16m4', 31, np.int32, vxs=True),
            # 16 to 8, vxv
            make_test_case('vnclip_wv_i8mf4', 4, np.int16, vxs=False),
            make_test_case('vnclip_wv_i8mf4', 3, np.int16, vxs=False),
            make_test_case('vnclip_wv_i8mf2', 8, np.int16, vxs=False),
            make_test_case('vnclip_wv_i8mf2', 7, np.int16, vxs=False),
            make_test_case('vnclip_wv_i8m1', 16, np.int16, vxs=False),
            make_test_case('vnclip_wv_i8m1', 15, np.int16, vxs=False),
            make_test_case('vnclip_wv_i8m2', 32, np.int16, vxs=False),
            make_test_case('vnclip_wv_i8m2', 31, np.int16, vxs=False),
            make_test_case('vnclip_wv_i8m4', 64, np.int16, vxs=False),
            make_test_case('vnclip_wv_i8m4', 63, np.int16, vxs=False),
            # 16 to 8, vxv
            make_test_case('vnclip_wx_i8mf4', 4, np.int16, vxs=True),
            make_test_case('vnclip_wx_i8mf4', 3, np.int16, vxs=True),
            make_test_case('vnclip_wx_i8mf2', 8, np.int16, vxs=True),
            make_test_case('vnclip_wx_i8mf2', 7, np.int16, vxs=True),
            make_test_case('vnclip_wx_i8m1', 16, np.int16, vxs=True),
            make_test_case('vnclip_wx_i8m1', 15, np.int16, vxs=True),
            make_test_case('vnclip_wx_i8m2', 32, np.int16, vxs=True),
            make_test_case('vnclip_wx_i8m2', 31, np.int16, vxs=True),
            make_test_case('vnclip_wx_i8m4', 64, np.int16, vxs=True),
            make_test_case('vnclip_wx_i8m4', 63, np.int16, vxs=True),
        ],
    )


@cocotb.test()
async def vnclip_vxsat_test(dut):
    """Test that vxsat CSR is set after a saturating vnclip operation.

    Per RISC-V Vector Extension v1.0 Section 3.5, when a saturating fixed-point
    operation causes overflow, the vxsat CSR bit must be set to 1.

    This test verifies the vxsat update path by:
    1. Clearing vxsat to 0
    2. Executing vnclip with MAX_INT32 >> 0, which saturates to MAX_INT16
    3. Reading vxsat via csrr and verifying it equals 1

    BUG: Currently fails because wr_vxsat_valid/wr_vxsat signals are connected
    to dead-end local wires in RvvCore.sv instead of output ports.
    """
    fixture = await Fixture.Create(dut)
    r = runfiles.Create()
    await fixture.load_elf_and_lookup_symbols(
        r.Rlocation('coralnpu_hw/tests/cocotb/rvv/arithmetics/vnclip_test.elf'),
        ['impl', 'vnclip_vxsat_check', 'vxsat_result', 'buf32', 'buf16',
         'buf_shift16'],
    )

    # Point impl to our vxsat test function
    await fixture.write_ptr('impl', 'vnclip_vxsat_check')
    await fixture.run_to_halt()

    # Read the vxsat value that was stored to memory
    vxsat_val = (await fixture.read_word("vxsat_result")).view(np.uint32)[0]

    # vxsat should be 1 after saturation occurred
    assert vxsat_val == 1, (
        f"vxsat CSR should be 1 after saturating vnclip operation, "
        f"but got {vxsat_val}. This indicates the vxsat update path is broken."
    )


@cocotb.test()
async def ternary_op_vx(dut):
    r = runfiles.Create()
    fixture = await Fixture.Create(dut)
    test_binaries = [
        ("vmacc_vx_test.elf", SAME_TYPE_TEST_CASES, lambda x, y, z: x + y * z),
        ("vnmsac_vx_test.elf", SAME_TYPE_TEST_CASES, lambda x, y, z: x - y * z),
        ("vmadd_vx_test.elf", SAME_TYPE_TEST_CASES, lambda x, y, z: x * y + z),
        ("vnmsub_vx_test.elf", SAME_TYPE_TEST_CASES, lambda x, y, z: -(x * y) + z),
    ]
    with tqdm.tqdm(test_binaries) as pbar:
        for test_binary, test_cases, expected_fn in pbar:
            pbar.set_postfix({"binary": test_binary})
            test_binary_path = r.Rlocation(
                f"coralnpu_hw/tests/cocotb/rvv/arithmetics/{test_binary}"
            )

            fn_names = list(set([x[0] for x in test_cases]))
            await fixture.load_elf_and_lookup_symbols(
                test_binary_path, ["vl", "vs1", "xs2", "vd", "impl"] + fn_names
            )

            for test_fn_name, vlmax, vs1_dtype, xs2_dtype, vd_dtype in test_cases:
                if test_fn_name not in fixture.symbols:
                    print(f"ERROR: symbol {test_fn_name} not found in {test_binary}")
                    continue
                for vl in [1, vlmax]:
                    rng = np.random.default_rng()
                    vs1_data = rng.integers(
                        np.iinfo(vs1_dtype).min,
                        np.iinfo(vs1_dtype).max + 1,
                        size=vl,
                        dtype=vs1_dtype,
                    )
                    xs2_data = rng.integers(
                        np.iinfo(xs2_dtype).min,
                        np.iinfo(xs2_dtype).max + 1,
                        size=1,
                        dtype=xs2_dtype,
                    )
                    vd_orig_data = rng.integers(
                        np.iinfo(vd_dtype).min,
                        np.iinfo(vd_dtype).max + 1,
                        size=vl,
                        dtype=vd_dtype,
                    )

                    await fixture.write("vl", np.array([vl], dtype=np.uint32))
                    await fixture.write("vs1", vs1_data)
                    await fixture.write("xs2", xs2_data.astype(np.uint32))
                    await fixture.write("vd", vd_orig_data)

                    await fixture.write_ptr("impl", test_fn_name)
                    await fixture.run_to_halt()

                    expected_vd_data = expected_fn(vd_orig_data, xs2_data[0], vs1_data)
                    actual_vd_data = (
                        await fixture.read("vd", vl * np.dtype(vd_dtype).itemsize)
                    ).view(vd_dtype)
                    assert (actual_vd_data == expected_vd_data).all(), (
                        f"binary: {test_binary}, test_fn: {test_fn_name}, vs1: {vs1_data}, xs2: {xs2_data}, vd_orig: {vd_orig_data}, "
                        f"expected: {expected_vd_data}, actual: {actual_vd_data}"
                    )


@cocotb.test()
async def comparison_op_vx(dut):
    r = runfiles.Create()
    fixture = await Fixture.Create(dut)
    test_binaries = [
        ("vmseq_vx_test.elf", SAME_TYPE_TEST_CASES, np.equal),
        ("vmsne_vx_test.elf", SAME_TYPE_TEST_CASES, np.not_equal),
        ("vmslt_vx_test.elf", SAME_TYPE_TEST_CASES, np.less),
        ("vmsle_vx_test.elf", SAME_TYPE_TEST_CASES, np.less_equal),
        ("vmsgt_vx_test.elf", SAME_TYPE_TEST_CASES, np.greater),
        ("vmsge_vx_test.elf", SAME_TYPE_TEST_CASES, np.greater_equal),
    ]
    with tqdm.tqdm(test_binaries) as pbar:
        for test_binary, test_cases, expected_fn in pbar:
            pbar.set_postfix({"binary": test_binary})
            test_binary_path = r.Rlocation(
                f"coralnpu_hw/tests/cocotb/rvv/arithmetics/{test_binary}"
            )
            fn_names = list(set([x[0] for x in test_cases]))
            await fixture.load_elf_and_lookup_symbols(
                test_binary_path, ["vl", "vs2", "xs2", "vd", "impl"] + fn_names
            )

            for test_fn_name, vlmax, vs2_dtype, xs2_dtype, _ in test_cases:
                for vl in [1, vlmax]:
                    rng = np.random.default_rng()
                    vs2_data = rng.integers(
                        np.iinfo(vs2_dtype).min,
                        np.iinfo(vs2_dtype).max + 1,
                        size=vl,
                        dtype=vs2_dtype,
                    )
                    xs2_data = rng.integers(
                        np.iinfo(xs2_dtype).min,
                        np.iinfo(xs2_dtype).max + 1,
                        size=1,
                        dtype=xs2_dtype,
                    )

                    await fixture.write("vl", np.array([vl], dtype=np.uint32))
                    await fixture.write("vs2", vs2_data)
                    await fixture.write("xs2", xs2_data.astype(np.uint32))
                    await fixture.write("vd", np.zeros(128, dtype=np.uint8))

                    await fixture.write_ptr("impl", test_fn_name)
                    await fixture.run_to_halt()

                    expected_res = expected_fn(vs2_data, xs2_data[0])
                    # Mask results are packed into bytes
                    num_mask_bytes = (vl + 7) // 8
                    actual_mask_bytes = await fixture.read("vd", num_mask_bytes)

                    for i in range(vl):
                        expected_bit = 1 if expected_res[i] else 0
                        actual_bit = (actual_mask_bytes[i // 8] >> (i % 8)) & 1
                        assert actual_bit == expected_bit, (
                            f"Bit {i} mismatch: expected {expected_bit}, got {actual_bit}"
                        )


@cocotb.test()
async def comparison_op_vv(dut):
    r = runfiles.Create()
    fixture = await Fixture.Create(dut)
    test_binaries = [
        ("vmseq_vv_test.elf", SAME_TYPE_TEST_CASES, np.equal),
        ("vmsne_vv_test.elf", SAME_TYPE_TEST_CASES, np.not_equal),
        ("vmslt_vv_test.elf", SAME_TYPE_TEST_CASES, np.less),
        ("vmsle_vv_test.elf", SAME_TYPE_TEST_CASES, np.less_equal),
    ]
    with tqdm.tqdm(test_binaries) as pbar:
        for test_binary, test_cases, expected_fn in pbar:
            pbar.set_postfix({"binary": test_binary})
            test_binary_path = r.Rlocation(
                f"coralnpu_hw/tests/cocotb/rvv/arithmetics/{test_binary}"
            )
            fn_names = list(set([x[0] for x in test_cases]))
            await fixture.load_elf_and_lookup_symbols(
                test_binary_path, ["vl", "vs2", "vs1", "vd", "impl"] + fn_names
            )

            for test_fn_name, vlmax, vs2_dtype, vs1_dtype, _ in test_cases:
                for vl in [1, vlmax]:
                    rng = np.random.default_rng()
                    vs2_data = rng.integers(
                        np.iinfo(vs2_dtype).min,
                        np.iinfo(vs2_dtype).max + 1,
                        size=vl,
                        dtype=vs2_dtype,
                    )
                    vs1_data = rng.integers(
                        np.iinfo(vs1_dtype).min,
                        np.iinfo(vs1_dtype).max + 1,
                        size=vl,
                        dtype=vs1_dtype,
                    )

                    await fixture.write("vl", np.array([vl], dtype=np.uint32))
                    await fixture.write("vs2", vs2_data)
                    await fixture.write("vs1", vs1_data)
                    await fixture.write("vd", np.zeros(128, dtype=np.uint8))

                    await fixture.write_ptr("impl", test_fn_name)
                    await fixture.run_to_halt()

                    expected_res = expected_fn(vs2_data, vs1_data)
                    num_mask_bytes = (vl + 7) // 8
                    actual_mask_bytes = await fixture.read("vd", num_mask_bytes)

                    for i in range(vl):
                        expected_bit = 1 if expected_res[i] else 0
                        actual_bit = (actual_mask_bytes[i // 8] >> (i % 8)) & 1
                        assert actual_bit == expected_bit, f"Bit {i} mismatch"


@cocotb.test()
async def carry_op_vx(dut):
    r = runfiles.Create()
    fixture = await Fixture.Create(dut)
    test_binaries = [
        ("vadc_vxm_test.elf", SAME_TYPE_TEST_CASES, reference_adc),
        ("vsbc_vxm_test.elf", SAME_TYPE_TEST_CASES, reference_sbc),
    ]
    with tqdm.tqdm(test_binaries) as pbar:
        for test_binary, test_cases, expected_fn in pbar:
            pbar.set_postfix({"binary": test_binary})
            test_binary_path = r.Rlocation(
                f"coralnpu_hw/tests/cocotb/rvv/arithmetics/{test_binary}"
            )
            fn_names = list(set([x[0] for x in test_cases]))
            await fixture.load_elf_and_lookup_symbols(
                test_binary_path,
                ["vl", "vs2", "xs2", "v0_buf", "vd", "impl"] + fn_names,
            )

            for test_fn_name, vlmax, vs2_dtype, xs2_dtype, vd_dtype in test_cases:
                for vl in [1, vlmax]:
                    rng = np.random.default_rng()
                    vs2_data = rng.integers(
                        np.iinfo(vs2_dtype).min,
                        np.iinfo(vs2_dtype).max + 1,
                        size=vl,
                        dtype=vs2_dtype,
                    )
                    xs2_data = rng.integers(
                        np.iinfo(xs2_dtype).min,
                        np.iinfo(xs2_dtype).max + 1,
                        size=1,
                        dtype=xs2_dtype,
                    )
                    v0_data = rng.integers(0, 256, size=(vl + 7) // 8, dtype=np.uint8)

                    await fixture.write("vl", np.array([vl], dtype=np.uint32))
                    await fixture.write("vs2", vs2_data)
                    await fixture.write("xs2", xs2_data.astype(np.uint32))
                    await fixture.write("v0_buf", v0_data)

                    await fixture.write_ptr("impl", test_fn_name)
                    await fixture.run_to_halt()

                    # Unpack v0_data to bits for reference
                    v0_bits = np.unpackbits(v0_data, bitorder="little")[:vl]
                    expected_vd_data = expected_fn(
                        vs2_data, xs2_data[0], v0_bits
                    ).astype(vd_dtype)
                    actual_vd_data = (
                        await fixture.read("vd", vl * np.dtype(vd_dtype).itemsize)
                    ).view(vd_dtype)
                    assert (actual_vd_data == expected_vd_data).all()


@cocotb.test()
async def merge_op_vv(dut):
    r = runfiles.Create()
    fixture = await Fixture.Create(dut)
    test_binary = "vmerge_vv_test.elf"
    test_binary_path = r.Rlocation(
        f"coralnpu_hw/tests/cocotb/rvv/arithmetics/{test_binary}"
    )
    fn_names = list(set([x[0] for x in SAME_TYPE_TEST_CASES]))
    await fixture.load_elf_and_lookup_symbols(
        test_binary_path, ["vl", "vs2", "vs1", "v0_buf", "vd", "impl"] + fn_names
    )

    for test_fn_name, vlmax, vs2_dtype, vs1_dtype, vd_dtype in SAME_TYPE_TEST_CASES:
        for vl in [1, vlmax]:
            rng = np.random.default_rng()
            vs2_data = rng.integers(
                np.iinfo(vs2_dtype).min,
                np.iinfo(vs2_dtype).max + 1,
                size=vl,
                dtype=vs2_dtype,
            )
            vs1_data = rng.integers(
                np.iinfo(vs1_dtype).min,
                np.iinfo(vs1_dtype).max + 1,
                size=vl,
                dtype=vs1_dtype,
            )
            v0_data = rng.integers(0, 256, size=(vl + 7) // 8, dtype=np.uint8)

            await fixture.write("vl", np.array([vl], dtype=np.uint32))
            await fixture.write("vs2", vs2_data)
            await fixture.write("vs1", vs1_data)
            await fixture.write("v0_buf", v0_data)

            await fixture.write_ptr("impl", test_fn_name)
            await fixture.run_to_halt()

            v0_bits = np.unpackbits(v0_data, bitorder="little")[:vl]
            expected_vd_data = np.where(v0_bits, vs1_data, vs2_data).astype(vd_dtype)
            actual_vd_data = (
                await fixture.read("vd", vl * np.dtype(vd_dtype).itemsize)
            ).view(vd_dtype)
            assert (actual_vd_data == expected_vd_data).all()


async def _widen_wide_math_ops_test_impl(
    dut,
    dtypes,
    math_ops: list,
    num_test_values: int = 16,
):
    """RVV widen wide arithmetic test template.

    Each test performs a widen wide math op loading vs2 (wide) and vs1 (narrow) or xs2 (narrow)
    """
    r = runfiles.Create()
    fixture = await Fixture.Create(dut)
    for math_op in math_ops:
        for in_dtype_str, out_dtype_str in dtypes:
            elf_name = f"vw{math_op}_wv_test.elf"
            test_binary_path = r.Rlocation(
                f"coralnpu_hw/tests/cocotb/rvv/arithmetics/{elf_name}"
            )
            in_dtype = STR_TO_NP_TYPE[in_dtype_str]
            out_dtype = STR_TO_NP_TYPE[out_dtype_str]

            # Since my BUILD used coralnpu_v2_binary with test_op templates, I need to lookup symbols
            ui = "i" if in_dtype_str.startswith("int") else "u"
            bits_match = re.search(r"\d+", in_dtype_str)
            if not bits_match:
                print(f"ERROR: could not extract bits from {in_dtype_str}")
                continue
            bits = bits_match.group()
            sew = int(bits)
            fn_name = f"test_{ui}{bits}_m1"
            await fixture.load_elf_and_lookup_symbols(
                test_binary_path, ["vl", "vs2", "vs1", "vd", "impl", fn_name]
            )

            if fn_name not in fixture.symbols:
                print(f"ERROR: symbol {fn_name} not found in {elf_name}")
                continue

            # VLEN=128, LMUL=1
            vl = min(num_test_values, 128 // sew)
            rng = np.random.default_rng()
            vs2_data = rng.integers(
                np.iinfo(out_dtype).min,
                np.iinfo(out_dtype).max + 1,
                size=vl,
                dtype=out_dtype,
            )
            vs1_data = rng.integers(
                np.iinfo(in_dtype).min,
                np.iinfo(in_dtype).max + 1,
                size=vl,
                dtype=in_dtype,
            )

            await fixture.write("vl", np.array([vl], dtype=np.uint32))
            await fixture.write("vs2", vs2_data)
            await fixture.write("vs1", vs1_data)
            await fixture.write(
                "vd", np.zeros(vl * np.dtype(out_dtype).itemsize, dtype=np.uint8)
            )

            await fixture.write_ptr("impl", fn_name)
            await fixture.run_to_halt()

            expected_vd_data = _get_math_result(
                vs2_data, vs1_data, math_op, dtype=out_dtype
            )
            actual_vd_data = (
                await fixture.read("vd", vl * np.dtype(out_dtype).itemsize)
            ).view(out_dtype)
            assert (actual_vd_data == expected_vd_data).all()


@cocotb.test()
async def widen_wide_math_ops_test(dut):
    await _widen_wide_math_ops_test_impl(
        dut=dut,
        dtypes=[
            ["int8", "int16"],
            ["int16", "int32"],
            ["uint8", "uint16"],
            ["uint16", "uint32"],
        ],
        math_ops=["add", "sub"],
    )


@cocotb.test()
async def extension_op_test(dut):
    """Test vsext and vzext instructions."""
    r = runfiles.Create()
    fixture = await Fixture.Create(dut)
    test_binaries = [
        ("vsext_vf2_test.elf", 2, True),
        ("vsext_vf4_test.elf", 4, True),
        ("vzext_vf2_test.elf", 2, False),
        ("vzext_vf4_test.elf", 4, False),
    ]

    for elf_name, factor, signed in test_binaries:
        elf_path = r.Rlocation(f"coralnpu_hw/tests/cocotb/rvv/arithmetics/{elf_name}")
        # Extension ops in rvv_vx_arithmetics.cc use NarrowType and Narrow(lmul, factor) for vs1.
        # We test types that result in 16-bit and 32-bit outputs.
        out_dtypes = [np.int16, np.int32] if signed else [np.uint16, np.uint32]

        for out_dtype in out_dtypes:
            out_sew = np.dtype(out_dtype).itemsize * 8
            in_sew = out_sew // factor
            if in_sew < 8:
                continue

            in_dtype = np.dtype(f"int{in_sew}") if signed else np.dtype(f"uint{in_sew}")
            # Map out_dtype to m1 test function name
            ui = "i" if signed else "u"
            fn_name = f"test_{ui}{out_sew}_m1"

            await fixture.load_elf_and_lookup_symbols(
                elf_path, ["vl", "vs1", "vd", "impl", fn_name]
            )
            if fn_name not in fixture.symbols:
                continue

            vl = 128 // out_sew  # Process full register group at M1
            rng = np.random.default_rng()
            vs1_data = rng.integers(
                np.iinfo(in_dtype).min,
                np.iinfo(in_dtype).max + 1,
                size=vl,
                dtype=in_dtype.type,
            )

            await fixture.write("vl", np.array([vl], dtype=np.uint32))
            await fixture.write("vs1", vs1_data)
            await fixture.write(
                "vd", np.zeros(vl * np.dtype(out_dtype).itemsize, dtype=np.uint8)
            )

            await fixture.write_ptr("impl", fn_name)
            await fixture.run_to_halt()

            expected_vd_data = vs1_data.astype(out_dtype)
            actual_vd_data = (
                await fixture.read("vd", vl * np.dtype(out_dtype).itemsize)
            ).view(out_dtype)

            debug_msg = (
                f"elf: {elf_name}, fn: {fn_name}, factor: {factor}, signed: {signed}, "
                f"in_dtype: {in_dtype}, out_dtype: {out_dtype}, vl: {vl}, "
                f"vs1: {vs1_data}, expected: {expected_vd_data}, actual: {actual_vd_data}"
            )
            assert (actual_vd_data == expected_vd_data).all(), debug_msg


@cocotb.test()
async def immediate_op_test(dut):
    """Test instructions with immediate operands (.vi)."""
    r = runfiles.Create()
    fixture = await Fixture.Create(dut)

    test_binaries = [
        ("vadd_vi_test.elf", np.add),
        ("vsadd_vi_test.elf", reference_sadd),
        ("vand_vi_test.elf", np.bitwise_and),
        ("vor_vi_test.elf", np.bitwise_or),
        ("vxor_vi_test.elf", np.bitwise_xor),
        ("vsll_vi_test.elf", reference_sll),
        ("vsrl_vi_test.elf", reference_srl),
        ("vsra_vi_test.elf", reference_sra),
        ("vssrl_vi_test.elf", reference_ssrl),
        ("vssra_vi_test.elf", reference_ssra),
        ("vrsub_vi_test.elf", lambda x, y: y - x),
    ]

    for elf_name, op in test_binaries:
        elf_path = r.Rlocation(f"coralnpu_hw/tests/cocotb/rvv/arithmetics/{elf_name}")

        # Test cases similar to binary_op_vx but with fixed immediate 5
        for test_case in SAME_TYPE_TEST_CASES:
            fn_name, vl, vs1_dtype, _, vd_dtype = test_case

            # Filter cases based on elf_name
            if "SIGNED_ONLY" in elf_name and not np.issubdtype(
                vs1_dtype, np.signedinteger
            ):
                continue
            if "UNSIGNED_ONLY" in elf_name and not np.issubdtype(
                vs1_dtype, np.unsignedinteger
            ):
                continue

            await fixture.load_elf_and_lookup_symbols(
                elf_path, ["vl", "vs1", "vd", "impl", fn_name]
            )
            if fixture.symbols.get(fn_name) is None:
                continue

            rng = np.random.default_rng()
            vs1_data = rng.integers(
                np.iinfo(vs1_dtype).min,
                np.iinfo(vs1_dtype).max + 1,
                size=vl,
                dtype=vs1_dtype,
            )
            imm = 5

            await fixture.write("vl", np.array([vl], dtype=np.uint32))
            await fixture.write("vs1", vs1_data)
            await fixture.write(
                "vd", np.zeros(vl * np.dtype(vd_dtype).itemsize, dtype=np.uint8)
            )

            await fixture.write_ptr("impl", fn_name)
            await fixture.run_to_halt()

            expected_vd_data = np.asarray(op(vs1_data, imm), dtype=vd_dtype)
            actual_vd_data = (
                await fixture.read("vd", vl * np.dtype(vd_dtype).itemsize)
            ).view(vd_dtype)

            debug_msg = (
                f"elf: {elf_name}, fn: {fn_name}, vs1: {vs1_data}, imm: {imm}, "
                f"expected: {expected_vd_data}, actual: {actual_vd_data}"
            )
            assert (actual_vd_data == expected_vd_data).all(), debug_msg


def reference_sadd(lhs, rhs):
    dtype = lhs.dtype
    return np.clip(lhs.astype(np.int64) + rhs, np.iinfo(dtype).min, np.iinfo(dtype).max)


def reference_ssub(lhs, rhs):
    dtype = lhs.dtype
    return np.clip(lhs.astype(np.int64) - rhs, np.iinfo(dtype).min, np.iinfo(dtype).max)


def reference_rsub(lhs, rhs):
    return rhs - lhs


def reference_mul(lhs, rhs):
    return lhs * rhs


def reference_vmulh(lhs, rhs):
    dtype = lhs.dtype
    bitwidth = np.iinfo(dtype).bits
    return ((lhs.astype(np.int64) * rhs) >> bitwidth) & (~np.array([0], dtype=dtype))


def reference_asub(lhs, rhs):
    dtype = lhs.dtype
    x_ext = lhs.astype(np.int64)
    y_ext = rhs.astype(np.int64)
    res = (x_ext - y_ext) >> 1
    # Round to nearest up (RNU)
    res += (x_ext - y_ext) & 1
    return res.astype(dtype)


def reference_aadd(lhs, rhs):
    dtype = lhs.dtype
    x_ext = lhs.astype(np.int64)
    y_ext = rhs.astype(np.int64)
    res = (x_ext + y_ext) >> 1
    # Round to nearest up (RNU)
    res += (x_ext + y_ext) & 1
    return res.astype(dtype)


def reference_smul(lhs, rhs):
    dtype = lhs.dtype
    bitwidth = np.iinfo(dtype).bits
    res = (lhs.astype(np.int64) * rhs + (1 << (bitwidth - 2))) >> (bitwidth - 1)
    return np.clip(res, np.iinfo(dtype).min, np.iinfo(dtype).max).astype(dtype)


def reference_div(x, y):
    dtype = x.dtype
    x_64 = (
        x.astype(np.int64)
        if np.issubdtype(dtype, np.signedinteger)
        else x.astype(np.uint64)
    )
    y_64 = (
        y.astype(np.int64)
        if np.issubdtype(dtype, np.signedinteger)
        else y.astype(np.uint64)
    )

    mask_zero = y_64 == 0
    mask_overflow = np.zeros_like(mask_zero)
    if np.issubdtype(dtype, np.signedinteger):
        min_int = np.iinfo(dtype).min
        mask_overflow = (x_64 == min_int) & (y_64 == -1)

    safe_y = np.where(mask_zero | mask_overflow, 1, y_64)
    with np.errstate(divide="ignore", invalid="ignore"):
        res = np.trunc(x.astype(np.float64) / safe_y.astype(np.float64)).astype(
            np.int64
        )

    if np.issubdtype(dtype, np.unsignedinteger):
        res[mask_zero] = np.iinfo(dtype).max
    else:
        res[mask_zero] = -1
        res[mask_overflow] = np.iinfo(dtype).min

    return res.astype(dtype)


def reference_rem(x, y):
    dtype = x.dtype
    x_64 = (
        x.astype(np.int64)
        if np.issubdtype(dtype, np.signedinteger)
        else x.astype(np.uint64)
    )
    y_64 = (
        y.astype(np.int64)
        if np.issubdtype(dtype, np.signedinteger)
        else y.astype(np.uint64)
    )

    mask_zero = y_64 == 0
    mask_overflow = np.zeros_like(mask_zero)
    if np.issubdtype(dtype, np.signedinteger):
        min_int = np.iinfo(dtype).min
        mask_overflow = (x_64 == min_int) & (y_64 == -1)

    safe_y = np.where(mask_zero | mask_overflow, 1, y_64)
    with np.errstate(divide="ignore", invalid="ignore"):
        div_res = np.trunc(x.astype(np.float64) / safe_y.astype(np.float64)).astype(
            np.int64
        )
    res = x_64 - div_res * y_64

    res[mask_zero] = x_64[mask_zero]
    res[mask_overflow] = 0

    return res.astype(dtype)


def reference_merge(vs2, vs1, v0):
    res = vs2.copy()
    mask = (v0 >> np.arange(8)) & 1  # Simplified mask unpacking for illustration
    # In practice, need bit-by-bit masking
    # But for cocotb, we can pass expanded mask
    return res


def reference_adc(vs2, vs1, v0):
    return vs2.astype(np.int64) + vs1 + v0


def reference_madc(vs2, vs1, v0):
    res = vs2.astype(np.int64) + vs1 + v0
    # Return 1 if overflow/carry out
    return (res > np.iinfo(vs2.dtype).max).astype(np.uint8)


def reference_sbc(vs2, vs1, v0):
    return vs2.astype(np.int64) - vs1 - v0


def reference_msbc(vs2, vs1, v0):
    res = vs2.astype(np.int64) - vs1 - v0
    # Return 1 if borrow
    return (res < np.iinfo(vs2.dtype).min).astype(np.uint8)


def reference_sll(lhs, rhs):
    dtype = lhs.dtype
    mask = ~np.array([0], dtype=dtype)
    shift = rhs & ((np.dtype(dtype).itemsize * 8) - 1)
    return ((lhs << shift) & mask).astype(dtype)


def reference_srl(lhs, rhs):
    dtype = lhs.dtype
    mask = (1 << (np.dtype(dtype).itemsize * 8)) - 1
    shift = rhs & ((np.dtype(dtype).itemsize * 8) - 1)
    # View as unsigned and mask to ensure bitwise shift behavior
    unsigned_dtype = np.dtype(dtype.str.replace("i", "u"))
    return ((lhs.view(unsigned_dtype).astype(np.uint64) >> shift) & mask).astype(dtype)


def reference_sra(lhs, rhs):
    shift = rhs & ((np.dtype(lhs.dtype).itemsize * 8) - 1)
    return np.right_shift(lhs, shift).astype(lhs.dtype)


def reference_ssra(lhs, rhs):
    dtype = lhs.dtype
    sew = np.dtype(dtype).itemsize * 8
    shift = rhs & (sew - 1)
    res = lhs.astype(object)
    if isinstance(shift, np.ndarray):
        mask = shift > 0
        if np.any(mask):
            res[mask] = (res[mask] + (1 << (shift[mask] - 1))) >> shift[mask]
    elif shift > 0:
        res = (res + (1 << (shift - 1))) >> shift
    return res.astype(dtype)


def reference_ssrl(lhs, rhs):
    dtype = lhs.dtype
    sew = np.dtype(dtype).itemsize * 8
    shift = rhs & (sew - 1)
    # View as unsigned for logical shift
    unsigned_dtype = np.dtype(dtype.str.replace("i", "u"))
    res = lhs.view(unsigned_dtype).astype(object)
    if isinstance(shift, np.ndarray):
        mask = shift > 0
        if np.any(mask):
            res[mask] = (res[mask] + (1 << (shift[mask] - 1))) >> shift[mask]
    elif shift > 0:
        res = (res + (1 << (shift - 1))) >> shift
    return res.astype(dtype)


# Test name, vl, vs1 type, xs2 type, vd type
SAME_TYPE_TEST_CASES = [
    ("test_i8_mf4", 4, np.int8, np.int8, np.int8),
    ("test_i8_mf2", 8, np.int8, np.int8, np.int8),
    ("test_i8_m1", 16, np.int8, np.int8, np.int8),
    ("test_i8_m2", 32, np.int8, np.int8, np.int8),
    ("test_i8_m4", 64, np.int8, np.int8, np.int8),
    ("test_i8_m8", 128, np.int8, np.int8, np.int8),
    ("test_i16_mf2", 4, np.int16, np.int16, np.int16),
    ("test_i16_m1", 8, np.int16, np.int16, np.int16),
    ("test_i16_m2", 16, np.int16, np.int16, np.int16),
    ("test_i16_m4", 32, np.int16, np.int16, np.int16),
    ("test_i16_m8", 64, np.int16, np.int16, np.int16),
    ("test_i32_m1", 4, np.int32, np.int32, np.int32),
    ("test_i32_m2", 8, np.int32, np.int32, np.int32),
    ("test_i32_m4", 16, np.int32, np.int32, np.int32),
    ("test_i32_m8", 32, np.int32, np.int32, np.int32),
    ("test_u8_mf4", 4, np.uint8, np.uint8, np.uint8),
    ("test_u8_mf2", 8, np.uint8, np.uint8, np.uint8),
    ("test_u8_m1", 16, np.uint8, np.uint8, np.uint8),
    ("test_u8_m2", 32, np.uint8, np.uint8, np.uint8),
    ("test_u8_m4", 64, np.uint8, np.uint8, np.uint8),
    ("test_u8_m8", 128, np.uint8, np.uint8, np.uint8),
    ("test_u16_mf2", 4, np.uint16, np.uint16, np.uint16),
    ("test_u16_m1", 8, np.uint16, np.uint16, np.uint16),
    ("test_u16_m2", 16, np.uint16, np.uint16, np.uint16),
    ("test_u16_m4", 32, np.uint16, np.uint16, np.uint16),
    ("test_u16_m8", 64, np.uint16, np.uint16, np.uint16),
    ("test_u32_m1", 4, np.uint32, np.uint32, np.uint32),
    ("test_u32_m2", 8, np.uint32, np.uint32, np.uint32),
    ("test_u32_m4", 16, np.uint32, np.uint32, np.uint32),
    ("test_u32_m8", 32, np.uint32, np.uint32, np.uint32),
]

SIGNED_ONLY_TEST_CASES = [
    x for x in SAME_TYPE_TEST_CASES if np.issubdtype(x[2], np.signedinteger)
]

UNSIGNED_ONLY_TEST_CASES = [
    x for x in SAME_TYPE_TEST_CASES if np.issubdtype(x[2], np.unsignedinteger)
]


def _force_unsigned(dtype):
    bitdepth = np.dtype(dtype).itemsize * 8
    return np.dtype(f"uint{bitdepth}")


SAME_TYPE_RHS_FORCED_UNSIGNED_TEST_CASES = [
    (name, vl, lhs_dtype, _force_unsigned(rhs_dtype), result_type)
    for name, vl, lhs_dtype, rhs_dtype, result_type in SAME_TYPE_TEST_CASES
]

UNSIGNED_ONLY_TEST_CASES = [
    (name, vl, lhs_dtype, rhs_dtype, result_type)
    for name, vl, lhs_dtype, rhs_dtype, result_type in SAME_TYPE_TEST_CASES
    if np.dtype(lhs_dtype).kind == 'u'
]

SIGNED_LHS_UNSIGNED_RHS_ONLY_TEST_CASES = [
    (name, vl, lhs_dtype, _force_unsigned(rhs_dtype), result_type)
    for name, vl, lhs_dtype, rhs_dtype, result_type in SAME_TYPE_TEST_CASES
    if np.dtype(lhs_dtype).kind == 'i'
]

@cocotb.test()
async def binary_op_vx(dut):
    r = runfiles.Create()
    fixture = await Fixture.Create(dut)
    test_binaries = [
        ("vadd_vx_test.elf", SAME_TYPE_TEST_CASES, np.add),
        ("vsadd_vx_test.elf", SAME_TYPE_TEST_CASES, reference_sadd),
        ("vsub_vx_test.elf", SAME_TYPE_TEST_CASES, np.subtract),
        ("vssub_vx_test.elf", SAME_TYPE_TEST_CASES, reference_ssub),
        ("vrsub_vx_test.elf", SAME_TYPE_TEST_CASES, reference_rsub),
        ("vmul_vx_test.elf", SAME_TYPE_TEST_CASES, np.multiply),
        ("vmulh_vx_test.elf", SAME_TYPE_TEST_CASES, reference_vmulh),
        ("vmin_vx_test.elf", SAME_TYPE_TEST_CASES, np.minimum),
        ("vmax_vx_test.elf", SAME_TYPE_TEST_CASES, np.maximum),
        ("vand_vx_test.elf", SAME_TYPE_TEST_CASES, np.bitwise_and),
        ("vor_vx_test.elf", SAME_TYPE_TEST_CASES, np.bitwise_or),
        ("vxor_vx_test.elf", SAME_TYPE_TEST_CASES, np.bitwise_xor),
        ("vaadd_vx_test.elf", SAME_TYPE_TEST_CASES, reference_aadd),
        ("vaaddu_vx_test.elf", UNSIGNED_ONLY_TEST_CASES, reference_aadd),
        ("vasub_vx_test.elf", SAME_TYPE_TEST_CASES, reference_asub),
        ("vasubu_vx_test.elf", UNSIGNED_ONLY_TEST_CASES, reference_asub),
        ("vsmul_vx_test.elf", SIGNED_ONLY_TEST_CASES, reference_smul),
        ("vdiv_vx_test.elf", SAME_TYPE_TEST_CASES, reference_div),
        ("vrem_vx_test.elf", SAME_TYPE_TEST_CASES, reference_rem),
        ("vsll_vx_test.elf", SAME_TYPE_RHS_FORCED_UNSIGNED_TEST_CASES, reference_sll),
        ("vsrl_vx_test.elf", UNSIGNED_ONLY_TEST_CASES, reference_srl),
        ("vsra_vx_test.elf", SIGNED_LHS_UNSIGNED_RHS_ONLY_TEST_CASES, reference_sra),
        (
            "vmulhsu_vx_test.elf",
            SIGNED_LHS_UNSIGNED_RHS_ONLY_TEST_CASES,
            reference_vmulh,
        ),
    ]
    with tqdm.tqdm(test_binaries) as pbar:
        for test_binary_op_vx, test_cases, expected_fn in pbar:
            pbar.set_postfix({"binary": test_binary_op_vx})
            test_binary_path = r.Rlocation(
                f"coralnpu_hw/tests/cocotb/rvv/arithmetics/{test_binary_op_vx}"
            )

            fn_names = list(set([x[0] for x in test_cases]))
            await fixture.load_elf_and_lookup_symbols(
                test_binary_path, ['vl', 'vs1', 'xs2', 'vd', 'impl'] + fn_names)

            for test_fn_name, vlmax, vs1_dtype, xs2_dtype, vd_dtype in test_cases:
                for vl in [1, vlmax-1, vlmax]:
                    # Write random data to vs1 and xs2
                    rng = np.random.default_rng()
                    vs1_data = rng.integers(
                        np.iinfo(vs1_dtype).min,
                        np.iinfo(vs1_dtype).max + 1,
                        size=vl,
                        dtype=vs1_dtype)
                    xs2_data = rng.integers(
                        np.iinfo(xs2_dtype).min,
                        np.iinfo(xs2_dtype).max + 1,
                        size=1,
                        dtype=xs2_dtype)

                    await fixture.write('vl', np.array([vl], dtype=np.uint32))
                    await fixture.write('vs1', vs1_data)
                    await fixture.write('xs2', xs2_data.astype(np.uint32))
                    await fixture.write('vd', np.zeros(128, dtype=np.uint8))

                    # Execute the test function
                    await fixture.write_ptr('impl', test_fn_name)
                    await fixture.run_to_halt()

                    # Read the result and assert
                    expected_vd_data = expected_fn(vs1_data, xs2_data[0])
                    actual_vd_data = (await fixture.read(
                        'vd', vl*np.dtype(vd_dtype).itemsize)).view(vd_dtype)
                    assert (actual_vd_data == expected_vd_data).all(), (
                        f"binary: {test_binary_op_vx}, "
                        f"test_fn_name: {test_fn_name}, "
                        f"vs1: {vs1_data}, xs2: {xs2_data}, "
                        f"expected: {expected_vd_data}, actual: {actual_vd_data}")
