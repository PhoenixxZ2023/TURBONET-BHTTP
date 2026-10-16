# 🚀 MANAGER - Painel de Gerenciamento Completo

<div align="center">

![Version](https://img.shields.io/badge/version-1.2.0-00c853?style=for-the-badge&logo=github)
![Ubuntu](https://img.shields.io/badge/Ubuntu-22.04-E95420?style=for-the-badge&logo=ubuntu&logoColor=white)
![License](https://img.shields.io/badge/license-MIT-blue?style=for-the-badge)
![Bash](https://img.shields.io/badge/Bash-4EAA25?style=for-the-badge&logo=gnu-bash&logoColor=white)
![Python](https://img.shields.io/badge/Python-3776AB?style=for-the-badge&logo=python&logoColor=white)

**Sistema tudo-em-um para gerenciamento de serviços BHTTP, HCR, UDPGW e Painel Web**

[Instalação](#-instalação) • [Características](#-características) • [Documentação](#-documentação)

</div>

---

## 📖 Descrição

O **MANAGER** é um sistema completo de administração de servidores que permite gerenciar múltiplos serviços de túnel (BHTTP, HCR, UDPGW) com uma interface de terminal elegante e um **Painel Web moderno** com design glassmorphism. Inclui gerenciamento automático de usuários com expiração, limpeza programada e sistema de atualizações OTA diretamente pelo GitHub.

## ✨ Características

### 🖥️ Menu no Terminal
- ✅ Gerenciamento de **múltiplas portas** para BHTTP, HCR e UDPGW
- ✅ Criação de usuários do sistema com **expiração automática**
- ✅ **Limpeza automática** diária de usuários expirados (cron)
- ✅ Controle individual e em massa de serviços
- ✅ Visualização de logs em tempo real
- ✅ Desinstalação completa com um clique

### 🌐 Painel Web
- 🎨 Design moderno com **glassmorphism** e gradientes animados
- 📱 **100% Responsivo** (funciona em celulares e desktop)
- 🔐 Login seguro com autenticação
- 📊 Dashboard com indicadores **ONLINE/OFFLINE** animados
- 👥 Modal elegante para adicionar usuários
- 🎛️ Botões de Iniciar/Parar/Reiniciar por serviço
- ⚙️ Mudança da porta do painel direto pela interface

### 🔄 Sistema de Atualizações
- 🔍 Detecção automática de novas versões
- 📦 Atualização granular (menu, templates, backend)
- 💾 Backups automáticos antes de atualizar
- ✅ Validação de sintaxe antes de aplicar mudanças
- 📝 Changelog integrado

## 🎯 Requisitos

- **Sistema Operacional:** Ubuntu 22.04 ou superior
- **Permissões:** Root (sudo)
- **Arquitetura:** x86_64 (amd64) ou ARM64
- **Conexão:** Internet para a instalação inicial

## 🚀 Instalação

Copie e cole um dos comandos abaixo no seu terminal como root para iniciar a instalação.

**Instalação completa (recomendada):**
```bash
curl -sSL https://raw.githubusercontent.com/PhoenixxZ2023/TURBONET-BHTTP/main/install.sh | bash
````

### Método 2: Apenas Painel Web (se já tiver o sistema instalado):

```bash
curl -sSL https://raw.githubusercontent.com/PhoenixxZ2023/TURBONET-BHTTP/main/install_webpanel.sh | bash
```

### Método 3: Instalação manual (via git clone):

```bash
git clone https://github.com/PhoenixxZ2023/TURBONET-BHTTP.git
cd TURBONET-BHTTP
sudo bash install.sh
```

### Outros

```
wget -qO- https://raw.githubusercontent.com/PhoenixxZ2023/TURBONET-BHTTP/main/install.sh | bash
```

```
curl -sSL https://raw.githubusercontent.com/PhoenixxZ2023/TURBONET-BHTTP/main/install.sh | bash
```

---

## 🔐 Segurança (v1.1.0)

- **Senha do painel:** não existe mais senha padrão. No primeiro start o painel gera uma senha aleatória, mostrada no fim da instalação e guardada em `/etc/hex/webpanel_initial_password.txt` (apagada quando você troca a senha no dashboard).
- **HTTPS do painel (automático):** instalação nova já sai com HTTPS (certificado autoassinado criado sozinho). Para mudar depois: `hex_menu` → Painel Web → **8) Segurança do acesso** (ativar/desativar HTTPS, gerar novo certificado, restringir a 127.0.0.1). Também funciona pela linha de comando: `hex_panel_mode.sh https | http | local | external | status`. Nenhum arquivo precisa ser editado à mão; se a mudança fizer o painel parar de responder, ela é desfeita sozinha. O navegador avisa que o certificado não é conhecido (é autoassinado): *Avançado → Continuar*. Para pular o HTTPS na instalação: `HEX_INSTALL_HTTPS=0`.
- **UDPGW:** por padrão escuta só em `127.0.0.1` (use dentro do túnel SSH). Para expor publicamente: `HEX_UDPGW_PUBLIC=1 bash install.sh` (cria `/etc/hex/udpgw_public`).
- **Shell dos usuários:** por padrão **só túnel** (`nologin`). Para dar terminal a novos usuários: `hex_menu` → Gerenciar usuários → 7 (Tipo de acesso). Teste o DTunnel/HTTP Custom com um usuário novo antes de aplicar aos existentes.
- **CSRF:** todo POST exige token (`csrf_token` no formulário ou cabeçalho `X-CSRF-Token`); excluir/serviços/sair são POST, não links.
- **Integridade:** os instaladores e o OTA conferem o SHA256 de `version.json`. Para exigir isso sempre: `touch /etc/hex/require_checksum`.
- **Publicando uma versão:** na raiz do repo rode `./gen_version.sh 1.1.1 "resumo"` antes do commit; ele recalcula os SHA256 de todos os arquivos (inclusive binários).
- **IP da VPS (nuvem com NAT):** em Oracle, AWS, GCP e similares a placa de rede só tem IP *privado*; o IP público fica no roteador do provedor. O `hex_ip.sh` descobre o IPv4 público (na placa ou, se a VPS está atrás de NAT, consultando a internet; cache de 24 h) e é usado nas URLs, no resumo da instalação e na mensagem de usuário criado. Menu principal → **9) IP da VPS** para ver, redescobrir ou fixar o IP manualmente (`hex_ip.sh status | refresh | set <ipv4> | unset`). Para nunca consultar a internet: `HEX_NO_IP_LOOKUP=1`. **Atrás de NAT, libere também as portas no firewall do provedor** (Security List / Security Group); o instalador lista quais.
- **Instalação de pacotes (v1.1.4):** o instalador espera o `apt` quando ele está ocupado, repete em caso de falha, mostra o erro real do `apt` na tela e **nunca remove pacotes**. Ele **não instala mais o `ufw`** (o `ufw` remove o `netfilter-persistent`, que as imagens Ubuntu da Oracle usam para guardar o firewall). Se o `netfilter-persistent` existir, as regras abertas são gravadas com `netfilter-persistent save`; o `ufw` só é usado se já estiver ativo.
- **Esqueceu a senha do painel?** `hex_menu` → Painel Web → **9) Senha do painel**: mostra a senha inicial (enquanto você não a trocou), gera uma nova senha aleatória ou define a que você quiser. A senha só é guardada como hash, então depois de trocada não dá para "ver"; só redefinir. Redefinir também reinicia o painel e desconecta todas as sessões abertas. Linha de comando: `/opt/hex-webpanel/venv/bin/python /opt/hex-webpanel/app.py --reset-password`.
- **Serviços instalados, mas desativados (v1.1.7):** o instalador instala BHTTP, HCR e UDPGW **sem iniciar nem abrir nenhuma porta**. Quem ativa é você, pelo menu: `hex_menu` → **[1] Gerenciar BHTTP** (ou [2] HCR, [3] UDPGW) → **[7] Ativar BHTTP**. Na primeira ativação ele pergunta a porta (Enter aceita a sugerida: BHTTP 80, HCR 8080, UDPGW 7300), confere se a porta está livre, abre o firewall só dela, liga no boot e inicia. **Desativar** (mesma opção) para, desliga no boot e fecha o firewall, mantendo as portas na lista. O Painel Web fica ativo após a instalação (é por onde você administra) e também tem **Ativar/Desativar** (opção 10 do menu do painel). Reinstalar religa só o que já estava ativo. Atrás de NAT (Oracle e similares), libere a porta também no firewall do provedor; o menu avisa qual.
- **Sessão do painel expira por inatividade (v1.1.8):** sem mexer no painel por **3 minutos**, a sessão é encerrada e a senha é pedida de novo. Vale a atividade real (mouse, teclado, rolagem, toque); a atualização automática de fundo **não** conta. Uns 30 segundos antes aparece um aviso; mexer o mouse renova. A expiração é conferida no servidor, então não depende do navegador. Para mudar o tempo: `hex_menu` → Painel Web → 8 → **8) Tempo de inatividade** (mínimo de 1 min), ou `hex_panel_mode.sh idle 120`.
- **Domínio / subdomínio e Cloudflare (v1.1.8):** `hex_menu` → Painel Web → 8 → **6) Usar um domínio**, ou `hex_panel_mode.sh domain painel.seudominio.com`. O HTTPS é ativado junto e o certificado autoassinado já sai com o domínio. Na Cloudflare, crie um registro **A** `painel → IP da VPS`:
  - **Nuvem cinza (só DNS):** funciona com qualquer porta (`https://painel.seudominio.com:9000`). O navegador avisa do certificado autoassinado (Avançado → Continuar).
  - **Nuvem laranja (proxy):** a Cloudflare só repassa as portas HTTPS **443, 2053, 2083, 2087, 2096 e 8443** (a 9000 não passa). O menu detecta isso e oferece trocar a porta do painel para 8443. Em SSL/TLS use o modo **Full** (não "Flexible"; o "Full (strict)" recusa certificado autoassinado). O navegador mostra o certificado da Cloudflare, sem aviso.
  - O limite de tentativas de login passa a usar o IP real do visitante (`CF-Connecting-IP`), aceito só quando a conexão vem mesmo de IP da Cloudflare.

---

## 🧰 Para quem mantém o projeto (v1.2.0)

### Estrutura do repositório
- `src/hex_menu/*.sh`: o menu, dividido em módulos por assunto. `src/lib/`: código compartilhado (download verificado, apt, assinatura). `src/install*.sh.in`: os instaladores.
- `hex_menu.sh`, `install.sh` e `install_webpanel.sh` são **gerados**: edite em `src/` e rode **`bash build.sh`**. As VPS continuam baixando um arquivo só (o instalador roda por `curl | bash`, sem o repositório em disco). O CI recusa o commit se estiverem desatualizados (`bash build.sh --check`).
- `static/vendor/`: Bootstrap, ícones e fontes hospedados no painel (sem CDN). As licenças estão em `static/vendor/LICENSES.txt`.
- `tests/`: `pip install -r tests/requirements.txt && pytest`. Não precisam de root nem alteram a máquina (usam um "sistema falso" no lugar de `useradd`, `systemctl` etc.).

### Publicar uma versão
1. Edite `src/`, rode `./build.sh`, atualize o `CHANGELOG.md` (a primeira seção `## [x.y.z]` é a versão).
2. `bash gen_version.sh x.y.z "resumo"` gera o `version.json` (SHA256 de tudo, inclusive `static/`) e, havendo chave, assina.
3. `pytest` e `bash gen_version.sh --check` precisam passar. Faça commit.

> (Se algum script der "Permission denied", rode `chmod +x *.sh` uma vez, ou chame com `bash script.sh`.)

> Sem o passo 2, **toda instalação falha** com "SHA256 não confere". Por isso o CI roda `--check`.

### Assinatura das atualizações (opcional, recomendada)
O SHA256 sozinho não protege de quem controla o repositório (publicaria arquivo e hash novos). A assinatura (Ed25519, OpenSSL) fecha isso:
1. **Ative 2FA/passkey na conta do GitHub** e proteja a branch `main` (sem force push).
2. `bash sign_release.sh keygen`: cria a chave **privada** em `~/.hex-release/` (**fora do repositório**, faça cópia offline) e a **pública** em `keys/release_pub.pem`.
3. Publique a **impressão digital** (`bash sign_release.sh fingerprint`) em outro lugar além do repositório (README, perfil).
4. Daí em diante `bash gen_version.sh` assina (`version.json.sig`). Faça commit de `keys/release_pub.pem`, `version.json` e `version.json.sig`.

Nos servidores: a primeira instalação fixa a chave publicada e **mostra a impressão digital** para conferir (`hex_menu` → Atualizações → 6 também permite fixar/conferir). **Depois de fixada, atualização sem assinatura válida é recusada**, e o repositório não consegue trocar a chave. Limite honesto: na primeira instalação o servidor confia no que baixou; quem não confere a impressão digital continua dependendo do repositório. Recuperação: `HEX_ALLOW_UNSIGNED=1`.

### Binários no GitHub Releases (opcional)
Para o repositório não crescer a cada binário novo: coloque os binários em `dist/` (ignorado pelo git), rode `bash gen_version.sh` (o manifesto ganha `release_tag`), crie o release com esses arquivos (`gh release create v1.2.0 dist/* --notes ...`) e remova-os do git (`git rm bhttp-server-* hcr-server-*`). Os instaladores baixam do release e, se falhar, usam o arquivo do repositório; o SHA256 vale nos dois casos. Os `v2.4.0` não são usados por nenhum instalador.

- **Senha dos usuários VPN (v1.2.0):** o `users.txt` guarda só `usuario:validade`; a senha fica apenas no hash do sistema (`/etc/shadow`). Arquivos antigos (com senha em texto) são convertidos sozinhos na primeira execução. A lista de usuários do menu passou a mostrar o tipo de acesso (túnel/SHELL) no lugar do pedaço da senha.
- **Painel sem CDN (v1.2.0):** Bootstrap, ícones e fontes vêm do próprio painel, e uma política de segurança de conteúdo (CSP) impede carregar scripts, estilos ou fontes de outros sites.
