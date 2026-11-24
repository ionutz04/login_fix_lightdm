#!/usr/bin/env bash
# Read-only. Shows whether a seat's greeter X server is wedged in vga_get (the bug in this repo).
# Needs sudo to read /proc/<pid>/stack. Changes nothing.
set -uo pipefail
echo "== GPUs: which is the boot VGA device, which seat owns each card"
for c in /dev/dri/card*; do
  [ -e "$c" ] || continue
  path=$(udevadm info -q property -n "$c" | sed -n 's/^ID_PATH=pci-//p' | tr '_' ':')
  seat=$(udevadm info -q property -n "$c" | sed -n 's/^ID_SEAT=//p'); seat=${seat:-seat0}
  bv=$(cat "/sys/bus/pci/devices/$path/boot_vga" 2>/dev/null || echo '?')
  drv=$(basename "$(readlink "/sys/bus/pci/devices/$path/driver" 2>/dev/null)" 2>/dev/null)
  echo "  $c  pci=$path  seat=$seat  boot_vga=$bv  driver=$drv"
done
echo; echo "== Xorg servers (a wedged one shows STAT D and wchan vga_get)"
bad=0
while read -r pid stat etime cmd; do
  [ -n "$pid" ] || continue
  wchan=$(sudo cat "/proc/$pid/wchan" 2>/dev/null)
  echo "  pid=$pid stat=$stat up=$etime wchan=${wchan:-?}"; echo "    $cmd" | cut -c1-140
  if [ "$wchan" = "vga_get" ]; then
    bad=1; echo "    >>> WEDGED in vga_get. kernel stack:"; sudo head -12 "/proc/$pid/stack" 2>/dev/null | sed 's/^/        /'
  fi
done < <(ps -C Xorg -o pid=,stat=,etime=,args= )
echo; echo "== VGA arbiter (a lock held on the boot VGA device while another GPU waits is the deadlock)"
sudo timeout 5 head -1 /dev/vga_arbiter 2>/dev/null | sed 's/^/  /'
echo "  processes with the arbiter open:"
sudo sh -c 'for p in /proc/[0-9]*; do ls -l $p/fd 2>/dev/null | grep -q vga_arbiter && echo "    $(basename $p) $(cat $p/comm)"; done'
echo; echo "== lightdm per-seat X config in effect"
sudo lightdm --show-config 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | grep -E 'Seat:|xserver-command' | sed 's/^/  /'
[ "$bad" -eq 1 ] && { echo; echo "RESULT: a greeter Xorg is wedged in vga_get (this bug)."; exit 2; } || { echo; echo "RESULT: no Xorg is wedged in vga_get right now."; }
