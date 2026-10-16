import re
import subprocess

from conftest import ROOT


def test_built_scripts_are_up_to_date_with_src():
    r = subprocess.run(["bash", str(ROOT / "build.sh"), "--check"], capture_output=True, text=True, cwd=ROOT)
    assert r.returncode == 0, r.stdout + r.stderr


def test_no_build_markers_leak_into_the_distributed_scripts():
    for name in ("hex_menu.sh", "install.sh", "install_webpanel.sh"):
        assert not re.search(r"^#@(include|embed)", (ROOT / name).read_text(encoding="utf-8"), re.M), name


def test_installers_share_a_single_copy_of_the_common_code():
    funcs = lambda name: re.findall(r"^([a-z_]+)\(\) \{", (ROOT / name).read_text(encoding="utf-8"), re.M)
    for name in ("install.sh", "install_webpanel.sh", "hex_menu.sh"):
        f = funcs(name)
        assert len(f) == len(set(f)), f"função definida duas vezes em {name}: {sorted({x for x in f if f.count(x) > 1})}"
    common = ["baixar_arquivo", "sha_esperado", "baixar_verificado", "apt_instalar", "hex_verificar_assinatura", "obter_manifesto"]
    lib = (ROOT / "src/lib/installer_common.sh").read_text(encoding="utf-8") + (ROOT / "src/lib/signature.sh").read_text(encoding="utf-8")
    for name in common:
        assert len(re.findall(rf"^{name}\(\) \{{", lib, re.M)) == 1, name
        for installer in ("src/install.sh.in", "src/install_webpanel.sh.in"):
            assert f"\n{name}() {{" not in (ROOT / installer).read_text(encoding="utf-8"), f"{name} duplicada em {installer}"


def test_embedded_cleanup_comes_from_the_single_source():
    menu = (ROOT / "hex_menu.sh").read_text(encoding="utf-8")
    cleanup = (ROOT / "hex_cleanup.sh").read_text(encoding="utf-8").rstrip("\n")
    assert cleanup in menu
