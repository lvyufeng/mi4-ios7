#!/usr/bin/env bash
# ====================================================================================================
# press_1023.sh.  MODELLED ON scripts/press_1022.sh (itself the RESIDENT-rung press: the USB console
# reader + the /proc/last_kmsg recovery).
#
# Press 1023: INSTALL THE mach trap-24 ROW (mach_port_construct) so libxpc's port allocation stops
# faulting.  Switch: **none new** - the widened row-24 gate reads STAGE90_XNU_IOS7_TRAPS, ALREADY 1 in
# the record; the externs and the inner gate were already widened by 1022.  Design:
# docs/1023-port-construct-trap24-design.md.
#
# THE ONE QUESTION THIS RUNG DECIDES.  The 1022 press read T15-FIRES (records/1022-press-read.txt PART
# 5): the trap-15 row IS installed, `mach_vm_map` IS called 7 times and returns `result=0` every time,
# and the udf wall 1021d stopped on is GONE.  The frontier moved one frame out: pid 1's libxpc
# port-allocation wrapper does `udf #254` at file VA `0x3824e022` because `mach_trap_table[24]` is
# `kern_invalid` on CANCRO, so the trap-24 shim (`0x381c66ec`, reached through the dyld veneer slot at
# `0x39f45174`) never sees the `0x10000003` it needs and the wrapper's `cbz/cmp #3/cmpne #6` chain
# falls through to the udf.  With row 24 installed AND the body's selector reading `ios7_traps_enabled()`
# instead of the compile-time-0 `ios7_compat_vmabi_enabled()`, does `__xpc_mach_port_allocate` get past
# its port-construct, i.e. does the row get used, does the adapter's view of the 5-word frame match the
# frame the shim sent, and does libxpc's allocator stop failing?
#
# THE PRE-REGISTERED CELLS (docs/1023-port-construct-trap24-design.md section 7):
#   G-CTL          - neither `xnu_live_undef_seq` nor any `IOS7LAB trap24 frame` line  => WITHHOLD
#   T24-FIRES      - `IOS7LAB trap24 frame …` present AND pid 1 proceeds past libxpc's port allocation
#                    (no udf at 0x3824e022's slide-corrected pc)                          => WALL MOVED
#   T24-REFUSED    - the frame line appears, the body returns non-zero, and the boot proceeds
#                                                                                       => ROW USED,
#                    THE WIRE IS REFUSED
#   T24-SENTINEL   - the run fails as before with NO frame line, or the frame line appears and the udf
#                    recurs at the same pc                                    => ROW INSTALLED,
#                    SELECTOR STILL 0 (edit 2 did not land)
#   T24-BADFRAME   - the frame line appears and the run faults INSIDE the handler (a bad `regs[1]`
#                    pointer: the `copyin` of 24 option bytes refuses)                   => WIRE MISMATCH
#   T24-PANICS     - a `swi_mach_error`-shaped panic                                     => STALE POOL
#   T24-DEFERRAL-BROKEN - the checker's read of rows 25/41/42 fails                     => COMPOSITION
#
# **THIS PRESS IS NOT TO READ A LOG.**  A `fastboot boot` spent to look at a log has no question behind
# it: this rung's question is the one above, and the arm must be the one the by-value gates below
# certify.  The recovery step reads `/proc/last_kmsg` only because the run's own log is the reading of
# the question ([[mi4-last-kmsg-reader-carrier]]: the carrier is the FLASHED ROM).
#
# Medium: 968 real iOS 7.1.2 HFSX rootfs over hfs_rmd0; CARD_COW=1, HDD_WRITE=0, the base is never
# written - fully reversible.  fastboot boot only, NEVER flash.
# ====================================================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

LIVE=out/stage90
REC=$LIVE/xnu_arm_entry-config.txt

echo "== 0. the record must be 1023's arm =="
# 1023's row-24 gate reads STAGE90_XNU_IOS7_TRAPS; it is ALSO the readability carrier (a record without
# it means the pool was built without -DSTAGE90_XNU_IOS7_TRAPS=1, so row 24 stays kern_invalid).
grep -q '^STAGE90_XNU_IOS7_TRAPS=1$' "$REC" || {
  echo "REFUSING: the record does not carry STAGE90_XNU_IOS7_TRAPS=1 - 1023's row-24 gate widens to read THIS switch. Its absence means the pool was built without -DSTAGE90_XNU_IOS7_TRAPS=1, so row 24 stays kern_invalid and libxpc's port-allocation udf recurs (build it with scripts/build_1023.sh first)"; exit 1; }
# The inherited switches this arm's set carries VERBATIM (1021d's set).
grep -q '^STAGE90_XNU_GENERAL_REGS=1$' "$REC" || {
  echo "REFUSING: the record does not carry STAGE90_XNU_GENERAL_REGS=1 - 1021d's -msoft-float flag must stay on, or the kernel-mode NEON undef at 0x8047b0ac returns and this rung would measure a different frontier"; exit 1; }
grep -q '^STAGE90_XNU_UNDEF_RAISE=1$' "$REC" || {
  echo "REFUSING: the record does not carry STAGE90_XNU_UNDEF_RAISE=1 - 1020's raise fix must stay on, or pid 1's genuine udf loops forever again (8183x measured) and 1023 would measure a different frontier"; exit 1; }
grep -q '^STAGE90_XNU_UNDEF_DIRECT=1$' "$REC" || {
  echo "REFUSING: the record does not carry STAGE90_XNU_UNDEF_DIRECT=1 - without the direct channel the udf witness can be silenced by the cap before the frontier (the 1017/1018 instrument defect)"; exit 1; }
# GLOBAL_FIX is a POOL switch declared only in the arm-extra drop-in (records/1020-build-defect.txt); it
# cannot be in the record.  **THE GREP BELOW IS THE PROCESS CHECK, NOT THE PROOF** - the by-value
# fingerprint below is what certifies the fix is in the pool object
# ([[mi4-self-written-record-is-not-a-constraint]]).
grep -qx 'STAGE90_XNU_GLOBAL_FIX=1 role=1023-trap24' "$LIVE/xnu_arm_entry-arm-extra.txt" || {
  echo "REFUSING: out/stage90/xnu_arm_entry-arm-extra.txt does not carry 'STAGE90_XNU_GLOBAL_FIX=1 role=1023-trap24' (it holds: '$(cat "$LIVE/xnu_arm_entry-arm-extra.txt" 2>/dev/null)') - the pool fix that keeps the retry storm gone is not declared by THIS build (build_1023.sh writes this line at its tail)"; exit 1; }
EXPECT_ARM=armed-d13-$(sha256sum "$LIVE/xnu_arm_entry.bin" | cut -c1-8)
echo "   arm = $EXPECT_ARM"

# BY VALUE (0-POOL): the inherited GLOBAL-FIX (1015b) is in the pool object the linked image was built
# from - `pmap_flush_tlbs` materializes `kernel_pmap` EXACTLY 3 times (OFF/Apple = 2).  1023 rebuilds the
# pool (syscall_sw.c + mach_kernelrpc.c), so the 1020 defect (a record-derived EXTRA dropping the
# GLOBAL_FIX token) is available again.
_gf_obj=out/xnu_kernel_obj_d13/osfmk_arm_pmap.o
[[ -f "$_gf_obj" ]] || { echo "REFUSING: $_gf_obj is absent - 1015b's GLOBAL-FIX cannot be certified"; exit 1; }
_gf_kp=$(arm-none-eabi-objdump -r "$_gf_obj" 2>/dev/null | awk '$1>="00000418" && $1<="00000640"' | grep -c 'MOVW_ABS_NC.*kernel_pmap' || true)
_gf_full=$(arm-none-eabi-objdump -r "$_gf_obj" 2>/dev/null | awk '$1>="00000418" && $1<="00000640"' | grep -c 'R_ARM_CALL.*arm_tlb_flushID$' || true)
_gf_asid=$(arm-none-eabi-objdump -r "$_gf_obj" 2>/dev/null | awk '$1>="00000418" && $1<="00000640"' | grep -c 'R_ARM_CALL.*arm_tlb_flushID_ASID$' || true)
[[ "$_gf_kp" == "3" && "$_gf_full" == "1" && "$_gf_asid" == "1" ]] || {
  echo "REFUSING: pmap_flush_tlbs materializes kernel_pmap x$_gf_kp (want 3), arm_tlb_flushID x$_gf_full / arm_tlb_flushID_ASID x$_gf_asid (want 1/1) - GLOBAL-FIX is NOT in the pool object, so the retry storm 1015b killed is BACK and the run would never reach libxpc's port-allocation udf this rung exists to retire. Re-run scripts/build_1023.sh."; exit 1; }
echo "   (0-POOL) by value: pmap_flush_tlbs carries the 3rd kernel_pmap materialization ($_gf_kp sites) and the 1/1 flush arms - 1015b's GLOBAL-FIX IS in the pool object this image was built from"

# BY VALUE (0a): THE RUNG'S OWN CLAIM.  `tools/check_1023_trap24.py` reads `mach_trap_table` BY VALUE
# and asserts row 24 is {arg_count=5; fn=&ios7lab_mach_port_construct_trap;
# name="ios7lab_mach_port_construct_trap"} AND that rows 25/41/42 still read kern_invalid,
# with BOTH symbols PRESENT.  Read on the LINKED image, because build_entry.sh only LINKS the pool
# objects (a stale object hides the row; records/1020-build-defect.txt).
#
# **THE CHECKER IS REQUIRED.**  Its absence means the arm's own claim cannot be certified
# ([[mi4-a-claim-in-a-comment-is-not-a-check]]).
[[ -f tools/check_1023_trap24.py ]] || {
  echo "REFUSING: tools/check_1023_trap24.py is ABSENT - it is this press's by-value claim on the linked image's row 24, and there is no sound fallback. A press that skipped it would spend the device on an arm whose 'row installed' claim nothing ever checked"; exit 1; }

# 0a-0. the checker's OWN self-test - a checker that cannot fail is not a check.
python3 -I tools/check_1023_trap24.py --selftest >/dev/null 2>&1 || {
  echo "REFUSING: tools/check_1023_trap24.py --selftest did NOT PASS - the checker cannot certify anything (an inert checker would bless any image)"; exit 1; }
echo "   (0a-0) by value: tools/check_1023_trap24.py --selftest PASSes (the checker is live)"

# 0a-1. THE RUNG'S OWN CLAIM, on the LINKED image.
python3 -I tools/check_1023_trap24.py "$LIVE/xnu_arm_entry.elf" --expect on >/dev/null 2>&1 || {
  echo "REFUSING: the LINKED image's mach_trap_table[24] is NOT the ios7lab_mach_port_construct_trap row (arg_count=5, rows 25/41/42 still kern_invalid) - the widened gate did not reach osfmk_kern_syscall_sw.o, or a STALE pool object was linked (build_entry.sh only LINKS it, so a green entry build says nothing about this half). Re-run scripts/build_1023.sh"; exit 1; }
echo "   (0a-1) by value: the LINKED image's mach_trap_table[24] IS the ios7lab_mach_port_construct_trap row (arg_count=5, handler + name present, rows 25/41/42 still kern_invalid)"

# 0a-2. THE DISCRIMINATING CONTROL.  The SAME checker, `--expect off`, on the FROZEN PRE-RUNG arm (1022,
# b47131c8), whose row 24 IS kern_invalid (1022 opened row 15 ONLY).
# The pair (pre-rung -> off PASS, this arm -> on PASS) proves the checker DISCRIMINATES
# ([[mi4-a-claim-in-a-comment-is-not-a-check]]).
_ctrl=$LIVE/frozen/armed-d13-b47131c8/xnu_arm_entry.elf
[[ -s $_ctrl ]] || { echo "REFUSING: the frozen 1022 elf ($_ctrl) is absent - the NEGATIVE CONTROL for this press's by-value clause cannot be taken, so the clause above cannot be shown to DISCRIMINATE. 1022's park must exist before 1023's"; exit 1; }
python3 -I tools/check_1023_trap24.py "$_ctrl" --expect off >/dev/null 2>&1 || {
  echo "REFUSING: the frozen 1022 elf's row 24 does NOT read kern_invalid in the --expect off direction - the checker is either broken or pointed at the wrong row, so the 'on' PASS above certifies nothing. A control that agrees with the test proves only that the checker says one thing"; exit 1; }
echo "   (0a-2) by value: NEGATIVE CONTROL - the frozen 1022 elf (b47131c8) reads row 24 == kern_invalid (--expect off PASSes), so the 'on' above is a reading and not a constant"

# BY VALUE (0b): the inherited 1021d NEON-free claim still holds on the LINKED image - 1023 rebuilds the
# pool, so the -msoft-float flag must still reach it.
[[ -f tools/check_d13_no_neon.py ]] || { echo "REFUSING: tools/check_d13_no_neon.py is ABSENT - the inherited 1021d claim's by-value check"; exit 1; }
python3 -I tools/check_d13_no_neon.py --selftest >/dev/null 2>&1 || { echo "REFUSING: tools/check_d13_no_neon.py --selftest did NOT PASS"; exit 1; }
python3 -I tools/check_d13_no_neon.py "$LIVE/xnu_arm_entry.elf" --symbol mach_msg_send --expect none >/dev/null 2>&1 || {
  echo "REFUSING: the LINKED image's mach_msg_send still contains FP/NEON instructions - 1021d's -msoft-float flag did not reach the object the linker saw, or a STALE pool object was linked. Re-run scripts/build_1023.sh"; exit 1; }
echo "   (0b) by value: the LINKED image's mach_msg_send is NEON-free (1021d's -msoft-float holds)"

# BY VALUE (0c): the inherited 1020 raise claim still holds on the LINKED image.
[[ -f tools/check_d13_undef_raise.py ]] || { echo "REFUSING: tools/check_d13_undef_raise.py is ABSENT"; exit 1; }
python3 -I tools/check_d13_undef_raise.py "$LIVE/xnu_arm_entry.elf" --expect on >/dev/null 2>&1 || {
  echo "REFUSING: tools/check_d13_undef_raise.py \"$LIVE/xnu_arm_entry.elf\" --expect on did NOT pass - the linked image's sleh_undef does not carry 1020's moved \`return\`, so the udf loop is back. Re-run scripts/build_1023.sh"; exit 1; }
echo "   (0c) by value: tools/check_d13_undef_raise.py --expect on PASSes (1020's raise is intact)"

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
# THE HARDWARE SAFETY PROPERTIES ([[mi4-hardware-run-safety-gate]]), checked before anything is sent.
adb devices | grep -q 4a2fe00b || { echo "NO DEVICE - hold Power ~10-15s to boot it back, then re-run"; exit 1; }
fastboot devices | grep -q 33e80afe && { echo "33e80afe (the OTHER phone) is present - unplug it first (hardware gate)"; exit 1; }

echo "== 2b. write the card image to userdata's head (partition offset 0) =="
# STREAMED, not pushed (/data is a 512 MB tmpfs, not the userdata partition).  This is userdata's HEAD,
# outside the boot chain; CARD_COW=1 / HDD_WRITE=0, so the base is never written - fully reversible.
adb -s 4a2fe00b root || true; sleep 1
adb -s 4a2fe00b shell "dd of=/dev/block/mmcblk0p25 bs=1M conv=fsync" < out/stage90/xnu_card_hfs.img
echo "read-back (the card's first 8 MiB):"
adb -s 4a2fe00b shell "dd if=/dev/block/mmcblk0p25 bs=1M count=8 2>/dev/null" | sha256sum
echo "expected:"
head -c 8388608 out/stage90/xnu_card_hfs.img | sha256sum

echo "== 3. the press (gate + runner, fastboot boot only) =="
# 1023 is a RESIDENT rung: if it does not return it keeps NO /proc/last_kmsg of its own, so start the
# HOST reader FIRST; it attaches the moment the payload enumerates. Primary channel: step 4.
USB_OUT="out/stage90/captures/usb-console-1023-$(date -u +%Y%m%d-%H%M%S).txt"
tools/usb_console_read.py --out "$USB_OUT" --wait 600 --seconds 0 &
USB_PID=$!
echo "   (USB console reader armed: pid $USB_PID -> $USB_OUT)"
trap 'kill "$USB_PID" 2>/dev/null || true' EXIT

scripts/preflight_boot_check.sh --allow-xnu-entry
# **THE COMMAND LINE, PRINTED BEFORE IT IS ISSUED.** The SINGLE device write this press makes is
# `fastboot boot` of the payload - never `fastboot flash`.
    echo "   fastboot boot -s 4a2fe00b out/stage90/stage90-qcdt.img   (fastboot boot, NEVER flash)"
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
echo "   adjudicate against docs/1023-port-construct-trap24-design.md section 7:"
echo "     G-CTL          neither xnu_live_undef_seq nor any IOS7LAB trap24 frame line anywhere => WITHHOLD"
echo "     T24-FIRES      IOS7LAB trap24 frame present AND pid 1 proceeds past libxpc's port allocation"
echo "                    (no udf at 0x3824e022's slide-corrected pc) => ROW INSTALLED, USED, AND"
echo "                    SUCCESSFUL; the wall moved"
echo "     T24-REFUSED    the frame line appears, the body returns non-zero, and the boot proceeds =>"
echo "                    ROW USED, THE WIRE IS REFUSED (read the printed frame words)"
echo "     T24-SENTINEL   the run fails as before with NO frame line, or the frame line appears and the"
echo "                    udf recurs at the same pc => REGRESSION (row installed, selector still 0 -"
echo "                    edit 2 did not land)"
echo "     T24-BADFRAME   the frame line appears and the run faults INSIDE the handler (a bad regs[1]"
echo "                    pointer: the copyin of 24 option bytes refuses) => WIRE MISMATCH"
echo "     T24-PANICS     a swi_mach_error-shaped panic => STALE POOL, not a behaviour reading"
echo "     T24-DEFERRAL-BROKEN the checker's read of rows 25/41/42 fails => COMPOSITION"
echo "   Machine check: python3 -I tools/check_1023_capture.py <capture> --baseline <1022 capture>"
echo "   Read the 1022 reading beside it: records/1022-press-read.txt (T15-FIRES; the frontier this"
echo "   rung exists to retire).  The udf witness rides the DIRECT channel (UNDEF_DIRECT)."