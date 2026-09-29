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

/** AxiAddressGenerator: An implementation of AxiAddressGenerator that uses Chisel's Arbiter and
  * Queue to manage burst state, optimized for zero-bubble transitions.
  */
class AxiAddressGeneratorBeat(addrWidthBits: Int, dataWidthBits: Int, idBits: Int) extends Bundle {
  val addr     = new AxiAddress(addrWidthBits, dataWidthBits, idBits)
  val wrapMask = UInt(addrWidthBits.W)
}

class AxiAddressGenerator(addrWidthBits: Int, dataWidthBits: Int, idBits: Int) extends Module {
  val io = IO(new Bundle {
    // Input from AXI Address Channel
    val in = Flipped(Decoupled(new AxiAddress(addrWidthBits, dataWidthBits, idBits)))
    // Output of generated single-beat addresses
    val out = Decoupled(new AxiAddress(addrWidthBits, dataWidthBits, idBits))
  })
  // Queue to store the next pending beats
  val queue = Module(
    new Queue(
      new AxiAddressGeneratorBeat(addrWidthBits, dataWidthBits, idBits),
      entries = 1,
      pipe = true
    )
  )

  // Arbiter to select between pending beats (queue) and new requests (in)
  // Input 0 (highest priority) is the queue.
  // Input 1 is the new request.
  val arb = Module(
    new Arbiter(new AxiAddressGeneratorBeat(addrWidthBits, dataWidthBits, idBits), 2)
  )

  val inBeat = Wire(new AxiAddressGeneratorBeat(addrWidthBits, dataWidthBits, idBits))
  inBeat.addr := io.in.bits

  val numBytes = 1.U << io.in.bits.size
  inBeat.wrapMask := Mux(
    io.in.bits.burst === AxiBurstType.WRAP.asUInt,
    ((io.in.bits.len << io.in.bits.size) | (numBytes - 1.U)).pad(addrWidthBits),
    0.U(addrWidthBits.W)
  )

  // Connect Queue to Arbiter Input 0
  arb.io.in(0) <> queue.io.deq

  // Connect io.in to Arbiter Input 1
  arb.io.in(1).valid := io.in.valid
  arb.io.in(1).bits  := inBeat
  io.in.ready        := arb.io.in(1).ready

  queue.io.enq.valid         := arb.io.out.fire && (arb.io.out.bits.addr.len =/= 0.U)
  queue.io.enq.bits.addr     := arb.io.out.bits.addr.nextAddr(arb.io.out.bits.wrapMask)
  queue.io.enq.bits.wrapMask := arb.io.out.bits.wrapMask

  io.out.valid     := arb.io.out.valid
  io.out.bits      := arb.io.out.bits.addr
  arb.io.out.ready := io.out.ready
}

import common.ChiselEmitter

object EmitAxiAddressGenerator extends App {
  ChiselEmitter.emit(
    new AxiAddressGenerator(addrWidthBits = 32, dataWidthBits = 256, idBits = 6),
    args
  )
}
