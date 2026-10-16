import base64
import hashlib
import json
import os
import shutil
import stat
import subprocess

import pytest

from conftest import ROOT

pytestmark = pytest.mark.skipif(shutil.which("openssl") is None, reason="precisa de openssl")
SIG = f'HEX_SOURCE_ONLY=1 source "{ROOT}/src/lib/signature.sh"'


def sh(code, env=None):
    return subprocess.run(["bash", "-c", code], capture_output=True, text=True, env={**os.environ, **(env or {})})


def new_key(tmp, name):
    priv, pub = tmp / f"{name}.pem", tmp / f"{name}_pub.pem"
    subprocess.run(["openssl", "genpkey", "-algorithm", "ed25519", "-out", str(priv)], check=True, capture_output=True)
    subprocess.run(["openssl", "pkey", "-in", str(priv), "-pubout", "-out", str(pub)], check=True, capture_output=True)
    return priv, pub


def sign(priv, data: bytes, tmp):
    f, o = tmp / "m.bin", tmp / "s.bin"
    f.write_bytes(data)
    subprocess.run(["openssl", "pkeyutl", "-sign", "-inkey", str(priv), "-rawin", "-in", str(f), "-out", str(o)], check=True, capture_output=True)
    return base64.b64encode(o.read_bytes())


@pytest.fixture
def keys(tmp_path):
    a, apub = new_key(tmp_path, "a"); b, bpub = new_key(tmp_path, "b")
    return {"priv": a, "pub": apub, "other_priv": b, "other_pub": bpub}


MANIFEST = json.dumps({"version": "9.9.9", "sha256": {"x": "0" * 64}}).encode()


# ───────────── verificação em bash (instaladores e menu) ─────────────
def verify_sh(tmp, man: bytes, sig: bytes, pub):
    (tmp / "version.json").write_bytes(man); (tmp / "version.json.sig").write_bytes(sig)
    return sh(f'{SIG}\nhex_verificar_assinatura "{tmp}/version.json" "{tmp}/version.json.sig" "{pub}"').returncode


def test_bash_accepts_valid_signature_and_rejects_everything_else(tmp_path, keys):
    good = sign(keys["priv"], MANIFEST, tmp_path)
    assert verify_sh(tmp_path, MANIFEST, good, keys["pub"]) == 0
    assert verify_sh(tmp_path, MANIFEST + b" ", good, keys["pub"]) != 0                    # manifesto alterado
    assert verify_sh(tmp_path, MANIFEST, good, keys["other_pub"]) != 0                      # chave errada
    assert verify_sh(tmp_path, MANIFEST, sign(keys["other_priv"], MANIFEST, tmp_path), keys["pub"]) != 0   # assinada por outro
    assert verify_sh(tmp_path, MANIFEST, b"isso nao e base64 !!!", keys["pub"]) != 0
    assert verify_sh(tmp_path, MANIFEST, b"", keys["pub"]) != 0
    assert verify_sh(tmp_path, MANIFEST, good[:20], keys["pub"]) != 0                       # truncada
    assert verify_sh(tmp_path, MANIFEST, good, tmp_path / "nao_existe.pem") != 0


def test_fingerprint_is_stable_and_matches_the_sha256_of_the_public_key(tmp_path, keys):
    r = sh(f'{SIG}\nhex_fingerprint "{keys["pub"]}"').stdout.strip()
    der = subprocess.run(["openssl", "pkey", "-pubin", "-in", str(keys["pub"]), "-outform", "DER"], capture_output=True).stdout
    expected = ":".join(hashlib.sha256(der).hexdigest()[i:i + 2] for i in range(0, 64, 2))
    assert r == expected and len(r.split(":")) == 32


def policy(tmp, pinned, sig_bytes, man=MANIFEST, env=None):
    (tmp / "version.json").write_bytes(man)
    sigp = tmp / "version.json.sig"
    if sig_bytes is None: sigp.unlink(missing_ok=True)
    else: sigp.write_bytes(sig_bytes)
    pin = tmp / "pinned.pem"
    pin.unlink(missing_ok=True)
    if pinned: shutil.copy(pinned, pin)
    return sh(f'{SIG}\nHEX_PUBKEY="{pin}"\nhex_politica_assinatura "{tmp}/version.json" "{sigp if sig_bytes is not None else ""}"', env)


def test_policy_requires_a_signature_once_the_key_is_pinned(tmp_path, keys):
    good = sign(keys["priv"], MANIFEST, tmp_path)
    assert policy(tmp_path, None, None).returncode == 0                                    # sem chave fixada: segue (só SHA256)
    assert policy(tmp_path, keys["pub"], good).returncode == 0
    r = policy(tmp_path, keys["pub"], None)
    assert r.returncode == 1 and "ausente ou inválida" in r.stdout and ":" in r.stdout      # remover a assinatura NÃO funciona
    assert policy(tmp_path, keys["pub"], b"AAAA").returncode == 1
    assert policy(tmp_path, keys["pub"], good, man=MANIFEST + b"x").returncode == 1
    assert policy(tmp_path, keys["pub"], sign(keys["other_priv"], MANIFEST, tmp_path)).returncode == 1
    assert policy(tmp_path, keys["pub"], None, env={"HEX_ALLOW_UNSIGNED": "1"}).returncode == 0  # válvula de recuperação


# ───────────── verificação em Python (OTA do painel) = mesmo resultado ─────────────
def test_python_verification_matches_bash(panel, tmp_path, keys):
    good = sign(keys["priv"], MANIFEST, tmp_path)
    v = panel.m.verify_manifest_signature
    assert v(MANIFEST, good, str(keys["pub"])) is True
    assert v(MANIFEST + b" ", good, str(keys["pub"])) is False
    assert v(MANIFEST, good, str(keys["other_pub"])) is False
    assert v(MANIFEST, b"lixo!!", str(keys["pub"])) is False
    assert v(MANIFEST, b"", str(keys["pub"])) is False
    assert v(MANIFEST, good, str(tmp_path / "nao_existe.pem")) is False
    assert v(b"", good, str(keys["pub"])) is False


# ───────────── OTA do painel com chave fixada ─────────────
from test_ota import server, installed  # noqa: E402,F401


def publish_signed(server, tmp_path, priv, **kw):
    server.publish(**kw)
    raw = (tmp_path / "srv/version.json").read_bytes()
    (tmp_path / "srv/version.json.sig").write_bytes(sign(priv, raw, tmp_path))


def test_ota_with_pinned_key_accepts_a_signed_manifest(installed, server, tmp_path, keys):
    shutil.copy(keys["pub"], tmp_path / "etc/release_pub.pem")
    publish_signed(server, tmp_path, keys["priv"])
    res = installed.m.perform_update()
    assert all(v["success"] for v in res.values()), res


def test_ota_with_pinned_key_refuses_unsigned_or_wrongly_signed(installed, server, tmp_path, keys):
    shutil.copy(keys["pub"], tmp_path / "etc/release_pub.pem")
    server.publish()                                                                       # sem .sig
    res = installed.m.perform_update()
    assert not any(v["success"] for v in res.values()) and "assinatura" in res["menu"]["message"]
    assert b"antigo" in (tmp_path / "bin/hex_menu").read_bytes()
    publish_signed(server, tmp_path, keys["other_priv"])                                   # assinada por outra chave
    assert not any(v["success"] for v in installed.m.perform_update().values())


def test_ota_refuses_a_manifest_changed_after_signing(installed, server, tmp_path, keys):
    shutil.copy(keys["pub"], tmp_path / "etc/release_pub.pem")
    publish_signed(server, tmp_path, keys["priv"])
    man = json.loads((tmp_path / "srv/version.json").read_text())
    man["sha256"]["hex_menu.sh"] = hashlib.sha256(b"#!/bin/bash\necho MALICIOSO\n").hexdigest()     # atacante troca o hash...
    (tmp_path / "srv/version.json").write_text(json.dumps(man))
    server.put("hex_menu.sh", b"#!/bin/bash\necho MALICIOSO\n")                                    # ...e o arquivo
    res = installed.m.perform_update()
    assert not any(v["success"] for v in res.values())
    assert b"MALICIOSO" not in (tmp_path / "bin/hex_menu").read_bytes()


def test_ota_without_pinned_key_still_works_unsigned_and_override_works(installed, server, tmp_path, keys, monkeypatch):
    server.publish()
    assert all(v["success"] for v in installed.m.perform_update().values())
    shutil.copy(keys["pub"], tmp_path / "etc/release_pub.pem")
    assert not any(v["success"] for v in installed.m.perform_update().values())
    monkeypatch.setenv("HEX_ALLOW_UNSIGNED", "1")
    assert all(v["success"] for v in installed.m.perform_update().values())


# ───────────── ferramenta do dono: sign_release.sh / gen_version.sh ─────────────
@pytest.fixture
def repo_copy(tmp_path):
    dst = tmp_path / "repo"
    shutil.copytree(ROOT, dst, ignore=shutil.ignore_patterns(".git", "tests", "__pycache__", ".pytest_cache", "bhttp-server-*", "hcr-server-*", "dist", "keys", "version.json.sig"))
    return dst


def run_in(repo, *args, env=None):
    return subprocess.run(list(args), cwd=repo, capture_output=True, text=True, env={**os.environ, **(env or {})})


def test_sign_release_end_to_end(repo_copy, tmp_path):
    key = tmp_path / "keydir/release_key.pem"
    env = {"HEX_SIGNING_KEY": str(key)}
    assert run_in(repo_copy, "bash", "./sign_release.sh", "keygen", env=env).returncode == 0
    assert stat.S_IMODE(os.stat(key).st_mode) == 0o600 and (repo_copy / "keys/release_pub.pem").exists()
    assert run_in(repo_copy, "bash", "./sign_release.sh", "keygen", env=env).returncode != 0, "não pode sobrescrever a chave privada"
    assert run_in(repo_copy, "bash", "./sign_release.sh", "verify", env=env).returncode != 0, "pública publicada mas sem .sig deve falhar"
    assert run_in(repo_copy, "bash", "./sign_release.sh", "sign", env=env).returncode == 0
    assert run_in(repo_copy, "bash", "./sign_release.sh", "verify", env=env).returncode == 0
    fp = run_in(repo_copy, "bash", "./sign_release.sh", "fingerprint", env=env).stdout.strip()
    assert len(fp.split(":")) == 32
    (repo_copy / "version.json").write_text((repo_copy / "version.json").read_text() + " ")
    assert run_in(repo_copy, "bash", "./sign_release.sh", "verify", env=env).returncode != 0, "manifesto mudou depois de assinado"


def test_gen_version_signs_and_check_enforces_the_signature(repo_copy, tmp_path):
    key = tmp_path / "k/release_key.pem"; env = {"HEX_SIGNING_KEY": str(key)}
    run_in(repo_copy, "bash", "./sign_release.sh", "keygen", env=env)
    r = run_in(repo_copy, "bash", "./gen_version.sh", "9.9.9", "teste", env=env)
    assert r.returncode == 0 and (repo_copy / "version.json.sig").exists(), r.stderr
    (repo_copy / "CHANGELOG.md").write_text("# Changelog\n\n## [9.9.9] - x\n" + (repo_copy / "CHANGELOG.md").read_text())
    assert run_in(repo_copy, "bash", "./gen_version.sh", "--check", env=env).returncode == 0
    (repo_copy / "version.json.sig").unlink()
    r = run_in(repo_copy, "bash", "./gen_version.sh", "--check", env=env)
    assert r.returncode != 0, "com chave publicada, version.json sem assinatura não pode passar no CI"


def test_gen_version_adds_release_tag_when_binaries_live_only_in_dist(repo_copy):
    (repo_copy / "dist").mkdir()
    (repo_copy / "dist/bhttp-server-x-linux-amd64").write_bytes(b"bin1")
    (repo_copy / "dist/hcr-server-linux-amd64").write_bytes(b"bin2")
    assert run_in(repo_copy, "bash", "./gen_version.sh", "9.9.9", "t").returncode == 0
    man = json.loads((repo_copy / "version.json").read_text())
    assert man["release_tag"] == "v9.9.9"
    assert man["sha256"]["hcr-server-linux-amd64"] == hashlib.sha256(b"bin2").hexdigest()
    run_in(repo_copy, "bash", "./gen_version.sh", "9.9.9", "t", env={"HEX_RELEASE_TAG": "binarios-1"})
    assert json.loads((repo_copy / "version.json").read_text())["release_tag"] == "binarios-1"
    (repo_copy / "hcr-server-linux-amd64").write_bytes(b"bin2")          # binário no próprio repositório: sem release_tag
    (repo_copy / "bhttp-server-x-linux-amd64").write_bytes(b"bin1")
    run_in(repo_copy, "bash", "./gen_version.sh", "9.9.9", "t")
    assert "release_tag" not in json.loads((repo_copy / "version.json").read_text())
