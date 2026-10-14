# `fst_query` - Native FST Waveform Query Tool

The `fst_query` tool queries signal hierarchies, instantaneous values, and transition streams directly from `.fst` waveforms. It links against Verilator's vendored `fstcpp` reader, zlib, and lz4, eliminating intermediate `.vcd` conversion.

---

## Key Features

- **Direct FST Reading**: Reads `.fst` waveforms natively without generating temporary `.vcd` files.
- **Fast Metadata Inspection (`--info`)**: Reads simulation bounds, timescale, scope counts, and signal counts in less than 1 ms directly from container headers without decompressing wave data blocks.
- **Output Guardrails (`--limit`, `--tail`, `--count`)**: Sets a default cap of 1,000 transitions with explicit truncation notices on `stderr` to prevent context exhaustion in automated agent sessions.
- **Instantaneous State Sampling (`--sample_at T1,T2,...`)**: Reconstructs signal values at one or more timestamps in a single chronological wave scan, capturing both active and static signals.
- **Hierarchical Tree Exploration (`--list`, `--scope`, `--depth`, `--scopes_only`)**: Provides directory-style progressive exploration of module scopes.
- **Pattern Matching (`--regex`, `--exact`)**: Supports RE2 regular expressions and exact string matching.
- **Session Caching and Batch Mode (`--batch`)**: The `FstSession` class caches container block indices and decompressed hierarchy in memory. Batch mode processes queries sequentially with explicit `--- [query end] ---` delimiters.

---

## Quick Start Recipes

### 1. Inspect Simulation Bounds and Timescale

```bash
$ fst_query sim.fst --info
File:         sim.fst
Writer:       Verilator 5.028
Date:         Wed Oct 14 18:00:00 2026
Timescale:    1 ps (1e-12 s)
Time Range:   0 to 520400 ps
Scopes:       128
Signals:      4312 (unique handles: 2150)
```

### 2. Explore Module Hierarchy (Top-Down)

```bash
# List top-level module scopes without signals:
$ fst_query sim.fst --list --scopes_only

# List scopes inside a submodule:
$ fst_query sim.fst --list --scope TOP.core --scopes_only

# List signals under a specific module:
$ fst_query sim.fst --list --scope TOP.core.alu
TOP.core.alu.pc [32] (handle=12)
TOP.core.alu.res [32] (handle=13)
```

### 3. Query Signal Transitions in a Time Window

```bash
$ fst_query sim.fst --start 1000 --end 1050 TOP.clk TOP.core.pc
@1000 TOP.clk = 0
@1000 TOP.core.pc = 0x80000000
@1010 TOP.clk = 1
@1010 TOP.core.pc = 0x80000004
@1020 TOP.clk = 0
```

### 4. Inspect the Failure Window Before Simulation End

```bash
# Print only the final 20 transitions preceding simulation termination:
fst_query sim.fst --tail 20 TOP.core.state TOP.err_code
```

### 5. Sample Signal State at Exact Timestamps

```bash
# Query signal values at timestamp 45200 (including static signals):
$ fst_query sim.fst --sample_at 45200 TOP.core.rst_n TOP.core.state TOP.core.pc
@45200 (sample) TOP.core.rst_n = 1
@45200 (sample) TOP.core.state = 0x2
@45200 (sample) TOP.core.pc = 0x80000104

# Sample multiple checkpoints in a single wave pass:
$ fst_query sim.fst --sample_at 1000,2000,3000 TOP.core.pc
@1000 (sample) TOP.core.pc = 0x80000000
@2000 (sample) TOP.core.pc = 0x80000040
@3000 (sample) TOP.core.pc = 0x80000084
```

### 6. Filter Signals with Regular Expressions

```bash
fst_query sim.fst --regex 'TOP\.core\.(pc|instruction)'
```

### 7. Execute Batch Queries in a Single Session

Avoid repeated file decompression overhead by streaming multiple queries to an open session:

```bash
# Query script (lines beginning with '#' indicate comments):
cat << 'EOF' > queries.txt
--info
--list --scope TOP.core --scopes_only
--sample_at 1000,2000 TOP.core.pc
EOF

fst_query sim.fst --batch queries.txt
# Each query output ends with:
# --- [query end] ---

# Stream queries interactively:
cat queries.txt | fst_query sim.fst --batch -
```

---

## Command Line Flag Reference

| Flag | Type | Default | Description |
| :--- | :--- | :--- | :--- |
| `--info` | `bool` | `false` | Print simulation metadata and time boundaries without scanning transitions. |
| `--list` | `bool` | `false` | List matching signals and scopes in hierarchy instead of transitions. |
| `--start` | `uint64_t` | `0` | Start timestamp for query (inclusive). |
| `--end` | `uint64_t` | `max` | End timestamp for query (inclusive). |
| `--limit` | `uint64_t` | `1000` | Maximum transitions to emit (default: 1000; set `0` for unlimited). |
| `--tail` | `uint64_t` | `0` | Emit only the final $N$ transitions in the query window (`0` disables). |
| `--count` | `bool` | `false` | Print only the total count of matching transitions (`N transitions`). |
| `--sample_at` | `string` | `""` | Sample signal values at one or more timestamps (for example, `'1000,2000'`). |
| `--scope` | `string` | `""` | Restrict hierarchy listing to descendants of this scope (for example, `'TOP.core'`). |
| `--depth` | `int` | `0` | Maximum hierarchy depth relative to root or `--scope` (`0` disables). |
| `--scopes_only` | `bool` | `false` | List scopes without individual signals. |
| `--regex` | `bool` | `false` | Match signal patterns using RE2 regular expressions. |
| `--exact` | `bool` | `false` | Match full signal name exactly instead of matching by substring. |
| `--batch` | `string` | `""` | Execute queries from a batch file (`-` reads standard input). |

---

## Output Formats and Truncation

- **Transitions**: The tool prints transitions in chronological order as `@<time> <full_signal_name> = <value>`. The tool formats binary vectors between 2 and 64 bits as hexadecimal (`0x...`), and formats single-bit values and four-state Verilog literals (`x`, `z`) as characters.
- **State Samples**: The tool prints samples as `@<time> (sample) <full_signal_name> = <value>`.
- **Truncation Notice**: When output reaches `--limit` and additional transitions match the query window, the tool prints an explicit warning on `stderr`:

  ```text
  [fst_query: Output limited to 1000 transitions. Use --limit 0 for unlimited, or narrow with --start/--end.]
  ```

---

## Reproducibility and Verification

### Build the Tool

```bash
bazel build //utils/fst_query:fst_query
```

### Run Unit Tests

The test suite includes tests against both synthetic waveforms and real simulation vectors generated at test time:

```bash
bazel test //utils/fst_query:fst_query_test
```

### Verify Against a Real Simulation Trace

Run a simulation using `core_mini_axi_sim` and `math.elf` to generate a waveform trace:

```bash
bazel run //tests/verilator_sim:core_mini_axi_sim -- \
    --binary=$(pwd)/$(bazel cquery --output=files //tests/cocotb:math.elf) \
    --trace --trace_file=/tmp/VCoreMiniAxi.core.fst \
    --backdoor_load --cycles=50
```

Then inspect and sample the generated waveform:

```bash
bazel run //utils/fst_query:fst_query -- /tmp/VCoreMiniAxi.core.fst --info
bazel run //utils/fst_query:fst_query -- /tmp/VCoreMiniAxi.core.fst \
    --exact --sample_at 45,90 VCoreMiniAxi.core.CoreMiniAxi.io_aclk
```

### Generate Code Coverage

Run Bazel with LLVM native source-based coverage:

```bash
bazel coverage \
    --repo_env=BAZEL_USE_LLVM_NATIVE_COVERAGE=1 \
    --repo_env=BAZEL_LLVM_PROFDATA=/usr/lib/llvm-21/bin/llvm-profdata \
    --repo_env=BAZEL_LLVM_COV=/usr/lib/llvm-21/bin/llvm-cov \
    --combined_report=lcov \
    //utils/fst_query:fst_query_test
```
