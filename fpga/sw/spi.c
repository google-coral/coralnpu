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

#include "fpga/sw/spi.h"

#include <stdint.h>

#include "fpga/sw/clk.h"

#define REG32(addr) (*(volatile uint32_t*)(uintptr_t)(addr))

uint32_t spi_get_master_base_addr(void) { return SPI_MASTER_BASE; }
uint32_t spi_get_flash_base_addr(void) { return SPI_FLASH_BASE; }

void spi_init(uint32_t base_addr, uint32_t target_mhz, uint32_t cpol,
              uint32_t cpha) {
  uint32_t spim_freq_mhz = clk_get_spim_freq_mhz();
  uint32_t div = (spim_freq_mhz / (2 * target_mhz)) - 1;
  if (spim_freq_mhz < 2 * target_mhz) div = 0;
  uint32_t ctrl = SPI_CTRL_ENABLE | SPI_CTRL_DIV(div);
  if (cpol) ctrl |= SPI_CTRL_CPOL;
  if (cpha) ctrl |= SPI_CTRL_CPHA;
  spi_set_control(base_addr, ctrl);
}

void spi_set_control(uint32_t base_addr, uint32_t ctrl) {
  REG32(base_addr + SPI_REG_CONTROL) = ctrl;
}

uint32_t spi_get_control(uint32_t base_addr) {
  return REG32(base_addr + SPI_REG_CONTROL);
}

void spi_set_csid(uint32_t base_addr, uint32_t csid) {
  REG32(base_addr + SPI_REG_CSID) = csid;
}

void spi_set_csmode(uint32_t base_addr, uint32_t csmode) {
  REG32(base_addr + SPI_REG_CSMODE) = csmode;
}

uint32_t spi_get_status(uint32_t base_addr) {
  return REG32(base_addr + SPI_REG_STATUS);
}

void spi_write_txdata(uint32_t base_addr, uint8_t data) {
  REG32(base_addr + SPI_REG_TXDATA) = data;
}

uint8_t spi_read_rxdata(uint32_t base_addr) {
  return (uint8_t)(REG32(base_addr + SPI_REG_RXDATA) & 0xFF);
}

uint8_t spi_xfer(uint32_t base_addr, uint8_t tx) {
  // Wait until TX FIFO is not full
  while (spi_get_status(base_addr) & 0x4);
  spi_write_txdata(base_addr, tx);
  // Wait until not busy
  while (spi_get_status(base_addr) & 0x1);
  return spi_read_rxdata(base_addr);
}
