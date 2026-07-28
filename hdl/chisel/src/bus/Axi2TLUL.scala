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
import common.{CoralNPURRArbiter, MuBi4}

/** Axi2TLUL: A Chisel module that serves as a bridge between an AXI4 master and a TileLink-UL
  * slave.
  *
  * This module translates AXI read and write transactions into TileLink Get and Put operations,
  * respectively. It uses a dataflow approach with queues to manage the protocol conversion.
  *
  * Note: This implementation handles single-beat AXI transactions (len=0). AXI bursting would
  * require more complex logic to be added.
  *
  * @param p
  *   The CoralNPU parameters.
  */
class Axi2TLUL[A_USER <: Data with TLUL_A_User_InstrType, D_USER <: Data](
  p: TLULParameters,
  userAGen: () => A_USER,
  userDGen: () => D_USER
) extends Module {
  val tlul_p = p
  val io     = IO(new Bundle {
    val axi  = Flipped(new AxiMasterIO(p.a, p.w * 8, p.o))
    val tl_a = Decoupled(new TileLink_A_ChannelBase(tlul_p, userAGen))          // TileLink Output
    val tl_d = Flipped(Decoupled(new TileLink_D_ChannelBase(tlul_p, userDGen))) // TileLink Input
  })

  // Mapping AXI ID to instr_type (MuBi4.True for instruction, MuBi4.False for data).
  // ID 1 is for IBus, others are for DBus.
  def idToInstrType(id: UInt): UInt = Mux(id === 1.U, MuBi4.True.asUInt, MuBi4.False.asUInt)

  val read_addr_q  = Queue(io.axi.read.addr, entries = 2)
  val write_addr_q = Queue(io.axi.write.addr, entries = 2)
  val write_data_q = Queue(io.axi.write.data, entries = 2)

  // Read Burst Unroller
  val r_unroll_busy  = RegInit(false.B)
  val r_unroll_addr  = RegInit(0.U(p.a.W))
  val r_unroll_id    = RegInit(0.U(p.o.W))
  val r_unroll_size  = RegInit(0.U(3.W))
  val r_unroll_len   = RegInit(0.U(8.W))
  val r_unroll_burst = RegInit(0.U(2.W))

  val r_req   = read_addr_q.bits
  val r_valid = read_addr_q.valid

  val r_current_addr  = Mux(r_unroll_busy, r_unroll_addr, r_req.addr)
  val r_current_id    = Mux(r_unroll_busy, r_unroll_id, r_req.id)
  val r_current_size  = Mux(r_unroll_busy, r_unroll_size, r_req.size)
  val r_current_len   = Mux(r_unroll_busy, r_unroll_len, r_req.len)
  val r_current_burst = Mux(r_unroll_busy, r_unroll_burst, r_req.burst)

  val r_beats_left   = RegInit(VecInit(Seq.fill(1 << p.o)(0.U(8.W))))
  val r_burst_active = RegInit(VecInit(Seq.fill(1 << p.o)(false.B)))

  val id_conflict = !r_unroll_busy && r_burst_active(r_req.id)

  val read_stream = Wire(Decoupled(new TileLink_A_ChannelBase(tlul_p, userAGen)))
  read_stream.valid                := (r_valid && !id_conflict) || r_unroll_busy
  read_stream.bits.opcode          := TLULOpcodesA.Get.asUInt
  read_stream.bits.param           := 0.U
  read_stream.bits.size            := r_current_size
  read_stream.bits.source          := r_current_id
  read_stream.bits.address         := r_current_addr
  read_stream.bits.mask            := Fill(tlul_p.w, 1.U)
  read_stream.bits.data            := 0.U((8 * tlul_p.w).W)
  read_stream.bits.user            := 0.U.asTypeOf(io.tl_a.bits.user)
  read_stream.bits.user.instr_type := idToInstrType(r_current_id)

  val r_addr_inc = 1.U << r_current_size

  val r_fire             = read_stream.fire
  val r_start            = r_fire && !r_unroll_busy
  val r_step             = r_fire && r_unroll_busy
  val r_last             = r_step && r_unroll_len === 0.U
  val r_unroll_next_addr =
    Mux(r_unroll_burst === AxiBurstType.FIXED.asUInt, r_unroll_addr, r_unroll_addr + r_addr_inc)
  val r_start_next_addr =
    Mux(r_req.burst === AxiBurstType.FIXED.asUInt, r_req.addr, r_req.addr + r_addr_inc)

  r_unroll_busy  := Mux(r_start && r_req.len =/= 0.U, true.B, Mux(r_last, false.B, r_unroll_busy))
  r_unroll_addr  := Mux(r_start, r_start_next_addr, Mux(r_step, r_unroll_next_addr, r_unroll_addr))
  r_unroll_id    := Mux(r_start, r_req.id, r_unroll_id)
  r_unroll_size  := Mux(r_start, r_req.size, r_unroll_size)
  r_unroll_len   := Mux(r_start, r_req.len - 1.U, Mux(r_step, r_unroll_len - 1.U, r_unroll_len))
  r_unroll_burst := Mux(r_start, r_req.burst, r_unroll_burst)

  read_addr_q.ready := read_stream.ready && !id_conflict && (!r_unroll_busy && r_req.len === 0.U || r_unroll_busy && r_unroll_len === 0.U)

  // Write Burst Unroller
  val w_unroll_busy  = RegInit(false.B)
  val w_unroll_addr  = RegInit(0.U(p.a.W))
  val w_unroll_id    = RegInit(0.U(p.o.W))
  val w_unroll_size  = RegInit(0.U(3.W))
  val w_unroll_len   = RegInit(0.U(8.W))
  val w_unroll_burst = RegInit(0.U(2.W))

  val w_req  = write_addr_q.bits
  val w_data = write_data_q.bits

  val w_current_addr  = Mux(w_unroll_busy, w_unroll_addr, w_req.addr)
  val w_current_id    = Mux(w_unroll_busy, w_unroll_id, w_req.id)
  val w_current_size  = Mux(w_unroll_busy, w_unroll_size, w_req.size)
  val w_current_len   = Mux(w_unroll_busy, w_unroll_len, w_req.len)
  val w_current_burst = Mux(w_unroll_busy, w_unroll_burst, w_req.burst)

  val w_beats_left   = RegInit(VecInit(Seq.fill(1 << p.o)(0.U(8.W))))
  val w_burst_active = RegInit(VecInit(Seq.fill(1 << p.o)(false.B)))
  val w_err_accum    = RegInit(VecInit(Seq.fill(1 << p.o)(false.B)))

  val w_id_conflict = !w_unroll_busy && w_burst_active(w_req.id)
  val w_valid       = write_addr_q.valid && write_data_q.valid && !w_id_conflict

  val write_stream = Wire(Decoupled(new TileLink_A_ChannelBase(tlul_p, userAGen)))
  write_stream.valid := w_valid || (w_unroll_busy && write_data_q.valid)

  val byte_offset   = if (p.w > 1) w_current_addr(log2Ceil(p.w) - 1, 0) else 0.U
  val expected_strb = (((1.U << (1.U << w_current_size)) - 1.U) << byte_offset)(p.w - 1, 0)
  val is_full       =
    (w_data.strb === expected_strb) && ((w_current_addr & ((1.U << w_current_size) - 1.U)) === 0.U)
  write_stream.bits.opcode := Mux(
    is_full,
    TLULOpcodesA.PutFullData.asUInt,
    TLULOpcodesA.PutPartialData.asUInt
  )
  write_stream.bits.param           := 0.U
  write_stream.bits.size            := w_current_size
  write_stream.bits.source          := w_current_id
  write_stream.bits.address         := w_current_addr
  write_stream.bits.mask            := w_data.strb
  write_stream.bits.data            := w_data.data
  write_stream.bits.user            := 0.U.asTypeOf(io.tl_a.bits.user)
  write_stream.bits.user.instr_type := idToInstrType(w_current_id)

  val w_addr_inc = 1.U << w_current_size
  val w_last     = (w_unroll_busy && w_unroll_len === 0.U) || (!w_unroll_busy && w_req.len === 0.U)

  val w_fire      = write_stream.fire
  val w_start     = w_fire && !w_unroll_busy
  val w_step      = w_fire && w_unroll_busy
  val w_last_step = w_step && w_unroll_len === 0.U

  val w_start_next_addr =
    Mux(w_req.burst === AxiBurstType.FIXED.asUInt, w_req.addr, w_req.addr + w_addr_inc)
  val w_unroll_next_addr =
    Mux(w_unroll_burst === AxiBurstType.FIXED.asUInt, w_unroll_addr, w_unroll_addr + w_addr_inc)

  w_unroll_busy := Mux(
    w_start && w_req.len =/= 0.U,
    true.B,
    Mux(w_last_step, false.B, w_unroll_busy)
  )
  w_unroll_addr  := Mux(w_start, w_start_next_addr, Mux(w_step, w_unroll_next_addr, w_unroll_addr))
  w_unroll_id    := Mux(w_start, w_req.id, w_unroll_id)
  w_unroll_size  := Mux(w_start, w_req.size, w_unroll_size)
  w_unroll_len   := Mux(w_start, w_req.len - 1.U, Mux(w_step, w_unroll_len - 1.U, w_unroll_len))
  w_unroll_burst := Mux(w_start, w_req.burst, w_unroll_burst)

  write_addr_q.ready := write_stream.ready && write_data_q.valid && !w_id_conflict && w_last
  write_data_q.ready := write_stream.ready && (!w_unroll_busy && !w_id_conflict || w_unroll_busy)

  // Reads are given higher priority.
  val arb = Module(new CoralNPURRArbiter(new TileLink_A_ChannelBase(tlul_p, userAGen), 2))
  arb.io.in(0) <> read_stream
  arb.io.in(1) <> write_stream

  io.tl_a.bits     := arb.io.out.bits
  io.tl_a.valid    := arb.io.out.valid
  arb.io.out.ready := io.tl_a.ready

  val d_is_write = io.tl_d.bits.opcode === TLULOpcodesD.AccessAck.asUInt
  val d_is_read  = io.tl_d.bits.opcode === TLULOpcodesD.AccessAckData.asUInt
  val d_source   = io.tl_d.bits.source

  val r_d_last = r_beats_left(d_source) === 0.U
  val w_d_last = w_beats_left(d_source) === 0.U

  val w_resp_err = io.tl_d.bits.error || w_err_accum(d_source)

  io.axi.write.resp.valid     := io.tl_d.valid && d_is_write && w_d_last
  io.axi.write.resp.bits.id   := d_source
  io.axi.write.resp.bits.resp := Mux(
    w_resp_err,
    AxiResponseType.SLVERR.asUInt,
    AxiResponseType.OKAY.asUInt
  )

  io.axi.read.data.valid     := io.tl_d.valid && d_is_read
  io.axi.read.data.bits.id   := d_source
  io.axi.read.data.bits.data := io.tl_d.bits.data
  io.axi.read.data.bits.resp := Mux(
    io.tl_d.bits.error,
    AxiResponseType.SLVERR.asUInt,
    AxiResponseType.OKAY.asUInt
  )
  io.axi.read.data.bits.last := r_d_last

  io.tl_d.ready := Mux(
    d_is_read,
    io.axi.read.data.ready,
    Mux(w_d_last, io.axi.write.resp.ready, true.B)
  )

  for (i <- 0 until (1 << p.o)) {
    val is_r_req  = r_start && r_req.id === i.U
    val is_r_resp = io.tl_d.fire && d_is_read && d_source === i.U

    r_burst_active(i) := Mux(
      is_r_req,
      true.B,
      Mux(is_r_resp && r_beats_left(i) === 0.U, false.B, r_burst_active(i))
    )
    r_beats_left(i) := Mux(
      is_r_req,
      r_req.len,
      Mux(is_r_resp && r_beats_left(i) =/= 0.U, r_beats_left(i) - 1.U, r_beats_left(i))
    )

    val is_w_req  = w_start && w_req.id === i.U
    val is_w_resp = io.tl_d.fire && d_is_write && d_source === i.U

    w_burst_active(i) := Mux(
      is_w_req,
      true.B,
      Mux(is_w_resp && w_beats_left(i) === 0.U, false.B, w_burst_active(i))
    )
    w_beats_left(i) := Mux(
      is_w_req,
      w_req.len,
      Mux(is_w_resp && w_beats_left(i) =/= 0.U, w_beats_left(i) - 1.U, w_beats_left(i))
    )
    w_err_accum(i) := Mux(
      is_w_req,
      false.B,
      Mux(is_w_resp && io.tl_d.bits.error, true.B, w_err_accum(i))
    )
  }
}

import _root_.circt.stage.{ChiselStage, FirtoolOption}

import chisel3.stage.ChiselGeneratorAnnotation
import scala.annotation.nowarn

@nowarn
object EmitAxi2TLUL extends App {
  val tlul_p = new TLULParameters(dataBits = 256, addrBits = 32, idBits = 6)
  (new ChiselStage).execute(
    Array("--target", "systemverilog") ++ args,
    Seq(
      ChiselGeneratorAnnotation(() =>
        new Axi2TLUL(tlul_p, () => new OpenTitanTileLink_A_User, () => new OpenTitanTileLink_D_User)
      )
    ) ++ Seq(FirtoolOption("-enable-layers=Verification"))
  )
}
