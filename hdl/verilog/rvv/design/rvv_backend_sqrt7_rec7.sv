
module rvv_backend_sqrt7_rec7(
  clk,
  rst_n,
  // Input signals
  operand_i, // 1 operand
  vs1_i,
  rnd_mode_i,
  tag_i,
  // Input Handshake
  in_valid_i,
  in_ready_o,
  flush_i,
  // Output signals
  result_o,
  tbl_status_o,
  tag_o,
  // Output handshake
  out_valid_o,
  out_ready_i
);
  parameter  type TagType   = logic;
  localparam CANO_NAN_SIGN  = 1'b0;
  localparam CANO_NAN_EXP   = 8'hff;
  localparam CANO_NAN_MAN   = 23'h400000;
  // global signals
  input   logic                     clk;
  input   logic                     rst_n;

  // Input signals
  input       [`WORD_WIDTH-1:0]     operand_i; // 1 operand
  input       [`REGIDX_WIDTH-1:0]   vs1_i;
  input                       RVFRM rnd_mode_i;
  input                     TagType tag_i;
  // Input Handshake
  input logic                       in_valid_i;
  output logic                      in_ready_o;
  input logic                       flush_i;
  // Output signals
  output  [`WORD_WIDTH-1:0]         result_o;
  output                   RVFEXP_t tbl_status_o;
  output                    TagType tag_o;
  // Output handshake
  output logic                      out_valid_o;
  input logic                       out_ready_i;

  //internal declaration
  logic                      rec7_vld;
  logic                      stall_pip;
  logic                      invld;

  //pipe 1, register all input sginal, test if subnormal
  logic                      sign_in;
  logic                [7:0] exp_in;
  logic               [22:0] man_in;
  //pipe 2, get the leading zero cnt of mantissa, get nornalized exp and man search index
  logic                      pip1_infinite;
  logic                      pip1_NaN;
  logic                      pip1_qNaN;
  logic                      pip1_zero;
  logic                [4:0] pip1_lead_z;
  logic                [7:0] pip1_exp_normed;
  logic                [6:0] pip1_man_index;

  logic                [7:0] pip2_sqrt7_exp;
  logic                [8:0] pip2_sqrt7_exp_bf_sft;
  logic                [7:0] pip2_rec7_exp;
  logic                [6:0] pip2_sqrt7_man;
  logic                [6:0] pip2_rec7_man;
  logic                      pip2_subn;

  logic                      pip3_rec7_exp_subn;
  logic                      pip3_rec7_unused_bit;
  logic               [22:0] pip3_rec7_man_normed;
  logic                [1:0] pip3_rec7_rnd_bit;
  //logic                [6:0] pip3_rec7_man_rnded;

  logic                      sqrt7_result_sign;
  logic                [7:0] sqrt7_result_exp;
  logic               [22:0] sqrt7_result_man;
  logic               [31:0] sqrt7_result;
  RVFEXP_t                   sqrt7_result_excp;

  logic                      rec7_result_sign;
  logic                [7:0] rec7_result_exp;
  logic               [22:0] rec7_result_man;
  logic               [31:0] rec7_result;
  RVFEXP_t                   rec7_result_excp;
  

  //pipe stage
  //pipe 1, register all input sginal, test if subnormal
  logic                        pip1_vld;
  logic                        pip1_sqrt7_vld;
  logic                        pip1_sign;
  RVFRM                      pip1_rnd;
  logic                  [7:0] pip1_exp;
  logic                 [22:0] pip1_man;
  logic                        pip1_subn;
  TagType                      pip1_tag;

  //pipe 2, get the leading zero cnt of mantissa, get nornalized exp and man search index
  logic                        pip2_vld;
  logic                        pip2_sqrt7_vld;
  logic                        pip2_sign;
  RVFRM                      pip2_rnd;
  logic                  [7:0] pip2_exp;
  logic                 [22:0] pip2_man;
  logic                        pip2_infinite;
  logic                        pip2_NaN;
  logic                        pip2_qNaN;
  logic                        pip2_zero;
  logic                        pip2_lead_z_eq_z;
  TagType                      pip2_tag;
  logic                  [7:0] pip2_exp_normed;
  logic                  [6:0] pip2_man_index;

  //pip3, get the normalized exponent, expreuslts and significant with registered leading zero cnt
  logic                        pip3_vld;
  logic                        pip3_sqrt7_vld;
  logic                        pip3_sign;
  RVFRM                      pip3_rnd;
  logic                  [7:0] pip3_exp;
  logic                 [22:0] pip3_man;
  logic                        pip3_infinite;
  logic                        pip3_NaN;
  logic                        pip3_qNaN;
  logic                        pip3_zero;
  logic                  [7:0] pip3_sqrt7_exp;
  logic                  [7:0] pip3_rec7_exp;
  logic                  [6:0] pip3_sqrt7_man;
  logic                  [6:0] pip3_rec7_man;
  TagType                        pip3_tag;

  //pipe 4, get the exponent results and search the table 
  logic                        pip4_vld;
  logic                        pip4_sqrt7_vld;
  logic                 [31:0] pip4_sqrt7_result;
  logic                 [31:0] pip4_rec7_result;
  RVFEXP_t                     pip4_sqrt7_fexp;
  RVFEXP_t                     pip4_rec7_fexp;
  TagType                        pip4_tag;
  

  //signal assignment
  assign rec7_vld        =  vs1_i[0];

  assign invld           = in_valid_i & in_ready_o & !flush_i;
  assign stall_pip       = out_valid_o & !out_ready_i;

  assign sign_in         = operand_i[31];
  assign exp_in          = operand_i[30-:8];
  assign man_in          =  operand_i[22:0];

  assign pip1_infinite    = pip1_exp == '1 && pip1_man == '0;
  assign pip1_NaN         = pip1_exp == '1 && pip1_man != '0;
  assign pip1_qNaN        = pip1_NaN && pip1_man[22]==1'b1;
  assign pip1_zero        = pip1_exp == '0 && pip1_man == '0;
  assign pip1_lead_z      = leading_zero_cnt(pip1_man);
  assign pip1_exp_normed  = pip1_subn ? (8'h0 - pip1_lead_z): pip1_exp;
  assign pip1_man_index   = man7_normed(pip1_subn, pip1_exp_normed, pip1_man);

  assign pip2_subn        = (pip2_exp == 8'h0) && |pip2_man;
  assign pip2_sqrt7_exp_bf_sft = 9'h17c - {(pip2_subn & !pip2_lead_z_eq_z), pip2_exp_normed};
  assign pip2_sqrt7_exp   = pip2_sqrt7_exp_bf_sft[8:1];
  assign pip2_rec7_exp    = (8'hfd - pip2_exp_normed);

  assign pip3_rec7_exp_subn   = pip3_rec7_exp == '0 || pip3_rec7_exp == '1;
  assign {pip3_rec7_unused_bit, pip3_rec7_man_normed} =
            {1'b1, pip3_rec7_man, 16'b0} >> (7'b1 - pip3_rec7_exp);

  //output assignment
  assign in_ready_o   = ~stall_pip;
  assign out_valid_o  = pip4_vld;

  assign tag_o        = pip4_tag;
  assign result_o     = pip4_sqrt7_vld ? pip4_sqrt7_result : pip4_rec7_result;
  assign tbl_status_o = pip4_sqrt7_vld ? pip4_sqrt7_fexp : pip4_rec7_fexp;

  always @(posedge clk or negedge rst_n)
  begin
    if(!rst_n) begin
      pip1_vld		    <='0;
      pip1_sqrt7_vld  <='0;
      pip1_sign       <='0;
      pip1_rnd        <= RVFRM'('0);
      pip1_exp        <='0;
      pip1_man        <='0;
      pip1_subn       <='0;
      pip1_tag        <='0;

      pip2_vld        <='0;
      pip2_sqrt7_vld  <='0;
      pip2_sign       <='0;
      pip2_rnd        <= RVFRM'('0);
      pip2_exp        <='0;
      pip2_man        <='0;
      pip2_infinite   <='0;
      pip2_NaN        <='0;
      pip2_qNaN       <='0;
      pip2_zero       <='0;
      pip2_lead_z_eq_z<='0;
      pip2_tag        <='0;
      pip2_exp_normed <='0;
      pip2_man_index  <='0;

      pip3_vld        <='0;
      pip3_sqrt7_vld  <='0;
      pip3_sign       <='0;
      pip3_rnd        <= RVFRM'('0);
      pip3_exp        <='0;
      pip3_man        <='0;
      pip3_infinite   <='0;
      pip3_NaN        <='0;
      pip3_qNaN       <='0;
      pip3_zero       <='0;
      pip3_sqrt7_exp  <='0;
      pip3_rec7_exp   <='0;
      pip3_sqrt7_man  <='0;
      pip3_rec7_man   <='0;
      pip3_tag        <='0;
                          
      pip4_vld        <='0;
      pip4_sqrt7_vld  <='0;
      pip4_sqrt7_result<= '0;
      pip4_rec7_result<= '0;
      pip4_sqrt7_fexp <= '0;
      pip4_rec7_fexp  <= '0;
      pip4_tag        <='0;
      end
    else begin
      if(flush_i) begin
        pip1_vld        <= 1'b0;
        pip2_vld        <= 1'b0;
        pip3_vld        <= 1'b0;
        pip4_vld        <= 1'b0;
      end
      else if(!stall_pip) begin
        if(invld) begin
        //pipe 1, register all input sginal
          pip1_vld        <= 1'b1;
          pip1_sqrt7_vld  <= !rec7_vld;
          pip1_sign       <= sign_in;
          pip1_rnd        <= rnd_mode_i;
          pip1_exp        <= exp_in;
          pip1_man        <= man_in;
          pip1_subn       <= exp_in == '0 && man_in != '0;
          pip1_tag        <= tag_i;
        end
        else begin
          pip1_vld        <= 1'b0;
        end
        //pip2, get the leading zero cnt of mantissa with registered input, test if data Nan, Normal or not
        pip2_vld          <= pip1_vld;
        pip2_sqrt7_vld    <= pip1_sqrt7_vld;
        pip2_sign         <= pip1_sign;
        pip2_rnd          <= pip1_rnd;
        pip2_exp          <= pip1_exp;
        pip2_man          <= pip1_man;
        pip2_infinite     <= pip1_infinite;
        pip2_NaN          <= pip1_NaN;
        pip2_qNaN         <= pip1_qNaN;
        pip2_zero         <= pip1_zero;
        pip2_lead_z_eq_z  <=(pip1_lead_z == '0);
        pip2_tag          <= pip1_tag;
        pip2_exp_normed   <= pip1_exp_normed;
        pip2_man_index    <= pip1_man_index;
        
        //pip3, get the normalized exponent, expreuslts and significant with registered leading zero cnt
        pip3_vld          <= pip2_vld;
        pip3_sqrt7_vld    <= pip2_sqrt7_vld;
        pip3_sign         <= pip2_sign;
        pip3_rnd          <= pip2_rnd;
        pip3_exp          <= pip2_exp;
        pip3_man          <= pip2_man;
        pip3_infinite     <= pip2_infinite;
        pip3_NaN          <= pip2_NaN;
        pip3_qNaN         <= pip2_qNaN;
        pip3_zero         <= pip2_zero;
        pip3_sqrt7_exp    <= pip2_sqrt7_exp;
        pip3_rec7_exp     <= pip2_rec7_exp;
        pip3_sqrt7_man    <= pip2_sqrt7_man;
        pip3_rec7_man     <= pip2_rec7_man;
        pip3_tag          <= pip2_tag;
      
      //pip4, get the exponent results and search the table
        pip4_vld          <= pip3_vld;
        pip4_sqrt7_vld    <= pip3_sqrt7_vld;
        pip4_sqrt7_result <= {sqrt7_result_sign, sqrt7_result_exp, sqrt7_result_man};
        pip4_rec7_result  <= {rec7_result_sign,  rec7_result_exp,  rec7_result_man};
        pip4_sqrt7_fexp   <= pip3_qNaN? '0: sqrt7_result_excp;
        pip4_rec7_fexp    <= pip3_qNaN? '0: rec7_result_excp;
        pip4_tag          <= pip3_tag;
       end
    end
  end

  //sqrt result
  always_comb
  begin
    sqrt7_result_excp = '0;
    if(pip3_zero) begin//input zero
      sqrt7_result_sign = pip3_sign;
      sqrt7_result_exp  = '1;
      sqrt7_result_man  = '0;
      sqrt7_result_excp.dz = 1'b1;
    end//input zero
    else if(pip3_sign) begin//input negetive
      sqrt7_result_sign = CANO_NAN_SIGN;
      sqrt7_result_exp  = CANO_NAN_EXP;
      sqrt7_result_man  = CANO_NAN_MAN;
      sqrt7_result_excp.nv = 1'b1;
    end
    else if(pip3_infinite) begin//input infinite
      sqrt7_result_sign = pip3_sign;
      sqrt7_result_exp  = '0;
      sqrt7_result_man  = '0;
    end
    else if(pip3_NaN) begin
      sqrt7_result_sign = CANO_NAN_SIGN;
      sqrt7_result_exp  = CANO_NAN_EXP;
      sqrt7_result_man  = CANO_NAN_MAN;
      sqrt7_result_excp.nv = 1'b1;
    end
    else begin//table check
      sqrt7_result_sign = pip3_sign;
      sqrt7_result_exp  = pip3_sqrt7_exp;
      sqrt7_result_man  = {pip3_sqrt7_man, 16'h0};
    end
  end

  //rec7 result
  always_comb
  begin
    rec7_result_excp = '0;
    if(pip3_zero) begin
      rec7_result_sign = pip3_sign;
      rec7_result_exp  = '1;
      rec7_result_man  = '0;
      rec7_result_excp.dz= 1'b1;
    end
    else if(pip3_infinite)begin
      rec7_result_sign = pip3_sign;
      rec7_result_exp  = '0;
      rec7_result_man  = '0;
    end
    else if(pip3_NaN)begin
      rec7_result_sign = CANO_NAN_SIGN;
      rec7_result_exp  = CANO_NAN_EXP;
      rec7_result_man  = CANO_NAN_MAN;
      rec7_result_excp.nv = 1'b1;
    end
    else begin
      if(pip3_exp == 8'b0 && (|pip3_man)) begin //subnormal input
        if(|pip3_man[22:21]) begin
          rec7_result_sign  = pip3_sign;
          rec7_result_exp   = pip3_rec7_exp;
          rec7_result_man   = {pip3_rec7_man, 16'b0};
        end
        else begin
          rec7_result_excp.nx = 1'b1;
          rec7_result_excp.of = 1'b1;
          rec7_result_sign  = pip3_sign;
          if(pip3_sign) begin//negetive subnormal input
            if(pip3_rnd == FRUP || pip3_rnd == FRTZ) begin//output max value
              rec7_result_exp   = 8'b1111_1110;
              rec7_result_man   = '1;
            end
            else begin
              rec7_result_exp  = '1;
              rec7_result_man  = '0;
            end
          end
          else begin//positive subnormal input
            if(pip3_rnd == FRDN || pip3_rnd == FRTZ) begin//output max value
              rec7_result_exp   = 8'b1111_1110;
              rec7_result_man   = '1;
            end
            else begin
              rec7_result_exp  = '1;
              rec7_result_man  = '0;
            end
          end
        end
      end
      else begin//normal input
        if(pip3_rec7_exp_subn) begin
          rec7_result_sign  = pip3_sign;
          rec7_result_exp   = '0;
          rec7_result_man   = pip3_rec7_man_normed;
        end
        else begin
          rec7_result_sign  = pip3_sign;
          rec7_result_exp   = pip3_rec7_exp;
          rec7_result_man   = {pip3_rec7_man, 16'b0};
        end
      end
    end
  end

  always_comb
  begin//sqrt table
    case({pip2_exp_normed[0], pip2_man_index[6:1]})
      {1'b0, 6'd 0}: pip2_sqrt7_man = 7'd52;
      {1'b0, 6'd 1}: pip2_sqrt7_man = 7'd51;
      {1'b0, 6'd 2}: pip2_sqrt7_man = 7'd50;
      {1'b0, 6'd 3}: pip2_sqrt7_man = 7'd48;
      {1'b0, 6'd 4}: pip2_sqrt7_man = 7'd47;
      {1'b0, 6'd 5}: pip2_sqrt7_man = 7'd46;
      {1'b0, 6'd 6}: pip2_sqrt7_man = 7'd44;
      {1'b0, 6'd 7}: pip2_sqrt7_man = 7'd43;
      {1'b0, 6'd 8}: pip2_sqrt7_man = 7'd42;
      {1'b0, 6'd 9}: pip2_sqrt7_man = 7'd41;
      {1'b0, 6'd10}: pip2_sqrt7_man = 7'd40;
      {1'b0, 6'd11}: pip2_sqrt7_man = 7'd39;
      {1'b0, 6'd12}: pip2_sqrt7_man = 7'd38;
      {1'b0, 6'd13}: pip2_sqrt7_man = 7'd36;
      {1'b0, 6'd14}: pip2_sqrt7_man = 7'd35;
      {1'b0, 6'd15}: pip2_sqrt7_man = 7'd34;
      {1'b0, 6'd16}: pip2_sqrt7_man = 7'd33;
      {1'b0, 6'd17}: pip2_sqrt7_man = 7'd32;
      {1'b0, 6'd18}: pip2_sqrt7_man = 7'd31;
      {1'b0, 6'd19}: pip2_sqrt7_man = 7'd30;
      {1'b0, 6'd20}: pip2_sqrt7_man = 7'd30;
      {1'b0, 6'd21}: pip2_sqrt7_man = 7'd29;
      {1'b0, 6'd22}: pip2_sqrt7_man = 7'd28;
      {1'b0, 6'd23}: pip2_sqrt7_man = 7'd27;
      {1'b0, 6'd24}: pip2_sqrt7_man = 7'd26;
      {1'b0, 6'd25}: pip2_sqrt7_man = 7'd25;
      {1'b0, 6'd26}: pip2_sqrt7_man = 7'd24;
      {1'b0, 6'd27}: pip2_sqrt7_man = 7'd23;
      {1'b0, 6'd28}: pip2_sqrt7_man = 7'd23;
      {1'b0, 6'd29}: pip2_sqrt7_man = 7'd22;
      {1'b0, 6'd30}: pip2_sqrt7_man = 7'd21;
      {1'b0, 6'd31}: pip2_sqrt7_man = 7'd20;
      {1'b0, 6'd32}: pip2_sqrt7_man = 7'd19;
      {1'b0, 6'd33}: pip2_sqrt7_man = 7'd19;
      {1'b0, 6'd34}: pip2_sqrt7_man = 7'd18;
      {1'b0, 6'd35}: pip2_sqrt7_man = 7'd17;
      {1'b0, 6'd36}: pip2_sqrt7_man = 7'd16;
      {1'b0, 6'd37}: pip2_sqrt7_man = 7'd16;
      {1'b0, 6'd38}: pip2_sqrt7_man = 7'd15;
      {1'b0, 6'd39}: pip2_sqrt7_man = 7'd14;
      {1'b0, 6'd40}: pip2_sqrt7_man = 7'd14;
      {1'b0, 6'd41}: pip2_sqrt7_man = 7'd13;
      {1'b0, 6'd42}: pip2_sqrt7_man = 7'd12;
      {1'b0, 6'd43}: pip2_sqrt7_man = 7'd12;
      {1'b0, 6'd44}: pip2_sqrt7_man = 7'd11;
      {1'b0, 6'd45}: pip2_sqrt7_man = 7'd10;
      {1'b0, 6'd46}: pip2_sqrt7_man = 7'd10;
      {1'b0, 6'd47}: pip2_sqrt7_man = 7'd9;
      {1'b0, 6'd48}: pip2_sqrt7_man = 7'd9;
      {1'b0, 6'd49}: pip2_sqrt7_man = 7'd8;
      {1'b0, 6'd50}: pip2_sqrt7_man = 7'd7;
      {1'b0, 6'd51}: pip2_sqrt7_man = 7'd7;
      {1'b0, 6'd52}: pip2_sqrt7_man = 7'd6;
      {1'b0, 6'd53}: pip2_sqrt7_man = 7'd6;
      {1'b0, 6'd54}: pip2_sqrt7_man = 7'd5;
      {1'b0, 6'd55}: pip2_sqrt7_man = 7'd4;
      {1'b0, 6'd56}: pip2_sqrt7_man = 7'd4;
      {1'b0, 6'd57}: pip2_sqrt7_man = 7'd3;
      {1'b0, 6'd58}: pip2_sqrt7_man = 7'd3;
      {1'b0, 6'd59}: pip2_sqrt7_man = 7'd2;
      {1'b0, 6'd60}: pip2_sqrt7_man = 7'd2;
      {1'b0, 6'd61}: pip2_sqrt7_man = 7'd1;
      {1'b0, 6'd62}: pip2_sqrt7_man = 7'd1;
      {1'b1, 6'd 0}: pip2_sqrt7_man = 7'd127;
      {1'b1, 6'd 1}: pip2_sqrt7_man = 7'd125;
      {1'b1, 6'd 2}: pip2_sqrt7_man = 7'd123;
      {1'b1, 6'd 3}: pip2_sqrt7_man = 7'd121;
      {1'b1, 6'd 4}: pip2_sqrt7_man = 7'd119;
      {1'b1, 6'd 5}: pip2_sqrt7_man = 7'd118;
      {1'b1, 6'd 6}: pip2_sqrt7_man = 7'd116;
      {1'b1, 6'd 7}: pip2_sqrt7_man = 7'd114;
      {1'b1, 6'd 8}: pip2_sqrt7_man = 7'd113;
      {1'b1, 6'd 9}: pip2_sqrt7_man = 7'd111;
      {1'b1, 6'd10}: pip2_sqrt7_man = 7'd109;
      {1'b1, 6'd11}: pip2_sqrt7_man = 7'd108;
      {1'b1, 6'd12}: pip2_sqrt7_man = 7'd106;
      {1'b1, 6'd13}: pip2_sqrt7_man = 7'd105;
      {1'b1, 6'd14}: pip2_sqrt7_man = 7'd103;
      {1'b1, 6'd15}: pip2_sqrt7_man = 7'd102;
      {1'b1, 6'd16}: pip2_sqrt7_man = 7'd100;
      {1'b1, 6'd17}: pip2_sqrt7_man = 7'd99;
      {1'b1, 6'd18}: pip2_sqrt7_man = 7'd97;
      {1'b1, 6'd19}: pip2_sqrt7_man = 7'd96;
      {1'b1, 6'd20}: pip2_sqrt7_man = 7'd95;
      {1'b1, 6'd21}: pip2_sqrt7_man = 7'd93;
      {1'b1, 6'd22}: pip2_sqrt7_man = 7'd92;
      {1'b1, 6'd23}: pip2_sqrt7_man = 7'd91;
      {1'b1, 6'd24}: pip2_sqrt7_man = 7'd90;
      {1'b1, 6'd25}: pip2_sqrt7_man = 7'd88;
      {1'b1, 6'd26}: pip2_sqrt7_man = 7'd87;
      {1'b1, 6'd27}: pip2_sqrt7_man = 7'd86;
      {1'b1, 6'd28}: pip2_sqrt7_man = 7'd85;
      {1'b1, 6'd29}: pip2_sqrt7_man = 7'd84;
      {1'b1, 6'd30}: pip2_sqrt7_man = 7'd83;
      {1'b1, 6'd31}: pip2_sqrt7_man = 7'd82;
      {1'b1, 6'd32}: pip2_sqrt7_man = 7'd80;
      {1'b1, 6'd33}: pip2_sqrt7_man = 7'd79;
      {1'b1, 6'd34}: pip2_sqrt7_man = 7'd78;
      {1'b1, 6'd35}: pip2_sqrt7_man = 7'd77;
      {1'b1, 6'd36}: pip2_sqrt7_man = 7'd76;
      {1'b1, 6'd37}: pip2_sqrt7_man = 7'd75;
      {1'b1, 6'd38}: pip2_sqrt7_man = 7'd74;
      {1'b1, 6'd39}: pip2_sqrt7_man = 7'd73;
      {1'b1, 6'd40}: pip2_sqrt7_man = 7'd72;
      {1'b1, 6'd41}: pip2_sqrt7_man = 7'd71;
      {1'b1, 6'd42}: pip2_sqrt7_man = 7'd70;
      {1'b1, 6'd43}: pip2_sqrt7_man = 7'd70;
      {1'b1, 6'd44}: pip2_sqrt7_man = 7'd69;
      {1'b1, 6'd45}: pip2_sqrt7_man = 7'd68;
      {1'b1, 6'd46}: pip2_sqrt7_man = 7'd67;
      {1'b1, 6'd47}: pip2_sqrt7_man = 7'd66;
      {1'b1, 6'd48}: pip2_sqrt7_man = 7'd65;
      {1'b1, 6'd49}: pip2_sqrt7_man = 7'd64;
      {1'b1, 6'd50}: pip2_sqrt7_man = 7'd63;
      {1'b1, 6'd51}: pip2_sqrt7_man = 7'd63;
      {1'b1, 6'd52}: pip2_sqrt7_man = 7'd62;
      {1'b1, 6'd53}: pip2_sqrt7_man = 7'd61;
      {1'b1, 6'd54}: pip2_sqrt7_man = 7'd60;
      {1'b1, 6'd55}: pip2_sqrt7_man = 7'd59;
      {1'b1, 6'd56}: pip2_sqrt7_man = 7'd59;
      {1'b1, 6'd57}: pip2_sqrt7_man = 7'd58;
      {1'b1, 6'd58}: pip2_sqrt7_man = 7'd57;
      {1'b1, 6'd59}: pip2_sqrt7_man = 7'd56;
      {1'b1, 6'd60}: pip2_sqrt7_man = 7'd56;
      {1'b1, 6'd61}: pip2_sqrt7_man = 7'd55;
      {1'b1, 6'd62}: pip2_sqrt7_man = 7'd54;
      {1'b1, 6'd63}: pip2_sqrt7_man = 7'd53;
      default:       pip2_sqrt7_man = 7'd0;
    endcase
  end

  always_comb
  begin
    case(pip2_man_index)
      7'd  0: pip2_rec7_man = 7'd127;
      7'd  1: pip2_rec7_man = 7'd125;
      7'd  2: pip2_rec7_man = 7'd123;
      7'd  3: pip2_rec7_man = 7'd121;
      7'd  4: pip2_rec7_man = 7'd119;
      7'd  5: pip2_rec7_man = 7'd117;
      7'd  6: pip2_rec7_man = 7'd116;
      7'd  7: pip2_rec7_man = 7'd114;
      7'd  8: pip2_rec7_man = 7'd112;
      7'd  9: pip2_rec7_man = 7'd110;
      7'd 10: pip2_rec7_man = 7'd109;
      7'd 11: pip2_rec7_man = 7'd107;
      7'd 12: pip2_rec7_man = 7'd105;
      7'd 13: pip2_rec7_man = 7'd104;
      7'd 14: pip2_rec7_man = 7'd102;
      7'd 15: pip2_rec7_man = 7'd100;
      7'd 16: pip2_rec7_man = 7'd99;
      7'd 17: pip2_rec7_man = 7'd97;
      7'd 18: pip2_rec7_man = 7'd96;
      7'd 19: pip2_rec7_man = 7'd94;
      7'd 20: pip2_rec7_man = 7'd93;
      7'd 21: pip2_rec7_man = 7'd91;
      7'd 22: pip2_rec7_man = 7'd90;
      7'd 23: pip2_rec7_man = 7'd88;
      7'd 24: pip2_rec7_man = 7'd87;
      7'd 25: pip2_rec7_man = 7'd85;
      7'd 26: pip2_rec7_man = 7'd84;
      7'd 27: pip2_rec7_man = 7'd83;
      7'd 28: pip2_rec7_man = 7'd81;
      7'd 29: pip2_rec7_man = 7'd80;
      7'd 30: pip2_rec7_man = 7'd79;
      7'd 31: pip2_rec7_man = 7'd77;
      7'd 32: pip2_rec7_man = 7'd76;
      7'd 33: pip2_rec7_man = 7'd75;
      7'd 34: pip2_rec7_man = 7'd74;
      7'd 35: pip2_rec7_man = 7'd72;
      7'd 36: pip2_rec7_man = 7'd71;
      7'd 37: pip2_rec7_man = 7'd70;
      7'd 38: pip2_rec7_man = 7'd69;
      7'd 39: pip2_rec7_man = 7'd68;
      7'd 40: pip2_rec7_man = 7'd66;
      7'd 41: pip2_rec7_man = 7'd65;
      7'd 42: pip2_rec7_man = 7'd64;
      7'd 43: pip2_rec7_man = 7'd63;
      7'd 44: pip2_rec7_man = 7'd62;
      7'd 45: pip2_rec7_man = 7'd61;
      7'd 46: pip2_rec7_man = 7'd60;
      7'd 47: pip2_rec7_man = 7'd59;
      7'd 48: pip2_rec7_man = 7'd58;
      7'd 49: pip2_rec7_man = 7'd57;
      7'd 50: pip2_rec7_man = 7'd56;
      7'd 51: pip2_rec7_man = 7'd55;
      7'd 52: pip2_rec7_man = 7'd54;
      7'd 53: pip2_rec7_man = 7'd53;
      7'd 54: pip2_rec7_man = 7'd52;
      7'd 55: pip2_rec7_man = 7'd51;
      7'd 56: pip2_rec7_man = 7'd50;
      7'd 57: pip2_rec7_man = 7'd49;
      7'd 58: pip2_rec7_man = 7'd48;
      7'd 59: pip2_rec7_man = 7'd47;
      7'd 60: pip2_rec7_man = 7'd46;
      7'd 61: pip2_rec7_man = 7'd45;
      7'd 62: pip2_rec7_man = 7'd44;
      7'd 63: pip2_rec7_man = 7'd43;
      7'd 64: pip2_rec7_man = 7'd42;
      7'd 65: pip2_rec7_man = 7'd41;
      7'd 66: pip2_rec7_man = 7'd40;
      7'd 67: pip2_rec7_man = 7'd40;
      7'd 68: pip2_rec7_man = 7'd39;
      7'd 69: pip2_rec7_man = 7'd38;
      7'd 70: pip2_rec7_man = 7'd37;
      7'd 71: pip2_rec7_man = 7'd36;
      7'd 72: pip2_rec7_man = 7'd35;
      7'd 73: pip2_rec7_man = 7'd35;
      7'd 74: pip2_rec7_man = 7'd34;
      7'd 75: pip2_rec7_man = 7'd33;
      7'd 76: pip2_rec7_man = 7'd32;
      7'd 77: pip2_rec7_man = 7'd31;
      7'd 78: pip2_rec7_man = 7'd31;
      7'd 79: pip2_rec7_man = 7'd30;
      7'd 80: pip2_rec7_man = 7'd29;
      7'd 81: pip2_rec7_man = 7'd28;
      7'd 82: pip2_rec7_man = 7'd28;
      7'd 83: pip2_rec7_man = 7'd27;
      7'd 84: pip2_rec7_man = 7'd26;
      7'd 85: pip2_rec7_man = 7'd25;
      7'd 86: pip2_rec7_man = 7'd25;
      7'd 87: pip2_rec7_man = 7'd24;
      7'd 88: pip2_rec7_man = 7'd23;
      7'd 89: pip2_rec7_man = 7'd23;
      7'd 90: pip2_rec7_man = 7'd22;
      7'd 91: pip2_rec7_man = 7'd21;
      7'd 92: pip2_rec7_man = 7'd21;
      7'd 93: pip2_rec7_man = 7'd20;
      7'd 94: pip2_rec7_man = 7'd19;
      7'd 95: pip2_rec7_man = 7'd19;
      7'd 96: pip2_rec7_man = 7'd18;
      7'd 97: pip2_rec7_man = 7'd17;
      7'd 98: pip2_rec7_man = 7'd17;
      7'd 99: pip2_rec7_man = 7'd16;
      7'd100: pip2_rec7_man = 7'd15;
      7'd101: pip2_rec7_man = 7'd15;
      7'd102: pip2_rec7_man = 7'd14;
      7'd103: pip2_rec7_man = 7'd14;
      7'd104: pip2_rec7_man = 7'd13;
      7'd105: pip2_rec7_man = 7'd12;
      7'd106: pip2_rec7_man = 7'd12;
      7'd107: pip2_rec7_man = 7'd11;
      7'd108: pip2_rec7_man = 7'd11;
      7'd109: pip2_rec7_man = 7'd10;
      7'd110: pip2_rec7_man = 7'd9;
      7'd111: pip2_rec7_man = 7'd9;
      7'd112: pip2_rec7_man = 7'd8;
      7'd113: pip2_rec7_man = 7'd8;
      7'd114: pip2_rec7_man = 7'd7;
      7'd115: pip2_rec7_man = 7'd7;
      7'd116: pip2_rec7_man = 7'd6;
      7'd117: pip2_rec7_man = 7'd5;
      7'd118: pip2_rec7_man = 7'd5;
      7'd119: pip2_rec7_man = 7'd4;
      7'd120: pip2_rec7_man = 7'd4;
      7'd121: pip2_rec7_man = 7'd3;
      7'd122: pip2_rec7_man = 7'd3;
      7'd123: pip2_rec7_man = 7'd2;
      7'd124: pip2_rec7_man = 7'd2;
      7'd125: pip2_rec7_man = 7'd1;
      7'd126: pip2_rec7_man = 7'd1;
      default:pip2_rec7_man = 7'd0;
    endcase
  end

  function [6:0] man7_normed(
    input         subn,
    input  [7:0]  exp,
    input [22:0]  man
  );

    logic [ 7:0]  subn_sft_cnt;
    logic [22:0]  man_shifted;


    begin
      subn_sft_cnt= 8'b1 - exp;
      man_shifted = man << subn_sft_cnt;
      man7_normed = subn? man_shifted[22-:7]: man[22-:7];
    end
  endfunction

  function [4:0] leading_zero_cnt(
    input [22:0] mantissa
  );
    logic [11:0] level1_data;
    logic [ 5:0] level2_data;
    logic [ 2:0] level3_data;
    logic [ 1:0] level4_adder;

    logic level1_add;
    logic level2_add;
    logic level3_add;

    begin

      level1_add = !(|mantissa[22:11]);
      level1_data =    (|mantissa[22:11])? mantissa[22:11]: mantissa[11:0];

      level2_add = !(  |level1_data[11: 6]);
      level2_data = (|level1_data[11: 6])? level1_data[11: 6]: level1_data[ 5:0];

      level3_add = !(  |level2_data[ 5: 3]);
      level3_data = (|level2_data[ 5: 3])? level2_data[ 5: 3]: level2_data[ 2:0];

      if(level3_data[2])
        level4_adder = 2'b00;
      else if(level3_data[1])
        level4_adder = 2'b01;
      else
        level4_adder = 2'b10;

      leading_zero_cnt = ({5{level1_add}} & 5'd11)+ 
                         ({5{level2_add}} & 5'd6) +
                         ({5{level3_add}} & 5'd3) +
                         level4_adder;
    end
    
  endfunction
endmodule
