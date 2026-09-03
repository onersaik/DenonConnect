#!/bin/bash
# make_pkg_pro.sh — Instalador PKG profesional para STAGE CONNECT.
# Genera un PKG firmado con pantalla de bienvenida, licencia y conclusión en español.
# Ejecutar: bash packaging/make_pkg_pro.sh  (desde la raíz del repositorio)
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
DOWNLOADS="$HOME/Downloads"
STAMP=$(date +%Y%m%d)
VERSION="1.0"
BUNDLE_ID="com.entikrecords.stageconnect"
PKG_NAME="STAGE-CONNECT-${VERSION}"
WORK=$(mktemp -d)
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

echo "=== STAGE CONNECT — Instalador PKG Profesional ==="
echo ""

# ── 1. Compilar las apps ──────────────────────────────────────────────────────
echo "[1/8] Compilando release..."
cd "$REPO"
swift build -c release --product SC6000ConnectApp --product DJSimulatorApp 2>&1 \
  | grep -E "^(error:|Build complete|warning: .*error)" || true

# ── 2. Iconos ─────────────────────────────────────────────────────────────────
echo "[2/8] Iconos..."
ICON_CONNECT="$REPO/Resources/AppIcon.icns"
ICON_TEST="$REPO/Resources/AppIconTest.icns"
if [ ! -f "$ICON_TEST" ] && [ -f "$REPO/Resources/icon_1024.png" ]; then
  TMP_ICONSET=$(mktemp -d)
  ICONSET="$TMP_ICONSET/test.iconset"
  mkdir -p "$ICONSET"
  for SZ in 16 32 128 256 512; do
    sips -z $SZ $SZ "$REPO/Resources/icon_1024.png" --out "$ICONSET/icon_${SZ}x${SZ}.png" >/dev/null 2>&1
    sips -z $((SZ*2)) $((SZ*2)) "$REPO/Resources/icon_1024.png" --out "$ICONSET/icon_${SZ}x${SZ}@2x.png" >/dev/null 2>&1
  done
  iconutil -c icns "$ICONSET" -o "$ICON_TEST" 2>/dev/null || cp "$ICON_CONNECT" "$ICON_TEST"
  rm -rf "$TMP_ICONSET"
fi

# ── 3. Construir .app bundles ─────────────────────────────────────────────────
echo "[3/8] Bundles .app..."
PAYLOAD="$WORK/payload"
mkdir -p "$PAYLOAD"

make_app() {
  local BIN="$1" APPNAME="$2" BUNDLEID="$3" ICNS="$4"
  local APP="$PAYLOAD/${APPNAME}.app"
  rm -rf "$APP"
  mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
  cp "$REPO/.build/release/$BIN" "$APP/Contents/MacOS/$BIN"
  chmod +x "$APP/Contents/MacOS/$BIN"
  [ -f "$ICNS" ] && cp "$ICNS" "$APP/Contents/Resources/AppIcon.icns"
  local SRC_PLIST="$REPO/packaging/Info.plist"
  if [ ! -f "$SRC_PLIST" ]; then
    echo "ERROR: falta $SRC_PLIST" >&2
    exit 1
  fi
  cp "$SRC_PLIST" "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleExecutable ${BIN}" "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier ${BUNDLEID}" "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleName ${APPNAME}" "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName ${APPNAME}" "$APP/Contents/Info.plist"
  if ! /usr/libexec/PlistBuddy -c "Print :NSLocalNetworkUsageDescription" "$APP/Contents/Info.plist" >/dev/null 2>&1; then
    echo "ERROR: packaging/Info.plist no tiene NSLocalNetworkUsageDescription" >&2
    exit 1
  fi
  local ENT="$REPO/packaging/STAGECONNECT.entitlements"
  if [ -f "$ENT" ]; then
    codesign --force --deep --sign - --entitlements "$ENT" "$APP" 2>/dev/null || \
    codesign --force --deep --sign - "$APP" 2>/dev/null || true
  else
    codesign --force --deep --sign - "$APP" 2>/dev/null || true
  fi
}

make_app "SC6000ConnectApp" "STAGE CONNECT"      "${BUNDLE_ID}"      "$ICON_CONNECT"
make_app "DJSimulatorApp"   "STAGE CONNECT TEST" "${BUNDLE_ID}.test" "$ICON_TEST"

# Copias sueltas en Descargas para uso inmediato
cp -R "$PAYLOAD/STAGE CONNECT.app"      "$DOWNLOADS/" 2>/dev/null || true
cp -R "$PAYLOAD/STAGE CONNECT TEST.app" "$DOWNLOADS/" 2>/dev/null || true

# ── 4. Imagen de fondo (Python puro) ─────────────────────────────────────────
echo "[4/8] Imagen de fondo del instalador..."
python3 << 'PY'
import struct, zlib, sys

W, H = 800, 500
px = bytearray(W * H * 4)

def put(x, y, r, g, b, a=255):
    if 0 <= x < W and 0 <= y < H:
        i = (y * W + x) * 4
        px[i:i+4] = bytes([r, g, b, a])

import math

# Fondo degradado oscuro
for y in range(H):
    t = y / H
    r = int(8  + t * 4)
    g = int(8  + t * 4)
    b = int(12 + t * 6)
    for x in range(W):
        put(x, y, r, g, b)

# Linea de acento naranja horizontal
ACCENT = (0xF5, 0xA6, 0x23)
for x in range(W):
    for dy in range(3):
        put(x, H - 60 + dy, *ACCENT)

# Puntos de decoracion (grid de cruces pequeñas)
for gy in range(30, H - 70, 50):
    for gx in range(30, W, 50):
        a = 30
        put(gx, gy, *ACCENT, a)
        put(gx-1, gy, *ACCENT, a)
        put(gx+1, gy, *ACCENT, a)
        put(gx, gy-1, *ACCENT, a)
        put(gx, gy+1, *ACCENT, a)

# Texto "STAGE CONNECT" simulado con bloques (letras pixeladas gruesas)
def draw_block(cx, cy, w, h, color):
    r, g, b = color
    for yy in range(cy, cy+h):
        for xx in range(cx, cx+w):
            put(xx, yy, r, g, b)

# Barra de titulo
draw_block(0, 0, W, 4, ACCENT)

# Guardar PNG
def png(w, h, pixels):
    def chunk(t, d):
        c = t + d
        return struct.pack('>I', len(d)) + c + struct.pack('>I', zlib.crc32(c) & 0xffffffff)
    rows = b''.join(b'\x00' + bytes(pixels[y*w*4:(y+1)*w*4]) for y in range(h))
    return (b'\x89PNG\r\n\x1a\n'
          + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 6, 0, 0, 0))
          + chunk(b'IDAT', zlib.compress(rows, 6))
          + chunk(b'IEND', b''))

import os
out_path = os.environ.get('BG_OUT', '/tmp/pkg_bg.png')
with open(out_path, 'wb') as f:
    f.write(png(W, H, px))
print(f'  Fondo: {out_path}')
PY
BG_OUT="$WORK/pkg_bg.png" python3 - << 'PY2'
import struct, zlib, math, os

W, H = 800, 500
px = bytearray(W * H * 4)

def put(x, y, r, g, b, a=255):
    if 0 <= x < W and 0 <= y < H:
        i = (y * W + x) * 4
        if a >= 255:
            px[i:i+4] = bytes([r, g, b, 255])
        else:
            oa = px[i+3]
            if oa == 0:
                px[i:i+4] = bytes([r, g, b, a])
            else:
                na = a + oa * (255 - a) // 255
                inv = 255 - a
                px[i]   = (r * a + px[i]   * oa * inv // 255) // na
                px[i+1] = (g * a + px[i+1] * oa * inv // 255) // na
                px[i+2] = (b * a + px[i+2] * oa * inv // 255) // na
                px[i+3] = na

ACCENT = (0xF5, 0xA6, 0x23)
DARK   = (8, 8, 12)
MID    = (16, 16, 22)

# Fondo degradado
for y in range(H):
    t = y / H
    r = int(DARK[0] + (MID[0]-DARK[0]) * t)
    g = int(DARK[1] + (MID[1]-DARK[1]) * t)
    b = int(DARK[2] + (MID[2]-DARK[2]) * t)
    for x in range(W):
        put(x, y, r, g, b)

# Grid de puntos
for gy in range(25, H, 40):
    for gx in range(25, W, 40):
        a = 25 + int(15 * math.sin(gx * 0.05 + gy * 0.07))
        for dx in [-1, 0, 1]:
            for dy in [-1, 0, 1]:
                if abs(dx) + abs(dy) <= 1:
                    put(gx+dx, gy+dy, *ACCENT, a)

# Barra superior acento
for x in range(W):
    for yy in range(3):
        put(x, yy, *ACCENT)
    put(x, 3, *ACCENT, 120)
    put(x, 4, *ACCENT, 40)

# Barra inferior
for x in range(W):
    for yy in range(H-56, H-52):
        put(x, yy, *ACCENT)
    for yy in range(H-52, H):
        put(x, yy, 12, 12, 18)

# Texto zona (degradado lateral izquierdo sutil)
for y in range(80, H-60):
    for x in range(W//2 - 20):
        t2 = 1.0 - x / (W//2 - 20)
        a = int(60 * t2 * t2)
        put(x, y, *ACCENT, a)

# Guardar
def png(w, h, pixels):
    def chunk(t, d):
        c = t + d
        return struct.pack('>I', len(d)) + c + struct.pack('>I', zlib.crc32(c) & 0xffffffff)
    rows = b''.join(b'\x00' + bytes(pixels[y*w*4:(y+1)*w*4]) for y in range(h))
    return (b'\x89PNG\r\n\x1a\n'
          + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 6, 0, 0, 0))
          + chunk(b'IDAT', zlib.compress(rows, 6))
          + chunk(b'IEND', b''))

out_path = os.environ.get('BG_OUT', '/tmp/pkg_bg.png')
with open(out_path, 'wb') as f:
    f.write(png(W, H, px))
print('  Fondo generado')
PY2

BG_PNG="$WORK/pkg_bg.png"
BG_TIF="$WORK/pkg_bg.tif"
sips -s format tiff "$BG_PNG" --out "$BG_TIF" >/dev/null 2>&1 || cp "$BG_PNG" "$BG_TIF"

# ── 5. Recursos del instalador (HTML en español) ──────────────────────────────
echo "[5/8] Recursos del instalador (español)..."
RES="$WORK/resources"
mkdir -p "$RES"

# Welcome
cat > "$RES/Welcome.html" << 'HTML'
<!DOCTYPE html>
<html lang="es">
<head>
<meta charset="UTF-8">
<style>
  body { font-family: -apple-system, 'Helvetica Neue', Arial, sans-serif;
         color: #e0e0e0; background: transparent; margin: 0; padding: 20px 24px; }
  h1   { font-size: 22px; font-weight: 700; color: #F5A623; margin: 0 0 12px; letter-spacing: 0.5px; }
  p    { font-size: 13px; line-height: 1.6; margin: 0 0 10px; }
  ul   { font-size: 13px; line-height: 1.8; margin: 8px 0 0 0; padding-left: 20px; }
  li   { margin-bottom: 2px; }
  .sub { font-size: 11px; color: #888; margin-top: 16px; }
</style>
</head>
<body>
<h1>Bienvenido a STAGE CONNECT</h1>
<p>STAGE CONNECT es un monitor profesional para sesiones de DJ en tiempo real. Conecta con tus reproductores Denon SC6000 (StageLinq) y Pioneer/AlphaTheta CDJ (Pro DJ Link) en la red local.</p>
<p>Este instalador copiará las siguientes aplicaciones en tu carpeta <strong>Aplicaciones</strong>:</p>
<ul>
  <li><strong>STAGE CONNECT</strong> &mdash; Monitor principal (Denon + Pioneer)</li>
  <li><strong>STAGE CONNECT TEST</strong> &mdash; Simulador de reproductores para pruebas</li>
</ul>
<p class="sub">Versión 1.0 &nbsp;&bull;&nbsp; entikrecords.com &nbsp;&bull;&nbsp; macOS 13 o superior</p>
</body>
</html>
HTML

# License / EULA
cat > "$RES/License.html" << 'HTML'
<!DOCTYPE html>
<html lang="es">
<head>
<meta charset="UTF-8">
<style>
  body { font-family: -apple-system, 'Helvetica Neue', Arial, sans-serif;
         color: #d0d0d0; background: transparent; margin: 0; padding: 16px 20px; }
  h2   { font-size: 15px; font-weight: 700; color: #F5A623; margin: 0 0 10px; }
  h3   { font-size: 13px; font-weight: 600; color: #ccc; margin: 14px 0 6px; }
  p    { font-size: 12px; line-height: 1.6; margin: 0 0 8px; }
</style>
</head>
<body>
<h2>Acuerdo de Licencia de Usuario Final — STAGE CONNECT</h2>
<p>Lea detenidamente este acuerdo antes de instalar el software.</p>

<h3>1. Concesión de licencia</h3>
<p>entikrecords.com le concede una licencia personal, no exclusiva e intransferible para instalar y utilizar STAGE CONNECT en los dispositivos de su propiedad o bajo su control, de conformidad con este acuerdo.</p>

<h3>2. Restricciones</h3>
<p>Queda prohibido: redistribuir, vender, sublicenciar o alquilar el software; realizar ingeniería inversa o descompilar el código; eliminar avisos de propiedad intelectual; utilizarlo para fines ilegales.</p>

<h3>3. Activación</h3>
<p>El software requiere una clave de activación válida para desbloquear todas las funciones. Las claves son personales e intransferibles.</p>

<h3>4. Sin garantía</h3>
<p>El software se proporciona "tal cual", sin garantía de ningún tipo, expresa o implícita. entikrecords.com no será responsable de daños derivados del uso o la imposibilidad de uso del software.</p>

<h3>5. Actualizaciones</h3>
<p>Las actualizaciones están sujetas a este mismo acuerdo salvo que se indique expresamente lo contrario.</p>

<h3>6. Rescisión</h3>
<p>Este acuerdo queda rescindido automáticamente si incumple cualquiera de sus términos. Al rescindirse, deberá dejar de utilizar el software y eliminar todas las copias.</p>

<h3>7. Ley aplicable</h3>
<p>Este acuerdo se rige por la ley española. Cualquier controversia se someterá a los tribunales competentes de España.</p>

<p style="margin-top:16px; font-size:11px; color:#777;">
Al hacer clic en "Aceptar" confirma que ha leído, comprendido y aceptado todos los términos de este acuerdo.
</p>
</body>
</html>
HTML

# Conclusion
cat > "$RES/Conclusion.html" << 'HTML'
<!DOCTYPE html>
<html lang="es">
<head>
<meta charset="UTF-8">
<style>
  body { font-family: -apple-system, 'Helvetica Neue', Arial, sans-serif;
         color: #e0e0e0; background: transparent; margin: 0; padding: 20px 24px; }
  h1   { font-size: 20px; font-weight: 700; color: #F5A623; margin: 0 0 10px; }
  p    { font-size: 13px; line-height: 1.6; margin: 0 0 10px; }
  code { background: rgba(245,166,35,0.15); padding: 1px 5px; border-radius: 3px;
         font-family: 'SF Mono', 'Menlo', monospace; font-size: 12px; color: #F5A623; }
  .note{ font-size: 12px; color: #888; margin-top: 14px; line-height: 1.6; }
</style>
</head>
<body>
<h1>Instalacion completada</h1>
<p>STAGE CONNECT se ha instalado correctamente en tu carpeta <strong>Aplicaciones</strong>.</p>
<p><strong>Primera apertura:</strong> haz clic derecho sobre la app y selecciona <em>Abrir</em> para omitir la advertencia de Gatekeeper la primera vez.</p>
<p>Introduce tu clave de activacion cuando la app lo solicite:</p>
<p><code>entikmedia</code> &mdash; acceso mensual (30 dias)<br>
   <code>laif</code> &mdash; acceso de por vida</p>
<p class="note">
  Asegurate de que tus reproductores y el Mac estan en la misma red local.<br>
  Para soporte: entikrecords.com
</p>
</body>
</html>
HTML

# ── 6. Distribution.xml ───────────────────────────────────────────────────────
echo "[6/8] Distribution XML..."
DIST_XML="$WORK/Distribution.xml"
cat > "$DIST_XML" << XML
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
  <title>STAGE CONNECT</title>
  <organization>com.entikrecords</organization>

  <background        file="pkg_bg.tif"        scaling="proportional" alignment="bottomleft"/>
  <background-darkAqua file="pkg_bg.tif"      scaling="proportional" alignment="bottomleft"/>
  <welcome           file="Welcome.html"       mime-type="text/html"/>
  <license           file="License.html"       mime-type="text/html"/>
  <conclusion        file="Conclusion.html"    mime-type="text/html"/>

  <options customize="never" require-scripts="false" rootVolumeOnly="false"/>

  <pkg-ref id="${BUNDLE_ID}.pkg">#stageconnect.pkg</pkg-ref>

  <choices-outline>
    <line choice="main"/>
  </choices-outline>

  <choice id="main" visible="false" start_selected="true" start_enabled="true" start_hidden="false">
    <pkg-ref id="${BUNDLE_ID}.pkg"/>
  </choice>
</installer-gui-script>
XML

# Copia el tif al directorio de recursos
cp "$BG_TIF" "$RES/pkg_bg.tif"

# ── 7. pkgbuild + productbuild ────────────────────────────────────────────────
echo "[7/8] Construyendo PKG..."
COMP_PKG="$WORK/stageconnect.pkg"
pkgbuild \
  --root "$PAYLOAD" \
  --install-location "/Applications" \
  --identifier "${BUNDLE_ID}.pkg" \
  --version "${VERSION}" \
  --ownership recommended \
  "$COMP_PKG" 2>&1 | grep -v "^pkgbuild" || true

FINAL_PKG="$DOWNLOADS/${PKG_NAME}.pkg"
productbuild \
  --distribution "$DIST_XML" \
  --resources "$RES" \
  --package-path "$WORK" \
  "$FINAL_PKG" 2>&1 | grep -v "^productbuild" || true

# ── 8. DMG arrastrable ───────────────────────────────────────────────────────
echo "[8/8] DMG arrastrable..."
DMG_SCRATCH="$WORK/dmg_src"
mkdir -p "$DMG_SCRATCH"
cp -R "$PAYLOAD/STAGE CONNECT.app"      "$DMG_SCRATCH/"
cp -R "$PAYLOAD/STAGE CONNECT TEST.app" "$DMG_SCRATCH/"
ln -s /Applications "$DMG_SCRATCH/Aplicaciones"
cp "$FINAL_PKG" "$DMG_SCRATCH/"

cat > "$DMG_SCRATCH/LEEME.txt" << TXT
STAGE CONNECT ${VERSION}
========================
entikrecords.com

Instalacion rapida
------------------
Arrastra STAGE CONNECT a la carpeta Aplicaciones.

Instalador completo
-------------------
Haz doble clic en ${PKG_NAME}.pkg

Primera apertura
----------------
Clic derecho → Abrir (para omitir Gatekeeper).
Introduce tu clave de activacion cuando la app lo pida.

Claves de activacion
--------------------
  entikmedia  — mensual (30 dias)
  laif        — de por vida
TXT

DMG_FILE="$DOWNLOADS/${PKG_NAME}.dmg"
rm -f "$DMG_FILE"
hdiutil create \
  -volname "STAGE CONNECT" \
  -srcfolder "$DMG_SCRATCH" \
  -ov -format UDZO \
  "$DMG_FILE" >/dev/null

# ── Resultado ─────────────────────────────────────────────────────────────────
echo ""
echo "=== Listo ==="
echo ""
ls -lh \
  "$DOWNLOADS/STAGE CONNECT.app" \
  "$DOWNLOADS/STAGE CONNECT TEST.app" \
  "$FINAL_PKG" \
  "$DMG_FILE" \
  2>/dev/null || true
echo ""
echo "Archivos en ~/Downloads:"
echo "  ${PKG_NAME}.pkg  — Instalador completo (Instalador.app de macOS)"
echo "  ${PKG_NAME}.dmg  — Imagen de disco arrastrable"
echo "  STAGE CONNECT.app — App lista para usar"
echo ""
