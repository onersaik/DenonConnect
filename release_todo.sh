#!/bin/bash
# release_todo.sh — Publica el commit y genera todos los entregables.
# Ejecutar desde Terminal en tu Mac (necesita xcodebuild/swift reales):
#
#   cd "/Users/saik/DENON CONNECT/sc6000swift"
#   bash release_todo.sh
#
set -uo pipefail

RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[1;33m'; BLU='\033[0;34m'; NC='\033[0m'
ok()   { echo -e "${GRN}  OK${NC}  $*"; }
fail() { echo -e "${RED}  XX${NC}  $*"; }
step() { echo ""; echo -e "${BLU}==>${NC} $*"; }

REPO="$(cd "$(dirname "$0")" && pwd)"
cd "$REPO"

echo ""
echo "  ================================================"
echo "    STAGE CONNECT  ·  push + build completo"
echo "  ================================================"

step "1/2  Subiendo el commit de correcciones a GitHub"
if git push origin main; then
    ok "Push hecho."
else
    fail "El push falló. Revisa tu sesión/credenciales de GitHub en este Mac"
    fail "(por ejemplo: gh auth login, o abre Xcode/Terminal y prueba 'git push' a mano)."
    exit 1
fi

step "2/2  Compilando .app, .pkg, .dmg e .ipa"
bash build_all.sh
STATUS=$?

echo ""
if [ $STATUS -eq 0 ]; then
    ok "Listo. Todo generado en: ~/Desktop/STAGE CONNECT"
else
    fail "build_all.sh terminó con errores (código $STATUS). Revisa el log arriba."
fi
exit $STATUS
