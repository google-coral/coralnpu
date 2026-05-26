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

#ifndef FPGA_SW_SPI_FLASH_H_
#define FPGA_SW_SPI_FLASH_H_

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// SPI Flash Commands
#define SPI_FLASH_CMD_PAGE_PROGRAM 0x02
#define SPI_FLASH_CMD_READ 0x03
#define SPI_FLASH_CMD_READ_STATUS 0x05
#define SPI_FLASH_CMD_WRITE_ENABLE 0x06
#define SPI_FLASH_CMD_SECTOR_ERASE 0xD8
#define SPI_FLASH_CMD_READ_ID 0x9F
#define SPI_FLASH_CMD_READ_SFDP 0x5A

// Structure to hold discovered flash parameters
struct spi_flash_info {
  uint8_t mfr_id;
  uint8_t device_id[2];
  uint32_t capacity_bytes;
  uint32_t sector_size_bytes;
  uint32_t page_size_bytes;
};

// NOTE: This driver currently uses 3-byte addressing, which limits the
// maximum addressable space to 16MB (0xFFFFFF).

// Initialize the SPI Flash peripheral
void spi_flash_init(void);

// Perform a hardware reset of the SPI Flash
void spi_flash_hw_reset(void);

// Assert/Deassert Chip Select
void spi_flash_cs_assert(void);
void spi_flash_cs_deassert(void);

// Write enable command
void spi_flash_write_enable(void);

// Poll status register until (status & mask) == expected.
// If poll_limit is 0, polls indefinitely.
bool spi_flash_poll_status(uint8_t mask, uint8_t expected, uint8_t* result,
                           uint32_t poll_limit);

// Read JEDEC ID
void spi_flash_read_id(uint8_t* mfr, uint8_t* id1, uint8_t* id2);

// Erase a sector
bool spi_flash_sector_erase(uint32_t addr);

// Program a page (up to 256 bytes)
bool spi_flash_page_program(uint32_t addr, const uint8_t* data, uint32_t len);

// Read data from flash
void spi_flash_read(uint32_t addr, uint8_t* data, uint32_t len);

// Read data from flash using DMA in half-duplex RX mode.
void spi_flash_read_dma(uint32_t addr, uint8_t* data, uint32_t len);

// Read SFDP data
void spi_flash_read_sfdp(uint32_t addr, uint8_t* data, uint32_t len);

// Discover flash parameters using SFDP and ID-CFI
bool spi_flash_discover(struct spi_flash_info* info);

#ifdef __cplusplus
}
#endif

#endif  // FPGA_SW_SPI_FLASH_H_
