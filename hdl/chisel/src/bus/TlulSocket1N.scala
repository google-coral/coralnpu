package bus

import chisel3._
import chisel3.util._
import common.MakeInvalid

// A simple error responder that immediately generates an error response
// for any incoming request.
class TlulErrorResponder(p: TLULParameters) extends Module {
  val io = IO(new Bundle {
    val tl_h = Flipped(new OpenTitanTileLink.Host2Device(p))
  })

  io.tl_h.a.ready := true.B

  val d = RegInit(MakeInvalid(new OpenTitanTileLink.D_Channel(p)))

  d.valid               := io.tl_h.a.fire
  d.bits.size           := Mux(io.tl_h.a.fire, io.tl_h.a.bits.size, d.bits.size)
  d.bits.source         := Mux(io.tl_h.a.fire, io.tl_h.a.bits.source, d.bits.source)
  d.bits.opcode         := TLULOpcodesD.AccessAck.asUInt
  d.bits.param          := 0.U
  d.bits.sink           := 0.U
  d.bits.data           := 0.U
  d.bits.error          := true.B
  d.bits.user.rsp_intg  := 0.U
  d.bits.user.data_intg := 0.U
  io.tl_h.d.valid       := d.valid
  io.tl_h.d.bits        := d.bits
}

class TlulSocket1N(
  p: TLULParameters,
  N: Int = 4,
  HReqPass: Boolean = true,
  HRspPass: Boolean = true,
  HReqDepth: Int = 1,
  HRspDepth: Int = 1,
  DReqPass: Seq[Boolean] = Nil,
  DRspPass: Seq[Boolean] = Nil,
  DReqDepth: Seq[Int] = Nil,
  DRspDepth: Seq[Int] = Nil,
  ExplicitErrs: Boolean = true,
  moduleName: String = "TlulSocket1N"
) extends Module {
  val DReqPass_            = if (DReqPass.isEmpty) Seq.fill(N)(true) else DReqPass
  val DRspPass_            = if (DRspPass.isEmpty) Seq.fill(N)(true) else DRspPass
  val DReqDepth_           = if (DReqDepth.isEmpty) Seq.fill(N)(1) else DReqDepth
  val DRspDepth_           = if (DRspDepth.isEmpty) Seq.fill(N)(1) else DRspDepth
  override val desiredName = moduleName
  val NWD                  = if (ExplicitErrs) log2Ceil(N + 1) else log2Ceil(N)

  val io = IO(new Bundle {
    val tl_h         = Flipped(new OpenTitanTileLink.Host2Device(p))
    val tl_d         = Vec(N, new OpenTitanTileLink.Host2Device(p))
    val dev_select_i = Input(UInt(NWD.W))
  })

  // 1. Instantiations
  val err_resp_opt =
    if (ExplicitErrs && (1 << NWD) > N) Some(Module(new TlulErrorResponder(p))) else None

  // 2. A-channel Request Steering
  val blanked_auser = Wire(new OpenTitanTileLink_A_User)
  blanked_auser.rsvd       := io.tl_h.a.bits.user.rsvd
  blanked_auser.instr_type := io.tl_h.a.bits.user.instr_type
  blanked_auser.cmd_intg   := 0.U
  blanked_auser.data_intg  := 0.U

  for (i <- 0 until N) {
    val dev_select = (io.dev_select_i === i.U)
    io.tl_d(i).a.valid     := io.tl_h.a.valid && dev_select
    io.tl_d(i).a.bits      := io.tl_h.a.bits
    io.tl_d(i).a.bits.user := Mux(dev_select, io.tl_h.a.bits.user, blanked_auser)
  }

  // Error responder request routing
  err_resp_opt.foreach { err_resp =>
    val err_select = (io.dev_select_i >= N.U)
    err_resp.io.tl_h.a.valid := io.tl_h.a.valid && err_select
    err_resp.io.tl_h.a.bits  := io.tl_h.a.bits
  }

  // 3. Host Ready Selection (A-channel backpressure)
  val readys = Wire(Vec(N + 1, Bool()))
  for (i <- 0 until N) {
    readys(i) := io.tl_d(i).a.ready
  }
  readys(N)       := err_resp_opt.map(_.io.tl_h.a.ready).getOrElse(true.B)
  io.tl_h.a.ready := readys(io.dev_select_i)

  // 4. D-channel Response Arbitration
  val d_arb = Module(new Arbiter(new OpenTitanTileLink.D_Channel(p), N + 1))
  for (i <- 0 until N) {
    d_arb.io.in(i) <> io.tl_d(i).d
  }

  // Error responder response routing
  err_resp_opt.foreach { err_resp =>
    d_arb.io.in(N) <> err_resp.io.tl_h.d
  }

  if (err_resp_opt.isEmpty) {
    d_arb.io.in(N).valid := false.B
    d_arb.io.in(N).bits  := DontCare
  }

  io.tl_h.d <> d_arb.io.out
}

import common.ChiselEmitter

object TlulSocket1N_128Emitter extends App {
  val tlul_p = new TLULParameters(dataBits = 128, addrBits = 32, idBits = 6)
  ChiselEmitter.emit(
    new TlulSocket1N(
      p = tlul_p,
      N = 4, // Default value, will be overridden at instantiation
      DReqPass = Seq.fill(4)(true),
      DRspPass = Seq.fill(4)(true),
      DReqDepth = Seq.fill(4)(1),
      DRspDepth = Seq.fill(4)(1),
      moduleName = "TlulSocket1N_128"
    ),
    args
  )
}
