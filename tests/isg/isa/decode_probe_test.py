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
"""Hardware decode probe unit test verifying alphabet consistency."""

import json
import os
import unittest

from bazel_tools.tools.python.runfiles import runfiles


class DecodeProbeTest(unittest.TestCase):
    """Tests decoding table properties and pattern validity."""

    @classmethod
    def setUpClass(cls):
        # ALPHABET_JSON holds the runfiles path ($(rlocationpath ...)) of the
        # alphabet under test.
        rlocation = os.environ["ALPHABET_JSON"]
        alphabet_path = runfiles.Create().Rlocation(rlocation)
        if not alphabet_path or not os.path.exists(alphabet_path):
            raise FileNotFoundError(
                f"Could not resolve alphabet runfile {rlocation}"
            )

        with open(alphabet_path, "r", encoding="utf-8") as f:
            cls.alphabet = json.load(f)

    def test_config_and_xlen(self):
        self.assertEqual(self.alphabet["config"], "core_mini_axi")
        self.assertEqual(self.alphabet["xlen"], 32)
        self.assertGreater(len(self.alphabet["instructions"]), 40)
        self.assertGreater(len(self.alphabet["csrs"]), 5)

    def test_instruction_patterns_valid(self):
        """Verifies mask & match invariants for every instruction."""
        for insn in self.alphabet["instructions"]:
            name = insn["name"]
            mask = int(insn["mask"], 16)
            match = int(insn["match"], 16)

            self.assertNotEqual(mask, 0, f"Instruction {name} has zero mask")
            self.assertEqual(
                match & ~mask,
                0,
                f"Instruction {name} match bits not contained in mask: "
                f"match=0x{match:08x}, mask=0x{mask:08x}",
            )
            # Base RISC-V opcodes have bits [1:0] == 11
            self.assertEqual(
                match & 0x3, 0x3,
                f"Instruction {name} does not have opcode[1:0] == 11"
            )

    def test_canonical_decoding(self):
        """Verifies that an instruction's match word decodes uniquely to itself."""
        instructions = self.alphabet["instructions"]
        for target in instructions:
            target_name = target["name"]
            match_word = int(target["match"], 16)

            # Find all instructions matching match_word
            matched = []
            for insn in instructions:
                mask = int(insn["mask"], 16)
                match = int(insn["match"], 16)
                if (match_word & mask) == match:
                    matched.append(insn["name"])

            self.assertEqual(
                matched,
                [target_name],
                f"Instruction {target_name} match word 0x{match_word:08x} "
                f"does not decode uniquely to itself: {matched}",
            )

    def test_invalid_opcodes_do_not_match(self):
        """Verifies that unassigned/illegal opcodes match zero instructions."""
        instructions = self.alphabet["instructions"]
        # 0x00000000, 0xffffffff, 0x0000007b (custom-3 opcode)
        invalid_words = [
            0x00000000, 0xFFFFFFFF, 0x0000007B, 0x0000000B, 0x0000002B
        ]

        for inv in invalid_words:
            matched = [
                insn["name"]
                for insn in instructions
                if (inv & int(insn["mask"], 16)) == int(insn["match"], 16)
            ]
            self.assertEqual(
                matched,
                [],
                f"Invalid word 0x{inv:08x} unexpectedly matched: {matched}",
            )

    def test_csrs_distinct_and_valid(self):
        """Verifies that CSR addresses are unique and non-zero."""
        csrs = self.alphabet["csrs"]
        addrs = set()
        names = set()
        for csr in csrs:
            name = csr["name"]
            addr = csr["address"]
            self.assertNotIn(name, names, f"Duplicate CSR name: {name}")
            self.assertNotIn(
                addr, addrs, f"Duplicate CSR address: {addr} ({name})"
            )
            self.assertNotEqual(addr, 0, f"CSR {name} has reserved address 0")
            names.add(name)
            addrs.add(addr)

        # Core required CSRs must be present
        self.assertIn("MSTATUS", names)
        self.assertIn("MSCRATCH", names)
        self.assertIn("MEPC", names)
        self.assertIn("MCAUSE", names)
        self.assertIn("MTVEC", names)


if __name__ == "__main__":
    unittest.main()
