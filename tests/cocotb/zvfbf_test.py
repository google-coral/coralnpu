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
from coralnpu_test_utils.sim_backends.verilator_test_fixture import VerilatorTestFixture
from bazel_tools.tools.python.runfiles import runfiles
import struct


def fp32_to_bits(f):
    return struct.unpack('<I', struct.pack('<f', f))[0]


def bits_to_fp32(i):
    return struct.unpack('<f', struct.pack('<I', i & 0xFFFFFFFF))[0]


@cocotb.test()
async def zvfbf_test(dut):
    """Test that runs Zvfbfmin and Zvfbfwma instructions."""
    fixture = await VerilatorTestFixture.Create(dut)
    r = runfiles.Create()
    elf_file = 'zvfbf_test.elf'

    await fixture.load_elf_and_lookup_symbols(
        r.Rlocation('coralnpu_hw/tests/cocotb/' + elf_file),
        ['vfwcvt_res', 'vfncvt_res', 'vfwmacc_res']
    )

    cycles = await fixture.run_to_halt(timeout_cycles=1000000)
    dut._log.info(f"Cycle count: {cycles}")

    # Verify vfwcvtbf16.s.f.vv
    # Expected: 1.5, 2.5, -1.0, 0.0
    expected_vfwcvt = [1.5, 2.5, -1.0, 0.0]
    dut._log.info("Verifying vfwcvt results...")
    for i in range(4):
        addr = fixture.symbols['vfwcvt_res'] + i * 4
        actual_bytes = await fixture.core_mini_axi.read(addr, 4)
        actual_bits = int.from_bytes(actual_bytes.tobytes(), 'little')
        actual_f = bits_to_fp32(actual_bits)
        dut._log.info(
            f"Element {i}: {actual_f} (expected {expected_vfwcvt[i]})"
        )
        assert actual_f == expected_vfwcvt[i]

    # Verify vfncvtbf16.s.f.vv
    # Expected: 0x3fc0, 0x4020, 0xbf80, 0x0000
    expected_vfncvt = [0x3fc0, 0x4020, 0xbf80, 0x0000]
    dut._log.info("Verifying vfncvt results...")
    for i in range(4):
        word_idx = i // 2
        elem_in_word = i % 2
        addr = fixture.symbols['vfncvt_res'] + word_idx * 4
        actual_bytes = await fixture.core_mini_axi.read(addr, 4)
        actual_word = int.from_bytes(actual_bytes.tobytes(), 'little')
        actual_bf16 = (actual_word >> (elem_in_word * 16)) & 0xFFFF
        dut._log.info(
            f"Element {i}: {hex(actual_bf16)} (expected {hex(expected_vfncvt[i])})"
        )
        assert actual_bf16 == expected_vfncvt[i]

    # Verify vfwmaccbf16.v.v.v
    expected_vfwmacc = [4.5, 7.5, -3.0, 0.0]
    dut._log.info("Verifying vfwmacc results...")
    for i in range(4):
        addr = fixture.symbols['vfwmacc_res'] + i * 4
        actual_bytes = await fixture.core_mini_axi.read(addr, 4)
        actual_bits = int.from_bytes(actual_bytes.tobytes(), 'little')
        actual_f = bits_to_fp32(actual_bits)
        dut._log.info(
            f"Element {i}: {actual_f} (expected {expected_vfwmacc[i]})"
        )
        assert actual_f == expected_vfwmacc[i]

    dut._log.info("All Vector BF16 tests passed!")
