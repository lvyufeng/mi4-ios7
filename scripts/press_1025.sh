#!/usr/bin/env bash
# ====================================================================================================
# press_1025.sh.  MODELLED ON scripts/press_1024.sh (itself the RESIDENT-rung press: the USB console
# reader + the /proc/last_kmsg recovery).
#
# Press 1025: PUBLISH THE DISCARDED vm_fault RETURN FOR THE launchctl[2] STACK ABORT (and the stack's
# shape) - the frontier becomes a NUMBER.  Switch: **ONE NEW: STAGE90_XNU_USTACK_PROBE=1** (1024's set
# VERBATIM otherwise).  Design: docs/1025-design.md.
#
# THE ONE QUESTION THIS RUNG DECIDES.  The 1024 boot (records/1024b-frontier-launchctl-crash.txt)
# reached `*** launchd[1] has started up ***`, spawned pid 2 `launchctl`, then died in a USERSPACE DATA
# ABORT on a STACK VA: `launchctl[2]: usermode data abort, EXC_BAD_ACCESS at 0x2bdbe000 in map
# 0xc0005688 (pmap 0xc0ba3b28) (Translation fault on page)`, `r4=r6=0x2bdbe000`, `sp=0x2bdbd074`,
# `lr=0x3adbc9af`, `pc=0x3adc4756`, `cpsr=0xa0000030` (T=1 Thumb, mode=USR).  By value 0x2bdbe000 is
# INSIDE the fixed stack window [0x2BD00000, 0x2BE00000) `create_unix_stack` allocates, and `sp` shows
# the FIXED allocation SUCCEEDED (no ANYWHERE fallback) - so a page that should be mapped is
# TRANSLATION-faulting (records/1025-source-trace.txt sections 3-4 FALSIFIED v1's collision hypothesis).
# In osfmk/arm/trap.c the usermode data-abort path CALLS `vm_fault` (trap.c:806) and, on a non-SUCCESS
# return (trap.c:809), prints the abort and delivers EXC_BAD_ACCESS (`doexception`, trap.c:968); the
# ONE assignment of the return code sits inside `#if BOARD_CONFIG_QSD8250_LEO` (trap.c:810-814), so on
# CANCRO **the value that NAMES the cause (`code`) is DISCARDED**.  The instrument (`trap.c`)
# publishes it for EVERY failed usermode data abort, NON-RINGED, because the `xnu_live_abt_*` RING
# capped at `n=0x400` on the shared-cache fault before the launchctl abort; a second instrument
# (`kern_exec.c`) publishes the stack's placement once per exec.  The arm identity is settled in
# records/1025-globalfix-carrier.txt section 6: the crash arm IS the 1024-shaped arm (VM_MAX_SPLIT=1
# AND GLOBAL_FIX=1), so GLOBAL_FIX did NOT retire the abort => case (R2) => the probe is REQUIRED.
#
# THE PRE-REGISTERED CELLS (docs/1025-design.md section 4; read by tools/check_1025_capture.py; its
# ORDER is G-CTL first, then REGRESSION before FAULT-NAMED):
#   G-CTL          - neither launchd-reached nor any prior control (trap24 / abt_pc) is live AND no
#                    panic => WITHHOLD (fail closed; an unsound instrument cannot read an absence)
#   FAULT-NAMED    - a `xnu_live_abt_vmfkrv_*` row whose `_far` is INSIDE the stack window
#                    [0x2BD00000, 0x2BE00000) with a `_vmfkrv` return that NAMES the cause => report the
#                    cause (this is the 1025 goal: the discarded return for 0x2bdbe000)
#   FAULT-NOT-RUN  - launchd was reached but NO `xnu_live_abt_vmfkrv=` row exists => the abort is NOT
#                    this (data) path; re-read (a PREFETCH abort? then instrument THAT arm too)
#   STACK-SHAPE    - `xnu_live_ustack_*` present with `_rc=0` and no ANYWHERE fallback => confirms
#                    records/1025-source-trace.txt's by-value claim independently
#   REGRESSION     - the 1024 controls regressed (the 1023 pthread storm returns, or trap24 /
#                    port_construct result=0 vanish) => the arm's switch set is wrong, not the fix
#   NO-CELL        - nothing in the table fired (report what was present; never fabricate)
#
# **THIS PRESS IS NOT TO READ A LOG.**  A `fastboot boot` spent to look at a log has no question behind
# it: this rung's question is the one above, and the arm must be the one the by-value gates below
# certify.  The recovery step reads `/proc/last_kmsg` only because the run's own log is the reading
# ([[mi4-last-kmsg-reader-carrier]]: the carrier is the FLASHED ROM).
#
# Medium: 968 real iOS 7.1.2 HFSX rootfs over hfs_rmd0; CARD_COW=1, HDD_WRITE=0, the base is never
# written - fully reversible.  fastboot boot only, NEVER flash.
# ====================================================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

LIVE=out/stage90
REC=$LIVE/xnu_arm_entry-config.txt

echo "== 0. the record must be 1025's arm =="
# 1025's own new switch: the two publishers (trap.c -> xnu_live_abt_vmfkrv=*, kern_exec.c ->
# xnu_live_ustack_req=*) are gated by STAGE90_XNU_USTACK_PROBE, and it is ALSO the readability carrier
# (a record without it means the pool was built with the probe gated SHUT, so the run would discard
# the discarded `vm_fault` return again and 1025 would capture NOTHING on its frontier).
grep -q '^STAGE90_XNU_USTACK_PROBE=1$' "$REC" || {
  echo "REFUSING: the record does not carry STAGE90_XNU_USTACK_PROBE=1 - the two publishers this rung IS are gated by THIS switch (trap.c's xnu_live_abt_vmfkrv=* + kern_exec.c's xnu_live_ustack_req=*). Its absence means the pool was built with the probe SHUT (the trap's `code` is discarded again), so the frontier would still be unreadable and this press would not be a reading of THIS rung. Build it with scripts/build_1025.sh first"; exit 1; }
# 1024's own switch: the widened vm_param.h:63 line reads STAGE90_XNU_VM_MAX_SPLIT, and it is what keeps
# the 1023 pthread storm away - the boot must reach launchctl for 1025 to have anything to read.
grep -q '^STAGE90_XNU_VM_MAX_SPLIT=1$' "$REC" || {
  echo "REFUSING: the record does not carry STAGE90_XNU_VM_MAX_SPLIT=1 - 1024's widened vm_param.h:63 line reads THIS switch. Its absence means the pool was built with the OLD ceiling (0x80000000), so the task map still reaches above the hardware's 1 GiB TTBR0 split and the 1023 storm recurs - the boot would never reach the launchctl abort 1025 exists to read. Build it with scripts/build_1025.sh first"; exit 1; }
# 1023's row-24 gate reads STAGE90_XNU_IOS7_TRAPS; 1025 ADDS ONLY THE PROBE, so trap 24 must still be
# installed or the 1023 frontier (libxpc's port-allocation udf) is back.
grep -q '^STAGE90_XNU_IOS7_TRAPS=1$' "$REC" || {
  echo "REFUSING: the record does not carry STAGE90_XNU_IOS7_TRAPS=1 - 1023's row-24 gate widens to read THIS switch. Its absence means the pool was built without -DSTAGE90_XNU_IOS7_TRAPS=1, so row 24 stays kern_invalid, libxpc's port-allocation udf recurs, and this rung would measure the 1023 frontier instead of the launchctl stack abort it exists to name (build it with scripts/build_1025.sh first)"; exit 1; }
# The inherited switches this arm's set carries VERBATIM (1021d's set).
grep -q '^STAGE90_XNU_GENERAL_REGS=1$' "$REC" || {
  echo "REFUSING: the record does not carry STAGE90_XNU_GENERAL_REGS=1 - 1021d's -msoft-float flag must stay on, or the kernel-mode NEON undef at 0x8047b0ac returns and this rung would measure a different frontier"; exit 1; }
grep -q '^STAGE90_XNU_UNDEF_RAISE=1$' "$REC" || {
  echo "REFUSING: the record does not carry STAGE90_XNU_UNDEF_RAISE=1 - 1020's raise fix must stay on, or pid 1's genuine udf loops forever again (8183x measured) and 1025 would measure a different frontier"; exit 1; }
grep -q '^STAGE90_XNU_UNDEF_DIRECT=1$' "$REC" || {
  echo "REFUSING: the record does not carry STAGE90_XNU_UNDEF_DIRECT=1 - without the direct channel the udf witness can be silenced by the cap before the frontier (the 1017/1018 instrument defect)"; exit 1; }
# GLOBAL_FIX is a POOL switch declared only in the arm-extra drop-in (records/1020-build-defect.txt); it
# cannot be in the record.  **THE GREP BELOW IS THE PROCESS CHECK, NOT THE PROOF** - the by-value
# fingerprint below is what certifies the fix is in the pool object
# ([[mi4-self-written-record-is-not-a-constraint]]).
grep -qx 'STAGE90_XNU_GLOBAL_FIX=1 role=1025-ustack-probe' "$LIVE/xnu_arm_entry-arm-extra.txt" || {
  echo "REFUSING: out/stage90/xnu_arm_entry-arm-extra.txt does not carry 'STAGE90_XNU_GLOBAL_FIX=1 role=1025-ustack-probe' (it holds: '$(cat "$LIVE/xnu_arm_entry-arm-extra.txt" 2>/dev/null)') - the pool fix that keeps the retry storm gone is not declared by THIS build (build_1025.sh writes this line at its tail)"; exit 1; }
EXPECT_ARM=armed-d13-$(sha256sum "$LIVE/xnu_arm_entry.bin" | cut -c1-8)
echo "   arm = $EXPECT_ARM"

# BY VALUE (0-POOL): the inherited GLOBAL-FIX (1015b) is in the pool object the linked image was built
# from - `pmap_flush_tlbs` materializes `kernel_pmap` EXACTLY 3 times (OFF/Apple = 2).  1025 rebuilds the
# WHOLE pool (trap.c/kern_exec.c are POOL objects), so the 1020 defect (a record-derived EXTRA dropping
# the GLOBAL_FIX token) is available again.  It also proves the arm is the 1024-shaped arm whose crash
# 1025 exists to name (records/1025-globalfix-carrier.txt section 6).
_gf_obj=out/xnu_kernel_obj_d13/osfmk_arm_pmap.o
[[ -f "$_gf_obj" ]] || { echo "REFUSING: $_gf_obj is absent - 1015b's GLOBAL-FIX cannot be certified"; exit 1; }
_gf_kp=$(arm-none-eabi-objdump -r "$_gf_obj" 2>/dev/null | awk '$1>="00000418" && $1<="00000640"' | grep -c 'MOVW_ABS_NC.*kernel_pmap' || true)
_gf_full=$(arm-none-eabi-objdump -r "$_gf_obj" 2>/dev/null | awk '$1>="00000418" && $1<="00000640"' | grep -c 'R_ARM_CALL.*arm_tlb_flushID$' || true)
_gf_asid=$(arm-none-eabi-objdump -r "$_gf_obj" 2>/dev/null | awk '$1>="00000418" && $1<="00000640"' | grep -c 'R_ARM_CALL.*arm_tlb_flushID_ASID$' || true)
[[ "$_gf_kp" == "3" && "$_gf_full" == "1" && "$_gf_asid" == "1" ]] || {
  echo "REFUSING: pmap_flush_tlbs materializes kernel_pmap x$_gf_kp (want 3), arm_tlb_flushID x$_gf_full / arm_tlb_flushID_ASID x$_gf_asid (want 1/1) - GLOBAL-FIX is NOT in the pool object, so the retry storm 1015b killed is BACK and the run would never reach the launchctl abort this rung exists to name. Re-run scripts/build_1025.sh."; exit 1; }
echo "   (0-POOL) by value: pmap_flush_tlbs carries the 3rd kernel_pmap materialization ($_gf_kp sites) and the 1/1 flush arms - 1015b's GLOBAL-FIX IS in the pool object this image was built from"

# BY VALUE (0a): THE RUNG'S OWN CLAIM - THE TWO PUBLISHERS ARE IN THE POOL OBJECTS.  This is 1025's
# substance: without them the press captures NOTHING on its frontier (the `xnu_live_abt_vmfkrv=*` and
# `xnu_live_ustack_*` keys are the reading).  The fingerprint is a FORMAT STRING, read by `strings`
# (the 1025 build's 5a clause), so a record that says 1 over a pool that carries neither is a refusal
# (the records/1020-build-defect.txt shape).
[[ -f tools/check_1025_capture.py ]] || {
  echo "REFUSING: tools/check_1025_capture.py is ABSENT - it is this press's capture reader and its by-value claim's checker, and there is no sound fallback. A press that skipped it could not adjudicate the pre-registered cells"; exit 1; }
_trap_obj=out/xnu_kernel_obj_d13/osfmk_arm_trap.o
_exec_obj=out/xnu_kernel_obj_d13/bsd_kern_kern_exec.o
[[ -f "$_trap_obj" ]] || { echo "REFUSING: $_trap_obj is absent - trap.c is where xnu_live_abt_vmfkrv=* lives, and a press whose trap.o is missing cannot name the fault"; exit 1; }
[[ -f "$_exec_obj" ]] || { echo "REFUSING: $_exec_obj is absent - kern_exec.c is where xnu_live_ustack_req=* lives, and a press whose kern_exec.o is missing cannot read the stack's shape"; exit 1; }
grep -qa '^xnu_live_abt_vmfkrv=' <(strings "$_trap_obj") || {
  echo "REFUSING: $_trap_obj carries NO xnu_live_abt_vmfkrv= publisher - the pool was NOT recompiled with STAGE90_XNU_USTACK_PROBE=1 (the env -> global DEFINES channel of build_xnu_arm_kernel.sh) or the trap.c edit is not staged. The discarded `vm_fault` return would NOT be published, so this press would capture nothing on the launchctl fault it exists to name. Re-run scripts/build_1025.sh"; exit 1; }
grep -qa '^xnu_live_ustack_req=' <(strings "$_exec_obj") || {
  echo "REFUSING: $_exec_obj carries NO xnu_live_ustack_req= publisher - the pool was NOT recompiled with STAGE90_XNU_USTACK_PROBE=1 or the kern_exec.c edit is not staged. The stack's placement (`rc`, `final`, the guard geometry) would NOT be published, so the STACK-SHAPE co-reading is impossible. Re-run scripts/build_1025.sh"; exit 1; }
echo "   (0a) by value: trap.o carries the xnu_live_abt_vmfkrv= publisher, kern_exec.o carries the xnu_live_ustack_req= publisher (the probe IS in the pool objects)"

# 0a-0. the checker's OWN self-test - a checker that cannot fail is not a check
# ([[mi4-a-claim-in-a-comment-is-not-a-check]]).
python3 -I tools/check_1025_capture.py --selftest >/dev/null 2>&1 || {
  echo "REFUSING: tools/check_1025_capture.py --selftest did NOT PASS - the checker cannot certify anything (an inert checker would bless any capture)"; exit 1; }
echo "   (0a-0) by value: tools/check_1025_capture.py --selftest PASSes (the checker is live; FAULT-NAMED / FAULT-NOT-RUN / REGRESSION / STACK-SHAPE / G-CTL / NO-CELL arms all exercise)"

# BY VALUE (0b): the inherited 1024 ceiling claim still holds on the LINKED image - 1025 ADDS ONLY THE
# PROBE, so `task_create_internal` must still pass 0x40000000 to `vm_map_create`.
# Read on the LINKED image, because build_entry.sh only LINKS the pool objects (a stale object hides the
# old ceiling; records/1020-build-defect.txt).
[[ -f tools/check_vm_max_split.py ]] || {
  echo "REFUSING: tools/check_vm_max_split.py is ABSENT - it is the inherited 1024 claim's by-value check on the linked image's task-map ceiling, and there is no sound fallback"; exit 1; }
python3 -I tools/check_vm_max_split.py --selftest >/dev/null 2>&1 || {
  echo "REFUSING: tools/check_vm_max_split.py --selftest did NOT PASS - the inherited ceiling checker cannot certify anything"; exit 1; }
python3 -I tools/check_vm_max_split.py "$LIVE/xnu_arm_entry.elf" --expect on >/dev/null 2>&1 || {
  echo "REFUSING: the LINKED image's task_create_internal does NOT pass 0x40000000 to vm_map_create - either 1024's widened vm_param.h:63 line did not reach the pool (the env -> global DEFINES channel), or a STALE pool object was linked (build_entry.sh only LINKS it). The task map's ceiling would then read 0x80000000 and this press would re-measure 1023's storm. Re-run scripts/build_1025.sh"; exit 1; }
echo "   (0b) by value: the LINKED image's task_create_internal passes 0x40000000 to vm_map_create (1024's ceiling is intact)"

# 0b-2. THE DISCRIMINATING CONTROL.  The SAME checker, `--expect off`, on a FROZEN arm whose ceiling is
# the PRE-SPLIT value 0x80000000 - i.e. an arm built BEFORE 1024's vm_param.h:63 widening.  The 1023 arm
# (armed-d13-10b79e5d, role=1023-trap24, VM_MAX_SPLIT UNSET) is exactly that arm: it reads 0x80000000
# and PASSes --expect off.  The (10b79e5d -> off PASS, this arm -> on PASS) pair is what proves the
# checker DISCRIMINATES rather than reporting one constant in both directions.
#
# **NOT armed-d13-64558b47.** An earlier draft of this clause pointed at that arm calling it "the FROZEN
# 1024 PRE-RUNG arm" - but 64558b47 IS 1024's OWN arm (its arm-extra reads `role=1024-vm-max-split` and
# its record carries `STAGE90_XNU_VM_MAX_SPLIT=1`), so its ceiling already reads 0x40000000 and the
# `--expect off` direction FAILS. A control taken on the arm the fix PRODUCED agrees with the test and
# proves only that the checker says one thing (the mis-named-control class). The control must be a
# PRE-FIX arm. If 10b79e5d's park is absent the clause SKIPS (this press must not hard-depend on a park).
_ctrl=$LIVE/frozen/armed-d13-10b79e5d/xnu_arm_entry.elf
if [[ -s $_ctrl ]]; then
  python3 -I tools/check_vm_max_split.py "$_ctrl" --expect off >/dev/null 2>&1 || {
    echo "REFUSING: the frozen 1023 elf (10b79e5d)'s ceiling does NOT read 0x80000000 in the --expect off direction - the checker is either broken or pointed at the wrong immediate, so the 'on' PASS above certifies nothing. A control that agrees with the test proves only that the checker says one thing"; exit 1; }
  echo "   (0b-2) by value: NEGATIVE CONTROL - the frozen 1023 elf (10b79e5d, PRE-SPLIT) reads the ceiling == 0x80000000 (--expect off PASSes), so the 'on' above is a reading and not a constant"
else
  echo "   (0b-2) SKIP: the frozen 1023 elf ($_ctrl) is absent - the pre-split park does not exist here, so this press does not hard-depend on it. The 'on' PASS above still stands; the discriminating control can be taken once a pre-split arm is parked"
fi

# BY VALUE (0c): the inherited 1021d NEON-free claim still holds on the LINKED image - 1025 recompiles
# the WHOLE pool (trap.c/kern_exec.c), so the -msoft-float flag must still reach every object.
[[ -f tools/check_d13_no_neon.py ]] || { echo "REFUSING: tools/check_d13_no_neon.py is ABSENT - the inherited 1021d claim's by-value check"; exit 1; }
python3 -I tools/check_d13_no_neon.py --selftest >/dev/null 2>&1 || { echo "REFUSING: tools/check_d13_no_neon.py --selftest did NOT PASS"; exit 1; }
python3 -I tools/check_d13_no_neon.py "$LIVE/xnu_arm_entry.elf" --symbol mach_msg_send --expect none >/dev/null 2>&1 || {
  echo "REFUSING: the LINKED image's mach_msg_send still contains FP/NEON instructions - 1021d's -msoft-float flag did not reach the object the linker saw, or a STALE pool object was linked. Re-run scripts/build_1025.sh"; exit 1; }
echo "   (0c) by value: the LINKED image's mach_msg_send is NEON-free (1021d's -msoft-float holds)"

# BY VALUE (0d): the inherited 1020 raise claim still holds on the LINKED image.
[[ -f tools/check_d13_undef_raise.py ]] || { echo "REFUSING: tools/check_d13_undef_raise.py is ABSENT"; exit 1; }
python3 -I tools/check_d13_undef_raise.py "$LIVE/xnu_arm_entry.elf" --expect on >/dev/null 2>&1 || {
  echo "REFUSING: tools/check_d13_undef_raise.py \"$LIVE/xnu_arm_entry.elf\" --expect on did NOT pass - the linked image's sleh_undef does not carry 1020's moved \`return\`, so the udf loop is back. Re-run scripts/build_1025.sh"; exit 1; }
echo "   (0d) by value: tools/check_d13_undef_raise.py --expect on PASSes (1020's raise is intact)"

# BY VALUE (0e): the inherited 1023 row-24 claim still holds on the LINKED image - 1025 ADDS ONLY THE
# PROBE, so `mach_trap_table[24]` must still be the construct handler with rows 25/41/42 still
# kern_invalid (the composition this rung inherits unchanged).
[[ -f tools/check_1023_trap24.py ]] || { echo "REFUSING: tools/check_1023_trap24.py is ABSENT - it is the inherited 1023 claim's by-value check on the linked image (build_1023's row 24)"; exit 1; }
python3 -I tools/check_1023_trap24.py --selftest >/dev/null 2>&1 || { echo "REFUSING: tools/check_1023_trap24.py --selftest did NOT PASS - the inherited row-24 checker cannot certify anything"; exit 1; }
python3 -I tools/check_1023_trap24.py "$LIVE/xnu_arm_entry.elf" --expect on >/dev/null 2>&1 || {
  echo "REFUSING: the LINKED image's mach_trap_table[24] is NOT the ios7lab_mach_port_construct_trap row any more (or rows 25/41/42 moved) - 1025 adds only the probe and must ADD nothing else; with the row gone the 1023 frontier is back and this press would measure the wrong wall. Re-run scripts/build_1025.sh"; exit 1; }
echo "   (0e) by value: the LINKED image's mach_trap_table[24] IS the ios7lab_mach_port_construct_trap row (arg_count=5, rows 25/41/42 still kern_invalid)"

# BY VALUE (0f): the probe IS in the LINKED image - the two publishers' format strings must be
# reachable from the ELF (an object carrying them that the linker DROPPED would leave the arm's claim
# unmet; the 1025 build's 6b clause reads the same).
grep -qa '^xnu_live_abt_vmfkrv=' <(strings "$LIVE/xnu_arm_entry.elf") || {
  echo "REFUSING: the LINKED $LIVE/xnu_arm_entry.elf carries NO xnu_live_abt_vmfkrv= string - the pool object that has it was not linked, so the press would capture nothing on the launchctl fault. Re-run scripts/build_1025.sh"; exit 1; }
grep -qa '^xnu_live_ustack_req=' <(strings "$LIVE/xnu_arm_entry.elf") || {
  echo "REFUSING: the LINKED $LIVE/xnu_arm_entry.elf carries NO xnu_live_ustack_req= string - the pool object that has it was not linked, so the stack-shape co-reading is impossible. Re-run scripts/build_1025.sh"; exit 1; }
echo "   (0f) by value: the LINKED image carries the xnu_live_abt_vmfkrv= AND xnu_live_ustack_req= publishers (the probe reached the image the press boots)"

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
# 1025 is a RESIDENT rung: if it does not return it keeps NO /proc/last_kmsg of its own, so start the
# HOST reader FIRST; it attaches the moment the payload enumerates. Primary channel: step 4.
USB_OUT="out/stage90/captures/usb-console-1025-$(date -u +%Y%m%d-%H%M%S).txt"
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

echo "== 5. read the recovered capture: run the 1025 reader and print its cell =="
# **THE READING IS TAKEN HERE, OR NOWHERE.**  The recovered run's own log is the reading of this rung's
# question ([[mi4-last-kmsg-reader-carrier]]), so the LAST step invokes the reader on the NEWEST
# recovered `last_kmsg` and PRINTS the cell.  The reader's exit is NOT this press's exit: `G-CTL`
# legitimately exits 1 (WITHHOLD), and a WITHHOLD is a reading of the instrument, not a failed press -
# so the invocation is wrapped and its status reported, never propagated ([[mi4-silence-is-a-reading]]).
_last=$(ls -1t out/stage90/captures/recovered-*-last_kmsg.txt 2>/dev/null | head -1 || true)
if [[ -n $_last ]]; then
  echo "   reading the NEWEST recovered capture: $_last"
  echo "   (its byte-identity to the 1024b crash family is the check that the slot was re-written this run:"
  echo "    the 1024b family sha is 685941a3c47c; if $_last still matches it, the run did NOT re-write the"
  echo "    ram-console slot and this is the stale slot, not the 1025 press's own boot)"
  set +e
  python3 -I tools/check_1025_capture.py "$_last"
  _rd_rc=$?
  set -e
  echo "   (reader exit $_rd_rc; 0 = a cell fired, 1 = G-CTL/WITHHOLD - both are readings)"
else
  echo "   NO recovered capture found under out/stage90/captures/recovered-*-last_kmsg.txt - there is"
  echo "   nothing to read; the run's log did not reach a recovery. Read records/1024b-frontier-launchctl-crash.txt"
  echo "   and re-run the recovery once the phone is visible ([[mi4-device-dark-needs-power-press]])"
fi

echo "== DONE =="
echo "   adjudicate against docs/1025-design.md section 4:"
echo "     G-CTL          neither launchd-reached nor any prior control (trap24 / abt_pc) is live AND no"
echo "                    panic => WITHHOLD (fail closed; an unsound instrument cannot read an absence)"
echo "     FAULT-NAMED    a xnu_live_abt_vmfkrv_* row whose _far is INSIDE the stack window"
echo "                    [0x2BD00000, 0x2BE00000) with a _vmfkrv return that NAMES the cause => report"
echo "                    the cause (this is the 1025 goal: the discarded return for 0x2bdbe000)"
echo "     FAULT-NOT-RUN  launchd was reached but NO xnu_live_abt_vmfkrv= row exists => the abort is NOT"
echo "                    this (data) path; re-read (a PREFETCH abort? then instrument THAT arm too)"
echo "     STACK-SHAPE    xnu_live_ustack_* present with _rc=0 and no ANYWHERE fallback => confirms"
echo "                    records/1025-source-trace.txt's by-value claim independently"
echo "     REGRESSION     the 1024 controls regressed (the 1023 pthread storm returns, or trap24 /"
echo "                    port_construct result=0 vanish) => the arm's switch set is wrong, not the fix"
echo "     NO-CELL        nothing in the table fired (report what was present; never fabricate)"
echo "   Machine check: python3 -I tools/check_1025_capture.py <capture>"
echo "   Read the 1024b reading beside it: records/1024b-frontier-launchctl-crash.txt (the wall this rung"
echo "   exists to name) and records/1025-globalfix-carrier.txt section 6 (the arm identity settlement)."