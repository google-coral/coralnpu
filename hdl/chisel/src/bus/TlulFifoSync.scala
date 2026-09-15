package bus

import chisel3._
import chisel3.util._

class TlulFifoSync(
  p: TLULParameters,
  reqDepth: Int = 2,
  rspDepth: Int = 2,
  reqPass: Boolean = true, // Equivalent to flow=true in Queue
  rspPass: Boolean = true, // Equivalent to flow=true in Queue
  spareReqW: Int = 1,
  spareRspW: Int = 1,
  moduleName: String = "TlulFifoSync"
) extends Module {
  require(reqDepth > 0 || reqPass, "reqDepth cannot be 0 if reqPass is false")
  require(rspDepth > 0 || rspPass, "rspDepth cannot be 0 if rspPass is false")

  override val desiredName = moduleName
  val io                   = IO(new Bundle {
    // Host-facing interface
    val host = Flipped(new OpenTitanTileLink.Host2Device(p))

    // Device-facing interface
    val device = new OpenTitanTileLink.Host2Device(p)

    // Spare side channels
    val spare_req_i = Input(UInt(spareReqW.W))
    val spare_req_o = Output(UInt(spareReqW.W))
    val spare_rsp_i = Input(UInt(spareRspW.W))
    val spare_rsp_o = Output(UInt(spareRspW.W))
  })

  // A bundle to hold the TileLink A channel data plus the spare bits
  class AChannelWithSpare extends Bundle {
    val a     = new OpenTitanTileLink.A_Channel(p)
    val spare = UInt(spareReqW.W)
  }

  // A bundle to hold the TileLink D channel data plus the spare bits
  class DChannelWithSpare extends Bundle {
    val d     = new OpenTitanTileLink.D_Channel(p)
    val spare = UInt(spareRspW.W)
  }

  // Request FIFO (Host to Device)
  if (reqDepth > 0) {
    val reqFifo = Module(new Queue(new AChannelWithSpare, reqDepth, flow = reqPass))
    reqFifo.io.enq.valid      := io.host.a.valid
    io.host.a.ready           := reqFifo.io.enq.ready
    reqFifo.io.enq.bits.a     := io.host.a.bits
    reqFifo.io.enq.bits.spare := io.spare_req_i

    io.device.a.valid    := reqFifo.io.deq.valid
    reqFifo.io.deq.ready := io.device.a.ready
    io.device.a.bits     := reqFifo.io.deq.bits.a
    io.spare_req_o       := reqFifo.io.deq.bits.spare
  } else {
    io.device.a.valid := io.host.a.valid
    io.host.a.ready   := io.device.a.ready
    io.device.a.bits  := io.host.a.bits
    io.spare_req_o    := io.spare_req_i
  }

  // Response FIFO (Device to Host)
  val device_d_bits_sanitized = Wire(chiselTypeOf(io.device.d.bits))
  device_d_bits_sanitized      := io.device.d.bits
  device_d_bits_sanitized.data := Mux(
    io.device.d.bits.opcode === TLULOpcodesD.AccessAckData.asUInt,
    io.device.d.bits.data,
    0.U
  )

  if (rspDepth > 0) {
    val rspFifo =
      Module(new Queue(new DChannelWithSpare, rspDepth, flow = rspPass))
    rspFifo.io.enq.valid      := io.device.d.valid
    io.device.d.ready         := rspFifo.io.enq.ready
    rspFifo.io.enq.bits.d     := device_d_bits_sanitized
    rspFifo.io.enq.bits.spare := io.spare_rsp_i

    io.host.d.valid      := rspFifo.io.deq.valid
    rspFifo.io.deq.ready := io.host.d.ready
    io.host.d.bits       := rspFifo.io.deq.bits.d
    io.spare_rsp_o       := rspFifo.io.deq.bits.spare
  } else {
    io.host.d.valid   := io.device.d.valid
    io.device.d.ready := io.host.d.ready
    io.host.d.bits    := device_d_bits_sanitized
    io.spare_rsp_o    := io.spare_rsp_i
  }
}

import common.ChiselEmitter

object TlulFifoSyncEmitter extends App {
  val tlul_p = new TLULParameters(dataBits = 256, addrBits = 32, idBits = 6)
  ChiselEmitter.emit(new TlulFifoSync(tlul_p), args)
}

object EmitTlulFifoSyncDepth0 extends App {
  val tlul_p = new TLULParameters(dataBits = 128, addrBits = 32, idBits = 6)
  ChiselEmitter.emit(
    new TlulFifoSync(
      p = tlul_p,
      reqDepth = 0,
      rspDepth = 0,
      spareReqW = 4,
      moduleName = "TlulFifoSync_Depth0"
    ),
    args
  )
}
