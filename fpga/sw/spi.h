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

#ifndef FPGA_SW_SPI_H_
#define FPGA_SW_SPI_H_

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// SPI register offsets
#define SPI_REG_STATUS 0x00
#define SPI_REG_CONTROL 0x04
#define SPI_REG_TXDATA 0x08
#define SPI_REG_RXDATA 0x0c
#define SPI_REG_CSID 0x10
#define SPI_REG_CSMODE 0x14

#define SPI_MASTER_BASE 0x40020000
#define SPI_FLASH_BASE 0x40070000

// SPI CONTROL bits
#define SPI_CTRL_ENABLE (1 << 0)
#define SPI_CTRL_CPOL (1 << 1)
#define SPI_CTRL_CPHA (1 << 2)
#define SPI_CTRL_HDRX (1 << 3)
#define SPI_CTRL_HDTX (1 << 4)
#define SPI_CTRL_DIV(d) ((d) << 8)

uint32_t spi_get_master_base_addr(void);
uint32_t spi_get_flash_base_addr(void);

void spi_init(uint32_t base_addr, uint32_t target_mhz, uint32_t cpol,
              uint32_t cpha);
void spi_set_control(uint32_t base_addr, uint32_t ctrl);
uint32_t spi_get_control(uint32_t base_addr);
void spi_set_csid(uint32_t base_addr, uint32_t csid);
void spi_set_csmode(uint32_t base_addr, uint32_t csmode);
uint32_t spi_get_status(uint32_t base_addr);
void spi_write_txdata(uint32_t base_addr, uint8_t data);
uint8_t spi_read_rxdata(uint32_t base_addr);

// Helper for single byte transfer
uint8_t spi_xfer(uint32_t base_addr, uint8_t tx);

#ifdef __cplusplus
}
#endif

#endif  // FPGA_SW_SPI_H_
