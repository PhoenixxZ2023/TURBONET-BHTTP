#!/bin/bash
# Monta os scripts distribuídos (hex_menu.sh, install.sh, install_webpanel.sh) a partir de src/.
#
#   ./build.sh           gera os arquivos
#   ./build.sh --check   confere se os arquivos commitados estão em dia com src/ (o CI roda isto)
#
# Por quê: o menu tem ~1600 linhas e os dois instaladores repetiam funções. Em src/ ficam módulos
# pequenos e uma única cópia do código compartilhado; os arquivos que as VPS baixam continuam sendo
# UM script cada (o instalador roda por "curl | bash", sem o repositório em disco).
#
# Marcadores nos arquivos de src/:
#   #@include lib/arquivo.sh   → substituído pelo conteúdo de src/lib/arquivo.sh
#   #@embed hex_cleanup.sh     → substituído pelo conteúdo do arquivo da raiz (fonte única)
set -euo pipefail
cd "$(dirname "$0")"
python3 - "${1:-build}" <<'PY'
import os, re, stat, sys
mode = sys.argv[1]
read = lambda p: open(p, encoding="utf-8").read()

def expand(text):
    out = []
    for line in text.splitlines(keepends=True):
        m = re.match(r"^#@include (\S+)\s*$", line)
        if m:
            out.append(expand(read(os.path.join("src", m.group(1)))).rstrip("\n") + "\n"); continue
        m = re.match(r"^#@embed (\S+)\s*$", line)
        if m:
            out.append(read(m.group(1)).rstrip("\n") + "\n"); continue
        out.append(line)
    return "".join(out)

TARGETS = {
    "hex_menu.sh": lambda: "".join(read(f"src/hex_menu/{f}") for f in sorted(os.listdir("src/hex_menu")) if f.endswith(".sh")),
    "install.sh": lambda: read("src/install.sh.in"),
    "install_webpanel.sh": lambda: read("src/install_webpanel.sh.in"),
}
stale = []
for name, src in TARGETS.items():
    try:
        text = expand(src())
    except FileNotFoundError:
        continue
    if mode == "--check":
        if not os.path.exists(name) or read(name) != text:
            stale.append(name)
        continue
    open(name, "w", encoding="utf-8").write(text)
    os.chmod(name, os.stat(name).st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
    print(f"  montado: {name} ({text.count(chr(10))} linhas)")
if mode == "--check":
    if stale:
        print("DESATUALIZADOS (rode ./build.sh e faça commit):", ", ".join(stale)); sys.exit(1)
    print("scripts montados estão em dia com src/")
PY
