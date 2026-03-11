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
import coralnpu.{RegfileReadDataIO, RegfileWriteDataIO, Parameters}

class RvvConfigState(p: Parameters) extends Bundle {
  val vl = Output(UInt(log2Ceil(p.rvvVlen + 1).W))
  val vstart = Output(UInt(log2Ceil(p.rvvVlen).W))
  val ma = Output(Bool())
  val ta = Output(Bool())
  val xrm = Output(UInt(2.W))
  val sew = Output(UInt(3.W))
  // This may be reduced according to vl.
  val lmul = Output(UInt(3.W))
  // This is the original one set in vset(i)vl(i)
  val lmul_orig = Output(UInt(3.W))
  val vill = Output(Bool())

  /**
   * Construct the vtype CSR value.
   * See section 3.4 of the RISC-V Vector Specification v1.0.
   */
  def vtype: UInt = {
    Cat(vill, 0.U(23.W), ma, ta, sew, lmul_orig)
  }
}

class Lsu2Rvv(p: Parameters) extends Bundle {
  val addr = UInt(5.W)
  val data = UInt(p.rvvVlen.W)
  val last = Bool()
}

class Rvv2Lsu(p: Parameters) extends Bundle {
  val idx = Valid(new Bundle {
    val addr = UInt(5.W)
    val data = UInt(p.rvvVlen.W)
  })
  val vregfile = Valid(new Bundle {
    val addr = UInt(5.W)
    val data = UInt(p.rvvVlen.W)
  })
  val mask = Valid(UInt(p.rvvVlenb.W))
}

class RvvCoreIO(p: Parameters) extends Bundle {
    // Decode Cycle.
    val inst = Vec(p.instructionLanes,
        Flipped(Decoupled(new RvvCompressedInstruction)))

    // Execute cycle.
    val rs = Vec(p.instructionLanes * 2, Flipped(new RegfileReadDataIO))
    val rd = Vec(p.instructionLanes, Valid(new RegfileWriteDataIO))
    val frs = Vec(p.instructionLanes, Input(UInt(32.W)))

    val rvv2lsu = Vec(2, Decoupled(new Rvv2Lsu(p)))
    val lsu2rvv = Vec(2, Flipped(Decoupled(new Lsu2Rvv(p))))

    // Config state.
    val configState = Output(Valid(new RvvConfigState(p)))

    // Async scalar regfile writes.
    val async_rd = Decoupled(new RegfileWriteDataIO)
    val async_frd = Decoupled(new RegfileWriteDataIO)

    // Async trap.
    val trap = Output(Valid(new RvvCompressedInstruction))

    // Csr Interface.
    val csr = new RvvCsrIO(p)

    val rvv_idle = Output(Bool())
    val queue_capacity = Output(UInt(4.W))

    // Scalar trap flush handshake.
    val scalarTrapValid = Input(Bool())
    val scalarTrapReady = Output(Bool())

    // ROB to RT stage writes.
    val rd_rob2rt_o = Vec(4, new Rob2Rt(p))
}


class Rob2Rt(p: Parameters) extends Bundle {
  val w_valid = Bool()
  val w_index = UInt(5.W)
  val w_data = UInt(p.rvvVlen.W)
  val w_type = Bool()  // 0 for VRF, 1 for XRF
  val vd_type = UInt(p.rvvVlenb.W)
  val trap_flag = Bool()
  val vector_csr = new RvvConfigState(p)
  val vxsaturate = UInt(p.rvvVlenb.W)
  val uop_pc = UInt(32.W)
  val last_uop_valid = Bool()
}

class RvvCsrIO(p: Parameters) extends Bundle {
  val vstart = Output(UInt(log2Ceil(p.rvvVlen).W))
  val vxrm = Output(UInt(2.W))
  val vxsat = Output(Bool())
  val frm = Input(UInt(3.W))
  val vstart_write = Input(Valid(UInt(log2Ceil(p.rvvVlen).W)))
  val vxrm_write = Input(Valid(UInt(2.W)))
  val vxsat_write = Input(Valid(Bool()))
}
