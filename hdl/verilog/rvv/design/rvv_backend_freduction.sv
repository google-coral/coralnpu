
`ifndef HDL_VERILOG_RVV_DESIGN_RVV_SVH
`include "rvv_backend.svh"
`endif

module rvv_backend_freduction(
  clk,
  rst_n,
  uop_valid,
  uop_ready,
  uop,
  result_valid,
  result,
  result_ready,
  trap_flush_rvv
);
  localparam IDLE = 1'b0;
  localparam MATH = 1'b1;
  localparam PipeLine = 3;
  localparam CTRW = $clog2(`VLEN/`WORD_WIDTH);
  // global signals
  input   logic     clk;
  input   logic     rst_n;

  // DIV RS to DIV unit
  input   logic       uop_valid;
  output  logic       uop_ready;
  input  PMT_RDT_RS_t uop;

  // submit DIV result to ROB
  output  logic       result_valid;
  output  PU2ROB_t    result;
  input   logic       result_ready;
  
  // trap-flush
  input   logic                     trap_flush_rvv;


  //internal declaration
  
  logic         set_busy;
  logic         clear_busy;
  logic         next_state;
  logic [`FP_RDT_TAG_WIDTH-1:0] tag_i;
  logic [`FP_RDT_TAG_WIDTH-1:0] rdtadd_tag_o;
  logic [`FP_RDT_TAG_WIDTH-1:0] rdtcmp_tag_o;

  logic         sub_result_vld;
  logic         sub_result_rdy;
  logic  [31:0] sub_result;
  logic  [31:0] sub_vs1;
  logic  [31:0] sub_vs2;
  logic  [31:0] vs2_data_sel;
  logic         result_last_uop;// to be connected
  RVFEXP_t      sub_fexcp;
  RVFEXP_t      unused_fexcp;
  fpnew_pkg::status_t sub_status;


  logic         sub_rdtadd_in_vld;
  logic         sub_rdtadd_in_rdy;
  logic         sub_rdtadd_result_vld;
  logic  [31:0] sub_rdtadd_result;
  fpnew_pkg::status_t sub_rdtadd_status;
  

  logic         sub_rdtcmp_in_vld;
  logic         sub_rdtcmp_in_rdy;
  logic         sub_rdtcmp_result_vld;
  logic  [31:0] sub_rdtcmp_result;

  //logic         sub_rdtadd_busy;
  //logic         sub_rdtcmp_busy;
  logic         sub_busy;

  fpnew_pkg::roundmode_e sub_add_rnd;
  fpnew_pkg::roundmode_e sub_cmp_rnd;
  fpnew_pkg::roundmode_e sub_rnd_reg;
  fpnew_pkg::roundmode_e sub_rnd;
  fpnew_pkg::roundmode_e sub_rnd_in;
  fpnew_pkg::status_t sub_rdtcmp_status;


  logic  [CTRW-1:0] vld_ctr;
  logic             busy;
  logic             state;
  logic             add_in_vld_reg;
  logic             cmp_in_vld_reg;
  logic      [31:0] vs1_reg;
  logic [`VLEN-1:0] vs2_reg;
  logic [`FP_RDT_TAG_WIDTH-1:0] tag_reg;
  BYTE_TYPE_e [`VLENW-1:0]      vs2_type_reg;
  fpnew_pkg::status_t           fpexp_reg;
  logic                         sub_in_accept;
  logic                         mask_cur;
  logic                         mask_cur_reg;
  logic [`FP_RDT_TAG_WIDTH-1:0] mask_tag_reg;
  logic                 [31:0]  vs1_in_reg;

  //assignment
  assign uop_ready         =  !busy ||
                               busy && !sub_busy && vld_ctr == '0||
                               busy &&  sub_busy && sub_result_vld && sub_result_rdy && vld_ctr == '0;
  assign sub_result_rdy    =(vld_ctr == '0 && result_last_uop)? result_ready: 1'b1;
  assign sub_cmp_rnd       = uop.uop_funct6.ari_funct6[1]? fpnew_pkg::RTZ: fpnew_pkg::RNE;
  assign sub_rdtadd_in_vld = uop_valid && !uop.uop_funct6.ari_funct6[2] && (uop.vs2_type[0] == BODY_ACTIVE) && !(add_in_vld_reg | cmp_in_vld_reg) && sub_rdtadd_in_rdy ||
                                                         add_in_vld_reg && (vs2_type_reg[vld_ctr] == BODY_ACTIVE) && sub_rdtadd_in_rdy;
  assign sub_rdtcmp_in_vld = uop_valid &&  uop.uop_funct6.ari_funct6[2] && (uop.vs2_type[0] == BODY_ACTIVE) && !(add_in_vld_reg | cmp_in_vld_reg) && sub_rdtcmp_in_rdy ||
                                                         cmp_in_vld_reg && (vs2_type_reg[vld_ctr] == BODY_ACTIVE) && sub_rdtcmp_in_rdy;
  assign sub_rnd           = uop.uop_funct6.ari_funct6[2]? sub_cmp_rnd: sub_add_rnd;
  assign sub_rnd_in        =(uop_valid && uop_ready)? sub_rnd: sub_rnd_reg;
  assign mask_cur          = uop_valid && (uop.vs2_type[0] != BODY_ACTIVE) && !(add_in_vld_reg | cmp_in_vld_reg) || 
                            (add_in_vld_reg | cmp_in_vld_reg) && (vs2_type_reg[vld_ctr] != BODY_ACTIVE);
  assign sub_rdtadd_in_rdy = sub_busy? sub_result_vld && sub_result_rdy: 1'b1;
  assign sub_rdtcmp_in_rdy = sub_busy? sub_result_vld && sub_result_rdy: 1'b1;
  assign sub_in_accept     = sub_rdtadd_in_vld && sub_rdtadd_in_rdy && !trap_flush_rvv ||
                             sub_rdtcmp_in_vld && sub_rdtcmp_in_rdy && !trap_flush_rvv ||
                             mask_cur && (!sub_busy || sub_busy && sub_result_vld && sub_result_rdy) && !trap_flush_rvv;

`ifdef TB_SUPPORT
  assign tag_i             = (uop_valid && uop_ready)? {uop.last_uop_valid, uop.uop_pc, uop.rob_entry}: tag_reg;
`else
  assign tag_i             = (uop_valid && uop_ready)? {uop.last_uop_valid, uop.rob_entry}: tag_reg;
`endif

  always_comb
  begin
    sub_result_vld    = sub_rdtcmp_result_vld || sub_rdtadd_result_vld || mask_cur_reg;
    result.vsaturate  = '0;
    result.fpexp      = {{(`VLENB-1){unused_fexcp}}, sub_fexcp};
    if(mask_cur_reg) begin
      //sub result
      sub_result        = vs1_in_reg;
      sub_status        = '0;

      //total result
    `ifdef TB_SUPPORT
      result.uop_pc     = mask_tag_reg[`ROB_DEPTH_WIDTH+:`PC_WIDTH];
      result_last_uop   = mask_tag_reg[`PC_WIDTH+`ROB_DEPTH_WIDTH];
    `else
      result_last_uop   = mask_tag_reg[`ROB_DEPTH_WIDTH];
    `endif
      result.rob_entry  = mask_tag_reg[0+:`ROB_DEPTH_WIDTH];
      result.w_data     = {(`VLEN-32)'('b0), vs1_in_reg};
    end
    else begin
      //sub result
      sub_result        = sub_rdtcmp_result_vld? sub_rdtcmp_result: sub_rdtadd_result;
      sub_status        = sub_rdtcmp_result_vld? sub_rdtcmp_status: sub_rdtadd_status;

      //total result
    `ifdef TB_SUPPORT
      result.uop_pc     = sub_rdtcmp_result_vld? rdtcmp_tag_o[`ROB_DEPTH_WIDTH+:`PC_WIDTH]:rdtadd_tag_o[`ROB_DEPTH_WIDTH+:`PC_WIDTH];
      result_last_uop   = sub_rdtcmp_result_vld? rdtcmp_tag_o[`PC_WIDTH+`ROB_DEPTH_WIDTH]:rdtadd_tag_o[`PC_WIDTH+`ROB_DEPTH_WIDTH];
    `else
      result_last_uop   = sub_rdtcmp_result_vld? rdtcmp_tag_o[`ROB_DEPTH_WIDTH]:rdtadd_tag_o[`ROB_DEPTH_WIDTH];
    `endif
      result.rob_entry  = sub_rdtcmp_result_vld? rdtcmp_tag_o[0+:`ROB_DEPTH_WIDTH]:rdtadd_tag_o[0+:`ROB_DEPTH_WIDTH];
      result.w_data     = {(`VLEN-32)'('b0), sub_result};
    end
    result_valid      = result_last_uop && sub_result_vld && vld_ctr == '0;
    result.w_valid    = result_valid;
  end

  assign unused_fexcp = '0;

  assign sub_fexcp.nv = sub_status.NV |fpexp_reg.NV;
  assign sub_fexcp.dz = sub_status.DZ |fpexp_reg.DZ;
  assign sub_fexcp.of = sub_status.OF |fpexp_reg.OF;
  assign sub_fexcp.uf = sub_status.UF |fpexp_reg.UF;
  assign sub_fexcp.nx = sub_status.NX |fpexp_reg.NX;

  assign vs2_data_sel = vs2_reg[(vld_ctr*32)+:32];

  always_comb
  begin
    case(uop.frm)
      FRNE:   sub_add_rnd=fpnew_pkg::RNE;
      FRTZ:   sub_add_rnd=fpnew_pkg::RTZ;
      FRDN:   sub_add_rnd=fpnew_pkg::RDN;
      FRUP:   sub_add_rnd=fpnew_pkg::RUP;
      FRMM:   sub_add_rnd=fpnew_pkg::RMM;
      default:sub_add_rnd=fpnew_pkg::DYN;
    endcase
  end

  always_comb
  begin
    set_busy       = '0;
    clear_busy     = '0;
    next_state     = state;
    sub_vs1        = sub_result;
    sub_vs2        = vs2_data_sel;
    case(state)
      MATH: begin
        if(trap_flush_rvv) begin
          clear_busy  = 1'b1;
          next_state  = IDLE;
        end
        else if(sub_result_vld && sub_result_rdy) begin
          if(vld_ctr == '0) begin
            if(uop_valid && !trap_flush_rvv) begin
              sub_vs2     = uop.vs2_data[31:0];
              if(result_last_uop)
                sub_vs1     = uop.vs1_data[31:0];
            end
            else begin
              if(result_last_uop) begin
                clear_busy  = 1'b1;
                next_state  = IDLE;
              end
            end
          end
        end
        else begin
          sub_vs1         = vs1_reg;
          if(uop_valid && (vld_ctr == '0))
            sub_vs2       = uop.vs2_data[31:0];
        end
      end
      default: begin//IDLE
        if(uop_valid && uop_ready && !trap_flush_rvv) begin
          set_busy        = 1'b1;
          next_state      = MATH;
          sub_vs1         = uop.vs1_data[31:0];
          sub_vs2         = uop.vs2_data[31:0];
        end
      end
    endcase
  end

  always @(posedge clk or negedge rst_n)
  begin
    if(!rst_n) begin
      vld_ctr     <= '0;
      busy        <= '0;
      state       <= IDLE;
      add_in_vld_reg  <= '0;
      cmp_in_vld_reg  <= '0;
      vs1_reg     <= '0;
      vs2_reg     <= '0;
      tag_reg     <= '0;
      vs2_type_reg<= '0;
      fpexp_reg   <= '0;
      sub_rnd_reg <= fpnew_pkg::roundmode_e'('0);
      mask_cur_reg<= '0;
      mask_tag_reg<= '0;
      vs1_in_reg  <= '0;
      sub_busy <= '0;
    end
    else begin
      state <= next_state;
      if(set_busy) busy <= 1'b1;
      else if(clear_busy) busy <= 1'b0;
      if(trap_flush_rvv) begin
        add_in_vld_reg <= 1'b0;
        cmp_in_vld_reg <= 1'b0;
      end
      else if(uop_valid && uop_ready) begin
        add_in_vld_reg <= !uop.uop_funct6.ari_funct6[2];
        cmp_in_vld_reg <=  uop.uop_funct6.ari_funct6[2];
        sub_rnd_reg <= sub_rnd;
      end
      else if(sub_in_accept && (vld_ctr == '1)) begin
        add_in_vld_reg <= 1'b0;
        cmp_in_vld_reg <= 1'b0;
      end
      if(trap_flush_rvv) begin
        vs1_reg   <= '0;
        fpexp_reg <= '0;
      end
      else if(sub_result_vld && sub_result_rdy) begin
        vs1_reg <= sub_result;
        if(vld_ctr == '0 && result_last_uop)
          fpexp_reg <= '0;
        else
          fpexp_reg <= sub_status | fpexp_reg;
      end
      if(uop_valid && uop_ready && !trap_flush_rvv) begin
        vs2_reg <= uop.vs2_data;
        for(int i=0;i<`VLENW;i++) begin
          vs2_type_reg[i] <= uop.vs2_type[i*4];
        end
      `ifdef TB_SUPPORT
        tag_reg <= {uop.last_uop_valid, uop.uop_pc, uop.rob_entry};
      `else
        tag_reg <= {uop.last_uop_valid, uop.rob_entry};
      `endif
      end
      if(trap_flush_rvv) begin 
        vld_ctr       <= '0;
        mask_cur_reg  <= 1'b0;
        sub_busy      <= 1'b0;
      end
      else if(sub_in_accept) begin
        vld_ctr       <= vld_ctr + 'b1;
        mask_cur_reg  <= mask_cur;
        sub_busy      <= 1'b1;
      end
      else if(sub_result_vld && sub_result_rdy) begin
        mask_cur_reg  <= 1'b0;
        sub_busy      <= 1'b0;
      end
      if(mask_cur && !trap_flush_rvv) begin
        mask_tag_reg  <= tag_i;
        vs1_in_reg    <= sub_vs1;
      end
    end
  end

  fpnew_fma_multi #(
    .FpFmtConfig(5'b10000),
    .NumPipeRegs(PipeLine),
    .PipeConfig(fpnew_pkg::DISTRIBUTED),
    .TagType(logic [`FP_RDT_TAG_WIDTH-1:0])
    )
  rdtadd (
    .clk_i                 (clk),
    .rst_ni                (rst_n),
    // Input signals
    .operands_i            ({sub_vs1, sub_vs2, 32'b0}), // 2 operands
    .is_boxed_i            ('1), // 2 operands
    .rnd_mode_i            (sub_rnd_in),
    .op_i                  (fpnew_pkg::ADD),
    .op_mod_i              (1'b0),
    .src_fmt_i             (fpnew_pkg::FP32),
    .src2_fmt_i            (fpnew_pkg::FP32),
    .dst_fmt_i             (fpnew_pkg::FP32),
    .tag_i                 (tag_i),
    .mask_i                ('0),
    .aux_i                 ('0),
    // Input Handshake
    .in_valid_i            (sub_rdtadd_in_vld),
    .in_ready_o            (),
    .flush_i               (trap_flush_rvv),
    // Output signals
    .result_o              (sub_rdtadd_result),
    .status_o              (sub_rdtadd_status),
    .extension_bit_o       (),
    .tag_o                 (rdtadd_tag_o),
    .mask_o                (),
    .aux_o                 (),
    // Output handshake
    .out_valid_o           (sub_rdtadd_result_vld),
    .out_ready_i           (sub_result_rdy),
    // Indication of valid data in flight
    .busy_o                (),
    // External register enable override
    .reg_ena_i             ('0),
    // Early valid for external structural hazard generation
    .early_out_valid_o     ()
  );


  fpnew_noncomp #(
    .FpFormat(fpnew_pkg::FP32),
    .NumPipeRegs(PipeLine),
    .PipeConfig(fpnew_pkg::DISTRIBUTED),
    .TagType(logic [`FP_RDT_TAG_WIDTH-1:0])
  )
  rdtcmp (
    .clk_i               (clk),
    .rst_ni              (rst_n),
    // Input signals
    .operands_i          ({sub_vs2, sub_vs1}), // 2 operands
    .is_boxed_i          ('1), // 2 operands
    .rnd_mode_i          (sub_rnd_in),
    .op_i                (fpnew_pkg::MINMAX),
    .op_mod_i            (1'b0),
    .tag_i               (tag_i),
    .mask_i              ('0),
    .aux_i               ('0),
    // Input Handshake
    .in_valid_i          (sub_rdtcmp_in_vld),
    .in_ready_o          (),
    .flush_i             (trap_flush_rvv),
    // Output signals
    .result_o            (sub_rdtcmp_result),
    .status_o            (sub_rdtcmp_status),
    .extension_bit_o     (),
    .class_mask_o        (),
    .is_class_o          (),
    .tag_o               (rdtcmp_tag_o),
    .mask_o              (),
    .aux_o               (),
    // Output handshake
    .out_valid_o         (sub_rdtcmp_result_vld),
    .out_ready_i         (sub_result_rdy),
    // Indication of valid data in flight
    .busy_o              (),
    // External register enable override
    .reg_ena_i           ('0),
    // Early valid for external structural hazard generation
    .early_out_valid_o   ()
  );

endmodule
