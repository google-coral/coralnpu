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

"""Test runner for CoralNPU SoC Verilator simulation.

Launches the Verilator simulator, loads an ELF binary via the SPI loader,
and determines pass/fail from UART output or exit status.
"""

import argparse
import logging
import os
import re
import signal
import socket
import subprocess
import sys
import threading
import time

from bazel_tools.tools.python.runfiles import runfiles


def find_free_port():
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("", 0))
        return s.getsockname()[1]


class SimTestRunner:
    """Manages the lifecycle of a simulation test."""

    PASS_PATTERN = re.compile(r"PASS|TEST.?PASSED", re.IGNORECASE)
    FAIL_PATTERN = re.compile(r"FAIL|TEST.?FAILED|ERROR|ABORT", re.IGNORECASE)

    def __init__(
        self,
        elf_file,
        sim_timeout,
        trace_file=None,
        highmem=False,
        itcm_size_kbytes=8,
        dtcm_size_kbytes=32,
        loader_mode="backdoor",
    ):
        self.elf_file = elf_file
        self.sim_timeout = sim_timeout
        self.trace_file = trace_file
        self.highmem = highmem
        self.itcm_size_kbytes = itcm_size_kbytes
        self.dtcm_size_kbytes = dtcm_size_kbytes
        self.loader_mode = loader_mode
        self.test_result = None  # None=unknown, True=pass, False=fail
        self.sim_proc = None
        self.loader_proc = None
        self.threads = []
        self._result_lock = threading.Lock()

    def _set_result(self, passed):
        with self._result_lock:
            if self.test_result is None:
                self.test_result = passed

    def _tail_uart_log(self, candidates, timeout):
        """Tails a UART log file, checking for pass/fail patterns."""
        deadline = time.monotonic() + timeout
        # Wait for any candidate file to appear
        path = None
        while time.monotonic() < deadline:
            for c in candidates:
                if os.path.exists(c):
                    path = c
                    break
            if path:
                break
            if self.sim_proc and self.sim_proc.poll() is not None:
                return
            time.sleep(0.1)
        if not path:
            logging.warning("SIM_TEST: uart1.log not found")
            return
        logging.warning(f"SIM_TEST: Tailing UART log: {path}")
        try:
            with open(path, "r") as f:
                while time.monotonic() < deadline:
                    with self._result_lock:
                        if self.test_result is not None:
                            return
                    line = f.readline()
                    if not line:
                        if self.sim_proc and self.sim_proc.poll() is not None:
                            return
                        time.sleep(0.05)
                        continue

                    stripped = line.strip()
                    if not stripped:
                        continue

                    logging.warning(f"[UART] {stripped}")
                    if self.PASS_PATTERN.search(stripped):
                        self._set_result(True)
                        return
                    if self.FAIL_PATTERN.search(stripped):
                        self._set_result(False)
                        return
        except OSError:
            pass

    def _stream_reader(self, pipe, prefix, check_output=False):
        """Reads lines from a subprocess pipe, optionally checking for pass/fail."""
        try:
            for line in iter(pipe.readline, ""):
                stripped = line.strip()
                logging.warning(f"[{prefix}] {stripped}")
                if check_output and stripped:
                    if self.PASS_PATTERN.search(stripped):
                        self._set_result(True)
                    elif self.FAIL_PATTERN.search(stripped):
                        self._set_result(False)
        finally:
            pipe.close()

    def run(self):
        r = runfiles.Create()

        sim_bin_name = "Vchip_verilator_highmem" if self.highmem else "Vchip_verilator"
        sim_bin_path = r.Rlocation("coralnpu_hw/fpga/" + sim_bin_name)
        if not sim_bin_path or not os.path.exists(sim_bin_path):
            build_target = "build_chip_verilator_highmem" if self.highmem else "build_chip_verilator"
            long_path = f"coralnpu_hw/fpga/{build_target}/com.google.coralnpu_fpga_chip_verilator_0.1/sim-verilator/Vchip_verilator"
            sim_bin_path = r.Rlocation(long_path)
            if not sim_bin_path or not os.path.exists(sim_bin_path):
                logging.error(f"Could not find simulator binary ({sim_bin_name}) in runfiles.")
                return 1

        loader_path = r.Rlocation("coralnpu_hw/utils/coralnpu_soc_loader/loader")
        if not loader_path or not os.path.exists(loader_path):
            logging.error("Could not find loader binary in runfiles.")
            return 1

        port = find_free_port()
        sim_env = os.environ.copy()
        sim_env["SPI_DPI_PORT"] = str(port)

        # Ensure required data files are in Current working directory
        raw_image_path = r.Rlocation("coralnpu_hw/fpga/ip/ispyocto/grey_bars_320x240.raw")
        if raw_image_path and os.path.exists(raw_image_path):
            if not os.path.exists("grey_bars_320x240.raw"):
                try:
                    os.symlink(raw_image_path, "grey_bars_320x240.raw")
                except OSError:
                    pass

        try:
            # Start simulator
            sim_cmd = [sim_bin_path]
            if self.trace_file:
                sim_cmd.append(f"--trace={self.trace_file}")
            if self.loader_mode == "backdoor":
                sim_cmd.append(f"--load_elf={self.elf_file}")

            logging.warning(f"SIM_TEST: Starting simulator on port {port}")
            self.sim_proc = subprocess.Popen(
                sim_cmd,
                env=sim_env,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )

            sim_ready = threading.Event()
            ready_line = f"DPI: Server listening on port {port}"

            # Monitor sim stdout for ready signal and UART output (pass/fail)
            self.threads.append(
                threading.Thread(
                    target=self._stream_reader,
                    args=(self.sim_proc.stdout, "SIM", True),
                    kwargs={},
                )
            )
            # Wrap stdout reader to also detect ready
            # Actually, let's use a dedicated ready-detecting reader for stdout
            self.threads.clear()

            def stdout_reader(pipe):
                try:
                    for line in iter(pipe.readline, ""):
                        stripped = line.strip()
                        # Filter out misleading trace-related paths from the simulator,
                        # as they point to sandbox locations that are not useful after
                        # the test finishes.
                        if (
                            "Writing simulation traces to" in stripped
                            or "You can view the simulation traces" in stripped
                            or "gtkwave" in stripped
                        ):
                            continue

                        logging.warning(f"[SIM] {stripped}")
                        if ready_line in stripped:
                            sim_ready.set()
                        if stripped:
                            if self.PASS_PATTERN.search(stripped):
                                self._set_result(True)
                            elif self.FAIL_PATTERN.search(stripped):
                                self._set_result(False)
                finally:
                    pipe.close()

            self.threads.append(
                threading.Thread(target=stdout_reader, args=(self.sim_proc.stdout,))
            )
            self.threads.append(
                threading.Thread(
                    target=self._stream_reader,
                    args=(self.sim_proc.stderr, "SIM_ERR"),
                )
            )
            for t in self.threads:
                t.daemon = True
                t.start()

            # Wait for simulator ready
            if not sim_ready.wait(timeout=120):
                logging.error("SIM_TEST: Timeout waiting for simulator ready.")
                return 1
            logging.warning("SIM_TEST: Simulator ready.")

            # Start tailing uart1.log for PASS/FAIL output.
            # UARTDPI writes UART data to this file (not to simulator stdout).
            # The file is created in the simulator's working directory.
            # Check multiple possible locations for uart1.log
            uart_candidates = [os.path.join(os.getcwd(), "uart1.log")]
            try:
                proc_cwd = os.readlink(f"/proc/{self.sim_proc.pid}/cwd")
                uart_candidates.insert(0, os.path.join(proc_cwd, "uart1.log"))
            except OSError:
                pass
            uart_thread = threading.Thread(
                target=self._tail_uart_log,
                args=(uart_candidates, self.sim_timeout + 300),
                daemon=True,
            )
            uart_thread.start()
            self.threads.append(uart_thread)

            # Load ELF (or just kick off, if segments were backdoor-loaded by
            # the simulator).
            if self.loader_mode == "backdoor":
                logging.warning(
                    f"SIM_TEST: Backdoor-loaded ELF: {self.elf_file}; "
                    "running loader in --csr_only mode."
                )
            else:
                logging.warning(f"SIM_TEST: Loading ELF over SPI: {self.elf_file}")
            loader_cmd = [
                loader_path,
                self.elf_file,
                "--itcm_size_kbytes",
                str(self.itcm_size_kbytes),
                "--dtcm_size_kbytes",
                str(self.dtcm_size_kbytes),
            ]
            if self.loader_mode == "backdoor":
                loader_cmd.append("--csr_only")
            self.loader_proc = subprocess.Popen(
                loader_cmd,
                env=sim_env,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )

            loader_threads = [
                threading.Thread(
                    target=self._stream_reader, args=(self.loader_proc.stdout, "LOADER")
                ),
                threading.Thread(
                    target=self._stream_reader,
                    args=(self.loader_proc.stderr, "LOADER_ERR"),
                ),
            ]
            for t in loader_threads:
                t.daemon = True
                t.start()
            self.threads.extend(loader_threads)

            self.loader_proc.wait(timeout=300)
            if self.loader_proc.returncode != 0:
                logging.error(
                    f"SIM_TEST: Loader failed with exit code {self.loader_proc.returncode}"
                )
                return 1

            logging.warning(
                f"SIM_TEST: ELF loaded. Waiting up to {self.sim_timeout}s for test result..."
            )

            # Wait for pass/fail from UART output
            deadline = time.monotonic() + self.sim_timeout
            while time.monotonic() < deadline:
                with self._result_lock:
                    if self.test_result is not None:
                        break
                # Check if simulator exited
                if self.sim_proc.poll() is not None:
                    break
                time.sleep(0.1)

            # Determine result
            with self._result_lock:
                result = self.test_result

            if self.trace_file:
                logging.warning(
                    f"SIM_TEST: Tracing enabled. Waveform can be found in "
                    f"bazel-testlogs/<target_path>/test.outputs/outputs.zip "
                    f"as {os.path.basename(self.trace_file)}"
                )

            if result is True:
                logging.warning("SIM_TEST: TEST PASSED")
                return 0
            elif result is False:
                logging.warning("SIM_TEST: TEST FAILED")
                return 1
            else:
                logging.warning("SIM_TEST: No pass/fail detected within timeout.")
                return 1

        except (subprocess.TimeoutExpired, RuntimeError) as e:
            logging.error(f"SIM_TEST: Error: {e}")
            return 1
        finally:
            if self.sim_proc and self.sim_proc.poll() is None:
                self.sim_proc.send_signal(signal.SIGINT)
                try:
                    self.sim_proc.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    self.sim_proc.kill()
            if self.loader_proc and self.loader_proc.poll() is None:
                self.loader_proc.kill()
            for t in self.threads:
                t.join(timeout=5)


def main():
    parser = argparse.ArgumentParser(description="CoralNPU SoC simulation test runner.")
    parser.add_argument("elf_file", help="Path to the ELF binary to test.")
    parser.add_argument(
        "--sim_timeout",
        type=int,
        default=30,
        help="Seconds to wait for test result after loading.",
    )
    parser.add_argument(
        "--trace", nargs="?", const="sim_trace.fst", help="Save waveform trace to file."
    )
    parser.add_argument(
        "--highmem", action="store_true", help="Use highmem simulator configuration."
    )
    parser.add_argument(
        "--itcm_size_kbytes", type=int, default=8, help="ITCM size in KBytes."
    )
    parser.add_argument(
        "--dtcm_size_kbytes", type=int, default=32, help="DTCM size in KBytes."
    )
    parser.add_argument(
        "--loader",
        choices=["backdoor", "spi"],
        default="backdoor",
        help="How to deliver the ELF to the SoC. 'backdoor' (default) uses "
             "sram_load_elf via DPI in the simulator and only fires the "
             "kickoff CSR writes over SPI. 'spi' streams the entire ELF over "
             "the spi2tlul bridge (kept for spi2tlul-loader regression "
             "coverage).",
    )
    args = parser.parse_args()

    runner = SimTestRunner(
        args.elf_file,
        args.sim_timeout,
        args.trace,
        args.highmem,
        args.itcm_size_kbytes,
        args.dtcm_size_kbytes,
        args.loader,
    )
    sys.exit(runner.run())


if __name__ == "__main__":
    main()
