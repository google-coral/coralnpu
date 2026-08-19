#!/bin/bash
# shellcheck disable=SC2312

set -eu -o pipefail

# Change to the repository root to ensure all relative paths (configs and files)
# resolve correctly regardless of where the script is invoked from.
REPO_ROOT=$(git rev-parse --show-toplevel)
cd "${REPO_ROOT}"

# --- Configuration ---
# Use BASE_BRANCH if set, otherwise we will attempt to detect it.
BASE_BRANCH=${BASE_BRANCH:-""}

# TODO: enable linters as we clean up the codebase
# Define linters: [name]="command and flags"
declare -A LINTER_COMMANDS=(
    ["yapf"]="yapf3 --diff"
    ["buildifier"]="buildifier -mode=check"
    ["verible-verilog-lint"]="true" #  "verible-verilog-lint"
    ["verible-verilog-format"]="verible-verilog-format --verify --inplace"
    # ["clang-tidy"]="clang-tidy" # Pending compilation database
    ["clang-format"]="clang-format-19 --dry-run --Werror"
    ["scalafmt"]="scalafmt --config .scalafmt --test"
    ["shellcheck"]="shellcheck -x"
    ["markdownlint"]="mdl --no-verbose"
)

# Define fix mode commands: [name]="command and flags"
declare -A LINTER_FIX_COMMANDS=(
    ["yapf"]="yapf3 -i"
    ["buildifier"]="buildifier -mode=fix"
    ["verible-verilog-format"]="verible-verilog-format --inplace"
    # ["clang-tidy"]="clang-tidy -fix" # Pending compilation database
    ["clang-format"]="clang-format-19 -i"
    ["scalafmt"]="scalafmt --config .scalafmt"
)

# Define diff-aware linters: [name]="command and flags"
# Use %BASE% as placeholder for the base commit/branch
declare -A LINTER_DIFF_COMMANDS=(
    ["clang-format"]="git-clang-format-19 --binary clang-format-19 --diff %BASE%"
    # ["clang-tidy"]="git diff -U0 %BASE% -- | clang-tidy-diff.py -p1"
)

# Define diff-aware fix commands: [name]="command and flags"
# Use %BASE% as placeholder for the base commit/branch
declare -A LINTER_DIFF_FIX_COMMANDS=(
    ["clang-format"]="git-clang-format-19 --binary clang-format-19 %BASE%"
    # ["clang-tidy"]="git diff -U0 %BASE% -- | clang-tidy-diff.py -fix -p1"
)


# Define file patterns for each linter
declare -A LINTER_REGEX=(
    ["yapf"]='\.py$'
    ["buildifier"]='(BUILD(\.bazel)?|\.bzl|WORKSPACE)$'
    ["verible-verilog-lint"]='\.s?v$'
    ["verible-verilog-format"]='\.s?v$'
    # ["clang-tidy"]='\.(c|cc|cpp|h|hpp)$'
    ["clang-format"]='\.(c|cc|cpp|h|hpp)$'
    ["scalafmt"]='\.scala$'
    ["shellcheck"]='\.(sh|bash)$'
    ["markdownlint"]='\.md$'
)

# Define ignore patterns for each linter (exclusive)
declare -A LINTER_IGNORE_REGEX=(
    ["verible-verilog-lint"]='hdl/verilog/rvv/'
    ["verible-verilog-format"]='hdl/verilog/rvv/'
)


# --- Initialization ---
declare -A ALL_FILES=()
LINT_TMP=$(mktemp -d)
trap 'rm -rf "$LINT_TMP"' EXIT

# --- Functions ---

log() {
    echo "▶️  $1"
}

info() {
    echo "   $1"
}

# Add a file to the processing queue with deduplication and ignore checks
add_file() {
    local file="$1"

    # Global deduplication: skip if we've already processed this file
    if [[ -n "${ALL_FILES["${file}"]:-}" ]]; then
        return
    fi

    if [[ -f "${file}" ]]; then
        # Mark as seen
        ALL_FILES["${file}"]=1
        for linter in "${!LINTER_REGEX[@]}"; do
            if [[ "${file}" =~ ${LINTER_REGEX[${linter}]} ]]; then
                # Check for ignore pattern
                local ignore_pattern="${LINTER_IGNORE_REGEX[${linter}]:-}"
                if [[ -n "${ignore_pattern}" ]] && [[ "${file}" =~ ${ignore_pattern} ]]; then
                    continue
                fi

                # Store filenames in a per-linter file in the temp dir
                echo "${file}" >> "${LINT_TMP}/${linter}"
            fi
        done
    fi
}

gather_diff() {
    local range="$1"
    while IFS= read -r -d '' file; do
        add_file "${file}"
    done < <(git diff -z --name-only "${range}" 2>/dev/null)
}

gather_targets() {
    for arg in "$@"; do
        if [[ -d "${arg}" ]]; then
            while IFS= read -r -d '' file; do
                add_file "${file}"
            done < <(find "${arg}" -type f -print0)
        else
            add_file "${arg}"
        fi
    done
}

detect_base_branch() {
    # 1. Use BASE_BRANCH if it was explicitly provided and exists
    if [[ -n "${BASE_BRANCH}" ]] && git rev-parse --verify "${BASE_BRANCH}" >/dev/null 2>&1; then
        echo "${BASE_BRANCH}"
        return
    fi

    # 2. Try to detect the default branch from remotes (e.g., origin/HEAD)
    local remote
    for remote in $(git remote); do
        local rhead
        rhead=$(git rev-parse --abbrev-ref "${remote}/HEAD" 2>/dev/null || true)
        # If rhead is valid and not just the literal string "$remote/HEAD"
        if [[ -n "${rhead}" && "${rhead}" != "${remote}/HEAD" ]]; then
            echo "${rhead}"
            return
        fi
    done

    # 3. Fallback to common branch names
    for b in "origin/main" "origin/master" "main" "master" "m/main" "m/master"; do
        if git rev-parse --verify "${b}" >/dev/null 2>&1; then
            echo "${b}"
            return
        fi
    done

    # 4. Final fallback
    echo "HEAD"
}

# --- Argument Parsing ---
FIX_MODE=false
ALL_MODE=false
TARGET_ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --fix)
            FIX_MODE=true
            shift
            ;;
        --all)
            ALL_MODE=true
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [--fix] [--all] [file/dir ...]"
            echo ""
            echo "By default (when no targets or --all are specified), this script lints all local"
            echo "changes (staged and unstaged) relative to the base branch (${BASE_BRANCH:-auto-detected})."
            echo ""
            echo "Options:"
            echo "  --fix       Fix formatting and lint issues where supported"
            echo "  --all       Lint all tracked files across the repository"
            echo "  -h, --help  Show this help message and exit"
            exit 0
            ;;
        -*)
            echo "Unknown option: $1" >&2
            exit 2
            ;;
        *)
            TARGET_ARGS+=("$1")
            shift
            ;;
    esac
done

# --- Environment Detection & File Gathering ---
DETECTED_BASE=$(detect_base_branch)
IS_DIFF_LINT=true
LINT_BASE="${DETECTED_BASE}"

# 1. Manual: Check for explicit --all flag
if [[ "${ALL_MODE}" == "true" ]]; then
    log "Manual: Linting all tracked files (--all)"
    IS_DIFF_LINT=false
    while IFS= read -r -d '' file; do
        add_file "${file}"
    done < <(git ls-files -z)

# 2. GitHub Actions
elif [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
    log "CI: GitHub Actions Detected"
    if [[ "${GITHUB_EVENT_NAME:-}" == "pull_request" ]]; then
        info "Event: Pull Request (Base: ${GITHUB_BASE_REF:-})"
        LINT_BASE="origin/${GITHUB_BASE_REF}"
        RANGE="origin/${GITHUB_BASE_REF}...HEAD"
    else
        info "Event: ${GITHUB_EVENT_NAME:-unknown}"
        RANGE="${LINT_BASE}...HEAD"
    fi
    gather_diff "${RANGE}"

# 3. Generic CI
elif [[ "${CI:-}" == "true" ]]; then
    log "CI: Generic CI Detected"
    gather_diff "${LINT_BASE}...HEAD"

# 4. Git Hook (Stdin is piped)
# hooks pass arguments (remote name/URL) that are NOT files to lint.
elif [[ ! -t 0 ]]; then
    if read -t 0.1 -r _ local_sha _ remote_sha; then
        log "Git Hook: Pre-push Detected"
        if [[ "${local_sha}" = "0000000000000000000000000000000000000000" ]]; then
            info "Branch deletion detected. Skipping."
            exit 0
        fi
        if [[ "${remote_sha}" = "0000000000000000000000000000000000000000" ]]; then
            info "New branch detected. Comparing against base."
            RANGE="${DETECTED_BASE}..HEAD"
        else
            LINT_BASE="${remote_sha}"
            RANGE="${remote_sha}..${local_sha}"
        fi
        gather_diff "${RANGE}"
    else
        if [[ ${#TARGET_ARGS[@]} -gt 0 ]]; then
            log "Manual: Linting specific targets (Non-TTY)"
            IS_DIFF_LINT=false
            gather_targets "${TARGET_ARGS[@]}"
        else
            log "Manual: Local Changes Detected (Non-TTY)"
            gather_diff "${DETECTED_BASE}...HEAD"
            while IFS= read -r -d '' file; do add_file "${file}"; done < <(git diff -z --name-only HEAD)
        fi
    fi

# 5. Manual: Check for specific file/directory arguments
elif [[ ${#TARGET_ARGS[@]} -gt 0 ]]; then
    log "Manual: Linting specific targets"
    IS_DIFF_LINT=false
    gather_targets "${TARGET_ARGS[@]}"

# 6. Default: Local changes
else
    log "Manual: Local Changes Detected"
    info "Comparing against ${LINT_BASE}"
    gather_diff "${LINT_BASE}...HEAD"
    while IFS= read -r -d '' file; do
        add_file "${file}";
        done < <(git diff -z --name-only HEAD)
fi

# --- Execution ---

TOTAL_FAILED=0

# Iterate through linter files in alphabetical order
shopt -s nullglob
LINTER_FILES=("${LINT_TMP}"/*)
shopt -u nullglob

if [[ ${#LINTER_FILES[@]} -eq 0 ]]; then
    echo "✅ No relevant files changed. Skipping linters."
    exit 0
fi

# Sort the files for consistent output
mapfile -t LINTER_FILES_SORTED < <(printf '%s\n' "${LINTER_FILES[@]}" | sort)

for linter_file in "${LINTER_FILES_SORTED[@]}"; do
    linter=$(basename "${linter_file}")
    num_files=$(wc -l < "${linter_file}")
    echo "🔍 Running ${linter} on ${num_files} file(s)..."

    cmd_str=""
    if [[ "${FIX_MODE}" == "true" ]]; then
        if [[ "${IS_DIFF_LINT}" == "true" ]] && [[ -n "${LINTER_DIFF_FIX_COMMANDS[${linter}]:-}" ]]; then
            cmd_str="${LINTER_DIFF_FIX_COMMANDS[${linter}]}"
        elif [[ -n "${LINTER_FIX_COMMANDS[${linter}]:-}" ]]; then
            cmd_str="${LINTER_FIX_COMMANDS[${linter}]}"
        fi
    fi

    if [[ -z "${cmd_str}" ]] && [[ "${IS_DIFF_LINT}" == "true" ]] && [[ -n "${LINTER_DIFF_COMMANDS[${linter}]:-}" ]]; then
        cmd_str="${LINTER_DIFF_COMMANDS[${linter}]}"
    fi

    if [[ -z "${cmd_str}" ]]; then
        cmd_str="${LINTER_COMMANDS[${linter}]}"
    fi

    if [[ -n "${cmd_str}" ]]; then
        cmd_str="${cmd_str//%BASE%/${LINT_BASE}}"
    fi

    if [[ "${cmd_str}" == *"|"* ]]; then
        if ! bash -c "xargs -r -d '\n' -a \"${linter_file}\" ${cmd_str}"; then
            echo "❌ ${linter} failed."
            TOTAL_FAILED=$((TOTAL_FAILED + 1))
        fi
    else
        read -r -a cmd_arr <<< "${cmd_str}"
        if ! xargs -r -d '\n' -a "${linter_file}" "${cmd_arr[@]}"; then
            echo "❌ ${linter} failed."
            TOTAL_FAILED=$((TOTAL_FAILED + 1))
        fi
    fi
done

if [[ "${TOTAL_FAILED}" -ne 0 ]]; then
    echo "❌ ${TOTAL_FAILED} linter(s) failed. Please fix the issues above."
    exit 1
else
    echo "✨ All linters passed successfully!"
    exit 0
fi
