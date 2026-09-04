#!/usr/bin/env bash
# ship.sh — sube tus cambios, arregla solo el lío del log de CI si aparece,
# espera a que termine el build en GitHub Actions y abre la app actualizada.
# Uso: ./ship.sh "mensaje del commit" (si hay cambios sin commitear)
set -e
cd "$(dirname "$0")"

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

# 2) trae lo del remoto (puede venir un commit de log del CI) y reordena
git fetch origin main
if ! git pull --rebase origin main; then
  # conflicto casi siempre en ci/build-log.txt: nos quedamos con la del remoto
  git checkout --theirs ci/build-log.txt 2>/dev/null || true
  git add ci/build-log.txt 2>/dev/null || true
  git rebase --continue
fi

# 3) sube
git push origin main

# 4) espera a que el run disparado por este push aparezca y termine
sleep 8
RUN_ID=$(gh run list --workflow=build.yml --limit 1 --json databaseId --jq '.[0].databaseId')
echo "Esperando el build (run $RUN_ID)..."
gh run watch "$RUN_ID" --exit-status

# 5) descarga, descomprime, quita cuarentena y abre
rm -rf ~/Downloads/SC6000Connect
gh run download "$RUN_ID" --dir ~/Downloads/SC6000Connect
cd ~/Downloads/SC6000Connect
unzip -o STAGECONNECT.zip
xattr -cr "STAGE CONNECT.app"
open "STAGE CONNECT.app"
echo "Listo: STAGE CONNECT.app actualizada y abierta."
