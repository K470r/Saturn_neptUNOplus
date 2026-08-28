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
sea imposible no darse cuenta de que falta este paso). Hay que regenerarlo en
Quartus (ALTPLL). Los valores exactos, sacados del propio `pll.v` de MiSTer
de este repo (`gui_reference_clock_frequency`/`gui_output_clock_frequency0`/
`gui_output_clock_frequency1`/`gui_phase_shift_deg1`):

- entrada (`inclk0`): 50 MHz
- `c0` (`clk_sys`): 53.748200 MHz, fase 0°
- `c1` (`clk_ram`, alimenta `SDRAM_CLK`): **107.496400 MHz (el doble exacto
  de c0)**, fase **-60°**

Ese `c1` = 2×c0 con -60° es tal cual el que usa `pll.v` para su `outclk_1`
(107.38635 MHz = 2×53.693175 MHz, -60°, antes de que el reconfig en caliente
cambie de frecuencia) - `sdram1.sv` necesita ese reloj al doble de frecuencia
para caber varias fases de acceso a SDRAM por cada ciclo de `clk_sys`. Ver el
mensaje de la sesión donde se guio la regeneración paso a paso en Quartus
para el detalle completo del asistente ALTPLL.

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

## `ddram.sv` (hallazgo grave, ya resuelto): necesitaba un puente SDRAM propio

Al compilar por primera vez en Quartus salió un bloque de errores en la
instancia `ddram ddram (.*, ...)` dentro del bloque de cableado copiado tal
cual de `Saturn.sv`: puertos `DDRAM_CLK/BUSY/BURSTCNT/ADDR/DOUT/DOUT_READY`
"no visibles en el scope". Investigando `rtl/ddram.sv` a fondo se confirmó
que **no es un alias interno para RAMH-vía-SDRAM** (como se asumió al
escribir el Milestone 1) sino **un controlador de DDR3 real**, con una
interfaz tipo Avalon-MM hacia hardware DDR3 físico. Por ahí pasa la mayoría
de la memoria de Saturn (RAMH, VRAM/framebuffer de VDP1, RAM/buffer de CD,
cartucho, BIOS, Backup RAM) **siempre**, sin importar `MISTER_DUAL_SDRAM` -
ese macro solo afecta a VDP2/SCSP, que van por `sdram1.sv`.

neptUNO+ no tiene DDR3 (ni el propio Cyclone IV GX trae el PHY de hardware
para eso). La memoria real que necesitan esos canales es pequeña (~15-20MB
frente a las ventanas de dirección mucho mayores que expone `ddram.sv`), así
que el problema no es de capacidad sino de que hace falta **un controlador
SDRAM nuevo detrás de esos mismos puertos Avalon**, sin tocar `ddram.sv`.

### Primer intento (descartado): dominio de reloj separado con CDC

En paralelo, otra sesión de Claude en la máquina del usuario avanzó un
puente Avalon→SDRAM (`avalon_sdram_bridge.sv` + `sdram2_ctrl.sv`, basado en
el controlador clásico de Sorgelig) para el chip de expansión, con un fix
real y bien encontrado: la salida `ready` de `sdram2_ctrl` sube varios
ciclos *antes* de que la FSM vuelva de verdad a `STATE_IDLE` (el único
estado donde atiende un comando nuevo) - si el puente solo esperaba
`ready`, el pulso de lectura/escritura siguiente de una ráfaga se perdía en
silencio. Se añadió una señal `idle` (alta solo en `STATE_IDLE` real) y el
puente espera `ready && idle` antes de mandar la siguiente sub-palabra -
esto resolvió una corrupción de BIOS real que se veía antes.

Pero esa sesión metió todo el puente + `sdram2_ctrl` en un dominio de reloj
`clk_ram2` **separado** de `clk_ram` (misma frecuencia, fase +150°, 3ª
salida de PLL), cruzando con un handshake `req`/`ack` de 2 flip-flops -
copiando (mal interpretado) el patrón de `NeoGeo_MiST.sv`. Con
instrumentación real en hardware (un `debug_uart` propio por `UART_TX`) se
encontró que el CPU sale del reset correctamente pero se cuelga
**permanentemente** en su primer acceso a memoria, dirección `0x000000`.

Analizando esto en esta sesión: ese cuelgue determinista (siempre el mismo
punto) es la firma clásica de un CDC roto - un `req`/`ack` de un solo ciclo
sin reintento se pierde por completo si un sincronizador de 2FF no lo ve a
tiempo, y como la relación de fase entre `clk_ram`/`clk_ram2` es fija, el
resultado es 100% reproducible. Y revisando `sdram2_ctrl.sv` de nuevo: su
`SDRAM_CLK` de salida ya lo genera internamente vía un registro de salida
DDR (`altddio_out`) - **no necesita que el reloj de entrada ya venga
desfasado**, esa técnica es la misma que usa este controlador (el clásico
de Sorgelig) en muchos otros cores sin depender nunca de un reloj especial.
No había ninguna razón real para el segundo dominio de reloj.

### Solución adoptada: todo en el mismo `clk_ram`, sin CDC

Se descartó `clk_ram2` por completo. `avalon_sdram_bridge` y `sdram2_ctrl`
corren sobre el mismo `clk_ram` que ya usa `ddram.sv` (y `sdram1.sv`) -
cero cruces de reloj, cero sincronizadores, cero forma de perder un pulso
por CDC. `sdram2_ctrl` resuelve la fase física de `SDRAM2_CLK` por su
cuenta vía `altddio_out`, igual que antes.

Reparto de chips confirmado con el usuario: **`sdram1.sv` (chip de a bordo)
se queda igual**, sirviendo VDP2 RAM A/B + SCSP RAM sin tocar. **El chip de
expansión (64MB, conector de borde)** sirve todo lo que pasa por
`ddram.sv` (RAMH, VDP1 VRAM/FB, CD RAM/buffer, cartucho, BIOS, Backup RAM)
a través del puente.

Estado: **integrado y en `files_core.qip`**. En `Saturn_MiST.sv`:
`ddram.sv` (sin tocar) sigue vinculando sus puertos `DDRAM_*` vía `.*`;
ahora hay wires `DDRAM_*` declarados que ese `.*` recoge automáticamente, y
`avalon_sdram_bridge`/`sdram2_ctrl` (renombrados `DDRAM_*`↔`av_*` en la
propia instancia) los respaldan, ambos sobre `clk_ram` y reiniciados con
`reset||rst_ram` (el puente, misma condición que usa `ddram.sv`) y
`rst_ram` solo (`sdram2_ctrl`, misma condición que usa `sdram1.sv` para su
`init` - un reset simple no debería forzar una re-inicialización completa
del chip físico, que tarda ~100us). Refresh: contador libre de 9 bits,
alterna cada 256 ciclos de `clk_ram` (~2.4us a 107.5MHz) - conservador
(más seguido de lo estrictamente necesario) pero no incorrecto. Pines
`SDRAM2_*` cableados de extremo a extremo (`neptuno2_top.sv` →
`Saturn_MiST.sv`), con el pinout de `NeoGeo_neptunoplus_dr.qsf`.

Primera compilación real en Quartus: hubo que arreglar señales
declaradas de menos (`RESET`, `*_download`, `OSD_STATUS`) y luego apareció
un hallazgo nuevo, más grande - ver la sección siguiente.

## Cyclone IV GX no tiene `altdpram`/MLAB (hallazgo grave, ya resuelto)

Tras resolver los primeros errores de compilación, Quartus falló al
elaborar `SH_regram` (el banco de registros de 16x32 bits de la CPU SH2)
con:

```
Error (287078): Assertion error: Can't convert dual-port RAM for Cyclone
IV GX device family using altsyncram megafunction because Cyclone IV GX
supports only synchronous dual-port RAM
Error (12152): Can't elaborate user hierarchy
"...SH_core:core|SH2_regfile:regfile|SH_regram:regramA|altdpram:altdpram_component"
```

Causa raíz: el core original usa `altdpram` en modo `MLAB` para todas
las memorias pequeñas con lectura asíncrona (dirección de lectura sin
registrar). Los bloques MLAB solo existen en familias más nuevas
(Cyclone V y posteriores); Cyclone IV GX solo tiene bloques M9K, que
requieren dirección de lectura registrada (síncrona). No hay forma de
pedirle a `altdpram`/MLAB que sintetice en Cyclone IV GX.

Esto resultó ser un patrón repetido en **todo el repo**, no un caso
aislado: 13 archivos usan `altdpram`/MLAB. Se hizo un barrido sistemático
de todo `rtl/` para reemplazar cada instancia por un simple array de
registros (`reg [...] mem[...]`), que sintetiza igual en cualquier
familia y preserva la semántica de lectura asíncrona (necesaria porque
varios llamadores, como `SH_regfile.sv`, leen el dato de forma
combinacional en el mismo ciclo).

Detalle importante encontrado en el camino, y sobre el que en un primer
momento me equivoqué: varios de estos módulos ya tenían una rama
`` `ifdef SIM ``/`` `else ``, donde la rama `SIM` era exactamente el
array de registros correcto y la rama `else` era el `altdpram` roto, con
el `` `define SIM `` envuelto en comentarios
`// synopsys translate_off` / `// synopsys translate_on`. Al principio
asumí que Quartus ignora esos comentarios (que son solo convención para
simuladores) y por lo tanto la macro quedaría activa también en síntesis
real, seleccionando sola la rama seguro - así que dejé esos módulos sin
tocar. **Esto era incorrecto**: la siguiente compilación falló
exactamente en uno de esos módulos "seguros" (`HMCS400_STACK`), lo que
demuestra que Quartus sí respeta `synopsys translate_off/on` y descarta
el `` `define SIM `` de adentro, así que la rama `else` (el `altdpram`
roto) era la que realmente se estaba sintetizando todo este tiempo. Se
corrigió eliminando por completo el `` `ifdef SIM ``/`` `else `` en esos
módulos y dejando solo el array de registros de forma incondicional
(válido tanto para simulación como para síntesis).

Módulos corregidos (lista completa, tras las dos rondas): `SH_regram`
(`rtl/SH_mem.sv`), `ddr_infifo` y `ddr_cache_ram` (`rtl/ddram.sv`),
`SCU_CBUS_CACHE` (`rtl/Saturn/SCU/RAM.sv`), `VDP2_WRITE_FIFO`
(`rtl/Saturn/VDP2/VDP2_mem.sv`), `SMPC_OREG_RAM`/`SMPC_SMEM`
(`rtl/Saturn/SMPC_HLE.sv`), `SCSP_KEY_RAM`/`SCSP_STACK_RAM`
(`rtl/Saturn/SCSP/SCSP.sv`), `VDP1_PAT_FIFO`/`VDP1_COL_TBL`
(`rtl/Saturn/VDP1/VDP1.sv`), `CACHE_TAG`/`CACHE_VALID`/`CACHE_LRU`
(`rtl/SH7604_mem.sv`), `mlab.vhd` (entidad VHDL genérica, sin uso real en
el diseño pero corregida igual por prudencia), `HMCS400_MR`/
`HMCS400_STACK` (`rtl/Saturn/SMPC/HMCS400_mem.sv` - `HMCS400_ROM` usa
`altsyncram` en modo `"ROM"`, que sí es compatible y no se tocó), y
`SMPC_ERAM`/`SMPC_IREG`/`SMPC_OREG` (`rtl/Saturn/SMPC/SMPC.sv`).

`ADSP_21xx_STACK` (`rtl/ADSP_21XX_mem.sv`) ya se había corregido
directamente en la primera ronda (sin depender del guard), así que no
hizo falta tocarlo de nuevo. `ADSP_21xx_MEM`, el otro módulo del mismo
archivo, usa `altsyncram` en modo `BIDIR_DUAL_PORT` en su rama `else`
(la que realmente se sintetiza) - ver el aparte más abajo sobre ese modo.

Confirmado como código muerto (no referenciado por ningún `.qip`, no se
tocó): `rtl/SH/core/SH_mem.sv` y `rtl/SH/SH7604/SH7604_mem.sv` - son
duplicados del mismo módulo con nombre de archivo idéntico pero en otra
carpeta; los archivos reales que compila el proyecto son los de nivel
raíz (`rtl/SH_mem.sv`, `rtl/SH7604_mem.sv`).

Nota aparte, sin resolver todavía: hay uso de `altsyncram` en modo
`"BIDIR_DUAL_PORT"` (verdadero dual-puerto, con escritura independiente
en ambos puertos) en `rtl/bram.vhd`, en `ADSP_21xx_MEM`
(`rtl/ADSP_21XX_mem.sv` - dado el hallazgo de arriba, ésta es la rama que
realmente se sintetiza, no una alternativa de respaldo) y, sin guard, en
`VDP2_PAL_RAM` (`rtl/Saturn/VDP2/VDP2_mem.sv`). A diferencia de
`altdpram`/MLAB, este es un caso distinto (`altsyncram`, con dirección
de lectura registrada/síncrona) que en principio Cyclone IV GX sí
soporta de forma nativa vía M9K - no se tocó especulativamente para no
arriesgar introducir un bug nuevo en una RAM de verdadera doble
escritura sin evidencia real del compilador de que haga falta. Si la
próxima compilación falla ahí, será la siguiente cosa a investigar.

## Rutas de `.mif` relativas a la raíz del repo (ya resuelto)

Tras corregir todo `altdpram`/MLAB, la siguiente compilación falló con:

```
Error (127001): Can't find Memory Initialization File or Hexadecimal
(Intel-Format) File rtl/Saturn/SMPC/smpc.mif for ROM instance ALTSYNCRAM
Error (12152): Can't elaborate user hierarchy
"...SMPC:SMPC|HMCS400_ROM:ROM|altsyncram:altsyncram_component|..."
```

Causa: `rtl/Saturn/Saturn.sv` (compartido con los proyectos MiSTer
originales en la raíz del repo - `Saturn.qpf`, etc.) instancia `SMPC` y
`SH1` con rutas de `.mif` escritas como literal `"rtl/..."`, relativas a
la raíz del repo, que es donde vive el `.qpf` original. Quartus resuelve
esas rutas relativas al directorio del proyecto - y el nuestro
(`neptunoplus/Saturn_neptunoplus.qpf`) vive un nivel más abajo, así que
buscaba en `neptunoplus/rtl/...` y no lo encontraba. Ambos módulos
(`SMPC` y `SH1`) se instancian sin condición en `Saturn.sv`, así que
Quartus necesita resolver su `.mif` sí o sí aunque el CD (que usa `SH1`)
esté fuera de alcance para el Milestone 1.

En vez de editar `rtl/Saturn/Saturn.sv` (lo que rompería el build
original de MiSTer, que sí necesita la ruta `"rtl/..."` tal cual), se
agregó en `neptunoplus/Saturn_neptunoplus.qsf`:

```
set_global_assignment -name SEARCH_PATH ".."
```

Esto le dice a Quartus que busque también en la raíz del repo, sin tocar
ningún archivo compartido. De paso también cubre el mismo patrón en
`neptunoplus/Saturn_MiST.sv` (`E93C45 #("rtl/stv_eeprom.mif")`, el
EEPROM de STV, también instanciado sin condición). Confirmado: la
siguiente compilación ya no reportó ningún error de `.mif`, así que
`SEARCH_PATH` resolvió el problema tal como se esperaba.

## `mist_video`: puerto `osd_enable` inexistente y `ce_divider` sin conectar

La compilación siguiente falló con:

```
Error (12002): Port "osd_enable" does not exist in macrofunction "mist_video"
```

La instancia de `mist_video` en `Saturn_MiST.sv` conectaba un puerto
`osd_enable` que no existe en la versión real de
`mist-modules/mist_video.v` (el submódulo vendorizado que realmente se
compila) - ese módulo maneja el overlay del OSD internamente a partir de
`SPI_SCK`/`SPI_SS3`/`SPI_DI`, sin necesitar una señal externa de enable.
Se quitó esa conexión (y el `wire osd_enable` que ya no se usaba en
ningún otro lado).

De paso se notó que a la instancia le faltaba conectar `ce_divider`
(entrada de 3 bits, obligatoria en este módulo, que le indica al
scandoubler interno la relación entre `clk_sys` y el reloj de píxel para
poder sincronizar su muestreo). Se conectó a `3'd3` (clk_sys/4), que es
el valor que el propio `scandoubler.v` documenta como su default "para
compatibilidad" cuando no se especifica nada. No se afinó contra la
relación real `DCLK`/`clk_sys` de este core (`DCLK` en VDP2.sv es
`DOT_CE_R | (DOT_CE_F & HRES[1])`, una señal de enable variable, no un
divisor fijo) - si en hardware real se ve desalineado el OSD o el
scandoubler, este valor es el primer lugar a revisar.

## `SDRAM_CLK` con dos manejadores (ya resuelto)

La compilación siguiente falló con:

```
Error (12014): Net "Saturn_MiST:saturn_mist|clk_ram", which fans out to
"Saturn_MiST:saturn_mist|sd2_ref_cnt[0]", cannot be assigned more than
one value
Error (12015): Net is fed by "...pll_sys:pll_sys|c1"
Error (12015): Net is fed by "...sdram1:sdram1|SDRAM_CLK"
```

Causa: en la sección de relojes de `Saturn_MiST.sv` había un
`assign SDRAM_CLK = clk_ram;` heredado de un borrador anterior, de
cuando `SDRAM_CLK` todavía no tenía un generador propio. Pero
`rtl/sdram1.sv` (el controlador de la SDRAM de a bordo) genera su propio
`SDRAM_CLK` internamente vía un registro de salida DDR (`altddio_out`,
alimentado por `clk_ram`) y lo entrega por su propio puerto de salida,
conectado en su instanciación (`.SDRAM_CLK(SDRAM_CLK)`) - así que
`SDRAM_CLK` terminaba con DOS manejadores: el `assign` directo y el
puerto de salida de `sdram1`. Quartus fusiona un `assign` simple
cable-a-cable en un único net físico, así que el conflicto apareció
reportado sobre `clk_ram` (con quien `SDRAM_CLK` había quedado
fusionado) en vez de sobre `SDRAM_CLK` directamente, lo cual lo hacía
confuso de leer en el log. Se quitó el `assign` sobrante; `SDRAM_CLK` ya
solo lo maneja `sdram1`.

## Primera compilación completa exitosa (Analysis & Synthesis → Fitter →
## Assembler → TimeQuest, 0 errores)

Con los tres fixes anteriores (barrido de `altdpram`/MLAB, `SEARCH_PATH`
para los `.mif`, `mist_video`) la compilación completa terminó sin
errores por primera vez, generando el `.sof`/`.pof`/`.rbf` de
programación. `VDP2_PAL_RAM` (`BIDIR_DUAL_PORT` con `altsyncram`) resultó
compatible con Cyclone IV GX tal como se esperaba - no hizo falta tocarlo.

Dos hallazgos del log de esta compilación, ambos en
`Saturn_neptunoplus.sdc` (ya corregidos):

- Las variables `sdram_clk`/`sys_clk` apuntaban al reloj del PLL sin el
  prefijo de jerarquía (`saturn_mist|...`), y lo mismo en el
  `set_clock_groups` de la línea 36 (referencia directa, sin variable).
  TimeQuest reportó explícitamente `Argument -clock is an empty
  collection` para cada `set_input_delay`/`set_output_delay` que usaba
  esas variables, y `could not be matched with a clock` para el
  `set_clock_groups` - es decir, **ninguna** de esas restricciones se
  estaba aplicando: ni la interfaz de la SDRAM (`SDRAM_DQ`, `SDRAM_A`,
  etc.), ni audio/VGA, ni la exclusión de `SPI_SCK` como dominio de reloj
  asíncrono frente al PLL. Se corrigió agregando `saturn_mist|` al
  nombre del reloj en los tres lugares.
- La falta de esa exclusión de `SPI_SCK` como asíncrono probablemente
  explica buena parte del slack negativo que el log reportó bajo el
  dominio `SPI_SCK` (`-4.714 ns` setup, `-5.628 ns` recovery) - TimeQuest
  estaba intentando analizar como síncronos caminos entre `SPI_SCK` y el
  PLL que son inherentemente asíncronos. Habrá que ver en la próxima
  compilación cuánto de eso desaparece.

## `sdram_clk` apuntaba al reloj equivocado del PLL (ya resuelto)

Con el fix anterior aplicado, la siguiente compilación reveló un segundo
bug relacionado, antes oculto porque `$sdram_clk` ni siquiera resolvía a
un reloj real: decenas de

```
Warning (332079): Reference pin SDRAM_CLK is invalid. It is not clocked
by the clock specified in set_input_delay/set_output_delay's -clock
option.
```

Causa: `sdram_clk` apuntaba a `clk[0]` (`clk_sys`), pero el pin físico
`SDRAM_CLK` lo genera `sdram1.sv` internamente a partir de `clk_ram`
(`clk[1]`), vía un `altddio_out`. El mecanismo `-reference_pin` exige que
el pin de referencia esté efectivamente en el dominio del reloj indicado
en `-clock` - no lo estaba. Se corrigió apuntando `sdram_clk` a `clk[1]`.
`sys_clk` (usado para `AUDIO_*`/`LED`/`VGA_*`, sin `-reference_pin`) se
dejó en `clk[0]`, correcto porque el core (`Saturn:saturn`) y
`mist_video` sí corren en `clk_sys`.

De paso se notó que la SDRAM2 (chip de expansión, mismo controlador
`sdram2_ctrl` basado en `sdram1.sv`, mismo dominio `clk_ram`) no tenía
ninguna restricción de timing en absoluto - ni siquiera del tipo roto
que se acaba de corregir. Se agregaron las mismas restricciones de
`SDRAM_DQ`/`SDRAM_A`/etc. mirrorizadas para `SDRAM2_*`.

### Pendiente

1. **Timing no cerrado todavía** (`Critical Warning (332148): Timing
   requirements not met`) - slack de setup peor caso de **-8.892 ns** en
   `clk[0]` (`clk_sys`, ~53.75MHz) y **-8.439 ns** en `clk[1]` (`clk_ram`),
   en el modelo más lento (1200mV/85°C). Esto es esperable en una primera
   compilación de un diseño de este tamaño sin ningún trabajo de
   optimización todavía, pero es un riesgo real: con timing no cerrado el
   diseño puede comportarse de forma errática en hardware real (datos
   corrompidos, cuelgues intermitentes) aunque el bitstream cargue sin
   problema. Antes de invertir tiempo depurando "bugs" en hardware real,
   conviene tener en cuenta que parte de lo que se vea podría ser
   simplemente timing no cumplido. Con la corrección del `.sdc` de arriba,
   la próxima compilación va a dar una lectura más real de cuánto slack
   negativo queda una vez que la SDRAM y `SPI_SCK` están correctamente
   constreñidos - hay que ver ese número antes de decidir si conviene
   perseguir el critical path o directamente probar en hardware primero.
2. Afinar `ce_divider` en la instancia de `mist_video` una vez haya
   imagen en pantalla real, si el scandoubler/OSD se ven desalineados.
3. `debug_uart` sigue sin traerse a este repo (vive en la otra máquina del
   usuario) - hace falta para depurar en hardware real cuando llegue el
   momento; dado que el cuelgue en `0x000000` era específico del diseño con
   CDC ya descartado, hay que confirmar desde cero si el problema
   desaparece con este diseño más simple.
