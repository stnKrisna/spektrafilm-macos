#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
UPSTREAM="${1:-${SPEKTRAFILM_PYTHON_REPO:-}}"

if [[ -z "$UPSTREAM" ]]; then
  echo "usage: $0 /path/to/andreavolpato/spektrafilm" >&2
  echo "   or: SPEKTRAFILM_PYTHON_REPO=/path/to/repo $0" >&2
  exit 2
fi

python3 "$ROOT/Scripts/import-python-goldens.py" "$UPSTREAM"
cd "$ROOT"
SPEKTRAFILM_REQUIRE_GOLDENS=1 swift test --filter pythonGoldenRegressionFixtures
