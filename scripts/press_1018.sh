#!/usr/bin/env bash
# Press 1018: THE CAP-EXEMPT UNDEF WITNESS (STAGE90_XNU_UNDEF_DIRECT=1).  Design: docs/1018-design.md.
# Recon: records/1018-recon.txt (a7bafd7).
#
# THE ONE QUESTION THIS RUNG DECIDES.  1017 (`docs/1017-shared-cache-naming.md`) named, statically and
# by value, the instruction pid 1's frame sits on: un-slid VA 0x3823aa54 = libsystem_platform.dylib
# `__os_alloc_slow`+0x108 = the Thumb `udf #254` (bytes fede), reached ONLY when `_mach_vm_map` returns
# non-zero.  It then wrote `# UNMEASURED` for the mechanism: does the undefined-instruction handler
# RETURN and re-trap, or does an outer retry re-enter the failure path?
#
# The 1015b capture could not answer it - an INSTRUMENT defect, not a device one: `__wrap_sleh_undef`
# (`entry_trace.c:5537`) writes `entry_live_write`, CAPPED at 24576u (`entry_stubs.c:4254`).  The cap
# published `xnu_live_capped` at capture `:29963` and dropped every capped record after it, while the
# frontier sits ~4000 records later at `:33977`.  So `xnu_live_undef_seq` is ZERO there not because no
# udf happened but because the channel was exhausted first (records/1018-recon.txt).
#
# With this arm's switch the six undef keys ride `entry_write_kv` (the DIRECT channel), so their absence
# after `xnu_live_capped` means the udf did not happen - and their presence at a pc the stall sampler
# also reads answers the re-trap-vs-retry question by value.
#
# THE PRE-REGISTERED READING (frozen once embedded; deviations reported, not reinterpreted):
#   U-FIRES-DIES  - the udf fires at the frontier AND the run has a kill/exit marker  => the trap
#                   TERMINATED pid 1: the frontier is a CRASH, not a spin; next rung = exception delivery.
#   U-FIRES-LOOPS - the udf fires and the stall sampler's pc stays put (wedged)         => the handler
#                   RETURNS and RE-TRAPS (1017 §3.3 mechanism (i)) - the same shape as 1010-1015, now at
#                   a udf in USER mode.
#   U-FIRES-ONCE  - the udf fires at a sampled pc but the sampler then MOVES             => the trap is a
#                   TRANSITION; the wall is downstream, not here.
#   U-SILENT      - the witness is LIVE yet fires at NO pc the sampler reads            => 1017's static
#                   identification is CONTRADICTED (the honest falsification of docs/1018-design.md §3).
#   U-CTL         - the witness never fired AND no boot self-test row                   => INSTRUMENT_UNSOUND,
#                   WITHHOLD.  (The reader requires BOTH halves - the boot self-test row AND a `_seq`
#                   row - so a pre-arm capture whose witness is still capped WITHHOLDS, never U-SILENT.)
# Read it with: python3 -I tools/check_1018_capture.py <capture>
#
# Medium: 968 real iOS 7.1.2 HFSX rootfs over hfs_rmd0; CARD_COW=1, HDD_WRITE=0, the base is never
# written - fully reversible.  fastboot boot only, NEVER flash.
set -euo pipefail
cd "$(dirname "$0")/.."

LIVE=out/stage90
REC=$LIVE/xnu_arm_entry-config.txt

echo "== 0. the record must be 1018's arm =="
grep -q '^STAGE90_XNU_UNDEF_DIRECT=1$' "$REC" || {
  echo "REFUSING: the record does not carry STAGE90_XNU_UNDEF_DIRECT=1 - this is not 1018's arm (build it with scripts/build_1018.sh first)"; exit 1; }
# **GLOBAL_FIX IS NOT IN THE RECORD AND CANNOT BE** (press_1015b.sh (0g), MEASURED): it is a POOL switch
# (osfmk/arm/pmap.c:1357) that no writer in src/entry/ echoes, and preflight_boot_check.sh's
# ENTRY_CFG_KEYS is a set difference against the record, so naming it there would make the gate refuse
# every press. Its ONE declaration is the drop-in file park_1015b.sh wrote at the freeze point.
grep -qx 'STAGE90_XNU_GLOBAL_FIX=1 role=1015b-globalfix' "$LIVE/xnu_arm_entry-arm-extra.txt" || {
  echo "REFUSING: out/stage90/xnu_arm_entry-arm-extra.txt does not carry 'STAGE90_XNU_GLOBAL_FIX=1 role=1015b-globalfix' - the pool fix that keeps the retry storm gone is not declared, so the udf this arm's witness exists to name would never be reached"; exit 1; }
EXPECT_ARM=armed-d13-$(sha256sum "$LIVE/xnu_arm_entry.bin" | cut -c1-8)
echo "   arm = $EXPECT_ARM"

# BY VALUE (0a): the property the arm claims - `__wrap_sleh_undef` in the LINKED image branches to the
# DIRECT writer - re-read here so the press refuses an image whose wrapper the cap can still silence.
_ua=$(arm-none-eabi-nm "$LIVE/xnu_arm_entry.elf" | awk '$3=="__wrap_sleh_undef"{print "0x" $1; n++} END{exit(n==1?0:1)}') || {
  echo "REFUSING: __wrap_sleh_undef is not in the image - the undef witness is gone"; exit 1; }
_ub=$(arm-none-eabi-nm -n "$LIVE/xnu_arm_entry.elf" | awk -v s="${_ua#0x}" 'BEGIN{sv=strtonum("0x" s)}{a=strtonum("0x" $1)} a>sv{if(!d){print "0x" $1; d=1}}')
_ud=$(arm-none-eabi-objdump -d "$LIVE/xnu_arm_entry.elf" --start-address="$_ua" --stop-address="${_ub:-0xffffffff}")
_kv=$(grep -c '<entry_write_kv>' <<<"$_ud" || true)
_lw=$(grep -c '<entry_live_write>' <<<"$_ud" || true)
[[ $_kv -ge 6 && $_lw -eq 0 ]] || {
  echo "REFUSING: __wrap_sleh_undef ($_ua..$_ub) branches to entry_write_kv $_kv and entry_live_write $_lw - with this arm on it must be >=6 direct and 0 counted"; exit 1; }
echo "   (0a) by value: __wrap_sleh_undef ($_ua..$_ub) -> entry_write_kv x$_kv, entry_live_write x$_lw (DIRECT channel, cap-exempt)"

echo "== 1. the real iOS 7.1.2 rootfs as the card image (the COW base) =="
# [[mi4-one-value-two-definitions]]: `--real` COPIES the pristine rootfs over the card image, so a
# re-run of this press after 1032 would silently discard the 1032 guard (10 bytes at card 0x10183720)
# and the press would re-measure an earlier rung while every kernel gate stayed green.  Refuse a card
# that is already the 1032 patched one instead of overwriting the rung.
_guard=$(dd if=out/stage90/xnu_card_hfs.img bs=1 skip=$((16#10183720)) count=10 2>/dev/null | od -An -tx1 | tr -d ' \n')
[[ "$_guard" == "5010012801daf0bdc046" ]] && {
  echo "REFUSING: out/stage90/xnu_card_hfs.img carries the 1032 guard (5010012801daf0bdc046 at 0x10183720);"
  echo "  build_root_volumes.sh --real would OVERWRITE it with the pristine rootfs. Use the press that"
  echo "  matches the card, or revert the patch (tools/patch_cache_libobjc_count.py --revert) deliberately."; exit 1; }
tools/build_root_volumes.sh --real

echo "== 2. hardware gate =="
adb devices | grep -q 4a2fe00b || { echo "NO DEVICE - hold Power ~10-15s to boot it back, then re-run"; exit 1; }
fastboot devices | grep -q 33e80afe && { echo "33e80afe (the OTHER phone) is present - unplug it first (hardware gate)"; exit 1; }

echo "== 2b. write the card image to userdata's head (partition offset 0) =="
# STREAMED, not pushed (/data is a 512 MB tmpfs, not the userdata partition).
adb -s 4a2fe00b root || true; sleep 1
adb -s 4a2fe00b shell "dd of=/dev/block/mmcblk0p25 bs=1M conv=fsync" < out/stage90/xnu_card_hfs.img
echo "read-back (the card's first 8 MiB):"
adb -s 4a2fe00b shell "dd if=/dev/block/mmcblk0p25 bs=1M count=8 2>/dev/null" | sha256sum
echo "expected:"
head -c 8388608 out/stage90/xnu_card_hfs.img | sha256sum

echo "== 3. the press (gate + runner, fastboot boot only) =="
# 1018 is a RESIDENT rung: if it does not return it keeps NO /proc/last_kmsg of its own, so start the
# HOST reader FIRST; it attaches the moment the payload enumerates. Primary channel: step 4.
USB_OUT="out/stage90/captures/usb-console-1018-$(date -u +%Y%m%d-%H%M%S).txt"
tools/usb_console_read.py --out "$USB_OUT" --wait 600 --seconds 0 &
USB_PID=$!
echo "   (USB console reader armed: pid $USB_PID -> $USB_OUT)"
trap 'kill "$USB_PID" 2>/dev/null || true' EXIT

scripts/preflight_boot_check.sh --allow-xnu-entry
set +e
scripts/run_and_capture.sh --allow-xnu-entry --expect-arm="$EXPECT_ARM"
RUN_RC=$?
set -e
echo "   (runner exit $RUN_RC; a resident rung not returning shows as 2)"

kill "$USB_PID" 2>/dev/null || true
echo "== USB console capture: $USB_OUT =="
[ -s "$USB_OUT" ] && echo "   bytes read: $(wc -c < "$USB_OUT")" || echo "   (empty)"

echo "== 4. recovery: the run's own log via /proc/last_kmsg (carrier is the FLASHED ROM) =="
for _ in $(seq 1 90); do
  if adb devices 2>/dev/null | grep -q 4a2fe00b || fastboot devices 2>/dev/null | grep -q 4a2fe00b; then break; fi
  sleep 5
done
if adb devices 2>/dev/null | grep -q 4a2fe00b; then
  scripts/recover_last_kmsg.sh --read-only
elif fastboot devices 2>/dev/null | grep -q 4a2fe00b; then
  scripts/recover_last_kmsg.sh
else
  echo "   (device not visible yet; if still dark, the operator power-press is the next step, then:"
  echo "    scripts/recover_last_kmsg.sh --read-only while Android is up; do not boot anything else first)"
fi
echo "== DONE =="
echo "   adjudicate with: python3 -I tools/check_1018_capture.py <capture>"
echo "     U-FIRES-DIES  the trap TERMINATED pid 1 (frontier is a CRASH, next rung = exception delivery)"
echo "     U-FIRES-LOOPS the handler RETURNS and RE-TRAPS (1017 3.3 (i), the 1010-1015 shape at a udf)"
echo "     U-FIRES-ONCE  the trap is a TRANSITION (the wall is downstream)"
echo "     U-SILENT      1017's static id CONTRADICTED (the witness is live, the CPU does not trap here)"
echo "     U-CTL         WITHHOLD (the instrument did not run - check the cap FIRST)"
echo "   READ THE CAP BEFORE ANY CELL: if xnu_live_capped is present AND the last undef _seq is before it,"
echo "   the witness was silenced by the channel - that is U-CTL, never U-SILENT."