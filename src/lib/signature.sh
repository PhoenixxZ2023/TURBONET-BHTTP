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
