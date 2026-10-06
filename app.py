import os, subprocess, datetime, logging, time, json, threading
from flask import Flask, render_template, request, redirect, url_for, flash, jsonify
from flask_login import LoginManager, UserMixin, login_user, login_required, logout_user
import bcrypt

logging.basicConfig(filename='/var/log/hex-webpanel.log', level=logging.INFO, 
                    format='%(asctime)s - %(levelname)s - %(message)s')

app = Flask(__name__)
app.secret_key = 'hex_secret_key_cambiar_123'
login_manager = LoginManager()
login_manager.init_app(app)
login_manager.login_view = 'login'

ADMIN_PASSWORD_HASH = None
PASSWORD_FILE = "/etc/hex/webpanel_admin_pass.conf"
DEFAULT_PASSWORD = "admin26"

SYSTEMCTL = '/usr/bin/systemctl'
USERADD = '/usr/sbin/useradd'
USERDEL = '/usr/sbin/userdel'
USERMOD = '/usr/sbin/usermod'
CHPASSWD = '/usr/sbin/chpasswd'
CHAGE = '/usr/bin/chage'
GROUPADD = '/usr/sbin/groupadd'
ID = '/usr/bin/id'
GETENT = '/usr/bin/getent'
CURL = '/usr/bin/curl'
BASH = '/bin/bash'
CP = '/bin/cp'
MV = '/bin/mv'
RM = '/bin/rm'

WEBPANEL_PORT_FILE = "/etc/hex/webpanel_port.conf"
VERSION_FILE = "/etc/hex/version"
UPDATE_CACHE_FILE = "/tmp/hex_update_cache.json"
GITHUB_RAW = "https://raw.githubusercontent.com/rogellevi/HCR_BHTTP/main"
CACHE_DURATION = 300

# ═══════════════════════════════════════════════════════════════
#  SISTEMA DE CONTRASEÑAS CON BCRYPT
# ═══════════════════════════════════════════════════════════════

def hash_password(password):
    salt = bcrypt.gensalt(rounds=8)
    return bcrypt.hashpw(password.encode('utf-8'), salt).decode('utf-8')

def verify_password(password, hashed):
    try:
        return bcrypt.checkpw(password.encode('utf-8'), hashed.encode('utf-8'))
    except Exception as e:
        logging.error(f"Error verificando contraseña: {e}")
        return False

def is_bcrypt_hash(value):
    if not value:
        return False
    return value.startswith(('$2b$', '$2a$', '$2y$')) and len(value) == 60

def save_password_hash(hashed_password):
    try:
        os.makedirs(os.path.dirname(PASSWORD_FILE), exist_ok=True)
        with open(PASSWORD_FILE, 'w') as f:
            f.write(hashed_password)
        os.chmod(PASSWORD_FILE, 0o600)
        return True
    except Exception as e:
        logging.error(f"Error guardando hash: {e}")
        return False

def load_admin_password():
    global ADMIN_PASSWORD_HASH
    try:
        if os.path.exists(PASSWORD_FILE):
            stored = open(PASSWORD_FILE).read().strip()
            if not is_bcrypt_hash(stored):
                logging.info("Migrando contraseña de texto plano a bcrypt...")
                stored = hash_password(stored)
                save_password_hash(stored)
            ADMIN_PASSWORD_HASH = stored
        else:
            logging.info("Creando archivo de contraseña con valor por defecto...")
            ADMIN_PASSWORD_HASH = hash_password(DEFAULT_PASSWORD)
            save_password_hash(ADMIN_PASSWORD_HASH)
    except Exception as e:
        logging.error(f"Error cargando contraseña: {e}")
        ADMIN_PASSWORD_HASH = hash_password(DEFAULT_PASSWORD)

load_admin_password()

# ═══════════════════════════════════════════════════════════════
#  UTILIDADES
# ═══════════════════════════════════════════════════════════════

def get_webpanel_port():
    try:
        if os.path.exists(WEBPANEL_PORT_FILE):
            return int(open(WEBPANEL_PORT_FILE).read().strip())
    except:
        pass
    return 9000

class User(UserMixin):
    def __init__(self, id): self.id = id

@login_manager.user_loader
def load_user(user_id): return User(user_id)

def get_service_status(svc, port):
    try:
        result = subprocess.run([SYSTEMCTL, 'is-active', f"{svc}@{port}.service"], 
                              capture_output=True, text=True)
        return result.returncode == 0 and "active" in result.stdout
    except:
        return False

def get_users():
    users = []
    if os.path.exists("/etc/hex/users.txt"):
        try:
            with open("/etc/hex/users.txt", "r") as f:
                for line in f:
                    parts = line.strip().split(":")
                    if len(parts) == 3: 
                        users.append({"user": parts[0], "exp": parts[2]})
        except Exception as e:
            logging.error(f"Error leyendo users.txt: {e}")
    return users

# ═══════════════════════════════════════════════════════════════
#  COMPARACIÓN SEMÁNTICA DE VERSIONES
# ═══════════════════════════════════════════════════════════════

def compare_versions(v1, v2):
    try:
        def normalize(v):
            parts = []
            for p in v.strip().split('.'):
                num = ''
                for c in p:
                    if c.isdigit(): num += c
                    else: break
                parts.append(int(num) if num else 0)
            return parts
        
        p1 = normalize(v1)
        p2 = normalize(v2)
        max_len = max(len(p1), len(p2))
        p1.extend([0] * (max_len - len(p1)))
        p2.extend([0] * (max_len - len(p2)))
        
        for a, b in zip(p1, p2):
            if a > b: return 1
            if a < b: return -1
        return 0
    except Exception as e:
        logging.error(f"Error comparando versiones {v1} vs {v2}: {e}")
        return 0

# ═══════════════════════════════════════════════════════════════
#  SISTEMA DE ACTUALIZACIONES
# ═══════════════════════════════════════════════════════════════

def get_local_version():
    try:
        if os.path.exists(VERSION_FILE):
            return open(VERSION_FILE).read().strip()
    except:
        pass
    return "1.0.0"

def check_updates():
    try:
        if os.path.exists(UPDATE_CACHE_FILE):
            cache_age = time.time() - os.path.getmtime(UPDATE_CACHE_FILE)
            if cache_age < CACHE_DURATION:
                with open(UPDATE_CACHE_FILE, 'r') as f:
                    return json.load(f)
        
        local_version = get_local_version()
        import urllib.request
        req = urllib.request.Request(
            f"{GITHUB_RAW}/version.json",
            headers={'User-Agent': 'HexWebPanel/1.0'}
        )
        with urllib.request.urlopen(req, timeout=3) as response:
            remote_data = json.loads(response.read().decode())
        
        remote_version = remote_data.get('version', local_version)
        changelog = remote_data.get('changelog', 'Nuevas mejoras disponibles')
        
        version_comparison = compare_versions(remote_version, local_version)
        has_update = version_comparison == 1
        is_older = version_comparison == -1
        
        result = {
            "has_update": has_update,
            "local_version": local_version,
            "remote_version": remote_version,
            "changelog": changelog,
            "checked_at": datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
            "is_newer": has_update,
            "is_older": is_older
        }
        
        with open(UPDATE_CACHE_FILE, 'w') as f:
            json.dump(result, f)
        
        return result
    except Exception as e:
        logging.error(f"Error verificando actualizaciones: {e}")
        return {
            "has_update": False,
            "local_version": get_local_version(),
            "remote_version": get_local_version(),
            "changelog": "",
            "checked_at": "",
            "is_newer": False,
            "is_older": False,
            "error": True
        }

def invalidate_update_cache():
    try:
        if os.path.exists(UPDATE_CACHE_FILE):
            os.remove(UPDATE_CACHE_FILE)
    except:
        pass

def schedule_restart():
    def restart_later():
        time.sleep(2)
        try:
            subprocess.run([SYSTEMCTL, 'restart', 'hex-webpanel.service'], 
                          capture_output=True, timeout=10)
        except:
            pass
    thread = threading.Thread(target=restart_later, daemon=True)
    thread.start()

def perform_update():
    results = {
        "menu": {"success": False, "message": ""},
        "templates": {"success": False, "message": ""},
        "backend": {"success": False, "message": ""},
        "version": {"success": False, "message": ""}
    }
    timestamp = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
    
    # Preservar archivo de contraseña
    password_backup = None
    if os.path.exists(PASSWORD_FILE):
        with open(PASSWORD_FILE, 'r') as f:
            password_backup = f.read()
    
    # 1. Actualizar menú
    try:
        menu_backup = f"/usr/local/bin/hex_menu.backup.{timestamp}"
        if os.path.exists("/usr/local/bin/hex_menu"):
            subprocess.run([CP, '/usr/local/bin/hex_menu', menu_backup], capture_output=True)
        res = subprocess.run([CURL, '-fsSL', f"{GITHUB_RAW}/hex_menu.sh", '-o', '/tmp/hex_menu_new.sh'],
                           capture_output=True, text=True, timeout=30)
        if res.returncode == 0 and os.path.exists('/tmp/hex_menu_new.sh'):
            syntax_check = subprocess.run([BASH, '-n', '/tmp/hex_menu_new.sh'], capture_output=True)
            if syntax_check.returncode == 0:
                subprocess.run([MV, '/tmp/hex_menu_new.sh', '/usr/local/bin/hex_menu'], capture_output=True)
                os.chmod('/usr/local/bin/hex_menu', 0o755)
                results["menu"] = {"success": True, "message": "Menú actualizado"}
            else:
                results["menu"] = {"success": False, "message": "Error de sintaxis"}
        else:
            results["menu"] = {"success": False, "message": "Error de descarga"}
    except Exception as e:
        results["menu"] = {"success": False, "message": str(e)}
    
    # 2. Actualizar templates
    try:
        templates_dir = "/opt/hex-webpanel/templates"
        if os.path.exists(templates_dir):
            backup_dir = f"{templates_dir}.backup.{timestamp}"
            subprocess.run([CP, '-r', templates_dir, backup_dir], capture_output=True)
            login_ok = subprocess.run([CURL, '-fsSL', f"{GITHUB_RAW}/templates/login.html", 
                                      '-o', f"{templates_dir}/login.html"], capture_output=True, timeout=30).returncode == 0
            dash_ok = subprocess.run([CURL, '-fsSL', f"{GITHUB_RAW}/templates/dashboard.html", 
                                     '-o', f"{templates_dir}/dashboard.html"], capture_output=True, timeout=30).returncode == 0
            if login_ok and dash_ok:
                results["templates"] = {"success": True, "message": "Templates actualizados"}
            else:
                results["templates"] = {"success": False, "message": "Error en algunos templates"}
        else:
            results["templates"] = {"success": True, "message": "Panel no instalado, omitido"}
    except Exception as e:
        results["templates"] = {"success": False, "message": str(e)}
    
    # 3. Actualizar backend
    try:
        if os.path.exists("/opt/hex-webpanel/app.py"):
            app_backup = f"/opt/hex-webpanel/app.py.backup.{timestamp}"
            subprocess.run([CP, '/opt/hex-webpanel/app.py', app_backup], capture_output=True)
            res = subprocess.run([CURL, '-fsSL', f"{GITHUB_RAW}/app.py", '-o', '/tmp/app_new.py'],
                               capture_output=True, text=True, timeout=30)
            if res.returncode == 0 and os.path.exists('/tmp/app_new.py'):
                syntax_check = subprocess.run(['python3', '-m', 'py_compile', '/tmp/app_new.py'], capture_output=True)
                if syntax_check.returncode == 0:
                    subprocess.run([MV, '/tmp/app_new.py', '/opt/hex-webpanel/app.py'], capture_output=True)
                    results["backend"] = {"success": True, "message": "Backend actualizado"}
                else:
                    results["backend"] = {"success": False, "message": "Error de sintaxis"}
            else:
                results["backend"] = {"success": False, "message": "Error de descarga"}
        else:
            results["backend"] = {"success": True, "message": "Panel no instalado, omitido"}
    except Exception as e:
        results["backend"] = {"success": False, "message": str(e)}
    
    # 4. Actualizar versión
    try:
        res = subprocess.run([CURL, '-fsSL', f"{GITHUB_RAW}/version.json", '-o', '/tmp/version_new.json'],
                           capture_output=True, text=True, timeout=30)
        if res.returncode == 0 and os.path.exists('/tmp/version_new.json'):
            with open('/tmp/version_new.json', 'r') as f:
                version_data = json.load(f)
            new_version = version_data.get('version', '')
            if new_version:
                with open(VERSION_FILE, 'w') as f:
                    f.write(new_version)
                results["version"] = {"success": True, "message": f"Versión actualizada a {new_version}"}
            subprocess.run([RM, '/tmp/version_new.json'], capture_output=True)
        else:
            results["version"] = {"success": False, "message": "Error al obtener versión"}
    except Exception as e:
        results["version"] = {"success": False, "message": str(e)}
    
    # Restaurar archivo de contraseña si fue modificado
    if password_backup and os.path.exists(PASSWORD_FILE):
        with open(PASSWORD_FILE, 'r') as f:
            current = f.read()
        if current != password_backup:
            with open(PASSWORD_FILE, 'w') as f:
                f.write(password_backup)
            logging.info("Archivo de contraseña restaurado después de actualización")
    
    invalidate_update_cache()
    logging.info(f"Actualización completada: {results}")
    return results
    
def get_stats_data():
    try:
        bhttp_ports = open("/etc/hex/bhttp_ports.conf").read().splitlines() if os.path.exists("/etc/hex/bhttp_ports.conf") else []
        hcr_ports = open("/etc/hex/hcr_ports.conf").read().splitlines() if os.path.exists("/etc/hex/hcr_ports.conf") else []
        udpgw_ports = open("/etc/hex/udpgw_ports.conf").read().splitlines() if os.path.exists("/etc/hex/udpgw_ports.conf") else []
        
        bhttp_active = sum(1 for p in bhttp_ports if get_service_status("bhttp", p))
        hcr_active = sum(1 for p in hcr_ports if get_service_status("hcr", p))
        udpgw_active = sum(1 for p in udpgw_ports if get_service_status("udpgw", p))
        
        return {
            "bhttp_ports": [p for p in bhttp_ports if p.strip()],
            "hcr_ports": [p for p in hcr_ports if p.strip()],
            "udpgw_ports": [p for p in udpgw_ports if p.strip()],
            "bhttp_active": bhttp_active,
            "hcr_active": hcr_active,
            "udpgw_active": udpgw_active,
            "bhttp_online": bhttp_active > 0,
            "hcr_online": hcr_active > 0,
            "udpgw_online": udpgw_active > 0,
            "users": len(get_users()),
            "webpanel_port": get_webpanel_port(),
            "update_info": check_updates()
        }
    except Exception as e:
        logging.error(f"Error obteniendo stats: {e}")
        return None

# ═══════════════════════════════════════════════════════════════
#  RUTAS
# ═══════════════════════════════════════════════════════════════

@app.route('/login', methods=['GET', 'POST'])
def login():
    if request.method == 'POST':
        password = request.form.get('password', '')
        if ADMIN_PASSWORD_HASH and verify_password(password, ADMIN_PASSWORD_HASH):
            login_user(User("admin"))
            logging.info(f"Login exitoso desde {request.remote_addr}")
            return redirect(url_for('dashboard'))
        logging.warning(f"Intento de login fallido desde {request.remote_addr}")
        flash('Contraseña incorrecta')
    return render_template('login.html')

@app.route('/logout')
@login_required
def logout(): 
    logout_user()
    return redirect(url_for('login'))

@app.route('/')
@login_required
def dashboard():
    stats = get_stats_data()
    if stats is None:
        flash("Error al cargar el dashboard")
        stats = {
            "bhttp_ports":[], "hcr_ports":[], "udpgw_ports":[],
            "bhttp_active":0, "hcr_active":0, "udpgw_active":0,
            "bhttp_online":False, "hcr_online":False, "udpgw_online":False,
            "users":0, "webpanel_port":9000,
            "update_info": {"has_update": False, "local_version": "1.0.0", 
                          "remote_version": "1.0.0", "changelog": "", "checked_at": "", 
                          "is_newer": False, "is_older": False, "error": True}
        }
    return render_template('dashboard.html', stats=stats, users=get_users())

@app.route('/api/stats')
@login_required
def api_stats():
    stats = get_stats_data()
    if stats is None:
        return jsonify({"error": "No se pudieron obtener las estadísticas"}), 500
    return jsonify(stats)

@app.route('/change_password', methods=['POST'])
@login_required
def change_password():
    global ADMIN_PASSWORD_HASH
    try:
        current_pass = request.form.get('current_password', '')
        new_pass = request.form.get('new_password', '')
        confirm_pass = request.form.get('confirm_password', '')
        
        logging.info(f"[CHANGE_PASS] Solicitud desde {request.remote_addr}")
        
        if not new_pass or len(new_pass) < 4:
            flash("La nueva contraseña debe tener al menos 4 caracteres")
            return redirect(url_for('dashboard'))
        if new_pass != confirm_pass:
            flash("Las contraseñas nuevas no coinciden")
            return redirect(url_for('dashboard'))
        if not verify_password(current_pass, ADMIN_PASSWORD_HASH):
            flash("La contraseña actual es incorrecta")
            return redirect(url_for('dashboard'))
        if verify_password(new_pass, ADMIN_PASSWORD_HASH):
            flash("La nueva contraseña debe ser diferente a la actual")
            return redirect(url_for('dashboard'))
        
        new_hash = hash_password(new_pass)
        if save_password_hash(new_hash):
            ADMIN_PASSWORD_HASH = new_hash
            logging.info("[CHANGE_PASS] ✓ Contraseña cambiada exitosamente")
            flash("✓ Contraseña cambiada exitosamente. Cierra sesión para aplicar los cambios.")
        else:
            flash("Error al guardar la contraseña")
    except Exception as e:
        logging.error(f"[CHANGE_PASS] Error: {e}", exc_info=True)
        flash(f"Error: {str(e)}")
    return redirect(url_for('dashboard'))

@app.route('/update_now', methods=['POST'])
@login_required
def update_now():
    try:
        logging.info("Iniciando actualización desde el panel web")
        results = perform_update()
        
        if results["backend"]["success"] or results["templates"]["success"]:
            schedule_restart()
            restart_msg = "El panel se reiniciará automáticamente en unos segundos."
        else:
            restart_msg = ""
        
        success_count = sum(1 for k, v in results.items() if v["success"])
        total_count = len(results)
        
        return jsonify({
            "success": True,
            "message": f"Actualización completada: {success_count}/{total_count} componentes",
            "details": results,
            "restart": restart_msg,
            "will_reload": results["backend"]["success"] or results["templates"]["success"]
        })
    except Exception as e:
        logging.error(f"Error en actualización: {e}", exc_info=True)
        return jsonify({"success": False, "message": f"Error: {str(e)}"}), 500

@app.route('/add_user', methods=['POST'])
@login_required
def add_user():
    try:
        user = request.form['username'].strip().lower()
        pwd = request.form['password']
        days = int(request.form['days'])
        
        if not user or not pwd or days < 1:
            flash("Todos los campos son obligatorios y los días deben ser positivos")
            return redirect(url_for('dashboard'))
        if not user.isalnum() and not all(c.isalnum() or c in '_-' for c in user):
            flash("El usuario solo puede contener letras, números, guiones y guiones bajos")
            return redirect(url_for('dashboard'))
        
        check_user = subprocess.run([ID, user], capture_output=True, text=True)
        if check_user.returncode == 0:
            flash(f"El usuario '{user}' ya existe en el sistema")
            return redirect(url_for('dashboard'))
        
        check_group = subprocess.run([GETENT, 'group', 'hexusers'], capture_output=True, text=True)
        if check_group.returncode != 0:
            subprocess.run([GROUPADD, 'hexusers'], capture_output=True)
        
        exp_date = (datetime.datetime.now() + datetime.timedelta(days=days)).strftime("%Y-%m-%d")
        
        res = subprocess.run([USERADD, '-m', '-s', '/bin/bash', '-G', 'hexusers', user], 
                           capture_output=True, text=True)
        if res.returncode != 0:
            flash(f"Error al crear usuario: {res.stderr}")
            return redirect(url_for('dashboard'))
        
        res_pwd = subprocess.run([CHPASSWD], input=f"{user}:{pwd}", text=True, capture_output=True)
        if res_pwd.returncode != 0:
            flash(f"Error al establecer contraseña: {res_pwd.stderr}")
            subprocess.run([USERDEL, '-r', user], capture_output=True)
            return redirect(url_for('dashboard'))
        
        subprocess.run([CHAGE, '-E', exp_date, user], capture_output=True)
        subprocess.run([USERMOD, '-e', exp_date, user], capture_output=True)
        
        with open("/etc/hex/users.txt", "a") as f: 
            f.write(f"{user}:{pwd}:{exp_date}\n")
        
        flash(f"✓ Usuario '{user}' creado exitosamente (Expira: {exp_date})")
        return redirect(url_for('dashboard'))
    except ValueError:
        flash("Error: Los días deben ser un número válido")
        return redirect(url_for('dashboard'))
    except Exception as e:
        logging.error(f"Error creando usuario: {str(e)}", exc_info=True)
        flash(f"Error inesperado: {str(e)}")
        return redirect(url_for('dashboard'))

@app.route('/delete_user/<username>')
@login_required
def delete_user(username):
    try:
        subprocess.run([USERDEL, '-r', username], capture_output=True)
        if os.path.exists("/etc/hex/users.txt"):
            with open("/etc/hex/users.txt", "r") as f:
                lines = f.readlines()
            with open("/etc/hex/users.txt", "w") as f:
                for line in lines:
                    if not line.startswith(f"{username}:"):
                        f.write(line)
        flash(f"✓ Usuario '{username}' eliminado correctamente")
    except Exception as e:
        logging.error(f"Error eliminando usuario: {e}")
        flash(f"Error al eliminar usuario: {str(e)}")
    return redirect(url_for('dashboard'))

@app.route('/edit_password/<username>', methods=['POST'])
@login_required
def edit_password(username):
    """Cambia la contraseña de un usuario desde el dashboard"""
    try:
        new_pass = request.form.get('new_password', '')
        confirm_pass = request.form.get('confirm_password', '')
        
        logging.info(f"[EDIT_PASS] Cambio de contraseña para {username} desde {request.remote_addr}")
        
        if not new_pass or len(new_pass) < 4:
            flash("La contraseña debe tener al menos 4 caracteres")
            return redirect(url_for('dashboard'))
        
        if new_pass != confirm_pass:
            flash("Las contraseñas no coinciden")
            return redirect(url_for('dashboard'))
        
        check_user = subprocess.run([ID, username], capture_output=True, text=True)
        if check_user.returncode != 0:
            flash(f"El usuario '{username}' no existe")
            return redirect(url_for('dashboard'))
        
        res_pwd = subprocess.run([CHPASSWD], input=f"{username}:{new_pass}", 
                                text=True, capture_output=True)
        if res_pwd.returncode != 0:
            flash(f"Error al cambiar contraseña: {res_pwd.stderr}")
            return redirect(url_for('dashboard'))
        
        if os.path.exists("/etc/hex/users.txt"):
            with open("/etc/hex/users.txt", "r") as f:
                lines = f.readlines()
            with open("/etc/hex/users.txt", "w") as f:
                for line in lines:
                    if line.startswith(f"{username}:"):
                        parts = line.strip().split(":")
                        if len(parts) == 3:
                            f.write(f"{username}:{new_pass}:{parts[2]}\n")
                        else:
                            f.write(line)
                    else:
                        f.write(line)
        
        logging.info(f"[EDIT_PASS] ✓ Contraseña de {username} cambiada")
        flash(f"✓ Contraseña de '{username}' cambiada exitosamente")
        
    except Exception as e:
        logging.error(f"[EDIT_PASS] Error: {e}", exc_info=True)
        flash(f"Error: {str(e)}")
    
    return redirect(url_for('dashboard'))

@app.route('/edit_expiry/<username>', methods=['POST'])
@login_required
def edit_expiry(username):
    """Cambia la fecha de expiración de un usuario desde el dashboard"""
    try:
        action = request.form.get('action', '')
        
        logging.info(f"[EDIT_EXP] Cambio de expiración para {username} desde {request.remote_addr}")
        
        check_user = subprocess.run([ID, username], capture_output=True, text=True)
        if check_user.returncode != 0:
            flash(f"El usuario '{username}' no existe")
            return redirect(url_for('dashboard'))
        
        new_exp = ""
        
        if action == "permanent":
            subprocess.run([CHAGE, '-E', '-1', username], capture_output=True)
            subprocess.run([USERMOD, '-e', '', username], capture_output=True)
            new_exp = "2099-12-31"
            flash(f"✓ Usuario '{username}' ahora es permanente")
            
        elif action == "custom":
            custom_date = request.form.get('custom_date', '')
            if not custom_date:
                flash("Debes ingresar una fecha")
                return redirect(url_for('dashboard'))
            new_exp = custom_date
            subprocess.run([CHAGE, '-E', new_exp, username], capture_output=True)
            subprocess.run([USERMOD, '-e', new_exp, username], capture_output=True)
            flash(f"✓ Expiración de '{username}' cambiada a {new_exp}")
            
        elif action.startswith("extend_"):
            days = int(action.split("_")[1])
            
            current_exp = ""
            if os.path.exists("/etc/hex/users.txt"):
                with open("/etc/hex/users.txt", "r") as f:
                    for line in f:
                        if line.startswith(f"{username}:"):
                            parts = line.strip().split(":")
                            if len(parts) == 3:
                                current_exp = parts[2]
                            break
            
            current_timestamp = int(time.time())
            exp_timestamp = 0
            try:
                exp_timestamp = int(datetime.datetime.strptime(current_exp, "%Y-%m-%d").timestamp())
            except:
                pass
            
            if exp_timestamp < current_timestamp:
                new_exp = (datetime.datetime.now() + datetime.timedelta(days=days)).strftime("%Y-%m-%d")
            else:
                new_exp = (datetime.datetime.strptime(current_exp, "%Y-%m-%d") + datetime.timedelta(days=days)).strftime("%Y-%m-%d")
            
            subprocess.run([CHAGE, '-E', new_exp, username], capture_output=True)
            subprocess.run([USERMOD, '-e', new_exp, username], capture_output=True)
            flash(f"✓ Expiración de '{username}' extendida a {new_exp} (+{days} días)")
            
        else:
            flash("Acción inválida")
            return redirect(url_for('dashboard'))
        
        if new_exp and os.path.exists("/etc/hex/users.txt"):
            with open("/etc/hex/users.txt", "r") as f:
                lines = f.readlines()
            with open("/etc/hex/users.txt", "w") as f:
                for line in lines:
                    if line.startswith(f"{username}:"):
                        parts = line.strip().split(":")
                        if len(parts) == 3:
                            f.write(f"{username}:{parts[1]}:{new_exp}\n")
                        else:
                            f.write(line)
                    else:
                        f.write(line)
        
        logging.info(f"[EDIT_EXP] ✓ Expiración de {username} cambiada a {new_exp}")
        
    except Exception as e:
        logging.error(f"[EDIT_EXP] Error: {e}", exc_info=True)
        flash(f"Error: {str(e)}")
    
    return redirect(url_for('dashboard'))

@app.route('/control_service/<svc>/<action>')
@login_required
def control_service(svc, action):
    try:
        if svc not in ['bhttp', 'hcr', 'udpgw']:
            flash(f"Servicio inválido: {svc}")
            return redirect(url_for('dashboard'))
        if action not in ['start', 'stop', 'restart']:
            flash(f"Acción inválida: {action}")
            return redirect(url_for('dashboard'))
        
        conf_file = f"/etc/hex/{svc}_ports.conf"
        if not os.path.exists(conf_file):
            flash(f"No hay puertos configurados para {svc.upper()}")
            return redirect(url_for('dashboard'))
        
        with open(conf_file, 'r') as f:
            ports = [p.strip() for p in f.readlines() if p.strip()]
        
        if not ports:
            flash(f"No hay puertos configurados para {svc.upper()}")
            return redirect(url_for('dashboard'))
        
        success_count = 0
        error_count = 0
        for port in ports:
            service_name = f"{svc}@{port}.service"
            result = subprocess.run([SYSTEMCTL, action, service_name], capture_output=True, text=True)
            if result.returncode == 0:
                success_count += 1
            else:
                error_count += 1
        
        if error_count == 0:
            flash(f"✓ {svc.upper()}: {action.capitalize()} exitoso en {success_count} puerto(s)")
        else:
            flash(f"⚠ {svc.upper()}: {success_count} exitoso(s), {error_count} error(es)")
    except Exception as e:
        logging.error(f"Error controlando servicio: {e}")
        flash(f"Error: {str(e)}")
    return redirect(url_for('dashboard'))

if __name__ == '__main__':
    web_port = get_webpanel_port()
    app.run(host='0.0.0.0', port=web_port, debug=False)