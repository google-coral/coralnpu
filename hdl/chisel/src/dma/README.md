# CoralNPU DMA

[TOC]

---

## 1. Overview

A standalone TL-UL DMA peripheral that moves a contiguous block of memory to a
destination, optionally **de-interleaving** it into several separate planes on
the way.

The motivating case is RGB de-interleave: an image stored as `R G B R G B …`
becomes three separate single-channel planes, which is the layout most
convolution kernels expect.

**`DLENB`**, the data bus width in bytes, is **16 throughout this document**.
Every DMA read and write is one `DLENB`-byte, `DLENB`-aligned beat. Formulas
hold for any power-of-two `DLENB`; concrete numbers do not.

---

## 2. Software interface

For anyone writing software that drives the DMA: drivers, runtimes, compilers.

> **This interface is subject to change.** Behaviour not described in this
> section is not supported and should not be relied on.

### 2.1 What the DMA does

Two modes, selected by `n_areas` in `XFER_CFG`. In NumPy terms, with `src` and
`dst` as `np.uint8` arrays:

**Memcopy** (`n_areas == 1`)

```python
dst[:len] = src[:len]
```

**Strided de-interleave** (`n_areas` = 2 … 16)

```python
dtype  = {0: np.uint8, 1: np.uint16, 2: np.uint32, 3: np.uint64}[xfer_width]
elems  = src[:len].view(dtype)
planes = elems.reshape(-1, n_areas).T
for j in range(n_areas):
    base = j * row_pitch
    dst[base : base + area_size] = planes[j].view(np.uint8)
```

### 2.2 Terminology

| term | meaning |
|---|---|
| **beat** | one `DLENB`-byte bus transaction; the smallest unit the DMA reads or writes |
| **area / plane** | one of the `n_areas` output streams the source is split into |
| **element** | the smallest interleaved unit in the source — one byte for `uint8` RGB, four bytes for interleaved `float32` |
| **`area_size`** | bytes of real data in one plane: `AREA_SIZE` in strided mode, `len` in memcopy |
| **`row_pitch`** | distance in bytes from the start of one plane to the start of the next |

### 2.3 Register map

All registers are 32 bits and are accessed at `DMA_BASE + offset`.

> `DMA_BASE` is assigned at SoC integration time.
>
> TO DO: fill it in before using this document as a programming reference.

| register | offset | access | purpose |
|---|---|---|---|
| `CTRL` | `0x00` | RW | `[0]` ENABLE, `[1]` START, `[2]` ABORT (reserved), `[3]` CLEAR_ERROR. Reads return ENABLE. |
| `STATUS` | `0x04` | R | `[0]` busy, `[1]` done, `[2]` error (OR of `[5:3]`), `[3]` align_error, `[4]` cfg_error, `[5]` xfer_error. |
| `SRC_ADDR` | `0x08` | RW | Source base address. |
| `DST_ADDR` | `0x0c` | RW | Base address of plane 0. |
| `LEN_FLAGS` | `0x10` | RW | `len`, `xfer_width` and mode flags; layout below. |
| `XFER_CFG` | `0x14` | RW | `[7:0]` `n_areas`, 1–16. Reset 1. |
| `AREA_SIZE` | `0x18` | RW | `[23:0]` bytes per plane, strided only. Reset 0. |
| `PASS_REM` | `0x1c` | R | Passes remaining in the running transfer. Debug only. |

#### `LEN_FLAGS` bit layout

| bits | field | meaning |
|---|---|---|
| `[23:0]` | `len` | Source bytes. Strided geometry comes from `AREA_SIZE`. |
| `[26:24]` | `xfer_width` | log2(element size in bytes), 0–4. Used only in strided mode. |
| `[31:27]` | `src_fixed`, `dst_fixed`, `poll_en`, reserved | Not implemented; write 0. |

### 2.4 Programming sequence

```c
#define DMA_CTRL       0x00
#define DMA_STATUS     0x04
#define DMA_SRC_ADDR   0x08
#define DMA_DST_ADDR   0x0c
#define DMA_LEN_FLAGS  0x10
#define DMA_XFER_CFG   0x14
#define DMA_AREA_SIZE  0x18

#define CTRL_ENABLE       (1u << 0)
#define CTRL_START        (1u << 1)
#define CTRL_CLEAR_ERROR  (1u << 3)
#define STATUS_DONE       (1u << 1)
#define STATUS_ERROR      (1u << 2)

static inline void dma_wr(uint32_t off, uint32_t v) {
  *(volatile uint32_t *)(DMA_BASE + off) = v;
}
static inline uint32_t dma_rd(uint32_t off) {
  return *(volatile uint32_t *)(DMA_BASE + off);
}

// Returns STATUS at completion.
uint32_t dma_transfer(uint32_t src, uint32_t dst, uint32_t len,
                      uint32_t xfer_width, uint32_t n_areas) {
  // Check error
  if (dma_rd(DMA_STATUS) & STATUS_ERROR)
    dma_wr(DMA_CTRL, CTRL_CLEAR_ERROR);

  // Start a new DMA transaction
  dma_wr(DMA_SRC_ADDR, src);
  dma_wr(DMA_DST_ADDR, dst);
  dma_wr(DMA_LEN_FLAGS, len | (xfer_width << 24));
  dma_wr(DMA_XFER_CFG, n_areas);
  if (n_areas > 1)
    dma_wr(DMA_AREA_SIZE, len / n_areas);
  dma_wr(DMA_CTRL, CTRL_ENABLE | CTRL_START);

  // Poll DMA status for completion
  uint32_t status;
  while (!((status = dma_rd(DMA_STATUS)) & (STATUS_DONE | STATUS_ERROR))) {}
  return status;
}
```

### 2.5 Example: RGB de-interleave

120 bytes of interleaved 1-byte `R G B R G B …` into three planes.

```c
// area_size = 120 / 3 = 40, row_pitch = 48 (40 rounded up to 16)
static uint8_t src[144] __attribute__((aligned(16)));  // 120 + over-read, Requirement 6
static uint8_t dst[144] __attribute__((aligned(16)));  // 3 × row_pitch, Requirement 7

uint32_t status = dma_transfer((uint32_t)src, (uint32_t)dst, 120, 0, 3);

uint8_t *r = dst + 0 * 48;
uint8_t *g = dst + 1 * 48;
uint8_t *b = dst + 2 * 48;
```

### 2.6 Requirements on software

#### Configuration

|   | software must | why | if not |
|---|---|---|---|
| *Requirement 1* | Align `SRC_ADDR` and `DST_ADDR` to 16 bytes. | The DMA only reads and writes whole, aligned 16-byte beats. | `align_error` |
| *Requirement 2* | Set `len` > 0. In strided mode, set `AREA_SIZE` = `len / n_areas`, non-zero. | Hardware has no divider (software already knows the value), so it can't compute or check `area_size`. | `cfg_error` if `len` or `AREA_SIZE` is 0. A wrong non-zero `AREA_SIZE` is **not detected**. |
| *Requirement 3* | Keep `len` ≤ 16,777,215 (24 bits); split larger copies. | `len` is a 24-bit field. | **Not detected**: upper bits are dropped. |
| *Requirement 4* | Set `xfer_width` 0–4 and `n_areas` 1–16. | An element must fit in one beat, and the buffer holds at most 16 planes. | `cfg_error` |
| *Requirement 5* | Write `LEN_FLAGS[31:27]` as 0. | These modes aren't implemented; rejecting them is safer than silently ignoring them. | `cfg_error` |

#### Memory allocation

|   | software must | why | if not |
|---|---|---|---|
| *Requirement 6* | Make the source readable up to `n_areas × area_size` rounded up to a multiple of `n_areas × 16` (at most 240 extra bytes). Contents of the extra bytes don't matter. | The final pass always reads whole beats, even past the end of the data. | `xfer_error` if the extra range is unmapped, even though the data moved correctly. |
| *Requirement 7* | Size the destination `n_areas × row_pitch`, with `row_pitch = ceil(area_size / 16) × 16`, and find plane `j` at `dst + j × row_pitch`. The last `row_pitch − area_size` bytes of each plane are left untouched. | Every write is an aligned 16-byte beat, so each plane must start on a 16-byte boundary. | **Not detected**: writes past the buffer, or planes read from the wrong offset. |

#### Operation

|   | software must | why | if not |
|---|---|---|---|
| *Requirement 8* | Clear errors (`CTRL.CLEAR_ERROR`) before the next `START`; error bits are sticky. | A failed transfer can't be silently overwritten by the next one. | `START` is ignored and `STATUS` keeps the old error. |
| *Requirement 9* | Wait for `done` or an error before writing the next configuration. | The DMA holds one transfer at a time; there is no queue. | Writes are ignored; **not detected**. |

### 2.7 Error reporting

| bit | set when | destination |
|---|---|---|
| `align_error` | *Requirement 1* is violated | untouched; the transfer never started |
| `cfg_error` | *Requirement 2*, *Requirement 4* or *Requirement 5* is violated | untouched; the transfer never started |
| `xfer_error` | the bus returned an error during the transfer | partially written; untrustworthy |

### 2.8 Not implemented

- Interrupt on completion
- Abort (`CTRL[2]`)
- Fixed-address modes and `poll_en` (`LEN_FLAGS[31:27]`)
- Descriptor chaining or queueing of multiple transfers
- 2-D tiled transpose

---

## 3. Hardware internals

For anyone modifying, porting, or integrating the DMA. Not needed to use it.

### 3.1 Hardware interfaces

| port | role | connects to | carries |
|---|---|---|---|
| `tl_device` | TL-UL **device** (slave) | SoC crossbar, driven by the RISC-V scalar core | register reads and writes from software |
| `tl_host` | TL-UL **host** (master) | SoC crossbar | every source `Get` and every destination `PutFullData` / `PutPartialData` |

Plus clock and synchronous reset.

`tl_host` shares the crossbar with the core and competes with it for bandwidth.
Any TL-UL-addressable target is a legal source or destination: DDR, SRAM, or the
core's DTCM.

### 3.2 Internal structure

| module | role |
|---|---|
| `DmaCsr` | terminates `tl_device`; holds the register file; validates configuration and computes transfer geometry once at start |
| `DmaFillEngine` | issues source `Get`s and writes responses into the transpose buffer |
| `TransposeBuffer` | performs the de-interleave gather; in memcopy mode it is a pass-through |
| `DmaDrainEngine` | reads the buffer and issues destination `Put`s |
| `TlulArbiter` | merges the fill and drain engines' requests onto the single `tl_host` port |
| `DmaDescriptors` | shared bundle definitions used by the engines |

The two engines run independent loops and do not hand off to each other. They
are synchronised only through the transpose buffer's ready/valid handshakes, so
those handshakes are load-bearing rather than incidental.

#### Additional terminology

| term | meaning |
|---|---|
| **pass** | one fill-then-drain cycle through the transpose buffer; moves 16 bytes into every plane |
| **`gMax`** | `log2(DLENB)`. Used for shifts and for the alignment check. |

### 3.3 The worked example, continued

The §2.5 example (`len = 120`, `n_areas = 3`, 1-byte elements), with `src` at
`0x8000_0000` and `dst` at `0x2000`.

| quantity | value |
|---|---|
| `area_size` | 40 |
| `passes` | 3 |
| `tail_bytes` | 8 |
| beats per pass | 3 |
| `row_pitch` | 48 |

#### Reads issued — 9 `Get`s of 16 bytes each

| pass | addresses |
|---|---|
| 0 | `…0000`, `…0010`, `…0020` |
| 1 | `…0030`, `…0040`, `…0050` |
| 2 | `…0060`, `…0070`, `…0080` |

Real source data ends at `…0077` (byte 119). The last 24 bytes read lie past the
end of the source buffer; this is what *Requirement 6* covers.

#### Writes issued — 9 `Put`s

| pass | beat 0 (R) | beat 1 (G) | beat 2 (B) |
|---|---|---|---|
| 0 | `0x2000` | `0x2030` | `0x2060` |
| 1 | `0x2010` | `0x2040` | `0x2070` |
| 2 | `0x2020` | `0x2050` | `0x2080` |

Masking in strided mode applies to **every** beat of the final pass,
not just the last one, and the mask is derived from `area_size mod 16`, not
`len mod 16`. In memcopy mode `n_areas = 1`, so `area_size == len` and the two
coincide — which means a memcopy test suite will not catch a bug here.

### 3.4 Geometry derivation

`DmaCsr` computes the whole transfer geometry once, at start, and hands each
engine a single job descriptor. Neither engine recomputes anything.

| parameter | memcopy (`n_areas == 1`) | strided (`n_areas > 1`) |
|---|---|---|
| `area_size` | `len` | `AREA_SIZE` register |
| beats per pass | `DLENB` | `n_areas` |
| `passes` | `ceil(len / DLENB²)` | `ceil(area_size / DLENB)` |
| `row_pitch` | `DLENB` | `passes × DLENB` |
| tail mask | from `len mod DLENB` | from `area_size mod DLENB` |
| mask every beat of last pass | no | yes |

There is no runtime division: strided `area_size` comes from software, and
memcopy uses `len` directly. Everything else is a shift, because `DLENB` is a
power of two fixed at elaboration time.

### 3.5 Parameterization

`DLENB` comes from `TLULParameters` as `p.w`. The RTL refers to it
symbolically — the `n_areas` bound is `nAreas > N`, not a literal 16, and
address arithmetic shifts by `gMax` rather than by a constant 4.

Changing `DLENB` therefore requires no RTL change, but it does change every byte
count in section 2:

| quantity | expression |
|---|---|
| alignment requirement | `DLENB` bytes |
| maximum `n_areas` | `DLENB` |
| maximum `xfer_width` | `gMax` |
| source over-allocation granularity | `n_areas × DLENB` |
| `row_pitch` | `ceil(area_size / DLENB) × DLENB` |
| worst-case over-read | `DLENB × (DLENB − 1)` bytes |
