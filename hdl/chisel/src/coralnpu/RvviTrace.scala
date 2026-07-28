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

object GenerateRvviTraceSource {
  def apply(p: Parameters): String = {
    var moduleInterface = "module RvviTraceBlackBox(\n"
    moduleInterface += "  input logic clk_i,\n"
    for (i <- 0 until p.retirementLanes) {
      moduleInterface +=
        "  input logic valid_i_GENI,\n".replaceAll("GENI", i.toString)
      moduleInterface +=
        "  input logic [63:0] order_i_GENI,\n".replaceAll("GENI", i.toString)
      moduleInterface +=
        "  input logic [31:0] insn_i_GENI,\n".replaceAll("GENI", i.toString)
      moduleInterface +=
        "  input logic trap_i_GENI,\n".replaceAll("GENI", i.toString)
      moduleInterface +=
        "  input logic debug_mode_i_GENI,\n".replaceAll("GENI", i.toString)
      moduleInterface +=
        "  input logic [31:0] pc_rdata_i_GENI,\n".replaceAll("GENI", i.toString)
      moduleInterface +=
        "  input logic [1023:0] x_wdata_i_GENI,\n".replaceAll("GENI", i.toString)
      moduleInterface +=
        "  input logic [31:0] x_wb_i_GENI,\n".replaceAll("GENI", i.toString)
      moduleInterface +=
        "  input logic [1023:0] f_wdata_i_GENI,\n".replaceAll("GENI", i.toString)
      moduleInterface +=
        "  input logic [31:0] f_wb_i_GENI,\n".replaceAll("GENI", i.toString)
      moduleInterface +=
        "  input logic [4095:0] v_wdata_i_GENI,\n".replaceAll("GENI", i.toString)
      moduleInterface +=
        "  input logic [31:0] v_wb_i_GENI,\n".replaceAll("GENI", i.toString)
      for (j <- 0 until p.retirementLanes) {
        moduleInterface +=
          "  input logic [GENSZ:0] csr_i_GENIDX,\n"
            .replaceAll("GENIDX", (i * p.retirementLanes + j).toString)
            .replaceAll("GENSZ", (((4096 / p.retirementLanes) * 32) - 1).toString)
      }
      moduleInterface +=
        "  input logic [4095:0] csr_wb_i_GENI,\n".replaceAll("GENI", i.toString)
    }

    moduleInterface = moduleInterface.dropRight(2)
    moduleInterface += ");\n\n"

    var coreInstantiation = """
        |  rvviTrace #(
        |    .ILEN(32),
        |    .XLEN(32),
        |    .FLEN(32),
        |    .VLEN(128),
        |    .NHART(1),
        |    .RETIRE(GEN_retirementLanes)
        |  ) rvvi();
        |""".replaceAll("GEN_retirementLanes", p.retirementLanes.toString).stripMargin

    coreInstantiation += "  assign rvvi.clk = clk_i;\n"
    for (i <- 0 until p.retirementLanes) {
      coreInstantiation += "  assign rvvi.valid[0][GENI] = valid_i_GENI;\n".replaceAll(
        "GENI",
        i.toString
      )
      coreInstantiation += "  assign rvvi.order[0][GENI] = order_i_GENI;\n".replaceAll(
        "GENI",
        i.toString
      )
      coreInstantiation += "  assign rvvi.insn[0][GENI] = insn_i_GENI;\n".replaceAll(
        "GENI",
        i.toString
      )
      coreInstantiation += "  assign rvvi.trap[0][GENI] = trap_i_GENI;\n".replaceAll(
        "GENI",
        i.toString
      )
      coreInstantiation += "  assign rvvi.debug_mode[0][GENI] = debug_mode_i_GENI;\n".replaceAll(
        "GENI",
        i.toString
      )
      coreInstantiation += "  assign rvvi.pc_rdata[0][GENI] = pc_rdata_i_GENI;\n".replaceAll(
        "GENI",
        i.toString
      )
      coreInstantiation += "  assign rvvi.x_wdata[0][GENI] = x_wdata_i_GENI;\n".replaceAll(
        "GENI",
        i.toString
      )
      coreInstantiation += "  assign rvvi.x_wb[0][GENI] = x_wb_i_GENI;\n".replaceAll(
        "GENI",
        i.toString
      )
      coreInstantiation += "  assign rvvi.f_wdata[0][GENI] = f_wdata_i_GENI;\n".replaceAll(
        "GENI",
        i.toString
      )
      coreInstantiation += "  assign rvvi.f_wb[0][GENI] = f_wb_i_GENI;\n".replaceAll(
        "GENI",
        i.toString
      )
      coreInstantiation += "  assign rvvi.v_wdata[0][GENI] = v_wdata_i_GENI;\n".replaceAll(
        "GENI",
        i.toString
      )
      coreInstantiation += "  assign rvvi.v_wb[0][GENI] = v_wb_i_GENI;\n".replaceAll(
        "GENI",
        i.toString
      )
      for (j <- 0 until p.retirementLanes) {
        coreInstantiation += "  assign rvvi.csr[0][GENi][MSB:LSB] = csr_i_GENIDX;\n"
          .replaceAll("GENi", i.toString)
          .replaceAll("GENIDX", (i * p.retirementLanes + j).toString)
          .replaceAll("MSB", ((j + 1) * (4096 / p.retirementLanes) - 1).toString)
          .replaceAll("LSB", ((j * (4096 / p.retirementLanes)).toString))
      }
      coreInstantiation += "  assign rvvi.csr_wb[0][GENI] = csr_wb_i_GENI;\n".replaceAll(
        "GENI",
        i.toString
      )
      coreInstantiation += "  assign rvvi.lrsc_cancel[0][GENI] = 1'b0;\n".replaceAll(
        "GENI",
        i.toString
      )
      coreInstantiation += "  assign rvvi.pc_wdata[0][GENI] = 32'b0;\n".replaceAll(
        "GENI",
        i.toString
      )
      coreInstantiation += "  assign rvvi.halt[0][GENI] = 1'b0;\n".replaceAll("GENI", i.toString)
      coreInstantiation += "  assign rvvi.ixl[0][GENI] = 2'b0;\n".replaceAll("GENI", i.toString)
      coreInstantiation += "  assign rvvi.mode[0][GENI] = 2'b0;\n".replaceAll("GENI", i.toString)
    }

    moduleInterface + coreInstantiation + "endmodule\n"
  }
}

class RvviTraceBlackBox(p: Parameters)
    extends BlackBox
    with HasBlackBoxInline
    with HasBlackBoxResource {
  val io = IO(new Bundle {
    val clk_i        = Input(Clock())
    val valid_i      = Input(Vec(p.retirementLanes, Bool()))
    val order_i      = Input(Vec(p.retirementLanes, UInt(64.W)))
    val insn_i       = Input(Vec(p.retirementLanes, UInt(32.W)))
    val trap_i       = Input(Vec(p.retirementLanes, Bool()))
    val debug_mode_i = Input(Vec(p.retirementLanes, Bool()))
    val pc_rdata_i   = Input(Vec(p.retirementLanes, UInt(32.W)))
    val x_wdata_i    = Input(Vec(p.retirementLanes, UInt((32 * 32).W)))
    val x_wb_i       = Input(Vec(p.retirementLanes, UInt(32.W)))
    val f_wdata_i    = Input(Vec(p.retirementLanes, UInt((32 * 32).W)))
    val f_wb_i       = Input(Vec(p.retirementLanes, UInt(32.W)))
    val v_wdata_i    = Input(Vec(p.retirementLanes, UInt((32 * 128).W)))
    val v_wb_i       = Input(Vec(p.retirementLanes, UInt(32.W)))
    val csr_i        = Input(
      Vec(
        p.retirementLanes * p.retirementLanes,
        UInt(((4096 / p.retirementLanes) * 32).W)
      )
    )
    val csr_wb_i = Input(Vec(p.retirementLanes, UInt(4096.W)))
  })
  addResource("external/RVVI/source/host/rvvi/rvviTrace.sv")
  setInline("RvviTraceBlackBox.sv", GenerateRvviTraceSource(p))
}

class RvviTrace(p: Parameters) extends Module {
  val io = IO(new Bundle {
    val rb  = Input(new RetirementBufferDebugIO(p))
    val csr = Input(new CsrTraceIO(p))
  })
  val x_wdata = Wire(Vec(p.retirementLanes, Vec(32, UInt(32.W))))
  val x_wb    = Wire(Vec(p.retirementLanes, Vec(32, Bool())))
  val f_wdata = Wire(Vec(p.retirementLanes, Vec(32, UInt(32.W))))
  val f_wb    = Wire(Vec(p.retirementLanes, Vec(32, Bool())))
  val v_wdata = Wire(Vec(p.retirementLanes, Vec(32, UInt(128.W))))
  val v_wb    = Wire(Vec(p.retirementLanes, Vec(32, Bool())))
  val csr     = Wire(Vec(p.retirementLanes, Vec(4096, UInt(32.W))))
  val csr_wb  = Wire(Vec(p.retirementLanes, Vec(4096, Bool())))

  val count = RegInit(0.U(64.W))
  count := count + PopCount(io.rb.inst.map(_.valid))

  val rvviTraceBlackBox = Module(new RvviTraceBlackBox(p))
  rvviTraceBlackBox.io.clk_i := clock
  for (i <- 0 until p.retirementLanes) {
    rvviTraceBlackBox.io.x_wdata_i(i) := x_wdata(i).asUInt
    rvviTraceBlackBox.io.x_wb_i(i)    := x_wb(i).asUInt
    rvviTraceBlackBox.io.f_wdata_i(i) := f_wdata(i).asUInt
    rvviTraceBlackBox.io.f_wb_i(i)    := f_wb(i).asUInt
    rvviTraceBlackBox.io.v_wdata_i(i) := v_wdata(i).asUInt
    rvviTraceBlackBox.io.v_wb_i(i)    := v_wb(i).asUInt
    for (j <- 0 until p.retirementLanes) {
      val subsize = rvviTraceBlackBox.io.csr_i(i).getWidth
      rvviTraceBlackBox.io
        .csr_i(i * p.retirementLanes + j) := csr(i).asUInt(subsize * (j + 1) - 1, subsize * j)
    }
    rvviTraceBlackBox.io.csr_wb_i(i) := csr_wb(i).asUInt
  }

  for (i <- 0 until p.retirementLanes) {
    val valid    = io.rb.inst(i).valid
    val insn     = io.rb.inst(i).bits.inst
    val pc_rdata = io.rb.inst(i).bits.pc
    val wb_idx   = io.rb.inst(i).bits.idx
    val wdata    = io.rb.inst(i).bits.data
    val trap     = io.rb.inst(i).bits.trap

    rvviTraceBlackBox.io.valid_i(i) := valid
    rvviTraceBlackBox.io.order_i(i) := MuxOR(valid, count + i.U)
    rvviTraceBlackBox.io.insn_i(i)  := MuxOR(valid, insn)
    rvviTraceBlackBox.io.trap_i(i)  := MuxOR(valid, trap)

    ///////////////////////////////////
    // TODO(atv): This is just generally not tracked.
    ///////////////////////////////////
    rvviTraceBlackBox.io.debug_mode_i(i) := false.B
    ///////////////////////////////////

    rvviTraceBlackBox.io.pc_rdata_i(i) := MuxOR(valid, pc_rdata)

    for (j <- 0 until 32) {
      val x_wb_valid = valid && (wb_idx === j.U)
      x_wdata(i)(j) := MuxOR(x_wb_valid, wdata)
      x_wb(i)(j)    := x_wb_valid

      val f_wb_valid = valid && (wb_idx === j.U + p.floatRegfileBaseAddr.U)
      f_wdata(i)(j) := MuxOR(f_wb_valid, wdata)
      f_wb(i)(j)    := f_wb_valid

      if (p.enableRvv) {
        val vecWrites = io.rb.inst(i).bits.vecWrites.get
        val hits      = vecWrites.map(w => valid && w.valid && w.bits.idx === j.U)
        val hit       = hits.reduce(_ | _)
        val hitData   = PriorityMux(hits, vecWrites.map(_.bits.data))

        v_wdata(i)(j) := MuxOR(hit, hitData)
        v_wb(i)(j)    := hit
      } else {
        val v_wb_valid = valid && (wb_idx === j.U + p.rvvRegfileBaseAddr.U)
        v_wdata(i)(j) := MuxOR(v_wb_valid, wdata)
        v_wb(i)(j)    := v_wb_valid
      }
    }

    for (j <- 0 until 4096) {
      val csr_wb_valid = valid && io.csr.valid && (io.csr.addr === j.U)
      csr(i)(j)    := MuxOR(csr_wb_valid, io.csr.data)
      csr_wb(i)(j) := csr_wb_valid
    }
  }
}
