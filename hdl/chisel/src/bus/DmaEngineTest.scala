// Copyright 2026 Google LLC
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

package bus

import chisel3._
import chisel3.simulator.scalatest.ChiselSim
import org.scalatest.freespec.AnyFreeSpec
import coralnpu.Parameters

class DmaEngineSpec extends AnyFreeSpec with ChiselSim {
  val hostP = new Parameters
  hostP.lsuDataBits = 128
  val hostTlulP = hostP.toTLUL()

  val deviceP = new Parameters
  deviceP.lsuDataBits = 32
  deviceP.axi2IdBits = 10
  val deviceTlulP = deviceP.toTLUL()

  // --- Device-port (CSR) TL-UL helpers ---

  def csrWrite(tl: OpenTitanTileLink.Host2Device, clock: Clock, addr: UInt, data: UInt): Unit = {
    tl.a.valid.poke(true.B)
    tl.a.bits.opcode.poke(TLULOpcodesA.PutFullData.asUInt)
    tl.a.bits.address.poke(addr)
    tl.a.bits.data.poke(data)
    tl.a.bits.mask.poke(0xf.U)
    while (tl.a.ready.peek().litValue == 0) clock.step()
    clock.step()
    tl.a.valid.poke(false.B)
    while (tl.d.valid.peek().litValue == 0) clock.step()
    tl.d.ready.poke(true.B)
    clock.step()
    tl.d.ready.poke(false.B)
  }

  def csrRead(tl: OpenTitanTileLink.Host2Device, clock: Clock, addr: UInt): (BigInt, Boolean) = {
    tl.a.valid.poke(true.B)
    tl.a.bits.opcode.poke(TLULOpcodesA.Get.asUInt)
    tl.a.bits.address.poke(addr)
    while (tl.a.ready.peek().litValue == 0) clock.step()
    clock.step()
    tl.a.valid.poke(false.B)
    while (tl.d.valid.peek().litValue == 0) clock.step()
    val data  = tl.d.bits.data.peek().litValue
    val error = tl.d.bits.error.peek().litValue != 0
    tl.d.ready.poke(true.B)
    clock.step()
    tl.d.ready.poke(false.B)
    (data, error)
  }

  def csrReadData(tl: OpenTitanTileLink.Host2Device, clock: Clock, addr: UInt): BigInt =
    csrRead(tl, clock, addr)._1

  /** Write a 32-bit word to simulated memory (little-endian). */
  def memWrite32(mem: scala.collection.mutable.Map[Long, Byte], addr: Long, value: Long): Unit = {
    for (i <- 0 until 4) mem(addr + i) = ((value >> (i * 8)) & 0xff).toByte
  }

  /** Read a 32-bit word from simulated memory (little-endian). */
  def memRead32(mem: scala.collection.mutable.Map[Long, Byte], addr: Long): Long = {
    var v = 0L
    for (i <- 0 until 4) v |= (mem.getOrElse(addr + i, 0.toByte).toLong & 0xff) << (i * 8)
    v
  }

  /** Build a 32-byte descriptor in memory. */
  def buildDescriptor(
    mem: scala.collection.mutable.Map[Long, Byte],
    descAddr: Long,
    srcAddr: Long,
    dstAddr: Long,
    xferLen: Int,
    xferWidth: Int = 2,
    srcFixed: Boolean = false,
    dstFixed: Boolean = false,
    pollEn: Boolean = false,
    nextDesc: Long = 0,
    pollAddr: Long = 0,
    pollMask: Long = 0,
    pollValue: Long = 0
  ): Unit = {
    memWrite32(mem, descAddr + 0x00, srcAddr)
    memWrite32(mem, descAddr + 0x04, dstAddr)
    val flags = (xferLen & 0xffffff).toLong |
      ((xferWidth & 0x7).toLong << 24) |
      ((if (srcFixed) 1L else 0L) << 27) |
      ((if (dstFixed) 1L else 0L) << 28) |
      ((if (pollEn) 1L else 0L) << 29)
    memWrite32(mem, descAddr + 0x08, flags)
    memWrite32(mem, descAddr + 0x0c, nextDesc)
    memWrite32(mem, descAddr + 0x10, pollAddr)
    memWrite32(mem, descAddr + 0x14, pollMask)
    memWrite32(mem, descAddr + 0x18, pollValue)
    memWrite32(mem, descAddr + 0x1c, 0)
  }

  /** Reactive memory model: step clock while servicing host port transactions. Runs for `maxCycles`
    * or until DMA is no longer busy.
    */
  def runDmaWithMemory(
    dut: DmaEngine,
    mem: scala.collection.mutable.Map[Long, Byte],
    maxCycles: Int = 2000
  ): Int = {
    val host     = dut.io.tl_host
    var txnCount = 0

    for (cycle <- 0 until maxCycles) {
      // Default: ready to accept A, no D response
      host.a.ready.poke(true.B)
      host.d.valid.poke(false.B)

      // Check if DMA is presenting an A channel request
      if (host.a.valid.peek().litValue != 0) {
        // Capture request details (they're combinationally valid now)
        val opcode  = host.a.bits.opcode.peek().litValue.toInt
        val address = host.a.bits.address.peek().litValue.toLong
        val size    = host.a.bits.size.peek().litValue.toInt
        val nbytes  = 1 << size
        val wdata   = host.a.bits.data.peek().litValue

        // Step: a.fire occurs (valid=1, ready=1 on this edge)
        dut.clock.step()

        // Now DMA has moved to response-wait state.
        // Present D channel response.
        host.a.ready.poke(false.B)
        host.d.valid.poke(true.B)
        host.d.bits.source.poke(0.U)
        host.d.bits.error.poke(false.B)
        host.d.bits.sink.poke(0.U)
        host.d.bits.param.poke(0.U)
        host.d.bits.size.poke(size.U)

        if (opcode == 4) {
          // Get: read from mem, place data at correct byte lane per TL-UL spec
          var rdata      = BigInt(0)
          val busBytes   = 16 // 128-bit bus
          val byteOffset = (address % busBytes).toInt
          for (i <- 0 until nbytes) {
            val b = mem.getOrElse(address + i, 0.toByte) & 0xff
            rdata = rdata | (BigInt(b) << ((byteOffset + i) * 8))
          }
          host.d.bits.opcode.poke(1.U) // AccessAckData
          host.d.bits.data.poke(rdata.U)
        } else {
          // PutFullData: write to mem, extract data from correct byte lane
          val busBytes   = 16 // 128-bit bus
          val byteOffset = (address % busBytes).toInt
          for (i <- 0 until nbytes) {
            mem(address + i) = ((wdata >> ((byteOffset + i) * 8)) & 0xff).toByte
          }
          host.d.bits.opcode.poke(0.U) // AccessAck
          host.d.bits.data.poke(0.U)
        }

        // Wait for D to be accepted
        var dWait = 0
        while (host.d.ready.peek().litValue == 0 && dWait < 100) {
          dut.clock.step()
          dWait += 1
        }
        // Step: d.fire occurs
        dut.clock.step()
        host.d.valid.poke(false.B)
        txnCount += 1
      } else {
        dut.clock.step()
      }
    }
    txnCount
  }

  // --- Tests ---

  "DmaEngine Operations" in {
    simulate(new DmaEngine(hostTlulP, deviceTlulP)) { dut =>
      // CSR Register Access
      {
        dut.reset.poke(true.B)
        dut.clock.step()
        dut.reset.poke(false.B)

        csrWrite(dut.io.tl_device, dut.clock, 0x08.U, 0xdead0000L.U)
        assert(csrReadData(dut.io.tl_device, dut.clock, 0x08.U) == 0xdead0000L)

        csrWrite(dut.io.tl_device, dut.clock, 0x00.U, 0x01.U)
        val ctrl = csrReadData(dut.io.tl_device, dut.clock, 0x00.U)
        assert((ctrl & 1) == 1)

        val status = csrReadData(dut.io.tl_device, dut.clock, 0x04.U)
        assert(status == 0)
      }

      // CSR Error on Invalid Address
      {
        dut.reset.poke(true.B)
        dut.clock.step()
        dut.reset.poke(false.B)

        val (_, error) = csrRead(dut.io.tl_device, dut.clock, 0x100.U)
        assert(error, "Invalid address should return error")
      }

      // CSR Error on Write to Read-Only Register
      {
        dut.reset.poke(true.B)
        dut.clock.step()
        dut.reset.poke(false.B)

        dut.io.tl_device.a.valid.poke(true.B)
        dut.io.tl_device.a.bits.opcode.poke(TLULOpcodesA.PutFullData.asUInt)
        dut.io.tl_device.a.bits.address.poke(0x04.U)
        dut.io.tl_device.a.bits.data.poke(1.U)
        dut.io.tl_device.a.bits.mask.poke(0xf.U)
        while (dut.io.tl_device.a.ready.peek().litValue == 0) dut.clock.step()
        dut.clock.step()
        dut.io.tl_device.a.valid.poke(false.B)
        while (dut.io.tl_device.d.valid.peek().litValue == 0) dut.clock.step()
        assert(dut.io.tl_device.d.bits.error.peek().litValue != 0)
      }

      // Simple Mem-to-Mem Transfer
      {
        dut.reset.poke(true.B)
        dut.clock.step()
        dut.reset.poke(false.B)

        val mem = scala.collection.mutable.Map[Long, Byte]()

        // Source data: 16 bytes at 0x1000
        for (i <- 0 until 16) mem(0x1000L + i) = (0xa0 + i).toByte

        // Descriptor at 0x2000: 16 bytes from 0x1000 to 0x3000, 4-byte beats
        buildDescriptor(mem, 0x2000L, 0x1000L, 0x3000L, xferLen = 16, xferWidth = 2)

        // Program DMA via CSR
        csrWrite(dut.io.tl_device, dut.clock, 0x08.U, 0x2000.U) // DESC_ADDR
        csrWrite(dut.io.tl_device, dut.clock, 0x00.U, 0x03.U)   // CTRL: enable + start

        // Run reactive memory model
        val _ = runDmaWithMemory(dut, mem, maxCycles = 500)

        val status = csrReadData(dut.io.tl_device, dut.clock, 0x04.U)
        assert((status & 0x2) != 0, s"STATUS.done should be set, got 0x${status.toString(16)}")
        assert((status & 0x4) == 0, s"STATUS.error should be clear, got 0x${status.toString(16)}")

        // Verify destination
        for (i <- 0 until 16) {
          val expected = (0xa0 + i).toByte
          val actual   = mem.getOrElse(0x3000L + i, 0.toByte)
          assert(
            actual == expected,
            s"Byte $i: expected 0x${(expected & 0xff).toHexString}, got 0x${(actual & 0xff).toHexString}"
          )
        }
      }

      // Descriptor Chaining
      {
        dut.reset.poke(true.B)
        dut.clock.step()
        dut.reset.poke(false.B)

        val mem = scala.collection.mutable.Map[Long, Byte]()

        for (i <- 0 until 8) mem(0x1000L + i) = (0x10 + i).toByte
        for (i <- 0 until 8) mem(0x1100L + i) = (0x20 + i).toByte

        buildDescriptor(
          mem,
          0x2000L,
          0x1000L,
          0x3000L,
          xferLen = 8,
          xferWidth = 2,
          nextDesc = 0x2020L
        )
        buildDescriptor(mem, 0x2020L, 0x1100L, 0x3100L, xferLen = 8, xferWidth = 2)

        csrWrite(dut.io.tl_device, dut.clock, 0x08.U, 0x2000.U)
        csrWrite(dut.io.tl_device, dut.clock, 0x00.U, 0x03.U)

        runDmaWithMemory(dut, mem, maxCycles = 500)

        val status = csrReadData(dut.io.tl_device, dut.clock, 0x04.U)
        assert((status & 0x2) != 0, s"STATUS.done should be set, got 0x${status.toString(16)}")

        for (i <- 0 until 8) {
          assert(
            mem.getOrElse(0x3000L + i, 0.toByte) == (0x10 + i).toByte,
            s"Chain 0 byte $i mismatch"
          )
        }
        for (i <- 0 until 8) {
          assert(
            mem.getOrElse(0x3100L + i, 0.toByte) == (0x20 + i).toByte,
            s"Chain 1 byte $i mismatch"
          )
        }
      }

      // Fixed Destination Address (Mem to Periph)
      {
        dut.reset.poke(true.B)
        dut.clock.step()
        dut.reset.poke(false.B)

        val mem = scala.collection.mutable.Map[Long, Byte]()

        memWrite32(mem, 0x1000L, 0xaabbccddL)
        memWrite32(mem, 0x1004L, 0x11223344L)
        memWrite32(mem, 0x1008L, 0x55667788L)

        // 12 bytes from 0x1000 to fixed 0x5000
        buildDescriptor(
          mem,
          0x2000L,
          0x1000L,
          0x5000L,
          xferLen = 12,
          xferWidth = 2,
          dstFixed = true
        )

        csrWrite(dut.io.tl_device, dut.clock, 0x08.U, 0x2000.U)
        csrWrite(dut.io.tl_device, dut.clock, 0x00.U, 0x03.U)

        runDmaWithMemory(dut, mem, maxCycles = 500)

        // With dst_fixed=true, all 3 writes go to 0x5000. Check the last value written.
        val finalVal = memRead32(mem, 0x5000L)
        assert(finalVal == 0x55667788L, s"Final value at fixed addr: 0x${finalVal.toHexString}")

        val status = csrReadData(dut.io.tl_device, dut.clock, 0x04.U)
        assert((status & 0x2) != 0, "STATUS.done should be set")
      }

      // Abort Transfer
      {
        dut.reset.poke(true.B)
        dut.clock.step()
        dut.reset.poke(false.B)

        val mem = scala.collection.mutable.Map[Long, Byte]()

        for (i <- 0 until 64) mem(0x1000L + i) = i.toByte
        buildDescriptor(mem, 0x2000L, 0x1000L, 0x3000L, xferLen = 64, xferWidth = 2)

        csrWrite(dut.io.tl_device, dut.clock, 0x08.U, 0x2000.U)
        csrWrite(dut.io.tl_device, dut.clock, 0x00.U, 0x03.U)

        // Let DMA start but don't service host port — it will be stuck waiting for A.ready
        dut.io.tl_host.a.ready.poke(false.B)
        dut.clock.step(5)

        // Abort
        csrWrite(dut.io.tl_device, dut.clock, 0x00.U, 0x05.U) // enable=1, abort=1

        dut.clock.step(5)

        val status = csrReadData(dut.io.tl_device, dut.clock, 0x04.U)
        assert(
          (status & 0x4) != 0,
          s"STATUS.error should be set after abort, got 0x${status.toString(16)}"
        )
        assert(
          (status & 0x1) == 0,
          s"STATUS.busy should be clear after abort, got 0x${status.toString(16)}"
        )
      }
    }
  }
}
