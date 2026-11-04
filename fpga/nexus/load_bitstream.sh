#!/usr/bin/env bash
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

set -eu -o pipefail

usage() {
    echo "Usage:"
    echo "  load_bitstream.sh [--bitstream fpga/bitstreams/chip_nexus.bin] [--host nexus17] [--mcu_uart /dev/ttyUSB5]"
    echo ""
    echo "Options:"
    echo "  -b, --bitstream  Path to bitstream file to load (default: fpga/bitstreams/chip_nexus.bin)"
    echo "  --host           Hostname or IP of Nexus SOM (default: nexus\${NEXUS_ID})"
    echo "  --mcu_uart       Path to device for Nexus MCU UART (default: /dev/Nexus-FTDI-\${NEXUS_ID}-MCU-UART)"
    echo "  -h, --help       Display this help message and exit"
    echo ""
    exit 1
}

while [[ "$#" -gt 0 ]]; do
    case "${1}" in
        -b|--bitstream)
            BITSTREAM_PATH="${2}"; shift 2 ;;
        --host)
            NEXUS_HOST="${2}"; shift 2 ;;
        --mcu_uart)
            MCU_UART="${2}"; shift 2 ;;
        -h|--help)
            usage ;;
        *)
            echo "Unknown option: ${1}"; usage ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

if [[ -z "${BITSTREAM_PATH:-}" ]]; then
    if PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." 2>/dev/null && pwd)"; then
        BITSTREAM_PATH="${PROJECT_ROOT}/fpga/bitstreams/chip_nexus.bin"
    else
        BITSTREAM_PATH="chip_nexus.bin"
    fi
    echo "[INFO] --bitstream not specified, defaulting to ${BITSTREAM_PATH}"
fi

if [[ ! -f "${BITSTREAM_PATH}" ]]; then
    echo "[ERROR] Bitstream file not found: ${BITSTREAM_PATH}" >&2
    exit 1
fi

if [[ -z "${MCU_UART:-}" ]]; then
    if [[ -n "${NEXUS_ID:-}" ]]; then
        MCU_UART="/dev/Nexus-FTDI-${NEXUS_ID}-MCU-UART"
    else
        echo "[ERROR] Specify path to MCU UART with --mcu_uart, or set NEXUS_ID" >&2
        exit 1
    fi
fi

if [[ -z "${NEXUS_HOST:-}" ]]; then
    if [[ -n "${NEXUS_ID:-}" ]]; then
        NEXUS_HOST="nexus${NEXUS_ID}"
    else
        echo "[ERROR] Specify hostname of Nexus SOM with --host, or set NEXUS_ID" >&2
        exit 1
    fi
fi

# Check that tio is installed, issue error otherwise
if ! command -v tio > /dev/null; then
    echo "[ERROR] tio command not found. Install with: sudo apt-get install tio" >&2
    exit 1
fi

nexus_mcu_write() {
    # Send command to the Nexus MCU REPL
    echo "Clearing MCU UART input buffer..."
    echo -e '\r' | tio "${MCU_UART}" --script "expect('Unrecognized command: \r', 1000)" --mute
    echo "Sending nexus MCU the command: $*"
    echo -ne "$*\r" | tio "${MCU_UART}" --script "expect('> ', 1000)" --mute
    echo
}

BITSTREAM="$(basename "${BITSTREAM_PATH}")"
LOCAL_SHA="$(sha256sum "${BITSTREAM_PATH}" | cut -f1 -d' ')"
# shellcheck disable=SC2029
REMOTE_SHA="$(ssh "root@${NEXUS_HOST}" "sha256sum '/data/${BITSTREAM}' 2>/dev/null | cut -f1 -d' '" || true)"

if [[ "${LOCAL_SHA}" != "${REMOTE_SHA}" ]]; then
    scp "${BITSTREAM_PATH}" "root@${NEXUS_HOST}:/data/"
fi

# Loading a bitstream with the camera powered on can wedge it
nexus_mcu_write "camera_powerdown"

# ssh to nexus and run zturn
# shellcheck disable=SC2029
if ! ssh "root@${NEXUS_HOST}" "zturn -d '/data/${BITSTREAM}'"; then
    echo "zturn failed, exiting" >&2
    exit 1
fi

# enable camera
nexus_mcu_write "camera_powerup"
