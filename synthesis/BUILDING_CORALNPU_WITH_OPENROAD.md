# Building CoralNPU with OpenROAD (ASAP7 ~200 MHz Physical Flow)

## 1. Overview & Architectural Target

This document provides the reproduction procedure, physical implementation parameters, and microarchitectural rationale for the ~200 MHz physical implementation flow of CoralNPU (`RvvCoreMiniAxi`) using open-source tools: [OpenROAD-flow-scripts (ORFS)](https://github.com/The-OpenROAD-Project/OpenROAD-flow-scripts) and [Yosys](https://github.com/YosysHQ/yosys) targeting the predictive [ASAP7 7.5T PDK](https://github.com/The-OpenROAD-Project/asap7).

* **Design Target**: `RvvCoreMiniAxi` (RISC-V Vector 1.0 RV32IMV + Zve32f + Zvfbwma, 128-bit vector datapath, single-issue in-order core with integrated TCM memory subsystem).
* **Process Technology**: ASAP7 7.5T Predictive 7nm FinFET PDK (Pure RVT standard cell library, FakeRAM memory proxies; Yosys/ABC synthesis maps against `RVT_FF` NLDM libraries, while PnR and multi-corner STA evaluate against `CORNER = WC` at 0.63V across `wc`, `tc`, and `bc` corners).
* **Target Operating Frequency**: Approximately 200 MHz (5.0 ns clock period; work in progress).
* **Standard Cell Count**: ~1.43 million standard cells, ~1.70 million signal nets.
* **Die Dimensions**: 441.5 µm × 441.5 µm (194,937 µm² total footprint, 38.07% core placement density).

---

## 2. Setup & Reproduction

### Prerequisites

* **Docker** engine with container image `openroad/orfs:latest` (pinning a tested image tag or digest is recommended for long-term reproducibility, as `run_parallel_synth.sh` invokes internal ORFS Tcl scripts directly).
* **Bazel** and a host C compiler (`gcc` or `clang`), **required on the host** for a clean checkout to elaborate the SystemVerilog RTL (`RvvCoreMiniAxi.sv`) from Chisel source code (`RvvCoreMiniAxi.sv` is gitignored and not checked into the repository).
* **Recommended Host Resources**: 16+ CPU cores, 64+ GB RAM, and 20+ GB free disk space (see [Hardware Parallelism & Resource Tuning](#hardware-parallelism--resource-tuning) below to scale down on smaller workstations).

### Step 1: Emit SystemVerilog RTL on the Host

Because Bazel is not installed inside `openroad/orfs:latest`, you must generate `synthesis/rvv_core_mini/asap7/RvvCoreMiniAxi.sv` from the CoralNPU repository root before launching the container:

```bash
./synthesis/rvv_core_mini/emit_rtl.sh
```

### Step 2: Hermetic Container Execution (Docker)

The physical implementation flow is fully containerized. Execute the complete synthesis and place-and-route (PnR) flow from the CoralNPU repository root:

```bash
# Enforce least privilege by running the container as the unprivileged host
# user (-u) rather than root, redirecting writable state to /tmp.
docker run --rm \
  -u $(id -u):$(id -g) \
  -e HOME=/tmp \
  -e XDG_CACHE_HOME=/tmp/cache \
  -e XDG_CONFIG_HOME=/tmp/config \
  -v $(pwd):/work \
  openroad/orfs:latest \
  /work/synthesis/rvv_core_mini/asap7/run_full_flow.sh \
    --rerun \
    --clock-period 5000
```

> **Note on Subsequent Runs**: When `.odb` checkpoints already exist in `synthesis/rvv_core_mini/asap7/work/results/`, invoking `run_full_flow.sh` in a non-interactive container without a stage flag will abort with an error. Always specify `--rerun` (for a clean build), `--resume` (to continue from the latest completed checkpoint), `--from <stage>`, or pass `-it` to `docker run` for interactive stage selection.

### Hardware Parallelism & Resource Tuning

By default, `run_parallel_synth.sh` spawns `MAX_PARALLEL_JOBS=16` concurrent Yosys/ABC worker processes, and `run_full_flow.sh` defaults to `NUM_CORES=64` and `ROUTING_CORES=64`. To prevent CPU contention or out-of-memory (OOM) kills on smaller machines, override these environment variables in `docker run`:

```bash
docker run --rm \
  -u $(id -u):$(id -g) \
  -e HOME=/tmp \
  -e XDG_CACHE_HOME=/tmp/cache \
  -e XDG_CONFIG_HOME=/tmp/config \
  -e MAX_PARALLEL_JOBS=8 \
  -e NUM_CORES=16 \
  -e ROUTING_CORES=16 \
  -v $(pwd):/work \
  openroad/orfs:latest \
  /work/synthesis/rvv_core_mini/asap7/run_full_flow.sh \
    --rerun \
    --clock-period 5000
```

### Flow Execution Architecture

The physical flow operates across four automated stages:

1. **RTL Elaboration & Canonicalization**:
   Elaborates `RvvCoreMiniAxi.sv` via Yosys/slang frontend and blackboxes embedded SRAM macros (`fakeram_512x128` and `fakeram_2048x128`).
2. **16-Partition Parallel Synthesis (`run_parallel_synth.sh`)**:
   Splits the design into 16 balanced partitions and synthesizes each concurrently using isolated Yosys workers across available CPU cores.
3. **Netlist Stitching & OpenDB Ingestion (`stitch_partitions.tcl`)**:
   Assembles the partition gate-level netlists into a single consolidated structural netlist (`1_2_yosys.v`) and initializes the OpenDB database (`1_synth.odb`).
4. **OpenROAD Physical Design Execution**:
   Drives floorplanning, macro placement halos, global placement (RePlAce), clock tree synthesis (TritonCTS), global routing (FastRoute), detailed routing (TritonRoute up to M8), and multi-corner post-route static timing analysis.

### Master Flow Runner CLI Options (`run_full_flow.sh`)

The master driver script `synthesis/rvv_core_mini/asap7/run_full_flow.sh` provides fine-grained stage control and checkpoint resumption:

* `--from <stage>`: Jump to a specific execution stage:
  * `0` / `rerun`: Clean rerun from scratch.
  * `1` / `synth`: 16-partition parallel Yosys synthesis.
  * `2` / `floorplan`: Macro and pin floorplanning.
  * `3` / `place`: Global and detailed placement.
  * `4` / `cts`: Clock tree synthesis and skew balancing.
  * `5` / `grt`: FastRoute global routing.
  * `6` / `route`: TritonRoute detailed routing.
  * `7` / `report`: Post-route parasitic extraction and STA reporting.
* `--rerun`: Forces a full clean rerun from scratch without interactive prompting.
* `--resume`: Automatically detects the latest valid `.odb` checkpoint and resumes downstream stages.
* `--clock-period <ps>`: Overrides target clock period in picoseconds (default: `5000` ps / 200 MHz).
* `--synth-only`: Stops immediately after partition stitching (Stages 1–3) without invoking OpenROAD PnR.
* `--dry-run`: Prints stage commands and environment variables without execution.

---

## 3. Structural Arithmetic Optimizations (`CORALNPU_STRUCTURAL_DATAPATH`)

### Motivation: Why Yosys + ABC Requires Structural RTL

Commercial EDA synthesis tools (such as Synopsys DesignWare `.sldb` libraries) recognize behavioural HDL arithmetic operators (`+`, `-`, `*`, `<<`, `>>`) and automatically map them to high-speed arithmetic architectures: Wallace/Dadda carry-save multiplier trees, Han-Carlson parallel-prefix adders, and dual-rail compound incrementers.

In contrast, open-source Yosys + ABC flattens high-level arithmetic into generic boolean equations (`techmap`, `extract_reduce`, `abc`). Without structural guidance, Yosys synthesizes multi-operand vector additions and reduction chains into serial carry-ripple and half-adder chains up to **428 gates deep**, making timing closure impossible at advanced nodes. Defining `CORALNPU_STRUCTURAL_DATAPATH` enables explicit, hand-optimized SystemVerilog arithmetic macros that close timing cleanly.

### Fundamental Compiler Limitations of Yosys `arith_tree`

An in-depth evaluation of the Yosys native `arith_tree` pass (`passes/techmap/arith_tree.cc` in Yosys `0.68+post` / `v0.68`, as packaged in `openroad/orfs:latest`) revealed core structural limitations that prevent automatic tree extraction on complex vector datapaths:

1. **Multi-Output Prefix Sum Fanout Rejection**:
   Lines 154–156 enforce `fanout[bit] == 1` across candidate nodes. In vector reduction units (e.g., Brent-Kung prefix adders), intermediate partial sums fan out to multiple downstream stages, causing `arith_tree` to abort tree formation and fall back to serial ripple logic.
2. **No Compound Dual-Rail Incrementer Inference**:
   Vector rounding modes require computing both $A$ and $A+1$ within a single cycle. `arith_tree` lacks pattern recognizers for dual-rail compound adders and instantiates two full independent 32-bit adders, exhausting logic and routing budgets.
3. **Restoring Division Carry-Out Steering**:
   Lines 113–115 reject adder chaining if the carry-out/borrow bit fans out to control multiplexers (`fanout(CO) > 0`). In iterative division and saturation clamping, trial subtractor carry-outs steer operand multiplexers, disqualifying them from CSA reduction.
4. **Subword Truncation Aborts**:
   The compiler's subword truncation guards (`W_child < W_parent`) abort operand chaining when processing mixed SIMD operations (EEW8, EEW16, EEW32) with intermediate bitfield extractions.
5. **Non-Additive Primitive Domain Boundary**:
   Barrel shifters, priority encoders, and saturation detectors lie outside the adder-tree compiler domain and cannot be recognized or balanced by `arith_tree`.

### Manifest of Structural Modules (`hdl/verilog/rvv/common/`)

| Module | Architectural Implementation | Gate Depth Reduction |
| :--- | :--- | :--- |
| `brent_kung_prefix_sum_16.sv` | 16-element parallel-prefix tree for vector mask counts and viota operations | **12 gates** (vs. 428 gates serial ripple) |
| `priority_encoder_tree.sv` & `isolate_lsb_128` | 128-to-7 binary balanced priority encoder tree and parallel isolate-LSB logic | **8 gates** (vs. 102 gates linear search) |
| `compressor_tree_16to2_dadda.sv` | 16:2 Dadda carry-save reduction tree for vector multiplier partial sums | **8 gates** (vs. 55 gates cascaded adds) |
| `compressor_4to2.sv`, `compressor_3to2.sv` | 4:2 and 3:2 CSA compressor slices for multi-operand accumulator reduction | **3 gates** per reduction level |
| `compound_incrementer_simd32.sv` | Dual-rail SIMD32 parallel-prefix incrementer computing $A$ and $A+1$ concurrently | **14 gates** (vs. 79 gates dual adders) |
| `prefix_adder_han_carlson_64b.sv` | 64-bit sparse Han-Carlson parallel-prefix adder for widening vector ALU ops | **11 gates** (vs. 64 gates ripple carry) |
| `prefix_adder_han_carlson_simd32.sv` | Parameterized SIMD32 (4x8b, 2x16b, 1x32b) Han-Carlson adder with zero carry propagation leakage | **10 gates** (vs. 32 gates ripple carry) |
| `barrel_shifter_tree.sv` | Radix-4 balanced logarithmic multiplexer tree for variable vector shifts | **6 gates** (vs. 32 gates linear cascade) |

---

## 4. Physical Implementation Results (200 MHz WIP Flow, Pure RVT)

Physical implementation characterization was performed on the full `RvvCoreMiniAxi` macro using OpenROAD and TritonRoute targeting 200 MHz on the predictive ASAP7 7.5T PDK (using non-functional `fakeram` placement proxies):

### Physical & Routing Metrics

* **Target Operating Frequency**: 200 MHz (5.0 ns clock period; work in progress).
* **Standard Cell Complexity**: ~1.43 million cells, ~1.70 million signal nets.
* **Die Dimensions**: 441.5 µm × 441.5 µm (~195,000 µm² total footprint, ~38% core placement density).
* **Metal Layer Allocation**: 8 routing layers (M1 through M8).
* **Detailed Routing**: Clean routing completion with 0 DRC violations in TritonRoute.
* **Timing Closure**: Achieves 200 MHz on pure RVT when relaxing setup clock uncertainty in `synthesis/rvv_core_mini/asap7/constraint.sdc` line 38 (`set_clock_uncertainty -setup [expr {$clk_period * 0.05}] [all_clocks]`). The default 5% rule reserves 250 ps at a 5000 ps period, resulting in ~195 MHz in post-route STA; reducing setup uncertainty below ~100 ps achieves 200 MHz. Detailed timing closure and power optimization remain active work in progress.

### Critical Flow Tuning Parameters

To prevent buffer explosion and maintain detailed placement legality:

* `ENABLE_PLACE_REPAIR_TIMING = 0`: Disables global placement buffer inflation, preventing site density violations and detailed placer displacement.
* `SKIP_CTS_REPAIR_TIMING = 0`: Enables post-CTS hold and setup buffer sizing within balanced clock domains.
* `CELL_PAD_IN_SITES_GLOBAL_PLACEMENT = 2`: Adds 2-site padding during global placement to guarantee pin accessibility on dense M1/M2 standard cell rows.
* `CTS_CLUSTER_SIZE = 30`: Generates uniform, balanced clock trees with symmetrical 1050 ps insertion latency.

### Output Artifacts & Post-Route Verification

All run outputs, logs, and reports are generated under `synthesis/rvv_core_mini/asap7/work/`:

* **Final Routed Design & SPEF (`results/asap7/RvvCoreMiniAxi/base/`)**:
  * `6_final.odb`: Final post-route OpenDB database.
  * `6_final.def`: Final routed DEF layout.
  * `6_final.v`: Final post-route gate-level Verilog netlist.
  * `6_final.spef`: Extracted post-route SPEF parasitics.
* **DRC & Post-Route STA Reports (`reports/asap7/RvvCoreMiniAxi/base/`)**:
  * `5_2_route_drc.rpt`: TritonRoute detailed routing DRC verification report (confirm 0 violations).
  * `6_finish.rpt`: Post-route multi-corner OpenSTA timing, skew, power, and area summary report.
* **Execution Logs (`logs/asap7/RvvCoreMiniAxi/base/`)**: Full execution logs for every tool stage.
