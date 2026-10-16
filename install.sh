#!/bin/bash
# ═══════════════════════════════════════════════════════════════
#  MANAGER - INSTALADOR AUTOMÁTICO (Múltiplas Portas) v1.1.7
#  Repositório: https://github.com/PhoenixxZ2023/TURBONET-BHTTP
#
#  Mudanças em relação à v1.0.1:
#   - baixa do SEU repositório (antes: rogellevi/HCR_BHTTP) e confere SHA256
#   - painel web instalado de verdade (antes era um stub sem app.py)
#   - UDPGW escuta só em 127.0.0.1 por padrão (HEX_UDPGW_PUBLIC=1 para público)
#   - badvpn compilado de tag fixa (1.999.130)
#   - serviços com hardening básico do systemd
#   - firewall idempotente; não sobrescreve *_ports.conf existentes
#   - grava /etc/hex/version; resumo mostra o estado real dos serviços
#   - instalação de pacotes robusta: espera o apt, repete, mostra o erro real, nunca
#     remove pacotes. NÃO instala mais o ufw (ele remove o netfilter-persistent da Oracle)
#   - BHTTP, HCR e UDPGW ficam INSTALADOS e DESATIVADOS: nenhuma porta é aberta nem iniciada.
#     O usuário ativa pelo menu (Gerenciar X > Ativar). Reinstalar religa só o que já estava ativo
# ═══════════════════════════════════════════════════════════════
set -o pipefail
export DEBIAN_FRONTEND=noninteractive

RED='\033[38;5;203m'; GREEN='\033[38;5;84m'; YELLOW='\033[38;5;221m'
CYAN='\033[38;5;51m'; WHITE='\033[38;5;255m'; NC='\033[0m'
BOLD='\033[1m'; ACC='\033[38;5;44m'; GRIS='\033[38;5;245m'

GITHUB_RAW="${HEX_GITHUB_RAW:-https://raw.githubusercontent.com/PhoenixxZ2023/TURBONET-BHTTP/main}"
BADVPN_TAG="1.999.130"
BHTTP_BIN="/opt/bhttp/bhttp-server"
HCR_BIN="/opt/hcr/hcr-server"
UDPGW_BIN="/opt/udpgw/udpgw-server"
HEX_DIR="/etc/hex"
USER_DB="$HEX_DIR/users.txt"
UDPGW_PUBLIC_FLAG="$HEX_DIR/udpgw_public"
INITIAL_PASS_FILE="$HEX_DIR/webpanel_initial_password.txt"
LOG_FILE="/var/log/hex-installation.log"

ui_top() { echo -e "${ACC}╔════════════════════════════════════════════════════════════╗${NC}"; }
ui_sep() { echo -e "${ACC}╠════════════════════════════════════════════════════════════╣${NC}"; }
ui_bot() { echo -e "${ACC}╚════════════════════════════════════════════════════════════╝${NC}"; }
ui_fila() { echo -e "${ACC}║${NC} $1"; }
ui_titulo() { printf "${ACC}║${NC} ${WHITE}${BOLD}%s${NC}\n" "$1"; }
ui_ok() { echo -e " ${GREEN}✓${NC} ${WHITE}$1${NC}"; }
ui_error() { echo -e " ${RED}✗${NC} ${RED}$1${NC}"; }
ui_info() { echo -e " ${CYAN}ℹ${NC} ${GRIS}$1${NC}"; }
ui_warn() { echo -e " ${YELLOW}⚠${NC} ${YELLOW}$1${NC}"; }




# ═══════════════════════════════════════════════════════════════
#  CÓDIGO COMPARTILHADO DOS INSTALADORES (install.sh e install_webpanel.sh)
#  Fonte única: edite AQUI e rode ./build.sh. Usa as funções ui_* de cada instalador.
# ═══════════════════════════════════════════════════════════════

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

# lista as chaves do manifesto que começam com um prefixo (ex.: static/)
listar_manifesto() {
    python3 - "$MANIFEST" "$1" <<'PY'
import json, sys
for k in json.load(open(sys.argv[1])).get("sha256", {}):
    if k.startswith(sys.argv[2]) and ".." not in k and not k.startswith("/"):
        print(k)
PY
}

# baixar_verificado <caminho-no-repo> <destino> <modo>
baixar_verificado() {
    local rel="$1" dest="$2" mode="${3:-644}" base="${HEX_ASSET_BASE:-$GITHUB_RAW}" tmpf exp got
    tmpf=$(mktemp "$(dirname "$dest")/.dl.XXXXXX") || return 1
    if ! baixar_arquivo "$base/$rel" "$tmpf" || [ ! -s "$tmpf" ]; then
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

# ── apt robusto: espera o bloqueio, tenta de novo, NUNCA remove pacotes e mostra o erro real ──
APT_OPTS=(-y --no-remove -o DPkg::Lock::Timeout=600 -o Dpkg::Options::=--force-confold)

apt_atualizar() {
    local t
    for t in 1 2 3; do
        apt-get update -o DPkg::Lock::Timeout=600 >>"$LOG_FILE" 2>&1 && return 0
        ui_info "apt-get update falhou (tentativa $t/3); aguardando..."; sleep 5
    done
    ui_warn "Não foi possível atualizar a lista de pacotes; seguindo com a lista atual"
    return 1
}

# apt_instalar <rótulo> <pacotes...>: 0 = ok; 1 = falhou (e mostra as linhas de erro do apt)
apt_instalar() {
    local rotulo="$1" tmp; shift
    tmp=$(mktemp) || return 1
    if apt-get install "${APT_OPTS[@]}" "$@" >"$tmp" 2>&1; then
        cat "$tmp" >>"$LOG_FILE"; rm -f "$tmp"; return 0
    fi
    cat "$tmp" >>"$LOG_FILE"
    if grep -qE "dpkg was interrupted|dpkg --configure -a" "$tmp"; then
        ui_info "dpkg estava interrompido; reparando e tentando de novo..."
        dpkg --configure -a >>"$LOG_FILE" 2>&1
        apt-get -f install "${APT_OPTS[@]}" >>"$LOG_FILE" 2>&1
        if apt-get install "${APT_OPTS[@]}" "$@" >"$tmp" 2>&1; then
            cat "$tmp" >>"$LOG_FILE"; rm -f "$tmp"; return 0
        fi
        cat "$tmp" >>"$LOG_FILE"
    fi
    ui_error "Falha ao instalar: $rotulo. Erro do apt:"
    { grep -E "^(E:|W:)|rror|lock|held|broken|Unable|Could not" "$tmp" | tail -8; } | sed 's/^/        /'
    rm -f "$tmp"
    return 1
}

# apt_opcional <pacotes...>: tenta em grupo e depois um a um; nunca aborta. Devolve 1 se algum faltou.
apt_opcional() {
    local p miss=0
    apt_instalar "opcionais" "$@" >/dev/null 2>&1 && return 0
    for p in "$@"; do apt_instalar "$p" "$p" >/dev/null 2>&1 || { miss=1; ui_warn "Pacote opcional indisponível: $p"; }; done
    return $miss
}

# firewall: ufw só se já estiver ATIVO; regras do iptables persistem se houver netfilter-persistent (imagens Oracle)
firewall_ufw_ativo() { command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "^Status: active"; }
fw_persistir() { command -v netfilter-persistent >/dev/null 2>&1 && netfilter-persistent save >>"$LOG_FILE" 2>&1; return 0; }

# ═══════════════════════════════════════════════════════════════
#  ASSINATURA DO version.json (Ed25519 via OpenSSL 3, já presente no Ubuntu 22.04+)
#  Fonte única: usado pelos instaladores E pelo menu (via ./build.sh).
#
#  Modelo de confiança: a chave PÚBLICA fica fixada em /etc/hex/release_pub.pem. Depois de fixada,
#  atualização sem assinatura válida é RECUSADA (não dá para "tirar" a assinatura e passar).
#  A chave privada fica só com o dono do projeto, fora do repositório.
# ═══════════════════════════════════════════════════════════════
HEX_PUBKEY="${HEX_PUBKEY:-${HEX_DIR:-/etc/hex}/release_pub.pem}"

# impressão digital da chave pública (SHA-256 do DER), em pares hex separados por ":"
hex_fingerprint() {
    openssl pkey -pubin -in "$1" -outform DER 2>/dev/null | sha256sum | cut -d' ' -f1 | sed 's/../&:/g; s/:$//'
}

# hex_verificar_assinatura <manifesto> <assinatura-base64> <chave.pem>  → 0 = válida
hex_verificar_assinatura() {
    local man=$1 sig=$2 key=$3 bin rc
    [ -s "$man" ] && [ -s "$sig" ] && [ -s "$key" ] || return 1
    bin=$(mktemp) || return 1
    if ! base64 -d "$sig" > "$bin" 2>/dev/null || [ ! -s "$bin" ]; then rm -f "$bin"; return 1; fi
    openssl pkeyutl -verify -pubin -inkey "$key" -rawin -in "$man" -sigfile "$bin" >/dev/null 2>&1
    rc=$?
    rm -f "$bin"
    return $rc
}

# hex_politica_assinatura <manifesto> [assinatura]  → 0 = pode seguir; 1 = recusar (motivo no stdout)
# Com chave fixada a assinatura é obrigatória. HEX_ALLOW_UNSIGNED=1 desliga (só para recuperação).
hex_politica_assinatura() {
    local man=$1 sig=${2:-}
    [ -s "$HEX_PUBKEY" ] || return 0
    [ "${HEX_ALLOW_UNSIGNED:-0}" = "1" ] && return 0
    if [ -n "$sig" ] && hex_verificar_assinatura "$man" "$sig" "$HEX_PUBKEY"; then return 0; fi
    echo "assinatura ausente ou inválida (chave fixada: $(hex_fingerprint "$HEX_PUBKEY"))"
    return 1
}

# campo de primeiro nível do version.json (ex.: release_tag)
manifesto_campo() {
    python3 - "$MANIFEST" "$1" <<'PY'
import json, sys
try:
    v = json.load(open(sys.argv[1])).get(sys.argv[2], "")
    print(v if isinstance(v, str) else "")
except Exception:
    print("")
PY
}

# Binários grandes ficam no GitHub Releases (não pesam no git). Tenta o release indicado no manifesto
# (release_tag); se não houver ou falhar, usa o arquivo do repositório. O SHA256 vale nos dois casos.
baixar_binario() {   # <nome> <destino> <modo>
    local nome="$1" dest="$2" mode="${3:-755}" tag repo="${GITHUB_REPO:-PhoenixxZ2023/TURBONET-BHTTP}"
    tag=$(manifesto_campo release_tag)
    if [ -n "$tag" ]; then
        if HEX_ASSET_BASE="${HEX_RELEASE_BASE:-https://github.com/$repo/releases/download}/$tag" baixar_verificado "$nome" "$dest" "$mode"; then
            return 0
        fi
        ui_warn "Release $tag indisponível para $nome; tentando o repositório..."
    fi
    baixar_verificado "$nome" "$dest" "$mode"
}

# Baixa o version.json + assinatura e aplica a política. Sem chave fixada: tenta fixar a chave publicada em
# keys/release_pub.pem (primeira instalação) e MOSTRA a impressão digital para você conferir com o README.
obter_manifesto() {   # <destino>
    local dest="$1" sig="$1.sig" pub="$1.pub" motivo
    baixar_arquivo "$GITHUB_RAW/version.json" "$dest" && [ -s "$dest" ] || { ui_error "Não foi possível baixar o version.json"; return 1; }
    rm -f "$sig"; baixar_arquivo "$GITHUB_RAW/version.json.sig" "$sig" 2>/dev/null || rm -f "$sig"
    if [ -s "$HEX_PUBKEY" ]; then
        if motivo=$(hex_politica_assinatura "$dest" "$sig"); then
            ui_ok "version.json com assinatura válida"; return 0
        fi
        ui_error "Atualização RECUSADA: $motivo"; return 1
    fi
    rm -f "$pub"; baixar_arquivo "$GITHUB_RAW/keys/release_pub.pem" "$pub" 2>/dev/null || rm -f "$pub"
    if [ -s "$pub" ] && [ -s "$sig" ]; then
        if hex_verificar_assinatura "$dest" "$sig" "$pub"; then
            mkdir -p "$(dirname "$HEX_PUBKEY")"; install -m 644 "$pub" "$HEX_PUBKEY"
            ui_ok "Assinatura válida. Chave de assinatura FIXADA neste servidor."
            ui_info "Impressão digital: $(hex_fingerprint "$HEX_PUBKEY")"
            ui_info "Confira com a divulgada pelo dono do projeto (README/perfil); a partir de agora, versão sem essa assinatura é recusada."
            return 0
        fi
        ui_error "A assinatura do version.json NÃO confere com a chave publicada. Abortando."; return 1
    fi
    ui_warn "Esta versão não está assinada (sem chave publicada). Seguindo apenas com SHA256."
    return 0
}

detectar_arquitetura() {
    case "$(uname -m)" in
        x86_64|amd64) echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        *) ui_error "Arquitetura não suportada: $(uname -m)"; exit 1 ;;
    esac
}


# abrir_porta <proto> <porta>  (idempotente)
abrir_porta() {
    local proto="$1" port="$2"
    iptables -C INPUT -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null \
        || iptables -I INPUT -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null
    firewall_ufw_ativo && ufw allow "$port/$proto" >/dev/null 2>&1
    return 0
}

limpar_instalacao_previa() {
    ui_info "Verificando instalação prévia..."
    systemctl stop bhttp-server.service hcr-server.service 2>/dev/null || true
    local svc instance
    for svc in bhttp hcr udpgw; do
        for instance in $(systemctl list-units --full --all "${svc}@*.service" 2>/dev/null | grep -oP "${svc}@\K[0-9]+"); do
            if systemctl is-active --quiet "${svc}@${instance}.service" 2>/dev/null \
               || systemctl is-enabled --quiet "${svc}@${instance}.service" 2>/dev/null; then
                echo "${svc}@${instance}" >> "$ATIVOS_ANTES"
            fi
            systemctl stop "${svc}@${instance}.service" 2>/dev/null || true
        done
    done
    rm -f /etc/systemd/system/bhttp-server.service /etc/systemd/system/hcr-server.service
    rm -f /etc/systemd/system/bhttp@.service /etc/systemd/system/hcr@.service /etc/systemd/system/udpgw@.service
    systemctl daemon-reload >/dev/null 2>&1
    ui_ok "Limpeza concluída"
}

instalar_dependencias() {
    clear; ui_top; ui_titulo "1/6 INSTALANDO DEPENDÊNCIAS"; ui_sep
    ui_info "Atualizando a lista de pacotes (aguarda se o apt estiver ocupado)..."
    apt_atualizar
    ui_info "Instalando pacotes essenciais..."
    apt_instalar "essenciais (curl, ca-certificates, iptables, python3, python3-venv)" \
        curl ca-certificates iptables python3 python3-venv \
        || { ui_error "Não foi possível instalar os pacotes essenciais. Log completo: $LOG_FILE"; exit 1; }
    ui_info "Instalando pacotes opcionais..."
    apt_opcional python3-pip wget lsof
    ui_info "Instalando ferramentas de compilação do UDPGW..."
    if apt_instalar "compilação (git, cmake, build-essential, libssl-dev)" git cmake build-essential libssl-dev; then
        SKIP_UDPGW_BUILD=0
    else
        SKIP_UDPGW_BUILD=1
        ui_warn "Sem ferramentas de compilação: o UDPGW será ignorado (BHTTP e HCR seguem normais)"
    fi
    ui_ok "Dependências instaladas"; sleep 1
}

baixar_binarios() {
    clear; ui_top; ui_titulo "2/6 BAIXANDO BINÁRIOS (com SHA256)"; ui_sep
    ARCH=$(detectar_arquitetura)
    mkdir -p /opt/bhttp /opt/hcr /opt/udpgw "$HEX_DIR" /var/log/bhttp /var/log/hcr
    chmod 700 "$HEX_DIR"
    MANIFEST="$TMPD/version.json"
    ui_info "Baixando version.json e conferindo a assinatura..."
    obter_manifesto "$MANIFEST" || exit 1

    ui_info "Baixando BHTTP ($ARCH)..."
    baixar_binario "bhttp-server-v2.4.1-btun-compat-keepalive-linux-${ARCH}" "$BHTTP_BIN" 755 \
        && ui_ok "BHTTP baixado" || { ui_error "Falha ao baixar BHTTP"; exit 1; }
    ui_info "Baixando HCR ($ARCH)..."
    baixar_binario "hcr-server-linux-${ARCH}" "$HCR_BIN" 755 \
        && ui_ok "HCR baixado" || { ui_error "Falha ao baixar HCR"; exit 1; }
    sleep 1
}

compilar_udpgw() {
    clear; ui_top; ui_titulo "3/6 COMPILANDO UDPGW (BadVPN $BADVPN_TAG)"; ui_sep
    local build="$TMPD/badvpn"
    if [ "${SKIP_UDPGW_BUILD:-0}" = "1" ]; then
        ui_warn "Compilação do UDPGW ignorada (faltam ferramentas de compilação)"; sleep 1; return 0
    fi
    ui_info "Baixando código-fonte do BadVPN (tag fixa)..."
    if git clone --quiet --depth 1 --branch "$BADVPN_TAG" https://github.com/ambrop72/badvpn.git "$build" >>"$LOG_FILE" 2>&1; then
        mkdir -p "$build/build"
        ui_info "Compilando apenas o módulo udpgw..."
        ( cd "$build/build" \
            && cmake .. -DBUILD_NOTHING_BY_DEFAULT=1 -DBUILD_UDPGW=1 >>"$LOG_FILE" 2>&1 \
            && make -j"$(nproc)" >>"$LOG_FILE" 2>&1 )
    fi
    if [ -f "$build/build/udpgw/badvpn-udpgw" ]; then
        install -m 755 "$build/build/udpgw/badvpn-udpgw" "$UDPGW_BIN"
        ui_ok "UDPGW compilado e instalado"
    elif [ -x "$UDPGW_BIN" ]; then
        ui_warn "A compilação falhou; mantendo o UDPGW já instalado"
    else
        ui_warn "A compilação do UDPGW falhou (veja $LOG_FILE); UDPGW não será iniciado"
    fi
    sleep 1
}

escrever_unit() {   # escrever_unit <nome> <descrição> <ExecStart>
    cat > "/etc/systemd/system/$1@.service" <<EOT
[Unit]
Description=$2 on port %i
After=network.target

[Service]
Type=simple
User=root
ExecStart=$3
Restart=on-failure
RestartSec=5
LimitNOFILE=65535
NoNewPrivileges=yes
PrivateTmp=yes
ProtectHome=yes
ProtectSystem=full
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
StandardOutput=journal
StandardError=journal
SyslogIdentifier=$1-%i

[Install]
WantedBy=multi-user.target
EOT
}

configurar_servicos() {
    clear; ui_top; ui_titulo "4/6 CONFIGURANDO SERVIÇOS"; ui_sep
    # listas de portas: criadas VAZIAS (nada é ativado); o usuário escolhe as portas ao ativar pelo menu
    [ -f "$HEX_DIR/bhttp_ports.conf" ] || : > "$HEX_DIR/bhttp_ports.conf"
    [ -f "$HEX_DIR/hcr_ports.conf" ] || : > "$HEX_DIR/hcr_ports.conf"
    [ -f "$HEX_DIR/udpgw_ports.conf" ] || : > "$HEX_DIR/udpgw_ports.conf"
    touch "$USER_DB" && chmod 600 "$USER_DB"

    # UDPGW público só se pedido (ou se já estava assim numa instalação anterior)
    case "${HEX_UDPGW_PUBLIC:-}" in
        1) touch "$UDPGW_PUBLIC_FLAG" ;;
        0) rm -f "$UDPGW_PUBLIC_FLAG" ;;
    esac
    if [ -f "$UDPGW_PUBLIC_FLAG" ]; then UDPGW_BIND="0.0.0.0"; else UDPGW_BIND="127.0.0.1"; fi

    ui_info "Configurando template BHTTP..."
    escrever_unit bhttp "BHTTP Server" "$BHTTP_BIN -listen 0.0.0.0 -port %i -backend-host 127.0.0.1 -backend-port 22"
    ui_info "Configurando template HCR..."
    escrever_unit hcr "HCR Server" "$HCR_BIN --listen :%i --target 127.0.0.1:22 --transport plain"
    ui_info "Configurando template UDPGW (escuta em $UDPGW_BIND)..."
    escrever_unit udpgw "BadVPN UDPGW Server" "$UDPGW_BIN --listen-addr ${UDPGW_BIND}:%i --max-clients 1000 --max-connections-for-client 10"
    systemctl daemon-reload >/dev/null 2>&1
    ui_ok "Templates configurados"; sleep 1
}

iniciar_servicos_e_firewall() {
    clear; ui_top; ui_titulo "5/6 SERVIÇOS (instalados, ativação manual)"; ui_sep
    local inst svc port religados=0
    if [ -s "$ATIVOS_ANTES" ]; then
        ui_info "Reinstalação: religando só o que já estava ativo antes..."
        while read -r inst; do
            svc=${inst%@*}; port=${inst#*@}
            grep -qx "$port" "$HEX_DIR/${svc}_ports.conf" 2>/dev/null || continue
            systemctl enable "${inst}.service" >/dev/null 2>&1
            systemctl restart "${inst}.service" 2>>"$LOG_FILE"
            case "$svc" in
                udpgw) if [ -f "$UDPGW_PUBLIC_FLAG" ]; then abrir_porta udp "$port"; abrir_porta tcp "$port"; fi ;;
                *) abrir_porta tcp "$port" ;;
            esac
            religados=$((religados+1))
        done < "$ATIVOS_ANTES"
        fw_persistir
        ui_ok "$religados porta(s) religada(s)"
    else
        ui_ok "BHTTP, HCR e UDPGW instalados e DESATIVADOS (nenhuma porta aberta ou iniciada)"
        ui_info "Você ativa e escolhe as portas pelo menu: hex_menu → Gerenciar → Ativar"
    fi
    sleep 1
}

instalar_menu_e_limpeza() {
    clear; ui_top; ui_titulo "6/6 INSTALANDO MENU, LIMPEZA E PAINEL WEB"; ui_sep
    ui_info "Baixando menu de gerenciamento..."
    baixar_verificado "hex_menu.sh" /usr/local/bin/hex_menu 755 && ui_ok "Menu instalado" || ui_error "Falha ao baixar o menu"
    rm -f /usr/bin/hex_menu   # cópia antiga de instalações anteriores
    ui_info "Instalando script de limpeza (v2)..."
    baixar_verificado "hex_cleanup.sh" /usr/local/bin/hex_cleanup.sh 755 && ui_ok "Script de limpeza instalado" || ui_error "Falha ao baixar a limpeza"
    baixar_verificado "hex_ip.sh" /usr/local/bin/hex_ip.sh 755 && ui_ok "Detector de IP público instalado" || ui_error "Falha ao baixar hex_ip.sh"
    baixar_verificado "hex_panel_mode.sh" /usr/local/bin/hex_panel_mode.sh 755 && ui_ok "Módulo de segurança do painel instalado" || ui_error "Falha ao baixar hex_panel_mode.sh"
    touch /var/log/hex-cleanup.log && chmod 644 /var/log/hex-cleanup.log
    ( crontab -l 2>/dev/null | grep -v "hex_cleanup.sh"; echo "0 3 * * * /usr/local/bin/hex_cleanup.sh" ) | crontab -
    ui_ok "Limpeza automática ativada (diariamente às 03:00)"
    local v
    v=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("version",""))' "$MANIFEST" 2>/dev/null)
    [ -n "$v" ] && echo "$v" > "$HEX_DIR/version"

    ui_info "Instalando o Painel Web (install_webpanel.sh verificado)..."
    local wp="$TMPD/install_webpanel.sh"
    if baixar_verificado "install_webpanel.sh" "$wp" 755; then
        HEX_GITHUB_RAW="$GITHUB_RAW" bash "$wp" || ui_warn "O instalador do painel terminou com erro"
    else
        ui_warn "Não foi possível obter o instalador do painel; instale depois pelo menu (opção 4)"
    fi
    sleep 1
}

criar_comandos_rapidos() {
    ln -sf /usr/local/bin/hex_menu /usr/local/bin/bhttp 2>/dev/null
    ln -sf /usr/local/bin/hex_menu /usr/local/bin/hcr 2>/dev/null
}

total_ativos() {   # quantas portas dos 3 serviços estão ativas agora
    local svc port n=0
    for svc in bhttp hcr udpgw; do
        [ -f "$HEX_DIR/${svc}_ports.conf" ] || continue
        while read -r port; do
            [ -z "$port" ] && continue
            systemctl is-active --quiet "${svc}@${port}.service" 2>/dev/null && n=$((n+1))
        done < "$HEX_DIR/${svc}_ports.conf"
    done
    echo "$n"
}

estado_servico() {   # estado_servico <svc> <conf>  → "ATIVO (2/2)" etc.
    local svc="$1" conf="$2" total=0 active=0 port
    while read -r port; do
        [ -z "$port" ] && continue; total=$((total+1))
        systemctl is-active --quiet "${svc}@${port}.service" && active=$((active+1))
    done < "$conf" 2>/dev/null
    if [ "$total" -eq 0 ]; then echo -e "${YELLOW}○ DESATIVADO${NC} (instalado)"
    elif [ "$active" -eq "$total" ]; then echo -e "${GREEN}● ATIVO${NC} ($active/$total)"
    elif [ "$active" -gt 0 ]; then echo -e "${YELLOW}● PARCIAL${NC} ($active/$total)"
    else echo -e "${YELLOW}○ DESATIVADO${NC} (0/$total)"; fi
}

portas_para_liberar() {
    local b h p
    b=$(paste -sd, "$HEX_DIR/bhttp_ports.conf" 2>/dev/null); h=$(paste -sd, "$HEX_DIR/hcr_ports.conf" 2>/dev/null)
    p=$(cat "$HEX_DIR/webpanel_port.conf" 2>/dev/null || echo 9000)
    echo "TCP ${b:+$b (BHTTP) }${h:+$h (HCR) }$p (painel)"
}

mostrar_resumo() {
    clear; ui_top; ui_titulo "✓ INSTALAÇÃO CONCLUÍDA"; ui_sep; ui_fila ""
    ui_fila " ${CYAN}BHTTP${NC}  - $(estado_servico bhttp "$HEX_DIR/bhttp_ports.conf")"
    ui_fila " ${CYAN}HCR${NC}    - $(estado_servico hcr "$HEX_DIR/hcr_ports.conf")"
    ui_fila " ${CYAN}UDPGW${NC}  - $(estado_servico udpgw "$HEX_DIR/udpgw_ports.conf") ${GRIS}(escuta em ${UDPGW_BIND})${NC}"
    local pstate; systemctl is-active --quiet hex-webpanel.service && pstate="${GREEN}● ATIVO${NC}" || pstate="${RED}● INATIVO${NC}"
    ui_fila " ${CYAN}PAINEL${NC} - $pstate  ${GRIS}$(/usr/local/bin/hex_panel_mode.sh url 2>/dev/null || echo "http://$(/usr/local/bin/hex_ip.sh 2>/dev/null || hostname -I | awk '{print $1}'):9000")${NC}"
    if [ -f "$INITIAL_PASS_FILE" ]; then
        ui_fila " ${BOLD}Senha inicial do painel:${NC} ${YELLOW}$(sed -n 's/^Senha inicial do painel: //p' "$INITIAL_PASS_FILE")${NC}"
        ui_fila " ${RED}⚠ Troque no dashboard.${NC} ${GRIS}($INITIAL_PASS_FILE)${NC}"
    fi
    ui_fila ""; ui_sep
    ui_fila " ${BOLD}Comando:${NC} ${YELLOW}hex_menu | bhttp | hcr${NC}"
    ui_fila " ${BOLD}IP:${NC} ${YELLOW}$(/usr/local/bin/hex_ip.sh 2>/dev/null || hostname -I | awk '{print $1}')${NC}"
    ui_fila ""
    if [ "$(total_ativos)" -eq 0 ]; then
        ui_fila " ${YELLOW}${BOLD}⚠ BHTTP, HCR e UDPGW estão instalados, mas DESATIVADOS.${NC}"
        ui_fila "   Nenhuma porta foi aberta. Para ativar e escolher a porta:"
        ui_fila "   ${BOLD}hex_menu → [1] Gerenciar BHTTP → [7] Ativar BHTTP${NC}  (igual para [2] HCR e [3] UDPGW)"
        ui_fila "   Portas sugeridas: BHTTP ${BOLD}80${NC} ou ${BOLD}8880${NC} · HCR ${BOLD}8080${NC} · UDPGW ${BOLD}7300${NC} (só local)"
        if /usr/local/bin/hex_ip.sh nat 2>/dev/null; then
            ui_fila "   ${YELLOW}Atrás de NAT:${NC} ao ativar, libere a porta também no firewall do PROVEDOR"
            ui_fila "   (Security List / Security Group). Painel Web: ${BOLD}$(cat "$HEX_DIR/webpanel_port.conf" 2>/dev/null || echo 9000)${NC}"
        fi
    else
        ui_fila " ${GRIS}Serviços religados como estavam antes. Ative/desative os demais em:${NC}"
        ui_fila "   ${BOLD}hex_menu → [1] BHTTP · [2] HCR · [3] UDPGW → [7] Ativar/Desativar${NC}"
        if /usr/local/bin/hex_ip.sh nat 2>/dev/null; then
            ui_fila "   ${YELLOW}Atrás de NAT:${NC} portas em uso para liberar no firewall do PROVEDOR:"
            ui_fila "   ${BOLD}$(portas_para_liberar)${NC}"
        fi
    fi
    ui_fila ""
    ui_fila " ${BOLD}Repo:${NC} ${CYAN}github.com/PhoenixxZ2023/TURBONET-BHTTP${NC}"
    ui_fila ""; ui_bot; echo ""
}

main() {
    if [ "$EUID" -ne 0 ]; then echo -e "${RED}✗ Requer root${NC}"; exit 1; fi
    command -v systemctl >/dev/null 2>&1 || { echo -e "${RED}✗ systemd (systemctl) não encontrado${NC}"; exit 1; }
    : > "$LOG_FILE" 2>/dev/null
    TMPD=$(mktemp -d); trap 'rm -rf "$TMPD"' EXIT
    ATIVOS_ANTES="$TMPD/ativos_antes"; : > "$ATIVOS_ANTES"
    limpar_instalacao_previa
    instalar_dependencias
    baixar_binarios
    compilar_udpgw
    configurar_servicos
    iniciar_servicos_e_firewall
    instalar_menu_e_limpeza
    criar_comandos_rapidos
    mostrar_resumo
}

[ "${HEX_SOURCE_ONLY:-0}" = "1" ] || main
