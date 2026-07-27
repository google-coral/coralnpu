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

package bus

import chisel3._
import chisel3.util._

object AxiResponseType extends ChiselEnum {
  val OKAY   = Value(0.U(2.W))
  val EXOKAY = Value(1.U(2.W))
  val SLVERR = Value(2.U(2.W))
  val DECERR = Value(3.U(2.W))
}

object AxiBurstType extends ChiselEnum {
  val FIXED = Value(0.U)
  val INCR  = Value(1.U)
  val WRAP  = Value(2.U)
}

// ARM IHI 0022E, A2.2 / A2.5
class AxiAddress(addrWidthBits: Int, dataWidthBits: Int, idBits: Int) extends Bundle {
  // "Required"
  val addr = UInt(addrWidthBits.W)
  val prot = UInt(3.W)
  // "Optional"
  val id     = UInt(idBits.W)
  val len    = UInt(8.W)
  val size   = UInt(3.W)
  val burst  = UInt(2.W)
  val lock   = UInt(1.W)
  val cache  = UInt(4.W)
  val qos    = UInt(4.W)
  val region = UInt(4.W)

  def nextAddr(): AxiAddress = {
    val next = Wire(new AxiAddress(addrWidthBits, dataWidthBits, idBits))
    next      := this
    next.addr := MuxLookup(this.burst, this.addr)(
      Seq(
        AxiBurstType.FIXED.asUInt -> this.addr,
        AxiBurstType.INCR.asUInt  -> (this.addr + (1.U << this.size))
      )
    )
    next.len := this.len - 1.U
    next
  }

  def defaults() = {
    id     := 0.U
    len    := 0.U
    size   := log2Ceil(dataWidthBits / 8).U
    burst  := 1.U
    lock   := 0.U
    cache  := 0.U
    qos    := 0.U
    region := 0.U
  }
}

// ARM IHI 0022E, A2.3
class AxiWriteData(dataWidthBits: Int, idBits: Int) extends Bundle {
  // "Required"
  val data = UInt(dataWidthBits.W)
  val last = Bool()
  // "Optional"
  val strb = UInt((dataWidthBits / 8).W)

  def defaults() = {
    strb := ((1 << (dataWidthBits / 8)) - 1).U
  }
}

// ARM IHI 0022E, A2.4
class AxiWriteResponse(idBits: Int) extends Bundle {
  // "Optional"
  val id   = UInt(idBits.W)
  val resp = UInt(2.W)

  def defaults() = {
    id   := 0.U
    resp := 0.U
  }

  def defaultsFlipped() = {
    defaults()
  }
}

// ARM IHI 0022E, A2.6
class AxiReadData(dataWidthBits: Int, idBits: Int) extends Bundle {
  // "Required"
  val data = UInt(dataWidthBits.W)
  // "Optional"
  val id   = UInt(idBits.W)
  val resp = UInt(2.W) // 00 = Okay, 01 = ExOkay, 10 = SlvErr, 11 = DecErr
  val last = Bool()

  def defaults() = {
    id   := 0.U
    resp := 0.U
    last := false.B
  }

  def defaultsFlipped() = {
    defaults()
  }
}

class AxiLiteAddress(addrWidthBits: Int) extends Bundle {
  val addr = UInt(addrWidthBits.W)
  val prot = UInt(3.W)
}

class AxiLiteWriteData(dataWidthBits: Int) extends Bundle {
  val data = UInt(dataWidthBits.W)
  val strb = UInt((dataWidthBits / 8).W)
}

class AxiLiteReadData(dataWidthBits: Int) extends Bundle {
  val data = UInt(dataWidthBits.W)
  val resp = UInt(2.W)
}

class AxiMasterIO(addrWidthBits: Int, dataWidthBits: Int, idBits: Int) extends Bundle {
  val write = new AxiMasterWriteIO(addrWidthBits, dataWidthBits, idBits)
  val read  = new AxiMasterReadIO(addrWidthBits, dataWidthBits, idBits)

  def defaults() = {
    write.defaults()
    read.defaults()
  }

  def defaultsFlipped() = {
    write.defaultsFlipped()
    read.defaultsFlipped()
  }
}

class AxiMasterWriteIO(addrWidthBits: Int, dataWidthBits: Int, idBits: Int) extends Bundle {
  val addr = Decoupled(new AxiAddress(addrWidthBits, dataWidthBits, idBits))
  val data = Decoupled(new AxiWriteData(dataWidthBits, idBits))
  val resp = Flipped(Decoupled(new AxiWriteResponse(idBits)))

  def defaults() = {
    addr.bits.defaults()
    data.bits.defaults()
    addr.valid := false.B
    data.valid := false.B
    resp.ready := true.B
  }

  def defaultsFlipped() = {
    addr.ready := false.B
    data.ready := false.B
    resp.valid := false.B
    resp.bits.defaultsFlipped()
  }
}

class AxiMasterReadIO(addrWidthBits: Int, dataWidthBits: Int, idBits: Int) extends Bundle {
  val addr = Decoupled(new AxiAddress(addrWidthBits, dataWidthBits, idBits))
  val data = Flipped(Decoupled(new AxiReadData(dataWidthBits, idBits)))

  def defaults() = {
    addr.bits.defaults()
    addr.valid := false.B
    data.ready := false.B
  }

  def defaultsFlipped() = {
    addr.ready := false.B
    data.valid := false.B
    data.bits.defaultsFlipped()
  }
}

class AxiLiteMasterIO(val addrWidthBits: Int, val dataWidthBits: Int) extends Bundle {
  val read  = new AxiLiteMasterReadIO(addrWidthBits, dataWidthBits)
  val write = new AxiLiteMasterWriteIO(addrWidthBits, dataWidthBits)
}

class AxiLiteMasterWriteIO(val addrWidthBits: Int, val dataWidthBits: Int) extends Bundle {
  val addr = Decoupled(new AxiLiteAddress(addrWidthBits))
  val data = Decoupled(new AxiLiteWriteData(dataWidthBits))
  val resp = Flipped(Decoupled(UInt(2.W)))
}

class AxiLiteMasterReadIO(addrWidthBits: Int, dataWidthBits: Int) extends Bundle {
  val addr = Decoupled(new AxiLiteAddress(addrWidthBits))
  val data = Flipped(Decoupled(new AxiLiteReadData(dataWidthBits)))
}
