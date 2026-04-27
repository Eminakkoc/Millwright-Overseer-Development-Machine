#!/usr/bin/env bash
# uuid.sh — generate a single UUID v4 and print it to stdout.
# Usage: uuid.sh

set -euo pipefail

# Prefer system uuidgen (BSD/macOS/Linux); fall back to Python.
if command -v uuidgen >/dev/null 2>&1; then
  uuidgen | tr '[:upper:]' '[:lower:]'
elif command -v python3 >/dev/null 2>&1; then
  python3 -c "import uuid; print(uuid.uuid4())"
else
  echo "error: need uuidgen or python3 to generate UUIDs" >&2
  exit 2
fi
