#!/usr/bin/env python3
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
"""Deterministically partitions Bazel test targets across CI worker shards.

Queries matching Bazel leaf test targets, estimates per-target execution cost
from Bazel `size`/`timeout`/`cpu:N`/`shard_count` attributes, and assigns
targets evenly across N shards using Longest-Processing-Time (LPT) bin-packing.

When `--tag-filters` is omitted or empty, default `test --test_tag_filters`
values are read from `.bazelrc` so CI shards stay aligned with `bazel test`.

Example usage:
  python3 utils/shard_bazel_tests.py \\
    --shard-index=0 \\
    --shard-count=5 \\
    --summary \\
    --output=/tmp/shard_targets.txt \\
    -- //...
  # Guard against empty shards (`shard_count > len(filtered)` exits 4) and
  # pass `--skip_incompatible_explicit_targets` since unconfigured `bazel query`
  # includes targets skipped by `target_compatible_with`.
  if [ -s /tmp/shard_targets.txt ]; then
    bazel test --skip_incompatible_explicit_targets \\
      --target_pattern_file=/tmp/shard_targets.txt
  fi

Repository verification:
  python3 utils/shard_bazel_tests.py --verify
"""

from __future__ import annotations

import argparse
import ast
from dataclasses import dataclass
import os
import re
import shlex
import subprocess
import sys
from typing import Sequence
import xml.etree.ElementTree as ET

SIZE_WEIGHTS: dict[str, float] = {
    "small": 2.0,
    "medium": 12.0,
    "large": 45.0,
    "enormous": 180.0,
}

TIMEOUT_WEIGHTS: dict[str, float] = {
    "short": 2.0,
    "moderate": 12.0,
    "long": 45.0,
    "eternal": 180.0,
}

SHARD_OVERHEAD_FACTOR = 0.15
DEFAULT_VERIFY_SHARD_COUNT = 5
_DECORATED_DEF_RE = re.compile(
    r"@(?:[\w.]*\.)?(?:coralflow_test|cocotb\.test)\b"
    r"(?:\([^)]*\))?\s*(?:async\s+)?def\s+([A-Za-z_]\w*)",
    re.M,
)
_DYNAMIC_CORALFLOW_RE = re.compile(
    r"(?<![@\w.])(?:[\w.]*\.)?coralflow_test\s*\(\s*[A-Za-z_]"
)


@dataclass(frozen=True)
class TestTarget:
    """Metadata extracted from `bazel query --output=xml` for a test rule."""

    label: str
    rule_class: str
    size: str = "medium"
    timeout: str | None = None
    shard_count: int = 1
    tags: tuple[str, ...] = ()
    model: str | None = None

    @property
    def affinity_key(self) -> str:
        if self.model:
            return self.model
        return self.label.split(":", 1)[0]


def _resolve_import_path(
    raw_import: str,
    current_rc: str,
    workspace_root: str,
) -> str:
    if raw_import.startswith("%workspace%/"):
        return os.path.join(workspace_root, raw_import[len("%workspace%/"):])
    if raw_import == "%workspace%":
        return workspace_root
    if os.path.isabs(raw_import):
        return raw_import
    ws_candidate = os.path.join(workspace_root, raw_import)
    if os.path.exists(ws_candidate):
        return ws_candidate
    return os.path.join(
        os.path.dirname(os.path.abspath(current_rc)), raw_import
    )


def read_bazelrc_test_tag_filters(
    bazelrc_path: str = ".bazelrc",
    workspace_root: str | None = None,
) -> str:
    """Reads unscoped `common`/`test --test_tag_filters` from `.bazelrc`.

    Matches Bazel `allowMultiple` accumulation semantics across repeated flags
    and recursively follows `import` and `try-import` directives.
    """
    if not bazelrc_path or not os.path.exists(bazelrc_path):
        return ""
    ws_root = workspace_root or (
        os.path.dirname(os.path.abspath(bazelrc_path)) or "."
    )
    collected: list[str] = []
    visited: set[str] = set()

    def _scan_rc(rc_path: str) -> None:
        if not os.path.isfile(rc_path):
            return
        real = os.path.realpath(rc_path)
        if real in visited:
            return
        visited.add(real)
        with open(rc_path, "r", encoding="utf-8") as f:
            for raw_line in f:
                line = raw_line.strip()
                if not line or line.startswith("#"):
                    continue
                try:
                    tokens = shlex.split(line, comments=True)
                except ValueError:
                    continue
                if len(tokens) < 2:
                    continue
                cmd = tokens[0]
                if cmd in ("import", "try-import"):
                    target = _resolve_import_path(tokens[1], rc_path, ws_root)
                    _scan_rc(target)
                    continue
                if cmd not in ("test", "common"):
                    continue
                idx = 1
                while idx < len(tokens):
                    tok = tokens[idx]
                    if tok.startswith("--test_tag_filters="):
                        val = tok.split("=", 1)[1].strip()
                        if val:
                            collected.append(val)
                    elif tok == "--test_tag_filters" and idx + 1 < len(tokens):
                        val = tokens[idx + 1].strip()
                        if val:
                            collected.append(val)
                        idx += 1
                    idx += 1

    _scan_rc(bazelrc_path)
    return ",".join(collected)


def parse_tag_filters(
    tag_filters: str,
) -> tuple[frozenset[str], frozenset[str]]:
    """Parses `--test_tag_filters` into `(required_any, excluded)` sets."""
    positive: set[str] = set()
    negative: set[str] = set()
    for raw in tag_filters.split(","):
        token = raw.strip()
        if not token:
            continue
        if token.startswith("-"):
            if len(token) > 1:
                negative.add(token[1:])
        elif token.startswith("+"):
            if len(token) > 1:
                positive.add(token[1:])
        else:
            positive.add(token)
    return frozenset(positive), frozenset(negative)


def matches_tag_filters(
    tags: Sequence[str],
    positive: frozenset[str],
    negative: frozenset[str],
) -> bool:
    """Returns True if `tags` satisfies Bazel `--test_tag_filters` semantics."""
    tag_set = set(tags)
    if negative and (tag_set & negative):
        return False
    if positive and not tag_set & positive:
        return False
    return True


def _is_wildcard_pattern(pattern: str) -> bool:
    stripped = pattern.lstrip("-")
    return (
        stripped.endswith("/...") or stripped == "..."
        or stripped.endswith(":all") or stripped.endswith(":*")
    )


def _pattern_test_expr(pat: str, *, include_manual: bool) -> str:
    if not include_manual and _is_wildcard_pattern(pat):
        # Match `bazel test` wildcard semantics: skip `manual` targets and
        # `manual` test_suites, while expanding non-manual test_suites.
        non_manual = f'({pat} except attr(tags, "\\bmanual\\b", {pat}))'
        return f"tests({non_manual})"
    return f"tests({pat})"


def build_bazel_query(patterns: Sequence[str]) -> str:
    """Builds a Bazel query expression matching left-to-right `bazel test` patterns."""
    cleaned = [raw.strip() for raw in patterns if raw.strip()]
    if not cleaned:
        cleaned = ["//..."]
    elif not any(not p.startswith("-") for p in cleaned):
        cleaned = ["//...", *cleaned]

    expr: str | None = None
    for pat in cleaned:
        if pat.startswith("-"):
            neg_pat = pat[1:]
            if not neg_pat or expr is None:
                continue
            term = _pattern_test_expr(neg_pat, include_manual=True)
            expr = f"({expr}) except ({term})"
        else:
            pos_pat = pat.lstrip("+")
            if not pos_pat:
                continue
            term = _pattern_test_expr(pos_pat, include_manual=False)
            expr = term if expr is None else f"({expr}) + ({term})"

    return expr or _pattern_test_expr("//...", include_manual=False)


def _get_rule_int_attr(
    rule: ET.Element,
    attr_name: str,
    default: int = 1,
) -> int:
    for i_elem in rule.findall("int"):
        if i_elem.attrib.get("name") == attr_name:
            try:
                return int(i_elem.attrib.get("value", str(default)))
            except ValueError:
                return default
    return default


def parse_query_xml(xml_bytes: bytes) -> list[TestTarget]:
    """Parses `bazel query --output=xml` bytes into sorted TestTargets."""
    root = ET.fromstring(xml_bytes)
    targets: dict[str, TestTarget] = {}
    for rule in root.findall("rule"):
        cls = rule.attrib.get("class", "")
        if cls == "test_suite":
            continue
        label = rule.attrib["name"]
        size = "medium"
        timeout: str | None = None
        shard_count = max(1, _get_rule_int_attr(rule, "shard_count", 1))
        tags: list[str] = []
        model: str | None = None

        for s_elem in rule.findall("string"):
            attr_name = s_elem.attrib.get("name")
            if attr_name == "size":
                size = s_elem.attrib.get("value", "medium")
            elif attr_name == "timeout":
                timeout = s_elem.attrib.get("value")

        for lst_elem in rule.findall("list"):
            if lst_elem.attrib.get("name") == "tags":
                tags = [
                    s.attrib["value"]
                    for s in lst_elem.findall("string")
                    if "value" in s.attrib
                ]

        for lbl_elem in rule.findall("label"):
            if lbl_elem.attrib.get("name") == "model":
                model = lbl_elem.attrib.get("value")

        targets[label] = TestTarget(
            label=label,
            rule_class=cls,
            size=size,
            timeout=timeout,
            shard_count=shard_count,
            tags=tuple(tags),
            model=model,
        )

    return [targets[k] for k in sorted(targets)]


def _extract_cpu_reservation(tags: Sequence[str]) -> int:
    """Returns `N` from a `cpu:N` tag if present, otherwise 2 (default sim)."""
    for tag in tags:
        if tag.startswith("cpu:"):
            suffix = tag[4:].strip()
            if suffix.isdigit() and int(suffix) > 0:
                return int(suffix)
    return 2


def estimate_target_weight(target: TestTarget) -> float:
    """Estimates execution cost of `target` in relative CPU-seconds."""
    base = SIZE_WEIGHTS.get(target.size, SIZE_WEIGHTS["medium"])
    if target.timeout and target.timeout in TIMEOUT_WEIGHTS:
        base = max(base, TIMEOUT_WEIGHTS[target.timeout])

    cpus = _extract_cpu_reservation(target.tags)
    if cpus > 2:
        base *= min(cpus / 2.0, 4.0)

    if target.shard_count > 1:
        base *= 1.0 + SHARD_OVERHEAD_FACTOR * (target.shard_count - 1)
    return base


def partition_targets(
    targets: Sequence[TestTarget],
    shard_count: int,
) -> tuple[list[list[TestTarget]], list[float]]:
    """Partitions `targets` across `shard_count` buckets via cluster-aware LPT.

    Targets sharing the same simulation model or package (`affinity_key`) are
    grouped into bounded chunks (at most `total_weight / (shard_count * 2.5)`)
    before Longest-Processing-Time bin-packing. This keeps shard weights tightly
    balanced while preserving model locality on cache-miss builds.
    """
    if shard_count < 1:
        raise ValueError(f"shard_count must be >= 1, got {shard_count}")

    shards: list[list[TestTarget]] = [[] for _ in range(shard_count)]
    loads: list[float] = [0.0 for _ in range(shard_count)]
    if not targets:
        return shards, loads

    weighted_by_aff: dict[str, list[tuple[float, TestTarget]]] = {}
    total_weight = 0.0
    for t in targets:
        w = estimate_target_weight(t)
        total_weight += w
        weighted_by_aff.setdefault(t.affinity_key, []).append((w, t))

    max_chunk_weight = total_weight / (shard_count * 2.5)

    # Form bounded affinity chunks so small/medium model suites stay together
    # while large suites split cleanly across shards.
    chunks: list[tuple[float, str, str, list[TestTarget]]] = []
    for aff in sorted(weighted_by_aff):
        items = weighted_by_aff[aff]
        items.sort(key=lambda item: (-item[0], item[1].label))
        cur_targets: list[TestTarget] = []
        cur_weight = 0.0
        for w, t in items:
            if cur_targets and (cur_weight + w) > max_chunk_weight:
                chunks.append(
                    (cur_weight, aff, cur_targets[0].label, cur_targets)
                )
                cur_targets = [t]
                cur_weight = w
            else:
                cur_targets.append(t)
                cur_weight += w
        if cur_targets:
            chunks.append((cur_weight, aff, cur_targets[0].label, cur_targets))

    chunks.sort(key=lambda c: (-c[0], c[1], c[2]))

    affinity_counts: list[dict[str, int]] = [{} for _ in range(shard_count)]
    for chunk_weight, aff, _, chunk_targets in chunks:
        best_idx = min(
            range(shard_count),
            key=lambda i, aff=aff: (
                round(loads[i], 6),
                -affinity_counts[i].get(aff, 0),
                i,
            ),
        )
        shards[best_idx].extend(chunk_targets)
        loads[best_idx] += chunk_weight
        affinity_counts[best_idx][aff] = (
            affinity_counts[best_idx].get(aff, 0) + len(chunk_targets)
        )

    for shard in shards:
        shard.sort(key=lambda t: t.label)
    return shards, loads


def query_bazel_targets(
    bazel_bin: str,
    patterns: Sequence[str],
    extra_query_flags: Sequence[str] = (),
) -> list[TestTarget]:
    """Executes `bazel query --output=xml` and returns parsed TestTargets."""
    query_expr = build_bazel_query(patterns)
    cmd = [
        bazel_bin,
        "query",
        "--noshow_progress",
        "--output=xml",
        *extra_query_flags,
        query_expr,
    ]
    proc = subprocess.run(cmd, stdout=subprocess.PIPE, check=True)
    return parse_query_xml(proc.stdout)


def _label_to_repo_path(label: str, repo_root: str) -> str | None:
    if not label.startswith("//"):
        return None
    body = label[2:]
    if ":" in body:
        pkg, target = body.split(":", 1)
        rel = os.path.join(pkg, target) if pkg else target
    else:
        rel = body
    return os.path.join(repo_root, rel)


def _extract_rule_env_map(rule: ET.Element) -> dict[str, str]:
    env_map: dict[str, str] = {}
    for lst_elem in rule.findall("list"):
        if lst_elem.attrib.get("name") == "extra_env":
            for s_elem in lst_elem.findall("string"):
                val = s_elem.attrib.get("value", "")
                if "=" in val:
                    k, v = val.split("=", 1)
                    env_map[k] = v
    for dict_elem in rule.findall("dict"):
        if dict_elem.attrib.get("name") == "env":
            for pair in dict_elem.findall("pair"):
                strs = pair.findall("string")
                if len(strs) == 2:
                    k = strs[0].attrib.get("value", "")
                    v = strs[1].attrib.get("value", "")
                    if k:
                        env_map[k] = v
    return env_map


def _is_test_decorator(dec: ast.expr) -> bool:
    target = dec.func if isinstance(dec, ast.Call) else dec
    if isinstance(target, ast.Name):
        return target.id == "coralflow_test"
    if isinstance(target, ast.Attribute):
        if target.attr == "coralflow_test":
            return True
        if (isinstance(target.value, ast.Name) and target.value.id == "cocotb"
                and target.attr == "test"):
            return True
    return False


def _inspect_test_source(src_text: str) -> tuple[list[str], bool]:
    """Returns `(decorated_function_names, has_dynamic_registration)`."""
    try:
        tree = ast.parse(src_text)
    except SyntaxError:
        return (
            _DECORATED_DEF_RE.findall(src_text),
            bool(_DYNAMIC_CORALFLOW_RE.search(src_text)),
        )

    names: list[str] = []
    decorator_ids: set[int] = set()
    for node in ast.walk(tree):
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            for dec in node.decorator_list:
                decorator_ids.add(id(dec))
            if any(_is_test_decorator(d) for d in node.decorator_list):
                names.append(node.name)

    has_dynamic = any(
        isinstance(node, ast.Call) and id(node) not in decorator_ids
        and _is_test_decorator(node) for node in ast.walk(tree)
    )
    return names, has_dynamic


def _validate_sharded_rule(rule: ET.Element, repo_root: str) -> list[str]:
    """Validates intra-target `shard_count` bounds for a single XML rule."""
    errors: list[str] = []
    label = rule.attrib["name"]
    shard_count = _get_rule_int_attr(rule, "shard_count", 1)
    if shard_count <= 1:
        return errors

    gen_fn = ""
    for s_elem in rule.findall("string"):
        if s_elem.attrib.get("name") == "generator_function":
            gen_fn = s_elem.attrib.get("value", "")
    if gen_fn != "coralflow_test":
        return errors

    env_map = _extract_rule_env_map(rule)
    tc_csv = env_map.get("CORALFLOW_TESTCASE", "").strip()
    excl = {
        t.strip()
        for t in env_map.get("CORALFLOW_EXCLUDE_TESTCASE", "").split(",")
        if t.strip()
    }
    if tc_csv:
        enabled_tcs = [
            t.strip()
            for t in tc_csv.split(",")
            if t.strip() and t.strip() not in excl
        ]
        if shard_count > len(enabled_tcs):
            errors.append(
                f"{label}: shard_count={shard_count} exceeds enabled "
                f"CORALFLOW_TESTCASE count ({len(enabled_tcs)})."
            )

    if env_map.get("CORALFLOW_UVM_BATCH") == "1":
        return errors

    src_labels: list[str] = []
    for lst_elem in rule.findall("list"):
        if lst_elem.attrib.get("name") in ("test_module", "srcs"):
            for lbl_elem in lst_elem.findall("label"):
                val = lbl_elem.attrib.get("value", "")
                if val.endswith(".py"):
                    src_labels.append(val)

    decorated_names: list[str] = []
    checked_files = 0
    has_dynamic = False
    for src_lbl in src_labels:
        path = _label_to_repo_path(src_lbl, repo_root)
        if path and os.path.isfile(path):
            checked_files += 1
            with open(path, "r", encoding="utf-8") as f:
                src_text = f.read()
            file_names, file_dynamic = _inspect_test_source(src_text)
            decorated_names.extend(file_names)
            if file_dynamic:
                has_dynamic = True

    enabled_decorators = [n for n in decorated_names if n not in excl]
    if (checked_files > 0 and not has_dynamic
            and len(enabled_decorators) < shard_count):
        errors.append(
            f"{label}: shard_count={shard_count} exceeds enabled "
            f"@coralflow_test count ({len(enabled_decorators)}) in "
            f"{src_labels}."
        )
    return errors


def verify_sharding_xml(
    ground_truth_xml: bytes,
    sharded_targets: Sequence[TestTarget],
    shard_count: int,
    tag_filters: str,
    repo_root: str = ".",
) -> tuple[list[str], int, int]:
    """Verifies completeness, disjointness, and intra-target `shard_count`.

    Compares `sharded_targets` partitioned across `shard_count` workers against
    an independent expansion of `tests(//...) + kind("test_suite rule", //...)`.

    Returns `(errors, active_target_count, sharded_rule_count)`.
    """
    errors: list[str] = []
    root = ET.fromstring(ground_truth_xml)

    suites: dict[str, tuple[set[str], list[str]]] = {}
    test_rules: dict[str, tuple[set[str], ET.Element]] = {}
    for rule in root.findall("rule"):
        cls = rule.attrib.get("class", "")
        name = rule.attrib["name"]
        tags = {
            s.attrib["value"]
            for lst in rule.findall("list") if lst.attrib.get("name") == "tags"
            for s in lst.findall("string") if "value" in s.attrib
        }
        if cls == "test_suite":
            members = [
                lbl.attrib["value"] for lst in rule.findall("list")
                if lst.attrib.get("name") == "tests"
                for lbl in lst.findall("label") if "value" in lbl.attrib
            ]
            suites[name] = (tags, members)
        else:
            test_rules[name] = (tags, rule)

    # 1. Independently compute wildcard target expansion (`//...`):
    #    all non-manual test rules + transitive members of non-manual suites.
    candidates: set[str] = {
        name
        for name, (tags, _) in test_rules.items()
        if "manual" not in tags
    }
    suite_queue = [
        name for name, (tags, _) in suites.items() if "manual" not in tags
    ]
    visited_suites = set(suite_queue)
    while suite_queue:
        cur_suite = suite_queue.pop()
        _, members = suites.get(cur_suite, (set(), []))
        for member in members:
            if member in suites:
                if member not in visited_suites:
                    visited_suites.add(member)
                    suite_queue.append(member)
            elif member in test_rules:
                candidates.add(member)

    pos_tags, neg_tags = parse_tag_filters(tag_filters)
    expected_labels = {
        name
        for name in candidates
        if matches_tag_filters(tuple(test_rules[name][0]), pos_tags, neg_tags)
    }

    filtered = [
        t for t in sharded_targets
        if matches_tag_filters(t.tags, pos_tags, neg_tags)
    ]
    shards, _ = partition_targets(filtered, shard_count)

    assigned_list = [t.label for bucket in shards for t in bucket]
    assigned_set = set(assigned_list)

    if len(assigned_list) != len(assigned_set):
        errors.append(
            f"Duplicate test assignments across shards: "
            f"{len(assigned_list)} total vs {len(assigned_set)} unique."
        )

    missing = sorted(expected_labels - assigned_set)
    if missing:
        preview = ", ".join(missing[:10])
        errors.append(
            f"Missed {len(missing)} active test target(s): {preview}"
        )

    unexpected = sorted(assigned_set - expected_labels)
    if unexpected:
        preview = ", ".join(unexpected[:10])
        errors.append(
            f"Included {len(unexpected)} excluded/manual target(s): {preview}"
        )

    if len(expected_labels) >= shard_count:
        empty_shards = [i for i, b in enumerate(shards) if not b]
        if empty_shards:
            errors.append(f"Empty shard(s) produced: {empty_shards}")

    # 2. Validate intra-target `shard_count` on all rules in the repository.
    sharded_rule_count = 0
    for _, (_, rule_elem) in sorted(test_rules.items()):
        if _get_rule_int_attr(rule_elem, "shard_count", 1) > 1:
            sharded_rule_count += 1
            errors.extend(_validate_sharded_rule(rule_elem, repo_root))

    return errors, len(expected_labels), sharded_rule_count


def _resolve_workspace_root(bazel_bin: str) -> str:
    """Resolves the Bazel workspace root directory."""
    try:
        proc = subprocess.run(
            [bazel_bin, "info", "--noshow_progress", "workspace"],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            check=True,
        )
        ws = proc.stdout.strip()
        if ws:
            return ws
    except (OSError, subprocess.CalledProcessError):
        pass
    return os.environ.get("BUILD_WORKSPACE_DIRECTORY") or os.getcwd()


def run_repo_verification(
    bazel_bin: str,
    shard_count: int,
    tag_filters: str,
    repo_root: str = ".",
) -> int:
    """Runs live repository sharding verification against `bazel query`."""
    gt_cmd = [
        bazel_bin,
        "query",
        "--noshow_progress",
        "--output=xml",
        'tests(//...) + kind("test_suite rule", //...)',
    ]
    gt_proc = subprocess.run(gt_cmd, stdout=subprocess.PIPE, check=True)
    sharded_targets = query_bazel_targets(bazel_bin, ["//..."])

    errors, active_count, sharded_rules = verify_sharding_xml(
        ground_truth_xml=gt_proc.stdout,
        sharded_targets=sharded_targets,
        shard_count=shard_count,
        tag_filters=tag_filters,
        repo_root=repo_root,
    )
    if errors:
        print("❌ Bazel test sharding verification failed:", file=sys.stderr)
        for err in errors:
            print(f"  - {err}", file=sys.stderr)
        return 1

    print(
        f"✅ Verified Bazel test sharding: {active_count} active tests "
        f"partitioned across {shard_count} shards (0 missed, 0 duplicates; "
        f"{sharded_rules} sharded rules valid)."
    )
    return 0


def _resolve_tag_filters(
    cli_tag_filters: str | None,
    use_bazelrc: bool,
    bazelrc_path: str,
    workspace_root: str | None = None,
) -> str:
    if cli_tag_filters:
        return cli_tag_filters
    if use_bazelrc:
        return read_bazelrc_test_tag_filters(
            bazelrc_path, workspace_root=workspace_root
        )
    return ""


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Deterministically shard Bazel test targets across workers."
    )
    parser.add_argument(
        "--shard-index",
        type=int,
        default=None,
        help="0-based index of this worker shard (or $SHARD_INDEX).",
    )
    parser.add_argument(
        "--shard-count",
        type=int,
        default=None,
        help="Total number of worker shards (or $SHARD_COUNT).",
    )
    parser.add_argument(
        "--tag-filters",
        default=None,
        help=(
            "Comma-separated Bazel --test_tag_filters expression "
            "(defaults to `test --test_tag_filters` from .bazelrc)."
        ),
    )
    parser.add_argument(
        "--bazelrc",
        default=".bazelrc",
        help=
        "Path to .bazelrc for default test_tag_filters (default: .bazelrc).",
    )
    parser.add_argument(
        "--no-bazelrc-filters",
        action="store_true",
        help="Do not read default test_tag_filters from .bazelrc.",
    )
    parser.add_argument(
        "--output",
        default=None,
        help="Path to write selected target labels (default: stdout).",
    )
    parser.add_argument(
        "--bazel",
        default="bazel",
        help="Bazel executable name or path (default: bazel).",
    )
    parser.add_argument(
        "--summary",
        action="store_true",
        help="Print shard distribution summary to stderr.",
    )
    parser.add_argument(
        "--verify",
        action="store_true",
        help="Verify sharding completeness and shard_count bounds on the repo.",
    )
    parser.add_argument(
        "patterns",
        nargs="*",
        help="Bazel target patterns (default: //...).",
    )

    args = parser.parse_args(argv)

    shard_count = (
        args.shard_count if args.shard_count is not None else (
            int(os.environ["SHARD_COUNT"])
            if os.environ.get("SHARD_COUNT") else None
        )
    )

    if args.verify:
        verify_shards = shard_count or DEFAULT_VERIFY_SHARD_COUNT
        if verify_shards < 1:
            parser.error(f"--shard-count must be >= 1, got {verify_shards}.")
        repo_root = _resolve_workspace_root(args.bazel)
        tag_filters = _resolve_tag_filters(
            args.tag_filters,
            use_bazelrc=not args.no_bazelrc_filters,
            bazelrc_path=args.bazelrc,
            workspace_root=repo_root,
        )
        return run_repo_verification(
            bazel_bin=args.bazel,
            shard_count=verify_shards,
            tag_filters=tag_filters,
            repo_root=repo_root,
        )

    tag_filters = _resolve_tag_filters(
        args.tag_filters,
        use_bazelrc=not args.no_bazelrc_filters,
        bazelrc_path=args.bazelrc,
    )

    shard_index = (
        args.shard_index if args.shard_index is not None else (
            int(os.environ["SHARD_INDEX"])
            if os.environ.get("SHARD_INDEX") else None
        )
    )

    if shard_index is None or shard_count is None:
        parser.error("--shard-index and --shard-count are required.")
    if shard_count < 1:
        parser.error(f"--shard-count must be >= 1, got {shard_count}.")
    if shard_index < 0 or shard_index >= shard_count:
        max_idx = shard_count - 1
        parser.error(
            f"--shard-index must be in [0, {max_idx}], got {shard_index}."
        )

    patterns = list(args.patterns)
    if patterns and patterns[0] == "--":
        patterns = patterns[1:]
    if not patterns:
        patterns = ["//..."]

    all_targets = query_bazel_targets(args.bazel, patterns)
    pos_tags, neg_tags = parse_tag_filters(tag_filters)
    filtered = [
        t for t in all_targets
        if matches_tag_filters(t.tags, pos_tags, neg_tags)
    ]

    shards, loads = partition_targets(filtered, shard_count)
    selected = shards[shard_index]

    if args.summary:
        total_weight = sum(loads)
        print(
            f"[shard_bazel_tests] Filtered {len(filtered)}/{len(all_targets)} "
            f"targets across {shard_count} shards "
            f"(total weight={total_weight:.1f}, filters='{tag_filters}'):",
            file=sys.stderr,
        )
        for idx, (bucket, load) in enumerate(zip(shards, loads)):
            marker = " <-- selected" if idx == shard_index else ""
            print(
                f"  shard {idx}/{shard_count}: {len(bucket):3d} targets, "
                f"weight={load:7.1f}{marker}",
                file=sys.stderr,
            )

    out_text = "".join(f"{t.label}\n" for t in selected)
    if args.output:
        parent = os.path.dirname(os.path.abspath(args.output))
        if parent:
            os.makedirs(parent, exist_ok=True)
        with open(args.output, "w", encoding="utf-8") as f:
            f.write(out_text)
    else:
        sys.stdout.write(out_text)

    return 0


if __name__ == "__main__":
    sys.exit(main())
