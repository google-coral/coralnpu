CAPI=2:
# Copyright 2025 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

name: "coralnpuv2:ip:coralnpu_chisel_subsystem_default:0.1"
description: "CoralNPU SoC Unified Chisel Subsystem"
virtual:
  - coralnpuv2:virtual:coralnpu_chisel_subsystem
filesets:
  rtl:
    depend:
      - lowrisc:prim:all
      - lowrisc:prim_generic:all
      - google:ip:ispyocto:0.1
    files:
      - __VERILOG_FILE__
    file_type: systemVerilogSource

targets:
  default:
    filesets:
      - rtl
