#pragma GCC optimize("O0")
#include <stdint.h>

// Global variable to store minstret value so it can be read by cocotb from memory.
volatile uint32_t minstret_val;

int main() {
  asm volatile("csrr %0, minstret" : "=r"(minstret_val)::"memory");
  return 0;
}
