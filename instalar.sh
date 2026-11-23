#!/bin/bash
# Instala lanewatch y activa pstore EFI. Ejecutar con sudo desde el repo.
#
#   sudo ./instalar.sh                      # entrada de arranque: /boot/loader/entries/arch.conf
#   sudo ENTRY=/boot/loader/entries/x.conf ./instalar.sh
#
# Copias de seguridad de lo que reemplaza: <fichero>.v1.bak (solo la primera vez) y
# <entrada>.bak-<fecha>. Solo toca UNA entrada de systemd-boot: deja las demas (p. ej.
# la "fallback") como via de escape. Con otro gestor de arranque, anade a mano
# efi_pstore.pstore_disable=0 a la linea del kernel (ver README).
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "Ejecutar con sudo." >&2; exit 1; }
src=$(dirname "$(readlink -f "$0")")
ts=$(date +%Y%m%d-%H%M%S)
entry=${ENTRY:-/boot/loader/entries/arch.conf}
param=efi_pstore.pstore_disable=0

bash -n "$src/lanewatch.sh"
command -v setpci >/dev/null || { echo "Falta setpci (paquete pciutils)." >&2; exit 1; }

backup_once() { [ -e "$1" ] && [ ! -e "$1.v1.bak" ] && cp "$1" "$1.v1.bak"; return 0; }
backup_once /usr/local/bin/lanewatch.sh
backup_once /etc/systemd/system/lanewatch.service
install -m 0755 "$src/lanewatch.sh" /usr/local/bin/lanewatch.sh
install -m 0644 "$src/lanewatch.service" /etc/systemd/system/lanewatch.service

if [ ! -f "$entry" ]; then
  echo "AVISO: no existe $entry. Anade $param a la linea del kernel a mano; sin eso pstore no guarda nada."
elif grep -q "$param" "$entry"; then
  echo "$entry ya tiene $param"
else
  cp "$entry" "$entry.bak-$ts"
  sed -i "/^options / s/\$/ $param/" "$entry"
fi

systemctl enable systemd-pstore.service
systemctl daemon-reload
systemctl enable lanewatch.service
systemctl restart lanewatch.service

echo "=== comprobacion ==="
[ -f "$entry" ] && grep '^options' "$entry"
echo "systemd-pstore: $(systemctl is-enabled systemd-pstore.service)"
echo "lanewatch:      $(systemctl is-active lanewatch.service)"
sleep 2
tail -8 /var/log/lanewatch.persist.log
echo
echo "pstore se activa en el PROXIMO arranque (linea del kernel). Reinicia cuando te venga bien."
