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

#ifndef TESTS_VERILATOR_SIM_SYSC_TB_H_
#define TESTS_VERILATOR_SIM_SYSC_TB_H_

// A SystemC baseclass for constrained random testing of Verilated RTL.
#include <systemc.h>

#include <iostream>
#include <string>

#include "tests/verilator_sim/fifo.h"
// sc_core needs to be included before verilator header
using namespace sc_core;      // NOLINT(build/namespaces)
#include "verilated_fst_c.h"  // NOLINT(build/include_subdir): From verilator.

using sc_dt::sc_bv;

#define BIND(a, b) a.b(b)
#define BIND2(a, b, c) \
  BIND(a, c);          \
  BIND(b, c)

template <typename T>
struct sc_signal_vrb {
  sc_signal<bool> valid;
  sc_signal<bool> ready;
  sc_signal<T> bits;
};

template <typename T>
struct sc_in_vrb {
  sc_in<bool> valid;
  sc_out<bool> ready;
  sc_in<T> bits;

  void bind(sc_signal<bool> &v, sc_signal<bool> &r, sc_signal<T> &b) {
    valid.bind(v);
    ready.bind(r);
    bits.bind(b);
  }

  void bind(sc_signal_vrb<T> &vrb) {
    valid.bind(vrb.valid);
    ready.bind(vrb.ready);
    bits.bind(vrb.bits);
  }

  void operator()(sc_signal<bool> &v, sc_signal<bool> &r, sc_signal<T> &b) {
    bind(v, r, b);
  }

  void operator()(sc_signal_vrb<T> &vrb) { bind(vrb); }
};

template <typename T>
struct sc_out_vrb {
  sc_out<bool> valid;
  sc_in<bool> ready;
  sc_out<T> bits;

  void bind(sc_signal<bool> &v, sc_signal<bool> &r, sc_signal<T> &b) {
    valid.bind(v);
    ready.bind(r);
    bits.bind(b);
  }

  void bind(sc_signal_vrb<T> &vrb) {
    valid.bind(vrb.valid);
    ready.bind(vrb.ready);
    bits.bind(vrb.bits);
  }

  void operator()(sc_signal<bool> &v, sc_signal<bool> &r, sc_signal<T> &b) {
    bind(v, r, b);
  }

  void operator()(sc_signal_vrb<T> &vrb) { bind(vrb); }
};

// eg. struct message : base {...};
struct base {
  inline bool operator==(const base &rhs) const { return false; }

  inline friend std::ostream &operator<<(std::ostream &os, base const &v) {
    return os;
  }
};

// Base class for testbench {posedge & negedge}.
struct Sysc_tb : public sc_module {
  sc_clock clock;
  sc_signal<bool> reset;
  sc_signal<bool> resetn;

  SC_HAS_PROCESS(Sysc_tb);

  Sysc_tb(sc_module_name n, int loops, bool random = true)
      : sc_module(n),
        clock("clock", 1, SC_NS),
        reset("reset"),
        resetn("resetn"),
        random_(random),
        loops_(loops) {
    loop_ = 0;
    error_ = false;

    SC_METHOD(tb_posedge);
    sensitive << clock_.pos();

    SC_METHOD(tb_negedge);
    sensitive << clock_.neg();

    SC_METHOD(tb_stop);
    sensitive << clock_.neg();

    clock_(clock);

    // Verilated::commandArgs(argc, argv);
    tf_ = new VerilatedFstC;
  }

  ~Sysc_tb() {
    if (tf_) {
      tf_->dump(sim_time_);  // last falling edge
      tf_->close();
      delete tf_;
      tf_ = nullptr;
    }
    if (error_) {
      exit(23);
    }
  }

  void start() {
    init();

    reset = 1;
    resetn = 0;
    sc_start(4.75, SC_NS);  // falling edge of clock
    reset = 0;
    resetn = 1;

    started_ = true;
    sc_start();

    if (tf_) {
      tf_->dump(sim_time_++);  // last falling edge
      tf_->close();
      delete tf_;
      tf_ = nullptr;
    }
  }

  template <typename T>
  void trace(T* design, const char *name = "") {
    std::string path;
    if (name != nullptr && strlen(name) > 0) {
      path = name;
      if (path.size() < 4 || path.substr(path.size() - 4) != ".fst") {
        path += ".fst";
      }
    } else {
      const char *test_tmpdir = std::getenv("TEST_TMPDIR");
      std::string dir = (test_tmpdir != nullptr && strlen(test_tmpdir) > 0) ? test_tmpdir : "/tmp";
      path            = dir + "/" + design->name() + ".fst";
    }

    reset = 1;
    resetn = 0;
    sc_start(SC_ZERO_TIME);
    reset = 0;
    resetn = 1;

    design->trace(tf_, 99);
    Verilated::traceEverOn(true);
    tf_->open(path.c_str());
    printf("\nInfo: default timescale unit used for tracing: 1 ps (%s)\n",
           path.c_str());
  }

  static char *get_name(char *s) {
    const int len = strlen(s);
    char *p = s;
    for (int i = 0; i < len; ++i) {
      if (s[i] == '/') {
        p = s + i + 1;
      }
    }
    return p;
  }

 protected:
  virtual void init() {}
  virtual void posedge() {}
  virtual void negedge() {}

  bool check(bool v, const char *s = "") {
    const char *KRED = "\x1B[31m";
    const char *KRST = "\033[0m";
    if (!v) {
      sc_stop();
      printf("%s", KRED);
      if (strlen(s)) {
        printf("***ERROR[%s]::VERIFY \"%s\"\n", this->name(), s);
      } else {
        printf("***ERROR[%s]::VERIFY\n", this->name());
      }
      printf("%s", KRST);
      error_ = true;
    }
    return v;
  }

  bool rand_bool() {
    // Do not allow any 'io_in_valid' controls to be set during reset.
    return !reset &&
           (!random_ || (rand() & 1));  // NOLINT(runtime/threadsafe_fn)
  }

  // Generates a number on the range [min, max].
  int rand_int(int min = 0, int max = (1 << 31)) {
    return (rand() % (max - min + 1)) + min;  // NOLINT(runtime/threadsafe_fn)
  }

  uint32_t rand_uint32(uint32_t min = 0, uint32_t max = 0xffffffffu) {
    uint32_t r = (rand() & 0xffff) |  // NOLINT(runtime/threadsafe_fn)
                 (rand() << 16);      // NOLINT(runtime/threadsafe_fn)
    if (min == 0 && max == 0xffffffff) return r;
    return (r % (max - min + 1)) + min;
  }

  uint64_t rand_uint64(uint64_t min = 0, uint64_t max = 0xffffffffffffffffull) {
    uint64_t r = rand_uint32() | (uint64_t(rand_uint32()) << 32);
    if (min == 0 && max == 0xffffffffffffffffull) return r;
    return (r % (max - min + 1)) + min;
  }

  uint32_t cycle() {
    return sim_time_ / 2;  // posedge + negedge
  }

 private:
  const bool random_;
  const int loops_;
  int loop_;
  bool error_;
  bool started_;

  sc_in<bool> clock_;

  uint32_t sim_time_ = 0;
  VerilatedFstC *tf_ = nullptr;

  void tb_posedge() {
    if (tf_ && started_) { tf_->dump(sim_time_++); tf_->flush(); }
    if (reset) return;
    posedge();
  }

  void tb_negedge() {
    if (tf_ && started_) { tf_->dump(sim_time_++); tf_->flush(); }
    if (reset) return;
    negedge();
  }

  void tb_stop() {
    // LessThanEqual for one more edge (end - start + 1).
    if (loop_ <= loops_) {
      loop_++;
    } else {
      printf("\nInfo: loop limit \"%d\" reached\n", loops_);
      sc_stop();
    }
  }
};

#endif  // TESTS_VERILATOR_SIM_SYSC_TB_H_
