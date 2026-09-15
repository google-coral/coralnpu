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

/** A testbench DUT that instantiates a single SecdedEncoder so it can be tested with cocotb.
  */
class SecdedEncoderTestbench(val w: Int, val moduleName: String) extends Module {
  override def desiredName = moduleName

  val io = IO(new Bundle {
    val data_i = Input(UInt(w.W))
    val ecc_o  = Output(UInt(7.W))
  })

  val encoder = Module(new SecdedEncoder(w))
  encoder.io.data_i := io.data_i
  io.ecc_o          := encoder.io.ecc_o
}

import common.ChiselEmitter

object EmitSecdedEncoderTestbench extends App {
  ChiselEmitter.emit(new SecdedEncoderTestbench(128, "SecdedEncoderTestbench128"), args)
}

object EmitSecdedEncoderTestbench32 extends App {
  ChiselEmitter.emit(new SecdedEncoderTestbench(32, "SecdedEncoderTestbench32"), args)
}

object EmitSecdedEncoderTestbench57 extends App {
  ChiselEmitter.emit(new SecdedEncoderTestbench(57, "SecdedEncoderTestbench57"), args)
}
