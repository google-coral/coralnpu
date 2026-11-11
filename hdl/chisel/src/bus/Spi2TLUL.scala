// Copyright 2025 Google LLC
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

package bus

import chisel3._
import common.MuBi4

class Spi2TLUL(p: TLULParameters, val dataWidth: Int = 1) extends Module {
  val tlul_p = p
  val io     = IO(new Bundle {
    val spi = new Bundle {
      val clk  = Input(Clock())
      val csb  = Input(Bool())
      val mosi = Input(UInt(dataWidth.W))
      val miso = Output(UInt(dataWidth.W))
    }
    val tl        = new OpenTitanTileLink.Host2Device(p)
    val sys_rst_o = Output(Bool())
  })

  val v2 = Module(new Spi2TLULV2(p, dataWidth))

  // Clock and reset wiring
  v2.io.spi_clk   := io.spi.clk
  v2.io.spi_rst_n := !io.spi.csb

  // MOSI: always valid, data from spi_mosi
  v2.io.q_mosi_pin.valid := true.B
  v2.io.q_mosi_pin.bits  := io.spi.mosi

  // MISO: always ready, output gated by valid
  v2.io.q_miso_pin.ready := true.B
  io.spi.miso            := Mux(v2.io.q_miso_pin.valid, v2.io.q_miso_pin.bits, 0.U(dataWidth.W))

  val v2_a = v2.io.q_tl_a.bits

  val raw_a = Wire(new OpenTitanTileLink.A_Channel(tlul_p))
  raw_a <> v2_a
  raw_a.user            := 0.U.asTypeOf(raw_a.user)
  raw_a.user.instr_type := MuBi4.False.asUInt

  io.tl.a.bits := raw_a

  io.tl.a.valid      := v2.io.q_tl_a.valid
  v2.io.q_tl_a.ready := io.tl.a.ready

  v2.io.q_tl_d.bits <> io.tl.d.bits
  v2.io.q_tl_d.valid := io.tl.d.valid
  io.tl.d.ready      := v2.io.q_tl_d.ready

  io.sys_rst_o := v2.io.sys_rst_o
}

import common.ChiselEmitter

object EmitWideSpi2TLUL extends App {
  val tlul_p = new TLULParameters(dataBits = 128, addrBits = 32, idBits = 6)
  ChiselEmitter.emit(new Spi2TLUL(tlul_p, dataWidth = 16), args)
}
