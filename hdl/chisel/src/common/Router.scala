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

package common

import chisel3._
import chisel3.util._

class Router[T <: Data](gen: T, n: Int, route: T => Seq[Bool]) extends Module {
  val io = IO(new Bundle {
    val in  = Flipped(Decoupled(gen))
    val out = Vec(n, Decoupled(gen))
  })

  // 1. Evaluate the routing function to get our one-hot selection vector
  val sel = route(io.in.bits)
  assert(PopCount(sel) === 1.U)

  for (i <- 0 until n) {
    // 2. Broadcast the payload to all outputs
    io.out(i).bits := io.in.bits

    // 3. Gate the valid signal so only the selected output sees the request
    io.out(i).valid := io.in.valid && sel(i)
  }

  // 4. Mux the ready signal from the selected output back to the input
  io.in.ready := Mux1H(sel, io.out.map(_.ready))
}

object Router {
  def apply[T <: Data](in: DecoupledIO[T], route: T => Seq[Bool]): Vec[DecoupledIO[T]] = {
    val sel    = route(in.bits)
    val n      = sel.length
    val router = Module(new Router(chiselTypeOf(in.bits), n, route))
    router.io.in <> in
    router.io.out
  }
}
