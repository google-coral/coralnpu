// Copyright 2024 Google LLC
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

object RvvAluOp extends ChiselEnum {
  // TODO(davidgao): values here can be tweaked.
  val VADD  = Value
  val VSUB  = Value
  val VRSUB = Value

  val VMINU = Value
  val VMIN  = Value
  val VMAXU = Value
  val VMAX  = Value

  val VAND = Value
  val VOR  = Value
  val VXOR = Value

  val VRGATHER     = Value
  val VRGATHEREI16 = Value

  val VSLIDEUP   = Value
  val VSLIDEDOWN = Value

  val VADC  = Value
  val VMADC = Value
  val VSBC  = Value
  val VMSBC = Value

  val VMERGE = Value
  val VMV    = Value

  val VMSEQ  = Value
  val VMSNE  = Value
  val VMSLTU = Value
  val VMSLT  = Value
  val VMSLEU = Value
  val VMSLE  = Value
  val VMSGTU = Value
  val VMSGT  = Value

  val VSADDU = Value
  val VSADD  = Value
  val VSSUBU = Value
  val VSSUB  = Value

  val VSMUL = Value

  val VMV1R = Value
  val VMV2R = Value
  val VMV4R = Value
  val VMV8R = Value

  val VSLL  = Value
  val VSRL  = Value
  val VSRA  = Value
  val VSSRL = Value
  val VSSRA = Value
  val VNSRL = Value
  val VNSRA = Value

  val VNCLIPU = Value
  val VNCLIP  = Value

  val VFNCVTBF16  = Value
  val VFWCVTBF16  = Value
  val VFWMACCBF16 = Value

  val VFREDUSUM = Value
  val VFREDOSUM = Value
  val VFREDMAX  = Value
  val VFREDMIN  = Value
}

// The validity of an RVV instruction can only be fully checked when the
// current vector config is known. The `S1DecodedInstruction` here passes
// all context-free checks and needs to be cross-checked with vector config
// before execution.
class RvvS1DecodedInstruction extends Bundle {
  val op          = RvvAluOp()
  val is_float    = Bool()
  val is_widening = Bool()
}
