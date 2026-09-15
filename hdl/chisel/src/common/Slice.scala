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

object Slice {
  def apply[T <: Data](
    t: T,
    doubleBuffered: Boolean = true,
    passReady: Boolean = false,
    passValid: Boolean = false
  ) = {
    Module(new Slice(t, doubleBuffered, passReady, passValid))
  }
}

class Slice[T <: Data](t: T, doubleBuffered: Boolean, passReady: Boolean, passValid: Boolean)
    extends Module {
  val io = IO(new Bundle {
    val in    = Flipped(Decoupled(t))
    val out   = Decoupled(t)
    val count = Output(UInt(2.W))
    val value = Output(Vec(if (doubleBuffered) 2 else 1, Valid(t)))
  })

  val size = if (doubleBuffered) 2 else 1

  val ipos  = RegInit(0.U(size.W))
  val opos  = RegInit(0.U(size.W))
  val count = RegInit(0.U(size.W))
  val mem   = RegInit(VecInit(Seq.fill(size)(0.U(t.getWidth.W).asTypeOf(t))))

  val empty  = ipos === opos
  val bypass = if (passValid) io.in.valid && io.out.ready && empty else false.B
  val ivalid = io.in.valid && io.in.ready && !bypass
  val ovalid = io.out.valid && io.out.ready && !bypass

  when(ivalid) {
    ipos := ipos + 1.U
  }

  when(ovalid) {
    opos := opos + 1.U
  }

  when(ivalid =/= ovalid) {
    count := count + ivalid - ovalid
  }

  if (doubleBuffered) {
    val full = ipos(0) === opos(0) && ipos(1) =/= opos(1)
    if (passReady) {
      io.in.ready := !full || io.out.ready // pass-through
    } else {
      io.in.ready := !full
    }

    when(ovalid && full) {
      mem(0) := mem(1)
    }.elsewhen(
      ivalid && !ovalid && empty ||
        ivalid && ovalid && !full
    ) {
      mem(0) := io.in.bits
    }.otherwise {
      mem(0) := mem(0)
    }

    when(
      ivalid && !ovalid && !empty ||
        ivalid && ovalid && full
    ) {
      mem(1) := io.in.bits
    }

    io.value(0).valid := !empty
    io.value(1).valid := full
    io.value(0).bits  := mem(0)
    io.value(1).bits  := mem(1)
  } else {
    if (passReady) {
      io.in.ready := empty || io.out.ready // pass-through
    } else {
      io.in.ready := empty
    }

    when(ivalid) {
      mem(0) := io.in.bits
    }.otherwise {
      mem(0) := mem(0)
    }

    io.value(0).valid := !empty
    io.value(0).bits  := mem(0)
  }

  if (!passValid) {
    io.out.valid := !empty
    io.out.bits  := mem(0)
  } else {
    io.out.valid := !empty || io.in.valid           // pass-through
    io.out.bits  := Mux(!empty, mem(0), io.in.bits) // pass-through
  }

  io.count := count
}

object EmitSlice extends App {
  ChiselEmitter.emit(new Slice(UInt(32.W), false, false, false), args)
}

object EmitSlice_1 extends App {
  ChiselEmitter.emit(new Slice(UInt(32.W), false, false, true), args)
}

object EmitSlice_2 extends App {
  ChiselEmitter.emit(new Slice(UInt(32.W), false, true, false), args)
}

object EmitSlice_3 extends App {
  ChiselEmitter.emit(new Slice(UInt(32.W), false, true, true), args)
}

object EmitSlice_4 extends App {
  ChiselEmitter.emit(new Slice(UInt(32.W), true, false, false), args)
}

object EmitSlice_5 extends App {
  ChiselEmitter.emit(new Slice(UInt(32.W), true, false, true), args)
}

object EmitSlice_6 extends App {
  ChiselEmitter.emit(new Slice(UInt(32.W), true, true, false), args)
}

object EmitSlice_7 extends App {
  ChiselEmitter.emit(new Slice(UInt(32.W), true, true, true), args)
}
