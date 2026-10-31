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

package bus

import chisel3._
import chisel3.util._
import common.{BitWidthForInt, FifoX, MakeWireBundle}

class TlulWidthBridge(val host_p: TLULParameters, val device_p: TLULParameters) extends Module {
  val io = IO(new Bundle {
    val tl_h = Flipped(new OpenTitanTileLink.Host2Device(host_p))
    val tl_d = new OpenTitanTileLink.Host2Device(device_p)

    val fault_a_o = Output(Bool())
    val fault_d_o = Output(Bool())
  })

  // ==========================================================================
  // Parameters and Constants
  // ==========================================================================
  val hostWidth   = host_p.w * 8
  val deviceWidth = device_p.w * 8

  // Default fault outputs
  io.fault_a_o := false.B
  io.fault_d_o := false.B

  // ==========================================================================
  // Wide to Narrow Path (e.g., 128-bit host to 32-bit device)
  // ==========================================================================
  if (hostWidth > deviceWidth) {
    val ratio       = hostWidth / deviceWidth
    val narrowBytes = deviceWidth / 8
    val hostBytes   = hostWidth / 8

    val req_info_q = Module(
      new Queue(
        new Bundle {
          val source = UInt(host_p.o.W)
          val beats  = UInt(BitWidthForInt(ratio))
          val size   = UInt(host_p.z.W)
        },
        8
      )
    )

    val numHostSources = 1 << host_p.o
    val d_data_reg     = RegInit(
      VecInit(Seq.fill(numHostSources)(VecInit(Seq.fill(ratio)(0.U(deviceWidth.W)))))
    )
    val d_resp_reg = RegInit(
      VecInit(Seq.fill(numHostSources)(0.U.asTypeOf(new OpenTitanTileLink.D_Channel(host_p))))
    )
    val d_valid_reg    = RegInit(0.U(numHostSources.W))
    val beats_received = RegInit(VecInit(Seq.fill(numHostSources)(0.U(ratio.W))))

    val host_source_idx = io.tl_d.d.bits.source >> log2Ceil(ratio)
    val beat_idx        = io.tl_d.d.bits.source(log2Ceil(ratio) - 1, 0)

    // Informational check — integrity enforcement lives at the xbar boundary;
    // this bridge just re-encodes because width conversion reshapes the data.
    val d_check = Module(new ResponseIntegrityCheck(device_p))
    d_check.io.d_i := io.tl_d.d.bits
    dontTouch(d_check.io.fault)

    val active_host_source  = req_info_q.io.deq.bits.source
    val next_beats_received = beats_received(host_source_idx) | (1.U << beat_idx)

    for (s <- 0 until numHostSources) {
      beats_received(s) := MuxCase(
        beats_received(s),
        Seq(
          (io.tl_d.d.fire && s.U === host_source_idx)    -> next_beats_received,
          (io.tl_h.d.fire && s.U === active_host_source) -> 0.U
        )
      )

      for (b <- 0 until ratio) {
        d_data_reg(s)(b) := MuxCase(
          d_data_reg(s)(b),
          Seq(
            (io.tl_d.d.fire && s.U === host_source_idx && b.U === beat_idx) -> io.tl_d.d.bits.data,
            (io.tl_h.d.fire && s.U === active_host_source)                  -> 0.U
          )
        )
      }

      val s_match_d = io.tl_d.d.fire && s.U === host_source_idx
      val s_match_h = io.tl_h.d.fire && s.U === active_host_source

      d_resp_reg(s) := MuxCase(
        d_resp_reg(s),
        Seq(
          s_match_d -> MakeWireBundle[OpenTitanTileLink.D_Channel](
            new OpenTitanTileLink.D_Channel(host_p),
            d => d -> io.tl_d.d.bits
          ),
          s_match_h -> 0.U.asTypeOf(new OpenTitanTileLink.D_Channel(host_p))
        )
      )
    }

    val d_valid_bits = VecInit((0 until numHostSources).map { s =>
      MuxCase(
        d_valid_reg(s),
        Seq(
          (io.tl_d.d.fire && s.U === host_source_idx && PopCount(
            next_beats_received
          ) === req_info_q.io.deq.bits.beats)            -> true.B,
          (io.tl_h.d.fire && s.U === active_host_source) -> false.B
        )
      )
    })
    d_valid_reg := d_valid_bits.asUInt

    val aggregated_data = VecInit(d_data_reg(active_host_source).zipWithIndex.map { case (d, i) =>
      Mux(
        io.tl_d.d.fire && host_source_idx === active_host_source && i.U === beat_idx,
        io.tl_d.d.bits.data,
        d
      )
    })
    val full_data = Cat(aggregated_data.reverse)

    val wide_resp_wire = Wire(new OpenTitanTileLink.D_Channel(host_p))
    wide_resp_wire.opcode := d_resp_reg(active_host_source).opcode
    wide_resp_wire.param  := d_resp_reg(active_host_source).param
    wide_resp_wire.size   := req_info_q.io.deq.bits.size
    wide_resp_wire.source := active_host_source
    wide_resp_wire.sink   := d_resp_reg(active_host_source).sink
    wide_resp_wire.data   := full_data
    wide_resp_wire.error  := d_resp_reg(active_host_source).error
    wide_resp_wire.user   := d_resp_reg(active_host_source).user

    val d_gen = Module(new ResponseIntegrityGen(host_p))
    d_gen.io.d_i := wide_resp_wire

    io.tl_d.d.ready := true.B
    io.tl_h.d.valid := d_valid_reg(active_host_source) && req_info_q.io.deq.valid

    val d_h_bits = Wire(new OpenTitanTileLink.D_Channel(host_p))
    d_h_bits.opcode := d_gen.io.d_o.opcode
    d_h_bits.param  := d_gen.io.d_o.param
    d_h_bits.size   := d_gen.io.d_o.size
    d_h_bits.source := d_gen.io.d_o.source
    d_h_bits.sink   := d_gen.io.d_o.sink
    d_h_bits.data   := full_data
    d_h_bits.error  := d_gen.io.d_o.error
    d_h_bits.user   := d_gen.io.d_o.user
    io.tl_h.d.bits  := d_h_bits

    req_info_q.io.deq.ready := io.tl_h.d.fire

    // ------------------------------------------------------------------------
    // Request Path (A Channel): Split wide request into multiple narrow ones
    // ------------------------------------------------------------------------
    // Informational check; enforcement is at the xbar boundary.
    val a_check = Module(new RequestIntegrityCheck(host_p))
    a_check.io.a_i := io.tl_h.a.bits
    io.fault_a_o   := a_check.io.fault
    dontTouch(a_check.io.fault)

    val is_write = io.tl_h.a.bits.opcode === TLULOpcodesA.PutFullData.asUInt ||
      io.tl_h.a.bits.opcode === TLULOpcodesA.PutPartialData.asUInt
    val address_offset = io.tl_h.a.bits.address(log2Ceil(hostBytes) - 1, 0)
    val size_in_bytes  = 1.U << io.tl_h.a.bits.size
    val read_mask      = (((1.U << size_in_bytes) - 1.U) << address_offset)(hostBytes - 1, 0)
    val effective_mask = Mux(is_write, io.tl_h.a.bits.mask, read_mask)

    val device_size_cap = log2Ceil(device_p.w).U
    val full_mask       = ((1 << narrowBytes) - 1).U

    val is_wide_transaction = io.tl_h.a.bits.size > device_size_cap
    val host_beat_idx       = io.tl_h.a.bits.address(log2Ceil(hostBytes) - 1, log2Ceil(narrowBytes))

    require(
      device_p.o >= (host_p.o + log2Ceil(ratio)),
      s"Device source ID width (${device_p.o}) is too narrow for host source ID width (${host_p.o}) plus ${log2Ceil(ratio)} beat bits"
    )

    val req_fifo = Module(
      new FifoX(new OpenTitanTileLink.A_Channel(device_p), ratio, ratio * 2 + 1)
    )
    val beats = Wire(Vec(ratio, Valid(new OpenTitanTileLink.A_Channel(device_p))))

    for (i <- 0 until ratio) {
      val req_gen      = Module(new RequestIntegrityGen(device_p))
      val narrow_req   = Wire(new OpenTitanTileLink.A_Channel(device_p))
      val narrow_mask  = (effective_mask >> (i * narrowBytes)).asUInt(narrowBytes - 1, 0)
      val is_full_beat = narrow_mask === full_mask

      narrow_req.opcode := Mux(
        is_write,
        Mux(
          is_full_beat && io.tl_h.a.bits.opcode === TLULOpcodesA.PutFullData.asUInt,
          TLULOpcodesA.PutFullData.asUInt,
          TLULOpcodesA.PutPartialData.asUInt
        ),
        io.tl_h.a.bits.opcode
      )
      narrow_req.param := io.tl_h.a.bits.param
      narrow_req.size  := device_size_cap

      val beat_source_offset = Mux(is_wide_transaction, i.U, host_beat_idx)
      narrow_req.source := Cat(io.tl_h.a.bits.source, beat_source_offset(log2Ceil(ratio) - 1, 0))

      narrow_req.address := (io.tl_h.a.bits.address & ~((hostBytes - 1)
        .U(32.W))) + (i * narrowBytes).U
      narrow_req.mask            := narrow_mask
      narrow_req.data            := (io.tl_h.a.bits.data >> (i * deviceWidth)).asUInt
      narrow_req.user.rsvd       := io.tl_h.a.bits.user.rsvd
      narrow_req.user.instr_type := io.tl_h.a.bits.user.instr_type
      narrow_req.user.cmd_intg   := io.tl_h.a.bits.user.cmd_intg
      narrow_req.user.data_intg  := io.tl_h.a.bits.user.data_intg

      req_gen.io.a_i := narrow_req
      beats(i).bits  := req_gen.io.a_o
      beats(i).valid := Mux(is_wide_transaction, true.B, i.U === host_beat_idx)
    }

    req_fifo.io.in.bits  := beats
    req_fifo.io.in.valid := io.tl_h.a.valid && req_info_q.io.enq.ready
    io.tl_h.a.ready      := req_fifo.io.in.ready && req_info_q.io.enq.ready
    io.tl_d.a <> req_fifo.io.out

    val total_beats = PopCount(beats.map(_.valid))
    req_info_q.io.enq.valid       := io.tl_h.a.fire
    req_info_q.io.enq.bits.source := io.tl_h.a.bits.source
    req_info_q.io.enq.bits.beats  := total_beats
    req_info_q.io.enq.bits.size   := io.tl_h.a.bits.size

    // ==========================================================================
    // Narrow to Wide Path (e.g., 32-bit host to 128-bit device)
    // ==========================================================================
  } else if (hostWidth < deviceWidth) {
    val wideBytes       = deviceWidth / 8
    val hostBytes       = hostWidth / 8
    val numSourceIds    = 1 << host_p.o
    val addr_lsb_width  = log2Ceil(wideBytes)
    val host_align_bits = log2Ceil(hostBytes)
    val index_width     = log2Ceil(numSourceIds)
    val addr_lsb_regs   = RegInit(VecInit(Seq.fill(numSourceIds)(0.U(addr_lsb_width.W))))

    val req_addr_lsb = io.tl_h.a.bits.address(addr_lsb_width - 1, 0)

    for (s <- 0 until numSourceIds) {
      val source_match =
        if (index_width > 0) io.tl_h.a.bits.source(index_width - 1, 0) === s.U else true.B
      addr_lsb_regs(s) := Mux(io.tl_h.a.fire && source_match, req_addr_lsb, addr_lsb_regs(s))
    }

    // Informational check; enforcement is at the xbar boundary.
    val a_check = Module(new RequestIntegrityCheck(host_p))
    a_check.io.a_i := io.tl_h.a.bits
    io.fault_a_o   := a_check.io.fault
    dontTouch(a_check.io.fault)

    val a_gen       = Module(new RequestIntegrityGen(device_p))
    val wide_req    = Wire(new OpenTitanTileLink.A_Channel(device_p))
    val is_put_full = io.tl_h.a.bits.opcode === TLULOpcodesA.PutFullData.asUInt

    wide_req.opcode := Mux(is_put_full, TLULOpcodesA.PutPartialData.asUInt, io.tl_h.a.bits.opcode)
    wide_req.param  := io.tl_h.a.bits.param
    wide_req.size   := io.tl_h.a.bits.size
    wide_req.source := io.tl_h.a.bits.source

    // Address Alignment: Keep address unaligned. Downstream bridges/devices
    // should handle unaligned TileLink addresses. Our internal steering handles
    // alignment within this bridge's width conversion.
    wide_req.address         := io.tl_h.a.bits.address
    wide_req.user.rsvd       := io.tl_h.a.bits.user.rsvd
    wide_req.user.instr_type := io.tl_h.a.bits.user.instr_type
    wide_req.user.cmd_intg   := io.tl_h.a.bits.user.cmd_intg
    wide_req.user.data_intg  := io.tl_h.a.bits.user.data_intg

    // Steering: Only shift by bits that are NEW to this bridge.
    // Bits below 'host_align_bits' are already handled by the host's native steering.
    val steering_shift = (req_addr_lsb >> host_align_bits) << host_align_bits
    wide_req.mask := (io.tl_h.a.bits.mask.asUInt << steering_shift).asUInt
    wide_req.data := (io.tl_h.a.bits.data.asUInt << (steering_shift << 3.U)).asUInt
    a_gen.io.a_i  := wide_req

    io.tl_d.a.valid := io.tl_h.a.valid
    io.tl_d.a.bits  := a_gen.io.a_o
    io.tl_h.a.ready := io.tl_d.a.ready

    // Informational check; enforcement is at the xbar boundary.
    val d_check = Module(new ResponseIntegrityCheck(device_p))
    d_check.io.d_i := io.tl_d.d.bits
    io.fault_d_o   := d_check.io.fault
    dontTouch(d_check.io.fault)

    val d_gen         = Module(new ResponseIntegrityGen(host_p))
    val narrow_resp   = Wire(new OpenTitanTileLink.D_Channel(host_p))
    val resp_addr_lsb = if (index_width > 0) {
      addr_lsb_regs(io.tl_d.d.bits.source(index_width - 1, 0))
    } else {
      addr_lsb_regs(0)
    }

    narrow_resp.opcode := io.tl_d.d.bits.opcode
    narrow_resp.param  := io.tl_d.d.bits.param
    narrow_resp.size   := io.tl_d.d.bits.size
    narrow_resp.source := io.tl_d.d.bits.source
    narrow_resp.sink   := io.tl_d.d.bits.sink

    // Shifting back: Only shift back the bits NEW to this bridge.
    val resp_steering_shift = (resp_addr_lsb >> host_align_bits) << host_align_bits
    narrow_resp.data           := (io.tl_d.d.bits.data >> (resp_steering_shift << 3.U)).asUInt
    narrow_resp.error          := io.tl_d.d.bits.error
    narrow_resp.user.rsp_intg  := io.tl_d.d.bits.user.rsp_intg
    narrow_resp.user.data_intg := io.tl_d.d.bits.user.data_intg

    d_gen.io.d_i := narrow_resp

    io.tl_h.d.valid := io.tl_d.d.valid
    io.tl_h.d.bits  := d_gen.io.d_o
    io.tl_d.d.ready := io.tl_h.d.ready

    // ==========================================================================
    // Equal Widths Path
    // ==========================================================================
  } else {
    io.tl_d <> io.tl_h
  }
}
