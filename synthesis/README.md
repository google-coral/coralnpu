# CoralNPU Physical Implementation & Synthesis

This directory contains the physical design infrastructure, synthesis automation, and timing characterization workflows for CoralNPU (`RvvCoreMiniAxi`) targeting modern open-source and predictive process design kits (PDKs) via [OpenROAD-flow-scripts (ORFS)](https://github.com/The-OpenROAD-Project/OpenROAD-flow-scripts).

---

## 1. Directory Structure

```text
synthesis/
├── .gitignore                      # Run artifact ignore rules
├── README.md                       # This quickstart and user guide
└── rvv_core_mini/
    ├── emit_rtl.sh                 # On-demand Bazel/Chisel SystemVerilog RTL generation
    └── asap7/
        ├── config.mk               # Floorplan, utilization, and routing layer configuration
        ├── constraint.sdc          # STA clock, uncertainty, and I/O timing constraints
        ├── run_full_flow.sh        # End-to-end multi-stage pipeline driver
        ├── run_parallel_synth.sh   # 16-partition parallel Yosys synthesis orchestrator
        └── stitch_partitions.tcl   # Gate-level netlist stitching and hierarchy validation
```

---

## 2. Quickstart Guide

### Prerequisites

* **Docker** (recommended for hermetic execution with `openroad/orfs:latest`)
* **Bazel** and a host C compiler (`gcc` or `clang`) (required on the host to generate the SystemVerilog netlist from Chisel source code)

### Step 1: Generate RTL from Chisel

From the CoralNPU repository root (`hw/coralnpu`), generate the top-level SystemVerilog netlist (`RvvCoreMiniAxi.sv`):

```bash
./synthesis/rvv_core_mini/emit_rtl.sh
```

> **Note**: When running directly on a host with `bazel` in `PATH`, `run_full_flow.sh` automatically invokes `emit_rtl.sh` if `RvvCoreMiniAxi.sv` is missing. When running via Docker (`openroad/orfs:latest`), Bazel is not available inside the container, so Step 1 must be run on the host first.

### Step 2: Execute Physical Design Flow via Docker

Run the complete 16-partition synthesis, floorplanning, placement, CTS, and routing flow:

```bash
docker run --rm \
  -u $(id -u):$(id -g) \
  -e HOME=/tmp \
  -e XDG_CACHE_HOME=/tmp/cache \
  -e XDG_CONFIG_HOME=/tmp/config \
  -v $(pwd):/work \
  openroad/orfs:latest \
  /work/synthesis/rvv_core_mini/asap7/run_full_flow.sh \
    --rerun
```

> **Note**: On subsequent runs where checkpoints already exist in `work/results/`, pass `--rerun` (for a clean rebuild), `--resume` (to continue from the latest checkpoint), `--from <stage>`, or add `-it` to `docker run` for interactive stage selection. To limit CPU/memory usage on smaller workstations, pass `-e MAX_PARALLEL_JOBS=<N> -e NUM_CORES=<N> -e ROUTING_CORES=<N>`.

Or run directly if OpenROAD and Yosys are available in your local environment:

```bash
./synthesis/rvv_core_mini/asap7/run_full_flow.sh
```

---

## 3. Flow Pipeline Architecture

The end-to-end automated flow executes across 4 discrete stages:

1. **Yosys Canonicalization (`1_1_yosys_canonicalize.rtlil`)**:
   Elaborates the top-level SystemVerilog and blackboxes compiled SRAM macros (`fakeram_512x128` and `fakeram_2048x128`).
2. **16-Partition Parallel Synthesis (`run_parallel_synth.sh`)**:
   Spawns 16 independent Yosys synthesis workers in parallel across host CPU cores, mapping complex vector arithmetic and control units in isolated processes.
3. **Netlist Stitching & Verification (`stitch_partitions.tcl`)**:
   Stitches all partition gate-level netlists into a single, unified top-level Verilog netlist (`1_2_yosys.v`) and validates gate-level mapping purity.
4. **OpenROAD Physical Design (PnR)**:
   Executes floorplanning, macro placement, global placement (RePlAce), clock tree synthesis (TritonCTS), global routing (FastRoute), detailed routing (TritonRoute up to M8), parasitic extraction (OpenRCX), and post-route static timing analysis (OpenSTA).

---

## 4. Output Directories & Artifacts

All run outputs and logs are written into `synthesis/rvv_core_mini/asap7/work/`:

* **`results/asap7/RvvCoreMiniAxi/base/`**: Final routed OpenDB (`6_final.odb`), DEF (`6_final.def`), gate-level netlist (`6_final.v`), and extracted SPEF parasitics (`6_final.spef`).
* **`reports/asap7/RvvCoreMiniAxi/base/`**: Static timing analysis (WNS/TNS), clock skew, power, and area utilization reports.
* **`logs/asap7/RvvCoreMiniAxi/base/`**: Full execution logs for every tool stage.
