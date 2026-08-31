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
    dut.io.rvv.get.vl.poke(0.U)
    dut.io.rvv.get.vtype.poke(0.U)
    dut.io.rvv.get.vxrm.poke(0.U)
    dut.io.rvv.get.vxsat.poke(false.B)
    dut.io.rvv.get.fflags.valid.poke(false.B)
    dut.io.rvv.get.fflags.bits.poke(0.U)
    dut.io.rvv.get.vstart.poke(0.U)
    dut.io.req.valid.poke(false.B)
    dut.io.req.bits.addr.poke(0.U)
    dut.io.req.bits.index.poke(0.U)
    dut.io.req.bits.rs1.poke(0.U)
    dut.io.req.bits.op.poke(CsrOp.CSRRW)
    dut.io.rs1.valid.poke(true.B)
    dut.io.rs1.data.poke(0.U)
  }

  "CSR write trace valid gating and data legalization" in {
    simulate(new Csr(p)) { dut =>
      initDut(dut)
      dut.clock.step()

      // 1. Writes to read-only CSRs (vl = 0xc20, vlenb = 0xc22) must suppress trace.valid
      dut.io.req.valid.poke(true.B)
      dut.io.req.bits.op.poke(CsrOp.CSRRW)
      dut.io.req.bits.index.poke(0xc20.U) // vl
      dut.io.req.bits.addr.poke(0.U)      // rd = x0
      dut.io.req.bits.rs1.poke(5.U)       // rs1 = x5 (t0)
      dut.io.rs1.data.poke(2.U)
      dut.clock.step()
      assert(!dut.io.trace.valid.peek().litToBoolean, "vl is read-only: trace.valid must be false")

      dut.io.req.bits.index.poke(0xc22.U) // vlenb
      dut.clock.step()
      assert(
        !dut.io.trace.valid.peek().litToBoolean,
        "vlenb is read-only: trace.valid must be false"
      )

      // 2. Writes to WARL CSRs in R/W space (mstatush = 0x310) must legalize trace data
      dut.io.req.bits.index.poke(0x310.U) // mstatush
      dut.io.rs1.data.poke(0xcafe.U)
      dut.clock.step()
      assert(dut.io.trace.valid.peek().litToBoolean, "mstatush is in R/W space (WARL)")
      assert(dut.io.trace.data.peek().litValue == 0, "mstatush trace data must legalize to 0")

      // 3. Writes to partially-writable CSRs (mstatus = 0x300) must legalize trace data
      dut.io.req.bits.index.poke(0x300.U) // mstatus
      dut.io.rs1.data.poke("hffffffff".U)
      dut.clock.step()
      assert(dut.io.trace.valid.peek().litToBoolean, "mstatus is in R/W space")
      assert(
        dut.io.trace.data.peek().litValue != BigInt("ffffffff", 16),
        "mstatus trace data must not output raw 0xffffffff"
      )

      // 4. Deassert request and verify readback of read-only registers is unchanged
      dut.io.req.valid.poke(false.B)
      dut.clock.step()

      // Read vl (0xc20) - must remain 0
      dut.io.req.valid.poke(true.B)
      dut.io.req.bits.op.poke(CsrOp.CSRRS)
      dut.io.req.bits.index.poke(0xc20.U)
      dut.io.req.bits.addr.poke(5.U)
      dut.io.req.bits.rs1.poke(0.U) // csrr
      dut.clock.step()
      assert(dut.io.rd.bits.data.peek().litValue == 0, "vl must remain 0")

      // Read vlenb (0xc22) - must remain 16 (0x10)
      dut.io.req.bits.index.poke(0xc22.U)
      dut.clock.step()
      assert(dut.io.rd.bits.data.peek().litValue == 16, "vlenb must remain 16")

      dut.io.req.valid.poke(false.B)
      dut.clock.step()
    }
  }
}
