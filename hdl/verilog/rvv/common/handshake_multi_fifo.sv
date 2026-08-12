// handshake_fifo - FIFO with handshake mechanism

module handshake_fifo (
  indata,
  invalid,
  inready,
  outdata,
  outvalid,
  outready,
  clear,
  fifo_data,
  wptr,
  rptr,
  entry_count,
  clk, rst_n
);

  parameter type T      = logic [7:0];  // data structure
  parameter M           = 4;            // indata number
  parameter N           = 4;            // outdata number
  parameter DEPTH       = 16;           // fifo depth
  parameter POP_CLEAR   = 1'b0;         // clear data once pop
  parameter ASYNC_RSTN  = 1'b0;         // reset data
  parameter CHAOS_PUSH  = 1'b0;         // support push data disorderly
  parameter DATAOUT_REG = 1'b0;         // dataout signal register output. 

  localparam DEPTH_BITS = $clog2(DEPTH);

  output T     [N-1:0] outdata;
  output logic [N-1:0] outvalid;
  input  logic [N-1:0] outready;

  input  T     [M-1:0] indata;
  input  logic [M-1:0] invalid;
  output logic [M-1:0] inready;
  input  logic         clk;
  input  logic         rst_n;

  input  logic         clear;
  output T     [DEPTH-1:0]  fifo_data;
  output logic [DEPTH_BITS-1:0] wptr;
  output logic [DEPTH_BITS-1:0] rptr;
  output logic [DEPTH_BITS  :0] entry_count;


  logic [M-1:0]        push;
  logic [N-1:0]        pop;
  logic                full;
  logic [M-1:0]        almost_full;
  logic                empty;
  logic [N-1:0]        almost_empty;

  genvar i;
  generate
    for (i=0; i<M; i++) begin : gen_push
      assign inready[i] = ~almost_full[i];
      assign push[i] = invalid[i] & inready[i];
    end

    for (i=0; i<N; i++) begin : gen_pop
      assign outvalid[i] = ~almost_empty[i];
      assign pop[i] = outvalid[i] & outready[i];
    end
  endgenerate

  multi_fifo #(
    .T              (T),
    .M              (M),
    .N              (N),
    .DEPTH          (DEPTH),
    .POP_CLEAR      (POP_CLEAR),
    .ASYNC_RSTN     (ASYNC_RSTN),
    .CHAOS_PUSH     (CHAOS_PUSH),
    .DATAOUT_REG    (DATAOUT_REG)
  ) u_div_rs (
    // global
    .clk            (clk),
    .rst_n          (rst_n),
    // write
    .push           (push),
    .datain         (indata),
    .pushRdy        (),
    // read
    .pop            (pop),
    .dataout        (outdata),
    // fifo status
    .full           (full),
    .almost_full    (almost_full),
    .empty          (empty),
    .almost_empty   (almost_empty),
    .clear          (clear),
    .fifo_data      (fifo_data),
    .wptr           (wptr),
    .rptr           (rptr),
    .entry_count    (entry_count)
  );

endmodule
