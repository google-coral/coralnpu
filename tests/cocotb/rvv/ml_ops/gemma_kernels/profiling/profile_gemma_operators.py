#!/usr/bin/env python3
"""Collect and report performance data for Gemma RVV operators.

This tool never estimates cycles from formulas. Dynamic cycle counts are read
by existing Cocotb tests from the running ELF's global ``cycle_count`` symbol;
this script only runs tests, saves raw logs, parses results, and records the
provenance of every data point.

Run it from the repository root:

  python3 tests/cocotb/rvv/ml_ops/gemma_kernels/profiling/profile_gemma_operators.py \\
      --workspace . --execute

If Bazel/Cocotb logs already exist, parse them without rerunning simulation:

  python3 tests/cocotb/rvv/ml_ops/gemma_kernels/profiling/profile_gemma_operators.py \\
      --workspace . --from-log /path/to/test.log
"""

from __future__ import annotations

import argparse
import csv
import json
import re
import shutil
import subprocess
import sys
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable


# This list defines the executable operator set rather than inferring it from
# log names. Each entry identifies the Bazel target, runner, data types, and
# performance work unit.
@dataclass(frozen=True)
class OperatorSpec:
    key: str
    name: str
    bazel_target: str
    runner_files: tuple[str, ...]
    test_modules: tuple[str, ...]
    dtypes: tuple[str, ...]
    work_unit: str
    feature_summary: str
    test_filter: str | None = None


GEMMA_KERNEL_DIR = Path("tests/cocotb/rvv/ml_ops/gemma_kernels")
SPECS: tuple[OperatorSpec, ...] = (
    OperatorSpec(
        key="rms_norm",
        name="RMSNorm",
        bazel_target="//tests/cocotb/rvv/ml_ops/gemma_kernels:rvv_rms_norm_cocotb_test",
        runner_files=("rms_norm_runner.cc", "rvv_bf16_rms_norm_runner.cc"),
        test_modules=("cocotb_tests/rvv_rms_norm_cocotb_test.py",),
        dtypes=("FP32", "BF16"),
        work_unit="elements",
        feature_summary="Supports dynamic seq_len and hidden_size; reports cycles/element.",
        test_filter="core_mini_rvv_bf16_rms_norm_test",
    ),
    OperatorSpec(
        key="residual_add",
        name="Residual Add",
        bazel_target="//tests/cocotb/rvv/ml_ops/gemma_kernels:rvv_residual_add_cocotb_test",
        runner_files=("rvv_residual_add_runner.cc", "rvv_bf16_residual_add_runner.cc"),
        test_modules=("cocotb_tests/rvv_residual_add_cocotb_test.py",),
        dtypes=("FP32", "BF16"),
        work_unit="elements",
        feature_summary="Element-wise residual addition; reports cycles/element.",
        test_filter="core_mini_rvv_bf16_residual_add_test",
    ),
    OperatorSpec(
        key="tanh_gelu_mul",
        name="Tanh-GELU × Up",
        bazel_target="//tests/cocotb/rvv/ml_ops/gemma_kernels:rvv_tanh_gelu_mul_cocotb_test",
        runner_files=("rvv_tanh_gelu_mul_runner.cc", "rvv_bf16_tanh_gelu_mul_runner.cc"),
        test_modules=("cocotb_tests/rvv_tanh_gelu_mul_cocotb_test.py",),
        dtypes=("FP32", "BF16"),
        work_unit="elements",
        feature_summary="Gemma MLP activation and element-wise multiplication; reports cycles/element.",
        test_filter="core_mini_rvv_bf16_tanh_gelu_mul_test",
    ),
    OperatorSpec(
        key="matmul",
        name="MatMul / GeMV",
        bazel_target="//tests/cocotb/rvv/ml_ops/gemma_kernels:rvv_matmul_cocotb_test",
        runner_files=("rvv_matmul_runner.cc", "rvv_bf16_matmul_runner.cc"),
        test_modules=("cocotb_tests/rvv_matmul_cocotb_test.py",),
        dtypes=("FP32", "BF16"),
        work_unit="MACs",
        feature_summary="Uses GeMV when M=1 and tiled MatMul otherwise; reports MACs/cycle.",
        test_filter="core_mini_rvv_bf16_matmul_lhs_1d_test",
    ),
    OperatorSpec(
        key="int8_matmul",
        name="INT8 MatMul / GeMV",
        bazel_target="//tests/cocotb/rvv/ml_ops/gemma_kernels:rvv_int8_matmul_test",
        runner_files=("rvv_int8_matmul_runner.cc",),
        test_modules=("cocotb_tests/rvv_int8_matmul_cocotb_test.py",),
        dtypes=("INT8 input / INT32 output",),
        work_unit="MACs",
        feature_summary="Covers K/N tails and 1D/2D paths; reports MACs/cycle.",
    ),
    OperatorSpec(
        key="flashattention",
        name="FlashAttention",
        bazel_target="//tests/cocotb/rvv/ml_ops/gemma_kernels:rvv_flashattention_cocotb_test",
        runner_files=("rvv_flashattention_runner.cc", "rvv_bf16_flashattention_runner.cc"),
        test_modules=("cocotb_tests/rvv_flashattention_cocotb_test.py",),
        dtypes=("FP32", "BF16"),
        work_unit="MACs",
        feature_summary="Covers prefill/decode and multi-query/multi-KV-head shapes; MACs include QK and PV.",
        test_filter="core_mini_rvv_bf16_flashattention_test",
    ),
    OperatorSpec(
        key="gemma_decoder_layer",
        name="Gemma 3 270M Decoder Layer Profile",
        bazel_target=(
            "//tests/cocotb/rvv/ml_ops/gemma_kernels/profiling/profiled_decoder_layer:"
            "rvv_gemma_decoder_layer_profile_cocotb_test"
        ),
        runner_files=(
            "profiling/profiled_decoder_layer/rvv_bf16_gemma_decoder_layer_profile_runner.cc",
            "profiling/profiled_decoder_layer/rvv_gemma_decoder_layer_profile.cc",
        ),
        test_modules=(
            "profiling/profiled_decoder_layer/cocotb_tests/rvv_gemma_decoder_layer_profile_cocotb_test.py",
        ),
        dtypes=("BF16",),
        work_unit="layer",
        feature_summary="End-to-end layer: RMSNorm, Q/K/V projections, RoPE, attention, MLP, and residuals.",
        test_filter="core_mini_rvv_bf16_gemma_decoder_layer_profile_test",
    ),
)

SPEC_BY_KEY = {spec.key: spec for spec in SPECS}


# Standard performance blocks printed by sw/utils/metrics.py in Cocotb.
# Keep the original label so each report entry remains traceable to its shape.
METRICS_BLOCK_RE = re.compile(
    r"PERFORMANCE METRICS:\s*(?P<label>[^\r\n]+).*?"
    r"Total Cycles\s*:\s*(?P<cycles>[\d,]+)(?P<details>.*?)(?=\n=+|\Z)",
    re.DOTALL,
)
COUNT_RE = re.compile(r"Total\s+(?P<unit>MACs|Elements)\s*:\s*(?P<count>[\d,]+)")
DECODER_CYCLES_RE = re.compile(
    r"(?:Full decoder layer completed in|decoder layer.*?in)\s*(?P<cycles>[\d,]+)\s*NPU cycles",
    re.IGNORECASE,
)
REAL_DECODER_CYCLES_RE = re.compile(
    r"REAL_GEMMA_RUN\s+mode=(?P<mode>[a-z0-9_]+).*?"
    r"cycles_raw=(?P<raw>[\d,]+).*?cycles_corrected=(?P<cycles>[\d,]+)",
    re.IGNORECASE,
)
DECODER_STAGE_RE = re.compile(
    r"Decoder stage cycle:\s*(?P<stage>[a-z0-9_]+)=(?P<cycles>[\d,]+)"
)
REAL_DECODER_STAGE_RE = re.compile(
    r"REAL_GEMMA_STAGE_METRIC\s+stage=(?P<stage>[a-z0-9_]+).*?"
    r"cycles_corrected=(?P<cycles>[\d,]+)"
)
DECODER_STAGE_SUM_RE = re.compile(r"Decoder stage cycle sum:\s*(?P<cycles>[\d,]+)")
DECODER_CORRECTED_STAGE_SUM_RE = re.compile(
    r"Decoder corrected stage cycle sum:\s*(?P<cycles>[\d,]+)"
)
DECODER_UNATTRIBUTED_RE = re.compile(
    r"Decoder (?:profiled-path )?unattributed cycles:\s*(?P<cycles>-?[\d,]+)"
)
TEST_SUMMARY_RE = re.compile(
    r"TESTS=(?P<tests>\d+)\s+PASS=(?P<pass>\d+)\s+"
    r"FAIL=(?P<fail>\d+)\s+SKIP=(?P<skip>\d+)"
)

# Logs use stable English stage keys, and the report uses readable English
# labels that can be checked against the decoder source order.
DECODER_STAGE_NAMES = {
    "input_rms_norm": "Input RMSNorm",
    "q_projection": "Q projection",
    "k_projection": "K projection",
    "v_projection": "V projection",
    "q_rms_norm": "Q RMSNorm",
    "k_rms_norm": "K RMSNorm",
    "rope": "RoPE",
    "cache_append": "K/V cache append",
    "flash_attention": "FlashAttention",
    "output_projection": "Output projection",
    "post_attention_rms_norm": "Post-attention RMSNorm",
    "post_attention_residual_add": "Post-attention residual add",
    "pre_feedforward_rms_norm": "Pre-feedforward RMSNorm",
    "gate_projection": "Gate projection",
    "up_projection": "Up projection",
    "tanh_gelu_mul": "Tanh-GELU x Up",
    "down_projection": "Down projection",
    "post_feedforward_rms_norm": "Post-feedforward RMSNorm",
    "post_feedforward_residual_add": "Post-feedforward residual add",
}


def parse_args() -> argparse.Namespace:
    """Parse command-line arguments; --execute is required to run simulation."""
    parser = argparse.ArgumentParser(
        description="Collect measured Gemma RVV operator cycles and report their provenance."
    )
    parser.add_argument(
        "--workspace",
        type=Path,
        default=Path.cwd(),
        help="CoralNPU repository root; defaults to the current directory.",
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=None,
        help="Report and raw-log directory; defaults to profiling/results.",
    )
    parser.add_argument(
        "--execute",
        action="store_true",
        help="Run each Bazel Cocotb test and collect logs; this may take a while.",
    )
    parser.add_argument(
        "--from-log",
        type=Path,
        action="append",
        default=[],
        help="Parse an existing log; may be specified more than once.",
    )
    parser.add_argument(
        "--operators",
        nargs="+",
        choices=sorted(SPEC_BY_KEY),
        default=None,
        help="Process only the selected operators; defaults to all operators.",
    )
    parser.add_argument(
        "--bazel",
        default="bazel",
        help="Path to the Bazel executable; defaults to bazel.",
    )
    parser.add_argument(
        "--test-env",
        action="append",
        default=[],
        metavar="KEY=VALUE",
        help=(
            "Additional --test_env values for Bazel test; may be repeated to select "
            "experimental ELFs or other runtime options."
        ),
    )
    return parser.parse_args()


def require_workspace(workspace: Path) -> Path:
    """Verify the workspace before running Bazel or scanning source files."""
    workspace = workspace.expanduser().resolve()
    required = workspace / GEMMA_KERNEL_DIR / "BUILD"
    if not required.is_file():
        raise FileNotFoundError(
            f"Could not find {GEMMA_KERNEL_DIR}/BUILD under {workspace}; "
            "pass --workspace for a different repository root."
        )
    return workspace


def line_numbers(text: str, pattern: str) -> list[int]:
    """Return matching line numbers so reports link cycles to source evidence."""
    expression = re.compile(pattern)
    return [index for index, line in enumerate(text.splitlines(), start=1) if expression.search(line)]


def collect_source_evidence(workspace: Path, spec: OperatorSpec) -> list[dict]:
    """Record where dynamic values are produced and read by runners and tests.

    This function does not produce cycle values. It checks that:
    1. the runner surrounds the kernel with mcycle_read();
    2. the delta is written to the cycle_count global;
    3. Cocotb resolves and reads cycle_count from the ELF through Fixture.
    """
    evidence: list[dict] = []
    kernel_root = workspace / GEMMA_KERNEL_DIR

    for relative_path in spec.runner_files:
        path = kernel_root / relative_path
        text = path.read_text(encoding="utf-8") if path.is_file() else ""
        evidence.append(
            {
                "kind": "runner_cycle_writer",
                "path": str(path.relative_to(workspace)),
                "exists": path.is_file(),
                "cycle_symbol_lines": line_numbers(text, r"\bcycle_count\b"),
                "mcycle_read_lines": line_numbers(text, r"\bmcycle_read\s*\("),
                "meaning": "The runner reads the RISC-V mcycle CSR and writes the delta to the ELF global cycle_count symbol.",
            }
        )

    for relative_path in spec.test_modules:
        path = kernel_root / relative_path
        text = path.read_text(encoding="utf-8") if path.is_file() else ""
        evidence.append(
            {
                "kind": "cocotb_cycle_reader",
                "path": str(path.relative_to(workspace)),
                "exists": path.is_file(),
                "elf_symbol_lookup_lines": line_numbers(text, r"[\"']cycle_count[\"']"),
                "read_lines": line_numbers(text, r"fixture\.read(?:_word)?\([^\n]*cycle_count"),
                "stage_symbol_lookup_lines": line_numbers(
                    text, r"[\"']gemma_stage_cycles[\"']"
                ),
                "stage_read_lines": line_numbers(
                    text, r"fixture\.read(?:_word)?\([^\n]*gemma_stage_cycles"
                ),
                "halt_counter_lines": line_numbers(text, r"run_to_halt\("),
                "meaning": (
                    "The test resolves cycle_count from the ELF symbol table; decoder "
                    "tests also resolve gemma_stage_cycles and read these 32-bit values "
                    "back over AXI."
                ),
            }
        )
    return evidence


def collect_fixture_evidence(workspace: Path) -> dict:
    """Describe ELF symbol lookup and simulated cycle counting in the shared Fixture."""
    path = workspace / "coralnpu_test_utils/core_mini_axi_interface.py"
    text = path.read_text(encoding="utf-8")
    return {
        "path": str(path.relative_to(workspace)),
        "lookup_symbol_lines": line_numbers(text, r"def lookup_symbol"),
        "wait_for_halted_lines": line_numbers(text, r"async def wait_for_halted"),
        "method": (
            "lookup_symbol uses pyelftools ELFFile/SHT_SYMTAB to find symbol addresses; "
            "wait_for_halted counts each io_aclk rising edge until the simulated core halts."
        ),
    }


def infer_operator_key(label: str) -> str | None:
    """Map a label from an existing metrics log to the fixed operator list."""
    normalized = label.lower()
    # The exact FlashAttention label contains "Decoder Layer Exact Shape". Check
    # it first so it is not classified as a full decoder layer.
    if "flashattention" in normalized or "flash attention" in normalized:
        return "flashattention"
    if "decoder" in normalized:
        return "gemma_decoder_layer"
    if "rms" in normalized:
        return "rms_norm"
    if "residual" in normalized:
        return "residual_add"
    if "tanh" in normalized or "gelu" in normalized:
        return "tanh_gelu_mul"
    if "int8" in normalized:
        return "int8_matmul"
    if "matmul" in normalized or "gemv" in normalized:
        return "matmul"
    return None


def parse_metric_blocks(log_text: str, log_path: Path) -> list[dict]:
    """Parse standard Cocotb performance blocks and measured kernel cycles."""
    samples: list[dict] = []
    for match in METRICS_BLOCK_RE.finditer(log_text):
        label = match.group("label").strip()
        operator_key = infer_operator_key(label)
        if operator_key is None:
            continue
        details = match.group("details")
        count_match = COUNT_RE.search(details)
        work_count = int(count_match.group("count").replace(",", "")) if count_match else None
        work_unit = count_match.group("unit") if count_match else None
        cycles = int(match.group("cycles").replace(",", ""))
        sample = make_sample(
            operator_key=operator_key,
            label=label,
            cycles=cycles,
            work_count=work_count,
            work_unit=work_unit,
            raw_log=log_path,
        )
        samples.append(sample)
    return samples


def parse_decoder_cycles(log_text: str, log_path: Path) -> list[dict]:
    """Parse decoder-specific logs, which do not use the generic metrics block."""
    samples: list[dict] = []
    real_matches = list(REAL_DECODER_CYCLES_RE.finditer(log_text))
    if real_matches:
        for match in real_matches:
            samples.append(
                make_sample(
                    operator_key="gemma_decoder_layer",
                    label=f"Gemma decoder layer ({match.group('mode')})",
                    cycles=int(match.group("cycles").replace(",", "")),
                    work_count=None,
                    work_unit="layer",
                    raw_log=log_path,
                )
            )
        return samples
    for index, match in enumerate(DECODER_CYCLES_RE.finditer(log_text), start=1):
        samples.append(
            make_sample(
                operator_key="gemma_decoder_layer",
                label=f"Gemma decoder layer run #{index}",
                cycles=int(match.group("cycles").replace(",", "")),
                work_count=None,
                work_unit="layer",
                raw_log=log_path,
            )
        )
    return samples


def make_sample(
    operator_key: str,
    label: str,
    cycles: int,
    work_count: int | None,
    work_unit: str | None,
    raw_log: Path,
) -> dict:
    """Build one measured record and calculate reproducible derived rates."""
    spec = SPEC_BY_KEY[operator_key]
    result = {
        "operator_key": operator_key,
        "operator_name": spec.name,
        "label": label,
        "kernel_cycles": cycles,
        "work_count": work_count,
        "work_unit": work_unit or spec.work_unit,
        "work_per_cycle": round(work_count / cycles, 8) if work_count and cycles else None,
        "cycles_per_work": round(cycles / work_count, 8) if work_count else None,
        "raw_log": str(raw_log),
        "cycle_value_source": (
            "Cocotb reads the ELF global cycle_count symbol through Fixture; "
            "the runner writes it from an mcycle_read() delta."
        ),
        "parser_method": "Parse the PERFORMANCE METRICS block from sw/utils/metrics.py or the decoder completion log.",
    }
    return result


def parse_logs(paths: Iterable[Path]) -> list[dict]:
    """Parse all logs and deduplicate repeated banners."""
    samples: list[dict] = []
    seen: set[tuple] = set()
    for path in paths:
        text = path.read_text(encoding="utf-8", errors="replace")
        for sample in parse_metric_blocks(text, path) + parse_decoder_cycles(text, path):
            identity = (
                sample["operator_key"], sample["label"], sample["kernel_cycles"], sample["raw_log"]
            )
            if identity not in seen:
                seen.add(identity)
                samples.append(sample)
    return samples


def parse_decoder_profiles(paths: Iterable[Path]) -> list[dict]:
    """Read full-decoder cycles, 19 stages, and unattributed overhead.

    Stage cycles are not estimated by this script. They come from the
    ``gemma_stage_cycles`` array in the decoder ELF. Cocotb resolves its address
    from the ELF symbol table, reads each word over AXI, and prints
    ``Decoder stage cycle`` log lines. This function only parses those lines and
    checks their explicit sums.
    """
    profiles: list[dict] = []
    for path in paths:
        text = path.read_text(encoding="utf-8", errors="replace")
        real_total_matches = list(REAL_DECODER_CYCLES_RE.finditer(text))
        total_matches = real_total_matches or list(DECODER_CYCLES_RE.finditer(text))
        real_stage_matches = list(REAL_DECODER_STAGE_RE.finditer(text))
        stage_matches = real_stage_matches or list(DECODER_STAGE_RE.finditer(text))
        if not total_matches:
            continue
        stages = {
            match.group("stage"): int(match.group("cycles").replace(",", ""))
            for match in stage_matches
        }
        stage_sum_match = (
            DECODER_CORRECTED_STAGE_SUM_RE.search(text)
            if real_stage_matches else DECODER_STAGE_SUM_RE.search(text)
        )
        unattributed_match = DECODER_UNATTRIBUTED_RE.search(text)
        for run_index, total_match in enumerate(total_matches, start=1):
            total_cycles = int(total_match.group("cycles").replace(",", ""))
            calculated_stage_sum = sum(stages.values()) if stages else None
            profiles.append(
                {
                    "run_index": run_index,
                    "raw_log": str(path),
                    "total_cycles": total_cycles,
                    "stages": stages,
                    "stage_sum_from_log": (
                        int(stage_sum_match.group("cycles").replace(",", ""))
                        if stage_sum_match else None
                    ),
                    "stage_sum_calculated": calculated_stage_sum,
                    "unattributed_cycles_from_log": (
                        int(unattributed_match.group("cycles").replace(",", ""))
                        if unattributed_match else None
                    ),
                    "unattributed_cycles_calculated": (
                        total_cycles - calculated_stage_sum
                        if calculated_stage_sum is not None else None
                    ),
                    "stage_value_source": (
                        "Cocotb resolves gemma_stage_cycles from the ELF symbol table, "
                        "reads the array over AXI, and prints it to the raw log."
                    ),
                }
            )
    return profiles


def parse_test_summaries(paths: Iterable[Path]) -> list[dict]:
    """Read the final Cocotb TESTS/PASS/FAIL/SKIP summary from each log."""
    summaries: list[dict] = []
    for path in paths:
        text = path.read_text(encoding="utf-8", errors="replace")
        matches = list(TEST_SUMMARY_RE.finditer(text))
        if not matches:
            continue
        match = matches[-1]
        summaries.append(
            {
                "raw_log": str(path),
                "tests": int(match.group("tests")),
                "pass": int(match.group("pass")),
                "fail": int(match.group("fail")),
                "skip": int(match.group("skip")),
            }
        )
    return summaries


def build_decoder_comparison(samples: list[dict], decoder_profiles: list[dict]) -> dict | None:
    """Compare standalone operators with the full decoder at identical shapes.

    RoPE and cache append have no standalone runners, so use their full-decoder
    stage values; all other terms come from standalone Cocotb runner
    ``cycle_count`` values. Return missing labels instead of fabricating a sum.
    """
    profiled_runs = [profile for profile in decoder_profiles if profile["stages"]]
    if not profiled_runs:
        return None
    decoder = profiled_runs[-1]

    # A label may occur in both combined and standalone tests. Keep the last
    # occurrence; callers should pass the newest and most precise log last.
    by_label: dict[str, dict] = {}
    for sample in samples:
        by_label[sample["label"]] = sample

    terms = [
        ("BF16 RMS Norm Shape: 1x640", 4, "Four hidden=640 RMSNorm calls"),
        ("BF16 RMS Norm Shape: 4x256", 1, "Q RMSNorm"),
        ("BF16 RMS Norm Shape: 1x256", 1, "K RMSNorm"),
        ("BF16 GeMV 1D: 1x640x1024", 1, "Q projection"),
        ("BF16 GeMV 1D: 1x640x256", 2, "K/V projections"),
        ("BF16 GeMV 1D: 1x1024x640", 1, "Output projection"),
        ("BF16 GeMV 1D: 1x640x2048", 2, "Gate/Up projections"),
        ("BF16 GeMV 1D: 1x2048x640", 1, "Down projection"),
        ("BF16 FlashAttention (Decoder Layer Exact Shape)", 1, "FlashAttention"),
        ("BF16 TanhGELU x Up Mul Shape: 1x2048", 1, "Tanh-GELU × Up"),
        ("BF16 Residual Add Shape: 1x640", 2, "Two residual additions"),
    ]
    missing = [label for label, _, _ in terms if label not in by_label]
    if missing:
        return {"missing_labels": missing}

    standalone_terms = []
    standalone_sum = 0
    for label, multiplier, meaning in terms:
        cycles = by_label[label]["kernel_cycles"]
        subtotal = cycles * multiplier
        standalone_sum += subtotal
        standalone_terms.append(
            {
                "meaning": meaning,
                "label": label,
                "cycles_each": cycles,
                "multiplier": multiplier,
                "subtotal_cycles": subtotal,
                "raw_log": by_label[label]["raw_log"],
            }
        )

    stage_only = {
        key: decoder["stages"][key] for key in ("rope", "cache_append")
    }
    comparable_sum = standalone_sum + sum(stage_only.values())
    full_cycles = decoder["total_cycles"]
    stage_sum = decoder["stage_sum_calculated"]
    return {
        "standalone_terms": standalone_terms,
        "standalone_kernel_sum": standalone_sum,
        "integrated_only_terms": stage_only,
        "standalone_plus_integrated_only_sum": comparable_sum,
        "decoder_stage_sum": stage_sum,
        "decoder_total_cycles": full_cycles,
        "standalone_vs_stage_sum_difference": stage_sum - comparable_sum,
        "standalone_vs_total_difference": full_cycles - comparable_sum,
        "standalone_vs_total_difference_percent": round(
            (full_cycles - comparable_sum) * 100.0 / full_cycles, 8
        ),
        "stage_sum_vs_total_difference": full_cycles - stage_sum,
        "stage_sum_vs_total_difference_percent": round(
            (full_cycles - stage_sum) * 100.0 / full_cycles, 8
        ),
        "decoder_raw_log": decoder["raw_log"],
    }


def run_bazel_target(
    workspace: Path,
    output_dir: Path,
    bazel: str,
    spec: OperatorSpec,
    extra_test_env: Iterable[str] = (),
) -> Path:
    """Run one Bazel test and save its complete stdout/stderr as raw evidence."""
    raw_dir = output_dir / "raw_logs"
    raw_dir.mkdir(parents=True, exist_ok=True)
    log_path = raw_dir / f"{spec.key}.log"
    # --batch avoids reusing an old Bazel server, so the current JAVA_HOME is
    # used. Resolve the host compiler through the repository's default toolchain
    # instead of binding the test to a workstation-specific LLVM path.
    command = [bazel, "--batch", "test", spec.bazel_target, "--test_output=all"]
    command.append("--test_env=GEMMA_PROFILE_ONLY=1")
    command.extend(f"--test_env={value}" for value in extra_test_env)
    if spec.test_filter:
        command.append(f"--test_filter={spec.test_filter}")
    # Stream output because the first Verilator/Cocotb build may take a while;
    # also save the same output as an auditable raw log.
    process = subprocess.Popen(
        command,
        cwd=workspace,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        bufsize=1,
    )
    assert process.stdout is not None
    with log_path.open("w", encoding="utf-8") as handle:
        for line in process.stdout:
            print(line, end="", flush=True)
            handle.write(line)
    return_code = process.wait()
    if return_code != 0:
        raise RuntimeError(
            f"Bazel target failed: {spec.bazel_target}, exit code {return_code}; "
            f"full log: {log_path}"
        )
    return log_path


def write_csv(path: Path, samples: list[dict]) -> None:
    """Write a flat CSV suitable for spreadsheets; include headers if empty."""
    fields = [
        "operator_key", "operator_name", "label", "kernel_cycles", "work_count",
        "work_unit", "work_per_cycle", "cycles_per_work", "raw_log",
        "cycle_value_source", "parser_method",
    ]
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields)
        writer.writeheader()
        writer.writerows(samples)


def markdown_table(rows: list[list[str]]) -> str:
    """Generate a minimal Markdown table without extra dependencies."""
    if not rows:
        return ""
    header = "| " + " | ".join(rows[0]) + " |"
    separator = "| " + " | ".join(["---"] * len(rows[0])) + " |"
    body = ["| " + " | ".join(row) + " |" for row in rows[1:]]
    return "\n".join([header, separator, *body])


def write_markdown(path: Path, report: dict) -> None:
    """Write a human-readable report with provenance and readout methods first."""
    lines = [
        "# Gemma RVV Operator Profiling Report",
        "",
        f"Generated at: {report['generated_at']}",
        "",
        "## Cycle data provenance",
        "",
        "1. Each C++ runner calls `mcycle_read()` around the kernel and writes the delta to the ELF global `cycle_count`.",
        "2. Cocotb resolves the `cycle_count` address with `Fixture.load_elf_and_lookup_symbols()`.",
        "3. The test reads the value over AXI with `Fixture.read()` or `Fixture.read_word()`; `sw/utils/metrics.py` prints the performance block.",
        "4. This script saves complete Bazel/Cocotb logs and parses the performance blocks, so JSON, CSV, and Markdown results trace back to `raw_logs`.",
        "",
        "`kernel_cycles` is the NPU-program mcycle delta, not host time. If a test records `run_to_halt()`, "
        "that value is the total simulated clock count from startup to halt and should be compared separately.",
        "",
        "## Verified source evidence",
        "",
    ]
    evidence_rows = [["Operator", "Runner", "mcycle_read lines", "cycle_count lines", "Test read lines"]]
    for key, evidence in report["source_evidence"].items():
        runners = [item for item in evidence if item["kind"] == "runner_cycle_writer"]
        readers = [item for item in evidence if item["kind"] == "cocotb_cycle_reader"]
        evidence_rows.append([
            SPEC_BY_KEY[key].name,
            "<br>".join(item["path"] for item in runners),
            "<br>".join(str(item["mcycle_read_lines"]) for item in runners),
            "<br>".join(str(item["cycle_symbol_lines"]) for item in runners),
            "<br>".join(str(item["read_lines"]) for item in readers),
        ])
    lines.extend([markdown_table(evidence_rows), ""])

    lines.extend(["## Measured results", ""])
    if report["samples"]:
        sample_rows = [["Operator", "Test shape/label", "Kernel cycles", "Work", "Work/cycle", "Cycles/work"]]
        for sample in report["samples"]:
            work = "-" if sample["work_count"] is None else f"{sample['work_count']} {sample['work_unit']}"
            sample_rows.append([
                sample["operator_name"], sample["label"], str(sample["kernel_cycles"]), work,
                "-" if sample["work_per_cycle"] is None else str(sample["work_per_cycle"]),
                "-" if sample["cycles_per_work"] is None else str(sample["cycles_per_work"]),
            ])
        lines.extend([markdown_table(sample_rows), ""])
    else:
        lines.extend([
            "No dynamic test results were parsed. Use `--execute` to run the tests or `--from-log` to import existing Cocotb logs.",
            "",
        ])

    lines.extend(["## Test status", ""])
    if report["test_summaries"]:
        status_rows = [["Raw log", "Tests", "Pass", "Fail", "Skip"]]
        for summary in report["test_summaries"]:
            status_rows.append([
                summary["raw_log"], str(summary["tests"]), str(summary["pass"]),
                str(summary["fail"]), str(summary["skip"]),
            ])
        lines.extend([markdown_table(status_rows), ""])
    else:
        lines.extend(["No Cocotb summary lines were found in the logs.", ""])

    lines.extend(["## Historical and profiled decoder runs", ""])
    if report["decoder_profiles"]:
        history_rows = [["Run", "Whole-layer cycles", "Has per-stage data", "Raw log"]]
        for index, profile in enumerate(report["decoder_profiles"], start=1):
            history_rows.append([
                str(index), f"{profile['total_cycles']:,}",
                "Yes" if profile["stages"] else "No", profile["raw_log"],
            ])
        lines.extend([markdown_table(history_rows), ""])
        if len(report["decoder_profiles"]) >= 2:
            old_cycles = report["decoder_profiles"][0]["total_cycles"]
            new_cycles = report["decoder_profiles"][-1]["total_cycles"]
            difference = new_cycles - old_cycles
            lines.extend([
                f"The first baseline decoder log measured **{old_cycles:,} cycles**; the latest profiled version measured "
                f"**{new_cycles:,} cycles**, a difference of **{difference:+,} cycles "
                f"({difference * 100.0 / old_cycles:+.6f}%)**.",
                "",
                "These logs use different ELFs: the profiled version adds 19 pairs of `mcycle_read()` calls "
                "and array writes, changing program size, code layout, and cache state. They show historical "
                "changes but cannot by themselves establish a kernel regression. Use the same profiled run below "
                "and standalone runners under matching DDR conditions for an exact sum.",
                "",
            ])

    lines.extend(["## Full decoder per-stage cycles", ""])
    profiled_decoders = [
        profile for profile in report["decoder_profiles"] if profile["stages"]
    ]
    if profiled_decoders:
        decoder = profiled_decoders[-1]
        stage_rows = [["Stage", "Log key", "Cycles", "Share of whole layer"]]
        for key, cycles in decoder["stages"].items():
            stage_rows.append([
                DECODER_STAGE_NAMES.get(key, key), key, f"{cycles:,}",
                f"{cycles * 100.0 / decoder['total_cycles']:.4f}%",
            ])
        lines.extend([
            f"Whole-layer total: **{decoder['total_cycles']:,} cycles**; "
            f"stage sum: **{decoder['stage_sum_calculated']:,} cycles**; "
            f"unattributed: **{decoder['unattributed_cycles_calculated']:,} cycles**.",
            "",
            markdown_table(stage_rows),
            "",
        ])
    else:
        lines.extend(["No decoder log containing `gemma_stage_cycles` was imported.", ""])

    lines.extend(["## Standalone operator sum vs full decoder", ""])
    comparison = report["decoder_comparison"]
    if comparison and not comparison.get("missing_labels"):
        term_rows = [["Component", "Standalone test label", "Cycles per run", "Count", "Subtotal"]]
        for term in comparison["standalone_terms"]:
            term_rows.append([
                term["meaning"], term["label"], f"{term['cycles_each']:,}",
                str(term["multiplier"]), f"{term['subtotal_cycles']:,}",
            ])
        for key, cycles in comparison["integrated_only_terms"].items():
            term_rows.append([
                f"{DECODER_STAGE_NAMES.get(key, key)} (no standalone runner)",
                "Full decoder internal stage readout", f"{cycles:,}", "1", f"{cycles:,}",
            ])
        lines.extend([
            markdown_table(term_rows),
            "",
            f"- Standalone kernel total: **{comparison['standalone_kernel_sum']:,} cycles**.",
            f"- With RoPE/cache stages: **{comparison['standalone_plus_integrated_only_sum']:,} cycles**.",
            f"- Full decoder 19-stage sum: **{comparison['decoder_stage_sum']:,} cycles**, "
            f"difference **{comparison['standalone_vs_stage_sum_difference']:+,} cycles**.",
            f"- Full decoder total: **{comparison['decoder_total_cycles']:,} cycles**, "
            f"difference **{comparison['standalone_vs_total_difference']:+,} cycles "
            f"({comparison['standalone_vs_total_difference_percent']:.6f}%)**.",
            "",
        ])
    elif comparison:
        lines.extend([
            "The following exact shapes are missing, so an uncontaminated sum cannot be computed:",
            "",
            *[f"- `{label}`" for label in comparison["missing_labels"]],
            "",
        ])
    else:
        lines.extend(["No full decoder log with per-stage data is available for comparison.", ""])

    lines.extend(["## Operator feature summary", ""])
    spec_rows = [["Operator", "Data types", "Bazel target", "Features"]]
    for spec in report["operators"]:
        spec_rows.append([
            spec["name"], ", ".join(spec["dtypes"]), f"`{spec['bazel_target']}`", spec["feature_summary"],
        ])
    lines.append(markdown_table(spec_rows))
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> int:
    """Collect source evidence, optionally run/parse logs, and write reports."""
    args = parse_args()
    workspace = require_workspace(args.workspace)
    output_dir = (args.output_dir or workspace / GEMMA_KERNEL_DIR / "profiling/results").resolve()
    output_dir.mkdir(parents=True, exist_ok=True)
    selected = [SPEC_BY_KEY[key] for key in (args.operators or [spec.key for spec in SPECS])]
    log_paths = [path.expanduser().resolve() for path in args.from_log]
    missing_logs = [path for path in log_paths if not path.is_file()]
    if missing_logs:
        raise FileNotFoundError(f"Log file(s) not found: {', '.join(str(path) for path in missing_logs)}")

    if args.execute:
        if shutil.which(args.bazel) is None and not Path(args.bazel).is_file():
            raise FileNotFoundError(f"Bazel executable not found: {args.bazel}")
        for spec in selected:
            print(f"[profile] Running {spec.name}: {spec.bazel_target}", flush=True)
            log_paths.append(
                run_bazel_target(
                    workspace,
                    output_dir,
                    args.bazel,
                    spec,
                    args.test_env,
                )
            )

    samples = [sample for sample in parse_logs(log_paths) if sample["operator_key"] in {spec.key for spec in selected}]
    decoder_profiles = parse_decoder_profiles(log_paths)
    test_summaries = parse_test_summaries(log_paths)
    decoder_comparison = build_decoder_comparison(samples, decoder_profiles)
    report = {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "workspace": str(workspace),
        "selected_operator_keys": [spec.key for spec in selected],
        "operators": [asdict(spec) for spec in selected],
        "samples": samples,
        "test_summaries": test_summaries,
        "decoder_profiles": decoder_profiles,
        "decoder_comparison": decoder_comparison,
        "source_evidence": {spec.key: collect_source_evidence(workspace, spec) for spec in selected},
        "fixture_evidence": collect_fixture_evidence(workspace),
        "data_reading_method": {
            "kernel_cycles": "The ELF cycle_count symbol is read over AXI by the Cocotb Fixture and written to the performance log.",
            "work_count": "Computed from matrix shapes or element counts in the test and printed by sw/utils/metrics.py.",
            "derived_metrics": "Derived by dividing measured kernel_cycles by MACs or elements from the log.",
            "raw_logs": [str(path) for path in log_paths],
            "host_toolchain": "Bazel default host toolchain",
            "extra_test_env": args.test_env,
        },
    }
    json_path = output_dir / "profile_report.json"
    csv_path = output_dir / "profile_samples.csv"
    markdown_path = output_dir / "profile_report.md"
    json_path.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    write_csv(csv_path, samples)
    write_markdown(markdown_path, report)
    print(f"[profile] JSON report: {json_path}")
    print(f"[profile] CSV report: {csv_path}")
    print(f"[profile] Markdown report: {markdown_path}")
    print(f"[profile] Parsed {len(samples)} dynamic samples.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (FileNotFoundError, RuntimeError, ValueError) as error:
        print(f"[profile] Error: {error}", file=sys.stderr)
        raise SystemExit(2)
