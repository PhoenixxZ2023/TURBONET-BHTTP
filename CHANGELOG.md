# Changelog

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
