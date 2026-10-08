#!/bin/bash
# hex_ip v1 - descobre o IPv4 PÚBLICO da VPS (o que o cliente VPN/navegador deve usar)
#
#   hex_ip.sh              imprime o IPv4 público (usa cache de 24h)
#   hex_ip.sh refresh      descobre de novo, ignorando o cache
#   hex_ip.sh status       mostra o IP, de onde veio e os IPs locais
#   hex_ip.sh set <ipv4>   fixa um IP manualmente (para casos especiais)
#   hex_ip.sh unset        volta à detecção automática
#   hex_ip.sh nat          sai com 0 se a VPS está atrás de NAT (IP público não está na placa)
#
# Ordem: IP manual > cache > IP público na própria placa de rede > consulta na internet
#        > (último recurso) IP privado local.  Só IPv4.
# Para nunca consultar a internet: HEX_NO_IP_LOOKUP=1
HEX_DIR="${HEX_DIR:-/etc/hex}"
OVERRIDE="$HEX_DIR/public_ip.override"
CACHE="$HEX_DIR/public_ip.cache"
FAILMARK="$HEX_DIR/.ip_lookup_failed"   # depois de uma falha total, não insiste por 10 min
TTL="${HEX_IP_TTL:-86400}"
IPV4_RE='^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$'

valid_ipv4() {
    [[ "$1" =~ $IPV4_RE ]] || return 1
    local o; for o in "${BASH_REMATCH[@]:1}"; do [ "$o" -le 255 ] || return 1; done
}

# IPv4 roteável na internet? (exclui privados, loopback, link-local, CGNAT, documentação, multicast)
is_public_ipv4() {
    valid_ipv4 "$1" || return 1
    local a b c
    IFS=. read -r a b c _ <<< "$1"
    a=$((10#$a)); b=$((10#$b)); c=$((10#$c))
    [ "$a" -eq 0 ] || [ "$a" -eq 10 ] || [ "$a" -eq 127 ] && return 1
    [ "$a" -ge 224 ] && return 1
    [ "$a" -eq 169 ] && [ "$b" -eq 254 ] && return 1
    [ "$a" -eq 172 ] && [ "$b" -ge 16 ] && [ "$b" -le 31 ] && return 1
    [ "$a" -eq 192 ] && [ "$b" -eq 168 ] && return 1
    [ "$a" -eq 100 ] && [ "$b" -ge 64 ] && [ "$b" -le 127 ] && return 1
    [ "$a" -eq 192 ] && [ "$b" -eq 0 ] && { [ "$c" -eq 0 ] || [ "$c" -eq 2 ]; } && return 1
    [ "$a" -eq 198 ] && { [ "$b" -eq 18 ] || [ "$b" -eq 19 ]; } && return 1
    [ "$a" -eq 198 ] && [ "$b" -eq 51 ] && [ "$c" -eq 100 ] && return 1
    [ "$a" -eq 203 ] && [ "$b" -eq 0 ] && [ "$c" -eq 113 ] && return 1
    return 0
}

local_ipv4s() {
    local out
    out=$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$')
    if [ -z "$out" ]; then
        out=$(ip -4 -o addr show scope global 2>/dev/null | awk '{split($4,a,"/"); print a[1]}')
    fi
    echo "$out"
}

interface_public_ip() {  # algum IP da própria placa já é público?
    local ip
    for ip in $(local_ipv4s); do is_public_ipv4 "$ip" && { echo "$ip"; return 0; }; done
    return 1
}

internet_public_ip() {  # internet_public_ip [force]
    [ "${HEX_NO_IP_LOOKUP:-0}" = "1" ] && return 1
    command -v curl >/dev/null 2>&1 || return 1
    local url ip now mt
    if [ "$1" != "force" ] && [ -f "$FAILMARK" ]; then
        now=$(date +%s); mt=$(stat -c %Y "$FAILMARK" 2>/dev/null || echo 0)
        [ $((now - mt)) -lt 600 ] && return 1
    fi
    for url in https://api.ipify.org https://ifconfig.me/ip https://icanhazip.com https://checkip.amazonaws.com; do
        ip=$(curl -4 -fsS --max-time 4 "$url" 2>/dev/null | tr -d ' \r\n')
        if is_public_ipv4 "$ip"; then rm -f "$FAILMARK"; echo "$ip"; return 0; fi
    done
    mkdir -p "$HEX_DIR" 2>/dev/null; touch "$FAILMARK" 2>/dev/null
    return 1
}

write_cache() {  # write_cache <ip> <origem>
    local tmp
    mkdir -p "$HEX_DIR" 2>/dev/null
    tmp=$(mktemp "$HEX_DIR/.ip.XXXXXX" 2>/dev/null) || return 0
    echo "$1 $2 $(date +%s)" > "$tmp" && chmod 644 "$tmp" && mv -f "$tmp" "$CACHE" || rm -f "$tmp"
}

# resolve [force]  →  imprime "ip origem"
resolve() {
    local ip src ts now cached_ip cached_src
    if [ -s "$OVERRIDE" ]; then
        ip=$(tr -d ' \r\n' < "$OVERRIDE")
        valid_ipv4 "$ip" && { echo "$ip manual"; return 0; }
    fi
    now=$(date +%s)
    if [ "$1" != "force" ] && [ -s "$CACHE" ]; then
        read -r cached_ip cached_src ts < "$CACHE"
        if is_public_ipv4 "$cached_ip" && [[ "$ts" =~ ^[0-9]+$ ]] && [ $((now - ts)) -lt "$TTL" ]; then
            echo "$cached_ip $cached_src"; return 0
        fi
    fi
    if ip=$(interface_public_ip); then write_cache "$ip" interface; echo "$ip interface"; return 0; fi
    if ip=$(internet_public_ip "$1"); then write_cache "$ip" internet; echo "$ip internet"; return 0; fi
    # sem internet agora: um cache antigo ainda é melhor que o IP privado
    if [ -s "$CACHE" ]; then
        read -r cached_ip cached_src _ < "$CACHE"
        is_public_ipv4 "$cached_ip" && { echo "$cached_ip $cached_src-antigo"; return 0; }
    fi
    ip=$(local_ipv4s | head -1)
    [ -n "$ip" ] && { echo "$ip local-privado"; return 0; }
    echo "127.0.0.1 nenhum"; return 1
}

origem_txt() {
    case "$1" in
        manual) echo "definido manualmente" ;;
        interface) echo "está na placa de rede da VPS" ;;
        internet) echo "descoberto pela internet (VPS atrás de NAT)" ;;
        *-antigo) echo "cache antigo (sem internet agora)" ;;
        local-privado) echo "IP PRIVADO local (não foi possível descobrir o público)" ;;
        *) echo "$1" ;;
    esac
}

main() {
    local ip src
    case "$1" in
        ""|ip) read -r ip src <<< "$(resolve)"; echo "$ip" ;;
        refresh) read -r ip src <<< "$(resolve force)"; echo "$ip" ;;
        status)
            read -r ip src <<< "$(resolve)"
            echo "IP em uso: $ip"
            echo "Origem: $(origem_txt "$src")"
            echo "IPs locais da VPS: $(local_ipv4s | tr '\n' ' ')"
            if interface_public_ip >/dev/null; then echo "NAT: não (o IP público está na placa de rede)"
            else echo "NAT: sim - libere as portas também no firewall do provedor"; fi ;;
        set)
            valid_ipv4 "$2" || { echo "IPv4 inválido: $2" >&2; exit 1; }
            mkdir -p "$HEX_DIR"; echo "$2" > "$OVERRIDE"; chmod 644 "$OVERRIDE"; echo "$2" ;;
        unset) rm -f "$OVERRIDE"; read -r ip src <<< "$(resolve force)"; echo "$ip" ;;
        nat) interface_public_ip >/dev/null && exit 1 || exit 0 ;;
        *) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
    esac
}

[ "${HEX_SOURCE_ONLY:-0}" = "1" ] || main "$@"
