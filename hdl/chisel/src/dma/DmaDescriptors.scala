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

package dma

import bus._

import chisel3._
import chisel3.util._

// One definition so the derived port widths cannot drift apart across modules.
object DmaGeometry {
  def gMax(p: TLULParameters)   = log2Ceil(p.w)
  def eMax(p: TLULParameters)   = gMax(p) // elemSize == N gives G == 1: pass-through (memcopy)
  def eWidth(p: TLULParameters) = log2Ceil(eMax(p) + 1)
  def sWidth(p: TLULParameters) = log2Ceil(p.w + 1)
}

class FillDescriptor(val p: TLULParameters) extends Bundle {
  val srcAddr = UInt(p.a.W)
  // Not read by the fill engine; forwarded verbatim in the drain handoff.
  val dstAddr     = UInt(p.a.W)
  val stride      = UInt(DmaGeometry.sWidth(p).W)
  val logElemSize = UInt(DmaGeometry.eWidth(p).W)
  val lastMask    = UInt(p.w.W)
}

class DrainDescriptor(val p: TLULParameters) extends Bundle {
  val dstAddr = UInt(p.a.W)
  val stride  = UInt(DmaGeometry.sWidth(p).W)
  // Byte enables for the final beat; all-ones when the length is a whole multiple of p.w.
  val lastMask = UInt(p.w.W)
}

class DrainStatus(val p: TLULParameters) extends Bundle {
  val issued    = UInt(DmaGeometry.sWidth(p).W)
  val received  = UInt(DmaGeometry.sWidth(p).W)
  val errSticky = Bool()
}

class FillStatus(val p: TLULParameters) extends Bundle {
  val cfgDone   = Bool()
  val issued    = UInt(DmaGeometry.sWidth(p).W)
  val received  = UInt(DmaGeometry.sWidth(p).W)
  val errSticky = Bool()
}

// The LEN_FLAGS CSR word, mirroring len_flags in coralnpu_dma_descriptor_t.
// First field is the MSB, so xfer_len lands at [23:0]. Widths here are the only
// definition; downstream code uses getWidth rather than repeating them.
class DmaLenFlags extends Bundle {
  val reserved   = UInt(2.W)
  val poll_en    = Bool()
  val dst_fixed  = Bool()
  val src_fixed  = Bool()
  val xfer_width = UInt(3.W)
  val xfer_len   = UInt(24.W)
}
