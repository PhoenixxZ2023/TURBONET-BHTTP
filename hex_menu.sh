#!/bin/bash

# ═══════════════════════════════════════════════════════════════
#  MANAGER - MENU DE GERENCIAMENTO COMPLETO (v1.1.2)
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
#!/bin/bash
# hex_cleanup v2 - remove contas gerenciadas que expiraram
# - só mexe em contas do grupo hexusers com UID >= 1000
# - linha inválida/data inválida NUNCA apaga a conta (antes virava "expirado")
# - aceita ':' dentro da senha (usa o primeiro e o último campo)
# - usa a mesma trava de arquivo do painel web
HEX_DIR="${HEX_DIR:-/etc/hex}"
USER_DB="$HEX_DIR/users.txt"
LOG_FILE="${HEX_CLEANUP_LOG:-/var/log/hex-cleanup.log}"
USER_GROUP="hexusers"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"; }

[ -s "$USER_DB" ] || exit 0

exec 9>"$HEX_DIR/.users.lock"
flock 9

now=$(date +%s)
tmp=$(mktemp "$HEX_DIR/users.XXXXXX") || { log "ERRO: mktemp falhou"; exit 1; }
trap 'rm -f "$tmp"' EXIT
deleted=0; kept_invalid=0; failed=0

while IFS= read -r line || [ -n "$line" ]; do
    [ -z "$line" ] && continue
    user=${line%%:*}
    exp=${line##*:}

    if ! [[ "$user" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || ! [[ "$exp" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
        log "AVISO: linha inválida mantida (usuário='${user:0:32}')"
        echo "$line" >> "$tmp"; ((kept_invalid++)); continue
    fi
    if ! exp_ts=$(date -d "$exp" +%s 2>/dev/null); then
        log "AVISO: data inválida '$exp' para $user; conta mantida"
        echo "$line" >> "$tmp"; ((kept_invalid++)); continue
    fi

    if [ "$exp_ts" -ge "$now" ]; then
        echo "$line" >> "$tmp"; continue
    fi

    # expirado: só apaga se for conta gerenciada (grupo hexusers, UID >= 1000)
    if id "$user" >/dev/null 2>&1; then
        uid=$(id -u "$user")
        if [ "$uid" -lt 1000 ] || ! id -nG "$user" | tr ' ' '\n' | grep -qx "$USER_GROUP"; then
            log "AVISO: $user não é conta gerenciada (uid=$uid); NÃO removido, linha descartada do banco"
            continue
        fi
        pkill -KILL -u "$user" 2>/dev/null
        if userdel -r "$user" 2>/dev/null || ! id "$user" >/dev/null 2>&1; then
            ((deleted++))
        else
            log "ERRO: userdel falhou para $user; mantido no banco"
            echo "$line" >> "$tmp"; ((failed++))
        fi
    else
        ((deleted++))   # já não existe no sistema; só limpa a linha
    fi
done < "$USER_DB"

chmod 600 "$tmp"
mv -f "$tmp" "$USER_DB"
trap - EXIT
log "Limpeza concluída. Removidos: $deleted | Linhas inválidas mantidas: $kept_invalid | Falhas: $failed"
EOF_CLEANUP
    chmod +x "$CLEANUP_SCRIPT"
    touch "$CLEANUP_LOG" && chmod 644 "$CLEANUP_LOG"
fi
cron_active=$(crontab -l 2>/dev/null | grep -c "hex_cleanup.sh")
[ "$cron_active" -eq 0 ] && (crontab -l 2>/dev/null; echo "0 3 * * * $CLEANUP_SCRIPT") | crontab -

# ═══════════════════════════════════════════════════════════════
#  FUNÇÕES DE INTERFACE DE USUÁRIO (UI)
# ═══════════════════════════════════════════════════════════════
pause_return() { echo ""; echo -e "  ${CYAN}Pressione ENTER para continuar...${NC}"; read -r; }
ui_top() { echo -e "${ACC}╔════════════════════════════════════════════════════════════╗${NC}"; }
ui_sep() { echo -e "${ACC}╠════════════════════════════════════════════════════════════╣${NC}"; }
ui_bot() { echo -e "${ACC}╚════════════════════════════════════════════════════════════╝${NC}"; }
ui_fila() { echo -e "${ACC}║${NC} $1 ${ACC}║${NC}"; }
ui_titulo() { printf "${ACC}║${NC}                      ${WHITE}${BOLD}%s${NC}                      ${ACC}║${NC}\n" "$1"; }
ui_opcion() { printf "     ${CYAN}[${NC}${YELLOW}$1${NC}${CYAN}]${NC}  $2\n"; }
ui_info() { echo -e "     ${CYAN}ℹ${NC} ${GRIS}$1${NC}"; }
ui_ok() { echo -e "     ${GREEN}✓${NC} ${WHITE}$1${NC}"; }
ui_error() { echo -e "     ${RED}✗${NC} ${RED}$1${NC}"; }

# ── validação e banco de usuários (seguros para senhas com / & \ e ':') ──
UDPGW_PUBLIC_FLAG="/etc/hex/udpgw_public"
valid_username() { [[ "$1" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; }
valid_user_password() { [[ ${#1} -ge 4 && ${#1} -le 64 && "$1" != *:* && "$1" =~ ^[[:print:]]+$ ]]; }
db_lock() { exec 8>"/etc/hex/.users.lock"; flock 8; }
db_has() { awk -F: -v u="$1" '$1==u{f=1} END{exit !f}' "$USER_DB"; }
# db_update <usuário> pass|exp|delete [valor]   (chamar dentro de: ( db_lock; db_update ... ))
db_update() {
    local user="$1" field="$2" value="${3:-}" tmp
    tmp=$(mktemp /etc/hex/users.XXXXXX) || return 1
    if HEX_U="$user" HEX_F="$field" HEX_V="$value" awk '
        { n=split($0,a,":"); u=a[1]; e=a[n]
          if (u != ENVIRON["HEX_U"] || n < 3) { print; next }
          p=substr($0, length(u)+2, length($0)-length(u)-length(e)-2)
          if (ENVIRON["HEX_F"]=="delete") next
          if (ENVIRON["HEX_F"]=="pass") p=ENVIRON["HEX_V"]
          if (ENVIRON["HEX_F"]=="exp") e=ENVIRON["HEX_V"]
          print u ":" p ":" e }' "$USER_DB" > "$tmp"; then
        chmod 600 "$tmp" && mv -f "$tmp" "$USER_DB"
    else
        rm -f "$tmp"; return 1
    fi
}

get_svc_status() {
    local svc=$1 conf=$2
    local total=0 active=0
    if [ -f "$conf" ]; then
        while read -r port; do
            [ -z "$port" ] && continue; ((total++))
            systemctl is-active --quiet "${svc}@${port}.service" 2>/dev/null && ((active++))
        done < "$conf"
    fi
    if [ "$total" -eq 0 ]; then echo "${RED}● SEM PORTAS${NC} (0)"
    elif [ "$active" -eq "$total" ]; then echo "${GREEN}● ATIVO${NC} ($active/$total)"
    elif [ "$active" -gt 0 ]; then echo "${YELLOW}● PARCIAL${NC} ($active/$total)"
    else echo "${RED}● INATIVO${NC} (0/$total)"; fi
}

# ═══════════════════════════════════════════════════════════════
#  SISTEMA DE ATUALIZAÇÃO AUTOMÁTICA
# ═══════════════════════════════════════════════════════════════

verificar_atualizacoes() {
    ui_info "Verificando atualizações disponíveis..."
    
    local remote_info=$(curl -fsSL --connect-timeout 10 "${GITHUB_RAW}/version.json" 2>/dev/null)
    
    if [ -z "$remote_info" ]; then
        ui_error "Não foi possível conectar ao repositório"
        return 1
    fi
    
    local remote_version=$(echo "$remote_info" | grep -o '"version": *"[^"]*"' | head -1 | cut -d'"' -f4)
    local changelog=$(echo "$remote_info" | grep -o '"changelog": *"[^"]*"' | head -1 | cut -d'"' -f4)
    
    if [ -z "$remote_version" ]; then
        ui_error "Não foi possível obter a versão remota"
        return 1
    fi
    
    # Comparação semântica de versões
    local comparison=$(comparar_versoes "$remote_version" "$HEX_VERSION")
    
    if [ "$comparison" -eq 1 ]; then
        echo ""
        ui_fila "  ${YELLOW}⚠ Nova versão disponível: ${BOLD}$remote_version${NC}"
        ui_fila "  ${GRIS}Versão atual: $HEX_VERSION${NC}"
        ui_fila "  ${GRIS}Mudanças: $changelog${NC}"
        ui_fila ""
        return 0
    elif [ "$comparison" -eq -1 ]; then
        ui_ok "Sua versão ($HEX_VERSION) é mais nova que a do repositório ($remote_version)"
        return 1
    else
        ui_ok "Você está usando a última versão ($HEX_VERSION)"
        return 1
    fi
}

comparar_versoes() {
    local v1=$1 v2=$2
    
    # Normalizar versões
    local p1=(${v1//./ })
    local p2=(${v2//./ })
    
    # Preencher com zeros
    while [ ${#p1[@]} -lt 3 ]; do p1+=("0"); done
    while [ ${#p2[@]} -lt 3 ]; do p2+=("0"); done
    
    # Comparar
    for i in 0 1 2; do
        if [ "${p1[$i]}" -gt "${p2[$i]}" ]; then
            echo 1; return
        elif [ "${p1[$i]}" -lt "${p2[$i]}" ]; then
            echo -1; return
        fi
    done
    echo 0
}

menu_atualizacoes() {
    clear; ui_top; ui_titulo "ATUALIZAÇÕES"; ui_sep; ui_fila ""
    
    ui_fila "  ${BOLD}Versão atual:${NC} ${YELLOW}$HEX_VERSION${NC}"
    ui_fila ""
    
    if verificar_atualizacoes; then
        ui_sep; ui_fila ""
        
        ui_opcion "1" "Atualizar menu (hex_menu.sh)"
        ui_opcion "2" "Atualizar templates do Painel Web"
        ui_opcion "3" "Atualizar backend do Painel Web (app.py)"
        ui_opcion "4" "Atualizar TUDO (recomendado)"
        ui_opcion "5" "Ver changelog completo"
        ui_opcion "0" "Voltar"
        
        ui_bot; echo ""
        echo -ne "  ${CYAN}►${NC} Selecione a opção: "; read -r opt
        
        case "$opt" in
            1) atualizar_menu ;;
            2) atualizar_templates ;;
            3) atualizar_backend ;;
            4) atualizar_tudo ;;
            5) ver_changelog ;;
            0) menu_principal ;;
            *) echo -e "  ${RED}✗ Opção inválida${NC}"; pause_return; menu_atualizacoes ;;
        esac
    else
        ui_sep; ui_fila ""
        ui_opcion "0" "Voltar"
        ui_bot; echo ""
        echo -ne "  ${CYAN}►${NC} Selecione a opção: "; read -r opt
        case "$opt" in
            0) menu_principal ;;
            *) menu_atualizacoes ;;
        esac
    fi
}

# ── OTA seguro: manifesto + SHA256 + sintaxe + troca atômica ──
hex_obter_manifesto() {
    HEX_MANIFEST=$(mktemp) || return 1
    if curl -fsSL --connect-timeout 10 "${GITHUB_RAW}/version.json" -o "$HEX_MANIFEST" 2>/dev/null && [ -s "$HEX_MANIFEST" ]; then
        return 0
    fi
    rm -f "$HEX_MANIFEST"; return 1
}
hex_sha_esperado() {
    python3 - "$HEX_MANIFEST" "$1" <<'PY'
import json, sys
try:
    print(json.load(open(sys.argv[1])).get("sha256", {}).get(sys.argv[2], ""))
except Exception:
    print("")
PY
}
# hex_instalar_arquivo <caminho-no-repo> <destino> <modo> <sh|py|html>
hex_instalar_arquivo() {
    local rel="$1" dest="$2" mode="$3" kind="$4" tmpf exp got
    tmpf=$(mktemp "$(dirname "$dest")/.dl.XXXXXX") || { ui_error "Sem permissão em $(dirname "$dest")"; return 1; }
    if ! curl -fsSL --connect-timeout 10 --max-time 120 "${GITHUB_RAW}/${rel}" -o "$tmpf" 2>/dev/null || [ ! -s "$tmpf" ]; then
        rm -f "$tmpf"; ui_error "Erro ao baixar $rel"; return 1
    fi
    exp=$(hex_sha_esperado "$rel")
    if [ -n "$exp" ]; then
        got=$(sha256sum "$tmpf" | cut -d' ' -f1)
        if [ "$got" != "$exp" ]; then rm -f "$tmpf"; ui_error "SHA256 não confere para $rel (recusado)"; return 1; fi
    elif [ -f /etc/hex/require_checksum ]; then
        rm -f "$tmpf"; ui_error "version.json sem SHA256 para $rel (recusado)"; return 1
    fi
    case "$kind" in
        sh) bash -n "$tmpf" 2>/dev/null || { rm -f "$tmpf"; ui_error "Erro de sintaxe em $rel"; return 1; } ;;
        py) python3 -c 'import sys; compile(open(sys.argv[1]).read(), sys.argv[1], "exec")' "$tmpf" 2>/dev/null \
                || { rm -f "$tmpf"; ui_error "Erro de sintaxe em $rel"; return 1; } ;;
    esac
    [ -s "$dest" ] && cp -p "$dest" "${dest}.backup.$(date +%Y%m%d_%H%M%S)" 2>/dev/null
    chmod "$mode" "$tmpf" && mv -f "$tmpf" "$dest"
}
hex_escrever_versao() {
    local v
    v=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("version",""))' "$HEX_MANIFEST" 2>/dev/null)
    if [ -n "$v" ]; then echo "$v" > "$VERSION_FILE"; ui_ok "Versão atualizada para $v"; fi
}
hex_atualizar_menu() {
    hex_instalar_arquivo hex_menu.sh /usr/local/bin/hex_menu 755 sh || return 1
    ui_ok "Menu atualizado"
    hex_instalar_arquivo hex_cleanup.sh "$CLEANUP_SCRIPT" 755 sh && ui_ok "Script de limpeza atualizado"
    hex_instalar_arquivo hex_panel_mode.sh /usr/local/bin/hex_panel_mode.sh 755 sh && ui_ok "Módulo de segurança do painel atualizado"
    hex_instalar_arquivo hex_ip.sh /usr/local/bin/hex_ip.sh 755 sh && ui_ok "Detector de IP público atualizado"
    return 0
}
hex_atualizar_templates() {
    [ -d /opt/hex-webpanel/templates ] || { ui_error "O Painel Web não está instalado"; return 1; }
    local ok=0
    hex_instalar_arquivo templates/login.html /opt/hex-webpanel/templates/login.html 644 html && ui_ok "login.html atualizado" || ok=1
    hex_instalar_arquivo templates/dashboard.html /opt/hex-webpanel/templates/dashboard.html 644 html && ui_ok "dashboard.html atualizado" || ok=1
    return $ok
}
hex_atualizar_backend() {
    [ -f /opt/hex-webpanel/app.py ] || { ui_error "O Painel Web não está instalado"; return 1; }
    hex_instalar_arquivo app.py /opt/hex-webpanel/app.py 644 py && ui_ok "Backend atualizado"
}

atualizar_menu() {
    clear; ui_top; ui_titulo "ATUALIZAR MENU"; ui_sep; ui_fila ""
    ui_info "Baixando nova versão do menu (com verificação SHA256)..."
    if hex_obter_manifesto; then
        if hex_atualizar_menu; then
            hex_escrever_versao
            ui_fila " ${YELLOW}⚠ Reinicie o menu para aplicar as mudanças${NC}"
        fi
        rm -f "$HEX_MANIFEST"
    else
        ui_error "Não foi possível baixar o version.json"
    fi
    ui_fila ""; pause_return
    menu_atualizacoes
}

atualizar_templates() {
    clear; ui_top; ui_titulo "ATUALIZAR TEMPLATES"; ui_sep; ui_fila ""
    if hex_obter_manifesto; then
        if hex_atualizar_templates; then
            ui_info "Reiniciando Painel Web..."
            systemctl restart hex-webpanel.service 2>/dev/null
            ui_ok "Templates atualizados e painel reiniciado"
        else
            ui_error "Alguns templates não puderam ser atualizados"
        fi
        rm -f "$HEX_MANIFEST"
    else
        ui_error "Não foi possível baixar o version.json"
    fi
    ui_fila ""; pause_return
    menu_atualizacoes
}

atualizar_backend() {
    clear; ui_top; ui_titulo "ATUALIZAR BACKEND"; ui_sep; ui_fila ""
    if hex_obter_manifesto; then
        if hex_atualizar_backend; then
            ui_info "Reiniciando Painel Web..."
            systemctl restart hex-webpanel.service 2>/dev/null
            ui_ok "Painel Web reiniciado"
        fi
        rm -f "$HEX_MANIFEST"
    else
        ui_error "Não foi possível baixar o version.json"
    fi
    ui_fila ""; pause_return
    menu_atualizacoes
}

atualizar_tudo() {
    clear; ui_top; ui_titulo "ATUALIZAÇÃO COMPLETA"; ui_sep; ui_fila ""
    echo -ne "  ${YELLOW}⚠ Isso atualizará o menu, templates e backend. Continuar? (s/n):${NC} "
    read -r confirm
    if [ "$confirm" != "s" ] && [ "$confirm" != "S" ]; then
        ui_info "Cancelado"; pause_return; menu_atualizacoes; return
    fi
    if ! hex_obter_manifesto; then
        ui_error "Não foi possível baixar o version.json"; pause_return; menu_atualizacoes; return
    fi
    ui_info "[1/3] Atualizando menu..."
    hex_atualizar_menu && hex_escrever_versao
    if [ -d /opt/hex-webpanel ]; then
        ui_info "[2/3] Atualizando templates..."; hex_atualizar_templates
        ui_info "[3/3] Atualizando backend...";   hex_atualizar_backend
        ui_info "Reiniciando Painel Web..."
        systemctl restart hex-webpanel.service 2>/dev/null
        ui_ok "Painel Web reiniciado"
    else
        ui_info "[2/3] Painel Web não instalado, ignorando..."
        ui_info "[3/3] Painel Web não instalado, ignorando..."
    fi
    rm -f "$HEX_MANIFEST"
    ui_fila ""; ui_ok "Atualização completa finalizada"
    ui_fila " ${YELLOW}⚠ Reinicie o menu para aplicar todas as mudanças${NC}"
    ui_fila " ${GRIS}Backups salvos em arquivos .backup.*${NC}"
    ui_fila ""; pause_return
    menu_atualizacoes
}

ver_changelog() {
    clear; ui_top; ui_titulo "CHANGELOG"; ui_sep; ui_fila ""
    
    ui_info "Baixando changelog..."
    local changelog=$(curl -fsSL "${GITHUB_RAW}/CHANGELOG.md" 2>/dev/null)
    
    if [ -n "$changelog" ]; then
        echo ""
        echo "$changelog" | less -R
    else
        ui_error "Não foi possível baixar o changelog"
        pause_return
    fi
    
    menu_atualizacoes
}

# ═══════════════════════════════════════════════════════════════
#  MUDAR PORTA DO PAINEL WEB
# ═══════════════════════════════════════════════════════════════

# ── modo de acesso do painel (HTTPS automático) ──
# IPv4 público da VPS (hex_ip.sh); sem o script, cai para o primeiro IP local
ip_publico() {
    local ip
    ip=$(/usr/local/bin/hex_ip.sh 2>/dev/null)
    echo "${ip:-$(hostname -I | awk '{print $1}')}"
}
painel_url() {
    local u
    u=$(/usr/local/bin/hex_panel_mode.sh url 2>/dev/null)
    echo "${u:-http://$(ip_publico):$WEBPANEL_PORT}"
}
ip_script_ok() {
    local sc=/usr/local/bin/hex_ip.sh
    if [ ! -x "$sc" ]; then
        ui_info "Baixando o detector de IP..."
        if hex_obter_manifesto; then
            hex_instalar_arquivo hex_ip.sh "$sc" 755 sh
            rm -f "$HEX_MANIFEST"
        fi
    fi
    [ -x "$sc" ]
}
menu_ip_servidor() {
    local sc=/usr/local/bin/hex_ip.sh ip
    while true; do
        clear; ui_top; ui_titulo "IP DA VPS (usado nas URLs e nas mensagens)"; ui_sep; ui_fila ""
        if ! ip_script_ok; then ui_error "Não foi possível obter o detector de IP"; pause_return; return; fi
        "$sc" status | while IFS= read -r linha; do ui_fila "  $linha"; done
        if "$sc" nat 2>/dev/null; then
            ui_fila ""
            ui_fila "  ${YELLOW}⚠ Libere também no firewall do PROVEDOR (Security List/Group):${NC}"
            ui_fila "    BHTTP: $(paste -sd, "$BHTTP_PORTS_CONF" 2>/dev/null)  HCR: $(paste -sd, "$HCR_PORTS_CONF" 2>/dev/null)  Painel: $WEBPANEL_PORT"
        fi
        ui_fila ""; ui_sep; ui_fila ""
        ui_opcion "1" "Descobrir o IP de novo"
        ui_opcion "2" "Definir o IP manualmente"
        ui_opcion "3" "Voltar à detecção automática"
        ui_opcion "0" "Voltar"
        ui_bot; echo ""; echo -ne "  ${CYAN}►${NC} Selecione a opção: "; read -r opt
        case "$opt" in
            1) ip=$("$sc" refresh); echo -e "  ${GREEN}✓ IP detectado: $ip${NC}"; pause_return ;;
            2) echo -ne "  ${WHITE}IPv4 da VPS:${NC} "; read -r ip
               if "$sc" set "$ip" >/dev/null 2>&1; then echo -e "  ${GREEN}✓ IP definido: $ip${NC}"
               else echo -e "  ${RED}✗ IPv4 inválido${NC}"; fi; pause_return ;;
            3) ip=$("$sc" unset); echo -e "  ${GREEN}✓ Detecção automática: $ip${NC}"; pause_return ;;
            0) return ;;
            *) echo -e "  ${RED}✗ Opção inválida${NC}"; pause_return ;;
        esac
    done
}
painel_modo_script() {
    local sc=/usr/local/bin/hex_panel_mode.sh
    if [ ! -x "$sc" ]; then
        ui_info "Baixando o módulo de segurança do painel..."
        if hex_obter_manifesto; then
            hex_instalar_arquivo hex_panel_mode.sh "$sc" 755 sh
            rm -f "$HEX_MANIFEST"
        fi
    fi
    [ -x "$sc" ]
}
menu_seguranca_painel() {
    local sc=/usr/local/bin/hex_panel_mode.sh
    while true; do
        clear; ui_top; ui_titulo "SEGURANÇA DO ACESSO AO PAINEL"; ui_sep; ui_fila ""
        if ! painel_modo_script; then
            ui_error "Não foi possível obter o módulo (sem internet?)"; pause_return; return
        fi
        "$sc" status | while IFS= read -r linha; do ui_fila "  $linha"; done
        ui_fila ""; ui_sep; ui_fila ""
        ui_opcion "1" "Ativar HTTPS ${GREEN}(recomendado)${NC} - criptografa a senha"
        ui_opcion "2" "Voltar para HTTP simples"
        ui_opcion "3" "Gerar novo certificado HTTPS"
        ui_opcion "4" "Somente local (127.0.0.1) ${GRIS}- avançado${NC}"
        ui_opcion "5" "Liberar acesso externo"
        ui_opcion "0" "Voltar"
        ui_bot; echo ""; echo -ne "  ${CYAN}►${NC} Selecione a opção: "; read -r opt
        case "$opt" in
            1) echo ""; "$sc" https; WEBPANEL_PORT=$(cat "$WEBPANEL_PORT_FILE" 2>/dev/null || echo 9000); pause_return ;;
            2) echo -ne "  ${YELLOW}⚠ A senha do painel voltará a trafegar sem criptografia. Continuar? (s/n):${NC} "; read -r c
               if [ "$c" = "s" ] || [ "$c" = "S" ]; then echo ""; "$sc" http; fi; pause_return ;;
            3) echo ""; "$sc" https --renew; pause_return ;;
            4) echo -e "  ${YELLOW}⚠ O painel deixará de abrir por IP:PORTA. Você só acessará por túnel SSH ou proxy.${NC}"
               echo -ne "  ${YELLOW}Continuar? (s/n):${NC} "; read -r c
               if [ "$c" = "s" ] || [ "$c" = "S" ]; then echo ""; "$sc" local; fi; pause_return ;;
            5) echo ""; "$sc" external; pause_return ;;
            0) return ;;
            *) echo -e "  ${RED}✗ Opção inválida${NC}"; pause_return ;;
        esac
    done
}

mudar_porta_webpanel() {
    clear; ui_top; ui_titulo "MUDAR PORTA DO PAINEL"; ui_sep; ui_fila ""
    
    ui_fila "  ${BOLD}Porta atual:${NC} ${YELLOW}$WEBPANEL_PORT${NC}"
    ui_fila "  ${GRIS}URL atual: $(painel_url)${NC}"
    ui_fila ""
    ui_sep; ui_fila ""
    
    echo -ne "  ${WHITE}Nova porta (1-65535):${NC} "
    read -r new_port
    
    if ! [[ "$new_port" =~ ^[0-9]+$ ]]; then
        echo -e "  ${RED}✗ Deve ser um número${NC}"
        pause_return; return
    fi
    
    if [ "$new_port" -lt 1 ] || [ "$new_port" -gt 65535 ]; then
        echo -e "  ${RED}✗ A porta deve estar entre 1 e 65535${NC}"
        pause_return; return
    fi
    
    if [ "$new_port" -eq "$WEBPANEL_PORT" ]; then
        echo -e "  ${YELLOW}⚠ Essa é a porta atual${NC}"
        pause_return; return
    fi
    
    if ss -tuln | grep -q ":$new_port "; then
        echo -e "  ${RED}✗ A porta $new_port já está em uso por outro serviço${NC}"
        pause_return; return
    fi
    
    echo ""
    echo -ne "  ${YELLOW}⚠ Mudar a porta de $WEBPANEL_PORT para $new_port. Continuar? (s/n):${NC} "
    read -r confirm
    if [ "$confirm" != "s" ] && [ "$confirm" != "S" ]; then
        ui_info "Cancelado"
        pause_return; return
    fi
    
    local old_port=$WEBPANEL_PORT
    
    ui_info "Parando o Painel Web..."
    systemctl stop hex-webpanel.service 2>/dev/null
    
    ui_info "Atualizando configuração..."
    echo "$new_port" > "$WEBPANEL_PORT_FILE"
    chmod 644 "$WEBPANEL_PORT_FILE"
    
    ui_info "Atualizando firewall..."
    iptables -D INPUT -p tcp --dport $old_port -j ACCEPT 2>/dev/null
    iptables -I INPUT -p tcp --dport $new_port -j ACCEPT 2>/dev/null
    command -v ufw >/dev/null 2>&1 && {
        ufw delete allow $old_port/tcp >/dev/null 2>&1
        ufw allow $new_port/tcp >/dev/null 2>&1
    }
    
    ui_info "Reiniciando Painel Web..."
    systemctl start hex-webpanel.service
    sleep 2
    
    WEBPANEL_PORT=$new_port
    
    if systemctl is-active --quiet hex-webpanel.service; then
        ui_ok "Porta alterada com sucesso"
        ui_fila ""
        ui_fila "  ${BOLD}Nova porta:${NC}  ${YELLOW}$new_port${NC}"
        ui_fila "  ${BOLD}Nova URL:${NC}    ${CYAN}$(painel_url)${NC}"
        ui_fila ""
        ui_fila "  ${YELLOW}⚠ Use a nova URL para acessar o painel${NC}"
    else
        ui_error "O painel não pôde iniciar com a nova porta"
        ui_info "Restaurando a porta anterior..."
        echo "$old_port" > "$WEBPANEL_PORT_FILE"
        WEBPANEL_PORT=$old_port
        systemctl start hex-webpanel.service
    fi
    
    ui_fila ""; pause_return
}

# ═══════════════════════════════════════════════════════════════
#  MENU PRINCIPAL
# ═══════════════════════════════════════════════════════════════

menu_principal() {
    clear; ui_top; ui_titulo "MANAGER"; ui_sep
    
    bhttp_st=$(get_svc_status "bhttp" "$BHTTP_PORTS_CONF")
    hcr_st=$(get_svc_status "hcr" "$HCR_PORTS_CONF")
    udpgw_st=$(get_svc_status "udpgw" "$UDPGW_PORTS_CONF")
    [ "$cron_active" -gt 0 ] && cleanup_status="${GREEN}● ATIVO${NC}" || cleanup_status="${RED}● INATIVO${NC}"
    
    webpanel_state=$(systemctl is-active $WEBPANEL_SERVICE 2>/dev/null || echo "inactivo")
    [ -f "/opt/hex-webpanel/app.py" ] && [ "$webpanel_state" = "active" ] && webpanel_status="${GREEN}● ATIVO${NC}" || webpanel_status="${RED}● INATIVO${NC}"
    [ ! -f "/opt/hex-webpanel/app.py" ] && webpanel_status="${YELLOW}● NÃO INSTALADO${NC}"
    
    ui_fila ""
    ui_fila "  ${CYAN}BHTTP${NC}      - $bhttp_st"
    ui_fila "  ${CYAN}HCR${NC}        - $hcr_st"
    ui_fila "  ${CYAN}UDPGW${NC}      - $udpgw_st"
    ui_fila "  ${CYAN}PAINEL WEB${NC} - Porta $WEBPANEL_PORT     $webpanel_status"
    ui_fila "  ${CYAN}LIMPADOR${NC}   - Diário 03:00   $cleanup_status"
    ui_fila "  ${CYAN}IP DA VPS${NC}   - $(ip_publico)"
    ui_fila "  ${CYAN}VERSÃO${NC}     - v$HEX_VERSION"
    ui_fila ""; ui_sep
    
    ui_opcion "1" "Gerenciar BHTTP"
    ui_opcion "2" "Gerenciar HCR"
    ui_opcion "3" "Gerenciar UDPGW"
    ui_opcion "4" "Gerenciar Painel Web"
    ui_opcion "5" "Gerenciar Usuários"
    ui_opcion "6" "Ver logs"
    ui_opcion "7" "Buscar atualizações"
    ui_opcion "8" "Desinstalar tudo"
    ui_opcion "9" "IP da VPS (ver / atualizar / definir)"
    ui_opcion "0" "Sair"
    
    ui_bot; echo ""
    echo -ne "  ${CYAN}►${NC} Selecione a opção: "; read -r opcion
    
    case "$opcion" in
        1) menu_generico "bhttp" "BHTTP" "$BHTTP_PORTS_CONF" "tcp" ;;
        2) menu_generico "hcr" "HCR" "$HCR_PORTS_CONF" "tcp" ;;
        3) menu_generico "udpgw" "UDPGW" "$UDPGW_PORTS_CONF" "udp" ;;
        4) gerenciar_webpanel ;;
        5) gerenciar_usuarios ;;
        6) ver_logs ;;
        7) menu_atualizacoes ;;
        8) desinstalar ;;
        9) menu_ip_servidor ;;
        0) exit 0 ;;
        *) echo -e "  ${RED}✗ Opção inválida${NC}"; pause_return; menu_principal ;;
    esac
}

# ═══════════════════════════════════════════════════════════════
#  GERENCIAMENTO GENÉRICO DE SERVIÇOS
# ═══════════════════════════════════════════════════════════════

menu_generico() {
    local svc=$1 title=$2 conf=$3 proto=$4
    while true; do
        clear; ui_top; ui_titulo "GERENCIAMENTO $title"; ui_sep; echo ""
        echo -e "  ${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
        echo -e "  ${CYAN}║${NC}  ${WHITE}${BOLD}Porta       Estado               Protocolo${NC}                 ${CYAN}║${NC}"
        echo -e "  ${CYAN}╠══════════════════════════════════════════════════════════════╣${NC}"
        
        count=0
        if [ -f "$conf" ]; then
            while read -r port; do
                [ -z "$port" ] && continue; ((count++))
                systemctl is-active --quiet "${svc}@${port}.service" 2>/dev/null && status="${GREEN}● ATIVO${NC}    " || status="${RED}● INATIVO${NC}  "
                printf "  ${CYAN}║${NC}  ${YELLOW}%-10s${NC} %b  ${GRIS}%s${NC}                     ${CYAN}║${NC}\n" "$port" "$status" "$proto"
            done < "$conf"
        fi
        [ "$count" -eq 0 ] && echo -e "  ${CYAN}║${NC}  ${YELLOW}Nenhuma porta configurada${NC}                            ${CYAN}║${NC}"
        echo -e "  ${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"; echo ""
        ui_sep; ui_fila ""
        
        ui_opcion "1" "Adicionar porta"
        ui_opcion "2" "Remover porta"
        ui_opcion "3" "Iniciar todos"
        ui_opcion "4" "Parar todos"
        ui_opcion "5" "Reiniciar todos"
        ui_opcion "6" "Controle individual"
        ui_opcion "0" "Voltar"
        ui_bot; echo ""; echo -ne "  ${CYAN}►${NC} Selecione a opção: "; read -r opt
        
        case "$opt" in
            1) generico_adicionar_porta "$svc" "$title" "$conf" "$proto" ;;
            2) generico_remover_porta "$svc" "$title" "$conf" "$proto" ;;
            3) generico_acao_todos "$svc" "$conf" "start" "iniciado"; pause_return ;;
            4) generico_acao_todos "$svc" "$conf" "stop" "parado"; pause_return ;;
            5) generico_acao_todos "$svc" "$conf" "restart" "reiniciado"; pause_return ;;
            6) generico_controle_individual "$svc" "$conf"; pause_return ;;
            0) break ;; *) echo -e "  ${RED}✗ Opção inválida${NC}"; pause_return ;;
        esac
    done
    menu_principal
}

generico_adicionar_porta() {
    local svc=$1 title=$2 conf=$3 proto=$4
    clear; ui_top; ui_titulo "ADICIONAR PORTA $title"; ui_sep; ui_fila ""
    echo -ne "  ${WHITE}Número da porta:${NC} "; read -r new_port
    if ! [[ "$new_port" =~ ^[0-9]+$ ]] || [ "$new_port" -lt 1 ] || [ "$new_port" -gt 65535 ]; then
        echo -e "  ${RED}✗ Porta inválida${NC}"; pause_return; return
    fi
    grep -qw "^$new_port$" "$conf" 2>/dev/null && { echo -e "  ${RED}✗ A porta já está configurada${NC}"; pause_return; return; }
    ss -tuln | grep -q ":$new_port " && { echo -e "  ${RED}✗ A porta já está em uso${NC}"; pause_return; return; }
    
    echo "$new_port" >> "$conf"
    # UDPGW escuta em 127.0.0.1 por padrão: só abre o firewall no modo público (/etc/hex/udpgw_public)
    if [ "$svc" != "udpgw" ] || [ -f "$UDPGW_PUBLIC_FLAG" ]; then
        iptables -C INPUT -p "$proto" --dport "$new_port" -j ACCEPT 2>/dev/null || iptables -I INPUT -p "$proto" --dport "$new_port" -j ACCEPT 2>/dev/null
        [ "$proto" == "udp" ] && { iptables -C INPUT -p tcp --dport "$new_port" -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport "$new_port" -j ACCEPT 2>/dev/null; }
        command -v ufw >/dev/null 2>&1 && { ufw allow "$new_port/$proto" >/dev/null 2>&1; [ "$proto" == "udp" ] && ufw allow "$new_port/tcp" >/dev/null 2>&1; }
    fi
    
    systemctl enable "${svc}@${new_port}.service" >/dev/null 2>&1
    systemctl start "${svc}@${new_port}.service" 2>/dev/null
    sleep 1
    systemctl is-active --quiet "${svc}@${new_port}.service" 2>/dev/null && echo -e "  ${GREEN}✓ Porta $new_port adicionada e ativa${NC}" || echo -e "  ${YELLOW}⚠ Porta adicionada, mas não iniciou${NC}"
    pause_return
}

generico_remover_porta() {
    local svc=$1 title=$2 conf=$3 proto=$4
    clear; ui_top; ui_titulo "REMOVER PORTA $title"; ui_sep; ui_fila ""
    [ ! -s "$conf" ] && { echo -e "  ${YELLOW}Não há portas configuradas${NC}"; pause_return; return; }
    
    echo -e "  ${CYAN}Portas atuais:${NC}"; echo ""
    counter=1
    while read -r port; do
        [ -z "$port" ] && continue
        systemctl is-active --quiet "${svc}@${port}.service" 2>/dev/null && status="${GREEN}● ATIVO${NC}" || status="${RED}● INATIVO${NC}"
        printf "    ${YELLOW}[%s]${NC} Porta ${WHITE}%s${NC}  %b\n" "$counter" "$port" "$status"; ((counter++))
    done < "$conf"
    echo ""
    
    echo -ne "  ${WHITE}Número da porta a remover:${NC} "; read -r del_port
    grep -qw "^$del_port$" "$conf" || { echo -e "  ${RED}✗ A porta não existe${NC}"; pause_return; return; }
    
    systemctl stop "${svc}@${del_port}.service" 2>/dev/null
    systemctl disable "${svc}@${del_port}.service" 2>/dev/null
    sed -i "/^${del_port}$/d" "$conf"
    iptables -D INPUT -p $proto --dport $del_port -j ACCEPT 2>/dev/null
    [ "$proto" == "udp" ] && iptables -D INPUT -p tcp --dport $del_port -j ACCEPT 2>/dev/null
    command -v ufw >/dev/null 2>&1 && { ufw delete allow $del_port/$proto >/dev/null 2>&1; [ "$proto" == "udp" ] && ufw delete allow $del_port/tcp >/dev/null 2>&1; }
    
    echo -e "  ${GREEN}✓ Porta $del_port removida completamente${NC}"; pause_return
}

generico_acao_todos() {
    local svc=$1 conf=$2 action=$3 msg=$4
    # Traduzir o prefixo de ação para o console
    local action_pt
    case "$action" in
        "start") action_pt="Iniciando" ;;
        "stop") action_pt="Parando" ;;
        "restart") action_pt="Reiniciando" ;;
    esac
    echo -e "  ${CYAN}${action_pt} todas as portas $svc...${NC}"
    [ -f "$conf" ] && while read -r port; do 
        [ -z "$port" ] && continue
        systemctl $action "${svc}@${port}.service" 2>/dev/null
        echo -e "  ${GREEN}✓ Porta $port $msg${NC}"
    done < "$conf"
}

generico_controle_individual() {
    local svc=$1 conf=$2
    clear; ui_top; ui_titulo "CONTROLE INDIVIDUAL"; ui_sep; ui_fila ""
    echo -e "  ${CYAN}Portas disponíveis:${NC}"; echo ""
    counter=1
    while read -r port; do
        [ -z "$port" ] && continue
        systemctl is-active --quiet "${svc}@${port}.service" 2>/dev/null && status="${GREEN}● ATIVO${NC}" || status="${RED}● INATIVO${NC}"
        printf "    ${YELLOW}[%s]${NC} Porta ${WHITE}%s${NC}  %b\n" "$counter" "$port" "$status"; ((counter++))
    done < "$conf"
    echo ""; echo -ne "  ${WHITE}Número da porta:${NC} "; read -r target_port
    grep -qw "^$target_port$" "$conf" || { echo -e "  ${RED}✗ Porta não encontrada${NC}"; return; }
    
    echo ""; echo -e "  ${CYAN}Ações para a porta $target_port:${NC}"; echo ""
    ui_opcion "1" "Iniciar"; ui_opcion "2" "Parar"; ui_opcion "3" "Reiniciar"; ui_opcion "4" "Ver estado"; ui_opcion "0" "Cancelar"
    echo ""; echo -ne "  ${CYAN}►${NC} Opção: "; read -r action
    case "$action" in
        1) systemctl start "${svc}@${target_port}.service"; echo -e "  ${GREEN}✓ Iniciado${NC}" ;;
        2) systemctl stop "${svc}@${target_port}.service"; echo -e "  ${GREEN}✓ Parado${NC}" ;;
        3) systemctl restart "${svc}@${target_port}.service"; echo -e "  ${GREEN}✓ Reiniciado${NC}" ;;
        4) systemctl status "${svc}@${target_port}.service" --no-pager ;;
        0) return ;; *) echo -e "  ${RED}✗ Opção inválida${NC}" ;;
    esac
}

# ═══════════════════════════════════════════════════════════════
#  INSTALAÇÃO DO PAINEL WEB
# ═══════════════════════════════════════════════════════════════

instalar_painel_web_automatico() {
    clear; ui_top; ui_titulo "INSTALANDO PAINEL WEB"; ui_sep; ui_fila ""
    ui_info "Este processo pode levar alguns minutos..."
    local wp
    wp=$(mktemp) || return
    if hex_obter_manifesto && hex_instalar_arquivo install_webpanel.sh "$wp" 755 sh; then
        HEX_GITHUB_RAW="$GITHUB_RAW" bash "$wp" || ui_error "O instalador do painel terminou com erro"
        rm -f "$HEX_MANIFEST"
    else
        ui_error "Não foi possível obter o instalador do painel"
    fi
    rm -f "$wp"
    WEBPANEL_PORT=$(cat "$WEBPANEL_PORT_FILE" 2>/dev/null || echo "9000")
    pause_return
}

gerenciar_webpanel() {
    while true; do
        clear; ui_top; ui_titulo "GERENCIAMENTO PAINEL WEB"; ui_sep
        
        if [ ! -f "/opt/hex-webpanel/app.py" ]; then
            ui_fila "  Estado: ${RED}● NÃO INSTALADO${NC}"
            ui_fila "  ${GRIS}O painel web ainda não foi configurado${NC}"
            ui_sep; ui_fila ""
            
            ui_opcion "1" "Instalar Painel Web (Automático)"
            ui_opcion "0" "Voltar"
            
            ui_bot; echo ""; echo -ne "  ${CYAN}►${NC} Selecione a opção: "; read -r opt
            
            case "$opt" in
                1) instalar_painel_web_automatico ;;
                0) break ;;
                *) echo -e "  ${RED}✗ Opção inválida${NC}"; pause_return ;;
            esac
        else
            webpanel_state=$(systemctl is-active hex-webpanel.service 2>/dev/null || echo "inativo")
            [ "$webpanel_state" = "active" ] && webpanel_status="${GREEN}● ATIVO${NC}" || webpanel_status="${RED}● INATIVO${NC}"
            
            ui_fila "  Estado: $webpanel_status  │  Porta: ${YELLOW}$WEBPANEL_PORT${NC}"
            ui_fila "  URL: ${CYAN}$(painel_url)${NC}"
            ui_sep; ui_fila ""
            
            ui_opcion "1" "Iniciar Painel Web"
            ui_opcion "2" "Parar Painel Web"
            ui_opcion "3" "Reiniciar Painel Web"
            ui_opcion "4" "Ver estado detalhado"
            ui_opcion "5" "Mudar porta do painel"
            ui_opcion "6" "Ver logs do painel"
            ui_opcion "7" "Desinstalar Painel Web"
            ui_opcion "8" "Segurança do acesso (HTTPS)"
            ui_opcion "0" "Voltar"
            
            ui_bot; echo ""; echo -ne "  ${CYAN}►${NC} Selecione a opção: "; read -r opt
            
            case "$opt" in
                1) systemctl start hex-webpanel.service; sleep 1; systemctl is-active --quiet hex-webpanel.service && echo -e "  ${GREEN}✓ Painel Web iniciado${NC}" || echo -e "  ${RED}✗ Erro ao iniciar${NC}"; pause_return ;;
                2) systemctl stop hex-webpanel.service; echo -e "  ${GREEN}✓ Painel Web parado${NC}"; pause_return ;;
                3) systemctl restart hex-webpanel.service; echo -e "  ${GREEN}✓ Painel Web reiniciado${NC}"; pause_return ;;
                4) echo ""; systemctl status hex-webpanel.service --no-pager; pause_return ;;
                5) mudar_porta_webpanel ;;
                8) menu_seguranca_painel ;;
                6) echo ""; journalctl -u hex-webpanel.service -n 50 --no-pager; pause_return ;;
                7)
                    echo -e "  ${CYAN}Desinstalando Painel Web...${NC}"
                    systemctl stop hex-webpanel.service 2>/dev/null
                    systemctl disable hex-webpanel.service 2>/dev/null
                    rm -f /etc/systemd/system/hex-webpanel.service
                    rm -rf /opt/hex-webpanel
                    rm -f "$WEBPANEL_PORT_FILE"
                    systemctl daemon-reload
                    echo -e "  ${GREEN}✓ Painel Web desinstalado${NC}"; pause_return
                    ;;
                0) break ;;
                *) echo -e "  ${RED}✗ Opção inválida${NC}"; pause_return ;;
            esac
        fi
    done
    menu_principal
}

# ═══════════════════════════════════════════════════════════════
#  GERENCIAMENTO DE USUÁRIOS (SUBMENU)
# ═══════════════════════════════════════════════════════════════

gerenciar_usuarios() {
    while true; do
        clear; ui_top; ui_titulo "GERENCIAMENTO DE USUÁRIOS"; ui_sep; ui_fila ""
        
        total_users=$(wc -l < "$USER_DB" 2>/dev/null || echo "0")
        active_count=0
        expired_count=0
        current_timestamp=$(date +%s)
        
        while IFS=: read -r user pass exp; do
            [ -z "$user" ] && continue
            exp_timestamp=$(date -d "$exp" +%s 2>/dev/null || echo "0")
            if [ "$exp_timestamp" -lt "$current_timestamp" ]; then
                ((expired_count++))
            else
                ((active_count++))
            fi
        done < "$USER_DB"
        
        ui_fila "  ${BOLD}Total de usuários:${NC} ${YELLOW}$total_users${NC}  │  ${GREEN}Ativos: $active_count${NC}  │  ${RED}Expirados: $expired_count${NC}"
        ui_fila ""
        ui_sep
        
        ui_opcion "1" "Adicionar usuário"
        ui_opcion "2" "Remover usuário"
        ui_opcion "3" "Listar usuários ativos"
        ui_opcion "4" "Limpeza automática"
        ui_opcion "5" "Mudar senha de usuário"
        ui_opcion "6" "Mudar data de expiração"
        ui_opcion "0" "Voltar"
        
        ui_bot; echo ""
        echo -ne "  ${CYAN}►${NC} Selecione a opção: "; read -r opt
        
        case "$opt" in
            1) adicionar_usuario ;;
            2) remover_usuario ;;
            3) listar_usuarios ;;
            4) gerenciar_limpeza ;;
            5) mudar_senha_usuario ;;
            6) mudar_expiracao_usuario ;;
            0) break ;;
            *) echo -e "  ${RED}✗ Opção inválida${NC}"; pause_return ;;
        esac
    done
    menu_principal
}

adicionar_usuario() {
    clear; ui_top; ui_titulo "ADICIONAR USUÁRIO"; ui_sep
    getent group "$USER_GROUP" >/dev/null 2>&1 || groupadd "$USER_GROUP" 2>/dev/null
    echo ""; echo -ne "  ${WHITE}Usuário:${NC} "; read -r new_user
    valid_username "$new_user" || { echo -e "  ${RED}✗ Nome inválido (minúsculas, números, _ e -)${NC}"; pause_return; return; }
    id "$new_user" >/dev/null 2>&1 && { echo -e "  ${RED}✗ Já existe${NC}"; pause_return; return; }
    echo -ne "  ${WHITE}Senha:${NC} "; read -rs new_pass; echo ""
    valid_user_password "$new_pass" || { echo -e "  ${RED}✗ Senha inválida (4 a 64 caracteres, sem ':')${NC}"; pause_return; return; }
    echo -ne "  ${WHITE}Validade (dias):${NC} "; read -r days
    [[ "$days" =~ ^[0-9]+$ ]] && [ "$days" -gt 0 ] && [ "$days" -le 3650 ] || { echo -e "  ${RED}✗ Inválido (1 a 3650)${NC}"; pause_return; return; }

    exp_date=$(date -d "+${days} days" +"%Y-%m-%d")
    user_shell=$(cat /etc/hex/user_shell 2>/dev/null)
    case "$user_shell" in /bin/bash|/bin/sh|/bin/false|/usr/sbin/nologin) ;; *) user_shell=/bin/bash ;; esac
    if ! useradd -m -s "$user_shell" -G "$USER_GROUP" "$new_user" 2>/dev/null; then
        echo -e "  ${RED}✗ Erro ao criar o usuário${NC}"; pause_return; return
    fi
    if ! printf '%s:%s\n' "$new_user" "$new_pass" | chpasswd 2>/dev/null; then
        userdel -r "$new_user" 2>/dev/null
        echo -e "  ${RED}✗ Erro ao definir a senha${NC}"; pause_return; return
    fi
    chage -E "$exp_date" "$new_user" && usermod -e "$exp_date" "$new_user"
    ( db_lock; printf '%s:%s:%s\n' "$new_user" "$new_pass" "$exp_date" >> "$USER_DB" )

    echo ""; echo -e "  ${GREEN}✓ Usuário criado${NC}"
    echo -e "  ${BOLD}IP:${NC} $(ip_publico)"
    echo -e "  ${BOLD}Usuário:${NC} ${YELLOW}${new_user}${NC} | ${BOLD}Senha:${NC} ${YELLOW}${new_pass}${NC} | ${BOLD}Expira em:${NC} ${YELLOW}${exp_date}${NC}"; echo ""
    pause_return
}

remover_usuario() {
    clear; ui_top; ui_titulo "REMOVER USUÁRIO"; ui_sep
    [ ! -s "$USER_DB" ] && { echo -e "  ${YELLOW}Não há usuários${NC}"; pause_return; return; }
    echo ""; echo -e "  ${CYAN}Usuários ativos:${NC}"; echo ""
    cat -n "$USER_DB" | awk -F: '{printf "    ${YELLOW}[%s]${NC} %s (Exp: %s)\n", NR, $1, $NF}' | sed "s/\${YELLOW}/\x1b[38;5;221m/g; s/\${NC}/\x1b[0m/g"; echo ""
    echo -ne "  ${WHITE}Usuário a remover:${NC} "; read -r del_user
    valid_username "$del_user" && db_has "$del_user" || { echo -e "  ${RED}✗ Não é um usuário gerenciado por este menu${NC}"; pause_return; return; }
    pkill -KILL -u "$del_user" 2>/dev/null
    userdel -r "$del_user" 2>/dev/null
    if id "$del_user" >/dev/null 2>&1; then
        echo -e "  ${RED}✗ Não foi possível remover o usuário do sistema${NC}"; pause_return; return
    fi
    ( db_lock; db_update "$del_user" delete )
    echo -e "  ${GREEN}✓ Usuário removido${NC}"; pause_return
}

listar_usuarios() {
    clear; ui_top; ui_titulo "USUÁRIOS ATIVOS"; ui_sep
    [ ! -s "$USER_DB" ] && { echo ""; echo -e "  ${YELLOW}⚠ Não há usuários${NC}"; ui_sep; ui_fila ""; ui_fila "  ${GRIS}Use a opção 1 para adicionar${NC}"; ui_fila ""; pause_return; return; }
    
    total_users=$(wc -l < "$USER_DB"); active_users=0; expired_users=0; expiring_soon=0
    current_timestamp=$(date +%s)
    
    echo ""; echo -e "  ${CYAN}╔═══════════════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "  ${CYAN}║${NC} ${WHITE}${BOLD}#   Usuário          Senha           Expira          Dias Rest.  Estado${NC}          ${CYAN}║${NC}"
    echo -e "  ${CYAN}╠═══════════════════════════════════════════════════════════════════════════════╣${NC}"
    
    counter=1
    while IFS=: read -r user pass exp; do
        if id "$user" >/dev/null 2>&1; then
            exp_timestamp=$(date -d "$exp" +%s 2>/dev/null || echo "0")
            days_left=$(( (exp_timestamp - current_timestamp) / 86400 ))
            
            if [ "$exp_timestamp" -lt "$current_timestamp" ]; then
                status="${RED}● EXPIRADO${NC}"; days_color="${RED}"; ((expired_users++))
            elif [ "$days_left" -le 3 ]; then
                status="${YELLOW}● PRESTES A EXPIRAR${NC}"; days_color="${YELLOW}"; ((expiring_soon++))
            else
                status="${GREEN}● ATIVO${NC}"; days_color="${GREEN}"; ((active_users++))
            fi
            
            [ ${#pass} -gt 3 ] && pass_masked="${pass:0:3}***" || pass_masked="***"
            printf "  ${CYAN}║${NC} ${YELLOW}%-3s${NC} ${WHITE}%-16s${NC} ${GRIS}%-15s${NC} ${WHITE}%-15s${NC} ${days_color}%-11s${NC} %b\n" "$counter" "$user" "$pass_masked" "$exp" "$days_left" "$status"
            ((counter++))
        fi
    done < "$USER_DB"
    
    echo -e "  ${CYAN}╚═══════════════════════════════════════════════════════════════════════════════╝${NC}"; echo ""
    ui_sep; echo ""
    echo -e "  ${BOLD}RESUMO:${NC}"; echo -e "  Total: ${WHITE}$total_users${NC} | Ativos: ${GREEN}$active_users${NC} | Prestes a expirar: ${YELLOW}$expiring_soon${NC} | Expirados: ${RED}$expired_users${NC}"; echo ""
    ui_sep; ui_fila ""; pause_return
}

gerenciar_limpeza() {
    clear; ui_top; ui_titulo "LIMPEZA AUTOMÁTICA"; ui_sep; ui_fila ""
    cron_active=$(crontab -l 2>/dev/null | grep -c "hex_cleanup.sh")
    
    if [ "$cron_active" -gt 0 ]; then
        ui_fila "  Estado: ${GREEN}● ATIVO${NC}"; ui_fila "  ${GRIS}Diariamente às 03:00 AM${NC}"; ui_fila ""
        ui_sep; ui_fila ""
        ui_opcion "1" "Desativar limpeza"; ui_opcion "2" "Executar AGORA"; ui_opcion "3" "Ver log"; ui_opcion "0" "Voltar"
        ui_bot; echo ""; echo -ne "  ${CYAN}►${NC} Opção: "; read -r opt
        case "$opt" in
            1) crontab -l 2>/dev/null | grep -v "hex_cleanup.sh" | crontab -; echo -e "  ${GREEN}✓ Desativada${NC}"; pause_return ;;
            2) $CLEANUP_SCRIPT; echo -e "  ${GREEN}✓ Concluída${NC}"; pause_return ;;
            3) [ -f "$CLEANUP_LOG" ] && tail -50 "$CLEANUP_LOG" | less || { echo -e "  ${YELLOW}Sem log${NC}"; pause_return; } ;;
            0) ;; *) echo -e "  ${RED}✗ Inválida${NC}"; pause_return ;;
        esac
    else
        ui_fila "  Estado: ${RED}● INATIVO${NC}"; ui_fila ""
        ui_sep; ui_fila ""
        ui_opcion "1" "Ativar limpeza"; ui_opcion "2" "Executar AGORA"; ui_opcion "3" "Ver log"; ui_opcion "0" "Voltar"
        ui_bot; echo ""; echo -ne "  ${CYAN}►${NC} Opção: "; read -r opt
        case "$opt" in
            1) (crontab -l 2>/dev/null; echo "0 3 * * * $CLEANUP_SCRIPT") | crontab -; echo -e "  ${GREEN}✓ Ativada${NC}"; pause_return ;;
            2) $CLEANUP_SCRIPT; echo -e "  ${GREEN}✓ Concluída${NC}"; pause_return ;;
            3) [ -f "$CLEANUP_LOG" ] && tail -50 "$CLEANUP_LOG" | less || { echo -e "  ${YELLOW}Sem log${NC}"; pause_return; } ;;
            0) ;; *) echo -e "  ${RED}✗ Inválida${NC}"; pause_return ;;
        esac
    fi
}

mudar_senha_usuario() {
    clear; ui_top; ui_titulo "MUDAR SENHA DE USUÁRIO"; ui_sep
    
    [ ! -s "$USER_DB" ] && { echo -e "  ${YELLOW}Não há usuários registrados${NC}"; pause_return; return; }
    
    echo ""; echo -e "  ${CYAN}Usuários disponíveis:${NC}"; echo ""
    counter=1
    while IFS=: read -r user pass exp; do
        [ -z "$user" ] && continue
        if id "$user" >/dev/null 2>&1; then
            printf "    ${YELLOW}[%s]${NC} ${WHITE}%s${NC}  ${GRIS}(Exp: %s)${NC}\n" "$counter" "$user" "$exp"
            ((counter++))
        fi
    done < "$USER_DB"
    echo ""
    
    echo -ne "  ${WHITE}Usuário a modificar:${NC} "
    read -r target_user
    
    if ! valid_username "$target_user" || ! id "$target_user" >/dev/null 2>&1; then
        echo -e "  ${RED}✗ O usuário '$target_user' não existe no sistema${NC}"
        pause_return; return
    fi
    
    if ! db_has "$target_user"; then
        echo -e "  ${RED}✗ O usuário '$target_user' não está no banco de dados${NC}"
        pause_return; return
    fi
    
    echo -ne "  ${WHITE}Nova senha:${NC} "
    read -rs new_pass; echo ""
    
    if [ -z "$new_pass" ]; then
        echo -e "  ${RED}✗ A senha não pode estar vazia${NC}"
        pause_return; return
    fi
    
    echo -ne "  ${WHITE}Confirmar nova senha:${NC} "
    read -rs confirm_pass; echo ""
    
    if [ "$new_pass" != "$confirm_pass" ]; then
        echo -e "  ${RED}✗ As senhas não coincidem${NC}"
        pause_return; return
    fi
    
    if ! valid_user_password "$new_pass"; then
        echo -e "  ${RED}✗ Senha inválida (4 a 64 caracteres, sem ':')${NC}"; pause_return; return
    fi
    if printf '%s:%s\n' "$target_user" "$new_pass" | chpasswd 2>/dev/null; then
        ( db_lock; db_update "$target_user" pass "$new_pass" )
        echo -e "  ${GREEN}✓ Senha de '$target_user' alterada com sucesso${NC}"
        echo -e "  ${GRIS}O usuário pode acessar com a nova senha${NC}"
    else
        echo -e "  ${RED}✗ Erro ao alterar a senha${NC}"
    fi
    
    pause_return
}

mudar_expiracao_usuario() {
    clear; ui_top; ui_titulo "MUDAR DATA DE EXPIRAÇÃO"; ui_sep
    
    [ ! -s "$USER_DB" ] && { echo -e "  ${YELLOW}Não há usuários registrados${NC}"; pause_return; return; }
    
    echo ""; echo -e "  ${CYAN}Usuários disponíveis:${NC}"; echo ""
    current_timestamp=$(date +%s)
    counter=1
    
    while IFS=: read -r user pass exp; do
        [ -z "$user" ] && continue
        if id "$user" >/dev/null 2>&1; then
            exp_timestamp=$(date -d "$exp" +%s 2>/dev/null || echo "0")
            days_left=$(( (exp_timestamp - current_timestamp) / 86400 ))
            
            if [ "$exp_timestamp" -lt "$current_timestamp" ]; then
                status="${RED}● EXPIRADO${NC}"
            elif [ "$days_left" -le 3 ]; then
                status="${YELLOW}● $days_left dias${NC}"
            else
                status="${GREEN}● $days_left dias${NC}"
            fi
            
            printf "    ${YELLOW}[%s]${NC} ${WHITE}%-15s${NC}  ${GRIS}Exp: %s${NC}  %b\n" "$counter" "$user" "$exp" "$status"
            ((counter++))
        fi
    done < "$USER_DB"
    echo ""
    
    echo -ne "  ${WHITE}Usuário a modificar:${NC} "
    read -r target_user
    
    if ! valid_username "$target_user" || ! id "$target_user" >/dev/null 2>&1; then
        echo -e "  ${RED}✗ O usuário '$target_user' não existe no sistema${NC}"
        pause_return; return
    fi
    
    if ! db_has "$target_user"; then
        echo -e "  ${RED}✗ O usuário '$target_user' não está no banco de dados${NC}"
        pause_return; return
    fi
    
    current_exp=$(awk -F':' -v u="$target_user" '$1==u{print $NF}' "$USER_DB")
    echo ""
    echo -e "  ${BOLD}Data atual de expiração:${NC} ${YELLOW}$current_exp${NC}"
    echo ""
    
    ui_opcion "1" "Estender 7 dias"
    ui_opcion "2" "Estender 15 dias"
    ui_opcion "3" "Estender 30 dias"
    ui_opcion "4" "Estender 60 dias"
    ui_opcion "5" "Estender 90 dias"
    ui_opcion "6" "Data personalizada"
    ui_opcion "7" "Remover expiração (permanente)"
    ui_opcion "0" "Cancelar"
    
    echo ""
    echo -ne "  ${CYAN}►${NC} Opção: "; read -r opt
    
    case "$opt" in
        1) days_to_add=7 ;;
        2) days_to_add=15 ;;
        3) days_to_add=30 ;;
        4) days_to_add=60 ;;
        5) days_to_add=90 ;;
        6)
            echo -ne "  ${WHITE}Nova data (YYYY-MM-DD):${NC} "
            read -r custom_date
            if ! [[ "$custom_date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || ! date -d "$custom_date" >/dev/null 2>&1; then
                echo -e "  ${RED}✗ Formato inválido. Use YYYY-MM-DD${NC}"
                pause_return; return
            fi
            new_exp="$custom_date"
            ;;
        7)
            if chage -E -1 "$target_user" 2>/dev/null && usermod -e '' "$target_user" 2>/dev/null; then
                new_exp="2099-12-31"
                ( db_lock; db_update "$target_user" exp "$new_exp" )
                echo -e "  ${GREEN}✓ Expiração removida. O usuário '$target_user' agora é permanente${NC}"
            else
                echo -e "  ${RED}✗ Erro ao remover a expiração${NC}"
            fi
            pause_return; return
            ;;
        0) return ;;
        *) echo -e "  ${RED}✗ Opção inválida${NC}"; pause_return; return ;;
    esac
    
    if [ -n "$days_to_add" ]; then
        exp_timestamp=$(date -d "$current_exp" +%s 2>/dev/null || echo "0")
        if [ "$exp_timestamp" -lt "$current_timestamp" ]; then
            new_exp=$(date -d "+${days_to_add} days" +"%Y-%m-%d")
        else
            new_exp=$(date -d "$current_exp + $days_to_add days" +"%Y-%m-%d")
        fi
    fi
    
    if chage -E "$new_exp" "$target_user" 2>/dev/null && usermod -e "$new_exp" "$target_user" 2>/dev/null; then
        ( db_lock; db_update "$target_user" exp "$new_exp" )
        echo ""
        echo -e "  ${GREEN}✓ Data de expiração atualizada${NC}"
        echo -e "  ${BOLD}Usuário:${NC}    ${YELLOW}$target_user${NC}"
        echo -e "  ${BOLD}Antes:${NC}      ${RED}$current_exp${NC}"
        echo -e "  ${BOLD}Agora:${NC}      ${GREEN}$new_exp${NC}"
    else
        echo -e "  ${RED}✗ Erro ao atualizar a data de expiração${NC}"
    fi
    
    pause_return
}

ver_logs() {
    clear; ui_top; ui_titulo "VER LOGS"; ui_sep; ui_fila ""
    ui_opcion "1" "BHTTP (50 linhas)"; ui_opcion "2" "HCR (50 linhas)"; ui_opcion "3" "UDPGW (todos)"
    ui_opcion "4" "BHTTP (todas)"; ui_opcion "5" "HCR (todas)"; ui_opcion "6" "Limpeza"; ui_opcion "7" "Painel Web"; ui_opcion "0" "Voltar"
    ui_bot; echo ""; echo -ne "  ${CYAN}►${NC} Opção: "; read -r opt
    
    case "$opt" in
        1) journalctl -u "bhttp@*.service" -n 50 --no-pager; pause_return ;;
        2) journalctl -u "hcr@*.service" -n 50 --no-pager; pause_return ;;
        3) [ -f "$UDPGW_PORTS_CONF" ] && while read -r port; do [ -z "$port" ] && continue; echo -e "${YELLOW}═══ Porta $port ═══${NC}"; journalctl -u "udpgw@${port}.service" -n 20 --no-pager; echo ""; done < "$UDPGW_PORTS_CONF"; pause_return ;;
        4) journalctl -u "bhttp@*.service" --no-pager | less ;;
        5) journalctl -u "hcr@*.service" --no-pager | less ;;
        6) [ -f "$CLEANUP_LOG" ] && tail -100 "$CLEANUP_LOG" | less || { echo -e "  ${YELLOW}Sem log${NC}"; pause_return; } ;;
        7) journalctl -u hex-webpanel.service -n 50 --no-pager; pause_return ;;
        0) ;; *) echo -e "  ${RED}✗ Inválida${NC}"; pause_return ;;
    esac
}

desinstalar() {
    clear; ui_top; ui_titulo "DESINSTALAR TUDO"; ui_sep; ui_fila ""
    ui_fila "  ${YELLOW}⚠${NC}  Você está prestes a desinstalar TUDO"
    ui_fila ""; ui_sep
    echo ""; echo -ne "  ${RED}✗ Escreva${NC} ${YELLOW}${BOLD}CONFIRMAR${NC} ${RED}para continuar:${NC} "; read -r confirm
    
    if [ "$confirm" = "CONFIRMAR" ]; then
        echo -e "  ${CYAN}Parando serviços...${NC}"
        for svc in bhttp hcr udpgw; do
            conf="/etc/hex/${svc}_ports.conf"
            [ -f "$conf" ] && while read -r port; do [ -z "$port" ] && continue; systemctl stop "${svc}@${port}.service" 2>/dev/null || true; done < "$conf"
        done
        
        echo -e "  ${CYAN}Removendo Painel Web...${NC}"
        systemctl stop hex-webpanel.service 2>/dev/null || true
        systemctl disable hex-webpanel.service 2>/dev/null || true
        rm -f /etc/systemd/system/hex-webpanel.service
        rm -rf /opt/hex-webpanel
        
        echo -e "  ${CYAN}Removendo arquivos...${NC}"
        rm -f /etc/systemd/system/bhttp@.service /etc/systemd/system/hcr@.service /etc/systemd/system/udpgw@.service
        rm -rf /opt/bhttp /opt/hcr /opt/udpgw /etc/bhttp /etc/hcr /etc/hex
        rm -f /usr/local/bin/hex_menu /usr/bin/hex_menu /usr/local/bin/bhttp /usr/local/bin/hcr /usr/local/bin/hex_cleanup.sh /var/log/hex-cleanup.log
        
        echo -e "  ${CYAN}Removendo usuários hexusers...${NC}"
        getent group "$USER_GROUP" >/dev/null 2>&1 && { for user in $(getent group "$USER_GROUP" | cut -d: -f4 | tr ',' '\n'); do userdel -r "$user" 2>/dev/null; done; groupdel "$USER_GROUP" 2>/dev/null; }
        
        crontab -l 2>/dev/null | grep -v "hex_cleanup.sh" | crontab -
        systemctl daemon-reload >/dev/null 2>&1
        
        echo ""; echo -e "  ${GREEN}✓ Desinstalado completamente${NC}"; echo ""; exit 0
    else
        echo -e "  ${YELLOW}⚠ Cancelado${NC}"; pause_return; menu_principal
    fi
}

# ═══════════════════════════════════════════════════════════════
#  VERIFICAÇÃO E EXECUÇÃO
# ═══════════════════════════════════════════════════════════════

[ "$EUID" -ne 0 ] && { echo -e "  ${RED}✗ Requer permissões de root${NC}"; exit 1; }
menu_principal
