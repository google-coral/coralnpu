// Copyright 2023 Google LLC
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

#ifndef TESTS_VERILATOR_SIM_CORALNPU_DEBUG_IF_H_
#define TESTS_VERILATOR_SIM_CORALNPU_DEBUG_IF_H_

#include <stdint.h>
#include <stdio.h>
#include <sys/time.h>

#include "tests/verilator_sim/sysc_module.h"
#include "tests/verilator_sim/coralnpu/memory_if.h"

// A core debug model.
struct Debug_if : Sysc_module {

  Debug_if(sc_module_name n, Memory_if* mm) : Sysc_module(n), mm_(mm) {
    gettimeofday(&start_, NULL);
  }

  ~Debug_if() {
    gettimeofday(&stop_, NULL);
    const float time_s =
        static_cast<float>(stop_.tv_sec - start_.tv_sec) +
        static_cast<float>(stop_.tv_usec - start_.tv_usec) / 1000000.0f;

    // Integer with commas.
    auto s = std::to_string(cycle_);
    int n = s.length() - 3;
    while (n > 0) {
      s.insert(n, ",");
      n -= 3;
    }

    printf("Info: %s cycles  @%.2fK/s\n", s.c_str(), cycle_ / time_s / 1000.0f);
  }

  void eval() {
    if (reset) {
      cycle_ = 0;
    } else if (clock->posedge()) {
      cycle_++;
    }
  }

 private:
#ifndef TIME_DISABLE
  [[maybe_unused]] const char *KNRM = "\x1B[0m";
  [[maybe_unused]] const char *KRED = "\x1B[31m";
  [[maybe_unused]] const char *KGRN = "\x1B[32m";
  [[maybe_unused]] const char *KYEL = "\x1B[33m";
  [[maybe_unused]] const char *KBLU = "\x1B[34m";
  [[maybe_unused]] const char *KMAG = "\x1B[35m";
  [[maybe_unused]] const char *KCYN = "\x1B[36m";
  [[maybe_unused]] const char *KWHT = "\x1B[37m";
  [[maybe_unused]] const char *KRST = "\033[0m";
#endif  // TIME_DISABLE

  [[maybe_unused]] static const int ARGMAX      = 16;
  [[maybe_unused]] static const int BUFFERLIMIT = 100;
  [[maybe_unused]] int argpos_;
  [[maybe_unused]] uint64_t arg_[ARGMAX];
  [[maybe_unused]] uint8_t str_[ARGMAX][BUFFERLIMIT];
  [[maybe_unused]] uint8_t pos_[ARGMAX] = {0};

  struct timeval stop_, start_;

  [[maybe_unused]] Memory_if *mm_;

  [[maybe_unused]] bool newline_ = false;
  int cycle_ = 0;
};

#endif  // TESTS_VERILATOR_SIM_CORALNPU_DEBUG_IF_H_
