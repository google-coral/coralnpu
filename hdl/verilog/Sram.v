// Copyright 2024 Google LLC
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

module Sram #(
    parameter NUM_ENTRIES = 128,
    parameter GLOBAL_BASE_ADDR = 0
) (
    input                            clock,
    input                            enable,
    input                            write,
    input  [$clog2(NUM_ENTRIES)-1:0] addr,
    input  [                  127:0] wdata,
    input  [                   15:0] wmask,
    output [                  127:0] rdata,
    output                           rvalid
);

  ///////////////////////////
  ///// SRAM Selection //////
  ///////////////////////////

`ifdef USE_TSMC12FFC
  ///////////////////////////
  ///// TSMC12FFC SRAM //////
  ///////////////////////////
  wire [127:0] nwmask;
  genvar i_wmask;
  generate
    for (i_wmask = 0; i_wmask < 16; i_wmask = i_wmask + 1) begin : gen_wmask
      assign nwmask[8*i_wmask+:8] = {8{~wmask[i_wmask]}};
    end
  endgenerate

  // Note on RTSEL/WTSEL: Different macro sizes require different timing control settings.
  // The simulation models check these pins and may error out if they don't match recommended values.
  // For synthesized netlist simulation (GLS), the ifdef's area already evaluated and cannot be changed
  // Use +define+TSMC_NO_TESTPINS_DEFAULT_VALUE_CHECK in VCS, to skip checks in simulation
  // RTSEL and WTSEL for synthesis may be required for tuning
  if (NUM_ENTRIES == 2048) begin
    TS1N12FFCLLMBLVTD2048X128M4SWBSHO u_sram (
        .BIST(1'b0),
        .SLP(1'b0),
        .DSLP(1'b0),
        .SD(1'b0),
        .CLK(clock),
        .CEB(~enable),
        .WEB(~write),
        .A(addr),
        .D(wdata),
        .BWEB(nwmask),
        .CEBM(1'b0),
        .WEBM(1'b0),
        .AM(11'b0),
        .DM(128'b0),
        .BWEBM({128{1'b1}}),
        .Q(rdata),
        .PUDELAY(),
`ifndef SIMULATION
        .RTSEL(2'b0),
        .WTSEL(2'b0)
`else
        .RTSEL(2'b1),
        .WTSEL(2'b1)
`endif
    );
  end else if (NUM_ENTRIES == 512) begin
    TS1N12FFCLLSBLVTD512X128M4SWBSHO u_sram (
        .BIST(1'b0),
        .SLP(1'b0),
        .DSLP(1'b0),
        .SD(1'b0),
        .CLK(clock),
        .CEB(~enable),
        .WEB(~write),
        .A(addr),
        .D(wdata),
        .BWEB(nwmask),
        .CEBM(1'b0),
        .WEBM(1'b0),
        .AM(9'b0),
        .DM(128'b0),
        .BWEBM({128{1'b1}}),
        .Q(rdata),
        .PUDELAY(),
`ifndef SIMULATION
        .RTSEL(2'b0),
        .WTSEL(2'b0)
`else
        .RTSEL(2'b1),
        .WTSEL(2'b0)
`endif
    );
  end else begin
    initial begin
      $error("Unsupported SRAM size for TSMC12FFC: %d", NUM_ENTRIES);
    end
  end

  reg rvalid_reg;
  always @(posedge clock) rvalid_reg <= enable;
  assign rvalid = rvalid_reg;

`elsif USE_GF22
  ///////////////////////////
  //////// GF22 SRAM ////////
  ///////////////////////////
  wire [127:0] nwmask;
  genvar i_wmask;
  generate
    for (i_wmask = 0; i_wmask < 16; i_wmask = i_wmask + 1) begin : gen_wmask
      assign nwmask[8*i_wmask+:8] = {8{wmask[i_wmask]}};
    end
  endgenerate

  if (NUM_ENTRIES == 2048) begin
    sasdulssd8LOW1p2048x128m4b2w0c0p0d0l0rm3sdrw01 u_sram (
        .Q(rdata),
        .ADR(addr),
        .D(wdata),
        .WEM(nwmask),
        .WE(write),
        .ME(enable),
        .CLK(clock),
        .TEST1(1'b0),
        .TEST_RNM(1'b0),
        .RME(1'b0),
        .RM(4'b0),
        .WA(2'b0),
        .WPULSE(3'b0),
        .LS(1'b0),
        .BC0(1'b0),
        .BC1(1'b0),
        .BC2(1'b0)
    );
  end else if (NUM_ENTRIES == 512) begin
    sasdulssd8LOW1p512x128m4b1w0c0p0d0l0rm3sdrw01 u_sram (
        .Q(rdata),
        .ADR(addr),
        .D(wdata),
        .WEM(nwmask),
        .WE(write),
        .ME(enable),
        .CLK(clock),
        .TEST1(1'b0),
        .TEST_RNM(1'b0),
        .RME(1'b0),
        .RM(4'b0),
        .WA(2'b0),
        .WPULSE(3'b0),
        .LS(1'b0),
        .BC0(1'b0),
        .BC1(1'b0),
        .BC2(1'b0)
    );
  end else begin
    initial begin
      $error("Unsupported SRAM size for GF22: %d", NUM_ENTRIES);
    end
  end

  reg rvalid_reg;
  always @(posedge clock) rvalid_reg <= enable;
  assign rvalid = rvalid_reg;

`else
  ///////////////////////////
  ////// Generic SRAM ///////
  ///////////////////////////
  localparam SRAM_WIDTH_BYTES = 16;
  localparam ADDR_WIDTH = $clog2(NUM_ENTRIES);

  reg rvalid_reg;
  always @(posedge clock) rvalid_reg <= enable;
  assign rvalid = rvalid_reg;

`ifdef SYNTHESIS
  bit [127:0] mem[0:NUM_ENTRIES-1];
  reg [ADDR_WIDTH-1:0] raddr;

  assign rdata = mem[raddr];

  always @(posedge clock) begin
    begin : mem_write
      integer i;
      for (i = 0; i < 16; i = i + 1) begin
        if (enable & write & wmask[i]) begin
          mem[addr][i*8+:8] <= wdata[8*i+:8];
        end
      end
    end

    if (enable & ~write) begin
      raddr <= addr;
    end
  end
`else
  // Simulation Path: DPI-based storage
`ifdef VERILATOR
  `define DPI_MEMORY
`elsif VCS
  `define DPI_MEMORY
`endif
`ifdef DPI_MEMORY
  import "DPI-C" function chandle sram_init(
    input longint global_addr,
    input longint size_bytes,
    input int width_bytes
  );
  import "DPI-C" function void sram_read(
    input chandle handle,
    input int addr,
    output bit [127:0] data
  );
  import "DPI-C" function void sram_write(
    input chandle handle,
    input int addr,
    input bit [127:0] data,
    input int wmask
  );
  import "DPI-C" function void sram_cleanup(input chandle handle);

  chandle backdoor_handle;
  reg [127:0] rdata_reg;
  assign rdata = rdata_reg;

  initial begin
    backdoor_handle = sram_init(GLOBAL_BASE_ADDR, NUM_ENTRIES * SRAM_WIDTH_BYTES, SRAM_WIDTH_BYTES);
  end

  final begin
    if (backdoor_handle != null) begin
      sram_cleanup(backdoor_handle);
    end
  end

  always @(posedge clock) begin
    if (enable & write) begin
      sram_write(backdoor_handle, 32'(addr), wdata, {16'b0, wmask});
    end
    if (enable & ~write) begin
      sram_read(backdoor_handle, 32'(addr), rdata_reg);
    end
  end
`else
  // Fallback for non-Verilator simulators
  bit [127:0] mem[0:NUM_ENTRIES-1];
  reg [ADDR_WIDTH-1:0] raddr;
  assign rdata = mem[raddr];
  always @(posedge clock) begin
    if (enable & write) begin
      integer i;
      for (i = 0; i < 16; i = i + 1) begin
        if (wmask[i]) mem[addr][i*8+:8] <= wdata[8*i+:8];
      end
    end
    if (enable & ~write) raddr <= addr;
  end
`endif
`endif

`endif  // SRAM selection

endmodule
