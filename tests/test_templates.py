import re

import pytest

from conftest import ROOT

DASH = (ROOT / "templates/dashboard.html").read_text(encoding="utf-8")
LOGIN = (ROOT / "templates/login.html").read_text(encoding="utf-8")
SPANISH = ["Servicios", "Puertos", "Contraseña", "Eliminar", "Detener", "Usuarios Totales", "Actualiz", "Cerrar sesión",
           "Nuevo Usuario", "¿", "Bienvenido", "derechos", "Crear Usuario"]


@pytest.mark.parametrize("name,src", [("dashboard", DASH), ("login", LOGIN)])
def test_pt_br_and_no_auto_translation(name, src):
    assert 'lang="pt-BR"' in src and '<meta name="google" content="notranslate">' in src


@pytest.mark.parametrize("word", SPANISH)
def test_no_spanish_left_in_dashboard(word):
    body = DASH[DASH.index("<body"):]
    assert word not in body


@pytest.mark.parametrize("name,src", [("dashboard", DASH), ("login", LOGIN)])
def test_every_post_form_has_a_csrf_token(name, src):
    forms = re.findall(r"<form[^>]*method=\"POST\"[^>]*>.*?</form>", src, re.S)
    assert forms and all('name="csrf_token"' in f for f in forms)


def test_destructive_actions_are_not_plain_links():
    assert not re.search(r'href="/(control_service|delete_user|logout)', DASH)
    assert "window.location.href='/delete_user" not in DASH
    assert DASH.count("postAction('/control_service/") == 9 and "postAction('/logout')" in DASH


def test_admin_password_form_asks_for_8_chars_and_user_form_for_4():
    forms = re.findall(r"<form[^>]*>.*?</form>", DASH, re.S)
    admin = [f for f in forms if 'name="current_password"' in f][0]
    assert 'minlength="8"' in admin and "Mínimo de 8 caracteres" in admin
    user = [f for f in forms if "editPasswordForm" in f][0]
    assert 'minlength="4"' in user


def test_idle_script_is_present_and_uses_the_server_value():
    assert "const IDLE_TIMEOUT = {{ idle_timeout }};" in DASH
    for token in ("/api/ping", "X-CSRF-Token", "encerrarPorInatividade", "verificarInatividade"):
        assert token in DASH


def test_rendered_dashboard(panel):
    html = panel.client().get("/").get_data(as_text=True)
    for s in ("Serviços Ativos", "Portas:", "Total de usuários", "<span>RAM</span>", "Criar usuário", "Sistema atualizado"):
        assert s in html
    assert "const IDLE_TIMEOUT = 180;" in html
    assert re.search(r'<meta name="csrf-token" content="[^"]{20,}">', html)


# ───────────── sem CDN: tudo vem de static/vendor ─────────────
@pytest.mark.parametrize("name,src", [("dashboard", DASH), ("login", LOGIN)])
def test_templates_load_nothing_from_outside(name, src):
    assert not re.search(r'(href|src|action)="https?://', src)
    assert "googleapis" not in src and "jsdelivr" not in src and "gstatic" not in src
    assert not re.search(r"url\(\s*['\"]?https?://", src) and "@import" not in src


def test_every_static_file_the_pages_use_exists_and_is_served(panel):
    c = panel.client()
    urls = set()
    for html in (c.get("/").get_data(as_text=True), panel.m.app.test_client().get("/login").get_data(as_text=True)):
        urls |= set(re.findall(r'(?:href|src)="(/static/[^"]+)"', html))
    assert len(urls) >= 4
    for u in urls:
        r = c.get(u)
        assert r.status_code == 200 and len(r.data) > 100, u
        assert (ROOT / u.lstrip("/")).is_file()


def test_css_references_only_local_files(panel):
    for css in (ROOT / "static/vendor").rglob("*.css"):
        text = css.read_text(encoding="utf-8")
        for ref in re.findall(r"url\(\s*['\"]?([^'\")]+)", text):
            if ref.startswith("data:"):
                continue
            assert not ref.startswith(("http://", "https://", "//")), f"{css.name}: {ref}"
            assert (css.parent / ref.split("?")[0].split("#")[0]).is_file(), f"{css.name}: {ref} não existe"


def test_vendored_licenses_are_shipped():
    text = (ROOT / "static/vendor/LICENSES.txt").read_text(encoding="utf-8")
    for needle in ("Bootstrap 5.3.0 - MIT", "Bootstrap Icons 1.11.0 - MIT", "Orbitron", "Rajdhani", "SIL OPEN FONT LICENSE"):
        assert needle in text


def test_content_security_policy_blocks_third_party_content(panel):
    r = panel.m.app.test_client().get("/login")
    csp = r.headers["Content-Security-Policy"]
    for directive in ("default-src 'self'", "object-src 'none'", "frame-ancestors 'none'", "form-action 'self'", "base-uri 'self'"):
        assert directive in csp
    assert "http" not in csp and "*" not in csp, "a política não pode abrir exceção para hosts externos"
