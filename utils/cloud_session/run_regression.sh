#!/bin/bash
# Runs every Verilator cocotb or UVM test target that CI runs, in batches, and
# collects per-testcase results with parse_cocotb_results.py or
# parse_uvm_results.py.
#
# usage: utils/cloud_session/run_regression.sh {cocotb|uvm} OUT_DIR [BATCH_SIZE]
#
# Set REGRESSION_LIMIT=N to run only the first N targets (a quick check).
# Set REGRESSION_NOCACHE=1 to rerun tests whose results bazel has cached.
#
# Each batch's runfiles trees are deleted once it finishes: they hold thousands
# of symlinks per target (20-30 MB each), and all of them at once outgrow a
# cloud session's disk. Results stay in bazel-testlogs and OUT_DIR. Where
# GitHub archive downloads are blocked, see README.md for the dependencies.
set -uo pipefail

if (($# < 2)); then
  echo "usage: run_regression.sh {cocotb|uvm} OUT_DIR [BATCH_SIZE]" >&2
  exit 2
fi
kind=$1
out_dir=$2
batch_size=${3:-40}

repo=$(git rev-parse --show-toplevel)
cd "${repo}" || exit 1
mkdir -p "${out_dir}"
out_dir=$(realpath "${out_dir}")
bazel=(bazel --bazelrc=utils/cloud_session/cloud.bazelrc)
test_flags=()
if ((${REGRESSION_NOCACHE:-0})); then
  test_flags+=(--nocache_test_results)
fi

case "${kind}" in
  cocotb)
    query='kind(cocotb_test, tests(//...)) except attr(tags, "\bmanual\b", //...) except attr(tags, "\bvcs\b", //...)'
    runfiles_glob='*_cocotb_runner.sh.runfiles'
    parser=utils/cloud_session/parse_cocotb_results.py
    ;;
  uvm)
    query='kind(verilator_batch_uvm_test, tests(//...)) except attr(tags, "\bmanual\b", //...)'
    runfiles_glob='verilator_uvm_regression_*.runfiles'
    parser=utils/cloud_session/parse_uvm_results.py
    ;;
  *)
    echo "unknown kind: ${kind} (expected cocotb or uvm)" >&2
    exit 2
    ;;
esac

targets=${out_dir}/${kind}_targets.txt
log=${out_dir}/${kind}_bazel.log
"${bazel[@]}" query "${query}" 2>/dev/null | sort >"${targets}"
if ((${REGRESSION_LIMIT:-0} > 0)); then
  head -n "${REGRESSION_LIMIT}" "${targets}" >"${targets}.tmp"
  mv "${targets}.tmp" "${targets}"
fi
total=$(wc -l <"${targets}")
echo "${total} ${kind} targets; batches of ${batch_size}; log: ${log}"

batches=$(mktemp -d)
trap 'rm -rf "${batches}"' EXIT
split -l "${batch_size}" -d -a 3 "${targets}" "${batches}/batch_"
bin_dir=$("${bazel[@]}" info bazel-bin 2>/dev/null)

: >"${log}"
for batch in "${batches}"/batch_*; do
  now=$(date -u +%H:%M:%S)
  echo "=== ${batch##*/} ${now}" | tee -a "${log}"
  "${bazel[@]}" test --keep_going --curses=no --color=no \
    --show_progress_rate_limit=300 --test_output=summary "${test_flags[@]}" \
    --target_pattern_file="${batch}" >>"${log}" 2>&1
  echo "exit=$?" | tee -a "${log}"
  grep -E '^Executed' "${log}" | tail -n 1
  find "${bin_dir}" -type d -name "${runfiles_glob}" -prune -exec rm -rf {} +
done

testlogs=$(realpath bazel-testlogs)
python3 -I "${parser}" "${log}" "${targets}" "${testlogs}" \
  "${out_dir}/${kind}_results"
echo "Results: ${out_dir}/${kind}_results.{csv,log}"
