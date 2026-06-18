`ifndef HDL_VERILOG_RVV_DESIGN_RVV_SVH
`include "rvv_backend.svh"
`endif

// TODO: tail process.

module zvt_pe_array (
  clk,
  rst_n,
  peCmdVld,
  peCmd,
  peCmdRdy,
  readAccIdx,
  readSubIdx,
  readData,
  writeEn,  
  writeAccIdx,
  writeSubIdx,
  writeData,
  fpexpVld,
  fpexp,
  fpexpRdy,
  flush,
  busy
);

// interface signals
  input  logic                              clk;
  input  logic                              rst_n;
  // Command
  input  logic    [`ZVT_LMUL-1:0]           peCmdVld;
  input  ZVT_RS_t [`ZVT_LMUL-1:0]           peCmd;
  output logic    [`ZVT_LMUL-1:0]           peCmdRdy;
  // ACC accessing
  output logic [`NUM_BLK-1:0][`NUM_BLKPORT-1:0][$clog2(`NUM_ACC)-1:0]     readAccIdx;
  output logic [`NUM_BLK-1:0][`NUM_BLKPORT-1:0][$clog2(`NUM_SUBTILE)-1:0] readSubIdx;
  input  logic [`NUM_BLK-1:0][`NUM_BLKPORT-1:0][`SUBTILE_SIZE*8-1:0]      readData;  
  output logic [`NUM_BLK-1:0][`NUM_BLKPORT-1:0][`SUBTILE_SIZE-1:0]        writeEn;  
  output logic [`NUM_BLK-1:0][`NUM_BLKPORT-1:0][$clog2(`NUM_ACC)-1:0]     writeAccIdx;
  output logic [`NUM_BLK-1:0][`NUM_BLKPORT-1:0][$clog2(`NUM_SUBTILE)-1:0] writeSubIdx;
  output logic [`NUM_BLK-1:0][`NUM_BLKPORT-1:0][`SUBTILE_SIZE*8-1:0]      writeData;  
  // floating-point status
  output logic                              fpexpVld;
  output RVFEXP_t                           fpexp;
  input  logic                              fpexpRdy;
  // control&status  
  input  logic                              flush;
  output logic                              busy;

// -------------- code start --------------------
  // source operands
  logic [`TE-1:0]                           tail_tm, tail_tm_tmp;
  logic [`TE-1:0]                           tail_tn, tail_tn_tmp;
  logic [`TE/2-1:0][`WORD_WIDTH-1:0]        vaGroupLo, vaGroupHi;
  logic [`TE/2-1:0][3:0]                    vaMaskLo, vaMaskHi;  
  logic [`TE/2-1:0][`WORD_WIDTH-1:0]        vbGroupLo, vbGroupHi;
  logic [`TE/2-1:0][3:0]                    vbMaskLo, vbMaskHi; 

  barrel_shifter #(.DATA_WIDTH(`TE)) 
    tm_tail (.din((`TE)'('1)), .shift_amount(peCmd[0].tm[$clog2(`TE)-1:0]), .shift_mode(2'b00), .dout(tail_tm_tmp));
  barrel_shifter #(.DATA_WIDTH(`TE)) 
    tn_tail (.din((`TE)'('1)), .shift_amount(peCmd[0].vl[$clog2(`TE)-1:0]), .shift_mode(2'b00), .dout(tail_tn_tmp));

  assign tail_tm = {`TE{!peCmd[0].tm[$clog2(`TE)]}} & tail_tm_tmp;
  assign tail_tn = {`TE{!peCmd[0].vl[$clog2(`TE)]}} & tail_tn_tmp;

  always_comb begin
    for(int i=0; i<`TE/2; i++) begin
      vaMaskLo[i] = {4{!tail_tm[i]}};
      vbMaskLo[i] = {4{!tail_tn[i]}};
      vaMaskHi[i] = {4{!tail_tm[i+`TE/2]}};
      vbMaskHi[i] = {4{!tail_tn[i+`TE/2]}};

      case(peCmd[0].sew)
        SEW16: begin
          if(peCmd[0].tk==3'd1)
          vaMaskLo[i] = {2'b0, {2{!tail_tm[i]}}};
          vbMaskLo[i] = {2'b0, {2{!tail_tn[i]}}};
          vaMaskHi[i] = {2'b0, {2{!tail_tm[i+`TE/2]}}};
          vbMaskHi[i] = {2'b0, {2{!tail_tn[i+`TE/2]}}};
        end
        SEW8: begin
          if(peCmd[0].tk==3'd1) begin
            vaMaskLo[i] = {3'b0, {!tail_tm[i]}};
            vbMaskLo[i] = {3'b0, {!tail_tn[i]}};
            vaMaskHi[i] = {3'b0, {!tail_tm[i+`TE/2]}};
            vbMaskHi[i] = {3'b0, {!tail_tn[i+`TE/2]}};
          end
          else if(peCmd[0].tk==3'd2) begin
            vaMaskLo[i] = {2'b0, {2{!tail_tm[i]}}};
            vbMaskLo[i] = {2'b0, {2{!tail_tn[i]}}};
            vaMaskHi[i] = {2'b0, {2{!tail_tm[i+`TE/2]}}};
            vbMaskHi[i] = {2'b0, {2{!tail_tn[i+`TE/2]}}};
          end
          else if(peCmd[0].tk==3'd3) begin
            vaMaskLo[i] = {1'b0, {3{!tail_tm[i]}}};
            vbMaskLo[i] = {1'b0, {3{!tail_tn[i]}}};
            vaMaskHi[i] = {1'b0, {3{!tail_tm[i+`TE/2]}}};
            vbMaskHi[i] = {1'b0, {3{!tail_tn[i+`TE/2]}}};
          end
        end
      endcase
    end
  end

  always_comb begin
    case(peCmd[0].sew)
      SEW8: begin
        for(int i=0; i<`TE/2; i++) begin
          vaGroupLo[i] = {peCmd[3].vs2_data[i*`BYTE_WIDTH+:`BYTE_WIDTH],
                          peCmd[2].vs2_data[i*`BYTE_WIDTH+:`BYTE_WIDTH],
                          peCmd[1].vs2_data[i*`BYTE_WIDTH+:`BYTE_WIDTH],
                          peCmd[0].vs2_data[i*`BYTE_WIDTH+:`BYTE_WIDTH]};
          vbGroupLo[i] = {peCmd[3].vs1_data[i*`BYTE_WIDTH+:`BYTE_WIDTH],
                          peCmd[2].vs1_data[i*`BYTE_WIDTH+:`BYTE_WIDTH],
                          peCmd[1].vs1_data[i*`BYTE_WIDTH+:`BYTE_WIDTH],
                          peCmd[0].vs1_data[i*`BYTE_WIDTH+:`BYTE_WIDTH]};

          vaGroupHi[i] = {peCmd[3].vs2_data[(i+`TE/2)*`BYTE_WIDTH+:`BYTE_WIDTH],
                          peCmd[2].vs2_data[(i+`TE/2)*`BYTE_WIDTH+:`BYTE_WIDTH],
                          peCmd[1].vs2_data[(i+`TE/2)*`BYTE_WIDTH+:`BYTE_WIDTH],
                          peCmd[0].vs2_data[(i+`TE/2)*`BYTE_WIDTH+:`BYTE_WIDTH]};
          vbGroupHi[i] = {peCmd[3].vs1_data[(i+`TE/2)*`BYTE_WIDTH+:`BYTE_WIDTH],
                          peCmd[2].vs1_data[(i+`TE/2)*`BYTE_WIDTH+:`BYTE_WIDTH],
                          peCmd[1].vs1_data[(i+`TE/2)*`BYTE_WIDTH+:`BYTE_WIDTH],
                          peCmd[0].vs1_data[(i+`TE/2)*`BYTE_WIDTH+:`BYTE_WIDTH]};
        end
      end
      SEW16: begin
        for(int i=0; i<`TE/2; i++) begin
          vaGroupLo[i] = {peCmd[2].vs2_data[i*`HWORD_WIDTH+:`HWORD_WIDTH],
                          peCmd[0].vs2_data[i*`HWORD_WIDTH+:`HWORD_WIDTH]};
          vbGroupLo[i] = {peCmd[2].vs1_data[i*`HWORD_WIDTH+:`HWORD_WIDTH],
                          peCmd[0].vs1_data[i*`HWORD_WIDTH+:`HWORD_WIDTH]};

          vaGroupHi[i] = {peCmd[3].vs2_data[i*`HWORD_WIDTH+:`HWORD_WIDTH],
                          peCmd[1].vs2_data[i*`HWORD_WIDTH+:`HWORD_WIDTH]};
          vbGroupHi[i] = {peCmd[3].vs1_data[i*`HWORD_WIDTH+:`HWORD_WIDTH],
                          peCmd[1].vs1_data[i*`HWORD_WIDTH+:`HWORD_WIDTH]};            
        end         
      end
      // SEW32
      default: begin    
        vaGroupHi = {peCmd[3].vs2_data,
                     peCmd[2].vs2_data};
        vaGroupLo = {peCmd[1].vs2_data,
                     peCmd[0].vs2_data};

        vbGroupHi = {peCmd[3].vs1_data,
                     peCmd[2].vs1_data};
        vbGroupLo = {peCmd[1].vs1_data,
                     peCmd[0].vs1_data};
      end
    endcase
  end
  
  // control logic
  logic                               canStart;
  logic [$clog2(`TE):0]               tmsub1, tnsub1;
  logic [$clog2(`PROCESS_DELAY)-1:0]  cnt, cntMax00, cntMax10;
  logic                               cntEn, cntCr;
  logic                               vaHiActive, vbHiActive;
  logic                               pipeLaEn, pipeHa0En, pipeHa1En, pipeLbEn, pipeHb0En, pipeHb1En;
  logic                               pipeLaRdy, pipeHa0Rdy, pipeHa1Rdy, pipeLbRdy, pipeHb0Rdy, pipeHb1Rdy;
  logic                               pipeLaVld, pipeHa0Vld, pipeHa1Vld, pipeLbVld, pipeHb0Vld, pipeHb1Vld;

  // ready to start up. 
  assign canStart = &peCmdVld[3:0] && peCmd[0].first_uop_valid && peCmd[3].last_uop_valid;
  assign peCmdRdy = {4{canStart && cntCr}};

  // counter
  cdffr #(.T(logic [$clog2(`PROCESS_DELAY)-1:0]))
  counter (.q(cnt), .clk(clk), .rst_n(rst_n), .e(cntEn), .c(cntCr), .d(cnt+($clog2(`PROCESS_DELAY))'('d1)));
  
  assign tmsub1   = peCmd[0].tm-'d1;
  assign tnsub1   = peCmd[0].vl-'d1;
  assign cntMax00 = tmsub1[$clog2(`TE)-1] ? ($clog2(`PROCESS_DELAY))'(`PROCESS_DELAY-1) : tmsub1[$clog2(`TE/2)-1:$clog2(`TE/2*`COMPRATIO)];
  assign cntCr    = cnt == cntMax00;
  assign cntEn    = canStart && &{pipeLaRdy, pipeHa0Rdy, pipeHa1Rdy, pipeLbRdy, pipeHb0Rdy, pipeHb1Rdy};

  // 01
  assign vbHiActive = tnsub1[$clog2(`TE)-1];
  assign pipeLaEn   = canStart & vbHiActive;
  assign pipeHb0En  = canStart & (cnt=='d0) & vbHiActive;
  // 10
  assign vaHiActive = tmsub1[$clog2(`TE)-1];
  assign cntMax10   = tmsub1[$clog2(`TE/2)-1:$clog2(`TE/2*`COMPRATIO)];
  assign pipeHa0En  = canStart & vaHiActive & (cnt<=cntMax10);
  assign pipeLbEn   = canStart & vaHiActive & (cnt=='d0);
  // 11
  assign pipeHa1En  = pipeHa0Vld & pipeHb0Vld;
  assign pipeHb1En  = pipeHa0Vld & pipeHb0Vld & (cnt=='d1);

  // information
  PEVAINFO_t            vaInfoLo, vaInfoHi, vaInfoLoD1, vaInfoHiD1, vaInfoHiD2;
  PEVBINFO_t            vbInfoLo, vbInfoHi, vbInfoLoD1, vbInfoHiD1, vbInfoHiD2;
  logic     [1:0][1:0]  blkCmdVld;
  BLKCMD_t  [1:0][1:0]  blkCmd;
  logic     [3:0]       blkCmdRdy;

`ifdef TB_SUPPORT
  assign vaInfoLo.uop_pc = peCmd[0].uop_pc;
  assign vaInfoHi.uop_pc = peCmd[0].uop_pc;
`endif 
  assign vaInfoLo.rndMode    = peCmd[0].rndMode;
  assign vaInfoHi.rndMode    = peCmd[0].rndMode;
  assign vaInfoLo.readAccIdx = peCmd[0].dst_index[4:1];
  assign vaInfoHi.readAccIdx = peCmd[0].dst_index[4:1];
  assign vaInfoLo.readAccId  = cnt;
  assign vaInfoHi.readAccId  = cnt;

  always_comb begin
    vaInfoLo.op       = INTMUL;
    vaInfoHi.op       = INTMUL;
    vaInfoLo.opMod    = 'b0;
    vaInfoHi.opMod    = 'b0;
    vaInfoLo.fsrcFmt  = fpnew_pkg::FP32;
    vaInfoHi.fsrcFmt  = fpnew_pkg::FP32;
    vaInfoLo.isrcFmt  = fpnew_pkg::INT32;
    vaInfoHi.isrcFmt  = fpnew_pkg::INT32;
    vaInfoLo.fdstFmt  = fpnew_pkg::FP32;
    vaInfoHi.fdstFmt  = fpnew_pkg::FP32;
    vaInfoLo.idstFmt  = fpnew_pkg::INT32;
    vaInfoHi.idstFmt  = fpnew_pkg::INT32;

    case(peCmd[0].uop_funct3)
      OPIVV: begin
        vaInfoLo.op       = peCmd[0].dst_index[0] ? INTMUL : UINTMUL;
        vaInfoHi.op       = peCmd[0].dst_index[0] ? INTMUL : UINTMUL;
        vaInfoLo.opMod    = peCmd[0].altfmt;
        vaInfoHi.opMod    = peCmd[0].altfmt;
      `ifdef ZVTI16I32_ON
        vaInfoLo.isrcFmt  = peCmd[0].sew==SEW16 ? fpnew_pkg::INT16 : fpnew_pkg::INT8;
        vaInfoHi.isrcFmt  = peCmd[0].sew==SEW16 ? fpnew_pkg::INT16 : fpnew_pkg::INT8;
      `else
        vaInfoLo.isrcFmt  = fpnew_pkg::INT8;
        vaInfoHi.isrcFmt  = fpnew_pkg::INT8;
      `endif
        vaInfoLo.idstFmt  = fpnew_pkg::INT32;
        vaInfoHi.idstFmt  = fpnew_pkg::INT32;        
      end
      OPFVV: begin
        vaInfoLo.op       = FPMUL;
        vaInfoHi.op       = FPMUL;
        vaInfoLo.fsrcFmt  = peCmd[0].sew==SEW16 ? fpnew_pkg::FP16ALT : fpnew_pkg::FP32;
        vaInfoHi.fsrcFmt  = peCmd[0].sew==SEW16 ? fpnew_pkg::FP16ALT : fpnew_pkg::FP32;
        vaInfoLo.fdstFmt  = fpnew_pkg::FP32;
        vaInfoHi.fdstFmt  = fpnew_pkg::FP32;
      end
    endcase
  end
  
  assign vaInfoLo.va     = vaGroupLo;
  assign vaInfoLo.vaMask = vaMaskLo;
  assign vbInfoLo.vb     = vbGroupLo;
  assign vbInfoLo.vbMask = vbMaskLo;
  assign vaInfoHi.va     = vaGroupHi;
  assign vaInfoHi.vaMask = vaMaskHi;
  assign vbInfoHi.vb     = vbGroupHi;
  assign vbInfoHi.vbMask = vbMaskHi;

  handshake_ff #(
    .T          (PEVAINFO_t)
  ) pipeLa (
    .indata     (vaInfoLo),
    .invalid    (pipeLaEn),
    .inready    (pipeLaRdy),
    .outdata    (vaInfoLoD1),
    .outvalid   (pipeLaVld),
    .outready   (&blkCmdRdy),
    .c          (flush),
    .clk        (clk), 
    .rst_n      (rst_n)
  );
  
  handshake_ff #(
    .T          (PEVAINFO_t)
  ) pipeHa0 (
    .indata     (vaInfoHi),
    .invalid    (pipeHa0En),
    .inready    (pipeHa0Rdy),
    .outdata    (vaInfoHiD1),
    .outvalid   (pipeHa0Vld),
    .outready   (&blkCmdRdy),
    .c          (flush),
    .clk        (clk), 
    .rst_n      (rst_n)
  );

  handshake_ff #(
    .T          (PEVAINFO_t)
  ) pipeHa1 (
    .indata     (vaInfoHiD1),
    .invalid    (pipeHa1En),
    .inready    (pipeHa1Rdy),
    .outdata    (vaInfoHiD2),
    .outvalid   (pipeHa1Vld),
    .outready   (&blkCmdRdy),
    .c          (flush),
    .clk        (clk), 
    .rst_n      (rst_n)
  );

  handshake_ff #(
    .T          (PEVBINFO_t)
  ) pipeLb (
    .indata     (vbInfoLo),
    .invalid    (pipeLbEn),
    .inready    (pipeLbRdy),
    .outdata    (vbInfoLoD1),
    .outvalid   (pipeLbVld),
    .outready   (&blkCmdRdy),
    .c          (flush),
    .clk        (clk), 
    .rst_n      (rst_n)
  );
  
  handshake_ff #(
    .T          (PEVBINFO_t)
  ) pipeHb0 (
    .indata     (vbInfoHi),
    .invalid    (pipeHb0En),
    .inready    (pipeHb0Rdy),
    .outdata    (vbInfoHiD1),
    .outvalid   (pipeHb0Vld),
    .outready   (&blkCmdRdy),
    .c          (flush),
    .clk        (clk), 
    .rst_n      (rst_n)
  );

  handshake_ff #(
    .T          (PEVBINFO_t)
  ) pipeHb1 (
    .indata     (vbInfoHiD1),
    .invalid    (pipeHb1En),
    .inready    (pipeHb1Rdy),
    .outdata    (vbInfoHiD2),
    .outvalid   (pipeHb1Vld),
    .outready   (&blkCmdRdy),
    .c          (flush),
    .clk        (clk), 
    .rst_n      (rst_n)
  );

  assign blkCmdVld[0][0] = canStart;
  assign blkCmdVld[0][1] = pipeLaVld && pipeHb0Vld;
  assign blkCmdVld[1][0] = pipeHa0Vld && pipeLbVld;
  assign blkCmdVld[1][1] = pipeHa1Vld && pipeHb1Vld;

  assign blkCmd[0][0].vaInfo = vaInfoLo;
  assign blkCmd[0][0].vbInfo = vbInfoLo;
  assign blkCmd[0][1].vaInfo = vaInfoLoD1;
  assign blkCmd[0][1].vbInfo = vbInfoHiD1;
  assign blkCmd[1][0].vaInfo = vaInfoHiD1;
  assign blkCmd[1][0].vbInfo = vbInfoLoD1;
  assign blkCmd[1][1].vaInfo = vaInfoHiD2;
  assign blkCmd[1][1].vbInfo = vbInfoHiD2;

// pe block
  logic     [1:0][1:0] hitBlkRaw;
  logic                rawStall;
  logic     [1:0][1:0] fpexpBlkVld;
  RVFEXP_t  [1:0][1:0] fpexpBlk;
  logic     [1:0][1:0] blkBusy;

  assign rawStall = |hitBlkRaw;

  for(genvar i=0; i<2; i++) begin: peBlkRow
    for(genvar j=0; j<2; j++) begin: peBlkCol
      localparam BLKID = {i[0], j[0]};

      zvt_pe_block #(
        .REMVPIPEBUBB   (1),
        .MULBULKPIPENUM (32'd3),
        .ADDERPIPENUM   (32'd3),
        .BLKID          (BLKID)
      ) peBlock (
        .clk            (clk),
        .rst_n          (rst_n),
        .blkCmdVld      (blkCmdVld[i][j]),
        .blkCmd         (blkCmd[i][j]),
        .blkCmdRdy      (blkCmdRdy[BLKID]),
        .hitBlkRaw      (hitBlkRaw[i][j]),
        .rawStall       (rawStall),
        .readAccIdx     (readAccIdx[BLKID]),
        .readSubIdx     (readSubIdx[BLKID]),
        .readData       (readData[BLKID]),  
        .writeEn        (writeEn[BLKID]),  
        .writeAccIdx    (writeAccIdx[BLKID]),
        .writeSubIdx    (writeSubIdx[BLKID]),
        .writeData      (writeData[BLKID]),  
        .fpexpVld       (fpexpBlkVld[i][j]),
        .fpexp          (fpexpBlk[i][j]),
        .fpexpRdy       (fpexpRdy),
        .flush          (flush),
        .busy           (blkBusy[i][j])
      );
    end
  end

// floating-point exceptions.
  always_comb begin
    fpexpVld = |fpexpBlkVld;
    fpexp    = 'b0;

    for(int i=0; i<2; i++) begin
      for(int j=0; j<2; j++) begin
        fpexp.of = fpexp.of | fpexpBlkVld[i][j] && (fpexpBlk[i][j].of);
        fpexp.nv = fpexp.nv | fpexpBlkVld[i][j] && (fpexpBlk[i][j].nv);
      end
    end
  end

// busy
  assign busy = |blkBusy;

endmodule
