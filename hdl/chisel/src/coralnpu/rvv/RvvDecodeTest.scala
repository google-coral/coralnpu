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
    params.enableVme = true
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

  class TesterMset(p: Parameters) extends Module {
    val io = IO(new Bundle {
      val inst                = Input(UInt(32.W))
      val rawIsVsetvl         = Output(Bool())
      val rawMsetWritesMtype  = Output(Bool())
      val rawMsetWritesVtype  = Output(Bool())
      val rawWritesMtype      = Output(Bool())
      val compMsetWritesMtype = Output(Bool())
      val compMsetWritesVtype = Output(Bool())
      val compIsMsettn        = Output(Bool())
      val compWritesRd        = Output(Bool())
      val compWritesVecReg    = Output(Bool())
    })

    io.rawIsVsetvl        := RvvCompressedInstruction.isVsetvl(io.inst)
    io.rawMsetWritesMtype := RvvCompressedInstruction.isMsetWritesMtype(io.inst)
    io.rawMsetWritesVtype := RvvCompressedInstruction.isMsetWritesVtype(io.inst)
    io.rawWritesMtype     := RvvCompressedInstruction.writesMtype(io.inst)

    val comp = RvvCompressedInstruction.from_uncompressed(p, io.inst, 0.U)
    io.compMsetWritesMtype := comp.valid && comp.bits.isMsetWritesMtype()
    io.compMsetWritesVtype := comp.valid && comp.bits.isMsetWritesVtype()
    io.compIsMsettn        := comp.valid && comp.bits.isMsettn()
    io.compWritesRd        := comp.valid && comp.bits.writesRd()
    io.compWritesVecReg    := comp.valid && comp.bits.writesVectorRegister()
  }

  class TesterLsuLegality(p: Parameters) extends Module {
    val io = IO(new Bundle {
      val inst       = Input(UInt(32.W))
      val sew        = Input(UInt(3.W))
      val lmul_orig  = Input(UInt(3.W))
      val compValid  = Output(Bool())
      val illegalCfg = Output(Bool())
    })

    val comp = RvvCompressedInstruction.from_uncompressed(p, io.inst, 0.U)
    io.compValid  := comp.valid
    io.illegalCfg := comp.valid && comp.bits.isIllegalLsuConfig(io.sew, io.lmul_orig)
  }

  class TesterVtxmm(p: Parameters) extends Module {
    val io = IO(new Bundle {
      val inst                 = Input(UInt(32.W))
      val compValid            = Output(Bool())
      val isVtxmm              = Output(Bool())
      val isVtfmm              = Output(Bool())
      val requiresValidMtwiden = Output(Bool())
      val accessesTile         = Output(Bool())
      val writesVecReg         = Output(Bool())
      val origEncoding         = Output(UInt(32.W))
    })

    val comp = RvvCompressedInstruction.from_uncompressed(p, io.inst, 0.U)
    io.compValid            := comp.valid
    io.isVtxmm              := comp.valid && comp.bits.isVtxmm()
    io.isVtfmm              := comp.valid && comp.bits.isVtfmm()
    io.requiresValidMtwiden := comp.valid && comp.bits.requiresValidMtwiden()
    io.accessesTile         := comp.valid && comp.bits.accessesTile()
    io.writesVecReg         := comp.valid && comp.bits.writesVectorRegister()
    io.origEncoding         := comp.bits.originalEncoding()
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
    (0xb2010057L, RvvAluOp.VNSRL), // vnsrl.wv v0, v0, v2
    (0xb2004057L, RvvAluOp.VNSRL), // vnsrl.wx v0, v0, x0
    (0xb2003057L, RvvAluOp.VNSRL), // vnsrl.wi v0, v0, 0
    (0xb6010057L, RvvAluOp.VNSRA), // vnsra.wv v0, v0, v2
    (0xb6004057L, RvvAluOp.VNSRA), // vnsra.wx v0, v0, x0
    (0xb6003057L, RvvAluOp.VNSRA), // vnsra.wi v0, v0, 0

    (0xba010057L, RvvAluOp.VNCLIPU), // vnclipu.wv v0, v0, v2
    (0xba004057L, RvvAluOp.VNCLIPU), // vnclipu.wx v0, v0, x0
    (0xba003057L, RvvAluOp.VNCLIPU), // vnclipu.wi v0, v0, 0
    (0xbe010057L, RvvAluOp.VNCLIP),  // vnclip.wv v0, v0, v2
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

    (0x241080d7L, RvvAluOp.VAND), // vand.vv v1, v1, v1, v0.t
    (0x241040d7L, RvvAluOp.VAND), // vand.vx v1, v1, x0, v0.t
    (0x241030d7L, RvvAluOp.VAND), // vand.vi v1, v1, 0, v0.t
    (0x281080d7L, RvvAluOp.VOR),  // vor.vv v1, v1, v1, v0.t
    (0x281040d7L, RvvAluOp.VOR),  // vor.vx v1, v1, x0, v0.t
    (0x281030d7L, RvvAluOp.VOR),  // vor.vi v1, v1, 0, v0.t
    (0x2c1080d7L, RvvAluOp.VXOR), // vxor.vv v1, v1, v1, v0.t
    (0x2c1040d7L, RvvAluOp.VXOR), // vxor.vx v1, v1, x0, v0.t
    (0x2c1030d7L, RvvAluOp.VXOR), // vxor.vi v1, v1, 0, v0.t

    (0x302100d7L, RvvAluOp.VRGATHER),     // vrgather.vv v1, v2, v2, v0.t
    (0x302040d7L, RvvAluOp.VRGATHER),     // vrgather.vx v1, v2, x0, v0.t
    (0x302030d7L, RvvAluOp.VRGATHER),     // vrgather.vi v1, v2, 0, v0.t
    (0x382100d7L, RvvAluOp.VRGATHEREI16), // vrgatherei16.vv v1, v2, v2, v0.t

    (0x382040d7L, RvvAluOp.VSLIDEUP),   // vslideup.vx v1, v2, x0, v0.t
    (0x382030d7L, RvvAluOp.VSLIDEUP),   // vslideup.vi v1, v2, 0, v0.t
    (0x3c2040d7L, RvvAluOp.VSLIDEDOWN), // vslidedown.vx v1, v2, x0, v0.t
    (0x3c2030d7L, RvvAluOp.VSLIDEDOWN), // vslidedown.vi v1, v2, 0, v0.t

    (0x401080d7L, RvvAluOp.VADC),  // vadc.vvm v1, v1, v1, v0
    (0x401040d7L, RvvAluOp.VADC),  // vadc.vxm v1, v1, x0, v0
    (0x401030d7L, RvvAluOp.VADC),  // vadc.vim v1, v1, 0, v0
    (0x441080d7L, RvvAluOp.VMADC), // vmadc.vvm v1, v1, v1, v0
    (0x441040d7L, RvvAluOp.VMADC), // vmadc.vxm v1, v1, x0, v0
    (0x441030d7L, RvvAluOp.VMADC), // vmadc.vim v1, v1, 0, v0
    (0x481080d7L, RvvAluOp.VSBC),  // vsbc.vvm v1, v1, v1, v0
    (0x481040d7L, RvvAluOp.VSBC),  // vsbc.vxm v1, v1, x0, v0
    (0x4c1080d7L, RvvAluOp.VMSBC), // vmsbc.vvm v1, v1, v1, v0
    (0x4c1040d7L, RvvAluOp.VMSBC), // vmsbc.vxm v1, v1, x0, v0

    (0x5c1080d7L, RvvAluOp.VMERGE), // vmerge.vvm v1, v1, v1, v0
    (0x5c1040d7L, RvvAluOp.VMERGE), // vmerge.vxm v1, v1, x0, v0
    (0x5c1030d7L, RvvAluOp.VMERGE), // vmerge.vim v1, v1, 0, v0
    // VMV does not allow mask.

    (0x60108057L, RvvAluOp.VMSEQ),  // vmseq.vv v0, v1, v1, v0.t
    (0x60104057L, RvvAluOp.VMSEQ),  // vmseq.vx v0, v1, x0, v0.t
    (0x60103057L, RvvAluOp.VMSEQ),  // vmseq.vi v0, v1, 0, v0.t
    (0x64108057L, RvvAluOp.VMSNE),  // vmsne.vv v0, v1, v1, v0.t
    (0x64104057L, RvvAluOp.VMSNE),  // vmseq.vx v0, v1, x0, v0.t
    (0x64103057L, RvvAluOp.VMSNE),  // vmsne.vi v0, v1, 0, v0.t
    (0x68108057L, RvvAluOp.VMSLTU), // vmsltu.vv v0, v1, v1, v0.t
    (0x68104057L, RvvAluOp.VMSLTU), // vmsltu.vx v0, v1, x0, v0.t
    (0x6c108057L, RvvAluOp.VMSLT),  // vmslt.vv v0, v1, v1, v0.t
    (0x6c104057L, RvvAluOp.VMSLT),  // vmslt.vx v0, v1, x0, v0.t
    (0x70108057L, RvvAluOp.VMSLEU), // vmsleu.vv v0, v1, v1, v0.t
    (0x70104057L, RvvAluOp.VMSLEU), // vmsleu.vx v0, v1, x0, v0.t
    (0x70103057L, RvvAluOp.VMSLEU), // vmsleu.vi v0, v1, 0, v0.t
    (0x74108057L, RvvAluOp.VMSLE),  // vmsle.vv v0, v1, v1, v0.t
    (0x74104057L, RvvAluOp.VMSLE),  // vmsle.vx v0, v1, x0, v0.t
    (0x74103057L, RvvAluOp.VMSLE),  // vmsle.vi v0, v1, 0, v0.t
    (0x78104057L, RvvAluOp.VMSGTU), // vmsgtu.vx v0, v1, x0, v0.t
    (0x78103057L, RvvAluOp.VMSGTU), // vmsgtu.vi v0, v1, 0, v0.t
    (0x7c104057L, RvvAluOp.VMSGT),  // vmsgt.vx v0, v1, x0, v0.t
    (0x7c103057L, RvvAluOp.VMSGT),  // vmsgt.vi v0, v1, 0, v0.t

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
    (0xb02080d7L, RvvAluOp.VNSRL), // vnsrl.wv v1, v2, v1, v0.t
    (0xb01040d7L, RvvAluOp.VNSRL), // vnsrl.wx v1, v1, x0, v0.t
    (0xb01030d7L, RvvAluOp.VNSRL), // vnsrl.wi v1, v1, 0, v0.t
    (0xb42080d7L, RvvAluOp.VNSRA), // vnsra.wv v1, v2, v1, v0.t
    (0xb41040d7L, RvvAluOp.VNSRA), // vnsra.wx v1, v1, x0, v0.t
    (0xb41030d7L, RvvAluOp.VNSRA), // vnsra.wi v1, v1, 0, v0.t

    (0xb82080d7L, RvvAluOp.VNCLIPU), // vnclipu.wv v1, v2, v1, v0.t
    (0xb81040d7L, RvvAluOp.VNCLIPU), // vnclipu.wx v1, v1, x0, v0.t
    (0xb81030d7L, RvvAluOp.VNCLIPU), // vnclipu.wi v1, v1, 0, v0.t
    (0xbc2080d7L, RvvAluOp.VNCLIP),  // vnclip.wv v1, v2, v1, v0.t
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

      // Masked reductions with vd=v0, vs2!=v0, vs1!=v0, vm=0 are legal per RVV 1.0 Section 5.3.
      val validMaskedReductionsToV0 = Seq(
        (0x04109057L, RvvAluOp.VFREDUSUM), // vfredusum.vs v0, v1, v1, v0.t
        (0x0c109057L, RvvAluOp.VFREDOSUM), // vfredosum.vs v0, v1, v1, v0.t
        (0x14109057L, RvvAluOp.VFREDMIN),  // vfredmin.vs v0, v1, v1, v0.t
        (0x1c109057L, RvvAluOp.VFREDMAX)   // vfredmax.vs v0, v1, v1, v0.t
      )
      test_decode_compressed(dut, validMaskedReductionsToV0)

      // Reserved encodings (RVV 1.0 Sections 5.2 & 5.3: vd=v0 or vs=v0 with vm=0,
      // and narrowing .wv with vs2 == vs1) must be rejected by from_uncompressed.
      val reservedCases = test_cases_errata1.map(_._1) ++ Seq(
        0xb2000057L, // vnsrl.wv v0, v0, v0
        0xb6000057L, // vnsra.wv v0, v0, v0
        0xba000057L, // vnclipu.wv v0, v0, v0
        0xbe000057L  // vnclip.wv v0, v0, v0
      )
      for (inst <- reservedCases) {
        dut.io.inst.poke(inst)
        dut.io.out_valid.expect(0)
      }
    }
  }

  "Decode Mset Instructions and CSR write properties" in {
    simulate(new TesterMset(p)) { dut =>
      case class TestCase(
        inst: Long,
        msetWritesMtype: Boolean,
        msetWritesVtype: Boolean,
        isMsettn: Boolean,
        isVsetvl: Boolean = false,
        writesRd: Boolean = true,
        writesVecReg: Boolean = false
      )
      val cases = Seq(
        TestCase(
          0x84007057L,
          msetWritesMtype = true,
          msetWritesVtype = true,
          isMsettn = false,
          writesRd = false
        ), // msetmtype
        TestCase(
          0x84b57057L,
          msetWritesMtype = true,
          msetWritesVtype = true,
          isMsettn = false,
          writesRd = false
        ), // msetmtype with rs1/rs2
        TestCase(
          0x88007057L,
          msetWritesMtype = false,
          msetWritesVtype = false,
          isMsettn = true
        ), // msettn
        TestCase(
          0x880572d7L,
          msetWritesMtype = false,
          msetWritesVtype = false,
          isMsettn = true
        ), // msettn with rd/rs1
        TestCase(
          0x88107057L,
          msetWritesMtype = true,
          msetWritesVtype = false,
          isMsettn = false
        ), // msettm
        TestCase(
          0x881572d7L,
          msetWritesMtype = true,
          msetWritesVtype = false,
          isMsettn = false
        ), // msettm with rd/rs1
        TestCase(
          0x88207057L,
          msetWritesMtype = true,
          msetWritesVtype = false,
          isMsettn = false
        ), // msettk
        TestCase(
          0x882572d7L,
          msetWritesMtype = true,
          msetWritesVtype = false,
          isMsettn = false
        ), // msettk with rd/rs1
        TestCase(
          0x88407057L,
          msetWritesMtype = true,
          msetWritesVtype = true,
          isMsettn = false,
          writesRd = false
        ), // msetmtypei
        // Standard vset* (isVsetvl = true; write both mtype and vtype via writesMtype/writesVtype)
        TestCase(
          0x00007057L,
          msetWritesMtype = false,
          msetWritesVtype = false,
          isMsettn = false,
          isVsetvl = true
        ), // vsetvli
        TestCase(
          0xc0007057L,
          msetWritesMtype = false,
          msetWritesVtype = false,
          isMsettn = false,
          isVsetvl = true
        ), // vsetivli
        TestCase(
          0x80007057L,
          msetWritesMtype = false,
          msetWritesVtype = false,
          isMsettn = false,
          isVsetvl = true
        ), // vsetvl
        // Non-vset instruction
        TestCase(
          0x02000057L,
          msetWritesMtype = false,
          msetWritesVtype = false,
          isMsettn = false,
          writesRd = false,
          writesVecReg = true
        ) // vadd.vv
      )

      for (c <- cases) {
        val writesMtype = c.isVsetvl || c.msetWritesMtype
        dut.io.inst.poke(c.inst.U)
        dut.io.rawIsVsetvl.expect(c.isVsetvl.B)
        dut.io.rawMsetWritesMtype.expect(c.msetWritesMtype.B)
        dut.io.rawMsetWritesVtype.expect(c.msetWritesVtype.B)
        dut.io.rawWritesMtype.expect(writesMtype.B)
        dut.io.compMsetWritesMtype.expect(c.msetWritesMtype.B)
        dut.io.compMsetWritesVtype.expect(c.msetWritesVtype.B)
        dut.io.compIsMsettn.expect(c.isMsettn.B)
        dut.io.compWritesRd.expect(c.writesRd.B)
        dut.io.compWritesVecReg.expect(c.writesVecReg.B)
      }
    }
  }

  "Validate RVV Load/Store Static and Dynamic Legality" in {
    simulate(new TesterLsuLegality(p)) { dut =>
      // Helper to build standard RVV load (opcode=0x07) or store (opcode=0x27) encodings
      def encodeLsu(
        isStore: Boolean,
        nf: Int,
        mew: Int,
        mop: Int,
        vm: Int,
        vs2OrUmop: Int,
        rs1: Int,
        width: Int,
        vdOrVs3: Int
      ): Long = {
        val opcode = if (isStore) 0x27L else 0x07L
        ((nf.toLong & 0x7L) << 29) |
          ((mew.toLong & 0x1L) << 28) |
          ((mop.toLong & 0x3L) << 26) |
          ((vm.toLong & 0x1L) << 25) |
          ((vs2OrUmop.toLong & 0x1fL) << 20) |
          ((rs1.toLong & 0x1fL) << 15) |
          ((width.toLong & 0x7L) << 12) |
          ((vdOrVs3.toLong & 0x1fL) << 7) |
          opcode
      }

      // 1. Static decode checks in RvvCompressedInstruction.from_uncompressed
      val staticCases = Seq(
        // Valid unit-stride loads/stores
        (
          encodeLsu(
            isStore = false,
            nf = 0,
            mew = 0,
            mop = 0,
            vm = 1,
            vs2OrUmop = 0,
            rs1 = 10,
            width = 0,
            vdOrVs3 = 0
          ),
          true
        ), // vle8.v v0, (a0)
        // Masked load/store using v0 is illegal (overlaps mask register v0.t)
        (
          encodeLsu(
            isStore = true,
            nf = 0,
            mew = 0,
            mop = 0,
            vm = 0,
            vs2OrUmop = 0,
            rs1 = 10,
            width = 0,
            vdOrVs3 = 0
          ),
          false
        ), // vse8.v v0, (a0), v0.t
        (
          encodeLsu(
            isStore = false,
            nf = 0,
            mew = 0,
            mop = 0,
            vm = 0,
            vs2OrUmop = 0,
            rs1 = 10,
            width = 0,
            vdOrVs3 = 0
          ),
          false
        ), // vle8.v v0, (a0), v0.t
        (
          encodeLsu(
            isStore = false,
            nf = 0,
            mew = 0,
            mop = 2,
            vm = 0,
            vs2OrUmop = 1,
            rs1 = 10,
            width = 0,
            vdOrVs3 = 0
          ),
          false
        ), // vlse8.v v0, (a0), x1, v0.t
        (
          encodeLsu(
            isStore = false,
            nf = 0,
            mew = 0,
            mop = 1,
            vm = 0,
            vs2OrUmop = 4,
            rs1 = 10,
            width = 0,
            vdOrVs3 = 0
          ),
          false
        ), // vluxei8.v v0, (a0), v4, v0.t
        // Fault-only-first on store is illegal
        (
          encodeLsu(
            isStore = false,
            nf = 0,
            mew = 0,
            mop = 0,
            vm = 1,
            vs2OrUmop = 0x10,
            rs1 = 10,
            width = 0,
            vdOrVs3 = 4
          ),
          true
        ), // vle8ff.v v4, (a0)
        (
          encodeLsu(
            isStore = true,
            nf = 0,
            mew = 0,
            mop = 0,
            vm = 1,
            vs2OrUmop = 0x10,
            rs1 = 10,
            width = 0,
            vdOrVs3 = 4
          ),
          false
        ), // vse8ff.v (illegal)
        // Mask load/store (umop=01011): requires vm=1, nf=0, width=000
        (
          encodeLsu(
            isStore = false,
            nf = 0,
            mew = 0,
            mop = 0,
            vm = 1,
            vs2OrUmop = 0x0b,
            rs1 = 10,
            width = 0,
            vdOrVs3 = 4
          ),
          true
        ), // vlm.v v4, (a0)
        (
          encodeLsu(
            isStore = false,
            nf = 0,
            mew = 0,
            mop = 0,
            vm = 0,
            vs2OrUmop = 0x0b,
            rs1 = 10,
            width = 0,
            vdOrVs3 = 4
          ),
          false
        ), // vlm.v with vm=0
        (
          encodeLsu(
            isStore = false,
            nf = 1,
            mew = 0,
            mop = 0,
            vm = 1,
            vs2OrUmop = 0x0b,
            rs1 = 10,
            width = 0,
            vdOrVs3 = 4
          ),
          false
        ), // vlm.v with nf=1
        (
          encodeLsu(
            isStore = true,
            nf = 0,
            mew = 0,
            mop = 0,
            vm = 1,
            vs2OrUmop = 0x0b,
            rs1 = 10,
            width = 5,
            vdOrVs3 = 4
          ),
          false
        ), // vsm.v with width=e16
        // Whole-register load/store (umop=01000): requires vm=1, nf in {0,1,3,7}, vd aligned to nf+1, store width=000
        (
          encodeLsu(
            isStore = false,
            nf = 1,
            mew = 0,
            mop = 0,
            vm = 1,
            vs2OrUmop = 0x08,
            rs1 = 10,
            width = 5,
            vdOrVs3 = 4
          ),
          true
        ), // vl2re16.v v4, (a0)
        (
          encodeLsu(
            isStore = false,
            nf = 1,
            mew = 0,
            mop = 0,
            vm = 1,
            vs2OrUmop = 0x08,
            rs1 = 10,
            width = 5,
            vdOrVs3 = 5
          ),
          false
        ), // vl2re16.v v5 (unaligned)
        (
          encodeLsu(
            isStore = false,
            nf = 2,
            mew = 0,
            mop = 0,
            vm = 1,
            vs2OrUmop = 0x08,
            rs1 = 10,
            width = 0,
            vdOrVs3 = 4
          ),
          false
        ), // vl3re8.v (invalid nf=2)
        (
          encodeLsu(
            isStore = true,
            nf = 0,
            mew = 0,
            mop = 0,
            vm = 1,
            vs2OrUmop = 0x08,
            rs1 = 10,
            width = 5,
            vdOrVs3 = 4
          ),
          false
        ), // vs1re16.v (reserved width)
        // EEW=64 (width=111, mew=0) is illegal on Zve32x
        (
          encodeLsu(
            isStore = false,
            nf = 0,
            mew = 0,
            mop = 1,
            vm = 1,
            vs2OrUmop = 4,
            rs1 = 10,
            width = 7,
            vdOrVs3 = 8
          ),
          false
        ) // vluxei64.v
      )

      for ((inst, expectedValid) <- staticCases) {
        dut.io.inst.poke(inst.U)
        dut.io.sew.poke(0.U)
        dut.io.lmul_orig.poke(0.U)
        dut.io.compValid.expect(expectedValid.B)
      }

      // 2. Dynamic vtype config checks in isIllegalLsuConfig(sew, lmul_orig)
      // sew: 0 -> e8, 1 -> e16, 2 -> e32
      // lmul_orig: 0 -> m1, 1 -> m2, 2 -> m4, 3 -> m8, 6 -> mf4 (-2), 7 -> mf2 (-1)
      case class DynCase(inst: Long, sew: Int, lmul: Int, expectIllegal: Boolean)
      val dynCases = Seq(
        // Valid baseline: vle16.v v8, (a0) with SEW=16, LMUL=1 -> EMUL=1
        DynCase(
          encodeLsu(
            isStore = false,
            nf = 0,
            mew = 0,
            mop = 0,
            vm = 1,
            vs2OrUmop = 0,
            rs1 = 10,
            width = 5,
            vdOrVs3 = 8
          ),
          sew = 1,
          lmul = 0,
          expectIllegal = false
        ),
        // EMUL > 8: vle16.v v8, (a0) with SEW=8, LMUL=8 -> EMUL=16
        DynCase(
          encodeLsu(
            isStore = false,
            nf = 0,
            mew = 0,
            mop = 0,
            vm = 1,
            vs2OrUmop = 0,
            rs1 = 10,
            width = 5,
            vdOrVs3 = 8
          ),
          sew = 0,
          lmul = 3,
          expectIllegal = true
        ),
        // EMUL < 1/4: vle8.v v8, (a0) with SEW=32, LMUL=1/2 -> EMUL=1/8
        DynCase(
          encodeLsu(
            isStore = false,
            nf = 0,
            mew = 0,
            mop = 0,
            vm = 1,
            vs2OrUmop = 0,
            rs1 = 10,
            width = 0,
            vdOrVs3 = 8
          ),
          sew = 2,
          lmul = 7,
          expectIllegal = true
        ),
        // Unaligned vd for EMUL=2: vle16.v v1, (a0) with SEW=8, LMUL=1 -> EMUL=2
        DynCase(
          encodeLsu(
            isStore = false,
            nf = 0,
            mew = 0,
            mop = 0,
            vm = 1,
            vs2OrUmop = 0,
            rs1 = 10,
            width = 5,
            vdOrVs3 = 1
          ),
          sew = 0,
          lmul = 0,
          expectIllegal = true
        ),
        // Segment NFIELDS * EMUL > 8: vlseg2e16.v v8, (a0) with SEW=8, LMUL=4 -> NFIELDS=2, EMUL=8 -> 16 > 8
        DynCase(
          encodeLsu(
            isStore = false,
            nf = 1,
            mew = 0,
            mop = 0,
            vm = 1,
            vs2OrUmop = 0,
            rs1 = 10,
            width = 5,
            vdOrVs3 = 8
          ),
          sew = 0,
          lmul = 2,
          expectIllegal = true
        ),
        // Segment vd + NFIELDS * EMUL > 32: vlseg4e8.v v30, (a0) with SEW=8, LMUL=1 -> 30 + 4 = 34 > 32
        DynCase(
          encodeLsu(
            isStore = false,
            nf = 3,
            mew = 0,
            mop = 0,
            vm = 1,
            vs2OrUmop = 0,
            rs1 = 10,
            width = 0,
            vdOrVs3 = 30
          ),
          sew = 0,
          lmul = 0,
          expectIllegal = true
        ),
        // Unaligned vs2 for indexed load when EMUL_index=2: vluxei16.v v4, (a0), v1 with SEW=8, LMUL=1
        DynCase(
          encodeLsu(
            isStore = false,
            nf = 0,
            mew = 0,
            mop = 1,
            vm = 1,
            vs2OrUmop = 1,
            rs1 = 10,
            width = 5,
            vdOrVs3 = 4
          ),
          sew = 0,
          lmul = 0,
          expectIllegal = true
        ),
        // Narrowing indexed load (EEW_index=16 > SEW=8, LMUL=1 -> EMUL_data=1, EMUL_index=2):
        // vd=v4 (lowest part of vs2=[v4,v5]) is legal; vd=v5 (upper part of vs2=[v4,v5]) is illegal
        DynCase(
          encodeLsu(
            isStore = false,
            nf = 0,
            mew = 0,
            mop = 1,
            vm = 1,
            vs2OrUmop = 4,
            rs1 = 10,
            width = 5,
            vdOrVs3 = 4
          ),
          sew = 0,
          lmul = 0,
          expectIllegal = false
        ),
        DynCase(
          encodeLsu(
            isStore = false,
            nf = 0,
            mew = 0,
            mop = 1,
            vm = 1,
            vs2OrUmop = 4,
            rs1 = 10,
            width = 5,
            vdOrVs3 = 5
          ),
          sew = 0,
          lmul = 0,
          expectIllegal = true
        ),
        // Widening indexed load with EMUL_index >= 1 (EEW_index=8 < SEW=16, LMUL=2 -> EMUL_data=2, EMUL_index=1):
        // vs2=v5 (highest part of vd=[v4,v5]) is legal; vs2=v4 (lower part of vd=[v4,v5]) is illegal
        DynCase(
          encodeLsu(
            isStore = false,
            nf = 0,
            mew = 0,
            mop = 1,
            vm = 1,
            vs2OrUmop = 5,
            rs1 = 10,
            width = 0,
            vdOrVs3 = 4
          ),
          sew = 1,
          lmul = 1,
          expectIllegal = false
        ),
        DynCase(
          encodeLsu(
            isStore = false,
            nf = 0,
            mew = 0,
            mop = 1,
            vm = 1,
            vs2OrUmop = 4,
            rs1 = 10,
            width = 0,
            vdOrVs3 = 4
          ),
          sew = 1,
          lmul = 1,
          expectIllegal = true
        ),
        // Widening indexed load with EMUL_index < 1 (EEW_index=8 < SEW=16, LMUL=1/2 -> EMUL_data=1/2, EMUL_index=1/4):
        // Any overlap (vd=v4, vs2=v4) is illegal when EMUL_index < 1!
        DynCase(
          encodeLsu(
            isStore = false,
            nf = 0,
            mew = 0,
            mop = 1,
            vm = 1,
            vs2OrUmop = 4,
            rs1 = 10,
            width = 0,
            vdOrVs3 = 4
          ),
          sew = 1,
          lmul = 7,
          expectIllegal = true
        ),
        // Widening 4:1 indexed load with EMUL_index < 1 (EEW_index=8 < SEW=32, LMUL=2 -> EMUL_data=2, EMUL_index=1/2):
        // Even vs2=v5 (highest reg of vd=[v4,v5]) is illegal because EMUL_index = 1/2 < 1!
        DynCase(
          encodeLsu(
            isStore = false,
            nf = 0,
            mew = 0,
            mop = 1,
            vm = 1,
            vs2OrUmop = 5,
            rs1 = 10,
            width = 0,
            vdOrVs3 = 4
          ),
          sew = 2,
          lmul = 1,
          expectIllegal = true
        ),
        // Segment indexed load (nf=1 -> NFIELDS=2): any overlap between vd=[v4,v5] and vs2=v5 is illegal
        DynCase(
          encodeLsu(
            isStore = false,
            nf = 1,
            mew = 0,
            mop = 1,
            vm = 1,
            vs2OrUmop = 5,
            rs1 = 10,
            width = 0,
            vdOrVs3 = 4
          ),
          sew = 0,
          lmul = 0,
          expectIllegal = true
        ),
        DynCase(
          encodeLsu(
            isStore = false,
            nf = 1,
            mew = 0,
            mop = 1,
            vm = 1,
            vs2OrUmop = 6,
            rs1 = 10,
            width = 0,
            vdOrVs3 = 4
          ),
          sew = 0,
          lmul = 0,
          expectIllegal = false
        )
      )

      for (c <- dynCases) {
        dut.io.inst.poke(c.inst.U)
        dut.io.sew.poke(c.sew.U)
        dut.io.lmul_orig.poke(c.lmul.U)
        dut.io.compValid.expect(true.B)
        dut.io.illegalCfg.expect(c.expectIllegal.B)
      }
    }
  }

  "Distinguish OP-VE Matrix Multiply from Standard RVV Widening MAC" in {
    val vmeParams = {
      val params = new Parameters
      params.enableRvv = true
      params.enableVme = true
      params.enableFloat = true
      params.enableVectorBf16 = true
      params
    }
    simulate(new TesterVtxmm(vmeParams)) { dut =>
      case class VtxmmCase(
        inst: Long,
        compValid: Boolean,
        isVtxmm: Boolean,
        isVtfmm: Boolean,
        requiresValidMtwiden: Boolean,
        accessesTile: Boolean,
        writesVecReg: Boolean
      )

      val cases = Seq(
        // vwmaccu.vv v4, v2, v8 (OP-V 0x57, funct6=111100, vm=1, funct3=010)
        VtxmmCase(
          inst = 0xf2812257L,
          compValid = true,
          isVtxmm = false,
          isVtfmm = false,
          requiresValidMtwiden = false,
          accessesTile = false,
          writesVecReg = true
        ),
        // vwmaccu.vx v4, x10, v8 (OP-V 0x57, funct6=111100, vm=1, funct3=110)
        VtxmmCase(
          inst = 0xf2856257L,
          compValid = true,
          isVtxmm = false,
          isVtfmm = false,
          requiresValidMtwiden = false,
          accessesTile = false,
          writesVecReg = true
        ),
        // vtmmu.tvv mt0, v8, v16 (OP-VE 0x77, funct6=111100, vm=1, funct3=000)
        VtxmmCase(
          inst = 0xf2880077L,
          compValid = true,
          isVtxmm = true,
          isVtfmm = false,
          requiresValidMtwiden = true,
          accessesTile = true,
          writesVecReg = false
        ),
        // vtmmu.tvv mt0, v2, v10 (INT16 Half-Hi bases with bit 1 set)
        VtxmmCase(
          inst = 0xf2250077L,
          compValid = true,
          isVtxmm = true,
          isVtfmm = false,
          requiresValidMtwiden = true,
          accessesTile = true,
          writesVecReg = false
        ),
        // vtmms.tvv mt12, v26, v18 (INT16 Half-Hi bases across upper register groups)
        VtxmmCase(
          inst = 0xf3a90cf7L,
          compValid = true,
          isVtxmm = true,
          isVtfmm = false,
          requiresValidMtwiden = true,
          accessesTile = true,
          writesVecReg = false
        ),
        // vtmmu.tvv mt0, v4, v16 (vs2[2]=1 out of KMAX>=2 half-group, must be rejected)
        VtxmmCase(
          inst = 0xf2480077L,
          compValid = false,
          isVtxmm = false,
          isVtfmm = false,
          requiresValidMtwiden = false,
          accessesTile = false,
          writesVecReg = false
        ),
        // vtmmu.tvv mt0, v8, v12 (vs1[2]=1 out of KMAX>=2 half-group, must be rejected)
        VtxmmCase(
          inst = 0xf2860077L,
          compValid = false,
          isVtxmm = false,
          isVtfmm = false,
          requiresValidMtwiden = false,
          accessesTile = false,
          writesVecReg = false
        ),
        // vtmmu.tvv mt2, v8, v16 (misaligned TEW=32 tile specifier, must be rejected)
        VtxmmCase(
          inst = 0xf2880277L,
          compValid = false,
          isVtxmm = false,
          isVtfmm = false,
          requiresValidMtwiden = false,
          accessesTile = false,
          writesVecReg = false
        ),
        // vtfmm.tvv mt0, v8, v16 (OP-VE 0x77, funct6=111100, vm=1, funct3=001)
        VtxmmCase(
          inst = 0xf2881077L,
          compValid = true,
          isVtxmm = true,
          isVtfmm = true,
          requiresValidMtwiden = true,
          accessesTile = true,
          writesVecReg = false
        ),
        // Reserved OP-V (0x57) with funct6=111100, vm=1, funct3=000 (must be rejected)
        VtxmmCase(
          inst = 0xf2880057L,
          compValid = false,
          isVtxmm = false,
          isVtfmm = false,
          requiresValidMtwiden = false,
          accessesTile = false,
          writesVecReg = false
        ),
        // Unsupported vfwmacc.vv (OP-V 0x57, funct6=111100, vm=1, funct3=001) (must be rejected)
        VtxmmCase(
          inst = 0xf2001057L,
          compValid = false,
          isVtxmm = false,
          isVtfmm = false,
          requiresValidMtwiden = false,
          accessesTile = false,
          writesVecReg = false
        )
      )

      for (c <- cases) {
        dut.io.inst.poke(c.inst.U)
        dut.io.compValid.expect(c.compValid.B)
        dut.io.isVtxmm.expect(c.isVtxmm.B)
        dut.io.isVtfmm.expect(c.isVtfmm.B)
        dut.io.requiresValidMtwiden.expect(c.requiresValidMtwiden.B)
        dut.io.accessesTile.expect(c.accessesTile.B)
        dut.io.writesVecReg.expect(c.writesVecReg.B)
        if (c.compValid) {
          dut.io.origEncoding.expect(c.inst.U)
        }
      }
    }
  }

  "Check Dynamic OP-VE Matrix Multiply Legality" in {
    class TesterVtxmmDynamic(p: Parameters) extends Module {
      val io = IO(new Bundle {
        val inst           = Input(UInt(32.W))
        val sew            = Input(UInt(3.W))
        val lmul_orig      = Input(UInt(3.W))
        val mtwiden        = Input(UInt(2.W))
        val altfmt         = Input(Bool())
        val frm            = Input(UInt(3.W))
        val compValid      = Output(Bool())
        val isDynamicLegal = Output(Bool())
      })

      val comp = RvvCompressedInstruction.from_uncompressed(p, io.inst, 0.U)
      io.compValid      := comp.valid
      io.isDynamicLegal := comp.valid && comp.bits.isLegalVtxmmDynamic(
        io.sew,
        io.lmul_orig,
        io.mtwiden,
        io.altfmt,
        io.frm
      )
    }

    val vmeParams = {
      val params = new Parameters
      params.enableRvv = true
      params.enableVme = true
      params.enableFloat = true
      params.enableVectorBf16 = true
      params
    }

    def opVeWord(vs2: Int, vs1: Int, funct3: Int, rd: Int): Long =
      ((0x3cL << 26) | (1L << 25) | (vs2.toLong << 20) | (vs1.toLong << 15) |
        (funct3.toLong << 12) | (rd.toLong << 7) | 0x77L) & 0xffffffffL

    simulate(new TesterVtxmmDynamic(vmeParams)) { dut =>
      case class DynVtxmmCase(
        inst: Long,
        sew: Int,
        lmul: Int,
        mtwiden: Int,
        altfmt: Boolean = false,
        frm: Int = 0,
        expectedLegal: Boolean
      )

      val cases = Seq(
        // INT8 (sew=0, lmul=0, mtwiden=3): v0/v1/v8/v9/v16/v17 allowed, v2/v10 rejected
        DynVtxmmCase(opVeWord(8, 16, 0, 0), sew = 0, lmul = 0, mtwiden = 3, expectedLegal = true),
        DynVtxmmCase(
          opVeWord(9, 17, 0, 1),
          sew = 0,
          lmul = 0,
          mtwiden = 3,
          altfmt = true,
          expectedLegal = true
        ),
        DynVtxmmCase(opVeWord(2, 16, 0, 0), sew = 0, lmul = 0, mtwiden = 3, expectedLegal = false),
        DynVtxmmCase(opVeWord(8, 10, 0, 0), sew = 0, lmul = 0, mtwiden = 3, expectedLegal = false),
        DynVtxmmCase(opVeWord(8, 16, 0, 0), sew = 0, lmul = 0, mtwiden = 2, expectedLegal = false),
        // INT16 (sew=1, lmul=1, mtwiden=2): even Half-Low/Half-Hi allowed, odd or wrong mtwiden rejected
        DynVtxmmCase(opVeWord(2, 18, 0, 8), sew = 1, lmul = 1, mtwiden = 2, expectedLegal = true),
        DynVtxmmCase(
          opVeWord(10, 26, 0, 25),
          sew = 1,
          lmul = 1,
          mtwiden = 2,
          altfmt = true,
          expectedLegal = true
        ),
        DynVtxmmCase(opVeWord(3, 16, 0, 0), sew = 1, lmul = 1, mtwiden = 2, expectedLegal = false),
        DynVtxmmCase(opVeWord(2, 17, 0, 1), sew = 1, lmul = 1, mtwiden = 2, expectedLegal = false),
        DynVtxmmCase(opVeWord(2, 18, 0, 0), sew = 1, lmul = 1, mtwiden = 1, expectedLegal = false),
        // FP32 vtfmm (sew=2, lmul=2, mtwiden=1, altfmt=0): 4-aligned bases allowed (including v4)
        DynVtxmmCase(opVeWord(4, 20, 1, 0), sew = 2, lmul = 2, mtwiden = 1, expectedLegal = true),
        DynVtxmmCase(
          opVeWord(8, 16, 1, 0),
          sew = 2,
          lmul = 2,
          mtwiden = 1,
          altfmt = true,
          expectedLegal = false
        ),
        DynVtxmmCase(opVeWord(2, 16, 1, 0), sew = 2, lmul = 2, mtwiden = 1, expectedLegal = false),
        DynVtxmmCase(
          opVeWord(8, 16, 1, 0),
          sew = 2,
          lmul = 2,
          mtwiden = 1,
          frm = 7,
          expectedLegal = false
        ),
        // BF16 vtfmm.alt (sew=1, lmul=1, mtwiden=2, altfmt=1): even !vs[2] allowed, v4 or altfmt=0 rejected
        DynVtxmmCase(
          opVeWord(2, 18, 1, 1),
          sew = 1,
          lmul = 1,
          mtwiden = 2,
          altfmt = true,
          expectedLegal = true
        ),
        DynVtxmmCase(
          opVeWord(8, 16, 1, 1),
          sew = 1,
          lmul = 1,
          mtwiden = 2,
          altfmt = false,
          expectedLegal = false
        ),
        DynVtxmmCase(
          opVeWord(4, 16, 1, 1),
          sew = 1,
          lmul = 1,
          mtwiden = 2,
          altfmt = true,
          expectedLegal = false
        ),
        DynVtxmmCase(
          opVeWord(2, 18, 1, 1),
          sew = 1,
          lmul = 1,
          mtwiden = 2,
          altfmt = true,
          frm = 5,
          expectedLegal = false
        ),
        // Non-vtxmm RVV instruction (vwmaccu.vv) passes through unaffected
        DynVtxmmCase(0xf2812257L, sew = 0, lmul = 0, mtwiden = 0, expectedLegal = true)
      )

      for (c <- cases) {
        dut.io.inst.poke(c.inst.U)
        dut.io.sew.poke(c.sew.U)
        dut.io.lmul_orig.poke(c.lmul.U)
        dut.io.mtwiden.poke(c.mtwiden.U)
        dut.io.altfmt.poke(c.altfmt.B)
        dut.io.frm.poke(c.frm.U)
        dut.io.compValid.expect(true.B)
        dut.io.isDynamicLegal.expect(c.expectedLegal.B)
      }
    }
  }
}
