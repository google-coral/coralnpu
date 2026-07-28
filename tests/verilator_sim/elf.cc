// Copyright 2024 Google LLC
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

#include "tests/verilator_sim/elf.h"

#include <elf.h>

#include <cstdint>
#include <cstring>
#include <string_view>

namespace {

template <typename Ehdr, typename Phdr>
uint64_t LoadElfTyped(const uint8_t *data, CopyFn copy_fn) {
  const Ehdr *elf_header = reinterpret_cast<const Ehdr *>(data);
  for (int i = 0; i < elf_header->e_phnum; ++i) {
    const Phdr *program_header =
        reinterpret_cast<const Phdr *>(data + elf_header->e_phoff + sizeof(Phdr) * i);
    if (program_header->p_type != PT_LOAD || program_header->p_filesz == 0) {
      continue;
    }
    copy_fn(reinterpret_cast<void *>(static_cast<uintptr_t>(program_header->p_paddr)),
            reinterpret_cast<const void *>(data + program_header->p_offset),
            program_header->p_filesz);
  }
  return elf_header->e_entry;
}

std::string_view SafeGetString(const char *table, size_t table_size, size_t offset) {
  if (table == nullptr || offset >= table_size) {
    return std::string_view();
  }
  size_t max_len = table_size - offset;
  size_t len     = strnlen(table + offset, max_len);
  return std::string_view(table + offset, len);
}

template <typename Ehdr, typename Shdr, typename Sym>
bool LookupSymbolTyped(const uint8_t *data, const std::string &symbol_name, uint64_t *symbol_addr) {
  const Ehdr *elf_header = reinterpret_cast<const Ehdr *>(data);
  if (elf_header->e_shstrndx == SHN_UNDEF || elf_header->e_shstrndx >= elf_header->e_shnum)
    return false;
  const auto section_string_table_idx     = elf_header->e_shstrndx;
  const Shdr *section_string_table_header = reinterpret_cast<const Shdr *>(
      data + elf_header->e_shoff + sizeof(Shdr) * section_string_table_idx);
  const char *section_string_table =
      reinterpret_cast<const char *>(data + section_string_table_header->sh_offset);
  size_t shstrtab_size = section_string_table_header->sh_size;

  const Sym *symbol_table  = nullptr;
  uint32_t symbol_count    = 0;
  const char *string_table = nullptr;
  size_t strtab_size       = 0;

  for (int i = 0; i < elf_header->e_shnum; ++i) {
    const Shdr *section_header =
        reinterpret_cast<const Shdr *>(data + elf_header->e_shoff + sizeof(Shdr) * i);
    if (section_header->sh_type == SHT_SYMTAB) {
      std::string_view symtab_name =
          SafeGetString(section_string_table, shstrtab_size, section_header->sh_name);
      if (symtab_name == ".symtab") {
        symbol_count = section_header->sh_size / sizeof(Sym);
        symbol_table = reinterpret_cast<const Sym *>(data + section_header->sh_offset);
      }
    }
    if (section_header->sh_type == SHT_STRTAB) {
      std::string_view strtab_name =
          SafeGetString(section_string_table, shstrtab_size, section_header->sh_name);
      if (strtab_name == ".strtab") {
        string_table = reinterpret_cast<const char *>(data + section_header->sh_offset);
        strtab_size  = section_header->sh_size;
      }
    }
  }
  if (string_table == nullptr || symbol_table == nullptr)
    return false;

  for (uint32_t i = 0; i < symbol_count; ++i) {
    const Sym *symbol = symbol_table + i;
    if (symbol->st_name != 0) {
      std::string_view found_symbol_name =
          SafeGetString(string_table, strtab_size, symbol->st_name);
      if (found_symbol_name == symbol_name) {
        *symbol_addr = symbol->st_value;
        return true;
      }
    }
  }
  return false;
}

}  // namespace

uint64_t LoadElf(const uint8_t *data, CopyFn copy_fn) {
  if (data == nullptr) {
    return 0;
  }
  if (std::memcmp(data, ELFMAG, SELFMAG) != 0) {
    return 0;
  }
  unsigned char elf_class = data[EI_CLASS];
  if (elf_class == ELFCLASS64) {
    return LoadElfTyped<Elf64_Ehdr, Elf64_Phdr>(data, copy_fn);
  } else if (elf_class == ELFCLASS32) {
    return LoadElfTyped<Elf32_Ehdr, Elf32_Phdr>(data, copy_fn);
  }
  return 0;
}

bool LookupSymbol(const uint8_t *data, const std::string &symbol_name, uint64_t *symbol_addr) {
  if (symbol_addr == nullptr || data == nullptr) {
    return false;
  }
  if (std::memcmp(data, ELFMAG, SELFMAG) != 0) {
    return false;
  }
  unsigned char elf_class = data[EI_CLASS];
  if (elf_class == ELFCLASS64) {
    return LookupSymbolTyped<Elf64_Ehdr, Elf64_Shdr, Elf64_Sym>(data, symbol_name, symbol_addr);
  } else if (elf_class == ELFCLASS32) {
    return LookupSymbolTyped<Elf32_Ehdr, Elf32_Shdr, Elf32_Sym>(data, symbol_name, symbol_addr);
  }
  return false;
}