#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# git_limpiar.sh — 1) commitea el trabajo actual  2) borra toda referencia a
#                  Claude del historial (autor y mensajes de commit)
#
# Uso:  cd ruta/al/repo/sc6000swift && bash git_limpiar.sh
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
cd "$(cd "$(dirname "$0")" && pwd)"

RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[1;33m'; BLU='\033[0;34m'; NC='\033[0m'
ok(){ echo -e "${GRN}  OK${NC}  $*"; }
warn(){ echo -e "${YLW}  --${NC}  $*"; }
err(){ echo -e "${RED}  XX${NC}  $*"; }
step(){ echo ""; echo -e "${BLU}==>${NC} $*"; }

NOMBRE="onersaik"
EMAIL="info@entikrecords.com"

echo ""
echo "  ============================================"
echo "    Limpieza de historial — STAGE CONNECT"
echo "  ============================================"

rm -f .git/index.lock 2>/dev/null

# ── 1. Commit del trabajo pendiente ──────────────────────────────────────────
step "1/4  Commit del trabajo actual"

if [ -n "$(git status --porcelain)" ]; then
    git add -A
    git commit -q -m "Modo dia/noche, 11 idiomas y layout de botones sin recortes

- ThemeStore: preferencia oscuro/claro persistente, negro puro en modo oscuro
- Theme: doble paleta y helper overlay() que se invierte en modo claro
- LocalizationStore: 11 idiomas (es en fr it de zh ja th ca gl eu)
- OutputsView: secciones Idioma y Apariencia
- ContentView: boton de modo en el header, textos que no se parten
- PlayerDeckRow: LOCK/MST/SMPTE con fixedSize, nunca cortan texto
- build_all.sh: genera .app, .pkg, .dmg e .ipa en Escritorio/STAGE CONNECT"
    ok "Cambios commiteados"
else
    warn "No habia cambios pendientes"
fi

# ── 2. Copia de seguridad ────────────────────────────────────────────────────
step "2/4  Copia de seguridad"

BACKUP="backup-antes-limpieza-$(date +%Y%m%d-%H%M)"
git branch "$BACKUP" 2>/dev/null && ok "Rama de respaldo: $BACKUP" \
    || warn "No se pudo crear la rama de respaldo"

# ── 3. Reescritura del historial ─────────────────────────────────────────────
step "3/4  Reescribiendo autores y mensajes"

ANTES_AUTOR=$(git log --all --format='%an' | grep -ci claude || true)
ANTES_MSG=$(git log --all --format='%B' | grep -ci 'claude' || true)
echo "     Antes: $ANTES_AUTOR commits con autor Claude, $ANTES_MSG lineas con referencias"

export FILTER_BRANCH_SQUELCH_WARNING=1

git filter-branch -f --tag-name-filter cat \
  --env-filter '
    if [ "$GIT_AUTHOR_NAME" = "Claude" ] || case "$GIT_AUTHOR_EMAIL" in *anthropic*) true;; *) false;; esac; then
        export GIT_AUTHOR_NAME="'"$NOMBRE"'"
        export GIT_AUTHOR_EMAIL="'"$EMAIL"'"
    fi
    if [ "$GIT_COMMITTER_NAME" = "Claude" ] || case "$GIT_COMMITTER_EMAIL" in *anthropic*) true;; *) false;; esac; then
        export GIT_COMMITTER_NAME="'"$NOMBRE"'"
        export GIT_COMMITTER_EMAIL="'"$EMAIL"'"
    fi
  ' \
  --msg-filter '
    grep -v -i -e "Co-Authored-By: Claude" \
              -e "Generated with .*Claude" \
              -e "claude\.ai/code" \
              -e "claude\.com/claude-code" \
              -e "Claude-Session" \
    | cat -s
  ' \
  -- --all >/dev/null 2>&1

if [ $? -eq 0 ]; then ok "Historial reescrito"; else err "Fallo la reescritura"; exit 1; fi

# Limpiar refs viejas
rm -rf .git/refs/original 2>/dev/null
git reflog expire --expire=now --all >/dev/null 2>&1
git gc --prune=now --aggressive >/dev/null 2>&1
ok "Referencias antiguas eliminadas"

# ── 4. Verificacion ──────────────────────────────────────────────────────────
step "4/4  Verificacion"

DESPUES_AUTOR=$(git log --format='%an' | grep -ci claude || true)
DESPUES_MSG=$(git log --format='%B' | grep -ci claude || true)

echo "     Autores con Claude:    $DESPUES_AUTOR"
echo "     Mensajes con Claude:   $DESPUES_MSG"
echo ""

if [ "$DESPUES_AUTOR" = "0" ] && [ "$DESPUES_MSG" = "0" ]; then
    ok "Historial limpio"
else
    err "Quedan referencias, revisa manualmente con: git log --format='%an %B' | grep -i claude"
fi

echo ""
echo "  Autores actuales del repositorio:"
git log --format='%an <%ae>' | sort -u | sed 's/^/     /'

echo ""
echo "  ============================================"
echo "    Para subirlo a GitHub (reescribe el remoto):"
echo ""
echo "      git push --force-with-lease origin main"
echo ""
echo "    Si algo sale mal, vuelve al respaldo con:"
echo "      git reset --hard $BACKUP"
echo "  ============================================"
echo ""
