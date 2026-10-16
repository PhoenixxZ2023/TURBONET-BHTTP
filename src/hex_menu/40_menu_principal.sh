menu_principal() {
    clear; ui_top; ui_titulo "MANAGER"; ui_sep
    
    bhttp_st=$(get_svc_status "bhttp" "$BHTTP_PORTS_CONF")
    hcr_st=$(get_svc_status "hcr" "$HCR_PORTS_CONF")
    udpgw_st=$(get_svc_status "udpgw" "$UDPGW_PORTS_CONF")
    [ "$cron_active" -gt 0 ] && cleanup_status="${GREEN}● ATIVO${NC}" || cleanup_status="${RED}● INATIVO${NC}"
    
    webpanel_state=$(systemctl is-active $WEBPANEL_SERVICE 2>/dev/null || echo "inactivo")
    [ -f "/opt/hex-webpanel/app.py" ] && [ "$webpanel_state" = "active" ] && webpanel_status="${GREEN}● ATIVO${NC}" || webpanel_status="${RED}● INATIVO${NC}"
    [ ! -f "/opt/hex-webpanel/app.py" ] && webpanel_status="${YELLOW}● NÃO INSTALADO${NC}"
    
    ui_fila ""
    ui_fila "  ${CYAN}BHTTP${NC}      - $bhttp_st"
    ui_fila "  ${CYAN}HCR${NC}        - $hcr_st"
    ui_fila "  ${CYAN}UDPGW${NC}      - $udpgw_st"
    ui_fila "  ${CYAN}PAINEL WEB${NC} - Porta $WEBPANEL_PORT     $webpanel_status"
    ui_fila "  ${CYAN}LIMPADOR${NC}   - Diário 03:00   $cleanup_status"
    ui_fila "  ${CYAN}IP DA VPS${NC}   - $(ip_publico)"
    ui_fila "  ${CYAN}VERSÃO${NC}     - v$HEX_VERSION"
    ui_fila ""; ui_sep
    
    ui_opcion "1" "Gerenciar BHTTP"
    ui_opcion "2" "Gerenciar HCR"
    ui_opcion "3" "Gerenciar UDPGW"
    ui_opcion "4" "Gerenciar Painel Web"
    ui_opcion "5" "Gerenciar Usuários"
    ui_opcion "6" "Ver logs"
    ui_opcion "7" "Buscar atualizações"
    ui_opcion "8" "Desinstalar tudo"
    ui_opcion "9" "IP da VPS (ver / atualizar / definir)"
    ui_opcion "0" "Sair"
    
    ui_bot; echo ""
    echo -ne "  ${CYAN}►${NC} Selecione a opção: "; read -r opcion
    
    case "$opcion" in
        1) menu_generico "bhttp" "BHTTP" "$BHTTP_PORTS_CONF" "tcp" ;;
        2) menu_generico "hcr" "HCR" "$HCR_PORTS_CONF" "tcp" ;;
        3) menu_generico "udpgw" "UDPGW" "$UDPGW_PORTS_CONF" "udp" ;;
        4) gerenciar_webpanel ;;
        5) gerenciar_usuarios ;;
        6) ver_logs ;;
        7) menu_atualizacoes ;;
        8) desinstalar ;;
        9) menu_ip_servidor ;;
        0) exit 0 ;;
        *) echo -e "  ${RED}✗ Opção inválida${NC}"; pause_return; menu_principal ;;
    esac
}

# ═══════════════════════════════════════════════════════════════
#  GERENCIAMENTO GENÉRICO DE SERVIÇOS
# ═══════════════════════════════════════════════════════════════

