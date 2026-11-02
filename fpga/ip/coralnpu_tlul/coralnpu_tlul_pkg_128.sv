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

package coralnpu_tlul_pkg_128;
  import tlul_pkg::*;
  import top_pkg::*;

  parameter ArbiterImpl = "PPC";

  localparam int TL_DW = 128;
  localparam int TL_DBW = TL_DW / 8;
  localparam int TL_SZW = $clog2(TL_DW);
  localparam int TL_AIW = 10;

  typedef struct packed {
    logic [RsvdWidth - 1 : 0] rsvd;
    prim_mubi_pkg::mubi4_t instr_type;
    logic [H2DCmdIntgWidth - 1 : 0] cmd_intg;
    logic [DataIntgWidth - 1 : 0] data_intg;
  } tl_a_user_t;

  typedef struct packed {
    logic a_valid;
    tl_a_op_e a_opcode;
    logic [2 : 0] a_param;
    logic [TL_SZW - 1 : 0] a_size;
    logic [TL_AIW - 1 : 0] a_source;
    logic [TL_AW - 1 : 0] a_address;
    logic [TL_DBW - 1 : 0] a_mask;
    logic [TL_DW - 1 : 0] a_data;
    tl_a_user_t a_user;
    logic d_ready;
  } tl_h2d_t;

  typedef struct packed {
    logic d_valid;
    tl_d_op_e d_opcode;
    logic [2 : 0] d_param;
    logic [TL_SZW - 1 : 0] d_size;
    logic [TL_AIW - 1 : 0] d_source;
    logic [TL_DIW - 1 : 0] d_sink;
    logic [TL_DW - 1 : 0] d_data;
    tl_d_user_t d_user;
    logic d_error;
    logic a_ready;
  } tl_d2h_t;

  localparam logic [top_pkg::TL_DW - 1 : 0] BlankedAData = {top_pkg::TL_DW{1'b1}};

  // return inverted integrity for command payload
  function automatic logic [H2DCmdIntgWidth - 1 : 0] get_bad_cmd_intg(tl_h2d_t tl);
    logic [H2DCmdIntgWidth - 1 : 0] cmd_intg;
    cmd_intg = get_cmd_intg(tl);
    return ~cmd_intg;
  endfunction  // get_bad_cmd_intg

  // return inverted integrity for data payload
  function automatic logic [H2DCmdIntgWidth - 1 : 0] get_bad_data_intg(
      logic [top_pkg::TL_DW - 1 : 0] data);
    logic [H2DCmdIntgWidth - 1 : 0] data_intg;
    data_intg = get_data_intg(data);
    return ~data_intg;
  endfunction  // get_bad_data_intg
endpackage
