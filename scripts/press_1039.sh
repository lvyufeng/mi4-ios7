#!/usr/bin/env bash
# ====================================================================================================
# press_1039.sh.  MODELLED ON scripts/press_1038.sh (every inherited gate carried, the card gate kept
# because 1039 STILL serves 1032's card patch), with ONE change: the kernel arm is 1039's OWN
# (armed-d13-<sha8>), which adds the STAGE90_XNU_FRAME_CARRIER rows (xnu_live_fcr_*) on top of the
# re-staged 1037 fb rows and 1038's WATCH_LE arm.
#
# Press 1039: **IS THE SAVED USER CONTEXT THE ONE THE HARDWARE FAULTED WITH -- INSTRUMENT ONLY.**  No fix.
# records/1039-read.txt 2 pre-registers the cells (L0-L3, U1-U3, I3/I4, S1, E); tools/check_1039_capture.py
# decides them.
#
# SAFETY ([[mi4-hardware-run-safety-gate]]): fastboot boot ONLY, never flash; never TWRP; unplug 33e80afe
# first, target 4a2fe00b.  The body below self-scans for a fastboot partition-write command and refuses
# the whole script if one is present.  The previous run's RAM console is recovered BEFORE this boot
# overwrites the slot, or the press refuses.
# ====================================================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

# SAFETY, BY VALUE: this script boots, it never writes a partition.
_BODY=$(grep -v '^[[:space:]]*#' "$0")
if grep -qE '(^|[[:space:]])fastboot([[:space:]]+-[[:alnum:][:space:]-]+)*[[:space:]]+flash([[:space:]]|$)' <<<"$_BODY"; then
  echo "REFUSING: press_1039's body names a fastboot partition-write command - this script is fastboot boot ONLY"; exit 1; fi

LIVE=out/stage90
REC=$LIVE/xnu_arm_entry-config.txt
NEW=STAGE90_XNU_FRAME_CARRIER
OTHER=STAGE90_XNU_WATCH_LE
TF=STAGE90_XNU_TRAP_FRAME
TRAP_SRC=external/xnu-hd2-darwin13/xnu/osfmk/arm/trap.c
TRAP_OBJ=out/xnu_kernel_obj_d13/osfmk_arm_trap.o
EXEC_OBJ=out/xnu_kernel_obj_d13/bsd_kern_kern_exec.o
ELF=$LIVE/xnu_arm_entry.elf
CHECKER=tools/check_1039_capture.py
CARD=$LIVE/xnu_card_hfs.img
SITE_HEX=10183720
SITE_DEC=$((16#10183720))
NEW_HEX=5010012801daf0bdc046
# The previous boot epoch (the last real press: 1037, boot epoch 1792405372, records/1037-read.txt /
# the recovered capture of 10:22:52).  A constant invented here would be an unchecked claim
# ([[mi4-a-claim-in-a-comment-is-not-a-check]]); the anchor may be OVERRIDDEN but has to be given as a
# boot epoch >= 1037's.
LAST_PRESS_EPOCH=${STAGE90_1039_LAST_PRESS_EPOCH:-1792405372}

# BY VALUE (0-checker0): the checker can FAIL.  FIRST, before anything is decided.
[[ -f $CHECKER ]] || { echo "REFUSING: $CHECKER is absent - the capture this press produces would have no pinned reader"; exit 1; }
python3 -I "$CHECKER" --selftest >/dev/null 2>&1 || { echo "REFUSING: $CHECKER --selftest did NOT PASS - an inert checker would bless any capture"; exit 1; }
[[ "$LAST_PRESS_EPOCH" =~ ^[0-9]{9,}$ ]] && (( LAST_PRESS_EPOCH >= 1792405372 )) || {
  echo "REFUSING: STAGE90_1039_LAST_PRESS_EPOCH is [$LAST_PRESS_EPOCH], not a boot epoch >= 1037's 1792405372."
  echo "  Set it to the boot epoch of the most recent real press: STAGE90_1039_LAST_PRESS_EPOCH=<epoch> scripts/press_1039.sh"; exit 1; }

# ---- the mandate (same gates as park_1039.sh P1): the rung has not been withdrawn.
[[ -f records/1039-read.txt ]] || { echo "REFUSING: records/1039-read.txt is absent"; exit 1; }
[[ -f scripts/build_1039.sh ]] || { echo "REFUSING: scripts/build_1039.sh is absent"; exit 1; }

echo "== 0. the record and the image must be 1039's arm =="
grep -q "^$NEW=1\$" "$REC" || {
  echo "REFUSING: the record does not carry $NEW=1 - the fcr rows this rung IS are gated by THIS switch (tools/patch_d13_frame_carrier.py), and a record without it means the pool was built with the block SHUT ([[mi4-build-variant-comes-from-an-env-default]]). Build it with scripts/build_1039.sh first"; exit 1; }
if grep -q 'role=1039-frame-carrier' records/revert-set.txt 2>/dev/null; then
  _parked=$(grep 'role=1039-frame-carrier;' records/revert-set.txt | sed -n 's/^set=\([^ ]*\).*/\1/p' | LC_ALL=C sort -u | tr '\n' ' ')
  _nowbin=$(tools/resolve_arm_set.sh "$LIVE" 2>/dev/null | head -1 | cut -f1)
  [[ -z $_parked || " $_parked " == *" ${_nowbin:-NONE} "* ]] || { echo "REFUSING: records/revert-set.txt parks 1039 as [$_parked] but out/stage90 resolves to ${_nowbin:-NO RECORDED SET} - the live image is not a parked 1039 arm; park it first (scripts/park_1039.sh)"; exit 1; }
else
  echo "REFUSING: records/revert-set.txt parks NO 1039-frame-carrier set - park it first (scripts/park_1039.sh)"; exit 1
fi
# ($OTHER=WATCH_LE is 0 for this rung: 1038's ROW side is in the tree but keeps its switch undefined.)
for k in $TF STAGE90_XNU_PC_CARRIER_CALLER STAGE90_XNU_PC_CARRIER STAGE90_XNU_EVAL_FRAME STAGE90_XNU_CALLER_PROBE STAGE90_XNU_WRITER_PROBE STAGE90_XNU_READER_PROBE STAGE90_XNU_ABT_ENTRY_PROBE \
         STAGE90_XNU_USTACK_PROBE STAGE90_XNU_H2_STACK_HEADROOM STAGE90_XNU_VM_MAX_SPLIT STAGE90_XNU_IOS7_TRAPS \
         STAGE90_XNU_GENERAL_REGS STAGE90_XNU_UNDEF_RAISE; do
  grep -q "^$k=1\$" "$REC" || { echo "REFUSING: the record does not carry $k=1 - 1039 carries the 1037/1038 instrument verbatim. Build it with scripts/build_1039.sh first"; exit 1; }
done
EXPECT_ARM=$(tools/resolve_arm_set.sh "$LIVE" 2>/dev/null | head -1 | cut -f1)
[[ -n $EXPECT_ARM ]] || { echo "REFUSING: the bytes in $LIVE resolve to NO recorded set - park the arm first (scripts/park_1039.sh)"; exit 1; }
echo "   arm = $EXPECT_ARM (resolved from records/revert-set.txt)"

# BY VALUE (0): 1015b's GLOBAL-FIX is in the pool object this image was built from.
_gf_obj=out/xnu_kernel_obj_d13/osfmk_arm_pmap.o
_gf_kp=$(arm-none-eabi-objdump -r "$_gf_obj" 2>/dev/null | awk '$1>="00000418" && $1<="00000640"' | grep -c 'MOVW_ABS_NC.*kernel_pmap' || true)
[[ "$_gf_kp" == "3" ]] || {
  echo "REFUSING: pmap_flush_tlbs materializes kernel_pmap x$_gf_kp (want 3) - 1015b's GLOBAL-FIX is NOT in the pool object, the retry storm is BACK and the run would never reach the fault. Re-run scripts/build_1039.sh"; exit 1; }
echo "   (0) by value: pmap_flush_tlbs carries the GLOBAL-FIX ($_gf_kp kernel_pmap sites)"

# BY VALUE (0a-0): the pool's source record names the same trap.c the tree shows.
_src_rec=out/xnu_kernel_src_d13.sha256
[[ -f $TRAP_SRC && -f $_src_rec ]] || { echo "REFUSING: trap.c or the pool's source record is absent"; exit 1; }
_want=$(sha256sum "$TRAP_SRC" | awk '{print $1}')
_have=$(awk -v b="$TRAP_SRC" 'index($2,b)==length($2)-length(b)+1{print $1}' "$_src_rec" | head -1)
[[ -n "$_have" && "$_want" == "$_have" ]] || { echo "REFUSING: the pool's source record says [${_have:-none}] but the staged trap.c hashes $_want - the pool was NOT rebuilt from the probed source"; exit 1; }
echo "   (0a-0) by value: the pool's source record names the SAME trap.c sha ($_want)"

echo "   (0a) by value: trap.o and the LINKED image carry the reader's required rows"
for _n in $(python3 -I "$CHECKER" --required-rows); do
  grep -qa "^${_n}" <(strings "$TRAP_OBJ") || { echo "REFUSING: $TRAP_OBJ carries no ${_n} - the pool was not recompiled with $NEW=1"; exit 1; }
  grep -qa "^${_n}" <(strings "$ELF") || { echo "REFUSING: the LINKED image carries no ${_n} - the linker dropped the probed object"; exit 1; }
done

# BY VALUE (0a-1): the parent rows the fcr rows are read BESIDE survive in the pool object and the image.
# (`xnu_live_sweq_seq=`, `ler_cnt_b=` and `wlg_byte=` are NOT here: they are 1038's, gated on a switch
#  this record sets to 0, and they are checked below only when it is 1.)
for s in xnu_live_fb_seq= xnu_live_fb_ctx_diff= xnu_live_fb_ldrh= \
         xnu_live_pcc2_seq= xnu_live_pcc_pc= xnu_live_pcc_xor_walk= xnu_live_evf_pc= \
         xnu_live_evf_far_raw= xnu_live_cal_region_end= xnu_live_wrp_r4= xnu_live_rdr_far= \
         xnu_live_abt_lookup_far= xnu_live_abt_vmfkrv=; do
  grep -qa "^$s" <(strings "$TRAP_OBJ") || { echo "REFUSING: $TRAP_OBJ lost $s in the rebuild - a parent row is gone ([[mi4-one-file-many-rungs]])"; exit 1; }
  grep -qa "^$s" <(strings "$ELF") || { echo "REFUSING: the LINKED image lost $s - the linker dropped a parent row"; exit 1; }
done
if grep -q '^STAGE90_XNU_WATCH_LE=1$' "$REC" 2>/dev/null; then
  for s in xnu_live_sweq_seq= xnu_live_ler_cnt_b= xnu_live_wlg_byte=; do
    grep -qa "^$s" <(strings "$TRAP_OBJ") || { echo "REFUSING: $TRAP_OBJ lost $s - a 1038 parent row is gone"; exit 1; }
    grep -qa "^$s" <(strings "$ELF") || { echo "REFUSING: the LINKED image lost $s"; exit 1; }
  done
else
  echo "   (1038's parent rows: STAGE90_XNU_WATCH_LE=0 - the arm compiles out, as that rung intends)"
fi
grep -qa '^xnu_live_abt_proc_ustack$' <(strings "$EXEC_OBJ") || { echo "REFUSING: $EXEC_OBJ carries no xnu_live_abt_proc_ustack"; exit 1; }
echo "   (0a-1) by value: trap.o and the image keep fb (re-staged 1037), sweq/ler/wlg (1038), pcc2 (1036), pcc (1035) and the evf/cal/wrp/rdr/abt publishers"

# BY VALUE (0a-checker): the readers this rung is read beside can still FAIL.
for _c in check_1037_capture.py check_1038_capture.py check_1036_capture.py check_1035_capture.py check_1033_capture.py; do
  python3 -I "tools/$_c" --selftest >/dev/null 2>&1 || { echo "REFUSING: tools/$_c --selftest did NOT PASS"; exit 1; }
done
python3 -I tools/check_vm_max_split.py "$ELF" --expect on >/dev/null 2>&1 || { echo "REFUSING: the LINKED image's task map ceiling moved (1024)"; exit 1; }
python3 -I tools/check_d13_no_neon.py "$ELF" --symbol mach_msg_send --expect none >/dev/null 2>&1 || { echo "REFUSING: mach_msg_send is not NEON-free (1021d)"; exit 1; }
python3 -I tools/check_d13_undef_raise.py "$ELF" --expect on >/dev/null 2>&1 || { echo "REFUSING: sleh_undef lost 1020's raise"; exit 1; }
python3 -I tools/check_1023_trap24.py "$ELF" --expect on >/dev/null 2>&1 || { echo "REFUSING: mach_trap_table[24] moved (1023)"; exit 1; }
echo "   (0a-checker) by value: 1033-1038 selftests PASS; 1024 ceiling / 1021d NEON-free / 1020 raise / 1023 row 24 all PASS on the linked image"

# BY VALUE (0g): THE CARD STILL CARRIES 1032'S GUARD.
_cp=tools/patch_cache_libobjc_count.py
python3 -I "$_cp" --selftest >/dev/null 2>&1 || { echo "REFUSING: $_cp --selftest failed"; exit 1; }
[[ -f $CARD ]] || { echo "REFUSING: $CARD is absent - run scripts/build_1039.sh"; exit 1; }
_got=$(dd if="$CARD" bs=1 skip=$SITE_DEC count=10 2>/dev/null | od -An -tx1 | tr -d ' \n')
[[ "$_got" == "$NEW_HEX" ]] || { echo "REFUSING: $CARD offset 0x$SITE_HEX holds $_got, not 1032's guard $NEW_HEX - this press would read a boot WITHOUT the clamp. Run scripts/build_1039.sh"; exit 1; }
python3 -I "$_cp" --check >/dev/null 2>&1 || { echo "REFUSING: $_cp --check FAILED - the card's cache header or the content anchor differs"; exit 1; }
_rs=${STAGE90_REAL_ROOTFS:-/mnt/data/ios7-payload/v2/ios7/rootfs.hfs}
_n=$(cmp -l "$CARD" "$_rs" 2>/dev/null | wc -l || true)
[[ "$_n" == "10" ]] || { echo "REFUSING: the card differs from the pristine rootfs in $_n bytes (want EXACTLY 10)"; exit 1; }
echo "   (0g) by value: the card carries 1032's 10-byte guard, differs from the rootfs in exactly those 10 bytes, and --check PASSes"

echo "== 1. the card image (built+patched by scripts/build_1039.sh -- NOT rebuilt here) =="
echo "   $CARD  $(sha256sum "$CARD" | cut -c1-16)..."

echo "== 2. hardware gate =="
# **Either mode is a device.** `fastboot boot` is what this script does; adb is only how a PREVIOUS
# run's RAM console is read. A phone already sitting in fastboot - which is where the press needs it -
# was refused with "NO DEVICE - hold Power ~10-15s".
if adb devices | grep -q 4a2fe00b; then
  echo "   device 4a2fe00b: adb"
elif fastboot devices | grep -q 4a2fe00b; then
  echo "   device 4a2fe00b: fastboot (boot from here)"
else
  echo "NO DEVICE - connect 4a2fe00b, or hold Power ~10-15s to boot it back, then re-run"; exit 1
fi
fastboot devices | grep -q 33e80afe && { echo "33e80afe (the OTHER phone) is present - unplug it first (hardware gate)"; exit 1; }

# ORDER: a PREVIOUS run's RAM console is recovered BEFORE this boot overwrites the slot
# ([[mi4-last-kmsg-reader-carrier]]: `fastboot boot` burns the single-slot record).
echo "== 2a. recover a PREVIOUS run's RAM console before anything overwrites it =="
_prev=$(ls -1t out/stage90/captures/recovered-*-last_kmsg.txt 2>/dev/null | head -1 || true)
_prev_ok=0
if [[ -n $_prev ]]; then
  _prev_ep=$(stat -c %Y "$_prev")
  # This kernel prints no in-log wall stamp; the capture's MTIME is when recover_last_kmsg.sh read the
  # boot's last_kmsg, which is >= the boot epoch.  The `-YYYYMMDD-HHMMSS-` name stamp is only a label.
  echo "   previous capture: $_prev (mtime epoch $_prev_ep = when recovered; last press's boot $LAST_PRESS_EPOCH)"
  if [[ $_prev_ep -ge $LAST_PRESS_EPOCH ]]; then
    _prev_ok=1
    echo "   (previous run's console is RECOVERED: mtime $_prev_ep >= the last press's boot epoch $LAST_PRESS_EPOCH)"
  fi
else
  echo "   (no recovered capture on the host)"
fi
if [[ $_prev_ok != 1 ]]; then
  if [[ ${STAGE90_1039_OVERWRITE_PREV:-0} == 1 ]]; then
    echo "   STAGE90_1039_OVERWRITE_PREV=1: proceeding although the previous run's console is not confirmed recovered."
  else
    echo "REFUSING: the previous run's RAM console is NOT confirmed recovered on the host, and the boot below"
    echo "  would overwrite the slot it exists in.  Recover it first (scripts/recover_last_kmsg.sh --read-only"
    echo "  while Android is up), or -- only if it is already adjudicated and kept in records/ -- re-run with"
    echo "  STAGE90_1039_OVERWRITE_PREV=1.  NOT booting."
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
USB_OUT="out/stage90/captures/usb-console-1039-$(date -u +%Y%m%d-%H%M%S).txt"
tools/usb_console_read.py --out "$USB_OUT" --wait 600 --seconds 0 &
USB_PID=$!
echo "   (USB console reader armed: pid $USB_PID -> $USB_OUT)"
trap 'kill "$USB_PID" 2>/dev/null || true' EXIT

scripts/preflight_boot_check.sh --allow-xnu-entry
echo "   fastboot boot -s 4a2fe00b out/stage90/stage90-qcdt.img   (fastboot boot, NEVER flash)"
_BOOT_EPOCH=$(date +%s)
echo "   _BOOT_EPOCH=$_BOOT_EPOCH"
set +e
scripts/run_and_capture.sh --allow-xnu-entry --expect-arm="$EXPECT_ARM" "$@"
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

echo "== 5. read the recovered capture: run the 1039 reader and print its cells =="
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
    python3 -I "$CHECKER" "$_last" --after "$_BOOT_EPOCH"
    _rd_rc=$?
    set -e
    echo "   (reader exit $_rd_rc; 0 = a cell, 1 = no cell, 2 = STALE SLOT; see records/1039-read.txt 2)"
  fi
else
  echo "   NO recovered capture found - nothing to read. Re-run the recovery once the phone is visible"
  echo "   ([[mi4-device-dark-needs-power-press]])"
fi

echo "== DONE =="
echo "   ADJUDICATE with $CHECKER on a capture NEWER than this boot (epoch $_BOOT_EPOCH)."
echo "   L = which saved register is odd; U = the record vs arm_ctx; I = continuation; S = spsr."
echo "   Do NOT pick a fix from this rung: it is the instrument."