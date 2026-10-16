#!/usr/bin/env bash
# Membangun "AI Transcriber.app" (dan .dmg) dari source.
#
#   ./build-app.sh                 → build/AI Transcriber.app
#   ./build-app.sh --install       → build lalu pasang ke /Applications dan buka
#   ./build-app.sh --dmg           → build + build/AI-Transcriber-<versi>.dmg
#   ./build-app.sh --universal     → binary Apple Silicon + Intel
#
# Opsional (distribusi tanpa peringatan Gatekeeper, butuh Apple Developer Program):
#   SIGN_IDENTITY="Developer ID Application: Nama (TEAMID)"
#   NOTARY_PROFILE="nama-profil-notarytool"   (dibuat dengan: xcrun notarytool store-credentials)
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="AI Transcriber"
EXECUTABLE="AITranscriber"
BUNDLE_ID="${BUNDLE_ID:-com.aitranscriber.app}"
VERSION="$(tr -d '[:space:]' < VERSION)"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
BUILD_DIR="build"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
DMG_PATH="$BUILD_DIR/AI-Transcriber-$VERSION.dmg"

UNIVERSAL=0; MAKE_DMG=0; INSTALL=0
for arg in "$@"; do
    case "$arg" in
        --universal) UNIVERSAL=1 ;;
        --dmg) MAKE_DMG=1 ;;
        --install) INSTALL=1 ;;
        -h|--help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Opsi tidak dikenal: $arg (lihat --help)"; exit 1 ;;
    esac
done

step() { printf '\n\033[1;34m▶︎ %s\033[0m\n' "$1"; }
fail() { printf '\033[1;31m✗ %s\033[0m\n' "$1" >&2; exit 1; }

[[ "$(uname)" == "Darwin" ]] || fail "Script ini harus dijalankan di macOS."
command -v swift >/dev/null || fail "Swift tidak ditemukan. Pasang Xcode dari App Store, lalu jalankan: sudo xcode-select -s /Applications/Xcode.app"
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version 2>/dev/null || echo 0)"
[[ "${SDK_VERSION%%.*}" -ge 15 ]] || fail "Butuh SDK macOS 15+ (Xcode 16 atau lebih baru). SDK terpasang: $SDK_VERSION"

ARCH_FLAGS=()
[[ $UNIVERSAL == 1 ]] && ARCH_FLAGS=(--arch arm64 --arch x86_64)

step "Kompilasi release ${ARCH_FLAGS[*]:-(arsitektur Mac ini)}… (pertama kali bisa beberapa menit)"
swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BIN_DIR="$(swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)"

step "Menyusun bundle aplikasi…"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN_DIR/$EXECUTABLE" "$APP_DIR/Contents/MacOS/$EXECUTABLE"
# Resource bundle milik dependensi (saat ini tidak ada, tapi tetap aman jika nanti ada).
find "$BIN_DIR" -maxdepth 1 -name "*.bundle" -exec cp -R {} "$APP_DIR/Contents/Resources/" \;

step "Membuat ikon…"
ICONSET="$BUILD_DIR/AppIcon.iconset"
rm -rf "$ICONSET"; mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
    sips -z $size $size Resources/AppIcon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) Resources/AppIcon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP_DIR/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleExecutable</key><string>${EXECUTABLE}</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
    <key>CFBundleDevelopmentRegion</key><string>id</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>Transkripsi AI di perangkat dengan WhisperKit.</string>
    <!-- Muncul di menu "Open With" untuk file audio & video di Finder -->
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>Audio atau Video</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>LSHandlerRank</key><string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>public.audio</string>
                <string>public.movie</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
PLIST
printf 'APPL????' > "$APP_DIR/Contents/PkgInfo"

step "Menandatangani aplikasi…"
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP_DIR"
else
    # Ad-hoc: cukup untuk dipakai di Mac sendiri.
    codesign --force --sign - "$APP_DIR"
fi
codesign --verify --strict "$APP_DIR"
echo "✓ $APP_DIR (versi $VERSION, build $BUILD_NUMBER)"

if [[ $MAKE_DMG == 1 ]]; then
    step "Membuat DMG…"
    STAGING="$BUILD_DIR/dmg"
    rm -rf "$STAGING" "$DMG_PATH"; mkdir -p "$STAGING"
    cp -R "$APP_DIR" "$STAGING/"
    ln -s /Applications "$STAGING/Applications"
    hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" -ov -format UDZO "$DMG_PATH" >/dev/null
    rm -rf "$STAGING"

    if [[ -n "${SIGN_IDENTITY:-}" ]]; then
        codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG_PATH"
        if [[ -n "${NOTARY_PROFILE:-}" ]]; then
            step "Notarisasi Apple (bisa beberapa menit)…"
            xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
            xcrun stapler staple "$DMG_PATH"
        fi
    fi
    echo "✓ $DMG_PATH"
fi

if [[ $INSTALL == 1 ]]; then
    step "Memasang ke /Applications…"
    osascript -e "quit app \"$APP_NAME\"" >/dev/null 2>&1 || true
    rm -rf "/Applications/$APP_NAME.app"
    ditto "$APP_DIR" "/Applications/$APP_NAME.app"
    echo "✓ Terpasang di /Applications/$APP_NAME.app"
    open "/Applications/$APP_NAME.app"
fi
