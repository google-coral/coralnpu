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

// =============================================================================
// RVV Vector Register File — Register Array
// Port of hdl/verilog/rvv/design/rvv_backend_vrf_reg.sv
//
// NUM_VRF registers, each VLEN bits wide, with per-byte write enables.
// =============================================================================
class RvvVrfReg(p: RvvBackendParams) extends Module {
  val io = IO(new Bundle {
    val wen   = Input(Vec(p.numVrf, UInt(p.vlenb.W)))   // byte enable per register
    val wdata = Input(Vec(p.numVrf, UInt(p.vlen.W)))     // write data per register
    val vreg  = Output(Vec(p.numVrf, UInt(p.vlen.W)))    // read data (all registers)
  })

  // 32 registers, each VLEN bits, organized as VLENB bytes with per-byte enable
  val regs = RegInit(VecInit(Seq.fill(p.numVrf)(0.U(p.vlen.W))))

  for (i <- 0 until p.numVrf) {
    for (j <- 0 until p.vlenb) {
      val byteHi = (j + 1) * p.byteWidth - 1
      val byteLo = j * p.byteWidth
      when (io.wen(i)(j)) {
        val writeByte = io.wdata(i)(byteHi, byteLo)
        // Assemble: upper bits | write byte | lower bits
        if (j == p.vlenb - 1 && j == 0) {
          // Only one byte in the register (VLEN=8)
          regs(i) := writeByte.pad(p.vlen)
        } else if (j == p.vlenb - 1) {
          // Last byte: no upper bits
          val lowerBits = regs(i)(j * p.byteWidth - 1, 0)
          regs(i) := Cat(writeByte, lowerBits)
        } else if (j == 0) {
          // First byte: no lower bits
          val upperBits = regs(i)(p.vlen - 1, p.byteWidth)
          regs(i) := Cat(upperBits, writeByte)
        } else {
          // Middle byte: both upper and lower bits
          val upperBits = regs(i)(p.vlen - 1, (j + 1) * p.byteWidth)
          val lowerBits = regs(i)(j * p.byteWidth - 1, 0)
          regs(i) := Cat(upperBits, writeByte, lowerBits)
        }
      }
    }
  }

  io.vreg := regs
}

// =============================================================================
// RVV Vector Register File — Full Wrapper
// Port of hdl/verilog/rvv/design/rvv_backend_vrf.sv
//
// Supports NUM_DP_VRF read ports (for dispatch) + 1 read port (for permutation),
// and NUM_RT_UOP write ports (from retirement).
// =============================================================================
class RvvVrf(p: RvvBackendParams) extends Module {
  val io = IO(new Bundle {
    // Dispatch read ports
    val dpRdIndex = Input(Vec(p.numDpVrf, UInt(p.regfileIndexWidth.W)))
    val dpRdData  = Output(Vec(p.numDpVrf, UInt(p.vlen.W)))
    val v0Data    = Output(UInt(p.vlen.W))  // V0 is always available

    // Permutation read port
    val pmtRdIndex = Input(UInt(p.regfileIndexWidth.W))
    val pmtRdData  = Output(UInt(p.vlen.W))

    // Retirement write ports
    val rtWrValid  = Input(Vec(p.numRtUop, Bool()))
    val rtWrIndex  = Input(Vec(p.numRtUop, UInt(p.regfileIndexWidth.W)))
    val rtWrData   = Input(Vec(p.numRtUop, UInt(p.vlen.W)))
    val rtWrStrobe = Input(Vec(p.numRtUop, UInt(p.vlenb.W)))  // byte strobe
  })

  // Generate byte-enable from strobe, and route writes to correct register
  val vrfWen   = Wire(Vec(p.numVrf, UInt(p.vlenb.W)))
  val vrfWdata = Wire(Vec(p.numVrf, UInt(p.vlen.W)))

  // Merge write ports: accumulate writes per register
  val wenPerPort  = Wire(Vec(p.numRtUop, Vec(p.numVrf, UInt(p.vlenb.W))))
  val dataPerPort = Wire(Vec(p.numRtUop, Vec(p.numVrf, UInt(p.vlen.W))))

  for (h <- 0 until p.numRtUop) {
    for (i <- 0 until p.numVrf) {
      wenPerPort(h)(i)  := 0.U
      dataPerPort(h)(i) := 0.U
    }
    when (io.rtWrValid(h)) {
      val addr = io.rtWrIndex(h)
      // Generate bit-enable from byte strobe
      val bitMasks = Wire(Vec(p.vlenb, UInt(p.vlen.W)))
      for (k <- 0 until p.vlenb) {
        bitMasks(k) := Mux(io.rtWrStrobe(h)(k),
          Fill(p.byteWidth, 1.U(1.W)) << (k * p.byteWidth).U,
          0.U)
      }
      val bitEnable = bitMasks.reduce(_ | _)

      for (i <- 0 until p.numVrf) {
        when (addr === i.U) {
          wenPerPort(h)(i)  := io.rtWrStrobe(h)
          dataPerPort(h)(i) := (0.U & ~bitEnable) | (io.rtWrData(h) & bitEnable)
        }
      }
    }
  }

  // Merge across ports
  for (i <- 0 until p.numVrf) {
    vrfWen(i)   := wenPerPort.map(_(i)).reduce(_ | _)
    vrfWdata(i) := dataPerPort.map(_(i)).reduce(_ | _)
  }

  // VRF register array
  val vrfReg = Module(new RvvVrfReg(p))
  vrfReg.io.wen   := vrfWen
  vrfReg.io.wdata := vrfWdata

  // Read ports for dispatch
  io.v0Data := vrfReg.io.vreg(0)
  for (j <- 0 until p.numDpVrf) {
    io.dpRdData(j) := vrfReg.io.vreg(io.dpRdIndex(j))
  }

  // Read port for permutation
  io.pmtRdData := vrfReg.io.vreg(io.pmtRdIndex)
}
