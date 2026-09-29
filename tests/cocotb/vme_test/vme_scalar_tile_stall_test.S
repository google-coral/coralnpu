/*
 * Directed test to demonstrate and observe scalar scoreboard false stalls
 * caused by tile instructions.
 *
 * Case A (Stall on x8):
 *   Slot 0: vtzero mt4   (encoded rd = x8)
 *   Slot 1: addi x8, x0, 42  (rd = x8) -> FALSE WAW stall
 *   Slot 1 should stall at decode, dispatching 1 cycle later.
 *
 * Case B (Stall on reading x8):
 *   Slot 0: vtzero mt4   (encoded rd = x8)
 *   Slot 1: addi x5, x8, 1   (rs1 = x8) -> FALSE RAW stall
 *   Slot 1 should stall at decode, dispatching 1 cycle later.
 *
 * Case C (No stall on x4):
 *   Slot 0: vtzero mt4   (encoded rd = x8)
 *   Slot 1: addi x4, x0, 10  (rd = x4) -> NO stall
 *   Both Slot 0 and Slot 1 should dual-issue in the SAME cycle.
 */
  .section ._init, "ax"
  .global _start
  .type _start, @function
_start:
  # Enable mstatus.VS (bits 10:9 = 11) and FS (bits 14:13 = 11) -> 0x6600
  li      t0, 0x6600
  csrrs   zero, mstatus, t0

  # Tile configuration (Zvt v0.4 encodings):
  li      x6, 0x4083
  li      x9, 0x0             # altfmt=0, sew=8b
  .word   0x84937057          # msetmtype x0, x6, x9

  li      x10, 16
  .word   0x880575D7          # msettn x11, x10
  li      x14, 16
  .word   0x881776D7          # msettm x13, x14
  li      x16, 4
  .word   0x882877D7          # msettk x15, x16

  nop
  nop
  nop
  nop

  # ---------------------------------------------------------------------------
  # Case 1: NO STALL with x4 (Control Case)
  # Slot 0 has vtzero mt4 (rd = x8). Slot 1 has addi x4, x0, 10 (rd = x4).
  # No overlap in scalar destination register. Both should dual-issue together.
  # ---------------------------------------------------------------------------
  .balign 8
  .word   0x43E06457          # Slot 0: vtzero mt4 (rd = x8)
  addi    x4, x0, 10          # Slot 1: addi x4, x0, 10 (rd = x4)

  nop
  nop
  nop
  nop

  # ---------------------------------------------------------------------------
  # Case 2: FALSE WAW STALL with x8
  # Slot 0 has vtzero mt4 (rd = x8). Slot 1 has addi x8, x0, 42 (rd = x8).
  # Slot 1 will stall for 1 cycle because rdScoreboard treats mt4 as writing x8.
  # ---------------------------------------------------------------------------
  .balign 8
  .word   0x43E06457          # Slot 0: vtzero mt4 (rd = x8)
  addi    x8, x0, 42          # Slot 1: addi x8, x0, 42 (rd = x8)

  nop
  nop
  nop
  nop

  # ---------------------------------------------------------------------------
  # Case 3: FALSE RAW STALL with x8
  # Slot 0 has vtzero mt4 (rd = x8). Slot 1 has addi x5, x8, 1 (rs1 = x8).
  # Slot 1 will stall for 1 cycle because readAfterWrite detects rs1 == x8.
  # ---------------------------------------------------------------------------
  .balign 8
  .word   0x43E06457          # Slot 0: vtzero mt4 (rd = x8)
  addi    x5, x8, 1           # Slot 1: addi x5, x8, 1 (rs1 = x8)

  nop
  nop
  nop
  nop

  # Clean simulator halt
  .word   0x08000073          # mpause
1:
  j       1b
