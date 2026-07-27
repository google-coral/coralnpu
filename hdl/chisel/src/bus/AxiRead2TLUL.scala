// Copyright 2026 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

package bus

import chisel3._
import chisel3.util._
import common.{MakeInvalid, MakeValid}

/** AxiRead2TLUL: A Chisel module that serves as a read-only bridge between an AXI4 master and a
  * TileLink-UL slave.
  *
  * It translates AXI read transactions into TileLink Get operations. It uses AxiAddressGenerator
  * internally to unroll bursts.
  *
  * This implementation uses NoUser for TileLink user fields.
  */
class AxiRead2TLUL(p: TLULParameters) extends Module {
  val tlulP = p
  val io    = IO(new Bundle {
    val axiRead = Flipped(new AxiMasterReadIO(p.a, p.w * 8, p.o))
    val tl      = new TLULHost2Device[NoUser, NoUser](tlulP)
  })

  val addrGen = Module(new AxiAddressGenerator(p.a, p.w * 8, p.o))

  // Track active bursts to prevent out-of-order responses for the same ID.
  val activeBeats = RegInit(VecInit(Seq.fill(1 << p.o)(MakeInvalid(UInt(8.W)))))

  // Check for ID conflict at the input.
  val idConflict = activeBeats(io.axiRead.addr.bits.id).valid

  // Gated AXI Address channel to prevent ID conflicts.
  val gatedAxiAddr = Wire(Decoupled(new AxiAddress(p.a, p.w * 8, p.o)))
  gatedAxiAddr.valid    := io.axiRead.addr.valid && !idConflict
  gatedAxiAddr.bits     := io.axiRead.addr.bits
  io.axiRead.addr.ready := gatedAxiAddr.ready && !idConflict

  // Connect gated address to address generator.
  addrGen.io.in <> gatedAxiAddr

  // Map address generator output to TileLink A channel.
  io.tl.a.valid        := addrGen.io.out.valid
  io.tl.a.bits.opcode  := TLULOpcodesA.Get.asUInt
  io.tl.a.bits.param   := 0.U
  io.tl.a.bits.size    := addrGen.io.out.bits.size
  io.tl.a.bits.source  := addrGen.io.out.bits.id
  io.tl.a.bits.address := addrGen.io.out.bits.addr
  io.tl.a.bits.mask    := Fill(tlulP.w, 1.U)
  io.tl.a.bits.data    := 0.U((8 * tlulP.w).W)

  addrGen.io.out.ready := io.tl.a.ready

  // Map TileLink D channel to AXI Read Data channel.
  val dSource = io.tl.d.bits.source
  val rDLast  = activeBeats(dSource).bits === 0.U

  io.axiRead.data.valid     := io.tl.d.valid
  io.axiRead.data.bits.id   := dSource
  io.axiRead.data.bits.data := io.tl.d.bits.data
  io.axiRead.data.bits.resp := Mux(
    io.tl.d.bits.error,
    AxiResponseType.SLVERR.asUInt,
    AxiResponseType.OKAY.asUInt
  )
  io.axiRead.data.bits.last := rDLast

  io.tl.d.ready := io.axiRead.data.ready

  // Update burst tracking state.
  for (i <- 0 until (1 << p.o)) {
    val isArFire = io.axiRead.addr.fire && io.axiRead.addr.bits.id === i.U
    val isRFire  = io.axiRead.data.fire && dSource === i.U

    activeBeats(i) := MuxCase(
      activeBeats(i),
      Seq(
        isArFire -> MakeValid(true.B, io.axiRead.addr.bits.len),
        isRFire  -> MakeValid(activeBeats(i).bits =/= 0.U, activeBeats(i).bits - 1.U)
      )
    )
  }
}

import _root_.circt.stage.{ChiselStage, FirtoolOption}
import chisel3.stage.ChiselGeneratorAnnotation
import scala.annotation.nowarn

@nowarn
object EmitAxiRead2TLUL extends App {
  val tlulP = new TLULParameters(dataBits = 256, addrBits = 32, idBits = 6)
  (new ChiselStage).execute(
    Array("--target", "systemverilog") ++ args,
    Seq(
      ChiselGeneratorAnnotation(() => new AxiRead2TLUL(tlulP))
    ) ++ Seq(FirtoolOption("-enable-layers=Verification"))
  )
}
