// Copyright 2023 Google LLC
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


// Scalar Core Frontend
package coralnpu

import chisel3._
import chisel3.util._
import common._
import coralnpu.float.{FloatCore}
import coralnpu.rvv.{RvvCoreIO}
import _root_.circt.stage.ChiselStage

object SCore {
  def apply(p: Parameters): SCore = {
    return Module(new SCore(p))
  }
}

class SCore(p: Parameters) extends Module {
  val io = IO(new Bundle {
    val csr = new CsrInOutIO(p)
    val halted = Output(Bool())
    val fault = Output(Bool())
    val wfi = Output(Bool())
    val irq = Input(Bool())
    val dm = new CoreDMIO(p)
    val timer_irq = Input(Bool())
    val software_irq = Input(Bool())

    val ibus = new IBusIO(p)
    val dbus = new DBusIO(p)
    val ebus = new EBusIO(p)

    val rvvcore = Option.when(p.enableRvv)(Flipped(new RvvCoreIO(p)))

    val iflush = new IFlushIO(p)
    val dflush = new DFlushIO(p)

    val debug = new DebugIO(p)
  })

  // The functional units that make up the core.
  val regfile = Regfile(p)
  val fetch = if (p.enableFetchL0) { Fetch(p) } else { Module(new UncachedFetch(p)) }

  val csr = Csr(p)
  val dispatch = Module(new DispatchV2(p))

  val lsu = Lsu(p)
  val fault_manager = Module(new FaultManager(p))
  val retirement_buffer = Module(new RetirementBuffer(p, mini = !p.useRetirementBuffer))
  val rob_io = retirement_buffer.io

  rob_io.inst := dispatch.io.inst
  rob_io.jump := dispatch.io.jump
  rob_io.branch := dispatch.io.branch
  rob_io.writeAddrScalar := dispatch.io.rdMark
  (0 until p.instructionLanes + 2).foreach(i => {
    rob_io.writeDataScalar(i) := regfile.io.writeData(i)
  })
  dispatch.io.retirement_buffer_nSpace := rob_io.nSpace
  dispatch.io.retirement_buffer_empty := rob_io.empty
  dispatch.io.retirement_buffer_trap_pending := rob_io.trapPending
  if (p.enableRvv) {
    rob_io.writeAddrVector.get := dispatch.io.rvvRdMark.get
    (0 until p.instructionLanes).foreach(i => {
      rob_io.writeDataVector.get(i).valid := io.rvvcore.get.rd_rob2rt_o(i).valid
      rob_io.writeDataVector.get(i).bits.addr := io.rvvcore.get.rd_rob2rt_o(i).w_index
      rob_io.writeDataVector.get(i).bits.data := io.rvvcore.get.rd_rob2rt_o(i).w_data
      rob_io.writeDataVector.get(i).bits.uop_pc := io.rvvcore.get.rd_rob2rt_o(i).uop_pc
      rob_io.writeDataVector.get(i).bits.last_uop_valid := io.rvvcore.get.rd_rob2rt_o(i).last_uop_valid
    })
  }
  rob_io.fault := fault_manager.io.out
  rob_io.storeComplete := lsu.io.storeComplete

  dispatch.io.single_step := csr.io.dm.single_step || csr.io.dm.dcsr_step
  dispatch.io.debug_mode := csr.io.dm.debug_mode
  fetch.io.debug_pc := csr.io.dm.debug_pc

  val alu = Seq.fill(p.instructionLanes)(Alu(p))
  val bru = (0 until p.instructionLanes).map(x => Seq(Bru(p, x == 0))).reduce(_ ++ _)
  val mlu = Mlu(p)
  val dvu = Dvu(p)

  // Wire up the core.
  val branchTaken = bru.map(x => x.io.taken.valid).reduce(_||_)

  // ---------------------------------------------------------------------------
  // Flush logic
  io.dflush.valid := lsu.io.flush.valid && !lsu.io.flush.fencei
  io.dflush.all   := lsu.io.flush.all
  io.dflush.clean := lsu.io.flush.clean

  io.iflush.valid  := lsu.io.flush.valid && lsu.io.flush.fencei
  io.iflush.pcNext := lsu.io.flush.pcNext
  fetch.io.iflush.valid := lsu.io.flush.valid && lsu.io.flush.fencei
  fetch.io.iflush.pcNext := lsu.io.flush.pcNext

  lsu.io.flush.ready := lsu.io.flush.valid &&
      Mux(lsu.io.flush.fencei, fetch.io.iflush.ready, io.dflush.ready)

  // ---------------------------------------------------------------------------
  // Fetch
  fetch.io.csr := io.csr.in

  for (i <- 0 until p.instructionLanes) {
    fetch.io.branch(i) := bru(i).io.taken
  }

  fetch.io.linkPort := regfile.io.linkPort

  // ---------------------------------------------------------------------------
  // Decode
  // Decode/Dispatch
  dispatch.io.inst <> fetch.io.inst.lanes
  dispatch.io.halted := csr.io.halted || csr.io.wfi || csr.io.dm.debug_mode
  dispatch.io.mactive := false.B
  dispatch.io.lsuActive := lsu.io.active
  dispatch.io.lsuQueueCapacity := lsu.io.queueCapacity
  dispatch.io.scoreboard.comb := regfile.io.scoreboard.comb
  dispatch.io.scoreboard.regd := regfile.io.scoreboard.regd
  dispatch.io.branchTaken := branchTaken
  dispatch.io.interlock := bru(0).io.interlock.get || lsu.io.flush.valid

  // Connect fault signaling to FaultManager.
  for (i <- 0 until p.instructionLanes) {
    fault_manager.io.in.fault(i).csr := dispatch.io.csrFault(i)
    fault_manager.io.in.fault(i).jal := dispatch.io.jalFault(i)
    fault_manager.io.in.fault(i).jalr := dispatch.io.jalrFault(i)
    fault_manager.io.in.fault(i).bxx := dispatch.io.bxxFault(i)
    fault_manager.io.in.fault(i).undef := dispatch.io.undefFault(i)
    if (p.enableRvv) {
      fault_manager.io.in.fault(i).rvv.get := dispatch.io.rvvFault.get(i)
    }
    fault_manager.io.in.pc(i).pc := fetch.io.inst.lanes(i).bits.addr
    fault_manager.io.in.jalr(i).target := regfile.io.target(i).data
    fault_manager.io.in.undef(i).inst := fetch.io.inst.lanes(i).bits.inst
    fault_manager.io.in.jal(i).target := dispatch.io.bruTarget(i)
  }
  fault_manager.io.in.memory_fault := lsu.io.fault
  if (p.enableRvv) {
    fault_manager.io.in.rvv_fault.get.valid := io.rvvcore.get.trap.valid
    fault_manager.io.in.rvv_fault.get.bits.mepc := io.rvvcore.get.trap.bits.pc
    fault_manager.io.in.rvv_fault.get.bits.mcause := 2.U(32.W)
    fault_manager.io.in.rvv_fault.get.bits.mtval :=
        io.rvvcore.get.trap.bits.originalEncoding()
    fault_manager.io.in.rvv_fault.get.bits.decode := false.B
  }
  bru(0).io.fault_manager.get := fault_manager.io.out

  // ---------------------------------------------------------------------------
  // ALU
  for (i <- 0 until p.instructionLanes) {
    alu(i).io.req := dispatch.io.alu(i)
    alu(i).io.rs1 := regfile.io.readData(2 * i + 0)
    alu(i).io.rs2 := regfile.io.readData(2 * i + 1)
  }

  // ---------------------------------------------------------------------------
  // Branch Unit
  for (i <- 0 until p.instructionLanes) {
    bru(i).io.req := dispatch.io.bru(i)
    bru(i).io.rs1 := regfile.io.readData(2 * i + 0)
    bru(i).io.rs2 := regfile.io.readData(2 * i + 1)
    bru(i).io.target := regfile.io.target(i)
    dispatch.io.jalrTarget(i) := regfile.io.target(i)
    rob_io.targets(i) := dispatch.io.bruTarget(i)
    rob_io.jalrTargets(i) := regfile.io.target(i).data
  }

  bru(0).io.csr.get <> csr.io.bru

  // Instruction counters
  csr.io.counters.nRetired := rob_io.nRetired

  // ---------------------------------------------------------------------------
  // Control Status Unit
  csr.io.csr <> io.csr
  csr.io.csr.in.value(12) := fetch.io.pc

  // Arbitrate requests from Dispatch and DM
  val csrReqArbiter = Module(new Arbiter(new CsrCmd, 2))
  csrReqArbiter.io.in(0).bits := dispatch.io.csr.bits
  csrReqArbiter.io.in(0).valid := dispatch.io.csr.valid
  csrReqArbiter.io.in(1).valid := io.dm.csr.valid
  csrReqArbiter.io.in(1).bits := io.dm.csr.bits
  csrReqArbiter.io.out.ready := true.B
  csr.io.req.bits := csrReqArbiter.io.out.bits
  csr.io.req.valid := csrReqArbiter.io.out.valid

  val dmRs1 = Wire(new RegfileReadDataIO)
  dmRs1.valid := true.B
  dmRs1.data := io.dm.csr_rs1
  csr.io.rs1 := Mux(RegNext(dispatch.io.csr.valid, false.B), regfile.io.readData(0), dmRs1)
  io.dm.csr_rd := MakeValid(csr.io.rd.valid, csr.io.rd.bits.data)
  val bruTaken = bru(0).io.actually_taken
  val realTarget = bru(0).io.real_target
  // In single-step mode, we break *before* the instruction at `dispatch.io.inst(0).bits.addr`
  // executes. Therefore, `nextInstPC` should point to this address so that upon resumption,
  // this instruction is executed.
  val nextInstPC = Mux(bruTaken, realTarget, dispatch.io.inst(0).bits.addr)

  csr.io.dm.current_pc := dispatch.io.inst(0).bits.addr
  csr.io.dm.next_pc := nextInstPC

  val stepTriggered = (!csr.io.dm.debug_mode && csr.io.dm.dcsr_step && dispatch.io.inst(0).fire)
  val stepTriggeredReg = RegNext(stepTriggered, false.B)
  csr.io.dm.debug_req := io.dm.debug_req || /* Request from external debugger */
                             stepTriggeredReg /* Single-step via CSR */
  csr.io.dm.resume_req := io.dm.resume_req
  io.dm.debug_mode := csr.io.dm.debug_mode

  // ---------------------------------------------------------------------------
  // Status
  io.halted := csr.io.halted
  io.fault  := csr.io.fault
  io.wfi    := csr.io.wfi
  csr.io.irq := io.irq
  csr.io.timer_irq := io.timer_irq
  csr.io.software_irq := io.software_irq

  // ---------------------------------------------------------------------------
  // Load/Store Unit
  lsu.io.busPort := regfile.io.busPort
  lsu.io.req <> dispatch.io.lsu
  if (p.enableRvv) {
    lsu.io.rvvState.get := io.rvvcore.get.configState
    lsu.io.lsu2rvv.get <> io.rvvcore.get.lsu2rvv
    io.rvvcore.get.rvv2lsu <> lsu.io.rvv2lsu.get
  }

  // ---------------------------------------------------------------------------
  // Multiplier Unit
  for (i <- 0 until p.instructionLanes) {
    mlu.io.req(i) <> dispatch.io.mlu(i)
    mlu.io.rs1(i) := regfile.io.readData(2 * i)
    mlu.io.rs2(i) := regfile.io.readData((2 * i) + 1)
  }

  // ---------------------------------------------------------------------------
  // Divide Unit
  dvu.io.req <> dispatch.io.dvu(0)
  dvu.io.rs1 := regfile.io.readData(0)
  dvu.io.rs2 := regfile.io.readData(1)
  dvu.io.rd.ready := !mlu.io.rd.valid

  // TODO: make port conditional on pipeline index.
  for (i <- 1 until p.instructionLanes) {
    dispatch.io.dvu(i).ready := false.B
  }

  // ---------------------------------------------------------------------------
  // Register File
  for (i <- 0 until p.instructionLanes) {
    regfile.io.readAddr(2 * i + 0) := dispatch.io.rs1Read(i)
    regfile.io.readAddr(2 * i + 1) := dispatch.io.rs2Read(i)
    regfile.io.readSet(2 * i + 0) := dispatch.io.rs1Set(i)
    regfile.io.readSet(2 * i + 1) := dispatch.io.rs2Set(i)
    regfile.io.writeAddr(i) := dispatch.io.rdMark(i)
    regfile.io.busAddr(i) := dispatch.io.busRead(i)

    regfile.io.debugBusPort <> io.dm.scalar_rs

    val csr0Valid = if (i == 0) csr.io.rd.valid else false.B
    val csr0Addr  = if (i == 0) csr.io.rd.bits.addr else 0.U
    val csr0Data  = if (i == 0) csr.io.rd.bits.data else 0.U

    val rvvCoreRdValid = io.rvvcore.map(_.rd(i).valid).getOrElse(false.B)
    val rvvCoreRdAddr = MuxOR(
        rvvCoreRdValid, io.rvvcore.map(_.rd(i).bits.addr).getOrElse(0.U))
    val rvvCoreRdData = MuxOR(
        rvvCoreRdValid, io.rvvcore.map(_.rd(i).bits.data).getOrElse(0.U))

    regfile.io.writeData(i).valid := csr0Valid ||
                                     alu(i).io.rd.valid || bru(i).io.rd.valid ||
                                     rvvCoreRdValid

    regfile.io.writeData(i).bits.addr :=
        MuxOR(csr0Valid, csr0Addr) |
        MuxOR(alu(i).io.rd.valid, alu(i).io.rd.bits.addr) |
        MuxOR(bru(i).io.rd.valid, bru(i).io.rd.bits.addr) |
        rvvCoreRdAddr

    regfile.io.writeData(i).bits.data :=
        MuxOR(csr0Valid, csr0Data) |
        MuxOR(alu(i).io.rd.valid, alu(i).io.rd.bits.data) |
        MuxOR(bru(i).io.rd.valid, bru(i).io.rd.bits.data) |
        rvvCoreRdData

    if (p.enableRvv) {
      assert((csr0Valid +&
              alu(i).io.rd.valid +& bru(i).io.rd.valid +&
              io.rvvcore.get.rd(i).valid) <= 1.U)
    } else {
      assert((csr0Valid +&
             alu(i).io.rd.valid +& bru(i).io.rd.valid) <= 1.U)
    }
  }

  // RV32F extension
  val floatCore = Option.when(p.enableFloat)(FloatCore(p))
  val floatReadPorts = 3
  val floatWritePorts = 2
  val fRegfile = Option.when(p.enableFloat)(Module(new FRegfile(p, floatReadPorts, floatWritePorts)))
  if (p.enableFloat) {
    lsu.io.busPort_flt.get := fRegfile.get.io.busPort
    fRegfile.get.io.busPortAddr := dispatch.io.fbusPortAddr.get
    fRegfile.get.io.scoreboard_set :=
      MuxOR(dispatch.io.rdMark_flt.get.valid, UIntToOH(dispatch.io.rdMark_flt.get.addr))
    // Mux input to read port 0
    fRegfile.get.io.read_ports(0).valid := MuxCase(false.B, Seq(
      io.dm.float_rs.get.valid -> true.B,
      floatCore.get.io.read_ports(0).valid -> true.B,
      dispatch.io.frs1Read.get(0).valid -> true.B,
    ))
    fRegfile.get.io.read_ports(0).addr := MuxCase(0.U, Seq(
      io.dm.float_rs.get.valid -> io.dm.float_rs.get.addr,
      floatCore.get.io.read_ports(0).valid -> floatCore.get.io.read_ports(0).addr,
      dispatch.io.frs1Read.get(0).valid -> dispatch.io.frs1Read.get(0).addr,
    ))
    floatCore.get.io.read_ports(0).data := fRegfile.get.io.read_ports(0).data

    // Connect read ports 1 and 2 to floatCore
    for (j <- 1 until 3) {
      fRegfile.get.io.read_ports(j).valid := floatCore.get.io.read_ports(j).valid
      fRegfile.get.io.read_ports(j).addr := floatCore.get.io.read_ports(j).addr
      floatCore.get.io.read_ports(j).data := fRegfile.get.io.read_ports(j).data
    }

    // Broadcast data back from read port 0 to debug interface
    io.dm.float_rs.get.data := fRegfile.get.io.read_ports(0).data

    // Mux input to write port
    fRegfile.get.io.write_ports(0).valid := MuxCase(false.B, Seq(
      io.dm.float_rd.get.valid -> true.B,
      floatCore.get.io.write_ports(0).valid -> true.B,
    ))
    fRegfile.get.io.write_ports(0).addr := MuxCase(0.U, Seq(
      io.dm.float_rd.get.valid -> io.dm.float_rd.get.addr,
      floatCore.get.io.write_ports(0).valid -> floatCore.get.io.write_ports(0).addr,
    ))
    fRegfile.get.io.write_ports(0).data := MuxCase(Fp32.Zero(false.B), Seq(
      io.dm.float_rd.get.valid -> io.dm.float_rd.get.data,
      floatCore.get.io.write_ports(0).valid -> floatCore.get.io.write_ports(0).data,
    ))
    fRegfile.get.io.dm_write_valid := io.dm.float_rd.get.valid

    // Route RVV async FP writeback (vfmv.f.s) through fRegfile write port 1.
    // The LSU FP-load (floatCore.write_ports(1)) takes priority; async_frd
    // uses the port only when LSU isn't writing. The scoreboard is pre-marked
    // via rdMark_flt (see Decode.scala), so clearing on this write doesn't
    // trip FRegfile's scoreboard_error assertion.
    // Port 1: Arbitrate between LSU FP-load and RVV async writeback.
    // LSU takes priority; RVV is stalled if LSU is writing.
    val lsuWriting = floatCore.get.io.write_ports(1).valid
    if (p.enableRvv) {
      val asyncFrd = io.rvvcore.get.async_frd
      asyncFrd.ready := !lsuWriting
      fRegfile.get.io.write_ports(1).valid := lsuWriting || asyncFrd.valid
      fRegfile.get.io.write_ports(1).addr := Mux(lsuWriting,
        floatCore.get.io.write_ports(1).addr,
        asyncFrd.bits.addr)
      fRegfile.get.io.write_ports(1).data := Mux(lsuWriting,
        floatCore.get.io.write_ports(1).data,
        Fp32.fromWord(asyncFrd.bits.data))
    } else {
      fRegfile.get.io.write_ports(1) := floatCore.get.io.write_ports(1)
    }

    floatCore.get.io.inst <> dispatch.io.float.get
    dispatch.io.fscoreboard.get := fRegfile.get.io.scoreboard
    dispatch.io.csrFrm.get := csr.io.float.get.out.frm
    floatCore.get.io.csr <> csr.io.float.get
    floatCore.get.io.rs1 := regfile.io.readData(0)
    floatCore.get.io.rs2 := regfile.io.readData(1)

    floatCore.get.io.lsu_rd.valid := lsu.io.rd_flt.valid
    floatCore.get.io.lsu_rd.bits.addr := lsu.io.rd_flt.bits.addr
    floatCore.get.io.lsu_rd.bits.data := lsu.io.rd_flt.bits.data

    rob_io.writeAddrFloat.get := dispatch.io.rdMark_flt.get
    (0 until 2).foreach(i => {
      rob_io.writeDataFloat.get(i).valid := fRegfile.get.io.write_ports(i).valid
      rob_io.writeDataFloat.get(i).bits.addr := fRegfile.get.io.write_ports(i).addr
      rob_io.writeDataFloat.get(i).bits.data := fRegfile.get.io.write_ports(i).data.asWord
    })
  }

  val mluDvuOffset = p.instructionLanes
  val mluDvuInputs = Seq(mlu.io.rd, dvu.io.rd) ++
                     io.rvvcore.map(x => Seq(x.async_rd)).getOrElse(Seq()) ++
                     floatCore.map(x => Seq(x.io.scalar_rd)).getOrElse(Seq()) ++
                     Seq(io.dm.scalar_rd)

  val arb = Module(new Arbiter(new RegfileWriteDataIO, mluDvuInputs.length))
  arb.io.in <> mluDvuInputs
  arb.io.out.ready := true.B
  regfile.io.writeData(mluDvuOffset).valid := arb.io.out.valid
  regfile.io.writeData(mluDvuOffset).bits.addr := arb.io.out.bits.addr
  regfile.io.writeData(mluDvuOffset).bits.data := arb.io.out.bits.data
  // MLU/DVU port is never masked
  regfile.io.writeMask(p.instructionLanes).valid := false.B

  val lsuOffset = p.instructionLanes + 1
  regfile.io.writeData(lsuOffset).valid := lsu.io.rd.valid
  regfile.io.writeData(lsuOffset).bits.addr  := lsu.io.rd.bits.addr
  regfile.io.writeData(lsuOffset).bits.data  := lsu.io.rd.bits.data
  regfile.io.writeMask(lsuOffset).valid := lsu.io.fault.valid

  val writeMask = bru.map(_.io.taken.valid).scan(false.B)(_||_)
  for (i <- 0 until p.instructionLanes) {
    regfile.io.writeMask(i).valid := writeMask(i)
  }
  regfile.io.debugWriteValid := io.dm.scalar_rd.valid

  // ---------------------------------------------------------------------------
  // Rvv Extension
  if (p.enableRvv) {
    // Connect dispatch
    dispatch.io.rvv.get <> io.rvvcore.get.inst
    dispatch.io.rvvState.get := io.rvvcore.get.configState
    dispatch.io.rvvIdle.get := io.rvvcore.get.rvv_idle
    dispatch.io.rvvQueueCapacity.get := io.rvvcore.get.queue_capacity

    // Register inputs
    io.rvvcore.get.rs := regfile.io.readData
    // Floating point register inputs. Stub-off if unused.
    if (p.enableFloat) {
      // The RVV front-end expects scalar operands to arrive one cycle after
      // dispatch (registered), similar to how the integer regfile's readData
      // ports work.
      val rvvFrsReg = Reg(Vec(p.instructionLanes, UInt(32.W)))
      for (i <- 0 until p.instructionLanes) {
        // We use read_ports(0) for all lanes because scalar float operands
        // are currently restricted to slot 0.
        rvvFrsReg(i) :=
          Mux(dispatch.io.frs1Read.get(i).valid, fRegfile.get.io.read_ports(0).data.asWord, rvvFrsReg(i))
        io.rvvcore.get.frs(i) := rvvFrsReg(i)
      }
    } else {
      for (i <- 0 until p.instructionLanes) {
        io.rvvcore.get.frs(i) := 0.U
      }
    }

    io.rvvcore.get.csr.vstart_write <> csr.io.rvv.get.vstart_write
    io.rvvcore.get.csr.vxrm_write <> csr.io.rvv.get.vxrm_write
    io.rvvcore.get.csr.vxsat_write <> csr.io.rvv.get.vxsat_write
    io.rvvcore.get.csr.frm := csr.io.rvv.get.frm
    csr.io.rvv.get.vstart := io.rvvcore.get.csr.vstart
    csr.io.rvv.get.vl := io.rvvcore.get.configState.bits.vl
    csr.io.rvv.get.vtype := io.rvvcore.get.configState.bits.vtype
    csr.io.rvv.get.vxrm := io.rvvcore.get.csr.vxrm
    csr.io.rvv.get.vxsat := io.rvvcore.get.csr.vxsat
  }
  val isBranching = bru.map(_.io.taken.valid).reduce(_||_)
  val hasFetchedInstructions = fetch.io.inst.lanes.map(_.valid).reduce(_||_)
  val floatIdle = if (p.enableFloat) {fRegfile.get.io.scoreboard === 0.U} else {true.B}
  val rvvIdle = if (p.enableRvv) {io.rvvcore.get.rvv_idle} else {true.B}
  // Scalar and float arithmetics don't actually trap, we're just trying to be precise here.
  val fetchFaultValid = fetch.io.fault.valid &&
      !isBranching &&  // Branches and jumps
      (regfile.io.scoreboard.regd === 0.U) &&  // Pending scalar operation
      floatIdle &&  // Pending float operation
      rvvIdle &&  // Could have vill
      !lsu.io.active &&  // Could fault
      !hasFetchedInstructions
  fault_manager.io.in.fetchFault := MakeValid(fetchFaultValid, fetch.io.fault.bits)

  // ---------------------------------------------------------------------------
  // Fetch Bus
  // Mux valid
  io.ibus.valid := Mux(lsu.io.ibus.valid, lsu.io.ibus.valid, fetch.io.ibus.valid)
  // Mux addr
  io.ibus.addr := Mux(lsu.io.ibus.valid, lsu.io.ibus.addr, fetch.io.ibus.addr)
  // Arbitrate ready
  lsu.io.ibus.ready := Mux(lsu.io.ibus.valid, io.ibus.ready, false.B)
  fetch.io.ibus.ready := Mux(lsu.io.ibus.valid, false.B, io.ibus.ready)
  // Arbitrate error
  fetch.io.ibus.fault := Mux(lsu.io.ibus.valid, MakeInvalid(new FaultInfo(p)), io.ibus.fault)
  // Broadcast rdata
  lsu.io.ibus.rdata := io.ibus.rdata
  fetch.io.ibus.rdata := io.ibus.rdata

  // Tie-off ibus faults in lsu (unused)
  lsu.io.ibus.fault := MakeInvalid(new FaultInfo(p))

  // ---------------------------------------------------------------------------
  // Local Data Bus Port
  io.dbus <> lsu.io.dbus
  io.ebus <> lsu.io.ebus

  // ---------------------------------------------------------------------------
  // DEBUG
  io.debug.cycles := csr.io.csr.out.value(4)

  val debugEn = RegInit(0.U(p.instructionLanes.W))
  val debugAddr = RegInit(VecInit.fill(p.instructionLanes)(0.U(32.W)))
  val debugInst = RegInit(VecInit.fill(p.instructionLanes)(0.U(32.W)))

  val debugBrch = Cat(bru.map(_.io.taken.valid).scanRight(false.B)(_ || _))

  debugEn := Cat(fetch.io.inst.lanes.map(x => x.valid && x.ready && !branchTaken))

  for (i <- 0 until p.instructionLanes) {
    debugAddr(i) := Mux(debugEn(i), fetch.io.inst.lanes(i).bits.addr, debugAddr(i))
    debugInst(i) := Mux(debugEn(i), fetch.io.inst.lanes(i).bits.inst, debugInst(i))
  }

  io.debug.en := debugEn & ~debugBrch

  io.debug.addr <> debugAddr
  io.debug.inst <> debugInst

  io.debug.dbus.valid := io.dbus.valid
  io.debug.dbus.bits.addr := io.dbus.addr
  io.debug.dbus.bits.wdata := io.dbus.wdata
  io.debug.dbus.bits.write := io.dbus.write

  for (i <- 0 until p.instructionLanes) {
    io.debug.dispatch(i).instFire := dispatch.io.inst(i).fire
    io.debug.dispatch(i).instAddr := dispatch.io.inst(i).bits.addr
    io.debug.dispatch(i).instInst := dispatch.io.inst(i).bits.inst
  }

  for (i <- 0 until p.instructionLanes) {
    io.debug.regfile.writeAddr(i).valid := regfile.io.writeAddr(i).valid
    io.debug.regfile.writeAddr(i).bits := regfile.io.writeAddr(i).addr
  }

  for (i <- 0 until p.instructionLanes + 2) {
    io.debug.regfile.writeData(i) := regfile.io.writeData(i)
  }

  if (p.enableFloat) {
    io.debug.float.get.writeAddr.valid := dispatch.io.rdMark_flt.get.valid
    io.debug.float.get.writeAddr.bits := dispatch.io.rdMark_flt.get.addr
    for (i <- 0 until 2) {
      io.debug.float.get.writeData(i).valid := fRegfile.get.io.write_ports(i).valid
      io.debug.float.get.writeData(i).bits.addr := fRegfile.get.io.write_ports(i).addr
      io.debug.float.get.writeData(i).bits.data := fRegfile.get.io.write_ports(i).data.asWord
    }
  }

  io.debug.rb := rob_io.debug
  if (p.useRetirementBuffer) {
    val rvvi = Module(new RvviTrace(p))
    rvvi.io.rb := rob_io.debug
    rvvi.io.csr := csr.io.trace
  }
}

object EmitSCore extends App {
  val p = new Parameters
  ChiselStage.emitSystemVerilogFile(new SCore(p), args)
}
