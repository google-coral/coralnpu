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

import coralnpu.rvv.RvvCore

object Core {
  def apply(p: Parameters): Core = {
    return Module(new Core(p, "Core"))
  }
  def apply(p: Parameters, moduleName: String): Core = {
    return Module(new Core(p, moduleName))
  }
}

class Core(p: Parameters, moduleName: String) extends Module with RequireAsyncReset {
  override val desiredName = moduleName
  val io                   = IO(new Bundle {
    val csr          = new CsrInOutIO(p)
    val halted       = Output(Bool())
    val fault        = Output(Bool())
    val wfi          = Output(Bool())
    val irq          = Input(Bool())
    val timer_irq    = Input(Bool())
    val software_irq = Input(Bool())
    val debug_req    = Input(Bool())
    val dm           = new CoreDMIO(p)

    // Bus between core and instruction memories.
    val ibus = new IBusIO(p)
    // Bus between core and data memories.
    val dbus = new DBusIO(p)
    // Bus between core and and external memories or peripherals.
    val ebus = new EBusIO(p)

    val debug = Option.when(p.shouldExposeDebugPorts)(new DebugIO(p))
  })

  val score   = SCore(p)
  val rvvCore = Option.when(p.enableRvv)(RvvCore(p))
  if (p.enableRvv) {
    rvvCore.get.io <> score.io.rvvcore.get
  }

  // ---------------------------------------------------------------------------
  // Scalar Core outputs.
  io.csr <> score.io.csr
  io.ibus <> score.io.ibus
  io.ebus <> score.io.ebus
  io.halted             := score.io.halted
  io.fault              := score.io.fault
  io.wfi                := score.io.wfi
  score.io.irq          := io.irq
  score.io.timer_irq    := io.timer_irq
  score.io.software_irq := io.software_irq

  score.io.dm <> io.dm

  require(
    io.debug.isDefined == score.io.debug.isDefined,
    "Debug port presence mismatch between Core and SCore"
  )
  io.debug.zip(score.io.debug).foreach { case (ioDebug, scoreDebug) => ioDebug <> scoreDebug }

  // ---------------------------------------------------------------------------
  // Local Data Bus Port
  io.dbus <> score.io.dbus
}

object EmitCore extends App {
  val p          = new Parameters
  var moduleName = "Core"
  var chiselArgs = List[String]()
  var useAxi     = false
  var useTlul    = false
  for (arg <- args) {
    if (arg.startsWith("--enableAxiInstructionFetch")) {
      p.enableAxiInstructionFetch = arg.split("=")(1).toBoolean
    } else if (arg.startsWith("--xlen")) {
      p.xlen = arg.split("=")(1).toInt
    } else if (arg.startsWith("--moduleName")) {
      moduleName = arg.split("=")(1)
    } else if (arg.startsWith("--fetchDataBits")) {
      p.fetchDataBits = arg.split("=")(1).toInt
    } else if (arg.startsWith("--enableRvv")) {
      p.enableRvv = arg.split("=")(1).toBoolean
    } else if (arg.startsWith("--enableVme")) {
      p.enableVme = arg.split("=")(1).toBoolean
    } else if (arg.startsWith("--enableFloat")) {
      p.enableFloat = arg.split("=")(1).toBoolean
    } else if (arg.startsWith("--enableZfbfmin")) {
      p.enableZfbfmin = arg.split("=")(1).toBoolean
    } else if (arg.startsWith("--enableVectorBf16")) {
      p.enableVectorBf16 = arg.split("=")(1).toBoolean
    } else if (arg.startsWith("--fpuPipeRegs")) {
      p.fpuPipeRegs = arg.split("=")(1).toInt
      require(p.fpuPipeRegs >= 0, s"--fpuPipeRegs must be non-negative: ${p.fpuPipeRegs}")
    } else if (arg.startsWith("--enableVerification")) {
      p.enableVerification = arg.split("=")(1).toBoolean
    } else if (arg.startsWith("--exposeDebugPorts")) {
      p.rawExposeDebugPorts = arg.split("=")(1).toBoolean
    } else if (arg.startsWith("--lsuDataBits")) {
      p.lsuDataBits = arg.split("=")(1).toInt
      // itcmSizeKBytes, and dtcmSizeKBytes replace highmem flag
      // if highmem is needed, set both tcm sizes to 1024
    } else if (arg.startsWith("--itcmSizeKBytes")) {
      p.itcmSizeKBytes = arg.split("=")(1).toInt
    } else if (arg.startsWith("--dtcmSizeKBytes")) {
      p.dtcmSizeKBytes = arg.split("=")(1).toInt
    } else if (arg.startsWith("--useAxi")) {
      useAxi = true
    } else if (arg.startsWith("--useTlul")) {
      useTlul = true
    } else {
      chiselArgs = chiselArgs :+ arg
    }
  }
  assert(!(useAxi && useTlul))
  require(!p.enableVme || p.enableRvv, "--enableVme requires --enableRvv=True")

  val finalModuleName =
    if (
      p.itcmSizeKBytes == Parameters.itcmSizeKBytesDefault && p.dtcmSizeKBytes == Parameters.dtcmSizeKBytesDefault
    ) {
      moduleName
    } else if (
      p.itcmSizeKBytes == Parameters.itcmSizeKBytesHighmem && p.dtcmSizeKBytes == Parameters.dtcmSizeKBytesHighmem
    ) {
      s"${moduleName}Highmem"
    } else {
      s"${moduleName}_ITCM${p.itcmSizeKBytes}KB_DTCM${p.dtcmSizeKBytes}KB"
    }

  val memoryRegions =
    if (
      p.itcmSizeKBytes == Parameters.itcmSizeKBytesDefault && p.dtcmSizeKBytes == Parameters.dtcmSizeKBytesDefault
    ) {
      MemoryRegions.default
    } else {
      MemoryRegions.highmem(p.itcmSizeKBytes, p.dtcmSizeKBytes)
    }

  // The core module must be created in the ChiselStage context. Use lazy here
  // so it's created in ChiselStage, but referencable afterwards.
  lazy val core = if (useAxi) {
    p.m = memoryRegions
    new CoreAxi(p, finalModuleName)
  } else if (useTlul) {
    p.m = memoryRegions
    new CoreTlul(p, finalModuleName)
  } else {
    // "Matcha" memory layout
    p.m = Seq(
      new MemoryRegion(0x0, 0x400000, MemoryRegionType.DMEM)
    )
    new Core(p, finalModuleName)
  }

  val defines = collection.mutable.ArrayBuffer[String]()
  if (p.enableRvv) {
    defines += s"+define+VLEN_${p.rvvVlen}"
    defines += "+define+TB_SUPPORT"
    if (p.enableFloat) {
      defines += "+define+ZVE32F_ON"
    }
  }
  if (p.enableVme) {
    defines += "+define+ZVT_ON"
  }
  if (p.fpuPipeRegs != 4) {
    defines += s"+define+FPU_PIPEREGS=${p.fpuPipeRegs}"
    defines += s"+define+FALU_PIPEREGS=${p.fpuPipeRegs}"
  }

  val headerStr = EmitParametersHeader(p)
  val options   = common.ChiselEmitterOptions(
    defines = defines.toSeq,
    extraFilesGen = Some(name => Map(s"V${name}_parameters.h" -> headerStr))
  )

  common.ChiselEmitter.emit(core, chiselArgs.toArray, options)
}
