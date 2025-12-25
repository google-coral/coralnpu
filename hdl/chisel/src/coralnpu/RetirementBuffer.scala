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

class RetirementBuffer(p: Parameters) extends Module {
  val io = IO(new Bundle {
    val inst = Input(Vec(p.instructionLanes, Decoupled(new FetchInstruction(p))))
    val storeComplete = Input(Valid(UInt(32.W)))
    val writeAddrScalar = Input(Vec(p.instructionLanes, new RegfileWriteAddrIO))
    val writeDataScalar = Input(Vec(p.instructionLanes + 2, Valid(new RegfileWriteDataIO)))
    val writeAddrFloat = Option.when(p.enableFloat)(Input(new RegfileWriteAddrIO))
    val writeDataFloat = Option.when(p.enableFloat)(Input(Vec(2, Valid(new RegfileWriteDataIO))))
    val writeAddrVector = Option.when(p.enableRvv)(Input(Vec(p.instructionLanes, new RegfileWriteAddrIO)))
    val writeDataVector = Option.when(p.enableRvv)(Input(Vec(p.instructionLanes, Valid(new VectorWriteDataIO(p)))))
    val fault = Input(Valid(new FaultManagerOutput))
    val nSpace = Output(UInt(32.W))
    val debug = Output(new RetirementBufferDebugIO(p))
  })
  if (p.enableRvv) {
    dontTouch(io.writeAddrVector.get)
  }

  val idxWidth = p.retirementBufferIdxWidth
  val noWriteRegIdx = ~0.U(idxWidth.W)
  val storeRegIdx = (noWriteRegIdx - 1.U)
  class Instruction extends Bundle {
    val addr = UInt(32.W) // Memory address
    val inst = UInt(32.W) // Instruction bits
    val idx = UInt(idxWidth.W) // Register Index
    val trap = Bool() // Instruction causing a trap to occur.
  }
  val bufferSize = p.retirementBufferSize
  assert(bufferSize >= p.instructionLanes)
  assert(bufferSize >= io.writeDataScalar.length)
  // Construct a circular buffer of `bufferSize`, that can enqueue and dequeue `bufferSize` elements
  // per cycle. This will be used to store information about dispatched instructions.
  val instBuffer = Module(new CircularBufferMulti(new Instruction,
                                              /* needs to be at least writeDataScalar count */ bufferSize,
                                              /* chosen sort-of-arbitrarily */ bufferSize))
  // Check that we see no instructions fire after the first non-fire.
  val instFires = io.inst.map(_.fire)
  val seenFalseV = (instFires.scanLeft(false.B) { (acc, curr) => acc || !curr }).drop(1)
  assert(!(seenFalseV.zip(instFires).map({ case (seenFalse, fire) => seenFalse && fire }).reduce(_|_)))

  val decodeFaultValid = (io.fault.valid && io.fault.bits.decode)
  // Valid fault, no fire, also not a load/store: those faults should be handled purely in the update stage
  val noFire0Fault = (io.fault.valid && !io.inst(0).fire && (io.fault.bits.mcause =/= 7.U) && (io.fault.bits.mcause =/= 5.U))
  val faultPc = io.fault.bits.mepc
  // Create Instruction wires out of io.inst + io.writeAddrScalar, and align.
  def WireInstruction(i: Int) = {
    val floatValid = (i == 0).B && io.writeAddrFloat.map(x => x.valid).getOrElse(false.B)
    val floatAddr = io.writeAddrFloat.map(x => x.addr).getOrElse(0.U)

    val scalarValid = io.writeAddrScalar(i).valid
    val scalarAddr = io.writeAddrScalar(i).addr

    val vectorValid = io.writeAddrVector.map(x => x(i).valid).getOrElse(false.B)
    val vectorAddr = io.writeAddrVector.map(x => x(i).addr).getOrElse(0.U)

    // clean this up... either a decode+pc match, or fault w/ no fires.
    val noFireFault = ((i == 0).B && noFire0Fault)
    val faultingInstr = (decodeFaultValid && ((faultPc === io.inst(i).bits.addr)))

    // Store detection per RISC-V spec section 7.3 Table 11
    // Scalar store: opcode 0x23
    val scalarStore = (io.inst(i).bits.inst(6,0) === "b0100011".U)
    val width = io.inst(i).bits.inst(14,12)
    // Float store: opcode 0x27 with width ∈ {001, 010, 011, 100}
    // These are 16b, 32b, 64b, 128b FP stores
    val floatStore = (io.inst(i).bits.inst(6,0) === "b0100111".U) &&
                     (width === "b001".U || width === "b010".U ||
                      width === "b011".U || width === "b100".U)
    // Vector store: opcode 0x27 with width ∈ {000, 101, 110, 111}
    // These are 8b, 16b, 32b, 64b element vector stores
    val vectorStore = (io.inst(i).bits.inst(6,0) === "b0100111".U) &&
                      (width === "b000".U || width === "b101".U ||
                       width === "b110".U || width === "b111".U)
    val store = scalarStore || floatStore || vectorStore

    val instr = Wire(new Instruction)
    instr.addr := Mux(noFireFault, io.fault.bits.mepc, io.inst(i).bits.addr)
    instr.inst := Mux(noFireFault, io.fault.bits.mtval, io.inst(i).bits.inst)
    instr.idx := MuxCase(noWriteRegIdx, Seq(
      floatValid -> (floatAddr +& p.floatRegfileBaseAddr.U),
      (scalarValid && scalarAddr =/= 0.U) -> scalarAddr,
      (vectorValid) -> (vectorAddr +& p.rvvRegfileBaseAddr.U),
      store -> storeRegIdx,
    ))
    instr.trap := faultingInstr || noFireFault
    instr
  }
  val insts = (0 until p.instructionLanes).map(x => WireInstruction(x))

  val instsWithWriteFired = PopCount(io.inst.map(_.fire))
  instBuffer.io.enqValid := instsWithWriteFired +& (decodeFaultValid || noFire0Fault)
  instBuffer.io.flush := false.B
  io.nSpace := instBuffer.io.nSpace

  for (i <- 0 until p.instructionLanes) {
    instBuffer.io.enqData(i) := insts(i)
  }
  for (i <- p.instructionLanes until bufferSize) {
    instBuffer.io.enqData(i) := 0.U.asTypeOf(instBuffer.io.enqData(i))
  }

  class InstructionUpdate extends Bundle {
    val result = UInt(dataWidth.W)
    val trap = Bool()
  }
  // Maintain a re-order buffer of instruction completion result.
  // The order and alignment of these buffers should correspond to the
  // output of `instBuffer`.
  val dataWidth = if (p.enableRvv) p.lsuDataBits else 32
  val resultBuffer = RegInit(VecInit(Seq.fill(bufferSize)(MakeInvalid(new InstructionUpdate))))
  // Compute update based on register writeback.
  // Note: The shift when committing instructions will be handled in a later block.
  val resultUpdate = Wire(Vec(bufferSize, Valid(new InstructionUpdate)))

  for (i <- 0 until bufferSize) {
    val bufferEntry = instBuffer.io.dataOut(i)
    // Check which incoming (scalar,float) write port matches this entry's needed address.
    val scalarWriteIdxMap = io.writeDataScalar.map(
        x => x.valid && (x.bits.addr === bufferEntry.idx))
    val floatWriteIdxMap = io.writeDataFloat.map(y => y.map(
        x => x.valid && ((x.bits.addr +& p.floatRegfileBaseAddr.U) ===
            bufferEntry.idx))).getOrElse(Seq(false.B))
    val vectorWriteIdxMap = io.writeDataVector.map(y => y.map(
        x => x.valid && ((x.bits.addr +& p.rvvRegfileBaseAddr.U) ===
            bufferEntry.idx))).getOrElse(Seq(false.B))
    // Check if this entry is an operation that doesn't require a register write, but is not a store.
    val nonWritingInstr = bufferEntry.idx === noWriteRegIdx
    val storeInstr = bufferEntry.idx === storeRegIdx
    // Check if this entry is the faulting instruction
    val faultingInstr = io.fault.valid && (bufferEntry.addr === faultPc)
    // The entry is active if it's validly enqueued and not already complete.
    val validBufferEntry = (i.U < instBuffer.io.nEnqueued) && (!resultBuffer(i).valid)

    // Find the index of the first write port that provides the needed data.
    val scalarWriteIdx = PriorityEncoder(scalarWriteIdxMap)
    val floatWriteIdx = PriorityEncoder(floatWriteIdxMap)
    val vectorWriteIdx = PriorityEncoder(vectorWriteIdxMap)

    // If the entry is active and its data dependency is met (or it has no dependency)...
    // Special care here for vector, as multiple instructions are allowed to be dispatched for the same destination register.
    // This differs from how the scalar/float scoreboards restrict dispatch.
    val updated = (validBufferEntry &&
        (scalarWriteIdxMap.reduce(_|_) || floatWriteIdxMap.reduce(_|_) || (vectorWriteIdxMap.reduce(_|_) && vectorWriteIdx === i.U) || nonWritingInstr || faultingInstr || (storeInstr && io.storeComplete.valid && io.storeComplete.bits === bufferEntry.addr)))
    // Select the actual data from the winning write port.
    val writeDataScalar = io.writeDataScalar(scalarWriteIdx).bits.data
    val writeDataFloat = io.writeDataFloat.map(x => x(floatWriteIdx).bits.data).getOrElse(0.U)
    val writeDataVector = io.writeDataVector.map(x => x(vectorWriteIdx).bits.data).getOrElse(0.U)
    // If updated, mark this buffer entry as complete for the next cycle.
    resultUpdate(i).valid := Mux(updated, true.B, resultBuffer(i).valid) // true.B
    // Select the correct write-back data to store, if updated (FP has priority).
    val sdata = if (p.enableRvv) Cat(0.U((p.lsuDataBits - 32).W), writeDataScalar) else writeDataScalar
    val fdata = if (p.enableRvv) Cat(0.U((p.lsuDataBits - 32).W), writeDataFloat) else writeDataFloat
    resultUpdate(i).bits.result := Mux(updated, MuxCase(0.U, Seq(
      floatWriteIdxMap.reduce(_|_) -> fdata,
      vectorWriteIdxMap.reduce(_|_) -> writeDataVector,
      scalarWriteIdxMap.reduce(_|_) -> sdata,
    )), resultBuffer(i).bits.result)
    resultUpdate(i).bits.trap := Mux(updated, faultingInstr, resultBuffer(i).bits.trap)
  }

  val deqReady = Cto(VecInit(resultUpdate.map(_.valid)).asUInt)
  instBuffer.io.deqReady := deqReady
  resultBuffer := ShiftVectorRight(resultUpdate, deqReady)

  for (i <- 0 until bufferSize) {
    val valid = (i.U < instBuffer.io.deqReady)
    io.debug.inst(i).valid := valid
    io.debug.inst(i).bits.pc := MuxOR(valid, instBuffer.io.dataOut(i).addr)
    io.debug.inst(i).bits.inst := MuxOR(valid, instBuffer.io.dataOut(i).inst)
    io.debug.inst(i).bits.idx := MuxOR(valid, instBuffer.io.dataOut(i).idx)
    io.debug.inst(i).bits.data := MuxOR(valid, resultUpdate(i).bits.result)
    io.debug.inst(i).bits.trap := MuxOR(valid, resultUpdate(i).bits.trap || instBuffer.io.dataOut(i).trap)
  }
}
