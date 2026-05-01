#!/bin/bash
set -e

# ══════════════════════════════════════════════════════════════════════════════
#  Configuration
# ══════════════════════════════════════════════════════════════════════════════

# ── Defaults ──────────────────────────────────────────────────────────────────
MAX_RETRIES=3
SKIP_COCOTB=false
SKIP_BUILD=false
SKIP_SIM=false
EXTRA_BAZEL_ARGS=""

# ── Expected tool versions (from README System Requirements) ─────────────────
REQUIRED_BAZEL_VERSION="7.4.1"
REQUIRED_PYTHON_MIN="3.9"
REQUIRED_PYTHON_MAX="3.12"

# ── Network error patterns ───────────────────────────────────────────────────
# Bazel output is scanned for these patterns to decide whether to retry.
# To add a new pattern, simply append a new quoted string to the array below.
# The pattern is used with grep -E (extended regex), so regex metacharacters
# (\. * + ? [ ] ( ) { } | ^ $) must be escaped.  Examples:
#   "Connection timed out"       → literal substring match
#   "java\.io\.IOException"      → regex-escaped dots
#   "Bytes read.*but wanted"     → regex wildcard for variable byte counts
NETWORK_ERROR_PATTERNS=(
  "Error downloading"
  "ContentLengthMismatchException"
  "Bytes read.*but wanted"
  "java\.io\.IOException"
)

# Build a single grep pattern from the array
GREP_PATTERN=$(IFS='|'; echo "${NETWORK_ERROR_PATTERNS[*]}")

# ══════════════════════════════════════════════════════════════════════════════
#  Prerequisite checks
# ══════════════════════════════════════════════════════════════════════════════

# Compare two dotted version strings.  Returns 0 if $1 >= $2, 1 otherwise.
version_ge() {
  local a=(${1//./ }) b=(${2//./ })
  for i in 0 1 2; do
    local ai=${a[$i]:-0} bi=${b[$i]:-0}
    [[ "$ai" -gt "$bi" ]] && return 0
    [[ "$ai" -lt "$bi" ]] && return 1
  done
  return 0
}

check_prerequisites() {
  local fail=false

  echo ""
  echo "────────────────────────────────────────────"
  echo " Checking system prerequisites..."
  echo "────────────────────────────────────────────"

  # ── Bazel ──────────────────────────────────────────────────────────────────
  if command -v bazel &>/dev/null; then
    local bazel_ver
    bazel_ver=$(bazel version 2>/dev/null | grep -oP 'Build label: \K[\d\.]+')
    if [[ "$bazel_ver" == "$REQUIRED_BAZEL_VERSION" ]]; then
      echo "  ✓ Bazel ${bazel_ver}  (== ${REQUIRED_BAZEL_VERSION})"
    else
      echo "  ✗ Bazel ${bazel_ver:-<not found>} — need exactly ${REQUIRED_BAZEL_VERSION}"
      fail=true
    fi
  else
    echo "  ✗ bazel not found in PATH"
    fail=true
  fi

  # ── Python ─────────────────────────────────────────────────────────────────
  if command -v python3 &>/dev/null; then
    local py_ver
    py_ver=$(python3 --version 2>&1 | grep -oP 'Python \K[\d\.]+')
    # Extract major.minor (first two components) for range comparison.
    # The README says "3.9–3.12", meaning any 3.12.x patch is acceptable.
    local py_major_minor="${py_ver%.*}"
    if version_ge "$py_ver" "$REQUIRED_PYTHON_MIN"; then
      if version_ge "$REQUIRED_PYTHON_MAX" "$py_major_minor"; then
        echo "  ✓ Python ${py_ver}  (${REQUIRED_PYTHON_MIN}–${REQUIRED_PYTHON_MAX})"
      else
        echo "  ✗ Python ${py_ver} — need ≤ ${REQUIRED_PYTHON_MAX}.x (3.13 support in progress)"
        fail=true
      fi
    else
      echo "  ✗ Python ${py_ver} — need ≥ ${REQUIRED_PYTHON_MIN}"
      fail=true
    fi
  else
    echo "  ✗ python3 not found in PATH"
    fail=true
  fi

  # ── SRecord (srec_cat) ────────────────────────────────────────────────────
  if command -v srec_cat &>/dev/null; then
    echo "  ✓ srec_cat found"
  else
    echo "  ✗ srec_cat not found in PATH (install SRecord: https://srecord.sourceforge.net/)"
    fail=true
  fi

  echo "────────────────────────────────────────────"

  if [[ "$fail" == "true" ]]; then
    echo ""
    echo "✗ One or more prerequisites are missing.  Please install them and re-run."
    exit 1
  fi

  echo "✓ All prerequisites satisfied."
  echo ""
}

# ── Argument parsing ─────────────────────────────────────────────────────────
show_help() {
  echo "Usage: $0 [OPTIONS]"
  echo ""
  echo "Run the Coral NPU Quick Start steps with network-error-aware retry."
  echo ""
  echo "Steps (matching README Quick Start):"
  echo "  1. Run cocotb test suite:  bazel run //tests/cocotb:core_mini_axi_sim_cocotb"
  echo "  2. Build example binary:   bazel build //examples:coralnpu_v2_hello_world_add_floats"
  echo "  3. Build Verilator sim:    bazel build //tests/verilator_sim:core_mini_axi_sim"
  echo "  4. Run binary on simulator"
  echo ""
  echo "Options:"
  echo "  --max_retries N   Max retries on network errors per step (default: 3)"
  echo "  --skip_cocotb     Skip the cocotb test suite step"
  echo "  --skip_build      Skip the binary & simulator build steps"
  echo "  --skip_sim        Skip the simulator run step"
  echo "  -- [BAZEL_ARGS]   Extra arguments passed to all bazel commands"
  echo "  -h, --help        Show this help message"
  exit 0
}

while [[ $# -gt 0 ]]; do
  case $1 in
    -h|--help)
      show_help
      ;;
    --max_retries)
      MAX_RETRIES="$2"
      shift 2
      ;;
    --skip_cocotb)
      SKIP_COCOTB=true
      shift
      ;;
    --skip_build)
      SKIP_BUILD=true
      shift
      ;;
    --skip_sim)
      SKIP_SIM=true
      shift
      ;;
    --)
      shift
      EXTRA_BAZEL_ARGS="$*"
      break
      ;;
    *)
      echo "Unknown argument: $1"
      echo ""
      show_help
      ;;
  esac
done

# ── Helper: check if output contains a network error ─────────────────────────
is_network_error() {
  local logfile="$1"
  grep -qiE "${GREP_PATTERN}" "${logfile}" 2>/dev/null
}

# ── Helper: run a bazel command with network-error-aware retry ───────────────
# Usage: run_bazel_with_retry "description" <command...>
# Returns 0 on success, exits with the command's exit code on non-network failure,
# exits 1 after exhausting retries on persistent network errors.
run_bazel_with_retry() {
  local desc="$1"
  shift
  local cmd="$*"
  local logfile
  logfile=$(mktemp /tmp/bazel_run_XXXXXX.log)

  echo ""
  echo "=========================================="
  echo " ${desc}"
  echo "=========================================="
  echo "Command: ${cmd}"
  echo "Max retries: ${MAX_RETRIES} (network errors only)"
  echo "=========================================="

  for ((i=1; ; i++)); do
    echo ""
    echo "── ${desc} — Attempt ${i} ─────────────────"

    set +e
    ${cmd} 2>&1 | tee "${logfile}"
    local exit_code=${PIPESTATUS[0]}
    set -e

    if [[ ${exit_code} -eq 0 ]]; then
      echo "✓ ${desc} — PASSED on attempt ${i}."
      rm -f "${logfile}"
      return 0
    fi

    # Check if the failure is due to a network error
    if is_network_error "${logfile}"; then
      echo ""
      echo "⚠ Network error detected (exit code: ${exit_code})."
      if [[ "${MAX_RETRIES}" -gt 0 ]] && [[ "${i}" -ge "${MAX_RETRIES}" ]]; then
        echo "Exhausted all ${MAX_RETRIES} retries for: ${desc}"
        rm -f "${logfile}"
        exit 1
      fi
      local wait_time=$((RANDOM % 51 + 10))
      echo "Retrying in ${wait_time}s..."
      sleep "${wait_time}"
    else
      # Not a network error — fail immediately, no retry
      echo ""
      echo "✗ ${desc} — FAILED (exit code: ${exit_code})."
      echo "  Not a network error — not retrying."
      rm -f "${logfile}"
      exit ${exit_code}
    fi
  done
}

# ══════════════════════════════════════════════════════════════════════════════
#  Quick Start Steps
# ══════════════════════════════════════════════════════════════════════════════

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  Coral NPU — Core Mini AXI Cocotb Simulation Quick Start     ║"
echo "╚══════════════════════════════════════════════════════════════╝"

# Verify system requirements before doing anything else
check_prerequisites

# ── Step 1: Run cocotb test suite ─────────────────────────────────────────────
if [[ "${SKIP_COCOTB}" == "false" ]]; then
  run_bazel_with_retry \
    "Step 1/4: Run cocotb test suite" \
    bazel run //tests/cocotb:core_mini_axi_sim_cocotb ${EXTRA_BAZEL_ARGS}
else
  echo ""
  echo "── Step 1/4: Run cocotb test suite — SKIPPED ──"
fi

# ── Step 2: Build a binary ────────────────────────────────────────────────────
if [[ "${SKIP_BUILD}" == "false" ]]; then
  run_bazel_with_retry \
    "Step 2/4: Build example binary" \
    bazel build //examples:coralnpu_v2_hello_world_add_floats ${EXTRA_BAZEL_ARGS}
else
  echo ""
  echo "── Step 2/4: Build example binary — SKIPPED ──"
fi

# ── Step 3: Build the simulator ───────────────────────────────────────────────
if [[ "${SKIP_BUILD}" == "false" ]]; then
  run_bazel_with_retry \
    "Step 3/4: Build Verilator simulator" \
    bazel build //tests/verilator_sim:core_mini_axi_sim ${EXTRA_BAZEL_ARGS}
else
  echo ""
  echo "── Step 3/4: Build Verilator simulator — SKIPPED ──"
fi

# ── Step 4: Run the binary on the simulator ───────────────────────────────────
if [[ "${SKIP_SIM}" == "false" ]]; then
  echo ""
  echo "=========================================="
  echo " Step 4/4: Run binary on simulator"
  echo "=========================================="

  # Resolve the ELF path dynamically via bazel cquery
  ELF_PATH=$(bazel cquery //examples:coralnpu_v2_hello_world_add_floats \
    --output=files 2>/dev/null | grep "\.elf$")
  EXEC_ROOT=$(bazel info execution_root)
  ELF_FULL_PATH="${EXEC_ROOT}/${ELF_PATH}"

  echo "ELF: ${ELF_FULL_PATH}"
  echo ""

  ./bazel-bin/tests/verilator_sim/core_mini_axi_sim --binary "${ELF_FULL_PATH}"
  echo "✓ Step 4/4: Simulator run — PASSED."
else
  echo ""
  echo "── Step 4/4: Run binary on simulator — SKIPPED ──"
fi

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  All Quick Start steps completed successfully.               ║"
echo "╚══════════════════════════════════════════════════════════════╝"
