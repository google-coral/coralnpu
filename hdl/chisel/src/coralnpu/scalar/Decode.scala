// Copyright 2023 Google LLC
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


// Decode: Contains decode logic to be forwarded to the appropriate functional
// block. A serialization mechanism is introduced to stall a decoded instruction
// from bring presented to the functional block until next cycle if the block has
// already been presented with an instruction from another decoder.

package coralnpu

import chisel3._
import chisel3.util._
import common._
import coralnpu.float.{FloatInstruction, FloatOpcode}
import coralnpu.rvv._

class DecodedInstruction(p: Parameters) extends Bundle {
  // The original encoding
  val inst = UInt(32.W)

  // Immediates
  val imm12  = UInt(32.W)
  val imm20  = UInt(32.W)
  val immjal = UInt(32.W)
  val immbr  = UInt(32.W)
  val immcsr = UInt(32.W)
  val immst  = UInt(32.W)

  // RV32I
  val lui   = Bool()
  val auipc = Bool()
  val jal   = Bool()
  val jalr  = Bool()
  val beq   = Bool()
  val bne   = Bool()
  val blt   = Bool()
  val bge   = Bool()
  val bltu  = Bool()
  val bgeu  = Bool()
  val csrrw = Bool()
  val csrrs = Bool()
  val csrrc = Bool()
  val lb    = Bool()
  val lh    = Bool()
  val lw    = Bool()
  val lbu   = Bool()
  val lhu   = Bool()
  val sb    = Bool()
  val sh    = Bool()
  val sw    = Bool()
  val fence = Bool()
  val addi  = Bool()
  val slti  = Bool()
  val sltiu = Bool()
  val xori  = Bool()
  val ori   = Bool()
  val andi  = Bool()
  val slli  = Bool()
  val srli  = Bool()
  val srai  = Bool()
  val add   = Bool()
  val sub   = Bool()
  val slt   = Bool()
  val sltu  = Bool()
  val xor   = Bool()
  val or    = Bool()
  val and   = Bool()
  val sll   = Bool()
  val srl   = Bool()
  val sra   = Bool()

  // RV32M
  val mul     = Bool()
  val mulh    = Bool()
  val mulhsu  = Bool()
  val mulhu   = Bool()
  val div     = Bool()
  val divu    = Bool()
  val rem     = Bool()
  val remu    = Bool()

  // ZBB
  val andn  = Bool()
  val orn   = Bool()
  val xnor  = Bool()
  val clz  = Bool()
  val ctz  = Bool()
  val cpop = Bool()
  val max  = Bool()
  val maxu = Bool()
  val min  = Bool()
  val minu = Bool()
  val sextb = Bool()
  val sexth = Bool()
  val rol = Bool()
  val ror = Bool()
  val orcb = Bool()
  val rev8 = Bool()
  val zexth = Bool()
  val rori = Bool()

  // Core controls.
  val ebreak = Bool()
  val ecall  = Bool()
  val mpause = Bool()
  val mret   = Bool()
  val undef  = Bool()
  val wfi    = Bool()

  // Fences.
  val fencei = Bool()
  val flushat = Bool()
  val flushall = Bool()

  val rvv = Option.when(p.enableRvv)(Valid(new RvvCompressedInstruction()))

  val float = Option.when(p.enableFloat)(Valid(new FloatInstruction()))

  def isAluImm(): Bool = {
      addi || slti || sltiu || xori || ori || andi || slli || srli || srai || rori
  }
  def isAluReg(): Bool = {
      add || sub || slt || sltu || xor || or || and || xnor || orn || andn || sll || srl || sra
  }
  def isAlu1Bit(): Bool = { clz || ctz || cpop || sextb || sexth || zexth || orcb || rev8 }
  def isAlu2Bit(): Bool = { min || minu || max || maxu || rol || ror }
  def isAlu(): Bool = { isAluImm() || isAluReg() || isAlu1Bit() || isAlu2Bit() }
  def isCsr(): Bool = { csrrw || csrrs || csrrc }
  def isCsrImm() = { isCsr() &&  inst(14) }
  def isCsrReg() = { isCsr() && !inst(14) }
  def isCondBr(): Bool = { beq || bne || blt || bge || bltu || bgeu }
  def isScalarLoad(): Bool = { lb || lh || lw || lbu || lhu }
  def isScalarStore(): Bool = { sb || sh || sw }
  def isFloat(): Bool = { float.map(f => f.valid).getOrElse(false.B) }
  def isFloatLoad(): Bool = {
    float.map(f => f.valid && f.bits.opcode === FloatOpcode.LOADFP).getOrElse(false.B)
  }
  def isFloatStore(): Bool = {
    float.map(f => f.valid && f.bits.opcode === FloatOpcode.STOREFP).getOrElse(false.B)
  }
  def isLsu(): Bool = {
      isScalarLoad() || isScalarStore() || flushat || flushall ||
      isFloatLoad() || isFloatStore() || (if (p.enableRvv) {
        rvv.get.valid && rvv.get.bits.isLoadStore()
      } else {
        false.B
      })
  }
  def isMul(): Bool = { mul || mulh || mulhsu || mulhu }
  def isDvu(): Bool = { div || divu || rem || remu }
  def isFency(): Bool = { fencei || ebreak || wfi || mpause || flushat || flushall }

  // Instructions that should dispatch out of slot 0, with no other instructions
  // dispatched on the same cycle.
  def forceSlot0Only(): Bool = {
    isFency() || isCsr() || isFloat() || rvvReadsFloatRs1() || rvvWritesFrd()
  }

  // Checks if an instruction is a jump or changes context switch. Instructions
  // after these should not be executed on the same cycle.
  def isJump(): Bool = {
    jal || jalr || ebreak || ecall || mpause ||
    mret
  }

  def floatWritesRd(): Bool = { float.map(f => f.valid && f.bits.scalar_rd).getOrElse(false.B) }
  def floatReadsScalarRs1(): Bool = { float.map(f => f.valid && f.bits.scalar_rs1).getOrElse(false.B) }
  def floatReadsFloatRs1(): Bool = { float.map(f => f.valid && f.bits.float_rs1).getOrElse(false.B) }
  def floatReadsRs2(): Bool = { float.map(f => f.valid && f.bits.uses_rs2).getOrElse(false.B) }
  def floatReadsRs3(): Bool = { float.map(f => f.valid && f.bits.uses_rs3).getOrElse(false.B) }

  def rvvReadsFloatRs1(): Bool = {
    rvv.map(x => x.valid && x.bits.readsFloatRs1()).getOrElse(false.B)
  }

  def rvvWritesFrd(): Bool = {
    rvv.map(x => x.valid && x.bits.writesFrd()).getOrElse(false.B)
  }

  def rvvWritesRd(): Bool = {
    if (p.enableRvv) {
      rvv.get.valid && rvv.get.bits.writesRd()
    } else {
      false.B
    }
  }

  def readsRs1(): Bool = {
    isCondBr() || isAluReg() || isAluImm() || isAlu1Bit() || isAlu2Bit() ||
    isCsr() || isMul() || isDvu() || jalr || floatReadsScalarRs1() ||
    (if (p.enableRvv) { rvv.get.valid && rvv.get.bits.readsRs1() } else { false.B })
  }
  def readsRs2(): Bool = {
    isCondBr() || isAluReg() || isAlu2Bit() || isScalarStore() || isCsrReg() ||
    isMul() || isDvu() ||
    (if (p.enableRvv) { rvv.get.valid && rvv.get.bits.readsRs2() } else { false.B })
  }

  // Check if argument should be set by immediate value
  def rs1Set(): Bool = { auipc || isCsrImm() }
  def rs2Set(): Bool = { rs1Set() || isAluImm() || isAlu1Bit() || lui }
}

class Dispatch(p: Parameters) extends Module {
  val io = IO(new Bundle {
    // Core controls.
    val halted = Input(Bool())
    val mactive = Input(Bool())  // memory active
    val lsuActive = Input(Bool()) // lsu active

    val scoreboard = new Bundle {
      val regd = Input(UInt(32.W))
      val comb = Input(UInt(32.W))
    }
    val fscoreboard = Option.when(p.enableFloat)(Input(UInt(32.W)))

    // Branch status.
    val branchTaken = Input(Bool())

    // Fault status.
    val csrFault = Output(Vec(p.instructionLanes, Bool()))
    val jalFault = Output(Vec(p.instructionLanes, Bool()))
    val jalrFault = Output(Vec(p.instructionLanes, Bool()))
    val bxxFault = Output(Vec(p.instructionLanes, Bool()))
    val undefFault = Output(Vec(p.instructionLanes, Bool()))
    val rvvFault = Option.when(p.enableRvv)(
        Output(Vec(p.instructionLanes, Bool())))
    val bruTarget = Output(Vec(p.instructionLanes, UInt(32.W)))
    val jalrTarget = Input(Vec(p.instructionLanes, new RegfileBranchTargetIO))

    val interlock = Input(Bool())

    // Decode input interface.
    val inst = Vec(p.instructionLanes, Flipped(Decoupled(new FetchInstruction(p))))

    // Register file decode cycle interface.
    val rs1Read = Vec(p.instructionLanes, Flipped(new RegfileReadAddrIO))
    val rs1Set  = Vec(p.instructionLanes, Flipped(new RegfileReadSetIO))
    val rs2Read = Vec(p.instructionLanes, Flipped(new RegfileReadAddrIO))
    val rs2Set  = Vec(p.instructionLanes, Flipped(new RegfileReadSetIO))
    val rdMark  = Vec(p.instructionLanes, Flipped(new RegfileWriteAddrIO))
    val busRead = Vec(p.instructionLanes, Flipped(new RegfileBusAddrIO))
    val rdMark_flt = Option.when(p.enableFloat)(Flipped(new RegfileWriteAddrIO))
    val rvvRdMark = Option.when(p.enableRvv)(Vec(p.instructionLanes, Flipped(new RegfileWriteAddrIO)))
    val frs1Read = Option.when(p.enableFloat)(Vec(p.instructionLanes, Flipped(new RegfileReadAddrIO)))

    // ALU interface.
    val alu = Vec(p.instructionLanes, Valid(new AluCmd))

    // Branch interface.
    val bru = Vec(p.instructionLanes, Valid(new BruCmd(p)))

    // CSR interface.
    val csr = Valid(new CsrCmd)

    // LSU interface.
    val lsu = Vec(p.instructionLanes, Decoupled(new LsuCmd(p)))
    val lsuQueueCapacity = Input(UInt(3.W))

    // Multiplier interface.
    val mlu = Vec(p.instructionLanes, Decoupled(new MluCmd))

    // Divide interface.
    val dvu = Vec(p.instructionLanes, Decoupled(new DvuCmd))

    // Rvv interface.
    val rvv = Option.when(p.enableRvv)(
        Vec(p.instructionLanes, Decoupled(new RvvCompressedInstruction)))
    val rvvState = Option.when(p.enableRvv)(Input(Valid(new RvvConfigState(p))))
    val rvvIdle = Option.when(p.enableRvv)(Input(Bool()))
    val rvvQueueCapacity = Option.when(p.enableRvv)(Input(UInt(4.W)))

    // Float interface
    val float = Option.when(p.enableFloat)(Decoupled(new FloatInstruction))
    val csrFrm = Option.when(p.enableFloat)(Input(UInt(3.W)))

    val fbusPortAddr = Option.when(p.enableFloat)(Output(UInt(5.W)))

    val retirement_buffer_nSpace = Input(UInt(5.W))
    val retirement_buffer_empty = Input(Bool())
    val retirement_buffer_trap_pending = Input(Bool())
    val single_step = Input(Bool())
    val debug_mode = Input(Bool())
    val branch = Output(Vec(p.instructionLanes, Bool()))
    val jump = Output(Vec(p.instructionLanes, Bool()))
  })
}

class DispatchV2(p: Parameters) extends Dispatch(p) {
  // Decode instructions
  val decodedInsts = (0 until p.instructionLanes).map(i =>
    DecodeInstruction(p, i, io.inst(i).bits.addr, io.inst(i).bits.inst,
                      io.csrFrm.getOrElse(0.U))
  )

  // ---------------------------------------------------------------------------
  // Jumps
  // Determine if there has been a jump in the instruction stream. This can
  // include instructions that trigger context switches. Treat fences as jumps
  // as well.
  val isJump = decodedInsts.map(x => x.isJump() || x.isFency())
  // NB: Only consumer of io.jump is ROB, for now.
  // We really only want "normal" (e.g. not mret or ecall) control-flow instructions here,
  // not things that also have interesting properties (like fences).
  io.jump := decodedInsts.map(x => x.isJump() && !x.ecall && !x.mret)
  val jumped = isJump.scan(false.B)(_ || _)

  // ---------------------------------------------------------------------------
  // Branching
  // The operations that can be dispatched after branching are ones that can be
  // completed in one cycle. In practice, this means Alu and Bru operations
  val isBranch = decodedInsts.map(_.isCondBr())
  io.branch := isBranch
  val branched = isBranch.scan(false.B)(_ || _)
  val branchInterlock = (0 until p.instructionLanes).map(i => branched(i))

  // ---------------------------------------------------------------------------
  // Scalar Scoreboard
  val rdAddr = io.inst.map(_.bits.inst(11,7))
  val writesRd = decodedInsts.map(d =>
      (!d.isScalarStore() && !d.isCondBr()) ||
      (d.isFloat() && d.floatWritesRd()) ||
      d.rvvWritesRd()
  )

  val rdScoreboard = (0 until p.instructionLanes).map(i =>
      Mux(writesRd(i), UIntToOH(rdAddr(i), 32), 0.U(32.W)))
  val scoreboardScan = rdScoreboard.scan(0.U(32.W))(_ | _)
  // Note: regd comes from directly from registers, accessible on the same cycle
  // via the busPort of the register file. comb includes write forwarding.
  val regd =  scoreboardScan.map(_ | io.scoreboard.regd)
  val comb =  scoreboardScan.map(_ | io.scoreboard.comb)
  val rs1Addr = io.inst.map(_.bits.inst(19,15))
  val rs2Addr = io.inst.map(_.bits.inst(24,20))
  val usesRs1Regd = decodedInsts.map(d => d.jalr || d.isLsu())
  val usesRs2Regd = decodedInsts.map(d => d.isScalarStore())
  val readScoreboardRegd = (0 until p.instructionLanes).map(i =>
      MuxOR(usesRs1Regd(i), UIntToOH(rs1Addr(i), 32)) |
      MuxOR(usesRs2Regd(i), UIntToOH(rs2Addr(i), 32)))

  val usesRs1Comb = decodedInsts.map(d => d.readsRs1())
  val usesRs2Comb = decodedInsts.map(d => d.readsRs2())
  val readScoreboardComb = (0 until p.instructionLanes).map(i =>
      MuxOR(usesRs1Comb(i), UIntToOH(rs1Addr(i), 32)) |
      MuxOR(usesRs2Comb(i), UIntToOH(rs2Addr(i), 32)))

  val readAfterWrite = (0 until p.instructionLanes).map(i =>
      (readScoreboardRegd(i) & regd(i)) =/= 0.U(32.W) ||
      (readScoreboardComb(i) & comb(i)) =/= 0.U(32.W))
  val writeAfterWrite = (0 until p.instructionLanes).map(i =>
      (rdScoreboard(i) & comb(i)) =/= 0.U(32.W))

  // ---------------------------------------------------------------------------
  // Floating-point Scoreboard
  val rs3Addr = io.inst.map(_.bits.inst(31,27))
  val writesFloatRd = decodedInsts.map(d =>
      (d.isFloat() && !d.floatWritesRd()) ||
      d.rvvWritesFrd()
  )
  val floatReadScoreboard = if (p.enableFloat) { (0 until p.instructionLanes).map(i =>
    MuxOR(decodedInsts(i).floatReadsFloatRs1() || decodedInsts(i).rvvReadsFloatRs1(), UIntToOH(rs1Addr(i), 32)) |
    MuxOR(decodedInsts(i).floatReadsRs2(), UIntToOH(rs2Addr(i), 32)) |
    MuxOR(decodedInsts(i).floatReadsRs3(), UIntToOH(rs3Addr(i), 32))
  ) } else { (0 until p.instructionLanes).map(_ => 0.U(32.W)) }

  val floatRdScoreboard = if (p.enableFloat) { (0 until p.instructionLanes).map(i =>
    MuxOR(writesFloatRd(i), UIntToOH(rdAddr(i), 32))
  ) } else { (0 until p.instructionLanes).map(_ => 0.U(32.W)) }

  val floatScoreboardScan = floatRdScoreboard.scan(0.U(32.W))(_ | _)
  val fcomb = floatScoreboardScan.map(_ | io.fscoreboard.getOrElse(0.U))

  val floatReadAfterWrite = (0 until p.instructionLanes).map(i =>
      (floatReadScoreboard(i) & fcomb(i)) =/= 0.U(32.W))
  val floatWriteAfterWrite = (0 until p.instructionLanes).map(i =>
      (floatRdScoreboard(i) & fcomb(i)) =/= 0.U(32.W))
  // For floating point store
  if (p.enableFloat) {
    io.fbusPortAddr.get := rs2Addr(0)
  }

  // ---------------------------------------------------------------------------
  // Fence interlock
  val fence = decodedInsts.map(x => x.isFency() && (io.mactive || io.lsuActive))

  // ---------------------------------------------------------------------------
  // Slot 0 interlock
  val slot0Interlock = (0 until p.instructionLanes).map(i =>
    if (i == 0) {
      true.B
    } else {
      !decodedInsts(0).forceSlot0Only() && !decodedInsts(i).forceSlot0Only()
    }
  )

  // ---------------------------------------------------------------------------
  // Rvv config interlock rules
  // RVV Load store unit requires valid config state on dispatch.
  val configInvalid = if (p.enableRvv) {
    val configChange = decodedInsts.map(
        x => x.rvv.get.valid && x.rvv.get.bits.isVset())
    configChange.scan(!io.rvvState.get.valid)(_ || _)
  } else {
    Seq.fill(p.instructionLanes)(false.B)
  }

  val rvvConfigInterlock = if (p.enableRvv) {
    val canDispatchRvv = (0 until p.instructionLanes).map(i =>
        !decodedInsts(i).rvv.get.valid || // Don't lock non-rvv
        !decodedInsts(i).rvv.get.bits.isLoadStore() || // Non-LSU can handle change
        !configInvalid(i)  // If config is valid, can dispatch load store
    )
    canDispatchRvv
  } else {
    Seq.fill(p.instructionLanes)(true.B)
  }

  // ---------------------------------------------------------------------------
  // Rvv Vstart
  // If an instruction requires vstart == 0, don't allow that instruction to
  // execute when vstart != 0
  val rvvVstartInterlock = if (p.enableRvv) {
    (0 until p.instructionLanes).map(i => {
        val invalidVstart =
            decodedInsts(i).rvv.get.valid &&
            decodedInsts(i).rvv.get.bits.requireZeroVstart() &&
            (configInvalid(i) || (io.rvvState.get.bits.vstart =/= 0.U))
        !invalidVstart
    })
  } else {
    Seq.fill(p.instructionLanes)(true.B)
  }

  // ---------------------------------------------------------------------------
  // Rvv Interlock
  val rvvInterlock = if (p.enableRvv) {
    val isRvv = decodedInsts.map(x => x.rvv.get.valid)
    val isRvvCount = isRvv.scan(0.U(4.W))(_+_)
    (0 until p.instructionLanes).map(
        i => isRvvCount(i) < io.rvvQueueCapacity.get)
  } else {
    Seq.fill(p.instructionLanes)(true.B)
  }

  // ---------------------------------------------------------------------------
  // LSU Interlock
  val isLsu = decodedInsts.map(x => x.isLsu())
  val isLsuCount = isLsu.scan(0.U(4.W))(_+_)
  val lsuInterlock =
      (0 until p.instructionLanes).map(
          i => isLsuCount(i) < io.lsuQueueCapacity)

  // ---------------------------------------------------------------------------
  // Undef
  // Ensure undef op is only handled in the first slot
  val undefInterlock = (0 until p.instructionLanes).map(i =>
    if (i == 0) { false.B } else { decodedInsts(i).undef })
  io.undefFault := (0 until p.instructionLanes).map(i =>
    if (i == 0) { io.inst(i).valid && decodedInsts(i).undef } else { false.B })

  // ---------------------------------------------------------------------------
  // Core idle
  // Evaluate whether the core is idle.
  // The general method of operation is to check that
  // scoreboards for register files are clear, and no LSU operation is active.
  val coreIdle =
        (
          (io.scoreboard.regd === 0.U) &&
          (io.fscoreboard.getOrElse(0.U) === 0.U) &&
          io.rvvIdle.getOrElse(true.B) &&
          !io.lsuActive
        )

  // ---------------------------------------------------------------------------
  // Single step
  val singleStepInterlock = (0 until p.instructionLanes).map(i =>
    !io.single_step || ((i == 0).B && coreIdle))

  // ---------------------------------------------------------------------------
  // MPAUSE
  val mpauseInterlock = (0 until p.instructionLanes).map(i =>
    !decodedInsts(i).mpause || ((i == 0).B && coreIdle))

  // ---------------------------------------------------------------------------
  // Combine above rules. This variable represents which instructions can be
  // dispatched before in-orderness and back-pressure are considered.
  val canDispatch = (0 until p.instructionLanes).map(i =>
      !io.halted &&          // Don't dispatch if halted
      !io.interlock &&       // Don't dispatch when interlocked
      io.inst(i).valid &&    // Instruction should be valid to dispatch
      !jumped(i) &&          // Don't dispatch after a jump
      !readAfterWrite(i) &&  // Avoid RAW hazards
      !writeAfterWrite(i) && // Avoid WAW hazards
      !floatReadAfterWrite(i) &&  // Avoid RAW hazards
      !floatWriteAfterWrite(i) && // Avoid WAW hazards
      !branchInterlock(i) && // Only branch/alu can be dispatched after a branch
      !fence(i) &&           // Don't dispatch if fence interlocked
      slot0Interlock(i) &&   // Special instructions execute out of slot 0 only
      rvvConfigInterlock(i) &&     // Rvv interlock rules
      rvvVstartInterlock(i) && // Don't dispatch illegal vstart != 0
      // rvvLsuInterlock(i) &&  // Dispatch only one Rvv LsuOp
      lsuInterlock(i) && // Ensure lsu instructions can be dispatched into queue
      rvvInterlock(i) && // Ensure rvv instructions can be dispatched into queue
      !undefInterlock(i) &&     // Ensure undef is only dispatched from first slot
      (i.U < io.retirement_buffer_nSpace) && // Retirement buffer needs space for our slot
      !io.retirement_buffer_trap_pending && // Stall dispatch when a trap is pending
      (!decodedInsts(i).isCsr() || io.retirement_buffer_empty) && // CSRs must wait for ROB to be empty
      singleStepInterlock(i) &&
      mpauseInterlock(i)
  )

  // ---------------------------------------------------------------------------
  // Try-dispatch loop.
  // Back-pressure from execution units gets applied here
  val lastReady = Wire(Vec(p.instructionLanes + 1, Bool()))
  lastReady(0) := true.B // TODO(derekjchow): Set to halted?
  for (i <- 0 until p.instructionLanes) {
    val tryDispatch = lastReady(i) && canDispatch(i)
    val d = decodedInsts(i)

    // -------------------------------------------------------------------------
    // Alu
    val alu = MuxUpTo1H(MakeValid(false.B, AluOp.ADD), Seq(
        // RV32IM
        (d.auipc || d.addi || d.add) -> MakeValid(true.B, AluOp.ADD),
        d.sub                        -> MakeValid(true.B, AluOp.SUB),
        (d.slti || d.slt)            -> MakeValid(true.B, AluOp.SLT),
        (d.sltiu || d.sltu)          -> MakeValid(true.B, AluOp.SLTU),
        (d.xori || d.xor)            -> MakeValid(true.B, AluOp.XOR),
        (d.ori || d.or)              -> MakeValid(true.B, AluOp.OR),
        (d.andi || d.and)            -> MakeValid(true.B, AluOp.AND),
        (d.slli || d.sll)            -> MakeValid(true.B, AluOp.SLL),
        (d.srli || d.srl)            -> MakeValid(true.B, AluOp.SRL),
        (d.srai || d.sra)            -> MakeValid(true.B, AluOp.SRA),
        d.lui                        -> MakeValid(true.B, AluOp.LUI),
        // ZBB
        d.andn                       -> MakeValid(true.B, AluOp.ANDN),
        d.orn                        -> MakeValid(true.B, AluOp.ORN),
        d.xnor                       -> MakeValid(true.B, AluOp.XNOR),
        d.clz                        -> MakeValid(true.B, AluOp.CLZ),
        d.ctz                        -> MakeValid(true.B, AluOp.CTZ),
        d.cpop                       -> MakeValid(true.B, AluOp.CPOP),
        d.max                        -> MakeValid(true.B, AluOp.MAX),
        d.maxu                       -> MakeValid(true.B, AluOp.MAXU),
        d.min                        -> MakeValid(true.B, AluOp.MIN),
        d.minu                       -> MakeValid(true.B, AluOp.MINU),
        d.sextb                      -> MakeValid(true.B, AluOp.SEXTB),
        d.sexth                      -> MakeValid(true.B, AluOp.SEXTH),
        d.rol                        -> MakeValid(true.B, AluOp.ROL),
        d.ror                        -> MakeValid(true.B, AluOp.ROR),
        d.orcb                       -> MakeValid(true.B, AluOp.ORCB),
        d.rev8                       -> MakeValid(true.B, AluOp.REV8),
        d.zexth                      -> MakeValid(true.B, AluOp.ZEXTH),
        d.rori                       -> MakeValid(true.B, AluOp.ROR),
    ))
    io.alu(i).valid := tryDispatch && alu.valid
    io.alu(i).bits.addr := rdAddr(i)
    io.alu(i).bits.op := alu.bits

    // -------------------------------------------------------------------------
    // Bru
    val bru = MuxUpTo1H(MakeValid(false.B, BruOp.JAL), Seq(
        d.jal    -> MakeValid(true.B, BruOp.JAL),
        d.jalr   -> MakeValid(true.B, BruOp.JALR),
        d.beq    -> MakeValid(true.B, BruOp.BEQ),
        d.bne    -> MakeValid(true.B, BruOp.BNE),
        d.blt    -> MakeValid(true.B, BruOp.BLT),
        d.bge    -> MakeValid(true.B, BruOp.BGE),
        d.bltu   -> MakeValid(true.B, BruOp.BLTU),
        d.bgeu   -> MakeValid(true.B, BruOp.BGEU),
        d.ebreak -> MakeValid(true.B, BruOp.EBREAK),
        d.ecall  -> MakeValid(true.B, BruOp.ECALL),
        d.mpause -> MakeValid(true.B, BruOp.MPAUSE),
        d.mret   -> MakeValid(true.B, BruOp.MRET),
        d.wfi    -> MakeValid(true.B, BruOp.WFI),
    ))
    val bru_target = io.inst(i).bits.addr + Mux(
        io.inst(i).bits.inst(2), d.immjal, d.immbr)
    io.bru(i).bits.fwd := io.inst(i).bits.brchFwd
    io.bru(i).bits.op := bru.bits
    io.bru(i).bits.pc := io.inst(i).bits.addr
    io.bru(i).bits.target := bru_target
    io.bru(i).bits.link := rdAddr(i)
    io.bru(i).bits.inst := io.inst(i).bits.inst

    val jalFault = tryDispatch && bru.valid && (bru.bits === BruOp.JAL) && ((bru_target & 0x3.U) =/= 0.U) && !io.branchTaken
    val jalrFault = tryDispatch && bru.valid && (bru.bits === BruOp.JALR) && ((io.jalrTarget(i).data & 0x2.U) =/= 0.U) && !io.branchTaken
    val bxxFault = tryDispatch && bru.valid &&
                  bru.bits.isOneOf(BruOp.BEQ, BruOp.BNE, BruOp.BLT, BruOp.BGE, BruOp.BLTU, BruOp.BGEU) &&
                  ((bru_target & 0x3.U) =/= 0.U) && !io.branchTaken
    io.jalFault(i) := jalFault
    io.jalrFault(i) := jalrFault
    io.bxxFault(i) := bxxFault
    io.bruTarget(i) := io.bru(i).bits.target
    io.bru(i).valid := tryDispatch && bru.valid && !(jalFault || jalrFault || bxxFault)


    // -------------------------------------------------------------------------
    // Mlu
    val mlu = MuxUpTo1H(MakeValid(false.B, MluOp.MUL), Seq(
      d.mul     -> MakeValid(true.B, MluOp.MUL),
      d.mulh    -> MakeValid(true.B, MluOp.MULH),
      d.mulhsu  -> MakeValid(true.B, MluOp.MULHSU),
      d.mulhu   -> MakeValid(true.B, MluOp.MULHU),
    ))
    io.mlu(i).valid := tryDispatch && mlu.valid
    io.mlu(i).bits.addr := rdAddr(i)
    io.mlu(i).bits.op := mlu.bits

    // -------------------------------------------------------------------------
    // Dvu
    val dvu = MuxUpTo1H(MakeValid(false.B, DvuOp.DIV), Seq(
      d.div  -> MakeValid(true.B, DvuOp.DIV),
      d.divu -> MakeValid(true.B, DvuOp.DIVU),
      d.rem  -> MakeValid(true.B, DvuOp.REM),
      d.remu -> MakeValid(true.B, DvuOp.REMU)
    ))
    io.dvu(i).valid := tryDispatch && dvu.valid
    io.dvu(i).bits.addr := rdAddr(i)
    io.dvu(i).bits.op := dvu.bits

    // -------------------------------------------------------------------------
    // Lsu
    val lsu = MuxUpTo1H(MakeValid(false.B, LsuOp.LB), Seq(
      d.lb             -> MakeValid(true.B, LsuOp.LB),
      d.lh             -> MakeValid(true.B, LsuOp.LH),
      d.lw             -> MakeValid(true.B, LsuOp.LW),
      d.lbu            -> MakeValid(true.B, LsuOp.LBU),
      d.lhu            -> MakeValid(true.B, LsuOp.LHU),
      d.sb             -> MakeValid(true.B, LsuOp.SB),
      d.sh             -> MakeValid(true.B, LsuOp.SH),
      d.sw             -> MakeValid(true.B, LsuOp.SW),
      d.wfi            -> MakeValid(true.B, LsuOp.FENCEI),
      d.fencei         -> MakeValid(true.B, LsuOp.FENCEI),
      d.flushat        -> MakeValid(true.B, LsuOp.FLUSHAT),
      d.flushall       -> MakeValid(true.B, LsuOp.FLUSHALL),
      (d.isFloatLoad() || d.isFloatStore()) -> MakeValid(true.B, LsuOp.FLOAT)
    ) ++ Option.when(p.enableRvv) {
      val isRvvLoad = d.rvv.get.valid &&
          (d.rvv.get.bits.opcode === RvvCompressedOpcode.RVVLOAD)
      val isRvvStore = d.rvv.get.valid &&
          (d.rvv.get.bits.opcode === RvvCompressedOpcode.RVVSTORE)
      val mop = d.rvv.get.bits.mop
      Seq(
        (isRvvLoad && (mop === RvvAddressingMode.UNIT_STRIDE))        -> MakeValid(true.B, LsuOp.VLOAD_UNIT),
        (isRvvLoad && (mop === RvvAddressingMode.INDEXED_UNORDERED))  -> MakeValid(true.B, LsuOp.VLOAD_UINDEXED),
        (isRvvLoad && (mop === RvvAddressingMode.STRIDED))            -> MakeValid(true.B, LsuOp.VLOAD_STRIDED),
        (isRvvLoad && (mop === RvvAddressingMode.INDEXED_ORDERED))    -> MakeValid(true.B, LsuOp.VLOAD_OINDEXED),
        (isRvvStore && (mop === RvvAddressingMode.UNIT_STRIDE))       -> MakeValid(true.B, LsuOp.VSTORE_UNIT),
        (isRvvStore && (mop === RvvAddressingMode.INDEXED_UNORDERED)) -> MakeValid(true.B, LsuOp.VSTORE_UINDEXED),
        (isRvvStore && (mop === RvvAddressingMode.STRIDED))           -> MakeValid(true.B, LsuOp.VSTORE_STRIDED),
        (isRvvStore && (mop === RvvAddressingMode.INDEXED_ORDERED))   -> MakeValid(true.B, LsuOp.VSTORE_OINDEXED),
      )
    }.getOrElse(Seq()))
    io.lsu(i).valid := tryDispatch && lsu.valid
    io.lsu(i).bits.store := io.inst(i).bits.inst(5)
    io.lsu(i).bits.addr := rdAddr(i)
    io.lsu(i).bits.op := lsu.bits
    io.lsu(i).bits.pc := io.inst(i).bits.addr
    if (p.enableRvv) {
      io.lsu(i).bits.elemWidth.get := io.inst(i).bits.inst(14,12)
      io.lsu(i).bits.nfields.get := io.inst(i).bits.inst(31,29)
      io.lsu(i).bits.umop.get := io.inst(i).bits.inst(24,20)
    }

    // -------------------------------------------------------------------------
    // Csr
    if (i == 0) {
      val csr = MuxUpTo1H(MakeValid(false.B, CsrOp.CSRRW), Seq(
        d.csrrw -> MakeValid(true.B, CsrOp.CSRRW),
        d.csrrs -> MakeValid(true.B, CsrOp.CSRRS),
        d.csrrc -> MakeValid(true.B, CsrOp.CSRRC)
      ))
      val csr_bits_index = io.inst(0).bits.inst(31,20)
      val (csr_address, csr_address_valid) = CsrAddress.safe(csr_bits_index)
      // Stall reads of vxsat (0x009) and vcsr (0x00F) until the vector unit is
      // idle. Only these CSRs can be modified by in-flight vector instructions
      // (saturating arithmetic sets vxsat; vcsr contains vxsat as a bitfield).
      val isVxsatOrVcsr = csr_bits_index === 0x009.U || csr_bits_index === 0x00F.U
      val rvvIdleOrNotVxsat = io.rvvIdle.getOrElse(true.B) || !isVxsatOrVcsr
      io.csr.valid := tryDispatch && csr.valid && csr_address_valid && (if (p.enableFloat) { io.float.get.ready } else { true.B }) && rvvIdleOrNotVxsat
      io.csr.bits.addr := rdAddr(i)
      io.csr.bits.index := csr_bits_index
      io.csr.bits.rs1 := rs1Addr(i)
      io.csr.bits.op := csr.bits
      io.csrFault(0) := csr.valid && !csr_address_valid && tryDispatch
    } else {
      io.csrFault(i) := false.B
    }

    // -------------------------------------------------------------------------
    // Rvv
    if (p.enableRvv) {
      io.rvv.get(i).valid := tryDispatch && d.rvv.get.valid
      io.rvv.get(i).bits := d.rvv.get.bits
    }

    // -------------------------------------------------------------------------
    // Floating point
    if (p.enableFloat && (i == 0)) {
      io.float.get.valid := tryDispatch && d.float.get.valid && !(d.isFloatLoad() || d.isFloatStore())
      io.float.get.bits := d.float.get.bits
    }

    // -------------------------------------------------------------------------
    // WFI
    // wfi instruction is handled by the bru and lsu.

    // -------------------------------------------------------------------------
    // Fence
    val fenceValid = if (i == 0) { tryDispatch && d.fence } else { false.B }

    // Set next lastReady if dispatched.
    val dispatched = Seq(io.alu(i).fire, io.bru(i).fire, io.mlu(i).fire, io.dvu(i).fire, io.lsu(i).fire) ++
      Option.when(i == 0)(Seq(io.csr.valid, fenceValid)).getOrElse(Seq()) ++
      Option.when(p.enableRvv)(Seq(io.rvv.get(i).fire)).getOrElse(Seq()) ++
      Option.when(p.enableFloat && i == 0)(Seq(io.float.get.fire)).getOrElse(Seq())
    lastReady(i + 1) := dispatched.reduce(_||_)
  }

  for (i <- 0 until p.instructionLanes) {
    io.inst(i).ready := lastReady(i + 1)
  }

  // Fault handling for RVV
  if (p.enableRvv) {
    for (i <- 0 until p.instructionLanes) {
      io.rvvFault.get(i) := (if (i == 0) {
        // Return fault if vstart != 0
        val requireZeroVstart = decodedInsts(i).rvv.get.valid &&
            decodedInsts(0).rvv.get.bits.requireZeroVstart()
        val vStartNotZero = io.rvvState.get.valid &&
            (io.rvvState.get.bits.vstart =/= 0.U)
        io.inst(0).valid && requireZeroVstart && vStartNotZero
      } else {
        false.B
      })
    }
  }

  for (i <- 0 until p.instructionLanes) {
    val d = decodedInsts(i)
    val rs3Addr = io.inst(i).bits.inst(31,27)
    io.rs1Read(i).valid := io.inst(i).fire && (d.readsRs1() || d.jalr)
    io.rs1Read(i).addr := Mux(io.inst(i).bits.inst(0), rs1Addr(i), rs3Addr(i))
    io.rs2Read(i).valid := io.inst(i).fire && d.readsRs2()
    io.rs2Read(i).addr := io.inst(i).bits.inst(24,20)

    // Set immediates
    io.rs1Set(i).valid := io.inst(i).fire && d.rs1Set()
    io.rs1Set(i).value := Mux(d.isCsr(), d.immcsr, io.inst(i).bits.addr)  // Program Counter (PC)
    io.rs2Set(i).valid := io.inst(i).fire && d.rs2Set()
    io.rs2Set(i).value := MuxCase(d.imm12, IndexedSeq((d.auipc || d.lui) -> d.imm20))

    if (p.enableFloat) {
      io.frs1Read.get(i).valid := io.inst(i).fire && d.rvvReadsFloatRs1()
      io.frs1Read.get(i).addr  := rs1Addr(i)
    }

    // Set scalar registers to write
    val rdMark_valid =
        io.alu(i).fire || io.mlu(i).fire || io.dvu(i).fire ||
        io.lsu(i).fire && d.isScalarLoad() ||
        (if (i == 0) { io.csr.valid } else { false.B }) ||
        io.rvv.map(x => x(i).fire && x(i).bits.writesRd()).getOrElse(false.B) ||
        (if (i == 0) { io.float.map(x => x.fire && x.bits.scalar_rd).getOrElse(false.B) } else { false.B }) ||
        (io.bru(i).valid && (io.bru(i).bits.op.isOneOf(BruOp.JAL, BruOp.JALR)) && rdAddr(i) =/= 0.U)

    io.rdMark(i).valid := rdMark_valid
    io.rdMark(i).addr  := rdAddr(i)

    // Set floating point registers to write
    if (p.enableFloat && (i == 0)) {
      val rvvWritesFrd = if (p.enableRvv) { io.rvv.get(0).fire && d.rvvWritesFrd() } else { false.B }

      // Double-check that our slot0 restriction is working: no other lane should fire a write.
      if (p.instructionLanes > 1) {
        val rvvWritesFrdOtherLanes = io.rvv.map(x =>
          (1 until p.instructionLanes).map(j => x(j).fire && x(j).bits.writesFrd())
        ).getOrElse(Seq.fill(p.instructionLanes - 1)(false.B))
        assert(!VecInit(rvvWritesFrdOtherLanes).asUInt.orR)
      }

      val rdMark_flt_valid = (io.float.get.fire && !d.float.get.bits.scalar_rd) ||
                             (io.lsu(0).fire && d.isFloatLoad()) ||
                             rvvWritesFrd
      io.rdMark_flt.get.valid := rdMark_flt_valid
      io.rdMark_flt.get.addr := rdAddr(0)
    }

    // Set RVV vector registers to write
    if (p.enableRvv) {
      val rvvRdMark_valid = io.rvv.get(i).fire && d.rvv.get.bits.writesVectorRegister()
      io.rvvRdMark.get(i).valid := rvvRdMark_valid
      io.rvvRdMark.get(i).addr := d.rvv.get.bits.bits(4,0) // vd
    }

    // Register file bus address port.
    // Pointer chasing bypass if immediate is zero.
    // Load/Store immediate selection keys off bit5, and RET off bit6.
    io.busRead(i).valid := io.lsu(i).valid
    io.busRead(i).bypass := d.inst(31,25) === 0.U &&
        Mux(!d.inst(5) || d.inst(6), d.inst(24,20) === 0.U, d.inst(11,7) === 0.U)

    // SB,SH,SW   0100011
    val storeSelect = d.inst(6,3) === 4.U && d.inst(1,0) === 3.U
    io.busRead(i).immen := !d.flushat
    io.busRead(i).immed := Mux(d.rvv.map(_.valid).getOrElse(false.B),
        0.U,
        Cat(d.imm12(31,5), Mux(storeSelect, d.immst(4,0), d.imm12(4,0))))
  }
}

object DecodeInstruction {
  def apply(p: Parameters, pipeline: Int, addr: UInt, op: UInt,
            csrFrm: UInt): DecodedInstruction = {
    val d = Wire(new DecodedInstruction(p))

    d.inst := op

    // Immediates
    d.imm12  := Cat(Fill(20, op(31)), op(31,20))
    d.imm20  := Cat(op(31,12), 0.U(12.W))
    d.immjal := Cat(Fill(12, op(31)), op(19,12), op(20), op(30,21), 0.U(1.W))
    d.immbr  := Cat(Fill(20, op(31)), op(7), op(30,25), op(11,8), 0.U(1.W))
    d.immcsr := op(19,15)
    d.immst  := Cat(Fill(20, op(31)), op(31,25), op(11,7))

    // RV32I
    d.lui   := op === BitPat("b????????????????????_?????_0110111")
    d.auipc := op === BitPat("b????????????????????_?????_0010111")
    d.jal   := op === BitPat("b????????????????????_?????_1101111")
    d.jalr  := op === BitPat("b????????????_?????_000_?????_1100111")
    d.beq   := op === BitPat("b???????_?????_?????_000_?????_1100011")
    d.bne   := op === BitPat("b???????_?????_?????_001_?????_1100011")
    d.blt   := op === BitPat("b???????_?????_?????_100_?????_1100011")
    d.bge   := op === BitPat("b???????_?????_?????_101_?????_1100011")
    d.bltu  := op === BitPat("b???????_?????_?????_110_?????_1100011")
    d.bgeu  := op === BitPat("b???????_?????_?????_111_?????_1100011")
    d.csrrw := op === BitPat("b????????????_?????_?01_?????_1110011")
    d.csrrs := op === BitPat("b????????????_?????_?10_?????_1110011")
    d.csrrc := op === BitPat("b????????????_?????_?11_?????_1110011")
    d.lb    := op === BitPat("b????????????_?????_000_?????_0000011")
    d.lh    := op === BitPat("b????????????_?????_001_?????_0000011")
    d.lw    := op === BitPat("b????????????_?????_010_?????_0000011")
    d.lbu   := op === BitPat("b????????????_?????_100_?????_0000011")
    d.lhu   := op === BitPat("b????????????_?????_101_?????_0000011")
    d.sb    := op === BitPat("b????????????_?????_000_?????_0100011")
    d.sh    := op === BitPat("b????????????_?????_001_?????_0100011")
    d.sw    := op === BitPat("b????????????_?????_010_?????_0100011")
    d.fence := op === BitPat("b0000_????_????_00000_000_00000_0001111")
    d.addi  := op === BitPat("b????????????_?????_000_?????_0010011")
    d.slti  := op === BitPat("b????????????_?????_010_?????_0010011")
    d.sltiu := op === BitPat("b????????????_?????_011_?????_0010011")
    d.xori  := op === BitPat("b????????????_?????_100_?????_0010011")
    d.ori   := op === BitPat("b????????????_?????_110_?????_0010011")
    d.andi  := op === BitPat("b????????????_?????_111_?????_0010011")
    d.slli  := op === BitPat("b0000000_?????_?????_001_?????_0010011")
    d.srli  := op === BitPat("b0000000_?????_?????_101_?????_0010011")
    d.srai  := op === BitPat("b0100000_?????_?????_101_?????_0010011")
    d.add   := op === BitPat("b0000000_?????_?????_000_?????_0110011")
    d.sub   := op === BitPat("b0100000_?????_?????_000_?????_0110011")
    d.slt   := op === BitPat("b0000000_?????_?????_010_?????_0110011")
    d.sltu  := op === BitPat("b0000000_?????_?????_011_?????_0110011")
    d.xor   := op === BitPat("b0000000_?????_?????_100_?????_0110011")
    d.or    := op === BitPat("b0000000_?????_?????_110_?????_0110011")
    d.and   := op === BitPat("b0000000_?????_?????_111_?????_0110011")
    d.sll   := op === BitPat("b0000000_?????_?????_001_?????_0110011")
    d.srl   := op === BitPat("b0000000_?????_?????_101_?????_0110011")
    d.sra   := op === BitPat("b0100000_?????_?????_101_?????_0110011")

    // RV32M
    d.mul     := op === BitPat("b0000_001_?????_?????_000_?????_0110011")
    d.mulh    := op === BitPat("b0000_001_?????_?????_001_?????_0110011")
    d.mulhsu  := op === BitPat("b0000_001_?????_?????_010_?????_0110011")
    d.mulhu   := op === BitPat("b0000_001_?????_?????_011_?????_0110011")
    d.div     := op === BitPat("b0000_001_?????_?????_100_?????_0110011")
    d.divu    := op === BitPat("b0000_001_?????_?????_101_?????_0110011")
    d.rem     := op === BitPat("b0000_001_?????_?????_110_?????_0110011")
    d.remu    := op === BitPat("b0000_001_?????_?????_111_?????_0110011")

    // ZBB
    d.andn  := op === BitPat("b0100000_?????_?????_111_?????_0110011")
    d.orn   := op === BitPat("b0100000_?????_?????_110_?????_0110011")
    d.xnor  := op === BitPat("b0100000_?????_?????_100_?????_0110011")
    d.clz   := op === BitPat("b0110000_00000_?????_001_?????_0010011")
    d.ctz   := op === BitPat("b0110000_00001_?????_001_?????_0010011")
    d.cpop  := op === BitPat("b0110000_00010_?????_001_?????_0010011")
    d.max   := op === BitPat("b0000101_?????_?????_110_?????_0110011")
    d.maxu  := op === BitPat("b0000101_?????_?????_111_?????_0110011")
    d.min   := op === BitPat("b0000101_?????_?????_100_?????_0110011")
    d.minu  := op === BitPat("b0000101_?????_?????_101_?????_0110011")
    d.sextb := op === BitPat("b0110000_00100_?????_001_?????_0010011")
    d.sexth := op === BitPat("b0110000_00101_?????_001_?????_0010011")
    d.rol   := op === BitPat("b0110000_?????_?????_001_?????_0110011")
    d.ror   := op === BitPat("b0110000_?????_?????_101_?????_0110011")
    d.orcb  := op === BitPat("b0010100_00111_?????_101_?????_0010011")
    d.rev8  := op === BitPat("b0110100_11000_?????_101_?????_0010011")
    d.zexth := op === BitPat("b0000100_00000_?????_100_?????_0110011")
    d.rori  := op === BitPat("b0110000_?????_?????_101_?????_0010011")

    // [extensions] Core controls.
    d.ebreak := op === BitPat("b000000000001_00000_000_00000_11100_11")
    d.ecall  := op === BitPat("b000000000000_00000_000_00000_11100_11")
    d.mpause := op === BitPat("b000010000000_00000_000_00000_11100_11")
    d.mret   := op === BitPat("b001100000010_00000_000_00000_11100_11")
    d.wfi    := op === BitPat("b000100000101_00000_000_00000_11100_11")

    // Fences.
    d.fencei   := op === BitPat("b0000_0000_0000_00000_001_00000_0001111")
    d.flushat  := op === BitPat("b0010?_??_00000_?????_000_00000_11101_11") && op(19,15) =/= 0.U
    d.flushall := op === BitPat("b0010?_??_00000_00000_000_00000_11101_11")


    if (p.enableFloat) {
      val float = FloatInstruction.decode(op, addr)
      val floatValid = float.valid && float.bits.validate_csrfrm(csrFrm)
      d.float.get := MakeValid(floatValid, float.bits)
    }

    // Stub out decoder state not used beyond pipeline0.
    if (pipeline > 0) {
      d.csrrw := false.B
      d.csrrs := false.B
      d.csrrc := false.B

      d.div := false.B
      d.divu := false.B
      d.rem := false.B
      d.remu := false.B

      d.ebreak := false.B
      d.ecall  := false.B
      d.mpause := false.B
      d.mret   := false.B
      d.wfi    := false.B

      d.fence    := false.B
      d.fencei   := false.B
      d.flushat  := false.B
      d.flushall := false.B

      if (p.enableFloat) {
        d.float.get := MakeInvalid(new FloatInstruction)
      }
    }

    if (p.enableRvv) {
      d.rvv.get := RvvCompressedInstruction.from_uncompressed(op, addr)
    }

    // Generate the undefined opcode.
    val decoded = Cat(d.lui, d.auipc,
                      d.jal, d.jalr,
                      d.beq, d.bne, d.blt, d.bge, d.bltu, d.bgeu,
                      d.csrrw, d.csrrs, d.csrrc,
                      d.lb, d.lh, d.lw, d.lbu, d.lhu,
                      d.sb, d.sh, d.sw, d.fence,
                      d.addi, d.slti, d.sltiu, d.xori, d.ori, d.andi,
                      d.add, d.sub, d.slt, d.sltu, d.xor, d.or, d.and, d.xnor, d.orn, d.andn,
                      d.slli, d.srli, d.srai, d.sll, d.srl, d.sra,
                      d.mul, d.mulh, d.mulhsu, d.mulhu,
                      d.div, d.divu, d.rem, d.remu,
                      d.clz, d.ctz, d.cpop, d.min, d.minu, d.max, d.maxu,
                      d.sextb, d.sexth, d.zexth,
                      d.rol, d.ror, d.orcb, d.rev8, d.rori,
                      d.ebreak, d.ecall, d.wfi,
                      d.mpause, d.mret, d.fencei, d.flushat, d.flushall,
                      d.rvv.map(_.valid).getOrElse(false.B),
                      d.float.map(_.valid).getOrElse(false.B))

    d.undef := decoded === 0.U

    d
  }
}
