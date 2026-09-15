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

set -eu -o pipefail

REPO_ROOT=$(git rev-parse --show-toplevel)
cd "${REPO_ROOT}"

TMP_DIR=$(mktemp -d)
trap 'rm -rf "${TMP_DIR}"' EXIT

BAZEL_QUERY_FLAGS=(
    "--noshow_progress"
    "--ui_event_filters=-info,-warning"
)

# 1. Compare target sets for main repository (excluding nested @netlist_test)
if ! bazel query "${BAZEL_QUERY_FLAGS[@]}" --config=workspace '//...' --output=label 2>"${TMP_DIR}/ws_query.err" | sort > "${TMP_DIR}/ws_targets.txt"; then
    echo "❌ ERROR: 'bazel query --config=workspace //...' failed:" >&2
    cat "${TMP_DIR}/ws_query.err" >&2
    exit 1
fi

if ! bazel query "${BAZEL_QUERY_FLAGS[@]}" --config=bzlmod '//...' --output=label 2>"${TMP_DIR}/bm_query.err" | grep -v '^//internal/netlist_test' | sort > "${TMP_DIR}/bm_targets.txt"; then
    echo "❌ ERROR: 'bazel query --config=bzlmod //...' failed:" >&2
    cat "${TMP_DIR}/bm_query.err" >&2
    exit 1
fi

if ! diff -u "${TMP_DIR}/ws_targets.txt" "${TMP_DIR}/bm_targets.txt" > "${TMP_DIR}/root_diff.txt"; then
    echo "❌ ERROR: Target divergence detected between WORKSPACE and Bzlmod:" >&2
    cat "${TMP_DIR}/root_diff.txt" >&2
    exit 1
fi

# 2. Compare target sets for nested @netlist_test repository (if present)
if [[ -d "${REPO_ROOT}/internal/netlist_test" ]]; then
    if ! bazel query "${BAZEL_QUERY_FLAGS[@]}" --config=workspace '@netlist_test//...' --output=label 2>"${TMP_DIR}/ws_nl_query.err" | sort > "${TMP_DIR}/ws_netlist.txt"; then
        echo "❌ ERROR: 'bazel query --config=workspace @netlist_test//...' failed:" >&2
        cat "${TMP_DIR}/ws_nl_query.err" >&2
        exit 1
    fi

    if ! bazel query "${BAZEL_QUERY_FLAGS[@]}" --config=bzlmod '@netlist_test//...' --output=label 2>"${TMP_DIR}/bm_nl_query.err" | sort > "${TMP_DIR}/bm_netlist.txt"; then
        echo "❌ ERROR: 'bazel query --config=bzlmod @netlist_test//...' failed:" >&2
        cat "${TMP_DIR}/bm_nl_query.err" >&2
        exit 1
    fi

    if ! diff -u "${TMP_DIR}/ws_netlist.txt" "${TMP_DIR}/bm_netlist.txt" > "${TMP_DIR}/netlist_diff.txt"; then
        echo "❌ ERROR: @netlist_test divergence detected between WORKSPACE and Bzlmod:" >&2
        cat "${TMP_DIR}/netlist_diff.txt" >&2
        exit 1
    fi
fi
