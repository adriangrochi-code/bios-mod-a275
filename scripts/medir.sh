#!/usr/bin/env bash
# Arnés de medición para la ThinkPad A275: corre una carga y muestrea potencia del
# paquete (fam15h_power), potencia de batería, temperatura, frecuencia, GPU, PSI,
# contadores de memoria y zswap. Guarda CSV + resumen JSON + entorno.
#
# Uso:
#   scripts/medir.sh [-e etiqueta] [-i seg] [-o dir] [-w unidades] -- comando [args...]
#   scripts/medir.sh [-e etiqueta] [-i seg] [-o dir] -d segundos      # solo reposo
#
#   -e etiqueta  nombre del experimento (p. ej. "schedutil-boost0"); agrupa repeticiones
#   -i seg       intervalo de muestreo (por defecto 1)
#   -o dir       raíz de resultados (por defecto ./resultados)
#   -w unidades  trabajo realizado por el comando (p. ej. ficheros compilados, fotogramas)
#                para calcular unidades por julio
#   -d seg       sin comando: muestrear el reposo durante esos segundos
#
# Salida: <dir>/<etiqueta>/<fecha>/{muestras.csv,resumen.json,env.txt,salida.log}
# Para leer zswap en debugfs hace falta root; sin root esas columnas salen NA.
set -euo pipefail

ETIQUETA="prueba"; INTERVALO=1; RAIZ="./resultados"; UNIDADES=""; DURACION=""
while getopts ":e:i:o:w:d:h" opt; do
  case "$opt" in
    e) ETIQUETA="$OPTARG" ;;
    i) INTERVALO="$OPTARG" ;;
    o) RAIZ="$OPTARG" ;;
    w) UNIDADES="$OPTARG" ;;
    d) DURACION="$OPTARG" ;;
    h) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "opción no válida: -$OPTARG" >&2; exit 2 ;;
  esac
done
shift $((OPTIND - 1))
[ "${1:-}" = "--" ] && shift
if [ $# -eq 0 ] && [ -z "$DURACION" ]; then
  echo "falta el comando (tras --) o -d segundos" >&2; exit 2
fi

DIR="$RAIZ/$ETIQUETA/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$DIR"
CSV="$DIR/muestras.csv"

# --- localizar sensores -----------------------------------------------------------
leer() { [ -r "$1" ] && tr -d '\n' < "$1" 2>/dev/null || printf 'NA'; }

PKG_FILE=""; TEMP_FILE=""
for h in /sys/class/hwmon/hwmon*; do
  [ -r "$h/name" ] || continue
  case "$(cat "$h/name")" in
    fam15h_power)
      if [ -r "$h/power1_average" ]; then PKG_FILE="$h/power1_average"
      elif [ -r "$h/power1_input" ]; then PKG_FILE="$h/power1_input"; fi ;;
    k10temp) [ -r "$h/temp1_input" ] && TEMP_FILE="$h/temp1_input" ;;
  esac
done
BAT_DIR=""
for b in /sys/class/power_supply/BAT*; do [ -d "$b" ] && BAT_DIR="$b" && break; done
GPU_BUSY=""
for g in /sys/class/drm/card*/device/gpu_busy_percent; do [ -r "$g" ] && GPU_BUSY="$g" && break; done
ZSWAP_DIR="/sys/kernel/debug/zswap"
FREQ_FILES=(/sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_cur_freq)
[ -r "${FREQ_FILES[0]}" ] || FREQ_FILES=()

pot_bateria_uw() {
  # µW. Si no hay power_now, current_now (µA) * voltage_now (µV) / 1e6
  [ -n "$BAT_DIR" ] || { printf 'NA'; return; }
  if [ -r "$BAT_DIR/power_now" ]; then leer "$BAT_DIR/power_now"; return; fi
  if [ -r "$BAT_DIR/current_now" ] && [ -r "$BAT_DIR/voltage_now" ]; then
    awk -v c="$(cat "$BAT_DIR/current_now")" -v v="$(cat "$BAT_DIR/voltage_now")" \
      'BEGIN{printf "%.0f", (c<0?-c:c)*v/1e6}'; return
  fi
  printf 'NA'
}
psi_total() { # $1 = memory|io|cpu, $2 = some|full
  [ -r "/proc/pressure/$1" ] || { printf 'NA'; return; }
  awk -v k="$2" '$1==k{for(i=2;i<=NF;i++) if($i ~ /^total=/){sub("total=","",$i); print $i; f=1}} END{if(!f) print "NA"}' "/proc/pressure/$1"
}
vmstat_val() { awk -v k="$1" '$1==k{print $2; f=1} END{if(!f) print "NA"}' /proc/vmstat; }
freq_media_mhz() {
  [ ${#FREQ_FILES[@]} -gt 0 ] || { printf 'NA'; return; }
  cat "${FREQ_FILES[@]}" 2>/dev/null | awk '{s+=$1;n++} END{if(n) printf "%.0f", s/n/1000; else print "NA"}'
}

# --- entorno ---------------------------------------------------------------------
{
  echo "fecha: $(date -Is)"
  echo "etiqueta: $ETIQUETA"
  echo "comando: ${*:-<reposo $DURACION s>}"
  echo "kernel: $(uname -r)"
  echo "cmdline: $(leer /proc/cmdline)"
  echo "cpu: $(awk -F: '/model name/{print $2; exit}' /proc/cpuinfo | sed 's/^ *//')"
  echo "governor: $(leer /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor)"
  echo "boost: $(leer /sys/devices/system/cpu/cpufreq/boost)"
  echo "cpuidle: $(leer /sys/devices/system/cpu/cpuidle/current_governor)"
  echo "preempt: $(leer /sys/kernel/debug/sched/preempt)"
  echo "sched_ext: $(leer /sys/kernel/sched_ext/state) $(leer /sys/kernel/sched_ext/root/ops)"
  echo "zswap: enabled=$(leer /sys/module/zswap/parameters/enabled) compressor=$(leer /sys/module/zswap/parameters/compressor) max_pool_percent=$(leer /sys/module/zswap/parameters/max_pool_percent) shrinker=$(leer /sys/module/zswap/parameters/shrinker_enabled)"
  echo "lru_gen: enabled=$(leer /sys/kernel/mm/lru_gen/enabled) min_ttl_ms=$(leer /sys/kernel/mm/lru_gen/min_ttl_ms)"
  echo "ksm: run=$(leer /sys/kernel/mm/ksm/run) pages_sharing=$(leer /sys/kernel/mm/ksm/pages_sharing)"
  echo "thp: $(leer /sys/kernel/mm/transparent_hugepage/enabled)"
  echo "swappiness: $(leer /proc/sys/vm/swappiness)"
  echo "ac_online: $(leer /sys/class/power_supply/AC/online)"
  echo "bateria: $([ -n "$BAT_DIR" ] && leer "$BAT_DIR/status" || echo NA)"
  echo "gpu_dpm: $(leer /sys/class/drm/card0/device/power_dpm_force_performance_level)"
  echo "sensor_pkg: ${PKG_FILE:-NA}"
  echo "sensor_temp: ${TEMP_FILE:-NA}"
  echo "memoria: $(awk '/MemTotal/{printf "%d MB", $2/1024}' /proc/meminfo)"
} > "$DIR/env.txt"

# --- muestreo en segundo plano ---------------------------------------------------
echo "t_s,pkg_w,bat_w,temp_c,freq_mhz,gpu_busy,psi_mem_some_us,psi_mem_full_us,psi_io_some_us,psi_cpu_some_us,pswpin,pswpout,pgmajfault,ws_refault_anon,ws_refault_file,zswap_stored,zswap_pool_bytes,zswap_reject_poor,zswap_wb" > "$CSV"
T0=$(date +%s.%N)
muestrear() {
  while :; do
    t=$(awk -v a="$(date +%s.%N)" -v b="$T0" 'BEGIN{printf "%.2f", a-b}')
    pkg=$([ -n "$PKG_FILE" ] && awk -v u="$(cat "$PKG_FILE")" 'BEGIN{printf "%.3f", u/1e6}' || printf 'NA')
    bat=$(pot_bateria_uw); [ "$bat" != NA ] && bat=$(awk -v u="$bat" 'BEGIN{printf "%.3f", u/1e6}')
    tmp=$([ -n "$TEMP_FILE" ] && awk -v m="$(cat "$TEMP_FILE")" 'BEGIN{printf "%.1f", m/1000}' || printf 'NA')
    printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
      "$t" "$pkg" "$bat" "$tmp" "$(freq_media_mhz)" "$([ -n "$GPU_BUSY" ] && leer "$GPU_BUSY" || printf 'NA')" \
      "$(psi_total memory some)" "$(psi_total memory full)" "$(psi_total io some)" "$(psi_total cpu some)" \
      "$(vmstat_val pswpin)" "$(vmstat_val pswpout)" "$(vmstat_val pgmajfault)" \
      "$(vmstat_val workingset_refault_anon)" "$(vmstat_val workingset_refault_file)" \
      "$(leer $ZSWAP_DIR/stored_pages)" "$(leer $ZSWAP_DIR/pool_total_size)" \
      "$(leer $ZSWAP_DIR/reject_compress_poor)" "$(leer $ZSWAP_DIR/written_back_pages)" >> "$CSV"
    sleep "$INTERVALO"
  done
}
muestrear &
MUESTREADOR=$!
trap 'kill $MUESTREADOR 2>/dev/null' EXIT

# --- la carga --------------------------------------------------------------------
ESTADO=0
if [ $# -gt 0 ]; then
  "$@" > "$DIR/salida.log" 2>&1 || ESTADO=$?
else
  sleep "$DURACION"
fi
T1=$(date +%s.%N)
kill $MUESTREADOR 2>/dev/null; wait $MUESTREADOR 2>/dev/null || true
trap - EXIT

# --- resumen ---------------------------------------------------------------------
DUR=$(awk -v a="$T1" -v b="$T0" 'BEGIN{printf "%.2f", a-b}')
awk -F, -v dur="$DUR" -v etiqueta="$ETIQUETA" -v unidades="${UNIDADES:-}" -v estado="$ESTADO" -v dir="$DIR" '
function num(x){ return (x != "NA" && x != "") }
function j(k,v){ printf "%s  \"%s\": %s", (first?"":",\n"), k, v; first=0 }
function js(k,v){ j(k, "\"" v "\"") }
NR==1 { next }
{
  n++
  if (num($2)) { spkg+=$2; npkg++ ; if($2>maxpkg) maxpkg=$2 }
  if (num($3)) { sbat+=$3; nbat++ }
  if (num($4) && $4>maxt) maxt=$4
  if (num($5)) { sfreq+=$5; nfreq++ }
  if (num($6)) { sgpu+=$6; ngpu++ }
  if (n==1) { for(i=7;i<=19;i++) ini[i]=$i }
  for(i=7;i<=19;i++) fin[i]=$i
}
function delta(i){ return (num(ini[i]) && num(fin[i])) ? fin[i]-ini[i] : "null" }
function pct(i,  d){ d=delta(i); return d=="null" ? "null" : sprintf("%.3f", d/(dur*1e4)) }
END {
  first=1
  printf "{\n"
  js("etiqueta", etiqueta); js("dir", dir)
  j("duracion_s", dur); j("muestras", n+0); j("estado_salida", estado)
  j("pkg_w_media", npkg? sprintf("%.3f", spkg/npkg) : "null")
  j("pkg_w_max",   npkg? sprintf("%.3f", maxpkg) : "null")
  j("pkg_J",       npkg? sprintf("%.1f", spkg/npkg*dur) : "null")
  j("bat_w_media", nbat? sprintf("%.3f", sbat/nbat) : "null")
  j("bat_J",       nbat? sprintf("%.1f", sbat/nbat*dur) : "null")
  j("temp_c_max",  maxt? sprintf("%.1f", maxt) : "null")
  j("freq_mhz_media", nfreq? sprintf("%.0f", sfreq/nfreq) : "null")
  j("gpu_busy_media", ngpu? sprintf("%.1f", sgpu/ngpu) : "null")
  j("psi_mem_some_pct", pct(7)); j("psi_mem_full_pct", pct(8))
  j("psi_io_some_pct", pct(9));  j("psi_cpu_some_pct", pct(10))
  j("pswpin", delta(11)); j("pswpout", delta(12)); j("pgmajfault", delta(13))
  j("ws_refault_anon", delta(14)); j("ws_refault_file", delta(15))
  j("zswap_wb", delta(19)); j("zswap_reject_poor", delta(18))
  j("zswap_ratio_final", (num(fin[16]) && num(fin[17]) && fin[17]>0) ? sprintf("%.2f", fin[16]*4096/fin[17]) : "null")
  if (unidades != "") {
    j("unidades", unidades)
    j("unidades_por_J_pkg", npkg? sprintf("%.4f", unidades/(spkg/npkg*dur)) : "null")
    j("unidades_por_J_bat", nbat? sprintf("%.4f", unidades/(sbat/nbat*dur)) : "null")
  }
  printf "\n}\n"
}' "$CSV" > "$DIR/resumen.json"

echo "== $ETIQUETA  ($DIR)"
python3 - "$DIR/resumen.json" <<'PY' 2>/dev/null || cat "$DIR/resumen.json"
import json, sys
r = json.load(open(sys.argv[1]))
def f(k, u=""):
    v = r.get(k); return "NA" if v is None else f"{v}{u}"
print(f"  duración {f('duracion_s',' s')}  muestras {f('muestras')}  salida {f('estado_salida')}")
print(f"  paquete  {f('pkg_w_media',' W')} media, {f('pkg_w_max',' W')} máx, {f('pkg_J',' J')}")
print(f"  batería  {f('bat_w_media',' W')} media, {f('bat_J',' J')}")
print(f"  temp máx {f('temp_c_max',' °C')}  freq media {f('freq_mhz_media',' MHz')}  gpu {f('gpu_busy_media',' %')}")
print(f"  PSI some: mem {f('psi_mem_some_pct',' %')} io {f('psi_io_some_pct',' %')} cpu {f('psi_cpu_some_pct',' %')}   mem full {f('psi_mem_full_pct',' %')}")
print(f"  refaults anon {f('ws_refault_anon')} file {f('ws_refault_file')}  majfault {f('pgmajfault')}  swap in/out {f('pswpin')}/{f('pswpout')}")
print(f"  zswap ratio {f('zswap_ratio_final')}  writeback {f('zswap_wb')}  rechazos {f('zswap_reject_poor')}")
if "unidades" in r:
    print(f"  trabajo: {f('unidades')} unidades → {f('unidades_por_J_pkg')} u/J (paquete), {f('unidades_por_J_bat')} u/J (batería)")
PY
exit "$ESTADO"
