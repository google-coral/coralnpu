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
import common.MakeInvalid

class RawTlulErrorResponder(p: TLULParameters) extends Module {
  val io = IO(new Bundle {
    val tl_h = Flipped(new TLULHost2Device[NoUser, NoUser](p))
  })

  val d = RegInit(MakeInvalid(new TileLink_D_Channel(p)))

  // We are ready for a new request only if we are not holding a pending response
  io.tl_h.a.ready := !d.valid

  // Hold valid until consumed by the host (io.tl_h.d.fire)
  d.valid       := (d.valid || io.tl_h.a.fire) && !io.tl_h.d.fire
  d.bits.size   := Mux(io.tl_h.a.fire, io.tl_h.a.bits.size, d.bits.size)
  d.bits.source := Mux(io.tl_h.a.fire, io.tl_h.a.bits.source, d.bits.source)
  val is_get        = io.tl_h.a.bits.opcode === TLULOpcodesA.Get.asUInt
  val next_d_opcode = Mux(is_get, TLULOpcodesD.AccessAckData.asUInt, TLULOpcodesD.AccessAck.asUInt)
  d.bits.opcode := Mux(io.tl_h.a.fire, next_d_opcode, d.bits.opcode)
  d.bits.param  := 0.U
  d.bits.sink   := 0.U
  d.bits.data   := 0.U
  d.bits.error  := true.B
  d.bits.user   := 0.U.asTypeOf(d.bits.user)

  io.tl_h.d.valid := d.valid
  io.tl_h.d.bits  := d.bits
}
