`ifndef HDL_VERILOG_RVV_DESIGN_RVV_SVH
`include "rvv_backend.svh"
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
  logic [`NUM_BLK-1:0][`NUM_BLKPORT-1:0][$clog2(`NUM_ACC)-1:0]      peReadAccIdx;
  logic [`NUM_BLK-1:0][`NUM_BLKPORT-1:0][$clog2(`NUM_SUBTILE)-1:0]  peReadSubIdx;
  logic [`NUM_BLK-1:0][`NUM_BLKPORT-1:0][`SUBTILE_SIZE-1:0]         peWriteEn;  
  logic [`NUM_BLK-1:0][`NUM_BLKPORT-1:0][$clog2(`NUM_ACC)-1:0]      peWriteAccIdx;
  logic [`NUM_BLK-1:0][`NUM_BLKPORT-1:0][$clog2(`NUM_SUBTILE)-1:0]  peWriteSubIdx;
  logic [`NUM_BLK-1:0][`NUM_BLKPORT-1:0][`SUBTILE_SIZE*8-1:0]       peWriteData;  
  // ACC
  logic [`NUM_BLK-1:0][`NUM_BLKPORT-1:0][$clog2(`NUM_ACC)-1:0]      readAccIdx;
  logic [`NUM_BLK-1:0][`NUM_BLKPORT-1:0][$clog2(`NUM_SUBTILE)-1:0]  readSubIdx;
  logic [`NUM_BLK-1:0][`NUM_BLKPORT-1:0][`SUBTILE_SIZE*8-1:0]       readData;  
  logic [`NUM_BLK-1:0][`NUM_BLKPORT-1:0][`SUBTILE_SIZE-1:0]         writeEn;  
  logic [`NUM_BLK-1:0][`NUM_BLKPORT-1:0][$clog2(`NUM_ACC)-1:0]      writeAccIdx;
  logic [`NUM_BLK-1:0][`NUM_BLKPORT-1:0][$clog2(`NUM_SUBTILE)-1:0]  writeSubIdx;
  logic [`NUM_BLK-1:0][`NUM_BLKPORT-1:0][`SUBTILE_SIZE*8-1:0]       writeData;  

  // Controller
  zvt_ctrl zvtCtrl (
    .clk              (clk),
    .rst_n            (rst_n),
    .uopVld           (uopVld),
    .uop              (uop),
    .uopRdy           (uopRdy),
    .res_vme2rvv_vld  (res_vme2rvv_vld),
    .res_vme2rvv      (res_vme2rvv),
    .res_vme2rvv_rdy  (res_vme2rvv_rdy),
    .vmelsuVld        (vmelsuVld),
    .vmelsu           (vmelsu),
    .vmelsuRdy        (vmelsuRdy),
    .vmelsuresVld     (vmelsuresVld),
    .vmelsures        (vmelsures),
    .vmelsuresRdy     (vmelsuresRdy),
    .peCmdVld         (peCmdVld),
    .peCmdRdy         (peCmdRdy),
    .peBusy           (peBusy),
    .peReadAccIdx     (peReadAccIdx),
    .peReadSubIdx     (peReadSubIdx),
    .peWriteEn        (peWriteEn),  
    .peWriteAccIdx    (peWriteAccIdx),
    .peWriteSubIdx    (peWriteSubIdx),
    .peWriteData      (peWriteData),  
    .readAccIdx       (readAccIdx),
    .readSubIdx       (readSubIdx),
    .readData         (readData),
    .writeEn          (writeEn), 
    .writeAccIdx      (writeAccIdx),
    .writeSubIdx      (writeSubIdx),
    .writeData        (writeData) 
  );

  // LSU
  assign vmelsuRdy        = ~vmelsuAfull;
  assign uop_vme2lsu_vld  = ~vmelsuAempty;
  assign uop_lsu2vme_rdy  = ~vmelsuresAfull;
  assign vmelsuresVld     = ~vmelsuresAempty;

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
    .readAccIdx   (peReadAccIdx),
    .readSubIdx   (peReadSubIdx),
    .readData     (readData),
    .writeEn      (peWriteEn),  
    .writeAccIdx  (peWriteAccIdx),
    .writeSubIdx  (peWriteSubIdx),
    .writeData    (peWriteData),
    .fpexpVld     (fpexpVld),
    .fpexp        (fpexp),
    .fpexpRdy     (fpexpRdy),
    .flush        (flush),
    .busy         (peBusy)
  );

  // ACC
  zvt_acc zvtAcc(
    .clk          (clk),
    .rst_n        (rst_n),
    .readAccIdx   (readAccIdx),
    .readSubIdx   (readSubIdx),
    .readData     (readData),
    .writeEn      (writeEn), 
    .writeAccIdx  (writeAccIdx),
    .writeSubIdx  (writeSubIdx),
    .writeData    (writeData) 
  );

  // busy
  assign zvtBusy = peBusy || !vmelsuAempty || !vmelsuresAempty;

endmodule
