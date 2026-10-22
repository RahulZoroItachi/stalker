#!/bin/bash
# Build from a clone and install. Idempotent, safe to re-run.
#
# This is a thin wrapper. Everything per-user — the signing certificate, the
# directories, the rules file, the shell hook, the launchd agents — lives in
# `stalker setup`, so it exists once rather than in two places that drift apart.
# Friends installing through Homebrew get the same `setup`; only this build step
# is specific to working from a clone.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Note: "~/..." inside double quotes does NOT expand. Always use "$HOME/...".
BIN_DIR="$HOME/.local/bin"
BINARY="$BIN_DIR/stalker"

echo "1. building"
cd "$REPO"
swift build -c release
mkdir -p "$BIN_DIR"
cp "$(swift build -c release --show-bin-path)/stalker" "$BINARY"
echo "   installed $BINARY"

echo "2. handing over to setup"
# --support-dir because from a clone the support files are in the repository, not
# in the share directory beside an installed binary.
exec "$BINARY" setup --support-dir "$REPO/scripts"
