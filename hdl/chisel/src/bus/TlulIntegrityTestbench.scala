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

package bus

import chisel3._
import chisel3.util._

/** A testbench DUT that instantiates all TlulIntegrity modules so they can be tested with cocotb in
  * a single simulation.
  */
class TlulIntegrityTestbench(p: TLULParameters) extends Module {
  val io = IO(new Bundle {
    // 1. RequestIntegrityGen instance
    val req_gen_a_i = Flipped(Decoupled(new OpenTitanTileLink.A_Channel(p)))
    val req_gen_a_o = Decoupled(new OpenTitanTileLink.A_Channel(p))

    // 2. RequestIntegrityCheck instance
    val req_check_a_i   = Flipped(Decoupled(new OpenTitanTileLink.A_Channel(p)))
    val req_check_fault = Output(Bool())

    // 4. ResponseIntegrityGen instance
    val rsp_gen_d_i = Flipped(Decoupled(new OpenTitanTileLink.D_Channel(p)))
    val rsp_gen_d_o = Decoupled(new OpenTitanTileLink.D_Channel(p))

    // 5. ResponseIntegrityCheck instance
    val rsp_check_d_i   = Flipped(Decoupled(new OpenTitanTileLink.D_Channel(p)))
    val rsp_check_fault = Output(Bool())

  })

  // 1. RequestIntegrityGen instance
  val req_gen = Module(new RequestIntegrityGen(p))
  req_gen.io.a_i <> io.req_gen_a_i.bits
  io.req_gen_a_o.bits  := req_gen.io.a_o
  io.req_gen_a_o.valid := io.req_gen_a_i.valid
  io.req_gen_a_i.ready := io.req_gen_a_o.ready

  // 2. RequestIntegrityCheck instance
  val req_check = Module(new RequestIntegrityCheck(p))
  req_check.io.a_i       := io.req_check_a_i.bits
  io.req_check_fault     := req_check.io.fault
  io.req_check_a_i.ready := true.B // Always ready to check

  // 4. ResponseIntegrityGen instance
  val rsp_gen = Module(new ResponseIntegrityGen(p))
  rsp_gen.io.d_i       := io.rsp_gen_d_i.bits
  io.rsp_gen_d_o.bits  := rsp_gen.io.d_o
  io.rsp_gen_d_o.valid := io.rsp_gen_d_i.valid
  io.rsp_gen_d_i.ready := io.rsp_gen_d_o.ready

  // 5. ResponseIntegrityCheck instance
  val rsp_check = Module(new ResponseIntegrityCheck(p))
  rsp_check.io.d_i       := io.rsp_check_d_i.bits
  io.rsp_check_fault     := rsp_check.io.fault
  io.rsp_check_d_i.ready := true.B

}

import common.ChiselEmitter

object EmitTlulIntegrityTestbench extends App {
  val tlul_p = new TLULParameters(dataBits = 128, addrBits = 32, idBits = 6)
  ChiselEmitter.emit(new TlulIntegrityTestbench(tlul_p), args)
}
