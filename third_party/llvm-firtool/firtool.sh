#!/bin/bash

SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"
if [[ -d "${0}.runfiles" ]]; then
  ROOTDIR="${0}.runfiles"
else
  # The script lives at <runfiles>/_main/third_party/llvm-firtool/firtool.sh
  # and the @llvm_firtool repo is at <runfiles>/llvm_firtool/.
  # Walk three levels up to land at runfiles root, then find it.
  ROOTDIR="${SCRIPT_DIR}/../../../"
fi

FIRTOOL_EXE=$(find "${ROOTDIR}" -name 'firtool' -ipath '*linux-x64*' -print -quit)

extra_args=()
if [[ "${FIRTOOL_ENABLE_THREADING:-0}" != "1" ]]; then
  has_disable=0
  for arg in "$@"; do
    if [[ "${arg}" == "--mlir-disable-threading" ]]; then
      has_disable=1
      break
    fi
  done
  if [[ "${has_disable}" -eq 0 ]]; then
    extra_args+=("--mlir-disable-threading")
  fi
fi

exec "${FIRTOOL_EXE}" "${extra_args[@]}" "$@"
