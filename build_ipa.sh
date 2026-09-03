#!/bin/bash
# build_ipa.sh — Compila STAGE CONNECT para iPad y genera el IPA.
# Ejecutar desde Terminal en tu Mac: bash build_ipa.sh
# Necesitas: Xcode + cuenta Apple Developer (gratuita para instalar vía AltStore/Sideloadly,
#            o de pago para distribución ad-hoc sin jailbreak).
set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
IOS_PROJECT="$REPO/iOS/STAGE CONNECT.xcodeproj"
DOWNLOADS="$HOME/Downloads"
STAMP=$(date +%Y%m%d)
SCHEME="STAGE CONNECT"
CONFIGURATION="Release"
ARCHIVE="$DOWNLOADS/STAGE-CONNECT-iPad-${STAMP}.xcarchive"
IPA_DIR="$DOWNLOADS/STAGE-CONNECT-iPad-${STAMP}"
IPA_FILE="$DOWNLOADS/STAGE-CONNECT-iPad-${STAMP}.ipa"

echo "=== STAGE CONNECT — iPad IPA build ==="
echo ""
echo "Proyecto : $IOS_PROJECT"
echo "Scheme   : $SCHEME"
echo "Destino  : $IPA_FILE"
echo ""

# ── Verificar Xcode ────────────────────────────────────────────────────────────
if ! command -v xcodebuild &>/dev/null; then
  echo "ERROR: xcodebuild no encontrado. Instala Xcode desde la App Store."
  exit 1
fi
XCODE_VER=$(xcodebuild -version 2>/dev/null | head -1)
echo "Usando $XCODE_VER"
echo ""

# ── Detectar Team ID ───────────────────────────────────────────────────────────
# Busca el primer team en tus certificados de desarrollador
TEAM_ID=$(security find-identity -v -p codesigning 2>/dev/null \
  | grep -oE '\([A-Z0-9]{10}\)' | tr -d '()' | head -1 || true)

if [ -z "$TEAM_ID" ]; then
  echo "AVISO: No se encontró Team ID. Se usará firma ad-hoc (--sign -)."
  echo "       Para instalar en iPad necesitas un Team ID de Apple Developer."
  echo "       Puedes crear uno gratis en developer.apple.com."
  echo ""
  SIGN_FLAGS=(CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual)
  EXPORT_METHOD="development"
else
  echo "Team ID detectado: $TEAM_ID"
  SIGN_FLAGS=(DEVELOPMENT_TEAM="$TEAM_ID" CODE_SIGN_STYLE=Automatic)
  EXPORT_METHOD="development"
fi

# ── ExportOptions.plist ────────────────────────────────────────────────────────
EXPORT_PLIST="$(mktemp /tmp/ExportOptions.XXXX.plist)"
cat > "$EXPORT_PLIST" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>
  <string>${EXPORT_METHOD}</string>
  <key>compileBitcode</key>
  <false/>
  <key>thinning</key>
  <string>&lt;none&gt;</string>
  <key>iCloudContainerEnvironment</key>
  <string>Development</string>
PLIST

if [ -n "$TEAM_ID" ]; then
cat >> "$EXPORT_PLIST" << PLIST
  <key>teamID</key>
  <string>${TEAM_ID}</string>
PLIST
fi

cat >> "$EXPORT_PLIST" << 'PLIST'
</dict>
</plist>
PLIST

# ── Archive ────────────────────────────────────────────────────────────────────
echo "[1/3] Archivando (esto puede tardar 2-5 min)..."
xcodebuild archive \
  -project "$IOS_PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination "generic/platform=iOS" \
  -archivePath "$ARCHIVE" \
  "${SIGN_FLAGS[@]}" \
  IPHONEOS_DEPLOYMENT_TARGET=17.0 \
  | grep -E "^(error:|warning:|Build succeeded|FAILED|===)" || true

if [ ! -d "$ARCHIVE" ]; then
  echo ""
  echo "ERROR: El archivo no se creó. Revisa los errores anteriores."
  echo ""
  echo "Soluciones comunes:"
  echo "  1. Abre Xcode, ve a Signing & Capabilities y añade tu cuenta Apple."
  echo "  2. Asegúrate de que el iPad está en modo desarrollador (iOS 16+)."
  echo "  3. Ejecuta: sudo xcode-select --reset"
  exit 1
fi
echo "   Archivo OK: $ARCHIVE"

# ── Export IPA ─────────────────────────────────────────────────────────────────
echo "[2/3] Exportando IPA..."
rm -rf "$IPA_DIR"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath "$IPA_DIR" \
  -exportOptionsPlist "$EXPORT_PLIST" \
  | grep -E "^(error:|warning:|Export succeeded|FAILED|===)" || true

IPA_FOUND=$(find "$IPA_DIR" -name "*.ipa" 2>/dev/null | head -1 || true)
if [ -z "$IPA_FOUND" ]; then
  echo "ERROR: No se encontró el IPA en $IPA_DIR"
  echo "Revisa los logs de exportación."
  exit 1
fi

cp "$IPA_FOUND" "$IPA_FILE"
rm -f "$EXPORT_PLIST"

# ── Resultado ─────────────────────────────────────────────────────────────────
echo "[3/3] Listo."
echo ""
SIZE=$(du -sh "$IPA_FILE" | cut -f1)
echo "IPA generado: $IPA_FILE ($SIZE)"
echo ""
echo "Para instalar en tu iPad:"
echo "  • Opcion A (cuenta gratuita): Arrastra el IPA a AltStore o Sideloadly"
echo "  • Opcion B (cuenta de pago):  Dispositivos de confianza en Xcode → Window → Devices"
echo "  • Opcion C (TestFlight):       Sube a App Store Connect como build interno"
echo ""
