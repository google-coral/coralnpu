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

/** IO bundle for standard 4-wire SPI interface.
  */
class SpiIO extends Bundle {
  val sclk = Output(Bool())
  val csb  = Output(Bool()) // Active Low
  val mosi = Output(Bool())
  val miso = Input(Bool())
}

/** SPI Master Controller core logic.
  *
  * This module manages the SPI protocol state machine, baud rate generation, and data buffering
  * using internal FIFOs. It interfaces with the bus via a TileLink-UL slave port.
  */
class SpiMasterCtrl(p: TLULParameters) extends Module {
  val tlul_p = p
  val io     = IO(new Bundle {
    val tl  = Flipped(new OpenTitanTileLink.Host2Device(tlul_p))
    val spi = new SpiIO
  })

  // Register Map offsets
  object SpiRegs {
    val STATUS  = 0x00.U
    val CONTROL = 0x04.U
    val TXDATA  = 0x08.U
    val RXDATA  = 0x0c.U
    val CSID    = 0x10.U
    val CSMODE  = 0x14.U
  }
  import SpiRegs._

  // Configuration and Control Registers
  val reg_control = RegInit(0.U(32.W))
  val reg_csid    = RegInit(0.U(32.W))
  val reg_csmode  = RegInit(0.U(32.W)) // 0: Auto, 1: Manual

  // Control bitfields
  val ctrl_div    = reg_control(15, 8)
  val ctrl_hdtx   = reg_control(4) // Half-duplex write: ignore RX data, no RX FIFO push
  val ctrl_hdrx   = reg_control(3) // Half-duplex read: auto-TX 0x00 when RX FIFO has space
  val ctrl_cpha   = reg_control(2)
  val ctrl_cpol   = reg_control(1)
  val ctrl_enable = reg_control(0)

  // Internal FIFOs for decoupling bus transactions from SPI timing
  val tx_fifo = Module(new Queue(UInt(8.W), 4))
  val rx_fifo = Module(new Queue(UInt(8.W), 4))

  // SPI Protocol States
  object SpiState extends ChiselEnum {
    val sIdle, sSetup, sShift, sFinish = Value
  }
  val state     = RegInit(SpiState.sIdle)
  val bit_count = RegInit(0.U(3.W))
  val clk_count = RegInit(0.U(8.W))
  val tx_reg    = Reg(UInt(8.W))
  val rx_reg    = Reg(UInt(8.W))
  val sclk_reg  = RegInit(false.B)
  val csb_reg   = RegInit(true.B)

  // Baud rate generator: generates a 'tick' pulse at every half-period of SCLK
  val tick = WireDefault(false.B)
  when(ctrl_enable) {
    when(clk_count === ctrl_div) {
      clk_count := 0.U
      tick      := true.B
    }.otherwise {
      clk_count := clk_count + 1.U
    }
  }

  // SPI Pins Driving Logic
  io.spi.sclk          := sclk_reg
  io.spi.csb           := csb_reg
  io.spi.mosi          := tx_reg(7)
  tx_fifo.io.deq.ready := false.B
  rx_fifo.io.enq.valid := false.B
  rx_fifo.io.enq.bits  := 0.U

  // Bus Interface Default Assignments
  tx_fifo.io.enq.valid := false.B
  tx_fifo.io.enq.bits  := 0.U
  rx_fifo.io.deq.ready := false.B

  // Chip Select Control (Manual Override vs Auto)
  val manual_cs     = reg_csmode(0)
  val manual_cs_val = !reg_csid(0) // CS0 selected if bit 0 set

  val phase        = RegInit(0.U(1.W)) // Half-cycle phase indicator
  val sample_count = RegInit(0.U(4.W)) // Number of bits sampled

  // Reset and Enable management
  when(!ctrl_enable) {
    state        := SpiState.sIdle
    sclk_reg     := ctrl_cpol
    csb_reg      := true.B
    clk_count    := 0.U
    phase        := 0.U
    sample_count := 0.U
  }.otherwise {
    when(manual_cs) {
      csb_reg := manual_cs_val
    }

    // SPI Peripheral State Machine
    switch(state) {
      is(SpiState.sIdle) {
        sclk_reg := ctrl_cpol
        when(!manual_cs) { csb_reg := true.B }
        phase        := 0.U
        clk_count    := 0.U
        sample_count := 0.U
        when(tx_fifo.io.deq.valid) {
          // Normal mode: dequeue from TX FIFO
          tx_fifo.io.deq.ready := true.B
          tx_reg               := tx_fifo.io.deq.bits
          state                := SpiState.sSetup
          when(!manual_cs) { csb_reg := false.B }
          bit_count := 7.U
        }.elsewhen(ctrl_hdrx && rx_fifo.io.enq.ready) {
          // Half-duplex read mode: auto-generate TX=0x00 transfers
          // as long as RX FIFO has space, no TXDATA write needed
          tx_reg := 0.U
          state  := SpiState.sSetup
          when(!manual_cs) { csb_reg := false.B }
          bit_count := 7.U
        }
      }

      is(SpiState.sSetup) {
        // Initial setup period before the first clock edge
        sclk_reg := ctrl_cpol
        when(tick) {
          state    := SpiState.sShift
          sclk_reg := !ctrl_cpol
          phase    := ~phase
        }
      }

      is(SpiState.sShift) {
        // Shift data bits and drive SCLK
        when(tick) {
          phase := ~phase
          when(phase === 1.U) {
            // End of Leading edge phase, Start of Trailing edge phase
            sclk_reg := ctrl_cpol
          }.otherwise {
            // End of Trailing edge phase, Start next Leading edge phase or finish
            when(bit_count === 0.U) {
              // Wait for space in RX FIFO before finalizing transaction,
              // unless we are in HDTX mode which ignores RX data.
              when(rx_fifo.io.enq.ready || ctrl_hdtx) {
                state    := SpiState.sFinish
                sclk_reg := ctrl_cpol
              }
            }.otherwise {
              bit_count := bit_count - 1.U
              sclk_reg  := !ctrl_cpol
            }
          }
        }
      }

      is(SpiState.sFinish) {
        // Finalize byte transfer and return received data
        sclk_reg := ctrl_cpol
        when(tick) {
          state := SpiState.sIdle
          when(!manual_cs) { csb_reg := true.B }
          // Only push to RX FIFO if not in HDTX mode
          when(!ctrl_hdtx) {
            rx_fifo.io.enq.valid := true.B
            rx_fifo.io.enq.bits  := rx_reg
          }
        }
      }
    }
  }

  // MISO Sampling and MOSI Shifting Logic
  // Using the value of 'phase' BEFORE it is toggled by 'tick' in sShift.
  // Leading edge: tick when phase is 0. Trailing edge: tick when phase is 1.
  when(tick) {
    when(state === SpiState.sShift || state === SpiState.sSetup) {
      // Sampling Edge: CPHA=0 -> Leading edge (phase=0), CPHA=1 -> Trailing edge (phase=1)
      when(phase === ctrl_cpha) {
        when(sample_count < 8.U) {
          rx_reg       := Cat(rx_reg(6, 0), io.spi.miso)
          sample_count := sample_count + 1.U
        }
      }

      // Shifting Edge: CPHA=0 -> Trailing edge (phase=1), CPHA=1 -> Leading edge (phase=0)
      // Special case: for CPHA=1, we don't shift on the very first leading edge (in sSetup or start of sShift).
      when(phase === !ctrl_cpha) {
        val is_first_leading = state === SpiState.sSetup
        when(!(ctrl_cpha === 1.U && is_first_leading)) {
          tx_reg := Cat(tx_reg(6, 0), 0.U(1.W))
        }
      }
    }
  }

  // TILELINK SLAVE REGISTER INTERFACE
  val tl_a = io.tl.a
  val tl_d = io.tl.d

  val addr_offset = tl_a.bits.address(11, 0)

  val is_txdata_write =
    tl_a.valid && (addr_offset === TXDATA) && (tl_a.bits.opcode === TLULOpcodesA.PutFullData.asUInt || tl_a.bits.opcode === TLULOpcodesA.PutPartialData.asUInt)
  val is_rxdata_read =
    tl_a.valid && (addr_offset === RXDATA) && (tl_a.bits.opcode === TLULOpcodesA.Get.asUInt)

  // Response and Read Data storage
  val tl_d_valid  = RegInit(false.B)
  val tl_d_opcode = Reg(UInt(3.W))
  val tl_d_data   = Reg(UInt(32.W))
  val tl_d_size   = Reg(UInt(tlul_p.z.W))
  val tl_d_source = Reg(UInt(tlul_p.a.W))
  val tl_d_error  = Reg(Bool())

  // Backpressure: Stall request channel if response is pending or FIFOs cannot accept/provide data
  tl_a.ready := !tl_d_valid && Mux(
    is_txdata_write,
    tx_fifo.io.enq.ready,
    Mux(is_rxdata_read, rx_fifo.io.deq.valid, true.B)
  )

  // Request Channel Processing
  when(tl_a.fire) {
    tl_d_valid  := true.B
    tl_d_source := tl_a.bits.source
    tl_d_size   := tl_a.bits.size
    tl_d_error  := false.B
    val is_write =
      (tl_a.bits.opcode === TLULOpcodesA.PutFullData.asUInt || tl_a.bits.opcode === TLULOpcodesA.PutPartialData.asUInt)

    when(is_write) {
      tl_d_opcode := TLULOpcodesD.AccessAck.asUInt
      switch(addr_offset) {
        is(CONTROL) { reg_control := tl_a.bits.data }
        is(CSID) { reg_csid := tl_a.bits.data }
        is(CSMODE) { reg_csmode := tl_a.bits.data }
        is(TXDATA) {
          tx_fifo.io.enq.valid := true.B
          tx_fifo.io.enq.bits  := tl_a.bits.data(7, 0)
        }
        // Return error for writes to read-only or status registers
        is(STATUS, RXDATA) { tl_d_error := true.B }
      }
    }.otherwise {
      tl_d_opcode := TLULOpcodesD.AccessAckData.asUInt
      switch(addr_offset) {
        is(STATUS) {
          // Bit 2: TX Full, Bit 1: RX Empty, Bit 0: Busy
          tl_d_data := Cat(
            0.U(29.W),
            state =/= SpiState.sIdle || tx_fifo.io.deq.valid,
            !rx_fifo.io.deq.valid,
            !tx_fifo.io.enq.ready
          )
        }
        is(CONTROL) { tl_d_data := reg_control }
        is(CSID) { tl_d_data := reg_csid }
        is(CSMODE) { tl_d_data := reg_csmode }
        is(RXDATA) {
          rx_fifo.io.deq.ready := true.B
          tl_d_data            := rx_fifo.io.deq.bits
        }
        // Return error for reads from write-only registers
        is(TXDATA) { tl_d_error := true.B }
      }
    }
    // Validate address range and return error for undefined offsets
    val is_known_addr =
      VecInit(STATUS, CONTROL, TXDATA, RXDATA, CSID, CSMODE).contains(addr_offset)
    when(!is_known_addr) { tl_d_error := true.B }
  }

  // Response Channel Handshake
  when(tl_d.fire) {
    tl_d_valid := false.B
  }

  tl_d.valid       := tl_d_valid
  tl_d.bits.opcode := tl_d_opcode
  tl_d.bits.data   := tl_d_data
  tl_d.bits.size   := tl_d_size
  tl_d.bits.source := tl_d_source
  tl_d.bits.error  := tl_d_error
  tl_d.bits.sink   := 0.U
  tl_d.bits.param  := 0.U
  tl_d.bits.user   := 0.U.asTypeOf(tl_d.bits.user)
}

/** Top-level SPI Master module with Asynchronous Clock Domain Crossing.
  *
  * Wraps the synchronous controller and uses TlulFifoAsync to bridge between high-speed system bus
  * (clk_i) and potentially slower SPI clock (spi_clk_i).
  */
class SpiMaster(p: TLULParameters) extends RawModule {
  val tlul_p = p
  val io     = IO(new Bundle {
    val clk_i     = Input(Clock())
    val rst_ni    = Input(AsyncReset())
    val tl        = Flipped(new OpenTitanTileLink.Host2Device(tlul_p))
    val spi       = new SpiIO
    val spi_clk_i = Input(Clock())
  })

  // CDC Adapter: Bridges TileLink Bus domain and SPI domain
  val fifo = Module(new TlulFifoAsync(tlul_p))
  fifo.io.clk_h_i := io.clk_i
  fifo.io.rst_h_i := !io.rst_ni.asBool
  fifo.io.tl_h <> io.tl

  // Reset synchronizer for the SPI clock domain
  val spi_reset = withClock(io.spi_clk_i) { RegNext(RegNext(!io.rst_ni.asBool)) }

  // SPI Controller instance running on independent clock/reset
  withClockAndReset(io.spi_clk_i, spi_reset) {
    val ctrl = Module(new SpiMasterCtrl(p))
    ctrl.io.tl <> fifo.io.tl_d
    io.spi <> ctrl.io.spi
  }

  fifo.io.clk_d_i := io.spi_clk_i
  fifo.io.rst_d_i := spi_reset
}

import common.ChiselEmitter

object EmitSpiMaster extends App {
  val tlul_p = new TLULParameters(dataBits = 32, addrBits = 32, idBits = 10)
  ChiselEmitter.emit(new SpiMaster(tlul_p), args)
}
