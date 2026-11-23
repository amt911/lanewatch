# lanewatch

Vigilante para un NVMe que **desaparece del bus PCIe** en Linux. Mientras el disco
funciona, registra los errores del enlace PCIe a medida que ocurren. Si el disco se cae,
consigue que el log del kernel de ese momento **sobreviva al reinicio** guardándolo en la
NVRAM EFI con pstore.

## El problema

Cuando el disco que cae es el del sistema, el journal muere con él: tras reiniciar, el
log del arranque anterior acaba de golpe, sin ningún error. Los mensajes del driver
`nvme` que explicarían la caída (`I/O timeout`, `controller is down`,
`Removing after probe failure`…) se quedan en RAM y se pierden al pulsar reset.

lanewatch ataca las dos cosas:

1. **Antes de la caída:** lee cada 5 s los registros de error del enlace PCIe (LaneErr, AER,
   estado del enlace) y apunta, cuenta y limpia cada error en caliente. Así se ve si el
   enlace se va degradando antes de caer.
2. **En la caída:** un proceso vigía, escrito solo con builtins de bash (no ejecuta nada
   del disco que vigila), detecta que el controlador lleva `DEAD_SECS` segundos sin estar
   `live`. Entonces vuelca un resumen y las últimas muestras a `/dev/kmsg` y provoca un
   **kernel panic** (`sysrq c`). En el panic, el kernel guarda el final del dmesg en la
   NVRAM EFI (pstore), y en el siguiente arranque `systemd-pstore` lo deja en
   `/var/lib/systemd/pstore/`.

> **Aviso.** Con el vigía armado, si el disco cae la máquina hace panic a propósito y se
> queda congelada (o se reinicia, si `kernel.panic` > 0). Cuando eso ocurre, el disco
> lleva ya `DEAD_SECS` (120 s por defecto) sin responder y el sistema no sirve de todas
> formas. Para que solo registre, sin panic: `sudo touch /etc/lanewatch.no-panic`.

## El caso que lo originó

Torre con MSI MAG X570 Tomahawk WiFi. El disco raíz es un Samsung 990 PRO 1 TB en M2_1
(líneas de la CPU, root port `00:01.1`, disco en `01:00.0`), con btrfs sobre LUKS.

- Caídas: 14 sep 2026 (siete en una hora), 21 sep (cuatro, con llama.cpp procesando
  prompts largos), 17 nov y 23 nov de madrugada. Entre el 21 sep y el 17 nov, ninguna.
- En septiembre el enlace entrenó dos veces a **Gen4 x1** en vez de x4.
- Desde entonces entrena a x4, pero el **carril 1** da LaneErr en caliente en todos los
  arranques, y desde el ~19 nov aparecen errores AER corregibles **Replay Timer Timeout**
  (el enlace tiene que retransmitir).
- El ahorro de energía del enlace (ASPM L1) está apagado en ese enlace.

**Hipótesis principal, sin confirmar:** integridad de señal al límite en Gen4 entre la
ranura y el disco. Experimento previsto: medir la tasa de errores en Gen4 con la v2 y
compararla con la de M2_1 forzada a Gen3 en la BIOS. Si los errores desaparecen en Gen3,
causa confirmada. Si no, el siguiente paso es cambiar el disco de ranura para separar disco
y ranura.

## Requisitos

- Linux con systemd y arranque UEFI; kernel con `CONFIG_EFI_VARS_PSTORE` (Arch: sí, pero
  desactivado por defecto: hace falta `efi_pstore.pstore_disable=0`).
- bash ≥ 5 (usa `$EPOCHSECONDS`; si existe `/usr/lib/bash/sleep`, usa `sleep` como builtin).
- `pciutils` (`setpci`). `nvme-cli` es opcional (SMART y APST al arrancar).
- systemd-boot para que el instalador edite la línea del kernel; con otro gestor de
  arranque, añádela a mano.

## Instalación

```sh
git clone https://github.com/amt911/lanewatch && cd lanewatch
tests/todos.sh            # opcional: pruebas sin root
sudo ./instalar.sh        # o: sudo ENTRY=/boot/loader/entries/<tu>.conf ./instalar.sh
# reiniciar: pstore se activa con la nueva línea del kernel
```

El instalador:
- copia el script y el servicio, guardando antes copia de lo que reemplaza (`*.v1.bak`);
- añade `efi_pstore.pstore_disable=0` a **una** entrada de systemd-boot, con copia
  `*.bak-<fecha>`, y deja intactas las demás como vía de escape;
- habilita `systemd-pstore.service` y `lanewatch.service`.

## Configuración

Los valores por defecto son los del caso de arriba. Para otro equipo, crea
`/etc/default/lanewatch`:

```sh
EP=01:00.0                       # disco: cat /sys/class/nvme/nvme*/address
RP=00:01.1                       # su root port: lspci -tv
WATCH_MODEL="Samsung SSD 990 PRO"  # prefijo de /sys/class/nvme/nvmeX/model
DEAD_SECS=120                    # segundos sin "live" antes del panic
IV=5                             # segundos entre muestras
```

El vigía **solo se arma** si en `EP` hay un controlador cuyo modelo empieza por
`WATCH_MODEL`. Si cambias el disco de ranura, no hará panic en cada arranque: lo anota y
se queda sin armar hasta que ajustes `EP`/`RP`.

## Leer los resultados

| Dónde | Qué |
|---|---|
| `/var/log/lanewatch.persist.log` | Eventos con fecha: arranque (valores de entrenamiento, SMART, APST, estado de pstore), cada error en caliente con totales, cambios de enlace o estado, y un latido cada hora. |
| `/var/lib/systemd/pstore/*/dmesg.txt` | Tras una caída: final del dmesg con los mensajes del driver `nvme` y el volcado `lanewatch: CAIDA …`. |
| `/dev/shm/lanewatch.trace{,.1}` | Una línea por muestra (última hora y la anterior). Se pierde al reiniciar. |
| `/dev/shm/dmesg-live.log` | dmesg completo en RAM, por si la máquina sigue viva tras la caída. |

```sh
grep -E 'EVENTO|CAIDA|LATIDO|PSTORE|vigia' /var/log/lanewatch.persist.log | tail -30
```

Decodificación rápida:

- **LnkSta**: `1044` = Gen4 x4, `1014` = Gen4 x1, `1043` = Gen3 x4 (los 4 bits bajos son la
  velocidad, los bits 4–9 el ancho).
- **LaneErr** (`LaneErrSta` del root port): bit *n* = error en el carril *n*. Se anota el
  valor que dejó el entrenamiento en el POST y luego se limpia; todo lo posterior es en
  caliente.
- **AER corregible**: `RxErr` (0x1), `BadTLP` (0x40), `BadDLLP` (0x80), `ReplayRollover`
  (0x100), `ReplayTimeout` (0x1000)… Si salen muchos, el enlace está retransmitiendo.
- **AER-NO-CORREGIBLE**: grave; suele preceder a la caída.

## Desactivar o desinstalar

```sh
sudo touch /etc/lanewatch.no-panic        # sigue registrando, sin panic
sudo systemctl disable --now lanewatch.service
sudo rm /etc/systemd/system/lanewatch.service /usr/local/bin/lanewatch.sh
# y quitar efi_pstore.pstore_disable=0 de la entrada de arranque si ya no lo quieres
```

## Pruebas

`tests/todos.sh` ejecuta el script contra un sysfs y un `setpci` falsos (sin root) y
comprueba:

| Escenario | Esperado |
|---|---|
| `ok` | errores en caliente contados, decodificados y limpiados; sin panic |
| `flap` | el controlador pasa por `resetting` 1 s y vuelve; sin panic |
| `dead` | controlador `dead` y enlace `ffff`; volcado `CAIDA` y panic |
| `gone` | el controlador desaparece de sysfs; panic |
| `nopanic` | caída con `/etc/lanewatch.no-panic`; volcado sin panic |
| `otro-disco` | otro modelo en `EP`; el vigía no se arma |
| `sabotaje` | caída con `DEAD_SECS=100`: el panic **no** debe llegar antes de tiempo |

Si se rompe el disparo del panic, `dead` y `gone` fallan.

## Limitaciones

- bash no puede bloquear sus páginas en memoria (`mlock`). El vigía se despierta cada
  segundo, así que sus páginas siguen calientes, y el servicio lleva `MemorySwapMax=0`,
  pero no es una garantía absoluta.
- pstore EFI guarda solo el final del dmesg (~10 KB por defecto, `pstore.kmsg_bytes`). El
  volcado de lanewatch es corto a propósito para no desplazar los mensajes del driver.
- Con `kernel.panic=0` (el defecto), tras el panic la máquina se queda congelada hasta que
  la reinicias a mano. El log ya está guardado.
- Los registros `ECAP_SECPCI` (LaneErr) necesitan la capability *Secondary PCI Express*
  (Gen3 o superior).
