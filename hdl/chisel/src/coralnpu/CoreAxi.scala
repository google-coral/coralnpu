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

import bus._
import common._
import dma.DmaCore

class CoreTlulInstrUser extends Bundle with TLUL_A_User_InstrType {
  val instr_type = UInt(4.W)
}

class ExtArbiter(
  p: TLULParameters,
  numHosts: Int,
  hostIsInstr: Seq[Boolean] = Nil
) extends Module {
  require(numHosts >= 2, "ExtArbiter requires at least 2 hosts")
  require(
    hostIsInstr.isEmpty || hostIsInstr.length == numHosts,
    "hostIsInstr length must match numHosts"
  )
  val hostIdBits  = log2Ceil(numHosts)
  val innerIdBits = p.o - hostIdBits
  require(
    innerIdBits > 0,
    s"Not enough TL-UL source ID bits (${p.o}) to encode $numHosts hosts"
  )

  val isInstrVec = VecInit(
    (if (hostIsInstr.isEmpty) Seq.fill(numHosts)(false) else hostIsInstr).map(_.B)
  )

  val io = IO(new Bundle {
    val hosts = Vec(numHosts, Flipped(new TLULHost2Device[NoUser, NoUser](p)))
    val out   = new TLULHost2Device(p, () => new CoreTlulInstrUser, () => new NoUser)
  })

  val pInner = p.shrinkId(hostIdBits)
  val arb    = Module(new Arbiter(new TileLink_A_Channel(pInner), numHosts))

  for (i <- 0 until numHosts) {
    arb.io.in(i).valid        := io.hosts(i).a.valid
    io.hosts(i).a.ready       := arb.io.in(i).ready
    arb.io.in(i).bits.opcode  := io.hosts(i).a.bits.opcode
    arb.io.in(i).bits.param   := io.hosts(i).a.bits.param
    arb.io.in(i).bits.size    := io.hosts(i).a.bits.size
    arb.io.in(i).bits.source  := io.hosts(i).a.bits.source(innerIdBits - 1, 0)
    arb.io.in(i).bits.address := io.hosts(i).a.bits.address
    arb.io.in(i).bits.mask    := io.hosts(i).a.bits.mask
    arb.io.in(i).bits.data    := io.hosts(i).a.bits.data
    arb.io.in(i).bits.user    := io.hosts(i).a.bits.user
  }

  io.out.a.valid                := arb.io.out.valid
  arb.io.out.ready              := io.out.a.ready
  io.out.a.bits.opcode          := arb.io.out.bits.opcode
  io.out.a.bits.param           := arb.io.out.bits.param
  io.out.a.bits.size            := arb.io.out.bits.size
  io.out.a.bits.source          := Cat(arb.io.chosen, arb.io.out.bits.source)
  io.out.a.bits.address         := arb.io.out.bits.address
  io.out.a.bits.mask            := arb.io.out.bits.mask
  io.out.a.bits.data            := arb.io.out.bits.data
  io.out.a.bits.user.instr_type := Mux(
    isInstrVec(arb.io.chosen),
    MuBi4.True.asUInt,
    MuBi4.False.asUInt
  )

  val dHost = io.out.d.bits.source(p.o - 1, innerIdBits)
  for (i <- 0 until numHosts) {
    io.hosts(i).d.valid       := io.out.d.valid && (dHost === i.U)
    io.hosts(i).d.bits        := io.out.d.bits
    io.hosts(i).d.bits.source := Cat(0.U(hostIdBits.W), io.out.d.bits.source(innerIdBits - 1, 0))
  }
  io.out.d.ready := MuxLookup(dHost, false.B)(
    (0 until numHosts).map(i => i.U -> io.hosts(i).d.ready)
  )
}

class CoreAxi(p: Parameters, coreModuleName: String) extends RawModule {
  override val desiredName = coreModuleName + "Axi"
  val memoryRegions        = p.m
  val io                   = IO(new Bundle {
    // AXI
    val aclk    = Input(Clock())
    val aresetn = Input(AsyncReset())
    // ITCM, DTCM, CSR
    val axi_slave  = Flipped(new AxiMasterIO(p.axi2AddrBits, p.axi2DataBits, p.axi2IdBits))
    val axi_master = new AxiMasterIO(p.axi2AddrBits, p.axi2DataBits, p.axi2IdBits)
    // Core status interrupts
    val halted = Output(Bool())
    val fault  = Output(Bool())
    val wfi    = Output(Bool())
    val irq    = Input(Bool())
    // Boot address (loaded into pcStartReg on reset)
    val boot_addr    = Input(UInt(p.fetchAddrBits.W))
    val timer_irq    = Input(Bool())
    val software_irq = Input(Bool())
    // Debug data interface
    val debug = Option.when(p.shouldExposeDebugPorts)(new DebugIO(p))
    val dm    = new DebugModuleIO(p)
    val te    = Input(Bool())
  })
  dontTouch(io)

  val rst_sync = Module(new RstSync())
  rst_sync.io.clk_i  := io.aclk
  rst_sync.io.rstn_i := io.aresetn
  rst_sync.io.clk_en := true.B
  rst_sync.io.te     := io.te

  val global_reset = (!Mux(io.te, io.aresetn, rst_sync.io.rstn_o).asBool).asAsyncReset
  withClockAndReset(rst_sync.io.clk_o, global_reset) {
    // Look up memory regions
    val itcmRegion = memoryRegions.find(_.memType == MemoryRegionType.IMEM).get
    val dtcmRegion = memoryRegions.find(_.memType == MemoryRegionType.DMEM).get
    val csrRegion  = memoryRegions.find(_.memType == MemoryRegionType.Peripheral).get
    val dmaRegion  =
      Option.when(p.enableDma)(memoryRegions.find(_.memType == MemoryRegionType.Dma).get)
    val csrAddrBits = log2Ceil(csrRegion.memSize)

    // Build CSR
    val csr = Module(new CoreTlulCSR(p, addrBits = csrAddrBits, extraIdBits = 1))
    csr.io.internal := false.B
    csr.io.bootAddr := io.boot_addr

    // Build core and connect with CSR
    val cg = Module(new ClockGate)
    cg.io.clk_i := rst_sync.io.clk_o
    cg.io.te    := io.te

    val dm = Module(new DebugModule(p))
    dontTouch(dm.io)
    val dmEnable = RegInit(false.B)
    dmEnable := true.B
    val dmReqArbiter = Module(new CoralNPURRArbiter(new DebugModuleReqIO(p), 2))
    dmReqArbiter.io.in(0) <> GateDecoupled(io.dm.req, dmEnable)
    dmReqArbiter.io.in(1) <> GateDecoupled(csr.io.debug.req, dmEnable)

    // Queue source ID of the request to route the response later.
    val inflight = Module(new Queue(UInt(1.W), 1))

    dm.io.ext.req.bits        := dmReqArbiter.io.out.bits
    dm.io.ext.req.valid       := dmReqArbiter.io.out.valid && inflight.io.enq.ready
    dmReqArbiter.io.out.ready := dm.io.ext.req.ready && inflight.io.enq.ready

    inflight.io.enq.bits  := dmReqArbiter.io.chosen
    inflight.io.enq.valid := dmReqArbiter.io.out.valid && dm.io.ext.req.ready

    val rspId = inflight.io.deq.bits
    inflight.io.deq.ready := dm.io.ext.rsp.fire

    csr.io.debug.rsp.bits := dm.io.ext.rsp.bits
    io.dm.rsp.bits        := dm.io.ext.rsp.bits

    csr.io.debug.rsp.valid := dm.io.ext.rsp.valid && inflight.io.deq.valid && (rspId === 1.U)
    io.dm.rsp.valid        := dm.io.ext.rsp.valid && inflight.io.deq.valid && (rspId === 0.U)

    dm.io.ext.rsp.ready := inflight.io.deq.valid && Mux(
      rspId === 1.U,
      csr.io.debug.rsp.ready,
      io.dm.rsp.ready
    )

    val core_reset =
      Mux(io.te, (!io.aresetn.asBool).asAsyncReset, (csr.io.reset || dm.io.ndmreset).asAsyncReset)
    val core = withClockAndReset(cg.io.clk_o, core_reset) { Core(p, coreModuleName) }

    // Register interrupts at the boundary to break timing paths to ibus.
    val irq_reg          = RegNext(io.irq, false.B)
    val timer_irq_reg    = RegNext(io.timer_irq, false.B)
    val software_irq_reg = RegNext(io.software_irq, false.B)

    cg.io.enable := irq_reg || timer_irq_reg || software_irq_reg || (!csr.io.cg && !core.io.wfi) || dm.io
      .haltreq(0)
    io.halted               := core.io.halted
    io.fault                := core.io.fault
    io.wfi                  := core.io.wfi
    core.io.irq             := irq_reg || dm.io.haltreq(0)
    core.io.timer_irq       := timer_irq_reg
    core.io.software_irq    := software_irq_reg
    csr.io.halted           := core.io.halted
    csr.io.fault            := core.io.fault
    csr.io.coralnpu_csr     := core.io.csr.out
    core.io.csr.in.value(0) := csr.io.pcStart
    for (i <- 1 until p.csrInCount) {
      core.io.csr.in.value(i) := 0.U
    }
    require(
      io.debug.isDefined == core.io.debug.isDefined,
      "Debug port presence mismatch between CoreAxi and Core"
    )
    io.debug.zip(core.io.debug).foreach { case (ioDebug, coreDebug) => ioDebug <> coreDebug }

    core.io.dm.debug_req  := dm.io.haltreq(0)
    core.io.dm.resume_req := dm.io.resumereq(0)
    dm.io.resumeack(0)    := !core.io.dm.debug_mode && RegNext(core.io.dm.debug_mode, false.B)
    dm.io.halted(0)       := core.io.dm.debug_mode
    dm.io.running(0)      := !core.io.dm.debug_mode
    dm.io.havereset(0)    := false.B
    core.io.dm.csr        := dm.io.csr
    core.io.dm.csr_rs1    := dm.io.csr_rs1
    dm.io.csr_rd          := core.io.dm.csr_rd
    dm.io.scalar_rd <> core.io.dm.scalar_rd
    dm.io.scalar_rs <> core.io.dm.scalar_rs
    if (p.enableFloat) {
      dm.io.float_rd.get <> core.io.dm.float_rd.get
      dm.io.float_rs.get <> core.io.dm.float_rs.get
    }

    val itcmBase = itcmRegion.memStart
    val dtcmBase = dtcmRegion.memStart

    // Helper function for banked routing
    def bankRouteFn(
      a: TileLink_A_Channel,
      region: MemoryRegion,
      numBanks: Int,
      bankSizeBytes: Int
    ): Seq[Bool] = {
      val addr    = a.address
      val inRange = region.contains(addr)
      val sel     = if (numBanks > 1) {
        val offset  = addr - region.memStart.U
        val bankSel = offset(log2Ceil(region.memSize) - 1, log2Ceil(bankSizeBytes))
        (0 until numBanks).map { j => inRange && (bankSel === j.U) }
      } else {
        Seq(inRange)
      }
      val errorSel = !inRange
      sel ++ Seq(errorSel)
    }

    // Helper function for AXI Slave router
    val slaveRouteFn = (a: TileLink_A_Channel) => {
      val inItcm  = itcmRegion.contains(a.address)
      val inDtcm  = dtcmRegion.contains(a.address)
      val inCsr   = csrRegion.contains(a.address)
      val inError = !inItcm && !inDtcm && !inCsr
      Seq(inItcm, inDtcm, inCsr, inError)
    }

    // -------------------------------------------------------------------------
    // Banked DTCM Setup
    val dtcmSizeBytes         = 1024 * p.dtcmSizeKBytes
    val dtcmNumBanks          = p.dtcmNumBanks
    val dtcmBankSizeBytes     = dtcmSizeBytes / dtcmNumBanks
    val dtcmBankBaseAddresses = (0 until dtcmNumBanks).map { i => dtcmBase + i * dtcmBankSizeBytes }
    val dtcmRouteFn           =
      (a: TileLink_A_Channel) => bankRouteFn(a, dtcmRegion, dtcmNumBanks, dtcmBankSizeBytes)

    // TODO(manyad): fix dma host priority at dtcm banks.
    val bankedDtcm = Module(
      new BankedDtcm(
        p = p.toTLUL(),
        numBanks = dtcmNumBanks,
        numHosts = if (p.enableDma) 5 else 4, // AXI RD, AXI WR, Core LSU, DM, DMA
        bankSizeBytes = dtcmBankSizeBytes,
        bankBaseAddresses = dtcmBankBaseAddresses,
        routeFn = dtcmRouteFn
      )
    )

    val dmaCore =
      Option.when(p.enableDma)(Module(new DmaCore(deviceP = p.toTLUL(), hostP = p.toTLUL())))

    // -------------------------------------------------------------------------
    // Banked ITCM Setup
    val itcmSizeBytes         = 1024 * p.itcmSizeKBytes
    val itcmNumBanks          = p.itcmNumBanks
    val itcmBankSizeBytes     = itcmSizeBytes / itcmNumBanks
    val itcmBankBaseAddresses = (0 until itcmNumBanks).map { i => itcmBase + i * itcmBankSizeBytes }
    val itcmRouteFn           =
      (a: TileLink_A_Channel) => bankRouteFn(a, itcmRegion, itcmNumBanks, itcmBankSizeBytes)

    val bankedItcm = Module(
      new BankedItcm(
        p = p.toTLUL(),
        numBanks = itcmNumBanks,
        numHosts = 5, // AXI RD, AXI WR, Core Fetch, Core LSU, DM
        bankSizeBytes = itcmBankSizeBytes,
        bankBaseAddresses = itcmBankBaseAddresses,
        routeFn = itcmRouteFn
      )
    )

    // -------------------------------------------------------------------------
    // TL-UL Routers for AXI Slave
    // Route to 3 destinations: 0 -> ITCM, 1 -> DTCM, 2 -> CSR
    val readRouter = Module(
      new TlulRouter(
        p = p.toTLUL(),
        n = 3,
        route = slaveRouteFn
      )
    )

    val writeRouter = Module(
      new TlulRouter(
        p = p.toTLUL(),
        n = 3,
        route = slaveRouteFn
      )
    )

    // AXI Slave Converters
    val axiReadConv  = Module(new AxiRead2TLUL(p.toTLUL()))
    val axiWriteConv = Module(new AxiWrite2TLUL(p.toTLUL()))

    val axiEnable = RegInit(false.B)
    axiEnable := true.B

    // Connect AXI Slave to Routers
    axiReadConv.io.axiRead.addr <> GateDecoupled(io.axi_slave.read.addr, axiEnable)
    io.axi_slave.read.data <> GateDecoupled(axiReadConv.io.axiRead.data, axiEnable)
    readRouter.io.tl_h <> axiReadConv.io.tl

    axiWriteConv.io.axiWrite.addr <> GateDecoupled(io.axi_slave.write.addr, axiEnable)
    axiWriteConv.io.axiWrite.data <> GateDecoupled(io.axi_slave.write.data, axiEnable)
    io.axi_slave.write.resp <> GateDecoupled(axiWriteConv.io.axiWrite.resp, axiEnable)
    writeRouter.io.tl_h <> axiWriteConv.io.tl

    // Connect Routers to Banked Memories
    bankedItcm.io.tl_h(0) <> readRouter.io.tl_d(0)
    bankedItcm.io.tl_h(1) <> writeRouter.io.tl_d(0)

    bankedDtcm.io.tl_h(0) <> readRouter.io.tl_d(1)
    bankedDtcm.io.tl_h(1) <> writeRouter.io.tl_d(1)

    // Connect Routers to CSR (via Arbiter), stripping region base address
    val csrArbiter = Module(new TlulArbiter(p.toTLUL(), M = 2))
    csrArbiter.io.tl_h(0) <> readRouter.io.tl_d(2)
    csrArbiter.io.tl_h(1) <> writeRouter.io.tl_d(2)
    val csrOffset = (csrArbiter.io.tl_d.a.bits.address - csrRegion.memStart.U)(csrAddrBits - 1, 0)
    csrArbiter.io.tl_d.connectNarrowAddr(csr.io.tl, csrOffset)

    // -------------------------------------------------------------------------
    // Core Bus Connections
    val coreClkEn     = cg.io.enable || io.te
    val coreSoftReset = !io.te && (csr.io.reset || dm.io.ndmreset)

    // Instruction Fetch Bridge & Router
    val fetchBridge = Module(new CoreDomainTlulBridge(p.toTLUL(), maxOutstanding = 2))
    fetchBridge.io.coreClkEn := coreClkEn
    fetchBridge.io.coreReset := coreSoftReset
    fetchBridge.io.tl_h <> core.io.tlul_fetch

    val fetchRouteFn = (a: TileLink_A_Channel) => {
      val inItcm  = itcmRegion.contains(a.address)
      val inDtcm  = dtcmRegion.contains(a.address)
      val inCsr   = csrRegion.contains(a.address)
      val inError =
        if (p.enableDma) inDtcm || inCsr || dmaRegion.get.contains(a.address)
        else inDtcm || inCsr
      val isExternal = !inItcm && !inError
      if (p.enableAxiInstructionFetch) {
        Seq(inItcm, isExternal, inError)
      } else {
        Seq(inItcm, false.B, inError || isExternal)
      }
    }

    val fetchRouter = Module(new TlulRouter(p.toTLUL(), n = 2, route = fetchRouteFn))
    fetchRouter.io.tl_h <> fetchBridge.io.tl_d
    bankedItcm.io.tl_h(2) <> fetchRouter.io.tl_d(0)

    val lsuBridge =
      Module(new CoreDomainTlulBridge(p.toTLUL(), maxOutstanding = p.lsuSlotTxidEntries))
    lsuBridge.io.coreClkEn := coreClkEn
    lsuBridge.io.coreReset := coreSoftReset
    lsuBridge.io.tl_h <> core.io.tlul_lsu

    val masterRouteFn = (a: TileLink_A_Channel) => {
      val inItcm    = itcmRegion.contains(a.address)
      val validItcm = inItcm && (a.opcode === TLULOpcodesA.Get.asUInt)
      val inDtcm    = dtcmRegion.contains(a.address)
      val inCsr     = csrRegion.contains(a.address)
      val inError   = inCsr || (inItcm && (a.opcode =/= TLULOpcodesA.Get.asUInt))
      if (p.enableDma) {
        val inDma      = dmaRegion.get.contains(a.address)
        val isExternal = !inDtcm && !inItcm && !inCsr && !inDma
        Seq(inDtcm, validItcm, isExternal, inDma, inError)
      } else {
        val isExternal = !inDtcm && !inItcm && !inCsr
        Seq(inDtcm, validItcm, isExternal, inError)
      }
    }

    val tlulRouter =
      Module(new TlulRouter(p.toTLUL(), n = if (p.enableDma) 4 else 3, route = masterRouteFn))
    tlulRouter.io.tl_h <> lsuBridge.io.tl_d
    bankedDtcm.io.tl_h(2) <> tlulRouter.io.tl_d(0)
    bankedItcm.io.tl_h(3) <> tlulRouter.io.tl_d(1)
    dmaCore.foreach(_.io.tl_device <> tlulRouter.io.tl_d(3))

    val dmRouteFn = (a: TileLink_A_Channel) => {
      val inItcm = itcmRegion.contains(a.address)
      val inDtcm = dtcmRegion.contains(a.address)
      val inCsr  = csrRegion.contains(a.address)
      if (p.enableDma) {
        val inDma      = dmaRegion.get.contains(a.address)
        val isExternal = !inItcm && !inDtcm && !inCsr && !inDma
        Seq(inItcm, inDtcm, isExternal, inCsr || inDma)
      } else {
        val isExternal = !inItcm && !inDtcm && !inCsr
        Seq(inItcm, inDtcm, isExternal, inCsr)
      }
    }

    val dmRouter = Module(new TlulRouter(p.toTLUL(), n = 3, route = dmRouteFn))
    dmRouter.io.tl_h <> dm.io.tlul
    bankedItcm.io.tl_h(4) <> dmRouter.io.tl_d(0)
    bankedDtcm.io.tl_h(3) <> dmRouter.io.tl_d(1)

    val dmaExtHost = Option.when(p.enableDma) {
      val dmaRouteFn = (a: TileLink_A_Channel) => {
        val inItcm     = itcmRegion.contains(a.address)
        val inDtcm     = dtcmRegion.contains(a.address)
        val inCsr      = csrRegion.contains(a.address)
        val inDma      = dmaRegion.get.contains(a.address)
        val isExternal = !inItcm && !inDtcm && !inCsr && !inDma
        val inError    = inItcm || inCsr || inDma
        Seq(inDtcm, isExternal, inError)
      }

      val dmaRouter = Module(new TlulRouter(p.toTLUL(), n = 2, route = dmaRouteFn))
      dmaRouter.io.tl_h <> dmaCore.get.io.tl_host
      bankedDtcm.io.tl_h(4) <> dmaRouter.io.tl_d(0)

      // Lanes are source[3:0]. Fill and drain can share a lane when fill starts the next
      // pass while drain's last Puts are still unacked; the remapper stalls that request,
      // which costs throughput only.
      val dmaExtP       = p.toTLUL().shrinkId(2)
      val dmaIdRemapper = Module(
        new TlulIdRemapper(p.toTLUL(), dmaExtP, () => new NoUser, () => new NoUser)
      )
      dmaIdRemapper.io.tl_a_in <> dmaRouter.io.tl_d(1).a
      dmaRouter.io.tl_d(1).d <> dmaIdRemapper.io.tl_d_out

      val dmaExtHostWire = Wire(new TLULHost2Device[NoUser, NoUser](p.toTLUL()))
      dmaExtHostWire.a <> dmaIdRemapper.io.tl_a_out
      dmaIdRemapper.io.tl_d_in.valid       := dmaExtHostWire.d.valid
      dmaExtHostWire.d.ready               := dmaIdRemapper.io.tl_d_in.ready
      dmaIdRemapper.io.tl_d_in.bits        := dmaExtHostWire.d.bits
      dmaIdRemapper.io.tl_d_in.bits.source := dmaExtHostWire.d.bits.source(dmaExtP.o - 1, 0)
      dmaExtHostWire
    }

    val tlul2Axi = Module(
      new TLUL2Axi(
        p.toTLUL(),
        p.axi2DataBits,
        p.axi2AddrBits,
        p.axi2IdBits,
        () => new CoreTlulInstrUser,
        () => new NoUser,
        maxReadTx = p.tlul2AxiMaxReadTx,
        maxWriteTx = p.tlul2AxiMaxWriteTx
      )
    )

    if (p.enableAxiInstructionFetch) {
      val extArbiter = Module(
        new ExtArbiter(
          p.toTLUL(),
          numHosts = if (p.enableDma) 4 else 3,
          hostIsInstr = Seq(false, false, true) ++ Option.when(p.enableDma)(false)
        )
      )
      extArbiter.io.hosts(0) <> tlulRouter.io.tl_d(2)
      extArbiter.io.hosts(1) <> dmRouter.io.tl_d(2)
      extArbiter.io.hosts(2) <> fetchRouter.io.tl_d(1)
      dmaExtHost.foreach(extArbiter.io.hosts(3) <> _)

      tlul2Axi.io.tl_a <> extArbiter.io.out.a
      extArbiter.io.out.d <> tlul2Axi.io.tl_d
    } else {
      fetchRouter.io.tl_d(1).a.ready := false.B
      fetchRouter.io.tl_d(1).d.valid := false.B
      fetchRouter.io.tl_d(1).d.bits  := DontCare

      val extArbiter = Module(
        new ExtArbiter(
          p.toTLUL(),
          numHosts = if (p.enableDma) 3 else 2,
          hostIsInstr = Seq(false, false) ++ Option.when(p.enableDma)(false)
        )
      )
      extArbiter.io.hosts(0) <> tlulRouter.io.tl_d(2)
      extArbiter.io.hosts(1) <> dmRouter.io.tl_d(2)
      dmaExtHost.foreach(extArbiter.io.hosts(2) <> _)

      tlul2Axi.io.tl_a <> extArbiter.io.out.a
      extArbiter.io.out.d <> tlul2Axi.io.tl_d
    }

    io.axi_master.write.addr <> GateDecoupled(tlul2Axi.io.axi.write.addr, axiEnable)
    io.axi_master.write.data <> GateDecoupled(tlul2Axi.io.axi.write.data, axiEnable)
    tlul2Axi.io.axi.write.resp <> GateDecoupled(io.axi_master.write.resp, axiEnable)
    io.axi_master.read.addr <> GateDecoupled(tlul2Axi.io.axi.read.addr, axiEnable)
    tlul2Axi.io.axi.read.data <> GateDecoupled(io.axi_master.read.data, axiEnable)
  }
}
