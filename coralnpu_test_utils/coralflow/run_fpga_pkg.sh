#!/usr/bin/env bash
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

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -d "${SCRIPT_DIR}/tests" ]]; then
  ROOT_DIR="${SCRIPT_DIR}"
else
  ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
fi
cd "${ROOT_DIR}"

CURRENT_USER="$(id -un)"
VENV_DIR="${CORALFLOW_VENV:-/var/tmp/coralflow_venv_${CURRENT_USER}}"

resolve_python_bin() {
  if [[ -n "${PYTHON_BIN:-}" ]]; then
    echo "${PYTHON_BIN}"
    return
  fi
  if [[ -n "${VIRTUAL_ENV:-}" && -x "${VIRTUAL_ENV}/bin/python3" ]]; then
    echo "${VIRTUAL_ENV}/bin/python3"
    return
  fi
  if [[ -x "${ROOT_DIR}/.venv/bin/python3" ]]; then
    echo "${ROOT_DIR}/.venv/bin/python3"
    return
  fi
  if [[ -x "${VENV_DIR}/bin/python3" && -x "${VENV_DIR}/bin/pip" ]]; then
    echo "${VENV_DIR}/bin/python3"
    return
  fi
  echo "python3"
}

PYTHON_EXEC="$(resolve_python_bin)"

if ! "${PYTHON_EXEC}" -c "import numpy, elftools, ml_dtypes" >/dev/null 2>&1; then
  echo "[coralflow] Missing Python packages (numpy, pyelftools, ml-dtypes) in ${PYTHON_EXEC}." >&2
  echo "[coralflow] Setting up user virtual environment at ${VENV_DIR}..." >&2
  if [[ ! -x "${VENV_DIR}/bin/pip" ]]; then
    "${PYTHON_EXEC}" -m venv --clear --system-site-packages "${VENV_DIR}"
  fi
  "${VENV_DIR}/bin/pip" install --quiet numpy pyelftools ml-dtypes tqdm
  PYTHON_EXEC="${VENV_DIR}/bin/python3"
fi

export PYTHONPATH="${ROOT_DIR}:${PYTHONPATH:-}"
export CORALFLOW_TARGET="nexus_fpga"
export CORALFLOW_HIGHMEM="${CORALFLOW_HIGHMEM:-1}"

FIND_OUT="$(find tests -name 'test_*.py')"
if [[ -z "${FIND_OUT}" ]]; then
  echo "Error: No test_*.py script found under ${ROOT_DIR}/tests" >&2
  exit 1
fi
SORTED_OUT="$(printf '%s\n' "${FIND_OUT}" | sort)"
mapfile -t TEST_SCRIPTS <<< "${SORTED_OUT}"
if [[ "${#TEST_SCRIPTS[@]}" -gt 1 ]]; then
  echo "Error: Multiple test_*.py scripts found under ${ROOT_DIR}/tests (${TEST_SCRIPTS[*]}). Each test package must contain exactly one test script to avoid running the wrong test." >&2
  exit 1
fi
TEST_SCRIPT="${TEST_SCRIPTS[0]}"

exec "${PYTHON_EXEC}" "${TEST_SCRIPT}" "$@"
