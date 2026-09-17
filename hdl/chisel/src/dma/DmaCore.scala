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

import bus._

import chisel3._
import chisel3.util._

class DmaCore(p: TLULParameters) extends Module {
  val M     = 2           // fill, drain
  val StIdW = log2Ceil(M) // = 1
  val p_d   = p.augmentId(StIdW)

  val io = IO(new Bundle {
    val tl_device = Flipped(new TLULHost2Device[NoUser, NoUser](p))
    val tl_host   = new TLULHost2Device[NoUser, NoUser](p_d)
    val busy      = Output(Bool())
    val error     = Output(Bool())
  })

  val buffer = Module(new TransposeBuffer(p))
  val fill   = Module(new DmaFillEngine(p))
  val drain  = Module(new DmaDrainEngine(p))
  val csr    = Module(new DmaCsr(p))
  val arb    = Module(new TlulArbiter(p, M))

  csr.io.tl <> io.tl_device
  csr.io.desc <> fill.io.descriptor
  fill.io.cfg <> buffer.io.cfg
  fill.io.beat <> buffer.io.in
  fill.io.drainDesc <> drain.io.descriptor
  buffer.io.out <> drain.io.beat

  arb.io.tl_h(0) <> fill.io.tl
  arb.io.tl_h(1) <> drain.io.tl
  io.tl_host <> arb.io.tl_d

  csr.io.fillBusy    := fill.io.busy
  csr.io.drainBusy   := drain.io.busy
  csr.io.engineError := fill.io.error || drain.io.error

  io.busy  := csr.io.busy
  io.error := csr.io.error || fill.io.error || drain.io.error

  // Intentionally unconnected: the descriptor handoff replaced fillDone, and
  // fill.io.cfg.ready subsumes drainDone. They are the hooks a ping-pong
  // arbiter would use.
  buffer.io.fillDone  := DontCare
  buffer.io.drainDone := DontCare

  // Index is arbitrary while one buffer serialises fill and drain; it becomes a
  // real decision at ping-pong.
}

import scala.annotation.nowarn
import _root_.circt.stage.{ChiselStage, FirtoolOption}
import chisel3.stage.ChiselGeneratorAnnotation

@nowarn
object DmaCoreEmitter extends App {
  val tlul_p = new TLULParameters(dataBits = 256, addrBits = 32, idBits = 6)
  (new ChiselStage).execute(
    Array("--target", "systemverilog") ++ args,
    Seq(ChiselGeneratorAnnotation(() => new DmaCore(tlul_p))) ++
      Seq(FirtoolOption("-enable-layers=Verification"))
  )
}
