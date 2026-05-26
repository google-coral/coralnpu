/* Copyright 2026 Google LLC. */
/* Licensed under the Apache License, Version 2.0, see LICENSE for details. */
/* SPDX-License-Identifier: Apache-2.0 */

MEMORY {
    ROM(rx) : ORIGIN = 0x10000000, LENGTH = 32K
    DTCM(rw) : ORIGIN = 0x00010000, LENGTH = 32K
}

ENTRY(_start)

SECTIONS {
    .text : {
        *(._init)
        *(.text)
        *(.text.*)
    } > ROM

    .rodata : ALIGN(4) {
        *(.rodata)
        *(.rodata.*)
        *(.srodata)
        *(.srodata.*)
        . = ALIGN(4);
    } > ROM

    . = ALIGN(4);
    _data_load = LOADADDR(.data);
    .data : ALIGN(4) {
        _data_start = .;
        *(.data)
        *(.data.*)
        *(.sdata)
        *(.sdata.*)
        . = ALIGN(4);
        _data_end = .;
    } > DTCM AT > ROM

    .bss : ALIGN(4) {
        _bss_start = .;
        *(.bss)
        *(.bss.*)
        *(.sbss)
        *(.sbss.*)
        . = ALIGN(4);
        _bss_end = .;
    } > DTCM

    .stack : {
        . = ALIGN(16);
        . += 1024;
        _stack_top = .;
    } > DTCM
}
