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

package common

import chisel3._
import chisel3.util._

class FIFOState[T <: Data](val size: Int, gen: T) extends Bundle {

  // State of our FIFO object
  val head   = UInt(log2Ceil(size).W)
  val tail   = UInt(log2Ceil(size).W)
  val count  = UInt(BitWidthForInt(size))
  val buffer = Vec(size, gen)

  // Helper methods

  def wraparoundSum(x: UInt, y: UInt): UInt = {
    // Optimization for powers of two
    if (isPow2(size)) {
      x + y
    } else {
      val sum = x +& y
      Mux(sum >= size.U, sum - size.U, sum)
    }
  }

  // Action methods

  // Enqueue new data. Returns a NEW FIFOState with updated buffer, head, and count.
  def enqueue(data: Vec[T], validCount: UInt): FIFOState[T] = {
    assert(validCount <= free(), "Enqueue overflow: validCount > free")
    assert(validCount <= data.length.U, "Valid count exceeds data size")
    assert(data.length.U <= size.U, "Data size exceeds buffer size")

    val nextBuffer = Wire(Vec(size, gen))

    // We want to write data[0]...data[validCount-1] to buffer[head]...buffer[head+validCount-1] (wrapping)

    for (idx <- 0 until size) {
      // Calculate the wrapped distance from the head to the current index.
      // If distance is less than validCount, the current index is a target for writing.
      val distanceFromHead = if (isPow2(size)) {
        idx.U(log2Ceil(size).W) - head
      } else {
        Mux(idx.U >= head, idx.U - head, idx.U +& size.U - head)
      }
      val shouldWriteAtIndex =
        distanceFromHead < validCount // if greater, distance is farther from head than validCount (inline or wrapped around)

      nextBuffer(idx) := Mux(shouldWriteAtIndex, data(distanceFromHead), buffer(idx))
    }

    val result = Wire(new FIFOState(size, gen))
    result.head   := wraparoundSum(head, validCount)
    result.tail   := tail
    result.count  := count + validCount
    result.buffer := nextBuffer
    result
  }

  // Dequeue data. Returns a NEW FIFOState with updated tail and count. Buffer is unchanged.
  def dequeue(readyCount: UInt): FIFOState[T] = {
    assert(readyCount <= count, "Dequeue underflow: readyCount > count")

    val result = Wire(new FIFOState(size, gen))
    result.head   := head
    result.tail   := wraparoundSum(tail, readyCount)
    result.count  := count - readyCount
    result.buffer := buffer
    result
  }

  // Flush data. Returns a NEW FIFOState with zero count and head = tail. Buffer is unchanged.
  def flush(): FIFOState[T] = {
    val result = Wire(new FIFOState(size, gen))
    result.head   := tail
    result.tail   := tail
    result.count  := 0.U
    result.buffer := buffer
    result
  }

  // "query" methods (do no modify state)
  // This function adds potentially unnecessary logic. Only for testing. Not for synthesis.
  def invariant(): Bool = {
    (tail +& count) % size.U === head
  }

  def free(): UInt = size.U - count

  // Peek at the first n elements from the FIFO (starting at tail).
  def peek(n: Int): Vec[T] = {
    // We return a Vec of size n.
    // out[0] = buffer[tail]
    // out[1] = buffer[tail+1]
    // ...
    val out = Wire(Vec(n, gen))
    for (i <- 0 until n) {
      val idx = wraparoundSum(tail, i.U)
      out(i) := buffer(idx)
    }
    out
  }
}

object FIFOState {
  def init[T <: Data](size: Int, gen: T): FIFOState[T] = {
    0.U.asTypeOf(new FIFOState(size, gen))
  }
}
