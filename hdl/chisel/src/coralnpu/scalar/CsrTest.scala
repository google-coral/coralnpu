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

class CsrSpec extends AnyFreeSpec with ChiselSim {
  val p = new Parameters
  p.enableFloat = true
  p.enableRvv = true
  p.enableVerification = true

  def initDut(dut: Csr): Unit = {
    for (i <- 0 until p.csrInCount) {
      dut.io.csr.in.value(i).poke(0.U)
    }
    dut.io.irq.poke(false.B)
    dut.io.bru.in.mode.valid.poke(false.B)
    dut.io.bru.in.mode.bits.poke(CsrMode.Machine)
    dut.io.bru.in.mcause.valid.poke(false.B)
    dut.io.bru.in.mcause.bits.poke(0.U)
    dut.io.bru.in.mepc.valid.poke(false.B)
    dut.io.bru.in.mepc.bits.poke(0.U)
    dut.io.bru.in.mtval.valid.poke(false.B)
    dut.io.bru.in.mtval.bits.poke(0.U)
    dut.io.bru.in.halt.poke(false.B)
    dut.io.bru.in.fault.poke(false.B)
    dut.io.bru.in.wfi.poke(false.B)
    dut.io.counters.nRetired.poke(0.U)
    dut.io.dm.debug_req.poke(false.B)
    dut.io.dm.resume_req.poke(false.B)
    dut.io.dm.current_pc.poke(0.U)
    dut.io.dm.next_pc.poke(4.U)
    dut.io.timer_irq.poke(false.B)
    dut.io.software_irq.poke(false.B)
    dut.io.float.get.in.fflags.valid.poke(false.B)
    dut.io.float.get.in.fflags.bits.poke(0.U)
    dut.io.float_dirty.get.poke(false.B)
    dut.io.rvv.get.vl.poke(0.U)
    dut.io.rvv.get.vtype.poke(0.U)
    dut.io.rvv.get.vxrm.poke(0.U)
    dut.io.rvv.get.vxsat.poke(false.B)
    dut.io.rvv.get.fflags.valid.poke(false.B)
    dut.io.rvv.get.fflags.bits.poke(0.U)
    dut.io.rvv.get.vstart.poke(0.U)
    dut.io.rvv_dirty.get.poke(false.B)
    dut.io.req.valid.poke(false.B)
    dut.io.req.bits.addr.poke(0.U)
    dut.io.req.bits.index.poke(0.U)
    dut.io.req.bits.rs1.poke(0.U)
    dut.io.req.bits.op.poke(CsrOp.CSRRW)
    dut.io.rs1.valid.poke(true.B)
    dut.io.rs1.data.poke(0.U)
  }

  "CSR Operations" in {
    simulate(new Csr(p)) { dut =>
      initDut(dut)
      dut.clock.step()

      // 1. Trace valid gating and data legalization
      {
        // Writes to read-only CSRs (vl = 0xc20, vlenb = 0xc22) must suppress trace.valid
        dut.io.req.valid.poke(true.B)
        dut.io.req.bits.op.poke(CsrOp.CSRRW)
        dut.io.req.bits.index.poke(0xc20.U) // vl
        dut.io.req.bits.addr.poke(0.U)      // rd = x0
        dut.io.req.bits.rs1.poke(5.U)       // rs1 = x5 (t0)
        dut.io.rs1.data.poke(2.U)
        dut.clock.step()
        assert(
          !dut.io.trace.valid.peek().litToBoolean,
          "vl is read-only: trace.valid must be false"
        )

        dut.io.req.bits.index.poke(0xc22.U) // vlenb
        dut.clock.step()
        assert(
          !dut.io.trace.valid.peek().litToBoolean,
          "vlenb is read-only: trace.valid must be false"
        )

        // Writes to WARL CSRs in R/W space (mstatush = 0x310) must legalize trace data
        dut.io.req.bits.index.poke(0x310.U) // mstatush
        dut.io.rs1.data.poke(0xcafe.U)
        dut.clock.step()
        assert(dut.io.trace.valid.peek().litToBoolean, "mstatush is in R/W space (WARL)")
        assert(dut.io.trace.data.peek().litValue == 0, "mstatush trace data must legalize to 0")

        // Writes to partially-writable CSRs (mstatus = 0x300) must legalize trace data
        dut.io.req.bits.index.poke(0x300.U) // mstatus
        dut.io.rs1.data.poke("hffffffff".U)
        dut.clock.step()
        assert(dut.io.trace.valid.peek().litToBoolean, "mstatus is in R/W space")
        assert(
          dut.io.trace.data.peek().litValue != BigInt("ffffffff", 16),
          "mstatus trace data must not output raw 0xffffffff"
        )

        // Writes to mepc (0x341) must clear bits 1:0 (WARL, IALIGN=32)
        dut.io.req.bits.index.poke(0x341.U) // mepc
        dut.io.rs1.data.poke("hffffffff".U)
        dut.clock.step()
        assert(dut.io.trace.valid.peek().litToBoolean, "mepc is in R/W space")
        assert(
          dut.io.trace.data.peek().litValue == BigInt("fffffffc", 16),
          s"mepc trace data must mask bits 1:0 to zero, got 0x${dut.io.trace.data.peek().litValue.toString(16)}"
        )

        // Deassert request and verify readback of read-only registers is unchanged
        dut.io.req.valid.poke(false.B)
        dut.clock.step()

        // Read mepc (0x341) - bits 1:0 must read back zero
        dut.io.req.valid.poke(true.B)
        dut.io.req.bits.op.poke(CsrOp.CSRRS)
        dut.io.req.bits.index.poke(0x341.U)
        dut.io.req.bits.addr.poke(5.U)
        dut.io.req.bits.rs1.poke(0.U) // csrr
        dut.clock.step()
        assert(
          dut.io.rd.bits.data.peek().litValue == BigInt("fffffffc", 16),
          s"mepc readback must have bits 1:0 as zero, got 0x${dut.io.rd.bits.data.peek().litValue.toString(16)}"
        )

        // Read vl (0xc20) - must remain 0
        dut.io.req.bits.index.poke(0xc20.U)
        dut.clock.step()
        assert(dut.io.rd.bits.data.peek().litValue == 0, "vl must remain 0")

        // Read vlenb (0xc22) - must remain 16 (0x10)
        dut.io.req.bits.index.poke(0xc22.U)
        dut.clock.step()
        assert(dut.io.rd.bits.data.peek().litValue == 16, "vlenb must remain 16")

        dut.io.req.valid.poke(false.B)
        dut.clock.step()
      }

      // 2. mstatus dirty bits (FS, VS, SD) full state model and write precedence
      {
        dut.reset.poke(true.B)
        dut.clock.step()
        dut.reset.poke(false.B)
        initDut(dut)
        dut.clock.step()

        // Initial reset value: FS=1 (Initial), VS=1 (Initial), MPP=3, SD=0 -> 0x00003a00
        dut.io.req.valid.poke(true.B)
        dut.io.req.bits.op.poke(CsrOp.CSRRS)
        dut.io.req.bits.index.poke(0x300.U) // mstatus
        dut.io.req.bits.addr.poke(5.U)
        dut.io.req.bits.rs1.poke(0.U)
        dut.clock.step()
        assert(
          dut.io.rd.bits.data.peek().litValue == BigInt("3a00", 16),
          s"Initial mstatus must be 0x00003a00, got 0x${dut.io.rd.bits.data.peek().litValue.toString(16)}"
        )

        // Software write Clean (FS=2, VS=2) -> 0x5c00 (SD=0)
        dut.io.req.bits.op.poke(CsrOp.CSRRW)
        dut.io.req.bits.rs1.poke(5.U)
        dut.io.rs1.data.poke("h00005c00".U)
        dut.clock.step()
        assert(
          dut.io.trace.data.peek().litValue == BigInt("5c00", 16),
          s"mstatus trace data after write 0x5c00 must be 0x00005c00, got 0x${dut.io.trace.data.peek().litValue.toString(16)}"
        )

        // Verify readback of Clean mstatus
        dut.io.req.bits.op.poke(CsrOp.CSRRS)
        dut.io.req.bits.rs1.poke(0.U)
        dut.clock.step()
        assert(
          dut.io.rd.bits.data.peek().litValue == BigInt("5c00", 16),
          s"mstatus readback after Clean write must be 0x00005c00, got 0x${dut.io.rd.bits.data.peek().litValue.toString(16)}"
        )

        // Hardware float dirty trigger -> FS transitions Clean(2) -> Dirty(3), VS remains Clean(2), SD=1 -> 0x80007c00
        dut.io.req.valid.poke(false.B)
        dut.io.float_dirty.get.poke(true.B)
        dut.clock.step()
        dut.io.float_dirty.get.poke(false.B)

        dut.io.req.valid.poke(true.B)
        dut.io.req.bits.op.poke(CsrOp.CSRRS)
        dut.io.req.bits.rs1.poke(0.U)
        dut.clock.step()
        assert(
          dut.io.rd.bits.data.peek().litValue == BigInt("80007c00", 16),
          s"mstatus after float_dirty must be 0x80007c00, got 0x${dut.io.rd.bits.data.peek().litValue.toString(16)}"
        )

        // Clean again (FS=2, VS=2) -> 0x5c00 (SD=0)
        dut.io.req.bits.op.poke(CsrOp.CSRRW)
        dut.io.req.bits.rs1.poke(5.U)
        dut.io.rs1.data.poke("h00005c00".U)
        dut.clock.step()
        dut.io.req.bits.op.poke(CsrOp.CSRRS)
        dut.io.req.bits.rs1.poke(0.U)
        dut.clock.step()
        assert(
          dut.io.rd.bits.data.peek().litValue == BigInt("5c00", 16),
          s"mstatus after second Clean write must be 0x00005c00, got 0x${dut.io.rd.bits.data.peek().litValue.toString(16)}"
        )

        // Hardware vector dirty trigger -> VS transitions Clean(2) -> Dirty(3), FS remains Clean(2), SD=1 -> 0x80005e00
        dut.io.req.valid.poke(false.B)
        dut.io.rvv_dirty.get.poke(true.B)
        dut.clock.step()
        dut.io.rvv_dirty.get.poke(false.B)

        dut.io.req.valid.poke(true.B)
        dut.io.req.bits.op.poke(CsrOp.CSRRS)
        dut.io.req.bits.rs1.poke(0.U)
        dut.clock.step()
        assert(
          dut.io.rd.bits.data.peek().litValue == BigInt("80005e00", 16),
          s"mstatus after rvv_dirty must be 0x80005e00, got 0x${dut.io.rd.bits.data.peek().litValue.toString(16)}"
        )

        // Direct software write to Dirty (FS=3, VS=3) -> 0x80007e00
        dut.io.req.bits.op.poke(CsrOp.CSRRW)
        dut.io.req.bits.rs1.poke(5.U)
        dut.io.rs1.data.poke("h00007e00".U)
        dut.clock.step()
        assert(
          dut.io.trace.data.peek().litValue == BigInt("80007e00", 16),
          s"mstatus trace data after write 0x7e00 must be 0x80007e00, got 0x${dut.io.trace.data.peek().litValue.toString(16)}"
        )
        dut.io.req.bits.op.poke(CsrOp.CSRRS)
        dut.io.req.bits.rs1.poke(0.U)
        dut.clock.step()
        assert(
          dut.io.rd.bits.data.peek().litValue == BigInt("80007e00", 16),
          s"mstatus readback after Dirty write must be 0x80007e00, got 0x${dut.io.rd.bits.data.peek().litValue.toString(16)}"
        )

        // Write Off (FS=0, VS=0) -> legalizes to Dirty (FS=3, VS=3, SD=1) -> 0x80007e00
        dut.io.req.bits.op.poke(CsrOp.CSRRW)
        dut.io.req.bits.rs1.poke(5.U)
        dut.io.rs1.data.poke("h00001800".U)
        dut.clock.step()
        assert(
          dut.io.trace.data.peek().litValue == BigInt("80007e00", 16),
          s"mstatus trace data after Off write must legalize to 0x80007e00, got 0x${dut.io.trace.data.peek().litValue.toString(16)}"
        )
        dut.io.req.bits.op.poke(CsrOp.CSRRS)
        dut.io.req.bits.rs1.poke(0.U)
        dut.clock.step()
        assert(
          dut.io.rd.bits.data.peek().litValue == BigInt("80007e00", 16),
          s"mstatus after Off write must legalize to 0x80007e00, got 0x${dut.io.rd.bits.data.peek().litValue.toString(16)}"
        )

        // Write Initial (FS=1, VS=1) -> 0x3a00 (SD=0)
        dut.io.req.bits.op.poke(CsrOp.CSRRW)
        dut.io.req.bits.rs1.poke(5.U)
        dut.io.rs1.data.poke("h00003a00".U)
        dut.clock.step()
        dut.io.req.bits.op.poke(CsrOp.CSRRS)
        dut.io.req.bits.rs1.poke(0.U)
        dut.clock.step()
        assert(
          dut.io.rd.bits.data.peek().litValue == BigInt("3a00", 16),
          s"mstatus after Initial write must be 0x00003a00, got 0x${dut.io.rd.bits.data.peek().litValue.toString(16)}"
        )

        // Precedence / ORing test: Concurrent software write Clean (FS=2, VS=2) + hardware float_dirty
        // Dirty pulse must NOT be masked -> FS becomes 3, VS becomes 2, SD=1 -> 0x80007c00
        dut.io.req.bits.op.poke(CsrOp.CSRRW)
        dut.io.req.bits.rs1.poke(5.U)
        dut.io.rs1.data.poke("h00005c00".U)
        dut.clock.step()
        dut.io.float_dirty.get.poke(true.B)
        assert(
          dut.io.trace.data.peek().litValue == BigInt("80007c00", 16),
          s"mstatus trace data during concurrent Clean write + float_dirty must be 0x80007c00, got 0x${dut.io.trace.data.peek().litValue.toString(16)}"
        )
        dut.io.req.bits.op.poke(CsrOp.CSRRS)
        dut.io.req.bits.rs1.poke(0.U)
        dut.clock.step()
        dut.io.float_dirty.get.poke(false.B)
        assert(
          dut.io.rd.bits.data.peek().litValue == BigInt("80007c00", 16),
          s"mstatus readback after concurrent Clean write + float_dirty must be 0x80007c00, got 0x${dut.io.rd.bits.data.peek().litValue.toString(16)}"
        )

        // Precedence / ORing test: Concurrent software write Clean (FS=2, VS=2) + hardware rvv_dirty
        // Dirty pulse must NOT be masked -> FS becomes 2, VS becomes 3, SD=1 -> 0x80005e00
        dut.io.req.bits.op.poke(CsrOp.CSRRW)
        dut.io.req.bits.rs1.poke(5.U)
        dut.io.rs1.data.poke("h00005c00".U)
        dut.clock.step()
        dut.io.rvv_dirty.get.poke(true.B)
        assert(
          dut.io.trace.data.peek().litValue == BigInt("80005e00", 16),
          s"mstatus trace data during concurrent Clean write + rvv_dirty must be 0x80005e00, got 0x${dut.io.trace.data.peek().litValue.toString(16)}"
        )
        dut.io.req.bits.op.poke(CsrOp.CSRRS)
        dut.io.req.bits.rs1.poke(0.U)
        dut.clock.step()
        dut.io.rvv_dirty.get.poke(false.B)
        assert(
          dut.io.rd.bits.data.peek().litValue == BigInt("80005e00", 16),
          s"mstatus readback after concurrent Clean write + rvv_dirty must be 0x80005e00, got 0x${dut.io.rd.bits.data.peek().litValue.toString(16)}"
        )

        dut.io.req.valid.poke(false.B)
        dut.clock.step()
      }
    }
  }
}
