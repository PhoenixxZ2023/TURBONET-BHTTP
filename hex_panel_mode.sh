#!/bin/bash
# hex_panel_mode v1 - modo de acesso do Painel Web (tudo automático, sem editar arquivos)
#
#   hex_panel_mode.sh https [--renew]   ativa HTTPS (certificado autoassinado, criado sozinho)
#   hex_panel_mode.sh http              volta ao HTTP simples
#   hex_panel_mode.sh local             painel só em 127.0.0.1 (use túnel SSH ou proxy)
#   hex_panel_mode.sh external          painel acessível de fora (0.0.0.0)
#   hex_panel_mode.sh status | url | fingerprint
#
# Toda mudança é verificada (o painel precisa responder) e revertida sozinha se falhar.
HEX_DIR="${HEX_DIR:-/etc/hex}"
ENV_FILE="$HEX_DIR/webpanel.env"
TLS_DIR="$HEX_DIR/webpanel_tls"
CERT="$TLS_DIR/cert.pem"
KEY="$TLS_DIR/key.pem"
PORT_FILE="$HEX_DIR/webpanel_port.conf"
PANEL_DIR="${HEX_PANEL_DIR:-/opt/hex-webpanel}"
SERVICE="hex-webpanel.service"

ok()   { echo "  ✓ $1"; }
err()  { echo "  ✗ $1" >&2; }
info() { echo "  ℹ $1"; }

panel_port() { local p; p=$(cat "$PORT_FILE" 2>/dev/null); [[ "$p" =~ ^[0-9]+$ ]] && echo "$p" || echo 9000; }
IP_SCRIPT="${HEX_IP_SCRIPT:-/usr/local/bin/hex_ip.sh}"
public_ip() {  # IPv4 público da VPS (cai para o primeiro IP local se o detector não existir)
    local ip=""
    [ -x "$IP_SCRIPT" ] && ip=$("$IP_SCRIPT" 2>/dev/null)
    [ -n "$ip" ] || ip=$(server_ips | head -1)
    echo "${ip:-127.0.0.1}"
}
server_ips() { hostname -I 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; }

# ── webpanel.env: lê/grava uma chave sem apagar as outras ──
env_get() { sed -n "s/^$1=//p" "$ENV_FILE" 2>/dev/null | tail -1 | tr -d '"'; }
env_write() {  # env_write <chave> <valor|"">  (valor vazio remove a chave)
    local tmp; mkdir -p "$HEX_DIR"
    tmp=$(mktemp "$HEX_DIR/.env.XXXXXX") || return 1
    { [ -f "$ENV_FILE" ] && grep -v "^$1=" "$ENV_FILE"; [ -n "$2" ] && echo "$1=$2"; } > "$tmp"
    chmod 600 "$tmp" && mv -f "$tmp" "$ENV_FILE"
}

is_tls()   { [ "$(env_get HEX_PANEL_TLS)" = "1" ]; }
is_local() { [ "$(env_get HEX_PANEL_HOST)" = "127.0.0.1" ]; }

cert_end_date() { openssl x509 -noout -enddate -in "$CERT" 2>/dev/null | sed 's/^notAfter=//'; }
fingerprint()   { openssl x509 -noout -fingerprint -sha256 -in "$CERT" 2>/dev/null | sed 's/^.*Fingerprint=//'; }

cert_pair_ok() {  # cert e chave existem, são válidos e combinam
    [ -s "$CERT" ] && [ -s "$KEY" ] || return 1
    local a b
    a=$(openssl x509 -noout -pubkey -in "$CERT" 2>/dev/null) || return 1
    b=$(openssl pkey -pubout -in "$KEY" 2>/dev/null) || return 1
    [ -n "$a" ] && [ "$a" = "$b" ]
}

make_cert() {  # make_cert [force]
    if [ "$1" != "force" ] && cert_pair_ok; then return 0; fi
    command -v openssl >/dev/null 2>&1 || { apt-get install -y openssl >/dev/null 2>&1; }
    command -v openssl >/dev/null 2>&1 || { err "openssl não encontrado"; return 1; }
    local san="IP:127.0.0.1,DNS:localhost" ip host
    for ip in $(server_ips) $(public_ip); do
        case ",$san," in *",IP:$ip,"*) ;; *) san="$san,IP:$ip" ;; esac
    done
    host=$(hostname 2>/dev/null); [[ "$host" =~ ^[A-Za-z0-9.-]+$ ]] && san="$san,DNS:$host"
    mkdir -p "$TLS_DIR" && chmod 700 "$TLS_DIR"
    info "Gerando certificado HTTPS (autoassinado, válido por ~2 anos)..."
    openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 825 \
        -keyout "$KEY.new" -out "$CERT.new" -subj "/CN=hex-webpanel" \
        -addext "subjectAltName=$san" >/dev/null 2>&1 \
        || { rm -f "$KEY.new" "$CERT.new"; err "Falha ao gerar o certificado"; return 1; }
    chmod 600 "$KEY.new"; chmod 644 "$CERT.new"
    mv -f "$KEY.new" "$KEY"; mv -f "$CERT.new" "$CERT"
    ok "Certificado criado"
}

ensure_cheroot() {
    local py="$PANEL_DIR/venv/bin/python"
    [ -x "$py" ] || { err "Painel Web não está instalado ($PANEL_DIR)"; return 1; }
    "$py" -c "import cheroot" 2>/dev/null && return 0
    info "Instalando o servidor HTTPS (cheroot)..."
    "$PANEL_DIR/venv/bin/pip" install --quiet cheroot >/dev/null 2>&1 && "$py" -c "import cheroot" 2>/dev/null \
        || { err "Não foi possível instalar o cheroot (sem internet?)"; return 1; }
}

restart_panel() {
    if [ -n "$HEX_RESTART_CMD" ]; then bash -c "$HEX_RESTART_CMD" >/dev/null 2>&1
    else systemctl restart "$SERVICE" >/dev/null 2>&1; fi
}

panel_answers() {  # o painel responde (200 em /login) no esquema atual?
    local scheme=http code
    is_tls && scheme=https
    for _ in $(seq 1 "${HEX_VERIFY_TRIES:-20}"); do
        code=$(curl -sk --max-time 3 -o /dev/null -w '%{http_code}' "$scheme://127.0.0.1:$(panel_port)/login" 2>/dev/null)
        [ "$code" = "200" ] && return 0
        sleep 1
    done
    return 1
}

# aplica_mudanca <descrição> <comandos...>: faz backup do env, aplica, reinicia, verifica; reverte se falhar
apply_change() {
    local desc="$1" bak; shift
    bak=$(mktemp) || return 1
    if [ -f "$ENV_FILE" ]; then cp -p "$ENV_FILE" "$bak"; else : > "$bak.absent"; fi
    if "$@" && restart_panel && panel_answers; then
        rm -f "$bak" "$bak.absent"; ok "$desc"; return 0
    fi
    err "O painel não respondeu depois da mudança; revertendo..."
    if [ -f "$bak.absent" ]; then rm -f "$ENV_FILE"; else cp -p "$bak" "$ENV_FILE"; fi
    rm -f "$bak" "$bak.absent"
    restart_panel; panel_answers && info "Configuração anterior restaurada" || err "Veja: journalctl -u $SERVICE -n 50"
    return 1
}

set_https() { make_cert "$1" && ensure_cheroot && env_write HEX_PANEL_TLS 1 && env_write HEX_PANEL_HTTPS 1; }
set_http()  { env_write HEX_PANEL_TLS "" && env_write HEX_PANEL_HTTPS ""; }

show_url() {
    local scheme=http host
    is_tls && scheme=https
    if is_local; then host="localhost"; else host=$(public_ip); fi
    echo "$scheme://${host:-localhost}:$(panel_port)"
}

show_status() {
    if is_tls; then
        echo "Protocolo: HTTPS (senha criptografada)"
        [ -s "$CERT" ] && echo "Certificado: autoassinado, válido até $(cert_end_date)"
    else
        echo "Protocolo: HTTP simples (senha trafega sem criptografia)"
    fi
    if is_local; then echo "Acesso: somente local (127.0.0.1) - use túnel SSH ou proxy"
    else echo "Acesso: externo (qualquer IP que alcance a porta)"; fi
    echo "URL: $(show_url)"
}

https_notes() {
    echo ""
    echo "  O navegador vai avisar \"conexão não é particular\" porque o certificado é"
    echo "  autoassinado (criado por este servidor). É esperado: clique em"
    echo "  Avançado → Continuar. A senha já viaja criptografada."
    echo "  Impressão digital (SHA-256), para conferir se quiser:"
    echo "  $(fingerprint)"
}

case "$1" in
    https)
        force=""; [ "$2" = "--renew" ] && force="force"
        apply_change "HTTPS ativado" set_https "$force" && { echo "  URL: $(show_url)"; https_notes; } ;;
    http)
        apply_change "Voltou para HTTP simples" set_http && echo "  URL: $(show_url)" ;;
    local)
        apply_change "Painel restrito a 127.0.0.1" env_write HEX_PANEL_HOST 127.0.0.1 && {
            echo "  Para acessar de fora, use um túnel SSH no seu computador:"
            echo "    ssh -L $(panel_port):127.0.0.1:$(panel_port) root@$(public_ip)"
            echo "  e abra $(show_url)"; } ;;
    external)
        apply_change "Painel liberado para acesso externo" env_write HEX_PANEL_HOST "" && echo "  URL: $(show_url)" ;;
    status) show_status ;;
    url) show_url ;;
    fingerprint) fingerprint ;;
    *) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
