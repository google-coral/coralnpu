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

// =============================================================================
// 3:2 Compressor (Carry-Save Adder)
// Port of hdl/verilog/rvv/common/compressor_3_2.sv
// =============================================================================
class Compressor3_2(width: Int) extends Module {
  val io = IO(new Bundle {
    val src1 = Input(UInt(width.W))
    val src2 = Input(UInt(width.W))
    val src3 = Input(UInt(width.W))
    val sum   = Output(UInt(width.W))
    val carry = Output(UInt(width.W))
  })

  val xor12 = io.src1 ^ io.src2
  io.sum   := xor12 ^ io.src3

  // Per-bit mux: carry[i] = xor12[i] ? src3[i] : src1[i]
  io.carry := VecInit.tabulate(width) { i =>
    Mux(xor12(i), io.src3(i), io.src1(i))
  }.asUInt
}

// =============================================================================
// 4:2 Compressor
// Port of hdl/verilog/rvv/common/compressor_4_2.sv
// =============================================================================
class Compressor4_2(width: Int) extends Module {
  val io = IO(new Bundle {
    val src1 = Input(UInt(width.W))
    val src2 = Input(UInt(width.W))
    val src3 = Input(UInt(width.W))
    val src4 = Input(UInt(width.W))
    val cin  = Input(UInt(width.W))
    val sum    = Output(UInt(width.W))
    val carry  = Output(UInt(width.W))
    val cout   = Output(UInt(width.W))
  })

  val xor12 = io.src1 ^ io.src2
  val xor34 = io.src3 ^ io.src4

  io.sum := VecInit.tabulate(width) { i =>
    val xor14 = Mux(xor34(i), !xor12(i), xor12(i))
    Mux(xor14, !io.cin(i), io.cin(i))
  }.asUInt

  io.cout := VecInit.tabulate(width) { i =>
    Mux(xor12(i), io.src3(i), io.src1(i))
  }.asUInt

  io.carry := VecInit.tabulate(width) { i =>
    val xor14 = Mux(xor34(i), !xor12(i), xor12(i))
    Mux(xor14, io.cin(i), io.src4(i))
  }.asUInt
}

// =============================================================================
// Handshake Flip-Flop
// Port of hdl/verilog/rvv/common/handshake_ff.sv
//
// A single-entry handshake buffer with clear support.
//   inready = ~outvalid | outready
// =============================================================================
class HandshakeFF[T <: Data](gen: T) extends Module {
  val io = IO(new Bundle {
    val indata  = Input(gen)
    val invalid  = Input(Bool())
    val inready  = Output(Bool())
    val outdata  = Output(gen)
    val outvalid = Output(Bool())
    val outready = Input(Bool())
    val clear    = Input(Bool())
  })

  val dataReg = RegEnable(io.indata, io.invalid && io.inready)
  io.outdata := dataReg

  val validReg = RegInit(false.B)
  val validEn  = (io.invalid && io.inready) || (validReg && io.outready)
  when (io.clear) {
    validReg := false.B
  } .elsewhen (validEn) {
    validReg := io.invalid
  }
  io.outvalid := validReg

  io.inready := !validReg || io.outready
}

// =============================================================================
// Multi-Push Multi-Pop FIFO
// Port of hdl/verilog/rvv/common/multi_fifo.sv
//
// Parameterized multi-push (M ports) multi-pop (N ports) synchronous FIFO.
// Simplified version: POP_CLEAR=0, ASYNC_RSTN=0, CHAOS_PUSH=0, DATAOUT_REG=0,
// FULL_PUSH=0 (defaults used by RVV backend).
// =============================================================================
class MultiFifo[T <: Data](gen: T, depth: Int, pushPorts: Int, popPorts: Int) extends Module {
  val depthBits = log2Ceil(depth)

  val io = IO(new Bundle {
    val push    = Input(Vec(pushPorts, Bool()))
    val datain  = Input(Vec(pushPorts, gen))
    val full    = Output(Bool())
    val almostFull = Output(Vec(pushPorts, Bool()))

    val pop     = Input(Vec(popPorts, Bool()))
    val dataout = Output(Vec(popPorts, gen))
    val empty   = Output(Bool())
    val almostEmpty = Output(Vec(popPorts, Bool()))

    val clear   = Input(Bool())

    // Debug outputs
    val fifoData    = Output(Vec(depth, gen))
    val wptr        = Output(UInt(depthBits.W))
    val rptr        = Output(UInt(depthBits.W))
    val entryCount  = Output(UInt((depthBits + 1).W))
  })

  // Memory array
  val mem = Reg(Vec(depth, gen))

  // Entry counter
  val entryCount = RegInit(0.U((depthBits + 1).W))
  val pushCount = PopCount(io.push)
  val popCount  = PopCount(io.pop)
  val nextEntryCount = entryCount + pushCount - popCount
  val entryCountEn = io.push.asUInt.orR || io.pop.asUInt.orR

  when (io.clear) {
    entryCount := 0.U
  } .elsewhen (entryCountEn) {
    entryCount := nextEntryCount
  }

  // Read / Write pointers
  val wptr = RegInit(0.U(depthBits.W))
  val rptr = RegInit(0.U(depthBits.W))

  when (io.clear) {
    wptr := 0.U
  } .elsewhen (io.push.asUInt.orR) {
    wptr := wptr + pushCount
  }

  when (io.clear) {
    rptr := 0.U
  } .elsewhen (io.pop.asUInt.orR) {
    rptr := rptr + popCount
  }

  // Status flags
  io.full := entryCount === depth.U
  io.almostFull.zipWithIndex.foreach { case (af, i) =>
    af := (entryCount + i.U) >= depth.U
  }

  io.empty := entryCount === 0.U
  io.almostEmpty.zipWithIndex.foreach { case (ae, i) =>
    ae := entryCount <= i.U
  }

  // Write data (simple ordered push — CHAOS_PUSH=0)
  // Push ports are assumed to be ordered (push[0]..push[M-1] are contiguous)
  for (j <- 0 until pushPorts) {
    when (io.push(j)) {
      mem((wptr + j.U) % depth.U) := io.datain(j)
    }
  }

  // Read data
  for (i <- 0 until popPorts) {
    io.dataout(i) := mem((rptr + i.U) % depth.U)
  }

  // Debug outputs
  for (i <- 0 until depth) {
    io.fifoData(i) := mem((rptr + i.U) % depth.U)
  }
  io.wptr := wptr
  io.rptr := rptr
  io.entryCount := entryCount
}

// =============================================================================
// Handshake Multi-FIFO
// Port of hdl/verilog/rvv/common/handshake_multi_fifo.sv
//
// Wraps MultiFifo with a handshake interface (valid/ready).
// =============================================================================
class HandshakeMultiFifo[T <: Data](gen: T, depth: Int, pushPorts: Int, popPorts: Int) extends Module {
  val io = IO(new Bundle {
    val indata   = Input(Vec(pushPorts, gen))
    val invalid  = Input(Vec(pushPorts, Bool()))
    val inready  = Output(Vec(pushPorts, Bool()))

    val outdata  = Output(Vec(popPorts, gen))
    val outvalid = Output(Vec(popPorts, Bool()))
    val outready = Input(Vec(popPorts, Bool()))

    val clear    = Input(Bool())

    // Debug
    val fifoData    = Output(Vec(depth, gen))
    val wptr        = Output(UInt(log2Ceil(depth).W))
    val rptr        = Output(UInt(log2Ceil(depth).W))
    val entryCount  = Output(UInt((log2Ceil(depth) + 1).W))
  })

  val fifo = Module(new MultiFifo(gen, depth, pushPorts, popPorts))

  // Push side: inready = ~almost_full
  for (i <- 0 until pushPorts) {
    io.inready(i) := !fifo.io.almostFull(i)
    fifo.io.push(i) := io.invalid(i) && io.inready(i)
    fifo.io.datain(i) := io.indata(i)
  }

  // Pop side: outvalid = ~almost_empty
  for (i <- 0 until popPorts) {
    io.outvalid(i) := !fifo.io.almostEmpty(i)
    fifo.io.pop(i) := io.outvalid(i) && io.outready(i)
    io.outdata(i) := fifo.io.dataout(i)
  }

  fifo.io.clear := io.clear

  io.fifoData   := fifo.io.fifoData
  io.wptr       := fifo.io.wptr
  io.rptr       := fifo.io.rptr
  io.entryCount := fifo.io.entryCount
}

// =============================================================================
// Open FIFO 4 (flopped pointer)
// Port of hdl/verilog/rvv/common/openFifo4_flopped_ptr.sv
//
// A 4-entry FIFO that exposes all entries and their valid bits.
// Used by the RVV dispatch for operand routing.
// =============================================================================
class OpenFifo4[T <: Data](gen: T) extends Module {
  val io = IO(new Bundle {
    val inData  = Input(gen)
    val push    = Input(Bool())
    val pop     = Input(Bool())
    val outData = Output(gen)
    val full    = Output(Bool())
    val empty   = Output(Bool())

    // Open access to all entries
    val d0 = Output(gen)
    val d1 = Output(gen)
    val d2 = Output(gen)
    val d3 = Output(gen)
    val dValid = Output(UInt(4.W))
    val dPtr   = Output(UInt(2.W))
  })

  val wrPtr = RegInit(0.U(2.W))
  val rdPtr = RegInit(0.U(2.W))

  val nxtWrPtr = Mux(io.push, wrPtr + 1.U, wrPtr)
  val nxtRdPtr = Mux(io.pop, rdPtr + 1.U, rdPtr)

  when (io.push) { wrPtr := nxtWrPtr }
  when (io.pop)  { rdPtr := nxtRdPtr }

  // Empty flag
  val nxtEmpty = WireDefault(false.B)
  when (io.pop && (nxtWrPtr === nxtRdPtr)) {
    nxtEmpty := true.B
  } .elsewhen (nxtWrPtr =/= nxtRdPtr) {
    nxtEmpty := false.B
  } .otherwise {
    nxtEmpty := io.empty
  }
  val emptyReg = RegNext(nxtEmpty, false.B)
  io.empty := emptyReg

  // Full flag
  val nxtFull = WireDefault(false.B)
  when (io.push && (nxtWrPtr === nxtRdPtr)) {
    nxtFull := true.B
  } .elsewhen (nxtWrPtr =/= nxtRdPtr) {
    nxtFull := false.B
  } .otherwise {
    nxtFull := io.full
  }
  val fullReg = RegNext(nxtFull, false.B)
  io.full := fullReg

  // Data registers
  val d0 = RegEnable(io.inData, io.push && (wrPtr === 0.U))
  val d1 = RegEnable(io.inData, io.push && (wrPtr === 1.U))
  val d2 = RegEnable(io.inData, io.push && (wrPtr === 2.U))
  val d3 = RegEnable(io.inData, io.push && (wrPtr === 3.U))

  io.d0 := d0
  io.d1 := d1
  io.d2 := d2
  io.d3 := d3

  // Read output
  io.outData := MuxLookup(rdPtr, 0.U.asTypeOf(gen))(Seq(
    0.U -> d0,
    1.U -> d1,
    2.U -> d2,
    3.U -> d3,
  ))

  // Valid bits per entry
  val dValid = RegInit(0.U(4.W))
  val updateValid = io.push || io.pop
  val dValidN = WireDefault(dValid)
  when (io.push) {
    dValidN := dValidN | (1.U(4.W) << wrPtr)
  }
  when (io.pop) {
    dValidN := dValidN & ~(1.U(4.W) << rdPtr)
  }
  when (updateValid) {
    dValid := dValidN
  }
  io.dValid := dValid

  io.dPtr := nxtRdPtr
}

// =============================================================================
// Open FIFO 8 (2-write 2-read, flopped pointer)
// Port of hdl/verilog/rvv/common/openFifo8_flopped_2w2r.sv
//
// An 8-entry open FIFO built from two interleaved OpenFifo4 instances.
// =============================================================================
class OpenFifo8_2w2r[T <: Data](gen: T) extends Module {
  val io = IO(new Bundle {
    val push0   = Input(Bool())
    val inData0 = Input(gen)
    val push1   = Input(Bool())
    val inData1 = Input(gen)

    val pop0    = Input(Bool())
    val outData0 = Output(gen)
    val pop1    = Input(Bool())
    val outData1 = Output(gen)

    val full           = Output(Bool())
    val oneLeftToFull  = Output(Bool())
    val empty          = Output(Bool())
    val oneLeftToEmpty = Output(Bool())

    // Open data
    val d0 = Output(gen); val d1 = Output(gen)
    val d2 = Output(gen); val d3 = Output(gen)
    val d4 = Output(gen); val d5 = Output(gen)
    val d6 = Output(gen); val d7 = Output(gen)
    val dPtr   = Output(UInt(3.W))
    val dValid = Output(UInt(8.W))
  })

  // Push arbitration: load-balance across even/odd sub-FIFOs
  val pushSwapFlag = RegInit(false.B)
  val singlePush = io.push0 && !io.push1
  val pushSwapNxt = Mux(singlePush, !pushSwapFlag, pushSwapFlag)
  when (io.push0 || io.push1) {
    pushSwapFlag := pushSwapNxt
  }

  val push0Int = Mux(pushSwapFlag, io.push0, io.push1)
  val push1Int = Mux(pushSwapFlag, io.push1, io.push0)
  val inData0Int = Mux(pushSwapFlag, io.inData0, io.inData1)
  val inData1Int = Mux(pushSwapFlag, io.inData1, io.inData0)

  // Pop arbitration
  val popSwapFlag = RegInit(false.B)
  val singlePop = io.pop0 && !io.pop1
  val popSwapNxt = Mux(singlePop, !popSwapFlag, popSwapFlag)
  when (io.pop0 || io.pop1) {
    popSwapFlag := popSwapNxt
  }

  val pop0Int = Mux(popSwapFlag, io.pop0, io.pop1)
  val pop1Int = Mux(popSwapFlag, io.pop1, io.pop0)

  // Two OpenFifo4 instances (even/odd interleaved)
  val fifoEven = Module(new OpenFifo4(gen))
  fifoEven.io.inData := inData0Int
  fifoEven.io.push   := push0Int
  fifoEven.io.pop    := pop0Int

  val fifoOdd = Module(new OpenFifo4(gen))
  fifoOdd.io.inData := inData1Int
  fifoOdd.io.push   := push1Int
  fifoOdd.io.pop    := pop1Int

  // Output arbitration
  io.outData0 := Mux(popSwapFlag, fifoOdd.io.outData, fifoEven.io.outData)
  io.outData1 := Mux(popSwapFlag, fifoEven.io.outData, fifoOdd.io.outData)

  // Full/empty flags
  io.full := fifoEven.io.full && fifoOdd.io.full
  io.oneLeftToFull := (fifoEven.io.full && !fifoOdd.io.full) ||
    (!fifoEven.io.full && fifoOdd.io.full)
  io.empty := fifoEven.io.empty && fifoOdd.io.empty
  io.oneLeftToEmpty := (fifoEven.io.empty && !fifoOdd.io.empty) ||
    (!fifoEven.io.empty && fifoOdd.io.empty)

  // Open data packing (interleaved: even[0], odd[0], even[1], odd[1], ...)
  io.d0 := fifoEven.io.d0; io.d1 := fifoOdd.io.d0
  io.d2 := fifoEven.io.d1; io.d3 := fifoOdd.io.d1
  io.d4 := fifoEven.io.d2; io.d5 := fifoOdd.io.d2
  io.d6 := fifoEven.io.d3; io.d7 := fifoOdd.io.d3

  val dPtrEven = fifoEven.io.dPtr * 2.U
  val dPtrOdd  = fifoOdd.io.dPtr * 2.U + 1.U
  io.dPtr := Mux(popSwapFlag, dPtrOdd, dPtrEven)

  // dValid packing
  io.dValid := Cat(
    fifoOdd.io.dValid(3), fifoEven.io.dValid(3),
    fifoOdd.io.dValid(2), fifoEven.io.dValid(2),
    fifoOdd.io.dValid(1), fifoEven.io.dValid(1),
    fifoOdd.io.dValid(0), fifoEven.io.dValid(0),
  )
}

// =============================================================================
// 2-Write 2-Read Flopped FIFO
// Port of hdl/verilog/rvv/common/fifo_flopped_2w2r.sv
//
// Built from two interleaved single-push/pop FIFOs with load-balancing.
// =============================================================================
class FifoFlop2w2r[T <: Data](gen: T, depth: Int) extends Module {
  val io = IO(new Bundle {
    val push0   = Input(Bool())
    val inData0 = Input(gen)
    val push1   = Input(Bool())
    val inData1 = Input(gen)

    val pop0    = Input(Bool())
    val outData0 = Output(gen)
    val pop1    = Input(Bool())
    val outData1 = Output(gen)

    val full           = Output(Bool())
    val oneLeftToFull  = Output(Bool())
    val empty          = Output(Bool())
    val oneLeftToEmpty = Output(Bool())
    val idle           = Output(Bool())
  })

  val halfDepth = depth / 2

  // Push arbitration
  val pushSwapFlag = RegInit(false.B)
  val singlePush = io.push0 && !io.push1
  val pushSwapNxt = Mux(singlePush, !pushSwapFlag, pushSwapFlag)
  when (io.push0 || io.push1) {
    pushSwapFlag := pushSwapNxt
  }

  val push0Int = Mux(pushSwapFlag, io.push0, io.push1)
  val push1Int = Mux(pushSwapFlag, io.push1, io.push0)
  val inData0Int = Mux(pushSwapFlag, io.inData0, io.inData1)
  val inData1Int = Mux(pushSwapFlag, io.inData1, io.inData0)

  // Pop arbitration
  val popSwapFlag = RegInit(false.B)
  val singlePop = io.pop0 && !io.pop1
  val popSwapNxt = Mux(singlePop, !popSwapFlag, popSwapFlag)
  when (io.pop0 || io.pop1) {
    popSwapFlag := popSwapNxt
  }

  val pop0Int = Mux(popSwapFlag, io.pop0, io.pop1)
  val pop1Int = Mux(popSwapFlag, io.pop1, io.pop0)

  // Two sub-FIFOs (using Chisel Queue as the underlying FIFO primitive)
  val fifoEven = Module(new Queue(gen, halfDepth))
  fifoEven.io.enq.valid := push0Int
  fifoEven.io.enq.bits  := inData0Int
  fifoEven.io.deq.ready := pop0Int

  val fifoOdd = Module(new Queue(gen, halfDepth))
  fifoOdd.io.enq.valid := push1Int
  fifoOdd.io.enq.bits  := inData1Int
  fifoOdd.io.deq.ready := pop1Int

  // Output arbitration
  io.outData0 := Mux(popSwapFlag, fifoOdd.io.deq.bits, fifoEven.io.deq.bits)
  io.outData1 := Mux(popSwapFlag, fifoEven.io.deq.bits, fifoOdd.io.deq.bits)

  // Status
  val evenCount = fifoEven.io.count
  val oddCount  = fifoOdd.io.count
  val evenFull  = evenCount === halfDepth.U
  val oddFull   = oddCount === halfDepth.U

  io.full := evenFull && oddFull
  io.oneLeftToFull := (evenFull && !oddFull) || (!evenFull && oddFull)
  io.empty := (evenCount === 0.U) && (oddCount === 0.U)
  io.oneLeftToEmpty :=
    ((evenCount === 0.U) && (oddCount =/= 0.U)) ||
    ((evenCount =/= 0.U) && (oddCount === 0.U))
  io.idle := io.empty
}

// =============================================================================
// 4-Write 2-Read Flopped FIFO
// Port of hdl/verilog/rvv/common/fifo_flopped_4w2r.sv
//
// Built from four interleaved single-push/pop FIFOs with rotating start pointer.
// =============================================================================
class FifoFlop4w2r[T <: Data](gen: T, depth: Int) extends Module {
  val io = IO(new Bundle {
    val push0 = Input(Bool()); val inData0 = Input(gen)
    val push1 = Input(Bool()); val inData1 = Input(gen)
    val push2 = Input(Bool()); val inData2 = Input(gen)
    val push3 = Input(Bool()); val inData3 = Input(gen)

    val pop0    = Input(Bool())
    val outData0 = Output(gen)
    val pop1    = Input(Bool())
    val outData1 = Output(gen)

    val full            = Output(Bool())
    val oneLeftToFull   = Output(Bool())
    val twoLeftToFull   = Output(Bool())
    val threeLeftToFull = Output(Bool())
    val empty           = Output(Bool())
    val oneLeftToEmpty  = Output(Bool())
    val idle            = Output(Bool())
  })

  val quarterDepth = depth / 4

  // Push arbitration with rotating start pointer
  val pushStartId = RegInit(0.U(2.W))
  val singlePush = io.push0 && !io.push1 && !io.push2 && !io.push3
  val doublePush = io.push0 &&  io.push1 && !io.push2 && !io.push3
  val triplePush = io.push0 &&  io.push1 &&  io.push2 && !io.push3
  val anyPush = io.push0 || io.push1 || io.push2 || io.push3

  val pushInc = Mux(triplePush, 3.U, Mux(doublePush, 2.U, Mux(singlePush, 1.U, 0.U)))
  val pushStartNxt = pushStartId + pushInc
  when (anyPush) {
    pushStartId := pushStartNxt
  }

  // Rotate push inputs based on start ID
  val pushRot = Wire(Vec(4, Bool()))
  val dataRot = Wire(Vec(4, gen))
  val rawPushes = Seq(io.push0, io.push1, io.push2, io.push3)
  val rawDatas  = Seq(io.inData0, io.inData1, io.inData2, io.inData3)

  for (i <- 0 until 4) {
    val idx = (i.U + pushStartId) % 4.U
    // Use a Mux tree for the rotation
    pushRot(i) := MuxLookup(pushStartId, rawPushes(i))(Seq(
      0.U -> rawPushes(i),
      1.U -> rawPushes((i + 3) % 4),
      2.U -> rawPushes((i + 2) % 4),
      3.U -> rawPushes((i + 1) % 4),
    ))
    dataRot(i) := MuxLookup(pushStartId, rawDatas(i))(Seq(
      0.U -> rawDatas(i),
      1.U -> rawDatas((i + 3) % 4),
      2.U -> rawDatas((i + 2) % 4),
      3.U -> rawDatas((i + 1) % 4),
    ))
  }

  // Pop arbitration with rotating start pointer
  val popStartId = RegInit(0.U(2.W))
  val singlePop = io.pop0 && !io.pop1
  val popInc = Mux(io.pop0 && io.pop1, 2.U, Mux(singlePop, 1.U, 0.U))
  val popStartNxt = popStartId + popInc
  when (io.pop0 || io.pop1) {
    popStartId := popStartNxt
  }

  // Four sub-FIFOs
  val subFifos = Seq.fill(4)(Module(new Queue(gen, quarterDepth)))

  for (i <- 0 until 4) {
    subFifos(i).io.enq.valid := pushRot(i)
    subFifos(i).io.enq.bits  := dataRot(i)
  }

  // Pop routing: which sub-FIFOs to pop from
  val pop0Idx = popStartId
  val pop1Idx = (popStartId + 1.U) % 4.U
  for (i <- 0 until 4) {
    subFifos(i).io.deq.ready := (i.U === pop0Idx && io.pop0) || (i.U === pop1Idx && io.pop1)
  }

  // Output muxing
  io.outData0 := MuxLookup(pop0Idx, subFifos(0).io.deq.bits)(Seq(
    0.U -> subFifos(0).io.deq.bits,
    1.U -> subFifos(1).io.deq.bits,
    2.U -> subFifos(2).io.deq.bits,
    3.U -> subFifos(3).io.deq.bits,
  ))
  io.outData1 := MuxLookup(pop1Idx, subFifos(0).io.deq.bits)(Seq(
    0.U -> subFifos(0).io.deq.bits,
    1.U -> subFifos(1).io.deq.bits,
    2.U -> subFifos(2).io.deq.bits,
    3.U -> subFifos(3).io.deq.bits,
  ))

  // Status flags
  val subFulls = subFifos.map(f => f.io.count === quarterDepth.U)
  val fullCount = PopCount(subFulls)
  io.full := fullCount === 4.U
  io.oneLeftToFull   := fullCount === 3.U
  io.twoLeftToFull   := fullCount === 2.U
  io.threeLeftToFull := fullCount === 1.U

  val subEmpties = subFifos.map(f => f.io.count === 0.U)
  val emptyCount = PopCount(subEmpties)
  io.empty := emptyCount === 4.U
  io.oneLeftToEmpty := emptyCount === 3.U
  io.idle := io.empty
}
