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

module priority_encoder_tree_node #( // verilog_lint: waive module-filename
  parameter int WIDTH = 128,
  parameter int IDX_WIDTH = (WIDTH > 1) ? $clog2(WIDTH) : 1
) (
  input  logic [WIDTH-1:0]     in_data,
  output logic [WIDTH-1:0]     out_onehot,
  output logic [IDX_WIDTH-1:0] out_index,
  output logic                 out_valid
);

  generate
    if (WIDTH == 2) begin : gen_base2
      assign out_valid     = in_data[0] | in_data[1];
      assign out_index[0]  = ~in_data[0] & in_data[1];
      assign out_onehot[0] = in_data[0];
      assign out_onehot[1] = ~in_data[0] & in_data[1];
    end else if (WIDTH > 2) begin : gen_recurse
      localparam int Half = WIDTH / 2;
      localparam int SubIdx = $clog2(Half);

      logic [Half-1:0]    oh_lo, oh_hi;
      logic [SubIdx-1:0]  idx_lo, idx_hi;
      logic               val_lo, val_hi;

      priority_encoder_tree_node #(
        .WIDTH(Half)
      ) u_lo (
        .in_data   (in_data[Half-1:0]),
        .out_onehot(oh_lo),
        .out_index (idx_lo),
        .out_valid (val_lo)
      );

      priority_encoder_tree_node #(
        .WIDTH(Half)
      ) u_hi (
        .in_data   (in_data[WIDTH-1:Half]),
        .out_onehot(oh_hi),
        .out_index (idx_hi),
        .out_valid (val_hi)
      );

      assign out_valid = val_lo | val_hi;
      assign out_index[IDX_WIDTH-1] = ~val_lo & val_hi;
      assign out_index[IDX_WIDTH-2:0] = val_lo ? idx_lo : idx_hi;
      assign out_onehot = {val_lo ? {Half{1'b0}} : oh_hi, oh_lo};
    end else begin : gen_base1
      assign out_valid     = in_data[0];
      assign out_index[0]  = 1'b0;
      assign out_onehot[0] = in_data[0];
    end
  endgenerate

endmodule

(* keep_hierarchy = "yes" *)
module priority_encoder_tree #(
  parameter int WIDTH = 128,
  parameter int IDX_WIDTH = (WIDTH > 1) ? $clog2(WIDTH) : 1
) (
  input  logic [WIDTH-1:0]     in_data,
  output logic [WIDTH-1:0]     out_onehot,
  output logic [IDX_WIDTH-1:0] out_index,
  output logic                 out_valid
);

  priority_encoder_tree_node #(
    .WIDTH    (WIDTH),
    .IDX_WIDTH(IDX_WIDTH)
  ) u_tree (
    .in_data   (in_data),
    .out_onehot(out_onehot),
    .out_index (out_index),
    .out_valid (out_valid)
  );

endmodule
