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

  // Connect IO with correct directions:
  // INPUTs to core (driven by external): rs, frs, lsu2rvv, csr.frm
  rvvCoreNative.io.rs          <> io.rs
  rvvCoreNative.io.frs         := io.frs
  rvvCoreNative.io.lsu2rvv     <> io.lsu2rvv

  // BIDIRECTIONAL (Decoupled with ready flowing opposite): inst
  rvvCoreNative.io.inst        <> io.inst

  // OUTPUTs from core (driven by native → external)
  io.rd          <> rvvCoreNative.io.rd
  io.rvv2lsu     <> rvvCoreNative.io.rvv2lsu
  io.async_rd    <> rvvCoreNative.io.async_rd
  io.async_frd   <> rvvCoreNative.io.async_frd
  io.rd_rob2rt_o <> rvvCoreNative.io.rd_rob2rt_o
  io.trap        <> rvvCoreNative.io.trap
  io.configState <> rvvCoreNative.io.configState
  io.rvv_idle     := rvvCoreNative.io.rvv_idle
  io.queue_capacity := rvvCoreNative.io.queue_capacity

  // ---- CSR State with external write support ----
  // Shim manages CSR state. Native core uses its own internal defaults.
  val vstart = RegInit(0.U(log2Ceil(p.rvvVlen).W))
  val vxrm   = RegInit(0.U(2.W))
  val vxsat  = RegInit(false.B)

  // CSR writes from scalar core
  when (io.csr.vstart_write.valid) { vstart := io.csr.vstart_write.bits }
  when (io.csr.vxrm_write.valid)   { vxrm   := io.csr.vxrm_write.bits }
  when (io.csr.vxsat_write.valid)  { vxsat  := io.csr.vxsat_write.bits }

  // Output CSR values to external
  io.csr.vstart := vstart
  io.csr.vxrm   := vxrm
  io.csr.vxsat  := vxsat

  // Native core reads frm from external
  rvvCoreNative.io.csr.frm := io.csr.frm

  // CSR write ports on native core — not used (shim manages CSR), drive defaults
  rvvCoreNative.io.csr.vstart_write.valid := false.B
  rvvCoreNative.io.csr.vstart_write.bits  := 0.U
  rvvCoreNative.io.csr.vxrm_write.valid   := false.B
  rvvCoreNative.io.csr.vxrm_write.bits    := 0.U
  rvvCoreNative.io.csr.vxsat_write.valid  := false.B
  rvvCoreNative.io.csr.vxsat_write.bits   := false.B

  // Output CSR values
  io.csr.vstart := vstart
  io.csr.vxrm   := vxrm
  io.csr.vxsat  := vxsat
}
