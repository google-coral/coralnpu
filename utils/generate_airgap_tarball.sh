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
# To use the artifacts, extract them to a known location (or use the generated directory), and use the --vendor_dir
# arguments for Bazel.
# An example command which will build and test is as follows:
# bazel test --vendor_dir=coralnpu_airgap_7d188ddd04e3ecd80527a41889e0c6175102af8b/vendor \
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
}

trap clean EXIT

################################################################################
# Download Bazel
################################################################################

cd "${WORKDIR}"
curl --location \
    "https://github.com/bazelbuild/bazel/releases/download/${BAZEL_VERSION}/bazel-${BAZEL_VERSION}-linux-x86_64" \
    --output "bazel-${BAZEL_VERSION}-linux-x86_64"
chmod +x "bazel-${BAZEL_VERSION}-linux-x86_64"
ln -s "bazel-${BAZEL_VERSION}-linux-x86_64" bazel

################################################################################
# Vendor external dependencies for CoralNPU
################################################################################

cd "${REPO_TOP}"
mkdir -p "${WORKDIR}/vendor"
"${WORKDIR}/bazel" vendor \
    --vendor_dir="${WORKDIR}/vendor" \
    //...

# Pin all vendored repositories in VENDOR.bazel so Bazel uses them offline
# unconditionally without checking marker files or attempting network re-fetches.
# Ignore non-hermetic local tool detection repositories so they evaluate dynamically
# against the runner's installed tools (e.g. Vivado).
for repo in "${WORKDIR}/vendor/"*/; do
    repo_name="$(basename "${repo}")"
    if [[ "${repo_name}" != "bazel-external" && -d "${repo}" ]]; then
        if [[ "${repo_name}" == *"nonhermetic"* ]]; then
            rm -rf "${repo}"
            echo "ignore(\"@@${repo_name}\")" >> "${WORKDIR}/vendor/VENDOR.bazel"
        else
            echo "pin(\"@@${repo_name}\")" >> "${WORKDIR}/vendor/VENDOR.bazel"
        fi
    fi
done
echo "ignore(\"@@nonhermetic\")" >> "${WORKDIR}/vendor/VENDOR.bazel"
echo "ignore(\"@@+coralnpu_deps_ext+nonhermetic\")" >> "${WORKDIR}/vendor/VENDOR.bazel"
rm -f "${WORKDIR}/vendor/bazel-external"
chmod -R a+rX "${WORKDIR}/vendor"

################################################################################
# Create bazel wrapper script
################################################################################

cat <<EOF >"${WORKDIR}/bazel.sh"
SCRIPT_DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"

\${SCRIPT_DIR}/bazel \$* \\
    --vendor_dir="\${SCRIPT_DIR}/vendor" \\
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
