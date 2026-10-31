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
import chisel3.util._
import chisel3.simulator.scalatest.ChiselSim
import org.scalatest.freespec.AnyFreeSpec

private class LsuCellProbe(p: Parameters) extends Module {
  val io = IO(new Bundle {
    val row         = Input(UInt(p.dbusRowAddrBits.W))
    val offset      = Input(UInt(p.dbusOffsetBits.W))
    val byteValid   = Input(Bool())
    val index       = Input(UInt(p.lsuAddrBits.W))
    val indexValid  = Input(Bool())
    val oldData     = Input(UInt(8.W))
    val initValid   = Input(Bool())
    val initByte    = Input(UInt(8.W))
    val respValid   = Input(Bool())
    val respBytes   = Input(Vec(p.lsuDataBytes, UInt(8.W)))
    val decodedMask = Output(UInt(p.lsuDataBytes.W))
    val nextRow     = Output(UInt(p.dbusRowAddrBits.W))
    val nextMask    = Output(UInt(p.lsuDataBytes.W))
    val nextData    = Output(UInt(8.W))
  })

  val cell = Wire(new LsuCell(p))
  cell.state      := Mux(io.initValid, LsuCellState.DONE, LsuCellState.W_RESP)
  cell.data       := io.oldData
  cell.rowAddr    := io.row
  cell.byteOffset := io.offset
  cell.byteValid  := io.byteValid
  // Use the actual index-update and response-selection implementations.
  val index = Wire(Valid(UInt(p.lsuAddrBits.W)))
  index.valid := io.indexValid
  index.bits  := io.index
  val updated = cell.applyVectorIndex(Some(index))
  io.decodedMask := cell.mask
  io.nextRow     := updated.rowAddr
  io.nextMask    := updated.mask

  val init = Wire(Valid(UInt(8.W)))
  init.valid := io.initValid
  init.bits  := io.initByte
  val resp = Wire(Valid(Vec(p.lsuDataBytes, UInt(8.W))))
  resp.valid := io.respValid
  resp.bits  := io.respBytes
  io.nextData := cell.next(
    write = false.B,
    initData = init,
    vectorIndex = None,
    vectorData = None,
    vectorMask = None,
    start = false.B,
    respData = resp,
    wb = false.B
  ).data
}

// Run the exhaustive combinations inside RTL so the host need not exchange
// hundreds of thousands of individual poke/peek messages with the simulator.
private class LsuCellSweep(p: Parameters) extends Module {
  val io = IO(new Bundle {
    val done = Output(Bool())
  })
  val bytes = p.lsuDataBytes
  val w = p.dbusOffsetBits
  val addressCases = bytes * bytes * 8
  val total = addressCases + bytes + 2
  val count = RegInit(0.U(log2Ceil(total + 1).W))
  io.done := count === total.U
  when(!io.done) { count := count + 1.U }

  val addressPhase = count < addressCases.U
  val responsePhase = count >= addressCases.U && count < (addressCases + bytes).U
  val invalidResponse = count === (addressCases + bytes).U
  val initPhase = count === (addressCases + bytes + 1).U
  val offset = Mux(addressPhase, count(w - 1, 0), (count - addressCases.U)(w - 1, 0))
  val shift = count(2 * w - 1, w)
  val valid = Mux(addressPhase, count(2 * w), responsePhase)
  val enabled = addressPhase && count(2 * w + 1)
  val row = Mux(count(2 * w + 2), ((BigInt(1) << p.dbusRowAddrBits) - 1).U, 0.U)
  val probe = Module(new LsuCellProbe(p))
  probe.io.row := row
  probe.io.offset := offset
  probe.io.byteValid := valid
  probe.io.index := (bytes * 3).U + shift
  probe.io.indexValid := enabled
  probe.io.oldData := 0xa5.U
  probe.io.initValid := initPhase
  probe.io.initByte := 0x5a.U
  probe.io.respValid := responsePhase || invalidResponse
  val response = VecInit.tabulate(bytes)(i => ((i * 37 + 11) & 255).U(8.W))
  probe.io.respBytes := response

  // Reference the previous one-hot representation and rotation/carry formula.
  val oldMask = Mux(valid, UIntToOH(offset, bytes), 0.U(bytes.W))
  val rotated = (oldMask << shift)(bytes - 1, 0) | (oldMask >> (bytes.U - shift))
  val carryMask = (~(Fill(bytes, 1.U(1.W)) >> shift))(bytes - 1, 1)
  val carry = (oldMask(bytes - 1, 1) & carryMask).orR
  val nextRow = (row +& 3.U +& carry)(p.dbusRowAddrBits - 1, 0)
  when(addressPhase) {
    assert(probe.io.decodedMask === oldMask)
    assert(probe.io.nextMask === Mux(enabled, rotated, oldMask))
    assert(probe.io.nextRow === Mux(enabled, nextRow, row))
    assert(probe.io.nextData === 0xa5.U)
  }
  when(responsePhase) { assert(probe.io.nextData === response(offset)) }
  when(invalidResponse) { assert(probe.io.nextData === 0.U) }
  when(initPhase) { assert(probe.io.nextData === 0x5a.U) }
}

class LsuCellSpec extends AnyFreeSpec with ChiselSim {
  for (busBytes <- Seq(4, 8, 16, 32, 64)) {
    s"encoded cell preserves address, mask, and byte selection on a $busBytes-byte bus" in {
      val p = new Parameters
      p.enableRvv = true
      p.lsuDataBits = busBytes * 8
      simulate(new LsuCellSweep(p)) { dut =>
        dut.clock.step(busBytes * busBytes * 8 + busBytes + 3)
        dut.io.done.expect(1)
      }
    }
  }
}
