# CoralNPU DV: UVM-style cocotb testbench

`coralnpu_dv` is a cocotb testbench for the CoralNPU core that is structured
like a UVM environment. Stimulus comes from sequences, and checking is done by
passive monitors and scoreboards that observe the DUT's pins, so a test never
relies on the driver or the BFM to tell it what happened.

## When to use this style

CoralNPU has three ways to test the core in simulation. They complement each
other:

| | CoralFlow / standard cocotb (`tests/cocotb`) | `coralnpu_dv` (this directory) | SystemVerilog UVM (`tests/uvm`) |
| :--- | :--- | :--- | :--- |
| Test shape | Load an ELF, write inputs, run to halt, read outputs, assert | Sequences drive the AXI slave port while monitors, scoreboards and lockstep cosim check the run | ELF regressions with lockstep cosim |
| What is checked | End results in memory | Every AXI transaction on the bus, every retired instruction (lockstep against MPACT), and end results | Every retired instruction (3-way lockstep against MPACT and Spike: GPR, FPR, vector, tile, CSR and LSU transactions) |
| Backends | MPACT, Verilator, VCS, UVM and FPGA from one test | Verilator | Verilator and VCS |
| Language | Python | Python | SystemVerilog |
| Python interaction during the run | Through the BFM | Yes: sequences, monitors and scoreboards run alongside the core | No: inputs are staged into the ELF image before the run |
| Checker logic tested without a simulator | n/a | Yes (`tb_unit_test`) | No |

Use **CoralFlow** for kernels and programs whose correctness is visible in
their outputs. One test then runs on every backend, including FPGA.

Use **`coralnpu_dv`** when the test needs to interact with the core while it
runs, or check the interfaces themselves:

- AXI traffic: concurrent or randomized accesses, responses, and what the DUT
  actually puts on the bus, not just what the BFM returns;
- directed or randomized stimulus combined with instruction-level lockstep in
  the same test;
- new checkers and golden models written quickly in Python and NumPy, and
  unit-tested before they ever see a simulator;
- debugging in Python: a lockstep mismatch is reported at the first diverging
  instruction, with its PC, disassembly and register writes.

Use **SystemVerilog UVM** for large ELF regressions that need the strongest
architectural-state comparison (3-way, including vector, tile and CSR state),
or for VCS-based flows.

## Architecture

```text
 test (BaseTest phases)
   |  sequences
   v
 Sequencer -> AxiDriver -> CoreMiniAxi BFM -> DUT (VmeCoreMiniVerificationAxi)
                                               |               |
                                     AXI slave pins      RVVI retirement trace
                                               |               |
                                          AxiMonitor      RvviMonitor
                                          (write_ap)      (retire_ap)
                                               |               |
                          +--------------------+               |
                          v                    v               v
                 test scoreboards        CosimScoreboard <-----+
                 (e.g. golden model)     (lockstep against the MPACT ISS)
```

`CoralNpuEnv` builds and connects these components. A test picks what it needs
through `EnvConfig` and passes in its own scoreboards.

| Component | File | UVM equivalent |
| :--- | :--- | :--- |
| `AxiTransaction` | `tb/transaction.py` | `uvm_sequence_item` |
| `AnalysisPort` | `tb/analysis.py` | `uvm_analysis_port` |
| `Sequencer`, sequences | `tb/sequences.py` | `uvm_sequencer`, `uvm_sequence` |
| `AxiDriver`, `AxiSlaveAgent` | `tb/axi_slave_agent.py` | `uvm_driver`, `uvm_agent` |
| `AxiMonitor` | `tb/axi_monitor.py` | `uvm_monitor` (one class for either AXI port) |
| `RvviMonitor`, `RetiredInsn` | `tb/rvvi_monitor.py`, `tb/retired_insn.py` | `uvm_monitor` on the RVVI trace |
| `LockstepChecker`, `CosimScoreboard` | `tb/lockstep.py`, `tb/cosim.py` | `uvm_scoreboard` with an ISS reference model |
| `CoralNpuEnv`, `EnvConfig` | `tb/env.py` | `uvm_env`, a config object |
| `BaseTest` | `tb/base_test.py` | `uvm_test` (reset, build, connect, run, check and report phases) |

The RVVI trace sits inside the core, so `rvvi.vlt.tpl` makes its ports visible
to cocotb. Only the verification cores (`*VerificationAxi`) contain it.

## Running the tests

```bash
bazel test //tests/cocotb/coralnpu_dv:all
```

| Target | What it checks |
| :--- | :--- |
| `tb_unit_test` | The simulator-independent modules (ISA decoding, retirement unpacking, analysis ports, lockstep rules) |
| `smoke_test` | The model boots and runs `vwmul` to completion |
| `axi_agent_test` | Concurrent write sequences are read back, and the monitor sees each write exactly once |
| `cosim_test` | RVVI trace ordering; `vwmul` checked by a golden model, by lockstep against MPACT, and by comparing its output with ISS memory |

## Adding a test

1. Add the program under `programs/` and a `coralnpu_v2_binary` for it in
   `BUILD`.
2. Subclass `BaseTest`: load the ELF in `reset_phase`, create a `CoralNpuEnv`
   in `build_phase`, start sequences in `main_phase`, and check in
   `check_phase`. `VwmulCosimTest` in `cosim_test.py` is the example.
3. If the program needs a golden model, write it as a scoreboard with an
   `analysis_export` queue and pass it in `scoreboards=[...]`.
4. Add the testcase to the matching `*_TESTCASES` list in `BUILD`.

To test another core configuration, add an entry to the `template_rule` map of
Verilator models in `BUILD`.

## Current limitations

- Verilator only, on the `VmeCoreMiniVerificationAxi` core.
- Lockstep compares the PC and integer register writes. Float, vector and
  matrix tile results are checked through memory, and counter CSR reads are
  expected differences.
- Only the AXI slave port has an agent; the master port, interrupts and AXI
  protocol checks are planned.
