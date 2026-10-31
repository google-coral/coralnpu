// Copyright 2025 Google LLC
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

#include "hw_sim/hw_primitives.h"

Clock::Observer::Observer(Clock* clock)
  : clock_(clock) {
  clock_->AddObserver(this);
}

Clock::Observer::~Observer() {
  clock_->RemoveObserver(this);
}

void Clock::Step() {
  context_->timeInc(1);
  (*clock_) = 1;
  Eval();

  context_->timeInc(1);
  (*clock_) = 0;
  for (auto& observer : observers_) {
    observer->OnFallingEdge();
  }
  Eval();
}

void Clock::Eval() {
  eval_function_();
}

void Clock::AddObserver(Observer* observer) {
  observers_.push_back(observer);
}

void Clock::RemoveObserver(Observer* observer) {
  auto it = std::find(observers_.begin(), observers_.end(), observer);
  if (it != observers_.end()) {
    observers_.erase(it);
  }
}

// static
AxiAddr AxiAddr::FromIdAddrSize(int id, uint32_t addr, uint32_t byte_length) {
  uint32_t start_addr = addr;
  uint32_t end_addr = addr + byte_length - 1;
  uint32_t start_line = start_addr / 16;
  uint32_t end_line = end_addr / 16;
  uint32_t beats = (end_line - start_line) + 1;
  uint32_t size = std::ceil(std::log2(byte_length));
  size = std::min(size, 4u);
  AxiAddr axi_addr;
  axi_addr.addr_bits_addr = addr;
  axi_addr.addr_bits_prot = 0;
  axi_addr.addr_bits_id = id;
  axi_addr.addr_bits_len = beats - 1;
  axi_addr.addr_bits_size = size;
  axi_addr.addr_bits_burst = 1;  // INCR
  axi_addr.addr_bits_lock = 0;
  axi_addr.addr_bits_cache = 0;
  axi_addr.addr_bits_qos = 0;
  axi_addr.addr_bits_region = 0;
  return axi_addr;
}

