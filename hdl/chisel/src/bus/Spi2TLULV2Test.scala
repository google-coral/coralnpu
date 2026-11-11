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
import chisel3.util._
import chisel3.simulator.scalatest.ChiselSim
import coralnpu.Parameters
import org.scalatest.freespec.AnyFreeSpec

// ---------------------------------------------------------------------------
// Test wrapper module — replicates spi_v2_tb_top.sv in Chisel
// ---------------------------------------------------------------------------

class Spi2TLULV2TestWrapper(val dataWidth: Int = 1) extends Module {
  val io = IO(new Bundle {
    val spi_clk_in = Input(Bool())
    val spi_csb    = Input(Bool())
    val spi_mosi   = Input(UInt(dataWidth.W))
    val spi_miso   = Output(UInt(dataWidth.W))

    // TL-A capture outputs (last beat)
    val tl_a_captured    = Output(Bool())
    val tl_a_cap_opcode  = Output(UInt(3.W))
    val tl_a_cap_address = Output(UInt(32.W))
    val tl_a_cap_data    = Output(UInt(128.W))
    val tl_a_cap_count   = Output(UInt(32.W))

    // TL-A first-beat capture + reset
    val tl_a_first_address = Output(UInt(32.W))
    val tl_a_first_data    = Output(UInt(128.W))
    val tl_a_first_reset   = Input(Bool())

    // Optional TL-D stall control and soft-reset observation
    val tl_d_stall = Input(Bool())
    val sys_rst_o  = Output(Bool())
  })

  var p = new Parameters()
  p.lsuDataBits = 128
  val tlul_p = p.toTLUL()
  val v2     = Module(new Spi2TLULV2(tlul_p, dataWidth))

  // Clock and reset wiring
  v2.io.spi_clk   := io.spi_clk_in.asClock
  v2.io.spi_rst_n := !io.spi_csb

  // MOSI: always valid, data from spi_mosi
  v2.io.q_mosi_pin.valid := true.B
  v2.io.q_mosi_pin.bits  := io.spi_mosi

  // MISO: always ready, output gated by valid
  v2.io.q_miso_pin.ready := true.B
  io.spi_miso            := Mux(v2.io.q_miso_pin.valid, v2.io.q_miso_pin.bits, 0.U(dataWidth.W))

  // -------------------------------------------------------------------------
  // TileLink auto-responder (mirrors spi_v2_tb_top.sv)
  // -------------------------------------------------------------------------
  // V2 TL-A is 217 bits: Cat(opcode(3), param(3), size(4), source(8),
  //   addr(32), mask(16), data(128), user(23))
  // V2 TL-D is 162 bits: Cat(opcode(3), param(3), size(4), source(8),
  //   sink(1), data(128), user(14), error(1))
  // -------------------------------------------------------------------------
  val TL_GET             = 4.U(3.W)
  val TL_ACCESS_ACK      = 0.U(3.W)
  val TL_ACCESS_ACK_DATA = 1.U(3.W)

  val respPending = RegInit(false.B)
  val respReq     = RegInit(0.U.asTypeOf(new OpenTitanTileLink.A_Channel(tlul_p)))
  val tlAReady    = RegInit(true.B)

  v2.io.q_tl_a.ready := tlAReady

  val aValid = v2.io.q_tl_a.valid
  val aData  = v2.io.q_tl_a.bits

  // Single-driver style: accept A → latch + deassert ready; D handshake → clear + reassert
  val acceptA   = aValid && tlAReady && !respPending
  val completeD = respPending && !io.tl_d_stall && v2.io.q_tl_d.ready

  respPending := Mux(acceptA, true.B, Mux(completeD, false.B, respPending))
  respReq     := Mux(acceptA, aData, respReq)
  tlAReady    := Mux(acceptA, false.B, Mux(completeD, true.B, tlAReady))

  // Decode latched request (217-bit positions)
  val reqOpcode = respReq.opcode
  val reqParam  = respReq.param
  val reqSize   = respReq.size
  val reqSource = respReq.source
  val reqAddr   = respReq.address

  val respOpcode =
    Mux(reqOpcode === TLULOpcodesA.Get.asUInt, TLULOpcodesD.AccessAckData, TLULOpcodesD.AccessAck)
  val respData = Cat(0.U(96.W), reqAddr)

  v2.io.q_tl_d.valid       := respPending && !io.tl_d_stall
  v2.io.q_tl_d.bits.opcode := respOpcode.asUInt
  v2.io.q_tl_d.bits.param  := 0.U(3.W)
  v2.io.q_tl_d.bits.size   := reqSize
  v2.io.q_tl_d.bits.source := reqSource
  v2.io.q_tl_d.bits.sink   := 0.U(1.W)
  v2.io.q_tl_d.bits.data   := respData
  v2.io.q_tl_d.bits.user   := 0.U.asTypeOf(new OpenTitanTileLink_D_User)
  v2.io.q_tl_d.bits.error  := 0.U(1.W)

  // -------------------------------------------------------------------------
  // TL-A capture registers (latch on A-channel handshake)
  // -------------------------------------------------------------------------
  val aHandshake = aValid && tlAReady
  val captured   = RegInit(false.B)
  val capOpcode  = RegInit(0.U(3.W))
  val capAddress = RegInit(0.U(32.W))
  val capData    = RegInit(0.U(128.W))
  val capCount   = RegInit(0.U(32.W))

  // First-beat capture: latched on the first handshake after count was last
  // snapshot by the test (i.e., the first beat of each multi-beat burst).
  val firstCapAddress = RegInit(0.U(32.W))
  val firstCapData    = RegInit(0.U(128.W))
  val firstCapDone    = RegInit(false.B)

  captured   := Mux(aHandshake, true.B, captured)
  capOpcode  := Mux(aHandshake, aData.opcode, capOpcode)
  capAddress := Mux(aHandshake, aData.address, capAddress)
  capData    := Mux(aHandshake, aData.data, capData)
  capCount   := Mux(aHandshake, capCount + 1.U, capCount)

  when(io.tl_a_first_reset) {
    firstCapDone    := false.B
    firstCapAddress := 0.U
    firstCapData    := 0.U
  }.elsewhen(aHandshake && !firstCapDone) {
    firstCapAddress := aData.address
    firstCapData    := aData.data
    firstCapDone    := true.B
  }

  io.tl_a_captured      := captured
  io.tl_a_cap_opcode    := capOpcode
  io.tl_a_cap_address   := capAddress
  io.tl_a_cap_data      := capData
  io.tl_a_cap_count     := capCount
  io.tl_a_first_address := firstCapAddress
  io.tl_a_first_data    := firstCapData
  io.sys_rst_o          := v2.io.sys_rst_o
}

// ---------------------------------------------------------------------------
// Test suite — ports all 6 C++ tests
// ---------------------------------------------------------------------------

class Spi2TLULV2Spec extends AnyFreeSpec with ChiselSim {

  // Sys clock period = 10 units (SYS_HALF=5), SPI period = 13 units (SPI_HALF=6.5).
  // We use integer ratio: SYS_HALF=10, SPI_HALF=13.
  // Each clock.step(1) is one "sim unit". SPI toggles when the phase counter says so.
  val SYS_HALF = 10
  val SPI_HALF = 13

  /** Run the simulation with dual-clock stepping. The main clock.step() drives the sys domain. SPI
    * clock is toggled as a Bool input at a 10:13 ratio to approximate truly async clocks.
    */
  def withDualClock(dataWidth: Int = 1)(body: Spi2TLULV2TestWrapper => Unit): Unit = {
    simulate(new Spi2TLULV2TestWrapper(dataWidth)) { dut =>
      // Reset — toggle SPI clock during reset so system-reset-only
      // CDC FIFOs (clocked by spi_clk) see the reset posedge.
      dut.reset.poke(true.B)
      dut.io.spi_csb.poke(true.B)
      dut.io.spi_mosi.poke(0.U(dataWidth.W))
      dut.io.spi_clk_in.poke(false.B)
      dut.io.tl_a_first_reset.poke(false.B)
      dut.io.tl_d_stall.poke(false.B)
      for (_ <- 0 until 5) {
        dut.io.spi_clk_in.poke(true.B)
        dut.clock.step(1)
        dut.io.spi_clk_in.poke(false.B)
        dut.clock.step(1)
      }
      dut.reset.poke(false.B)
      dut.clock.step(5)

      body(dut)
    }
  }

  def withDualClock(body: Spi2TLULV2TestWrapper => Unit): Unit = withDualClock(1)(body)

  /** Dual-clock tick state — tracks when to toggle SPI clock relative to sys clock. */
  class DualClockState(dut: Spi2TLULV2TestWrapper) {
    var sysTime: Long     = 0
    var nextSysEdge: Long = SYS_HALF
    var nextSpiEdge: Long = SPI_HALF
    var spiLevel: Boolean = false

    /** Advance one sim time unit, toggling whichever clock(s) fire. Returns 's', 'p', or 'b'. */
    def tick(): Char = {
      if (nextSysEdge < nextSpiEdge) {
        sysTime = nextSysEdge
        nextSysEdge += SYS_HALF
        dut.clock.step(1)
        's'
      } else if (nextSpiEdge < nextSysEdge) {
        sysTime = nextSpiEdge
        spiLevel = !spiLevel
        dut.io.spi_clk_in.poke(spiLevel.B)
        nextSpiEdge += SPI_HALF
        // Don't step sys clock — just toggle SPI
        // But we need at least one eval to propagate. Step sys clock to advance simulation.
        dut.clock.step(1)
        'p'
      } else {
        // Both edges coincide
        sysTime = nextSysEdge
        spiLevel = !spiLevel
        dut.io.spi_clk_in.poke(spiLevel.B)
        nextSysEdge += SYS_HALF
        nextSpiEdge += SPI_HALF
        dut.clock.step(1)
        'b'
      }
    }

    /** Advance until n SPI posedges have occurred. */
    def spiCycles(n: Int): Unit = {
      var count = 0
      while (count < n) {
        val w = tick()
        if ((w == 'p' || w == 'b') && spiLevel) count += 1
      }
    }

    /** Advance until n sys posedges have occurred. */
    def bothCycles(n: Int): Unit = {
      var count = 0
      while (count < n) {
        val w = tick()
        if (w == 's' || w == 'b') count += 1
      }
    }

    // SPI protocol helpers

    /** Transfer one 8-bit byte MSB-first across (8 / dataWidth) SPI cycles (requires dataWidth <=
      * 8).
      */
    def spiXferByte(tx: Int): Unit = {
      val w = dut.dataWidth
      require(
        w <= 8,
        s"spiXferByte requires dataWidth <= 8 (got $w); use spiXferWord16 for 16-bit transfers."
      )
      if (w == 1) {
        for (bit <- 7 to 0 by -1) {
          dut.io.spi_mosi.poke(((tx >> bit) & 1).U(1.W))
          spiCycles(1)
        }
      } else {
        val mask = (1 << w) - 1
        for (bit <- (8 - w) to 0 by -w) {
          dut.io.spi_mosi.poke(((tx >> bit) & mask).U(w.W))
          spiCycles(1)
        }
      }
    }

    /** Receive one 8-bit byte MSB-first across (8 / dataWidth) SPI cycles (requires dataWidth <=
      * 8).
      */
    def spiRecvByte(): Int = {
      var rx = 0
      val w  = dut.dataWidth
      require(
        w <= 8,
        s"spiRecvByte requires dataWidth <= 8 (got $w); use spiRecvWord16 for 16-bit transfers."
      )
      if (w == 1) {
        for (_ <- 7 to 0 by -1) {
          dut.io.spi_mosi.poke(0.U(1.W))
          spiCycles(1)
          rx = (rx << 1) | (if (dut.io.spi_miso.peek().litValue != 0) 1 else 0)
        }
      } else {
        val mask = (1 << w) - 1
        for (_ <- (8 - w) to 0 by -w) {
          dut.io.spi_mosi.poke(0.U(w.W))
          val valRead = dut.io.spi_miso.peek().litValue.toInt & mask
          rx = (rx << w) | valRead
          spiCycles(1)
        }
      }
      rx
    }

    def csbAssert(): Unit = {
      dut.io.spi_csb.poke(false.B)
      dut.io.spi_mosi.poke(0.U(dut.dataWidth.W))
    }

    def csbDeassert(): Unit = {
      dut.io.spi_mosi.poke(0.U(dut.dataWidth.W))
      // Let DmaEngine finish draining CDC FIFOs before CSB deasserts
      // (AsyncQueue safe mode coordinates reset on CSB deassert)
      bothCycles(500)
      dut.io.spi_csb.poke(true.B)
      bothCycles(50)
    }

    /** Deassert CSB immediately without draining CDC FIFOs to test mid-frame aborts. */
    def csbAbortNow(): Unit = {
      dut.io.spi_mosi.poke(0.U(dut.dataWidth.W))
      dut.io.spi_csb.poke(true.B)
      // Clock idle SPI cycles while CSB=1 so AsyncQueue reset sync settles
      spiCycles(10)
      bothCycles(20)
    }

    /** Transfer one 16-bit halfword in a single SPI cycle (requires dataWidth == 16). */
    def spiXferWord16(tx: Int): Unit = {
      require(dut.dataWidth == 16, s"spiXferWord16 requires dataWidth == 16, got ${dut.dataWidth}")
      dut.io.spi_mosi.poke((tx & 0xffff).U(dut.dataWidth.W))
      spiCycles(1)
    }

    /** Sample one 16-bit halfword from MISO in a single SPI cycle (requires dataWidth == 16). */
    def spiRecvWord16(): Int = {
      require(dut.dataWidth == 16, s"spiRecvWord16 requires dataWidth == 16, got ${dut.dataWidth}")
      dut.io.spi_mosi.poke(0.U(dut.dataWidth.W))
      spiCycles(1)
      dut.io.spi_miso.peek().litValue.toInt & 0xffff
    }

    /** Poll 16-bit MISO until the 0x00AA write-completion acknowledgement arrives. */
    def spiWaitWriteAck16(maxCycles: Int = 500): Boolean = {
      var cycles = 0
      while (cycles < maxCycles) {
        if (spiRecvWord16() == 0x00aa) return true
        cycles += 1
      }
      false
    }

    def spiSendHeader(op: Int, addr: Long, len: Int): Unit = {
      if (dut.dataWidth == 16) {
        spiXferWord16(op & 0xff)
        spiXferWord16(len & 0xffff)
        spiXferWord16((addr & 0xffff).toInt)
        spiXferWord16(((addr >> 16) & 0xffff).toInt)
      } else {
        spiXferByte(op & 0xff)
        spiXferByte(((addr >> 24) & 0xff).toInt)
        spiXferByte(((addr >> 16) & 0xff).toInt)
        spiXferByte(((addr >> 8) & 0xff).toInt)
        spiXferByte((addr & 0xff).toInt)
        spiXferByte((len >> 8) & 0xff)
        spiXferByte(len & 0xff)
      }
    }

    /** Collect n raw MISO bits. Returns array of bytes packed MSB-first per byte. */
    def collectMisoBits(nbits: Int): Array[Int] = {
      val buf = new Array[Int]((nbits + 7) / 8)
      for (i <- 0 until nbits) {
        dut.io.spi_mosi.poke(false.B)
        spiCycles(1)
        val byteIdx = i / 8
        val bitIdx  = 7 - (i % 8)
        if (dut.io.spi_miso.peek().litValue != 0) {
          buf(byteIdx) |= (1 << bitIdx)
        }
      }
      buf
    }

    /** Wait for TL-A capture count to reach expected value. */
    def waitTlACapture(expectedCount: Long, timeoutSys: Int = 200): Boolean = {
      var sc = 0
      while (sc < timeoutSys) {
        val w = tick()
        if (w == 's' || w == 'b') {
          sc += 1
          if (dut.io.tl_a_cap_count.peek().litValue >= expectedCount) return true
        }
      }
      false
    }

    /** Reset the first-beat capture registers so the next A-channel handshake is captured. */
    def resetFirstCapture(): Unit = {
      dut.io.tl_a_first_reset.poke(true.B)
      dut.clock.step(1)
      dut.io.tl_a_first_reset.poke(false.B)
    }

    /** Send a multi-beat write frame: header(op=0x02, addr, len=numBeats-1) + numBeats*16 payload
      * bytes.
      */
    def spiWriteMulti(addr: Long, beats: Seq[Array[Int]]): Unit = {
      csbAssert()
      spiSendHeader(0x02, addr, beats.length - 1)
      for {
        beat <- beats
        byte <- beat
      } spiXferByte(byte)
      csbDeassert()
    }

  }

  /** Search for a bit pattern (needle) in a bit buffer (haystack). Both are packed MSB-first per
    * byte. Returns bit offset or -1.
    */
  def findBitPattern(
    haystack: Array[Int],
    hayBits: Int,
    needle: Array[Int],
    needleBits: Int
  ): Int = {
    for (off <- 0 to (hayBits - needleBits)) {
      var matched = true
      var b       = 0
      while (b < needleBits && matched) {
        val hi     = off + b
        val hayBit = (haystack(hi / 8) >> (7 - (hi % 8))) & 1
        val ndlBit = (needle(b / 8) >> (7 - (b     % 8))) & 1
        if (hayBit != ndlBit) matched = false
        b += 1
      }
      if (matched) return off
    }
    -1
  }

  // =========================================================================
  // Tests
  // =========================================================================

  "async clocks" in {
    withDualClock { dut =>
      val dc         = new DualClockState(dut)
      var coincident = 0
      var spiPos     = 0
      var sysPos     = 0
      for (_ <- 0 until 2000) {
        val w = dc.tick()
        if (w == 'b' && dc.spiLevel) { coincident += 1; spiPos += 1; sysPos += 1 }
        else if (w == 'p' && dc.spiLevel) spiPos += 1
        else if (w == 's') sysPos += 1
      }
      println(s"    sys=$sysPos spi=$spiPos coincident=$coincident")
      assert(spiPos != sysPos, "frequencies should differ")
      assert(coincident < spiPos / 2, "clocks should not be locked")
    }
  }

  "read data on MISO" in {
    withDualClock { dut =>
      val dc = new DualClockState(dut)

      dc.csbAssert()
      dc.spiSendHeader(0x01, 0x0000aa55L, 0x0000)

      val misoRaw = dc.collectMisoBits(384)
      dc.csbDeassert()

      // Expected: 0x55 then 0xAA (LSB-first byte emission, MSB-first shift per byte)
      val pattern = Array(0x55, 0xaa)
      val offset  = findBitPattern(misoRaw, 384, pattern, 16)

      if (offset >= 0) println(s"    found 0x55_0xAA at bit offset $offset")
      else {
        val hex = misoRaw.take(8).map(b => f"$b%02X").mkString(" ")
        println(s"    MISO raw (first 64 bits): $hex")
      }
      assert(offset >= 0, "exact 0x55AA pattern found in MISO bit stream")
    }
  }

  "read different address" in {
    withDualClock { dut =>
      val dc = new DualClockState(dut)

      dc.csbAssert()
      dc.spiSendHeader(0x01, 0x0000c3e7L, 0x0000)

      val raw = dc.collectMisoBits(384)
      dc.csbDeassert()

      val pattern = Array(0xe7, 0xc3)
      val offset  = findBitPattern(raw, 384, pattern, 16)

      if (offset >= 0) println(s"    found 0xE7_0xC3 at bit offset $offset")
      assert(offset >= 0, "exact 0xE7C3 pattern found in MISO")
    }
  }

  "read address" in {
    withDualClock { dut =>
      val dc          = new DualClockState(dut)
      val countBefore = dut.io.tl_a_cap_count.peek().litValue.toLong

      dc.csbAssert()
      dc.spiSendHeader(0x01, 0xcafe0000L, 0x0000)
      for (_ <- 0 until 16) dc.spiXferByte(0x00)
      dc.csbDeassert()

      var got = dut.io.tl_a_cap_count.peek().litValue.toLong > countBefore
      if (!got) got = dc.waitTlACapture(countBefore + 1, 300)
      assert(got, "TL-A fired after read frame")
      assert(
        dut.io.tl_a_cap_opcode.peek().litValue == 4,
        s"TL-A opcode = Get (4), got ${dut.io.tl_a_cap_opcode.peek().litValue}"
      )
      assert(
        dut.io.tl_a_cap_address.peek().litValue == BigInt("CAFE0000", 16),
        s"TL-A address = 0xCAFE0000, got 0x${dut.io.tl_a_cap_address.peek().litValue.toString(16)}"
      )
    }
  }

  "write address and data" in {
    withDualClock { dut =>
      val dc          = new DualClockState(dut)
      val countBefore = dut.io.tl_a_cap_count.peek().litValue.toLong

      dc.csbAssert()
      dc.spiSendHeader(0x02, 0xdead0000L, 0x0000)

      // Send 16 bytes of write data: 0x01..0x10
      for (i <- 0 until 16) dc.spiXferByte((i + 1) & 0xff)
      dc.csbDeassert()

      val got = dc.waitTlACapture(countBefore + 1, 2000)
      assert(got, "TL-A fired after write frame")
      assert(
        dut.io.tl_a_cap_opcode.peek().litValue == 0,
        s"TL-A opcode = PutFullData (0), got ${dut.io.tl_a_cap_opcode.peek().litValue}"
      )
      assert(
        dut.io.tl_a_cap_address.peek().litValue == BigInt("DEAD0000", 16),
        s"TL-A address = 0xDEAD0000, got 0x${dut.io.tl_a_cap_address.peek().litValue.toString(16)}"
      )

      // Low 32 bits of write data: bytes 0x01,0x02,0x03,0x04 packed LE = 0x04030201
      val word0 = dut.io.tl_a_cap_data.peek().litValue & BigInt("FFFFFFFF", 16)
      assert(
        word0 == BigInt("04030201", 16),
        s"write payload low 32 bits = 0x04030201, got 0x${word0.toString(16)}"
      )
    }
  }

  "CSB toggle stability" in {
    withDualClock { dut =>
      val dc = new DualClockState(dut)
      for (i <- 0 until 10) {
        dc.csbAssert()
        dc.spiSendHeader(0x01, 0x10000000L + (i << 4), 0x0000)
        dc.csbDeassert()
        dc.bothCycles(20)
      }
      // If we got here without crashing, the test passes
      assert(true, "10 rapid frames without crash")
    }
  }

  "multi-beat write" in {
    withDualClock { dut =>
      val dc          = new DualClockState(dut)
      val countBefore = dut.io.tl_a_cap_count.peek().litValue.toLong
      dc.resetFirstCapture()

      // 2-beat write: len=1, base address 0xBEEF0000
      val beat0 = (0 until 16).map(i => (i + 0x10) & 0xff).toArray
      val beat1 = (0 until 16).map(i => (i + 0x20) & 0xff).toArray
      dc.spiWriteMulti(0xbeef0000L, Seq(beat0, beat1))

      val got = dc.waitTlACapture(countBefore + 2, 400)
      assert(got, "TL-A fired twice for 2-beat write")

      // First beat: address = 0xBEEF0000
      assert(
        dut.io.tl_a_first_address.peek().litValue == BigInt("BEEF0000", 16),
        s"first beat address should be 0xBEEF0000, got 0x${dut.io.tl_a_first_address.peek().litValue.toString(16)}"
      )
      // First beat data: 0x10,0x11,...,0x1F packed LE → low 32 bits = 0x13121110
      val firstWord0 = dut.io.tl_a_first_data.peek().litValue & BigInt("FFFFFFFF", 16)
      assert(
        firstWord0 == BigInt("13121110", 16),
        s"first beat low word = 0x13121110, got 0x${firstWord0.toString(16)}"
      )

      // Last beat: address = 0xBEEF0010
      assert(
        dut.io.tl_a_cap_address.peek().litValue == BigInt("BEEF0010", 16),
        s"last beat address should be 0xBEEF0010, got 0x${dut.io.tl_a_cap_address.peek().litValue.toString(16)}"
      )
      // Last beat data: 0x20,0x21,...,0x2F packed LE → low 32 bits = 0x23222120
      val lastWord0 = dut.io.tl_a_cap_data.peek().litValue & BigInt("FFFFFFFF", 16)
      assert(
        lastWord0 == BigInt("23222120", 16),
        s"last beat low word = 0x23222120, got 0x${lastWord0.toString(16)}"
      )
    }
  }

  "multi-beat read" in {
    withDualClock { dut =>
      val dc          = new DualClockState(dut)
      val countBefore = dut.io.tl_a_cap_count.peek().litValue.toLong
      dc.resetFirstCapture()

      // 2-beat read: len=1, base address 0x0000AA00
      // V2 issues 2 TL-A Gets with auto-incrementing addresses.
      dc.csbAssert()
      dc.spiSendHeader(0x01, 0x0000aa00L, 0x0001)
      // Clock enough SPI cycles for both beats to complete through CDC
      for (_ <- 0 until 32) dc.spiXferByte(0x00)
      dc.csbDeassert()

      val got = dc.waitTlACapture(countBefore + 2, 400)
      assert(got, "TL-A fired at least twice for 2-beat read")

      // Verify addresses
      val firstAddr = dut.io.tl_a_first_address.peek().litValue
      val lastAddr  = dut.io.tl_a_cap_address.peek().litValue
      val opcode    = dut.io.tl_a_cap_opcode.peek().litValue
      println(
        s"    2-beat read: first=0x${firstAddr.toString(16)}, last=0x${lastAddr.toString(16)}, opcode=$opcode"
      )

      assert(opcode == 4, s"opcode should be Get (4), got $opcode")
      assert(
        firstAddr == BigInt("AA00", 16),
        s"first beat address should be 0xAA00, got 0x${firstAddr.toString(16)}"
      )
      assert(
        lastAddr == BigInt("AA10", 16),
        s"second beat address should be 0xAA10, got 0x${lastAddr.toString(16)}"
      )
    }
  }

  "large multi-beat write (8 beats)" in {
    withDualClock { dut =>
      val dc          = new DualClockState(dut)
      val countBefore = dut.io.tl_a_cap_count.peek().litValue.toLong
      val numBeats    = 8
      val baseAddr    = 0x40000000L

      dc.resetFirstCapture()

      // Build 8 beats of distinctive data
      val beats = (0 until numBeats).map { b =>
        (0 until 16).map(i => ((b << 4) | i) & 0xff).toArray
      }
      dc.spiWriteMulti(baseAddr, beats)

      val got = dc.waitTlACapture(countBefore + numBeats, 800)
      assert(got, s"TL-A fired $numBeats times for $numBeats-beat write")

      // First beat address
      assert(
        dut.io.tl_a_first_address.peek().litValue == BigInt("40000000", 16),
        s"first beat addr, got 0x${dut.io.tl_a_first_address.peek().litValue.toString(16)}"
      )

      // Last beat address = base + (numBeats-1)*16 = 0x40000070
      val expectedLastAddr = baseAddr + (numBeats - 1) * 16
      assert(
        dut.io.tl_a_cap_address.peek().litValue == BigInt(expectedLastAddr.toHexString, 16),
        s"last beat addr = 0x${expectedLastAddr.toHexString}, got 0x${dut.io.tl_a_cap_address.peek().litValue.toString(16)}"
      )

      // Last beat data: beat 7 bytes are 0x70..0x7F, low 32 bits LE = 0x73727170
      val lastWord0 = dut.io.tl_a_cap_data.peek().litValue & BigInt("FFFFFFFF", 16)
      assert(
        lastWord0 == BigInt("73727170", 16),
        s"last beat low word = 0x73727170, got 0x${lastWord0.toString(16)}"
      )
    }
  }

  "large multi-beat read (8 beats)" in {
    withDualClock { dut =>
      val dc          = new DualClockState(dut)
      val countBefore = dut.io.tl_a_cap_count.peek().litValue.toLong
      val numBeats    = 8
      val baseAddr    = 0x0000bb00L
      dc.resetFirstCapture()

      // 8-beat read: V2 issues 8 TL-A Gets with auto-incrementing addresses.
      dc.csbAssert()
      dc.spiSendHeader(0x01, baseAddr, numBeats - 1)
      // Clock enough SPI cycles for all beats to complete through CDC
      for (_ <- 0 until 128) dc.spiXferByte(0x00)
      dc.csbDeassert()

      val got = dc.waitTlACapture(countBefore + numBeats, 800)
      assert(got, s"TL-A fired at least $numBeats times for $numBeats-beat read")

      val firstAddr        = dut.io.tl_a_first_address.peek().litValue
      val lastAddr         = dut.io.tl_a_cap_address.peek().litValue
      val opcode           = dut.io.tl_a_cap_opcode.peek().litValue
      val expectedLastAddr = baseAddr + (numBeats - 1) * 16
      println(
        s"    8-beat read: first=0x${firstAddr.toString(16)}, last=0x${lastAddr.toString(16)}, opcode=$opcode"
      )

      assert(opcode == 4, s"opcode should be Get (4), got $opcode")
      assert(
        firstAddr == BigInt("BB00", 16),
        s"first beat address should be 0xBB00, got 0x${firstAddr.toString(16)}"
      )
      assert(
        lastAddr == BigInt(expectedLastAddr.toHexString, 16),
        s"last beat address should be 0x${expectedLastAddr.toHexString}, got 0x${lastAddr.toString(16)}"
      )
    }
  }

  "regression - repeated 0xFE" in {
    withDualClock { dut =>
      val dc       = new DualClockState(dut)
      val baseAddr = 0x0000cc00L

      dc.csbAssert()
      dc.spiSendHeader(0x01, baseAddr, 0x0001) // 2-beat read

      // Wait for TL-A to fire
      dc.waitTlACapture(2, 1000)

      // Wait for 0xFE bit-by-bit to align with the stream
      var rxBuf   = 0
      var timeout = 0
      while (rxBuf != 0xfe && timeout < 2000) {
        dut.io.spi_mosi.poke(0.U(dut.dataWidth.W))
        dc.spiCycles(1)
        val bit = if (dut.io.spi_miso.peek().litValue != 0) 1 else 0
        rxBuf = ((rxBuf << 1) & 0xff) | bit
        timeout += 1
      }
      assert(rxBuf == 0xfe, "Should have found 0xFE sync byte bit-by-bit")

      // Now we are bit-aligned. Read next 16 bytes (first beat data)
      val beat0 = (0 until 16).map(_ => dc.spiRecvByte())
      assert(beat0(0) == 0x00, s"beat0[0] should be 0x00, got 0x${beat0(0).toHexString}")
      assert(beat0(1) == 0xcc, s"beat0[1] should be 0xcc, got 0x${beat0(1).toHexString}")

      // Now check if next byte is 0xFE or something else
      val rx = dc.spiRecvByte()
      assert(rx == 0xfe, s"Should have received second 0xFE sync byte, got 0x${rx.toHexString}")

      // Read next 16 bytes (second beat data)
      val beat1 = (0 until 16).map(_ => dc.spiRecvByte())
      // Second beat address is 0x0000cc10
      assert(beat1(0) == 0x10, s"beat1[0] should be 0x10, got 0x${beat1(0).toHexString}")
      assert(beat1(1) == 0xcc, s"beat1[1] should be 0xcc, got 0x${beat1(1).toHexString}")

      dc.csbDeassert()
    }
  }

  "16-bit ultra-wide bus - write transaction and back-to-back 0x00AA ack" in {
    withDualClock(16) { dut =>
      val dc       = new DualClockState(dut)
      val baseAddr = 0x80000000L

      dc.csbAssert()
      // Clock leading NOP dummy words (0x0000) to verify NOP tolerance in sOp
      dc.spiXferWord16(0x0000)
      dc.spiXferWord16(0x0000)
      // Op 0x02 (Write), Addr 0x80000000, Len 0 (1 beat = 8 x 16-bit halfwords)
      dc.spiSendHeader(0x02, baseAddr, 0x0000)

      // Send 8 x 16-bit halfwords (bytes 0x01..0x10, 2 bytes per clock)
      for (i <- 0 until 8) {
        val lo = (2 * i + 1) & 0xff
        val hi = (2 * i + 2) & 0xff
        dc.spiXferWord16((hi << 8) | lo)
      }

      assert(dc.spiWaitWriteAck16(), "First 16-bit write should return 0x00AA ack on MISO")
      dc.csbDeassert()

      // Verify TileLink write request and full 128-bit payload across all 16 MOSI wires
      assert(dut.io.tl_a_captured.peek().litToBoolean, "TL-A should have captured write request")
      assert(
        dut.io.tl_a_cap_address.peek().litValue == baseAddr,
        s"TL-A address mismatch: 0x${dut.io.tl_a_cap_address.peek().litValue.toString(16)}"
      )
      val expected128 = BigInt("100f0e0d0c0b0a090807060504030201", 16)
      assert(
        dut.io.tl_a_cap_data.peek().litValue == expected128,
        s"TL-A 128-bit data mismatch: 0x${dut.io.tl_a_cap_data.peek().litValue.toString(16)}"
      )

      // Back-to-back second write with stalled TL-D: verify wr_done_latch cleared and does not
      // emit a stale 0x00AA before the second write actually finishes on TileLink-D.
      val secondAddr = 0x80000010L
      dut.io.tl_d_stall.poke(true.B)
      dc.csbAssert()
      dc.spiSendHeader(0x02, secondAddr, 0x0000)
      for (i <- 0 until 8) {
        dc.spiXferWord16(0xa500 | i)
      }
      for (_ <- 0 until 20) {
        val preAck = dc.spiRecvWord16()
        assert(
          preAck != 0x00aa,
          "MISO must not report 0x00AA while second write TL-D response is stalled"
        )
      }
      dut.io.tl_d_stall.poke(false.B)
      assert(
        dc.spiWaitWriteAck16(),
        "Second 16-bit write should return 0x00AA ack once TL-D completes"
      )
      dc.csbDeassert()
      assert(dut.io.tl_a_cap_address.peek().litValue == secondAddr)
    }
  }

  "16-bit ultra-wide bus - single-beat read transaction" in {
    withDualClock(16) { dut =>
      val dc       = new DualClockState(dut)
      val baseAddr = 0x80001000L

      dc.csbAssert()
      // Op 0x01 (Read), Addr 0x80001000, Len 0 (1 beat = 8 x 16-bit halfwords)
      dc.spiSendHeader(0x01, baseAddr, 0x0000)

      // Wait for 0x00FE sync halfword on 16-bit MISO
      var sync    = 0
      var timeout = 0
      while (sync != 0x00fe && timeout < 500) {
        sync = dc.spiRecvWord16()
        timeout += 1
      }
      assert(sync == 0x00fe, s"Should receive 0x00FE sync word, got 0x${sync.toHexString}")

      // Receive 8 x 16-bit halfwords (2 bytes per clock across all 16 MISO wires)
      val halfwords = (0 until 8).map(_ => dc.spiRecvWord16())
      assert(
        halfwords(0) == 0x1000,
        s"halfwords[0] should match addr[15:0] (0x1000), got 0x${halfwords(0).toHexString}"
      )
      assert(
        halfwords(1) == 0x8000,
        s"halfwords[1] should match addr[31:16] (0x8000), got 0x${halfwords(1).toHexString}"
      )

      dc.csbDeassert()
    }
  }

  "16-bit ultra-wide bus - multi-beat burst write transaction (4 beats)" in {
    withDualClock(16) { dut =>
      val dc       = new DualClockState(dut)
      val baseAddr = 0x80002000L

      dc.csbAssert()
      // Op 0x02 (Write), Addr 0x80002000, Len 3 (4 beats = 32 x 16-bit halfwords)
      dc.spiSendHeader(0x02, baseAddr, 0x0003)

      for (b <- 0 until 4) {
        for (i <- 0 until 8) {
          val lo = ((b * 16) + 2 * i + 1) & 0xff
          val hi = ((b * 16) + 2 * i + 2) & 0xff
          dc.spiXferWord16((hi << 8) | lo)
        }
      }

      assert(dc.spiWaitWriteAck16(), "4-beat burst write should return 0x00AA ack on MISO")
      dc.csbDeassert()

      assert(dut.io.tl_a_captured.peek().litToBoolean, "TL-A should have captured burst write")
      assert(
        dut.io.tl_a_first_address.peek().litValue == baseAddr,
        s"First beat address mismatch: 0x${dut.io.tl_a_first_address.peek().litValue.toString(16)}"
      )
      assert(
        dut.io.tl_a_cap_address.peek().litValue == (baseAddr + 0x30L),
        s"Last beat address mismatch: 0x${dut.io.tl_a_cap_address.peek().litValue.toString(16)}"
      )
      assert(
        dut.io.tl_a_cap_count.peek().litValue == 4,
        s"Beat count mismatch: ${dut.io.tl_a_cap_count.peek().litValue}"
      )
      val lastLow32 = dut.io.tl_a_cap_data.peek().litValue & BigInt("FFFFFFFF", 16)
      assert(
        lastLow32 == BigInt("34333231", 16),
        s"Last beat low 32b should be 0x34333231, got 0x${lastLow32.toString(16)}"
      )
    }
  }

  "16-bit ultra-wide bus - multi-beat burst read transaction (4 beats)" in {
    withDualClock(16) { dut =>
      val dc       = new DualClockState(dut)
      val baseAddr = 0x80003000L

      dc.csbAssert()
      // Op 0x01 (Read), Addr 0x80003000, Len 3 (4 beats = 64 bytes)
      dc.spiSendHeader(0x01, baseAddr, 0x0003)

      for (b <- 0 until 4) {
        var sync    = 0
        var timeout = 0
        while (sync != 0x00fe && timeout < 500) {
          sync = dc.spiRecvWord16()
          timeout += 1
        }
        assert(
          sync == 0x00fe,
          s"Beat $b should receive 0x00FE sync word, got 0x${sync.toHexString}"
        )
        val payload = (0 until 8).map(_ => dc.spiRecvWord16())
        assert(
          payload(0) == (0x3000 + b * 0x10),
          s"Beat $b halfword[0] mismatch: got 0x${payload(0).toHexString}"
        )
        assert(
          payload(1) == 0x8000,
          s"Beat $b halfword[1] mismatch: got 0x${payload(1).toHexString}"
        )
      }

      dc.csbDeassert()
    }
  }

  "quad-spi (W=4) write and read transaction" in {
    withDualClock(4) { dut =>
      val dc       = new DualClockState(dut)
      val baseAddr = 0x80004000L

      // Quad-SPI Write Test
      dc.csbAssert()
      dc.spiSendHeader(0x02, baseAddr, 0x0000)
      for (i <- 0 until 16) {
        dc.spiXferByte(i + 0xa0)
      }
      dc.csbDeassert()

      assert(dut.io.tl_a_captured.peek().litToBoolean, "Quad-SPI write should be captured")
      assert(dut.io.tl_a_cap_address.peek().litValue == baseAddr, s"Quad-SPI address mismatch")
      val expectedQuadWrite =
        (0 until 16).foldLeft(BigInt(0))((acc, i) => acc | (BigInt(i + 0xa0) << (i * 8)))
      assert(
        dut.io.tl_a_cap_data.peek().litValue == expectedQuadWrite,
        s"Quad-SPI write data mismatch: 0x${dut.io.tl_a_cap_data.peek().litValue.toString(16)}"
      )

      // Quad-SPI Read Test (with nibble-sliding sync search resilient to odd-nibble CDC arrival)
      dc.csbAssert()
      dc.spiSendHeader(0x01, baseAddr, 0x0000)
      var rxBuf   = 0
      var timeout = 0
      while (rxBuf != 0xfe && timeout < 1000) {
        dut.io.spi_mosi.poke(0.U(4.W))
        val nibble = dut.io.spi_miso.peek().litValue.toInt & 0xf
        rxBuf = ((rxBuf << 4) & 0xff) | nibble
        dc.spiCycles(1)
        timeout += 1
      }
      assert(
        rxBuf == 0xfe,
        s"Quad-SPI read should receive 0xFE sync byte, got 0x${rxBuf.toHexString}"
      )
      val data = (0 until 16).map(_ => dc.spiRecvByte())
      assert(
        data.take(4) == Seq(0x00, 0x40, 0x00, 0x80),
        s"Quad-SPI read bytes [0..3] mismatch: ${data.take(4).map(_.toHexString)}"
      )
      assert(data.drop(4).forall(_ == 0), "Quad-SPI read upper 12 bytes should be zero")
      dc.csbDeassert()
    }
  }

  "helper width guards reject mismatched transfer widths" in {
    withDualClock(16) { dut =>
      val dc = new DualClockState(dut)
      assertThrows[IllegalArgumentException] {
        dc.spiXferByte(0x12)
      }
      assertThrows[IllegalArgumentException] {
        dc.spiRecvByte()
      }
    }
    withDualClock(1) { dut =>
      val dc = new DualClockState(dut)
      assertThrows[IllegalArgumentException] {
        dc.spiXferWord16(0x1234)
      }
      assertThrows[IllegalArgumentException] {
        dc.spiRecvWord16()
      }
    }
  }

  "full-width opcode validation rejects upper-byte noise and supports 0x0003 soft reset" in {
    withDualClock(16) { dut =>
      val dc = new DualClockState(dut)

      // Upper-byte noise / invalid opcodes (0x0100, 0xAA02, 0xFF03, 0xFFFF) must park in sWaitEnd
      for (badOp <- Seq(0x0100, 0xaa02, 0xff03, 0xffff)) {
        dc.csbAssert()
        dc.spiXferWord16(badOp)
        dc.spiXferWord16(0x0000)
        dc.spiXferWord16(0x0000)
        dc.spiXferWord16(0x8000)
        for (_ <- 0 until 8) dc.spiXferWord16(0xdead)
        dc.bothCycles(40)
        assert(
          !dut.io.tl_a_captured.peek().litToBoolean,
          s"Invalid 16-bit opcode 0x${badOp.toHexString} must not issue TL-A request"
        )
        assert(
          !dut.io.sys_rst_o.peek().litToBoolean,
          s"Invalid 16-bit opcode 0x${badOp.toHexString} must not assert sys_rst_o"
        )
        dc.csbAbortNow()
      }

      // Exact 0x0003 opcode must assert synchronized sys_rst_o until CSB deasserts
      dc.csbAssert()
      dc.spiXferWord16(0x0003)
      dc.bothCycles(20)
      assert(dut.io.sys_rst_o.peek().litToBoolean, "Exact 0x0003 opcode should assert sys_rst_o")
      dc.csbAbortNow()
      dc.bothCycles(20)
      assert(!dut.io.sys_rst_o.peek().litToBoolean, "CSB deassert should clear sys_rst_o")
    }
  }

  "16-bit ultra-wide bus - CSB toggle and stalled multi-beat abort recovery" in {
    withDualClock(16) { dut =>
      val dc = new DualClockState(dut)

      // 1. Aborted partial header
      dc.csbAssert()
      dc.spiXferWord16(0x0002) // Op
      dc.spiXferWord16(0x0000) // Partial len
      dc.csbAbortNow()
      assert(!dut.io.tl_a_captured.peek().litToBoolean, "Partial header must not issue TL-A")

      // 2. Multi-beat write aborted while beat 0 is stalled in sWriteAck, followed immediately
      // by a new CSB frame BEFORE beat 0's TL-D response returns.
      val abortedWriteAddr = 0x80005000L
      dut.io.tl_d_stall.poke(true.B)
      dc.csbAssert()
      dc.spiSendHeader(0x02, abortedWriteAddr, 0x0003) // 4-beat write
      for (i <- 0 until 8) dc.spiXferWord16(0x1100 | i) // Beat 0
      assert(dc.waitTlACapture(1, 400), "Beat 0 of multi-beat write should issue TL-A")
      val countAfterBeat0 = dut.io.tl_a_cap_count.peek().litValue.toLong

      // Abort mid-burst while beat 0 is stuck in sWriteAck, then start a new 1-beat write
      dc.csbAbortNow()
      val cleanWriteAddr = 0x80006000L
      dc.csbAssert()
      dc.spiSendHeader(0x02, cleanWriteAddr, 0x0000)
      for (i <- 0 until 8) {
        dc.spiXferWord16(((2 * i + 2) << 8) | (2 * i + 1))
      }
      // Release TL-D stall so beat 0 of aborted burst drains and new write executes cleanly
      dut.io.tl_d_stall.poke(false.B)
      assert(dc.spiWaitWriteAck16(), "Follow-up write after multi-beat write abort should ack")
      dc.csbDeassert()

      assert(
        dut.io.tl_a_cap_count.peek().litValue == countAfterBeat0 + 1,
        s"Expected exactly 1 new TL-A beat (no phantom beat 1 on aborted burst), got ${dut.io.tl_a_cap_count.peek().litValue}"
      )
      assert(
        dut.io.tl_a_cap_address.peek().litValue == cleanWriteAddr,
        s"Follow-up write address mismatch: 0x${dut.io.tl_a_cap_address.peek().litValue.toString(16)}"
      )
      assert(
        dut.io.tl_a_cap_data.peek().litValue == BigInt("100f0e0d0c0b0a090807060504030201", 16),
        "Follow-up write payload corrupted by stale aborted write state"
      )

      // 3. Multi-beat read aborted while stalled in sReadData, followed by a new read:
      // stale beat 0 data (0x80007000) must be discarded and never leak into the new read.
      val abortedReadAddr = 0x80007000L
      val countBeforeRead = dut.io.tl_a_cap_count.peek().litValue.toLong
      dut.io.tl_d_stall.poke(true.B)
      dc.csbAssert()
      dc.spiSendHeader(0x01, abortedReadAddr, 0x0007) // 8-beat read
      assert(
        dc.waitTlACapture(countBeforeRead + 1, 400),
        "Beat 0 of multi-beat read should issue TL-A"
      )

      // Abort while beat 0 is stalled in sReadData, then start a clean 1-beat read at 0x80008000
      dc.csbAbortNow()
      val cleanReadAddr = 0x80008000L
      dc.csbAssert()
      dc.spiSendHeader(0x01, cleanReadAddr, 0x0000)
      dut.io.tl_d_stall.poke(false.B)

      var sync    = 0
      var timeout = 0
      while (sync != 0x00fe && timeout < 500) {
        sync = dc.spiRecvWord16()
        timeout += 1
      }
      assert(sync == 0x00fe, "Clean read after aborted multi-beat read should sync on 0x00FE")
      val readHalfwords = (0 until 8).map(_ => dc.spiRecvWord16())
      assert(
        readHalfwords(0) == 0x8000 && readHalfwords(1) == 0x8000,
        s"Expected 0x80008000 from clean read (not stale 0x80007000), got 0x${readHalfwords(1).toHexString}_${readHalfwords(0).toHexString}"
      )
      dc.csbDeassert()
    }
  }
}
