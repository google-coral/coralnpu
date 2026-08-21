// description:
// 1. Dispatch unit receives uop instructions from uop queue
// 2. Dispatch unit check rules to determine if the uops are sent to reservation stations(RS). 
//    There are two ways to solve: 
//     a. stall pipeline
//     b. foreward data from ROB
// 3. Dispatch unit read vector data from VRF for uops.

`ifndef HDL_VERILOG_RVV_DESIGN_RVV_SVH
`include "rvv_backend.svh"
`endif
`ifndef RVV_DISPATCH__SVH
`include "rvv_backend_dispatch.svh"
`endif

module rvv_backend_dispatch
(
    clk,
    rst_n,
    uop_valid_uop2dp,
    uop_uop2dp,
    uop_ready_dp2uop,
    rs_valid_dp2alu,
    rs_dp2alu,
    rs_ready_alu2dp,
    rs_valid_dp2pmtrdt,
    rs_dp2pmtrdt,
    rs_ready_pmtrdt2dp,
    rs_valid_dp2mul,
    rs_dp2mul,
    rs_ready_mul2dp,
    rs_valid_dp2div,
    rs_dp2div,
    rs_ready_div2dp,
`ifdef ZVE32F_ON
    rs_valid_dp2falu,
    rs_dp2falu,
    rs_ready_falu2dp,
`endif
`ifdef ZVT_ON
    rs_valid_dp2zvt,
    rs_dp2zvt,
    rs_ready_zvt2dp,
`endif
    rs_valid_dp2lsu,
    rs_dp2lsu,
    rs_ready_lsu2dp,
    mapinfo_valid_dp2lsu,
    mapinfo_dp2lsu,
    mapinfo_ready_lsu2dp,
    uop_valid_dp2rob,
    uop_dp2rob,
    uop_ready_rob2dp,
    rob_entry_rob2dp,
    rd_index_dp2vrf,        
    rd_data_vrf2dp,
    v0_mask_vrf2dp,
    rob_entry
);  
// ---port definition-------------------------------------------------
// global signal
    input  logic           clk;
    input  logic           rst_n;

// Uops Queue to Dispatch unit
    input  logic        [`NUM_DP_UOP-1:0]         uop_valid_uop2dp;
    input  UOP_QUEUE_t  [`NUM_DP_UOP-1:0]         uop_uop2dp;
    output logic        [`NUM_DP_UOP-1:0]         uop_ready_dp2uop;

// Dispatch unit sends oprations to reservation stations
// Dispatch unit to ALU reservation station
// rs_*: reservation station
    output logic          [`NUM_DP_UOP-1:0]       rs_valid_dp2alu;
    output ALU_RS_t       [`NUM_DP_UOP-1:0]       rs_dp2alu;
    input  logic          [`NUM_DP_UOP-1:0]       rs_ready_alu2dp;

// Dispatch unit to PMT+RDT reservation station
    output logic          [`NUM_DP_UOP-1:0]       rs_valid_dp2pmtrdt;
    output PMT_RDT_RS_t   [`NUM_DP_UOP-1:0]       rs_dp2pmtrdt;
    input  logic          [`NUM_DP_UOP-1:0]       rs_ready_pmtrdt2dp;

// Dispatch unit to MUL reservation station
    output logic          [`NUM_DP_UOP-1:0]       rs_valid_dp2mul;
    output MUL_RS_t       [`NUM_DP_UOP-1:0]       rs_dp2mul;
    input  logic          [`NUM_DP_UOP-1:0]       rs_ready_mul2dp;

// Dispatch unit to DIV reservation station
    output logic          [`NUM_DP_UOP-1:0]       rs_valid_dp2div;
    output DIV_RS_t       [`NUM_DP_UOP-1:0]       rs_dp2div;
    input  logic          [`NUM_DP_UOP-1:0]       rs_ready_div2dp;

`ifdef ZVE32F_ON
// Dispatch unit to FALU reservation station
    output logic          [`NUM_DP_UOP-1:0]       rs_valid_dp2falu;
    output FALU_RS_t      [`NUM_DP_UOP-1:0]       rs_dp2falu;
    input  logic          [`NUM_DP_UOP-1:0]       rs_ready_falu2dp;
`endif

`ifdef ZVT_ON
// Dispatch unit to VME reservation station
    output logic          [`NUM_DP_UOP-1:0]       rs_valid_dp2zvt;
    output ZVT_RS_t       [`NUM_DP_UOP-1:0]       rs_dp2zvt;
    input  logic          [`NUM_DP_UOP-1:0]       rs_ready_zvt2dp;
`endif

// Dispatch unit to LSU 
    // to LSU RS
    output logic          [`NUM_DP_UOP-1:0]       rs_valid_dp2lsu;
    output UOP_RVV2LSU_t  [`NUM_DP_UOP-1:0]       rs_dp2lsu;
    input  logic          [`NUM_DP_UOP-1:0]       rs_ready_lsu2dp;
    // to LSU MAP INFO
    output logic          [`NUM_DP_UOP-1:0]       mapinfo_valid_dp2lsu;
    output LSU_MAP_INFO_t [`NUM_DP_UOP-1:0]       mapinfo_dp2lsu;
    input  logic          [`NUM_DP_UOP-1:0]       mapinfo_ready_lsu2dp;

// Dispatch unit pushes operations to ROB unit    
    output logic          [`NUM_DP_UOP-1:0]       uop_valid_dp2rob;
    output DP2ROB_t       [`NUM_DP_UOP-1:0]       uop_dp2rob;
    input  logic          [`NUM_DP_UOP-1:0]       uop_ready_rob2dp;
    input  logic          [`ROB_DEPTH_WIDTH-1:0]  rob_entry_rob2dp;

// Dispatch unit sends read request to VRF for vector data.
// Dispatch unit to VRF unit
// rd_data would be return from VRF at the current cycle.
    output logic [`NUM_DP_VRF-1:0][`REGIDX_WIDTH-1:0] rd_index_dp2vrf;          
    input  logic [`NUM_DP_VRF-1:0][`VLEN-1:0]         rd_data_vrf2dp;
    input  logic [`VLEN-1:0]                          v0_mask_vrf2dp;

// Dispatch unit accept all ROB entry to determine if vs_data of RS is from ROB or not
// ROB unit to Dispatch unit
    input  ROB2DP_t     [`ROB_DEPTH-1:0]          rob_entry;

// ---internal signal definition--------------------------------------
    SUC_UOP_RAW_t       [`NUM_DP_UOP-1:0]   suc_uop;
    PRE_UOP_RAW_t       [`ROB_DEPTH-1:0]    pre_uop_rob;
    PRE_UOP_RAW_t       [`NUM_DP_UOP-2:0]   pre_uop_uop;
    RAW_UOP_ROB_t       [`NUM_DP_UOP-1:0]   raw_uop_rob; 
    // uop0 is the first uop so no need raw check between uops for it
    RAW_UOP_UOP_t       [`NUM_DP_UOP-1:1]   raw_uop_uop; 

    STRCT_UOP_t         [`NUM_DP_UOP-1:0]   strct_uop;
    ARCH_HAZARD_t                           arch_hazard;

    UOP_OPN_t           [`NUM_DP_UOP-1:0]   uop_operand;
    UOP_OPN_t           [`NUM_DP_UOP-1:0]   vrf_byp;
    ROB_BYP_t           [`ROB_DEPTH-1:0]    rob_byp;

    UOP_CTRL_t          [`NUM_DP_UOP-1:0]   uop_ctrl;

    UOP_INFO_t          [`NUM_DP_UOP-1:0]   uop_info;
    UOP_OPN_BYTE_TYPE_t [`NUM_DP_UOP-1:0]   uop_operand_byte_type;

    logic [`NUM_DP_UOP-1:0][2:0]                    lmul;
    logic [`NUM_DP_UOP-1:0][`VL_WIDTH-1:0]          vlmax;
    logic [`NUM_DP_UOP-1:0][$clog2(`VL_WIDTH)-1:0]  vlmax_shift;

    logic [`NUM_DP_UOP-1:0][`ROB_DEPTH_WIDTH-1:0]   rob_address;

// ---code start------------------------------------------------------
    genvar i;

    // vlmax = lmul * `VLENB / sew 
    generate
      for (i=0; i<`NUM_DP_UOP; i++) begin : gen_vlmax
        assign lmul[i] = uop_uop2dp[i].uop_exe_unit==VEU_PMT ? uop_uop2dp[i].vector_csr.lmul_orig : uop_uop2dp[i].vector_csr.lmul;
        assign vlmax_shift[i] = ($clog2(`VL_WIDTH))'(lmul[i][1:0]) 
                                + $clog2(`VLENB) 
                                - ($clog2(`VL_WIDTH))'(uop_uop2dp[i].vector_csr.sew) 
                                - {{($clog2(`VL_WIDTH)-3){1'b0}}, lmul[i][2],2'b0};
        assign vlmax[i] = (`VL_WIDTH)'(1) << vlmax_shift[i];
      end
    endgenerate

    generate
        for (i=0; i<`NUM_DP_UOP; i++) begin : gen_suc_uop
            assign suc_uop[i].vs1_index = uop_uop2dp[i].vs1;
            assign suc_uop[i].vs1_valid = uop_uop2dp[i].vs1_valid;
            assign suc_uop[i].vs2_index = uop_uop2dp[i].vs2_index;
            assign suc_uop[i].vs2_valid = uop_uop2dp[i].vs2_valid;
            assign suc_uop[i].vd_index  = uop_uop2dp[i].dst_index;
            assign suc_uop[i].vs3_valid = uop_uop2dp[i].vs3_valid;
            assign suc_uop[i].vm        = uop_uop2dp[i].vm;
        end
    endgenerate
// RAW data hazard check between uop[*] and ROB
    generate
        for (i=0; i<`ROB_DEPTH; i++) begin : gen_pre_uop_rob
            assign pre_uop_rob[i].w_index = rob_entry[i].w_index;
            assign pre_uop_rob[i].w_type  = rob_entry[i].w_type;
            assign pre_uop_rob[i].w_valid = rob_entry[i].w_valid;
            assign pre_uop_rob[i].valid   = rob_entry[i].valid;
        end
        for (i=0; i<`NUM_DP_UOP; i++) begin : gen_raw_uop_rob
            rvv_backend_dispatch_raw_uop_rob #(
            ) u_raw_uop_rob (
                .raw_uop_rob  (raw_uop_rob[i]),
                .suc_uop      (suc_uop[i]),
                .pre_uop      (pre_uop_rob)
            );
        end
    endgenerate

// RAW data hazard check between uop(s)
    generate
        for (i=0; i<`NUM_DP_UOP-1; i++) begin : gen_pre_uop_uop
            assign pre_uop_uop[i].w_index = uop_uop2dp[i].dst_index;
            assign pre_uop_uop[i].w_valid = 1'b0;
            assign pre_uop_uop[i].w_type  = uop_uop2dp[i].vd_valid ? VRF : XRF;
            assign pre_uop_uop[i].valid   = uop_uop2dp[i].vd_valid & uop_valid_uop2dp[i];
        end
        for (i=1; i<`NUM_DP_UOP; i++) begin : gen_raw_uop_uop
            rvv_backend_dispatch_raw_uop_uop #(
                .PREUOP_NUM (i)
            ) u_raw_uop_uop (
                .raw_uop_uop  (raw_uop_uop[i]),
                .suc_uop      (suc_uop[i]),
                .pre_uop      (pre_uop_uop[i-1:0])
            );
        end
    endgenerate

// Structure hazard check and set read index for VRF
    generate
        for (i=0; i<`NUM_DP_UOP; i++) begin : gen_strct_uop
            assign strct_uop[i].vs1_index = uop_uop2dp[i].vs1;
            assign strct_uop[i].vs1_valid = uop_uop2dp[i].vs1_valid;
            assign strct_uop[i].vs2_index = uop_uop2dp[i].vs2_index;
            assign strct_uop[i].vs2_valid = uop_uop2dp[i].vs2_valid;
            assign strct_uop[i].vd_index  = uop_uop2dp[i].dst_index;
            assign strct_uop[i].vs3_valid = uop_uop2dp[i].vs3_valid;
            assign strct_uop[i].uop_exe_unit = uop_uop2dp[i].uop_exe_unit;
            assign strct_uop[i].uop_class = uop_uop2dp[i].uop_class;
        end
    endgenerate

    rvv_backend_dispatch_structure_hazard #(
    ) u_structure_hazard (
        .rd_index     (rd_index_dp2vrf),
        .arch_hazard  (arch_hazard),
        .strct_uop    (strct_uop)
    );

// Bypass data for source operand of uop(s)
    generate
      for (i=0; i<`ROB_DEPTH; i++) begin : gen_rob_byp
        assign rob_byp[i].w_data    = rob_entry[i].w_data;
        assign rob_byp[i].byte_type = rob_entry[i].byte_type;

        `ifdef AGNOSTIC_ONE
          assign rob_byp[i].tail_one  = rob_entry[i].vector_csr.vtype.vta;
          assign rob_byp[i].inactive_one = rob_entry[i].vector_csr.vtype.vma;
        `else
          assign rob_byp[i].tail_one  = 1'b0;
          assign rob_byp[i].inactive_one = 1'b0;
        `endif
      end

      rvv_backend_dispatch_operand
      u_operand
      (
        .vrf_byp        (vrf_byp       ),
        .uop_uop2dp     (uop_uop2dp    ),
        .rd_data_vrf2dp (rd_data_vrf2dp),
        .v0_mask_vrf2dp (v0_mask_vrf2dp)
      );

      for (i=0;i<`NUM_DP_UOP;i++) begin: gen_bypass_data
        rvv_backend_dispatch_bypass 
        #(
        ) 
        u_bypass (
          .uop_operand  (uop_operand[i]),
          .rob_byp      (rob_byp),
          .vrf_byp      (vrf_byp[i]),
          .raw_uop_rob  (raw_uop_rob[i])
        );
      end
    endgenerate

// Control handshae mechanism for uop_queue <-> dispath, dispatch <-> rs and dispatch <-> rob
    generate
        for (i=0; i<`NUM_DP_UOP; i++) begin : gen_uop_ctrl
            assign uop_ctrl[i].uop_exe_unit = uop_uop2dp[i].uop_exe_unit;
            assign uop_ctrl[i].pshrob_valid = uop_uop2dp[i].pshrob_valid;
            assign uop_ctrl[i].pshlsu_valid = uop_uop2dp[i].pshlsu_valid;
        end
    endgenerate

    rvv_backend_dispatch_ctrl #(
    ) u_ctrl (
      // ctrl input signal
        .raw_uop_rob            (raw_uop_rob),
        .raw_uop_uop            (raw_uop_uop),
        .arch_hazard            (arch_hazard),
        .uop_ctrl               (uop_ctrl),
      // handshake signals
        .uop_valid_uop2dp       (uop_valid_uop2dp),
        .uop_ready_dp2uop       (uop_ready_dp2uop),
        .rs_valid_dp2alu        (rs_valid_dp2alu),
        .rs_ready_alu2dp        (rs_ready_alu2dp),
        .rs_valid_dp2pmtrdt     (rs_valid_dp2pmtrdt),
        .rs_ready_pmtrdt2dp     (rs_ready_pmtrdt2dp),
        .rs_valid_dp2mul        (rs_valid_dp2mul),
        .rs_ready_mul2dp        (rs_ready_mul2dp),
        .rs_valid_dp2div        (rs_valid_dp2div),
        .rs_ready_div2dp        (rs_ready_div2dp),
      `ifdef ZVE32F_ON
        .rs_valid_dp2falu       (rs_valid_dp2falu),
        .rs_ready_falu2dp       (rs_ready_falu2dp),
      `endif
      `ifdef ZVT_ON
        .rs_valid_dp2zvt        (rs_valid_dp2zvt),
        .rs_ready_zvt2dp        (rs_ready_zvt2dp),
      `endif
        .rs_valid_dp2lsu        (rs_valid_dp2lsu),
        .rs_ready_lsu2dp        (rs_ready_lsu2dp),
        .mapinfo_valid_dp2lsu   (mapinfo_valid_dp2lsu),
        .mapinfo_ready_lsu2dp   (mapinfo_ready_lsu2dp),
        .uop_valid_dp2rob       (uop_valid_dp2rob),
        .uop_ready_rob2dp       (uop_ready_rob2dp)
    );

// determine the type for each byte in uop's vector operands 
    generate
        for (i=0; i<`NUM_DP_UOP; i++) begin : gen_opr_bype_type
            assign uop_info[i].uop_index  = (uop_uop2dp[i].uop_exe_unit==LSU)&(uop_uop2dp[i].uop_funct6.lsu_funct6.lsu_is_seg==IS_SEGMENT)? 
                                            uop_uop2dp[i].seg_field_index : uop_uop2dp[i].uop_index[$clog2(`EMUL_MAX)-1:0];
            assign uop_info[i].uop_exe_unit = uop_uop2dp[i].uop_exe_unit;
            assign uop_info[i].vd_eew     = uop_uop2dp[i].vd_eew;
            assign uop_info[i].vs1_eew    = uop_uop2dp[i].vs1_eew;
            assign uop_info[i].vs2_eew    = uop_uop2dp[i].vs2_eew;
            assign uop_info[i].vstart     = uop_uop2dp[i].vector_csr.vstart;
            assign uop_info[i].vl         = uop_uop2dp[i].vs_evl;
            assign uop_info[i].vm         = uop_uop2dp[i].vm;
            assign uop_info[i].ignore_vma = uop_uop2dp[i].ignore_vma;
            assign uop_info[i].ignore_vta = uop_uop2dp[i].ignore_vta;

            rvv_backend_dispatch_opr_byte_type #(
            ) u_opr_byte_type (
                .operand_byte_type (uop_operand_byte_type[i]),
                .uop_info          (uop_info[i]),
                .v0_data           (uop_operand[i].v0)
            );
        end
    endgenerate

// output signals for RS+ROB
    generate
        for (i=0; i<`NUM_DP_UOP; i++) begin : gen_output_sig
          // rob_address
            if (i==0) begin : gen_rob_address_0
              assign rob_address[0] = rob_entry_rob2dp;
            end else begin : gen_rob_address_i
              assign rob_address[i] = rob_address[i-1] + (`ROB_DEPTH_WIDTH)'(uop_uop2dp[i-1].pshrob_valid);
            end

          // ALU RS
          `ifdef TB_SUPPORT
            assign rs_dp2alu[i].uop_pc          = uop_uop2dp[i].uop_pc; 
          `endif
            assign rs_dp2alu[i].rob_entry       = rob_address[i]; 
            assign rs_dp2alu[i].uop_funct6      = uop_uop2dp[i].uop_funct6;
            assign rs_dp2alu[i].uop_funct3      = uop_uop2dp[i].uop_funct3;
            assign rs_dp2alu[i].is_cmp          = uop_uop2dp[i].uop_exe_unit==VEU_CMP; 
            assign rs_dp2alu[i].vstart          = uop_uop2dp[i].vector_csr.vstart;
            assign rs_dp2alu[i].vl              = uop_uop2dp[i].vs_evl;
            assign rs_dp2alu[i].vm              = uop_uop2dp[i].vm;
            assign rs_dp2alu[i].vxrm            = uop_uop2dp[i].vector_csr.xrm;
            assign rs_dp2alu[i].v0_data         = uop_operand[i].v0;
            assign rs_dp2alu[i].v0_data_valid   = uop_uop2dp[i].v0_valid;
            assign rs_dp2alu[i].vd_data         = uop_operand[i].vd;
            assign rs_dp2alu[i].vd_data_valid   = uop_uop2dp[i].vs3_valid;
            assign rs_dp2alu[i].vd_eew          = uop_uop2dp[i].vd_eew;
            assign rs_dp2alu[i].vs1             = uop_uop2dp[i].vs1;
            assign rs_dp2alu[i].vs1_data        = uop_uop2dp[i].vs1_valid ? uop_operand[i].vs1 : (`VLEN)'(uop_uop2dp[i].rs1_data);
            assign rs_dp2alu[i].vs1_data_valid  = uop_uop2dp[i].vs1_valid;
            assign rs_dp2alu[i].rs1_data_valid  = uop_uop2dp[i].rs1_data_valid;
            assign rs_dp2alu[i].vs2_data        = uop_operand[i].vs2;
            assign rs_dp2alu[i].vs2_data_valid  = uop_uop2dp[i].vs2_valid;
            assign rs_dp2alu[i].vs2_eew         = uop_uop2dp[i].vs2_eew;
            assign rs_dp2alu[i].first_uop_valid = uop_uop2dp[i].first_uop_valid;
            assign rs_dp2alu[i].last_uop_valid  = uop_uop2dp[i].last_uop_valid;
            assign rs_dp2alu[i].uop_index       = uop_uop2dp[i].uop_index[$clog2(`EMUL_MAX)-1:0];

          // PMTRDT RS
          `ifdef TB_SUPPORT
            assign rs_dp2pmtrdt[i].uop_pc          = uop_uop2dp[i].uop_pc; 
          `endif
            assign rs_dp2pmtrdt[i].rob_entry       = rob_address[i]; 
            assign rs_dp2pmtrdt[i].uop_exe_unit    = uop_uop2dp[i].uop_exe_unit; 
            assign rs_dp2pmtrdt[i].uop_funct6      = uop_uop2dp[i].uop_funct6;
            assign rs_dp2pmtrdt[i].uop_funct3      = uop_uop2dp[i].uop_funct3;
            assign rs_dp2pmtrdt[i].vl              = uop_uop2dp[i].vs_evl;
            assign rs_dp2pmtrdt[i].vm              = uop_uop2dp[i].vm;
            assign rs_dp2pmtrdt[i].vlmax           = vlmax[i];
            assign rs_dp2pmtrdt[i].v0_data         = uop_operand[i].v0;
            assign rs_dp2pmtrdt[i].vs1_data        = uop_operand[i].vs1;
            assign rs_dp2pmtrdt[i].vs1_eew         = uop_uop2dp[i].vs1_eew;
            assign rs_dp2pmtrdt[i].vs1_data_valid  = uop_uop2dp[i].vs1_valid;
            assign rs_dp2pmtrdt[i].vs2_index       = uop_uop2dp[i].vs2_index;
            assign rs_dp2pmtrdt[i].vs2_data        = uop_operand[i].vs2;
            assign rs_dp2pmtrdt[i].vs2_eew         = uop_uop2dp[i].vs2_eew;
            assign rs_dp2pmtrdt[i].vs2_type        = uop_operand_byte_type[i].vs2;
            assign rs_dp2pmtrdt[i].vd_eew          = uop_uop2dp[i].vd_eew;
            assign rs_dp2pmtrdt[i].dst_index       = uop_uop2dp[i].dst_index;
            assign rs_dp2pmtrdt[i].rs1_data        = uop_uop2dp[i].rs1_data;
            assign rs_dp2pmtrdt[i].first_uop_valid = uop_uop2dp[i].first_uop_valid;
            assign rs_dp2pmtrdt[i].last_uop_valid  = uop_uop2dp[i].last_uop_valid;
            assign rs_dp2pmtrdt[i].uop_index       = uop_uop2dp[i].uop_index[$clog2(`EMUL_MAX)-1:0];
          `ifdef ZVE32F_ON
            assign rs_dp2pmtrdt[i].frm             = uop_uop2dp[i].vector_csr.frm;
          `endif
            
          // MUL/MAC RS
          `ifdef TB_SUPPORT
            assign rs_dp2mul[i].uop_pc          = uop_uop2dp[i].uop_pc; 
          `endif
            assign rs_dp2mul[i].rob_entry       = rob_address[i]; 
            assign rs_dp2mul[i].uop_funct6      = uop_uop2dp[i].uop_funct6;
            assign rs_dp2mul[i].uop_funct3      = uop_uop2dp[i].uop_funct3;
            assign rs_dp2mul[i].vxrm            = uop_uop2dp[i].vector_csr.xrm;
            assign rs_dp2mul[i].vs1_data        = uop_uop2dp[i].vs1_valid ? uop_operand[i].vs1 : (`VLEN)'(uop_uop2dp[i].rs1_data);
            assign rs_dp2mul[i].vs1_data_valid  = uop_uop2dp[i].vs1_valid;
            assign rs_dp2mul[i].rs1_data_valid  = uop_uop2dp[i].rs1_data_valid;
            assign rs_dp2mul[i].vs2_data        = uop_operand[i].vs2;
            assign rs_dp2mul[i].vs2_data_valid  = uop_uop2dp[i].vs2_valid;
            assign rs_dp2mul[i].vs2_eew         = uop_uop2dp[i].vs2_eew;
            assign rs_dp2mul[i].vs3_data        = uop_operand[i].vd;
            assign rs_dp2mul[i].vs3_data_valid  = uop_uop2dp[i].vs3_valid;
            assign rs_dp2mul[i].uop_index       = uop_uop2dp[i].uop_index[0];

          // DIV RS
          `ifdef TB_SUPPORT
            assign rs_dp2div[i].uop_pc          = uop_uop2dp[i].uop_pc; 
          `endif
            assign rs_dp2div[i].rob_entry       = rob_address[i]; 
            assign rs_dp2div[i].uop_funct6      = uop_uop2dp[i].uop_funct6;
            assign rs_dp2div[i].uop_funct3      = uop_uop2dp[i].uop_funct3;
            assign rs_dp2div[i].is_div          = uop_uop2dp[i].uop_exe_unit==VEU_DIV; 
            assign rs_dp2div[i].vs1_data        = uop_uop2dp[i].vs1_valid ? uop_operand[i].vs1 : (`VLEN)'(uop_uop2dp[i].rs1_data);
            assign rs_dp2div[i].vs1_data_valid  = uop_uop2dp[i].vs1_valid;
            assign rs_dp2div[i].rs1_data_valid  = uop_uop2dp[i].rs1_data_valid;
            assign rs_dp2div[i].vs2_data        = uop_operand[i].vs2;
            assign rs_dp2div[i].vs2_eew         = uop_uop2dp[i].vs2_eew;
            assign rs_dp2div[i].vs2_data_valid  = uop_uop2dp[i].vs2_valid;
          `ifdef ZVE32F_ON
            assign rs_dp2div[i].frm             = uop_uop2dp[i].vector_csr.frm;
            assign rs_dp2div[i].vs1             = uop_uop2dp[i].vs1;
          `endif

          `ifdef ZVE32F_ON
          // FALU RS
          `ifdef TB_SUPPORT
            assign rs_dp2falu[i].uop_pc          = uop_uop2dp[i].uop_pc; 
          `endif
            assign rs_dp2falu[i].rob_entry       = rob_address[i]; 
            assign rs_dp2falu[i].uop_funct6      = uop_uop2dp[i].uop_funct6;
            assign rs_dp2falu[i].uop_funct3      = uop_uop2dp[i].uop_funct3;
            assign rs_dp2falu[i].uop_exe_unit    = uop_uop2dp[i].uop_exe_unit;
            assign rs_dp2falu[i].vstart          = uop_uop2dp[i].vector_csr.vstart;
            assign rs_dp2falu[i].vl              = uop_uop2dp[i].vs_evl;
            assign rs_dp2falu[i].vm              = uop_uop2dp[i].vm;
            assign rs_dp2falu[i].frm             = uop_uop2dp[i].vector_csr.frm;
            assign rs_dp2falu[i].v0_data         = uop_operand[i].v0[`VLENW*`EMUL_MAX-1:0];
            assign rs_dp2falu[i].v0_data_valid   = uop_uop2dp[i].v0_valid;
            assign rs_dp2falu[i].vs1             = uop_uop2dp[i].vs1;
            assign rs_dp2falu[i].vs1_data        = uop_operand[i].vs1;
            assign rs_dp2falu[i].vs1_data_valid  = uop_uop2dp[i].vs1_valid;
            assign rs_dp2falu[i].vs2_data        = uop_operand[i].vs2;
            assign rs_dp2falu[i].vs2_data_valid  = uop_uop2dp[i].vs2_valid;
            assign rs_dp2falu[i].vs2_eew         = uop_uop2dp[i].vs2_eew;
            assign rs_dp2falu[i].vs3_data        = uop_operand[i].vd;
            assign rs_dp2falu[i].vs3_data_valid  = uop_uop2dp[i].vs3_valid;
            assign rs_dp2falu[i].rs1_data        = uop_uop2dp[i].rs1_data;
            assign rs_dp2falu[i].rs1_data_valid  = uop_uop2dp[i].rs1_data_valid;
            assign rs_dp2falu[i].last_uop_valid  = uop_uop2dp[i].last_uop_valid;
            assign rs_dp2falu[i].uop_index       = uop_uop2dp[i].uop_index[$clog2(`EMUL_MAX)-1:0];            
          `endif

          `ifdef ZVT_ON
          // ZVT RS
          `ifdef TB_SUPPORT
            assign rs_dp2zvt[i].uop_pc          = uop_uop2dp[i].uop_pc; 
          `endif
            assign rs_dp2zvt[i].rob_entry       = rob_address[i]; 
            assign rs_dp2zvt[i].uop_funct6      = uop_uop2dp[i].uop_funct6;
            assign rs_dp2zvt[i].uop_funct3      = uop_uop2dp[i].uop_funct3;
            assign rs_dp2zvt[i].vs2             = uop_uop2dp[i].vs2_index;
            assign rs_dp2zvt[i].is_lsu          = uop_uop2dp[i].uop_exe_unit==VMELSU;
            assign rs_dp2zvt[i].is_store        = uop_uop2dp[i].lsu_is_store;
            assign rs_dp2zvt[i].vstart          = uop_uop2dp[i].vector_csr.vstart;
            assign rs_dp2zvt[i].altfmt          = uop_uop2dp[i].vector_csr.altfmt;
            assign rs_dp2zvt[i].mtwiden         = uop_uop2dp[i].vector_csr.mtwiden;
            assign rs_dp2zvt[i].tm              = uop_uop2dp[i].vector_csr.tm;
            assign rs_dp2zvt[i].vl              = uop_uop2dp[i].vs_evl[$clog2(`TE):0];
            assign rs_dp2zvt[i].tk              = uop_uop2dp[i].vector_csr.tk;
            assign rs_dp2zvt[i].sew             = uop_uop2dp[i].vector_csr.sew;
            // Use the de2-computed mt_eew, not a raw cast of `sew`: the SEW
            // enum (SEW8=0, SEW16=1, SEW32=2) and EEW enum (EEW_NONE=0, EEW1=1,
            // EEW8=2, EEW16=3, EEW32=4) do not align, so `EEW_e'(sew)` silently
            // mis-tags the move (e.g. SEW8 -> EEW_NONE), causing zvt_ctrl to
            // fall through to its EEW32 default path for vtmv.v.t / vtmv.t.v.
            assign rs_dp2zvt[i].eew_mt          = uop_uop2dp[i].mt_eew;
            assign rs_dp2zvt[i].rndMode         = fpnew_pkg::roundmode_e'(uop_uop2dp[i].vector_csr.frm);
            assign rs_dp2zvt[i].tss             = {uop_uop2dp[i].rs1_data[30:27],
                                                   uop_uop2dp[i].rs1_data[24],
                                                   uop_uop2dp[i].rs1_data[$clog2(`TE)-1:0]};
            assign rs_dp2zvt[i].vs1_data        = uop_operand[i].vs1;
            assign rs_dp2zvt[i].vs2_data        = uop_operand[i].vs2;
            assign rs_dp2zvt[i].dst_index       = uop_uop2dp[i].dst_index;
            assign rs_dp2zvt[i].first_uop_valid = uop_uop2dp[i].first_uop_valid;
            assign rs_dp2zvt[i].last_uop_valid  = uop_uop2dp[i].last_uop_valid;
            assign rs_dp2zvt[i].uop_index       = uop_uop2dp[i].uop_index[$clog2(`EMUL_MAX)-1:0];            
          `endif

          // LSU RS
          `ifdef TB_SUPPORT
            assign rs_dp2lsu[i].uop_pc              = uop_uop2dp[i].uop_pc; 
          `endif
            assign rs_dp2lsu[i].vidx_valid          = uop_uop2dp[i].vs2_valid;
            assign rs_dp2lsu[i].vidx_addr           = uop_uop2dp[i].vs2_index;
            assign rs_dp2lsu[i].vidx_data           = uop_operand[i].vs2;
            assign rs_dp2lsu[i].vregfile_read_valid = uop_uop2dp[i].vs3_valid;
            assign rs_dp2lsu[i].vregfile_read_addr  = uop_uop2dp[i].dst_index;
            assign rs_dp2lsu[i].vregfile_read_data  = uop_operand[i].vd;
            assign rs_dp2lsu[i].v0_valid            = uop_uop2dp[i].v0_valid;
            assign rs_dp2lsu[i].v0_data             = uop_operand_byte_type[i].v0_strobe;

          // LSU MAP INFO
          `ifdef TB_SUPPORT
            assign mapinfo_dp2lsu[i].uop_pc              = uop_uop2dp[i].uop_pc; 
          `endif
            assign mapinfo_dp2lsu[i].valid               = mapinfo_valid_dp2lsu[i];
            assign mapinfo_dp2lsu[i].rob_entry           = rob_address[i];
            assign mapinfo_dp2lsu[i].lsu_is_store        = uop_uop2dp[i].lsu_is_store;
            assign mapinfo_dp2lsu[i].vregfile_write_addr = uop_uop2dp[i].dst_index;

          // ROB
          assign uop_dp2rob[i].rob_tag          = uop_uop2dp[i].rob_tag;
          `ifdef TB_SUPPORT
            assign uop_dp2rob[i].uop_pc           = uop_uop2dp[i].uop_pc; 
            assign uop_dp2rob[i].res_updating_end = uop_uop2dp[i].res_updating_end; 
          `endif
            assign uop_dp2rob[i].w_index          = uop_uop2dp[i].dst_index;
            assign uop_dp2rob[i].w_type           = uop_uop2dp[i].vd_valid ? VRF : 
                                                  `ifdef ZVE32F_ON
                                                    uop_uop2dp[i].fd_valid ? FRF :
                                                  `endif
                                                    uop_uop2dp[i].xd_valid ? XRF : NOWRITE;
            assign uop_dp2rob[i].byte_type        = uop_operand_byte_type[i].vd;
            assign uop_dp2rob[i].is_ff            = (uop_uop2dp[i].uop_exe_unit==LSU)&(uop_uop2dp[i].uop_funct6.lsu_funct6.lsu_umop==US_FF);
            assign uop_dp2rob[i].vector_csr       = uop_uop2dp[i].vector_csr;
            assign uop_dp2rob[i].last_uop_valid   = uop_uop2dp[i].last_uop_valid;
        end
    endgenerate

endmodule
