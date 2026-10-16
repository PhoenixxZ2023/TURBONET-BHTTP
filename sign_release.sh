#!/bin/bash
# Assinatura das versões (Ed25519 via OpenSSL). Ferramenta do DONO do projeto, não vai para as VPS.
#
#   ./sign_release.sh keygen        cria a chave PRIVADA (~/.hex-release/release_key.pem, 0600) e a pública (keys/release_pub.pem)
#   ./sign_release.sh sign          assina o version.json  → version.json.sig
#   ./sign_release.sh verify        confere version.json.sig com keys/release_pub.pem
#   ./sign_release.sh fingerprint   mostra a impressão digital da chave pública (publique no README/perfil)
#
# A chave PRIVADA nunca vai para o repositório: guarde cópia offline. Outro local: HEX_SIGNING_KEY=/caminho/chave.pem
set -euo pipefail
cd "$(dirname "$0")"
# shellcheck source=src/lib/signature.sh
. src/lib/signature.sh
KEY="${HEX_SIGNING_KEY:-$HOME/.hex-release/release_key.pem}"
PUB="keys/release_pub.pem"
case "${1:-}" in
    keygen)
        [ -e "$KEY" ] && { echo "Já existe uma chave privada em $KEY (não vou sobrescrever)." >&2; exit 1; }
        mkdir -p "$(dirname "$KEY")" keys; chmod 700 "$(dirname "$KEY")"
        ( umask 077; openssl genpkey -algorithm ed25519 -out "$KEY" )
        openssl pkey -in "$KEY" -pubout -out "$PUB"
        echo "Chave privada: $KEY   (0600, FORA do repositório; faça cópia offline)"
        echo "Chave pública: $PUB   (faça commit)"
        echo "Impressão digital: $(hex_fingerprint "$PUB")"
        echo "Publique essa impressão digital em outro lugar além do repositório (README, perfil do GitHub)." ;;
    sign)
        [ -s "$KEY" ] || { echo "Chave privada não encontrada: $KEY (rode: ./sign_release.sh keygen)" >&2; exit 1; }
        [ -s version.json ] || { echo "version.json não existe (rode ./gen_version.sh <versão>)" >&2; exit 1; }
        tmp=$(mktemp); openssl pkeyutl -sign -inkey "$KEY" -rawin -in version.json -out "$tmp"
        base64 -w0 "$tmp" > version.json.sig; echo >> version.json.sig; rm -f "$tmp"
        hex_verificar_assinatura version.json version.json.sig "$PUB" || { echo "A assinatura gerada NÃO confere com $PUB (chave errada?)" >&2; exit 1; }
        echo "version.json.sig gerado e conferido com $PUB" ;;
    verify)
        [ -s "$PUB" ] || { echo "Sem $PUB: nada a conferir (versão não assinada)"; exit 0; }
        [ -s version.json.sig ] || { echo "version.json.sig ausente (rode: HEX_SIGNING_KEY=... ./gen_version.sh <versão> ou ./sign_release.sh sign)" >&2; exit 1; }
        hex_verificar_assinatura version.json version.json.sig "$PUB" && echo "assinatura do version.json confere" \
            || { echo "A assinatura NÃO confere com o version.json atual (assine de novo: ./sign_release.sh sign)" >&2; exit 1; } ;;
    fingerprint) hex_fingerprint "$PUB" ;;
    *) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
