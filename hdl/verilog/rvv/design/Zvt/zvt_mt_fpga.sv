// Copyright 2026 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

`ifndef HDL_VERILOG_RVV_DESIGN_RVV_SVH
`include "rvv_backend.svh"
`endif
`ifdef ASSERT_ON
`ifndef RVV_ASSERT__SVH
`include "rvv_backend_sva.svh"
`endif
`endif

`ifdef FPGA_XILINX
/**
 * zvt_mt_fpga_bank: Parameterized Synchronous UltraRAM Bank Primitive for FPGA
 *
 * Infers AMD UltraScale+ hardened URAM288 (or RAMB36E2) primitives.
 * Provides 1 synchronous write port with byte enables and 1 synchronous
 * 1-cycle clock-gated read port.
 */
module zvt_mt_fpga_bank #(
  parameter int DEPTH      = 16,
  parameter int ADDR_WIDTH = $clog2(DEPTH)
) (
  input  logic                       clk,
  input  logic                       ren,    // Read enable (holds rdata on stall)
  input  logic [ADDR_WIDTH-1:0]      raddr,  // Bank read entry address
  output logic [`SUBTILE_SIZE*8-1:0] rdata,  // 128-bit subtile word (1-cycle read)
  input  logic [`SUBTILE_SIZE-1:0]   wen,    // 16-bit byte write enable
  input  logic [ADDR_WIDTH-1:0]      waddr,  // Bank write entry address
  input  logic [`SUBTILE_SIZE*8-1:0] wdata   // 128-bit subtile word
);

  (* ram_style = "ultra" *) logic [`SUBTILE_SIZE*8-1:0] mem [DEPTH];

  // Synchronous byte-enabled write
  always_ff @(posedge clk) begin
    for (int h = 0; h < `SUBTILE_SIZE; h++) begin
      if (wen[h]) begin
        mem[waddr][h*8 +: 8] <= wdata[h*8 +: 8];
      end
    end
  end

  // Synchronous 1-cycle read with clock-enable gating
  always_ff @(posedge clk) begin
    if (ren) begin
      rdata <= mem[raddr];
    end
  end

`ifdef ASSERT_ON
  `rvv_forbid(|wen && $isunknown(waddr))
    else $error("ZVT_MT_FPGA_BANK: Write address is unknown with active wen!");
  `rvv_forbid(ren && $isunknown(raddr))
    else $error("ZVT_MT_FPGA_BANK: Read address is unknown with active ren!");
`endif

endmodule

/**
 * zvt_mt_fpga: 16-Bank Synchronous UltraRAM Architecture for FPGA Emulation
 *
 * Maps matrix tile storage into 16 independent URAM288 banks using an
 * invertible XOR-folding bijection. Eliminates 332k CLB LUTs and resolves
 * SLR0-SLR1 SLL routing congestion (Route 35-3424).
 */
module zvt_mt_fpga (
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

  input  logic clk;
  input  logic rst_n;

  // 16 read ports (4 blocks x 4 ports/block)
  input  logic [`NUM_BLK-1:0][`NUM_BLKPORT-1:0][$clog2(`NUM_MT)-1:0]      readMtIdx;
  input  logic [`NUM_BLK-1:0][`NUM_BLKPORT-1:0][$clog2(`NUM_SUBTILE)-1:0] readSubIdx;
  output logic [`NUM_BLK-1:0][`NUM_BLKPORT-1:0][`SUBTILE_SIZE*8-1:0]      readData;

`ifdef RVVI_ON
  // RVVI verification read ports
  input  logic [`NUM_BLK-1:0][3:0][$clog2(`NUM_MT)-1:0]                          rvviMtIdx;
  input  logic [`NUM_BLK-1:0][3:0][`NUM_SUBTILE/2-1:0][$clog2(`NUM_SUBTILE)-1:0] rvviSubIdx;
  output logic [`NUM_BLK-1:0][3:0][`NUM_SUBTILE/2-1:0][`SUBTILE_SIZE*8-1:0]      rvviReadData;
`endif

  // 16 write ports (4 blocks x 4 ports/block)
  input  logic [`NUM_BLK-1:0][`NUM_BLKPORT-1:0][`SUBTILE_SIZE-1:0]        writeEn;
  input  logic [`NUM_BLK-1:0][`NUM_BLKPORT-1:0][$clog2(`NUM_MT)-1:0]      writeMtIdx;
  input  logic [`NUM_BLK-1:0][`NUM_BLKPORT-1:0][$clog2(`NUM_SUBTILE)-1:0] writeSubIdx;
  input  logic [`NUM_BLK-1:0][`NUM_BLKPORT-1:0][`SUBTILE_SIZE*8-1:0]      writeData;

  localparam int MT_WIDTH        = $clog2(`NUM_MT);
  localparam int SUB_WIDTH       = $clog2(`NUM_SUBTILE);
  localparam int TOTAL_ENTRIES   = `NUM_MT * `NUM_SUBTILE;
  localparam int BANK_DEPTH      = TOTAL_ENTRIES / 16;
  localparam int BANK_ADDR_WIDTH = $clog2(BANK_DEPTH);

  // -------------------------------------------------------------------------
  // Elaboration Configuration Checks (IEEE 1800-2012 § 20.11)
  // -------------------------------------------------------------------------
  if (`NUM_MT < 4 || ((`NUM_MT & (`NUM_MT - 1)) != 0)) begin : chk_num_mt
    $fatal(1, "ZVT_MT CONFIGURATION ERROR: NUM_MT (%0d) must be a power of 2 >= 4 for 16-bank UltraRAM.", `NUM_MT);
  end
  if (`NUM_SUBTILE < 16 || ((`NUM_SUBTILE & (`NUM_SUBTILE - 1)) != 0)) begin : chk_num_subtile
    $fatal(1, "ZVT_MT CONFIGURATION ERROR: NUM_SUBTILE (%0d) must be a power of 2 >= 16 for 16-bank UltraRAM.", `NUM_SUBTILE);
  end

  // -------------------------------------------------------------------------
  // Parameterized XOR-Folding Bank Hashing Functions
  // -------------------------------------------------------------------------
  function automatic logic [3:0] get_bank_id(
    input logic [MT_WIDTH-1:0]  mt,
    input logic [SUB_WIDTH-1:0] sub
  );
    return {mt[1], sub[1], mt[0] ^ sub[3], sub[0] ^ sub[2]};
  endfunction

  function automatic logic [BANK_ADDR_WIDTH-1:0] get_bank_addr(
    input logic [MT_WIDTH-1:0]  mt,
    input logic [SUB_WIDTH-1:0] sub
  );
    logic [BANK_ADDR_WIDTH-1:0] addr;
    addr = {sub[3], sub[2]};
    if (SUB_WIDTH > 4) addr = addr | (BANK_ADDR_WIDTH'(sub >> 4) << 2);
    if (MT_WIDTH > 2)  addr = addr | (BANK_ADDR_WIDTH'(mt >> 2) << (SUB_WIDTH - 2));
    return addr;
  endfunction

  // The 16-bank mapping serves exactly 4 ports per block, one read per bank per
  // cycle. More PE parallelism (ZVT_PROCESS_DELAY below TE/4) needs more ports.
  if (`NUM_BLKPORT != 4) begin : gen_unsupported_port_count
    $error("zvt_mt_fpga supports 4 MT ports per block; build the FPGA image without ZVT_PROCESS_DELAY");
  end

  // -------------------------------------------------------------------------
  // Internal Read Enable Reconstruction
  // Ports j in {1, 2, 3} never address (mt=0, sub=0) when active; Port j == 0
  // is always paired with Port j == 1 across all PE and LSU/Move read modes.
  // -------------------------------------------------------------------------
  logic [`NUM_BLK-1:0][`NUM_BLKPORT-1:0] port_ren;

  always_comb begin
    for (int i = 0; i < `NUM_BLK; i++) begin
      for (int j = 0; j < `NUM_BLKPORT; j++) begin
        if (j == 0) begin
          port_ren[i][j] = (readMtIdx[i][1] != '0) || (readSubIdx[i][1] != '0);
        end else begin
          port_ren[i][j] = (readMtIdx[i][j] != '0) || (readSubIdx[i][j] != '0);
        end
      end
    end
  end

  // -------------------------------------------------------------------------
  // Bank Signals & Steering
  // -------------------------------------------------------------------------
  logic [15:0][`SUBTILE_SIZE-1:0]          bank_wen;
  logic [15:0][BANK_ADDR_WIDTH-1:0]        bank_waddr;
  logic [15:0][`SUBTILE_SIZE*8-1:0]        bank_wdata;
  logic [15:0]                             bank_ren;
  logic [15:0][BANK_ADDR_WIDTH-1:0]        bank_raddr;
  logic [15:0][`SUBTILE_SIZE*8-1:0]        bank_rdata;
  logic [`NUM_BLK-1:0][`NUM_BLKPORT-1:0][3:0] read_bank_sel;

  // Write Steering: Direct bank routing with zero port contention
  always_comb begin
    for (int k = 0; k < 16; k++) begin
      bank_wen[k]   = '0;
      bank_waddr[k] = '0;
      bank_wdata[k] = '0;
      for (int i = 0; i < `NUM_BLK; i++) begin
        for (int j = 0; j < `NUM_BLKPORT; j++) begin
          if (|writeEn[i][j] && (get_bank_id(writeMtIdx[i][j], writeSubIdx[i][j]) == 4'(k))) begin
            bank_wen[k]   = writeEn[i][j];
            bank_waddr[k] = get_bank_addr(writeMtIdx[i][j], writeSubIdx[i][j]);
            bank_wdata[k] = writeData[i][j];
          end
        end
      end
    end
  end

  // Read Address & Enable Steering
  always_comb begin
    for (int k = 0; k < 16; k++) begin
      bank_ren[k]   = 1'b0;
      bank_raddr[k] = '0;
      for (int i = 0; i < `NUM_BLK; i++) begin
        for (int j = 0; j < `NUM_BLKPORT; j++) begin
          if (port_ren[i][j] && (get_bank_id(readMtIdx[i][j], readSubIdx[i][j]) == 4'(k))) begin
            bank_ren[k]   = 1'b1;
            bank_raddr[k] = get_bank_addr(readMtIdx[i][j], readSubIdx[i][j]);
          end
        end
      end
    end
  end

  // Pipelined Bank Routing Select Register (Retimed for 1-cycle synchronous latency)
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      read_bank_sel <= '0;
    end else begin
      for (int i = 0; i < `NUM_BLK; i++) begin
        for (int j = 0; j < `NUM_BLKPORT; j++) begin
          if (port_ren[i][j]) begin
            read_bank_sel[i][j] <= get_bank_id(readMtIdx[i][j], readSubIdx[i][j]);
          end
        end
      end
    end
  end

  // Read Output Demultiplexing (Bank selection driven by 1-cycle pipelined tag)
  always_comb begin
    for (int i = 0; i < `NUM_BLK; i++) begin
      for (int j = 0; j < `NUM_BLKPORT; j++) begin
        readData[i][j] = bank_rdata[read_bank_sel[i][j]];
      end
    end
  end

  // -------------------------------------------------------------------------
  // 16 Hardened Synchronous UltraRAM Bank Instantiations
  // -------------------------------------------------------------------------
  genvar b;
  generate
    for (b = 0; b < 16; b++) begin : gen_mt_banks
      zvt_mt_fpga_bank #(
        .DEPTH      (BANK_DEPTH),
        .ADDR_WIDTH (BANK_ADDR_WIDTH)
      ) u_bank (
        .clk   (clk),
        .ren   (bank_ren[b]),
        .raddr (bank_raddr[b]),
        .rdata (bank_rdata[b]),
        .wen   (bank_wen[b]),
        .waddr (bank_waddr[b]),
        .wdata (bank_wdata[b])
      );
    end
  endgenerate

  // -------------------------------------------------------------------------
  // RVVI Simulation Support & Shadow Array
  // -------------------------------------------------------------------------
`ifdef RVVI_ON
  logic [`NUM_MT-1:0][`NUM_SUBTILE-1:0][`SUBTILE_SIZE*8-1:0] shadow_mt;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int m = 0; m < `NUM_MT; m++) begin
        for (int s = 0; s < `NUM_SUBTILE; s++) begin
          shadow_mt[m][s] <= '0;
        end
      end
    end else begin
      for (int i = 0; i < `NUM_BLK; i++) begin
        for (int j = 0; j < `NUM_BLKPORT; j++) begin
          if (|writeEn[i][j]) begin
            for (int h = 0; h < `SUBTILE_SIZE; h++) begin
              if (writeEn[i][j][h]) begin
                shadow_mt[writeMtIdx[i][j]][writeSubIdx[i][j]][h*8 +: 8] <= writeData[i][j][h*8 +: 8];
              end
            end
          end
        end
      end
    end
  end

  always_comb begin
    for (int i = 0; i < `NUM_BLK; i++) begin
      for (int j = 0; j < 4; j++) begin
        for (int k = 0; k < `NUM_SUBTILE/2; k++) begin
          rvviReadData[i][j][k] = shadow_mt[rvviMtIdx[i][j]][rvviSubIdx[i][j][k]];
        end
      end
    end
  end
`endif

  // -------------------------------------------------------------------------
  // SystemVerilog Formal Assertions (SVA)
  // -------------------------------------------------------------------------
`ifdef ASSERT_ON
  logic [15:0][`NUM_BLK*`NUM_BLKPORT-1:0] bank_write_req;
  logic [15:0][`NUM_BLK*`NUM_BLKPORT-1:0] bank_read_req;

  always_comb begin
    for (int a = 0; a < 16; a++) begin
      for (int i = 0; i < `NUM_BLK; i++) begin
        for (int j = 0; j < `NUM_BLKPORT; j++) begin
          bank_write_req[a][i*`NUM_BLKPORT + j] =
              |writeEn[i][j] && (get_bank_id(writeMtIdx[i][j], writeSubIdx[i][j]) == 4'(a));
          bank_read_req[a][i*`NUM_BLKPORT + j] =
              port_ren[i][j] && (get_bank_id(readMtIdx[i][j], readSubIdx[i][j]) == 4'(a));
        end
      end
    end
  end

  generate
    for (genvar a = 0; a < 16; a++) begin : assert_single_writer
      property p_exclusive_bank_write;
        @(posedge clk) disable iff (!rst_n)
        $onehot0(bank_write_req[a]);
      endproperty
      assert property (p_exclusive_bank_write)
        else $error("ZVT_MT FATAL ERROR: Bank %0d has concurrent write port collisions!", a);

      property p_exclusive_bank_read;
        @(posedge clk) disable iff (!rst_n)
        $onehot0(bank_read_req[a]);
      endproperty
      assert property (p_exclusive_bank_read)
        else $error("ZVT_MT FATAL ERROR: Bank %0d has concurrent read port collisions!", a);
    end

    for (genvar bi = 0; bi < `NUM_BLK; bi++) begin : assert_stall_hold
      for (genvar pj = 0; pj < `NUM_BLKPORT; pj++) begin : assert_stall_hold_p
        property p_hold_sel_on_stall;
          @(posedge clk) disable iff (!rst_n)
          (!port_ren[bi][pj]) |=> ($stable(read_bank_sel[bi][pj]));
        endproperty
        assert property (p_hold_sel_on_stall)
          else $error("ZVT_MT FATAL ERROR: read_bank_sel modified while port_ren deasserted!");
      end
    end
  endgenerate
`endif

endmodule

/**
 * zvt_ctrl_fpga: 2-Cycle Request/Response Handshake for Synchronous URAM Reads
 *
 * Delegates the uopRdy / valid handshake block in zvt_ctrl.sv so that
 * vtmv.v.t (isMv2Rvv) and matrix tile store (isVme2Lsu) wait 1 clock cycle
 * for synchronous UltraRAM readData to arrive before asserting valid/ready.
 */
module zvt_ctrl_fpga (
  input  logic                 clk,
  input  logic                 rst_n,
  input  logic                 isVme2Lsu,
  input  logic                 isLsu2Vme,
  input  logic                 isMv2Rvv,
  input  logic                 isMv2Vme,
  input  logic                 isZero,
  input  logic                 resVme2rvvRdy,
  input  logic                 cntCr,
  input  logic [`ZVT_LMUL-1:0] peCmdRdy,
  output logic                 vmelsuVld,
  output logic                 resVme2rvvVld,
  output logic [`ZVT_LMUL-1:0] uopRdy,
  output logic                 vmelsuresRdy
);

  logic mvlsuReadPending;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      mvlsuReadPending <= 1'b0;
    end else begin
      mvlsuReadPending <= (isMv2Rvv || isVme2Lsu) && !uopRdy[0];
    end
  end

  always_comb begin
    vmelsuVld     = 'b0;
    resVme2rvvVld = 'b0;
    uopRdy        = 'b0;
    vmelsuresRdy  = 'b0;

    case (1'b1)
      isVme2Lsu: begin
        vmelsuVld = mvlsuReadPending;
        uopRdy[0] = mvlsuReadPending;
      end
      isLsu2Vme: begin
        uopRdy[0]    = 1'b1;
        vmelsuresRdy = 1'b1;
      end
      isMv2Rvv: begin
        resVme2rvvVld = mvlsuReadPending;
        uopRdy[0]     = mvlsuReadPending && resVme2rvvRdy;
      end
      isMv2Vme: begin
        uopRdy[0] = 1'b1;
      end
      isZero: begin
        uopRdy[0] = cntCr;
      end
      default: begin
        uopRdy = peCmdRdy;
      end
    endcase
  end

endmodule

/**
 * zvt_pe_block_fpga: Cycle-Neutral T3 Read Launch & Stage 4 RAW Tag Multiplexer
 *
 * Advances the matrix tile read launch in zvt_pe_block from Cycle T4
 * (mulbulkCmd) to Cycle T3 (mulbulkRes) so synchronous 1-cycle UltraRAM
 * readData arrives at Cycle T4 aligned with mulbulkCmd.res. Also multiplexes
 * Stage 4 (mulbulkCmd) RAW hazard tags onto the existing 3-stage
 * mulbulkTagOut[3:1] bus so zvt_pe_array.sv requires zero modifications.
 */
module zvt_pe_block_fpga #(
  parameter int         MULBULKPIPENUM = 3,
  parameter int         ADDERPIPENUM   = 3,
  parameter logic [1:0] BLKID          = 2'b00
) (
  input  logic [`TE/2*`COMPRATIO-1:0][`TE/2-1:0][MULBULKPIPENUM:1] mulbulkOutVld,
  input  MULBULKTAG_t                                              mulbulkTagIn,
  input  MULBULKTAG_t [MULBULKPIPENUM:1]                           mulbulkTagPipe,
  input  logic                                                     mulbulkResVld,
  input  MULBULKRES_t                                              mulbulkRes,
  input  logic                                                     mulbulkResRdy,
  input  logic                                                     mulbulkCmdVld,
  input  MULBULKRES_t                                              mulbulkCmd,
  output logic        [ADDERPIPENUM:1]                             mulbulkTagOutVld,
  output MULBULKTAG_t [ADDERPIPENUM:1]                             mulbulkTagOut,
`ifdef TB_SUPPORT
  output logic [`PC_WIDTH-1:0]                                     readPc,
`endif
  output logic [`NUM_BLKPORT-1:0][$clog2(`NUM_MT)-1:0]             readMtIdx,
  output logic [`NUM_BLKPORT-1:0][$clog2(`NUM_SUBTILE)-1:0]        readSubIdx
);

  wire stage4_raw_vld = mulbulkCmdVld && (mulbulkCmd.tag.readMtId == '0);
  wire stage3_raw_vld = mulbulkOutVld[0][0][3] && (mulbulkTagPipe[3].readMtId == '0);
  wire use_stage4_tag = stage4_raw_vld &&
                        (!stage3_raw_vld || (mulbulkCmd.tag.readMtIdx == mulbulkTagIn.readMtIdx));

  assign mulbulkTagOutVld[1] = mulbulkOutVld[0][0][1];
  assign mulbulkTagOut[1]    = mulbulkTagPipe[1];

  assign mulbulkTagOutVld[2] = mulbulkOutVld[0][0][2];
  assign mulbulkTagOut[2]    = mulbulkTagPipe[2];

  assign mulbulkTagOutVld[3] = use_stage4_tag ? 1'b1           : mulbulkOutVld[0][0][3];
  assign mulbulkTagOut[3]    = use_stage4_tag ? mulbulkCmd.tag : mulbulkTagPipe[3];

`ifdef TB_SUPPORT
  assign readPc = mulbulkRes.tag.uop_pc;
`endif

  always_comb begin
    if (mulbulkResVld && mulbulkResRdy) begin
      for (int i = 0; i < `TE/4*`COMPRATIO; i++) begin : SubtileRow
        for (int j = 0; j < `TE/8; j++) begin : SubtileCol
          readMtIdx[(`TE/4*i)+(2*j)  ] = {mulbulkRes.tag.readMtIdx[3:2], BLKID[1], 1'b0};
          readMtIdx[(`TE/4*i)+(2*j+1)] = {mulbulkRes.tag.readMtIdx[3:2], BLKID[1], 1'b1};
          readSubIdx[(`TE/4*i)+(2*j)  ] = ($clog2(`NUM_SUBTILE))'((`TE/8)*BLKID[0]+(`TE/4*`COMPRATIO*mulbulkRes.tag.readMtId+i)*(`TE/4)+j);
          readSubIdx[(`TE/4*i)+(2*j+1)] = ($clog2(`NUM_SUBTILE))'((`TE/8)*BLKID[0]+(`TE/4*`COMPRATIO*mulbulkRes.tag.readMtId+i)*(`TE/4)+j);
        end
      end
    end else begin
      readMtIdx  = 'b0;
      readSubIdx = 'b0;
    end
  end

endmodule
`endif // FPGA_XILINX
