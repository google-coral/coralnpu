// Copyright 2026 Google LLC
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

class DvuSpec extends AnyFreeSpec with ChiselSim {
  val p = new Parameters

  "Initialization" in {
    simulate(new Dvu(p)) { dut =>
      dut.io.rd.valid.expect(0)
    }
  }

  private def testDvuOp(
    dut: Dvu,
    addr: UInt,
    op: DvuOp.Type,
    cases: Seq[(Long, Long, BigInt)]
  ) = {
    val mask = (BigInt(1) << p.xlen) - 1
    val good = cases.map { case (rs1, rs2, exp_rd) =>
      dut.io.req.valid.poke(true)
      dut.io.req.bits.addr.poke(addr)
      dut.io.req.bits.op.poke(op)
      dut.clock.step()
      dut.io.req.valid.poke(false)
      dut.io.rs1.valid.poke(true)
      dut.io.rs1.data.poke(rs1)
      dut.io.rs2.valid.poke(true)
      dut.io.rs2.data.poke(rs2)
      dut.io.rd.ready.poke(true)

      var cycles = 0
      while (dut.io.rd.valid.peek().litValue == 0 && cycles < 100) {
        dut.clock.step()
        cycles += 1
      }
      val res = (dut.io.rd.valid.peek().litValue == 1) &&
        ((dut.io.rd.bits.data.peek().litValue & mask) == (exp_rd & mask)) &&
        (dut.io.rd.bits.addr.peek().litValue == addr.litValue)
      dut.clock.step()
      res
    }
    if (!ProcessTestResults(good, printfn = info(_))) fail()
  }

  "DIV" in {
    val inputs = Seq(
      (20L, 5L, 4L),
      (19L, 5L, 3L),
      (-20L, 5L, -4L),
      (-19L, 5L, -3L),
      (20L, -5L, -4L),
      (-20L, -5L, 4L),
      (7L, 0L, -1L) // div by zero returns all 1s
    )
    val mask      = (BigInt(1) << p.xlen) - 1
    val testCases = inputs.map { case (rs1, rs2, exp) =>
      (rs1, rs2, BigInt(exp) & mask)
    }
    simulate(new Dvu(p))(testDvuOp(_, 14.U, DvuOp.DIV, testCases))
  }

  "DIVU" in {
    val inputs = Seq(
      (20L, 5L, 4L),
      (19L, 5L, 3L),
      (7L, 0L, 0xffffffffL)
    )
    val mask      = (BigInt(1) << p.xlen) - 1
    val testCases = inputs.map { case (rs1, rs2, exp) =>
      (rs1, rs2, BigInt(exp) & mask)
    }
    simulate(new Dvu(p))(testDvuOp(_, 14.U, DvuOp.DIVU, testCases))
  }

  "REM" in {
    val inputs = Seq(
      (20L, 5L, 0L),
      (19L, 5L, 4L),
      (-19L, 5L, -4L),
      (19L, -5L, 4L),
      (7L, 0L, 7L) // rem by zero returns dividend
    )
    val mask      = (BigInt(1) << p.xlen) - 1
    val testCases = inputs.map { case (rs1, rs2, exp) =>
      (rs1, rs2, BigInt(exp) & mask)
    }
    simulate(new Dvu(p))(testDvuOp(_, 14.U, DvuOp.REM, testCases))
  }

  "REMU" in {
    val inputs = Seq(
      (20L, 5L, 0L),
      (19L, 5L, 4L),
      (7L, 0L, 7L)
    )
    val mask      = (BigInt(1) << p.xlen) - 1
    val testCases = inputs.map { case (rs1, rs2, exp) =>
      (rs1, rs2, BigInt(exp) & mask)
    }
    simulate(new Dvu(p))(testDvuOp(_, 14.U, DvuOp.REMU, testCases))
  }
}

class Dvu64Spec extends AnyFreeSpec with ChiselSim {
  val p = new Parameters(xlen = 64)

  private def testDvuOp(
    dut: Dvu,
    addr: UInt,
    op: DvuOp.Type,
    cases: Seq[(Long, Long, BigInt)]
  ) = {
    val mask = (BigInt(1) << p.xlen) - 1
    val good = cases.map { case (rs1, rs2, exp_rd) =>
      dut.io.req.valid.poke(true)
      dut.io.req.bits.addr.poke(addr)
      dut.io.req.bits.op.poke(op)
      dut.clock.step()
      dut.io.req.valid.poke(false)
      dut.io.rs1.valid.poke(true)
      dut.io.rs1.data.poke(rs1)
      dut.io.rs2.valid.poke(true)
      dut.io.rs2.data.poke(rs2)
      dut.io.rd.ready.poke(true)

      var cycles = 0
      while (dut.io.rd.valid.peek().litValue == 0 && cycles < 100) {
        dut.clock.step()
        cycles += 1
      }
      val res = (dut.io.rd.valid.peek().litValue == 1) &&
        ((dut.io.rd.bits.data.peek().litValue & mask) == (exp_rd & mask)) &&
        (dut.io.rd.bits.addr.peek().litValue == addr.litValue)
      dut.clock.step()
      res
    }
    if (!ProcessTestResults(good, printfn = info(_))) fail()
  }

  "DIVW" in {
    val inputs = Seq(
      (20L, 5L, 4L),
      (-20L, 5L, -4L),
      (0xffffffff80000000L, -1L, 0xffffffff80000000L), // 32-bit signed overflow
      (7L, 0L, -1L)                                    // div by zero
    )
    val mask      = (BigInt(1) << p.xlen) - 1
    val testCases = inputs.map { case (rs1, rs2, exp) =>
      (rs1, rs2, BigInt(exp) & mask)
    }
    simulate(new Dvu(p))(testDvuOp(_, 15.U, DvuOp.DIVW, testCases))
  }

  "DIVUW" in {
    val inputs = Seq(
      (20L, 5L, 4L),
      (
        0x00000000fffffffeL,
        2L,
        0x000000007fffffffL
      ), // 32-bit unsigned division zero-extended operands
      (7L, 0L, -1L)
    )
    val mask      = (BigInt(1) << p.xlen) - 1
    val testCases = inputs.map { case (rs1, rs2, exp) =>
      (rs1, rs2, BigInt(exp) & mask)
    }
    simulate(new Dvu(p))(testDvuOp(_, 15.U, DvuOp.DIVUW, testCases))
  }

  "REMW" in {
    val inputs = Seq(
      (19L, 5L, 4L),
      (-19L, 5L, -4L),
      (7L, 0L, 7L)
    )
    val mask      = (BigInt(1) << p.xlen) - 1
    val testCases = inputs.map { case (rs1, rs2, exp) =>
      (rs1, rs2, BigInt(exp) & mask)
    }
    simulate(new Dvu(p))(testDvuOp(_, 15.U, DvuOp.REMW, testCases))
  }

  "REMUW" in {
    val inputs = Seq(
      (19L, 5L, 4L),
      (0x00000000fffffffeL, 3L, 2L),
      (7L, 0L, 7L)
    )
    val mask      = (BigInt(1) << p.xlen) - 1
    val testCases = inputs.map { case (rs1, rs2, exp) =>
      (rs1, rs2, BigInt(exp) & mask)
    }
    simulate(new Dvu(p))(testDvuOp(_, 15.U, DvuOp.REMUW, testCases))
  }

  "DIV" in {
    val inputs = Seq(
      (0x0000000100000000L, 2L, 0x0000000080000000L),
      (-0x0000000100000000L, 2L, -0x0000000080000000L),
      (0x8000000000000000L, -1L, 0x8000000000000000L) // 64-bit signed overflow
    )
    val mask      = (BigInt(1) << p.xlen) - 1
    val testCases = inputs.map { case (rs1, rs2, exp) =>
      (rs1, rs2, BigInt(exp) & mask)
    }
    simulate(new Dvu(p))(testDvuOp(_, 15.U, DvuOp.DIV, testCases))
  }

  "DIVU" in {
    val inputs = Seq(
      (0x0000000100000000L, 2L, 0x0000000080000000L),
      (0xfffffffffffffffeL, 2L, 0x7fffffffffffffffL)
    )
    val mask      = (BigInt(1) << p.xlen) - 1
    val testCases = inputs.map { case (rs1, rs2, exp) =>
      (rs1, rs2, BigInt(exp) & mask)
    }
    simulate(new Dvu(p))(testDvuOp(_, 15.U, DvuOp.DIVU, testCases))
  }

  "REM" in {
    val inputs = Seq(
      (0x0000000100000001L, 0x0000000100000000L, 1L),
      (-0x0000000100000001L, 0x0000000100000000L, -1L)
    )
    val mask      = (BigInt(1) << p.xlen) - 1
    val testCases = inputs.map { case (rs1, rs2, exp) =>
      (rs1, rs2, BigInt(exp) & mask)
    }
    simulate(new Dvu(p))(testDvuOp(_, 15.U, DvuOp.REM, testCases))
  }

  "REMU" in {
    val inputs = Seq(
      (0x0000000100000001L, 0x0000000100000000L, 1L),
      (0xfffffffffffffffeL, 3L, 2L)
    )
    val mask      = (BigInt(1) << p.xlen) - 1
    val testCases = inputs.map { case (rs1, rs2, exp) =>
      (rs1, rs2, BigInt(exp) & mask)
    }
    simulate(new Dvu(p))(testDvuOp(_, 15.U, DvuOp.REMU, testCases))
  }
}
