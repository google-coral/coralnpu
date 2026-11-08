package coralnpu

import chisel3._
import chisel3.simulator.scalatest.ChiselSim
import org.scalatest.freespec.AnyFreeSpec

class DispatchScoreboardSpec extends AnyFreeSpec with ChiselSim {
  "Scalar scoreboard ignores x0 dependencies" in {
    val p = new Parameters()
    simulate(new DispatchV2(p)) { dut =>
      DispatchTestUtils.initialize(dut, p)
      dut.io.inst.foreach { inst =>
        inst.valid.poke(true.B)
        inst.bits.inst.poke(0x13.U) // addi x0, x0, 0
      }
      dut.io.inst.foreach(_.ready.expect(true.B))
      dut.io.rdMark.foreach(_.valid.expect(false.B))
      dut.io.inst.last.bits.inst.poke(0x93.U) // addi x1, x0, 0
      dut.io.inst.last.ready.expect(true.B)
      dut.io.rdMark.last.valid.expect(true.B)
    }
  }
}
