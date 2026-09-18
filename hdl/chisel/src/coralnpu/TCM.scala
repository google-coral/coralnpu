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
import common._

class TCM128(
  tcmSizeBytes: Int,
  tcmSubEntryWidth: Int,
  globalBaseAddr: Int = 0,
  availableBlockSizes: Seq[Int] = Seq(512, 128)
) extends Module {
  val tcmWidth      = 128
  val tcmEntries    = tcmSizeBytes / (tcmWidth / 8)
  val tcmSubEntries = tcmWidth / tcmSubEntryWidth

  val io = IO(new Bundle {
    val addr   = Input(UInt(log2Ceil(tcmEntries).W)) // 9 for 512 rows to address
    val enable = Input(Bool())
    val write  = Input(Bool())
    val wdata  = Input(Vec(tcmSubEntries, UInt(tcmSubEntryWidth.W)))
    val wmask  = Input(Vec(tcmSubEntries, Bool()))
    val rdata  = Output(Vec(tcmSubEntries, UInt(tcmSubEntryWidth.W)))
  })

  val sram = Module(new Sram_Nx128(tcmEntries, globalBaseAddr, availableBlockSizes))
  sram.io.addr   := io.addr
  sram.io.enable := io.enable
  sram.io.write  := Cat(io.write)
  sram.io.wdata  := Cat(io.wdata.reverse)
  sram.io.wmask  := Cat(io.wmask.reverse)
  io.rdata       := UIntToVec(sram.io.rdata, tcmSubEntryWidth).reverse
}
