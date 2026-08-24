// Description:
// 1. the rvv_backend_dispatch_ctrl is responsible for push uop(s) to RS/ROB and pop uop(s) from UOP_Queue.

`ifndef HDL_VERILOG_RVV_DESIGN_RVV_SVH
`include "rvv_backend.svh"
`endif
`ifndef RVV_DISPATCH__SVH
`include "rvv_backend_dispatch.svh"
`endif

module rvv_backend_dispatch_ctrl
(
    raw_uop_rob,
    raw_uop_uop,
    arch_hazard,
    uop_ctrl,
    uop_valid_uop2dp,
    uop_ready_dp2uop,
    rs_valid_dp2alu,
    rs_ready_alu2dp,
    rs_valid_dp2pmtrdt,
    rs_ready_pmtrdt2dp,
    rs_valid_dp2mul,
    rs_ready_mul2dp,
    rs_valid_dp2div,
    rs_ready_div2dp,
  `ifdef ZVE32F_ON
    rs_valid_dp2falu,
    rs_ready_falu2dp,
  `endif
  `ifdef ZVT_ON
    rs_valid_dp2zvt,
    rs_ready_zvt2dp,
  `endif
    rs_valid_dp2lsu,
    rs_ready_lsu2dp,
    mapinfo_valid_dp2lsu,
    mapinfo_ready_lsu2dp,
    uop_valid_dp2rob,
    uop_ready_rob2dp
);
// ---port definition-------------------------------------------------
// ctrl input signal
    input   RAW_UOP_ROB_t [`NUM_DP_UOP-1:0] raw_uop_rob;
    input   RAW_UOP_UOP_t [`NUM_DP_UOP-1:1] raw_uop_uop;
    input   ARCH_HAZARD_t                   arch_hazard;
    input   UOP_CTRL_t    [`NUM_DP_UOP-1:0] uop_ctrl;
// handshake singals
    input   logic         [`NUM_DP_UOP-1:0] uop_valid_uop2dp;
    output  logic         [`NUM_DP_UOP-1:0] uop_ready_dp2uop;

    output  logic         [`NUM_DP_UOP-1:0] rs_valid_dp2alu;
    input   logic         [`NUM_DP_UOP-1:0] rs_ready_alu2dp;
    output  logic         [`NUM_DP_UOP-1:0] rs_valid_dp2pmtrdt;
    input   logic         [`NUM_DP_UOP-1:0] rs_ready_pmtrdt2dp;
    output  logic         [`NUM_DP_UOP-1:0] rs_valid_dp2mul;
    input   logic         [`NUM_DP_UOP-1:0] rs_ready_mul2dp;
    output  logic         [`NUM_DP_UOP-1:0] rs_valid_dp2div;
    input   logic         [`NUM_DP_UOP-1:0] rs_ready_div2dp;
  `ifdef ZVE32F_ON
    output  logic         [`NUM_DP_UOP-1:0] rs_valid_dp2falu;
    input   logic         [`NUM_DP_UOP-1:0] rs_ready_falu2dp;
  `endif
  `ifdef ZVT_ON
    output  logic         [`NUM_DP_UOP-1:0] rs_valid_dp2zvt;
    input   logic         [`NUM_DP_UOP-1:0] rs_ready_zvt2dp;
  `endif
    output  logic         [`NUM_DP_UOP-1:0] rs_valid_dp2lsu;
    input   logic         [`NUM_DP_UOP-1:0] rs_ready_lsu2dp;
    output  logic         [`NUM_DP_UOP-1:0] mapinfo_valid_dp2lsu;
    input   logic         [`NUM_DP_UOP-1:0] mapinfo_ready_lsu2dp;

    output  logic         [`NUM_DP_UOP-1:0] uop_valid_dp2rob;
    input   logic         [`NUM_DP_UOP-1:0] uop_ready_rob2dp;

// ---internal signal definition--------------------------------------
    logic [`NUM_DP_UOP-1:0] uop_valid;
    logic [`NUM_DP_UOP-1:0] rs_ready;

// ---code start------------------------------------------------------
    genvar i;
    generate
        for (i=0; i<`NUM_DP_UOP; i++) begin : gen_uop_valid
            if (i==0) begin : gen_first
              assign uop_valid[0] = uop_valid_uop2dp[0]      &
                                    ~raw_uop_rob[0].vs1_wait &
                                    ~raw_uop_rob[0].vs2_wait &
                                    ~raw_uop_rob[0].vd_wait  &
                                    ~raw_uop_rob[0].v0_wait  ;
            end else if (i<`NUM_DP_UOP-1) begin : gen_i
              assign uop_valid[i] = uop_valid[i-1]           &
                                    uop_valid_uop2dp[i]      &
                                    ~raw_uop_rob[i].vs1_wait &
                                    ~raw_uop_rob[i].vs2_wait &
                                    ~raw_uop_rob[i].vd_wait  &
                                    ~raw_uop_rob[i].v0_wait  &
                                    ~raw_uop_uop[i].vs1_wait &
                                    ~raw_uop_uop[i].vs2_wait &
                                    ~raw_uop_uop[i].vd_wait  &
                                    ~raw_uop_uop[i].v0_wait  ;
            end else begin : gen_last
              assign uop_valid[i] = uop_valid[i-1]           &
                                    uop_valid_uop2dp[i]      &
                                    ~raw_uop_rob[i].vs1_wait &
                                    ~raw_uop_rob[i].vs2_wait &
                                    ~raw_uop_rob[i].vd_wait  &
                                    ~raw_uop_rob[i].v0_wait  &
                                    ~raw_uop_uop[i].vs1_wait &
                                    ~raw_uop_uop[i].vs2_wait &
                                    ~raw_uop_uop[i].vd_wait  &
                                    ~raw_uop_uop[i].v0_wait  &
                                    ~arch_hazard.vr_limit    ;  
            end
        end
        for (i=0; i<`NUM_DP_UOP; i++) begin : gen_rs_ready
          if (i==0) begin : gen_first
            always_comb begin
                case (uop_ctrl[i].uop_exe_unit)
                  `ifdef ZVT_ON
                    VME,
                    VMELSU:  rs_ready[0] = rs_ready_zvt2dp[0];
                  `endif
                    VEU_CMP,
                    VEU_ALU: rs_ready[0] = rs_ready_alu2dp[0];
                    VEU_MUL,
                    VEU_MAC: rs_ready[0] = rs_ready_mul2dp[0];
                    VEU_MISC,
                    VEU_PMT,
                  `ifdef ZVE32F_ON
                    VEU_FRDT,
                  `endif
                    VEU_RDT: rs_ready[0] = rs_ready_pmtrdt2dp[0];
                  `ifdef ZVE32F_ON
                    VEU_FNCMP,
                    VEU_FCMP,
                    VEU_FMA,
                    VEU_FCVT,
                    VEU_FTBL:rs_ready[0] = rs_ready_falu2dp[0];
                    VEU_FDIV,
                  `endif
                    VEU_DIV: rs_ready[0] = rs_ready_div2dp[0];
                    LSU: rs_ready[0] = (!uop_ctrl[0].pshlsu_valid||rs_ready_lsu2dp[0]) & mapinfo_ready_lsu2dp[0];
                    default: rs_ready[0] = 1'b0;
                endcase
            end
          end else begin : gen_i
            always_comb begin
                case (uop_ctrl[i].uop_exe_unit)
                  `ifdef ZVT_ON
                    VME,
                    VMELSU: rs_ready[i] = rs_ready[i-1] & rs_ready_zvt2dp[i];
                  `endif
                    VEU_CMP,
                    VEU_ALU: rs_ready[i] = rs_ready[i-1] & rs_ready_alu2dp[i];
                    VEU_MUL,
                    VEU_MAC: rs_ready[i] = rs_ready[i-1] & rs_ready_mul2dp[i];
                    VEU_MISC,
                    VEU_PMT,
                  `ifdef ZVE32F_ON
                    VEU_FRDT,
                  `endif
                    VEU_RDT: rs_ready[i] = rs_ready[i-1] & rs_ready_pmtrdt2dp[i];
                  `ifdef ZVE32F_ON
                    VEU_FNCMP,
                    VEU_FCMP,
                    VEU_FMA,
                    VEU_FCVT:rs_ready[i] = rs_ready[i-1] & rs_ready_falu2dp[i];
                    VEU_FDIV,
                  `endif
                    VEU_DIV: rs_ready[i] = rs_ready[i-1] & rs_ready_div2dp[i];
                    LSU: rs_ready[i] = rs_ready[i-1] & (!uop_ctrl[i].pshlsu_valid||rs_ready_lsu2dp[i]) & mapinfo_ready_lsu2dp[i];
                    default: rs_ready[i] = 1'b0;
                endcase
            end
          end
        end
        for (i=0; i<`NUM_DP_UOP; i++) begin: gen_ctrl_output
            assign uop_ready_dp2uop[i]     = uop_valid[i]        &
                                             uop_ready_rob2dp[i] &
                                             rs_ready[i]         ;

            assign uop_valid_dp2rob[i]     = uop_ready_dp2uop[i] & 
                                             uop_ctrl[i].pshrob_valid;

          `ifdef ZVT_ON
            assign rs_valid_dp2zvt[i]      = uop_ready_dp2uop[i] & 
                                             ((uop_ctrl[i].uop_exe_unit == VME) ||
                                              (uop_ctrl[i].uop_exe_unit == VMELSU));
          `endif
            assign rs_valid_dp2alu[i]      = uop_ready_dp2uop[i] & 
                                             ((uop_ctrl[i].uop_exe_unit == VEU_ALU) ||
                                              (uop_ctrl[i].uop_exe_unit == VEU_CMP) );
            assign rs_valid_dp2pmtrdt[i]   = uop_ready_dp2uop[i] & 
                                             ((uop_ctrl[i].uop_exe_unit == VEU_MISC)|| 
                                            `ifdef ZVE32F_ON
                                              (uop_ctrl[i].uop_exe_unit == VEU_FRDT)|| 
                                            `endif
                                              (uop_ctrl[i].uop_exe_unit == VEU_PMT) || 
                                              (uop_ctrl[i].uop_exe_unit == VEU_RDT) ); 
            assign rs_valid_dp2mul[i]      = uop_ready_dp2uop[i] & 
                                             (uop_ctrl[i].uop_exe_unit == VEU_MUL || 
                                              uop_ctrl[i].uop_exe_unit == VEU_MAC );
          `ifdef ZVE32F_ON
            assign rs_valid_dp2falu[i]     = uop_ready_dp2uop[i] & 
                                             ((uop_ctrl[i].uop_exe_unit == VEU_FMA)  ||
                                              (uop_ctrl[i].uop_exe_unit == VEU_FNCMP)||
                                              (uop_ctrl[i].uop_exe_unit == VEU_FCMP) ||
                                              (uop_ctrl[i].uop_exe_unit == VEU_FTBL) ||
                                              (uop_ctrl[i].uop_exe_unit == VEU_FCVT) );
          `endif
            assign rs_valid_dp2div[i]      = uop_ready_dp2uop[i] & (
                                            `ifdef ZVE32F_ON
                                             uop_ctrl[i].uop_exe_unit == VEU_FDIV ||
                                            `endif
                                             uop_ctrl[i].uop_exe_unit == VEU_DIV);
            assign rs_valid_dp2lsu[i]      = uop_ready_dp2uop[i] & 
                                             uop_ctrl[i].pshlsu_valid &
                                             (uop_ctrl[i].uop_exe_unit == LSU);
            assign mapinfo_valid_dp2lsu[i] = uop_valid_dp2rob[i] & 
                                             (uop_ctrl[i].uop_exe_unit == LSU);
        end
    endgenerate
    
endmodule
