#!/bin/bash

# Exit on error
set -e

TEST_NAME=$(basename "$0")

# Identify runfiles root
if [[ -z "${RUNFILES_DIR}" ]]; then
  # Fallback for some environments
  if [[ -d "${0}.runfiles" ]]; then
    RUNFILES_DIR="${0}.runfiles"
  else
    RUNFILES_DIR="$(pwd)"
  fi
fi

# Locate Verilator and firtool within runfiles
VERILATOR_BIN=$(find "${RUNFILES_DIR}" -name verilator_bin -print -quit)
FIRTOOL_BIN=$(find "${RUNFILES_DIR}" -name firtool -ipath '*linux-x64*' -print -quit)
if [[ -z "${FIRTOOL_BIN}" ]]; then
  FIRTOOL_BIN=$(find "${RUNFILES_DIR}" -name firtool -print -quit)
fi

if [[ -z "${VERILATOR_BIN}" ]]; then
  echo "Error: Could not find verilator_bin in ${RUNFILES_DIR}"
  exit 1
fi

if [[ -z "${FIRTOOL_BIN}" ]]; then
  echo "Error: Could not find firtool in ${RUNFILES_DIR}"
  exit 1
fi

VERILATOR_ROOT=$(dirname "${VERILATOR_BIN}")

# Create a temporary directory for the hermetic tool wrappers
WRAPPER_DIR=$(mktemp -d)
trap 'rm -rf "${WRAPPER_DIR}"' EXIT

# Generate a wrapper script named 'verilator' that FuseSoC/Chisel expects
cat >"${WRAPPER_DIR}/verilator" <<EOF
#!/bin/bash
export VERILATOR_PYTHON3=\$(which python3)
export VERILATOR_AR=\$(which ar)
export VERILATOR_CXX=\$(which g++)
export VERILATOR_ROOT="${VERILATOR_ROOT}"

args=()
while [[ \${#} -gt 0 ]]; do
  if [[ "\${1}" == "-j" ]]; then
    args+=("-j" "1")
    shift 2
  elif [[ "\${1}" =~ ^-j[0-9]+\$ ]]; then
    args+=("-j1")
    shift
  else
    args+=("\${1}")
    shift
  fi
done

exec "${VERILATOR_BIN}" "\${args[@]}"
EOF
chmod +x "${WRAPPER_DIR}/verilator"

# Generate a wrapper script named 'firtool' that disables MLIR thread-pool
# oversubscription inside parallel test sandboxes.
cat >"${WRAPPER_DIR}/firtool" <<EOF
#!/bin/bash
extra_args=()
has_disable=0
for arg in "\$@"; do
  if [[ "\${arg}" == "--mlir-disable-threading" ]]; then
    has_disable=1
    break
  fi
done
if [[ "\${has_disable}" -eq 0 ]]; then
  extra_args+=("--mlir-disable-threading")
fi
exec "${FIRTOOL_BIN}" "\${extra_args[@]}" "\$@"
EOF
chmod +x "${WRAPPER_DIR}/firtool"

# Configure environment to use our hermetic tools
export PATH="${WRAPPER_DIR}:${PATH}"
export CHISEL_FIRTOOL_PATH="${WRAPPER_DIR}"

# Find and run the actual scalatest binary
SCALATEST_BIN=$(find "${RUNFILES_DIR}" -name "${TEST_NAME}_scalatest" -print -quit)

if [[ -z "${SCALATEST_BIN}" ]]; then
  echo "Error: Could not find scalatest binary ${TEST_NAME}_scalatest"
  exit 1
fi

exec "${SCALATEST_BIN}" "$@"
