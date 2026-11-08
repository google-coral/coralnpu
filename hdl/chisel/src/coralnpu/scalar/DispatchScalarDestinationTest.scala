package coralnpu

import chisel3._
import chisel3.simulator.scalatest.ChiselSim
import org.scalatest.freespec.AnyFreeSpec

class DispatchScalarDestinationSpec extends AnyFreeSpec with ChiselSim {
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
