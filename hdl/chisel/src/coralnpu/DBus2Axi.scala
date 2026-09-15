// Copyright 2023 Google LLC
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

import bus.{AxiMasterIO, AxiResponseType, AxiWriteData}
import common._

object DBus2Axi {
  def apply(p: Parameters, id: Int = 0): DBus2Axi = {
    return Module(new DBus2AxiV2(p, id))
  }
}

class ReadCtrl(p: Parameters) extends Bundle {
  val addr = UInt(p.axi2AddrBits.W)
  val size = UInt(p.axi2DataBits.W)
  val pc   = UInt(p.programCounterBits.W)
}

class WriteCtrl(p: Parameters) extends Bundle {
  val addr = UInt(p.axi2AddrBits.W)
  val pc   = UInt(p.programCounterBits.W)
}

class DBus2Axi(p: Parameters) extends Module {
  val io = IO(new Bundle {
    val dbus  = Flipped(new DBusIO(p))
    val axi   = new AxiMasterIO(p.axi2AddrBits, p.axi2DataBits, p.axi2IdBits)
    val fault = Valid(new FaultInfo(p))
  })
}

class DBus2AxiV2(p: Parameters, id: Int = 0) extends DBus2Axi(p) {
  assert(!(io.dbus.valid && PopCount(io.dbus.size) =/= 1.U), cf"Invalid dbus size=${io.dbus.size}")

  // ---------------------------------------------------------------------------
  // Write Path
  val waddrFired = RegInit(false.B)
  io.axi.write.addr.valid := !waddrFired && io.dbus.valid && io.dbus.write
  io.axi.write.addr.bits.defaults()
  io.axi.write.addr.bits.addr := io.dbus.addr
  io.axi.write.addr.bits.size := Ctz(io.dbus.size)
  io.axi.write.addr.bits.prot := 2.U
  io.axi.write.addr.bits.id   := id.U

  val wdataFired = RegInit(false.B)
  val wdataQueue = Module(new Queue(new AxiWriteData(p.axi2DataBits, p.axi2IdBits), 2))
  wdataQueue.io.enq.valid     := !wdataFired && io.dbus.valid && io.dbus.write
  wdataQueue.io.enq.bits.data := io.dbus.wdata
  wdataQueue.io.enq.bits.strb := io.dbus.wmask
  wdataQueue.io.enq.bits.last := true.B
  io.axi.write.data <> wdataQueue.io.deq

  val wrespReceived = RegInit(false.B)
  io.axi.write.resp.ready := !wrespReceived && io.dbus.valid && io.dbus.write

  val writeFinished = (io.axi.write.addr.fire || waddrFired) &&
    (wdataQueue.io.enq.fire || wdataFired) &&
    (io.axi.write.resp.fire || wrespReceived)
  waddrFired := MuxCase(
    waddrFired,
    Seq(
      writeFinished          -> false.B,
      io.axi.write.addr.fire -> true.B
    )
  )
  wdataFired := MuxCase(
    wdataFired,
    Seq(
      writeFinished          -> false.B,
      wdataQueue.io.enq.fire -> true.B
    )
  )
  wrespReceived := MuxCase(
    wrespReceived,
    Seq(
      writeFinished          -> false.B,
      io.axi.write.resp.fire -> true.B
    )
  )

  // ---------------------------------------------------------------------------
  // Read Path
  val raddrFired = RegInit(false.B)
  io.axi.read.addr.valid := !raddrFired && io.dbus.valid && !io.dbus.write
  io.axi.read.addr.bits.defaults()
  io.axi.read.addr.bits.addr := io.dbus.addr
  io.axi.read.addr.bits.size := Ctz(io.dbus.size)
  io.axi.read.addr.bits.prot := 2.U
  io.axi.read.addr.bits.id   := id.U

  val rdataReceived = RegInit(MakeInvalid(UInt(p.axi2DataBits.W)))
  io.axi.read.data.ready :=
    !rdataReceived.valid && io.dbus.valid && !io.dbus.write

  val readFinished = (io.axi.read.addr.fire || raddrFired) &&
    (io.axi.read.data.fire || rdataReceived.valid)
  raddrFired := MuxCase(
    raddrFired,
    Seq(
      readFinished          -> false.B,
      io.axi.read.addr.fire -> true.B
    )
  )
  rdataReceived := MuxCase(
    rdataReceived,
    Seq(
      readFinished          -> MakeInvalid(UInt(p.axi2DataBits.W)),
      io.axi.read.data.fire -> MakeValid(true.B, io.axi.read.data.bits.data)
    )
  )
  // Insert delay register to match dbus interface expecations, changing on
  // fire.
  val readNext = RegInit(0.U(p.axi2DataBits.W))
  readNext := Mux(
    readFinished,
    Mux(io.axi.read.data.fire, io.axi.read.data.bits.data, rdataReceived.bits),
    readNext
  )
  io.dbus.rdata := readNext

  // ---------------------------------------------------------------------------
  // DBus Response
  io.dbus.ready := Mux(io.dbus.write, writeFinished, readFinished)

  // ---------------------------------------------------------------------------
  // Fault Handling
  io.fault.valid := io.dbus.valid && Mux(
    io.dbus.write,
    io.axi.write.resp.valid && (io.axi.write.resp.bits.resp =/= AxiResponseType.OKAY.asUInt),
    // TODO(derekjchow): Does read resp come in last? If not, wait until
    // transaction is totally complete before returning error.
    io.axi.read.data.valid && (io.axi.read.data.bits.resp =/= AxiResponseType.OKAY.asUInt)
  )
  io.fault.bits.write := io.dbus.write
  // TODO(derekjchow): Make sure this targets the actual address instead of
  // line address (to report a more accurate exception).
  io.fault.bits.addr := io.dbus.addr
  io.fault.bits.epc  := io.dbus.pc
}

object EmitDBus2Axi extends App {
  val p = new Parameters
  ChiselEmitter.emit(new DBus2AxiV2(p), args)
}
