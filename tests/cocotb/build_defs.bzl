# Copyright 2025 Google LLC
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

"""Common build arguments for cocotb tests."""

VERILATOR_BUILD_ARGS = [
    "--threads 16",
    "-O3",
    "-Wno-WIDTH",
    "-Wno-CASEINCOMPLETE",
    "-Wno-LATCH",
    "-Wno-SIDEEFFECT",
    "-Wno-MULTIDRIVEN",
    "-Wno-UNOPTFLAT",
    # Warnings that we disable for fpnew
    "-Wno-ASCRANGE",
    "-Wno-WIDTHEXPAND",
    "-Wno-WIDTHTRUNC",
    "-Wno-UNSIGNED",
    "-DUSE_GENERIC=\"\"",
]

VCS_BUILD_ARGS = [
    "-timescale=1ns/1ps",
    "-kdb",
    "+vcs+fsdbon",
    "-debug_access+all",
    "-cm",
    "line+cond+tgl+branch+assert",
    "-cm_hier",
    "../tests/cocotb/coverage_exclude.cfg",
]

VCS_TEST_ARGS = [
    "+vcs+fsdbon",
    "-cm",
    "line+cond+tgl+branch+assert",
]

VCS_DEFINES = {"USE_GENERIC": ""}
