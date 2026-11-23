#!/bin/bash
# lanewatch - vigila el NVMe raiz (Samsung 990 PRO, 01:00.0) y deja constancia de su caida.
#
# POR QUE EXISTE: el Samsung 990 PRO (01:00.0, root port 00:01.1) llego a entrenar a
# Gen4 x1 teniendo LnkCap x4, da LaneErr en caliente en el carril 1 y Replay Timer
# Timeouts (AER), y desaparece de vez en cuando: 14 sep, 21 sep (bajo carga de LLM),
# 17 nov, 23 nov de madrugada. Cuando desaparece, el journal muere con el disco: por
# eso las caidas no dejan ni una linea.
#
# v1 (sep 2026): muestras de LaneErr/AER/LnkSta cada 5 s a /dev/shm (RAM) y los
#   CAMBIOS a /var/log. Limite: lo de RAM se pierde al reiniciar, y la caida del
#   23 nov quedo sin registrar.
#
# v2 (23 nov 2026):
#   - Vigia de caida (deadman) hecho SOLO con builtins de bash, en su propio proceso:
#     sigue funcionando aunque el disco raiz ya no responda. Si el controlador deja de
#     estar "live" DEAD_SECS seguidos, vuelca resumen + ultimas muestras a /dev/kmsg y
#     provoca un panic (sysrq c). El kernel guarda el final del dmesg (con los mensajes
#     del driver nvme) en la NVRAM EFI via pstore, y systemd-pstore lo deja en
#     /var/lib/systemd/pstore/ en el siguiente arranque.
#     Requiere efi_pstore.pstore_disable=0 en la linea de arranque.
#     Para que NO haga panic (solo registrar en RAM):  touch /etc/lanewatch.no-panic
#   - Cada error AER/LaneErr se cuenta y se limpia: se ve la TASA, no solo el primero.
#   - DevSta sin el bit 5 (Transactions Pending: ruido normal de E/S).
#   - Bloque y controlador resueltos por direccion PCI: nvme0/nvme1 se intercambian
#     entre arranques y v1 media el disco equivocado la mitad de las veces.
#   - Fecha completa en cada linea persistida; temperatura y estado del controlador en
#     cada muestra; SMART, APST y estado de pstore al arrancar; latido cada hora.
#
# v2.1 (23 nov 2026): segundo disparador, la raiz en SOLO LECTURA durante RO_SECS. En
#   la ultima caida se vio en pantalla un error de btrfs ("corrupt" / escritura). btrfs
#   pasa la raiz a solo lectura tanto si el disco se cae (errores de E/S) como si su
#   tree-checker detecta metadatos corruptos en RAM antes de escribirlos; en el segundo
#   caso el controlador sigue "live" y el primer disparador no saltaria nunca.

RP=${RP:-00:01.1}       # root port (lado CPU) - el que registra LaneErr
EP=${EP:-01:00.0}       # endpoint (el disco)
IV=${IV:-5}             # segundos entre muestras
DEAD_SECS=${DEAD_SECS:-120}   # tiempo seguido sin "live" para darlo por caido
RO_SECS=${RO_SECS:-15}        # tiempo con la raiz en solo lectura (deja terminar al kernel)
MOUNTS=${MOUNTS:-/proc/self/mounts}
TRACE_MAX=${TRACE_MAX:-720}   # muestras por fichero de traza (1 h a 5 s) y periodo del latido

LIVE=${LIVE:-/dev/shm/lanewatch.log}          # detalle, se pierde al reiniciar
TRACE=${TRACE:-/dev/shm/lanewatch.trace}      # una linea por muestra (rota a .1)
KEEP=${KEEP:-/var/log/lanewatch.persist.log}  # eventos, sobrevive al reinicio
KMSG=${KMSG:-/dev/kmsg}
SYSRQ=${SYSRQ:-/proc/sysrq-trigger}
DMESG_LIVE=${DMESG_LIVE:-/dev/shm/dmesg-live.log}
NOPANIC=${NOPANIC:-/etc/lanewatch.no-panic}
PCIDEV=${PCIDEV:-/sys/bus/pci/devices/0000:$EP}
PSTORE_DIR=${PSTORE_DIR:-/var/lib/systemd/pstore}
PSTORE_BACKEND=${PSTORE_BACKEND:-/sys/module/pstore/parameters/backend}
SETPCI=${SETPCI:-setpci}
DISKSTATS=${DISKSTATS:-/proc/diskstats}

# sleep como builtin: el vigia no debe ejecutar binarios del disco que vigila.
enable -f /usr/lib/bash/sleep sleep 2>/dev/null

r() { "$SETPCI" -s "$1" "$2" 2>/dev/null; }

kmsg() {                                # $1 = nivel (0 emerg .. 7 debug)
  printf '<%d>lanewatch: %s\n' "$1" "$2" 2>/dev/null >>"$KMSG"
}

note() {                                # RAM y kmsg primero, disco en segundo plano
  # RAM SIEMPRE, y sin bloquear: si el disco agoniza, la escritura a $KEEP puede
  # quedarse colgada en I/O y matariamos justo el registro que venimos a capturar.
  # Por eso el volcado a disco va a un subshell aparte. kmsg deja la nota en el
  # dmesg, que es lo que pstore guarda si hay panic.
  local line
  printf -v line '%(%F %T)T  %s' -1 "$*"
  echo "$line" >>"$LIVE"
  kmsg 5 "$*"
  { echo "$line" >>"$KEEP" && sync -f "$KEEP"; } 2>/dev/null &
}

clear_rw1c() {                          # RW1C: se limpia reescribiendo lo leido
  local dev=$1 reg=$2 v
  v=$(r "$dev" "$reg")
  [ -n "$v" ] && [ "$v" != "00000000" ] && [ "$v" != "0000" ] && r "$dev" "$reg=$v"
}

ce_names() {                            # bits de AER Correctable Error Status
  local v=$((16#$1)) s=""
  ((v & 0x0001)) && s+="RxErr,"
  ((v & 0x0040)) && s+="BadTLP,"
  ((v & 0x0080)) && s+="BadDLLP,"
  ((v & 0x0100)) && s+="ReplayRollover,"
  ((v & 0x1000)) && s+="ReplayTimeout,"
  ((v & 0x2000)) && s+="AdvNonFatal,"
  ((v & 0x4000)) && s+="CorrIntErr,"
  ((v & 0x8000)) && s+="HdrLogOverflow,"
  echo "${s%,}"
}

lane_list() {                           # bits de LaneErrSta -> "carril 1,3"
  local v=$((16#$1)) i s=""
  for ((i = 0; i < 16; i++)); do ((v >> i & 1)) && s+="$i,"; done
  echo "carril ${s%,}"
}

# Controlador y bloque del disco por su direccion PCI (los nombres bailan).
CTRL=""
for c in "$PCIDEV"/nvme/nvme*; do [ -d "$c" ] && CTRL=${c##*/}; done
STATE_FILE=$PCIDEV/nvme/$CTRL/state
BLK=${CTRL}n1
MODEL=""
[ -n "$CTRL" ] && read -r MODEL 2>/dev/null <"$PCIDEV/nvme/$CTRL/model"
# El panic solo se arma si en $EP esta de verdad el disco raiz: si se cambia de
# ranura, aqui habria otro disco o nada, y se haria panic en cada arranque.
WATCH_MODEL=${WATCH_MODEL:-Samsung SSD 990 PRO}
TEMP_FILE=""
for t in "$PCIDEV"/nvme/"$CTRL"/hwmon*/temp1_input; do [ -r "$t" ] && TEMP_FILE=$t; done

dump_final() {                          # solo builtins: el disco puede no estar
  # Corto a proposito (12 muestras): pstore guarda solo el FINAL del dmesg y lo que
  # importa son los mensajes de btrfs/nvme que el kernel ha escrito justo antes.
  local -a t=()
  local n from i rec=""
  kmsg 2 "CAIDA: $1, desde hace $2 s. Ultimas muestras:"
  mapfile -t t 2>/dev/null <"$TRACE.1"
  mapfile -t -O "${#t[@]}" t 2>/dev/null <"$TRACE"
  n=${#t[@]}
  from=$((n > 12 ? n - 12 : 0))
  for ((i = from; i < n; i++)); do
    rec+="${t[i]} | "
    if (((i - from) % 4 == 3 || i == n - 1)); then kmsg 2 "$rec"; rec=""; fi
  done
}

root_mode() {                           # RMODE = rw | ro | ? (solo builtins)
  local dev mp fs opts rest
  RMODE="?"
  while read -r dev mp fs opts rest; do
    [ "$mp" = / ] && RMODE=${opts%%,*}  # la ultima linea de "/" es la que manda
  done 2>/dev/null <"$MOUNTS"
}

fire() {                                # $1 motivo, $2 segundos
  local backend=""
  dump_final "$1" "$2"
  read -r backend 2>/dev/null <"$PSTORE_BACKEND"
  if [ -e "$NOPANIC" ]; then
    kmsg 2 "$NOPANIC existe: sin panic. Este volcado solo esta en RAM (dmesg)."
  else
    kmsg 0 "panic provocado por lanewatch para que pstore (backend=${backend:-?}) guarde este dmesg en NVRAM EFI"
    printf c 2>/dev/null >"$SYSRQ"
  fi
}

deadman() {
  local st since=0 now armed=1 seen_rw=0 ro_since=0 ro_armed=1
  while :; do
    now=$EPOCHSECONDS

    # A) el controlador deja de estar "live" (disco fuera del bus o colgado)
    if ! read -r st 2>/dev/null <"$STATE_FILE"; then st=desaparecido; fi
    if [ "$st" = live ]; then
      [ "$since" -ne 0 ] && kmsg 4 "$CTRL vuelve a live tras $((now - since)) s"
      since=0
      armed=1
    else
      if [ "$since" -eq 0 ]; then
        since=$now
        kmsg 2 "$CTRL ($EP) estado=$st: si sigue asi ${DEAD_SECS} s se da por caido"
      fi
      if [ "$armed" -eq 1 ] && ((now - since >= DEAD_SECS)); then
        armed=0
        fire "controlador $CTRL ($EP) estado=$st" $((now - since))
      fi
    fi

    # B) la raiz pasa a solo lectura (btrfs aborta: E/S o corrupcion detectada).
    #    Solo despues de haberla visto rw: no confundir con el arranque.
    root_mode
    if [ "$RMODE" = rw ]; then
      seen_rw=1
      ro_since=0
    elif [ "$RMODE" = ro ] && [ "$seen_rw" -eq 1 ]; then
      if [ "$ro_since" -eq 0 ]; then
        ro_since=$now
        kmsg 2 "la raiz ha pasado a SOLO LECTURA: en ${RO_SECS} s se vuelca y se da por caida"
      fi
      if [ "$ro_armed" -eq 1 ] && ((now - ro_since >= RO_SECS)); then
        ro_armed=0
        fire "raiz en solo lectura (controlador $CTRL estado=$st)" $((now - ro_since))
      fi
    fi

    sleep 1
  done
}

io_stats() {                            # sectores leidos/escritos del bloque, en MB
  local maj min name r1 r2 rs r4 w1 w2 ws rest
  while read -r maj min name r1 r2 rs r4 w1 w2 ws rest; do
    if [ "$name" = "$BLK" ]; then
      echo "read=$((rs / 2048))MB write=$((ws / 2048))MB"
      return
    fi
  done <"$DISKSTATS"
  echo "io=?"
}

note "===== lanewatch v2 arranca $(date -Is)  ctrl=${CTRL:-NINGUNO} blk=$BLK ====="

# 1) Valor DE ENTRENAMIENTO: lo que dejo el POST, antes de tocar nada.
note "ENTRENAMIENTO  LaneErrSta=$(r $RP ECAP_SECPCI+08.l)  DevSta=$(r $EP CAP_EXP+0a.w)  LnkSta=$(r $EP CAP_EXP+12.w)  (LnkSta 1014=Gen4 x1, 1044=Gen4 x4, 1043=Gen3 x4)"

# 2) Contexto del arranque: pstore, SMART, APST.
backend=""
read -r backend 2>/dev/null <"$PSTORE_BACKEND"
if [ -z "$backend" ] || [ "$backend" = "(null)" ]; then
  note "PSTORE INACTIVO (backend=${backend:-?}): falta efi_pstore.pstore_disable=0 en la linea de arranque; una caida NO dejara rastro."
else
  note "pstore activo: backend=$backend"
fi
dumps=("$PSTORE_DIR"/*/)
[ -d "${dumps[0]}" ] && note "PSTORE: ${#dumps[@]} volcado(s) guardado(s); el mas reciente: ${dumps[-1]} (ver dmesg.txt)"
if [ -n "$CTRL" ] && command -v nvme >/dev/null; then
  smart=$(nvme smart-log "/dev/$CTRL" 2>/dev/null |
    grep -iE '^(critical_warning|temperature |percentage_used|media_errors|num_err_log_entries|unsafe_shutdowns|power_cycles|power_on_hours|warning temperature time|critical composite temperature time)' |
    tr -s ' ' | tr '\n' ';')
  note "SMART $CTRL: ${smart:-no disponible}"
  apst=$(nvme get-feature "/dev/$CTRL" -f 0x0c -H 2>/dev/null | grep -m1 -i 'APSTE' | tr -s ' ')
  note "APST $CTRL: ${apst:-no disponible}"
fi

# 3) Limpiar. A partir de aqui, cualquier error es EN CALIENTE.
clear_rw1c $RP ECAP_SECPCI+08.l
clear_rw1c $EP CAP_EXP+0a.w
clear_rw1c $EP ECAP_AER+10.l
clear_rw1c $EP ECAP_AER+04.l
note "limpiado -> LaneErrSta=$(r $RP ECAP_SECPCI+08.l) DevSta=$(r $EP CAP_EXP+0a.w). Todo lo que salga ahora es en caliente."

# 4) Vigia de caida, aislado: sin stdout/stderr (si journald se cuelga con el disco,
#    escribir ahi podria bloquearlo).
if [ -n "$CTRL" ] && [[ $MODEL == "$WATCH_MODEL"* ]]; then
  deadman >/dev/null 2>&1 &
  note "vigia de caida ARMADO: $CTRL '$MODEL' en $EP; panic tras ${DEAD_SECS} s sin 'live' o ${RO_SECS} s con la raiz en solo lectura$([ -e "$NOPANIC" ] && echo ' (DESACTIVADO por '"$NOPANIC"')')"
else
  note "vigia de caida NO armado: en $EP hay '${MODEL:-nada}' y se esperaba '$WATCH_MODEL'. Revisar EP/RP si se ha cambiado el disco de ranura."
fi

# 5) dmesg en RAM: el detalle completo, por si la maquina sigue viva tras la caida.
dmesg -w >"$DMESG_LIVE" 2>/dev/null &

declare -i nlane=0 nce=0 nue=0 nds=0 samples=0
prev=""
while true; do
  lane=$(r $RP ECAP_SECPCI+08.l)
  ds=$(r $EP CAP_EXP+0a.w)
  ce=$(r $EP ECAP_AER+10.l)
  ue=$(r $EP ECAP_AER+04.l)
  lnk=$(r $EP CAP_EXP+12.w)
  st=desaparecido
  read -r st 2>/dev/null <"$STATE_FILE"
  temp="?"
  if [ -n "$TEMP_FILE" ] && read -r tm 2>/dev/null <"$TEMP_FILE"; then temp=$((tm / 1000)); fi
  io=$(io_stats)
  root_mode

  if [ -z "$lnk" ] || [ "$lnk" = ffff ]; then
    resp=no-responde                    # disco fuera del bus: no contar basura ffff
  else
    resp=ok
    ev=""
    if [ -n "$lane" ] && [ "$lane" != 00000000 ]; then
      nlane+=1; ev+=" LaneErr=$lane($(lane_list "$lane"))"; r $RP "ECAP_SECPCI+08.l=$lane"
    fi
    if [ -n "$ce" ] && [ "$ce" != 00000000 ]; then
      nce+=1; ev+=" AER-corregible=$ce($(ce_names "$ce"))"; r $EP "ECAP_AER+10.l=$ce"
    fi
    if [ -n "$ue" ] && [ "$ue" != 00000000 ]; then
      nue+=1; ev+=" AER-NO-CORREGIBLE=$ue"; r $EP "ECAP_AER+04.l=$ue"
    fi
    dse=$((16#${ds:-0} & 0xf))          # CED/NFED/FED/URD; el bit 5 (TP) es ruido
    if ((dse)); then
      ((dse & 0xe)) && nds+=1
      ev+=" DevSta=$ds"; r $EP "CAP_EXP+0a.w=$(printf %04x $dse)"
    fi
    [ -n "$ev" ] && note "EVENTO EN CALIENTE:$ev  lnk=$lnk temp=${temp}C st=$st ($io)  totales lane=$nlane ce=$nce ue=$nue devsta=$nds"
  fi

  printf -v line '%(%m-%d %T)T lane=%s ds=%s ce=%s ue=%s lnk=%s t=%sC st=%s raiz=%s %s n=%d/%d/%d/%d' \
    -1 "${lane:--}" "${ds:--}" "${ce:--}" "${ue:--}" "${lnk:--}" "$temp" "$st" "$RMODE" "$io" \
    "$nlane" "$nce" "$nue" "$nds"
  echo "$line" >>"$TRACE"

  cur="lnk=${lnk:--} st=$st resp=$resp raiz=$RMODE"
  if [ "$cur" != "$prev" ]; then
    note "CAMBIO: $cur  temp=${temp}C ($io)"
    prev="$cur"
  fi

  samples+=1
  if ((samples % TRACE_MAX == 0)); then
    mv -f "$TRACE" "$TRACE.1"
    note "LATIDO: lnk=$lnk temp=${temp}C st=$st ($io)  totales lane=$nlane ce=$nce ue=$nue devsta=$nds"
  fi
  sleep "$IV"
done
