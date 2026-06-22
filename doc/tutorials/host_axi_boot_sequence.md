# Host AXI boot sequence

This is the host-side sequence for booting a Coral NPU instance exposed through
the AXI subordinate interface. It pulls together the memory map from the
integration guide and the ELF/testbench pieces from the program-writing
tutorial.

The system base address is SoC-specific. The addresses below are offsets within
the Coral NPU local address map.

## Address regions

| Region | Local address range | Purpose |
| --- | --- | --- |
| ITCM | `0x00000` - `0x01fff` | Instruction memory for code executed by Coral NPU. |
| DTCM | `0x10000` - `0x17fff` | Data memory for program buffers and stack data. |
| CSR | `0x30000` and above | Externally visible control/status registers. |

## Control registers

| Register | Local address | Use |
| --- | ---: | --- |
| `RESET_CONTROL` | `0x30000` | Bit 0 holds the core in reset when set; bit 1 gates the core clock when set. |
| `PC_START` | `0x30004` | Program counter value used when reset is released. |
| `STATUS` | `0x30008` | Bit 0 reports halted; bit 1 reports fault. |

On power-up, `RESET_CONTROL` holds the core in reset with the clock gated. A
host should release the clock gate before releasing reset so the synchronous
reset has an active clock edge.

## ELF loading

Programs built with `coralnpu_v2_binary` produce ELF files. A host loader should
iterate over loadable `PT_LOAD` segments and write each segment's bytes to the
segment physical address (`p_paddr`). Segments that target ITCM initialize
program code; segments that target DTCM initialize data.

For host-provided input or output buffers, inspect the ELF symbol table and use
symbol addresses as offsets into the Coral NPU address map. The program-writing
tutorial uses `input1_buffer`, `input2_buffer`, and `output_buffer` for this
pattern.

## Boot flow

1. Hold the core in reset with its clock gated by writing `0x3` to
   `RESET_CONTROL`.
2. Write loadable ELF segments through the AXI subordinate interface.
3. Write host-provided input buffers to their DTCM symbol addresses.
4. Write the ELF entry point to `PC_START`.
5. Release the clock gate while keeping reset asserted by writing `0x1` to
   `RESET_CONTROL`.
6. Wait at least one clock cycle.
7. Release reset by writing `0x0` to `RESET_CONTROL`.
8. Poll `STATUS` until either halted or fault is set. A fault should be treated
   as a boot or program failure.
9. Read output buffers from their DTCM symbol addresses.

If the surrounding SoC has a DMA engine, use it for bulk ITCM/DTCM
initialization and reserve CPU MMIO writes for short control/status accesses.

## Cocotb correspondence

The `CoreMiniAxiInterface` helper provides the same sequence for simulation:

```python
core_mini_axi = CoreMiniAxiInterface(dut)
await core_mini_axi.init()
await core_mini_axi.reset()
cocotb.start_soon(core_mini_axi.clock.start())

with open(elf_path, "rb") as elf:
    entry_point = await core_mini_axi.load_elf(elf, backdoor=False)

with open(elf_path, "rb") as elf:
    input_addr = core_mini_axi.lookup_symbol(elf, "input1_buffer")
    output_addr = core_mini_axi.lookup_symbol(elf, "output_buffer")

await core_mini_axi.write(input_addr, input_data)
await core_mini_axi.execute_from(entry_point)
await core_mini_axi.wait_for_halted()
output_data = await core_mini_axi.read(output_addr, output_size)
```

`load_elf(..., backdoor=False)` forces ELF loading through AXI bus writes. This
is slower than the default backdoor path, but it better matches what a system
host or bare-metal loader must do.

## Host pseudocode

```c
write32(base + 0x30000, 0x3);        // Hold reset and gate clock.
load_elf_segments_over_axi(base, elf);
write_input_buffers(base, elf_symbols);
write32(base + 0x30004, elf_entry);  // PC_START.
write32(base + 0x30000, 0x1);        // Clock running, reset held.
wait_at_least_one_core_clock();
write32(base + 0x30000, 0x0);        // Release reset.

do {
  status = read32(base + 0x30008);
  if (status & 0x2) {
    return FAULT;
  }
} while ((status & 0x1) == 0);

read_output_buffers(base, elf_symbols);
```

This flow assumes the host can access the Coral NPU local address map through
the AXI subordinate interface and that any SoC-level reset or clock controls
outside Coral NPU have already been released.
