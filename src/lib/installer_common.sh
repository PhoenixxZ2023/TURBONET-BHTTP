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

#@include lib/signature.sh

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
