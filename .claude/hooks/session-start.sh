#!/bin/bash
# SessionStart hook for Claude Code cloud sessions: installs what the CI image
# (utils/coralnpu.dockerfile) provides and this container lacks, so Bazel
# builds, cocotb tests and utils/run_linters.sh work. Safe to run repeatedly.
set -euo pipefail

if [[ "${CLAUDE_CODE_REMOTE:-}" != "true" ]]; then
  exit 0
fi

project_dir=${CLAUDE_PROJECT_DIR:-}
if [[ -z "${project_dir}" ]]; then
  project_dir=$(git rev-parse --show-toplevel)
fi
cd "${project_dir}"

# System packages from the CI image that builds need (liblz4-dev: Verilator's
# FST writer) plus the linters run_linters.sh calls.
packages=(
  autoconf build-essential ccache cmake device-tree-compiler gawk libelf-dev
  libftdi1-dev liblz4-dev libmpfr-dev libusb-1.0-0-dev ninja-build python3-numpy
  srecord unzip xxd zip yapf3 shellcheck shfmt markdownlint
)
missing=()
for p in "${packages[@]}"; do
  dpkg -s "${p}" >/dev/null 2>&1 || missing+=("${p}")
done
if ((${#missing[@]})); then
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}"
fi

# Ubuntu's yapf3 imports lib2to3, which Python 3.13 no longer ships. Where the
# default python3 is 3.13, run the same yapf with Python 3.12.
if ! yapf3 --version >/dev/null 2>&1 && command -v python3.12 >/dev/null 2>&1; then
  printf '#!/bin/sh\nexec python3.12 -m yapf "$@"\n' >/usr/local/bin/yapf3
  chmod +x /usr/local/bin/yapf3
fi

# Bazel via bazelisk (the version comes from .bazelversion). Fetch Bazel from
# GitHub releases, which stays reachable where releases.bazel.build is blocked.
if ! command -v bazel >/dev/null 2>&1; then
  npm install -g @bazel/bazelisk@1.25.0 >/dev/null
fi
if [[ -n "${CLAUDE_ENV_FILE:-}" ]]; then
  echo 'export BAZELISK_BASE_URL=https://github.com/bazelbuild/bazel/releases/download' >>"${CLAUDE_ENV_FILE}"
fi

# Lint tools pinned as in the CI image.
tmp=$(mktemp -d)
trap 'rm -rf "${tmp}"' EXIT
if ! command -v buildifier >/dev/null 2>&1; then
  curl -fsSL -o "${tmp}/buildifier" \
    https://github.com/bazelbuild/buildtools/releases/download/v7.3.1/buildifier-linux-amd64
  echo "5474cc5128a74e806783d54081f581662c4be8ae65022f557e9281ed5dc88009  ${tmp}/buildifier" | sha256sum --check --quiet -
  install "${tmp}/buildifier" /usr/local/bin
fi
if ! command -v verible-verilog-format >/dev/null 2>&1; then
  curl -fsSL -o "${tmp}/verible.tar.gz" \
    https://github.com/chipsalliance/verible/releases/download/v0.0-4051-g9fdb4057/verible-v0.0-4051-g9fdb4057-linux-static-x86_64.tar.gz
  echo "f52e5920ef63f70620a6086e09dea8bd778147cd7a9ff827bb7de5d6316b1754  ${tmp}/verible.tar.gz" | sha256sum --check --quiet -
  mkdir -p "${tmp}/verible"
  tar -xf "${tmp}/verible.tar.gz" --strip-components=1 -C "${tmp}/verible"
  install "${tmp}"/verible/bin/verible-verilog-* /usr/local/bin
fi

# Where github.com/<owner>/<repo>/archive/* downloads are blocked, rebuild the
# .tar.gz dependencies from git into Bazel's repository cache (sha256 is still
# checked; build with --bazelrc=utils/cloud_session/cloud.bazelrc).
# See utils/cloud_session/README.md for the .zip dependencies.
probe=https://github.com/accellera-official/systemc/archive/refs/tags/2.3.4.tar.gz
code=$(curl -s -o /dev/null -w '%{http_code}' -L --max-time 30 "${probe}" || true)
if [[ "${code}" != "200" ]]; then
  echo "GitHub archive downloads return ${code}; seeding the Bazel repository cache from git." >&2
  python3 -I utils/cloud_session/fill_gh_archives.py --repo . >&2
fi
