# Changelog

## [1.1.8] - 2026-10-10

### Segurança
- **A sessão do painel agora expira por inatividade** (padrão 3 min; antes nunca expirava). A atividade vem do que a pessoa faz (mouse, teclado, rolagem, toque) por um aviso ao servidor (`/api/ping`); a atualização automática (`/api/stats`) não conta. O servidor confere o prazo em toda requisição (um cookie antigo é recusado mesmo com assinatura válida); o navegador avisa 30 s antes e encerra a sessão no prazo
- Ações com sessão expirada vão para o login e não são executadas; chamadas de API recebem 401
- Tempo configurável: `HEX_SESSION_IDLE_SECONDS` (30 a 86400 s) ou `hex_panel_mode.sh idle <segundos>` / menu

### Adicionado
- **Domínio/subdomínio para o painel**, com HTTPS e certificado autoassinado que já inclui o domínio: `hex_panel_mode.sh domain <dominio>` e menu Painel Web → 8 → 6/7. Detecta se o DNS aponta direto para a VPS (nuvem cinza), passa pela Cloudflare (nuvem laranja), aponta para outro IP ou não resolve, e orienta o ajuste. Com proxy da Cloudflare confere a porta (443, 2053, 2083, 2087, 2096, 8443) e oferece mudar para 8443, com reversão automática se o painel não subir
- IP real do visitante atrás da Cloudflare (`CF-Connecting-IP`) para o limite de tentativas de login e os logs, aceito só de IPs da Cloudflare (o cabeçalho não pode ser forjado de fora). `HEX_TRUST_CLOUDFLARE=0` desliga
- Menu Painel Web → 8: opções 6 (domínio), 7 (remover domínio) e 8 (tempo de inatividade)

### Observação
- A "atualização automática" do dashboard (a cada 30 s) só consulta `/api/stats` e descarta a resposta; ela não atualiza os números na tela. Isso já era assim e não foi alterado

## [1.1.7] - 2026-10-10

### Alterado
- **O instalador não ativa mais BHTTP, HCR e UDPGW.** Eles ficam instalados e desativados: nenhum serviço é iniciado, nenhuma porta é aberta no firewall e as listas de portas começam vazias
- O resumo da instalação mostra "DESATIVADO (instalado)", o caminho do menu para ativar e as portas sugeridas (BHTTP 80/8880, HCR 8080, UDPGW 7300), com lembrete do firewall do provedor quando a VPS está atrás de NAT
- **Reinstalar/atualizar religa só o que já estava ativo ou habilitado antes** e não sobrescreve as listas de portas

### Adicionado
- Menu de cada serviço (BHTTP, HCR, UDPGW): **opção 7 Ativar / Desativar**. Ativar pergunta a porta (padrão sugerido), verifica se está livre (mostra o processo que a usa), abre o firewall só dela, habilita no boot e inicia. Desativar para, desabilita e fecha o firewall, mantendo as portas na lista
- Menu do Painel Web: **opção 10 Ativar / Desativar** (habilita/desabilita, abre/fecha a porta, recusa se a porta estiver em uso)
- Tela de cada serviço mostra "Serviço: ● ATIVADO / ○ DESATIVADO"; o menu principal mostra "○ DESATIVADO" em vez de "SEM PORTAS"

### Observação
- Instalações existentes não mudam sozinhas: os serviços já ativos continuam como estão; só ganham a nova opção 7 ao atualizar o menu

## [1.1.6] - 2026-10-09

### Corrigido
- O `dashboard.html` estava **em espanhol** (declarava `lang="es"`), então o Chrome oferecia traduzir e deformava termos, por exemplo "RAM" virava "BATER" e o selo "2/3" do UDPGW podia sair errado. A interface agora está inteira em português do Brasil: textos, botões, modais, confirmações, avisos e mensagens da atualização
- `<html lang="pt-BR">` e `<meta name="google" content="notranslate">` no dashboard e no login, para o navegador não traduzir de novo
- O formulário de troca da senha do **admin** pedia mínimo de 4 caracteres, mas o servidor exige 8; o formulário agora exige e informa 8 (a senha de usuário VPN continua com mínimo de 4)

### Observação
- Só texto mudou: IDs, classes, rotas, funções JavaScript e expressões Jinja do template são idênticos aos da versão anterior (conferido por comparação automática)

## [1.1.5] - 2026-10-09

### Adicionado
- Menu: Painel Web → 9) Senha do painel: ver a senha inicial (se ainda não foi trocada), gerar nova senha aleatória ou definir a própria
- `app.py --reset-password` e `--set-password` (a senha vai por stdin, não aparece na lista de processos). Redefinir troca a secret_key e desconecta todas as sessões abertas; o menu reinicia o painel (isso também zera bloqueios de login por tentativas)
- O resumo da instalação do painel avisa onde recuperar a senha

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
