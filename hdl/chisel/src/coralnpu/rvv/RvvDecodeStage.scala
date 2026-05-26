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
import chisel3.util._
import coralnpu.Parameters

// =============================================================================
// RvvDecodeStage — Consolidated Decode Pipeline
// Port of hdl/verilog/rvv/design/rvv_backend_decode*.sv
//
// Takes commands from the RvvFrontEnd command queue and decodes them into
// uops for the uop queue, splitting vector instructions into element groups
// based on SEW/LMUL/EMUL.
// =============================================================================

// Uop entry in the uop queue (simplified — full version has ~40 fields)
class UopQueueEntry(p: Parameters) extends Bundle {
  private val vlen = p.rvvVlen
  private val vlWidth = log2Ceil(vlen) + 1
  val exeUnit     = UInt(4.W)      // EXE_UNIT_e: ALU, MUL, LSU, etc.
  val uopClass    = UInt(3.W)      // UOP_CLASS_e: VVV, VVX, VXV, etc.
  val vectorCsr   = new RvvConfigState(p)
  val vsEvl       = UInt(vlWidth.W)
  val vm          = Bool()
  val v0Valid     = Bool()
  val dstIndex    = UInt(5.W)
  val vdEew       = UInt(3.W)      // EEW_e
  val vdValid     = Bool()
  val vs3Valid    = Bool()
  val xdValid     = Bool()
  val vs1         = UInt(5.W)
  val vs1Eew      = UInt(3.W)
  val vs1Valid    = Bool()
  val vs2Index    = UInt(5.W)
  val vs2Eew      = UInt(3.W)
  val vs2Valid    = Bool()
  val rs1Data     = UInt(32.W)
  val rs1DataValid = Bool()
  val uopIndex    = UInt(5.W)
  val firstUopValid = Bool()
  val lastUopValid  = Bool()
  val pshRobValid   = Bool()
  val pshLsuValid   = Bool()
}

class RvvDecodeStage(p: Parameters, instructionLanes: Int) extends Module {
  // Backend config (DISPATCH2 defaults)
  private val numDeInst = 2
  private val numDeUop  = 4

  val io = IO(new Bundle {
    // From command queue (aligned commands from RvvFrontEnd)
    val cmdValid = Input(Vec(instructionLanes, Bool()))
    val cmdData  = Input(Vec(instructionLanes, new RvvCmd(p)))

    // Backpressure from uop queue
    val uqReady  = Input(Vec(numDeUop, Bool()))

    // Pop signals back to command queue
    val cmdPop   = Output(Vec(instructionLanes, Bool()))

    // Push to uop queue
    val uopPush  = Output(Vec(numDeUop, Bool()))
    val uopData  = Output(Vec(numDeUop, new UopQueueEntry(p)))

    // Trap flush
    val trapFlush = Input(Bool())
  })

  val N = instructionLanes

  // ---- Decode each command slot into uops ----
  // For simplicity (DISPATCH2 mode: NUM_DE_INST=2, NUM_DE_UOP=4):
  // Slot 0 produces up to 4 uops, Slot 1 produces up to 2 uops
  val deUopValid = Wire(Vec(numDeInst, Vec(numDeUop, Bool())))
  val deUop      = Wire(Vec(numDeInst, Vec(numDeUop, new UopQueueEntry(p))))

  for (instIdx <- 0 until numDeInst) {
    val cmd = io.cmdData(instIdx)
    val valid = io.cmdValid(instIdx)

    // Determine execution unit based on opcode
    val isLoad  = cmd.opcode === RvvCompressedOpcode.RVVLOAD
    val isStore = cmd.opcode === RvvCompressedOpcode.RVVSTORE
    val isAlu   = cmd.opcode === RvvCompressedOpcode.RVVALU

    // Simplified uop generation: each instruction produces 1-4 uops
    // based on EMUL (effective LMUL). For now, produce 1 uop per instruction.
    for (uopIdx <- 0 until numDeUop) {
      val isFirst = uopIdx == 0
      deUopValid(instIdx)(uopIdx) := valid && isFirst.B

      deUop(instIdx)(uopIdx).exeUnit := Mux(isLoad || isStore, 7.U, 0.U) // LSU=7, ALU=0
      deUop(instIdx)(uopIdx).uopClass := 7.U // VVV
      deUop(instIdx)(uopIdx).vectorCsr := cmd.archState
      deUop(instIdx)(uopIdx).vsEvl := cmd.archState.vl
      deUop(instIdx)(uopIdx).vm := cmd.bits(19) // bit 25 in full inst = bit 19 in compressed
      deUop(instIdx)(uopIdx).v0Valid := !cmd.bits(19)
      deUop(instIdx)(uopIdx).dstIndex := cmd.bits(4, 0)
      deUop(instIdx)(uopIdx).vdEew := cmd.archState.sew
      deUop(instIdx)(uopIdx).vdValid := true.B
      deUop(instIdx)(uopIdx).vs3Valid := false.B
      deUop(instIdx)(uopIdx).xdValid := false.B
      deUop(instIdx)(uopIdx).vs1 := cmd.bits(12, 8)
      deUop(instIdx)(uopIdx).vs1Eew := cmd.archState.sew
      deUop(instIdx)(uopIdx).vs1Valid := true.B
      deUop(instIdx)(uopIdx).vs2Index := cmd.bits(17, 13)
      deUop(instIdx)(uopIdx).vs2Eew := cmd.archState.sew
      deUop(instIdx)(uopIdx).vs2Valid := true.B
      deUop(instIdx)(uopIdx).rs1Data := cmd.rs1
      deUop(instIdx)(uopIdx).rs1DataValid := cmd.bits(7)
      deUop(instIdx)(uopIdx).uopIndex := 0.U
      deUop(instIdx)(uopIdx).firstUopValid := true.B
      deUop(instIdx)(uopIdx).lastUopValid := true.B
      deUop(instIdx)(uopIdx).pshRobValid := true.B
      deUop(instIdx)(uopIdx).pshLsuValid := isLoad || isStore
    }
  }

  // ---- Control: route uops to uop queue with priority packing ----
  // Simple priority-based packing: uops from instruction 0 first, then instruction 1
  val allUops = Wire(Vec(numDeInst * numDeUop, Valid(new UopQueueEntry(p))))
  for (i <- 0 until numDeInst) {
    for (j <- 0 until numDeUop) {
      allUops(i * numDeUop + j).valid := deUopValid(i)(j)
      allUops(i * numDeUop + j).bits  := deUop(i)(j)
    }
  }

  // Pack into NUM_DE_UOP output slots
  val prefixSum = Wire(Vec(allUops.length, UInt(log2Ceil(allUops.length + 1).W)))
  val running = Wire(Vec(allUops.length + 1, UInt(log2Ceil(allUops.length + 1).W)))
  running(0) := 0.U
  for (i <- 0 until allUops.length) {
    running(i + 1) := running(i) + allUops(i).valid
    prefixSum(i) := running(i)
  }

  for (outIdx <- 0 until numDeUop) {
    io.uopPush(outIdx) := false.B
    io.uopData(outIdx) := 0.U.asTypeOf(new UopQueueEntry(p))
    for (inIdx <- 0 until allUops.length) {
      when (allUops(inIdx).valid && prefixSum(inIdx) === outIdx.U && io.uqReady(outIdx)) {
        io.uopPush(outIdx) := true.B
        io.uopData(outIdx) := allUops(inIdx).bits
      }
    }
  }

  // Pop signals: pop a command from CQ when its last uop is accepted
  val lastUopAccepted = Wire(Vec(numDeUop, Bool()))
  for (i <- 0 until numDeUop) {
    lastUopAccepted(i) := io.uopPush(i) && io.uopData(i).lastUopValid
  }

  // Map last-uop accepted events back to instruction pop signals
  // Each accepted last-uop corresponds to one instruction completing
  val lastUopSum = Wire(Vec(numDeUop + 1, UInt(log2Ceil(numDeUop + 1).W)))
  lastUopSum(0) := 0.U
  for (i <- 0 until numDeUop) {
    lastUopSum(i + 1) := lastUopSum(i) + lastUopAccepted(i)
  }

  io.cmdPop := VecInit(Seq.fill(N)(false.B))
  for (instIdx <- 0 until N) {
    // Pop instruction instIdx when we've accepted exactly instIdx+1 last-uops
    // and we haven't already popped more
    when (lastUopSum(numDeUop) > instIdx.U) {
      io.cmdPop(instIdx) := true.B
    }
  }
}
