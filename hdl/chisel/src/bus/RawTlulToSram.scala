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

class RawTlulToSram(p: TLULParameters, sramAddressWidth: Int) extends Module {
  val tlul_p = p
  val io     = IO(new Bundle {
    val tl   = Flipped(new TLULHost2Device[NoUser, NoUser](tlul_p))
    val sram = Flipped(new Sram128IO(sramAddressWidth))
  })

  // Output Skid Buffer (1-entry queue with flow-through)
  val d_q = Module(new Queue(chiselTypeOf(io.tl.d.bits), entries = 1, flow = true, pipe = true))

  io.tl.d <> d_q.io.deq

  val metadata_bits = Wire(new Bundle {
    val source = UInt(tlul_p.o.W)
    val size   = UInt(tlul_p.z.W)
    val opcode = UInt(3.W)
  })
  metadata_bits.source := io.tl.a.bits.source
  metadata_bits.size   := io.tl.a.bits.size
  metadata_bits.opcode := io.tl.a.bits.opcode

  // Pipe delays the metadata by 1 cycle, driven by io.tl.a.fire
  val metadata_pipe = Pipe(io.tl.a.fire, metadata_bits, latency = 1)

  // Input handshake logic:
  val a_ready =
    d_q.io.deq.fire || (!metadata_pipe.valid && (d_q.io.count === 0.U)) // simplified with k-map
  // We accept request if Skid Buffer has space AND (no request is in flight OR host is ready to accept D response)
  // This prevents in-flight requests from overflowing the Skid Buffer if the host stalls.
  // similar to: d_q.io.enq.ready && (!metadata_pipe.valid || io.tl.d.ready)
  io.tl.a.ready := a_ready
  val can_issue = io.tl.a.valid && a_ready

  io.sram.enable := can_issue
  io.sram.write := io.tl.a.bits.opcode === TLULOpcodesA.PutFullData.asUInt || io.tl.a.bits.opcode === TLULOpcodesA.PutPartialData.asUInt
  // SRAM is word-addressed (128-bit / 16-byte words)
  io.sram.addr  := io.tl.a.bits.address >> log2Ceil(tlul_p.w)
  io.sram.wdata := io.tl.a.bits.data
  io.sram.wmask := io.tl.a.bits.mask

  // Assertion: if pipe is outputting data, d_q.io.enq must be ready
  assert(
    !metadata_pipe.valid || d_q.io.enq.ready,
    "Metadata pipe output valid but d_q is not ready"
  )

  // D channel response formulation
  val is_read = metadata_pipe.bits.opcode === TLULOpcodesA.Get.asUInt

  // For registered memory, we expect rvalid to be asserted 1 cycle after enable.
  d_q.io.enq.valid       := metadata_pipe.valid && io.sram.rvalid
  d_q.io.enq.bits        := 0.U.asTypeOf(d_q.io.enq.bits)
  d_q.io.enq.bits.opcode := Mux(
    is_read,
    TLULOpcodesD.AccessAckData.asUInt,
    TLULOpcodesD.AccessAck.asUInt
  )
  d_q.io.enq.bits.source := metadata_pipe.bits.source
  d_q.io.enq.bits.size   := metadata_pipe.bits.size
  d_q.io.enq.bits.data   := io.sram.rdata
  d_q.io.enq.bits.error  := false.B
  d_q.io.enq.bits.user   := 0.U.asTypeOf(d_q.io.enq.bits.user)
}
