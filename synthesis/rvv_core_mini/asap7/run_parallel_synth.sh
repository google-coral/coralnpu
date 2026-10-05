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
WORK_HOME="${1:-${SCRIPT_DIR}/work}"
VARIANT="${2:-base}"
PLATFORM="${PLATFORM:-asap7}"
DESIGN="${DESIGN:-RvvCoreMiniAxi}"

RESULTS_DIR="${WORK_HOME}/results/${PLATFORM}/${DESIGN}/${VARIANT}"
LOG_DIR="${WORK_HOME}/logs/${PLATFORM}/${DESIGN}/${VARIANT}"
REPORTS_DIR="${WORK_HOME}/reports/${PLATFORM}/${DESIGN}/${VARIANT}"
OBJECTS_DIR="${WORK_HOME}/objects/${PLATFORM}/${DESIGN}/${VARIANT}"
CHECKPOINT="${RESULTS_DIR}/1_1_yosys_canonicalize.rtlil"

export FLOW_HOME="${FLOW_HOME:-/OpenROAD-flow-scripts/flow}"
export SCRIPTS_DIR="${SCRIPTS_DIR:-${FLOW_HOME}/scripts}"
export PLATFORM_DIR="${PLATFORM_DIR:-${FLOW_HOME}/platforms/${PLATFORM}}"
export RESULTS_DIR LOG_DIR REPORTS_DIR OBJECTS_DIR
export PYTHON_EXE="${PYTHON_EXE:-python3}"
export YOSYS_EXE="${YOSYS_EXE:-yosys}"
export KEEP_VARS=1

# ASAP7 Synthesis Environment Defaults
export ABC_DRIVER_CELL="${ABC_DRIVER_CELL:-BUFx2_ASAP7_75t_R}"
export ABC_LOAD_IN_FF="${ABC_LOAD_IN_FF:-3.898}"
export ABC_AREA="${ABC_AREA:-0}"
export TIEHI_CELL_AND_PORT="${TIEHI_CELL_AND_PORT:-TIEHIx1_ASAP7_75t_R H}"
export TIELO_CELL_AND_PORT="${TIELO_CELL_AND_PORT:-TIELOx1_ASAP7_75t_R L}"
export MIN_BUF_CELL_AND_PORTS="${MIN_BUF_CELL_AND_PORTS:-BUFx2_ASAP7_75t_R A Y}"
export ADDER_MAP_FILE="${ADDER_MAP_FILE:-${PLATFORM_DIR}/yoSys/cells_adders_R.v}"
export LATCH_MAP_FILE="${LATCH_MAP_FILE:-${PLATFORM_DIR}/yoSys/cells_latch_R.v}"
export CLKGATE_MAP_FILE="${CLKGATE_MAP_FILE:-${PLATFORM_DIR}/yoSys/cells_clkgate_R.v}"
export DONT_USE_CELLS="${DONT_USE_CELLS:-*x1p*_ASAP7* *xp*_ASAP7* SDF* ICG*}"
export SYNTH_GUT="${SYNTH_GUT:-0}"
export SYNTH_MOCK_LARGE_MEMORIES="${SYNTH_MOCK_LARGE_MEMORIES:-0}"
export SYNTH_HIERARCHICAL="${SYNTH_HIERARCHICAL:-0}"
export SYNTH_INSBUF="${SYNTH_INSBUF:-0}"
export SYNTH_REPEATABLE_BUILD="${SYNTH_REPEATABLE_BUILD:-1}"
export SYNTH_WRAPPED_OPERATORS=1
export SWAP_ARITH_OPERATORS=1


LIB_DIR="${PLATFORM_DIR}/lib/NLDM"
export LIB_FILES="${LIB_FILES:-${LIB_DIR}/asap7sc7p5t_AO_RVT_FF_nldm_211120.lib.gz ${LIB_DIR}/asap7sc7p5t_INVBUF_RVT_FF_nldm_220122.lib.gz ${LIB_DIR}/asap7sc7p5t_OA_RVT_FF_nldm_211120.lib.gz ${LIB_DIR}/asap7sc7p5t_SIMPLE_RVT_FF_nldm_211120.lib.gz ${LIB_DIR}/asap7sc7p5t_SEQ_RVT_FF_nldm_220123.lib ${LIB_DIR}/fakeram_512x128.lib ${LIB_DIR}/fakeram_2048x128.lib}"
export DFF_LIB_FILE="${DFF_LIB_FILE:-${LIB_DIR}/asap7sc7p5t_SEQ_RVT_FF_nldm_220123.lib}"

mkdir -p "${RESULTS_DIR}" "${LOG_DIR}" "${REPORTS_DIR}" "${OBJECTS_DIR}"

declare -A TARGET_MAP=(
  ["rvv_backend_mac_unit_0"]="rvv_backend_mac_unit\$RvvCoreMiniAxi.core.rvvCore.rvvCoreWrapper.core.backend.u_mulmac.INST_MAC[0].u_mac"
  ["rvv_backend_mac_unit_1"]="rvv_backend_mac_unit\$RvvCoreMiniAxi.core.rvvCore.rvvCoreWrapper.core.backend.u_mulmac.INST_MAC[1].u_mac"
  ["rvv_backend_falu_unit_0"]="rvv_backend_falu_unit\$RvvCoreMiniAxi.core.rvvCore.rvvCoreWrapper.core.backend.u_falu.uop_unit[0].falu_uop_unit"
  ["rvv_backend_falu_unit_1"]="rvv_backend_falu_unit\$RvvCoreMiniAxi.core.rvvCore.rvvCoreWrapper.core.backend.u_falu.uop_unit[1].falu_uop_unit"
  ["rvv_backend_alu_unit_0"]="rvv_backend_alu_unit\$RvvCoreMiniAxi.core.rvvCore.rvvCoreWrapper.core.backend.u_alu.u_alu_cmp_unit"
  ["rvv_backend_alu_unit_1"]="rvv_backend_alu_unit\$RvvCoreMiniAxi.core.rvvCore.rvvCoreWrapper.core.backend.u_alu.ALU_UNIT[1].u_alu_unit"
  ["rvv_backend_div"]="rvv_backend_div\$RvvCoreMiniAxi.core.rvvCore.rvvCoreWrapper.core.backend.u_div"
  ["rvv_backend_pmtrdt"]="rvv_backend_pmtrdt\$RvvCoreMiniAxi.core.rvvCore.rvvCoreWrapper.core.backend.u_pmtrdt"
  ["rvv_backend_vrf"]="rvv_backend_vrf\$RvvCoreMiniAxi.core.rvvCore.rvvCoreWrapper.core.backend.u_vrf"
  ["rvv_backend_dispatch"]="rvv_backend_dispatch\$RvvCoreMiniAxi.core.rvvCore.rvvCoreWrapper.core.backend.u_dispatch"
  ["rvv_backend_rob"]="rvv_backend_rob\$RvvCoreMiniAxi.core.rvvCore.rvvCoreWrapper.core.backend.u_rob"
  ["RvvFrontEnd"]="RvvFrontEnd\$RvvCoreMiniAxi.core.rvvCore.rvvCoreWrapper.core.frontend"
  ["LsuV3"]="LsuV3\$RvvCoreMiniAxi.core.score.lsu"
  ["SCore"]="SCore\$RvvCoreMiniAxi.core.score"
  ["rvv_backend"]="rvv_backend\$RvvCoreMiniAxi.core.rvvCore.rvvCoreWrapper.core.backend"
  ["RvvCoreMiniAxi"]="RvvCoreMiniAxi"
)

TARGET_KEYS=(
  "rvv_backend_mac_unit_0"
  "rvv_backend_mac_unit_1"
  "rvv_backend_falu_unit_0"
  "rvv_backend_falu_unit_1"
  "rvv_backend_alu_unit_0"
  "rvv_backend_alu_unit_1"
  "rvv_backend_div"
  "rvv_backend_pmtrdt"
  "rvv_backend_vrf"
  "rvv_backend_dispatch"
  "rvv_backend_rob"
  "RvvFrontEnd"
  "LsuV3"
  "SCore"
  "rvv_backend"
  "RvvCoreMiniAxi"
)

ALL_MANGLED_NAMES=()
for k in "${TARGET_KEYS[@]}"; do
  ALL_MANGLED_NAMES+=("${TARGET_MAP[${k}]}")
done

echo "========================================================================"
echo " Starting 16-Partition Parallel Synthesis for ${DESIGN} on ASAP7"
echo " Checkpoint: ${CHECKPOINT}"
echo " Number of Workers: ${#TARGET_KEYS[@]}"
echo "========================================================================"

# Clean up child processes on interrupt or exit
trap 'kill $(jobs -p) 2>/dev/null || true' EXIT INT TERM

MAX_PARALLEL_JOBS="${MAX_PARALLEL_JOBS:-16}"

PARENT_RESULTS_DIR="${RESULTS_DIR}"
pids=()

run_worker() {
  local out_name="$1"
  local mangled_name="${TARGET_MAP[${out_name}]}"

  if [[ -s "${PARENT_RESULTS_DIR}/1_2_yosys_${out_name}.v" ]]; then
    echo "[REUSE] Partition ${out_name} already synthesized -> 1_2_yosys_${out_name}.v"
    return 0
  fi

  # Partition-specific optimization controls
  local p_wrapped="${SYNTH_WRAPPED_OPERATORS}"
  local p_swap="${SWAP_ARITH_OPERATORS}"

  # Non-arithmetic and control partitions do not need operator wrapping
  case "${out_name}" in
    SCore|RvvFrontEnd|rvv_backend_dispatch|rvv_backend_rob|rvv_backend_pmtrdt|rvv_backend_vrf|rvv_backend|RvvCoreMiniAxi)
      p_wrapped=0
      p_swap=0
      ;;
    *)
      ;;
  esac

  echo "[LAUNCH] Spawning partition worker for: ${out_name} (${mangled_name}) (SYNTH_WRAPPED_OPERATORS=${p_wrapped})"

  # Blackboxes = all other partition modules
  local blackbox_list=""
  for m in "${ALL_MANGLED_NAMES[@]}"; do
    if [[ "${m}" != "${mangled_name}" ]]; then
      blackbox_list="${blackbox_list} ${m}"
    fi
  done

  local worker_res_dir="${PARENT_RESULTS_DIR}/workers/${out_name}"
  local worker_log_dir="${LOG_DIR}/workers/${out_name}"
  local worker_rep_dir="${REPORTS_DIR}/workers/${out_name}"
  local worker_obj_dir="${OBJECTS_DIR}/workers/${out_name}"
  mkdir -p "${worker_res_dir}" "${worker_log_dir}" "${worker_rep_dir}" "${worker_obj_dir}"

  (
    t_start=$(date +%s)
    export SYNTH_CHECKPOINT="${CHECKPOINT}"
    export SYNTH_BLACKBOXES="${blackbox_list}"
    export DESIGN_NAME="${mangled_name}"
    export SYNTH_ARGS="-noshare"
    export SYNTH_MEMORY_MAX_BITS=32768
    export SYNTH_WRAPPED_OPERATORS="${p_wrapped}"
    export SWAP_ARITH_OPERATORS="${p_swap}"
    export SYNTH_SKIP_KEEP=1

    export RESULTS_DIR="${worker_res_dir}"
    export LOG_DIR="${worker_log_dir}"
    export REPORTS_DIR="${worker_rep_dir}"
    export OBJECTS_DIR="${worker_obj_dir}"
    export KEEP_VARS=1

    local worker_start_time
    worker_start_time="$(date)"
    echo "Worker [${out_name}] started at ${worker_start_time} (SYNTH_WRAPPED_OPERATORS=${p_wrapped})" > "${LOG_DIR}/1_2_yosys_${out_name}.log"
    "${YOSYS_EXE}" -c "${SCRIPTS_DIR}/synth.tcl" \
          >> "${LOG_DIR}/1_2_yosys_${out_name}.log" 2>&1

    if [[ ! -f "${worker_res_dir}/1_2_yosys.v" ]]; then
      echo "[FATAL] Partition ${out_name} failed to produce netlist." >&2
      tail -n 25 "${LOG_DIR}/1_2_yosys_${out_name}.log" >&2
      exit 1
    fi

    cp "${worker_res_dir}/1_2_yosys.v" "${PARENT_RESULTS_DIR}/1_2_yosys_${out_name}.v"
    if [[ -f "${worker_res_dir}/1_2_yosys.sdc" ]]; then
      cp "${worker_res_dir}/1_2_yosys.sdc" "${PARENT_RESULTS_DIR}/1_2_yosys_${out_name}.sdc"
    fi
    t_end=$(date +%s)
    dur=$((t_end - t_start))
    echo "[SUCCESS] Partition ${out_name} mapped in ${dur}s -> 1_2_yosys_${out_name}.v"
  )
}

for out_name in "${TARGET_KEYS[@]}"; do
  run_worker "${out_name}" &
  pids+=("$!")
  if [[ ${#pids[@]} -ge ${MAX_PARALLEL_JOBS} ]]; then
    wait -n 2>/dev/null || true
  fi
done

failed=0
for pid in "${pids[@]}"; do
  if ! wait "${pid}"; then
    failed=$((failed + 1))
  fi
done

if [[ "${failed}" -ne 0 ]]; then
  echo "[ERROR] ${failed} partition synthesis worker(s) failed." >&2
  exit 1
fi

echo "========================================================================"
echo " All ${#TARGET_KEYS[@]} partition targets synthesized cleanly."
echo "========================================================================"

