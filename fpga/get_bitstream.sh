#!/bin/bash
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

set -ue -o pipefail

GCP_PROJECT="${PROJECT:-cerebra-shodan-ci-public}"
GCP_LOCATION="${LOCATION:-us}"
AR_REPO="${REPO:-coralnpu-artifacts}"
AR_PACKAGE="${PACKAGE:-coralnpu-bitstreams}"
TARGET_FILE="${TARGET:-chip_nexus_matrix.bin}"
LIMIT=10
START_REF=""

usage() {
    echo "Usage:"
    echo "  get_bitstream.sh (--latest|--ref REF) [options]"
    echo ""
    echo "Options:"
    echo "  -r, --ref      The git reference to start searching from"
    echo "  -n, --limit    Number of git commits to check back (default: ${LIMIT})"
    echo "  --target       The name of the file to fetch (default: ${TARGET_FILE})"
    echo "  --matrix       Fetch the 30MHz RVV+VME bitstream (chip_nexus_matrix.bin)"
    echo "  --vector       Fetch the 50MHz RVV-only bitstream (chip_nexus_vector.bin)"
    echo "  -h, --help     Display this help message and exit"
    echo ""
    exit 1
}

while [[ "$#" -gt 0 ]]; do
    case "${1}" in
        -n|--limit)
            LIMIT="$2"; shift 2 ;;
        --target)
            TARGET_FILE="chip_${2}.bin"; shift 2 ;;
        --matrix)
            TARGET_FILE="chip_nexus_matrix.bin"; shift ;;
        --vector)
            TARGET_FILE="chip_nexus_vector.bin"; shift ;;
        -r|--ref)
            START_REF="$2"; shift 2 ;;
        -h|--help)
            usage ;;
        *)
            echo "Unknown option: $1"; usage ;;
    esac
done

if [[ -z "${START_REF}" ]]; then
    START_REF="HEAD"
    echo "[INFO] --ref not specified, searching for latest."
fi

# cd into project and find root via git
cd "$(dirname -- "${BASH_SOURCE[0]}")" || exit 1
# Verify Git history availability in project
if ! git rev-parse --is-inside-work-tree >/dev/null; then
    echo "Error: git not found or git history not available."
    exit 1
fi

PROJECT_ROOT=$(git rev-parse --show-toplevel)
cd "${PROJECT_ROOT}"

echo "Start Ref:    ${START_REF}"
echo "Search limit: ${LIMIT} commits"
echo "Target File:  ${TARGET_FILE}"
echo ""

mkdir -p "${PROJECT_ROOT}/fpga/bitstreams"

# Get list of changes that modified fpga/ or hdl/
SHAS=$(git log "${START_REF}" -n "${LIMIT}" --format="%H" -- fpga/ hdl/)

if [[ -z "${SHAS}" ]]; then
    echo "ERROR: No matching commits found in the history of ${START_REF} affecting fpga/ or hdl/."
    exit 1
fi

for SHA in ${SHAS}; do
    LAST_SHA="${SHA}"

    # Artifact Registry Generic format uses colons as delimiters.
    # In the HTTP REST API, these colons MUST be URL-encoded as %3A.
    URL="https://artifactregistry.googleapis.com/download/v1"
    URL+="/projects/${GCP_PROJECT}"
    URL+="/locations/${GCP_LOCATION}"
    URL+="/repositories/${AR_REPO}"
    URL+="/files/${AR_PACKAGE}%3A${SHA}%3A${TARGET_FILE}:download?alt=media"

    echo "Checking commit ${SHA:0:8}..."

    if curl -sL --fail -o "${PROJECT_ROOT}/fpga/bitstreams/${TARGET_FILE}" "${URL}"; then
        echo "SUCCESS: Found artifact for commit ${SHA}"
        echo "File saved as: ${PROJECT_ROOT}/fpga/bitstreams/${TARGET_FILE}"
        exit 0
    fi
done

echo "ERROR: No matching artifact found in the previous ${LIMIT} commits."
echo "The artifact might not have been built for these specific commits, or the build is still in progress."
echo ""
echo "To search further back, try increasing --limit or running:"
echo "  ${0} --ref ${LAST_SHA}^ --target ${TARGET_FILE}"
exit 1
