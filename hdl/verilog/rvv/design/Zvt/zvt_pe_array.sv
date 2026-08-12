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
  readMtIdx,
  readSubIdx,
  readData,
  writeEn,  
  writeMtIdx,
  writeSubIdx,
  writeData,
  fpexpVld,
  fpexp,
  fpexpRdy,
  peRtVld,
`ifdef RVVI_ON
  peRtMtIdx,
`endif
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
  // MT accessing
  output logic [`NUM_BLK-1:0][`NUM_BLKPORT-1:0][$clog2(`NUM_MT)-1:0]      readMtIdx;
  output logic [`NUM_BLK-1:0][`NUM_BLKPORT-1:0][$clog2(`NUM_SUBTILE)-1:0] readSubIdx;
  input  logic [`NUM_BLK-1:0][`NUM_BLKPORT-1:0][`SUBTILE_SIZE*8-1:0]      readData;  
  output logic [`NUM_BLK-1:0][`NUM_BLKPORT-1:0][`SUBTILE_SIZE-1:0]        writeEn;  
  output logic [`NUM_BLK-1:0][`NUM_BLKPORT-1:0][$clog2(`NUM_MT)-1:0]      writeMtIdx;
  output logic [`NUM_BLK-1:0][`NUM_BLKPORT-1:0][$clog2(`NUM_SUBTILE)-1:0] writeSubIdx;
  output logic [`NUM_BLK-1:0][`NUM_BLKPORT-1:0][`SUBTILE_SIZE*8-1:0]      writeData;  
  // floating-point status
  output logic                              fpexpVld;
  output RVFEXP_t                           fpexp;
  input  logic                              fpexpRdy;
  // retiring informaiton
  output logic [`NUM_BLK-1:0]               peRtVld;
`ifdef RVVI_ON
  output logic [`NUM_BLK-1:0][$clog2(`NUM_MT)-1:0] peRtMtIdx;
`endif
  // control&status  
  input  logic                              flush;
  output logic                              busy;

// -------------- code start --------------------
  // source operands
  logic [`TE-1:0]                    tailTm, tailTmTmp;
  logic [`TE-1:0]                    tailTn, tailTnTmp;
  logic [`TE/2-1:0][`WORD_WIDTH-1:0] vaGroupLo, vaGroupHi;
  logic [`TE/2-1:0][3:0]             vaMaskLo, vaMaskHi;  
  logic [`TE/2-1:0][`WORD_WIDTH-1:0] vbGroupLo, vbGroupHi;
  logic [`TE/2-1:0][3:0]             vbMaskLo, vbMaskHi; 

  barrel_shifter #(.DATA_WIDTH(`TE)) 
    tm_tail (.din((`TE)'('1)), .shift_amount(peCmd[0].tm[$clog2(`TE)-1:0]), .shift_mode(2'b00), .dout(tailTmTmp));
  barrel_shifter #(.DATA_WIDTH(`TE)) 
    tn_tail (.din((`TE)'('1)), .shift_amount(peCmd[0].vl[$clog2(`TE)-1:0]), .shift_mode(2'b00), .dout(tailTnTmp));

  assign tailTm = {`TE{!peCmd[0].tm[$clog2(`TE)]}} & tailTmTmp;
  assign tailTn = {`TE{!peCmd[0].vl[$clog2(`TE)]}} & tailTnTmp;

  always_comb begin
    for(int i=0; i<`TE/2; i++) begin
      vaMaskLo[i] = {4{!tailTm[i]}};
      vbMaskLo[i] = {4{!tailTn[i]}};
      vaMaskHi[i] = {4{!tailTm[i+`TE/2]}};
      vbMaskHi[i] = {4{!tailTn[i+`TE/2]}};

      case(peCmd[0].sew)
        SEW16: begin
          if(peCmd[0].tk==3'd1)
          vaMaskLo[i] = {2'b0, {2{!tailTm[i]}}};
          vbMaskLo[i] = {2'b0, {2{!tailTn[i]}}};
          vaMaskHi[i] = {2'b0, {2{!tailTm[i+`TE/2]}}};
          vbMaskHi[i] = {2'b0, {2{!tailTn[i+`TE/2]}}};
        end
        SEW8: begin
          if(peCmd[0].tk==3'd1) begin
            vaMaskLo[i] = {3'b0, {!tailTm[i]}};
            vbMaskLo[i] = {3'b0, {!tailTn[i]}};
            vaMaskHi[i] = {3'b0, {!tailTm[i+`TE/2]}};
            vbMaskHi[i] = {3'b0, {!tailTn[i+`TE/2]}};
          end
          else if(peCmd[0].tk==3'd2) begin
            vaMaskLo[i] = {2'b0, {2{!tailTm[i]}}};
            vbMaskLo[i] = {2'b0, {2{!tailTn[i]}}};
            vaMaskHi[i] = {2'b0, {2{!tailTm[i+`TE/2]}}};
            vbMaskHi[i] = {2'b0, {2{!tailTn[i+`TE/2]}}};
          end
          else if(peCmd[0].tk==3'd3) begin
            vaMaskLo[i] = {1'b0, {3{!tailTm[i]}}};
            vbMaskLo[i] = {1'b0, {3{!tailTn[i]}}};
            vaMaskHi[i] = {1'b0, {3{!tailTm[i+`TE/2]}}};
            vbMaskHi[i] = {1'b0, {3{!tailTn[i+`TE/2]}}};
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
  logic                              canStart;
  logic [$clog2(`TE):0]              tmsub1, tnsub1;
  logic [$clog2(`PROCESS_DELAY)-1:0] cnt, cntMax00, cntMax10;
  logic                              cntEn, cntCr;
  logic                              vaHiActive, vbHiActive;
  logic                              pipeLaEn, pipeHa0En, pipeHa1En, pipeLbEn, pipeHb0En, pipeHb1En;
  logic                              pipeLaVld, pipeHa0Vld, pipeHa1Vld, pipeLbVld, pipeHb0Vld, pipeHb1Vld;
  // information
  PEVAINFO_t                         vaInfoLo, vaInfoHi, vaInfoLoD1, vaInfoHiD1, vaInfoHiD2;
  PEVBINFO_t                         vbInfoLo, vbInfoHi, vbInfoLoD1, vbInfoHiD1, vbInfoHiD2;
  logic     [1:0][1:0]               blkCmdVld;
  BLKCMD_t  [1:0][1:0]               blkCmd;
  logic     [`NUM_BLK-1:0]           blkCmdRdy;

  // ready to start up. 
  assign canStart = &peCmdVld[3:0] && peCmd[0].first_uop_valid && peCmd[3].last_uop_valid;
  assign peCmdRdy = {4{canStart && cntCr}};

  // counter
  cdffr #(.T(logic [$clog2(`PROCESS_DELAY)-1:0]))
  counter (.q(cnt), .clk(clk), .rst_n(rst_n), .e(cntEn), .c(cntCr), .d(cnt+($clog2(`PROCESS_DELAY))'('d1)));
  
  assign tmsub1   = peCmd[0].tm - 'd1;
  assign tnsub1   = peCmd[0].vl - 'd1;
  assign cntMax00 = tmsub1[$clog2(`TE)-1] ? ($clog2(`PROCESS_DELAY))'(`PROCESS_DELAY-1) : tmsub1[$clog2(`TE/2)-1:$clog2(`TE/2*`COMPRATIO)];
  assign cntCr    = cnt == cntMax00;
  assign cntEn    = canStart && &blkCmdRdy;

  // 01
  assign vbHiActive = tnsub1[$clog2(`TE)-1];
  assign pipeLaEn   = canStart & vbHiActive;
  assign pipeHb0En  = canStart & vbHiActive;
  // 10
  assign vaHiActive = tmsub1[$clog2(`TE)-1];
  assign cntMax10   = tmsub1[$clog2(`TE/2)-1:$clog2(`TE/2*`COMPRATIO)];
  assign pipeHa0En  = canStart & vaHiActive & (cnt<=cntMax10);
  assign pipeLbEn   = canStart & vaHiActive;
  // 11
  assign pipeHa1En  = pipeHa0Vld & pipeHb0Vld;
  assign pipeHb1En  = pipeHa0Vld & pipeHb0Vld;

`ifdef TB_SUPPORT
  assign vaInfoLo.uop_pc     = peCmd[0].uop_pc;
  assign vaInfoHi.uop_pc     = peCmd[0].uop_pc;
`endif 
  assign vaInfoLo.rndMode    = peCmd[0].rndMode;
  assign vaInfoHi.rndMode    = peCmd[0].rndMode;
  assign vaInfoLo.readMtIdx  = peCmd[0].dst_index[4:1];
  assign vaInfoHi.readMtIdx  = peCmd[0].dst_index[4:1];
  assign vaInfoLo.readMtId   = cnt;
  assign vaInfoHi.readMtId   = cnt;
  assign vaInfoLo.lastUopVld = cntCr;
  assign vaInfoHi.lastUopVld = cntCr;

  always_comb begin
    vaInfoLo.op      = INTMUL;
    vaInfoHi.op      = INTMUL;
    vaInfoLo.opMod   = 'b0;
    vaInfoHi.opMod   = 'b0;
    vaInfoLo.fsrcFmt = fpnew_pkg::FP32;
    vaInfoHi.fsrcFmt = fpnew_pkg::FP32;
    vaInfoLo.isrcFmt = fpnew_pkg::INT32;
    vaInfoHi.isrcFmt = fpnew_pkg::INT32;
    vaInfoLo.fdstFmt = fpnew_pkg::FP32;
    vaInfoHi.fdstFmt = fpnew_pkg::FP32;
    vaInfoLo.idstFmt = fpnew_pkg::INT32;
    vaInfoHi.idstFmt = fpnew_pkg::INT32;

    case(peCmd[0].uop_funct3)
      OPIVV: begin
        vaInfoLo.op      = peCmd[0].dst_index[0] ? INTMUL : UINTMUL;
        vaInfoHi.op      = peCmd[0].dst_index[0] ? INTMUL : UINTMUL;
        vaInfoLo.opMod   = peCmd[0].altfmt;
        vaInfoHi.opMod   = peCmd[0].altfmt;
      `ifdef ZVTI16I32_ON
        vaInfoLo.isrcFmt = peCmd[0].sew==SEW16 ? fpnew_pkg::INT16 : fpnew_pkg::INT8;
        vaInfoHi.isrcFmt = peCmd[0].sew==SEW16 ? fpnew_pkg::INT16 : fpnew_pkg::INT8;
      `else
        vaInfoLo.isrcFmt = fpnew_pkg::INT8;
        vaInfoHi.isrcFmt = fpnew_pkg::INT8;
      `endif
        vaInfoLo.idstFmt = fpnew_pkg::INT32;
        vaInfoHi.idstFmt = fpnew_pkg::INT32;        
      end
      OPFVV: begin
        vaInfoLo.op      = FPMUL;
        vaInfoHi.op      = FPMUL;
        vaInfoLo.fsrcFmt = peCmd[0].sew==SEW16 ? fpnew_pkg::FP16ALT : fpnew_pkg::FP32;
        vaInfoHi.fsrcFmt = peCmd[0].sew==SEW16 ? fpnew_pkg::FP16ALT : fpnew_pkg::FP32;
        vaInfoLo.fdstFmt = fpnew_pkg::FP32;
        vaInfoHi.fdstFmt = fpnew_pkg::FP32;
      end
    endcase
  end
  
  // M-direction stripmining: vaInfo.va only carries ROWS_PER_CNT = TE/2*COMPRATIO
  // rows per cycle. The pe_array advances cnt to walk through tm rows in
  // ROWS_PER_CNT-sized chunks; this mux picks the correct chunk of vaGroup{Lo,Hi}
  // for the current cnt. Without this slice, every cnt cycle re-multiplied
  // rows 0..ROWS_PER_CNT-1.
  localparam ROWS_PER_CNT = `TE/2*`COMPRATIO;
  always_comb begin
    for (int k = 0; k < ROWS_PER_CNT; k++) begin
      vaInfoLo.va[k]     = vaGroupLo[k + ROWS_PER_CNT * cnt];
      vaInfoLo.vaMask[k] = vaMaskLo[ k + ROWS_PER_CNT * cnt];
      vaInfoHi.va[k]     = vaGroupHi[k + ROWS_PER_CNT * cnt];
      vaInfoHi.vaMask[k] = vaMaskHi[ k + ROWS_PER_CNT * cnt];
    end
  end
  assign vbInfoLo.vb     = vbGroupLo;
  assign vbInfoLo.vbMask = vbMaskLo;
  assign vbInfoHi.vb     = vbGroupHi;
  assign vbInfoHi.vbMask = vbMaskHi;
  
  // systolic pipeline register
  edff regLaVld  (.q(pipeLaVld ), .clk(clk), .rst_n(rst_n), .e(&blkCmdRdy), .d(pipeLaEn));
  edff regHa0Vld (.q(pipeHa0Vld), .clk(clk), .rst_n(rst_n), .e(&blkCmdRdy), .d(pipeHa0En));
  edff regHa1Vld (.q(pipeHa1Vld), .clk(clk), .rst_n(rst_n), .e(&blkCmdRdy), .d(pipeHa1En));
  edff regLbVld  (.q(pipeLbVld ), .clk(clk), .rst_n(rst_n), .e(&blkCmdRdy), .d(pipeLbEn));
  edff regHb0Vld (.q(pipeHb0Vld), .clk(clk), .rst_n(rst_n), .e(&blkCmdRdy), .d(pipeHb0En));
  edff regHb1Vld (.q(pipeHb1Vld), .clk(clk), .rst_n(rst_n), .e(&blkCmdRdy), .d(pipeHb1En));

  edff #(.T(PEVAINFO_t)) regLaData  (.q(vaInfoLoD1), .clk(clk), .rst_n(rst_n), .e(pipeLaEn  && &blkCmdRdy), .d(vaInfoLo));
  edff #(.T(PEVAINFO_t)) regHa0Data (.q(vaInfoHiD1), .clk(clk), .rst_n(rst_n), .e(pipeHa0En && &blkCmdRdy), .d(vaInfoHi));
  edff #(.T(PEVAINFO_t)) regHa1Data (.q(vaInfoHiD2), .clk(clk), .rst_n(rst_n), .e(pipeHa1En && &blkCmdRdy), .d(vaInfoHiD1));
  edff #(.T(PEVBINFO_t)) regLbData  (.q(vbInfoLoD1), .clk(clk), .rst_n(rst_n), .e(pipeLbEn  && (cnt=='d0) && (&blkCmdRdy)), .d(vbInfoLo));
  edff #(.T(PEVBINFO_t)) regHb0Data (.q(vbInfoHiD1), .clk(clk), .rst_n(rst_n), .e(pipeHb0En && (cnt=='d0) && (&blkCmdRdy)), .d(vbInfoHi));
  edff #(.T(PEVBINFO_t)) regHb1Data (.q(vbInfoHiD2), .clk(clk), .rst_n(rst_n), .e(pipeHb1En && (cnt=='d1) && (&blkCmdRdy)), .d(vbInfoHiD1));

  // Block Command
  assign blkCmdVld[0][0] = canStart   && &blkCmdRdy;
  assign blkCmdVld[0][1] = pipeLaVld  && pipeHb0Vld && &blkCmdRdy;
  assign blkCmdVld[1][0] = pipeHa0Vld && pipeLbVld  && &blkCmdRdy;
  assign blkCmdVld[1][1] = pipeHa1Vld && pipeHb1Vld && &blkCmdRdy;

  assign blkCmd[0][0].vaInfo = vaInfoLo;
  assign blkCmd[0][0].vbInfo = vbInfoLo;
  assign blkCmd[0][1].vaInfo = vaInfoLoD1;
  assign blkCmd[0][1].vbInfo = vbInfoHiD1;
  assign blkCmd[1][0].vaInfo = vaInfoHiD1;
  assign blkCmd[1][0].vbInfo = vbInfoLoD1;
  assign blkCmd[1][1].vaInfo = vaInfoHiD2;
  assign blkCmd[1][1].vbInfo = vbInfoHiD2;

// pe block
  logic    [1:0][1:0] hitBlkRaw;
  logic               rawStall;
  logic    [1:0][1:0] fpexpBlkVld;
  RVFEXP_t [1:0][1:0] fpexpBlk;
  logic    [1:0][1:0] blkBusy;

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
        .readMtIdx      (readMtIdx[BLKID]),
        .readSubIdx     (readSubIdx[BLKID]),
        .readData       (readData[BLKID]),  
        .writeEn        (writeEn[BLKID]),  
        .writeMtIdx     (writeMtIdx[BLKID]),
        .writeSubIdx    (writeSubIdx[BLKID]),
        .writeData      (writeData[BLKID]),  
        .fpexpVld       (fpexpBlkVld[i][j]),
        .fpexp          (fpexpBlk[i][j]),
        .fpexpRdy       (fpexpRdy),
        .blkRtVld       (peRtVld[BLKID]),
      `ifdef RVVI_ON
        .blkRtMtIdx     (peRtMtIdx[BLKID]),
      `endif
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
