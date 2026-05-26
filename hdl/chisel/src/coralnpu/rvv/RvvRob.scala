// Copyright 2025 Google LLC
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

package coralnpu.rvv

import chisel3._
import coralnpu.Parameters

// =============================================================================
// Reorder Buffer — internal helper types
// =============================================================================

// Dispatch → ROB
class RobDp2Rob(p: Parameters) extends Bundle {
  val w_index   = UInt(5.W)
  val w_type    = Bool()
  val byte_type = UInt(p.rvvVlenb.W)
}

// PU → ROB
class RobPu2Rob(p: Parameters) extends Bundle {
  val rob_entry  = UInt(3.W)
  val w_valid    = Bool()
  val w_data     = UInt(p.rvvVlen.W)
  val vsaturate  = UInt(p.rvvVlenb.W)
}

// ROB → Dispatch bypass
class RobBypassEntry(p: Parameters) extends Bundle {
  val valid     = Bool()
  val wValid    = Bool()
  val wIndex    = UInt(5.W)
  val wType     = Bool()
  val wData     = UInt(p.rvvVlen.W)
  val byteType  = UInt(p.rvvVlenb.W)
}

// Result memory
class RobResMem(p: Parameters) extends Bundle {
  val w_valid    = Bool()
  val w_data     = UInt(p.rvvVlen.W)
  val vsaturate  = UInt(p.rvvVlenb.W)
}

// =============================================================================
// Reorder Buffer
// =============================================================================
class RvvRob(p: Parameters) extends Module {
  private val numDpUop = 2
  private val numSmPort = 8
  private val numRtUop = 4
  private val robDepth = 8

  val io = IO(new Bundle {
    val dpValid    = Input(Vec(numDpUop, Bool()))
    val dpData     = Input(Vec(numDpUop, new RobDp2Rob(p)))
    val dpReady    = Output(Vec(numDpUop, Bool()))
    val robEmpty   = Output(Bool())

    val puWrValid  = Input(Vec(numSmPort, Bool()))
    val puWrData   = Input(Vec(numSmPort, new RobPu2Rob(p)))

    val rtValid    = Output(Vec(numRtUop, Bool()))
    val rtData     = Output(Vec(numRtUop, new Rob2Rt(p)))
    val rtReady    = Input(Vec(numRtUop, Bool()))

    val bypass     = Output(Vec(robDepth, new RobBypassEntry(p)))

    val trapValid    = Input(Bool())
    val trapRobEntry = Input(UInt(3.W))
    val trapReady    = Output(Bool())
    val trapReadyRvv = Output(Bool())
    val trapFlush    = Output(Bool())
  })

  // ---- Trap flag register ----
  val trapFlag = RegInit(VecInit(Seq.fill(robDepth)(false.B)))

  // ---- Trap flush ----
  val trapIn = WireDefault(false.B)
  val trapReadyReg = RegInit(false.B)
  when (trapIn && !trapReadyReg) { trapReadyReg := true.B }
  io.trapReadyRvv := trapReadyReg
  io.trapFlush := trapIn || trapReadyReg

  // ---- Uop Info FIFO ----
  val uopInfoFifo = Module(new MultiFifo(new RobDp2Rob(p), robDepth, numDpUop, numRtUop))
  uopInfoFifo.io.push   := io.dpValid
  uopInfoFifo.io.datain := io.dpData
  uopInfoFifo.io.clear  := io.trapFlush
  io.dpReady := VecInit(uopInfoFifo.io.almostFull.map(!_))

  val retireFire = Wire(Vec(numRtUop, Bool()))
  retireFire := (io.rtValid zip io.rtReady).map { case (v, r) => v && r }
  uopInfoFifo.io.pop := retireFire

  // ---- Entry Valid FIFO ----
  val validFifo = Module(new MultiFifo(Bool(), robDepth, numDpUop, numRtUop))
  validFifo.io.push   := io.dpValid
  validFifo.io.datain := io.dpValid
  validFifo.io.pop    := retireFire
  validFifo.io.clear  := io.trapFlush

  // ---- Result Memory ----
  val resMem = RegInit(VecInit(Seq.fill(robDepth)(0.U.asTypeOf(new RobResMem(p)))))
  for (k <- 0 until numSmPort) {
    when (io.puWrValid(k)) {
      val e = io.puWrData(k).rob_entry
      resMem(e).w_valid    := io.puWrData(k).w_valid
      resMem(e).w_data     := io.puWrData(k).w_data
      resMem(e).vsaturate  := io.puWrData(k).vsaturate
    }
  }

  // ---- Uop Done Bits ----
  val uopDone = RegInit(VecInit(Seq.fill(robDepth)(false.B)))
  val rptr = uopInfoFifo.io.rptr

  when (io.trapFlush) {
    uopDone := VecInit(Seq.fill(robDepth)(false.B))
  } .otherwise {
    for (k <- 0 until numRtUop) {
      when (retireFire(k)) { uopDone((rptr + k.U) % robDepth.U) := false.B }
    }
    for (k <- 0 until numSmPort) {
      when (io.puWrValid(k)) { uopDone(io.puWrData(k).rob_entry) := true.B }
    }
  }

  // ---- Retire Logic ----
  val uopInfo    = uopInfoFifo.io.fifoData
  val entryValid = validFifo.io.fifoData
  io.robEmpty := !entryValid.reduceTree(_ || _)

  for (i <- 0 until numRtUop) {
    val wr = (rptr + i.U) % robDepth.U
    val done = uopDone(wr)

    if (i == 0) {
      io.rtValid(i) := entryValid(i) && (done || trapFlag(wr))
    } else {
      val prev = (rptr + (i - 1).U) % robDepth.U
      io.rtValid(i) := entryValid(i) && done && io.rtValid(i - 1) && !trapFlag(prev)
    }

    io.rtData(i).valid        := entryValid(i)
    io.rtData(i).w_valid      := resMem(wr).w_valid && done
    io.rtData(i).w_index      := uopInfo(i).w_index
    io.rtData(i).w_data       := resMem(wr).w_data
    io.rtData(i).w_type       := uopInfo(i).w_type
    io.rtData(i).vd_type      := uopInfo(i).byte_type
    io.rtData(i).trap_flag    := trapFlag(wr)
    io.rtData(i).vxsaturate   := resMem(wr).vsaturate
    io.rtData(i).uop_pc       := 0.U
    io.rtData(i).last_uop_valid := false.B
    // vector_csr left at Wire default (will be driven externally)
  }

  // ---- Trap Logic ----
  io.trapReady := true.B
  when (io.trapFlush) {
    trapFlag := VecInit(Seq.fill(robDepth)(false.B))
  } .elsewhen (io.trapValid && io.trapReady) {
    trapFlag(io.trapRobEntry) := true.B
  }
  trapIn := entryValid(0) && io.rtData(0).trap_flag && io.rtReady(0)

  // ---- Bypass to Dispatch ----
  for (i <- 0 until robDepth) {
    val wr = (rptr + i.U) % robDepth.U
    io.bypass(i).valid     := entryValid(i)
    io.bypass(i).wValid    := resMem(wr).w_valid && uopDone(wr)
    io.bypass(i).wIndex    := uopInfo(i).w_index
    io.bypass(i).wType     := uopInfo(i).w_type
    io.bypass(i).wData     := resMem(wr).w_data
    io.bypass(i).byteType  := uopInfo(i).byte_type
  }
}
