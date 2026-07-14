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

package coralnpu.soc

import chisel3._
import chisel3.util._
import bus._
import coralnpu.Sram_Nx128

class RawTlulSram(p: TLULParameters, sramSizeBytes: Int, globalBaseAddr: Int = 0) extends Module {
  val io = IO(new Bundle {
    val tl = Flipped(new TLULHost2Device[NoUser, NoUser](p))
  })

  val tcmEntries    = sramSizeBytes / 16
  val sramAddrWidth = log2Ceil(tcmEntries)

  val adapter = Module(new RawTlulToSram(p, sramAddrWidth))
  val sram    = Module(new Sram_Nx128(tcmEntries, globalBaseAddr))

  adapter.io.tl <> io.tl

  sram.io.addr   := adapter.io.sram.addr
  sram.io.enable := adapter.io.sram.enable
  sram.io.write  := adapter.io.sram.write
  sram.io.wdata  := adapter.io.sram.wdata
  sram.io.wmask  := adapter.io.sram.wmask

  adapter.io.sram.rdata  := sram.io.rdata
  adapter.io.sram.rvalid := sram.io.rvalid
}
