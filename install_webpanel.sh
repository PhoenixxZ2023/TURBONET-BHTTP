@@
 baixar_aplicacao() {
     clear; ui_top; ui_titulo "3/5 BAIXANDO APLICAÇÃO"; ui_sep
     TMPD=$(mktemp -d); trap 'rm -rf "$TMPD"' EXIT
     MANIFEST="$TMPD/version.json"
     ui_info "Baixando version.json..."
     baixar_arquivo "$GITHUB_RAW/version.json" "$MANIFEST" && [ -s "$MANIFEST" ] \
         || { ui_error "Não foi possível baixar o version.json"; exit 1; }
-    ui_info "Baixando app.py e templates..."
+    ui_info "Baixando app.py, helper privilegiado e templates..."
     baixar_verificado "app.py" "$PANEL_DIR/app.py" 644 || exit 1
+    mkdir -p "$PANEL_DIR/scripts"
+    baixar_verificado "hex_privileged.py" "$PANEL_DIR/hex_privileged.py" 700 || exit 1
+    baixar_verificado "scripts/setup_privileged_runtime.sh" "$PANEL_DIR/scripts/setup_privileged_runtime.sh" 700 || exit 1
     baixar_verificado "templates/login.html" "$PANEL_DIR/templates/login.html" 644 || exit 1
     baixar_verificado "templates/dashboard.html" "$PANEL_DIR/templates/dashboard.html" 644 || exit 1
     baixar_verificado "hex_ip.sh" /usr/local/bin/hex_ip.sh 755 || exit 1
     baixar_verificado "hex_panel_mode.sh" /usr/local/bin/hex_panel_mode.sh 755 || exit 1
     "$PANEL_DIR/venv/bin/python" -m py_compile "$PANEL_DIR/app.py" || { ui_error "app.py com erro de sintaxe"; exit 1; }
+    "$PANEL_DIR/venv/bin/python" -m py_compile "$PANEL_DIR/hex_privileged.py" || { ui_error "hex_privileged.py com erro de sintaxe"; exit 1; }
     local v
     v=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("version",""))' "$MANIFEST" 2>/dev/null)
     [ -n "$v" ] && [ ! -f "$HEX_DIR/version" ] && echo "$v" > "$HEX_DIR/version"
     ui_ok "Aplicação baixada e verificada"; sleep 1
 }
+
+aplicar_separacao_privilegiada() {
+    clear; ui_top; ui_titulo "4/5 SEPARAÇÃO DE PRIVILÉGIOS"; ui_sep
+    if [ -f "$PANEL_DIR/scripts/setup_privileged_runtime.sh" ]; then
+        ui_info "Aplicando setup do helper privilegiado e usuário não-root..."
+        if bash "$PANEL_DIR/scripts/setup_privileged_runtime.sh"; then
+            ui_ok "Separação de privilégios aplicada";
+        else
+            ui_warn "O setup do runtime privilegiado falhou; o painel continua com a instalação anterior";
+            return 1
+        fi
+    else
+        ui_warn "helper privilegiado não disponível; pulando proteção de runtime"
+    fi
+    sleep 1
+}
 
 configurar_servico() {
-    clear; ui_top; ui_titulo "4/5 CONFIGURANDO SERVIÇO"; ui_sep
+    clear; ui_top; ui_titulo "5/5 CONFIGURANDO SERVIÇO"; ui_sep
     PANEL_PORT=$(cat "$PORT_FILE" 2>/dev/null || echo 9000)
     cat > /etc/systemd/system/hex-webpanel.service <<EOT
 [Unit]
 Description=Hex Web Panel
 After=network.target
@@
-    mostrar_resumo() {
-    clear; ui_top; ui_titulo "5/5 ✓ INSTALAÇÃO CONCLUÍDA"; ui_sep
+mostrar_resumo() {
+    clear; ui_top; ui_titulo "6/6 ✓ INSTALAÇÃO CONCLUÍDA"; ui_sep
@@
 main() {
     verificar_root
     : > "$LOG_FILE" 2>/dev/null
     instalar_dependencias
     criar_estrutura
     baixar_aplicacao
+    aplicar_separacao_privilegiada
     configurar_servico
     mostrar_resumo
 }
