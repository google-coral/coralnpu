// Copyright 2026 Google LLC
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

#include <pybind11/numpy.h>
#include <pybind11/pybind11.h>
#include <pybind11/stl.h>

#include <cstdint>
#include <string>

#include "absl/log/log.h"
#include "absl/status/status.h"
#include "sim/coralnpu_simulator.h"

using coralnpu::sim::Architecture;
using coralnpu::sim::CoralNPUSimulator;
using coralnpu::sim::CoralNPUSimulatorOptions;
using coralnpu::sim::CoralNPUV2MemoryRegion;
using coralnpu::sim::MemoryPermission;

namespace py = pybind11;

class CoralNPUV2SimulatorPy {
 public:
  explicit CoralNPUV2SimulatorPy(
      const coralnpu::sim::CoralNPUSimulatorOptions& options);
  ~CoralNPUV2SimulatorPy() = default;

  void LoadProgram(const std::string& elf_file_path,
                   std::optional<uint32_t> entry_point = std::nullopt);
  void Run();
  void Wait();
  void Halt();
  void SetSwBreakpoint(uint64_t address);
  void ClearSwBreakpoint(uint64_t address);
  int Step(const int num_steps);
  uint64_t GetCycleCount();
  uint64_t ReadRegister(const std::string& name);
  void WriteRegister(const std::string& name, uint64_t value);
  py::array_t<uint8_t> ReadMemory(uint64_t address, size_t length);
  void WriteMemory(uint64_t address, py::array_t<uint8_t> input_buffer,
                   size_t length);
  void WriteWord(uint64_t address, uint32_t data);
  void WritePtr(uint64_t address, uint64_t ptr_address);

 private:
  coralnpu::sim::CoralNPUSimulator sim_;
};

void CoralNPUV2SimulatorPy::LoadProgram(const std::string& elf_file_path,
                                        std::optional<uint32_t> entry_point) {
  absl::Status status = sim_.LoadProgram(elf_file_path, entry_point);
  if (!status.ok()) {
    LOG(ERROR) << "LoadProgram failed: " << status;
    return;
  }
}

void CoralNPUV2SimulatorPy::Run() {
  absl::Status status = sim_.Run();
  if (!status.ok()) {
    LOG(ERROR) << "Run failed: " << status;
    return;
  }
}

void CoralNPUV2SimulatorPy::Wait() {
  absl::Status status = sim_.Wait();
  if (!status.ok()) {
    LOG(ERROR) << "Wait failed: " << status;
    return;
  }
}

void CoralNPUV2SimulatorPy::Halt() {
  absl::Status status = sim_.Halt();
  if (!status.ok()) {
    LOG(ERROR) << "Halt failed: " << status;
    return;
  }
}

void CoralNPUV2SimulatorPy::SetSwBreakpoint(uint64_t address) {
  absl::Status status = sim_.SetSwBreakpoint(address);
  if (!status.ok()) {
    LOG(ERROR) << "SetSwBreakpoint failed: " << status;
    return;
  }
}

void CoralNPUV2SimulatorPy::ClearSwBreakpoint(uint64_t address) {
  absl::Status status = sim_.ClearSwBreakpoint(address);
  if (!status.ok()) {
    LOG(ERROR) << "ClearSwBreakpoint failed: " << status;
    return;
  }
}

int CoralNPUV2SimulatorPy::Step(const int num_steps) {
  absl::StatusOr<int> count_status = sim_.Step(num_steps);
  if (!count_status.ok()) {
    LOG(ERROR) << "Step failed: " << count_status;
    return -1;
  }
  return count_status.value();
}

uint64_t CoralNPUV2SimulatorPy::GetCycleCount() {
  uint64_t cycle_count = sim_.GetCycleCount();
  if (cycle_count) {
    return cycle_count;
  }
  return 0;
}

uint64_t CoralNPUV2SimulatorPy::ReadRegister(const std::string& name) {
  absl::StatusOr<uint64_t> word_status = sim_.ReadRegister(name);
  if (!word_status.ok()) {
    LOG(ERROR) << "ReadRegister failed: " << word_status;
  }
  return word_status.value();
}

void CoralNPUV2SimulatorPy::WriteRegister(const std::string& name,
                                          uint64_t value) {
  absl::Status status = sim_.WriteRegister(name, value);
  if (!status.ok()) {
    LOG(ERROR) << "WriteRegister failed: " << status;
    return;
  }
}

void CoralNPUV2SimulatorPy::WriteMemory(uint64_t address,
                                        py::array_t<uint8_t> input_buffer,
                                        size_t length) {
  py::buffer_info info = input_buffer.request();
  const void* input_buffer_ptr = static_cast<const void*>(info.ptr);

  absl::StatusOr<size_t> write_status =
      sim_.WriteMemory(address, input_buffer_ptr, length);
  if (!write_status.ok()) {
    LOG(ERROR) << "Write memory failed: " << write_status;
  }
  if (write_status.value() != length) {
    LOG(ERROR) << "Write memory length assertion error: "
               << write_status.value() << " written out of" << length;
  }
}

void CoralNPUV2SimulatorPy::WriteWord(uint64_t address, uint32_t data) {
  absl::StatusOr<size_t> write_status = sim_.WriteMemory(address, &data, 4);
  if (!write_status.ok()) {
    LOG(ERROR) << "Write memory failed: " << write_status;
  }
  if (write_status.value() != 4) {
    LOG(ERROR) << "Write memory length assertion error: "
               << write_status.value() << " written out of" << 4;
  }
}

void CoralNPUV2SimulatorPy::WritePtr(uint64_t address, uint64_t ptr_address) {
  absl::StatusOr<size_t> write_status =
      sim_.WriteMemory(address, &ptr_address, 8);
  if (!write_status.ok()) {
    LOG(ERROR) << "Write memory failed: " << write_status;
  }
  if (write_status.value() != 8) {
    LOG(ERROR) << "Write memory length assertion error: "
               << write_status.value() << " written out of" << 8;
  }
}

py::array_t<uint8_t> CoralNPUV2SimulatorPy::ReadMemory(uint64_t address,
                                                       size_t length) {
  auto result = py::array_t<uint8_t>(length);
  py::buffer_info info = result.request();
  void* buffer_ptr = info.ptr;

  absl::StatusOr<size_t> read_status =
      sim_.ReadMemory(address, buffer_ptr, length);
  if (!read_status.ok()) {
    LOG(ERROR) << "Read memory failed: " << read_status.status();
  } else if (read_status.value() != length) {
    LOG(ERROR) << "Read memory length assertion error: " << read_status.value()
               << " read out of " << length;
  }
  return result;
}

CoralNPUV2SimulatorPy::CoralNPUV2SimulatorPy(
    const coralnpu::sim::CoralNPUSimulatorOptions& options)
    : sim_(options) {}

PYBIND11_MODULE(coralnpu_v2_sim_pybind, module) {
  module.doc() =
      "This module is created with pybind wrap on coralnpu simulator";

  py::enum_<Architecture>(module, "Architecture")
      .value("kV2", Architecture::kV2)
      .value("kM3", Architecture::kM3)
      .value("kM4", Architecture::kM4)
      .export_values();

  py::enum_<MemoryPermission>(module, "MemoryPermission")
      .value("kNone", MemoryPermission::kNone)
      .value("kRead", MemoryPermission::kRead)
      .value("kWrite", MemoryPermission::kWrite)
      .value("kExecute", MemoryPermission::kExecute)
      .value("kReadWrite", MemoryPermission::kReadWrite)
      .value("kReadExecute", MemoryPermission::kReadExecute)
      .value("kReadWriteExecute", MemoryPermission::kReadWriteExecute)
      .export_values();

  py::class_<CoralNPUV2MemoryRegion>(module, "CoralNPUV2MemoryRegion")
      .def(py::init<>())
      .def_readwrite("start_address", &CoralNPUV2MemoryRegion::start_address)
      .def_readwrite("length", &CoralNPUV2MemoryRegion::length)
      .def_readwrite("permissions", &CoralNPUV2MemoryRegion::permissions);

  py::class_<CoralNPUSimulatorOptions>(module, "CoralNPUSimulatorOptions")
      .def(py::init<>())
      .def_readwrite("architecture", &CoralNPUSimulatorOptions::architecture)
      .def_readwrite("itcm_start_address", &CoralNPUSimulatorOptions::itcm_start_address)
      .def_readwrite("itcm_length", &CoralNPUSimulatorOptions::itcm_length)
      .def_readwrite("initial_misa_value", &CoralNPUSimulatorOptions::initial_misa_value)
      .def_readwrite("memory_regions", &CoralNPUSimulatorOptions::memory_regions)
      .def_readwrite("exit_on_ebreak", &CoralNPUSimulatorOptions::exit_on_ebreak)
      .def_readwrite("semihost_htif", &CoralNPUSimulatorOptions::semihost_htif);

  py::class_<CoralNPUV2SimulatorPy>(module, "CoralNPUSimulatorPy")
      .def(py::init<const CoralNPUSimulatorOptions>())
      .def("LoadProgram", &CoralNPUV2SimulatorPy::LoadProgram,
           py::arg("elf_file_path"), py::arg("entry_point"), "loads elf")
      .def("Run", &CoralNPUV2SimulatorPy::Run, "runs the program")
      .def("Wait", &CoralNPUV2SimulatorPy::Wait,
           "waits for the program to finish")
      .def("Halt", &CoralNPUV2SimulatorPy::Halt, "Halt the simulator")
      .def("SetSwBreakpoint", &CoralNPUV2SimulatorPy::SetSwBreakpoint,
           py::arg("address"), "Set a software breakpoint at address")
      .def("ClearSwBreakpoint", &CoralNPUV2SimulatorPy::ClearSwBreakpoint,
           py::arg("address"), "Clear a software breakpoint at address")
      .def("Step", &CoralNPUV2SimulatorPy::Step, py::arg("num_steps"),
           "Runs a simulator to a specifed number of steps")
      .def("GetCycleCount", &CoralNPUV2SimulatorPy::GetCycleCount,
           "Return number of cycles taken by program to run")
      .def("ReadMemory", &CoralNPUV2SimulatorPy::ReadMemory,
           "Reads memory and stores in the given buffer")
      .def("WriteMemory", &CoralNPUV2SimulatorPy::WriteMemory, "Write memory")
      .def("WriteWord", &CoralNPUV2SimulatorPy::WriteWord, "Write word")
      .def("WritePtr", &CoralNPUV2SimulatorPy::WritePtr, "Write ptr")
      .def("ReadRegister", &CoralNPUV2SimulatorPy::ReadRegister,
           "Read Register and returns the value in it")
      .def("WriteRegister", &CoralNPUV2SimulatorPy::WriteRegister,
           "Read Register and returns the value in it");
}