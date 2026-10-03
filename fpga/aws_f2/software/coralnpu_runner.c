// Load and run a Coral NPU ELF through the F2 OCL BAR.
// The sequence mirrors CoreMiniAxiInterface in the official Coral tutorial.
#define _POSIX_C_SOURCE 200809L

#include <elf.h>
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#include "fpga_mgmt.h"
#include "fpga_pci.h"

#define CORAL_CONTROL 0x00030000u
#define CORAL_PC      0x00030004u
#define CORAL_STATUS  0x00030008u
#define STATUS_HALTED 0x1u
#define STATUS_FAULT  0x2u

typedef struct {
  uint8_t *data;
  size_t size;
  Elf32_Ehdr *eh;
} elf_image_t;

static void usage(const char *argv0) {
  fprintf(stderr,
      "Usage: %s [--slot N] [--timeout SEC] [--verify] [--read SYMBOL[:WORDS]] ELF\n",
      argv0);
}

static int checked_range(const elf_image_t *img, size_t off, size_t len) {
  return off <= img->size && len <= img->size - off;
}

static int open_elf(const char *path, elf_image_t *img) {
  int fd = open(path, O_RDONLY);
  if (fd < 0) { perror(path); return -1; }
  struct stat st;
  if (fstat(fd, &st) || st.st_size < (off_t)sizeof(Elf32_Ehdr)) {
    perror("fstat/ELF size"); close(fd); return -1;
  }
  img->size = (size_t)st.st_size;
  img->data = mmap(NULL, img->size, PROT_READ, MAP_PRIVATE, fd, 0);
  close(fd);
  if (img->data == MAP_FAILED) { perror("mmap"); return -1; }
  img->eh = (Elf32_Ehdr *)img->data;
  if (memcmp(img->eh->e_ident, ELFMAG, SELFMAG) ||
      img->eh->e_ident[EI_CLASS] != ELFCLASS32 ||
      img->eh->e_ident[EI_DATA] != ELFDATA2LSB ||
      img->eh->e_machine != EM_RISCV) {
    fprintf(stderr, "%s is not a little-endian ELF32 RISC-V image\n", path);
    munmap(img->data, img->size); return -1;
  }
  if (!checked_range(img, img->eh->e_phoff,
                     (size_t)img->eh->e_phnum * img->eh->e_phentsize)) {
    fprintf(stderr, "ELF program-header table is out of range\n");
    munmap(img->data, img->size); return -1;
  }
  return 0;
}

static int poke(pci_bar_handle_t bar, uint32_t addr, uint32_t value) {
  int rc = fpga_pci_poke(bar, addr, value);
  if (rc) fprintf(stderr, "OCL write 0x%08" PRIx32 " failed: %d\n", addr, rc);
  return rc;
}

static int peek(pci_bar_handle_t bar, uint32_t addr, uint32_t *value) {
  int rc = fpga_pci_peek(bar, addr, value);
  if (rc) fprintf(stderr, "OCL read 0x%08" PRIx32 " failed: %d\n", addr, rc);
  return rc;
}

static int load_segments(pci_bar_handle_t bar, const elf_image_t *img,
                         bool verify) {
  for (unsigned i = 0; i < img->eh->e_phnum; ++i) {
    Elf32_Phdr ph;
    memcpy(&ph, img->data + img->eh->e_phoff +
                (size_t)i * img->eh->e_phentsize, sizeof(ph));
    if (ph.p_type != PT_LOAD || ph.p_memsz == 0) continue;
    if (ph.p_filesz > ph.p_memsz || !checked_range(img, ph.p_offset, ph.p_filesz)) {
      fprintf(stderr, "Invalid PT_LOAD segment %u\n", i); return -1;
    }
    uint64_t end64 = (uint64_t)ph.p_paddr + ph.p_memsz;
    if (end64 > UINT32_MAX + 1ull) {
      fprintf(stderr, "PT_LOAD segment %u exceeds 32-bit address space\n", i);
      return -1;
    }
    printf("load[%u] 0x%08" PRIx32 "..0x%08" PRIx64 " (%" PRIu32 " bytes)\n",
           i, ph.p_paddr, end64, ph.p_memsz);
    uint32_t first = ph.p_paddr & ~3u;
    uint32_t last = (uint32_t)((end64 + 3u) & ~3ull);
    for (uint32_t addr = first; addr != last; addr += 4) {
      uint32_t word = 0;
      for (unsigned lane = 0; lane < 4; ++lane) {
        uint32_t at = addr + lane;
        uint8_t byte = 0;
        if (at >= ph.p_paddr && at < ph.p_paddr + ph.p_filesz)
          byte = img->data[ph.p_offset + (at - ph.p_paddr)];
        word |= (uint32_t)byte << (lane * 8);
      }
      if (poke(bar, addr, word)) return -1;
      if (verify) {
        uint32_t got;
        if (peek(bar, addr, &got) || got != word) {
          fprintf(stderr, "verify failed at 0x%08" PRIx32 ": wrote 0x%08" PRIx32
                          ", read 0x%08" PRIx32 "\n", addr, word, got);
          return -1;
        }
      }
    }
  }
  return 0;
}

static int lookup_symbol(const elf_image_t *img, const char *name,
                         uint32_t *address) {
  if (!img->eh->e_shoff || !img->eh->e_shnum ||
      !checked_range(img, img->eh->e_shoff,
                     (size_t)img->eh->e_shnum * img->eh->e_shentsize)) return -1;
  for (unsigned i = 0; i < img->eh->e_shnum; ++i) {
    Elf32_Shdr sh;
    memcpy(&sh, img->data + img->eh->e_shoff +
                (size_t)i * img->eh->e_shentsize, sizeof(sh));
    if (sh.sh_type != SHT_SYMTAB && sh.sh_type != SHT_DYNSYM) continue;
    if (sh.sh_link >= img->eh->e_shnum || !sh.sh_entsize ||
        !checked_range(img, sh.sh_offset, sh.sh_size)) continue;
    Elf32_Shdr str;
    memcpy(&str, img->data + img->eh->e_shoff +
                 (size_t)sh.sh_link * img->eh->e_shentsize, sizeof(str));
    if (!checked_range(img, str.sh_offset, str.sh_size)) continue;
    const char *strings = (const char *)img->data + str.sh_offset;
    for (size_t off = 0; off + sizeof(Elf32_Sym) <= sh.sh_size; off += sh.sh_entsize) {
      Elf32_Sym sym;
      memcpy(&sym, img->data + sh.sh_offset + off, sizeof(sym));
      if (sym.st_name >= str.sh_size) continue;
      const char *candidate = strings + sym.st_name;
      if (memchr(candidate, '\0', str.sh_size - sym.st_name) && !strcmp(candidate, name)) {
        *address = sym.st_value;
        return 0;
      }
    }
  }
  return -1;
}

static double monotonic_seconds(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

int main(int argc, char **argv) {
  int slot = 0, timeout = 60;
  bool verify = false;
  const char *read_spec = NULL, *elf_path = NULL;
  for (int i = 1; i < argc; ++i) {
    if (!strcmp(argv[i], "--slot") && i + 1 < argc) slot = atoi(argv[++i]);
    else if (!strcmp(argv[i], "--timeout") && i + 1 < argc) timeout = atoi(argv[++i]);
    else if (!strcmp(argv[i], "--verify")) verify = true;
    else if (!strcmp(argv[i], "--read") && i + 1 < argc) read_spec = argv[++i];
    else if (argv[i][0] == '-') { usage(argv[0]); return 2; }
    else if (!elf_path) elf_path = argv[i];
    else { usage(argv[0]); return 2; }
  }
  if (!elf_path || timeout <= 0) { usage(argv[0]); return 2; }

  elf_image_t img = {0};
  if (open_elf(elf_path, &img)) return 1;
  if (fpga_mgmt_init()) { fprintf(stderr, "fpga_mgmt_init failed\n"); return 1; }

  pci_bar_handle_t bar = PCI_BAR_HANDLE_INIT;
  int rc = fpga_pci_attach(slot, 0, 0, 0, &bar);
  if (rc) {
    fprintf(stderr, "Could not attach slot %d APP PF BAR0: %d\n", slot, rc);
    munmap(img.data, img.size); return 1;
  }

  // Hold the architectural core in reset while loading ITCM/DTCM.
  if (poke(bar, CORAL_CONTROL, 1u) || load_segments(bar, &img, verify) ||
      poke(bar, CORAL_PC, img.eh->e_entry) || poke(bar, CORAL_CONTROL, 0u)) {
    rc = 1; goto out;
  }
  printf("start PC=0x%08" PRIx32 "\n", img.eh->e_entry);

  double deadline = monotonic_seconds() + timeout;
  uint32_t status = 0;
  do {
    if (peek(bar, CORAL_STATUS, &status)) { rc = 1; goto out; }
    if (status & (STATUS_HALTED | STATUS_FAULT)) break;
    struct timespec delay = {.tv_sec = 0, .tv_nsec = 1000000};
    nanosleep(&delay, NULL);
  } while (monotonic_seconds() < deadline);

  if (status & STATUS_FAULT) {
    fprintf(stderr, "Coral faulted (status=0x%08" PRIx32 ")\n", status);
    rc = 1; goto out;
  }
  if (!(status & STATUS_HALTED)) {
    fprintf(stderr, "Timeout after %d seconds (status=0x%08" PRIx32 ")\n", timeout, status);
    rc = 1; goto out;
  }
  printf("halted status=0x%08" PRIx32 "\n", status);

  if (read_spec) {
    char *spec = strdup(read_spec);
    if (!spec) { rc = 1; goto out; }
    char *colon = strchr(spec, ':');
    unsigned words = 1;
    if (colon) { *colon = '\0'; words = (unsigned)strtoul(colon + 1, NULL, 0); }
    uint32_t address;
    if (!words || lookup_symbol(&img, spec, &address)) {
      fprintf(stderr, "ELF symbol not found or invalid word count: %s\n", spec);
      free(spec); rc = 1; goto out;
    }
    printf("%s@0x%08" PRIx32 " =", spec, address);
    for (unsigned i = 0; i < words; ++i) {
      uint32_t value;
      if (peek(bar, address + 4u * i, &value)) {
        free(spec); rc = 1; goto out;
      }
      printf(" 0x%08" PRIx32, value);
    }
    putchar('\n');
    free(spec);
  }
  rc = 0;

out:
  fpga_pci_detach(bar);
  munmap(img.data, img.size);
  return rc;
}
