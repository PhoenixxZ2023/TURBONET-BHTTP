#!/usr/bin/env bash
set -euo pipefail

# install_webpanel.sh (corrigido)
# Instalador do painel web (versão limpa, sem diffs embutidos)
# Uso: sudo bash install_webpanel.sh

GITHUB_RAW="https://raw.githubusercontent.com/PhoenixxZ2023/TURBONET-BHTTP/main"
DEST_DIR="/opt/hex-webpanel"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

HEX_FAIL_ON_HASH_MISMATCH=${HEX_FAIL_ON_HASH_MISMATCH:-0}
HEX_REQUIRE_CHECKSUM=${HEX_REQUIRE_CHECKSUM:-0}

ui_info(){ echo -e "\e[36m[+] $*\e[0m"; }
ui_warn(){ echo -e "\e[33m[!] $*\e[0m"; }
ui_error(){ echo -e "\e[31m[-] $*\e[0m"; }
ui_ok(){ echo -e "\e[32m[✓] $*\e[0m"; }

baixar_verificado_simple(){
  local rel="$1" dest="$2" mode="${3:-644}"
  local tmpf="$TMPDIR/$(basename "$rel")"

  ui_info "Baixando $rel..."
  if ! curl -fsSL -H 'Cache-Control: no-cache' "$GITHUB_RAW/$rel" -o "$tmpf"; then
    ui_error "Falha ao baixar $rel"
    return 1
  fi

  if curl -fsSL -H 'Cache-Control: no-cache' "$GITHUB_RAW/version.json" -o "$TMPDIR/version.json"; then
    exp=$(jq -r --arg f "$rel" '.sha256[$f] // empty' "$TMPDIR/version.json" 2>/dev/null || true)
  else
    exp=""
  fi

  if [ -n "$exp" ]; then
    got=$(sha256sum "$tmpf" | cut -d' ' -f1)
    if [ "$got" != "$exp" ]; then
      if [ "${HEX_FAIL_ON_HASH_MISMATCH}" = "1" ]; then
        ui_error "SHA256 não confere para $rel (recusado)"
        return 2
      else
        ui_warn "SHA256 divergente para $rel; seguindo em modo permissivo"
      fi
    fi
  else
    if [ "${HEX_REQUIRE_CHECKSUM}" = "1" ]; then
      ui_error "version.json sem SHA256 para $rel"
      return 2
    else
      ui_warn "version.json sem SHA256 para $rel (sem verificação)"
    fi
  fi

  mkdir -p "$(dirname "$dest")"
  chmod "$mode" "$tmpf" 2>/dev/null || true
  mv -f "$tmpf" "$dest"
  return 0
}

main(){
  ui_info "Instalando painel web em $DEST_DIR"
  mkdir -p "$DEST_DIR"

  files=(
    "app.py:$DEST_DIR/app.py:644"
    "hex_privileged.py:$DEST_DIR/hex_privileged.py:700"
    "scripts/setup_privileged_runtime.sh:$DEST_DIR/scripts/setup_privileged_runtime.sh:700"
    "scripts/deploy_runtime_complete.sh:$DEST_DIR/scripts/deploy_runtime_complete.sh:700"
    "templates/login.html:$DEST_DIR/templates/login.html:644"
    "templates/dashboard.html:$DEST_DIR/templates/dashboard.html:644"
    "hex_ip.sh:/usr/local/bin/hex_ip.sh:755"
    "hex_panel_mode.sh:/usr/local/bin/hex_panel_mode.sh:755"
  )

  for entry in "${files[@]}"; do
    IFS=':' read -r rel dest mode <<< "$entry"
    if ! baixar_verificado_simple "$rel" "$dest" "$mode"; then
      rc=$?
      if [ "$rc" -eq 2 ]; then
        ui_error "Abortando por erro de verificação em $rel"
        return 1
      else
        ui_warn "Falha ao baixar $rel; continuando com próximos"
      fi
    else
      ui_ok "$rel instalado em $dest"
    fi
  done

  if [ ! -x "$DEST_DIR/venv/bin/python" ]; then
    ui_info "Criando virtualenv..."
    python3 -m venv "$DEST_DIR/venv" || { ui_warn "venv falhou (talvez python3-venv não instalado)"; }
  fi

  if [ -x "$DEST_DIR/venv/bin/python" ]; then
    "$DEST_DIR/venv/bin/python" -m py_compile "$DEST_DIR/app.py" 2>/dev/null || ui_warn "app.py pode conter erro de sintaxe"
  fi

  ui_ok "Instalação básica concluída (arquivos baixados)."
  ui_info "Execute: sudo bash /opt/hex-webpanel/scripts/deploy_runtime_complete.sh para aplicar separação de privilégios (se desejar)."

  return 0
}

main "$@"
