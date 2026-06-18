`ifndef HDL_VERILOG_RVV_DESIGN_RVV_SVH
`include "rvv_backend.svh"
`endif

module zvt_acc (
  clk,
  rst_n,
  readAccIdx,
  readSubIdx,
  readData,
  writeEn, 
  writeAccIdx,
  writeSubIdx,
  writeData
);

// interface signals
  input  logic clk;
  input  logic rst_n;
  // read subtile     
  input  logic [`NUM_BLK-1:0][`NUM_BLKPORT-1:0][$clog2(`NUM_ACC)-1:0]     readAccIdx;
  input  logic [`NUM_BLK-1:0][`NUM_BLKPORT-1:0][$clog2(`NUM_SUBTILE)-1:0] readSubIdx;
  output logic [`NUM_BLK-1:0][`NUM_BLKPORT-1:0][`SUBTILE_SIZE*8-1:0]      readData;
  // write subtile
  input  logic [`NUM_BLK-1:0][`NUM_BLKPORT-1:0][`SUBTILE_SIZE-1:0]        writeEn;  
  input  logic [`NUM_BLK-1:0][`NUM_BLKPORT-1:0][$clog2(`NUM_ACC)-1:0]     writeAccIdx;
  input  logic [`NUM_BLK-1:0][`NUM_BLKPORT-1:0][$clog2(`NUM_SUBTILE)-1:0] writeSubIdx;
  input  logic [`NUM_BLK-1:0][`NUM_BLKPORT-1:0][`SUBTILE_SIZE*8-1:0]      writeData;    

// -------------- code start --------------------    
  // write data
  logic [`NUM_ACC-1:0][`NUM_SUBTILE-1:0][`SUBTILE_SIZE-1:0]   wen;    // byte enable
  logic [`NUM_ACC-1:0][`NUM_SUBTILE-1:0][`SUBTILE_SIZE*8-1:0] wdata;
  logic [`NUM_ACC-1:0][`NUM_SUBTILE-1:0][`SUBTILE_SIZE*8-1:0] acc;

  always_comb begin 
    wen      = 'b0; 
    wdata    = 'b0;
    readData = 'b0; 

    for(int i=0; i<`NUM_BLK; i++) begin: block_addr
      for(int j=0; j<`NUM_BLKPORT; j++) begin: block_subtile_addr
        // write
        wen[  writeAccIdx[i][j]][writeSubIdx[i][j]] = writeEn[i][j];
        wdata[writeAccIdx[i][j]][writeSubIdx[i][j]] = writeData[i][j];
        // read
        readData[i][j] = acc[readAccIdx[i][j]][readSubIdx[i][j]];
      end
    end
  end

  zvt_acc_reg accumulator(
    .clk    (clk),
    .rst_n  (rst_n),
    .wen    (wen),
    .wdata  (wdata),
    .acc    (acc)
  );

endmodule
