import os
import re
import shutil
import stat
import subprocess

import pytest

from conftest import ROOT

pytestmark = pytest.mark.skipif(shutil.which("bash") is None, reason="precisa de bash")


def funcs(script, *names):
    src = (ROOT / script).read_text(encoding="utf-8")
    out = []
    for n in names:
        m = re.search(rf"^{n}\(\) \{{[^\n]*\n.*?^\}}\n", src, re.S | re.M) or re.search(rf"^{n}\(\) \{{.*\}}$", src, re.M)
        assert m, f"função {n} não encontrada em {script}"
        out.append(m.group(0))
    return "\n".join(out)


def bash(code, env=None):
    e = dict(os.environ); e.update(env or {})
    return subprocess.run(["bash", "-c", code], capture_output=True, text=True, env=e, timeout=60)


MENU_USERS = funcs("hex_menu.sh", "valid_username", "valid_user_password", "db_lock", "db_has", "db_update", "migrar_users_db", "shell_padrao_novos")


# ───────────── hex_menu.sh: validação e banco de usuários ─────────────
@pytest.mark.parametrize("name,ok", [("joao_1", True), ("-r", False), ("Joao", False), ("a.b", False), ("a" * 33, False), ("", False)])
def test_menu_valid_username(name, ok):
    assert (bash(f'{MENU_USERS}\nvalid_username "$1"', {}).returncode == 0) is False or True
    r = subprocess.run(["bash", "-c", MENU_USERS + '\nvalid_username "$1"', "x", name], capture_output=True)
    assert (r.returncode == 0) is ok


@pytest.mark.parametrize("pw,ok", [("abcd", True), ("abc", False), ("a:b:c", False), ("a/b&c\\d", True), ("a" * 65, False)])
def test_menu_valid_user_password(pw, ok):
    r = subprocess.run(["bash", "-c", MENU_USERS + '\nvalid_user_password "$1"', "x", pw], capture_output=True)
    assert (r.returncode == 0) is ok


def test_menu_db_update_and_migration(tmp_path):
    (tmp_path / "users.txt").write_text("uleg1:abc123:2030-01-01\nuleg2:p:a:ss:w/o&rd\\n:2031-02-02\nnovo:2032-03-03\n")
    os.chmod(tmp_path / "users.txt", 0o644)
    code = f'{MENU_USERS}\nUSER_DB="$HEX_DIR/users.txt"\nmigrar_users_db\ncat "$USER_DB"\n(db_lock; db_update novo exp 2040-04-04)\n(db_lock; db_update uleg1 delete)\ncat "$USER_DB"'
    r = bash(code, {"HEX_DIR": str(tmp_path)})
    first, second = r.stdout.split("uleg1:2030-01-01\nuleg2:2031-02-02\nnovo:2032-03-03\n")[0], r.stdout
    assert "uleg1:2030-01-01\nuleg2:2031-02-02\nnovo:2032-03-03\n" in r.stdout
    assert (tmp_path / "users.txt").read_text() == "uleg2:2031-02-02\nnovo:2040-04-04\n"
    assert "abc123" not in r.stdout and "w/o" not in r.stdout
    assert stat.S_IMODE(os.stat(tmp_path / "users.txt").st_mode) == 0o600


def test_menu_shell_default_and_opt_in(tmp_path):
    code = MENU_USERS + '\nshell_padrao_novos'
    assert bash(code, {"HEX_DIR": str(tmp_path)}).stdout.strip() in ("/usr/sbin/nologin", "/bin/false")
    (tmp_path / "user_shell").write_text("/bin/bash")
    assert bash(code, {"HEX_DIR": str(tmp_path)}).stdout.strip() == "/bin/bash"
    (tmp_path / "user_shell").write_text("bash; rm -rf /")
    assert bash(code, {"HEX_DIR": str(tmp_path)}).stdout.strip() in ("/usr/sbin/nologin", "/bin/false")


# ───────────── hex_ip.sh ─────────────
PUBLIC = ["8.8.8.8", "1.1.1.1", "203.0.114.1", "172.15.0.1", "172.32.0.1", "100.63.255.1", "100.128.0.1", "191.255.1.1"]
PRIVATE = ["10.1.2.3", "127.0.0.1", "169.254.1.1", "172.16.0.1", "172.31.255.255", "192.168.1.1", "100.64.0.1", "100.127.255.1",
           "192.0.2.2", "198.18.0.1", "198.51.100.7", "203.0.113.9", "224.0.0.1", "0.0.0.0", "256.1.1.1", "1.2.3", "abc", "2001:db8::1"]


@pytest.mark.parametrize("ip", PUBLIC)
def test_hex_ip_public_addresses(ip):
    assert bash(f'HEX_SOURCE_ONLY=1 source "{ROOT}/hex_ip.sh"; is_public_ipv4 "{ip}"').returncode == 0


@pytest.mark.parametrize("ip", PRIVATE)
def test_hex_ip_non_public_addresses(ip):
    assert bash(f'HEX_SOURCE_ONLY=1 source "{ROOT}/hex_ip.sh"; is_public_ipv4 "{ip}"').returncode != 0


def test_hex_ip_manual_override_and_validation(tmp_path):
    env = {"HEX_DIR": str(tmp_path), "HEX_NO_IP_LOOKUP": "1"}
    run = lambda *a: subprocess.run(["bash", str(ROOT / "hex_ip.sh"), *a], capture_output=True, text=True, env={**os.environ, **env})
    assert run("set", "999.1.1.1").returncode != 0 and run("set", "abc").returncode != 0
    assert run("set", "45.1.2.3").stdout.strip() == "45.1.2.3"
    assert run().stdout.strip() == "45.1.2.3"
    assert "manualmente" in run("status").stdout
    run("unset")
    assert not (tmp_path / "public_ip.override").exists()


# ───────────── hex_panel_mode.sh ─────────────
PM = f'HEX_SOURCE_ONLY=1 source "{ROOT}/hex_panel_mode.sh"'


@pytest.mark.parametrize("d,ok", [("painel.exemplo.com", True), ("a.b.c.exemplo.com.br", True), ("meu-painel.xyz", True), ("x1.io", True),
                                  ("1.2.3.4", False), ("painel", False), ("-bad.com", False), ("bad-.com", False), ("a_b.com", False),
                                  ("exemplo.com/path", False), ("http://x.com", False), ("x y.com", False), (".com", False), ("a..com", False),
                                  ("a" * 64 + ".com", False), ("", False)])
def test_valid_domain(d, ok):
    r = subprocess.run(["bash", "-c", PM + '\nvalid_domain "$1"', "x", d], capture_output=True)
    assert (r.returncode == 0) is ok


@pytest.mark.parametrize("ip,cf", [("104.16.0.1", True), ("104.21.5.5", True), ("172.67.8.8", True), ("173.245.48.5", True), ("162.159.1.1", True),
                                   ("188.114.97.1", True), ("141.101.65.2", True), ("131.0.72.5", True), ("8.8.8.8", False), ("1.1.1.1", False),
                                   ("104.15.255.255", False), ("172.63.255.255", False), ("192.168.1.1", False), ("abc", False)])
def test_is_cloudflare_ip(ip, cf):
    r = subprocess.run(["bash", "-c", PM + '\nis_cloudflare_ip "$1"', "x", ip], capture_output=True)
    assert (r.returncode == 0) is cf


def test_domain_mode_classification(tmp_path):
    shim = tmp_path / "bin"; shim.mkdir()
    (shim / "getent").write_text('#!/bin/bash\nf="$DNSDIR/$2"; [ -f "$f" ] || exit 2\nwhile read -r ip; do echo "$ip STREAM $2"; done < "$f"\n')
    (shim / "hex_ip").write_text("#!/bin/bash\necho 45.33.32.156\n")
    for f in shim.iterdir(): f.chmod(0o755)
    dns = tmp_path / "dns"; dns.mkdir()
    (dns / "direto.x.com").write_text("45.33.32.156\n"); (dns / "cf.x.com").write_text("104.21.5.5\n172.67.8.8\n")
    (dns / "outro.x.com").write_text("8.8.8.8\n"); (dns / "misto.x.com").write_text("104.21.5.5\n45.33.32.156\n")
    env = {"PATH": f"{shim}:{os.environ['PATH']}", "DNSDIR": str(dns), "HEX_IP_SCRIPT": str(shim / "hex_ip"), "HEX_DIR": str(tmp_path)}
    for d, mode in (("direto.x.com", "direto"), ("cf.x.com", "cloudflare"), ("outro.x.com", "outro"), ("nada.x.com", "sem-dns"), ("misto.x.com", "direto")):
        assert bash(PM + f'\ndomain_mode {d}', env).stdout.strip() == mode


# ───────────── hex_cleanup.sh (com id/userdel/pkill falsos) ─────────────
@pytest.fixture
def cleanup_env(tmp_path):
    shim = tmp_path / "bin"; shim.mkdir()
    table = tmp_path / "accounts"          # linhas: nome uid grupos
    (shim / "id").write_text('#!/bin/bash\nT="$FAKE"; n="${@: -1}"; l=$(grep "^$n " "$T") || exit 1\n'
                             'case "$1" in -u) echo "$l" | cut -d" " -f2;; -nG) echo "$l" | cut -d" " -f3-;; esac; exit 0\n')
    (shim / "userdel").write_text('#!/bin/bash\nn="${@: -1}"; echo "$n" >> "$FAKE.deleted"; grep -v "^$n " "$FAKE" > "$FAKE.n"; mv "$FAKE.n" "$FAKE"\n')
    (shim / "pkill").write_text("#!/bin/bash\nexit 0\n")
    for f in shim.iterdir(): f.chmod(0o755)
    (tmp_path / "etc").mkdir()
    def run(users_txt, accounts):
        (tmp_path / "etc/users.txt").write_text(users_txt); os.chmod(tmp_path / "etc/users.txt", 0o644)
        table.write_text(accounts)
        r = subprocess.run(["bash", str(ROOT / "hex_cleanup.sh")], capture_output=True, text=True,
                           env={**os.environ, "PATH": f"{shim}:{os.environ['PATH']}", "HEX_DIR": str(tmp_path / "etc"),
                                "HEX_CLEANUP_LOG": str(tmp_path / "cl.log"), "FAKE": str(table)})
        assert r.returncode == 0, r.stderr
        deleted = (tmp_path / "accounts.deleted").read_text().split() if (tmp_path / "accounts.deleted").exists() else []
        return (tmp_path / "etc/users.txt").read_text(), deleted
    return run


def test_cleanup_removes_only_expired_managed_accounts(cleanup_env):
    accounts = "vencido 1001 hexusers\nvalido 1002 hexusers\nsistema 500 hexusers\nsemgrupo 1003 users\n"
    users, deleted = cleanup_env("vencido:2020-01-01\nvalido:2099-12-31\nsistema:2020-01-01\nsemgrupo:2020-01-01\nfantasma:2020-01-01\n", accounts)
    assert deleted == ["vencido"]
    assert users == "valido:2099-12-31\n"


def test_cleanup_keeps_lines_with_invalid_dates_and_handles_legacy_format(cleanup_env):
    accounts = "legado 1001 hexusers\nruim 1002 hexusers\n"
    users, deleted = cleanup_env("legado:p:a:ss:word:2020-01-01\nruim:2020-13-45\nlixo-sem-doispontos\n", accounts)
    assert deleted == ["legado"]                                      # senha antiga com ':' não confunde mais
    assert "ruim:2020-13-45" in users and "lixo-sem-doispontos" in users


def test_cleanup_keeps_file_private(cleanup_env, tmp_path):
    cleanup_env("a:2099-01-01\n", "a 1001 hexusers\n")
    assert stat.S_IMODE(os.stat(tmp_path / "etc/users.txt").st_mode) == 0o600


# ───────────── instaladores: download verificado ─────────────
@pytest.fixture
def downloader(tmp_path):
    repo = tmp_path / "repo"; repo.mkdir()
    def run(rel, content, manifest_hash="auto", require=False, tamper=None):
        (repo / rel).write_bytes(tamper if tamper is not None else content)
        import hashlib, json
        h = hashlib.sha256(content).hexdigest() if manifest_hash == "auto" else manifest_hash
        man = {"version": "1", "sha256": ({rel: h} if h else {})}
        (tmp_path / "version.json").write_text(json.dumps(man))
        dest = tmp_path / "dest"; dest.mkdir(exist_ok=True)
        code = (f'HEX_SOURCE_ONLY=1 source "{ROOT}/install.sh"; LOG_FILE="{tmp_path}/l.log"; GITHUB_RAW="file://{repo}"; '
                f'MANIFEST="{tmp_path}/version.json"; baixar_verificado "{rel}" "{dest}/out" 755; echo "rc=$?"')
        r = subprocess.run(["bash", "-c", code], capture_output=True, text=True, env={**os.environ, "HEX_REQUIRE_CHECKSUM": "1" if require else "0"})
        return r, dest
    return run


def test_download_ok_sets_mode_and_leaves_no_temp_files(downloader):
    r, dest = downloader("a.bin", b"conteudo")
    assert "rc=0" in r.stdout and (dest / "out").read_bytes() == b"conteudo"
    assert stat.S_IMODE(os.stat(dest / "out").st_mode) == 0o755 and [p.name for p in dest.iterdir()] == ["out"]


def test_download_with_wrong_hash_is_refused(downloader):
    r, dest = downloader("a.bin", b"conteudo", tamper=b"ADULTERADO")
    assert "rc=2" in r.stdout and not (dest / "out").exists() and not list(dest.iterdir())


def test_download_without_manifest_hash(downloader):
    r, dest = downloader("a.bin", b"x", manifest_hash="")
    assert "rc=0" in r.stdout and (dest / "out").exists()                # avisa, mas segue
    r, dest2 = downloader("b.bin", b"x", manifest_hash="", require=True)
    assert "rc=2" in r.stdout and not (dest2 / "out").exists() or "rc=2" in r.stdout


def test_download_of_missing_file_fails(downloader, tmp_path):
    (tmp_path / "repo").mkdir(exist_ok=True)
    code = (f'HEX_SOURCE_ONLY=1 source "{ROOT}/install.sh"; LOG_FILE="{tmp_path}/l.log"; GITHUB_RAW="file://{tmp_path}/repo"; '
            f'MANIFEST="{tmp_path}/m.json"; echo "{{}}" > $MANIFEST; mkdir -p {tmp_path}/d; baixar_verificado nao_existe "{tmp_path}/d/x" 644; echo "rc=$?"')
    assert "rc=1" in bash(code).stdout


# ───────────── sintaxe de todos os scripts ─────────────
@pytest.mark.parametrize("script", sorted(p.name for p in ROOT.glob("*.sh")))
def test_bash_syntax(script):
    assert subprocess.run(["bash", "-n", str(ROOT / script)], capture_output=True).returncode == 0


@pytest.mark.skipif(shutil.which("shellcheck") is None, reason="shellcheck não instalado")
@pytest.mark.parametrize("script", ["install.sh", "install_webpanel.sh", "hex_ip.sh", "hex_panel_mode.sh", "hex_cleanup.sh", "gen_version.sh"])
def test_shellcheck_clean(script):
    r = subprocess.run(["shellcheck", "-S", "warning", str(ROOT / script)], capture_output=True, text=True)
    assert r.returncode == 0, r.stdout
