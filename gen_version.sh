#!/bin/bash
# Gera (ou confere) o version.json com SHA256 de todos os arquivos distribuídos.
#
#   ./gen_version.sh 1.2.0 "Resumo curto sem aspas"   gera o version.json
#   HEX_SIGNING_KEY=~/.hex-release/release_key.pem ./gen_version.sh 1.2.0 "Resumo"   gera E assina (version.json.sig)
#   ./gen_version.sh --check                          confere se o version.json bate com os arquivos
#                                                     (o CI roda isto: sem isso, um commit esquecido
#                                                     faria TODA instalação falhar com "SHA256 não confere")
set -euo pipefail
cd "$(dirname "$0")"
MODE="gen"; if [ "${1:-}" = "--check" ]; then MODE="check"; fi
VERSION="${1:-}"; CHANGELOG="${2:-Atualização}"
if [ "$MODE" = "gen" ] && [ -z "$VERSION" ]; then echo "uso: $0 <versão> [changelog]  |  $0 --check" >&2; exit 2; fi
python3 - "$MODE" "$VERSION" "$CHANGELOG" <<'PY'
import datetime, glob, hashlib, json, os, re, sys
mode, version, changelog = sys.argv[1], sys.argv[2], sys.argv[3].replace('"', "'")
files = ["app.py", "hex_menu.sh", "hex_cleanup.sh", "hex_panel_mode.sh", "hex_ip.sh", "install.sh", "install_webpanel.sh",
         "templates/login.html", "templates/dashboard.html"]
# binários: ficam no repositório OU em dist/ (cópias locais dos arquivos enviados ao GitHub Releases)
files += sorted(f for f in glob.glob("static/**", recursive=True) if os.path.isfile(f))
assets = sorted(set(glob.glob("bhttp-server-*") + glob.glob("hcr-server-*") + glob.glob("dist/bhttp-server-*") + glob.glob("dist/hcr-server-*")))
sha = {}
for f in files:
    if not os.path.isfile(f):
        sys.exit(f"arquivo ausente: {f}")
    sha[f] = hashlib.sha256(open(f, "rb").read()).hexdigest()
for f in assets:
    sha[os.path.basename(f)] = hashlib.sha256(open(f, "rb").read()).hexdigest()
if mode == "gen":
    out = {"version": version, "release_date": datetime.date.today().isoformat(), "changelog": changelog,
           "components": {"menu": version, "templates": version, "backend": version}, "sha256": sha}
    # binários só em dist/ (fora do git) => os instaladores baixam do GitHub Releases dessa tag
    if assets and not any(os.path.isfile(os.path.basename(a)) for a in assets):
        out["release_tag"] = os.environ.get("HEX_RELEASE_TAG") or f"v{version}"
    with open("version.json", "w") as fh:
        json.dump(out, fh, indent=2); fh.write("\n")
    print(f"version.json gerado: v{version}, {len(sha)} arquivos com SHA256")
    sys.exit(0)
# --check
cur = json.load(open("version.json"))
bad = []
for f, h in cur["sha256"].items():
    path = f if os.path.isfile(f) else (f"dist/{f}" if os.path.isfile(f"dist/{f}") else None)
    if path is None:
        if f.startswith(("bhttp-server-", "hcr-server-")):
            print(f"  (aviso) binário {f} não está no repositório; confiando no hash do manifesto"); continue
        bad.append(f"{f}: arquivo do manifesto não existe"); continue
    if hashlib.sha256(open(path, "rb").read()).hexdigest() != h:
        bad.append(f"{f}: SHA256 diferente do version.json (rode ./gen_version.sh <versão>)")
for f in files:
    if f not in cur["sha256"]:
        bad.append(f"{f}: não está no version.json")
cl = re.search(r"^## \[([0-9][^\]]*)\]", open("CHANGELOG.md", encoding="utf-8").read(), re.M)
if cl and cl.group(1) != cur["version"]:
    bad.append(f"CHANGELOG.md está na {cl.group(1)}, mas o version.json diz {cur['version']}")
if bad:
    print("version.json NÃO confere:"); [print("  -", b) for b in bad]; sys.exit(1)
print(f"version.json confere (v{cur['version']}, {len(cur['sha256'])} arquivos)")
PY
if [ "$MODE" = "gen" ]; then
    KEY="${HEX_SIGNING_KEY:-$HOME/.hex-release/release_key.pem}"
    if [ -s "$KEY" ] && [ -s keys/release_pub.pem ]; then HEX_SIGNING_KEY="$KEY" bash ./sign_release.sh sign
    else echo "AVISO: version.json NÃO foi assinado (sem chave). Veja: bash sign_release.sh keygen" >&2; fi
else
    # com chave pública publicada, o version.json commitado precisa estar assinado (e a assinatura em dia)
    [ -s keys/release_pub.pem ] && bash ./sign_release.sh verify
fi
exit 0
