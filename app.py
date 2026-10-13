@@
 def set_expiry(user, exp_date):
     if exp_date == "2099-12-31":
-        run([CHAGE, '-E', '-1', user])
-        run([USERMOD, '-e', '', user])
+        privileged_run('chage', '-E', '-1', user)
+        privileged_run('usermod', '-e', '', user)
     else:
-        run([CHAGE, '-E', exp_date, user])
-        run([USERMOD, '-e', exp_date, user])
+        privileged_run('chage', '-E', exp_date, user)
+        privileged_run('usermod', '-e', exp_date, user)
@@
 def get_service_status(svc, port):
     try:
-        r = run([SYSTEMCTL, 'is-active', f"{svc}@{port}.service"], timeout=5)
+        r = privileged_run('systemctl', 'is-active', f"{svc}@{port}.service", timeout=5)
         return r.returncode == 0 and "active" in r.stdout
     except Exception:
         return False
@@
 def run(cmd, **kw):
     kw.setdefault('capture_output', True)
     kw.setdefault('text', True)
     kw.setdefault('timeout', 20)
     return subprocess.run(cmd, **kw)
+
+
+PRIVILEGED_HELPER = os.environ.get('HEX_PRIVILEGED_HELPER')
+
+
+def get_privileged_helper():
+    candidates = [
+        PRIVILEGED_HELPER,
+        os.path.join(os.path.dirname(os.path.abspath(__file__)), 'hex_privileged.py'),
+        '/usr/local/bin/hex_privileged.py',
+        '/opt/hex-webpanel/hex_privileged.py',
+    ]
+    for candidate in candidates:
+        if candidate and os.path.exists(candidate):
+            return candidate
+    return None
+
+
+def privileged_run(action, *args, **kw):
+    helper = get_privileged_helper()
+    if helper is None:
+        raise RuntimeError('Helper privilegiado não encontrado em HEX_PRIVILEGED_HELPER/nas pastas padrões')
+    cmd = [sys.executable, helper, action]
+    for arg in args:
+        if arg is None:
+            continue
+        cmd.append(str(arg))
+    kw.setdefault('capture_output', True)
+    kw.setdefault('text', True)
+    kw.setdefault('timeout', 20)
+    return subprocess.run(cmd, **kw)
@@
 def add_user():
     try:
         user = request.form.get('username', '').strip().lower()
         pwd = request.form.get('password', '')
@@
         if run([GETENT, 'group', USER_GROUP]).returncode != 0:
-            run([GROUPADD, USER_GROUP])
+            privileged_run('groupadd', USER_GROUP)
         exp_date = (datetime.datetime.now() + datetime.timedelta(days=days)).strftime("%Y-%m-%d")
-        res = run([USERADD, '-m', '-s', get_user_shell(), '-G', USER_GROUP, user])
+        res = privileged_run('useradd', user)
         if res.returncode != 0:
             logging.error(f"useradd falhou: {res.stderr}")
             flash("Erro ao criar usuário")
             return redirect(url_for('dashboard'))
-        res = run([CHPASSWD], input=f"{user}:{pwd}\n")
+        env = os.environ.copy()
+        env['HEX_CHPASSWD_INPUT'] = f"{user}:{pwd}\n"
+        res = privileged_run('chpasswd', user, env=env)
         if res.returncode != 0:
             logging.error(f"chpasswd falhou: {res.stderr}")
-            run([USERDEL, '-r', user])
+            privileged_run('userdel', user)
             flash("Erro ao definir a senha")
             return redirect(url_for('dashboard'))
         set_expiry(user, exp_date)
@@
         if not _managed_or_flash(username):
             return redirect(url_for('dashboard'))
-        run([PKILL, '-KILL', '-u', username])
-        res = run([USERDEL, '-r', username])
+        privileged_run('pkill', '-KILL', username)
+        res = privileged_run('userdel', username)
         if res.returncode != 0 and system_user_exists(username):
             logging.error(f"userdel falhou para {username}: {res.stderr}")
             flash(f"Erro ao remover '{username}'")
             return redirect(url_for('dashboard'))
@@
             elif not system_user_exists(username):
                 flash(f"O usuário '{username}' não existe no sistema")
             else:
-                res = run([CHPASSWD], input=f"{username}:{new}\n")
+                env = os.environ.copy()
+                env['HEX_CHPASSWD_INPUT'] = f"{username}:{new}\n"
+                res = privileged_run('chpasswd', username, env=env)
                 if res.returncode != 0:
                     logging.error(f"chpasswd falhou: {res.stderr}")
                     flash("Erro ao alterar a senha")
                 else:
@@
         if not _managed_or_flash(username):
             return redirect(url_for('dashboard'))
         if action not in ('start', 'stop', 'restart'):
             flash(f"Ação inválida: {action}")
             return redirect(url_for('dashboard'))
@@
         ok = err = 0
         for port in ports:
-            r = run([SYSTEMCTL, action, f"{svc}@{port}.service"])
+            r = privileged_run('systemctl', action, f"{svc}@{port}.service")
             if r.returncode == 0:
                 ok += 1
             else:
                 err += 1
***
