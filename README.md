# BIOS mod — Lenovo ThinkPad A275 (20KC / 20KD)

Análisis del BIOS oficial de Lenovo y guía para activar las opciones ocultas.

> ⚠️ **Modificar el BIOS puede dejar el equipo sin arrancar.** Antes de tocar nada, haz
> una copia completa del chip SPI con un programador externo y guárdala en más de un sitio.
> Todo lo que hagas aquí corre de tu cuenta.

## 1. Qué se analizó

| Dato | Valor |
|---|---|
| Paquete | `r0nuj17w.exe` (BIOS 1.24, `R0NET46W`, publicado el 2022-05-17), el último en el catálogo de Lenovo para 20KC |
| SHA-256 del `.exe` | `647af2edb21ffa5f4444f5f08ea02b68e3c8db0f50613812647b26dde91cf817` |
| Imagen | `$0AR0N00.FL1`, unos 17 MB (cápsula de flasheo) |
| Fabricante del BIOS | **Phoenix SecureCore Tiano** (no es AMI ni Insyde, así que AMIBCP y H2OEZE no sirven) |
| Plataforma | AMD Bristol Ridge / Stoney Ridge (AGESA + CPM) |

Para reproducirlo: `scripts/extract_bios.sh` descarga el paquete, comprueba su hash, lo
desempaqueta y saca los formularios IFR. Los IFR relevantes están ya en [`ifr/`](ifr/).

## 2. Hallazgos: menús ocultos

El Setup de Lenovo solo muestra Main/Config/Date/Security/Startup/Restart. Sin embargo, la
imagen contiene formularios completos de AMD que no están enlazados en ningún menú:

- **`PlatformHiiAMDDxe`** → formset "AMD" con submenús *Platform*, *FCH Options*, *GNB Options*
- **`AmdCpmOemHiiDxe`** → "AMD CPM Setup" (gráficos híbridos, ranuras M.2 y WWAN, CLKREQ…)
- **`PlatformHiiAdvancedDxe`** → "Advanced" → *Peripheral Configuration* (selección del TPM)

Los ajustes se guardan en variables UEFI (varstores). Si se cambia el byte correcto en la
variable, el ajuste se aplica aunque el menú siga oculto.

### Opciones con más interés

Varstores:

| Nombre | GUID | Tamaño |
|---|---|---|
| `AmdSetup` | `3A997502-647A-4C82-998E-52EF9486A247` | 0x44 |
| `AmdSetup2` | `B66E0339-2E6F-4281-9DCE-DE32AB19192C` | 0x66 |
| `AMD_CPM_SETUP` | `7C03B9B0-895B-4458-8BD2-A1F6AC1BB5E7` | 0x5C |

| Opción | Varstore | Offset | Tamaño | Valores (★ = por defecto) |
|---|---|---|---|---|
| **UMA Frame Buffer Size** (VRAM de la iGPU) | AmdSetup | `0x09` | **2 bytes** | 0=Auto, 32, 64, 128, 256, 384, 512★, 1024 (`0x400`), 2048 (`0x800`) en MB, little-endian |
| UMA Version | AmdSetup | `0x27` | 1 | 0=Legacy, 1=Non Legacy★ |
| AMD SVM (virtualización) | AmdSetup2 | `0x02` | 1 | 0=Enabled★, 1=Disabled |
| AMD SVM Lock | AmdSetup2 | `0x03` | 1 | 0=Enabled★, 1=Disabled |
| IOMMU | AmdSetup2 | `0x05` | 1 | 0=Disabled, 1=Enabled★ |
| ACPI P-state | AmdSetup | `0x04` | 1 | 0=Disabled, 1=Enabled★ |
| IMC Fan Control | AmdSetup | `0x26` | 1 | 0=Disabled★, 1=Enabled |
| PSPP Policy (gestión de energía PCIe) | AmdSetup | `0x0F` | 1 | 0=Disabled, 1=Performance, 2=Bal-High, 3=Bal-Low★, 4=Power Saving, 5=Auto |
| SATA D3 Cold | AmdSetup | `0x28` | 1 | 0=Disabled★, 1=Enabled |
| SD Mode | AmdSetup | `0x20` | 1 | 0=Disabled★, 1=v2.0, 2=v3.0, 3=SDR50, 4=SDR104, 5=DDR50 |
| AC Loss Control (encender al conectar corriente) | AmdSetup | `0x22` | 1 | 0=Always Off★, 1=Always On, 3=Previous |
| Light Sensor | AmdSetup | `0x03` | 1 | 0=Disabled★, 1=Enabled |
| M.2 Slot Lane control | AMD_CPM_SETUP | `0x18` | 1 | 0=2×x1, 1=1×x2★ |
| WWAN Power Enable | AMD_CPM_SETUP | `0x17` | 1 | ver `ifr/AmdCpmOemHiiDxe.txt` |
| Clock PM (CLKREQ#) | AMD_CPM_SETUP | `0x0A` | 1 | ver `ifr/AmdCpmOemHiiDxe.txt` |

La lista completa, con todas las opciones y sus valores, está en `ifr/PlatformHiiAMDDxe.txt`
y en `ifr/AmdCpmOemHiiDxe.txt`.

**No toques** el modo SATA, el SPI MODE/SPEED, "XHCI Controller 0", "Integrated Graphics"
ni el TPM (`Setup2` offset 0): con un valor erróneo puedes quedarte sin disco, sin teclado
USB o sin imagen.

> El valor "★ por defecto" es el que trae el IFR. El valor real de tu equipo puede ser
> otro: **lee siempre la variable antes de escribirla.**

## 3. Métodos, del más seguro al más arriesgado

### Método A: editar las variables sin flashear (recomendado para empezar)

No modifica la imagen del BIOS. Si algo sale mal, se suele arreglar con *Load Setup
Defaults* (F9 en el Setup) o quitando la pila CMOS.

1. En el Setup de Lenovo, desactiva **Secure Boot** (y, si tienes, la contraseña de supervisor).
2. Prepara un USB FAT32 con una de estas herramientas:
   - **GRUB con `setup_var`** (p. ej. el fork *grub-mod-setup_var* de datasone), que incluye
     `setup_var_cv` para varstores con nombre. Ejemplo para leer y luego poner 1 GB de VRAM
     (revisa la sintaxis exacta en el README de la versión que uses):
     ```
     setup_var_cv AmdSetup 0x9 0x2            # leer
     setup_var_cv AmdSetup 0x9 0x2 0x400      # escribir 1024 MB
     ```
   - **RU.efi**: abre `AmdSetup` en la lista de variables UEFI y edita el offset a mano.
3. Reinicia y comprueba el cambio (en Windows, *Configuración de pantalla → Propiedades del
   adaptador*; en Linux, `dmesg | grep -i "VRAM\|amdgpu"`).

**Si la escritura falla** (por ejemplo, `Write variable failed`), la variable está protegida
por SMM o por Lenovo y hay que pasar al método B.

> Sobre la VRAM: lo que se asigna a la iGPU se resta de la RAM del sistema. Con 4 GB no
> subas de 512 MB; 1 GB tiene sentido a partir de 8 GB y 2 GB a partir de 16 GB.

### Método B: programador SPI y edición de la NVRAM en el volcado

Material: un **CH341A** (mejor la versión con 1,8/3,3 V corregido) y una pinza **SOIC8**.
Software: `flashrom` o NeoProgrammer.

1. Desconecta la batería interna y el cargador. Mantén pulsado el botón de encendido para
   descargar el equipo.
2. Localiza el chip SPI de 16 MB de la placa (NM-B361), conecta la pinza y **lee el chip
   3 veces**. Las tres lecturas deben tener el mismo hash; si no, la pinza hace mal contacto.
3. Abre el volcado con UEFITool. Busca la variable `AmdSetup` en la región NVRAM y cambia
   solo los bytes de la tabla anterior (con un editor hexadecimal sobre el volcado, o con
   UEFITool 0.28 extrayendo y reemplazando el volumen NVRAM).
4. Graba el volcado modificado y verifícalo.

**Importante:** este BIOS incluye `SecureFlashAuthentication`, `LenovoVerifiedBootPei`,
`LenovoProtectPBPei` y un archivo *"Phoenix protected ranges hash file"*. Eso quiere decir
que:

- **WinFlash/ShellFlash rechazarán cualquier imagen modificada.** La cápsula va firmada, así
  que la única vía para grabar un mod es el programador SPI.
- Si modificas los **volúmenes de código** (DXE/PEI), el arranque verificado puede detectarlo
  y el equipo no arrancará. Limítate a la **NVRAM**, que no entra en esos hashes.

### Método C: hacer visibles los menús ocultos (no recomendado)

Habría que parchear el IFR de `LenovoSetup*` o de `SystemFormBrowserCoreDxe` para enlazar el
formset "AMD" (`4E45C392-32E2-4134-8FB0-06E7390F22F3`). Para eso hay que modificar volúmenes
protegidos por hash, así que el riesgo de dejar el equipo inservible es alto. Los métodos
A y B consiguen lo mismo sin ese riesgo.

## 4. Lo que **no** se puede desbloquear

- **Overclock o undervolt de la CPU:** el formset AMD no tiene P-states editables ni
  voltajes. Solo trae ACPI P-state on/off.
- **Cambiar la CPU o la iGPU:** van soldadas (BGA).
- **Whitelist de WLAN/WWAN: existe.** `LenovoWmaPolicyDxe` (junto con `LenovoWmaPciDxe` y
  `LenovoWmaUsbDxe`) muestra *"1802: Unauthorized network card is plugged in"*, y no hay
  ninguna opción de Setup para desactivarla. Quitarla obliga a parchear ese módulo DXE, es
  decir, un volumen de código, con el riesgo del método C. Lo práctico es usar tarjetas de la
  lista FRU de Lenovo para la A275. Algunas Intel AC 8265 y Realtek de ThinkPads de la misma
  época suelen estar en esa lista, pero compruébalo en el PSREF o la HMM antes de comprar.

## 5. Estructura del repo

```
README.md               esta guía
ifr/                    menús extraídos (IFR en texto) de los módulos de Setup
scripts/extract_bios.sh descarga el BIOS oficial y extrae todos los IFR
scripts/collect_pe.py   auxiliar: copia los módulos PE32 que saca UEFIExtract
```

El repo no incluye binarios de Lenovo; el script los descarga de `download.lenovo.com`.
