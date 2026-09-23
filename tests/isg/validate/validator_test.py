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
"""Unit tests for ISG invariant validator."""

import unittest

from tests.isg.validate.validator import (
    InvariantViolationError,
    extract_payload_lines,
    validate_assembly_lines,
)


class ValidatorTest(unittest.TestCase):

    def _wrap_payload(self, instructions):
        return (["# === ISG RANDOMIZED PAYLOAD START ==="] + instructions +
                ["# === ISG RANDOMIZED PAYLOAD END ==="])

    def test_valid_stream(self):
        valid_lines = self._wrap_payload([
            "addi x1, x2, 100",
            "sw x5, 64(x31)",
            "lw x10, 128(x31)",
            "beq x4, x4, . + 4",
            "jal x6, . + 4",
            "auipc x7, 0",
            "jalr x8, 8(x7)",
            "csrr x12, 0x340",
        ])
        validate_assembly_lines(valid_lines)

    def test_x31_destination_rejected(self):
        invalid_lines = self._wrap_payload(["addi x31, x2, 100"])
        with self.assertRaises(InvariantViolationError):
            validate_assembly_lines(invalid_lines)

    def test_unpinned_load_base_rejected(self):
        invalid_lines = self._wrap_payload(["lw x5, 64(x10)"])
        with self.assertRaises(InvariantViolationError):
            validate_assembly_lines(invalid_lines)

    def test_out_of_bounds_store_rejected(self):
        invalid_lines = self._wrap_payload(["sw x5, 2048(x31)"]
                                           )  # max for 4-byte is 2044
        with self.assertRaisesRegex(InvariantViolationError,
                                    r"out of bounds \[0, 2044\]"):
            validate_assembly_lines(invalid_lines)

    def test_non_reflexive_branch_rejected(self):
        invalid_lines = self._wrap_payload(["beq x1, x2, . + 4"])
        with self.assertRaises(InvariantViolationError):
            validate_assembly_lines(invalid_lines)

    def test_jalr_through_x0_rejected(self):
        # auipc x0, 0 / jalr 8(x0) would jump to absolute address 8.
        invalid_lines = self._wrap_payload(["auipc x0, 0", "jalr x8, 8(x0)"])
        with self.assertRaises(InvariantViolationError):
            validate_assembly_lines(invalid_lines)

    def test_non_stimulus_word_rejected(self):
        for insn in [".word 0xdeadbeef", ".word 0x00000013", ".word"]:
            with self.subTest(insn=insn):
                with self.assertRaises(InvariantViolationError):
                    validate_assembly_lines(
                        self._wrap_payload([insn]), traps_enabled=True
                    )

    def test_unpaired_jalr_rejected(self):
        invalid_lines = self._wrap_payload(["jalr x8, 8(x7)"])
        with self.assertRaises(InvariantViolationError):
            validate_assembly_lines(invalid_lines)

    def test_unauthorized_csr_write_rejected(self):
        invalid_lines = self._wrap_payload(["csrw 0x300, x1"])  # mstatus write
        with self.assertRaises(InvariantViolationError):
            validate_assembly_lines(invalid_lines)

    def test_csr_zero_immediate_pseudo_ops_do_not_write(self):
        # misa (0x301) is readable but not writable.
        # csrci/csrsi with immediate 0 are pure reads and must be accepted.
        valid_lines = self._wrap_payload(["csrci 0x301, 0", "csrsi 0x301, 0"])
        validate_assembly_lines(valid_lines)

    def test_valid_float_stream(self):
        valid_lines = self._wrap_payload([
            "flw f0, 64(x31)",
            "fsw f1, 128(x31)",
            "fadd.s f2, f0, f1, rne",
            "fmadd.s f3, f0, f1, f2, rmm",
            "fcvt.w.s x5, f3, rtz",
            "fmv.x.w x6, f0",
            "fmv.w.x f4, x6",
        ])
        validate_assembly_lines(valid_lines)

    def test_dynamic_rounding_rejected(self):
        invalid_lines = self._wrap_payload(["fmadd.s f3, f0, f1, f2, dyn"])
        with self.assertRaises(InvariantViolationError):
            validate_assembly_lines(invalid_lines)

    def test_zfbfmin_ops_rejected(self):
        for insn in [
                "fcvt.s.bf16 f5, f4",
                "fcvt.bf16.s f6, f5, rne",
                "fmv.x.h x7, f6",
                "fmv.h.x f7, x7",
        ]:
            with self.subTest(insn=insn):
                with self.assertRaises(InvariantViolationError):
                    validate_assembly_lines(self._wrap_payload([insn]))

    def test_branch_target_must_be_exactly_plus_4(self):
        for insn in ["beq x4, x4, . + 40", "bne x4, x4, . + 8",
                     "jal x1, . + 44"]:
            with self.subTest(insn=insn):
                with self.assertRaises(InvariantViolationError):
                    validate_assembly_lines(self._wrap_payload([insn]))

    def test_trap_stimuli_rejected_without_traps(self):
        for insn in ["ecall", ".word 0x0000007b"]:
            with self.subTest(insn=insn):
                with self.assertRaises(InvariantViolationError):
                    validate_assembly_lines(self._wrap_payload([insn]))
                validate_assembly_lines(
                    self._wrap_payload([insn]), traps_enabled=True
                )

    def test_fp_csr_writes_allowed(self):
        valid_lines = self._wrap_payload([
            "csrrw x0, 0x001, x5",  # fflags, write-only
            "csrrw x7, 0x002, x5",  # frm, old value observable
            "csrrwi x0, 0x003, 17",  # fcsr, write-only
            "csrrsi x9, 0x002, 3",
            "csrrci x11, 0x002, 1",
            "csrrs x10, 0x002, x0",  # frm pure read
        ])
        validate_assembly_lines(valid_lines)
        validate_assembly_lines(valid_lines, traps_enabled=True)

    def test_flag_csr_set_clear_rejected(self):
        # Set/clear folds the diverging accrued flags into the written value.
        for insn in [
                "csrrc x0, 0x003, x7",
                "csrrs x0, 0x001, x7",
                "csrrci x0, 0x001, 1",
                "csrrsi x0, 0x003, 4",
                "csrs fflags, x7",
        ]:
            with self.subTest(insn=insn):
                with self.assertRaises(InvariantViolationError):
                    validate_assembly_lines(self._wrap_payload([insn]))

    def test_unsafe_csr_read_rejected(self):
        for insn in [
                "csrrw x7, 0x001, x5",  # observes old fflags
                "csrrs x7, 0x003, x0",  # reads fcsr
                "csrrs x7, 0x343, x0",  # reads mtval
                "csrr x7, fflags",
        ]:
            with self.subTest(insn=insn):
                with self.assertRaises(InvariantViolationError):
                    validate_assembly_lines(self._wrap_payload([insn]))

    def test_unauthorized_csr_immediate_write_rejected(self):
        invalid_lines = self._wrap_payload(["csrrsi x0, 0x300, 8"])  # mstatus
        with self.assertRaises(InvariantViolationError):
            validate_assembly_lines(invalid_lines)

    def test_csrwi_zero_immediate_always_writes(self):
        lines = self._wrap_payload(["csrwi 0x300, 0"])
        with self.assertRaises(InvariantViolationError):
            validate_assembly_lines(lines)

    def test_extract_payload_lines_ignores_labels_and_blank_lines(self):
        raw = self._wrap_payload([
            "",
            "   ",
            "some_label:",
            "addi x1, x2, 100",
            "# just a comment",
            ".balign 4",
            ".word 0x00000013",
        ])
        extracted = extract_payload_lines(raw)
        self.assertEqual(extracted, ["addi x1, x2, 100", ".word 0x00000013"])

    def test_mscratch_write_rejected_when_traps_enabled(self):
        lines = self._wrap_payload(["csrrw x5, 0x340, x6"])
        validate_assembly_lines(lines)
        with self.assertRaises(InvariantViolationError):
            validate_assembly_lines(lines, traps_enabled=True)

    def test_flw_unpinned_base_rejected(self):
        invalid_lines = self._wrap_payload(["flw f0, 64(x10)"])
        with self.assertRaises(InvariantViolationError):
            validate_assembly_lines(invalid_lines)

    def test_fsw_unpinned_base_rejected(self):
        invalid_lines = self._wrap_payload(["fsw f1, 64(x10)"])
        with self.assertRaises(InvariantViolationError):
            validate_assembly_lines(invalid_lines)

    def test_flw_out_of_bounds_rejected(self):
        invalid_lines = self._wrap_payload(["flw f0, 2048(x31)"])
        with self.assertRaises(InvariantViolationError):
            validate_assembly_lines(invalid_lines)

    def test_fsw_out_of_bounds_rejected(self):
        invalid_lines = self._wrap_payload(["fsw f1, 2048(x31)"])
        with self.assertRaises(InvariantViolationError):
            validate_assembly_lines(invalid_lines)

    def test_f31_destination_allowed(self):
        valid_lines = self._wrap_payload([
            "flw f31, 0(x31)",
            "fadd.s f31, f0, f1, rne",
        ])
        validate_assembly_lines(valid_lines)

    def test_omitted_rounding_mode_rejected(self):
        # The assembler encodes an omitted rm as dyn.
        for insn in [
                "fadd.s f2, f0, f1",
                "fmadd.s f3, f0, f1, f2",
                "fsqrt.s f1, f2",
                "fcvt.w.s x5, f3",
                "fcvt.s.wu f4, x6",
        ]:
            with self.subTest(insn=insn):
                with self.assertRaises(InvariantViolationError):
                    validate_assembly_lines(self._wrap_payload([insn]))

    def test_rounding_mode_not_required_without_rm_field(self):
        validate_assembly_lines(
            self._wrap_payload([
                "fsgnj.s f1, f2, f3",
                "fmin.s f1, f2, f3",
                "feq.s x5, f1, f2",
                "fmv.x.w x6, f0",
            ])
        )

    def test_malformed_operands_raise_violation(self):
        for insn in [
                "lw x5, %lo(sym)(x31)",
                "lw x5",
                "jalr x1, x2, 8",
                "beq x4",
        ]:
            with self.subTest(insn=insn):
                with self.assertRaisesRegex(InvariantViolationError, "Line 0"):
                    validate_assembly_lines(self._wrap_payload([insn]))

    def test_custom_base_reg_validated_and_x31_allowed(self):
        lines = [
            ".set isg_base_reg, 10",
            "# === ISG RANDOMIZED PAYLOAD START ===",
            "addi x31, x2, 100",
            "sw x31, 64(x10)",
            "lw x5, 128(x10)",
            "# === ISG RANDOMIZED PAYLOAD END ===",
        ]
        validate_assembly_lines(lines)

        bad_dest = [
            ".set isg_base_reg, 10",
            "# === ISG RANDOMIZED PAYLOAD START ===",
            "addi x10, x2, 100",
            "# === ISG RANDOMIZED PAYLOAD END ===",
        ]
        with self.assertRaises(InvariantViolationError):
            validate_assembly_lines(bad_dest)

        bad_mem = [
            ".set isg_base_reg, 10",
            "# === ISG RANDOMIZED PAYLOAD START ===",
            "lw x5, 64(x31)",
            "# === ISG RANDOMIZED PAYLOAD END ===",
        ]
        with self.assertRaises(InvariantViolationError):
            validate_assembly_lines(bad_mem)


if __name__ == "__main__":
    unittest.main()
