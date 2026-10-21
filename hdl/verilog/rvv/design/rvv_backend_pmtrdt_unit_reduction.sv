// description

`ifndef HDL_VERILOG_RVV_DESIGN_RVV_SVH
`include "rvv_backend.svh"
`endif
`ifndef RVV_ASSERT__SVH
`include "rvv_backend_sva.svh"
`endif
`ifndef PMTRDT_DEFINE_SVH
`include "rvv_backend_pmtrdt.svh"
`endif

module rvv_backend_pmtrdt_unit_reduction
(
  clk,
  rst_n,

  rdt_uop_valid,
  rdt_uop,
  rdt_uop_ready,

  rdt_res_valid,
  rdt_res,
  rdt_res_ready,

  trap_flush_rvv
);

// ---port definition-------------------------------------------------
// global signal
  input logic       clk;
  input logic       rst_n;

// the uop
  input             rdt_uop_valid;
  input PMT_RDT_RS_t rdt_uop;
  output logic      rdt_uop_ready;

// the result
  output logic      rdt_res_valid;
  output PU2ROB_t   rdt_res;
  input             rdt_res_ready;

// trap-flush
  input             trap_flush_rvv;

// ---parameter definition--------------------------------------------
  localparam        ALU_WIDTH       = 32;
  localparam        ALU_BYTE        = ALU_WIDTH/8;
  localparam        ALU_NUM_T0      = `VLENB/(ALU_BYTE*2);  // ALU width: 4B; 2 src operands each ALU
  localparam        ALU_STAGE_NUM   = 5'($clog2(ALU_NUM_T0));
  localparam        VIOTA_STRIDE    = 4;
  localparam        M_SUM_NUM       = `VLENB/VIOTA_STRIDE;
  localparam        ALU_NUM_T1      = ALU_NUM_T0/2;
  localparam        ALU_NUM_T2      = ALU_NUM_T1/2;
  localparam        ALU_NUM_T3      = ALU_NUM_T2/2;
  localparam        ALU_NUM_T4      = ALU_NUM_T3/2;

// ---internal signal definition--------------------------------------
  logic                     wsum, wsum_h;          // widen sum high part
  logic [`VLEN-1:0]         widen_vs2;       // vs2 data after being widen if need
  BYTE_TYPE_t               widen_vs2_type;  // vs2 data btpe type after being widen if need

  RDT_ALU_t                 alu_ctrl_t0, alu_ctrl_t1;
  logic                     alu_t0_valid, alu_t1_valid;
  logic                     alu_t0_ready, alu_t1_ready;
  logic [ALU_NUM_T0-1:0][ALU_BYTE-1:0][7:0] src1_t0, src2_t0, dst_t0, data_t1; // reduction operation in 0 stage: source value for reduction vs2[*]
  logic [ALU_BYTE-1:0][7:0] vs1_t0, vs1_t1;                // source value for reduction vs1[0]

  VM_STATE_e                vm_state, next_vm_state;             // vector mask instruction: vcpop, viota
  logic                     state_en;
  logic                     vm_en;
  logic                     vm_last_opr;                   // last operation for vm instruction.
  logic [`VL_WIDTH-1:0]     vm_cnt, vm_cnt_q;
  RDT_VM_t                  vm_ctrl, vm_ctrl_q;
  logic [`VLEN-1:0]         vs2_m, vs2_m_tail_tmp, vs2_m_tail, vs2_m_body, vs2_m_d, vs2_m_q;       // vector mask register - vs2
  logic [`VLEN-1:0]         vm_vs2;
  logic [`VLENB-1:0]        vs2_m_t0, vs2_m_t1;            // vector mask register for pipeline
  logic [M_SUM_NUM-1:0][`VSTART_WIDTH-1:0] vs2_m_sum_t0, vs2_m_sum_t1;   // vector mask sum for pipeline with VIOTA_STRIDE

  // ALU_STAGE_NUM > 0
  RDT_ALU_t                 alu_ctrl_t2;
  logic                     alu_t2_valid;
  logic                     alu_t2_ready;
  logic [ALU_NUM_T1-1:0][ALU_BYTE-1:0][7:0] src1_t1, src2_t1, dst_t1, data_t2; // reduction operation in 1 stage: source value for reduction data_t1
  logic [ALU_BYTE-1:0][7:0] vs1_t2;        // source value for reduction vs1[0]
  logic [`VLENB-1:0]        vs2_m_t2;
  logic [M_SUM_NUM-1:0][`VSTART_WIDTH-1:0]  vs2_m_sum_t1_tmp, vs2_m_sum_t2;
  // ALU_STAGE_NUM > 1
  RDT_ALU_t                 alu_ctrl_t3;
  logic                     alu_t3_valid;
  logic                     alu_t3_ready;
  logic [ALU_NUM_T2-1:0][ALU_BYTE-1:0][7:0] src1_t2, src2_t2, dst_t2, data_t3; // reduction operation in 1 stage: source value for reduction data_t2
  logic [ALU_BYTE-1:0][7:0] vs1_t3;        // source value for reduction vs1[0]
  logic [`VLENB-1:0]        vs2_m_t3;
  logic [M_SUM_NUM-1:0][`VSTART_WIDTH-1:0]  vs2_m_sum_t2_tmp, vs2_m_sum_t3;
  // ALU_STAGE_NUM > 2
  RDT_ALU_t                 alu_ctrl_t4;
  logic                     alu_t4_valid;
  logic                     alu_t4_ready;
  logic [ALU_NUM_T3-1:0][ALU_BYTE-1:0][7:0] src1_t3, src2_t3, dst_t3, data_t4; // reduction operation in 1 stage: source value for reduction data_t3
  logic [ALU_BYTE-1:0][7:0] vs1_t4;        // source value for reduction vs1[0]
  logic [`VLENB-1:0]        vs2_m_t4;
  logic [M_SUM_NUM-1:0][`VSTART_WIDTH-1:0]  vs2_m_sum_t3_tmp, vs2_m_sum_t4;
  // ALU_STAGE_NUM > 3
  RDT_ALU_t                 alu_ctrl_t5;
  logic                     alu_t5_valid;
  logic                     alu_t5_ready;
  logic [ALU_NUM_T4-1:0][ALU_BYTE-1:0][7:0] src1_t4, src2_t4, dst_t4, data_t5; // reduction operation in 1 stage: source value for reduction data_t4
  logic [ALU_BYTE-1:0][7:0] vs1_t5;        // source value for reduction vs1[0]
  logic [`VLENB-1:0]        vs2_m_t5;
  logic [M_SUM_NUM-1:0][`VSTART_WIDTH-1:0]  vs2_m_sum_t4_tmp, vs2_m_sum_t5;

  // ALU_STAGE_NUM == 0
  logic [`VLEN/ALU_WIDTH-1:0][ALU_BYTE-1:0][7:0]   viota_src2_t0;
  logic [`VLEN/ALU_WIDTH-1:0][ALU_BYTE-1:0][7:0]   viota_src2_t1;
  logic [ALU_BYTE-1:0][7:0] vs1_rdt_vm_t0;
  logic [ALU_BYTE-1:0][7:0] vs1_rdt_vm_t1;
  // ALU_STAGE_NUM == 1
  logic [`VLEN/ALU_WIDTH-1:0][ALU_BYTE-1:0][7:0]   viota_src2_t2;
  logic [ALU_BYTE-1:0][7:0] vs1_rdt_vm_t2;
  // ALU_STAGE_NUM == 2
  logic [`VLEN/ALU_WIDTH-1:0][ALU_BYTE-1:0][7:0]   viota_src2_t3;
  logic [ALU_BYTE-1:0][7:0] vs1_rdt_vm_t3;
  // ALU_STAGE_NUM == 3
  logic [`VLEN/ALU_WIDTH-1:0][ALU_BYTE-1:0][7:0]   viota_src2_t4;
  logic [ALU_BYTE-1:0][7:0] vs1_rdt_vm_t4;
  // ALU_STAGE_NUM == 4
  logic [`VLEN/ALU_WIDTH-1:0][ALU_BYTE-1:0][7:0]   viota_src2_t5;
  logic [ALU_BYTE-1:0][7:0] vs1_rdt_vm_t5;

  RDT_ALU_t                 alu_ctrl;
  logic                     alu_ctrl_valid;
  logic [ALU_BYTE-1:0][7:0] rdt_vs2, rdt_vs1;
  logic [7:0]               rdt_src1_8b,  rdt_src2_8b;
  logic [7:0]               rdt_vs1_8b,  rdt_vs2_8b,  dst_8b;
  logic [15:0]              rdt_vs1_16b, rdt_vs2_16b, dst_16b;
  logic [31:0]              rdt_vs1_32b, rdt_vs2_32b, dst_32b;
  logic [ALU_WIDTH-1:0]     rdt_dst;
  logic [ALU_BYTE-1:0][7:0] rdt_pre_dst;

  logic [ALU_BYTE-1:0][7:0] viota_src1;
  logic [`VLEN/ALU_WIDTH-1:0][ALU_BYTE-1:0][7:0]   viota_src2;
  logic [`VLEN/ALU_WIDTH-1:0][ALU_BYTE-1:0]        viota_cin;
  logic [`VLEN/ALU_WIDTH-1:0][ALU_BYTE-1:0]        viota_cout;
  logic [`VLEN/ALU_WIDTH-1:0][ALU_BYTE-1:0][7:0]   viota_dst;

  genvar i;

// ---code start------------------------------------------------------
  // VM FSM
  always_comb begin
    next_vm_state = MSK0;
    state_en = 1'b0;
    vm_en = 1'b0;
    vm_last_opr = 1'b0;
    case (vm_state)
      MSK0: begin
        if(rdt_uop_valid & ((vm_ctrl.uop_funct6==VWRXUNARY0)|(vm_ctrl.uop_funct6==VMUNARY0))) begin
          if (vm_cnt < vm_ctrl.vlmax) begin
            next_vm_state = MSKN;
            state_en = 1'b1;
            vm_en = 1'b1;
          end else begin
            vm_last_opr = 1'b1;
          end
        end
      end
      default: begin // MSKN
        if (vm_cnt >= vm_ctrl_q.vlmax) begin
          next_vm_state = MSK0;
          state_en = vm_ctrl_q.uop_funct6==VMUNARY0 ? rdt_uop_valid : 1'b1;
          vm_last_opr = 1'b1;
        end
        vm_en = 1'b1;
      end
    endcase
  end
  cdffr #(.T(VM_STATE_e), .INIT(MSK0)) vm_state_reg (.q(vm_state), .d(next_vm_state), .c(trap_flush_rvv), .e(state_en&alu_t0_valid&alu_t0_ready), .clk(clk), .rst_n(rst_n));
  
  // vm_cnt
  always_comb begin
    case (vm_state)
      MSK0: begin
        case (vm_ctrl.uop_funct6)
          VMUNARY0: begin
            case (vm_ctrl.vd_eew)
              EEW32: vm_cnt = `VLENW;
              EEW16: vm_cnt = `VLENH;
              default: vm_cnt = `VLENB;
            endcase
          end
          default: vm_cnt = `VLENH;
        endcase
      end
      default: begin // MSKN
        case (vm_ctrl_q.uop_funct6)
          VMUNARY0: begin
            case (vm_ctrl_q.vd_eew)
              EEW32: vm_cnt = vm_cnt_q + `VLENW;
              EEW16: vm_cnt = vm_cnt_q + `VLENH;
              default: vm_cnt = vm_cnt_q + `VLENB;
            endcase
          end
          default: vm_cnt = vm_cnt_q +`VLENH;
        endcase
      end
    endcase
  end
  cdffr #(.T(logic[`VL_WIDTH-1:0])) vm_cnt_reg (.q(vm_cnt_q), .d(vm_cnt), .c(trap_flush_rvv), .e(vm_en&alu_t0_valid&alu_t0_ready), .clk(clk), .rst_n(rst_n));

  // vs2_m data
  barrel_shifter #(.DATA_WIDTH(`VLEN)) 
  u_tail (.din((`VLEN)'('1)), .shift_amount(rdt_uop.vl[$clog2(`VLEN)-1:0]), .shift_mode(2'b00), .dout(vs2_m_tail_tmp));
  
  assign vs2_m_tail = rdt_uop.vl[$clog2(`VLEN)] ? 'b0 : vs2_m_tail_tmp;
  assign vs2_m_body = ~vs2_m_tail;
  assign vs2_m = rdt_uop.vs2_data & (rdt_uop.v0_data | {(`VLEN){rdt_uop.vm}}) & vs2_m_body;

  always_comb begin
    case (vm_state)
      MSK0: begin
        case (vm_ctrl.uop_funct6)
          VMUNARY0: begin
            case (vm_ctrl.vd_eew)
              EEW32: vs2_m_d = vs2_m >> `VLENW;
              EEW16: vs2_m_d = vs2_m >> `VLENH;
              default: vs2_m_d = vs2_m >> `VLENB; //EEW8
            endcase
          end
          default: vs2_m_d = vs2_m >> `VLENH; // vcpop updates a XRF.
                                              // in general, `VL_WIDTH is very less than `XLEN.
        endcase
      end
      default: begin //MSKN
        case (vm_ctrl_q.uop_funct6)
          VMUNARY0: begin
            case (vm_ctrl_q.vd_eew)
              EEW32: vs2_m_d = vs2_m_q >> `VLENW;
              EEW16: vs2_m_d = vs2_m_q >> `VLENH;
              default: vs2_m_d = vs2_m_q >> `VLENB; //EEW8
            endcase
          end
          default: vs2_m_d = vs2_m_q >> `VLENH; // vcpop updates a XRF.
                                              // in general, `VL_WIDTH is very less than `XLEN.
        endcase
      end
    endcase
  end
  edff #(.T(logic[`VLEN-1:0])) vs2_m_reg (.q(vs2_m_q), .d(vs2_m_d), .e(vm_en&alu_t0_valid&alu_t0_ready), .clk(clk), .rst_n(rst_n));

  assign vm_ctrl.uop_funct6 = rdt_uop.uop_funct6;
  assign vm_ctrl.vlmax      = rdt_uop.vlmax;
  assign vm_ctrl.vd_eew     = rdt_uop.vd_eew;
  cdffr #(.T(RDT_VM_t)) vm_ctrl_reg (.q(vm_ctrl_q), .d(vm_ctrl), .c(trap_flush_rvv), .e(vm_en&(vm_state==MSK0)&alu_t0_valid&alu_t0_ready), .clk(clk), .rst_n(rst_n));

  // vm_vs2 data
  always_comb begin
    case (vm_state)
      MSK0: begin
        case (vm_ctrl.uop_funct6)
          VMUNARY0: begin
            case (vm_ctrl.vd_eew)
              EEW32: for (int j=0; j<`VLENW; j++) vm_vs2[32*j+:32] = {31'h0, vs2_m[j]};
              EEW16: for (int j=0; j<`VLENH; j++) vm_vs2[16*j+:16] = {15'h0, vs2_m[j]};
              default: for (int j=0; j<`VLENB; j++) vm_vs2[8*j+:8] = {7'h0, vs2_m[j]};
            endcase
          end
          default: for (int j=0; j<`VLENH; j++) vm_vs2[16*j+:16] = {15'h0, vs2_m[j]};
        endcase
      end
      default: begin // MSKN
        case (vm_ctrl_q.uop_funct6)
          VMUNARY0: begin
            case (vm_ctrl_q.vd_eew)
              EEW32: for (int j=0; j<`VLENW; j++) vm_vs2[32*j+:32] = {31'h0, vs2_m_q[j]};
              EEW16: for (int j=0; j<`VLENH; j++) vm_vs2[16*j+:16] = {15'h0, vs2_m_q[j]};
              default: for (int j=0; j<`VLENB; j++) vm_vs2[8*j+:8] = {7'h0, vs2_m_q[j]};
            endcase
          end
          default: for (int j=0; j<`VLENH; j++) vm_vs2[16*j+:16] = {15'h0, vs2_m_q[j]};
        endcase
      end
    endcase
  end

  generate
    // src1_t0/src2_t0 data
    for (i=0; i<ALU_NUM_T0; i++) begin : gen_src_t0
      // src2_t0 data
      always_comb begin
        src2_t0[i][0][7:0] = rdt_uop.vs2_data[8*(8*i)+:8]  ;
        src2_t0[i][1][7:0] = rdt_uop.vs2_data[8*(8*i+1)+:8]; 
        src2_t0[i][2][7:0] = rdt_uop.vs2_data[8*(8*i+2)+:8]; 
        src2_t0[i][3][7:0] = rdt_uop.vs2_data[8*(8*i+3)+:8]; 
        case (rdt_uop.uop_funct6)
          VMUNARY0, // VIOTA
          VWRXUNARY0: begin // VCPOP
            src2_t0[i][0][7:0] = vm_vs2[8*(8*i)+:8]  ;
            src2_t0[i][1][7:0] = vm_vs2[8*(8*i+1)+:8]; 
            src2_t0[i][2][7:0] = vm_vs2[8*(8*i+2)+:8]; 
            src2_t0[i][3][7:0] = vm_vs2[8*(8*i+3)+:8]; 
          end
          VWREDSUMU,
          VWREDSUM:begin
            if (widen_vs2_type[8*i]   == BODY_ACTIVE) src2_t0[i][0][7:0] = widen_vs2[8*(8*i)+:8];
            else                                      src2_t0[i][0][7:0] = 8'h00;
            if (widen_vs2_type[8*i+1] == BODY_ACTIVE) src2_t0[i][1][7:0] = widen_vs2[8*(8*i+1)+:8];
            else                                      src2_t0[i][1][7:0] = 8'h00;
            if (widen_vs2_type[8*i+2] == BODY_ACTIVE) src2_t0[i][2][7:0] = widen_vs2[8*(8*i+2)+:8];
            else                                      src2_t0[i][2][7:0] = 8'h00;
            if (widen_vs2_type[8*i+3] == BODY_ACTIVE) src2_t0[i][3][7:0] = widen_vs2[8*(8*i+3)+:8];
            else                                      src2_t0[i][3][7:0] = 8'h00;
          end
          VREDMAX:begin
            case (rdt_uop.vs2_eew)
              EEW32:begin
                if (rdt_uop.vs2_type[8*i]   != BODY_ACTIVE) src2_t0[i][0][7:0] = 8'h00;
                if (rdt_uop.vs2_type[8*i+1] != BODY_ACTIVE) src2_t0[i][1][7:0] = 8'h00; 
                if (rdt_uop.vs2_type[8*i+2] != BODY_ACTIVE) src2_t0[i][2][7:0] = 8'h00; 
                if (rdt_uop.vs2_type[8*i+3] != BODY_ACTIVE) src2_t0[i][3][7:0] = 8'h80; 
              end
              EEW16:begin
                if (rdt_uop.vs2_type[8*i]   != BODY_ACTIVE) src2_t0[i][0][7:0] = 8'h00;
                if (rdt_uop.vs2_type[8*i+1] != BODY_ACTIVE) src2_t0[i][1][7:0] = 8'h80; 
                if (rdt_uop.vs2_type[8*i+2] != BODY_ACTIVE) src2_t0[i][2][7:0] = 8'h00; 
                if (rdt_uop.vs2_type[8*i+3] != BODY_ACTIVE) src2_t0[i][3][7:0] = 8'h80; 
              end
              default:begin // EEW8
                if (rdt_uop.vs2_type[8*i]   != BODY_ACTIVE) src2_t0[i][0][7:0] = 8'h80;
                if (rdt_uop.vs2_type[8*i+1] != BODY_ACTIVE) src2_t0[i][1][7:0] = 8'h80; 
                if (rdt_uop.vs2_type[8*i+2] != BODY_ACTIVE) src2_t0[i][2][7:0] = 8'h80; 
                if (rdt_uop.vs2_type[8*i+3] != BODY_ACTIVE) src2_t0[i][3][7:0] = 8'h80; 
              end
            endcase
          end
          VREDMIN:begin
            case (rdt_uop.vs2_eew)
              EEW32:begin
                if (rdt_uop.vs2_type[8*i]   != BODY_ACTIVE) src2_t0[i][0][7:0] = 8'hFF;
                if (rdt_uop.vs2_type[8*i+1] != BODY_ACTIVE) src2_t0[i][1][7:0] = 8'hFF; 
                if (rdt_uop.vs2_type[8*i+2] != BODY_ACTIVE) src2_t0[i][2][7:0] = 8'hFF; 
                if (rdt_uop.vs2_type[8*i+3] != BODY_ACTIVE) src2_t0[i][3][7:0] = 8'h7F; 
              end
              EEW16:begin
                if (rdt_uop.vs2_type[8*i]   != BODY_ACTIVE) src2_t0[i][0][7:0] = 8'hFF;
                if (rdt_uop.vs2_type[8*i+1] != BODY_ACTIVE) src2_t0[i][1][7:0] = 8'h7F; 
                if (rdt_uop.vs2_type[8*i+2] != BODY_ACTIVE) src2_t0[i][2][7:0] = 8'hFF; 
                if (rdt_uop.vs2_type[8*i+3] != BODY_ACTIVE) src2_t0[i][3][7:0] = 8'h7F; 
              end
              default:begin // EEW8
                if (rdt_uop.vs2_type[8*i]   != BODY_ACTIVE) src2_t0[i][0][7:0] = 8'h7F;
                if (rdt_uop.vs2_type[8*i+1] != BODY_ACTIVE) src2_t0[i][1][7:0] = 8'h7F; 
                if (rdt_uop.vs2_type[8*i+2] != BODY_ACTIVE) src2_t0[i][2][7:0] = 8'h7F; 
                if (rdt_uop.vs2_type[8*i+3] != BODY_ACTIVE) src2_t0[i][3][7:0] = 8'h7F; 
              end
            endcase
          end
          VREDMINU,
          VREDAND:begin
            if (rdt_uop.vs2_type[8*i]   != BODY_ACTIVE) src2_t0[i][0][7:0] = 8'hFF;
            if (rdt_uop.vs2_type[8*i+1] != BODY_ACTIVE) src2_t0[i][1][7:0] = 8'hFF;
            if (rdt_uop.vs2_type[8*i+2] != BODY_ACTIVE) src2_t0[i][2][7:0] = 8'hFF;
            if (rdt_uop.vs2_type[8*i+3] != BODY_ACTIVE) src2_t0[i][3][7:0] = 8'hFF;
          end
          default:begin // VREDSUM, VREDMAXU, VREDOR, VREDXOR
            if (rdt_uop.vs2_type[8*i]   != BODY_ACTIVE) src2_t0[i][0][7:0] = 8'h00;
            if (rdt_uop.vs2_type[8*i+1] != BODY_ACTIVE) src2_t0[i][1][7:0] = 8'h00; 
            if (rdt_uop.vs2_type[8*i+2] != BODY_ACTIVE) src2_t0[i][2][7:0] = 8'h00; 
            if (rdt_uop.vs2_type[8*i+3] != BODY_ACTIVE) src2_t0[i][3][7:0] = 8'h00; 
          end
        endcase
      end
  
      // src1_t0 data
      always_comb begin
        src1_t0[i][0][7:0] = rdt_uop.vs2_data[8*(8*i+4)+:8];
        src1_t0[i][1][7:0] = rdt_uop.vs2_data[8*(8*i+5)+:8];
        src1_t0[i][2][7:0] = rdt_uop.vs2_data[8*(8*i+6)+:8];
        src1_t0[i][3][7:0] = rdt_uop.vs2_data[8*(8*i+7)+:8];
        case (rdt_uop.uop_funct6)
          VMUNARY0,
          VWRXUNARY0:begin
            src1_t0[i][0][7:0] = vm_vs2[8*(8*i+4)+:8];
            src1_t0[i][1][7:0] = vm_vs2[8*(8*i+5)+:8];
            src1_t0[i][2][7:0] = vm_vs2[8*(8*i+6)+:8];
            src1_t0[i][3][7:0] = vm_vs2[8*(8*i+7)+:8];
          end
          VWREDSUMU,
          VWREDSUM:begin
            if (widen_vs2_type[8*i+4] == BODY_ACTIVE) src1_t0[i][0][7:0] = widen_vs2[8*(8*i+4)+:8];
            else                                      src1_t0[i][0][7:0] = 8'h00;
            if (widen_vs2_type[8*i+5] == BODY_ACTIVE) src1_t0[i][1][7:0] = widen_vs2[8*(8*i+5)+:8];
            else                                      src1_t0[i][1][7:0] = 8'h00;
            if (widen_vs2_type[8*i+6] == BODY_ACTIVE) src1_t0[i][2][7:0] = widen_vs2[8*(8*i+6)+:8];
            else                                      src1_t0[i][2][7:0] = 8'h00;
            if (widen_vs2_type[8*i+7] == BODY_ACTIVE) src1_t0[i][3][7:0] = widen_vs2[8*(8*i+7)+:8];
            else                                      src1_t0[i][3][7:0] = 8'h00;
          end
          VREDMAX:begin
            case (rdt_uop.vs2_eew)
              EEW32:begin
                if (rdt_uop.vs2_type[8*i+4] != BODY_ACTIVE) src1_t0[i][0][7:0] = 8'h00;
                if (rdt_uop.vs2_type[8*i+5] != BODY_ACTIVE) src1_t0[i][1][7:0] = 8'h00;
                if (rdt_uop.vs2_type[8*i+6] != BODY_ACTIVE) src1_t0[i][2][7:0] = 8'h00;
                if (rdt_uop.vs2_type[8*i+7] != BODY_ACTIVE) src1_t0[i][3][7:0] = 8'h80;
              end
              EEW16:begin
                if (rdt_uop.vs2_type[8*i+4] != BODY_ACTIVE) src1_t0[i][0][7:0] = 8'h00;
                if (rdt_uop.vs2_type[8*i+5] != BODY_ACTIVE) src1_t0[i][1][7:0] = 8'h80;
                if (rdt_uop.vs2_type[8*i+6] != BODY_ACTIVE) src1_t0[i][2][7:0] = 8'h00;
                if (rdt_uop.vs2_type[8*i+7] != BODY_ACTIVE) src1_t0[i][3][7:0] = 8'h80;
              end
              default:begin // EEW8
                if (rdt_uop.vs2_type[8*i+4] != BODY_ACTIVE) src1_t0[i][0][7:0] = 8'h80;
                if (rdt_uop.vs2_type[8*i+5] != BODY_ACTIVE) src1_t0[i][1][7:0] = 8'h80;
                if (rdt_uop.vs2_type[8*i+6] != BODY_ACTIVE) src1_t0[i][2][7:0] = 8'h80;
                if (rdt_uop.vs2_type[8*i+7] != BODY_ACTIVE) src1_t0[i][3][7:0] = 8'h80;
              end
            endcase
          end
          VREDMIN:begin
            case (rdt_uop.vs2_eew)
              EEW32:begin
                if (rdt_uop.vs2_type[8*i+4] != BODY_ACTIVE) src1_t0[i][0][7:0] = 8'hFF;
                if (rdt_uop.vs2_type[8*i+5] != BODY_ACTIVE) src1_t0[i][1][7:0] = 8'hFF;
                if (rdt_uop.vs2_type[8*i+6] != BODY_ACTIVE) src1_t0[i][2][7:0] = 8'hFF;
                if (rdt_uop.vs2_type[8*i+7] != BODY_ACTIVE) src1_t0[i][3][7:0] = 8'h7F;
              end
              EEW16:begin
                if (rdt_uop.vs2_type[8*i+4] != BODY_ACTIVE) src1_t0[i][0][7:0] = 8'hFF;
                if (rdt_uop.vs2_type[8*i+5] != BODY_ACTIVE) src1_t0[i][1][7:0] = 8'h7F;
                if (rdt_uop.vs2_type[8*i+6] != BODY_ACTIVE) src1_t0[i][2][7:0] = 8'hFF;
                if (rdt_uop.vs2_type[8*i+7] != BODY_ACTIVE) src1_t0[i][3][7:0] = 8'h7F;
              end
              default:begin // EE8
                if (rdt_uop.vs2_type[8*i+4] != BODY_ACTIVE) src1_t0[i][0][7:0] = 8'h7F;
                if (rdt_uop.vs2_type[8*i+5] != BODY_ACTIVE) src1_t0[i][1][7:0] = 8'h7F;
                if (rdt_uop.vs2_type[8*i+6] != BODY_ACTIVE) src1_t0[i][2][7:0] = 8'h7F;
                if (rdt_uop.vs2_type[8*i+7] != BODY_ACTIVE) src1_t0[i][3][7:0] = 8'h7F;
              end
            endcase
          end
          VREDMINU,
          VREDAND:begin
            if (rdt_uop.vs2_type[8*i+4] != BODY_ACTIVE) src1_t0[i][0][7:0] = 8'hFF;
            if (rdt_uop.vs2_type[8*i+5] != BODY_ACTIVE) src1_t0[i][1][7:0] = 8'hFF;
            if (rdt_uop.vs2_type[8*i+6] != BODY_ACTIVE) src1_t0[i][2][7:0] = 8'hFF;
            if (rdt_uop.vs2_type[8*i+7] != BODY_ACTIVE) src1_t0[i][3][7:0] = 8'hFF;
          end
          default:begin // VREDSUM, VREDMAXU, VREDOR, VREDXOR
            if (rdt_uop.vs2_type[8*i+4] != BODY_ACTIVE) src1_t0[i][0][7:0] = 8'h00;
            if (rdt_uop.vs2_type[8*i+5] != BODY_ACTIVE) src1_t0[i][1][7:0] = 8'h00;
            if (rdt_uop.vs2_type[8*i+6] != BODY_ACTIVE) src1_t0[i][2][7:0] = 8'h00;
            if (rdt_uop.vs2_type[8*i+7] != BODY_ACTIVE) src1_t0[i][3][7:0] = 8'h00;
          end
        endcase
      end
    end //for (i=0; i<ALU_NUM_T0; i++) begin : gen_src_t0
  endgenerate

  assign wsum = (rdt_uop.uop_funct6 == VWREDSUMU) || (rdt_uop.uop_funct6 == VWREDSUM);
  cdffr #(.T(logic)) wsum_h_reg (.q(wsum_h), .d(~wsum_h), .c(trap_flush_rvv), .e(wsum & alu_t0_valid & alu_t0_ready), .clk(clk), .rst_n(rst_n));
  // widen vs2 data & widen vs2 eew
  always_comb begin
    case(rdt_uop.vs2_eew)
      EEW16:begin
        for (int j=0; j<`VLENB/4; j++) begin
          widen_vs2[16*(2*j)+:16]   = wsum_h ? rdt_uop.vs2_data[(`VLEN/2+16*j)+:16] : rdt_uop.vs2_data[(16*j)+:16];
          widen_vs2[16*(2*j+1)+:16] = rdt_uop.uop_funct6 == VWREDSUM ? wsum_h ? {16{rdt_uop.vs2_data[`VLEN/2+16*(j+1)-1]}}
                                                                              : {16{rdt_uop.vs2_data[16*(j+1)-1]}}
                                                                     : '0;
          widen_vs2_type[4*j]   = wsum_h ? rdt_uop.vs2_type[`VLENB/2+2*j]   : rdt_uop.vs2_type[2*j];
          widen_vs2_type[4*j+1] = wsum_h ? rdt_uop.vs2_type[`VLENB/2+2*j+1] : rdt_uop.vs2_type[2*j+1];
          widen_vs2_type[4*j+2] = wsum_h ? rdt_uop.vs2_type[`VLENB/2+2*j]   : rdt_uop.vs2_type[2*j];
          widen_vs2_type[4*j+3] = wsum_h ? rdt_uop.vs2_type[`VLENB/2+2*j+1] : rdt_uop.vs2_type[2*j+1];
        end
      end
      default:begin // EEW8
        for (int j=0; j<`VLENB/2; j++) begin
          widen_vs2[8*(2*j)+:8]   = wsum_h ? rdt_uop.vs2_data[(`VLEN/2+8*j)+:8] : rdt_uop.vs2_data[(8*j)+:8];
          widen_vs2[8*(2*j+1)+:8] = rdt_uop.uop_funct6 == VWREDSUM ? wsum_h ? {8{rdt_uop.vs2_data[`VLEN/2+8*(j+1)-1]}}
                                                                            : {8{rdt_uop.vs2_data[8*(j+1)-1]}}
                                                                   : '0;
          widen_vs2_type[2*j]   = wsum_h ? rdt_uop.vs2_type[`VLENB/2+j] : rdt_uop.vs2_type[j];
          widen_vs2_type[2*j+1] = wsum_h ? rdt_uop.vs2_type[`VLENB/2+j] : rdt_uop.vs2_type[j];
        end
      end
    endcase
  end

  // ALU for 1stage
  assign alu_t0_valid = rdt_uop_valid & (rdt_uop_ready | !wsum_h);
`ifdef TB_SUPPORT
  assign alu_ctrl_t0.uop_pc     = rdt_uop.uop_pc;
`endif
  assign alu_ctrl_t0.rob_entry  = rdt_uop.rob_entry;
  assign alu_ctrl_t0.vm_state   = vm_state;
  assign alu_ctrl_t0.uop_funct6 = rdt_uop.uop_funct6;
  assign alu_ctrl_t0.vd_eew     = vm_ctrl.uop_funct6==VWRXUNARY0 ? EEW16 : rdt_uop.vd_eew;
  assign alu_ctrl_t0.vs2_eew    = vm_ctrl.uop_funct6==VWRXUNARY0 ? EEW16 : rdt_uop.vd_eew; // 2*SEW when vwsum
  assign alu_ctrl_t0.first_uop_valid = rdt_uop.first_uop_valid & ~wsum_h;
  assign alu_ctrl_t0.last_uop_valid = vm_ctrl.uop_funct6==VWRXUNARY0 ? vm_last_opr : wsum ? rdt_uop.last_uop_valid&wsum_h : rdt_uop.last_uop_valid;

  generate
    for (i=0; i<ALU_NUM_T0; i++) begin : gen_alu_t0
      rvv_backend_pmtrdt_unit_reduction_alu #(
        .ALU_WIDTH (ALU_WIDTH)
      ) u_alu_t0 (
        .src1   (src1_t0[i]),
        .src2   (src2_t0[i]),
        .ctrl   (alu_ctrl_t0),
        .dst    (dst_t0[i])
      );
  
      edff #(.T(logic[ALU_WIDTH-1:0])) rdt_data_t0_reg (.q(data_t1[i]), .d(dst_t0[i]), .e(alu_t0_valid&alu_t0_ready), .clk(clk), .rst_n(rst_n));
    end
  endgenerate

  assign vs2_m_t0 = vm_state==MSK0 ? vs2_m[`VLENB-1:0] : vs2_m_q[`VLENB-1:0];
  edff #(.T(logic[`VLENB-1:0])) rdt_vs2_m_t0_reg (.q(vs2_m_t1), .d(vs2_m_t0), .e(alu_t0_valid&alu_t0_ready), .clk(clk), .rst_n(rst_n));

`ifdef CORALNPU_STRUCTURAL_DATAPATH
  // Structural Brent-Kung 16-element Parallel-Prefix Mask Adder
  // Replaces the 62 cascaded half-adders with balanced depth <= 7 gates
  logic [M_SUM_NUM/4-1:0][`VSTART_WIDTH-1:0] blk_total_sum;

  for (genvar blk = 0; blk < M_SUM_NUM/4; blk = blk + 1) begin : gen_bk_blk
    logic [3:0][`VSTART_WIDTH-1:0] blk_sum;

    brent_kung_prefix_sum_16 #(
      .WIDTH (`VSTART_WIDTH)
    ) u_mask_bk16 (
      .mask_in          (vs2_m_t0[blk*16 +: 16]),
      .block_prefix_sum (blk_sum),
      .total_sum        (blk_total_sum[blk]),
      .prefix_sum       ()
    );

    if (blk == 0) begin : gen_blk0
      assign vs2_m_sum_t0[0] = blk_sum[0];
    end else begin : gen_blk_ext
      assign vs2_m_sum_t0[blk*4 + 0] = blk_total_sum[blk - 1];
    end
    assign vs2_m_sum_t0[blk*4 + 1] = blk_sum[1];
    assign vs2_m_sum_t0[blk*4 + 2] = blk_sum[2];
    assign vs2_m_sum_t0[blk*4 + 3] = blk_sum[3];
  end
`else
  always_comb begin
    for (int i=0; i<M_SUM_NUM; i++) vs2_m_sum_t0[i] = '0;
    for (int i=1; i<M_SUM_NUM; i++) 
      for (int j=0; j<VIOTA_STRIDE; j++) vs2_m_sum_t0[i] += vs2_m_t0[(i-1)*VIOTA_STRIDE+j];
    for (int i=2; i<M_SUM_NUM; i=i+2) vs2_m_sum_t0[i] = vs2_m_sum_t0[i] + vs2_m_sum_t0[i-1]; 
    for (int i=3; i<M_SUM_NUM; i=i+4) vs2_m_sum_t0[i] = vs2_m_sum_t0[i] + vs2_m_sum_t0[i-1];
    for (int i=4; i<M_SUM_NUM; i=i+4) vs2_m_sum_t0[i] = vs2_m_sum_t0[i] + vs2_m_sum_t0[i-2];
  end
`endif
  edff #(.T(logic[M_SUM_NUM-1:0][`VSTART_WIDTH-1:0])) rdt_vs2_m_sum_t0_reg (.q(vs2_m_sum_t1), .d(vs2_m_sum_t0), .e(alu_t0_valid&alu_t0_ready), .clk(clk), .rst_n(rst_n));

  handshake_ff #(.T(RDT_ALU_t)) rdt_alu_ctrl_t0_reg (.outdata(alu_ctrl_t1), .outvalid(alu_t1_valid), .outready(alu_t1_ready), 
                                                     .indata(alu_ctrl_t0),  .invalid(alu_t0_valid),  .inready(alu_t0_ready),
                                                     .c(trap_flush_rvv), .clk(clk), .rst_n(rst_n));

  // vs1_t0
  assign vs1_t0 = rdt_uop.vs1_data[0+:ALU_WIDTH];
  edff #(.T(logic[ALU_WIDTH-1:0])) rdt_vs1_t0_reg (.q(vs1_t1), .d(vs1_t0), .e(alu_t0_valid&alu_t0_ready), .clk(clk), .rst_n(rst_n));

generate
  // reduction for all vs2_data except vs1[0]
  if (ALU_STAGE_NUM > 5'd0) begin
    for (i=0; i<ALU_NUM_T1; i++) begin : gen_alu_t1
      // src2_t1 data
      always_comb begin
        src2_t1[i][0][7:0] = data_t1[2*i][0][7:0];
        src2_t1[i][1][7:0] = data_t1[2*i][1][7:0];
        src2_t1[i][2][7:0] = data_t1[2*i][2][7:0];
        src2_t1[i][3][7:0] = data_t1[2*i][3][7:0];
      end
      // src1_t1 data
      always_comb begin
        src1_t1[i][0][7:0] = data_t1[2*i+1][0][7:0];
        src1_t1[i][1][7:0] = data_t1[2*i+1][1][7:0];
        src1_t1[i][2][7:0] = data_t1[2*i+1][2][7:0];
        src1_t1[i][3][7:0] = data_t1[2*i+1][3][7:0];
      end

      rvv_backend_pmtrdt_unit_reduction_alu #(
        .ALU_WIDTH (ALU_WIDTH)
      ) u_alu_t1 (
        .src1   (src1_t1[i]),
        .src2   (src2_t1[i]),
        .ctrl   (alu_ctrl_t1),
        .dst    (dst_t1[i])
      );

      edff #(.T(logic[ALU_WIDTH-1:0])) rdt_data_t1_reg (.q(data_t2[i]), .d(dst_t1[i]), .e(alu_t1_valid&alu_t1_ready), .clk(clk), .rst_n(rst_n));
    end //end for (i=0; i<ALU_NUM_T1; i++) begin : gen_alu_t1

    edff #(.T(logic[`VLENB-1:0])) rdt_vs2_m_t1_reg (.q(vs2_m_t2), .d(vs2_m_t1), .e(alu_t1_valid&alu_t1_ready), .clk(clk), .rst_n(rst_n));

    always_comb begin
      for (int i=0; i<M_SUM_NUM; i++) vs2_m_sum_t1_tmp[i] = vs2_m_sum_t1[i];
      for (int i=4; i<M_SUM_NUM; i=i+8)
        for (int j=1; j<4; j++) vs2_m_sum_t1_tmp[i+j] = vs2_m_sum_t1[i+j] + vs2_m_sum_t1[i];
      for (int i=8; i<M_SUM_NUM; i=i+8) vs2_m_sum_t1_tmp[i] = vs2_m_sum_t1[i] + vs2_m_sum_t1[i-4];
    end
    edff #(.T(logic[M_SUM_NUM-1:0][`VSTART_WIDTH-1:0])) rdt_vs2_m_sum_t1_reg (.q(vs2_m_sum_t2), .d(vs2_m_sum_t1_tmp), .e(alu_t1_valid&alu_t1_ready), .clk(clk), .rst_n(rst_n));

    handshake_ff #(.T(RDT_ALU_t)) rdt_alu_ctrl_t1_reg (.outdata(alu_ctrl_t2), .outvalid(alu_t2_valid), .outready(alu_t2_ready), 
                                                       .indata(alu_ctrl_t1),  .invalid(alu_t1_valid),  .inready(alu_t1_ready),
                                                       .c(trap_flush_rvv), .clk(clk), .rst_n(rst_n));

    edff #(.T(logic[ALU_WIDTH-1:0])) rdt_vs1_t1_reg (.q(vs1_t2), .d(vs1_t1), .e(alu_t1_valid&alu_t1_ready), .clk(clk), .rst_n(rst_n));
  end
  
  if (ALU_STAGE_NUM > 5'd1) begin
    for (i=0; i<ALU_NUM_T2; i++) begin : gen_alu_t2
      // src2_t2 data
      always_comb begin
        src2_t2[i][0][7:0] = data_t2[2*i][0][7:0];
        src2_t2[i][1][7:0] = data_t2[2*i][1][7:0];
        src2_t2[i][2][7:0] = data_t2[2*i][2][7:0];
        src2_t2[i][3][7:0] = data_t2[2*i][3][7:0];
      end
      // src1_t2 data
      always_comb begin
        src1_t2[i][0][7:0] = data_t2[2*i+1][0][7:0];
        src1_t2[i][1][7:0] = data_t2[2*i+1][1][7:0];
        src1_t2[i][2][7:0] = data_t2[2*i+1][2][7:0];
        src1_t2[i][3][7:0] = data_t2[2*i+1][3][7:0];
      end

      rvv_backend_pmtrdt_unit_reduction_alu #(
        .ALU_WIDTH (ALU_WIDTH)
      ) u_alu_t2 (
        .src1   (src1_t2[i]),
        .src2   (src2_t2[i]),
        .ctrl   (alu_ctrl_t2),
        .dst    (dst_t2[i])
      );

      edff #(.T(logic[ALU_WIDTH-1:0])) rdt_data_t2_reg (.q(data_t3[i]), .d(dst_t2[i]), .e(alu_t2_valid&alu_t2_ready), .clk(clk), .rst_n(rst_n));
    end //end for (i=0; i<ALU_NUM_T2; i++) begin : gen_alu_t2

    edff #(.T(logic[`VLENB-1:0])) rdt_vs2_m_t2_reg (.q(vs2_m_t3), .d(vs2_m_t2), .e(alu_t2_valid&alu_t2_ready), .clk(clk), .rst_n(rst_n));

    always_comb begin
      for (int i=0; i<M_SUM_NUM; i++) vs2_m_sum_t2_tmp[i] = vs2_m_sum_t2[i];
      for (int i=8; i<M_SUM_NUM; i=i+16)
        for (int j=1; j<8; j++) vs2_m_sum_t2_tmp[i+j] = vs2_m_sum_t2[i+j] + vs2_m_sum_t2[i];
      for (int i=16; i<M_SUM_NUM; i=i+16) vs2_m_sum_t2_tmp[i] = vs2_m_sum_t2[i] + vs2_m_sum_t2[i-8];
    end
    edff #(.T(logic[M_SUM_NUM-1:0][`VSTART_WIDTH-1:0])) rdt_vs2_m_sum_t2_reg (.q(vs2_m_sum_t3), .d(vs2_m_sum_t2_tmp), .e(alu_t2_valid&alu_t2_ready), .clk(clk), .rst_n(rst_n));

    handshake_ff #(.T(RDT_ALU_t)) rdt_alu_ctrl_t2_reg (.outdata(alu_ctrl_t3), .outvalid(alu_t3_valid), .outready(alu_t3_ready), 
                                                       .indata(alu_ctrl_t2),  .invalid(alu_t2_valid),  .inready(alu_t2_ready),
                                                       .c(trap_flush_rvv), .clk(clk), .rst_n(rst_n));

    edff #(.T(logic[ALU_WIDTH-1:0])) rdt_vs1_t2_reg (.q(vs1_t3), .d(vs1_t2), .e(alu_t2_valid&alu_t2_ready), .clk(clk), .rst_n(rst_n));
  end

  if (ALU_STAGE_NUM > 5'd2) begin
    for (i=0; i<ALU_NUM_T3; i++) begin : gen_alu_t3
      // src2_t3 data
      always_comb begin
        src2_t3[i][0][7:0] = data_t3[2*i][0][7:0];
        src2_t3[i][1][7:0] = data_t3[2*i][1][7:0];
        src2_t3[i][2][7:0] = data_t3[2*i][2][7:0];
        src2_t3[i][3][7:0] = data_t3[2*i][3][7:0];
      end
      // src1_t3 data
      always_comb begin
        src1_t3[i][0][7:0] = data_t3[2*i+1][0][7:0];
        src1_t3[i][1][7:0] = data_t3[2*i+1][1][7:0];
        src1_t3[i][2][7:0] = data_t3[2*i+1][2][7:0];
        src1_t3[i][3][7:0] = data_t3[2*i+1][3][7:0];
      end

      rvv_backend_pmtrdt_unit_reduction_alu #(
        .ALU_WIDTH (ALU_WIDTH)
      ) u_alu_t3 (
        .src1   (src1_t3[i]),
        .src2   (src2_t3[i]),
        .ctrl   (alu_ctrl_t3),
        .dst    (dst_t3[i])
      );

      edff #(.T(logic[ALU_WIDTH-1:0])) rdt_data_t3_reg (.q(data_t4[i]), .d(dst_t3[i]), .e(alu_t3_valid&alu_t3_ready), .clk(clk), .rst_n(rst_n));
    end //end for (i=0; i<ALU_NUM_T3; i++) begin : gen_alu_t3

    edff #(.T(logic[`VLENB-1:0])) rdt_vs2_m_t3_reg (.q(vs2_m_t4), .d(vs2_m_t3), .e(alu_t3_valid&alu_t3_ready), .clk(clk), .rst_n(rst_n));

    always_comb begin
      for (int i=0; i<M_SUM_NUM; i++) vs2_m_sum_t3_tmp[i] = vs2_m_sum_t3[i];
      for (int i=16; i<M_SUM_NUM; i=i+32)
        for (int j=1; j<16; j++) vs2_m_sum_t3_tmp[i+j] = vs2_m_sum_t3[i+j] + vs2_m_sum_t3[i];
      for (int i=32; i<M_SUM_NUM; i=i+32) vs2_m_sum_t3_tmp[i] = vs2_m_sum_t3[i] + vs2_m_sum_t3[i-16];
    end
    edff #(.T(logic[M_SUM_NUM-1:0][`VSTART_WIDTH-1:0])) rdt_vs2_m_sum_t3_reg (.q(vs2_m_sum_t4), .d(vs2_m_sum_t3_tmp), .e(alu_t3_valid&alu_t3_ready), .clk(clk), .rst_n(rst_n));

    handshake_ff #(.T(RDT_ALU_t)) rdt_alu_ctrl_t3_reg (.outdata(alu_ctrl_t4), .outvalid(alu_t4_valid), .outready(alu_t4_ready),
                                                       .indata(alu_ctrl_t3),  .invalid(alu_t3_valid),  .inready(alu_t3_ready),
                                                       .c(trap_flush_rvv), .clk(clk), .rst_n(rst_n));

    edff #(.T(logic[ALU_WIDTH-1:0])) rdt_vs1_t3_reg (.q(vs1_t4), .d(vs1_t3), .e(alu_t3_valid&alu_t3_ready), .clk(clk), .rst_n(rst_n));
  end

  if (ALU_STAGE_NUM > 5'd3) begin
    for (i=0; i<ALU_NUM_T4; i++) begin : gen_alu_t4
      // src2_t4 data
      always_comb begin
        src2_t4[i][0][7:0] = data_t4[2*i][0][7:0];
        src2_t4[i][1][7:0] = data_t4[2*i][1][7:0];
        src2_t4[i][2][7:0] = data_t4[2*i][2][7:0];
        src2_t4[i][3][7:0] = data_t4[2*i][3][7:0];
      end
      // src1_t4 data
      always_comb begin
        src1_t4[i][0][7:0] = data_t4[2*i+1][0][7:0];
        src1_t4[i][1][7:0] = data_t4[2*i+1][1][7:0];
        src1_t4[i][2][7:0] = data_t4[2*i+1][2][7:0];
        src1_t4[i][3][7:0] = data_t4[2*i+1][3][7:0];
      end

      rvv_backend_pmtrdt_unit_reduction_alu #(
        .ALU_WIDTH (ALU_WIDTH)
      ) u_alu_t4 (
        .src1   (src1_t4[i]),
        .src2   (src2_t4[i]),
        .ctrl   (alu_ctrl_t4),
        .dst    (dst_t4[i])
      );

      edff #(.T(logic[ALU_WIDTH-1:0])) rdt_data_t4_reg (.q(data_t5[i]), .d(dst_t4[i]), .e(alu_t4_valid&alu_t4_ready), .clk(clk), .rst_n(rst_n));
    end //end for (i=0; i<ALU_NUM_T3; i++) begin : gen_alu_t4

    edff #(.T(logic[`VLENB-1:0])) rdt_vs2_m_t4_reg (.q(vs2_m_t5), .d(vs2_m_t4), .e(alu_t4_valid&alu_t4_ready), .clk(clk), .rst_n(rst_n));

    always_comb begin
      for (int i=0; i<M_SUM_NUM; i++) vs2_m_sum_t4_tmp[i] = vs2_m_sum_t4[i];
      for (int i=32; i<M_SUM_NUM; i=i+64)
        for (int j=1; j<32; j++) vs2_m_sum_t4_tmp[i+j] = vs2_m_sum_t4[i+j] + vs2_m_sum_t4[i];
      for (int i=64; i<M_SUM_NUM; i=i+64) vs2_m_sum_t4_tmp[i] = vs2_m_sum_t4[i] + vs2_m_sum_t3[i-32];
    end
    edff #(.T(logic[M_SUM_NUM-1:0][`VSTART_WIDTH-1:0])) rdt_vs2_m_sum_t4_reg (.q(vs2_m_sum_t5), .d(vs2_m_sum_t4_tmp), .e(alu_t4_valid&alu_t4_ready), .clk(clk), .rst_n(rst_n));

    handshake_ff #(.T(RDT_ALU_t)) rdt_alu_ctrl_t4_reg (.outdata(alu_ctrl_t5), .outvalid(alu_t5_valid), .outready(alu_t5_ready), 
                                                       .indata(alu_ctrl_t4),  .invalid(alu_t4_valid), .inready(alu_t4_ready),
                                                       .c(trap_flush_rvv), .clk(clk), .rst_n(rst_n));

    edff #(.T(logic[ALU_WIDTH-1:0])) rdt_vs1_t4_reg (.q(vs1_t5), .d(vs1_t4), .e(alu_t4_valid&alu_t4_ready), .clk(clk), .rst_n(rst_n));
  end

  if (ALU_STAGE_NUM == 5'd0) begin
    assign rdt_vs2 = data_t1[0];
    assign rdt_vs1 = vs1_rdt_vm_t1;
    assign alu_ctrl = alu_ctrl_t1;
    assign alu_ctrl_valid = alu_t1_valid;
    assign alu_t1_ready = rdt_res_ready;
    assign viota_src2 = viota_src2_t1;

    // VM operation
    assign vs1_rdt_vm_t0 = f_mux_rdt_vm(vs1_t0, rdt_pre_dst, alu_ctrl_t0.uop_funct6, alu_ctrl_t0.vm_state, alu_ctrl_t0.first_uop_valid);
    edff #(.T(logic[ALU_BYTE-1:0][7:0])) rdt_vs1_vm_t0_reg (.q(vs1_rdt_vm_t1), .d(vs1_rdt_vm_t0), .e(alu_t0_valid&alu_t0_ready), .clk(clk), .rst_n(rst_n));

    // Viota sum from vs2
    assign viota_src2_t0 = f_vmsum2src2(vs2_m_sum_t0, vs2_m_t0, alu_ctrl_t0.vd_eew);
    edff #(.T(logic[`VLEN/ALU_WIDTH-1:0][ALU_BYTE-1:0][7:0])) viota_src2_t0_reg (.q(viota_src2_t1), .d(viota_src2_t0), .e(alu_t0_valid&alu_t0_ready), .clk(clk), .rst_n(rst_n));
  end

  if (ALU_STAGE_NUM == 5'd1) begin
    assign rdt_vs2 = data_t2[0];
    assign rdt_vs1 = vs1_rdt_vm_t2;
    assign alu_ctrl = alu_ctrl_t2;
    assign alu_ctrl_valid = alu_t2_valid;
    assign alu_t2_ready = rdt_res_ready;
    assign viota_src2 = viota_src2_t2;

    // VM operation
    assign vs1_rdt_vm_t1 = f_mux_rdt_vm(vs1_t1, rdt_pre_dst, alu_ctrl_t1.uop_funct6, alu_ctrl_t1.vm_state, alu_ctrl_t1.first_uop_valid);
    edff #(.T(logic[ALU_BYTE-1:0][7:0])) rdt_vs1_vm_t1_reg (.q(vs1_rdt_vm_t2), .d(vs1_rdt_vm_t1), .e(alu_t1_valid&alu_t1_ready), .clk(clk), .rst_n(rst_n));

    // Viota sum from vs2
    assign viota_src2_t1 = f_vmsum2src2(vs2_m_sum_t1, vs2_m_t1, alu_ctrl_t1.vd_eew);
    edff #(.T(logic[`VLEN/ALU_WIDTH-1:0][ALU_BYTE-1:0][7:0])) viota_src2_t1_reg (.q(viota_src2_t2), .d(viota_src2_t1), .e(alu_t1_valid&alu_t1_ready), .clk(clk), .rst_n(rst_n));
  end

  if (ALU_STAGE_NUM == 5'd2) begin
    assign rdt_vs2 = data_t3[0];
    assign rdt_vs1 = vs1_rdt_vm_t3;
    assign alu_ctrl = alu_ctrl_t3;
    assign alu_ctrl_valid = alu_t3_valid;
    assign alu_t3_ready = rdt_res_ready;
    assign viota_src2 = viota_src2_t3;

    // VM operation
    assign vs1_rdt_vm_t2 = f_mux_rdt_vm(vs1_t2, rdt_pre_dst, alu_ctrl_t2.uop_funct6, alu_ctrl_t2.vm_state, alu_ctrl_t2.first_uop_valid);
    edff #(.T(logic[ALU_BYTE-1:0][7:0])) rdt_vs1_vm_t2_reg (.q(vs1_rdt_vm_t3), .d(vs1_rdt_vm_t2), .e(alu_t2_valid&alu_t2_ready), .clk(clk), .rst_n(rst_n));

    // Viota sum from vs2
    assign viota_src2_t2 = f_vmsum2src2(vs2_m_sum_t2, vs2_m_t2, alu_ctrl_t2.vd_eew);
    edff #(.T(logic[`VLEN/ALU_WIDTH-1:0][ALU_BYTE-1:0][7:0])) viota_src2_t2_reg (.q(viota_src2_t3), .d(viota_src2_t2), .e(alu_t2_valid&alu_t2_ready), .clk(clk), .rst_n(rst_n));
  end

  if (ALU_STAGE_NUM == 5'd3) begin
    assign rdt_vs2 = data_t4[0];
    assign rdt_vs1 = vs1_rdt_vm_t4;
    assign alu_ctrl = alu_ctrl_t4;
    assign alu_ctrl_valid = alu_t4_valid;
    assign alu_t4_ready = rdt_res_ready;
    assign viota_src2 = viota_src2_t4;

    // VM operation
    assign vs1_rdt_vm_t3 = f_mux_rdt_vm(vs1_t3, rdt_pre_dst, alu_ctrl_t3.uop_funct6, alu_ctrl_t3.vm_state, alu_ctrl_t3.first_uop_valid);
    edff #(.T(logic[ALU_BYTE-1:0][7:0])) rdt_vs1_vm_t3_reg (.q(vs1_rdt_vm_t4), .d(vs1_rdt_vm_t3), .e(alu_t3_valid&alu_t3_ready), .clk(clk), .rst_n(rst_n));

    // Viota sum from vs2
    assign viota_src2_t3 = f_vmsum2src2(vs2_m_sum_t3, vs2_m_t3, alu_ctrl_t3.vd_eew);
    edff #(.T(logic[`VLEN/ALU_WIDTH-1:0][ALU_BYTE-1:0][7:0])) viota_src2_t3_reg (.q(viota_src2_t4), .d(viota_src2_t3), .e(alu_t3_valid&alu_t3_ready), .clk(clk), .rst_n(rst_n));
  end

  if (ALU_STAGE_NUM == 5'd4) begin
    assign rdt_vs2 = data_t5[0];
    assign rdt_vs1 = vs1_rdt_vm_t5;
    assign alu_ctrl = alu_ctrl_t5;
    assign alu_ctrl_valid = alu_t5_valid;
    assign alu_t5_ready = rdt_res_ready;
    assign viota_src2 = viota_src2_t5;

    // VM operation
    assign vs1_rdt_vm_t4 = f_mux_rdt_vm(vs1_t4, rdt_pre_dst, alu_ctrl_t4.uop_funct6, alu_ctrl_t4.vm_state, alu_ctrl_t4.first_uop_valid);
    edff #(.T(logic[ALU_BYTE-1:0][7:0])) rdt_vs1_vm_t4_reg (.q(vs1_rdt_vm_t5), .d(vs1_rdt_vm_t4), .e(alu_t4_valid&alu_t4_ready), .clk(clk), .rst_n(rst_n));

    // Viota sum from vs2
    assign viota_src2_t4 = f_vmsum2src2(vs2_m_sum_t4, vs2_m_t4, alu_ctrl_t4.vd_eew);
    edff #(.T(logic[`VLEN/ALU_WIDTH-1:0][ALU_BYTE-1:0][7:0])) viota_src2_t4_reg (.q(viota_src2_t5), .d(viota_src2_t4), .e(alu_t4_valid&alu_t4_ready), .clk(clk), .rst_n(rst_n));
  end
 
endgenerate

  assign rdt_vs2_32b = rdt_vs2;
  assign rdt_vs1_32b = rdt_vs1;
  rvv_backend_pmtrdt_unit_reduction_alu #(
    .ALU_WIDTH (32)
  ) u_alu_dst_32b (
    .src1   (rdt_vs2_32b),
    .src2   (rdt_vs1_32b),
    .ctrl   (alu_ctrl),
    .dst    (dst_32b)
  );

`ifdef CORALNPU_STRUCTURAL_DATAPATH
  // 16-bit Fast Structural Reduction Tree: 3:2 CSA Compressor
  logic [15:0] csa16_sum, csa16_carry;
  logic [15:0] rdt_sum_tree_16b;
  logic [15:0] non_sum_dst_16b;

  compressor_3_2 #(.WIDTH(16)) u_csa16_stg1 (
    .src1        (rdt_vs2_32b[15:0]),
    .src2        (rdt_vs2_32b[31:16]),
    .src3        ({rdt_vs1[1], rdt_vs1[0]}),
    .result_sum  (csa16_sum),
    .result_carry(csa16_carry)
  );

  assign rdt_sum_tree_16b = csa16_sum + {csa16_carry[14:0], 1'b0};

  rvv_backend_pmtrdt_unit_reduction_alu #(
    .ALU_WIDTH (16)
  ) u_alu_16b (
    .src1   (rdt_vs2_32b[15:0]),
    .src2   (rdt_vs2_32b[31:16]),
    .ctrl   (alu_ctrl),
    .dst    (rdt_vs2_16b)
  );

  assign rdt_vs1_16b = rdt_vs1[1:0];
  rvv_backend_pmtrdt_unit_reduction_alu #(
    .ALU_WIDTH (16)
  ) u_alu_dst_16b (
    .src1   (rdt_vs2_16b),
    .src2   (rdt_vs1_16b),
    .ctrl   (alu_ctrl),
    .dst    (non_sum_dst_16b)
  );

  always_comb begin
    case (alu_ctrl.uop_funct6)
      VMUNARY0,
      VWRXUNARY0,
      VREDSUM,
      VWREDSUMU,
      VWREDSUM: dst_16b = rdt_sum_tree_16b;
      default:  dst_16b = non_sum_dst_16b;
    endcase
  end
`else
  rvv_backend_pmtrdt_unit_reduction_alu #(
    .ALU_WIDTH (16)
  ) u_alu_16b (
    .src1   (rdt_vs2_32b[15:0]),
    .src2   (rdt_vs2_32b[31:16]),
    .ctrl   (alu_ctrl),
    .dst    (rdt_vs2_16b)
  );

  assign rdt_vs1_16b = rdt_vs1[1:0];
  rvv_backend_pmtrdt_unit_reduction_alu #(
    .ALU_WIDTH (16)
  ) u_alu_dst_16b (
    .src1   (rdt_vs2_16b),
    .src2   (rdt_vs1_16b),
    .ctrl   (alu_ctrl),
    .dst    (dst_16b)
  );
`endif

`ifdef CORALNPU_STRUCTURAL_DATAPATH
  // ---------------------------------------------------------------------------
  // Structural Reduction Tree: Fast Carry-Save Tree + Parallel Merge
  // ---------------------------------------------------------------------------
  logic [7:0] rdt_sum_tree;
  logic [7:0] csa_sum1, csa_carry1;
  logic [7:0] csa_sum2, csa_carry2;
  logic [7:0] non_sum_dst_8b;

  // CSA stage 1: compress 3 terms (byte 0, byte 1, byte 2)
  compressor_3_2 #(.WIDTH(8)) u_csa8_stg1 (
    .src1        (rdt_vs2_32b[7:0]),
    .src2        (rdt_vs2_32b[15:8]),
    .src3        (rdt_vs2_32b[23:16]),
    .result_sum  (csa_sum1),
    .result_carry(csa_carry1)
  );

  // CSA stage 2: compress (sum1, carry1<<1, byte 3, vs1)
  compressor_tree_4to2 #(.WIDTH(8)) u_csa8_stg2 (
    .src         ({rdt_vs1[0], rdt_vs2_32b[31:24], {csa_carry1[6:0], 1'b0}, csa_sum1}),
    .result_sum  (csa_sum2),
    .result_carry(csa_carry2)
  );

  assign rdt_sum_tree = csa_sum2 + {csa_carry2[6:0], 1'b0};

  // Dedicated parallel min/max tree & logical tree
  rvv_backend_pmtrdt_unit_reduction_alu #(
    .ALU_WIDTH (8)
  ) u_alu_8b_0 (
    .src1   (rdt_vs2_32b[7:0]),
    .src2   (rdt_vs2_32b[15:8]),
    .ctrl   (alu_ctrl),
    .dst    (rdt_src2_8b)
  );

  rvv_backend_pmtrdt_unit_reduction_alu #(
    .ALU_WIDTH (8)
  ) u_alu_8b_1 (
    .src1   (rdt_vs2_32b[23:16]),
    .src2   (rdt_vs2_32b[31:24]),
    .ctrl   (alu_ctrl),
    .dst    (rdt_src1_8b)
  );

  rvv_backend_pmtrdt_unit_reduction_alu #(
    .ALU_WIDTH (8)
  ) u_alu_8b_2 (
    .src1   (rdt_src2_8b),
    .src2   (rdt_src1_8b),
    .ctrl   (alu_ctrl),
    .dst    (rdt_vs2_8b)
  );

  assign rdt_vs1_8b = rdt_vs1[0];
  rvv_backend_pmtrdt_unit_reduction_alu #(
    .ALU_WIDTH (8)
  ) u_alu_dst_8b (
    .src1   (rdt_vs2_8b),
    .src2   (rdt_vs1_8b),
    .ctrl   (alu_ctrl),
    .dst    (non_sum_dst_8b)
  );

  always_comb begin
    case (alu_ctrl.uop_funct6)
      VMUNARY0,
      VWRXUNARY0,
      VREDSUM,
      VWREDSUMU,
      VWREDSUM: dst_8b = rdt_sum_tree;
      default:  dst_8b = non_sum_dst_8b;
    endcase
  end

`else
  // ---------------------------------------------------------------------------
  // Default Behavioral Reference Flow
  // ---------------------------------------------------------------------------
  rvv_backend_pmtrdt_unit_reduction_alu #(
    .ALU_WIDTH (8)
  ) u_alu_8b_0 (
    .src1   (rdt_vs2_32b[7:0]),
    .src2   (rdt_vs2_32b[15:8]),
    .ctrl   (alu_ctrl),
    .dst    (rdt_src2_8b)
  );

  rvv_backend_pmtrdt_unit_reduction_alu #(
    .ALU_WIDTH (8)
  ) u_alu_8b_1 (
    .src1   (rdt_vs2_32b[23:16]),
    .src2   (rdt_vs2_32b[31:24]),
    .ctrl   (alu_ctrl),
    .dst    (rdt_src1_8b)
  );

  rvv_backend_pmtrdt_unit_reduction_alu #(
    .ALU_WIDTH (8)
  ) u_alu_8b_2 (
    .src1   (rdt_src2_8b),
    .src2   (rdt_src1_8b),
    .ctrl   (alu_ctrl),
    .dst    (rdt_vs2_8b)
  );

  assign rdt_vs1_8b = rdt_vs1[0];
  rvv_backend_pmtrdt_unit_reduction_alu #(
    .ALU_WIDTH (8)
  ) u_alu_dst_8b (
    .src1   (rdt_vs2_8b),
    .src2   (rdt_vs1_8b),
    .ctrl   (alu_ctrl),
    .dst    (dst_8b)
  );
`endif

  //rdt_dst data
  always_comb begin
    case (alu_ctrl.vd_eew)
      EEW32: rdt_dst = {{(ALU_WIDTH-32){1'b0}},dst_32b};
      EEW16: rdt_dst = {{(ALU_WIDTH-16){1'b0}},dst_16b};
      default: rdt_dst = {{(ALU_WIDTH-8){1'b0}},dst_8b};
    endcase
  end

  //rdt_pre_dst data
  always_comb begin
    case (alu_ctrl.uop_funct6)
      VREDMAXU,
      VREDMAX,
      VREDMINU,
      VREDMIN:
        case (alu_ctrl.vd_eew)
          EEW32: rdt_pre_dst = {(ALU_WIDTH/32){dst_32b}};
          EEW16: rdt_pre_dst = {(ALU_WIDTH/16){dst_16b}};
          default: rdt_pre_dst = {(ALU_WIDTH/8){dst_8b}};
        endcase
      VREDAND:
        case (alu_ctrl.vd_eew)
          EEW32: rdt_pre_dst = {{(ALU_WIDTH-32){1'b1}},dst_32b};
          EEW16: rdt_pre_dst = {{(ALU_WIDTH-16){1'b1}},dst_16b};
          default: rdt_pre_dst = {{(ALU_WIDTH-8){1'b1}},dst_8b};
        endcase
      //VMUNARY0,VWRXUNARY0,
      //VWREDSUMU,VWREDSUM,VREDSUM,
      //VREDOR,VREDXOR
      default:
        case (alu_ctrl.vd_eew)
          EEW32: rdt_pre_dst = {{(ALU_WIDTH-32){1'b0}},dst_32b};
          EEW16: rdt_pre_dst = {{(ALU_WIDTH-16){1'b0}},dst_16b};
          default: rdt_pre_dst = {{(ALU_WIDTH-8){1'b0}},dst_8b};
        endcase
    endcase
  end

  // viota_dst
  assign viota_src1 = f_rdtsum2src1(rdt_vs1, alu_ctrl.vd_eew);
  assign viota_cin  = f_cout2cin(viota_cout, alu_ctrl.vd_eew);
  generate
    for (i=0; i<`VLEN/ALU_WIDTH; i++) begin : gen_viota_res
      adder #(.ADD_NUM(ALU_BYTE), .ADD_WIDTH(8)) u_adder (.a(viota_src1), .b(viota_src2[i]), .cin(viota_cin[i]), .sum(viota_dst[i]), .cout(viota_cout[i]));
    end
  endgenerate

  //rdt_res
  always_comb begin
  `ifdef TB_SUPPORT
    rdt_res.uop_pc = alu_ctrl.uop_pc;
  `endif
    rdt_res.rob_entry = alu_ctrl.rob_entry;
    case (alu_ctrl.uop_funct6)
      VMUNARY0: rdt_res.w_data = viota_dst;
      default: rdt_res.w_data = {{(`VLEN-ALU_WIDTH){1'b0}}, rdt_dst};
    endcase
    rdt_res.w_valid = rdt_res_valid;
    rdt_res.vsaturate = '0;
  `ifdef ZVE32F_ON
    rdt_res.fpexp = '0;
  `endif
  end

  // rdt_uop_ready
  always_comb begin
    case (rdt_uop.uop_funct6)
      VWRXUNARY0:rdt_uop_ready = vm_last_opr & alu_t0_ready;
      VWREDSUMU,
      VWREDSUM:rdt_uop_ready = wsum_h & alu_t0_ready;
      default: rdt_uop_ready = alu_t0_ready; // VMUNARY0
    endcase
  end

  // rdt_res_valid
  always_comb begin
    case (alu_ctrl.uop_funct6)
      VMUNARY0: rdt_res_valid = alu_ctrl_valid;
      default:rdt_res_valid = alu_ctrl.last_uop_valid & alu_ctrl_valid;
    endcase
  end

// ---function--------------------------------------------------------
  function [ALU_BYTE-1:0][7:0] f_mux_rdt_vm;
    input [ALU_BYTE-1:0][7:0] vs1_rdt;    // vs1[0] data for Vector reduction instruction
    input [ALU_BYTE-1:0][7:0] pre_res;    // previous result
    input FUNCT6_u funct6;   // control information
    input VM_STATE_e vm_state;   // control information
    input            first_uop_valid;

    case (funct6)
      VMUNARY0,
      VWRXUNARY0:
        case (vm_state)
          MSK0: f_mux_rdt_vm = '0;
          default: f_mux_rdt_vm = pre_res; // MSKN
        endcase
      //VREDSUM, VWREDSUMU, VWREDSUM, VREDMAXU, VREDMAX,
      //VREDMINU, VREDMIN, VREDAND, VREDOR, VREDXOR
      default: 
        if (first_uop_valid)
          f_mux_rdt_vm = vs1_rdt;
        else
          f_mux_rdt_vm = pre_res;
    endcase
  endfunction

  function [ALU_BYTE-1:0][7:0] f_rdtsum2src1;
    input [ALU_BYTE-1:0][7:0] sum;
    input EEW_e eew;

    case (eew)
      EEW32: f_rdtsum2src1 = {(ALU_BYTE/4){sum[3:0]}};
      EEW16: f_rdtsum2src1 = {(ALU_BYTE/2){sum[1:0]}};
      default: f_rdtsum2src1 = {(ALU_BYTE){sum[0]}}; //EEW8
    endcase
  endfunction
  
  function automatic [`VLEN/ALU_WIDTH-1:0][ALU_BYTE-1:0][7:0] f_vmsum2src2;
    input [M_SUM_NUM-1:0][`VSTART_WIDTH-1:0]  vs2_m_sum;
    input [`VLENB-1:0]  vs2_m;
    input EEW_e eew;

    localparam MIN_ = (10'(`VSTART_WIDTH) < 10'd8) ? 8-`VSTART_WIDTH : 0;
    localparam MAX_ = (10'(`VSTART_WIDTH) < 10'd8) ? `VSTART_WIDTH : 8;
    logic [`VLENB-1:0][`VSTART_WIDTH-1:0] vs2_m_src2;  
    logic [`VLEN/ALU_WIDTH-1:0][ALU_BYTE/4-1:0][31:0] vs2_m_src2_32b;
    logic [`VLEN/ALU_WIDTH-1:0][ALU_BYTE/2-1:0][15:0] vs2_m_src2_16b;
    logic [`VLEN/ALU_WIDTH-1:0][ALU_BYTE-1:0][7:0]    vs2_m_src2_8b;
    begin
      for (int i= 0; i<M_SUM_NUM; i++) begin 
          vs2_m_src2[i*VIOTA_STRIDE] = vs2_m_sum[i]; 
        for (int j=1; j<VIOTA_STRIDE; j++) begin
          vs2_m_src2[i*VIOTA_STRIDE+j] = vs2_m_src2[i*VIOTA_STRIDE+j-1] + vs2_m[i*VIOTA_STRIDE+j-1]; 
        end
      end

      for (int i= 0; i<`VLEN/ALU_WIDTH; i++)
        for (int j=0; j<ALU_BYTE/4; j++)
          vs2_m_src2_32b[i][j] = {{(32-`VSTART_WIDTH){1'b0}}, {vs2_m_src2[i*ALU_BYTE/4+j][`VSTART_WIDTH-1:0]}};

      for (int i= 0; i<`VLEN/ALU_WIDTH; i++)
        for (int j=0; j<ALU_BYTE/2; j++)
          vs2_m_src2_16b[i][j] = {{(16-`VSTART_WIDTH){1'b0}}, {vs2_m_src2[i*ALU_BYTE/2+j][`VSTART_WIDTH-1:0]}};

      for (int i= 0; i<`VLEN/ALU_WIDTH; i++)
        for (int j=0; j<ALU_BYTE; j++)
          vs2_m_src2_8b[i][j] = {{(MIN_){1'b0}}, {vs2_m_src2[i*ALU_BYTE+j][MAX_-1:0]}};

      case (eew)
        EEW32: f_vmsum2src2 = vs2_m_src2_32b;
        EEW16: f_vmsum2src2 = vs2_m_src2_16b;
        default: f_vmsum2src2 = vs2_m_src2_8b; //EEW8
      endcase
    end
  endfunction

  function [`VLEN/ALU_WIDTH-1:0][ALU_BYTE-1:0] f_cout2cin;
    input [`VLEN/ALU_WIDTH-1:0][ALU_BYTE-1:0] cout;
    input EEW_e eew;

    for (int i=0; i<`VLEN/ALU_WIDTH; i++) begin
      f_cout2cin[i][0] = 1'b0;
      case (eew)
        EEW32: for (int j=1; j<ALU_BYTE; j++) f_cout2cin[i][j] = j%4==0 ? 1'b0 : cout[i][j-1];
        EEW16: for (int j=1; j<ALU_BYTE; j++) f_cout2cin[i][j] = j%2==0 ? 1'b0 : cout[i][j-1];
        default: for (int j=1; j<ALU_BYTE; j++) f_cout2cin[i][j] = 1'b0; //EEW8
      endcase
    end
  endfunction

endmodule
