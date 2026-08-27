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
import chisel3.simulator.scalatest.ChiselSim
import chisel3.util._
import org.scalatest.ParallelTestExecution
import org.scalatest.freespec.AnyFreeSpec

import common.ProcessTestResults
import coralnpu.Parameters

class RvvS1DecodeInstructionSpec extends AnyFreeSpec with ChiselSim with ParallelTestExecution {
  val p = {
    val params = new Parameters
    params.enableFloat = true
    params.enableVectorBf16 = true
    params
  }
  class Tester extends Module {
    val io = IO(new Bundle {
      val inst      = Input(UInt(32.W))
      val out_valid = Output(Bool())
      val out_op    = Output(UInt(RvvAluOp.getWidth.W))
    })

    val out = Wire(Valid(new RvvS1DecodedInstruction()))
    out          := RvvS1DecodeInstruction(io.inst)
    io.out_valid := out.valid
    io.out_op    := out.bits.op.asUInt
  }

  class TesterCompressed(p: Parameters) extends Module {
    val io = IO(new Bundle {
      val inst      = Input(UInt(32.W))
      val out_valid = Output(Bool())
      val out_op    = Output(UInt(RvvAluOp.getWidth.W))
    })

    val out = Wire(Valid(new RvvS1DecodedInstruction()))
    out := RvvS1DecodeCompressedInstruction(
      RvvCompressedInstruction.from_uncompressed(p, io.inst, 0.U)
    )
    io.out_valid := out.valid
    io.out_op    := out.bits.op.asUInt
  }

  private def test_decode(
    dut: Tester,
    // Long because Scala has no unsigned int.
    cases: Seq[(Long, RvvAluOp.Type)]
  ) = {
    val good = cases.map { case (inst, op) =>
      dut.io.inst.poke(inst)
      ((dut.io.out_valid.peek().litValue == 1) && (dut.io.out_op.peek().litValue == op.litValue))
    }
    if (!ProcessTestResults(good, printfn = info(_))) fail()
  }

  private def test_decode_compressed(
    dut: TesterCompressed,
    // Long because Scala has no unsigned int.
    cases: Seq[(Long, RvvAluOp.Type)]
  ) = {
    val good = cases.map { case (inst, op) =>
      dut.io.inst.poke(inst)
      ((dut.io.out_valid.peek().litValue == 1) && (dut.io.out_op.peek().litValue == op.litValue))
    }
    if (!ProcessTestResults(good, printfn = info(_))) fail()
  }

  val test_cases_no_mask = Seq(
    // Compiled on godbolt rv32gc clang 18.1.0 --target=riscv32-none-eabi -march=rv32im_zve32x -O3
    (0x02000057L, RvvAluOp.VADD),  // vadd.vv v0, v0, v0
    (0x02004057L, RvvAluOp.VADD),  // vadd.vx v0, v0, x0
    (0x02003057L, RvvAluOp.VADD),  // vadd.vi v0, v0, 0
    (0x0a000057L, RvvAluOp.VSUB),  // vsub.vv v0, v0, v0
    (0x0a004057L, RvvAluOp.VSUB),  // vsub.vx v0, v0, x0
    (0x0e004057L, RvvAluOp.VRSUB), // vrsub.vx v0, v0, x0
    (0x0e003057L, RvvAluOp.VRSUB), // vrsub.vi v0, v0, 0

    (0x12000057L, RvvAluOp.VMINU), // vminu.vv v0, v0, v0
    (0x12004057L, RvvAluOp.VMINU), // vminu.vx v0, v0, x0
    (0x16000057L, RvvAluOp.VMIN),  // vmin.vv v0, v0, v0
    (0x16004057L, RvvAluOp.VMIN),  // vmin.vx v0, v0, x0
    (0x1a000057L, RvvAluOp.VMAXU), // vmaxu.vv v0, v0, v0
    (0x1a004057L, RvvAluOp.VMAXU), // vmaxu.vx v0, v0, x0
    (0x1e000057L, RvvAluOp.VMAX),  // vmax.vv v0, v0, v0
    (0x1e004057L, RvvAluOp.VMAX),  // vmax.vx v0, v0, x0

    (0x26000057L, RvvAluOp.VAND), // vand.vv v0, v0, v0
    (0x26004057L, RvvAluOp.VAND), // vand.vx v0, v0, x0
    (0x26003057L, RvvAluOp.VAND), // vand.vi v0, v0, 0
    (0x2a000057L, RvvAluOp.VOR),  // vor.vv v0, v0, v0
    (0x2a004057L, RvvAluOp.VOR),  // vor.vx v0, v0, x0
    (0x2a003057L, RvvAluOp.VOR),  // vor.vi v0, v0, 0
    (0x2e000057L, RvvAluOp.VXOR), // vxor.vv v0, v0, v0
    (0x2e004057L, RvvAluOp.VXOR), // vxor.vx v0, v0, x0
    (0x2e003057L, RvvAluOp.VXOR), // vxor.vi v0, v0, 0

    (0x32108057L, RvvAluOp.VRGATHER),     // vrgather.vv v0, v1, v1
    (0x32104057L, RvvAluOp.VRGATHER),     // vrgather.vx v0, v1, x0
    (0x32103057L, RvvAluOp.VRGATHER),     // vrgather.vi v0, v1, 0
    (0x3a108057L, RvvAluOp.VRGATHEREI16), // vrgatherei16.vv v0, v1, v1

    (0x3a0040d7L, RvvAluOp.VSLIDEUP),   // vslideup.vx v1, v0, x0
    (0x3a0030d7L, RvvAluOp.VSLIDEUP),   // vslideup.vi v1, v0, 0
    (0x3e0040d7L, RvvAluOp.VSLIDEDOWN), // vslidedown.vx v1, v0, x0
    (0x3e0030d7L, RvvAluOp.VSLIDEDOWN), // vslidedown.vi v1, v0, 0

    // VADC requires mask.
    (0x46000057L, RvvAluOp.VMADC), // vmadc.vv v0, v0, v0
    (0x46004057L, RvvAluOp.VMADC), // vmadc.vx v0, v0, x0
    (0x46003057L, RvvAluOp.VMADC), // vmadc.vi v0, v0, 0
    // VSBC requires mask.
    (0x4e000057L, RvvAluOp.VMSBC), // vmsbc.vv v0, v0, v0
    (0x4e004057L, RvvAluOp.VMSBC), // vmsbc.vx v0, v0, x0

    // VMERGE requires mask
    (0x5e000057L, RvvAluOp.VMV), // vmv.v.v v0, v0
    (0x5e004057L, RvvAluOp.VMV), // vmv.v.x v0, x0
    (0x5e003057L, RvvAluOp.VMV), // vmv.v.i v0, 0

    // VMSEQ requires mask.
    // VMSNE requires mask.
    // VMSLTU requires mask.
    // VMSLT requires mask.
    // VMSLEU requires mask.
    // VMSLE requires mask.
    // VMSGTU requires mask.
    // VMSGT requires mask.

    (0x82000057L, RvvAluOp.VSADDU), // vsaddu.vv v0, v0, v0
    (0x82004057L, RvvAluOp.VSADDU), // vsaddu.vx v0, v0, x0
    (0x82003057L, RvvAluOp.VSADDU), // vsaddu.vi v0, v0, 0
    (0x86000057L, RvvAluOp.VSADD),  // vsadd.vv v0, v0, v0
    (0x86004057L, RvvAluOp.VSADD),  // vsadd.vx v0, v0, x0
    (0x86003057L, RvvAluOp.VSADD),  // vsadd.vi v0, v0, 0
    (0x8a000057L, RvvAluOp.VSSUBU), // vssubu.vv v0, v0, v0
    (0x8a004057L, RvvAluOp.VSSUBU), // vssubu.vx v0, v0, x0
    (0x8e000057L, RvvAluOp.VSSUB),  // vssub.vv v0, v0, v0
    (0x8e004057L, RvvAluOp.VSSUB),  // vssub.vx v0, v0, x0

    (0x9e000057L, RvvAluOp.VSMUL), // vsmul.vv v0, v0, v0
    (0x9e004057L, RvvAluOp.VSMUL), // vsmul.vx v0, v0, x0

    (0x9e003057L, RvvAluOp.VMV1R), // vmv1r.v v0, v0
    (0x9e00b057L, RvvAluOp.VMV2R), // vmv2r.v v0, v0
    (0x9e01b057L, RvvAluOp.VMV4R), // vmv4r.v v0, v0
    (0x9e03b057L, RvvAluOp.VMV8R), // vmv8r.v v0, v0

    (0x96000057L, RvvAluOp.VSLL),  // vsll.vv v0, v0, v0
    (0x96004057L, RvvAluOp.VSLL),  // vsll.vx v0, v0, x0
    (0x96003057L, RvvAluOp.VSLL),  // vsll.vi v0, v0, 0
    (0xa2000057L, RvvAluOp.VSRL),  // vsrl.vv v0, v0, v0
    (0xa2004057L, RvvAluOp.VSRL),  // vsrl.vx v0, v0, x0
    (0xa2003057L, RvvAluOp.VSRL),  // vsrl.vi v0, v0, 0
    (0xa6000057L, RvvAluOp.VSRA),  // vsra.vv v0, v0, v0
    (0xa6004057L, RvvAluOp.VSRA),  // vsra.vx v0, v0, x0
    (0xa6003057L, RvvAluOp.VSRA),  // vsra.vi v0, v0, 0
    (0xaa000057L, RvvAluOp.VSSRL), // vssrl.vv v0, v0, v0
    (0xaa004057L, RvvAluOp.VSSRL), // vssrl.vx v0, v0, x0
    (0xaa003057L, RvvAluOp.VSSRL), // vssrl.vi v0, v0, 0
    (0xae000057L, RvvAluOp.VSSRA), // vssra.vv v0, v0, v0
    (0xae004057L, RvvAluOp.VSSRA), // vssra.vx v0, v0, x0
    (0xae003057L, RvvAluOp.VSSRA), // vssra.vi v0, v0, 0
    (0xb2000057L, RvvAluOp.VNSRL), // vnsrl.wv v0, v0, v0
    (0xb2004057L, RvvAluOp.VNSRL), // vnsrl.wx v0, v0, x0
    (0xb2003057L, RvvAluOp.VNSRL), // vnsrl.wi v0, v0, 0
    (0xb6000057L, RvvAluOp.VNSRA), // vnsra.wv v0, v0, v0
    (0xb6004057L, RvvAluOp.VNSRA), // vnsra.wx v0, v0, x0
    (0xb6003057L, RvvAluOp.VNSRA), // vnsra.wi v0, v0, 0

    (0xba000057L, RvvAluOp.VNCLIPU), // vnclipu.wv v0, v0, v0
    (0xba004057L, RvvAluOp.VNCLIPU), // vnclipu.wx v0, v0, x0
    (0xba003057L, RvvAluOp.VNCLIPU), // vnclipu.wi v0, v0, 0
    (0xbe000057L, RvvAluOp.VNCLIP),  // vnclip.wv v0, v0, v0
    (0xbe004057L, RvvAluOp.VNCLIP),  // vnclip.wx v0, v0, x0
    (0xbe003057L, RvvAluOp.VNCLIP)   // vnclip.wi v0, v0, 0
  )

  val test_cases_with_mask = Seq(
    // Compiled on godbolt rv32gc clang 18.1.0 --target=riscv32-none-eabi -march=rv32im_zve32x -O3
    (0x001080d7L, RvvAluOp.VADD),  // vadd.vv v1, v1, v1, v0.t
    (0x001040d7L, RvvAluOp.VADD),  // vadd.vx v1, v1, x0, v0.t
    (0x001030d7L, RvvAluOp.VADD),  // vadd.vi v1, v1, 0, v0.t
    (0x081080d7L, RvvAluOp.VSUB),  // vsub.vv v1, v1, v1, v0.t
    (0x081040d7L, RvvAluOp.VSUB),  // vsub.vx v1, v1, x0, v0.t
    (0x0c1040d7L, RvvAluOp.VRSUB), // vrsub.vx v1, v1, x0, v0.t
    (0x0c1030d7L, RvvAluOp.VRSUB), // vrsub.vi v1, v1, 0, v0.t

    (0x101080d7L, RvvAluOp.VMINU), // vminu.vv v1, v1, v1, v0.t
    (0x101040d7L, RvvAluOp.VMINU), // vminu.vx v1, v1, x0, v0.t
    (0x141080d7L, RvvAluOp.VMIN),  // vmin.vv v1, v1, v1
    (0x141040d7L, RvvAluOp.VMIN),  // vmin.vx v1, v1, x0
    (0x181080d7L, RvvAluOp.VMAXU), // vmaxu.vv v1, v1, v1, v0.t
    (0x181040d7L, RvvAluOp.VMAXU), // vmaxu.vx v1, v1, x0, v0.t
    (0x1c1080d7L, RvvAluOp.VMAX),  // vmax.vv v1, v1, v1, v0.t
    (0x1c1040d7L, RvvAluOp.VMAX),  // vmax.vx v1, v1, x0, v0.t

    (0x241000d7L, RvvAluOp.VAND), // vand.vv v1, v1, v1, v0.t
    (0x241040d7L, RvvAluOp.VAND), // vand.vx v1, v1, x0, v0.t
    (0x241030d7L, RvvAluOp.VAND), // vand.vi v1, v1, 0, v0.t
    (0x281000d7L, RvvAluOp.VOR),  // vor.vv v1, v1, v1, v0.t
    (0x281040d7L, RvvAluOp.VOR),  // vor.vx v1, v1, x0, v0.t
    (0x281030d7L, RvvAluOp.VOR),  // vor.vi v1, v1, 0, v0.t
    (0x2c1000d7L, RvvAluOp.VXOR), // vxor.vv v1, v1, v1, v0.t
    (0x2c1040d7L, RvvAluOp.VXOR), // vxor.vx v1, v1, x0, v0.t
    (0x2c1030d7L, RvvAluOp.VXOR), // vxor.vi v1, v1, 0, v0.t

    (0x300000d7L, RvvAluOp.VRGATHER),     // vrgather.vv v1, v0, v0, v0.t
    (0x300040d7L, RvvAluOp.VRGATHER),     // vrgather.vx v1, v0, x0, v0.t
    (0x300030d7L, RvvAluOp.VRGATHER),     // vrgather.vi v1, v0, 0, v0.t
    (0x380000d7L, RvvAluOp.VRGATHEREI16), // vrgatherei16.vv v1, v0, v0, v0.t

    (0x380040d7L, RvvAluOp.VSLIDEUP),   // vslideup.vx v1, v0, x0, v0.t
    (0x380030d7L, RvvAluOp.VSLIDEUP),   // vslideup.vi v1, v0, 0, v0.t
    (0x3c0040d7L, RvvAluOp.VSLIDEDOWN), // vslidedown.vx v1, v0, x0, v0.t
    (0x3c0030d7L, RvvAluOp.VSLIDEDOWN), // vslidedown.vi v1, v0, 0, v0.t

    (0x401080d7L, RvvAluOp.VADC),  // vadc.vvm v1, v1, v1, v0
    (0x401040d7L, RvvAluOp.VADC),  // vadc.vxm v1, v1, x0, v0
    (0x401030d7L, RvvAluOp.VADC),  // vadc.vim v1, v1, 0, v0
    (0x441080d7L, RvvAluOp.VMADC), // vmadc.vvm v1, v1, v1, v0
    (0x441040d7L, RvvAluOp.VMADC), // vmadc.vxm v1, v1, x0, v0
    (0x441030d7L, RvvAluOp.VMADC), // vmadc.vim v1, v1, 0, v0
    (0x480000d7L, RvvAluOp.VSBC),  // vsbc.vvm v1, v0, v0, v0
    (0x480040d7L, RvvAluOp.VSBC),  // vsbc.vxm v1, v0, x0, v0
    (0x4c1080d7L, RvvAluOp.VMSBC), // vmsbc.vvm v1, v1, v1, v0
    (0x4c1040d7L, RvvAluOp.VMSBC), // vmsbc.vxm v1, v1, x0, v0

    (0x5c1080d7L, RvvAluOp.VMERGE), // vmerge.vvm v1, v1, v1, v0
    (0x5c1040d7L, RvvAluOp.VMERGE), // vmerge.vxm v1, v1, x0, v0
    (0x5c1030d7L, RvvAluOp.VMERGE), // vmerge.vim v1, v1, 0, v0
    // VMV does not allow mask.

    (0x60000057L, RvvAluOp.VMSEQ),  // vmseq.vv v0, v0, v0, v0.t
    (0x60004057L, RvvAluOp.VMSEQ),  // vmseq.vx v0, v0, x0, v0.t
    (0x60003057L, RvvAluOp.VMSEQ),  // vmseq.vi v0, v0, 0, v0.t
    (0x64000057L, RvvAluOp.VMSNE),  // vmsne.vv v0, v0, v0, v0.t
    (0x64004057L, RvvAluOp.VMSNE),  // vmsne.vx v0, v0, x0, v0.t
    (0x64003057L, RvvAluOp.VMSNE),  // vmsne.vi v0, v0, 0, v0.t
    (0x68000057L, RvvAluOp.VMSLTU), // vmsltu.vv v0, v0, v0, v0.t
    (0x68004057L, RvvAluOp.VMSLTU), // vmsltu.vx v0, v0, x0, v0.t
    (0x6c000057L, RvvAluOp.VMSLT),  // vmslt.vv v0, v0, v0, v0.t
    (0x6c004057L, RvvAluOp.VMSLT),  // vmslt.vx v0, v0, x0, v0.t
    (0x70000057L, RvvAluOp.VMSLEU), // vmsleu.vv v0, v0, v0, v0.t
    (0x70004057L, RvvAluOp.VMSLEU), // vmsleu.vx v0, v0, x0, v0.t
    (0x70003057L, RvvAluOp.VMSLEU), // vmsleu.vi v0, v0, 0, v0.t
    (0x74000057L, RvvAluOp.VMSLE),  // vmsle.vv v0, v0, v0, v0.t
    (0x74004057L, RvvAluOp.VMSLE),  // vmsle.vx v0, v0, x0, v0.t
    (0x74003057L, RvvAluOp.VMSLE),  // vmsle.vi v0, v0, 0, v0.t
    (0x78004057L, RvvAluOp.VMSGTU), // vmsgtu.vx v0, v0, x0, v0.t
    (0x78003057L, RvvAluOp.VMSGTU), // vmsgtu.vi v0, v0, 0, v0.t
    (0x7c004057L, RvvAluOp.VMSGT),  // vmsgt.vx v0, v0, x0, v0.t
    (0x7c003057L, RvvAluOp.VMSGT),  // vmsgt.vi v0, v0, 0, v0.t

    (0x801080d7L, RvvAluOp.VSADDU), // vsaddu.vv v1, v1, v1, v0.t
    (0x801040d7L, RvvAluOp.VSADDU), // vsaddu.vx v1, v1, x0, v0.t
    (0x801030d7L, RvvAluOp.VSADDU), // vsaddu.vi v1, v1, 0, v0.t
    (0x841080d7L, RvvAluOp.VSADD),  // vsadd.vv v1, v1, v1, v0.t
    (0x841040d7L, RvvAluOp.VSADD),  // vsadd.vx v1, v1, x0, v0.t
    (0x841030d7L, RvvAluOp.VSADD),  // vsadd.vi v1, v1, 0, v0.t
    (0x881080d7L, RvvAluOp.VSSUBU), // vssubu.vv v1, v1, v1, v0.t
    (0x881040d7L, RvvAluOp.VSSUBU), // vssubu.vx v1, v1, x0, v0.t
    (0x8c1080d7L, RvvAluOp.VSSUB),  // vssub.vv v1, v1, v1, v0.t
    (0x8c1040d7L, RvvAluOp.VSSUB),  // vssub.vx v1, v1, x0, v0.t

    (0x9c1080d7L, RvvAluOp.VSMUL), // vsmul.vv v1, v1, v1, v0.t
    (0x9c1040d7L, RvvAluOp.VSMUL), // vsmul.vx v1, v1, x0, v0.t

    // VMV1R does not allow mask.
    // VMV2R does not allow mask.
    // VMV4R does not allow mask.
    // VMV8R does not allow mask.

    (0x941080d7L, RvvAluOp.VSLL),  // vsll.vv v1, v1, v1, v0.t
    (0x941040d7L, RvvAluOp.VSLL),  // vsll.vx v1, v1, x0, v0.t
    (0x941030d7L, RvvAluOp.VSLL),  // vsll.vi v1, v1, 0, v0.t
    (0xa01080d7L, RvvAluOp.VSRL),  // vsrl.vv v1, v1, v1, v0.t
    (0xa01040d7L, RvvAluOp.VSRL),  // vsrl.vx v1, v1, x0, v0.t
    (0xa01030d7L, RvvAluOp.VSRL),  // vsrl.vi v1, v1, 0, v0.t
    (0xa41080d7L, RvvAluOp.VSRA),  // vsra.vv v1, v1, v1, v0.t
    (0xa41040d7L, RvvAluOp.VSRA),  // vsra.vx v1, v1, x0, v0.t
    (0xa41030d7L, RvvAluOp.VSRA),  // vsra.vi v1, v1, 0, v0.t
    (0xa81080d7L, RvvAluOp.VSSRL), // vssrl.vv v1, v1, v1, v0.t
    (0xa81040d7L, RvvAluOp.VSSRL), // vssrl.vx v1, v1, x0, v0.t
    (0xa81030d7L, RvvAluOp.VSSRL), // vssrl.vi v1, v1, 0, v0.t
    (0xac1080d7L, RvvAluOp.VSSRA), // vssra.vv v1, v1, v1, v0.t
    (0xac1040d7L, RvvAluOp.VSSRA), // vssra.vx v1, v1, x0, v0.t
    (0xac1030d7L, RvvAluOp.VSSRA), // vssra.vi v1, v1, 0, v0.t
    (0xb01080d7L, RvvAluOp.VNSRL), // vnsrl.wv v1, v1, v1, v0.t
    (0xb01040d7L, RvvAluOp.VNSRL), // vnsrl.wx v1, v1, x0, v0.t
    (0xb01030d7L, RvvAluOp.VNSRL), // vnsrl.wi v1, v1, 0, v0.t
    (0xb41080d7L, RvvAluOp.VNSRA), // vnsra.wv v1, v1, v1, v0.t
    (0xb41040d7L, RvvAluOp.VNSRA), // vnsra.wx v1, v1, x0, v0.t
    (0xb41030d7L, RvvAluOp.VNSRA), // vnsra.wi v1, v1, 0, v0.t

    (0xb81080d7L, RvvAluOp.VNCLIPU), // vnclipu.wv v1, v1, v1, v0.t
    (0xb81040d7L, RvvAluOp.VNCLIPU), // vnclipu.wx v1, v1, x0, v0.t
    (0xb81030d7L, RvvAluOp.VNCLIPU), // vnclipu.wi v1, v1, 0, v0.t
    (0xbc1080d7L, RvvAluOp.VNCLIP),  // vnclip.wv v1, v1, v1, v0.t
    (0xbc1040d7L, RvvAluOp.VNCLIP),  // vnclip.wx v1, v1, x0, v0.t
    (0xbc1030d7L, RvvAluOp.VNCLIP)   // vnclip.wi v1, v1, 0, v0.t
  )

  val test_cases_errata1 = Seq(
    // These are valid encodings according to the spec but rejected by the assembler.
    // Failed to compile on godbolt rv32gc clang 18.1.0 --target=riscv32-none-eabi -march=rv32im_zve32x -O3
    (0x00000057L, RvvAluOp.VADD),  // vadd.vv v0, v0, v0, v0.t
    (0x00004057L, RvvAluOp.VADD),  // vadd.vx v0, v0, x0, v0.t
    (0x00003057L, RvvAluOp.VADD),  // vadd.vi v0, v0, 0, v0.t
    (0x08000057L, RvvAluOp.VSUB),  // vsub.vv v0, v0, v0, v0.t
    (0x08004057L, RvvAluOp.VSUB),  // vsub.vx v0, v0, x0, v0.t
    (0x0c004057L, RvvAluOp.VRSUB), // vrsub.vx v0, v0, x0, v0.t
    (0x0c003057L, RvvAluOp.VRSUB), // vrsub.vi v0, v0, 0, v0.t

    (0x10000057L, RvvAluOp.VMINU), // vminu.vv v0, v0, v0, v0.t
    (0x10004057L, RvvAluOp.VMINU), // vminu.vx v0, v0, x0, v0.t
    (0x14000057L, RvvAluOp.VMIN),  // vmin.vv v0, v0, v0, v0.t
    (0x14004057L, RvvAluOp.VMIN),  // vmin.vx v0, v0, x0, v0.t
    (0x18000057L, RvvAluOp.VMAXU), // vmaxu.vv v0, v0, v0, v0.t
    (0x18004057L, RvvAluOp.VMAXU), // vmaxu.vx v0, v0, x0, v0.t
    (0x1c000057L, RvvAluOp.VMAX),  // vmax.vv v0, v0, v0, v0.t
    (0x1c004057L, RvvAluOp.VMAX),  // vmax.vx v0, v0, x0, v0.t

    (0x24000057L, RvvAluOp.VAND), // vand.vv v0, v0, v0, v0.t
    (0x24004057L, RvvAluOp.VAND), // vand.vx v0, v0, x0, v0.t
    (0x24003057L, RvvAluOp.VAND), // vand.vi v0, v0, 0, v0.t
    (0x28000057L, RvvAluOp.VOR),  // vor.vv v0, v0, v0, v0.t
    (0x28004057L, RvvAluOp.VOR),  // vor.vx v0, v0, x0, v0.t
    (0x28003057L, RvvAluOp.VOR),  // vor.vi v0, v0, 0, v0.t
    (0x2c000057L, RvvAluOp.VXOR), // vxor.vv v0, v0, v0, v0.t
    (0x2c004057L, RvvAluOp.VXOR), // vxor.vx v0, v0, x0, v0.t
    (0x2c003057L, RvvAluOp.VXOR), // vxor.vi v0, v0, 0, v0.t

    (0x30210057L, RvvAluOp.VRGATHER),     // vrgather.vv v0, v2, v2, v0.t
    (0x30204057L, RvvAluOp.VRGATHER),     // vrgather.vx v0, v2, x0, v0.t
    (0x30203057L, RvvAluOp.VRGATHER),     // vrgather.vi v0, v2, 0, v0.t
    (0x38210057L, RvvAluOp.VRGATHEREI16), // vrgatherei16.vv v1, v2, v2, v0.t

    (0x38204057L, RvvAluOp.VSLIDEUP),   // vslideup.vx v0, v2, x0, v0.t
    (0x38203057L, RvvAluOp.VSLIDEUP),   // vslideup.vi v0, v2, 0, v0.t
    (0x3c204057L, RvvAluOp.VSLIDEDOWN), // vslidedown.vx v0, v2, x0, v0.t
    (0x3c203057L, RvvAluOp.VSLIDEDOWN), // vslidedown.vi v0, v2, 0, v0.t

    // Does not apply to VADC.
    (0x44000057L, RvvAluOp.VMADC), // vmadc.vvm v0, v0, v0, v0
    (0x44004057L, RvvAluOp.VMADC), // vmadc.vxm v0, v0, x0, v0
    (0x44003057L, RvvAluOp.VMADC), // vmadc.vim v0, v0, 0, v0
    // Does not apply to VSBC.
    (0x4c000057L, RvvAluOp.VMSBC), // vmsbc.vvm v0, v0, v0, v0
    (0x4c004057L, RvvAluOp.VMSBC), // vmsbc.vxm v0, v0, x0, v0

    (0x5c000057L, RvvAluOp.VMERGE), // vmerge.vvm v0, v0, v0, v0
    (0x5c004057L, RvvAluOp.VMERGE), // vmerge.vxm v0, v0, x0, v0
    (0x5c003057L, RvvAluOp.VMERGE), // vmerge.vim v0, v0, 0, v0
    // Does not apply to VMV.

    // Does not apply to VMSEQ.
    // Does not apply to VMSNE.
    // Does not apply to VMSLTU.
    // Does not apply to VMSLT.
    // Does not apply to VMSLEU.
    // Does not apply to VMSLE.
    // Does not apply to VMSGTU.
    // Does not apply to VMSGT.

    (0x80000057L, RvvAluOp.VSADDU), // vsaddu.vv v0, v0, v0, v0.t
    (0x80004057L, RvvAluOp.VSADDU), // vsaddu.vx v0, v0, x0, v0.t
    (0x80003057L, RvvAluOp.VSADDU), // vsaddu.vi v0, v0, 0, v0.t
    (0x84000057L, RvvAluOp.VSADD),  // vsadd.vv v0, v0, v0, v0.t
    (0x84004057L, RvvAluOp.VSADD),  // vsadd.vx v0, v0, x0, v0.t
    (0x84003057L, RvvAluOp.VSADD),  // vsadd.vi v0, v0, 0, v0.t
    (0x88000057L, RvvAluOp.VSSUBU), // vssubu.vv v0, v0, v0, v0.t
    (0x88004057L, RvvAluOp.VSSUBU), // vssubu.vx v0, v0, x0, v0.t
    (0x8c000057L, RvvAluOp.VSSUB),  // vssub.vv v0, v0, v0, v0.t
    (0x8c004057L, RvvAluOp.VSSUB),  // vssub.vx v0, v0, x0, v0.t

    (0x9c000057L, RvvAluOp.VSMUL), // vsmul.vv v0, v0, v0, v0.t
    (0x9c004057L, RvvAluOp.VSMUL), // vsmul.vx v0, v0, x0, v0.t

    // Does not apply to VMV1R.
    // Does not apply to VMV2R.
    // Does not apply to VMV4R.
    // Does not apply to VMV8R.

    (0x94000057L, RvvAluOp.VSLL),  // vsll.vv v0, v0, v0, v0.t
    (0x94004057L, RvvAluOp.VSLL),  // vsll.vx v0, v0, x0, v0.t
    (0x94003057L, RvvAluOp.VSLL),  // vsll.vi v0, v0, 0, v0.t
    (0xa0000057L, RvvAluOp.VSRL),  // vsrl.vv v0, v0, v0, v0.t
    (0xa0004057L, RvvAluOp.VSRL),  // vsrl.vx v0, v0, x0, v0.t
    (0xa0003057L, RvvAluOp.VSRL),  // vsrl.vi v0, v0, 0, v0.t
    (0xa4000057L, RvvAluOp.VSRA),  // vsra.vv v0, v0, v0, v0.t
    (0xa4004057L, RvvAluOp.VSRA),  // vsra.vx v0, v0, x0, v0.t
    (0xa4003057L, RvvAluOp.VSRA),  // vsra.vi v0, v0, 0, v0.t
    (0xa8000057L, RvvAluOp.VSSRL), // vssrl.vv v0, v0, v0, v0.t
    (0xa8004057L, RvvAluOp.VSSRL), // vssrl.vx v0, v0, x0, v0.t
    (0xa8003057L, RvvAluOp.VSSRL), // vssrl.vi v0, v0, 0, v0.t
    (0xac000057L, RvvAluOp.VSSRA), // vssra.vv v0, v0, v0, v0.t
    (0xac004057L, RvvAluOp.VSSRA), // vssra.vx v0, v0, x0, v0.t
    (0xac003057L, RvvAluOp.VSSRA), // vssra.vi v0, v0, 0, v0.t
    (0xb0000057L, RvvAluOp.VNSRL), // vnsrl.wv v0, v0, v0, v0.t
    (0xb0004057L, RvvAluOp.VNSRL), // vnsrl.wx v0, v0, x0, v0.t
    (0xb0003057L, RvvAluOp.VNSRL), // vnsrl.wi v0, v0, 0, v0.t
    (0xb4000057L, RvvAluOp.VNSRA), // vnsra.wv v0, v0, v0, v0.t
    (0xb4004057L, RvvAluOp.VNSRA), // vnsra.wx v0, v0, x0, v0.t
    (0xb4003057L, RvvAluOp.VNSRA), // vnsra.wi v0, v0, 0, v0.t

    (0xb8000057L, RvvAluOp.VNCLIPU), // vnclipu.wv v0, v0, v0, v0.t
    (0xb8004057L, RvvAluOp.VNCLIPU), // vnclipu.wx v0, v0, x0, v0.t
    (0xb8003057L, RvvAluOp.VNCLIPU), // vnclipu.wi v0, v0, 0, v0.t
    (0xbc000057L, RvvAluOp.VNCLIP),  // vnclip.wv v0, v0, v0, v0.t
    (0xbc004057L, RvvAluOp.VNCLIP),  // vnclip.wx v0, v0, x0, v0.t
    (0xbc003057L, RvvAluOp.VNCLIP),  // vnclip.wi v0, v0, 0, v0.t

    (0x04001057L, RvvAluOp.VFREDUSUM), // vfredusum.vs v0, v0, v0
    (0x0c001057L, RvvAluOp.VFREDOSUM), // vfredosum.vs v0, v0, v0
    (0x14001057L, RvvAluOp.VFREDMIN),  // vfredmin.vs v0, v0, v0
    (0x1c001057L, RvvAluOp.VFREDMAX)   // vfredmax.vs v0, v0, v0
  )

  "Decode Uncompressed Instructions" in {
    simulate(new Tester) { dut =>
      // Doesn't decode float load/store
      {
        val testCases = Seq(
          0x00052507L, // flw f10, 0(x10)
          0x00a52027L  // fsw f10, 0(x10)
        )

        for (t <- testCases) {
          dut.io.inst.poke(t)
          dut.io.out_valid.expect(0)
        }
      }

      // Decode VAlu ops (no mask) correctly
      test_decode(dut, test_cases_no_mask)

      // Decode VAlu ops (with mask) correctly
      test_decode(dut, test_cases_with_mask)

      // Errata 1: Decode VAlu ops with vd=vm
      test_decode(dut, test_cases_errata1)
    }
  }

  "Decode Compressed Instructions" in {
    simulate(new TesterCompressed(p)) { dut =>
      // Decode VAlu ops (no mask) correctly
      test_decode_compressed(dut, test_cases_no_mask)

      // Decode VAlu ops (with mask) correctly
      test_decode_compressed(dut, test_cases_with_mask)

      // Errata 1: Decode VAlu ops with vd=vm
      test_decode_compressed(dut, test_cases_errata1)
    }
  }
}
