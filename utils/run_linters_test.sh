#!/bin/bash

# A simple test suite for run_linters.sh
# This script creates a temporary git repository to simulate various scenarios.

set -u -o pipefail

# --- Setup ---
TEST_DIR=$(mktemp -d)
SCRIPT_PATH=$(readlink -f "$0")
SCRIPT_DIR=$(dirname "${SCRIPT_PATH}")
SCRIPT_UNDER_TEST="${SCRIPT_DIR}/run_linters.sh"
MOCK_BIN_DIR="${TEST_DIR}/bin"
mkdir -p "${MOCK_BIN_DIR}"

# Add mock bin to PATH so the script finds our dummy linters
export PATH="${MOCK_BIN_DIR}:${PATH}"

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# --- Helpers ---

setup_repo() {
    local repo_dir
    repo_dir=$(mktemp -d -p "${TEST_DIR}" repo_XXXXXX)
    cd "${repo_dir}" || exit 1

    git init -q
    git config user.email "test@example.com"
    git config user.name "Test User"

    # Create initial commit on main
    echo "initial" > README.md
    git add README.md
    git commit -q -m "initial commit"
    git branch -m main

    # Create a dummy remote
    local remote_dir
    remote_dir=$(mktemp -d -p "${TEST_DIR}" remote_XXXXXX)
    cd "${remote_dir}" || exit 1
    git init -q --bare

    cd "${repo_dir}" || exit 1
    git remote add origin "${remote_dir}"
    git push -q origin main
    git remote set-head origin main
}

mock_linter() {
    local name="$1"
    cat > "${MOCK_BIN_DIR}/${name}" <<EOF
#!/bin/bash
echo "MOCK: ${name} running on \$*"
exit 0
EOF
    chmod +x "${MOCK_BIN_DIR}/${name}"
}

mock_failing_linter() {
    local name="$1"
    cat > "${MOCK_BIN_DIR}/${name}" <<EOF
#!/bin/bash
echo "MOCK FAILURE: ${name}"
exit 1
EOF
    chmod +x "${MOCK_BIN_DIR}/${name}"
}

# Mock all required linters
mock_linter "yapf"
mock_linter "buildifier"
mock_linter "verible-verilog-lint"
mock_linter "verible-verilog-format"
mock_linter "verible-verilog-syntax"
mock_linter "clang-tidy"
mock_linter "clang-format"
mock_linter "clang-format-19"
mock_linter "git-clang-format-19"
mock_linter "scalafmt"
mock_linter "shellcheck"

# Run a test case
run_test() {
    local name="$1"
    local env_vars="$2"
    local args="$3"
    local stdin_file="${4:-/dev/null}"
    local expected_status="${5:-0}"
    local expected_output_pattern="${6:-}"

    echo -e "Testing: ${name}..."

    local output
    # shellcheck disable=SC2086
    output=$(eval "${env_vars} bash ${SCRIPT_UNDER_TEST} ${args} < ${stdin_file} 2>&1")
    local status=$?

    if [[ ${status} -eq "${expected_status}" ]]; then
        if [[ -n "${expected_output_pattern}" ]] && [[ ! "${output}" =~ ${expected_output_pattern} ]]; then
            echo -e "  ${RED}FAIL${NC} (Output pattern mismatch)"
            echo "--- Output ---"
            echo "${output}"
            echo "Expected pattern (regex): ${expected_output_pattern}"
            echo "--------------"
            return 1
        fi
        echo -e "  ${GREEN}PASS${NC}"
        return 0
    else
        echo -e "  ${RED}FAIL${NC} (Status: ${status}, Expected: ${expected_status})"
        echo "--- Output ---"
        echo "${output}"
        echo "--------------"
        return 1
    fi
}

# --- Test Cases ---

FAILED_TESTS=0

# 1. Local changes
setup_repo
echo "print('hello')" > test.py
echo "int main() {}" > test.cc
git add test.py test.cc
run_test "Local Staged Changes" "" "" "/dev/null" 0 "MOCK: git-clang-format-19 running on --binary clang-format-19 --diff origin/main.*test.cc" || FAILED_TESTS=$((FAILED_TESTS + 1))

# 2. --all flag
setup_repo
echo "print('hello')" > test.py
echo "int main() {}" > test.cc
git add test.py test.cc
git commit -q -m "add files"
run_test "Manual --all" "" "--all" "/dev/null" 0 "MOCK: clang-format-19 running on --dry-run --Werror.*test.cc" || FAILED_TESTS=$((FAILED_TESTS + 1))

# 3. Specific targets
setup_repo
mkdir subdir
echo "echo hi" > subdir/test.sh
echo "int main() {}" > subdir/test.cc
run_test "Specific Directory" "" "subdir" "/dev/null" 0 "MOCK: clang-format-19 running on --dry-run --Werror.*subdir/test.cc" || FAILED_TESTS=$((FAILED_TESTS + 1))

# 4. GitHub Actions Emulation (PR)
setup_repo
git checkout -q -b my-feature
echo "echo hi" > feat.sh
echo "int main() {}" > feat.cc
git add feat.sh feat.cc
git commit -q -m "feat"
run_test "GitHub Actions PR" "GITHUB_ACTIONS=true GITHUB_EVENT_NAME=pull_request GITHUB_BASE_REF=main" "" "/dev/null" 0 "MOCK: git-clang-format-19 running on --binary clang-format-19 --diff origin/main.*feat.cc" || FAILED_TESTS=$((FAILED_TESTS + 1))

# 5. Pre-push Hook Emulation
setup_repo
git checkout -q -b hook-test
echo "echo hook" > hook.sh
echo "int main() {}" > hook.cc
git add hook.sh hook.cc
git commit -q -m "hook commit"
LOCAL_SHA=$(git rev-parse HEAD)
REMOTE_SHA=$(git rev-parse main)
echo "refs/heads/hook-test ${LOCAL_SHA} refs/heads/hook-test ${REMOTE_SHA}" > "${TEST_DIR}/stdin_mock"
run_test "Pre-push Hook" "" "" "${TEST_DIR}/stdin_mock" 0 "MOCK: git-clang-format-19 running on --binary clang-format-19 --diff ${REMOTE_SHA}.*hook.cc" || FAILED_TESTS=$((FAILED_TESTS + 1))

# 6. Deduplication Check
setup_repo
echo "echo dedup" > dedup.sh
git add dedup.sh
run_test "Deduplication" "" "" || FAILED_TESTS=$((FAILED_TESTS + 1))

# 7. No relevant files
setup_repo
echo "just text" > doc.txt
git add doc.txt
run_test "No relevant files" "" "" "/dev/null" 0 || FAILED_TESTS=$((FAILED_TESTS + 1))

# 8. Filenames with spaces
setup_repo
echo "echo spaces" > "file with spaces.sh"
git add "file with spaces.sh"
run_test "Spaces in Filenames" "" "" || FAILED_TESTS=$((FAILED_TESTS + 1))

# 9. Linter Failure Propagation
setup_repo
mock_failing_linter "shellcheck"
echo "echo failing" > fail.sh
git add fail.sh
run_test "Linter Failure" "" "" "/dev/null" 1 || FAILED_TESTS=$((FAILED_TESTS + 1))
mock_linter "shellcheck" # Reset to passing

# 10. Branch Deletion in Pre-push
setup_repo
ZERO="0000000000000000000000000000000000000000"
echo "refs/heads/delete ${ZERO} refs/heads/delete ${ZERO}" > "${TEST_DIR}/stdin_delete"
run_test "Pre-push Deletion" "" "" "${TEST_DIR}/stdin_delete" 0 || FAILED_TESTS=$((FAILED_TESTS + 1))

# 11. Mixed Routing
setup_repo
echo "import os" > a.py
echo "module m;" > b.sv
git add a.py b.sv
echo -e "Testing: Mixed Routing..."
OUTPUT=$(bash "${SCRIPT_UNDER_TEST}" 2>&1)
if [[ "${OUTPUT}" == *"Running yapf"* ]] && [[ "${OUTPUT}" == *"Running verible-verilog-lint"* ]]; then
    echo -e "  ${GREEN}PASS${NC}"
else
    echo -e "  ${RED}FAIL${NC}"
    echo "${OUTPUT}"
    FAILED_TESTS=$((FAILED_TESTS + 1))
fi

# 12. Ignore Patterns
setup_repo
mkdir -p hdl/verilog/rvv
echo "module ignored;" > hdl/verilog/rvv/core.sv
echo "module included;" > hdl/verilog/top.sv
git add hdl/verilog/rvv/core.sv hdl/verilog/top.sv
echo -e "Testing: Ignore Patterns..."
OUTPUT=$(bash "${SCRIPT_UNDER_TEST}" 2>&1)
# We expect only 1 file to be linted by verible-verilog-lint (top.sv)
if [[ "${OUTPUT}" == *"Running verible-verilog-lint on 1 file(s)"* ]]; then
    echo -e "  ${GREEN}PASS${NC}"
else
    echo -e "  ${RED}FAIL${NC}"
    echo "${OUTPUT}"
    FAILED_TESTS=$((FAILED_TESTS + 1))
fi

# 13. --fix flag (Target file, buildifier)
setup_repo
echo "# build file" > BUILD
run_test "Fix mode buildifier" "" "--fix BUILD" "/dev/null" 0 "MOCK: buildifier running on -mode=fix.*BUILD" || FAILED_TESTS=$((FAILED_TESTS + 1))

# 14. --fix flag (Local Staged Changes, diff mode git-clang-format-19)
setup_repo
echo "int main() {}" > test.cc
git add test.cc
run_test "Fix mode diff git-clang-format" "" "--fix" "/dev/null" 0 "MOCK: git-clang-format-19 running on --binary clang-format-19 origin/main.*test.cc" || FAILED_TESTS=$((FAILED_TESTS + 1))

# 15. --fix --all flags (clang-format -i)
setup_repo
echo "int main() {}" > test.cc
git add test.cc
git commit -q -m "add test.cc"
run_test "Fix mode --all clang-format" "" "--fix --all" "/dev/null" 0 "MOCK: clang-format-19 running on -i.*test.cc" || FAILED_TESTS=$((FAILED_TESTS + 1))

# --- Summary ---

echo ""
if [[ ${FAILED_TESTS} -eq 0 ]]; then
    echo -e "${GREEN}All tests passed!${NC}"
    rm -rf "${TEST_DIR}"
    exit 0
else
    echo -e "${RED}${FAILED_TESTS} test(s) failed.${NC}"
    echo "Test directory preserved at: ${TEST_DIR}"
    exit 1
fi
