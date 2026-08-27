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

class FabricArbiterSpec extends AnyFreeSpec with ChiselSim {
  var p = new Parameters

  "2-Port Arbiter" in {
    simulate(new FabricArbiter(p)) { dut =>
      def resetDut(): Unit = {
        dut.reset.poke(true.B)
        dut.clock.step()
        dut.reset.poke(false.B)
        dut.io.source(0).readDataAddr.valid.poke(false.B)
        dut.io.source(0).writeDataAddr.valid.poke(false.B)
        dut.io.source(1).readDataAddr.valid.poke(false.B)
        dut.io.source(1).writeDataAddr.valid.poke(false.B)
        dut.io.port.readData.valid.poke(false.B)
      }

      // CoralNPU Read - AXI Slave Any
      {
        dut.io.source(0).readDataAddr.valid.poke(true.B)
        dut.io.source(0).readDataAddr.bits.poke(0x8080.U)
        dut.io.source(0).writeDataAddr.valid.poke(false.B)

        dut.io.source(1).readDataAddr.bits.poke(0x4080.U)
        dut.io.source(1).writeDataAddr.bits.poke(0x4080.U)
        dut.io.source(1).writeDataBits.poke(0x5080.U)
        dut.io.source(1).writeDataStrb.poke(0x1.U)

        for (i <- 0 until 3) {
          if (i == 0) { // None
            dut.io.source(1).readDataAddr.valid.poke(false.B)
            dut.io.source(1).writeDataAddr.valid.poke(false.B)
          } else if (i == 1) { // Read
            dut.io.source(1).readDataAddr.valid.poke(true.B)
            dut.io.source(1).writeDataAddr.valid.poke(false.B)
          } else { // Write
            dut.io.source(1).readDataAddr.valid.poke(false.B)
            dut.io.source(1).writeDataAddr.valid.poke(true.B)
          }

          // Check read command is accurate
          dut.io.fabricBusy(1).expect(1)
          dut.io.port.readDataAddr.valid.expect(1)
          dut.io.port.writeDataAddr.valid.expect(0)
          dut.io.port.readDataAddr.bits.expect(0x8080)

          dut.clock.step()

          // Check response is propagated back to source 0
          dut.io.port.readData.valid.poke(true.B)
          dut.io.port.readData.bits.poke(300 + i)
          dut.io.source(0).readData.valid.expect(1)
          dut.io.source(0).readData.bits.expect(300 + i)
        }
      }

      resetDut()

      // CoralNPU Write - AXI Slave Any
      {
        dut.io.source(0).readDataAddr.valid.poke(false.B)
        dut.io.source(0).writeDataAddr.valid.poke(true.B)
        dut.io.source(0).writeDataAddr.bits.poke(0x80b0.U)
        dut.io.source(0).writeDataBits.poke(0x50b0.U)
        dut.io.source(0).writeDataStrb.poke(0xf.U)

        dut.io.source(1).readDataAddr.bits.poke(0x40b0.U)
        dut.io.source(1).writeDataAddr.bits.poke(0x40b0.U)
        dut.io.source(1).writeDataBits.poke(0x60b0.U)
        dut.io.source(1).writeDataStrb.poke(0x12.U)

        for (i <- 0 until 3) {
          if (i == 0) { // None
            dut.io.source(1).readDataAddr.valid.poke(false.B)
            dut.io.source(1).writeDataAddr.valid.poke(false.B)
          } else if (i == 1) { // Read
            dut.io.source(1).readDataAddr.valid.poke(true.B)
            dut.io.source(1).writeDataAddr.valid.poke(false.B)
          } else { // Write
            dut.io.source(1).readDataAddr.valid.poke(false.B)
            dut.io.source(1).writeDataAddr.valid.poke(true.B)
          }

          // Check write command is accurate
          dut.io.fabricBusy(1).expect(1)
          dut.io.port.readDataAddr.valid.expect(0)
          dut.io.port.writeDataAddr.valid.expect(1)
          dut.io.port.writeDataAddr.bits.expect(0x80b0)
          dut.io.port.writeDataBits.expect(0x50b0)
          dut.io.port.writeDataStrb.expect(0xf)
        }
      }

      resetDut()

      // CoralNPU None - AXI Slave Read
      {
        dut.io.source(0).readDataAddr.valid.poke(false.B)
        dut.io.source(0).writeDataAddr.valid.poke(false.B)

        dut.io.source(1).readDataAddr.valid.poke(true.B)
        dut.io.source(1).readDataAddr.bits.poke(0x40b0.U)
        dut.io.source(1).writeDataAddr.valid.poke(false.B)

        dut.io.fabricBusy(1).expect(0)
        dut.io.port.readDataAddr.valid.expect(1)
        dut.io.port.readDataAddr.bits.expect(0x40b0)
        dut.io.port.writeDataAddr.valid.expect(0)

        dut.clock.step()

        dut.io.port.readData.valid.poke(true.B)
        dut.io.port.readData.bits.poke(777)
        dut.io.source(1).readData.valid.expect(1)
        dut.io.source(1).readData.bits.expect(777)
      }

      resetDut()

      // CoralNPU None - AXI Slave Write
      {
        dut.io.source(0).readDataAddr.valid.poke(false.B)
        dut.io.source(0).writeDataAddr.valid.poke(false.B)

        dut.io.source(1).readDataAddr.valid.poke(false.B)
        dut.io.source(1).writeDataAddr.valid.poke(true.B)
        dut.io.source(1).writeDataAddr.bits.poke(0xb0b0.U)
        dut.io.source(1).writeDataBits.poke(0xa0b0.U)
        dut.io.source(1).writeDataStrb.poke(0xa.U)

        dut.io.fabricBusy(1).expect(0)
        dut.io.port.readDataAddr.valid.expect(0)
        dut.io.port.writeDataAddr.valid.expect(1)
        dut.io.port.writeDataAddr.bits.expect(0xb0b0)
      }

      resetDut()

      // Both None
      {
        dut.io.source(0).readDataAddr.valid.poke(false.B)
        dut.io.source(0).writeDataAddr.valid.poke(false.B)
        dut.io.source(1).readDataAddr.valid.poke(false.B)
        dut.io.source(1).writeDataAddr.valid.poke(false.B)

        dut.io.fabricBusy(1).expect(0)
        dut.io.port.readDataAddr.valid.expect(0)
        dut.io.port.writeDataAddr.valid.expect(0)
      }
    }
  }

  "3-Port Arbiter Priority" in {
    simulate(new FabricArbiter(p, n = 3)) { dut =>
      // Case 0: No inputs
      for (i <- 0 until 3) {
        dut.io.source(i).readDataAddr.valid.poke(false.B)
        dut.io.source(i).writeDataAddr.valid.poke(false.B)
      }
      dut.io.fabricBusy(0).expect(0)
      dut.io.fabricBusy(1).expect(0)
      dut.io.fabricBusy(2).expect(0)
      dut.io.port.readDataAddr.valid.expect(0)

      // Case 1: Port 2 only (lowest priority)
      dut.io.source(2).readDataAddr.valid.poke(true.B)
      dut.io.source(2).readDataAddr.bits.poke(0x2000.U)

      dut.io.fabricBusy(0).expect(0)
      dut.io.fabricBusy(1).expect(0)
      dut.io.fabricBusy(2).expect(0) // No one higher is busy
      dut.io.port.readDataAddr.valid.expect(1)
      dut.io.port.readDataAddr.bits.expect(0x2000.U)

      // Case 2: Port 1 and Port 2 (Port 1 wins)
      dut.io.source(1).readDataAddr.valid.poke(true.B)
      dut.io.source(1).readDataAddr.bits.poke(0x1000.U)

      dut.io.fabricBusy(0).expect(0)
      dut.io.fabricBusy(1).expect(0) // No one higher is busy
      dut.io.fabricBusy(2).expect(1) // Port 1 is busy
      dut.io.port.readDataAddr.valid.expect(1)
      dut.io.port.readDataAddr.bits.expect(0x1000.U)

      // Case 3: Port 0, 1, 2 (Port 0 wins)
      dut.io.source(0).readDataAddr.valid.poke(true.B)
      dut.io.source(0).readDataAddr.bits.poke(0x0000.U)

      dut.io.fabricBusy(0).expect(0) // Highest priority
      dut.io.fabricBusy(1).expect(1) // Port 0 is busy
      dut.io.fabricBusy(2).expect(1) // Port 0 is busy
      dut.io.port.readDataAddr.valid.expect(1)
      dut.io.port.readDataAddr.bits.expect(0x0000.U)

      // Broadcast response check
      dut.clock.step()
      dut.io.port.readData.valid.poke(true.B)
      dut.io.port.readData.bits.poke(0xdeadbeefL.U)

      dut.io.source(0).readData.valid.expect(1)
      dut.io.source(0).readData.bits.expect(0xdeadbeefL.U)
      dut.io.source(1).readData.valid.expect(1)
      dut.io.source(1).readData.bits.expect(0xdeadbeefL.U)
      dut.io.source(2).readData.valid.expect(1)
      dut.io.source(2).readData.bits.expect(0xdeadbeefL.U)
    }
  }
}
