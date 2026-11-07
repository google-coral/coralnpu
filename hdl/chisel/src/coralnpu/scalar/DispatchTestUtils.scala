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
    dut.io.lsu.foreach(_.ready.poke(true.B))
  }
}
