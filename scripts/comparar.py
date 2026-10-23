#!/usr/bin/env python3
"""Compara ejecuciones de scripts/medir.sh.

Uso:
  scripts/comparar.py [raiz_resultados] [-m metrica ...]

Agrupa por etiqueta (directorio de primer nivel bajo la raíz), y muestra por cada
métrica la mediana y el número de repeticiones. Solo usa la biblioteca estándar.
"""
import argparse
import json
import pathlib
import statistics
import sys

METRICAS = [
    "duracion_s", "pkg_w_media", "pkg_J", "bat_w_media", "bat_J", "temp_c_max",
    "freq_mhz_media", "psi_mem_some_pct", "psi_io_some_pct", "psi_cpu_some_pct",
    "ws_refault_anon", "ws_refault_file", "pgmajfault", "unidades_por_J_pkg",
    "unidades_por_J_bat",
]


def cargar(raiz):
    grupos = {}
    for resumen in sorted(pathlib.Path(raiz).glob("*/*/resumen.json")):
        try:
            datos = json.load(open(resumen))
        except (OSError, ValueError) as exc:
            print(f"aviso: no se pudo leer {resumen}: {exc}", file=sys.stderr)
            continue
        grupos.setdefault(datos.get("etiqueta", resumen.parent.parent.name), []).append(datos)
    return grupos


def mediana(valores):
    nums = [float(v) for v in valores if v is not None]
    return statistics.median(nums) if nums else None


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("raiz", nargs="?", default="./resultados")
    ap.add_argument("-m", "--metrica", action="append", help="métrica a mostrar (repetible)")
    args = ap.parse_args()

    grupos = cargar(args.raiz)
    if not grupos:
        sys.exit(f"no hay resúmenes bajo {args.raiz}")
    metricas = args.metrica or [m for m in METRICAS if any(d.get(m) is not None for g in grupos.values() for d in g)]

    ancho = max(len(e) for e in grupos) + 2
    print(f"{'etiqueta':<{ancho}}{'n':>3}  " + "  ".join(f"{m:>18}" for m in metricas))
    for etiqueta, ejecuciones in grupos.items():
        fila = [f"{etiqueta:<{ancho}}{len(ejecuciones):>3}  "]
        for m in metricas:
            med = mediana(d.get(m) for d in ejecuciones)
            fila.append(f"{'NA' if med is None else f'{med:.4g}':>18}")
        print("  ".join(fila))
    print("\nmediana por etiqueta; compara J (menos es mejor) y unidades/J (más es mejor).")


if __name__ == "__main__":
    main()
