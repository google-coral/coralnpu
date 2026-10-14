# Autonomous Agents in CoralNPU

This document provides guidance for AI agents operating in the CoralNPU repository.

## Waveform Traces and Debugging

Simulations in this repository generate `.fst` (Fast Signal Trace) waveforms.
Do not convert `.fst` files to `.vcd` using `fst2vcd` or custom scripts; large unpacked text dumps exhaust disk space and context windows.

Use `//utils/fst_query:fst_query` to inspect waveform metadata, explore scopes, sample signal states, and query transitions directly. Refer to [utils/fst_query/README.md](utils/fst_query/README.md) for usage instructions and workflows.
