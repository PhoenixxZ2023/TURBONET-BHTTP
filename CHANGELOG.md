# Changelog

## [1.1.4] - 2026-10-08

### Corrigido
- Instalar o `ufw` fazia o `apt` **remover** `iptables-persistent` e `netfilter-persistent` (imagens Ubuntu da Oracle Cloud), perdendo a persistência do firewall. O `ufw` não é mais instalado; só é usado se já estiver ativo
- Regras de firewall abertas pelo instalador, pelo instalador do painel e pelo menu agora são gravadas com `netfilter-persistent save` quando ele existe (sobrevivem ao reboot)
- "Falha ao instalar dependências" não dizia o motivo. Agora o erro do `apt` aparece na tela

### Melhorado
- Passo de dependências: espera o bloqueio do `apt`/`dpkg` (até 10 min), tenta `apt-get update` 3 vezes, repara `dpkg` interrompido, usa `--no-remove`, separa pacotes essenciais, opcionais e de compilação
- Sem ferramentas de compilação, só o UDPGW é ignorado (BHTTP e HCR continuam); antes a instalação inteira abortava
- Verifica a existência do `systemctl` antes de começar

## [1.1.3] - 2026-10-07

### Corrigido
- O instalador, o menu e o painel mostravam o IP **privado** da VPS (`hostname -I | awk '{print $1}'`), ou até um IPv6, em VPS de nuvem atrás de NAT. Isso levava o usuário a configurar o cliente VPN e o navegador com o IP errado. Agora tudo usa o IPv4 público
- Certificado HTTPS do painel passa a incluir o IP público no SAN

### Adicionado
- `hex_ip.sh`: descobre o IPv4 público (placa de rede, ou internet se houver NAT), com cache de 24 h, IP manual (`set`/`unset`) e detecção de NAT; só IPv4
- Menu principal: linha "IP DA VPS" e opção 9 (ver, redescobrir, definir manualmente)
- Resumo da instalação avisa quando a VPS está atrás de NAT e lista as portas que precisam ser liberadas também no firewall do provedor
- O OTA também atualiza o `hex_ip.sh`

## [1.1.2] - 2026-10-07

### Adicionado
- `hex_panel_mode.sh`: muda o modo de acesso do painel sem editar arquivos (HTTPS, HTTP, somente local, externo, status). Gera o certificado sozinho, reinicia, confere se o painel responde e desfaz a mudança se não responder
- HTTPS nativo no painel (servidor cheroot, TLS 1.2+); cookie de sessão fica `Secure` no modo HTTPS; sem HSTS (certificado autoassinado)
- Menu: Painel Web → 8) Segurança do acesso (HTTPS)
- Instalação nova do painel já sai com HTTPS ligado (`HEX_INSTALL_HTTPS=0` para pular); instalações existentes continuam como estão até você mudar pelo menu
- O menu e a URL mostrada nos instaladores respeitam http/https; o OTA também atualiza o `hex_panel_mode.sh`

## [1.1.1] - 2026-10-07

### Segurança
- Ações que alteram estado agora são POST (antes eram links GET): excluir usuário, iniciar/parar/reiniciar serviços e sair
- Token CSRF obrigatório em todo POST (formulários, ações do painel, login e `/update_now` via cabeçalho `X-CSRF-Token`); o token é trocado a cada login
- GET nessas rotas retorna 405; requisição sem token/sessão expirada retorna 403 com mensagem clara
- dashboard.html e login.html atualizados (token nos formulários e função `postAction` para os botões)

## [1.1.0] - 2026-10-07

### Segurança
- secret_key do painel agora é aleatória e persistente (antes era fixa e pública: permitia forjar o cookie de login)
- Sem senha padrão: senha inicial aleatória; bcrypt com custo 12; limite de tentativas de login (5 por IP, bloqueio de 15 min)
- Cookie de sessão HttpOnly + SameSite=Strict e checagem de Origin (proteção CSRF)
- Rotas de usuário só operam em contas gerenciadas (users.txt); validação de usuário, senha e datas
- Gravação atômica e travada de users.txt; senhas com `/`, `&` e `\` não corrompem mais o arquivo
- OTA e instaladores verificam SHA256 (version.json) e usam arquivos temporários privados
- Instalador baixa do próprio repositório (antes apontava para rogellevi/HCR_BHTTP)
- UDPGW escuta em 127.0.0.1 por padrão; badvpn compilado de tag fixa (1.999.130)
- Serviços systemd com hardening básico

### Corrigido
- Dashboard retornava erro 500: o app.py não enviava `system_stats` (CPU/RAM/disco) esperado pelo template
- install.sh deixava o painel web como stub (sem app.py nem bcrypt); agora instala de verdade
- install_webpanel.sh embutia um app.py antigo e inseguro; agora baixa o app.py do repositório
- Limpeza automática apagava usuários com ':' na senha ou data inválida; agora só remove contas do grupo hexusers com data válida e vencida
- /etc/hex/version passa a ser gravado na instalação

## [1.0.1] - 2026-10-04

### Adicionado
- Painel Web moderno com design glassmorphism
- Modal elegante para adicionar usuários
- Suporte para múltiplas portas no BHTTP, HCR e UDPGW
- Sistema de atualização automática
- Limpeza automática de usuários expirados

### Melhorado
- Dashboard responsivo para dispositivos móveis
- Backend com caminhos absolutos (compatível com systemd)
- Validações melhoradas na criação de usuários
- Logs detalhados de todas as ações

### Corrigido
- Erro ao criar usuários com senhas contendo caracteres especiais
- Botões de controle de serviços não funcionavam
- Design visual em telas pequenas

---

## [1.0.0] - 2026-10-02

### Adicionado
- Painel Web básico
- Gerenciamento de usuários com expiração

### Corrigido
- Erros de sintaxe na instalação
