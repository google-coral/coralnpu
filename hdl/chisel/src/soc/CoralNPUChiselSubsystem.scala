package coralnpu.soc

import chisel3._
import bus._
import coralnpu.Parameters
import coralnpu.MemorySize
import coralnpu.CoreTlul
import common.MuBi4

/** This is the IO bundle for the unified Chisel subsystem.
  */
class CoralNPUChiselSubsystemIO(
  val hostParams: Seq[bus.TLULParameters],
  val deviceParams: Seq[bus.TLULParameters],
  val enableTestHarness: Boolean,
  val itcmSize: MemorySize,
  val dtcmSize: MemorySize,
  val xlen: Int = 32
) extends Bundle {
  val cfg = SoCChiselConfig(itcmSize, dtcmSize, xlen).crossbar

  // --- Clocks and Resets ---
  val clk_i  = Input(Clock())
  val rst_ni = Input(AsyncReset())

  // --- Dynamic Asynchronous Clock/Reset Ports ---
  val asyncHostDomains =
    cfg.hosts(enableTestHarness).map(_.clockDomain).distinct.filter(_ != "main")
  val async_ports_hosts = new DataRecord(asyncHostDomains.map(d => d -> new ClockResetBundle))

  val asyncDeviceDomains  = cfg.devices.map(_.clockDomain).distinct.filter(_ != "main")
  val async_ports_devices = new DataRecord(asyncDeviceDomains.map(d => d -> new ClockResetBundle))

  // --- Identify Internal vs. External Connections ---
  val internalHosts =
    SoCChiselConfig(itcmSize, dtcmSize, xlen).modules.flatMap(_.hostConnections.values).toSet
  val internalDevices =
    SoCChiselConfig(itcmSize, dtcmSize, xlen).modules.flatMap(_.deviceConnections.values).toSet

  // These devices are handled specially within the subsystem (e.g., converted to AXI)
  // and should not have external TileLink ports created for them.
  val speciallyHandledDevices = Set("ddr_ctrl", "ddr_mem")
  // Note: SpeciallyHandledHosts modified to matches the XBAR port names to accomodate multiple hosts in one IP
  val speciallyHandledHosts = Set("ispyocto_m1", "ispyocto_m2")

  val externalHostPorts = cfg
    .hosts(enableTestHarness)
    .filterNot(h => internalHosts.contains(h.name) || speciallyHandledHosts.contains(h.name))
  val externalDevicePorts = cfg.devices.filterNot(d =>
    internalDevices.contains(d.name) || speciallyHandledDevices.contains(d.name)
  )

  // --- Create External TileLink Ports ---
  val external_hosts = Flipped(new TLBundleMap(externalHostPorts.map { h =>
    h.name -> hostParams(cfg.hosts(enableTestHarness).indexWhere(_.name == h.name))
  }))

  val external_devices = new TLBundleMap(externalDevicePorts.map { d =>
    d.name -> deviceParams(cfg.devices.indexWhere(_.name == d.name))
  })

  // --- Manually define peripheral ports for now ---
  val allExternalPortsConfig =
    SoCChiselConfig(itcmSize, dtcmSize, xlen).modules.flatMap(_.externalPorts)
  val external_ports = new DataRecord(allExternalPortsConfig.map { p =>
    val port = p.portType match {
      case coralnpu.soc.Clk          => Clock()
      case coralnpu.soc.Bool         => Bool()
      case coralnpu.soc.Logic(width) => UInt(width.W)
      case coralnpu.soc.Custom(gen)  => gen()
    }
    p.name -> (if (p.direction == coralnpu.soc.In) Input(port) else Output(port))
  })

  val p            = new Parameters(xlen = xlen)
  val ddrCtrlWidth = cfg.devices.find(_.name == "ddr_ctrl").get.width
  val ddrMemWidth  = cfg.devices.find(_.name == "ddr_mem").get.width
  val ddr_ctrl_axi = new AxiMasterIO(xlen, ddrCtrlWidth, p.axi2IdBits)
  // We specify the 256-bit AXI width and 1-bit ID for DDR here.
  // The output from the Xbar is 128-bits / 6-bits, and we instantiate
  // width and TL->AXI bridges elsewhere to adapt the interfaces.
  val ddr_mem_axi = new AxiMasterIO(xlen, 256, 1)

  // ISP Ports (Manual exposure for FPGA integration)
  // Control Interface (Slave): CPU -> Xbar -> ISP
  // Using generic Host2Device bundle
  val ispyocto_ctrl = new OpenTitanTileLink.Host2Device(
    deviceParams(cfg.devices.indexWhere(_.name == "ispyocto_ctrl"))
  )

  // Master Interfaces (Master): ISP -> AXI2TLUL -> Xbar -> Memory
  // Need Flipped AxiMasterIO because Subsystem acts as Slave to ISP
  val ispyocto_m1_axi = Flipped(new AxiMasterIO(xlen, 64, 4))
  val ispyocto_m2_axi = Flipped(new AxiMasterIO(xlen, 64, 4))
}

import chisel3.experimental.BaseModule
import chisel3.reflect.DataMirror
import scala.collection.mutable

/** A generator for the entire Chisel-based subsystem of the CoralNPU SoC.
  */
class CoralNPUChiselSubsystem(
  val hostParams: Seq[bus.TLULParameters],
  val deviceParams: Seq[bus.TLULParameters],
  val enableTestHarness: Boolean,
  val itcmSize: MemorySize,
  val dtcmSize: MemorySize,
  val xlen: Int = 32,
  val moduleName: String = ""
) extends RawModule {
  val testHarnessSuffix    = if (enableTestHarness) "TestHarness" else ""
  override val desiredName = {
    val xlenSuffix  = if (xlen == 32) "" else s"${xlen}"
    val defaultName =
      if (
        itcmSize.kBytes == Parameters.itcmSizeKBytesDefault && dtcmSize.kBytes == Parameters.dtcmSizeKBytesDefault
      ) {
        s"CoralNPUChiselSubsystem$xlenSuffix"
      } else if (
        itcmSize.kBytes == Parameters.itcmSizeKBytesHighmem && dtcmSize.kBytes == Parameters.dtcmSizeKBytesHighmem
      ) {
        s"CoralNPUChiselSubsystemHighmem$xlenSuffix"
      } else {
        s"CoralNPUChiselSubsystem_ITCM${itcmSize.kBytes}KB_DTCM${dtcmSize.kBytes}KB$xlenSuffix"
      }
    (if (moduleName.isEmpty) defaultName else moduleName) + testHarnessSuffix
  }
  val io = IO(
    new CoralNPUChiselSubsystemIO(
      hostParams,
      deviceParams,
      enableTestHarness,
      itcmSize,
      dtcmSize,
      xlen
    )
  )
  val cfg = SoCChiselConfig(itcmSize, dtcmSize, xlen).crossbar

  /** A helper function to recursively traverse a Chisel Bundle and populate a map with the full
    * hierarchical path to every port and sub-port.
    */
  def populatePorts(prefix: String, data: Data, map: mutable.Map[String, Data]): Unit = {
    map(prefix) = data
    data match {
      case b: Record =>
        b.elements.foreach { case (name, child) =>
          populatePorts(s"$prefix.$name", child, map)
        }
      case v: Vec[_] =>
        v.zipWithIndex.foreach { case (child, i) =>
          populatePorts(s"$prefix($i)", child, map)
        }
      case _ => // Leaf element
    }
  }

  withClockAndReset(io.clk_i, (!io.rst_ni.asBool).asAsyncReset) {
    // --- 1. Instantiate spi2tlul first (with hardware reset) ---
    val spi2tlul_config =
      SoCChiselConfig(itcmSize, dtcmSize, xlen).modules.find(_.name == "spi2tlul").get
    val spi2tlul = {
      val p          = spi2tlul_config.params.asInstanceOf[Spi2TlulParameters]
      val spi2tlul_p = new Parameters(xlen = xlen)
      spi2tlul_p.lsuDataBits = p.lsuDataBits
      spi2tlul_p.axi2IdBits = 8
      val m = Module(new Spi2TLUL(spi2tlul_p.toTLUL()))
      m.suggestName("spi2tlul")
      m
    }

    // --- 2. Define combined reset (active-low for modules expecting rst_ni) ---
    val soft_reset     = spi2tlul.io.sys_rst_o
    val raw_combined_n = io.rst_ni.asBool && !soft_reset
    val combined_rst_n = withClockAndReset(io.clk_i, (!raw_combined_n).asAsyncReset) {
      val r1 = RegInit(false.B)
      val r2 = RegInit(false.B)
      r1 := true.B
      r2 := r1
      r2
    }

    // --- 3. Instantiate xbar (with combined reset) ---
    val xbar = withClockAndReset(io.clk_i, (!combined_rst_n).asAsyncReset) {
      Module(new CoralNPUXbar(hostParams, deviceParams, enableTestHarness, itcmSize, dtcmSize))
    }

    // --- 4. Dynamic Module Instantiation helper (with combined reset) ---
    def instantiateModule(config: ChiselModuleConfig): BaseModule = {
      withClockAndReset(io.clk_i, (!combined_rst_n).asAsyncReset) {
        config.params match {
          case p: CoreTlulParameters =>
            val core_p = new Parameters(xlen = xlen)
            core_p.m = p.memoryRegions
            core_p.lsuDataBits = p.lsuDataBits
            core_p.enableRvv = p.enableRvv
            core_p.enableFetchL0 = p.enableFetchL0
            core_p.fetchDataBits = p.fetchDataBits
            core_p.enableFloat = p.enableFloat
            core_p.enableZfbfmin = p.enableZfbfmin
            core_p.enableVectorBf16 = p.enableVectorBf16
            core_p.itcmSizeKBytes = itcmSize.kBytes
            core_p.dtcmSizeKBytes = dtcmSize.kBytes
            Module(new CoreTlul(core_p, config.name))

          case p: Spi2TlulParameters => null

          case p: SpiMasterParameters =>
            val spi_p = new Parameters(xlen = xlen)
            spi_p.lsuDataBits = p.lsuDataBits
            spi_p.axi2IdBits = 10
            Module(new SpiMaster(spi_p.toTLUL()))

          case p: GPIOModuleParameters =>
            val gpio_p = new Parameters(xlen = xlen)
            gpio_p.lsuDataBits = 32
            gpio_p.axi2IdBits = 10
            val gp = bus.GPIOParameters(width = p.width)
            Module(new bus.GPIO(gpio_p.toTLUL(), gp))

          case p: DmaParameters =>
            val host_p = new Parameters(xlen = xlen)
            host_p.lsuDataBits = p.hostDataBits
            val device_p = new Parameters(xlen = xlen)
            device_p.lsuDataBits = p.deviceDataBits
            device_p.axi2IdBits = 10
            Module(new bus.DmaEngine(host_p.toTLUL(), device_p.toTLUL()))

          case ClintParameters =>
            val clint_p = new Parameters(xlen = xlen)
            clint_p.lsuDataBits = 32
            clint_p.axi2IdBits = 10
            Module(new bus.Clint(clint_p.toTLUL()))

          case p: PlicParameters =>
            val plic_p = new Parameters(xlen = xlen)
            plic_p.lsuDataBits = 32
            plic_p.axi2IdBits = 10
            Module(new bus.Plic(plic_p.toTLUL(), p.numInterrupts, p.priorityWidth))

          case p: TlulSramParameters =>
            val sram_p = new Parameters(xlen = xlen)
            sram_p.lsuDataBits = 128
            sram_p.axi2IdBits = 8
            Module(new TlulSram(sram_p, p.sramSizeBytes, p.globalBaseAddr))

          case p: IspParameters => null // Handled externally
        }
      }
    }

    // --- 5. Instantiate other modules ---
    val otherModules = SoCChiselConfig(itcmSize, dtcmSize).modules
      .filter(_.name != "spi2tlul")
      .flatMap { config =>
        val m = instantiateModule(config)
        if (m != null) {
          m.suggestName(config.name)
          Some(config.name -> m)
        } else {
          None
        }
      }
      .toMap

    val instantiatedModules = otherModules + ("spi2tlul" -> spi2tlul)

    // --- Dynamic Wiring ---
    // Note: SpeciallyHandledHosts modified to matches the XBAR port names to accomodate multiple hosts in one IP
    val speciallyHandledHosts = Set("ispyocto_m1", "ispyocto_m2")

    // Create a map of all ports on all instantiated modules for easy lookup.
    val modulePorts = mutable.Map[String, Data]()
    instantiatedModules.foreach { case (moduleName, module) =>
      DataMirror.modulePorts(module).foreach { case (portName, port) =>
        populatePorts(s"$moduleName.$portName", port, modulePorts)
      }
    }

    // --- Clock & Reset Connections ---
    instantiatedModules.foreach { case (name, module) =>
      modulePorts.get(s"$name.io.clk").foreach(_ := io.clk_i)
      modulePorts.get(s"$name.io.clk_i").foreach(_ := io.clk_i)
      modulePorts.get(s"$name.io.clock").foreach(_ := io.clk_i)

      val m_rst_ni = if (name == "spi2tlul") io.rst_ni else combined_rst_n.asAsyncReset
      val m_reset  =
        if (name == "spi2tlul") (!io.rst_ni.asBool).asAsyncReset else (!combined_rst_n).asAsyncReset

      modulePorts.get(s"$name.io.rst_ni").foreach(_ := m_rst_ni)
      modulePorts.get(s"$name.io.reset").foreach(_ := m_reset)
    }

    // Connect all modules based on the configuration.
    SoCChiselConfig(itcmSize, dtcmSize).modules
      .filter(c => instantiatedModules.contains(c.name))
      .foreach { config =>
        config.hostConnections.foreach { case (modulePort, xbarPort) =>
          if (!speciallyHandledHosts.contains(xbarPort)) {
            modulePorts(s"${config.name}.$modulePort") <> xbar.io.hosts(xbarPort)
          }
        }
        config.deviceConnections.foreach { case (modulePort, xbarPort) =>
          xbar.io.devices(xbarPort) <> modulePorts(s"${config.name}.$modulePort")
        }
        config.externalPorts.foreach { extPort =>
          val moduleIo = modulePorts(s"${config.name}.${extPort.modulePort}")
          val topIo    = io.external_ports(extPort.name)
          if (extPort.direction == In) {
            if (topIo.getClass == moduleIo.getClass) moduleIo := topIo
            else moduleIo := topIo.asTypeOf(chiselTypeOf(moduleIo))
          } else {
            if (topIo.getClass == moduleIo.getClass) topIo := moduleIo
            else topIo                                     := moduleIo.asTypeOf(chiselTypeOf(topIo))
          }
        }
      }

    // Connect external-facing TileLink ports
    io.externalHostPorts.map(_.name).foreach { name =>
      xbar.io.hosts(name) <> io.external_hosts(name)
    }
    io.externalDevicePorts.map(_.name).foreach { name =>
      io.external_devices(name) <> xbar.io.devices(name)
    }

    // Connect async clocks
    io.asyncHostDomains.foreach { domainName =>
      val xbarPort = xbar.io.async_ports_hosts(domainName).asInstanceOf[ClockResetBundle]
      val ioPort   = io.async_ports_hosts(domainName).asInstanceOf[ClockResetBundle]
      xbarPort.clock := ioPort.clock
      xbarPort.reset := ioPort.reset
    }

    io.asyncDeviceDomains.foreach { domainName =>
      val xbarPort = xbar.io.async_ports_devices(domainName).asInstanceOf[ClockResetBundle]
      val ioPort   = io.async_ports_devices(domainName).asInstanceOf[ClockResetBundle]
      xbarPort.clock := ioPort.clock
      xbarPort.reset := ioPort.reset
    }

    // --- Wire CLINT mtip/msip to core timer_irq/software_irq ---
    // Override the external port connections: connect clint's mtip directly to core's timer_irq
    val clintMtip    = modulePorts("clint.io.mtip")
    val coreTimerIrq = modulePorts("rvv_core.io.timer_irq")
    coreTimerIrq := clintMtip

    val clintMsip       = modulePorts("clint.io.msip")
    val coreSoftwareIrq = modulePorts("rvv_core.io.software_irq")
    coreSoftwareIrq := clintMsip

    // --- Wire PLIC irq to core irq ---
    val plicIrq = modulePorts("plic.io.irq")
    val coreIrq = modulePorts("rvv_core.io.irq")
    coreIrq := plicIrq

    // --- DDR AXI Interface ---
    val ddrAsyncPorts = io.async_ports_devices("ddr").asInstanceOf[ClockResetBundle]
    val ddr_clk       = ddrAsyncPorts.clock
    val ddr_rst       = ddrAsyncPorts.reset

    val ddr_ctrl_tlul_p = deviceParams(cfg.devices.indexWhere(_.name == "ddr_ctrl"))
    val ddr_ctrl_axi_p  = new Parameters(xlen = xlen)
    ddr_ctrl_axi_p.lsuDataBits = ddr_ctrl_tlul_p.w * 8
    val ddr_ctrl_axi_conv = Module(
      new TLUL2Axi(
        ddr_ctrl_tlul_p,
        ddr_ctrl_axi_p.axi2DataBits,
        ddr_ctrl_axi_p.axi2AddrBits,
        ddr_ctrl_axi_p.axi2IdBits,
        () => new OpenTitanTileLink_A_User,
        () => new OpenTitanTileLink_D_User
      )
    )
    ddr_ctrl_axi_conv.clock := ddr_clk
    ddr_ctrl_axi_conv.reset := ddr_rst
    ddr_ctrl_axi_conv.io.tl_a <> xbar.io.devices("ddr_ctrl").a
    ddr_ctrl_axi_conv.io.tl_d <> xbar.io.devices("ddr_ctrl").d
    io.ddr_ctrl_axi <> ddr_ctrl_axi_conv.io.axi

    // --- DDR Memory AXI Interface (128-bit TL -> 256-bit TL -> 256-bit AXI) ---
    // Define parameters for the 256-bit bus that exists AFTER the width bridge.
    val ddr_mem_256_tlul_p = new bus.TLULParameters(
      dataBits = 256,
      addrBits = xlen,
      idBits = 10
    )

    // Define parameters for the final 256-bit AXI port.
    val ddr_mem_axi_p = {
      val p = new Parameters(xlen = xlen)
      p.lsuDataBits = 256
      p.axi2IdBits = 1
      p
    }

    // Instantiate the bridge: 128-bit (from xbar) to 256-bit.
    val ddr_mem_bridge = Module(new TlulWidthBridge(xbar.commonParams, ddr_mem_256_tlul_p))

    // Instantiate the AXI converter: 256-bit TL to 256-bit AXI.
    val ddr_mem_axi_conv = Module(
      new TLUL2Axi(
        ddr_mem_256_tlul_p,
        ddr_mem_axi_p.axi2DataBits,
        ddr_mem_axi_p.axi2AddrBits,
        ddr_mem_axi_p.axi2IdBits,
        () => new OpenTitanTileLink_A_User,
        () => new OpenTitanTileLink_D_User
      )
    )

    ddr_mem_bridge.clock   := ddr_clk
    ddr_mem_bridge.reset   := ddr_rst
    ddr_mem_axi_conv.clock := ddr_clk
    ddr_mem_axi_conv.reset := ddr_rst

    // Wire the components together: Xbar (128) -> Bridge -> AXI Conv (256) -> IO (256)
    ddr_mem_bridge.io.tl_h <> xbar.io.devices("ddr_mem")
    ddr_mem_axi_conv.io.tl_a <> ddr_mem_bridge.io.tl_d.a
    ddr_mem_bridge.io.tl_d.d <> ddr_mem_axi_conv.io.tl_d
    io.ddr_mem_axi <> ddr_mem_axi_conv.io.axi

    // --- ISP Integration (Manual Wiring) ---
    // Wired to external IOs instead of internal module.

    // 1. Control Interface (TLUL Slave)
    // Map Config Port ["ispyocto_ctrl"] -> IO
    io.ispyocto_ctrl <> xbar.io.devices("ispyocto_ctrl")

    // 2. AXI Master 1 -> TLUL Host
    // Map IO [AXI] -> Bridge -> Xbar Port ["ispyocto_m1"]
    val ispAsyncPorts = io.async_ports_hosts("isp_axi_clk").asInstanceOf[ClockResetBundle]
    val m1HostName    = "ispyocto_m1"
    val ispAxiParams  = new Parameters(xlen = xlen)
    ispAxiParams.lsuDataBits = 64

    val axibm1 = withClockAndReset(ispAsyncPorts.clock, ispAsyncPorts.reset) {
      Module(
        new Axi2TLUL(
          ispAxiParams.toTLUL(),
          () => new OpenTitanTileLink_A_User,
          () => new OpenTitanTileLink_D_User
        )
      )
    }
    axibm1.io.axi <> io.ispyocto_m1_axi
    xbar.io.hosts(m1HostName).a.valid                := axibm1.io.tl_a.valid
    axibm1.io.tl_a.ready                             := xbar.io.hosts(m1HostName).a.ready
    xbar.io.hosts(m1HostName).a.bits                 := axibm1.io.tl_a.bits
    xbar.io.hosts(m1HostName).a.bits.user.instr_type := MuBi4.False.asUInt
    axibm1.io.tl_d <> xbar.io.hosts(m1HostName).d

    // 3. AXI Master 2 -> TLUL Host
    // Map IO [AXI] -> Bridge -> Xbar Port ["ispyocto_m2"]
    val m2HostName = "ispyocto_m2"

    val axibm2 = withClockAndReset(ispAsyncPorts.clock, ispAsyncPorts.reset) {
      Module(
        new Axi2TLUL(
          ispAxiParams.toTLUL(),
          () => new OpenTitanTileLink_A_User,
          () => new OpenTitanTileLink_D_User
        )
      )
    }
    axibm2.io.axi <> io.ispyocto_m2_axi
    xbar.io.hosts(m2HostName).a.valid                := axibm2.io.tl_a.valid
    axibm2.io.tl_a.ready                             := xbar.io.hosts(m2HostName).a.ready
    xbar.io.hosts(m2HostName).a.bits                 := axibm2.io.tl_a.bits
    xbar.io.hosts(m2HostName).a.bits.user.instr_type := MuBi4.False.asUInt
    axibm2.io.tl_d <> xbar.io.hosts(m2HostName).d
  }
}

import _root_.circt.stage.ChiselStage
import java.nio.charset.StandardCharsets
import java.nio.file.{Files, Paths, StandardOpenOption}
import coralnpu.Parameters

object CoralNPUChiselSubsystemEmitter extends App {
  val enableTestHarness = args.contains("--enableTestHarness")

  // --- Parse command-line arguments for TCM sizes ---
  var itcmSizeKBytes = Parameters.itcmSizeKBytesDefault // Default ITCM size in KBytes
  var dtcmSizeKBytes = Parameters.dtcmSizeKBytesDefault // Default DTCM size in KBytes
  var xlen           = 32
  var moduleName     = ""
  args.sliding(2, 1).foreach {
    case Array("--itcmSizeKBytes", size) => itcmSizeKBytes = size.toInt
    case Array("--dtcmSizeKBytes", size) => dtcmSizeKBytes = size.toInt
    case Array("--xlen", size)           => xlen = size.toInt
    case Array("--moduleName", name)     => moduleName = name
    case _                               =>
  }

  val itcmSize = MemorySize.fromKBytes(itcmSizeKBytes)
  val dtcmSize = MemorySize.fromKBytes(dtcmSizeKBytes)

  val flagsWithValues = Set("--itcmSizeKBytes", "--dtcmSizeKBytes", "--xlen", "--moduleName")
  val indicesToSkip   = args.zipWithIndex
    .collect {
      case (arg, idx) if flagsWithValues.contains(arg) => Seq(idx, idx + 1)
    }
    .flatten
    .toSet

  val chiselArgs = args.zipWithIndex.collect {
    case (arg, idx)
        if !indicesToSkip.contains(idx) &&
          !arg.startsWith("--enableTestHarness") &&
          !arg.startsWith("--target-dir=") =>
      arg
  }

  val hostParams =
    SoCChiselConfig(itcmSize, dtcmSize, xlen).crossbar.hosts(enableTestHarness).map { host =>
      new bus.TLULParameters(dataBits = host.width, addrBits = xlen, idBits = 6)
    }
  val deviceParams = SoCChiselConfig(itcmSize, dtcmSize, xlen).crossbar.devices.map { device =>
    new bus.TLULParameters(dataBits = device.width, addrBits = xlen, idBits = 10)
  }

  // Manually parse arguments to find the target directory.
  var targetDir: Option[String] = None
  args.foreach {
    case s if s.startsWith("--target-dir=") => targetDir = Some(s.stripPrefix("--target-dir="))
    case "--enableTestHarness"              => // Already handled by filterNot
    case _                                  => // Ignore other arguments
  }

  // The subsystem module must be created in the ChiselStage context.
  lazy val subsystem =
    new CoralNPUChiselSubsystem(
      hostParams,
      deviceParams,
      enableTestHarness,
      itcmSize,
      dtcmSize,
      xlen,
      moduleName
    )

  val firtoolOpts = Array(
    // Disable `automatic logic =`, Suppress location comments
    "--lowering-options=disallowLocalVariables,locationInfoStyle=none",
    "-enable-layers=Verification"
  )
  val systemVerilogSource =
    ChiselStage.emitSystemVerilog(subsystem, chiselArgs.toArray, firtoolOpts)

  // CIRCT adds extra data to the end of the file. Remove it.
  val resourcesSeparator =
    "// ----- 8< ----- FILE \"firrtl_black_box_resource_files.f\" ----- 8< -----"
  val strippedVerilogSource = systemVerilogSource.split(resourcesSeparator)(0)

  // Write the stripped Verilog to the target directory.
  targetDir.foreach { dir =>
    Files.write(
      Paths.get(dir, subsystem.name + ".sv"),
      strippedVerilogSource.getBytes(StandardCharsets.UTF_8),
      StandardOpenOption.CREATE,
      StandardOpenOption.TRUNCATE_EXISTING
    )
  }
}
