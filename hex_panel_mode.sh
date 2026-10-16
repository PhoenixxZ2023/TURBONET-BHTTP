#!/bin/bash
# hex_panel_mode v1 - modo de acesso do Painel Web (tudo automático, sem editar arquivos)
#
#   hex_panel_mode.sh https [--renew]   ativa HTTPS (certificado autoassinado, criado sozinho)
#   hex_panel_mode.sh http              volta ao HTTP simples
#   hex_panel_mode.sh local             painel só em 127.0.0.1 (use túnel SSH ou proxy)
#   hex_panel_mode.sh external          painel acessível de fora (0.0.0.0)
#   hex_panel_mode.sh domain <dominio>  usa um domínio/subdomínio (Cloudflare ou DNS direto) + HTTPS
#   hex_panel_mode.sh domain off        remove o domínio
#   hex_panel_mode.sh cf-port-ok        sai com 1 se o domínio está na Cloudflare (proxy) e a porta não é aceita por ela
#   hex_panel_mode.sh idle <segundos>   tempo de inatividade da sessão (30 a 86400; 'default' = 180)
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

# ── domínio / Cloudflare ──
# Faixas IPv4 da Cloudflare (https://www.cloudflare.com/ips-v4) e portas HTTPS que o proxy aceita
CF_NETS="173.245.48.0/20 103.21.244.0/22 103.22.200.0/22 103.31.4.0/22 141.101.64.0/18 108.162.192.0/18 190.93.240.0/20 188.114.96.0/20 197.234.240.0/22 198.41.128.0/17 162.158.0.0/15 104.16.0.0/13 104.24.0.0/14 172.64.0.0/13 131.0.72.0/22"
CF_HTTPS_PORTS="443 2053 2083 2087 2096 8443"

is_cloudflare_ip() {
    # shellcheck disable=SC2086
    python3 - "$1" $CF_NETS <<'PY'
import ipaddress, sys
try:
    ip = ipaddress.ip_address(sys.argv[1])
except ValueError:
    sys.exit(1)
sys.exit(0 if any(ip in ipaddress.ip_network(n) for n in sys.argv[2:]) else 1)
PY
}
valid_domain() { local d=$1; [ ${#d} -le 253 ] && [[ "$d" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]]; }
domain_ips() { getent ahostsv4 "$1" 2>/dev/null | awk '{print $1}' | sort -u; }
# imprime: direto | cloudflare | outro | sem-dns
domain_mode() {
    local ips ip mine n=0 ncf=0 direto=0
    ips=$(domain_ips "$1"); [ -z "$ips" ] && { echo sem-dns; return; }
    mine=$(public_ip)
    for ip in $ips; do
        n=$((n+1)); is_cloudflare_ip "$ip" && ncf=$((ncf+1)); [ "$ip" = "$mine" ] && direto=1
    done
    if [ "$ncf" -eq "$n" ]; then echo cloudflare
    elif [ "$direto" = 1 ]; then echo direto
    else echo outro; fi
}
get_domain() { env_get HEX_PANEL_DOMAIN; }
cf_port_ok() {  # 0 = ok / não se aplica; 1 = domínio atrás do proxy da Cloudflare com porta não suportada
    local d p; d=$(get_domain); [ -z "$d" ] && return 0
    [ "$(domain_mode "$d")" = cloudflare ] || return 0
    p=$(panel_port); case " $CF_HTTPS_PORTS " in *" $p "*) return 0 ;; esac
    return 1
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
    [ -n "$a" ] && [ "$a" = "$b" ] && cert_has_domain
}
cert_has_domain() {  # com domínio configurado, o certificado precisa listá-lo no SAN
    local d; d=$(get_domain); [ -z "$d" ] && return 0
    openssl x509 -noout -ext subjectAltName -in "$CERT" 2>/dev/null | grep -q "DNS:$d"
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
    local dom cn="hex-webpanel"; dom=$(get_domain)
    if [ -n "$dom" ]; then san="$san,DNS:$dom"; cn="$dom"; fi
    mkdir -p "$TLS_DIR" && chmod 700 "$TLS_DIR"
    info "Gerando certificado HTTPS (autoassinado, válido por ~2 anos)..."
    openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 825 \
        -keyout "$KEY.new" -out "$CERT.new" -subj "/CN=$cn" \
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
set_domain() { env_write HEX_PANEL_DOMAIN "$1" && set_https ""; }

show_url() {
    local scheme=http host
    is_tls && scheme=https
    if is_local; then host="localhost"; else host=$(get_domain); [ -n "$host" ] || host=$(public_ip); fi
    if [ "$scheme" = https ] && [ "$(panel_port)" = 443 ]; then echo "$scheme://${host:-localhost}"
    else echo "$scheme://${host:-localhost}:$(panel_port)"; fi
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
    local d; d=$(get_domain)
    if [ -n "$d" ]; then
        case "$(domain_mode "$d")" in
            direto) echo "Domínio: $d (DNS direto para esta VPS)" ;;
            cloudflare) echo "Domínio: $d (via proxy da Cloudflare - nuvem laranja)" ;;
            outro) echo "Domínio: $d (⚠ aponta para outro IP, não para esta VPS)" ;;
            *) echo "Domínio: $d (⚠ DNS não resolve agora)" ;;
        esac
    fi
    local idle; idle=$(env_get HEX_SESSION_IDLE_SECONDS); [[ "$idle" =~ ^[0-9]+$ ]] || idle=180
    if [ "$idle" -ge 120 ] && [ $((idle % 60)) -eq 0 ]; then echo "Sessão: expira após $((idle / 60)) min sem atividade"
    else echo "Sessão: expira após ${idle}s sem atividade"; fi
    echo "URL: $(show_url)"
}

domain_report() {  # domain_report <dominio>
    local d=$1 mode ips mine p
    mode=$(domain_mode "$d"); mine=$(public_ip); p=$(panel_port)
    echo ""
    case "$mode" in
        direto)
            echo "  DNS: aponta direto para esta VPS (Cloudflare \"nuvem cinza\" / só DNS)."
            echo "  • Funciona em qualquer porta (ex.: $p). O navegador avisa do certificado"
            echo "    autoassinado: Avançado → Continuar."
            echo "  • Para usar o proxy da Cloudflare (nuvem laranja), a porta do painel precisa ser"
            echo "    $CF_HTTPS_PORTS (a Cloudflare ignora as demais)." ;;
        cloudflare)
            echo "  DNS: passa pelo proxy da Cloudflare (nuvem laranja)."
            echo "  • No painel da Cloudflare: SSL/TLS → Visão geral → modo \"Full\""
            echo "    (não use \"Flexible\"; \"Full (strict)\" recusa certificado autoassinado)."
            if cf_port_ok; then echo "  • Porta $p: aceita pela Cloudflare."
            else echo "  • ⚠ Porta $p NÃO é aceita pela Cloudflare. Use: $CF_HTTPS_PORTS (sugestão: 8443)."; fi
            echo "  • O navegador mostra o certificado da Cloudflare (sem aviso); entre a Cloudflare"
            echo "    e esta VPS vale o certificado autoassinado." ;;
        outro)
            ips=$(domain_ips "$d" | tr '\n' ' ')
            echo "  ⚠ $d aponta para: $ips"
            echo "    mas o IP desta VPS é $mine. Ajuste o registro A na Cloudflare." ;;
        *)
            echo "  ⚠ Não consegui resolver $d agora."
            echo "    Crie na Cloudflare um registro A: $d → $mine (pode levar alguns minutos)." ;;
    esac
}

https_notes() {
    echo ""
    echo "  O navegador vai avisar \"conexão não é particular\" porque o certificado é"
    echo "  autoassinado (criado por este servidor). É esperado: clique em"
    echo "  Avançado → Continuar. A senha já viaja criptografada."
    echo "  Impressão digital (SHA-256), para conferir se quiser:"
    echo "  $(fingerprint)"
}

[ "${HEX_SOURCE_ONLY:-0}" = "1" ] && { return 0 2>/dev/null || exit 0; }

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
    domain)
        d=$(echo "$2" | tr 'A-Z' 'a-z')
        if [ "$d" = "off" ] || [ "$d" = "remover" ]; then
            apply_change "Domínio removido (o certificado e o HTTPS continuam)" env_write HEX_PANEL_DOMAIN "" && echo "  URL: $(show_url)"
        elif ! valid_domain "$d"; then
            err "Domínio inválido: '$2'. Use algo como painel.seudominio.com (sem http://, sem barra)."; exit 1
        else
            apply_change "Domínio $d configurado (HTTPS ativado)" set_domain "$d" && { echo "  URL: $(show_url)"; domain_report "$d"; }
        fi ;;
    cf-port-ok) cf_port_ok ;;
    idle)
        v="$2"
        if [ "$v" = "default" ] || [ "$v" = "padrao" ]; then
            apply_change "Tempo de inatividade: padrão (3 min)" env_write HEX_SESSION_IDLE_SECONDS ""
        elif [[ "$v" =~ ^[0-9]+$ ]] && [ "$v" -ge 30 ] && [ "$v" -le 86400 ]; then
            apply_change "Sessão expira após ${v}s sem atividade" env_write HEX_SESSION_IDLE_SECONDS "$v"
        else
            err "Informe segundos entre 30 e 86400 (ou 'default')."; exit 1
        fi ;;
    status) show_status ;;
    url) show_url ;;
    fingerprint) fingerprint ;;
    *) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
