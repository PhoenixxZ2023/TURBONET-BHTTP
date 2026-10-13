#!/bin/bash
set -euo pipefail

# scripts/update_version_shas.sh
# Calcula SHA256 dos arquivos listados e atualiza version.json no repositório local.
# Uso:
#   cd /path/to/TURBONET-BHTTP
#   sudo ./scripts/update_version_shas.sh
# Isso escreve/atualiza version.json. Revise antes de commitar.

VERSION_FILE="version.json"
if [ ! -f "$VERSION_FILE" ]; then
  echo "ERRO: $VERSION_FILE não encontrado no diretório atual. Execute a partir da raiz do repositório." >&2
  exit 1
fi

FILES=(
  "app.py"
  "hex_menu.sh"
  "hex_cleanup.sh"
  "hex_panel_mode.sh"
  "hex_ip.sh"
  "install.sh"
  "install_webpanel.sh"
  "hex_privileged.py"
  "scripts/setup_privileged_runtime.sh"
  "scripts/deploy_runtime_complete.sh"
  "templates/login.html"
  "templates/dashboard.html"
)

TMP=$(mktemp)
cp "$VERSION_FILE" "$TMP"

for f in "${FILES[@]}"; do
  if [ -f "$f" ]; then
    sha=$(sha256sum "$f" | cut -d' ' -f1)
    echo "Atualizando SHA para $f -> $sha"
    # usa jq para inserir/atualizar
    jq --arg file "$f" --arg hash "$sha" '.sha256[$file]=$hash' "$TMP" > "$TMP.tmp" && mv "$TMP.tmp" "$TMP"
  else
    echo "Aviso: arquivo não encontrado, pulando: $f"
  fi
done

# valida JSON e grava de volta
if jq empty "$TMP" >/dev/null 2>&1; then
  mv "$TMP" "$VERSION_FILE"
  echo "version.json atualizado. Revise e commit:"
  echo "  git add $VERSION_FILE && git commit -m \"Atualizar SHA256 em version.json\" && git push"
  exit 0
else
  echo "ERRO: JSON gerado inválido; mantendo versão antiga." >&2
  rm -f "$TMP"
  exit 2
fi
