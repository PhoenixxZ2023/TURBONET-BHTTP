ver_logs() {
    clear; ui_top; ui_titulo "VER LOGS"; ui_sep; ui_fila ""
    ui_opcion "1" "BHTTP (50 linhas)"; ui_opcion "2" "HCR (50 linhas)"; ui_opcion "3" "UDPGW (todos)"
    ui_opcion "4" "BHTTP (todas)"; ui_opcion "5" "HCR (todas)"; ui_opcion "6" "Limpeza"; ui_opcion "7" "Painel Web"; ui_opcion "0" "Voltar"
    ui_bot; echo ""; echo -ne "  ${CYAN}►${NC} Opção: "; read -r opt
    
    case "$opt" in
        1) journalctl -u "bhttp@*.service" -n 50 --no-pager; pause_return ;;
        2) journalctl -u "hcr@*.service" -n 50 --no-pager; pause_return ;;
        3) [ -f "$UDPGW_PORTS_CONF" ] && while read -r port; do [ -z "$port" ] && continue; echo -e "${YELLOW}═══ Porta $port ═══${NC}"; journalctl -u "udpgw@${port}.service" -n 20 --no-pager; echo ""; done < "$UDPGW_PORTS_CONF"; pause_return ;;
        4) journalctl -u "bhttp@*.service" --no-pager | less ;;
        5) journalctl -u "hcr@*.service" --no-pager | less ;;
        6) [ -f "$CLEANUP_LOG" ] && tail -100 "$CLEANUP_LOG" | less || { echo -e "  ${YELLOW}Sem log${NC}"; pause_return; } ;;
        7) journalctl -u hex-webpanel.service -n 50 --no-pager; pause_return ;;
        0) ;; *) echo -e "  ${RED}✗ Inválida${NC}"; pause_return ;;
    esac
}

desinstalar() {
    clear; ui_top; ui_titulo "DESINSTALAR TUDO"; ui_sep; ui_fila ""
    ui_fila "  ${YELLOW}⚠${NC}  Você está prestes a desinstalar TUDO"
    ui_fila ""; ui_sep
    echo ""; echo -ne "  ${RED}✗ Escreva${NC} ${YELLOW}${BOLD}CONFIRMAR${NC} ${RED}para continuar:${NC} "; read -r confirm
    
    if [ "$confirm" = "CONFIRMAR" ]; then
        echo -e "  ${CYAN}Parando serviços...${NC}"
        for svc in bhttp hcr udpgw; do
            conf="/etc/hex/${svc}_ports.conf"
            [ -f "$conf" ] && while read -r port; do [ -z "$port" ] && continue; systemctl stop "${svc}@${port}.service" 2>/dev/null || true; done < "$conf"
        done
        
        echo -e "  ${CYAN}Removendo Painel Web...${NC}"
        systemctl stop hex-webpanel.service 2>/dev/null || true
        systemctl disable hex-webpanel.service 2>/dev/null || true
        rm -f /etc/systemd/system/hex-webpanel.service
        rm -rf /opt/hex-webpanel
        
        echo -e "  ${CYAN}Removendo arquivos...${NC}"
        rm -f /etc/systemd/system/bhttp@.service /etc/systemd/system/hcr@.service /etc/systemd/system/udpgw@.service
        rm -rf /opt/bhttp /opt/hcr /opt/udpgw /etc/bhttp /etc/hcr /etc/hex
        rm -f /usr/local/bin/hex_menu /usr/bin/hex_menu /usr/local/bin/bhttp /usr/local/bin/hcr /usr/local/bin/hex_cleanup.sh /var/log/hex-cleanup.log
        
        echo -e "  ${CYAN}Removendo usuários hexusers...${NC}"
        getent group "$USER_GROUP" >/dev/null 2>&1 && { for user in $(getent group "$USER_GROUP" | cut -d: -f4 | tr ',' '\n'); do userdel -r "$user" 2>/dev/null; done; groupdel "$USER_GROUP" 2>/dev/null; }
        
        crontab -l 2>/dev/null | grep -v "hex_cleanup.sh" | crontab -
        systemctl daemon-reload >/dev/null 2>&1
        
        echo ""; echo -e "  ${GREEN}✓ Desinstalado completamente${NC}"; echo ""; exit 0
    else
        echo -e "  ${YELLOW}⚠ Cancelado${NC}"; pause_return; menu_principal
    fi
}

# ═══════════════════════════════════════════════════════════════
#  VERIFICAÇÃO E EXECUÇÃO
# ═══════════════════════════════════════════════════════════════

[ "$EUID" -ne 0 ] && { echo -e "  ${RED}✗ Requer permissões de root${NC}"; exit 1; }
migrar_users_db
menu_principal
