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
import _root_.circt.stage.{ChiselStage, FirtoolOption}
import chisel3.stage.ChiselGeneratorAnnotation
import scala.annotation.nowarn

class TlulLocalXbar(
  p: TLULParameters,
  numHosts: Int,
  numBanks: Int,
  routeFn: TileLink_A_Channel => Seq[Bool],
  moduleName: String = "TlulLocalXbar"
) extends Module {
  override val desiredName = moduleName

  val StIdW = log2Ceil(numHosts)
  val p_d   = p.augmentId(StIdW)

  val io = IO(new Bundle {
    val tl_h = Flipped(Vec(numHosts, new TLULHost2Device[NoUser, NoUser](p)))
    val tl_d = Vec(numBanks, new TLULHost2Device[NoUser, NoUser](p_d))
  })

  // 1. Instantiate Routers for each host
  val routers = (0 until numHosts).map { i =>
    val router = Module(new TlulRouter(p, numBanks, routeFn))
    router.io.tl_h <> io.tl_h(i)
    router
  }

  // 2. Instantiate Arbiters for each bank and connect
  val arbiters = Seq.fill(numBanks)(Module(new TlulArbiter(p, numHosts)))

  for (j <- 0 until numBanks) {
    io.tl_d(j) <> arbiters(j).io.tl_d

    for (i <- 0 until numHosts) {
      arbiters(j).io.tl_h(i) <> routers(i).io.tl_d(j)
    }
  }
}

@nowarn
object TlulLocalXbarEmitter extends App {
  val tlul_p   = new TLULParameters(dataBits = 128, addrBits = 32, idBits = 6)
  val bankSize = 4096
  val numBanks = 8
  val baseAddr = 0x10000
  val dtcmSize = bankSize * numBanks

  val routeFn = (a: TileLink_A_Channel) => {
    val addr     = a.address
    val in_range = (addr >= baseAddr.U) && (addr < (baseAddr + dtcmSize).U)
    val offset   = addr - baseAddr.U
    val bank_sel = offset(log2Ceil(dtcmSize) - 1, log2Ceil(bankSize))

    val sel       = (0 until numBanks).map { j => in_range && (bank_sel === j.U) }
    val error_sel = !in_range
    sel ++ Seq(error_sel)
  }

  (new ChiselStage).execute(
    Array("--target", "systemverilog") ++ args,
    Seq(
      ChiselGeneratorAnnotation(() =>
        new TlulLocalXbar(
          p = tlul_p,
          numHosts = 3,
          numBanks = numBanks,
          routeFn = routeFn,
          moduleName = "TlulLocalXbar"
        )
      )
    ) ++ Seq(FirtoolOption("-enable-layers=Verification"))
  )
}
