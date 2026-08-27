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

/** Test suite for SPI Master implementation.
  *
  * Covers register access, data path (loopback), baud rate timing, manual chip-select control, and
  * asynchronous clock domain crossing.
  */
class SpiMasterSpec extends AnyFreeSpec with ChiselSim with TLULTestUtils {
  val p      = new Parameters
  val tlul_p = p.toTLUL()

  "SpiMaster Controller Operations" in {
    simulate(new SpiMasterCtrl(tlul_p)) { dut =>
      // Register Access
      {
        dut.reset.poke(true.B)
        dut.clock.step()
        dut.reset.poke(false.B)

        tlWrite(dut.io.tl, dut.clock, 0x04.U, 0x1234.U) // CONTROL
        val rdata = tlReadData(dut.io.tl, dut.clock, 0x04.U)
        assert(rdata == 0x1234)
      }

      // Loopback
      {
        dut.reset.poke(true.B)
        dut.clock.step()
        dut.reset.poke(false.B)

        // Enable SPI
        tlWrite(dut.io.tl, dut.clock, 0x04.U, 0x01.U) // ENABLE=1
        tlWrite(dut.io.tl, dut.clock, 0x08.U, 0x55.U) // TXDATA=0x55

        // Sample MOSI and feed back to MISO to simulate wire loopback
        for (_ <- 0 until 100) {
          dut.io.spi.miso.poke(dut.io.spi.mosi.peek())
          dut.clock.step()
        }

        // Verify RX FIFO status is non-empty
        val status = tlReadData(dut.io.tl, dut.clock, 0x00.U)
        assert((status & 2) == 0, s"RX FIFO should not be empty, status=$status")

        // Check captured data
        val rxdata = tlReadData(dut.io.tl, dut.clock, 0x0c.U)
        assert(rxdata == 0x55, s"Expected 0x55, got 0x${rxdata.toString(16)}")
      }

      // DIV Timing
      {
        dut.reset.poke(true.B)
        dut.clock.step()
        dut.reset.poke(false.B)

        // Configure DIV=3: SCLK period = (DIV+1)*2 = 8 cycles
        // Standard Mode 0 (CPOL=0) results in sclk_reg=0 at idle
        tlWrite(dut.io.tl, dut.clock, 0x04.U, 0x0301.U) // ENABLE=1, DIV=3, CPOL=0
        tlWrite(dut.io.tl, dut.clock, 0x08.U, 0xaa.U)

        // Wait for first edge (0 -> 1 for standard CPOL=0)
        while (dut.io.spi.sclk.peek().litValue == 0) dut.clock.step()
        var steps = 0
        // Measure duration of '1' phase
        while (dut.io.spi.sclk.peek().litValue == 1) {
          dut.clock.step()
          steps += 1
        }
        // Measure duration of '0' phase
        while (dut.io.spi.sclk.peek().litValue == 0) {
          dut.clock.step()
          steps += 1
        }
        assert(steps == 8, s"Expected period 8, got $steps")
      }

      // Manual CS
      {
        dut.reset.poke(true.B)
        dut.clock.step()
        dut.reset.poke(false.B)

        // Explicitly control CS line via CSID and CSMODE
        tlWrite(dut.io.tl, dut.clock, 0x14.U, 0x01.U) // CSMODE=Manual
        tlWrite(dut.io.tl, dut.clock, 0x10.U, 0x01.U) // CSID=0 active
        tlWrite(dut.io.tl, dut.clock, 0x04.U, 0x01.U) // ENABLE=1

        dut.clock.step(10)
        assert(dut.io.spi.csb.peek().litValue == 0, "CS should stay asserted in manual mode")

        tlWrite(dut.io.tl, dut.clock, 0x10.U, 0x00.U) // Deassert
        dut.clock.step(10)
        assert(dut.io.spi.csb.peek().litValue == 1, "CS should stay deasserted in manual mode")
      }

      // TX Backpressure
      {
        dut.reset.poke(true.B)
        dut.clock.step()
        dut.reset.poke(false.B)

        // Saturation test: fill FIFO and verify channel A stall
        for (i <- 0 until 4) {
          tlWrite(dut.io.tl, dut.clock, 0x08.U, i.U)
        }

        dut.io.tl.a.valid.poke(true.B)
        dut.io.tl.a.bits.address.poke(0x08.U)
        dut.clock.step()
        assert(
          dut.io.tl.a.ready.peek().litValue == 0,
          "Host should be stalled when TX FIFO is full"
        )
        dut.io.tl.a.valid.poke(false.B)
      }

      // RX Blocking Read
      {
        dut.reset.poke(true.B)
        dut.clock.step()
        dut.reset.poke(false.B)

        // Verification of atomic synchronization: reading from empty RXDATA stalls the bus
        dut.io.tl.a.valid.poke(true.B)
        dut.io.tl.a.bits.address.poke(0x0c.U)
        dut.clock.step()
        assert(
          dut.io.tl.a.ready.peek().litValue == 0,
          "Host should be stalled when reading empty RX FIFO"
        )
        dut.io.tl.a.valid.poke(false.B)
      }

      // RX Overflow Stall
      {
        dut.reset.poke(true.B)
        dut.clock.step()
        dut.reset.poke(false.B)

        tlWrite(dut.io.tl, dut.clock, 0x04.U, 0x0101.U) // Baud rate scaling

        // Saturate RX path
        for (i <- 0 until 4) {
          tlWrite(dut.io.tl, dut.clock, 0x08.U, (0xa0 + i).U)
          for (_ <- 0 until 100) {
            dut.io.spi.miso.poke(dut.io.spi.mosi.peek())
            dut.clock.step()
          }
        }

        // 5th byte should hang until space is cleared
        tlWrite(dut.io.tl, dut.clock, 0x08.U, 0xee.U)
        for (_ <- 0 until 200) {
          dut.io.spi.miso.poke(dut.io.spi.mosi.peek())
          dut.clock.step()
        }

        val sclk1 = dut.io.spi.sclk.peek().litValue
        dut.clock.step(20)
        val sclk2 = dut.io.spi.sclk.peek().litValue
        assert(sclk1 == sclk2, "SPI FSM should be stalled awaiting RX FIFO availability")

        // Clear space and verify resumption
        tlReadData(dut.io.tl, dut.clock, 0x0c.U)
        for (_ <- 0 until 100) {
          dut.io.spi.miso.poke(dut.io.spi.mosi.peek())
          dut.clock.step()
        }
        val status = tlReadData(dut.io.tl, dut.clock, 0x00.U)
        assert((status & 2) == 0, "Transaction should have finalized after FIFO read")
      }

      // Invalid Address Access
      {
        dut.reset.poke(true.B)
        dut.clock.step()
        dut.reset.poke(false.B)

        // Get error on invalid address
        val (_, error) = tlRead(dut.io.tl, dut.clock, 0x100.U)
        assert(error, "Invalid address access should return error")

        // Get error on write to read-only register
        dut.io.tl.a.valid.poke(true.B)
        dut.io.tl.a.bits.opcode.poke(TLULOpcodesA.PutFullData.asUInt)
        dut.io.tl.a.bits.address.poke(0x00.U) // STATUS is RO
        dut.io.tl.a.bits.data.poke(1.U)
        while (dut.io.tl.a.ready.peek().litValue == 0) dut.clock.step()
        dut.clock.step()
        dut.io.tl.a.valid.poke(false.B)
        while (dut.io.tl.d.valid.peek().litValue == 0) dut.clock.step()
        assert(
          dut.io.tl.d.bits.error.peek().litValue != 0,
          "Write to RO register should return error"
        )
      }

      // Mode 0 Sampling Verification
      {
        dut.reset.poke(true.B)
        dut.clock.step()
        dut.reset.poke(false.B)

        // Configure Mode 0 (CPOL=0, CPHA=0)
        tlWrite(dut.io.tl, dut.clock, 0x04.U, 0x01.U) // ENABLE=1, CPOL=0, CPHA=0
        tlWrite(dut.io.tl, dut.clock, 0x08.U, 0x88.U) // Send 10001000

        // Wait for bit shifting to start
        while (dut.io.spi.csb.peek().litValue == 1) dut.clock.step()

        // In Mode 0, data is driven by slave immediately on CS assertion.
        // Master must sample on the first available leading clock edge.
        for (_ <- 0 until 200) {
          // Simple loopback: MISO = MOSI
          dut.io.spi.miso.poke(dut.io.spi.mosi.peek())
          dut.clock.step()
        }

        val rxdata = tlReadData(dut.io.tl, dut.clock, 0x0c.U)
        assert(rxdata == 0x88, s"Expected 0x88, got 0x${rxdata.toString(16)}")
      }

      // Multi-Mode Verification
      {
        for (mode <- 0 until 4) {
          val cpol     = (mode >> 1) & 1
          val cpha     = mode & 1
          val ctrl_val = (cpol << 1) | (cpha << 2) | 1 // ENABLE=1

          dut.reset.poke(true.B)
          dut.clock.step()
          dut.reset.poke(false.B)

          tlWrite(dut.io.tl, dut.clock, 0x04.U, ctrl_val.U)
          tlWrite(dut.io.tl, dut.clock, 0x08.U, 0xa5.U)

          while (dut.io.spi.csb.peek().litValue == 1) dut.clock.step()

          // Wait enough time for the transfer to complete
          for (_ <- 0 until 500) {
            dut.io.spi.miso.poke(dut.io.spi.mosi.peek())
            dut.clock.step()
          }

          val rxdata = tlReadData(dut.io.tl, dut.clock, 0x0c.U)
          assert(
            rxdata == 0xa5,
            s"Mode $mode (CPOL=$cpol, CPHA=$cpha) failed: expected 0xa5, got 0x${rxdata.toString(16)}"
          )
        }
      }

      // Half-Duplex RX Mode
      {
        dut.reset.poke(true.B)
        dut.clock.step()
        dut.reset.poke(false.B)

        // Enable SPI with HDRX (bit 3)
        // Div=2, HDRX=1, Enable=1 -> 0x0209
        tlWrite(dut.io.tl, dut.clock, 0x04.U, 0x0209.U)

        // In HDRX, SPI should start generating SCLK as long as RX FIFO is not full,
        // without needing a write to TXDATA.
        var sclk_edges = 0
        var last_sclk  = false
        for (_ <- 0 until 500) {
          val sclk = dut.io.spi.sclk.peek().litValue != 0
          if (sclk && !last_sclk) sclk_edges += 1
          last_sclk = sclk

          // Simple loopback: MISO = bit count (mocking some external data)
          dut.io.spi.miso.poke(true.B) // Just send all 1s for simplicity
          dut.clock.step()
        }

        assert(sclk_edges >= 8, "SCLK should have toggled in half-duplex mode")

        // Check that data was captured
        val status = tlReadData(dut.io.tl, dut.clock, 0x00.U)
        assert((status & 2) == 0, "RX FIFO should have data")

        val rxdata = tlReadData(dut.io.tl, dut.clock, 0x0c.U)
        assert(rxdata == 0xff, s"Expected 0xFF from all-1s loopback, got 0x${rxdata.toString(16)}")
      }

      // Half-Duplex TX Mode
      {
        dut.reset.poke(true.B)
        dut.clock.step()
        dut.reset.poke(false.B)

        // Enable SPI with HDTX (bit 4)
        // Div=2, HDTX=1, Enable=1 -> 0x0211
        tlWrite(dut.io.tl, dut.clock, 0x04.U, 0x0211.U)

        // Write 8 bytes to TXDATA. With an RX FIFO of size 4, this would
        // normally stall if RX wasn't being drained. In HDTX mode, it should
        // proceed without stalls and without filling the RX FIFO.
        for (i <- 0 until 8) {
          tlWrite(dut.io.tl, dut.clock, 0x08.U, i.U)
          // Wait for byte to finish (busy bit in status)
          var status = tlReadData(dut.io.tl, dut.clock, 0x00.U)
          while ((status & 1) != 0) {
            dut.clock.step()
            status = tlReadData(dut.io.tl, dut.clock, 0x00.U)
          }
        }

        // Check that RX FIFO is still empty
        val status = tlReadData(dut.io.tl, dut.clock, 0x00.U)
        assert((status & 2) != 0, "RX FIFO should be empty in HDTX mode")
      }
    }
  }

  "SpiMaster Top-level Async Clocks" in {
    simulate(new Module {
      val io = IO(new Bundle {
        val tl         = Flipped(new OpenTitanTileLink.Host2Device(tlul_p))
        val spi        = new SpiIO
        val spi_clk_in = Input(Bool())
      })
      val dut = Module(new SpiMaster(tlul_p))
      dut.io.clk_i  := clock
      dut.io.rst_ni := (!reset.asBool).asAsyncReset
      dut.io.tl <> io.tl
      io.spi <> dut.io.spi
      dut.io.spi_clk_i := io.spi_clk_in.asClock
    }) { dut =>
      dut.reset.poke(true.B)
      dut.clock.step()
      dut.reset.poke(false.B)

      var spi_clk_val = false

      /** Helper to step both system bus and SPI clock domains.
        */
      def stepBoth(n: Int = 1): Unit = {
        for (_ <- 0 until n) {
          dut.clock.step()
          spi_clk_val = !spi_clk_val
          dut.io.spi_clk_in.poke(spi_clk_val.B)
        }
      }

      /** Specialized TileLink helper for CDC crossing test.
        */
      def tlWriteAsync(addr: UInt, data: UInt): Unit = {
        dut.io.tl.a.valid.poke(true.B)
        dut.io.tl.a.bits.opcode.poke(TLULOpcodesA.PutFullData.asUInt)
        dut.io.tl.a.bits.address.poke(addr)
        dut.io.tl.a.bits.data.poke(data)
        dut.io.tl.a.bits.mask.poke(0xf.U)
        while (dut.io.tl.a.ready.peek().litValue == 0) stepBoth()
        stepBoth()
        dut.io.tl.a.valid.poke(false.B)
        while (dut.io.tl.d.valid.peek().litValue == 0) stepBoth()
        dut.io.tl.d.ready.poke(true.B)
        stepBoth()
        dut.io.tl.d.ready.poke(false.B)
      }

      tlWriteAsync(0x04.U, 0x01.U) // Enable
      stepBoth(40)
      tlWriteAsync(0x08.U, 0x33.U) // Send byte

      var seen = 0
      for (_ <- 0 until 400) {
        stepBoth()
        if (dut.io.spi.csb.peek().litValue == 0) seen += 1
      }
      assert(seen > 0, "SPI logic did not activate across CDC bridge")
    }
  }
}
