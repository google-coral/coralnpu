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

import subprocess
import os
import csv
import sys
import re
import argparse
import shutil
import stat
import datetime
import xml.etree.ElementTree as ET
import signal
import tempfile
import logging
from typing import List, Tuple, Optional, Dict
from elftools.elf.elffile import ELFFile

# Configure logging
logging.basicConfig(level=logging.INFO,
                    format="%(asctime)s - %(levelname)s - %(message)s",
                    datefmt="%H:%M:%S")

# List of targets to exclude from the regression
DENYLIST = [
    # Checks mcycle
    "//tests/cocotb/tutorial/counters:inst_cycle_counter_example",
    "//tests/cocotb/coralnpu_isa:perf_counters",
    # Peripherals
    "//tests/cocotb:timer_interrupt_test",
    "//tests/cocotb:plic_test",
    # RVV exceptions, not supported by MPACT (yet)
    "//tests/cocotb/rvv:vill_test",
    "//tests/cocotb:vector_store",
    "//tests/cocotb:vector_store_fault",
    # Jump to dtcm (also disabled in cocotb)
    "//third_party/riscv-tests:rv32ui-p-fence_i",
    "//third_party/riscv-tests:rv32ui-v-fence_i",
    # Actual RVV bugs?
    "//tests/cocotb/rvv:vmsif_test",
    "//tests/cocotb/rvv:vmsbf_test",
    "//tests/cocotb/rvv/load_store:load_unit_masked",
    "//tests/cocotb/rvv/load_store:store_unit_masked",
    "//tests/cocotb/rvv/arithmetics:vmsge_vx_test",
    # Enable when MPACT enables Zve32f
    "//tests/cocotb/rvv/ml_ops:rvv_float_matmul",
    "//tests/cocotb/rvv/ml_ops:rvv_float_matmul_assembly",
    "//tests/cocotb/rvv/arithmetics:rvv_fadd_float_m1",
    "//tests/cocotb/rvv/arithmetics:rvv_fdiv_float_m1",
    "//tests/cocotb/rvv/arithmetics:rvv_fmul_float_m1",
    "//tests/cocotb/rvv/arithmetics:rvv_fredmax_float_m1",
    "//tests/cocotb/rvv/arithmetics:rvv_fredmin_float_m1",
    "//tests/cocotb/rvv/arithmetics:rvv_fredusum_float_m1",
    "//tests/cocotb/rvv/arithmetics:rvv_fsub_float_m1",
    "//tests/cocotb/rvv/arithmetics:vfadd_vf_test",
    "//tests/cocotb/rvv/arithmetics:vfdiv_vf_test",
    "//tests/cocotb/rvv/arithmetics:vfmul_vf_test",
    "//tests/cocotb/rvv/arithmetics:vfsub_vf_test",
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
]

# Map of targets to custom timeouts (in nanoseconds)
TIMEOUT_MAP = {
    "//tests/cocotb/rvv/ml_ops:rvv_matmul": 100000000,
    "//tests/cocotb/rvv/ml_ops:rvv_matmul_assembly": 100000000,
    "//examples:coralnpu_v2_rvv_add_intrinsic": 200000,
}

# Spike simulation parameters
SPIKE_MEMORY_REGIONS = [
    (0x0, 0x2000),  # ITCM
    (0x10000, 0x8000),  # DTCM
    (0x20000000, 0x400000),  # DRAM
]
SPIKE_ISA = "rv32imf_zve32f_zvl128b_zicsr_zifencei_zbb_zfbfmin_zvfbfa"


def get_spike_memory_map_str() -> str:

    return ",".join([
        f"0x{start:x}:0x{length:x}" for start, length in SPIKE_MEMORY_REGIONS
    ])


def get_targets(limit: Optional[int] = None,
                target: Optional[str] = None) -> List[str]:

    if target:
        return [target]

    logging.info("Querying bazel targets...")
    # Using --output=xml to parse attributes
    cmd = ["bazel", "query", "kind(coralnpu_v2_binary, //...)", "--output=xml"]
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, check=True)
    except subprocess.CalledProcessError as e:
        logging.error(f"Bazel query failed: {e}")
        if e.stderr:
            logging.error(f"Stderr: {e.stderr}")
        sys.exit(1)
    root = ET.fromstring(result.stdout)
    targets = []
    for rule in root.findall('rule'):
        target_name_full = rule.attrib['name']  # //package:target

        # Check against DENYLIST
        if target_name_full in DENYLIST:
            continue

        # Check linker_script attribute
        linker_script_elem = rule.find("label[@name='linker_script']")
        if linker_script_elem is not None:
            linker_script = linker_script_elem.attrib['value']

            # Extract package and name from target
            # e.g. //tests/cocotb:align_test
            if ':' in target_name_full:
                parts = target_name_full.split(':')
                pkg = parts[0]
                name = parts[1]
            else:
                # Handling edge case //package (implicit :package)
                pkg = target_name_full
                name = target_name_full.split('/')[-1]

            # Construct expected default linker script
            # Default is generated in the same package with name <target_name>.ld
            expected_linker_script = f"{pkg}:{name}.ld"

            if linker_script == expected_linker_script:
                targets.append(target_name_full)
            else:
                # Skipping targets with custom/non-default linker scripts
                pass
        else:
            # If no linker_script attribute is found, it might not be a valid target for us, skip.
            pass

    targets = sorted(targets)
    if limit:
        return targets[:limit]
    return targets


def build_targets(targets: List[str]) -> bool:
    logging.info(f"Building {len(targets)} targets...")
    # Split into chunks to avoid command line length limits if necessary,
    # but for now pass all. Bazel handles many targets well.
    cmd = ["bazel", "build"] + targets
    try:
        subprocess.run(cmd, check=True)
        return True
    except subprocess.CalledProcessError as e:
        logging.error(f"Build failed for some targets: {e}")
        return False


def get_elf_source_path(target: str) -> Optional[str]:
    # Use bazel cquery to get the actual output path
    cmd = ["bazel", "cquery", "--output=files", target]
    try:
        result = subprocess.run(cmd,
                                capture_output=True,
                                text=True,
                                check=True)
        lines = result.stdout.strip().split('\n')
        for line in lines:
            if line.endswith('.elf'):
                return line.strip()
        return None
    except subprocess.CalledProcessError as e:
        logging.error(f"Error finding ELF source path: {e}")
        return None


def get_entry_point(elf_path: str) -> int:
    try:
        with open(elf_path, 'rb') as f:
            elf = ELFFile(f)
            return elf.header.e_entry
    except Exception as e:
        logging.error(f"Error reading ELF entry point: {e}")
        return 0


def get_tohost_addr(elf_path: str) -> Optional[int]:
    try:
        with open(elf_path, 'rb') as f:
            elf = ELFFile(f)
            symtab = elf.get_section_by_name('.symtab')
            if symtab:
                syms = symtab.get_symbol_by_name('tohost')
                if syms and len(syms) > 0:
                    return syms[0]['st_value']
    except Exception as e:
        logging.error(f"Error reading tohost addr: {e}")
    return None

def build_simulator(mpact_root: str,
                    mpact_riscv_root: Optional[str] = None) -> bool:
    logging.info("Building UVM Simulator (simv)...")
    env = os.environ.copy()
    env["CORALNPU_MPACT"] = mpact_root
    if mpact_riscv_root:
        env["CORALNPU_MPACT_RISCV"] = mpact_riscv_root

    cmd = ["make", "-C", "tests/uvm", "compile"]
    try:
        subprocess.run(cmd, check=True, env=env)
        return True
    except subprocess.CalledProcessError as e:
        logging.error(f"Simulator build failed: {e}")
        return False


def build_spike() -> Optional[str]:
    logging.info("Building Spike Simulator...")
    cmd = ["bazel", "build", "@riscv_isa_sim//:riscv_isa_sim"]
    try:
        subprocess.run(cmd, check=True)
        # Return the absolute path to the binary
        return os.path.abspath(
            "bazel-bin/external/riscv_isa_sim/riscv_isa_sim/bin/spike")
    except subprocess.CalledProcessError as e:
        logging.error(f"Spike build failed: {e}")
        return None


def generate_spike_log(spike_bin: str,
                       elf_path: str,
                       log_path: str,
                       entry_point: int = 0,
                       timeout: int = 30) -> bool:

    logging.info(
        f"Generating Spike log for {elf_path} (Entry: 0x{entry_point:x})...")
    cmd = [
        spike_bin, f"-m{get_spike_memory_map_str()}", f"--isa={SPIKE_ISA}",
        "--misaligned", "-l", "--log-commits", f"--pc={entry_point}", elf_path
    ]
    try:
        with open(log_path, 'w') as f:
            process = subprocess.Popen(cmd,
                                       stdin=subprocess.DEVNULL,
                                       stdout=f,
                                       stderr=subprocess.STDOUT,
                                       start_new_session=True)
            try:
                process.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                logging.warning(f"Spike timed out (PID: {process.pid})")
                os.killpg(os.getpgid(process.pid), signal.SIGTERM)
                process.wait(timeout=5)
                return False

            if process.returncode != 0:
                logging.error(
                    f"Spike failed with exit code {process.returncode}")
                return False
        return True
    except Exception as e:
        logging.error(f"Spike generation failed: {e}")
        return False


def run_uvm(elf_path: str,
            spike_log_path: Optional[str] = None,
            target: Optional[str] = None,
            mpact_root: str = "/tmp/copybara-mpact",
            tohost_addr: Optional[int] = None) -> Tuple[str, str, str]:

    logging.info(f"Running UVM for {elf_path}...")
    if not os.path.exists(elf_path):
        # We don't want to deal too much with handling exceptions in
        # the run loop that calls this. We'll just log in the CSV and let
        # the user pick up the pieces.
        return "BUILD_ARTIFACT_MISSING", "ELF file not found", ""

    env = os.environ.copy()
    env["CORALNPU_MPACT"] = mpact_root
    # Use absolute path for TEST_ELF
    abs_elf_path = os.path.abspath(elf_path)
    cmd = [
        "make", "-C", "tests/uvm", "run", "UVM_VERBOSITY=UVM_HIGH",
        f"TEST_ELF={abs_elf_path}"
    ]

    if target and target in TIMEOUT_MAP:
        timeout_ns = TIMEOUT_MAP[target]
        cmd.append(f"TEST_TIMEOUT_NS={timeout_ns}")
        logging.info(f"  Using custom timeout: {timeout_ns} ns")


    if tohost_addr is not None:
        cmd.append(f"EXTRA_PLUSARGS=+TOHOST_ADDR={tohost_addr:08x}")

    if spike_log_path:
        cmd.append(f"SPIKE_LOG={os.path.abspath(spike_log_path)}")

    max_retries = 3
    for attempt in range(1, max_retries + 1):
        try:
            result = subprocess.run(cmd,
                                    capture_output=True,
                                    text=True,
                                    env=env)
            output = result.stdout + result.stderr
            if result.returncode != 0 and "1-800-VERILOG" in output:
                if attempt < max_retries:
                    logging.warning(
                        f"  WARNING: License failure detected (1-800-VERILOG), retrying... (Attempt {attempt}/{max_retries})"
                    )
                    continue
                else:
                    logging.error(
                        f"  ERROR: License failure detected (1-800-VERILOG), max retries reached."
                    )
            # If successful or failed for other reasons, break loop
            break

        except Exception as e:
            return "EXEC_FAIL", str(e), ""

    # Process result (from last attempt)
    try:
        # Check for UVM errors/fatals regardless of return code
        # Match lines like: UVM_ERROR file.sv(123) @ 100: ... or UVM_FATAL @ 100: ...
        # Exclude summary lines like "UVM_ERROR : 0" or "Number of ... : 0"
        uvm_err = re.search(r"^\s*(UVM_(?:FATAL|ERROR)(?!.*:\s+0\s*$).*)$",
                            output, re.MULTILINE)

        if result.returncode != 0:
            status = "FAIL"
            reason = "Unknown Error"

            if uvm_err:
                reason = uvm_err.group(1).strip()
            elif "AXI_DECERR" in output:
                reason = "AXI_DECERR detected"
            else:
                lines = output.strip().split('\n')
                reason = "Make failed: " + (lines[-1] if lines else "Unknown")

            # Sanitize reason for CSV (remove commas and newlines)
            reason = reason.replace(',', ';').replace('\n', ' ')
            return status, reason, output

        # Even if return code is 0, check for UVM errors
        if uvm_err:
            reason = uvm_err.group(1).strip()
            # Sanitize reason for CSV
            reason = reason.replace(',', ';').replace('\n', ' ')
            return "FAIL", reason, output

        status = "PASS"
        return status, "None", output

    except Exception as e:
        return "EXEC_FAIL", str(e), ""


def get_riscv_test_artifacts() -> List[Tuple[str, str]]:
    logging.info("Collecting riscv-tests artifacts...")
    target = "//third_party/riscv-tests:all_files"
    cmd = ["bazel", "cquery", target, "--output=files"]
    try:
        result = subprocess.run(cmd,
                                capture_output=True,
                                text=True,
                                check=True)
    except subprocess.CalledProcessError as e:
        logging.error(f"Failed to query riscv-tests outputs: {e}")
        return []

    artifacts = []
    dirs = result.stdout.strip().split('\n')
    for d in dirs:
        d = d.strip()
        if not os.path.isdir(d):
            continue

        for root, _, files in os.walk(d):
            for f in files:
                if f.endswith('.dump'):
                    continue
                # heuristic: starts with rv32
                if f.startswith('rv32'):
                    full_path = os.path.join(root, f)
                    # Construct a pseudo-target name
                    # e.g. //third_party/riscv-tests:rv32ui-p-add
                    name = f
                    pseudo_target = f"//third_party/riscv-tests:{name}"
                    if pseudo_target in DENYLIST:
                        continue
                    artifacts.append((pseudo_target, full_path))

    return sorted(artifacts)


def parse_arguments():
    parser = argparse.ArgumentParser(description="Run UVM regression")
    parser.add_argument("--limit", type=int, help="Limit number of tests")
    parser.add_argument("--target", type=str, help="Run a single target")
    parser.add_argument("--list-targets",
                        action="store_true",
                        help="List targets and exit")
    parser.add_argument("--check-spike-timeouts",
                        action="store_true",
                        help="Run only Spike generation to identify timeouts")
    parser.add_argument("--skip-riscv-tests",
                        action="store_true",
                        help="Skip riscv-tests")
    parser.add_argument(
        "--mpact-root",
        type=str,
        help="Path to MPACT root directory (overrides CORALNPU_MPACT env var)")
    parser.add_argument(
        "--mpact-riscv-root",
        type=str,
        help=
        "Path to MPACT RISCV directory (overrides CORALNPU_MPACT_RISCV env var)"
    )
    parser.add_argument("--mpact-commit",
                        type=str,
                        help="Git commit hash to checkout for MPACT root")
    parser.add_argument(
        "--mpact-riscv-commit",
        type=str,
        help="Git commit hash to checkout for MPACT RISCV root")
    return parser.parse_args()


def checkout_git_commit(repo_root: str, commit: str):
    logging.info(f"Checking out {repo_root} at commit {commit}...")
    if not os.path.isdir(os.path.join(repo_root, ".git")):
        logging.error(
            f"{repo_root} is not a git repository. Cannot checkout commit.")
        sys.exit(1)

    try:
        # Fetch first to ensure we have the commit
        subprocess.run(["git", "-C", repo_root, "fetch"], check=True)
        subprocess.run(["git", "-C", repo_root, "checkout", commit],
                       check=True)
    except subprocess.CalledProcessError as e:
        logging.error(
            f"Failed to checkout commit {commit} in {repo_root}: {e}")
        sys.exit(1)


def get_mpact_configs(args) -> Tuple[str, Optional[str]]:
    if args.mpact_root:
        mpact_root = os.path.abspath(args.mpact_root)
    else:
        mpact_root = os.environ.get("CORALNPU_MPACT", "/tmp/copybara-mpact")

    mpact_riscv_root = None
    if args.mpact_riscv_root:
        mpact_riscv_root = os.path.abspath(args.mpact_riscv_root)
    elif "CORALNPU_MPACT_RISCV" in os.environ:
        mpact_riscv_root = os.environ["CORALNPU_MPACT_RISCV"]

    return mpact_root, mpact_riscv_root


def prepare_tests(args, standard_targets: List[str]) -> List[Tuple[str, str]]:
    # Build targets
    # Filter out pseudo-targets from standard_targets if they match riscv-tests pattern
    real_targets = [
        t for t in standard_targets
        if not t.startswith("//third_party/riscv-tests:")
    ]
    targets_to_build = real_targets
    if not args.skip_riscv_tests:
        targets_to_build.append("//third_party/riscv-tests:all_files")

    if not build_targets(targets_to_build):
        logging.warning(
            "WARNING: Some targets failed to build. Continuing with available artifacts."
        )

    # Now populate tests_to_run with valid ELFs
    tests_to_run = []

    # 1. RISC-V Tests
    if not args.skip_riscv_tests:
        riscv_tests = get_riscv_test_artifacts()
        for t, elf in riscv_tests:
            if args.target and args.target != t:
                continue
            tests_to_run.append((t, elf))

    # 2. Standard Targets
    if standard_targets:
        logging.info("Resolving standard target artifacts...")
    for t in standard_targets:
        if args.target and args.target != t:
            continue
        elf = get_elf_source_path(t)
        if elf:
            tests_to_run.append((t, elf))

    # Apply global limit if set
    if args.limit:
        tests_to_run = tests_to_run[:args.limit]

    return tests_to_run


def run_spike_timeout_check(tests_to_run: List[Tuple[str, str]],
                            spike_bin: str, temp_elf_dir: str):
    logging.info("--- Checking Spike Timeouts ---")
    failed_targets = []
    for i, (target, src_elf) in enumerate(tests_to_run):
        logging.info(f"[{i+1}/{len(tests_to_run)}] Checking {target}")

        if src_elf and os.path.exists(src_elf):
            safe_name = target.replace('//', '').replace(':', '_').replace(
                '/', '_') + ".elf"
            dest_elf = os.path.join(temp_elf_dir, safe_name)
            try:
                if os.path.exists(dest_elf): os.remove(dest_elf)
                shutil.copy2(src_elf, dest_elf)
                # Permissions: 755 / -rwxr-xr-x / u=rwx,go=rx
                os.chmod(
                    dest_elf, stat.S_IRUSR | stat.S_IWUSR | stat.S_IXUSR
                    | stat.S_IRGRP
                    | stat.S_IXGRP | stat.S_IROTH | stat.S_IXOTH)

                entry_point = get_entry_point(dest_elf)
                temp_spike_log = os.path.join(temp_elf_dir,
                                              safe_name + ".spike.log")

                if not generate_spike_log(
                        spike_bin,
                        dest_elf,
                        temp_spike_log,
                        entry_point,
                        timeout=10):  # Short timeout for check
                    logging.error(f"  FAIL: {target}")
                    failed_targets.append(target)
                else:
                    logging.info(f"  PASS: {target}")
            except Exception as e:
                logging.error(f"  ERROR: {target} - {e}")
                failed_targets.append(target)
        else:
            logging.warning(f"  SKIP: {target} (ELF not found)")

    logging.info("\n--- Suggested SPIKE_DENYLIST ---")
    logging.info("SPIKE_DENYLIST = [")
    for t in failed_targets:
        logging.info(f'    "{t}",')
    logging.info("]")


def run_full_regression(tests_to_run: List[Tuple[str, str]], spike_bin: str,
                        mpact_root: str, mpact_riscv_root: Optional[str],
                        temp_elf_dir: str):
    # Build the UVM simulator once
    if not build_simulator(mpact_root, mpact_riscv_root):
        logging.critical("ERROR: Simulator build failed. Aborting regression.")
        sys.exit(1)

    # Setup output directory
    timestamp = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
    output_dir = f"uvm_regression_{timestamp}"
    logs_dir = os.path.join(output_dir, "logs")
    os.makedirs(logs_dir, exist_ok=True)
    logging.info(f"Regression results will be stored in: {output_dir}")

    # 1. Preparation: Copy ELFs and generate Spike logs
    logging.info(f"Preparing {len(tests_to_run)} tests...")
    test_info_map = {} # target -> info dict
    for i, (target, src_elf) in enumerate(tests_to_run):
        if src_elf and os.path.exists(src_elf):
            safe_name = target.replace('//', '').replace(':', '_').replace('/', '_') + ".elf"
            dest_elf = os.path.join(temp_elf_dir, safe_name)

            try:
                if os.path.exists(dest_elf): os.remove(dest_elf)
                shutil.copy2(src_elf, dest_elf)
                os.chmod(dest_elf, stat.S_IRUSR | stat.S_IWUSR | stat.S_IXUSR | stat.S_IRGRP | stat.S_IXGRP | stat.S_IROTH | stat.S_IXOTH)

                entry_point = get_entry_point(dest_elf)
                spike_log_path = "NONE"
                if spike_bin and target not in SPIKE_DENYLIST:
                    spike_log_name = safe_name + ".spike.log"
                    temp_spike_log = os.path.join(temp_elf_dir, spike_log_name)
                    if os.path.exists(temp_spike_log): os.remove(temp_spike_log)
                    cmd_spike = [
                        spike_bin, f"-m{get_spike_memory_map_str()}", f"--isa={SPIKE_ISA}",
                        "--misaligned", "-l", "--log-commits", f"--pc={entry_point}", dest_elf
                    ]
                    try:
                        with open(os.devnull, 'w') as devnull:
                            subprocess.run(cmd_spike, stdout=devnull, stderr=devnull, timeout=30)
                        if os.path.exists(temp_spike_log):
                            shutil.copy2(temp_spike_log, os.path.join(logs_dir, spike_log_name))
                            spike_log_path = os.path.abspath(temp_spike_log)
                    except: pass

                tohost_addr = get_tohost_addr(dest_elf)
                if tohost_addr is None: tohost_addr = 0xFFFFFFFF
                timeout = TIMEOUT_MAP.get(target, 100000)

                test_info_map[target] = {
                    "elf": os.path.abspath(dest_elf),
                    "tohost": tohost_addr,
                    "entry": entry_point,
                    "timeout": timeout,
                    "spike": spike_log_path,
                    "safe_log": safe_name.replace('.elf', '.log')
                }
            except Exception as e:
                logging.error(f"Failed to prepare {target}: {e}")

    # 2. Execute Simulation with Crash Recovery
    results = []
    completed_targets = set()
    pending_targets = [t for t, _ in tests_to_run if t in test_info_map]

    env = os.environ.copy()
    env["CORALNPU_MPACT"] = mpact_root
    regression_log_path = os.path.join(logs_dir, "regression.log")

    logging.info("--- Starting Batch UVM Regression ---")

    while pending_targets:
        # Create REGRESSION_LIST for current batch
        batch_list_path = os.path.join(output_dir, "current_batch.txt")
        with open(batch_list_path, 'w') as f_list:
            for t in pending_targets:
                info = test_info_map[t]
                f_list.write(f"{info['elf']} {info['tohost']:08x} {info['entry']:08x} {info['timeout']} {info['spike']} {t}\n")

        cmd = [
            "make", "-C", "tests/uvm", "run", 
            "UVM_VERBOSITY=UVM_LOW",
            "UVM_TESTNAME=coralnpu_regression_test",
            f"EXTRA_PLUSARGS=+REGRESSION_LIST={os.path.abspath(batch_list_path)}"
        ]

        current_target = None
        current_test_log = None
        current_reason = "None"

        try:
            with open(regression_log_path, 'a') as f_log:
                process = subprocess.Popen(cmd, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)

                for line in process.stdout:
                    f_log.write(line)
                    if current_test_log: current_test_log.write(line)

                    # Detect start of test
                    start_match = re.search(r'--- STARTING TEST: (.*?) ---', line)
                    if start_match:
                        current_target = start_match.group(1)
                        logging.info(f"Running UVM for {current_target}...")

                        log_path = os.path.join(logs_dir, test_info_map[current_target]['safe_log'])
                        if current_test_log: current_test_log.close()
                        current_test_log = open(log_path, 'w')
                        current_test_log.write(line)
                        current_reason = "None"
                        continue

                    # Parse for failure reasons
                    if current_target:
                        # Prioritize the first error found for the summary
                        err_match = re.search(r"^\s*(UVM_(?:FATAL|ERROR)(?!.*:\s+0\s*$).*)$", line, re.MULTILINE)
                        if err_match:
                            err_msg = err_match.group(1).strip()
                            logging.error(f"    {err_msg}")
                            if current_reason == "None":
                                current_reason = err_msg.replace(',', ';')
                        else:
                            # Match standard Verilog Error/Fatal/Assertion
                            verilog_err = re.search(r"^(Error|Fatal|Runtime Error|Assertion failed):? (.*)$", line, re.MULTILINE)
                            if verilog_err:
                                err_msg = verilog_err.group(0).strip()
                                logging.error(f"    {err_msg}")
                                if current_reason == "None":
                                    current_reason = err_msg.replace(',', ';')

                        if "** UVM TEST PASSED **" in line:
                            logging.info(f"  Result: PASS - {current_reason}")
                            results.append({
                                "Target": current_target, "Status": "PASS", "Reason": current_reason,
                                "Log Path": os.path.join("logs", test_info_map[current_target]['safe_log'])
                            })
                            completed_targets.add(current_target)
                            current_test_log.close()
                            current_test_log = None
                            current_target = None
                        elif "** UVM TEST FAILED **" in line:
                            logging.info(f"  Result: FAIL - {current_reason}")
                            results.append({
                                "Target": current_target, "Status": "FAIL", "Reason": current_reason,
                                "Log Path": os.path.join("logs", test_info_map[current_target]['safe_log'])
                            })
                            completed_targets.add(current_target)
                            current_test_log.close()
                            current_test_log = None
                            current_target = None

                process.wait()
                if current_test_log: current_test_log.close()

                # If process ended while a test was running, mark it as a crash
                if current_target:
                    status = "FAIL"
                    if current_reason == "None":
                        current_reason = "Simulator exited early or crashed"
                    logging.error(f"  Result: {status} - {current_reason}")
                    results.append({
                        "Target": current_target, "Status": status, "Reason": current_reason,
                        "Log Path": os.path.join("logs", test_info_map[current_target]['safe_log'])
                    })
                    completed_targets.add(current_target)
                    current_target = None

        except Exception as e:
            logging.error(f"Batch execution failed: {e}")
            break # Avoid infinite loop if prepare/launch fails fundamentally

        # Update pending targets for next batch attempt
        pending_targets = [t for t in pending_targets if t not in completed_targets]
        if pending_targets:
            logging.warning(f"Simulator crashed. Restarting for {len(pending_targets)} remaining tests...")

    # 3. Finalization
    csv_file = os.path.join(output_dir, "uvm_results.csv")
    with open(csv_file, "w", newline='') as csvfile:
        fieldnames = ["Target", "Status", "Reason", "Log Path"]
        writer = csv.DictWriter(csvfile, fieldnames=fieldnames)
        writer.writeheader()
        for row in results:
            writer.writerow(row)

    logging.info(f"Results written to {csv_file}")
    zip_filename = f"{output_dir}"
    logging.info(f"Creating archive {zip_filename}.zip...")
    shutil.make_archive(zip_filename, 'zip', output_dir)
    logging.info(f"Artifact created: {os.path.abspath(zip_filename + '.zip')}")

    any_failed = any(r["Status"] != "PASS" for r in results)
    if any_failed:
        num_failed = sum(1 for r in results if r["Status"] != "PASS")
        logging.error(f"Regression FAILED: {num_failed} tests failed.")
        sys.exit(1)

    logging.info("Regression PASSED.")


def main():
    args = parse_arguments()
    mpact_root, mpact_riscv_root = get_mpact_configs(args)

    if args.mpact_commit:
        checkout_git_commit(mpact_root, args.mpact_commit)

    if args.mpact_riscv_commit and mpact_riscv_root:
        checkout_git_commit(mpact_riscv_root, args.mpact_riscv_commit)

    logging.info(f"Using MPACT root: {mpact_root}")
    if mpact_riscv_root:
        logging.info(f"Using MPACT RISCV root: {mpact_riscv_root}")

    standard_targets = get_targets(args.limit, args.target)

    if args.list_targets:
        logging.info("Targets to be verified:")
        for t in standard_targets:
            logging.info(t)
        logging.info(
            "(Note: riscv-tests are discovered after build and not listed here unless built)"
        )
        return

    tests_to_run = prepare_tests(args, standard_targets)
    logging.info(f"Found {len(tests_to_run)} tests to run.")

    # Build Spike once
    spike_bin = build_spike()
    if not spike_bin or not os.path.exists(spike_bin):
        logging.critical("ERROR: Spike binary not found. Aborting.")
        sys.exit(1)

    # Use secure temporary directory
    with tempfile.TemporaryDirectory(prefix="uvm_reg_") as temp_elf_dir:
        logging.info(f"Using temp ELF directory: {temp_elf_dir}")

        if args.check_spike_timeouts:
            run_spike_timeout_check(tests_to_run, spike_bin, temp_elf_dir)
            return

        run_full_regression(tests_to_run, spike_bin, mpact_root,
                            mpact_riscv_root, temp_elf_dir)


if __name__ == "__main__":
    main()
