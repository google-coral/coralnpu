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

package coralnpu

import bus._
import chisel3._
import chisel3.util._

/** Isolates a `Core` TileLink-UL host port (`io.tl_h`) from the surrounding ungated TileLink-UL
  * fabric (`io.tl_d`) across clock-gating and soft-reset boundaries.
  *
  * Inside `CoreAxi`, `Core` runs on a gated clock (`io.coreClkEn`) and can be reset independently
  * of the surrounding TCM and external bus fabric via `io.coreReset` (CSR soft reset or debug
  * `ndmreset`). Clocked on the ungated fabric clock and global reset, this bridge enforces two
  * invariants:
  *
  *   1. '''Clock-gate isolation (`io.coreClkEn`)''': While the core clock is gated (such as during
  *      `WFI` or CSR clock gating), `Core`'s outputs remain frozen. Channel A handshakes are gated
  *      off when `!io.coreClkEn` so the ungated fabric cannot accept duplicate requests across
  *      gated cycles. Returning Channel D responses are absorbed into a flow-through queue (`d_q`)
  *      while `io.tl_h.d.valid` is held low until `io.coreClkEn` resumes, preventing shared TCM
  *      banks or external arbiters from stalling on a sleeping core.
  *   2. '''Soft-reset draining (`io.coreReset`)''': Soft reset clears `Core` state while pre-reset
  *      transactions may still be in flight in the ungated fabric. Asserting `io.coreReset` flushes
  *      `d_q` and snapshots the count of unreturned fabric transactions into `orphaned`. New
  *      post-reset Channel A requests remain blocked (`orphaned =/= 0.U`) while returning pre-reset
  *      Channel D responses are silently drained (`io.tl_d.d.ready := true.B` without enqueueing)
  *      until `orphaned` reaches zero, ensuring stale responses never corrupt post-reset
  *      transaction slots.
  *
  * @param p
  *   TileLink-UL bus parameters.
  * @param maxOutstanding
  *   Maximum number of concurrent in-flight requests on `io.tl_d`, used to size the tracking
  *   counters.
  * @param dQueueEntries
  *   Depth of the Channel D response buffer used while `Core` is clock-gated.
  */
class CoreDomainTlulBridge(
  p: TLULParameters,
  maxOutstanding: Int,
  dQueueEntries: Int = 2
) extends Module {
  require(maxOutstanding > 0, "maxOutstanding must be positive")
  require(dQueueEntries > 0, "dQueueEntries must be positive")

  val io = IO(new Bundle {
    val tl_h      = Flipped(new TLULHost2Device[NoUser, NoUser](p))
    val tl_d      = new TLULHost2Device[NoUser, NoUser](p)
    val coreClkEn = Input(Bool())
    val coreReset = Input(Bool())
  })

  val ctrWidth    = log2Ceil(maxOutstanding + 1)
  val outstanding = RegInit(0.U(ctrWidth.W))
  val orphaned    = RegInit(0.U(ctrWidth.W))

  // Only allow Channel A handshakes on active core clock edges when not in reset
  // and after any pre-reset orphaned fabric transactions have drained.
  val canIssueA = io.coreClkEn && !io.coreReset && (orphaned === 0.U)
  io.tl_d.a.valid := io.tl_h.a.valid && canIssueA
  io.tl_h.a.ready := io.tl_d.a.ready && canIssueA
  io.tl_d.a.bits  := io.tl_h.a.bits

  // Buffer returning Channel D responses while the core clock is gated so shared
  // TCM banks never stall waiting for the sleeping core.
  val d_q = Module(
    new Queue(new TileLink_D_Channel(p), entries = dQueueEntries, flow = true, hasFlush = true)
  )
  d_q.io.flush.get := io.coreReset

  // Silently drain Channel D responses during coreReset or while orphaned pre-reset
  // fabric transactions are still returning.
  val dropResp = io.coreReset || (orphaned > 0.U)
  d_q.io.enq.valid := io.tl_d.d.valid && !dropResp
  d_q.io.enq.bits  := io.tl_d.d.bits
  io.tl_d.d.ready  := Mux(dropResp, true.B, d_q.io.enq.ready)

  val canDeliverD = io.coreClkEn && !io.coreReset
  io.tl_h.d.valid  := d_q.io.deq.valid && canDeliverD
  io.tl_h.d.bits   := d_q.io.deq.bits
  d_q.io.deq.ready := io.tl_h.d.ready && canDeliverD

  val aFire           = io.tl_d.a.fire
  val dFire           = io.tl_d.d.fire
  val outstandingNext = MuxCase(
    outstanding,
    Seq(
      (aFire && !dFire) -> (outstanding + 1.U),
      (!aFire && dFire) -> (outstanding - 1.U)
    )
  )
  outstanding := outstandingNext

  orphaned := MuxCase(
    orphaned,
    Seq(
      io.coreReset                -> outstandingNext,
      (dFire && (orphaned > 0.U)) -> (orphaned - 1.U)
    )
  )
}
