#!/bin/sh
# Laser 500 sim regression: boot, keyboard, PRG, disk read (.nic, .dsk) and
# write (save, reboot, run). Screenshots go to out/regression/ for a look.
# Disk images come from refs/ and software/ (not in git); missing ones are skipped.
set -u
cd "$(dirname "$0")"
make -s || exit 1
O=out/regression
mkdir -p "$O"
fail=0
T=$(mktemp -d)

run() {  # name, expected-text-in-log (grep -E), args...
	name=$1; shift; want=$1; shift
	if ./obj_hl/Vtop --quiet --screenshot-dir "$O" --screenshot-prefix "$name" "$@" > "$O/$name.log" 2>&1 \
		&& grep -Eq "$want" "$O/$name.log"; then
		echo "ok   $name"
	else
		echo "FAIL $name (see $O/$name.log)"; fail=1
	fi
}

VTDOS=../refs/laser500emu/software/disks/vt-dos.nic
GAMES="../software/mister11/2_s0 !.dsk"
PRG=../software/mister11/cross_chase.prg

run boot   'SHOT 120'             --stop-at-frame 120 --screenshot 120
run print  'SHOT 260'             --stop-at-frame 260 --send-keys '70:PRINT 2+3\n' --screenshot 260
[ -f "$PRG" ] && run prg 'LOAD done frame 100' --prg "$PRG@100" --send-keys '110:RUN\n' --stop-at-frame 300 --screenshot 300
if [ -f "$VTDOS" ]; then
	run nic_boot 'read lba 32 blocks 16' --disk1 "$VTDOS" --stop-at-frame 300 --screenshot 300 --fdc-log
	cp "$VTDOS" "$T/w.nic"
	run nic_save 'writes 3' --disk1 "$T/w.nic" --disk1-save "$T/w2.nic" \
		--send-keys '230:10 PRINT "SAVED OK"\n' --send-keys '240:SAVE "TEST"\n' --stop-at-frame 800
	run nic_reload 'SHOT 700' --disk1 "$T/w2.nic" --send-keys '230:RUN "TEST"\n' --stop-at-frame 700 --screenshot 700
	python3 -I ../tools/laser500_disk.py check "$T/w2.nic" | tail -1
fi
[ -f "$GAMES" ] && run dsk_tarzan 'read lba 16 blocks 8' --disk1 "$GAMES" --send-keys '230:run "tarzan"\n' \
	--stop-at-frame 1400 --screenshot 1400 --fdc-log

rm -rf "$T"
echo "screenshots: $O (nic_reload should say 'saved ok', dsk_tarzan the TARZAN menu)"
exit $fail
