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

package coralnpu

import chisel3._
import chisel3.util._
import common._

class RetirementBufferIO(p: Parameters) extends Bundle {
  val inst            = Input(Vec(p.instructionLanes, Decoupled(new FetchInstruction(p))))
  val targets         = Input(Vec(p.instructionLanes, UInt(p.programCounterBits.W)))
  val jalrTargets     = Input(Vec(p.instructionLanes, UInt(p.programCounterBits.W)))
  val jump            = Input(Vec(p.instructionLanes, Bool()))
  val branch          = Input(Vec(p.instructionLanes, Bool()))
  val storeComplete   = Input(Valid(UInt(p.programCounterBits.W)))
  val writeAddrScalar = Input(Vec(p.instructionLanes, new RegfileWriteAddrIO(p)))
  val writeDataScalar = Input(Vec(p.instructionLanes + 2, Valid(new RegfileWriteDataIO(p))))
  val writeAddrFloat  = Option.when(p.enableFloat)(Input(new RegfileWriteAddrIO(p)))
  val writeDataFloat  = Option.when(p.enableFloat)(Input(Vec(2, Valid(new RegfileWriteDataIO(p)))))
  val writeAddrVector =
    Option.when(p.enableRvv)(Input(Vec(p.instructionLanes, new RegfileWriteAddrIO(p))))
  val writeDataVector =
    Option.when(p.enableRvv)(
      Input(Vec(p.rvvRetireLanes, Valid(new VectorWriteDataIO(p))))
    )
  val enqPtr      = Output(UInt(log2Ceil(p.retirementBufferSize).W))
  val fault       = Input(Valid(new FaultManagerOutput(p)))
  val nSpace      = Output(UInt(log2Ceil(p.retirementBufferSize + 1).W))
  val nRetired    = Output(UInt(log2Ceil(p.retirementLanes + 1).W))
  val empty       = Output(Bool())
  val trapPending = Output(Bool())
  val trapRetired = Output(Bool())
  val isVector    = Option.when(p.enableRvv)(Input(Vec(p.instructionLanes, Bool())))
  val clearVstart = Option.when(p.enableRvv)(Output(Bool()))
  val debug       = Option.when(p.shouldExposeDebugPorts)(Output(new RetirementBufferDebugIO(p)))
}

/** The Retirement Buffer manages the lifecycle of instructions from dispatch to retirement.
  *
  * Instruction Lifecycle:
  *   - Dispatched: The instruction is enqueued into the buffer upon dispatch.
  *   - Completed: All side effects (register writes, store completions, or faults) are committed to
  *     the architectural state.
  *   - Retired: The final state. Instructions are dequeued from the buffer in-order when they and
  *     all preceding instructions are completed.
  */
class RetirementBuffer(p: Parameters, mini: Boolean = false) extends Module {
  val io            = IO(new RetirementBufferIO(p))
  val idxWidth      = p.retirementBufferIdxWidth
  val noWriteRegIdx = ~0.U(idxWidth.W)
  val storeRegIdx   = (noWriteRegIdx - 1.U)
  class Instruction extends Bundle {
    val addr = UInt(p.programCounterBits.W)                       // Program counter address
    val inst = if (mini) UInt(0.W) else UInt(p.instructionBits.W) // Instruction bits
    val idx  = UInt(idxWidth.W)                                   // Register Index
    val trap          = Bool() // Instruction causing a trap to occur.
    val isControlFlow = Bool() // True if instruction is a jump or branch.
    val isBranch      = Bool()
    val isVector      = Bool()
    val resetsVstart  = Bool()
    // Target storage removed in favor of linkOk check for area optimization
    val linkOk   = Bool()
    val isEcall  = Bool()
    val isMpause = Bool()
  }

  val storeComplete = Pipe(io.storeComplete)

  val bufferSize = p.retirementBufferSize
  assert(bufferSize >= p.instructionLanes)
  assert(bufferSize >= p.retirementLanes)
  assert(p.retirementLanes >= io.writeDataScalar.length)
  // Construct a circular buffer of `bufferSize`, that can enqueue and dequeue `bufferSize` elements
  // per cycle. This will be used to store information about dispatched instructions.
  val instBuffer = Module(
    new CircularBufferMulti(
      new Instruction,
      /* needs to be at least writeDataScalar count */ bufferSize,
      /* chosen sort-of-arbitrarily */ bufferSize
    )
  )
  io.empty := instBuffer.io.nEnqueued === 0.U
  // Check that we see no instructions fire after the first non-fire.
  val instFires  = io.inst.map(_.fire)
  val seenFalseV = (instFires.scanLeft(false.B) { (acc, curr) => acc || !curr }).drop(1)
  assert(
    !(seenFalseV.zip(instFires).map({ case (seenFalse, fire) => seenFalse && fire }).reduce(_ | _))
  )

  val decodeFaultValid = (io.fault.valid && io.fault.bits.decode)
  // Valid fault, no fire, also not a load/store: those faults should be handled purely in the update stage
  val noFire0Fault = (io.fault.valid && !io
    .inst(0)
    .fire && (io.fault.bits.mcause =/= 7.U) && (io.fault.bits.mcause =/= 5.U))
  val faultPc = io.fault.bits.mepc

  // Mini-mode optimization state: Track the expected PC of the next instruction across dispatch cycles.
  // These are used to verify control flow continuity (linkOk) for the first instruction of a dispatch group.
  // If the fetcher sends an instruction that doesn't match the expected target (e.g. due to mis-prediction
  // in the fetcher), linkOk will be false, eventually triggering a trap.
  val regLastTarget   = RegInit(0.U(p.programCounterBits.W))
  val regLastAddr     = RegInit(0.U(p.programCounterBits.W))
  val regLastIsBranch = RegInit(false.B)
  val regAfterFlush   = RegInit(true.B)

  // Create Instruction wires out of io.inst + io.writeAddrScalar, and align.
  def dispatch(
    finst: FetchInstruction,
    scalarAddr: RegfileWriteAddrIO,
    floatAddr: Option[RegfileWriteAddrIO],
    vectorAddr: Option[RegfileWriteAddrIO],
    resetsVstart: Bool,
    isJump: Bool,
    isBranch: Bool,
    linkOk: Bool,
    isFault: Bool
  ): Instruction = {
    val floatValid = floatAddr.map(_.valid).getOrElse(false.B)
    val fAddr      = floatAddr.map(_.addr).getOrElse(0.U)

    val sValid = scalarAddr.valid
    val sAddr  = scalarAddr.addr

    val vectorValid = vectorAddr.map(_.valid).getOrElse(false.B)
    val vAddr       = vectorAddr.map(_.addr).getOrElse(0.U)

    // Store detection per RISC-V spec section 7.3 Table 11
    // Scalar store: opcode 0x23
    val scalarStore = (finst.inst(6, 0) === "b0100011".U)
    val width       = finst.inst(14, 12)
    // Float store: opcode 0x27 with width ∈ {001, 010, 011, 100}
    // These are 16b, 32b, 64b, 128b FP stores
    val floatStore = if (p.enableFloat) {
      (finst.inst(6, 0) === "b0100111".U) &&
      (width === "b001".U || width === "b010".U ||
        width === "b011".U || width === "b100".U)
    } else {
      false.B
    }
    // Vector store: opcode 0x27 with width ∈ {000, 101, 110, 111}
    // These are 8b, 16b, 32b, 64b element vector stores
    val vectorStore = if (p.enableRvv) {
      (finst.inst(6, 0) === "b0100111".U) &&
      (width === "b000".U || width === "b101".U ||
        width === "b110".U || width === "b111".U)
    } else {
      false.B
    }
    val store = scalarStore || floatStore || vectorStore

    val instr = Wire(new Instruction)
    instr.addr := finst.addr
    if (mini) {
      instr.inst := 0.U
    } else {
      instr.inst := finst.inst
    }
    instr.idx := MuxCase(
      noWriteRegIdx,
      Seq(
        floatValid                -> (fAddr +& p.floatRegfileBaseAddr.U),
        (vectorValid)             -> (vAddr +& p.rvvRegfileBaseAddr.U),
        (sValid && sAddr =/= 0.U) -> sAddr,
        store                     -> storeRegIdx
      )
    )
    instr.trap          := isFault
    instr.isControlFlow := isJump || isBranch
    instr.isBranch      := isBranch
    instr.isVector      := vectorValid || vectorStore
    instr.resetsVstart  := resetsVstart
    instr.linkOk        := linkOk
    instr.isEcall       := (finst.inst === 0x73.U)
    instr.isMpause      := (finst.inst === 0x08000073.U)
    instr
  }

  def fault(
    finst: FetchInstruction,
    scalarAddr: RegfileWriteAddrIO,
    floatAddr: Option[RegfileWriteAddrIO],
    vectorAddr: Option[RegfileWriteAddrIO],
    resetsVstart: Bool,
    isJump: Bool,
    isBranch: Bool
  ): Instruction = {
    // A faulting instruction still needs properties like isControlFlow and idx
    // to correctly handle side effects (like JAL return addresses) and debug reporting.
    val instr = dispatch(
      finst,
      scalarAddr,
      floatAddr,
      vectorAddr,
      resetsVstart,
      isJump,
      isBranch,
      linkOk = true.B,
      isFault = true.B
    )
    instr.addr := io.fault.bits.mepc
    // mtval only contains instruction bits for illegal instruction faults (mcause == 2).
    // For other faults (like misaligned address), it contains addresses.
    if (mini) {
      instr.inst := 0.U
    } else {
      instr.inst := Mux(io.fault.bits.mcause === 2.U, io.fault.bits.mtval, finst.inst)
    }
    // Re-calculate linkOk for the fault PC against the last retired instruction's target.
    instr.linkOk := (instr.addr === regLastTarget) || (regLastIsBranch && instr.addr === regLastAddr + 4.U)
    instr
  }

  def calculateTarget(
    inst: UInt,
    addr: UInt,
    isBranch: Bool,
    jalrTarget: UInt,
    target: UInt
  ): UInt = {
    val isJalr            = (inst(6, 0) === "b1100111".U)
    val isJal             = (inst(6, 0) === "b1101111".U)
    val jalrTargetAligned = Cat(jalrTarget(p.programCounterBits - 1, 1), 0.U(1.W))
    Mux(
      isJalr,
      jalrTargetAligned,
      Mux(isJal || isBranch, target, addr + 4.U)
    )
  }

  val insts = (0 until p.instructionLanes).map(i => {
    val isDecodeFault = decodeFaultValid && (faultPc === io.inst(i).bits.addr)
    val isNoFireFault = (i == 0).B && noFire0Fault

    val linkOk = if (i == 0) {
      regAfterFlush || (io
        .inst(0)
        .bits
        .addr === regLastTarget) || (regLastIsBranch && io.inst(0).bits.addr === regLastAddr + 4.U)
    } else {
      val prevTarget = calculateTarget(
        io.inst(i - 1).bits.inst,
        io.inst(i - 1).bits.addr,
        io.branch(i - 1),
        io.jalrTargets(i - 1),
        io.targets(i - 1)
      )
      (io.inst(i).bits.addr === prevTarget) || (io.branch(i - 1) && io
        .inst(i)
        .bits
        .addr === io.inst(i - 1).bits.addr + 4.U)
    }

    val fAddr = io.writeAddrFloat.filter(_ => i == 0)
    val vAddr = io.writeAddrVector.map(_(i))
    val isVec = io.isVector.map(_(i)).getOrElse(false.B)
    Mux(
      isNoFireFault,
      fault(io.inst(i).bits, io.writeAddrScalar(i), fAddr, vAddr, isVec, io.jump(i), io.branch(i)),
      dispatch(
        io.inst(i).bits,
        io.writeAddrScalar(i),
        fAddr,
        vAddr,
        isVec,
        io.jump(i),
        io.branch(i),
        linkOk,
        isDecodeFault
      )
    )
  })

  // Update regLast state based on the last fired instruction
  val hasFire     = instFires.reduce(_ | _)
  val targetsList = (0 until p.instructionLanes).map(i => {
    calculateTarget(
      io.inst(i).bits.inst,
      io.inst(i).bits.addr,
      io.branch(i),
      io.jalrTargets(i),
      io.targets(i)
    )
  })
  val addrList   = io.inst.map(_.bits.addr)
  val branchList = io.branch

  regLastTarget := Mux(hasFire, PriorityMux(instFires.reverse, targetsList.reverse), regLastTarget)
  regLastAddr   := Mux(hasFire, PriorityMux(instFires.reverse, addrList.reverse), regLastAddr)
  regLastIsBranch := Mux(
    hasFire,
    PriorityMux(instFires.reverse, branchList.reverse),
    regLastIsBranch
  )

  val instsWithWriteFired = PopCount(io.inst.map(_.fire))
  instBuffer.io.enqValid := instsWithWriteFired +& (decodeFaultValid || noFire0Fault)
  io.nSpace              := instBuffer.io.nSpace

  for (i <- 0 until p.instructionLanes) {
    instBuffer.io.enqData(i) := insts(i)
  }
  for (i <- p.instructionLanes until bufferSize) {
    instBuffer.io.enqData(i) := 0.U.asTypeOf(instBuffer.io.enqData(i))
  }

  class InstructionUpdate extends Bundle {
    val result = if (mini) UInt(0.W) else UInt(dataWidth.W)
    val trap   = Bool()
    val cfDone = Bool()
  }

  class VectorWrite extends Bundle {
    val data = UInt(p.rvvVlen.W)
    val idx  = UInt(log2Ceil(p.rvvRegCount).W)
  }

  // Maintain a re-order buffer of instruction completion result.
  // The order and alignment of these buffers should correspond to the
  // output of `instBuffer`.
  val dataWidth    = if (mini) 0 else (if (p.enableRvv) p.lsuDataBits else 32)
  val resultBuffer = RegInit(VecInit(Seq.fill(bufferSize)(MakeInvalid(new InstructionUpdate))))

  val accEnqPtr = RegInit(0.U(log2Ceil(bufferSize).W))
  val accDeqPtr = RegInit(0.U(log2Ceil(bufferSize).W))
  io.enqPtr := accEnqPtr
  val vectorWriteAccumulator = Option.when(!mini && p.enableRvv)(
    RegInit(VecInit.fill(bufferSize)(VecInit.fill(8)(0.U.asTypeOf(Valid(new VectorWrite)))))
  )

  val vectorAccumulatorNext = Option.when(!mini && p.enableRvv)(
    Wire(Vec(bufferSize, Vec(8, Valid(new VectorWrite))))
  )
  val debugVectorWrites = Option.when(!mini && p.enableRvv)(
    Wire(Vec(bufferSize, Vec(8, Valid(new VectorWrite))))
  )
  if (!mini && p.enableRvv) {
    vectorAccumulatorNext.get := vectorWriteAccumulator.get
    debugVectorWrites.get     := vectorWriteAccumulator.get
  }

  // Compute update based on register writeback.
  // Note: The shift when committing instructions will be handled in a later block.
  val resultUpdate = Wire(Vec(bufferSize, Valid(new InstructionUpdate)))

  for (i <- 0 until bufferSize) {
    val bufferEntry = instBuffer.io.dataOut(i)
    // Check if this entry is an operation that doesn't require a register write, but is not a store.
    val nonWritingInstr = bufferEntry.idx === noWriteRegIdx
    val storeInstr      = bufferEntry.idx === storeRegIdx

    // Check which incoming (scalar,float) write port matches this entry's needed address.
    val scalarWriteIdxMap =
      io.writeDataScalar.map(x => x.valid && (x.bits.addr === bufferEntry.idx))
    val floatWriteIdxMap = io.writeDataFloat
      .map(y =>
        y.map(x =>
          x.valid && ((x.bits.addr +& p.floatRegfileBaseAddr.U) ===
            bufferEntry.idx)
        )
      )
      .getOrElse(Seq(false.B))
    val tagWidth = log2Ceil(bufferSize)
    val pIdx     = if (bufferSize > 1) (accDeqPtr +& i.U)(tagWidth - 1, 0) else 0.U

    val vectorWriteIdxMap = io.writeDataVector
      .map(y =>
        y.map(x =>
          x.valid && (
            (bufferEntry.isVector && !storeInstr && (x.bits.rob_tag === pIdx)) ||
              (!bufferEntry.isVector && ((x.bits.addr +& p.rvvRegfileBaseAddr.U) === bufferEntry.idx))
          )
        )
      )
      .getOrElse(Seq(false.B))
    // Check if this entry is the faulting instruction
    val isRvvFault =
      if (p.enableRvv) io.fault.valid && io.fault.bits.is_rvv.getOrElse(false.B) else false.B
    val rvvTagMatch =
      if (p.enableRvv) (io.fault.bits.rob_tag.getOrElse(0.U) === pIdx) else false.B
    val faultingInstr = io.fault.valid && Mux(isRvvFault, rvvTagMatch, bufferEntry.addr === faultPc)
    // The entry is active if it's validly enqueued.
    val validBufferEntry = (i.U < instBuffer.io.nEnqueued)

    // Find the index of the first write port that provides the needed data.
    val scalarWriteIdx = PriorityEncoder(scalarWriteIdxMap)
    val floatWriteIdx  = PriorityEncoder(floatWriteIdxMap)
    val vectorWriteIdx = PriorityEncoder(vectorWriteIdxMap)

    val vectorReady = io.writeDataVector
      .map(y =>
        y.zip(vectorWriteIdxMap)
          .map({ case (port, matchBool) =>
            matchBool && port.bits.last_uop_valid
          })
          .reduce(_ | _)
      )
      .getOrElse(false.B)

    if (!mini && p.enableRvv) {
      val nextEntry = Wire(Vec(8, Valid(new VectorWrite)))

      val portMatches = Wire(Vec(p.rvvRetireLanes, Bool()))
      val portTargets = Wire(Vec(p.rvvRetireLanes, UInt(3.W)))

      for (j <- 0 until p.rvvRetireLanes) {
        val port = io.writeDataVector.get(j)
        portMatches(j) := vectorWriteIdxMap(j)
        val absAddr = port.bits.addr +& p.rvvRegfileBaseAddr.U
        val offset  = absAddr - bufferEntry.idx
        portTargets(j) := offset(2, 0)
      }

      for (k <- 0 until 8) {
        val hits  = Wire(Vec(p.rvvRetireLanes, Bool()))
        val datas = Wire(Vec(p.rvvRetireLanes, UInt(p.rvvVlen.W)))
        val idxs  = Wire(Vec(p.rvvRetireLanes, UInt(5.W)))

        for (j <- 0 until p.rvvRetireLanes) {
          val port = io.writeDataVector.get(j)
          hits(j)  := portMatches(j) && (portTargets(j) === k.U)
          datas(j) := port.bits.data.getOrElse(0.U)
          idxs(j)  := port.bits.addr
        }

        val anyHit = hits.asUInt.orR
        nextEntry(k).valid     := Mux(anyHit, true.B, vectorWriteAccumulator.get(pIdx)(k).valid)
        nextEntry(k).bits.data := Mux(
          anyHit,
          PriorityMux(hits, datas),
          vectorWriteAccumulator.get(pIdx)(k).bits.data
        )
        nextEntry(k).bits.idx := Mux(
          anyHit,
          PriorityMux(hits, idxs),
          vectorWriteAccumulator.get(pIdx)(k).bits.idx
        )
      }
      vectorAccumulatorNext
        .get(pIdx) := Mux(validBufferEntry, nextEntry, vectorWriteAccumulator.get(pIdx))
      debugVectorWrites
        .get(pIdx) := Mux(validBufferEntry, nextEntry, vectorWriteAccumulator.get(pIdx))
    }

    // If the entry is active and its data dependency is met (or it has no dependency)...
    // Special care here for vector, as multiple instructions are allowed to be dispatched for the same destination register.
    // This differs from how the scalar/float scoreboards restrict dispatch.
    val dataReady = (scalarWriteIdxMap.reduce(_ | _) || floatWriteIdxMap.reduce(
      _ | _
    ) || vectorReady || nonWritingInstr || (storeInstr && storeComplete.valid && storeComplete.bits === bufferEntry.addr))
    val isControlFlow = bufferEntry.isControlFlow
    val isBranch      = bufferEntry.isBranch
    // For the last entry in the buffer, we can't see the next instruction yet (it hasn't been enqueued or wrapped visibly).
    // So we treat nextValid as false.
    val nextValid = if (i < bufferSize - 1) ((i.U +& 1.U) < instBuffer.io.nEnqueued) else false.B
    val nextAddr  = if (i < bufferSize - 1) instBuffer.io.dataOut(i + 1).addr else 0.U
    val nextAddrValid = nextValid || noFire0Fault || io.inst(0).valid

    val lane0LinkOk = regAfterFlush || (io
      .inst(0)
      .bits
      .addr === regLastTarget) || (regLastIsBranch && io.inst(0).bits.addr === regLastAddr + 4.U)
    val faultLinkOk = regAfterFlush ||
      (io.fault.bits.mepc === regLastTarget) || (regLastIsBranch && io.fault.bits.mepc === regLastAddr + 4.U)
    val fallthrough = bufferEntry.addr + 4.U

    // Check next instruction's linkOk bit to verify control flow continuity.
    // If we are at the end of the buffer (i == bufferSize-1), we check the incoming instruction (lane 0) or fault.
    // Note: We use a Scala conditional to prevent generating hardware for out-of-bounds access.
    val nextLinkOk = if (i < bufferSize - 1) instBuffer.io.dataOut(i + 1).linkOk else true.B

    val targetMatch = MuxCase(
      true.B,
      Seq(
        (nextValid && (i.U < (bufferSize - 1).U)) -> nextLinkOk,
        noFire0Fault                              -> faultLinkOk,
        io.inst(0).valid                          -> lane0LinkOk
      )
    )
    val fallthroughMatch = (MuxCase(
      nextAddr,
      Seq(
        nextValid        -> nextAddr,
        noFire0Fault     -> io.fault.bits.mepc,
        io.inst(0).valid -> io.inst(0).bits.addr
      )
    ) === fallthrough)

    val cfMatch = nextAddrValid && (targetMatch || (isBranch && fallthroughMatch))
    // CF instructions wait for the next instruction to be valid.
    // They are ready if matched, or if they mismatch (which leads to trap).
    val cfReady = !isControlFlow || nextAddrValid

    // Update state:
    // We update valid (Data Done) if previously done, or if new data arrives.
    // We update cfDone if previously done, or if new CF check passes.
    val prevDataDone = resultBuffer(i).valid
    val prevCfDone   = resultBuffer(i).valid && resultBuffer(i).bits.cfDone

    // Only allow new data/cf updates if the entry is actually valid in instBuffer
    val newCfDone   = validBufferEntry && cfReady
    val isMpause    = bufferEntry.isMpause
    val currentTrap = resultBuffer(
      i
    ).bits.trap || faultingInstr || (validBufferEntry && bufferEntry.trap) || (validBufferEntry && isControlFlow && newCfDone && (!cfMatch || noFire0Fault) && !isMpause)

    val trapReady =
      bufferEntry.trap || (isControlFlow && newCfDone) || (faultingInstr && (!bufferEntry.isVector || isRvvFault))
    val newDataDone = validBufferEntry && !prevDataDone && (dataReady || trapReady)

    val currentDataDone = prevDataDone || newDataDone
    val currentCfDone   = prevCfDone || newCfDone

    // If updated, mark this buffer entry as complete for the next cycle.
    resultUpdate(i).valid       := currentDataDone
    resultUpdate(i).bits.cfDone := currentCfDone
    resultUpdate(i).bits.result := 0.U
    resultUpdate(i).bits.trap   := currentTrap

    if (!mini) {
      // Select the actual data from the winning write port.
      val writeDataScalar = io.writeDataScalar(scalarWriteIdx).bits.data
      val writeDataFloat  = io.writeDataFloat.map(x => x(floatWriteIdx).bits.data).getOrElse(0.U)
      val writeDataVector =
        io.writeDataVector.map(x => x(vectorWriteIdx).bits.data.getOrElse(0.U)).getOrElse(0.U)

      // Select the correct write-back data to store, if updated (FP has priority).
      val sdata =
        if (p.enableRvv) Cat(0.U((p.lsuDataBits - 32).W), writeDataScalar) else writeDataScalar
      val fdata =
        if (p.enableRvv) Cat(0.U((p.lsuDataBits - 32).W), writeDataFloat) else writeDataFloat

      // If we are trapping, we shouldn't be writing back.
      // This masks the writeback data in the trace.
      val result = Mux(
        newDataDone,
        MuxCase(
          0.U,
          Seq(
            floatWriteIdxMap.reduce(_ | _)  -> fdata,
            vectorWriteIdxMap.reduce(_ | _) -> writeDataVector,
            scalarWriteIdxMap.reduce(_ | _) -> sdata
          )
        ),
        resultBuffer(i).bits.result
      )

      val allowWritebackTrap = validBufferEntry && isControlFlow && newCfDone && noFire0Fault
      resultUpdate(i).bits.result := Mux(currentTrap && !allowWritebackTrap, 0.U, result)
    }
  }

  val hasTrap = resultUpdate.map(x => x.valid && x.bits.trap).reduce(_ || _)

  val deqReady = {
    val blockRetire = VecInit
      .tabulate(p.retirementLanes) { i =>
        if (i == 0) {
          !resultUpdate(i).valid || !resultUpdate(i).bits.cfDone
        } else {
          !resultUpdate(i).valid || !resultUpdate(i).bits.cfDone || resultUpdate(i - 1).bits.trap
        }
      }
      .asUInt
    Ctz(blockRetire)
  }

  instBuffer.io.deqReady := deqReady

  val trapRetired = {
    val laneReady = VecInit(
      resultUpdate.take(p.retirementLanes).map(x => x.valid && x.bits.cfDone)
    )
    // This does not consider previous traps because we're going to reduce.
    val laneCanTrap = laneReady.scanLeft(true.B)(_ && _).drop(1)
    VecInit
      .tabulate(p.retirementLanes) { i =>
        laneCanTrap(i) && resultUpdate(i).bits.trap
      }
      .reduce(_ || _)
  }

  instBuffer.io.flush := trapRetired
  when(trapRetired) {
    regAfterFlush := true.B
  }.elsewhen(hasFire) {
    regAfterFlush := false.B
  }

  if (p.enableRvv) {
    accEnqPtr := Mux(trapRetired, 0.U, accEnqPtr + instBuffer.io.enqValid)
    accDeqPtr := Mux(trapRetired, 0.U, accDeqPtr + deqReady)

    val clearVstart = VecInit(
      (0 until p.retirementLanes).map { i =>
        (i.U < deqReady) && !resultUpdate(i).bits.trap && instBuffer.io.dataOut(i).resetsVstart
      }
    ).asUInt.orR
    io.clearVstart.get := clearVstart

    if (!mini) {
      val tagWidth = log2Ceil(bufferSize)
      for (x <- 0 until bufferSize) {
        val isEnqueuing = (0 until p.instructionLanes)
          .map { k =>
            val slotIdx = if (bufferSize > 1) (accEnqPtr +& k.U)(tagWidth - 1, 0) else 0.U
            (k.U < instBuffer.io.enqValid) && (x.U === slotIdx)
          }
          .reduce(_ || _)
        vectorWriteAccumulator.get(x) := Mux(
          trapRetired || isEnqueuing,
          0.U.asTypeOf(vectorWriteAccumulator.get(0)),
          vectorAccumulatorNext.get(x)
        )
      }
    }
  }

  resultBuffer := Mux(
    trapRetired,
    VecInit(Seq.fill(bufferSize)(MakeInvalid(new InstructionUpdate))),
    ShiftVectorRight(resultUpdate, deqReady)
  )

  val retiredEcalls = PopCount(
    VecInit(
      (0 until p.retirementLanes).map(i => (i.U < deqReady) && instBuffer.io.dataOut(i).isEcall)
    ).asUInt
  )

  // Register inputs to break timing path before subtraction
  val deqReady_reg      = RegNext(deqReady, 0.U)
  val retiredEcalls_reg = RegNext(retiredEcalls, 0.U)
  io.nRetired    := deqReady_reg - retiredEcalls_reg
  io.trapPending := RegNext(hasTrap && !trapRetired, false.B)
  io.trapRetired := trapRetired

  io.debug.foreach { debug =>
    for (i <- 0 until p.retirementLanes) {
      val valid      = (i.U < instBuffer.io.deqReady)
      val allowDebug =
        resultUpdate(i).bits.trap && instBuffer.io.dataOut(i).isControlFlow && noFire0Fault
      debug.inst(i).valid     := valid
      debug.inst(i).bits.pc   := MuxOR(valid, instBuffer.io.dataOut(i).addr)
      debug.inst(i).bits.inst := MuxOR(valid && !mini.B, instBuffer.io.dataOut(i).inst)
      debug.inst(i).bits.data := MuxOR(valid && !mini.B, resultUpdate(i).bits.result)
      debug.inst(i).bits.idx  := MuxOR(
        valid,
        Mux(resultUpdate(i).bits.trap && !allowDebug, noWriteRegIdx, instBuffer.io.dataOut(i).idx)
      )
      debug.inst(i).bits.trap := MuxOR(valid, resultUpdate(i).bits.trap)
      if (p.enableRvv) {
        val tagWidth = log2Ceil(bufferSize)
        val pIdx     = if (bufferSize > 1) (accDeqPtr +& i.U)(tagWidth - 1, 0) else 0.U
        if (!mini) {
          val maskedVecWrites = Wire(Vec(8, Valid(new VectorWrite)))
          for (k <- 0 until 8) {
            maskedVecWrites(k).valid := debugVectorWrites.get(pIdx)(k).valid && !resultUpdate(
              i
            ).bits.trap
            maskedVecWrites(k).bits := debugVectorWrites.get(pIdx)(k).bits
          }
          debug.inst(i).bits.vecWrites.get := maskedVecWrites
        } else {
          debug.inst(i).bits.vecWrites.get := 0.U.asTypeOf(debug.inst(i).bits.vecWrites.get)
        }
      }
    }
  }
}
