#!/bin/bash
# Empaqueta STAGE CONNECT y STAGE CONNECT TEST en un instalador macOS
# profesional: DMG arrastrable + PKG para Instalador.app.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
DOWNLOADS="$HOME/Downloads"
STAMP=$(date +%Y%m%d)
VOL="STAGE CONNECT"
WORK=$(mktemp -d)
PAYLOAD="$WORK/payload"
SCRATCH="$WORK/scratch"

cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

echo "=== STAGE CONNECT — instalador ==="
cd "$REPO"

echo "[1/6] Compilando release..."
swift build -c release

echo "[2/6] Iconos..."
ICON_CONNECT="$REPO/Resources/AppIcon.icns"
ICON_TEST="$REPO/Resources/AppIconTest.icns"
if [ ! -f "$ICON_TEST" ]; then
  PNG_TEST="$REPO/Resources/icon_test_1024.png"
  swift "$REPO/packaging/make_test_icon.swift" "$REPO/Resources/icon_1024.png" "$PNG_TEST"
  TMP=$(mktemp -d)
  ICONSET="$TMP/test.iconset"
  mkdir -p "$ICONSET"
  for SZ in 16 32 128 256 512; do
    sips -z $SZ $SZ "$PNG_TEST" --out "$ICONSET/icon_${SZ}x${SZ}.png" >/dev/null
    sips -z $((SZ*2)) $((SZ*2)) "$PNG_TEST" --out "$ICONSET/icon_${SZ}x${SZ}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$ICON_TEST"
  rm -rf "$TMP"
fi

make_app() {
  local BIN="$1" APPNAME="$2" BUNDLEID="$3" ICNS="$4" DEST="$5"
  local APP="$DEST/${APPNAME}.app"
  rm -rf "$APP"
  mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
  cp "$REPO/.build/release/$BIN" "$APP/Contents/MacOS/$BIN"
  chmod +x "$APP/Contents/MacOS/$BIN"
  [ -f "$ICNS" ] && cp "$ICNS" "$APP/Contents/Resources/AppIcon.icns"
  cat > "$APP/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>${BIN}</string>
  <key>CFBundleIdentifier</key><string>${BUNDLEID}</string>
  <key>CFBundleName</key><string>${APPNAME}</string>
  <key>CFBundleDisplayName</key><string>${APPNAME}</string>
  <key>CFBundleVersion</key><string>1.0</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSLocalNetworkUsageDescription</key>
  <string>STAGE CONNECT descubre y se conecta a tus reproductores Denon SC6000 (StageLinq, UDP 51337) y Pioneer/AlphaTheta CDJ (Pro DJ Link, UDP 50000-50002) en la red local. Sin este permiso no aparecen los equipos.</string>
  <key>NSBonjourServices</key><array><string>_stagelinq._tcp</string></array>
  <key>NSAppTransportSecurity</key>
  <dict>
    <key>NSAllowsLocalNetworking</key>
    <true/>
  </dict>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.music</string>
</dict></plist>
PLIST
  local ENT="$REPO/packaging/STAGECONNECT.entitlements"
  if [ -f "$ENT" ]; then
    codesign --force --deep --sign - --entitlements "$ENT" "$APP" >/dev/null 2>&1 \
      || codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
  else
    codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
  fi
  echo "  $APP"
}

echo "[3/6] Bundles .app..."
mkdir -p "$PAYLOAD" "$SCRATCH" "$DOWNLOADS"
make_app "SC6000ConnectApp" "STAGE CONNECT"      "com.entikrecords.stageconnect"      "$ICON_CONNECT" "$PAYLOAD"
make_app "DJSimulatorApp"   "STAGE CONNECT TEST" "com.entikrecords.stageconnect.test" "$ICON_TEST"    "$PAYLOAD"
# Copias sueltas en Descargas (abrir al momento)
rm -rf "$DOWNLOADS/STAGE CONNECT.app" "$DOWNLOADS/STAGE CONNECT TEST.app"
cp -R "$PAYLOAD/STAGE CONNECT.app" "$DOWNLOADS/"
cp -R "$PAYLOAD/STAGE CONNECT TEST.app" "$DOWNLOADS/"

echo "[4/6] PKG (Instalador.app)..."
PKG="$DOWNLOADS/STAGE-CONNECT-${STAMP}.pkg"
pkgbuild \
  --root "$PAYLOAD" \
  --install-location "/Applications" \
  --identifier "com.entikrecords.stageconnect.pkg" \
  --version "1.0" \
  --ownership recommended \
  "$PKG" >/dev/null
echo "  $PKG"

echo "[5/6] DMG arrastrable..."
mkdir -p "$SCRATCH"
cp -R "$PAYLOAD/STAGE CONNECT.app" "$SCRATCH/"
cp -R "$PAYLOAD/STAGE CONNECT TEST.app" "$SCRATCH/"
ln -s /Applications "$SCRATCH/Applications"
cat > "$SCRATCH/LEEME.txt" << TXT
STAGE CONNECT
============
Arrastra las apps a Aplicaciones.

• STAGE CONNECT — monitor Denon + Pioneer
• STAGE CONNECT TEST — simulador de reproductores

Primera apertura: clic derecho → Abrir.
Introduce la clave de activación la primera vez.
TXT
DMG="$DOWNLOADS/STAGE-CONNECT-${STAMP}.dmg"
rm -f "$DMG"
hdiutil create \
  -volname "$VOL" \
  -srcfolder "$SCRATCH" \
  -ov -format UDZO \
  "$DMG" >/dev/null
echo "  $DMG"

echo "[6/6] Listo."
ls -lh "$DOWNLOADS/STAGE CONNECT.app" "$DOWNLOADS/STAGE CONNECT TEST.app" "$PKG" "$DMG"
