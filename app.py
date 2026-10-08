#!/usr/bin/env python3
# ═══════════════════════════════════════════════════════════════
#  HEX WEB PANEL - backend (v1.1.3)
#  Repositório: https://github.com/PhoenixxZ2023/TURBONET-BHTTP
#
#  Mudanças de segurança em relação à v1.0.1:
#   - secret_key aleatória e persistente (antes: fixa e pública)
#   - senha inicial aleatória (antes: admin26) + bcrypt custo 12
#   - limite de tentativas de login por IP
#   - cookie de sessão HttpOnly + SameSite=Strict + checagem de Origin
#   - todas as rotas de usuário só operam em contas gerenciadas (users.txt)
#   - validação de usuário/senha/data; sem ':' ou quebras de linha
#   - gravação atômica de users.txt (+ trava de arquivo)
#   - OTA com arquivos temporários privados e verificação SHA256
#   - system_stats (CPU/RAM/disco) exigido pelo dashboard.html
#   v1.1.1: ações que alteram estado (delete_user, control_service, logout)
#           agora são POST; token CSRF obrigatório em todo POST
#   v1.1.2: HTTPS nativo opcional (HEX_PANEL_TLS=1 + /etc/hex/webpanel_tls/);
#           use `hex_panel_mode.sh https` em vez de editar arquivos à mão
# ═══════════════════════════════════════════════════════════════
import os, re, json, time, hashlib, hmac, secrets, logging, tempfile, threading
import subprocess, datetime, fcntl, shutil, urllib.request, ssl, sys
from urllib.parse import urlparse

from flask import Flask, render_template, request, redirect, url_for, flash, jsonify, abort, session
from flask_login import LoginManager, UserMixin, login_user, login_required, logout_user
import bcrypt

try:
    import psutil
except ImportError:  # o painel funciona sem psutil, só sem os gráficos
    psutil = None

# ───────────────────────── caminhos / constantes ─────────────────────────
HEX_DIR = os.environ.get("HEX_DIR", "/etc/hex")
LOG_FILE = os.environ.get("HEX_LOG", "/var/log/hex-webpanel.log")
PANEL_DIR = os.environ.get("HEX_PANEL_DIR", "/opt/hex-webpanel")
MENU_PATH = os.environ.get("HEX_MENU_PATH", "/usr/local/bin/hex_menu")
CLEANUP_PATH = os.environ.get("HEX_CLEANUP_PATH", "/usr/local/bin/hex_cleanup.sh")
MODE_PATH = os.environ.get("HEX_MODE_PATH", "/usr/local/bin/hex_panel_mode.sh")
IP_PATH = os.environ.get("HEX_IP_PATH", "/usr/local/bin/hex_ip.sh")
GITHUB_RAW = os.environ.get(
    "HEX_GITHUB_RAW",
    "https://raw.githubusercontent.com/PhoenixxZ2023/TURBONET-BHTTP/main")

USER_DB = os.path.join(HEX_DIR, "users.txt")
USER_DB_LOCK = os.path.join(HEX_DIR, ".users.lock")
PASSWORD_FILE = os.path.join(HEX_DIR, "webpanel_admin_pass.conf")
INITIAL_PASS_FILE = os.path.join(HEX_DIR, "webpanel_initial_password.txt")
SECRET_FILE = os.path.join(HEX_DIR, "webpanel_secret.key")
WEBPANEL_PORT_FILE = os.path.join(HEX_DIR, "webpanel_port.conf")
VERSION_FILE = os.path.join(HEX_DIR, "version")
UPDATE_CACHE_FILE = os.path.join(HEX_DIR, "update_cache.json")
REQUIRE_CHECKSUM_FILE = os.path.join(HEX_DIR, "require_checksum")
USER_SHELL_FILE = os.path.join(HEX_DIR, "user_shell")
TLS_CERT = os.path.join(HEX_DIR, "webpanel_tls", "cert.pem")
TLS_KEY = os.path.join(HEX_DIR, "webpanel_tls", "key.pem")
TLS_ENABLED = os.environ.get("HEX_PANEL_TLS") == "1"
USER_GROUP = "hexusers"

SYSTEMCTL = '/usr/bin/systemctl'
USERADD = '/usr/sbin/useradd'
USERDEL = '/usr/sbin/userdel'
USERMOD = '/usr/sbin/usermod'
CHPASSWD = '/usr/sbin/chpasswd'
CHAGE = '/usr/bin/chage'
GROUPADD = '/usr/sbin/groupadd'
ID = '/usr/bin/id'
GETENT = '/usr/bin/getent'
PKILL = '/usr/bin/pkill'
BASH = '/bin/bash'

CACHE_DURATION = 300
SERVICES = ('bhttp', 'hcr', 'udpgw')
USERNAME_RE = re.compile(r'^[a-z_][a-z0-9_-]{0,31}$')
PORT_RE = re.compile(r'^[0-9]{1,5}$')
OLD_DEFAULT_PASSWORDS = ("admin26", "HexAdmin2026")

MAX_LOGIN_FAILS = 5
LOGIN_LOCK_SECONDS = 15 * 60

try:
    logging.basicConfig(filename=LOG_FILE, level=logging.INFO,
                        format='%(asctime)s - %(levelname)s - %(message)s')
except OSError:
    logging.basicConfig(level=logging.INFO,
                        format='%(asctime)s - %(levelname)s - %(message)s')

# ───────────────────────── utilitários de arquivo ─────────────────────────
def write_atomic(path, data, mode=0o600):
    """Grava em arquivo temporário privado no mesmo diretório e troca com rename."""
    if isinstance(data, str):
        data = data.encode('utf-8')
    d = os.path.dirname(path) or '.'
    os.makedirs(d, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=d, prefix='.tmp-')
    try:
        with os.fdopen(fd, 'wb') as f:
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, mode)
        os.replace(tmp, path)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


class DbLock:
    """Trava de processo + thread para users.txt."""
    _tl = threading.RLock()

    def __enter__(self):
        DbLock._tl.acquire()
        os.makedirs(HEX_DIR, exist_ok=True)
        self._fh = open(USER_DB_LOCK, 'a')
        fcntl.flock(self._fh, fcntl.LOCK_EX)
        return self

    def __exit__(self, *exc):
        fcntl.flock(self._fh, fcntl.LOCK_UN)
        self._fh.close()
        DbLock._tl.release()


# ───────────────────────── chave secreta e senha ─────────────────────────
def load_secret_key():
    try:
        with open(SECRET_FILE, 'rb') as f:
            key = f.read()
        if len(key) >= 32:
            return key
    except OSError:
        pass
    key = secrets.token_bytes(32)
    write_atomic(SECRET_FILE, key, 0o600)
    logging.info("Nova secret_key gerada")
    return key


def hash_password(password):
    return bcrypt.hashpw(password.encode('utf-8'), bcrypt.gensalt(rounds=12)).decode('utf-8')


def verify_password(password, hashed):
    try:
        return bcrypt.checkpw(password.encode('utf-8'), hashed.encode('utf-8'))
    except Exception as e:
        logging.error(f"Erro ao verificar senha: {e}")
        return False


def is_bcrypt_hash(value):
    return bool(value) and value.startswith(('$2b$', '$2a$', '$2y$')) and len(value) == 60


def save_password_hash(hashed):
    try:
        write_atomic(PASSWORD_FILE, hashed, 0o600)
        return True
    except Exception as e:
        logging.error(f"Erro ao salvar hash: {e}")
        return False


def load_admin_password():
    """Carrega o hash. Migra texto puro; se não existir, gera senha inicial aleatória."""
    try:
        if os.path.exists(PASSWORD_FILE):
            with open(PASSWORD_FILE) as f:
                stored = f.read().strip()
            if not is_bcrypt_hash(stored):
                logging.info("Migrando senha de texto plano para bcrypt...")
                stored = hash_password(stored)
                save_password_hash(stored)
            return stored
        initial = secrets.token_urlsafe(9)  # 12 caracteres
        hashed = hash_password(initial)
        save_password_hash(hashed)
        write_atomic(INITIAL_PASS_FILE,
                     f"Senha inicial do painel: {initial}\n"
                     "Troque no dashboard; este arquivo é apagado quando você trocar.\n", 0o600)
        logging.info(f"Senha inicial gerada em {INITIAL_PASS_FILE}")
        return hashed
    except Exception as e:
        logging.error(f"Erro ao carregar senha: {e}")
        raise


# ───────────────────────── app / sessão ─────────────────────────
app = Flask(__name__)
app.secret_key = load_secret_key()
app.config.update(
    SESSION_COOKIE_NAME="hex_session",
    SESSION_COOKIE_HTTPONLY=True,
    SESSION_COOKIE_SAMESITE="Strict",
    SESSION_COOKIE_SECURE=TLS_ENABLED or os.environ.get("HEX_PANEL_HTTPS") == "1",
    MAX_CONTENT_LENGTH=64 * 1024,
)
login_manager = LoginManager()
login_manager.init_app(app)
login_manager.login_view = 'login'
ADMIN_PASSWORD_HASH = load_admin_password()

TRUSTED_HOSTS = {h.strip() for h in os.environ.get("HEX_TRUSTED_HOSTS", "").split(",") if h.strip()}


class User(UserMixin):
    def __init__(self, id):
        self.id = id


@login_manager.user_loader
def load_user(user_id):
    return User(user_id) if user_id == "admin" else None


def csrf_token():
    """Token CSRF por sessão (usado nos templates via {{ csrf_token() }})."""
    tok = session.get("_csrf")
    if not tok:
        tok = secrets.token_urlsafe(32)
        session["_csrf"] = tok
    return tok


@app.context_processor
def inject_csrf():
    return {"csrf_token": csrf_token}


@app.before_request
def check_csrf():
    """Em todo POST/PUT/PATCH/DELETE: Origin coerente + token CSRF válido."""
    if request.method in ("POST", "PUT", "PATCH", "DELETE"):
        origin = request.headers.get("Origin") or request.headers.get("Referer")
        if origin:
            host = urlparse(origin).netloc
            if host != request.host and host not in TRUSTED_HOSTS:
                logging.warning(f"Origin bloqueada: {origin!r} de {request.remote_addr}")
                abort(403)
        sent = request.form.get("csrf_token") or request.headers.get("X-CSRF-Token") or ""
        expected = session.get("_csrf", "")
        if not expected or not hmac.compare_digest(sent.encode("utf-8"), expected.encode("utf-8")):
            logging.warning(f"CSRF inválido em {request.path} de {request.remote_addr}")
            abort(403)


@app.errorhandler(403)
def forbidden(_e):
    msg = "Requisição bloqueada (sessão expirada ou origem inválida). Recarregue a página."
    if request.path == "/update_now":
        return jsonify({"success": False, "message": msg}), 403
    return f"<h3>403 - {msg}</h3><p><a href='/'>Voltar</a></p>", 403


@app.after_request
def security_headers(resp):
    resp.headers.setdefault("X-Frame-Options", "DENY")
    resp.headers.setdefault("X-Content-Type-Options", "nosniff")
    resp.headers.setdefault("Referrer-Policy", "same-origin")
    resp.headers.setdefault("Cache-Control", "no-store")
    return resp


# ───────────────────────── limite de tentativas de login ─────────────────────────
_fails = {}
_fails_lock = threading.Lock()


def login_blocked(ip):
    with _fails_lock:
        info = _fails.get(ip)
        if info and info["until"] > time.time():
            return int(info["until"] - time.time())
    return 0


def register_fail(ip):
    with _fails_lock:
        info = _fails.setdefault(ip, {"count": 0, "until": 0})
        if info["until"] and info["until"] <= time.time():
            info["count"], info["until"] = 0, 0
        info["count"] += 1
        if info["count"] >= MAX_LOGIN_FAILS:
            info["until"] = time.time() + LOGIN_LOCK_SECONDS


def clear_fails(ip):
    with _fails_lock:
        _fails.pop(ip, None)


# ───────────────────────── validação ─────────────────────────
def valid_username(u):
    return bool(USERNAME_RE.match(u or ''))


def valid_user_password(p):
    if not p or not (4 <= len(p) <= 64):
        return False
    return not any(c == ':' or ord(c) < 32 or ord(c) == 127 for c in p)


def valid_date(s):
    try:
        datetime.datetime.strptime(s, "%Y-%m-%d")
        return True
    except (ValueError, TypeError):
        return False


def get_user_shell():
    try:
        with open(USER_SHELL_FILE) as f:
            sh = f.read().strip()
        if sh in ('/bin/bash', '/bin/sh', '/bin/false', '/usr/sbin/nologin'):
            return sh
    except OSError:
        pass
    return '/bin/bash'


# ───────────────────────── banco de usuários (users.txt) ─────────────────────────
def _parse_line(line):
    """user:senha:exp. Tolera ':' dentro da senha (entradas antigas)."""
    line = line.rstrip('\n')
    if not line or ':' not in line:
        return None
    user, rest = line.split(':', 1)
    if ':' not in rest:
        return None
    pwd, exp = rest.rsplit(':', 1)
    if not user:
        return None
    return user, pwd, exp


def read_db():
    entries = []
    try:
        with open(USER_DB) as f:
            for line in f:
                e = _parse_line(line)
                if e:
                    entries.append(e)
    except FileNotFoundError:
        pass
    except Exception as e:
        logging.error(f"Erro ao ler users.txt: {e}")
    return entries


def write_db(entries):
    write_atomic(USER_DB, ''.join(f"{u}:{p}:{e}\n" for u, p, e in entries), 0o600)


def db_has(username):
    return any(u == username for u, _, _ in read_db())


def get_users():
    return [{"user": u, "exp": e} for u, _, e in read_db()]


# ───────────────────────── comandos do sistema ─────────────────────────
def run(cmd, **kw):
    kw.setdefault('capture_output', True)
    kw.setdefault('text', True)
    kw.setdefault('timeout', 20)
    return subprocess.run(cmd, **kw)


def system_user_exists(user):
    return run([ID, user]).returncode == 0


def set_expiry(user, exp_date):
    if exp_date == "2099-12-31":
        run([CHAGE, '-E', '-1', user])
        run([USERMOD, '-e', '', user])
    else:
        run([CHAGE, '-E', exp_date, user])
        run([USERMOD, '-e', exp_date, user])


def get_service_status(svc, port):
    try:
        r = run([SYSTEMCTL, 'is-active', f"{svc}@{port}.service"], timeout=5)
        return r.returncode == 0 and "active" in r.stdout
    except Exception:
        return False


def read_ports(svc):
    path = os.path.join(HEX_DIR, f"{svc}_ports.conf")
    try:
        with open(path) as f:
            return [p.strip() for p in f if PORT_RE.match(p.strip())]
    except OSError:
        return []


def get_webpanel_port():
    try:
        with open(WEBPANEL_PORT_FILE) as f:
            p = int(f.read().strip())
        if 1 <= p <= 65535:
            return p
    except Exception:
        pass
    return 9000


# ───────────────────────── métricas do sistema ─────────────────────────
def _level(percent):
    return "success" if percent < 60 else ("warning" if percent < 85 else "danger")


def get_system_stats():
    zero = {"percent": 0, "color": "secondary"}
    if psutil is None:
        return {"cpu": dict(zero, cores=os.cpu_count() or 1),
                "ram": dict(zero, used_gb=0, total_gb=0),
                "disk": dict(zero, used_gb=0, total_gb=0)}
    try:
        cpu = psutil.cpu_percent(interval=0.1)
        vm = psutil.virtual_memory()
        du = psutil.disk_usage('/')
        gb = 1024 ** 3
        return {
            "cpu": {"percent": round(cpu, 1), "cores": psutil.cpu_count(logical=True) or 1,
                    "color": _level(cpu)},
            "ram": {"percent": round(vm.percent, 1), "used_gb": round(vm.used / gb, 2),
                    "total_gb": round(vm.total / gb, 2), "color": _level(vm.percent)},
            "disk": {"percent": round(du.percent, 1), "used_gb": round(du.used / gb, 1),
                     "total_gb": round(du.total / gb, 1), "color": _level(du.percent)},
        }
    except Exception as e:
        logging.error(f"Erro ao obter métricas: {e}")
        return {"cpu": dict(zero, cores=os.cpu_count() or 1),
                "ram": dict(zero, used_gb=0, total_gb=0),
                "disk": dict(zero, used_gb=0, total_gb=0)}


# ───────────────────────── versões / OTA ─────────────────────────
def compare_versions(v1, v2):
    def normalize(v):
        parts = []
        for p in str(v).strip().split('.'):
            num = ''
            for c in p:
                if c.isdigit():
                    num += c
                else:
                    break
            parts.append(int(num) if num else 0)
        return parts
    try:
        p1, p2 = normalize(v1), normalize(v2)
        n = max(len(p1), len(p2))
        p1 += [0] * (n - len(p1))
        p2 += [0] * (n - len(p2))
        return (p1 > p2) - (p1 < p2)
    except Exception as e:
        logging.error(f"Erro ao comparar versões {v1} vs {v2}: {e}")
        return 0


def get_local_version():
    try:
        with open(VERSION_FILE) as f:
            return f.read().strip() or "1.0.0"
    except OSError:
        return "1.0.0"


def http_get(url, limit=3 * 1024 * 1024, timeout=15):
    req = urllib.request.Request(url, headers={'User-Agent': 'HexWebPanel/1.1'})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        data = resp.read(limit + 1)
    if len(data) > limit:
        raise ValueError("arquivo remoto maior que o limite")
    return data


def check_updates():
    local = get_local_version()
    try:
        if os.path.exists(UPDATE_CACHE_FILE) and \
                time.time() - os.path.getmtime(UPDATE_CACHE_FILE) < CACHE_DURATION:
            with open(UPDATE_CACHE_FILE) as f:
                cached = json.load(f)
            cmp_ = compare_versions(cached.get("remote_version", local), local)
            cached.update(local_version=local, has_update=cmp_ == 1,
                          is_newer=cmp_ == 1, is_older=cmp_ == -1)
            return cached
        remote = json.loads(http_get(f"{GITHUB_RAW}/version.json", timeout=3).decode())
        rv = str(remote.get('version', local))
        cmp_ = compare_versions(rv, local)
        result = {"has_update": cmp_ == 1, "local_version": local, "remote_version": rv,
                  "changelog": str(remote.get('changelog', 'Novas melhorias disponíveis')),
                  "checked_at": datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
                  "is_newer": cmp_ == 1, "is_older": cmp_ == -1}
        write_atomic(UPDATE_CACHE_FILE, json.dumps(result), 0o644)
        return result
    except Exception as e:
        logging.error(f"Erro ao verificar atualizações: {e}")
        return {"has_update": False, "local_version": local, "remote_version": local,
                "changelog": "", "checked_at": "", "is_newer": False, "is_older": False,
                "error": True}


def invalidate_update_cache():
    try:
        os.remove(UPDATE_CACHE_FILE)
    except OSError:
        pass


def schedule_restart():
    def restart_later():
        time.sleep(2)
        try:
            run([SYSTEMCTL, 'restart', 'hex-webpanel.service'], timeout=10)
        except Exception:
            pass
    threading.Thread(target=restart_later, daemon=True).start()


def fetch_verified(relpath, manifest):
    """Baixa um arquivo do repositório e confere o SHA256 do version.json."""
    data = http_get(f"{GITHUB_RAW}/{relpath}")
    expected = (manifest.get("sha256") or {}).get(relpath)
    if expected:
        got = hashlib.sha256(data).hexdigest()
        if not hmac.compare_digest(got, expected.lower()):
            raise ValueError(f"SHA256 não confere para {relpath}")
    elif os.path.exists(REQUIRE_CHECKSUM_FILE):
        raise ValueError(f"sem SHA256 no version.json para {relpath}")
    else:
        logging.warning(f"version.json sem SHA256 para {relpath}; seguindo sem verificação")
    return data


def check_syntax(kind, data, name):
    if kind == "sh":
        r = subprocess.run([BASH, '-n'], input=data, capture_output=True, timeout=10)
        if r.returncode != 0:
            raise ValueError(f"erro de sintaxe em {name}")
    elif kind == "py":
        compile(data, name, 'exec')
    elif kind == "html":
        app.jinja_env.parse(data.decode('utf-8'))


def install_file(dest, data, mode, backup_stamp):
    if os.path.exists(dest):
        shutil.copy2(dest, f"{dest}.backup.{backup_stamp}")
    write_atomic(dest, data, mode)


def perform_update():
    results = {k: {"success": False, "message": ""} for k in ("menu", "templates", "backend", "version")}
    stamp = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
    try:
        manifest = json.loads(http_get(f"{GITHUB_RAW}/version.json", timeout=10).decode())
    except Exception as e:
        for k in results:
            results[k]["message"] = f"Erro ao baixar version.json: {e}"
        return results

    # 1. menu (+ script de limpeza)
    try:
        if os.path.exists(MENU_PATH):
            data = fetch_verified("hex_menu.sh", manifest)
            check_syntax("sh", data, "hex_menu.sh")
            install_file(MENU_PATH, data, 0o755, stamp)
            if os.path.exists(CLEANUP_PATH):
                try:
                    c = fetch_verified("hex_cleanup.sh", manifest)
                    check_syntax("sh", c, "hex_cleanup.sh")
                    install_file(CLEANUP_PATH, c, 0o755, stamp)
                except Exception as e:
                    logging.warning(f"hex_cleanup.sh não atualizado: {e}")
            try:
                ipd = fetch_verified("hex_ip.sh", manifest)
                check_syntax("sh", ipd, "hex_ip.sh")
                install_file(IP_PATH, ipd, 0o755, stamp)
            except Exception as e:
                logging.warning(f"hex_ip.sh não atualizado: {e}")
            try:
                pm = fetch_verified("hex_panel_mode.sh", manifest)
                check_syntax("sh", pm, "hex_panel_mode.sh")
                install_file(MODE_PATH, pm, 0o755, stamp)
            except Exception as e:
                logging.warning(f"hex_panel_mode.sh não atualizado: {e}")
            results["menu"] = {"success": True, "message": "Menu atualizado"}
        else:
            results["menu"] = {"success": True, "message": "Menu não instalado, ignorado"}
    except Exception as e:
        results["menu"] = {"success": False, "message": str(e)}

    # 2. templates
    try:
        tdir = os.path.join(PANEL_DIR, "templates")
        if os.path.isdir(tdir):
            blobs = {}
            for name in ("login.html", "dashboard.html"):
                d = fetch_verified(f"templates/{name}", manifest)
                check_syntax("html", d, name)
                blobs[name] = d
            for name, d in blobs.items():
                install_file(os.path.join(tdir, name), d, 0o644, stamp)
            results["templates"] = {"success": True, "message": "Templates atualizados"}
        else:
            results["templates"] = {"success": True, "message": "Painel não instalado, ignorado"}
    except Exception as e:
        results["templates"] = {"success": False, "message": str(e)}

    # 3. backend
    try:
        dest = os.path.join(PANEL_DIR, "app.py")
        if os.path.exists(dest):
            data = fetch_verified("app.py", manifest)
            check_syntax("py", data, "app.py")
            install_file(dest, data, 0o644, stamp)
            results["backend"] = {"success": True, "message": "Backend atualizado"}
        else:
            results["backend"] = {"success": True, "message": "Painel não instalado, ignorado"}
    except Exception as e:
        results["backend"] = {"success": False, "message": str(e)}

    # 4. versão
    try:
        nv = str(manifest.get('version', '')).strip()
        if nv:
            write_atomic(VERSION_FILE, nv, 0o644)
            results["version"] = {"success": True, "message": f"Versão atualizada para {nv}"}
        else:
            results["version"]["message"] = "Erro ao obter versão"
    except Exception as e:
        results["version"]["message"] = str(e)

    invalidate_update_cache()
    logging.info(f"Atualização concluída: {results}")
    return results


# ───────────────────────── dados do dashboard ─────────────────────────
def get_stats_data():
    try:
        data = {}
        for svc in SERVICES:
            ports = read_ports(svc)
            active = sum(1 for p in ports if get_service_status(svc, p))
            data[f"{svc}_ports"] = ports
            data[f"{svc}_active"] = active
            data[f"{svc}_online"] = active > 0
        data.update(users=len(get_users()), webpanel_port=get_webpanel_port(),
                    update_info=check_updates(), system_stats=get_system_stats())
        return data
    except Exception as e:
        logging.error(f"Erro ao obter stats: {e}")
        return None


def empty_stats():
    d = {}
    for svc in SERVICES:
        d.update({f"{svc}_ports": [], f"{svc}_active": 0, f"{svc}_online": False})
    d.update(users=0, webpanel_port=9000, system_stats=get_system_stats(),
             update_info={"has_update": False, "local_version": get_local_version(),
                          "remote_version": get_local_version(), "changelog": "",
                          "checked_at": "", "is_newer": False, "is_older": False, "error": True})
    return d


# ───────────────────────── rotas ─────────────────────────
@app.route('/login', methods=['GET', 'POST'])
def login():
    if request.method == 'POST':
        ip = request.remote_addr or '?'
        wait = login_blocked(ip)
        if wait:
            flash(f'Muitas tentativas. Tente de novo em {wait // 60 + 1} min.')
            return render_template('login.html'), 429
        password = request.form.get('password', '')
        if ADMIN_PASSWORD_HASH and verify_password(password, ADMIN_PASSWORD_HASH):
            clear_fails(ip)
            login_user(User("admin"))
            session["_csrf"] = secrets.token_urlsafe(32)
            logging.info(f"Login com sucesso de {ip}")
            if password in OLD_DEFAULT_PASSWORDS:
                flash("⚠ Você está usando a senha padrão antiga. Troque agora no painel.")
            return redirect(url_for('dashboard'))
        register_fail(ip)
        logging.warning(f"Tentativa de login falhou de {ip}")
        flash('Senha incorreta')
    return render_template('login.html')


@app.route('/logout', methods=['POST'])
@login_required
def logout():
    logout_user()
    return redirect(url_for('login'))


@app.route('/')
@login_required
def dashboard():
    stats = get_stats_data()
    if stats is None:
        flash("Erro ao carregar o dashboard")
        stats = empty_stats()
    return render_template('dashboard.html', stats=stats, users=get_users())


@app.route('/api/stats')
@login_required
def api_stats():
    stats = get_stats_data()
    if stats is None:
        return jsonify({"error": "Não foi possível obter as estatísticas"}), 500
    return jsonify(stats)


@app.route('/change_password', methods=['POST'])
@login_required
def change_password():
    global ADMIN_PASSWORD_HASH
    try:
        cur = request.form.get('current_password', '')
        new = request.form.get('new_password', '')
        conf = request.form.get('confirm_password', '')
        logging.info(f"[CHANGE_PASS] Solicitação de {request.remote_addr}")
        if len(new) < 8 or len(new.encode('utf-8')) > 72:
            flash("A nova senha deve ter entre 8 e 72 caracteres")
        elif new != conf:
            flash("As novas senhas não coincidem")
        elif not verify_password(cur, ADMIN_PASSWORD_HASH):
            flash("A senha atual está incorreta")
        elif verify_password(new, ADMIN_PASSWORD_HASH):
            flash("A nova senha deve ser diferente da atual")
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
            else:
                flash("Erro ao salvar a senha")
    except Exception as e:
        logging.error(f"[CHANGE_PASS] Erro: {e}", exc_info=True)
        flash("Erro ao alterar a senha")
    return redirect(url_for('dashboard'))


@app.route('/update_now', methods=['POST'])
@login_required
def update_now():
    try:
        logging.info("Iniciando atualização pelo painel web")
        results = perform_update()
        reload_ = results["backend"]["success"] or results["templates"]["success"]
        if reload_:
            schedule_restart()
        ok = sum(1 for v in results.values() if v["success"])
        return jsonify({
            "success": True,
            "message": f"Atualização concluída: {ok}/{len(results)} componentes",
            "details": results,
            "restart": "O painel será reiniciado automaticamente em alguns segundos." if reload_ else "",
            "will_reload": reload_})
    except Exception as e:
        logging.error(f"Erro em atualização: {e}", exc_info=True)
        return jsonify({"success": False, "message": "Erro durante a atualização"}), 500


@app.route('/add_user', methods=['POST'])
@login_required
def add_user():
    try:
        user = request.form.get('username', '').strip().lower()
        pwd = request.form.get('password', '')
        try:
            days = int(request.form.get('days', ''))
        except ValueError:
            flash("Erro: Os dias devem ser um número válido")
            return redirect(url_for('dashboard'))
        if not valid_username(user):
            flash("Usuário inválido: use letras minúsculas, números, '_' ou '-' (começando por letra ou '_')")
            return redirect(url_for('dashboard'))
        if not valid_user_password(pwd):
            flash("Senha inválida: 4 a 64 caracteres, sem ':' nem caracteres de controle")
            return redirect(url_for('dashboard'))
        if not (1 <= days <= 3650):
            flash("Os dias devem estar entre 1 e 3650")
            return redirect(url_for('dashboard'))
        if system_user_exists(user):
            flash(f"O usuário '{user}' já existe no sistema")
            return redirect(url_for('dashboard'))

        if run([GETENT, 'group', USER_GROUP]).returncode != 0:
            run([GROUPADD, USER_GROUP])
        exp_date = (datetime.datetime.now() + datetime.timedelta(days=days)).strftime("%Y-%m-%d")
        res = run([USERADD, '-m', '-s', get_user_shell(), '-G', USER_GROUP, user])
        if res.returncode != 0:
            logging.error(f"useradd falhou: {res.stderr}")
            flash("Erro ao criar usuário")
            return redirect(url_for('dashboard'))
        res = run([CHPASSWD], input=f"{user}:{pwd}\n")
        if res.returncode != 0:
            logging.error(f"chpasswd falhou: {res.stderr}")
            run([USERDEL, '-r', user])
            flash("Erro ao definir a senha")
            return redirect(url_for('dashboard'))
        set_expiry(user, exp_date)
        with DbLock():
            entries = [e for e in read_db() if e[0] != user]
            entries.append((user, pwd, exp_date))
            write_db(entries)
        logging.info(f"Usuário criado: {user} (exp {exp_date}) por {request.remote_addr}")
        flash(f"✓ Usuário '{user}' criado com sucesso (Expira: {exp_date})")
    except Exception as e:
        logging.error(f"Erro criando usuário: {e}", exc_info=True)
        flash("Erro inesperado ao criar usuário")
    return redirect(url_for('dashboard'))


def _managed_or_flash(username):
    """Só permite mexer em contas que estão no users.txt."""
    if not valid_username(username) or not db_has(username):
        flash(f"O usuário '{username}' não é gerenciado por este painel")
        return False
    return True


@app.route('/delete_user/<username>', methods=['POST'])
@login_required
def delete_user(username):
    try:
        if not _managed_or_flash(username):
            return redirect(url_for('dashboard'))
        run([PKILL, '-KILL', '-u', username])
        res = run([USERDEL, '-r', username])
        if res.returncode != 0 and system_user_exists(username):
            logging.error(f"userdel falhou para {username}: {res.stderr}")
            flash(f"Erro ao remover '{username}'")
            return redirect(url_for('dashboard'))
        with DbLock():
            write_db([e for e in read_db() if e[0] != username])
        logging.info(f"Usuário removido: {username} por {request.remote_addr}")
        flash(f"✓ Usuário '{username}' removido com sucesso")
    except Exception as e:
        logging.error(f"Erro removendo usuário: {e}", exc_info=True)
        flash("Erro ao remover usuário")
    return redirect(url_for('dashboard'))


@app.route('/edit_password/<username>', methods=['POST'])
@login_required
def edit_password(username):
    try:
        new = request.form.get('new_password', '')
        conf = request.form.get('confirm_password', '')
        logging.info(f"[EDIT_PASS] Troca de senha para {username} de {request.remote_addr}")
        if not _managed_or_flash(username):
            return redirect(url_for('dashboard'))
        if not valid_user_password(new):
            flash("Senha inválida: 4 a 64 caracteres, sem ':' nem caracteres de controle")
        elif new != conf:
            flash("As novas senhas não coincidem")
        elif not system_user_exists(username):
            flash(f"O usuário '{username}' não existe no sistema")
        else:
            res = run([CHPASSWD], input=f"{username}:{new}\n")
            if res.returncode != 0:
                logging.error(f"chpasswd falhou: {res.stderr}")
                flash("Erro ao alterar a senha")
            else:
                with DbLock():
                    write_db([(u, new if u == username else p, e) for u, p, e in read_db()])
                flash(f"✓ Senha de '{username}' alterada com sucesso")
    except Exception as e:
        logging.error(f"[EDIT_PASS] Erro: {e}", exc_info=True)
        flash("Erro ao alterar a senha")
    return redirect(url_for('dashboard'))


@app.route('/edit_expiry/<username>', methods=['POST'])
@login_required
def edit_expiry(username):
    try:
        action = request.form.get('action', '')
        logging.info(f"[EDIT_EXP] Troca de expiração para {username} de {request.remote_addr}")
        if not _managed_or_flash(username):
            return redirect(url_for('dashboard'))
        if not system_user_exists(username):
            flash(f"O usuário '{username}' não existe no sistema")
            return redirect(url_for('dashboard'))

        current = next((e for u, _, e in read_db() if u == username), "")
        new_exp, msg = "", ""
        if action == "permanent":
            new_exp, msg = "2099-12-31", f"✓ Usuário '{username}' agora é permanente"
        elif action == "custom":
            custom = request.form.get('custom_date', '')
            if not valid_date(custom):
                flash("Data inválida. Use o formato AAAA-MM-DD")
                return redirect(url_for('dashboard'))
            new_exp, msg = custom, f"✓ Expiração de '{username}' alterada para {custom}"
        elif re.fullmatch(r'extend_[0-9]{1,4}', action):
            days = int(action.split('_')[1])
            base = datetime.datetime.now()
            if valid_date(current):
                cur_dt = datetime.datetime.strptime(current, "%Y-%m-%d")
                if cur_dt > base:
                    base = cur_dt
            new_exp = (base + datetime.timedelta(days=days)).strftime("%Y-%m-%d")
            msg = f"✓ Expiração de '{username}' estendida para {new_exp} (+{days} dias)"
        else:
            flash("Ação inválida")
            return redirect(url_for('dashboard'))

        set_expiry(username, new_exp)
        with DbLock():
            write_db([(u, p, new_exp if u == username else e) for u, p, e in read_db()])
        logging.info(f"[EDIT_EXP] ✓ Expiração de {username} alterada para {new_exp}")
        flash(msg)
    except Exception as e:
        logging.error(f"[EDIT_EXP] Erro: {e}", exc_info=True)
        flash("Erro ao alterar a expiração")
    return redirect(url_for('dashboard'))


@app.route('/control_service/<svc>/<action>', methods=['POST'])
@login_required
def control_service(svc, action):
    try:
        if svc not in SERVICES:
            flash(f"Serviço inválido: {svc}")
            return redirect(url_for('dashboard'))
        if action not in ('start', 'stop', 'restart'):
            flash(f"Ação inválida: {action}")
            return redirect(url_for('dashboard'))
        ports = read_ports(svc)
        if not ports:
            flash(f"Não há portas configuradas para {svc.upper()}")
            return redirect(url_for('dashboard'))
        ok = err = 0
        for port in ports:
            r = run([SYSTEMCTL, action, f"{svc}@{port}.service"])
            if r.returncode == 0:
                ok += 1
            else:
                err += 1
        label = {"start": "Início", "stop": "Parada", "restart": "Reinício"}[action]
        if err == 0:
            flash(f"✓ {svc.upper()}: Ação '{label}' com sucesso em {ok} porta(s)")
        else:
            flash(f"⚠ {svc.upper()}: {ok} com sucesso, {err} erro(s)")
    except Exception as e:
        logging.error(f"Erro ao controlar o serviço: {e}")
        flash("Erro ao controlar o serviço")
    return redirect(url_for('dashboard'))


# ───────────────────────── main ─────────────────────────
def run_https(host, port):
    """HTTPS nativo (cheroot). Só inicia se o certificado existir: nunca cai para HTTP em silêncio."""
    if not (os.path.isfile(TLS_CERT) and os.path.isfile(TLS_KEY)):
        logging.error(f"HEX_PANEL_TLS=1 mas faltam {TLS_CERT} / {TLS_KEY}. Rode: hex_panel_mode.sh https")
        sys.exit(1)
    try:
        from cheroot.wsgi import Server
        from cheroot.ssl.builtin import BuiltinSSLAdapter
    except ImportError:
        logging.error("cheroot não instalado. Rode: hex_panel_mode.sh https")
        sys.exit(1)
    server = Server((host, port), app, numthreads=8)
    server.ssl_adapter = BuiltinSSLAdapter(TLS_CERT, TLS_KEY)
    server.ssl_adapter.context.minimum_version = ssl.TLSVersion.TLSv1_2
    logging.info(f"Painel (HTTPS/cheroot) em {host}:{port}")
    try:
        server.start()
    except KeyboardInterrupt:
        pass
    finally:
        server.stop()


if __name__ == '__main__':
    host = os.environ.get("HEX_PANEL_HOST", "0.0.0.0")
    port = get_webpanel_port()
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
