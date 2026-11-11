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

import bus._
import chisel3._
import chisel3.simulator.scalatest.ChiselSim
import org.scalatest.freespec.AnyFreeSpec

class CoreTlulAxiCSRSpec extends AnyFreeSpec with ChiselSim {
  var p = new Parameters
  p.lsuDataBits = 128
  // The original fabric-based design used relative (offset) addresses.
  // Since we removed the fabric and migrated to TL-UL, we must now use absolute addresses.
  p.m = MemoryRegions.default

  "CoreTlulAxiCSR" in {
    simulate(new CoreTlulAxiCSR(p)) { dut =>
      def resetDut(): Unit = {
        dut.reset.poke(true.B)
        dut.clock.step()
        dut.reset.poke(false.B)
        dut.io.internal.poke(false.B)
        dut.io.halted.poke(false.B)
        dut.io.fault.poke(false.B)
        dut.io.axi.read.addr.valid.poke(false.B)
        dut.io.axi.read.data.ready.poke(false.B)
        dut.io.axi.write.addr.valid.poke(false.B)
        dut.io.axi.write.data.valid.poke(false.B)
        dut.io.axi.write.resp.ready.poke(false.B)
        dut.io.debug.req.ready.poke(false.B)
        dut.io.debug.rsp.valid.poke(false.B)
      }

      // Initialization
      {
        dut.io.axi.read.addr.ready.expect(1)
        dut.io.axi.read.data.valid.expect(0)
        dut.io.axi.write.addr.ready.expect(0)
        dut.io.axi.write.data.ready.expect(0)
        dut.io.axi.write.resp.valid.expect(0)
      }

      resetDut()

      // Read
      {
        dut.io.internal.poke(false.B)
        dut.io.halted.poke(false.B)
        dut.io.fault.poke(false.B)
        dut.io.coralnpu_csr.value(0).poke("xCAFEB0BA".U)

        // Send read request
        dut.io.axi.read.addr.valid.poke(true.B)
        dut.io.axi.read.addr.bits.addr.poke(0x30100.U)
        dut.io.axi.read.addr.ready.expect(1)
        dut.clock.step()
        dut.io.axi.read.addr.valid.poke(false.B)

        // Wait for response
        while (dut.io.axi.read.data.valid.peek().litValue != 1) {
          dut.clock.step()
        }
        dut.io.axi.read.data.valid.expect(1)
        dut.io.axi.read.data.bits.data.expect(3405689018L)
        dut.io.axi.read.data.bits.last.expect(1)
        dut.io.axi.read.data.bits.resp.expect(0)

        // Accept response, check that no requests were made after.
        dut.io.axi.read.data.ready.poke(true.B)
        for (i <- 0 until 10) {
          dut.io.axi.read.data.valid.peek()
        }
      }

      resetDut()

      // Write
      {
        dut.io.internal.poke(false.B)
        dut.io.halted.poke(false.B)
        dut.io.fault.poke(false.B)

        // Step once to allow bootAddrCapture to transition to false before we can write to pcStart.
        dut.clock.step()

        // Check initial values.
        dut.io.cg.expect(1)
        dut.io.reset.expect(1)
        dut.io.pcStart.expect(0)

        // Configure write address and write data
        dut.io.axi.write.addr.valid.poke(true.B)
        dut.io.axi.write.addr.bits.addr.poke(0x30004.U)
        dut.io.axi.write.addr.bits.len.poke(0.U)
        dut.io.axi.write.addr.bits.size.poke(2.U)
        dut.io.axi.write.data.bits.data.poke((BigInt(0x20000000) << 32).U)
        dut.io.axi.write.data.bits.strb.poke(0xff00.U)
        dut.io.axi.write.data.bits.last.poke(true.B)
        dut.io.axi.write.data.valid.poke(true.B)

        // Expect readies after both valid signals are poked
        dut.io.axi.write.addr.ready.expect(1)
        dut.io.axi.write.data.ready.expect(1)
        dut.clock.step()
        dut.io.axi.write.addr.valid.poke(false.B)
        dut.io.axi.write.data.valid.poke(false.B)

        // Wait for response
        while (dut.io.axi.write.resp.valid.peek().litValue != 1) {
          dut.clock.step()
        }
        // Check that only pcStartReg changed.
        dut.io.cg.expect(1)
        dut.io.reset.expect(1)
        dut.io.pcStart.expect(0x20000000)

        // Accept write response
        dut.io.axi.write.resp.ready.poke(true.B)
        dut.clock.step()
        dut.io.axi.write.resp.ready.poke(false.B)
        for (i <- 0 until 10) {
          dut.clock.step()
          // Check that only pcStartReg changed.
          dut.io.cg.expect(1)
          dut.io.reset.expect(1)
          dut.io.pcStart.expect(0x20000000)
          dut.io.axi.write.resp.valid.expect(0)
        }

        // Check write result via AXI, as well
        dut.io.axi.read.addr.valid.poke(true.B)
        dut.io.axi.read.addr.bits.addr.poke(0x30004.U)
        dut.io.axi.read.addr.bits.size.poke(2.U)
        dut.io.axi.read.addr.bits.len.poke(0.U)
        while (dut.io.axi.read.addr.ready.peek().litValue != 1) {
          dut.clock.step()
        }
        dut.clock.step()
        dut.io.axi.read.addr.valid.poke(false.B)

        // Wait for read data
        while (dut.io.axi.read.data.valid.peek().litValue != 1) {
          dut.clock.step()
        }
        assert((dut.io.axi.read.data.bits.data.peek().litValue >> 32) == 0x20000000)
        dut.io.axi.read.data.bits.last.expect(1)
        dut.io.axi.read.data.bits.resp.expect(0)

        // Accept read result, no pending read
        dut.io.axi.read.data.ready.poke(true.B)
        dut.clock.step()
        dut.io.axi.read.data.valid.expect(0)
        dut.io.axi.read.data.ready.poke(false.B)
      }

      resetDut()

      // WriteInvalid
      {
        dut.io.internal.poke(false.B)
        dut.io.halted.poke(false.B)
        dut.io.fault.poke(false.B)

        // Step once to allow bootAddrCapture to transition to false before we can write to pcStart.
        dut.clock.step()

        // Check initial values.
        dut.io.cg.expect(1)
        dut.io.reset.expect(1)
        dut.io.pcStart.expect(0)

        // Configure write address and write data
        dut.io.axi.write.addr.valid.poke(true.B)
        dut.io.axi.write.addr.bits.addr.poke(0x30104.U)
        dut.io.axi.write.addr.bits.len.poke(0.U)
        dut.io.axi.write.addr.bits.size.poke(2.U)
        dut.io.axi.write.data.bits.data.poke((BigInt(0x20000000) << 32).U)
        dut.io.axi.write.data.bits.strb.poke(0xff00.U)
        dut.io.axi.write.data.bits.last.poke(true.B)
        dut.io.axi.write.data.valid.poke(true.B)

        // Expect readies after both valid signals are poked
        dut.io.axi.write.addr.ready.expect(1)
        dut.io.axi.write.data.ready.expect(1)
        dut.clock.step()
        dut.io.axi.write.addr.valid.poke(false.B)
        dut.io.axi.write.data.valid.poke(false.B)

        // Wait for response
        while (dut.io.axi.write.resp.valid.peek().litValue != 1) {
          dut.clock.step()
        }
        // Check error was raised in response
        dut.io.axi.write.resp.bits.resp.expect(2)
        // Check that no register changed.
        dut.io.cg.expect(1)
        dut.io.reset.expect(1)
        dut.io.pcStart.expect(0)

        // Accept write response
        dut.io.axi.write.resp.ready.poke(true.B)
        dut.clock.step()
        dut.io.axi.write.resp.ready.poke(false.B)

        // Check that no register changed.
        dut.io.cg.expect(1)
        dut.io.reset.expect(1)
        dut.io.pcStart.expect(0)
      }

      resetDut()

      // Debug CSR request pulse and response dequeue
      {
        def axiWriteWord(addr: Int, value: BigInt): Int = {
          val laneShift = (addr % p.axi2DataBytes) * 8
          val laneStrb  = BigInt(0xf) << (addr % p.axi2DataBytes)
          dut.io.axi.write.addr.valid.poke(true.B)
          dut.io.axi.write.addr.bits.addr.poke(addr.U)
          dut.io.axi.write.addr.bits.len.poke(0.U)
          dut.io.axi.write.addr.bits.size.poke(2.U)
          dut.io.axi.write.data.bits.data.poke((value << laneShift).U)
          dut.io.axi.write.data.bits.strb.poke(laneStrb.U)
          dut.io.axi.write.data.bits.last.poke(true.B)
          dut.io.axi.write.data.valid.poke(true.B)
          dut.clock.step()
          dut.io.axi.write.addr.valid.poke(false.B)
          dut.io.axi.write.data.valid.poke(false.B)
          while (dut.io.axi.write.resp.valid.peek().litValue != 1) {
            dut.clock.step()
          }
          val resp = dut.io.axi.write.resp.bits.resp.peek().litValue.toInt
          dut.io.axi.write.resp.ready.poke(true.B)
          dut.clock.step()
          dut.io.axi.write.resp.ready.poke(false.B)
          resp
        }

        def axiReadWord(addr: Int): BigInt = {
          val laneShift = (addr % p.axi2DataBytes) * 8
          dut.io.axi.read.addr.valid.poke(true.B)
          dut.io.axi.read.addr.bits.addr.poke(addr.U)
          dut.io.axi.read.addr.bits.len.poke(0.U)
          dut.io.axi.read.addr.bits.size.poke(2.U)
          dut.clock.step()
          dut.io.axi.read.addr.valid.poke(false.B)
          while (dut.io.axi.read.data.valid.peek().litValue != 1) {
            dut.clock.step()
          }
          val word = (dut.io.axi.read.data.bits.data.peek().litValue >> laneShift) & 0xffffffffL
          dut.io.axi.read.data.ready.poke(true.B)
          dut.clock.step()
          dut.io.axi.read.data.ready.poke(false.B)
          word
        }

        dut.io.debug.req.ready.poke(true.B)
        assert(axiWriteWord(0x30800, 0x10) == 0)
        assert(axiWriteWord(0x30804, 0x80000001L) == 0)

        // Writing DbgReqOp pulses io.debug.req.valid for one cycle.
        val opShift = (0x30808 % p.axi2DataBytes) * 8
        val opStrb  = BigInt(0xf) << (0x30808 % p.axi2DataBytes)
        dut.io.axi.write.addr.valid.poke(true.B)
        dut.io.axi.write.addr.bits.addr.poke(0x30808.U)
        dut.io.axi.write.addr.bits.len.poke(0.U)
        dut.io.axi.write.addr.bits.size.poke(2.U)
        dut.io.axi.write.data.bits.data.poke((BigInt(2) << opShift).U)
        dut.io.axi.write.data.bits.strb.poke(opStrb.U)
        dut.io.axi.write.data.bits.last.poke(true.B)
        dut.io.axi.write.data.valid.poke(true.B)
        dut.clock.step()
        dut.io.axi.write.addr.valid.poke(false.B)
        dut.io.axi.write.data.valid.poke(false.B)
        dut.io.debug.req.valid.expect(true.B)
        dut.io.debug.req.bits.address.expect(0x10.U)
        dut.io.debug.req.bits.data.expect(0x80000001L.U)
        assert(dut.io.debug.req.bits.op.peekValue().asBigInt == DmReqOp.WRITE.litValue)

        dut.io.axi.write.resp.ready.poke(true.B)
        dut.clock.step()
        dut.io.axi.write.resp.ready.poke(false.B)
        dut.io.debug.req.valid.expect(false.B)

        // Enqueue a debug response and verify DbgStatus/DbgRspData + dequeue on DbgStatus write.
        dut.io.debug.rsp.valid.poke(true.B)
        dut.io.debug.rsp.bits.data.poke(0x12345678L.U)
        dut.io.debug.rsp.bits.op.poke(DmRspOp.SUCCESS)
        dut.clock.step()
        dut.io.debug.rsp.valid.poke(false.B)

        assert(axiReadWord(0x30814) == 3)
        assert(axiReadWord(0x3080c) == 0x12345678L)
        assert(axiWriteWord(0x30814, 0) == 0)
        assert(axiReadWord(0x30814) == 1)

        // Out-of-region write returns SLVERR via router error responder.
        assert(axiWriteWord(0x10004, 0xdeadbeefL) == 2)
      }

      resetDut()

      // Full-beat 128-bit RMW writes (as emitted by Spi2TLULV2)
      {
        def axiWriteFullBeat(
          alignedAddr: Int,
          value128: BigInt,
          mask: Int = 0xffff,
          expectDbgReqValid: Boolean = false
        ): Int = {
          dut.io.axi.write.addr.valid.poke(true.B)
          dut.io.axi.write.addr.bits.addr.poke(alignedAddr.U)
          dut.io.axi.write.addr.bits.len.poke(0.U)
          dut.io.axi.write.addr.bits.size.poke(4.U)
          dut.io.axi.write.data.bits.data.poke(value128.U)
          dut.io.axi.write.data.bits.strb.poke(mask.U)
          dut.io.axi.write.data.bits.last.poke(true.B)
          dut.io.axi.write.data.valid.poke(true.B)
          dut.clock.step()
          dut.io.axi.write.addr.valid.poke(false.B)
          dut.io.axi.write.data.valid.poke(false.B)
          while (dut.io.axi.write.resp.valid.peek().litValue != 1) {
            dut.clock.step()
          }
          dut.io.debug.req.valid.expect(expectDbgReqValid.B)
          val resp = dut.io.axi.write.resp.bits.resp.peek().litValue.toInt
          dut.io.axi.write.resp.ready.poke(true.B)
          dut.clock.step()
          dut.io.axi.write.resp.ready.poke(false.B)
          dut.io.debug.req.valid.expect(false.B)
          resp
        }

        def axiReadFullBeat(addr: Int): (Int, BigInt) = {
          dut.io.axi.read.addr.valid.poke(true.B)
          dut.io.axi.read.addr.bits.addr.poke(addr.U)
          dut.io.axi.read.addr.bits.len.poke(0.U)
          dut.io.axi.read.addr.bits.size.poke(4.U)
          dut.clock.step()
          dut.io.axi.read.addr.valid.poke(false.B)
          while (dut.io.axi.read.data.valid.peek().litValue != 1) {
            dut.clock.step()
          }
          val resp = dut.io.axi.read.data.bits.resp.peek().litValue.toInt
          val data = dut.io.axi.read.data.bits.data.peek().litValue
          dut.io.axi.read.data.ready.poke(true.B)
          dut.clock.step()
          dut.io.axi.read.data.ready.poke(false.B)
          (resp, data)
        }

        def axiReadFullBeatResp(addr: Int): Int = axiReadFullBeat(addr)._1

        def axiRmwWord(
          addr: Int,
          wordVal: BigInt,
          expectDbgReqValid: Boolean = false
        ): Int = {
          val alignedAddr       = addr & ~0xf
          val bitShift          = (addr & 0xf) * 8
          val wordMask          = BigInt(0xffffffffL) << bitShift
          val (rResp, lineData) = axiReadFullBeat(alignedAddr)
          assert(rResp == 0)
          val patched = (lineData & ~wordMask) | ((wordVal & 0xffffffffL) << bitShift)
          axiWriteFullBeat(alignedAddr, patched, expectDbgReqValid = expectDbgReqValid)
        }

        // Step once so bootAddrCapture clears.
        dut.clock.step()
        dut.io.cg.expect(1)
        dut.io.reset.expect(1)
        dut.io.pcStart.expect(0)

        // 16-byte RMW beat to 0x30000: preserve resetReg=3 in [31:0], set pcStartReg=0x20000000 in [63:32].
        val csrBeat = (BigInt(0x20000000L) << 32) | BigInt(0x3)
        assert(axiWriteFullBeat(0x30000, csrBeat) == 0)
        dut.io.cg.expect(1)
        dut.io.reset.expect(1)
        dut.io.pcStart.expect(0x20000000)

        // Release clock gate then reset via full-beat RMW without clobbering pcStartReg.
        assert(axiWriteFullBeat(0x30000, (BigInt(0x20000000L) << 32) | BigInt(0x1)) == 0)
        dut.io.cg.expect(0)
        dut.io.reset.expect(1)
        dut.io.pcStart.expect(0x20000000)

        assert(axiWriteFullBeat(0x30000, (BigInt(0x20000000L) << 32) | BigInt(0x0)) == 0)
        dut.io.cg.expect(0)
        dut.io.reset.expect(0)
        dut.io.pcStart.expect(0x20000000)

        // Full-beat RMW to debug line 0x30800 with DbgReqOp=NOP must update addr/data without pulsing req.valid.
        dut.io.debug.req.ready.poke(true.B)
        assert(axiRmwWord(0x30800, 0x20, expectDbgReqValid = false) == 0)
        assert(axiRmwWord(0x30804, 0xcafebabeL, expectDbgReqValid = false) == 0)
        dut.io.debug.req.bits.address.expect(0x20.U)
        dut.io.debug.req.bits.data.expect(0xcafebabeL.U)

        // Full-beat RMW to 0x30808 with DbgReqOp=WRITE (2) pulses io.debug.req.valid for one cycle.
        assert(axiRmwWord(0x30808, 2, expectDbgReqValid = true) == 0)

        // Enqueue a debug response and verify RMW handling on line 0x30810 (DbgRspOp + DbgStatus).
        dut.io.debug.rsp.valid.poke(true.B)
        dut.io.debug.rsp.bits.data.poke(0xdeadc0deL.U)
        dut.io.debug.rsp.bits.op.poke(DmRspOp.SUCCESS)
        dut.clock.step()
        dut.io.debug.rsp.valid.poke(false.B)

        val (statusResp0, statusLine0) = axiReadFullBeat(0x30810)
        assert(statusResp0 == 0)
        assert(((statusLine0 >> 32) & 0xffffffffL) == 3)

        // RMW beat to 0x30810 preserving non-zero DbgStatus must not dequeue rsp_queue.
        assert(axiWriteFullBeat(0x30810, statusLine0) == 0)
        val (_, statusLine1) = axiReadFullBeat(0x30810)
        assert(((statusLine1 >> 32) & 0xffffffffL) == 3)

        // RMW write of 0 to DbgStatus (0x30814) dequeues rsp_queue.
        assert(axiRmwWord(0x30814, 0) == 0)
        val (_, statusLine2) = axiReadFullBeat(0x30810)
        assert(((statusLine2 >> 32) & 0xffffffffL) == 1)

        // Second back-to-back debug operation via RMW: updating DbgReqAddr and DbgReqData
        // must not re-trigger the previous DbgReqOp.
        assert(axiRmwWord(0x30800, 0x24, expectDbgReqValid = false) == 0)
        dut.io.debug.req.bits.address.expect(0x24.U)
        assert(axiRmwWord(0x30804, 0x11223344L, expectDbgReqValid = false) == 0)
        dut.io.debug.req.bits.data.expect(0x11223344L.U)
        assert(axiRmwWord(0x30808, 1, expectDbgReqValid = true) == 0)

        // Full-beat write to read-only internal CSR line (0x30100) returns SLVERR.
        assert(axiWriteFullBeat(0x30100, BigInt(0x12345678L)) == 2)

        // Full-beat write with full strobes to unaligned or unmapped offsets returns SLVERR.
        assert(axiWriteFullBeat(0x30004, csrBeat) == 2)
        assert(axiWriteFullBeat(0x3000c, csrBeat) == 2)
        assert(axiWriteFullBeat(0x30010, csrBeat) == 2)
        assert(axiWriteFullBeat(0x30818, BigInt(0)) == 2)

        // Bus-sized partial writes with word-aligned sub-line addresses and masked lower lanes
        // succeed (matching SystemC tlm2axi-bridge transactions in core_mini_axi_sim).
        assert(axiWriteFullBeat(0x30000, BigInt(0x3), mask = 0x000f) == 0)
        dut.io.cg.expect(1)
        dut.io.reset.expect(1)
        assert(axiWriteFullBeat(0x30004, BigInt(0x12340000L) << 32, mask = 0x00f0) == 0)
        dut.io.cg.expect(1)
        dut.io.reset.expect(1)
        dut.io.pcStart.expect(0x12340000L)
        assert(axiWriteFullBeat(0x30000, BigInt(0x0), mask = 0x000f) == 0)
        dut.io.cg.expect(0)
        dut.io.reset.expect(0)
        dut.io.pcStart.expect(0x12340000L)

        // Bus-sized partial writes to debug CSRs at sub-line offsets update single lanes cleanly.
        assert(axiWriteFullBeat(0x30804, BigInt(0x55aa55aaL) << 32, mask = 0x00f0) == 0)
        dut.io.debug.req.bits.address.expect(0x24.U)
        dut.io.debug.req.bits.data.expect(0x55aa55aaL.U)
        assert(
          axiWriteFullBeat(
            0x30808,
            BigInt(2) << 64,
            mask = 0x0f00,
            expectDbgReqValid = true
          ) == 0
        )

        dut.io.debug.rsp.valid.poke(true.B)
        dut.io.debug.rsp.bits.data.poke(0xfeedfaceL.U)
        dut.io.debug.rsp.bits.op.poke(DmRspOp.SUCCESS)
        dut.clock.step()
        dut.io.debug.rsp.valid.poke(false.B)
        assert(((axiReadFullBeat(0x30810)._2 >> 32) & 0xffffffffL) == 3)
        // Single-lane partial write of non-zero value to DbgStatus still dequeues rsp_queue.
        assert(axiWriteFullBeat(0x30814, BigInt(1) << 32, mask = 0x00f0) == 0)
        assert(((axiReadFullBeat(0x30810)._2 >> 32) & 0xffffffffL) == 1)

        // Bus-sized partial writes targeting read-only or unmapped sub-line offsets return SLVERR.
        assert(axiWriteFullBeat(0x30008, BigInt(0xffffffffL) << 64, mask = 0x0f00) == 2)
        assert(axiWriteFullBeat(0x3000c, BigInt(0xffffffffL) << 96, mask = 0xf000) == 2)
        assert(axiWriteFullBeat(0x30005, BigInt(0xab) << 40, mask = 0x0020) == 2)
        dut.io.pcStart.expect(0x12340000L)

        // Full-beat write masking only read-only/unmapped lanes (0x30008/0x3000c) returns SLVERR
        // without disturbing resetReg or pcStartReg.
        assert(axiWriteFullBeat(0x30000, BigInt(0xffffffffL) << 64, mask = 0xff00) == 2)
        dut.io.cg.expect(0)
        dut.io.reset.expect(0)
        dut.io.pcStart.expect(0x12340000L)

        // Full-width reads (arsize=4, as issued by CoreMiniAxiInterface.read_word and Spi2TLULV2)
        // return OKAY on valid CSR offsets and SLVERR on invalid offsets even within valid lines.
        assert(axiReadFullBeatResp(0x30000) == 0)
        assert(axiReadFullBeatResp(0x30004) == 0)
        assert(axiReadFullBeatResp(0x30008) == 0)
        assert(axiReadFullBeatResp(0x30800) == 0)
        assert(axiReadFullBeatResp(0x30810) == 0)
        assert(axiReadFullBeatResp(0x30814) == 0)
        assert(axiReadFullBeatResp(0x3000c) == 2)
        assert(axiReadFullBeatResp(0x30010) == 2)
        assert(axiReadFullBeatResp(0x30818) == 2)
        assert(axiReadFullBeatResp(0x3081c) == 2)
      }
    }
  }

  "CoreTlulAxiCSR 256-bit" in {
    val p256 = new Parameters
    p256.lsuDataBits = 256
    p256.m = MemoryRegions.default

    simulate(new CoreTlulAxiCSR(p256)) { dut =>
      dut.reset.poke(true.B)
      dut.clock.step()
      dut.reset.poke(false.B)
      dut.io.internal.poke(false.B)
      dut.io.halted.poke(false.B)
      dut.io.fault.poke(false.B)
      dut.io.axi.read.addr.valid.poke(false.B)
      dut.io.axi.read.data.ready.poke(false.B)
      dut.io.axi.write.addr.valid.poke(false.B)
      dut.io.axi.write.data.valid.poke(false.B)
      dut.io.axi.write.resp.ready.poke(false.B)
      dut.io.debug.req.ready.poke(true.B)
      dut.io.debug.rsp.valid.poke(false.B)
      dut.clock.step()

      def axiWriteBeat256(
        addr: Int,
        value256: BigInt,
        mask: Long = 0xffffffffL,
        expectDbgReqValid: Boolean = false
      ): Int = {
        dut.io.axi.write.addr.valid.poke(true.B)
        dut.io.axi.write.addr.bits.addr.poke(addr.U)
        dut.io.axi.write.addr.bits.len.poke(0.U)
        dut.io.axi.write.addr.bits.size.poke(5.U)
        dut.io.axi.write.data.bits.data.poke(value256.U)
        dut.io.axi.write.data.bits.strb.poke(BigInt(mask).U)
        dut.io.axi.write.data.bits.last.poke(true.B)
        dut.io.axi.write.data.valid.poke(true.B)
        dut.clock.step()
        dut.io.axi.write.addr.valid.poke(false.B)
        dut.io.axi.write.data.valid.poke(false.B)
        while (dut.io.axi.write.resp.valid.peek().litValue != 1) {
          dut.clock.step()
        }
        dut.io.debug.req.valid.expect(expectDbgReqValid.B)
        val resp = dut.io.axi.write.resp.bits.resp.peek().litValue.toInt
        dut.io.axi.write.resp.ready.poke(true.B)
        dut.clock.step()
        dut.io.axi.write.resp.ready.poke(false.B)
        resp
      }

      def axiReadBeat256(addr: Int): (Int, BigInt) = {
        dut.io.axi.read.addr.valid.poke(true.B)
        dut.io.axi.read.addr.bits.addr.poke(addr.U)
        dut.io.axi.read.addr.bits.len.poke(0.U)
        dut.io.axi.read.addr.bits.size.poke(5.U)
        dut.clock.step()
        dut.io.axi.read.addr.valid.poke(false.B)
        while (dut.io.axi.read.data.valid.peek().litValue != 1) {
          dut.clock.step()
        }
        val resp = dut.io.axi.read.data.bits.resp.peek().litValue.toInt
        val data = dut.io.axi.read.data.bits.data.peek().litValue
        dut.io.axi.read.data.ready.poke(true.B)
        dut.clock.step()
        dut.io.axi.read.data.ready.poke(false.B)
        (resp, data)
      }

      // Bus-sized partial write to 0x30004 (lanes 4..7) updates pcStart without disturbing reset.
      assert(axiWriteBeat256(0x30004, BigInt(0x20000000L) << 32, mask = 0x000000f0L) == 0)
      dut.io.cg.expect(1)
      dut.io.reset.expect(1)
      dut.io.pcStart.expect(0x20000000L)

      // In 256-bit mode, 0x800..0x814 share one 32-byte line. Updating DbgReqAddr via RMW
      // while DbgStatus is 3 must neither pulse req.valid nor dequeue rsp_queue.
      dut.io.debug.rsp.valid.poke(true.B)
      dut.io.debug.rsp.bits.data.poke(0xabcd1234L.U)
      dut.io.debug.rsp.bits.op.poke(DmRspOp.SUCCESS)
      dut.clock.step()
      dut.io.debug.rsp.valid.poke(false.B)

      val (r0, line0) = axiReadBeat256(0x30800)
      assert(r0 == 0)
      assert(((line0 >> (20 * 8)) & 0xffffffffL) == 3)

      val patchedAddr = (line0 & ~BigInt(0xffffffffL)) | BigInt(0x40)
      assert(axiWriteBeat256(0x30800, patchedAddr, expectDbgReqValid = false) == 0)
      dut.io.debug.req.bits.address.expect(0x40.U)
      assert(((axiReadBeat256(0x30800)._2 >> (20 * 8)) & 0xffffffffL) == 3)

      // Clearing DbgStatus (offset 20, bits [191:160]) via 32-byte RMW dequeues rsp_queue.
      val clearedStatus = patchedAddr & ~(BigInt(0xffffffffL) << (20 * 8))
      assert(axiWriteBeat256(0x30800, clearedStatus, expectDbgReqValid = false) == 0)
      assert(((axiReadBeat256(0x30800)._2 >> (20 * 8)) & 0xffffffffL) == 1)
    }
  }
}

class CoreAxiInstructionFetchSpec extends AnyFreeSpec with ChiselSim {
  "CoreAxi parameters verify enableAxiInstructionFetch" in {
    val pTrue = new Parameters
    assert(pTrue.enableAxiInstructionFetch == true)

    val pFalse = new Parameters
    pFalse.enableAxiInstructionFetch = false
    assert(pFalse.enableAxiInstructionFetch == false)

    val pAugment = pFalse.augmentId(2)
    assert(pAugment.enableAxiInstructionFetch == false)

    val headerTrue = EmitParametersHeader(pTrue)
    assert(headerTrue.contains("#define KP_enableAxiInstructionFetch  true"))

    val headerFalse = EmitParametersHeader(pFalse)
    assert(headerFalse.contains("#define KP_enableAxiInstructionFetch  false"))
  }

  "CoreAxi elaborates with enableAxiInstructionFetch false" in {
    val pFalse = new Parameters
    pFalse.m = MemoryRegions.default
    pFalse.lsuDataBits = 128
    pFalse.fetchDataBits = 128
    pFalse.enableAxiInstructionFetch = false
    val sv = _root_.circt.stage.ChiselStage.emitSystemVerilog(new CoreAxi(pFalse, "CoreAxiNoIbus"))
    assert(!sv.contains("io_hosts_2_"))
  }

  "CoreAxi elaborates with enableAxiInstructionFetch true" in {
    val pTrue = new Parameters
    pTrue.m = MemoryRegions.default
    pTrue.lsuDataBits = 128
    pTrue.fetchDataBits = 128
    pTrue.enableAxiInstructionFetch = true
    val sv = _root_.circt.stage.ChiselStage.emitSystemVerilog(new CoreAxi(pTrue, "CoreAxiWithIbus"))
    assert(sv.contains("io_hosts_2_"))
  }
}

class CoreDomainTlulBridgeSpec extends AnyFreeSpec with ChiselSim {
  val tlParams = new TLULParameters(dataBits = 128, addrBits = 32, idBits = 6)

  "CoreDomainTlulBridge isolates gated clock and drains orphaned soft-reset responses" in {
    simulate(new CoreDomainTlulBridge(tlParams, maxOutstanding = 2, dQueueEntries = 2)) { dut =>
      dut.reset.poke(true.B)
      dut.io.coreClkEn.poke(true.B)
      dut.io.coreReset.poke(false.B)
      dut.io.tl_h.a.valid.poke(false.B)
      dut.io.tl_h.a.bits.opcode.poke(TLULOpcodesA.Get.asUInt)
      dut.io.tl_h.a.bits.param.poke(0.U)
      dut.io.tl_h.a.bits.size.poke(4.U)
      dut.io.tl_h.a.bits.source.poke(0.U)
      dut.io.tl_h.a.bits.address.poke(0.U)
      dut.io.tl_h.a.bits.mask.poke(0xffff.U)
      dut.io.tl_h.a.bits.data.poke(0.U)
      dut.io.tl_h.d.ready.poke(true.B)
      dut.io.tl_d.a.ready.poke(true.B)
      dut.io.tl_d.d.valid.poke(false.B)
      dut.io.tl_d.d.bits.opcode.poke(TLULOpcodesD.AccessAckData.asUInt)
      dut.io.tl_d.d.bits.param.poke(0.U)
      dut.io.tl_d.d.bits.size.poke(4.U)
      dut.io.tl_d.d.bits.source.poke(0.U)
      dut.io.tl_d.d.bits.sink.poke(0.U)
      dut.io.tl_d.d.bits.data.poke(0.U)
      dut.io.tl_d.d.bits.error.poke(false.B)
      dut.clock.step()
      dut.reset.poke(false.B)

      // 1. Issue request (source = 0) on active clock edge just before WFI clock gating.
      dut.io.tl_h.a.valid.poke(true.B)
      dut.io.tl_h.a.bits.source.poke(0.U)
      dut.io.tl_d.a.valid.expect(true.B)
      dut.io.tl_h.a.ready.expect(true.B)
      dut.clock.step()

      // 2. Clock gate asserts while core still holds speculative a.valid (source = 1) high.
      // Fabric must NOT accept duplicate requests while gated, and returning response for
      // source = 0 must be buffered without stalling tl_d.d.ready.
      dut.io.coreClkEn.poke(false.B)
      dut.io.tl_h.a.bits.source.poke(1.U)
      dut.io.tl_d.a.valid.expect(false.B)
      dut.io.tl_h.a.ready.expect(false.B)

      dut.io.tl_d.d.valid.poke(true.B)
      dut.io.tl_d.d.bits.source.poke(0.U)
      dut.io.tl_d.d.bits.data.poke(0x11223344L.U)
      dut.io.tl_d.d.ready.expect(true.B)
      dut.io.tl_h.d.valid.expect(false.B)
      dut.clock.step()

      // Keep gated for extra cycles: buffered response stays held cleanly.
      dut.io.tl_d.d.valid.poke(false.B)
      dut.clock.step()
      dut.io.tl_h.d.valid.expect(false.B)
      dut.io.tl_d.a.valid.expect(false.B)

      // 3. Ungate clock: buffered response (source = 0) delivers immediately to core.
      dut.io.coreClkEn.poke(true.B)
      dut.io.tl_h.a.valid.poke(false.B)
      dut.io.tl_h.d.valid.expect(true.B)
      dut.io.tl_h.d.bits.source.expect(0.U)
      dut.io.tl_h.d.bits.data.expect(0x11223344L.U)
      dut.clock.step()
      dut.io.tl_h.d.valid.expect(false.B)

      // 4. Issue 2 requests (source = 0, 1), buffer one during clock-gate, then pulse coreReset.
      dut.io.tl_h.a.valid.poke(true.B)
      dut.io.tl_h.a.bits.source.poke(0.U)
      dut.clock.step()
      dut.io.tl_h.a.bits.source.poke(1.U)
      dut.clock.step()
      dut.io.tl_h.a.valid.poke(false.B)

      // Buffer response 0 while gated.
      dut.io.coreClkEn.poke(false.B)
      dut.io.tl_d.d.valid.poke(true.B)
      dut.io.tl_d.d.bits.source.poke(0.U)
      dut.io.tl_d.d.bits.data.poke(0xaaaaL.U)
      dut.clock.step()
      dut.io.tl_d.d.valid.poke(false.B)

      // Pulse soft reset for 1 cycle while response 1 is still in flight in fabric.
      dut.io.coreReset.poke(true.B)
      dut.clock.step()
      dut.io.coreReset.poke(false.B)
      dut.io.coreClkEn.poke(true.B)

      // Buffered response 0 must have been flushed, and new post-reset Channel A requests
      // must remain blocked until orphaned response 1 drains from fabric.
      dut.io.tl_h.d.valid.expect(false.B)
      dut.io.tl_h.a.valid.poke(true.B)
      dut.io.tl_h.a.bits.source.poke(0.U)
      dut.io.tl_h.a.ready.expect(false.B)
      dut.io.tl_d.a.valid.expect(false.B)

      // Orphaned response 1 arrives and is silently drained.
      dut.io.tl_d.d.valid.poke(true.B)
      dut.io.tl_d.d.bits.source.poke(1.U)
      dut.io.tl_d.d.bits.data.poke(0xbbbbL.U)
      dut.io.tl_d.d.ready.expect(true.B)
      dut.io.tl_h.d.valid.expect(false.B)
      dut.clock.step()
      dut.io.tl_d.d.valid.poke(false.B)

      // Now fabric is clean: post-reset Channel A request is accepted immediately.
      dut.io.tl_h.a.ready.expect(true.B)
      dut.io.tl_d.a.valid.expect(true.B)
    }
  }
}
