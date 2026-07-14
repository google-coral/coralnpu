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

class TlulArbiter(
  p: TLULParameters,
  M: Int
) extends Module {
  val StIdW = log2Ceil(M)
  val p_d   = p.augmentId(StIdW)

  val io = IO(new Bundle {
    val tl_h = Flipped(Vec(M, new TLULHost2Device[NoUser, NoUser](p)))
    val tl_d = new TLULHost2Device[NoUser, NoUser](p_d)
  })

  // 1. A-Channel Arbitration
  // Use our custom generic Arbiter to select one of the M host requests
  val a_arb = Module(new Arbiter(new TileLink_A_Channel(p), M))

  for (i <- 0 until M) {
    a_arb.io.in(i) <> io.tl_h(i).a
  }

  // Connect the chosen request to the device port
  io.tl_d.a.valid    := a_arb.io.out.valid
  a_arb.io.out.ready := io.tl_d.a.ready

  // Extend the source ID with the index of the chosen host
  io.tl_d.a.bits := a_arb.io.out.bits.extendSource(a_arb.io.chosen)

  // 2. D-Channel Response Routing
  // Route D-channel based on the host index encoded in the source ID LSBs
  val routeD = (d: TileLink_D_Channel) => {
    val host_index = d.source(StIdW - 1, 0)
    (0 until M).map { i => host_index === i.U }
  }

  // Instantiate generic Router with M outputs
  val d_router = Module(new Router(new TileLink_D_Channel(p_d), M, routeD))

  d_router.io.in <> io.tl_d.d

  // Connect router outputs back to hosts, shrinking the source ID
  for (i <- 0 until M) {
    io.tl_h(i).d.valid       := d_router.io.out(i).valid
    d_router.io.out(i).ready := io.tl_h(i).d.ready
    io.tl_h(i).d.bits        := d_router.io.out(i).bits.shrinkSource(StIdW)
  }
}
