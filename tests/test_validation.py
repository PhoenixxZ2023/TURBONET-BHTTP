import os
import stat

import pytest


@pytest.mark.parametrize("name,ok", [("joao", True), ("j_o-1", True), ("_x", True), ("a" * 32, True), ("a" * 33, False),
                                     ("1abc", False), ("-r", False), ("Joao", False), ("a b", False), ("a:b", False),
                                     ("", False), ("root;rm", False), ("a\nb", False)])
def test_valid_username(panel, name, ok):
    assert panel.m.valid_username(name) is ok


@pytest.mark.parametrize("pw,ok", [("abcd", True), ("abc", False), ("a" * 64, True), ("a" * 65, False), ("a:b", False),
                                   ("a\nb", False), ("com espaço", True), ("Pa$$w0rd/&\\", True), ("ação123", True),
                                   ("", False), ("a\x00bcd", False), ("a\x7fbcd", False)])
def test_valid_user_password(panel, pw, ok):
    assert panel.m.valid_user_password(pw) is ok


@pytest.mark.parametrize("d,ok", [("2030-02-28", True), ("2030-02-30", False), ("2030-13-01", False), ("--help", False),
                                  ("", False), (None, False), ("30-01-2030", False)])
def test_valid_date(panel, d, ok):
    assert panel.m.valid_date(d) is ok


@pytest.mark.parametrize("a,b,expected", [("1.1.8", "1.1.7", 1), ("1.10.0", "1.9.9", 1), ("1.0.0", "1.0", 0),
                                          ("1.2", "1.10", -1), ("2.0.0", "1.99.99", 1), ("1.0.0", "1.0.0", 0),
                                          ("lixo", "lixo", 0)])
def test_compare_versions(panel, a, b, expected):
    assert panel.m.compare_versions(a, b) == expected


def test_write_atomic_content_mode_and_no_leftovers(panel, tmp_path):
    target = tmp_path / "x" / "arquivo.txt"
    panel.m.write_atomic(str(target), "olá")
    assert target.read_text() == "olá"
    assert stat.S_IMODE(os.stat(target).st_mode) == 0o600
    panel.m.write_atomic(str(target), b"novo", 0o644)
    assert target.read_bytes() == b"novo" and stat.S_IMODE(os.stat(target).st_mode) == 0o644
    assert [p.name for p in target.parent.iterdir()] == ["arquivo.txt"], "sobrou arquivo temporário"


@pytest.mark.parametrize("line,expected", [
    ("joao:2030-01-01\n", ("joao", "2030-01-01")),
    ("joao:senha:2030-01-01", ("joao", "2030-01-01")),                 # formato antigo
    ("ana:p:a:ss:w/o&rd:2031-02-02", ("ana", "2031-02-02")),           # senha antiga com ':' e símbolos
    ("", None), ("semdoispontos", None), (":2030-01-01", None)])
def test_parse_line(panel, line, expected):
    assert panel.m._parse_line(line) == expected


def test_db_roundtrip_has_no_password_and_is_0600(panel):
    panel.m.write_db([("joao", "2030-01-01"), ("ana", "2031-02-02")])
    path = panel.etc / "users.txt"
    assert path.read_text() == "joao:2030-01-01\nana:2031-02-02\n"
    assert stat.S_IMODE(os.stat(path).st_mode) == 0o600
    assert panel.m.read_db() == [("joao", "2030-01-01"), ("ana", "2031-02-02")]
    assert panel.m.db_has("ana") and not panel.m.db_has("zé")


def test_migrate_users_db_removes_passwords_and_is_idempotent(panel):
    path = panel.etc / "users.txt"
    path.write_text("uleg1:abc123:2030-01-01\nuleg2:p:a:ss:w/o&rd:2031-02-02\nnovo:2032-03-03\n")
    panel.m.migrate_users_db()
    assert path.read_text() == "uleg1:2030-01-01\nuleg2:2031-02-02\nnovo:2032-03-03\n"
    assert "abc123" not in path.read_text() and "w/o" not in path.read_text()
    assert stat.S_IMODE(os.stat(path).st_mode) == 0o600
    before = path.read_text(); panel.m.migrate_users_db()
    assert path.read_text() == before


def test_migrate_with_missing_file_is_a_noop(panel):
    (panel.etc / "users.txt").unlink(missing_ok=True)
    panel.m.migrate_users_db()
    assert not (panel.etc / "users.txt").exists()


def test_default_shell_is_tunnel_only(panel):
    assert panel.m.get_user_shell() in ("/usr/sbin/nologin", "/bin/false")


@pytest.mark.parametrize("content", ["bash", "/bin/zsh", "; rm -rf /", "", "/nao/existe"])
def test_invalid_shell_file_falls_back_to_tunnel_only(panel, content):
    (panel.etc / "user_shell").write_text(content)
    assert panel.m.get_user_shell() in ("/usr/sbin/nologin", "/bin/false")


def test_shell_opt_in_bash(panel):
    (panel.etc / "user_shell").write_text("/bin/bash\n")
    assert panel.m.get_user_shell() == "/bin/bash"


@pytest.mark.parametrize("env,expected", [("5", 30), ("abc", 180), ("99999999", 86400), ("120", 120), ("30", 30)])
def test_idle_timeout_is_clamped(make_panel, env, expected):
    assert make_panel(env={"HEX_SESSION_IDLE_SECONDS": env}).m.IDLE_TIMEOUT == expected


def test_idle_timeout_default_is_three_minutes(panel):
    assert panel.m.IDLE_TIMEOUT == 180


def test_secret_key_and_initial_password_files(panel):
    key = panel.etc / "webpanel_secret.key"
    assert len(key.read_bytes()) == 32 and stat.S_IMODE(os.stat(key).st_mode) == 0o600
    assert len(panel.password) == 12
    assert panel.password not in ("admin26", "HexAdmin2026")
    h = (panel.etc / "webpanel_admin_pass.conf").read_text().strip()
    assert h.startswith("$2") and panel.password not in h
