# ── modo de acesso do painel (HTTPS automático) ──
# IPv4 público da VPS (hex_ip.sh); sem o script, cai para o primeiro IP local
ip_publico() {
    local ip
    ip=$(/usr/local/bin/hex_ip.sh 2>/dev/null)
    echo "${ip:-$(hostname -I | awk '{print $1}')}"
}
# grava as regras do iptables quando existe netfilter-persistent (imagens Oracle); sem ele não faz nada
fw_persistir() { command -v netfilter-persistent >/dev/null 2>&1 && netfilter-persistent save >/dev/null 2>&1; return 0; }
painel_url() {
    local u
    u=$(/usr/local/bin/hex_panel_mode.sh url 2>/dev/null)
    echo "${u:-http://$(ip_publico):$WEBPANEL_PORT}"
}
ip_script_ok() {
    local sc=/usr/local/bin/hex_ip.sh
    if [ ! -x "$sc" ]; then
        ui_info "Baixando o detector de IP..."
        if hex_obter_manifesto; then
            hex_instalar_arquivo hex_ip.sh "$sc" 755 sh
            rm -f "$HEX_MANIFEST"
        fi
    fi
    [ -x "$sc" ]
}
menu_ip_servidor() {
    local sc=/usr/local/bin/hex_ip.sh ip
    while true; do
        clear; ui_top; ui_titulo "IP DA VPS (usado nas URLs e nas mensagens)"; ui_sep; ui_fila ""
        if ! ip_script_ok; then ui_error "Não foi possível obter o detector de IP"; pause_return; return; fi
        "$sc" status | while IFS= read -r linha; do ui_fila "  $linha"; done
        if "$sc" nat 2>/dev/null; then
            ui_fila ""
            ui_fila "  ${YELLOW}⚠ Libere também no firewall do PROVEDOR (Security List/Group):${NC}"
            ui_fila "    BHTTP: $(paste -sd, "$BHTTP_PORTS_CONF" 2>/dev/null)  HCR: $(paste -sd, "$HCR_PORTS_CONF" 2>/dev/null)  Painel: $WEBPANEL_PORT"
        fi
        ui_fila ""; ui_sep; ui_fila ""
        ui_opcion "1" "Descobrir o IP de novo"
        ui_opcion "2" "Definir o IP manualmente"
        ui_opcion "3" "Voltar à detecção automática"
        ui_opcion "0" "Voltar"
        ui_bot; echo ""; echo -ne "  ${CYAN}►${NC} Selecione a opção: "; read -r opt
        case "$opt" in
            1) ip=$("$sc" refresh); echo -e "  ${GREEN}✓ IP detectado: $ip${NC}"; pause_return ;;
            2) echo -ne "  ${WHITE}IPv4 da VPS:${NC} "; read -r ip
               if "$sc" set "$ip" >/dev/null 2>&1; then echo -e "  ${GREEN}✓ IP definido: $ip${NC}"
               else echo -e "  ${RED}✗ IPv4 inválido${NC}"; fi; pause_return ;;
            3) ip=$("$sc" unset); echo -e "  ${GREEN}✓ Detecção automática: $ip${NC}"; pause_return ;;
            0) return ;;
            *) echo -e "  ${RED}✗ Opção inválida${NC}"; pause_return ;;
        esac
    done
}
painel_modo_script() {
    local sc=/usr/local/bin/hex_panel_mode.sh
    if [ ! -x "$sc" ]; then
        ui_info "Baixando o módulo de segurança do painel..."
        if hex_obter_manifesto; then
            hex_instalar_arquivo hex_panel_mode.sh "$sc" 755 sh
            rm -f "$HEX_MANIFEST"
        fi
    fi
    [ -x "$sc" ]
}
painel_aplicar_porta() {   # <nova_porta>: troca a porta do painel (serviço + firewall) e reverte se não subir
    local new=$1 old quem
    old=$(cat "$WEBPANEL_PORT_FILE" 2>/dev/null || echo 9000)
    [ "$new" = "$old" ] && return 0
    if quem=$(porta_ocupada_por "$new"); then
        echo -e "  ${RED}✗ A porta $new já está em uso${NC} ${GRIS}${quem:+(processo: $quem)}${NC}"; return 1
    fi
    systemctl stop hex-webpanel.service 2>/dev/null
    echo "$new" > "$WEBPANEL_PORT_FILE"; chmod 644 "$WEBPANEL_PORT_FILE"
    fw_fechar_svc painel tcp "$old"; fw_abrir_svc painel tcp "$new"; fw_persistir
    systemctl start hex-webpanel.service 2>/dev/null; sleep 2
    if systemctl is-active --quiet hex-webpanel.service 2>/dev/null; then
        WEBPANEL_PORT=$new
        echo -e "  ${GREEN}✓ Porta do painel alterada para $new${NC}"
        aviso_firewall_provedor "$new"
        return 0
    fi
    echo -e "  ${RED}✗ O painel não subiu na porta $new; restaurando a porta $old...${NC}"
    echo "$old" > "$WEBPANEL_PORT_FILE"; fw_fechar_svc painel tcp "$new"; fw_abrir_svc painel tcp "$old"; fw_persistir
    systemctl start hex-webpanel.service 2>/dev/null
    return 1
}
menu_seguranca_painel() {
    local sc=/usr/local/bin/hex_panel_mode.sh
    while true; do
        clear; ui_top; ui_titulo "SEGURANÇA DO ACESSO AO PAINEL"; ui_sep; ui_fila ""
        if ! painel_modo_script; then
            ui_error "Não foi possível obter o módulo (sem internet?)"; pause_return; return
        fi
        "$sc" status | while IFS= read -r linha; do ui_fila "  $linha"; done
        ui_fila ""; ui_sep; ui_fila ""
        ui_opcion "1" "Ativar HTTPS ${GREEN}(recomendado)${NC} - criptografa a senha"
        ui_opcion "2" "Voltar para HTTP simples"
        ui_opcion "3" "Gerar novo certificado HTTPS"
        ui_opcion "4" "Somente local (127.0.0.1) ${GRIS}- avançado${NC}"
        ui_opcion "5" "Liberar acesso externo"
        ui_opcion "6" "Usar um domínio (Cloudflare / DNS) ${GRIS}- ex.: painel.seudominio.com${NC}"
        ui_opcion "7" "Remover o domínio"
        ui_opcion "8" "Tempo de inatividade da sessão"
        ui_opcion "0" "Voltar"
        ui_bot; echo ""; echo -ne "  ${CYAN}►${NC} Selecione a opção: "; read -r opt
        case "$opt" in
            1) echo ""; "$sc" https; WEBPANEL_PORT=$(cat "$WEBPANEL_PORT_FILE" 2>/dev/null || echo 9000); pause_return ;;
            2) echo -ne "  ${YELLOW}⚠ A senha do painel voltará a trafegar sem criptografia. Continuar? (s/n):${NC} "; read -r c
               if [ "$c" = "s" ] || [ "$c" = "S" ]; then echo ""; "$sc" http; fi; pause_return ;;
            3) echo ""; "$sc" https --renew; pause_return ;;
            4) echo -e "  ${YELLOW}⚠ O painel deixará de abrir por IP:PORTA. Você só acessará por túnel SSH ou proxy.${NC}"
               echo -ne "  ${YELLOW}Continuar? (s/n):${NC} "; read -r c
               if [ "$c" = "s" ] || [ "$c" = "S" ]; then echo ""; "$sc" local; fi; pause_return ;;
            5) echo ""; "$sc" external; pause_return ;;
            6) echo -e "  ${GRIS}Crie antes, na Cloudflare, um registro A: seu-subdominio → IP da VPS ($(ip_publico)).${NC}"
               echo -ne "  ${WHITE}Domínio (ex.: painel.seudominio.com):${NC} "; read -r dom
               echo ""; "$sc" domain "$dom"; rc=$?
               WEBPANEL_PORT=$(cat "$WEBPANEL_PORT_FILE" 2>/dev/null || echo 9000)
               if [ "$rc" -eq 0 ] && ! "$sc" cf-port-ok; then
                   echo -ne "\n  ${YELLOW}Mudar a porta do painel para 8443 agora (aceita pela Cloudflare)? (S/n):${NC} "; read -r c
                   if [ "$c" != "n" ] && [ "$c" != "N" ]; then
                       painel_aplicar_porta 8443 && echo -e "  ${GREEN}URL: $(painel_url)${NC}"
                   fi
               fi
               pause_return ;;
            7) echo -ne "  ${YELLOW}Remover o domínio do painel? (s/n):${NC} "; read -r c
               if [ "$c" = "s" ] || [ "$c" = "S" ]; then echo ""; "$sc" domain off; fi; pause_return ;;
            8) echo -ne "  ${WHITE}Minutos de inatividade até sair (1 a 1440)${NC} ${GRIS}[3]${NC}: "; read -r mins; mins=${mins:-3}
               if [[ "$mins" =~ ^[0-9]+$ ]] && [ "$mins" -ge 1 ] && [ "$mins" -le 1440 ]; then echo ""; "$sc" idle $((mins * 60))
               else echo -e "  ${RED}✗ Informe um número de 1 a 1440${NC}"; fi; pause_return ;;
            0) return ;;
            *) echo -e "  ${RED}✗ Opção inválida${NC}"; pause_return ;;
        esac
    done
}

# ── senha do painel: ver a inicial / redefinir ──
PAINEL_PY="${PAINEL_PY:-/opt/hex-webpanel/venv/bin/python}"
PAINEL_APP="${PAINEL_APP:-/opt/hex-webpanel/app.py}"
PAINEL_PASS_INICIAL="${PAINEL_PASS_INICIAL:-/etc/hex/webpanel_initial_password.txt}"
painel_aplicar_senha() {  # reinicia o painel para valer a nova senha (e zerar bloqueios de login)
    systemctl restart hex-webpanel.service 2>/dev/null
    echo -e "  ${GREEN}✓ Painel reiniciado. Sessões antigas foram desconectadas.${NC}"
}
menu_senha_painel() {
    local opt out p1 p2
    while true; do
        clear; ui_top; ui_titulo "SENHA DO PAINEL WEB"; ui_sep; ui_fila ""
        if [ -f "$PAINEL_PASS_INICIAL" ]; then
            ui_fila "  A senha inicial ainda não foi trocada: dá para ver."
        else
            ui_fila "  A senha já foi trocada. Ela é guardada só em forma de hash,"
            ui_fila "  então não dá para ver; se esqueceu, gere ou defina uma nova."
        fi
        ui_fila ""; ui_sep; ui_fila ""
        ui_opcion "1" "Ver a senha inicial"
        ui_opcion "2" "Gerar uma nova senha aleatória"
        ui_opcion "3" "Definir minha própria senha"
        ui_opcion "0" "Voltar"
        ui_bot; echo ""; echo -ne "  ${CYAN}►${NC} Selecione a opção: "; read -r opt
        case "$opt" in
            1) if [ -f "$PAINEL_PASS_INICIAL" ]; then
                   echo ""; sed -n 's/^Senha inicial do painel: /  Senha: /p' "$PAINEL_PASS_INICIAL"
               else
                   echo -e "  ${YELLOW}⚠ Não há senha inicial salva (já foi trocada). Use a opção 2 ou 3.${NC}"
               fi; pause_return ;;
            2|3)
               if ! grep -q -- "--set-password" "$PAINEL_APP" 2>/dev/null; then
                   echo -e "  ${YELLOW}⚠ Este painel é de uma versão antiga. Atualize em: menu principal → Buscar atualizações.${NC}"
                   pause_return; continue
               fi
               if [ "$opt" = "2" ]; then
                   out=$("$PAINEL_PY" "$PAINEL_APP" --reset-password 2>&1) || { echo -e "  ${RED}✗ Erro: $out${NC}"; pause_return; continue; }
                   echo ""; echo -e "  ${GREEN}✓ Nova senha gerada${NC}"
                   echo -e "  ${BOLD}Senha:${NC} ${YELLOW}${out#NOVA_SENHA=}${NC}"
                   echo -e "  ${GRIS}Anote. Troque no dashboard depois, se quiser.${NC}"
               else
                   echo -ne "  ${WHITE}Nova senha (8 a 72 caracteres):${NC} "; read -rs p1; echo ""
                   echo -ne "  ${WHITE}Repita a senha:${NC} "; read -rs p2; echo ""
                   if [ "$p1" != "$p2" ]; then echo -e "  ${RED}✗ As senhas não coincidem${NC}"; pause_return; continue; fi
                   out=$(printf '%s\n' "$p1" | "$PAINEL_PY" "$PAINEL_APP" --set-password 2>&1) \
                       || { echo -e "  ${RED}✗ ${out}${NC}"; pause_return; continue; }
                   echo -e "  ${GREEN}✓ Senha definida${NC}"
               fi
               painel_aplicar_senha; pause_return ;;
            0) return ;;
            *) echo -e "  ${RED}✗ Opção inválida${NC}"; pause_return ;;
        esac
    done
}

mudar_porta_webpanel() {
    clear; ui_top; ui_titulo "MUDAR PORTA DO PAINEL"; ui_sep; ui_fila ""
    
    ui_fila "  ${BOLD}Porta atual:${NC} ${YELLOW}$WEBPANEL_PORT${NC}"
    ui_fila "  ${GRIS}URL atual: $(painel_url)${NC}"
    ui_fila ""
    ui_sep; ui_fila ""
    
    echo -ne "  ${WHITE}Nova porta (1-65535):${NC} "
    read -r new_port
    
    if ! [[ "$new_port" =~ ^[0-9]+$ ]]; then
        echo -e "  ${RED}✗ Deve ser um número${NC}"
        pause_return; return
    fi
    
    if [ "$new_port" -lt 1 ] || [ "$new_port" -gt 65535 ]; then
        echo -e "  ${RED}✗ A porta deve estar entre 1 e 65535${NC}"
        pause_return; return
    fi
    
    if [ "$new_port" -eq "$WEBPANEL_PORT" ]; then
        echo -e "  ${YELLOW}⚠ Essa é a porta atual${NC}"
        pause_return; return
    fi
    
    if ss -tuln | grep -q ":$new_port "; then
        echo -e "  ${RED}✗ A porta $new_port já está em uso por outro serviço${NC}"
        pause_return; return
    fi
    
    echo ""
    echo -ne "  ${YELLOW}⚠ Mudar a porta de $WEBPANEL_PORT para $new_port. Continuar? (s/n):${NC} "
    read -r confirm
    if [ "$confirm" != "s" ] && [ "$confirm" != "S" ]; then
        ui_info "Cancelado"
        pause_return; return
    fi
    
    local old_port=$WEBPANEL_PORT
    
    ui_info "Parando o Painel Web..."
    systemctl stop hex-webpanel.service 2>/dev/null
    
    ui_info "Atualizando configuração..."
    echo "$new_port" > "$WEBPANEL_PORT_FILE"
    chmod 644 "$WEBPANEL_PORT_FILE"
    
    ui_info "Atualizando firewall..."
    iptables -D INPUT -p tcp --dport $old_port -j ACCEPT 2>/dev/null
    iptables -I INPUT -p tcp --dport $new_port -j ACCEPT 2>/dev/null
    command -v ufw >/dev/null 2>&1 && {
        ufw delete allow $old_port/tcp >/dev/null 2>&1
        ufw allow $new_port/tcp >/dev/null 2>&1
    }
    fw_persistir
    
    ui_info "Reiniciando Painel Web..."
    systemctl start hex-webpanel.service
    sleep 2
    
    WEBPANEL_PORT=$new_port
    
    if systemctl is-active --quiet hex-webpanel.service; then
        ui_ok "Porta alterada com sucesso"
        ui_fila ""
        ui_fila "  ${BOLD}Nova porta:${NC}  ${YELLOW}$new_port${NC}"
        ui_fila "  ${BOLD}Nova URL:${NC}    ${CYAN}$(painel_url)${NC}"
        ui_fila ""
        ui_fila "  ${YELLOW}⚠ Use a nova URL para acessar o painel${NC}"
    else
        ui_error "O painel não pôde iniciar com a nova porta"
        ui_info "Restaurando a porta anterior..."
        echo "$old_port" > "$WEBPANEL_PORT_FILE"
        WEBPANEL_PORT=$old_port
        systemctl start hex-webpanel.service
    fi
    
    ui_fila ""; pause_return
}

# ═══════════════════════════════════════════════════════════════
#  MENU PRINCIPAL
# ═══════════════════════════════════════════════════════════════

