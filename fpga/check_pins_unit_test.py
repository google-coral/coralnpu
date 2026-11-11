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
"""Unit tests for fpga/check_pins.py."""

import os
import tempfile
import unittest

from fpga import check_pins


class CheckPinsUnitTest(unittest.TestCase):

    def _write_temp(self, tmpdir, name, content):
        path = os.path.join(tmpdir, name)
        with open(path, "w") as f:
            f.write(content)
        return path

    def test_valid_mappings_pass(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            sv = self._write_temp(
                tmpdir,
                "top.sv",
                "module top(\n"
                "  input wide_spi_clk_i,\n"
                "  input wide_spi_csb_i,\n"
                "  input [1:0] wide_spi_mosi_i\n"
                ");\nendmodule\n",
            )
            xdc = self._write_temp(
                tmpdir,
                "pins.xdc",
                "create_clock -period 40.0 -name wide_spi_clk_i [get_ports wide_spi_clk_i]\n"
                "set_property -dict {PACKAGE_PIN H19 IOSTANDARD LVCMOS18} [get_ports {wide_spi_clk_i}]\n"
                "set_property -dict {PACKAGE_PIN G18 IOSTANDARD LVCMOS18} [get_ports {wide_spi_csb_i}]\n"
                "set_property -dict {PACKAGE_PIN G20 IOSTANDARD LVCMOS18} [get_ports {wide_spi_mosi_i[0]}]\n"
                "set_property -dict {PACKAGE_PIN F20 IOSTANDARD LVCMOS18} [get_ports {wide_spi_mosi_i[1]}]\n",
            )
            missing, duplicates, multi_ports, forbidden = check_pins.check_pins(
                sv, [xdc]
            )
            self.assertEqual(missing, [])
            self.assertEqual(duplicates, {})
            self.assertEqual(multi_ports, {})
            self.assertEqual(forbidden, {})

    def test_clock_or_false_path_without_package_pin_reports_missing(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            sv = self._write_temp(
                tmpdir,
                "top.sv",
                "module top(\n"
                "  input wide_spi_clk_i,\n"
                "  input wide_spi_csb_i\n"
                ");\nendmodule\n",
            )
            xdc = self._write_temp(
                tmpdir,
                "pins.xdc",
                "create_clock -period 40.0 -name wide_spi_clk_i [get_ports wide_spi_clk_i]\n"
                "set_false_path -from [get_ports {wide_spi_csb_i}]\n",
            )
            missing, _, _, _ = check_pins.check_pins(sv, [xdc])
            self.assertEqual(
                sorted(missing), ["wide_spi_clk_i", "wide_spi_csb_i"]
            )

    def test_duplicate_ball_and_multi_assigned_port_detected(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            sv = self._write_temp(
                tmpdir,
                "top.sv",
                "module top(\n  input p0,\n  input p1\n);\nendmodule\n",
            )
            xdc = self._write_temp(
                tmpdir,
                "pins.xdc",
                "set_property -dict {PACKAGE_PIN G20 IOSTANDARD LVCMOS18} [get_ports {p0}]\n"
                "set_property -dict {PACKAGE_PIN G20 IOSTANDARD LVCMOS18} [get_ports {p1}]\n"
                "set_property -dict {PACKAGE_PIN F20 IOSTANDARD LVCMOS18} [get_ports {p1}]\n",
            )
            missing, duplicates, multi_ports, _ = check_pins.check_pins(
                sv, [xdc]
            )
            self.assertEqual(missing, [])
            self.assertEqual(duplicates, {"G20": ["p0", "p1"]})
            self.assertEqual(multi_ports, {"p1": ["G20", "F20"]})

    def test_forbidden_nexus_ball_detected(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            sv = self._write_temp(
                tmpdir, "top.sv", "module top(\n  input p0\n);\nendmodule\n"
            )
            xdc = self._write_temp(
                tmpdir,
                "pins.xdc",
                "set_property -dict {PACKAGE_PIN A17 IOSTANDARD LVCMOS18} [get_ports {p0}]\n",
            )
            _, _, _, forbidden = check_pins.check_pins(sv, [xdc])
            self.assertIn("A17", forbidden)
            self.assertEqual(forbidden["A17"], ("VCCO_75", ["p0"]))


if __name__ == "__main__":
    unittest.main()
