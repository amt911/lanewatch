#!/bin/bash
# Ejecuta todos los escenarios en paralelo y comprueba si el vigia provoca panic o no.
# Sin root: usa sysfs y setpci falsos. Sale con 1 si algun escenario no da lo esperado.
D=$(dirname "$(readlink -f "$0")")
bash -n "$D/../lanewatch.sh" || exit 1
declare -A espera=([ok]="" [flap]="" [dead]=c [gone]=c [nopanic]="" [otro-disco]="" [sabotaje]="")
O=$(mktemp -d)
for sc in ok flap dead gone nopanic otro-disco; do "$D/escenario.sh" "$sc" >"$O/$sc" 2>&1 & done
DS=100 "$D/escenario.sh" dead >"$O/sabotaje" 2>&1 &   # el panic NO debe llegar antes de DEAD_SECS
wait
fallos=0
for sc in "${!espera[@]}"; do
  got=$(sed -n 's/^#####.*sysrq=\[\([^]]*\)\].*/\1/p' "$O/$sc")
  out=$(sed -n 's/^#####.*stdout_bytes=\([0-9]*\).*/\1/p' "$O/$sc")
  if [ "$got" = "${espera[$sc]}" ] && [ "$out" = 0 ]; then
    printf 'OK    %-11s sysrq=[%s]\n' "$sc" "$got"
  else
    printf 'FALLO %-11s sysrq=[%s] esperado=[%s] stdout=%s bytes\n' "$sc" "$got" "${espera[$sc]}" "$out"
    fallos=$((fallos + 1))
  fi
done
[ "$fallos" -eq 0 ] || { echo "Detalle en $O"; exit 1; }
grep -q 'CAIDA:' "$O/dead" && grep -q 'EVENTO EN CALIENTE: LaneErr=00000002(carril 1) AER-corregible=00001000(ReplayTimeout)' "$O/ok" \
  || { echo "FALLO: falta el volcado CAIDA o el evento decodificado. Detalle en $O"; exit 1; }
echo "Todo bien."; rm -rf "$O"
