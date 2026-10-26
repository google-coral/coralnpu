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
import org.scalatest.matchers.should.Matchers

class DecodeInstructionSpec extends AnyFreeSpec with Matchers with ChiselSim {
  val p = new Parameters()

  class DecodeTester(p: Parameters) extends Module {
    val io = IO(new Bundle {
      val inst  = Input(UInt(32.W))
      val undef = Output(Bool())
    })

    val d = DecodeInstruction(p, pipeline = 0, addr = 0.U, op = io.inst, csrFrm = 0.U)
    io.undef := d.undef
  }

  "DecodeInstruction" - {
    "should decode all table instructions as valid (undef == false)" in {
      simulate(new DecodeTester(p)) { dut =>
        val tbl = DecodeInstruction.table(p)
        for (DecodeInstruction.DecodeEntry(name, _, pat) <- tbl) {
          dut.io.inst.poke(pat.value.U(32.W))
          dut.clock.step()
          assert(
            dut.io.undef.peek().litValue == 0,
            s"Instruction $name (0x${pat.value.toString(16)}) decoded as undef"
          )
        }
      }
    }

    "should decode fence and fence.tso as valid (undef == false)" in {
      simulate(new DecodeTester(p)) { dut =>
        val validFences = Seq(
          0x0ff0000fL, // fence iorw, iorw
          0x0330000fL, // fence rw, rw
          0x8330000fL  // fence.tso
        )
        for (word <- validFences) {
          dut.io.inst.poke(word.U(32.W))
          dut.clock.step()
          assert(
            dut.io.undef.peek().litValue == 0,
            s"Fence instruction 0x${word.toHexString} decoded as undef"
          )
        }
      }
    }

    "should decode invalid opcodes as undefined (undef == true)" in {
      simulate(new DecodeTester(p)) { dut =>
        val invalidWords = Seq(
          0x00000000L,         // All zeros
          0xffffffffL,         // All ones
          0x00000000L | 0x7bL, // Invalid custom opcode
          0x00000000L | 0x0bL, // Invalid opcode
          0x00000000L | 0x2bL, // Invalid opcode
          0x1330000fL,         // Invalid fence fm=0001
          0x8110000fL          // Invalid fence.tso pred/succ!=0011
        )
        for (word <- invalidWords) {
          dut.io.inst.poke(word.U(32.W))
          dut.clock.step()
          assert(
            dut.io.undef.peek().litValue == 1,
            s"Word 0x${word.toHexString} should decode as undef"
          )
        }
      }
    }
  }
}

object DispatchTestUtils {
  import chisel3.simulator.PeekPokeAPI._

  def initialize(dut: DispatchV2, p: Parameters): Unit = {
    dut.io.halted.poke(false.B)
    dut.io.lsuActive.poke(false.B)
    dut.io.scoreboard.regd.poke(0.U)
    dut.io.scoreboard.comb.poke(0.U)
    dut.io.fscoreboard.foreach(_.poke(0.U))
    dut.io.float.foreach(_.ready.poke(true.B))
    dut.io.csrFrm.foreach(_.poke(0.U))
    dut.io.branchTaken.poke(false.B)
    dut.io.interlock.poke(false.B)
    dut.io.lsuQueueCapacity.poke(p.instructionLanes.U)
    dut.io.retirement_buffer_nSpace.poke(p.retirementBufferSize.U)
    dut.io.retirement_buffer_empty.poke(true.B)
    dut.io.retirement_buffer_trap_pending.poke(false.B)
    dut.io.single_step.poke(false.B)
    dut.io.debug_mode.poke(false.B)
    for (i <- 0 until p.instructionLanes) {
      dut.io.inst(i).valid.poke(false.B)
      dut.io.inst(i).bits.addr.poke((0x100 + 4 * i).U)
      dut.io.inst(i).bits.inst.poke(0x13.U)
      dut.io.inst(i).bits.brchFwd.poke(false.B)
      dut.io.jalrTarget(i).data.poke(0.U)
      dut.io.lsu(i).ready.poke(true.B)
      dut.io.mlu(i).ready.poke(true.B)
      dut.io.dvu(i).ready.poke(true.B)
    }
    dut.io.rvv.foreach(_.foreach(_.ready.poke(true.B)))
    dut.io.rvvIdle.foreach(_.poke(true.B))
    dut.io.rvvQueueCapacity.foreach(_.poke(p.instructionLanes.U))
    dut.io.rvvState.foreach { state =>
      state.valid.poke(true.B)
      state.bits.vl.poke(4.U)
      state.bits.vstart.poke(0.U)
      state.bits.ma.poke(false.B)
      state.bits.ta.poke(false.B)
      state.bits.xrm.poke(0.U)
      state.bits.sew.poke(0.U)
      state.bits.lmul.poke(0.U)
      state.bits.lmul_orig.poke(0.U)
      state.bits.vill.poke(false.B)
    }
  }
}

class DispatchLsuInterlockSpec extends AnyFreeSpec with ChiselSim {
  "LSU capacity gates only memory instructions" in {
    val p = new Parameters()
    simulate(new DispatchV2(p)) { dut =>
      DispatchTestUtils.initialize(dut, p)
      dut.io.inst(0).valid.poke(true.B)
      dut.io.inst(0).bits.inst.poke(0x93.U) // addi x1, x0, 0
      dut.io.lsuQueueCapacity.poke(0.U)
      dut.io.inst(0).ready.expect(true.B)

      // Scalar lane can follow final load admission, next load must wait.
      dut.io.inst(0).bits.inst.poke(0x52083.U) // lw x1, 0(x10)
      dut.io.inst(1).valid.poke(true.B)
      dut.io.inst(1).bits.inst.poke(0x113.U) // addi x2, x0, 0
      dut.io.inst(2).valid.poke(true.B)
      dut.io.inst(2).bits.inst.poke(0x52183.U) // lw x3, 0(x10)
      dut.io.inst(0).ready.expect(false.B)
      dut.io.inst(1).ready.expect(false.B)
      dut.io.lsuQueueCapacity.poke(1.U)
      dut.io.inst(0).ready.expect(true.B)
      dut.io.inst(1).ready.expect(true.B)
      dut.io.inst(2).ready.expect(false.B)
      dut.io.lsuQueueCapacity.poke(2.U)
      dut.io.inst(2).ready.expect(true.B)
    }
  }
}

class DispatchInterlockSpec extends AnyFreeSpec with ChiselSim {
  "RVV capacity gates only vector instructions" in {
    val p = new Parameters()
    p.enableRvv = true
    simulate(new DispatchV2(p)) { dut =>
      DispatchTestUtils.initialize(dut, p)
      dut.io.inst(0).valid.poke(true.B)
      dut.io.inst(0).bits.inst.poke(0x93.U) // addi x1, x0, 0
      dut.io.rvvQueueCapacity.get.poke(0.U)
      dut.io.inst(0).ready.expect(true.B)

      // Scalar lane can follow final vector admission, next vector must wait
      dut.io.inst(0).bits.inst.poke(0x02000157.U) // vadd.vv v2, v0, v0
      dut.io.inst(1).valid.poke(true.B)
      dut.io.inst(1).bits.inst.poke(0x93.U)
      dut.io.inst(2).valid.poke(true.B)
      dut.io.inst(2).bits.inst.poke(0x020001d7.U) // vadd.vv v3, v0, v0
      dut.io.inst(0).ready.expect(false.B)
      dut.io.inst(1).ready.expect(false.B)
      dut.io.rvvQueueCapacity.get.poke(1.U)
      dut.io.inst(0).ready.expect(true.B)
      dut.io.inst(1).ready.expect(true.B)
      dut.io.inst(2).ready.expect(false.B)
      dut.io.rvvQueueCapacity.get.poke(2.U)
      dut.io.inst(2).ready.expect(true.B)
    }
  }

  "Scalar scoreboard ignores x0 dependencies" in {
    val p = new Parameters()
    simulate(new DispatchV2(p)) { dut =>
      DispatchTestUtils.initialize(dut, p)
      dut.io.inst.foreach(_.valid.poke(true.B)) // addi x0, x0, 0 in every lane
      dut.io.inst.foreach(_.ready.expect(true.B))
      dut.io.rdMark.foreach(_.valid.expect(false.B))
      dut.io.inst.last.bits.inst.poke(0x93.U) // addi x1, x0, 0
      dut.io.inst.last.ready.expect(true.B)
      dut.io.rdMark.last.valid.expect(true.B)
    }
  }

  "Scalar scoreboard distinguishes register banks" in {
    val p = new Parameters()
    p.enableRvv = true
    p.enableFloat = true
    simulate(new DispatchV2(p)) { dut =>
      def instructions(words: BigInt*): Unit = {
        DispatchTestUtils.initialize(dut, p)
        for ((word, i) <- words.zipWithIndex) {
          dut.io.inst(i).valid.poke(true.B)
          dut.io.inst(i).bits.inst.poke(word.U)
        }
      }

      // Vector destination v1 must not create scalar RAW or WAW hazards on x1
      instructions(0x020000d7, 0x8113) // vadd.vv v1, v0, v0 / addi x2, x1, 0
      dut.io.inst(1).ready.expect(true.B)
      dut.io.inst(1).bits.inst.poke(0x93.U) // addi x1, x0, 0
      dut.io.inst(1).ready.expect(true.B)

      // Real scalar destinations still block younger reads and writes
      for (word <- Seq(0x93, 0x422020d7)) { // addi x1, x0, 0 / vmv.x.s x1, v2
        instructions(word, 0x8113)
        dut.io.inst(1).ready.expect(false.B)
        dut.io.inst(1).bits.inst.poke(0x93.U)
        dut.io.inst(1).ready.expect(false.B)
      }

      // Cover each scalar result path and non-scalar register banks with x1 busy
      val destinations = Seq(
        (0x00000093L, true),  // addi x1, x0, 0
        (0x000000b7L, true),  // lui x1, 0
        (0x00000097L, true),  // auipc x1, 0
        (0x000000efL, true),  // jal x1, 0
        (0x000000e7L, true),  // jalr x1, x0, 0
        (0xb00020f3L, true),  // csrrs x1, mcycle, x0
        (0x00052083L, true),  // lw x1, 0(x10)
        (0x02b500b3L, true),  // mul x1, x10, x11
        (0x02b540b3L, true),  // div x1, x10, x11
        (0xe00100d3L, true),  // fmv.x.w x1, f2
        (0x422020d7L, true),  // vmv.x.s x1, v2
        (0x000570d7L, true),  // vsetvli x1, x10, e8, m1
        (0x02050087L, false), // vle8.v v1, (x10)
        (0x020500a7L, false), // vse8.v v1, (x10)
        (0x003100d3L, false), // fadd.s f1, f2, f3
        (0x00052087L, false), // flw f1, 0(x10)
        (0x002520a7L, false)  // fsw f2, 1(x10), bits 11:7 are not a destination
      )
      for ((word, writesScalar) <- destinations) {
        instructions(BigInt(word))
        dut.io.inst(0).ready.expect(true.B)
        dut.io.rdMark(0).valid.expect(writesScalar.B)
        dut.io.scoreboard.comb.poke(2.U)
        dut.io.inst(0).ready.expect((!writesScalar).B)
      }
    }
  }
}
