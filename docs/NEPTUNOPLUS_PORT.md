# Port de Sega Saturn a neptUNO+ (QMTech EP4CGX150, RP2040 con mist-firmware-rp2040)

Este documento resume el análisis hecho para portar este core (fork MiSTer de
Sega Saturn) a la placa **neptUNO+** (FPGA Cyclone IV GX `EP4CGX150DF27I7` en
un módulo QMTech, controlada por un **RP2040** que corre
`mist-firmware-rp2040` de ZXMicroJack/microhack, con firmware compatible con
el protocolo MiST clásico), y el estado del scaffold creado en
`neptunoplus/`.

## Referencias usadas

- `delgrom/NeoGeo_FPGA` → `neptunoplus/` (mismo target, ya funciona con CD)
- `delgrom/TurboGrafx16_FPGA` → `neptUNOplus/` (mismo target, ya funciona con CD)
- `ZXMicroJack/mist-firmware-rp2040` (firmware del RP2040, protocolo MiST)
- `somhi/jtcores` → `modules/jtframe/target/{mist,demist}_neptuno2` (mismo target,
  usado como referencia de cómo un framework tipo-MiSTer se adapta a este board)
- `mist-devel/mist-modules` (framework MiST clásico: `user_io.v`, `data_io.v`,
  `mist_video.v`, `dac.vhd`, `i2s.v` - vendorizado aquí como submódulo de git
  en `mist-modules/`, fijado al mismo commit que usa el port de NeoGeo)

## Idea central del port

**neptUNO+ no es una placa MiSTer.** Habla el protocolo SPI clásico de MiST
(`SPI_SCK`/`SPI_DI`/`SPI_DO`/`SPI_SS2`/`SPI_SS3`/`SPI_SS4`/`CONF_DATA0`) y el
RP2040 hace de "ARM" de MiST (menú OSD, carga de ROM/BIOS, tarjeta SD, joysticks),
no de HPS/Linux como en MiSTer. Por tanto no se puede usar `sys/hps_io.sv` ni el
resto del framework MiSTer de este repo: hace falta una capa (`user_io`+`data_io`
del framework MiST) que hable ese protocolo.

La buena noticia, confirmada mirando NeoGeo/TGFX16/jtframe en este mismo board:
la parte "core" (CPUs, VDP1/VDP2, SCU, bloque CD, generación de RAMs) **no
cambia nada** entre el top MiSTer y el top MiST. Solo cambia la "cáscara"
alrededor: puertos físicos, el módulo que habla con el controlador (HPS vs
RP2040), los PLLs y la salida de vídeo/audio.

## Qué se generó en `neptunoplus/`

```
neptunoplus/
  Saturn_neptunoplus.qsf   - proyecto Quartus (pines, macros, lista de ficheros)
  Saturn_neptunoplus.qpf
  Saturn_neptunoplus.sdc   - constraints de tiempo (punto de partida)
  build_id.tcl             - genera build_id.v (fecha de build para el menú OSD)
  files_core.qip           - misma lista de RTL del core que usa el build MiSTer
                             (SH2, VDP1/VDP2, SCU, CD, sdram1/2, ps2, lightgun,
                             cofi...) sin tocar
  neptuno2_top.sv          - adaptador de pines físicos de la placa (calcado del
                             patrón de NeoGeo/TGFX16 en este mismo target)
  Saturn_MiST.sv           - el top "de verdad": mismo contenido que
                             Saturn.sv (MiSTer) pero con hps_io reemplazado
                             por user_io/data_io, PLL fijo en vez de
                             reconfigurable, y mist_video/dac/i2s en vez de
                             video_mixer/framebuffer
  pll_sys.v / pll_sys.qip  - PLACEHOLDER, ver más abajo, HAY QUE REGENERARLO
mist-modules/               - submódulo git de mist-devel/mist-modules,
                              fijado al commit que usa NeoGeo_FPGA en este board
```

`Saturn_MiST.sv` se construyó así: se extrajo tal cual (verbatim) todo el
bloque de `Saturn.sv` que va desde la lógica de reset hasta el final del
cableado del core/CD/VDP/backup-RAM (esa parte no sabe ni le importa si el
host es HPS o un RP2040), y se reescribió a mano solo: la lista de puertos,
el `CONF_STR`, la instancia de `user_io`/`data_io` (en vez de `hps_io`), el
PLL, y la salida de vídeo/audio (en vez de `video_mixer`/framebuffer HDMI).

## Decisión de alcance: Milestone 1 (elegido en esta sesión)

Se prioriza **arrancar BIOS + juegos de cartucho/RAM, sin CD**, antes de meter
el bloque CD. Motivo, aparte de reducir riesgo: se descubrió que el CD **no
se puede portar con un simple cambio de cáscara** (ver más abajo).

## Hallazgos importantes (y por qué importan)

### 1. El CD no usa el protocolo de bloques SD clásico - necesita una fase propia

`Saturn.sv` declara dos "discos" hacia `hps_io` (`VDNUM=2`): el slot 0
(`sd_lba0`/`sd_ack0`, pensado para la imagen de CD) y el slot 1 (`sd_lba`/
`sd_ack`, la Backup RAM). Se comprobó por grep que **`sd_lba0`/`sd_ack0`
nunca se leen ni escriben en ningún sitio del bloque de cableado del core**:
el CD en este repo se carga completo (o por streaming) a través del camino
`ioctl_download` con `ioctl_index` de grupo 2/3 (`cdd_download`/
`cdboot_download`), que es el mecanismo "bulk transfer" propio de
MiSTer/Linux, no el protocolo `sd_lba`/`img_mounted` de bloque tipo tarjeta-SD
que sí habla el `user_io.v` clásico de MiST (y que sí usan NeoGeo/TGFX16 para
su CD en este mismo target).

**Consecuencia:** portar el CD no es solo recablear la cáscara. Hace falta
o bien (a) reescribir el controlador de CD dentro de `rtl/Saturn/` para que
hable el protocolo `sd_lba`/`img_mounted` de bloques (el camino "de verdad"
que ya sabemos que funciona en neptUNO+, visto en NeoGeo/TGFX16), o bien (b)
añadir al firmware del RP2040 un mecanismo de streaming ioctl-like que hoy no
tiene. La opción (a) es la que siguen NeoGeo/TGFX16 y es la recomendada.
Es trabajo real de RTL, no scaffold - por eso quedó fuera de esta sesión.

La Backup RAM (slot 1, `sd_lba`/`sd_ack`) sí usa el protocolo de bloques
clásico y **sí se cableó de verdad** en `Saturn_MiST.sv`.

### 2. El PLL reconfigurable de MiSTer no existe en Cyclone IV GX

`Saturn.sv` (MiSTer) resintoniza `clk_sys` en caliente entre 4 frecuencias
exactas usando un IP de Altera de reconfiguración de PLL en runtime
(`altera_pll` + `altera_pll_reconfig`), para poder generar con precisión el
reloj maestro real de Saturn según PAL/NTSC y el bit `SMPC_DOTSEL` (resolución
normal vs alta):

| PAL | DOTSEL | clk_sys objetivo |
|---|---|---|
| No (NTSC) | 0 | 53.748200 MHz |
| No (NTSC) | 1 | 57.272800 MHz |
| Sí (PAL)  | 0 | 53.375000 MHz |
| Sí (PAL)  | 1 | 56.875000 MHz |

Cyclone IV GX no tiene ese mismo IP (tiene `ALTPLL_RECONFIG`, que reconfigura
por cadena de scan, mecanismo distinto y más limitado). Todos los ports a
neptUNO+ que se revisaron (NeoGeo, TGFX16, jtframe) usan un `altpll` fijo de
frecuencia única generado con el asistente de Quartus.

**Decisión tomada para el Milestone 1:** `clk_sys` fijo en 53.748200 MHz
(NTSC, resolución normal). PAL y alta resolución quedan para un milestone
posterior (necesitaría o 4 PLLs fijos + conmutación de reloj con
`altclkctrl` en los cambios de modo, o `ALTPLL_RECONFIG`).

**Acción pendiente para ti:** `neptunoplus/pll_sys.v` es un **placeholder
que no genera reloj de verdad** (a propósito: `locked` queda en 0 para que
sea imposible no darse cuenta de que falta este paso). Tienes que abrirlo en
Quartus (IP Catalog → PLL → ALTPLL) y generarlo con: entrada 50 MHz,
`c0`=53.748200 MHz, `c1`=misma frecuencia con la fase que use el `pll.v`
original de MiSTer para su `outclk_1` respecto a `outclk_0` (ábrelo para
copiar ese desfase). No se puede generar este IP sin Quartus - por eso no
venía ya resuelto.

### 3. `CONF_STR` había que reescribirlo a la sintaxis clásica de MiST

`Saturn.sv` usa la sintaxis moderna de MiSTer (`O[hi:lo]`, prefijos `D#` para
ocultar líneas de menú según otra opción, `status` de 128 bits). El firmware
clásico de MiST (y `mist-firmware-rp2040`, que es un fork de
`mist-firmware`) no entiende esa sintaxis: usa un único carácter base36
(`0`-`9`,`A`-`Z` = posiciones 0-35) por bit, y aquí `user_io.v` solo expone un
`status` de 64 bits.

Se reescribió `CONF_STR` en `Saturn_MiST.sv` a la sintaxis clásica,
**usando a propósito las mismas posiciones de bit** que ya lee el bloque de
cableado copiado tal cual (para no tener que tocar ese bloque). Todo lo que
caía en el bit 36 o más arriba (2º mando, configuración de lightgun, blend
compuesto, recorte vertical, aspect ratio) se dejó sin exponer en el menú por
ahora (queda en su valor por defecto = apagado); un pase posterior puede
moverlo a bits libres por debajo de 36 si se quiere recuperar.

### 4. Ancho del bus de Backup RAM: 16 bits (MiSTer) vs 8 bits (MiST clásico)

`Saturn.sv` usa `hps_io` en modo `WIDE(1)` (bus de 16 bits, dirección de
palabra de 8 bits) para el buffer de sector de la Backup RAM. El `user_io.v`
clásico expone ese mismo buffer de 512 bytes como 8 bits de dato con 9 bits
de dirección de byte. Se ajustó el único punto donde esto importa: la
instancia `dpram_dif` de `tmpram` en `Saturn_MiST.sv` (búscala por el
comentario "NOTE (neptUNO+ port)"), cambiando sus parámetros de
`#(8,16,8,16)` a `#(8,16,9,8)` (misma capacidad total, 512 bytes/4096 bits,
solo cambia cómo se parte por el lado B).

### 5. Memoria: SDRAM única (64MB placa + 64MB expansión) vs 128-160MB recomendados por MiSTer

El README original pide 128MB (SDRAM primaria) + 32-128MB (secundaria). El
propio core **ya trae un modo de SDRAM única** (`` `ifndef MISTER_DUAL_SDRAM ``,
parámetro `RAMH_SLOW=1`), pensado exactamente para boards MiST/SiDi de un solo
chip de 32MB - confirmado mirando el controlador `rtl/sdram1.sv` (bus de 13
bits de fila / 2 de banco / 16 de dato, el mismo ancho físico que usa
neptUNO+). Con los 64MB del chip de la QMTech ya se tiene más margen que el
caso base de 32MB para el que se diseñó ese modo; los 64MB adicionales por el
conector de expansión son el camino natural para, más adelante, recuperar el
modo `MISTER_DUAL_SDRAM` completo (con eso sí se llega a la config de 128MB
recomendada) - pero eso implica cablear `SDRAM2_*` en `neptuno2_top.sv` y
enrutar esos pines en el edge connector, trabajo de un milestone posterior,
no de esta sesión.

## Lo que NO se tocó (y no había que tocar)

Todo `rtl/Saturn/`, `rtl/SH/`, `rtl/ADSP_21xx/`, `rtl/FX68K/` y el resto de
periféricos (`hps2pad.sv`, `ps2mouse.sv`, `ps2keyboard.sv`, `lightgun.sv`,
`cofi.sv`, `sdram1.sv`, `ddram.sv`...) - se reusan sin modificar vía
`neptunoplus/files_core.qip`, que apunta a los mismos ficheros que ya usa
`files.qip` en la raíz del repo.

## Qué falta para tener esto arrancando en la placa

1. **Regenerar `pll_sys.v`** en Quartus (ver punto 2 arriba) - bloqueante,
   sin esto no hay reloj.
2. Abrir `neptunoplus/Saturn_neptunoplus.qpf` en Quartus, compilar. Es
   *esperable* que salgan errores la primera vez (nombres de puerto, algún
   ancho que se me haya escapado en el cableado a mano de `user_io`/
   `data_io`/`mist_video`/audio) - no había manera de compilar esto en esta
   sesión (no hay Quartus instalado aquí) para verificarlo de antemano.
   Pásame los errores y los vamos resolviendo.
3. Generar el `.rbf`/`.sof`, meterlo en la SD junto con un `.cue`+bios+
   cartucho de prueba, y probar con `mist-firmware-rp2040` (asegúrate de que
   el firmware del RP2040 en tu placa ya soporta el perfil `neptuno+` - el
   repo lo trae, revisa el `README`/instrucciones de compilación e
   instalación de firmware de ese repo si no lo tienes ya flasheado).
4. Iterar: seguramente el primer bring-up tenga problemas de timing SDRAM,
   polaridad de sync, orden de bits de joystick, etc. - normal en un primer
   intento de un core de esta complejidad.

## Próximos milestones (una vez arranque el Milestone 1)

- **M2**: recuperar PAL + alta resolución (resolver el problema del PLL
  reconfigurable, punto 2).
- **M3**: CD - portar el controlador de CD de `rtl/Saturn/` al protocolo de
  bloques `sd_lba`/`img_mounted` (punto 1), siguiendo el patrón de NeoGeo/
  TGFX16 en este mismo target.
- **M4**: pads avanzados (Mission Stick/3D Pad/Mouse/Teclado/Lightgun),
  mando 2, SDRAM2/expansión de 64MB para volver al modo dual-SDRAM completo.
