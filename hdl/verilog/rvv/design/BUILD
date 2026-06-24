# Copyright 2024 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

load("@rules_hdl//verilog:providers.bzl", "verilog_library")
load("//rules:vcs.bzl", "vcs_testbench_test")

exports_files(
    srcs = [
        "Aligner.sv",
        "FPnew/C910_DivSqrt/ct_vfdsu_ctrl.v",  # New
        "FPnew/C910_DivSqrt/ct_vfdsu_double.v",  # New
        "FPnew/C910_DivSqrt/ct_vfdsu_ff1.v",  # New
        "FPnew/C910_DivSqrt/ct_vfdsu_pack.v",  # New
        "FPnew/C910_DivSqrt/ct_vfdsu_prepare.v",  # New
        "FPnew/C910_DivSqrt/ct_vfdsu_round.v",  # New
        "FPnew/C910_DivSqrt/ct_vfdsu_scalar_dp.v",  # New
        "FPnew/C910_DivSqrt/ct_vfdsu_srt.v",  # New
        "FPnew/C910_DivSqrt/ct_vfdsu_srt_radix16_bound_table.v",  # New
        "FPnew/C910_DivSqrt/ct_vfdsu_srt_radix16_with_sqrt.v",  # New
        "FPnew/C910_DivSqrt/ct_vfdsu_top.v",  # New
        "FPnew/C910_DivSqrt/gated_clk_cell.v",  # New
        "FPnew/common_cells/inc/assertions.svh",  # New
        "FPnew/common_cells/inc/registers.svh",  # New
        "FPnew/common_cells/src/cf_math_pkg.sv",  # New
        "FPnew/common_cells/src/lzc.sv",  # New
        "FPnew/common_cells/src/rr_arb_tree.sv",  # New
        "FPnew/fpnew_cast_multi.sv",  # New
        "FPnew/fpnew_classifier.sv",  # New
        "FPnew/fpnew_divsqrt_multi.sv",  # New
        "FPnew/fpnew_divsqrt_th_64_multi.sv",  # New
        "FPnew/fpnew_fma_multi.sv",  # New
        "FPnew/fpnew_noncomp.sv",  # New
        "FPnew/fpnew_pkg.sv",  # New
        "FPnew/fpnew_rounding.sv",  # New
        "FPnew/fpu_div_sqrt_mvp/control_mvp.sv",  # New
        "FPnew/fpu_div_sqrt_mvp/defs_div_sqrt_mvp.sv",  # New
        "FPnew/fpu_div_sqrt_mvp/div_sqrt_top_mvp.sv",  # New
        "FPnew/fpu_div_sqrt_mvp/iteration_div_sqrt_mvp.sv",  # New
        "FPnew/fpu_div_sqrt_mvp/norm_div_sqrt_mvp.sv",  # New
        "FPnew/fpu_div_sqrt_mvp/nrbd_nrsc_mvp.sv",  # New
        "FPnew/fpu_div_sqrt_mvp/preprocess_mvp.sv",  # New
        "MultiFifo.sv",
        "RvvCore.sv",
        "RvvFrontEnd.sv",
        "Zvt/fp_absaddsub.sv",
        "Zvt/fp_addfront.sv",
        "Zvt/fp_align.sv",
        "Zvt/fp_classifier.sv",
        "Zvt/fp_mulfront.sv",
        "Zvt/fp_rounding.sv",
        "Zvt/zvt.sv",
        "Zvt/zvt_acc.sv",
        "Zvt/zvt_acc_reg.sv",
        "Zvt/zvt_ctrl.sv",
        "Zvt/zvt_pe_adder.sv",
        "Zvt/zvt_pe_adder_fp_lane.sv",
        "Zvt/zvt_pe_adder_int_lane.sv",
        "Zvt/zvt_pe_array.sv",
        "Zvt/zvt_pe_block.sv",
        "Zvt/zvt_pe_mulbulk.sv",
        "Zvt/zvt_pe_mulbulk_fp_lane.sv",
        "Zvt/zvt_pe_mulbulk_int_lane.sv",
        "rvv.svh",
        "rvv_backend.sv",
        "rvv_backend_alu.sv",
        "rvv_backend_alu_unit.sv",
        "rvv_backend_alu_unit_addsub.sv",
        "rvv_backend_alu_unit_execution_p1.sv",
        "rvv_backend_alu_unit_mask.sv",
        "rvv_backend_alu_unit_mask_viota.sv",
        "rvv_backend_alu_unit_other.sv",
        "rvv_backend_alu_unit_shift.sv",
        "rvv_backend_arb.sv",  # New
        "rvv_backend_decode.sv",
        "rvv_backend_decode_ctrl.sv",
        "rvv_backend_decode_de2.sv",  # New
        "rvv_backend_decode_unit.sv",
        "rvv_backend_decode_unit_ari.sv",
        "rvv_backend_decode_unit_ari_de2.sv",  # New
        "rvv_backend_decode_unit_de2.sv",  # New
        "rvv_backend_decode_unit_lsu.sv",
        "rvv_backend_decode_unit_lsu_de2.sv",  # New
        "rvv_backend_dispatch.sv",
        "rvv_backend_dispatch_bypass.sv",
        "rvv_backend_dispatch_ctrl.sv",
        "rvv_backend_dispatch_operand.sv",
        "rvv_backend_dispatch_opr_byte_type.sv",
        "rvv_backend_dispatch_raw_uop_rob.sv",
        "rvv_backend_dispatch_raw_uop_uop.sv",
        "rvv_backend_dispatch_structure_hazard.sv",
        "rvv_backend_div.sv",
        "rvv_backend_div_unit.sv",
        "rvv_backend_falu.sv",
        "rvv_backend_falu_unit.sv",
        "rvv_backend_fdiv_unit.sv",
        "rvv_backend_fdiv_wrapper.sv",  # New
        "rvv_backend_freduction.sv",  # New
        "rvv_backend_lsu_remap.sv",
        "rvv_backend_mac_unit.sv",
        "rvv_backend_mul_unit.sv",
        "rvv_backend_mul_unit_mul8.sv",
        "rvv_backend_mulmac.sv",
        "rvv_backend_pmtrdt.sv",
        "rvv_backend_pmtrdt_unit.sv",
        "rvv_backend_pmtrdt_unit_permutation.sv",  # New
        "rvv_backend_pmtrdt_unit_reduction.sv",  # New
        "rvv_backend_pmtrdt_unit_reduction_alu.sv",  # New
        "rvv_backend_retire.sv",
        "rvv_backend_retire_waw.sv",  # New
        "rvv_backend_rob.sv",
        "rvv_backend_sqrt7_rec7.sv",  # New
        "rvv_backend_vrf.sv",
        "rvv_backend_vrf_reg.sv",
        "rvv_define.svh",
    ],
    visibility = ["//visibility:public"],
)

verilog_library(
    name = "aligner",
    srcs = [
        "Aligner.sv",
    ],
    visibility = ["//visibility:public"],
)

vcs_testbench_test(
    name = "aligner_tb",
    srcs = ["Aligner_tb.sv"],
    module = "Aligner_tb",
    deps = ":aligner",
)

verilog_library(
    name = "multififo",
    srcs = [
        "MultiFifo.sv",
    ],
    visibility = ["//visibility:public"],
)

vcs_testbench_test(
    name = "multififo_tb",
    srcs = ["MultiFifo_tb.sv"],
    module = "MultiFifo_tb",
    deps = ":multififo",
)
