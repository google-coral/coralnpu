/*
 * Copyright 2026 Google LLC
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

  .section ._init, "ax"
  .global _start
_start:
  # Initialize stack pointer
  la sp, _stack_top

  # Copy data from ROM to RAM
  la a0, _data_load
  la a1, _data_start
  la a2, _data_end
  bgeu a1, a2, .L_copy_data_done
.L_copy_data_loop:
  lw t0, 0(a0)
  sw t0, 0(a1)
  addi a0, a0, 4
  addi a1, a1, 4
  bltu a1, a2, .L_copy_data_loop
.L_copy_data_done:

  # Zero BSS
  la a0, _bss_start
  la a1, _bss_end
  bgeu a0, a1, .L_zero_bss_done
.L_zero_bss_loop:
  sw zero, 0(a0)
  addi a0, a0, 4
  bltu a0, a1, .L_zero_bss_loop
.L_zero_bss_done:

  # Jump to main
  tail main
