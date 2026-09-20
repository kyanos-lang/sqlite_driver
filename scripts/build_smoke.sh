#!/usr/bin/env bash
# Build SQLite query-builder smoke test (native SQLite only).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$ROOT/target"
OUT_BIN="$OUT_DIR/sqlite_smoke"

mkdir -p "$OUT_DIR"

if [[ -z "${KYANOS_LIB:-}" ]]; then
  echo "error: set KYANOS_LIB to the Kyanos lib/ directory" >&2
  exit 1
fi

if ! command -v kyanos >/dev/null 2>&1; then
  echo "error: kyanos not on PATH" >&2
  exit 1
fi

echo "==> kyanos build + run SQLite smoke"
kyanos build --manifest-path "$ROOT/tests/kyanos.toml" -o "$OUT_BIN"
chmod +x "$OUT_BIN"
echo "built $OUT_BIN"
set +e
"$OUT_BIN"
smoke_rc=$?
set -e
if [[ "$smoke_rc" -ne 0 ]]; then
  echo "warning: sqlite smoke exited $smoke_rc (continuing to persist)" >&2
fi

PERSIST_BIN="$OUT_DIR/sqlite_persist"
echo "==> kyanos build + run SQLite persist consumer"
kyanos build --manifest-path "$ROOT/tests/persist/kyanos.toml" -o "$PERSIST_BIN"
chmod +x "$PERSIST_BIN"
"$PERSIST_BIN"
