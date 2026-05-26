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

import chisel3._
import chisel3.util._

import common._

class SRAMIO(p: Parameters, sramAddressWidth: Int) extends Bundle {
  val address = Output(UInt(sramAddressWidth.W))
  val enable = Output(Bool())
  val isWrite = Output(Bool())
  val readData = Input(Vec(p.axi2DataBits / 8, UInt(8.W)))
  val writeData = Output(Vec(p.axi2DataBits / 8, UInt(8.W)))
  val mask = Output(Vec(p.axi2DataBits / 8, Bool()))
}

class SRAM(p: Parameters, sramAddressWidth: Int) extends Module {
  val io = IO(new Bundle{
    val fabric = Flipped(new FabricIO(p))
    val sram = new SRAMIO(p, sramAddressWidth)
  })

  val lsb = log2Ceil(p.axi2DataBits / 8)
  io.sram.address := MuxUpTo1H(0.U, Seq(
    io.fabric.writeDataAddr.valid -> io.fabric.writeDataAddr.bits(sramAddressWidth + lsb - 1, lsb),
    io.fabric.readDataAddr.valid -> io.fabric.readDataAddr.bits(sramAddressWidth + lsb - 1, lsb)
  ))

  val readData = Cat(io.sram.readData)
  val readIssued = RegInit(false.B)
  val issueRead = io.fabric.readDataAddr.valid && !io.fabric.writeDataAddr.valid
  readIssued := issueRead
  io.fabric.readData.bits := Mux(readIssued, readData, 0.U)
  io.fabric.readData.valid := readIssued

  io.sram.enable := (io.fabric.readDataAddr.valid || io.fabric.writeDataAddr.valid)
  io.sram.isWrite := io.fabric.writeDataAddr.valid
  val writeDataVec = UIntToVec(io.fabric.writeDataBits, 8)
  val writeMaskData = VecInit(io.fabric.writeDataStrb.asBools)
  io.sram.writeData := Mux(io.fabric.writeDataAddr.valid, writeDataVec, 0.U.asTypeOf(writeDataVec))
  val readMaskData = RegInit(VecInit(Seq.fill(io.fabric.writeDataBits.getWidth / 8)(true.B)))
  val maskData = Mux(io.fabric.writeDataAddr.valid, writeMaskData, readMaskData)
  io.sram.mask := maskData
  io.fabric.writeResp := true.B
}
