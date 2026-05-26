# Coral NPU Makefile
# Full pipeline: Chisel → Verilog → Verilator → Simulation
# =============================================================================

BAZEL       ?= bazel
JAVA_HOME   ?= $(shell /usr/libexec/java_home 2>/dev/null || echo /opt/homebrew/opt/openjdk@17)
BAZEL_FLAGS := --java_runtime_version=remotejdk_11
BAZEL_ENV   := JAVA_HOME=$(JAVA_HOME) PATH=/opt/homebrew/bin:$(JAVA_HOME)/bin:/usr/bin:/bin
BAZEL_RUN   := env $(BAZEL_ENV) $(BAZEL)

RVTDIR      := third_party/riscv_vector_tests
RVTOUT      := $(RVTDIR)/out
RVT_GEN     := $(RVTDIR)/generator
RVT_CONFIG  ?= $(HOME)/riscv-vector-tests

MODEL_TARGET := //tests/cocotb:rvv_core_mini_highmem_axi_model

# Default target
.PHONY: help
help:
	@echo "Coral NPU — RVV Chisel Pipeline"
	@echo ""
	@echo "  make pipeline             Full flow: Chisel → Verilog → Sim → Test"
	@echo "  make chisel-to-verilog     Compile Chisel, emit Verilog (via firtool)"
	@echo "  make verilog-to-sim        Build Verilator simulation model"
	@echo "  make sim-run               Run 516 riscv-vector-tests on Verilator"
	@echo ""
	@echo "  make rvv-tests-generate    Generate & compile all 516 riscv-vector-tests"
	@echo "  make rvv-regression        Run existing cocotb RVV regression (~100 tests)"
	@echo ""
	@echo "  make setup-macos           Install all macOS dependencies (brew)"
	@echo "  make setup-firtool         Download firtool binary to tools/firtool/"
	@echo ""
	@echo "  make clean                 Bazel clean"
	@echo "  make clean-all             Bazel clean --expunge + test artifacts"
	@echo ""

# ---------------------------------------------------------------------------
# Full Pipeline
# ---------------------------------------------------------------------------

.PHONY: pipeline
pipeline: chisel-to-verilog verilog-to-sim sim-run

# ---------------------------------------------------------------------------
# Step 1: Chisel → Verilog (via firtool)
# ---------------------------------------------------------------------------

.PHONY: chisel-to-verilog
chisel-to-verilog:
	@echo "=== Step 1: Chisel → Verilog ==="
	$(BAZEL_RUN) build //hdl/chisel/src/coralnpu:rvv_core_mini_highmem_axi_cc_library $(BAZEL_FLAGS)
	@echo "=== Verilog emitted successfully ==="

# ---------------------------------------------------------------------------
# Step 2: Verilog → Verilator C++ Simulation Model
# ---------------------------------------------------------------------------

.PHONY: verilog-to-sim
verilog-to-sim:
	@echo "=== Step 2: Verilog → Verilator Simulation ==="
	$(BAZEL_RUN) build $(MODEL_TARGET) $(BAZEL_FLAGS)
	@echo "=== Verilator model built ==="

# ---------------------------------------------------------------------------
# Step 3: Run Compliance Tests
# ---------------------------------------------------------------------------

.PHONY: sim-run
sim-run:
	@echo "=== Step 3: Running 516 riscv-vector-tests ==="
	$(BAZEL_RUN) test //tests/cocotb:rvv_compliance_tests \
		--config=coralnpu_v2 \
		--cache_test_results=no \
		--test_output=errors \
		$(BAZEL_FLAGS)

# ---------------------------------------------------------------------------
# RVV Compliance Tests (riscv-vector-tests)
# ---------------------------------------------------------------------------

$(RVTOUT):
	mkdir -p $(RVTOUT)

$(RVT_GEN):
	@test -d "$(RVT_CONFIG)" || { \
		echo "ERROR: riscv-vector-tests not found at $(RVT_CONFIG)"; \
		echo "Clone: git clone https://github.com/chipsalliance/riscv-vector-tests $(RVT_CONFIG)"; \
		echo "Submodules: git -C $(RVT_CONFIG) submodule update --init --recursive --depth 1"; \
		exit 1; \
	}
	cd $(RVT_CONFIG) && go build -o $(RVT_GEN) ./single/...

.PHONY: rvv-tests-generate
rvv-tests-generate: $(RVTOUT) $(RVT_GEN)
	python3 $(RVTDIR)/generate_all.py

.PHONY: rvv-tests-clean
rvv-tests-clean:
	rm -rf $(RVTOUT)

# ---------------------------------------------------------------------------
# Existing RVV Regression Tests
# ---------------------------------------------------------------------------

.PHONY: rvv-regression
rvv-regression:
	$(BAZEL_RUN) test \
		//tests/cocotb:rvv_assembly_cocotb_test \
		//tests/cocotb:rvv_arithmetic_cocotb_test \
		//tests/cocotb:rvv_load_store_test \
		//tests/cocotb:rvv_ml_ops_cocotb_test \
		//hdl/chisel/src/coralnpu:coralnpu_rvv_tests \
		--cache_test_results=no \
		--test_output=errors \
		$(BAZEL_FLAGS)

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------

.PHONY: setup-macos
setup-macos:
	brew install go verilator riscv64-elf-gcc bazelisk openjdk@17

FIRTOOL_VER  := 1.114.0
FIRTOOL_JAR  := llvm-firtool-$(FIRTOOL_VER).jar
FIRTOOL_URL  := https://repo1.maven.org/maven2/org/chipsalliance/llvm-firtool/$(FIRTOOL_VER)/$(FIRTOOL_JAR)

.PHONY: setup-firtool
setup-firtool:
	@mkdir -p tools/firtool
	@if [ ! -f tools/firtool/org.chipsalliance/llvm-firtool/macos-x64/bin/firtool ]; then \
		echo "Downloading firtool $(FIRTOOL_VER)..."; \
		curl -L -o /tmp/$(FIRTOOL_JAR) $(FIRTOOL_URL); \
		unzip -o /tmp/$(FIRTOOL_JAR) -d tools/firtool; \
		chmod +x tools/firtool/org.chipsalliance/llvm-firtool/macos-x64/bin/firtool; \
		rm /tmp/$(FIRTOOL_JAR); \
		echo "firtool installed to tools/firtool/"; \
	else \
		echo "firtool already installed"; \
	fi

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------

.PHONY: clean
clean:
	$(BAZEL_RUN) clean $(BAZEL_FLAGS)

.PHONY: clean-all
clean-all:
	$(BAZEL_RUN) clean --expunge $(BAZEL_FLAGS)
	rm -rf $(RVTOUT)
