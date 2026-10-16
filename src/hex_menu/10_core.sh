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
db_lock() { exec 8>"${HEX_DIR:-/etc/hex}/.users.lock"; flock 8; }
db_has() { awk -F: -v u="$1" '$1==u{f=1} END{exit !f}' "$USER_DB"; }
# db_update <usuário> exp|delete [valor]   (chamar dentro de: ( db_lock; db_update ... ))
# Formato do users.txt: usuario:validade  (a senha NÃO é guardada aqui; fica só no hash do sistema)
db_update() {
    local user="$1" field="$2" value="${3:-}" tmp
    tmp=$(mktemp "${HEX_DIR:-/etc/hex}/users.XXXXXX") || return 1
    if HEX_U="$user" HEX_F="$field" HEX_V="$value" awk '
        { n=split($0,a,":"); u=a[1]; e=a[n]
          if (u != ENVIRON["HEX_U"]) { print; next }
          if (ENVIRON["HEX_F"]=="delete") next
          if (ENVIRON["HEX_F"]=="exp") e=ENVIRON["HEX_V"]
          print u ":" e }' "$USER_DB" > "$tmp"; then
        chmod 600 "$tmp" && mv -f "$tmp" "$USER_DB"
    else
        rm -f "$tmp"; return 1
    fi
}
# converte o formato antigo (usuario:senha:validade) para usuario:validade; idempotente
migrar_users_db() {
    [ -s "$USER_DB" ] || return 0
    (
        db_lock
        awk -F: 'NF>2{f=1} END{exit !f}' "$USER_DB" || exit 0
        tmp=$(mktemp "${HEX_DIR:-/etc/hex}/users.XXXXXX") || exit 1
        if awk '{ n=split($0,a,":"); if (n>2) print a[1] ":" a[n]; else print }' "$USER_DB" > "$tmp"; then
            chmod 600 "$tmp" && mv -f "$tmp" "$USER_DB"
        else
            rm -f "$tmp"
        fi
    )
}
# shell dos NOVOS usuários: padrão = só túnel (nologin); /etc/hex/user_shell pode mudar
shell_padrao_novos() {
    local sh; sh=$(cat "${HEX_DIR:-/etc/hex}/user_shell" 2>/dev/null)
    case "$sh" in /bin/bash|/bin/sh|/bin/false|/usr/sbin/nologin) [ -e "$sh" ] && { echo "$sh"; return; } ;; esac
    if [ -x /usr/sbin/nologin ]; then echo /usr/sbin/nologin; else echo /bin/false; fi
}

