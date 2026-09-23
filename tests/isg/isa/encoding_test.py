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
"""Tests for encoding-based destination register-file classification."""

import json
import os
import unittest

from bazel_tools.tools.python.runfiles import runfiles

from tests.isg.gen import constraints as c
from tests.isg.isa import encoding as enc

# Mnemonic oracle for the scalar alphabet. Used only to cross-check the
# encoding rules; the checkers themselves never consult mnemonic lists.
_EXPECTED = {}
for _ops, _dest in [
    (c.LOAD_OPS | c.ALU_IMM_OPS | c.SHIFT_IMM_OPS | c.UNARY_OPS | c.ALU_REG_OPS
     | c.CSR_REG_OPS | c.FLOAT_CMP_OPS | c.FLOAT_CVT_TO_INT_OPS
     | c.FLOAT_MISC_TO_INT_OPS | {"lui", "auipc", "jal", "jalr"}, enc.GPR),
    (c.FLOAT_LOAD_OPS | c.FLOAT_R4_OPS | c.FLOAT_R2_RM_OPS | c.FLOAT_R1_RM_OPS
     | c.FLOAT_SGNJ_OPS | c.FLOAT_MINMAX_OPS | c.FLOAT_CVT_FROM_INT_OPS
     | c.FLOAT_MV_FROM_INT_OPS, enc.FPR),
    (c.STORE_OPS | c.FLOAT_STORE_OPS | c.BRANCH_OPS
     | {"fence", "fencei", "fencetso", "ecall", "ebreak", "mret", "wfi",
        "mpause"}, None),
]:
    for _op in _ops:
        _EXPECTED[_op] = _dest


def _v_arith(funct6, funct3, vd, vs2, vs1, vm=1):
    return ((funct6 << 26) | (vm << 25) | (vs2 << 20) | (vs1 << 15)
            | (funct3 << 12) | (vd << 7) | enc.OP_V)


class EncodingTest(unittest.TestCase):

    @classmethod
    def setUpClass(cls):
        path = runfiles.Create().Rlocation(os.environ["ALPHABET_JSON"])
        with open(path, "r", encoding="utf-8") as f:
            cls.instructions = json.load(f)["instructions"]

    def test_every_alphabet_entry_classifies(self):
        """A new major opcode space in the alphabet must get a rule."""
        for insn in self.instructions:
            with self.subTest(name=insn["name"]):
                enc.dest_register_file(int(insn["match"], 16))

    def test_alphabet_matches_mnemonic_oracle(self):
        for insn in self.instructions:
            name = insn["name"]
            with self.subTest(name=name):
                self.assertIn(name, _EXPECTED, "add the opcode to the oracle")
                self.assertEqual(
                    enc.dest_register_file(int(insn["match"], 16)),
                    _EXPECTED[name],
                )

    def test_zfbfmin_encodings(self):
        self.assertEqual(
            enc.dest_register_file(0xE4000053), enc.GPR
        )  # fmv.x.h
        self.assertEqual(
            enc.dest_register_file(0xF4000053), enc.FPR
        )  # fmv.h.x
        self.assertEqual(
            enc.dest_register_file(0x44800053), enc.FPR
        )  # fcvt.bf16.s

    def test_vector_encodings(self):
        cases = {
            "vsetvli x5, x6": ((0x010 << 20) | (6 << 15) | (0b111 << 12)
                               | (5 << 7) | enc.OP_V, enc.GPR),
            "vadd.vv": (_v_arith(0b000000, 0b000, 1, 2, 3), enc.VPR),
            "vmv.x.s": (_v_arith(0b010000, 0b010, 5, 2, 0b00000), enc.GPR),
            "vcpop.m": (_v_arith(0b010000, 0b010, 5, 2, 0b10000), enc.GPR),
            "vfirst.m": (_v_arith(0b010000, 0b010, 5, 2, 0b10001), enc.GPR),
            "vfmv.f.s": (_v_arith(0b010000, 0b001, 5, 2, 0), enc.FPR),
            "vmv.s.x": (_v_arith(0b010000, 0b110, 1, 0, 5), enc.VPR),
            "vfmv.s.f": (_v_arith(0b010000, 0b101, 1, 0, 5), enc.VPR),
            "vredsum.vs": (_v_arith(0b000000, 0b010, 1, 2, 3), enc.VPR),
            "vle32.v": ((1 << 25) | (31 << 15) | (0b110 << 12) | (1 << 7)
                        | enc.OP_LOAD_FP, enc.VPR),
            "vse32.v": ((1 << 25) | (31 << 15) | (0b110 << 12) | (1 << 7)
                        | enc.OP_STORE_FP, None),
        }
        for name, (word, dest) in cases.items():
            with self.subTest(name=name):
                self.assertEqual(enc.dest_register_file(word), dest)

    def test_unknown_major_opcode_raises(self):
        for word in [0x0000000B, 0x0000002B, 0x0000005B, 0x0000007B]:
            with self.subTest(word=f"0x{word:08x}"):
                with self.assertRaises(ValueError):
                    enc.dest_register_file(word)

    def test_compressed_parcel_raises(self):
        with self.assertRaises(ValueError):
            enc.dest_register_file(0x00000001)


if __name__ == "__main__":
    unittest.main()
