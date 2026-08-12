
`ifndef HDL_VERILOG_RVV_DESIGN_RVV_SVH
`include "rvv_backend.svh"
`endif
`ifndef RVV_DISPATCH__SVH
`include "rvv_backend_dispatch.svh"
`endif

module rvv_backend_dispatch_bypass
(
    uop_operand,
    rob_byp,
    vrf_byp,
    raw_uop_rob
);
// ---port definition-------------------------------------------------
    output UOP_OPN_t                  uop_operand;
    input  ROB_BYP_t [`ROB_DEPTH-1:0] rob_byp;
    input  UOP_OPN_t                  vrf_byp;
    input  RAW_UOP_ROB_t              raw_uop_rob;

// ---internal signal definition--------------------------------------
    logic [`ROB_DEPTH-1:0][`VLENB-1:0] vs1_sel; // one-hot code
    logic [`ROB_DEPTH-1:0][`VLENB-1:0] vs2_sel; // one-hot code
    logic [`ROB_DEPTH-1:0][`VLENB-1:0] vd_sel;  // one-hot code
    logic [`ROB_DEPTH-1:0][`VLENB-1:0] v0_sel;  // one-hot code
    logic [`ROB_DEPTH-1:0][`VLENB-1:0] agnostic; // one-hot code

// ---code start------------------------------------------------------
    genvar i,j;
    generate
        for (i=0; i<`ROB_DEPTH; i++) begin : gen_data_sel
            for (j=0; j<`VLENB; j++) begin
                assign vs1_sel[i][j]  = (raw_uop_rob.vs1_hit[i] == 1'b1) & 
                                        (rob_byp[i].byte_type[j] == BODY_ACTIVE |
                                         rob_byp[i].byte_type[j] == BODY_INACTIVE & rob_byp[i].inactive_one |
                                         rob_byp[i].byte_type[j] == TAIL & rob_byp[i].tail_one);

                assign vs2_sel[i][j]  = (raw_uop_rob.vs2_hit[i] == 1'b1) & 
                                        (rob_byp[i].byte_type[j] == BODY_ACTIVE |
                                         rob_byp[i].byte_type[j] == BODY_INACTIVE & rob_byp[i].inactive_one |
                                         rob_byp[i].byte_type[j] == TAIL & rob_byp[i].tail_one);

                assign vd_sel[i][j]   = (raw_uop_rob.vd_hit[i] == 1'b1) & 
                                        (rob_byp[i].byte_type[j] == BODY_ACTIVE |
                                         rob_byp[i].byte_type[j] == BODY_INACTIVE & rob_byp[i].inactive_one |
                                         rob_byp[i].byte_type[j] == TAIL & rob_byp[i].tail_one);

                assign v0_sel[i][j]   = (raw_uop_rob.v0_hit[i] == 1'b1) & 
                                        (rob_byp[i].byte_type[j] == BODY_ACTIVE |
                                         rob_byp[i].byte_type[j] == BODY_INACTIVE & rob_byp[i].inactive_one |
                                         rob_byp[i].byte_type[j] == TAIL & rob_byp[i].tail_one);

                assign agnostic[i][j] = (rob_byp[i].byte_type[j] == BODY_INACTIVE & rob_byp[i].inactive_one |
                                        rob_byp[i].byte_type[j] == TAIL & rob_byp[i].tail_one);
            end
        end

        for (j=0; j<`VLENB; j++) begin: bypass
            always_comb begin
                uop_operand.vs1[`BYTE_WIDTH*j+:`BYTE_WIDTH] = vrf_byp.vs1[`BYTE_WIDTH*j+:`BYTE_WIDTH];
                uop_operand.vs2[`BYTE_WIDTH*j+:`BYTE_WIDTH] = vrf_byp.vs2[`BYTE_WIDTH*j+:`BYTE_WIDTH];
                uop_operand.vd[`BYTE_WIDTH*j+:`BYTE_WIDTH]  = vrf_byp.vd[`BYTE_WIDTH*j+:`BYTE_WIDTH];
                uop_operand.v0[`BYTE_WIDTH*j+:`BYTE_WIDTH]  = vrf_byp.v0[`BYTE_WIDTH*j+:`BYTE_WIDTH];

                for(int i=0;i<`ROB_DEPTH;i++) begin
                    if(vs1_sel[i][j]) 
                        uop_operand.vs1[`BYTE_WIDTH*j+:`BYTE_WIDTH] = agnostic[i][j] ? 8'hFF : rob_byp[i].w_data[`BYTE_WIDTH*j+:`BYTE_WIDTH];
                    if(vs2_sel[i][j]) 
                        uop_operand.vs2[`BYTE_WIDTH*j+:`BYTE_WIDTH] = agnostic[i][j] ? 8'hFF : rob_byp[i].w_data[`BYTE_WIDTH*j+:`BYTE_WIDTH];
                    if(vd_sel[i][j]) 
                        uop_operand.vd[`BYTE_WIDTH*j+:`BYTE_WIDTH]  = agnostic[i][j] ? 8'hFF : rob_byp[i].w_data[`BYTE_WIDTH*j+:`BYTE_WIDTH];
                    if(v0_sel[i][j]) 
                        uop_operand.v0[`BYTE_WIDTH*j+:`BYTE_WIDTH]  = agnostic[i][j] ? 8'hFF : rob_byp[i].w_data[`BYTE_WIDTH*j+:`BYTE_WIDTH];
                end
            end
        end
    endgenerate

endmodule
