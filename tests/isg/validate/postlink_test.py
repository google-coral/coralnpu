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
"""Unit tests for the ISG post-link ELF invariant checker."""

import unittest

from tests.isg.validate.postlink import PostLinkViolationError, validate_payload_words

# Subset of alphabet_core_mini_axi.json (mask/match pairs from the Chisel tables).
PATTERNS = [{
    "name": n,
    "mask": m,
    "match": v
} for n, m, v in [
    ("auipc", 0x0000007F, 0x00000017),
    ("jal", 0x0000007F, 0x0000006F),
    ("jalr", 0x0000707F, 0x00000067),
    ("beq", 0x0000707F, 0x00000063),
    ("csrrw", 0x0000307F, 0x00001073),
    ("csrrs", 0x0000307F, 0x00002073),
    ("csrrc", 0x0000307F, 0x00003073),
    ("lw", 0x0000707F, 0x00002003),
    ("sw", 0x0000707F, 0x00002023),
    ("addi", 0x0000707F, 0x00000013),
    ("flw", 0x0000707F, 0x00002007),
    ("fadd.s", 0xFE00007F, 0x00000053),
    ("feq.s", 0xFE00707F, 0xA0002053),
    ("fmv.x.w", 0xFFF0707F, 0xE0000053),
    ("ecall", 0xFFFFFFFF, 0x00000073),
    ("mret", 0xFFFFFFFF, 0x30200073),
]]


def i_type(opcode, rd, f3, rs1, imm):
    return ((imm & 0xFFF) << 20) | (rs1 << 15) | (f3 <<
                                                  12) | (rd << 7) | opcode


def s_type(opcode, f3, rs1, rs2, imm):
    return ((((imm >> 5) & 0x7F) << 25) | (rs2 << 20) | (rs1 << 15)
            | (f3 << 12) | ((imm & 0x1F) << 7) | opcode)


def b_type(f3, rs1, rs2, imm):
    return ((((imm >> 12) & 1) << 31) | (((imm >> 5) & 0x3F) << 25)
            | (rs2 << 20) | (rs1 << 15) | (f3 << 12)
            | (((imm >> 1) & 0xF) << 8) | (((imm >> 11) & 1) << 7) | 0x63)


def j_type(rd, imm):
    return ((((imm >> 20) & 1) << 31) | (((imm >> 1) & 0x3FF) << 21)
            | (((imm >> 11) & 1) << 20) | (((imm >> 12) & 0xFF) << 12)
            | (rd << 7) | 0x6F)


def addi(rd, rs1, imm):
    return i_type(0x13, rd, 0, rs1, imm)


def lw(rd, rs1, imm):
    return i_type(0x03, rd, 2, rs1, imm)


def sw(rs2, rs1, imm):
    return s_type(0x23, 2, rs1, rs2, imm)


def auipc(rd, imm20):
    return (imm20 << 12) | (rd << 7) | 0x17


def jalr(rd, rs1, imm):
    return i_type(0x67, rd, 0, rs1, imm)


def csr(rd, f3, csr_addr, rs1):
    return (csr_addr << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | 0x73


def fadd_s(fd, fs1, fs2, rm):
    return (fs2 << 20) | (fs1 << 15) | (rm << 12) | (fd << 7) | 0x53


class PostLinkTest(unittest.TestCase):

    def assert_ok(self, words, traps_enabled=False):
        validate_payload_words(words, PATTERNS, traps_enabled)

    def assert_bad(self, words, traps_enabled=False):
        with self.assertRaises(PostLinkViolationError):
            validate_payload_words(words, PATTERNS, traps_enabled)

    def test_valid_stream(self):
        self.assert_ok([
            addi(1, 2, 100),
            sw(5, 31, 64),
            lw(10, 31, 2044),
            b_type(0, 4, 4, 4),  # beq x4, x4, .+4
            j_type(6, 4),  # jal x6, .+4
            auipc(7, 0),
            jalr(8, 7, 8),
            csr(12, 2, 0x340, 0),  # csrr x12, mscratch
            csr(0, 1, 0x001, 5),  # csrrw x0, fflags, x5
            csr(3, 5, 0x002, 4),  # csrrwi x3, frm, 4
            fadd_s(1, 2, 3, 0),  # rne
        ])

    def test_empty_payload_rejected(self):
        self.assert_bad([])

    def test_undecodable_word(self):
        self.assert_bad([0x0000007B])
        self.assert_ok([0x0000007B, 0x0000007B], traps_enabled=True)

    def test_trap_mode_accepts_only_generator_stimulus(self):
        for word in [
                0x00000000,  # all-zero (also an illegal 16-bit parcel)
                0xFFFFFFFF,
                0x0000000B,  # custom-0, not the generator's stimulus
                0x00010001,  # two c.nop parcels
        ]:
            with self.subTest(word=f"0x{word:08x}"):
                self.assert_bad([word], traps_enabled=True)

    def test_compressed_encoding_rejected(self):
        self.assert_bad([0x00000001])  # c.nop
        self.assert_bad([0x00000001], traps_enabled=True)

    def test_trap_and_forbidden_ops(self):
        self.assert_bad([0x00000073])  # ecall without traps
        self.assert_ok([0x00000073], traps_enabled=True)
        self.assert_bad([0x30200073], traps_enabled=True)  # mret

    def test_default_traps_enabled_is_false(self):
        with self.assertRaises(PostLinkViolationError):
            validate_payload_words([0x00000073], PATTERNS)

    def test_cli_requires_alphabet_argument(self):
        import sys
        from unittest.mock import patch
        from tests.isg.validate import postlink

        with patch.object(sys, "argv", ["postlink", "test.elf"]):
            with self.assertRaises(SystemExit):
                postlink.main()

    def test_x31_destination_rejected(self):
        self.assert_bad([addi(31, 2, 1)])
        self.assert_bad([csr(31, 2, 0x340, 0)])  # csrr x31, mscratch
        self.assert_bad([0xA0002053 | (31 << 7)])  # feq.s x31, f0, f0
        self.assert_bad([0xE0000053 | (31 << 7)])  # fmv.x.w x31, f0

    def test_rd_field_of_non_gpr_writers_ignored(self):
        self.assert_ok([sw(5, 31, 31)])  # imm[4:0] = 31 sits in the rd field
        self.assert_ok([i_type(0x07, 31, 2, 31, 0)])  # flw f31, 0(x31)
        self.assert_ok([fadd_s(31, 1, 2, 0)])  # fadd.s f31

    def test_unclassifiable_opcode_space_rejected(self):
        # A decodable instruction in a major opcode with no destination rule
        # must fail rather than silently skip the x31 check.
        patterns = PATTERNS + [{
            "name": "custom0",
            "mask": 0x0000007F,
            "match": 0x0000000B,
        }]
        with self.assertRaisesRegex(PostLinkViolationError, "no destination"):
            validate_payload_words([0x0000000B], patterns)

    def test_memory_base_and_bounds(self):
        self.assert_bad([lw(1, 10, 0)])
        self.assert_bad([sw(1, 31, 2048)])
        self.assert_bad([lw(1, 31, -4)])

    def test_branch_and_jump_targets(self):
        self.assert_bad([b_type(0, 1, 2, 4)])  # non-reflexive
        self.assert_bad([b_type(0, 1, 1, 8)])
        with self.assertRaisesRegex(PostLinkViolationError,
                                    r"jal target offset 40 != 4"):
            validate_payload_words([j_type(1, 40)], PATTERNS)

    def test_jalr_pairing(self):
        self.assert_bad([jalr(8, 7, 8)])
        self.assert_bad([auipc(7, 1), jalr(8, 7, 8)])
        self.assert_bad([auipc(6, 0), jalr(8, 7, 8)])
        self.assert_bad([auipc(7, 0), jalr(8, 7, 12)])

    def test_jalr_through_x0_rejected(self):
        # auipc x0, 0 / jalr 8(x0) would jump to absolute address 8.
        self.assert_bad([auipc(0, 0), jalr(8, 0, 8)])

    def test_reserved_rounding_modes_rejected(self):
        for rm in (0b101, 0b110):
            with self.subTest(rm=rm):
                self.assert_bad([fadd_s(1, 2, 3, rm)])
        for rm in range(5):
            with self.subTest(rm=rm):
                self.assert_ok([fadd_s(1, 2, 3, rm)])

    def test_csr_policy(self):
        self.assert_bad([csr(0, 1, 0x300, 1)])  # csrrw mstatus
        self.assert_bad([csr(0, 6, 0x300, 8)])  # csrrsi mstatus, 8
        self.assert_bad([csr(5, 2, 0x001, 0)])  # read fflags
        self.assert_bad([csr(5, 2, 0x343, 0)])  # read mtval
        self.assert_ok([csr(5, 1, 0x340, 6)])  # csrrw mscratch
        self.assert_bad([csr(5, 1, 0x340, 6)], traps_enabled=True)
        self.assert_bad([csr(0, 3, 0x003, 7)])  # csrrc fcsr, x7
        self.assert_bad([csr(0, 6, 0x001, 1)])  # csrrsi fflags, 1
        self.assert_ok([csr(0, 2, 0x001, 0)])  # csrrs x0, fflags, x0: no-op
        self.assert_ok([csr(0, 3, 0x002, 7)])  # csrrc frm, x7

    def test_dynamic_rounding_rejected(self):
        self.assert_bad([fadd_s(1, 2, 3, 7)])

    def test_custom_base_reg_enforced(self):
        validate_payload_words(
            [addi(31, 2, 1), sw(31, 10, 64),
             lw(5, 10, 128)],
            PATTERNS,
            base_reg=10,
        )
        with self.assertRaises(PostLinkViolationError):
            validate_payload_words([addi(10, 2, 1)], PATTERNS, base_reg=10)
        with self.assertRaises(PostLinkViolationError):
            validate_payload_words([lw(5, 31, 64)], PATTERNS, base_reg=10)


if __name__ == "__main__":
    unittest.main()
