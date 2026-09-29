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
      dut.io.inst.last.bits.inst.poke(0x93.U) // addi x1, x0, 0
      dut.io.inst.last.ready.expect(true.B)

      // Even if bit 0 of scoreboard inputs were driven high, x0 reads do not stall.
      dut.io.scoreboard.regd.poke(1.U)
      dut.io.scoreboard.comb.poke(1.U)
      dut.io.inst(0).bits.inst.poke(0x00002103L.U) // lw x2, 0(x0)
      dut.io.inst(0).ready.expect(true.B)
      dut.io.inst.last.ready.expect(true.B)
    }
  }

  "Vector, matrix, and float non-scalar-rd ops do not cause false scalar stalls" in {
    val p = new Parameters()
    p.enableRvv = true
    p.enableVme = true
    p.enableFloat = true
    simulate(new DispatchV2(p)) { dut =>
      DispatchTestUtils.initialize(dut, p)
      dut.io.mlu.foreach(_.ready.poke(true.B))
      dut.io.dvu.foreach(_.ready.poke(true.B))
      dut.io.inst(0).valid.poke(true.B)
      dut.io.inst(1).valid.poke(true.B)

      // Tile op vtzero mt4 (inst[11:7] = 8) followed by scalar WAW/RAW on x8 dual-issues.
      dut.io.inst(0).bits.inst.poke(0x43e06457L.U) // vtzero mt4 (encoded rd = 8)
      dut.io.inst(1).bits.inst.poke(0x02a00413L.U) // addi x8, x0, 42 (WAW on x8)
      dut.io.inst(0).ready.expect(true.B)
      dut.io.inst(1).ready.expect(true.B)

      dut.io.inst(1).bits.inst.poke(0x00140293L.U) // addi x5, x8, 1 (RAW on x8)
      dut.io.inst(0).ready.expect(true.B)
      dut.io.inst(1).ready.expect(true.B)

      // Vector op vadd.vv v8, v0, v0 (inst[11:7] = 8) followed by scalar WAW/RAW on x8 dual-issues.
      dut.io.inst(0).bits.inst.poke(0x02000457L.U) // vadd.vv v8, v0, v0
      dut.io.inst(1).bits.inst.poke(0x02a00413L.U) // addi x8, x0, 42
      dut.io.inst(0).ready.expect(true.B)
      dut.io.inst(1).ready.expect(true.B)

      // Vector op writing scalar rd (vmv.x.s x8, v2) MUST still stall scalar WAW/RAW on x8.
      dut.io.inst(0).bits.inst.poke(0x42202457L.U) // vmv.x.s x8, v2
      dut.io.inst(1).bits.inst.poke(0x02a00413L.U) // addi x8, x0, 42
      dut.io.inst(0).ready.expect(true.B)
      dut.io.inst(1).ready.expect(false.B)

      dut.io.inst(1).bits.inst.poke(0x00140293L.U) // addi x5, x8, 1
      dut.io.inst(0).ready.expect(true.B)
      dut.io.inst(1).ready.expect(false.B)

      // Float op writing frd (fadd.s f8, f1, f2) does not WAW-stall when scalar x8 is in-flight,
      // whereas fmv.x.w x8, f1 (scalar_rd = true) does stall.
      dut.io.inst(1).valid.poke(false.B)
      dut.io.scoreboard.comb.poke((1 << 8).U)
      dut.io.inst(0).bits.inst.poke(0x00208453L.U) // fadd.s f8, f1, f2
      dut.io.inst(0).ready.expect(true.B)

      dut.io.inst(0).bits.inst.poke(0xe0008453L.U) // fmv.x.w x8, f1
      dut.io.inst(0).ready.expect(false.B)
    }
  }
}
