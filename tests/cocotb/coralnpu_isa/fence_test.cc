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

#include <cstdint>

volatile uint32_t sink0 = 10;
volatile uint32_t sink1 = 20;

int main() {
  // Verify standard FENCE encodings.
  sink0 = 1;
  asm volatile("fence rw, rw" ::: "memory");
  sink1 = sink0 + 1;
  asm volatile("fence r, r" ::: "memory");
  sink0 = sink1 + 1;
  asm volatile("fence w, w" ::: "memory");
  asm volatile("fence iorw, iorw" ::: "memory");

  // Verify FENCE.TSO (0x8330000f) across all 4 fetch/dispatch lane alignments
  // and adjacent to load/store traffic.
  asm volatile(
      ".balign 16\n\t"
      "fence.tso\n\t"
      "nop\n\t"
      "nop\n\t"
      "nop\n\t"
      ".balign 16\n\t"
      "nop\n\t"
      "fence.tso\n\t"
      "nop\n\t"
      "nop\n\t"
      ".balign 16\n\t"
      "nop\n\t"
      "nop\n\t"
      "fence.tso\n\t"
      "nop\n\t"
      ".balign 16\n\t"
      "nop\n\t"
      "nop\n\t"
      "nop\n\t"
      "fence.tso\n\t" ::
          : "memory");

  sink0 = 42;
  asm volatile("fence.tso" ::: "memory");
  uint32_t v = sink0;
  asm volatile("fence.tso" ::: "memory");
  sink1 = v;

  return (sink1 == 42) ? 0 : 1;
}
