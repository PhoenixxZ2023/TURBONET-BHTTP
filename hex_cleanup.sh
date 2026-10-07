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
