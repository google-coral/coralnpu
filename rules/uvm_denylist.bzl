# Copyright 2026 Google LLC
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

"""Single authoritative source for UVM regression denylists and test configurations."""

# List of targets to exclude from the regression.
# Supports exact labels or simple glob/prefix patterns (e.g. "*bf16*", "//internal/kernels:*").
DENYLIST = [
    # Checks mcycle
    "//tests/cocotb/tutorial/counters:inst_cycle_counter_example",
    "//tests/cocotb/coralnpu_isa:perf_counters",
    # Peripherals
    "//tests/cocotb:timer_interrupt_test",
    "//tests/cocotb:plic_test",
    # RVV exceptions, not supported by MPACT (yet)
    "//tests/cocotb/rvv:vill_test",
    "//tests/cocotb/rvv:rvv_vill_loop_trap_test",
    "//tests/cocotb/rvv:rvv_vstart_trap_flush_test",
    "//tests/cocotb/rvv:rvv_vstart_vmv_scalar_test",
    "//tests/cocotb/rvv:rvv_vstart_vset_test",
    "//tests/cocotb:vector_store",
    "//tests/cocotb:vector_store_fault",
    "//tests/cocotb/exceptions:vfwadd_trap",
    "//tests/cocotb/exceptions:vfwsub_trap",
    "//tests/cocotb/exceptions:vfwmul_trap",
    # Jump to dtcm (disabled on both RTL and MPACT)
    "//third_party/riscv-tests:rv32ui-p-fence_i",
    "//third_party/riscv-tests:rv32ui-v-fence_i",
    # Runs code in DDR (not supported by MPACT atm)
    "//tests/cocotb:fencei_test",
    # Actual RVV bugs?
    "//tests/cocotb/rvv:vmsif_test",
    "//tests/cocotb/rvv:vmsbf_test",
    "//tests/cocotb/rvv/load_store:load_unit_masked",
    "//tests/cocotb/rvv/load_store:store_unit_masked",
    "//tests/cocotb/rvv/arithmetics:vmsge_vx_test",
    # MPACT needs update to canonical-NaN
    "//tests/cocotb/rvv/arithmetics:rvv_fdiv_float_rdn_m1",
    "//tests/cocotb/rvv/arithmetics:rvv_fdiv_float_rmm_m1",
    "//tests/cocotb/rvv/arithmetics:rvv_fdiv_float_rne_m1",
    "//tests/cocotb/rvv/arithmetics:rvv_fdiv_float_rtz_m1",
    "//tests/cocotb/rvv/arithmetics:rvv_fdiv_float_rup_m1",
    "//tests/cocotb/rvv/arithmetics:vfdiv_vf_test_rdn",
    "//tests/cocotb/rvv/arithmetics:vfdiv_vf_test_rmm",
    "//tests/cocotb/rvv/arithmetics:vfdiv_vf_test_rne",
    "//tests/cocotb/rvv/arithmetics:vfdiv_vf_test_rtz",
    "//tests/cocotb/rvv/arithmetics:vfdiv_vf_test_rup",
    "//tests/cocotb/rvv/arithmetics:vfrdiv_vf_test_rdn",
    "//tests/cocotb/rvv/arithmetics:vfrdiv_vf_test_rmm",
    "//tests/cocotb/rvv/arithmetics:vfrdiv_vf_test_rne",
    "//tests/cocotb/rvv/arithmetics:vfrdiv_vf_test_rtz",
    "//tests/cocotb/rvv/arithmetics:vfrdiv_vf_test_rup",
    # Exclude until MPACT supports the vector bf16 spec.
    "*bf16*",
    "//tests/cocotb:zvfbf_test",
    # Exclude until MPACT supports VME.
    "*vme*",
    # Exclude all ml_ops tests from regression
    "//tests/cocotb/rvv/ml_ops:rvv_float_matmul",
    "//tests/cocotb/rvv/ml_ops:rvv_float_matmul_assembly",
    "//tests/cocotb/rvv/ml_ops:rvv_float_matmul_optimized",
    "//tests/cocotb/rvv/ml_ops:rvv_matmul",
    "//tests/cocotb/rvv/ml_ops:rvv_matmul_assembly",
    "//tests/cocotb/rvv/ml_ops:rvv_matmul_assembly_highmem",
    "//tests/cocotb/rvv/ml_ops:rvv_matmul_assembly_itcm512kb_dtcm512kb",
    "//tests/cocotb/rvv/ml_ops:rvv_matmul_highmem",
    "//tests/cocotb/rvv/ml_ops:rvv_matmul_itcm512kb_dtcm512kb",
    # 1) UVM backdoor loader does not support loading to external memory (.extdata).
    # 2) UVM testbench lacks mechanism to initialize input/scale/zp data in external memory.
    "//internal/kernels:*",
    "//internal/kernels/*",
    "//tests/cocotb/vme_test:vme_matmul_test_program",
    "//tests/cocotb/vme_test:vme_test_program",
]

# List of targets to exclude from Spike co-simulation (e.g. tests requiring external IRQs)
SPIKE_DENYLIST = [
    "//hw_sim:mailbox_example",
    "//tests/cocotb/exceptions:store_fault_0",
    "//tests/cocotb/rvv:rvv_add",
    "//tests/cocotb/rvv:rvv_load",
    "//tests/cocotb/rvv:vstart_store",
    "//tests/cocotb:loop",
    "//tests/cocotb:registers",
    "//tests/cocotb:software_interrupt_test",
    "//tests/cocotb:stress_test",
    "//tests/cocotb:wfi_slot_0",
    "//tests/cocotb:wfi_slot_1",
    "//tests/cocotb:wfi_slot_2",
    "//tests/cocotb:wfi_slot_3",
    "//tests/cocotb/exceptions:vfwadd_trap",
    "//tests/cocotb/exceptions:vfwsub_trap",
    "//tests/cocotb/exceptions:vfwmul_trap",
    "//tests/cocotb/rvv:rvv_flush_race_test",
    "//tests/cocotb/rvv:rvv_small_loop_test",
    "//tests/cocotb:csr_behavior",
    "//tests/cocotb/rvv:rvv_vfrdiv_test",
]

# Map of targets to custom timeouts (in nanoseconds)
TIMEOUT_MAP = {
    "//examples:coralnpu_v2_rvv_add_intrinsic": 200000,
    "//tests/cocotb:nop_test": 5000000,
    "//tests/cocotb/rvv/ml_ops:rvv_float_matmul": 100000000,
    "//tests/cocotb/rvv/ml_ops:rvv_matmul": 100000000,
    "//tests/cocotb/rvv/ml_ops:rvv_matmul_assembly": 100000000,
    "//tests/cocotb/rvv/ml_ops/static_reference_tests:float_matmul_16x48x16": 100000000,
    "//tests/cocotb/rvv/ml_ops/static_reference_tests:int_matmul_16x48x16": 100000000,
}

def is_uvm_denylisted(target):
    """Returns True if target matches any pattern in DENYLIST."""
    for pattern in DENYLIST:
        if pattern == target:
            return True
        if pattern.startswith("*") and pattern.endswith("*"):
            if pattern[1:-1] in target:
                return True
        if pattern.endswith(":*"):
            if target.startswith(pattern[:-2] + ":"):
                return True
        if pattern.endswith("/*"):
            if target.startswith(pattern[:-2] + "/"):
                return True
        if pattern.endswith("*"):
            if target.startswith(pattern[:-1]):
                return True
    return False
