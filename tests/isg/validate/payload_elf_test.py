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
"""End-to-end check of read_payload_words on real linked ISG ELFs.

For each (assembly, ELF) pair, the linked payload must contain exactly one
32-bit word per payload source line, and each word must decode to the
mnemonic written in the source. This pins down read_payload_words (symbol
lookup, section slicing) and confirms that the assembler/linker emitted the
payload one-for-one.

Usage: payload_elf_test --alphabet=<json> [--traps-enabled] <asm> <elf> ...
"""

import argparse
import re
import sys
import unittest

from tests.isg.gen.constraints import ILLEGAL_STIMULUS_WORDS, OPCODE_TO_ASM
from tests.isg.validate.postlink import (
    decode,
    load_alphabet_patterns,
    read_base_reg,
    read_payload_words,
    validate_payload_words,
)
from tests.isg.validate.validator import extract_payload_lines

# Assembler mnemonic -> alphabet entry name, where they differ.
_ASM_TO_ALPHABET = {asm: op for op, asm in OPCODE_TO_ASM.items()}
# The alphabet's csrr* entries cover the immediate forms.
_ASM_TO_ALPHABET.update({
    "csrrwi": "csrrw",
    "csrrsi": "csrrs",
    "csrrci": "csrrc"
})

_ARGS = None


class PayloadElfTest(unittest.TestCase):

    def test_payload_words_match_source(self):
        patterns = load_alphabet_patterns(_ARGS.alphabet)
        pairs = list(zip(_ARGS.files[::2], _ARGS.files[1::2]))
        self.assertTrue(pairs)
        for asm_path, elf_path in pairs:
            with self.subTest(elf=elf_path):
                with open(asm_path, "r", encoding="utf-8") as f:
                    src = extract_payload_lines(f.readlines())
                words = read_payload_words(elf_path)
                base_reg = read_base_reg(elf_path)
                self.assertEqual(len(words), len(src))
                validate_payload_words(
                    words, patterns, _ARGS.traps_enabled, base_reg=base_reg
                )
                for line, word in zip(src, words):
                    op = re.split(r"\s+", line.split("#")[0].strip())[0]
                    names = decode(word, patterns)
                    if op == ".word":
                        self.assertIn(word, ILLEGAL_STIMULUS_WORDS, line)
                        self.assertEqual(names, [], line)
                    else:
                        self.assertEqual(
                            names,
                            [_ASM_TO_ALPHABET.get(op, op)],
                            f"{line} -> 0x{word:08x}",
                        )


def _parse_args(argv):
    parser = argparse.ArgumentParser()
    parser.add_argument("--alphabet", required=True)
    parser.add_argument("--traps-enabled", action="store_true")
    parser.add_argument("files", nargs="+", help="asm/elf path pairs")
    args, rest = parser.parse_known_args(argv)
    if len(args.files) % 2:
        parser.error("files must be (asm, elf) pairs")
    return args, rest


if __name__ == "__main__":
    _ARGS, _rest = _parse_args(sys.argv[1:])
    unittest.main(argv=[sys.argv[0]] + _rest)
