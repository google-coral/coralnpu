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
// RvvFrontEnd — Native Chisel Port
// Port of hdl/verilog/rvv/design/RvvFrontEnd.sv
//
// Assembles RVVInstructions into RVVCmds, manages architectural vector config
// state (vtype, vl, SEW, LMUL), handles vset* instructions, LMUL reduction,
// and instruction alignment.
// =============================================================================

// RVVCommand: internal command format combining instruction + arch state + rs1
class RvvCmd(p: Parameters) extends Bundle {
  val opcode     = RvvCompressedOpcode()
  val bits       = UInt(25.W)
  val rs1        = UInt(32.W)
  val archState  = new RvvConfigState(p)
}

class RvvFrontEnd(p: Parameters, instructionLanes: Int) extends Module {
  // Derived parameters matching rvv_backend_define.svh semantics
  private val vlen      = p.rvvVlen
  private val vlenb     = vlen / 8
  private val vstartWidth = log2Ceil(vlen)
  private val vlWidth    = log2Ceil(vlen) + 1

  val io = IO(new Bundle {
    // CSR inputs
    val vstart = Input(UInt(vstartWidth.W))
    val vxrm   = Input(UInt(2.W))
    val vxsat  = Input(Bool())
    val frm    = Input(UInt(3.W))

    // Instruction input
    val instValid = Input(Vec(instructionLanes, Bool()))
    val instData  = Input(Vec(instructionLanes, new RvvCompressedInstruction))
    val instReady = Output(Vec(instructionLanes, Bool()))

    // Register file read data (arrives 1 cycle after instruction)
    val regReadValid = Input(Vec(2 * instructionLanes, Bool()))
    val regReadData  = Input(Vec(2 * instructionLanes, UInt(32.W)))

    // Scalar regfile writeback (for vset instructions)
    val regWriteValid = Output(Vec(instructionLanes, Bool()))
    val regWriteAddr  = Output(Vec(instructionLanes, UInt(5.W)))
    val regWriteData  = Output(Vec(instructionLanes, UInt(32.W)))

    // Command output (to backend queue)
    val cmdValid = Output(Vec(instructionLanes, Bool()))
    val cmdData  = Output(Vec(instructionLanes, new RvvCmd(p)))
    val queueCapacity = Input(UInt(log2Ceil(2 * instructionLanes + 1).W))
    val queueCapacityOut = Output(UInt(log2Ceil(2 * instructionLanes + 1).W))

    // Trap output
    val trapValid = Output(Bool())
    val trapData  = Output(new RvvCompressedInstruction)

    // Config state output
    val configStateValid = Output(Bool())
    val configState      = Output(new RvvConfigState(p))
  })

  val N = instructionLanes
  val countBits = log2Ceil(N + 1)

  // ---- Architectural config state register ----
  val configStateQ = RegInit({
    val init = Wire(new RvvConfigState(p))
    init.vill      := true.B
    init.vl        := 0.U
    init.vstart    := 0.U
    init.ma        := false.B
    init.ta        := false.B
    init.xrm       := 0.U  // RNU
    init.xsat      := false.B
    init.sew       := 0.U  // SEW8
    init.lmul      := 0.U  // LMUL1
    init.lmul_orig := 0.U
    init
  })

  // ---- Instruction buffer (1-deep) ----
  val validInstQ     = RegInit(VecInit(Seq.fill(N)(false.B)))
  val validInstCountQ = RegInit(0.U(countBits.W))
  val instQ           = Reg(Vec(N, new RvvCompressedInstruction))

  // ---- Backpressure: compute how many new instructions we can accept ----
  val queueCap = io.queueCapacity - validInstCountQ
  io.queueCapacityOut := queueCap

  val validInPsum = Wire(Vec(N + 1, UInt(countBits.W)))
  validInPsum(0) := 0.U
  for (i <- 0 until N) {
    validInPsum(i + 1) := validInPsum(i) + io.instValid(i)
  }

  val instAccepted = Wire(Vec(N, Bool()))
  val validInstCountD = Wire(UInt(countBits.W))
  for (i <- 0 until N) {
    instAccepted(i) := (validInPsum(i) < queueCap) && io.instValid(i)
    io.instReady(i) := instAccepted(i)
  }
  validInstCountD := Mux(validInPsum(N) < queueCap, validInPsum(N), queueCap)

  // Update instruction buffer
  when (reset.asBool) {
    validInstQ := VecInit(Seq.fill(N)(false.B))
    validInstCountQ := 0.U
  } .otherwise {
    validInstQ := instAccepted
    validInstCountQ := validInstCountD
  }

  for (i <- 0 until N) {
    instQ(i) := io.instData(i)
  }

  // ---- Config state propagation through instruction slots ----
  // instConfigState(0) = current architectural state (with CSR inputs applied)
  // instConfigState(i+1) = state after processing instruction i
  val instConfigState = Wire(Vec(N + 1, new RvvConfigState(p)))
  val avl       = Wire(Vec(N, UInt(32.W)))
  val vlmax     = Wire(Vec(N, UInt(32.W)))
  val isSetvl   = Wire(Vec(N, Bool()))

  instConfigState(0) := configStateQ
  instConfigState(0).vstart := io.vstart
  instConfigState(0).xrm := io.vxrm
  instConfigState(0).xsat := io.vxsat

  for (i <- 0 until N) {
    instConfigState(i + 1) := instConfigState(i)
    avl(i)     := 0.U
    vlmax(i)   := 0.U
    isSetvl(i) := false.B

    val inst = instQ(i)
    val isRvvAlu = inst.opcode === RvvCompressedOpcode.RVVALU
    val funct3 = inst.bits(7, 5)
    val isCfg = isRvvAlu && funct3 === "b111".U

    when (validInstQ(i) && isCfg) {
      // vsetvli: bits[24] == 0, bits[24:23] != 2'b11
      when (inst.bits(24) === 0.U && inst.bits(24, 23) =/= "b11".U) {
        avl(i) := Mux(inst.bits(12, 8) === 0.U,
          Mux(inst.bits(4, 0) === 0.U,
            instConfigState(i).vl,   // rd=x0, rs1=x0
            "hFFFFFFFF".U),           // rd!=x0, rs1=x0
          io.regReadData(2 * i))      // rs1 != x0

        instConfigState(i + 1).lmul_orig := inst.bits(15, 13)
        instConfigState(i + 1).sew       := inst.bits(18, 16)
        instConfigState(i + 1).ta        := inst.bits(19)
        instConfigState(i + 1).ma        := inst.bits(20)
        isSetvl(i) := true.B
      }

      // vsetivli: bits[24:23] == 2'b11
      when (inst.bits(24, 23) === "b11".U) {
        avl(i) := inst.bits(12, 8).pad(32)
        instConfigState(i + 1).lmul_orig := inst.bits(15, 13)
        instConfigState(i + 1).sew       := inst.bits(18, 16)
        instConfigState(i + 1).ta        := inst.bits(19)
        instConfigState(i + 1).ma        := inst.bits(20)
        isSetvl(i) := true.B
      }

      // vsetvl: bits[24:23] == 2'b10
      when (inst.bits(24, 23) === "b10".U) {
        avl(i) := Mux(inst.bits(12, 8) === 0.U,
          Mux(inst.bits(4, 0) === 0.U,
            instConfigState(i).vl,
            "hFFFFFFFF".U),
          io.regReadData(2 * i))

        instConfigState(i + 1).lmul_orig := io.regReadData(2 * i + 1)(2, 0)
        instConfigState(i + 1).sew       := io.regReadData(2 * i + 1)(5, 3)
        instConfigState(i + 1).ta        := io.regReadData(2 * i + 1)(6)
        instConfigState(i + 1).ma        := io.regReadData(2 * i + 1)(7)
        isSetvl(i) := true.B
      }
    }

    when (isSetvl(i)) {
      // Compute vill (illegal vtype check)
      val sew = instConfigState(i + 1).sew
      val lmulOrig = instConfigState(i + 1).lmul_orig

      instConfigState(i + 1).vill := MuxLookup(sew, true.B)(Seq(
        0.U -> MuxLookup(lmulOrig, true.B)(Seq(  // SEW8
          0.U -> false.B, 1.U -> false.B, 2.U -> false.B, 3.U -> false.B,  // m1, m2, m4, m8
          5.U -> false.B, 6.U -> false.B, 7.U -> false.B)),                 // mf2, mf4, mf8
        1.U -> MuxLookup(lmulOrig, true.B)(Seq(  // SEW16
          0.U -> false.B, 1.U -> false.B, 2.U -> false.B, 3.U -> false.B,  // m1, m2, m4, m8
          5.U -> false.B, 7.U -> false.B)),                                 // mf2, mf8
        2.U -> MuxLookup(lmulOrig, true.B)(Seq(  // SEW32
          0.U -> false.B, 1.U -> false.B, 2.U -> false.B, 3.U -> false.B)), // m1, m2, m4, m8
      ))

      // Compute VLMAX = VLEN * LMUL / SEW
      // VLENB shifts: VLENB * lmul_mult / (1 << sew)
      val vlenbU = vlenb.U
      val lmulMult = MuxLookup(lmulOrig, 0.U)(Seq(
        7.U  -> (vlenbU / 8.U),     // mf8
        6.U  -> (vlenbU / 4.U),     // mf4
        5.U  -> (vlenbU / 2.U),     // mf2
        0.U  -> vlenbU,              // m1
        1.U  -> (vlenbU * 2.U),      // m2
        2.U  -> (vlenbU * 4.U),      // m4
        3.U  -> (vlenbU * 8.U),      // m8
      ))
      vlmax(i) := lmulMult >> sew

      // Compute vl = min(avl, vlmax), or 0 if vill
      when (instConfigState(i + 1).vill) {
        instConfigState(i + 1).vl := 0.U
      } .elsewhen (avl(i) > vlmax(i)) {
        instConfigState(i + 1).vl := vlmax(i)
      } .otherwise {
        instConfigState(i + 1).vl := avl(i)
      }

      instConfigState(i + 1).lmul := instConfigState(i + 1).lmul_orig

      // LMUL reduction: use minimal LMUL given actual vl
      val vlMinusOne = Mux(instConfigState(i + 1).vl === 0.U,
        0.U(vlWidth.W),
        instConfigState(i + 1).vl - 1.U)

      // Check which bit of vl-1 is set to determine minimal LMUL
      // VLEN=128 → vlWidth=8 bits → vlMinusOne[7:0]
      // For VLEN=128 and SEW=8:  vlMax=128, bits: v[7]→LMUL8, v[6]→LMUL4, etc.
      instConfigState(i + 1).lmul := MuxLookup(sew, instConfigState(i + 1).lmul_orig)(Seq(
        0.U -> MuxCase(instConfigState(i + 1).lmul_orig, Seq(  // SEW8
          (vlMinusOne(vlWidth - 1, vlWidth - 2) =/= "b00".U) -> 3.U,  // LMUL8
          (vlMinusOne(vlWidth - 3) === 1.U) -> 2.U,                       // LMUL4
          (vlMinusOne(vlWidth - 4) === 1.U) -> 1.U,                       // LMUL2
          (vlMinusOne(vlWidth - 5) === 1.U) -> 0.U,                       // LMUL1
          (vlMinusOne(vlWidth - 6) === 1.U) -> 5.U,                       // LMUL1_2
        )),
        1.U -> MuxCase(instConfigState(i + 1).lmul_orig, Seq(  // SEW16
          (vlMinusOne(vlWidth - 2, vlWidth - 3) =/= "b00".U) -> 3.U,  // LMUL8
          (vlMinusOne(vlWidth - 4) === 1.U) -> 2.U,                       // LMUL4
          (vlMinusOne(vlWidth - 5) === 1.U) -> 1.U,                       // LMUL2
          (vlMinusOne(vlWidth - 6) === 1.U) -> 0.U,                       // LMUL1
        )),
        2.U -> MuxCase(instConfigState(i + 1).lmul_orig, Seq(  // SEW32
          (vlMinusOne(vlWidth - 3, vlWidth - 4) =/= "b00".U) -> 3.U,  // LMUL8
          (vlMinusOne(vlWidth - 5) === 1.U) -> 2.U,                       // LMUL4
          (vlMinusOne(vlWidth - 6) === 1.U) -> 1.U,                       // LMUL2
        )),
      ))
    }
  }

  // Update config state register
  when (reset.asBool) {
    configStateQ.vill      := true.B
    configStateQ.vl        := 0.U
    configStateQ.vstart    := 0.U
    configStateQ.ma        := false.B
    configStateQ.ta        := false.B
    configStateQ.xrm       := 0.U
    configStateQ.xsat      := false.B
    configStateQ.sew       := 0.U
    configStateQ.lmul      := 0.U
    configStateQ.lmul_orig := 0.U
  } .otherwise {
    configStateQ := instConfigState(N)
  }

  // Config state valid: true when no instructions are in the buffer
  io.configStateValid := !validInstQ.reduce(_ || _)
  io.configState := configStateQ

  // ---- Command assembly ----
  val unalignedCmdValid = Wire(Vec(N, Bool()))
  val unalignedCmdData  = Wire(Vec(N, new RvvCmd(p)))
  val unalignedTrapValid = Wire(Vec(N, Bool()))
  val unalignedTrapData  = Wire(Vec(N, new RvvCompressedInstruction))

  for (i <- 0 until N) {
    val inst = instQ(i)
    val isRvvAlu = inst.opcode === RvvCompressedOpcode.RVVALU
    val funct3 = inst.bits(7, 5)
    val isCfg = isRvvAlu && funct3 === "b111".U

    unalignedTrapValid(i) := validInstQ(i) && !isSetvl(i) &&
      instConfigState(i + 1).vill
    unalignedTrapData(i) := inst

    unalignedCmdValid(i) := validInstQ(i) && !isSetvl(i) &&
      !instConfigState(i + 1).vill

    unalignedCmdData(i).opcode    := inst.opcode
    unalignedCmdData(i).bits      := inst.bits
    unalignedCmdData(i).archState := instConfigState(i + 1)
    // rs1: use reg read data if instruction reads rs1
    unalignedCmdData(i).rs1 := Mux(inst.bits(7), io.regReadData(2 * i), 0.U)

    // vset instructions write vl to rd
    io.regWriteValid(i) := isSetvl(i)
    io.regWriteAddr(i)  := inst.bits(4, 0)
    io.regWriteData(i)  := instConfigState(i + 1).vl.pad(32)
  }

  // ---- Align commands (pack valid to the left) ----
  // Compute prefix sum of valid bits → each valid input gets a destination index
  val prefixSum = Wire(Vec(N, UInt(log2Ceil(N + 1).W)))
  val runningSum = Wire(Vec(N + 1, UInt(log2Ceil(N + 1).W)))
  runningSum(0) := 0.U
  for (i <- 0 until N) {
    runningSum(i + 1) := runningSum(i) + unalignedCmdValid(i)
    prefixSum(i) := runningSum(i)  // index where input i routes to (if valid)
  }

  val packed = Wire(Vec(N, Bool()))
  val packedData = Wire(Vec(N, new RvvCmd(p)))

  for (outIdx <- 0 until N) {
    packed(outIdx) := false.B
    packedData(outIdx) := 0.U.asTypeOf(new RvvCmd(p))
    for (inIdx <- 0 until N) {
      when (unalignedCmdValid(inIdx) && (prefixSum(inIdx) === outIdx.U)) {
        packed(outIdx) := true.B
        packedData(outIdx) := unalignedCmdData(inIdx)
      }
    }
  }

  io.cmdValid := packed
  io.cmdData  := packedData

  // ---- Trap output ----
  val trapOccurred = unalignedTrapValid.reduce(_ || _)
  io.trapValid := trapOccurred

  // Find first trapping instruction
  io.trapData := 0.U.asTypeOf(new RvvCompressedInstruction)
  for (i <- 0 until N) {
    when (unalignedTrapValid(i)) {
      io.trapData := unalignedTrapData(i)
    }
  }
}
