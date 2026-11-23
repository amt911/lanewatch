#!/bin/bash
# uso: escenario.sh <escenario>   escenarios: ok flap dead gone nopanic otro-disco ro ro-arranque
S=$(dirname "$(readlink -f "$0")"); SC=$1
T=$(mktemp -d); export FAKE_REGS=$T/regs; mkdir -p $FAKE_REGS
P=$T/pci; mkdir -p $P/nvme/nvme9/nvme9n1 $P/nvme/nvme9/hwmon3
M="Samsung SSD 990 PRO 1TB"; [ "$SC" = otro-disco ] && M="WDC WDBA3V0010BNC-WRSN"; echo "$M" >$P/nvme/nvme9/model
echo live >$P/nvme/nvme9/state; echo 41850 >$P/nvme/nvme9/hwmon3/temp1_input
echo 1044 >$FAKE_REGS/01_00_0_CAP_EXP_12_w
echo 0000000f >$FAKE_REGS/00_01_1_ECAP_SECPCI_08_l     # valor de entrenamiento
echo " 259 0 nvme9n1 10 0 4096 0 5 0 2048 0" >$T/diskstats
echo efi_pstore >$T/backend
R0=rw; [ "$SC" = ro-arranque ] && R0=ro; echo "/dev/mapper/x / btrfs $R0,relatime 0 0" >$T/mounts
export PCIDEV=$P SETPCI=$S/fake-setpci LIVE=$T/live KEEP=$T/keep TRACE=$T/trace KMSG=$T/kmsg \
  SYSRQ=$T/sysrq NOPANIC=$T/nopanic PSTORE_DIR=$T/pstore PSTORE_BACKEND=$T/backend DISKSTATS=$T/diskstats \
  IV=1 DEAD_SECS=${DS:-3} RO_SECS=2 MOUNTS=$T/mounts TRACE_MAX=4 DMESG_LIVE=$T/dmesg
[ "$SC" = nopanic ] && touch $T/nopanic
setsid bash $S/../lanewatch.sh >$T/stdout 2>&1 & PID=$!
sleep 2.5
# error en caliente: carril 1 + ReplayTimeout, dos veces
echo 00000002 >$FAKE_REGS/00_01_1_ECAP_SECPCI_08_l; echo 00001000 >$FAKE_REGS/01_00_0_ECAP_AER_10_l; echo 0001 >$FAKE_REGS/01_00_0_CAP_EXP_0a_w
sleep 1.5
echo 00001000 >$FAKE_REGS/01_00_0_ECAP_AER_10_l
sleep 1.5
case $SC in
  flap) echo resetting >$P/nvme/nvme9/state; sleep 1.5; echo live >$P/nvme/nvme9/state; sleep 4 ;;
  dead|nopanic|otro-disco) echo dead >$P/nvme/nvme9/state; echo ffff >$FAKE_REGS/01_00_0_CAP_EXP_12_w; sleep 6 ;;
  gone) rm -rf $P/nvme/nvme9; echo ffff >$FAKE_REGS/01_00_0_CAP_EXP_12_w; sleep 6 ;;
  ok|ro-arranque) sleep 5 ;;
  ro) echo "/dev/mapper/x / btrfs ro,relatime 0 0" >$T/mounts; sleep 5 ;;
esac
kill -- -$PID 2>/dev/null; wait $PID 2>/dev/null
echo "##### $SC  sysrq=[$(cat $T/sysrq 2>/dev/null)]  stdout_bytes=$(wc -c <$T/stdout)"
echo "--- keep:"; cat $T/keep | cut -c1-230
echo "--- kmsg (deadman):"; grep -vE "lanewatch: (=====|ENTRENAMIENTO|pstore|limpiado|EVENTO|CAMBIO|LATIDO|SMART|APST)" $T/kmsg | cut -c1-260
echo "--- writes:"; cat $FAKE_REGS/writes.log | sort | uniq -c
echo "--- trace tail:"; tail -2 $T/trace; ls $T/trace.1 >/dev/null 2>&1 && echo "(rotado ok)"
[ -s $T/stdout ] && { echo "--- stdout:"; cat $T/stdout; }
rm -rf $T
