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

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "fpga/sw/spi_flash.h"
#include "fpga/sw/uart.h"

// --- Structures ---

struct rom_header {
  uint32_t magic;
  uint32_t eocd_offset;
  uint32_t zip_start_offset;
  uint32_t reserved[5];
} __attribute__((packed));

struct zip_eocd {
  uint32_t signature;
  uint16_t disk_num;
  uint16_t cd_disk_num;
  uint16_t num_entries_on_disk;
  uint16_t total_entries;
  uint32_t cd_size;
  uint32_t cd_offset;
  uint16_t comment_len;
} __attribute__((packed));

struct zip_cd_entry {
  uint32_t signature;
  uint16_t version_made;
  uint16_t version_needed;
  uint16_t flags;
  uint16_t compression;
  uint16_t mod_time;
  uint16_t mod_date;
  uint32_t crc32;
  uint32_t compressed_size;
  uint32_t uncompressed_size;
  uint16_t filename_len;
  uint16_t extra_len;
  uint16_t comment_len;
  uint16_t disk_num_start;
  uint16_t internal_attr;
  uint32_t external_attr;
  uint32_t lfh_offset;
} __attribute__((packed));

struct zip_lfh {
  uint32_t signature;
  uint16_t version_needed;
  uint16_t flags;
  uint16_t compression;
  uint16_t mod_time;
  uint16_t mod_date;
  uint32_t crc32;
  uint32_t compressed_size;
  uint32_t uncompressed_size;
  uint16_t filename_len;
  uint16_t extra_len;
} __attribute__((packed));

struct elf_header {
  uint8_t e_ident[16];
  uint16_t e_type;
  uint16_t e_machine;
  uint32_t e_version;
  uint32_t e_entry;
  uint32_t e_phoff;
  uint32_t e_shoff;
  uint32_t e_flags;
  uint16_t e_ehsize;
  uint16_t e_phentsize;
  uint16_t e_phnum;
  uint16_t e_shentsize;
  uint16_t e_shnum;
  uint16_t e_shstrndx;
} __attribute__((packed));

struct elf_phdr {
  uint32_t p_type;
  uint32_t p_offset;
  uint32_t p_vaddr;
  uint32_t p_paddr;
  uint32_t p_filesz;
  uint32_t p_memsz;
  uint32_t p_flags;
  uint32_t p_align;
} __attribute__((packed));

// --- Helpers ---

static int strncmp_local(const char* s1, const char* s2, size_t n) {
  for (size_t i = 0; i < n; i++) {
    if (s1[i] != s2[i])
      return (int)((unsigned char)s1[i] - (unsigned char)s2[i]);
    if (s1[i] == '\0') return 0;
  }
  return 0;
}

int main(void) {
  uart_init();
  uart_putc('B');  // Booting

  spi_flash_init();

  // 1. Read ROM header at offset 0
  struct rom_header rh;
  spi_flash_read(0, (uint8_t*)&rh, sizeof(rh));

  if (rh.magic != 0x544f4f42) {  // "BOOT"
    uart_putc('M');              // Magic error
    while (1);
  }

  // 2. Read EOCD
  struct zip_eocd eocd;
  spi_flash_read(rh.eocd_offset, (uint8_t*)&eocd, sizeof(eocd));
  if (eocd.signature != 0x06054b50) {
    uart_putc('S');  // Signature error
    while (1);
  }

  // 3. Find BOOT.ELF in Central Directory
  uint32_t cd_ptr = rh.zip_start_offset + eocd.cd_offset;
  uint32_t elf_data_start = 0;

  for (int i = 0; i < eocd.total_entries; i++) {
    struct zip_cd_entry cd;
    spi_flash_read(cd_ptr, (uint8_t*)&cd, sizeof(cd));

    if (cd.filename_len == 8) {
      char filename[8];
      spi_flash_read(cd_ptr + sizeof(cd), (uint8_t*)filename, 8);
      if (strncmp_local(filename, "BOOT.ELF", 8) == 0) {
        // Found it! Get Local Header
        struct zip_lfh lfh;
        uint32_t lfh_addr = rh.zip_start_offset + cd.lfh_offset;
        spi_flash_read(lfh_addr, (uint8_t*)&lfh, sizeof(lfh));
        elf_data_start =
            lfh_addr + sizeof(lfh) + lfh.filename_len + lfh.extra_len;
        break;
      }
    }
    cd_ptr += sizeof(cd) + cd.filename_len + cd.extra_len + cd.comment_len;
  }

  if (elf_data_start == 0) {
    uart_putc('F');  // File not found
    while (1);
  }

  // 4. Load ELF
  struct elf_header eh;
  spi_flash_read(elf_data_start, (uint8_t*)&eh, sizeof(eh));

  if (eh.e_ident[0] != 0x7f || eh.e_ident[1] != 'E' || eh.e_ident[2] != 'L' ||
      eh.e_ident[3] != 'F') {
    uart_putc('E');  // ELF header error
    while (1);
  }

  for (int i = 0; i < eh.e_phnum; i++) {
    struct elf_phdr ph;
    spi_flash_read(elf_data_start + eh.e_phoff + i * eh.e_phentsize,
                   (uint8_t*)&ph, sizeof(ph));
    if (ph.p_type == 1) {  // PT_LOAD
      // Direct load from SPI to destination (ITCM/DTCM/SRAM) via DMA
      spi_flash_read_dma(elf_data_start + ph.p_offset,
                         (uint8_t*)(uintptr_t)ph.p_paddr, ph.p_filesz);
    }
  }

  uart_putc('J');  // Jumping

  void (*entry)(void) = (void (*)(void))(uintptr_t)eh.e_entry;
  entry();

  while (1);
  return 0;
}
