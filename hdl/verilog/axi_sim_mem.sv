// Copyright 2026 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

// Simulation-only AXI4 slave memory. The storage lives in C++ (ddr_sim_mem.cc)
// behind DPI so the testbench can load and inspect it through a backdoor
// (ddr_backdoor_*_c) without any bus traffic, and so the core's weight
// streaming never enters Python. One outstanding read burst and one
// outstanding write burst; responses the cycle after acceptance.
//
// Burst handling: INCR increments by 2**size per beat, FIXED repeats the
// address, WRAP is treated as INCR (the core does not issue WRAP bursts to
// external memory). Out-of-range beats return SLVERR like the Python model.

module axi_sim_mem #(
    parameter int ADDR_W = 32,
    parameter int DATA_W = 128,
    parameter int ID_W   = 6,
    parameter int STRB_W = DATA_W / 8
) (
    input  logic              clk,
    input  logic              rst_n,
    // Write address
    input  logic              aw_valid,
    output logic              aw_ready,
    input  logic [ADDR_W-1:0] aw_addr,
    input  logic [ID_W-1:0]   aw_id,
    input  logic [7:0]        aw_len,
    input  logic [2:0]        aw_size,
    input  logic [1:0]        aw_burst,
    // Write data
    input  logic              w_valid,
    output logic              w_ready,
    input  logic [DATA_W-1:0] w_data,
    input  logic [STRB_W-1:0] w_strb,
    input  logic              w_last,
    // Write response
    output logic              b_valid,
    input  logic              b_ready,
    output logic [ID_W-1:0]   b_id,
    output logic [1:0]        b_resp,
    // Read address
    input  logic              ar_valid,
    output logic              ar_ready,
    input  logic [ADDR_W-1:0] ar_addr,
    input  logic [ID_W-1:0]   ar_id,
    input  logic [7:0]        ar_len,
    input  logic [2:0]        ar_size,
    input  logic [1:0]        ar_burst,
    // Read data
    output logic              r_valid,
    input  logic              r_ready,
    output logic [DATA_W-1:0] r_data,
    output logic [ID_W-1:0]   r_id,
    output logic [1:0]        r_resp,
    output logic              r_last
);
  // Returns 0 on success, non-zero if addr is outside the configured window.
  import "DPI-C" function int ddr_sim_read(input longint unsigned addr, output bit [127:0] data);
  import "DPI-C" function int ddr_sim_write(input longint unsigned addr, input bit [127:0] data,
                                            input bit [15:0] strb);

  localparam logic [1:0] kBurstFixed = 2'b00;
  localparam logic [1:0] kRespOkay   = 2'b00;
  localparam logic [1:0] kRespSlvErr = 2'b10;

  function automatic logic [ADDR_W-1:0] next_addr(logic [ADDR_W-1:0] a, logic [2:0] size,
                                                  logic [1:0] burst);
    if (burst == kBurstFixed) return a;
    return a + (ADDR_W'(1) << size);
  endfunction

  // ---------------------------------------------------------------- reads
  logic              rd_active;
  logic [ADDR_W-1:0] rd_addr;
  logic [7:0]        rd_left;
  logic [ID_W-1:0]   rd_id;
  logic [2:0]        rd_size;
  logic [1:0]        rd_burst;
  logic              rd_err;
  logic [127:0]      rd_data_q;

  assign ar_ready = !rd_active;
  assign r_valid  = rd_active;
  assign r_last   = (rd_left == 8'd0);
  assign r_id     = rd_id;
  assign r_resp   = rd_err ? kRespSlvErr : kRespOkay;
  assign r_data   = rd_data_q[DATA_W-1:0];

  always_ff @(posedge clk) begin
    bit [127:0] tmp;
    int         err;
    if (!rst_n) begin
      rd_active <= 1'b0;
      rd_left   <= 8'd0;
      rd_err    <= 1'b0;
    end else if (ar_valid && ar_ready) begin
      err       = ddr_sim_read(64'(ar_addr), tmp);
      rd_data_q <= tmp;
      rd_err    <= (err != 0);
      rd_active <= 1'b1;
      rd_id     <= ar_id;
      rd_left   <= ar_len;
      rd_size   <= ar_size;
      rd_burst  <= ar_burst;
      rd_addr   <= next_addr(ar_addr, ar_size, ar_burst);
    end else if (r_valid && r_ready) begin
      if (rd_left == 8'd0) begin
        rd_active <= 1'b0;
      end else begin
        err       = ddr_sim_read(64'(rd_addr), tmp);
        rd_data_q <= tmp;
        rd_err    <= (err != 0);
        rd_left   <= rd_left - 8'd1;
        rd_addr   <= next_addr(rd_addr, rd_size, rd_burst);
      end
    end
  end

  // --------------------------------------------------------------- writes
  logic              wr_active;   // AW accepted, collecting W beats
  logic              b_pending;
  logic [ADDR_W-1:0] wr_addr;
  logic [ID_W-1:0]   wr_id;
  logic [2:0]        wr_size;
  logic [1:0]        wr_burst;
  logic              wr_err;

  // Bounded trace of the first transactions and of every error response, so
  // a failing run shows what the core asked for without a waveform.
  int trace_left = 48;
  always_ff @(posedge clk) begin
    if (rst_n) begin
      if (ar_valid && ar_ready && trace_left > 0) begin
        trace_left--;
        $display("[axi_sim_mem] AR addr=0x%08x id=%0d len=%0d size=%0d burst=%0d", ar_addr, ar_id,
                 ar_len, ar_size, ar_burst);
      end
      if (aw_valid && aw_ready && trace_left > 0) begin
        trace_left--;
        $display("[axi_sim_mem] AW addr=0x%08x id=%0d len=%0d size=%0d burst=%0d", aw_addr, aw_id,
                 aw_len, aw_size, aw_burst);
      end
      if (r_valid && r_ready && (trace_left > 0 || r_resp != kRespOkay)) begin
        if (trace_left > 0) trace_left--;
        $display("[axi_sim_mem] R  id=%0d resp=%0d last=%0d left=%0d active=%0d data=0x%032x", r_id, r_resp,
                 r_last, rd_left, rd_active, r_data);
      end
      if (b_valid && b_ready && (trace_left > 0 || b_resp != kRespOkay)) begin
        if (trace_left > 0) trace_left--;
        $display("[axi_sim_mem] B  id=%0d resp=%0d", b_id, b_resp);
      end
    end
  end

  assign aw_ready = !wr_active && !b_pending;
  assign w_ready  = wr_active;
  assign b_valid  = b_pending;
  assign b_id     = wr_id;
  assign b_resp   = wr_err ? kRespSlvErr : kRespOkay;

  always_ff @(posedge clk) begin
    int err;
    if (!rst_n) begin
      wr_active <= 1'b0;
      b_pending <= 1'b0;
      wr_err    <= 1'b0;
    end else begin
      if (aw_valid && aw_ready) begin
        wr_active <= 1'b1;
        wr_addr   <= aw_addr;
        wr_id     <= aw_id;
        wr_size   <= aw_size;
        wr_burst  <= aw_burst;
        wr_err    <= 1'b0;
      end
      if (w_valid && w_ready) begin
        err     = ddr_sim_write(64'(wr_addr), 128'(w_data), 16'(w_strb));
        wr_err  <= wr_err | (err != 0);
        wr_addr <= next_addr(wr_addr, wr_size, wr_burst);
        if (w_last) begin
          wr_active <= 1'b0;
          b_pending <= 1'b1;
        end
      end
      if (b_valid && b_ready) begin
        b_pending <= 1'b0;
      end
    end
  end
endmodule
