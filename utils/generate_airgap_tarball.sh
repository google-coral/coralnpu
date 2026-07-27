#!/bin/bash
# Copyright 2024 Google LLC
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

## Generates a tar file or directory containing required artifacts to build and test CoralNPU without
# an internet connection.
# To use the artifacts, extract them to a known location (or use the generated directory), and use the --repository_cache
# arguments for Bazel.
# An example command which will build and test is as follows:
# bazel test --repository_cache=coralnpu_airgap_7d188ddd04e3ecd80527a41889e0c6175102af8b/bazel-cachedir \
#            --build_tag_filters="-verilator" --test_tag_filters="-verilator" //...
# Additionally, the bazel binary is included, in case
# it is not available on your system.

set -euo pipefail

CREATE_TAR=true

function usage {
    echo "Usage: $0 [options]"
    echo ""
    echo "Generates dependencies for building CoralNPU offline."
    echo ""
    echo "Options:"
    echo "  --tar       Create a tarball (default)"
    echo "  --no-tar    Leave artifacts in a directory instead of creating a tarball"
    echo "  -h, --help  Show this help message"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --tar)
            CREATE_TAR=true
            shift
            ;;
        --no-tar|--dir)
            CREATE_TAR=false
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

REPO_TOP="$(git rev-parse --show-toplevel)"
CORALNPU_VERSION="$(git rev-parse HEAD)"
BAZEL_VERSION="$(cat "${REPO_TOP}/.bazelversion")"
VENVDIR=$(mktemp -d)

if [[ "${CREATE_TAR}" == "true" ]]; then
    WORKDIR=$(mktemp -d)
else
    WORKDIR="${REPO_TOP}/coralnpu_airgap_${CORALNPU_VERSION}"
    if [[ -d "${WORKDIR}" ]]; then
        rm -rf "${WORKDIR}"
    fi
    mkdir -p "${WORKDIR}"
fi

function clean {
    if [[ "${CREATE_TAR}" == "true" && -n "${WORKDIR:-}" && -d "${WORKDIR}" ]]; then
        rm -rf "${WORKDIR}"
    fi
    if [[ -n "${VENVDIR:-}" && -d "${VENVDIR}" ]]; then
        rm -rf "${VENVDIR}"
    fi
}

trap clean EXIT

################################################################################
# Download Bazel
################################################################################

mkdir "${WORKDIR}/bazel-distdir"
cd "${WORKDIR}"
curl --location \
    "https://github.com/bazelbuild/bazel/releases/download/${BAZEL_VERSION}/bazel-${BAZEL_VERSION}-linux-x86_64" \
    --output "bazel-${BAZEL_VERSION}-linux-x86_64"
chmod +x "bazel-${BAZEL_VERSION}-linux-x86_64"
ln -s "bazel-${BAZEL_VERSION}-linux-x86_64" bazel

################################################################################
# Cache bazel deps for CoralNPU
################################################################################

cd "${REPO_TOP}"
mkdir "${WORKDIR}/bazel-cachedir"
"${WORKDIR}/bazel" clean --expunge
"${WORKDIR}/bazel" sync \
    --show_progress_rate_limit=30 \
    --repository_cache="${WORKDIR}/bazel-cachedir"

CORALNPU_MPACT_DIR="$("${WORKDIR}/bazel" info output_base)/external/coralnpu_mpact"
if [[ -d "${CORALNPU_MPACT_DIR}" ]]; then
    echo "Syncing coralnpu_mpact dependencies..."
    (cd "${CORALNPU_MPACT_DIR}" && "${WORKDIR}/bazel" sync \
        --show_progress_rate_limit=30 \
        --repository_cache="${WORKDIR}/bazel-cachedir" \
        --override_repository=coralnpu_hw="${REPO_TOP}") || true
fi

################################################################################
# Cache pip deps for CoralNPU
################################################################################

mkdir -p "${WORKDIR}/pip-cache"
python3.11 -m venv "${VENVDIR}"
# shellcheck disable=SC1091
source "${VENVDIR}/bin/activate"
echo "Querying for requirements files..."
OPENTITAN_REQS=$("${WORKDIR}/bazel" query @lowrisc_opentitan_gh//:python-requirements.txt --output=location 2>/dev/null | sed 's/:.*//')
TFLITE_REQS=$("${WORKDIR}/bazel" query @tflite_micro//third_party:python_requirements.txt --output=location 2>/dev/null | sed 's/:.*//')

if [[ -f "${OPENTITAN_REQS}" ]]; then
    echo "Downloading OpenTitan pip dependencies from ${OPENTITAN_REQS}..."
    # pass --no-deps to restrict download to only listed packages
    pip download --no-deps --require-hashes -r "${OPENTITAN_REQS}" -d "${WORKDIR}/pip-cache"
else
    echo "Warning: Could not find OpenTitan requirements file."
fi

if [[ -f "${TFLITE_REQS}" ]]; then
    echo "Downloading TFLite Micro pip dependencies from ${TFLITE_REQS}..."
    # pass --no-deps to restrict download to only listed packages
    pip download --no-deps --require-hashes -r "${TFLITE_REQS}" -d "${WORKDIR}/pip-cache"
else
    echo "Warning: Could not find TFLite Micro requirements file."
fi
deactivate

################################################################################
# Create bazel wrapper script
################################################################################

cat <<EOF >"${WORKDIR}/bazel.sh"
SCRIPT_DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
# Export variables for local usage and pass to Bazel for repository rules
export PIP_NO_INDEX=true
export PIP_FIND_LINKS="\${SCRIPT_DIR}/pip-cache"
export BAZEL_CACHE="\${SCRIPT_DIR}/bazel-cachedir"

\${SCRIPT_DIR}/bazel \$* \\
    --distdir=\${SCRIPT_DIR}/bazel-distdir \\
    --repository_cache=\${SCRIPT_DIR}/bazel-cachedir \\
    --repo_env=PIP_NO_INDEX=true \\
    --repo_env=PIP_FIND_LINKS="\${SCRIPT_DIR}/pip-cache" \\
    --repo_env=BAZEL_CACHE="\${SCRIPT_DIR}/bazel-cachedir" \\
    --test_tag_filters="-verilator" \\
    --build_tag_filters="-verilator"
EOF
chmod +x "${WORKDIR}/bazel.sh"

################################################################################
# Output artifacts
################################################################################

if [[ "${CREATE_TAR}" == "true" ]]; then
    TAR_PATH="${REPO_TOP}/coralnpu_airgap_${CORALNPU_VERSION}.tar"
    tar --transform="s|/|/coralnpu_airgap_${CORALNPU_VERSION}/|" -cf "${TAR_PATH}" -C "${WORKDIR}" .
    echo "Tarball containing dependencies for building CoralNPU offline is available at ${TAR_PATH}"
else
    echo "Directory containing dependencies for building CoralNPU offline is available at ${WORKDIR}"
fi
