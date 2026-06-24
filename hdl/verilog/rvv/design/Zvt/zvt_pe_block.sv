`ifndef HDL_VERILOG_RVV_DESIGN_RVV_SVH
`include "rvv_backend.svh"
`endif

module zvt_pe_block (
  clk,
  rst_n,
  blkCmdVld,
  blkCmd,
  blkCmdRdy,
  hitBlkRaw,
  rawStall,
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
  parameter REMVPIPEBUBB    = 1;
  parameter MULBULKPIPENUM  = 3;
  parameter ADDERPIPENUM    = 3;
  parameter BLKID           = 2'b00;

// interface signals
  input  logic                                              clk;
  input  logic                                              rst_n;
  // Command
  input  logic                                              blkCmdVld;
  input  BLKCMD_t                                           blkCmd;
  output logic                                              blkCmdRdy;
  // ACC 
  output logic                                              hitBlkRaw;
  input  logic                                              rawStall;
  output logic [`NUM_BLKPORT-1:0][$clog2(`NUM_ACC)-1:0]     readAccIdx;
  output logic [`NUM_BLKPORT-1:0][$clog2(`NUM_SUBTILE)-1:0] readSubIdx;
  input  logic [`NUM_BLKPORT-1:0][`SUBTILE_SIZE*8-1:0]      readData;  
  output logic [`NUM_BLKPORT-1:0][`SUBTILE_SIZE-1:0]        writeEn;  
  output logic [`NUM_BLKPORT-1:0][$clog2(`NUM_ACC)-1:0]     writeAccIdx;
  output logic [`NUM_BLKPORT-1:0][$clog2(`NUM_SUBTILE)-1:0] writeSubIdx;
  output logic [`NUM_BLKPORT-1:0][`SUBTILE_SIZE*8-1:0]      writeData;  
  // floating-point status
  output logic                                              fpexpVld;
  output RVFEXP_t                                           fpexp;
  input  logic                                              fpexpRdy;
  // control&status  
  input  logic                                              flush;
  output logic                                              busy;

// -------------- code start --------------------
  // mul+bulk input
  MULBULKTAG_t                                  mulbulkTag;
  logic [`TE/2*`COMPRATIO-1:0][`TE/2-1:0][3:0]  maskIn;
  // mul+bulk Result
  logic [`TE/2*`COMPRATIO-1:0][`TE/2-1:0]       outVld;
  logic                                         mulbulkResVld;
  MULBULKRES_t                                  mulbulkRes;
  logic                                         mulbulkResRdy;
  // mul+bulk status                            
  logic                                         mulbulkBusy;

`ifdef TB_SUPPORT
  assign mulbulkTag.uop_pc     = blkCmd.vaInfo.uop_pc;
`endif    
  assign mulbulkTag.rndMode    = blkCmd.vaInfo.rndMode;
  assign mulbulkTag.op         = blkCmd.vaInfo.op;
  assign mulbulkTag.fdstFmt    = blkCmd.vaInfo.fdstFmt;
  assign mulbulkTag.idstFmt    = blkCmd.vaInfo.idstFmt;
  assign mulbulkTag.readAccIdx = blkCmd.vaInfo.readAccIdx;
  assign mulbulkTag.readAccId  = blkCmd.vaInfo.readAccId;

  // instance mul+bulk-normalization
  for(genvar i=0; i<`TE/2*`COMPRATIO; i++) begin: mul_bulk_row
    for(genvar j=0; j<`TE/2; j++) begin: mul_bulk_col
      assign maskIn[i][j] = blkCmd.vaInfo.vaMask[i]&blkCmd.vbInfo.vbMask[j];
      
      if ((i==0)&(j==0)) begin
        zvt_pe_mulbulk #(
          .FP_FMT_CONFIG    (5'b10001),  
          `ifdef ZVTI16I32_ON
          .INT_FMT_CONFIG   (2'b11),
          `else
          .INT_FMT_CONFIG   (2'b01),
          `endif
          .NUM_PIPE_REGS    (MULBULKPIPENUM),
          .PIPE_CONFIG      (fpnew_pkg::DISTRIBUTED),  
          .TAG_TYPE         (MULBULKTAG_t),
          .REMV_PIPE_BUBBLE (REMVPIPEBUBB)
        ) peMulBulk (
          .clk            (clk),
          .rst_n          (rst_n),
          // Input signals
          .operands       ({blkCmd.vaInfo.va[i], blkCmd.vbInfo.vb[j]}),   
          .rnd_mode       (blkCmd.vaInfo.rndMode),   
          .op             (blkCmd.vaInfo.op),         
          .op_mod         (blkCmd.vaInfo.opMod),     
          .fsrc_fmt       (blkCmd.vaInfo.fsrcFmt),   
          .isrc_fmt       (blkCmd.vaInfo.isrcFmt),   
          .fdst_fmt       (blkCmd.vaInfo.fdstFmt),   
          .idst_fmt       (blkCmd.vaInfo.idstFmt),   
          .in_tag         (mulbulkTag),
          .mask           (maskIn[i][j]),
          // Input Handshake
          .in_valid       (blkCmdVld && (|maskIn[i][j])),
          .in_ready       (blkCmdRdy),
          .flush          (flush),
          // Output signals
          .result         (mulbulkRes.res[i][j]),
          .status         (mulbulkRes.status[i][j]),
          .out_tag        (mulbulkRes.tag),
          // Output handshak
          .out_valid      (outVld[i][j]),
          .out_ready      (mulbulkResRdy),
          // Indication of valid data in flight
          .busy           (mulbulkBusy)
        );
      end else begin
        zvt_pe_mulbulk #(
          .FP_FMT_CONFIG    (5'b10001),  
          `ifdef ZVTI16I32_ON
          .INT_FMT_CONFIG   (2'b11),
          `else
          .INT_FMT_CONFIG   (2'b01),
          `endif
          .NUM_PIPE_REGS    (MULBULKPIPENUM),
          .PIPE_CONFIG      (fpnew_pkg::DISTRIBUTED),  
          .REMV_PIPE_BUBBLE (REMVPIPEBUBB)
        ) peMulBulk (
          .clk            (clk),
          .rst_n          (rst_n),
          // Input signals
          .operands       ({blkCmd.vaInfo.va[i], blkCmd.vbInfo.vb[j]}),   
          .rnd_mode       (blkCmd.vaInfo.rndMode),   
          .op             (blkCmd.vaInfo.op),         
          .op_mod         (blkCmd.vaInfo.opMod),     
          .fsrc_fmt       (blkCmd.vaInfo.fsrcFmt),   
          .isrc_fmt       (blkCmd.vaInfo.isrcFmt),   
          .fdst_fmt       (blkCmd.vaInfo.fdstFmt),   
          .idst_fmt       (blkCmd.vaInfo.idstFmt),   
          .in_tag         ('0),
          .mask           (maskIn[i][j]),
          // Input Handshake
          .in_valid       (blkCmdVld && (|maskIn[i][j])),
          .in_ready       (),
          .flush          (flush),
          // Output signals
          .result         (mulbulkRes.res[i][j]),
          .status         (mulbulkRes.status[i][j]),
          .out_tag        (),
          // Output handshak
          .out_valid      (outVld[i][j]),
          .out_ready      (mulbulkResRdy),
          // Indication of valid data in flight
          .busy           ()
        );
      end

      assign mulbulkRes.resMask[i][j] = {4{outVld[i][j]}};
    end
  end

  // mulbulk result buffer
  logic         mulbulkBufAfull;
  logic         mulbulkBufAempty;
  logic         mulbulkCmdVld;
  MULBULKRES_t  mulbulkCmd;
  logic         mulbulkCmdRdy;

  assign mulbulkResVld = outVld[0][0];   
  assign mulbulkResRdy = !mulbulkBufAfull;

  multi_fifo #(
      .T            (MULBULKRES_t),
      .M            (1),
      .N            (1),
      .ASYNC_RSTN   (1),
      .DEPTH        (2)
  ) mulbulkBuf (
    // global
      .clk          (clk),
      .rst_n        (rst_n),
    // write
      .push         (mulbulkResVld & mulbulkResRdy),
      .datain       (mulbulkRes),
    // read
      .pop          (mulbulkCmdVld & mulbulkCmdRdy),
      .dataout      (mulbulkCmd),
    // fifo status
      .almost_full  (mulbulkBufAfull),
      .almost_empty (mulbulkBufAempty),
      .full         (),
      .empty        (),
      .fifo_data    (),
      .wptr         (),
      .rptr         (),
      .entry_count  (),
      .clear        (flush)
  );  

// Adder
  ADDERTAG_t                                                adderTagIn;
  logic [`TE/2*`COMPRATIO-1:0][`TE/2-1:0][ADDERPIPENUM:1]   adderVld;
  logic                                                     adderRdy;
  logic [`TE/2*`COMPRATIO-1:0][`TE/2-1:0]                   adderResVld;  
  generate 
    for(genvar i=0; i<`TE/2*`COMPRATIO; i++) begin: gen_res_vld_i
      for(genvar j=0; j<`TE/2; j++) begin: gen_res_vld_j
        assign adderResVld[i][j] = adderVld[i][j][ADDERPIPENUM];
      end
    end
  endgenerate
  logic [`TE/2*`COMPRATIO-1:0][`TE/2-1:0][`WORD_WIDTH-1:0]  adderRes;
  logic                                                     adderResRdy;
  fpnew_pkg::status_t [`TE/2*`COMPRATIO-1:0][`TE/2-1:0]     adderStatus;
  ADDERTAG_t [ADDERPIPENUM:1]                               adderTag;
  logic                                                     adderBusy;

  // handshake
  assign mulbulkCmdVld = !mulbulkBufAempty;
  assign mulbulkCmdRdy = !rawStall && adderRdy;

  // check RAW of ACC
  always_comb begin
    hitBlkRaw = 'b0;
    for (int i=1;i<=ADDERPIPENUM;i++) begin
      hitBlkRaw = hitBlkRaw || (mulbulkCmdVld && 
                                adderVld[0][0][i] &&
                                (mulbulkCmd.tag.readAccIdx == adderTag[i].writeAccIdx) &&
                                (mulbulkCmd.tag.readAccId == adderTag[i].writeAccId));
    end
  end

  // read the operands from ACC
  always_comb begin
    if(mulbulkCmdVld) begin
      for(int i=0; i<`TE/4*`COMPRATIO; i++) begin: SubtileRow
        for(int j=0; j<`TE/8; j++) begin: SubtileCol
          readAccIdx[(`TE/4*i)+(2*j)  ] = {mulbulkCmd.tag.readAccIdx[3:2], BLKID[1], 1'b0};
          readAccIdx[(`TE/4*i)+(2*j+1)] = {mulbulkCmd.tag.readAccIdx[3:2], BLKID[1], 1'b1};
          readSubIdx[(`TE/4*i)+(2*j)  ] = ($clog2(`NUM_SUBTILE))'((`TE/8)*BLKID[0]+(`TE/4*`COMPRATIO*mulbulkCmd.tag.readAccId+i)*(`TE/4)+j); 
          readSubIdx[(`TE/4*i)+(2*j+1)] = ($clog2(`NUM_SUBTILE))'((`TE/8)*BLKID[0]+(`TE/4*`COMPRATIO*mulbulkCmd.tag.readAccId+i)*(`TE/4)+j);
        end
      end
    end else begin
      readAccIdx = 'b0;
      readSubIdx = 'b0;
    end
  end

  // reorder the operands
  logic [`TE/2*`COMPRATIO-1:0][`TE/2-1:0][`WORD_WIDTH-1:0]  operands;

  always_comb begin
    for(int i=0; i<`TE/2*`COMPRATIO; i++) begin: blkRow
      for(int j=0; j<`TE/2; j++) begin: blkCol
        operands[i][j] = readData[(`TE/4)*(i/2)+(j/2)][`WORD_WIDTH*{i[0], j[0]} +: `WORD_WIDTH];
      end
    end
  end

`ifdef TB_SUPPORT
  assign adderTagIn.uop_pc      = mulbulkCmd.tag.uop_pc;
`endif
  assign adderTagIn.status      = mulbulkCmd.status;
  assign adderTagIn.writeAccIdx = mulbulkCmd.tag.readAccIdx;
  assign adderTagIn.writeAccId  = mulbulkCmd.tag.readAccId;

  // adder
  for(genvar i=0; i<`TE/2*`COMPRATIO; i++) begin: adderRow
    for(genvar j=0; j<`TE/2; j++) begin: adderCol
      if((i==0)&(j==0)) begin
        zvt_pe_adder #(
          .NUM_PIPE_REGS    (ADDERPIPENUM),
          .PIPE_CONFIG      (fpnew_pkg::DISTRIBUTED),  
          .TAG_TYPE         (ADDERTAG_t),
          .REMV_PIPE_BUBBLE (REMVPIPEBUBB)
        ) peAdder (
          .clk          (clk),
          .rst_n        (rst_n),
          .operands     ({operands[i][j], mulbulkCmd.res[i][j]}),  
          .rnd_mode     (mulbulkCmd.tag.rndMode),  
          .op_mod       ('0), 
          .op           (mulbulkCmd.tag.op==FPMUL),         
          .in_tag       (adderTagIn),        
          .in_valid     (mulbulkCmdVld & !rawStall && &mulbulkCmd.resMask[i][j]),  
          .in_ready     (adderRdy),
          .flush        (flush),      
          .result       (adderRes[i][j]),   
          .status       (adderStatus[i][j]),     
          .out_tag      (adderTag),        
          .out_valid    (adderVld[i][j]),
          .out_ready    (adderResRdy),
          .busy         (adderBusy)
        );
      end else begin
        zvt_pe_adder #(
          .NUM_PIPE_REGS    (ADDERPIPENUM),
          .PIPE_CONFIG      (fpnew_pkg::DISTRIBUTED),
          .REMV_PIPE_BUBBLE (REMVPIPEBUBB)
        ) peAdder (
          .clk          (clk),
          .rst_n        (rst_n),
          .operands     ({operands[i][j], mulbulkCmd.res[i][j]}),   
          .rnd_mode     (mulbulkCmd.tag.rndMode),   
          .op_mod       ('0),
          .op           (mulbulkCmd.tag.op==FPMUL),         
          .in_tag       ('0),        
          .in_valid     (mulbulkCmdVld & !hitBlkRaw && &mulbulkCmd.resMask[i][j]),  
          .in_ready     (),
          .flush        (flush),      
          .result       (adderRes[i][j]),   
          .status       (adderStatus[i][j]),      
          .out_tag      (),        
          .out_valid    (adderVld[i][j]),
          .out_ready    (adderResRdy),
          .busy         ()
        ); 
      end
    end
  end

  always_comb begin
    fpexp = 'b0;
    for(int i=0; i<`TE/2*`COMPRATIO; i++) begin
      for(int j=0; j<`TE/2; j++) begin
        fpexp.of = fpexp.of | adderResVld[i][j] && (adderTag[ADDERPIPENUM].status[i][j].OF || adderStatus[i][j].OF);
        fpexp.nv = fpexp.nv | adderResVld[i][j] && (adderTag[ADDERPIPENUM].status[i][j].NV || adderStatus[i][j].NV);
      end
    end
  end

  always_comb begin
    fpexpVld    = |fpexp;
    adderResRdy = !fpexpVld || fpexpRdy; 
    writeEn     = 'b0; 
    writeAccIdx = 'b0;
    writeSubIdx = 'b0;
    writeData   = 'b0; 

    for(int i=0; i<`TE/2*`COMPRATIO; i++) begin
      for(int j=0; j<`TE/2; j++) begin
        writeAccIdx[(`TE/4)*(i/2)+(j/2)] = {adderTag[ADDERPIPENUM].writeAccIdx[3:2], BLKID[1], j[1]};
        writeSubIdx[(`TE/4)*(i/2)+(j/2)] = ($clog2(`NUM_SUBTILE))'(`TE/8)*BLKID[0]+
                                         (`TE/4)*(`TE/4*`COMPRATIO*adderTag[ADDERPIPENUM].writeAccId*+i/2)+(j/4);
        writeEn[(`TE/4)*(i/2)+(j/2)][{i[0],j[0]}*4 +: 4] = {4{adderResVld[i][j]&&adderResRdy}};
        writeData[(`TE/4)*(i/2)+(j/2)][{i[0],j[0]}*`WORD_WIDTH +: `WORD_WIDTH] = adderRes[i][j];
      end
    end
  end

  // busy
  assign busy = mulbulkBusy || !mulbulkBufAempty || adderBusy;

endmodule
