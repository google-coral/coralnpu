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

package coralnpu

import chisel3._
import chisel3.util._
import common._

class PredecodeOutput(p: Parameters) extends Bundle {
  val insts     = Vec(p.fetchInstrSlots, new FetchInstruction(p))
  val count     = UInt(4.W)
  val nextPc    = UInt(p.instructionBits.W)
  val hasJumped = Bool()
}

class FetchResponse(p: Parameters) extends Bundle {
  val addr  = UInt(p.fetchAddrBits.W)
  val inst  = Vec(p.fetchInstrSlots, UInt(p.instructionBits.W))
  val fault = Bool()
}

class Instruction(p: Parameters) extends Bundle {
  val addr = UInt(p.fetchAddrBits.W)
  val inst = UInt(p.instructionBits.W)
}

class FetchReorderBuffer(
  txidBits: Int,
  addrBits: Int,
  dataBits: Int,
  capacity: Int,
  flowResponse: Boolean = false
) extends Module {
  val ctrWidth   = log2Ceil(capacity + 1)
  val indexWidth = log2Ceil(capacity)

  // Structures

  class Response extends Bundle {
    val data  = UInt(dataBits.W)
    val fault = Bool()
  }

  class NewTx extends Bundle {
    val txid = UInt(txidBits.W)
    val addr = UInt(addrBits.W)
  }

  // This comes from the bus
  class ResponseWithTxid extends Bundle {
    val txid = UInt(txidBits.W)
    val resp = new Response()
  }

  // This is just FetchResponse before instructions are separated.
  // I don't want the reorder buffer to understand the idea of instructions.
  class ResponseWithAddr extends Bundle {
    val addr = UInt(addrBits.W)
    val resp = new Response()
  }

  class Entry extends Bundle {
    val txid = UInt(txidBits.W)
    val addr = UInt(addrBits.W)
    val resp = Valid(new Response())

    def asResponse: ResponseWithAddr = MakeWireBundle[ResponseWithAddr](
      new ResponseWithAddr,
      _.addr -> addr,
      _.resp -> resp.bits
    )
  }
  object Entry {
    def apply(): Entry = MakeWireBundle[Entry](
      new Entry,
      _.txid -> 0.U,
      _.addr -> 0.U,
      _.resp -> MakeInvalid(new Response)
    )
  }

  // IO

  val io = IO(new Bundle {
    val newTx = Flipped(Decoupled(new NewTx()))
    // We always consume the resp. It is discarded if nothing matches.
    val busResp = Flipped(Valid(new ResponseWithTxid()))
    val commit  = Decoupled(new ResponseWithAddr())
    // Allocator should always have space for what it allocated.
    val freeTxid = Valid(UInt(txidBits.W))
    val flush    = Input(Bool())
  })

  class State extends Bundle {
    val queue      = Vec(capacity, new Entry)
    val nElem      = UInt(ctrWidth.W)
    val nCancelled = UInt(ctrWidth.W)

    def valids = VecInit.tabulate(capacity)(_.U < nElem)

    def trimPrecondition = {
      val noOverflow           = nElem <= capacity.U
      val nCancelledReasonable = nCancelled <= nElem
      val noDuplicateTxid      = !VecInit
        .tabulate(capacity, capacity) { (i, j) =>
          (i != j).B && state.valids(i) && state
            .valids(j) && state.queue(i).txid === state.queue(j).txid
        }
        .exists(x => x.exists(y => y))

      noOverflow && nCancelledReasonable && noDuplicateTxid
    }

    def commonPrecondition = {
      val dontNeedTrim = nCancelled === 0.U || queue(0).resp.valid

      trimPrecondition && dontNeedTrim
    }

    def trySaveResponse(busResp: ResponseWithTxid): (State, Bool) = {
      val founds = VecInit.tabulate(capacity) { i =>
        valids(i) && (busResp.txid === queue(i).txid)
      }
      // Resp cannot match two tx.
      val duplicateTxid = founds.count(x => x) > 1.U
      // Tx cannot get two resp.
      val badResponse = VecInit
        .tabulate(capacity) { i =>
          founds(i) && queue(i).resp.valid
        }
        .exists(x => x)
      val precondition = commonPrecondition && !duplicateTxid && !badResponse

      val accepted = Mux(precondition, founds.exists(x => x), WireDefault(Bool(), DontCare))
      val result   = Mux(
        precondition,
        Mux(
          accepted,
          MakeWireBundle[State](
            new State,
            _                                       -> this,
            _.queue(founds.indexWhere(x => x)).resp -> MakeValid(busResp.resp)
          ),
          this
        ),
        State.unreachable()
      )

      (result, accepted)
    }

    def enq(tx: NewTx): State = {
      val precondition = commonPrecondition && nElem < capacity.U

      val index = nElem(indexWidth - 1, 0)
      Mux(
        precondition,
        MakeWireBundle[State](
          new State,
          _                         -> this,
          _.queue(index).txid       -> tx.txid,
          _.queue(index).addr       -> tx.addr,
          _.queue(index).resp.valid -> false.B,
          // _.queue(index).resp.bits is untouched
          _.nElem -> (nElem + 1.U)
        ),
        State.unreachable()
      )
    }

    def deq(): State = {
      val precondition = commonPrecondition && nElem > 0.U

      Mux(
        precondition,
        MakeWireBundle[State](
          new State,
          _       -> this,
          _.queue -> VecInit.tabulate(capacity) { i =>
            if (i + 1 < capacity)
              Mux((i + 1).U < nElem, queue(i + 1), queue(i))
            else queue(i)
          },
          _.nElem      -> (nElem - 1.U),
          _.nCancelled -> Mux(nCancelled > 0.U, nCancelled - 1.U, 0.U)
        ),
        State.unreachable()
      )
    }

    def flush(): State = {
      Mux(
        commonPrecondition,
        MakeWireBundle[State](
          new State,
          _            -> this,
          _.nCancelled -> nElem
        ),
        State.unreachable()
      )
    }

    def maybeTrim(): State = {
      // From the front, discard all cancelled entries without resp
      val keepCancelled = VecInit.tabulate(capacity) { i =>
        (i.U < nCancelled) && queue(i).resp.valid
      }
      val hasKeep = keepCancelled.exists(x => x)
      val offset  = Mux(hasKeep, keepCancelled.indexWhere(x => x), nCancelled)

      // Note it's not commonPrecondition here
      Mux(
        trimPrecondition,
        MakeWireBundle[State](
          new State,
          _       -> this,
          _.queue -> VecInit.tabulate(capacity) { i =>
            Mux(i.U < nElem - offset, queue(i.U + offset(indexWidth - 1, 0)), queue(i))
          },
          _.nElem      -> (nElem - offset),
          _.nCancelled -> (nCancelled - offset)
        ),
        State.unreachable()
      )
    }
  }
  object State {
    def apply() = MakeWireBundle[State](
      new State,
      _.queue      -> VecInit.fill(capacity)(Entry()),
      _.nElem      -> 0.U,
      _.nCancelled -> 0.U
    )

    def unreachable() = MakeWireBundle[State](
      new State,
      _.queue      -> DontCare,
      _.nElem      -> DontCare,
      _.nCancelled -> DontCare
    )
  }

  val state = RegInit(State())

  // Stage 1, decide what to do with the bus response
  val badResponse = io.busResp.valid && VecInit
    .tabulate(capacity) { i =>
      state.valids(i) && state.queue(i).resp.valid && state.queue(i).txid === io.busResp.bits.txid
    }
    .exists(x => x)
  val s1Precondition = state.commonPrecondition && !badResponse
  assert(s1Precondition)
  val (stateAfterResp, respFound) = state.trySaveResponse(io.busResp.bits)
  // BusResp takes priority here because s1Reject cannot depend on io.flush.
  val s1Reject = io.busResp.valid && !respFound
  val s1State  =
    Mux(s1Precondition, Mux(io.busResp.valid, stateAfterResp, state), State.unreachable())

  // Stage 2, commit a response if we can
  val s2Src = if (flowResponse) s1State else state
  // Prevent io.commit.valid from depending on io.commit.valid
  val s2Valid =
    !s1Reject && s2Src.valids(0) && s2Src.nCancelled === 0.U && s2Src.queue(0).resp.valid
  val s2Commit       = io.commit.fire
  val s2Precondition = s2Src.commonPrecondition && (!s2Commit || s2Valid)
  assert(s2Precondition)
  val s2State = Mux(s2Precondition, Mux(s2Commit, s1State.deq(), s1State), State.unreachable())

  // Stage 3, handle flushing
  val s3Precondition = s2State.commonPrecondition
  assert(s3Precondition)
  val s3State =
    Mux(s3Precondition, Mux(io.flush, s2State.flush().maybeTrim(), s2State), State.unreachable())

  // Stage 4, discard a response if we can
  val s4Discard      = !s1Reject && !s2Commit && s3State.valids(0) && s3State.nCancelled > 0.U
  val s4Precondition = s3State.commonPrecondition && (!s4Discard || s3State.queue(0).resp.valid)
  assert(s4Precondition)
  val s4State =
    Mux(s4Precondition, Mux(s4Discard, s3State.deq().maybeTrim(), s3State), State.unreachable())

  // Stage 5, handle new transaction
  val s5Ready        = !s4State.valids(capacity - 1)
  val s5Fire         = io.newTx.fire
  val s5Precondition = s4State.commonPrecondition && (!s5Fire || s5Ready)
  assert(s5Precondition)
  val s5State =
    Mux(s5Precondition, Mux(s5Fire, s4State.enq(io.newTx.bits), s4State), State.unreachable())

  assert(s5State.commonPrecondition)
  state := s5State

  io.newTx.ready  := s5Ready
  io.commit.valid := s2Valid
  io.commit.bits  := s2Src.queue(0).asResponse
  val freeTxidUsage = VecInit(Seq(s1Reject, s2Commit, s4Discard)).count(x => x)
  assert(freeTxidUsage <= 1.U)
  io.freeTxid := MuxUpTo1H(
    MakeInvalid(0.U(txidBits.W)),
    Seq(
      s1Reject  -> MakeValid(io.busResp.bits.txid),
      s2Commit  -> MakeValid(s2Src.queue(0).txid),
      s4Discard -> MakeValid(s3State.queue(0).txid)
    )
  )
}

// TODO(atv): Privatize this and FetchControl
// Module which is responsible for performing
// memory fetches which are requested by
// `FetchControl`.
class Fetcher(p: Parameters) extends Module {
  val io = IO(new Bundle {
    val ctrl    = Flipped(Irrevocable(UInt(p.fetchAddrBits.W)))
    val flushTx = Input(Bool())
    val fetch   = Decoupled(new FetchResponse(p))
    val ibus    = new IBusIO(p)
  })

  val lsb = log2Ceil(p.fetchDataBits / 8)
  assert((p.fetchDataBits == 128 && lsb == 4) || (p.fetchDataBits == 256 && lsb == 5))

  val maxConcurrentTx = 2
  val txidAllocator   = Module(new IndexAllocatorShifting(maxConcurrentTx))

  // The reorder buffer does not flow the response. This serves as the delay
  // cycle to break the rdata->addr loop.
  // TODO(davidgao): upgrade ibus and move the delay upstream.
  val reorderBuffer = Module(
    new FetchReorderBuffer(
      txidBits = txidAllocator.width,
      addrBits = p.fetchAddrBits,
      dataBits = p.fetchDataBits,
      capacity = maxConcurrentTx,
      flowResponse = false
    )
  )

  val canStartFetch = io.ctrl.valid && reorderBuffer.io.newTx.ready && txidAllocator.io.alloc.valid
  // The fetch request goes through without stopping.
  io.ibus.valid := canStartFetch
  io.ibus.addr  := Cat(io.ctrl.bits(p.fetchAddrBits - 1, lsb), 0.U(lsb.W))

  val ibusAddrFire = io.ibus.fire
  // TODO(davidgao): Add txid to ibus interface
  // io.ibus.txid := txidAllocator.io.alloc.bits
  txidAllocator.io.alloc.ready     := ibusAddrFire
  reorderBuffer.io.newTx.valid     := ibusAddrFire
  reorderBuffer.io.newTx.bits.addr := io.ctrl.bits
  reorderBuffer.io.newTx.bits.txid := txidAllocator.io.alloc.bits
  // TODO(davidgao): remove this adapter when we decouple data from addr on ibus
  reorderBuffer.io.busResp.valid           := RegNext(ibusAddrFire, false.B)
  reorderBuffer.io.busResp.bits.txid       := RegNext(txidAllocator.io.alloc.bits)
  reorderBuffer.io.busResp.bits.resp.data  := io.ibus.rdata
  reorderBuffer.io.busResp.bits.resp.fault := RegNext(io.ibus.fault.valid)
  reorderBuffer.io.commit.ready            := io.fetch.ready
  reorderBuffer.io.flush                   := io.flushTx
  io.ctrl.ready                            := ibusAddrFire

  txidAllocator.io.free.valid := reorderBuffer.io.freeTxid.valid
  txidAllocator.io.free.bits  := reorderBuffer.io.freeTxid.bits

  io.fetch.valid := reorderBuffer.io.commit.valid
  io.fetch.bits  := MakeWireBundle[FetchResponse](
    new FetchResponse(p),
    _.addr  -> reorderBuffer.io.commit.bits.addr,
    _.inst  -> UIntToVec(reorderBuffer.io.commit.bits.resp.data, p.instructionBits),
    _.fault -> reorderBuffer.io.commit.bits.resp.fault
  )
}

class FetchControl(p: Parameters) extends Module {
  val io = IO(new Bundle {
    val fetchFault = Valid(UInt(p.programCounterBits.W))
    val csr        = new CsrInIO(p)
    val iflush     = Input(Valid(UInt(p.programCounterBits.W)))
    val branch     = Input(Valid(UInt(p.fetchAddrBits.W)))
    val fetchData  = Flipped(Decoupled(new FetchResponse(p)))
    val linkPort   = Flipped(new RegfileLinkPortIO(p))

    val fetchAddr     = Irrevocable(UInt(p.fetchAddrBits.W))
    val flushTx       = Output(Bool())
    val bufferRequest = DecoupledVectorIO(new FetchInstruction(p), p.fetchInstrSlots)
  })

  val lsb = log2Ceil(p.fetchDataBits / 8)

  def PredictJump(addr: UInt, inst: UInt): ValidIO[UInt] = {
    assert(p.instructionBits == 32)
    val jal    = inst === BitPat("b????????????????????_?????_1101111")
    val immjal = Cat(Fill(12, inst(31)), inst(19, 12), inst(20), inst(30, 21), 0.U(1.W))
    val bxx    = inst === BitPat("b???????_?????_?????_???_?????_1100011") &&
      inst(31) && inst(14, 13) =/= 1.U
    val immbxx = Cat(Fill(20, inst(31)), inst(7), inst(30, 25), inst(11, 8), 0.U(1.W))
    val immed  = Mux(inst(2), immjal, immbxx)

    val valid  = jal || bxx
    val target = addr + immed

    MakeValid(valid, target)
  }

  def Predecode(fetchResponse: FetchResponse): PredecodeOutput = {
    val addr = fetchResponse.addr
    val lsb  = log2Ceil(p.fetchDataBits / 8)
    assert((p.fetchDataBits == 128 && lsb == 4) || (p.fetchDataBits == 256 && lsb == 5))
    val baseAddr  = addr(p.fetchAddrBits - 1, lsb)
    val startElem = addr(lsb - 1, lsb - log2Ceil(p.fetchInstrSlots))

    val insts = ShiftVectorRight(fetchResponse.inst, startElem)
    val addrs = VecInit.tabulate(p.fetchInstrSlots)(i => addr + (i * 4).U)

    val branchTargets = VecInit.tabulate(p.fetchInstrSlots)(i => PredictJump(addrs(i), insts(i)))

    val validsIn = VecInit.tabulate(p.fetchInstrSlots)(i => i.U < p.fetchInstrSlots.U - startElem)
    val jumped   = VecInit.tabulate(p.fetchInstrSlots)(i => validsIn(i) && branchTargets(i).valid)
    val firstJumpOH = VecInit(PriorityEncoderOH(jumped))

    // Have we jumped before the instruction i
    val hasJumpedBefore = VecInit(jumped.scan(false.B)(_ || _).take(p.fetchInstrSlots))

    val validsOut = VecInit.tabulate(p.fetchInstrSlots)(i => validsIn(i) && !hasJumpedBefore(i))

    val nextFetchPc = MuxUpTo1H(
      Cat(baseAddr + 1.U, 0.U(lsb.W)),
      (0 until p.fetchInstrSlots).map(i => firstJumpOH(i) -> branchTargets(i).bits)
    )

    val result = MakeWireBundle[PredecodeOutput](
      new PredecodeOutput(p),
      _.insts -> VecInit.tabulate(p.fetchInstrSlots)(i =>
        MakeWireBundle[FetchInstruction](
          new FetchInstruction(p),
          _.addr    -> addrs(i),
          _.inst    -> insts(i),
          _.brchFwd -> jumped(i)
        )
      ),
      _.count     -> validsOut.count(x => x),
      _.nextPc    -> nextFetchPc,
      _.hasJumped -> jumped.reduce(_ || _)
    )

    result
  }

  val predecode = Predecode(io.fetchData.bits)

  io.bufferRequest.bits := predecode.insts

  val pastBranchOrFlush    = RegInit(false.B)
  val currentBranchOrFlush = io.iflush.valid || io.branch.valid
  val ongoingBranchOrFlush = pastBranchOrFlush || currentBranchOrFlush

  // If we have faulted we should stop making any new attempts until a branch resolves it.
  val faulted         = RegInit(false.B)
  val fetchFaultValid = (faulted || (io.fetchData.valid && io.fetchData.bits.fault)) &&
    !io.branch.valid
  io.fetchFault := MakeValid(fetchFaultValid, io.fetchData.bits.addr)
  faulted       := fetchFaultValid

  val sufficientBuffer = io.bufferRequest.nReady >= predecode.count
  io.fetchData.ready := sufficientBuffer || fetchFaultValid
  // Send out results. All branch or flush, current or past, will make us
  // discard results.
  // TODO(davidgao): ForceZero it when invalid?
  val writeToBuffer = io.fetchData.fire && !fetchFaultValid && !ongoingBranchOrFlush
  val nValid        = Mux(writeToBuffer, predecode.count, 0.U)
  io.bufferRequest.nValid := nValid

  val ongoingFetch = RegInit(MakeInvalid(UInt(p.fetchAddrBits.W)))

  // PC is initialized with the CSR value below upon leaving reset.
  val pc = RegInit(MakeInvalid(UInt(32.W)))

  // Past branch or flush doesn't block us from initiating new fetches.
  val blockNewFetch = !pc.valid || // We're stil in reset.
    currentBranchOrFlush ||
    ongoingFetch.valid ||
    fetchFaultValid

  val pcFetched = RegInit(false.B)
  pcFetched := MuxCase(
    pcFetched,
    Seq(
      (!pc.valid)                            -> !blockNewFetch, // We're leaving reset.
      (io.iflush.valid || io.branch.valid)   -> false.B,
      (writeToBuffer && predecode.hasJumped) -> !blockNewFetch,
      // Speculative fetch
      (!blockNewFetch) -> true.B
    )
  )
  val pcNext = MuxCase(
    pc.bits,
    Seq(
      (!pc.valid)     -> Cat(io.csr.value(0)(31, 2), 0.U(2.W)), // We're leaving reset.
      io.iflush.valid -> io.iflush.bits,
      io.branch.valid -> io.branch.bits,
      (writeToBuffer && predecode.hasJumped) -> predecode.nextPc,
      // Speculative fetch
      (!blockNewFetch && pcFetched) -> Cat(pc.bits(31, lsb) + 1.U, 0.U(lsb.W))
    )
  )
  // PC will always be valid as soon as we leave reset.
  pc := MakeValid(pcNext)

  val fetch = MuxUpTo1H(
    MakeInvalid(UInt(p.fetchAddrBits.W)),
    Seq(
      ongoingFetch.valid -> ongoingFetch,
      !blockNewFetch     -> MakeValid(pcNext)
    )
  )
  ongoingFetch := Mux(io.fetchAddr.ready, MakeInvalid(UInt(p.fetchAddrBits.W)), fetch)

  // All branch or flush are cleared once we're able to initiate a new fetch.
  val newFetchInitiated = fetch.valid && !ongoingFetch.valid
  pastBranchOrFlush := ongoingBranchOrFlush && !newFetchInitiated

  // Similarly, whenever we write a fetched jump, we need to flush until we initiate a new fetch
  val newJump     = writeToBuffer && predecode.hasJumped
  val pendingJump = RegInit(false.B)
  pendingJump := (pendingJump || newJump) && !newFetchInitiated

  io.fetchAddr <> MakeIrrevocable(fetch)
  io.flushTx := ongoingBranchOrFlush || pendingJump || newJump
}

class UncachedFetch(p: Parameters) extends FetchUnit(p) {
  // TODO(derekjchow): Make Bru use valid interface
  val branch = MuxCase(
    MakeInvalid(UInt(p.fetchAddrBits.W)),
    (0 until p.instructionLanes).map(i => io.branch(i).valid -> MakeValid(io.branch(i).value))
  )

  val ctrl = Module(new FetchControl(p))
  ctrl.io.csr <> io.csr
  ctrl.io.branch := branch
  val debug_iflush = Seq(
    io.debug_pc.valid -> MakeValid(io.debug_pc.bits)
  )
  ctrl.io.iflush := MuxCase(
    MakeInvalid(UInt(p.fetchAddrBits.W)),
    Seq(
      io.iflush.valid -> MakeValid(io.iflush.pcNext)
    ) ++ debug_iflush
  )
  ctrl.io.linkPort := io.linkPort
  // TODO(derekjchow): Maybe do something with back pressure?
  io.iflush.ready := true.B

  val fetcher = Module(new Fetcher(p))
  fetcher.io.ctrl <> ctrl.io.fetchAddr
  fetcher.io.flushTx := ctrl.io.flushTx
  ctrl.io.fetchData <> fetcher.io.fetch
  fetcher.io.ibus <> io.ibus

  val window            = p.fetchInstrSlots * 2
  val instructionBuffer = Module(
    new InstructionBuffer(new FetchInstruction(p), p.fetchInstrSlots, window)
  )
  instructionBuffer.io.feedIn <> ctrl.io.bufferRequest
  io.inst.lanes <> instructionBuffer.io.out.take(p.instructionLanes)
  instructionBuffer.io.out.drop(p.instructionLanes).foreach(_.ready := false.B)
  instructionBuffer.io.flush := io.iflush.valid || branch.valid || io.debug_pc.valid

  val pc = RegInit(0.U(p.fetchAddrBits.W))
  pc       := Mux(instructionBuffer.io.out(0).valid, instructionBuffer.io.out(0).bits.addr, pc)
  io.pc    := pc
  io.fault := ctrl.io.fetchFault
}
