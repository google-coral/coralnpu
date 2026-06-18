`ifndef HDL_VERILOG_RVV_DESIGN_RVV_SVH
`include "rvv_backend.svh"
`endif

module zvt_acc_reg (
  clk,
  rst_n,
  wen,
  wdata,
  acc
);

// interface signals
  input  logic clk;
  input  logic rst_n;
  
  input  logic [`NUM_ACC-1:0][`NUM_SUBTILE-1:0][`SUBTILE_SIZE-1:0]   wen;    // byte enable
  input  logic [`NUM_ACC-1:0][`NUM_SUBTILE-1:0][`SUBTILE_SIZE*8-1:0] wdata;
  output logic [`NUM_ACC-1:0][`NUM_SUBTILE-1:0][`SUBTILE_SIZE*8-1:0] acc;

// -------------- code start --------------------    
  genvar i,j,h;
  generate
    for (i=0; i<`NUM_ACC; i++) begin: acc_addr
      for (j=0; j<`NUM_SUBTILE; j++) begin: subtile_addr
        for (h=0; h<`SUBTILE_SIZE; h++) begin: byte_addr
           edff #(
             .T       (logic [`BYTE_WIDTH-1:0])
           ) acc_reg (
             .q       (acc[i][j][h*`BYTE_WIDTH +: `BYTE_WIDTH]),
             .e       (wen[i][j][h]),
             .d       (wdata[i][j][h*`BYTE_WIDTH +: `BYTE_WIDTH]),
             .clk     (clk),
             .rst_n   (rst_n)
           );
        `ifdef ASSERT_ON
          `rvv_forbid($isunknown(acc[i][j][h*`BYTE_WIDTH +: `BYTE_WIDTH]))
            else $error("ACCREG: data is unknow at ACCreg[%d][%d][%d:%d]",i,j,8*h+7,8*h);
        `endif //ASSERT_ON
        end
      end 
    end 
  endgenerate

endmodule
