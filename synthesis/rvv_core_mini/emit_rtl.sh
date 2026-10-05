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
# Walk up until finding WORKSPACE or MODULE.bazel
CUR_DIR="${SCRIPT_DIR}"
REPO_ROOT=""
while [[ "${CUR_DIR}" != "/" ]]; do
  if [[ -f "${CUR_DIR}/WORKSPACE" || -f "${CUR_DIR}/MODULE.bazel" ]]; then
    REPO_ROOT="${CUR_DIR}"
    break
  fi
  CUR_DIR="$(dirname "${CUR_DIR}")"
done

if [[ -z "${REPO_ROOT}" ]]; then
  echo "Error: Could not locate Bazel workspace root." >&2
  exit 1
fi

DEST_ARG="${1:-${SCRIPT_DIR}/asap7/RvvCoreMiniAxi.sv}"
if [[ "${DEST_ARG}" = /* ]]; then
  DEST_SV="${DEST_ARG}"
else
  DEST_SV="$(pwd)/${DEST_ARG}"
fi
TARGET="//hdl/chisel/src/coralnpu:rvv_core_mini_axi_cc_library_emit_verilog"
EMITTED_REL="bazel-bin/hdl/chisel/src/coralnpu/RvvCoreMiniAxi.sv"

echo "========================================================================"
echo " Generating SystemVerilog for RvvCoreMiniAxi via Bazel Chisel Emission"
echo " Bazel Root:  ${REPO_ROOT}"
echo " Target:      ${TARGET}"
echo " Destination: ${DEST_SV}"
now="$(date)"
echo " Timestamp:   ${now}"
echo "========================================================================"

cd "${REPO_ROOT}"

# Ensure C compiler flag for host toolchain compatibility
CC_ENV="${CC:-gcc}"
if ! command -v "${CC_ENV}" > /dev/null 2>&1; then
  if command -v gcc > /dev/null 2>&1; then
    CC_ENV="gcc"
  elif command -v clang > /dev/null 2>&1; then
    CC_ENV="clang"
  fi
fi

echo ">>> Building Chisel emission target with CC=${CC_ENV}..."
t_start=$(date +%s)
bazel build --action_env=CC="${CC_ENV}" --repo_env=CC="${CC_ENV}" "${TARGET}"
t_end=$(date +%s)
build_dur=$((t_end - t_start))

if [[ ! -f "${EMITTED_REL}" ]]; then
  echo "Error: Expected emitted netlist not found at ${REPO_ROOT}/${EMITTED_REL}" >&2
  exit 1
fi

mkdir -p "$(dirname "${DEST_SV}")"
chmod u+w "${DEST_SV}" 2>/dev/null || true
cp -L "${EMITTED_REL}" "${DEST_SV}"

file_size=$(du -h "${DEST_SV}" | cut -f1)
echo ">>> [SUCCESS] Emitted ${DEST_SV} (${file_size}) in ${build_dur}s"
echo "========================================================================"
