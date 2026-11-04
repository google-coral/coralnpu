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

import unittest
import queue
import numpy as np

from coralnpu_test_utils.dispatch_verifier.disasm import disassemble

from tb.isa import csr_addr, is_counter_access, is_csr_op, rd
from tb.retired_insn import RetiredInsn, unpack_writes
from tb.analysis import AnalysisPort
from tb.lockstep import ExpectedDifferences, LockstepChecker

# Real encodings, taken from the vwmul RVVI trace.
CSRWI_MINSTRET_0 = 0xB0205073  # csrwi minstret, 0
CSRR_A0_MINSTRET = 0xB0202573  # csrr a0, minstret
CSRR_A1_MINSTRETH = 0xB82025F3  # csrr a1, minstreth
AUIPC_SP = 0x00018117  # auipc sp, 0x18
ADDI_SP = 0xFF010113  # addi sp, sp, -16
CSRR_A0_MSTATUS = 0x30002573  # csrr a0, mstatus
ECALL = 0x00000073


class IsaTest(unittest.TestCase):

    def test_csr_fields(self):
        self.assertEqual(csr_addr(CSRR_A0_MINSTRET), 0xB02)
        self.assertEqual(rd(CSRR_A0_MINSTRET), 10)

    def test_is_csr_op(self):
        self.assertTrue(is_csr_op(CSRR_A0_MSTATUS))
        self.assertTrue(is_csr_op(CSRWI_MINSTRET_0))
        self.assertFalse(is_csr_op(ECALL))
        self.assertFalse(is_csr_op(AUIPC_SP))

    def test_is_counter_access(self):
        for insn in (CSRWI_MINSTRET_0, CSRR_A0_MINSTRET, CSRR_A1_MINSTRETH):
            self.assertTrue(is_counter_access(insn), hex(insn))
        for insn in (CSRR_A0_MSTATUS, ECALL, AUIPC_SP, ADDI_SP):
            self.assertFalse(is_counter_access(insn), hex(insn))

    def test_custom_counter_set(self):
        only_mstatus = frozenset({0x300})
        self.assertTrue(is_counter_access(CSRR_A0_MSTATUS, only_mstatus))
        self.assertFalse(is_counter_access(CSRR_A0_MINSTRET, only_mstatus))


class RetiredInsnTest(unittest.TestCase):

    def test_single_write(self):
        txn = RetiredInsn(
            order=4,
            pc=0x10,
            insn=AUIPC_SP,
            x_wb=1 << 2,
            x_wdata=0x18010 << 64
        )
        self.assertEqual(txn.x_writes(), {2: 0x18010})

    def test_x0_is_skipped(self):
        txn = RetiredInsn(order=0, pc=0, insn=0, x_wb=1, x_wdata=0x1234)
        self.assertEqual(txn.x_writes(), {})

    def test_top_register_and_full_width(self):
        data = (0xDEADBEEF << (32 * 31)) | (0xFFFFFFFF << (32 * 5))
        txn = RetiredInsn(
            order=0, pc=0, insn=0, x_wb=(1 << 31) | (1 << 5), x_wdata=data
        )
        self.assertEqual(txn.x_writes(), {5: 0xFFFFFFFF, 31: 0xDEADBEEF})

    def test_f0_is_kept(self):
        txn = RetiredInsn(order=0, pc=0, insn=0, f_wb=1, f_wdata=0x3F800000)
        self.assertEqual(txn.f_writes(), {0: 0x3F800000})

    def test_no_writes(self):
        self.assertEqual(unpack_writes(0, 0xFFFF), {})

    def test_str(self):
        txn = RetiredInsn(
            order=4,
            pc=0x10,
            insn=AUIPC_SP,
            x_wb=1 << 2,
            x_wdata=0x18010 << 64
        )
        self.assertEqual(
            str(txn),
            f"#4 pc=0x0010 insn=0x00018117 ({disassemble(txn.insn, txn.pc)}) x2=0x18010"
        )

    def test_str_never_raises(self):
        txn = RetiredInsn(order=0, pc=0, insn=0xFFFFFFFF)
        self.assertIn("insn=0xffffffff", str(txn))


class AnalysisPortTest(unittest.TestCase):

    def test_every_subscriber_gets_every_item(self):
        port = AnalysisPort("ap")
        first, second = queue.Queue(), queue.Queue()
        port.connect(first)
        port.connect(second)
        port.write("a")
        port.write("b")
        self.assertEqual(port.count, 2)
        for q in (first, second):
            self.assertEqual([q.get_nowait(), q.get_nowait()], ["a", "b"])

    def test_write_without_subscribers(self):
        port = AnalysisPort("ap")
        port.write("a")
        self.assertEqual(port.count, 1)


class FakeIss:
    """Just enough of CoralNPUV2Simulator for LockstepChecker.

    `program` lists the (pc, {register: value}) steps the ISS will execute.
    """

    def __init__(self, program):
        self.program = list(program)
        self.regs: dict[str, int] = {}
        self.memory: dict[int, int] = {}

    def read_register(self, name: str) -> str:
        if name == "pc":
            return hex(self.program[0][0] if self.program else 0xFFFFFFFF)
        return hex(self.regs.get(name, 0))

    def write_register(self, name: str, value: int):
        self.regs[name] = value

    def step(self, n: int) -> int:
        for _ in range(n):
            _, writes = self.program.pop(0)
            self.regs.update({f"x{reg}": val for reg, val in writes.items()})
        return n

    def write_memory(self, addr: int, data):
        for i, byte in enumerate(data):
            self.memory[addr + i] = int(byte)

    def read_memory(self, addr: int, length: int):
        return np.array([self.memory.get(addr + i, 0) for i in range(length)],
                        dtype=np.uint8)


def _retired(order: int, pc: int, insn: int, writes: dict) -> RetiredInsn:
    """A RetiredInsn whose integer register writes are {register: value}."""
    return RetiredInsn(
        order=order,
        pc=pc,
        insn=insn,
        x_wb=sum(1 << reg for reg in writes),
        x_wdata=sum(val << (32 * reg) for reg, val in writes.items()),
    )


class LockstepCheckerTest(unittest.TestCase):

    def test_matching_instruction_passes(self):
        checker = LockstepChecker("t", FakeIss([(0x10, {2: 0x18010})]))
        checker.check(_retired(4, 0x10, AUIPC_SP, {2: 0x18010}))
        self.assertEqual(checker.mismatches, [])
        self.assertEqual((checker.checked, checker.reg_compares), (1, 1))

    def test_register_mismatch_is_reported(self):
        checker = LockstepChecker("t", FakeIss([(0x10, {2: 0x18010})]))
        checker.check(_retired(4, 0x10, AUIPC_SP, {2: 0xC008}))
        self.assertEqual(len(checker.mismatches), 1)
        self.assertIn("x2: RTL 0xc008 ISS 0x18010", checker.mismatches[0])

    def test_pc_mismatch_is_reported_without_stepping(self):
        iss = FakeIss([(0x14, {})])
        checker = LockstepChecker("t", iss)
        checker.check(_retired(4, 0x10, AUIPC_SP, {}))
        self.assertIn("pc: ISS is at 0x14", checker.mismatches[0])
        self.assertEqual(len(iss.program), 1)  # not stepped

    def test_counter_read_is_copied_not_compared(self):
        iss = FakeIss([(0x8, {10: 5})])  # the ISS's own minstret reads 5
        checker = LockstepChecker("t", iss)
        checker.check(_retired(2, 0x8, CSRR_A0_MINSTRET, {10: 0}))
        self.assertEqual(checker.mismatches, [])
        self.assertEqual((checker.skipped, checker.reg_compares), (1, 0))
        self.assertEqual(iss.regs["x10"], 0)  # back in sync with the RTL

    def test_stops_after_first_mismatch(self):
        iss = FakeIss([(0x10, {2: 1}), (0x14, {2: 2})])
        checker = LockstepChecker("t", iss)
        checker.check(_retired(4, 0x10, AUIPC_SP, {2: 99}))
        checker.check(_retired(5, 0x14, ADDI_SP, {2: 98}))
        self.assertEqual(len(checker.mismatches), 1)
        self.assertEqual(len(iss.program), 1)  # second one not stepped

    def test_mirror_skips_mmio(self):
        iss = FakeIss([])
        checker = LockstepChecker("t", iss)
        checker.mirror_write(0x10068, np.array([1, 2, 3], dtype=np.uint8))
        checker.mirror_write(0x30000, np.array([9], dtype=np.uint8))
        self.assertEqual(checker.mirrored, 1)
        self.assertEqual(iss.read_memory(0x10068, 3).tolist(), [1, 2, 3])
        self.assertNotIn(0x30000, iss.memory)

    def test_compare_memory_honours_ignored_ranges(self):
        iss = FakeIss([])
        iss.write_memory(0x100, [1, 2, 3, 4, 5, 6])
        expected = ExpectedDifferences(memory=((0x100, 0x104), ))
        checker = LockstepChecker("t", iss, expected)
        rtl = np.array([9, 9, 9, 9, 5, 7], dtype=np.uint8)
        # 0x100-0x103 differ but are ignored; offset 5 (6 vs 7) is reported.
        self.assertEqual(checker.compare_memory(0x100, rtl), [5])


if __name__ == "__main__":
    unittest.main()
