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
import chisel3.util._
import chisel3.simulator.scalatest.ChiselSim
import org.scalatest.freespec.AnyFreeSpec

class BasicModule extends Module {
  val io = IO(new Bundle {
    val in  = Input(UInt(32.W))
    val out = Output(UInt(32.W))
  })

  io.out := io.in + 1.U
}

class ValidModule extends Module {
  val io = IO(new Bundle {
    val in  = Input(Valid(UInt(32.W)))
    val out = Output(Valid(UInt(32.W)))
  })

  io.out := io.in.map(_ + 1.U)
}

object TrafficLight extends ChiselEnum {
  val RED    = Value
  val YELLOW = Value
  val GREEN  = Value
}

class ChiselEnumModule extends Module {
  val io = IO(new Bundle {
    val in  = Input(TrafficLight())
    val out = Output(TrafficLight())
  })
  io.out := MuxLookup(io.in, TrafficLight.RED)(
    Seq(
      TrafficLight.RED    -> TrafficLight.GREEN,
      TrafficLight.GREEN  -> TrafficLight.YELLOW,
      TrafficLight.YELLOW -> TrafficLight.RED
    )
  )
}

class VectorModule extends Module {
  val io = IO(new Bundle {
    val in  = Input(Vec(4, UInt(8.W)))
    val out = Output(Vec(4, UInt(8.W)))
  })
  io.out := io.in
}

class KitchenSync extends Bundle {
  val b = Bool()
  val u = UInt(12.W)
  val s = SInt(7.W)
  val e = TrafficLight()
  val v = Vec(
    3,
    new Bundle {
      val nu = UInt(3.W)
      val ns = SInt(2.W)
    }
  )
}

class KitchenSyncModule extends Module {
  val io = IO(new Bundle {
    val in  = Flipped(Decoupled(new KitchenSync()))
    val out = Decoupled(new KitchenSync())
  })
  io.out <> Queue(io.in, 2)
}

class GenerateInterfaceSpec extends AnyFreeSpec with ChiselSim {
  "BasicModule" in {
    val expectedInterface =
      """  input  logic [31:0] io_in,
              |  output logic [31:0] io_out""".stripMargin

    simulate(new BasicModule()) { dut =>
      val interface = GenerateInterface(dut.io, "io")
      assert(interface === expectedInterface)
    }
  }

  "ValidModule" in {
    val expectedInterface =
      """  input  logic io_in_valid,
              |  input  logic [31:0] io_in_bits,
              |  output logic io_out_valid,
              |  output logic [31:0] io_out_bits""".stripMargin

    simulate(new ValidModule()) { dut =>
      val interface = GenerateInterface(dut.io, "io")
      assert(interface === expectedInterface)
    }
  }

  "ChiselEnumModule" in {
    val expectedInterface =
      """  input  logic [1:0] io_in,
              |  output logic [1:0] io_out""".stripMargin
    simulate(new ChiselEnumModule()) { dut =>
      val interface = GenerateInterface(dut.io, "io")
      assert(interface === expectedInterface)
    }
  }

  "VectorModule" in {
    val expectedInterface =
      """  input  logic [7:0] io_in_0,
              |  input  logic [7:0] io_in_1,
              |  input  logic [7:0] io_in_2,
              |  input  logic [7:0] io_in_3,
              |  output logic [7:0] io_out_0,
              |  output logic [7:0] io_out_1,
              |  output logic [7:0] io_out_2,
              |  output logic [7:0] io_out_3""".stripMargin

    simulate(new VectorModule()) { dut =>
      val interface = GenerateInterface(dut.io, "io")
      assert(interface === expectedInterface)
    }
  }

  "KitchenSyncModule" in {
    val expectedInterface =
      """  output logic io_in_ready,
              |  input  logic io_in_valid,
              |  input  logic io_in_bits_b,
              |  input  logic [11:0] io_in_bits_u,
              |  input  logic [6:0] io_in_bits_s,
              |  input  logic [1:0] io_in_bits_e,
              |  input  logic [2:0] io_in_bits_v_0_nu,
              |  input  logic [1:0] io_in_bits_v_0_ns,
              |  input  logic [2:0] io_in_bits_v_1_nu,
              |  input  logic [1:0] io_in_bits_v_1_ns,
              |  input  logic [2:0] io_in_bits_v_2_nu,
              |  input  logic [1:0] io_in_bits_v_2_ns,
              |  input  logic io_out_ready,
              |  output logic io_out_valid,
              |  output logic io_out_bits_b,
              |  output logic [11:0] io_out_bits_u,
              |  output logic [6:0] io_out_bits_s,
              |  output logic [1:0] io_out_bits_e,
              |  output logic [2:0] io_out_bits_v_0_nu,
              |  output logic [1:0] io_out_bits_v_0_ns,
              |  output logic [2:0] io_out_bits_v_1_nu,
              |  output logic [1:0] io_out_bits_v_1_ns,
              |  output logic [2:0] io_out_bits_v_2_nu,
              |  output logic [1:0] io_out_bits_v_2_ns""".stripMargin

    simulate(new KitchenSyncModule()) { dut =>
      val interface = GenerateInterface(dut.io, "io")
      assert(interface === expectedInterface)
    }
  }
}

class ChiselEmitterSpec extends AnyFreeSpec {
  "ChiselEmitter emits monolithic SV, ZIP package, and split directory" in {
    val tempDir  = java.nio.file.Files.createTempDirectory("chisel_emitter_test").toFile
    val splitDir = java.nio.file.Files.createTempDirectory("chisel_emitter_split_test").toFile

    try {
      val options = ChiselEmitterOptions(
        defines = Seq("+define+TEST_DEF"),
        extraFiles = Map("test_params.h" -> "#define TEST 1\n"),
        emitSplitDir = Some(splitDir.getAbsolutePath)
      )

      ChiselEmitter.emit(
        new BasicModule(),
        Array(s"--target-dir=${tempDir.getAbsolutePath}"),
        options
      )

      // 1. Check monolithic SV and extra files
      val svFile = new java.io.File(tempDir, "BasicModule.sv")
      assert(svFile.exists(), "BasicModule.sv should exist")
      val svContent = new String(java.nio.file.Files.readAllBytes(svFile.toPath))
      assert(
        svContent.contains("module BasicModule"),
        "BasicModule.sv should contain module declaration"
      )

      val paramFile = new java.io.File(tempDir, "test_params.h")
      assert(paramFile.exists(), "test_params.h should exist")

      // 2. Check ZIP package
      val zipFile = new java.io.File(tempDir, "BasicModule.zip")
      assert(zipFile.exists(), "BasicModule.zip should exist")

      val zip = new java.util.zip.ZipFile(zipFile)
      try {
        val entryNames = scala.jdk.CollectionConverters
          .EnumerationHasAsScala(zip.entries())
          .asScala
          .map(_.getName)
          .toSet
        assert(entryNames.contains("BasicModule.sv"), "ZIP should contain BasicModule.sv")
        assert(entryNames.contains("chisel_preamble.svh"), "ZIP should contain chisel_preamble.svh")
        assert(entryNames.contains("all_headers.svh"), "ZIP should contain all_headers.svh")
        assert(entryNames.contains("filelist.f"), "ZIP should contain filelist.f")
        assert(entryNames.contains("filelist_hier.f"), "ZIP should contain filelist_hier.f")

        val flEntry   = zip.getEntry("filelist.f")
        val flContent = new String(zip.getInputStream(flEntry).readAllBytes())
        assert(flContent.contains("+define+TEST_DEF"), "filelist.f should contain custom defines")
        assert(flContent.contains("BasicModule.sv"), "filelist.f should contain BasicModule.sv")

        val flHierEntry   = zip.getEntry("filelist_hier.f")
        val flHierContent = new String(zip.getInputStream(flHierEntry).readAllBytes())
        assert(flHierContent.contains("-y ."), "filelist_hier.f should contain -y .")
        assert(
          flHierContent.contains("BasicModule.sv"),
          "filelist_hier.f should contain BasicModule.sv"
        )
      } finally {
        zip.close()
      }

      // 3. Check split directory
      assert(
        new java.io.File(splitDir, "BasicModule.sv").exists(),
        "splitDir should contain BasicModule.sv"
      )
      assert(
        new java.io.File(splitDir, "chisel_preamble.svh").exists(),
        "splitDir should contain chisel_preamble.svh"
      )
      assert(
        new java.io.File(splitDir, "all_headers.svh").exists(),
        "splitDir should contain all_headers.svh"
      )
      assert(
        new java.io.File(splitDir, "filelist.f").exists(),
        "splitDir should contain filelist.f"
      )
      assert(
        new java.io.File(splitDir, "filelist_hier.f").exists(),
        "splitDir should contain filelist_hier.f"
      )
    } finally {
      def deleteRecursively(file: java.io.File): Unit = {
        if (file.isDirectory) file.listFiles().foreach(deleteRecursively)
        file.delete()
      }
      deleteRecursively(tempDir)
      deleteRecursively(splitDir)
    }
  }
}
