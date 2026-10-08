#!/bin/bash
# ═══════════════════════════════════════════════════════════════
#  PAINEL WEB - INSTALADOR (v1.1.2)
#  Repositório: https://github.com/PhoenixxZ2023/TURBONET-BHTTP
#
#  - baixa app.py e templates do repositório (com SHA256 do version.json)
#  - NÃO embute mais um app.py antigo (a versão embutida tinha senha fixa
#    em texto puro e injeção de comando)
#  - a senha inicial é gerada ALEATORIAMENTE pelo painel no primeiro start
#  - pode ser executado de novo para atualizar sem perder senha/usuários
#  - instalação NOVA já sai com HTTPS ligado (certificado autoassinado criado
#    sozinho); para pular: HEX_INSTALL_HTTPS=0 bash install_webpanel.sh
#  - o modo de acesso depois se muda pelo menu (Painel Web > 8) ou por
#    hex_panel_mode.sh, sem editar arquivo nenhum
# ═══════════════════════════════════════════════════════════════
set -o pipefail
export DEBIAN_FRONTEND=noninteractive

RED='\033[38;5;203m'; GREEN='\033[38;5;84m'; YELLOW='\033[38;5;221m'
CYAN='\033[38;5;51m'; WHITE='\033[38;5;255m'; NC='\033[0m'
BOLD='\033[1m'; ACC='\033[38;5;44m'

GITHUB_RAW="${HEX_GITHUB_RAW:-https://raw.githubusercontent.com/PhoenixxZ2023/TURBONET-BHTTP/main}"
PANEL_DIR="/opt/hex-webpanel"
HEX_DIR="/etc/hex"
PORT_FILE="$HEX_DIR/webpanel_port.conf"
INITIAL_PASS_FILE="$HEX_DIR/webpanel_initial_password.txt"
LOG_FILE="/var/log/hex-installation.log"

ui_top() { echo -e "${ACC}╔════════════════════════════════════════════════════════════╗${NC}"; }
ui_sep() { echo -e "${ACC}╠════════════════════════════════════════════════════════════╣${NC}"; }
ui_bot() { echo -e "${ACC}╚════════════════════════════════════════════════════════════╝${NC}"; }
ui_fila() { echo -e "${ACC}║${NC} $1"; }
ui_titulo() { printf "${ACC}║${NC} ${WHITE}${BOLD}%s${NC}\n" "$1"; }
ui_ok() { echo -e " ${GREEN}✓${NC} ${WHITE}$1${NC}"; }
ui_error() { echo -e " ${RED}✗${NC} ${RED}$1${NC}"; }
ui_info() { echo -e " ${CYAN}ℹ${NC} $1${NC}"; }
ui_warn() { echo -e " ${YELLOW}⚠${NC} ${YELLOW}$1${NC}"; }

baixar_arquivo() {
    local url="$1" destino="$2"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --connect-timeout 15 --max-time 600 --retry 3 -o "$destino" "$url" 2>>"$LOG_FILE"
    else
        wget -q --timeout=30 --tries=3 -O "$destino" "$url" 2>>"$LOG_FILE"
    fi
}

sha_esperado() {
    python3 - "$MANIFEST" "$1" <<'PY'
import json, sys
try:
    print(json.load(open(sys.argv[1])).get("sha256", {}).get(sys.argv[2], ""))
except Exception:
    print("")
PY
}

# baixar_verificado <caminho-no-repo> <destino> <modo>
baixar_verificado() {
    local rel="$1" dest="$2" mode="${3:-644}" tmpf exp got
    tmpf=$(mktemp "$(dirname "$dest")/.dl.XXXXXX") || return 1
    if ! baixar_arquivo "$GITHUB_RAW/$rel" "$tmpf" || [ ! -s "$tmpf" ]; then
        rm -f "$tmpf"; ui_error "Falha ao baixar $rel"; return 1
    fi
    exp=$(sha_esperado "$rel")
    if [ -n "$exp" ]; then
        got=$(sha256sum "$tmpf" | cut -d' ' -f1)
        if [ "$got" != "$exp" ]; then
            rm -f "$tmpf"; ui_error "SHA256 não confere para $rel (arquivo recusado)"; return 2
        fi
    elif [ "${HEX_REQUIRE_CHECKSUM:-0}" = "1" ]; then
        rm -f "$tmpf"; ui_error "version.json sem SHA256 para $rel"; return 2
    else
        ui_warn "version.json sem SHA256 para $rel (sem verificação)"
    fi
    chmod "$mode" "$tmpf" && mv -f "$tmpf" "$dest"
}

verificar_root() {
    [ "$EUID" -eq 0 ] || { echo -e "${RED}✗ Este script requer permissões de root${NC}"; exit 1; }
}

instalar_dependencias() {
    clear; ui_top; ui_titulo "1/5 INSTALANDO DEPENDÊNCIAS"; ui_sep
    ui_info "Atualizando repositórios..."
    apt-get update -y >>"$LOG_FILE" 2>&1
    ui_info "Instalando Python3, venv e curl..."
    apt-get install -y python3 python3-pip python3-venv curl >>"$LOG_FILE" 2>&1 \
        || { ui_error "Falha ao instalar dependências (veja $LOG_FILE)"; exit 1; }
    ui_ok "Dependências instaladas"; sleep 1
}

criar_estrutura() {
    clear; ui_top; ui_titulo "2/5 CRIANDO ESTRUTURA"; ui_sep
    mkdir -p "$PANEL_DIR/templates" "$HEX_DIR"
    chmod 755 "$PANEL_DIR"
    chmod 700 "$HEX_DIR" 2>/dev/null
    if [ ! -x "$PANEL_DIR/venv/bin/python" ]; then
        ui_info "Criando ambiente virtual do Python..."
        python3 -m venv "$PANEL_DIR/venv" >>"$LOG_FILE" 2>&1 || { ui_error "Falha ao criar o venv"; exit 1; }
    fi
    ui_info "Instalando Flask, bcrypt, psutil, waitress e cheroot..."
    "$PANEL_DIR/venv/bin/pip" install --quiet flask flask-login psutil bcrypt waitress cheroot >>"$LOG_FILE" 2>&1 \
        || { ui_error "Falha no pip install (veja $LOG_FILE)"; exit 1; }
    [ -f "$PORT_FILE" ] || echo "9000" > "$PORT_FILE"
    chmod 644 "$PORT_FILE"
    ui_ok "Ambiente configurado"; sleep 1
}

baixar_aplicacao() {
    clear; ui_top; ui_titulo "3/5 BAIXANDO APLICAÇÃO"; ui_sep
    TMPD=$(mktemp -d); trap 'rm -rf "$TMPD"' EXIT
    MANIFEST="$TMPD/version.json"
    ui_info "Baixando version.json..."
    baixar_arquivo "$GITHUB_RAW/version.json" "$MANIFEST" && [ -s "$MANIFEST" ] \
        || { ui_error "Não foi possível baixar o version.json"; exit 1; }
    ui_info "Baixando app.py e templates..."
    baixar_verificado "app.py" "$PANEL_DIR/app.py" 644 || exit 1
    baixar_verificado "templates/login.html" "$PANEL_DIR/templates/login.html" 644 || exit 1
    baixar_verificado "templates/dashboard.html" "$PANEL_DIR/templates/dashboard.html" 644 || exit 1
    baixar_verificado "hex_ip.sh" /usr/local/bin/hex_ip.sh 755 || exit 1
    baixar_verificado "hex_panel_mode.sh" /usr/local/bin/hex_panel_mode.sh 755 || exit 1
    "$PANEL_DIR/venv/bin/python" -m py_compile "$PANEL_DIR/app.py" || { ui_error "app.py com erro de sintaxe"; exit 1; }
    local v
    v=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("version",""))' "$MANIFEST" 2>/dev/null)
    [ -n "$v" ] && [ ! -f "$HEX_DIR/version" ] && echo "$v" > "$HEX_DIR/version"
    ui_ok "Aplicação baixada e verificada"; sleep 1
}

configurar_servico() {
    clear; ui_top; ui_titulo "4/5 CONFIGURANDO SERVIÇO"; ui_sep
    PANEL_PORT=$(cat "$PORT_FILE" 2>/dev/null || echo 9000)
    cat > /etc/systemd/system/hex-webpanel.service <<EOT
[Unit]
Description=Hex Web Panel
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$PANEL_DIR
Environment="PATH=$PANEL_DIR/venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
# Opcional: /etc/hex/webpanel.env  (ex.: HEX_PANEL_HOST=127.0.0.1, HEX_PANEL_HTTPS=1, HEX_TRUSTED_HOSTS=painel.exemplo.com)
EnvironmentFile=-$HEX_DIR/webpanel.env
ExecStart=$PANEL_DIR/venv/bin/python app.py
Restart=always
RestartSec=3
NoNewPrivileges=yes
PrivateTmp=yes
ProtectKernelTunables=yes
ProtectControlGroups=yes

[Install]
WantedBy=multi-user.target
EOT
    systemctl daemon-reload >/dev/null 2>&1
    systemctl enable hex-webpanel.service >/dev/null 2>&1
    ui_info "Abrindo a porta $PANEL_PORT/tcp no firewall..."
    iptables -C INPUT -p tcp --dport "$PANEL_PORT" -j ACCEPT 2>/dev/null \
        || iptables -I INPUT -p tcp --dport "$PANEL_PORT" -j ACCEPT 2>/dev/null
    command -v ufw >/dev/null 2>&1 && ufw allow "$PANEL_PORT/tcp" >/dev/null 2>&1
    local fresh=0
    [ -s "$HEX_DIR/webpanel_admin_pass.conf" ] || fresh=1
    ui_info "Iniciando painel web..."
    systemctl restart hex-webpanel.service
    sleep 2
    if systemctl is-active --quiet hex-webpanel.service; then ui_ok "Painel web ativo"
    else ui_error "O painel não pôde iniciar (journalctl -u hex-webpanel -n 50)"; fi
    # instalação nova: liga o HTTPS sozinho (se falhar, o próprio script volta para HTTP)
    if [ "$fresh" = "1" ] && [ "${HEX_INSTALL_HTTPS:-1}" != "0" ]; then
        ui_info "Ativando HTTPS (certificado autoassinado, automático)..."
        if /usr/local/bin/hex_panel_mode.sh https >>"$LOG_FILE" 2>&1; then ui_ok "HTTPS ativado"
        else ui_warn "Não foi possível ativar o HTTPS agora; o painel segue em HTTP (menu: Painel Web > 8)"; fi
    fi
    sleep 1
}

mostrar_resumo() {
    clear; ui_top; ui_titulo "5/5 ✓ INSTALAÇÃO CONCLUÍDA"; ui_sep
    ui_fila ""
    local url; url=$(/usr/local/bin/hex_panel_mode.sh url 2>/dev/null)
    ui_fila " ${BOLD}URL:${NC} ${CYAN}${url:-http://$(/usr/local/bin/hex_ip.sh 2>/dev/null || hostname -I | awk '{print $1}'):${PANEL_PORT}}${NC}"
    local i=0 pass=""
    while [ $i -lt 15 ] && [ ! -f "$INITIAL_PASS_FILE" ] && [ ! -s "$HEX_DIR/webpanel_admin_pass.conf" ]; do sleep 1; i=$((i+1)); done
    if [ -f "$INITIAL_PASS_FILE" ]; then
        pass=$(sed -n 's/^Senha inicial do painel: //p' "$INITIAL_PASS_FILE")
        ui_fila " ${BOLD}Senha inicial:${NC} ${YELLOW}${pass}${NC}"
        ui_fila " ${RED}${BOLD}⚠ Anote e troque no dashboard.${NC} Arquivo: $INITIAL_PASS_FILE"
    else
        ui_fila " ${BOLD}Senha:${NC} a que você já configurou (mantida)"
    fi
    ui_fila ""
    if [[ "$url" == https://* ]]; then
        ui_fila " ${YELLOW}O navegador vai avisar \"conexão não é particular\"${NC} (certificado criado"
        ui_fila " por este servidor). É normal: ${BOLD}Avançado → Continuar${NC}. A senha vai criptografada."
    else
        ui_fila " ${YELLOW}Painel em HTTP simples.${NC} Para criptografar a senha: ${BOLD}hex_menu → Painel Web → 8${NC}"
    fi
    [[ "$url" == https://* ]] && ui_fila " Mudar o modo de acesso depois: ${BOLD}hex_menu → Painel Web → 8${NC}"
    ui_fila ""; ui_bot; echo ""
}

main() {
    verificar_root
    : > "$LOG_FILE" 2>/dev/null
    instalar_dependencias
    criar_estrutura
    baixar_aplicacao
    configurar_servico
    mostrar_resumo
}

[ "${HEX_SOURCE_ONLY:-0}" = "1" ] || main
