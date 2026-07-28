// Copyright 2025 Google LLC
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

object DmReqOp extends ChiselEnum {
  val NOP   = Value(0.U(2.W))
  val READ  = Value(1.U(2.W))
  val WRITE = Value(2.U(2.W))
}

object DmRspOp extends ChiselEnum {
  val SUCCESS = Value(0.U(2.W))
  val FAILED  = Value(2.U(2.W))
  val BUSY    = Value(3.U(2.W))
}

// See RISC-V Debug Specification v0.13.2
object DebugModuleAddress {
  def Data0      = 0x4.U(32.W)
  def Data1      = 0x5.U(32.W)
  def Dmcontrol  = 0x10.U(32.W)
  def Dmstatus   = 0x11.U(32.W)
  def Hartinfo   = 0x12.U(32.W)
  def Abstractcs = 0x16.U(32.W)
  def Command    = 0x17.U(32.W)
  def Sbcs       = 0x38.U(32.W)
}

object AccessRegisterCommand {
  def Cmdtype = 0.U(8.W)
}

object AccessMemoryCommand {
  def Cmdtype = 2.U(8.W)
}

class DebugModuleReqIO(p: Parameters) extends Bundle {
  val address = UInt(32.W)
  val data    = UInt(32.W)
  val op      = DmReqOp()

  def isRead: Bool           = (op === DmReqOp.READ)
  def isWrite: Bool          = (op === DmReqOp.WRITE)
  def isOp: Bool             = op.isOneOf(DmReqOp.READ, DmReqOp.WRITE)
  def isAddrData0: Bool      = (address === DebugModuleAddress.Data0)
  def isAddrData1: Bool      = (address === DebugModuleAddress.Data1)
  def isAddrDmcontrol: Bool  = (address === DebugModuleAddress.Dmcontrol)
  def isAddrDmstatus: Bool   = (address === DebugModuleAddress.Dmstatus)
  def isAddrHartinfo: Bool   = (address === DebugModuleAddress.Hartinfo)
  def isAddrAbstractcs: Bool = (address === DebugModuleAddress.Abstractcs)
  def isAddrCommand: Bool    = (address === DebugModuleAddress.Command)
  def isAddrSbcs: Bool       = (address === DebugModuleAddress.Sbcs)

  // Abstract command
  def cmdtype: UInt = data(31, 24)
  def write: Bool   = data(16)

  // Access Register
  def aarsize: UInt = data(22, 20)
  def regno: UInt   = data(15, 0)

  // Access memory
  def aamvirtual: UInt       = data(23)
  def aamsize: UInt          = data(22, 20)
  def aampostincrement: UInt = data(19)
}

class DebugModuleRspIO(p: Parameters) extends Bundle {
  val data = UInt(32.W)
  val op   = DmRspOp()
}

class DebugModuleIO(p: Parameters) extends Bundle {
  val req = Flipped(Decoupled(new DebugModuleReqIO(p)))
  val rsp = Decoupled(new DebugModuleRspIO(p))
}

class DebugModule(p: Parameters) extends Module {
  val nHart = 1
  val io    = IO(new Bundle {
    val ext       = new DebugModuleIO(p)
    val csr       = Output(Valid(new CsrCmd(p)))
    val csr_rs1   = Output(UInt(p.xlen.W))
    val csr_rd    = Input(Valid(UInt(p.xlen.W)))
    val scalar_rd = Decoupled(new RegfileWriteDataIO(p))
    val scalar_rs = new Bundle {
      val idx  = Output(UInt(log2Ceil(p.scalarRegCount).W))
      val data = Input(UInt(p.xlen.W))
    }
    val float_rd = Option.when(p.enableFloat)(Flipped(new FRegfileWrite(p)))
    val float_rs = Option.when(p.enableFloat)(Flipped(new FRegfileRead(p)))
    val itcm     = new FabricIO(p)
    val dtcm     = new FabricIO(p)

    val haltreq   = Output(Vec(nHart, Bool()))
    val resumereq = Output(Vec(nHart, Bool()))
    val resumeack = Input(Vec(nHart, Bool()))

    val ndmreset  = Output(Bool())
    val halted    = Input(Vec(nHart, Bool()))
    val running   = Input(Vec(nHart, Bool()))
    val havereset = Input(Vec(nHart, Bool()))
  })
  val req = Queue(io.ext.req, 1)

  val haltreq   = RegInit(VecInit.fill(nHart)(false.B))
  val resumereq = RegInit(VecInit.fill(nHart)(false.B))
  val resumeack = RegInit(VecInit.fill(nHart)(false.B))
  io.haltreq   := haltreq
  io.resumereq := resumereq

  val dmcontrol = RegInit(1.U(32.W))
  val dmactive  = dmcontrol(0)

  val data0  = RegInit(0.U(32.W))
  val data1  = RegInit(0.U(32.W))
  val cmderr = RegInit(0.U(32.W))

  val dmcontrol_wvalid = (req.fire && req.bits.isAddrDmcontrol && req.bits.isWrite)
  for (i <- 0 until nHart) {
    haltreq(i) := MuxCase(
      haltreq(i),
      Seq(
        dmcontrol_wvalid -> req.bits.data(31)
      )
    )
    val resumereq_i = MuxOR(dmcontrol_wvalid, req.bits.data(30))
    resumereq(i) := MuxCase(
      resumereq(i),
      Seq(
        dmcontrol_wvalid -> resumereq_i,
        io.resumeack(i)  -> false.B
      )
    )
    resumeack(i) := MuxCase(
      resumeack(i),
      Seq(
        haltreq(i)      -> false.B,
        io.resumeack(i) -> true.B
      )
    )
  }

  def LegalizeDmcontrol(in: UInt): UInt = {
    assert(in.getWidth == 32)
    val new_dmcontrol = Wire(UInt(32.W))
    val ndmreset      = req.bits.data(1)
    val dmactive      = req.bits.data(0)
    val hartsel       = Min(req.bits.data(25, 6), 1.U(20.W))
    new_dmcontrol := Cat(dmcontrol(31, 26), hartsel, dmcontrol(5, 2), ndmreset, dmactive)
    new_dmcontrol
  }
  dmcontrol := MuxCase(
    dmcontrol,
    Seq(
      dmcontrol_wvalid -> LegalizeDmcontrol(req.bits.data)
    )
  )
  io.ndmreset := dmcontrol(1)

  val dmstatus = Wire(UInt(32.W))
  dmstatus := Cat(
    0.U(14.W),
    resumeack.reduce(_ & _).asUInt,  // allresumeack
    resumeack.reduce(_ & _).asUInt,  // anyresumeack
    0.U(4.W),                        // any/all nonexistent/unavail
    io.running.reduce(_ & _).asUInt, // allrunning
    io.running.reduce(_ | _).asUInt, // anyrunning
    io.halted.reduce(_ & _).asUInt,  // allhalted
    io.halted.reduce(_ | _).asUInt,  // anyhalted
    1.U(1.W),                        // authenticated
    0.U(3.W),
    3.U(4.W) // version
  )

  val hartinfo = Wire(UInt(32.W))
  hartinfo := Cat(
    0.U(8.W),
    2.U(4.W), /* nscratch */
    0.U(3.W),
    0.U(1.W),      /* dataaccess */
    0.U(4.W),      /* datasize */
    "x7B4".U(12.W) /* dataaddr */
  )

  val abstractCmdValid        = req.valid && req.bits.isWrite && req.bits.isAddrCommand
  val cmdtypeIsAccessRegister = (req.bits.cmdtype === AccessRegisterCommand.Cmdtype)
  val cmdtypeIsAccessMemory   = (req.bits.cmdtype === AccessMemoryCommand.Cmdtype)
  val regnoIsCsr              = (req.bits.regno >= 0.U(16.W)) && (req.bits.regno < "x1000".U(16.W))
  val regnoIsScalar           =
    (req.bits.regno >= "x1000".U(16.W)) && (req.bits.regno < (0x1000 + p.scalarRegCount).U(16.W))
  val regnoIsFloat = (req.bits.regno >= (0x1000 + p.scalarRegCount).U(
    16.W
  ) && (req.bits.regno < (0x1000 + p.scalarRegCount + p.floatRegCount).U(16.W)))
  val regnoInvalid = !regnoIsCsr && !regnoIsScalar && !regnoIsFloat
  val sizeInvalid  =
    if (p.xlen == 64) (req.bits.aarsize =/= 3.U(3.W) && req.bits.aarsize =/= 2.U(3.W))
    else (req.bits.aarsize =/= 2.U(3.W))

  val itcm = p.m
    .filter(_.memType == MemoryRegionType.IMEM)
    .map(_.contains(data1))
    .reduceOption(_ || _)
    .getOrElse(false.B)
  val dtcm = p.m
    .filter(_.memType == MemoryRegionType.DMEM)
    .map(_.contains(data1))
    .reduceOption(_ || _)
    .getOrElse(false.B)
  val peri = p.m
    .filter(_.memType == MemoryRegionType.Peripheral)
    .map(_.contains(data1))
    .reduceOption(_ || _)
    .getOrElse(false.B)
  val ext = !(itcm || dtcm || peri)

  val abstractCmdCompleteFloat = (if (p.enableFloat) {
                                    Seq(
                                      (cmdtypeIsAccessRegister && regnoIsFloat && req.bits.write && io.float_rd
                                        .map(_.valid)
                                        .getOrElse(true.B)) -> true.B,
                                      (cmdtypeIsAccessRegister && regnoIsFloat && !req.bits.write) -> true.B
                                    )
                                  } else { Seq() })
  val abstractCmdComplete = (abstractCmdValid && MuxCase(
    false.B,
    Seq(
      (cmdtypeIsAccessRegister && regnoInvalid)                                         -> true.B,
      (cmdtypeIsAccessRegister && regnoIsCsr && io.csr_rd.valid)                        -> true.B,
      (cmdtypeIsAccessRegister && regnoIsScalar && req.bits.write && io.scalar_rd.fire) -> true.B,
      (cmdtypeIsAccessRegister && regnoIsScalar && !req.bits.write)                     -> true.B,
      (cmdtypeIsAccessMemory && (io.itcm.readData.valid))                               -> true.B,
      (cmdtypeIsAccessMemory && (io.dtcm.readData.valid))                               -> true.B,
      (cmdtypeIsAccessMemory && req.bits.write)                                         -> true.B,
      (cmdtypeIsAccessMemory && !(itcm || dtcm))                                        -> true.B
    ) ++ abstractCmdCompleteFloat
  )) || !io.halted(0)
  io.csr.valid      := io.halted(0) && abstractCmdValid && cmdtypeIsAccessRegister && regnoIsCsr
  io.csr.bits.addr  := 0.U(5.W)
  io.csr.bits.index := req.bits.regno
  io.csr.bits.op    := Mux(req.bits.write, CsrOp.CSRRW, CsrOp.CSRRC)
  io.csr.bits.rs1   := 0.U
  io.csr_rs1        := MuxOR(
    req.bits.write,
    if (p.xlen == 64) Mux(req.bits.aarsize === 3.U(3.W), Cat(data1, data0), data0) else data0
  )

  val abstractcs_wvalid = (req.fire && req.bits.isAddrAbstractcs && req.bits.isWrite)
  // TODO(atv): Enum for cmderr
  cmderr := MuxCase(
    cmderr,
    Seq(
      abstractcs_wvalid                   -> (cmderr & ~(req.bits.data(10, 8))), // cmderr is W1C
      (abstractCmdValid && !io.halted(0)) -> 4.U(3.W),
      (abstractCmdValid && req.bits.isAddrCommand && cmdtypeIsAccessRegister && req.bits.isOp && sizeInvalid) -> 2
        .U(3.W), // not supported
      (abstractCmdValid && req.bits.isAddrCommand && cmdtypeIsAccessMemory && !(itcm || dtcm)) -> 5
        .U(3.W),
      !dmactive -> 0.U(3.W)
    )
  )
  val busy       = abstractCmdValid && !abstractCmdComplete
  val abstractcs = Wire(UInt(32.W))
  abstractcs := Cat(
    0.U(3.W),  // rsvd
    0.U(5.W),  // progbufsize
    0.U(11.W), // rsvd
    busy,      // busy
    0.U(1.W),  // relaxedpriv
    cmderr,    // cmderr
    0.U(4.W),  // rsvd
    1.U(4.W)   // datacount
  )

  val scalarRegno = req.bits.regno(4, 0)
  io.scalar_rd.valid := io.halted(
    0
  ) && abstractCmdValid && (req.bits.cmdtype === AccessRegisterCommand.Cmdtype) && regnoIsScalar && req.bits.write
  io.scalar_rd.bits.addr := scalarRegno
  io.scalar_rd.bits.data := (if (p.xlen == 64)
                               Mux(
                                 req.bits.aarsize === 3.U(3.W),
                                 Cat(data1, data0),
                                 SignExtend(data0, p.xlen)
                               )
                             else data0)
  io.scalar_rs.idx := MuxOR(
    io.halted(
      0
    ) && abstractCmdValid && (req.bits.cmdtype === AccessRegisterCommand.Cmdtype) && regnoIsScalar && !req.bits.write,
    scalarRegno
  )

  if (p.enableFloat) {
    val floatRegno = req.bits.regno(4, 0)
    io.float_rd.get.valid := io.halted(
      0
    ) && abstractCmdValid && (req.bits.cmdtype === AccessRegisterCommand.Cmdtype) && regnoIsFloat && req.bits.write
    io.float_rd.get.addr  := floatRegno
    io.float_rd.get.data  := Fp32.fromWord(data0)
    io.float_rs.get.valid := io.halted(
      0
    ) && abstractCmdValid && (req.bits.cmdtype === AccessRegisterCommand.Cmdtype) && regnoIsFloat && !req.bits.write
    io.float_rs.get.addr := floatRegno
  }

  val itcmWords         = p.axi2DataBits / 32
  val itcmWordSel       = data1(log2Ceil(p.axi2DataBits / 8) - 1, 2)
  val data0ItcmReadData = MuxCase(
    0.U(32.W),
    (0 until itcmWords).map(i =>
      (itcmWordSel === i.U) -> io.itcm.readData.bits((i + 1) * 32 - 1, i * 32)
    )
  )
  val dtcmWords         = p.axi2DataBits / 32
  val dtcmWordSel       = data1(log2Ceil(p.axi2DataBits / 8) - 1, 2)
  val data0DtcmReadData = MuxCase(
    0.U(32.W),
    (0 until dtcmWords).map(i =>
      (dtcmWordSel === i.U) -> io.dtcm.readData.bits((i + 1) * 32 - 1, i * 32)
    )
  )
  val data0Priv = RegNext(data0, 0.U(32.W))
  data0 := MuxCase(
    data0,
    Seq(
      (req.valid && req.bits.isAddrData0 && req.bits.isWrite) -> req.bits.data,
      (abstractCmdComplete && cmdtypeIsAccessRegister && io.halted(
        0
      ) && req.valid && !req.bits.write && regnoIsCsr && io.csr_rd.valid) -> io.csr_rd.bits,
      (abstractCmdComplete && cmdtypeIsAccessRegister && io.halted(
        0
      ) && req.valid && !req.bits.write && regnoIsScalar) -> io.scalar_rs.data,
      (abstractCmdComplete && cmdtypeIsAccessRegister && io.halted(
        0
      ) && req.valid && !req.bits.write && regnoIsFloat) -> io.float_rs
        .map(_.data)
        .getOrElse(Fp32.Zero(false.B))
        .asWord,
      (abstractCmdComplete && cmdtypeIsAccessMemory && io.halted(
        0
      ) && req.valid && !req.bits.write && io.itcm.readData.valid) -> data0ItcmReadData.rotateRight(
        data1(1, 0) * 8.U
      ),
      (abstractCmdComplete && cmdtypeIsAccessMemory && io.halted(
        0
      ) && req.valid && !req.bits.write && io.dtcm.readData.valid) -> data0DtcmReadData.rotateRight(
        data1(1, 0) * 8.U
      ),
      !dmactive -> 0.U(32.W)
    )
  )

  data1 := MuxCase(
    data1,
    Seq(
      (req.valid && req.bits.isAddrData1 && req.bits.isWrite) -> req.bits.data,
      (abstractCmdComplete && cmdtypeIsAccessRegister && io.halted(
        0
      ) && req.valid && !req.bits.write && regnoIsCsr && io.csr_rd.valid) -> (if (p.xlen == 64)
                                                                                Mux(
                                                                                  req.bits.aarsize === 3
                                                                                    .U(3.W),
                                                                                  io.csr_rd
                                                                                    .bits(63, 32),
                                                                                  0.U(32.W)
                                                                                )
                                                                              else 0.U(32.W)),
      (abstractCmdComplete && cmdtypeIsAccessRegister && io.halted(
        0
      ) && req.valid && !req.bits.write && regnoIsScalar) -> (if (p.xlen == 64)
                                                                Mux(
                                                                  req.bits.aarsize === 3.U(3.W),
                                                                  io.scalar_rs.data(63, 32),
                                                                  0.U(32.W)
                                                                )
                                                              else 0.U(32.W)),
      (req.valid && (req.bits.aampostincrement === 1.U) && abstractCmdComplete && cmdtypeIsAccessMemory && io
        .halted(0)) -> (data1 + (1.U << req.bits.aamsize))
    )
  )

  val rsp = req.map(reqBits => {
    val rspBits = Wire(new DebugModuleRspIO(p))
    rspBits.op := MuxCase(
      DmRspOp.BUSY,
      Seq(
        (req.bits.isAddrData0 && req.bits.isOp)      -> DmRspOp.SUCCESS,
        (req.bits.isAddrData1 && req.bits.isOp)      -> DmRspOp.SUCCESS,
        (req.bits.isAddrDmcontrol && req.bits.isOp)  -> DmRspOp.SUCCESS,
        (req.bits.isAddrDmstatus && req.bits.isOp)   -> DmRspOp.SUCCESS,
        (req.bits.isAddrHartinfo && req.bits.isOp)   -> DmRspOp.SUCCESS,
        (req.bits.isAddrAbstractcs && req.bits.isOp) -> DmRspOp.SUCCESS,
        (req.bits.isAddrSbcs && req.bits.isOp)       -> DmRspOp.SUCCESS,
        (req.bits.isAddrCommand && cmdtypeIsAccessRegister && req.bits.isOp && regnoInvalid) -> DmRspOp.FAILED,
        (req.bits.isAddrCommand && cmdtypeIsAccessRegister && req.bits.isOp) -> DmRspOp.SUCCESS,
        // Accept any memory requests. We report failure (if necessary) via cmderr.
        (req.bits.isAddrCommand && cmdtypeIsAccessMemory) -> DmRspOp.SUCCESS
      )
    )
    rspBits.data := MuxCase(
      0.U(32.W),
      Seq(
        (req.bits.isAddrData0 && req.bits.isRead)      -> data0,
        (req.bits.isAddrData1 && req.bits.isRead)      -> data1,
        (req.bits.isAddrDmcontrol && req.bits.isRead)  -> dmcontrol,
        (req.bits.isAddrDmstatus && req.bits.isRead)   -> dmstatus,
        (req.bits.isAddrHartinfo && req.bits.isRead)   -> hartinfo,
        (req.bits.isAddrAbstractcs && req.bits.isRead) -> abstractcs,
        (req.bits.isAddrSbcs && req.bits.isRead)       -> 0.U(32.W),
        (req.bits.isAddrCommand && req.bits.isRead)    -> 0.U(32.W)
      )
    )
    rspBits
  })
  rsp.valid := req.valid && (!abstractCmdValid || abstractCmdComplete)
  req.ready := rsp.ready && (!abstractCmdValid || abstractCmdComplete)
  io.ext.rsp <> Queue(rsp, 1)

  io.itcm.readDataAddr.valid := (abstractCmdValid && cmdtypeIsAccessMemory && !req.bits.write && itcm)
  io.itcm.readDataAddr.bits := data1
  io.itcm.writeDataAddr.valid := (abstractCmdValid && cmdtypeIsAccessMemory && req.bits.write && itcm)
  io.itcm.writeDataAddr.bits := data1

  io.dtcm.readDataAddr.valid := (abstractCmdValid && cmdtypeIsAccessMemory && !req.bits.write && dtcm)
  io.dtcm.readDataAddr.bits := data1
  io.dtcm.writeDataAddr.valid := (abstractCmdValid && cmdtypeIsAccessMemory && req.bits.write && dtcm)
  io.dtcm.writeDataAddr.bits := data1
  // Handle variable access sizes and alignment
  val byteOffsetBits = log2Ceil(p.axi2DataBits / 8)
  val byteOffset     = data1(byteOffsetBits - 1, 0)
  val strobe         = MuxCase(
    ~0.U((p.axi2DataBits / 8).W),
    Seq(
      (req.bits.aamsize === 0.U) -> ("b0001".U << byteOffset),
      (req.bits.aamsize === 1.U) -> ("b0011".U << byteOffset),
      (req.bits.aamsize === 2.U) -> ("b1111".U << byteOffset)
    )
  )
  val writeDataBits = data0.asTypeOf(UInt(p.axi2DataBits.W)) << (byteOffset * 8.U)
  io.dtcm.writeDataBits := writeDataBits
  io.dtcm.writeDataStrb := strobe
  io.itcm.writeDataBits := writeDataBits
  io.itcm.writeDataStrb := strobe
}
