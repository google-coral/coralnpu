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

#include <fcntl.h>
#include <ftdi.h>
#include <gelf.h>
#include <libelf.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <iomanip>
#include <iostream>
#include <memory>
#include <vector>

#include "absl/flags/flag.h"
#include "absl/flags/parse.h"
#include "absl/flags/usage.h"
#include "sw/utils/nexus_loader/spi_master.h"

ABSL_FLAG(std::string, serial, "", "FTDI device serial number");
ABSL_FLAG(std::string, load_elf, "", "ELF file to load");
ABSL_FLAG(bool, verify, false, "Verify memory after loading");
ABSL_FLAG(bool, highmem, false, "Use high memory CSR base (0x200000)");
ABSL_FLAG(bool, lowmem, false, "Use low memory CSR base (0x30000)");
ABSL_FLAG(uint32_t, read_line, 0xFFFFFFFF,
          "Address to read a single 128-bit line");
ABSL_FLAG(uint32_t, read_lines_addr, 0xFFFFFFFF,
          "Base address to read multiple lines");
ABSL_FLAG(uint32_t, read_lines_count, 1, "Number of 128-bit lines to read");
ABSL_FLAG(bool, reset, false, "Reset the target device");
ABSL_FLAG(bool, soft_reset, false, "Soft reset the target device via SPI (non-destructive)");
ABSL_FLAG(std::string, load_data, "", "Binary data file to load");
ABSL_FLAG(uint32_t, load_data_addr, 0, "Address to load binary data");
ABSL_FLAG(uint32_t, read_data_addr, 0xFFFFFFFF,
          "Address to read binary data from");
ABSL_FLAG(uint32_t, read_data_size, 0, "Size of binary data to read");
ABSL_FLAG(uint32_t, write_word_addr, 0xFFFFFFFF,
          "Address to write a 32-bit word");
ABSL_FLAG(uint32_t, write_word_val, 0, "Value to write to the word address");
ABSL_FLAG(uint32_t, read_word_addr, 0xFFFFFFFF,
          "Address to read a 32-bit word");
ABSL_FLAG(bool, start_core, false, "Start the core after loading");
ABSL_FLAG(uint32_t, csr_base, 0x30000, "CSR base address for core control");
ABSL_FLAG(uint32_t, set_entry_point, 0xFFFFFFFF, "Entry point address to set");
ABSL_FLAG(double, poll_halt, 0.0, "Timeout in seconds to poll for core halt");
ABSL_FLAG(uint32_t, poll_status_addr, 0xFFFFFFFF,
          "Address of the status message buffer to poll");
ABSL_FLAG(uint32_t, poll_status_size, 0, "Size of the status message buffer");

constexpr uint16_t kFtdiVid = 0x0403;
constexpr uint16_t kFtdiPid = 0x6011;

class RealFtdi : public FtdiInterface {
  struct ftdi_context* ftdi_;

 public:
  RealFtdi(struct ftdi_context* ftdi) : ftdi_(ftdi) {}

  int write_data(const uint8_t* buf, int size) override {
    return ftdi_write_data(ftdi_, buf, size);
  }

  int read_data(uint8_t* buf, int size) override {
    return ftdi_read_data(ftdi_, buf, size);
  }

#ifdef SIO_TCIFLUSH
  int purge_buffers() override { return ftdi_tcioflush(ftdi_); }
#else
  int purge_buffers() override { return ftdi_usb_purge_buffers(ftdi_); }
#endif
};

struct ElfDeleter {
  void operator()(Elf* e) {
    if (e) elf_end(e);
  }
};

struct FdDeleter {
  void operator()(int* fd) {
    if (fd && *fd >= 0) close(*fd);
  }
};

ssize_t ReadFully(int fd, void* buf, size_t count) {
  size_t total = 0;
  char* p = static_cast<char*>(buf);
  while (total < count) {
    ssize_t n = read(fd, p + total, count - total);
    if (n < 0) {
      if (errno == EINTR) continue;
      return -1;
    }
    if (n == 0) return total;
    total += n;
  }
  return total;
}

void SuggestResetOnError() {
  fprintf(stderr, "\n[HINT] If the transaction timed out, the FPGA bus might be hung (possibly due to a failed Power-On Reset from FTDI backpowering).\n");
  fprintf(stderr, "[HINT] Try running the command again with the '--reset' flag to reload the bitstream.\n\n");
}

bool load_elf(SpiMaster& spi, const char* filename, uint32_t csr_base,
              bool verify) {
  if (elf_version(EV_CURRENT) == EV_NONE) return false;
  int fd_val = open(filename, O_RDONLY, 0);
  if (fd_val < 0) {
    perror("Failed to open ELF file");
    return false;
  }
  std::unique_ptr<int, FdDeleter> fd(&fd_val);

  std::unique_ptr<Elf, ElfDeleter> e(elf_begin(fd_val, ELF_C_READ, NULL));
  if (!e) {
    fprintf(stderr, "elf_begin failed: %s\n", elf_errmsg(-1));
    return false;
  }
  GElf_Ehdr ehdr;
  if (!gelf_getehdr(e.get(), &ehdr)) {
    fprintf(stderr, "gelf_getehdr failed: %s\n", elf_errmsg(-1));
    return false;
  }
  size_t phnum;
  if (elf_getphdrnum(e.get(), &phnum) != 0) {
    fprintf(stderr, "elf_getphdrnum failed: %s\n", elf_errmsg(-1));
    return false;
  }

  size_t total_bytes = 0;
  auto start_time = std::chrono::steady_clock::now();

  for (size_t i = 0; i < phnum; i++) {
    GElf_Phdr phdr;
    if (!gelf_getphdr(e.get(), i, &phdr)) {
      fprintf(stderr, "gelf_getphdr failed: %s\n", elf_errmsg(-1));
      return false;
    }
    if (phdr.p_type != PT_LOAD) continue;
    uint32_t paddr = static_cast<uint32_t>(phdr.p_vaddr);
    size_t filesz = phdr.p_filesz;
    if (filesz == 0) continue;

    fprintf(stderr, "Loading 0x%08x (%zu bytes)...", paddr, filesz);
    fflush(stderr);
    std::vector<uint8_t> buf(filesz, 0);
    lseek(fd_val, static_cast<off_t>(phdr.p_offset), SEEK_SET);
    if (ReadFully(fd_val, buf.data(), filesz) != static_cast<ssize_t>(filesz)) {
      fprintf(stderr, " Failed to read ELF segment\n");
      return false;
    }

    spi.v2_write_data(paddr, buf.data(), filesz);
    total_bytes += filesz;
    fprintf(stderr, " Done.\n");

    if (verify) {
      fprintf(stderr, " Verifying...");
      fflush(stderr);
      for (size_t off = 0; off < filesz; off += 1024) {
        size_t chunk = (filesz - off > 1024) ? 1024 : filesz - off;
        uint8_t vbuf[1024];
        if (!spi.v2_read_data(paddr + static_cast<uint32_t>(off), chunk,
                              vbuf)) {
          fprintf(stderr, " TIMEOUT at 0x%08x\n",
                  paddr + static_cast<uint32_t>(off));
          SuggestResetOnError();
          return false;
        }
        if (memcmp(vbuf, buf.data() + off, chunk) != 0) {
          fprintf(stderr, " FAIL at 0x%08x\n",
                  paddr + static_cast<uint32_t>(off));
          return false;
        }
      }
      fprintf(stderr, " OK\n");
    }
  }
  auto end_time = std::chrono::steady_clock::now();
  double duration =
      std::chrono::duration<double>(end_time - start_time).count();
  fprintf(stderr, "Transfer complete: %zu bytes in %.2fs (%.2f KB/s)\n",
          total_bytes, duration, (total_bytes / 1024.0) / duration);

  return true;
}

struct FtdiDeleter {
  void operator()(struct ftdi_context* f) {
    if (f) {
      ftdi_usb_close(f);
      ftdi_free(f);
    }
  }
};

void HandleReset(struct ftdi_context* ftdi, SpiMaster& spi) {
  fprintf(stderr, "Resetting device...\n");
  ftdi_set_bitmode(ftdi, 0, BITMODE_RESET);
  ftdi_set_bitmode(ftdi, 0x8b, BITMODE_MPSSE);  // ADBUS7+kDirMask
  spi.device_reset();
  ftdi_set_bitmode(ftdi, 0, BITMODE_RESET);
  ftdi_set_bitmode(ftdi, kDirMask, BITMODE_MPSSE);
}

void HandleSoftReset(SpiMaster& spi) {
  fprintf(stderr, "Soft resetting device via SPI...\n");
  spi.soft_reset();
}

bool HandleLoadElf(SpiMaster& spi, uint32_t csr_base) {
  std::string elf_file = absl::GetFlag(FLAGS_load_elf);
  if (!load_elf(spi, elf_file.c_str(), csr_base, absl::GetFlag(FLAGS_verify))) {
    return false;
  }
  return true;
}

bool HandleLoadData(SpiMaster& spi) {
  std::string load_data_file = absl::GetFlag(FLAGS_load_data);
  int fd_val = open(load_data_file.c_str(), O_RDONLY);
  if (fd_val < 0) {
    perror("Failed to open data file");
    return false;
  }
  std::unique_ptr<int, FdDeleter> fd(&fd_val);

  struct stat st;
  if (fstat(fd_val, &st) < 0) {
    perror("fstat failed");
    return false;
  }
  size_t sz = static_cast<size_t>(st.st_size);
  std::vector<uint8_t> buf(sz);
  if (ReadFully(fd_val, buf.data(), sz) != static_cast<ssize_t>(sz)) {
    fprintf(stderr, "Failed to read data file\n");
    return false;
  }
  uint32_t load_data_addr = absl::GetFlag(FLAGS_load_data_addr);
  fprintf(stderr, "Loading %zu bytes to 0x%08x\n", sz, load_data_addr);
  spi.v2_write_data(load_data_addr, buf.data(), sz);
  return true;
}

bool HandleReadData(SpiMaster& spi) {
  uint32_t read_data_addr = absl::GetFlag(FLAGS_read_data_addr);
  uint32_t read_data_size = absl::GetFlag(FLAGS_read_data_size);
  if (read_data_size == 0) return true;
  std::vector<uint8_t> buf(read_data_size);
  if (spi.v2_read_data(read_data_addr, read_data_size, buf.data())) {
    fwrite(buf.data(), 1, read_data_size, stdout);
    return true;
  } else {
    fprintf(stderr, "Failed to read data at 0x%08x\n", read_data_addr);
    return false;
  }
}

void HandleStartCore(SpiMaster& spi, uint32_t csr_base) {
  uint32_t entry_point = absl::GetFlag(FLAGS_set_entry_point);
  if (entry_point != 0xFFFFFFFF) {
    fprintf(stderr, "Setting entry point to 0x%08x\n", entry_point);
    spi.write_word(csr_base + 4, entry_point);
  }

  if (absl::GetFlag(FLAGS_start_core)) {
    fprintf(stderr, "Starting core...\n");
    spi.write_word(csr_base, 1);
    usleep(1000);
    spi.write_word(csr_base, 0);
  }
}

bool HandlePollHalt(SpiMaster& spi, uint32_t csr_base) {
  double poll_halt_timeout = absl::GetFlag(FLAGS_poll_halt);
  uint32_t status_addr = absl::GetFlag(FLAGS_poll_status_addr);
  uint32_t status_size = absl::GetFlag(FLAGS_poll_status_size);

  fprintf(stderr, "Polling for halt (timeout: %.1fs)...\n", poll_halt_timeout);
  auto start = std::chrono::steady_clock::now();
  bool halted = false;
  std::string last_status;
  int consecutive_failures = 0;
  constexpr int kMaxConsecutiveFailures = 10;

  while (!halted) {
    auto now = std::chrono::steady_clock::now();
    if (std::chrono::duration<double>(now - start).count() > poll_halt_timeout)
      break;

    uint32_t val;
    if (spi.v2_read_data(csr_base + 8, 4, reinterpret_cast<uint8_t*>(&val))) {
      consecutive_failures = 0;
      if (val == 1) {
        fprintf(stderr, "Core halted.\n");
        halted = true;
      }
    } else {
      consecutive_failures++;
      if (consecutive_failures >= kMaxConsecutiveFailures) {
        fprintf(stderr, "Too many consecutive SPI read failures. Aborting.\n");
        return false;
      }
    }

    if (status_addr != 0xFFFFFFFF && status_size > 0) {
      std::vector<uint8_t> status_buf(status_size);
      if (spi.v2_read_data(status_addr, status_size, status_buf.data())) {
        std::string current_status(reinterpret_cast<char*>(status_buf.data()),
                                   status_size);
        // Truncate at null terminator
        size_t null_pos = current_status.find('\0');
        if (null_pos != std::string::npos) {
          current_status.resize(null_pos);
        }

        if (!current_status.empty() && current_status != last_status) {
          fprintf(stderr, "Status: %s\n", current_status.c_str());
          last_status = current_status;
          // Zero out the first byte of the status message
          uint8_t zero = 0;
          spi.v2_write_data(status_addr, &zero, 1);
        }
      }
    }

    if (halted) break;
    usleep(10000);
  }

  if (!halted) {
    fprintf(stderr, "Timed out waiting for core to halt.\n");
    return false;
  }
  return true;
}

int main(int argc, char** argv) {
  absl::SetProgramUsageMessage("FTDI Nexus Loader");
  absl::ParseCommandLine(argc, argv);

  std::string serial = absl::GetFlag(FLAGS_serial);
  if (serial.empty()) {
    fprintf(stderr, "Error: --serial is required\n");
    return 1;
  }

  uint32_t csr_base = absl::GetFlag(FLAGS_csr_base);
  if (absl::GetFlag(FLAGS_highmem)) csr_base = 0x200000;
  if (absl::GetFlag(FLAGS_lowmem)) csr_base = 0x30000;

  std::unique_ptr<struct ftdi_context, FtdiDeleter> ftdi_ctx(ftdi_new());
  ftdi_set_interface(ftdi_ctx.get(), INTERFACE_A);
  if (ftdi_usb_open_desc(ftdi_ctx.get(), kFtdiVid, kFtdiPid, NULL,
                         serial.c_str()) < 0) {
    fprintf(stderr, "Failed to open FTDI device\n");
    return 1;
  }

  // Always reset FTDI bitmode to clear any hung state.
  // Use kDirMask (0x0b) so ADBUS7 (PROG_B) remains an input and doesn't wipe the FPGA.
  ftdi_set_bitmode(ftdi_ctx.get(), 0, BITMODE_RESET);
  ftdi_set_bitmode(ftdi_ctx.get(), kDirMask, BITMODE_MPSSE);

  RealFtdi rftdi(ftdi_ctx.get());
  SpiMaster spi(&rftdi);

  if (absl::GetFlag(FLAGS_reset)) {
    HandleReset(ftdi_ctx.get(), spi);
    usleep(3000000);  // 3s delay for FPGA configuration and DDR calibration
  }

  if (absl::GetFlag(FLAGS_soft_reset)) {
    HandleSoftReset(spi);
  }

  std::vector<uint8_t> init_cmd = {MPSSE_DISABLE_CLK_DIV_5,
                                   MPSSE_ENABLE_3PHASE_CLK,
                                   MPSSE_SET_TCK_DIVISOR,
                                   0x00,
                                   0x00,
                                   MPSSE_DISABLE_3PHASE_CLK,
                                   MPSSE_SET_DATA_BITS_LOW,
                                   kCsHigh,
                                   kDirMask};
  rftdi.write_data(init_cmd.data(), init_cmd.size());

  // Command Execution Order:
  // 1. Reset (already done)
  // 2. Load ELF OR Load Data
  // 3. Write Word
  // 4. Start Core (includes entry point)
  // 5. Poll Halt
  // 6. Read Word / Read Data / Read Line(s)

  if (!absl::GetFlag(FLAGS_load_elf).empty()) {
    if (!HandleLoadElf(spi, csr_base)) return 1;
  }

  if (!absl::GetFlag(FLAGS_load_data).empty()) {
    if (!HandleLoadData(spi)) return 1;
  }

  if (absl::GetFlag(FLAGS_write_word_addr) != 0xFFFFFFFF) {
    spi.write_word(absl::GetFlag(FLAGS_write_word_addr),
                   absl::GetFlag(FLAGS_write_word_val));
  }

  if (absl::GetFlag(FLAGS_start_core) ||
      absl::GetFlag(FLAGS_set_entry_point) != 0xFFFFFFFF) {
    HandleStartCore(spi, csr_base);
  }

  if (absl::GetFlag(FLAGS_poll_halt) > 0.0) {
    if (!HandlePollHalt(spi, csr_base)) return 1;
  }

  if (absl::GetFlag(FLAGS_read_word_addr) != 0xFFFFFFFF) {
    uint32_t addr = absl::GetFlag(FLAGS_read_word_addr);
    uint32_t val;
    if (spi.v2_read_data(addr, 4, reinterpret_cast<uint8_t*>(&val))) {
      printf("DATA_WORD: 0x%08x\n", val);
    } else {
      fprintf(stderr, "Failed to read word at 0x%08x\n", addr);
      SuggestResetOnError();
      return 1;
    }
  }

  if (absl::GetFlag(FLAGS_read_data_addr) != 0xFFFFFFFF) {
    if (!HandleReadData(spi)) return 1;
  }

  if (absl::GetFlag(FLAGS_read_line) != 0xFFFFFFFF) {
    uint32_t addr = absl::GetFlag(FLAGS_read_line);
    uint8_t line[16];
    if (spi.v2_read_lines(addr, 1, line)) {
      printf("0x%08x: 0x", addr);
      for (int i = 15; i >= 0; i--) printf("%02x", line[i]);
      printf("\n");
    } else {
      fprintf(stderr, "Failed to read line at 0x%08x\n", addr);
      SuggestResetOnError();
      return 1;
    }
  }

  if (absl::GetFlag(FLAGS_read_lines_addr) != 0xFFFFFFFF) {
    uint32_t addr = absl::GetFlag(FLAGS_read_lines_addr);
    uint32_t count = absl::GetFlag(FLAGS_read_lines_count);
    std::vector<uint8_t> lines(count * 16);
    if (spi.v2_read_lines(addr, count, lines.data())) {
      for (uint32_t c = 0; c < count; c++) {
        printf("0x%08x: 0x", addr + c * 16);
        for (int i = 15; i >= 0; i--) printf("%02x", lines[c * 16 + i]);
        printf("\n");
      }
    } else {
      fprintf(stderr, "Failed to read %u lines at 0x%08x\n", count, addr);
      SuggestResetOnError();
      return 1;
    }
  }

  return 0;
}