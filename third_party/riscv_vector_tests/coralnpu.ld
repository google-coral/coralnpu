/* CoralNPU link script for riscv-vector-tests */
OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY {
  ITCM (rx)  : ORIGIN = 0x00000000, LENGTH = 2M
  DTCM (rw)  : ORIGIN = 0x10000000, LENGTH = 2M
}

SECTIONS {
  .text : {
    *(.text.start)
    *(.text*)
  } > ITCM

  .rodata : {
    *(.rodata*)
  } > ITCM

  .data : {
    *(.data*)
    *(.sdata*)
  } > DTCM

  .bss : {
    *(.bss*)
    *(.sbss*)
  } > DTCM

  /DISCARD/ : {
    *(.comment*)
    *(.riscv.attributes*)
    *(.debug*)
    *(.note*)
  }
}
