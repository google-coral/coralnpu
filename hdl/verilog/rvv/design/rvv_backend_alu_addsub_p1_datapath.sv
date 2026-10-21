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

`ifndef HDL_VERILOG_RVV_DESIGN_RVV_SVH
`include "rvv_backend.svh"
`endif
`ifndef ALU_DEFINE_SVH
`include "rvv_backend_alu.svh"
`endif

(* keep_hierarchy = "yes" *)
module rvv_backend_alu_addsub_p1_datapath (
  input  logic        is_sub,
  input  EEW_e        vs2_eew,
  input  FUNCT6_u     uop_funct6,
  input  RVVXRM       vxrm,
  input  logic [3:0]  src2_sgn,
  input  logic [3:0]  src1_sgn,
  input  logic [31:0] product8_in,
  input  logic [3:0]  cout8_in,

  // P1 stage outputs
  output logic [31:0] product16_out,
  output logic [1:0]  cout16_out,
  output logic [31:0] product32_out,
  output logic        cout32_out,
  output logic [31:0] round8_out,
  output logic [31:0] round16_out,
  output logic [31:0] round32_out,

  // Overflow and Saturation signals
  output logic [3:0]  addu_upoverflow,
  output logic [3:0]  add_upoverflow,
  output logic [3:0]  add_underoverflow,
  output logic [3:0]  subu_underoverflow,
  output logic [3:0]  sub_upoverflow,
  output logic [3:0]  sub_underoverflow
);

  // P1 16-bit and 32-bit Recombination
  logic [3:0][7:0]  p8_in_bytes;
  logic [1:0][15:0] p16_words;
  logic [31:0]      p32_word;

  assign p8_in_bytes = product8_in;

  always_comb begin
    for (int i = 0; i < 2; i = i + 1) begin
      if (!is_sub) begin
        {cout16_out[i], product16_out[16*i +: 16]} = {
          ({cout8_in[2*i+1], p8_in_bytes[2*i+1]} + cout8_in[2*i]),
          p8_in_bytes[2*i]
        };
      end else begin
        {cout16_out[i], product16_out[16*i +: 16]} = {
          ({cout8_in[2*i+1], p8_in_bytes[2*i+1]} - cout8_in[2*i]),
          p8_in_bytes[2*i]
        };
      end
    end

    if (!is_sub) begin
      {cout32_out, product32_out} = {
        ({cout16_out[1], product16_out[31:16]} + cout16_out[0]),
        product16_out[15:0]
      };
    end else begin
      {cout32_out, product32_out} = {
        ({cout16_out[1], product16_out[31:16]} - cout16_out[0]),
        product16_out[15:0]
      };
    end
  end

  assign p16_words = product16_out;
  assign p32_word  = product32_out;

  // Rounding Evaluation
  logic [3:0][7:0]  round8_src;
  logic [1:0][15:0] round16_src;
  logic [31:0]      round32_src;

  always_comb begin
    round8_src  = '0;
    round16_src = '0;
    round32_src = '0;
    round8_out  = '0;
    round16_out = '0;
    round32_out = '0;

    case (uop_funct6.ari_funct6)
      VAADDU,
      VASUBU: begin
        case (vxrm)
          RNU: begin
            for (int i = 0; i < 4; i = i + 1) begin
              round8_src[i] = {cout8_in[i], p8_in_bytes[i][7:1]};
              round8_out[8*i +: 8] = p8_in_bytes[i][0] ? (round8_src[i] + 1'b1) : round8_src[i];
            end
            for (int i = 0; i < 2; i = i + 1) begin
              round16_src[i] = {cout16_out[i], p16_words[i][15:1]};
              round16_out[16*i +: 16] =
                  p16_words[i][0] ? (round16_src[i] + 1'b1) : round16_src[i];
            end
            round32_src = {cout32_out, p32_word[31:1]};
            round32_out = p32_word[0] ? (round32_src + 1'b1) : round32_src;
          end
          RNE: begin
            for (int i = 0; i < 4; i = i + 1) begin
              round8_src[i] = {cout8_in[i], p8_in_bytes[i][7:1]};
              round8_out[8*i +: 8] = (p8_in_bytes[i][0] & p8_in_bytes[i][1]) ?
                  (round8_src[i] + 1'b1) : round8_src[i];
            end
            for (int i = 0; i < 2; i = i + 1) begin
              round16_src[i] = {cout16_out[i], p16_words[i][15:1]};
              round16_out[16*i +: 16] = (p16_words[i][0] & p16_words[i][1]) ?
                  (round16_src[i] + 1'b1) : round16_src[i];
            end
            round32_src = {cout32_out, p32_word[31:1]};
            round32_out = (p32_word[0] & p32_word[1]) ? (round32_src + 1'b1) : round32_src;
          end
          RDN: begin
            for (int i = 0; i < 4; i = i + 1) begin
              round8_src[i] = {cout8_in[i], p8_in_bytes[i][7:1]};
              round8_out[8*i +: 8] = round8_src[i];
            end
            for (int i = 0; i < 2; i = i + 1) begin
              round16_src[i] = {cout16_out[i], p16_words[i][15:1]};
              round16_out[16*i +: 16] = round16_src[i];
            end
            round32_src = {cout32_out, p32_word[31:1]};
            round32_out = round32_src;
          end
          ROD: begin
            for (int i = 0; i < 4; i = i + 1) begin
              round8_src[i] = {cout8_in[i], p8_in_bytes[i][7:1]};
              round8_out[8*i +: 8] = (!p8_in_bytes[i][1] & p8_in_bytes[i][0]) ?
                  (round8_src[i] + 1'b1) : round8_src[i];
            end
            for (int i = 0; i < 2; i = i + 1) begin
              round16_src[i] = {cout16_out[i], p16_words[i][15:1]};
              round16_out[16*i +: 16] = (!p16_words[i][1] & p16_words[i][0]) ?
                  (round16_src[i] + 1'b1) : round16_src[i];
            end
            round32_src = {cout32_out, p32_word[31:1]};
            round32_out = (!p32_word[1] & p32_word[0]) ? (round32_src + 1'b1) : round32_src;
          end
          default: ;
        endcase
      end

      VAADD,
      VASUB: begin
        case (vxrm)
          RNU: begin
            for (int i = 0; i < 4; i = i + 1) begin
              round8_src[i] = {(src2_sgn[i] ^ src1_sgn[i]) ? (!cout8_in[i]) : cout8_in[i],
                               p8_in_bytes[i][7:1]};
              round8_out[8*i +: 8] = p8_in_bytes[i][0] ? (round8_src[i] + 1'b1) : round8_src[i];
            end
            for (int i = 0; i < 2; i = i + 1) begin
              round16_src[i] = {(src2_sgn[2*i+1] ^ src1_sgn[2*i+1]) ?
                                  (!cout16_out[i]) : cout16_out[i],
                                p16_words[i][15:1]};
              round16_out[16*i +: 16] =
                  p16_words[i][0] ? (round16_src[i] + 1'b1) : round16_src[i];
            end
            round32_src = {(src2_sgn[3] ^ src1_sgn[3]) ? (!cout32_out) : cout32_out,
                           p32_word[31:1]};
            round32_out = p32_word[0] ? (round32_src + 1'b1) : round32_src;
          end
          RNE: begin
            for (int i = 0; i < 4; i = i + 1) begin
              round8_src[i] = {(src2_sgn[i] ^ src1_sgn[i]) ? (!cout8_in[i]) : cout8_in[i],
                               p8_in_bytes[i][7:1]};
              round8_out[8*i +: 8] = (p8_in_bytes[i][0] & p8_in_bytes[i][1]) ?
                  (round8_src[i] + 1'b1) : round8_src[i];
            end
            for (int i = 0; i < 2; i = i + 1) begin
              round16_src[i] = {(src2_sgn[2*i+1] ^ src1_sgn[2*i+1]) ?
                                  (!cout16_out[i]) : cout16_out[i],
                                p16_words[i][15:1]};
              round16_out[16*i +: 16] = (p16_words[i][0] & p16_words[i][1]) ?
                  (round16_src[i] + 1'b1) : round16_src[i];
            end
            round32_src = {(src2_sgn[3] ^ src1_sgn[3]) ? (!cout32_out) : cout32_out,
                           p32_word[31:1]};
            round32_out = (p32_word[0] & p32_word[1]) ? (round32_src + 1'b1) : round32_src;
          end
          RDN: begin
            for (int i = 0; i < 4; i = i + 1) begin
              round8_src[i] = {(src2_sgn[i] ^ src1_sgn[i]) ? (!cout8_in[i]) : cout8_in[i],
                               p8_in_bytes[i][7:1]};
              round8_out[8*i +: 8] = round8_src[i];
            end
            for (int i = 0; i < 2; i = i + 1) begin
              round16_src[i] = {(src2_sgn[2*i+1] ^ src1_sgn[2*i+1]) ?
                                  (!cout16_out[i]) : cout16_out[i],
                                p16_words[i][15:1]};
              round16_out[16*i +: 16] = round16_src[i];
            end
            round32_src = {(src2_sgn[3] ^ src1_sgn[3]) ? (!cout32_out) : cout32_out,
                           p32_word[31:1]};
            round32_out = round32_src;
          end
          ROD: begin
            for (int i = 0; i < 4; i = i + 1) begin
              round8_src[i] = {(src2_sgn[i] ^ src1_sgn[i]) ? (!cout8_in[i]) : cout8_in[i],
                               p8_in_bytes[i][7:1]};
              round8_out[8*i +: 8] = (!p8_in_bytes[i][1] & p8_in_bytes[i][0]) ?
                  (round8_src[i] + 1'b1) : round8_src[i];
            end
            for (int i = 0; i < 2; i = i + 1) begin
              round16_src[i] = {(src2_sgn[2*i+1] ^ src1_sgn[2*i+1]) ?
                                  (!cout16_out[i]) : cout16_out[i],
                                p16_words[i][15:1]};
              round16_out[16*i +: 16] = (!p16_words[i][1] & p16_words[i][0]) ?
                  (round16_src[i] + 1'b1) : round16_src[i];
            end
            round32_src = {(src2_sgn[3] ^ src1_sgn[3]) ? (!cout32_out) : cout32_out,
                           p32_word[31:1]};
            round32_out = (!p32_word[1] & p32_word[0]) ? (round32_src + 1'b1) : round32_src;
          end
          default: ;
        endcase
      end
      default: ;
    endcase
  end

  // Overflow and Saturation Evaluation
  always_comb begin
    addu_upoverflow    = '0;
    add_upoverflow     = '0;
    add_underoverflow  = '0;
    subu_underoverflow = '0;
    sub_upoverflow     = '0;
    sub_underoverflow  = '0;

    case (vs2_eew)
      EEW8: begin
        addu_upoverflow = cout8_in;
        add_upoverflow  = {
          (p8_in_bytes[3][7] & (!src2_sgn[3]) & (!src1_sgn[3])),
          (p8_in_bytes[2][7] & (!src2_sgn[2]) & (!src1_sgn[2])),
          (p8_in_bytes[1][7] & (!src2_sgn[1]) & (!src1_sgn[1])),
          (p8_in_bytes[0][7] & (!src2_sgn[0]) & (!src1_sgn[0]))
        };
        add_underoverflow = {
          ((!p8_in_bytes[3][7]) & src2_sgn[3] & src1_sgn[3]),
          ((!p8_in_bytes[2][7]) & src2_sgn[2] & src1_sgn[2]),
          ((!p8_in_bytes[1][7]) & src2_sgn[1] & src1_sgn[1]),
          ((!p8_in_bytes[0][7]) & src2_sgn[0] & src1_sgn[0])
        };
        subu_underoverflow = cout8_in;
        sub_upoverflow = {
          (p8_in_bytes[3][7] & (!src2_sgn[3]) & src1_sgn[3]),
          (p8_in_bytes[2][7] & (!src2_sgn[2]) & src1_sgn[2]),
          (p8_in_bytes[1][7] & (!src2_sgn[1]) & src1_sgn[1]),
          (p8_in_bytes[0][7] & (!src2_sgn[0]) & src1_sgn[0])
        };
        sub_underoverflow = {
          ((!p8_in_bytes[3][7]) & src2_sgn[3] & (!src1_sgn[3])),
          ((!p8_in_bytes[2][7]) & src2_sgn[2] & (!src1_sgn[2])),
          ((!p8_in_bytes[1][7]) & src2_sgn[1] & (!src1_sgn[1])),
          ((!p8_in_bytes[0][7]) & src2_sgn[0] & (!src1_sgn[0]))
        };
      end
      EEW16: begin
        addu_upoverflow = {cout16_out[1], 1'b0, cout16_out[0], 1'b0};
        add_upoverflow = {
          (p16_words[1][15] & (!src2_sgn[3]) & (!src1_sgn[3])),
          1'b0,
          (p16_words[0][15] & (!src2_sgn[1]) & (!src1_sgn[1])),
          1'b0
        };
        add_underoverflow = {
          ((!p16_words[1][15]) & src2_sgn[3] & src1_sgn[3]),
          1'b0,
          ((!p16_words[0][15]) & src2_sgn[1] & src1_sgn[1]),
          1'b0
        };
        subu_underoverflow = {cout16_out[1], 1'b0, cout16_out[0], 1'b0};
        sub_upoverflow = {
          (p16_words[1][15] & (!src2_sgn[3]) & src1_sgn[3]),
          1'b0,
          (p16_words[0][15] & (!src2_sgn[1]) & src1_sgn[1]),
          1'b0
        };
        sub_underoverflow = {
          ((!p16_words[1][15]) & src2_sgn[3] & (!src1_sgn[3])),
          1'b0,
          ((!p16_words[0][15]) & src2_sgn[1] & (!src1_sgn[1])),
          1'b0
        };
      end
      EEW32: begin
        addu_upoverflow    = {cout32_out, 3'b0};
        add_upoverflow     = {(p32_word[31] & (!src2_sgn[3]) & (!src1_sgn[3])), 3'b0};
        add_underoverflow  = {((!p32_word[31]) & src2_sgn[3] & src1_sgn[3]), 3'b0};
        subu_underoverflow = {cout32_out, 3'b0};
        sub_upoverflow     = {(p32_word[31] & (!src2_sgn[3]) & src1_sgn[3]), 3'b0};
        sub_underoverflow  = {((!p32_word[31]) & src2_sgn[3] & (!src1_sgn[3])), 3'b0};
      end
      default: ;
    endcase
  end

endmodule
