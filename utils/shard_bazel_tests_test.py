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
"""Unit tests for shard_bazel_tests."""

import os
import tempfile
from unittest import mock
import unittest

from utils.shard_bazel_tests import (
    TestTarget,
    build_bazel_query,
    estimate_target_weight,
    main,
    matches_tag_filters,
    parse_query_xml,
    parse_tag_filters,
    partition_targets,
    read_bazelrc_test_tag_filters,
    verify_sharding_xml,
)

SAMPLE_QUERY_XML = b"""<?xml version="1.1" encoding="UTF-8" standalone="no"?>
<query version="2">
  <rule class="cocotb_test" name="//tests/cocotb:big_rvv_test">
    <string name="generator_function" value="coralflow_test"/>
    <string name="size" value="enormous"/>
    <int name="shard_count" value="4"/>
    <list name="tags">
      <string value="verilator"/>
      <string value="rtl"/>
    </list>
    <list name="extra_env">
      <string value="CORALFLOW_TESTCASE=tc1,tc2,tc3,tc4"/>
    </list>
    <label name="model" value="//tests/cocotb:rvv_core_mini_axi_model"/>
  </rule>
  <rule class="cocotb_test" name="//tests/cocotb:vcs_only_test">
    <string name="size" value="large"/>
    <list name="tags">
      <string value="vcs"/>
    </list>
    <label name="model" value="//tests/cocotb:rvv_core_mini_axi_vcs_model"/>
  </rule>
  <rule class="_sim_test" name="//fpga:clk_sim_test">
    <string name="size" value="large"/>
    <string name="timeout" value="long"/>
    <list name="tags">
      <string value="cpu:8"/>
    </list>
  </rule>
  <rule class="scala_test" name="//hdl/chisel:manual_scalatest">
    <string name="size" value="large"/>
    <list name="tags">
      <string value="manual"/>
    </list>
  </rule>
  <rule class="py_test" name="//utils:fast_unit_test">
    <string name="size" value="small"/>
    <list name="tags"/>
  </rule>
  <rule class="test_suite" name="//tests/cocotb:some_suite">
    <list name="tags"/>
    <list name="tests">
      <label value="//tests/cocotb:big_rvv_test"/>
    </list>
  </rule>
</query>
"""


class ShardBazelTestsTest(unittest.TestCase):

    def test_read_bazelrc_test_tag_filters(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            rc_path = os.path.join(tmpdir, ".bazelrc")
            extra_path = os.path.join(tmpdir, "extra.bazelrc")
            with open(extra_path, "w", encoding="utf-8") as f:
                f.write(
                    'test --test_tag_filters="-spyglass"\n'
                    "try-import %workspace%/.bazelrc\n"
                )
            with open(rc_path, "w", encoding="utf-8") as f:
                f.write(
                    "# Comment line\n"
                    'build --build_tag_filters="-vcs,-synthesis"\n'
                    'common --test_tag_filters="-vcs"\n'
                    'test --test_tag_filters="-synthesis,-power"\n'
                    'test:vcs --test_tag_filters="vcs"\n'
                    "import %workspace%/extra.bazelrc\n"
                    "try-import %workspace%/missing.bazelrc\n"
                )
            self.assertEqual(
                read_bazelrc_test_tag_filters(rc_path, workspace_root=tmpdir),
                "-vcs,-synthesis,-power,-spyglass",
            )

    def test_tag_filter_matching(self):
        pos, neg = parse_tag_filters(
            "-exclusive,-vcs,-synthesis,-power,-spyglass"
        )
        self.assertEqual(pos, frozenset())
        self.assertEqual(
            neg,
            frozenset({"exclusive", "vcs", "synthesis", "power", "spyglass"}),
        )
        self.assertTrue(matches_tag_filters(["verilator", "rtl"], pos, neg))
        self.assertFalse(matches_tag_filters(["exclusive"], pos, neg))
        self.assertFalse(matches_tag_filters(["vcs", "rtl"], pos, neg))

        excl_pos, excl_neg = parse_tag_filters("exclusive,-vcs,-synthesis")
        self.assertTrue(matches_tag_filters(["exclusive"], excl_pos, excl_neg))
        self.assertFalse(
            matches_tag_filters(["exclusive", "vcs"], excl_pos, excl_neg)
        )
        self.assertFalse(
            matches_tag_filters(["verilator"], excl_pos, excl_neg)
        )

    def test_build_bazel_query_wildcards_exclude_manual(self):
        q = build_bazel_query(["//..."])
        self.assertIn('except attr(tags, "\\bmanual\\b", //...)', q)
        self.assertNotIn("\\\\b", q)
        self.assertTrue(q.startswith("tests("))

        q_explicit = build_bazel_query([
            "//tests/cocotb:my_test", "-//fpga/..."
        ])
        self.assertEqual(
            q_explicit,
            "(tests(//tests/cocotb:my_test)) except (tests(//fpga/...))",
        )

        # Left-to-right pattern folding preserves re-included targets after `-`.
        q_reinclude = build_bazel_query([
            "//...",
            "-//fpga/...",
            "//fpga:check_pins_test",
        ])
        self.assertEqual(
            q_reinclude,
            "((tests((//... except attr(tags, \"\\bmanual\\b\", //...)))) "
            "except (tests(//fpga/...))) + (tests(//fpga:check_pins_test))",
        )

        # Leading negative patterns subtract from `//...`.
        q_neg_only = build_bazel_query(["-//fpga/..."])
        self.assertEqual(
            q_neg_only,
            "(tests((//... except attr(tags, \"\\bmanual\\b\", //...)))) "
            "except (tests(//fpga/...))",
        )

    def test_parse_query_xml_skips_test_suites(self):
        targets = parse_query_xml(SAMPLE_QUERY_XML)
        labels = [t.label for t in targets]
        self.assertEqual(
            labels,
            [
                "//fpga:clk_sim_test",
                "//hdl/chisel:manual_scalatest",
                "//tests/cocotb:big_rvv_test",
                "//tests/cocotb:vcs_only_test",
                "//utils:fast_unit_test",
            ],
        )
        rvv = next(
            t for t in targets if t.label == "//tests/cocotb:big_rvv_test"
        )
        self.assertEqual(rvv.size, "enormous")
        self.assertEqual(rvv.shard_count, 4)
        self.assertEqual(rvv.model, "//tests/cocotb:rvv_core_mini_axi_model")
        self.assertEqual(rvv.tags, ("verilator", "rtl"))

    def test_partition_targets_is_complete_disjoint_and_balanced(self):
        targets = [
            TestTarget("//pkg:enormous_a", "cocotb_test", size="enormous"),
            TestTarget("//pkg:enormous_b", "cocotb_test", size="enormous"),
            TestTarget("//pkg:large_a", "cocotb_test", size="large"),
            TestTarget("//pkg:large_b", "cocotb_test", size="large"),
            TestTarget("//pkg:large_c", "cocotb_test", size="large"),
            TestTarget("//pkg:large_d", "cocotb_test", size="large"),
        ] + [
            TestTarget(f"//pkg:med_{i:02d}", "cocotb_test", size="medium")
            for i in range(20)
        ]

        shards, loads = partition_targets(targets, shard_count=4)
        all_assigned = [t.label for bucket in shards for t in bucket]
        self.assertEqual(len(all_assigned), len(targets))
        self.assertEqual(set(all_assigned), {t.label for t in targets})
        self.assertLessEqual(max(loads) - min(loads), 45.0)

        shards2, loads2 = partition_targets(
            list(reversed(targets)), shard_count=4
        )
        self.assertEqual(shards, shards2)
        self.assertEqual(loads, loads2)

    def test_affinity_clustering_groups_same_model(self):
        targets = [
            TestTarget(
                f"//a:m{m}_{i}",
                "cocotb_test",
                size="medium",
                model=f"//m:model_{m}",
            ) for m in range(6) for i in range(2)
        ]
        shards, loads = partition_targets(targets, shard_count=2)
        self.assertEqual(loads, [72.0, 72.0])
        s0_models = {t.model for t in shards[0]}
        s1_models = {t.model for t in shards[1]}
        self.assertEqual(s0_models & s1_models, set())

    def test_size_and_cpu_tag_weights(self):
        target = TestTarget("//a:fast_small", "py_test", size="small")
        self.assertEqual(estimate_target_weight(target), 2.0)
        fpga_sim = TestTarget(
            "//fpga:clk_sim_test",
            "_sim_test",
            size="large",
            timeout="long",
            tags=("cpu:8", ),
        )
        self.assertEqual(estimate_target_weight(fpga_sim), 180.0)

    def test_verify_sharding_xml_detects_missing_and_excess_shards(self):
        non_manual = [
            t for t in parse_query_xml(SAMPLE_QUERY_XML)
            if "manual" not in t.tags
        ]
        errors, active_cnt, sharded_cnt = verify_sharding_xml(
            ground_truth_xml=SAMPLE_QUERY_XML,
            sharded_targets=non_manual,
            shard_count=2,
            tag_filters="-vcs",
        )
        self.assertEqual(errors, [])
        self.assertEqual(active_cnt, 3)
        self.assertEqual(sharded_cnt, 1)

        # Simulate a bug that drops `//utils:fast_unit_test`.
        dropped = [
            t for t in non_manual if t.label != "//utils:fast_unit_test"
        ]
        errors_missing, _, _ = verify_sharding_xml(
            ground_truth_xml=SAMPLE_QUERY_XML,
            sharded_targets=dropped,
            shard_count=2,
            tag_filters="-vcs",
        )
        self.assertTrue(
            any("Missed 1 active test" in e for e in errors_missing),
            errors_missing,
        )

        # Simulate `shard_count` exceeding `CORALFLOW_TESTCASE` count.
        bad_xml = SAMPLE_QUERY_XML.replace(
            b'shard_count" value="4"', b'shard_count" value="9"'
        )
        errors_bad_shard, _, _ = verify_sharding_xml(
            ground_truth_xml=bad_xml,
            sharded_targets=non_manual,
            shard_count=2,
            tag_filters="-vcs",
        )
        self.assertTrue(
            any(
                "exceeds enabled CORALFLOW_TESTCASE" in e
                for e in errors_bad_shard
            ),
            errors_bad_shard,
        )

        # Malformed `shard_count` int attribute does not raise ValueError.
        malformed_xml = SAMPLE_QUERY_XML.replace(
            b'shard_count" value="4"', b'shard_count" value="invalid"'
        )
        errors_malformed, _, sharded_malformed = verify_sharding_xml(
            ground_truth_xml=malformed_xml,
            sharded_targets=non_manual,
            shard_count=2,
            tag_filters="-vcs",
        )
        self.assertEqual(errors_malformed, [])
        self.assertEqual(sharded_malformed, 0)

    def test_verify_sharding_subtracts_excluded_decorators(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            pkg_dir = os.path.join(tmpdir, "tests", "coralflow")
            os.makedirs(pkg_dir, exist_ok=True)
            py_path = os.path.join(pkg_dir, "sample_test.py")
            with open(py_path, "w", encoding="utf-8") as f:
                f.write(
                    "from coralnpu_test_utils.coralflow.runner import coralflow_test\n\n"
                    + "\n".join(
                        f"@coralflow_test(highmem=True)\n"
                        f"async def tc_{i}(fixture):\n    pass\n"
                        for i in range(5)
                    )
                )

            def _make_xml(shards: int) -> bytes:
                return f"""<?xml version="1.1" encoding="UTF-8" standalone="no"?>
<query version="2">
  <rule class="py_test" name="//tests/coralflow:sample_test_uvm">
    <string name="generator_function" value="coralflow_test"/>
    <int name="shard_count" value="{shards}"/>
    <list name="tags"><string value="uvm"/></list>
    <list name="srcs"><label value="//tests/coralflow:sample_test.py"/></list>
    <dict name="env">
      <pair><string value="CORALFLOW_EXCLUDE_TESTCASE"/><string value="tc_4"/></pair>
    </dict>
  </rule>
</query>
""".encode("utf-8")

            xml_bad = _make_xml(5)
            targets_bad = parse_query_xml(xml_bad)
            errors_bad, _, _ = verify_sharding_xml(
                ground_truth_xml=xml_bad,
                sharded_targets=targets_bad,
                shard_count=1,
                tag_filters="",
                repo_root=tmpdir,
            )
            self.assertTrue(
                any(
                    "exceeds enabled @coralflow_test count (4)" in e
                    for e in errors_bad
                ),
                errors_bad,
            )

            xml_ok = _make_xml(4)
            targets_ok = parse_query_xml(xml_ok)
            errors_ok, _, _ = verify_sharding_xml(
                ground_truth_xml=xml_ok,
                sharded_targets=targets_ok,
                shard_count=1,
                tag_filters="",
                repo_root=tmpdir,
            )
            self.assertEqual(errors_ok, [])

            # Dynamic `coralflow_test(_fn)` registrations bypass static count.
            dyn_path = os.path.join(pkg_dir, "dyn_test.py")
            with open(dyn_path, "w", encoding="utf-8") as f:
                f.write(
                    "from coralnpu_test_utils.coralflow.runner import coralflow_test\n\n"
                    "for idx in range(4):\n"
                    "    async def _test(fixture):\n"
                    "        pass\n"
                    "    _test.__name__ = f'dyn_{idx}'\n"
                    "    coralflow_test(_test)\n"
                )
            xml_dyn = _make_xml(4).replace(b"sample_test.py", b"dyn_test.py")
            errors_dyn, _, _ = verify_sharding_xml(
                ground_truth_xml=xml_dyn,
                sharded_targets=parse_query_xml(xml_dyn),
                shard_count=1,
                tag_filters="",
                repo_root=tmpdir,
            )
            self.assertEqual(errors_dyn, [])

    @mock.patch(
        "utils.shard_bazel_tests.run_repo_verification", return_value=0
    )
    @mock.patch("utils.shard_bazel_tests._resolve_workspace_root")
    def test_verify_uses_workspace_root_when_bazelrc_external(
        self, mock_ws, mock_verify
    ):
        with tempfile.TemporaryDirectory() as tmpdir:
            ws_dir = os.path.join(tmpdir, "workspace")
            ext_dir = os.path.join(tmpdir, "external_cfg")
            os.makedirs(ws_dir)
            os.makedirs(ext_dir)
            rc_path = os.path.join(ext_dir, "custom.bazelrc")
            with open(rc_path, "w", encoding="utf-8") as f:
                f.write('test --test_tag_filters="-vcs"\n')
            mock_ws.return_value = ws_dir

            rc = main(["--verify", f"--bazelrc={rc_path}"])
            self.assertEqual(rc, 0)
            mock_verify.assert_called_once_with(
                bazel_bin="bazel",
                shard_count=5,
                tag_filters="-vcs",
                repo_root=ws_dir,
            )

    @mock.patch("utils.shard_bazel_tests.query_bazel_targets")
    def test_cli_falls_back_to_bazelrc_when_tag_filters_empty(
        self, mock_query
    ):
        mock_query.return_value = [
            t for t in parse_query_xml(SAMPLE_QUERY_XML)
            if "manual" not in t.tags
        ]
        with tempfile.TemporaryDirectory() as tmpdir:
            rc_path = os.path.join(tmpdir, ".bazelrc")
            with open(rc_path, "w", encoding="utf-8") as f:
                f.write('test --test_tag_filters="-vcs"\n')
            out0 = os.path.join(tmpdir, "s0.txt")
            out1 = os.path.join(tmpdir, "s1.txt")
            rc0 = main([
                "--shard-index=0",
                "--shard-count=2",
                "--tag-filters=",
                f"--bazelrc={rc_path}",
                f"--output={out0}",
                "//...",
            ])
            rc1 = main([
                "--shard-index=1",
                "--shard-count=2",
                "--tag-filters=",
                f"--bazelrc={rc_path}",
                f"--output={out1}",
                "//...",
            ])
            self.assertEqual(rc0, 0)
            self.assertEqual(rc1, 0)
            with open(out0,
                      encoding="utf-8") as f0, open(out1,
                                                    encoding="utf-8") as f1:
                combined = sorted(
                    f0.read().splitlines() + f1.read().splitlines()
                )
            self.assertEqual(
                combined,
                [
                    "//fpga:clk_sim_test",
                    "//tests/cocotb:big_rvv_test",
                    "//utils:fast_unit_test",
                ],
            )


if __name__ == "__main__":
    unittest.main()
