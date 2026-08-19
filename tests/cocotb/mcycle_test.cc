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

#pragma GCC optimize("O2")

// Global volatile variables to force register usage and prevent optimization
volatile unsigned int g_start = 0;
volatile unsigned int g_end   = 0;
volatile unsigned int g_delta = 0;

int main(int argc, char **argv) {
  unsigned int start_cycle = 0;
  unsigned int end_cycle   = 0;
  unsigned int delta       = 0;

  // Read mcycle (varying CSR)
  asm volatile("csrr %0, mcycle" : "=r"(start_cycle));

  // Perform calculations using registers
  end_cycle = start_cycle + 10;
  delta     = end_cycle - start_cycle;

  // Force register writeback to memory via volatile globals
  g_start = start_cycle;
  g_end   = end_cycle;
  g_delta = delta;

  // Overwrite/clean GPRs to end the propagation lifetime
  start_cycle = 100;
  end_cycle   = 200;
  delta       = 0;

  // Write clean values again
  g_start = start_cycle;
  g_end   = end_cycle;
  g_delta = delta;

  return g_delta;
}
