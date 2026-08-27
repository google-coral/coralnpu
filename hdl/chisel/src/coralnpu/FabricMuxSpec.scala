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

class FabricMuxSpec extends AnyFreeSpec with ChiselSim {
  var p = new Parameters

  val memoryRegions = Seq(
    new MemoryRegion(0x0000, 0x2000, MemoryRegionType.IMEM),       // ITCM
    new MemoryRegion(0x10000, 0x8000, MemoryRegionType.DMEM),      // DTCM
    new MemoryRegion(0x30000, 0x2000, MemoryRegionType.Peripheral) // CSR
  )

  "FabricMux" in {
    simulate(new FabricMux(p, memoryRegions)) { dut =>
      def resetDut(): Unit = {
        dut.reset.poke(true.B)
        dut.clock.step()
        dut.reset.poke(false.B)
        dut.io.source.readDataAddr.valid.poke(false.B)
        dut.io.source.writeDataAddr.valid.poke(false.B)
        for (j <- 0 until memoryRegions.length) {
          dut.io.periBusy(j).poke(false.B)
          dut.io.ports(j).readData.valid.poke(false.B)
        }
      }

      // Writes
      {
        val inputAddrs  = Seq(0x10, 0x10020, 0x30004)
        val outputAddrs = Seq(0x10, 0x20, 0x4)
        for (i <- 0 until memoryRegions.length) {
          dut.io.source.readDataAddr.valid.poke(false.B)
          dut.io.source.writeDataAddr.valid.poke(true.B)
          dut.io.source.writeDataAddr.bits.poke(inputAddrs(i).U)
          dut.io.source.writeDataBits.poke((123 + i).U)
          dut.io.source.writeDataStrb.poke((21 + i).U)

          for (j <- 0 until memoryRegions.length) {
            dut.io.ports(j).readDataAddr.valid.expect(0)
            if (i == j) {
              dut.io.ports(j).writeDataAddr.valid.expect(1)
              dut.io.ports(j).writeDataAddr.bits.expect(outputAddrs(i))
              dut.io.ports(j).writeDataBits.expect(123 + i)
              dut.io.ports(j).writeDataStrb.expect(21 + i)
            } else {
              dut.io.ports(j).writeDataAddr.valid.expect(0)
            }
          }

          // Check periBusy gets forwarded correctly
          dut.io.periBusy(i).poke(true.B)
          dut.io.fabricBusy.expect(1)
          dut.io.periBusy(i).poke(false.B)
          dut.io.fabricBusy.expect(0)
        }

        // Invalid write
        dut.io.source.writeDataAddr.bits.poke(0x90000.U)
        dut.io.source.writeDataBits.poke(1123.U)
        dut.io.source.writeDataStrb.poke(11.U)
        for (j <- 0 until memoryRegions.length) {
          dut.io.ports(j).readDataAddr.valid.expect(0)
          dut.io.ports(j).writeDataAddr.valid.expect(0)
        }
      }

      resetDut()

      // Reads
      {
        val inputAddrs  = Seq(0x10, 0x10020, 0x30004)
        val outputAddrs = Seq(0x10, 0x20, 0x4)
        for (i <- 0 until memoryRegions.length) {
          dut.io.source.readDataAddr.valid.poke(true.B)
          dut.io.source.readDataAddr.bits.poke(inputAddrs(i).U)
          dut.io.source.writeDataAddr.valid.poke(false.B)

          // Check command was forwarded correctly
          for (j <- 0 until memoryRegions.length) {
            dut.io.ports(j).writeDataAddr.valid.expect(0)
            if (i == j) {
              dut.io.ports(j).readDataAddr.valid.expect(1)
              dut.io.ports(j).readDataAddr.bits.expect(outputAddrs(i))
            } else {
              dut.io.ports(j).readDataAddr.valid.expect(0)
            }
          }

          // Check periBusy gets forwarded correctly
          dut.io.periBusy(i).poke(true.B)
          dut.io.fabricBusy.expect(1)
          dut.io.periBusy(i).poke(false.B)
          dut.io.fabricBusy.expect(0)

          dut.clock.step()

          // Check correct response is picked
          for (j <- 0 until memoryRegions.length) {
            dut.io.ports(j).readData.valid.poke(false.B)
            dut.io.ports(j).readData.bits.poke((800 + j).U)
          }
          dut.io.ports(i).readData.valid.poke(true.B)
          dut.io.source.readData.valid.expect(1)
          dut.io.source.readData.bits.expect(800 + i)
        }

        // Invalid read
        dut.io.source.readDataAddr.valid.poke(true.B)
        dut.io.source.readDataAddr.bits.poke(0x90000.U)
        dut.io.source.writeDataAddr.valid.poke(false.B)
        for (i <- 0 until memoryRegions.length) {
          dut.io.ports(i).readDataAddr.valid.expect(0)
        }
      }
    }
  }
}
