#!/bin/bash
set -euo pipefail

# deploy_runtime_complete.sh
# Script idempotente para aplicar a separação de privilégios e instalar o helper
# Uso: copiar para o servidor onde o painel foi instalado (/opt/hex-webpanel) e executar como root

PANEL_DIR="/opt/hex-webpanel"
HELPER_SRC="$PANEL_DIR/hex_privileged.py"
HELPER_DST="/usr/local/bin/hex_privileged.py"
WEB_USER="hexweb"
HEX_DIR="/etc/hex"
SUDOERS_FILE="/etc/sudoers.d/hex-webpanel"
HELPER_SERVICE="/etc/systemd/system/hex-privileged.service"
WEB_SERVICE="/etc/systemd/system/hex-webpanel.service"

if [ "$(id -u)" -ne 0 ]; then
  echo "Erro: execute este script como root" >&2
  exit 1
fi

echo "[1/8] Preparando diretórios e permissões"
mkdir -p "$HEX_DIR"
chmod 700 "$HEX_DIR"
mkdir -p "$PANEL_DIR"
chown -R root:root "$PANEL_DIR" || true

echo "[2/8] Instalando helper privilegiado em $HELPER_DST"
if [ -f "$HELPER_SRC" ]; then
  install -o root -g root -m 700 "$HELPER_SRC" "$HELPER_DST"
  echo "  helper instalado"
else
  echo "  AVISO: $HELPER_SRC não encontrado. Coloque o hex_privileged.py em $PANEL_DIR e reexecute" >&2
fi

echo "[3/8] Criando usuário system account para o painel: $WEB_USER"
if id "$WEB_USER" >/dev/null 2>&1; then
  echo "  usuário $WEB_USER já existe"
else
  useradd --system --home-dir "$PANEL_DIR" --shell /usr/sbin/nologin "$WEB_USER"
  echo "  usuário criado: $WEB_USER"
fi

echo "[4/8] Ajustando ownership do painel para $WEB_USER"
chown -R "$WEB_USER":"$WEB_USER" "$PANEL_DIR" || true
chmod 750 "$PANEL_DIR" || true

echo "[5/8] Instalando regra sudoers restrita: $SUDOERS_FILE"
cat > "$SUDOERS_FILE" <<'EOF'
Defaults:hexweb !requiretty
hexweb ALL=(root) NOPASSWD: /usr/local/bin/hex_privileged.py *
EOF
chmod 440 "$SUDOERS_FILE"
if visudo -cf "$SUDOERS_FILE" >/dev/null 2>&1; then
  echo "  sudoers OK"
else
  echo "  ERRO: arquivo sudoers inválido" >&2
  exit 1
fi

echo "[6/8] Instalando systemd unit do helper (hex-privileged.service)"
cat > "$HELPER_SERVICE" <<'EOF'
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

chmod 644 "$HELPER_SERVICE"

echo "[7/8] Ajustando systemd unit do painel para rodar como $WEB_USER"
cat > "$WEB_SERVICE" <<EOF
[Unit]
Description=Hex Web Panel
After=network.target

[Service]
Type=simple
User=$WEB_USER
Group=$WEB_USER
WorkingDirectory=$PANEL_DIR
Environment="PATH=$PANEL_DIR/venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
EnvironmentFile=-$HEX_DIR/webpanel.env
ExecStart=$PANEL_DIR/venv/bin/python $PANEL_DIR/app.py
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

chmod 644 "$WEB_SERVICE"

echo "[8/8] Reload systemd e reiniciar serviços (helper + painel)"
systemctl daemon-reload
systemctl enable --now hex-privileged.service || true
systemctl restart hex-privileged.service || true
systemctl enable --now hex-webpanel.service || true
systemctl restart hex-webpanel.service || true

cat <<EOF

Pronto.
Valide os logs e status:
  sudo systemctl status hex-privileged.service
  sudo journalctl -u hex-privileged.service -n 50
  sudo systemctl status hex-webpanel.service
  sudo journalctl -u hex-webpanel.service -n 50
Checklist rápido:
  - painel roda como usuário: $(id -un $(pgrep -u 0 -f hex-webpanel.service 2>/dev/null) 2>/dev/null || echo "verifique")
  - helper instalado: $HELPER_DST
  - sudoers: $SUDOERS_FILE
  - auditoria: /var/log/hex-webpanel-audit.log
EOF
