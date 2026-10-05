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

# Defensive fallback for non-root container runs
export HOME="${HOME:-/tmp}"
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-/tmp/cache}"
export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-/tmp/config}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Robust ORFS discovery (Environment -> Local Repo -> System Root)
# TODO(coralnpu): Walking 5 levels up to find OpenROAD-flow-scripts in the repo
# workspace root is brittle. Integrate OpenROAD-flow-scripts into the default repo
# manifest so it is checked out into a standardized location automatically.
WORKSPACE_ROOT="$(cd "${SCRIPT_DIR}/../../../../.." && pwd)"

if [[ -n "${OPENROAD_FLOW_HOME:-}" && -d "${OPENROAD_FLOW_HOME}" ]]; then
  ORFS_ROOT="${OPENROAD_FLOW_HOME}"
elif [[ -d "/OpenROAD-flow-scripts" ]]; then
  ORFS_ROOT="/OpenROAD-flow-scripts"
elif [[ -d "${WORKSPACE_ROOT}/OpenROAD-flow-scripts" ]]; then
  ORFS_ROOT="${WORKSPACE_ROOT}/OpenROAD-flow-scripts"
else
  echo "Error: Could not locate OpenROAD-flow-scripts directory." >&2
  exit 1
fi

if [[ -f "${ORFS_ROOT}/env.sh" ]]; then
  # shellcheck source=/dev/null
  source "${ORFS_ROOT}/env.sh"
fi

export FLOW_HOME="${ORFS_ROOT}/flow"
export YOSYS_EXE="${YOSYS_EXE:-yosys}"
export KEEP_VARS=1

show_help() {
  cat << 'EOF'
Usage: run_full_flow.sh [OPTIONS]

End-to-End 16-Partition Fast Flow for RvvCoreMiniAxi on ASAP7.

Options:
  --from <0-7|name>   Start execution from a specific stage:
                        0 | rerun     : Full clean rerun from scratch (--rerun)
                        1 | synth     : Synthesis & 16-Partitioning (from RTL)
                        2 | floorplan : Floorplanning (from 1_synth.odb)
                        3 | place     : Global & Detailed Placement (from 2_floorplan.odb)
                        4 | cts       : Clock Tree Synthesis (from 3_place.odb)
                        5 | grt       : Global Routing (from 4_cts.odb)
                        6 | route     : Detailed Routing (from 5_1_grt.odb)
                        7 | report    : Post-Route Extraction & STA Reporting (from 5_2_route.odb)
  --resume            Automatically resume from latest detected completed checkpoint
  --rerun             Force full clean rerun from scratch without prompting
  --synth-only        Stop after synthesis & netlist stitching (Stages 1-3), skipping PnR
  --dry-run           Print flow steps without executing synthesis or PnR commands
  -h, --help          Display this help message and exit

Interactive Behavior:
  When existing checkpoints are found in the results directory and no CLI bypass
  flag (--from, --resume, --rerun) is supplied:
    - In an interactive terminal, prompts for stage selection (0-7 or name).
    - In a non-interactive environment, exits with error code 1.
EOF
}

stage_to_canonical() {
  local input="$1"
  STAGE_CANONICAL=""
  case "${input}" in
    0|rerun)     STAGE_CANONICAL="0 rerun" ;;
    1|synth)     STAGE_CANONICAL="1 synth" ;;
    2|floorplan) STAGE_CANONICAL="2 floorplan" ;;
    3|place)     STAGE_CANONICAL="3 place" ;;
    4|cts)       STAGE_CANONICAL="4 cts" ;;
    5|grt)       STAGE_CANONICAL="5 grt" ;;
    6|route)     STAGE_CANONICAL="6 route" ;;
    7|report)    STAGE_CANONICAL="7 report" ;;
    *)           STAGE_CANONICAL="" ;;
  esac
}



detect_latest_checkpoint_stage() {
  STAGE_DETECTED="1 synth"
  if [[ -d "${RESULTS_DIR}" ]]; then
    if [[ -f "${RESULTS_DIR}/5_2_route.odb" || -f "${RESULTS_DIR}/5_route.odb" || -f "${RESULTS_DIR}/6_final.odb" ]]; then
      STAGE_DETECTED="7 report"
    elif [[ -f "${RESULTS_DIR}/5_1_grt.odb" ]]; then
      STAGE_DETECTED="6 route"
    elif [[ -f "${RESULTS_DIR}/4_cts.odb" || -f "${RESULTS_DIR}/4_1_cts.odb" ]]; then
      STAGE_DETECTED="5 grt"
    elif [[ -f "${RESULTS_DIR}/3_place.odb" || -f "${RESULTS_DIR}/3_5_place_dp.odb" ]]; then
      STAGE_DETECTED="4 cts"
    elif [[ -f "${RESULTS_DIR}/2_floorplan.odb" || -f "${RESULTS_DIR}/2_4_floorplan_pdn.odb" ]]; then
      STAGE_DETECTED="3 place"
    elif [[ -f "${RESULTS_DIR}/1_synth.odb" ]]; then
      STAGE_DETECTED="2 floorplan"
    fi
  fi
}

check_required_checkpoint() {
  local stage_num="$1"
  local required_file=""
  case "${stage_num}" in
    2) required_file="${RESULTS_DIR}/1_synth.odb" ;;
    3) required_file="${RESULTS_DIR}/2_floorplan.odb" ;;
    4) required_file="${RESULTS_DIR}/3_place.odb" ;;
    5) required_file="${RESULTS_DIR}/4_cts.odb" ;;
    6) required_file="${RESULTS_DIR}/5_1_grt.odb" ;;
    7) required_file="${RESULTS_DIR}/5_2_route.odb" ;;
    *) ;;
  esac
  if [[ -n "${required_file}" && ! -f "${required_file}" ]]; then
    if [[ "${stage_num}" -eq 7 && -f "${RESULTS_DIR}/5_route.odb" ]]; then
      return 0
    fi
    if [[ "${DRY_RUN}" -eq 1 ]]; then
      echo ">>> [DRY-RUN] [WARNING] Required checkpoint '${required_file}' does not exist on disk."
      return 0
    fi
    echo "Error: Required checkpoint '${required_file}' not found for stage ${stage_num} (${TARGET_STAGE_NAME})." >&2
    exit 1
  fi
}

# CLI Argument Parsing
CLI_MODE=""
FROM_ARG=""
DRY_RUN="${DRY_RUN:-0}"
SYNTH_ONLY="${SYNTH_ONLY:-0}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --from=*)
      CLI_MODE="from"
      FROM_ARG="${1#*=}"
      shift
      ;;
    --from)
      if [[ $# -lt 2 ]]; then
        echo "Error: --from requires an argument (0-7 or stage name)" >&2
        exit 1
      fi
      CLI_MODE="from"
      FROM_ARG="$2"
      shift 2
      ;;
    --resume)
      CLI_MODE="resume"
      shift
      ;;
    --rerun)
      CLI_MODE="rerun"
      shift
      ;;
    --synth-only)
      SYNTH_ONLY=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      show_help
      exit 0
      ;;
    *)
      echo "Error: Unknown argument: $1" >&2
      echo "Run '$0 --help' for usage." >&2
      exit 1
      ;;
  esac
done

VARIANT="${VARIANT:-base}"
export WORK_HOME="${WORK_HOME:-${SCRIPT_DIR}/work}"
export PLATFORM="${PLATFORM:-asap7}"
export DESIGN="${DESIGN:-RvvCoreMiniAxi}"
export FLOW_HOME="${FLOW_HOME:-${ORFS_ROOT}/flow}"
export SCRIPTS_DIR="${SCRIPTS_DIR:-${FLOW_HOME}/scripts}"
export PLATFORM_DIR="${PLATFORM_DIR:-${FLOW_HOME}/platforms/${PLATFORM}}"
export RESULTS_DIR="${RESULTS_DIR:-${WORK_HOME}/results/${PLATFORM}/${DESIGN}/${VARIANT}}"
export LOG_DIR="${LOG_DIR:-${WORK_HOME}/logs/${PLATFORM}/${DESIGN}/${VARIANT}}"
export REPORTS_DIR="${REPORTS_DIR:-${WORK_HOME}/reports/${PLATFORM}/${DESIGN}/${VARIANT}}"
export OBJECTS_DIR="${OBJECTS_DIR:-${WORK_HOME}/objects/${PLATFORM}/${DESIGN}/${VARIANT}}"
export SDC_FILE="${SDC_FILE:-${SCRIPT_DIR}/constraint.sdc}"
export DESIGN_CONFIG="${DESIGN_CONFIG:-${SCRIPT_DIR}/config.mk}"
export VERILOG_FILES="${VERILOG_FILES:-${SCRIPT_DIR}/RvvCoreMiniAxi.sv ${ORFS_ROOT}/flow/platforms/asap7/verilog/fakeram_512x128.sv ${ORFS_ROOT}/flow/platforms/asap7/verilog/fakeram_2048x128.sv}"
export NUM_CORES="${NUM_CORES:-64}"
export ROUTING_CORES="${ROUTING_CORES:-64}"
export KEEP_VARS=1

# Stage Resolution
TARGET_STAGE_NUM=""
TARGET_STAGE_NAME=""

if [[ "${CLI_MODE}" == "from" ]]; then
  stage_to_canonical "${FROM_ARG}"
  if [[ -z "${STAGE_CANONICAL}" ]]; then
    echo "Error: Invalid stage '${FROM_ARG}'. Must be 0-7 or one of: rerun, synth, floorplan, place, cts, grt, route, report." >&2
    exit 1
  fi
  read -r TARGET_STAGE_NUM TARGET_STAGE_NAME <<< "${STAGE_CANONICAL}"
elif [[ "${CLI_MODE}" == "resume" ]]; then
  detect_latest_checkpoint_stage
  read -r TARGET_STAGE_NUM TARGET_STAGE_NAME <<< "${STAGE_DETECTED}"
  echo ">>> [RESUME] Automatically resuming from stage ${TARGET_STAGE_NUM} (${TARGET_STAGE_NAME})."
elif [[ "${CLI_MODE}" == "rerun" ]]; then
  TARGET_STAGE_NUM=0
  TARGET_STAGE_NAME="rerun"
else
  # No CLI bypass flag provided. Check results directory for existing checkpoints.
  has_checkpoints=0
  if [[ -d "${RESULTS_DIR}" ]]; then
    shopt -s nullglob
    odbs=("${RESULTS_DIR}"/*.odb)
    shopt -u nullglob
    if [[ ${#odbs[@]} -gt 0 ]]; then
      has_checkpoints=1
    fi
  fi

  if [[ "${has_checkpoints}" -eq 0 ]]; then
    TARGET_STAGE_NUM=1
    TARGET_STAGE_NAME="synth"
    echo ">>> No existing checkpoints found in ${RESULTS_DIR}. Proceeding automatically from stage 1 (synth)."
  else
    if [[ -t 0 ]]; then
      echo "========================================================================"
      echo " Existing checkpoints detected in: ${RESULTS_DIR}"
      echo " Available stages to run:"
      echo "   0 / rerun     : Full clean rerun from scratch (--rerun)"
      echo "   1 / synth     : Synthesis & 16-Partitioning (from RTL)"
      echo "   2 / floorplan : Floorplanning (from 1_synth.odb)"
      echo "   3 / place     : Global & Detailed Placement (from 2_floorplan.odb)"
      echo "   4 / cts       : Clock Tree Synthesis (from 3_place.odb)"
      echo "   5 / grt       : Global Routing (from 4_cts.odb)"
      echo "   6 / route     : Detailed Routing (from 5_1_grt.odb)"
      echo "   7 / report    : Post-Route Extraction & STA Reporting (from 5_2_route.odb)"
      echo "========================================================================"
      while true; do
        printf "Select stage to run from [0-7 or name]: "
        if ! read -r user_choice; then
          echo ""
          echo "Error: End of input encountered." >&2
          exit 1
        fi
        stage_to_canonical "${user_choice}"
        if [[ -n "${STAGE_CANONICAL}" ]]; then
          read -r TARGET_STAGE_NUM TARGET_STAGE_NAME <<< "${STAGE_CANONICAL}"
          break
        fi
        echo "Invalid choice '${user_choice}'. Please enter 0-7 or one of: rerun, synth, floorplan, place, cts, grt, route, report."
      done
    else
      echo "Error: Existing checkpoints found in non-interactive environment. Please specify --resume, --rerun, or --from <stage>." >&2
      exit 1
    fi
  fi
fi

echo "========================================================================"
echo " Starting End-to-End 16-Partition Fast Flow for RvvCoreMiniAxi on ASAP7"
echo " Starting Stage: ${TARGET_STAGE_NUM} (${TARGET_STAGE_NAME})"
FLOW_START_TIME="$(date)"
echo " Start Time:     ${FLOW_START_TIME}"
echo "========================================================================"

T_START=$(date +%s)

if [[ "${TARGET_STAGE_NUM}" -eq 0 ]]; then
  echo ">>> [STAGE 0] Full clean rerun selected. Resetting checkpoints in ${RESULTS_DIR}..."
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    echo ">>> [DRY-RUN] Would remove existing .odb files in ${RESULTS_DIR}"
  else
    if [[ -d "${RESULTS_DIR}" ]]; then
      rm -f "${RESULTS_DIR}"/*.odb
    fi
  fi
fi

if [[ "${TARGET_STAGE_NUM}" -le 1 ]]; then
  # --- Pre-Stage: RTL Verification & Emission ---
  read -r TOP_SV _ <<< "${VERILOG_FILES}"
  if [[ ! -f "${TOP_SV}" ]]; then
    echo ">>> [PRE-STAGE] Top-level RTL ${TOP_SV} not found. Checking for Bazel..."
    if command -v bazel > /dev/null 2>&1; then
      echo ">>> [PRE-STAGE] Emitting ${TOP_SV} via Bazel Chisel pipeline..."
      if [[ "${DRY_RUN}" -eq 1 ]]; then
        echo ">>> [DRY-RUN] Would run: ${SCRIPT_DIR}/../emit_rtl.sh ${TOP_SV}"
      else
        "${SCRIPT_DIR}/../emit_rtl.sh" "${TOP_SV}"
      fi
    else
      echo ">>> [ERROR] Top-level RTL ${TOP_SV} not found and Bazel is not available." >&2
      exit 1
    fi
  else
    echo ">>> [PRE-STAGE] Reusing existing top-level RTL: ${TOP_SV}"
  fi

  # --- Stage 1: Canonicalization Pass ---
  echo ">>> [STAGE 1/4] Running Yosys Canonicalization Pass..."
  T_CANON_START=$(date +%s)
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    echo ">>> [DRY-RUN] Would run: make -C ${FLOW_HOME} DESIGN_CONFIG=${DESIGN_CONFIG} VERILOG_FILES=\"${VERILOG_FILES}\" SDC_FILE=${SDC_FILE} WORK_HOME=${WORK_HOME} do-yosys-canonicalize"
    CANON_DUR=0
  else
    make -C "${FLOW_HOME}" \
         DESIGN_CONFIG="${DESIGN_CONFIG}" \
         VERILOG_FILES="${VERILOG_FILES}" \
         SDC_FILE="${SDC_FILE}" \
         WORK_HOME="${WORK_HOME}" \
         do-yosys-canonicalize
    T_CANON_END=$(date +%s)
    CANON_DUR=$((T_CANON_END - T_CANON_START))
  fi
  echo ">>> [STAGE 1/4] Canonicalization completed in ${CANON_DUR}s."

  # --- Stage 2: 16-Partition Parallel Synthesis ---
  echo ">>> [STAGE 2/4] Running 16-Partition Parallel Synthesis..."
  T_SYNTH_START=$(date +%s)
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    echo ">>> [DRY-RUN] Would run: ${SCRIPT_DIR}/run_parallel_synth.sh ${WORK_HOME} ${VARIANT}"
    SYNTH_DUR=0
  else
    "${SCRIPT_DIR}/run_parallel_synth.sh" "${WORK_HOME}" "${VARIANT}"
    T_SYNTH_END=$(date +%s)
    SYNTH_DUR=$((T_SYNTH_END - T_SYNTH_START))
  fi
  echo ">>> [STAGE 2/4] Parallel Synthesis completed in ${SYNTH_DUR}s."

  # --- Stage 3: Netlist Stitching ---
  echo ">>> [STAGE 3/4] Running Netlist Stitching and Validation..."
  T_STITCH_START=$(date +%s)
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    echo ">>> [DRY-RUN] Would run: ${YOSYS_EXE} -c ${SCRIPT_DIR}/stitch_partitions.tcl"
    STITCH_DUR=0
  else
    export KEEP_VARS=1
    "${YOSYS_EXE}" -c "${SCRIPT_DIR}/stitch_partitions.tcl"
    touch "${RESULTS_DIR}/1_2_yosys.v" "${RESULTS_DIR}/1_2_yosys.sdc"
    T_STITCH_END=$(date +%s)
    STITCH_DUR=$((T_STITCH_END - T_STITCH_START))
  fi
  echo ">>> [STAGE 3/4] Netlist Stitching completed in ${STITCH_DUR}s."
else
  check_required_checkpoint "${TARGET_STAGE_NUM}"
  echo ">>> [RESUME] Skipping Stages 1-3. Resuming flow from stage ${TARGET_STAGE_NUM} (${TARGET_STAGE_NAME})..."
  CANON_DUR="0 (reused)"
  SYNTH_DUR="0 (reused)"
  STITCH_DUR="0 (reused)"
fi

# --- Stage 4: OpenROAD PnR (64 Cores) ---
if [[ "${SYNTH_ONLY}" -eq 1 ]]; then
  echo ">>> [STAGE 4/4] Synthesis-only mode requested (--synth-only). Generating 1_synth.odb and STA reports..."
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    echo ">>> [DRY-RUN] Would run: make -C ${FLOW_HOME} DESIGN_CONFIG=${DESIGN_CONFIG} SDC_FILE=${SDC_FILE} WORK_HOME=${WORK_HOME} do-1_synth"
  else
    make -C "${FLOW_HOME}" \
         DESIGN_CONFIG="${DESIGN_CONFIG}" \
         SDC_FILE="${SDC_FILE}" \
         WORK_HOME="${WORK_HOME}" \
         do-1_synth
  fi
  PNR_DUR="0 (skipped: synth-only)"
else
  echo ">>> [STAGE 4/4] Running Flat PnR (Floorplan -> Place -> CTS -> Route -> Finish)..."
  T_PNR_START=$(date +%s)
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    echo ">>> [DRY-RUN] Would run: make -C ${FLOW_HOME} DESIGN_CONFIG=${DESIGN_CONFIG} SDC_FILE=${SDC_FILE} WORK_HOME=${WORK_HOME} NUM_CORES=${NUM_CORES} ROUTING_CORES=${ROUTING_CORES} finish"
    PNR_DUR=0
  else
    make -C "${FLOW_HOME}" \
         DESIGN_CONFIG="${DESIGN_CONFIG}" \
         SDC_FILE="${SDC_FILE}" \
         WORK_HOME="${WORK_HOME}" \
         NUM_CORES="${NUM_CORES}" \
         ROUTING_CORES="${ROUTING_CORES}" \
         finish
    T_PNR_END=$(date +%s)
    PNR_DUR=$((T_PNR_END - T_PNR_START))
  fi
  echo ">>> [STAGE 4/4] PnR completed in ${PNR_DUR}s."
fi

T_END=$(date +%s)
TOTAL_DUR=$((T_END - T_START))

echo "========================================================================"
echo " FLOW EXECUTION SUMMARY"
echo "========================================================================"
echo " Starting Stage:        ${TARGET_STAGE_NUM} (${TARGET_STAGE_NAME})"
if [[ "${CANON_DUR}" =~ ^[0-9]+$ ]]; then
  echo " Canonicalization Time: ${CANON_DUR}s"
else
  echo " Canonicalization Time: ${CANON_DUR}"
fi
if [[ "${SYNTH_DUR}" =~ ^[0-9]+$ ]]; then
  echo " Parallel Synth Time:   ${SYNTH_DUR}s"
else
  echo " Parallel Synth Time:   ${SYNTH_DUR}"
fi
if [[ "${STITCH_DUR}" =~ ^[0-9]+$ ]]; then
  echo " Netlist Stitch Time:   ${STITCH_DUR}s"
else
  echo " Netlist Stitch Time:   ${STITCH_DUR}"
fi
if [[ "${PNR_DUR}" =~ ^[0-9]+$ ]]; then
  echo " PnR (64 Cores) Time:   ${PNR_DUR}s"
else
  echo " PnR (64 Cores) Time:   ${PNR_DUR}"
fi
echo " Total Wall-Clock Time: ${TOTAL_DUR}s"
FLOW_FINISH_TIME="$(date)"
echo " Finished at:           ${FLOW_FINISH_TIME}"
echo "========================================================================"

if [[ -f "${RESULTS_DIR}/1_2_yosys.v" ]]; then
  echo "========================================================================"
  echo " SYNTHESIS NETLIST CELL AUDIT (${RESULTS_DIR}/1_2_yosys.v)"
  echo "========================================================================"
  fa_count=$(grep -c "FAx1_ASAP7_75t_R" "${RESULTS_DIR}/1_2_yosys.v" || true)
  ha_count=$(grep -c "HAxp5_ASAP7_75t_R" "${RESULTS_DIR}/1_2_yosys.v" || true)
  total_cells=$(grep -c "_ASAP7_" "${RESULTS_DIR}/1_2_yosys.v" || true)
  echo " Total ASAP7 Standard Cells:     ${total_cells}"
  echo " Full Adders (FAx1_ASAP7_75t_R): ${fa_count}"
  echo " Half Adders (HAxp5_ASAP7_75t_R): ${ha_count}"
  echo "========================================================================"
fi

