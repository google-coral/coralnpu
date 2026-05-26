#!/bin/bash
# firtool wrapper for Coral NPU (macOS)
# Located in tools/firtool/

DIR="$(cd "$(dirname "$0")" && pwd)"
exec "$DIR/org.chipsalliance/llvm-firtool/macos-x64/bin/firtool" "$@"
