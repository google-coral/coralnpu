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
import common.Router

class TlulRouter(
  p: TLULParameters,
  n: Int,
  route: TileLink_A_Channel => Seq[Bool]
) extends Module {
  val io = IO(new Bundle {
    val tl_h = Flipped(new TLULHost2Device[NoUser, NoUser](p))
    val tl_d = Vec(n, new TLULHost2Device[NoUser, NoUser](p))
  })

  // Instantiate generic Router with n + 1 outputs (n banks + 1 error responder)
  val router = Module(new Router(new TileLink_A_Channel(p), n + 1, route))

  router.io.in <> io.tl_h.a

  // Connect banks
  for (i <- 0 until n) {
    io.tl_d(i).a <> router.io.out(i)
  }

  // Instantiate Error Responder and connect it to output port n
  val err_resp = Module(new RawTlulErrorResponder(p))
  err_resp.io.tl_h.a <> router.io.out(n)

  // Merge responses (D-channel) from banks and error responder
  val d_arb = Module(new Arbiter(new TileLink_D_Channel(p), n + 1))

  for (i <- 0 until n) {
    d_arb.io.in(i) <> io.tl_d(i).d
  }
  d_arb.io.in(n) <> err_resp.io.tl_h.d

  io.tl_h.d <> d_arb.io.out
}
