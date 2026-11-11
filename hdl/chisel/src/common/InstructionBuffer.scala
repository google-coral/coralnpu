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

package common

import chisel3._
import chisel3.util._
import common.CircularBufferMulti

/** An interface which encapsulates up-to n DecoupledIO interfaces. The convention is that the first
  * nValid interfaces are considered valid.
  */
class DecoupledVectorIO[T <: Data](gen: T, n: Int) extends Bundle {
  val nReady = Input(UInt(log2Up(n + 1).W))
  val nValid = Output(UInt(log2Up(n + 1).W))
  val bits   = Output(Vec(n, gen))
}

object DecoupledVectorIO {
  def apply[T <: Data](gen: T, n: Int): DecoupledVectorIO[T] = new DecoupledVectorIO(gen, n)
}

// Note any instruction will be available to dequeu one full cycle follong enqueuing.
// This must be accounted for when using the instruction buffer as there is no backpressure.
class InstructionBuffer[T <: Data](val gen: T, val n: Int, val window: Int) extends Module {
  assert(window % n == 0)

  val io = IO(new Bundle {
    val feedIn = Flipped(DecoupledVectorIO(gen, n))
    val out    = Vec(n, Decoupled(gen))
    val flush  = Input(Bool())

    val nEnqueued = Output(UInt(BitWidthForInt(window)))
    val nSpace    = Output(UInt(BitWidthForInt(window)))
  })
  dontTouch(io)

  val circularBuffer = Module(new CircularBufferMulti(t = gen, n = n, capacity = window))

  // Enqueue Logic
  val feedInReady = Mux(circularBuffer.io.nSpace < n.U, circularBuffer.io.nSpace, n.U)
  io.feedIn.nReady           := feedInReady
  circularBuffer.io.enqValid := io.feedIn.nValid
  circularBuffer.io.enqData  := io.feedIn.bits

  circularBuffer.io.flush := io.flush

  // Dequeue Logic: Always make n elements visible, but only set valid the lesser n nEnqueud and n
  // Don't show data is valid if flushing
  for (nIndex <- 0 until n) {
    io.out(nIndex).valid := (nIndex.U < circularBuffer.io.nEnqueued) && !io.flush
    io.out(nIndex).bits  := circularBuffer.io.dataOut(nIndex)
  }

  // Confirm ready signals are contiguous with assert (ex only ready(0) and ready(2) set should fail)
  assert(
    OneHotInOrder(io.out.map(_.fire)),
    p"OneHotInOrder - Instructions not dispatched in order."
  )
  val nReady = PopCount(io.out.map(_.fire))
  circularBuffer.io.deqReady := nReady

  io.nEnqueued := circularBuffer.io.nEnqueued
  io.nSpace    := circularBuffer.io.nSpace
}
