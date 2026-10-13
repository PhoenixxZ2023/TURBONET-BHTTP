@@
 APP = Flask(__name__)
 app.secret_key = load_secret_key()
@@
 login_manager.login_view = 'login'
 ADMIN_PASSWORD_HASH = load_admin_password()
 migrate_legacy_user_db()
+
+AUDIT_LOG_FILE = os.environ.get("HEX_AUDIT_LOG", "/var/log/hex-webpanel-audit.log")
+ALLOWED_SYSTEMCTL_ACTIONS = {"start", "stop", "restart", "enable", "disable", "is-active", "is-enabled"}
+
+
+def audit_action(action, target, success, details="", ip=None):
+    entry = {
+        "ts": datetime.datetime.utcnow().isoformat(timespec="seconds") + "Z",
+        "action": str(action),
+        "target": str(target),
+        "success": bool(success),
+        "details": str(details),
+        "ip": str(ip or "unknown"),
+    }
+    try:
+        with open(AUDIT_LOG_FILE, "a", encoding="utf-8") as f:
+            f.write(json.dumps(entry, ensure_ascii=False) + "\n")
+    except Exception:
+        pass
+
+
+def sanitize_cmd_arg(value):
+    if value is None:
+        return ""
+    s = str(value).strip()
+    if not s:
+        return ""
+    if any(ch in s for ch in (";", "|", "&", "`", "$", "\n", "\r", ">", "<")):
+        raise ValueError(f"Argumento inválido para execução do sistema: {value!r}")
+    return s
+
+
+def validate_service_name(svc):
+    return svc in SERVICES
+
+
+def validate_systemctl_action(action):
+    return action in ALLOWED_SYSTEMCTL_ACTIONS
+
+
+def systemctl_guard(svc, action, port=None):
+    if not validate_service_name(svc):
+        raise ValueError(f"serviço inválido: {svc}")
+    if not validate_systemctl_action(action):
+        raise ValueError(f"ação inválida no systemctl: {action}")
+    if port is not None:
+        if not PORT_RE.fullmatch(str(port)):
+            raise ValueError(f"porta inválida: {port}")
+        return [SYSTEMCTL, action, f"{svc}@{port}.service"]
+    return [SYSTEMCTL, action, svc]
@@
 def run(cmd, **kw):
     kw.setdefault('capture_output', True)
     kw.setdefault('text', True)
     kw.setdefault('timeout', 20)
-    return subprocess.run(cmd, **kw)
+    sanitized = [sanitize_cmd_arg(part) for part in cmd]
+    if any(not part for part in sanitized):
+        raise ValueError(f"Comando inválido na execução: {cmd!r}")
+    return subprocess.run(sanitized, **kw)
***
@@
 def control_service(svc, action):
     try:
-        if svc not in SERVICES:
+        if svc not in SERVICES:
             flash(f"Serviço inválido: {svc}")
             return redirect(url_for('dashboard'))
         if action not in ('start', 'stop', 'restart'):
             flash(f"Ação inválida: {action}")
             return redirect(url_for('dashboard'))
@@
         ok = err = 0
         for port in ports:
-            r = run([SYSTEMCTL, action, f"{svc}@{port}.service"])
+            target = systemctl_guard(svc, action, port)
+            r = run(target)
             if r.returncode == 0:
                 ok += 1
             else:
                 err += 1
+        audit_action(f"service:{action}", f"{svc}:{','.join(ports) or 'none'}", err == 0, f"ok={ok} err={err}", client_ip())
         label = {"start": "Início", "stop": "Parada", "restart": "Reinício"}[action]
         if err == 0:
             flash(f"✓ {svc.upper()}: Ação '{label}' com sucesso em {ok} porta(s)")
         else:
             flash(f"⚠ {svc.upper()}: {ok} com sucesso, {err} erro(s)")
     except Exception as e:
+        audit_action(f"service:{action}", f"{svc}", False, str(e), client_ip())
         logging.error(f"Erro ao controlar o serviço: {e}")
         flash("Erro ao controlar o serviço")
     return redirect(url_for('dashboard'))
***
@@
 def change_password():
     global ADMIN_PASSWORD_HASH
     try:
         cur = request.form.get('current_password', '')
         new = request.form.get('new_password', '')
         conf = request.form.get('confirm_password', '')
         logging.info(f"[CHANGE_PASS] Solicitação de {client_ip()}")
         if len(new) < 8 or len(new.encode('utf-8')) > 72:
             flash("A nova senha deve ter entre 8 e 72 caracteres")
+            audit_action("admin_change_password", "admin", False, "new_password_length", client_ip())
         elif new != conf:
             flash("As novas senhas não coincidem")
+            audit_action("admin_change_password", "admin", False, "password_mismatch", client_ip())
         elif not verify_password(cur, ADMIN_PASSWORD_HASH):
             flash("A senha atual está incorreta")
+            audit_action("admin_change_password", "admin", False, "current_password_invalid", client_ip())
         elif verify_password(new, ADMIN_PASSWORD_HASH):
             flash("A nova senha deve ser diferente da atual")
+            audit_action("admin_change_password", "admin", False, "same_as_current", client_ip())
         else:
             new_hash = hash_password(new)
             if save_password_hash(new_hash):
                 ADMIN_PASSWORD_HASH = new_hash
                 try:
                     os.remove(INITIAL_PASS_FILE)
                 except OSError:
                     pass
                 logging.info("[CHANGE_PASS] ✓ Senha alterada com sucesso")
                 flash("✓ Senha alterada com sucesso. Saia para aplicar as alterações.")
+                audit_action("admin_change_password", "admin", True, "password_changed", client_ip())
             else:
                 flash("Erro ao salvar a senha")
+                audit_action("admin_change_password", "admin", False, "save_failed", client_ip())
     except Exception as e:
         logging.error(f"[CHANGE_PASS] Erro: {e}", exc_info=True)
         flash("Erro ao alterar a senha")
+        audit_action("admin_change_password", "admin", False, str(e), client_ip())
     return redirect(url_for('dashboard'))
***
@@
 def update_now():
     try:
         logging.info("Iniciando atualização pelo painel web")
         results = perform_update()
         reload_ = results["backend"]["success"] or results["templates"]["success"]
         if reload_:
             schedule_restart()
         ok = sum(1 for v in results.values() if v["success"])
+        audit_action("panel_update", "ota", ok > 0, json.dumps(results, ensure_ascii=False), client_ip())
         return jsonify({
             "success": True,
             "message": f"Atualização concluída: {ok}/{len(results)} componentes",
             "details": results,
             "restart": "O painel será reiniciado automaticamente em alguns segundos." if reload_ else "",
             "will_reload": reload_})
     except Exception as e:
         logging.error(f"Erro em atualização: {e}", exc_info=True)
+        audit_action("panel_update", "ota", False, str(e), client_ip())
         return jsonify({"success": False, "message": "Erro durante a atualização"}), 500
***
@@
 def add_user():
     try:
         user = request.form.get('username', '').strip().lower()
         pwd = request.form.get('password', '')
         try:
             days = int(request.form.get('days', ''))
         except ValueError:
             flash("Erro: Os dias devem ser um número válido")
+            audit_action("user_create", user or "unknown", False, "invalid_days", client_ip())
             return redirect(url_for('dashboard'))
         if not valid_username(user):
             flash("Usuário inválido: use letras minúsculas, números, '_' ou '-' (começando por letra ou '_')")
+            audit_action("user_create", user or "unknown", False, "invalid_username", client_ip())
             return redirect(url_for('dashboard'))
         if not valid_user_password(pwd):
             flash("Senha inválida: 4 a 64 caracteres, sem ':' nem caracteres de controle")
+            audit_action("user_create", user, False, "invalid_password", client_ip())
             return redirect(url_for('dashboard'))
         if not (1 <= days <= 3650):
             flash("Os dias devem estar entre 1 e 3650")
+            audit_action("user_create", user, False, "invalid_expiry_days", client_ip())
             return redirect(url_for('dashboard'))
         if system_user_exists(user):
             flash(f"O usuário '{user}' já existe no sistema")
+            audit_action("user_create", user, False, "already_exists", client_ip())
             return redirect(url_for('dashboard'))
@@
         if res.returncode != 0:
             logging.error(f"useradd falhou: {res.stderr}")
             flash("Erro ao criar usuário")
+            audit_action("user_create", user, False, res.stderr.strip()[:250], client_ip())
             return redirect(url_for('dashboard'))
         res = run([CHPASSWD], input=f"{user}:{pwd}\n")
         if res.returncode != 0:
             logging.error(f"chpasswd falhou: {res.stderr}")
             run([USERDEL, '-r', user])
             flash("Erro ao definir a senha")
+            audit_action("user_create", user, False, res.stderr.strip()[:250], client_ip())
             return redirect(url_for('dashboard'))
         set_expiry(user, exp_date)
         with DbLock():
             entries = [e for e in read_db() if e[0] != user]
             entries.append((user, pwd, exp_date))
             write_db(entries)
         logging.info(f"Usuário criado: {user} (exp {exp_date}) por {client_ip()}")
         flash(f"✓ Usuário '{user}' criado com sucesso (Expira: {exp_date})")
+        audit_action("user_create", user, True, f"exp={exp_date}", client_ip())
     except Exception as e:
         logging.error(f"Erro criando usuário: {e}", exc_info=True)
         flash("Erro inesperado ao criar usuário")
+        audit_action("user_create", user if 'user' in locals() else 'unknown', False, str(e), client_ip())
     return redirect(url_for('dashboard'))
***
@@
 def delete_user(username):
     try:
         if not _managed_or_flash(username):
             return redirect(url_for('dashboard'))
         run([PKILL, '-KILL', '-u', username])
@@
         with DbLock():
             write_db([e for e in read_db() if e[0] != username])
         logging.info(f"Usuário removido: {username} por {client_ip()}")
         flash(f"✓ Usuário '{username}' removido com sucesso")
+        audit_action("user_delete", username, True, "removed", client_ip())
     except Exception as e:
         logging.error(f"Erro removendo usuário: {e}", exc_info=True)
         flash("Erro ao remover usuário")
+        audit_action("user_delete", username, False, str(e), client_ip())
     return redirect(url_for('dashboard'))
***
@@
 def edit_password(username):
     try:
         new = request.form.get('new_password', '')
         conf = request.form.get('confirm_password', '')
         logging.info(f"[EDIT_PASS] Troca de senha para {username} de {client_ip()}")
         if not _managed_or_flash(username):
             return redirect(url_for('dashboard'))
         if not valid_user_password(new):
             flash("Senha inválida: 4 a 64 caracteres, sem ':' nem caracteres de controle")
+            audit_action("user_password_change", username, False, "invalid_password", client_ip())
         elif new != conf:
             flash("As novas senhas não coincidem")
+            audit_action("user_password_change", username, False, "mismatch", client_ip())
         elif not system_user_exists(username):
             flash(f"O usuário '{username}' não existe no sistema")
+            audit_action("user_password_change", username, False, "missing_user", client_ip())
         else:
             res = run([CHPASSWD], input=f"{username}:{new}\n")
             if res.returncode != 0:
                 logging.error(f"chpasswd falhou: {res.stderr}")
                 flash("Erro ao alterar a senha")
+                audit_action("user_password_change", username, False, res.stderr.strip()[:250], client_ip())
             else:
                 with DbLock():
                     write_db([(u, new if u == username else p, e) for u, p, e in read_db()])
                 flash(f"✓ Senha de '{username}' alterada com sucesso")
+                audit_action("user_password_change", username, True, "password_updated", client_ip())
     except Exception as e:
         logging.error(f"[EDIT_PASS] Erro: {e}", exc_info=True)
         flash("Erro ao alterar a senha")
+        audit_action("user_password_change", username, False, str(e), client_ip())
     return redirect(url_for('dashboard'))
***
@@
 def edit_expiry(username):
     try:
         action = request.form.get('action', '')
         logging.info(f"[EDIT_EXP] Troca de expiração para {username} de {client_ip()}")
@@
         if not _managed_or_flash(username):
             return redirect(url_for('dashboard'))
         if not system_user_exists(username):
             flash(f"O usuário '{username}' não existe no sistema")
+            audit_action("user_expiry_change", username, False, "user_missing", client_ip())
             return redirect(url_for('dashboard'))
@@
         if action == "permanent":
             new_exp, msg = "2099-12-31", f"✓ Usuário '{username}' agora é permanente"
         elif action == "custom":
             custom = request.form.get('custom_date', '')
             if not valid_date(custom):
                 flash("Data inválida. Use o formato AAAA-MM-DD")
+                audit_action("user_expiry_change", username, False, "invalid_date", client_ip())
                 return redirect(url_for('dashboard'))
             new_exp, msg = custom, f"✓ Expiração de '{username}' alterada para {custom}"
@@
         else:
             flash("Ação inválida")
+            audit_action("user_expiry_change", username, False, f"invalid_action:{action}", client_ip())
             return redirect(url_for('dashboard'))
 
         set_expiry(username, new_exp)
         with DbLock():
             write_db([(u, p, new_exp if u == username else e) for u, p, e in read_db()])
         logging.info(f"[EDIT_EXP] ✓ Expiração de {username} alterada para {new_exp}")
         flash(msg)
+        audit_action("user_expiry_change", username, True, f"new_exp={new_exp}", client_ip())
     except Exception as e:
         logging.error(f"[EDIT_EXP] Erro: {e}", exc_info=True)
         flash("Erro ao alterar a expiração")
+        audit_action("user_expiry_change", username, False, str(e), client_ip())
     return redirect(url_for('dashboard'))
***
@@
 def __main__():
     if len(sys.argv) > 1 and sys.argv[1] == "--reset-password":
         sys.exit(cli_set_password())
     if len(sys.argv) > 1 and sys.argv[1] == "--set-password":
         sys.exit(cli_set_password(sys.stdin.readline().rstrip("\n")))
     host = os.environ.get("HEX_PANEL_HOST", "0.0.0.0")
     port = get_webpanel_port()
+    audit_action("panel_start", f"{host}:{port}", True, "startup", "local")
     if TLS_ENABLED:
         run_https(host, port)
     else:
         try:
             from waitress import serve
             logging.info(f"Painel (waitress) em {host}:{port}")
             serve(app, host=host, port=port, threads=4)
         except ImportError:
             logging.warning("waitress não instalado; usando o servidor de desenvolvimento do Flask")
             app.run(host=host, port=port, debug=False)
***
