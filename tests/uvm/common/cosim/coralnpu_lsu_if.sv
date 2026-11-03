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

//----------------------------------------------------------------------------
// Interface: coralnpu_lsu_if
// Description: Passive monitor interface probing the internal LSU slot bus
//              requests and responses before the external AXI bridge.
//----------------------------------------------------------------------------
interface coralnpu_lsu_if (
    input logic clk,
    input logic resetn
);
  logic         uop_valid;
  logic         uop_ready;
  logic [ 31:0] uop_pc;
  logic         uop_store;
  logic         slot_active;
  logic [ 31:0] slot_pc;
  logic         store_complete;
  logic         slot_fault_valid;
  logic         bus_req_valid;
  logic         bus_req_ready;
  logic [  2:0] bus_req_txid;
  logic [ 27:0] bus_req_row_addr;
  logic [  3:0] bus_req_offset;
  logic [  4:0] bus_req_size;
  logic         bus_req_write;
  logic [127:0] bus_req_wdata;
  logic [ 15:0] bus_req_wmask;
  logic         bus_resp_valid;
  logic [  2:0] bus_resp_txid;
  logic [127:0] bus_resp_rdata;
  logic         bus_resp_fault;
  logic         lsu_fault_valid;
endinterface : coralnpu_lsu_if
