"""Fluxo dos instaladores: manifesto assinado (chave fixada na 1ª instalação) e binários via GitHub Releases."""
import hashlib
import json
import os
import shutil
import subprocess

import pytest

from conftest import ROOT
from test_signature import new_key, sign

pytestmark = pytest.mark.skipif(shutil.which("openssl") is None or shutil.which("curl") is None, reason="precisa de openssl e curl")


def run_installer(tmp, script, body, extra_env=None):
    code = f'HEX_SOURCE_ONLY=1 source "{ROOT}/{script}"; LOG_FILE="{tmp}/l.log"; GITHUB_RAW="file://{tmp}/repo"; HEX_PUBKEY="{tmp}/pinned.pem"; {body}'
    return subprocess.run(["bash", "-c", code], capture_output=True, text=True, env={**os.environ, **(extra_env or {})})


@pytest.fixture
def repo(tmp_path):
    (tmp_path / "repo/keys").mkdir(parents=True)
    return tmp_path


def publish(tmp, priv=None, pub=None, extra=None):
    man = json.dumps({"version": "1", "sha256": {}, **(extra or {})}).encode()
    (tmp / "repo/version.json").write_bytes(man)
    (tmp / "repo/version.json.sig").unlink(missing_ok=True)
    (tmp / "repo/keys/release_pub.pem").unlink(missing_ok=True)
    if priv: (tmp / "repo/version.json.sig").write_bytes(sign(priv, man, tmp))
    if pub: shutil.copy(pub, tmp / "repo/keys/release_pub.pem")


@pytest.mark.parametrize("script", ["install.sh", "install_webpanel.sh"])
def test_unsigned_release_without_key_continues_with_a_warning(repo, script):
    publish(repo)
    r = run_installer(repo, script, f'obter_manifesto "{repo}/m.json"; echo rc=$?')
    assert "rc=0" in r.stdout and "não está assinada" in r.stdout and not (repo / "pinned.pem").exists()


@pytest.mark.parametrize("script", ["install.sh", "install_webpanel.sh"])
def test_first_install_pins_the_published_key_and_shows_the_fingerprint(repo, script):
    priv, pub = new_key(repo, "k"); publish(repo, priv, pub)
    r = run_installer(repo, script, f'obter_manifesto "{repo}/m.json"; echo rc=$?')
    assert "rc=0" in r.stdout and (repo / "pinned.pem").read_bytes() == pub.read_bytes()
    assert "FIXADA" in r.stdout and "Impressão digital" in r.stdout


def test_published_key_with_invalid_signature_aborts_and_pins_nothing(repo):
    priv, pub = new_key(repo, "k"); other, _ = new_key(repo, "o")
    publish(repo, other, pub)                                           # assinado por uma chave diferente da publicada
    r = run_installer(repo, "install.sh", f'obter_manifesto "{repo}/m.json"; echo rc=$?')
    assert "rc=1" in r.stdout and not (repo / "pinned.pem").exists()


def test_pinned_key_refuses_unsigned_and_accepts_signed(repo):
    priv, pub = new_key(repo, "k"); shutil.copy(pub, repo / "pinned.pem")
    publish(repo)                                                       # sem assinatura
    r = run_installer(repo, "install.sh", f'obter_manifesto "{repo}/m.json"; echo rc=$?')
    assert "rc=1" in r.stdout and "RECUSADA" in r.stdout
    publish(repo, priv, pub)
    assert "rc=0" in run_installer(repo, "install.sh", f'obter_manifesto "{repo}/m.json"; echo rc=$?').stdout


def test_pinned_key_cannot_be_replaced_by_the_repository(repo):
    """Atacante com acesso ao repositório publica OUTRA chave e assina com ela: a chave fixada não troca."""
    good_priv, good_pub = new_key(repo, "good"); evil_priv, evil_pub = new_key(repo, "evil")
    shutil.copy(good_pub, repo / "pinned.pem")
    publish(repo, evil_priv, evil_pub)
    r = run_installer(repo, "install.sh", f'obter_manifesto "{repo}/m.json"; echo rc=$?')
    assert "rc=1" in r.stdout and (repo / "pinned.pem").read_bytes() == good_pub.read_bytes()


# ───────────── binários: GitHub Releases com fallback ─────────────
def setup_binary(tmp, name, content, release_tag="v1", in_release=True, in_repo=True, release_content=None):
    (tmp / "repo").mkdir(exist_ok=True)
    man = {"version": "1", "sha256": {name: hashlib.sha256(content).hexdigest()}}
    if release_tag: man["release_tag"] = release_tag
    (tmp / "m.json").write_text(json.dumps(man))
    if in_repo: (tmp / "repo" / name).write_bytes(content)
    if in_release and release_tag:
        (tmp / "rel" / release_tag).mkdir(parents=True, exist_ok=True)
        (tmp / "rel" / release_tag / name).write_bytes(release_content if release_content is not None else content)
    (tmp / "dest").mkdir(exist_ok=True)


def fetch_binary(tmp, name):
    r = run_installer(tmp, "install.sh", f'MANIFEST="{tmp}/m.json"; baixar_binario "{name}" "{tmp}/dest/bin" 755; echo rc=$?',
                      {"HEX_RELEASE_BASE": f"file://{tmp}/rel"})
    return r


def test_binary_comes_from_the_release_when_available(tmp_path):
    setup_binary(tmp_path, "hcr-x", b"BINARIO", in_repo=False)
    r = fetch_binary(tmp_path, "hcr-x")
    assert "rc=0" in r.stdout and (tmp_path / "dest/bin").read_bytes() == b"BINARIO" and os.access(tmp_path / "dest/bin", os.X_OK)


def test_binary_falls_back_to_the_repository_when_the_release_is_missing(tmp_path):
    setup_binary(tmp_path, "hcr-x", b"BINARIO", in_release=False)
    r = fetch_binary(tmp_path, "hcr-x")
    assert "rc=0" in r.stdout and "indisponível" in r.stdout and (tmp_path / "dest/bin").read_bytes() == b"BINARIO"


def test_tampered_release_binary_is_refused_and_the_verified_repo_copy_is_used(tmp_path):
    setup_binary(tmp_path, "hcr-x", b"BINARIO", release_content=b"ADULTERADO")
    r = fetch_binary(tmp_path, "hcr-x")
    assert "rc=0" in r.stdout and (tmp_path / "dest/bin").read_bytes() == b"BINARIO"
    assert "SHA256 não confere" in r.stdout


def test_binary_fails_when_neither_source_is_valid(tmp_path):
    setup_binary(tmp_path, "hcr-x", b"BINARIO", in_repo=False, release_content=b"ADULTERADO")
    r = fetch_binary(tmp_path, "hcr-x")
    assert "rc=1" in r.stdout or "rc=2" in r.stdout
    assert not (tmp_path / "dest/bin").exists()


def test_without_release_tag_only_the_repository_is_used(tmp_path):
    setup_binary(tmp_path, "hcr-x", b"BINARIO", release_tag=None)
    r = fetch_binary(tmp_path, "hcr-x")
    assert "rc=0" in r.stdout and "indisponível" not in r.stdout
