`ifndef HDL_VERILOG_RVV_DESIGN_RVV_SVH
`include "rvv_backend.svh"
`endif

module zvt_mt_reg (
  clk,
  rst_n,
  wen,
  wdata,
  mt
);

// interface signals
  input  logic clk;
  input  logic rst_n;
  
  input  logic [`NUM_MT-1:0][`NUM_SUBTILE-1:0][`SUBTILE_SIZE-1:0]   wen;    // byte enable
  input  logic [`NUM_MT-1:0][`NUM_SUBTILE-1:0][`SUBTILE_SIZE*8-1:0] wdata;
  output logic [`NUM_MT-1:0][`NUM_SUBTILE-1:0][`SUBTILE_SIZE*8-1:0] mt;

// -------------- code start --------------------    
  genvar i,j,h;
  generate
    for (i=0; i<`NUM_MT; i++) begin: mt_addr
      for (j=0; j<`NUM_SUBTILE; j++) begin: subtile_addr
        for (h=0; h<`SUBTILE_SIZE; h++) begin: byte_addr
           edff #(
             .T       (logic [`BYTE_WIDTH-1:0])
           ) mtRetByte (
             .q       (mt[i][j][h*`BYTE_WIDTH +: `BYTE_WIDTH]),
             .e       (wen[i][j][h]),
             .d       (wdata[i][j][h*`BYTE_WIDTH +: `BYTE_WIDTH]),
             .clk     (clk),
             .rst_n   (rst_n)
           );
        `ifdef ASSERT_ON
          `rvv_forbid($isunknown(mt[i][j][h*`BYTE_WIDTH +: `BYTE_WIDTH]))
          else $error("MTREG: data is unknow at MTreg[%d][%d][%d:%d]",i,j,8*h+7,8*h);
        `endif //ASSERT_ON
        end
      end 
    end 
  endgenerate

endmodule
