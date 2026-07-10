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

import common.{MakeInvalid, MakeValid, MuxUpTo1H}
import chisel3._
import chisel3.util._
import coralnpu.float.{CsrFloatIO}

class CsrRvvIO(p: Parameters) extends Bundle {
  // To Csr from RvvCore
  val vstart = Input(UInt(log2Ceil(p.rvvVlen).W))
  val vl = Input(UInt(log2Ceil(p.rvvVlen + 1).W))
  val vtype = Input(UInt(32.W))
  val vxrm = Input(UInt(2.W))
  val vxsat = Input(Bool())
  // From Csr to RvvCore
  val vstart_write = Output(Valid(UInt(log2Ceil(p.rvvVlen).W)))
  val vxrm_write = Output(Valid(UInt(2.W)))
  val vxsat_write = Output(Valid(Bool()))
  val frm = Output(UInt(3.W))
}

object Csr {
  def apply(p: Parameters): Csr = {
    return Module(new Csr(p))
  }
}

object CsrAddress extends ChiselEnum {
  // Per spec, this is not allocated. We use this internally to
  // represent an invalid address.
  val RESERVED  = Value(0x000.U(12.W))
  val FFLAGS    = Value(0x001.U(12.W))
  val FRM       = Value(0x002.U(12.W))
  val FCSR      = Value(0x003.U(12.W))
  val VSTART    = Value(0x008.U(12.W))
  val VXSAT     = Value(0x009.U(12.W))
  val VXRM      = Value(0x00A.U(12.W))
  val MSTATUS   = Value(0x300.U(12.W))
  val MISA      = Value(0x301.U(12.W))
  val MIE       = Value(0x304.U(12.W))
  val MTVEC     = Value(0x305.U(12.W))
  val MSTATUSH  = Value(0x310.U(12.W))
  val MSCRATCH  = Value(0x340.U(12.W))
  val MEPC      = Value(0x341.U(12.W))
  val MCAUSE    = Value(0x342.U(12.W))
  val MTVAL     = Value(0x343.U(12.W))
  val MIP       = Value(0x344.U(12.W))
  val TSELECT   = Value(0x7A0.U(12.W))
  val TDATA1    = Value(0x7A1.U(12.W))
  val TDATA2    = Value(0x7A2.U(12.W))
  val TINFO     = Value(0x7A4.U(12.W))
  val DCSR      = Value(0x7B0.U(12.W))
  val DPC       = Value(0x7B1.U(12.W))
  val DSCRATCH0 = Value(0x7B2.U(12.W))
  val DSCRATCH1 = Value(0x7B3.U(12.W))
  val MCONTEXT0 = Value(0x7C0.U(12.W))
  val MCONTEXT1 = Value(0x7C1.U(12.W))
  val MCONTEXT2 = Value(0x7C2.U(12.W))
  val MCONTEXT3 = Value(0x7C3.U(12.W))
  val MCONTEXT4 = Value(0x7C4.U(12.W))
  val MCONTEXT5 = Value(0x7C5.U(12.W))
  val MCONTEXT6 = Value(0x7C6.U(12.W))
  val MCONTEXT7 = Value(0x7C7.U(12.W))
  val MPC       = Value(0x7E0.U(12.W))
  val MSP       = Value(0x7E1.U(12.W))
  val MCYCLE    = Value(0xB00.U(12.W))
  val MINSTRET  = Value(0xB02.U(12.W))
  val MCYCLEH   = Value(0xB80.U(12.W))
  val MINSTRETH = Value(0xB82.U(12.W))
  val VL        = Value(0xC20.U(12.W))
  val VTYPE     = Value(0xC21.U(12.W))
  val VLENB     = Value(0xC22.U(12.W))
  val MVENDORID = Value(0xF11.U(12.W))
  val MARCHID   = Value(0xF12.U(12.W))
  val MIMPID    = Value(0xF13.U(12.W))
  val MHARTID   = Value(0xF14.U(12.W))
  val KISA      = Value(0xFC0.U(12.W))
  val KSCM0     = Value(0xFC4.U(12.W))
  val KSCM1     = Value(0xFC8.U(12.W))
  val KSCM2     = Value(0xFCC.U(12.W))
  val KSCM3     = Value(0xFD0.U(12.W))
  val KSCM4     = Value(0xFD4.U(12.W))
}

object CsrMode extends ChiselEnum {
  val Machine = Value(0.U(2.W))
  val Debug = Value(2.U(2.W))
}

/* For details, see The RISC-V Debug Specification v1.0, chapter 4.9.1 */
class Dcsr(p: Parameters) extends Bundle {
  val debugver = UInt(4.W)
  val extcause = UInt(3.W)
  val cetrig = Bool()
  val pelp = Bool()
  val ebreakvs = Bool()
  val ebreakvu = Bool()
  val ebreakm = Bool()
  val ebreaks = Bool()
  val ebreaku = Bool()
  val stepie = Bool()
  val stopcount = Bool()
  val stoptime = Bool()
  val cause = UInt(3.W)
  val v = Bool()
  val mprven = Bool()
  val nmip = Bool()
  val step = Bool()
  val prv = UInt(2.W)

  def asWord: UInt = {
    val ret = Cat(debugver, 0.U(1.W), extcause, 0.U(4.W), cetrig, pelp, ebreakvs, ebreakvu, ebreakm, 0.U(1.W),
                  ebreaks, ebreaku, stepie, stopcount, stoptime, cause, v, mprven, nmip, step, prv)
    assert(ret.getWidth == 32)
    if (p.xlen == 32) {
      ret
    } else {
      Cat(0.U((p.xlen - 32).W), ret)
    }
  }
}

/* For details, see The RISC-V Debug Specification v1.0, chapter 5.7.2 */
class Tdata1(p: Parameters) extends Bundle {
  val data = UInt(p.xlen.W)
  def _type: UInt = data(p.xlen - 1, p.xlen - 4)
  def asWord: UInt = {
    data.asUInt
  }
  def isTrigger6: Bool = {
    _type === 6.U(4.W)
  }
  def m: Bool = data(6)
}

// Cause types for the dcsr `cause` field.
// See Table 8 in Chapter 4.9.1 of the Debug Specification.
// These are sorted in priority order.
object DebugCause extends ChiselEnum {
  val resethaltreq = 5.U(3.W)
  val haltgroup = 6.U(3.W)
  val haltreq = 3.U(3.W)
  val trigger = 2.U(3.W)
  val ebreak = 1.U(3.W)
  val step = 4.U(3.W)
  val other = 7.U(3.W)
}

class CsrCounters(p: Parameters) extends Bundle {
  val nRetired = UInt(log2Ceil(p.retirementBufferSize + 1).W)
}

class CsrBruIO(p: Parameters) extends Bundle {
  val in = new Bundle {
    val mode   = Valid(CsrMode())
    val mcause = Valid(UInt(p.xlen.W))
    val mepc   = Valid(UInt(p.programCounterBits.W))
    val mtval  = Valid(UInt(p.xlen.W))
    val halt   = Output(Bool())
    val fault  = Output(Bool())
    val wfi    = Output(Bool())
  }
  val out = new Bundle {
    val mode  = Input(CsrMode())
    val mepc  = Input(UInt(p.programCounterBits.W))
    val mtvec = Input(UInt(p.programCounterBits.W))
    val interrupt = Input(Bool())
    val interrupt_cause = Input(UInt(p.xlen.W))
  }
  def defaults() = {
    out.mode := CsrMode.Machine
    out.mepc := 0.U
    out.mtvec := 0.U
    out.interrupt := false.B
    out.interrupt_cause := 0.U
  }
}

class Csr(p: Parameters) extends Module {
  val io = IO(new Bundle {
    // Reset and shutdown.
    val csr = new CsrInOutIO(p)

    // Decode cycle.
    val req = Flipped(Valid(new CsrCmd(p)))

    // Execute cycle.
    val rs1 = Flipped(new RegfileReadDataIO(p))
    val rd  = Valid(Flipped(new RegfileWriteDataIO(p)))
    val bru = Flipped(new CsrBruIO(p))
    val float = Option.when(p.enableFloat) { Flipped(new CsrFloatIO(p)) }
    val rvv = Option.when(p.enableRvv) { new CsrRvvIO(p) }

    val counters = Input(new CsrCounters(p))

    // Pipeline Control.
    val halted = Output(Bool())
    val fault  = Output(Bool())
    val wfi    = Output(Bool())
    val irq    = Input(Bool())
    val dm = new Bundle {
      val debug_req = Input(Bool())
      val resume_req = Input(Bool())
      val debug_mode = Output(Bool())
      val single_step = Output(Bool())
      val dcsr_step = Output(Bool())
      val current_pc = Input(UInt(p.programCounterBits.W))
      val next_pc = Input(UInt(p.programCounterBits.W))
      val debug_pc = Valid(UInt(p.fetchAddrBits.W))
    }
    val timer_irq = Input(Bool())
    val software_irq = Input(Bool())
    val trace = Output(new CsrTraceIO(p))
  })

  def LegalizeTdata1(wdata: UInt): Tdata1 = {
    assert(wdata.getWidth == p.xlen)
    val newWdata = Wire(new Tdata1(p))
    newWdata.data := Cat(
      6.U(4.W),   // type
      wdata(p.xlen - 5), // dmode
      0.U((p.xlen - 21).W),
      wdata(15,12) & 1.U(4.W), // action
      0.U(5.W),
      wdata(6),  // m
      (wdata(5,0) & 4.U(6.W)) // !uncertainen, !s, !u, execute, !store, !load
    )
    newWdata
  }

  // Control registers. CsrAddress.RESERVED is used for invalid values.
  val req = RegInit(MakeInvalid(new CsrCmd(p)))
  req := MakeValid(io.req.valid, io.req.bits, bitsWhenInvalid=req.bits)

  // Pipeline Control.
  val halted = RegInit(false.B)
  val fault  = RegInit(false.B)
  val wfi    = RegInit(false.B)

  // Machine(0)/Debug(2) Mode.
  val mode = RegInit(CsrMode.Machine)

  // CSRs parallel loaded when(reset).
  val mpc       = RegInit(0.U(p.programCounterBits.W))
  val msp       = RegInit(0.U(p.xlen.W))
  val mcause    = RegInit(0.U(p.xlen.W))
  val mtval     = RegInit(0.U(p.xlen.W))
  val mcontext0 = RegInit(0.U(p.xlen.W))
  val mcontext1 = RegInit(0.U(p.xlen.W))
  val mcontext2 = RegInit(0.U(p.xlen.W))
  val mcontext3 = RegInit(0.U(p.xlen.W))
  val mcontext4 = RegInit(0.U(p.xlen.W))
  val mcontext5 = RegInit(0.U(p.xlen.W))
  val mcontext6 = RegInit(0.U(p.xlen.W))
  val mcontext7 = RegInit(0.U(p.xlen.W))

  // Debug mode CSRs
  val dcsr      = RegInit(0.U.asTypeOf(new Dcsr(p)))
  val dpc       = RegInit(0.U(p.programCounterBits.W))
  val dscratch0 = RegInit(0.U(p.xlen.W))
  val dscratch1 = RegInit(0.U(p.xlen.W))
  // Trigger CSRs
  val tselect   = RegInit(0.U(p.xlen.W))
  val tdata1    = RegInit(((if (p.xlen == 32) 0x60000000L else 0x6000000000000000L).U).asTypeOf(new Tdata1(p)))
  val tdata2    = RegInit(0.U(p.xlen.W))
  /* For details, see The RISC-V Debug Specification v1.0, chapter 5.7.5 */
  val tinfo     = RegInit(0x01000040.U(p.xlen.W))

  // CSRs with initialization.
  val fflags    = RegInit(0.U(5.W))
  val frm       = RegInit(0.U(3.W))
  val mstatus_mie  = RegInit(false.B)
  val mstatus_mpie = RegInit(false.B)
  val mie       = RegInit(0.U(p.xlen.W))
  val mtvec     = RegInit(0.U(p.programCounterBits.W))
  val mscratch  = RegInit(0.U(p.xlen.W))
  val mepc      = RegInit(0.U(p.programCounterBits.W))
  val mhartid   = RegInit(p.hartId.U(p.xlen.W))

  val mcycle    = RegInit(0.U(64.W))
  val minstret  = RegInit(0.U(64.W))
  val minstretThisCycle_delayed = RegInit(0.U(64.W))
  val minstret_val = minstret + minstretThisCycle_delayed

  // MXLEN, I,M,X extensions
  val misaValue = (if (p.xlen == 32) BigInt(0x40001100L) else BigInt("8000000000001100", 16)) |
                  (if (p.enableRvv) { BigInt(1) << 21 } else { BigInt(0) }) |
                  (if (p.enableFloat) { BigInt(1) << 5 } else { BigInt(0) })
  val misa      = RegInit(misaValue.U(p.xlen.W))
  // CoralNPU-specific ISA register.
  val kisa      = RegInit(0.U(p.xlen.W))
  // SCM Revision (spread over 5 indices)
  val kscm      = RegInit(((new ScmInfo).revision).U(160.W))

  // 0x426 - Google's Vendor ID
  val mvendorid = RegInit(0x426.U(p.xlen.W))

  // Unimplemented -- explicitly return zero.
  val marchid   = RegInit(0.U(1.W))
  val mimpid    = RegInit(0.U(1.W))

  val fcsr = Cat(frm, fflags)

  // TODO(b/452672880): Implement the dirty feature for fs and vs.
  val fs = if (p.enableFloat) 1.U(2.W) else 0.U(2.W)
  val vs = if (p.enableRvv) 1.U(2.W) else 0.U(2.W)

  // Decode the Index.
  val (csr_address, csr_address_valid) = CsrAddress.safe(req.bits.index)
  assert(!(req.valid && !csr_address_valid))
  val fflagsEn    = csr_address === CsrAddress.FFLAGS
  val frmEn       = csr_address === CsrAddress.FRM
  val fcsrEn      = csr_address === CsrAddress.FCSR
  val vstartEn    = Option.when(p.enableRvv) { csr_address === CsrAddress.VSTART }
  val vlEn        = Option.when(p.enableRvv) { csr_address === CsrAddress.VL }
  val vtypeEn     = Option.when(p.enableRvv) { csr_address === CsrAddress.VTYPE }
  val vxrmEn      = Option.when(p.enableRvv) { csr_address === CsrAddress.VXRM }
  val vxsatEn     = Option.when(p.enableRvv) { csr_address === CsrAddress.VXSAT }
  val mstatusEn   = csr_address === CsrAddress.MSTATUS
  val misaEn      = csr_address === CsrAddress.MISA
  val mieEn       = csr_address === CsrAddress.MIE
  val mtvecEn     = csr_address === CsrAddress.MTVEC
  val mstatushEn  = csr_address === CsrAddress.MSTATUSH
  val mscratchEn  = csr_address === CsrAddress.MSCRATCH
  val mepcEn      = csr_address === CsrAddress.MEPC
  val mcauseEn    = csr_address === CsrAddress.MCAUSE
  val mtvalEn     = csr_address === CsrAddress.MTVAL
  val mipEn       = csr_address === CsrAddress.MIP
  // Debug CSRs.
  val tselectEn   = csr_address === CsrAddress.TSELECT
  val tdata1En    = csr_address === CsrAddress.TDATA1
  val tdata2En    = csr_address === CsrAddress.TDATA2
  val tinfoEn     = csr_address === CsrAddress.TINFO
  val dcsrEn      = csr_address === CsrAddress.DCSR
  val dpcEn       = csr_address === CsrAddress.DPC
  val dscratch0En = csr_address === CsrAddress.DSCRATCH0
  val dscratch1En = csr_address === CsrAddress.DSCRATCH1
  val mcontext0En = csr_address === CsrAddress.MCONTEXT0
  val mcontext1En = csr_address === CsrAddress.MCONTEXT1
  val mcontext2En = csr_address === CsrAddress.MCONTEXT2
  val mcontext3En = csr_address === CsrAddress.MCONTEXT3
  val mcontext4En = csr_address === CsrAddress.MCONTEXT4
  val mcontext5En = csr_address === CsrAddress.MCONTEXT5
  val mcontext6En = csr_address === CsrAddress.MCONTEXT6
  val mcontext7En = csr_address === CsrAddress.MCONTEXT7
  val mpcEn       = csr_address === CsrAddress.MPC
  val mspEn       = csr_address === CsrAddress.MSP
  // M-mode performance CSRs.
  val mcycleEn    = csr_address === CsrAddress.MCYCLE
  val minstretEn  = csr_address === CsrAddress.MINSTRET
  val mcyclehEn   = csr_address === CsrAddress.MCYCLEH
  val minstrethEn = csr_address === CsrAddress.MINSTRETH
  // Vector CSRs.
  val vlenbEn     = Option.when(p.enableRvv) { csr_address === CsrAddress.VLENB }
  // M-mode information CSRs.
  val mvendoridEn = csr_address === CsrAddress.MVENDORID
  val marchidEn   = csr_address === CsrAddress.MARCHID
  val mimpidEn    = csr_address === CsrAddress.MIMPID
  val mhartidEn   = csr_address === CsrAddress.MHARTID
  // Start of custom CSRs.
  val kisaEn      = csr_address === CsrAddress.KISA
  val kscm0En     = csr_address === CsrAddress.KSCM0
  val kscm1En     = csr_address === CsrAddress.KSCM1
  val kscm2En     = csr_address === CsrAddress.KSCM2
  val kscm3En     = csr_address === CsrAddress.KSCM3
  val kscm4En     = csr_address === CsrAddress.KSCM4

  // Pipeline Control.
  when (io.bru.in.halt) {
    halted := true.B
  }

  when (io.bru.in.fault) {
    fault := true.B
  }

  val mtip_pending = io.timer_irq && mie(7)
  val meip_pending = io.irq && mie(11)
  val msip_pending = io.software_irq && mie(3)
  wfi := Mux(wfi, !(mtip_pending || meip_pending || msip_pending || io.dm.debug_req), io.bru.in.wfi)

  io.halted := halted
  io.fault  := fault
  io.wfi    := wfi

  assert(!(io.fault && !io.halted && !io.wfi))

  // Register state.
  val rs1 = io.rs1.data

  val rdata = MuxUpTo1H(0.U(32.W), Seq(
      fflagsEn    -> Cat(0.U(27.W), fflags),
      frmEn       -> Cat(0.U(29.W), frm),
      fcsrEn      -> Cat(0.U(24.W), fcsr),
      mstatusEn   -> Cat(0.U(17.W), fs, 3.U(2.W), vs, 0.U(1.W), mstatus_mpie, 0.U(3.W), mstatus_mie, 0.U(3.W)),
      misaEn      -> misa,
      mieEn       -> mie,
      mipEn       -> Cat(0.U(20.W), io.irq, 0.U(3.W), io.timer_irq, 0.U(3.W), io.software_irq, 0.U(3.W)),
      mtvecEn     -> mtvec,
      mstatushEn  -> 0.U(32.W),
      mscratchEn  -> mscratch,
      mepcEn      -> mepc,
      mcauseEn    -> mcause,
      mtvalEn     -> mtval,
      mcontext0En -> mcontext0,
      mcontext1En -> mcontext1,
      mcontext2En -> mcontext2,
      mcontext3En -> mcontext3,
      mcontext4En -> mcontext4,
      mcontext5En -> mcontext5,
      mcontext6En -> mcontext6,
      mcontext7En -> mcontext7,
      mpcEn       -> mpc,
      mspEn       -> msp,
      mcycleEn    -> mcycle(31,0),
      mcyclehEn   -> mcycle(63,32),
      minstretEn  -> minstret_val(31,0),
      minstrethEn -> minstret_val(63,32),
      mvendoridEn -> mvendorid,
      marchidEn   -> Cat(0.U(31.W), marchid),
      mimpidEn    -> Cat(0.U(31.W), mimpid),
      mhartidEn   -> mhartid,
      kisaEn      -> kisa,
      kscm0En     -> kscm(31,0),
      kscm1En     -> kscm(63,32),
      kscm2En     -> kscm(95,64),
      kscm3En     -> kscm(127,96),
      kscm4En     -> kscm(159,128),
    ) ++
      Option.when(p.enableRvv) {
        Seq(
          vstartEn.get -> io.rvv.get.vstart,
          vlEn.get     -> io.rvv.get.vl,
          vtypeEn.get  -> io.rvv.get.vtype,
          vxrmEn.get   -> io.rvv.get.vxrm,
          vxsatEn.get  -> io.rvv.get.vxsat,
          vlenbEn.get -> 16.U(32.W),  // Vector length in Bytes
        )
      }.getOrElse(Seq())
      ++
      Seq(
        tselectEn   -> tselect,
        tdata1En    -> tdata1.asWord,
        tdata2En    -> tdata2,
        tinfoEn     -> tinfo,
        dcsrEn      -> dcsr.asWord,
        dpcEn       -> dpc,
        dscratch0En -> dscratch0,
        dscratch1En -> dscratch1,
      )
  )

  val wdata = MuxLookup(req.bits.op, 0.U)(Seq(
      CsrOp.CSRRW -> rs1,
      CsrOp.CSRRS -> (rdata | rs1),
      CsrOp.CSRRC -> (rdata & ~rs1)
  ))

  when (req.valid) {
    when (fflagsEn)     { fflags    := wdata }
    when (frmEn)        { frm       := wdata }
    when (fcsrEn)       { fflags    := wdata(4,0)
                          frm       := wdata(7,5) }
    when (mstatusEn)    { mstatus_mie := wdata(3); mstatus_mpie := wdata(7) }
    when (mieEn)        { mie       := wdata & "h888".U }
    when (mtvecEn)      { mtvec     := wdata }
    //Writes to mstatush are ignored (hardwired zero)
    when (mscratchEn)   { mscratch  := wdata }
    when (mepcEn)       { mepc      := wdata }
    when (mcauseEn)     { mcause    := wdata }
    when (mtvalEn)      { mtval     := wdata }
    when (mpcEn)        { mpc       := wdata }
    when (mspEn)        { msp       := wdata }
    when (mcontext0En)  { mcontext0 := wdata }
    when (mcontext1En)  { mcontext1 := wdata }
    when (mcontext2En)  { mcontext2 := wdata }
    when (mcontext3En)  { mcontext3 := wdata }
    when (mcontext4En)  { mcontext4 := wdata }
    when (mcontext5En)  { mcontext5 := wdata }
    when (mcontext6En)  { mcontext6 := wdata }
    when (mcontext7En)  { mcontext7 := wdata }
    when (dscratch0En)  { dscratch0 := wdata }
    when (dscratch1En)  { dscratch1 := wdata }
    when (tdata1En)     { tdata1 := LegalizeTdata1(wdata) }
    when (tdata2En)     { tdata2 := wdata }
  }

  if (p.enableRvv) {
    io.rvv.get.vstart_write.valid := req.valid && vstartEn.get
    io.rvv.get.vstart_write.bits  := wdata(log2Ceil(p.rvvVlen)-1, 0)
    io.rvv.get.vxrm_write.valid   := req.valid && vxrmEn.get
    io.rvv.get.vxrm_write.bits    := wdata(1,0)
    io.rvv.get.vxsat_write.valid  := req.valid && vxsatEn.get
    io.rvv.get.vxsat_write.bits   := wdata(0)
    io.rvv.get.frm                := frm
  }

  val is_csr_write = req.valid && !(req.bits.op.isOneOf(CsrOp.CSRRS, CsrOp.CSRRC) && req.bits.rs1 === 0.U)

  // mcycle implementation
  // If one of the enable signals for
  // the register are true, overwrite the enabled half
  // of the register.
  // Increment the value of mcycle by 1.
  val mcycle_th = Mux(mcyclehEn, wdata, mcycle(63,32))
  val mcycle_tl = Mux(mcycleEn, wdata, mcycle(31,0))
  val mcycle_t = Cat(mcycle_th, mcycle_tl)
  val mcycle_written = is_csr_write && (mcycleEn || mcyclehEn)
  mcycle := Mux(mcycle_written, mcycle_t, mcycle + 1.U)


  val minstret_th = Mux(minstrethEn, wdata, minstret(63,32))
  val minstret_tl = Mux(minstretEn, wdata, minstret(31,0))
  val minstret_t = Cat(minstret_th, minstret_tl)
  val minstret_written = is_csr_write && (minstretEn || minstrethEn)
  minstretThisCycle_delayed := Mux(minstret_written, 0.U, io.counters.nRetired)
  minstret := Mux(minstret_written, minstret_t, minstret + minstretThisCycle_delayed)

  val trigger_enabled = tdata1.isTrigger6 && tdata1.m
  val trigger_match = trigger_enabled && io.dm.current_pc === tdata2

  val entering_debug_mode = (mode =/= CsrMode.Debug) && (io.dm.debug_req || trigger_match)
  val exiting_debug_mode = (mode === CsrMode.Debug) && (io.dm.resume_req)
  mode := MuxCase(mode, Seq(
    entering_debug_mode -> CsrMode.Debug,
    exiting_debug_mode -> CsrMode.Machine,
    io.bru.in.mode.valid -> io.bru.in.mode.bits,
  ))
  io.dm.debug_mode := (mode === CsrMode.Debug) || entering_debug_mode
  val newCause = MuxCase(DebugCause.other, Seq(
        (io.dm.debug_req && !io.dm.dcsr_step) -> DebugCause.haltreq,
        trigger_match -> DebugCause.trigger,
        io.dm.dcsr_step -> DebugCause.step,
      ))
  dcsr := MuxCase(dcsr, Seq(
    entering_debug_mode -> {
      val newDcsr = Wire(new Dcsr(p))
      newDcsr := dcsr
      newDcsr.extcause := false.B
      newDcsr.cause := newCause
      newDcsr.prv := 3.U(2.W)
      newDcsr
    },
    (req.valid && dcsrEn) -> wdata.asTypeOf(new Dcsr(p)),
  ))
  val dpc_value = Mux(newCause === DebugCause.step, io.dm.next_pc, io.dm.current_pc)
  dpc := MuxCase(dpc, Seq(
    (req.valid && dpcEn) -> wdata,
    entering_debug_mode -> dpc_value,
  ))
  io.dm.debug_pc := MuxCase(MakeInvalid(UInt(p.fetchAddrBits.W)), Seq(
    (req.valid && dpcEn && mode === CsrMode.Debug) -> MakeValid(wdata),
  ))

  io.dm.dcsr_step := dcsr.step
  io.dm.single_step := trigger_enabled

  // High bit of mcause is set for an external interrupt.
  val interrupt = mcause(31)

  when (io.bru.in.mcause.valid) {
    mcause := io.bru.in.mcause.bits
  }

  when (io.bru.in.mtval.valid) {
    mtval := io.bru.in.mtval.bits
  }

  when (io.bru.in.mepc.valid) {
    mepc := io.bru.in.mepc.bits
  }

  if (p.enableFloat) {
    when (io.float.get.in.fflags.valid) {
      fflags := io.float.get.in.fflags.bits | fflags
    }
  }

  // Interrupt generation
  val in_debug = mode === CsrMode.Debug
  val interrupt_pending = (mtip_pending || meip_pending || msip_pending) && mstatus_mie && !in_debug

  io.bru.out.interrupt := interrupt_pending
  io.bru.out.interrupt_cause := MuxCase(0.U, Seq(
    meip_pending -> "x8000000B".U(32.W),
    msip_pending -> "x80000003".U(32.W),
    mtip_pending -> "x80000007".U(32.W),
  ))

  // Trap entry: save mstatus on trap (ecall, ebreak-trap, fault, or interrupt)
  val trap_taken = io.bru.in.mcause.valid
  when (trap_taken) {
    mstatus_mpie := mstatus_mie
    mstatus_mie  := false.B
  }

  // MRET: restore mstatus
  when (io.bru.in.mode.valid) {
    mstatus_mie  := mstatus_mpie
    mstatus_mpie := true.B
  }

  // Forwarding.
  io.bru.out.mode  := mode
  io.bru.out.mepc  := Mux(mepcEn && req.valid, wdata, mepc)
  io.bru.out.mtvec := Mux(mtvecEn && req.valid, wdata, mtvec)

  if (p.enableFloat) {
    io.float.get.out.frm := Mux(frmEn && req.valid, wdata(2,0), frm)
  }

  io.csr.out.value(0) := io.csr.in.value(12)
  io.csr.out.value(1) := mepc
  io.csr.out.value(2) := mtval
  io.csr.out.value(3) := mcause
  io.csr.out.value(4) := mcycle(31,0)
  io.csr.out.value(5) := mcycle(63,32)
  io.csr.out.value(6) := minstret(31,0)
  io.csr.out.value(7) := minstret(63,32)
  io.csr.out.value(8) := mcontext0

  // Write port.
  io.rd.valid := req.valid
  io.rd.bits.addr  := req.bits.addr
  io.rd.bits.data  := rdata

  io.trace.valid := req.valid && !(req.bits.op.isOneOf(CsrOp.CSRRS, CsrOp.CSRRC) && req.bits.rs1 === 0.U)
  io.trace.addr := req.bits.index
  io.trace.data := wdata

  // Assertions.
  assert(!(req.valid && !io.rs1.valid))
}
