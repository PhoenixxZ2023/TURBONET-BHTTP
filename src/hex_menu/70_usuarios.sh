gerenciar_usuarios() {
    while true; do
        clear; ui_top; ui_titulo "GERENCIAMENTO DE USUÁRIOS"; ui_sep; ui_fila ""
        
        total_users=$(wc -l < "$USER_DB" 2>/dev/null || echo "0")
        active_count=0
        expired_count=0
        current_timestamp=$(date +%s)
        
        while IFS= read -r _linha; do
        user=${_linha%%:*}; exp=${_linha##*:}
            [ -z "$user" ] && continue
            exp_timestamp=$(date -d "$exp" +%s 2>/dev/null || echo "0")
            if [ "$exp_timestamp" -lt "$current_timestamp" ]; then
                ((expired_count++))
            else
                ((active_count++))
            fi
        done < "$USER_DB"
        
        ui_fila "  ${BOLD}Total de usuários:${NC} ${YELLOW}$total_users${NC}  │  ${GREEN}Ativos: $active_count${NC}  │  ${RED}Expirados: $expired_count${NC}"
        ui_fila ""
        ui_sep
        
        ui_opcion "1" "Adicionar usuário"
        ui_opcion "2" "Remover usuário"
        ui_opcion "3" "Listar usuários ativos"
        ui_opcion "4" "Limpeza automática"
        ui_opcion "5" "Mudar senha de usuário"
        ui_opcion "6" "Mudar data de expiração"
        ui_opcion "7" "Tipo de acesso (túnel / shell)"
        ui_opcion "0" "Voltar"
        
        ui_bot; echo ""
        echo -ne "  ${CYAN}►${NC} Selecione a opção: "; read -r opt
        
        case "$opt" in
            1) adicionar_usuario ;;
            2) remover_usuario ;;
            3) listar_usuarios ;;
            4) gerenciar_limpeza ;;
            5) mudar_senha_usuario ;;
            6) mudar_expiracao_usuario ;;
            7) menu_tipo_acesso ;;
            0) break ;;
            *) echo -e "  ${RED}✗ Opção inválida${NC}"; pause_return ;;
        esac
    done
    menu_principal
}

menu_tipo_acesso() {
    local opt sh c n=0 u
    while true; do
        sh=$(shell_padrao_novos)
        clear; ui_top; ui_titulo "TIPO DE ACESSO DOS USUÁRIOS"; ui_sep; ui_fila ""
        case "$sh" in
            */nologin|*/false) ui_fila "  Novos usuários: ${GREEN}SÓ TÚNEL${NC} ${GRIS}($sh)${NC} - sem terminal na VPS" ;;
            *) ui_fila "  Novos usuários: ${YELLOW}COM SHELL${NC} ${GRIS}($sh)${NC} - acesso a terminal na VPS" ;;
        esac
        ui_fila ""; ui_fila "  ${GRIS}Contas só de túnel conectam normalmente pelo DTunnel/HTTP Custom na maioria dos casos;${NC}"
        ui_fila "  ${GRIS}teste com um usuário novo antes de aplicar aos existentes.${NC}"
        ui_fila ""; ui_sep; ui_fila ""
        ui_opcion "1" "Novos usuários SÓ TÚNEL ${GREEN}(recomendado)${NC}"
        ui_opcion "2" "Novos usuários COM SHELL (bash)"
        ui_opcion "3" "Aplicar o tipo atual a TODOS os usuários existentes"
        ui_opcion "0" "Voltar"
        ui_bot; echo ""; echo -ne "  ${CYAN}►${NC} Selecione a opção: "; read -r opt
        case "$opt" in
            1) if [ -x /usr/sbin/nologin ]; then echo /usr/sbin/nologin > /etc/hex/user_shell; else echo /bin/false > /etc/hex/user_shell; fi
               chmod 644 /etc/hex/user_shell; echo -e "  ${GREEN}✓ Novos usuários: só túnel${NC}"; pause_return ;;
            2) echo /bin/bash > /etc/hex/user_shell; chmod 644 /etc/hex/user_shell
               echo -e "  ${GREEN}✓ Novos usuários: com shell${NC}"; pause_return ;;
            3) echo -ne "  ${YELLOW}Trocar o shell de TODOS os usuários para $sh? Quem estiver usando terminal será afetado. (s/n):${NC} "; read -r c
               if [ "$c" = "s" ] || [ "$c" = "S" ]; then
                   while IFS= read -r _linha; do
                       u=${_linha%%:*}; [ -z "$u" ] && continue
                       id "$u" >/dev/null 2>&1 && usermod -s "$sh" "$u" 2>/dev/null && n=$((n+1))
                   done < "$USER_DB"
                   echo -e "  ${GREEN}✓ $n usuário(s) atualizado(s)${NC}"
               fi; pause_return ;;
            0) return ;;
            *) echo -e "  ${RED}✗ Opção inválida${NC}"; pause_return ;;
        esac
    done
}

adicionar_usuario() {
    clear; ui_top; ui_titulo "ADICIONAR USUÁRIO"; ui_sep
    getent group "$USER_GROUP" >/dev/null 2>&1 || groupadd "$USER_GROUP" 2>/dev/null
    echo ""; echo -ne "  ${WHITE}Usuário:${NC} "; read -r new_user
    valid_username "$new_user" || { echo -e "  ${RED}✗ Nome inválido (minúsculas, números, _ e -)${NC}"; pause_return; return; }
    id "$new_user" >/dev/null 2>&1 && { echo -e "  ${RED}✗ Já existe${NC}"; pause_return; return; }
    echo -ne "  ${WHITE}Senha:${NC} "; read -rs new_pass; echo ""
    valid_user_password "$new_pass" || { echo -e "  ${RED}✗ Senha inválida (4 a 64 caracteres, sem ':')${NC}"; pause_return; return; }
    echo -ne "  ${WHITE}Validade (dias):${NC} "; read -r days
    [[ "$days" =~ ^[0-9]+$ ]] && [ "$days" -gt 0 ] && [ "$days" -le 3650 ] || { echo -e "  ${RED}✗ Inválido (1 a 3650)${NC}"; pause_return; return; }

    exp_date=$(date -d "+${days} days" +"%Y-%m-%d")
    user_shell=$(shell_padrao_novos)
    if ! useradd -m -s "$user_shell" -G "$USER_GROUP" "$new_user" 2>/dev/null; then
        echo -e "  ${RED}✗ Erro ao criar o usuário${NC}"; pause_return; return
    fi
    if ! printf '%s:%s\n' "$new_user" "$new_pass" | chpasswd 2>/dev/null; then
        userdel -r "$new_user" 2>/dev/null
        echo -e "  ${RED}✗ Erro ao definir a senha${NC}"; pause_return; return
    fi
    chage -E "$exp_date" "$new_user" && usermod -e "$exp_date" "$new_user"
    ( db_lock; printf '%s:%s\n' "$new_user" "$exp_date" >> "$USER_DB" )

    echo ""; echo -e "  ${GREEN}✓ Usuário criado${NC}"
    echo -e "  ${BOLD}IP:${NC} $(ip_publico)"
    echo -e "  ${BOLD}Usuário:${NC} ${YELLOW}${new_user}${NC} | ${BOLD}Senha:${NC} ${YELLOW}${new_pass}${NC} | ${BOLD}Expira em:${NC} ${YELLOW}${exp_date}${NC}"; echo ""
    pause_return
}

remover_usuario() {
    clear; ui_top; ui_titulo "REMOVER USUÁRIO"; ui_sep
    [ ! -s "$USER_DB" ] && { echo -e "  ${YELLOW}Não há usuários${NC}"; pause_return; return; }
    echo ""; echo -e "  ${CYAN}Usuários ativos:${NC}"; echo ""
    cat -n "$USER_DB" | awk -F: '{printf "    ${YELLOW}[%s]${NC} %s (Exp: %s)\n", NR, $1, $NF}' | sed "s/\${YELLOW}/\x1b[38;5;221m/g; s/\${NC}/\x1b[0m/g"; echo ""
    echo -ne "  ${WHITE}Usuário a remover:${NC} "; read -r del_user
    valid_username "$del_user" && db_has "$del_user" || { echo -e "  ${RED}✗ Não é um usuário gerenciado por este menu${NC}"; pause_return; return; }
    pkill -KILL -u "$del_user" 2>/dev/null
    userdel -r "$del_user" 2>/dev/null
    if id "$del_user" >/dev/null 2>&1; then
        echo -e "  ${RED}✗ Não foi possível remover o usuário do sistema${NC}"; pause_return; return
    fi
    ( db_lock; db_update "$del_user" delete )
    echo -e "  ${GREEN}✓ Usuário removido${NC}"; pause_return
}

listar_usuarios() {
    clear; ui_top; ui_titulo "USUÁRIOS ATIVOS"; ui_sep
    [ ! -s "$USER_DB" ] && { echo ""; echo -e "  ${YELLOW}⚠ Não há usuários${NC}"; ui_sep; ui_fila ""; ui_fila "  ${GRIS}Use a opção 1 para adicionar${NC}"; ui_fila ""; pause_return; return; }
    
    total_users=$(wc -l < "$USER_DB"); active_users=0; expired_users=0; expiring_soon=0
    current_timestamp=$(date +%s)
    
    echo ""; echo -e "  ${CYAN}╔═══════════════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "  ${CYAN}║${NC} ${WHITE}${BOLD}#   Usuário          Acesso          Expira          Dias Rest.  Estado${NC}          ${CYAN}║${NC}"
    echo -e "  ${CYAN}╠═══════════════════════════════════════════════════════════════════════════════╣${NC}"
    
    counter=1
    while IFS= read -r _linha; do
        user=${_linha%%:*}; exp=${_linha##*:}
        if id "$user" >/dev/null 2>&1; then
            exp_timestamp=$(date -d "$exp" +%s 2>/dev/null || echo "0")
            days_left=$(( (exp_timestamp - current_timestamp) / 86400 ))
            
            if [ "$exp_timestamp" -lt "$current_timestamp" ]; then
                status="${RED}● EXPIRADO${NC}"; days_color="${RED}"; ((expired_users++))
            elif [ "$days_left" -le 3 ]; then
                status="${YELLOW}● PRESTES A EXPIRAR${NC}"; days_color="${YELLOW}"; ((expiring_soon++))
            else
                status="${GREEN}● ATIVO${NC}"; days_color="${GREEN}"; ((active_users++))
            fi
            
            case "$(getent passwd "$user" | cut -d: -f7)" in */nologin|*/false) acesso="túnel" ;; *) acesso="SHELL" ;; esac
            printf "  ${CYAN}║${NC} ${YELLOW}%-3s${NC} ${WHITE}%-16s${NC} ${GRIS}%-15s${NC} ${WHITE}%-15s${NC} ${days_color}%-11s${NC} %b\n" "$counter" "$user" "$acesso" "$exp" "$days_left" "$status"
            ((counter++))
        fi
    done < "$USER_DB"
    
    echo -e "  ${CYAN}╚═══════════════════════════════════════════════════════════════════════════════╝${NC}"; echo ""
    ui_sep; echo ""
    echo -e "  ${BOLD}RESUMO:${NC}"; echo -e "  Total: ${WHITE}$total_users${NC} | Ativos: ${GREEN}$active_users${NC} | Prestes a expirar: ${YELLOW}$expiring_soon${NC} | Expirados: ${RED}$expired_users${NC}"; echo ""
    ui_sep; ui_fila ""; pause_return
}

gerenciar_limpeza() {
    clear; ui_top; ui_titulo "LIMPEZA AUTOMÁTICA"; ui_sep; ui_fila ""
    cron_active=$(crontab -l 2>/dev/null | grep -c "hex_cleanup.sh")
    
    if [ "$cron_active" -gt 0 ]; then
        ui_fila "  Estado: ${GREEN}● ATIVO${NC}"; ui_fila "  ${GRIS}Diariamente às 03:00 AM${NC}"; ui_fila ""
        ui_sep; ui_fila ""
        ui_opcion "1" "Desativar limpeza"; ui_opcion "2" "Executar AGORA"; ui_opcion "3" "Ver log"; ui_opcion "0" "Voltar"
        ui_bot; echo ""; echo -ne "  ${CYAN}►${NC} Opção: "; read -r opt
        case "$opt" in
            1) crontab -l 2>/dev/null | grep -v "hex_cleanup.sh" | crontab -; echo -e "  ${GREEN}✓ Desativada${NC}"; pause_return ;;
            2) $CLEANUP_SCRIPT; echo -e "  ${GREEN}✓ Concluída${NC}"; pause_return ;;
            3) [ -f "$CLEANUP_LOG" ] && tail -50 "$CLEANUP_LOG" | less || { echo -e "  ${YELLOW}Sem log${NC}"; pause_return; } ;;
            0) ;; *) echo -e "  ${RED}✗ Inválida${NC}"; pause_return ;;
        esac
    else
        ui_fila "  Estado: ${RED}● INATIVO${NC}"; ui_fila ""
        ui_sep; ui_fila ""
        ui_opcion "1" "Ativar limpeza"; ui_opcion "2" "Executar AGORA"; ui_opcion "3" "Ver log"; ui_opcion "0" "Voltar"
        ui_bot; echo ""; echo -ne "  ${CYAN}►${NC} Opção: "; read -r opt
        case "$opt" in
            1) (crontab -l 2>/dev/null; echo "0 3 * * * $CLEANUP_SCRIPT") | crontab -; echo -e "  ${GREEN}✓ Ativada${NC}"; pause_return ;;
            2) $CLEANUP_SCRIPT; echo -e "  ${GREEN}✓ Concluída${NC}"; pause_return ;;
            3) [ -f "$CLEANUP_LOG" ] && tail -50 "$CLEANUP_LOG" | less || { echo -e "  ${YELLOW}Sem log${NC}"; pause_return; } ;;
            0) ;; *) echo -e "  ${RED}✗ Inválida${NC}"; pause_return ;;
        esac
    fi
}

mudar_senha_usuario() {
    clear; ui_top; ui_titulo "MUDAR SENHA DE USUÁRIO"; ui_sep
    
    [ ! -s "$USER_DB" ] && { echo -e "  ${YELLOW}Não há usuários registrados${NC}"; pause_return; return; }
    
    echo ""; echo -e "  ${CYAN}Usuários disponíveis:${NC}"; echo ""
    counter=1
    while IFS= read -r _linha; do
        user=${_linha%%:*}; exp=${_linha##*:}
        [ -z "$user" ] && continue
        if id "$user" >/dev/null 2>&1; then
            printf "    ${YELLOW}[%s]${NC} ${WHITE}%s${NC}  ${GRIS}(Exp: %s)${NC}\n" "$counter" "$user" "$exp"
            ((counter++))
        fi
    done < "$USER_DB"
    echo ""
    
    echo -ne "  ${WHITE}Usuário a modificar:${NC} "
    read -r target_user
    
    if ! valid_username "$target_user" || ! id "$target_user" >/dev/null 2>&1; then
        echo -e "  ${RED}✗ O usuário '$target_user' não existe no sistema${NC}"
        pause_return; return
    fi
    
    if ! db_has "$target_user"; then
        echo -e "  ${RED}✗ O usuário '$target_user' não está no banco de dados${NC}"
        pause_return; return
    fi
    
    echo -ne "  ${WHITE}Nova senha:${NC} "
    read -rs new_pass; echo ""
    
    if [ -z "$new_pass" ]; then
        echo -e "  ${RED}✗ A senha não pode estar vazia${NC}"
        pause_return; return
    fi
    
    echo -ne "  ${WHITE}Confirmar nova senha:${NC} "
    read -rs confirm_pass; echo ""
    
    if [ "$new_pass" != "$confirm_pass" ]; then
        echo -e "  ${RED}✗ As senhas não coincidem${NC}"
        pause_return; return
    fi
    
    if ! valid_user_password "$new_pass"; then
        echo -e "  ${RED}✗ Senha inválida (4 a 64 caracteres, sem ':')${NC}"; pause_return; return
    fi
    if printf '%s:%s\n' "$target_user" "$new_pass" | chpasswd 2>/dev/null; then
        echo -e "  ${GREEN}✓ Senha de '$target_user' alterada com sucesso${NC}"
        echo -e "  ${GRIS}O usuário pode acessar com a nova senha${NC}"
    else
        echo -e "  ${RED}✗ Erro ao alterar a senha${NC}"
    fi
    
    pause_return
}

mudar_expiracao_usuario() {
    clear; ui_top; ui_titulo "MUDAR DATA DE EXPIRAÇÃO"; ui_sep
    
    [ ! -s "$USER_DB" ] && { echo -e "  ${YELLOW}Não há usuários registrados${NC}"; pause_return; return; }
    
    echo ""; echo -e "  ${CYAN}Usuários disponíveis:${NC}"; echo ""
    current_timestamp=$(date +%s)
    counter=1
    
    while IFS= read -r _linha; do
        user=${_linha%%:*}; exp=${_linha##*:}
        [ -z "$user" ] && continue
        if id "$user" >/dev/null 2>&1; then
            exp_timestamp=$(date -d "$exp" +%s 2>/dev/null || echo "0")
            days_left=$(( (exp_timestamp - current_timestamp) / 86400 ))
            
            if [ "$exp_timestamp" -lt "$current_timestamp" ]; then
                status="${RED}● EXPIRADO${NC}"
            elif [ "$days_left" -le 3 ]; then
                status="${YELLOW}● $days_left dias${NC}"
            else
                status="${GREEN}● $days_left dias${NC}"
            fi
            
            printf "    ${YELLOW}[%s]${NC} ${WHITE}%-15s${NC}  ${GRIS}Exp: %s${NC}  %b\n" "$counter" "$user" "$exp" "$status"
            ((counter++))
        fi
    done < "$USER_DB"
    echo ""
    
    echo -ne "  ${WHITE}Usuário a modificar:${NC} "
    read -r target_user
    
    if ! valid_username "$target_user" || ! id "$target_user" >/dev/null 2>&1; then
        echo -e "  ${RED}✗ O usuário '$target_user' não existe no sistema${NC}"
        pause_return; return
    fi
    
    if ! db_has "$target_user"; then
        echo -e "  ${RED}✗ O usuário '$target_user' não está no banco de dados${NC}"
        pause_return; return
    fi
    
    current_exp=$(awk -F':' -v u="$target_user" '$1==u{print $NF}' "$USER_DB")
    echo ""
    echo -e "  ${BOLD}Data atual de expiração:${NC} ${YELLOW}$current_exp${NC}"
    echo ""
    
    ui_opcion "1" "Estender 7 dias"
    ui_opcion "2" "Estender 15 dias"
    ui_opcion "3" "Estender 30 dias"
    ui_opcion "4" "Estender 60 dias"
    ui_opcion "5" "Estender 90 dias"
    ui_opcion "6" "Data personalizada"
    ui_opcion "7" "Remover expiração (permanente)"
    ui_opcion "0" "Cancelar"
    
    echo ""
    echo -ne "  ${CYAN}►${NC} Opção: "; read -r opt
    
    case "$opt" in
        1) days_to_add=7 ;;
        2) days_to_add=15 ;;
        3) days_to_add=30 ;;
        4) days_to_add=60 ;;
        5) days_to_add=90 ;;
        6)
            echo -ne "  ${WHITE}Nova data (YYYY-MM-DD):${NC} "
            read -r custom_date
            if ! [[ "$custom_date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || ! date -d "$custom_date" >/dev/null 2>&1; then
                echo -e "  ${RED}✗ Formato inválido. Use YYYY-MM-DD${NC}"
                pause_return; return
            fi
            new_exp="$custom_date"
            ;;
        7)
            if chage -E -1 "$target_user" 2>/dev/null && usermod -e '' "$target_user" 2>/dev/null; then
                new_exp="2099-12-31"
                ( db_lock; db_update "$target_user" exp "$new_exp" )
                echo -e "  ${GREEN}✓ Expiração removida. O usuário '$target_user' agora é permanente${NC}"
            else
                echo -e "  ${RED}✗ Erro ao remover a expiração${NC}"
            fi
            pause_return; return
            ;;
        0) return ;;
        *) echo -e "  ${RED}✗ Opção inválida${NC}"; pause_return; return ;;
    esac
    
    if [ -n "$days_to_add" ]; then
        exp_timestamp=$(date -d "$current_exp" +%s 2>/dev/null || echo "0")
        if [ "$exp_timestamp" -lt "$current_timestamp" ]; then
            new_exp=$(date -d "+${days_to_add} days" +"%Y-%m-%d")
        else
            new_exp=$(date -d "$current_exp + $days_to_add days" +"%Y-%m-%d")
        fi
    fi
    
    if chage -E "$new_exp" "$target_user" 2>/dev/null && usermod -e "$new_exp" "$target_user" 2>/dev/null; then
        ( db_lock; db_update "$target_user" exp "$new_exp" )
        echo ""
        echo -e "  ${GREEN}✓ Data de expiração atualizada${NC}"
        echo -e "  ${BOLD}Usuário:${NC}    ${YELLOW}$target_user${NC}"
        echo -e "  ${BOLD}Antes:${NC}      ${RED}$current_exp${NC}"
        echo -e "  ${BOLD}Agora:${NC}      ${GREEN}$new_exp${NC}"
    else
        echo -e "  ${RED}✗ Erro ao atualizar a data de expiração${NC}"
    fi
    
    pause_return
}

