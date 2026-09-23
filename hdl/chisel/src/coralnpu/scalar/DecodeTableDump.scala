// Copyright 2026 Google LLC
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

import coralnpu.float.FloatInstruction
import java.io.PrintWriter

object DecodeTableDump {
  def main(args: Array[String]): Unit = {
    var configName = "core_mini_axi"
    var outputPath = ""

    for (arg <- args) {
      if (arg.startsWith("--config=")) {
        configName = arg.stripPrefix("--config=")
      } else if (arg.startsWith("--output=")) {
        outputPath = arg.stripPrefix("--output=")
      }
    }

    require(outputPath.nonEmpty, "Must specify --output=<path>")

    val p = new Parameters(MemoryRegions.default)
    configName match {
      case "core_mini_axi" =>
        p.enableRvv = false
        p.enableFloat = true
        p.enableZfbfmin = true
        p.enableVme = false
      case "rvv_core_mini_axi" =>
        p.enableRvv = true
        p.enableFloat = true
        p.enableZfbfmin = true
        p.enableVme = false
      case "vme_core_mini_axi" =>
        p.enableRvv = true
        p.enableFloat = true
        p.enableZfbfmin = true
        p.enableVme = true
      case other =>
        throw new IllegalArgumentException(s"Unknown config: $other")
    }

    val floatTable =
      if (p.enableFloat)
        FloatInstruction.table(p)
      else Seq()

    val table = DecodeInstruction.table(p) ++ floatTable

    val machineCsrs = Seq(
      CsrAddress.MSTATUS,
      CsrAddress.MISA,
      CsrAddress.MIE,
      CsrAddress.MTVEC,
      CsrAddress.MSCRATCH,
      CsrAddress.MEPC,
      CsrAddress.MCAUSE,
      CsrAddress.MTVAL,
      CsrAddress.MIP
    )

    val floatCsrs =
      if (p.enableFloat)
        Seq(
          CsrAddress.FFLAGS,
          CsrAddress.FRM,
          CsrAddress.FCSR
        )
      else Seq()

    val rvvCsrs =
      if (p.enableRvv)
        Seq(
          CsrAddress.VSTART,
          CsrAddress.VXSAT,
          CsrAddress.VXRM,
          CsrAddress.VL,
          CsrAddress.VTYPE,
          CsrAddress.VLENB
        )
      else Seq()

    val csrs = machineCsrs ++ floatCsrs ++ rvvCsrs

    val out = new PrintWriter(outputPath)
    try {
      out.println("{")
      out.println(s"""  "config": "$configName",""")
      out.println(s"""  "xlen": ${p.xlen},""")
      out.println("""  "instructions": [""")
      val insnJson = table.zipWithIndex.map { case ((name, pat), idx) =>
        val isLast   = idx == table.length - 1
        val comma    = if (isLast) "" else ","
        val maskHex  = f"0x${pat.mask}%08x"
        val valueHex = f"0x${pat.value}%08x"
        s"""    {"name": "$name", "mask": "$maskHex", "match": "$valueHex", "pattern": "${pat.toString}"}$comma"""
      }
      insnJson.foreach(out.println)
      out.println("  ],")
      out.println("""  "csrs": [""")
      val csrJson = csrs.zipWithIndex.map { case (csrVal, idx) =>
        val isLast    = idx == csrs.length - 1
        val comma     = if (isLast) "" else ","
        val rawName   = csrVal.toString
        val cleanName =
          if (rawName.contains("=")) rawName.substring(rawName.indexOf('=') + 1).stripSuffix(")")
          else rawName
        s"""    {"name": "$cleanName", "address": ${csrVal.litValue}, "address_hex": "${f"0x${csrVal.litValue}%03x"}"}$comma"""
      }
      csrJson.foreach(out.println)
      out.println("  ]")
      out.println("}")
    } finally {
      out.close()
    }
  }
}
