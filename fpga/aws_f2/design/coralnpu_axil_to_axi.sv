// Copyright 2026
// SPDX-License-Identifier: Apache-2.0
//
// Serialize AWS's 32-bit OCL AXI-Lite transactions onto Coral NPU's 128-bit
// AXI4 slave port.  Every request is a single 32-bit beat; byte strobes and
// read data are steered to the addressed lane of the 128-bit bus.

module coralnpu_axil_to_axi (
  input  logic         clk,
  input  logic         reset_n,

  input  logic [31:0]  s_awaddr,
  input  logic [2:0]   s_awprot,
  input  logic         s_awvalid,
  output logic         s_awready,
  input  logic [31:0]  s_wdata,
  input  logic [3:0]   s_wstrb,
  input  logic         s_wvalid,
  output logic         s_wready,
  output logic [1:0]   s_bresp,
  output logic         s_bvalid,
  input  logic         s_bready,
  input  logic [31:0]  s_araddr,
  input  logic [2:0]   s_arprot,
  input  logic         s_arvalid,
  output logic         s_arready,
  output logic [31:0]  s_rdata,
  output logic [1:0]   s_rresp,
  output logic         s_rvalid,
  input  logic         s_rready,

  output logic         m_awvalid,
  input  logic         m_awready,
  output logic [31:0]  m_awaddr,
  output logic [2:0]   m_awprot,
  output logic [5:0]   m_awid,
  output logic [7:0]   m_awlen,
  output logic [2:0]   m_awsize,
  output logic [1:0]   m_awburst,
  output logic         m_awlock,
  output logic [3:0]   m_awcache,
  output logic [3:0]   m_awqos,
  output logic [3:0]   m_awregion,
  output logic         m_wvalid,
  input  logic         m_wready,
  output logic [127:0] m_wdata,
  output logic         m_wlast,
  output logic [15:0]  m_wstrb,
  input  logic         m_bvalid,
  output logic         m_bready,
  input  logic [1:0]   m_bresp,
  output logic         m_arvalid,
  input  logic         m_arready,
  output logic [31:0]  m_araddr,
  output logic [2:0]   m_arprot,
  output logic [5:0]   m_arid,
  output logic [7:0]   m_arlen,
  output logic [2:0]   m_arsize,
  output logic [1:0]   m_arburst,
  output logic         m_arlock,
  output logic [3:0]   m_arcache,
  output logic [3:0]   m_arqos,
  output logic [3:0]   m_arregion,
  input  logic         m_rvalid,
  output logic         m_rready,
  input  logic [127:0] m_rdata,
  input  logic [1:0]   m_rresp,
  input  logic         m_rlast
);

  typedef enum logic [2:0] {
    IDLE, WRITE_COLLECT, WRITE_SEND, WRITE_RESP, READ_SEND, READ_RESP
  } state_t;

  state_t state;
  logic aw_held, w_held, aw_sent, w_sent;
  logic [31:0] write_addr, write_data, read_addr;
  logic [2:0] write_prot, read_prot;
  logic [3:0] write_strb;
  logic [1:0] write_lane, read_lane;

  wire take_aw = s_awvalid && s_awready;
  wire take_w  = s_wvalid  && s_wready;
  wire take_ar = s_arvalid && s_arready;
  wire have_aw = aw_held || take_aw;
  wire have_w  = w_held  || take_w;

  always_comb begin
    s_awready = (state == IDLE || state == WRITE_COLLECT) && !aw_held;
    s_wready  = (state == IDLE || state == WRITE_COLLECT) && !w_held;
    // Writes win if a write channel and a read address arrive together.
    s_arready = (state == IDLE) && !aw_held && !w_held &&
                !s_awvalid && !s_wvalid;

    m_awvalid  = (state == WRITE_SEND) && !aw_sent;
    m_awaddr   = write_addr;
    m_awprot   = write_prot;
    m_awid     = '0;
    m_awlen    = '0;
    m_awsize   = 3'd2;
    m_awburst  = 2'b01;
    m_awlock   = 1'b0;
    m_awcache  = '0;
    m_awqos    = '0;
    m_awregion = '0;

    m_wvalid = (state == WRITE_SEND) && !w_sent;
    m_wdata  = 128'b0;
    m_wstrb  = 16'b0;
    m_wdata[write_lane * 32 +: 32] = write_data;
    m_wstrb[write_lane * 4 +: 4] = write_strb;
    m_wlast = 1'b1;

    m_bready = (state == WRITE_RESP) && s_bready;
    s_bvalid = (state == WRITE_RESP) && m_bvalid;
    s_bresp  = m_bresp;

    m_arvalid  = (state == READ_SEND);
    m_araddr   = read_addr;
    m_arprot   = read_prot;
    m_arid     = '0;
    m_arlen    = '0;
    m_arsize   = 3'd2;
    m_arburst  = 2'b01;
    m_arlock   = 1'b0;
    m_arcache  = '0;
    m_arqos    = '0;
    m_arregion = '0;

    m_rready = (state == READ_RESP) && s_rready;
    s_rvalid = (state == READ_RESP) && m_rvalid;
    s_rresp  = m_rresp;
    s_rdata  = m_rdata[read_lane * 32 +: 32];
  end

  always_ff @(posedge clk) begin
    if (!reset_n) begin
      state       <= IDLE;
      aw_held     <= 1'b0;
      w_held      <= 1'b0;
      aw_sent     <= 1'b0;
      w_sent      <= 1'b0;
      write_addr  <= '0;
      write_data  <= '0;
      write_prot  <= '0;
      write_strb  <= '0;
      write_lane  <= '0;
      read_addr   <= '0;
      read_prot   <= '0;
      read_lane   <= '0;
    end else begin
      if (take_aw) begin
        write_addr <= s_awaddr;
        write_prot <= s_awprot;
        write_lane <= s_awaddr[3:2];
        aw_held    <= 1'b1;
      end
      if (take_w) begin
        write_data <= s_wdata;
        write_strb <= s_wstrb;
        w_held     <= 1'b1;
      end

      case (state)
        IDLE, WRITE_COLLECT: begin
          if (have_aw && have_w) begin
            state   <= WRITE_SEND;
            aw_sent <= 1'b0;
            w_sent  <= 1'b0;
          end else if (have_aw || have_w) begin
            state <= WRITE_COLLECT;
          end else if (take_ar) begin
            read_addr <= s_araddr;
            read_prot <= s_arprot;
            read_lane <= s_araddr[3:2];
            state     <= READ_SEND;
          end
        end

        WRITE_SEND: begin
          if (m_awvalid && m_awready) aw_sent <= 1'b1;
          if (m_wvalid  && m_wready)  w_sent  <= 1'b1;
          if ((aw_sent || (m_awvalid && m_awready)) &&
              (w_sent  || (m_wvalid  && m_wready))) begin
            state <= WRITE_RESP;
          end
        end

        WRITE_RESP: begin
          if (m_bvalid && s_bready) begin
            aw_held <= 1'b0;
            w_held  <= 1'b0;
            state   <= IDLE;
          end
        end

        READ_SEND: begin
          if (m_arready) state <= READ_RESP;
        end

        READ_RESP: begin
          if (m_rvalid && s_rready) state <= IDLE;
        end

        default: state <= IDLE;
      endcase
    end
  end

  // Coral returns one beat for these single-beat requests. This is a guard
  // against accidentally wiring the bridge to a burst-capable target later.
  always_ff @(posedge clk) begin
    if (reset_n && state == READ_RESP && m_rvalid && !m_rlast)
      $error("Coral NPU returned a non-final beat to an AXI-Lite read");
  end

endmodule
