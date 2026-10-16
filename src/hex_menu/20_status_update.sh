get_svc_status() {
    local svc=$1 conf=$2
    local total=0 active=0
    if [ -f "$conf" ]; then
        while read -r port; do
            [ -z "$port" ] && continue; ((total++))
            systemctl is-active --quiet "${svc}@${port}.service" 2>/dev/null && ((active++))
        done < "$conf"
    fi
    if [ "$total" -eq 0 ]; then echo "${YELLOW}○ DESATIVADO${NC} (instalado)"
    elif [ "$active" -eq "$total" ]; then echo "${GREEN}● ATIVO${NC} ($active/$total)"
    elif [ "$active" -gt 0 ]; then echo "${YELLOW}● PARCIAL${NC} ($active/$total)"
    elif svc_habilitado "$svc" "$conf"; then echo "${RED}● INATIVO${NC} (0/$total)"
    else echo "${YELLOW}○ DESATIVADO${NC} (0/$total)"; fi
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
        ui_opcion "6" "Chave de assinatura (conferir / fixar)"
        ui_opcion "0" "Voltar"
        
        ui_bot; echo ""
        echo -ne "  ${CYAN}►${NC} Selecione a opção: "; read -r opt
        
        case "$opt" in
            1) atualizar_menu ;;
            2) atualizar_templates ;;
            3) atualizar_backend ;;
            4) atualizar_tudo ;;
            5) ver_changelog ;;
            6) menu_chave_assinatura; menu_atualizacoes ;;
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
#@include lib/signature.sh

hex_obter_manifesto() {
    local sig motivo
    HEX_MANIFEST=$(mktemp) || return 1
    sig="${HEX_MANIFEST}.sig"
    if curl -fsSL --connect-timeout 10 "${GITHUB_RAW}/version.json" -o "$HEX_MANIFEST" 2>/dev/null && [ -s "$HEX_MANIFEST" ]; then
        curl -fsSL --connect-timeout 10 "${GITHUB_RAW}/version.json.sig" -o "$sig" 2>/dev/null || rm -f "$sig"
        if motivo=$(hex_politica_assinatura "$HEX_MANIFEST" "$sig"); then rm -f "$sig"; return 0; fi
        ui_error "Atualização RECUSADA: $motivo"
        rm -f "$HEX_MANIFEST" "$sig"; return 1
    fi
    rm -f "$HEX_MANIFEST" "$sig"; return 1
}

# Mostra a chave de assinatura fixada ou, se ainda não houver, deixa fixar a publicada em keys/release_pub.pem
# DEPOIS de você conferir a impressão digital com a divulgada pelo dono do projeto (README/perfil do GitHub).
menu_chave_assinatura() {
    local tmp c
    clear; ui_top; ui_titulo "CHAVE DE ASSINATURA DAS ATUALIZAÇÕES"; ui_sep; ui_fila ""
    if [ -s "$HEX_PUBKEY" ]; then
        ui_fila "  ${GREEN}● Chave fixada${NC} - atualização sem assinatura válida é recusada"
        ui_fila "  Impressão digital:"; ui_fila "  ${YELLOW}$(hex_fingerprint "$HEX_PUBKEY")${NC}"
        ui_fila ""; ui_bot; echo ""; pause_return; return
    fi
    ui_fila "  ${YELLOW}○ Nenhuma chave fixada${NC}: as atualizações são conferidas só por SHA256."
    ui_fila ""; ui_bot; echo ""
    tmp=$(mktemp) || return
    if ! curl -fsSL --connect-timeout 10 "${GITHUB_RAW}/keys/release_pub.pem" -o "$tmp" 2>/dev/null || ! openssl pkey -pubin -in "$tmp" -noout 2>/dev/null; then
        echo -e "  ${YELLOW}⚠ O projeto ainda não publicou uma chave de assinatura.${NC}"; rm -f "$tmp"; pause_return; return
    fi
    echo -e "  Chave publicada no repositório. Impressão digital:"
    echo -e "  ${YELLOW}$(hex_fingerprint "$tmp")${NC}"
    echo -e "  ${GRIS}Compare com a que o dono do projeto divulgou em OUTRO lugar (README, perfil).${NC}"
    echo -ne "\n  ${WHITE}É a mesma? Fixar esta chave? (s/n):${NC} "; read -r c
    if [ "$c" = "s" ] || [ "$c" = "S" ]; then
        mkdir -p "$(dirname "$HEX_PUBKEY")"; install -m 644 "$tmp" "$HEX_PUBKEY"
        echo -e "  ${GREEN}✓ Chave fixada. Daqui em diante só entram atualizações assinadas por ela.${NC}"
    else
        echo -e "  ${GRIS}Cancelado${NC}"
    fi
    rm -f "$tmp"; pause_return
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
    [ "$5" != "nobackup" ] && [ -s "$dest" ] && cp -p "$dest" "${dest}.backup.$(date +%Y%m%d_%H%M%S)" 2>/dev/null
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
hex_atualizar_static() {   # arquivos estáticos (Bootstrap, ícones, fontes) listados no manifesto
    local rel
    for rel in $(python3 - "$HEX_MANIFEST" <<'PY'
import json, sys
for k in json.load(open(sys.argv[1])).get("sha256", {}):
    if k.startswith("static/") and ".." not in k and not k.startswith("/"):
        print(k)
PY
); do
        mkdir -p "$(dirname "/opt/hex-webpanel/$rel")"
        hex_instalar_arquivo "$rel" "/opt/hex-webpanel/$rel" 644 none nobackup || return 1
    done
    return 0
}
hex_atualizar_templates() {
    [ -d /opt/hex-webpanel/templates ] || { ui_error "O Painel Web não está instalado"; return 1; }
    local ok=0
    hex_atualizar_static && ui_ok "Arquivos estáticos atualizados" || ok=1
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

