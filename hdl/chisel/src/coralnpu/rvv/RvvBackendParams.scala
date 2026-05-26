// Copyright 2025 Google LLC
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

package coralnpu.rvv

import chisel3._
import chisel3.util._
import coralnpu.Parameters

// =============================================================================
// RVV Backend Parameters — mirrors hdl/verilog/rvv/inc/rvv_backend_define.svh
// =============================================================================
case class RvvBackendParams(
    // Data widths
    vlen:      Int = 128,   // VLEN
    xlen:      Int = 32,    // XLEN
    flen:      Int = 32,    // FLEN

    // Dispatch config (DISPATCH2 is default)
    numDeInst:  Int = 2,    // NUM_DE_INST
    numDeUop:   Int = 4,    // NUM_DE_UOP
    numDpUop:   Int = 2,    // NUM_DP_UOP
    numDpVrf:   Int = 4,    // NUM_DP_VRF

    // Queue/station depths
    cqDepth:      Int = 8,   // CQ_DEPTH
    uqDepth:      Int = 16,  // UQ_DEPTH
    aluRsDepth:   Int = 4,   // ALU_RS_DEPTH
    mulRsDepth:   Int = 4,   // MUL_RS_DEPTH
    divRsDepth:   Int = 4,   // DIV_RS_DEPTH
    pmtrdtRsDepth: Int = 8,  // PMTRDT_RS_DEPTH
    lsuRsDepth:   Int = 4,   // LSU_RS_DEPTH
    robDepth:     Int = 8,   // ROB_DEPTH

    // Execution unit counts
    numLsu:     Int = 2,     // NUM_LSU
    numAlu:     Int = 2,     // NUM_ALU
    numMul:     Int = 2,     // NUM_MUL
    numPmtrdt:  Int = 1,     // NUM_PMTRDT
    numDiv:     Int = 1,     // NUM_DIV

    // FP config
    hasFloat:   Boolean = false,

    // Retirement
    numRtUop:   Int = 4,     // NUM_RT_UOP

    // VRF
    numVrf:     Int = 32,    // NUM_VRF

    // Issue lane
    issueLane:  Int = 4,     // ISSUE_LANE
) {
  // Derived parameters
  def vlenb:      Int = vlen / 8
  def vlenh:      Int = vlen / 16
  def vlenw:      Int = vlen / 32
  def byteWidth:  Int = 8
  def vstartWidth: Int = log2Ceil(vlen)
  def vlWidth:     Int = log2Ceil(vlen) + 1
  def regfileIndexWidth: Int = 5
  def robDepthWidth: Int = log2Ceil(robDepth)

  def numAri: Int = if (hasFloat) numAlu + numPmtrdt + numMul + numDiv + 2  // +2 for FMA
                    else numAlu + numPmtrdt + numMul + numDiv
  def numPu:  Int = numAri + numLsu
  def numSmPort: Int = numPu  // NUM_SMPORT without ARBITER_ON
}
