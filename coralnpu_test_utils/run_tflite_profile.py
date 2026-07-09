#!/usr/bin/env python3
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

import argparse
import sys
import os
import struct
import logging
import time
import re
import json

# To support 'import coralnpu_hw.coralnpu_test_utils' without Bazel:
_script_dir = os.path.dirname(os.path.abspath(__file__))
_project_root = os.path.dirname(_script_dir)
if _project_root not in sys.path:
    sys.path.insert(0, _project_root)

try:
    import coralnpu_hw
except ImportError:
    import types
    _coralnpu_hw = types.ModuleType("coralnpu_hw")
    _coralnpu_hw.__path__ = [_project_root]
    sys.modules["coralnpu_hw"] = _coralnpu_hw

from bazel_tools.tools.python.runfiles import runfiles
from coralnpu_hw.coralnpu_test_utils.elf_util import parse_elf
from coralnpu_hw.coralnpu_test_utils.ftdi_spi_master import FtdiSpiMaster

logger = logging.getLogger(__name__)


class TfliteProfiler:
    """Loads a generic TFLite runner, injects a TFLite model, and profiles execution."""

    def __init__(
        self,
        runner_elf_path,
        model_path,
        usb_serial=None,
        ftdi_port=1,
        csr_base_addr=0x30000,
        detailed=False,
        force_run=False,
    ):
        self.runner_elf_path = runner_elf_path
        self.model_path = model_path
        # Resolve relative path if run via bazel run
        if not os.path.isabs(self.model_path
                             ) and "BUILD_WORKSPACE_DIRECTORY" in os.environ:
            self.model_path = os.path.join(
                os.environ["BUILD_WORKSPACE_DIRECTORY"], self.model_path
            )
        self.usb_serial = usb_serial
        self.ftdi_port = ftdi_port
        self.csr_base_addr = csr_base_addr
        self.detailed = detailed
        self.force_run = force_run

        self.cached_data = None
        self.entry_point = None
        self.symbols = {}

        self.use_cache = self._is_cache_valid(force_run)

        if not self.use_cache:
            if not usb_serial:
                raise ValueError(
                    "Cache is invalid/stale, and --usb-serial is required to"
                    " run on hardware."
                )
            logger.info(
                "Cache is invalid or --force was set. Preparing hardware"
                " execution..."
            )
            self.spi_master = FtdiSpiMaster(
                usb_serial, ftdi_port, csr_base_addr
            )
            self._parse_elf()
        else:
            logger.info(
                "[Cache] Valid cache found. Skipping hardware execution (use"
                " --force to rerun)."
            )

    def _is_cache_valid(self, force_run=False):
        if force_run:
            return False

        cache_path = self._get_cache_path()
        if not os.path.exists(cache_path):
            return False

        try:
            with open(cache_path, "r") as f:
                data = json.load(f)

            # Check model path
            cached_model = data.get("model_path")
            if not cached_model:
                return False

            abs_cached_model = os.path.abspath(cached_model)
            abs_current_model = os.path.abspath(self.model_path)
            if abs_cached_model != abs_current_model:
                return False

            # Check model mtime
            if not os.path.exists(self.model_path):
                return False
            current_model_mtime = os.path.getmtime(self.model_path)
            if abs(data.get("model_mtime", 0) - current_model_mtime) > 0.1:
                return False

            # Check runner path and mtime
            cached_runner = data.get("runner_path")
            if not cached_runner:
                return False
            abs_cached_runner = os.path.abspath(cached_runner)
            abs_current_runner = os.path.abspath(self.runner_elf_path)
            if abs_cached_runner != abs_current_runner:
                return False

            if not os.path.exists(self.runner_elf_path):
                return False
            current_runner_mtime = os.path.getmtime(self.runner_elf_path)
            if abs(data.get("runner_mtime", 0) - current_runner_mtime) > 0.1:
                return False

            # Check USB serial (if provided)
            if self.usb_serial and data.get("usb_serial") != self.usb_serial:
                return False

            self.cached_data = data
            return True
        except Exception as e:
            logger.warning(f"Error validating cache: {e}")
            return False

    def _parse_elf(self):
        """Parses the runner ELF to find symbol addresses."""
        logger.info(f"Parsing runner ELF file: {self.runner_elf_path}")
        required_symbols = [
            'model_buffer', 'model_size', 'cycle_count', 'init_status',
            'invoke_status', 'debug_log_buffer', 'debug_log_ptr'
        ]
        entry_point, symbol_map = parse_elf(
            self.runner_elf_path, required_symbols
        )
        self.entry_point = entry_point
        self.symbols = symbol_map

        if self.entry_point is None or not all(sym in self.symbols
                                               for sym in required_symbols):
            raise ValueError(
                "Could not find all required symbols in runner ELF."
            )

        for name, sym_info in self.symbols.items():
            logger.info(f"  Found symbol '{name}' at 0x{sym_info.addr:x}")

    def _get_device_logs(self):
        """Reads device-side debug logs from memory and returns them as string."""
        try:
            ptr_data = self.spi_master.read_data(
                self.symbols['debug_log_ptr'].addr, 4
            )
            ptr = struct.unpack("<I", ptr_data)[0]
            if ptr == 0:
                return ""

            LOG_BUFFER_SIZE = 8192
            if ptr > LOG_BUFFER_SIZE:
                logger.warning(
                    f"Device log pointer {ptr} exceeds buffer size, capping."
                )
                ptr = LOG_BUFFER_SIZE

            log_data = self.spi_master.read_data(
                self.symbols['debug_log_buffer'].addr, ptr
            )
            return log_data.decode('utf-8', errors='replace')
        except Exception as e:
            logger.error(f"Failed to read device logs: {e}")
            return ""

    def _print_device_logs(self):
        """Reads and prints the device-side debug logs from memory."""
        log_str = self._get_device_logs()
        if log_str:
            print("\n--- Device Debug Logs ---")
            print(log_str)
            print("-------------------------\n")
        else:
            logger.info("Device logs are empty.")

    def _parse_and_print_fallbacks(self, log_str):
        """Parses fallback kernel info from logs and prints a summary with MACs."""
        pattern = r"Fallback kernel: fh=(\d+) fw=(\d+) id=(\d+) od=(\d+) oh=(\d+) ow=(\d+)"
        matches = re.findall(pattern, log_str)

        if not matches:
            return

        # Aggregate matches with MACs and Output Size (if detailed)
        stats = {}
        for fh_s, fw_s, id_s, od_s, oh_s, ow_s in matches:
            fh, fw, id_val, od, oh, ow = map(
                int, [fh_s, fw_s, id_s, od_s, oh_s, ow_s]
            )
            macs = fh * fw * id_val * od * oh * ow

            if self.detailed:
                key = (fh, fw, id_val, od, oh, ow)
            else:
                key = (fh, fw, id_val, od)
            if key not in stats:
                stats[key] = {'count': 0, 'macs': 0}
            stats[key]['count'] += 1
            stats[key]['macs'] += macs

        # Sort by Total MACs descending, then by frequency, then by key
        sorted_stats = sorted(
            stats.items(), key=lambda x: (-x[1]['macs'], -x[1]['count'], x[0])
        )

        if self.detailed:
            columns = [
                {
                    "header": "Filter Shape",
                    "width": 12,
                    "fmt": lambda k, s: f"{k[0]}x{k[1]}"
                },
                {
                    "header": "Input Depth",
                    "width": 12,
                    "fmt": lambda k, s: str(k[2])
                },
                {
                    "header": "Output Depth",
                    "width": 12,
                    "fmt": lambda k, s: str(k[3])
                },
                {
                    "header": "Output Size",
                    "width": 12,
                    "fmt": lambda k, s: f"{k[4]}x{k[5]}"
                },
                {
                    "header": "Frequency",
                    "width": 9,
                    "fmt": lambda k, s: str(s['count'])
                },
                {
                    "header": "Est. MACs (Total)",
                    "width": 18,
                    "fmt": lambda k, s: f"{s['macs']:,}"
                },
            ]
        else:
            columns = [
                {
                    "header": "Filter Shape",
                    "width": 12,
                    "fmt": lambda k, s: f"{k[0]}x{k[1]}"
                },
                {
                    "header": "Input Depth",
                    "width": 12,
                    "fmt": lambda k, s: str(k[2])
                },
                {
                    "header": "Output Depth",
                    "width": 12,
                    "fmt": lambda k, s: str(k[3])
                },
                {
                    "header": "Frequency",
                    "width": 9,
                    "fmt": lambda k, s: str(s['count'])
                },
                {
                    "header": "Est. MACs (Total)",
                    "width": 18,
                    "fmt": lambda k, s: f"{s['macs']:,}"
                },
            ]

        header_parts = [f"{col['header']:<{col['width']}}" for col in columns]
        header_str = " | ".join(header_parts)
        line_width = len(header_str)
        separator = "-" * line_width

        title_suffix = " - Detailed" if self.detailed else ""
        print(
            f"\n--- Fallback Kernels Summary (Sorted by Est. Compute){title_suffix} ---"
        )
        print(header_str)
        print(separator)

        for key, stat in sorted_stats:
            row_parts = [
                f"{col['fmt'](key, stat):<{col['width']}}" for col in columns
            ]
            print(" | ".join(row_parts))
        print(separator + "\n")

    def run_profile(self):
        """Loads the runner and model, executes, and prints cycle count."""
        if self.use_cache:
            self._replay_profile()
            return

        # Read model file
        if not os.path.exists(self.model_path):
            raise FileNotFoundError(f"Model file not found: {self.model_path}")

        logger.info(f"Reading model file: {self.model_path}")
        with open(self.model_path, 'rb') as f:
            model_data = f.read()

        model_sz = len(model_data)
        logger.info(f"Model size: {model_sz} bytes")

        MAX_MODEL_SIZE = 512 * 1024  # Must match tflite_runner.cc
        if model_sz > MAX_MODEL_SIZE:
            raise ValueError(
                f"Model size ({model_sz}) exceeds max supported size ({MAX_MODEL_SIZE})"
            )

        self.spi_master.idle_clocking(20)

        # 1. Load runner ELF (do not start)
        logger.info("Loading runner ELF...")
        self.spi_master.load_elf(self.runner_elf_path, start_core=False)

        # 2. Inject model data and size
        logger.info(
            f"Injecting model data to 0x{self.symbols['model_buffer'].addr:x}..."
        )
        self.spi_master.load_data(
            model_data, self.symbols['model_buffer'].addr
        )

        logger.info(
            f"Setting model size to {model_sz} at 0x{self.symbols['model_size'].addr:x}..."
        )
        size_bytes = struct.pack("<I", model_sz)
        self.spi_master.load_data(size_bytes, self.symbols['model_size'].addr)

        # 3. Start execution
        self.spi_master.set_entry_point(self.entry_point)
        logger.info("Starting execution...")
        start_time = time.time()
        self.spi_master.start_core()

        # 4. Wait for halt
        logger.info(
            "Waiting for core to halt (this may take a few minutes due to fallback kernels)..."
        )
        if not self.spi_master.poll_for_halt(timeout=300.0):
            # Read status upon timeout to help debug
            init_status_data = self.spi_master.read_data(
                self.symbols['init_status'].addr, 4
            )
            init_status = struct.unpack("<i", init_status_data)[0]
            invoke_status_data = self.spi_master.read_data(
                self.symbols['invoke_status'].addr, 4
            )
            invoke_status = struct.unpack("<i", invoke_status_data)[0]
            logger.error(
                f"Timeout debug: init_status={init_status}, invoke_status={invoke_status}"
            )
            self._print_device_logs()
            raise RuntimeError("Run failed: Core did not halt.")

        elapsed_time = time.time() - start_time
        logger.info("Core halted.")

        # 5. Check status
        init_status_data = self.spi_master.read_data(
            self.symbols['init_status'].addr, 4
        )
        init_status = struct.unpack("<i", init_status_data)[0]

        invoke_status_data = self.spi_master.read_data(
            self.symbols['invoke_status'].addr, 4
        )
        invoke_status = struct.unpack("<i", invoke_status_data)[0]

        if init_status != 1:
            self._print_device_logs()
            raise RuntimeError(
                f"TFLite initialization FAILED on device with status: {init_status}"
            )

        if invoke_status != 1:
            self._print_device_logs()
            raise RuntimeError(
                f"TFLite invocation FAILED on device with status: {invoke_status}"
            )

        # 6. Read cycle count
        cycle_data = self.spi_master.read_data(
            self.symbols['cycle_count'].addr, 8
        )
        cycles = struct.unpack("<Q", cycle_data)[0]

        # 7. Retrieve logs for fallback analysis (on success)
        log_str = self._get_device_logs()

        # Save to cache
        self._save_to_cache(cycles, elapsed_time, log_str)

        self._print_results(cycles, elapsed_time, log_str)

    def _print_results(self, cycles, elapsed_time, log_str):
        print("\n========================================")
        print(f"Model: {os.path.basename(self.model_path)}")
        print(f"Inference Cycle Count: {cycles}")
        if self.detailed:
            print(f"Host-measured Wall Time: {elapsed_time:.2f} seconds")
        print("========================================\n")

        if log_str:
            self._parse_and_print_fallbacks(log_str)

    def _save_to_cache(self, cycles, elapsed_time, log_str):
        cache_path = self._get_cache_path()
        try:
            abs_model_path = os.path.abspath(self.model_path)
            abs_runner_path = os.path.abspath(self.runner_elf_path)
            data = {
                "model_path": abs_model_path,
                "model_mtime": os.path.getmtime(self.model_path),
                "runner_path": abs_runner_path,
                "runner_mtime": os.path.getmtime(self.runner_elf_path),
                "usb_serial": self.usb_serial,
                "cycles": cycles,
                "elapsed_time": elapsed_time,
                "log_str": log_str,
            }
            with open(cache_path, "w") as f:
                json.dump(data, f, indent=2)
            logger.info(f"Saved run profile results to cache: {cache_path}")
        except Exception as e:
            logger.warning(f"Failed to save results to cache: {e}")

    def _get_cache_path(self):
        # Use workspace directory if run via bazel, otherwise CWD
        base_dir = os.environ.get("BUILD_WORKSPACE_DIRECTORY", os.getcwd())
        model_name = os.path.basename(self.model_path)
        return os.path.join(base_dir, f"profile_cache_{model_name}.json")

    def _replay_profile(self):
        if not self.cached_data:
            raise ValueError("No cached data available to replay.")

        # Override model path from cache for display
        self.model_path = self.cached_data["model_path"]

        self._print_results(
            self.cached_data["cycles"],
            self.cached_data["elapsed_time"],
            self.cached_data["log_str"],
        )


def main():
    parser = argparse.ArgumentParser(
        description="Profile any TFLite model on CoralNPU FPGA."
    )
    parser.add_argument(
        "model_file", help="Path to the .tflite model file to profile."
    )
    parser.add_argument(
        "--usb-serial",
        help=
        "USB serial number of the FTDI device (optional if valid cache exists).",
    )
    parser.add_argument(
        "--ftdi-port",
        type=int,
        default=1,
        help="Port number of the FTDI device.",
    )
    parser.add_argument(
        "--csr-base-addr",
        type=lambda x: int(x, 0),
        default=0x30000,
        help="Base address for CSR registers (default: 0x30000).",
    )
    parser.add_argument(
        "--highmem",
        action="store_true",
        help="Use high memory (0x200000) for CSR base address.",
    )
    parser.add_argument(
        "--verbose",
        action="store_true",
        help="Enable verbose logging.",
    )
    parser.add_argument(
        "--detailed",
        action="store_true",
        help=
        "Print detailed fallback information including output sizes and wall time.",
    )
    parser.add_argument(
        "--force",
        action="store_true",
        help="Force execution on hardware even if cache is valid.",
    )
    args = parser.parse_args()

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s - %(levelname)s - %(message)s",
    )

    csr_base_addr = args.csr_base_addr
    if args.highmem:
        csr_base_addr = 0x200000

    # Locate runner ELF using runfiles
    r = runfiles.Create()
    runner_elf = r.Rlocation(
        "coralnpu_hw/sw/utils/tflite_runner/tflite_runner.elf"
    )
    if not runner_elf or not os.path.exists(runner_elf):
        # Fallback for manual run outside bazel sandbox
        script_dir = os.path.dirname(os.path.abspath(__file__))
        project_root = os.path.abspath(os.path.join(script_dir, ".."))
        runner_elf = os.path.join(
            project_root, "bazel-bin/sw/utils/tflite_runner/tflite_runner.elf"
        )

    if not os.path.exists(runner_elf):
        logger.error(
            f"Could not find tflite_runner.elf. Please build it first: bazel build //sw/utils/tflite_runner"
        )
        sys.exit(1)

    try:
        profiler = TfliteProfiler(
            runner_elf,
            args.model_file,
            args.usb_serial,
            args.ftdi_port,
            csr_base_addr,
            detailed=args.detailed,
            force_run=args.force,
        )
        profiler.run_profile()
    except Exception as e:
        logger.error(f"Error: {e}")
        import traceback
        traceback.print_exc()
        sys.exit(1)


if __name__ == "__main__":
    main()
