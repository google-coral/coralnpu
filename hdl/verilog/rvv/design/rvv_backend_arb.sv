`ifndef HDL_VERILOG_RVV_DESIGN_RVV_SVH
`include "rvv_backend.svh"
`endif

module rvv_backend_arb(
  clk,
  rst_n,
  req,
  item,
  grant,
  result_valid,
  result
);

// global signal
    input   logic                       clk;
    input   logic                       rst_n;
// PU to ARB
    input   logic     [`NUM_PU-1:0]     req;
    input   PU2ROB_t  [`NUM_PU-1:0]     item;
    output  logic     [`NUM_PU-1:0]     grant;
// ARB to ROB
    output  logic     [`NUM_SMPORT-1:0] result_valid;
    output  PU2ROB_t  [`NUM_SMPORT-1:0] result;

// ---internal signal definition--------------------------------------
`ifdef ZVE32F_ON
  `ifdef ZVT_ON
    localparam EVEN_NP_NUM = 4;
  `else
    localparam EVEN_NP_NUM = 3;
  `endif
`else
  `ifdef ZVT_ON
    localparam EVEN_NP_NUM = 3;
  `else
    localparam EVEN_NP_NUM = 2;
  `endif
`endif

`ifdef ZVE32F_ON
  localparam ODD_NP_NUM = 3;
`else
  localparam ODD_NP_NUM = 2;
`endif

// --- Even Slice (Slice 0) ---
logic [EVEN_NP_NUM-1:0] req_even_np;
PU2ROB_t [EVEN_NP_NUM-1:0] item_even_np;

assign req_even_np[0] = req[2];
assign item_even_np[0] = item[2];

assign req_even_np[1] = req[4];
assign item_even_np[1] = item[4];

`ifdef ZVE32F_ON
  assign req_even_np[2] = req[8];
  assign item_even_np[2] = item[8];
  `ifdef ZVT_ON
    assign req_even_np[3] = req[10];
    assign item_even_np[3] = item[10];
  `endif
`else
  `ifdef ZVT_ON
    assign req_even_np[2] = req[8];
    assign item_even_np[2] = item[8];
  `endif
`endif


logic [ODD_NP_NUM-1:0] req_odd_np;
PU2ROB_t [ODD_NP_NUM-1:0] item_odd_np;

assign req_odd_np[0] = req[3];
assign item_odd_np[0] = item[3];

assign req_odd_np[1] = req[5];
assign item_odd_np[1] = item[5];

`ifdef ZVE32F_ON
  assign req_odd_np[2] = req[9];
  assign item_odd_np[2] = item[9];
`endif

logic [EVEN_NP_NUM-1:0] even_np_total_grant;

rvv_backend_arb_slice #(.NP_NUM(EVEN_NP_NUM))
u_even_slice (
  .clk(clk),
  .rst_n(rst_n),
  .req_hp0(req[0]),
  .item_hp0(item[0]),
  .req_hp1(req[6]),
  .item_hp1(item[6]),
  .req_np(req_even_np),
  .item_np(item_even_np),
  .grant_hp0(grant[0]),
  .grant_hp1(grant[6]),
  .grant_np(even_np_total_grant),
  .result_valid0(result_valid[0]),
  .result0(result[0]),
  .result_valid1(result_valid[2]),
  .result1(result[2])
);

logic [ODD_NP_NUM-1:0] odd_np_total_grant;

rvv_backend_arb_slice #(.NP_NUM(ODD_NP_NUM))
u_odd_slice (
  .clk(clk),
  .rst_n(rst_n),
  .req_hp0(req[1]),
  .item_hp0(item[1]),
  .req_hp1(req[7]),
  .item_hp1(item[7]),
  .req_np(req_odd_np),
  .item_np(item_odd_np),
  .grant_hp0(grant[1]),
  .grant_hp1(grant[7]),
  .grant_np(odd_np_total_grant),
  .result_valid0(result_valid[1]),
  .result0(result[1]),
  .result_valid1(result_valid[3]),
  .result1(result[3])
);

assign grant[2] = even_np_total_grant[0];
assign grant[4] = even_np_total_grant[1];
`ifdef ZVE32F_ON
  assign grant[8] = even_np_total_grant[2];
  `ifdef ZVT_ON
    assign grant[10] = even_np_total_grant[3];
  `endif
`else
  `ifdef ZVT_ON
    assign grant[8] = even_np_total_grant[2];
  `endif
`endif

assign grant[3] = odd_np_total_grant[0];
assign grant[5] = odd_np_total_grant[1];
`ifdef ZVE32F_ON
  assign grant[9] = odd_np_total_grant[2];
`endif

endmodule


module rvv_backend_arb_slice #(
  parameter int NP_NUM = 2
) (
  input  logic               clk,
  input  logic               rst_n,
  // High priority requests
  input  logic               req_hp0,
  input  PU2ROB_t            item_hp0,
  input  logic               req_hp1,
  input  PU2ROB_t            item_hp1,
  // Non-priority requests
  input  logic [NP_NUM-1:0]  req_np,
  input  PU2ROB_t [NP_NUM-1:0] item_np,
  // Slice outputs
  output logic               grant_hp0,
  output logic               grant_hp1,
  output logic [NP_NUM-1:0]  grant_np,
  // Outputs to ports
  output logic               result_valid0,
  output PU2ROB_t            result0,
  output logic               result_valid1,
  output PU2ROB_t            result1
);

  logic port0_avail, port1_avail;
  assign port0_avail = !req_hp0;
  assign port1_avail = !req_hp1;

  logic [NP_NUM-1:0] ptr_reg;
  logic [NP_NUM-1:0] next_ptr;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ptr_reg <= {{(NP_NUM-1){1'b0}}, 1'b1};
    end else begin
      ptr_reg <= next_ptr;
    end
  end

  // First Grant Search
  logic [2*NP_NUM-1:0] double_req;
  logic [2*NP_NUM-1:0] double_ptr;
  logic [2*NP_NUM-1:0] double_sub;
  logic [2*NP_NUM-1:0] double_g0;
  logic [NP_NUM-1:0]   grant0_onehot;

  assign double_req = {req_np, req_np};
  assign double_ptr = {{NP_NUM{1'b0}}, ptr_reg};
  assign double_sub = double_req - double_ptr;
  assign double_g0  = double_req & ~double_sub;

  assign grant0_onehot = (port0_avail || port1_avail) ? (double_g0[NP_NUM-1:0] | double_g0[2*NP_NUM-1:NP_NUM]) : '0;

  // Second Grant Search
  logic [NP_NUM-1:0]   req_remain;
  logic [2*NP_NUM-1:0] double_req_remain;
  logic [2*NP_NUM-1:0] double_ptr1;
  logic [2*NP_NUM-1:0] double_sub1;
  logic [2*NP_NUM-1:0] double_g1;
  logic [NP_NUM-1:0]   grant1_onehot;

  assign req_remain = req_np & ~grant0_onehot;
  assign double_req_remain = {req_remain, req_remain};
  assign double_ptr1 = {{NP_NUM{1'b0}}, grant0_onehot};
  assign double_sub1 = double_req_remain - double_ptr1;
  assign double_g1  = double_req_remain & ~double_sub1;

  assign grant1_onehot = (port0_avail && port1_avail) ? (double_g1[NP_NUM-1:0] | double_g1[2*NP_NUM-1:NP_NUM]) : '0;

  // Pointer Advancing Logic
  logic [NP_NUM-1:0] last_grant;
  assign last_grant = (|grant1_onehot) ? grant1_onehot : (|grant0_onehot) ? grant0_onehot : ptr_reg;
  assign next_ptr   = (|grant_np) ? {last_grant[NP_NUM-2:0], last_grant[NP_NUM-1]} : ptr_reg;

  assign grant_hp0 = req_hp0;
  assign grant_hp1 = req_hp1;
  assign grant_np  = grant0_onehot | grant1_onehot;

  // Port 0 outputs
  logic np_grant0_vld;
  assign np_grant0_vld = |grant0_onehot;

  PU2ROB_t np_item0;
  always_comb begin
    np_item0 = '0;
    for (int j = 0; j < NP_NUM; j++) begin
      if (grant0_onehot[j]) begin
        np_item0 = item_np[j];
      end
    end
  end

  assign result_valid0 = req_hp0 || (port0_avail && np_grant0_vld);
  assign result0       = req_hp0 ? item_hp0 : np_item0;

  // Port 1 outputs
  logic np_grant1_vld;
  assign np_grant1_vld = |grant1_onehot;

  PU2ROB_t np_item1;
  always_comb begin
    np_item1 = '0;
    for (int j = 0; j < NP_NUM; j++) begin
      if (grant1_onehot[j]) begin
        np_item1 = item_np[j];
      end
    end
  end

  assign result_valid1 = req_hp1 || (port1_avail && (port0_avail ? np_grant1_vld : np_grant0_vld));
  assign result1       = req_hp1 ? item_hp1 : (port0_avail ? np_item1 : np_item0);

endmodule
