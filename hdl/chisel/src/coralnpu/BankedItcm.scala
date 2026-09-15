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

package coralnpu

import chisel3._
import chisel3.util._
import bus._
import coralnpu.soc.RawTlulSram
import common.{ChiselEmitter, ChiselEmitterOptions}

class BankedItcm(
  p: TLULParameters,
  numBanks: Int = 2,
  numHosts: Int = 3,
  bankSizeBytes: Int,
  bankBaseAddresses: Seq[Int],
  routeFn: TileLink_A_Channel => Seq[Bool]
) extends Module {

  val io = IO(new Bundle {
    val tl_h = Vec(numHosts, Flipped(new TLULHost2Device[NoUser, NoUser](p)))
  })

  // Instantiate banks with the augmented parameters
  val extraIdBits = log2Ceil(numHosts)
  val bankParams  = p.augmentId(extraIdBits)
  val banks       = (0 until numBanks).map { i =>
    Module(new RawTlulSram(bankParams, bankSizeBytes, bankBaseAddresses(i)))
  }

  // Instantiate crossbar internally
  val xbar = Module(new TlulLocalXbar(p, numHosts, numBanks, routeFn))

  // Connect IO to crossbar
  xbar.io.tl_h <> io.tl_h

  // Connect crossbar to banks
  for (i <- 0 until numBanks) {
    banks(i).io.tl <> xbar.io.tl_d(i)
  }
}

object BankedItcmEmitter extends App {
  val p = new Parameters
  p.m = MemoryRegions.default

  var numBanks   = 2
  var numHosts   = 3
  var moduleName = "BankedItcm"

  // Simple arg parser
  var chiselArgs = Array[String]()
  for (arg <- args) {
    if (arg.startsWith("--numBanks=")) {
      numBanks = arg.split("=")(1).toInt
    } else if (arg.startsWith("--numHosts=")) {
      numHosts = arg.split("=")(1).toInt
    } else if (arg.startsWith("--lsuDataBits=")) {
      p.lsuDataBits = arg.split("=")(1).toInt
    } else if (arg.startsWith("--fetchDataBits=")) {
      p.fetchDataBits = arg.split("=")(1).toInt
      // Keep lsuDataBits in sync because toTLUL uses axi2DataBits (alias for lsuDataBits)
      p.lsuDataBits = arg.split("=")(1).toInt
    } else if (arg.startsWith("--moduleName=")) {
      moduleName = arg.split("=")(1)
    } else {
      chiselArgs = chiselArgs :+ arg
    }
  }

  val imemRegion    = p.m.find(_.memType == MemoryRegionType.IMEM).get
  val itcmBase      = imemRegion.memStart
  val itcmSize      = imemRegion.memSize
  val bankSizeBytes = itcmSize / numBanks

  val routeFn = (a: TileLink_A_Channel) => {
    val addr     = a.address
    val in_range = (addr >= itcmBase.U) && (addr < (itcmBase + itcmSize).U)
    val offset   = addr - itcmBase.U
    val bank_sel = offset(log2Ceil(itcmSize) - 1, log2Ceil(bankSizeBytes))

    val sel       = (0 until numBanks).map { j => in_range && (bank_sel === j.U) }
    val error_sel = !in_range
    sel ++ Seq(error_sel)
  }

  val bankBaseAddresses = (0 until numBanks).map { i => itcmBase + i * bankSizeBytes }

  ChiselEmitter.emit(
    new BankedItcm(
      p = p.toTLUL(),
      numBanks = numBanks,
      numHosts = numHosts,
      bankSizeBytes = bankSizeBytes,
      bankBaseAddresses = bankBaseAddresses,
      routeFn = routeFn
    ),
    chiselArgs,
    ChiselEmitterOptions(moduleName = Some(moduleName))
  )
}
