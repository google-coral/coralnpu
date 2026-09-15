// Copyright 2023 Google LLC
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

object Fifo {
  def apply[T <: Data](t: T, n: Int, passReady: Boolean = false) = {
    Module(new Fifo(t, n, passReady))
  }
}

class Fifo[T <: Data](t: T, n: Int, passReady: Boolean) extends Module {
  val io = IO(new Bundle {
    val in    = Flipped(Decoupled(t))
    val out   = Decoupled(t)
    val count = Output(UInt(log2Ceil(n + 1).W))
  })

  // An (n-1) queue with a registered output stage.
  val m = n - 1 // n = Mem(n-1) + Out

  val mem   = RegInit(VecInit(Seq.fill(n)(0.U(t.getWidth.W).asTypeOf(t))))
  val rdata = Reg(t)

  val rvalid = RegInit(false.B)
  val wready = RegInit(false.B)
  val raddr  = RegInit(0.U(log2Ceil(m).W))
  val waddr  = RegInit(0.U(log2Ceil(m).W))
  val count  = RegInit(0.U(log2Ceil(n + 1).W))

  // ---------------------------------------------------------------------------
  // Memory Addresses.
  val winc = io.in.valid && io.in.ready
  val rinc = (!rvalid || io.out.ready) && (winc || count > 1.U)

  when(winc) {
    waddr := Mux(waddr === (m - 1).U, 0.U, waddr + 1.U)
  }

  when(rinc) {
    raddr := Mux(raddr === (m - 1).U, 0.U, raddr + 1.U)
  }

  val forward = rinc && winc && count <= 1.U

  // ---------------------------------------------------------------------------
  // FIFO Control.
  val ien = io.in.valid && io.in.ready
  val oen = io.out.valid && io.out.ready

  when(ien && !oen) {
    count := count + 1.U
  }.elsewhen(!ien && oen) {
    count := count - 1.U
  }

  when(ien) {
    rvalid := true.B
  }.elsewhen(io.out.ready && count === 1.U) {
    rvalid := false.B
  }

  wready := count < (n - 1).U ||
    count === (n - 1).U && !(ien && !oen) ||
    (oen && !ien)

  // ---------------------------------------------------------------------------
  // Memory.
  when(winc && !forward) {
    mem(waddr) := io.in.bits
  }

  when(forward) {
    rdata := io.in.bits
  }.elsewhen(rinc) {
    rdata := mem(raddr)
  }

  // ---------------------------------------------------------------------------
  // Interface.
  io.out.valid := rvalid
  io.out.bits  := rdata

  if (passReady) {
    io.in.ready := wready || io.out.ready // pass-through
  } else {
    io.in.ready := wready
  }

  io.count := count

  assert(count <= n.U)
  assert(!(!passReady.B && io.in.ready && count === n.U))
}

object EmitFifo extends App {
  ChiselEmitter.emit(new Fifo(UInt(8.W), 11, false), args)
}

object EmitFifo_1 extends App {
  ChiselEmitter.emit(new Fifo(UInt(8.W), 11, true), args)
}
