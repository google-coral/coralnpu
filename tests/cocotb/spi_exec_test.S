// Copyright 2026 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

.section .data
.balign 16
.global input_val
input_val:
    .word 0x12345678

.global output_val
output_val:
    .word 0x00000000

.section .text
.balign 4
.option norelax
.global _start
.type _start, @function
_start:
    // Load input_val from DTCM (0x00010000)
    la   t0, input_val
    lw   t1, 0(t0)

    // Compute expected result: input_val + 1 (0x12345679)
    addi t1, t1, 1

    // Store output_val to DTCM (0x00010004)
    la   t2, output_val
    sw   t1, 0(t2)

    // Halt core via mpause
    .word 0x08000073 # mpause
halt_loop:
    j    halt_loop
