// Copyright 2024 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

package coralnpu

import chisel3._
import chisel3.simulator.scalatest.ChiselSim
import org.scalatest.freespec.AnyFreeSpec

import common.ProcessTestResults

class AluSpec extends AnyFreeSpec with ChiselSim {
  val p = new Parameters

  "Initialization" in {
    simulate(new Alu(p)) { dut =>
      dut.io.rd.valid.expect(0)
    }
  }

  private def test_unary_op(
    dut: Alu,
    addr: UInt,
    op: AluOp.Type,
    // Long because Scala has no unsigned int.
    cases: Seq[(Long, BigInt)]
  ) = {
    val good = cases.map { case (rs1, exp_rd) =>
      dut.io.req.valid.poke(true)
      dut.io.req.bits.addr.poke(addr)
      dut.io.req.bits.op.poke(op)
      dut.io.rs1.valid.poke(true)
      dut.io.rs1.data.poke(rs1)
      dut.clock.step()
      val good1 = {
        (dut.io.rd.valid.peek().litValue == 1) && (dut.io.rd.bits.data.peek().litValue == exp_rd)
      }
      dut.io.req.valid.poke(true)
      dut.clock.step()
      val good2 = {
        (dut.io.rd.valid.peek().litValue == 1) && (dut.io.rd.bits.addr
          .peek()
          .litValue == addr.litValue)
      }
      good1 & good2
    }
    if (!ProcessTestResults(good, printfn = info(_))) fail()
  }

  "Sign Extend Byte" in {
    val inputs     = Seq(0x7fL, 0x80L)
    val test_cases = inputs.map { v =>
      val ext = if ((v & 0x80L) != 0) {
        (BigInt(v) | ~BigInt(0xff)) & ((BigInt(1) << p.xlen) - 1)
      } else {
        BigInt(v)
      }
      (v, ext)
    }
    simulate(new Alu(p))(test_unary_op(_, 13.U, AluOp.SEXTB, test_cases))
  }

  "Sign Extend Half Word" in {
    val inputs     = Seq(0x7fffL, 0x8000L)
    val test_cases = inputs.map { v =>
      val ext = if ((v & 0x8000L) != 0) {
        (BigInt(v) | ~BigInt(0xffff)) & ((BigInt(1) << p.xlen) - 1)
      } else {
        BigInt(v)
      }
      (v, ext)
    }
    simulate(new Alu(p))(test_unary_op(_, 13.U, AluOp.SEXTH, test_cases))
  }
  "Zero Extend Half Word" in {
    val test_cases = Seq(
      (0x00007fffL, BigInt(0x00007fffL)),
      (0x00008000L, BigInt(0x00008000L))
    )
    simulate(new Alu(p))(test_unary_op(_, 13.U, AluOp.ZEXTH, test_cases))
  }

  "CLZ" in {
    val base_cases = Seq(
      (0L, 32L),
      (1L, 31L),
      (3L, 30L),
      (0xffff8000L, 0L),
      (0x00800000L, 8L),
      (0x00007fffL, 17L),
      (0x7fffffffL, 1L),
      (0x0007ffffL, 13L),
      (0x80000000L, 0L),
      (0x121f5000L, 3L),
      (0x04000000L, 5L),
      (0x0000000eL, 28L),
      (0x20401341L, 2L)
    )
    val test_cases = base_cases.map { case (rs1, exp) =>
      (rs1, BigInt(exp + (p.xlen - 32)))
    }
    simulate(new Alu(p))(test_unary_op(_, 13.U, AluOp.CLZ, test_cases))
  }

  "CTZ" in {
    val base_cases = Seq(
      (0x00000000L, 32L),
      (0x00000001L, 0L),
      (0x00000003L, 0L),
      (0xffff8000L, 15L),
      (0x00800000L, 23L),
      (0x00007fffL, 0L),
      (0x7fffffffL, 0L),
      (0x0007ffffL, 0L),
      (0x80000000L, 31L),
      (0x121f5000L, 12L),
      (0xc0000000L, 30L),
      (0x0000000eL, 1L),
      (0x20401341L, 0L)
    )
    val test_cases = base_cases.map { case (rs1, exp) =>
      if (rs1 == 0L) (rs1, BigInt(p.xlen)) else (rs1, BigInt(exp))
    }
    simulate(new Alu(p))(test_unary_op(_, 13.U, AluOp.CTZ, test_cases))
  }

  "CPOP" in {
    val test_cases = Seq(
      (0x00000000L, BigInt(0L)),
      (0x00000001L, BigInt(1L)),
      (0x00000003L, BigInt(2L)),
      (0xffff8000L, BigInt(17L)),
      (0x00800000L, BigInt(1L)),
      (0x00007fffL, BigInt(15L)),
      (0x7fffffffL, BigInt(31L)),
      (0x0007ffffL, BigInt(19L)),
      (0x80000000L, BigInt(1L)),
      (0x121f5000L, BigInt(9L)),
      (0xc0000000L, BigInt(2L)),
      (0x0000000eL, BigInt(3L)),
      (0x20401341L, BigInt(7L))
    )
    simulate(new Alu(p))(test_unary_op(_, 13.U, AluOp.CPOP, test_cases))
  }

  "ORCB" in {
    val test_cases = Seq(
      (0x00000000L, BigInt(0x00000000L)),
      (0x00000001L, BigInt(0x000000ffL)),
      (0x00000003L, BigInt(0x000000ffL)),
      (0xffff8000L, BigInt(0xffffff00L)),
      (0x00800000L, BigInt(0x00ff0000L)),
      (0xffff8000L, BigInt(0xffffff00L)),
      (0x00007fffL, BigInt(0x0000ffffL)),
      (0x7fffffffL, BigInt(0xffffffffL)),
      (0x0007ffffL, BigInt(0x00ffffffL)),
      (0x80000000L, BigInt(0xff000000L)),
      (0x121f5000L, BigInt(0xffffff00L)),
      (0x00000000L, BigInt(0x00000000L)),
      (0x0000000eL, BigInt(0x000000ffL)),
      (0x20401341L, BigInt(0xffffffffL))
    )
    simulate(new Alu(p))(test_unary_op(_, 13.U, AluOp.ORCB, test_cases))
  }

  "REV8" in {
    val inputs = Seq(
      0x00000000L, 0x00000001L, 0x00000003L, 0xffff8000L, 0x00800000L, 0x00007fffL, 0x7fffffffL,
      0x0007ffffL, 0x80000000L, 0x121f5000L, 0x0000000eL, 0x20401341L
    )
    def scala_rev8(v: Long): BigInt = {
      val bytes = p.xlen / 8
      var res   = BigInt(0)
      for (i <- 0 until bytes) {
        val byte = (v >> (i * 8)) & 0xffL
        res |= (BigInt(byte) << ((bytes - 1 - i) * 8))
      }
      res
    }
    val test_cases = inputs.map(v => (v, scala_rev8(v)))
    simulate(new Alu(p))(test_unary_op(_, 13.U, AluOp.REV8, test_cases))
  }

  private def testBinaryOp(
    dut: Alu,
    addr: UInt,
    op: AluOp.Type,
    // Long because Scala has no unsigned int.
    cases: Seq[(Long, Long, BigInt)]
  ) = {
    dut.io.req.valid.poke(true)
    dut.io.req.bits.addr.poke(addr)
    dut.io.req.bits.op.poke(op)
    val good = cases.map { case (rs1, rs2, exp_rd) =>
      dut.io.rs1.valid.poke(true)
      dut.io.rs1.data.poke(rs1)
      dut.io.rs2.valid.poke(true)
      dut.io.rs2.data.poke(rs2)
      dut.clock.step()
      (dut.io.rd.valid.peek().litValue == 1) && (dut.io.rd.bits.data
        .peek()
        .litValue == exp_rd) && (dut.io.rd.bits.addr.peek().litValue == addr.litValue)
    }
    if (!ProcessTestResults(good, printfn = info(_))) fail()
  }

  "XNOR(Not XOR)" in {
    val inputs = Seq(
      (0x00000000L, 0x00000000L),
      (0x00000000L, 0x12345678L),
      (0x00000000L, -1L),
      (0x12345678L, 0x00000000L),
      (0x12345678L, 0x12345678L),
      (0x12345678L, -1L),
      (-1L, 0x00000000L),
      (-1L, 0x12345678L),
      (-1L, -1L)
    )
    val mask       = (BigInt(1) << p.xlen) - 1
    val test_cases = inputs.map { case (rs1, rs2) =>
      val exp = ~(rs1 ^ rs2)
      (rs1, rs2, BigInt(exp) & mask)
    }
    simulate(new Alu(p))(testBinaryOp(_, 13.U, AluOp.XNOR, test_cases))
  }

  "ORN(Not OR)" in {
    val inputs = Seq(
      (0x00000000L, 0x00000000L),
      (0x00000000L, 0x12345678L),
      (0x00000000L, -1L),
      (0x12345678L, 0x00000000L),
      (0x12345678L, 0x12345678L),
      (0x12345678L, -1L),
      (-1L, 0x00000000L),
      (-1L, 0x12345678L),
      (-1L, -1L)
    )
    val mask       = (BigInt(1) << p.xlen) - 1
    val test_cases = inputs.map { case (rs1, rs2) =>
      val exp = rs1 | ~rs2
      (rs1, rs2, BigInt(exp) & mask)
    }
    simulate(new Alu(p))(testBinaryOp(_, 13.U, AluOp.ORN, test_cases))
  }

  "ANDN(Not AND)" in {
    val inputs = Seq(
      (0x00000000L, 0x00000000L),
      (0x00000000L, 0x12345678L),
      (0x00000000L, -1L),
      (0x12345678L, 0x00000000L),
      (0x12345678L, 0x12345678L),
      (0x12345678L, -1L),
      (-1L, 0x00000000L),
      (-1L, 0x12345678L),
      (-1L, -1L)
    )
    val mask       = (BigInt(1) << p.xlen) - 1
    val test_cases = inputs.map { case (rs1, rs2) =>
      val exp = rs1 & ~rs2
      (rs1, rs2, BigInt(exp) & mask)
    }
    simulate(new Alu(p))(testBinaryOp(_, 13.U, AluOp.ANDN, test_cases))
  }

  "MAX" in {
    val inputs = Seq(
      (0x00000000L, 0x00000000L),
      (0x00000001L, 0x00000001L),
      (0x00000003L, 0x00000007L),
      (0x00000000L, 0xffff8000L),
      (0xffff8000L, 0x00000000L),
      (0x00000000L, 0x00007fffL),
      (0x00007fffL, 0x00000000L),
      (0x7fffffffL, 0x00000000L),
      (0x00000000L, 0x7fffffffL),
      (0x7fffffffL, 0x80000000L),
      (0xffffffffL, 0x00000001L),
      (0x00000001L, 0xffffffffL)
    )
    def toSignedXlen(v: Long): Long = {
      if (p.xlen == 32) v.toInt.toLong else v
    }
    val test_cases = inputs.map { case (rs1, rs2) =>
      val s1   = toSignedXlen(rs1)
      val s2   = toSignedXlen(rs2)
      val exp  = math.max(s1, s2)
      val mask = (BigInt(1) << p.xlen) - 1
      (rs1, rs2, BigInt(exp) & mask)
    }
    simulate(new Alu(p))(testBinaryOp(_, 13.U, AluOp.MAX, test_cases))
  }

  "MAXU" in {
    val inputs = Seq(
      (0x00000000L, 0x00000000L),
      (0x00000001L, 0x00000001L),
      (0x00000003L, 0x00000007L),
      (0x00000000L, 0xffff8000L),
      (0xffff8000L, 0x00000000L),
      (0x00000000L, 0x00007fffL),
      (0x00007fffL, 0x00000000L),
      (0x7fffffffL, 0x00000000L),
      (0x00000000L, 0x7fffffffL),
      (0x7fffffffL, 0x80000000L),
      (0xffffffffL, 0x00000001L),
      (0x00000001L, 0xffffffffL)
    )
    val mask       = (BigInt(1) << p.xlen) - 1
    val test_cases = inputs.map { case (rs1, rs2) =>
      val u1  = BigInt(rs1) & mask
      val u2  = BigInt(rs2) & mask
      val exp = u1.max(u2)
      (rs1, rs2, exp)
    }
    simulate(new Alu(p))(testBinaryOp(_, 13.U, AluOp.MAXU, test_cases))
  }

  "MIN" in {
    val inputs = Seq(
      (0x00000000L, 0x00000000L),
      (0x00000001L, 0x00000001L),
      (0x00000003L, 0x00000007L),
      (0x00000000L, 0xffff8000L),
      (0xffff8000L, 0x00000000L),
      (0x00000000L, 0x00007fffL),
      (0x00007fffL, 0x00000000L),
      (0x7fffffffL, 0x00000000L),
      (0x00000000L, 0x7fffffffL),
      (0x7fffffffL, 0x80000000L),
      (0xffffffffL, 0x00000001L),
      (0x00000001L, 0xffffffffL)
    )
    def toSignedXlen(v: Long): Long = {
      if (p.xlen == 32) v.toInt.toLong else v
    }
    val test_cases = inputs.map { case (rs1, rs2) =>
      val s1   = toSignedXlen(rs1)
      val s2   = toSignedXlen(rs2)
      val exp  = math.min(s1, s2)
      val mask = (BigInt(1) << p.xlen) - 1
      (rs1, rs2, BigInt(exp) & mask)
    }
    simulate(new Alu(p))(testBinaryOp(_, 13.U, AluOp.MIN, test_cases))
  }

  "MINU" in {
    val inputs = Seq(
      (0x00000000L, 0x00000000L),
      (0x00000001L, 0x00000001L),
      (0x00000003L, 0x00000007L),
      (0x00000000L, 0xffff8000L),
      (0xffff8000L, 0x00000000L),
      (0x00000000L, 0x00007fffL),
      (0x00007fffL, 0x00000000L),
      (0x7fffffffL, 0x00000000L),
      (0x00000000L, 0x7fffffffL),
      (0x7fffffffL, 0x80000000L),
      (0xffffffffL, 0x00000001L),
      (0x00000001L, 0xffffffffL)
    )
    val mask       = (BigInt(1) << p.xlen) - 1
    val test_cases = inputs.map { case (rs1, rs2) =>
      val u1  = BigInt(rs1) & mask
      val u2  = BigInt(rs2) & mask
      val exp = u1.min(u2)
      (rs1, rs2, exp)
    }
    simulate(new Alu(p))(testBinaryOp(_, 13.U, AluOp.MINU, test_cases))
  }

  "ROL" in {
    val inputs = Seq(
      (0x00000001L, 0x00000000L),
      (0x00000001L, 0x00000001L),
      (0x00000001L, 0x00000007L),
      (0x00000001L, 0x0000000eL),
      (0x00000001L, 0x0000001fL),
      (0xffffffffL, 0x00000000L),
      (0xffffffffL, 0x00000001L),
      (0xffffffffL, 0x00000007L),
      (0xffffffffL, 0x0000000eL),
      (0xffffffffL, 0x0000001fL),
      (0x21212121L, 0x00000000L),
      (0x21212121L, 0x00000001L),
      (0x21212121L, 0x00000007L),
      (0x21212121L, 0x0000000eL),
      (0x21212121L, 0x0000001fL)
    )
    val test_cases = inputs.map { case (rs1, rs2) =>
      val mask  = (BigInt(1) << p.xlen) - 1
      val shamt = (rs2 & (p.xlen - 1)).toInt
      val bg_v  = BigInt(rs1) & mask
      val exp   = ((bg_v << shamt) | (bg_v >> (p.xlen - shamt))) & mask
      (rs1, rs2, exp)
    }
    simulate(new Alu(p))(testBinaryOp(_, 13.U, AluOp.ROL, test_cases))
  }

  "ROR" in {
    val inputs = Seq(
      (0x00000001L, 0x00000000L),
      (0x00000001L, 0x00000001L),
      (0x00000001L, 0x00000007L),
      (0x00000001L, 0x0000000eL),
      (0x00000001L, 0x0000001fL),
      (0xffffffffL, 0x00000000L),
      (0xffffffffL, 0x00000001L),
      (0xffffffffL, 0x00000007L),
      (0xffffffffL, 0x0000000eL),
      (0xffffffffL, 0x0000001fL),
      (0x21212121L, 0x00000000L),
      (0x21212121L, 0x00000001L),
      (0x21212121L, 0x00000007L),
      (0x21212121L, 0x0000000eL),
      (0x21212121L, 0x0000001fL)
    )
    val test_cases = inputs.map { case (rs1, rs2) =>
      val mask  = (BigInt(1) << p.xlen) - 1
      val shamt = (rs2 & (p.xlen - 1)).toInt
      val bg_v  = BigInt(rs1) & mask
      val exp   = ((bg_v >> shamt) | (bg_v << (p.xlen - shamt))) & mask
      (rs1, rs2, exp)
    }
    simulate(new Alu(p))(testBinaryOp(_, 13.U, AluOp.ROR, test_cases))
  }
}

class Alu64Spec extends AnyFreeSpec with ChiselSim {
  val p = new Parameters(xlen = 64)

  private def testBinaryOp(
    dut: Alu,
    addr: UInt,
    op: AluOp.Type,
    cases: Seq[(Long, Long, Long)]
  ) = {
    dut.io.req.valid.poke(true)
    dut.io.req.bits.addr.poke(addr)
    dut.io.req.bits.op.poke(op)
    val good = cases.map { case (rs1, rs2, exp_rd) =>
      dut.io.rs1.valid.poke(true)
      dut.io.rs1.data.poke(rs1)
      dut.io.rs2.valid.poke(true)
      dut.io.rs2.data.poke(rs2)
      dut.clock.step()
      val mask = (BigInt(1) << p.xlen) - 1
      (dut.io.rd.valid.peek().litValue == 1) &&
      ((dut.io.rd.bits.data.peek().litValue & mask) == (BigInt(exp_rd) & mask)) &&
      (dut.io.rd.bits.addr.peek().litValue == addr.litValue)
    }
    if (!ProcessTestResults(good, printfn = info(_))) fail()
  }

  private def test_unary_op(
    dut: Alu,
    addr: UInt,
    op: AluOp.Type,
    cases: Seq[(Long, BigInt)]
  ) = {
    val mask = (BigInt(1) << p.xlen) - 1
    val good = cases.map { case (rs1, exp_rd) =>
      dut.io.req.valid.poke(true)
      dut.io.req.bits.addr.poke(addr)
      dut.io.req.bits.op.poke(op)
      dut.io.rs1.valid.poke(true)
      dut.io.rs1.data.poke(rs1)
      dut.clock.step()
      val good1 = {
        (dut.io.rd.valid.peek().litValue == 1) &&
        ((dut.io.rd.bits.data.peek().litValue & mask) == (exp_rd & mask))
      }
      dut.io.req.valid.poke(true)
      dut.clock.step()
      val good2 = {
        (dut.io.rd.valid.peek().litValue == 1) && (dut.io.rd.bits.addr
          .peek()
          .litValue == addr.litValue)
      }
      good1 & good2
    }
    if (!ProcessTestResults(good, printfn = info(_))) fail()
  }

  "ADDW" in {
    val inputs = Seq(
      (
        0x000000007fffffffL,
        0x0000000000000001L,
        0xffffffff80000000L
      ), // 32-bit overflow sign extended to 64
      (0x0000000000000005L, 0x0000000000000003L, 0x0000000000000008L),
      (0xffffffff80000000L, 0xffffffffffffffffL, 0x000000007fffffffL)
    )
    simulate(new Alu(p))(testBinaryOp(_, 13.U, AluOp.ADDW, inputs))
  }

  "SUBW" in {
    val inputs = Seq(
      (
        0x0000000080000000L,
        0x0000000000000001L,
        0x000000007fffffffL
      ), // 32-bit subtraction sign extended
      (0x0000000000000005L, 0x0000000000000003L, 0x0000000000000002L)
    )
    simulate(new Alu(p))(testBinaryOp(_, 13.U, AluOp.SUBW, inputs))
  }

  "SLLW" in {
    val inputs = Seq(
      (0x0000000000000001L, 31L, 0xffffffff80000000L),
      (0x0000000000000003L, 2L, 0x000000000000000cL)
    )
    simulate(new Alu(p))(testBinaryOp(_, 13.U, AluOp.SLLW, inputs))
  }

  "SRLW" in {
    val inputs = Seq(
      (0xffffffff80000000L, 1L, 0x0000000040000000L),
      (0x0000000000000010L, 2L, 0x0000000000000004L)
    )
    simulate(new Alu(p))(testBinaryOp(_, 13.U, AluOp.SRLW, inputs))
  }

  "SRAW" in {
    val inputs = Seq(
      (0xffffffff80000000L, 1L, 0xffffffffc0000000L),
      (0x0000000000000010L, 2L, 0x0000000000000004L)
    )
    simulate(new Alu(p))(testBinaryOp(_, 13.U, AluOp.SRAW, inputs))
  }

  "CLZW" in {
    val base_cases = Seq(
      (0L, 32L),
      (1L, 31L),
      (3L, 30L),
      (0x80000000L, 0L)
    )
    val test_cases = base_cases.map { case (rs1, exp) => (rs1, BigInt(exp)) }
    simulate(new Alu(p))(test_unary_op(_, 13.U, AluOp.CLZW, test_cases))
  }

  "CTZW" in {
    val base_cases = Seq(
      (0L, 32L),
      (1L, 0L),
      (8L, 3L),
      (0x80000000L, 31L)
    )
    val test_cases = base_cases.map { case (rs1, exp) => (rs1, BigInt(exp)) }
    simulate(new Alu(p))(test_unary_op(_, 13.U, AluOp.CTZW, test_cases))
  }

  "CPOPW" in {
    val base_cases = Seq(
      (0L, 0L),
      (1L, 1L),
      (3L, 2L),
      (0xffffffff80000000L, 1L),
      (0x00000000ffffffffL, 32L)
    )
    val test_cases = base_cases.map { case (rs1, exp) => (rs1, BigInt(exp)) }
    simulate(new Alu(p))(test_unary_op(_, 13.U, AluOp.CPOPW, test_cases))
  }

  "ROLW" in {
    val inputs = Seq(
      (0x0000000080000000L, 1L, 0x0000000000000001L),
      (0x0000000040000000L, 1L, 0xffffffff80000000L)
    )
    simulate(new Alu(p))(testBinaryOp(_, 13.U, AluOp.ROLW, inputs))
  }

  "RORW" in {
    val inputs = Seq(
      (0x0000000000000001L, 1L, 0xffffffff80000000L),
      (0xffffffff80000000L, 1L, 0x0000000040000000L)
    )
    simulate(new Alu(p))(testBinaryOp(_, 13.U, AluOp.RORW, inputs))
  }
}
