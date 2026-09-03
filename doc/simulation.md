# Simulation

## VCS Support

CoralNPU supports using VCS simulator. To enable VCS support, the following
environment variables need to be set:

```bash
export VCS_HOME=${PATH_TO_YOUR_VCS_HOME}
export LM_LICENSE_FILE=${YOUR_LICENSE_FILE}
```

`LD_LIBRARY_PATH` and `PATH` should also be updated.

```bash
export LD_LIBRARY_PATH="${VCS_HOME}"/linux64/lib
export PATH=$PATH:${VCS_HOME}/bin/
```

A VCS simulation can defined with the `vcs_testbench_test` rule. For example
use in a BUILD file:

```starlark
load("//rules:vcs.bzl", "vcs_testbench_test")

vcs_testbench_test(
    name = "foobar_tb",
    srcs = ["Foobar_tb.sv"],
    module = "Foobar_tb",
    deps = ":foobar",
)
```

By default, we disable VCS within bazel. Invoke
`bazel {build,run,test} --config=vcs` to enable VCS support.

### Troubleshooting

#### CCACHE and VCS (Read-only filesystem error)

If you encounter an error like `ccache: error: Failed to create temporary file ... Read-only file system` during a VCS simulation, it is because `ccache` is attempting to write to your home directory from within the Bazel sandbox.

**Fix:** Prepend `CCACHE_DISABLE=1` to your command:

```bash
bazel --action_env=CCACHE_DISABLE=1 test --config=vcs //...
```

### Code Coverage (vcs_binary)

`vcs_binary` targets (e.g. the simulators in `tests/vcs_sim/`) can be compiled
with VCS code coverage instrumentation via the `--//rules:vcs_coverage_types`
build setting:

```bash
bazel build --config=vcs \
    --//rules:vcs_coverage_types=line+cond+fsm+branch+tgl+assert \
    //tests/vcs_sim:rvv_core_mini_verification_axi_sim
```

Repeated `--//rules:vcs_coverage_types=` flags accumulate; values are joined
with `+` before being passed to `vcs -cm`.

When a simv is coverage-instrumented, the generated runner script keeps the
coverage database away from the binary itself. This matters because VCS derives
its default database location from the simv path (`<simv>.vdb`), which is inside
`bazel-out/`. A database left there by an earlier run or build no longer matches
the freshly linked coverage model, and the simulation aborts at startup with:

```text
Error-[MON-ICDF] Incompatible Code Coverage Directory
  Simulation could not read the database from the directory '...simv.vdb'.
```

The runner handles this automatically: it deletes any stale `<simv>.vdb` and
passes `-cm_dir` pointing at a fresh per-run directory (under `$TEST_TMPDIR`
inside bazel tests, otherwise the current working directory). After the run it
prints where the database was written.

To control where coverage lands yourself, either set an environment variable
(the same directory is reused across runs, so results accumulate and merge):

```bash
VCS_COVERAGE_DIR=$PWD/cov_rvv_add ./bazel-bin/tests/vcs_sim/rvv_core_mini_verification_axi_sim \
    +binary=$ELF +permissive -cm line+cond+fsm+branch+tgl+assert -l run.log
```

or pass an explicit runtime flag, which always wins:

```bash
./bazel-bin/tests/vcs_sim/rvv_core_mini_verification_axi_sim ... -cm_dir $PWD/my_cov
```

Generate a report from any of these databases with URG:

```bash
urg -dir <database_dir>/<simv>.vdb -report urgReport
```
