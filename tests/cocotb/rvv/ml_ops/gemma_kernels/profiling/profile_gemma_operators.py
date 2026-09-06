#!/usr/bin/env python3
"""Gemma RVV 算子性能采集与报告工具。

本工具不会凭公式猜测 cycle。动态 cycle 由已有 Cocotb 用例从已运行 ELF
的 ``cycle_count`` 全局变量读取；本脚本只负责执行测试、保存原始日志、解析
结果，并把每条数据的来源一并写入报告。

推荐在仓库根目录执行：

  python3 tests/cocotb/rvv/ml_ops/gemma_kernels/profiling/profile_gemma_operators.py \\
      --workspace . --execute

如果已经有 Bazel/Cocotb 日志，可以只解析日志，避免重新跑仿真：

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


# 这里的清单是“可执行的算子集合”，而不是从日志名称反推出来的猜测。
# 每一项明确给出：Bazel 目标、对应 runner、数据类型和性能工作量单位。
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
        feature_summary="支持动态 seq_len 与 hidden_size；统计 cycles/element。",
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
        feature_summary="逐元素残差相加；统计 cycles/element。",
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
        feature_summary="Gemma MLP 激活与逐元素乘法；统计 cycles/element。",
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
        feature_summary="M=1 时走 GeMV，其他形状走 tiled MatMul；统计 MACs/cycle。",
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
        feature_summary="覆盖 K、N 尾块与 1D/2D 路径；统计 MACs/cycle。",
    ),
    OperatorSpec(
        key="flashattention",
        name="FlashAttention",
        bazel_target="//tests/cocotb/rvv/ml_ops/gemma_kernels:rvv_flashattention_cocotb_test",
        runner_files=("rvv_flashattention_runner.cc", "rvv_bf16_flashattention_runner.cc"),
        test_modules=("cocotb_tests/rvv_flashattention_cocotb_test.py",),
        dtypes=("FP32", "BF16"),
        work_unit="MACs",
        feature_summary="覆盖 prefill/decode、多查询头与多 KV 头；MAC 数包含 QK 与 PV 两部分。",
        test_filter="core_mini_rvv_bf16_flashattention_test",
    ),
    OperatorSpec(
        key="gemma_decoder_layer",
        name="Gemma 3 270M Decoder Layer（mytest）",
        bazel_target=(
            "//tests/cocotb/rvv/ml_ops/gemma_kernels/profiling/mytest:"
            "rvv_gemma_decoder_layer_profile_cocotb_test"
        ),
        runner_files=(
            "profiling/mytest/rvv_bf16_gemma_decoder_layer_runner_mytest.cc",
            "profiling/mytest/rvv_gemma_decoder_layer_mytest.cc",
        ),
        test_modules=(
            "profiling/mytest/cocotb_tests/rvv_gemma_decoder_layer_cocotb_test_mytest.py",
        ),
        dtypes=("BF16",),
        work_unit="layer",
        feature_summary="端到端单层：RMSNorm、Q/K/V 投影、RoPE、Attention、MLP 与残差。",
        test_filter="core_mini_rvv_bf16_gemma_decoder_layer_test",
    ),
)

SPEC_BY_KEY = {spec.key: spec for spec in SPECS}


# Cocotb 中 sw/utils/metrics.py 打印的标准性能块。
# 该正则特意保留原始 label，确保报告可追溯到具体测试形状。
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

# 日志使用稳定的英文 stage key，报告额外给出中文名称，方便和 Decoder
# 源码中的执行顺序一一核对。
DECODER_STAGE_NAMES_ZH = {
    "input_rms_norm": "输入 RMSNorm",
    "q_projection": "Q 投影",
    "k_projection": "K 投影",
    "v_projection": "V 投影",
    "q_rms_norm": "Q RMSNorm",
    "k_rms_norm": "K RMSNorm",
    "rope": "RoPE",
    "cache_append": "追加 K/V Cache",
    "flash_attention": "FlashAttention",
    "output_projection": "输出投影",
    "post_attention_rms_norm": "Attention 后 RMSNorm",
    "post_attention_residual_add": "Attention 残差加",
    "pre_feedforward_rms_norm": "FFN 前 RMSNorm",
    "gate_projection": "Gate 投影",
    "up_projection": "Up 投影",
    "tanh_gelu_mul": "Tanh-GELU × Up",
    "down_projection": "Down 投影",
    "post_feedforward_rms_norm": "FFN 后 RMSNorm",
    "post_feedforward_residual_add": "FFN 残差加",
}


def parse_args() -> argparse.Namespace:
    """解析命令行；默认只生成静态证据报告，--execute 才会启动仿真。"""
    parser = argparse.ArgumentParser(
        description="采集 Gemma RVV 算子的真实 cycle，并输出可追溯报告。"
    )
    parser.add_argument(
        "--workspace",
        type=Path,
        default=Path.cwd(),
        help="CoralNPU 仓库根目录，默认是当前目录。",
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=None,
        help="报告与原始日志输出目录；默认 profiling/results。",
    )
    parser.add_argument(
        "--execute",
        action="store_true",
        help="逐个执行 Bazel Cocotb 测试并采集日志；可能耗时较长。",
    )
    parser.add_argument(
        "--from-log",
        type=Path,
        action="append",
        default=[],
        help="追加解析已有日志；可重复传入该参数。",
    )
    parser.add_argument(
        "--operators",
        nargs="+",
        choices=sorted(SPEC_BY_KEY),
        default=None,
        help="仅处理指定算子；默认处理全部算子。",
    )
    parser.add_argument(
        "--bazel",
        default="bazel",
        help="Bazel 可执行文件路径，默认 bazel。",
    )
    parser.add_argument(
        "--test-env",
        action="append",
        default=[],
        metavar="KEY=VALUE",
        help=(
            "额外传给 Bazel test 的 --test_env；可重复传入。用于选择实验 ELF "
            "或其他不改变测试主体的运行参数。"
        ),
    )
    return parser.parse_args()


def require_workspace(workspace: Path) -> Path:
    """确认目录确实是工作区，避免在错误目录运行 Bazel 或扫描错误源码。"""
    workspace = workspace.expanduser().resolve()
    required = workspace / GEMMA_KERNEL_DIR / "BUILD"
    if not required.is_file():
        raise FileNotFoundError(
            f"未在 {workspace} 找到 {GEMMA_KERNEL_DIR}/BUILD；请传入 --workspace。"
        )
    return workspace


def line_numbers(text: str, pattern: str) -> list[int]:
    """返回匹配模式所在行号，用于让报告直接定位到 cycle 的源码证据。"""
    expression = re.compile(pattern)
    return [index for index, line in enumerate(text.splitlines(), start=1) if expression.search(line)]


def collect_source_evidence(workspace: Path, spec: OperatorSpec) -> list[dict]:
    """静态读取 runner 与测试代码，记录“动态数值从哪里读出”的证据。

    此函数不产生 cycle 数值；它读取源码来验证下列链路是否存在：
    1. runner 用 mcycle_read() 包住 kernel；
    2. 差值写入 cycle_count 全局变量；
    3. Cocotb 通过 Fixture 从 ELF 查找并读取 cycle_count。
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
                "meaning": "runner 读取 RISC-V mcycle CSR，并将差值写入 ELF 全局符号 cycle_count。",
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
                    "测试先从 ELF 符号表解析 cycle_count；Decoder 还解析 "
                    "gemma_stage_cycles。随后通过 AXI 读回这些 32 位值。"
                ),
            }
        )
    return evidence


def collect_fixture_evidence(workspace: Path) -> dict:
    """读取公共 Fixture 实现，说明 ELF 符号解析与仿真周期计数的具体方法。"""
    path = workspace / "coralnpu_test_utils/core_mini_axi_interface.py"
    text = path.read_text(encoding="utf-8")
    return {
        "path": str(path.relative_to(workspace)),
        "lookup_symbol_lines": line_numbers(text, r"def lookup_symbol"),
        "wait_for_halted_lines": line_numbers(text, r"async def wait_for_halted"),
        "method": (
            "lookup_symbol 使用 pyelftools 的 ELFFile/SHT_SYMTAB 查找符号地址；"
            "wait_for_halted 每个 io_aclk 上升沿累加一次，返回仿真端到 halted 的总时钟数。"
        ),
    }


def infer_operator_key(label: str) -> str | None:
    """从已有 metrics 日志的测试标签映射回固定算子清单。"""
    normalized = label.lower()
    # 精确 FlashAttention 配置名中含有 “Decoder Layer Exact Shape”，必须先
    # 判断 FlashAttention，否则会被误归类为完整 Decoder。
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
    """读取 Cocotb 标准性能块，提取已由测试读取出的真实 kernel cycle。"""
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
    """解析 decoder 测试的专用日志；它目前没有调用通用 metrics 格式化函数。"""
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
    """构造单次实测记录，并计算可复核的派生吞吐率。"""
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
            "Cocotb 测试通过 Fixture 读取 ELF 全局符号 cycle_count；"
            "该变量由 runner 的 mcycle_read() 差值写入。"
        ),
        "parser_method": "解析 sw/utils/metrics.py 输出的 PERFORMANCE METRICS 块，或 decoder 专用完成日志。",
    }
    return result


def parse_logs(paths: Iterable[Path]) -> list[dict]:
    """解析全部日志并按内容去重，避免同一条 banner 被重复汇总。"""
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
    """读取完整 Decoder 的总 cycle、19 个阶段及未归因开销。

    阶段 cycle 不是脚本估算值，而是 Decoder ELF 中
    ``gemma_stage_cycles`` 数组的内容。Cocotb 先从 ELF 符号表取得数组地址，
    再通过 AXI 逐字读取，最后打印成 ``Decoder stage cycle`` 日志行。
    本函数只解析这些日志行并核对日志中的显式求和值。
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
                        "Cocotb 通过 ELF 符号表定位 gemma_stage_cycles，"
                        "经 AXI 读取数组后打印到该原始日志。"
                    ),
                }
            )
    return profiles


def parse_test_summaries(paths: Iterable[Path]) -> list[dict]:
    """读取每份日志最后一个 Cocotb TESTS/PASS/FAIL/SKIP 汇总。"""
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
    """用完全相同 shape 的独立算子，与完整 Decoder 做可比求和。

    RoPE 和 Cache Append 当前没有独立 runner，因此使用完整 Decoder 内部阶段
    读数补齐；其余项全部来自独立 Cocotb runner 的 ``cycle_count``。若任一
    必需标签缺失，就返回缺失清单而不伪造结果。
    """
    profiled_runs = [profile for profile in decoder_profiles if profile["stages"]]
    if not profiled_runs:
        return None
    decoder = profiled_runs[-1]

    # 同一标签可能同时出现在组合测试和单项测试中；取传入日志顺序中的最后
    # 一条。调用方应把最新、最精确的日志放在参数列表后面。
    by_label: dict[str, dict] = {}
    for sample in samples:
        by_label[sample["label"]] = sample

    terms = [
        ("BF16 RMS Norm Shape: 1x640", 4, "4 次 hidden=640 RMSNorm"),
        ("BF16 RMS Norm Shape: 4x256", 1, "Q RMSNorm"),
        ("BF16 RMS Norm Shape: 1x256", 1, "K RMSNorm"),
        ("BF16 GeMV 1D: 1x640x1024", 1, "Q 投影"),
        ("BF16 GeMV 1D: 1x640x256", 2, "K/V 投影"),
        ("BF16 GeMV 1D: 1x1024x640", 1, "输出投影"),
        ("BF16 GeMV 1D: 1x640x2048", 2, "Gate/Up 投影"),
        ("BF16 GeMV 1D: 1x2048x640", 1, "Down 投影"),
        ("BF16 FlashAttention (Decoder Layer Exact Shape)", 1, "FlashAttention"),
        ("BF16 TanhGELU x Up Mul Shape: 1x2048", 1, "Tanh-GELU × Up"),
        ("BF16 Residual Add Shape: 1x640", 2, "2 次残差加"),
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
    """运行一个算子的 Bazel 测试，并将完整 stdout/stderr 保存为原始证据。"""
    raw_dir = output_dir / "raw_logs"
    raw_dir.mkdir(parents=True, exist_ok=True)
    log_path = raw_dir / f"{spec.key}.log"
    # --batch 不复用旧 Bazel server，确保本次 JAVA_HOME 生效。Host 编译器由
    # 仓库的默认 Bazel toolchain 解析，避免绑定某台机器的 LLVM 安装路径。
    command = [bazel, "--batch", "test", spec.bazel_target, "--test_output=all"]
    command.append("--test_env=GEMMA_PROFILE_ONLY=1")
    command.extend(f"--test_env={value}" for value in extra_test_env)
    if spec.test_filter:
        command.append(f"--test_filter={spec.test_filter}")
    # 流式转发输出：首次 Verilator/Cocotb 构建可能很久，不能等命令结束后才让
    # 使用者看到状态。同时将相同内容保存为可审计的原始日志。
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
            f"Bazel 目标失败：{spec.bazel_target}，退出码 {return_code}；"
            f"完整日志：{log_path}"
        )
    return log_path


def write_csv(path: Path, samples: list[dict]) -> None:
    """写出便于表格软件查看的扁平 CSV；空样本也会写出列头。"""
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
    """生成最小 Markdown 表格，避免额外依赖。"""
    if not rows:
        return ""
    header = "| " + " | ".join(rows[0]) + " |"
    separator = "| " + " | ".join(["---"] * len(rows[0])) + " |"
    body = ["| " + " | ".join(row) + " |" for row in rows[1:]]
    return "\n".join([header, separator, *body])


def write_markdown(path: Path, report: dict) -> None:
    """写出面向阅读的报告，并把数据来源与读取方法放在报告开头。"""
    lines = [
        "# Gemma RVV 算子 Profiling 报告",
        "",
        f"生成时间：{report['generated_at']}",
        "",
        "## cycle 数据从哪里来",
        "",
        "1. 每个 C++ runner 在 kernel 调用前后执行 `mcycle_read()`，差值写入 ELF 全局变量 `cycle_count`。",
        "2. Cocotb 通过 `Fixture.load_elf_and_lookup_symbols()` 解析 ELF 符号表中的 `cycle_count` 地址。",
        "3. 测试通过 `Fixture.read()` 或 `Fixture.read_word()` 经 AXI 读取该地址，并由 `sw/utils/metrics.py` 打印性能块。",
        "4. 本脚本保存完整 Bazel/Cocotb 日志，再从性能块中解析数值；因此 JSON、CSV、Markdown 都可回溯到 raw_logs。",
        "",
        "`kernel_cycles` 是 NPU 程序内 mcycle 差值；它不等同于 host 耗时。若测试代码记录 `run_to_halt()` 返回值，"
        "那是从启动到 halted 的仿真总时钟数，应单独比较。",
        "",
        "## 已验证的源码证据",
        "",
    ]
    evidence_rows = [["算子", "runner", "mcycle_read 行", "cycle_count 行", "测试读取行"]]
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

    lines.extend(["## 实测结果", ""])
    if report["samples"]:
        sample_rows = [["算子", "测试形状/标签", "Kernel cycles", "工作量", "工作量/cycle", "cycles/工作量"]]
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
            "尚未解析到动态测试结果。请使用 `--execute` 运行全部测试，或用 `--from-log` 导入已有 Cocotb 日志。",
            "",
        ])

    lines.extend(["## 测试通过情况", ""])
    if report["test_summaries"]:
        status_rows = [["原始日志", "Tests", "Pass", "Fail", "Skip"]]
        for summary in report["test_summaries"]:
            status_rows.append([
                summary["raw_log"], str(summary["tests"]), str(summary["pass"]),
                str(summary["fail"]), str(summary["skip"]),
            ])
        lines.extend([markdown_table(status_rows), ""])
    else:
        lines.extend(["日志中没有找到 Cocotb 汇总行。", ""])

    lines.extend(["## 历史 mytest 与当前逐阶段版本", ""])
    if report["decoder_profiles"]:
        history_rows = [["顺序", "完整层 cycles", "包含逐阶段数据", "原始日志"]]
        for index, profile in enumerate(report["decoder_profiles"], start=1):
            history_rows.append([
                str(index), f"{profile['total_cycles']:,}",
                "是" if profile["stages"] else "否", profile["raw_log"],
            ])
        lines.extend([markdown_table(history_rows), ""])
        if len(report["decoder_profiles"]) >= 2:
            old_cycles = report["decoder_profiles"][0]["total_cycles"]
            new_cycles = report["decoder_profiles"][-1]["total_cycles"]
            difference = new_cycles - old_cycles
            lines.extend([
                f"首份旧 mytest 日志为 **{old_cycles:,} cycles**，当前逐阶段版本为 "
                f"**{new_cycles:,} cycles**，差 **{difference:+,} cycles "
                f"({difference * 100.0 / old_cycles:+.6f}%)**。",
                "",
                "这两份日志来自不同 ELF：逐阶段版本加入了 19 组 `mcycle_read()` "
                "与数组写回，改变了程序大小、代码布局及缓存状态。因此它们适合展示历史变化，"
                "但不能把差值直接解释成某个 kernel 的回归。严格求和应使用下方同一次逐阶段运行，"
                "并用相同 DDR 条件的独立 runner 交叉验证。",
                "",
            ])

    lines.extend(["## 完整 Decoder 逐阶段 cycle", ""])
    profiled_decoders = [
        profile for profile in report["decoder_profiles"] if profile["stages"]
    ]
    if profiled_decoders:
        decoder = profiled_decoders[-1]
        stage_rows = [["阶段", "日志 key", "Cycles", "占完整层比例"]]
        for key, cycles in decoder["stages"].items():
            stage_rows.append([
                DECODER_STAGE_NAMES_ZH.get(key, key), key, f"{cycles:,}",
                f"{cycles * 100.0 / decoder['total_cycles']:.4f}%",
            ])
        lines.extend([
            f"完整层总计：**{decoder['total_cycles']:,} cycles**；"
            f"阶段计算和：**{decoder['stage_sum_calculated']:,} cycles**；"
            f"未归因：**{decoder['unattributed_cycles_calculated']:,} cycles**。",
            "",
            markdown_table(stage_rows),
            "",
        ])
    else:
        lines.extend(["没有导入包含 `gemma_stage_cycles` 的 Decoder 日志。", ""])

    lines.extend(["## 独立算子求和与完整 Decoder 对比", ""])
    comparison = report["decoder_comparison"]
    if comparison and not comparison.get("missing_labels"):
        term_rows = [["组成", "独立测试标签", "单次 cycles", "次数", "小计"]]
        for term in comparison["standalone_terms"]:
            term_rows.append([
                term["meaning"], term["label"], f"{term['cycles_each']:,}",
                str(term["multiplier"]), f"{term['subtotal_cycles']:,}",
            ])
        for key, cycles in comparison["integrated_only_terms"].items():
            term_rows.append([
                f"{DECODER_STAGE_NAMES_ZH.get(key, key)}（暂无独立 runner）",
                "完整 Decoder 内部阶段读取", f"{cycles:,}", "1", f"{cycles:,}",
            ])
        lines.extend([
            markdown_table(term_rows),
            "",
            f"- 独立 kernel 合计：**{comparison['standalone_kernel_sum']:,} cycles**。",
            f"- 加上 RoPE/Cache 阶段后：**{comparison['standalone_plus_integrated_only_sum']:,} cycles**。",
            f"- 完整 Decoder 的 19 阶段和：**{comparison['decoder_stage_sum']:,} cycles**，"
            f"相差 **{comparison['standalone_vs_stage_sum_difference']:+,} cycles**。",
            f"- 完整 Decoder 总计：**{comparison['decoder_total_cycles']:,} cycles**，"
            f"相差 **{comparison['standalone_vs_total_difference']:+,} cycles "
            f"({comparison['standalone_vs_total_difference_percent']:.6f}%)**。",
            "",
        ])
    elif comparison:
        lines.extend([
            "缺少以下精确 shape，无法进行不掺杂估算的求和：",
            "",
            *[f"- `{label}`" for label in comparison["missing_labels"]],
            "",
        ])
    else:
        lines.extend(["没有包含逐阶段数据的完整 Decoder 日志，无法比较。", ""])

    lines.extend(["## 算子特性清单", ""])
    spec_rows = [["算子", "数据类型", "Bazel 目标", "特性"]]
    for spec in report["operators"]:
        spec_rows.append([
            spec["name"], ", ".join(spec["dtypes"]), f"`{spec['bazel_target']}`", spec["feature_summary"],
        ])
    lines.append(markdown_table(spec_rows))
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> int:
    """主流程：先收集源码证据，再按需要执行/解析日志，最后写三种报告。"""
    args = parse_args()
    workspace = require_workspace(args.workspace)
    output_dir = (args.output_dir or workspace / GEMMA_KERNEL_DIR / "profiling/results").resolve()
    output_dir.mkdir(parents=True, exist_ok=True)
    selected = [SPEC_BY_KEY[key] for key in (args.operators or [spec.key for spec in SPECS])]
    log_paths = [path.expanduser().resolve() for path in args.from_log]
    missing_logs = [path for path in log_paths if not path.is_file()]
    if missing_logs:
        raise FileNotFoundError(f"找不到日志：{', '.join(str(path) for path in missing_logs)}")

    if args.execute:
        if shutil.which(args.bazel) is None and not Path(args.bazel).is_file():
            raise FileNotFoundError(f"找不到 Bazel：{args.bazel}")
        for spec in selected:
            print(f"[profile] 运行 {spec.name}: {spec.bazel_target}", flush=True)
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
            "kernel_cycles": "ELF 符号 cycle_count，经 Cocotb Fixture 的 AXI 读取后写入性能日志。",
            "work_count": "由测试用例中的矩阵形状/元素数计算，并由 sw/utils/metrics.py 打印。",
            "derived_metrics": "本工具使用实测 kernel_cycles 与日志中的 MACs/Elements 相除得到。",
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
    print(f"[profile] JSON 报告：{json_path}")
    print(f"[profile] CSV 报告：{csv_path}")
    print(f"[profile] Markdown 报告：{markdown_path}")
    print(f"[profile] 已解析 {len(samples)} 条动态样本。")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (FileNotFoundError, RuntimeError, ValueError) as error:
        print(f"[profile] 错误：{error}", file=sys.stderr)
        raise SystemExit(2)
