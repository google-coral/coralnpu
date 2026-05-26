#!/usr/bin/env python3
# Copyright 2026 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

import argparse
import io
import struct
import zipfile


def main():
    parser = argparse.ArgumentParser(
        description="Create a flash image with ROM header and ZIP."
    )
    parser.add_argument("elf", help="Path to the payload ELF file.")
    parser.add_argument("output", help="Path to the output flash image.")
    args = parser.parse_args()

    # 1. Create a ZIP in memory containing the ELF as BOOT.ELF
    zip_buffer = io.BytesIO()
    with zipfile.ZipFile(zip_buffer, "w", compression=zipfile.ZIP_STORED) as zf:
        zf.write(args.elf, "BOOT.ELF")

    zip_data = zip_buffer.getvalue()

    # 2. Find EOCD (End of Central Directory)
    # EOCD is at least 22 bytes at the end of the ZIP
    eocd_pos = zip_data.rfind(b"\x50\x4b\x05\x06")
    if eocd_pos == -1:
        raise RuntimeError("Could not find EOCD in generated ZIP")

    # 3. Create ROM Header (32 bytes)
    # struct rom_header {
    #     uint32_t magic;           // 0x00
    #     uint32_t eocd_offset;     // 0x04
    #     uint32_t zip_start_offset;// 0x08
    #     uint32_t reserved[5];     // 0x0C
    # }
    header_size = 32
    magic = 0x544F4F42  # "BOOT" in little-endian (B=0x42 at byte 0)
    zip_start_offset = header_size
    eocd_offset = zip_start_offset + eocd_pos

    header = struct.pack("<III5I", magic, eocd_offset, zip_start_offset, 0, 0, 0, 0, 0)

    # 4. Write Header + ZIP
    with open(args.output, "wb") as f:
        f.write(header)
        f.write(zip_data)

    print(f"Created flash image {args.output}")
    print(f"  Magic:      0x{magic:08x} (Hexdump: {header[:4].hex()})")
    print(f"  ZIP Start:  0x{zip_start_offset:x}")
    print(f"  EOCD Start: 0x{eocd_offset:x}")


if __name__ == "__main__":
    main()
