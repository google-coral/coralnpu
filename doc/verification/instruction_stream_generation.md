# Constrained-Random Instruction Stream Generation for CoralNPU

## Overview & Motivation

Verification of the CoralNPU core presents challenges that differ from standard in-order or out-of-order processors:

* **Microarchitecture:** CoralNPU uses an in-order, 4-wide dispatch front end. It connects to asymmetric back-end execution units and retires out of order into a retirement buffer (`RetirementBuffer.scala`).
* **Hazard & Contention Hotspots:**
  * Scoreboard tracking for RAW and WAW dependencies across variable-latency units.
  * Structural contention on constrained execution units. Only one Multiply Unit (Mlu) operates per cycle. A non-pipelined Divide Unit (Dvu) applies backpressure. A single Load/Store Unit (Lsu) slot handles memory operations.
  * Serialization at dispatch-group boundaries. Control flow (`jal`, `jalr`), CSR writes (`csrrw`, `csrrs`, `csrrc`), and pipeline fences (`fence.i`) terminate dispatch groups and limit execution to slot 0.
  * Multi-beat bus transactions in the LSU. The 128-bit `dbus` splits memory accesses across multiple cycles with state machines for the slot table.

Standard test streams have verification gaps:

1. **Architectural compliance suites (`riscv-tests`):** These uniform single-issue sequences rarely cause dispatch congestion, structural stalls, or retirement buffer reordering.
2. **Unconstrained random fuzzing (such as `core_mini_axi_rand_instr_test`):** Random 32-bit words mostly hit undefined opcodes, branch out of bounds, or trigger illegal memory accesses. They terminate execution after one instruction without exercising multi-cycle pipeline interactions.
3. **Static random binaries (`riscv-dv` replays):** Pre-generated static binaries run without active seed sweeps or lock-step comparison.

The **Constrained-Random Instruction Stream Generator (ISG)** resolves these gaps. It generates short (64 slots by default), self-terminating programs that enforce **straight-line execution invariants** and **sandboxed memory accesses**. Every batch covers 100% of the active instruction alphabet while it exercises back-to-back hazards (see [Dealt-Based Partitioning](#dealt-based-partitioning)). The active alphabet excludes privileged and terminating opcodes. Each program runs in lock-step co-simulation against reference instruction set simulators.

```text
+----------------------------------------+
| Chisel Decoder                         |
| (DecodeInstruction.table)              |
+----------------------------------------+
                    |
                    v
+----------------------------------------+
| Alphabet Dumper (DecodeTableDump)      |
|   -> alphabet_<config>.json            |
+----------------------------------------+
                    |
                    v
+----------------------------------------+     +----------------------+
| Instruction Stream Generator (Python)  | <-- | isg_rules.bzl        |
|  - Dealt partitioning (guaranteed      |     | seed, batch size,    |
|    active-alphabet coverage)           |     | length, trap rate,   |
|  - Operand constraint engine           |     | align mode           |
+----------------------------------------+     +----------------------+
                    |
                    v
+----------------------------------------+     +----------------------+
| .S assembly                            | --> | Source validator     |
|                                        |     | (validator.py)       |
+----------------------------------------+     +----------------------+
                    |
                    v
+----------------------------------------+
| coralnpu_v2_binary -> ELF              |
+----------------------------------------+
          |                          |
          v                          v
+------------------------+   +------------------------+
| Post-link checks       |   | UVM 3-way lock-step    |
| (postlink.py,          |   | co-simulation          |
|  payload_elf_test.py)  |   | (RVVI vs MPACT vs      |
| - decode vs. alphabet  |   |  Spike)                |
| - encoded invariants   |   |                        |
+------------------------+   +------------------------+
```

---

## Core Invariants

To make sure that random instruction sequences execute deterministically without early termination or bus faults, operand generation follows mathematical invariants.

### 1. Memory Architecture & Spatial Safety Sandboxing

CoralNPU uses a Harvard-style memory subsystem that separates instruction and data spaces. The ISG does not use physical base addresses. It uses linker symbols instead of hardcoded memory offsets.

* **Memory Map & Interconnect Topology (`core_mini_axi` / `coralnpu_v2`):**
  * *ITCM (`0x00000000` - `0x00002000`, 8 KB):* Read-only memory for the core. It contains `.text`. Instructions execute only from ITCM (or external SRAM at `0x20000000`). CoralNPU does not support instruction fetch from DTCM. Fetch from DTCM falls back to AXI EXTMEM. Store instructions that target ITCM cause bus or memory faults.
  * *DTCM (`0x00010000` - `0x00018000`, 32 KB):* Read/write data memory that contains `.data`, `.bss`, stack, and scratchpad structures.
  * *CSR / Peripheral Aperture (`0x00030000` - `0x00040000`):* MMIO registers.
* **Relocatable ISG Design:**
  * *Symbol Relocation:* The generator emits no hardcoded numerical addresses. All references use relocatable symbols:

    ```assembly
    la  xb, isg_scratch        # Base pointer for memory fuzzing (.bss in DTCM)
    la  x2, tohost             # HTIF termination mailbox (.htif section in DTCM)
    ```

  * *Linker & Build Macro Parameterization:* Linker scripts (`coralnpu_tcm.ld.tpl`) template `ITCM_ORIGIN` and `DTCM_ORIGIN`. `tests/isg/isg_rules.bzl` provides a `binary_macro` parameter that defaults to `coralnpu_v2_binary`.
* **Base Pointer Selection:** For each program, the generator selects a random base address register $x_b \in \{x1 \dots x31\}$ (`base_reg`, which defaults to `x31` / `DATA_BASE_REG` in lower-level helper defaults). It sets `rs1` for all load and store instructions to $x_b$.
* **Scratchpad Allocation:** The test prologue writes the address of a 64-byte-aligned scratchpad buffer (`isg_scratch`, 2048 bytes) into $x_b$. It also exports the chosen register index as the ELF symbol `isg_base_reg`.
* **Destination Register Exclusion:** Payload instructions must not use $x_b$ as the destination register `rd`. All other general-purpose registers $\{x1 \dots x31\} \setminus \{x_b\}$ remain in the active GPR pool. Thus, payloads exercise `x31` whenever $x_b \ne x31$. The post-link checker reads `isg_base_reg` from the ELF symbol table. It determines whether an instruction writes a GPR from its encoding (`tests/isg/isa/encoding.py`). It inspects the major opcode and specific subfields rather than a mnemonic list. This check supports new opcodes in known spaces (such as RVV) without code changes. Any instruction in an unclassified opcode space fails verification.
* **Bounded Immediate Offsets:** For an access of size $S \in \{1, 2, 4\}$ bytes, the generator constrains the immediate offset. The entire operand stays within the buffer:
  $$\text{offset} \in [0, 2048 - S]$$
* **Natural Memory Alignment:** In the baseline generator, all memory accesses are naturally aligned ($\text{offset} = k \times S$). This ensures valid execution under standard RISC-V conventions. The generator also supports `unaligned` and `straddle` offset modes. Straddle accesses cross a 16-byte `dbus` boundary. The source validator and unit tests check these modes, but baseline co-simulation batches do not run them.

### 2. Constrained Control Flow

Branches are necessary to test branch resolution, dispatch serialization, and pipeline redirects. However, unconstrained branch targets break linear execution.

* **Reflexive Comparison ($rs1 == rs2$):** The generator tests conditional branches (`beq`, `bne`, `blt`, `bge`, `bltu`, `bgeu`). It sets both source registers to the same random register $r \in \{x1 \dots x31\} \setminus \{x_b\}$:
  * `beq`, `bge`, and `bgeu` evaluate as **always taken** ($r == r$, $r \ge r$).
  * `bne`, `blt`, and `bltu` evaluate as **always not taken** ($r \ne r$, $r < r$ is false).
* **Target Invariant (+4):** All conditional branch instructions set their target offset to $+4$. Taken branches jump to the next instruction word. Untaken branches fall through to that same instruction.
* **Direct Jumps (`jal`):** The generator sets the target immediate for `jal` to $+4$.
* **Indirect Jumps (`jalr`):** The generator emits `jalr` as an atomic two-instruction macro:

  ```assembly
  auipc   xT, 0            # xT = current PC
  jalr    xD, 8(xT)        # Jump to instruction immediately following jalr
  ```

  The temporary register $xT \in \{x1 \dots x31\} \setminus \{x_b\}$ is distinct from $x_b$.

### 3. CSR Sandboxing

`tests/isg/gen/constraints.py` defines the CSR policy. The generator, the source validator, and the post-link checker enforce this policy.

* **Instruction Forms:** The generator creates all six Zicsr instructions: `csrrw`, `csrrs`, `csrrc`, and their immediate forms `csrrwi`, `csrrsi`, `csrrci`. Decoder BitPats use wildcards for `funct3[2]`, so the hardware alphabet lists only register forms. The generator splits each entry into register and immediate forms so dealt partitioning covers both.
* **Write Access (`SAFE_WRITABLE_CSRS_*`):** The generator permits writes only to registers that do not change execution privilege:
  * `0x001` (`fflags`), `0x002` (`frm`), and `0x003` (`fcsr`).
  * `0x340` (`mscratch`), **only with traps disabled**. With traps enabled, `mscratch` holds the save-area pointer for the trap handler. The payload never writes to it.
* **Read Access (`SAFE_READABLE_CSRS`):** Any instruction with `rd != x0` reads the previous CSR value. Therefore, the CSR must return identical values in RTL, MPACT, and Spike: `misa`, `mie`, `mtvec`, `mscratch`, `mepc`, `mcause`, `mip`, and `frm`.
  * `mip` shows pending interrupts. Interrupts can depend on cycle timing in RTL, but not in an ISS. `mip` is readable only because ISG programs run without active interrupt sources. CoralNPU operates as an accelerator rather than a microcontroller, and ISG does not target interrupts.
  * Programs can read `mepc` and `mcause` before the first trap, and `mscratch` with traps disabled. These reads return reset values. RTL, MPACT, and Spike must agree on these reset values.
  * `fflags` and `fcsr` are writable but not readable (see Anomaly 3). Writes to these registers must use `rd = x0`.
  * `fflags` and `fcsr` support only full overwrites (`csrrw` and `csrrwi`). Set or clear instructions (`csrrs`, `csrrc`, and immediate forms) fold diverging accrued flags into the written value, which triggers co-simulation mismatches during writeback.
  * `mtval` is not readable (see Anomaly 1).
* The generator excludes writes to execution-control or privilege-changing CSRs (`mstatus`, `satp`, `mie`, `mtvec`).
* **Floating-Point CSR Coverage:** Random writes to `frm` and full overwrites of `fflags` and `fcsr` interleave with floating-point arithmetic. Every floating-point instruction uses a static rounding mode. Therefore, arbitrary `frm` values (including reserved encodings) do not affect arithmetic results. Reading `frm` checks that RTL and ISS models agree on its architectural value.

### 4. Architectural State Normalization

To avoid false mismatches from uninitialized state during lock-step co-simulation, the test environment normalizes initial state:

* The `_start` entry point clears `.bss` (which holds `isg_scratch` and `isg_trap_save`). A word-store loop clears memory to the word-aligned boundary, and a byte-store loop clears any remaining tail. The linker script aligns `__bss_start__` to 16 bytes. ISG `_start` overrides the CRT weak `_start` symbol, and the ELF loader does not populate NOBITS sections.
* The prologue clears all non-base GPRs in $\{x1 \dots x31\} \setminus \{x_b\}$ to zero (`li r, 0`).
* The prologue clears floating-point registers `f0` through `f31` to zero (`fmv.w.x fN, x0`).
* The prologue clears `fcsr` to reset dynamic rounding modes and sticky accrued flags.
* The prologue initializes `mstatus.FS = Initial` to enable floating-point execution.

---

## Architectural Coupling: Chisel Decoder as Source of Truth

To prevent coverage drift as the processor changes, tooling extracts the instruction alphabet automatically from the hardware decoder in `hdl/chisel/src/coralnpu/scalar/Decode.scala`.

```text
hdl/chisel/src/coralnpu/scalar/Decode.scala
  └── DecodeInstruction.table(p: Parameters): Seq[(String, BitPat)]
            │
            ├──> Chisel Hardware Elaboration (d.elements.foreach / BitPat matching)
            │
            └──> DecodeTableDump (scala_binary)
                      │
                      v
                 alphabet_<config>.json (name, mask, match, pattern)
                      │
                      v
                 Python ISG Generator & Post-Link Validator
```

1. **First-Class Decoder Table:** `DecodeInstruction.table(p: Parameters)` provides the supported `(mnemonic, BitPat)` sequence. Core configuration parameters (`xlen`, `enableFloat`, `enableRvv`, `enableZfbfmin`) select the entries.
2. **Bundle Reflection:** The Chisel hardware decoder iterates over `DecodedInstruction` bundle fields, driving `field := table.get(name).map(op === _).getOrElse(false.B)`. Hardware decode logic and verification tooling share identical definitions.
3. **Automated Extraction:** `DecodeTableDump` instantiates the table for target configurations and outputs `alphabet_<config>.json`. This file contains `(mask, match)` pairs and CSR address lists (`CsrAddress.all`).
4. **Alphabet Consistency Checks:** `decode_probe_test.py` checks the dumped alphabet:
  * Every `match` value fits within its `mask`.
  * Each entry decodes uniquely.
  * Known illegal words (such as `0x00000000` and `0x0000007b`) match no entry.
  * All CSR addresses are unique.
  The post-link checker (`postlink.py`) decodes each linked payload word against this same table.

---

## Dealt-Based Partitioning

### Dealt-Based Coverage Guarantee

With uniform random generation, covering an alphabet of size $M$ within short programs requires impractically large tests. The ISG guarantees full coverage with **Dealt-Based Partitioning**:

* A batch contains $B$ test programs ($B = 32$ for baseline regression).
* Each program $i \in [0, B - 1]$ receives a deterministic dealt cover:
  $$\text{dealtCover}(i) = \{ \text{alphabet}[j] \mid j \equiv i \pmod B \}$$
* Program $i$ distributes its dealt cover across the instruction stream. The union of all programs in the batch covers 100% of the active alphabet:
  $$\bigcup_{i=0}^{B-1} \text{dealtCover}(i) = \text{alphabet}$$
* The generator fills the remaining slots with uniform random instructions from the active alphabet and shuffles the combined stream.
* The active alphabet contains the dumped decoder alphabet without privileged or terminating opcodes (`mret`, `wfi`, `ebreak`, `mpause`, `ecall`). The generator expands each `csrr*` entry into both register and immediate forms.

---

## Build System & Verification Flow

### Baseline Bazel Generation Flow

The generator integrates into Bazel to provide test streams while maintaining build hermeticity and test caching:

1. **`isg_program` Macro:** Runs the Python generator in a Bazel action to produce the `.S` assembly file. It then runs the source validator (`validator.py`) on the assembly text. The build fails on any validation error. The macro accepts configuration parameters such as payload length and random seed.
2. **`coralnpu_v2_binary` Macro:** Compiles `.S` files into bare-metal ELF binaries with the hermetic RISC-V toolchain. It links against the default memory layout (`toolchain/coralnpu_tcm.ld.tpl`).
3. **Post-Link Check (`<batch>_postlink_test`):** Reads linked instruction words between `isg_payload_start` and `isg_payload_end`. It decodes each word against the hardware alphabet and rechecks memory, branch, jump, CSR, and rounding-mode invariants. This verifies that assembler or linker passes (such as pseudo-op expansion, relaxation, or compression) did not violate invariants. With traps enabled, the checker accepts only one undecodable word: the illegal-instruction stimulus (`ILLEGAL_STIMULUS_WORDS`, `0x0000007b`).
4. **Payload/ELF Consistency (`<batch>_payload_elf_test`):** For each program in the batch, this test verifies that the linked payload contains one 32-bit word per source line. It also verifies that each word decodes to the mnemonic written in the source.
5. **`isg_batch` Macro & Regression Targets:** Instantiates `isg_program` for every program in the batch. It defines regression targets such as `verilator_uvm_regression_<batch>` and `vcs_uvm_regression_<batch>`. These targets run all programs in the batch inside one simulator run to reduce execution overhead.

### 3-Way Lock-Step Co-Simulation Oracle

Tests execute in the UVM co-simulation environment (`tests/uvm/`):

* **Retirement Interface (RVVI):** The hardware DUT (`RvvCoreMiniVerificationAxi`) exports retirement signals across up to 8 retire lanes per cycle. These signals include `valid`, `pc_rdata`, `insn`, `x_wb`, `x_wdata`, `csr_wb`, and `csr`.
* **Reference Models:**
  * **MPACT-Sim:** Architectural instruction set simulator stepped on every retired instruction.
  * **Spike (`riscv-isa-sim`):** Reference simulator connected via DPI-C.
* **Lock-Step Checking:** `coralnpu_cosim_checker_pkg.sv` compares destination registers (GPR, FPR, VPR) and CSR state at every instruction retirement boundary.
* **Dirty Register Masking:** Dynamic taint tracking identifies registers that read variable-latency cycle counters (`mcycle`, `minstret`). It masks these registers to prevent false mismatch reports.

---

## Hardware & Verification Anomalies (Reconciliation Log)

This log records hardware and simulator behaviors that diverge or require generator constraints for co-simulation.

### Anomaly 1: mtval Exception Value Divergence on Illegal Instructions

* **Observation:** When an illegal instruction exception occurs (`mcause = 2`, such as undefined word `0x0000007b`):
  * CoralNPU RTL writes the 32-bit faulting instruction word (`0x0000007b`) into `mtval` (`0x343`) in `FaultManager.scala:148`.
  * MPACT leaves `mtval` as `0x00000000`.
  * Both behaviors comply with the RISC-V Privileged Architecture Specification v1.12, Section 3.1.16. The specification permits setting `mtval` to zero or to the faulting instruction bits.
* **Formal Ground Truth (Sail RISC-V):**
  * The formal Sail RISC-V specification (`model/postlude/step.sail`, `model/sys/sys_control.sail`, `model/core/platform_config.sail`) defines writing the faulting opcode as a platform configuration option:

    ```sail
    let illegal_instruction_writes_xtval : bool = config base.xtval_nonzero.illegal_instruction
    ```

  * In Sail's default platform configuration (`config/config.json.in`), `base.xtval_nonzero.illegal_instruction` is **`true`**.
  * Therefore, **CoralNPU RTL matches the default Sail formal model**. MPACT implements the alternative specification option (`illegal_instruction = false`).
* **Co-Simulation Discrepancy:** If an instruction reads `mtval` via `csrrw`, `csrrs`, or `csrrc`, RTL returns `0x0000007b` and MPACT returns `0x00000000`. This divergence causes a `3WAY_COSIM_MISMATCH`.
* **Current ISG Mitigation:** The ISG defines `SAFE_READABLE_CSRS` in `tests/isg/gen/constraints.py` and excludes `mtval` (`0x343`) from random read accesses.
* **Potential Long-Term Solutions:**
  1. *Simulator Alignment:* Configure MPACT to capture faulting instruction bits in `mtval` on illegal instructions, matching Sail and RTL.
  2. *Co-Simulation Checker Masking:* Update the SystemVerilog lockstep checker (`coralnpu_cosim_checker_pkg.sv`) to mask `mtval` comparison when `mcause == 2`.
  3. *ISG Generator Exclusion (Retained):* Keep `mtval` excluded from `SAFE_READABLE_CSRS` so co-simulation passes without changes to external tools.

### Anomaly 2: Dynamic Rounding Mode (`dyn`) Illegal Instruction Divergence with Invalid `fcsr.frm`

* **Observation:** The RISC-V Unprivileged Specification (v20191213, Section 11.2) defines dynamic rounding (`dyn`, `rm = 7`). Such instructions must use the mode in `fcsr.frm` (bits 7:5). If `fcsr.frm` contains an invalid value (5, 6, or 7):
  * **Architectural Requirement:** Any instruction executed with `rm = 7` when `fcsr.frm` is invalid must raise an illegal instruction exception (`mcause = 2`).
  * **CoralNPU Hardware Behavior:** Hardware RTL implements this check in `FloatCoreInterface.scala:72-76`:

    ```scala
    val illegalRm = rm === 7.U && (frm === 5.U || frm === 6.U || frm === 7.U)
    ```

    When `illegalRm` is high, RTL decodes the instruction as illegal and generates a trap.
  * **Reference ISS (MPACT) Behavior:** In `riscv_instruction_helpers.h:500`, MPACT logs an internal error message. It does not raise an illegal instruction exception, and continues simulation with default rounding.
* **Co-Simulation Discrepancy:** When the ISG generated floating-point instructions with dynamic rounding mode (`dyn`) and random `fcsr.frm` values, RTL generated an illegal instruction trap. MPACT continued simulation without trapping, causing a co-simulation mismatch.
* **ISG Resolution:** In `tests/isg/gen/constraints.py`, the generator selects only from the five valid static rounding modes: `ROUNDING_MODES = ["rne", "rtz", "rdn", "rup", "rmm"]`. This constraint prevents unintended dynamic rounding traps and maintains full functional coverage of all IEEE 754 hardware rounding modes.

### Anomaly 3: Floating-Point Accrued Exception Flag (`fflags` / `fcsr` Inexact `NX`) Divergence

* **Observation:** IEEE 754 floating-point operations set sticky exception flags in `fcsr` and `fflags`. These flags include NX (Inexact), UF (Underflow), OF (Overflow), DZ (Divide by Zero), and NV (Invalid Operation).
  * Some operations (such as square root `fsqrt.s`) set the inexact flag (`NX`, bit 0) in CoralNPU hardware according to IEEE 754-2008.
  * Host C++ standard library functions in the reference ISS (MPACT) do not emulate inexact flag accumulation consistently across all operand ranges.
* **Co-Simulation Discrepancy:** When an ISG program executed a CSR read from `fcsr` (`0x003`) or `fflags` (`0x001`) via `csrrs rd, fcsr, rs1`, RTL retired with `fcsr = 0x1` (`NX` set). MPACT retired with `fcsr = 0x0`. This difference caused a false CSR retirement mismatch.
* **ISG Resolution:** `tests/isg/gen/constraints.py` excludes `0x001` (`fflags`) and `0x003` (`fcsr`) from `SAFE_READABLE_CSRS`. They remain in the writable set. Random overwrites (`csrrw` and `csrrwi`) interleave with floating-point arithmetic, but they always use `rd = x0`. This avoids reading diverging previous values. The generator does not use set or clear forms (`csrrs` and `csrrc`) on these CSRs. Those forms fold diverging previous flags into the written value (for example, `csrrc x0, fcsr, x7` produced RTL `0x10` versus MPACT `0x0`). The source validator and post-link checker reject any non-`x0` destination for these CSRs. Directed tests check flag updates and hardware interlocks (`//tests/cocotb:verilator_uvm_regression_float_csr_interlock_test` and `//tests/cocotb:verilator_uvm_regression_frm_test`).

### Anomaly 4: Reference ISS Scope Boundary (Standard RV32F vs Zfbfmin)

* **Observation:** CoralNPU Chisel RTL implements the single-precision floating-point extension (`RV32F`, 26 instructions). It also implements the 16-bit BFloat16 extension (`Zfbfmin`, 4 instructions: `fcvt.s.bf16`, `fcvt.bf16.s`, `fmv.x.h`, `fmv.h.x`).
  * The reference ISS (`coralnpu_mpact` in `rules/repo_defs.bzl`) defines only the 26 instructions of the `RV32F` extension (`coralnpu_v2.isa`). It does not model `Zfbfmin`.
  * For half-word moves (`fmv.x.h`, `fmv.h.x`), MPACT zeroes the upper half of 32-bit registers. Hardware uses 16-bit NaN boxing (`0xffff0000 | halfword`).
* **Co-Simulation Discrepancy:** When random programs included `Zfbfmin` instructions, MPACT generated illegal instruction traps or reported register value mismatches on half-word moves.
* **ISG Resolution:** `DecodeTableDump.scala` restricts the exported decode table to `fBase` (the 26 single-precision RV32F instructions). This matches the supported scope of the co-simulation reference model. The generator has no synthesis rules for `Zfbfmin`. Both the source validator and post-link checker reject `Zfbfmin` opcodes. Dedicated testbenches provide directed verification for `Zfbfmin` (`//tests/cocotb:verilator_uvm_regression_zfbfmin_test`).
