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

class Sram_Nx128(tcmEntries: Int, globalBaseAddr: Int = 0) extends Module {
  override val desiredName = "SRAM_" + tcmEntries + "x128"
  val addrBits             = log2Ceil(tcmEntries)
  val io                   = IO(new Bundle {
    val addr   = Input(UInt(addrBits.W))
    val enable = Input(Bool())
    val write  = Input(Bool())
    val wdata  = Input(UInt(128.W))
    val wmask  = Input(UInt(16.W))
    val rdata  = Output(UInt(128.W))
    val rvalid = Output(Bool())
  })

  // Setup SRAM modules
  // Use the largest possible SRAM block (2048, then 512, then 128)
  val blockSize =
    if (tcmEntries % 2048 == 0) 2048
    else if (tcmEntries % 512 == 0) 512
    else 128

  val nSramModules   = tcmEntries / blockSize
  val sramAddrBits   = log2Ceil(blockSize)
  val sramSelectBits = addrBits - sramAddrBits
  assert(sramSelectBits >= 0)

  val sramModules = (0 until nSramModules).map(x => {
    val subModuleAddr = globalBaseAddr + x * blockSize * 16
    Module(new SramBlock(blockSize, subModuleAddr))
  })

  // Hook in inputs and Mux read output
  if (nSramModules == 1) {
    sramModules(0).io.clock  := clock
    sramModules(0).io.addr   := io.addr
    sramModules(0).io.enable := io.enable
    sramModules(0).io.write  := io.write
    sramModules(0).io.wdata  := io.wdata
    sramModules(0).io.wmask  := io.wmask
    io.rdata                 := sramModules(0).io.rdata
  } else {
    val selectedSram = io.addr(addrBits - 1, sramAddrBits)
    for (i <- 0 until nSramModules) {
      sramModules(i).io.clock  := clock
      sramModules(i).io.addr   := io.addr(sramAddrBits - 1, 0)
      sramModules(i).io.enable := (selectedSram === i.U) && io.enable
      sramModules(i).io.write  := io.write
      sramModules(i).io.wdata  := io.wdata
      sramModules(i).io.wmask  := io.wmask
    }
    val selectedSramRead = RegNext(selectedSram, 0.U(sramSelectBits.W))
    io.rdata := MuxLookup(selectedSramRead, 0.U(128.W))(
      (0 until nSramModules).map(i => i.U -> sramModules(i).io.rdata)
    )
  }
  io.rvalid := RegNext(io.enable)
}

// SramBlock — moved here from Sram.scala (macOS case-insensitive FS workaround)
class SramBlock(numEntries: Int, globalBaseAddr: Int = 0) extends SRAM128(numEntries, globalBaseAddr) with HasBlackBoxResource {
  override val desiredName = "Sram"
  addResource("Sram.v")
}
