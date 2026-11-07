package coralnpu

import chisel3._
import chisel3.simulator.scalatest.ChiselSim
import org.scalatest.freespec.AnyFreeSpec

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
