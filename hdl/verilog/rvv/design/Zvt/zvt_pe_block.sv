`ifndef HDL_VERILOG_RVV_DESIGN_RVV_SVH
`include "rvv_backend.svh"
`endif

module zvt_pe_block (
  clk,
  rst_n,
  blkCmdVld,
  blkCmd,
  blkCmdRdy,
  mulbulkTagOutVld,
  mulbulkTagOut,
  readMtIdx,
  readSubIdx,
  readData,  
`ifdef TB_SUPPORT
  readPc,
  writePc,
`endif
  writeEn,  
  writeMtIdx,
  writeSubIdx,
  writeData,  
  fpexpVld,
  fpexp,
  fpexpRdy,
  blkRtVld,
`ifdef RVVI_ON
  blkRtInfo,
`endif
  flush,
  busy
);
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
  // Tag
  output logic        [ADDERPIPENUM:1]                      mulbulkTagOutVld;
  output MULBULKTAG_t [ADDERPIPENUM:1]                      mulbulkTagOut;
  // MT 
  output logic [`NUM_BLKPORT-1:0][$clog2(`NUM_MT)-1:0]      readMtIdx;
  output logic [`NUM_BLKPORT-1:0][$clog2(`NUM_SUBTILE)-1:0] readSubIdx;
  input  logic [`NUM_BLKPORT-1:0][`SUBTILE_SIZE*8-1:0]      readData;  
`ifdef TB_SUPPORT
  output logic [`PC_WIDTH-1:0]                              readPc;
  output logic [`PC_WIDTH-1:0]                              writePc;
`endif
  output logic [`NUM_BLKPORT-1:0][`SUBTILE_SIZE-1:0]        writeEn;  
  output logic [`NUM_BLKPORT-1:0][$clog2(`NUM_MT)-1:0]      writeMtIdx;
  output logic [`NUM_BLKPORT-1:0][$clog2(`NUM_SUBTILE)-1:0] writeSubIdx;
  output logic [`NUM_BLKPORT-1:0][`SUBTILE_SIZE*8-1:0]      writeData;  
  // floating-point status
  output logic                                              fpexpVld;
  output RVFEXP_t                                           fpexp;
  input  logic                                              fpexpRdy;
  // retiring informaiton
  output logic                                              blkRtVld;
`ifdef RVVI_ON
  output PE_RTINFO_t                                        blkRtInfo;
`endif
  // control&status  
  input  logic                                              flush;
  output logic                                              busy;

// -------------- code start --------------------
  // mul+bulk input
  MULBULKTAG_t                                              mulbulkTagIn;
  logic [`TE/2*`COMPRATIO-1:0][`TE/2-1:0][3:0]              maskIn;
  // mul+bulk Result
  logic [`TE/2*`COMPRATIO-1:0][`TE/2-1:0][MULBULKPIPENUM:1] mulbulkOutVld;
  logic                                                     mulbulkResVld;
  MULBULKRES_t                                              mulbulkRes;
  logic                                                     mulbulkResRdy;
  MULBULKTAG_t [MULBULKPIPENUM:1]                           mulbulkTagPipe;
  // mul+bulk status                                        
  logic                                                     mulbulkBusy;

`ifdef TB_SUPPORT
  assign mulbulkTagIn.uop_pc     = blkCmd.vaInfo.uop_pc;
`endif    
  assign mulbulkTagIn.rndMode    = blkCmd.vaInfo.rndMode;
  assign mulbulkTagIn.op         = blkCmd.vaInfo.op;
  assign mulbulkTagIn.fdstFmt    = blkCmd.vaInfo.fdstFmt;
  assign mulbulkTagIn.idstFmt    = blkCmd.vaInfo.idstFmt;
  assign mulbulkTagIn.readMtIdx  = blkCmd.vaInfo.readMtIdx;
  assign mulbulkTagIn.readMtId   = blkCmd.vaInfo.readMtId;
  assign mulbulkTagIn.lastUopVld = blkCmd.vaInfo.lastUopVld;

  // instance mul+bulk-normalization
  //
  // Each PE block has ROWS_PER_CNT = TE/2*COMPRATIO adder rows. For tm
  // values larger than ROWS_PER_CNT, the pe_array stripmines M across cnt
  // cycles and pre-slices vaGroupLo to deliver the correct rows per cycle.
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
          .REMV_PIPE_BUBBLE (1)
        ) peMulBulk (
          .clk            (clk),
          .rst_n          (rst_n),
          // Input signals
          //                          vs1                 vs2
          .operands       ({blkCmd.vbInfo.vb[j], blkCmd.vaInfo.va[i]}),
          .rnd_mode       (blkCmd.vaInfo.rndMode),
          .op             (blkCmd.vaInfo.op),
          .op_mod         (blkCmd.vaInfo.opMod),
          .fsrc_fmt       (blkCmd.vaInfo.fsrcFmt),
          .isrc_fmt       (blkCmd.vaInfo.isrcFmt),
          .fdst_fmt       (blkCmd.vaInfo.fdstFmt),
          .idst_fmt       (blkCmd.vaInfo.idstFmt),
          .in_tag         (mulbulkTagIn),
          .mask           (maskIn[i][j]),
          // Input Handshake
          .in_valid       (blkCmdVld && (|maskIn[i][j])),
          .in_ready       (blkCmdRdy),
          .flush          (flush),
          // Output signals
          .result         (mulbulkRes.res[i][j]),
          .status         (mulbulkRes.status[i][j]),
          .out_tag        (mulbulkTagPipe),
          // Output handshak
          .out_valid      (mulbulkOutVld[i][j]),
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
          .REMV_PIPE_BUBBLE (1)
        ) peMulBulk (
          .clk            (clk),
          .rst_n          (rst_n),
          // Input signals
          .operands       ({blkCmd.vbInfo.vb[j], blkCmd.vaInfo.va[i]}),
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
          .out_valid      (mulbulkOutVld[i][j]),
          .out_ready      (mulbulkResRdy),
          // Indication of valid data in flight
          .busy           ()
        );
      end

      assign mulbulkRes.resMask[i][j] = {4{mulbulkOutVld[i][j][MULBULKPIPENUM]}};
    end
  end

  assign mulbulkRes.tag = mulbulkTagPipe[MULBULKPIPENUM];
  assign mulbulkResVld  = mulbulkOutVld[0][0][MULBULKPIPENUM];   

  // output tag for RAW check
  for(genvar i=1; i<=ADDERPIPENUM; i++) begin
    assign mulbulkTagOutVld[i] = mulbulkOutVld[0][0][i];
    assign mulbulkTagOut[i]    = mulbulkTagPipe[i];
  end

  // mulbulk result buffer
  logic        mulbulkCmdVld;
  MULBULKRES_t mulbulkCmd;
  logic        mulbulkCmdRdy;

  handshake_ff #(
    .T        (MULBULKRES_t)
  ) mulbulkPipe (
    .indata   (mulbulkRes),
    .invalid  (mulbulkResVld),
    .inready  (mulbulkResRdy),
    .outdata  (mulbulkCmd),
    .outvalid (mulbulkCmdVld),
    .outready (mulbulkCmdRdy),
    .c        (flush),
    .clk      (clk), 
    .rst_n    (rst_n) 
  );

// Adder
  ADDERTAG_t                                               adderTagIn;
  logic                                                    adderRdy;
  logic [`TE/2*`COMPRATIO-1:0][`TE/2-1:0][ADDERPIPENUM:1]  adderOutVld;
  logic [`TE/2*`COMPRATIO-1:0][`TE/2-1:0]                  adderResVld;  
  logic                                                    adderResRdy;
  logic [`TE/2*`COMPRATIO-1:0][`TE/2-1:0][`WORD_WIDTH-1:0] adderRes;
  fpnew_pkg::status_t [`TE/2*`COMPRATIO-1:0][`TE/2-1:0]    adderStatus;
  ADDERTAG_t [ADDERPIPENUM:1]                              adderTagOut;
  ADDERTAG_t                                               adderResTag;
  logic                                                    adderBusy;

  // handshake
  assign mulbulkCmdRdy = adderRdy;

  // read the operands from MT
`ifdef TB_SUPPORT
  assign readPc = mulbulkCmd.tag.uop_pc;
`endif

  always_comb begin
    if(mulbulkCmdVld) begin
      for(int i=0; i<`TE/4*`COMPRATIO; i++) begin: SubtileRow
        for(int j=0; j<`TE/8; j++) begin: SubtileCol
          readMtIdx[(`TE/4*i)+(2*j)  ] = {mulbulkCmd.tag.readMtIdx[3:2], BLKID[1], 1'b0};
          readMtIdx[(`TE/4*i)+(2*j+1)] = {mulbulkCmd.tag.readMtIdx[3:2], BLKID[1], 1'b1};
          readSubIdx[(`TE/4*i)+(2*j)  ] = ($clog2(`NUM_SUBTILE))'((`TE/8)*BLKID[0]+(`TE/4*`COMPRATIO*mulbulkCmd.tag.readMtId+i)*(`TE/4)+j); 
          readSubIdx[(`TE/4*i)+(2*j+1)] = ($clog2(`NUM_SUBTILE))'((`TE/8)*BLKID[0]+(`TE/4*`COMPRATIO*mulbulkCmd.tag.readMtId+i)*(`TE/4)+j);
        end
      end
    end else begin
      readMtIdx = 'b0;
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
  assign adderTagIn.uop_pc     = mulbulkCmd.tag.uop_pc;
`endif
  assign adderTagIn.status     = mulbulkCmd.status;
  assign adderTagIn.writeMtIdx = mulbulkCmd.tag.readMtIdx;
  assign adderTagIn.writeMtId  = mulbulkCmd.tag.readMtId;
  assign adderTagIn.lastUopVld = mulbulkCmd.tag.lastUopVld;

  // adder
  for(genvar i=0; i<`TE/2*`COMPRATIO; i++) begin: adderRow
    for(genvar j=0; j<`TE/2; j++) begin: adderCol
      if((i==0)&(j==0)) begin
        zvt_pe_adder #(
          .NUM_PIPE_REGS    (ADDERPIPENUM),
          .PIPE_CONFIG      (fpnew_pkg::DISTRIBUTED),  
          .TAG_TYPE         (ADDERTAG_t),
          .REMV_PIPE_BUBBLE (1)
        ) peAdder (
          .clk              (clk),
          .rst_n            (rst_n),
          .operands         ({operands[i][j], mulbulkCmd.res[i][j]}),  
          .rnd_mode         (mulbulkCmd.tag.rndMode),  
          .op_mod           ('0), 
          .op               (mulbulkCmd.tag.op==FPMUL),         
          .in_tag           (adderTagIn),        
          .in_valid         (mulbulkCmdVld & &mulbulkCmd.resMask[i][j]),  
          .in_ready         (adderRdy),
          .flush            (flush),      
          .result           (adderRes[i][j]),   
          .status           (adderStatus[i][j]),     
          .out_tag          (adderTagOut),        
          .out_valid        (adderOutVld[i][j]),
          .out_ready        (adderResRdy),
          .busy             (adderBusy)
        );
      end else begin
        zvt_pe_adder #(
          .NUM_PIPE_REGS    (ADDERPIPENUM),
          .PIPE_CONFIG      (fpnew_pkg::DISTRIBUTED),
          .REMV_PIPE_BUBBLE (1)
        ) peAdder (
          .clk              (clk),
          .rst_n            (rst_n),
          .operands         ({operands[i][j], mulbulkCmd.res[i][j]}),   
          .rnd_mode         (mulbulkCmd.tag.rndMode),   
          .op_mod           ('0),
          .op               (mulbulkCmd.tag.op==FPMUL),         
          .in_tag           ('0),        
          .in_valid         (mulbulkCmdVld & &mulbulkCmd.resMask[i][j]),  
          .in_ready         (),
          .flush            (flush),      
          .result           (adderRes[i][j]),   
          .status           (adderStatus[i][j]),      
          .out_tag          (),        
          .out_valid        (adderOutVld[i][j]),
          .out_ready        (adderResRdy),
          .busy             ()
        ); 
      end
    end
  end

  // adder output valid
  generate 
    for(genvar i=0; i<`TE/2*`COMPRATIO; i++) begin: gen_res_vld_i
      for(genvar j=0; j<`TE/2; j++) begin: gen_res_vld_j
        assign adderResVld[i][j] = adderOutVld[i][j][ADDERPIPENUM];
      end
    end
  endgenerate

  assign adderResTag = adderTagOut[ADDERPIPENUM];

  // fp status
  always_comb begin
    fpexp = 'b0;
    for(int i=0; i<`TE/2*`COMPRATIO; i++) begin
      for(int j=0; j<`TE/2; j++) begin
        fpexp.of = fpexp.of | adderResVld[i][j] && (adderResTag.status[i][j].OF || adderStatus[i][j].OF);
        fpexp.nv = fpexp.nv | adderResVld[i][j] && (adderResTag.status[i][j].NV || adderStatus[i][j].NV);
      end
    end
  end

  assign fpexpVld    = |fpexp;
  assign adderResRdy = !fpexpVld || fpexpRdy; 

// write Mt
  always_comb begin
  `ifdef TB_SUPPORT
    writePc     = adderResTag.uop_pc;
  `endif
    writeEn     = 'b0; 
    writeMtIdx  = 'b0;
    writeSubIdx = 'b0;
    writeData   = 'b0; 

    for(int i=0; i<`TE/2*`COMPRATIO; i++) begin
      for(int j=0; j<`TE/2; j++) begin
        writeMtIdx[(`TE/4)*(i/2)+(j/2)] = {adderResTag.writeMtIdx[3:2], BLKID[1], j[1]};
        // Stripmine subIdx by writeMtId so multi-cycle (tm > TE/2*COMPRATIO)
        // dispatches land in different subtiles. The original `*+i/2`
        // collapsed to 0 for i<2 (i/2=0), so cnt=1+ would overwrite cnt=0.
        // Matches the symmetric READ formula at line ~246.
        writeSubIdx[(`TE/4)*(i/2)+(j/2)] = ($clog2(`NUM_SUBTILE))'(`TE/8)*BLKID[0]+
                                           (`TE/4)*(`TE/4*`COMPRATIO*adderResTag.writeMtId+i/2)+(j/4);
        writeEn[(`TE/4)*(i/2)+(j/2)][{i[0],j[0]}*4 +: 4] = {4{adderResVld[i][j]&&adderResRdy}};
        writeData[(`TE/4)*(i/2)+(j/2)][{i[0],j[0]}*`WORD_WIDTH +: `WORD_WIDTH] = adderRes[i][j];
      end
    end
  end

  // retire
  assign blkRtVld         = adderResVld[0][0] && adderResTag.lastUopVld;
`ifdef RVVI_ON
  assign blkRtInfo.uop_pc = adderResTag.uop_pc;
  assign blkRtInfo.mtIdx  = adderResTag.writeMtIdx;
`endif

  // busy
  assign busy = mulbulkBusy || mulbulkCmdVld || adderBusy;

endmodule
