// Copyright 2026 Google LLC
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

object BufState extends ChiselEnum {
  val sIdle, sFilling, sDraining = Value
}

class TransposeConfig(val sWidth: Int, val eWidth: Int, val jWidth: Int) extends Bundle {
  val s = UInt(sWidth.W)
  val E = UInt(eWidth.W)
  val j = UInt(jWidth.W)
}

class TransposeBuffer(p: TLULParameters) extends Module {
  val N      = p.w
  val gMax   = log2Ceil(N) // widest group index; g at elemSize 1
  val eMax   = gMax - 1    // largest log2(elemSize)
  val jMax   = log2Ceil(N) // largest trailing zero count from the max stride N
  val eWidth = log2Ceil(eMax + 1)
  val jWidth = log2Ceil(jMax + 1)
  val sWidth = log2Ceil(N + 1)

  val io = IO(new Bundle {
    val in        = Flipped(Decoupled(Vec(N, UInt(8.W))))
    val out       = Decoupled(Vec(N, UInt(8.W)))
    val fillDone  = Output(Bool())
    val drainDone = Output(Bool())
    val cfg       = Flipped(Decoupled(new Bundle {
      val stride = UInt(sWidth.W)
      // elemSize is the byte count; logElemSize is used everywhere downstream
      val logElemSize = UInt(eWidth.W)
    }))
  })

  val banks = Reg(Vec(N, Vec(N, UInt(8.W))))

  val state = RegInit(BufState.sIdle)

  val idle     = state === BufState.sIdle
  val filling  = state === BufState.sFilling
  val draining = state === BufState.sDraining

  val cfgWire = Wire(new TransposeConfig(sWidth, eWidth, jWidth))
  cfgWire.s := io.cfg.bits.stride
  cfgWire.E := io.cfg.bits.logElemSize
  cfgWire.j := PriorityEncoder(io.cfg.bits.stride)

  val reg_cfg = RegEnable(
    cfgWire,
    0.U.asTypeOf(new TransposeConfig(sWidth, eWidth, jWidth)),
    io.cfg.fire
  )

  val r         = RegInit(0.U(sWidth.W))
  val beatCount = RegInit(0.U(sWidth.W))
  val phase     = RegInit(0.U(log2Ceil(N).W))

  val lastRow  = r === reg_cfg.s - 1.U
  val lastBeat = beatCount === reg_cfg.s - 1.U

  state := MuxCase(
    state,
    Seq(
      (idle && io.cfg.fire)                 -> BufState.sFilling,
      (filling && io.in.fire && lastRow)    -> BufState.sDraining,
      (draining && io.out.fire && lastBeat) -> BufState.sIdle
    )
  )

  r         := Mux(io.cfg.fire, 0.U, Mux(filling && io.in.fire, r + 1.U, r))
  beatCount := Mux(io.cfg.fire, 0.U, Mux(draining && io.out.fire, beatCount + 1.U, beatCount))

  assert(
    !io.cfg.fire || ((io.cfg.bits.stride =/= 0.U) && (io.cfg.bits.stride <= N.U)),
    "Stride must be non-zero and less than or equal to N"
  )
  assert(
    !io.cfg.fire || (io.cfg.bits.logElemSize <= eMax.U),
    s"logElemSize must be less than or equal to $eMax"
  )

  io.in.ready  := filling
  io.cfg.ready := idle
  io.fillDone  := draining
  io.drainDone := idle

  // ==========================================
  // WRITE-SIDE ADDRESSING & ROUTING
  // ==========================================

  // γj-1(x) = x ^ (x >> j) ^ (x >> 2j) ^ (x >> 3j) ^ ….
  // Where x = b ^ R   and  R = (r mod 2^j) << (g - j)
  // Note: need to consider case (j>=g)
  def gammaInv(x: UInt, j: Int, g: Int): UInt = {
    if (j == 0 || j >= g) {
      x(g - 1, 0)
    } else {
      var k     = j
      var terms = Seq(x)
      while (k < g) {
        terms = terms :+ (x >> k) // :+ appends a single element to the end of a sequence
        k += j
      }
      val xorSum = terms.reduce(_ ^ _)
      xorSum(g - 1, 0)
    }
  }

  // Write row hash component per jc
  val aWrite = VecInit.tabulate(jMax + 1) { jc =>
    if (jc == 0) 0.U(gMax.W) else ((r & ((1 << jc) - 1).U) << (gMax - jc))(gMax - 1, 0)
  }

  // Runtime masks and per-bank group/offset
  val gMask = VecInit((0 to eMax).map(ec => ((1 << (gMax - ec)) - 1).U(gMax.W)))(reg_cfg.E)
  val tMask = VecInit((0 to eMax).map(ec => ((1 << ec) - 1).U(gMax.W)))(reg_cfg.E)

  val gp_rt = VecInit.tabulate(N)(b => (b.U(gMax.W) >> reg_cfg.E)(gMax - 1, 0))
  val t_rt  = VecInit.tabulate(N)(b => (b.U(gMax.W) & tMask)(gMax - 1, 0))

  // 2D candidate array storing group only
  val srcCandidate = VecInit.tabulate(jMax + 1) { jc =>
    val Rc = (aWrite(jc) >> reg_cfg.E) & gMask
    VecInit.tabulate(N) { b =>
      val sg = gammaInv((gp_rt(b) ^ Rc)(gMax - 1, 0), jc, gMax) & gMask
      sg(gMax - 1, 0)
    }
  }

  // Selection with element shift and offset OR
  val src_b = VecInit.tabulate(N) { b =>
    ((srcCandidate(reg_cfg.j)(b) << reg_cfg.E) | t_rt(b))(gMax - 1, 0)
  }

  val memAddr = r

  for (b <- 0 until N) {
    banks(b)(memAddr) := Mux(io.in.fire, io.in.bits(src_b(b)), banks(b)(memAddr))
  }

  // ==========================================
  // READ-SIDE ADDRESSING, ROUTING & GATHER
  // ==========================================

  val out_valid = RegInit(false.B)
  io.out.valid := out_valid

  val out_ready_or_idle = io.out.ready || !io.out.valid
  val readIssued        = draining && out_ready_or_idle && (phase < reg_cfg.s)

  phase     := Mux(io.cfg.fire, 0.U, Mux(readIssued, phase + 1.U, phase))
  out_valid := Mux(idle, false.B, Mux(readIssued, true.B, Mux(io.out.fire, false.B, out_valid)))

  val eIdxWidth = gMax + sWidth
  val e         = VecInit.tabulate(N)(k => (reg_cfg.s * k.U + phase).pad(eIdxWidth))

  val gc    = gMax.U(log2Ceil(gMax + 1).W) - reg_cfg.E
  val cMask = VecInit((0 to eMax).map(ec => ((1 << (gMax - ec)) - 1).U(gMax.W)))(reg_cfg.E)

  val r_k = VecInit.tabulate(N)(k => (e(k) >> gc)(gMax - 1, 0))
  val c_k = VecInit.tabulate(N)(k => (e(k) & cMask)(gMax - 1, 0))

  // PHASE 1: ADDRESS GENERATION
  // Bank = γj(c) ^ R = gammaCandidate ^ aCandidate
  // Where γj(c) = c ^ (c >> j) and R = (r mod 2^j) << (g - j)

  // The column half of the hash, per j lane
  val gammaCandidate = VecInit.tabulate(jMax + 1, N) { (jc, k) =>
    if (jc == 0 || jc >= gMax) c_k(k) else (c_k(k) ^ (c_k(k) >> jc))(gMax - 1, 0)
  }
  // The row half of the hash
  val aCandidate = VecInit.tabulate(jMax + 1, N) { (jc, k) =>
    if (jc == 0) 0.U(gMax.W) else ((r_k(k) & ((1 << jc) - 1).U) << (gMax - jc))(gMax - 1, 0)
  }

  // Group and addr selection for lanes
  val grp_k = VecInit.tabulate(N) { k =>
    (gammaCandidate(reg_cfg.j)(k) ^ (aCandidate(reg_cfg.j)(k) >> reg_cfg.E)) & cMask
  }
  val addr_k = r_k

  // Lane Validity: all lanes are computed, need to validate useful lanes only
  val G_runtime = N.U >> reg_cfg.E
  val laneValid = VecInit.tabulate(N)(k => k.U < G_runtime)

  // PHASE 2: ADDRESS SCATTER
  val addrGrp = VecInit.tabulate(N) { gp =>
    val hit = VecInit.tabulate(N)(k => laneValid(k) && (grp_k(k) === gp.U))
    assert(!draining || PopCount(hit) <= 1.U, s"Multiple hits for the group $gp during draining")
    Mux1H(hit, addr_k)
  }

  // Grouping banks
  val bankAddr = VecInit.tabulate(N)(b => addrGrp(b.U(gMax.W) >> reg_cfg.E))

  // Bank reads
  val bankData = RegEnable(
    VecInit((0 until N).map(b => banks(b)(bankAddr(b)))),
    readIssued
  )

  // PHASE 3: DATA GATHER
  val grp_k_d = RegEnable(grp_k, readIssued)

  val outByteCandidate = VecInit.tabulate(eMax + 1, N) { (ec, p) =>
    val gc   = gMax - ec
    val lane = p >> ec
    val t    = p & ((1 << ec) - 1)
    val idx  = if (ec == 0) grp_k_d(lane) else Cat(grp_k_d(lane)(gc - 1, 0), t.U(ec.W))
    bankData(idx)
  }

  val gatherData = VecInit.tabulate(N) { p =>
    VecInit((0 to eMax).map(ec => outByteCandidate(ec)(p)))(reg_cfg.E)
  }

  io.out.bits := gatherData
}

import scala.annotation.nowarn
import _root_.circt.stage.{ChiselStage, FirtoolOption}
import chisel3.stage.ChiselGeneratorAnnotation

@nowarn
object TransposeBufferEmitter extends App {
  val tlul_p = new TLULParameters(dataBits = 128, addrBits = 32, idBits = 6)
  (new ChiselStage).execute(
    Array("--target", "systemverilog") ++ args,
    Seq(ChiselGeneratorAnnotation(() => new TransposeBuffer(tlul_p))) ++
      Seq(FirtoolOption("-enable-layers=Verification"))
  )
}
