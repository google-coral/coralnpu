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

// Regfile: 32 entry scalar register file with 8 read ports and 6
// write ports. Houses a global scoreboard that informs of interlock
// deps inside the decoders.

package coralnpu

import chisel3._
import chisel3.util._
import common._
import _root_.circt.stage.ChiselStage

object Regfile {
  def apply(p: Parameters): Regfile = {
    return Module(new Regfile(p))
  }
}

class RegfileReadAddrIO(p: Parameters) extends Bundle {
  val valid = Input(Bool())
  val addr  = Input(UInt(log2Ceil(p.scalarRegCount).W))
}

class RegfileReadSetIO(p: Parameters) extends Bundle {
  val valid = Input(Bool())
  val value = Input(UInt(p.xlen.W))
}

class RegfileBusAddrIO(p: Parameters) extends Bundle {
  val valid = Input(Bool())
  val immen = Input(Bool())
  val immed = Input(UInt(p.lsuAddrBits.W))
}

class RegfileBranchTargetIO(p: Parameters) extends Bundle {
  val data = Output(UInt(p.programCounterBits.W))
}

class Regfile(p: Parameters) extends Module {
  // The register file has 1 write port per instruction lane.
  // Additionally, there are two more write ports to service
  // the MLU/DVU, and the LSU, as they may take more cycles.
  val extraWritePorts = 2
  val io              = IO(new Bundle {
    // Decode cycle.
    val readAddr     = Vec(p.instructionLanes * 2, new RegfileReadAddrIO(p))
    val readSet      = Vec(p.instructionLanes * 2, new RegfileReadSetIO(p))
    val writeAddr    = Vec(p.instructionLanes, new RegfileWriteAddrIO(p))
    val busAddr      = Vec(p.instructionLanes, Input(new RegfileBusAddrIO(p)))
    val target       = Vec(p.instructionLanes, new RegfileBranchTargetIO(p))
    val linkPort     = new RegfileLinkPortIO(p)
    val busPort      = new RegfileBusPortIO(p)
    val debugBusPort = new Bundle {
      val idx  = Input(UInt(log2Ceil(p.scalarRegCount).W))
      val data = Output(UInt(p.xlen.W))
    }
    val debugWriteValid = Input(Bool())

    // Execute cycle.
    val readData  = Vec(p.instructionLanes * 2, new RegfileReadDataIO(p))
    val writeData = Vec(
      p.instructionLanes + extraWritePorts,
      new Bundle {
        val valid = Input(Bool())
        val bits  = new RegfileWriteDataIO(p)
      }
    )
    val writeMask =
      Vec(p.instructionLanes + extraWritePorts, new Bundle { val valid = Input(Bool()) })
    val pipelineFlush = Input(Bool())
    val scoreboard    = new Bundle {
      val regd = Output(UInt(p.scalarRegCount.W))
      val comb = Output(UInt(p.scalarRegCount.W))
    }
  })

  // The scalar registers.
  val regfile = RegInit(VecInit.fill(p.scalarRegCount)(0.U(p.xlen.W)))

  // ***************************************************************************
  // The scoreboard.
  // ***************************************************************************
  val scoreboard         = RegInit(0.U(p.scalarRegCount.W))
  val flushed_scoreboard = RegInit(0.U(p.scalarRegCount.W))

  // The write Addr:Data contract is against speculated opcodes. If an opcode
  // is in the shadow of a taken branch it will still Set:Clr the scoreboard,
  // but the actual write will be Masked.
  val scoreboard_set = io.writeAddr
    .map(x => MuxOR(x.valid, UIntToOH(x.addr, p.scalarRegCount)))
    .reduce(_ | _)

  val scoreboard_clr0 = io.writeData
    .map(x => MuxOR(x.valid, UIntToOH(x.bits.addr, p.scalarRegCount)))
    .reduce(_ | _)

  val scoreboard_clr = Cat(scoreboard_clr0(p.scalarRegCount - 1, 1), 0.U(1.W))

  when(io.pipelineFlush) {
    scoreboard         := Cat(scoreboard_set(p.scalarRegCount - 1, 1), 0.U(1.W))
    flushed_scoreboard := Cat(
      ((scoreboard | flushed_scoreboard) & ~scoreboard_clr)(p.scalarRegCount - 1, 1),
      0.U(1.W)
    )
  }.elsewhen(scoreboard_set =/= 0.U || scoreboard_clr =/= 0.U) {
    val nxtScoreboard = (scoreboard & ~scoreboard_clr) | scoreboard_set
    scoreboard         := Cat(nxtScoreboard(p.scalarRegCount - 1, 1), 0.U(1.W))
    flushed_scoreboard := Cat(
      (flushed_scoreboard & ~scoreboard_clr)(p.scalarRegCount - 1, 1),
      0.U(1.W)
    )
  }.otherwise {
    flushed_scoreboard := Cat(
      (flushed_scoreboard & ~scoreboard_clr)(p.scalarRegCount - 1, 1),
      0.U(1.W)
    )
  }

  io.scoreboard.regd := scoreboard
  io.scoreboard.comb := scoreboard & ~scoreboard_clr

  // ***************************************************************************
  // The read port response.
  // ***************************************************************************
  val readDataReady   = RegInit(VecInit(Seq.fill(p.instructionLanes * 2) { false.B }))
  val readDataBits    = RegInit(VecInit.fill(p.instructionLanes * 2)(0.U(p.xlen.W)))
  val nxtReadDataBits = Wire(Vec(p.instructionLanes * 2, UInt(p.xlen.W)))

  for (i <- 0 until (p.instructionLanes * 2)) {
    io.readData(i).valid := readDataReady(i)
    io.readData(i).data  := readDataBits(i)
  }

  // ***************************************************************************
  // One hot write ports.
  // ***************************************************************************
  val writeValid = Wire(Vec(p.scalarRegCount, Bool()))
  val writeData  = Wire(Vec(p.scalarRegCount, UInt(p.xlen.W)))

  writeValid(0) := true.B // do not require special casing of indices
  writeData(0)  := 0.U    // regfile(0) is optimized away

  for (i <- 1 until p.scalarRegCount) {
    val valid = (0 until p.instructionLanes + extraWritePorts).map(j => {
      val addrValid = (io.writeData(j).bits.addr === i.U)
      (io.writeData(j).valid && addrValid && !io.writeMask(j).valid)
    })

    val data = (0 until p.instructionLanes + extraWritePorts)
      .map(x => MuxOR(valid(x), io.writeData(x).bits.data))
      .reduce(_ | _)

    writeValid(i) := Cat(valid) =/= 0.U
    writeData(i)  := data

    assert(PopCount(valid) <= 1.U)
  }

  for (i <- 0 until p.scalarRegCount) {
    when(writeValid(i)) {
      regfile(i) := writeData(i)
    }
  }

  // We care if someone tried to write x0 (e.g. nop is encoded this way), but want
  // it separate for above mentioned optimization.
  val x0 = (0 until p.instructionLanes).map(x =>
    io.writeData(x).valid &&
      io.writeData(x).bits.addr === 0.U &&
      !io.writeMask(x).valid
  )

  // ***************************************************************************
  // Read ports with write forwarding.
  // ***************************************************************************
  val rdata  = Wire(Vec((p.instructionLanes * 2), UInt(p.xlen.W)))
  val wdata  = Wire(Vec((p.instructionLanes * 2), UInt(p.xlen.W)))
  val rwdata = Wire(Vec((p.instructionLanes * 2), UInt(p.xlen.W)))
  for (i <- 0 until (p.instructionLanes * 2)) {
    val idx   = io.readAddr(i).addr
    val write = VecAt(writeValid, idx)
    rdata(i)  := VecAt(regfile, idx)
    wdata(i)  := VecAt(writeData, idx)
    rwdata(i) := Mux(write, wdata(i), rdata(i))
  }
  io.debugBusPort.data := VecAt(regfile, io.debugBusPort.idx)

  for (i <- 0 until (p.instructionLanes * 2)) {
    nxtReadDataBits(i) := Mux(io.readSet(i).valid, io.readSet(i).value, rwdata(i))

    readDataReady(i) := io.readAddr(i).valid || io.readSet(i).valid
    readDataBits(i)  := MuxCase(
      readDataBits(i),
      Seq(
        io.readSet(i).valid  -> io.readSet(i).value,
        io.readAddr(i).valid -> rwdata(i)
      )
    )
  }

  // Bus port priority encoded address.
  val busAddr  = Wire(Vec(p.instructionLanes, UInt(p.lsuAddrBits.W)))
  val busValid = Cat((0 until p.instructionLanes).reverse.map(x => io.busAddr(x).valid))

  for (i <- 0 until p.instructionLanes) {
    busAddr(i) := Mux(io.busAddr(i).immen, rdata(2 * i) + io.busAddr(i).immed, rdata(2 * i))
  }

  for (i <- 0 until p.instructionLanes) {
    io.busPort.addr(i) := busAddr(i)
    io.busPort.data(i) := nxtReadDataBits(2 * i + 1)
  }

  // Branch target address combinatorial.
  for (i <- 0 until p.instructionLanes) {
    io.target(i).data := busAddr(i)
  }

  // ***************************************************************************
  // Link port.
  // ***************************************************************************
  io.linkPort.valid := !scoreboard(1)
  io.linkPort.value := regfile(1)

  // ***************************************************************************
  // Assertions.
  // ***************************************************************************
  for (i <- 0 until p.instructionLanes) {
    assert(busAddr(i).getWidth == p.lsuAddrBits)
  }

  for (i <- 0 until p.instructionLanes + extraWritePorts) {
    for (j <- (i + 1) until p.instructionLanes + extraWritePorts) {
      // Delay the failure a cycle for debugging purposes.
      val write_fail = RegInit(false.B)
      write_fail := io.writeData(i).valid && io.writeData(j).valid &&
        io.writeData(i).bits.addr === io.writeData(j).bits.addr &&
        io.writeData(i).bits.addr =/= 0.U
      assert(!write_fail)
    }
  }

  val scoreboard_error = RegInit(false.B)
  val dm_write_valid   = io.debugWriteValid
  val valid_clr_mask   = scoreboard | flushed_scoreboard
  scoreboard_error := ((valid_clr_mask & scoreboard_clr) =/= scoreboard_clr) && !dm_write_valid
  assert(!scoreboard_error)
}

object EmitRegfile extends App {
  val p = new Parameters
  ChiselStage.emitSystemVerilogFile(new Regfile(p), args)
}
