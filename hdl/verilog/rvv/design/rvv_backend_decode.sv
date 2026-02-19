//
// description: 
// 1. It will read instructions from Command Queue and decode the instructions to uops and write to Uop Queue.
//
// feature list:
// 1. One instruction can be decoded to 8 uops at most according to RISC-V spec.
// 2. Decoder will push 4 uops at most into Uops Queue, so decoder only decode to 4 uops at most per cycle.  
// 3. If the instruction is in wrong encoding, it will be discarded directly without applying a trap.
// 4. When decoding, if the elements of one uop all belongs to ¡®prestart¡¯, this uop will be discarded.
// 5. The vstart of the instruction will be calculated to a new value for every decoded uops.
// 6. Fault-only-first load instruction will be regarded as regular unit-stride load instruction.
// 7. Vector segment vload/vstore instructions will be decoded to regular stride or indexed vload/vstore uops. 

`ifndef HDL_VERILOG_RVV_DESIGN_RVV_SVH
`include "rvv_backend.svh"
`endif
`ifndef RVV_ASSERT__SVH
`include "rvv_backend_sva.svh"
`endif

module rvv_backend_decode
(
  clk,
  rst_n,
  inst_pkg_cq2de, 
  fifo_empty_cq2de,
  fifo_almost_empty_cq2de,
  pop_de2cq,
  push_de2uq,
  data_de2uq,
  fifo_full_uq2de, 
  fifo_almost_full_uq2de,
  trap_flush_rvv
);
//
// interface signals
//
  // global signal
  input   logic                         clk;
  input   logic                         rst_n;
  
  // signals from command queue
  input   RVVCmd  [`NUM_DE_INST-1:0]    inst_pkg_cq2de; 
  input   logic                         fifo_empty_cq2de;
  input   logic   [`NUM_DE_INST-1:0]    fifo_almost_empty_cq2de;
  output  logic   [`NUM_DE_INST-1:0]    pop_de2cq;

  // signals from Uops Quue
  output  logic   [`NUM_DE_UOP-1:0]     push_de2uq;
  output  UOP_QUEUE_t [`NUM_DE_UOP-1:0] data_de2uq;
  input   logic                         fifo_full_uq2de;
  input   logic   [`NUM_DE_UOP-1:0]     fifo_almost_full_uq2de;

  // trap-flush
  input   logic                         trap_flush_rvv;

//
// internal signals
//
  // instruction struct valid signal 
  logic       [`NUM_DE_INST-1:0]                  pkg_valid;
  
  // the decoded uops
  logic       [`NUM_DE_INST-1:0][`NUM_DE_UOP-1:0] uop_valid_de2uq;
  UOP_QUEUE_t [`NUM_DE_INST-1:0][`NUM_DE_UOP-1:0] uop_de2uq;
 
  // uop index from controller
  logic       [`UOP_INDEX_WIDTH-1:0]              uop_index_remain;
  
  // for-loop
  genvar                                          i;

//
// decode
//
  // get data valid signals
  assign pkg_valid[0] = !fifo_empty_cq2de;

  generate 
    for (i=1;i<`NUM_DE_INST;i=i+1) begin: GET_PKG_VALID
      assign pkg_valid[i] = !(|fifo_almost_empty_cq2de[i:0]);
    end
  endgenerate

  // decode unit
  rvv_backend_decode_unit u_decode_unit0
  (
    .inst_valid_cq2de       (pkg_valid[0]),
    .inst_cq2de             (inst_pkg_cq2de[0]),
    .uop_index_remain       (uop_index_remain),
    .uop_valid_de2uq        (uop_valid_de2uq[0]),
    .uop_de2uq              (uop_de2uq[0])
  );
   
  generate 
    for (i=1;i<`NUM_DE_INST;i=i+1) begin: DECODE_UNIT
      rvv_backend_decode_unit u_decode_unit1
      (
        .inst_valid_cq2de   (pkg_valid[i]),
        .inst_cq2de         (inst_pkg_cq2de[i]),
        .uop_index_remain   ({`UOP_INDEX_WIDTH{1'b0}}),
        .uop_valid_de2uq    (uop_valid_de2uq[i]),
        .uop_de2uq          (uop_de2uq[i])
      );    
    end
  endgenerate
  
  // decode controller
  rvv_backend_decode_ctrl u_decode_ctrl
  (
    .clk                    (clk),
    .rst_n                  (rst_n),
    .pkg_valid              (pkg_valid),
    .uop_valid_de2uq        (uop_valid_de2uq),
    .uop_de2uq              (uop_de2uq),
    .uop_index_remain       (uop_index_remain),
    .pop                    (pop_de2cq),
    .push                   (push_de2uq),
    .dataout                (data_de2uq),
    .fifo_full_uq2de        (fifo_full_uq2de), 
    .fifo_almost_full_uq2de (fifo_almost_full_uq2de),
    .trap_flush_rvv         (trap_flush_rvv)
  );

endmodule
