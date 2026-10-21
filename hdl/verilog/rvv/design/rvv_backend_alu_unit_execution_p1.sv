
`ifndef HDL_VERILOG_RVV_DESIGN_RVV_SVH
`include "rvv_backend.svh"
`endif
`ifdef CORALNPU_STRUCTURAL_DATAPATH
`ifndef ALU_DEFINE_SVH
`include "rvv_backend_alu.svh"
`endif
`endif
`ifndef RVV_ASSERT__SVH
`include "rvv_backend_sva.svh"
`endif

module rvv_backend_alu_unit_execution_p1
(
  clk,
  rst_n,
  alu_uop_valid,
  alu_uop,
  result_valid,
  result,
  trap_flush_rvv
);
  parameter CMP_SUPPORT = 1'b0;

//
// interface signals
//
  // global signal
  input   logic           clk;
  input   logic           rst_n;
  // ALU RS handshake signals
  input   logic           alu_uop_valid;
  input   PIPE_DATA_t     alu_uop;
  // ALU send result signals to ROB
  output  logic           result_valid;
  output  PU2ROB_t        result;
  // trap-flush
  input   logic           trap_flush_rvv; 

//
// internal signals
//  
  // ALU_RS_t struct signals
  ADDSUB_e                                opcode;
  FUNCT6_u                                uop_funct6;
  logic   [`FUNCT3_WIDTH-1:0]             uop_funct3;
  logic   [`VSTART_WIDTH-1:0]             vstart;
  logic   [`VL_WIDTH-1:0]                 vl;       
  logic                                   vm;       
  RVVXRM                                  vxrm;       
  logic   [`VLEN-1:0]                     v0_data;
  logic   [`VLEN-1:0]                     vd_data;           
  EEW_e                                   vs2_eew;
  logic        	                          last_uop_valid;
  logic   [$clog2(`EMUL_MAX)-1:0]         uop_index;   

  logic                                   is_cmp;
  logic   [`VLENB-1:0][`BYTE_WIDTH-1:0]   src2_data;
  logic   [`VLENB-1:0][`BYTE_WIDTH-1:0]   src1_data;  
  logic   [`VLENB-1:0]                    src2_sgn;
  logic   [`VLENB-1:0]                    src1_sgn;
  logic   [`VLENB-1:0][`BYTE_WIDTH-1:0]   product8;
  logic   [`VLENH-1:0][`HWORD_WIDTH-1:0]  product16;
  logic   [`VLENW-1:0][`WORD_WIDTH-1:0]   product32;
  logic   [`VLENB-1:0]                    cout8;
  logic   [`VLENH-1:0]                    cout16;
  logic   [`VLENW-1:0]                    cout32;  
`ifndef CORALNPU_STRUCTURAL_DATAPATH
  logic   [`VLENB-1:0][`BYTE_WIDTH-1:0]   round8_src;
  logic   [`VLENH-1:0][`HWORD_WIDTH-1:0]  round16_src;
  logic   [`VLENW-1:0][`WORD_WIDTH-1:0]   round32_src;
`endif
  logic   [`VLENB-1:0][`BYTE_WIDTH-1:0]   round8;
  logic   [`VLENH-1:0][`HWORD_WIDTH-1:0]  round16;
  logic   [`VLENW-1:0][`WORD_WIDTH-1:0]   round32;
  logic   [`VLENB-1:0]                    addu_upoverflow;
  logic   [`VLENB-1:0]                    add_upoverflow;
  logic   [`VLENB-1:0]                    add_underoverflow;
  logic   [`VLENB-1:0]                    subu_underoverflow;
  logic   [`VLENB-1:0]                    sub_upoverflow;
  logic   [`VLENB-1:0]                    sub_underoverflow;
  logic   [`VLENB-1:0][`BYTE_WIDTH-1:0]   result_minmax8;
  logic   [`VLENH-1:0][`HWORD_WIDTH-1:0]  result_minmax16;
  logic   [`VLENW-1:0][`WORD_WIDTH-1:0]   result_minmax32;
  logic   [`VLEN-1:0]                     result_data;   // regular data for EEW_vd = 8b,16b,32b
  genvar                                  j;

  // for CMP
  logic   [`VLEN-1:0]                     vstart_elements_tmp;
  logic   [`VLEN-1:0]                     vstart_elements;
  logic   [`VLEN-1:0]                     tail_elements_tmp;
  logic   [`VLEN-1:0]                     tail_elements;
  logic   [`VLEN-1:0]                     cmp_tmp;
  logic   [`VLEN-1:0]                     cmp;
  logic   [27:0]                          cmp_en;
  logic   [28*`VLENW-1:0]                 cmp_d1;
  logic   [`VLEN-1:0]                     cmp_res_tmp;
  logic   [`VLEN-1:0]                     cmp_res;
  logic   [`VLEN-1:0]                     vmadcsbc_res;

//
// prepare source data to calculate    
//
  // split ALU_RS_t struct
  assign opcode         = alu_uop.opcode;
  assign uop_funct6     = alu_uop.uop_funct6;
  assign uop_funct3     = alu_uop.uop_funct3;
  assign is_cmp         = alu_uop.is_cmp;
  assign vs2_eew        = alu_uop.vs2_eew;
  assign vstart         = alu_uop.vstart;
  assign vl             = alu_uop.vl;
  assign vm             = alu_uop.vm;
  assign vxrm           = alu_uop.vxrm;
  assign v0_data        = alu_uop.v0_src2.v0;
  assign vd_data        = alu_uop.vd_src1.vd;
  assign src2_data      = alu_uop.v0_src2.src2;
  assign src1_data      = alu_uop.vd_src1.src1;
  assign src2_sgn       = alu_uop.src2_sgn;
  assign src1_sgn       = alu_uop.src1_sgn;
  assign product8       = alu_uop.w_data;
  assign cout8          = alu_uop.vsat_cout.cout;
  assign last_uop_valid = alu_uop.last_uop_valid;
  assign uop_index      = alu_uop.uop_index;

  generate
    // prepare valid signal 
    always_comb begin
      // initial the data
      result_valid = alu_uop_valid;

      if(CMP_SUPPORT) begin
        case(uop_funct3) 
          OPIVV: begin
            case(uop_funct6.ari_funct6)
              VMADC,
              VMSBC,
              VMSEQ,
              VMSNE,
              VMSLTU,
              VMSLT,
              VMSLEU,
              VMSLE: begin
                result_valid = alu_uop_valid&last_uop_valid;
              end            
            endcase
          end
          
          OPIVX: begin
            case(uop_funct6.ari_funct6)
              VMADC,
              VMSBC,
              VMSEQ,
              VMSNE,
              VMSLTU,
              VMSLT,
              VMSLEU,
              VMSLE,
              VMSGTU,
              VMSGT: begin
                result_valid = alu_uop_valid&last_uop_valid;
              end
            endcase
          end

          OPIVI: begin
            case(uop_funct6.ari_funct6)
              VMADC,
              VMSEQ,
              VMSNE,
              VMSLEU,
              VMSLE,
              VMSGTU,
              VMSGT: begin
                result_valid = alu_uop_valid&last_uop_valid;
              end
            endcase
          end
        endcase
      end
    end
  endgenerate

//    
// calculate the result
//
`ifdef CORALNPU_STRUCTURAL_DATAPATH
  generate
    for (j = 0; j < `VLENW; j = j + 1) begin : gen_alu_p1_lane
      rvv_backend_alu_addsub_p1_datapath u_alu_p1_dp (
        .is_sub             (opcode == ADDSUB_VSUB),
        .vs2_eew            (vs2_eew),
        .uop_funct6         (uop_funct6),
        .vxrm               (vxrm),
        .src2_sgn           (src2_sgn[4*j +: 4]),
        .src1_sgn           (src1_sgn[4*j +: 4]),
        .product8_in        ({product8[4*j+3], product8[4*j+2], product8[4*j+1], product8[4*j]}),
        .cout8_in           (cout8[4*j +: 4]),
        .product16_out      ({product16[2*j+1], product16[2*j]}),
        .cout16_out         (cout16[2*j +: 2]),
        .product32_out      (product32[j]),
        .cout32_out         (cout32[j]),
        .round8_out         ({round8[4*j+3], round8[4*j+2], round8[4*j+1], round8[4*j]}),
        .round16_out        ({round16[2*j+1], round16[2*j]}),
        .round32_out        (round32[j]),
        .addu_upoverflow    (addu_upoverflow[4*j +: 4]),
        .add_upoverflow     (add_upoverflow[4*j +: 4]),
        .add_underoverflow  (add_underoverflow[4*j +: 4]),
        .subu_underoverflow (subu_underoverflow[4*j +: 4]),
        .sub_upoverflow     (sub_upoverflow[4*j +: 4]),
        .sub_underoverflow  (sub_underoverflow[4*j +: 4])
      );
    end
  endgenerate
`else
  always_comb begin
    for(int i=0;i<`VLENH;i++) begin: VADDSUB_PROD16
      if (opcode==ADDSUB_VADD) 
        {cout16[i],product16[i]} = { ({cout8[2*i+1],product8[2*i+1]} + cout8[2*i]), product8[2*i] };
      else //(opcode==ADDSUB_VSUB)
        {cout16[i],product16[i]} = { ({cout8[2*i+1],product8[2*i+1]} - cout8[2*i]), product8[2*i] };
    end
  end

  always_comb begin
    for(int i=0;i<`VLENW;i++) begin: VADDSUB_PROD32
      if (opcode==ADDSUB_VADD) 
        {cout32[i],product32[i]} = { ({cout16[2*i+1],product16[2*i+1]} + cout16[2*i]), product16[2*i] };
      else //(opcode==ADDSUB_VSUB)
        {cout32[i],product32[i]} = { ({cout16[2*i+1],product16[2*i+1]} - cout16[2*i]), product16[2*i] };
    end
  end 

  // rounding result
  always_comb begin
    round8_src  = 'b0;
    round16_src = 'b0;
    round32_src = 'b0;
    round8  = 'b0;
    round16 = 'b0;
    round32 = 'b0;
    
    case(uop_funct6.ari_funct6)
      VAADDU,
      VASUBU: begin
        case(vxrm)
          RNU: begin
            for(int i=0;i<`VLENB;i=i+1) begin
              round8_src[i] = {cout8[i], product8[i][`BYTE_WIDTH-1:1]};
              round8[i]     = product8[i][0] ? round8_src[i]+1'b1 : round8_src[i];
            end

            for(int i=0;i<`VLENH;i=i+1) begin
              round16_src[i] = {cout16[i], product16[i][`HWORD_WIDTH-1:1]};
              round16[i]     = product16[i][0] ? round16_src[i]+1'b1 : round16_src[i];
            end

            for(int i=0;i<`VLENW;i=i+1) begin
              round32_src[i] = {cout32[i], product32[i][`WORD_WIDTH-1:1]};
              round32[i]     = product32[i][0] ? round32_src[i]+1'b1 : round32_src[i];
            end
          end
          RNE: begin
            for(int i=0;i<`VLENB;i=i+1) begin
              round8_src[i] = {cout8[i], product8[i][`BYTE_WIDTH-1:1]};
              round8[i]     = product8[i][0]&product8[i][1] ? round8_src[i]+1'b1 : round8_src[i];
            end
    
            for(int i=0;i<`VLENH;i=i+1) begin
              round16_src[i] = {cout16[i], product16[i][`HWORD_WIDTH-1:1]};
              round16[i]     = product16[i][0]&product16[i][1] ? round16_src[i]+1'b1 : round16_src[i];
            end
    
            for(int i=0;i<`VLENW;i=i+1) begin
              round32_src[i] = {cout32[i], product32[i][`WORD_WIDTH-1:1]};
              round32[i]     = product32[i][0]&product32[i][1] ? round32_src[i]+1'b1 : round32_src[i];
            end
          end
          RDN: begin
            for(int i=0;i<`VLENB;i=i+1) begin
              round8_src[i] = {cout8[i], product8[i][`BYTE_WIDTH-1:1]}; 
              round8[i]     = round8_src[i];
            end
    
            for(int i=0;i<`VLENH;i=i+1) begin
              round16_src[i] = {cout16[i], product16[i][`HWORD_WIDTH-1:1]}; 
              round16[i]     = round16_src[i];
            end
    
            for(int i=0;i<`VLENW;i=i+1) begin
              round32_src[i] = {cout32[i], product32[i][`WORD_WIDTH-1:1]}; 
              round32[i]     = round32_src[i];
            end
          end
          ROD: begin
            for(int i=0;i<`VLENB;i=i+1) begin
              round8_src[i] = {cout8[i], product8[i][`BYTE_WIDTH-1:1]};
              round8[i]     = (!product8[i][1])&product8[i][0] ? round8_src[i]+1'b1 : round8_src[i];
            end
    
            for(int i=0;i<`VLENH;i=i+1) begin
              round16_src[i] = {cout16[i], product16[i][`HWORD_WIDTH-1:1]};
              round16[i]     = (!product16[i][1])&product16[i][0] ? round16_src[i]+1'b1 : round16_src[i]; 
            end
    
            for(int i=0;i<`VLENW;i=i+1) begin
              round32_src[i] = {cout32[i], product32[i][`WORD_WIDTH-1:1]}; 
              round32[i]     = (!product32[i][1])&product32[i][0] ? round32_src[i]+1'b1 : round32_src[i]; 
            end
          end
        endcase
      end
      VAADD,
      VASUB: begin
        case(vxrm)
          RNU: begin
            for(int i=0;i<`VLENB;i=i+1) begin
              round8_src[i] = {src2_sgn[i]^src1_sgn[i] ? (!cout8[i]) : cout8[i], product8[i][`BYTE_WIDTH-1:1]};
              round8[i]     = product8[i][0] ? round8_src[i]+1'b1 : round8_src[i];                  
            end
            
            for(int i=0;i<`VLENH;i=i+1) begin
              round16_src[i] = {src2_sgn[2*i+1]^src1_sgn[2*i+1] ? (!cout16[i]) : cout16[i], product16[i][`HWORD_WIDTH-1:1]};
              round16[i]     = product16[i][0] ? round16_src[i]+1'b1 : round16_src[i]; 
            end

            for(int i=0;i<`VLENW;i=i+1) begin
              round32_src[i] = {src2_sgn[4*i+3]^src1_sgn[4*i+3] ? (!cout32[i]) : cout32[i], product32[i][`WORD_WIDTH-1:1]};
              round32[i]     = product32[i][0] ? round32_src[i]+1'b1 : round32_src[i]; 
            end
          end
          RNE: begin
            for(int i=0;i<`VLENB;i=i+1) begin
              round8_src[i] = {src2_sgn[i]^src1_sgn[i] ? (!cout8[i]) : cout8[i], product8[i][`BYTE_WIDTH-1:1]};
              round8[i]     = product8[i][0]&product8[i][1] ? round8_src[i]+1'b1 : round8_src[i]; 
            end
    
            for(int i=0;i<`VLENH;i=i+1) begin
              round16_src[i] = {src2_sgn[2*i+1]^src1_sgn[2*i+1] ? (!cout16[i]) : cout16[i], product16[i][`HWORD_WIDTH-1:1]};
              round16[i]     = product16[i][0]&product16[i][1] ? round16_src[i]+1'b1 : round16_src[i]; 
            end
    
            for(int i=0;i<`VLENW;i=i+1) begin
              round32_src[i] = {src2_sgn[4*i+3]^src1_sgn[4*i+3] ? (!cout32[i]) : cout32[i], product32[i][`WORD_WIDTH-1:1]};
              round32[i]     = product32[i][0]&product32[i][1] ? round32_src[i]+1'b1 : round32_src[i]; 
            end
          end
          RDN: begin
            for(int i=0;i<`VLENB;i=i+1) begin
              round8_src[i] = {src2_sgn[i]^src1_sgn[i] ? (!cout8[i]) : cout8[i], product8[i][`BYTE_WIDTH-1:1]}; 
              round8[i]     = round8_src[i];
            end
    
            for(int i=0;i<`VLENH;i=i+1) begin
              round16_src[i] = {src2_sgn[2*i+1]^src1_sgn[2*i+1] ? (!cout16[i]) : cout16[i], product16[i][`HWORD_WIDTH-1:1]}; 
              round16[i]     = round16_src[i];
            end
    
            for(int i=0;i<`VLENW;i=i+1) begin
              round32_src[i] = {src2_sgn[4*i+3]^src1_sgn[4*i+3] ? (!cout32[i]) : cout32[i], product32[i][`WORD_WIDTH-1:1]}; 
              round32[i]     = round32_src[i];
            end
          end
          ROD: begin
            for(int i=0;i<`VLENB;i=i+1) begin
              round8_src[i] = {src2_sgn[i]^src1_sgn[i] ? (!cout8[i]) : cout8[i], product8[i][`BYTE_WIDTH-1:1]};
              round8[i]     = (!product8[i][1])&product8[i][0] ? round8_src[i]+1'b1 : round8_src[i]; 
            end
    
            for(int i=0;i<`VLENH;i=i+1) begin
              round16_src[i] = {src2_sgn[2*i+1]^src1_sgn[2*i+1] ? (!cout16[i]) : cout16[i], product16[i][`HWORD_WIDTH-1:1]};
              round16[i]     = (!product16[i][1])&product16[i][0] ? round16_src[i]+1'b1 : round16_src[i]; 
            end
    
            for(int i=0;i<`VLENW;i=i+1) begin
              round32_src[i] = {src2_sgn[4*i+3]^src1_sgn[4*i+3] ? (!cout32[i]) : cout32[i], product32[i][`WORD_WIDTH-1:1]};
              round32[i]     = (!product32[i][1])&product32[i][0] ? round32_src[i]+1'b1 : round32_src[i]; 
            end
          end
        endcase
      end
    endcase
  end

  // overflow check
  generate 
    for (j=0;j<`VLENW;j++) begin: OVERFLOW
      always_comb begin
        // initial
        addu_upoverflow[   4*j +: 4] = 'b0;
        add_upoverflow[    4*j +: 4] = 'b0;
        add_underoverflow[ 4*j +: 4] = 'b0;
        subu_underoverflow[4*j +: 4] = 'b0;
        sub_upoverflow[    4*j +: 4] = 'b0;
        sub_underoverflow[ 4*j +: 4] = 'b0;
          
        case(vs2_eew)
          EEW8: begin
            addu_upoverflow[4*j +: 4] = {cout8[4*j+3],cout8[4*j+2],cout8[4*j+1],cout8[4*j]};

            add_upoverflow[4*j +: 4] = {
              ((product8[4*j+3][`BYTE_WIDTH-1])&(!src2_sgn[4*j+3])&(!src1_sgn[4*j+3])),
              ((product8[4*j+2][`BYTE_WIDTH-1])&(!src2_sgn[4*j+2])&(!src1_sgn[4*j+2])),
              ((product8[4*j+1][`BYTE_WIDTH-1])&(!src2_sgn[4*j+1])&(!src1_sgn[4*j+1])),
              ((product8[4*j  ][`BYTE_WIDTH-1])&(!src2_sgn[4*j  ])&(!src1_sgn[4*j  ]))};

            add_underoverflow[4*j +: 4] = {
              ((!product8[4*j+3][`BYTE_WIDTH-1])&(src2_sgn[4*j+3])&(src1_sgn[4*j+3])),
              ((!product8[4*j+2][`BYTE_WIDTH-1])&(src2_sgn[4*j+2])&(src1_sgn[4*j+2])),
              ((!product8[4*j+1][`BYTE_WIDTH-1])&(src2_sgn[4*j+1])&(src1_sgn[4*j+1])),
              ((!product8[4*j  ][`BYTE_WIDTH-1])&(src2_sgn[4*j  ])&(src1_sgn[4*j  ]))};
            
            subu_underoverflow[4*j +: 4] = {cout8[4*j+3],cout8[4*j+2],cout8[4*j+1],cout8[4*j]};

            sub_upoverflow[4*j +: 4] = {
              ((product8[4*j+3][`BYTE_WIDTH-1])&(!src2_sgn[4*j+3])&(src1_sgn[4*j+3])),
              ((product8[4*j+2][`BYTE_WIDTH-1])&(!src2_sgn[4*j+2])&(src1_sgn[4*j+2])),
              ((product8[4*j+1][`BYTE_WIDTH-1])&(!src2_sgn[4*j+1])&(src1_sgn[4*j+1])),
              ((product8[4*j  ][`BYTE_WIDTH-1])&(!src2_sgn[4*j  ])&(src1_sgn[4*j  ]))};

            sub_underoverflow[4*j +: 4] = {
              ((!product8[4*j+3][`BYTE_WIDTH-1])&(src2_sgn[4*j+3])&(!src1_sgn[4*j+3])),
              ((!product8[4*j+2][`BYTE_WIDTH-1])&(src2_sgn[4*j+2])&(!src1_sgn[4*j+2])),
              ((!product8[4*j+1][`BYTE_WIDTH-1])&(src2_sgn[4*j+1])&(!src1_sgn[4*j+1])),
              ((!product8[4*j  ][`BYTE_WIDTH-1])&(src2_sgn[4*j  ])&(!src1_sgn[4*j  ]))};
          end
          EEW16: begin
            addu_upoverflow[4*j +: 4] = {cout16[2*j+1],1'b0,cout16[2*j],1'b0};

            add_upoverflow[4*j +: 4] = {
              ((product16[2*j+1][`HWORD_WIDTH-1])&(!src2_sgn[4*j+3])&(!src1_sgn[4*j+3])),
              1'b0,
              ((product16[2*j  ][`HWORD_WIDTH-1])&(!src2_sgn[4*j+1])&(!src1_sgn[4*j+1])),
              1'b0};

            add_underoverflow[4*j +: 4] = {
              ((!product16[2*j+1][`HWORD_WIDTH-1])&(src2_sgn[4*j+3])&(src1_sgn[4*j+3])),
              1'b0,
              ((!product16[2*j  ][`HWORD_WIDTH-1])&(src2_sgn[4*j+1])&(src1_sgn[4*j+1])),
              1'b0};

            subu_underoverflow[4*j +: 4] = {cout16[2*j+1],1'b0,cout16[2*j],1'b0};

            sub_upoverflow[4*j +: 4] = {
              ((product16[2*j+1][`HWORD_WIDTH-1])&(!src2_sgn[4*j+3])&(src1_sgn[4*j+3])),
              1'b0,
              ((product16[2*j  ][`HWORD_WIDTH-1])&(!src2_sgn[4*j+1])&(src1_sgn[4*j+1])),
              1'b0};

            sub_underoverflow[4*j +: 4] = {
              ((!product16[2*j+1][`HWORD_WIDTH-1])&(src2_sgn[4*j+3])&(!src1_sgn[4*j+3])),
              1'b0,
              ((!product16[2*j  ][`HWORD_WIDTH-1])&(src2_sgn[4*j+1])&(!src1_sgn[4*j+1])),
              1'b0};
          end
          EEW32: begin
            addu_upoverflow[4*j +: 4] = {cout32[j],3'b0};

            add_upoverflow[4*j +: 4] = {
              ((product32[j][`WORD_WIDTH-1])&(!src2_sgn[4*j+3])&(!src1_sgn[4*j+3])),
              3'b0};

            add_underoverflow[4*j +: 4] = {
              ((!product32[j][`WORD_WIDTH-1])&(src2_sgn[4*j+3])&(src1_sgn[4*j+3])),
              3'b0};

            subu_underoverflow[4*j +: 4] = {cout32[j],3'b0};

            sub_upoverflow[4*j +: 4] = {
              ((product32[j][`WORD_WIDTH-1])&(!src2_sgn[4*j+3])&(src1_sgn[4*j+3])),
              3'b0};

            sub_underoverflow[4*j +: 4] = {
              ((!product32[j][`WORD_WIDTH-1])&(src2_sgn[4*j+3])&(!src1_sgn[4*j+3])),
              3'b0};
          end
        endcase
      end
    end
  endgenerate
`endif

  generate 
    if(CMP_SUPPORT) begin
      always_comb begin
        cmp_tmp = 'b0;
        cmp     = 'b0;
        cmp_en  = 'b0;
        
        for(int i=0;i<`VLENW;i++) begin
          // calculate result data
          case(uop_funct6.ari_funct6)
            VMSEQ,
            VMSNE: begin
              case(vs2_eew)
                EEW8: begin
                  cmp_tmp[(4*uop_index  )*`VLENW+i] = |(product8[0*`VLENW+i]);
                  cmp_tmp[(4*uop_index+1)*`VLENW+i] = |(product8[1*`VLENW+i]);
                  cmp_tmp[(4*uop_index+2)*`VLENW+i] = |(product8[2*`VLENW+i]);
                  cmp_tmp[(4*uop_index+3)*`VLENW+i] = |(product8[3*`VLENW+i]);

                  cmp[(4*uop_index  )*`VLENW+i] = (uop_funct6.ari_funct6==VMSNE) ? 
                                                    cmp_tmp[(4*uop_index)*`VLENW+i] : 
                                                    !cmp_tmp[(4*uop_index)*`VLENW+i];
                  cmp[(4*uop_index+1)*`VLENW+i] = (uop_funct6.ari_funct6==VMSNE) ? 
                                                    cmp_tmp[(4*uop_index+1)*`VLENW+i] : 
                                                    !cmp_tmp[(4*uop_index+1)*`VLENW+i];
                  cmp[(4*uop_index+2)*`VLENW+i] = (uop_funct6.ari_funct6==VMSNE) ? 
                                                    cmp_tmp[(4*uop_index+2)*`VLENW+i] : 
                                                    !cmp_tmp[(4*uop_index+2)*`VLENW+i];
                  cmp[(4*uop_index+3)*`VLENW+i] = (uop_funct6.ari_funct6==VMSNE) ? 
                                                    cmp_tmp[(4*uop_index+3)*`VLENW+i] : 
                                                    !cmp_tmp[(4*uop_index+3)*`VLENW+i];

                  cmp_en[uop_index*4 +: 4] = {4{alu_uop_valid&alu_uop.is_cmp&(!last_uop_valid)}};
                end
                EEW16: begin
                  cmp_tmp[(2*uop_index  )*`VLENW+i] = |(product16[0*`VLENW+i]);
                  cmp_tmp[(2*uop_index+1)*`VLENW+i] = |(product16[1*`VLENW+i]);

                  cmp[(2*uop_index  )*`VLENW+i] = (uop_funct6.ari_funct6==VMSNE) ? 
                                                    cmp_tmp[(2*uop_index)*`VLENW+i] : 
                                                    !cmp_tmp[(2*uop_index)*`VLENW+i];
                  cmp[(2*uop_index+1)*`VLENW+i] = (uop_funct6.ari_funct6==VMSNE) ? 
                                                    cmp_tmp[(2*uop_index+1)*`VLENW+i] : 
                                                    !cmp_tmp[(2*uop_index+1)*`VLENW+i];

                  cmp_en[uop_index*2 +: 2] = {2{alu_uop_valid&alu_uop.is_cmp&(!last_uop_valid)}};
                end
                EEW32: begin
                  cmp_tmp[uop_index*`VLENW+i] = |(product32[`VLENW*0+i]);

                  cmp[uop_index*`VLENW+i] = (uop_funct6.ari_funct6==VMSNE) ? 
                                              cmp_tmp[uop_index*`VLENW+i] : 
                                              !cmp_tmp[uop_index*`VLENW+i];

                  cmp_en[uop_index] = alu_uop_valid&alu_uop.is_cmp&(!last_uop_valid);
                end
              endcase
            end
            VMADC,
            VMSBC: begin
              case(vs2_eew)
                EEW8: begin
                  cmp[(4*uop_index  )*`VLENW+i] = cout8[0*`VLENW+i];
                  cmp[(4*uop_index+1)*`VLENW+i] = cout8[1*`VLENW+i];
                  cmp[(4*uop_index+2)*`VLENW+i] = cout8[2*`VLENW+i];
                  cmp[(4*uop_index+3)*`VLENW+i] = cout8[3*`VLENW+i];

                  cmp_en[uop_index*4 +: 4] = {4{alu_uop_valid&alu_uop.is_cmp&(!last_uop_valid)}};
                end
                EEW16: begin
                  cmp[(2*uop_index  )*`VLENW+i] = cout16[0*`VLENW+i];
                  cmp[(2*uop_index+1)*`VLENW+i] = cout16[1*`VLENW+i];

                  cmp_en[uop_index*2 +: 2] = {2{alu_uop_valid&alu_uop.is_cmp&(!last_uop_valid)}};
                end
                EEW32: begin
                  cmp[uop_index*`VLENW+i] = cout32[`VLENW*0+i];

                  cmp_en[uop_index] = alu_uop_valid&alu_uop.is_cmp&(!last_uop_valid);
                end
              endcase
            end
            VMSLT,
            VMSLE,
            VMSGT: begin
              case(vs2_eew)
                EEW8: begin
                  cmp_tmp[(4*uop_index  )*`VLENW+i] = sub_underoverflow[0*`VLENW+i] || 
                                                      (!sub_upoverflow[0*`VLENW+i]) && product8[0*`VLENW+i][`BYTE_WIDTH-1];
                  cmp_tmp[(4*uop_index+1)*`VLENW+i] = sub_underoverflow[1*`VLENW+i] || 
                                                      (!sub_upoverflow[1*`VLENW+i]) && product8[1*`VLENW+i][`BYTE_WIDTH-1];
                  cmp_tmp[(4*uop_index+2)*`VLENW+i] = sub_underoverflow[2*`VLENW+i] || 
                                                      (!sub_upoverflow[2*`VLENW+i]) && product8[2*`VLENW+i][`BYTE_WIDTH-1];
                  cmp_tmp[(4*uop_index+3)*`VLENW+i] = sub_underoverflow[3*`VLENW+i] || 
                                                      (!sub_upoverflow[3*`VLENW+i]) && product8[3*`VLENW+i][`BYTE_WIDTH-1];

                  cmp[(4*uop_index  )*`VLENW+i] = (uop_funct6.ari_funct6==VMSLE) ? 
                                                    cmp_tmp[(4*uop_index)*`VLENW+i] | (!(|product8[0*`VLENW+i])) :
                                                    cmp_tmp[(4*uop_index)*`VLENW+i] ;
                  cmp[(4*uop_index+1)*`VLENW+i] = (uop_funct6.ari_funct6==VMSLE) ? 
                                                    cmp_tmp[(4*uop_index+1)*`VLENW+i] | (!(|product8[1*`VLENW+i])) :
                                                    cmp_tmp[(4*uop_index+1)*`VLENW+i] ;
                  cmp[(4*uop_index+2)*`VLENW+i] = (uop_funct6.ari_funct6==VMSLE) ? 
                                                    cmp_tmp[(4*uop_index+2)*`VLENW+i] | (!(|product8[2*`VLENW+i])) :
                                                    cmp_tmp[(4*uop_index+2)*`VLENW+i] ;
                  cmp[(4*uop_index+3)*`VLENW+i] = (uop_funct6.ari_funct6==VMSLE) ? 
                                                    cmp_tmp[(4*uop_index+3)*`VLENW+i] | (!(|product8[3*`VLENW+i])) :
                                                    cmp_tmp[(4*uop_index+3)*`VLENW+i] ;

                  cmp_en[uop_index*4 +: 4] = {4{alu_uop_valid&alu_uop.is_cmp&(!last_uop_valid)}};
                end
                EEW16: begin
                  cmp_tmp[(2*uop_index  )*`VLENW+i] = sub_underoverflow[0*`VLENW+2*i+1] || 
                                                      (!sub_upoverflow[0*`VLENW+2*i+1]) && product16[0*`VLENW+i][`HWORD_WIDTH-1];
                  cmp_tmp[(2*uop_index+1)*`VLENW+i] = sub_underoverflow[2*`VLENW+2*i+1] || 
                                                      (!sub_upoverflow[2*`VLENW+2*i+1]) && product16[1*`VLENW+i][`HWORD_WIDTH-1];

                  cmp[(2*uop_index  )*`VLENW+i] = (uop_funct6.ari_funct6==VMSLE) ? 
                                                    cmp_tmp[(2*uop_index)*`VLENW+i] | (!(|product16[0*`VLENW+i])) :
                                                    cmp_tmp[(2*uop_index)*`VLENW+i] ;
                  cmp[(2*uop_index+1)*`VLENW+i] = (uop_funct6.ari_funct6==VMSLE) ? 
                                                    cmp_tmp[(2*uop_index+1)*`VLENW+i] | (!(|product16[1*`VLENW+i])) :
                                                    cmp_tmp[(2*uop_index+1)*`VLENW+i] ;

                  cmp_en[uop_index*2 +: 2] = {2{alu_uop_valid&alu_uop.is_cmp&(!last_uop_valid)}};
                end
                EEW32: begin
                  cmp_tmp[uop_index*`VLENW+i] = sub_underoverflow[4*i+3] ||
                                                (!sub_upoverflow[4*i+3]) && product32[i][`WORD_WIDTH-1];

                  cmp[uop_index*`VLENW+i] = (uop_funct6.ari_funct6==VMSLE) ? 
                                              cmp_tmp[uop_index*`VLENW+i] | (!(|product32[i])) :
                                              cmp_tmp[uop_index*`VLENW+i] ;

                  cmp_en[uop_index] = alu_uop_valid&alu_uop.is_cmp&(!last_uop_valid);
                end
              endcase     
            end
            VMSLTU,
            VMSLEU,
            VMSGTU: begin
              case(vs2_eew)
                EEW8: begin
                  cmp_tmp[(4*uop_index  )*`VLENW+i] = subu_underoverflow[0*`VLENW+i] || cout8[0*`VLENW+i];
                  cmp_tmp[(4*uop_index+1)*`VLENW+i] = subu_underoverflow[1*`VLENW+i] || cout8[1*`VLENW+i];
                  cmp_tmp[(4*uop_index+2)*`VLENW+i] = subu_underoverflow[2*`VLENW+i] || cout8[2*`VLENW+i];
                  cmp_tmp[(4*uop_index+3)*`VLENW+i] = subu_underoverflow[3*`VLENW+i] || cout8[3*`VLENW+i];

                  cmp[(4*uop_index  )*`VLENW+i] = (uop_funct6.ari_funct6==VMSLEU) ? 
                                                    cmp_tmp[(4*uop_index)*`VLENW+i] | (!(|product8[0*`VLENW+i])) :
                                                    cmp_tmp[(4*uop_index)*`VLENW+i] ;
                  cmp[(4*uop_index+1)*`VLENW+i] = (uop_funct6.ari_funct6==VMSLEU) ? 
                                                    cmp_tmp[(4*uop_index+1)*`VLENW+i] | (!(|product8[1*`VLENW+i])) :
                                                    cmp_tmp[(4*uop_index+1)*`VLENW+i] ;
                  cmp[(4*uop_index+2)*`VLENW+i] = (uop_funct6.ari_funct6==VMSLEU) ? 
                                                    cmp_tmp[(4*uop_index+2)*`VLENW+i] | (!(|product8[2*`VLENW+i])) :
                                                    cmp_tmp[(4*uop_index+2)*`VLENW+i] ;
                  cmp[(4*uop_index+3)*`VLENW+i] = (uop_funct6.ari_funct6==VMSLEU) ? 
                                                    cmp_tmp[(4*uop_index+3)*`VLENW+i] | (!(|product8[3*`VLENW+i])) :
                                                    cmp_tmp[(4*uop_index+3)*`VLENW+i] ;

                  cmp_en[uop_index*4 +: 4] = {4{alu_uop_valid&alu_uop.is_cmp&(!last_uop_valid)}};
                end
                EEW16: begin
                  cmp_tmp[(2*uop_index  )*`VLENW+i] = subu_underoverflow[0*`VLENW+2*i+1] || cout16[0*`VLENW+i];
                  cmp_tmp[(2*uop_index+1)*`VLENW+i] = subu_underoverflow[2*`VLENW+2*i+1] || cout16[1*`VLENW+i];

                  cmp[(2*uop_index  )*`VLENW+i] = (uop_funct6.ari_funct6==VMSLEU) ? 
                                                    cmp_tmp[(2*uop_index)*`VLENW+i] | (!(|product16[0*`VLENW+i])) :
                                                    cmp_tmp[(2*uop_index)*`VLENW+i] ;
                  cmp[(2*uop_index+1)*`VLENW+i] = (uop_funct6.ari_funct6==VMSLEU) ? 
                                                    cmp_tmp[(2*uop_index+1)*`VLENW+i] | (!(|product16[1*`VLENW+i])) :
                                                    cmp_tmp[(2*uop_index+1)*`VLENW+i] ;

                  cmp_en[uop_index*2 +: 2] = {2{alu_uop_valid&alu_uop.is_cmp&(!last_uop_valid)}};
                end
                EEW32: begin
                  cmp_tmp[uop_index*`VLENW+i] = subu_underoverflow[4*i+3] || cout32[i];

                  cmp[uop_index*`VLENW+i] = (uop_funct6.ari_funct6==VMSLEU) ? 
                                              cmp_tmp[uop_index*`VLENW+i] | (!(|product32[i])) :
                                              cmp_tmp[uop_index*`VLENW+i] ;

                  cmp_en[uop_index] = alu_uop_valid&alu_uop.is_cmp&(!last_uop_valid);
                end
              endcase  
            end
          endcase
        end
      end

      for(j=0;j<28;j++) begin
        cdffr # (
          .T            (logic [`VLENW-1:0])
        ) cmp_pipe ( 
          .q            (cmp_d1[j*`VLENW +: `VLENW]), 
          .clk          (clk), 
          .rst_n        (rst_n),  
          .c            (alu_uop_valid&is_cmp&last_uop_valid | trap_flush_rvv), 
          .e            (cmp_en[j]), 
          .d            (cmp[j*`VLENW +: `VLENW]) 
        );
      end

      assign cmp_res_tmp      = {cmp[`VLEN-1:28*`VLENW], (cmp[28*`VLENW-1:0]|cmp_d1)};

      barrel_shifter #(.DATA_WIDTH(`VLEN)) 
      u_prestart (.din((`VLEN)'('1)), .shift_amount(vstart[$clog2(`VLEN)-1:0]), .shift_mode(2'b00), .dout(vstart_elements_tmp));
      barrel_shifter #(.DATA_WIDTH(`VLEN)) 
      u_tail (.din((`VLEN)'('1)), .shift_amount(vl[$clog2(`VLEN)-1:0]), .shift_mode(2'b00), .dout(tail_elements_tmp));
      
      assign vstart_elements  = ~vstart_elements_tmp;
      assign tail_elements    = vl[$clog2(`VLEN)] ? 'b0 : tail_elements_tmp;

      for(j=0;j<`VLEN;j++) begin: CMP_MERGE
        assign cmp_res[j]       = !(vstart_elements[j]|tail_elements[j]) & (vm|v0_data[j]) ? cmp_res_tmp[j] : vd_data[j];
        assign vmadcsbc_res[j]  = vstart_elements[j]|tail_elements[j] ? vd_data[j] : cmp_res_tmp[j];
      end
    end

    // assign to result_data
    for (j=0;j<`VLENW;j++) begin: GET_RESULT_DATA
      always_comb begin
        // initial the data
        result_data[j*`WORD_WIDTH +: `WORD_WIDTH] = alu_uop.w_data[j*`WORD_WIDTH +: `WORD_WIDTH];
        result_minmax8[4*j+3]  = 'b0;
        result_minmax8[4*j+2]  = 'b0;
        result_minmax8[4*j+1]  = 'b0;
        result_minmax8[4*j]    = 'b0;
        result_minmax16[2*j+1] = 'b0;
        result_minmax16[2*j]   = 'b0;
        result_minmax32[j]     = 'b0;
 
        if(CMP_SUPPORT) begin
          // calculate result data
          case(uop_funct3) 
            OPIVV,
            OPIVX,
            OPIVI: begin
              case(uop_funct6.ari_funct6)
                VADD,
                VSUB,
                VRSUB,
                VADC,
                VSBC: begin
                  case(vs2_eew)
                    EEW8: begin
                      result_data[j*`WORD_WIDTH +: `WORD_WIDTH] = {product8[4*j+3],product8[4*j+2],product8[4*j+1],product8[4*j]};
                    end
                    EEW16: begin
                      result_data[j*`WORD_WIDTH +: `WORD_WIDTH] = {product16[2*j+1],product16[2*j]};
                    end
                    EEW32: begin
                      result_data[j*`WORD_WIDTH +: `WORD_WIDTH] = product32[j];
                    end
                  endcase
                end
                
                VSADDU: begin
                  case(vs2_eew)
                    EEW8: begin
                      if(addu_upoverflow[4*j])
                        result_data[j*`WORD_WIDTH +: `BYTE_WIDTH] = 'hff;
                      else
                        result_data[j*`WORD_WIDTH +: `BYTE_WIDTH] = product8[4*j];
                        
                      if(addu_upoverflow[4*j+1])
                        result_data[j*`WORD_WIDTH+1*`BYTE_WIDTH +: `BYTE_WIDTH] = 'hff;
                      else
                        result_data[j*`WORD_WIDTH+1*`BYTE_WIDTH +: `BYTE_WIDTH] = product8[4*j+1];
                      
                      if(addu_upoverflow[4*j+2])
                        result_data[j*`WORD_WIDTH+2*`BYTE_WIDTH +: `BYTE_WIDTH] = 'hff;
                      else
                        result_data[j*`WORD_WIDTH+2*`BYTE_WIDTH +: `BYTE_WIDTH] = product8[4*j+2];

                      if(addu_upoverflow[4*j+3])
                        result_data[j*`WORD_WIDTH+3*`BYTE_WIDTH +: `BYTE_WIDTH] = 'hff;
                      else
                        result_data[j*`WORD_WIDTH+3*`BYTE_WIDTH +: `BYTE_WIDTH] = product8[4*j+3];
                    end
                    EEW16: begin
                      if(addu_upoverflow[4*j+1])
                        result_data[j*`WORD_WIDTH +: `HWORD_WIDTH] = 'hffff;
                      else
                        result_data[j*`WORD_WIDTH +: `HWORD_WIDTH] = product16[2*j];
                        
                      if(addu_upoverflow[4*j+3])
                        result_data[j*`WORD_WIDTH+1*`HWORD_WIDTH +: `HWORD_WIDTH] = 'hffff;
                      else
                        result_data[j*`WORD_WIDTH+1*`HWORD_WIDTH +: `HWORD_WIDTH] = product16[2*j+1];
                    end
                    EEW32: begin
                      if(addu_upoverflow[4*j+3])
                        result_data[j*`WORD_WIDTH +: `WORD_WIDTH] = 'hffff_ffff;
                      else
                        result_data[j*`WORD_WIDTH +: `WORD_WIDTH] = product32[j];
                    end
                  endcase
                end

                VSADD: begin
                  case(vs2_eew)
                    EEW8: begin
                      if (add_upoverflow[4*j])
                        result_data[j*`WORD_WIDTH +: `BYTE_WIDTH] = 'h7f;
                      else if (add_underoverflow[4*j])
                        result_data[j*`WORD_WIDTH +: `BYTE_WIDTH] = 'h80;
                      else
                        result_data[j*`WORD_WIDTH +: `BYTE_WIDTH] = product8[4*j];
                        
                      if (add_upoverflow[4*j+1])
                        result_data[j*`WORD_WIDTH+1*`BYTE_WIDTH +: `BYTE_WIDTH] = 'h7f;
                      else if (add_underoverflow[4*j+1])
                        result_data[j*`WORD_WIDTH+1*`BYTE_WIDTH +: `BYTE_WIDTH] = 'h80;
                      else
                        result_data[j*`WORD_WIDTH+1*`BYTE_WIDTH +: `BYTE_WIDTH] = product8[4*j+1];
                      
                      if (add_upoverflow[4*j+2])
                        result_data[j*`WORD_WIDTH+2*`BYTE_WIDTH +: `BYTE_WIDTH] = 'h7f;
                      else if (add_underoverflow[4*j+2])
                        result_data[j*`WORD_WIDTH+2*`BYTE_WIDTH +: `BYTE_WIDTH] = 'h80;
                      else
                        result_data[j*`WORD_WIDTH+2*`BYTE_WIDTH +: `BYTE_WIDTH] = product8[4*j+2];

                      if (add_upoverflow[4*j+3])
                        result_data[j*`WORD_WIDTH+3*`BYTE_WIDTH +: `BYTE_WIDTH] = 'h7f;
                      else if (add_underoverflow[4*j+3])
                        result_data[j*`WORD_WIDTH+3*`BYTE_WIDTH +: `BYTE_WIDTH] = 'h80;
                      else
                        result_data[j*`WORD_WIDTH+3*`BYTE_WIDTH +: `BYTE_WIDTH] = product8[4*j+3];
                    end
                    EEW16: begin
                      if (add_upoverflow[4*j+1])
                        result_data[j*`WORD_WIDTH +: `HWORD_WIDTH] = 'h7fff;
                      else if (add_underoverflow[4*j+1])
                        result_data[j*`WORD_WIDTH +: `HWORD_WIDTH] = 'h8000;
                      else
                        result_data[j*`WORD_WIDTH +: `HWORD_WIDTH] = product16[2*j];                   

                      if (add_upoverflow[4*j+3])
                        result_data[j*`WORD_WIDTH+1*`HWORD_WIDTH +: `HWORD_WIDTH] = 'h7fff;
                      else if (add_underoverflow[4*j+3])
                        result_data[j*`WORD_WIDTH+1*`HWORD_WIDTH +: `HWORD_WIDTH] = 'h8000;
                      else
                        result_data[j*`WORD_WIDTH+1*`HWORD_WIDTH +: `HWORD_WIDTH] = product16[2*j+1];                   
                    end
                    EEW32: begin
                      if (add_upoverflow[4*j+3])
                        result_data[j*`WORD_WIDTH +: `WORD_WIDTH] = 'h7fff_ffff;
                      else if (add_underoverflow[4*j+3])
                        result_data[j*`WORD_WIDTH +: `WORD_WIDTH] = 'h8000_0000;
                      else
                        result_data[j*`WORD_WIDTH +: `WORD_WIDTH] = product32[j]; 
                    end
                  endcase
                end

                VSSUBU: begin
                  case(vs2_eew)
                    EEW8: begin
                      if(subu_underoverflow[4*j])
                        result_data[j*`WORD_WIDTH +: `BYTE_WIDTH] = 'd0;
                      else
                        result_data[j*`WORD_WIDTH +: `BYTE_WIDTH] = product8[4*j];
                        
                      if(subu_underoverflow[4*j+1])
                        result_data[j*`WORD_WIDTH+1*`BYTE_WIDTH +: `BYTE_WIDTH] = 'd0;
                      else
                        result_data[j*`WORD_WIDTH+1*`BYTE_WIDTH +: `BYTE_WIDTH] = product8[4*j+1];
                      
                      if(subu_underoverflow[4*j+2])
                        result_data[j*`WORD_WIDTH+2*`BYTE_WIDTH +: `BYTE_WIDTH] = 'd0;
                      else
                        result_data[j*`WORD_WIDTH+2*`BYTE_WIDTH +: `BYTE_WIDTH] = product8[4*j+2];

                      if(subu_underoverflow[4*j+3])
                        result_data[j*`WORD_WIDTH+3*`BYTE_WIDTH +: `BYTE_WIDTH] = 'd0;
                      else
                        result_data[j*`WORD_WIDTH+3*`BYTE_WIDTH +: `BYTE_WIDTH] = product8[4*j+3];
                    end
                    EEW16: begin
                      if(subu_underoverflow[4*j+1])
                        result_data[j*`WORD_WIDTH +: `HWORD_WIDTH] = 'd0;
                      else
                        result_data[j*`WORD_WIDTH +: `HWORD_WIDTH] = product16[2*j];
                        
                      if(subu_underoverflow[4*j+3])
                        result_data[j*`WORD_WIDTH+1*`HWORD_WIDTH +: `HWORD_WIDTH] = 'd0;
                      else
                        result_data[j*`WORD_WIDTH+1*`HWORD_WIDTH +: `HWORD_WIDTH] = product16[2*j+1];
                    end
                    EEW32: begin
                      if(subu_underoverflow[4*j+3])
                        result_data[j*`WORD_WIDTH +: `WORD_WIDTH] = 'd0;
                      else
                        result_data[j*`WORD_WIDTH +: `WORD_WIDTH] = product32[j];
                    end
                  endcase
                end

                VSSUB: begin
                  case(vs2_eew)
                    EEW8: begin
                      if (sub_upoverflow[4*j])
                        result_data[j*`WORD_WIDTH +: `BYTE_WIDTH] = 'h7f;
                      else if (sub_underoverflow[4*j])
                        result_data[j*`WORD_WIDTH +: `BYTE_WIDTH] = 'h80;
                      else
                        result_data[j*`WORD_WIDTH +: `BYTE_WIDTH] = product8[4*j];
                        
                      if (sub_upoverflow[4*j+1])
                        result_data[j*`WORD_WIDTH+1*`BYTE_WIDTH +: `BYTE_WIDTH] = 'h7f;
                      else if (sub_underoverflow[4*j+1])
                        result_data[j*`WORD_WIDTH+1*`BYTE_WIDTH +: `BYTE_WIDTH] = 'h80;
                      else
                        result_data[j*`WORD_WIDTH+1*`BYTE_WIDTH +: `BYTE_WIDTH] = product8[4*j+1];
                      
                      if (sub_upoverflow[4*j+2])
                        result_data[j*`WORD_WIDTH+2*`BYTE_WIDTH +: `BYTE_WIDTH] = 'h7f;
                      else if (sub_underoverflow[4*j+2])
                        result_data[j*`WORD_WIDTH+2*`BYTE_WIDTH +: `BYTE_WIDTH] = 'h80;
                      else
                        result_data[j*`WORD_WIDTH+2*`BYTE_WIDTH +: `BYTE_WIDTH] = product8[4*j+2];

                      if (sub_upoverflow[4*j+3])
                        result_data[j*`WORD_WIDTH+3*`BYTE_WIDTH +: `BYTE_WIDTH] = 'h7f;
                      else if (sub_underoverflow[4*j+3])
                        result_data[j*`WORD_WIDTH+3*`BYTE_WIDTH +: `BYTE_WIDTH] = 'h80;
                      else
                        result_data[j*`WORD_WIDTH+3*`BYTE_WIDTH +: `BYTE_WIDTH] = product8[4*j+3];
                    end
                    EEW16: begin
                      if (sub_upoverflow[4*j+1])
                        result_data[j*`WORD_WIDTH +: `HWORD_WIDTH] = 'h7fff;
                      else if (sub_underoverflow[4*j+1])
                        result_data[j*`WORD_WIDTH +: `HWORD_WIDTH] = 'h8000;
                      else
                        result_data[j*`WORD_WIDTH +: `HWORD_WIDTH] = product16[2*j];                   

                      if (sub_upoverflow[4*j+3])
                        result_data[j*`WORD_WIDTH+1*`HWORD_WIDTH +: `HWORD_WIDTH] = 'h7fff;
                      else if (sub_underoverflow[4*j+3])
                        result_data[j*`WORD_WIDTH+1*`HWORD_WIDTH +: `HWORD_WIDTH] = 'h8000;
                      else
                        result_data[j*`WORD_WIDTH+1*`HWORD_WIDTH +: `HWORD_WIDTH] = product16[2*j+1];                   
                    end
                    EEW32: begin
                      if (sub_upoverflow[4*j+3])
                        result_data[j*`WORD_WIDTH +: `WORD_WIDTH] = 'h7fff_ffff;
                      else if (sub_underoverflow[4*j+3])
                        result_data[j*`WORD_WIDTH +: `WORD_WIDTH] = 'h8000_0000;
                      else
                        result_data[j*`WORD_WIDTH +: `WORD_WIDTH] = product32[j]; 
                    end
                  endcase
                end

                VMADC,
                VMSBC: begin
                  result_data[j*`WORD_WIDTH +: `WORD_WIDTH] = vmadcsbc_res[j*`WORD_WIDTH +: `WORD_WIDTH];
                end

                VMSEQ,
                VMSNE,
                VMSLTU,
                VMSLT,
                VMSLEU,
                VMSLE,
                VMSGTU,
                VMSGT: begin
                  result_data[j*`WORD_WIDTH +: `WORD_WIDTH] = cmp_res[j*`WORD_WIDTH +: `WORD_WIDTH];
                end

                VMINU: begin
                  case(vs2_eew)
                    EEW8: begin
                      result_minmax8[4*j+3] = cout8[4*j+3] ? src2_data[4*j+3] : src1_data[4*j+3];
                      result_minmax8[4*j+2] = cout8[4*j+2] ? src2_data[4*j+2] : src1_data[4*j+2];
                      result_minmax8[4*j+1] = cout8[4*j+1] ? src2_data[4*j+1] : src1_data[4*j+1];
                      result_minmax8[4*j  ] = cout8[4*j  ] ? src2_data[4*j  ] : src1_data[4*j  ];

                      result_data[j*`WORD_WIDTH +: `WORD_WIDTH] = {result_minmax8[4*j+3],
                                                                   result_minmax8[4*j+2],
                                                                   result_minmax8[4*j+1],
                                                                   result_minmax8[4*j]};
                    end
                    EEW16: begin
                      result_minmax16[2*j+1] = cout16[2*j+1] ? {src2_data[4*j+3],src2_data[4*j+2]} : {src1_data[4*j+3],src1_data[4*j+2]}; 
                      result_minmax16[2*j  ] = cout16[2*j  ] ? {src2_data[4*j+1],src2_data[4*j  ]} : {src1_data[4*j+1],src1_data[4*j  ]};

                      result_data[j*`WORD_WIDTH +: `WORD_WIDTH] = {result_minmax16[2*j+1],
                                                                   result_minmax16[2*j]};
                    end
                    EEW32: begin
                      result_minmax32[j] = cout32[j] ? {src2_data[4*j+3],src2_data[4*j+2],src2_data[4*j+1],src2_data[4*j]}: 
                                                       {src1_data[4*j+3],src1_data[4*j+2],src1_data[4*j+1],src1_data[4*j]}; 

                      result_data[j*`WORD_WIDTH +: `WORD_WIDTH] = result_minmax32[j];
                    end
                  endcase
                end

                VMIN: begin
                  case(vs2_eew)
                    EEW8: begin
                      case({src2_data[4*j][`BYTE_WIDTH-1],src1_data[4*j][`BYTE_WIDTH-1]})
                        2'b10  : result_minmax8[4*j] = src2_data[4*j];
                        2'b01  : result_minmax8[4*j] = src1_data[4*j];
                        default: result_minmax8[4*j] = product8[4*j][`BYTE_WIDTH-1] ? src2_data[4*j] : src1_data[4*j];
                      endcase

                      case({src2_data[4*j+1][`BYTE_WIDTH-1],src1_data[4*j+1][`BYTE_WIDTH-1]})
                        2'b10  : result_minmax8[4*j+1] = src2_data[4*j+1];
                        2'b01  : result_minmax8[4*j+1] = src1_data[4*j+1];
                        default: result_minmax8[4*j+1] = product8[4*j+1][`BYTE_WIDTH-1] ? src2_data[4*j+1] : src1_data[4*j+1];
                      endcase

                      case({src2_data[4*j+2][`BYTE_WIDTH-1],src1_data[4*j+2][`BYTE_WIDTH-1]})
                        2'b10  : result_minmax8[4*j+2] = src2_data[4*j+2];
                        2'b01  : result_minmax8[4*j+2] = src1_data[4*j+2];
                        default: result_minmax8[4*j+2] = product8[4*j+2][`BYTE_WIDTH-1] ? src2_data[4*j+2] : src1_data[4*j+2];
                      endcase

                      case({src2_data[4*j+3][`BYTE_WIDTH-1],src1_data[4*j+3][`BYTE_WIDTH-1]})
                        2'b10  : result_minmax8[4*j+3] = src2_data[4*j+3];
                        2'b01  : result_minmax8[4*j+3] = src1_data[4*j+3];
                        default: result_minmax8[4*j+3] = product8[4*j+3][`BYTE_WIDTH-1] ? src2_data[4*j+3] : src1_data[4*j+3];
                      endcase

                      result_data[j*`WORD_WIDTH +: `WORD_WIDTH] = {result_minmax8[4*j+3],
                                                                   result_minmax8[4*j+2],
                                                                   result_minmax8[4*j+1],
                                                                   result_minmax8[4*j]};
                    end
                    EEW16: begin
                      case({src2_data[4*j+1][`BYTE_WIDTH-1],src1_data[4*j+1][`BYTE_WIDTH-1]})
                        2'b10  : result_minmax16[2*j] = {src2_data[4*j+1],src2_data[4*j]};
                        2'b01  : result_minmax16[2*j] = {src1_data[4*j+1],src1_data[4*j]};
                        default: result_minmax16[2*j] = product16[2*j][`HWORD_WIDTH-1] ? {src2_data[4*j+1],src2_data[4*j]} : {src1_data[4*j+1],src1_data[4*j]};
                      endcase

                      case({src2_data[4*j+3][`BYTE_WIDTH-1],src1_data[4*j+3][`BYTE_WIDTH-1]})
                        2'b10  : result_minmax16[2*j+1] = {src2_data[4*j+3],src2_data[4*j+2]};
                        2'b01  : result_minmax16[2*j+1] = {src1_data[4*j+3],src1_data[4*j+2]};
                        default: result_minmax16[2*j+1] = product16[2*j+1][`HWORD_WIDTH-1] ? {src2_data[4*j+3],src2_data[4*j+2]} : {src1_data[4*j+3],src1_data[4*j+2]};
                      endcase

                      result_data[j*`WORD_WIDTH +: `WORD_WIDTH] = {result_minmax16[2*j+1],
                                                                   result_minmax16[2*j]};
                    end
                    EEW32: begin
                      case({src2_data[4*j+3][`BYTE_WIDTH-1],src1_data[4*j+3][`BYTE_WIDTH-1]})
                        2'b10  : result_minmax32[j] = {src2_data[4*j+3],src2_data[4*j+2],src2_data[4*j+1],src2_data[4*j]};
                        2'b01  : result_minmax32[j] = {src1_data[4*j+3],src1_data[4*j+2],src1_data[4*j+1],src1_data[4*j]};
                        default: result_minmax32[j] = product32[j][`WORD_WIDTH-1] ? 
                                                        {src2_data[4*j+3],src2_data[4*j+2],src2_data[4*j+1],src2_data[4*j]}:
                                                        {src1_data[4*j+3],src1_data[4*j+2],src1_data[4*j+1],src1_data[4*j]}; 
                      endcase

                      result_data[j*`WORD_WIDTH +: `WORD_WIDTH] = result_minmax32[j];
                    end
                  endcase
                end

                VMAXU: begin
                  case(vs2_eew)
                    EEW8: begin
                      result_minmax8[4*j+3] = cout8[4*j+3] ? src1_data[4*j+3] : src2_data[4*j+3];
                      result_minmax8[4*j+2] = cout8[4*j+2] ? src1_data[4*j+2] : src2_data[4*j+2];
                      result_minmax8[4*j+1] = cout8[4*j+1] ? src1_data[4*j+1] : src2_data[4*j+1];
                      result_minmax8[4*j  ] = cout8[4*j  ] ? src1_data[4*j  ] : src2_data[4*j  ];

                      result_data[j*`WORD_WIDTH +: `WORD_WIDTH] = {result_minmax8[4*j+3],
                                                                   result_minmax8[4*j+2],
                                                                   result_minmax8[4*j+1],
                                                                   result_minmax8[4*j]};
                    end
                    EEW16: begin
                      result_minmax16[2*j+1] = cout16[2*j+1] ? {src1_data[4*j+3],src1_data[4*j+2]} : {src2_data[4*j+3],src2_data[4*j+2]}; 
                      result_minmax16[2*j  ] = cout16[2*j  ] ? {src1_data[4*j+1],src1_data[4*j  ]} : {src2_data[4*j+1],src2_data[4*j  ]};

                      result_data[j*`WORD_WIDTH +: `WORD_WIDTH] = {result_minmax16[2*j+1],
                                                                   result_minmax16[2*j]};
                    end
                    EEW32: begin
                      result_minmax32[j] = cout32[j] ? {src1_data[4*j+3],src1_data[4*j+2],src1_data[4*j+1],src1_data[4*j]}: 
                                                       {src2_data[4*j+3],src2_data[4*j+2],src2_data[4*j+1],src2_data[4*j]}; 

                      result_data[j*`WORD_WIDTH +: `WORD_WIDTH] = result_minmax32[j];
                    end
                  endcase
                end

                VMAX: begin
                  case(vs2_eew)
                    EEW8: begin
                      case({src2_data[4*j][`BYTE_WIDTH-1],src1_data[4*j][`BYTE_WIDTH-1]})
                        2'b01  : result_minmax8[4*j] = src2_data[4*j];
                        2'b10  : result_minmax8[4*j] = src1_data[4*j];
                        default: result_minmax8[4*j] = product8[4*j][`BYTE_WIDTH-1] ? src1_data[4*j] : src2_data[4*j];
                      endcase

                      case({src2_data[4*j+1][`BYTE_WIDTH-1],src1_data[4*j+1][`BYTE_WIDTH-1]})
                        2'b01  : result_minmax8[4*j+1] = src2_data[4*j+1];
                        2'b10  : result_minmax8[4*j+1] = src1_data[4*j+1];
                        default: result_minmax8[4*j+1] = product8[4*j+1][`BYTE_WIDTH-1] ? src1_data[4*j+1] : src2_data[4*j+1];
                      endcase

                      case({src2_data[4*j+2][`BYTE_WIDTH-1],src1_data[4*j+2][`BYTE_WIDTH-1]})
                        2'b01  : result_minmax8[4*j+2] = src2_data[4*j+2];
                        2'b10  : result_minmax8[4*j+2] = src1_data[4*j+2];
                        default: result_minmax8[4*j+2] = product8[4*j+2][`BYTE_WIDTH-1] ? src1_data[4*j+2] : src2_data[4*j+2];
                      endcase

                      case({src2_data[4*j+3][`BYTE_WIDTH-1],src1_data[4*j+3][`BYTE_WIDTH-1]})
                        2'b01  : result_minmax8[4*j+3] = src2_data[4*j+3];
                        2'b10  : result_minmax8[4*j+3] = src1_data[4*j+3];
                        default: result_minmax8[4*j+3] = product8[4*j+3][`BYTE_WIDTH-1] ? src1_data[4*j+3] : src2_data[4*j+3];
                      endcase

                      result_data[j*`WORD_WIDTH +: `WORD_WIDTH] = {result_minmax8[4*j+3],
                                                                   result_minmax8[4*j+2],
                                                                   result_minmax8[4*j+1],
                                                                   result_minmax8[4*j]};
                    end
                    EEW16: begin
                      case({src2_data[4*j+1][`BYTE_WIDTH-1],src1_data[4*j+1][`BYTE_WIDTH-1]})
                        2'b01  : result_minmax16[2*j] = {src2_data[4*j+1],src2_data[4*j]};
                        2'b10  : result_minmax16[2*j] = {src1_data[4*j+1],src1_data[4*j]};
                        default: result_minmax16[2*j] = product16[2*j][`HWORD_WIDTH-1] ? {src1_data[4*j+1],src1_data[4*j]} : {src2_data[4*j+1],src2_data[4*j]};
                      endcase

                      case({src2_data[4*j+3][`BYTE_WIDTH-1],src1_data[4*j+3][`BYTE_WIDTH-1]})
                        2'b01  : result_minmax16[2*j+1] = {src2_data[4*j+3],src2_data[4*j+2]};
                        2'b10  : result_minmax16[2*j+1] = {src1_data[4*j+3],src1_data[4*j+2]};
                        default: result_minmax16[2*j+1] = product16[2*j+1][`HWORD_WIDTH-1] ? {src1_data[4*j+3],src1_data[4*j+2]} : {src2_data[4*j+3],src2_data[4*j+2]};
                      endcase

                      result_data[j*`WORD_WIDTH +: `WORD_WIDTH] = {result_minmax16[2*j+1],
                                                                   result_minmax16[2*j]};
                    end
                    EEW32: begin
                      case({src2_data[4*j+3][`BYTE_WIDTH-1],src1_data[4*j+3][`BYTE_WIDTH-1]})
                        2'b01  : result_minmax32[j] = {src2_data[4*j+3],src2_data[4*j+2],src2_data[4*j+1],src2_data[4*j]};
                        2'b10  : result_minmax32[j] = {src1_data[4*j+3],src1_data[4*j+2],src1_data[4*j+1],src1_data[4*j]};
                        default: result_minmax32[j] = product32[j][`WORD_WIDTH-1] ? 
                                                        {src1_data[4*j+3],src1_data[4*j+2],src1_data[4*j+1],src1_data[4*j]}:
                                                        {src2_data[4*j+3],src2_data[4*j+2],src2_data[4*j+1],src2_data[4*j]}; 
                      endcase

                      result_data[j*`WORD_WIDTH +: `WORD_WIDTH] = result_minmax32[j];
                    end
                  endcase
                end        
              endcase
            end
            
            OPMVV,
            OPMVX: begin
              case(uop_funct6.ari_funct6)
                VWADDU,
                VWSUBU,
                VWADD,
                VWSUB: begin
                  case(vs2_eew)
                    EEW8: begin
                      result_data[j*`WORD_WIDTH +: `WORD_WIDTH] = {product16[2*j+1], product16[2*j]};
                    end
                    EEW16: begin
                      result_data[j*`WORD_WIDTH +: `WORD_WIDTH] = product32[j];
                    end
                  endcase
                end

                VWADDU_W,
                VWSUBU_W,
                VWADD_W,
                VWSUB_W: begin
                  case(vs2_eew)
                    EEW16: begin
                      result_data[j*`WORD_WIDTH +: `WORD_WIDTH] = {product16[2*j+1], product16[2*j]};
                    end
                    EEW32: begin
                      result_data[j*`WORD_WIDTH +: `WORD_WIDTH] = product32[j];
                    end
                  endcase
                end

                VAADDU,
                VAADD,
                VASUBU,
                VASUB: begin
                  case(vs2_eew)
                    EEW8: begin
                      result_data[j*`WORD_WIDTH +: `WORD_WIDTH] = {round8[4*j+3], round8[4*j+2], round8[4*j+1], round8[4*j]};
                    end
                    EEW16: begin
                      result_data[j*`WORD_WIDTH +: `WORD_WIDTH] = {round16[2*j+1], round16[2*j]};
                    end
                    EEW32: begin
                      result_data[j*`WORD_WIDTH +: `WORD_WIDTH] = round32[j];
                    end
                  endcase
                end
              endcase
            end
          endcase
        end
        else begin
          // calculate result data
          case(uop_funct3) 
            OPIVV,
            OPIVX,
            OPIVI: begin
              case(uop_funct6.ari_funct6)
                VADD,
                VSUB,
                VRSUB,
                VADC,
                VSBC: begin
                  case(vs2_eew)
                    EEW8: begin
                      result_data[j*`WORD_WIDTH +: `WORD_WIDTH] = {product8[4*j+3],product8[4*j+2],product8[4*j+1],product8[4*j]};
                    end
                    EEW16: begin
                      result_data[j*`WORD_WIDTH +: `WORD_WIDTH] = {product16[2*j+1],product16[2*j]};
                    end
                    EEW32: begin
                      result_data[j*`WORD_WIDTH +: `WORD_WIDTH] = product32[j];
                    end
                  endcase
                end
                
                VSADDU: begin
                  case(vs2_eew)
                    EEW8: begin
                      if(addu_upoverflow[4*j])
                        result_data[j*`WORD_WIDTH +: `BYTE_WIDTH] = 'hff;
                      else
                        result_data[j*`WORD_WIDTH +: `BYTE_WIDTH] = product8[4*j];
                        
                      if(addu_upoverflow[4*j+1])
                        result_data[j*`WORD_WIDTH+1*`BYTE_WIDTH +: `BYTE_WIDTH] = 'hff;
                      else
                        result_data[j*`WORD_WIDTH+1*`BYTE_WIDTH +: `BYTE_WIDTH] = product8[4*j+1];
                      
                      if(addu_upoverflow[4*j+2])
                        result_data[j*`WORD_WIDTH+2*`BYTE_WIDTH +: `BYTE_WIDTH] = 'hff;
                      else
                        result_data[j*`WORD_WIDTH+2*`BYTE_WIDTH +: `BYTE_WIDTH] = product8[4*j+2];

                      if(addu_upoverflow[4*j+3])
                        result_data[j*`WORD_WIDTH+3*`BYTE_WIDTH +: `BYTE_WIDTH] = 'hff;
                      else
                        result_data[j*`WORD_WIDTH+3*`BYTE_WIDTH +: `BYTE_WIDTH] = product8[4*j+3];
                    end
                    EEW16: begin
                      if(addu_upoverflow[4*j+1])
                        result_data[j*`WORD_WIDTH +: `HWORD_WIDTH] = 'hffff;
                      else
                        result_data[j*`WORD_WIDTH +: `HWORD_WIDTH] = product16[2*j];
                        
                      if(addu_upoverflow[4*j+3])
                        result_data[j*`WORD_WIDTH+1*`HWORD_WIDTH +: `HWORD_WIDTH] = 'hffff;
                      else
                        result_data[j*`WORD_WIDTH+1*`HWORD_WIDTH +: `HWORD_WIDTH] = product16[2*j+1];
                    end
                    EEW32: begin
                      if(addu_upoverflow[4*j+3])
                        result_data[j*`WORD_WIDTH +: `WORD_WIDTH] = 'hffff_ffff;
                      else
                        result_data[j*`WORD_WIDTH +: `WORD_WIDTH] = product32[j];
                    end
                  endcase
                end

                VSADD: begin
                  case(vs2_eew)
                    EEW8: begin
                      if (add_upoverflow[4*j])
                        result_data[j*`WORD_WIDTH +: `BYTE_WIDTH] = 'h7f;
                      else if (add_underoverflow[4*j])
                        result_data[j*`WORD_WIDTH +: `BYTE_WIDTH] = 'h80;
                      else
                        result_data[j*`WORD_WIDTH +: `BYTE_WIDTH] = product8[4*j];
                        
                      if (add_upoverflow[4*j+1])
                        result_data[j*`WORD_WIDTH+1*`BYTE_WIDTH +: `BYTE_WIDTH] = 'h7f;
                      else if (add_underoverflow[4*j+1])
                        result_data[j*`WORD_WIDTH+1*`BYTE_WIDTH +: `BYTE_WIDTH] = 'h80;
                      else
                        result_data[j*`WORD_WIDTH+1*`BYTE_WIDTH +: `BYTE_WIDTH] = product8[4*j+1];
                      
                      if (add_upoverflow[4*j+2])
                        result_data[j*`WORD_WIDTH+2*`BYTE_WIDTH +: `BYTE_WIDTH] = 'h7f;
                      else if (add_underoverflow[4*j+2])
                        result_data[j*`WORD_WIDTH+2*`BYTE_WIDTH +: `BYTE_WIDTH] = 'h80;
                      else
                        result_data[j*`WORD_WIDTH+2*`BYTE_WIDTH +: `BYTE_WIDTH] = product8[4*j+2];

                      if (add_upoverflow[4*j+3])
                        result_data[j*`WORD_WIDTH+3*`BYTE_WIDTH +: `BYTE_WIDTH] = 'h7f;
                      else if (add_underoverflow[4*j+3])
                        result_data[j*`WORD_WIDTH+3*`BYTE_WIDTH +: `BYTE_WIDTH] = 'h80;
                      else
                        result_data[j*`WORD_WIDTH+3*`BYTE_WIDTH +: `BYTE_WIDTH] = product8[4*j+3];
                    end
                    EEW16: begin
                      if (add_upoverflow[4*j+1])
                        result_data[j*`WORD_WIDTH +: `HWORD_WIDTH] = 'h7fff;
                      else if (add_underoverflow[4*j+1])
                        result_data[j*`WORD_WIDTH +: `HWORD_WIDTH] = 'h8000;
                      else
                        result_data[j*`WORD_WIDTH +: `HWORD_WIDTH] = product16[2*j];                   

                      if (add_upoverflow[4*j+3])
                        result_data[j*`WORD_WIDTH+1*`HWORD_WIDTH +: `HWORD_WIDTH] = 'h7fff;
                      else if (add_underoverflow[4*j+3])
                        result_data[j*`WORD_WIDTH+1*`HWORD_WIDTH +: `HWORD_WIDTH] = 'h8000;
                      else
                        result_data[j*`WORD_WIDTH+1*`HWORD_WIDTH +: `HWORD_WIDTH] = product16[2*j+1];                   
                    end
                    EEW32: begin
                      if (add_upoverflow[4*j+3])
                        result_data[j*`WORD_WIDTH +: `WORD_WIDTH] = 'h7fff_ffff;
                      else if (add_underoverflow[4*j+3])
                        result_data[j*`WORD_WIDTH +: `WORD_WIDTH] = 'h8000_0000;
                      else
                        result_data[j*`WORD_WIDTH +: `WORD_WIDTH] = product32[j]; 
                    end
                  endcase
                end

                VSSUBU: begin
                  case(vs2_eew)
                    EEW8: begin
                      if(subu_underoverflow[4*j])
                        result_data[j*`WORD_WIDTH +: `BYTE_WIDTH] = 'd0;
                      else
                        result_data[j*`WORD_WIDTH +: `BYTE_WIDTH] = product8[4*j];
                        
                      if(subu_underoverflow[4*j+1])
                        result_data[j*`WORD_WIDTH+1*`BYTE_WIDTH +: `BYTE_WIDTH] = 'd0;
                      else
                        result_data[j*`WORD_WIDTH+1*`BYTE_WIDTH +: `BYTE_WIDTH] = product8[4*j+1];
                      
                      if(subu_underoverflow[4*j+2])
                        result_data[j*`WORD_WIDTH+2*`BYTE_WIDTH +: `BYTE_WIDTH] = 'd0;
                      else
                        result_data[j*`WORD_WIDTH+2*`BYTE_WIDTH +: `BYTE_WIDTH] = product8[4*j+2];

                      if(subu_underoverflow[4*j+3])
                        result_data[j*`WORD_WIDTH+3*`BYTE_WIDTH +: `BYTE_WIDTH] = 'd0;
                      else
                        result_data[j*`WORD_WIDTH+3*`BYTE_WIDTH +: `BYTE_WIDTH] = product8[4*j+3];
                    end
                    EEW16: begin
                      if(subu_underoverflow[4*j+1])
                        result_data[j*`WORD_WIDTH +: `HWORD_WIDTH] = 'd0;
                      else
                        result_data[j*`WORD_WIDTH +: `HWORD_WIDTH] = product16[2*j];
                        
                      if(subu_underoverflow[4*j+3])
                        result_data[j*`WORD_WIDTH+1*`HWORD_WIDTH +: `HWORD_WIDTH] = 'd0;
                      else
                        result_data[j*`WORD_WIDTH+1*`HWORD_WIDTH +: `HWORD_WIDTH] = product16[2*j+1];
                    end
                    EEW32: begin
                      if(subu_underoverflow[4*j+3])
                        result_data[j*`WORD_WIDTH +: `WORD_WIDTH] = 'd0;
                      else
                        result_data[j*`WORD_WIDTH +: `WORD_WIDTH] = product32[j];
                    end
                  endcase
                end

                VSSUB: begin
                  case(vs2_eew)
                    EEW8: begin
                      if (sub_upoverflow[4*j])
                        result_data[j*`WORD_WIDTH +: `BYTE_WIDTH] = 'h7f;
                      else if (sub_underoverflow[4*j])
                        result_data[j*`WORD_WIDTH +: `BYTE_WIDTH] = 'h80;
                      else
                        result_data[j*`WORD_WIDTH +: `BYTE_WIDTH] = product8[4*j];
                        
                      if (sub_upoverflow[4*j+1])
                        result_data[j*`WORD_WIDTH+1*`BYTE_WIDTH +: `BYTE_WIDTH] = 'h7f;
                      else if (sub_underoverflow[4*j+1])
                        result_data[j*`WORD_WIDTH+1*`BYTE_WIDTH +: `BYTE_WIDTH] = 'h80;
                      else
                        result_data[j*`WORD_WIDTH+1*`BYTE_WIDTH +: `BYTE_WIDTH] = product8[4*j+1];
                      
                      if (sub_upoverflow[4*j+2])
                        result_data[j*`WORD_WIDTH+2*`BYTE_WIDTH +: `BYTE_WIDTH] = 'h7f;
                      else if (sub_underoverflow[4*j+2])
                        result_data[j*`WORD_WIDTH+2*`BYTE_WIDTH +: `BYTE_WIDTH] = 'h80;
                      else
                        result_data[j*`WORD_WIDTH+2*`BYTE_WIDTH +: `BYTE_WIDTH] = product8[4*j+2];

                      if (sub_upoverflow[4*j+3])
                        result_data[j*`WORD_WIDTH+3*`BYTE_WIDTH +: `BYTE_WIDTH] = 'h7f;
                      else if (sub_underoverflow[4*j+3])
                        result_data[j*`WORD_WIDTH+3*`BYTE_WIDTH +: `BYTE_WIDTH] = 'h80;
                      else
                        result_data[j*`WORD_WIDTH+3*`BYTE_WIDTH +: `BYTE_WIDTH] = product8[4*j+3];
                    end
                    EEW16: begin
                      if (sub_upoverflow[4*j+1])
                        result_data[j*`WORD_WIDTH +: `HWORD_WIDTH] = 'h7fff;
                      else if (sub_underoverflow[4*j+1])
                        result_data[j*`WORD_WIDTH +: `HWORD_WIDTH] = 'h8000;
                      else
                        result_data[j*`WORD_WIDTH +: `HWORD_WIDTH] = product16[2*j];                   

                      if (sub_upoverflow[4*j+3])
                        result_data[j*`WORD_WIDTH+1*`HWORD_WIDTH +: `HWORD_WIDTH] = 'h7fff;
                      else if (sub_underoverflow[4*j+3])
                        result_data[j*`WORD_WIDTH+1*`HWORD_WIDTH +: `HWORD_WIDTH] = 'h8000;
                      else
                        result_data[j*`WORD_WIDTH+1*`HWORD_WIDTH +: `HWORD_WIDTH] = product16[2*j+1];                   
                    end
                    EEW32: begin
                      if (sub_upoverflow[4*j+3])
                        result_data[j*`WORD_WIDTH +: `WORD_WIDTH] = 'h7fff_ffff;
                      else if (sub_underoverflow[4*j+3])
                        result_data[j*`WORD_WIDTH +: `WORD_WIDTH] = 'h8000_0000;
                      else
                        result_data[j*`WORD_WIDTH +: `WORD_WIDTH] = product32[j]; 
                    end
                  endcase
                end

                VMINU: begin
                  case(vs2_eew)
                    EEW8: begin
                      result_minmax8[4*j+3] = cout8[4*j+3] ? src2_data[4*j+3] : src1_data[4*j+3];
                      result_minmax8[4*j+2] = cout8[4*j+2] ? src2_data[4*j+2] : src1_data[4*j+2];
                      result_minmax8[4*j+1] = cout8[4*j+1] ? src2_data[4*j+1] : src1_data[4*j+1];
                      result_minmax8[4*j  ] = cout8[4*j  ] ? src2_data[4*j  ] : src1_data[4*j  ];

                      result_data[j*`WORD_WIDTH +: `WORD_WIDTH] = {result_minmax8[4*j+3],
                                                                   result_minmax8[4*j+2],
                                                                   result_minmax8[4*j+1],
                                                                   result_minmax8[4*j]};
                    end
                    EEW16: begin
                      result_minmax16[2*j+1] = cout16[2*j+1] ? {src2_data[4*j+3],src2_data[4*j+2]} : {src1_data[4*j+3],src1_data[4*j+2]}; 
                      result_minmax16[2*j  ] = cout16[2*j  ] ? {src2_data[4*j+1],src2_data[4*j  ]} : {src1_data[4*j+1],src1_data[4*j  ]};

                      result_data[j*`WORD_WIDTH +: `WORD_WIDTH] = {result_minmax16[2*j+1],
                                                                   result_minmax16[2*j]};
                    end
                    EEW32: begin
                      result_minmax32[j] = cout32[j] ? {src2_data[4*j+3],src2_data[4*j+2],src2_data[4*j+1],src2_data[4*j]}: 
                                                       {src1_data[4*j+3],src1_data[4*j+2],src1_data[4*j+1],src1_data[4*j]}; 

                      result_data[j*`WORD_WIDTH +: `WORD_WIDTH] = result_minmax32[j];
                    end
                  endcase
                end

                VMIN: begin
                  case(vs2_eew)
                    EEW8: begin
                      case({src2_data[4*j][`BYTE_WIDTH-1],src1_data[4*j][`BYTE_WIDTH-1]})
                        2'b10  : result_minmax8[4*j] = src2_data[4*j];
                        2'b01  : result_minmax8[4*j] = src1_data[4*j];
                        default: result_minmax8[4*j] = product8[4*j][`BYTE_WIDTH-1] ? src2_data[4*j] : src1_data[4*j];
                      endcase

                      case({src2_data[4*j+1][`BYTE_WIDTH-1],src1_data[4*j+1][`BYTE_WIDTH-1]})
                        2'b10  : result_minmax8[4*j+1] = src2_data[4*j+1];
                        2'b01  : result_minmax8[4*j+1] = src1_data[4*j+1];
                        default: result_minmax8[4*j+1] = product8[4*j+1][`BYTE_WIDTH-1] ? src2_data[4*j+1] : src1_data[4*j+1];
                      endcase

                      case({src2_data[4*j+2][`BYTE_WIDTH-1],src1_data[4*j+2][`BYTE_WIDTH-1]})
                        2'b10  : result_minmax8[4*j+2] = src2_data[4*j+2];
                        2'b01  : result_minmax8[4*j+2] = src1_data[4*j+2];
                        default: result_minmax8[4*j+2] = product8[4*j+2][`BYTE_WIDTH-1] ? src2_data[4*j+2] : src1_data[4*j+2];
                      endcase

                      case({src2_data[4*j+3][`BYTE_WIDTH-1],src1_data[4*j+3][`BYTE_WIDTH-1]})
                        2'b10  : result_minmax8[4*j+3] = src2_data[4*j+3];
                        2'b01  : result_minmax8[4*j+3] = src1_data[4*j+3];
                        default: result_minmax8[4*j+3] = product8[4*j+3][`BYTE_WIDTH-1] ? src2_data[4*j+3] : src1_data[4*j+3];
                      endcase

                      result_data[j*`WORD_WIDTH +: `WORD_WIDTH] = {result_minmax8[4*j+3],
                                                                   result_minmax8[4*j+2],
                                                                   result_minmax8[4*j+1],
                                                                   result_minmax8[4*j]};
                    end
                    EEW16: begin
                      case({src2_data[4*j+1][`BYTE_WIDTH-1],src1_data[4*j+1][`BYTE_WIDTH-1]})
                        2'b10  : result_minmax16[2*j] = {src2_data[4*j+1],src2_data[4*j]};
                        2'b01  : result_minmax16[2*j] = {src1_data[4*j+1],src1_data[4*j]};
                        default: result_minmax16[2*j] = product16[2*j][`HWORD_WIDTH-1] ? {src2_data[4*j+1],src2_data[4*j]} : {src1_data[4*j+1],src1_data[4*j]};
                      endcase

                      case({src2_data[4*j+3][`BYTE_WIDTH-1],src1_data[4*j+3][`BYTE_WIDTH-1]})
                        2'b10  : result_minmax16[2*j+1] = {src2_data[4*j+3],src2_data[4*j+2]};
                        2'b01  : result_minmax16[2*j+1] = {src1_data[4*j+3],src1_data[4*j+2]};
                        default: result_minmax16[2*j+1] = product16[2*j+1][`HWORD_WIDTH-1] ? {src2_data[4*j+3],src2_data[4*j+2]} : {src1_data[4*j+3],src1_data[4*j+2]};
                      endcase

                      result_data[j*`WORD_WIDTH +: `WORD_WIDTH] = {result_minmax16[2*j+1],
                                                                   result_minmax16[2*j]};
                    end
                    EEW32: begin
                      case({src2_data[4*j+3][`BYTE_WIDTH-1],src1_data[4*j+3][`BYTE_WIDTH-1]})
                        2'b10  : result_minmax32[j] = {src2_data[4*j+3],src2_data[4*j+2],src2_data[4*j+1],src2_data[4*j]};
                        2'b01  : result_minmax32[j] = {src1_data[4*j+3],src1_data[4*j+2],src1_data[4*j+1],src1_data[4*j]};
                        default: result_minmax32[j] = product32[j][`WORD_WIDTH-1] ? 
                                                        {src2_data[4*j+3],src2_data[4*j+2],src2_data[4*j+1],src2_data[4*j]}:
                                                        {src1_data[4*j+3],src1_data[4*j+2],src1_data[4*j+1],src1_data[4*j]}; 
                      endcase

                      result_data[j*`WORD_WIDTH +: `WORD_WIDTH] = result_minmax32[j];
                    end
                  endcase
                end

                VMAXU: begin
                  case(vs2_eew)
                    EEW8: begin
                      result_minmax8[4*j+3] = cout8[4*j+3] ? src1_data[4*j+3] : src2_data[4*j+3];
                      result_minmax8[4*j+2] = cout8[4*j+2] ? src1_data[4*j+2] : src2_data[4*j+2];
                      result_minmax8[4*j+1] = cout8[4*j+1] ? src1_data[4*j+1] : src2_data[4*j+1];
                      result_minmax8[4*j  ] = cout8[4*j  ] ? src1_data[4*j  ] : src2_data[4*j  ];

                      result_data[j*`WORD_WIDTH +: `WORD_WIDTH] = {result_minmax8[4*j+3],
                                                                   result_minmax8[4*j+2],
                                                                   result_minmax8[4*j+1],
                                                                   result_minmax8[4*j]};
                    end
                    EEW16: begin
                      result_minmax16[2*j+1] = cout16[2*j+1] ? {src1_data[4*j+3],src1_data[4*j+2]} : {src2_data[4*j+3],src2_data[4*j+2]}; 
                      result_minmax16[2*j  ] = cout16[2*j  ] ? {src1_data[4*j+1],src1_data[4*j  ]} : {src2_data[4*j+1],src2_data[4*j  ]};

                      result_data[j*`WORD_WIDTH +: `WORD_WIDTH] = {result_minmax16[2*j+1],
                                                                   result_minmax16[2*j]};
                    end
                    EEW32: begin
                      result_minmax32[j] = cout32[j] ? {src1_data[4*j+3],src1_data[4*j+2],src1_data[4*j+1],src1_data[4*j]}: 
                                                       {src2_data[4*j+3],src2_data[4*j+2],src2_data[4*j+1],src2_data[4*j]}; 

                      result_data[j*`WORD_WIDTH +: `WORD_WIDTH] = result_minmax32[j];
                    end
                  endcase
                end

                VMAX: begin
                  case(vs2_eew)
                    EEW8: begin
                      case({src2_data[4*j][`BYTE_WIDTH-1],src1_data[4*j][`BYTE_WIDTH-1]})
                        2'b01  : result_minmax8[4*j] = src2_data[4*j];
                        2'b10  : result_minmax8[4*j] = src1_data[4*j];
                        default: result_minmax8[4*j] = product8[4*j][`BYTE_WIDTH-1] ? src1_data[4*j] : src2_data[4*j];
                      endcase

                      case({src2_data[4*j+1][`BYTE_WIDTH-1],src1_data[4*j+1][`BYTE_WIDTH-1]})
                        2'b01  : result_minmax8[4*j+1] = src2_data[4*j+1];
                        2'b10  : result_minmax8[4*j+1] = src1_data[4*j+1];
                        default: result_minmax8[4*j+1] = product8[4*j+1][`BYTE_WIDTH-1] ? src1_data[4*j+1] : src2_data[4*j+1];
                      endcase

                      case({src2_data[4*j+2][`BYTE_WIDTH-1],src1_data[4*j+2][`BYTE_WIDTH-1]})
                        2'b01  : result_minmax8[4*j+2] = src2_data[4*j+2];
                        2'b10  : result_minmax8[4*j+2] = src1_data[4*j+2];
                        default: result_minmax8[4*j+2] = product8[4*j+2][`BYTE_WIDTH-1] ? src1_data[4*j+2] : src2_data[4*j+2];
                      endcase

                      case({src2_data[4*j+3][`BYTE_WIDTH-1],src1_data[4*j+3][`BYTE_WIDTH-1]})
                        2'b01  : result_minmax8[4*j+3] = src2_data[4*j+3];
                        2'b10  : result_minmax8[4*j+3] = src1_data[4*j+3];
                        default: result_minmax8[4*j+3] = product8[4*j+3][`BYTE_WIDTH-1] ? src1_data[4*j+3] : src2_data[4*j+3];
                      endcase

                      result_data[j*`WORD_WIDTH +: `WORD_WIDTH] = {result_minmax8[4*j+3],
                                                                   result_minmax8[4*j+2],
                                                                   result_minmax8[4*j+1],
                                                                   result_minmax8[4*j]};
                    end
                    EEW16: begin
                      case({src2_data[4*j+1][`BYTE_WIDTH-1],src1_data[4*j+1][`BYTE_WIDTH-1]})
                        2'b01  : result_minmax16[2*j] = {src2_data[4*j+1],src2_data[4*j]};
                        2'b10  : result_minmax16[2*j] = {src1_data[4*j+1],src1_data[4*j]};
                        default: result_minmax16[2*j] = product16[2*j][`HWORD_WIDTH-1] ? {src1_data[4*j+1],src1_data[4*j]} : {src2_data[4*j+1],src2_data[4*j]};
                      endcase

                      case({src2_data[4*j+3][`BYTE_WIDTH-1],src1_data[4*j+3][`BYTE_WIDTH-1]})
                        2'b01  : result_minmax16[2*j+1] = {src2_data[4*j+3],src2_data[4*j+2]};
                        2'b10  : result_minmax16[2*j+1] = {src1_data[4*j+3],src1_data[4*j+2]};
                        default: result_minmax16[2*j+1] = product16[2*j+1][`HWORD_WIDTH-1] ? {src1_data[4*j+3],src1_data[4*j+2]} : {src2_data[4*j+3],src2_data[4*j+2]};
                      endcase

                      result_data[j*`WORD_WIDTH +: `WORD_WIDTH] = {result_minmax16[2*j+1],
                                                                   result_minmax16[2*j]};
                    end
                    EEW32: begin
                      case({src2_data[4*j+3][`BYTE_WIDTH-1],src1_data[4*j+3][`BYTE_WIDTH-1]})
                        2'b01  : result_minmax32[j] = {src2_data[4*j+3],src2_data[4*j+2],src2_data[4*j+1],src2_data[4*j]};
                        2'b10  : result_minmax32[j] = {src1_data[4*j+3],src1_data[4*j+2],src1_data[4*j+1],src1_data[4*j]};
                        default: result_minmax32[j] = product32[j][`WORD_WIDTH-1] ? 
                                                        {src1_data[4*j+3],src1_data[4*j+2],src1_data[4*j+1],src1_data[4*j]}:
                                                        {src2_data[4*j+3],src2_data[4*j+2],src2_data[4*j+1],src2_data[4*j]}; 
                      endcase

                      result_data[j*`WORD_WIDTH +: `WORD_WIDTH] = result_minmax32[j];
                    end
                  endcase
                end        
              endcase
            end
            
            OPMVV,
            OPMVX: begin
              case(uop_funct6.ari_funct6)
                VWADDU,
                VWSUBU,
                VWADD,
                VWSUB: begin
                  case(vs2_eew)
                    EEW8: begin
                      result_data[j*`WORD_WIDTH +: `WORD_WIDTH] = {product16[2*j+1], product16[2*j]};
                    end
                    EEW16: begin
                      result_data[j*`WORD_WIDTH +: `WORD_WIDTH] = product32[j];
                    end
                  endcase
                end

                VWADDU_W,
                VWSUBU_W,
                VWADD_W,
                VWSUB_W: begin
                  case(vs2_eew)
                    EEW16: begin
                      result_data[j*`WORD_WIDTH +: `WORD_WIDTH] = {product16[2*j+1], product16[2*j]};
                    end
                    EEW32: begin
                      result_data[j*`WORD_WIDTH +: `WORD_WIDTH] = product32[j];
                    end
                  endcase
                end

                VAADDU,
                VAADD,
                VASUBU,
                VASUB: begin
                  case(vs2_eew)
                    EEW8: begin
                      result_data[j*`WORD_WIDTH +: `WORD_WIDTH] = {round8[4*j+3], round8[4*j+2], round8[4*j+1], round8[4*j]};
                    end
                    EEW16: begin
                      result_data[j*`WORD_WIDTH +: `WORD_WIDTH] = {round16[2*j+1], round16[2*j]};
                    end
                    EEW32: begin
                      result_data[j*`WORD_WIDTH +: `WORD_WIDTH] = round32[j];
                    end
                  endcase
                end
              endcase
            end
          endcase
        end
      end
    end
  endgenerate


//
// submit result to ROB
//
  // get result_uop
  always_comb begin
    // initial the data
  `ifdef TB_SUPPORT
    result.uop_pc    = alu_uop.uop_pc;
  `endif
    result.rob_entry = alu_uop.rob_entry;
    result.w_valid   = alu_uop.is_addsub ? 'b1 : alu_uop.w_valid; 
    result.w_data    = alu_uop.is_addsub ? result_data : alu_uop.w_data; 
    result.vsaturate = alu_uop.is_addsub ? 'b0 : alu_uop.vsat_cout.vsaturate;
  `ifdef ZVE32F_ON
    result.fpexp     = 'b0;
  `endif

    case(uop_funct3) 
      OPIVV,
      OPIVX,
      OPIVI: begin
        case(uop_funct6.ari_funct6)
          VSADDU: begin
            result.vsaturate = addu_upoverflow;
          end
          VSADD: begin
            result.vsaturate = add_upoverflow|add_underoverflow;
          end
          VSSUBU: begin
            result.vsaturate = subu_underoverflow;
          end
          VSSUB: begin
            result.vsaturate = sub_upoverflow|sub_underoverflow;
          end
        endcase
      end
    endcase
  end

endmodule
