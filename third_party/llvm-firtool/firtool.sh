#!/bin/bash
# firtool wrapper — finds the platform-appropriate binary

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Try macOS first, then Linux
for plat in macos-x64 linux-x64; do
  FIRTOOL_EXE=$(find "$SCRIPT_DIR" "$SCRIPT_DIR/../../tools/firtool" -name firtool -ipath "*${plat}*" -print -quit 2>/dev/null)
  if [ -n "$FIRTOOL_EXE" ] && [ -x "$FIRTOOL_EXE" ]; then
    exec "$FIRTOOL_EXE" "$@"
  fi
done

echo "ERROR: firtool binary not found" >&2
exit 1
