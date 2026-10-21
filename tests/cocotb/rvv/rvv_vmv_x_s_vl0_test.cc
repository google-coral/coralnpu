#include <stdint.h>

int32_t in_buf[4] __attribute__((section(".data"), aligned(16))) = {10, 20, 30, 40};
int32_t result __attribute__((section(".data")))                 = 0xDEAD;

int main(int argc, char **argv) {
  int32_t r = 0xDEAD;  // sentinel: survives if vmv.x.s is skipped
  asm volatile(
      "vsetivli zero, 4, e32, m1, ta, ma \n\t"  // vl=4
      "vle32.v  v8, (%[src])             \n\t"  // v8 = {10,20,30,40}
      "vsetivli zero, 0, e32, m1, ta, ma \n\t"  // vl=0   <- the #102 trigger
      "vmv.x.s  %[r], v8                 \n\t"  // r = v8[0], must happen even at vl=0
      : [r] "+r"(r)
      : [src] "r"(in_buf)
      : "v8", "vl", "vtype", "memory");
  result = r;
  return 0;
}