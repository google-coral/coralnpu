# Autonomous Agents in CoralNPU

This document provides guidance for AI agents operating in the CoralNPU repository.

## Linting and Formatting

CoralNPU CI runs [`utils/run_linters.sh`](utils/run_linters.sh) on every change and rejects any commit that fails. Run `./utils/run_linters.sh` before committing or finishing a task.

### Usage

- Check all modified, staged, and committed files relative to the auto-detected base branch:

  ```bash
  ./utils/run_linters.sh
  ```

- Automatically fix formatting issues and update `MODULE.bazel.lock`:

  ```bash
  ./utils/run_linters.sh --fix
  ```

- Scope linting to the latest commit or working tree (recommended on detached `HEAD`, stacked commits, or non-default branches):

  ```bash
  # Lint or fix only the most recent commit (plus any working-tree edits):
  BASE_BRANCH=HEAD~ ./utils/run_linters.sh [--fix]

  # Lint or fix only uncommitted working-tree and staged edits on top of HEAD:
  BASE_BRANCH=HEAD ./utils/run_linters.sh [--fix]
  ```

- Lint specific files or directories (required for untracked files that are not yet staged with `git add`):

  ```bash
  ./utils/run_linters.sh [--fix] path/to/file_or_dir
  ```

- Skip or force the Bzlmod lockfile check with `--no-lockfile` or `--check-lockfile`.

### Detached `HEAD`, `BASE_BRANCH`, and `clang-format` Caveats

- **How base detection works**: When `BASE_BRANCH` is unset, `run_linters.sh` checks `<remote>/HEAD` (typically `origin/master`), falls back to common branch names (`origin/main`, `origin/master`, `main`, `master`, `m/main`, `m/master`), and finally falls back to `HEAD`. It then lints all files in `git diff ${BASE}...HEAD` plus uncommitted tracked files in `git diff HEAD`.
- **Why `BASE_BRANCH=HEAD~` is useful**: On detached `HEAD` (such as a Gerrit patchset, a stacked commit series, or a branch like `origin/v2`), comparing against `origin/master` sweeps in every ancestor commit since `origin/master`. Conversely, if you commit directly on the detected base branch (or if base detection falls back to `HEAD`), `${BASE}...HEAD` is empty and the script skips committed changes. Setting `BASE_BRANCH=HEAD~` (or `BASE_BRANCH=HEAD~N` for `N` commits) targets only your commit series.
- **Diff-only vs. full-file `clang-format`**: Passing explicit file paths (`./utils/run_linters.sh --fix foo.cc`) disables diff mode and formats the entire C or C++ file with `clang-format-19 -i`, which can create unrelated diff noise in legacy files. Using `BASE_BRANCH=HEAD~ ./utils/run_linters.sh --fix` without file arguments keeps diff mode active so `git-clang-format-19` formats only the lines you changed.
- **Stage or commit C and C++ files before `--fix` in diff mode**: `git-clang-format-19` (invoked without `-f`) refuses to modify files that have unstaged working-tree changes. Stage (`git add`) or commit C and C++ edits before running `./utils/run_linters.sh --fix`. Note that `git-clang-format-19` exits with status `1` whenever it modifies files; re-run `./utils/run_linters.sh` after staging the formatted changes to confirm a clean pass.

### Enforced Checks

- **Python (`*.py`)**: `yapf3` (supports `--fix`).
- **Bazel (`BUILD`, `BUILD.bazel`, `*.bzl`, `MODULE.bazel`)**: `buildifier` (supports `--fix`).
- **SystemVerilog and Verilog (`*.sv`, `*.v`, excluding `hdl/verilog/rvv/`)**: `verible-verilog-format` (supports `--fix`).
- **C and C++ (`*.c`, `*.cc`, `*.cpp`, `*.h`, `*.hpp`)**: `clang-format-19` via `git-clang-format-19` on changed lines in diff mode, or full-file `clang-format-19` when targeting paths directly (supports `--fix`).
- **Scala (`*.scala`)**: `scalafmt` with `.scalafmt` (supports `--fix`).
- **Shell (`*.sh`, `*.bash`)**: `shellcheck -x` (check only; fix warnings manually).
- **Markdown (`*.md`)**: `mdl` using `.markdown_style.rb`, which requires 2-space indentation for unordered lists and ordered numbering for ordered lists (check only; fix violations manually).
- **Bzlmod Lockfile (`MODULE.bazel.lock`)**: When Bazel files change, the script runs `bazel mod deps --lockfile_mode=error` (or `--lockfile_mode=update` with `--fix`) and verifies that `MODULE.bazel.lock` has no unstaged or uncommitted changes.

## Waveform Traces and Debugging

Simulations in this repository generate `.fst` (Fast Signal Trace) waveforms.
Do not convert `.fst` files to `.vcd` using `fst2vcd` or custom scripts; large unpacked text dumps exhaust disk space and context windows.

Use `//utils/fst_query:fst_query` to inspect waveform metadata, explore scopes, sample signal states, and query transitions directly. Refer to [utils/fst_query/README.md](utils/fst_query/README.md) for usage instructions and workflows.
