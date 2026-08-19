#include <stdint.h>

#define DDR_BASE   0x81000000
#define TEST_WORDS 16

// volatile to ensure the compiler doesn't optimize away our "redundant" writes
static volatile uint32_t *ddr = (uint32_t *)DDR_BASE;

int main() {
  // Write unique ID to each word in the first 64 bytes of our DDR range
  for (uint32_t i = 0; i < TEST_WORDS; i++) {
    ddr[i] = 0xA0000000 | (i << 8) | i;
  }

  // Read back is handled by the cocotb testbench by inspecting DDR memory
  // but we can also do a local check to trigger a failure if the CPU sees it
  // too.
  uint32_t fail_mask = 0;
  for (uint32_t i = 0; i < TEST_WORDS; i++) {
    uint32_t exp = 0xA0000000 | (i << 8) | i;
    if (ddr[i] != exp) {
      fail_mask |= (1 << i);
    }
  }

  // Halt with the fail_mask in a register or just ebreak
  if (fail_mask != 0) {
    asm volatile("mv a0, %0" : : "r"(fail_mask));
    asm volatile("ebreak");
  }

  // Success halt
  asm volatile(".word 0x8000073");  // mpause
  return 0;
}
