#!/usr/bin/env bash
# ====================================================================================================
# press_1035.sh.  MODELLED ON scripts/press_1033.sh (every inherited gate carried, the card gate kept
# because 1035 STILL serves 1032's card patch), with ONE change: the kernel arm is 1035's OWN
# (armed-d13-<sha8>), which adds the STAGE90_XNU_PC_CARRIER rows that read the DEVICE's page content at
# the faulting pc.
#
# Press 1035: **THE pc QUESTION, BY THE DEVICE'S OWN PAGE CONTENT -- INSTRUMENT ONLY.**  No fix.  It
# answers the one question records/1033-reading.txt and records/1034-design-errata.txt E12 leave open:
# at launchctl[2]'s fault (pc 0x3819d474, far 0x10, dfsr 7) is the device's page word the caller's walk
# (host file VA 0x37C26474) or the data word at pc itself (0x030B131B)?  records/1035-carrier-by-pc-read.txt.
#
# THE CELLS (tools/check_1035_capture.py) are pre-registered in records/1035-carrier-by-pc-read.txt 3.
#
# Medium: the real iOS 7.1.2 HFSX rootfs over the card, with 1032's 10-byte clamp (CARD_COW=1,
# HDD_WRITE=0, the base is never written - fully reversible).  fastboot boot only, NEVER flash.
# [[mi4-hardware-run-safety-gate]]: unplug 33e80afe first, target 4a2fe00b.
# ====================================================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

# SAFETY, BY VALUE: this script boots, it never writes a partition.  The only line in the body that
# names the flash verb is this refusal, which fires if any line of the body (comments, echoes, traps)
# contains it: refuse the WHOLE script rather than run a press one edit away from a flash.
if grep -v '^[[:space:]]*#' "$0" | grep -qE '(^|[[:space:]])fastboot([[:space:]]+-[[:alnum:][:space:]-]+)*[[:space:]]+flash([[:space:]]|$)'; then
  echo "REFUSING: this script's body names the flash verb in a fastboot command - press_1035 is fastboot boot ONLY"; exit 1; fi

LIVE=out/stage90
REC=$LIVE/xnu_arm_entry-config.txt
NEW=STAGE90_XNU_PC_CARRIER
TRAP_SRC=external/xnu-hd2-darwin13/xnu/osfmk/arm/trap.c
TRAP_OBJ=out/xnu_kernel_obj_d13/osfmk_arm_trap.o
EXEC_OBJ=out/xnu_kernel_obj_d13/bsd_kern_kern_exec.o
ELF=$LIVE/xnu_arm_entry.elf
CHECKER=tools/check_1035_capture.py
CARD=$LIVE/xnu_card_hfs.img
SITE_HEX=10183720
SITE_DEC=$((16#10183720))
NEW_HEX=5010012801daf0bdc046

# BY VALUE (0-checker0): the checker can FAIL.  FIRST, before anything is decided.
[[ -f $CHECKER ]] || { echo "REFUSING: $CHECKER is absent - the capture this press produces would have no pinned reader"; exit 1; }
python3 -I "$CHECKER" --selftest >/dev/null 2>&1 || { echo "REFUSING: $CHECKER --selftest did NOT PASS - an inert checker would bless any capture"; exit 1; }

echo "== 0. the record and the image must be 1035's arm =="
grep -q "^$NEW=1\$" "$REC" || {
  echo "REFUSING: the record does not carry $NEW=1 - the pcc rows this rung IS are gated by THIS switch (tools/patch_d13_pc_carrier.py), and a record without it means the pool was built with the probe SHUT ([[mi4-build-variant-comes-from-an-env-default]]). Build it with scripts/build_1035.sh first"; exit 1; }
# 1035's OWN source of truth for the arm name: an earlier rung's arm would be a press of ITS bytes.
if grep -q '^role=1035-pc-carrier' records/revert-set.txt 2>/dev/null; then
  _parked=$(awk -F'set=' '/role=1035-pc-carrier/{split($2,a," "); print a[1]; exit}' records/revert-set.txt)
  _nowbin=armed-d13-$(sha256sum "$LIVE/xnu_arm_entry.bin" | cut -c1-8)
  [[ -z $_parked || $_parked == "$_nowbin" ]] || { echo "REFUSING: records/revert-set.txt parks 1035 as $_parked but out/stage90 holds $_nowbin - the live image is not the parked 1035 arm"; exit 1; }
fi
for k in STAGE90_XNU_EVAL_FRAME STAGE90_XNU_CALLER_PROBE STAGE90_XNU_WRITER_PROBE STAGE90_XNU_READER_PROBE STAGE90_XNU_ABT_ENTRY_PROBE \
         STAGE90_XNU_USTACK_PROBE STAGE90_XNU_H2_STACK_HEADROOM STAGE90_XNU_VM_MAX_SPLIT STAGE90_XNU_IOS7_TRAPS \
         STAGE90_XNU_GENERAL_REGS STAGE90_XNU_UNDEF_RAISE; do
  grep -q "^$k=1\$" "$REC" || { echo "REFUSING: the record does not carry $k=1 - 1035 carries the 1033 instrument verbatim and names the 1033 frame (pc/lr/r1/r2/r5/r7) as its reference; without it the pcc rows describe a boot this rung was not built against. Build it with scripts/build_1035.sh first"; exit 1; }
done
EXPECT_ARM=armed-d13-$(sha256sum "$LIVE/xnu_arm_entry.bin" | cut -c1-8)
echo "   arm = $EXPECT_ARM"

# BY VALUE (0): 1015b's GLOBAL-FIX is in the pool object this image was built from.
_gf_obj=out/xnu_kernel_obj_d13/osfmk_arm_pmap.o
_gf_kp=$(arm-none-eabi-objdump -r "$_gf_obj" 2>/dev/null | awk '$1>="00000418" && $1<="00000640"' | grep -c 'MOVW_ABS_NC.*kernel_pmap' || true)
_gf_full=$(arm-none-eabi-objdump -r "$_gf_obj" 2>/dev/null | awk '$1>="00000418" && $1<="00000640"' | grep -c 'R_ARM_CALL.*arm_tlb_flushID$' || true)
_gf_asid=$(arm-none-eabi-objdump -r "$_gf_obj" 2>/dev/null | awk '$1>="00000418" && $1<="00000640"' | grep -c 'R_ARM_CALL.*arm_tlb_flushID_ASID$' || true)
[[ "$_gf_kp" == "3" && "$_gf_full" == "1" && "$_gf_asid" == "1" ]] || {
  echo "REFUSING: pmap_flush_tlbs materializes kernel_pmap x$_gf_kp (want 3), flushID x$_gf_full / flushID_ASID x$_gf_asid (want 1/1) - 1015b's GLOBAL-FIX is NOT in the pool object, the retry storm is BACK and the run would never reach the launchctl fault. Re-run scripts/build_1035.sh"; exit 1; }
echo "   (0) by value: pmap_flush_tlbs carries the GLOBAL-FIX ($_gf_kp kernel_pmap sites, $_gf_full/$_gf_asid flush arms)"

# BY VALUE (0a): 1035'S OWN ROWS ARE IN THE STAGED SOURCE (the pool's source-content record names it)
# AND IN THE POOL OBJECT AND IN THE LINKED IMAGE (the press boots the ELF).
_src_rec=out/xnu_kernel_src_d13.sha256
[[ -f $TRAP_SRC && -f $_src_rec ]] || { echo "REFUSING: trap.c or the pool's source record is absent"; exit 1; }
grep -q "defined($NEW) && $NEW" "$TRAP_SRC" || { echo "REFUSING: $TRAP_SRC does not carry the $NEW gate - the probe is not staged"; exit 1; }
# (the manifest names sources by ABSOLUTE path, exactly as the compile loop spelled them; compare the full
# path, with a suffix fallback so the check does not depend on the tree's location)
_want=$(sha256sum "$TRAP_SRC" | awk '{print $1}')
_have=$(awk -v a="$TRAP_SRC" -v b="external/xnu-hd2-darwin13/xnu/osfmk/arm/trap.c" '$2==a||index($2,b)==length($2)-length(b)+1{print $1}' "$_src_rec" | head -1)
[[ -n "$_have" ]] || { echo "REFUSING: $_src_rec names NO entry for $TRAP_SRC - the pool's manifest does not cover trap.c, so the probe's content is unrecorded (a lookup that never matches is a defective CLAUSE, not evidence - [[mi4-self-written-record-is-not-a-constraint]])"; exit 1; }
[[ "$_want" == "$_have" ]] || { echo "REFUSING: the pool's source record says $_have but the staged trap.c hashes $_want - the pool was NOT rebuilt from the probed source"; exit 1; }
echo "   (0a-0) by value: the pool's source record names the SAME trap.c sha ($_want) - the probe IS in the object the image was linked from"
for s in xnu_live_pcc_seq= xnu_live_pcc_pc= xnu_live_pcc_near2= xnu_live_pcc_near2_ok= xnu_live_pcc_xor_walk= xnu_live_pcc_xor_table=; do
  grep -qa "^$s" <(strings "$TRAP_OBJ") || { echo "REFUSING: $TRAP_OBJ carries no $s - the pool was not recompiled with $NEW=1"; exit 1; }
  grep -qa "^$s" <(strings "$ELF") || { echo "REFUSING: the LINKED image carries no $s - the linker dropped the probed object"; exit 1; }
done
echo "   (0a) by value: trap.c (source-record matched), trap.o and the LINKED image all carry the pcc rows"

# BY VALUE (0a-1): the parent rows the pcc frame is read BESIDE survive in the pool object and the image.
for s in xnu_live_evf_pc= xnu_live_evf_far_raw= xnu_live_cal_region_end= xnu_live_wrp_r4= xnu_live_rdr_far= xnu_live_abt_lookup_far= xnu_live_abt_vmfkrv=; do
  grep -qa "^$s" <(strings "$TRAP_OBJ") || { echo "REFUSING: $TRAP_OBJ lost $s in the rebuild - the parent rows the pcc frame is read BESIDE are gone ([[mi4-one-file-many-rungs]])"; exit 1; }
done
grep -qa '^xnu_live_abt_proc_ustack$' <(strings "$EXEC_OBJ") || { echo "REFUSING: $EXEC_OBJ carries no xnu_live_abt_proc_ustack"; exit 1; }
echo "   (0a-1) by value: trap.o keeps evf/cal/wrp/rdr/abt publishers; kern_exec.o keeps the ustack accessor"

# BY VALUE (0a-checker): the 1033 reader (which the pcc frame is read beside) can still FAIL.
python3 -I tools/check_1033_capture.py --selftest >/dev/null 2>&1 || { echo "REFUSING: tools/check_1033_capture.py --selftest did NOT PASS"; exit 1; }
python3 -I tools/check_vm_max_split.py "$ELF" --expect on >/dev/null 2>&1 || { echo "REFUSING: the LINKED image's task map ceiling moved (1024)"; exit 1; }
python3 -I tools/check_d13_no_neon.py "$ELF" --symbol mach_msg_send --expect none >/dev/null 2>&1 || { echo "REFUSING: mach_msg_send is not NEON-free (1021d)"; exit 1; }
python3 -I tools/check_d13_undef_raise.py "$ELF" --expect on >/dev/null 2>&1 || { echo "REFUSING: sleh_undef lost 1020's raise"; exit 1; }
python3 -I tools/check_1023_trap24.py "$ELF" --expect on >/dev/null 2>&1 || { echo "REFUSING: mach_trap_table[24] moved (1023)"; exit 1; }
echo "   (0a-checker) by value: 1035/1033 selftests PASS; 1024 ceiling / 1021d NEON-free / 1020 raise / 1023 row 24 all PASS on the linked image"

# BY VALUE (0g): THE CARD STILL CARRIES 1032'S GUARD -- 1035 reads the world 1032/1033 produced.
_cp=tools/patch_cache_libobjc_count.py
python3 -I "$_cp" --selftest >/dev/null 2>&1 || { echo "REFUSING: $_cp --selftest failed"; exit 1; }
[[ -f $CARD ]] || { echo "REFUSING: $CARD is absent - run scripts/build_1035.sh"; exit 1; }
_got=$(dd if="$CARD" bs=1 skip=$SITE_DEC count=10 2>/dev/null | od -An -tx1 | tr -d ' \n')
[[ "$_got" == "$NEW_HEX" ]] || { echo "REFUSING: $CARD offset 0x$SITE_HEX holds $_got, not 1032's guard $NEW_HEX - this press would read a boot WITHOUT the clamp. Run scripts/build_1035.sh"; exit 1; }
python3 -I "$_cp" --check >/dev/null 2>&1 || { echo "REFUSING: $_cp --check FAILED - the card's cache header no longer declares map0 at 0x2C000000/0 (or the content anchor differs)"; exit 1; }
_rs=${STAGE90_REAL_ROOTFS:-/mnt/data/ios7-payload/v2/ios7/rootfs.hfs}
_n=$(cmp -l "$CARD" "$_rs" 2>/dev/null | wc -l || true)
[[ "$_n" == "10" ]] || { echo "REFUSING: the card differs from the pristine rootfs in $_n bytes (want EXACTLY 10) - the card is not the one build_1032.sh / build_1035.sh produced"; exit 1; }
echo "   (0g) by value: the card carries 1032's 10-byte guard, differs from the rootfs in exactly those 10 bytes, and --check PASSes"

echo "== 1. the card image (built+patched by scripts/build_1035.sh -- NOT rebuilt here) =="
echo "   $CARD  $(sha256sum "$CARD" | cut -c1-16)..."

echo "== 2. hardware gate =="
adb devices | grep -q 4a2fe00b || { echo "NO DEVICE - hold Power ~10-15s to boot it back, then re-run"; exit 1; }
fastboot devices | grep -q 33e80afe && { echo "33e80afe (the OTHER phone) is present - unplug it first (hardware gate)"; exit 1; }

# ORDER: a PREVIOUS run's RAM console is recovered BEFORE this boot overwrites the slot
# ([[mi4-last-kmsg-reader-carrier]]: the carrier is the flash slot a boot writes; `fastboot boot` burns
# the single-slot record).  If the previous press's log is not yet on the host, this press would destroy
# the only place it exists.  So: recover now, or run with STAGE90_1035_OVERWRITE_PREV=1 to say so.
echo "== 2a. recover a PREVIOUS run's RAM console before anything overwrites it =="
_prev=$(ls -1t out/stage90/captures/recovered-*-last_kmsg.txt 2>/dev/null | head -1 || true)
_prev_ok=0
if [[ -n $_prev ]]; then
  _prev_ep=$(stat -c %Y "$_prev")
  _prev_boot=$(python3 -I - "$_prev" <<'PY' || true
import sys
with open(sys.argv[1], errors="replace") as fh:
    for ln in fh:
        if "MI4IOS6_STAGE90 v1 entered" not in ln:
            continue
        for t in ln.split():
            if t.isdigit() and len(t) >= 9:
                print(t); sys.exit(0)
sys.exit(1)
PY
)
  # A recovery stamped in the file's name (recovered-...-<YYYYMMDD-HHMMSS>) or a boot time in the entry
  # line both place the capture; the slot is considered current if EITHER is newer than the last press.
  _prev_epoch=$_prev_boot
  _nm=$(basename "$_prev")
  if [[ $_nm =~ -([0-9]{8}-[0-9]{6})- ]]; then
    _d=${BASH_REMATCH[1]}
    _prev_epoch=$(date -u -d "${_d:0:4}-${_d:4:2}-${_d:6:2} ${_d:9:2}:${_d:11:2}:${_d:13:2}" +%s 2>/dev/null || echo "$_prev_epoch")
  fi
  echo "   previous capture: $_prev (file epoch $_prev_ep${_prev_epoch:+, boot epoch $_prev_epoch})"
  # MEASURED 2026-10-19: the draft read a `PRESS: <date> UTC` stamp from records/1034-usysc-trace.txt,
  # which carries none; the clause came out empty, and the `-ge` test then treated EVERY capture as
  # unrecovered (press refused on a capture made 2 min earlier).  The last press before this rung is
  # 1033's, whose fruits were COMMITTED at 788dc5e; its capture (2026-10-18 19:27) and 1034's trace both
  # postdate that commit, so a capture is recovered iff it is newer than it.  The 1034 trace itself is kept in records/ (E1-
  # E13) and its capture (2026-10-18 19:27) was checked by hand before this press.
  _last_press=$(git log -1 --format=%ct 788dc5e 2>/dev/null || true)
  if [[ -n ${_last_press:-} && -n ${_prev_epoch:-} && $_prev_epoch -ge $_last_press ]]; then
    _prev_ok=1
    echo "   (previous run's console is RECOVERED: capture epoch $_prev_epoch >= the last press epoch $_last_press)"
  fi
else
  echo "   (no recovered capture on the host)"
fi
if [[ $_prev_ok != 1 ]]; then
  if [[ ${STAGE90_1035_OVERWRITE_PREV:-0} == 1 ]]; then
    echo "   STAGE90_1035_OVERWRITE_PREV=1: proceeding although the previous run's console is not confirmed recovered."
  else
    echo "REFUSING: the previous run's RAM console is NOT confirmed recovered on the host, and the boot below"
    echo "  would overwrite the slot it exists in.  Recover it first (scripts/recover_last_kmsg.sh --read-only"
    echo "  while Android is up), or -- only if it is already adjudicated and kept in records/ -- re-run with"
    echo "  STAGE90_1035_OVERWRITE_PREV=1.  NOT booting."
    exit 1
  fi
fi

echo "== 2b. write the card image to userdata's head (partition offset 0) =="
adb -s 4a2fe00b root || true; sleep 1
adb -s 4a2fe00b shell "dd of=/dev/block/mmcblk0p25 bs=1M conv=fsync" < "$CARD"
_dev10=$(adb -s 4a2fe00b shell "dd if=/dev/block/mmcblk0p25 bs=1 skip=$SITE_DEC count=10 2>/dev/null" | od -An -tx1 | tr -d ' \n')
_card10=$(dd if="$CARD" bs=1 skip=$SITE_DEC count=10 2>/dev/null | od -An -tx1 | tr -d ' \n')
echo "   device 0x$SITE_HEX = $_dev10"
echo "   card   0x$SITE_HEX = $_card10"
[[ "$_dev10" == "$_card10" && "$_dev10" == "$NEW_HEX" ]] || { echo "REFUSING: the device's guard bytes do not match the patched card. The dd did not deliver the rung; NOT pressing."; exit 1; }
echo "   (2b') by value: the DEVICE's userdata carries 1032's guard at the offset the cache maps it from"

echo "== 3. the press (gate + runner, fastboot boot only) =="
USB_OUT="out/stage90/captures/usb-console-1035-$(date -u +%Y%m%d-%H%M%S).txt"
tools/usb_console_read.py --out "$USB_OUT" --wait 600 --seconds 0 &
USB_PID=$!
echo "   (USB console reader armed: pid $USB_PID -> $USB_OUT)"
trap 'kill "$USB_PID" 2>/dev/null || true' EXIT

scripts/preflight_boot_check.sh --allow-xnu-entry
echo "   fastboot boot -s 4a2fe00b out/stage90/stage90-qcdt.img   (fastboot boot, NEVER flash)"
_BOOT_EPOCH=$(date +%s)
echo "   _BOOT_EPOCH=$_BOOT_EPOCH"
set +e
scripts/run_and_capture.sh --allow-xnu-entry --expect-arm="$EXPECT_ARM"
RUN_RC=$?
set -e
echo "   (runner exit $RUN_RC; a resident rung not returning shows as 2)"

kill "$USB_PID" 2>/dev/null || true
# [[mi4-unguarded-wait-aborts-resident-press]]: the `set +e` around `wait` is load-bearing.
USB_RC=0
for _ in $(seq 1 40); do kill -0 "$USB_PID" 2>/dev/null || break; sleep 0.25; done
if kill -0 "$USB_PID" 2>/dev/null; then kill "$USB_PID" 2>/dev/null || true; USB_RC=-1
else set +e; wait "$USB_PID"; USB_RC=$?; set -e; fi
echo "== USB console capture: $USB_OUT =="
[ -s "$USB_OUT" ] && echo "   bytes read: $(wc -c < "$USB_OUT")" || echo "   (zero bytes)"
case "$USB_RC" in
  0)  echo "   reader exit 0: the payload's EP1-IN delivered bytes." ;;
  2)  echo "   reader exit 2: NOTHING ENUMERATED as 18d1:0910 - the payload never reached the USB idle path." ;;
  3)  echo "   reader exit 3: enumerated and claimed, EP1-IN delivered NOTHING." ;;
  -1) echo "   reader still waiting when the runner returned (killed here)." ;;
  *)  echo "   reader exit $USB_RC" ;;
esac

echo "== 4. recovery: the run's own log via /proc/last_kmsg (carrier is the FLASHED ROM) =="
for _ in $(seq 1 90); do
  if adb devices 2>/dev/null | grep -q 4a2fe00b || fastboot devices 2>/dev/null | grep -q 4a2fe00b; then break; fi
  sleep 5
done
if adb devices 2>/dev/null | grep -q 4a2fe00b; then scripts/recover_last_kmsg.sh --read-only
elif fastboot devices 2>/dev/null | grep -q 4a2fe00b; then scripts/recover_last_kmsg.sh
else
  echo "   (device not visible yet.  If it stays dark, NOTHING host-side brings it back:"
  echo "    THE OPERATOR'S POWER PRESS is the next step ([[mi4-device-dark-needs-power-press]])."
  echo "    Then: scripts/recover_last_kmsg.sh --read-only while Android is up; do not boot anything"
  echo "    else first - the slot is this run's only copy.)"
fi

echo "== 5. read the recovered capture: run the 1035 reader and print its cell =="
_last=$(ls -1t out/stage90/captures/recovered-*-last_kmsg.txt 2>/dev/null | head -1 || true)
if [[ -n $_last ]]; then
  _last_epoch=$(stat -c %Y "$_last" 2>/dev/null || echo 0)
  if [[ -n ${_BOOT_EPOCH:-} && $_last_epoch -lt $_BOOT_EPOCH ]]; then
    echo "   NO READING - STALE SLOT: the newest capture is OLDER than this press's boot."
    echo "     capture: $_last (mtime $(stat -c %y "$_last"), epoch $_last_epoch)"
    echo "     this boot: epoch $_BOOT_EPOCH"
    echo "   This run did NOT re-write the RAM-console slot ([[mi4-last-kmsg-reader-carrier]]).  NOT"
    echo "   adjudicating.  THE OPERATOR'S POWER PRESS is needed; then recover_last_kmsg.sh"
    echo "   --read-only and adjudicate ONLY a capture newer than this boot.  Do NOT boot first."
  else
    echo "   reading the NEWEST recovered capture: $_last"
    set +e
    python3 -I "$CHECKER" "$_last"
    _rd_rc=$?
    set -e
    echo "   (reader exit $_rd_rc; see records/1035-carrier-by-pc-read.txt 3 for the pre-registered cells)"
  fi
else
  echo "   NO recovered capture found - nothing to read. Read records/1033-reading.txt (the frame this"
  echo "   rung's rows are about) and re-run the recovery once the phone is visible"
  echo "   ([[mi4-device-dark-needs-power-press]])"
fi

echo "== DONE =="
echo "   ADJUDICATE with $CHECKER on a capture NEWER than this boot (epoch $_BOOT_EPOCH)."
echo "   The pcc rows are the DEVICE's page words at pc; the evf rows beside them are the 1033 frame."
echo "   Do NOT pick a fix from this rung: it is the instrument."