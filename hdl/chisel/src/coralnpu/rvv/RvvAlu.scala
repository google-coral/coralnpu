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
// Complete RvvAluOp — all RVV vector ALU operations
// Mirrors funct6 definitions in hdl/verilog/rvv/inc/rvv_backend.svh
// =============================================================================
object RvvAluOp extends ChiselEnum {
  // ---- OPIVV / OPIVX / OPIVI (funct3=000/100/011) ----
  val VADD  = Value; val VSUB  = Value; val VRSUB = Value
  val VMINU = Value; val VMIN  = Value; val VMAXU = Value; val VMAX  = Value
  val VAND  = Value; val VOR   = Value; val VXOR  = Value
  val VRGATHER = Value; val VRGATHEREI16 = Value
  val VSLIDEUP  = Value; val VSLIDEDOWN  = Value
  val VADC   = Value; val VMADC  = Value; val VSBC   = Value; val VMSBC  = Value
  val VMERGE = Value; val VMV    = Value
  val VMSEQ  = Value; val VMSNE  = Value; val VMSLTU = Value; val VMSLT  = Value
  val VMSLEU = Value; val VMSLE  = Value; val VMSGTU = Value; val VMSGT  = Value
  val VSADDU = Value; val VSADD  = Value; val VSSUBU = Value; val VSSUB  = Value
  val VSMUL  = Value
  val VMV1R  = Value; val VMV2R  = Value; val VMV4R  = Value; val VMV8R  = Value
  val VSLL   = Value; val VSRL   = Value; val VSRA   = Value
  val VSSRL  = Value; val VSSRA  = Value; val VNSRL  = Value; val VNSRA  = Value
  val VNCLIPU = Value; val VNCLIP = Value

  // ---- OPMVV / OPMVX (funct3=010/110) ----
  // Reduction
  val VREDSUM  = Value; val VREDAND  = Value; val VREDOR   = Value; val VREDXOR  = Value
  val VREDMINU = Value; val VREDMIN  = Value; val VREDMAXU = Value; val VREDMAX  = Value
  val VWREDSUMU = Value; val VWREDSUM = Value
  // Widening
  val VWADDU  = Value; val VWADD   = Value; val VWSUBU  = Value; val VWSUB   = Value
  val VWADDU_W = Value; val VWADD_W = Value; val VWSUBU_W = Value; val VWSUB_W = Value
  val VWMULU  = Value; val VWMULSU = Value; val VWMUL   = Value
  // MAC
  val VMACC   = Value; val VNMSAC  = Value; val VMADD   = Value; val VNMSUB  = Value
  val VWMACCU = Value; val VWMACC  = Value; val VWMACCUS = Value; val VWMACCSU = Value
  // Mask logical
  val VMANDN  = Value; val VMAND   = Value; val VMOR    = Value; val VMXOR   = Value
  val VMORN   = Value; val VMNAND  = Value; val VMNOR   = Value; val VMXNOR  = Value
  // Div/Rem
  val VDIVU   = Value; val VDIV    = Value; val VREMU   = Value; val VREM    = Value
  // Mulh
  val VMULHU  = Value; val VMULHSU = Value; val VMULH   = Value
  // Misc
  val VAADDU  = Value; val VAADD   = Value; val VASUBU  = Value; val VASUB   = Value
  val VSLIDE1UP = Value; val VSLIDE1DOWN = Value
  val VCOMPRESS = Value
  // Unary
  val VCPOP   = Value; val VFIRST  = Value; val VMV_X_S = Value; val VMV_S_X = Value
  val VMSBF   = Value; val VMSOF   = Value; val VMSIF   = Value; val VIOTA   = Value; val VID = Value
  val VZEXT_VF2 = Value; val VSEXT_VF2 = Value; val VZEXT_VF4 = Value; val VSEXT_VF4 = Value

  // ---- Float (ZVE32F) ----
  val VFADD   = Value; val VFSUB   = Value; val VFRSUB  = Value
  val VFMUL   = Value; val VFDIV   = Value; val VFRDIV  = Value
  val VFMACC  = Value; val VFNMACC = Value; val VFMSAC  = Value; val VFNMSAC = Value
  val VFMADD  = Value; val VFNMADD = Value; val VFMSUB  = Value; val VFNMSUB = Value
  val VFMIN   = Value; val VFMAX   = Value
  val VFSGNJ  = Value; val VFSGNJN = Value; val VFSGNJX = Value
  val VMFEQ   = Value; val VMFNE   = Value; val VMFLT   = Value; val VMFLE   = Value
  val VMFGT   = Value; val VMFGE   = Value
  val VFMERGE = Value; val VFMV    = Value
  val VFSQRT  = Value; val VFRSQRT7 = Value; val VFREC7 = Value; val VFCLASS = Value
  val VFCVT_XUFV = Value; val VFCVT_XFV = Value; val VFCVT_FXUV = Value; val VFCVT_FXV = Value
  val VFREDOSUM = Value; val VFREDUSUM = Value; val VFREDMAX = Value; val VFREDMIN = Value
}

class RvvS1DecodedInstruction extends Bundle {
  val op = RvvAluOp()
}
