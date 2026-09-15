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

package common

import chisel3._
import _root_.circt.stage.ChiselStage
import java.io.{File, FileOutputStream}
import java.nio.charset.StandardCharsets
import java.nio.file.{Files, Paths, StandardOpenOption}
import java.util.zip.{ZipEntry, ZipOutputStream}

case class ChiselEmitterOptions(
  moduleName: Option[String] = None,
  firtoolOpts: Array[String] = ChiselEmitter.defaultFirtoolOpts,
  defines: Seq[String] = Seq(),
  extraFiles: Map[String, String] = Map.empty,
  extraFilesGen: Option[String => Map[String, String]] = None,
  emitZip: Boolean = true,
  emitSplitDir: Option[String] = None
)

object ChiselEmitter {
  val defaultFirtoolOpts: Array[String] = Array(
    "--lowering-options=disallowLocalVariables,locationInfoStyle=none",
    "-enable-layers=Verification"
  )

  def emit(
    gen: => RawModule,
    args: Array[String],
    options: ChiselEmitterOptions = ChiselEmitterOptions()
  ): Unit = {
    var chiselArgs                = List[String]()
    var targetDir: Option[String] = None
    var splitDir: Option[String]  = options.emitSplitDir

    // Parse --target-dir and optional --split-dir
    var i = 0
    while (i < args.length) {
      val arg = args(i)
      if (arg.startsWith("--target-dir=")) {
        targetDir = Some(arg.stripPrefix("--target-dir="))
      } else if (arg == "--target-dir" && i + 1 < args.length) {
        targetDir = Some(args(i + 1))
        i += 1
      } else if (arg.startsWith("--split-dir=")) {
        splitDir = Some(arg.stripPrefix("--split-dir="))
      } else if (arg == "--split-dir" && i + 1 < args.length) {
        splitDir = Some(args(i + 1))
        i += 1
      } else {
        chiselArgs = chiselArgs :+ arg
      }
      i += 1
    }

    lazy val dut            = gen
    val systemVerilogSource =
      ChiselStage.emitSystemVerilog(dut, chiselArgs.toArray, options.firtoolOpts)
    val resourcesSeparator =
      "// ----- 8< ----- FILE \"firrtl_black_box_resource_files.f\" ----- 8< -----"
    val strippedVerilogSource = systemVerilogSource.split(resourcesSeparator)(0)
    val moduleName            = options.moduleName.getOrElse {
      try {
        dut.desiredName
      } catch {
        case _: Throwable => dut.name
      }
    }

    targetDir match {
      case Some(dir) =>
        val targetDirPath = Paths.get(dir)
        Files.createDirectories(targetDirPath)

        // 1. Multi-file ZIP & loose split directory construction
        if (options.emitZip || splitDir.isDefined) {
          emitMultiFilePackage(
            strippedVerilogSource = strippedVerilogSource,
            moduleName = moduleName,
            targetDir = dir,
            customDefines = options.defines,
            emitZip = options.emitZip,
            splitDir = splitDir
          )
        }

        // 2. Verification wrapper for monolithic Verilog output
        val verificationPattern =
          """(?m)(^//.*FILE\s*"verification/[^"]+".*$\n(?:[\s\S]*?))(?=\n//.*FILE\s*"|\z)""".r
        val wrappedVerilogSource = verificationPattern.replaceAllIn(
          strippedVerilogSource,
          m => {
            java.util.regex.Matcher.quoteReplacement(
              s"`ifndef SYNTHESIS // Added by ChiselEmitter Verification Wrapper\n\n${m.group(1)}\n`endif // Added by ChiselEmitter Verification Wrapper"
            )
          }
        )

        // 3. Write monolithic SystemVerilog
        Files.write(
          Paths.get(dir, s"${moduleName}.sv"),
          wrappedVerilogSource
            .replace("exclude_file", "exclude_module")
            .getBytes(StandardCharsets.UTF_8),
          StandardOpenOption.CREATE,
          StandardOpenOption.TRUNCATE_EXISTING
        )

        // 4. Write extra files (e.g. parameters headers)
        val allExtraFiles =
          options.extraFiles ++ options.extraFilesGen.map(_(moduleName)).getOrElse(Map.empty)
        for ((fileName, content) <- allExtraFiles) {
          Files.write(
            Paths.get(dir, fileName),
            content.getBytes(StandardCharsets.UTF_8),
            StandardOpenOption.CREATE,
            StandardOpenOption.TRUNCATE_EXISTING
          )
        }

      case None => ()
    }
  }

  private def emitMultiFilePackage(
    strippedVerilogSource: String,
    moduleName: String,
    targetDir: String,
    customDefines: Seq[String],
    emitZip: Boolean,
    splitDir: Option[String]
  ): Unit = {
    val fileSepRegex   = """(?m)^//.*FILE\s*"([^"]+)".*$""".r
    val fileSepMatches = fileSepRegex.findAllMatchIn(strippedVerilogSource).toList

    val chiselPart = if (fileSepMatches.nonEmpty) {
      strippedVerilogSource.substring(0, fileSepMatches.head.start)
    } else {
      strippedVerilogSource
    }

    // 1. Extract and deduplicate CIRCT common preamble into chisel_preamble.svh
    val modDeclRegex    = """(?m)^(module|interface|package|primitive|config)\s+(\w+)""".r
    val modMatches      = modDeclRegex.findAllMatchIn(chiselPart).toList
    val commonHeaderRaw = if (modMatches.nonEmpty) {
      chiselPart.substring(0, modMatches.head.start).trim
    } else {
      ""
    }
    val guardedCommonHeader =
      s"""`ifndef CHISEL_PREAMBLE_SVH
         |`define CHISEL_PREAMBLE_SVH
         |$commonHeaderRaw
         |`endif // CHISEL_PREAMBLE_SVH
         |""".stripMargin

    // 2. Parse CIRCT verification layer bind statements to inline into modules
    // Matches: bind <TargetMod> <AssertMod> <instName> ( ... );
    val bindRegex        = """(?s)bind\s+(\w+)\s+(\w+)\s+(\w+)\s*\((.*?)\);""".r
    val bindsByModule    = collection.mutable.Map[String, collection.mutable.ArrayBuffer[String]]()
    val globalLayerFiles = collection.mutable.Set[String]()

    // Parse all embedded file sections
    case class EmbeddedFile(path: String, body: String)
    val embeddedFiles = collection.mutable.ArrayBuffer[EmbeddedFile]()

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

      if (
        normalizedPath.startsWith("verification/assert/layers-") ||
        normalizedPath.startsWith("verification/assume/layers-") ||
        normalizedPath.startsWith("verification/cover/layers-")
      ) {
        globalLayerFiles += normalizedPath
        for (b <- bindRegex.findAllMatchIn(rawBody)) {
          val targetMod   = b.group(1)
          val assertMod   = b.group(2)
          val instName    = b.group(3)
          val ports       = b.group(4)
          val inlinedInst =
            s"""  `ifndef SYNTHESIS // Added by ChiselEmitter Inlined Verification Layer
               |  $assertMod $instName ($ports);
               |  `endif // SYNTHESIS
               |""".stripMargin
          bindsByModule.getOrElseUpdate(
            targetMod,
            collection.mutable.ArrayBuffer[String]()
          ) += inlinedInst
        }
      } else {
        val body = if (normalizedPath.startsWith("verification/")) {
          s"`ifndef SYNTHESIS // Added by ChiselEmitter Verification Wrapper\n\n${rawBody.trim}\n\n`endif // Added by ChiselEmitter Verification Wrapper\n"
        } else {
          rawBody
        }
        embeddedFiles += EmbeddedFile(normalizedPath, body)
      }
    }

    // 3. Process Chisel modules (inject inlined binds before endmodule)
    val chiselModules = collection.mutable.ArrayBuffer[(String, String)]()
    for (i <- modMatches.indices) {
      val m       = modMatches(i)
      val modName = m.group(2)
      val start   = m.start
      val end     = if (i + 1 < modMatches.length) modMatches(i + 1).start else chiselPart.length
      var modBody = chiselPart.substring(start, end)

      // If this module has verification binds to inline, inject before endmodule
      if (bindsByModule.contains(modName)) {
        val inlinedCode  = bindsByModule(modName).mkString("\n")
        val endModuleIdx = modBody.lastIndexOf("endmodule")
        if (endModuleIdx != -1) {
          modBody =
            modBody.substring(0, endModuleIdx) + inlinedCode + modBody.substring(endModuleIdx)
        }
      }

      val fileName    = s"${modName}.sv"
      val fileContent = s"`include \"all_headers.svh\"\n\n$modBody"
      chiselModules += ((fileName, fileContent))
    }

    // 4. Process embedded files and split any multi-module blackboxes (e.g. compressor_3to2.sv)
    val otherFiles   = collection.mutable.ArrayBuffer[(String, String)]()
    val headers      = collection.mutable.ArrayBuffer[String]()
    val packages     = collection.mutable.ArrayBuffer[String]()
    val packageNames = collection.mutable.ArrayBuffer[String]()
    val otherModules = collection.mutable.ArrayBuffer[String]()
    val pkgDeclRegex = """(?m)^package\s+(\w+);""".r

    headers += "chisel_preamble.svh"
    headers += "all_headers.svh"

    for (ef <- embeddedFiles) {
      val normalizedPath = ef.path
      val body           = ef.body

      val pkgMatches = pkgDeclRegex.findAllMatchIn(body).toList
      if (normalizedPath.endsWith(".svh") || normalizedPath.endsWith(".h")) {
        headers += normalizedPath
        otherFiles += ((normalizedPath, body))
      } else if (
        pkgMatches.nonEmpty ||
        normalizedPath.endsWith("_pkg.sv") || normalizedPath.startsWith("defs_") || normalizedPath
          .contains("defs")
      ) {
        packages += normalizedPath
        if (pkgMatches.nonEmpty) {
          for (pm <- pkgMatches) {
            packageNames += pm.group(1)
          }
        } else {
          val pkgName = normalizedPath.replaceAll("""\.sv$""", "").replaceFirst("^.*/", "")
          packageNames += pkgName
        }
        otherFiles += ((normalizedPath, body))
      } else if (!normalizedPath.endsWith(".f")) {
        // Check if embedded blackbox defines multiple modules or has a mismatched name
        val subModMatches = modDeclRegex.findAllMatchIn(body).toList
        if (subModMatches.length > 1) {
          for (j <- subModMatches.indices) {
            val sm         = subModMatches(j)
            val subModName = sm.group(2)
            val smStart    = sm.start
            val smEnd      =
              if (j + 1 < subModMatches.length) subModMatches(j + 1).start else body.length
            val subModBody    = body.substring(smStart, smEnd)
            val splitFileName = s"${subModName}.sv"
            val splitContent  = s"`include \"all_headers.svh\"\n\n$subModBody"
            otherFiles += ((splitFileName, splitContent))
            otherModules += splitFileName
          }
        } else {
          val contentWithHeader =
            if (normalizedPath.endsWith(".sv") || normalizedPath.endsWith(".v")) {
              s"`include \"all_headers.svh\"\n\n$body"
            } else {
              body
            }
          otherFiles += ((normalizedPath, contentWithHeader))
          otherModules += normalizedPath
        }
      }
    }

    // 5. Construct umbrella all_headers.svh
    val allHeadersContent = new StringBuilder
    allHeadersContent.append("`ifndef ALL_HEADERS_SVH\n`define ALL_HEADERS_SVH\n\n")
    allHeadersContent.append("`include \"chisel_preamble.svh\"\n")
    for (h <- headers.distinct if h != "chisel_preamble.svh" && h != "all_headers.svh") {
      allHeadersContent.append(s"`include \"$h\"\n")
    }
    // Add package wildcard imports so -y cell resolution has all package types
    for (pkgName <- packageNames.distinct) {
      allHeadersContent.append(s"import $pkgName::*;\n")
    }
    allHeadersContent.append("\n`endif // ALL_HEADERS_SVH\n")

    // 6. Generate standard filelist.f and hierarchical filelist_hier.f
    val filelist = collection.mutable.ArrayBuffer[String]()
    filelist += "+incdir+."
    filelist += "+define+USE_GENERIC"
    filelist ++= customDefines
    filelist ++= packages.distinct
    filelist ++= headers.distinct
    filelist ++= chiselModules.map(_._1)
    filelist ++= otherModules.distinct

    val filelistHier = collection.mutable.ArrayBuffer[String]()
    filelistHier += "+incdir+."
    filelistHier += "+define+USE_GENERIC"
    filelistHier ++= customDefines
    filelistHier ++= packages.distinct
    filelistHier += "-y ."
    filelistHier += "-y verification/assert"
    filelistHier += "+libext+.sv+.v"
    filelistHier += s"${moduleName}.sv"

    val filelistContent     = filelist.mkString("\n") + "\n"
    val filelistHierContent = filelistHier.mkString("\n") + "\n"

    // 7. Output files: to ZIP archive and/or splitDir
    val allOutputEntries = collection.mutable.ArrayBuffer[(String, String)]()
    allOutputEntries += (("chisel_preamble.svh", guardedCommonHeader))
    allOutputEntries += (("all_headers.svh", allHeadersContent.toString))
    allOutputEntries ++= chiselModules
    allOutputEntries ++= otherFiles
    allOutputEntries += (("filelist.f", filelistContent))
    allOutputEntries += (("filelist_hier.f", filelistHierContent))

    if (emitZip) {
      val zipFile = new File(targetDir, s"${moduleName}.zip")
      val zip     = new ZipOutputStream(new FileOutputStream(zipFile))
      try {
        for ((name, content) <- allOutputEntries) {
          zip.putNextEntry(new ZipEntry(name))
          zip.write(content.getBytes(StandardCharsets.UTF_8))
          zip.closeEntry()
        }
      } finally {
        zip.close()
      }
    }

    splitDir.foreach { dirPath =>
      val baseDir = Paths.get(dirPath)
      Files.createDirectories(baseDir)
      for ((name, content) <- allOutputEntries) {
        val targetPath = baseDir.resolve(name)
        Option(targetPath.getParent).foreach(Files.createDirectories(_))
        Files.write(
          targetPath,
          content.getBytes(StandardCharsets.UTF_8),
          StandardOpenOption.CREATE,
          StandardOpenOption.TRUNCATE_EXISTING
        )
      }
    }
  }
}
