# Copyright 2024 Google LLC
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

load("@rules_python//python:defs.bzl", "py_binary", "py_test")

package(default_visibility = ["//visibility:public"])

py_binary(
    name = "scm_info",
    srcs = ["scm_info.py"],
)

py_test(
    name = "check_macro_signatures_test",
    srcs = ["check_macro_signatures.py"],
    data = [
        "//rules:coco_tb.bzl",
    ],
    main = "check_macro_signatures.py",
)
