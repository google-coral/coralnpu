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

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
cd "${REPO_ROOT}" || exit 1

if [[ -n "${NEXUS_ID:-}" ]]; then
    USB_SERIAL="Nexus-FTDI-${NEXUS_ID}"
elif [[ -n "${1:-}" ]]; then
    USB_SERIAL="$1"
else
    echo "Error: Set NEXUS_ID in the environment or pass the device name as the first argument." >&2
    echo "Usage: NEXUS_ID=<id> $0 | $0 <device_name>" >&2
    exit 1
fi

# Tests expected to fail on Nexus FPGA hardware (XFAIL).
# If any of these pass, the script flags them as XPASS so they can be removed.
EXPECTED_FAILURES=()

is_expected_failure() {
    local target="$1"
    local xfail
    for xfail in "${EXPECTED_FAILURES[@]}"; do
        if [[ "${target}" == "${xfail}" ]]; then
            return 0
        fi
    done
    return 1
}

query_output="$(bazel query 'kind("py_binary", attr(tags, "nexus_fpga", //...))' 2>/dev/null)" || exit 1
mapfile -t targets <<< "${query_output}"

echo "Found ${#targets[@]} FPGA test targets. Building all upfront..."

bazel build "${targets[@]}" || exit 1

passed=()
failed=()
xfailed=()
xpassed=()

for t in "${targets[@]}"; do
    echo "========================================"
    echo "Running: ${t}"
    echo "========================================"
    if bazel run "${t}" -- --usb-serial "${USB_SERIAL}" --highmem --verify; then
        if is_expected_failure "${t}"; then
            xpassed+=("${t}")
        else
            passed+=("${t}")
        fi
    else
        if is_expected_failure "${t}"; then
            xfailed+=("${t}")
        else
            failed+=("${t}")
        fi
    fi
done

echo "========================================"
echo "Serial device: ${USB_SERIAL}"
echo "Summary: ${#passed[@]} passed, ${#xfailed[@]} expected fail (XFAIL), ${#failed[@]} unexpected fail, ${#xpassed[@]} unexpected pass (XPASS) (out of ${#targets[@]})"
if (( ${#xfailed[@]} > 0 )); then
    printf '  XFAIL (expected): %s\n' "${xfailed[@]}"
fi
if (( ${#xpassed[@]} > 0 )); then
    printf '  XPASS (remove from EXPECTED_FAILURES): %s\n' "${xpassed[@]}"
fi
if (( ${#failed[@]} > 0 )); then
    printf '  FAILED: %s\n' "${failed[@]}"
fi
if (( ${#failed[@]} > 0 || ${#xpassed[@]} > 0 )); then
    exit 1
fi
