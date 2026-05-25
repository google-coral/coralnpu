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
import coralnpu.{Parameters,RegfileReadDataIO,RegfileWriteDataIO}

object RvvCore {
  def apply(p: Parameters): RvvCoreShim = {
    return Module(new RvvCoreShim(p))
  }
}

// Shim class for RVVCore — wraps the native Chisel RVV pipeline with
// CSR muxing logic (vstart, vxrm, vxsat).
class RvvCoreShim(p: Parameters) extends Module {
  val io = IO(new RvvCoreIO(p))

  // ---- Native Chisel RVV pipeline ----
  val rvvCoreNative = Module(new RvvCoreNative(p))

  // Connect all IO directly
  rvvCoreNative.io.inst        := io.inst
  rvvCoreNative.io.rs          := io.rs
  rvvCoreNative.io.rd          := io.rd
  rvvCoreNative.io.frs         := io.frs
  rvvCoreNative.io.async_rd    <> io.async_rd
  rvvCoreNative.io.async_frd   <> io.async_frd
  rvvCoreNative.io.rd_rob2rt_o := io.rd_rob2rt_o
  rvvCoreNative.io.trap        := io.trap
  rvvCoreNative.io.rvv2lsu     <> io.rvv2lsu
  rvvCoreNative.io.lsu2rvv     <> io.lsu2rvv
  rvvCoreNative.io.configState <> io.configState
  rvvCoreNative.io.rvv_idle     := io.rvv_idle
  rvvCoreNative.io.queue_capacity := io.queue_capacity

  // ---- CSR State with external write support ----
  val vstart = RegInit(0.U(log2Ceil(p.rvvVlen).W))
  val vxrm   = RegInit(0.U(2.W))
  val vxsat  = RegInit(false.B)

  rvvCoreNative.io.csr.frm := io.csr.frm

  // CSR update from scalar core writes or backend
  val vstartWdata = MuxCase(vstart, Seq(
    io.csr.vstart_write.valid -> io.csr.vstart_write.bits,
  ))
  vstart := vstartWdata

  val vxrmWdata = MuxCase(vxrm, Seq(
    io.csr.vxrm_write.valid -> io.csr.vxrm_write.bits,
  ))
  vxrm := vxrmWdata

  val vxsatWdata = MuxCase(vxsat, Seq(
    io.csr.vxsat_write.valid -> io.csr.vxsat_write.bits,
  ))
  vxsat := vxsatWdata

  // Provide current CSR values to native core
  rvvCoreNative.io.csr.vstart := vstart
  rvvCoreNative.io.csr.vxrm   := vxrm
  rvvCoreNative.io.csr.vxsat  := vxsat

  // Output CSR values
  io.csr.vstart := vstart
  io.csr.vxrm   := vxrm
  io.csr.vxsat  := vxsat
}
