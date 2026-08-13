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

package coralnpu.float

import common._
import chisel3._
import chisel3.util._
import coralnpu.{Parameters, RegfileWriteDataIO}

object FloatCore {
  def apply(p: Parameters): FloatCore = {
    return Module(new FloatCore(p))
  }
}

// TODO(atv): Investigate importing these from fpnew RTL.
object FpNewConfig {
  val NUM_OPERANDS = 3
  val WIDTH        = 32
  val OP_BITS      = 4
}

// Corresponding SystemVerilog enum `opgroup_e` can be found at
// external/cvfpu/src/fpnew_pkg.sv:119
object FpNewOperation extends ChiselEnum {
  val FMADD    = Value(0.U(FpNewConfig.OP_BITS.W))
  val FNMSUB   = Value(1.U(FpNewConfig.OP_BITS.W))
  val ADD      = Value(2.U(FpNewConfig.OP_BITS.W))
  val MUL      = Value(3.U(FpNewConfig.OP_BITS.W))
  val DIV      = Value(4.U(FpNewConfig.OP_BITS.W))
  val SQRT     = Value(5.U(FpNewConfig.OP_BITS.W))
  val SGNJ     = Value(6.U(FpNewConfig.OP_BITS.W))
  val MINMAX   = Value(7.U(FpNewConfig.OP_BITS.W))
  val CMP      = Value(8.U(FpNewConfig.OP_BITS.W))
  val CLASSIFY = Value(9.U(FpNewConfig.OP_BITS.W))
  val F2F      = Value(10.U(FpNewConfig.OP_BITS.W))
  val F2I      = Value(11.U(FpNewConfig.OP_BITS.W))
  val I2F      = Value(12.U(FpNewConfig.OP_BITS.W))
  val CPKAB    = Value(13.U(FpNewConfig.OP_BITS.W))
  val CPKCD    = Value(14.U(FpNewConfig.OP_BITS.W))
  // This isn't a real FPNEW operation. Don't present it to the core.
  val STORE = Value(15.U(FpNewConfig.OP_BITS.W))
}

// Corresponding SystemVerilog enum `roundmode_e` can be found at
// external/cvfpu/src/fpnew_pkg.sv:130
// See the RISC-V Unprivileged spec, Chapter 20.2 for details
// on rounding modes.
object FpNewRoundingMode extends ChiselEnum {
  val RNE = Value(0.U(3.W)) // Round to nearest, ties to even
  val RTZ = Value(1.U(3.W)) // Round to zero
  val RDN = Value(2.U(3.W)) // Round down (towards -inf)
  val RUP = Value(3.U(3.W)) // Round up (towards +inf)
  val RMM = Value(4.U(3.W)) // Round to nearest, ties to max magnitude
  val DYN = Value(7.U(3.W)) // Dynamic rounding mode (embedded in instruction)
}

object GenerateCoreShimSource {
  def apply(p: Parameters): String = {
    var moduleInterface = """
        |module FloatCoreWrapper(
        |  input logic clk_i,
        |  input logic rst_ni,
        |""".stripMargin

    moduleInterface += "  input logic in_valid_i,\n"
    moduleInterface += "  output logic in_ready_o,\n"
    for (i <- 0 until FpNewConfig.NUM_OPERANDS) {
      moduleInterface += "  input logic [WIDTH-1:0] operands_i_GENI,\n"
        .replaceAll("GENI", i.toString)
        .replaceAll("WIDTH", FpNewConfig.WIDTH.toString)
    }
    moduleInterface += "  input logic[OP_BITS-1:0] op_i,\n".replaceAll(
      "OP_BITS",
      FpNewConfig.OP_BITS.toString
    )
    moduleInterface += "  input logic op_mod_i,\n"
    moduleInterface += "  input logic[2:0] rnd_mode_i,\n"
    moduleInterface += "  input logic[2:0] src_fmt_i,\n"
    moduleInterface += "  input logic[2:0] dst_fmt_i,\n"
    moduleInterface += "  input logic flush_i,\n"
    moduleInterface += "  output logic out_valid_o,\n"
    moduleInterface += "  input logic out_ready_i,\n"
    moduleInterface += "  output logic[WIDTH-1:0] result_o,\n".replaceAll(
      "WIDTH",
      FpNewConfig.WIDTH.toString
    )
    for (i <- 0 until 5) {
      moduleInterface += "  output logic status_o_GENI,\n".replaceAll("GENI", i.toString)
    }
    moduleInterface += "  output logic busy_o,\n"
    moduleInterface += "  output logic early_valid_o\n"
    moduleInterface += ");\n\n"

    var coreInstantiation = "  logic [NUM_OPERANDS-1:0][WIDTH-1:0] operands_i;\n"
      .replaceAll("NUM_OPERANDS", FpNewConfig.NUM_OPERANDS.toString)
      .replaceAll("WIDTH", FpNewConfig.WIDTH.toString)

    for (i <- 0 until FpNewConfig.NUM_OPERANDS) {
      coreInstantiation += "  assign operands_i[GENI] = operands_i_GENI;\n".replaceAll(
        "GENI",
        i.toString
      )
    }

    coreInstantiation += "  fpnew_pkg::status_t status_o_pkg;\n"
    for (i <- 0 until 5) {
      coreInstantiation += "  assign status_o_GENI = status_o_pkg[GENI];\n".replaceAll(
        "GENI",
        i.toString
      )
    }

    coreInstantiation += """  localparam fpnew_pkg::fpu_implementation_t impl = '{
        |  PipeRegs:   '{default: 'd3},
        |  UnitTypes:  '{'{default: fpnew_pkg::PARALLEL}, // ADDMUL
        |                '{default: fpnew_pkg::MERGED},   // DIVSQRT
        |                '{default: fpnew_pkg::PARALLEL}, // NONCOMP
        |                '{default: fpnew_pkg::MERGED}},  // CONV
        |  PipeConfig: fpnew_pkg::DISTRIBUTED
        |};
        |""".stripMargin

    coreInstantiation += """  fpnew_top#(
        |      .Features(FEATURES),
        |      .Implementation(impl),
        |      .DivSqrtSel(DIVSQRT_SEL)
        |    ) core(
        |    .clk_i(clk_i),
        |    .rst_ni(rst_ni),
        |    .operands_i(operands_i),
        |    .rnd_mode_i(fpnew_pkg::roundmode_e'(rnd_mode_i)),
        |    .op_i(fpnew_pkg::operation_e'(op_i)),
        |    .op_mod_i(op_mod_i),
        |    .src_fmt_i(fpnew_pkg::fp_format_e'(src_fmt_i)),
        |    .dst_fmt_i(fpnew_pkg::fp_format_e'(dst_fmt_i)),
        |    .int_fmt_i(fpnew_pkg::INT32),
        |    .vectorial_op_i(1'b0),
        |    .tag_i(1'b0),
        |    .simd_mask_i(1'b0),
        |    .in_valid_i(in_valid_i),
        |    .flush_i(flush_i),
        |    .out_ready_i(out_ready_i),
        |    .in_ready_o(in_ready_o),
        |    .result_o(result_o),
        |    .status_o(status_o_pkg),
        |    .tag_o(),
        |    .out_valid_o(out_valid_o),
        |    .busy_o(busy_o),
        |    .early_valid_o(early_valid_o)
        |  );
        |"""
      .replaceAll(
        "DIVSQRT_SEL",
        if (p.floatPulpDivsqrt != 0 || p.enableZfbfmin) "fpnew_pkg::PULP" else "fpnew_pkg::TH32"
      )
      .replaceAll(
        "FEATURES",
        if (p.enableZfbfmin) """fpnew_pkg::fpu_features_t'{
        |  Width:         32,
        |  EnableVectors: 1'b0,
        |  EnableNanBox:  1'b1,
        |  FpFmtMask:     5'b10001,
        |  IntFmtMask:    4'b0010
        |}""" else "fpnew_pkg::RV32F"
      )
      .stripMargin

    moduleInterface + coreInstantiation + "endmodule\n"
  }
}

class FloatCoreWrapper(p: Parameters)
    extends BlackBox
    with HasBlackBoxInline
    with HasBlackBoxResource {
  val io = IO(new Bundle {
    val clk_i      = Input(Clock())
    val rst_ni     = Input(AsyncReset())
    val in_valid_i = Input(Bool())
    val in_ready_o = Output(Bool())
    val operands_i = Input(Vec(FpNewConfig.NUM_OPERANDS, UInt(FpNewConfig.WIDTH.W)))
    val op_i       = Input(UInt(FpNewConfig.OP_BITS.W))
    val op_mod_i   = Input(Bool())
    val rnd_mode_i = Input(UInt(3.W))
    val src_fmt_i  = Input(UInt(3.W))
    val dst_fmt_i  = Input(UInt(3.W))
    val flush_i    = Input(Bool())

    val out_valid_o   = Output(Bool())
    val out_ready_i   = Input(Bool())
    val result_o      = Output(UInt(FpNewConfig.WIDTH.W))
    val status_o      = Output(Vec(5, Bool())) // fflags
    val busy_o        = Output(Bool())
    val early_valid_o = Output(Bool())
  })
  addResource("external/common_cells/include/common_cells/registers.svh")
  addResource("external/common_cells/src/cf_math_pkg.sv")
  addResource("external/common_cells/src/lzc.sv")
  addResource("external/common_cells/src/rr_arb_tree.sv")
  addResource("external/cvfpu/src/fpnew_pkg.sv")
  addResource("external/cvfpu/src/fpnew_cast_multi.sv")
  addResource("external/cvfpu/src/fpnew_classifier.sv")
  if (p.floatPulpDivsqrt == 0 && !p.enableZfbfmin) {
    addResource("external/cvfpu/vendor/opene906/E906_RTL_FACTORY/gen_rtl/clk/rtl/gated_clk_cell.v")
    addResource("external/cvfpu/vendor/opene906/E906_RTL_FACTORY/gen_rtl/fdsu/rtl/pa_fdsu_ctrl.v")
    addResource("external/cvfpu/vendor/opene906/E906_RTL_FACTORY/gen_rtl/fdsu/rtl/pa_fdsu_ff1.v")
    addResource(
      "external/cvfpu/vendor/opene906/E906_RTL_FACTORY/gen_rtl/fdsu/rtl/pa_fdsu_pack_single.v"
    )
    addResource(
      "external/cvfpu/vendor/opene906/E906_RTL_FACTORY/gen_rtl/fdsu/rtl/pa_fdsu_prepare.v"
    )
    addResource(
      "external/cvfpu/vendor/opene906/E906_RTL_FACTORY/gen_rtl/fdsu/rtl/pa_fdsu_round_single.v"
    )
    addResource(
      "external/cvfpu/vendor/opene906/E906_RTL_FACTORY/gen_rtl/fdsu/rtl/pa_fdsu_special.v"
    )
    addResource(
      "external/cvfpu/vendor/opene906/E906_RTL_FACTORY/gen_rtl/fdsu/rtl/pa_fdsu_srt_single.v"
    )
    addResource("external/cvfpu/vendor/opene906/E906_RTL_FACTORY/gen_rtl/fdsu/rtl/pa_fdsu_top.v")
    addResource("external/cvfpu/vendor/opene906/E906_RTL_FACTORY/gen_rtl/fpu/rtl/pa_fpu_dp.v")
    addResource("external/cvfpu/vendor/opene906/E906_RTL_FACTORY/gen_rtl/fpu/rtl/pa_fpu_frbus.v")
    addResource("external/cvfpu/vendor/opene906/E906_RTL_FACTORY/gen_rtl/fpu/rtl/pa_fpu_src_type.v")
    addResource("external/cvfpu/src/fpnew_divsqrt_th_32.sv")
  } else {
    addResource("external/fpu_div_sqrt_mvp/hdl/defs_div_sqrt_mvp.sv")
    addResource("external/fpu_div_sqrt_mvp/hdl/iteration_div_sqrt_mvp.sv")
    addResource("external/fpu_div_sqrt_mvp/hdl/control_mvp.sv")
    addResource("external/fpu_div_sqrt_mvp/hdl/norm_div_sqrt_mvp.sv")
    addResource("external/fpu_div_sqrt_mvp/hdl/preprocess_mvp.sv")
    addResource("external/fpu_div_sqrt_mvp/hdl/nrbd_nrsc_mvp.sv")
    addResource("external/fpu_div_sqrt_mvp/hdl/div_sqrt_top_mvp.sv")
    addResource("external/fpu_div_sqrt_mvp/hdl/div_sqrt_mvp_wrapper.sv")
    addResource("external/cvfpu/src/fpnew_divsqrt_multi.sv")
  }
  addResource("external/cvfpu/src/fpnew_fma.sv")
  addResource("external/cvfpu/src/fpnew_fma_multi.sv")
  addResource("external/cvfpu/src/fpnew_noncomp.sv")
  addResource("external/cvfpu/src/fpnew_opgroup_block.sv")
  addResource("external/cvfpu/src/fpnew_opgroup_fmt_slice.sv")
  addResource("external/cvfpu/src/fpnew_opgroup_multifmt_slice.sv")
  addResource("external/cvfpu/src/fpnew_rounding.sv")
  addResource("external/cvfpu/src/fpnew_top.sv")
  setInline("FloatCoreWrapper.sv", GenerateCoreShimSource(p))
}

class FloatCore(p: Parameters) extends Module {
  val io = IO(new FloatCoreIO(p))

  val instQueue = Module(new Queue(new FloatInstruction(p), 1))
  instQueue.io.enq <> MakeDecoupled(io.inst.valid, instQueue.io.count === 0.U, io.inst.bits)
  val inst = instQueue.io.deq
  io.inst.ready := (instQueue.io.count === 0.U)

  val rstn             = (!reset.asBool).asAsyncReset
  val floatCoreWrapper = Module(new FloatCoreWrapper(p))

  floatCoreWrapper.io.clk_i  := clock
  floatCoreWrapper.io.rst_ni := rstn

  val opfp_operation = MuxLookup(inst.bits.funct5, FpNewOperation.ADD)(
    Seq(
      // FPNEW expects the same `opcode_i` for add and sub,
      // with a different value of `op_mod_i`.
      "b00000".U -> FpNewOperation.ADD,
      "b00001".U -> FpNewOperation.ADD,
      "b00010".U -> FpNewOperation.MUL,
      "b00011".U -> FpNewOperation.DIV,
      "b01011".U -> FpNewOperation.SQRT,
      "b00100".U -> FpNewOperation.SGNJ,
      "b00101".U -> FpNewOperation.MINMAX,
      "b11000".U -> FpNewOperation.F2I,
      "b10100".U -> FpNewOperation.CMP,
      "b11100".U -> FpNewOperation.CLASSIFY,
      "b11010".U -> FpNewOperation.I2F,
      "b01000".U -> FpNewOperation.F2F
    )
  )
  val opfp_mod = MuxLookup(inst.bits.funct5, 0.U(1.W))(
    Seq(
      "b00000".U -> 0.U(1.W),         // ADD
      "b00001".U -> 1.U(1.W),         // SUB
      "b00100".U -> 1.U(1.W),         // FpNewOperation.SGNJ, Nan-Boxing,
      "b11000".U -> inst.bits.rs2(0), // F2I -- 0 is signed, 1 is unsigned
      "b11010".U -> inst.bits.rs2(0)  // I2F, same sign behaviour as above
    )
  )

  val op_i = MuxLookup(inst.bits.opcode, FpNewOperation.ADD)(
    Seq(
      FloatOpcode.OPFP    -> opfp_operation,
      FloatOpcode.MADD    -> FpNewOperation.FMADD,
      FloatOpcode.MSUB    -> FpNewOperation.FMADD,
      FloatOpcode.NMADD   -> FpNewOperation.FNMSUB,
      FloatOpcode.NMSUB   -> FpNewOperation.FNMSUB,
      FloatOpcode.STOREFP -> FpNewOperation.STORE
    )
  )
  val op_mod_i = MuxLookup(inst.bits.opcode, 0.U(1.W))(
    Seq(
      FloatOpcode.OPFP  -> opfp_mod,
      FloatOpcode.MADD  -> 0.U(1.W),
      FloatOpcode.MSUB  -> 1.U(1.W),
      FloatOpcode.NMADD -> 1.U(1.W),
      FloatOpcode.NMSUB -> 0.U(1.W)
    )
  )

  // For more details on which ports are used by each operation,
  // consult the README for fpnew.
  val read_port_0_valid =
    MuxOR(op_i =/= FpNewOperation.ADD, true.B) // All ops but ADD/SUB use op0
  val read_port_1_valid = op_i.isOneOf(FpNewOperation.FMADD, FpNewOperation.FNMSUB) ||
    (
      inst.bits.opcode === FloatOpcode.OPFP &&
        !opfp_operation.isOneOf(
          FpNewOperation.SQRT,
          FpNewOperation.CLASSIFY,
          FpNewOperation.F2I,
          FpNewOperation.I2F,
          FpNewOperation.F2F
        )
    )
  val read_port_2_valid = op_i.isOneOf(FpNewOperation.FMADD, FpNewOperation.FNMSUB) ||
    (inst.bits.opcode === FloatOpcode.OPFP && opfp_operation === FpNewOperation.ADD)
  val read_ports_valid = VecInit(
    Seq(
      read_port_0_valid,
      read_port_1_valid,
      read_port_2_valid
    )
  )
  for (i <- 0 until FpNewConfig.NUM_OPERANDS) {
    io.read_ports(i).valid := read_ports_valid(i) && inst.valid
    if (i == 0) {
      floatCoreWrapper.io.operands_i(0) :=
        Mux(
          (inst.bits.opcode === FloatOpcode.OPFP) && (opfp_operation === FpNewOperation.I2F),
          io.rs1.data,
          io.read_ports(0).data.asWord
        )
    } else {
      floatCoreWrapper.io.operands_i(i) := io.read_ports(i).data.asWord
    }
  }

  val fmt         = inst.bits.inst(26, 25)
  val is_fmt_fp32 = fmt === 0.U
  val is_fmt_bf16 = (fmt === 2.U) && p.enableZfbfmin.B

  val fmv_funct5_valid = (inst.bits.funct5 === "b11100".U) || (inst.bits.funct5 === "b11110".U)
  val fmv              =
    inst.valid && (inst.bits.opcode === FloatOpcode.OPFP) && fmv_funct5_valid && (inst.bits.rm === "b000".U) && (is_fmt_fp32 || is_fmt_bf16)
  val fmv_to_gpr = fmv && (inst.bits.funct5 === "b11100".U)
  val fmv_to_fpr = fmv && (inst.bits.funct5 === "b11110".U)
  val storefp    = inst.valid && (inst.bits.opcode === FloatOpcode.STOREFP)

  val op0_addr = inst.bits.rs1
  val op1_addr = Mux(op_i === FpNewOperation.ADD, inst.bits.rs1, inst.bits.rs2)
  val op2_addr = Mux(op_i === FpNewOperation.ADD, inst.bits.rs2, inst.bits.rs3)
  io.read_ports(0).addr := op0_addr
  io.read_ports(1).addr := op1_addr
  io.read_ports(2).addr := op2_addr

  floatCoreWrapper.io.op_i      := op_i.asUInt
  floatCoreWrapper.io.op_mod_i  := op_mod_i
  floatCoreWrapper.io.src_fmt_i := inst.bits.src_fmt.asUInt
  floatCoreWrapper.io.dst_fmt_i := inst.bits.dst_fmt.asUInt
  val (inst_rm, inst_rm_valid) = FpNewRoundingMode.safe(inst.bits.rm)
  val (csr_rm, csr_rm_valid)   = FpNewRoundingMode.safe(io.csr.out.frm)
  val rnd_mode                 = MuxCase(
    MakeValid(false.B, inst_rm),
    Seq(
      !inst_rm_valid                                       -> MakeValid(false.B, inst_rm),
      (inst_rm =/= FpNewRoundingMode.DYN)                  -> MakeValid(true.B, inst_rm),
      !csr_rm_valid                                        -> MakeValid(false.B, csr_rm),
      (csr_rm_valid && (csr_rm === FpNewRoundingMode.DYN)) -> MakeValid(false.B, csr_rm),
      csr_rm_valid                                         -> MakeValid(true.B, csr_rm)
    )
  )
  floatCoreWrapper.io.rnd_mode_i := rnd_mode.bits.asUInt

  // Track whether an instruction has been accepted by the input side of fpnew.
  // This allows us to unblock dispatch immediately,
  // while waiting on an instruction that may take multiple cycles to execute (e.g. DIV/SQRT).
  val fpuActive = RegInit(false.B)
  fpuActive := MuxCase(
    fpuActive,
    Seq(
      inst.fire                                                          -> false.B,
      (floatCoreWrapper.io.in_valid_i && floatCoreWrapper.io.in_ready_o) -> true.B
    )
  )
  floatCoreWrapper.io.flush_i    := false.B
  floatCoreWrapper.io.in_valid_i := (inst.valid && !fmv) && !fpuActive && rnd_mode.valid

  val fmv_fpr_data = Mux(is_fmt_bf16, Cat("hffff".U(16.W), io.rs1.data(15, 0)), io.rs1.data(31, 0))
  io.write_ports(0)
    .valid := ((floatCoreWrapper.io.out_valid_o && inst.fire && !inst.bits.scalar_rd) || fmv_to_fpr) && !storefp
  io.write_ports(0).addr := inst.bits.rd
  io.write_ports(0).data := Fp32.fromWord(
    Mux(fmv_to_fpr, fmv_fpr_data, floatCoreWrapper.io.result_o)
  )

  io.write_ports(1).valid := io.lsu_rd.valid
  io.write_ports(1).addr  := io.lsu_rd.bits.addr
  io.write_ports(1).data  := Fp32.fromWord(io.lsu_rd.bits.data)

  io.csr.in.fflags.valid := (floatCoreWrapper.io.out_valid_o && inst.fire && !fmv)
  io.csr.in.fflags.bits  := floatCoreWrapper.io.status_o.asUInt

  val scalar_rd_pre_pipe = Wire(Decoupled(new RegfileWriteDataIO(p)))
  scalar_rd_pre_pipe.valid := (((floatCoreWrapper.io.in_valid_i && floatCoreWrapper.io.in_ready_o) || fpuActive) && floatCoreWrapper.io.out_valid_o && floatCoreWrapper.io.out_ready_i && inst.bits.scalar_rd) || (fmv_to_gpr)
  scalar_rd_pre_pipe.bits.addr := inst.bits.rd
  val fmv_gpr_data = Mux(
    is_fmt_bf16,
    Cat(Fill(16, io.read_ports(0).data.asWord(15)), io.read_ports(0).data.asWord(15, 0)),
    io.read_ports(0).data.asWord
  )
  scalar_rd_pre_pipe.bits.data := Mux(
    fmv_to_gpr,
    fmv_gpr_data,
    floatCoreWrapper.io.result_o
  )

  val scalar_rd_pipe = Queue(scalar_rd_pre_pipe, 2, false)
  io.scalar_rd <> scalar_rd_pipe

  floatCoreWrapper.io.out_ready_i := (inst.valid && inst.bits.scalar_rd && scalar_rd_pre_pipe.ready) || (inst.valid && !inst.bits.scalar_rd)
  inst.ready := (((floatCoreWrapper.io.in_ready_o && floatCoreWrapper.io.in_valid_i) || fpuActive) && floatCoreWrapper.io.out_ready_i && floatCoreWrapper.io.out_valid_o) || fmv
}
