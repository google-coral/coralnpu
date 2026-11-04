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

import logging


class BaseTest:

    def __init__(self, name: str, dut):
        self.name = name
        self.dut = dut
        self.log = logging.getLogger(f"cocotb.{name}")

    async def run(self):
        await self.reset_phase()
        self.build_phase()
        self.connect_phase()
        self.start_run_phase()
        await self.main_phase()
        self.check_phase()
        self.report_phase()

    async def reset_phase(self):
        "..."

    def build_phase(self):
        "..."

    def connect_phase(self):
        "..."

    def start_run_phase(self):
        "..."

    async def main_phase(self):
        "..."

    def check_phase(self):
        "..."

    def report_phase(self):
        self.log.info(f"{self.name}: all phases complete")
