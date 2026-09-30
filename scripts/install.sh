#!/bin/bash
# Idempotent installer. Safe to re-run.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Note: "~/..." inside double quotes does NOT expand. Always use "$HOME/...".
DATA_DIR="$HOME/Library/Application Support/stalker"
CONFIG_DIR="$HOME/.config/stalker"
BIN_DIR="$HOME/.local/bin"
BINARY="$BIN_DIR/stalker"
SIGN_IDENTITY="stalker-dev"
PLIST="$HOME/Library/LaunchAgents/stalker.sample.plist"

echo "1. building"
cd "$REPO"
swift build -c release
mkdir -p "$BIN_DIR"
cp "$(swift build -c release --show-bin-path)/stalker" "$BINARY"

# A stable signing identity is what keeps the Accessibility grant alive across
# rebuilds. Swift's default is an ad-hoc signature, whose designated requirement
# is the code hash — so every build produces a binary TCC treats as a different
# program, while the entry in System Settings goes on reading as enabled. Signing
# with a certificate makes the requirement "identifier + this leaf cert", which
# every later build still satisfies.
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGN_IDENTITY"; then
  codesign -f -s "$SIGN_IDENTITY" -i stalker "$BINARY"
  echo "   signed as $SIGN_IDENTITY"
else
  echo "   WARNING: no '$SIGN_IDENTITY' code signing identity found."
  echo "            Leaving the binary ad-hoc signed, which means Accessibility"
  echo "            must be re-granted after every single build. To fix once:"
  echo "            Keychain Access > Certificate Assistant > Create a Certificate"
  echo "            name '$SIGN_IDENTITY', Self Signed Root, type Code Signing."
fi

echo "2. creating directories"
mkdir -p "$DATA_DIR/shell" "$CONFIG_DIR" "$HOME/Library/LaunchAgents"

echo "3. excluding the database from Time Machine"
tmutil addexclusion "$DATA_DIR"
tmutil isexcluded "$DATA_DIR"

echo "4. installing default rules (existing file is kept)"
if [ -f "$CONFIG_DIR/rules.toml" ]; then
  echo "   rules.toml already exists, leaving it alone"
else
  cp "$REPO/scripts/rules.toml.default" "$CONFIG_DIR/rules.toml"
fi

echo "5. shell hook"
HOOK_LINE="source \"$REPO/scripts/stalker.zsh\""
if grep -qF "$HOOK_LINE" "$HOME/.zshrc" 2>/dev/null; then
  echo "   hook already sourced from ~/.zshrc"
else
  printf '\n# stalker courier hook\n%s\n' "$HOOK_LINE" >> "$HOME/.zshrc"
  echo "   added to ~/.zshrc — open a new terminal tab for it to take effect"
fi

echo "6. launchd agent"
sed "s|__BINARY__|$BINARY|" "$REPO/scripts/stalker.sample.plist" > "$PLIST"
plutil -lint "$PLIST"
launchctl bootout "gui/$UID/stalker.sample" 2>/dev/null || true
launchctl bootstrap "gui/$UID" "$PLIST"
echo "   loaded"

echo
echo "7. REMAINING MANUAL STEP"
echo "   Grant Accessibility to:  $BINARY"
echo "   System Settings → Privacy & Security → Accessibility"
echo
echo "8. then verify:  $BINARY doctor"
