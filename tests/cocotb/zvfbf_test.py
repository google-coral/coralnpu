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

from coralnpu_test_utils.coralflow.runner import coralflow_main, coralflow_test
from bazel_tools.tools.python.runfiles import runfiles
import logging
import struct


def fp32_to_bits(f):
    return struct.unpack('<I', struct.pack('<f', f))[0]


def bits_to_fp32(i):
    return struct.unpack('<f', struct.pack('<I', i & 0xFFFFFFFF))[0]


@coralflow_test
async def zvfbf_test(fixture):
    """Test that runs Zvfbfmin and Zvfbfwma instructions."""
    r = runfiles.Create()
    elf_file = 'zvfbf_test.elf'

    await fixture.load_elf_and_lookup_symbols(
        r.Rlocation('coralnpu_hw/tests/cocotb/' + elf_file),
        ['vfwcvt_res', 'vfncvt_res', 'vfwmacc_res']
    )

    await fixture.run_to_halt(timeout_cycles=1000000)
    cycles = fixture.get_cycle_count()
    logging.info(f"Cycle count: {cycles}")

    # Verify vfwcvtbf16.s.f.vv
    # Expected: 1.5, 2.5, -1.0, 0.0
    expected_vfwcvt = [1.5, 2.5, -1.0, 0.0]
    logging.info("Verifying vfwcvt results...")
    vfwcvt_bytes = bytes(await fixture.read('vfwcvt_res', 16))
    for i in range(4):
        actual_bits = int.from_bytes(vfwcvt_bytes[i * 4:(i + 1) * 4], 'little')
        actual_f = bits_to_fp32(actual_bits)
        logging.info(
            f"Element {i}: {actual_f} (expected {expected_vfwcvt[i]})"
        )
        assert actual_f == expected_vfwcvt[i]

    # Verify vfncvtbf16.s.f.vv
    # Expected: 0x3fc0, 0x4020, 0xbf80, 0x0000
    expected_vfncvt = [0x3fc0, 0x4020, 0xbf80, 0x0000]
    logging.info("Verifying vfncvt results...")
    vfncvt_bytes = bytes(await fixture.read('vfncvt_res', 8))
    for i in range(4):
        word_idx = i // 2
        elem_in_word = i % 2
        actual_word = int.from_bytes(
            vfncvt_bytes[word_idx * 4:(word_idx + 1) * 4], 'little'
        )
        actual_bf16 = (actual_word >> (elem_in_word * 16)) & 0xFFFF
        logging.info(
            f"Element {i}: {hex(actual_bf16)} (expected {hex(expected_vfncvt[i])})"
        )
        assert actual_bf16 == expected_vfncvt[i]

    # Verify vfwmaccbf16.v.v.v
    expected_vfwmacc = [4.5, 7.5, -3.0, 0.0]
    logging.info("Verifying vfwmacc results...")
    vfwmacc_bytes = bytes(await fixture.read('vfwmacc_res', 16))
    for i in range(4):
        actual_bits = int.from_bytes(
            vfwmacc_bytes[i * 4:(i + 1) * 4], 'little'
        )
        actual_f = bits_to_fp32(actual_bits)
        logging.info(
            f"Element {i}: {actual_f} (expected {expected_vfwmacc[i]})"
        )
        assert actual_f == expected_vfwmacc[i]

    logging.info("All Vector BF16 tests passed!")


if __name__ == "__main__":
    coralflow_main()
