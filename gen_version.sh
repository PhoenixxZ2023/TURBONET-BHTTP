#!/bin/bash
# Gera o version.json com SHA256 de todos os arquivos distribuídos.
# Uso (na raiz do repositório, ANTES de cada commit/release):
#   ./gen_version.sh 1.1.0 "Resumo curto sem aspas"
set -euo pipefail
cd "$(dirname "$0")"
VERSION="${1:?uso: $0 <versão> [changelog]}"
CHANGELOG="${2:-Atualização}"
python3 - "$VERSION" "$CHANGELOG" <<'PY'
import datetime, glob, hashlib, json, os, sys
version, changelog = sys.argv[1], sys.argv[2].replace('"', "'")
files = ["app.py", "hex_menu.sh", "hex_cleanup.sh", "install.sh", "install_webpanel.sh",
         "templates/login.html", "templates/dashboard.html"]
files += sorted(glob.glob("bhttp-server-*")) + sorted(glob.glob("hcr-server-*"))
sha = {}
for f in files:
    if not os.path.isfile(f):
        sys.exit(f"arquivo ausente: {f}")
    sha[f] = hashlib.sha256(open(f, "rb").read()).hexdigest()
out = {"version": version, "release_date": datetime.date.today().isoformat(),
       "changelog": changelog,
       "components": {"menu": version, "templates": version, "backend": version},
       "sha256": sha}
with open("version.json", "w") as fh:
    json.dump(out, fh, indent=2)
    fh.write("\n")
print(f"version.json gerado: v{version}, {len(sha)} arquivos com SHA256")
PY
