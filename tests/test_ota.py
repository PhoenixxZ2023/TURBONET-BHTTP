import functools
import hashlib
import http.server
import json
import os
import socketserver
import stat
import threading

import pytest

from conftest import ROOT


@pytest.fixture
def server(tmp_path):
    """Servidor HTTP local que imita o raw.githubusercontent.com do repositório."""
    root = tmp_path / "srv"
    (root / "templates").mkdir(parents=True)
    handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=str(root))
    handler.log_message = lambda *a, **k: None
    class Q(http.server.SimpleHTTPRequestHandler):
        def log_message(self, *a, **k): pass
    httpd = socketserver.TCPServer(("127.0.0.1", 0), lambda *a, **k: Q(*a, directory=str(root), **k))
    threading.Thread(target=httpd.serve_forever, daemon=True).start()

    class Srv:
        url = f"http://127.0.0.1:{httpd.server_address[1]}"
        files = {}
        def put(self, rel, data):
            (root / rel).parent.mkdir(parents=True, exist_ok=True)
            (root / rel).write_bytes(data); self.files[rel] = data
        def publish(self, version="9.9.9", sha=True, drop=()):
            man = {"version": version, "changelog": "t",
                   "sha256": {k: hashlib.sha256(v).hexdigest() for k, v in self.files.items() if sha and k not in drop}}
            (root / "version.json").write_text(json.dumps(man))
            return man
    srv = Srv(); srv.files = {}
    srv.put("hex_menu.sh", b"#!/bin/bash\necho novo menu\n")
    srv.put("hex_cleanup.sh", b"#!/bin/bash\necho novo cleanup\n")
    srv.put("hex_panel_mode.sh", b"#!/bin/bash\necho mode\n")
    srv.put("hex_ip.sh", b"#!/bin/bash\necho ip\n")
    srv.put("app.py", (ROOT / "app.py").read_bytes())
    srv.put("templates/login.html", (ROOT / "templates/login.html").read_bytes())
    srv.put("templates/dashboard.html", (ROOT / "templates/dashboard.html").read_bytes())
    yield srv
    httpd.shutdown()


@pytest.fixture
def installed(make_panel, server, tmp_path):
    p = make_panel()
    p.m.GITHUB_RAW = server.url
    (tmp_path / "bin/hex_menu").write_text("#!/bin/bash\necho antigo\n")
    (tmp_path / "bin/hex_cleanup.sh").write_text("antigo")
    (tmp_path / "panel/app.py").write_text("# antigo\n")
    for f in ("login.html", "dashboard.html"):
        (tmp_path / "panel/templates" / f).write_text("antigo")
    return p


def test_successful_update_installs_everything_with_backups_and_modes(installed, server, tmp_path):
    server.publish()
    res = installed.m.perform_update()
    assert all(v["success"] for v in res.values()), res
    assert b"novo menu" in (tmp_path / "bin/hex_menu").read_bytes()
    assert stat.S_IMODE(os.stat(tmp_path / "bin/hex_menu").st_mode) == 0o755
    assert (tmp_path / "bin/hex_panel_mode.sh").exists() and (tmp_path / "bin/hex_ip.sh").exists()
    assert list((tmp_path / "bin").glob("hex_menu.backup.*")), "sem backup do menu antigo"
    assert (tmp_path / "etc/version").read_text() == "9.9.9"
    assert (tmp_path / "panel/templates/dashboard.html").read_bytes() == server.files["templates/dashboard.html"]


def test_file_with_wrong_hash_is_refused_and_not_installed(installed, server, tmp_path):
    server.publish()
    server.put("hex_menu.sh", b"#!/bin/bash\necho ADULTERADO\n")          # muda depois de publicar o hash
    res = installed.m.perform_update()
    assert not res["menu"]["success"] and "SHA256" in res["menu"]["message"]
    assert b"ADULTERADO" not in (tmp_path / "bin/hex_menu").read_bytes()


def test_bash_syntax_error_is_refused(installed, server, tmp_path):
    server.put("hex_menu.sh", b"echo 'sem fechar\n"); server.publish()
    res = installed.m.perform_update()
    assert not res["menu"]["success"] and b"antigo" in (tmp_path / "bin/hex_menu").read_bytes()


def test_python_syntax_error_in_backend_is_refused(installed, server, tmp_path):
    server.put("app.py", b"def x(:\n"); server.publish()
    res = installed.m.perform_update()
    assert not res["backend"]["success"] and (tmp_path / "panel/app.py").read_text() == "# antigo\n"


def test_invalid_jinja_template_is_refused(installed, server, tmp_path):
    server.put("templates/dashboard.html", b"{% if %}"); server.publish()
    res = installed.m.perform_update()
    assert not res["templates"]["success"] and (tmp_path / "panel/templates/dashboard.html").read_text() == "antigo"
    assert (tmp_path / "panel/templates/login.html").read_text() == "antigo", "atualização parcial dos templates"


def test_missing_manifest_hash_is_allowed_with_warning_but_refused_when_required(installed, server, tmp_path):
    server.publish(drop=("hex_menu.sh",))
    assert installed.m.perform_update()["menu"]["success"]
    (tmp_path / "etc/require_checksum").write_text("1")
    server.publish(drop=("hex_menu.sh",))
    res = installed.m.perform_update()
    assert not res["menu"]["success"] and "sem SHA256" in res["menu"]["message"]


def test_unreachable_manifest_fails_everything_safely(installed, tmp_path):
    installed.m.GITHUB_RAW = "http://127.0.0.1:9"
    res = installed.m.perform_update()
    assert not any(v["success"] for v in res.values())
    assert b"antigo" in (tmp_path / "bin/hex_menu").read_bytes()


def test_download_size_limit(installed, server):
    server.put("grande.bin", b"x" * (3 * 1024 * 1024 + 10))
    with pytest.raises(ValueError):
        installed.m.http_get(f"{server.url}/grande.bin")


def test_update_installs_static_assets_listed_in_the_manifest(installed, server, tmp_path):
    server.put("static/vendor/bootstrap/bootstrap.min.css", b"/* css */")
    server.put("static/vendor/fonts/orbitron.woff2", b"\x00\x01binario")
    server.publish()
    res = installed.m.perform_update()
    assert res["templates"]["success"] and "2 arquivo(s) estático(s)" in res["templates"]["message"], res
    assert (tmp_path / "panel/static/vendor/bootstrap/bootstrap.min.css").read_bytes() == b"/* css */"
    assert (tmp_path / "panel/static/vendor/fonts/orbitron.woff2").read_bytes() == b"\x00\x01binario"
    assert not list((tmp_path / "panel/static").rglob("*.backup.*")), "backups não devem ir para uma pasta servida"


def test_tampered_static_asset_blocks_the_whole_templates_update(installed, server, tmp_path):
    server.put("static/vendor/a.css", b"ok"); server.publish()
    server.put("static/vendor/a.css", b"ADULTERADO")
    res = installed.m.perform_update()
    assert not res["templates"]["success"]
    assert (tmp_path / "panel/templates/dashboard.html").read_text() == "antigo", "template foi trocado apesar do asset inválido"
    assert not (tmp_path / "panel/static/vendor/a.css").exists()


def _publish_with_extra_key(server, tmp_path, key):
    import json, hashlib
    server.publish()
    man = json.loads((tmp_path / "srv/version.json").read_text())
    man["sha256"][key] = hashlib.sha256(b"x").hexdigest()
    (tmp_path / "srv/version.json").write_text(json.dumps(man))


@pytest.mark.parametrize("evil", ["static/../../etc/cron.d/x", "static/../app.py", "static/../../../tmp/x"])
def test_manifest_path_traversal_under_static_is_refused(installed, server, tmp_path, evil):
    _publish_with_extra_key(server, tmp_path, evil)
    res = installed.m.perform_update()
    assert not res["templates"]["success"] and "caminho inválido" in res["templates"]["message"]
    assert (tmp_path / "panel/templates/dashboard.html").read_text() == "antigo"
    assert not (tmp_path / "etc/cron.d").exists() and not (tmp_path / "tmp/x").exists()


def test_manifest_keys_outside_static_are_ignored_by_the_asset_step(installed, server, tmp_path):
    _publish_with_extra_key(server, tmp_path, "/etc/passwd")
    res = installed.m.perform_update()
    assert res["templates"]["success"] and "0 arquivo(s) estático(s)" in res["templates"]["message"]
