//module rvv_backend_alu_unit_mask_viota64
//(
//  source,
//  result_viota64
//);
//  input  logic  [63:0]                source;
//  output logic  [63:0][$clog2(64):0]  result_viota64;
//
//  logic [1:0][31:0][$clog2(32):0]     result_viota32;
//
//  genvar                              j;
//  
//  // calculate
//  generate
//    for(j=0;j<2;j++) begin: GET_VIOTA32
//      rvv_backend_alu_unit_mask_viota32
//      u_viota32
//      (
//        .source         (source[32*j +: 32]),
//        .result_viota32 (result_viota32[j])
//      );
//    end
//    
//    for(j=0;j<32;j++) begin: GET_VIOTA64
//      assign result_viota64[j] = result_viota32[0][j];
//      assign result_viota64[j+32] = result_viota32[1][j]+result_viota32[0][31];
//    end
//  endgenerate
//
//endmodule
 
//
//  another viota64 by using viota16
//

// module rvv_backend_alu_unit_mask_viota64
// (
//   source,
//   result_viota64
// );
//   input  logic  [63:0]                source;
//   output logic  [63:0][$clog2(64):0]  result_viota64;
// 
//   logic [3:0][15:0][$clog2(16):0]     result_viota16;
//   logic      [15:0][$clog2(16):0]     sum_47to32;
//   logic      [15:0][$clog2(16):0]     carry_47to32;
//   logic      [15:0][$clog2(16):0]     sum_63to48;
//   logic      [15:0][$clog2(16):0]     carry_63to48;
//   logic      [15:0][$clog2(16):0]     cout_63to48;
// 
//   genvar                              j;
//   
//   // calculate
//   generate
//     for(j=0;j<4;j++) begin: GET_VIOTA16
//       rvv_backend_alu_unit_mask_viota16
//       u_viota16
//       (
//         .source         (source[16*j +: 16]),
//         .result_viota16 (result_viota16[j])
//       );
//     end
//     
//     for(j=0;j<16;j++) begin: GET_VIOTA64
//       assign result_viota64[j] = result_viota16[0][j];
//       assign result_viota64[j+16] = result_viota16[1][j]+result_viota16[0][15];
//       assign result_viota64[j+32] = sum_47to32[j]+{carry_47to32[j],1'b0};
//       assign result_viota64[j+48] = sum_63to48[j]+{({1'b0,carry_63to48[j]}+{1'b0,cout_63to48[j]}),1'b0};
// 
//       compressor_3_2
//       #(
//         .WIDTH  ($clog2(16)+1)
//       )
//       viota64_47to32
//       (
//         .src1         (result_viota16[0][15]),
//         .src2         (result_viota16[1][15]),
//         .src3         (result_viota16[2][j]),
//         .result_sum   (sum_47to32[j]),
//         .result_carry (carry_47to32[j])
//       );
// 
//       compressor_4_2
//       #(
//         .WIDTH  ($clog2(16)+1)
//       )
//       viota64_63to48
//       (
//         .src1         (result_viota16[0][15]),
//         .src2         (result_viota16[1][15]),
//         .src3         (result_viota16[2][15]),
//         .src4         (result_viota16[3][j]),
//         .cin          ('0),
//         .result_sum   (sum_63to48[j]),
//         .result_carry (carry_63to48[j]),
//         .result_cout  (cout_63to48[j])
//       );
//     end
//   endgenerate
// 
// endmodule

module rvv_backend_alu_unit_mask_viota32
(
  source,
  result_viota32
);

  input  logic [31:0]               source;
  output logic [31:0][$clog2(32):0] result_viota32;
  
  logic [3:0][6:0][2:0]             result_viota7;
  logic      [6:0][2:0]             sum_20to14;
  logic      [6:0][2:0]             carry_20to14;
  logic      [6:0][2:0]             sum_27to21;
  logic      [6:0][2:0]             carry_27to21;
  logic      [6:0][2:0]             cout_27to21;
  logic      [3:0][2:0]             result_viota4;
  logic      [3:0][2:0]             sum_31to28;
  logic      [3:0][2:0]             carry_31to28;
  logic      [3:0][2:0]             cout_31to28;
  
  genvar                            j;

  // calculate
  generate
    for(j=0;j<4;j++) begin: GET_VIOTA7_FOR_27_0_BIT
      rvv_backend_alu_unit_mask_viota7
      u_viota7
      (
        .source(source[j*7 +: 7]),
        .result_viota7(result_viota7[j])
      );
    end
  endgenerate

  rvv_backend_alu_unit_mask_viota4
  u_viota4
  (
    .source(source[31:28]),
    .result_viota4(result_viota4)
  );

  generate
    for(j=0;j<7;j++) begin: GET_VIOTA32_27_0
      assign result_viota32[j] = ($clog2(32)+1)'(result_viota7[0][j]);
      assign result_viota32[j+7] = ($clog2(32)+1)'(result_viota7[1][j])+($clog2(32)+1)'(result_viota7[0][6]);
      assign result_viota32[j+14] = ($clog2(32)+1)'(sum_20to14[j])+($clog2(32)+1)'({carry_20to14[j],1'b0});
      assign result_viota32[j+21] = ($clog2(32)+1)'(sum_27to21[j])+($clog2(32)+1)'({({1'b0,carry_27to21[j]})+($clog2(32)+1)'({1'b0,cout_27to21[j]}),1'b0});

      compressor_3_2
      #(
        .WIDTH        (3)
      )
      viota32_20to14
      (
        .src1         (result_viota7[0][6]),
        .src2         (result_viota7[1][6]),
        .src3         (result_viota7[2][j]),
        .result_sum   (sum_20to14[j]),
        .result_carry (carry_20to14[j])
      );
      
      compressor_4_2
      #(
        .WIDTH        (3)
      )
      viota32_27to21
      (
        .src1         (result_viota7[0][6]),
        .src2         (result_viota7[1][6]),
        .src3         (result_viota7[2][6]),
        .src4         (result_viota7[3][j]),
        .cin          ('0),
        .result_sum   (sum_27to21[j]),
        .result_carry (carry_27to21[j]),
        .result_cout  (cout_27to21[j])
      );
    end

    for(j=0;j<4;j++) begin: GET_VIOTA32_31_28
      assign result_viota32[j+28] = ($clog2(32)+1)'(sum_31to28[j])+
                                    ($clog2(32)+1)'({({1'b0,carry_31to28[j]})+
                                    ($clog2(32)+1)'({1'b0,cout_31to28[j]}),1'b0});

      compressor_4_2
      #(
        .WIDTH        (3)
      )
      viota32_31to28
      (
        .src1         (result_viota7[0][6]),
        .src2         (result_viota7[1][6]),
        .src3         (result_viota7[2][6]),
        .src4         (result_viota7[3][6]),
        .cin          (result_viota4[j]),
        .result_sum   (sum_31to28[j]),
        .result_carry (carry_31to28[j]),
        .result_cout  (cout_31to28[j])
      );
    end
  endgenerate
  
endmodule

// module rvv_backend_alu_unit_mask_viota16
// (
//   source,
//   result_viota16
// );
//   input  logic  [15:0]               source;
//   output logic  [15:0][$clog2(16):0] result_viota16;
// 
//   logic [3:0][3:0][$clog2(4):0]      result_viota4;
//   logic      [3:0][$clog2(4):0]      sum_11to8;
//   logic      [3:0][$clog2(4):0]      carry_11to8;
//   logic      [3:0][$clog2(4):0]      sum_15to12;
//   logic      [3:0][$clog2(4):0]      carry_15to12;
//   logic      [3:0][$clog2(4):0]      cout_15to12;
// 
//   genvar                             j;
//   
//   // calculate
//   generate
//     for(j=0;j<4;j++) begin: GET_VIOTA4
//       rvv_backend_alu_unit_mask_viota4
//       u_viota4
//       (
//         .source         (source[j*4 +: 4]),
//         .result_viota7  (result_viota4[j])
//       );
//     end
// 
//     for(j=0;j<4;j++) begin: GET_VIOTA16
//       assign result_viota16[j] = result_viota4[0][j];
//       assign result_viota16[j+4] = result_viota4[1][j]+result_viota4[0][3];
//       assign result_viota16[j+8] = sum_11to8[j]+{carry_11to8[j],1'b0};
//       assign result_viota16[j+12] = sum_15to12[j]+{({1'b0,carry_15to12[j]}+{1'b0,cout_15to12[j]}),1'b0};
// 
//       compressor_3_2
//       #(
//         .WIDTH  ($clog2(4)+1)
//       )
//       viota16_11to8
//       (
//         .src1         (result_viota4[0][3]),
//         .src2         (result_viota4[1][3]),
//         .src3         (result_viota4[2][j]),
//         .result_sum   (sum_11to8[j]),
//         .result_carry (carry_11to8[j])
//       );
// 
//       compressor_4_2
//       #(
//         .WIDTH  ($clog2(4)+1)
//       )
//       viota16_15to12
//       (
//         .src1         (result_viota4[0][3]),
//         .src2         (result_viota4[1][3]),
//         .src3         (result_viota4[2][3]),
//         .src4         (result_viota4[3][j]),
//         .cin          ('0),
//         .result_sum   (sum_15to12[j]),
//         .result_carry (carry_15to12[j]),
//         .result_cout  (cout_15to12[j])
//       );
//     end
//   endgenerate
// 
// endmodule

module rvv_backend_alu_unit_mask_viota7
(
  source,
  result_viota7
);

  input  logic [6:0]      source;
  output logic [6:0][2:0] result_viota7;
  
  logic [3:0][2:0]        result_viota4;

  rvv_backend_alu_unit_mask_viota4
  u_viota4
  (
    .source(source[3:0]),
    .result_viota4(result_viota4)
  );
  
  assign result_viota7[3:0] = result_viota4;

  always_comb begin
    case(source[4])
      1'b0: begin
        result_viota7[4] = result_viota4[3];
      end
      1'b1: begin
        result_viota7[4] = result_viota4[3]+1'b1;
      end
      default: begin
        result_viota7[4] = result_viota4[3];
      end
    endcase

    case(source[5:4])
      2'b00: begin
        result_viota7[5] = result_viota4[3];
      end
      2'b01,
      2'b10: begin
        result_viota7[5] = result_viota4[3]+1'b1;
      end
      2'b11: begin
        result_viota7[5] = result_viota4[3]+2'd2;
      end
      default: begin
        result_viota7[5] = result_viota4[3];
      end
    endcase

    case(source[6:4])
      3'b000: begin
        result_viota7[6] = result_viota4[3];
      end
      3'b001,
      3'b010,
      3'b100: begin
        result_viota7[6] = result_viota4[3]+1'b1;
      end
      3'b011,
      3'b101,
      3'b110: begin
        result_viota7[6] = result_viota4[3]+2'd2;
      end
      3'b111: begin
        result_viota7[6] = result_viota4[3]+2'd3;
      end
      default: begin
        result_viota7[6] = result_viota4[3];
      end
    endcase
  end

endmodule

module rvv_backend_alu_unit_mask_viota4
(
  source,
  result_viota4 
);

  input  logic [3:0]              source;
  output logic [3:0][$clog2(4):0] result_viota4;
  
  always_comb begin
    case(source[0])
      1'b0: begin
        result_viota4[0] = 3'd0;
      end
      1'b1: begin
        result_viota4[0] = 3'd1;
      end
      default: begin
        result_viota4[0] = 3'd0;
      end
    endcase

    case(source[1:0])
      2'b00: begin
        result_viota4[1] = 3'd0;
      end
      2'b01,
      2'b10: begin
        result_viota4[1] = 3'd1;
      end
      2'b11: begin
        result_viota4[1] = 3'd2;
      end
      default: begin
        result_viota4[1] = 3'd0;
      end
    endcase

    case(source[2:0])
      3'b000: begin
        result_viota4[2] = 3'd0;
      end
      3'b001,
      3'b010,
      3'b100: begin
        result_viota4[2] = 3'd1;
      end
      3'b011,
      3'b101,
      3'b110: begin
        result_viota4[2] = 3'd2;
      end
      3'b111: begin
        result_viota4[2] = 3'd3;
      end
      default: begin
        result_viota4[2] = 3'd0;
      end
    endcase

    case(source)
      4'b0000: begin
        result_viota4[3] = 3'd0;
      end
      4'b0001,
      4'b0010,
      4'b0100,
      4'b1000: begin
        result_viota4[3] = 3'd1;
      end
      4'b0011,
      4'b0101,
      4'b1001,
      4'b0110,
      4'b1010,
      4'b1100: begin
        result_viota4[3] = 3'd2;
      end
      4'b0111,
      4'b1011,
      4'b1101,
      4'b1110: begin
        result_viota4[3] = 3'd3;
      end
      4'b1111: begin
        result_viota4[3] = 3'd4;
      end
      default: begin
        result_viota4[3] = 3'd0;
      end
    endcase
  end

endmodule
