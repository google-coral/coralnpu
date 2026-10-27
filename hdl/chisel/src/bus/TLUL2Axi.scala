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
import common.CoralNPURRArbiter

/** TLUL2Axi: A Chisel module that serves as a bridge between a TileLink-UL master and an AXI4
  * slave.
  *
  * This module translates TileLink Get and Put operations into AXI read and write transactions,
  * respectively. It uses a dataflow approach with queues and an arbiter to manage the protocol
  * conversion.
  *
  * @param p
  *   The CoralNPU parameters.
  * @param maxReadTx
  *   Maximum number of in-flight read transactions.
  * @param maxWriteTx
  *   Maximum number of in-flight write transactions.
  */
class TLUL2Axi[A_USER <: Data with TLUL_A_User_InstrType, D_USER <: Data](
  val p_tl: TLULParameters,
  val axiDataBits: Int,
  val axiAddrBits: Int,
  val axiIdBits: Int,
  userAGen: () => A_USER,
  userDGen: () => D_USER,
  val maxReadTx: Int = 8,
  val maxWriteTx: Int = 8
) extends Module {
  require(maxReadTx > 0, "maxReadTx must be positive")
  require(maxWriteTx > 0, "maxWriteTx must be positive")
  val tlul_p = p_tl
  val io     = IO(new Bundle {
    val tl_a = Flipped(Decoupled(new TileLink_A_ChannelBase(tlul_p, userAGen))) // TileLink Input
    val tl_d = Decoupled(new TileLink_D_ChannelBase(tlul_p, userDGen))          // TileLink Output
    val axi  = new AxiMasterIO(axiAddrBits, axiDataBits, axiIdBits)
  })

  // --- AXI ID Mapper and Transaction Limiter ---
  val axiIdWidth      = axiIdBits
  val idWidthMismatch = tlul_p.o > axiIdWidth

  val p_tl_remapped = new TLULParameters(
    dataBits = p_tl.w * 8,
    addrBits = p_tl.a,
    idBits = axiIdWidth
  )

  val tl_a_q = Module(new Queue(chiselTypeOf(io.tl_a.bits), 2))
  tl_a_q.io.enq <> io.tl_a

  val tl_a_q_remapped = Wire(Decoupled(new TileLink_A_ChannelBase(p_tl_remapped, userAGen)))

  val d_channel_arb = Module(
    new CoralNPURRArbiter(new TileLink_D_ChannelBase(p_tl_remapped, userDGen), 2)
  )

  var id_remapper: TlulIdRemapper[A_USER, D_USER] = null
  if (idWidthMismatch) {
    id_remapper = Module(new TlulIdRemapper(tlul_p, p_tl_remapped, userAGen, userDGen))
    id_remapper.io.tl_a_in <> tl_a_q.io.deq
    tl_a_q_remapped <> id_remapper.io.tl_a_out
    id_remapper.io.tl_d_in <> d_channel_arb.io.out
    io.tl_d <> id_remapper.io.tl_d_out
  } else {
    tl_a_q_remapped <> tl_a_q.io.deq
    io.tl_d <> Queue(d_channel_arb.io.out, 2)
  }

  class TxInfo extends Bundle {
    val size = UInt(p_tl_remapped.z.W)
  }
  val read_tx_info_q  = Module(new Queue(new TxInfo, entries = maxReadTx))
  val write_tx_info_q = Module(new Queue(new TxInfo, entries = maxWriteTx))

  // --- Queue for incoming TileLink A-Channel requests ---
  val is_get = tl_a_q_remapped.bits.opcode === TLULOpcodesA.Get.asUInt
  val is_put = tl_a_q_remapped.bits.opcode === TLULOpcodesA.PutFullData.asUInt ||
    tl_a_q_remapped.bits.opcode === TLULOpcodesA.PutPartialData.asUInt

  // --- AXI Channel Generation ---
  // TODO: Consider gating these signals (on get/put)? Especially address.
  // Drive AXI write channels for Put requests
  val aw_q = Module(
    new Queue(new AxiAddress(axiAddrBits, axiDataBits, axiIdBits), entries = 1, pipe = true)
  )
  val w_q = Module(
    new Queue(new AxiWriteData(axiDataBits, axiIdBits), entries = 1, pipe = true)
  )

  aw_q.io.enq.valid := tl_a_q_remapped.valid && is_put && w_q.io.enq.ready && write_tx_info_q.io.enq.ready
  aw_q.io.enq.bits.addr   := tl_a_q_remapped.bits.address
  aw_q.io.enq.bits.id     := tl_a_q_remapped.bits.source
  aw_q.io.enq.bits.len    := 0.U
  aw_q.io.enq.bits.size   := tl_a_q_remapped.bits.size
  aw_q.io.enq.bits.burst  := AxiBurstType.INCR.asUInt
  aw_q.io.enq.bits.prot   := 0.U
  aw_q.io.enq.bits.lock   := 0.U
  aw_q.io.enq.bits.cache  := 0.U
  aw_q.io.enq.bits.qos    := 0.U
  aw_q.io.enq.bits.region := 0.U

  w_q.io.enq.valid := tl_a_q_remapped.valid && is_put && aw_q.io.enq.ready && write_tx_info_q.io.enq.ready
  w_q.io.enq.bits.data := tl_a_q_remapped.bits.data
  w_q.io.enq.bits.strb := tl_a_q_remapped.bits.mask
  w_q.io.enq.bits.last := true.B

  io.axi.write.addr <> aw_q.io.deq
  io.axi.write.data <> w_q.io.deq

  // Drive AXI read channel for Get requests
  io.axi.read.addr.valid      := tl_a_q_remapped.valid && is_get && read_tx_info_q.io.enq.ready
  io.axi.read.addr.bits.addr  := tl_a_q_remapped.bits.address
  io.axi.read.addr.bits.id    := tl_a_q_remapped.bits.source
  io.axi.read.addr.bits.len   := 0.U                      // No bursting
  io.axi.read.addr.bits.size  := tl_a_q_remapped.bits.size
  io.axi.read.addr.bits.burst := AxiBurstType.INCR.asUInt // Doesn't matter
  io.axi.read.addr.bits.prot  := 0.U                      // Default protection

  // Dequeue from TileLink queue when AXI transaction is accepted
  val get_ready = io.axi.read.addr.ready && read_tx_info_q.io.enq.ready
  val put_ready = aw_q.io.enq.ready && w_q.io.enq.ready && write_tx_info_q.io.enq.ready
  tl_a_q_remapped.ready := (is_get && get_ready) || (is_put && put_ready)

  io.axi.write.addr.bits.lock   := 0.U
  io.axi.write.addr.bits.cache  := 0.U
  io.axi.write.addr.bits.qos    := 0.U
  io.axi.write.addr.bits.region := 0.U
  io.axi.read.addr.bits.lock    := 0.U
  io.axi.read.addr.bits.cache   := 0.U
  io.axi.read.addr.bits.qos     := 0.U
  io.axi.read.addr.bits.region  := 0.U

  // --- Response Path ---

  read_tx_info_q.io.enq.valid     := tl_a_q_remapped.valid && is_get && io.axi.read.addr.ready
  read_tx_info_q.io.enq.bits.size := Mux((axiDataBits == 256).B, 5.U, tl_a_q_remapped.bits.size)

  write_tx_info_q.io.enq.valid := tl_a_q_remapped.valid && is_put && aw_q.io.enq.ready && w_q.io.enq.ready
  write_tx_info_q.io.enq.bits.size := Mux((axiDataBits == 256).B, 5.U, tl_a_q_remapped.bits.size)

  // --- TileLink D-Channel (Response) Generation ---
  val read_response  = Wire(Decoupled(new TileLink_D_ChannelBase(p_tl_remapped, userDGen)))
  val write_response = Wire(Decoupled(new TileLink_D_ChannelBase(p_tl_remapped, userDGen)))

  // AXI Read Response -> TileLink AccessAckData
  read_response.bits.opcode := TLULOpcodesD.AccessAckData.asUInt
  read_response.bits.param  := 0.U
  read_response.bits.size   := read_tx_info_q.io.deq.bits.size
  read_response.bits.source := io.axi.read.data.bits.id.asUInt
  read_response.bits.sink   := 0.U
  read_response.bits.data   := io.axi.read.data.bits.data
  read_response.bits.error  := io.axi.read.data.bits.resp =/= 0.U
  read_response.bits.user   := 0.U.asTypeOf(read_response.bits.user)
  read_response.valid       := io.axi.read.data.valid && read_tx_info_q.io.deq.valid

  // AXI Write Response -> TileLink AccessAck
  write_response.bits.opcode := TLULOpcodesD.AccessAck.asUInt
  write_response.bits.param  := 0.U
  write_response.bits.size   := write_tx_info_q.io.deq.bits.size
  write_response.bits.source := io.axi.write.resp.bits.id.asUInt
  write_response.bits.sink   := 0.U
  write_response.bits.data   := 0.U
  write_response.bits.error  := io.axi.write.resp.bits.resp =/= 0.U
  write_response.bits.user   := 0.U.asTypeOf(write_response.bits.user)
  write_response.valid       := io.axi.write.resp.valid && write_tx_info_q.io.deq.valid

  d_channel_arb.io.in(0) <> read_response
  d_channel_arb.io.in(1) <> write_response

  // Drive ready signals
  io.axi.read.data.ready      := d_channel_arb.io.in(0).ready
  read_tx_info_q.io.deq.ready := io.axi.read.data.valid && d_channel_arb.io.in(0).ready

  io.axi.write.resp.ready      := d_channel_arb.io.in(1).ready
  write_tx_info_q.io.deq.ready := d_channel_arb.io.in(1).ready && io.axi.write.resp.valid

}

import common.ChiselEmitter

object EmitTLUL2Axi extends App {
  val tlul_p = new TLULParameters(dataBits = 256, addrBits = 32, idBits = 6)
  ChiselEmitter.emit(
    new TLUL2Axi(
      tlul_p,
      256,
      32,
      6,
      () => new OpenTitanTileLink_A_User,
      () => new OpenTitanTileLink_D_User
    ),
    args
  )
}
