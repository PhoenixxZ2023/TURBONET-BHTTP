#!/bin/bash
set -euo pipefail

HEX_DIR="/etc/hex"
PANEL_DIR="/opt/hex-webpanel"
HELPER_SRC="/opt/hex-webpanel/hex_privileged.py"
HELPER_DST="/usr/local/bin/hex_privileged.py"
WEB_USER="hexweb"

if [ "$(id -u)" -ne 0 ]; then
  echo "Este script precisa rodar como root" >&2
  exit 1
fi

mkdir -p "$HEX_DIR"
chmod 700 "$HEX_DIR"

# Copia o helper para um local do sistema, com permissões estritas.
install -o root -g root -m 700 "$HELPER_SRC" "$HELPER_DST"

# Cria o usuário não-root usado pelo painel web.
if ! id "$WEB_USER" >/dev/null 2>&1; then
  useradd --system --home-dir "$PANEL_DIR" --shell /usr/sbin/nologin "$WEB_USER"
fi

# Ajusta ownership do painel para o usuário web.
chown -R "$WEB_USER":"$WEB_USER" "$PANEL_DIR"
chmod 750 "$PANEL_DIR"
chmod 700 "$HEX_DIR"

# Cria um sudoers seguro para o usuário do painel executar apenas o helper centralizado.
cat > /etc/sudoers.d/hex-webpanel <<'EOF'
Defaults:hexweb !requiretty
hexweb ALL=(root) NOPASSWD: /usr/local/bin/hex_privileged.py *
EOF
chmod 440 /etc/sudoers.d/hex-webpanel
visudo -cf /etc/sudoers.d/hex-webpanel >/dev/null

# Instala a unit do helper em systemd (opcional; o workflow mais simples é permitir sudo do helper)
cat > /etc/systemd/system/hex-privileged.service <<'EOF'
[Unit]
Description=Hex privileged helper
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/bin/python3 /usr/local/bin/hex_privileged.py --daemon
Restart=on-failure
RestartSec=2
NoNewPrivileges=yes
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
EOF

# Ajusta o unit do painel para rodar como o usuário não-root.
cat > /etc/systemd/system/hex-webpanel.service <<'EOF'
[Unit]
Description=Hex Web Panel
After=network.target

[Service]
Type=simple
User=hexweb
Group=hexweb
WorkingDirectory=/opt/hex-webpanel
Environment="PATH=/opt/hex-webpanel/venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
EnvironmentFile=-/etc/hex/webpanel.env
ExecStart=/opt/hex-webpanel/venv/bin/python /opt/hex-webpanel/app.py
Restart=always
RestartSec=3
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable hex-privileged.service 2>/dev/null || true
systemctl restart hex-privileged.service 2>/dev/null || true
systemctl restart hex-webpanel.service 2>/dev/null || true

printf '\nSeparação de privilégios concluída.\n'
printf 'Helper: %s\n' "$HELPER_DST"
printf 'Usuário do painel: %s\n' "$WEB_USER"
printf 'Sudoers: %s\n' "/etc/sudoers.d/hex-webpanel"
