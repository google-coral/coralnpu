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

`verilator_config
// Top-level IO, clock and reset, as in the default template.
public -module "{HDL_TOPLEVEL}" -var "io_*"
public -module "{HDL_TOPLEVEL}" -var "clock"
public -module "{HDL_TOPLEVEL}" -var "reset"

// RVVI retirement trace, one set of ports per retirement lane N.
public -module "RvviTraceBlackBox" -var "valid_i_*"
public -module "RvviTraceBlackBox" -var "order_i_*"
public -module "RvviTraceBlackBox" -var "insn_i_*"
public -module "RvviTraceBlackBox" -var "trap_i_*"
public -module "RvviTraceBlackBox" -var "pc_rdata_i_*"
public -module "RvviTraceBlackBox" -var "x_wb_i_*"
public -module "RvviTraceBlackBox" -var "x_wdata_i_*"
public -module "RvviTraceBlackBox" -var "f_wb_i_*"
public -module "RvviTraceBlackBox" -var "f_wdata_i_*"
public -module "RvviTraceBlackBox" -var "v_wb_i_*"