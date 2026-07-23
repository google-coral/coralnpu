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

# Makefile for CoralNPU UVM Testbench (Integrates with MPACT-Sim)

# If CORALNPU_MPACT is not set, dynamically resolve it from Bazel's http_archive cache
ifndef CORALNPU_MPACT
    BAZEL_CACHE_ARG = $(if $(BAZEL_CACHE),--repository_cache=$(BAZEL_CACHE),)
    _FETCH := $(shell bazel build $(BAZEL_CACHE_ARG) @coralnpu_mpact//:coralnpu_sim_users > /dev/null 2>&1)
    BAZEL_OUTPUT_BASE = $(shell bazel info output_base)
    CORALNPU_MPACT = $(BAZEL_OUTPUT_BASE)/external/coralnpu_mpact
endif

# Generated RTL path
BAZEL_BIN_DIR = $(shell bazel info bazel-bin)
GENERATED_RTL_NAME = RvvCoreMiniVerificationAxi.sv
GENERATED_RTL_SRC = $(BAZEL_BIN_DIR)/hdl/chisel/src/coralnpu/$(GENERATED_RTL_NAME)

# User Configuration
VCS = vcs
VERILATOR ?= verilator
CXX = clang++
SIMULATOR ?= vcs

ifeq ($(SIMULATOR),vcs)
SIM_BIN = $(VCS)
else
SIM_BIN = $(VERILATOR)
endif


# UVM DV Directories
COMMON_DIR = ./common
TB_DIR = ./tb
ENV_DIR = ./env
TESTS_DIR = ./tests
BIN_DIR = ./bin
UTILS_DIR = ./utils

# Simulation Work Directory
SIM_DIR = ./sim_work
BUILD_DIR = $(SIM_DIR)/build
LOG_DIR = $(SIM_DIR)/logs
WAVE_DIR = $(SIM_DIR)/waves

# MPACT-Sim Integration Paths
MPACT_BAZEL_BIN_DIR = $(CORALNPU_MPACT)/bazel-bin/sim/cosim
MPACT_COSIM_LIB_NAME = coralnpu_cosim_lib_static
MPACT_LIB_PATH = $(MPACT_BAZEL_BIN_DIR)/lib$(MPACT_COSIM_LIB_NAME).a

# File List for -f option
FILE_LIST = ./coralnpu_dv.f

# Simulation Settings
SIM_EXEC = $(SIM_DIR)/simv
UVM_TESTNAME ?= coralnpu_base_test
TEST_ELF ?= $(BIN_DIR)/rvv_aadd_int16_m1.elf
UVM_VERBOSITY ?= UVM_MEDIUM
TEST_TIMEOUT_NS ?= 100000
MISA_VALUE ?= "'h40201120'"
PLUSARGS = +UVM_TESTNAME=$(UVM_TESTNAME) \
           +UVM_VERBOSITY=$(UVM_VERBOSITY) +TEST_TIMEOUT=$(TEST_TIMEOUT_NS) \
           +TEST_ELF=$(TEST_ELF) \
           +MISA_VALUE=$(MISA_VALUE)

# Waveform Dumping
ifeq ($(SIMULATOR),vcs)
DUMP_WAVES_FSDB = 1
WAVE_FILE = $(WAVE_DIR)/$(UVM_TESTNAME).fsdb
else
DUMP_WAVES_VCD = 1
WAVE_FILE = $(WAVE_DIR)/$(UVM_TESTNAME).vcd
endif

# Compile options
ifeq ($(SIMULATOR),vcs)
SIM_COMPILE_OPTS = \
	-full64 \
	-sverilog \
	+define+UVM_NO_DEPRECATED \
	+define+TB_SUPPORT \
		+define+VLEN_128 \
		+define+ZVE32F_ON \
	-ntb_opts uvm-1.2 \
	-debug_access+all \
	-kdb \
	-timescale=1ns/1ps \
	-o $(SIM_EXEC) \
	-cpp $(CXX) \
	-cppflags "-std=c++17" \
	-CFLAGS "-I$(CORALNPU_MPACT)" \
	$(MPACT_LIB_PATH)
else
SIM_COMPILE_OPTS = \
	--binary \
	--build-jobs $(shell nproc --all) \
	--top coralnpu_tb_top \
	-Wno-PINMISSING -Wno-lint -Wno-style -Wno-fatal \
	--vpi \
	--trace-vcd \
	+define+UVM_NO_DEPRECATED \
	+define+TB_SUPPORT \
	+define+VLEN_128 \
	+define+ZVE32F_ON \
	+define+DUMP_WAVES_VCD \
	--timescale 1ns/1ps \
	-CFLAGS "-std=c++17 -I$(CORALNPU_MPACT)" \
	-I"$(UVM)/src/" \
	"$(UVM)/src/uvm_pkg.sv" \
	"$(UVM)/src/dpi/uvm_dpi.cc" \
	"$(MPACT_LIB_PATH)" \
	-Mdir $(BUILD_DIR) \
	-o simv \
	-MAKEFLAGS "VERILATOR_ROOT=$(VERILATOR_ROOT)"
SIM_EXEC = $(BUILD_DIR)/simv
endif

SIM_RUN_OPTS = \
	$(PLUSARGS) \
	$(EXTRA_PLUSARGS)

# Add define to COMPILE options for waveform dumping
ifeq ($(DUMP_WAVES_FSDB),1)
SIM_COMPILE_OPTS += +define+DUMP_WAVES_FSDB
SIM_RUN_OPTS += +fsdb+all \
                +fsdbfile+$(WAVE_FILE)
endif

# Add Spike Log to runtime options if defined
ifdef SPIKE_LOG
SIM_RUN_OPTS += +SPIKE_LOG=$(SPIKE_LOG)
endif

# Bazel override flags.
# We must always override coralnpu_hw because the simulator's WORKSPACE template
# loads patch files from the main @coralnpu_hw workspace.
BAZEL_OVERRIDE_FLAGS = --override_repository=coralnpu_hw=$(abspath $(CURDIR)/../..)

ifdef CORALNPU_MPACT_RISCV
    BAZEL_OVERRIDE_FLAGS += --override_repository=com_google_mpact-riscv=$(CORALNPU_MPACT_RISCV)
endif

MPACT_COMMIT ?= 430a8d1

# Targets

.PHONY: all compile run clean dirs help build_mpact_lib gen_mem_files rtl run_3way checkout_mpact

# Default target, builds and then runs.
all: compile run

# Checkout MPACT-Sim at a specific commit
checkout_mpact:
	@echo "--- Checking out CORALNPU_MPACT at commit $(MPACT_COMMIT) ---"
	cd $(CORALNPU_MPACT) && git fetch && git checkout $(MPACT_COMMIT)

# Create necessary directories
dirs:
	@mkdir -p $(SIM_DIR) $(LOG_DIR) $(WAVE_DIR) $(BIN_DIR)

# Build the MPACT-Sim library using Bazel with CC=clang
build_mpact_lib:
	@echo "--- Building MPACT-Sim Co-sim Library via Bazel ---"
	cd $(CORALNPU_MPACT) && CC=clang bazel build $(BAZEL_OVERRIDE_FLAGS) $(MPACT_BAZEL_FLAGS) //sim/cosim:$(MPACT_COSIM_LIB_NAME)

# Generate memory and run option files from the ELF file
# Generate the DUT RTL from Chisel source
rtl:
	@echo "--- Generating DUT RTL from Chisel ---"
	bazel build //hdl/chisel/src/coralnpu:rvv_core_mini_verification_axi_cc_library_emit_verilog

# Compile the design
$(SIM_EXEC): $(FILE_LIST) dirs build_mpact_lib rtl
	@echo "--- Compiling Simulation ---"
	$(SIM_BIN) $(SIM_COMPILE_OPTS) -f $(FILE_LIST) $(GENERATED_RTL_SRC)
	@echo "--- Compilation Finished ---"

compile: $(SIM_EXEC)

# Run the simulation
run:
	@echo "--- Running Simulation ---"
	@echo "Test:      $(UVM_TESTNAME)"
	@echo "ELF File:  $(TEST_ELF)"
	@echo "Verbosity: $(UVM_VERBOSITY)"
	@echo "Timeout:   $(TEST_TIMEOUT_NS) ns"
	@echo "Plusargs:  $(PLUSARGS)"
	@echo "Log File:  $(LOG_DIR)/$(UVM_TESTNAME).log"
ifeq ($(DUMP_WAVES_FSDB),1)
	@echo "Wave File: $(WAVE_FILE)"
endif
	./$(SIM_EXEC) $(SIM_RUN_OPTS) -l $(LOG_DIR)/$(UVM_TESTNAME).log
	@echo "--- Simulation Finished ---"

# 3-Way Simulation
run_3way:
	@echo "--- Running 3-Way Simulation (with Spike) ---"
	$(MAKE) run SPIKE_LOG=$(if $(SPIKE_LOG),$(SPIKE_LOG),$(abspath spike.log))

# Clean up simulation files
clean:
	@echo "--- Cleaning Simulation Files ---"
	rm -rf $(SIM_DIR) simv* csrc* *.log* *.key *.vpd *.fsdb ucli.key DVEfiles/ verdiLog/ novas.*
	bazel clean --expunge
	@echo "--- Cleaning MPACT-Sim Bazel cache ---"
	cd $(CORALNPU_MPACT) && bazel clean --expunge

# Help
help:
	@echo "Makefile Targets:"
	@echo "  make all              : Compiles and runs the default test (same as just 'make')."
	@echo "  make compile          : Builds the simulator executable."
	@echo "  make run              : Runs the simulation. Compiles first if the executable is missing or source files have changed."
	@echo "                        :   Override defaults: make run UVM_TESTNAME=<test> TEST_ELF=<path> UVM_VERBOSITY=<level>"
	@echo "  make run_3way         : Runs the simulation with 3-way check enabled (Spike)."
	@echo "  make rtl              : Generates the DUT Verilog from Chisel source"
	@echo "  make build_mpact_lib  : Only builds the MPACT-Sim C++ library"
	@echo "  make checkout_mpact   : Checks out CORALNPU_MPACT at MPACT_COMMIT (default: $(MPACT_COMMIT))"
	@echo "  make clean            : Removes generated simulation and MPACT-Sim files"
	@echo "  make dirs             : Creates simulation directories"
	@echo "  make help             : Shows this help message"
