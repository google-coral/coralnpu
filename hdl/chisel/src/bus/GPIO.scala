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

package bus

import chisel3._
import chisel3.util._

case class GPIOParameters(
  width: Int
)

class GPIO(p: TLULParameters, gpioParams: GPIOParameters) extends Module {
  val tlul_p = p
  val io     = IO(new Bundle {
    val tl        = Flipped(new OpenTitanTileLink.Host2Device(tlul_p))
    val gpio_o    = Output(UInt(gpioParams.width.W))
    val gpio_en_o = Output(UInt(gpioParams.width.W))
    val gpio_i    = Input(UInt(gpioParams.width.W))
  })

  // Register Map
  object GpioRegs {
    val DATA_IN  = 0x00.U
    val DATA_OUT = 0x04.U
    val OUT_EN   = 0x08.U
  }
  import GpioRegs._

  val data_out = RegInit(0.U(gpioParams.width.W))
  val out_en   = RegInit(0.U(gpioParams.width.W))

  // Drive outputs
  io.gpio_o    := data_out
  io.gpio_en_o := out_en

  // TileLink Interface
  val tl_a = io.tl.a
  val tl_d = io.tl.d

  val addr_offset = tl_a.bits.address(11, 0)

  // Response logic
  val tl_d_valid  = RegInit(false.B)
  val tl_d_opcode = Reg(UInt(3.W))
  val tl_d_data   = Reg(UInt(32.W))
  val tl_d_size   = Reg(UInt(tlul_p.z.W))
  val tl_d_source = Reg(UInt(tlul_p.a.W))
  val tl_d_error  = Reg(Bool())

  tl_a.ready := !tl_d_valid

  when(tl_a.fire) {
    tl_d_valid  := true.B
    tl_d_source := tl_a.bits.source
    tl_d_size   := tl_a.bits.size
    tl_d_error  := false.B

    val is_write = (tl_a.bits.opcode === TLULOpcodesA.PutFullData.asUInt ||
      tl_a.bits.opcode === TLULOpcodesA.PutPartialData.asUInt)

    when(is_write) {
      tl_d_opcode := TLULOpcodesD.AccessAck.asUInt
      switch(addr_offset) {
        is(DATA_OUT) { data_out := tl_a.bits.data }
        is(OUT_EN) { out_en := tl_a.bits.data }
        is(DATA_IN) { tl_d_error := true.B } // Read-only
      }
    }.otherwise {
      tl_d_opcode := TLULOpcodesD.AccessAckData.asUInt
      switch(addr_offset) {
        is(DATA_IN) { tl_d_data := io.gpio_i }
        is(DATA_OUT) { tl_d_data := data_out }
        is(OUT_EN) { tl_d_data := out_en }
        // Default: 0 for undefined
      }
    }

    val is_known_addr = VecInit(DATA_IN, DATA_OUT, OUT_EN).contains(addr_offset)
    when(!is_known_addr) { tl_d_error := true.B }
  }

  when(tl_d.fire) {
    tl_d_valid := false.B
  }

  tl_d.valid       := tl_d_valid
  tl_d.bits.opcode := tl_d_opcode
  tl_d.bits.data   := tl_d_data
  tl_d.bits.size   := tl_d_size
  tl_d.bits.source := tl_d_source
  tl_d.bits.error  := tl_d_error
  tl_d.bits.sink   := 0.U
  tl_d.bits.param  := 0.U
  tl_d.bits.user   := 0.U.asTypeOf(tl_d.bits.user)
}

import common.ChiselEmitter

object EmitGPIO extends App {
  val tlul_p = new TLULParameters(dataBits = 32, addrBits = 32, idBits = 10)
  val gp     = GPIOParameters(width = 32)
  ChiselEmitter.emit(new GPIO(tlul_p, gp), args)
}
