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

package(default_visibility = ["//visibility:public"])

genrule(
    name = "coralnpu_chisel_subsystem_matrix_verilog",
    srcs = ["//hdl/chisel/src/soc:CoralNPUChiselSubsystemMatrix.sv"],
    outs = ["CoralNPUChiselSubsystemMatrix.sv"],
    cmd = "cp $< $@; sed -i -e 's/CoralNPUChiselSubsystemMatrix/CoralNPUChiselSubsystem/g' $@",
)

genrule(
    name = "generate_core_file",
    srcs = [
        "coralnpu_chisel_subsystem_matrix.core.tpl",
        ":coralnpu_chisel_subsystem_matrix_verilog",
    ],
    outs = ["coralnpu_chisel_subsystem_matrix.core"],
    cmd = "sed 's|__VERILOG_FILE__|CoralNPUChiselSubsystemMatrix.sv|' $(location coralnpu_chisel_subsystem_matrix.core.tpl) > $@",
)

filegroup(
    name = "rtl_files",
    srcs = glob([
        "*.sv",
        "*.core",
    ]) + [
        ":CoralNPUChiselSubsystemMatrix.sv",
    ],
)
