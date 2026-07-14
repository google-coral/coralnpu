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

package bus

import chisel3._
import chisel3.util._

object TLULOpcodesA extends ChiselEnum {
  val PutFullData    = Value(0.U(3.W))
  val PutPartialData = Value(1.U(3.W))
  val Get            = Value(4.U(3.W))
  val End            = Value(7.U(3.W))
}

object TLULOpcodesD extends ChiselEnum {
  val AccessAck     = Value(0.U(3.W))
  val AccessAckData = Value(1.U(3.W))
  val End           = Value(7.U(3.W))
}

trait TLUL_A_User_InstrType {
  val instr_type: UInt
}

class OpenTitanTileLink_A_User extends Bundle with TLUL_A_User_InstrType {
  val rsvd       = UInt(5.W)
  val instr_type = UInt(4.W) // mubi4_t
  val cmd_intg   = UInt(7.W)
  val data_intg  = UInt(7.W)
}

class OpenTitanTileLink_D_User extends Bundle {
  val rsp_intg  = UInt(7.W)
  val data_intg = UInt(7.W)
}

class NoUser extends Bundle {}

class TileLink_A_ChannelBase[T <: Data](
  val p: TLULParameters,
  val userGen: () => T = () => (new NoUser).asInstanceOf[T]
) extends Bundle {
  val opcode  = UInt(3.W)
  val param   = UInt(3.W)
  val size    = UInt(p.z.W)
  val source  = UInt(p.o.W)
  val address = UInt(p.a.W)
  val mask    = UInt(p.w.W)
  val data    = UInt((8 * p.w).W)
  val user    = userGen()

  def extendSource(extraBits: UInt) = {
    val extraWidth = extraBits.getWidth
    val result     = Wire(new TileLink_A_ChannelBase(p.augmentId(extraWidth), userGen))
    result.opcode  := this.opcode
    result.param   := this.param
    result.size    := this.size
    result.source  := Cat(this.source, extraBits)
    result.address := this.address
    result.mask    := this.mask
    result.data    := this.data
    result.user    := this.user
    result
  }
}

class TileLink_D_ChannelBase[T <: Data](
  val p: TLULParameters,
  val userGen: () => T = () => (new NoUser).asInstanceOf[T]
) extends Bundle {
  val opcode = UInt(3.W)
  val param  = UInt(3.W)
  val size   = UInt(p.z.W)
  val source = UInt(p.o.W)
  val sink   = UInt(p.i.W)
  val data   = UInt((8 * p.w).W)
  val user   = userGen()
  val error  = Bool()

  def shrinkSource(extraBits: Int) = {
    val result = Wire(new TileLink_D_ChannelBase(p.shrinkId(extraBits), userGen))
    result.opcode := this.opcode
    result.param  := this.param
    result.size   := this.size
    result.source := this.source >> extraBits
    result.sink   := this.sink
    result.data   := this.data
    result.user   := this.user
    result.error  := this.error
    result
  }
}

class TileLink_A_Channel(p: TLULParameters) extends TileLink_A_ChannelBase(p, () => new NoUser) {}
class TileLink_D_Channel(p: TLULParameters) extends TileLink_D_ChannelBase(p, () => new NoUser) {}

class TLULHost2Device[A_USER <: Data, D_USER <: Data](
  val p: TLULParameters,
  val userAGen: () => A_USER = () => (new NoUser).asInstanceOf[A_USER],
  val userDGen: () => D_USER = () => (new NoUser).asInstanceOf[D_USER]
) extends Bundle {
  val a = Decoupled(new TileLink_A_ChannelBase(p, userAGen))
  val d = Flipped(Decoupled(new TileLink_D_ChannelBase(p, userDGen)))

  def extendSource(extraBits: Int) = {
    new TLULHost2Device(p.augmentId(extraBits), userAGen, userDGen)
  }
}

class TLULDevice2Host[A_USER <: Data, D_USER <: Data](
  val p: TLULParameters,
  val userAGen: () => A_USER = () => (new NoUser).asInstanceOf[A_USER],
  val userDGen: () => D_USER = () => (new NoUser).asInstanceOf[D_USER]
) extends Bundle {
  val a = Flipped(Decoupled(new TileLink_A_ChannelBase(p, userAGen)))
  val d = Decoupled(new TileLink_D_ChannelBase(p, userDGen))

  def extendSource(extraBits: Int) = {
    new TLULDevice2Host(p.augmentId(extraBits), userAGen, userDGen)
  }
}

object OpenTitanTileLink {
  class A_Channel(p: TLULParameters)
      extends TileLink_A_ChannelBase(p, () => new OpenTitanTileLink_A_User) {}
  class D_Channel(p: TLULParameters)
      extends TileLink_D_ChannelBase(p, () => new OpenTitanTileLink_D_User) {}
  class Host2Device(p: TLULParameters)
      extends TLULHost2Device(
        p,
        () => new OpenTitanTileLink_A_User,
        () => new OpenTitanTileLink_D_User
      ) {}
  class Device2Host(p: TLULParameters)
      extends TLULDevice2Host(
        p,
        () => new OpenTitanTileLink_A_User,
        () => new OpenTitanTileLink_D_User
      ) {}
}

object TlulAccessors {
  def augment[A_USER <: Data, D_USER <: Data](
    narrow: TLULHost2Device[A_USER, D_USER],
    hostIndex: UInt
  ): TLULHost2Device[A_USER, D_USER] = {
    val extraBits = hostIndex.getWidth
    val wide      = Wire(narrow.extendSource(extraBits))

    // A-Channel (Request: wide <- narrow)
    wide.a.valid   := narrow.a.valid
    narrow.a.ready := wide.a.ready
    wide.a.bits    := narrow.a.bits.extendSource(hostIndex)

    // D-Channel (Response: narrow <- wide)
    narrow.d.valid := wide.d.valid
    wide.d.ready   := narrow.d.ready
    narrow.d.bits  := wide.d.bits.shrinkSource(extraBits)

    wide
  }
}
