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

`ifndef HDL_VERILOG_RVV_COMMON_COMPOUND_INCREMENTER_SIMD32_SV
`define HDL_VERILOG_RVV_COMMON_COMPOUND_INCREMENTER_SIMD32_SV

(* keep_hierarchy = "yes" *)
module compound_incrementer_simd32 (
  input  logic [31:0] a,
  input  logic [1:0]  eew,        // 0=EEW8, 1=EEW16, 2=EEW32
  input  logic [3:0]  inc,        // Increment enable per sub-element
  input  logic        shift_is_arith,
  output logic [31:0] sum0,       // sum0 = a
  output logic [31:0] sum1,       // sum1 = a + 1 per active sub-element
  output logic [31:0] sum,        // Selected sum based on inc
  output logic [3:0]  cout        // Carry out per active sub-element
);
  assign sum0 = a;

  // ---------------------------------------------------------------------------
  // Step 1: Compute Prefix-AND within each 8-bit byte (Depth: 3 gates)
  // ---------------------------------------------------------------------------
  logic [3:0][7:0] c8;
  genvar b;
  generate
    for (b = 0; b < 4; b = b + 1) begin : gen_byte_prefix
      logic [7:0] byte_in;
      logic [7:0] l1, l2, l3;
      assign byte_in = a[b*8 +: 8];

      // Distance 1
      assign l1[0] = byte_in[0];
      assign l1[1] = byte_in[1] & byte_in[0];
      assign l1[2] = byte_in[2] & byte_in[1];
      assign l1[3] = byte_in[3] & byte_in[2];
      assign l1[4] = byte_in[4] & byte_in[3];
      assign l1[5] = byte_in[5] & byte_in[4];
      assign l1[6] = byte_in[6] & byte_in[5];
      assign l1[7] = byte_in[7] & byte_in[6];

      // Distance 2
      assign l2[0] = l1[0];
      assign l2[1] = l1[1];
      assign l2[2] = l1[2] & l1[0];
      assign l2[3] = l1[3] & l1[1];
      assign l2[4] = l1[4] & l1[2];
      assign l2[5] = l1[5] & l1[3];
      assign l2[6] = l1[6] & l1[4];
      assign l2[7] = l1[7] & l1[5];

      // Distance 4
      assign l3[0] = l2[0];
      assign l3[1] = l2[1];
      assign l3[2] = l2[2];
      assign l3[3] = l2[3];
      assign l3[4] = l2[4] & l2[0];
      assign l3[5] = l2[5] & l2[1];
      assign l3[6] = l2[6] & l2[2];
      assign l3[7] = l2[7] & l2[3];

      assign c8[b] = l3;
    end
  endgenerate

  // ---------------------------------------------------------------------------
  // Step 2: Merge across 16-bit halfword (Depth: 4 gates)
  // ---------------------------------------------------------------------------
  logic [1:0][15:0] c16;
  generate
    for (b = 0; b < 2; b = b + 1) begin : gen_hword_prefix
      assign c16[b][7:0] = c8[2*b];
      for (genvar j = 0; j < 8; j = j + 1) begin : gen_hword_hi
        assign c16[b][8+j] = c8[2*b+1][j] & c8[2*b][7];
      end
    end
  endgenerate

  // ---------------------------------------------------------------------------
  // Step 3: Merge across 32-bit word (Depth: 5 gates)
  // ---------------------------------------------------------------------------
  logic [31:0] c32;
  assign c32[15:0] = c16[0];
  generate
    for (genvar j = 0; j < 16; j = j + 1) begin : gen_word_hi
      assign c32[16+j] = c16[1][j] & c16[0][15];
    end
  endgenerate

  // ---------------------------------------------------------------------------
  // Step 4: Generate sum1 (a + 1) per active EEW
  // ---------------------------------------------------------------------------
  always_comb begin
    case (eew)
      2'b00: begin // EEW8
        sum1[0]     = ~a[0];
        sum1[7:1]   = a[7:1]   ^ c8[0][6:0];
        sum1[8]     = ~a[8];
        sum1[15:9]  = a[15:9]  ^ c8[1][6:0];
        sum1[16]    = ~a[16];
        sum1[23:17] = a[23:17] ^ c8[2][6:0];
        sum1[24]    = ~a[24];
        sum1[31:25] = a[31:25] ^ c8[3][6:0];
      end
      2'b01: begin // EEW16
        sum1[0]     = ~a[0];
        sum1[15:1]  = a[15:1]  ^ c16[0][14:0];
        sum1[16]    = ~a[16];
        sum1[31:17] = a[31:17] ^ c16[1][14:0];
      end
      default: begin // EEW32
        sum1[0]     = ~a[0];
        sum1[31:1]  = a[31:1]  ^ c32[30:0];
      end
    endcase
  end

  // ---------------------------------------------------------------------------
  // Step 5: Select Sum and Carry Out based on increment enable
  // ---------------------------------------------------------------------------
  always_comb begin
    case (eew)
      2'b00: begin // EEW8
        sum[7:0]   = inc[0] ? sum1[7:0]   : a[7:0];
        sum[15:8]  = inc[1] ? sum1[15:8]  : a[15:8];
        sum[23:16] = inc[2] ? sum1[23:16] : a[23:16];
        sum[31:24] = inc[3] ? sum1[31:24] : a[31:24];

        if (shift_is_arith) begin
          cout[0] = inc[0] ? (a[7]  ^ c8[0][7]) : a[7];
          cout[1] = inc[1] ? (a[15] ^ c8[1][7]) : a[15];
          cout[2] = inc[2] ? (a[23] ^ c8[2][7]) : a[23];
          cout[3] = inc[3] ? (a[31] ^ c8[3][7]) : a[31];
        end else begin
          cout[0] = inc[0] ? c8[0][7] : 1'b0;
          cout[1] = inc[1] ? c8[1][7] : 1'b0;
          cout[2] = inc[2] ? c8[2][7] : 1'b0;
          cout[3] = inc[3] ? c8[3][7] : 1'b0;
        end
      end

      2'b01: begin // EEW16
        sum[15:0]  = inc[0] ? sum1[15:0]  : a[15:0];
        sum[31:16] = inc[1] ? sum1[31:16] : a[31:16];

        if (shift_is_arith) begin
          cout[0] = inc[0] ? (a[15] ^ c16[0][15]) : a[15];
          cout[1] = inc[1] ? (a[31] ^ c16[1][15]) : a[31];
        end else begin
          cout[0] = inc[0] ? c16[0][15] : 1'b0;
          cout[1] = inc[1] ? c16[1][15] : 1'b0;
        end
        cout[2] = 1'b0;
        cout[3] = 1'b0;
      end

      default: begin // EEW32
        sum = inc[0] ? sum1 : a;

        if (shift_is_arith) begin
          cout[0] = inc[0] ? (a[31] ^ c32[31]) : a[31];
        end else begin
          cout[0] = inc[0] ? c32[31] : 1'b0;
        end
        cout[1] = 1'b0;
        cout[2] = 1'b0;
        cout[3] = 1'b0;
      end
    endcase
  end

endmodule

`endif // HDL_VERILOG_RVV_COMMON_COMPOUND_INCREMENTER_SIMD32_SV
