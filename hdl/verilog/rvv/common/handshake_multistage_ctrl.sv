// Pipeline handshake logic for multiple stage registers

// This module handles handshaking, provides enable signals on data registers.
// The user then can focus on data processing by using this module.

// NUM_PIPE_REGS indicates how many stages are there in the pipeline.
// REMV_PIPE_BUBBLE when set to 1, bubbles will be removes on back-pressure.
// when set to 0, the overall back-pressure chain will be shorter.

module handshake_multistage_ctrl#(
  parameter int unsigned NUM_PIPE_REGS = 1,  // Pipeline length
  parameter REMV_PIPE_BUBBLE = 0,            // See above

  localparam int unsigned N = NUM_PIPE_REGS  // for simplicity
) (
  input         clk,
  input         rst_n,

  input         up_valid,    // valid signal from upstream
  output        up_ready,    // ready signal to upstream

  output        down_valid,  // valid signal to downstream
  input         down_ready,  // ready signal from downstream

  input         flush,       // clear all valid signals
  output[N-1:0] reg_enable,  // enable signals on each stage
  output[N:1]   valids,      // valid signal on each stage
  output        busy         // any data in flight, ignore input stage
);

  logic [N:0] pip_valid;
  logic [N:0] pip_ready;
 
  // Port connections
  assign pip_valid[0] = up_valid;
  assign up_ready = pip_ready[0];

  assign down_valid = pip_valid[NUM_PIPE_REGS];
  assign pip_ready[NUM_PIPE_REGS] = down_ready;
  assign valids = pip_valid[N:1];
  assign busy = |pip_valid[N:1];

  // Handshake logic
  generate if (REMV_PIPE_BUBBLE) begin: remv_bubb
    // If we need to remove pipeline bubbles, every two stages will handshake
    for (genvar i = 0; i < NUM_PIPE_REGS; i++) begin: gen_handshake

      // For each stage:    (not back-pressure) or (this stage has bubble)
      assign pip_ready[i] =  pip_ready[i+1]     |   ~pip_valid[i+1];
      // use ready as enable for valid, indicates this stage can receive data
      cdffr #(.T(logic)) valid_reg(.q(pip_valid[i+1]), .d(pip_valid[i]), .c(flush), .e(pip_ready[i]), .clk(clk), .rst_n(rst_n));
      // data register enable = handshake success on this stage
      assign reg_enable[i] = pip_valid[i] & pip_ready[i];

    end
  end else begin: keep_bubb
    // If no need to remove bubbles, the pipeline will be treated as a shift register
    // Attention to fanout
    logic can_shift;
    assign can_shift = pip_ready[NUM_PIPE_REGS] | ~pip_valid[NUM_PIPE_REGS];
    // keep pip_ready for waveform compability
    assign pip_ready[NUM_PIPE_REGS-1:0] = {NUM_PIPE_REGS{can_shift}};
    cdffr #(.T(logic[NUM_PIPE_REGS-1:0])) valid_shift_reg(.q(pip_valid[N:1]), .d(pip_valid[N-1:0]), .c(flush), .e(can_shift), .clk(clk), .rst_n(rst_n));
    // all data are also connect to shift
    assign reg_enable = {NUM_PIPE_REGS{can_shift}};
  end endgenerate

endmodule
