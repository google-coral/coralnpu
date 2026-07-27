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
import common.{MakeInvalid, MakeValid, MakeWireBundle}

class WriteTrackState extends Bundle {
  val beatsLeft = UInt(8.W)
  val errAccum  = Bool()
}

/** AxiWrite2TLUL: A Chisel module that serves as a write-only bridge between an AXI4 master and a
  * TileLink-UL slave.
  *
  * It translates AXI write transactions (AW, W, B) into TileLink Put operations. It synchronizes AW
  * and W channels and uses AxiAddressGenerator internally.
  *
  * This implementation uses NoUser for TileLink user fields.
  */
class AxiWrite2TLUL(p: TLULParameters) extends Module {
  val tlulP = p
  val io    = IO(new Bundle {
    val axiWrite = Flipped(new AxiMasterWriteIO(p.a, p.w * 8, p.o))
    val tl       = new TLULHost2Device[NoUser, NoUser](tlulP)
  })

  val addrGen = Module(new AxiAddressGenerator(p.a, p.w * 8, p.o))

  // Track active bursts to prevent out-of-order responses for the same ID.
  val activeWrites = RegInit(VecInit(Seq.fill(1 << p.o)(MakeInvalid(new WriteTrackState))))

  // Check for ID conflict at the input.
  val wIdConflict = activeWrites(io.axiWrite.addr.bits.id).valid

  // Connect AW channel to address generator (gated by ID conflict)
  addrGen.io.in.bits     := io.axiWrite.addr.bits
  addrGen.io.in.valid    := io.axiWrite.addr.valid && !wIdConflict
  io.axiWrite.addr.ready := addrGen.io.in.ready && !wIdConflict

  // AW / W Stream Synchronization
  io.tl.a.valid          := addrGen.io.out.valid && io.axiWrite.data.valid
  addrGen.io.out.ready   := io.tl.a.ready && io.axiWrite.data.valid
  io.axiWrite.data.ready := io.tl.a.ready && addrGen.io.out.valid

  // Map joined address and data to TileLink A channel.
  val wData  = io.axiWrite.data.bits
  val isFull = wData.strb.asBools.reduce(_ && _)

  io.tl.a.bits.opcode := Mux(
    isFull,
    TLULOpcodesA.PutFullData.asUInt,
    TLULOpcodesA.PutPartialData.asUInt
  )
  io.tl.a.bits.param   := 0.U
  io.tl.a.bits.size    := addrGen.io.out.bits.size
  io.tl.a.bits.source  := addrGen.io.out.bits.id
  io.tl.a.bits.address := addrGen.io.out.bits.addr
  io.tl.a.bits.mask    := wData.strb
  io.tl.a.bits.data    := wData.data

  // Map TileLink D channel to AXI Write Response (B) channel.
  val dSource  = io.tl.d.bits.source
  val wDLast   = activeWrites(dSource).bits.beatsLeft === 0.U
  val wRespErr = io.tl.d.bits.error || activeWrites(dSource).bits.errAccum

  io.axiWrite.resp.valid     := io.tl.d.valid && wDLast
  io.axiWrite.resp.bits.id   := dSource
  io.axiWrite.resp.bits.resp := Mux(
    wRespErr,
    AxiResponseType.SLVERR.asUInt,
    AxiResponseType.OKAY.asUInt
  )

  // Stalls D channel only on the last beat response if B channel is not ready.
  io.tl.d.ready := Mux(wDLast, io.axiWrite.resp.ready, true.B)

  // Update burst tracking state.
  for (i <- 0 until (1 << p.o)) {
    val isAwFire = io.axiWrite.addr.fire && io.axiWrite.addr.bits.id === i.U
    val isDResp  = io.tl.d.fire && dSource === i.U

    activeWrites(i) := MuxCase(
      activeWrites(i),
      Seq(
        isAwFire -> MakeValid(
          true.B,
          MakeWireBundle[WriteTrackState](
            new WriteTrackState,
            _.beatsLeft -> io.axiWrite.addr.bits.len,
            _.errAccum  -> false.B
          )
        ),
        isDResp -> MakeValid(
          activeWrites(i).bits.beatsLeft =/= 0.U,
          MakeWireBundle[WriteTrackState](
            new WriteTrackState,
            _.beatsLeft -> (activeWrites(i).bits.beatsLeft - 1.U),
            _.errAccum  -> (io.tl.d.bits.error || activeWrites(i).bits.errAccum)
          )
        )
      )
    )
  }
}

import _root_.circt.stage.{ChiselStage, FirtoolOption}
import chisel3.stage.ChiselGeneratorAnnotation
import scala.annotation.nowarn

@nowarn
object EmitAxiWrite2TLUL extends App {
  val tlulP = new TLULParameters(dataBits = 256, addrBits = 32, idBits = 6)
  (new ChiselStage).execute(
    Array("--target", "systemverilog") ++ args,
    Seq(
      ChiselGeneratorAnnotation(() => new AxiWrite2TLUL(tlulP))
    ) ++ Seq(FirtoolOption("-enable-layers=Verification"))
  )
}
