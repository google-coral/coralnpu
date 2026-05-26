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
import coralnpu.Parameters

// =============================================================================
// FMA/FDIV BlackBox wrappers around FPNew (third-party Verilog IP)
//
// These modules instantiate the Verilog FPNew-based FMA and FDIV wrappers
// which provide IEEE-754 floating-point operations per RVV lane.
// =============================================================================

// FMA Wrapper BlackBox — wraps rvv_backend_fma_wrapper.sv
class RvvFmaWrapper(p: Parameters) extends BlackBox with HasBlackBoxResource {
  val io = IO(new Bundle {
    val clk   = Input(Clock())
    val rst_n = Input(Reset())

    val fma_uop_vld = Input(Bool())
    // Simplified uop interface
    val fma_uop_vs1_data = Input(UInt(p.rvvVlen.W))
    val fma_uop_vs2_data = Input(UInt(p.rvvVlen.W))
    val fma_uop_vs3_data = Input(UInt(p.rvvVlen.W))
    val fma_uop_rs1_data = Input(UInt(32.W))
    val fma_uop_funct3   = Input(UInt(3.W))
    val fma_uop_funct6   = Input(UInt(6.W))
    val fma_uop_frm      = Input(UInt(3.W))
    val fma_uop_rob_entry = Input(UInt(3.W))

    val fma_type = Input(UInt(4.W))

    val fma_uop_addmul_rdy = Output(Bool())
    val fma_uop_cmp_rdy    = Output(Bool())
    val fma_uop_cvt_rdy    = Output(Bool())
    val fma_uop_tbl_rdy    = Output(Bool())

    val trap_flush_rvv = Input(Bool())

    val fma_result_vld = Output(Bool())
    val fma_result_w_data = Output(UInt(p.rvvVlen.W))
    val fma_result_rob_entry = Output(UInt(3.W))
    val fma_result_w_valid = Output(Bool())
    val fma_result_rdy = Input(Bool())
  })

  addResource("hdl/verilog/rvv/design/rvv_backend_fma_wrapper.sv")
  addResource("hdl/verilog/rvv/design/rvv_backend_sqrt7_rec7.sv")
  addResource("hdl/verilog/rvv/design/rvv_backend_fma.sv")
  addResource("hdl/verilog/rvv/inc/rvv_backend_fma.svh")
  addResource("hdl/verilog/rvv/inc/rvv_backend.svh")
  addResource("hdl/verilog/rvv/inc/rvv_backend_define.svh")
  addResource("hdl/verilog/rvv/inc/rvv_backend_config.svh")
  addResource("hdl/verilog/rvv/inc/rvv_backend_sva.svh")
  addResource("external/cvfpu/src/fpnew_pkg.sv")
  addResource("external/cvfpu/src/fpnew_fma_multi.sv")
  addResource("external/cvfpu/src/fpnew_noncomp.sv")
  addResource("external/cvfpu/src/fpnew_cast_multi.sv")
  addResource("external/cvfpu/src/fpnew_classifier.sv")
  addResource("external/common_cells/include/common_cells/registers.svh")
  addResource("external/common_cells/src/cf_math_pkg.sv")
  addResource("external/common_cells/src/lzc.sv")
  addResource("external/common_cells/src/rr_arb_tree.sv")
}

// FDIV Wrapper BlackBox — wraps rvv_backend_fdiv_wrapper.sv
class RvvFdivWrapper(p: Parameters) extends BlackBox with HasBlackBoxResource {
  val io = IO(new Bundle {
    val clk   = Input(Clock())
    val rst_n = Input(Reset())

    val fdiv_uop_valid = Input(Bool())
    val fdiv_uop_vs1_data = Input(UInt(p.rvvVlen.W))
    val fdiv_uop_vs2_data = Input(UInt(p.rvvVlen.W))
    val fdiv_uop_funct3   = Input(UInt(3.W))
    val fdiv_uop_funct6   = Input(UInt(6.W))
    val fdiv_uop_frm      = Input(UInt(3.W))
    val fdiv_uop_rob_entry = Input(UInt(3.W))
    val fdiv_uop_ready    = Output(Bool())

    val trap_flush_rvv = Input(Bool())

    val result_valid = Output(Bool())
    val result_w_data = Output(UInt(p.rvvVlen.W))
    val result_rob_entry = Output(UInt(3.W))
    val result_w_valid = Output(Bool())
    val result_ready = Input(Bool())
  })

  addResource("hdl/verilog/rvv/design/rvv_backend_fdiv_wrapper.sv")
  addResource("hdl/verilog/rvv/inc/rvv_backend.svh")
  addResource("hdl/verilog/rvv/inc/rvv_backend_define.svh")
  addResource("hdl/verilog/rvv/inc/rvv_backend_config.svh")
  addResource("hdl/verilog/rvv/inc/rvv_backend_sva.svh")
  addResource("external/cvfpu/src/fpnew_pkg.sv")
  addResource("external/cvfpu/src/fpnew_divsqrt_multi.sv")
  addResource("external/cvfpu/src/fpnew_divsqrt_th_64_multi.sv")
  addResource("external/fpu_div_sqrt_mvp/src/div_sqrt_top_mvp.sv")
  addResource("external/fpu_div_sqrt_mvp/src/control_mvp.sv")
  addResource("external/fpu_div_sqrt_mvp/src/norm_div_sqrt_mvp.sv")
  addResource("external/fpu_div_sqrt_mvp/src/nrbd_nrsc_mvp.sv")
  addResource("external/fpu_div_sqrt_mvp/src/preprocess_mvp.sv")
  addResource("external/fpu_div_sqrt_mvp/src/iteration_div_sqrt_mvp.sv")
  addResource("external/fpu_div_sqrt_mvp/vendor/C910_DivSqrt/ct_vfdsu_top.v")
  addResource("external/fpu_div_sqrt_mvp/vendor/C910_DivSqrt/ct_vfdsu_srt.v")
  addResource("external/fpu_div_sqrt_mvp/vendor/C910_DivSqrt/ct_vfdsu_double.v")
  addResource("external/fpu_div_sqrt_mvp/vendor/C910_DivSqrt/ct_vfdsu_scalar_dp.v")
  addResource("external/fpu_div_sqrt_mvp/vendor/C910_DivSqrt/ct_vfdsu_prepare.v")
  addResource("external/fpu_div_sqrt_mvp/vendor/C910_DivSqrt/ct_vfdsu_ctrl.v")
  addResource("external/fpu_div_sqrt_mvp/vendor/C910_DivSqrt/ct_vfdsu_round.v")
  addResource("external/fpu_div_sqrt_mvp/vendor/C910_DivSqrt/ct_vfdsu_pack.v")
  addResource("external/fpu_div_sqrt_mvp/vendor/C910_DivSqrt/ct_vfdsu_ff1.v")
  addResource("external/fpu_div_sqrt_mvp/vendor/C910_DivSqrt/ct_vfdsu_srt_radix16_with_sqrt.v")
  addResource("external/fpu_div_sqrt_mvp/vendor/C910_DivSqrt/ct_vfdsu_srt_radix16_bound_table.v")
  addResource("external/fpu_div_sqrt_mvp/vendor/C910_DivSqrt/gated_clk_cell.v")
  addResource("external/common_cells/include/common_cells/registers.svh")
  addResource("external/common_cells/src/cf_math_pkg.sv")
  addResource("external/common_cells/src/lzc.sv")
  addResource("external/common_cells/src/rr_arb_tree.sv")
}
