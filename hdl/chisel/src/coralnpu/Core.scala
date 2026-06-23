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

import java.io.{File, FileOutputStream, PrintWriter}
import scala.io.Source
import java.util.zip._
import java.nio.file.{Files, Paths, StandardOpenOption}
import java.nio.charset.StandardCharsets
import coralnpu.rvv.RvvCore
import _root_.circt.stage.ChiselStage
import scala.collection.mutable.Stack

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
      {
        lazy val core2 = if (useAxi) {
          new CoreAxi(p, moduleName)
        } else {
          new Core(p, moduleName)
        }

        ChiselStage.emitSystemVerilogFile(
          core2,
          chiselArgs.toArray ++ Array("--split-verilog", "--target-dir", targetDir),
          firtoolOpts
        )

        // Post-process split files to wrap verification code in ifndef SYNTHESIS
        def wrapFileInIfndef(file: File): Unit = {
          if (file.isFile && file.getName.endsWith(".sv")) {
            val source  = Source.fromFile(file)
            val content = try {
              source.getLines().mkString("\n")
            } finally {
              source.close()
            }
            val wrappedContent =
              s"`ifndef SYNTHESIS // Added by Core.scala Verification Wrapper\n\n${content}\n\n`endif // Added by Core.scala Verification Wrapper\n"
            val writer = new PrintWriter(file)
            writer.write(wrappedContent)
            writer.close()
          } else if (file.isDirectory) {
            Option(file.listFiles()).foreach(_.foreach(wrapFileInIfndef))
          }
        }
        val verificationDir = new File(targetDir + "/verification")
        if (verificationDir.exists()) {
          wrapFileInIfndef(verificationDir)
        }

        val zip = new ZipOutputStream(new FileOutputStream(targetDir + "/" + coreName + ".zip"))
        val dirStack = new Stack[File](1)
        dirStack.push(new File(targetDir))
        println(s"target: ${targetDir}")
        while (!dirStack.isEmpty) {
          val dir   = dirStack.pop()
          val files = dir.listFiles
          files.foreach { name =>
            if (name.isDirectory()) {
              dirStack.push(name)
            } else {
              val zipName = name.getPath().replace(targetDir + "/", "")
              zip.putNextEntry(new ZipEntry(zipName))
              zip.write(Files.readAllBytes(Paths.get(name.getPath())))
              zip.closeEntry()
            }
          }
        }
        zip.close()
      }

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
        StandardOpenOption.CREATE
      )
      Files.write(
        Paths.get(targetDir + "/" + core.name + ".sv"),
        wrappedVerilogSource
          .replace("exclude_file", "exclude_module")
          .getBytes(StandardCharsets.UTF_8),
        StandardOpenOption.CREATE
      )

      ()
    }
    case None => ()
  }
}
