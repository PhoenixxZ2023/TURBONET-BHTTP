# 🚀 MANAGER - Painel de Gerenciamento Completo

<div align="center">

![Version](https://img.shields.io/badge/version-3.1.2-00c853?style=for-the-badge&logo=github)
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
curl -sSL [https://raw.githubusercontent.com/PhoenixxZ2023/TURBONET-BHTTP/main/install.sh](https://raw.githubusercontent.com/PhoenixxZ2023/TURBONET-BHTTP/main/install.sh) | bash
````

### Método 2: Solo Panel Web (si ya tienes el sistema instalado)

```bash
curl -sSL https://raw.githubusercontent.com/rogellevi/HCR_BHTTP/main/install_webpanel.sh | bash
```

### Método 3: Instalación manual

```bash
git clone https://github.com/rogellevi/HCR_BHTTP.git
cd HCR_BHTTP
sudo bash install.sh
```

### Otros

```
wget -qO- https://raw.githubusercontent.com/rogellevi/HCR_BHTTP/main/install.sh | bash
```

```
curl -sSL https://raw.githubusercontent.com/rogellevi/HCR_BHTTP/main/install.sh | bash
```
