import datetime
import re

import pytest


def post(c, path, **data):
    return c.post(path, data=data)


def flashes(c):
    with c.session_transaction() as s:
        return [m for _, m in s.get("_flashes", [])] if s.get("_flashes") and isinstance(s["_flashes"][0], (list, tuple)) else list(s.get("_flashes", []))


def add(c, user="joao", pw="Segredo123", days="5"):
    return post(c, "/add_user", username=user, password=pw, days=days)


def test_add_user_creates_account_with_tunnel_only_shell_and_no_password_on_disk(panel):
    c = panel.client()
    assert add(c).status_code == 302
    assert panel.fake.users["joao"]["shell"] in ("/usr/sbin/nologin", "/bin/false")
    assert panel.fake.users["joao"]["pw"] == "Segredo123"          # a senha vai só para o chpasswd
    text = (panel.etc / "users.txt").read_text()
    assert re.fullmatch(r"joao:\d{4}-\d{2}-\d{2}\n", text), text
    assert "Segredo123" not in text


def test_add_user_lowercases_the_username(panel):
    add(panel.client(), user="  JoaoPaulo ")
    assert "joaopaulo" in panel.fake.users and panel.m.read_db()[0][0] == "joaopaulo"


def test_add_user_opt_in_shell(panel):
    (panel.etc / "user_shell").write_text("/bin/bash")
    add(panel.client())
    assert panel.fake.users["joao"]["shell"] == "/bin/bash"


@pytest.mark.parametrize("user,pw,days", [("ab cd", "abcd", "5"), ("-r", "abcd", "5"), ("root", "abcd", "5"), ("a:b", "abcd", "5"),
                                          ("joao", "a:b", "5"), ("joao", "abc", "5"), ("joao", "abcd", "0"),
                                          ("joao", "abcd", "abc"), ("joao", "abcd", "3651")])
def test_add_user_rejects_invalid_input(panel, user, pw, days):
    c = panel.client()
    before = set(panel.fake.users)
    add(c, user, pw, days)
    assert set(panel.fake.users) == before
    assert panel.m.read_db() == []


def test_add_user_rolls_back_when_password_cannot_be_set(panel):
    panel.fake.fail.add("chpasswd")
    add(panel.client())
    assert "joao" not in panel.fake.users and panel.m.read_db() == []


def test_add_user_failure_in_useradd_creates_nothing(panel):
    panel.fake.fail.add("useradd")
    add(panel.client())
    assert "joao" not in panel.fake.users and panel.m.read_db() == []


def test_edit_password_changes_system_password_but_not_the_file(panel):
    c = panel.client(); add(c)
    before = (panel.etc / "users.txt").read_text()
    post(c, "/edit_password/joao", new_password="Nova/Senha&1", confirm_password="Nova/Senha&1")
    assert panel.fake.users["joao"]["pw"] == "Nova/Senha&1"
    assert (panel.etc / "users.txt").read_text() == before
    assert "Nova" not in before


@pytest.mark.parametrize("new,conf", [("abc", "abc"), ("a:b:c:d", "a:b:c:d"), ("abcd", "abce")])
def test_edit_password_validation(panel, new, conf):
    c = panel.client(); add(c)
    post(c, "/edit_password/joao", new_password=new, confirm_password=conf)
    assert panel.fake.users["joao"]["pw"] == "Segredo123"


@pytest.mark.parametrize("target", ["root", "nobody", "naoexiste", "-r"])
def test_routes_refuse_accounts_not_managed_by_the_panel(panel, target):
    c = panel.client()
    n_calls = len(panel.fake.calls)
    post(c, f"/edit_password/{target}", new_password="hacked123", confirm_password="hacked123")
    post(c, f"/edit_expiry/{target}", action="permanent")
    post(c, f"/delete_user/{target}")
    assert all(Path(cmd[0]).name not in ("chpasswd", "userdel") for cmd in panel.fake.calls[n_calls:])
    assert panel.fake.users.get("root") is not None and panel.fake.users["root"]["pw"] is None


def test_edit_expiry_variants(panel):
    c = panel.client(); add(c)
    today = datetime.date.today()
    post(c, "/edit_expiry/joao", action="permanent")
    assert panel.m.read_db() == [("joao", "2099-12-31")]
    post(c, "/edit_expiry/joao", action="custom", custom_date="2031-05-06")
    assert panel.m.read_db() == [("joao", "2031-05-06")]
    post(c, "/edit_expiry/joao", action="extend_30")                      # estende a partir da data atual (futura)
    assert panel.m.read_db() == [("joao", "2031-06-05")]
    for bad in ("2030-13-45", "--help", "", "31/12/2030"):
        post(c, "/edit_expiry/joao", action="custom", custom_date=bad)
    post(c, "/edit_expiry/joao", action="rm -rf")
    assert panel.m.read_db() == [("joao", "2031-06-05")]
    assert today.year < 2031


def test_edit_expiry_extends_from_today_when_already_expired(panel):
    c = panel.client(); add(c)
    panel.m.write_db([("joao", "2020-01-01")])
    post(c, "/edit_expiry/joao", action="extend_7")
    exp = datetime.date.fromisoformat(panel.m.read_db()[0][1])
    assert exp == datetime.date.today() + datetime.timedelta(days=7)


def test_delete_user_only_via_post_and_only_managed(panel):
    c = panel.client(); add(c)
    assert c.get("/delete_user/joao").status_code == 405
    assert "joao" in panel.fake.users
    post(c, "/delete_user/joao")
    assert "joao" not in panel.fake.users and panel.m.read_db() == []


def test_delete_keeps_db_entry_if_account_could_not_be_removed(panel):
    c = panel.client(); add(c)
    panel.fake.fail.add("userdel")
    post(c, "/delete_user/joao")
    assert "joao" in panel.fake.users and panel.m.db_has("joao")


@pytest.mark.parametrize("path", ["/delete_user/x", "/control_service/bhttp/stop", "/logout"])
def test_state_changing_routes_do_not_accept_get(panel, path):
    assert panel.client().get(path).status_code == 405


def test_control_service_runs_systemctl_for_each_port(panel):
    (panel.etc / "bhttp_ports.conf").write_text("80\n8880\n")
    c = panel.client()
    post(c, "/control_service/bhttp/restart")
    units = [cmd[2] for cmd in panel.fake.calls if cmd[:2] and cmd[0].endswith("systemctl") and cmd[1] == "restart"]
    assert units == ["bhttp@80.service", "bhttp@8880.service"]


@pytest.mark.parametrize("svc,action", [("sshd", "stop"), ("bhttp", "rm"), ("../x", "stop")])
def test_control_service_rejects_unknown_service_or_action(panel, svc, action):
    (panel.etc / "bhttp_ports.conf").write_text("80\n")
    c = panel.client(); n = len(panel.fake.calls)
    post(c, f"/control_service/{svc}/{action}")
    assert not [x for x in panel.fake.calls[n:] if x[1] in ("stop", "start", "restart")]


def test_ports_conf_with_garbage_is_filtered(panel):
    (panel.etc / "bhttp_ports.conf").write_text("80\n$(rm -rf /)\n8880; reboot\n 443 \n")
    assert panel.m.read_ports("bhttp") == ["80", "443"]


from pathlib import Path  # noqa: E402  (usado nos testes acima)
