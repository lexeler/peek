#!/bin/zsh
# Builds Peek.app from source with the Command Line Tools (no Xcode needed).
#
#   scripts/build.sh              build into .build-app/Peek.app
#   scripts/build.sh --install    build, copy to /Applications, enable start-at-login (+ crash restart)
#   scripts/build.sh --zip        also pack dist/Peek-<version>.zip to send to someone
#   scripts/build.sh --debug-hooks  include developer remote-control hooks (testing only)
#
# Signing: a local self-signed identity kept in a private keychain inside the project
# (.signing/, created on the first build, never committed), so macOS permissions (Bluetooth)
# survive rebuilds. Falls back to ad-hoc.

set -euo pipefail

ROOT="${0:A:h:h}"
OUT="$ROOT/.build-app"
APP="$OUT/Peek.app"
VENDOR="$ROOT/Vendor/mediaremote-adapter"
INSTALL=0
ZIP=0
DEBUG_HOOKS=0

for arg in "$@"; do
  case "$arg" in
    --install) INSTALL=1 ;;
    --zip) ZIP=1 ;;
    --debug-hooks) DEBUG_HOOKS=1 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done
if (( ZIP && DEBUG_HOOKS )); then
  echo "--zip packs release builds only (drop --debug-hooks)" >&2
  exit 2
fi

step() { print -P "%F{cyan}▸%f $1"; }

mkdir -p "$OUT"

# ── 1. MediaRemote adapter framework (BSD-3, vendored) ──────────────────────────
FW="$OUT/MediaRemoteAdapter.framework"
FW_BIN="$FW/Versions/A/MediaRemoteAdapter"
if [[ ! -f "$FW_BIN" || -n "$(find "$VENDOR/src" "$VENDOR/include" -newer "$FW_BIN" -print -quit)" ]]; then
  step "Building MediaRemoteAdapter.framework"
  rm -rf "$FW"
  mkdir -p "$FW/Versions/A/Resources"
  clang -O2 -dynamiclib -fobjc-arc -fvisibility=default -arch arm64 -mmacosx-version-min=26.0 \
    -I"$VENDOR/include" -I"$VENDOR/src" \
    "$VENDOR"/src/adapter/*.m "$VENDOR"/src/private/MediaRemote.m "$VENDOR"/src/utility/*.m \
    -framework Foundation -framework AppKit -framework UniformTypeIdentifiers \
    -install_name @rpath/MediaRemoteAdapter.framework/Versions/A/MediaRemoteAdapter \
    -o "$FW_BIN"
  cat > "$FW/Versions/A/Resources/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.lexeler.Peek.MediaRemoteAdapter</string>
  <key>CFBundleExecutable</key><string>MediaRemoteAdapter</string>
  <key>CFBundleName</key><string>MediaRemoteAdapter</string>
  <key>CFBundlePackageType</key><string>FMWK</string>
  <key>CFBundleShortVersionString</key><string>0.7.7</string>
  <key>CFBundleVersion</key><string>1</string>
</dict></plist>
PLIST
  ln -sfn A "$FW/Versions/Current"
  ln -sfn Versions/Current/MediaRemoteAdapter "$FW/MediaRemoteAdapter"
  ln -sfn Versions/Current/Resources "$FW/Resources"
fi

# ── 2. Swift app ────────────────────────────────────────────────────────────────
step "Compiling Peek (release)"
SWIFT_ARGS=(-c release --arch arm64 --package-path "$ROOT")
if (( DEBUG_HOOKS )); then SWIFT_ARGS+=(-Xswiftc -DPEEK_DEBUG); fi
swift build "${SWIFT_ARGS[@]}"
BIN_DIR="$(swift build "${SWIFT_ARGS[@]}" --show-bin-path)"

# ── 3. Bundle ───────────────────────────────────────────────────────────────────
step "Assembling Peek.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN_DIR/Peek" "$APP/Contents/MacOS/Peek"
strip -x "$APP/Contents/MacOS/Peek"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
[[ -f "$ROOT/Resources/AppIcon.icns" ]] && cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/"
cp "$VENDOR/bin/mediaremote-adapter.pl" "$APP/Contents/Resources/"
cp -R "$FW" "$APP/Contents/Frameworks/"

# ── 4. Sign ─────────────────────────────────────────────────────────────────────
KEYCHAIN="$ROOT/.signing/peek-signing.keychain-db"
KC_PASS_FILE="$ROOT/.signing/keychain-password"   # random, per machine, never committed
IDENTITY="Peek Local Signing"
KC_PASS=""

ensure_identity() {
  if [[ -f "$KEYCHAIN" && -f "$KC_PASS_FILE" ]]; then
    KC_PASS="$(<"$KC_PASS_FILE")"
    security unlock-keychain -p "$KC_PASS" "$KEYCHAIN" >/dev/null 2>&1 || return 1
    security find-certificate -c "$IDENTITY" "$KEYCHAIN" >/dev/null 2>&1 && return 0
  fi
  step "Creating local signing identity (one time)"
  mkdir -p "$ROOT/.signing"
  KC_PASS="$(/usr/bin/openssl rand -hex 16)"
  (umask 077; print -rn -- "$KC_PASS" > "$KC_PASS_FILE")
  local tmp; tmp="$(mktemp -d)"
  cat > "$tmp/cfg" <<'CFG'
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = Peek Local Signing
[ext]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:false
CFG
  # The system LibreSSL on purpose: Homebrew's OpenSSL 3 writes .p12 files `security import` rejects.
  /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$tmp/cfg" \
    -keyout "$tmp/key.pem" -out "$tmp/cert.pem" >/dev/null 2>&1
  /usr/bin/openssl pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" -name "$IDENTITY" \
    -out "$tmp/id.p12" -passout pass:"$KC_PASS" >/dev/null 2>&1
  rm -f "$KEYCHAIN"
  security create-keychain -p "$KC_PASS" "$KEYCHAIN"
  security set-keychain-settings "$KEYCHAIN"
  security unlock-keychain -p "$KC_PASS" "$KEYCHAIN"
  security import "$tmp/id.p12" -k "$KEYCHAIN" -P "$KC_PASS" -T /usr/bin/codesign >/dev/null
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KC_PASS" "$KEYCHAIN" >/dev/null
  rm -rf "$tmp"
  security find-certificate -c "$IDENTITY" "$KEYCHAIN" >/dev/null 2>&1
}

sign() {
  if [[ "$SIGN_ID" == "-" ]]; then
    codesign --force --sign - "$@"
  else
    codesign --force --keychain "$KEYCHAIN" --sign "$SIGN_ID" "$@"
  fi
}

step "Signing"
SIGN_ID="-"
# codesign only looks in the user's keychain search list, so ours is listed while signing only.
# Remember the list first: creating a keychain also adds it there.
ORIGINAL_KEYCHAINS=("${(@f)$(security list-keychains -d user | sed -e 's/^ *"//' -e 's/"$//')}")
ORIGINAL_KEYCHAINS=("${(@)ORIGINAL_KEYCHAINS:#*/.signing/peek-signing.keychain-db}")
restore_keychains() { security list-keychains -d user -s "${ORIGINAL_KEYCHAINS[@]}"; }
trap restore_keychains EXIT
if ensure_identity; then
  SIGN_ID="$(security find-certificate -c "$IDENTITY" -Z "$KEYCHAIN" | awk '/SHA-1/{print $NF; exit}')"
  security list-keychains -d user -s "${ORIGINAL_KEYCHAINS[@]}" "$KEYCHAIN"
fi
if ! sign "$APP/Contents/Frameworks/MediaRemoteAdapter.framework" 2>/dev/null; then
  print -P "%F{yellow}!%f local identity unusable — falling back to ad-hoc signing"
  SIGN_ID="-"
  sign "$APP/Contents/Frameworks/MediaRemoteAdapter.framework"
fi
sign --identifier com.lexeler.Peek "$APP"
codesign --verify --strict "$APP"

print -P "%F{green}✓%f Built $APP  ($(du -sh "$APP" | cut -f1))"

# ── 5. Archive to share ─────────────────────────────────────────────────────────
if (( ZIP )); then
  VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Resources/Info.plist")"
  ARCHIVE="$ROOT/dist/Peek-$VERSION.zip"
  mkdir -p "$ROOT/dist"
  rm -f "$ARCHIVE"
  ditto -c -k --sequesterRsrc --keepParent "$APP" "$ARCHIVE"
  print -P "%F{green}✓%f Archive to share: $ARCHIVE  ($(du -h "$ARCHIVE" | cut -f1))"
fi

# ── 6. Install ──────────────────────────────────────────────────────────────────
if (( INSTALL )); then
  DEST="/Applications/Peek.app"
  step "Installing to $DEST"
  launchctl bootout "gui/$(id -u)/com.lexeler.Peek.agent" 2>/dev/null || true
  pkill -x Peek 2>/dev/null || true
  for _ in {1..20}; do pgrep -x Peek >/dev/null || break; sleep 0.1; done
  rm -rf "$DEST"
  ditto "$APP" "$DEST"
  "$DEST/Contents/MacOS/Peek" --install-agent
  print -P "%F{green}✓%f Peek is running (starts at login, restarts after a crash)"
fi
