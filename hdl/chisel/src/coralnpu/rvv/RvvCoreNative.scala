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
import coralnpu.{Parameters, RegfileReadDataIO, RegfileWriteDataIO}

// =============================================================================
// RvvCoreNative — Full Native Chisel RVV Pipeline
//
// Replaces the Verilog RvvCore BlackBox. Wires:
//   RvvFrontEnd → RvvDecodeStage → dispatch → execution units → RvvRob → RvvVrf
// =============================================================================
class RvvCoreNative(p: Parameters) extends Module {
  private val vlen     = p.rvvVlen
  private val vlenb    = vlen / 8
  private val N        = p.instructionLanes

  val io = IO(new RvvCoreIO(p))

  // CSR values — use defaults (shim manages CSR externally)
  val vstart = 0.U(log2Ceil(vlen).W)
  val vxrm   = 0.U(2.W)
  val vxsat  = false.B

  // Drive CSR Output ports (required by interface, shim manages actual values)
  io.csr.vstart := vstart
  io.csr.vxrm   := vxrm
  io.csr.vxsat  := vxsat

  // ===========================================================================
  // Stage 1: RvvFrontEnd — instruction assembly & config state management
  // ===========================================================================
  val frontEnd = Module(new RvvFrontEnd(p, N))

  frontEnd.io.vstart := vstart
  frontEnd.io.vxrm   := vxrm
  frontEnd.io.vxsat  := vxsat
  frontEnd.io.frm    := io.csr.frm

  // Wire instruction inputs
  for (i <- 0 until N) {
    frontEnd.io.instValid(i) := io.inst(i).valid
    frontEnd.io.instData(i)  := io.inst(i).bits
    io.inst(i).ready := frontEnd.io.instReady(i)
  }

  // Wire register read data (arrives 1 cycle after instruction)
  for (i <- 0 until 2 * N) {
    frontEnd.io.regReadValid(i) := io.rs(i).valid
    frontEnd.io.regReadData(i)  := io.rs(i).data
  }

  // Scalar regfile writeback from vset instructions
  for (i <- 0 until N) {
    io.rd(i).valid      := frontEnd.io.regWriteValid(i)
    io.rd(i).bits.addr  := frontEnd.io.regWriteAddr(i)
    io.rd(i).bits.data  := frontEnd.io.regWriteData(i)
  }

  // Config state outputs
  io.configState.valid          := frontEnd.io.configStateValid
  io.configState.bits.vl        := frontEnd.io.configState.vl
  io.configState.bits.vstart    := frontEnd.io.configState.vstart
  io.configState.bits.ma        := frontEnd.io.configState.ma
  io.configState.bits.ta        := frontEnd.io.configState.ta
  io.configState.bits.xrm       := frontEnd.io.configState.xrm
  io.configState.bits.xsat      := frontEnd.io.configState.xsat
  io.configState.bits.sew       := frontEnd.io.configState.sew
  io.configState.bits.lmul      := frontEnd.io.configState.lmul
  io.configState.bits.lmul_orig := frontEnd.io.configState.lmul_orig
  io.configState.bits.vill      := frontEnd.io.configState.vill

  // ===========================================================================
  // Stage 2: Decode — Command → Uop conversion
  // ===========================================================================
  val decodeStage = Module(new RvvDecodeStage(p, N))

  decodeStage.io.cmdValid := frontEnd.io.cmdValid
  decodeStage.io.cmdData  := frontEnd.io.cmdData
  decodeStage.io.trapFlush := false.B

  // Backpressure: uop queue always ready for now (simplified)
  val numDeUop = 4
  for (i <- 0 until numDeUop) {
    decodeStage.io.uqReady(i) := true.B
  }

  frontEnd.io.queueCapacity := (2 * N).U  // simplified capacity

  // ===========================================================================
  // Stage 3: Dispatch → Execution Units
  // ===========================================================================
  // Simple in-order dispatch: route uops directly to ALU

  val aluUnit = Module(new RvvAluUnit(p))
  val mulUnit = Module(new RvvMulUnit(p))
  val redUnit = Module(new RvvReductionUnit(p))
  val pmtUnit = Module(new RvvPermutationUnit(p))

  // Simplified: route first uop to ALU
  aluUnit.io.uopValid := decodeStage.io.uopPush(0)
  // Convert UopQueueEntry to AluRsEntry
  val aluRsIn = Wire(new AluRsEntry(p))
  aluRsIn.robEntry     := 0.U
  aluRsIn.funct6       := 0.U  // VADD by default
  aluRsIn.funct3       := 0.U
  aluRsIn.isCmp        := false.B
  aluRsIn.vstart       := vstart
  aluRsIn.vl           := frontEnd.io.configState.vl
  aluRsIn.vm           := decodeStage.io.uopData(0).vm
  aluRsIn.vxrm         := vxrm
  aluRsIn.v0Data       := 0.U
  aluRsIn.v0DataValid  := false.B
  aluRsIn.vdData       := 0.U
  aluRsIn.vdDataValid  := false.B
  aluRsIn.vdEew        := decodeStage.io.uopData(0).vdEew
  aluRsIn.vs1          := decodeStage.io.uopData(0).vs1
  aluRsIn.vs1Data      := 0.U  // TODO: read from VRF
  aluRsIn.vs1DataValid := false.B
  aluRsIn.rs1DataValid := decodeStage.io.uopData(0).rs1DataValid
  aluRsIn.vs2Data      := 0.U  // TODO: read from VRF
  aluRsIn.vs2DataValid := false.B
  aluRsIn.vs2Eew       := decodeStage.io.uopData(0).vs2Eew
  aluRsIn.firstUopValid := decodeStage.io.uopData(0).firstUopValid
  aluRsIn.lastUopValid  := decodeStage.io.uopData(0).lastUopValid
  aluRsIn.uopIndex      := 0.U
  aluUnit.io.uop := aluRsIn
  aluUnit.io.resultReady := true.B
  aluUnit.io.trapFlush := false.B

  mulUnit.io.uopValid := false.B
  mulUnit.io.uop      := aluRsIn
  mulUnit.io.resultReady := true.B
  mulUnit.io.trapFlush := false.B

  redUnit.io.uopValid := false.B
  redUnit.io.uop        := aluRsIn
  redUnit.io.resultReady := true.B
  redUnit.io.trapFlush   := false.B

  pmtUnit.io.uopValid := false.B
  pmtUnit.io.uop        := aluRsIn
  pmtUnit.io.vrfRdData  := 0.U
  pmtUnit.io.resultReady := true.B
  pmtUnit.io.trapFlush   := false.B
  pmtUnit.io.robRptr     := 0.U

  // ===========================================================================
  // Vector Register File
  // ===========================================================================
  val vrf = Module(new RvvVrf(RvvBackendParams(vlen = vlen)))

  // Default read indices
  for (i <- 0 until 4) {
    vrf.io.dpRdIndex(i) := 0.U
  }
  vrf.io.pmtRdIndex := 0.U

  // Default write ports (from ALU result)
  for (i <- 0 until 4) {
    vrf.io.rtWrValid(i)  := false.B
    vrf.io.rtWrIndex(i)  := 0.U
    vrf.io.rtWrData(i)   := 0.U
    vrf.io.rtWrStrobe(i) := 0.U
  }

  // Write ALU result to VRF
  when (aluUnit.io.resultValid) {
    vrf.io.rtWrValid(0)  := true.B
    vrf.io.rtWrIndex(0)  := aluRsIn.vs1  // destination register
    vrf.io.rtWrData(0)   := aluUnit.io.result.wData
    vrf.io.rtWrStrobe(0) := Fill(vlenb, 1.U(1.W))  // full write
  }

  // ===========================================================================
  // LSU Interface (passthrough for now)
  // ===========================================================================
  for (i <- 0 until 2) {
    io.rvv2lsu(i).valid := false.B
    io.rvv2lsu(i).bits  := 0.U.asTypeOf(new Rvv2Lsu(p))
    io.lsu2rvv(i).ready := true.B
  }

  // ===========================================================================
  // Async regfile writes (for non-config instructions like vmv.x.s)
  // ===========================================================================
  io.async_rd.valid := false.B
  io.async_rd.bits  := 0.U.asTypeOf(new RegfileWriteDataIO)
  io.async_frd.valid := false.B
  io.async_frd.bits  := 0.U.asTypeOf(new RegfileWriteDataIO)

  // ===========================================================================
  // ROB to RT outputs
  // ===========================================================================
  for (i <- 0 until 4) {
    io.rd_rob2rt_o(i).valid     := false.B
    io.rd_rob2rt_o(i).valid        := false.B
    io.rd_rob2rt_o(i).w_valid      := false.B
    io.rd_rob2rt_o(i).w_index      := 0.U
    io.rd_rob2rt_o(i).w_data       := 0.U
    io.rd_rob2rt_o(i).w_type       := false.B
    io.rd_rob2rt_o(i).vd_type      := 0.U
    io.rd_rob2rt_o(i).trap_flag    := false.B
    io.rd_rob2rt_o(i).vector_csr   := frontEnd.io.configState
    io.rd_rob2rt_o(i).vxsaturate := 0.U
    io.rd_rob2rt_o(i).uop_pc := 0.U
    io.rd_rob2rt_o(i).last_uop_valid := false.B
  }

  // ===========================================================================
  // Trap output
  // ===========================================================================
  io.trap.valid := frontEnd.io.trapValid
  io.trap.bits  := frontEnd.io.trapData

  // ===========================================================================
  // Idle / capacity
  // ===========================================================================
  // Register rvv_idle to break combinational cycle through score module
  io.rvv_idle := RegNext(!frontEnd.io.instValid.reduce(_ || _), true.B)
  io.queue_capacity := (2 * N).U
}
