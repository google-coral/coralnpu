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
from coralnpu_test_utils.sim_test_fixture import Fixture
from bazel_tools.tools.python.runfiles import runfiles
import numpy as np
import random
import struct

# Rounding modes
RNE = 0
RTZ = 1
RDN = 2
RUP = 3
RMM = 4

# fflags
F_NV = 1 << 4
F_DZ = 1 << 3
F_OF = 1 << 2
F_UF = 1 << 1
F_NX = 1 << 0


def fp32_to_bits(f):
    return struct.unpack('<I', struct.pack('<f', f))[0]


def bits_to_fp32(i):
    return struct.unpack('<f', struct.pack('<I', i & 0xFFFFFFFF))[0]


def bf16_to_fp32_bits_with_flags(bf16_bits):
    # BF16 to FP32 is always exact.
    # NV set only on signaling NaN.
    flags = 0
    # BF16 NaN: exp=0xFF, mant != 0
    # Signaling NaN if top bit of mantissa (bit 6) is 0.
    if (bf16_bits & 0x7f80) == 0x7f80 and (bf16_bits & 0x7f) != 0:
        if not (bf16_bits & 0x40):  # sNaN
            flags |= F_NV

    fp32_bits = (bf16_bits << 16) & 0xFFFFFFFF
    return fp32_bits, flags


def fp32_to_bf16_bits_with_flags(fp32_bits, rm=RNE):
    sign = (fp32_bits >> 31) & 1
    exp = (fp32_bits >> 23) & 0xFF
    mant = fp32_bits & 0x7FFFFF
    flags = 0

    if exp == 0xFF:  # Inf or NaN
        if mant != 0:  # NaN
            if not (mant & 0x400000):  # sNaN
                flags |= F_NV
            # Canonicalize NaN for BF16
            res_mant = (mant >> 16) | 0x40  # make it qNaN
            return (sign << 15) | (0xFF << 7) | res_mant, flags
        return (sign << 15) | (0xFF << 7), flags

    # Rounding bits
    round_bit = (fp32_bits >> 15) & 1
    sticky_bit = 1 if (fp32_bits & 0x7FFF) != 0 else 0

    if round_bit or sticky_bit:
        flags |= F_NX

    # Value is in range if exp is normal or subnormal
    # BF16 and FP32 share the same exponent range, but BF16 has less mantissa.
    # Max BF16 value: (2 - 2^-7) * 2^127
    # Bit pattern: exp=0xFE, mant=0x7F -> 0x7F7F

    upper = (fp32_bits >> 16)
    lsb = upper & 1

    increment = 0
    if rm == RNE:
        if round_bit and (lsb or sticky_bit):
            increment = 1
    elif rm == RTZ:
        increment = 0
    elif rm == RDN:
        if sign and (round_bit or sticky_bit):
            increment = 1
    elif rm == RUP:
        if not sign and (round_bit or sticky_bit):
            increment = 1
    elif rm == RMM:
        if round_bit:
            increment = 1

    res_raw = upper + increment
    res = res_raw & 0xFFFF

    # Check Overflow: if exponent becomes 0xFF due to rounding
    if (res_raw & 0x7F80) == 0x7f80 and exp != 0xFF:
        flags |= F_OF | F_NX

    # Check Underflow: if result is tiny and inexact
    # Tiny means magnitude < min normal BF16 (2^-126)
    is_tiny = (exp == 0) or (res_raw & 0x7f80) == 0
    if is_tiny and (flags & F_NX):
        flags |= F_UF

    return res, flags


def fmv_h_x_expected_with_flags(in_32):
    # fmv.h.x: moves rs1[15:0] to rd[15:0], NaN-boxes bits [31:16] with 1s.
    # Does not modify fflags.
    expected_bits = 0xFFFF0000 | (in_32 & 0xFFFF)
    return expected_bits, 0


def fmv_x_h_expected_with_flags(in_32):
    # fmv.x.h: moves fs1[15:0] to rd[15:0], sign-extends bit 15 to bits [31:16].
    # Does not modify fflags.
    lower_16 = in_32 & 0xFFFF
    if lower_16 & 0x8000:
        expected_bits = 0xFFFF0000 | lower_16
    else:
        expected_bits = lower_16
    return expected_bits, 0


def fmv_roundtrip_expected_with_flags(in_32):
    # GPR -> fmv.h.x -> FPR -> fmv.x.h -> GPR
    # fmv.h.x extracts in_32[15:0], fmv.x.h sign-extends bit 15.
    lower_16 = in_32 & 0xFFFF
    if lower_16 & 0x8000:
        expected_bits = 0xFFFF0000 | lower_16
    else:
        expected_bits = lower_16
    return expected_bits, 0


@cocotb.test()
async def zfbfmin_test(dut):
    """Test that runs Zfbfmin conversion and move instructions with various inputs."""
    fixture = await Fixture.Create(dut)
    r = runfiles.Create()
    elf_file = 'zfbfmin_test.elf'

    await fixture.load_elf_and_lookup_symbols(
        r.Rlocation('coralnpu_hw/tests/cocotb/' + elf_file), [
            'fcvt_s_bf16_cases', 'fcvt_bf16_s_cases', 'num_fcvt_s_bf16_cases',
            'num_fcvt_bf16_s_cases', 'fmv_cases', 'num_fmv_cases'
        ]
    )

    symbols = fixture.symbols

    # Test cases for fcvt.s.bf16 (BF16 to FP32)
    s_bf16_inputs = [
        0x3fc0,  # 1.5f
        0x0000,  # 0.0
        0x8000,  # -0.0
        0x7f80,  # +Inf
        0xff80,  # -Inf
        0x7fc0,  # qNaN
        0x7fbf,  # sNaN
        0x0001,  # min subnormal
    ]
    for _ in range(10):
        s_bf16_inputs.append(random.getrandbits(16))

    for i, val in enumerate(s_bf16_inputs):
        await fixture.core_mini_axi.write_word(
            symbols['fcvt_s_bf16_cases'] + i * 16, 0xFFFF0000 | val
        )
        await fixture.core_mini_axi.write_word(
            symbols['fcvt_s_bf16_cases'] + i * 16 + 4, RNE
        )

    await fixture.core_mini_axi.write_word(
        symbols['num_fcvt_s_bf16_cases'], len(s_bf16_inputs)
    )

    # Test cases for fcvt.bf16.s (FP32 to BF16)
    bf16_s_inputs = [
        (1.5, RNE),
        (2.75, RNE),
        (0.0, RNE),
        (-0.0, RNE),
        (float('inf'), RNE),
        (float('-inf'), RNE),
        (bits_to_fp32(0x7f800001), RNE),  # sNaN
        (bits_to_fp32(0x7f800000 + (1 << 22)), RNE),  # qNaN
        # Max FP32 (overflows to BF16 Inf)
        (bits_to_fp32(0x7f7fffff), RNE),
        # Rounding tests
        (1.00390625, RNE),  # 1.0 + 2^-8
        (1.00390625, RTZ),
        # Tiny FP32 (underflow)
        (bits_to_fp32(0x00000001), RNE),  # min FP32 subnormal
    ]

    for _ in range(10):
        f = random.uniform(-100, 100)
        bf16_s_inputs.append((f, random.choice([RNE, RTZ, RDN, RUP, RMM])))

    for i, (val, rm) in enumerate(bf16_s_inputs):
        bits = fp32_to_bits(val)
        await fixture.core_mini_axi.write_word(
            symbols['fcvt_bf16_s_cases'] + i * 16, bits
        )
        await fixture.core_mini_axi.write_word(
            symbols['fcvt_bf16_s_cases'] + i * 16 + 4, rm
        )

    await fixture.core_mini_axi.write_word(
        symbols['num_fcvt_bf16_s_cases'], len(bf16_s_inputs)
    )

    # Combined test cases for FMV instructions (fmv.h.x, fmv.x.h, fmv_roundtrip)
    fmv_inputs = [
        0x00000000,  # +0.0
        0x00008000,  # -0.0
        0x00003fc0,  # 1.5 BF16 (positive normal)
        0x0000bfc0,  # -1.5 BF16 (negative normal)
        0x00007f80,  # +Inf
        0x0000ff80,  # -Inf
        0x00007fc0,  # qNaN
        0x00007fbf,  # sNaN
        0x00000001,  # min positive subnormal
        0x00008001,  # min negative subnormal
        0xFFFF3fc0,  # NaN-boxed positive BF16
        0xFFFFbfc0,  # NaN-boxed negative BF16
        0xFFFF7f80,  # NaN-boxed +Inf
        0xFFFFFF80,  # NaN-boxed -Inf
        0xFFFF7fc0,  # NaN-boxed qNaN
        0xFFFF7fbf,  # NaN-boxed sNaN
        0xFFFF0000,  # NaN-boxed +0.0
        0xFFFF8000,  # NaN-boxed -0.0
        0xFFFF0001,  # NaN-boxed positive subnormal
        0xFFFF8001,  # NaN-boxed negative subnormal
        0x12343fc0,  # Non-zero dirty high bits with positive normal
        0x1234bfc0,  # Non-zero dirty high bits with negative normal
        0x12340042,  # Arbitrary dirty high bits with positive sign bit
        0x12348042,  # Arbitrary dirty high bits with negative sign bit
        0xABCD0001,  # Dirty high bits with positive subnormal
        0xABCD8001,  # Dirty high bits with negative subnormal
        0x55555555,  # Alternating pattern (bit 15 = 0)
        0xAAAAAAAA,  # Alternating pattern (bit 15 = 1)
        0xDEADBEEF,  # Arbitrary 32-bit pattern (bit 15 = 1)
        0xFFFFFFFF,  # All ones
    ]
    for _ in range(10):
        fmv_inputs.append(random.getrandbits(32))

    fmv_data = np.zeros((len(fmv_inputs), 7), dtype=np.uint32)
    for i, val in enumerate(fmv_inputs):
        fmv_data[i, 0] = val
    await fixture.core_mini_axi.write(symbols['fmv_cases'], fmv_data.flatten())
    await fixture.core_mini_axi.write_word(
        symbols['num_fmv_cases'], len(fmv_inputs)
    )

    # Run the core
    await fixture.run_to_halt(timeout_cycles=1000000)

    # Verify fcvt.s.bf16
    dut._log.info("Verifying fcvt.s.bf16 results...")
    for i, val in enumerate(s_bf16_inputs):
        addr = symbols['fcvt_s_bf16_cases'] + i * 16 + 8
        actual_bytes = await fixture.core_mini_axi.read_word(addr)
        actual_bits = int.from_bytes(actual_bytes.tobytes(), 'little')

        flags_bytes = await fixture.core_mini_axi.read_word(addr + 4)
        actual_flags = int.from_bytes(flags_bytes.tobytes(), 'little')

        expected_bits, expected_flags = bf16_to_fp32_bits_with_flags(val)

        is_expected_nan = (expected_bits & 0x7f800000
                           ) == 0x7f800000 and (expected_bits & 0x7fffff) != 0
        is_actual_nan = (actual_bits & 0x7f800000
                         ) == 0x7f800000 and (actual_bits & 0x7fffff) != 0

        if is_expected_nan:
            assert is_actual_nan, f"Case {i}: Input {hex(val)}, Expected NaN, got {hex(actual_bits)}"
        else:
            assert actual_bits == expected_bits, f"Case {i}: Input {hex(val)}, Expected {hex(expected_bits)}, got {hex(actual_bits)}"

        assert actual_flags == expected_flags, f"Case {i}: Input {hex(val)}, Expected flags {hex(expected_flags)}, got {hex(actual_flags)}"

    # Verify fcvt.bf16.s
    dut._log.info("Verifying fcvt.bf16.s results...")
    for i, (val, rm) in enumerate(bf16_s_inputs):
        addr = symbols['fcvt_bf16_s_cases'] + i * 16 + 8
        actual_bytes = await fixture.core_mini_axi.read_word(addr)
        actual_bits = int.from_bytes(actual_bytes.tobytes(), 'little')

        flags_bytes = await fixture.core_mini_axi.read_word(addr + 4)
        actual_flags = int.from_bytes(flags_bytes.tobytes(), 'little')

        actual_bf16 = actual_bits & 0xFFFF
        expected_bf16, expected_flags = fp32_to_bf16_bits_with_flags(
            fp32_to_bits(val), rm
        )

        is_expected_nan = (expected_bf16
                           & 0x7f80) == 0x7f80 and (expected_bf16
                                                    & 0x7f) != 0
        is_actual_nan = (actual_bf16
                         & 0x7f80) == 0x7f80 and (actual_bf16
                                                  & 0x7f) != 0

        if is_expected_nan:
            assert is_actual_nan, f"Case {i}: Input {val} (RM {rm}), Expected NaN, got {hex(actual_bf16)}"
        else:
            assert actual_bf16 == expected_bf16, f"Case {i}: Input {val} (RM {rm}), Expected {hex(expected_bf16)}, got {hex(actual_bf16)}"
            assert (
                actual_bits >> 16
            ) == 0xFFFF, f"Case {i}: Result not NaN-boxed: {hex(actual_bits)}"

        # Verify flags
        assert actual_flags == expected_flags, f"Case {i}: Input {val} (RM {rm}), Expected flags {hex(expected_flags)}, got {hex(actual_flags)}"

    # Verify fmv instructions
    dut._log.info("Verifying fmv results...")
    fmv_results = (
        await
        fixture.core_mini_axi.read(symbols['fmv_cases'],
                                   len(fmv_inputs) * 28)
    ).view(np.uint32).reshape(-1, 7)

    errors = []

    # Verify fmv.h.x
    for i, val in enumerate(fmv_inputs):
        actual_bits = int(fmv_results[i, 1])
        actual_flags = int(fmv_results[i, 2])

        expected_bits, expected_flags = fmv_h_x_expected_with_flags(val)

        if actual_bits != expected_bits:
            errors.append(
                f"fmv.h.x Case {i}: Input {hex(val)}, Expected {hex(expected_bits)}, got {hex(actual_bits)}"
            )
        if actual_flags != expected_flags:
            errors.append(
                f"fmv.h.x Case {i}: Input {hex(val)}, Expected flags {hex(expected_flags)}, got {hex(actual_flags)}"
            )

    # Verify fmv.x.h
    for i, val in enumerate(fmv_inputs):
        actual_bits = int(fmv_results[i, 3])
        actual_flags = int(fmv_results[i, 4])

        expected_bits, expected_flags = fmv_x_h_expected_with_flags(val)

        if actual_bits != expected_bits:
            errors.append(
                f"fmv.x.h Case {i}: Input {hex(val)}, Expected {hex(expected_bits)}, got {hex(actual_bits)}"
            )
        if actual_flags != expected_flags:
            errors.append(
                f"fmv.x.h Case {i}: Input {hex(val)}, Expected flags {hex(expected_flags)}, got {hex(actual_flags)}"
            )

    # Verify fmv roundtrip
    for i, val in enumerate(fmv_inputs):
        actual_bits = int(fmv_results[i, 5])
        actual_flags = int(fmv_results[i, 6])

        expected_bits, expected_flags = fmv_roundtrip_expected_with_flags(val)

        if actual_bits != expected_bits:
            errors.append(
                f"fmv roundtrip Case {i}: Input {hex(val)}, Expected {hex(expected_bits)}, got {hex(actual_bits)}"
            )
        if actual_flags != expected_flags:
            errors.append(
                f"fmv roundtrip Case {i}: Input {hex(val)}, Expected flags {hex(expected_flags)}, got {hex(actual_flags)}"
            )

    if errors:
        dut._log.error(f"Zfbfmin test encountered {len(errors)} failure(s):")
        for err in errors:
            dut._log.error(f"  {err}")
        assert len(
            errors
        ) == 0, f"Zfbfmin test failed with {len(errors)} error(s):\n" + "\n".join(
            errors[:10]
        )

    dut._log.info("All Zfbfmin tests passed!")
