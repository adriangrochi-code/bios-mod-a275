"""Copia el cuerpo PE32 de cada módulo extraído por UEFIExtract a <out>/<Nombre>.efi."""
import os
import shutil
import sys


def module_name(path, root):
    """Busca hacia arriba el info.txt que lleva el nombre (línea 'Text: ...')."""
    while path.startswith(root):
        info = os.path.join(path, "info.txt")
        if os.path.exists(info):
            for line in open(info, errors="ignore"):
                if line.startswith("Text: "):
                    return line[6:].strip()
        path = os.path.dirname(path)
    return None


def main(root, out):
    os.makedirs(out, exist_ok=True)
    for dirpath, _, files in os.walk(root):
        if "info.txt" not in files or "body.bin" not in files:
            continue
        info = open(os.path.join(dirpath, "info.txt"), errors="ignore").read()
        if "Subtype: PE32 image" not in info:
            continue
        name = module_name(dirpath, root)
        if name:
            shutil.copy(os.path.join(dirpath, "body.bin"), os.path.join(out, name + ".efi"))


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
