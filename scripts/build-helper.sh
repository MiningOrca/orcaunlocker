#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

cargo build \
  --manifest-path "$ROOT/helper/Cargo.toml" \
  --locked \
  --release

HELPER="$ROOT/helper/target/release/miningorca-steam-helper"

echo
echo "Helper: $HELPER"
ls -lh "$HELPER"
