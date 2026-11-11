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
import chisel3.experimental.BundleLiterals._
import freechips.rocketchip.util.{AsyncQueue, AsyncQueueParams}

class DmaDesc extends Bundle {
  val op   = UInt(8.W)
  val addr = UInt(32.W)
  val len  = UInt(16.W)
}

object SpiFrameParserPhase extends ChiselEnum {
  val sOp, sAddr3, sAddr2, sAddr1, sAddr0, sLen1, sLen0, sSendDesc, sWriteData, sWaitEnd, sReset =
    Value
}

object DmaEnginePhase extends ChiselEnum {
  val sIdle, sReadAddr, sReadData, sWriteData, sWriteAddr, sWriteAck = Value
}

class SpiByteAssemblerRegs extends Bundle {
  val sr    = UInt(8.W)
  val count = UInt(4.W)
}

class SpiFrameParserRegs extends Bundle {
  val phase     = SpiFrameParserPhase()
  val op        = UInt(8.W)
  val addr      = UInt(32.W)
  val len       = UInt(16.W)
  val wr_remain = UInt(32.W)

  def onOpMatch(
    word_valid: Bool,
    word_bits: UInt,
    next_hdr_phase: SpiFrameParserPhase.Type
  ): SpiFrameParserRegs = {
    val res      = Wire(new SpiFrameParserRegs)
    val is_nop   = (word_bits === 0.U)
    val is_rw    = (word_bits === 1.U) || (word_bits === 2.U)
    val is_reset = (word_bits === 3.U)
    val advance  = word_valid && !is_nop
    res.phase := Mux(
      advance,
      Mux(
        is_reset,
        SpiFrameParserPhase.sReset,
        Mux(is_rw, next_hdr_phase, SpiFrameParserPhase.sWaitEnd)
      ),
      this.phase
    )
    res.op        := Mux(advance, Mux(is_rw || is_reset, word_bits(7, 0), 0.U), this.op)
    res.addr      := Mux(advance, 0.U, this.addr)
    res.len       := Mux(advance, 0.U, this.len)
    res.wr_remain := Mux(advance, 0.U, this.wr_remain)
    res
  }

  def onOp(byte_valid: Bool, byte_bits: UInt): SpiFrameParserRegs =
    onOpMatch(byte_valid, byte_bits, SpiFrameParserPhase.sAddr3)

  def onReset(): SpiFrameParserRegs = {
    val res = Wire(new SpiFrameParserRegs)
    res.phase     := SpiFrameParserPhase.sReset
    res.op        := this.op
    res.addr      := this.addr
    res.len       := this.len
    res.wr_remain := 0.U
    res
  }

  def onAddr(
    next_phase: SpiFrameParserPhase.Type,
    byte_valid: Bool,
    byte_bits: UInt,
    shift: Int
  ): SpiFrameParserRegs = {
    val res = Wire(new SpiFrameParserRegs)
    res.phase := Mux(byte_valid, next_phase, this.phase)
    res.op    := this.op
    res.addr  := Mux(
      byte_valid,
      if (shift == 24) (byte_bits << 24.U) else this.addr | (byte_bits << shift.U),
      this.addr
    )
    res.len       := this.len
    res.wr_remain := this.wr_remain
    res
  }

  def onLen(
    next_phase: SpiFrameParserPhase.Type,
    byte_valid: Bool,
    byte_bits: UInt,
    shift: Int
  ): SpiFrameParserRegs = {
    val res = Wire(new SpiFrameParserRegs)
    res.phase := Mux(byte_valid, next_phase, this.phase)
    res.op    := this.op
    res.addr  := this.addr
    res.len   := Mux(
      byte_valid,
      if (shift == 8) (byte_bits << 8.U) else this.len | byte_bits,
      this.len
    )
    res.wr_remain := this.wr_remain
    res
  }

  def onSendDesc(ready: Bool, wordsPerBeat: Int = 16): SpiFrameParserRegs = {
    val res         = Wire(new SpiFrameParserRegs)
    val is_op_write = (this.op === 2.U)
    val shiftBits   = log2Ceil(wordsPerBeat)
    res.phase := Mux(
      ready,
      Mux(is_op_write, SpiFrameParserPhase.sWriteData, SpiFrameParserPhase.sWaitEnd),
      this.phase
    )
    res.op        := this.op
    res.addr      := this.addr
    res.len       := this.len
    res.wr_remain := Mux(
      ready,
      Mux(is_op_write, (this.len.pad(32) + 1.U) << shiftBits.U, 0.U),
      this.wr_remain
    )
    res
  }

  def onOpWide(word_valid: Bool, word_bits: UInt): SpiFrameParserRegs =
    onOpMatch(word_valid, word_bits, SpiFrameParserPhase.sLen0)

  def onLenWide(word_valid: Bool, word_bits: UInt): SpiFrameParserRegs = {
    val res = Wire(new SpiFrameParserRegs)
    res.phase     := Mux(word_valid, SpiFrameParserPhase.sAddr1, this.phase)
    res.op        := this.op
    res.addr      := this.addr
    res.len       := Mux(word_valid, word_bits(15, 0), this.len)
    res.wr_remain := this.wr_remain
    res
  }

  def onAddrLoWide(word_valid: Bool, word_bits: UInt): SpiFrameParserRegs = {
    val res = Wire(new SpiFrameParserRegs)
    res.phase     := Mux(word_valid, SpiFrameParserPhase.sAddr0, this.phase)
    res.op        := this.op
    res.addr      := Mux(word_valid, word_bits(15, 0).pad(32), this.addr)
    res.len       := this.len
    res.wr_remain := this.wr_remain
    res
  }

  def onAddrHiWide(word_valid: Bool, word_bits: UInt): SpiFrameParserRegs = {
    val res = Wire(new SpiFrameParserRegs)
    res.phase     := Mux(word_valid, SpiFrameParserPhase.sSendDesc, this.phase)
    res.op        := this.op
    res.addr      := Mux(word_valid, Cat(word_bits(15, 0), this.addr(15, 0)), this.addr)
    res.len       := this.len
    res.wr_remain := this.wr_remain
    res
  }

  def onWriteData(byte_valid: Bool, ready: Bool): SpiFrameParserRegs = {
    val res               = Wire(new SpiFrameParserRegs)
    val is_wr_remain_zero = (this.wr_remain === 0.U)
    res.phase     := Mux(is_wr_remain_zero, SpiFrameParserPhase.sWaitEnd, this.phase)
    res.op        := this.op
    res.addr      := this.addr
    res.len       := this.len
    res.wr_remain := Mux(
      is_wr_remain_zero,
      0.U,
      Mux(byte_valid && ready, this.wr_remain - 1.U, this.wr_remain)
    )
    res
  }

  def onWaitEnd(): SpiFrameParserRegs = {
    val res = Wire(new SpiFrameParserRegs)
    res.phase     := SpiFrameParserPhase.sWaitEnd
    res.op        := this.op
    res.addr      := this.addr
    res.len       := this.len
    res.wr_remain := 0.U
    res
  }

}

class SpiBulkDeserializerRegs extends Bundle {
  val word_buf = UInt(128.W)
  val byte_idx = UInt(5.W)
}

class SpiMisoShifterRegs extends Bundle {
  val sr    = UInt(8.W)
  val count = UInt(4.W)
}

class DmaEngineRegs extends Bundle {
  val phase    = DmaEnginePhase()
  val dma_addr = UInt(32.W)
  val dma_len  = UInt(16.W)
  val beat_cnt = UInt(16.W)
  val word_acc = UInt(128.W)
  val byte_ptr = UInt(5.W)

  def onIdle(desc_valid: Bool, desc: DmaDesc): DmaEngineRegs = {
    val res = Wire(new DmaEngineRegs)
    res.phase := Mux(
      desc_valid,
      Mux(
        desc.op === 1.U,
        DmaEnginePhase.sReadAddr,
        Mux(desc.op === 2.U, DmaEnginePhase.sWriteData, DmaEnginePhase.sIdle)
      ),
      this.phase
    )
    res.dma_addr := Mux(desc_valid, desc.addr, this.dma_addr)
    res.dma_len  := Mux(desc_valid, desc.len, this.dma_len)
    res.beat_cnt := Mux(desc_valid, 0.U, this.beat_cnt)
    res.word_acc := Mux(desc_valid, 0.U, this.word_acc)
    res.byte_ptr := Mux(desc_valid, 0.U, this.byte_ptr)
    res
  }

  def onReadAddr(ready: Bool): DmaEngineRegs = {
    val res = Wire(new DmaEngineRegs)
    res       := this
    res.phase := Mux(ready, DmaEnginePhase.sReadData, this.phase)
    res
  }

  def onReadData(tl_d_valid: Bool, rd_data_ready: Bool): DmaEngineRegs = {
    val res = Wire(new DmaEngineRegs)
    res := this
    val fire = tl_d_valid && rd_data_ready
    res.phase := Mux(
      fire,
      Mux(this.beat_cnt === this.dma_len, DmaEnginePhase.sIdle, DmaEnginePhase.sReadAddr),
      this.phase
    )
    res.beat_cnt := Mux(fire, this.beat_cnt + 1.U, this.beat_cnt)
    res
  }

  def onWriteData(wr_data_valid: Bool, word_bits: UInt, wordWidth: Int = 8): DmaEngineRegs = {
    val res          = Wire(new DmaEngineRegs)
    val maxPtr       = (128 / wordWidth) - 1
    val shiftLog2    = log2Ceil(wordWidth)
    val is_ptr_max   = (this.byte_ptr === maxPtr.U)
    val shifted_word = (word_bits.pad(128) << (this.byte_ptr(3, 0) << shiftLog2.U))(127, 0)
    res          := this
    res.word_acc := Mux(
      wr_data_valid,
      this.word_acc | shifted_word,
      this.word_acc
    )
    res.byte_ptr := Mux(
      wr_data_valid,
      Mux(is_ptr_max, 0.U, this.byte_ptr + 1.U),
      this.byte_ptr
    )
    res.phase := Mux(wr_data_valid && is_ptr_max, DmaEnginePhase.sWriteAddr, this.phase)
    res
  }

  def onWriteAddr(ready: Bool): DmaEngineRegs = {
    val res = Wire(new DmaEngineRegs)
    res          := this
    res.phase    := Mux(ready, DmaEnginePhase.sWriteAck, this.phase)
    res.word_acc := Mux(ready, 0.U, this.word_acc)
    res.byte_ptr := Mux(ready, 0.U, this.byte_ptr)
    res
  }

  def onWriteAck(tl_d_valid: Bool): DmaEngineRegs = {
    val res = Wire(new DmaEngineRegs)
    res       := this
    res.phase := Mux(
      tl_d_valid,
      Mux(this.beat_cnt === this.dma_len, DmaEnginePhase.sIdle, DmaEnginePhase.sWriteData),
      this.phase
    )
    res.beat_cnt := Mux(tl_d_valid, this.beat_cnt + 1.U, this.beat_cnt)
    res.word_acc := Mux(tl_d_valid, 0.U, this.word_acc)
    res.byte_ptr := Mux(tl_d_valid, 0.U, this.byte_ptr)
    res
  }

}

/** Spi2TLULV2_SpiDomain: Handles SPI interface logic (clocked by `spi_clk`). */
class Spi2TLULV2_SpiDomain(p: TLULParameters, val dataWidth: Int = 1) extends Module {
  require(Set(1, 2, 4, 8, 16).contains(dataWidth), s"Unsupported Spi2TLUL dataWidth: $dataWidth")
  val wordWidth    = if (dataWidth == 16) 16 else 8
  val wordsPerBeat = 128 / wordWidth

  val io = IO(new Bundle {
    val q_mosi_pin = Flipped(Decoupled(UInt(dataWidth.W)))
    val q_miso_pin = Decoupled(UInt(dataWidth.W))

    // CDC Interface
    val q_desc_enq    = Decoupled(new DmaDesc)
    val q_wr_data_enq = Decoupled(UInt(wordWidth.W))
    val q_rd_data_deq = Flipped(Decoupled(UInt(128.W)))

    val sys_rst_o = Output(Bool())
    val wr_done_i = Input(Bool())
  })

  val c_SpiFrameParser = RegInit((new SpiFrameParserRegs).Lit(_.phase -> SpiFrameParserPhase.sOp))

  // At 25 MHz spi_clk, 16-bit Wide-SPI delivers one 128-bit beat every 320 ns (16 cycles of
  // 50 MHz clk_main), which exceeds single-beat stop-and-wait DDR4 write throughput. Sizing
  // q_spi_byte_q to 1024 halfwords (128 beats = 2 KB) uses one full UltraScale+ RAMB18E2 block
  // and provides over 2x margin for 60-beat host bursts paced by 0x00AA write acknowledgements.
  val spiQueueDepth = if (dataWidth == 16) 1024 else 16
  val q_spi_byte_q  = Module(new Queue(UInt(wordWidth.W), spiQueueDepth))

  val r_SpiByteAssembler_tick_will_fire = io.q_mosi_pin.valid

  if (dataWidth == 16) {
    // Direct 16-bit halfword ingestion (2 bytes per spi_clk)
    q_spi_byte_q.io.enq.bits  := io.q_mosi_pin.bits
    q_spi_byte_q.io.enq.valid := r_SpiByteAssembler_tick_will_fire
  } else {
    // Sub-byte or byte accumulation into 8-bit bytes
    val c_SpiByteAssembler              = RegInit(0.U.asTypeOf(new SpiByteAssemblerRegs))
    val target_count                    = (8 - dataWidth).U
    val r_SpiByteAssembler_is_byte_done = (c_SpiByteAssembler.count >= target_count)
    c_SpiByteAssembler.sr := Mux(
      r_SpiByteAssembler_tick_will_fire,
      Mux(
        r_SpiByteAssembler_is_byte_done,
        0.U,
        (c_SpiByteAssembler.sr << dataWidth.U) | io.q_mosi_pin.bits
      ),
      c_SpiByteAssembler.sr
    )
    c_SpiByteAssembler.count := Mux(
      r_SpiByteAssembler_tick_will_fire,
      Mux(r_SpiByteAssembler_is_byte_done, 0.U, c_SpiByteAssembler.count + dataWidth.U),
      c_SpiByteAssembler.count
    )
    q_spi_byte_q.io.enq.bits := (c_SpiByteAssembler.sr << dataWidth.U) | io.q_mosi_pin.bits
    q_spi_byte_q.io.enq.valid := r_SpiByteAssembler_tick_will_fire && r_SpiByteAssembler_is_byte_done
  }

  // Rule: SpiFrameParser.tick
  val r_SpiFrameParser_is_wr_remain_zero = (c_SpiFrameParser.wr_remain === 0.U)
  val r_SpiFrameParser_byte_valid        = q_spi_byte_q.io.deq.valid
  val r_SpiFrameParser_wr_data_ready     = io.q_wr_data_enq.ready
  val r_SpiFrameParser_desc_ready        = io.q_desc_enq.ready

  q_spi_byte_q.io.deq.ready := MuxLookup(c_SpiFrameParser.phase, r_SpiFrameParser_byte_valid)(
    Seq(
      SpiFrameParserPhase.sWriteData -> (r_SpiFrameParser_byte_valid && !r_SpiFrameParser_is_wr_remain_zero && r_SpiFrameParser_wr_data_ready),
      SpiFrameParserPhase.sSendDesc -> false.B,
      SpiFrameParserPhase.sWaitEnd  -> false.B,
      SpiFrameParserPhase.sReset    -> false.B
    )
  )

  io.q_wr_data_enq.valid := (c_SpiFrameParser.phase === SpiFrameParserPhase.sWriteData) && !r_SpiFrameParser_is_wr_remain_zero && r_SpiFrameParser_byte_valid
  io.q_wr_data_enq.bits := q_spi_byte_q.io.deq.bits

  val r_SpiFrameParser_desc_bits = Wire(new DmaDesc)
  r_SpiFrameParser_desc_bits.op   := c_SpiFrameParser.op
  r_SpiFrameParser_desc_bits.addr := c_SpiFrameParser.addr
  r_SpiFrameParser_desc_bits.len  := c_SpiFrameParser.len

  io.q_desc_enq.valid := (c_SpiFrameParser.phase === SpiFrameParserPhase.sSendDesc)
  io.q_desc_enq.bits  := r_SpiFrameParser_desc_bits

  if (dataWidth == 16) {
    // 4-halfword (8-byte) header: [opcode(16b), beat_len_m1(16b), addr_lo(16b), addr_hi(16b)]
    c_SpiFrameParser := MuxLookup(c_SpiFrameParser.phase, c_SpiFrameParser)(
      Seq(
        SpiFrameParserPhase.sOp -> c_SpiFrameParser
          .onOpWide(r_SpiFrameParser_byte_valid, q_spi_byte_q.io.deq.bits),
        SpiFrameParserPhase.sLen0 -> c_SpiFrameParser
          .onLenWide(r_SpiFrameParser_byte_valid, q_spi_byte_q.io.deq.bits),
        SpiFrameParserPhase.sAddr1 -> c_SpiFrameParser
          .onAddrLoWide(r_SpiFrameParser_byte_valid, q_spi_byte_q.io.deq.bits),
        SpiFrameParserPhase.sAddr0 -> c_SpiFrameParser
          .onAddrHiWide(r_SpiFrameParser_byte_valid, q_spi_byte_q.io.deq.bits),
        SpiFrameParserPhase.sSendDesc -> c_SpiFrameParser
          .onSendDesc(r_SpiFrameParser_desc_ready, wordsPerBeat),
        SpiFrameParserPhase.sWriteData -> c_SpiFrameParser
          .onWriteData(r_SpiFrameParser_byte_valid, r_SpiFrameParser_wr_data_ready),
        SpiFrameParserPhase.sWaitEnd -> c_SpiFrameParser.onWaitEnd(),
        SpiFrameParserPhase.sReset   -> c_SpiFrameParser.onReset()
      )
    )
  } else {
    // 7-byte header: [op(1B), addr(4B BE), beat_len_m1(2B BE)]
    c_SpiFrameParser := MuxLookup(c_SpiFrameParser.phase, c_SpiFrameParser)(
      Seq(
        SpiFrameParserPhase.sOp -> c_SpiFrameParser
          .onOp(r_SpiFrameParser_byte_valid, q_spi_byte_q.io.deq.bits),
        SpiFrameParserPhase.sAddr3 -> c_SpiFrameParser.onAddr(
          SpiFrameParserPhase.sAddr2,
          r_SpiFrameParser_byte_valid,
          q_spi_byte_q.io.deq.bits,
          24
        ),
        SpiFrameParserPhase.sAddr2 -> c_SpiFrameParser.onAddr(
          SpiFrameParserPhase.sAddr1,
          r_SpiFrameParser_byte_valid,
          q_spi_byte_q.io.deq.bits,
          16
        ),
        SpiFrameParserPhase.sAddr1 -> c_SpiFrameParser.onAddr(
          SpiFrameParserPhase.sAddr0,
          r_SpiFrameParser_byte_valid,
          q_spi_byte_q.io.deq.bits,
          8
        ),
        SpiFrameParserPhase.sAddr0 -> c_SpiFrameParser.onAddr(
          SpiFrameParserPhase.sLen1,
          r_SpiFrameParser_byte_valid,
          q_spi_byte_q.io.deq.bits,
          0
        ),
        SpiFrameParserPhase.sLen1 -> c_SpiFrameParser
          .onLen(
            SpiFrameParserPhase.sLen0,
            r_SpiFrameParser_byte_valid,
            q_spi_byte_q.io.deq.bits,
            8
          ),
        SpiFrameParserPhase.sLen0 -> c_SpiFrameParser.onLen(
          SpiFrameParserPhase.sSendDesc,
          r_SpiFrameParser_byte_valid,
          q_spi_byte_q.io.deq.bits,
          0
        ),
        SpiFrameParserPhase.sSendDesc -> c_SpiFrameParser
          .onSendDesc(r_SpiFrameParser_desc_ready, wordsPerBeat),
        SpiFrameParserPhase.sWriteData -> c_SpiFrameParser
          .onWriteData(r_SpiFrameParser_byte_valid, r_SpiFrameParser_wr_data_ready),
        SpiFrameParserPhase.sWaitEnd -> c_SpiFrameParser.onWaitEnd(),
        SpiFrameParserPhase.sReset   -> c_SpiFrameParser.onReset()
      )
    )
  }

  io.sys_rst_o := (c_SpiFrameParser.phase === SpiFrameParserPhase.sReset)

  if (dataWidth == 16) {
    // 16-bit MISO: 1 sync halfword (0x00FE) + 8 data halfwords per 128-bit beat
    val w16_idx  = RegInit(0.U(4.W))
    val w16_buf  = RegInit(0.U(128.W))
    val miso_reg = RegInit(0.U(16.W))

    val is_idle   = (w16_idx === 0.U)
    val can_start = is_idle && io.q_rd_data_deq.valid

    io.q_rd_data_deq.ready := is_idle

    val wr_ack_ready =
      (c_SpiFrameParser.phase === SpiFrameParserPhase.sWaitEnd) &&
        (c_SpiFrameParser.op === 2.U) &&
        io.wr_done_i

    when(can_start) {
      miso_reg := 0x00fe.U(16.W)
      w16_buf  := io.q_rd_data_deq.bits
      w16_idx  := 8.U
    }.elsewhen(!is_idle) {
      miso_reg := w16_buf(15, 0)
      w16_buf  := w16_buf >> 16.U
      w16_idx  := w16_idx - 1.U
    }.otherwise {
      miso_reg := Mux(wr_ack_ready, 0x00aa.U(16.W), 0.U(16.W))
    }

    io.q_miso_pin.bits  := miso_reg
    io.q_miso_pin.valid := true.B
  } else {
    val c_SpiBulkDeserializer = RegInit(0.U.asTypeOf(new SpiBulkDeserializerRegs))
    val c_SpiMisoShifter      = RegInit(0.U.asTypeOf(new SpiMisoShifterRegs))
    val q_miso_byte_q         = Module(new Queue(UInt(wordWidth.W), 16))

    // Rule: SpiBulkDeserializer.tick
    val r_SpiMisoShifter_is_count_zero    = (c_SpiMisoShifter.count === 0.U)
    val r_SpiBulkDeserializer_is_idx_zero = (c_SpiBulkDeserializer.byte_idx === 0.U)
    val r_SpiBulkDeserializer_is_idx_17   = (c_SpiBulkDeserializer.byte_idx === 17.U)
    val r_SpiBulkDeserializer_is_idx_15   = (c_SpiBulkDeserializer.byte_idx === 15.U)
    val r_SpiBulkDeserializer_can_start   =
      r_SpiBulkDeserializer_is_idx_zero && io.q_rd_data_deq.valid && r_SpiMisoShifter_is_count_zero
    val r_SpiBulkDeserializer_can_enq = q_miso_byte_q.io.enq.ready

    io.q_rd_data_deq.ready := r_SpiBulkDeserializer_can_start && r_SpiBulkDeserializer_can_enq

    q_miso_byte_q.io.enq.bits := Mux(
      r_SpiBulkDeserializer_is_idx_zero,
      0xfe.U,
      c_SpiBulkDeserializer.word_buf(7, 0)
    )
    q_miso_byte_q.io.enq.valid := r_SpiBulkDeserializer_can_enq && (r_SpiBulkDeserializer_can_start || r_SpiBulkDeserializer_is_idx_17 || (!r_SpiBulkDeserializer_is_idx_zero && !r_SpiBulkDeserializer_is_idx_17))

    c_SpiBulkDeserializer.word_buf := Mux(
      r_SpiBulkDeserializer_can_enq,
      Mux(
        r_SpiBulkDeserializer_is_idx_zero,
        Mux(r_SpiBulkDeserializer_can_start, io.q_rd_data_deq.bits, 0.U),
        c_SpiBulkDeserializer.word_buf >> 8.U
      ),
      c_SpiBulkDeserializer.word_buf
    )

    c_SpiBulkDeserializer.byte_idx := Mux(
      r_SpiBulkDeserializer_can_enq,
      Mux(
        r_SpiBulkDeserializer_is_idx_zero,
        Mux(r_SpiBulkDeserializer_can_start, 17.U, 0.U),
        Mux(
          r_SpiBulkDeserializer_is_idx_17,
          1.U,
          Mux(r_SpiBulkDeserializer_is_idx_15, 0.U, c_SpiBulkDeserializer.byte_idx + 1.U)
        )
      ),
      c_SpiBulkDeserializer.byte_idx
    )

    // Rule: SpiMisoShifter.tick
    val r_SpiMisoShifter_can_deq =
      r_SpiMisoShifter_is_count_zero && q_miso_byte_q.io.deq.valid

    q_miso_byte_q.io.deq.ready := r_SpiMisoShifter_can_deq

    io.q_miso_pin.bits := Mux(
      r_SpiMisoShifter_is_count_zero,
      Mux(
        q_miso_byte_q.io.deq.valid,
        q_miso_byte_q.io.deq.bits(7, 8 - dataWidth),
        0.U(dataWidth.W)
      ),
      c_SpiMisoShifter.sr(7, 8 - dataWidth)
    )
    io.q_miso_pin.valid := true.B

    c_SpiMisoShifter.sr := Mux(
      r_SpiMisoShifter_is_count_zero,
      Mux(r_SpiMisoShifter_can_deq, (q_miso_byte_q.io.deq.bits << dataWidth.U), 0.U),
      (c_SpiMisoShifter.sr << dataWidth.U)
    )

    c_SpiMisoShifter.count := Mux(
      r_SpiMisoShifter_is_count_zero,
      Mux(r_SpiMisoShifter_can_deq, (8 - dataWidth).U, 0.U),
      Mux(c_SpiMisoShifter.count >= dataWidth.U, c_SpiMisoShifter.count - dataWidth.U, 0.U)
    )
  }

  io.q_mosi_pin.ready := r_SpiByteAssembler_tick_will_fire
}

/** Spi2TLULV2_TlulDomain: Handles TileLink-related logic (clocked by system `clock`). */
class Spi2TLULV2_TlulDomain(p: TLULParameters, val wordWidth: Int = 8) extends Module {
  val tlul_p = p
  val io     = IO(new Bundle {
    val q_tl_a = Decoupled(new OpenTitanTileLink.A_Channel(tlul_p))
    val q_tl_d = Flipped(Decoupled(new OpenTitanTileLink.D_Channel(tlul_p)))

    // CDC Interface
    val q_desc_deq    = Flipped(Decoupled(new DmaDesc))
    val q_wr_data_deq = Flipped(Decoupled(UInt(wordWidth.W)))
    val q_rd_data_enq = Decoupled(UInt(128.W))
    val spi_csb_sync  = Input(Bool())
    val wr_done_o     = Output(Bool())
  })

  val c_DmaEngine = RegInit((new DmaEngineRegs).Lit(_.phase -> DmaEnginePhase.sIdle))

  // Queue: tl_a_pending
  val q_tl_a_pending = Module(new Queue(new OpenTitanTileLink.A_Channel(tlul_p), 1))

  val r_TlaSender_send_will_fire = q_tl_a_pending.io.deq.valid && io.q_tl_a.ready

  // Rule: DmaEngine.tick
  val r_DmaEngine_is_idle       = (c_DmaEngine.phase === DmaEnginePhase.sIdle)
  val r_DmaEngine_is_read_addr  = (c_DmaEngine.phase === DmaEnginePhase.sReadAddr)
  val r_DmaEngine_is_read_data  = (c_DmaEngine.phase === DmaEnginePhase.sReadData)
  val r_DmaEngine_is_write_data = (c_DmaEngine.phase === DmaEnginePhase.sWriteData)
  val r_DmaEngine_is_write_addr = (c_DmaEngine.phase === DmaEnginePhase.sWriteAddr)
  val r_DmaEngine_is_write_ack  = (c_DmaEngine.phase === DmaEnginePhase.sWriteAck)

  val r_DmaEngine_desc_bits  = io.q_desc_deq.bits
  val r_DmaEngine_desc_valid = io.q_desc_deq.valid

  val r_DmaEngine_tl_d_valid    = io.q_tl_d.valid
  val r_DmaEngine_wr_data_valid = io.q_wr_data_deq.valid
  val r_DmaEngine_rd_data_ready = io.q_rd_data_enq.ready
  val r_DmaEngine_is_beat_done  = (c_DmaEngine.beat_cnt === c_DmaEngine.dma_len)

  val xfer_aborted = RegInit(false.B)
  when(r_DmaEngine_is_idle) {
    xfer_aborted := false.B
  }.elsewhen(io.spi_csb_sync) {
    xfer_aborted := true.B
  }
  val abort_active = (!r_DmaEngine_is_idle) && (io.spi_csb_sync || xfer_aborted)

  io.wr_done_o := r_DmaEngine_is_write_ack && r_DmaEngine_tl_d_valid && r_DmaEngine_is_beat_done && !abort_active

  io.q_desc_deq.ready := r_DmaEngine_is_idle && r_DmaEngine_desc_valid
  io.q_tl_d.ready     := (
    (r_DmaEngine_is_read_data && r_DmaEngine_tl_d_valid && (r_DmaEngine_rd_data_ready || abort_active)) ||
      (r_DmaEngine_is_write_ack && r_DmaEngine_tl_d_valid)
  )
  io.q_wr_data_deq.ready := r_DmaEngine_is_write_data && r_DmaEngine_wr_data_valid

  io.q_rd_data_enq.valid := r_DmaEngine_is_read_data && r_DmaEngine_tl_d_valid && !abort_active
  io.q_rd_data_enq.bits  := io.q_tl_d.bits.data

  q_tl_a_pending.io.enq.valid := (r_DmaEngine_is_read_addr && !abort_active) || r_DmaEngine_is_write_addr
  q_tl_a_pending.io.enq.bits.opcode := Mux(
    r_DmaEngine_is_read_addr,
    TLULOpcodesA.Get.asUInt,
    TLULOpcodesA.PutFullData.asUInt
  )
  q_tl_a_pending.io.enq.bits.param   := 0.U
  q_tl_a_pending.io.enq.bits.size    := 4.U
  q_tl_a_pending.io.enq.bits.source  := 0.U
  q_tl_a_pending.io.enq.bits.address := c_DmaEngine.dma_addr + (c_DmaEngine.beat_cnt << 4.U)
  q_tl_a_pending.io.enq.bits.mask    := 0xffff.U
  q_tl_a_pending.io.enq.bits.data    := c_DmaEngine.word_acc
  q_tl_a_pending.io.enq.bits.user    := 0.U.asTypeOf(q_tl_a_pending.io.enq.bits.user)

  // DMA Engine lifecycle with full CSB-abort recovery across writes and in-flight reads
  val abort_to_idle =
    (r_DmaEngine_is_write_data && abort_active && !r_DmaEngine_wr_data_valid) ||
      (r_DmaEngine_is_read_addr && abort_active) ||
      ((r_DmaEngine_is_read_data || r_DmaEngine_is_write_ack) && abort_active && r_DmaEngine_tl_d_valid)
  when(abort_to_idle) {
    c_DmaEngine.phase    := DmaEnginePhase.sIdle
    c_DmaEngine.word_acc := 0.U
    c_DmaEngine.byte_ptr := 0.U
  }.otherwise {
    c_DmaEngine := MuxLookup(c_DmaEngine.phase, c_DmaEngine)(
      Seq(
        DmaEnginePhase.sIdle -> c_DmaEngine.onIdle(r_DmaEngine_desc_valid, r_DmaEngine_desc_bits),
        DmaEnginePhase.sReadAddr -> c_DmaEngine.onReadAddr(q_tl_a_pending.io.enq.ready),
        DmaEnginePhase.sReadData -> c_DmaEngine
          .onReadData(r_DmaEngine_tl_d_valid, r_DmaEngine_rd_data_ready),
        DmaEnginePhase.sWriteData -> c_DmaEngine
          .onWriteData(r_DmaEngine_wr_data_valid, io.q_wr_data_deq.bits, wordWidth),
        DmaEnginePhase.sWriteAddr -> c_DmaEngine.onWriteAddr(q_tl_a_pending.io.enq.ready),
        DmaEnginePhase.sWriteAck  -> c_DmaEngine.onWriteAck(r_DmaEngine_tl_d_valid)
      )
    )
  }

  // Rule: TlaSender.send
  io.q_tl_a.bits  := q_tl_a_pending.io.deq.bits
  io.q_tl_a.valid := r_TlaSender_send_will_fire

  q_tl_a_pending.io.deq.ready := r_TlaSender_send_will_fire
}

/** Spi2TLULV2: Converts SPI frames into TileLink-UL (TL-UL) transactions. Wrapper that instantiates
  * SPI and TLUL domains and connects them via AsyncQueues.
  */
class Spi2TLULV2(p: TLULParameters, val dataWidth: Int = 1) extends Module {
  assert(p.w == 16)
  val wordWidth  = if (dataWidth == 16) 16 else 8
  val wrCdcDepth = if (dataWidth == 16) 32 else 16
  val tlul_p     = p
  val io         = IO(new Bundle {
    val spi_clk    = Input(Clock())
    val spi_rst_n  = Input(Bool())
    val q_mosi_pin = Flipped(Decoupled(UInt(dataWidth.W)))
    val q_miso_pin = Decoupled(UInt(dataWidth.W))
    val q_tl_a     = Decoupled(new OpenTitanTileLink.A_Channel(tlul_p))
    val q_tl_d     = Flipped(Decoupled(new OpenTitanTileLink.D_Channel(tlul_p)))
    val sys_rst_o  = Output(Bool())
  })

  // CDC FIFOs
  val sysRst = reset.asBool

  val q_desc_cdc = Module(new AsyncQueue(new DmaDesc, AsyncQueueParams(depth = 4, safe = true)))
  q_desc_cdc.io.enq_clock := io.spi_clk
  q_desc_cdc.io.enq_reset := !io.spi_rst_n
  q_desc_cdc.io.deq_clock := clock
  q_desc_cdc.io.deq_reset := sysRst

  val q_wr_data_cdc =
    Module(new AsyncQueue(UInt(wordWidth.W), AsyncQueueParams(depth = wrCdcDepth, safe = true)))
  q_wr_data_cdc.io.enq_clock := io.spi_clk
  q_wr_data_cdc.io.enq_reset := !io.spi_rst_n
  q_wr_data_cdc.io.deq_clock := clock
  q_wr_data_cdc.io.deq_reset := sysRst

  val q_rd_data_cdc = Module(new AsyncQueue(UInt(128.W), AsyncQueueParams(depth = 4, safe = true)))
  q_rd_data_cdc.io.enq_clock := clock
  q_rd_data_cdc.io.enq_reset := sysRst
  q_rd_data_cdc.io.deq_clock := io.spi_clk
  q_rd_data_cdc.io.deq_reset := !io.spi_rst_n

  // SPI Domain
  val u_spi_domain = withClockAndReset(io.spi_clk, (!io.spi_rst_n).asAsyncReset) {
    Module(new Spi2TLULV2_SpiDomain(p, dataWidth))
  }
  u_spi_domain.io.q_mosi_pin <> io.q_mosi_pin
  u_spi_domain.io.q_miso_pin <> io.q_miso_pin
  u_spi_domain.io.q_desc_enq <> q_desc_cdc.io.enq
  u_spi_domain.io.q_wr_data_enq <> q_wr_data_cdc.io.enq
  u_spi_domain.io.q_rd_data_deq <> q_rd_data_cdc.io.deq

  // TLUL Domain (3-FF CSB synchronizer matched by ASYNC_REG in pins_nexus.xdc)
  val spi_csb_sync_s0 = RegInit(true.B)
  val spi_csb_sync_s1 = RegInit(true.B)
  val spi_csb_sync_s2 = RegInit(true.B)
  spi_csb_sync_s0 := !io.spi_rst_n
  spi_csb_sync_s1 := spi_csb_sync_s0
  spi_csb_sync_s2 := spi_csb_sync_s1
  val spi_csb_sys   = spi_csb_sync_s2
  val u_tlul_domain = Module(new Spi2TLULV2_TlulDomain(p, wordWidth))
  u_tlul_domain.io.q_tl_a <> io.q_tl_a
  u_tlul_domain.io.q_tl_d <> io.q_tl_d
  u_tlul_domain.io.q_desc_deq <> q_desc_cdc.io.deq
  u_tlul_domain.io.q_wr_data_deq <> q_wr_data_cdc.io.deq
  u_tlul_domain.io.q_rd_data_enq <> q_rd_data_cdc.io.enq
  u_tlul_domain.io.spi_csb_sync := spi_csb_sys

  // Level-latched write completion flag synchronized from TLUL domain back to SPI domain
  val wr_done_latch = RegInit(false.B)
  when(spi_csb_sys || q_desc_cdc.io.deq.fire) {
    wr_done_latch := false.B
  }.elsewhen(u_tlul_domain.io.wr_done_o) {
    wr_done_latch := true.B
  }

  withClockAndReset(io.spi_clk, (!io.spi_rst_n).asAsyncReset) {
    val wr_done_sync_s0 = RegInit(false.B).suggestName("wr_done_sync_s0")
    val wr_done_sync_s1 = RegInit(false.B).suggestName("wr_done_sync_s1")
    wr_done_sync_s0           := wr_done_latch
    wr_done_sync_s1           := wr_done_sync_s0
    u_spi_domain.io.wr_done_i := wr_done_sync_s1
  }

  // Synchronize soft reset to system clock domain
  withClockAndReset(clock, reset) {
    val sys_rst_sync_s0 = RegInit(false.B).suggestName("sys_rst_sync_s0")
    val sys_rst_sync_s1 = RegInit(false.B).suggestName("sys_rst_sync_s1")
    sys_rst_sync_s0 := u_spi_domain.io.sys_rst_o
    sys_rst_sync_s1 := sys_rst_sync_s0
    io.sys_rst_o    := sys_rst_sync_s1
  }
}
