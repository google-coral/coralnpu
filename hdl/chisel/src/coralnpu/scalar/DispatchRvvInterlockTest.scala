package coralnpu

import chisel3._
import chisel3.simulator.scalatest.ChiselSim
import org.scalatest.freespec.AnyFreeSpec

class DispatchRvvInterlockSpec extends AnyFreeSpec with ChiselSim {
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
}
