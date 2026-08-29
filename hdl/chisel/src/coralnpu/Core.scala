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

import java.io.{File, FileOutputStream}
import java.util.zip._
import java.nio.file.{Files, Paths, StandardOpenOption}
import java.nio.charset.StandardCharsets
import coralnpu.rvv.RvvCore
import _root_.circt.stage.ChiselStage

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

    val iflush = new IFlushIO(p)
    val dflush = new DFlushIO(p)

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

  io.iflush <> score.io.iflush
  io.dflush <> score.io.dflush
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
  val p                         = new Parameters
  var moduleName                = "Core"
  var chiselArgs                = List[String]()
  var targetDir: Option[String] = None
  var useAxi                    = false
  var useTlul                   = false
  for (arg <- args) {
    if (arg.startsWith("--enableFetchL0")) {
      p.enableFetchL0 = arg.split("=")(1).toBoolean
    } else if (arg.startsWith("--enableAxiInstructionFetch")) {
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
    } else if (arg.startsWith("--target-dir")) {
      targetDir = Some(arg.split("=")(1))
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

  val firtoolOpts = Array(
    // Disable `automatic logic =`, Suppress location comments
    "--lowering-options=disallowLocalVariables,locationInfoStyle=none",
    "-enable-layers=Verification"
  )
  val systemVerilogSource = ChiselStage.emitSystemVerilog(core, chiselArgs.toArray, firtoolOpts)
  // CIRCT adds a little extra data to the sv file at the end. Remove it as we
  // don't want it (it prevents the sv from being verilated).
  val resourcesSeparator =
    "// ----- 8< ----- FILE \"firrtl_black_box_resource_files.f\" ----- 8< -----"
  val strippedVerilogSource = systemVerilogSource.split(resourcesSeparator)(0)
  val coreName              = core.name

  val header_str = EmitParametersHeader(p)

  targetDir match {
    case Some(targetDir) => {
      // 1. Identify boundary between Chisel-generated modules and embedded FILE sections.
      val fileSepRegex   = """(?m)^//.*FILE\s*"([^"]+)".*$""".r
      val fileSepMatches = fileSepRegex.findAllMatchIn(strippedVerilogSource).toList

      val chiselPart = if (fileSepMatches.nonEmpty) {
        strippedVerilogSource.substring(0, fileSepMatches.head.start)
      } else {
        strippedVerilogSource
      }

      // 2. Extract common header (macros/preamble before the first module).
      val modDeclRegex = """(?m)^(module|interface|package|primitive|config)\s+(\w+)""".r
      val modMatches   = modDeclRegex.findAllMatchIn(chiselPart).toList
      val commonHeader = if (modMatches.nonEmpty) {
        chiselPart.substring(0, modMatches.head.start)
      } else {
        ""
      }

      // 3. Build multi-file ZIP and filelist.f in topological order.
      val headers       = collection.mutable.ArrayBuffer[String]()
      val packages      = collection.mutable.ArrayBuffer[String]()
      val chiselModules = collection.mutable.ArrayBuffer[String]()
      val otherModules  = collection.mutable.ArrayBuffer[String]()

      val zipFile = new File(targetDir, s"${coreName}.zip")
      val zip     = new ZipOutputStream(new FileOutputStream(zipFile))

      try {
        // A. Chisel-generated modules
        for (i <- modMatches.indices) {
          val m       = modMatches(i)
          val modName = m.group(2)
          val start   = m.start
          val end = if (i + 1 < modMatches.length) modMatches(i + 1).start else chiselPart.length
          val modBody     = chiselPart.substring(start, end)
          val fileName    = s"${modName}.sv"
          val fileContent = commonHeader + modBody

          zip.putNextEntry(new ZipEntry(fileName))
          zip.write(fileContent.getBytes(StandardCharsets.UTF_8))
          zip.closeEntry()

          chiselModules += fileName
        }

        // B. Embedded file sections (verification layers, blackbox resources, headers)
        for (i <- fileSepMatches.indices) {
          val m              = fileSepMatches(i)
          val rawPath        = m.group(1)
          val normalizedPath = if (rawPath.startsWith("./")) rawPath.substring(2) else rawPath
          val lineEnd        = strippedVerilogSource.indexOf('\n', m.start)
          val start          = if (lineEnd != -1) lineEnd + 1 else m.end
          val end            =
            if (i + 1 < fileSepMatches.length) fileSepMatches(i + 1).start
            else strippedVerilogSource.length
          val rawBody = if (start <= end) strippedVerilogSource.substring(start, end) else ""

          val body = if (normalizedPath.startsWith("verification/")) {
            s"`ifndef SYNTHESIS // Added by Core.scala Verification Wrapper\n\n${rawBody.trim}\n\n`endif // Added by Core.scala Verification Wrapper\n"
          } else {
            rawBody
          }

          zip.putNextEntry(new ZipEntry(normalizedPath))
          zip.write(body.getBytes(StandardCharsets.UTF_8))
          zip.closeEntry()

          if (normalizedPath.endsWith(".svh") || normalizedPath.endsWith(".h")) {
            headers += normalizedPath
          } else if (
            normalizedPath
              .endsWith("_pkg.sv") || normalizedPath.startsWith("defs_") || normalizedPath.contains(
              "defs"
            )
          ) {
            packages += normalizedPath
          } else if (!normalizedPath.endsWith(".f")) {
            otherModules += normalizedPath
          }
        }

        // C. filelist.f (+incdir+., defines, packages, headers, then modules in topological order)
        val filelist = collection.mutable.ArrayBuffer[String]()
        filelist += "+incdir+."
        filelist += "+define+USE_GENERIC"
        if (p.enableRvv) {
          filelist += s"+define+VLEN_${p.rvvVlen}"
          filelist += "+define+TB_SUPPORT"
          if (p.enableFloat) {
            filelist += "+define+ZVE32F_ON"
          }
        }
        if (p.enableVme) {
          filelist += "+define+ZVT_ON"
        }
        filelist ++= packages
        filelist ++= headers
        filelist ++= chiselModules
        filelist ++= otherModules

        val filelistContent = filelist.mkString("\n") + "\n"
        zip.putNextEntry(new ZipEntry("filelist.f"))
        zip.write(filelistContent.getBytes(StandardCharsets.UTF_8))
        zip.closeEntry()
      } finally {
        zip.close()
      }

      // 4. Verification wrapper for monolithic Verilog output
      // Regex to match verification blocks in the concatenated Verilog output.
      // - (^//.*FILE\s*"verification/[^"]+".*$\n) matches the header line of a verification file.
      // - (?:[\s\S]*?) lazily captures all content up to the next file block.
      // - (?=\n//.*FILE\s*"|\z) lookahead stops matching before the next file header or at the end of the file.
      // - (?m) enables multiline mode so ^ and $ match line boundaries.
      val verificationPattern =
        """(?m)(^//.*FILE\s*"verification/[^"]+".*$\n(?:[\s\S]*?))(?=\n//.*FILE\s*"|\z)""".r
      val wrappedVerilogSource = verificationPattern.replaceAllIn(
        strippedVerilogSource,
        m => {
          java.util.regex.Matcher.quoteReplacement(
            s"`ifndef SYNTHESIS // Added by Core.scala Verification Wrapper\n\n${m.group(1)}\n`endif // Added by Core.scala Verification Wrapper"
          )
        }
      )

      Files.write(
        Paths.get(targetDir + "/V" + core.name + "_parameters.h"),
        header_str.getBytes(StandardCharsets.UTF_8),
        StandardOpenOption.CREATE,
        StandardOpenOption.TRUNCATE_EXISTING
      )
      Files.write(
        Paths.get(targetDir + "/" + core.name + ".sv"),
        wrappedVerilogSource
          .replace("exclude_file", "exclude_module")
          .getBytes(StandardCharsets.UTF_8),
        StandardOpenOption.CREATE,
        StandardOpenOption.TRUNCATE_EXISTING
      )

      ()
    }
    case None => ()
  }
}
