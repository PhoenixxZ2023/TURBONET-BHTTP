import json
import re
import subprocess

from conftest import ROOT


def test_version_json_matches_the_files():
    """Se este teste falha, TODA instalação falharia com 'SHA256 não confere': rode ./gen_version.sh <versão>."""
    r = subprocess.run(["bash", str(ROOT / "gen_version.sh"), "--check"], capture_output=True, text=True, cwd=ROOT)
    assert r.returncode == 0, r.stdout + r.stderr


def test_everything_the_installers_download_is_in_the_manifest():
    manifest = json.loads((ROOT / "version.json").read_text())["sha256"]
    needed = set()
    for script in ("install.sh", "install_webpanel.sh", "hex_menu.sh"):
        needed |= set(re.findall(r'baixar_verificado "([^"$]+)"', (ROOT / script).read_text(encoding="utf-8")))
        needed |= set(re.findall(r"hex_instalar_arquivo ([A-Za-z_./]+\.(?:sh|py|html))", (ROOT / script).read_text(encoding="utf-8")))
    missing = sorted(n for n in needed if n not in manifest)
    assert not missing, f"arquivos baixados mas sem SHA256 no version.json: {missing}"


def test_readme_badge_and_changelog_match_the_manifest_version():
    version = json.loads((ROOT / "version.json").read_text())["version"]
    assert f"badge/version-{version}-" in (ROOT / "README.md").read_text(encoding="utf-8")
    assert re.search(r"^## \[(\S+?)\]", (ROOT / "CHANGELOG.md").read_text(encoding="utf-8"), re.M).group(1) == version
