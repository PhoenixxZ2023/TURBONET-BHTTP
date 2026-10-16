instalar_painel_web_automatico() {
    clear; ui_top; ui_titulo "INSTALANDO PAINEL WEB"; ui_sep; ui_fila ""
    ui_info "Este processo pode levar alguns minutos..."
    local wp
    wp=$(mktemp) || return
    if hex_obter_manifesto && hex_instalar_arquivo install_webpanel.sh "$wp" 755 sh; then
        HEX_GITHUB_RAW="$GITHUB_RAW" bash "$wp" || ui_error "O instalador do painel terminou com erro"
        rm -f "$HEX_MANIFEST"
    else
        ui_error "Não foi possível obter o instalador do painel"
    fi
    rm -f "$wp"
    WEBPANEL_PORT=$(cat "$WEBPANEL_PORT_FILE" 2>/dev/null || echo "9000")
    pause_return
}

painel_ativar_desativar() {
    local port c quem
    port=$(cat "$WEBPANEL_PORT_FILE" 2>/dev/null || echo 9000)
    clear; ui_top
    if systemctl is-enabled --quiet hex-webpanel.service 2>/dev/null || systemctl is-active --quiet hex-webpanel.service 2>/dev/null; then
        ui_titulo "DESATIVAR PAINEL WEB"; ui_sep; ui_fila ""
        echo -e "  Isso ${BOLD}para e desliga${NC} o painel (não inicia no boot) e ${BOLD}fecha${NC} a porta $port."
        echo -e "  Você continua administrando tudo por este menu."
        echo -ne "\n  ${YELLOW}Desativar o Painel Web? (s/n):${NC} "; read -r c
        [ "$c" = "s" ] || [ "$c" = "S" ] || { echo -e "  ${GRIS}Cancelado${NC}"; pause_return; return; }
        systemctl disable --now hex-webpanel.service >/dev/null 2>&1
        fw_fechar_svc painel tcp "$port"; fw_persistir
        echo -e "  ${GREEN}✓ Painel Web desativado${NC}"; pause_return; return
    fi
    ui_titulo "ATIVAR PAINEL WEB"; ui_sep; ui_fila ""
    if quem=$(porta_ocupada_por "$port"); then
        echo -e "  ${RED}✗ A porta $port já está em uso${NC} ${GRIS}${quem:+(processo: $quem)}${NC}"
        echo -e "  ${GRIS}Mude a porta do painel (opção 5) e tente de novo.${NC}"; pause_return; return
    fi
    fw_abrir_svc painel tcp "$port"; fw_persistir
    systemctl enable --now hex-webpanel.service >/dev/null 2>&1
    sleep 2
    if systemctl is-active --quiet hex-webpanel.service 2>/dev/null; then
        echo -e "  ${GREEN}✓ Painel Web ativado${NC}  URL: ${CYAN}$(painel_url)${NC}"
        aviso_firewall_provedor "$port"
    else
        echo -e "  ${RED}✗ O painel não iniciou (veja: journalctl -u hex-webpanel -n 30)${NC}"
    fi
    pause_return
}

gerenciar_webpanel() {
    while true; do
        clear; ui_top; ui_titulo "GERENCIAMENTO PAINEL WEB"; ui_sep
        
        if [ ! -f "/opt/hex-webpanel/app.py" ]; then
            ui_fila "  Estado: ${RED}● NÃO INSTALADO${NC}"
            ui_fila "  ${GRIS}O painel web ainda não foi configurado${NC}"
            ui_sep; ui_fila ""
            
            ui_opcion "1" "Instalar Painel Web (Automático)"
            ui_opcion "0" "Voltar"
            
            ui_bot; echo ""; echo -ne "  ${CYAN}►${NC} Selecione a opção: "; read -r opt
            
            case "$opt" in
                1) instalar_painel_web_automatico ;;
                0) break ;;
                *) echo -e "  ${RED}✗ Opção inválida${NC}"; pause_return ;;
            esac
        else
            webpanel_state=$(systemctl is-active hex-webpanel.service 2>/dev/null || echo "inativo")
            [ "$webpanel_state" = "active" ] && webpanel_status="${GREEN}● ATIVO${NC}" || webpanel_status="${RED}● INATIVO${NC}"
            
            ui_fila "  Estado: $webpanel_status  │  Porta: ${YELLOW}$WEBPANEL_PORT${NC}"
            ui_fila "  URL: ${CYAN}$(painel_url)${NC}"
            ui_sep; ui_fila ""
            
            ui_opcion "1" "Iniciar Painel Web"
            ui_opcion "2" "Parar Painel Web"
            ui_opcion "3" "Reiniciar Painel Web"
            ui_opcion "4" "Ver estado detalhado"
            ui_opcion "5" "Mudar porta do painel"
            ui_opcion "6" "Ver logs do painel"
            ui_opcion "7" "Desinstalar Painel Web"
            ui_opcion "8" "Segurança do acesso (HTTPS)"
            ui_opcion "9" "Senha do painel (ver / redefinir)"
            if systemctl is-enabled --quiet hex-webpanel.service 2>/dev/null; then ui_opcion "10" "Desativar Painel Web"; else ui_opcion "10" "Ativar Painel Web"; fi
            ui_opcion "0" "Voltar"
            
            ui_bot; echo ""; echo -ne "  ${CYAN}►${NC} Selecione a opção: "; read -r opt
            
            case "$opt" in
                1) systemctl start hex-webpanel.service; sleep 1; systemctl is-active --quiet hex-webpanel.service && echo -e "  ${GREEN}✓ Painel Web iniciado${NC}" || echo -e "  ${RED}✗ Erro ao iniciar${NC}"; pause_return ;;
                2) systemctl stop hex-webpanel.service; echo -e "  ${GREEN}✓ Painel Web parado${NC}"; pause_return ;;
                3) systemctl restart hex-webpanel.service; echo -e "  ${GREEN}✓ Painel Web reiniciado${NC}"; pause_return ;;
                4) echo ""; systemctl status hex-webpanel.service --no-pager; pause_return ;;
                5) mudar_porta_webpanel ;;
                8) menu_seguranca_painel ;;
                9) menu_senha_painel ;;
                10) painel_ativar_desativar ;;
                6) echo ""; journalctl -u hex-webpanel.service -n 50 --no-pager; pause_return ;;
                7)
                    echo -e "  ${CYAN}Desinstalando Painel Web...${NC}"
                    systemctl stop hex-webpanel.service 2>/dev/null
                    systemctl disable hex-webpanel.service 2>/dev/null
                    rm -f /etc/systemd/system/hex-webpanel.service
                    rm -rf /opt/hex-webpanel
                    rm -f "$WEBPANEL_PORT_FILE"
                    systemctl daemon-reload
                    echo -e "  ${GREEN}✓ Painel Web desinstalado${NC}"; pause_return
                    ;;
                0) break ;;
                *) echo -e "  ${RED}✗ Opção inválida${NC}"; pause_return ;;
            esac
        fi
    done
    menu_principal
}

# ═══════════════════════════════════════════════════════════════
#  GERENCIAMENTO DE USUÁRIOS (SUBMENU)
# ═══════════════════════════════════════════════════════════════

