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
import chisel3.util._

class TlulIdRemapper[A_USER <: Data, D_USER <: Data](
  p_tl_in: TLULParameters,
  p_tl_out: TLULParameters,
  userAGen: () => A_USER,
  userDGen: () => D_USER
) extends Module {
  val io = IO(new Bundle {
    val tl_a_in  = Flipped(Decoupled(new TileLink_A_ChannelBase(p_tl_in, userAGen)))
    val tl_a_out = Decoupled(new TileLink_A_ChannelBase(p_tl_out, userAGen))
    val tl_d_in  = Flipped(Decoupled(new TileLink_D_ChannelBase(p_tl_out, userDGen)))
    val tl_d_out = Decoupled(new TileLink_D_ChannelBase(p_tl_in, userDGen))
  })

  val axiIdWidth      = p_tl_out.o
  val numTrackerSlots = 1 << axiIdWidth

  val outstanding_reg     = RegInit(0.U(numTrackerSlots.W))
  val saved_source_id_map = RegInit(VecInit(Seq.fill(numTrackerSlots)(0.U(p_tl_in.o.W))))

  val tl_a_q = Queue(io.tl_a_in, 2)
  val tl_d_q = Wire(Decoupled(new TileLink_D_ChannelBase(p_tl_in, userDGen)))
  io.tl_d_out <> Queue(tl_d_q, 2)

  val truncated_id = tl_a_q.bits.source(axiIdWidth - 1, 0)
  val lane_is_busy = outstanding_reg(truncated_id)

  // Remap tl_a
  io.tl_a_out.bits        := tl_a_q.bits
  io.tl_a_out.bits.source := truncated_id
  io.tl_a_out.valid       := tl_a_q.valid && !lane_is_busy
  tl_a_q.ready            := io.tl_a_out.ready && !lane_is_busy

  // Remap tl_d
  tl_d_q.bits        := io.tl_d_in.bits
  tl_d_q.bits.source := saved_source_id_map(io.tl_d_in.bits.source)
  tl_d_q.valid       := io.tl_d_in.valid
  io.tl_d_in.ready   := tl_d_q.ready

  val a_fire   = io.tl_a_out.fire
  val d_fire   = io.tl_d_in.fire
  val d_source = io.tl_d_in.bits.source

  val set_mask = Mux(a_fire, UIntToOH(truncated_id, numTrackerSlots), 0.U(numTrackerSlots.W))
  val clr_mask = Mux(d_fire, UIntToOH(d_source, numTrackerSlots), 0.U(numTrackerSlots.W))
  outstanding_reg := (outstanding_reg & ~clr_mask) | set_mask

  saved_source_id_map(truncated_id) := Mux(
    a_fire,
    tl_a_q.bits.source,
    saved_source_id_map(truncated_id)
  )
}
