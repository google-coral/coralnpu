// Copyright 2024 Google LLC
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
import chisel3.util._

class Sram_Nx128(tcmEntries: Int) extends Module {
  override val desiredName = "SRAM_" + tcmEntries + "x128" + "_wrapper"
  val addrBits = log2Ceil(tcmEntries)
  val io = IO(new Bundle {
    val addr = Input(UInt(addrBits.W))
    val enable = Input(Bool())
    val write = Input(Bool())
    val wdata = Input(UInt(128.W))
    val wmask = Input(UInt(16.W))
    val rdata = Output(UInt(128.W))
  })

  // Setup SRAM modules
  val mod512 = (tcmEntries % 512) == 0
  val mod2048 = (tcmEntries % 2048) == 0
  assert((tcmEntries % 128) == 0)

  val sramAddrBits = (mod2048, mod512) match {
     case (true, _) => 11
     case (_, true) => 9
     case (false, false) => 7
  }

  val sramSelectBits = addrBits - sramAddrBits
  assert(sramSelectBits >= 0)

  val nSramModules = (mod2048, mod512) match {
     case (true, _) => tcmEntries / 2048
     case (_, true) => tcmEntries / 512
     case (false, false) => tcmEntries / 128
  }

  val sramModules = (0 until nSramModules).map(x =>
        (mod2048, mod512) match {
           case (true, _) => Module(new Sram_2048x128)
           case (_, true) => Module(new Sram_512x128)
           case (false, false) => Module(new Sram_12ffcp_128x128)
        }
      )
  val selectedSram = if (sramSelectBits == 0) { 0.U(sramSelectBits.W) } else { io.addr(addrBits - 1, sramAddrBits) }
  assert(selectedSram.getWidth == sramSelectBits)

  // Hook in inputs
  for (i <- 0 until nSramModules) {
    sramModules(i).io.clock := clock
    sramModules(i).io.addr := io.addr(sramAddrBits - 1, 0)
    sramModules(i).io.enable := (selectedSram === i.U) && io.enable
    sramModules(i).io.write := io.write
    sramModules(i).io.wdata := io.wdata
    sramModules(i).io.wmask := io.wmask
  }

  // Mux read output
  val selectedSramRead = RegNext(selectedSram, 0.U(sramSelectBits.W))
  io.rdata := MuxLookup(selectedSramRead, 0.U(sramAddrBits.W))(
      (0 until nSramModules).map(i => i.U -> sramModules(i).io.rdata))
}
