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

class RetirementBufferSpec extends AnyFreeSpec with ChiselSim {
  private def clearInputs(dut: RetirementBuffer, p: Parameters): Unit = {
    for (i <- 0 until p.instructionLanes) {
      dut.io.inst(i).valid.poke(false.B)
      dut.io.inst(i).ready.poke(true.B)
      dut.io.inst(i).bits.addr.poke(0.U)
      dut.io.inst(i).bits.inst.poke(0.U)
      dut.io.inst(i).bits.brchFwd.poke(false.B)
      dut.io.targets(i).poke(0.U)
      dut.io.jalrTargets(i).poke(0.U)
      dut.io.jump(i).poke(false.B)
      dut.io.branch(i).poke(false.B)
      dut.io.writeAddrScalar(i).valid.poke(false.B)
      dut.io.writeAddrScalar(i).addr.poke(0.U)
    }
    dut.io.storeComplete.valid.poke(false.B)
    dut.io.storeComplete.bits.poke(0.U)
    for (i <- 0 until p.instructionLanes + 2) {
      dut.io.writeDataScalar(i).valid.poke(false.B)
      dut.io.writeDataScalar(i).bits.addr.poke(0.U)
      dut.io.writeDataScalar(i).bits.data.poke(0.U)
    }
    dut.io.writeAddrFloat.foreach { port =>
      port.valid.poke(false.B)
      port.addr.poke(0.U)
    }
    dut.io.writeDataFloat.foreach { ports =>
      for (port <- ports) {
        port.valid.poke(false.B)
        port.bits.addr.poke(0.U)
        port.bits.data.poke(0.U)
      }
    }
    dut.io.fault.valid.poke(false.B)
    dut.io.fault.bits.mepc.poke(0.U)
    dut.io.fault.bits.mtval.poke(0.U)
    dut.io.fault.bits.mcause.poke(0.U)
    dut.io.fault.bits.decode.poke(false.B)
  }

  // Returns the retirement buffer to its reset state so that scenarios can share one simulation.
  private def resetDut(dut: RetirementBuffer, p: Parameters): Unit = {
    clearInputs(dut, p)
    dut.reset.poke(true.B)
    dut.clock.step()
    dut.reset.poke(false.B)
    dut.clock.step()
    dut.io.empty.expect(true.B)
  }

  // A scalar load with rd = x0 waits for the LSU writeback before retiring.
  private def testLoadZeroWaitsForLsu(dut: RetirementBuffer, p: Parameters): Unit = {
    val lsuPort       = p.instructionLanes + 1
    val noWriteRegIdx = (BigInt(1) << p.retirementBufferIdxWidth) - 1
    resetDut(dut, p)

    // Lane 0: lw x0, 0(x10) (0x00052003) at PC 0x100
    // Lane 1: addi x0, x0, 0 (0x00000013) at PC 0x104
    dut.io.inst(0).valid.poke(true.B)
    dut.io.inst(0).bits.addr.poke(0x100.U)
    dut.io.inst(0).bits.inst.poke(0x00052003L.U)
    dut.io.writeAddrScalar(0).valid.poke(true.B)
    dut.io.writeAddrScalar(0).addr.poke(0.U)

    dut.io.inst(1).valid.poke(true.B)
    dut.io.inst(1).bits.addr.poke(0x104.U)
    dut.io.inst(1).bits.inst.poke(0x00000013L.U)
    dut.io.writeAddrScalar(1).valid.poke(true.B)
    dut.io.writeAddrScalar(1).addr.poke(0.U)
    dut.clock.step()
    clearInputs(dut, p)

    // An ALU write to x0 on lane 1 must not complete the in-flight scalar load.
    dut.io.writeDataScalar(1).valid.poke(true.B)
    dut.io.writeDataScalar(1).bits.addr.poke(0.U)
    dut.io.empty.expect(false.B)
    dut.io.debug.get.inst(0).valid.expect(false.B)
    dut.clock.step()
    clearInputs(dut, p)

    dut.io.empty.expect(false.B)

    // LSU writeback on lsuOffset (addr = 0) completes lw x0 and retires both entries.
    dut.io.writeDataScalar(lsuPort).valid.poke(true.B)
    dut.io.writeDataScalar(lsuPort).bits.addr.poke(0.U)
    dut.io.writeDataScalar(lsuPort).bits.data.poke(0x12345678L.U)
    dut.io.debug.get.inst(0).valid.expect(true.B)
    dut.io.debug.get.inst(0).bits.pc.expect(0x100.U)
    dut.io.debug.get.inst(0).bits.idx.expect(noWriteRegIdx.U)
    dut.io.debug.get.inst(0).bits.trap.expect(false.B)
    dut.io.debug.get.inst(1).valid.expect(true.B)
    dut.io.debug.get.inst(1).bits.pc.expect(0x104.U)
    dut.clock.step()
    clearInputs(dut, p)

    dut.io.empty.expect(true.B)
    dut.io.nRetired.expect(2.U)
  }

  // Back-to-back scalar loads with rd = x0 complete one per LSU writeback.
  private def testBackToBackLoadZero(dut: RetirementBuffer, p: Parameters): Unit = {
    val lsuPort = p.instructionLanes + 1
    resetDut(dut, p)

    // Lane 0: lw x0, 0(x10) at PC 0x100; Lane 1: lh x0, 4(x10) at PC 0x104
    dut.io.inst(0).valid.poke(true.B)
    dut.io.inst(0).bits.addr.poke(0x100.U)
    dut.io.inst(0).bits.inst.poke(0x00052003L.U)
    dut.io.writeAddrScalar(0).valid.poke(true.B)
    dut.io.writeAddrScalar(0).addr.poke(0.U)

    dut.io.inst(1).valid.poke(true.B)
    dut.io.inst(1).bits.addr.poke(0x104.U)
    dut.io.inst(1).bits.inst.poke(0x00451003L.U)
    dut.io.writeAddrScalar(1).valid.poke(true.B)
    dut.io.writeAddrScalar(1).addr.poke(0.U)
    dut.clock.step()
    clearInputs(dut, p)

    // First LSU writeback retires only the older load at 0x100.
    dut.io.writeDataScalar(lsuPort).valid.poke(true.B)
    dut.io.writeDataScalar(lsuPort).bits.addr.poke(0.U)
    dut.io.debug.get.inst(0).valid.expect(true.B)
    dut.io.debug.get.inst(0).bits.pc.expect(0x100.U)
    dut.io.debug.get.inst(1).valid.expect(false.B)
    dut.clock.step()
    clearInputs(dut, p)

    dut.io.empty.expect(false.B)

    // Second LSU writeback retires the younger load at 0x104.
    dut.io.writeDataScalar(lsuPort).valid.poke(true.B)
    dut.io.writeDataScalar(lsuPort).bits.addr.poke(0.U)
    dut.io.debug.get.inst(0).valid.expect(true.B)
    dut.io.debug.get.inst(0).bits.pc.expect(0x104.U)
    dut.clock.step()
    clearInputs(dut, p)

    dut.io.empty.expect(true.B)
  }

  // A scalar load with rd = x0 asserts trapRetired when the LSU reports a load fault.
  private def testLoadZeroFault(dut: RetirementBuffer, p: Parameters): Unit = {
    resetDut(dut, p)

    // Lane 0: lw x0, 0(x10) at PC 0x200; Lane 1: addi x1, x0, 1 at PC 0x204
    dut.io.inst(0).valid.poke(true.B)
    dut.io.inst(0).bits.addr.poke(0x200.U)
    dut.io.inst(0).bits.inst.poke(0x00052003L.U)
    dut.io.writeAddrScalar(0).valid.poke(true.B)
    dut.io.writeAddrScalar(0).addr.poke(0.U)

    dut.io.inst(1).valid.poke(true.B)
    dut.io.inst(1).bits.addr.poke(0x204.U)
    dut.io.inst(1).bits.inst.poke(0x00100093L.U)
    dut.io.writeAddrScalar(1).valid.poke(true.B)
    dut.io.writeAddrScalar(1).addr.poke(1.U)
    dut.clock.step()
    clearInputs(dut, p)

    // Wait two cycles to model external bus read latency before fault response.
    dut.io.empty.expect(false.B)
    dut.clock.step()
    dut.io.empty.expect(false.B)
    dut.clock.step()
    dut.io.empty.expect(false.B)

    // Drive asynchronous LSU load access fault (mcause = 5) at mepc = 0x200.
    dut.io.fault.valid.poke(true.B)
    dut.io.fault.bits.mepc.poke(0x200.U)
    dut.io.fault.bits.mcause.poke(5.U)
    dut.io.fault.bits.mtval.poke(0xa0000000L.U)
    dut.io.fault.bits.decode.poke(false.B)
    dut.clock.step()
    clearInputs(dut, p)

    // Registered faultRetire marks 0x200 as trapped, pulsing trapRetired and flushing lane 1.
    dut.io.trapRetired.expect(true.B)
    dut.clock.step()

    dut.io.empty.expect(true.B)
  }

  "scalar loads with rd = x0" in {
    val p = new Parameters()
    p.enableVerification = true

    simulate(new RetirementBuffer(p, mini = false)) { dut =>
      testLoadZeroWaitsForLsu(dut, p)
      testBackToBackLoadZero(dut, p)
      testLoadZeroFault(dut, p)
    }
  }

  "scalar load with rd = x0 load fault (mini)" in {
    val p = new Parameters()

    simulate(new RetirementBuffer(p, mini = true)) { dut =>
      testLoadZeroFault(dut, p)
    }
  }
}
