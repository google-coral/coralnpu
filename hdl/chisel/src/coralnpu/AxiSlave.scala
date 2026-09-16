// Copyright 2024 Google LLC
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

import bus._
import common._

class RWAxiAddress(p: Parameters) extends Bundle {
  val addr  = new AxiAddress(p.axi2AddrBits, p.axi2DataBits, p.axi2IdBits)
  val write = Bool()
}

class ReadResult(idBits: Int) extends Bundle {
  val id   = UInt(idBits.W)
  val last = Bool()
}

object ReadResult {
  def apply(idBits: Int, id: UInt, last: Bool): ReadResult = {
    val result = Wire(new ReadResult(idBits))
    result.id   := id
    result.last := last
    result
  }
}

class AxiSlave(p: Parameters) extends Module {
  val io = IO(new Bundle {
    val axi    = Flipped(new AxiMasterIO(p.axi2AddrBits, p.axi2DataBits, p.axi2IdBits))
    val fabric = new FabricIO(p)
    // Output indicating that a transaction is in progress
    val txnInProgress = Output(Bool())
    // Input indicating that the peripheral is busy -- do not accept AXI transactions
    val periBusy = Input(Bool())
  })

  // Arbitrate Read/Write channels
  val addrArbiter = Module(
    new CoralNPURRArbiter(new AxiAddress(p.axi2AddrBits, p.axi2DataBits, p.axi2IdBits), 2)
  )
  addrArbiter.io.in(0) <> Queue(io.axi.read.addr, 2)
  addrArbiter.io.in(1) <> Queue(io.axi.write.addr, 2)
  val axiAddr = Wire(Decoupled(new RWAxiAddress(p)))
  axiAddr.valid      := addrArbiter.io.out.valid
  axiAddr.bits.addr  := addrArbiter.io.out.bits
  axiAddr.bits.write := (addrArbiter.io.chosen === 1.U)

  addrArbiter.io.out.ready := axiAddr.ready
  val axiAddrCmd  = Queue(axiAddr, 1, pipe = true)
  val writeActive = axiAddrCmd.valid && axiAddrCmd.bits.write
  val readActive  = axiAddrCmd.valid && !axiAddrCmd.bits.write
  // This register tracks the address over multiple beats in a burst
  val cmdAddr = RegInit(0.U(p.axi2AddrBits.W))

  // Write
  val writeData     = Queue(io.axi.write.data, 3)
  val writeResponse = Wire(Decoupled(new AxiWriteResponse(p.axi2IdBits)))
  io.axi.write.resp <> Queue(writeResponse, 2)

  /// Set fabric write command. Note that even if valid is asserted,
  /// the write won't occur if io.periBusy is high
  val maybeWriteData = writeActive && // Write must be active
    writeData.valid && // Write data packet must be valid
    writeResponse.ready // Make sure resp can be sent
  io.fabric.writeDataAddr.valid := maybeWriteData
  io.fabric.writeDataAddr.bits  := cmdAddr
  io.fabric.writeDataBits       := writeData.bits.data
  io.fabric.writeDataStrb       := writeData.bits.strb

  /// Check if ok to write
  writeData.ready := maybeWriteData && !io.periBusy

  /// Enqueue write response
  writeResponse.valid     := writeData.fire && writeData.bits.last
  writeResponse.bits.id   := axiAddrCmd.bits.addr.id
  writeResponse.bits.resp := Mux(
    io.fabric.writeResp,
    AxiResponseType.OKAY.asUInt,
    AxiResponseType.SLVERR.asUInt
  )

  // Read
  val readDataQueueSize = 3
  val readDataQueue     = Module(
    new Queue(new AxiReadData(p.axi2DataBits, p.axi2IdBits), readDataQueueSize)
  )
  val readData = readDataQueue.io.enq
  io.axi.read.data <> readDataQueue.io.deq

  val readIssued  = RegInit(MakeInvalid(new ReadResult(p.axi2IdBits)))
  val readsIssued = RegInit(
    0.U((axiAddrCmd.bits.addr.len.getWidth + 1).W)
  ) // Tracks number of readData issued

  /// Check if we can issue a read
  val maybeIssueRead = readActive &&
    ((readDataQueueSize.U - readDataQueue.io.count) >= 2.U)
  val issueRead       = maybeIssueRead && !io.periBusy
  val readsIssuedNext = Mux(axiAddrCmd.fire, 0.U, readsIssued + issueRead)
  val lastRead        = (readsIssued === axiAddrCmd.bits.addr.len)

  readIssued  := MakeValid(issueRead, ReadResult(p.axi2IdBits, axiAddrCmd.bits.addr.id, lastRead))
  readsIssued := readsIssuedNext

  /// Forward read command to SRAM
  /// Note: maybeIssueRead is used here instead of issue read so the downstream
  /// arbiter can route the correct periBusy signal back. If periBusy is raised
  /// the read operation is not conducted.
  io.fabric.readDataAddr.valid := maybeIssueRead
  io.fabric.readDataAddr.bits  := cmdAddr

  /// Response from SRAM, cycle later
  readData.valid     := readIssued.valid
  readData.bits.data := io.fabric.readData.bits
  readData.bits.id   := readIssued.bits.id
  readData.bits.resp := Mux(
    io.fabric.readData.valid,
    AxiResponseType.OKAY.asUInt,
    AxiResponseType.SLVERR.asUInt
  )
  readData.bits.last := readIssued.bits.last

  /// Ensure read is enqueued
  assert(!readIssued.valid || readDataQueue.io.enq.ready)

  // Update address between beats
  val wrapWindowSize =
    ((axiAddrCmd.bits.addr.len +& 1.U) << axiAddrCmd.bits.addr.size).pad(p.axi2AddrBits)
  val baseAddrMask        = ~(wrapWindowSize - 1.U(p.axi2AddrBits.W))
  val cmdAddrBase         = axiAddrCmd.bits.addr.addr & baseAddrMask
  val (burst, burstValid) = AxiBurstType.safe(axiAddrCmd.bits.addr.burst)
  val validBurst          = axiAddrCmd.valid && burstValid
  val addrNext            = MuxUpTo1H(
    cmdAddr,
    Seq(
      (validBurst && (burst === AxiBurstType.FIXED)) -> cmdAddr,
      (validBurst && (burst === AxiBurstType.INCR))  ->
        (cmdAddr + (1.U << axiAddrCmd.bits.addr.size)),
      (validBurst && (burst === AxiBurstType.WRAP)) -> {
        val newAddr        = cmdAddr +& (1.U << axiAddrCmd.bits.addr.size)
        val newAddrWrapped =
          Mux(
            newAddr >= (cmdAddrBase +& wrapWindowSize),
            cmdAddrBase,
            newAddr(p.axi2AddrBits - 1, 0)
          )
        newAddrWrapped
      }
    )
  )

  cmdAddr := MuxCase(
    cmdAddr,
    Seq(
      // New command
      axiAddr.fire -> axiAddr.bits.addr.addr,
      // Updates
      (writeActive && io.fabric.writeDataAddr.valid && !io.periBusy) -> addrNext,
      (readActive && io.fabric.readDataAddr.valid && !io.periBusy)   -> addrNext
    )
  )

  // Move to the next command when done
  axiAddrCmd.ready := MuxCase(
    false.B,
    Seq(
      writeActive -> writeResponse.fire,
      readActive  -> (issueRead && lastRead)
    )
  )

  io.txnInProgress := axiAddrCmd.valid
}
