#!/usr/bin/env bash
# ship.sh — sube tus cambios, arregla solo el lío del log de CI si aparece,
# espera a que termine el build en GitHub Actions y deja la app actualizada
# en ~/Desktop/STAGE CONNECT/STAGE CONNECT.app (sobrescribiendo la anterior).
# Uso: ./ship.sh "mensaje del commit" (si hay cambios sin commitear)
set -e
cd "$(dirname "$0")"

DEST_DIR="$HOME/Desktop/STAGE CONNECT"
DEST_APP="$DEST_DIR/STAGE CONNECT.app"

# 0) limpieza defensiva: locks sueltos o un rebase a medias de una vez anterior
rm -f .git/index.lock .git/HEAD.lock .git/ORIG_HEAD.lock 2>/dev/null || true
if [ -d .git/rebase-merge ] || [ -d .git/rebase-apply ]; then
  git rebase --abort 2>/dev/null || true
fi
git checkout main 2>/dev/null || true

# 1) si hay cambios locales, los commitea (menos el log de CI, que es del CI)
git checkout -- ci/build-log.txt 2>/dev/null || true
if ! git diff --quiet || ! git diff --cached --quiet; then
  git add -A
  git commit -m "${1:-Actualizacion}"
fi

# 2) trae lo del remoto (puede venir un commit de log del CI) y fusiona sin editor
git fetch origin main
if ! git pull --no-rebase --no-edit origin main; then
  git checkout --theirs ci/build-log.txt 2>/dev/null || true
  git add ci/build-log.txt 2>/dev/null || true
  git commit --no-edit 2>/dev/null || true
fi

# 3) sube
git push origin main

# 4) espera a que el run disparado por este push aparezca y termine
sleep 8
RUN_ID=$(gh run list --workflow=build.yml --limit 1 --json databaseId --jq '.[0].databaseId')
echo "Esperando el build (run $RUN_ID)..."
gh run watch "$RUN_ID" --exit-status

# 5) descarga, descomprime, quita cuarentena y deja la app en el Escritorio
TMP_DL=$(mktemp -d)
gh run download "$RUN_ID" --dir "$TMP_DL"
# gh anida cada artefacto en su propia subcarpeta (nombre del artefacto):
# el zip puede estar en $TMP_DL/STAGE-CONNECT-app/STAGECONNECT.zip, no suelto.
ZIP_PATH=$(find "$TMP_DL" -name "STAGECONNECT.zip" -print -quit)
if [ -z "$ZIP_PATH" ]; then
  echo "No se encontro STAGECONNECT.zip en el artefacto descargado:" >&2
  find "$TMP_DL" >&2
  exit 1
fi
unzip -o "$ZIP_PATH" -d "$TMP_DL"
APP_PATH=$(find "$TMP_DL" -name "STAGE CONNECT.app" -maxdepth 3 -print -quit)
if [ -z "$APP_PATH" ]; then
  echo "No se encontro STAGE CONNECT.app tras descomprimir:" >&2
  find "$TMP_DL" >&2
  exit 1
fi
xattr -cr "$APP_PATH"

mkdir -p "$DEST_DIR"
rm -rf "$DEST_APP"
mv "$APP_PATH" "$DEST_APP"
rm -rf "$TMP_DL"

open "$DEST_APP"
echo "Listo: '$DEST_APP' actualizada y abierta."
