package bus

import chisel3._
import chisel3.util._

class TlulSocketM1(
  p: TLULParameters,
  M: Int = 4,
  HReqPass: Seq[Boolean] = Nil,
  HRspPass: Seq[Boolean] = Nil,
  HReqDepth: Seq[Int] = Nil,
  HRspDepth: Seq[Int] = Nil,
  DReqPass: Boolean = true,
  DRspPass: Boolean = true,
  DReqDepth: Int = 1,
  DRspDepth: Int = 1,
  moduleName: String = "TlulSocketM1"
) extends Module {
  override val desiredName = moduleName
  val StIdW                = log2Ceil(M)

  // 1. Define device-side parameters (augmented source ID width)
  val p_d = p.augmentId(StIdW)

  val io = IO(new Bundle {
    val tl_h = Flipped(Vec(M, new OpenTitanTileLink.Host2Device(p)))
    val tl_d = new OpenTitanTileLink.Host2Device(p_d)
  })

  // 2. Combinational Request Path (A-Channel)
  val augmented_hosts = (0 until M).map { i =>
    TlulAccessors.augment(io.tl_h(i), i.U(StIdW.W))
  }

  // Arbiter selects one request combinationally
  val arb = Module(new Arbiter(new OpenTitanTileLink.A_Channel(p_d), M))
  for (i <- 0 until M) {
    arb.io.in(i) <> augmented_hosts(i).a
  }

  // Drive device request directly (0 latency)
  io.tl_d.a <> arb.io.out

  // 3. Combinational Response Path (D-Channel)
  // Response steering based purely on the returning source ID
  val rsp_valid  = io.tl_d.d.valid
  val rsp_bits   = io.tl_d.d.bits
  val host_index = rsp_bits.source(StIdW - 1, 0)

  for (i <- 0 until M) {
    augmented_hosts(i).d.valid := rsp_valid && (host_index === i.U)
    augmented_hosts(i).d.bits  := rsp_bits
  }

  // Combine ready signals back to device D-channel
  io.tl_d.d.ready := VecInit(augmented_hosts.map(_.d.ready))(host_index)
}

import common.ChiselEmitter

object TlulSocketM1_2_128Emitter extends App {
  val tlul_p = new TLULParameters(dataBits = 128, addrBits = 32, idBits = 6)
  ChiselEmitter.emit(
    new TlulSocketM1(
      p = tlul_p,
      M = 2,
      HReqDepth = Seq.fill(2)(0),
      HRspDepth = Seq.fill(2)(0),
      DReqDepth = 0,
      DRspDepth = 0,
      moduleName = "TlulSocketM1_2_128"
    ),
    args
  )
}

object TlulSocketM1_3_128Emitter extends App {
  val tlul_p = new TLULParameters(dataBits = 128, addrBits = 32, idBits = 6)
  ChiselEmitter.emit(
    new TlulSocketM1(
      p = tlul_p,
      M = 3,
      HReqDepth = Seq.fill(3)(0),
      HRspDepth = Seq.fill(3)(0),
      DReqDepth = 0,
      DRspDepth = 0,
      moduleName = "TlulSocketM1_3_128"
    ),
    args
  )
}
