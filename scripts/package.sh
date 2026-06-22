#!/usr/bin/env bash
#
# Phase 5 — build a distributable installer (PRD M5).
#
# Produces build/Crisp-<version>.pkg that installs:
#   /Applications/Crisp.app
#   /Library/Audio/Plug-Ins/HAL/CrispAudio.driver   (+ postinstall restarts coreaudiod)
#
# A .pkg (not a drag-install .dmg) is used because the virtual-mic HAL driver must land
# in a system location with admin rights — pkg postinstall handles this; a dmg cannot.
#
# Signing + notarization (required for Gatekeeper-clean install on other Macs) run only
# when these are set; otherwise an UNSIGNED pkg is produced for local testing:
#   DEVELOPER_ID_APP="Developer ID Application: NAME (TEAMID)"
#   DEVELOPER_ID_INSTALLER="Developer ID Installer: NAME (TEAMID)"
#   NOTARY_PROFILE="<notarytool keychain profile>"   # from: xcrun notarytool store-credentials
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="0.1.0"
BUILD="$ROOT/build"
PKGROOT="$BUILD/pkgroot"
SCRIPTS="$BUILD/pkgscripts"
COMPONENT="$BUILD/Crisp-component.pkg"
PRODUCT="$BUILD/Crisp-$VERSION.pkg"

echo "==> Building driver + app"
"$ROOT/build.sh" >/dev/null
"$ROOT/build-app.sh" >/dev/null

echo "==> Staging payload"
rm -rf "$PKGROOT" "$SCRIPTS"
mkdir -p "$PKGROOT/Applications" "$PKGROOT/Library/Audio/Plug-Ins/HAL" "$SCRIPTS"
cp -R "$BUILD/Crisp.app" "$PKGROOT/Applications/"
cp -R "$BUILD/CrispAudio.driver" "$PKGROOT/Library/Audio/Plug-Ins/HAL/"

cat > "$SCRIPTS/postinstall" <<'EOF'
#!/bin/bash
# Restart coreaudiod so the virtual mic is picked up.
killall coreaudiod 2>/dev/null || true
exit 0
EOF
chmod +x "$SCRIPTS/postinstall"

# --- Optional Developer ID signing of the app + driver (hardened runtime) ---
if [[ -n "${DEVELOPER_ID_APP:-}" ]]; then
    echo "==> Signing app + driver with: $DEVELOPER_ID_APP"
    codesign --force --options runtime --timestamp \
        --sign "$DEVELOPER_ID_APP" "$PKGROOT/Library/Audio/Plug-Ins/HAL/CrispAudio.driver"
    codesign --force --options runtime --timestamp \
        --entitlements "$ROOT/app/Crisp.entitlements" \
        --sign "$DEVELOPER_ID_APP" "$PKGROOT/Applications/Crisp.app/Contents/Resources/lib/libdf.dylib"
    codesign --force --options runtime --timestamp \
        --entitlements "$ROOT/app/Crisp.entitlements" \
        --sign "$DEVELOPER_ID_APP" "$PKGROOT/Applications/Crisp.app"
else
    echo "==> DEVELOPER_ID_APP not set — payload stays ad-hoc signed (local test only)"
fi

echo "==> pkgbuild (relocation disabled so the app always installs to /Applications)"
# By default pkgbuild marks app bundles relocatable; the installer would then redirect
# the install to any existing copy of bundle id ai.rtzr.crisp. Force BundleIsRelocatable=false.
PLIST="$BUILD/components.plist"
pkgbuild --analyze --root "$PKGROOT" "$PLIST" >/dev/null
/usr/bin/python3 - "$PLIST" <<'PY'
import sys, plistlib
p = sys.argv[1]
with open(p, 'rb') as f: comps = plistlib.load(f)
for c in comps:
    c['BundleIsRelocatable'] = False
with open(p, 'wb') as f: plistlib.dump(comps, f)
PY
pkgbuild --root "$PKGROOT" --component-plist "$PLIST" --scripts "$SCRIPTS" \
    --identifier ai.rtzr.crisp.pkg --version "$VERSION" \
    --install-location / "$COMPONENT"

echo "==> productbuild"
if [[ -n "${DEVELOPER_ID_INSTALLER:-}" ]]; then
    productbuild --package "$COMPONENT" --sign "$DEVELOPER_ID_INSTALLER" "$PRODUCT"
else
    productbuild --package "$COMPONENT" "$PRODUCT"
    echo "   (unsigned — set DEVELOPER_ID_INSTALLER to sign)"
fi

# --- Optional notarization ---
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    echo "==> Notarizing ($NOTARY_PROFILE)"
    xcrun notarytool submit "$PRODUCT" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$PRODUCT"
    echo "   notarized + stapled"
else
    echo "==> NOTARY_PROFILE not set — skipping notarization"
fi

rm -f "$COMPONENT"
echo "==> Done: $PRODUCT"
