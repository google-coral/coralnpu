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
"""Unit tests for ISG trap generation and epilogue verification."""

import random
import unittest

from tests.isg.gen.epilogue import generate_epilogue
from tests.isg.gen.prologue import generate_prologue
from tests.isg.gen.traps import ILLEGAL_WORDS, is_trap_op, synthesize_trap


class TrapsTest(unittest.TestCase):

    def test_is_trap_op(self):
        self.assertTrue(is_trap_op("ecall"))
        self.assertTrue(is_trap_op("undef"))
        self.assertFalse(is_trap_op("add"))
        self.assertFalse(is_trap_op("lw"))

    def test_synthesize_trap_ecall(self):
        lines = synthesize_trap("ecall", random.Random(0))
        self.assertEqual(lines, ["ecall"])

    def test_synthesize_trap_undef(self):
        lines = synthesize_trap("undef", random.Random(0))
        self.assertEqual(len(lines), 1)
        self.assertTrue(lines[0].startswith(".word 0x"))
        val = int(lines[0].split()[1], 16)
        self.assertIn(val, ILLEGAL_WORDS)

    def test_prologue_with_traps_enabled(self):
        lines = generate_prologue(traps_enabled=True)
        text = "\n".join(lines)
        self.assertIn("isg_trap_handler", text)
        self.assertIn("csrw mtvec", text)
        self.assertIn("csrw mscratch", text)

    def test_prologue_initializes_float_state(self):
        lines = generate_prologue()
        text = "\n".join(lines)
        self.assertIn("fmv.w.x f0, x0", text)
        self.assertIn("fmv.w.x f31, x0", text)
        self.assertIn("csrw fcsr, x0", text)

    def test_epilogue_with_traps_enabled(self):
        lines = generate_epilogue(traps_enabled=True, expected_trap_count=3)
        text = "\n".join(lines)
        self.assertIn("isg_trap_handler:", text)
        self.assertIn("mret", text)
        self.assertIn("isg_trap_save:", text)
        self.assertIn("li   x7, 3", text)


if __name__ == "__main__":
    unittest.main()
