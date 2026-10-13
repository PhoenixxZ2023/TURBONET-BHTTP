#!/usr/bin/env python3
import os
import re
import subprocess
import sys

ALLOWED_ACTIONS = {
    "systemctl": {"start", "stop", "restart", "enable", "disable", "is-active", "is-enabled"},
    "useradd": {"create"},
    "userdel": {"remove"},
    "usermod": {"modify"},
    "chpasswd": {"set"},
    "chage": {"set-expiry"},
    "groupadd": {"create"},
    "groupdel": {"remove"},
    "pkill": {"kill-user"},
}

SAFE_SERVICE_RE = re.compile(r"^(?:bhttp|hcr|udpgw|hex-webpanel)(?:@\d+)?(?:\.service)?$")
SAFE_USER_RE = re.compile(r"^[a-z_][a-z0-9_-]{0,31}$")
SAFE_PORT_RE = re.compile(r"^\d{1,5}$")


def safe_arg(value):
    if value is None:
        raise ValueError("argumento nulo")
    s = str(value).strip()
    if not s:
        raise ValueError("argumento vazio")
    if any(ch in s for ch in (";", "|", "&", "`", "$", "\n", "\r", ">", "<")):
        raise ValueError(f"caracter inválido em argumento: {s!r}")
    return s


def run_once(cmd):
    p = subprocess.run(cmd, capture_output=True, text=True, timeout=20)
    if p.stdout:
        sys.stdout.write(p.stdout)
    if p.stderr:
        sys.stderr.write(p.stderr)
    return p.returncode


def handle_systemctl(args):
    if len(args) < 2:
        raise ValueError("systemctl requer ação e alvo")
    action = safe_arg(args[0])
    target = safe_arg(args[1])
    if action not in ALLOWED_ACTIONS["systemctl"]:
        raise ValueError(f"ação systemctl não permitida: {action}")
    if not SAFE_SERVICE_RE.fullmatch(target):
        raise ValueError(f"alvo inválido para systemctl: {target}")
    return run_once(["/usr/bin/systemctl", action, target])


def handle_useradd(args):
    if len(args) < 1:
        raise ValueError("useradd requer usuário")
    user = safe_arg(args[0])
    if not SAFE_USER_RE.fullmatch(user):
        raise ValueError(f"usuário inválido: {user}")
    cmd = ["/usr/sbin/useradd", "-m", "-s", "/bin/bash", user]
    if len(args) > 1:
        for extra in args[1:]:
            if extra.startswith("-"):
                continue
            cmd.append(safe_arg(extra))
    return run_once(cmd)


def handle_userdel(args):
    if len(args) < 1:
        raise ValueError("userdel requer usuário")
    user = safe_arg(args[0])
    if not SAFE_USER_RE.fullmatch(user):
        raise ValueError(f"usuário inválido: {user}")
    return run_once(["/usr/sbin/userdel", "-r", user])


def handle_usermod(args):
    if len(args) < 2:
        raise ValueError("usermod requer usuário e flag")
    user = safe_arg(args[0])
    if not SAFE_USER_RE.fullmatch(user):
        raise ValueError(f"usuário inválido: {user}")
    opt = safe_arg(args[1])
    cmd = ["/usr/sbin/usermod", opt, user]
    if len(args) > 2:
        cmd.extend(safe_arg(a) for a in args[2:])
    return run_once(cmd)


def handle_chpasswd(args):
    if len(args) < 1:
        raise ValueError("chpasswd requer usuário e senha via stdin")
    user = safe_arg(args[0])
    if not SAFE_USER_RE.fullmatch(user):
        raise ValueError(f"usuário inválido: {user}")
    data = os.environ.get("HEX_CHPASSWD_INPUT", "")
    if not data:
        raise ValueError("stdin vazio para chpasswd")
    p = subprocess.run(["/usr/sbin/chpasswd"], input=data, text=True, capture_output=True, timeout=20)
    if p.stdout:
        sys.stdout.write(p.stdout)
    if p.stderr:
        sys.stderr.write(p.stderr)
    return p.returncode


def handle_chage(args):
    if len(args) < 2:
        raise ValueError("chage requer ação e usuário")
    action = safe_arg(args[0])
    user = safe_arg(args[1])
    if not SAFE_USER_RE.fullmatch(user):
        raise ValueError(f"usuário inválido: {user}")
    if action == "-E":
        return run_once(["/usr/bin/chage", action, args[2] if len(args) > 2 else "-1", user])
    if action == "-e":
        return run_once(["/usr/bin/chage", action, args[2] if len(args) > 2 else "", user])
    return run_once(["/usr/bin/chage", action, user])


def handle_groupadd(args):
    if len(args) < 1:
        raise ValueError("groupadd requer grupo")
    group = safe_arg(args[0])
    if not re.fullmatch(r"[a-z_][a-z0-9_-]*", group):
        raise ValueError(f"grupo inválido: {group}")
    return run_once(["/usr/sbin/groupadd", group])


def handle_groupdel(args):
    if len(args) < 1:
        raise ValueError("groupdel requer grupo")
    group = safe_arg(args[0])
    if not re.fullmatch(r"[a-z_][a-z0-9_-]*", group):
        raise ValueError(f"grupo inválido: {group}")
    return run_once(["/usr/sbin/groupdel", group])


def handle_pkill(args):
    if len(args) < 2:
        raise ValueError("pkill requer sinal e usuário")
    flag = safe_arg(args[0])
    user = safe_arg(args[1])
    if flag not in {"-KILL", "-TERM"}:
        raise ValueError(f"sinal inválido: {flag}")
    if not SAFE_USER_RE.fullmatch(user):
        raise ValueError(f"usuário inválido: {user}")
    return run_once(["/usr/bin/pkill", flag, "-u", user])


def main():
    if len(sys.argv) < 2:
        print("uso: hex_privileged <action> [args...]", file=sys.stderr)
        return 2
    action = safe_arg(sys.argv[1])
    args = [safe_arg(a) for a in sys.argv[2:]]
    handlers = {
        "systemctl": handle_systemctl,
        "useradd": handle_useradd,
        "userdel": handle_userdel,
        "usermod": handle_usermod,
        "chpasswd": handle_chpasswd,
        "chage": handle_chage,
        "groupadd": handle_groupadd,
        "groupdel": handle_groupdel,
        "pkill": handle_pkill,
    }
    if action not in handlers:
        print(f"ação não permitida: {action}", file=sys.stderr)
        return 2
    try:
        return handlers[action](args)
    except Exception as exc:
        print(f"erro: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
