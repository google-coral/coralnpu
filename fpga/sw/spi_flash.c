// Copyright 2026 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

#include "fpga/sw/spi_flash.h"

#include <stddef.h>

#include "fpga/sw/clk.h"
#include "fpga/sw/dma.h"
#include "fpga/sw/gpio.h"
#include "fpga/sw/spi.h"

#define GPIO_FLASH_RST_BIT (1 << 4)

#define CLINT_BASE 0x02000000u
#define MTIME_LO (*(volatile uint32_t*)(CLINT_BASE + 0xBFF8))
#define MTIME_HI (*(volatile uint32_t*)(CLINT_BASE + 0xBFFC))

static uint32_t flash_base(void) { return spi_get_flash_base_addr(); }

static uint8_t spi_xfer_local(uint8_t tx) { return spi_xfer(flash_base(), tx); }

uint64_t get_mtime(void) {
  uint32_t hi, lo;
  do {
    hi = MTIME_HI;
    lo = MTIME_LO;
  } while (hi != MTIME_HI);
  return ((uint64_t)hi << 32) | lo;
}

void udelay(uint32_t us) {
  uint32_t freq_mhz = clk_get_main_freq_mhz();
  uint64_t start = get_mtime();
  uint64_t ticks = (uint64_t)us * freq_mhz;
  while ((get_mtime() - start) < ticks) {
    __asm__ volatile("nop");
  }
}

void spi_flash_init(void) {
  // Div=20, CPOL=0, CPHA=0, Enable=1
  spi_set_control(flash_base(), SPI_CTRL_DIV(20) | SPI_CTRL_ENABLE);
  // CSMODE=1 (manual CS control) for multi-byte transactions
  spi_set_csmode(flash_base(), 1);
  // CSID[0]=0 → CS deasserted (high) in manual mode
  spi_set_csid(flash_base(), 0);

  // Initialize GPIO 4 as output and deassert flash reset (active low)
  gpio_set_output_enable(gpio_read_output() | GPIO_FLASH_RST_BIT);
  gpio_write(gpio_read_output() | GPIO_FLASH_RST_BIT);
  udelay(100);
}

void spi_flash_hw_reset(void) {
  // Pulse Reset (active low)
  gpio_write(gpio_read_output() & ~GPIO_FLASH_RST_BIT);  // Assert
  udelay(10);
  gpio_write(gpio_read_output() | GPIO_FLASH_RST_BIT);  // Deassert
  udelay(1000);                                         // tRST = 1ms
}

void spi_flash_cs_assert(void) {
  // In manual mode, CSID[0]=1 asserts CS (drives low)
  spi_set_csid(flash_base(), 1);
}

void spi_flash_cs_deassert(void) {
  // Wait until not busy before deasserting
  while (spi_get_status(flash_base()) & 0x1);
  // In manual mode, CSID[0]=0 deasserts CS (drives high)
  spi_set_csid(flash_base(), 0);
  // Small delay for CS deassert timing (tCSH)
  udelay(1);
}

void spi_flash_write_enable(void) {
  spi_flash_cs_assert();
  spi_xfer_local(SPI_FLASH_CMD_WRITE_ENABLE);
  spi_flash_cs_deassert();
}

bool spi_flash_poll_status(uint8_t mask, uint8_t expected, uint8_t* result,
                           uint32_t poll_limit) {
  uint32_t count = 0;
  uint8_t status;
  spi_flash_cs_assert();
  spi_xfer_local(SPI_FLASH_CMD_READ_STATUS);
  while (true) {
    status = spi_xfer_local(0x00);
    if ((status & mask) == expected) {
      break;
    }
    if (poll_limit > 0 && ++count >= poll_limit) {
      break;
    }
  }
  spi_flash_cs_deassert();
  if (result) {
    *result = status;
  }
  return ((status & mask) == expected);
}

void spi_flash_read_id(uint8_t* mfr, uint8_t* id1, uint8_t* id2) {
  spi_flash_cs_assert();
  spi_xfer_local(SPI_FLASH_CMD_READ_ID);
  if (mfr) *mfr = spi_xfer_local(0x00);
  if (id1) *id1 = spi_xfer_local(0x00);
  if (id2) *id2 = spi_xfer_local(0x00);
  spi_flash_cs_deassert();
}

bool spi_flash_sector_erase(uint32_t addr) {
  spi_flash_write_enable();
  spi_flash_cs_assert();
  spi_xfer_local(SPI_FLASH_CMD_SECTOR_ERASE);
  spi_xfer_local((addr >> 16) & 0xFF);
  spi_xfer_local((addr >> 8) & 0xFF);
  spi_xfer_local(addr & 0xFF);
  spi_flash_cs_deassert();
  return spi_flash_poll_status(0x01, 0x00, NULL, 10000000);
}

bool spi_flash_page_program(uint32_t addr, const uint8_t* data, uint32_t len) {
  spi_flash_write_enable();
  spi_flash_cs_assert();
  spi_xfer_local(SPI_FLASH_CMD_PAGE_PROGRAM);
  spi_xfer_local((addr >> 16) & 0xFF);
  spi_xfer_local((addr >> 8) & 0xFF);
  spi_xfer_local(addr & 0xFF);
  for (uint32_t i = 0; i < len; i++) {
    spi_xfer_local(data[i]);
  }
  spi_flash_cs_deassert();
  return spi_flash_poll_status(0x01, 0x00, NULL, 10000000);
}

void spi_flash_read(uint32_t addr, uint8_t* data, uint32_t len) {
  spi_flash_cs_assert();
  spi_xfer_local(SPI_FLASH_CMD_READ);
  spi_xfer_local((addr >> 16) & 0xFF);
  spi_xfer_local((addr >> 8) & 0xFF);
  spi_xfer_local(addr & 0xFF);
  for (uint32_t i = 0; i < len; i++) {
    data[i] = spi_xfer_local(0x00);
  }
  spi_flash_cs_deassert();
}

void spi_flash_read_dma(uint32_t addr, uint8_t* data, uint32_t len) {
  if (len == 0) return;

  uint32_t base = flash_base();
  spi_flash_cs_assert();
  spi_xfer_local(SPI_FLASH_CMD_READ);
  spi_xfer_local((addr >> 16) & 0xFF);
  spi_xfer_local((addr >> 8) & 0xFF);
  spi_xfer_local(addr & 0xFF);

  // Enable Half-Duplex RX mode via RMW
  uint32_t ctrl = spi_get_control(base);
  spi_set_control(base, ctrl | SPI_CTRL_HDRX);

  // Use a stack-based descriptor to avoid initialization/relocation issues in
  // ROM.
  struct dma_descriptor desc __attribute__((aligned(32)));
  desc.src_addr = base + SPI_REG_RXDATA;
  desc.dst_addr = (uint32_t)(uintptr_t)data;
  desc.len_flags = dma_make_len_flags(len, 0, 1, 0, 0);
  desc.next_desc = 0;

  dma_start((uint32_t)(uintptr_t)&desc);
  dma_wait_done();

  // Restore control register
  spi_set_control(base, ctrl);
  spi_flash_cs_deassert();
}

void spi_flash_read_sfdp(uint32_t addr, uint8_t* data, uint32_t len) {
  spi_flash_cs_assert();
  spi_xfer_local(SPI_FLASH_CMD_READ_SFDP);
  spi_xfer_local((addr >> 16) & 0xFF);
  spi_xfer_local((addr >> 8) & 0xFF);
  spi_xfer_local(addr & 0xFF);
  spi_xfer_local(0x00);  // Dummy byte
  for (uint32_t i = 0; i < len; i++) {
    data[i] = spi_xfer_local(0x00);
  }
  spi_flash_cs_deassert();
}

bool spi_flash_discover(struct spi_flash_info* info) {
  if (!info) {
    return false;
  }

  // 1. Read JEDEC ID (optional validation, now relaxed)
  spi_flash_read_id(&info->mfr_id, &info->device_id[0], &info->device_id[1]);

  // 2. Read SFDP Header
  uint8_t header[16];
  spi_flash_read_sfdp(0x00, header, 16);
  if (header[0] != 'S' || header[1] != 'F' || header[2] != 'D' ||
      header[3] != 'P') {
    return false;
  }

  // Number of parameter headers is in header[6] (0-based)
  int num_headers = header[6] + 1;
  uint32_t table_ptr = 0;
  uint32_t table_len = 0;

  // 3. Find JEDEC Basic Flash Parameter Table (ID 0x00)
  // We want the longest one available (usually Rev B/16 Dwords).
  for (int i = 0; i < num_headers; i++) {
    uint8_t phead[8];
    spi_flash_read_sfdp(8 + i * 8, phead, 8);
    if (phead[0] == 0x00) {  // JEDEC ID
      uint32_t ptr = phead[4] | (phead[5] << 8) | (phead[6] << 16);
      uint32_t len = phead[3] * 4;
      if (len > table_len) {
        table_ptr = ptr;
        table_len = len;
      }
    }
  }

  if (table_ptr == 0 || table_len < 36) {
    return false;
  }

  // 4. Read Basic Flash Parameter Table
  uint8_t table[64];
  if (table_len > 64) {
    table_len = 64;
  }
  spi_flash_read_sfdp(table_ptr, table, table_len);

  // Dword 2 contains density: bits 0-30 = density - 1.
  uint32_t density_bits = table[4] | (table[5] << 8) | (table[6] << 16) |
                          ((uint32_t)table[7] << 24);

  if (density_bits & 0x80000000) {
    uint32_t n = density_bits & 0x7FFFFFFF;
    info->capacity_bytes = (uint32_t)(1ULL << (n - 3));
  } else {
    info->capacity_bytes = (density_bits + 1) / 8;
  }

  // Dword 9 contains Erase Type 3 (256KB for S25FL512S)
  // Byte 0: size 2^N, Byte 1: opcode
  if (table_len >= 34 && table[33] == 0xD8) {
    info->sector_size_bytes = (1U << table[32]);
  } else {
    // Fallback
    info->sector_size_bytes = 256 * 1024;
  }

  // Dword 11 contains Page Size: bits 7:4 = N, page size = 2^N
  // (JESD216B offset 40)
  if (table_len >= 41) {
    info->page_size_bytes = (1U << ((table[40] >> 4) & 0x0F));
  } else {
    info->page_size_bytes = 256;  // Default
  }

  return true;
}
