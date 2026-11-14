#!/bin/bash
# Builds KeyVault.app with the Swift toolchain only (no Xcode project, no dependencies).
set -euo pipefail
cd "$(dirname "$0")"

if ! command -v swiftc >/dev/null 2>&1; then
  echo "✗ Swift compiler not found."
  echo "  Install Apple's Command Line Tools, then run this script again:"
  echo "    xcode-select --install"
  exit 1
fi
if [ "$(sw_vers -productVersion | cut -d. -f1)" -lt 14 ]; then
  echo "✗ KeyVault needs macOS 14 (Sonoma) or later. You have $(sw_vers -productVersion)."
  exit 1
fi

APP="build/KeyVault.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

if [ ! -f AppIcon.icns ] || [ tools/make_icon.swift -nt AppIcon.icns ]; then
  echo "→ Rendering icon"
  mkdir -p assets build/AppIcon.iconset
  swift tools/make_icon.swift assets/logo.png
  for s in 16 32 128 256 512; do
    sips -z $s $s assets/logo.png --out build/AppIcon.iconset/icon_${s}x${s}.png >/dev/null
    sips -z $((s*2)) $((s*2)) assets/logo.png --out build/AppIcon.iconset/icon_${s}x${s}@2x.png >/dev/null
  done
  iconutil -c icns build/AppIcon.iconset -o AppIcon.icns
fi

echo "→ Running crypto tests"
swiftc -O -swift-version 5 Sources/VaultCrypto.swift Sources/PasswordPolicy.swift tests/main.swift -o build/crypto-tests
./build/crypto-tests

echo "→ Running agent-access tests (protocol, process checks, approvals, socket attacks)"
swiftc -O -swift-version 5 Sources/AgentProtocol.swift Sources/ProcessInspector.swift Sources/AccessController.swift \
    Sources/AgentServer.swift tests/agent/main.swift -o build/agent-tests
./build/agent-tests agent

echo "→ Running app integration tests (throwaway home folder; your real vault is never touched)"
APP_SOURCES=()
for f in Sources/*.swift; do [ "$f" != "Sources/KeyVaultApp.swift" ] && APP_SOURCES+=("$f"); done
swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos14.0" "${APP_SOURCES[@]}" tests/integration/main.swift \
    -o build/integration-tests
./build/integration-tests agent

echo "→ Running Python client tests"
python3 -I -m unittest discover -s agent/tests

echo "→ Compiling app"
swiftc -O -parse-as-library -swift-version 5 -target "$(uname -m)-apple-macos14.0" \
    Sources/*.swift -o "$APP/Contents/MacOS/KeyVault"
cp Info.plist "$APP/Contents/Info.plist"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp assets/logo.png "$APP/Contents/Resources/logo.png"
cp agent/keyvault_client.py "$APP/Contents/Resources/keyvault_client.py"

# Hardened runtime: ignores DYLD_INSERT_LIBRARIES, enforces library validation,
# and (with no get-task-allow entitlement) blocks debugger attachment.
# Files in iCloud-synced folders (e.g. Desktop) carry Finder metadata that codesign rejects.
# Cloud-synced folders can re-attach Finder metadata at any moment, so clean and sign in a retry loop.
signed=0
for attempt in 1 2 3 4 5; do
  xattr -cr "$APP"
  if codesign --force --options runtime --entitlements KeyVault.entitlements --sign - "$APP" >/dev/null 2>&1; then signed=1; break; fi
  sleep 1
done
if [ "$signed" != 1 ]; then
  echo "✗ Code signing failed. If this folder is synced (iCloud, Dropbox), copy the project somewhere unsynced and build there."
  exit 1
fi
echo "✓ Built $APP"
echo "  Run:     open \"$APP\""
echo "  Install: cp -R \"$APP\" /Applications/"
