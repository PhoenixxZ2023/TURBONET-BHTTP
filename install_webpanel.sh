#!/bin/bash

# ═══════════════════════════════════════════════════════════════
#  PAINEL WEB - INSTALADOR AUTOMÁTICO
#  Repositório: https://github.com/PhoenixxZ2023/TURBONET-BHTTP
# ═══════════════════════════════════════════════════════════════

set -o pipefail
export DEBIAN_FRONTEND=noninteractive

RED='\033[38;5;203m'; GREEN='\033[38;5;84m'; YELLOW='\033[38;5;221m'
CYAN='\033[38;5;51m'; WHITE='\033[38;5;255m'; NC='\033[0m'
BOLD='\033[1m'; ACC='\033[38;5;44m'

PANEL_DIR="/opt/hex-webpanel"
PANEL_PORT=9000
ADMIN_PASS="admin26"

ui_top() { echo -e "${ACC} ════════════════════════════════════════════════════════════${NC}"; }
ui_sep() { echo -e "${ACC}════════════════════════════════════════════════════════════${NC}"; }
ui_bot() { echo -e "${ACC}════════════════════════════════════════════════════════════${NC}"; }
ui_fila() { echo -e "${ACC}║${NC} $1 ${ACC}║${NC}"; }
ui_titulo() { printf "${ACC}║${NC}                      ${WHITE}${BOLD}%s${NC}                      ${ACC}║${NC}\n" "$1"; }
ui_ok() { echo -e "     ${GREEN}✓${NC} ${WHITE}$1${NC}"; }
ui_error() { echo -e "     ${RED}✗${NC} ${RED}$1${NC}"; }
ui_info() { echo -e "     ${CYAN}ℹ${NC} $1${NC}"; }

verificar_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}✗ Este script requer permissões de root${NC}"
        exit 1
    fi
}

instalar_dependencias() {
    clear; ui_top; ui_titulo "1/5 INSTALANDO DEPENDÊNCIAS"; ui_sep; ui_fila ""
    ui_info "Atualizando repositórios..."
    apt-get update -y >/dev/null 2>&1
    ui_info "Instalando Python3 e ferramentas..."
    apt-get install -y python3 python3-pip python3-venv >/dev/null 2>&1
    ui_ok "Dependências instaladas"; ui_fila ""; sleep 1
}

criar_estrutura() {
    clear; ui_top; ui_titulo "2/5 CRIANDO ESTRUTURA"; ui_sep; ui_fila ""
    ui_info "Criando diretórios..."
    mkdir -p "$PANEL_DIR/templates"
    cd "$PANEL_DIR" || exit 1

    ui_info "Criando ambiente virtual do Python..."
    python3 -m venv venv >/dev/null 2>&1
    source venv/bin/activate

    ui_info "Instalando Flask e dependências..."
    pip install flask flask-login psutil bcrypt >/dev/null 2>&1
    ui_ok "Ambiente configurado"; ui_fila ""; sleep 1
}

criar_app() {
    clear; ui_top; ui_titulo "3/5 CRIANDO APLICATIVO"; ui_sep; ui_fila ""
    ui_info "Criando arquivo app.py..."

    # IMPORTANTE: Usar <<'EOF_APP' (com aspas simples) para evitar a expansão de variáveis
    cat > "$PANEL_DIR/app.py" <<'EOF_APP'
import os
import subprocess
import datetime
from flask import Flask, render_template, request, redirect, url_for, flash
from flask_login import LoginManager, UserMixin, login_user, login_required, logout_user

app = Flask(__name__)
app.secret_key = 'hex_secret_key_mudar_123'

login_manager = LoginManager()
login_manager.init_app(app)
login_manager.login_view = 'login'

ADMIN_PASSWORD = "admin26"

class User(UserMixin):
    def __init__(self, id):
        self.id = id

@login_manager.user_loader
def load_user(user_id):
    return User(user_id)

def run_cmd(cmd):
    try:
        result = subprocess.run(cmd, shell=True, capture_output=True, text=True, check=True)
        return True, result.stdout
    except subprocess.CalledProcessError as e:
        return False, e.stderr

def get_service_status(svc, port):
    try:
        result = subprocess.run(
            f"systemctl is-active {svc}@{port}.service",
            shell=True,
            capture_output=True,
            text=True
        )
        return result.returncode == 0 and "active" in result.stdout
    except:
        return False

def get_users():
    users = []
    if os.path.exists("/etc/hex/users.txt"):
        with open("/etc/hex/users.txt", "r") as f:
            for line in f:
                parts = line.strip().split(":")
                if len(parts) == 3:
                    users.append({"user": parts[0], "exp": parts[2]})
    return users

@app.route('/login', methods=['GET', 'POST'])
def login():
    if request.method == 'POST':
        if request.form['password'] == ADMIN_PASSWORD:
            login_user(User("admin"))
            return redirect(url_for('dashboard'))
        flash('Senha incorreta')
    return render_template('login.html')

@app.route('/logout')
@login_required
def logout():
    logout_user()
    return redirect(url_for('login'))

@app.route('/')
@login_required
def dashboard():
    bhttp_ports = open("/etc/hex/bhttp_ports.conf").read().splitlines() if os.path.exists("/etc/hex/bhttp_ports.conf") else []
    hcr_ports = open("/etc/hex/hcr_ports.conf").read().splitlines() if os.path.exists("/etc/hex/hcr_ports.conf") else []
    udpgw_ports = open("/etc/hex/udpgw_ports.conf").read().splitlines() if os.path.exists("/etc/hex/udpgw_ports.conf") else []
    
    stats = {
        "bhttp": sum(1 for p in bhttp_ports if get_service_status("bhttp", p)),
        "hcr": sum(1 for p in hcr_ports if get_service_status("hcr", p)),
        "udpgw": sum(1 for p in udpgw_ports if get_service_status("udpgw", p)),
        "users": len(get_users())
    }
    return render_template('dashboard.html', stats=stats, users=get_users())

@app.route('/add_user', methods=['POST'])
@login_required
def add_user():
    user = request.form['username']
    pwd = request.form['password']
    days = int(request.form['days'])
    
    exp_date = (datetime.datetime.now() + datetime.timedelta(days=days)).strftime("%Y-%m-%d")
    
    success1, msg1 = run_cmd(f"useradd -m -s /bin/bash -G hexusers {user} 2>/dev/null")
    if not success1 and "already exists" not in msg1:
        flash(f"Erro ao criar usuário: {msg1}")
        return redirect(url_for('dashboard'))
    
    run_cmd(f"echo '{user}:{pwd}' | chpasswd")
    run_cmd(f"chage -E {exp_date} {user}")
    run_cmd(f"usermod -e {exp_date} {user}")
    
    with open("/etc/hex/users.txt", "a") as f:
        f.write(f"{user}:{pwd}:{exp_date}\n")
    
    flash(f"Usuário {user} criado com sucesso (Expira: {exp_date})")
    return redirect(url_for('dashboard'))

@app.route('/delete_user/<username>')
@login_required
def delete_user(username):
    run_cmd(f"userdel -r {username} 2>/dev/null")
    run_cmd(f"sed -i '/^{username}:/d' /etc/hex/users.txt")
    flash(f"Usuário {username} removido")
    return redirect(url_for('dashboard'))

@app.route('/restart_service/<svc>')
@login_required
def restart_service(svc):
    run_cmd(f"systemctl restart '{svc}@*.service' 2>/dev/null")
    flash(f"Serviço {svc.upper()} reiniciado")
    return redirect(url_for('dashboard'))

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=9000, debug=False)
EOF_APP

    ui_ok "app.py criado"; ui_fila ""; sleep 1
}

criar_templates() {
    clear; ui_top; ui_titulo "4/5 CRIANDO INTERFACE WEB"; ui_sep; ui_fila ""
    ui_info "Criando templates HTML..."

    # Login template
    cat > "$PANEL_DIR/templates/login.html" <<'EOF_LOGIN'
<!DOCTYPE html>
<html lang="pt-BR">
<head>
    <meta charset="UTF-8">
    <title>Hex Panel - Login</title>
    <link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/css/bootstrap.min.css" rel="stylesheet">
    <style>
        body { background-color: #121212; color: #e0e0e0; display: flex; align-items: center; justify-content: center; height: 100vh; }
        .card { background-color: #1e1e1e; border: 1px solid #333; }
        .btn-primary { background-color: #00c853; border: none; }
    </style>
</head>
<body>
    <div class="card p-4" style="width: 350px;">
        <h3 class="text-center mb-4 text-success">🔐 Painel</h3>
        {% with messages = get_flashed_messages() %}
          {% if messages %}<div class="alert alert-danger">{{ messages[0] }}</div>{% endif %}
        {% endwith %}
        <form method="POST">
            <div class="mb-3">
                <label>Senha de Administrador</label>
                <input type="password" name="password" class="form-control bg-dark text-light" required>
            </div>
            <button type="submit" class="btn btn-primary w-100">Entrar</button>
        </form>
    </div>
</body>
</html>
EOF_LOGIN

    # Dashboard template
    cat > "$PANEL_DIR/templates/dashboard.html" <<'EOF_DASH'
<!DOCTYPE html>
<html lang="pt-BR">
<head>
    <meta charset="UTF-8">
    <title>Manager - Dashboard</title>
    <link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/css/bootstrap.min.css" rel="stylesheet">
    <style>
        body { background-color: #121212; color: #e0e0e0; }
        .card { background-color: #1e1e1e; border: 1px solid #333; }
        .text-success { color: #00c853 !important; }
        .table { color: #e0e0e0; }
        .table-dark { background-color: #1e1e1e; }
    </style>
</head>
<body>
    <nav class="navbar navbar-dark bg-dark border-bottom border-secondary">
        <div class="container-fluid">
            <span class="navbar-brand mb-0 h1">Painel Web</span>
            <a href="/logout" class="btn btn-outline-danger btn-sm">Sair</a>
        </div>
    </nav>

    <div class="container mt-4">
        {% with messages = get_flashed_messages() %}
          {% if messages %}<div class="alert alert-success">{{ messages[0] }}</div>{% endif %}
        {% endwith %}

        <div class="row mb-4">
            <div class="col-md-3">
                <div class="card p-3 text-center">
                    <h5 class="text-success">BHTTP</h5>
                    <h2>{{ stats.bhttp }} <small class="text-muted">Portas</small></h2>
                    <a href="/restart_service/bhttp" class="btn btn-sm btn-outline-success mt-2">Reiniciar</a>
                </div>
            </div>
            <div class="col-md-3">
                <div class="card p-3 text-center">
                    <h5 class="text-info">HCR</h5>
                    <h2>{{ stats.hcr }} <small class="text-muted">Portas</small></h2>
                    <a href="/restart_service/hcr" class="btn btn-sm btn-outline-info mt-2">Reiniciar</a>
                </div>
            </div>
            <div class="col-md-3">
                <div class="card p-3 text-center">
                    <h5 class="text-warning">UDPGW</h5>
                    <h2>{{ stats.udpgw }} <small class="text-muted">Portas</small></h2>
                    <a href="/restart_service/udpgw" class="btn btn-sm btn-outline-warning mt-2">Reiniciar</a>
                </div>
            </div>
            <div class="col-md-3">
                <div class="card p-3 text-center">
                    <h5 class="text-primary">Usuários</h5>
                    <h2>{{ stats.users }}</h2>
                </div>
            </div>
        </div>

        <div class="row">
            <div class="col-md-4">
                <div class="card p-3">
                    <h5 class="mb-3">➕ Adicionar Usuário</h5>
                    <form action="/add_user" method="POST">
                        <div class="mb-2">
                            <input type="text" name="username" class="form-control bg-dark text-light" placeholder="Usuário" required>
                        </div>
                        <div class="mb-2">
                            <input type="text" name="password" class="form-control bg-dark text-light" placeholder="Senha" required>
                        </div>
                        <div class="mb-2">
                            <input type="number" name="days" class="form-control bg-dark text-light" placeholder="Dias de validade" required>
                        </div>
                        <button type="submit" class="btn btn-success w-100">Criar Usuário</button>
                    </form>
                </div>
            </div>
            <div class="col-md-8">
                <div class="card p-3">
                    <h5 class="mb-3">👥 Usuários Ativos</h5>
                    <div class="table-responsive">
                        <table class="table table-dark table-hover">
                            <thead>
                                <tr>
                                    <th>Usuário</th>
                                    <th>Expiração</th>
                                    <th>Ação</th>
                                </tr>
                            </thead>
                            <tbody>
                                {% for u in users %}
                                <tr>
                                    <td>{{ u.user }}</td>
                                    <td>{{ u.exp }}</td>
                                    <td>
                                        <a href="/delete_user/{{ u.user }}" class="btn btn-sm btn-danger" onclick="return confirm('Remover este usuário?')">🗑️</a>
                                    </td>
                                </tr>
                                {% else %}
                                <tr><td colspan="3" class="text-center text-muted">Não há usuários registrados</td></tr>
                                {% endfor %}
                            </tbody>
                        </table>
                    </div>
                </div>
            </div>
        </div>
    </div>
</body>
</html>
EOF_DASH

    ui_ok "Templates criados"; ui_fila ""; sleep 1
}

configurar_servico() {
    clear; ui_top; ui_titulo "5/5 CONFIGURANDO SERVIÇO"; ui_sep; ui_fila ""
    ui_info "Criando serviço systemd..."

    cat > /etc/systemd/system/hex-webpanel.service <<EOF
[Unit]
Description=Hex Web Panel
After=network.target

[Service]
User=root
WorkingDirectory=$PANEL_DIR
Environment="PATH=$PANEL_DIR/venv/bin"
ExecStart=$PANEL_DIR/venv/bin/python app.py
Restart=always

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload >/dev/null 2>&1
    systemctl enable hex-webpanel.service >/dev/null 2>&1

    ui_info "Abrindo a porta $PANEL_PORT no firewall..."
    iptables -I INPUT -p tcp --dport $PANEL_PORT -j ACCEPT 2>/dev/null
    command -v ufw >/dev/null 2>&1 && ufw allow $PANEL_PORT/tcp >/dev/null 2>&1

    ui_info "Iniciando painel web..."
    systemctl start hex-webpanel.service

    sleep 2
    if systemctl is-active --quiet hex-webpanel.service; then
        ui_ok "Painel web ativo"
    else
        ui_error "O painel não pôde iniciar"
    fi

    ui_fila ""; sleep 1
}

mostrar_resumo() {
    clear; ui_top; ui_titulo "✓ INSTALAÇÃO CONCLUÍDA"; ui_sep; ui_fila ""
    ui_fila "  ${GREEN}${BOLD}Painel Web instalado com sucesso${NC}"
    ui_fila ""
    ui_fila "  ${BOLD}URL:${NC}        ${CYAN}http://$(hostname -I | awk '{print $1}'):$PANEL_PORT${NC}"
    ui_fila "  ${BOLD}Usuário:${NC}    ${YELLOW}admin${NC}"
    ui_fila "  ${BOLD}Senha:${NC}      ${YELLOW}$ADMIN_PASS${NC}"
    ui_fila ""
    ui_sep
    ui_fila "  ${RED}${BOLD}⚠ IMPORTANTE:${NC} Altere a senha em:"
    ui_fila "  ${YELLOW}$PANEL_DIR/app.py${NC}"
    ui_fila ""
    ui_bot; echo ""
}

# EXECUÇÃO
verificar_root
instalar_dependencias
criar_estrutura
criar_app
criar_templates
configurar_servico
mostrar_resumo
