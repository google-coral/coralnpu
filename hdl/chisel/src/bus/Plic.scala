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

object PlicRegister extends ChiselEnum {
  val PENDING   = Value("h001000".U(24.W))
  val LE        = Value("h001080".U(24.W))
  val ENABLE    = Value("h002000".U(24.W))
  val THRESHOLD = Value("h200000".U(24.W))
  val CLAIM     = Value("h200004".U(24.W))
}

class Plic(p: TLULParameters, numInterrupts: Int = 31, priorityWidth: Int = 3) extends Module {
  val tlul_p = p
  val io     = IO(new Bundle {
    val tl   = Flipped(new OpenTitanTileLink.Host2Device(tlul_p))
    val srcs = Input(UInt(numInterrupts.W))
    val irq  = Output(Bool())
  })

  import PlicRegister._

  require(numInterrupts > 0 && numInterrupts <= 31, "PLIC currently supports 1 to 31 sources")
  require(priorityWidth > 0 && priorityWidth <= 32, "Priority width must be between 1 and 32")

  // --- Registers ---
  // Offset 0x000000 - 0x000FFC: Interrupt Priority
  val priority = RegInit(VecInit(Seq.fill(numInterrupts + 1)(0.U(priorityWidth.W))))
  // Offset 0x001000: Interrupt Pending
  val pending = RegInit(0.U((numInterrupts + 1).W))
  // Offset 0x001080: Level/Edge Configuration (0: level, 1: edge)
  // Custom register for the CoralNPU PLIC gateway.
  val le = RegInit(0.U((numInterrupts + 1).W))
  // Offset 0x002000: Interrupt Enable
  val enable = RegInit(0.U((numInterrupts + 1).W))
  // Offset 0x200000: Priority Threshold
  val threshold = RegInit(0.U(priorityWidth.W))

  val waiting_for_complete = RegInit(0.U((numInterrupts + 1).W))
  val src_q                = RegNext(io.srcs)

  // --- TileLink Interface ---
  val tl_a     = io.tl.a
  val tl_d     = io.tl.d
  val addr     = tl_a.bits.address(23, 0)
  val is_write = (tl_a.bits.opcode === TLULOpcodesA.PutFullData.asUInt ||
    tl_a.bits.opcode === TLULOpcodesA.PutPartialData.asUInt)
  val tl_a_write_fire = tl_a.fire && is_write
  val tl_a_read_fire  = tl_a.fire && !is_write

  // --- Highest Priority Pending Interrupt (HPPI) Logic ---
  val active_priorities = Wire(Vec(numInterrupts + 1, UInt(priorityWidth.W)))
  active_priorities(0) := 0.U
  for (i <- 1 to numInterrupts) {
    active_priorities(i) := Mux(pending(i) && enable(i), priority(i), 0.U)
  }

  val max_prio_init      = (0.U(priorityWidth.W), 0.U(32.W)) // (priority, id)
  val (max_prio, max_id) = (1 to numInterrupts).foldLeft(max_prio_init) {
    case ((max_p, max_i), idx) =>
      val p         = active_priorities(idx)
      val p_greater = p > max_p
      (Mux(p_greater, p, max_p), Mux(p_greater, idx.U(32.W), max_i))
  }

  // --- Claim / Complete Signals ---
  val id_bits         = log2Up(numInterrupts + 1)
  val claimable_id    = Mux(max_prio > threshold, max_id, 0.U)
  val actual_claim_id = Mux(tl_a_read_fire && addr === CLAIM.asUInt, claimable_id, 0.U)
  val complete_id     =
    Mux(tl_a_write_fire && addr === CLAIM.asUInt, tl_a.bits.data(id_bits - 1, 0), 0.U)

  // --- Register Updates (Single Assignment Style) ---

  // Pending
  pending := VecInit((0 to numInterrupts).map { i =>
    if (i == 0) false.B
    else {
      val s             = io.srcs(i - 1)
      val sq            = src_q(i - 1)
      val is_edge       = le(i)
      val edge_trigger  = s && !sq
      val level_trigger = s && !waiting_for_complete(i)
      val set_p         = Mux(is_edge, edge_trigger, level_trigger)
      val clear_p       = (actual_claim_id === i.U)
      Mux(clear_p, false.B, Mux(set_p, true.B, pending(i)))
    }
  }).asUInt

  // Waiting for Complete (Level-triggered Gateway State)
  waiting_for_complete := VecInit((0 to numInterrupts).map { i =>
    if (i == 0) false.B
    else {
      val is_level = !le(i)
      val set_w    = is_level && (actual_claim_id === i.U)
      val clear_w  = is_level && (complete_id === i.U)
      Mux(clear_w, false.B, Mux(set_w, true.B, waiting_for_complete(i)))
    }
  }).asUInt

  // Priority
  priority := VecInit((0 to numInterrupts).map { i =>
    Mux(
      tl_a_write_fire && addr === (i * 4).U && i.U =/= 0.U,
      tl_a.bits.data(priorityWidth - 1, 0),
      priority(i)
    )
  })

  // Enable, Threshold, Level/Edge
  enable := Mux(
    tl_a_write_fire && addr === ENABLE.asUInt,
    Cat(tl_a.bits.data(numInterrupts, 1), 0.U(1.W)),
    enable
  )
  threshold := Mux(
    tl_a_write_fire && addr === THRESHOLD.asUInt,
    tl_a.bits.data(priorityWidth - 1, 0),
    threshold
  )
  le := Mux(
    tl_a_write_fire && addr === LE.asUInt,
    Cat(tl_a.bits.data(numInterrupts, 1), 0.U(1.W)),
    le
  )

  // Output IRQ
  io.irq := max_prio > threshold

  // --- Read Data ---
  val priority_idx = addr(log2Up(numInterrupts * 4 + 4) - 1, 2)
  val read_data    = MuxCase(
    0.U,
    Seq(
      (addr >= "h000000".U && addr <= (numInterrupts * 4).U) -> priority(priority_idx),
      (addr === PENDING.asUInt)                              -> pending,
      (addr === LE.asUInt)                                   -> le,
      (addr === ENABLE.asUInt)                               -> enable,
      (addr === THRESHOLD.asUInt)                            -> threshold,
      (addr === CLAIM.asUInt)                                -> claimable_id
    )
  )

  // --- Response Logic ---
  val tl_d_valid  = RegInit(false.B)
  val tl_d_opcode = Reg(UInt(3.W))
  val tl_d_data   = Reg(UInt(32.W))
  val tl_d_size   = Reg(UInt(tlul_p.z.W))
  val tl_d_source = Reg(UInt(tlul_p.a.W))
  val tl_d_error  = Reg(Bool())

  tl_a.ready := !tl_d_valid

  tl_d_valid  := Mux(tl_d.fire, false.B, Mux(tl_a.fire, true.B, tl_d_valid))
  tl_d_source := Mux(tl_a.fire, tl_a.bits.source, tl_d_source)
  tl_d_size   := Mux(tl_a.fire, tl_a.bits.size, tl_d_size)
  tl_d_error  := Mux(tl_a.fire, false.B, tl_d_error)
  tl_d_opcode := Mux(
    tl_a.fire,
    Mux(is_write, TLULOpcodesD.AccessAck.asUInt, TLULOpcodesD.AccessAckData.asUInt),
    tl_d_opcode
  )
  tl_d_data := Mux(tl_a.fire, Mux(is_write, 0.U, read_data), tl_d_data)

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
