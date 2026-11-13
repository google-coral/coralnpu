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

  // A decode fault at a loop PC must not mark the older, completed jump at the same PC as trapped.
  private def testDecodeFaultSkipsCompletedJump(dut: RetirementBuffer, p: Parameters): Unit = {
    resetDut(dut, p)

    // Iteration 0:
    //   0x24: div x6, x1, x2    (0x0220c333, long-latency blocker on rd = x6)
    //   0x28: xori a3, a3, 2    (0x0026c693, rd = x13)
    //   0x2c: jalr zero, 0(a3)  (0x00068067, target = 0x20)
    dut.io.inst(0).valid.poke(true.B)
    dut.io.inst(0).bits.addr.poke(0x24.U)
    dut.io.inst(0).bits.inst.poke(0x0220c333L.U)
    dut.io.writeAddrScalar(0).valid.poke(true.B)
    dut.io.writeAddrScalar(0).addr.poke(6.U)

    dut.io.inst(1).valid.poke(true.B)
    dut.io.inst(1).bits.addr.poke(0x28.U)
    dut.io.inst(1).bits.inst.poke(0x0026c693L.U)
    dut.io.writeAddrScalar(1).valid.poke(true.B)
    dut.io.writeAddrScalar(1).addr.poke(13.U)

    dut.io.inst(2).valid.poke(true.B)
    dut.io.inst(2).bits.addr.poke(0x2c.U)
    dut.io.inst(2).bits.inst.poke(0x00068067L.U)
    dut.io.jump(2).poke(true.B)
    dut.io.jalrTargets(2).poke(0x20.U)
    dut.clock.step()
    clearInputs(dut, p)

    // Iteration 0's xori completes; Iteration 1 dispatches 0x20 (addi), 0x30 (sw), 0x28 (xori),
    // confirming control-flow continuity for Iteration 0's jalr at 0x2c.
    dut.io.writeDataScalar(1).valid.poke(true.B)
    dut.io.writeDataScalar(1).bits.addr.poke(13.U)
    dut.io.writeDataScalar(1).bits.data.poke(0x20.U)

    dut.io.inst(0).valid.poke(true.B)
    dut.io.inst(0).bits.addr.poke(0x20.U)
    dut.io.inst(0).bits.inst.poke(0x00158593L.U)
    dut.io.writeAddrScalar(0).valid.poke(true.B)
    dut.io.writeAddrScalar(0).addr.poke(11.U)

    dut.io.inst(1).valid.poke(true.B)
    dut.io.inst(1).bits.addr.poke(0x30.U)
    dut.io.inst(1).bits.inst.poke(0x00b42823L.U)

    dut.io.inst(2).valid.poke(true.B)
    dut.io.inst(2).bits.addr.poke(0x28.U)
    dut.io.inst(2).bits.inst.poke(0x0026c693L.U)
    dut.io.writeAddrScalar(2).valid.poke(true.B)
    dut.io.writeAddrScalar(2).addr.poke(13.U)
    dut.clock.step()
    clearInputs(dut, p)

    // Iteration 1's addi and xori complete, while Iteration 1's jalr at 0x2c faults at decode
    // (misaligned target 0x22, ready = false -> noFire0Fault).
    dut.io.writeDataScalar(0).valid.poke(true.B)
    dut.io.writeDataScalar(0).bits.addr.poke(11.U)
    dut.io.writeDataScalar(0).bits.data.poke(2.U)
    dut.io.writeDataScalar(2).valid.poke(true.B)
    dut.io.writeDataScalar(2).bits.addr.poke(13.U)
    dut.io.writeDataScalar(2).bits.data.poke(0x22.U)

    dut.io.inst(0).valid.poke(true.B)
    dut.io.inst(0).ready.poke(false.B)
    dut.io.inst(0).bits.addr.poke(0x2c.U)
    dut.io.inst(0).bits.inst.poke(0x00068067L.U)
    dut.io.jump(0).poke(true.B)
    dut.io.jalrTargets(0).poke(0x22.U)

    dut.io.fault.valid.poke(true.B)
    dut.io.fault.bits.mepc.poke(0x2c.U)
    dut.io.fault.bits.mcause.poke(0.U)
    dut.io.fault.bits.mtval.poke(0x22.U)
    dut.io.fault.bits.decode.poke(true.B)
    dut.clock.step()
    clearInputs(dut, p)

    // Registered faultRetire fires this cycle.
    dut.clock.step()
    clearInputs(dut, p)

    // Iteration 0's div x6 completes; Iteration 0 (0x24, 0x28, 0x2c) and Iteration 1's 0x20
    // must retire WITHOUT trapRetired so Iteration 1's store (0x30) and faulting jalr remain.
    dut.io.writeDataScalar(p.instructionLanes).valid.poke(true.B)
    dut.io.writeDataScalar(p.instructionLanes).bits.addr.poke(6.U)
    dut.io.writeDataScalar(p.instructionLanes).bits.data.poke(99.U)
    dut.io.trapRetired.expect(false.B)
    dut.clock.step()
    clearInputs(dut, p)

    dut.io.empty.expect(false.B)

    // Now Iteration 1's store at 0x30 finishes; Iteration 1 retires and pulses trapRetired
    // on Iteration 1's faulting jalr at 0x2c.
    dut.io.storeComplete.valid.poke(true.B)
    dut.io.storeComplete.bits.poke(0x30.U)
    dut.clock.step()
    clearInputs(dut, p)

    dut.io.trapRetired.expect(true.B)
    dut.clock.step()

    dut.io.empty.expect(true.B)
  }

  // A non-decode fault at a loop PC skips the completed older entry and marks the pending one.
  private def testLoadFaultMarksPendingEntry(dut: RetirementBuffer, p: Parameters): Unit = {
    val lsuPort = p.instructionLanes + 1
    resetDut(dut, p)

    // Enqueue:
    //   0x0fc: div x6, x1, x2  (uncompleted blocker, rd = x6)
    //   0x100: lw x5, 0(x10)   (Iteration 0 load, rd = x5)
    //   0x100: lw x7, 0(x11)   (Iteration 1 load at same PC, rd = x7)
    dut.io.inst(0).valid.poke(true.B)
    dut.io.inst(0).bits.addr.poke(0x0fc.U)
    dut.io.inst(0).bits.inst.poke(0x0220c333L.U)
    dut.io.writeAddrScalar(0).valid.poke(true.B)
    dut.io.writeAddrScalar(0).addr.poke(6.U)

    dut.io.inst(1).valid.poke(true.B)
    dut.io.inst(1).bits.addr.poke(0x100.U)
    dut.io.inst(1).bits.inst.poke(0x00052283L.U)
    dut.io.writeAddrScalar(1).valid.poke(true.B)
    dut.io.writeAddrScalar(1).addr.poke(5.U)

    dut.io.inst(2).valid.poke(true.B)
    dut.io.inst(2).bits.addr.poke(0x100.U)
    dut.io.inst(2).bits.inst.poke(0x0005a383L.U)
    dut.io.writeAddrScalar(2).valid.poke(true.B)
    dut.io.writeAddrScalar(2).addr.poke(7.U)
    dut.clock.step()
    clearInputs(dut, p)

    // Iteration 0's lw x5 completes cleanly while div x6 is still running.
    dut.io.writeDataScalar(lsuPort).valid.poke(true.B)
    dut.io.writeDataScalar(lsuPort).bits.addr.poke(5.U)
    dut.io.writeDataScalar(lsuPort).bits.data.poke(0x1111L.U)
    dut.clock.step()
    clearInputs(dut, p)

    // Iteration 1's lw x7 at PC 0x100 raises an asynchronous load fault (decode = false).
    dut.io.fault.valid.poke(true.B)
    dut.io.fault.bits.mepc.poke(0x100.U)
    dut.io.fault.bits.mcause.poke(5.U)
    dut.io.fault.bits.mtval.poke(0xa0000000L.U)
    dut.io.fault.bits.decode.poke(false.B)
    dut.clock.step()
    clearInputs(dut, p)

    // faultRetire fires this cycle; complete div x6 on the next cycle and verify Iteration 0's
    // lw x5 retires with trap=false while Iteration 1's lw x7 retires with trap=true.
    dut.clock.step()
    dut.io.writeDataScalar(p.instructionLanes).valid.poke(true.B)
    dut.io.writeDataScalar(p.instructionLanes).bits.addr.poke(6.U)
    dut.io.writeDataScalar(p.instructionLanes).bits.data.poke(42.U)
    dut.io.debug.get.inst(0).valid.expect(true.B)
    dut.io.debug.get.inst(0).bits.trap.expect(false.B)
    dut.io.debug.get.inst(1).valid.expect(true.B)
    dut.io.debug.get.inst(1).bits.pc.expect(0x100.U)
    dut.io.debug.get.inst(1).bits.trap.expect(false.B)
    dut.io.debug.get.inst(2).valid.expect(true.B)
    dut.io.debug.get.inst(2).bits.pc.expect(0x100.U)
    dut.io.debug.get.inst(2).bits.trap.expect(true.B)
    dut.io.trapRetired.expect(true.B)
    dut.clock.step()
    clearInputs(dut, p)

    dut.io.empty.expect(true.B)
  }

  // A decode-faulting jump retires its trap without waiting for the next fetch packet.
  private def testDecodeFaultJumpRetires(dut: RetirementBuffer, p: Parameters): Unit = {
    resetDut(dut, p)

    // Misaligned jalr at slot 0 (noFire0Fault) followed by stalled fetch
    // (inst(0).valid = false).
    dut.io.inst(0).valid.poke(true.B)
    dut.io.inst(0).ready.poke(false.B)
    dut.io.inst(0).bits.addr.poke(0x300.U)
    dut.io.inst(0).bits.inst.poke(0x00068067L.U)
    dut.io.jump(0).poke(true.B)
    dut.io.jalrTargets(0).poke(0x302.U)

    dut.io.fault.valid.poke(true.B)
    dut.io.fault.bits.mepc.poke(0x300.U)
    dut.io.fault.bits.mcause.poke(0.U)
    dut.io.fault.bits.mtval.poke(0x302.U)
    dut.io.fault.bits.decode.poke(true.B)
    dut.clock.step()
    clearInputs(dut, p)

    dut.io.trapRetired.expect(true.B)
    dut.clock.step()

    dut.io.empty.expect(true.B)
  }

  // Stores at the same PC from two loop iterations complete one per storeComplete.
  private def testSamePcStoresCompleteInOrder(dut: RetirementBuffer, p: Parameters): Unit = {
    resetDut(dut, p)

    // Lanes 0 and 1: sw a1, 0(a0) (0x00b52023) at PC 0x20, from two loop iterations.
    for (lane <- 0 until 2) {
      dut.io.inst(lane).valid.poke(true.B)
      dut.io.inst(lane).bits.addr.poke(0x20.U)
      dut.io.inst(lane).bits.inst.poke(0x00b52023L.U)
    }
    dut.clock.step()
    clearInputs(dut, p)

    // The LSU finishes the older store.
    dut.io.storeComplete.valid.poke(true.B)
    dut.io.storeComplete.bits.poke(0x20.U)
    dut.clock.step()
    clearInputs(dut, p)

    // The registered storeComplete retires only the older store.
    dut.io.debug.foreach { debug =>
      debug.inst(0).valid.expect(true.B)
      debug.inst(0).bits.pc.expect(0x20.U)
      debug.inst(1).valid.expect(false.B)
    }
    dut.clock.step()
    dut.io.empty.expect(false.B)

    // The LSU finishes the younger store.
    dut.io.storeComplete.valid.poke(true.B)
    dut.io.storeComplete.bits.poke(0x20.U)
    dut.clock.step()
    clearInputs(dut, p)

    dut.io.debug.foreach { debug =>
      debug.inst(0).valid.expect(true.B)
      debug.inst(0).bits.pc.expect(0x20.U)
    }
    dut.clock.step()
    dut.io.empty.expect(true.B)
  }

  "retirement buffer scenarios" in {
    val p = new Parameters()
    p.enableVerification = true

    simulate(new RetirementBuffer(p, mini = false)) { dut =>
      testLoadZeroWaitsForLsu(dut, p)
      testBackToBackLoadZero(dut, p)
      testLoadZeroFault(dut, p)
      testDecodeFaultSkipsCompletedJump(dut, p)
      testLoadFaultMarksPendingEntry(dut, p)
      testDecodeFaultJumpRetires(dut, p)
      testSamePcStoresCompleteInOrder(dut, p)
    }
  }

  "retirement buffer scenarios (mini)" in {
    val p = new Parameters()

    simulate(new RetirementBuffer(p, mini = true)) { dut =>
      testLoadZeroFault(dut, p)
      testDecodeFaultSkipsCompletedJump(dut, p)
      testSamePcStoresCompleteInOrder(dut, p)
    }
  }
}
