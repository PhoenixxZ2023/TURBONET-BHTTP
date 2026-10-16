#!/bin/bash

# ═══════════════════════════════════════════════════════════════
#  MANAGER - MENU DE GERENCIAMENTO COMPLETO (v1.2.0)
#  Repositório: https://github.com/PhoenixxZ2023/TURBONET-BHTTP
#  Com sistema de atualização automática e porta web configurável
# ═══════════════════════════════════════════════════════════════

RED='\033[38;5;203m'; GREEN='\033[38;5;84m'; YELLOW='\033[38;5;221m'
CYAN='\033[38;5;51m'; WHITE='\033[38;5;255m'; NC='\033[0m'
BOLD='\033[1m'; ACC='\033[38;5;44m'; GRIS='\033[38;5;245m'

BHTTP_PORTS_CONF="/etc/hex/bhttp_ports.conf"
HCR_PORTS_CONF="/etc/hex/hcr_ports.conf"
UDPGW_PORTS_CONF="/etc/hex/udpgw_ports.conf"
USER_DB="/etc/hex/users.txt"
USER_GROUP="hexusers"
CLEANUP_SCRIPT="/usr/local/bin/hex_cleanup.sh"
CLEANUP_LOG="/var/log/hex-cleanup.log"
WEBPANEL_SERVICE="hex-webpanel.service"

# ═══════════════════════════════════════════════════════════════
#  CONFIGURAÇÃO DE ATUALIZAÇÕES E PORTA WEB
# ═══════════════════════════════════════════════════════════════
VERSION_FILE="/etc/hex/version"
WEBPANEL_PORT_FILE="/etc/hex/webpanel_port.conf"
GITHUB_REPO="PhoenixxZ2023/TURBONET-BHTTP"
GITHUB_RAW="https://raw.githubusercontent.com/${GITHUB_REPO}/main"

HEX_VERSION=$(cat "$VERSION_FILE" 2>/dev/null || echo "1.0.0")
WEBPANEL_PORT=$(cat "$WEBPANEL_PORT_FILE" 2>/dev/null || echo "9000")

mkdir -p /etc/hex
touch "$USER_DB" && chmod 600 "$USER_DB"
[ -f "$BHTTP_PORTS_CONF" ] || echo "80" > "$BHTTP_PORTS_CONF"
[ -f "$HCR_PORTS_CONF" ] || echo "8080" > "$HCR_PORTS_CONF"
[ -f "$UDPGW_PORTS_CONF" ] || echo -e "7300\n7301" > "$UDPGW_PORTS_CONF"
[ -f "$WEBPANEL_PORT_FILE" ] || echo "9000" > "$WEBPANEL_PORT_FILE"

# Instalação automática de limpeza ao iniciar (recria se for a versão antiga, sem o marcador v2)
if [ ! -f "$CLEANUP_SCRIPT" ] || ! grep -q "hex_cleanup v2" "$CLEANUP_SCRIPT" 2>/dev/null; then
    cat > "$CLEANUP_SCRIPT" <<'EOF_CLEANUP'
#@embed hex_cleanup.sh
EOF_CLEANUP
    chmod +x "$CLEANUP_SCRIPT"
    touch "$CLEANUP_LOG" && chmod 644 "$CLEANUP_LOG"
fi
cron_active=$(crontab -l 2>/dev/null | grep -c "hex_cleanup.sh")
[ "$cron_active" -eq 0 ] && (crontab -l 2>/dev/null; echo "0 3 * * * $CLEANUP_SCRIPT") | crontab -

