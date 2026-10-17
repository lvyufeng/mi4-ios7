#!/usr/bin/env bash
# ====================================================================================================
# press_1024.sh.  MODELLED ON scripts/press_1023.sh (itself the RESIDENT-rung press: the USB console
# reader + the /proc/last_kmsg recovery).
#
# Press 1024: MAKE THE TASK MAP'S CEILING AGREE WITH THE HARDWARE SPLIT - VM_MAX_ADDRESS 0x80000000 ->
# 0x40000000.  Switch: **ONE NEW: STAGE90_XNU_VM_MAX_SPLIT=1** (1023's set VERBATIM otherwise).
# Design: docs/1024-design.md.
#
# THE ONE QUESTION THIS RUNG DECIDES.  The 1023 press read T24-FIRES (records/1023-press-read.txt):
# trap 24 IS dispatched (`IOS7LAB trap24 frame` x4), `mach_port_construct` returns `result=0` x4, and
# the udf wall 1022/1021d stopped on is GONE - but the frontier moved one frame out, into a
# ~2^20-iteration DATA-ABORT loop in pid 1 at user VA `0x40083008`: `abt_pc` = `0x39ded790 - slide
# 0x01bac000` = `0x38241790` = `libsystem_pthread.dylib + 0x2790` = `_pthread_create+0xbc`, the
# instruction `ldr r0,[r5,#8]` with `r5 = 0x40083000` (out-param 1 of `__pthread_allocate_stack`),
# `abt_ptel2 = 0` (the walk finds an empty L2 slot).  BY VALUE the two definitions of "the split"
# disagree: `set_mmu_ttbcr(2)` (`osfmk/arm/arm_vm_init.c:475`) gives TTBR0 exactly 1 GiB -
# `[0, 0x40000000)` - while `task_create_internal` links
# `vm_map_create(pmap, 0, VM_MAX_ADDRESS, TRUE, ...)` with **VM_MAX_ADDRESS = 0x80000000** (MEASURED
# at 80085cf0 `mov r2,#-2147483648` before 80085cfc `bl vm_map_create` in the armed 1023 image),
# because `vm_param.h:62-68` compiles the `#else` branch on CANCRO.  So the first big
# anywhere-allocation (the pthread stack) is placed ABOVE the split, where the hardware walks TTBR1
# (the kernel's tree) and finds nothing; `vm_fault` "succeeds" for ever.  With the task map's ceiling
# at 0x40000000 - the hardware's own split - does pid 1 get a pthread stack the hardware can walk,
# i.e. does the ±-storm vanish and the boot proceed, and where does the frontier land then?
#
# THE PRE-REGISTERED CELLS (docs/1024-design.md section 4; read by tools/check_1024_capture.py):
#   G-CTL          - neither the live channel nor any IOS7LAB line is live (no panic/stop either)
#                                                                                      => WITHHOLD
#   STORM-GONE     - the 1023 storm signature (abt_pc at slide-corrected 0x38241790 / abt_far
#                    0x40083008) is ABSENT AND the prior rungs' POSITIVE controls still hold in the
#                    SAME capture (trap24 frame x4, port_construct result=0 x4, xnu_live_undef_seq =
#                    0x, zero panics)                                     => WALL MOVED (the frontier
#                    moved; the checker reports the NEW frontier)
#   STORM-PERSISTS - the storm recurs at 1023's pc/far at scale => the patch did NOT reach the
#                    compiled image; read `check_vm_max_split.py <elf> --expect on` before anything
#   STORM-MOVED    - a storm exists elsewhere; ANY abt_far >= 0x40000000 means the map was not the
#                    only producer (1024-W's (U) registry names the culprit)
#   PRIOR-RUNGS-REGRESSED - one of the prior rungs' controls regressed => the arm's switch set is
#                    wrong, not the fix
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

echo "== 0. the record must be 1024's arm =="
# 1024's own new switch: the widened vm_param.h:63 line reads STAGE90_XNU_VM_MAX_SPLIT, and it is ALSO
# the readability carrier (a record without it means the pool was built with the OLD ceiling, so the
# task map still reaches 0x80000000 while the hardware walks TTBR1 above 0x40000000 and 1023's storm
# recurs).
grep -q '^STAGE90_XNU_VM_MAX_SPLIT=1$' "$REC" || {
  echo "REFUSING: the record does not carry STAGE90_XNU_VM_MAX_SPLIT=1 - 1024's widened vm_param.h:63 line reads THIS switch. Its absence means the pool was built with the OLD ceiling (0x80000000), so the task map still reaches above the hardware's 1 GiB TTBR0 split and the 1023 storm recurs - this press would not be a reading of THIS rung. Build it with scripts/build_1024.sh first"; exit 1; }
# 1023's row-24 gate reads STAGE90_XNU_IOS7_TRAPS; 1024 MOVES THE CEILING AND ADDS NOTHING ELSE, so
# trap 24 must still be installed or the 1023 frontier (libxpc's port-allocation udf) is back.
grep -q '^STAGE90_XNU_IOS7_TRAPS=1$' "$REC" || {
  echo "REFUSING: the record does not carry STAGE90_XNU_IOS7_TRAPS=1 - 1023's row-24 gate widens to read THIS switch. Its absence means the pool was built without -DSTAGE90_XNU_IOS7_TRAPS=1, so row 24 stays kern_invalid, libxpc's port-allocation udf recurs, and this rung would measure the 1023 frontier instead of pid 1's pthread-create fault it exists to move (build it with scripts/build_1024.sh first)"; exit 1; }
# The inherited switches this arm's set carries VERBATIM (1021d's set).
grep -q '^STAGE90_XNU_GENERAL_REGS=1$' "$REC" || {
  echo "REFUSING: the record does not carry STAGE90_XNU_GENERAL_REGS=1 - 1021d's -msoft-float flag must stay on, or the kernel-mode NEON undef at 0x8047b0ac returns and this rung would measure a different frontier"; exit 1; }
grep -q '^STAGE90_XNU_UNDEF_RAISE=1$' "$REC" || {
  echo "REFUSING: the record does not carry STAGE90_XNU_UNDEF_RAISE=1 - 1020's raise fix must stay on, or pid 1's genuine udf loops forever again (8183x measured) and 1024 would measure a different frontier"; exit 1; }
grep -q '^STAGE90_XNU_UNDEF_DIRECT=1$' "$REC" || {
  echo "REFUSING: the record does not carry STAGE90_XNU_UNDEF_DIRECT=1 - without the direct channel the udf witness can be silenced by the cap before the frontier (the 1017/1018 instrument defect)"; exit 1; }
# GLOBAL_FIX is a POOL switch declared only in the arm-extra drop-in (records/1020-build-defect.txt); it
# cannot be in the record.  **THE GREP BELOW IS THE PROCESS CHECK, NOT THE PROOF** - the by-value
# fingerprint below is what certifies the fix is in the pool object
# ([[mi4-self-written-record-is-not-a-constraint]]).
grep -qx 'STAGE90_XNU_GLOBAL_FIX=1 role=1024-vm-max-split' "$LIVE/xnu_arm_entry-arm-extra.txt" || {
  echo "REFUSING: out/stage90/xnu_arm_entry-arm-extra.txt does not carry 'STAGE90_XNU_GLOBAL_FIX=1 role=1024-vm-max-split' (it holds: '$(cat "$LIVE/xnu_arm_entry-arm-extra.txt" 2>/dev/null)') - the pool fix that keeps the retry storm gone is not declared by THIS build (build_1024.sh writes this line at its tail)"; exit 1; }
EXPECT_ARM=armed-d13-$(sha256sum "$LIVE/xnu_arm_entry.bin" | cut -c1-8)
echo "   arm = $EXPECT_ARM"

# BY VALUE (0-POOL): the inherited GLOBAL-FIX (1015b) is in the pool object the linked image was built
# from - `pmap_flush_tlbs` materializes `kernel_pmap` EXACTLY 3 times (OFF/Apple = 2).  1024 rebuilds the
# WHOLE pool (vm_param.h is a HEADER every pool TU includes), so the 1020 defect (a record-derived EXTRA
# dropping the GLOBAL_FIX token) is available again.
_gf_obj=out/xnu_kernel_obj_d13/osfmk_arm_pmap.o
[[ -f "$_gf_obj" ]] || { echo "REFUSING: $_gf_obj is absent - 1015b's GLOBAL-FIX cannot be certified"; exit 1; }
_gf_kp=$(arm-none-eabi-objdump -r "$_gf_obj" 2>/dev/null | awk '$1>="00000418" && $1<="00000640"' | grep -c 'MOVW_ABS_NC.*kernel_pmap' || true)
_gf_full=$(arm-none-eabi-objdump -r "$_gf_obj" 2>/dev/null | awk '$1>="00000418" && $1<="00000640"' | grep -c 'R_ARM_CALL.*arm_tlb_flushID$' || true)
_gf_asid=$(arm-none-eabi-objdump -r "$_gf_obj" 2>/dev/null | awk '$1>="00000418" && $1<="00000640"' | grep -c 'R_ARM_CALL.*arm_tlb_flushID_ASID$' || true)
[[ "$_gf_kp" == "3" && "$_gf_full" == "1" && "$_gf_asid" == "1" ]] || {
  echo "REFUSING: pmap_flush_tlbs materializes kernel_pmap x$_gf_kp (want 3), arm_tlb_flushID x$_gf_full / arm_tlb_flushID_ASID x$_gf_asid (want 1/1) - GLOBAL-FIX is NOT in the pool object, so the retry storm 1015b killed is BACK and the run would never reach pid 1's pthread-create fault this rung exists to move. Re-run scripts/build_1024.sh."; exit 1; }
echo "   (0-POOL) by value: pmap_flush_tlbs carries the 3rd kernel_pmap materialization ($_gf_kp sites) and the 1/1 flush arms - 1015b's GLOBAL-FIX IS in the pool object this image was built from"

# BY VALUE (0a): THE RUNG'S OWN CLAIM.  `tools/check_vm_max_split.py` reads `task_create_internal` BY
# VALUE (both ends resolved by NAME from the symbol table) and asserts the `mov r2,#imm` feeding
# `bl vm_map_create` reads 0x40000000 in the `--expect on` direction - i.e. the task map's ceiling now
# equals the hardware's 1 GiB TTBR0 split.
# Read on the LINKED image, because build_entry.sh only LINKS the pool objects (a stale object hides the
# old ceiling; records/1020-build-defect.txt).
#
# **THE CHECKER IS REQUIRED.**  Its absence means the arm's own claim cannot be certified
# ([[mi4-a-claim-in-a-comment-is-not-a-check]]).
[[ -f tools/check_vm_max_split.py ]] || {
  echo "REFUSING: tools/check_vm_max_split.py is ABSENT - it is this press's by-value claim on the linked image's task-map ceiling, and there is no sound fallback (a grep of the source cannot distinguish 'the switch reached the object' from 'the header edit never compiled'). A press that skipped it would spend the device on an arm whose 'ceiling moved' claim nothing ever checked"; exit 1; }

# 0a-0. the checker's OWN self-test - a checker that cannot fail is not a check.
python3 -I tools/check_vm_max_split.py --selftest >/dev/null 2>&1 || {
  echo "REFUSING: tools/check_vm_max_split.py --selftest did NOT PASS - the checker cannot certify anything (an inert checker would bless any image)"; exit 1; }
echo "   (0a-0) by value: tools/check_vm_max_split.py --selftest PASSes (the checker is live; mov + movw/movt spellings, wrong value and missing-symbol arms all exercise)"

# 0a-1. THE RUNG'S OWN CLAIM, on the LINKED image.
python3 -I tools/check_vm_max_split.py "$LIVE/xnu_arm_entry.elf" --expect on >/dev/null 2>&1 || {
  echo "REFUSING: the LINKED image's task_create_internal does NOT pass 0x40000000 to vm_map_create - either the widened vm_param.h:63 line did not reach the pool (the env -> global DEFINES channel of build_xnu_arm_kernel.sh), or a STALE pool object was linked (build_entry.sh only LINKS it, so a green entry build says nothing about this half). The task map's ceiling would then read 0x80000000 and this press would re-measure 1023's storm. Re-run scripts/build_1024.sh"; exit 1; }
echo "   (0a-1) by value: the LINKED image's task_create_internal passes 0x40000000 to vm_map_create (== the hardware's 1 GiB TTBR0 split)"

# 0a-2. THE DISCRIMINATING CONTROL.  The SAME checker, `--expect off`, on the FROZEN PRE-RUNG arm (1023,
# 10b79e5d), whose ceiling IS 0x80000000 (1023 never touched VM_MAX_ADDRESS - 1024 is the FIRST rung to
# move it).
# The pair (pre-rung -> off PASS, this arm -> on PASS) proves the checker DISCRIMINATES
# ([[mi4-a-claim-in-a-comment-is-not-a-check]]).
_ctrl=$LIVE/frozen/armed-d13-10b79e5d/xnu_arm_entry.elf
[[ -s $_ctrl ]] || { echo "REFUSING: the frozen 1023 elf ($_ctrl) is absent - the NEGATIVE CONTROL for this press's by-value clause cannot be taken, so the clause above cannot be shown to DISCRIMINATE. 1023's park must exist before 1024's"; exit 1; }
python3 -I tools/check_vm_max_split.py "$_ctrl" --expect off >/dev/null 2>&1 || {
  echo "REFUSING: the frozen 1023 elf's ceiling does NOT read 0x80000000 in the --expect off direction - the checker is either broken or pointed at the wrong immediate, so the 'on' PASS above certifies nothing. A control that agrees with the test proves only that the checker says one thing"; exit 1; }
echo "   (0a-2) by value: NEGATIVE CONTROL - the frozen 1023 elf (10b79e5d) reads the ceiling == 0x80000000 (--expect off PASSes), so the 'on' above is a reading and not a constant"

# BY VALUE (0b): the inherited 1021d NEON-free claim still holds on the LINKED image - 1024 recompiles
# the WHOLE pool (vm_param.h is a header), so the -msoft-float flag must still reach every object.
[[ -f tools/check_d13_no_neon.py ]] || { echo "REFUSING: tools/check_d13_no_neon.py is ABSENT - the inherited 1021d claim's by-value check"; exit 1; }
python3 -I tools/check_d13_no_neon.py --selftest >/dev/null 2>&1 || { echo "REFUSING: tools/check_d13_no_neon.py --selftest did NOT PASS"; exit 1; }
python3 -I tools/check_d13_no_neon.py "$LIVE/xnu_arm_entry.elf" --symbol mach_msg_send --expect none >/dev/null 2>&1 || {
  echo "REFUSING: the LINKED image's mach_msg_send still contains FP/NEON instructions - 1021d's -msoft-float flag did not reach the object the linker saw, or a STALE pool object was linked. Re-run scripts/build_1024.sh"; exit 1; }
echo "   (0b) by value: the LINKED image's mach_msg_send is NEON-free (1021d's -msoft-float holds)"

# BY VALUE (0c): the inherited 1020 raise claim still holds on the LINKED image.
[[ -f tools/check_d13_undef_raise.py ]] || { echo "REFUSING: tools/check_d13_undef_raise.py is ABSENT"; exit 1; }
python3 -I tools/check_d13_undef_raise.py "$LIVE/xnu_arm_entry.elf" --expect on >/dev/null 2>&1 || {
  echo "REFUSING: tools/check_d13_undef_raise.py \"$LIVE/xnu_arm_entry.elf\" --expect on did NOT pass - the linked image's sleh_undef does not carry 1020's moved \`return\`, so the udf loop is back. Re-run scripts/build_1024.sh"; exit 1; }
echo "   (0c) by value: tools/check_d13_undef_raise.py --expect on PASSes (1020's raise is intact)"

# BY VALUE (0d): the inherited 1023 row-24 claim still holds on the LINKED image - 1024 moves the
# ceiling and ADDS NOTHING ELSE, so `mach_trap_table[24]` must still be the construct handler with rows
# 25/41/42 still kern_invalid (the composition this rung inherits unchanged).
[[ -f tools/check_1023_trap24.py ]] || { echo "REFUSING: tools/check_1023_trap24.py is ABSENT - it is the inherited 1023 claim's by-value check on the linked image (build_1023's row 24)"; exit 1; }
python3 -I tools/check_1023_trap24.py --selftest >/dev/null 2>&1 || { echo "REFUSING: tools/check_1023_trap24.py --selftest did NOT PASS - the inherited row-24 checker cannot certify anything"; exit 1; }
python3 -I tools/check_1023_trap24.py "$LIVE/xnu_arm_entry.elf" --expect on >/dev/null 2>&1 || {
  echo "REFUSING: the LINKED image's mach_trap_table[24] is NOT the ios7lab_mach_port_construct_trap row any more (or rows 25/41/42 moved) - 1024 moves the ceiling and must ADD nothing else; with the row gone the 1023 frontier is back and this press would measure the wrong wall. Re-run scripts/build_1024.sh"; exit 1; }
echo "   (0d) by value: the LINKED image's mach_trap_table[24] IS the ios7lab_mach_port_construct_trap row (arg_count=5, rows 25/41/42 still kern_invalid)"

echo "== 1. the real iOS 7.1.2 rootfs as the card image (the COW base) =="
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
# 1024 is a RESIDENT rung: if it does not return it keeps NO /proc/last_kmsg of its own, so start the
# HOST reader FIRST; it attaches the moment the payload enumerates. Primary channel: step 4.
USB_OUT="out/stage90/captures/usb-console-1024-$(date -u +%Y%m%d-%H%M%S).txt"
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
# **THE READER'S OWN VERDICT.** A zero-byte capture and a bare `kill` report the same thing whether
# the payload never enumerated (exit 2) or enumerated and delivered nothing (exit 3); discarding the
# exit code is what made the 1024 non-return read as "no way to tell". The reader is backgrounded with
# `&`, so `wait` is the only way to its status - and the trap fires on EXIT, so poll it out first.
USB_RC=0
for _ in $(seq 1 40); do
  kill -0 "$USB_PID" 2>/dev/null || break
  sleep 0.25
done
if kill -0 "$USB_PID" 2>/dev/null; then
  kill "$USB_PID" 2>/dev/null || true
  USB_RC=-1
else
  # `wait` on a SIGNALED reader returns 128+signal (143 = the EXIT trap\x27s SIGTERM) and under
  # `set -e` ABORTS THE SCRIPT before the capture check, the recovery, and the reading run - which is
  # what truncated the 1024/1027 press logs at the runner\x27s line, losing the USB verdict that says
  # whether the reader saw the device.  `set +e` keeps both the script alive AND the reader\x27s real status.
  set +e
  wait "$USB_PID"
  USB_RC=$?
  set -e
fi
echo "== USB console capture: $USB_OUT =="
[ -s "$USB_OUT" ] && echo "   bytes read: $(wc -c < "$USB_OUT")" || echo "   (zero bytes)"
case "$USB_RC" in
  0)  echo "   reader exit 0: the payload's EP1-IN delivered bytes (the RAM console stream ran)." ;;
  2)  echo "   reader exit 2: NOTHING ENUMERATED as 18d1:0910 in the window - the payload never reached" ;;
  3)  echo "   reader exit 3: the payload ENUMERATED and was claimed, but EP1-IN delivered NOTHING - it" ;;
  -1) echo "   reader STILL WAITING when the runner returned (killed here): the payload had not enumerated" ;;
  *)  echo "   reader exit $USB_RC (see tools/usb_console_read.py's exit contract)" ;;
esac
case "$USB_RC" in
  2|-1) echo "        the ladder (STAGE90_XNU_USB_ENUM=1 here); the run died before the USB idle path." ;;
  3)    echo "        reached USB but the stream never primed (see 960's note on USBCMD.RST)." ;;
esac

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
echo "   adjudicate against docs/1024-design.md section 4:"
echo "     G-CTL          neither the live channel nor any IOS7LAB line is live (and no panic/stop) =>"
echo "                    WITHHOLD (an unsound instrument cannot read an absence)"
echo "     STORM-GONE     the 1023 storm signature (abt_pc at slide-corrected 0x38241790, abt_far"
echo "                    0x40083008) is ABSENT AND the prior rungs' positive controls still hold in"
echo "                    the SAME capture (trap24 frame x4, port_construct result=0 x4,"
echo "                    xnu_live_undef_seq = 0x, zero panics) => WALL MOVED; the checker reports the"
echo "                    NEW frontier (last non-storm abt_pc/far, last user SVC, last stall pc)"
echo "     STORM-PERSISTS the storm recurs at 1023's pc/far at scale => the patch did NOT reach the"
echo "                    compiled image; read check_vm_max_split.py <elf> --expect on before anything"
echo "     STORM-MOVED    a storm exists elsewhere; any abt_far >= 0x40000000 means the map was not the"
echo "                    only producer (1024-W's (U) registry names the culprit)"
echo "     PRIOR-RUNGS-REGRESSED one of the prior rungs' controls regressed => the arm's switch set is"
echo "                    wrong, not the fix"
echo "   Machine check: python3 -I tools/check_1024_capture.py <capture> --baseline <1023 capture>"
echo "   Read the 1023 reading beside it: records/1023-press-read.txt (T24-FIRES; the storm this rung"
echo "   exists to retire).  The udf witness rides the DIRECT channel (UNDEF_DIRECT)."