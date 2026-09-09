# Verilator Bazel Dependency and Build Support

This directory contains vendored Bazel build definitions, code generation scripts, patches, and build-time dependencies required to build and execute [Verilator](https://www.veripool.org/verilator/) hermetically within Bazel.

---

## Upstream Provenance

The build definitions, wrapper scripts, and toolchain dependencies in this directory were vendored from:

* **Repository:** [https://github.com/hdl/bazel_rules_hdl](https://github.com/hdl/bazel_rules_hdl)
* **Commit:** [`7a1ba0e8d229200b4628e8a676917fc6b8e165d1`](https://github.com/hdl/bazel_rules_hdl/commit/7a1ba0e8d229200b4628e8a676917fc6b8e165d1)
* **Archive:** `https://github.com/hdl/bazel_rules_hdl/archive/7a1ba0e8d229200b4628e8a676917fc6b8e165d1.tar.gz`
* **License:** Apache License 2.0

---

## Manifest and File Breakdown

### 1. Verilator Generator Scripts (Python)

During Verilator's build process, code generators produce AST node classes, lexers, parsers, and configuration headers. The following Python scripts wrap Verilator's native generators to execute cleanly within hermetic Bazel actions:

| File | Upstream Path | Description |
|---|---|---|
| `verilator_astgen.py` | `dependency_support/verilator/private/verilator_astgen.py` | Wrapper around Verilator's `src/astgen` Python script. Dynamically passes `-I` include directories for source files and copies generated AST headers (`V3Ast__gen_*.h`, `V3Ast__gen_*.cpp`) to Bazel action output paths. |
| `verilator_bisonpre.py` | `dependency_support/verilator/private/verilator_bisonpre.py` | Wrapper around Verilator's `src/bisonpre` script. Suppresses verbose stdout during successful execution to minimize Bazel build log noise, surfacing stdout/stderr only on failure. |
| `verilator_flexfix.py` | `dependency_support/verilator/private/verilator_flexfix.py` | Wrapper around Verilator's `src/flexfix` script. Post-processes Flex output to adjust symbol names and formatting for compatibility with Verilator's parser. |
| `verilator_version.py` | `dependency_support/verilator/private/verilator_version.py` | Parses Verilator's `Changes` changelog file to extract the semantic version string for inclusion into generated headers (`verilator_version.h`). |
| `verilator_build_template.py` | `dependency_support/verilator/private/verilator_build_template.py` | Substitutes build configuration variables (including version and makefile variables) into Verilator source templates such as `src/Makefile_obj.in`. |

### 2. Verilator Build Rules and Build Files

| File | Upstream Path | Description |
|---|---|---|
| `verilator.BUILD.bazel` | `dependency_support/verilator/bundled.BUILD.bazel` | Complete Bazel build definition for the `@verilator` external repository (Verilator v5.052, tag `refs/tags/v5.052`). Defines `verilator_bin`, runtime C++ libraries (`libverilated`), headers, and runfiles. |
| `verilator_utils.bzl` | `dependency_support/verilator/private/verilator_utils.bzl` | Starlark rule macros defining the custom Bazel actions that invoke `verilator_astgen.py` and `verilator_bisonpre.py`. Updated to refer to tools at `@coralnpu_hw//third_party/verilator:...`. |
| `0001-Remove-autodetect-of-VERILATOR_ROOT.patch` | `dependency_support/verilator/0001-Remove-autodetect-of-VERILATOR_ROOT.patch` | Patch applied to `@verilator` to disable dynamic auto-detection of `VERILATOR_ROOT` from executable paths, ensuring Verilator uses Bazel runfiles paths consistently. |
| `BUILD.bazel` | (Local) | Declares `py_binary` targets for the vendored Python helper scripts and exports files for external repository references. |

### 3. Build-Time Toolchain Dependencies

Verilator requires `flex`, `bison`, `m4`, `zlib`, and `gnulib` during its build. The build files and support macros for these dependencies were also imported from `bazel_rules_hdl` at commit `7a1ba0e8d229200b4628e8a676917fc6b8e165d1`:

| File | Upstream Path | Description |
|---|---|---|
| `flex.bzl` | `dependency_support/verilator/private/flex.bzl` | Custom `genlex` Starlark rule integrating `@com_github_westes_flex//:flex` and `@org_gnu_m4//:m4` into Bazel actions. |
| `copy.bzl` | `dependency_support/copy.bzl` | Starlark helper macro for copying files across Bazel actions. |
| `pseudo_configure.bzl` | `dependency_support/pseudo_configure.bzl` | Macro creating configured headers without running autoconf scripts. |
| `zlib.BUILD` | `dependency_support/net_zlib/bundled.BUILD.bazel` | Build definition for `zlib` (v1.2.11, fetched from `https://github.com/madler/zlib`). |
| `m4.BUILD` | `dependency_support/org_gnu_m4/bundled.BUILD.bazel` | Build definition for GNU `m4` (v1.4.18, fetched from GNU mirrors). |
| `flex.BUILD` | `dependency_support/com_github_westes_flex/bundled.BUILD.bazel` | Build definition for `flex` (v2.6.4, fetched from `https://github.com/westes/flex`). |
| `bison.BUILD` | `dependency_support/org_gnu_bison/bundled.BUILD.bazel` | Build definition for GNU `bison` (v3.5, fetched from GNU mirrors). Modified to remove deprecated `path = "data"` on filegroup definitions for modern Bazel compatibility. |
| `gnulib.bzl` | `dependency_support/org_gnu_gnulib/org_gnu_gnulib.bzl` | Repository rule macro defining the `@org_gnu_gnulib` external archive (commit `dbc5605c3b37a14d7c7e56fcf6c305d542e73210` from `https://github.com/coreutils/gnulib`). |
| `gnulib/` | `dependency_support/org_gnu_gnulib/*` | Contains `gnulib.BUILD`, Darwin/Linux platform configuration headers (`config-darwin.h`, `config-linux.h`, `config.in.h`), and `stop_using_sigstksz.patch` required by Bison and M4. |

---

## Related Files

* **`rules/cocotb_wrapper.py`**:
  * Vendored from `bazel_rules_hdl` (`cocotb/cocotb_wrapper.py`) at commit `7a1ba0e8d229200b4628e8a676917fc6b8e165d1`.
  * Licensed under Apache 2.0 (Copyright 2023 Antmicro).
  * Modified for CoralNPU to support running pre-compiled VCS simulation binaries, location expansion for test output XML files, and execution status code handling.
* **`rules/coco_tb.bzl`**:
  * CoralNPU's native cocotb Bazel rule implementation.
* **`rules/repos.bzl`**:
  * Defines repository rules (`coralnpu_repos`, `coralnpu_repos2`) pointing to the build files in this directory.
