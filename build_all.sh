#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# build_all.sh — Genera .app, .pkg, .dmg e .ipa y los deja en
#                ~/Desktop/STAGE CONNECT
#
# Uso:   cd ruta/al/repo/sc6000swift && bash build_all.sh
#        bash build_all.sh --sin-ipa      (salta el IPA, mas rapido)
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
DEST="$HOME/Desktop/STAGE CONNECT"
STAGING="$(mktemp -d)"
VERSION="2.0.0"
STAMP="$(date +%Y%m%d-%H%M)"
SKIP_IPA=0
[ "${1:-}" = "--sin-ipa" ] && SKIP_IPA=1

RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[1;33m'; BLU='\033[0;34m'; NC='\033[0m'
ok()   { echo -e "${GRN}  OK${NC}  $*"; }
warn() { echo -e "${YLW}  --${NC}  $*"; }
fail() { echo -e "${RED}  XX${NC}  $*"; }
step() { echo ""; echo -e "${BLU}==>${NC} $*"; }

trap 'rm -rf "$STAGING"' EXIT

echo ""
echo "  ================================================"
echo "    STAGE CONNECT  ·  build completo  ·  v$VERSION"
echo "  ================================================"

mkdir -p "$DEST"

# ── 1. Compilar y montar los .app ────────────────────────────────────────────
step "1/5  Compilando la app (swift build -c release)"

if ! command -v swift >/dev/null 2>&1; then
    fail "swift no encontrado. Instala Xcode o las Command Line Tools:"
    echo "      xcode-select --install"
    exit 1
fi

cd "$REPO"
if bash build_apps.sh; then
    ok "Apps compiladas"
else
    fail "Fallo la compilacion. Revisa los errores de arriba."
    exit 1
fi

# build_apps.sh las deja en ~/Downloads
APP_SRC="$HOME/Downloads/STAGE CONNECT.app"
APP_TEST_SRC="$HOME/Downloads/STAGE CONNECT TEST.app"

if [ ! -d "$APP_SRC" ]; then
    fail "No se genero STAGE CONNECT.app"
    exit 1
fi

step "2/5  Copiando los .app a la carpeta de entrega"
rm -rf "$DEST/STAGE CONNECT.app" "$DEST/STAGE CONNECT TEST.app"
cp -R "$APP_SRC" "$DEST/STAGE CONNECT.app"
ok "STAGE CONNECT.app"
if [ -d "$APP_TEST_SRC" ]; then
    cp -R "$APP_TEST_SRC" "$DEST/STAGE CONNECT TEST.app"
    ok "STAGE CONNECT TEST.app"
fi

# ── 3. PKG ───────────────────────────────────────────────────────────────────
step "3/5  Creando el instalador .pkg"

PKG_ROOT="$STAGING/pkgroot"
PKG_RES="$STAGING/pkgres"
mkdir -p "$PKG_ROOT/Applications" "$PKG_RES"
cp -R "$DEST/STAGE CONNECT.app" "$PKG_ROOT/Applications/"
[ -d "$DEST/STAGE CONNECT TEST.app" ] && cp -R "$DEST/STAGE CONNECT TEST.app" "$PKG_ROOT/Applications/"

# Textos del instalador
cat > "$PKG_RES/welcome.html" << 'HTML'
<!DOCTYPE html><html><head><meta charset="utf-8">
<style>
body{font-family:-apple-system,sans-serif;font-size:13px;color:#222;line-height:1.6;margin:0;padding:4px}
h2{font-size:17px;margin:0 0 12px;color:#000}
ul{margin:10px 0 0 18px;padding:0} li{margin-bottom:7px}
.n{color:#666;font-size:12px;margin-top:16px}
</style></head><body>
<h2>STAGE CONNECT</h2>
<p>Convierte tus reproductores en el reloj maestro del show. Este instalador copia la aplicacion en tu carpeta Aplicaciones.</p>
<ul>
<li>Timecode SMPTE LTC a 24, 25 y 30 fps</li>
<li>MIDI Timecode por cualquier puerto del sistema</li>
<li>OSC y puente directo a Resolume</li>
<li>Monitor web en tiempo real y sobreimpresion para OBS</li>
<li>Compatible con Denon StageLinq, Pioneer PRO DJ LINK, Serato y VirtualDJ</li>
</ul>
<p class="n">Requiere macOS 13 Ventura o superior.</p>
</body></html>
HTML

cat > "$PKG_RES/conclusion.html" << 'HTML'
<!DOCTYPE html><html><head><meta charset="utf-8">
<style>
body{font-family:-apple-system,sans-serif;font-size:13px;color:#222;line-height:1.6;margin:0;padding:4px}
h2{font-size:17px;margin:0 0 12px;color:#000}
ol{margin:10px 0 0 18px;padding:0} li{margin-bottom:8px}
.n{color:#666;font-size:12px;margin-top:18px}
</style></head><body>
<h2>Instalacion completada</h2>
<p>STAGE CONNECT ya esta en tu carpeta Aplicaciones. Para empezar:</p>
<ol>
<li>Conecta el Mac a la misma red que los reproductores, por cable.</li>
<li>Abre STAGE CONNECT e introduce tu codigo de activacion.</li>
<li>La primera vez, macOS pedira permiso de red local. Aceptalo: sin el no aparecen los equipos.</li>
<li>En CONFIG asigna las salidas de LTC, MTC y OSC.</li>
<li>Pulsa MASTER y el timecode empieza a seguir lo que suena.</li>
</ol>
<p class="n">ENTIK MEDIA</p>
</body></html>
HTML

cat > "$STAGING/distribution.xml" << XML
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
    <title>STAGE CONNECT</title>
    <organization>com.entikrecords</organization>
    <welcome    file="welcome.html"    mime-type="text/html"/>
    <conclusion file="conclusion.html" mime-type="text/html"/>
    <options customize="never" require-scripts="false" hostArchitectures="arm64,x86_64"/>
    <volume-check>
        <allowed-os-versions><os-version min="13.0"/></allowed-os-versions>
    </volume-check>
    <pkg-ref id="com.entikrecords.stageconnect.pkg"/>
    <choices-outline><line choice="default"/></choices-outline>
    <choice id="default" title="STAGE CONNECT">
        <pkg-ref id="com.entikrecords.stageconnect.pkg"/>
    </choice>
    <pkg-ref id="com.entikrecords.stageconnect.pkg" version="$VERSION" onConclusion="none">componente.pkg</pkg-ref>
</installer-gui-script>
XML

pkgbuild --root "$PKG_ROOT" \
         --identifier "com.entikrecords.stageconnect.pkg" \
         --version "$VERSION" \
         --install-location "/" \
         "$STAGING/componente.pkg" >/dev/null 2>&1

if productbuild --distribution "$STAGING/distribution.xml" \
                --resources "$PKG_RES" \
                --package-path "$STAGING" \
                "$DEST/STAGE CONNECT $VERSION.pkg" >/dev/null 2>&1; then
    ok "STAGE CONNECT $VERSION.pkg"
else
    fail "No se pudo crear el .pkg"
fi

# ── 4. DMG ───────────────────────────────────────────────────────────────────
step "4/5  Creando la imagen de disco .dmg"

DMG_SRC="$STAGING/dmg"
mkdir -p "$DMG_SRC"
cp -R "$DEST/STAGE CONNECT.app" "$DMG_SRC/"
[ -d "$DEST/STAGE CONNECT TEST.app" ] && cp -R "$DEST/STAGE CONNECT TEST.app" "$DMG_SRC/"
ln -s /Applications "$DMG_SRC/Aplicaciones"

cat > "$DMG_SRC/LEEME.txt" << TXT
STAGE CONNECT $VERSION
======================

Arrastra STAGE CONNECT.app a la carpeta Aplicaciones.

Primera ejecucion
-----------------
macOS pedira permiso de red local la primera vez que abras la app.
Hay que aceptarlo: sin ese permiso los reproductores no aparecen.

Si macOS bloquea la app por no estar firmada con una cuenta de
desarrollador, abrela con clic derecho > Abrir, o ve a
Ajustes del Sistema > Privacidad y seguridad > Abrir igualmente.

Requisitos
----------
macOS 13 Ventura o superior, Apple Silicon o Intel.
El Mac y los reproductores en la misma red local.

STAGE CONNECT TEST.app simula reproductores en la red para que
puedas probar la configuracion sin tener el equipo delante.

ENTIK MEDIA
TXT

DMG_OUT="$DEST/STAGE CONNECT $VERSION.dmg"
rm -f "$DMG_OUT"
if hdiutil create -volname "STAGE CONNECT" \
                  -srcfolder "$DMG_SRC" \
                  -ov -format UDZO \
                  "$DMG_OUT" >/dev/null 2>&1; then
    ok "STAGE CONNECT $VERSION.dmg"
else
    fail "No se pudo crear el .dmg"
fi

# ── 5. IPA ───────────────────────────────────────────────────────────────────
step "5/5  Compilando el IPA para iPad"

if [ "$SKIP_IPA" = "1" ]; then
    warn "Saltado (--sin-ipa)"
elif [ ! -d "$REPO/iOS/STAGE CONNECT.xcodeproj" ]; then
    warn "No se encontro el proyecto de iOS"
elif ! command -v xcodebuild >/dev/null 2>&1; then
    warn "xcodebuild no disponible. Instala Xcode completo desde la App Store."
else
    ARCHIVE="$STAGING/STAGE-CONNECT-iPad.xcarchive"
    IPA_DIR="$STAGING/ipa"

    echo "     Archivando (puede tardar varios minutos)..."
    if xcodebuild archive \
        -project "$REPO/iOS/STAGE CONNECT.xcodeproj" \
        -scheme "STAGE CONNECT" \
        -configuration Release \
        -destination "generic/platform=iOS" \
        -archivePath "$ARCHIVE" \
        -allowProvisioningUpdates \
        CODE_SIGN_STYLE=Automatic \
        IPHONEOS_DEPLOYMENT_TARGET=17.0 \
        >"$STAGING/xcode.log" 2>&1; then

        cat > "$STAGING/ExportOptions.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>development</string>
  <key>compileBitcode</key><false/>
  <key>signingStyle</key><string>automatic</string>
  <key>stripSwiftSymbols</key><true/>
  <key>thinning</key><string>&lt;none&gt;</string>
</dict>
</plist>
PLIST

        if xcodebuild -exportArchive \
            -archivePath "$ARCHIVE" \
            -exportPath "$IPA_DIR" \
            -exportOptionsPlist "$STAGING/ExportOptions.plist" \
            -allowProvisioningUpdates \
            >>"$STAGING/xcode.log" 2>&1; then

            FOUND="$(find "$IPA_DIR" -name '*.ipa' | head -1)"
            if [ -n "$FOUND" ]; then
                cp "$FOUND" "$DEST/STAGE CONNECT $VERSION.ipa"
                ok "STAGE CONNECT $VERSION.ipa"
            else
                fail "El export termino pero no hay .ipa"
                cp "$STAGING/xcode.log" "$DEST/build-ipa-error.log"
                warn "Log guardado en la carpeta: build-ipa-error.log"
            fi
        else
            fail "Fallo el export del archive (falta firma o provisioning)"
            cp "$STAGING/xcode.log" "$DEST/build-ipa-error.log"
            warn "Log guardado en la carpeta: build-ipa-error.log"
            warn "Abre iOS/STAGE CONNECT.xcodeproj en Xcode y elige tu equipo"
            warn "en Signing & Capabilities, luego vuelve a lanzar el script."
        fi
    else
        fail "Fallo el archive de iOS"
        cp "$STAGING/xcode.log" "$DEST/build-ipa-error.log"
        warn "Log guardado en la carpeta: build-ipa-error.log"
        warn "Normalmente es la firma: abre el proyecto en Xcode, ve a"
        warn "Signing & Capabilities y selecciona tu Team de Apple Developer."
    fi
fi

# ── Resumen ──────────────────────────────────────────────────────────────────
echo ""
echo "  ================================================"
echo "    Entregado en:  $DEST"
echo "  ================================================"
echo ""
ls -lh "$DEST" 2>/dev/null | grep -v '^total' | awk '{printf "    %-10s %s\n", $5, substr($0, index($0,$9))}'
echo ""
