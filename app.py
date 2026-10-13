@@
 def read_db():
     entries = []
     try:
         with open(USER_DB) as f:
             for line in f:
                 e = _parse_line(line)
                 if e:
-                    entries.append(e)
+                    user, pwd, exp = e
+                    if pwd and not is_bcrypt_hash(pwd):
+                        pwd = hash_user_password(pwd)
+                    entries.append((user, pwd, exp))
     except FileNotFoundError:
         pass
     except Exception as e:
         logging.error(f"Erro ao ler users.txt: {e}")
     return entries
 
 
 def write_db(entries):
-    write_atomic(USER_DB, ''.join(f"{u}:{p}:{e}\n" for u, p, e in entries), 0o600)
+    normalized = []
+    for u, p, e in entries:
+        if not p:
+            normalized.append((u, p, e))
+        elif is_bcrypt_hash(p):
+            normalized.append((u, p, e))
+        else:
+            normalized.append((u, hash_user_password(p), e))
+    write_atomic(USER_DB, ''.join(f"{u}:{p}:{e}\n" for u, p, e in normalized), 0o600)
+
+
+def hash_user_password(password):
+    return bcrypt.hashpw(password.encode('utf-8'), bcrypt.gensalt(rounds=12)).decode('utf-8')
+
+
+def verify_user_password(password, hashed):
+    try:
+        return bcrypt.checkpw(password.encode('utf-8'), hashed.encode('utf-8'))
+    except Exception as e:
+        logging.error(f"Erro ao verificar senha do usuário: {e}")
+        return False
+
+
+def migrate_legacy_user_db():
+    try:
+        entries = read_db()
+        if any(not is_bcrypt_hash(p) for _, p, _ in entries if p):
+            with DbLock():
+                entries = read_db()
+                write_db(entries)
+    except Exception as e:
+        logging.error(f"Erro ao migrar users.txt para hashes: {e}")
@@
 login_manager = LoginManager()
 login_manager.init_app(app)
 login_manager.login_view = 'login'
 ADMIN_PASSWORD_HASH = load_admin_password()
+migrate_legacy_user_db()
*** 
