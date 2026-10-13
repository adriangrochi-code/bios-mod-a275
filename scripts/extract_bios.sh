#!/usr/bin/env bash
# Descarga el BIOS oficial de la ThinkPad A275 (R0NUJ17W / R0NET46W v1.24),
# lo desempaqueta y extrae los formularios IFR (menús de Setup) de cada módulo.
#
# Requisitos: curl, innoextract, 7z, python3
#   sudo apt install innoextract p7zip-full
#
# Uso: scripts/extract_bios.sh [directorio_de_trabajo]
set -euo pipefail

WORK="${1:-./work}"
HERE="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$WORK"/{dl,ex,tools,pe}
cd "$WORK"

EXE_URL="https://download.lenovo.com/pccbbs/mobiles/r0nuj17w.exe"
EXE_SHA="647af2edb21ffa5f4444f5f08ea02b68e3c8db0f50613812647b26dde91cf817"

[ -f dl/r0nuj17w.exe ] || curl -fsSL -o dl/r0nuj17w.exe "$EXE_URL"
echo "$EXE_SHA  dl/r0nuj17w.exe" | sha256sum -c -

innoextract -s -d ex dl/r0nuj17w.exe
FL1="$(find ex -name '*.FL1' | head -1)"
cp "$FL1" bios.fl1

if [ ! -x tools/uefiextract ]; then
  curl -fsSL -o tools/ue.zip https://github.com/LongSoft/UEFITool/releases/download/A68/UEFIExtract_NE_A68_x64_linux.zip
  curl -fsSL -o tools/ifr.zip https://github.com/LongSoft/IFRExtractor-RS/releases/download/v1.6.0/ifrextractor_1.6.0_linux.zip
  (cd tools && 7z x -y ue.zip >/dev/null && 7z x -y ifr.zip >/dev/null)
fi

rm -rf bios.fl1.dump
tools/uefiextract bios.fl1 all >/dev/null
python3 -I "$HERE/collect_pe.py" bios.fl1.dump pe

(cd pe && for f in *.efi; do ../tools/ifrextractor "$f" >/dev/null 2>&1 || true; done)
echo "Formularios IFR extraídos:"
ls -S pe/*.ifr.txt
