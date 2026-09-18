#!/bin/bash
# Copyright 2026 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# simulators_smoke_test.sh - VCS simulator smoke test

# --- Begin Bazel Bash Runfiles Library Boilerplate ---
# Sourced from @bazel_tools//tools/bash/runfiles
if [[ -z "${RUNFILES_DIR:-}" ]]; then
  if [[ -n "${PYTHON_RUNFILES:-}" ]]; then
    export RUNFILES_DIR="${PYTHON_RUNFILES}"
  elif [[ -n "${TEST_SRCDIR:-}" ]]; then
    export RUNFILES_DIR="${TEST_SRCDIR}"
  fi
fi
if [[ -n "${RUNFILES_DIR:-}" ]]; then
  export RUNFILES_MANIFEST_FILE="${RUNFILES_DIR}_manifest"
fi
# --- End Bazel Bash Runfiles Library Boilerplate ---

# Locate runfiles
function rlocation() {
  local path="$1"
  local stripped="${path#coralnpu_hw/}"
  for p in "${path}" "${stripped}" "_main/${stripped}"; do
    if [[ -n "${RUNFILES_DIR:-}" && -f "${RUNFILES_DIR}/${p}" ]]; then
      echo "${RUNFILES_DIR}/${p}"
      return 0
    elif [[ -n "${RUNFILES_MANIFEST_FILE:-}" && -f "${RUNFILES_MANIFEST_FILE}" ]]; then
      local res
      res="$(grep -m1 "^${p} " "${RUNFILES_MANIFEST_FILE}" | cut -d' ' -f2- || true)"
      if [[ -n "${res}" && -f "${res}" ]]; then
        echo "${res}"
        return 0
      fi
    fi
  done
  echo "Error: Runfiles not found: ${path}" >&2
  exit 1
}

SIMULATOR="$(rlocation "coralnpu_hw/tests/vcs_sim/rvv_core_mini_verification_axi_sim")"
ELF="$(rlocation "coralnpu_hw/tests/cocotb/nop_test.elf")"

if [[ -z "${SIMULATOR}" || ! -x "${SIMULATOR}" ]]; then
  echo "Error: VCS simulator binary not found or not executable" >&2
  exit 1
fi

if [[ -z "${ELF}" || ! -f "${ELF}" ]]; then
  echo "Error: nop_test.elf not found" >&2
  exit 1
fi

echo "Running VCS simulator smoke test with: ${ELF}"
"${SIMULATOR}" +binary="${ELF}" +cycles=10000
EXIT_CODE="$?"

if [[ "${EXIT_CODE}" -eq 0 ]]; then
  echo "Smoke test PASSED!"
else
  echo "Smoke test FAILED with exit code: ${EXIT_CODE}" >&2
fi

exit "${EXIT_CODE}"
