# ── Ativar / Desativar serviço: instalado, mas só liga quando o usuário pedir ──
svc_porta_padrao() { case "$1" in bhttp) echo 80 ;; hcr) echo 8080 ;; udpgw) echo 7300 ;; *) echo "" ;; esac; }

# 0 se alguma porta do serviço está ativa ou habilitada no boot
svc_habilitado() {
    local svc=$1 conf=$2 port
    [ -f "$conf" ] || return 1
    while read -r port; do
        [ -z "$port" ] && continue
        systemctl is-enabled --quiet "${svc}@${port}.service" 2>/dev/null && return 0
        systemctl is-active --quiet "${svc}@${port}.service" 2>/dev/null && return 0
    done < "$conf"
    return 1
}

fw_abrir_svc() {   # <svc> <proto> <porta>  (UDPGW só abre se estiver no modo público)
    local svc=$1 proto=$2 port=$3
    if [ "$svc" != "udpgw" ] || [ -f "$UDPGW_PUBLIC_FLAG" ]; then
        iptables -C INPUT -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null || iptables -I INPUT -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null
        [ "$proto" = "udp" ] && { iptables -C INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null; }
        command -v ufw >/dev/null 2>&1 && { ufw allow "$port/$proto" >/dev/null 2>&1; [ "$proto" = "udp" ] && ufw allow "$port/tcp" >/dev/null 2>&1; }
    fi
    return 0
}
fw_fechar_svc() {  # <svc> <proto> <porta>
    local proto=$2 port=$3
    iptables -D INPUT -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null
    [ "$proto" = "udp" ] && iptables -D INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null
    command -v ufw >/dev/null 2>&1 && { ufw delete allow "$port/$proto" >/dev/null 2>&1; [ "$proto" = "udp" ] && ufw delete allow "$port/tcp" >/dev/null 2>&1; }
    return 0
}
# nome do processo que está escutando na porta (vazio se livre)
porta_ocupada_por() {
    local linha
    linha=$(ss -H -tulnp "sport = :$1" 2>/dev/null | head -1)
    [ -z "$linha" ] && return 1
    echo "$linha" | grep -o 'users:(("[^"]*"' | sed 's/users:(("//; s/"$//' | head -1
    return 0
}
aviso_firewall_provedor() {  # <lista de portas>
    if /usr/local/bin/hex_ip.sh nat 2>/dev/null; then
        echo -e "  ${YELLOW}⚠ Sua VPS está atrás de NAT: libere também no firewall do PROVEDOR${NC}"
        echo -e "  ${YELLOW}  (Security List / Security Group) a(s) porta(s): ${BOLD}$1${NC}"
    fi
}

generico_ativar_desativar() {
    local svc=$1 title=$2 conf=$3 proto=$4 port padrao c quem ok=0 falhou=0 lista=""
    padrao=$(svc_porta_padrao "$svc")
    [ -f "$conf" ] || : > "$conf"
    clear; ui_top
    if svc_habilitado "$svc" "$conf"; then
        ui_titulo "DESATIVAR $title"; ui_sep; ui_fila ""
        echo -e "  Isso ${BOLD}para e desliga${NC} todas as portas do $title (não iniciam no boot)"
        echo -e "  e ${BOLD}fecha${NC} o firewall delas. As portas continuam na lista para ativar de novo."
        echo -ne "\n  ${YELLOW}Desativar o $title? (s/n):${NC} "; read -r c
        [ "$c" = "s" ] || [ "$c" = "S" ] || { echo -e "  ${GRIS}Cancelado${NC}"; pause_return; return; }
        while read -r port; do
            [ -z "$port" ] && continue
            systemctl stop "${svc}@${port}.service" 2>/dev/null
            systemctl disable "${svc}@${port}.service" >/dev/null 2>&1
            fw_fechar_svc "$svc" "$proto" "$port"
            echo -e "  ${GREEN}✓ Porta $port desativada${NC}"
        done < "$conf"
        fw_persistir
        echo -e "\n  ${GREEN}✓ $title desativado${NC} ${GRIS}(instalado; para ligar de novo use esta mesma opção)${NC}"
        pause_return; return
    fi

    ui_titulo "ATIVAR $title"; ui_sep; ui_fila ""
    if ! grep -q '[0-9]' "$conf" 2>/dev/null; then
        echo -ne "  ${WHITE}Porta para o $title${NC} ${GRIS}[$padrao]${NC}: "; read -r port
        port=${port:-$padrao}
        if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
            echo -e "  ${RED}✗ Porta inválida${NC}"; pause_return; return
        fi
        echo "$port" >> "$conf"
    else
        echo -e "  Portas configuradas: ${YELLOW}$(paste -sd' ' "$conf")${NC}"
        echo -e "  ${GRIS}(para trocar ou incluir outra, use Adicionar/Remover porta)${NC}"
    fi
    echo ""
    while read -r port; do
        [ -z "$port" ] && continue
        if ! systemctl is-active --quiet "${svc}@${port}.service" 2>/dev/null; then
            if quem=$(porta_ocupada_por "$port"); then
                echo -e "  ${RED}✗ Porta $port já está em uso${NC} ${GRIS}${quem:+(processo: $quem)}${NC} - pulada"
                falhou=$((falhou+1)); continue
            fi
        fi
        fw_abrir_svc "$svc" "$proto" "$port"
        systemctl enable "${svc}@${port}.service" >/dev/null 2>&1
        systemctl start "${svc}@${port}.service" 2>/dev/null
        sleep 1
        if systemctl is-active --quiet "${svc}@${port}.service" 2>/dev/null; then
            echo -e "  ${GREEN}✓ Porta $port ativa${NC}"; ok=$((ok+1)); lista="${lista:+$lista, }$port"
        else
            echo -e "  ${YELLOW}⚠ Porta $port não iniciou (veja: journalctl -u ${svc}@${port} -n 20)${NC}"; falhou=$((falhou+1))
        fi
    done < "$conf"
    fw_persistir
    echo ""
    if [ "$ok" -gt 0 ]; then
        echo -e "  ${GREEN}✓ $title ativado${NC} em ${YELLOW}$lista${NC} ${GRIS}- IP: $(ip_publico)${NC}"
        if [ "$svc" = "udpgw" ] && [ ! -f "$UDPGW_PUBLIC_FLAG" ]; then
            echo -e "  ${GRIS}UDPGW escuta só em 127.0.0.1 (use pelo túnel SSH); não precisa abrir no provedor.${NC}"
        else
            aviso_firewall_provedor "$lista"
        fi
    else
        echo -e "  ${RED}✗ Nenhuma porta foi ativada${NC}"
    fi
    pause_return
}

menu_generico() {
    local svc=$1 title=$2 conf=$3 proto=$4 rotulo_toggle
    while true; do
        clear; ui_top; ui_titulo "GERENCIAMENTO $title"; ui_sep; echo ""
        echo -e "  ${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
        echo -e "  ${CYAN}║${NC}  ${WHITE}${BOLD}Porta       Estado               Protocolo${NC}                 ${CYAN}║${NC}"
        echo -e "  ${CYAN}╠══════════════════════════════════════════════════════════════╣${NC}"
        
        count=0
        if [ -f "$conf" ]; then
            while read -r port; do
                [ -z "$port" ] && continue; ((count++))
                systemctl is-active --quiet "${svc}@${port}.service" 2>/dev/null && status="${GREEN}● ATIVO${NC}    " || status="${RED}● INATIVO${NC}  "
                printf "  ${CYAN}║${NC}  ${YELLOW}%-10s${NC} %b  ${GRIS}%s${NC}                     ${CYAN}║${NC}\n" "$port" "$status" "$proto"
            done < "$conf"
        fi
        [ "$count" -eq 0 ] && echo -e "  ${CYAN}║${NC}  ${YELLOW}Nenhuma porta configurada${NC}                            ${CYAN}║${NC}"
        echo -e "  ${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"; echo ""
        if svc_habilitado "$svc" "$conf"; then
            ui_fila "  Serviço: ${GREEN}● ATIVADO${NC}"; rotulo_toggle="Desativar $title"
        else
            ui_fila "  Serviço: ${YELLOW}○ DESATIVADO${NC} ${GRIS}(instalado; use a opção 7 para ativar)${NC}"; rotulo_toggle="Ativar $title"
        fi
        ui_sep; ui_fila ""
        
        ui_opcion "1" "Adicionar porta"
        ui_opcion "2" "Remover porta"
        ui_opcion "3" "Iniciar todos"
        ui_opcion "4" "Parar todos"
        ui_opcion "5" "Reiniciar todos"
        ui_opcion "6" "Controle individual"
        ui_opcion "7" "$rotulo_toggle"
        ui_opcion "0" "Voltar"
        ui_bot; echo ""; echo -ne "  ${CYAN}►${NC} Selecione a opção: "; read -r opt
        
        case "$opt" in
            1) generico_adicionar_porta "$svc" "$title" "$conf" "$proto" ;;
            2) generico_remover_porta "$svc" "$title" "$conf" "$proto" ;;
            3) generico_acao_todos "$svc" "$conf" "start" "iniciado"; pause_return ;;
            4) generico_acao_todos "$svc" "$conf" "stop" "parado"; pause_return ;;
            5) generico_acao_todos "$svc" "$conf" "restart" "reiniciado"; pause_return ;;
            6) generico_controle_individual "$svc" "$conf"; pause_return ;;
            7) generico_ativar_desativar "$svc" "$title" "$conf" "$proto" ;;
            0) break ;; *) echo -e "  ${RED}✗ Opção inválida${NC}"; pause_return ;;
        esac
    done
    menu_principal
}

generico_adicionar_porta() {
    local svc=$1 title=$2 conf=$3 proto=$4
    clear; ui_top; ui_titulo "ADICIONAR PORTA $title"; ui_sep; ui_fila ""
    echo -ne "  ${WHITE}Número da porta:${NC} "; read -r new_port
    if ! [[ "$new_port" =~ ^[0-9]+$ ]] || [ "$new_port" -lt 1 ] || [ "$new_port" -gt 65535 ]; then
        echo -e "  ${RED}✗ Porta inválida${NC}"; pause_return; return
    fi
    grep -qw "^$new_port$" "$conf" 2>/dev/null && { echo -e "  ${RED}✗ A porta já está configurada${NC}"; pause_return; return; }
    ss -tuln | grep -q ":$new_port " && { echo -e "  ${RED}✗ A porta já está em uso${NC}"; pause_return; return; }
    
    echo "$new_port" >> "$conf"
    # UDPGW escuta em 127.0.0.1 por padrão: só abre o firewall no modo público (/etc/hex/udpgw_public)
    if [ "$svc" != "udpgw" ] || [ -f "$UDPGW_PUBLIC_FLAG" ]; then
        iptables -C INPUT -p "$proto" --dport "$new_port" -j ACCEPT 2>/dev/null || iptables -I INPUT -p "$proto" --dport "$new_port" -j ACCEPT 2>/dev/null
        [ "$proto" == "udp" ] && { iptables -C INPUT -p tcp --dport "$new_port" -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport "$new_port" -j ACCEPT 2>/dev/null; }
        command -v ufw >/dev/null 2>&1 && { ufw allow "$new_port/$proto" >/dev/null 2>&1; [ "$proto" == "udp" ] && ufw allow "$new_port/tcp" >/dev/null 2>&1; }
        fw_persistir
    fi
    
    systemctl enable "${svc}@${new_port}.service" >/dev/null 2>&1
    systemctl start "${svc}@${new_port}.service" 2>/dev/null
    sleep 1
    systemctl is-active --quiet "${svc}@${new_port}.service" 2>/dev/null && echo -e "  ${GREEN}✓ Porta $new_port adicionada e ativa${NC}" || echo -e "  ${YELLOW}⚠ Porta adicionada, mas não iniciou${NC}"
    pause_return
}

generico_remover_porta() {
    local svc=$1 title=$2 conf=$3 proto=$4
    clear; ui_top; ui_titulo "REMOVER PORTA $title"; ui_sep; ui_fila ""
    [ ! -s "$conf" ] && { echo -e "  ${YELLOW}Não há portas configuradas${NC}"; pause_return; return; }
    
    echo -e "  ${CYAN}Portas atuais:${NC}"; echo ""
    counter=1
    while read -r port; do
        [ -z "$port" ] && continue
        systemctl is-active --quiet "${svc}@${port}.service" 2>/dev/null && status="${GREEN}● ATIVO${NC}" || status="${RED}● INATIVO${NC}"
        printf "    ${YELLOW}[%s]${NC} Porta ${WHITE}%s${NC}  %b\n" "$counter" "$port" "$status"; ((counter++))
    done < "$conf"
    echo ""
    
    echo -ne "  ${WHITE}Número da porta a remover:${NC} "; read -r del_port
    grep -qw "^$del_port$" "$conf" || { echo -e "  ${RED}✗ A porta não existe${NC}"; pause_return; return; }
    
    systemctl stop "${svc}@${del_port}.service" 2>/dev/null
    systemctl disable "${svc}@${del_port}.service" 2>/dev/null
    sed -i "/^${del_port}$/d" "$conf"
    iptables -D INPUT -p $proto --dport $del_port -j ACCEPT 2>/dev/null
    [ "$proto" == "udp" ] && iptables -D INPUT -p tcp --dport $del_port -j ACCEPT 2>/dev/null
    command -v ufw >/dev/null 2>&1 && { ufw delete allow $del_port/$proto >/dev/null 2>&1; [ "$proto" == "udp" ] && ufw delete allow $del_port/tcp >/dev/null 2>&1; }
    fw_persistir
    
    echo -e "  ${GREEN}✓ Porta $del_port removida completamente${NC}"; pause_return
}

generico_acao_todos() {
    local svc=$1 conf=$2 action=$3 msg=$4
    # Traduzir o prefixo de ação para o console
    local action_pt
    case "$action" in
        "start") action_pt="Iniciando" ;;
        "stop") action_pt="Parando" ;;
        "restart") action_pt="Reiniciando" ;;
    esac
    echo -e "  ${CYAN}${action_pt} todas as portas $svc...${NC}"
    [ -f "$conf" ] && while read -r port; do 
        [ -z "$port" ] && continue
        systemctl $action "${svc}@${port}.service" 2>/dev/null
        echo -e "  ${GREEN}✓ Porta $port $msg${NC}"
    done < "$conf"
}

generico_controle_individual() {
    local svc=$1 conf=$2
    clear; ui_top; ui_titulo "CONTROLE INDIVIDUAL"; ui_sep; ui_fila ""
    echo -e "  ${CYAN}Portas disponíveis:${NC}"; echo ""
    counter=1
    while read -r port; do
        [ -z "$port" ] && continue
        systemctl is-active --quiet "${svc}@${port}.service" 2>/dev/null && status="${GREEN}● ATIVO${NC}" || status="${RED}● INATIVO${NC}"
        printf "    ${YELLOW}[%s]${NC} Porta ${WHITE}%s${NC}  %b\n" "$counter" "$port" "$status"; ((counter++))
    done < "$conf"
    echo ""; echo -ne "  ${WHITE}Número da porta:${NC} "; read -r target_port
    grep -qw "^$target_port$" "$conf" || { echo -e "  ${RED}✗ Porta não encontrada${NC}"; return; }
    
    echo ""; echo -e "  ${CYAN}Ações para a porta $target_port:${NC}"; echo ""
    ui_opcion "1" "Iniciar"; ui_opcion "2" "Parar"; ui_opcion "3" "Reiniciar"; ui_opcion "4" "Ver estado"; ui_opcion "0" "Cancelar"
    echo ""; echo -ne "  ${CYAN}►${NC} Opção: "; read -r action
    case "$action" in
        1) systemctl start "${svc}@${target_port}.service"; echo -e "  ${GREEN}✓ Iniciado${NC}" ;;
        2) systemctl stop "${svc}@${target_port}.service"; echo -e "  ${GREEN}✓ Parado${NC}" ;;
        3) systemctl restart "${svc}@${target_port}.service"; echo -e "  ${GREEN}✓ Reiniciado${NC}" ;;
        4) systemctl status "${svc}@${target_port}.service" --no-pager ;;
        0) return ;; *) echo -e "  ${RED}✗ Opção inválida${NC}" ;;
    esac
}

# ═══════════════════════════════════════════════════════════════
#  INSTALAÇÃO DO PAINEL WEB
# ═══════════════════════════════════════════════════════════════

