#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

/bin/bash -n "$ROOT"/scripts/*.sh

cargo test \
  --manifest-path "$ROOT/helper/Cargo.toml" \
  --locked

"$ROOT/scripts/build-helper.sh"

swift build

BIN_DIR="$(swift build --show-bin-path)"
"$BIN_DIR/orcaunlocker" --help >/dev/null
"$BIN_DIR/orcaunlocker" apply --help | /usr/bin/grep -q -- "--transport"

MININGORCA_STEAM_HELPER="$ROOT/helper/target/release/miningorca-steam-helper" \
  swift test --no-parallel
