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
import sys
import tqdm
import re
import numpy as np
import os

from bazel_tools.tools.python.runfiles import runfiles
from coralnpu_test_utils.sim_test_fixture import Fixture

import ctypes
import math

RM_MAP = {"rne": 0, "rtz": 0xc00, "rdn": 0x400, "rup": 0x800, "rmm": None}

STR_TO_NP_TYPE = {
    "int8": np.int8,
    "int16": np.int16,
    "int32": np.int32,
    "uint8": np.uint8,
    "uint16": np.uint16,
    "uint32": np.uint32,
    "float": np.float32,
}


def reference_fma(x, y, z, symbol, rm="rne"):
    # Convert inputs to float64 to prevent double-rounding
    xf64 = np.float64(x)
    yf64 = np.float64(y)
    zf64 = np.float64(z)

    if symbol == "fmacc":
        res64 = yf64 * zf64 + xf64
    elif symbol == "fnmacc":
        res64 = (-yf64) * zf64 - xf64
    elif symbol == "fmadd":
        res64 = xf64 * yf64 + zf64
    elif symbol == "fnmadd":
        res64 = (-xf64) * yf64 - zf64
    elif symbol == "fmsac":
        res64 = yf64 * zf64 - xf64
    elif symbol == "fnmsac":
        res64 = (-yf64) * zf64 + xf64
    elif symbol == "fmsub":
        res64 = xf64 * yf64 - zf64
    elif symbol == "fnmsub":
        res64 = (-xf64) * yf64 + zf64
    else:
        return x

    if rm == "rmm":
        res32 = np.float32(res64)
        return res32
    else:
        libc = ctypes.CDLL(None)
        if hasattr(libc,
                   "fesetround") and rm in RM_MAP and RM_MAP[rm] is not None:
            libc.fesetround(RM_MAP[rm])

        res32 = np.float32(res64)

        if hasattr(libc, "fesetround"):
            libc.fesetround(0)  # Restore RNE
        return res32


def reference_fclass(x):
    res = np.zeros_like(x, dtype=np.uint32)
    # 0: neg inf
    res |= (np.isinf(x) & (x < 0)).astype(np.uint32) << 0
    # 1: neg normal
    res |= (
        np.isfinite(x) & (x < 0) & (np.abs(x) >= np.finfo(np.float32).tiny)
    ).astype(np.uint32) << 1
    # 2: neg subnormal
    res |= (
        np.isfinite(x) & (x < 0) & (np.abs(x) < np.finfo(np.float32).tiny) &
        (x != 0)
    ).astype(np.uint32) << 2
    # 3: neg zero
    res |= ((x == 0) & np.signbit(x)).astype(np.uint32) << 3
    # 4: pos zero
    res |= ((x == 0) & ~np.signbit(x)).astype(np.uint32) << 4
    # 5: pos subnormal
    res |= (np.isfinite(x) & (x > 0) &
            (x < np.finfo(np.float32).tiny)).astype(np.uint32) << 5
    # 6: pos normal
    res |= (np.isfinite(x) & (x > 0) &
            (x >= np.finfo(np.float32).tiny)).astype(np.uint32) << 6
    # 7: pos inf
    res |= (np.isinf(x) & (x > 0)).astype(np.uint32) << 7
    # 8: signaling NaN (assume none for now as it is hard to distinguish from quiet NaN in NumPy)
    # 9: quiet NaN
    res |= np.isnan(x).astype(np.uint32) << 9
    return res


def reference_fredosum(x, y):
    res = y[0]
    for i in range(len(x)):
        res += x[i]
    return np.array([res])


async def _setup_fixture(dut):
    r = runfiles.Create()
    fixture = await Fixture.Create(dut)
    rng = np.random.default_rng(seed=42)
    return fixture, r, rng


def _get_math_result(
    x: np.array, y: np.array, symbol: str, dtype=None, z=None, rm="rne"
):
    libc = ctypes.CDLL(None)

    def apply_rm(func, *args, **kwargs):
        if rm != "rmm" and hasattr(
                libc,
                "fesetround") and rm in RM_MAP and RM_MAP[rm] is not None:
            libc.fesetround(RM_MAP[rm])
        res = func(*args, **kwargs)
        if hasattr(libc, "fesetround"):
            libc.fesetround(0)
        return res

    if symbol == "add" or symbol == "fadd":
        if symbol == "fadd": return apply_rm(np.add, x, y, dtype=dtype)
        return np.add(x, y, dtype=dtype)
    elif symbol == "sub" or symbol == "fsub":
        if symbol == "fsub": return apply_rm(np.subtract, x, y, dtype=dtype)
        return np.subtract(x, y, dtype=dtype)
    elif symbol == "mul" or symbol == "fmul":
        if symbol == "fmul": return apply_rm(np.multiply, x, y, dtype=dtype)
        return np.multiply(x, y, dtype=dtype)
    elif symbol == "fdiv":
        orig_settings = np.seterr(divide="ignore")
        divide_output = apply_rm(np.divide, x, y, dtype=dtype)
        np.seterr(**orig_settings)
        return divide_output
    elif symbol == "fmin":
        return apply_rm(np.minimum, x, y)
    elif symbol == "fmax":
        return apply_rm(np.maximum, x, y)
    elif symbol == "frsub":
        return apply_rm(np.subtract, y, x)
    elif symbol == "frdiv":
        with np.errstate(divide="ignore", invalid="ignore"):
            return apply_rm(np.divide, y, x, dtype=dtype)
    elif symbol == "fsqrt":
        with np.errstate(invalid="ignore"):
            return apply_rm(np.sqrt, x, dtype=dtype)
    elif symbol == "fsgnj":
        # Standard: magnitude from vs2 (x), sign from scalar/vs1 (y).
        return np.copysign(x, y)
    elif symbol == "fsgnjn":
        return np.copysign(x, -y)
    elif symbol == "fsgnjx":
        x_bits = x.view(np.uint32)
        y_bits = y.view(np.uint32)
        res_bits = x_bits ^ (y_bits & 0x80000000)
        return res_bits.view(np.float32)
    elif symbol in [
            "fmacc",
            "fnmacc",
            "fmadd",
            "fnmadd",
            "fmsac",
            "fnmsac",
            "fmsub",
            "fnmsub",
    ]:
        return reference_fma(x, y, z, symbol, rm)
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
    elif symbol == "fredosum":
        return reference_fredosum(x, y)
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


async def arithmetic_m1_vanilla_ops_test(
    dut, dtypes, math_ops: list, num_bytes: int
):
    """RVV arithmetic test template.

    Each test performs a math op loading `in_buf_1` and `in_buf_2` and storing the output to `out_buf`.
    """
    rms = ["rne", "rtz", "rdn", "rup", "rmm"]
    m1_vanilla_op_elfs = []
    for math_op in math_ops:
        for dtype in dtypes:
            if dtype == "float":
                for rm in rms:
                    m1_vanilla_op_elfs.append(
                        f"rvv_{math_op}_{dtype}_{rm}_m1.elf"
                    )
            else:
                if not (math_op == "smul" and dtype.startswith("u")) \
                   and not (math_op in ["sra", "ssra"] and dtype.startswith("u")) \
                   and not (math_op in ["srl", "ssrl"] and dtype.startswith("i")):
                    m1_vanilla_op_elfs.append(f"rvv_{math_op}_{dtype}_m1.elf")

    pattern_extract = re.compile(
        r"rvv_(.*)_(int8|int16|int32|uint8|uint16|uint32|float)_(.*_)*m1.elf"
    )

    r = runfiles.Create()
    fixture = await Fixture.Create(dut)
    test_elf_filter = os.environ.get("TEST_ELF")
    if test_elf_filter:
        m1_vanilla_op_elfs = [
            x for x in m1_vanilla_op_elfs
            if os.path.basename(x) == test_elf_filter or x == test_elf_filter
        ]

    with tqdm.tqdm(m1_vanilla_op_elfs) as t:
        for elf_name in t:
            t.set_postfix({"binary": os.path.basename(elf_name)})
            elf_path = r.Rlocation(
                "coralnpu_hw/tests/cocotb/rvv/arithmetics/" + elf_name
            )
            await fixture.load_elf_and_lookup_symbols(
                elf_path,
                ["in_buf_1", "in_buf_2", "out_buf"],
            )
            match = pattern_extract.match(elf_name)
            math_op = match.group(1)
            dtype = match.group(2)
            rm_str = match.group(3).strip("_") if match.group(3) else "rne"
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
                input_d = np.zeros(num_test_values, dtype=np_type)
            else:
                input_1 = np.random.uniform(-10, 10,
                                            num_test_values).astype(np_type)
                input_2 = np.random.uniform(-10, 10,
                                            num_test_values).astype(np_type)
                input_d = np.random.uniform(-10, 10,
                                            num_test_values).astype(np_type)

            if math_op in [
                    "fmacc",
                    "fnmacc",
                    "fmadd",
                    "fnmadd",
                    "fmsac",
                    "fnmsac",
                    "fmsub",
                    "fnmsub",
            ]:
                expected_output = np.asarray(
                    _get_math_result(
                        input_d,
                        input_1,
                        math_op,
                        dtype=np_type,
                        z=input_2,
                        rm=rm_str
                    ),
                    dtype=np_type,
                )
            else:
                expected_output = np.asarray(
                    _get_math_result(
                        input_1, input_2, math_op, dtype=np_type, rm=rm_str
                    ),
                    dtype=np_type
                )

            await fixture.write("in_buf_1", input_1)
            await fixture.write("in_buf_2", input_2)
            await fixture.write("out_buf", input_d)

            await fixture.run_to_halt()

            actual_output = (await fixture.read("out_buf",
                                                num_bytes)).view(np_type)
            debug_msg = str({
                "op": math_op,
                "input_1": input_1,
                "input_2": input_2,
                "expected": expected_output,
                "actual": actual_output,
            })

            if np.issubdtype(np_type, np.integer):
                assert (actual_output == expected_output).all(), debug_msg
            else:
                assert np.allclose(
                    actual_output,
                    expected_output,
                    rtol=1e-5,
                    atol=1e-8,
                    equal_nan=True
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
        math_ops=[
            "fadd",
            "fsub",
            "fmul",
            "fdiv",
            "fmin",
            "fmax",
            "fmacc",
            "fnmacc",
            "fmadd",
            "fnmadd",
            "fmsac",
            "fnmsac",
            "fmsub",
            "fnmsub",
            "fsqrt",
            "fsgnj",
            "fsgnjn",
            "fsgnjx",
        ],
        num_bytes=16,
    )


async def reduction_m1_vanilla_ops_test(
    dut, dtypes, math_ops: list, num_bytes: int
):
    """RVV reduction test template.

    Each test performs a reduction op loading `in_buf_1` and storing the output to `out_buf`.
    """
    m1_vanilla_op_elfs = [
        f"rvv_{math_op}_{dtype}_m1.elf" for math_op in math_ops
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
                optional_symbols=["faulted", "mcause"],
            )
            math_op, dtype = pattern_extract.match(elf_name).groups()
            np_type = STR_TO_NP_TYPE[dtype]
            itemsize = np.dtype(np_type).itemsize
            num_test_values = int(num_bytes / np.dtype(np_type).itemsize)
            if np.issubdtype(np_type, np.integer):
                min_value = np.iinfo(np_type).min
                max_value = np.iinfo(np_type).max + 1  # One above.
                input_1 = np.random.randint(
                    min_value, max_value, num_test_values, dtype=np_type
                )
                input_2 = np.random.randint(
                    min_value, max_value, 1, dtype=np_type
                )
            else:
                input_1 = np.random.uniform(-10, 10,
                                            num_test_values).astype(np_type)
                input_2 = np.random.uniform(-10, 10, 1).astype(np_type)

            expected_output = np.asarray(
                _get_math_result(input_1, input_2, math_op), dtype=np_type
            )

            await fixture.write('in_buf_1', input_1)
            await fixture.write('scalar_input', input_2)
            await fixture.write('out_buf', np.zeros(1, dtype=np_type))
            await fixture.run_to_halt(timeout_cycles=1000000)
            if "faulted" in fixture.symbols:
                faulted = (await fixture.read('faulted', 4)).view(np.uint32)[0]
                mcause = (await fixture.read('mcause', 4)).view(np.uint32)[0]
                assert faulted == 0, f"Test faulted with mcause 0x{mcause:x} for op {math_op}"

            actual_output = (await fixture.read("out_buf",
                                                itemsize)).view(np_type)
            debug_msg = str({
                "op": math_op,
                "input_1": input_1,
                "input_2": input_2,
                "expected": expected_output,
                "actual": actual_output,
            })
            if np.issubdtype(np_type, np.integer):
                assert (actual_output == expected_output).all(), debug_msg
            else:
                assert np.allclose(
                    actual_output,
                    expected_output,
                    rtol=1e-5,
                    atol=1e-8,
                    equal_nan=True
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
        math_ops=["fredusum", "fredosum", "fredmin", "fredmax"],
        num_bytes=16,
    )


async def reduction_m1_failure_test(
    dut, dtypes, math_ops: str, num_bytes: int
):
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
                f"coralnpu_hw/tests/cocotb/rvv/arithmetics/{elf_name}"
            )
            await fixture.load_elf_and_lookup_symbols(
                elf_path,
                [
                    'in_buf_1', 'scalar_input', 'out_buf', 'vstart', 'vl',
                    'faulted', 'mcause'
                ],
            )
            math_op, dtype = pattern_extract.match(elf_name).groups()
            np_type = STR_TO_NP_TYPE[dtype]
            itemsize = np.dtype(np_type).itemsize
            num_test_values = int(num_bytes / np.dtype(np_type).itemsize)

            if np.issubdtype(np_type, np.integer):
                min_value = np.iinfo(np_type).min
                max_value = np.iinfo(np_type).max + 1  # One above.
                input_1 = np.random.randint(
                    min_value, max_value, num_test_values, dtype=np_type
                )
                input_2 = np.random.randint(
                    min_value, max_value, 1, dtype=np_type
                )
            else:
                input_1 = np.random.uniform(-10, 10,
                                            num_test_values).astype(np_type)
                input_2 = np.random.uniform(-10, 10, 1).astype(np_type)

            await fixture.write('in_buf_1', input_1)
            await fixture.write('scalar_input', input_2)
            await fixture.write('vstart', np.array([1], dtype=np.uint32))
            await fixture.write('out_buf', np.zeros(1, dtype=np_type))

            await fixture.run_to_halt()
            faulted = (await fixture.read('faulted', 4)).view(np.uint32)
            mcause = (await fixture.read('mcause', 4)).view(np.uint32)
            assert (faulted == True)
            assert (mcause == 0x2)  # Invalid instruction


@cocotb.test()
async def reduction_m1_failure_ops(dut):
    await reduction_m1_failure_test(
        dut=dut,
        dtypes=["int8", "int16", "int32", "uint8", "uint16", "uint32"],
        math_ops=["redsum", "redmin", "redmax"],
        num_bytes=16
    )


@cocotb.test()
async def float32_reduction_m1_failure_ops(dut):
    await reduction_m1_failure_test(
        dut=dut,
        dtypes=["float"],
        math_ops=["fredusum", "fredosum", "fredmin", "fredmax"],
        num_bytes=16
    )


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
        for math_op in math_ops
        for in_dtype, out_dtype in dtypes
    ]
    pattern_extract = re.compile("rvv_widen_(.*)_(.*)_(.*).elf")

    r = runfiles.Create()
    fixture = await Fixture.Create(dut)
    with tqdm.tqdm(widen_op_elfs) as t:
        for elf_name in tqdm.tqdm(widen_op_elfs):
            t.set_postfix({"binary": os.path.basename(elf_name)})
            elf_path = r.Rlocation(
                "coralnpu_hw/tests/cocotb/rvv/arithmetics/" + elf_name
            )
            await fixture.load_elf_and_lookup_symbols(
                elf_path,
                ['in_buf_1', 'in_buf_2', 'out_buf_widen'],
            )
            math_op, in_dtype, out_dtype = pattern_extract.match(elf_name
                                                                 ).groups()
            in_np_type = STR_TO_NP_TYPE[in_dtype]
            out_np_type = STR_TO_NP_TYPE[out_dtype]

            min_value = np.iinfo(in_np_type).min
            max_value = np.iinfo(in_np_type).max + 1  # One above.
            input_1 = np.random.randint(
                min_value, max_value, num_test_values, dtype=in_np_type
            )
            input_2 = np.random.randint(
                min_value, max_value, num_test_values, dtype=in_np_type
            )
            expected_output = np.asarray(
                _get_math_result(input_1, input_2, math_op, dtype=out_np_type),
                dtype=out_np_type
            )
            await fixture.write('in_buf_1', input_1)
            await fixture.write('in_buf_2', input_2)
            await fixture.write(
                'out_buf_widen', np.zeros([num_test_values], dtype=out_np_type)
            )
            await fixture.run_to_halt()

            actual_output = (
                await fixture.read(
                    'out_buf_widen',
                    num_test_values * np.dtype(out_np_type).itemsize
                )
            ).view(out_np_type)
            debug_msg = str({
                'input_1': input_1,
                'input_2': input_2,
                'expected': expected_output,
                'actual': actual_output,
            })

            assert (actual_output == expected_output).all(), debug_msg


@cocotb.test()
async def widen_math_ops_test_impl(dut):
    await _widen_math_ops_test_impl(
        dut=dut,
        dtypes=[['int8', 'int16'], ['int16', 'int32']],
        math_ops=['add', 'sub', 'mul']
    )


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
            'impl', 'vl', 'shift_scalar', 'buf8', 'buf16', 'buf32',
            'buf_shift8', 'buf_shift16'
        ] + list({c['impl']
                  for c in cases}),
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
            0, np.iinfo(in_dtype).max + 1, vl, dtype=in_dtype
        )
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
        dut=dut,
        elf_name='vnsra_test.elf',
        cases=[
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
        dut=dut,
        elf_name='vnsrl_test.elf',
        cases=[
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
        dut=dut,
        elf_name='vnclip_test.elf',
        cases=[
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
async def vnclipu_test(dut):
    """Test vnclipu usage accessible from intrinsics."""

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
            'saturate': True,
        }

    await test_narrowing_math_op(
        dut=dut,
        elf_name='vnclipu_test.elf',
        cases=[
            # 32 to 16, vxv
            make_test_case('vnclipu_wv_u16mf2', 4, np.uint32, vxs=False),
            make_test_case('vnclipu_wv_u16mf2', 3, np.uint32, vxs=False),
            make_test_case('vnclipu_wv_u16m1', 8, np.uint32, vxs=False),
            make_test_case('vnclipu_wv_u16m1', 7, np.uint32, vxs=False),
            make_test_case('vnclipu_wv_u16m2', 16, np.uint32, vxs=False),
            make_test_case('vnclipu_wv_u16m2', 15, np.uint32, vxs=False),
            make_test_case('vnclipu_wv_u16m4', 32, np.uint32, vxs=False),
            make_test_case('vnclipu_wv_u16m4', 31, np.uint32, vxs=False),
            # 32 to 16, vxs
            make_test_case('vnclipu_wx_u16mf2', 4, np.uint32, vxs=True),
            make_test_case('vnclipu_wx_u16mf2', 3, np.uint32, vxs=True),
            make_test_case('vnclipu_wx_u16m1', 8, np.uint32, vxs=True),
            make_test_case('vnclipu_wx_u16m1', 7, np.uint32, vxs=True),
            make_test_case('vnclipu_wx_u16m2', 16, np.uint32, vxs=True),
            make_test_case('vnclipu_wx_u16m2', 15, np.uint32, vxs=True),
            make_test_case('vnclipu_wx_u16m4', 32, np.uint32, vxs=True),
            make_test_case('vnclipu_wx_u16m4', 31, np.uint32, vxs=True),
            # 16 to 8, vxv
            make_test_case('vnclipu_wv_u8mf4', 4, np.uint16, vxs=False),
            make_test_case('vnclipu_wv_u8mf4', 3, np.uint16, vxs=False),
            make_test_case('vnclipu_wv_u8mf2', 8, np.uint16, vxs=False),
            make_test_case('vnclipu_wv_u8mf2', 7, np.uint16, vxs=False),
            make_test_case('vnclipu_wv_u8m1', 16, np.uint16, vxs=False),
            make_test_case('vnclipu_wv_u8m1', 15, np.uint16, vxs=False),
            make_test_case('vnclipu_wv_u8m2', 32, np.uint16, vxs=False),
            make_test_case('vnclipu_wv_u8m2', 31, np.uint16, vxs=False),
            make_test_case('vnclipu_wv_u8m4', 64, np.uint16, vxs=False),
            make_test_case('vnclipu_wv_u8m4', 63, np.uint16, vxs=False),
            # 16 to 8, vxs
            make_test_case('vnclipu_wx_u8mf4', 4, np.uint16, vxs=True),
            make_test_case('vnclipu_wx_u8mf4', 3, np.uint16, vxs=True),
            make_test_case('vnclipu_wx_u8mf2', 8, np.uint16, vxs=True),
            make_test_case('vnclipu_wx_u8mf2', 7, np.uint16, vxs=True),
            make_test_case('vnclipu_wx_u8m1', 16, np.uint16, vxs=True),
            make_test_case('vnclipu_wx_u8m1', 15, np.uint16, vxs=True),
            make_test_case('vnclipu_wx_u8m2', 32, np.uint16, vxs=True),
            make_test_case('vnclipu_wx_u8m2', 31, np.uint16, vxs=True),
            make_test_case('vnclipu_wx_u8m4', 64, np.uint16, vxs=True),
            make_test_case('vnclipu_wx_u8m4', 63, np.uint16, vxs=True),
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
    """
    fixture = await Fixture.Create(dut)
    r = runfiles.Create()
    await fixture.load_elf_and_lookup_symbols(
        r.
        Rlocation('coralnpu_hw/tests/cocotb/rvv/arithmetics/vnclip_test.elf'),
        [
            'impl', 'vnclip_vxsat_check', 'vxsat_result', 'buf32', 'buf16',
            'buf_shift16'
        ],
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
        (
            "vnmsac_vx_test.elf", SAME_TYPE_TEST_CASES,
            lambda x, y, z: x - y * z
        ),
        ("vmadd_vx_test.elf", SAME_TYPE_TEST_CASES, lambda x, y, z: x * y + z),
        (
            "vnmsub_vx_test.elf", SAME_TYPE_TEST_CASES,
            lambda x, y, z: -(x * y) + z
        ),
        ("vfmacc_vf_test.elf", FLOAT_SAME_TYPE_TEST_CASES, None),
        ("vfnmacc_vf_test.elf", FLOAT_SAME_TYPE_TEST_CASES, None),
        ("vfmadd_vf_test.elf", FLOAT_SAME_TYPE_TEST_CASES, None),
        ("vfnmadd_vf_test.elf", FLOAT_SAME_TYPE_TEST_CASES, None),
        ("vfmsac_vf_test.elf", FLOAT_SAME_TYPE_TEST_CASES, None),
        ("vfnmsac_vf_test.elf", FLOAT_SAME_TYPE_TEST_CASES, None),
        ("vfmsub_vf_test.elf", FLOAT_SAME_TYPE_TEST_CASES, None),
        ("vfnmsub_vf_test.elf", FLOAT_SAME_TYPE_TEST_CASES, None),
    ]
    rms = ["rne", "rtz", "rdn", "rup", "rmm"]
    test_binaries_rm = []
    for binary, cases, fn in test_binaries:
        if "vf_" in binary:
            for rm in rms:
                test_binaries_rm.append(
                    (binary.replace(".elf", f"_{rm}.elf"), cases, fn, rm)
                )
        else:
            test_binaries_rm.append((binary, cases, fn, "rne"))

    with tqdm.tqdm(test_binaries_rm) as pbar:
        for test_binary, test_cases, expected_fn, rm_str in pbar:
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
                    print(
                        f"ERROR: symbol {test_fn_name} not found in {test_binary}"
                    )
                    continue
                for vl in [1, vlmax]:
                    rng = np.random.default_rng()
                    if np.issubdtype(vs1_dtype, np.integer):
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
                    else:
                        vs1_data = rng.uniform(-10, 10, vl).astype(vs1_dtype)
                        xs2_data = rng.uniform(-10, 10, 1).astype(xs2_dtype)
                        vd_orig_data = rng.uniform(-10, 10,
                                                   vl).astype(vd_dtype)

                    await fixture.write("vl", np.array([vl], dtype=np.uint32))
                    await fixture.write("vs1", vs1_data)
                    if "vf_" in test_binary:
                        scalar_full = np.zeros(1, dtype=np.uint64)
                        scalar_full[0] = xs2_data.view(np.uint32)[0]
                        await fixture.write("xs2", scalar_full)
                    else:
                        await fixture.write("xs2", xs2_data.astype(np.uint32))
                    await fixture.write("vd", vd_orig_data)

                    await fixture.write_ptr("impl", test_fn_name)
                    await fixture.run_to_halt()

                    if "vf_" in test_binary:
                        math_op = test_binary.split("_vf_")[0][1:]
                        # _get_math_result expects: (vd, vs1, symbol, dtype, z=vs2, rm=rm)
                        # For ternary: x=vd_orig_data, y=vs1_data, z=xs2_data[0]
                        # Wait, C++ does VX_FUNCTION(vd_orig, xs2_data, vs1_data)
                        # So vs1=xs2_data[0], vs2=vs1_data in RISC-V terms.
                        # Wait, in the lambda it was expected_fn(vd_orig_data, xs2_data[0], vs1_data) -> (x, y, z).
                        # Let's pass it to _get_math_result exactly like that: x=vd, y=xs2, z=vs1
                        expected_vd_data = np.asarray(
                            _get_math_result(
                                vd_orig_data,
                                xs2_data[0],
                                math_op,
                                dtype=np.float32,
                                z=vs1_data,
                                rm=rm_str
                            ),
                            dtype=np.float32
                        )
                    else:
                        expected_vd_data = expected_fn(
                            vd_orig_data, xs2_data[0], vs1_data
                        )
                    actual_vd_data = (
                        await
                        fixture.read("vd",
                                     vl * np.dtype(vd_dtype).itemsize)
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
                    actual_mask_bytes = await fixture.read(
                        "vd", num_mask_bytes
                    )

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
                    actual_mask_bytes = await fixture.read(
                        "vd", num_mask_bytes
                    )

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
                    v0_data = rng.integers(
                        0, 256, size=(vl + 7) // 8, dtype=np.uint8
                    )

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
                        await
                        fixture.read("vd",
                                     vl * np.dtype(vd_dtype).itemsize)
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
        test_binary_path,
        ["vl", "vs2", "vs1", "v0_buf", "vd", "impl"] + fn_names
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
            expected_vd_data = np.where(v0_bits, vs1_data,
                                        vs2_data).astype(vd_dtype)
            actual_vd_data = (
                await fixture.read("vd",
                                   vl * np.dtype(vd_dtype).itemsize)
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
                "vd",
                np.zeros(vl * np.dtype(out_dtype).itemsize, dtype=np.uint8)
            )

            await fixture.write_ptr("impl", fn_name)
            await fixture.run_to_halt()

            expected_vd_data = _get_math_result(
                vs2_data, vs1_data, math_op, dtype=out_dtype
            )
            actual_vd_data = (
                await fixture.read("vd",
                                   vl * np.dtype(out_dtype).itemsize)
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
        elf_path = r.Rlocation(
            f"coralnpu_hw/tests/cocotb/rvv/arithmetics/{elf_name}"
        )
        # Extension ops in rvv_vx_arithmetics.cc use NarrowType and Narrow(lmul, factor) for vs1.
        # We test types that result in 16-bit and 32-bit outputs.
        out_dtypes = [np.int16, np.int32] if signed else [np.uint16, np.uint32]

        for out_dtype in out_dtypes:
            out_sew = np.dtype(out_dtype).itemsize * 8
            in_sew = out_sew // factor
            if in_sew < 8:
                continue

            in_dtype = np.dtype(f"int{in_sew}"
                                ) if signed else np.dtype(f"uint{in_sew}")
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
                "vd",
                np.zeros(vl * np.dtype(out_dtype).itemsize, dtype=np.uint8)
            )

            await fixture.write_ptr("impl", fn_name)
            await fixture.run_to_halt()

            expected_vd_data = vs1_data.astype(out_dtype)
            actual_vd_data = (
                await fixture.read("vd",
                                   vl * np.dtype(out_dtype).itemsize)
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
        elf_path = r.Rlocation(
            f"coralnpu_hw/tests/cocotb/rvv/arithmetics/{elf_name}"
        )

        # Test cases similar to binary_op_vx but with fixed immediate 5
        for test_case in SAME_TYPE_TEST_CASES:
            fn_name, vl, vs1_dtype, _, vd_dtype = test_case

            # Filter cases based on elf_name
            if "SIGNED_ONLY" in elf_name and not np.issubdtype(
                    vs1_dtype, np.signedinteger):
                continue
            if "UNSIGNED_ONLY" in elf_name and not np.issubdtype(
                    vs1_dtype, np.unsignedinteger):
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
                "vd",
                np.zeros(vl * np.dtype(vd_dtype).itemsize, dtype=np.uint8)
            )

            await fixture.write_ptr("impl", fn_name)
            await fixture.run_to_halt()

            expected_vd_data = np.asarray(op(vs1_data, imm), dtype=vd_dtype)
            actual_vd_data = (
                await fixture.read("vd",
                                   vl * np.dtype(vd_dtype).itemsize)
            ).view(vd_dtype)

            debug_msg = (
                f"elf: {elf_name}, fn: {fn_name}, vs1: {vs1_data}, imm: {imm}, "
                f"expected: {expected_vd_data}, actual: {actual_vd_data}"
            )
            assert (actual_vd_data == expected_vd_data).all(), debug_msg


def reference_sadd(lhs, rhs):
    dtype = lhs.dtype
    return np.clip(
        lhs.astype(np.int64) + rhs,
        np.iinfo(dtype).min,
        np.iinfo(dtype).max
    )


def reference_ssub(lhs, rhs):
    dtype = lhs.dtype
    return np.clip(
        lhs.astype(np.int64) - rhs,
        np.iinfo(dtype).min,
        np.iinfo(dtype).max
    )


def reference_rsub(lhs, rhs):
    return rhs - lhs


def reference_mul(lhs, rhs):
    return lhs * rhs


def reference_vmulh(lhs, rhs):
    dtype = lhs.dtype
    bitwidth = np.iinfo(dtype).bits
    return ((lhs.astype(np.int64) * rhs) >>
            bitwidth) & (~np.array([0], dtype=dtype))


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
    res = (lhs.astype(np.int64) * rhs + (1 << (bitwidth - 2))) >> (
        bitwidth - 1
    )
    return np.clip(res, np.iinfo(dtype).min, np.iinfo(dtype).max).astype(dtype)


def reference_div(x, y):
    dtype = x.dtype
    x_64 = (
        x.astype(np.int64)
        if np.issubdtype(dtype, np.signedinteger) else x.astype(np.uint64)
    )
    y_64 = (
        y.astype(np.int64)
        if np.issubdtype(dtype, np.signedinteger) else y.astype(np.uint64)
    )

    mask_zero = y_64 == 0
    mask_overflow = np.zeros_like(mask_zero)
    if np.issubdtype(dtype, np.signedinteger):
        min_int = np.iinfo(dtype).min
        mask_overflow = (x_64 == min_int) & (y_64 == -1)

    safe_y = np.where(mask_zero | mask_overflow, 1, y_64)
    with np.errstate(divide="ignore", invalid="ignore"):
        res = np.trunc(x.astype(np.float64) / safe_y.astype(np.float64)
                       ).astype(np.int64)

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
        if np.issubdtype(dtype, np.signedinteger) else x.astype(np.uint64)
    )
    y_64 = (
        y.astype(np.int64)
        if np.issubdtype(dtype, np.signedinteger) else y.astype(np.uint64)
    )

    mask_zero = y_64 == 0
    mask_overflow = np.zeros_like(mask_zero)
    if np.issubdtype(dtype, np.signedinteger):
        min_int = np.iinfo(dtype).min
        mask_overflow = (x_64 == min_int) & (y_64 == -1)

    safe_y = np.where(mask_zero | mask_overflow, 1, y_64)
    with np.errstate(divide="ignore", invalid="ignore"):
        div_res = np.trunc(x.astype(np.float64) / safe_y.astype(np.float64)
                           ).astype(np.int64)
    res = x_64 - div_res * y_64

    res[mask_zero] = x_64[mask_zero]
    res[mask_overflow] = 0

    return res.astype(dtype)


def reference_merge(vs2, vs1, v0):
    res = vs2.copy()
    mask = (
        v0 >> np.arange(8)
    ) & 1  # Simplified mask unpacking for illustration
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
    return ((lhs.view(unsigned_dtype).astype(np.uint64) >> shift)
            & mask).astype(dtype)


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
    if np.dtype(lhs_dtype).kind == "i"
]

WIDENING_BINARY_VX_TEST_CASES = [
    ("test_i8_mf4", 4, np.int8, np.int8, np.int16),
    ("test_i8_mf2", 8, np.int8, np.int8, np.int16),
    ("test_i8_m1", 16, np.int8, np.int8, np.int16),
    ("test_i8_m2", 32, np.int8, np.int8, np.int16),
    ("test_i8_m4", 64, np.int8, np.int8, np.int16),
    ("test_i16_mf2", 4, np.int16, np.int16, np.int32),
    ("test_i16_m1", 8, np.int16, np.int16, np.int32),
    ("test_i16_m2", 16, np.int16, np.int16, np.int32),
    ("test_i16_m4", 32, np.int16, np.int16, np.int32),
]

FLOAT_SAME_TYPE_TEST_CASES = [
    ("test_f32_m1", 4, np.float32, np.float32, np.float32),
    ("test_f32_m2", 8, np.float32, np.float32, np.float32),
    ("test_f32_m4", 16, np.float32, np.float32, np.float32),
    ("test_f32_m8", 32, np.float32, np.float32, np.float32),
]

FLOAT_CROSS_CONVERT_TEST_CASES = [
    c for c in WIDENING_BINARY_VX_TEST_CASES if c[2] in (np.int16, np.uint16)
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
        (
            "vsll_vx_test.elf", SAME_TYPE_RHS_FORCED_UNSIGNED_TEST_CASES,
            reference_sll
        ),
        ("vsrl_vx_test.elf", UNSIGNED_ONLY_TEST_CASES, reference_srl),
        (
            "vsra_vx_test.elf", SIGNED_LHS_UNSIGNED_RHS_ONLY_TEST_CASES,
            reference_sra
        ),
        (
            "vmulhsu_vx_test.elf",
            SIGNED_LHS_UNSIGNED_RHS_ONLY_TEST_CASES,
            reference_vmulh,
        ),
        ("vfadd_vf_test.elf", FLOAT_SAME_TYPE_TEST_CASES, np.add),
        ("vfsub_vf_test.elf", FLOAT_SAME_TYPE_TEST_CASES, np.subtract),
        ("vfmul_vf_test.elf", FLOAT_SAME_TYPE_TEST_CASES, np.multiply),
        ("vfdiv_vf_test.elf", FLOAT_SAME_TYPE_TEST_CASES, np.divide),
        (
            "vfrsub_vf_test.elf", FLOAT_SAME_TYPE_TEST_CASES,
            lambda x, y: np.subtract(y, x)
        ),
        (
            "vfrdiv_vf_test.elf", FLOAT_SAME_TYPE_TEST_CASES,
            lambda x, y: np.divide(y, x)
        ),
    ]
    rms = ["rne", "rtz", "rdn", "rup", "rmm"]
    test_binaries_rm = []
    for binary, cases, fn in test_binaries:
        if "vf_" in binary:
            for rm in rms:
                test_binaries_rm.append(
                    (binary.replace(".elf", f"_{rm}.elf"), cases, fn, rm)
                )
        else:
            test_binaries_rm.append((binary, cases, fn, "rne"))

    with tqdm.tqdm(test_binaries_rm) as pbar:
        for test_binary_op_vx, test_cases, expected_fn, rm_str in pbar:
            pbar.set_postfix({"binary": test_binary_op_vx})
            test_binary_path = r.Rlocation(
                f"coralnpu_hw/tests/cocotb/rvv/arithmetics/{test_binary_op_vx}"
            )

            fn_names = list(set([x[0] for x in test_cases]))
            await fixture.load_elf_and_lookup_symbols(
                test_binary_path, ['vl', 'vs1', 'xs2', 'vd', 'impl'] + fn_names
            )

            for test_fn_name, vlmax, vs1_dtype, xs2_dtype, vd_dtype in test_cases:
                for vl in [1, vlmax - 1, vlmax]:
                    # Write random data to vs1 and xs2
                    rng = np.random.default_rng()
                    if np.issubdtype(vs1_dtype, np.integer):
                        vs1_data = rng.integers(
                            np.iinfo(vs1_dtype).min,
                            np.iinfo(vs1_dtype).max + 1,
                            size=vl,
                            dtype=vs1_dtype
                        )
                        xs2_data = rng.integers(
                            np.iinfo(xs2_dtype).min,
                            np.iinfo(xs2_dtype).max + 1,
                            size=1,
                            dtype=xs2_dtype
                        )
                    else:
                        vs1_data = rng.uniform(-10, 10, vl).astype(vs1_dtype)
                        xs2_data = rng.uniform(-10, 10, 1).astype(xs2_dtype)

                    await fixture.write('vl', np.array([vl], dtype=np.uint32))
                    await fixture.write('vs1', vs1_data)
                    if "vf_" in test_binary_op_vx:
                        scalar_full = np.zeros(1, dtype=np.uint64)
                        scalar_full[0] = xs2_data.view(np.uint32)[0]
                        await fixture.write("xs2", scalar_full)
                    else:
                        await fixture.write('xs2', xs2_data.astype(np.uint32))
                    await fixture.write('vd', np.zeros(128, dtype=np.uint8))

                    # Execute the test function
                    await fixture.write_ptr('impl', test_fn_name)
                    await fixture.run_to_halt()

                    # Read the result and assert
                    if "vf_" in test_binary_op_vx:
                        with np.errstate(divide="ignore", invalid="ignore"):
                            expected_vd_data = _get_math_result(
                                vs1_data,
                                xs2_data[0],
                                test_binary_op_vx.split("_vf_")[0][1:],
                                dtype=np.float32,
                                rm=rm_str
                            )
                    else:
                        expected_vd_data = expected_fn(vs1_data, xs2_data[0])
                    actual_vd_data = (
                        await
                        fixture.read('vd',
                                     vl * np.dtype(vd_dtype).itemsize)
                    ).view(vd_dtype)
                    err_msg = (
                        f"binary: {test_binary_op_vx}, test_fn: {test_fn_name}, vs1: {vs1_data}, xs2: {xs2_data}, "
                        f"expected: {expected_vd_data}, actual: {actual_vd_data}"
                    )
                    if "vf_" in test_binary_op_vx and rm_str == "rmm":
                        # RMM is not natively supported by x86 FPU so we fall back to RNE in Python.
                        # This can cause 1 ULP differences in halfway tie cases.
                        np.testing.assert_allclose(
                            actual_vd_data,
                            expected_vd_data,
                            rtol=1e-6,
                            atol=1e-6,
                            err_msg=err_msg
                        )
                    else:
                        np.testing.assert_array_equal(
                            actual_vd_data, expected_vd_data, err_msg=err_msg
                        )


@cocotb.test()
async def float_comparison_op(dut):
    fixture, r, rng = await _setup_fixture(dut)
    test_binaries = [
        (
            "vmfeq_vv_test.elf",
            FLOAT_SAME_TYPE_TEST_CASES,
            lambda x, y: (x == y).astype(np.uint8),
            False,
        ),
        (
            "vmfeq_vf_test.elf",
            FLOAT_SAME_TYPE_TEST_CASES,
            lambda x, y: (x == y).astype(np.uint8),
            True,
        ),
        (
            "vmfne_vv_test.elf",
            FLOAT_SAME_TYPE_TEST_CASES,
            lambda x, y: (x != y).astype(np.uint8),
            False,
        ),
        (
            "vmfne_vf_test.elf",
            FLOAT_SAME_TYPE_TEST_CASES,
            lambda x, y: (x != y).astype(np.uint8),
            True,
        ),
        (
            "vmflt_vv_test.elf",
            FLOAT_SAME_TYPE_TEST_CASES,
            lambda x, y: (x < y).astype(np.uint8),
            False,
        ),
        (
            "vmflt_vf_test.elf",
            FLOAT_SAME_TYPE_TEST_CASES,
            lambda x, y: (x < y).astype(np.uint8),
            True,
        ),
        (
            "vmfle_vv_test.elf",
            FLOAT_SAME_TYPE_TEST_CASES,
            lambda x, y: (x <= y).astype(np.uint8),
            False,
        ),
        (
            "vmfle_vf_test.elf",
            FLOAT_SAME_TYPE_TEST_CASES,
            lambda x, y: (x <= y).astype(np.uint8),
            True,
        ),
        (
            "vmfgt_vf_test.elf",
            FLOAT_SAME_TYPE_TEST_CASES,
            lambda x, y: (x > y).astype(np.uint8),
            True,
        ),
        (
            "vmfge_vf_test.elf",
            FLOAT_SAME_TYPE_TEST_CASES,
            lambda x, y: (x >= y).astype(np.uint8),
            True,
        ),
    ]
    with tqdm.tqdm(test_binaries) as pbar:
        for test_binary, test_cases, expected_fn, is_vf in pbar:
            pbar.set_postfix({"binary": test_binary})
            test_binary_path = r.Rlocation(
                f"coralnpu_hw/tests/cocotb/rvv/arithmetics/{test_binary}"
            )

            symbols = ["vl", "vs2", "vd", "impl"]
            symbols.append("xs2" if is_vf else "vs1")

            fn_names = list(set([x[0] for x in test_cases]))
            await fixture.load_elf_and_lookup_symbols(
                test_binary_path, symbols + fn_names
            )

            for test_fn_name, vlmax, vs1_dtype, vs2_dtype, vd_dtype in test_cases:
                for vl in [1, vlmax]:
                    vs2_data = rng.standard_normal(vl).astype(vs2_dtype)
                    in1_data = rng.standard_normal(vl).astype(vs1_dtype)

                    await fixture.write("vl", np.array([vl], dtype=np.uint32))
                    await fixture.write("vs2", vs2_data)
                    if is_vf:
                        scalar_bits = in1_data[0:1].view(np.uint32)
                        scalar_full = np.zeros(1, dtype=np.uint64)
                        scalar_full[0] = scalar_bits[0]
                        await fixture.write("xs2", scalar_full)
                    else:
                        await fixture.write("vs1", in1_data)

                    await fixture.write_ptr("impl", test_fn_name)
                    await fixture.run_to_halt()

                    num_mask_bytes = (vl + 7) // 8
                    actual_packed = await fixture.read("vd", num_mask_bytes)
                    actual = np.zeros(vl, dtype=np.uint8)
                    for i in range(vl):
                        if actual_packed[i // 8] & (1 << (i % 8)):
                            actual[i] = 1

                    expected = expected_fn(
                        vs2_data, in1_data[0] if is_vf else in1_data
                    )
                    np.testing.assert_array_equal(actual, expected)


@cocotb.test()
async def float_misc_op(dut):
    fixture, r, rng = await _setup_fixture(dut)
    test_binaries = [
        (
            "vfclass_v_test.elf",
            FLOAT_SAME_TYPE_TEST_CASES,
            reference_fclass,
            False,
            False,
            False,
        ),
        (
            "vfmv_v_f_test.elf",
            FLOAT_SAME_TYPE_TEST_CASES,
            lambda y, vl: np.full(vl, y),
            False,
            True,
            True,
        ),
        (
            "vfsgnj_vf_test.elf",
            FLOAT_SAME_TYPE_TEST_CASES,
            lambda x, y: np.copysign(x, y),
            False,
            True,
            False,
        ),
        (
            "vfsgnjn_vf_test.elf",
            FLOAT_SAME_TYPE_TEST_CASES,
            lambda x, y: np.copysign(x, -y),
            False,
            True,
            False,
        ),
        (
            "vfsgnjx_vf_test.elf",
            FLOAT_SAME_TYPE_TEST_CASES,
            lambda x, y: (
                x.view(np.uint32) ^
                (np.array([y], dtype=np.float32).view(np.uint32) & 0x80000000)
            ).view(np.float32),
            False,
            True,
            False,
        ),
        (
            "vfmerge_vfm_test.elf",
            FLOAT_SAME_TYPE_TEST_CASES,
            lambda x, y, m: np.where(m, y, x),
            True,
            True,
            False,
        ),
    ]

    rms = ["rne", "rtz", "rdn", "rup", "rmm"]
    test_binaries_rm = []
    for binary, cases, fn, has_mask, is_vf, is_move in test_binaries:
        for rm in rms:
            test_binaries_rm.append((
                binary.replace(".elf", f"_{rm}.elf"), cases, fn, has_mask,
                is_vf, is_move, rm
            ))

    with tqdm.tqdm(test_binaries_rm) as pbar:
        for test_binary, test_cases, expected_fn, has_mask, is_vf, is_move, rm_str in pbar:
            pbar.set_postfix({"binary": test_binary})
            test_binary_path = r.Rlocation(
                f"coralnpu_hw/tests/cocotb/rvv/arithmetics/{test_binary}"
            )

            symbols = ["vl", "vd", "impl"]
            opt_symbols = ["vs1", "vs2", "xs2", "v0_buf"]
            fn_names = list(set([x[0] for x in test_cases]))
            await fixture.load_elf_and_lookup_symbols(
                test_binary_path,
                symbols + fn_names,
                optional_symbols=opt_symbols
            )

            for test_fn_name, vlmax, vs1_dtype, vs2_dtype, vd_dtype in test_cases:
                vl = vlmax
                vs2_data = rng.standard_normal(vl).astype(vs2_dtype)
                in1_data = rng.standard_normal(vl).astype(vs1_dtype)
                v0_data = rng.integers(
                    0, 2, vl, dtype=np.uint8
                ) if has_mask else None

                if "vfclass" in test_binary:
                    edge_cases = [
                        -np.inf,
                        -1.0,
                        -1e-40,
                        -0.0,
                        0.0,
                        1e-40,
                        1.0,
                        np.inf,
                        np.nan,
                    ]
                    for i in range(min(vl, len(edge_cases))):
                        vs2_data[i] = edge_cases[i]

                if "vl" in fixture.symbols:
                    await fixture.write("vl", np.array([vl], dtype=np.uint32))
                if "vs2" in fixture.symbols:
                    await fixture.write("vs2", vs2_data)
                if "vs1" in fixture.symbols:
                    await fixture.write("vs1", in1_data)
                if "xs2" in fixture.symbols and is_vf:
                    # Write as 8 bytes to match uint64_t xs2 in C++ and user mandate
                    scalar_val = in1_data[0]
                    scalar_bits = np.array([scalar_val],
                                           dtype=np.float32).view(np.uint32)
                    scalar_full = np.zeros(1, dtype=np.uint64)
                    scalar_full[0] = scalar_bits[0]
                    await fixture.write("xs2", scalar_full)

                if "v0_buf" in fixture.symbols and has_mask:
                    # Mask size in bytes: (vl + 7) // 8
                    mask_bytes = (vl + 7) // 8
                    mask_packed = np.zeros(mask_bytes, dtype=np.uint8)
                    for i in range(vl):
                        if v0_data[i]:
                            mask_packed[i // 8] |= 1 << (i % 8)
                    await fixture.write("v0_buf", mask_packed)

                await fixture.write_ptr("impl", test_fn_name)
                await fixture.run_to_halt()

                actual_vd_dtype = np.uint32 if "vfclass" in test_binary else vd_dtype
                actual = (
                    await fixture.read(
                        "vd",
                        vl * np.dtype(actual_vd_dtype).itemsize
                    )
                ).view(actual_vd_dtype)

                # Buffer choice for reference:
                # vfsgnj (if using #else) use vs1 buffer.
                # vfsgnj_vf_test.elf (using specialized test) uses vs2 buffer.
                # vfmerge uses vs2 buffer.

                vec_in = vs2_data

                libc = ctypes.CDLL(None)
                if rm_str != "rmm" and rm_str in RM_MAP and RM_MAP[
                        rm_str] is not None:
                    libc.fesetround(RM_MAP[rm_str])

                if is_move:
                    expected = expected_fn(in1_data[0], vl)
                elif has_mask:
                    expected = expected_fn(vs2_data, in1_data[0], v0_data)
                elif is_vf:
                    expected = expected_fn(vec_in, in1_data[0])
                else:
                    expected = expected_fn(vec_in)

                if hasattr(libc, "fesetround"):
                    libc.fesetround(0)

                debug_msg = f"binary: {test_binary}, fn: {test_fn_name}, vl: {vl}\n"
                if not is_move:
                    debug_msg += f"vs2: {vs2_data}\n"
                debug_msg += f"vs1: {in1_data}\n"
                if is_vf:
                    debug_msg += f"xs2: {in1_data[0]} (bits: {in1_data[0:1].view(np.uint32)[0]:08x})\n"
                if has_mask:
                    debug_msg += f"mask: {v0_data}\n"
                debug_msg += f"expected: {expected}\nactual: {actual}"

                np.testing.assert_array_equal(
                    actual,
                    expected.astype(actual_vd_dtype),
                    err_msg=debug_msg
                )


@cocotb.test()
async def float_convert_op(dut):
    fixture, r, rng = await _setup_fixture(dut)
    test_binaries = [
        (
            "vfcvt_f_x_v_test.elf",
            FLOAT_SAME_TYPE_TEST_CASES,
            lambda x: x.astype(np.float32),
            np.int32,
            np.float32,
        ),
        (
            "vfcvt_f_xu_v_test.elf",
            FLOAT_SAME_TYPE_TEST_CASES,
            lambda x: x.astype(np.float32),
            np.uint32,
            np.float32,
        ),
        (
            "vfcvt_x_f_v_test.elf",
            FLOAT_SAME_TYPE_TEST_CASES,
            lambda x: np.round(x).astype(np.int32),
            np.float32,
            np.int32,
        ),
        (
            "vfcvt_xu_f_v_test.elf",
            FLOAT_SAME_TYPE_TEST_CASES,
            lambda x: np.clip(np.round(x), 0,
                              np.iinfo(np.uint32).max).astype(np.uint32),
            np.float32,
            np.uint32,
        ),
        (
            "vfcvt_rtz_x_f_v_test.elf",
            FLOAT_SAME_TYPE_TEST_CASES,
            lambda x: np.trunc(x).astype(np.int32),
            np.float32,
            np.int32,
        ),
        (
            "vfcvt_rtz_xu_f_v_test.elf",
            FLOAT_SAME_TYPE_TEST_CASES,
            lambda x: np.clip(np.trunc(x), 0,
                              np.iinfo(np.uint32).max).astype(np.uint32),
            np.float32,
            np.uint32,
        ),
    ]
    rms = ["rne", "rtz", "rdn", "rup", "rmm"]
    test_binaries_rm = []
    for binary, cases, fn, in_type, out_type in test_binaries:
        if "rtz" in binary:
            test_binaries_rm.append(
                (binary, cases, fn, in_type, out_type, "rtz")
            )
        else:
            for rm in rms:
                test_binaries_rm.append((
                    binary.replace(".elf", f"_{rm}.elf"), cases, fn, in_type,
                    out_type, rm
                ))

    with tqdm.tqdm(test_binaries_rm) as pbar:
        for test_binary, test_cases, expected_fn, in_dtype, out_dtype, rm_str in pbar:
            pbar.set_postfix({"binary": test_binary})
            test_binary_path = r.Rlocation(
                f"coralnpu_hw/tests/cocotb/rvv/arithmetics/{test_binary}"
            )
            if not os.path.exists(test_binary_path):
                continue

            await fixture.load_elf_and_lookup_symbols(
                test_binary_path,
                ["vl", "vs2", "vd", "impl"] + [x[0] for x in test_cases],
            )
            for test_fn_name, vlmax, _, _, _ in test_cases:
                vl = vlmax
                if np.issubdtype(in_dtype, np.floating):
                    vs2_data = (rng.standard_normal(vl) * 10).astype(in_dtype)
                elif np.issubdtype(in_dtype, np.unsignedinteger):
                    vs2_data = rng.integers(0, 100, vl, dtype=in_dtype)
                else:
                    vs2_data = rng.integers(-100, 100, vl, dtype=in_dtype)

                await fixture.write("vl", np.array([vl], dtype=np.uint32))
                await fixture.write("vs2", vs2_data)
                await fixture.write_ptr("impl", test_fn_name)
                await fixture.run_to_halt()

                actual = (
                    await
                    fixture.read("vd",
                                 vl * np.dtype(out_dtype).itemsize)
                ).view(out_dtype)

                if out_dtype == np.float32:
                    # Int to float conversion (vfcvt_f_x) is exact unless large int
                    expected = expected_fn(vs2_data)
                else:
                    # Float to Int conversion (vfcvt_x_f)
                    if rm_str == "rtz":
                        res = np.trunc(vs2_data)
                    elif rm_str == "rdn":
                        res = np.floor(vs2_data)
                    elif rm_str == "rup":
                        res = np.ceil(vs2_data)
                    elif rm_str == "rmm":
                        res = np.trunc(vs2_data + np.copysign(0.5, vs2_data))
                    else:  # rne
                        res = np.round(vs2_data)

                    if out_dtype in (np.uint32, np.uint16, np.uint8):
                        res = np.clip(res, 0, np.iinfo(out_dtype).max)
                    else:
                        res = np.clip(
                            res,
                            np.iinfo(out_dtype).min,
                            np.iinfo(out_dtype).max
                        )
                    expected = res.astype(out_dtype)
                np.testing.assert_array_equal(actual, expected)
