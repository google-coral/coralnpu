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

package dma

import chisel3._
import chisel3.util._

class BypassWrite[T <: Data](t: T, tagWidth: Int) extends Bundle {
  val tag  = UInt(tagWidth.W)
  val data = t
}

class DmaBypassBuffer[T <: Data](t: T, depth: Int) extends Module {
  require(depth >= 2 && isPow2(depth), "depth must be a power of two, at least 2")
  val tagWidth = log2Ceil(depth)

  val io = IO(new Bundle {
    val alloc = Decoupled(UInt(tagWidth.W))
    val write = Flipped(Valid(new BypassWrite(t, tagWidth)))
    val out   = Decoupled(t)
    // Abort path: frees every slot and resets the pointers. Legal only when no
    // Get response is outstanding.
    val clear = Input(Bool())
    val empty = Output(Bool())
  })

  val data  = Reg(Vec(depth, t))
  val full  = RegInit(0.U(depth.W))
  val head  = RegInit(0.U(tagWidth.W))
  val tail  = RegInit(0.U(tagWidth.W))
  val count = RegInit(0.U((tagWidth + 1).W))

  // A slot is in use when its distance from head is below count.
  val inUse        = VecInit.tabulate(depth)(i => (i.U(tagWidth.W) - head) < count)
  val awaitingData = inUse.asUInt & ~full

  val writeMask = Mux(io.write.valid, UIntToOH(io.write.bits.tag, depth), 0.U(depth.W))
  val popMask   = Mux(io.out.fire, UIntToOH(head, depth), 0.U(depth.W))

  full  := Mux(io.clear, 0.U, (full | writeMask) & ~popMask)
  data  := VecInit.tabulate(depth)(i => Mux(writeMask(i), io.write.bits.data, data(i)))
  head  := Mux(io.clear, 0.U, Mux(io.out.fire, head + 1.U, head))
  tail  := Mux(io.clear, 0.U, Mux(io.alloc.fire, tail + 1.U, tail))
  count := Mux(io.clear, 0.U, count + io.alloc.fire.asUInt - io.out.fire.asUInt)

  io.alloc.valid := !io.clear && (count =/= depth.U)
  io.alloc.bits  := tail
  io.out.valid   := !io.clear && full(head)
  io.out.bits    := data(head)
  io.empty       := count === 0.U

  assert(
    !io.write.valid || inUse(io.write.bits.tag),
    "Bypass buffer write to a slot that is not in use"
  )
  assert(
    !io.write.valid || !full(io.write.bits.tag),
    "Bypass buffer write to a slot that is already full"
  )
  assert(!io.clear || (awaitingData === 0.U), "Bypass buffer clear with a Get response outstanding")
  assert(
    !io.clear || !(io.write.valid || io.alloc.fire || io.out.fire),
    "Bypass buffer clear in the same cycle as another operation"
  )
}

import common.ChiselEmitter

object DmaBypassBufferEmitter extends App {
  ChiselEmitter.emit(new DmaBypassBuffer(UInt(128.W), 16), args)
}
