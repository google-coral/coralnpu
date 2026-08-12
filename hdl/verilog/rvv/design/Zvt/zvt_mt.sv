`ifndef HDL_VERILOG_RVV_DESIGN_RVV_SVH
`include "rvv_backend.svh"
`endif

module zvt_mt (
  clk,
  rst_n,
  readMtIdx,
  readSubIdx,
  readData,
`ifdef RVVI_ON
  rvviMtIdx,
  rvviSubIdx,
  rvviReadData,
`endif 
  writeEn, 
  writeMtIdx,
  writeSubIdx,
  writeData
);

// interface signals
  input  logic clk;
  input  logic rst_n;
  // read subtile     
  input  logic [`NUM_BLK-1:0][`NUM_BLKPORT-1:0][$clog2(`NUM_MT)-1:0]      readMtIdx;
  input  logic [`NUM_BLK-1:0][`NUM_BLKPORT-1:0][$clog2(`NUM_SUBTILE)-1:0] readSubIdx;
  output logic [`NUM_BLK-1:0][`NUM_BLKPORT-1:0][`SUBTILE_SIZE*8-1:0]      readData;
`ifdef RVVI_ON
  // rvvi read subtile     
  input  logic [`NUM_BLK-1:0][3:0][$clog2(`NUM_MT)-1:0]                          rvviMtIdx;
  input  logic [`NUM_BLK-1:0][3:0][`NUM_SUBTILE/2-1:0][$clog2(`NUM_SUBTILE)-1:0] rvviSubIdx;
  output logic [`NUM_BLK-1:0][3:0][`NUM_SUBTILE/2-1:0][`SUBTILE_SIZE*8-1:0]      rvviReadData;
`endif 
  // write subtile
  input  logic [`NUM_BLK-1:0][`NUM_BLKPORT-1:0][`SUBTILE_SIZE-1:0]        writeEn;  
  input  logic [`NUM_BLK-1:0][`NUM_BLKPORT-1:0][$clog2(`NUM_MT)-1:0]      writeMtIdx;
  input  logic [`NUM_BLK-1:0][`NUM_BLKPORT-1:0][$clog2(`NUM_SUBTILE)-1:0] writeSubIdx;
  input  logic [`NUM_BLK-1:0][`NUM_BLKPORT-1:0][`SUBTILE_SIZE*8-1:0]      writeData;    

// -------------- code start --------------------    
  // write data
  logic [`NUM_MT-1:0][`NUM_SUBTILE-1:0][`SUBTILE_SIZE-1:0]   wen;    // byte enable
  logic [`NUM_MT-1:0][`NUM_SUBTILE-1:0][`SUBTILE_SIZE*8-1:0] wdata;
  logic [`NUM_MT-1:0][`NUM_SUBTILE-1:0][`SUBTILE_SIZE*8-1:0] mt;

  always_comb begin
    wen      = 'b0;
    wdata    = 'b0;
    readData = 'b0;

    for(int i=0; i<`NUM_BLK; i++) begin: block_addr
      for(int j=0; j<`NUM_BLKPORT; j++) begin: block_subtile_addr
        // write
        // Multiple (i,j) entries can map to the same (mt, sub) slot, and the
        // unused entries default to writeMtIdx=0, writeSubIdx=0, writeEn=0.
        // A blind "last writer wins" assignment lets those zero entries stomp
        // the valid write from a lower (i,j). Guard on writeEn so only entries
        // actually requesting a write contribute.
        if (|writeEn[i][j]) begin
          wen[  writeMtIdx[i][j]][writeSubIdx[i][j]] = writeEn[i][j];
          wdata[writeMtIdx[i][j]][writeSubIdx[i][j]] = writeData[i][j];
        end
        // read
        readData[i][j] = mt[readMtIdx[i][j]][readSubIdx[i][j]];
      end
    end
  end

`ifdef RVVI_ON
  // rvvi read subtile     
  always_comb begin
    for(int i=0;i<`NUM_BLK;i++) begin
      for(int j=0;j<4;j++) begin
        for(int k=0;k<`NUM_SUBTILE/2;k++) begin
          rvviReadData[i][j][k] = mt[rvviMtIdx[i][j]][rvviSubIdx[i][j][k]];
        end
      end
    end
  end
`endif 

  zvt_mt_reg mtReg (
    .clk    (clk),
    .rst_n  (rst_n),
    .wen    (wen),
    .wdata  (wdata),
    .mt     (mt)
  );

endmodule
