# CoralNPU Nexus FPGA Operations

This document describes how to operate the CoralNPU Nexus FPGA emulation boards (e.g., Board 09, Board 10) in the lab.

## Loading the Bitstream

The FPGA configuration is volatile (stored in SRAM) and is **not** automatically loaded from flash on power-up or reset.

To load the bitstream, you must run `zturn` on the Zynq SOM Linux system.

1. SSH to the SOM (replace `XX` with the board ID, e.g., `09` or `10`):

   ```bash
   ssh root@nexusXX.mtv.corp.google.com
   ```

2. Run `zturn` to load the bitstream:

   ```bash
   zturn -d /data/chip_nexus.bin
   ```

   *Note: `zturn` returns exit code `0` on success. Automated test runners use the `NEXUS_BITSTREAM` environment variable to override the default bitstream path (`/data/chip_nexus.bin`).*

## Reset Mechanisms: Hard vs. Soft Reset

The platform supports two reset mechanisms. **Always prefer Soft Reset (`--soft_reset`) for normal operations.**

| Feature | Hard Reset (`--reset`) | Soft Reset (`--soft_reset`) |
| :--- | :--- | :--- |
| **Mechanism** | Physical `PROG_B` pin toggle (via FTDI ADBUS7). | SPI Opcode `0x03` command. |
| **FPGA Bitstream** | **Wiped** (SRAM cleared). | **Preserved** (remains configured). |
| **DDR Calibration** | **Lost** (requires reload + 1s wait). | **Preserved** (remains active). |
| **SoC Registers** | Reset to defaults (after reload). | Reset to defaults immediately. |
| **SOM Reload** | **Required** (via `zturn`). | **Not required**. Immediately ready. |
| **Execution Time** | ~3 seconds (reload + calibration). | Microseconds. |

### When to use which

* **Use Soft Reset (`--soft_reset`) by default**:
  * To reset the core and peripherals to a clean state between test runs.
  * To recover from an AXI/TL-UL bus hang (e.g., if you accessed DDR before it calibrated).
  * *Command*:

      ```bash
      nexus_loader --serial Nexus-FTDI-XX --soft_reset
      ```

* **Use Hard Reset (`--reset`) ONLY when**:
  * The FPGA is completely unresponsive and `soft_reset` fails (e.g., the FPGA is unconfigured or the SPI slave logic is hung).
  * You want to completely clear the FPGA state before loading a new bitstream.
  * *Command*:

    ```bash
    nexus_loader --serial Nexus-FTDI-XX --reset
    ```

  * **CRITICAL**: You **MUST** run `zturn` on the SOM to reload the bitstream immediately after a hard reset!

---

## DDR Calibration Timing

* DDR calibration starts automatically after the bitstream is loaded (either on power-up or after `zturn`), but it is **NOT instant** (it can take up to 1 second).
* **DO NOT** attempt to read or write to the DDR memory range (`0x80000000`) immediately after loading.
* Accessing DDR before calibration completes will stall the TLUL-to-AXI bridge, hanging the entire crossbar and blocking subsequent transactions.
* If this happens, run `--soft_reset` to unjam the bus.

---

## Troubleshooting & Recovery

If you encounter consistent read/write timeouts (e.g., `Failed to read word` or `RMW read failed`):

### Phase 1: Fast Recovery (Non-Destructive)

Try to recover the bus using soft reset:

```bash
# 1. Run soft reset (this will also unjam the FTDI MPSSE if it was hung)
nexus_loader --serial Nexus-FTDI-XX --soft_reset

# 2. Verify responsiveness by reading address 0x0
nexus_loader --serial Nexus-FTDI-XX --read_word_addr 0x0
```

If this succeeds, you can resume testing immediately.

### Phase 2: Full Recovery (Destructive)

If Phase 1 fails (meaning the FPGA is empty or in a fatal state), you must perform a full hard reset and reload:

```bash
# 1. Hard reset (wipes FPGA)
nexus_loader --serial Nexus-FTDI-XX --reset

# 2. Reload bitstream via SOM
ssh root@nexusXX.mtv.corp.google.com "zturn -d /data/chip_nexus.bin"

# 3. Wait 1 second for DDR calibration, then verify
sleep 1
nexus_loader --serial Nexus-FTDI-XX --read_word_addr 0x0
```
