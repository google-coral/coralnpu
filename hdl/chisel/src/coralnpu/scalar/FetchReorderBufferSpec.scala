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

import chisel3._
import chisel3.simulator.scalatest.ChiselSim
import org.scalatest.freespec.AnyFreeSpec

class FetchReorderBufferSpec extends AnyFreeSpec with ChiselSim {
  val capacity = 4

  def makeDut(flowResponse: Boolean = false) = new FetchReorderBuffer(
    txidBits = 4,
    addrBits = 32,
    dataBits = 128,
    capacity = capacity,
    flowResponse = flowResponse
  )

  def resetDut(dut: FetchReorderBuffer): Unit = {
    dut.reset.poke(true.B)
    dut.clock.step()
    dut.reset.poke(false.B)
    dut.io.flush.poke(false.B)
    dut.io.newTx.valid.poke(false.B)
    dut.io.busResp.valid.poke(false.B)
    dut.io.commit.ready.poke(false.B)
  }

  def pokeNewTx(dut: FetchReorderBuffer, txid: UInt, addr: UInt): Unit = {
    dut.io.newTx.valid.poke(true.B)
    dut.io.newTx.bits.txid.poke(txid)
    dut.io.newTx.bits.addr.poke(addr)
  }

  def enqueueTx(dut: FetchReorderBuffer, txid: UInt, addr: UInt): Unit = {
    pokeNewTx(dut, txid, addr)
    expectNewTxReady(dut, true)
    dut.clock.step()
    dut.io.newTx.valid.poke(false.B)
  }

  def pokeBusResp(
    dut: FetchReorderBuffer,
    txid: UInt,
    data: UInt,
    fault: Bool = false.B
  ): Unit = {
    dut.io.busResp.valid.poke(true.B)
    dut.io.busResp.bits.txid.poke(txid)
    dut.io.busResp.bits.resp.data.poke(data)
    dut.io.busResp.bits.resp.fault.poke(fault)
  }

  def expectFreeTxid(dut: FetchReorderBuffer, txid: UInt): Unit = {
    dut.io.freeTxid.valid.expect(true.B)
    dut.io.freeTxid.bits.expect(txid)
  }

  def expectCommit(
    dut: FetchReorderBuffer,
    addr: UInt,
    data: UInt,
    fault: Bool = false.B
  ): Unit = {
    dut.io.commit.valid.expect(true.B)
    dut.io.commit.bits.addr.expect(addr)
    dut.io.commit.bits.resp.data.expect(data)
    dut.io.commit.bits.resp.fault.expect(fault)
  }

  def clearBusResp(dut: FetchReorderBuffer): Unit = {
    dut.io.busResp.valid.poke(false.B)
  }

  def setCommitReady(dut: FetchReorderBuffer, ready: Boolean): Unit = {
    dut.io.commit.ready.poke(ready.B)
  }

  def setFlush(dut: FetchReorderBuffer, flush: Boolean): Unit = {
    dut.io.flush.poke(flush.B)
  }

  def expectNoCommit(dut: FetchReorderBuffer): Unit = {
    dut.io.commit.valid.expect(false.B)
  }

  def expectNoFreeTxid(dut: FetchReorderBuffer): Unit = {
    dut.io.freeTxid.valid.expect(false.B)
  }

  def expectNewTxReady(dut: FetchReorderBuffer, ready: Boolean): Unit = {
    dut.io.newTx.ready.expect(ready.B)
  }

  def setupQueue(
    dut: FetchReorderBuffer,
    txids: Seq[Int],
    respondedTxids: Seq[Int] = Seq.empty
  ): Unit = {
    for (txid <- txids) {
      enqueueTx(dut, txid.U, (txid * 0x100).U)
    }
    for (txid <- respondedTxids) {
      pokeBusResp(dut, txid.U, (txid * 0x1000).U)
      dut.clock.step()
    }
    if (respondedTxids.nonEmpty) {
      clearBusResp(dut)
    }
  }

  def verifyQueueEmpty(dut: FetchReorderBuffer): Unit = {
    setupQueue(dut, 4 until 4 + capacity)
    expectNewTxReady(dut, false)
  }

  "FetchReorderBuffer Operations (flowResponse=false)" in {
    simulate(makeDut(flowResponse = false)) { dut =>
      // Basic Data Flow: Record and Commit with fault
      {
        resetDut(dut)
        setCommitReady(dut, true)

        enqueueTx(dut, 1.U, 0x100.U)

        // Provide response with fault = true
        pokeBusResp(dut, 1.U, 0x1000.U, fault = true.B)
        dut.clock.step()
        clearBusResp(dut)

        // Verify the fault bit successfully propagated to the commit stage
        expectCommit(dut, 0x100.U, 0x1000.U, fault = true.B)
      }

      // Basic Data Flow: Commit
      {
        resetDut(dut)
        // Condition 1: Empty buffer blocks commit
        expectNoCommit(dut)

        enqueueTx(dut, 1.U, 0x100.U)

        // Condition 2: No response yet blocks commit
        expectNoCommit(dut)

        pokeBusResp(dut, 1.U, 0x1000.U)
        dut.clock.step()
        clearBusResp(dut)

        // Commit should now be valid, and commit.ready being low blocks consumption
        expectCommit(dut, 0x100.U, 0x1000.U)

        // Condition 3: Unmatched busResp takes priority for freeTxid and blocks commit combinatorially
        pokeBusResp(dut, 2.U, 0x2000.U)
        expectNoCommit(dut)
        expectFreeTxid(dut, 2.U)
        dut.clock.step()
        clearBusResp(dut)

        // Back to normal, commit is valid again
        expectCommit(dut, 0x100.U, 0x1000.U)

        // Consume the first transaction
        setCommitReady(dut, true)
        dut.clock.step()
        setCommitReady(dut, false)
        expectNoCommit(dut)

        // Setup for Condition 4: Cancelled transaction at the head of the buffer
        setupQueue(dut, Seq(2, 3), Seq(2, 3))

        // Commit is valid for Tx 2
        expectCommit(dut, 0x200.U, 0x2000.U)

        // Trigger flush. In this cycle, it's still valid because s2Src=state (from prev cycle)
        setFlush(dut, true)
        dut.clock.step()
        setFlush(dut, false)

        // Condition 4: Queue has Tx 3 with valid response, but nCancelled == 1 blocks commit
        expectNoCommit(dut)

        dut.clock.step()
        // Queue is now empty
        expectNoCommit(dut)
      }

      // Basic Data Flow: Record and Commit
      {
        resetDut(dut)
        // Setup: Enqueue Tx 1 and Tx 2
        setupQueue(dut, Seq(1, 2), Seq(1))

        // Now Tx 1 is ready to commit.
        // Simultaneously provide response for Tx 2 and consume Tx 1.
        setCommitReady(dut, true)
        pokeBusResp(dut, 2.U, 0x2000.U)

        // Tx 1 should commit successfully while Tx 2's response is being recorded.
        expectCommit(dut, 0x100.U, 0x1000.U)
        expectFreeTxid(dut, 1.U)
        dut.clock.step()

        // In the next cycle, Tx 2 should be at the head and ready to commit,
        // proving its response was correctly recorded in the previous cycle.
        clearBusResp(dut)
        expectCommit(dut, 0x200.U, 0x2000.U)
        expectFreeTxid(dut, 2.U)
      }

      // Basic Data Flow: Reorder responses
      {
        resetDut(dut)
        // Setup: Enqueue Tx 1, 2, 3 and provide response for Tx 3 (out of order)
        setupQueue(dut, Seq(1, 2, 3), Seq(3))

        // Tx 1 is at head, un-responded. Commit must be blocked.
        expectNoCommit(dut)

        // Provide response for Tx 2 (out of order)
        pokeBusResp(dut, 2.U, 0x2000.U)
        dut.clock.step()

        // Commit is still blocked by Tx 1
        clearBusResp(dut)
        expectNoCommit(dut)

        // Provide response for Tx 1 (in order)
        pokeBusResp(dut, 1.U, 0x1000.U)
        dut.clock.step()
        clearBusResp(dut)

        // Now Tx 1 is ready! Consume it.
        setCommitReady(dut, true)
        expectCommit(dut, 0x100.U, 0x1000.U)
        expectFreeTxid(dut, 1.U)
        dut.clock.step()

        // Tx 2 and Tx 3 should immediately follow in perfect order
        expectCommit(dut, 0x200.U, 0x2000.U)
        expectFreeTxid(dut, 2.U)
        dut.clock.step()

        expectCommit(dut, 0x300.U, 0x3000.U)
        expectFreeTxid(dut, 3.U)
        dut.clock.step()

        setCommitReady(dut, false)
        expectNoCommit(dut)
        verifyQueueEmpty(dut)
      }

      // Flushing: Unmatched busResp and flush
      {
        resetDut(dut)
        // Setup: Enqueue Tx 1 (un-responded), Tx 2 (responded), Tx 3 (un-responded)
        setupQueue(dut, Seq(1, 2, 3), Seq(2))

        // Trigger flush while simultaneously providing an unmatched busResp
        setFlush(dut, true)
        pokeBusResp(dut, 4.U, 0x4000.U)

        // Unmatched busResp claims freeTxid.
        // The flush cancels all transactions. Tx 1 has no response so it is silently dropped.
        // Freeing the txid for the cancelled Tx 2 is blocked by the unmatched busResp, so Tx 2 (and Tx 3 shielded behind it) remain in the buffer.
        expectFreeTxid(dut, 4.U)
        dut.clock.step()

        // Remove the unmatched busResp. The buffer frees the txid for Tx 2.
        // Tx 3 (cancelled, no response) is silently dropped in the same cycle.
        setFlush(dut, false)
        clearBusResp(dut)

        expectFreeTxid(dut, 2.U)
        dut.clock.step()

        verifyQueueEmpty(dut)
      }

      // Flushing: Flush frees txid for responded cancelled transactions
      {
        resetDut(dut)
        // Setup: Enqueue Tx 1 (un-responded), Tx 2 (responded), Tx 3 (un-responded)
        setupQueue(dut, Seq(1, 2, 3), Seq(2))

        // Trigger flush with no blocking conditions
        setFlush(dut, true)

        // In this single cycle:
        // 1. Flush cancels all transactions. Tx 1 has no response, so it is silently dropped.
        // 2. Tx 2 is cancelled and already has a response, so its txid is freed via freeTxid.
        // 3. Tx 3 has no response and is behind Tx 2, so it is silently dropped in the same cascade.
        // All transactions are cleared immediately!
        expectFreeTxid(dut, 2.U)
        dut.clock.step()
        setFlush(dut, false)

        verifyQueueEmpty(dut)
      }

      // Flushing: Flush, record busResp, and free cancelled txid
      {
        resetDut(dut)
        // Setup: Enqueue Tx 1, Tx 2, Tx 3 (all un-responded)
        setupQueue(dut, Seq(1, 2, 3))

        // Trigger flush while simultaneously providing a matched busResp for Tx 2
        setFlush(dut, true)
        pokeBusResp(dut, 2.U, 0x2000.U)

        // In this single cycle:
        // 1. The response for Tx 2 is recorded.
        // 2. The flush cancels all transactions. Tx 1 (un-responded) is silently dropped.
        // 3. Tx 2 now has a response and is cancelled, so its txid is freed via freeTxid.
        // 4. Tx 3 (un-responded) is silently dropped in the same cascade.
        expectFreeTxid(dut, 2.U)
        expectNoCommit(dut)
        dut.clock.step()

        setFlush(dut, false)
        clearBusResp(dut)

        verifyQueueEmpty(dut)
      }

      // Flushing: Flush, record busResp, and commit
      {
        resetDut(dut)
        // Setup: Enqueue Tx 1 (responded), Tx 2 (un-responded), Tx 3 (un-responded)
        setupQueue(dut, Seq(1, 2, 3), Seq(1))

        // Simultaneously:
        // 1. Commit Tx 1
        // 2. Record response for Tx 2
        // 3. Flush
        setCommitReady(dut, true)
        pokeBusResp(dut, 2.U, 0x2000.U)
        setFlush(dut, true)

        // Committing Tx 1 claims freeTxid.
        // Freeing the txid for the cancelled Tx 2 is blocked by the commit, so Tx 2 is NOT dropped yet.
        // Tx 3 remains shielded behind Tx 2.
        expectCommit(dut, 0x100.U, 0x1000.U)
        expectFreeTxid(dut, 1.U)
        dut.clock.step()

        // Next cycle: Remove stimuli. The buffer frees the txid for Tx 2, and silently drops Tx 3.
        setCommitReady(dut, false)
        clearBusResp(dut)
        setFlush(dut, false)

        expectNoCommit(dut)
        expectFreeTxid(dut, 2.U)
        dut.clock.step()

        verifyQueueEmpty(dut)
      }

      // Flushing: Record busResp for a cancelled transaction
      {
        resetDut(dut)
        // Setup: Enqueue Tx 1 (un-responded), Tx 2 (responded), Tx 3 (un-responded)
        setupQueue(dut, Seq(1, 2, 3), Seq(2))

        // Trigger flush and an unmatched busResp simultaneously to block freeing cancelled txids
        setFlush(dut, true)
        pokeBusResp(dut, 4.U, 0x4000.U)

        // Tx 1 is silently dropped. Tx 2 is cancelled but has a response.
        // Freeing Tx 2's txid is blocked by the unmatched busResp (Tx 4), so Tx 2 and Tx 3 stay in the buffer.
        expectFreeTxid(dut, 4.U)
        expectNoCommit(dut)
        dut.clock.step()

        // Now Tx 3 is still in the buffer, cancelled, and un-responded.
        // Provide its response!
        setFlush(dut, false)
        pokeBusResp(dut, 3.U, 0x3000.U)

        // The buffer records Tx 3's response.
        // The buffer frees Tx 2's txid.
        // Since Tx 3 now has a response, it is NOT silently dropped and remains in the buffer.
        expectFreeTxid(dut, 2.U)
        expectNoCommit(dut)
        dut.clock.step()

        // Now Tx 3 is at the head, cancelled and responded. Its txid is freed.
        clearBusResp(dut)
        expectFreeTxid(dut, 3.U)
        expectNoCommit(dut)
        dut.clock.step()

        verifyQueueEmpty(dut)
      }

      // Queue Full and Combinatorial Unblocking: Flush and enqueue
      {
        resetDut(dut)
        // Setup: Queue has Tx 1, Tx 2
        setupQueue(dut, Seq(1, 2))

        // Same cycle: flush the queue AND enqueue Tx 3
        setFlush(dut, true)
        pokeNewTx(dut, 3.U, 0x300.U)
        expectNewTxReady(dut, true)
        dut.clock.step()

        setFlush(dut, false)
        dut.io.newTx.valid.poke(false.B)
        dut.clock.step()

        // Tx 1 and Tx 2 are cancelled by the flush and have no responses, so they are
        // silently dropped from the buffer.
        // Tx 3 is added AFTER the flush marker in the combinatorial chain, so it is NOT cancelled.
        // Tx 3 is now at the head, waiting for response.

        // Provide response for Tx 3
        pokeBusResp(dut, 3.U, 0x3000.U)
        dut.clock.step()
        clearBusResp(dut)

        // Verify Tx 3 commits successfully (proving it wasn't cancelled)
        expectCommit(dut, 0x300.U, 0x3000.U)
      }

      // Queue Full and Combinatorial Unblocking: Commit and enqueue
      {
        resetDut(dut)
        setupQueue(dut, 1 to capacity, Seq(1))
        expectNewTxReady(dut, false)

        setCommitReady(dut, true)
        pokeNewTx(dut, 5.U, 0x500.U)

        expectCommit(dut, 0x100.U, 0x1000.U)
        expectNewTxReady(dut, true)
        dut.clock.step()

        setCommitReady(dut, false)
        dut.io.newTx.valid.poke(false.B)

        // Buffer is full again (Tx 2, 3, 4, 5 waiting for responses)
        expectNewTxReady(dut, false)
      }

      // Queue Full and Combinatorial Unblocking: Drop cancelled transaction and enqueue
      {
        resetDut(dut)
        setupQueue(dut, 1 to capacity)
        expectNewTxReady(dut, false)

        setFlush(dut, true)
        pokeBusResp(dut, 1.U, 0x1000.U)

        expectFreeTxid(dut, 1.U)

        pokeNewTx(dut, 5.U, 0x500.U)
        expectNewTxReady(dut, true)
        dut.clock.step()
      }
    }
  }

  "FetchReorderBuffer Operations (flowResponse=true)" in {
    simulate(makeDut(flowResponse = true)) { d =>
      // Same-cycle commit
      {
        resetDut(d)

        // Enqueue Tx 1
        enqueueTx(d, 1.U, 0x100.U)

        // Currently at head, waiting for response. Commit must be blocked.
        expectNoCommit(d)

        // Provide response. Because flowResponse=true, commit goes valid immediately!
        pokeBusResp(d, 1.U, 0x1000.U)

        // Unblocked in the SAME cycle
        expectCommit(d, 0x100.U, 0x1000.U)

        // Consume it immediately
        setCommitReady(d, true)
        d.clock.step()

        // Verify consumption
        clearBusResp(d)
        setCommitReady(d, false)
        expectNoCommit(d)
        expectNewTxReady(d, true)

        // Enqueue enough to prove the buffer is empty
        verifyQueueEmpty(d)
      }

      // Same-cycle commit with fault
      {
        resetDut(d)

        // Enqueue Tx 1
        enqueueTx(d, 1.U, 0x100.U)

        // Currently at head, waiting for response. Commit must be blocked.
        expectNoCommit(d)

        // Provide response with fault = true. Because flowResponse=true, commit goes valid immediately!
        pokeBusResp(d, 1.U, 0x1000.U, fault = true.B)

        // Unblocked in the SAME cycle, and the fault bit is propagated!
        expectCommit(d, 0x100.U, 0x1000.U, fault = true.B)

        // Consume it immediately
        setCommitReady(d, true)
        d.clock.step()

        // Verify consumption
        clearBusResp(d)
        setCommitReady(d, false)
        expectNoCommit(d)
        expectNewTxReady(d, true)

        verifyQueueEmpty(d)
      }
    }
  }
}
