# Integrating a New IP (CNN / MatMul / SIMD) into Coral NPU

**Audience:** engineers on the NTU_coralnpu team.
**Goal:** tell you exactly *which files to change* and *how*, with copy-pasteable code, to bolt a new compute IP — a CNN engine, a MatMul/GEMM accelerator, a custom vector/tensor instruction, or a small SIMD ALU op — onto the Coral NPU SoC.

---

## 1. Overview & decision guide

Coral NPU is an **RV32IMF scalar core + RVV (`Zve32x`) vector unit**. The scalar core and SoC are written in **Chisel**; the RVV backend is a **hand-written SystemVerilog** unit attached to the scalar core as a Chisel `BlackBox`. **There is no matrix engine** — today all matrix/GEMM math is *software* running on the vector unit. The SoC itself is **data-driven**: the whole chip is assembled from two config files (`CrossbarConfig.scala` + `SoCChiselConfig.scala`), and even the CPU is just another bus host named `coralnpu_core`.

There are three ways to attach a new IP, from loosest to tightest coupling:

| Path | What it is | Coupling | Best for |
|------|-----------|----------|----------|
| **A. Bus device (MMIO + DMA)** | A TileLink-UL device with CSR slave + DMA master. Core kicks it and polls. | Loose | **CNN / MatMul / GEMM engines** — large, own dataflow/memory, possibly own clock. *(Recommended default.)* |
| **B. Custom RVV instruction / RVV backend** | New OP-V opcode routed to a new EX unit, or scale existing SIMD lanes/VLEN. | Tight | MatMul/MAC array *inside* the vector unit; SIMD widening; tensor ops that fit VRF/VLEN. |
| **C. In-core functional unit** | A small scalar/SIMD ALU op reading `rs1/rs2`, writing `rd`. | Tight | Small 1–few-cycle custom ALU/SIMD ops. |

### Decision heuristic

- **Tight (B or C)** when the op is *small* and fits the vector register file / `VLEN`, or is a scalar reg-reg op.
- **Loose (A)** when the accelerator is *large*, has its **own memory or dataflow**, or wants an **independent clock**.

### Map your ask → path

| You want to add… | Use |
|---|---|
| **CNN accelerator** (conv engine, own SRAM, streams tensors) | **Path A** |
| **MatMul / GEMM engine** (coarse-grained, DMA-fed) | **Path A** |
| **MatMul / tensor op *in the vector unit*** (MAC array behind an RVV opcode) | **Path B** |
| **Wider SIMD** (more ALU/MUL/LSU lanes, bigger VLEN) | **Path B** (scaling) |
| **Small custom SIMD/ALU op** (`rd = f(rs1, rs2)`) | **Path C** (or Path B) |

> **Rule of thumb for the two big asks:** a **CNN or standalone GEMM engine → Path A**. A **MatMul folded into RVV as a matrix/MAC unit → Path B**.

---

## 2. Background — how the SoC is assembled

The SoC is **not** hand-wired. It is generated from configuration, so once you understand the four moving parts, every edit below makes sense.

There are **four config sites** that describe any bus device:

1. **`hdl/chisel/src/soc/CrossbarConfig.scala`** — the *fabric map*:
   - `HostConfig(name, width, clockDomain)` (`:43`) — a **bus master** port (something that *initiates* reads/writes). The CPU is `coralnpu_core`; the `dma` is a host too.
   - `DeviceConfig(name, Seq(AddressRange(base, size)), clockDomain, width)` (`:52-57`) — a **slave** at an MMIO address range.
   - `connections` (`:125`) — the **permission graph**: `host -> Seq(devices it may reach)`.
   - `CrossbarConfigValidator` (`:145`, a standalone `App`) — **asserts on address-range overlap**. Run it before emitting.

2. **`hdl/chisel/src/soc/SoCChiselConfig.scala`** — the *instance list*:
   - A `case class …Parameters(...) extends ModuleParameters` (the sealed trait is at `:39`) holding per-module constructor args.
   - A `ChiselModuleConfig(name, moduleClass, params, hostConnections, deviceConnections, externalPorts)` entry in the `modules` Seq (`:130`). The `hostConnections`/`deviceConnections` maps bind **your Chisel IO port paths** (keys) to **XBAR port names** (values, from step 1).

3. **`hdl/chisel/src/soc/CoralNPUChiselSubsystem.scala`** — the *elaborator*:
   - `instantiateModule` (`:130-190`) is a **Scala pattern-match on the params type** that actually calls `Module(new …)`. **This is the real dispatch — the `moduleClass` string in step 2 is documentation only.**
   - Generic wiring loops (`:208-247`) auto-connect clock/reset, `io.tl_host`/`io.tl_device`, and external ports from the config maps. **No per-module wiring needed** for a normal device.

4. **The module BUILD file** (e.g. `hdl/chisel/src/bus/BUILD`) — adds your `.scala` to the compiled `srcs`.

> **The one that bites:** if you add the params + config but **forget the `case p: … =>` arm** in `instantiateModule`, the match is non-exhaustive and Chisel elaboration dies with **`scala.MatchError` at runtime** — not a compile error you'll catch early.

The RVV path (B) and in-core path (C) hook into the *scalar core* instead of the fabric, but the same "data-driven, one load-bearing dispatch site" philosophy applies (a decode `Cat`, a dispatch lane, a writeback port).

---

## 3. Path A — Bus accelerator (MMIO + DMA)  ← the main worked example

This is the **primary path for a CNN or MatMul/GEMM engine**. The engine is a TileLink-UL device that:

- exposes a **CSR slave** (`tl_device`) the core writes to configure/kick it, and
- acts as a **bus master** (`tl_host`) to stream tensors from SRAM/DDR.

**The `DmaEngine` is the exact template** — it already carries *both* ports. A CNN/GEMM engine is the same shape: CSR slave for config + descriptor pointer, host master for tensor streaming. We'll build one called **`cnn_accel`** at base **`0x40060000`** (the free 4 KB slot between `dma` @ `0x40050000` and `spi_master_flash` @ `0x40070000`).

You will touch **five files** (four config/BUILD + one new module).

### 3.0 Reference: the DmaEngine port bundle you replicate

From `hdl/chisel/src/bus/DmaEngine.scala:22-29`:

```scala
class DmaEngine(hostParams: Parameters, deviceParams: Parameters) extends Module {
  val hostTlulP   = new TLULParameters(hostParams)
  val deviceTlulP = new TLULParameters(deviceParams)
  val io = IO(new Bundle {
    val tl_host   = new OpenTitanTileLink.Host2Device(hostTlulP)           // MASTER: reads/writes memory
    val tl_device = Flipped(new OpenTitanTileLink.Host2Device(deviceTlulP)) // SLAVE: core writes CSRs
  })
```

- `tl_host` = **bus master** — the engine drives A-channel `Get`/`PutFullData` to stream tensors.
- `tl_device = Flipped(...)` = **CSR slave** — the core writes control regs here.
- `Host2Device` is defined at `bus/TileLinkUL.scala:99`; `TLULParameters(p)` at `:22` derives `w = axi2DataBits/8`, `z = log2Ceil(w)`, `o = axi2IdBits`.

### 3.1 New module: `hdl/chisel/src/bus/CnnAccel.scala`

Copy `DmaEngine.scala` and adapt. **Keep the class signature and the exact dual-port `io` bundle** — the auto-wiring loop looks up the port names `io.tl_host` / `io.tl_device` *by string*, so do **not** rename them.

Swap out three regions:
- the CSR enum (`object DmaReg`, `:38-48`) → your accelerator regs,
- the descriptor FSM (`:51-56`) → your compute + tensor-stream FSM,
- but **reuse the host A/D request generation (`:397-434`) and the device CSR read/write logic (`:180-370`) unchanged in structure**.

```scala
package bus

import chisel3._
import chisel3.util._
import common._

// --- CSR map: 12-bit offsets. RSVD=0xfff pins the enum to full 12-bit width. ---
object CnnReg extends ChiselEnum {
  val CTRL      = Value(0x00.U(12.W))  // [0]=GO, [1]=irq_en, ...
  val STATUS    = Value(0x04.U(12.W))  // [0]=busy, [1]=done
  val IN_ADDR   = Value(0x08.U(12.W))  // input/activation tensor base (in memory)
  val W_ADDR    = Value(0x0c.U(12.W))  // weight base
  val OUT_ADDR  = Value(0x10.U(12.W))  // output base
  val DIMS      = Value(0x14.U(12.W))  // packed M/N/K or H/W/C
  val RSVD      = Value(0xfff.U(12.W)) // NB: keep — forces full 12-bit enum width
}

class CnnAccel(hostParams: Parameters, deviceParams: Parameters) extends Module {
  val hostTlulP   = new TLULParameters(hostParams)
  val deviceTlulP = new TLULParameters(deviceParams)
  val io = IO(new Bundle {
    val tl_host   = new OpenTitanTileLink.Host2Device(hostTlulP)           // MASTER
    val tl_device = Flipped(new OpenTitanTileLink.Host2Device(deviceTlulP)) // CSR SLAVE
  })

  // ---------------- Device (CSR slave) side ----------------
  // Structure mirrors DmaEngine.scala:177-368.
  val dev_a = io.tl_device.a
  val dev_d = io.tl_device.d
  val dev_a_internal = Wire(chiselTypeOf(dev_a)) // (or Queue as DmaEngine does)
  // ... a/d handshake plumbing copied from DmaEngine ...

  val dev_addr_offset = dev_a_internal.bits.address(11, 0)          // DmaEngine.scala:177
  val (dev_addr_reg, dev_addr_reg_valid) = CnnReg.safe(dev_addr_offset) // :178
  val dev_is_write = dev_a_internal.bits.opcode === /* PutFullData */ 0.U

  // Config registers
  val ctrl_reg  = RegInit(0.U(deviceParams.lsuDataBits.W))
  val in_addr   = RegInit(0.U(32.W))
  val w_addr    = RegInit(0.U(32.W))
  val out_addr  = RegInit(0.U(32.W))
  val dims_reg  = RegInit(0.U(32.W))
  val busy      = RegInit(false.B)
  val done      = RegInit(false.B)

  // Write path (mirror DmaEngine.scala:210-232)
  when (dev_a_internal.fire && dev_is_write) {
    switch (dev_addr_reg) {
      is (CnnReg.CTRL)     { ctrl_reg := dev_a_internal.bits.data }
      is (CnnReg.IN_ADDR)  { in_addr  := dev_a_internal.bits.data }
      is (CnnReg.W_ADDR)   { w_addr   := dev_a_internal.bits.data }
      is (CnnReg.OUT_ADDR) { out_addr := dev_a_internal.bits.data }
      is (CnnReg.DIMS)     { dims_reg := dev_a_internal.bits.data }
    }
  }
  val go = dev_a_internal.fire && dev_is_write &&
           (dev_addr_reg === CnnReg.CTRL) && dev_a_internal.bits.data(0)

  // Read mux (mirror DmaEngine.scala:340-368)
  val status_val = Cat(0.U, done, busy)
  dev_d.bits.data := MuxLookup(dev_addr_reg, 0.U)(Seq(
    CnnReg.CTRL     -> ctrl_reg,
    CnnReg.STATUS   -> status_val,
    CnnReg.IN_ADDR  -> in_addr,
    CnnReg.W_ADDR   -> w_addr,
    CnnReg.OUT_ADDR -> out_addr,
    CnnReg.DIMS     -> dims_reg))
  // ... AccessAck / AccessAckData opcode + handshake copied from DmaEngine ...

  // ---------------- Host (bus master) side ----------------
  // Your compute + tensor-stream FSM lives here (replaces the DmaEngine descriptor FSM).
  // REUSE DmaEngine.scala:397-430 to build host_a_bits (opcode Get/PutFullData,
  // size, address, mask via sizeMask, data), then:
  //   io.tl_host.a <> Queue(host_a_internal, 1)   // DmaEngine.scala:431
  //   host D-responses consumed at DmaEngine.scala:434
  when (go) { busy := true.B; done := false.B }
  // ... issue Get bursts from in_addr/w_addr, run MAC array, PutFullData to out_addr,
  //     then: busy := false.B; done := true.B
}
```

> **Key reuse points inside DmaEngine (do not rewrite these):**
> - Host-master request builder: `DmaEngine.scala:397-430`, emitted at `:431` `io.tl_host.a <> Queue(host_a_internal, 1)`, responses at `:434`.
> - Device CSR decode: `:177-178`; write path `:210-232`; read-mux + `AccessAck`/`AccessAckData` `:340-368`.

### 3.2 `hdl/chisel/src/bus/BUILD`

Add the new file to the `bus` library `srcs` (the Seq starts ~`:31`, alongside `DmaEngine.scala`):

```python
chisel_library(
    name = "bus",
    srcs = [
        "DmaEngine.scala",
        "CnnAccel.scala",   # <-- add
        # ...
    ],
    # ...
)
```

Optionally mirror `dma_engine_test` (bottom of file) with a `chisel_test` for a unit TB.

### 3.3 `hdl/chisel/src/soc/CrossbarConfig.scala` — three edits

**(a) Host (only if it masters the bus — a CNN/GEMM engine does).** In `def hosts` `baseHosts` Seq (`:68-75`), after `HostConfig("dma", width=128)` at `:71`:

```scala
HostConfig("cnn_accel", width = 128),
```

**(b) Device (CSR slave).** In the `devices` Seq (`:105-122`), after the `dma` entry at `:117`:

```scala
DeviceConfig("cnn_accel", Seq(AddressRange(0x40060000, 0x1000))),
```

Pick a base that does **not** collide (`0x40060000` is free between `dma 0x40050000` and `spi_master_flash 0x40070000`). `CrossbarConfigValidator` (`:147`) asserts on overlap.

**(c) Connections — two separate edges.** In `def connections` `baseConnections` (`:126-133`):

```scala
// (c1) let the CORE reach the CSRs — add to the coralnpu_core grant list (:127):
"coralnpu_core" -> Seq(/* ...existing... */, "cnn_accel"),

// (c2) let the ENGINE master memory — NEW master entry mirroring "dma" (:129):
"cnn_accel" -> Seq("sram", "ddr_mem", "coralnpu_device"),
```

> **Two-way grant gotcha:** (c1) and (c2) are *separate edges*. Add only (c1) and you get an engine that can be configured but can't touch memory (dead master). Add only (c2) and the core can't program it. Also, if `width != 128`, the XBAR auto-inserts a `TlulWidthBridge`.

### 3.4 `hdl/chisel/src/soc/SoCChiselConfig.scala` — two edits

**(a) Params case class** next to `DmaParameters` (`:67-70`). It **must** `extends ModuleParameters` (sealed trait at `:39`):

```scala
case class CnnAccelParameters(hostDataBits: Int, deviceDataBits: Int) extends ModuleParameters
```

**(b) ChiselModuleConfig** — copy the `dma` block (`:211-217`) into the `modules` Seq and rename:

```scala
ChiselModuleConfig(
  name = "cnn_accel",
  moduleClass = "bus.CnnAccel",                          // documentation only
  params = CnnAccelParameters(hostDataBits = 128, deviceDataBits = 32),
  hostConnections   = Map("io.tl_host"   -> "cnn_accel"), // KEY=your IO path, VALUE=XBAR port
  deviceConnections = Map("io.tl_device" -> "cnn_accel"),
  externalPorts = Seq.empty)
```

> The map **keys** are the literal Chisel IO port paths on *your* module (`io.tl_host`, `io.tl_device`) — looked up by string via `DataMirror.populatePorts` in the auto-wiring loop (`Subsystem :215-225`). Rename your bundle fields and you get a `NoSuchElementException`. **Keep `tl_host`/`tl_device`.**
> For a non-TileLink pin (e.g. an interrupt), add `ExternalPort("cnn_irq", Bool, Out, "io.irq")` here.

### 3.5 `hdl/chisel/src/soc/CoralNPUChiselSubsystem.scala` — the load-bearing match arm

Add a `case` to `instantiateModule` (`:130-190`), right after the `DmaParameters` arm (`:163-169`):

```scala
case p: CnnAccelParameters =>
  val host_p = new Parameters
  host_p.lsuDataBits = p.hostDataBits
  val device_p = new Parameters
  device_p.lsuDataBits = p.deviceDataBits
  device_p.axi2IdBits  = 10               // sizes the TL source-id field — must be set
  Module(new bus.CnnAccel(host_p, device_p))
```

> **This arm is mandatory.** Dispatch is a **pattern-match on the params TYPE, not reflection**; the `moduleClass` string is not used to instantiate. Omit this and the match is non-exhaustive → **`scala.MatchError` at elaboration**.
> After this, clock/reset (`io.clk`/`clk_i`/`rst_ni`), TL host/device wiring, and external ports are auto-connected by the generic loops at `:208-247`. If you added an IRQ `ExternalPort` and want it to reach the **core/PLIC** (not just a top-level pin), add an explicit wire like the CLINT/PLIC block at `:270-283` — the generic external-ports loop only routes it to a top IO pin.

### 3.6 Validate, then build

```bash
# from repo root
bazel run //hdl/chisel/src/soc:validate_crossbar_config   # CrossbarConfigValidator, asserts on overlap
```

Then emit via the testharness model and run the bus test (see §6). Firmware drives the CSRs at `0x40060000` (see §6.4).

### Path A gotchas (checklist)

- ✅ The `case p: CnnAccelParameters =>` arm exists (else `MatchError`).
- ✅ Params `extends ModuleParameters`.
- ✅ IO fields named exactly `tl_host` / `tl_device`.
- ✅ No address overlap (`0x40060000` is free; run the validator).
- ✅ **Both** connection edges present (`coralnpu_core -> cnn_accel` **and** `cnn_accel -> Seq(...)`).
- ✅ `device_p.axi2IdBits = 10` set in the match arm.
- ✅ Widths match your real bus (host 128 / device CSR 32 is the normal `Dma` shape; XBAR bridges mismatches).
- ⚠️ This is the **coarse-grained** path (core kicks + polls). It is **not** the RVV/custom-instruction path — don't confuse them.

---

## 4. Path B — Custom vector instruction / RVV backend

Use this when you want to (A) add a **custom vector/tensor instruction** on the tight-coupled RVV path, or (B) **extend/scale the SystemVerilog RVV backend** — add a MatMul/MAC execution unit, route an RVV opcode to it, or widen SIMD (`NUM_ALU/MUL/LSU`, `VLEN`).

**Critical orientation — there are two decoders, and one is dead for this build:**

- `hdl/chisel/src/coralnpu/rvv/RvvDecode.scala` (Chisel) only **classifies** instructions (hazards / interlocks / LSU addressing) and forwards **25 opaque payload bits**. `RvvS1DecodeInstruction` (`:404-456`) is a Chisel-native decode that is **dead** on the tight-coupled build.
- **All real arithmetic decode + execution lives in the SystemVerilog backend** (`hdl/verilog/rvv/…`: `rvv_backend_decode_* → uop queue → dispatch → EX units`). The RVV core is a **`BlackBox`** (`RvvCoreWrapper`), *not* the Chisel-native `RvvCore`/`RvvAlu`.

### 4.0 The BlackBox / `addResource` contract

`hdl/chisel/src/coralnpu/rvv/RvvCore.scala`:
- `class RvvCoreWrapper(p) extends BlackBox with HasBlackBoxInline with HasBlackBoxResource` (`:427`).
- `GenerateCoreShimSource` (`:27-391`) emits `RvvCoreWrapper.sv` (`setInline` `:612`) with per-lane inst ports: `inst_i_valid`, `inst_i_bits_opcode[1:0]`, `inst_i_bits_bits[24:0]` (`:40-44`).
- **The `addResource` list (`:485-611`) enumerates EVERY `.sv` file compiled into the backend. A new `.sv` unit MUST be added here or it is not in the build** (silent link/elaboration error, not a skip). Note `rvv_backend_mul_unit.sv` is intentionally commented out at `:595` — the MAC path is used instead; a live example.
- `GenerateBackendConfig` (`:394-423`) emits `rvv_backend_config.svh`. **`ZVE32F_ON` is commented out (float OFF)**; `ZVFBFWMA_ON` only if `p.enableVectorBf16`. `VLEN` is threaded in via `vlen.toString` into `rvv2lsu`/`lsu2rvv` port widths (`:89-108`).

### 4.A Add a custom vector instruction (reuse OP-V `1010111`)

The **only** gate on which RISC-V opcodes enter RVV is `RvvCompressedInstruction.from_uncompressed` (`RvvDecode.scala:149-181`):

```
0000111 -> RVVLOAD    (:166)
0100111 -> RVVSTORE   (:168)
1010111 -> RVVALU     (:170)   // OP-V; payload = inst(31,7) = 25 bits pass through opaquely
```

- **If your op reuses OP-V (`1010111`) and reads/writes vector regs normally → NO Chisel change** here; the 25 payload bits pass through.
- Only edit the semantic helpers in `RvvCompressedInstruction` if your op has non-standard reg-write/trap/vstart semantics, because these drive **scalar hazard interlocks**:
  - `writesRd` (`:123`), `writesFrd` (`:129`), `writesVectorRegister` (`:134`), `requireZeroVstart` (`:64`), `readsRs1`/`readsRs2` (`:106`/`:113`).
- In **SystemVerilog** (the real work):
  1. Add the `funct6` parameter to `rvv_backend_opcode.svh`.
  2. Add its case to `rvv_backend_decode_unit_ari.sv` (uop split / `uop_index_max`) and to `rvv_backend_decode_unit_ari_de2.sv` where `uop_exe_unit` is assigned (`:327-353` pattern), pointing it at the target EX unit.
  3. If it needs a **new load/store addressing form**, extend `Decode.scala:648-662` (`mop -> LsuOp`) and the LSU decode (unit-stride/strided/indexed are already mapped).
- These SV files are already in `addResource`, so a rebuild picks them up.

> A brand-new custom-0/1/2 major opcode would need a change in `from_uncompressed` **and** in scalar fetch/decode — far more expensive. **Reusing OP-V with a spare `funct6` is the cheap path.**

### 4.B Add a MatMul / new EX unit (e.g. `MMU`)

The MAC array is the precedent: `rvv_backend_mac_unit` is instantiated `NUM_MUL`-wide inside `rvv_backend_mulmac.sv`, fed by `u_mul_rs` (`rvv_backend.sv:599-628`) and routed from `u_mulmac` (`rvv_backend.sv:896-907`). Mirror it.

**Step 1 — EX-unit enum** (`hdl/verilog/rvv/inc/rvv_backend.svh:157-176`), add `MMU`:

```systemverilog
typedef enum logic [3:0] {
  ALU, MUL, MAC, PMT, RDT, CMP, DIV, LSU, MMU,   // <-- add MMU
`ifdef ZVE32F_ON
  FMA, FCVT, FRDT, FNCMP, FCMP, FDIV, FTBL,
`endif
  MISC
} EXE_UNIT_e;
```

**Step 2 — counts** (`hdl/verilog/rvv/inc/rvv_backend_define.svh:64-84`). Add `NUM_MMU` and fold it into `NUM_ARI` so `NUM_PU` grows:

```systemverilog
`define NUM_LSU 2
`define NUM_ALU 2
`define NUM_MUL 2
`define NUM_PMTRDT 1
`define NUM_DIV 1
`define NUM_MMU 1                                            // <-- add
// ...
`define NUM_ARI (`NUM_ALU+`NUM_PMTRDT+`NUM_MUL+`NUM_DIV+`NUM_MMU)  // <-- include MMU
`define NUM_PU  (`NUM_ARI+`NUM_LSU)
```

Also define an `MMU_RS_t` struct + `` `MMU_RS_DEPTH `` alongside the other RS depths.

**Step 3 — dispatch routing.** In `rvv_backend_dispatch_ctrl.sv`, add `rs_valid_dp2mmu` (mirror the MUL/MAC decode at `:179-181`):

```systemverilog
assign rs_valid_dp2mmu[i] = uop_ready_dp2uop[i] &
    (uop_ctrl[i].uop_exe_unit == MMU);
```

Thread that port through `rvv_backend_dispatch.sv`. In `rvv_backend_decode_unit_ari_de2.sv` set `uop_exe_unit = MMU` for your new `funct6`.

**Step 4 — instantiate + arbitrate.** In `rvv_backend.sv`:

- Declare `rs_valid_dp2mmu` / `rs_dp2mmu` / `rs_ready_mmu2dp` (cf. `:166-169`) and `res_valid_mmu` / `res_mmu` / `res_ready_mmu` (cf. `:273-275`).
- Instantiate `u_mmu_rs` as a `multi_fifo` (copy `u_mul_rs` `:599-628`, `N = `` `NUM_MMU ``).
- Instantiate the MatMul unit (copy `u_mulmac` wiring `:896-907`).
- Pass `rs_valid_dp2mmu` into the `u_dispatch` port list (cf. `:489-491`).
- **Append** `res_valid_mmu`/`res_mmu` into the `res_valid_pu2arb` / `res_pu2arb` concats and split `res_ready` (`:967-998`). Ordering is **positional** and must line up with the `NUM_PU` bit layout used by the arbiter loop:

```systemverilog
assign res_valid_pu2arb = {
  `ifdef ZVE32F_ON res_valid_falu, `endif
  res_valid_mmu,                 // <-- append (keep order consistent with NUM_PU indexing)
  res_valid_div, res_valid_pmtrdt, res_valid_mul,
  res_valid_alu, res_valid_lsu };
```

- The `ARBITER_ON` `gen_res_ff` generate (`:1002-1034`) iterates `[NUM_LSU..NUM_PU)` and **auto-buffers every ARI PU** into `rvv_backend_arb`, so a correctly-appended ARI unit is arbitrated into the 4 ROB write ports automatically.

**Step 5 — register the file.** Add the new `.sv` to the `addResource` list in `RvvCore.scala` (`~:485-611`) or the BlackBox won't compile it.

> The MAC array template (`rvv_backend_mulmac.sv`):
> ```systemverilog
> generate for (i = 0; i < `NUM_MUL; i++) begin: INST_MAC
>   rvv_backend_mac_unit u_mac (
>     .mac2rob_uop_valid(res_valid_ex2rob[i]),
>     .mac2rob_uop_data (res_ex2rob[i]),
>     .rs2mac_uop_valid (mac_valid[i]),
>     .rs2mac_uop_data  (mac_uop[i]), /* ... */ );
> end endgenerate
> ```
> A MatMul unit can **piggyback the shared MAC array** (MUL and MAC already share `u_mul_rs` + `u_mulmac`, and dispatch sends both `MUL` and `MAC` to `dp2mul`), or take a **genuinely separate RS + PU**. The latter is cleaner for wide/multi-cycle tensor ops but requires the full `NUM_*`/dispatch/arb plumbing above.

### 4.C Scale SIMD (more lanes)

Bump the counts in `rvv_backend_define.svh:64-68` (`NUM_ALU/NUM_MUL/NUM_LSU/NUM_PMTRDT/NUM_DIV`). RS `multi_fifo`s use `N = `` `NUM_* `` so they widen automatically, and the `mulmac`/`alu` generate loops replicate lanes.

**But widening a unit count does NOT raise throughput alone.** The real ceilings:

- `` `NUM_DP_UOP = 3 `` (`:14`, `DISPATCH3`) — uops issued per cycle.
- `` `NUM_SMPORT = 4 `` (`:88`, under `ARBITER_ON`) — arbiter→ROB writeback ports.

Raise those too, or extra lanes starve.

### 4.D VLEN — double-defined, keep in sync

`VLEN` is set in **both** places and they must match:

- SV: `` `ifdef VLEN_128 `define VLEN 128 `` (`rvv_backend_define.svh:129-130`); build flag `-DVLEN_128` at `BUILD:742`.
- Chisel: `val rvvVlen = 128` (`Parameters.scala:96`).

The shim bakes `vlen` into `rvv2lsu`/`lsu2rvv`/VRF port widths (`RvvCore.scala:89-108`). Change one without the other → **mismatched BlackBox port widths** (hard to debug). To go to 256: set `-DVLEN_256` (BUILD) **and** `p.rvvVlen = 256`.

### 4.E Float / BF16 is gated OFF on the attached BlackBox

`GenerateBackendConfig` emits `` //`define ZVE32F_ON `` (commented, `RvvCore.scala:403-405`), so FMA/FALU/FDIV units and `vfwmaccbf16` are compiled out (`NUM_FMA=0`, `rvv_backend_define.svh:81`):

```scala
|// FP ISA
|//`define ZVE32F_ON
|""".stripMargin
if (p.enableVectorBf16) { config += "`define ZVFBFWMA_ON\n" }
else                    { config += "//`define ZVFBFWMA_ON\n" }
```

Enabling BF16 needs `p.enableVectorBf16` (emits `ZVFBFWMA_ON`) **and** turning `ZVE32F_ON` on, plus the `cvfpu` resources (already `addResource`'d). **Note:** the standalone Verilator `RvvCoreMini` target (`BUILD:742`) *does* define `ZVE32F_ON+VLEN_128`, so **a passing sim there does not prove the attached-BlackBox config** — verify against what `GenerateBackendConfig` actually emits.

### 4.F Where the scalar core hands instructions to RVV (for context)

- **Dispatch lane:** `io.rvv` = `Vec(instructionLanes, Decoupled(RvvCompressedInstruction))` (`Decode.scala:279-280`); driven `:704-705`; fires `:726`.
- **Backpressure:** `rvvInterlock` (`Decode.scala:446-453`) — cumulative RVV inst count must be `< io.rvvQueueCapacity` (`:283`), which comes from the backend's `remaining_count_cq2rvs = CQ_DEPTH - used_count_cq` (`rvv_backend.sv:356`, surfaced at `RvvCore.scala:131`).
  ```scala
  val rvvInterlock = if (p.enableRvv) {
    val isRvv = decodedInsts.map(x => x.rvv.get.valid)
    val isRvvCount = isRvv.scan(0.U(4.W))(_+_)
    (0 until p.instructionLanes).map(i => isRvvCount(i) < io.rvvQueueCapacity.get)
  } else { Seq.fill(p.instructionLanes)(true.B) }
  ```
- `rvvConfigInterlock` (`:417-427`) blocks RVV LSU until vset config is valid; `rvvVstartInterlock` (`:432-442`) blocks reductions when `vstart!=0`. All fold into `canDispatch` (`:497-514`).
- **Top wiring** (`SCore.scala`): `io.rvvcore = Flipped(RvvCoreIO)` (`:47`); `dispatch.io.rvv <> io.rvvcore.inst` (`:434`); LSU bridge `rvv2lsu`/`lsu2rvv` (`:240-243`); vector writeback `rob2rt` (`:80-84`); CSR plumb `vcsr/vstart/vxrm/vxsat` (`:460-468`).

### Path B gotchas

- **Edit the SV backend to change behavior** — `RvvDecode.scala` / `RvvCore`/`RvvAlu` (Chisel-native) are *not* the execution path.
- **Any new `.sv` must be in `addResource`** (`RvvCore.scala:485-611`) or it's invisible.
- **VLEN must match** in SV (`-DVLEN_*`) and Chisel (`p.rvvVlen`).
- **`NUM_DP_UOP=3` and `NUM_SMPORT=4` are the throughput ceilings**, not the per-unit counts.
- **Concat ordering** in `res_*_pu2arb` (`rvv_backend.sv:967-998`) is positional — must match the `gen_res_ff` `NUM_LSU..NUM_PU` indexing.
- **Float/BF16 OFF** on the BlackBox; the Mini sim differs.

---

## 5. Path C — In-core functional unit

Use this for a **small, tightly-coupled scalar/SIMD ALU op** that reads `rs1/rs2` and writes `rd`. Model on **`Alu`** (single-cycle, per-lane, combinational writeback) for a 1-cycle op, or **`Mlu`** (Decoupled, multi-stage, writeback via `Arbiter`) if it takes >1 cycle. All are RV32 R-type custom-opcode ops dispatched by `DispatchV2`.

We'll add a single-cycle unit called **`SimdAlu`** using the **RISC-V custom-0 opcode `0x0B` (`0001011`)** so it can't alias base/M/ZBB decodes.

### 5.1 New module: `hdl/chisel/src/coralnpu/scalar/SimdAlu.scala`

Copy `Alu.scala` verbatim; rename object/class/`Op` enum. Keep the **single-cycle contract** (`Alu.scala:68-77`). **Regfile read data arrives the cycle AFTER `req`** (registered), matching the `Valid` pulse — do *not* make it `Decoupled` unless it's multi-cycle.

```scala
class SimdAlu(p: Parameters) extends Module {
  val io = IO(new Bundle {
    val req = Flipped(Valid(new SimdCmd(p)))          // decode cycle
    val rs1 = Flipped(new RegfileReadDataIO(p))       // execute cycle (registered read)
    val rs2 = Flipped(new RegfileReadDataIO(p))
    val rd  = Valid(Flipped(new RegfileWriteDataIO(p)))
  })
  // SimdCmd bundle: { addr = UInt(log2Ceil(scalarRegCount).W); op = SimdOp() }
  val valid = RegInit(false.B)
  val addr  = Reg(UInt())
  val op    = Reg(SimdOp())
  valid := io.req.valid                               // pulse cycle after req (Alu.scala:79-91)
  when (io.req.valid) { addr := io.req.bits.addr; op := io.req.bits.op }

  val rs1 = io.rs1.data                               // Alu.scala:93-94
  val rs2 = io.rs2.data
  io.rd.valid     := valid
  io.rd.bits.addr := addr
  io.rd.bits.data := MuxLookup(op, 0.U)(Seq(/* op -> result, e.g. packed add/min/max */))

  assert(!io.req.valid || io.rs1.valid)              // operand-valid asserts (Alu.scala:158-159)
  assert(!io.req.valid || io.rs2.valid)
}
```

### 5.2 `hdl/chisel/src/coralnpu/scalar/Decode.scala` — eight edits

1. **Add the field** to `DecodedInstruction` near the ZBB block (`~:111`): `val simd = Bool()`.
2. **Decode BitPat** in `DecodeInstruction.apply` (`~:907`, after the RV32/ZBB block):
   ```scala
   d.simd := op === BitPat("b0000000_?????_?????_000_?????_0001011") // custom-0 = 0x0B
   ```
3. **CRITICAL — append to the `decoded = Cat(...)` list (`~:960-977`)**. Anything not in this `Cat` makes `d.undef` true (`:979`) and traps as illegal-instruction:
   ```scala
   val decoded = Cat(d.lui, d.auipc, /* ...all ops... */,
                     d.rol, d.ror, d.orcb, d.rev8, d.rori,
                     d.ebreak, d.ecall, d.wfi, d.mpause, d.mret,
                     d.fencei, d.flushat, d.flushall,
                     d.simd,   // <-- ADD; else undef=1 for your opcode
                     d.rvv.map(_.valid).getOrElse(false.B),
                     d.float.map(_.valid).getOrElse(false.B))
   d.undef := decoded === 0.U
   ```
4. **Hazard predicates** — if it reads registers, add to `readsRs1()`/`readsRs2()` (`:200-209`). These gate *both* the scoreboard RAW/WAW check *and* the actual regfile read-port `.valid` (`:754-757`). Miss it → `rs1/rs2` read as 0/stale.
5. **Dispatch IO port** next to `val alu` (`:260`):
   ```scala
   val simd = Vec(p.instructionLanes, Valid(new SimdCmd(p)))   // Valid=single-cycle; Decoupled(...)=multi-cycle
   ```
6. **Try-dispatch** — copy the ALU op-select block (`:533-568`), drive the port:
   ```scala
   val tryDispatch = lastReady(i) && canDispatch(i)
   val simdSel = SafeMuxUpTo1H(MakeValid(false.B, SimdOp.OP0), Seq(
       d.simd -> MakeValid(true.B, SimdOp.OP0),   // extend per funct3/funct7
   ), SimdOp)
   io.simd(i).valid     := tryDispatch && simdSel.valid
   io.simd(i).bits.addr := rdAddr(i)
   io.simd(i).bits.op   := simdSel.bits
   ```
7. **`dispatched` Seq** (`:724`) so `lastReady` advances — add `io.simd(i).valid` (Valid) or `io.simd(i).fire` (Decoupled):
   ```scala
   val dispatched = Seq(io.alu(i).fire, io.bru(i).fire, io.simd(i).valid, /* ... */)
   ```
8. **`rdMark_valid`** (`:771-777`) — OR in the new unit so the destination register is scoreboard-marked (else a following dependent instruction can read a stale reg).

### 5.3 `hdl/chisel/src/coralnpu/scalar/SCore.scala` — instantiate + writeback

**(A) Instantiate** (`~:94`), like `Alu`:
```scala
val simd = Seq.fill(p.instructionLanes)(SimdAlu(p))
```

**(B) Wire per-lane** (mirror the ALU block `:167-171`):
```scala
simd(i).io.req := dispatch.io.simd(i)
simd(i).io.rs1 := regfile.io.readData(2*i + 0)
simd(i).io.rs2 := regfile.io.readData(2*i + 1)
```

**(C) SINGLE-CYCLE writeback** — fold into the per-lane `regfile.io.writeData(i)` OR-tree (`:288-302`) **and extend the one-hot assert (`:305-311`)**:
```scala
regfile.io.writeData(i).valid := csr0Valid ||
    alu(i).io.rd.valid || bru(i).io.rd.valid || simd(i).io.rd.valid || rvvCoreRdValid
regfile.io.writeData(i).bits.data :=
    MuxOR(csr0Valid, csr0Data) |
    MuxOR(alu(i).io.rd.valid,  alu(i).io.rd.bits.data) |
    MuxOR(bru(i).io.rd.valid,  bru(i).io.rd.bits.data) |
    MuxOR(simd(i).io.rd.valid, simd(i).io.rd.bits.data) | rvvCoreRdData
assert((csr0Valid +& alu(i).io.rd.valid +& bru(i).io.rd.valid +&
        simd(i).io.rd.valid) <= 1.U)   // <-- add the term or the assert fires
```

**MULTI-CYCLE writeback instead** — do **not** hand-OR into a lane port (its completion is decoupled from dispatch and collides with ALU/BRU). Append `simd.io.rd` to `mluDvuInputs` (`:404`) to share the MLU/DVU `Arbiter` (which serializes writeback onto `writeData(instructionLanes)` and enforces one-hot):
```scala
val mluDvuInputs = Seq(mlu.io.rd, dvu.io.rd, simd.io.rd) ++   // <-- append here
    io.rvvcore.map(x => Seq(x.async_rd)).getOrElse(Seq()) ++
    floatCore.map(x => Seq(x.io.scalar_rd)).getOrElse(Seq()) ++ Seq(io.dm.scalar_rd)
```

> Only bump `Regfile.extraWritePorts` (=2 today: MLU/DVU + LSU; `Regfile.scala:74`) and add a whole new `writeData` index if you *truly* need a dedicated port — prefer sharing.

### 5.4 `hdl/chisel/src/coralnpu/Parameters.scala` — enable flag

Add next to `enableFloat`/`enableRvv` (`:95`/`:102`):
```scala
var enableSimd = false
```
Gate the FU instantiation, dispatch port, and decode field with `if (p.enableSimd)` / `Option.when(p.enableSimd)(...)`, exactly like `enableFloat`/`enableRvv`, so the base core is bit-identical when off. It auto-exports to the C header as `KP_enableSimd` via the reflection in `EmitParametersHeader` (`:178-216`) — a `var …: Boolean` is emitted automatically (a `def` would not).

### 5.5 (Optional) `hdl/chisel/src/coralnpu/scalar/Csr.scala` — a config CSR

Custom `Kxxx` CSRs live in the read-only `0xFC0+` space (`:91-96` / `:374-380`). To add a **writable** mode/enable/scale register `KSIMD`:
```scala
// (1) CsrAddress enum (~:91):
val KSIMD = Value(0xFC1.U(12.W))
// (2) storage next to kisa (~:305):
val kSimdCfg = RegInit(0.U(p.xlen.W))
// (3) enable (~:375):
val ksimdEn = csr_address === CsrAddress.KSIMD
// (4) add to rdata MuxUpTo1H (:405-443):  ksimdEn -> kSimdCfg
// (5) WRITABLE — inside when(req.valid) (:473-500):
when (ksimdEn) { kSimdCfg := wdata }   // Kxxx are read-only today; add this when-block
// (6) route kSimdCfg to your FU via a new Csr IO output if the datapath needs it.
```
Reads/writes go through the normal `csrrw/csrrs/csrrc` path decoded at `Decode.scala:678-699`.

### Path C gotchas (the ones that bite)

- **#1 trap:** a new `DecodedInstruction` Bool *not* in the `decoded = Cat(...)` (`:960-977`) → `d.undef=1` → every instance faults as illegal. Shows up as *unexpected illegal-instruction traps in sim*.
- **Use the custom opcode space** (`0x0B/0x2B/0x5B/0x7B`). Reusing `0110011`/`0010011` risks aliasing base/M/ZBB (matched independently, no priority) → double-decode + one-hot assert failure.
- **Single-cycle rd must feed the per-lane OR-tree AND the one-hot assert** (`:305-311`). Miss the OR → writeback silently dropped; miss the assert term → assertion fires when two units target the same lane.
- **Never hand-OR a multi-cycle result** into a per-lane port — route it through the MLU/DVU `Arbiter`.
- **Regfile read data is REGISTERED** — consume `rs1/rs2` in the `valid` (execute) cycle, not the `req` cycle.
- **Add fire/valid to `dispatched`** (`:724`) or `lastReady` stalls the slot.
- **Add rd to `rdMark_valid`** (`:771`) or RAW hazards on your result are missed.
- **`instructionLanes = 4`** (`Parameters.scala:73`): a per-lane single-cycle unit is replicated **4×** (`Seq.fill`). Fine for a small op; if area-heavy, prefer one shared instance behind an `Arbiter` (the `Mlu` pattern).

---

## 6. Build, test & drive a new IP

Two canonical worked examples: the **`DmaEngine`** (memory-mapped device) and the **gemma `rvv_matmul`** kernel (RVV compute).

### 6.1 BUILD wiring

For a **bus device**: add the `.scala` to the `bus` library `srcs` (`hdl/chisel/src/bus/BUILD:31-53`). Anything depending on `//hdl/chisel/src/soc:...` picks it up transitively. For a *standalone* emitted Verilog + Verilator model of the IP:

```python
chisel_cc_library(name = "cnn_accel", chisel_lib = ":bus",
                  emit_class = "bus.EmitCnnAccel", module_name = "CnnAccel")
verilator_cocotb_model(hdl_toplevel = "CnnAccel",
                       verilog_source = "//hdl/chisel/src/bus:CnnAccel.sv",
                       cflags = VERILATOR_BUILD_ARGS)
```

> `chisel_cc_library` (`rules/chisel.bzl:131`) produces **three** things: a `<name>_emit_verilog` genrule that runs `emit_class` `main()` to make `module_name.sv` (`:151-160`), a `<name>_verilog` library, and Verilator libs `<name>` (SystemC) + `<name>_cc` (plain C++) (`:170-191`). `verilator_cocotb_model` (`rules/coco_tb.bzl:350`) wants the `.sv` or the `_emit_verilog` label — **not** the cc lib.
> A `ChiselEnum` CSR map needs the `RSVD = Value(0xfff.U(12.W))` sentinel (`DmaEngine.scala:47`) or the enum collapses to the width of the largest real register and decode breaks. Keep it.

The **SoC top is already wired** to sim via `//hdl/chisel/src/soc:coralnpu_chisel_subsystem_testharness_model` (Verilator) and `:coralnpu_chisel_subsystem_testharness_cc_library_verilog` (VCS). Building your cocotb suite re-emits `CoralNPUChiselSubsystemTestHarness.sv` and Verilates it.

### 6.2 Emit + build the sim

```bash
# standalone IP model:
bazel build //hdl/chisel/src/bus:cnn_accel_model
# or just build the cocotb suite (re-emits the testharness):
bazel build //tests/cocotb/tlul:cnn_accel_cocotb
```

### 6.3 cocotb test — drive the CSRs over TL-UL

**BUILD** (`tests/cocotb/tlul/BUILD`) — copy the `dma_integration_cocotb` block (`:486-515`):

```python
cocotb_test_suite(
    name = "cnn_accel_cocotb",
    hdl_toplevel = "CoralNPUChiselSubsystemTestHarness",
    test_module = ["test_cnn_accel.py"],
    testcases = ["test_cnn_csr_access"],
    deps = ["//coralnpu_test_utils:TileLinkULInterface"],
    verilator_model = "//hdl/chisel/src/soc:coralnpu_chisel_subsystem_testharness_model",
    vcs_verilog_sources = ["//hdl/chisel/src/soc:coralnpu_chisel_subsystem_testharness_cc_library_verilog"],
)
```

**Test** (`tests/cocotb/tlul/test_cnn_accel.py`) — copy `test_dma_integration.py`. The integration harness drives from host **`test_host_32`** (`io_external_hosts_test_host_32`), width 32, on the async "test" clock domain — you must drive `io_async_ports_hosts_test_clock/_reset` **separately** from `io_clk_i`:

```python
CNN_BASE   = 0x40060000
CNN_CTRL   = CNN_BASE + 0x00
CNN_STATUS = CNN_BASE + 0x04
CNN_IN_ADDR = CNN_BASE + 0x08

host_if = TileLinkULInterface(dut, host_if_name="io_external_hosts_test_host_32",
    clock_name="io_async_ports_hosts_test_clock", width=32)

txn = create_a_channel_req(address=CNN_IN_ADDR, data=0x20000000, mask=0xF, width=host_if.width)
await host_if.host_put(txn); resp = await host_if.host_get_response()
assert resp["error"] == 0

# kick + poll
txn = create_a_channel_req(address=CNN_CTRL, data=0x1, mask=0xF, width=host_if.width)
await host_if.host_put(txn); await host_if.host_get_response()
txn = create_a_channel_req(address=CNN_STATUS, data=0, mask=0x0, width=host_if.width)  # read
await host_if.host_put(txn); r = await host_if.host_get_response()
assert (r["data"] & 0x2)  # done
```

**Run:**
```bash
bazel test //tests/cocotb/tlul:cnn_accel_cocotb_test_cnn_csr_access   # per-testcase
```

> - `cocotb_test_suite` fans out **one target per testcase** named `<suite>_<testcase>`; the bare `<suite>` is a `manual` meta-target — `bazel test //...:suite` alone won't run cases.
> - `test_host_32` only exists when the Verilog is emitted with `--enableTestHarness` (`soc/BUILD:70,121`) and must be in that device's `connections` list under the `enableTestHarness` branch (`CrossbarConfig.scala:135`). Use the *testharness* model/verilog targets.
> - Verilator is the friction-free default. For **VCS**, strip Cadence/Innovus `libstdc++` from `LD_LIBRARY_PATH` (known repo env issue), have `bazelisk` on `PATH`; a new toplevel using backdoor SRAM must be listed in `rules/sram_backdoor.bzl` `SRAM_BACKDOOR_TOPLEVELS` or VCS elaboration fails.

### 6.4 Firmware — drive the IP over MMIO

The base address from `CrossbarConfig` is the single source of truth. Access CSRs through `volatile` pointers (the CLINT pattern, `tests/cocotb/timer_interrupt_test.cc:21`):

```c
#define CNN_BASE     0x40060000u
#define CNN_CTRL     (*(volatile uint32_t*)(CNN_BASE + 0x00))
#define CNN_STATUS   (*(volatile uint32_t*)(CNN_BASE + 0x04))
#define CNN_IN_ADDR  (*(volatile uint32_t*)(CNN_BASE + 0x08))
#define CNN_W_ADDR   (*(volatile uint32_t*)(CNN_BASE + 0x0c))
#define CNN_OUT_ADDR (*(volatile uint32_t*)(CNN_BASE + 0x10))
#define CNN_DIMS     (*(volatile uint32_t*)(CNN_BASE + 0x14))

void cnn_run(uint32_t in, uint32_t w, uint32_t out, uint32_t dims) {
  CNN_IN_ADDR  = in;
  CNN_W_ADDR   = w;
  CNN_OUT_ADDR = out;
  CNN_DIMS     = dims;
  CNN_CTRL     = 0x1;                 // GO
  while ((CNN_STATUS & 0x2) == 0) {}  // poll done
}
```

### 6.5 RVV / compute-kernel path (Path B software)

Put the kernel `.cc` (RVV intrinsics) + a runner `main()` under `tests/cocotb/rvv/ml_ops/gemma_kernels/`. Expose I/O as `volatile` C symbols; **data exceeding DTCM (1 MB) must go in `.ddr_data`, not `.data`** (`rvv_matmul_runner.cc:37-41`):

```cpp
float rhs_input[MAX_K*MAX_N] __attribute__((section(".ddr_data"))) __attribute__((aligned(16)));
volatile uint32_t active_m __attribute__((section(".data")));
int main(){ rvv_tiled_matmul_2d_f32(lhs_input, rhs_input, result_output, active_m, active_k, active_n); }
```

BUILD with `coralnpu_v2_binary` (via the `template_rule` in `gemma_kernels/BUILD:28-65`) and drive from cocotb with the `Fixture` ELF flow (`rvv_rms_norm_cocotb_test.py:38`). **Kernel tests target `hdl_toplevel = "RvvCoreMiniHighmemAxi"` with itcm/dtcm 1024 KB** — the default 8/32 KB core overflows.

```python
fixture = await Fixture.Create(dut, highmem=True)
await fixture.load_elf_and_lookup_symbols(elf_path, ["rms_input","active_seq_len","cycle_count"])
await fixture.write('rms_input', input_data.flatten())
await fixture.run_to_halt(timeout_cycles=10000000)
out = (await fixture.read('rms_output', nbytes)).view(np.float32)
```

### 6.6 Where software lives

- **Production reusable ML kernels:** `sw/opt/litert-micro/` (one `cc_library` per op: conv, depthwise_conv, fully_connected, pooling; `target_compatible_with //platforms/cpu:coralnpu_v2`, dep `//sw/opt:rvv_opt`).
- **Experimental RVV kernels + their cocotb drivers:** `tests/cocotb/rvv/ml_ops/`.
- **Tiny standalone demos:** `examples/` (`coralnpu_v2_binary`).

---

## 7. End-to-end checklist & summary

### Path A (Bus accelerator) — do all of these

- [ ] `hdl/chisel/src/bus/CnnAccel.scala` — new module, `class CnnAccel(hostParams, deviceParams)`, `io.tl_host` + `io.tl_device` (names exact), CSR enum with `RSVD=0xfff`, host A/D + device CSR blocks reused from `DmaEngine`.
- [ ] `hdl/chisel/src/bus/BUILD` — add `CnnAccel.scala` to `bus` `srcs`.
- [ ] `CrossbarConfig.scala` — `HostConfig` (`:71`) + `DeviceConfig(0x40060000)` (`:117`) + connections: `coralnpu_core -> …,"cnn_accel"` (`:127`) **and** `"cnn_accel" -> Seq("sram","ddr_mem","coralnpu_device")` (`:129`).
- [ ] `SoCChiselConfig.scala` — `CnnAccelParameters extends ModuleParameters` (`:67`) + `ChiselModuleConfig` (`:211`).
- [ ] `CoralNPUChiselSubsystem.scala` — **`case p: CnnAccelParameters =>`** arm (`:163`), with `device_p.axi2IdBits = 10`.
- [ ] `bazel run //hdl/chisel/src/soc:validate_crossbar_config` (no overlap).
- [ ] cocotb test + BUILD suite (§6.3); firmware MMIO driver (§6.4).

### Path B (RVV) — custom op

- [ ] (If non-standard semantics) `RvvDecode.scala` helper methods.
- [ ] SV: `funct6` in `rvv_backend_opcode.svh`; case in `rvv_backend_decode_unit_ari.sv` + `…_ari_de2.sv` (`uop_exe_unit`).
- [ ] (New unit) enum in `inc/rvv_backend.svh:176`; `NUM_MMU` into `NUM_ARI` (`rvv_backend_define.svh`); RS + instantiate + arbiter concat in `rvv_backend.sv`.
- [ ] New `.sv` added to `addResource` (`RvvCore.scala:485-611`).
- [ ] VLEN matched (`-DVLEN_*` + `p.rvvVlen`); raise `NUM_DP_UOP`/`NUM_SMPORT` if scaling.

### Path C (In-core FU)

- [ ] `SimdAlu.scala` (copy `Alu.scala`).
- [ ] `Decode.scala`: field + BitPat + **`decoded` Cat** + `readsRs1/2` + dispatch IO port + try-dispatch mux + `dispatched` + `rdMark_valid`.
- [ ] `SCore.scala`: instantiate + wire + writeback (OR-tree + one-hot assert **or** `mluDvuInputs`).
- [ ] `Parameters.scala`: `var enableSimd`; gate everything.
- [ ] (Optional) `Csr.scala`: `KSIMD` config CSR.

### Summary table

| Path | Coupling | Files touched | Load-bearing edit | Effort |
|------|----------|---------------|-------------------|--------|
| **A. Bus (MMIO+DMA)** | Loose | `bus/CnnAccel.scala` (new) + `bus/BUILD` + `CrossbarConfig` + `SoCChiselConfig` + `CoralNPUChiselSubsystem` | the `case p: …Parameters =>` match arm (else `MatchError`) | **Medium** — mostly config; module copied from `DmaEngine`. Best for CNN/GEMM. |
| **B. RVV / custom op** | Tight | `RvvDecode.scala` (maybe) + SV `rvv_backend_*` + `rvv_backend_define.svh`/`.svh` + `RvvCore.scala` (`addResource`) | new `.sv` in `addResource`; VLEN match; arbiter concat ordering | **High** — SV backend surgery; MAC array precedent helps. |
| **C. In-core FU** | Tight | `scalar/SimdAlu.scala` (new) + `Decode.scala` + `SCore.scala` + `Parameters.scala` (+ `Csr.scala`) | append to `decoded` Cat + one-hot writeback assert | **Low–Medium** — small op, but many small decode/writeback touch-points. |
| **Build/test/SW (all paths)** | — | `*/BUILD` + `tests/cocotb/**` + firmware `*.cc` + `sw/opt/litert-micro/**` | keep `CrossbarConfig` ↔ `SoCChiselConfig` in sync | — |

**Bottom line:** a **CNN or MatMul/GEMM engine** almost always wants **Path A** (loose, DMA-fed, DmaEngine-shaped). Fold **MatMul into the vector unit** via **Path B** only when the op fits VRF/VLEN and you want it behind an RVV opcode. Use **Path C** for small scalar/SIMD ALU ops. In every case the SoC is data-driven — get the config edits right and *do not forget the `instantiateModule` match arm* (Path A) or the `decoded` `Cat` (Path C).