"""Infra dos testes: carrega o app.py com diretórios temporários e um "sistema falso"
(useradd, chpasswd, userdel, systemctl...), então NADA aqui precisa de root nem altera a máquina."""
import importlib.util
import re
import secrets
import subprocess
import sys
import time
from pathlib import Path

import pytest
from flask.testing import FlaskClient

ROOT = Path(__file__).resolve().parent.parent
FAKE_UPDATE = {"has_update": False, "local_version": "1.0.0", "remote_version": "1.0.0", "changelog": "",
               "checked_at": "", "is_newer": False, "is_older": False}


class FakeSystem:
    """Imita os comandos que o painel executa. Guarda estado em memória."""

    def __init__(self):
        self.users = {"root": {"shell": "/bin/bash", "pw": None, "exp": None},
                      "nobody": {"shell": "/usr/sbin/nologin", "pw": None, "exp": None}}
        self.groups = set()
        self.calls = []
        self.fail = set()   # nomes de comandos que devem falhar

    def __call__(self, cmd, **kw):
        self.calls.append(list(cmd))
        name = Path(cmd[0]).name
        out = lambda rc=0, so="", se="": subprocess.CompletedProcess(cmd, rc, so, se)
        if name in self.fail:
            return out(1, "", f"{name} falhou (simulado)")
        if name == "id":
            return out(0 if cmd[1] in self.users else 1)
        if name == "getent":
            return out(0 if cmd[2] in self.groups else 2)
        if name == "groupadd":
            self.groups.add(cmd[1]); return out()
        if name == "useradd":
            user = cmd[-1]
            if user in self.users:
                return out(9)
            shell = cmd[cmd.index("-s") + 1] if "-s" in cmd else "/bin/bash"
            self.users[user] = {"shell": shell, "pw": None, "exp": None}
            return out()
        if name == "chpasswd":
            user, _, pw = kw["input"].rstrip("\n").partition(":")
            if user not in self.users:
                return out(1)
            self.users[user]["pw"] = pw; return out()
        if name in ("chage", "usermod"):
            return out()
        if name == "userdel":
            self.users.pop(cmd[-1], None); return out()
        if name == "pkill":
            return out(1)
        if name == "systemctl":
            return out(1 if cmd[1] == "is-active" else 0)
        return out()


class Panel:
    def __init__(self, module, fake, tmp):
        self.m, self.fake, self.tmp = module, fake, tmp
        self.etc = tmp / "etc"

    @property
    def password(self):
        return re.search(r"painel: (\S+)", (self.etc / "webpanel_initial_password.txt").read_text()).group(1)

    def client(self, logged=True, addr="10.9.9.9"):
        c = self.m.app.test_client()
        if logged:
            r = c.post("/login", data={"password": self.password}, environ_base={"REMOTE_ADDR": addr})
            assert r.status_code == 302, r.status_code
        return c

    def login_page_token(self, c):
        return re.search(r'name="csrf_token" value="([^"]+)"', c.get("/login").get_data(as_text=True)).group(1)

    def token(self, c):
        with c.session_transaction() as s:
            return s["_csrf"]

    def set_last_seen(self, c, value):
        with c.session_transaction() as s:
            s["last_seen"] = value

    def last_seen(self, c):
        with c.session_transaction() as s:
            return s.get("last_seen")


class TokenClient(FlaskClient):
    """Cliente de teste que injeta o token CSRF da sessão em todo POST (o app o exige)."""
    def open(self, *a, **kw):
        if kw.get("method") == "POST" and not kw.pop("no_csrf", False):
            with self.session_transaction() as s:
                tok = s.get("_csrf") or s.setdefault("_csrf", "t-" + secrets.token_hex(8))
            data = dict(kw.get("data") or {})
            data.setdefault("csrf_token", tok)
            kw["data"] = data
        return super().open(*a, **kw)


@pytest.fixture
def make_panel(tmp_path, monkeypatch):
    """Fábrica: make_panel(env={...}) carrega um app.py novo com diretórios temporários."""
    def factory(env=None, name=None):
        base = {"HEX_DIR": str(tmp_path / "etc"), "HEX_LOG": str(tmp_path / "panel.log"),
                "HEX_PANEL_DIR": str(tmp_path / "panel"), "HEX_MENU_PATH": str(tmp_path / "bin/hex_menu"),
                "HEX_CLEANUP_PATH": str(tmp_path / "bin/hex_cleanup.sh"),
                "HEX_MODE_PATH": str(tmp_path / "bin/hex_panel_mode.sh"), "HEX_IP_PATH": str(tmp_path / "bin/hex_ip.sh")}
        base.update(env or {})
        for k, v in base.items():
            monkeypatch.setenv(k, v)
        for d in ("etc", "panel/templates", "bin"):
            (tmp_path / d).mkdir(parents=True, exist_ok=True)
        modname = name or f"hexapp_{secrets.token_hex(4)}"
        spec = importlib.util.spec_from_file_location(modname, ROOT / "app.py")
        mod = importlib.util.module_from_spec(spec)
        sys.modules[modname] = mod
        spec.loader.exec_module(mod)
        mod.app.config["TESTING"] = True
        mod.app.test_client_class = TokenClient
        fake = FakeSystem()
        mod.run = fake
        mod.check_updates = lambda: dict(FAKE_UPDATE)
        return Panel(mod, fake, tmp_path)
    return factory


@pytest.fixture
def panel(make_panel):
    return make_panel()


@pytest.fixture
def fixed_time(monkeypatch):
    """Permite avançar o relógio: fixed_time(+200) faz time.time() andar 200 s à frente."""
    real = time.time
    offset = {"v": 0}
    monkeypatch.setattr(time, "time", lambda: real() + offset["v"])
    def advance(seconds):
        offset["v"] += seconds
    return advance
