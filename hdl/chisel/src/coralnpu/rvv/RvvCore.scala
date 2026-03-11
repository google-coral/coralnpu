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

package coralnpu.rvv

import chisel3._
import chisel3.util._
import coralnpu.{Parameters,RegfileReadDataIO,RegfileWriteDataIO}

object RvvCore {
  def apply(p: Parameters): RvvCoreShim = {
    return Module(new RvvCoreShim(p))
  }
}

object GenerateCoreShimSource {
  def apply(instructionLanes: Integer, vlen: Integer): String = {
    var moduleInterface = """module RvvCoreWrapper(
        |    input clk,
        |    input rstn,
        |    input logic [VSTART_LEN:0] vstart,
        |    input logic [1:0] vxrm,
        |    input logic vxsat,
        |    input logic [2:0] frm,
        |""".stripMargin.replaceAll("VSTART_LEN", (log2Ceil(vlen) - 1).toString)

    // Add instruction interface inputs
    for (i <- 0 until instructionLanes) {
        moduleInterface += """    input inst_GENI_valid,
            |    input [31:0] inst_GENI_bits_pc,
            |    input [1:0] inst_GENI_bits_opcode,
            |    input [24:0] inst_GENI_bits_bits,
            |""".stripMargin.replaceAll("GENI", i.toString)
    }

    // Add regfile read interface inputs
    for (i <- 0 until 2*instructionLanes) {
        moduleInterface += """    input rs_GENI_valid,
            |    input [31:0] rs_GENI_data,
            |""".stripMargin.replaceAll("GENI", i.toString)
    }

    // Add float regfile read interface inputs
    for (i <- 0 until instructionLanes) {
        moduleInterface += """    input [31:0] frs_GENI,
            |""".stripMargin.replaceAll("GENI", i.toString)
    }

    // Add instruction interface outputs (backpressure)
    for (i <- 0 until instructionLanes) {
        moduleInterface += "    output inst_GENI_ready,\n".replaceAll(
            "GENI", i.toString)
    }

    // Add regfile write interface outputs
    for (i <- 0 until instructionLanes) {
        moduleInterface += """    output rd_GENI_valid,
            |    output [4:0] rd_GENI_bits_addr,
            |    output [31:0] rd_GENI_bits_data,
            |""".stripMargin.replaceAll("GENI", i.toString)
    }

    moduleInterface += """    output async_rd_valid,
        |    output [4:0] async_rd_bits_addr,
        |    output [31:0] async_rd_bits_data,
        |    input async_rd_ready,
        |    output async_frd_valid,
        |    output [4:0] async_frd_bits_addr,
        |    output [31:0] async_frd_bits_data,
        |    input async_frd_ready,
        |""".stripMargin

    // RVV to LSU
    for (i <- 0 until 2) {
        moduleInterface += """    output rvv2lsu_GENI_valid,
            |    output rvv2lsu_GENI_bits_idx_valid,
            |    output [4:0] rvv2lsu_GENI_bits_idx_bits_addr,
            |    output [VLEN-1:0] rvv2lsu_GENI_bits_idx_bits_data,
            |    output rvv2lsu_GENI_bits_vregfile_valid,
            |    output [4:0] rvv2lsu_GENI_bits_vregfile_bits_addr,
            |    output [VLEN-1:0] rvv2lsu_GENI_bits_vregfile_bits_data,
            |    output rvv2lsu_GENI_bits_mask_valid,
            |    output [(VLEN/8)-1:0] rvv2lsu_GENI_bits_mask_bits,
            |    input rvv2lsu_GENI_ready,
            |""".stripMargin.replaceAll("GENI", i.toString).replaceAll(
                "VLEN", vlen.toString)
    }

    // LSU to RVV
    for (i <- 0 until 2) {
        moduleInterface += """    input lsu2rvv_GENI_valid,
            |    input [4:0] lsu2rvv_GENI_bits_addr,
            |    input [VLEN-1:0] lsu2rvv_GENI_bits_data,
            |    input  lsu2rvv_GENI_bits_last,
            |    output lsu2rvv_GENI_ready,
            |""".stripMargin.replaceAll("GENI", i.toString).replaceAll(
                "VLEN", vlen.toString)
    }

    // Add CSR output
    moduleInterface += """    output vcsr_valid,
        |    output [VSTART_LEN:0] vcsr_vstart,
        |    output [1:0] vcsr_xrm,
        |    output vcsr_vxsat,
        |    input vcsr_ready,
        |""".stripMargin.replaceAll("VSTART_LEN", (log2Ceil(vlen) - 1).toString)

    // Add RVV Config state output
    moduleInterface += """    output configStateValid,
        |    output [7:0] configVl,
        |    output [VSTART_LEN:0] configVstart,
        |    output configMa,
        |    output configTa,
        |    output [1:0] configXrm,
        |    output [2:0] configSew,
        |    output [2:0] configLmul,
        |    output [2:0] configLmulOrig,
        |    output configVill,
        |    output logic rvv_idle,
        |    output logic [3:0] queue_capacity,
        |""".stripMargin.replaceAll("VSTART_LEN", (log2Ceil(vlen) - 1).toString)

    // Add rd_rob2rt_o interface outputs
    for (i <- 0 until instructionLanes) {
        moduleInterface += """
            |    output rd_rob2rt_o_GENI_w_valid,
            |    output [4:0] rd_rob2rt_o_GENI_w_index,
            |    output [127:0] rd_rob2rt_o_GENI_w_data,
            |    output rd_rob2rt_o_GENI_w_type,
            |    output [15:0] rd_rob2rt_o_GENI_vd_type,
            |    output rd_rob2rt_o_GENI_trap_flag,
            |    output rd_rob2rt_o_GENI_vector_csr_vl,
            |    output rd_rob2rt_o_GENI_vector_csr_vstart,
            |    output rd_rob2rt_o_GENI_vector_csr_ma,
            |    output rd_rob2rt_o_GENI_vector_csr_ta,
            |    output rd_rob2rt_o_GENI_vector_csr_xrm,
            |    output rd_rob2rt_o_GENI_vector_csr_sew,
            |    output rd_rob2rt_o_GENI_vector_csr_lmul,
            |    output rd_rob2rt_o_GENI_vector_csr_lmul_orig,
            |    output rd_rob2rt_o_GENI_vector_csr_vill,
            |    output [15:0] rd_rob2rt_o_GENI_vxsaturate,
            |    output [31:0] rd_rob2rt_o_GENI_uop_pc,
            |    output rd_rob2rt_o_GENI_last_uop_valid,
            """.stripMargin.replaceAll("GENI", i.toString)
    }

    // Add trap interface outputs
    moduleInterface += """
        |    output trap_valid,
        |    output [31:0] trap_bits_pc,
        |    output [1:0] trap_bits_opcode,
        |    output [24:0] trap_bits_bits,
        |    input scalarTrapValid,
        |    output scalarTrapReady,""".stripMargin

    // Add vxsat backend update outputs
    moduleInterface += """
        |    output wr_vxsat_valid_o,
        |    output wr_vxsat_o,""".stripMargin

    // Remove last comma/linebreak
    moduleInterface = moduleInterface.dropRight(1)
    moduleInterface += "\n);\n"

    var coreInstantiation = "  logic [GENN-1:0] inst_valid;\n".replaceAll(
            "GENN", instructionLanes.toString)
    for (i <- 0 until instructionLanes) {
      coreInstantiation += "  assign inst_valid[GENI] = inst_GENI_valid;\n".replaceAll(
          "GENI", i.toString)
    }

    // Inst data
    coreInstantiation += "  RVVInstruction [GENN-1:0] inst_data;\n".replaceAll(
            "GENN", instructionLanes.toString)
    for (i <- 0 until instructionLanes) {
      coreInstantiation += "  assign inst_data[GENI].pc = inst_GENI_bits_pc;\n".replaceAll(
          "GENI", i.toString)
      coreInstantiation += "  assign inst_data[GENI].opcode = RVVOpCode'(inst_GENI_bits_opcode);\n".replaceAll(
          "GENI", i.toString)
      coreInstantiation += "  assign inst_data[GENI].bits = inst_GENI_bits_bits;\n".replaceAll(
          "GENI", i.toString)
    }

    // Inst ready temp output
    coreInstantiation += "  logic [GENN-1:0] inst_ready;\n".replaceAll(
        "GENN", instructionLanes.toString)

    // Scalar regfile read
    coreInstantiation += "  logic [2*GENN-1:0] reg_read_valid;\n".replaceAll(
            "GENN", instructionLanes.toString)
    for (i <- 0 until 2*instructionLanes) {
      coreInstantiation += "  assign reg_read_valid[GENI] = rs_GENI_valid;\n".replaceAll(
          "GENI", i.toString)
    }
    coreInstantiation += "  logic [2*GENN-1:0][31:0] reg_read_data;\n".replaceAll(
            "GENN", instructionLanes.toString)
    for (i <- 0 until 2*instructionLanes) {
      coreInstantiation += "  assign reg_read_data[GENI] = rs_GENI_data;\n".replaceAll(
          "GENI", i.toString)
    }

    // Float regfile read
    coreInstantiation += "  logic [GENN-1:0][31:0] freg_read_data;\n".replaceAll(
            "GENN", instructionLanes.toString)
    for (i <- 0 until instructionLanes) {
      coreInstantiation += "  assign freg_read_data[GENI] = frs_GENI;\n".replaceAll(
          "GENI", i.toString)
    }

    // RVV2LSU
    coreInstantiation += """  logic [2-1:0] uop_lsu_valid_rvv2lsu;
      |  logic [2-1:0] uop_lsu_idx_valid_rvv2lsu;
      |  logic [2-1:0][4:0] uop_lsu_idx_addr_rvv2lsu;
      |  logic [2-1:0][VLEN-1:0] uop_lsu_idx_data_rvv2lsu;
      |  logic [2-1:0] uop_lsu_vregfile_valid_rvv2lsu;
      |  logic [2-1:0][4:0] uop_lsu_vregfile_addr_rvv2lsu;
      |  logic [2-1:0][VLEN-1:0] uop_lsu_vregfile_data_rvv2lsu;
      |  logic [2-1:0] uop_lsu_v0_valid_rvv2lsu;
      |  logic [2-1:0][(VLEN/8)-1:0] uop_lsu_v0_data_rvv2lsu;
      |  logic [2-1:0] uop_lsu_ready_lsu2rvv;""".stripMargin.replaceAll(
          "VLEN", vlen.toString)
    for (i <- 0 until 2) {
      coreInstantiation += """
          |  assign rvv2lsu_GENI_valid = uop_lsu_valid_rvv2lsu[GENI];
          |  assign rvv2lsu_GENI_bits_idx_valid = uop_lsu_idx_valid_rvv2lsu[GENI];
          |  assign rvv2lsu_GENI_bits_idx_bits_addr = uop_lsu_idx_addr_rvv2lsu[GENI];
          |  assign rvv2lsu_GENI_bits_idx_bits_data = uop_lsu_idx_data_rvv2lsu[GENI];
          |  assign rvv2lsu_GENI_bits_vregfile_valid = uop_lsu_vregfile_valid_rvv2lsu[GENI];
          |  assign rvv2lsu_GENI_bits_vregfile_bits_addr = uop_lsu_vregfile_addr_rvv2lsu[GENI];
          |  assign rvv2lsu_GENI_bits_vregfile_bits_data = uop_lsu_vregfile_data_rvv2lsu[GENI];
          |  assign rvv2lsu_GENI_bits_mask_valid = uop_lsu_v0_valid_rvv2lsu[GENI];
          |  assign rvv2lsu_GENI_bits_mask_bits = uop_lsu_v0_data_rvv2lsu[GENI];
          |  assign uop_lsu_ready_lsu2rvv[GENI] = rvv2lsu_GENI_ready;
          |""".stripMargin.replaceAll("GENI", i.toString)
    }


    // LSU2RVV
    coreInstantiation += """  logic [2-1:0] uop_lsu_valid_lsu2rvv;
      |  logic  [2-1:0][4:0]  uop_lsu_addr_lsu2rvv;
      |  logic  [2-1:0][VLEN-1:0] uop_lsu_wdata_lsu2rvv;
      |  logic  [2-1:0] uop_lsu_last_lsu2rvv;
      |  logic  [2-1:0] uop_lsu_ready_rvv2lsu;""".stripMargin.replaceAll(
          "VLEN", vlen.toString)
    for (i <- 0 until 2) {
      coreInstantiation += """
          |  assign uop_lsu_valid_lsu2rvv[GENI] = lsu2rvv_GENI_valid;
          |  assign uop_lsu_addr_lsu2rvv[GENI] = lsu2rvv_GENI_bits_addr;
          |  assign uop_lsu_wdata_lsu2rvv[GENI] = lsu2rvv_GENI_bits_data;
          |  assign uop_lsu_last_lsu2rvv[GENI] = lsu2rvv_GENI_bits_last;
          |  assign lsu2rvv_GENI_ready = uop_lsu_ready_rvv2lsu[GENI];
          |""".stripMargin.replaceAll("GENI", i.toString)
    }

    // Scalar regfile write temp output
    coreInstantiation += """  logic [GENN-1:0] reg_write_valid;
        |  logic [GENN-1:0][4:0] reg_write_addr;
        |  logic [GENN-1:0][31:0] reg_write_data;
        |""".stripMargin.replaceAll("GENN", instructionLanes.toString)

    // VCSR temp output
    coreInstantiation += """  RVVConfigState vector_csr;
        |  assign vcsr_vstart = vector_csr.vstart;
        |  assign vcsr_xrm = vector_csr.xrm;
        |  assign vcsr_vxsat = vector_csr.xsat;
        |""".stripMargin
    // RVV Config State temp output
    coreInstantiation += """  RVVConfigState config_state;
        |""".stripMargin

    coreInstantiation += "  ROB2RT_t [3:0] rd_rob2rt_o;\n"
    coreInstantiation += "  RVVInstruction trap_data;\n"

    coreInstantiation += """  RvvCore#(.N (GENN)) core(
        |      .clk(clk),
        |      .rstn(rstn),
        |      .vstart(vstart),
        |      .vxrm(vxrm),
        |      .vxsat(vxsat),
        |      .frm(frm),
        |      .inst_valid(inst_valid),
        |      .inst_data(inst_data),
        |      .inst_ready(inst_ready),
        |      .reg_read_valid(reg_read_valid),
        |      .reg_read_data(reg_read_data),
        |      .freg_read_data(freg_read_data),
        |      .reg_write_valid(reg_write_valid),
        |      .reg_write_addr(reg_write_addr),
        |      .reg_write_data(reg_write_data),
        |      .async_rd_valid(async_rd_valid),
        |      .async_rd_addr(async_rd_bits_addr),
        |      .async_rd_data(async_rd_bits_data),
        |      .async_rd_ready(async_rd_ready),
        |      .async_frd_valid(async_frd_valid),
        |      .async_frd_addr(async_frd_bits_addr),
        |      .async_frd_data(async_frd_bits_data),
        |      .async_frd_ready(async_frd_ready),
        |      .uop_lsu_valid_rvv2lsu(uop_lsu_valid_rvv2lsu),
        |      .uop_lsu_idx_valid_rvv2lsu(uop_lsu_idx_valid_rvv2lsu),
        |      .uop_lsu_idx_addr_rvv2lsu(uop_lsu_idx_addr_rvv2lsu),
        |      .uop_lsu_idx_data_rvv2lsu(uop_lsu_idx_data_rvv2lsu),
        |      .uop_lsu_vregfile_valid_rvv2lsu(uop_lsu_vregfile_valid_rvv2lsu),
        |      .uop_lsu_vregfile_addr_rvv2lsu(uop_lsu_vregfile_addr_rvv2lsu),
        |      .uop_lsu_vregfile_data_rvv2lsu(uop_lsu_vregfile_data_rvv2lsu),
        |      .uop_lsu_v0_valid_rvv2lsu(uop_lsu_v0_valid_rvv2lsu),
        |      .uop_lsu_v0_data_rvv2lsu(uop_lsu_v0_data_rvv2lsu),
        |      .uop_lsu_ready_lsu2rvv(uop_lsu_ready_lsu2rvv),
        |      .uop_lsu_valid_lsu2rvv(uop_lsu_valid_lsu2rvv),
        |      .uop_lsu_addr_lsu2rvv(uop_lsu_addr_lsu2rvv),
        |      .uop_lsu_wdata_lsu2rvv(uop_lsu_wdata_lsu2rvv),
        |      .uop_lsu_last_lsu2rvv(uop_lsu_last_lsu2rvv),
        |      .uop_lsu_ready_rvv2lsu(uop_lsu_ready_rvv2lsu),
        |      .vcsr_valid(vcsr_valid),
        |      .vector_csr(vector_csr),
        |      .vcsr_ready(vcsr_ready),
        |      .config_state_valid(configStateValid),
        |      .config_state(config_state),
        |      .rvv_idle(rvv_idle),
        |      .queue_capacity(queue_capacity),
        |      .rd_rob2rt_o(rd_rob2rt_o),
        |      .trap_valid_o(trap_valid),
        |      .trap_data_o(trap_data),
        |      .wr_vxsat_valid_o(wr_vxsat_valid_o),
        |      .wr_vxsat_o(wr_vxsat_o),
        |      .trap_valid_rvs2rvv(scalarTrapValid),
        |      .trap_ready_rvv2rvs(scalarTrapReady)
        |""".stripMargin.replaceAll("GENN", instructionLanes.toString)
    coreInstantiation += "  );\n"

    for (i <- 0 until instructionLanes) {
      coreInstantiation += """  assign rd_rob2rt_o_GENI_w_valid = rd_rob2rt_o[GENI].w_valid;
      |  assign rd_rob2rt_o_GENI_w_index = rd_rob2rt_o[GENI].w_index;
      |  assign rd_rob2rt_o_GENI_w_data = rd_rob2rt_o[GENI].w_data;
      |  assign rd_rob2rt_o_GENI_w_type = rd_rob2rt_o[GENI].w_type;
      |  assign rd_rob2rt_o_GENI_vd_type = rd_rob2rt_o[GENI].vd_type;
      |  assign rd_rob2rt_o_GENI_trap_flag = rd_rob2rt_o[GENI].trap_flag;
      |  assign rd_rob2rt_o_GENI_vector_csr_vl = rd_rob2rt_o[GENI].vector_csr.vl;
      |  assign rd_rob2rt_o_GENI_vector_csr_vstart = rd_rob2rt_o[GENI].vector_csr.vstart;
      |  assign rd_rob2rt_o_GENI_vector_csr_ma = rd_rob2rt_o[GENI].vector_csr.ma;
      |  assign rd_rob2rt_o_GENI_vector_csr_ta = rd_rob2rt_o[GENI].vector_csr.ta;
      |  assign rd_rob2rt_o_GENI_vector_csr_xrm = rd_rob2rt_o[GENI].vector_csr.xrm;
      |  assign rd_rob2rt_o_GENI_vector_csr_sew = rd_rob2rt_o[GENI].vector_csr.sew;
      |  assign rd_rob2rt_o_GENI_vector_csr_lmul = rd_rob2rt_o[GENI].vector_csr.lmul;
      |  assign rd_rob2rt_o_GENI_vector_csr_lmul_orig = rd_rob2rt_o[GENI].vector_csr.lmul_orig;
      |  assign rd_rob2rt_o_GENI_vector_csr_vill = rd_rob2rt_o[GENI].vector_csr.vill;
      |  assign rd_rob2rt_o_GENI_vxsaturate = rd_rob2rt_o[GENI].vxsaturate;
      |  assign rd_rob2rt_o_GENI_uop_pc = rd_rob2rt_o[GENI].uop_pc;
      |  assign rd_rob2rt_o_GENI_last_uop_valid = rd_rob2rt_o[GENI].last_uop_valid;
      |""".stripMargin.replaceAll("GENI", i.toString)
    }
    coreInstantiation += """  assign trap_bits_pc = trap_data.pc;
      |  assign trap_bits_opcode = trap_data.opcode;
      |  assign trap_bits_bits = trap_data.bits;
      |""".stripMargin
    for (i <- 0 until instructionLanes) {
      coreInstantiation += "  assign inst_GENI_ready = inst_ready[GENI];\n".replaceAll("GENI", i.toString)
    }
    for (i <- 0 until instructionLanes) {
      coreInstantiation += """  assign rd_GENI_valid = reg_write_valid[GENI];
      |  assign rd_GENI_bits_addr = reg_write_addr[GENI];
      |  assign rd_GENI_bits_data = reg_write_data[GENI];
      |""".stripMargin.replaceAll("GENI", i.toString)
    }
    coreInstantiation += "  assign configVl = config_state.vl;\n"
    coreInstantiation += "  assign configVstart = config_state.vstart;\n"
    coreInstantiation += "  assign configMa = config_state.ma;\n"
    coreInstantiation += "  assign configTa = config_state.ta;\n"
    coreInstantiation += "  assign configXrm = config_state.xrm;\n"
    coreInstantiation += "  assign configSew = config_state.sew;\n"
    coreInstantiation += "  assign configLmul = config_state.lmul;\n"
    coreInstantiation += "  assign configLmulOrig = config_state.lmul_orig;\n"
    coreInstantiation += "  assign configVill = config_state.vill;\n"

    moduleInterface + coreInstantiation + "endmodule\n"
  }
}

// Shim class for RVVCore, which invokes the RVV SV interface with the correct
// parameters.
class RvvCoreWrapper(p: Parameters) extends BlackBox with HasBlackBoxInline
                                                     with HasBlackBoxResource {
  val io = IO(new Bundle {
    val clk  = Input(Clock())
    val rstn = Input(AsyncReset())

    val vstart = Input(UInt(log2Ceil(p.rvvVlen).W))
    val vxrm = Input(UInt(2.W))
    val vxsat = Input(UInt(1.W))
    val frm = Input(UInt(3.W))

    val inst = Vec(p.instructionLanes,
        Flipped(Decoupled(new RvvCompressedInstruction)))

    val rs = Vec(p.instructionLanes * 2, Flipped(new RegfileReadDataIO))
    val rd = Vec(p.instructionLanes, Valid(new RegfileWriteDataIO))
    val frs = Vec(p.instructionLanes, Input(UInt(32.W)))

    val async_rd = Decoupled(new RegfileWriteDataIO)
    val async_frd = Decoupled(new RegfileWriteDataIO)

    val rd_rob2rt_o = Vec(4, new Rob2Rt(p))
    val trap = Output(Valid(new RvvCompressedInstruction))

    val vcsr_valid = Output(Bool())
    val vcsr_vstart = Output(UInt(7.W))
    val vcsr_xrm = Output(UInt(2.W))
    val vcsr_vxsat = Output(Bool())
    val vcsr_ready = Input(Bool())

    // VXSAT update from backend
    val wr_vxsat_valid_o = Output(Bool())
    val wr_vxsat_o = Output(Bool())

    // TODO(derekjchow): Parameterize
    val rvv2lsu = Vec(2, Decoupled(new Rvv2Lsu(p)))
    val lsu2rvv = Vec(2, Flipped(Decoupled(new Lsu2Rvv(p))))

    // Config state
    val configStateValid = Output(Bool())
    val configVl = Output(UInt(8.W))
    val configVstart = Output(UInt(7.W))
    val configMa = Output(Bool())
    val configTa = Output(Bool())
    val configXrm = Output(UInt(2.W))
    val configSew = Output(UInt(3.W))
    // This may be reduced according to vl.
    val configLmul = Output(UInt(3.W))
    // This is the original one set in vset(i)vl(i)
    val configLmulOrig = Output(UInt(3.W))
    val configVill = Output(Bool())
    val rvv_idle = Output(Bool())
    val queue_capacity = Output(UInt(4.W))

    val scalarTrapValid = Input(Bool())
    val scalarTrapReady = Output(Bool())
  })
  dontTouch(io.rd_rob2rt_o)

  // Resources must be sorted topologically by dependency DAG
  addResource("hdl/verilog/rvv/inc/rvv_backend_config.svh")
  addResource("hdl/verilog/rvv/inc/rvv_backend_define.svh")
  addResource("hdl/verilog/rvv/inc/rvv_backend.svh")
  addResource("hdl/verilog/rvv/inc/rvv_backend_sva.svh")
  addResource("hdl/verilog/rvv/inc/rvv_backend_alu.svh")
  addResource("hdl/verilog/rvv/inc/rvv_backend_dispatch.svh")
  addResource("hdl/verilog/rvv/inc/rvv_backend_div.svh")
  addResource("hdl/verilog/rvv/inc/rvv_backend_pmtrdt.svh")
  addResource("hdl/verilog/rvv/common/cdffr.sv")
  addResource("hdl/verilog/rvv/common/compressor_3_2.sv")
  addResource("hdl/verilog/rvv/common/compressor_4_2.sv")
  addResource("hdl/verilog/rvv/common/dff.sv")
  addResource("hdl/verilog/rvv/common/edff.sv")
  addResource("hdl/verilog/rvv/common/edff_2d.sv")
  addResource("hdl/verilog/rvv/common/multi_fifo.sv")
  addResource("hdl/verilog/rvv/design/Aligner.sv")
  addResource("hdl/verilog/rvv/design/RvvFrontEnd.sv")
  addResource("hdl/verilog/rvv/design/rvv_backend_alu_unit_addsub.sv")
  addResource("hdl/verilog/rvv/design/rvv_backend_alu_unit_execution_p1.sv")
  addResource("hdl/verilog/rvv/design/rvv_backend_alu_unit_mask_viota.sv")
  addResource("hdl/verilog/rvv/design/rvv_backend_alu_unit_mask.sv")
  addResource("hdl/verilog/rvv/design/rvv_backend_alu_unit_other.sv")
  addResource("hdl/verilog/rvv/design/rvv_backend_alu_unit_shift.sv")
  addResource("hdl/verilog/rvv/design/rvv_backend_alu_unit.sv")
  addResource("hdl/verilog/rvv/design/rvv_backend_alu.sv")
  addResource("hdl/verilog/rvv/design/rvv_backend_decode_unit.sv")
  addResource("hdl/verilog/rvv/design/rvv_backend_decode_unit_ari.sv")
  addResource("hdl/verilog/rvv/design/rvv_backend_decode_unit_lsu.sv")
  addResource("hdl/verilog/rvv/design/rvv_backend_decode_ctrl.sv")
  addResource("hdl/verilog/rvv/design/rvv_backend_decode.sv")
  addResource("hdl/verilog/rvv/design/rvv_backend_dispatch_bypass.sv")
  addResource("hdl/verilog/rvv/design/rvv_backend_dispatch_ctrl.sv")
  addResource("hdl/verilog/rvv/design/rvv_backend_dispatch_operand.sv")
  addResource("hdl/verilog/rvv/design/rvv_backend_dispatch_opr_byte_type.sv")
  addResource("hdl/verilog/rvv/design/rvv_backend_dispatch_raw_uop_rob.sv")
  addResource("hdl/verilog/rvv/design/rvv_backend_dispatch_raw_uop_uop.sv")
  addResource("hdl/verilog/rvv/design/rvv_backend_dispatch_structure_hazard.sv")
  addResource("hdl/verilog/rvv/design/rvv_backend_dispatch.sv")
  addResource("hdl/verilog/rvv/design/rvv_backend_div_unit_divider.sv")
  addResource("hdl/verilog/rvv/design/rvv_backend_div_unit.sv")
  addResource("hdl/verilog/rvv/design/rvv_backend_div.sv")
  addResource("hdl/verilog/rvv/design/rvv_backend_lsu_remap.sv")
  addResource("hdl/verilog/rvv/design/rvv_backend_mul_unit_mul8.sv")
  addResource("hdl/verilog/rvv/design/rvv_backend_mac_unit.sv")
  addResource("hdl/verilog/rvv/design/rvv_backend_mul_unit.sv")
  addResource("hdl/verilog/rvv/design/rvv_backend_mulmac.sv")
  addResource("hdl/verilog/rvv/design/rvv_backend_pmtrdt_unit.sv")
  addResource("hdl/verilog/rvv/design/rvv_backend_pmtrdt.sv")
  addResource("hdl/verilog/rvv/design/rvv_backend_retire.sv")
  addResource("hdl/verilog/rvv/design/rvv_backend_rob.sv")
  addResource("hdl/verilog/rvv/design/rvv_backend_vrf_reg.sv")
  addResource("hdl/verilog/rvv/design/rvv_backend_vrf.sv")
  addResource("hdl/verilog/rvv/design/rvv_backend.sv")
  addResource("hdl/verilog/rvv/design/RvvCore.sv")
  setInline("RvvCoreWrapper.sv", GenerateCoreShimSource(p.instructionLanes, p.rvvVlen))
}

// Shim class for RVVCore, which translates the SV RVVCore interfaces with the
// Chisel ones. Note, we name this class "RvvCoreShim" to avoid conflict with
// the "RvvCore" defined in SystemVerilog
class RvvCoreShim(p: Parameters) extends Module {
  val io = IO(new RvvCoreIO(p))

  val vstart = RegInit(0.U(log2Ceil(p.rvvVlen).W))
  val vxrm = RegInit(0.U(2.W))
  val vxsat = RegInit(false.B)

  val rstn = (!reset.asBool).asAsyncReset
  val rvvCoreWrapper = Module(new RvvCoreWrapper(p))
  rvvCoreWrapper.io.clk := clock
  rvvCoreWrapper.io.rstn := rstn
  rvvCoreWrapper.io.inst <> io.inst
  rvvCoreWrapper.io.rs <> io.rs
  rvvCoreWrapper.io.rd <> io.rd
  rvvCoreWrapper.io.frs <> io.frs
  rvvCoreWrapper.io.async_rd <> io.async_rd
  rvvCoreWrapper.io.async_frd <> io.async_frd
  rvvCoreWrapper.io.rd_rob2rt_o <> io.rd_rob2rt_o
  io.trap := rvvCoreWrapper.io.trap

  rvvCoreWrapper.io.vstart := Mux(
      io.csr.vstart_write.valid, io.csr.vstart_write.bits, vstart)
  rvvCoreWrapper.io.vxrm := Mux(
      io.csr.vxrm_write.valid, io.csr.vxrm_write.bits, vxrm)
  rvvCoreWrapper.io.vxsat := Mux(
      io.csr.vxsat_write.valid, io.csr.vxsat_write.bits, vxsat)
  rvvCoreWrapper.io.frm := io.csr.frm
  rvvCoreWrapper.io.vcsr_ready := true.B

  io.rvv2lsu <> rvvCoreWrapper.io.rvv2lsu
  io.lsu2rvv <> rvvCoreWrapper.io.lsu2rvv

  // Conservatively mark config state as invalid the cycle when CSR instruction
  // updates vstart, vxrm or vxsat.
  io.configState.valid := rvvCoreWrapper.io.configStateValid &&
      !rvvCoreWrapper.io.vcsr_valid &&
      !io.csr.vstart_write.valid &&
      !io.csr.vxrm_write.valid &&
      !io.csr.vxsat_write.valid
  io.configState.bits.vl          := rvvCoreWrapper.io.configVl
  io.configState.bits.vstart      := rvvCoreWrapper.io.configVstart
  io.configState.bits.ma          := rvvCoreWrapper.io.configMa
  io.configState.bits.ta          := rvvCoreWrapper.io.configTa
  io.configState.bits.xrm         := rvvCoreWrapper.io.configXrm
  io.configState.bits.sew         := rvvCoreWrapper.io.configSew
  io.configState.bits.lmul        := rvvCoreWrapper.io.configLmul
  io.configState.bits.lmul_orig   := rvvCoreWrapper.io.configLmulOrig
  io.configState.bits.vill        := rvvCoreWrapper.io.configVill
  io.rvv_idle                     := rvvCoreWrapper.io.rvv_idle
  io.queue_capacity               := rvvCoreWrapper.io.queue_capacity
  rvvCoreWrapper.io.scalarTrapValid := io.scalarTrapValid
  io.scalarTrapReady              := rvvCoreWrapper.io.scalarTrapReady

  val vstart_wdata = MuxCase(vstart, Seq(
      rvvCoreWrapper.io.vcsr_valid -> rvvCoreWrapper.io.vcsr_vstart,
      io.csr.vstart_write.valid -> io.csr.vstart_write.bits,
  ))
  vstart := vstart_wdata

  val vxrm_wdata = MuxCase(vxrm, Seq(
      rvvCoreWrapper.io.vcsr_valid -> rvvCoreWrapper.io.vcsr_xrm,
      io.csr.vxrm_write.valid -> io.csr.vxrm_write.bits,
  ))
  vxrm := vxrm_wdata

  val vxsat_wdata = MuxCase(vxsat, Seq(
      rvvCoreWrapper.io.wr_vxsat_valid_o -> (vxsat | rvvCoreWrapper.io.wr_vxsat_o),
      rvvCoreWrapper.io.vcsr_valid -> rvvCoreWrapper.io.vcsr_vxsat,
      io.csr.vxsat_write.valid -> io.csr.vxsat_write.bits,
  ))
  vxsat := vxsat_wdata

  io.csr.vstart := vstart
  io.csr.vxrm := vxrm
  io.csr.vxsat := vxsat
}

