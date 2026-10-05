// Copyright 2026 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

// ==============================================================================
// UltraScale+ Inter-Die SLL AXI Register Slice (Skid Buffer)
//
// Provides 100% register isolation for inter-SLR crossings.
// Maps to dedicated Xilinx Laguna flip-flops (REG_LAGUNA), eliminating long SLL
// routing delays across SLR boundaries with zero bubbles (sustained 1 beat/clk).
// ==============================================================================

`timescale 1ns / 1ps

module fpga_skid_buffer #(
    parameter int WIDTH = 32
) (
    input  logic             clk,
    input  logic             rst_n,
    input  logic             s_valid,
    output logic             s_ready,
    input  logic [WIDTH-1:0] s_data,
    output logic             m_valid,
    input  logic             m_ready,
    output logic [WIDTH-1:0] m_data
);
  logic [WIDTH-1:0] buf_data;
  logic [WIDTH-1:0] skid_data;
  logic             buf_valid;
  logic             skid_valid;

  assign s_ready = !skid_valid;
  assign m_valid = buf_valid;
  assign m_data  = buf_data;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      buf_valid  <= 1'b0;
      skid_valid <= 1'b0;
      buf_data   <= '0;
      skid_data  <= '0;
    end else begin
      if (m_ready) begin
        if (skid_valid) begin
          buf_valid  <= 1'b1;
          buf_data   <= skid_data;
          skid_valid <= 1'b0;
        end else if (s_valid) begin
          buf_valid  <= 1'b1;
          buf_data   <= s_data;
          skid_valid <= 1'b0;
        end else begin
          buf_valid <= 1'b0;
        end
      end else begin
        // Downstream stalled; capture in skid register if primary is occupied
        if (s_valid && s_ready) begin
          if (buf_valid) begin
            skid_valid <= 1'b1;
            skid_data  <= s_data;
          end else begin
            buf_valid <= 1'b1;
            buf_data  <= s_data;
          end
        end
      end
    end
  end
endmodule

module fpga_axi_reg_slice #(
    parameter int ADDR_WIDTH = 34,
    parameter int DATA_WIDTH = 512,
    parameter int ID_WIDTH   = 4,
    parameter int STRB_WIDTH = DATA_WIDTH / 8
) (
    input logic clk,
    input logic rst_n,

    // Slave Interface (from SoC / Interconnect)
    input  logic                  s_axi_awvalid,
    output logic                  s_axi_awready,
    input  logic [ADDR_WIDTH-1:0] s_axi_awaddr,
    input  logic [  ID_WIDTH-1:0] s_axi_awid,
    input  logic [           7:0] s_axi_awlen,
    input  logic [           2:0] s_axi_awsize,
    input  logic [           1:0] s_axi_awburst,
    input  logic [           0:0] s_axi_awlock,
    input  logic [           3:0] s_axi_awcache,
    input  logic [           2:0] s_axi_awprot,
    input  logic [           3:0] s_axi_awqos,

    input  logic                  s_axi_wvalid,
    output logic                  s_axi_wready,
    input  logic [DATA_WIDTH-1:0] s_axi_wdata,
    input  logic [STRB_WIDTH-1:0] s_axi_wstrb,
    input  logic                  s_axi_wlast,

    output logic                s_axi_bvalid,
    input  logic                s_axi_bready,
    output logic [ID_WIDTH-1:0] s_axi_bid,
    output logic [         1:0] s_axi_bresp,

    input  logic                  s_axi_arvalid,
    output logic                  s_axi_arready,
    input  logic [ADDR_WIDTH-1:0] s_axi_araddr,
    input  logic [  ID_WIDTH-1:0] s_axi_arid,
    input  logic [           7:0] s_axi_arlen,
    input  logic [           2:0] s_axi_arsize,
    input  logic [           1:0] s_axi_arburst,
    input  logic [           0:0] s_axi_arlock,
    input  logic [           3:0] s_axi_arcache,
    input  logic [           2:0] s_axi_arprot,
    input  logic [           3:0] s_axi_arqos,

    output logic                  s_axi_rvalid,
    input  logic                  s_axi_rready,
    output logic [  ID_WIDTH-1:0] s_axi_rid,
    output logic [DATA_WIDTH-1:0] s_axi_rdata,
    output logic [           1:0] s_axi_rresp,
    output logic                  s_axi_rlast,

    // Master Interface (to DDR4 Controller)
    output logic                  m_axi_awvalid,
    input  logic                  m_axi_awready,
    output logic [ADDR_WIDTH-1:0] m_axi_awaddr,
    output logic [  ID_WIDTH-1:0] m_axi_awid,
    output logic [           7:0] m_axi_awlen,
    output logic [           2:0] m_axi_awsize,
    output logic [           1:0] m_axi_awburst,
    output logic [           0:0] m_axi_awlock,
    output logic [           3:0] m_axi_awcache,
    output logic [           2:0] m_axi_awprot,
    output logic [           3:0] m_axi_awqos,

    output logic                  m_axi_wvalid,
    input  logic                  m_axi_wready,
    output logic [DATA_WIDTH-1:0] m_axi_wdata,
    output logic [STRB_WIDTH-1:0] m_axi_wstrb,
    output logic                  m_axi_wlast,

    input  logic                m_axi_bvalid,
    output logic                m_axi_bready,
    input  logic [ID_WIDTH-1:0] m_axi_bid,
    input  logic [         1:0] m_axi_bresp,

    output logic                  m_axi_arvalid,
    input  logic                  m_axi_arready,
    output logic [ADDR_WIDTH-1:0] m_axi_araddr,
    output logic [  ID_WIDTH-1:0] m_axi_arid,
    output logic [           7:0] m_axi_arlen,
    output logic [           2:0] m_axi_arsize,
    output logic [           1:0] m_axi_arburst,
    output logic [           0:0] m_axi_arlock,
    output logic [           3:0] m_axi_arcache,
    output logic [           2:0] m_axi_arprot,
    output logic [           3:0] m_axi_arqos,

    input  logic                  m_axi_rvalid,
    output logic                  m_axi_rready,
    input  logic [  ID_WIDTH-1:0] m_axi_rid,
    input  logic [DATA_WIDTH-1:0] m_axi_rdata,
    input  logic [           1:0] m_axi_rresp,
    input  logic                  m_axi_rlast
);

  localparam int AW_PAYLOAD_W = ADDR_WIDTH + ID_WIDTH + 8 + 3 + 2 + 1 + 4 + 3 + 4;
  localparam int W_PAYLOAD_W = DATA_WIDTH + STRB_WIDTH + 1;
  localparam int B_PAYLOAD_W = ID_WIDTH + 2;
  localparam int AR_PAYLOAD_W = ADDR_WIDTH + ID_WIDTH + 8 + 3 + 2 + 1 + 4 + 3 + 4;
  localparam int R_PAYLOAD_W = ID_WIDTH + DATA_WIDTH + 2 + 1;

  // AW Channel
  wire [AW_PAYLOAD_W-1:0] s_aw_payload = {
    s_axi_awaddr,
    s_axi_awid,
    s_axi_awlen,
    s_axi_awsize,
    s_axi_awburst,
    s_axi_awlock,
    s_axi_awcache,
    s_axi_awprot,
    s_axi_awqos
  };
  wire [AW_PAYLOAD_W-1:0] m_aw_payload;
  assign {m_axi_awaddr, m_axi_awid, m_axi_awlen, m_axi_awsize,
          m_axi_awburst, m_axi_awlock, m_axi_awcache, m_axi_awprot, m_axi_awqos} = m_aw_payload;

  fpga_skid_buffer #(
      .WIDTH(AW_PAYLOAD_W)
  ) u_aw_slice (
      .clk    (clk),
      .rst_n  (rst_n),
      .s_valid(s_axi_awvalid),
      .s_ready(s_axi_awready),
      .s_data (s_aw_payload),
      .m_valid(m_axi_awvalid),
      .m_ready(m_axi_awready),
      .m_data (m_aw_payload)
  );

  // W Channel
  wire [W_PAYLOAD_W-1:0] s_w_payload = {s_axi_wdata, s_axi_wstrb, s_axi_wlast};
  wire [W_PAYLOAD_W-1:0] m_w_payload;
  assign {m_axi_wdata, m_axi_wstrb, m_axi_wlast} = m_w_payload;

  fpga_skid_buffer #(
      .WIDTH(W_PAYLOAD_W)
  ) u_w_slice (
      .clk    (clk),
      .rst_n  (rst_n),
      .s_valid(s_axi_wvalid),
      .s_ready(s_axi_wready),
      .s_data (s_w_payload),
      .m_valid(m_axi_wvalid),
      .m_ready(m_axi_wready),
      .m_data (m_w_payload)
  );

  // B Channel (Slave to Master direction)
  wire [B_PAYLOAD_W-1:0] m_b_payload = {m_axi_bid, m_axi_bresp};
  wire [B_PAYLOAD_W-1:0] s_b_payload;
  assign {s_axi_bid, s_axi_bresp} = s_b_payload;

  fpga_skid_buffer #(
      .WIDTH(B_PAYLOAD_W)
  ) u_b_slice (
      .clk    (clk),
      .rst_n  (rst_n),
      .s_valid(m_axi_bvalid),
      .s_ready(m_axi_bready),
      .s_data (m_b_payload),
      .m_valid(s_axi_bvalid),
      .m_ready(s_axi_bready),
      .m_data (s_b_payload)
  );

  // AR Channel
  wire [AR_PAYLOAD_W-1:0] s_ar_payload = {
    s_axi_araddr,
    s_axi_arid,
    s_axi_arlen,
    s_axi_arsize,
    s_axi_arburst,
    s_axi_arlock,
    s_axi_arcache,
    s_axi_arprot,
    s_axi_arqos
  };
  wire [AR_PAYLOAD_W-1:0] m_ar_payload;
  assign {m_axi_araddr, m_axi_arid, m_axi_arlen, m_axi_arsize,
          m_axi_arburst, m_axi_arlock, m_axi_arcache, m_axi_arprot, m_axi_arqos} = m_ar_payload;

  fpga_skid_buffer #(
      .WIDTH(AR_PAYLOAD_W)
  ) u_ar_slice (
      .clk    (clk),
      .rst_n  (rst_n),
      .s_valid(s_axi_arvalid),
      .s_ready(s_axi_arready),
      .s_data (s_ar_payload),
      .m_valid(m_axi_arvalid),
      .m_ready(m_axi_arready),
      .m_data (m_ar_payload)
  );

  // R Channel (Slave to Master direction)
  wire [R_PAYLOAD_W-1:0] m_r_payload = {m_axi_rid, m_axi_rdata, m_axi_rresp, m_axi_rlast};
  wire [R_PAYLOAD_W-1:0] s_r_payload;
  assign {s_axi_rid, s_axi_rdata, s_axi_rresp, s_axi_rlast} = s_r_payload;

  fpga_skid_buffer #(
      .WIDTH(R_PAYLOAD_W)
  ) u_r_slice (
      .clk    (clk),
      .rst_n  (rst_n),
      .s_valid(m_axi_rvalid),
      .s_ready(m_axi_rready),
      .s_data (m_r_payload),
      .m_valid(s_axi_rvalid),
      .m_ready(s_axi_rready),
      .m_data (s_r_payload)
  );

endmodule
