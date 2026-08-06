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
import time
import os
import subprocess
import tempfile
import logging
import re

try:
    from bazel_tools.tools.python.runfiles import runfiles
except ImportError:
    runfiles = None
from elftools.elf.elffile import ELFFile

logger = logging.getLogger(__name__)


class FtdiSpiMaster:
    """A class to manage SPI communication using the C++ nexus_loader utility."""

    def __init__(self, usb_serial, ftdi_port=1, csr_base_addr=0x30000):
        self.usb_serial = usb_serial
        self.ftdi_port = ftdi_port
        self.csr_base_addr = csr_base_addr
        self._recovering = False

        self.nexus_loader_bin = None
        if runfiles:
            r = runfiles.Create()
            # Find nexus_loader binary
            self.nexus_loader_bin = r.Rlocation(
                "coralnpu_hw/sw/utils/nexus_loader/nexus_loader"
            )

        if not self.nexus_loader_bin:
            # Fallback if not running in bazel run environment
            # Use absolute path relative to this script
            script_dir = os.path.dirname(os.path.abspath(__file__))
            project_root = os.path.abspath(os.path.join(script_dir, ".."))
            self.nexus_loader_bin = os.path.join(
                project_root, "bazel-bin/sw/utils/nexus_loader/nexus_loader"
            )
            if not os.path.exists(self.nexus_loader_bin):
                self.nexus_loader_bin = os.path.join(
                    project_root, "sw/utils/nexus_loader/nexus_loader"
                )

        if not os.path.exists(self.nexus_loader_bin):
            raise FileNotFoundError(
                f"Could not find nexus_loader binary at {self.nexus_loader_bin}. "
                "Please build it first: bazel build //sw/utils/nexus_loader"
            )

        logger.info(
            f"Initialized FtdiSpiMaster wrapper using {self.nexus_loader_bin}"
        )

    def _run_cmd(self, args, capture=False, timeout=10.0):
        """Runs the nexus_loader binary with the given args.

        Args:
            args: List of command line arguments.
            capture: Whether to capture stdout.
            timeout: Timeout in seconds.

        Returns:
            The output of the command if capture is True.

        Raises:
            subprocess.CalledProcessError: If the command fails.
            subprocess.TimeoutExpired: If the command times out.
        """
        cmd = [self.nexus_loader_bin, "--serial", self.usb_serial]
        if self.csr_base_addr == 0x200000:
            cmd.append("--highmem")
        cmd += args
        # Add 1.0s buffer to the subprocess timeout to let the C++ binary exit gracefully first.
        try:
            if capture:
                res = subprocess.run(
                    cmd,
                    stdout=subprocess.PIPE,
                    check=True,
                    timeout=timeout + 1.0
                )
                return res.stdout
            else:
                subprocess.run(cmd, check=True, timeout=timeout + 1.0)
        except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as e:
            if "--reset" not in args and not self._recovering:
                logger.warning(
                    "Command failed. Attempting FPGA self-healing recovery..."
                )
                if self.recover_fpga():
                    logger.info("Recovery succeeded. Retrying command...")
                    if capture:
                        return subprocess.run(
                            cmd,
                            stdout=subprocess.PIPE,
                            check=True,
                            timeout=timeout + 1.0
                        ).stdout
                    else:
                        subprocess.run(cmd, check=True, timeout=timeout + 1.0)
                        return
            raise e

    def recover_fpga(self):
        """Attempts to recover the FPGA by resetting FTDI and reloading bitstream."""
        self._recovering = True
        try:
            # 1. Derive SOM host
            match = re.search(r"Nexus-FTDI-(\d+)", self.usb_serial)
            if not match:
                logger.error(
                    f"Cannot derive SOM host from serial {self.usb_serial}"
                )
                return False
            nexus_id = match.group(1)
            som_host = f"nexus{nexus_id}.mtv.corp.google.com"

            # 2. Try soft reset first (non-destructive)
            logger.info("Attempting non-destructive soft reset via SPI...")
            try:
                subprocess.run(
                    [
                        self.nexus_loader_bin, "--serial", self.usb_serial,
                        "--soft_reset"
                    ],
                    check=True,
                    timeout=5.0,
                )
                if self._is_responsive():
                    logger.info("Soft reset succeeded. FPGA is responsive.")
                    return True
                logger.warning(
                    "Soft reset completed but FPGA is still unresponsive."
                )
            except subprocess.SubprocessError as e:
                logger.warning(f"Soft reset command failed: {e}")

            # 3. Fallback to destructive hard reset (toggles PROG_B, wipes FPGA)
            logger.info("Falling back to destructive hard reset...")
            subprocess.run(
                [
                    self.nexus_loader_bin, "--serial", self.usb_serial,
                    "--reset"
                ],
                check=True,
                timeout=15.0,
            )

            # 3. Load bitstream via SSH
            bitstream = "chip_nexus.bin"
            logger.info(
                f"Reloading bitstream {bitstream} on {som_host} via zturn..."
            )
            ssh_cmd = [
                "ssh",
                "-o",
                "StrictHostKeyChecking=no",
                f"root@{som_host}",
                f"cd /mnt/mmcp1 && ./zturn -d a {bitstream}",
            ]
            res = subprocess.run(
                ssh_cmd, capture_output=True, text=True, timeout=30.0
            )
            if res.returncode != 1:
                logger.error(
                    f"zturn failed with exit code {res.returncode}. Output: {res.stdout}\n{res.stderr}"
                )
                return False

            logger.info(
                "FPGA reloaded successfully. Waiting for DDR calibration..."
            )
            time.sleep(2.0)  # Wait for DDR calibration
            return True
        except Exception as e:
            logger.error(f"FPGA recovery failed: {e}")
            return False
        finally:
            self._recovering = False

    def close(self):
        pass

    def device_reset(self):
        logger.info("Resetting device...")
        self._run_cmd(["--reset"])

    def soft_reset(self):
        logger.info("Soft resetting device via SPI...")
        self._run_cmd(["--soft_reset"])

    def _is_responsive(self) -> bool:
        try:
            # Try to read word at 0x0 (ITCM). Use a short timeout.
            # We bypass _run_cmd to avoid recursion.
            subprocess.run(
                [
                    self.nexus_loader_bin, "--serial", self.usb_serial,
                    "--read_word_addr", "0x0"
                ],
                check=True,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=2.0,
            )
            return True
        except subprocess.SubprocessError:
            return False

    def idle_clocking(self, cycles):
        pass

    def write_word(self, address, data):
        self._run_cmd([
            "--write_word_addr",
            hex(address), "--write_word_val",
            hex(data)
        ])

    def read_word(self, address):
        out = self._run_cmd(["--read_word_addr", hex(address)], capture=True)
        # Handle potential empty output or extra logs
        lines = out.decode().strip().splitlines()
        for line in lines:
            if line.startswith("DATA_WORD: "):
                try:
                    return int(line.split(": ")[1], 16)
                except (ValueError, IndexError):
                    continue
        raise ValueError(f"Could not find DATA_WORD in output: {out}")

    def load_file(self, file_path, address, timeout=None):
        cmd = ["--load_data", file_path, "--load_data_addr", hex(address)]
        if timeout is not None:
            self._run_cmd(cmd, timeout=timeout)
        else:
            self._run_cmd(cmd)

    def load_data(self, data, address, timeout=None):
        temp_file = tempfile.NamedTemporaryFile(delete=False)
        try:
            temp_file.write(data)
            temp_file.close()
            self.load_file(temp_file.name, address, timeout=timeout)
        finally:
            if os.path.exists(temp_file.name):
                os.remove(temp_file.name)

    def load_elf(
        self,
        elf_file,
        start_core=True,
        verify=False,
        poll_halt=None,
        status_addr=None,
        status_size=None,
    ):
        logger.info(f"load_elf elf_file={elf_file} verify={verify}")

        # We manually parse entry point here since C++ auto-start is removed
        with open(elf_file, "rb") as f:
            elf_reader = ELFFile(f)
            entry_point = elf_reader.header["e_entry"]

        args = ["--load_elf", elf_file]
        if verify:
            args.append("--verify")

        if start_core:
            args += ["--set_entry_point", hex(entry_point), "--start_core"]

        if poll_halt is not None:
            args += ["--poll_halt", str(poll_halt)]
            if status_addr is not None:
                args += ["--poll_status_addr", hex(status_addr)]
            if status_size is not None:
                args += ["--poll_status_size", str(status_size)]

        self._run_cmd(args, timeout=300.0)

    def set_entry_point(self, entry_point):
        logger.info(f"Setting entry point to 0x{entry_point:x}")
        self._run_cmd([
            "--csr_base",
            hex(self.csr_base_addr),
            "--set_entry_point",
            hex(entry_point),
        ])

    def start_core(self):
        logger.info("Starting core...")
        self._run_cmd(["--start_core", "--csr_base", hex(self.csr_base_addr)])

    def poll_for_halt(self, timeout=10.0, status_addr=None, status_size=None):
        logger.info("Polling for halt...")
        args = [
            "--poll_halt",
            str(timeout), "--csr_base",
            hex(self.csr_base_addr)
        ]
        if status_addr is not None:
            args += ["--poll_status_addr", hex(status_addr)]
        if status_size is not None:
            args += ["--poll_status_size", str(status_size)]

        try:
            self._run_cmd(args, timeout=timeout + 1.0)
            return True
        except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
            return False

    def read_data(self, address, size, verbose=True, timeout=None):
        if size == 0:
            return bytearray()
        # SPI read throughput is ~500 kB/s (500,000 B/s). Base overhead of 10s + 2.0x safety factor.
        to = timeout if timeout is not None else (
            10.0 + (size / 500_000.0) * 2.0
        )
        out = self._run_cmd(
            ["--read_data_addr",
             hex(address), "--read_data_size",
             str(size)],
            capture=True,
            timeout=to,
        )
        return bytearray(out)
