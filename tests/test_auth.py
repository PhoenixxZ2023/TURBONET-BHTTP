import os
import re
import subprocess
import sys

import pytest
from flask import Flask
from flask.sessions import SecureCookieSessionInterface

from conftest import ROOT


def bad_login(panel, addr, headers=None, n=1):
    code = None
    for _ in range(n):
        c = panel.m.app.test_client()
        tok = panel.login_page_token(c)
        code = c.post("/login", data={"password": "errada", "csrf_token": tok},
                      environ_base={"REMOTE_ADDR": addr}, headers=headers or {}).status_code
    return code


# ───────────── login, senha, bloqueio ─────────────
def test_login_wrong_and_old_default_password(panel):
    c = panel.m.app.test_client(); tok = panel.login_page_token(c)
    for pw in ("admin26", "HexAdmin2026", "", "x" * 100):
        assert c.post("/login", data={"password": pw, "csrf_token": tok}).status_code == 200


def test_login_ok_sets_secure_cookie_flags(panel):
    c = panel.m.app.test_client(); tok = panel.login_page_token(c)
    r = c.post("/login", data={"password": panel.password, "csrf_token": tok})
    assert r.status_code == 302
    cookie = [h for h in r.headers.getlist("Set-Cookie") if h.startswith("hex_session")][0]
    assert "HttpOnly" in cookie and "SameSite=Strict" in cookie and "Secure" not in cookie


def test_cookie_is_secure_when_tls_is_enabled(make_panel):
    p = make_panel(env={"HEX_PANEL_TLS": "1"})
    c = p.m.app.test_client()
    cookie = [h for h in c.get("/login").headers.getlist("Set-Cookie") if h.startswith("hex_session")][0]
    assert "Secure" in cookie


def test_lockout_after_five_failures(panel):
    assert bad_login(panel, "7.7.7.7", n=5) == 200
    assert bad_login(panel, "7.7.7.7") == 429
    assert bad_login(panel, "7.7.7.8") == 200          # outro IP não é afetado


def test_forged_cookie_with_the_old_public_secret_key_is_rejected(panel):
    d = Flask("x"); d.secret_key = "hex_secret_key_mudar_123"
    forged = SecureCookieSessionInterface().get_signing_serializer(d).dumps({"_user_id": "admin", "_fresh": True})
    c = panel.m.app.test_client(); c.set_cookie("hex_session", forged)
    assert c.get("/").status_code == 302


def test_protected_routes_redirect_to_login(panel):
    c = panel.m.app.test_client()
    for path in ("/", "/api/stats"):
        assert c.get(path).status_code == 302


def test_security_headers(panel):
    r = panel.m.app.test_client().get("/login")
    assert r.headers["X-Frame-Options"] == "DENY" and r.headers["X-Content-Type-Options"] == "nosniff"
    assert "Strict-Transport-Security" not in r.headers      # certificado autoassinado: HSTS travaria o navegador


def test_change_admin_password_rules(panel):
    c = panel.client(); old = panel.password
    def change(cur, new, conf):
        return c.post("/change_password", data={"current_password": cur, "new_password": new, "confirm_password": conf})
    change(old, "curta", "curta")                                   # < 8
    change(old, "x" * 73, "x" * 73)                                 # > 72 bytes
    change("errada", "MinhaSenhaForte1", "MinhaSenhaForte1")
    change(old, "MinhaSenhaForte1", "outra")
    change(old, old, old)                                           # igual à atual
    assert panel.m.verify_password(old, panel.m.ADMIN_PASSWORD_HASH)
    change(old, "MinhaSenhaForte1", "MinhaSenhaForte1")
    assert panel.m.verify_password("MinhaSenhaForte1", panel.m.ADMIN_PASSWORD_HASH)
    assert not panel.m.verify_password(old, panel.m.ADMIN_PASSWORD_HASH)
    assert not (panel.etc / "webpanel_initial_password.txt").exists()


# ───────────── CSRF ─────────────
def test_login_requires_csrf_token(panel):
    c = panel.m.app.test_client(); tok = panel.login_page_token(c)
    assert c.post("/login", data={"password": panel.password}, no_csrf=True).status_code == 403
    assert c.post("/login", data={"password": panel.password, "csrf_token": "errado"}).status_code == 403
    assert c.post("/login", data={"password": panel.password, "csrf_token": tok}).status_code == 302


def test_post_without_or_with_wrong_token_is_rejected(panel):
    c = panel.client()
    assert c.post("/add_user", data={"username": "zz", "password": "abcd", "days": "1"}, no_csrf=True).status_code == 403
    assert c.post("/add_user", data={"username": "zz", "password": "abcd", "days": "1", "csrf_token": "x"}, no_csrf=True).status_code == 403
    assert "zz" not in panel.fake.users


def test_token_from_another_session_is_rejected(panel):
    a, b = panel.client(), panel.client()
    r = b.post("/add_user", data={"username": "zz", "password": "abcd", "days": "1", "csrf_token": panel.token(a)}, no_csrf=True)
    assert r.status_code == 403


@pytest.mark.parametrize("origin", ["http://evil.example", "null", "https://painel.exemplo.com.evil.com"])
def test_foreign_origin_is_rejected_even_with_valid_token(panel, origin):
    c = panel.client()
    r = c.post("/add_user", data={"username": "zz", "password": "abcd", "days": "1"}, headers={"Origin": origin})
    assert r.status_code == 403 and "zz" not in panel.fake.users


def test_trusted_host_origin_is_accepted(make_panel):
    p = make_panel(env={"HEX_TRUSTED_HOSTS": "painel.exemplo.com"})
    c = p.client()
    r = c.post("/add_user", data={"username": "zz", "password": "abcd", "days": "1"}, headers={"Origin": "https://painel.exemplo.com"})
    assert r.status_code == 302 and "zz" in p.fake.users


# ───────────── expiração por inatividade ─────────────
def test_login_records_activity_and_pages_renew_it(panel, fixed_time):
    c = panel.client()
    assert isinstance(panel.last_seen(c), int)
    panel.set_last_seen(c, int(__import__("time").time()) - 100)
    assert c.get("/").status_code == 200
    assert panel.last_seen(c) >= int(__import__("time").time()) - 1


def test_background_polling_does_not_renew_the_session(panel):
    import time
    c = panel.client(); old = int(time.time()) - 100
    panel.set_last_seen(c, old)
    assert c.get("/api/stats").status_code == 200
    assert panel.last_seen(c) == old


def test_ping_renews_and_reports_the_timeout(panel):
    import time
    c = panel.client(); panel.set_last_seen(c, int(time.time()) - 100)
    r = c.post("/api/ping", headers={"X-CSRF-Token": panel.token(c)}, no_csrf=True)
    assert r.status_code == 200 and r.get_json() == {"ok": True, "idle_timeout": 180}
    assert panel.last_seen(c) >= int(time.time()) - 1
    assert c.post("/api/ping", no_csrf=True).status_code == 403


def test_session_within_the_limit_stays_valid_and_beyond_it_expires(panel):
    import time
    c = panel.client(); idle = panel.m.IDLE_TIMEOUT
    panel.set_last_seen(c, int(time.time()) - (idle - 5))
    assert c.get("/").status_code == 200
    panel.set_last_seen(c, int(time.time()) - (idle + 5))
    r = c.get("/")
    assert r.status_code == 302 and "/login" in r.headers["Location"]
    assert "Sessão expirada por inatividade" in c.get("/login").get_data(as_text=True)
    assert c.get("/").status_code == 302


@pytest.mark.parametrize("value", ["missing", 12345])
def test_missing_or_ancient_last_seen_counts_as_expired(panel, value):
    c = panel.client()
    with c.session_transaction() as s:
        if value == "missing": s.pop("last_seen", None)
        else: s["last_seen"] = value
    assert c.get("/").status_code == 302


def test_expired_api_calls_get_401_and_cannot_revive_the_session(panel):
    import time
    for path, kw in (("/api/stats", {}), ("/api/ping", {"method": "POST"}), ("/update_now", {"method": "POST"})):
        c = panel.client(); panel.set_last_seen(c, int(time.time()) - 500)
        headers = {"X-CSRF-Token": panel.token(c)}
        r = c.post(path, headers=headers, no_csrf=True) if kw else c.get(path)
        assert r.status_code == 401 and r.get_json()["expired"] is True
        assert c.get("/").status_code == 302


def test_actions_with_an_expired_session_do_not_run(panel):
    import time
    c = panel.client(); tok = panel.token(c)
    panel.set_last_seen(c, int(time.time()) - 500)
    r = c.post("/add_user", data={"username": "zzexp", "password": "abcd", "days": "3", "csrf_token": tok}, no_csrf=True)
    assert r.status_code == 302 and "/login" in r.headers["Location"] and "zzexp" not in panel.fake.users


def test_old_cookie_with_valid_signature_is_refused_after_the_timeout(panel, fixed_time):
    c = panel.client(); cookie = c.get_cookie("hex_session").value
    fixed_time(panel.m.IDLE_TIMEOUT + 10)
    c2 = panel.m.app.test_client(); c2.set_cookie("hex_session", cookie)
    assert c2.get("/").status_code == 302


def test_logout_messages(panel):
    c = panel.client()
    assert c.post("/logout", data={"reason": "idle"}).status_code == 302
    assert "encerrada por inatividade" in c.get("/login").get_data(as_text=True)
    c = panel.client(); c.post("/logout")
    assert "inatividade" not in c.get("/login").get_data(as_text=True)


# ───────────── IP real atrás da Cloudflare ─────────────
def test_cloudflare_client_ip_is_used_only_for_cloudflare_connections(panel):
    assert bad_login(panel, "104.16.1.1", {"CF-Connecting-IP": "198.51.100.1"}, n=5) == 200
    assert bad_login(panel, "104.16.1.1", {"CF-Connecting-IP": "198.51.100.1"}) == 429
    assert bad_login(panel, "104.16.1.1", {"CF-Connecting-IP": "198.51.100.2"}) == 200      # outro visitante, mesmo IP da CF
    for i in range(5):
        bad_login(panel, "9.9.9.9", {"CF-Connecting-IP": f"198.51.100.{100 + i}"})
    assert bad_login(panel, "9.9.9.9", {"CF-Connecting-IP": "198.51.100.250"}) == 429       # cabeçalho forjado é ignorado
    for _ in range(5):
        bad_login(panel, "104.16.2.2", {"CF-Connecting-IP": "lixo"})
    assert bad_login(panel, "104.16.2.2", {"CF-Connecting-IP": "lixo"}) == 429


def test_cloudflare_trust_can_be_disabled(make_panel):
    p = make_panel(env={"HEX_TRUST_CLOUDFLARE": "0"})
    assert p.m.TRUST_CLOUDFLARE is False
    bad_login(p, "104.16.1.1", {"CF-Connecting-IP": "198.51.100.1"}, n=5)
    assert bad_login(p, "104.16.1.1", {"CF-Connecting-IP": "198.51.100.9"}) == 429          # agora conta pelo IP da conexão


# ───────────── redefinição de senha pela linha de comando ─────────────
def run_cli(tmp, *args, stdin=None):
    env = dict(os.environ, HEX_DIR=str(tmp / "etc"), HEX_LOG=str(tmp / "cli.log"))
    return subprocess.run([sys.executable, str(ROOT / "app.py"), *args], input=stdin, capture_output=True, text=True, env=env, timeout=60)


def test_cli_reset_and_set_password(tmp_path):
    (tmp_path / "etc").mkdir()
    run_cli(tmp_path, "--reset-password")
    key1 = (tmp_path / "etc/webpanel_secret.key").read_bytes()
    r = run_cli(tmp_path, "--reset-password")
    assert r.returncode == 0 and r.stdout.startswith("NOVA_SENHA=") and len(r.stdout.strip().split("=")[1]) == 12
    assert (tmp_path / "etc/webpanel_secret.key").read_bytes() != key1            # derruba as sessões abertas
    senha = 'Senh@ Nov4/&é"\\'
    r = run_cli(tmp_path, "--set-password", stdin=senha + "\n")
    assert r.returncode == 0 and r.stdout.strip() == "SENHA_DEFINIDA"
    assert not (tmp_path / "etc/webpanel_initial_password.txt").exists()
    before = (tmp_path / "etc/webpanel_admin_pass.conf").read_text()
    for bad in ("curta", "a" * 73):
        r = run_cli(tmp_path, "--set-password", stdin=bad + "\n")
        assert r.returncode == 2
    assert (tmp_path / "etc/webpanel_admin_pass.conf").read_text() == before
