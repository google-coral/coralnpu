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
  def lenBits                   = (new DmaLenFlags).xfer_len.getWidth
  def pWidth(p: TLULParameters) = lenBits - gMax(p) + 1
}

class FillDescriptor(val p: TLULParameters) extends Bundle {
  val srcAddr = UInt(p.a.W)
  // Beats the buffer takes per pass: N in memcopy, nAreas in strided.
  val stride        = UInt(DmaGeometry.sWidth(p).W)
  val lastPassBeats = UInt(DmaGeometry.sWidth(p).W) // Number of beats in the last pass
  val passes        = UInt(DmaGeometry.pWidth(p).W)
  val logElemSize   = UInt(DmaGeometry.eWidth(p).W)
}

class DrainDescriptor(val p: TLULParameters) extends Bundle {
  val dstAddr       = UInt(p.a.W)
  val stride        = UInt(DmaGeometry.sWidth(p).W)
  val lastPassBeats = UInt(DmaGeometry.sWidth(p).W)
  val passes        = UInt(DmaGeometry.pWidth(p).W)
  val rowPitch      = UInt(p.a.W)
  val passAdvance   = UInt(p.a.W)
  // Byte enables for the final beat; all-ones when areaSize is a whole multiple of p.w.
  val lastMask = UInt(p.w.W)
  val maskAll  = Bool()
}

class DrainStatus(val p: TLULParameters) extends Bundle {
  val issued        = UInt(DmaGeometry.sWidth(p).W)
  val received      = UInt(DmaGeometry.sWidth(p).W)
  val errSticky     = Bool()
  val passRemaining = UInt(DmaGeometry.pWidth(p).W)
  val passBase      = UInt(p.a.W)
  val addr          = UInt(p.a.W)
}

class FillStatus(val p: TLULParameters) extends Bundle {
  val cfgDone       = Bool()
  val issued        = UInt(DmaGeometry.sWidth(p).W)
  val received      = UInt(DmaGeometry.sWidth(p).W)
  val errSticky     = Bool()
  val passRemaining = UInt(DmaGeometry.pWidth(p).W)
  val srcBase       = UInt(p.a.W)
}

// The LEN_FLAGS CSR word, mirroring len_flags in coralnpu_dma_descriptor_t.
// First field is the MSB, so xfer_len lands at [23:0]. Widths here are the only
// definition; downstream code uses getWidth rather than repeating them.
// xfer_width = log2(element size in bytes), used as logElemSize; it is no longer
// required to equal gMax.
class DmaLenFlags extends Bundle {
  val reserved   = UInt(2.W)
  val poll_en    = Bool()
  val dst_fixed  = Bool()
  val src_fixed  = Bool()
  val xfer_width = UInt(3.W)
  val xfer_len   = UInt(24.W)
}

class XferCfg extends Bundle {
  val reserved = UInt(24.W)
  val n_areas  = UInt(8.W)
}
