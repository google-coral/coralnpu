package coralnpu

import chisel3._

object DispatchTestUtils {
  import chisel3.simulator.PeekPokeAPI._

  def initialize(dut: DispatchV2, p: Parameters): Unit = {
    dut.io.halted.poke(false.B)
    dut.io.interlock.poke(false.B)
    dut.io.scoreboard.regd.poke(0.U)
    dut.io.scoreboard.comb.poke(0.U)
    dut.io.lsuQueueCapacity.poke(p.instructionLanes.U)
    dut.io.retirement_buffer_nSpace.poke(p.retirementBufferSize.U)
    dut.io.retirement_buffer_trap_pending.poke(false.B)
    dut.io.single_step.poke(false.B)
    dut.io.inst.foreach(_.valid.poke(false.B))
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
