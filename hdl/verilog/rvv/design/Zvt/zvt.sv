`ifndef HDL_VERILOG_RVV_DESIGN_RVV_SVH
`include "rvv_backend.svh"
`endif
`ifdef ASSERT_ON
`include "rvv_backend_sva.svh"
`endif 

module zvt (
  clk,
  rst_n,
  uopVld,
  uop,
  uopRdy,
  res_vme2rvv_vld,
  res_vme2rvv,
  res_vme2rvv_rdy,
  uop_vme2lsu_vld,
  uop_vme2lsu,
  uop_vme2lsu_rdy,
  uop_lsu2vme_vld,
  uop_lsu2vme,
  uop_lsu2vme_rdy,
  fpexpVld,
  fpexp,
  fpexpRdy,
  vmeRtVld,
  vmeRt,
  vmeRtRdy,
  flush,
  zvtBusy
);

// interface signals
  input  logic                    clk;
  input  logic                    rst_n;
  // uops
  input  logic    [`ZVT_LMUL-1:0] uopVld;
  input  ZVT_RS_t [`ZVT_LMUL-1:0] uop;
  output logic    [`ZVT_LMUL-1:0] uopRdy;
  // VME2RVV
  output logic                    res_vme2rvv_vld;
  output PU2ROB_t                 res_vme2rvv;
  input  logic                    res_vme2rvv_rdy;
  // VME2LSU
  output logic                    uop_vme2lsu_vld;
  output UOP_VME2LSU_t            uop_vme2lsu;
  input  logic                    uop_vme2lsu_rdy;
  // LSU2VME
  input  logic                    uop_lsu2vme_vld;
  input  UOP_LSU2VME_t            uop_lsu2vme;
  output logic                    uop_lsu2vme_rdy;
  // VME retire information
  output logic                    vmeRtVld;
  output VMERT_t                  vmeRt;
  input  logic                    vmeRtRdy;
  // floating-point status
  output logic                    fpexpVld;
  output RVFEXP_t                 fpexp;
  input  logic                    fpexpRdy;
  // control&status  
  input  logic                    flush;
  output logic                    zvtBusy;

// -------------- code start --------------------
  // VME2LSU
  logic                 vmelsuVld;
  UOP_VME2LSU_t         vmelsu;
  logic                 vmelsuRdy;
  logic                 vmelsuAfull;
  logic                 vmelsuAempty;
  // LSU2VME
  logic                 vmelsuresVld;
  UOP_LSU2VME_t         vmelsures;
  logic                 vmelsuresRdy;
  logic                 vmelsuresAfull;
  logic                 vmelsuresAempty;
  // PE array
  logic [`ZVT_LMUL-1:0] peCmdVld;
  logic [`ZVT_LMUL-1:0] peCmdRdy;
  logic                 peBusy;  
  logic [`NUM_BLK-1:0][`NUM_BLKPORT-1:0][$clog2(`NUM_MT)-1:0]       peReadMtIdx;
  logic [`NUM_BLK-1:0][`NUM_BLKPORT-1:0][$clog2(`NUM_SUBTILE)-1:0]  peReadSubIdx;
  logic [`NUM_BLK-1:0][`NUM_BLKPORT-1:0][`SUBTILE_SIZE-1:0]         peWriteEn;  
  logic [`NUM_BLK-1:0][`NUM_BLKPORT-1:0][$clog2(`NUM_MT)-1:0]       peWriteMtIdx;
  logic [`NUM_BLK-1:0][`NUM_BLKPORT-1:0][$clog2(`NUM_SUBTILE)-1:0]  peWriteSubIdx;
  logic [`NUM_BLK-1:0][`NUM_BLKPORT-1:0][`SUBTILE_SIZE*8-1:0]       peWriteData;  
  // MT
  logic [`NUM_BLK-1:0][`NUM_BLKPORT-1:0][$clog2(`NUM_MT)-1:0]       readMtIdx;
  logic [`NUM_BLK-1:0][`NUM_BLKPORT-1:0][$clog2(`NUM_SUBTILE)-1:0]  readSubIdx;
  logic [`NUM_BLK-1:0][`NUM_BLKPORT-1:0][`SUBTILE_SIZE*8-1:0]       readData;  
  logic [`NUM_BLK-1:0][`NUM_BLKPORT-1:0][`SUBTILE_SIZE-1:0]         writeEn;  
  logic [`NUM_BLK-1:0][`NUM_BLKPORT-1:0][$clog2(`NUM_MT)-1:0]       writeMtIdx;
  logic [`NUM_BLK-1:0][`NUM_BLKPORT-1:0][$clog2(`NUM_SUBTILE)-1:0]  writeSubIdx;
  logic [`NUM_BLK-1:0][`NUM_BLKPORT-1:0][`SUBTILE_SIZE*8-1:0]       writeData;  
  // Retire Info
  logic                 rtCmdVld;
  VME_RTCMD_t           rtCmd;
  logic                 rtCmdRdy;
  logic                 miscRtVld;
  logic [`NUM_BLK-1:0]  peRtVld;
`ifdef RVVI_ON
  logic [$clog2(`NUM_MT)-1:0]                miscRtMtIdx;
  logic [`NUM_BLK-1:0][$clog2(`NUM_MT)-1:0]  peRtMtIdx;
`endif

  // Controller
  zvt_ctrl zvtCtrl (
    .clk              (clk),
    .rst_n            (rst_n),
    .uopVld           (uopVld),
    .uop              (uop),
    .uopRdy           (uopRdy),
    .resVme2rvvVld    (res_vme2rvv_vld),
    .resVme2rvv       (res_vme2rvv),
    .resVme2rvvRdy    (res_vme2rvv_rdy),
    .vmelsuVld        (vmelsuVld),
    .vmelsu           (vmelsu),
    .vmelsuRdy        (vmelsuRdy),
    .vmelsuresVld     (vmelsuresVld),
    .vmelsures        (vmelsures),
    .vmelsuresRdy     (vmelsuresRdy),
    .peCmdVld         (peCmdVld),
    .peCmdRdy         (peCmdRdy),
    .peBusy           (peBusy),
    .peReadMtIdx      (peReadMtIdx),
    .peReadSubIdx     (peReadSubIdx),
    .peWriteEn        (peWriteEn),  
    .peWriteMtIdx     (peWriteMtIdx),
    .peWriteSubIdx    (peWriteSubIdx),
    .peWriteData      (peWriteData),  
    .readMtIdx        (readMtIdx),
    .readSubIdx       (readSubIdx),
    .readData         (readData),
    .writeEn          (writeEn), 
    .writeMtIdx       (writeMtIdx),
    .writeSubIdx      (writeSubIdx),
    .writeData        (writeData),
    .rtCmdVld         (rtCmdVld),
    .rtCmd            (rtCmd),
    .rtCmdRdy         (rtCmdRdy),
    .miscRtVld        (miscRtVld)
  `ifdef RVVI_ON
    ,.miscRtMtIdx     (miscRtMtIdx)
  `endif
  );

  // LSU
  assign vmelsuRdy       = ~vmelsuAfull;
  assign uop_vme2lsu_vld = ~vmelsuAempty;
  assign uop_lsu2vme_rdy = ~vmelsuresAfull;
  assign vmelsuresVld    = ~vmelsuresAempty;

  multi_fifo #(
    .T            (UOP_VME2LSU_t),
    .M            (1),
    .N            (1),
    .DEPTH        (2),
    .ASYNC_RSTN   (1'b1)
  ) u_vmelsu_rs (
    .clk          (clk),
    .rst_n        (rst_n),
    .push         (vmelsuVld & vmelsuRdy),
    .pushRdy      (),
    .datain       (vmelsu),
    .pop          (uop_vme2lsu_vld & uop_vme2lsu_rdy),
    .dataout      (uop_vme2lsu),
    .almost_full  (vmelsuAfull),
    .almost_empty (vmelsuAempty),
    .full         (),
    .empty        (),
    .fifo_data    (),
    .wptr         (),
    .rptr         (),
    .entry_count  (),
    .clear        (flush)
  );

  multi_fifo #(
    .T            (UOP_LSU2VME_t),
    .M            (1),
    .N            (1),
    .DEPTH        (2),
    .ASYNC_RSTN   (1'b1)
  ) u_vmelsures_rs (
    .clk          (clk),
    .rst_n        (rst_n),
    .push         (uop_lsu2vme_vld & uop_lsu2vme_rdy),
    .pushRdy      (),
    .datain       (uop_lsu2vme),
    .pop          (vmelsuresVld & vmelsuresRdy),
    .dataout      (vmelsures),
    .almost_full  (vmelsuresAfull),
    .almost_empty (vmelsuresAempty),
    .full         (),
    .empty        (),
    .fifo_data    (),
    .wptr         (),
    .rptr         (),
    .entry_count  (),
    .clear        (flush)
  );

  // pe array
  zvt_pe_array zvtPeArray (
    .clk          (clk),
    .rst_n        (rst_n),
    .peCmdVld     (peCmdVld),
    .peCmd        (uop),
    .peCmdRdy     (peCmdRdy),
    .readMtIdx    (peReadMtIdx),
    .readSubIdx   (peReadSubIdx),
    .readData     (readData),
    .writeEn      (peWriteEn),  
    .writeMtIdx   (peWriteMtIdx),
    .writeSubIdx  (peWriteSubIdx),
    .writeData    (peWriteData),
    .fpexpVld     (fpexpVld),
    .fpexp        (fpexp),
    .fpexpRdy     (fpexpRdy),
    .peRtVld      (peRtVld),
  `ifdef RVVI_ON
    .peRtMtIdx    (peRtMtIdx),
  `endif
    .flush        (flush),
    .busy         (peBusy)
  );

// Retire Cmd
  logic         vmeRtCmdVld;
  VME_RTCMD_t   vmeRtCmd;
  logic         rtCmdAempty;

  // cmd queue
  multi_fifo #(
    .T            (VME_RTCMD_t),
    .M            (1),
    .N            (1),
    .DEPTH        (8),       
    .ASYNC_RSTN   (1'b1)
  ) rtCmdRs (
    .clk          (clk),
    .rst_n        (rst_n),
    .push         (rtCmdVld),
    .datain       (rtCmd),
    .pushRdy      (rtCmdRdy),
    .pop          (vmeRtVld&vmeRtRdy),   
    .dataout      (vmeRtCmd),
    .full         (),
    .almost_full  (),
    .empty        (),
    .almost_empty (rtCmdAempty),
    .fifo_data    (),
    .wptr         (),
    .rptr         (),
    .entry_count  (),
    .clear        (flush)
  );

  assign vmeRtCmdVld = ~rtCmdAempty;

  // register rt valid
  logic miscRtVldD1;
  logic blk0RtVld, blk1RtVld, blk2RtVld, blk3RtVld;
  
  dff regMiscRtVld (.q(miscRtVldD1), .clk(clk), .rst_n(rst_n), .d(miscRtVld));
  dff regBlk0RtVld (.q(blk0RtVld  ), .clk(clk), .rst_n(rst_n), .d(peRtVld[0]));
  dff regBlk1RtVld (.q(blk1RtVld  ), .clk(clk), .rst_n(rst_n), .d(blk0RtVld));
  dff regBlk3RtVld (.q(blk3RtVld  ), .clk(clk), .rst_n(rst_n), .d(blk1RtVld));

  assign blk2RtVld = blk1RtVld;

`ifdef RVVI_ON
  logic [$clog2(`NUM_MT)-1:0] miscRtMtIdxD1;
  logic [$clog2(`NUM_MT)-1:0] blk0RtMtIdx, blk1RtMtIdx, blk2RtMtIdx, blk3RtMtIdx;

  dff #(.WIDTH($clog2(`NUM_MT))) regMiscRtMtIdx (.q(miscRtMtIdxD1), .clk(clk), .rst_n(rst_n), .d(miscRtMtIdx));
  dff #(.WIDTH($clog2(`NUM_MT))) regBlk0RtMtIdx (.q(blk0RtMtIdx  ), .clk(clk), .rst_n(rst_n), .d(peRtMtIdx[0]));
  dff #(.WIDTH($clog2(`NUM_MT))) regBlk1RtMtIdx (.q(blk1RtMtIdx  ), .clk(clk), .rst_n(rst_n), .d(blk0RtMtIdx));
  dff #(.WIDTH($clog2(`NUM_MT))) regBlk3RtMtIdx (.q(blk3RtMtIdx  ), .clk(clk), .rst_n(rst_n), .d(blk1RtMtIdx));
  
  assign blk2RtMtIdx = blk1RtMtIdx;

  // MT accessing
  logic [`NUM_BLK-1:0][3:0][$clog2(`NUM_MT)-1:0]                          rvviMtIdx;
  logic [`NUM_BLK-1:0][3:0][`NUM_SUBTILE/2-1:0]                           rvviSubVld;
  logic [`NUM_BLK-1:0][3:0][`NUM_SUBTILE/2-1:0][$clog2(`NUM_SUBTILE)-1:0] rvviSubIdx;
  logic [`NUM_BLK-1:0][3:0][`NUM_SUBTILE/2-1:0][`SUBTILE_SIZE*8-1:0]      rvviMtData;
  
  localparam BLKID0 = 0;
  localparam BLKID1 = 1;
  localparam BLKID2 = 2;
  localparam BLKID3 = 3;

  always_comb begin
    rvviMtIdx = 'x;
    rvviSubVld = 'b0;
    rvviSubIdx = 'x;

    if(miscRtVldD1) begin
      case(vmeRtCmd.eew_mt)
        EEW8: begin
          rvviMtIdx[BLKID0][0] = miscRtMtIdxD1; 
          rvviMtIdx[BLKID1][0] = miscRtMtIdxD1; 
          rvviMtIdx[BLKID2][0] = miscRtMtIdxD1; 
          rvviMtIdx[BLKID3][0] = miscRtMtIdxD1; 

          for(int i=0;i<`TE/8;i++) begin
            for(int j=0;j<`TE/8;j++) begin
              rvviSubVld[BLKID0][0][i*`TE/8+j] = 1'b1;
              rvviSubVld[BLKID1][0][i*`TE/8+j] = 1'b1;
              rvviSubVld[BLKID2][0][i*`TE/8+j] = 1'b1;
              rvviSubVld[BLKID3][0][i*`TE/8+j] = 1'b1;

              rvviSubIdx[BLKID0][0][i*`TE/8+j] = i*`TE/4 + j;
              rvviSubIdx[BLKID1][0][i*`TE/8+j] = i*`TE/4 + `TE/8 + j;
              rvviSubIdx[BLKID2][0][i*`TE/8+j] = i*`TE/4 + `TE*`TE/32 + j;
              rvviSubIdx[BLKID3][0][i*`TE/8+j] = i*`TE/4 + `TE*`TE/32 + `TE/8 + j;
            end
          end 
        end
        EEW16: begin
          rvviMtIdx[BLKID0][0] = miscRtMtIdxD1; 
          rvviMtIdx[BLKID0][1] = miscRtMtIdxD1 + 'd1; 
          rvviMtIdx[BLKID1][0] = miscRtMtIdxD1; 
          rvviMtIdx[BLKID1][1] = miscRtMtIdxD1 + 'd1; 
          rvviMtIdx[BLKID2][0] = miscRtMtIdxD1; 
          rvviMtIdx[BLKID2][1] = miscRtMtIdxD1 + 'd1; 
          rvviMtIdx[BLKID3][0] = miscRtMtIdxD1; 
          rvviMtIdx[BLKID3][1] = miscRtMtIdxD1 + 'd1; 

          for(int i=0;i<`TE/8;i++) begin
            for(int j=0;j<`TE/8;j++) begin
              rvviSubVld[BLKID0][0][i*`TE/8+j] = 1'b1;
              rvviSubVld[BLKID0][1][i*`TE/8+j] = 1'b1;
              rvviSubVld[BLKID1][0][i*`TE/8+j] = 1'b1;
              rvviSubVld[BLKID1][1][i*`TE/8+j] = 1'b1;
              rvviSubVld[BLKID2][0][i*`TE/8+j] = 1'b1;
              rvviSubVld[BLKID2][1][i*`TE/8+j] = 1'b1;
              rvviSubVld[BLKID3][0][i*`TE/8+j] = 1'b1;
              rvviSubVld[BLKID3][1][i*`TE/8+j] = 1'b1;

              rvviSubIdx[BLKID0][0][i*`TE/8+j] = i*`TE/4 + j;
              rvviSubIdx[BLKID0][1][i*`TE/8+j] = i*`TE/4 + j;
              rvviSubIdx[BLKID1][0][i*`TE/8+j] = i*`TE/4 + `TE/8 + j;
              rvviSubIdx[BLKID1][1][i*`TE/8+j] = i*`TE/4 + `TE/8 + j;
              rvviSubIdx[BLKID2][0][i*`TE/8+j] = i*`TE/4 + `TE*`TE/32 + j;
              rvviSubIdx[BLKID2][1][i*`TE/8+j] = i*`TE/4 + `TE*`TE/32 + j;
              rvviSubIdx[BLKID3][0][i*`TE/8+j] = i*`TE/4 + `TE*`TE/32 + `TE/8 + j;
              rvviSubIdx[BLKID3][1][i*`TE/8+j] = i*`TE/4 + `TE*`TE/32 + `TE/8 + j;
            end
          end        
        end
        default: begin // EEW32
          rvviMtIdx[BLKID0][0] = miscRtMtIdxD1; 
          rvviMtIdx[BLKID0][1] = miscRtMtIdxD1 + 'd1; 
          rvviMtIdx[BLKID0][2] = miscRtMtIdxD1 + 'd2; 
          rvviMtIdx[BLKID0][3] = miscRtMtIdxD1 + 'd3; 
          rvviMtIdx[BLKID1][0] = miscRtMtIdxD1; 
          rvviMtIdx[BLKID1][1] = miscRtMtIdxD1 + 'd1; 
          rvviMtIdx[BLKID1][2] = miscRtMtIdxD1 + 'd2; 
          rvviMtIdx[BLKID1][3] = miscRtMtIdxD1 + 'd3; 
          rvviMtIdx[BLKID2][0] = miscRtMtIdxD1; 
          rvviMtIdx[BLKID2][1] = miscRtMtIdxD1 + 'd1; 
          rvviMtIdx[BLKID2][2] = miscRtMtIdxD1 + 'd2; 
          rvviMtIdx[BLKID2][3] = miscRtMtIdxD1 + 'd3; 
          rvviMtIdx[BLKID3][0] = miscRtMtIdxD1; 
          rvviMtIdx[BLKID3][1] = miscRtMtIdxD1 + 'd1; 
          rvviMtIdx[BLKID3][2] = miscRtMtIdxD1 + 'd2; 
          rvviMtIdx[BLKID3][3] = miscRtMtIdxD1 + 'd3; 

          for(int i=0;i<`TE/4;i++) begin
            for(int j=0;j<`TE/8;j++) begin
              rvviSubVld[BLKID0][0][i*`TE/8+j] = 1'b1;
              rvviSubVld[BLKID0][1][i*`TE/8+j] = 1'b1;
              rvviSubVld[BLKID1][0][i*`TE/8+j] = 1'b1;
              rvviSubVld[BLKID1][1][i*`TE/8+j] = 1'b1;
              rvviSubVld[BLKID2][2][i*`TE/8+j] = 1'b1;
              rvviSubVld[BLKID2][3][i*`TE/8+j] = 1'b1;
              rvviSubVld[BLKID3][2][i*`TE/8+j] = 1'b1;
              rvviSubVld[BLKID3][3][i*`TE/8+j] = 1'b1;

              rvviSubIdx[BLKID0][0][i*`TE/8+j] = i*`TE/4 + j;
              rvviSubIdx[BLKID0][1][i*`TE/8+j] = i*`TE/4 + j;
              rvviSubIdx[BLKID1][0][i*`TE/8+j] = i*`TE/4 + `TE/8 + j;
              rvviSubIdx[BLKID1][1][i*`TE/8+j] = i*`TE/4 + `TE/8 + j;
              rvviSubIdx[BLKID2][2][i*`TE/8+j] = i*`TE/4 + j;
              rvviSubIdx[BLKID2][3][i*`TE/8+j] = i*`TE/4 + j;
              rvviSubIdx[BLKID3][2][i*`TE/8+j] = i*`TE/4 + `TE/8 + j;
              rvviSubIdx[BLKID3][3][i*`TE/8+j] = i*`TE/4 + `TE/8 + j;
            end
          end
        end
      endcase
    end
    else begin
      if(blk0RtVld) begin
        // default: EEW32
        rvviMtIdx[BLKID0][0] = blk0RtMtIdx; 
        rvviMtIdx[BLKID0][1] = blk0RtMtIdx + 'd1; 
        rvviMtIdx[BLKID0][2] = blk0RtMtIdx + 'd2; 
        rvviMtIdx[BLKID0][3] = blk0RtMtIdx + 'd3; 

        for(int i=0;i<`TE/4;i++) begin
          for(int j=0;j<`TE/8;j++) begin
            rvviSubVld[BLKID0][0][i*`TE/8+j] = 1'b1;
            rvviSubVld[BLKID0][1][i*`TE/8+j] = 1'b1;

            rvviSubIdx[BLKID0][0][i*`TE/8+j] = i*`TE/4 + j;
            rvviSubIdx[BLKID0][1][i*`TE/8+j] = i*`TE/4 + j;
          end
        end
      end

      if(blk1RtVld || blk2RtVld) begin
        // default: EEW32
        rvviMtIdx[BLKID1][0] = blk1RtMtIdx; 
        rvviMtIdx[BLKID1][1] = blk1RtMtIdx + 'd1; 
        rvviMtIdx[BLKID1][2] = blk1RtMtIdx + 'd2; 
        rvviMtIdx[BLKID1][3] = blk1RtMtIdx + 'd3; 
        rvviMtIdx[BLKID2][0] = blk1RtMtIdx; 
        rvviMtIdx[BLKID2][1] = blk1RtMtIdx + 'd1; 
        rvviMtIdx[BLKID2][2] = blk1RtMtIdx + 'd2; 
        rvviMtIdx[BLKID2][3] = blk1RtMtIdx + 'd3; 

        for(int i=0;i<`TE/4;i++) begin
          for(int j=0;j<`TE/8;j++) begin
            rvviSubVld[BLKID1][0][i*`TE/8+j] = 1'b1;
            rvviSubVld[BLKID1][1][i*`TE/8+j] = 1'b1;
            rvviSubVld[BLKID2][2][i*`TE/8+j] = 1'b1;
            rvviSubVld[BLKID2][3][i*`TE/8+j] = 1'b1;

            rvviSubIdx[BLKID1][0][i*`TE/8+j] = i*`TE/4 + `TE/8 + j;
            rvviSubIdx[BLKID1][1][i*`TE/8+j] = i*`TE/4 + `TE/8 + j;
            rvviSubIdx[BLKID2][2][i*`TE/8+j] = i*`TE/4 + j;
            rvviSubIdx[BLKID2][3][i*`TE/8+j] = i*`TE/4 + j;
          end
        end
      end

      if(blk3RtVld) begin
        // default: EEW32
        rvviMtIdx[BLKID3][0] = blk0RtMtIdx; 
        rvviMtIdx[BLKID3][1] = blk0RtMtIdx + 'd1; 
        rvviMtIdx[BLKID3][2] = blk0RtMtIdx + 'd2; 
        rvviMtIdx[BLKID3][3] = blk0RtMtIdx + 'd3; 

        for(int i=0;i<`TE/4;i++) begin
          for(int j=0;j<`TE/8;j++) begin
            rvviSubVld[BLKID3][2][i*`TE/8+j] = 1'b1;
            rvviSubVld[BLKID3][3][i*`TE/8+j] = 1'b1;

            rvviSubIdx[BLKID3][2][i*`TE/8+j] = i*`TE/4 + `TE/8 + j;
            rvviSubIdx[BLKID3][3][i*`TE/8+j] = i*`TE/4 + `TE/8 + j;
          end
        end
      end
    end
  end
`endif

  zvt_mt zvtMt(
    .clk            (clk),
    .rst_n          (rst_n),
    .readMtIdx      (readMtIdx),
    .readSubIdx     (readSubIdx),
    .readData       (readData),
  `ifdef RVVI_ON
    .rvviMtIdx      (rvviMtIdx),
    .rvviSubIdx     (rvviSubIdx),
    .rvviReadData   (rvviMtData),
  `endif 
    .writeEn        (writeEn), 
    .writeMtIdx     (writeMtIdx),
    .writeSubIdx    (writeSubIdx),
    .writeData      (writeData) 
  );
  
  // res info queue of each block
  MT_INFO_t [`NUM_BLK-1:0] mtInfo;
  logic     [`NUM_BLK-1:0] mtInfoRdy;
  logic     [`NUM_BLK-1:0] mtRtInfoVld;  
  MT_INFO_t [`NUM_BLK-1:0] mtRtInfo;
  logic     [`NUM_BLK-1:0] mtInfoAempty;

  assign mtInfo[0].Vld = blk0RtVld || miscRtVldD1;
  assign mtInfo[1].Vld = blk1RtVld || miscRtVldD1;
  assign mtInfo[2].Vld = blk2RtVld || miscRtVldD1;
  assign mtInfo[3].Vld = blk3RtVld || miscRtVldD1;

`ifdef RVVI_ON
  for (genvar i=0; i<`NUM_BLK; i++) begin
    assign mtInfo[i].rvviMtIdx  = rvviMtIdx[i];
    assign mtInfo[i].rvviSubVld = rvviSubVld[i];
    assign mtInfo[i].rvviSubIdx = rvviSubIdx[i];
    assign mtInfo[i].rvviData   = rvviMtData[i];
  end
`endif

  for (genvar i=0; i<`NUM_BLK; i++) begin: store_mt_info
    multi_fifo #(
      .T            (MT_INFO_t),
      .M            (1),
      .N            (1),
      .DEPTH        (8),
      .ASYNC_RSTN   (1'b1)
    ) mtInfoRs (
      .clk          (clk),
      .rst_n        (rst_n),
      .push         (mtInfo[i].Vld),
      .datain       (mtInfo[i]),
      .pushRdy      (mtInfoRdy[i]),      
      .pop          (vmeRtVld&vmeRtRdy),  
      .dataout      (mtRtInfo[i]),
      .full         (),
      .almost_full  (),
      .empty        (),
      .almost_empty (mtInfoAempty[i]),
      .fifo_data    (),
      .wptr         (),
      .rptr         (),
      .entry_count  (),
      .clear        (flush)
    );

    assign mtRtInfoVld[i] = ~mtInfoAempty[i];
  `ifdef ASSERT_ON
    `rvv_forbid(mtInfo[i].Vld && !mtInfoRdy[i])
    else $error("Push mtInfoRs[%d] when it is full.\n", i);
  `endif
  end

  // all info is ready
  assign vmeRtVld = vmeRtCmdVld && (&mtRtInfoVld);

`ifdef TB_SUPPORT
  assign vmeRt.inst_pc = vmeRtCmd.inst_pc;
`endif
  assign vmeRt.isStore = vmeRtCmd.isStore;

`ifdef RVVI_ON
  // mt_index
  always_comb begin
    case(vmeRtCmd.eew_mt)
      EEW8:    vmeRt.mtIdxVld = vmeRtCmd.isStore ? 'b0 : 4'b0001;
      EEW16:   vmeRt.mtIdxVld = vmeRtCmd.isStore ? 'b0 : 4'b0011;
      default: vmeRt.mtIdxVld = vmeRtCmd.isStore ? 'b0 : 4'b1111;
    endcase
  end

  assign vmeRt.mtIdx[0] = vmeRtCmd.mt_index;
  assign vmeRt.mtIdx[1] = vmeRtCmd.mt_index + 'd1;
  assign vmeRt.mtIdx[2] = vmeRtCmd.mt_index + 'd2;
  assign vmeRt.mtIdx[3] = vmeRtCmd.mt_index + 'd3;

  // data remap
  always_comb begin
    vmeRt.mtData = 'x;
    
    for (int i=0;i<4;i++) begin: retire_each_mt
      for (int j=0;j<`NUM_BLK;j++) begin: retire_each_block
        for (int h=0;h<`NUM_SUBTILE/2;h++) begin: retire_block_each_port
          if(vmeRtVld && mtRtInfo[j].rvviSubVld[i][h]) begin
            vmeRt.mtData[i][mtRtInfo[j].rvviSubIdx[i][h]] = mtRtInfo[j].rvviData[i][h];
          end
        end
      end
    end
  end

  `ifdef ASSERT_ON
  for(genvar i=0;i<4;i++) begin
    for(genvar j=0;j<`NUM_SUBTILE;j++) begin
      `rvv_forbid(vmeRtVld && vmeRt.mtIdxVld[i] && ($isunknown(vmeRt.mtData[i][j])))
      else $error("The retiring Mt[%d][%d] is undriven.\n", i, j);
    end
  end
  `endif
`endif // RVVI_ON

  // busy
  assign zvtBusy = peBusy || !vmelsuAempty || !vmelsuresAempty;

endmodule
