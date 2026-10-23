# Plan: distro para la ThinkPad A275 con el máximo rendimiento por vatio

Documento de trabajo. Recoge el objetivo, lo que el hardware permite, las palancas
disponibles, lo que ya trae Linux y lo que habría que construir. Al final hay un backlog
de ideas con ganancia esperada, coste y forma de medirlas, para decidir qué se añade.

Regla única del proyecto: **nada entra si no se ha medido**. La métrica es trabajo por
julio (rendimiento por vatio) junto con la latencia p99. Una mejora que sube el
rendimiento pero gasta más de lo que aporta se descarta.

---

## 1. Hardware y límites

| Componente | Dato | Consecuencia |
|---|---|---|
| CPU | AMD PRO A10-9700B / A12-9800B, Bristol Ridge, familia 15h modelos 65h/70h, núcleos Excavator, 2 módulos / 4 hilos, 15 W | Sin CPPC: no hay `amd_pstate`. Se usa `acpi-cpufreq`. |
| ISA | SSE4.2, AVX2, FMA3, BMI1/2, MOVBE, F16C | Cumple **x86-64-v3**. Se puede compilar userland para v3 o `-march=bdver4`. |
| Medición de potencia | `X86_FEATURE_ACC_POWER` (potencia acumulada en MSR) | Hay lectura de vatios del paquete con `fam15h_power` y `perf` (`power/power-pkg/`). **No hay RAPL** ni `ryzenadj`. |
| iGPU | Radeon R7, GCN 3 (GFX8, asic "Carrizo"), 6 u 8 CU, 758–900 MHz | `amdgpu` + Mesa `radeonsi` (OpenGL 4.6) y `RADV` (Vulkan 1.3). Memoria compartida con la RAM. |
| Vídeo | UVD 6.0: decodifica H.264 y HEVC 8 bits. VCE 3.1: codifica H.264. | **No decodifica VP9 ni AV1.** Eso se hace por software y cuesta vatios. |
| RAM | DDR4-2133 | El ancho de banda limita a la iGPU. Doble canal si el equipo lo permite. |
| Almacenamiento | M.2 2280 por PCIe x2 (ver `AMD_CPM_SETUP` 0x18 en el README) o SATA | Un NVMe cambia lo que compensa comprimir o precargar. |
| BIOS | Phoenix, sin P-states ni voltajes editables | El undervolt solo es posible desde el kernel vía MSR. |
| Sensores | `k10temp`, batería ACPI (`power_now`), `thinkpad_acpi` | Potencia total del equipo desde la batería; potencia del paquete desde el CPU. |

Lo que **no** existe y conviene no buscar: RAPL, `amd_pstate`, `ryzenadj`, Vulkan con
ray tracing o mesh shaders útiles, ROCm (abandonó GFX8).

---

## 2. Métricas y herramientas de medición

| Qué | Cómo | Notas |
|---|---|---|
| Potencia del paquete (CPU + iGPU) | hwmon `fam15h_power` → `power1_input`, `power1_average`, `power1_cap` (TDP) | Es la métrica central. `perf stat -e power/power-pkg/` da lo mismo por intervalo. |
| Potencia total del equipo | `/sys/class/power_supply/BAT0/power_now` con la batería descargando | Incluye panel, SSD, WiFi. Un medidor USB-C PD en el cargador es la referencia externa. |
| Temperatura | `k10temp` | La temperatura sube las fugas; un chip más frío gasta algo menos. |
| Frecuencia real | `cpufreq/scaling_cur_freq`, `perf stat -e cycles,instructions` | IPC = instrucciones / ciclos: dice si los ciclos se aprovechan. |
| Ciclos perdidos en memoria o E/S | PSI: `/proc/pressure/{memory,io,cpu}` | `some` = alguna tarea parada; `full` = todas. Es la medida directa de "pérdida de ciclos". |
| Thrashing | `/proc/vmstat`: `workingset_refault_anon`, `workingset_refault_file`, `pgmajfault`, `pswpin`, `pswpout` | Si suben al reducir RAM, el controlador se ha pasado. |
| Compresión | `/sys/kernel/debug/zswap/*`: `stored_pages`, `pool_total_size`, `reject_compress_poor`, `written_back_pages` | Ratio real = stored_pages × 4096 / pool_total_size. |
| Latencia de planificación | `cyclictest` (rt-tests), `schbench`, `hackbench` | p99 y máximo, no la media. |
| Dónde se pierde el tiempo | BPF: `runqlat`, `offcputime`, `biolatency`; `perf sched`, `perf top` | Para encontrar causas, no para comparar configs. |
| Estados de reposo | `cpupower idle-info`, `/sys/devices/system/cpu/cpu*/cpuidle/state*/{time,usage,above,below}` | `above`/`below` dicen si el governor predice mal. |
| Despertares | `powertop`, `perf stat -e sched:sched_wakeup` | Cada despertar innecesario cuesta vatios en reposo. |
| GPU | `/sys/class/drm/card*/device/pp_dpm_sclk`, `gpu_busy_percent`, `mem_busy_percent` | Y el consumo del paquete, que la incluye. |

El script `scripts/medir.sh` muestrea casi todo esto mientras corre una carga y guarda un
CSV más un resumen con julios, potencia media, PSI y refaults. `scripts/comparar.py`
pone varias ejecuciones en una tabla.

### Protocolo experimental

1. Condiciones fijas: mismo brillo, misma red, batería o corriente (no mezclar), sin
   actualizaciones de fondo, mismo estado térmico de partida (esperar a temperatura
   base entre ejecuciones).
2. Una sola variable por experimento.
3. Orden A/B/B/A y al menos tres repeticiones por lado. Se compara la **mediana**.
4. Se mide trabajo por julio y p99. Si uno mejora y otro empeora, se decide por el caso
   de uso, y se anota.
5. Toda ejecución guarda el `env.txt` con kernel, cmdline, governor y parámetros para
   que sea reproducible.

---

## 3. Kernel: construir con todos los interruptores

No hace falta inventar un kernel modular: Linux ya deja conmutar en caliente lo que
importa. El trabajo es compilarlo con todas las opciones y automatizar la conmutación.
El fragmento de configuración está en `kernel/a275-eficiencia.config`.

### 3.1 Cómo construirlo

```sh
# Sobre un kernel estable reciente (6.12 o posterior, por sched_ext y DAMOS goals)
make localmodconfig                      # solo los módulos que usa esta máquina
scripts/kconfig/merge_config.sh .config /ruta/kernel/a275-eficiencia.config
make -j4 bindeb-pkg                      # o 'make -j4' y 'make modules_install install'
```

Opcional, para optimizar el código al Excavator: el parche *more-uarches* de graysky
añade `CONFIG_MEXCAVATOR`. Sin parche, `KCFLAGS="-march=bdver4"`. La ganancia es de
pocos puntos; se mide, no se asume.

### 3.2 Palancas que se conmutan sin recompilar

| Palanca | Dónde | Valores a comparar |
|---|---|---|
| Governor de frecuencia | `cpufreq/scaling_governor` | `schedutil` vs `ondemand` (+ módulo `amd_freq_sensitivity`, específico de Fam 15h) vs `conservative` |
| Turbo (CPB) | `/sys/devices/system/cpu/cpufreq/boost` | 1 vs 0. En 15 W, apagarlo suele subir el rendimiento por vatio. |
| Reacción de schedutil | `cpufreq/schedutil/rate_limit_us` | 500 … 10000 |
| Governor de reposo | `/sys/devices/system/cpu/cpuidle/current_governor` | `teo` vs `menu` |
| Modelo de preempción | parámetro `preempt=none|voluntary|full` (PREEMPT_DYNAMIC) | latencia p99 vs rendimiento |
| Planificador | `sched_ext`: `scx_lavd`, `scx_bpfland`, `scx_rusty`, o EEVDF de serie | se cargan y descargan en caliente |
| Frecuencia de tick | compilar `HZ=250` y `HZ=1000` | dos kernels, mismo resto |
| Mitigaciones | parámetro `mitigations=off` | Excavator paga retpolines. Solo para medir cuánto; decidir con criterio de seguridad. |
| ASPM PCIe | `pcie_aspm.policy=powersupersave` | reposo del SSD y WiFi |
| SATA | `CONFIG_SATA_MOBILE_LPM_POLICY=3` (med_power_with_dipm) | si el disco es SATA |
| Planificador de E/S | `queue/scheduler` | `none`/`mq-deadline` en NVMe, `bfq` en SATA |
| Pantalla | `amdgpu.dc=1` vs `amdgpu.dc=0`, `amdgpu.dcfeaturemask` | consumo en reposo con pantalla encendida |
| GPU DPM | `power_dpm_force_performance_level` | `auto` vs `low` en escritorio |

### 3.3 Undervolt por P-state (la palanca grande)

Los P-states de la familia 15h viven en los MSR `0xC0010064`–`0xC001006B` (campos
CpuFid, CpuDid, CpuVid). `amdctl` los lee y escribe. Procedimiento:

1. Cargar `msr`, leer la tabla: `amdctl -g`.
2. Bajar el VID un paso en el P-state más alto, correr `stress-ng --cpu 4 --matrix 4`
   diez minutos, medir julios con `medir.sh`. Repetir hasta inestabilidad y volver dos
   pasos atrás.
3. Repetir por cada P-state. Los bajos aguantan menos recorte.
4. Aplicarlo en un servicio de systemd solo tras una semana sin cuelgues.

Riesgos: cuelgues y corrupción si se exagera; y cabe que Lenovo tenga bloqueada la
escritura del MSR (entonces `amdctl` falla y esta vía se cierra).

### 3.4 Variables del BIOS que ayudan (ver README)

PSPP a *Power Saving* o *Bal-Low*, *WWAN Power* apagado si no hay módem, *Clock PM*
(CLKREQ#) activo, *SATA D3 Cold* activo si el disco es SATA, *UMA Frame Buffer* según el
experimento de la sección 6.4.

---

## 4. Memoria: jerarquía RAM / RAM comprimida / SSD con control medido

### 4.1 Lo que ya trae el kernel

- **zswap**: páginas anónimas frías comprimidas en RAM (`zsmalloc`); las que comprimen
  mal pasan directas al swap del SSD; el *shrinker* (6.8+) baja al SSD las comprimidas
  que llevan tiempo frías. Compresor, tamaño de pool y umbrales se cambian en caliente.
- **zram con recompresión** (`ZRAM_MULTI_COMP`, 6.2+): alternativa a zswap. Comprime
  primero con `lz4` y recomprime las páginas inactivas con `zstd`. Es "compresión
  inteligente" de serie. Se elige zswap **o** zram, no ambos; el experimento decide.
- **MGLRU** (`lru_gen`): envejecimiento por generaciones. `min_ttl_ms` corta el thrashing
  antes de que se pierdan ciclos sin fin.
- **DAMON / DAMOS** (6.8+ con *goals*): monitoriza accesos y aplica esquemas, por
  ejemplo "manda a comprimir lo que lleve N segundos sin tocarse, hasta mantener la PSI
  de memoria por debajo de X". Es el lazo adaptativo dentro del kernel.
- **KSM**: deduplica páginas iguales entre procesos. Desde 6.4 se activa por proceso
  (`prctl(PR_SET_MEMORY_MERGE)`); el *smart scan* reduce su coste.
- **Reclamo proactivo por cgroup**: `memory.reclaim` encoge una aplicación hasta su
  conjunto de trabajo real.
- **PSI** por cgroup: la señal de parada de cualquier política.
- **Compresión en el sistema de archivos**: btrfs o f2fs con `zstd:1` o `lzo` reducen
  bytes leídos del SSD para páginas de fichero (zswap no las toca).

### 4.2 Lo que hay que construir: el controlador

Un demonio en espacio de usuario que cierre el lazo. Primero en userspace, porque se
itera rápido y no cuelga la máquina; solo se toca el kernel si falta un mando.

Entradas: PSI memoria/E/S, refaults, fallos mayores, ratio y rechazos de zswap, potencia
del paquete, AC o batería.

Salidas: compresor de zswap (`lz4` en batería o con CPU saturada; `zstd` si la ratio
manda y hay margen), `max_pool_percent`, `swappiness`, cuota y umbrales DAMOS,
`min_ttl_ms`, `memory.high`/`memory.reclaim` por cgroup, KSM on/off por proceso.

Política inicial (estilo senpai): por cada cgroup de aplicación, reclamar poco a poco
hasta que aparezca una PSI `some` mínima (p. ej. 0,1 %/s); retroceder un 10 % y
mantener. Si suben los refaults, soltar. Resultado: cada app ocupa lo que usa, no lo que
reservó.

Candidato a parche de kernel, solo si los datos lo piden: elegir compresor por página
según contenido (zswap usa uno por pool).

### 4.3 Prever páginas: precarga por aplicación

Grabador y reproductor de conjunto de trabajo (al estilo SuperFetch): al arrancar una
aplicación se graban durante unos segundos los rangos de fichero que toca (`mincore`,
`/proc/pid/pagemap` o DAMON en modo registro); en el siguiente arranque se lanzan
`readahead(2)` / `MADV_WILLNEED` de esos rangos. Gana en arranque de aplicaciones
grandes y al volver de suspensión. Con NVMe son decenas de milisegundos; con SATA,
mucho más. Va al final del plan porque cuesta más de lo que rinde en SSD rápido. Nunca
precargar "por adivinación general": llena la RAM de páginas inútiles.

### 4.4 Perfil de partida

`etc/sysctl.d/90-a275-memoria.conf` y `etc/tmpfiles.d/90-a275-memoria.conf` fijan un
punto de partida razonable (zswap + lz4 + pool 25 %, MGLRU con `min_ttl_ms`, KSM en
marcha, `page-cluster=0`). Es el **estado A** de los experimentos, no la conclusión.

---

## 5. CPU: aprovechar ciclos y prever lo que hace falta

- **Reposo**: `teo` predice la duración del reposo y elige C-state. Comprobar con
  `cpuidle/state*/above` y `below` si acierta. Un C-state demasiado profundo pierde
  microsegundos en cada despertar; uno ligero gasta vatios.
- **Frecuencia**: `schedutil` con `rate_limit_us` ajustado; `uclamp` para que las
  tareas interactivas suban antes sin arrastrar al resto. Comparar con `ondemand` +
  `amd_freq_sensitivity`, que usa el MSR de sensibilidad a frecuencia de Fam 15h para
  no subir reloj cuando la tarea está limitada por memoria (justo el caso de este chip).
- **Planificación**: `sched_ext` con `scx_lavd` (estima criticidad de latencia) o
  `scx_bpfland` (prioriza interactivas). Medir p99 y julios frente a EEVDF.
- **Despertares**: PipeWire con `default.clock.quantum` más alto en batería, `timer
  slack` mayor para procesos de fondo, `powertop --auto-tune` como línea base.
- **IPC**: con `perf stat -e cycles,instructions,cache-misses` por carga se ve si la
  pérdida está en memoria (IPC bajo) o en planificación (PSI cpu). Un IPC bajo con
  reloj alto es el peor caso de vatios por trabajo: ahí `amd_freq_sensitivity` o un
  límite de frecuencia ganan.
- **Memoria física**: doble canal y DDR4-2133 real son más importantes para la iGPU que
  cualquier ajuste de software. Comprobar con `dmidecode -t memory`.

---

## 6. Gráficos y APIs modernas sin perder rendimiento

Objetivo: usar la ruta más directa a la GPU y al decodificador de vídeo, y evitar capas
de traducción que cuestan ciclos en un chip de 15 W.

### 6.1 Pila recomendada

| Capa | Elección | Por qué |
|---|---|---|
| Kernel | `amdgpu` con DC | Ruta moderna, soporta Carrizo. Comparar `dc=0` solo por consumo. |
| OpenGL | Mesa `radeonsi` | Nativo para GCN 3; normalmente más rápido y frugal que Zink en GFX8. |
| Vulkan | Mesa `RADV` (compilador ACO) | Vulkan 1.3 en GFX8. Es lo que usan DXVK, juegos nativos y compositores modernos. |
| Zink (OpenGL sobre Vulkan) | Solo si una app concreta va mejor, medido | En GFX8 suele perder frente a radeonsi. |
| Vídeo | VA-API vía Mesa (`vainfo`): H.264 y HEVC por hardware | Es la mayor ganancia de vatios del uso diario. |
| Pantalla | Wayland (KDE, GNOME, sway/Hyprland) con *direct scanout* | Evita una copia por fotograma. Escalado entero, no fraccional. |
| Audio | PipeWire | Cuanto mayor el quantum en batería, menos despertares. |

### 6.2 Vídeo: la regla que más vatios mueve

UVD 6 decodifica H.264 y HEVC. **Si el navegador recibe VP9 o AV1, decodifica por
software y el consumo se dispara.** Medidas:

- Firefox en Wayland: `media.ffmpeg.vaapi.enabled=true`, `media.av1.enabled=false`;
  preferir H.264 en sitios de vídeo (extensiones tipo *enhanced-h264ify*).
- Chromium: `--ozone-platform=wayland --enable-features=VaapiVideoDecodeLinuxGL` y
  desactivar AV1/VP9 por política o extensión.
- `mpv`: `hwdec=vaapi`, `vo=gpu-next` o `vo=dmabuf-wayland`.
- Verificar con `radeontop` o `gpu_busy_percent` que el decodificador trabaja y, sobre
  todo, con `medir.sh` reproduciendo el mismo clip con y sin hardware.

### 6.3 Vulkan: dónde aporta y dónde no

- **Aporta** en juegos vía DXVK (DX9/10/11 → Vulkan) y en aplicaciones que ya usan
  Vulkan (emuladores, algunos editores). Menos sobrecarga de driver que OpenGL.
- **No aporta** reescribir nada que ya corra bien en radeonsi. Zink añade una capa.
- `vkd3d-proton` (DX12) en GFX8 está limitado por funciones ausentes; no contar con él.
- Vulkan Video en RADV: comprobar con `vulkaninfo` si expone decodificación en este
  UVD; si no, VA-API sigue siendo la ruta.
- Para juegos: renderizar a menor resolución con FSR 1 (gamescope o la opción del
  juego) baja los vatios más que cualquier ajuste de driver.

### 6.4 Memoria de la iGPU

Con `amdgpu` la GPU usa RAM del sistema por GTT además del *UMA Frame Buffer* del BIOS.
Experimento: UMA 512 MB (de serie) frente a 128 MB con GTT grande. Un UMA pequeño
devuelve RAM al sistema (encaja con "reducir RAM innecesaria"); algunos juegos y apps
Vulkan asumen memoria local y pierden. Se mide con las cargas reales del usuario.

### 6.5 Errores que hacen perder rendimiento al modernizar

- Aplicaciones cayendo en XWayland con escalado fraccional (una copia y un reescalado
  por fotograma).
- Compositor sin *direct scanout* o con efectos que fuerzan composición continua.
- VP9/AV1 por software (ver 6.2).
- Zink por defecto.
- GPU forzada a `low` para uso interactivo: la latencia sube y el trabajo tarda más,
  así que a veces gasta más julios en total. Medir, no suponer.

---

## 7. Userland y distro

- **Base**: Arch o Debian para iterar. **CachyOS** es una opción práctica: repos
  compilados para x86-64-v3 (válidos en Excavator) y kernels con `sched_ext` de serie,
  útiles como referencia contra el kernel propio. Gentoo solo si se quiere todo con
  `-march=bdver4` y LTO/PGO, aceptando el coste de compilar en un chip de 15 W.
- **Qué compensa recompilar**: poco. Mesa, ffmpeg, zstd, lz4 ya despachan en tiempo de
  ejecución según la CPU. El resto gana pocos puntos. Priorizar política sobre flags.
- **Empaquetado final** (fase 4): `archiso` o `debootstrap` con el kernel propio, el
  demonio controlador, los perfiles (batería / corriente / rendimiento), `sysctl`,
  `tmpfiles`, reglas udev y la configuración de navegador y PipeWire. Buildroot solo si
  se busca algo mínimo sin gestor de paquetes.

---

## 8. Hoja de ruta

| Fase | Entregable | Criterio de salida |
|---|---|---|
| 1 | Kernel propio con el fragmento de config + arnés de medición funcionando | `medir.sh` da julios y PSI estables en tres repeticiones de la misma carga |
| 2 | Barrido de palancas de CPU y kernel (gobernadores, boost, idle, preempt, HZ, ASPM) | Tabla con mediana de J/trabajo y p99 por palanca |
| 3 | Memoria: zswap vs zram, MGLRU, DAMON, KSM; demonio con reclamo proactivo | Menos RAM usada con refaults y PSI sin subir |
| 4 | Undervolt por MSR | Una semana estable con el nuevo VID |
| 5 | Gráficos y vídeo: VA-API, Wayland, Vulkan donde toque, UMA vs GTT | Vatios de vídeo y escritorio medidos antes y después |
| 6 | Precarga por aplicación | Tiempo de arranque de apps grandes con y sin perfil |
| 7 | Distro: imagen instalable con todo lo anterior y perfiles | Instalación limpia reproduce las medidas |

---

## 9. Backlog de ideas: qué añadir y a qué coste

Ganancia y coste son estimaciones a priori para priorizar; la medición las sustituye.

| Idea | Ganancia esperada | Coste en consumo o CPU | Riesgo | Cómo se mide | Fase |
|---|---|---|---|---|---|
| Decodificación de vídeo por hardware (H.264/HEVC) y bloquear VP9/AV1 | Alta: varios vatios en reproducción | Ninguno | Bajo | `medir.sh` con un clip fijo | 5 |
| Undervolt por P-state (MSR) | Alta: menos vatios a igual reloj | Ninguno | Medio: cuelgues, posible MSR bloqueado | julios en `stress-ng` 10 min | 4 |
| Turbo apagado o limitado en batería | Media-alta en perf/W; pierde pico | Ninguno | Bajo | J/trabajo en compilación | 2 |
| Variables BIOS: PSPP, WWAN, CLKREQ, SATA D3 | Media en reposo | Ninguno | Bajo (método A del README) | `power_now` en reposo | 2 |
| `teo` vs `menu` | Baja-media en reposo y latencia | Ninguno | Bajo | p99 + vatios en reposo | 2 |
| `schedutil` vs `ondemand`+`amd_freq_sensitivity` | Media en cargas limitadas por memoria | Ninguno | Bajo | IPC y J/trabajo | 2 |
| `sched_ext` (lavd / bpfland) | Media en latencia interactiva | Bajo (BPF) | Bajo: se descarga en caliente | p99 bajo carga de fondo | 2 |
| Reclamo proactivo por cgroup (senpai) | Media: RAM libre real sin thrashing | Bajo si la PSI manda | Medio: mal ajustado provoca refaults | RSS/PSS vs refaults | 3 |
| zswap lz4 vs zstd, pool 20–40 % | Depende de la RAM instalada | Medio: comprimir cuesta ciclos | Bajo | J/trabajo con poca RAM libre | 3 |
| zram con recompresión en lugar de zswap | Similar; mejor ratio en frío | Medio | Bajo | mismo experimento | 3 |
| DAMON_RECLAIM con goal de PSI | Media si hay presión; nula si sobra RAM | Bajo (muestreo) | Bajo | PSI y refaults | 3 |
| KSM por proceso (navegador, Electron) | Media en RAM; nula en CPU | Bajo con smart scan | Bajo | `pages_sharing`, vatios en reposo | 3 |
| `min_ttl_ms` en MGLRU | Evita thrashing largo | Ninguno | Medio: puede matar procesos | PSI full | 3 |
| Compresión en el FS (btrfs/f2fs zstd:1) | Baja-media en lecturas; menos escritura | Bajo-medio | Bajo | tiempo y julios de arranque de apps | 3 |
| UMA 128 MB + GTT frente a 512 MB | RAM libre; puede costar en juegos | Ninguno | Bajo | juegos y escritorio con `medir.sh` | 5 |
| Wayland con direct scanout, sin escalado fraccional | Media en escritorio | Ninguno | Bajo | vatios en reposo con pantalla | 5 |
| PipeWire quantum alto en batería | Baja en reposo | Ninguno | Bajo: latencia de audio | despertares/s | 2 |
| Precarga por aplicación | Baja con NVMe, media con SATA | Bajo-medio: lecturas anticipadas | Medio: RAM mal usada si falla | tiempo de arranque, refaults | 6 |
| Kernel con `-march=bdver4` / MEXCAVATOR | Baja | Ninguno | Bajo | J/trabajo en kernel build | 2 |
| Userland x86-64-v3 (CachyOS) | Baja | Ninguno | Bajo | mismo | 7 |
| `mitigations=off` | Media en syscalls | Ninguno | Alto en seguridad | solo para conocer el coste | 2 |
| `HZ=250` vs `HZ=1000` | Baja | Ninguno | Bajo | p99 y vatios en reposo | 2 |
| `preempt=` none/voluntary/full | Baja; intercambia latencia por rendimiento | Ninguno | Bajo | p99 vs J/trabajo | 2 |
| Zink como OpenGL por defecto | Probablemente negativa en GFX8 | Medio | Bajo | fps/W en una app OpenGL | 5 |
| Parche: compresor por página según contenido | Desconocida | Medio | Alto (código de kernel) | solo si zswap muestra muchos `reject_compress_poor` | después de 3 |

---

## 10. Decisiones pendientes

- Confirmar modelo exacto de CPU, RAM instalada (canales) y tipo de M.2: cambian la
  prioridad entre compresión y precarga.
- Elegir base (Arch/CachyOS o Debian) para la fase 1.
- Decidir si el controlador se escribe en Python (rápido de iterar) o Rust/C (menos
  consumo propio). Para la fase 3, Python; se reescribe si su coste aparece en las
  medidas.
