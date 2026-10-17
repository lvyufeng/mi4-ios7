#!/usr/bin/env bash
# ====================================================================================================
# press_1026.sh.  MODELLED ON scripts/press_1025.sh (itself the RESIDENT-rung press: the USB console
# reader + the /proc/last_kmsg recovery).
#
# Press 1026: DISCRIMINATE WHY THE launchctl[2] STACK VA HAS NO vm_map ENTRY - H1 WRONG MAP vs H2
# OFF-THE-END - by value.  Switch: **ONE NEW: STAGE90_XNU_ABT_ENTRY_PROBE=1** (1025's set VERBATIM
# otherwise).  Design: docs/1026-design.md.
#
# THE ONE QUESTION THIS RUNG DECIDES.  1025's press RAN and its own console was recovered
# (records/1025-press-read.txt): the discarded `vm_fault` return is `code=1` = KERN_INVALID_ADDRESS on
# `far=0x2bd35000` (the EXCLUSIVE TOP of launchctl's [0x2bc35000, 0x2bd35000)), `dfsr=0x807`,
# `prot=write`, `sp=0x2bd34074`, `pc=0x3b4ce756`, `pid=2`.  By source, KERN_INVALID_ADDRESS means
# `vm_map_lookup_entry(map, VA)` returned FALSE (vm_map.c:8761ff) - NO entry covered the VA when the walk
# ran.  1025's own `xnu_live_ustack_*` rows then FALSIFIED the 1025 design's "inside a written region"
# premise: the region ENDS at far.  1026 discriminates the two remaining causes, which predict DIFFERENT
# fixes, by publishing seven reads FOR THE FAILING FAULT ONLY: the walk's own lookup result (at `far` and
# at `far-4`), AND the two map identities H1 hinges on (`thread->map` vs `get_task_map(thread->task)`),
# AND the exec's `user_stack`.  Source routes: trap.c's abort path calls `vm_map_lookup_entry`
# (trap.c:806ff); `create_unix_stack` (kern_exec.c) allocates into the task map and records `user_stack`.
#
# THE PRE-REGISTERED CELLS (docs/1026-design.md section 4; read by tools/check_1026_capture.py; its
# ORDER is G-CTL first, then REGRESSION before the H cells):
#   G-CTL        - neither launchd-reached nor any prior control (trap24 / vmfkrv) is live AND no panic
#                  => WITHHOLD (fail closed; an unsound instrument cannot read an absence)
#   FAULT-NAMED  - the 1025 re-reading still HOLDS (a xnu_live_abt_vmfkrv row with vmfkrv=1 on a far in
#                  the stack window [0x2BD00000, 0x2BE00000)) => the discriminator is asked about the
#                  RIGHT fault and is worth reading
#   H1           - xnu_live_abt_lookup_far=0 AND far_in_map=0 AND map != taskmap AND ustack == far =>
#                  WRONG MAP (the entry was entered into a DIFFERENT map than the one the walk uses;
#                  fix = the exec must allocate into / the walk must use ONE map)
#   H2           - xnu_live_abt_lookup_far=0 AND far_in_map=1 AND entry_hi == far AND map == taskmap =>
#                  OFF-THE-END (the entry ends exactly at far; a legal word sits just below; the cause
#                  is upstream - the initial argv/env block / sp one word too high)
#   H-OTHER      - any other combination => report it; pick NO fix (fail closed); 1027 instruments
#                  whatever the combination names
#   REGRESSION   - the 1024 controls regressed (the 1023 pthread storm returns, or trap24 /
#                  port_construct result=0 vanish) => the arm's switch set is wrong, not the fix
#   NO-CELL      - nothing in the table fired (report what was present; never fabricate)
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

echo "== 0. the record must be 1026's arm =="
# 1026's own new switch: the seven discriminator reads (trap.c -> xnu_live_abt_lookup_far=* etc.,
# kern_exec.c -> the xnu_live_abt_proc_ustack accessor) are gated by STAGE90_XNU_ABT_ENTRY_PROBE, and it
# is ALSO the readability carrier (a record without it means the pool was built with the discriminator
# gated SHUT, so the launchctl fault would still leave H1/H2 unseparated and 1026 would capture NOTHING
# on its frontier).
grep -q '^STAGE90_XNU_ABT_ENTRY_PROBE=1$' "$REC" || {
  echo "REFUSING: the record does not carry STAGE90_XNU_ABT_ENTRY_PROBE=1 - the seven reads this rung IS are gated by THIS switch (trap.c's xnu_live_abt_lookup_far=* + kern_exec.c's xnu_live_abt_proc_ustack). Its absence means the pool was built with the discriminator SHUT and the launchctl fault would still leave WHY unreadable, so this press would not be a reading of THIS rung. Build it with scripts/build_1026.sh first"; exit 1; }
# 1025's PARENT switch: 1026's block is NESTED INSIDE 1025's publisher (the fault path is SHARED: ONE
# gate for it), so a record without STAGE90_XNU_USTACK_PROBE=1 means the discriminator prints NOTHING -
# and the 1025 re-reading the reader depends on would be gone too.
grep -q '^STAGE90_XNU_USTACK_PROBE=1$' "$REC" || {
  echo "REFUSING: the record does not carry STAGE90_XNU_USTACK_PROBE=1 - 1026's discriminator is NESTED INSIDE 1025's publisher block (the fault path is SHARED), so with the parent gate shut the seven reads never execute and the capture would be silent on the 1026 question while the record says the probe is live ([[mi4-one-file-many-rungs]]). Build it with scripts/build_1026.sh first"; exit 1; }
# 1024's own switch: the widened vm_param.h:63 line reads STAGE90_XNU_VM_MAX_SPLIT, and it is what keeps
# the 1023 pthread storm away - the boot must reach launchctl for 1026 to have anything to read.
grep -q '^STAGE90_XNU_VM_MAX_SPLIT=1$' "$REC" || {
  echo "REFUSING: the record does not carry STAGE90_XNU_VM_MAX_SPLIT=1 - 1024's widened vm_param.h:63 line reads THIS switch. Its absence means the pool was built with the OLD ceiling (0x80000000), so the task map still reaches above the hardware's 1 GiB TTBR0 split and the 1023 storm recurs - the boot would never reach the launchctl abort 1026 exists to name. Build it with scripts/build_1026.sh first"; exit 1; }
# 1023's row-24 gate reads STAGE90_XNU_IOS7_TRAPS; 1026 ADDS ONLY THE DISCRIMINATOR, so trap 24 must
# still be installed or the 1023 frontier (libxpc's port-allocation udf) is back.
grep -q '^STAGE90_XNU_IOS7_TRAPS=1$' "$REC" || {
  echo "REFUSING: the record does not carry STAGE90_XNU_IOS7_TRAPS=1 - 1023's row-24 gate widens to read THIS switch. Its absence means the pool was built without -DSTAGE90_XNU_IOS7_TRAPS=1, so row 24 stays kern_invalid, libxpc's port-allocation udf recurs, and this rung would measure the 1023 frontier instead of the launchctl stack fault it exists to name (build it with scripts/build_1026.sh first)"; exit 1; }
# The inherited switches this arm's set carries VERBATIM (1021d's set).
grep -q '^STAGE90_XNU_GENERAL_REGS=1$' "$REC" || {
  echo "REFUSING: the record does not carry STAGE90_XNU_GENERAL_REGS=1 - 1021d's -msoft-float flag must stay on, or the kernel-mode NEON undef at 0x8047b0ac returns and this rung would measure a different frontier"; exit 1; }
grep -q '^STAGE90_XNU_UNDEF_RAISE=1$' "$REC" || {
  echo "REFUSING: the record does not carry STAGE90_XNU_UNDEF_RAISE=1 - 1020's raise fix must stay on, or pid 1's genuine udf loops forever again (8183x measured) and 1026 would measure a different frontier"; exit 1; }
grep -q '^STAGE90_XNU_UNDEF_DIRECT=1$' "$REC" || {
  echo "REFUSING: the record does not carry STAGE90_XNU_UNDEF_DIRECT=1 - without the direct channel the udf witness can be silenced by the cap before the frontier (the 1017/1018 instrument defect)"; exit 1; }
# GLOBAL_FIX is a POOL switch declared only in the arm-extra drop-in (records/1020-build-defect.txt); it
# cannot be in the record.  **THE GREP BELOW IS THE PROCESS CHECK, NOT THE PROOF** - the by-value
# fingerprint below is what certifies the fix is in the pool object
# ([[mi4-self-written-record-is-not-a-constraint]]).
grep -qx 'STAGE90_XNU_GLOBAL_FIX=1 role=1026-abt-entry-probe' "$LIVE/xnu_arm_entry-arm-extra.txt" || {
  echo "REFUSING: out/stage90/xnu_arm_entry-arm-extra.txt does not carry 'STAGE90_XNU_GLOBAL_FIX=1 role=1026-abt-entry-probe' (it holds: '$(cat "$LIVE/xnu_arm_entry-arm-extra.txt" 2>/dev/null)') - the pool fix that keeps the retry storm gone is not declared by THIS build (build_1026.sh writes this line at its tail)"; exit 1; }
EXPECT_ARM=armed-d13-$(sha256sum "$LIVE/xnu_arm_entry.bin" | cut -c1-8)
echo "   arm = $EXPECT_ARM"

# BY VALUE (0-POOL): the inherited GLOBAL-FIX (1015b) is in the pool object the linked image was built
# from - `pmap_flush_tlbs` materializes `kernel_pmap` EXACTLY 3 times (OFF/Apple = 2).  1026 rebuilds the
# WHOLE pool (trap.c/kern_exec.c are POOL objects), so the 1020 defect (a record-derived EXTRA dropping
# the GLOBAL_FIX token) is available again.  It also proves the arm is the same 1024-shaped arm whose
# launchctl fault 1026 exists to name.
_gf_obj=out/xnu_kernel_obj_d13/osfmk_arm_pmap.o
[[ -f "$_gf_obj" ]] || { echo "REFUSING: $_gf_obj is absent - 1015b's GLOBAL-FIX cannot be certified"; exit 1; }
_gf_kp=$(arm-none-eabi-objdump -r "$_gf_obj" 2>/dev/null | awk '$1>="00000418" && $1<="00000640"' | grep -c 'MOVW_ABS_NC.*kernel_pmap' || true)
_gf_full=$(arm-none-eabi-objdump -r "$_gf_obj" 2>/dev/null | awk '$1>="00000418" && $1<="00000640"' | grep -c 'R_ARM_CALL.*arm_tlb_flushID$' || true)
_gf_asid=$(arm-none-eabi-objdump -r "$_gf_obj" 2>/dev/null | awk '$1>="00000418" && $1<="00000640"' | grep -c 'R_ARM_CALL.*arm_tlb_flushID_ASID$' || true)
[[ "$_gf_kp" == "3" && "$_gf_full" == "1" && "$_gf_asid" == "1" ]] || {
  echo "REFUSING: pmap_flush_tlbs materializes kernel_pmap x$_gf_kp (want 3), arm_tlb_flushID x$_gf_full / arm_tlb_flushID_ASID x$_gf_asid (want 1/1) - GLOBAL-FIX is NOT in the pool object, so the retry storm 1015b killed is BACK and the run would never reach the launchctl fault this rung exists to name. Re-run scripts/build_1026.sh."; exit 1; }
echo "   (0-POOL) by value: pmap_flush_tlbs carries the 3rd kernel_pmap materialization ($_gf_kp sites) and the 1/1 flush arms - 1015b's GLOBAL-FIX IS in the pool object this image was built from"

# BY VALUE (0a): THE RUNG'S OWN CLAIM - THE DISCRIMINATOR IS IN THE TWO POOL OBJECTS.  This is 1026's
# substance: without it the press captures NOTHING that separates H1 from H2.  The fingerprints are a
# FORMAT STRING (trap.o) and a SYMBOL (kern_exec.o), read by `strings` (the 1026 build's 5a clause), so
# a record that says 1 over a pool that carries neither is a refusal (the records/1020-build-defect.txt
# shape).  It also re-reads 1025's two survivors: 1026's block is NESTED inside 1025's, so a build that
# dropped the parent gate would leave the discriminator compiled-out ([[mi4-one-file-many-rungs]]).
[[ -f tools/check_1026_capture.py ]] || {
  echo "REFUSING: tools/check_1026_capture.py is ABSENT - it is this press's capture reader and its by-value claim's checker, and there is no sound fallback. A press that skipped it could not adjudicate the pre-registered H1/H2/H-OTHER cells"; exit 1; }
_trap_obj=out/xnu_kernel_obj_d13/osfmk_arm_trap.o
_exec_obj=out/xnu_kernel_obj_d13/bsd_kern_kern_exec.o
[[ -f "$_trap_obj" ]] || { echo "REFUSING: $_trap_obj is absent - trap.c is where xnu_live_abt_lookup_far=* lives, and a press whose trap.o is missing cannot discriminate the fault"; exit 1; }
[[ -f "$_exec_obj" ]] || { echo "REFUSING: $_exec_obj is absent - kern_exec.c is where xnu_live_abt_proc_ustack lives, and a press whose kern_exec.o is missing cannot read user_stack (H1's 4th conjunct)"; exit 1; }
grep -qa '^xnu_live_abt_lookup_far=' <(strings "$_trap_obj") || {
  echo "REFUSING: $_trap_obj carries NO xnu_live_abt_lookup_far= publisher - the pool was NOT recompiled with STAGE90_XNU_ABT_ENTRY_PROBE=1 (the env -> global DEFINES channel of build_xnu_arm_kernel.sh) or the trap.c edit is not staged. The discrimination would NOT be published, so this press would capture nothing that separates H1 from H2. Re-run scripts/build_1026.sh"; exit 1; }
grep -qa '^xnu_live_abt_proc_ustack$' <(strings "$_exec_obj") || {
  echo "REFUSING: $_exec_obj carries NO xnu_live_abt_proc_ustack symbol - the pool was NOT recompiled with STAGE90_XNU_ABT_ENTRY_PROBE=1 or the kern_exec.c edit is not staged. H1's `ustack == far` conjunct could not be read. Re-run scripts/build_1026.sh"; exit 1; }
grep -qa '^xnu_live_abt_vmfkrv=' <(strings "$_trap_obj") || {
  echo "REFUSING: $_trap_obj lost 1025's xnu_live_abt_vmfkrv= publisher in this pool rebuild - 1026's block is NESTED inside 1025's, so the discriminator would never run and the FAULT-NAMED co-reading would be gone ([[mi4-one-file-many-rungs]]). Re-run scripts/build_1026.sh"; exit 1; }
grep -qa '^xnu_live_ustack_req=' <(strings "$_exec_obj") || {
  echo "REFUSING: $_exec_obj lost 1025's xnu_live_ustack_req= publisher in this pool rebuild - 1026 builds ON 1025, not over it. Re-run scripts/build_1026.sh"; exit 1; }
echo "   (0a) by value: trap.o carries the xnu_live_abt_lookup_far= publisher AND 1025's xnu_live_abt_vmfkrv=; kern_exec.o carries the xnu_live_abt_proc_ustack accessor AND 1025's xnu_live_ustack_req= (the discriminator AND its parent are in the pool objects)"

# 0a-0. the checker's OWN self-test - a checker that cannot fail is not a check
# ([[mi4-a-claim-in-a-comment-is-not-a-check]]).
python3 -I tools/check_1026_capture.py --selftest >/dev/null 2>&1 || {
  echo "REFUSING: tools/check_1026_capture.py --selftest did NOT PASS - the checker cannot certify anything (an inert checker would bless any capture)"; exit 1; }
echo "   (0a-0) by value: tools/check_1026_capture.py --selftest PASSes (the checker is live; FAULT-NAMED / H1 / H2 / H-OTHER / REGRESSION / G-CTL / NO-CELL arms all exercise)"

# BY VALUE (0b): the inherited 1024 ceiling claim still holds on the LINKED image - 1026 ADDS ONLY THE
# DISCRIMINATOR, so `task_create_internal` must still pass 0x40000000 to `vm_map_create`.
# Read on the LINKED image, because build_entry.sh only LINKS the pool objects (a stale object hides the
# old ceiling; records/1020-build-defect.txt).
[[ -f tools/check_vm_max_split.py ]] || {
  echo "REFUSING: tools/check_vm_max_split.py is ABSENT - it is the inherited 1024 claim's by-value check on the linked image's task-map ceiling, and there is no sound fallback"; exit 1; }
python3 -I tools/check_vm_max_split.py --selftest >/dev/null 2>&1 || {
  echo "REFUSING: tools/check_vm_max_split.py --selftest did NOT PASS - the inherited ceiling checker cannot certify anything"; exit 1; }
python3 -I tools/check_vm_max_split.py "$LIVE/xnu_arm_entry.elf" --expect on >/dev/null 2>&1 || {
  echo "REFUSING: the LINKED image's task_create_internal does NOT pass 0x40000000 to vm_map_create - either 1024's widened vm_param.h:63 line did not reach the pool (the env -> global DEFINES channel), or a STALE pool object was linked (build_entry.sh only LINKS it). The task map's ceiling would then read 0x80000000 and this press would re-measure 1023's storm. Re-run scripts/build_1026.sh"; exit 1; }
echo "   (0b) by value: the LINKED image's task_create_internal passes 0x40000000 to vm_map_create (1024's ceiling is intact)"

# 0b-2. THE DISCRIMINATING CONTROL.  The SAME checker, `--expect off`, on a FROZEN arm whose ceiling is
# the PRE-SPLIT value 0x80000000 - i.e. an arm built BEFORE 1024's vm_param.h:63 widening.  The 1023 arm
# (armed-d13-10b79e5d, role=1023-trap24, VM_MAX_SPLIT UNSET) is exactly that arm: it reads 0x80000000
# and PASSes --expect off.  The (10b79e5d -> off PASS, this arm -> on PASS) pair is what proves the
# checker DISCRIMINATES rather than reporting one constant in both directions.
#
# **NOT THIS RUNG'S OWN ARM.** A control taken on the arm the FIX produced (or on 1026's own arm) agrees
# with the test and proves only that the checker says one thing (the mis-named-control class).  The
# control must be a PRE-1024 arm - 10b79e5d, as press_1025.sh used.  If 10b79e5d's park is absent the
# clause SKIPS (this press must not hard-depend on a park).
_ctrl=$LIVE/frozen/armed-d13-10b79e5d/xnu_arm_entry.elf
if [[ -s $_ctrl ]]; then
  python3 -I tools/check_vm_max_split.py "$_ctrl" --expect off >/dev/null 2>&1 || {
    echo "REFUSING: the frozen 1023 elf (10b79e5d)'s ceiling does NOT read 0x80000000 in the --expect off direction - the checker is either broken or pointed at the wrong immediate, so the 'on' PASS above certifies nothing. A control that agrees with the test proves only that the checker says one thing"; exit 1; }
  echo "   (0b-2) by value: NEGATIVE CONTROL - the frozen 1023 elf (10b79e5d, PRE-SPLIT) reads the ceiling == 0x80000000 (--expect off PASSes), so the 'on' above is a reading and not a constant"
else
  echo "   (0b-2) SKIP: the frozen 1023 elf ($_ctrl) is absent - the pre-split park does not exist here, so this press does not hard-depend on it. The 'on' PASS above still stands; the discriminating control can be taken once a pre-split arm is parked"
fi

# BY VALUE (0c): the inherited 1021d NEON-free claim still holds on the LINKED image - 1026 recompiles
# the WHOLE pool (trap.c/kern_exec.c), so the -msoft-float flag must still reach every object.
[[ -f tools/check_d13_no_neon.py ]] || { echo "REFUSING: tools/check_d13_no_neon.py is ABSENT - the inherited 1021d claim's by-value check"; exit 1; }
python3 -I tools/check_d13_no_neon.py --selftest >/dev/null 2>&1 || { echo "REFUSING: tools/check_d13_no_neon.py --selftest did NOT PASS"; exit 1; }
python3 -I tools/check_d13_no_neon.py "$LIVE/xnu_arm_entry.elf" --symbol mach_msg_send --expect none >/dev/null 2>&1 || {
  echo "REFUSING: the LINKED image's mach_msg_send still contains FP/NEON instructions - 1021d's -msoft-float flag did not reach the object the linker saw, or a STALE pool object was linked. Re-run scripts/build_1026.sh"; exit 1; }
echo "   (0c) by value: the LINKED image's mach_msg_send is NEON-free (1021d's -msoft-float holds)"

# BY VALUE (0d): the inherited 1020 raise claim still holds on the LINKED image.
[[ -f tools/check_d13_undef_raise.py ]] || { echo "REFUSING: tools/check_d13_undef_raise.py is ABSENT"; exit 1; }
python3 -I tools/check_d13_undef_raise.py "$LIVE/xnu_arm_entry.elf" --expect on >/dev/null 2>&1 || {
  echo "REFUSING: tools/check_d13_undef_raise.py \"$LIVE/xnu_arm_entry.elf\" --expect on did NOT pass - the linked image's sleh_undef does not carry 1020's moved \`return\`, so the udf loop is back. Re-run scripts/build_1026.sh"; exit 1; }
echo "   (0d) by value: tools/check_d13_undef_raise.py --expect on PASSes (1020's raise is intact)"

# BY VALUE (0e): the inherited 1023 row-24 claim still holds on the LINKED image - 1026 ADDS ONLY THE
# DISCRIMINATOR, so `mach_trap_table[24]` must still be the construct handler with rows 25/41/42 still
# kern_invalid (the composition this rung inherits unchanged).
[[ -f tools/check_1023_trap24.py ]] || { echo "REFUSING: tools/check_1023_trap24.py is ABSENT - it is the inherited 1023 claim's by-value check on the linked image (build_1023's row 24)"; exit 1; }
python3 -I tools/check_1023_trap24.py --selftest >/dev/null 2>&1 || { echo "REFUSING: tools/check_1023_trap24.py --selftest did NOT PASS - the inherited row-24 checker cannot certify anything"; exit 1; }
python3 -I tools/check_1023_trap24.py "$LIVE/xnu_arm_entry.elf" --expect on >/dev/null 2>&1 || {
  echo "REFUSING: the LINKED image's mach_trap_table[24] is NOT the ios7lab_mach_port_construct_trap row any more (or rows 25/41/42 moved) - 1026 adds only the discriminator and must ADD nothing else; with the row gone the 1023 frontier is back and this press would measure the wrong wall. Re-run scripts/build_1026.sh"; exit 1; }
echo "   (0e) by value: the LINKED image's mach_trap_table[24] IS the ios7lab_mach_port_construct_trap row (arg_count=5, rows 25/41/42 still kern_invalid)"

# BY VALUE (0f): the probe IS in the LINKED image - the discriminator's format string AND 1025's
# publisher must be reachable from the ELF (an object carrying them that the linker DROPPED would leave
# the arm's claim unmet; the 1026 build's 6b clause reads the same).
grep -qa '^xnu_live_abt_lookup_far=' <(strings "$LIVE/xnu_arm_entry.elf") || {
  echo "REFUSING: the LINKED $LIVE/xnu_arm_entry.elf carries NO xnu_live_abt_lookup_far= string - the pool object that has it was not linked, so the press would capture nothing that separates H1 from H2. Re-run scripts/build_1026.sh"; exit 1; }
grep -qa '^xnu_live_abt_vmfkrv=' <(strings "$LIVE/xnu_arm_entry.elf") || {
  echo "REFUSING: the LINKED $LIVE/xnu_arm_entry.elf carries NO xnu_live_abt_vmfkrv= string - the pool object that has it was not linked, so the FAULT-NAMED co-reading is impossible. Re-run scripts/build_1026.sh"; exit 1; }
echo "   (0f) by value: the LINKED image carries the xnu_live_abt_lookup_far= discriminator AND 1025's xnu_live_abt_vmfkrv= publisher (the probe reached the image the press boots)"

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
# 1026 is a RESIDENT rung: if it does not return it keeps NO /proc/last_kmsg of its own, so start the
# HOST reader FIRST; it attaches the moment the payload enumerates. Primary channel: step 4.
USB_OUT="out/stage90/captures/usb-console-1026-$(date -u +%Y%m%d-%H%M%S).txt"
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

echo "== 5. read the recovered capture: run the 1026 reader and print its cell =="
# **THE READING IS TAKEN HERE, OR NOWHERE.**  The recovered run's own log is the reading of this rung's
# question ([[mi4-last-kmsg-reader-carrier]]), so the LAST step invokes the reader on the NEWEST
# recovered `last_kmsg` and PRINTS the cell.  The reader's exit is NOT this press's exit: `G-CTL`
# legitimately exits 1 (WITHHOLD), and a WITHHOLD is a reading of the instrument, not a failed press -
# so the invocation is wrapped and its status reported, never propagated ([[mi4-silence-is-a-reading]]).
_last=$(ls -1t out/stage90/captures/recovered-*-last_kmsg.txt 2>/dev/null | head -1 || true)
if [[ -n $_last ]]; then
  echo "   reading the NEWEST recovered capture: $_last"
  echo "   (its byte-identity to the 1025 crash family is the check that the slot was re-written this run:"
  echo "    if $_last still matches the 1025 press's own log, the run did NOT re-write the ram-console slot"
  echo "    and this is the stale slot, not the 1026 press's own boot)"
  set +e
  python3 -I tools/check_1026_capture.py "$_last"
  _rd_rc=$?
  set -e
  echo "   (reader exit $_rd_rc; 0 = a cell fired, 1 = G-CTL/WITHHOLD - both are readings)"
else
  echo "   NO recovered capture found under out/stage90/captures/recovered-*-last_kmsg.txt - there is"
  echo "   nothing to read; the run's log did not reach a recovery. Read records/1025-press-read.txt and"
  echo "   re-run the recovery once the phone is visible ([[mi4-device-dark-needs-power-press]])"
fi

echo "== DONE =="
echo "   adjudicate against docs/1026-design.md section 4:"
echo "     G-CTL        neither launchd-reached nor any prior control (trap24 / vmfkrv) is live AND no"
echo "                  panic => WITHHOLD (fail closed; an unsound instrument cannot read an absence)"
echo "     FAULT-NAMED  the 1025 re-reading still HOLDS (a xnu_live_abt_vmfkrv row with vmfkrv=1 on a far"
echo "                  in the stack window [0x2BD00000, 0x2BE00000)) => the discriminator is asked about"
echo "                  the RIGHT fault and is worth reading"
echo "     H1           xnu_live_abt_lookup_far=0 AND far_in_map=0 AND map != taskmap AND ustack == far =>"
echo "                  WRONG MAP"
echo "     H2           xnu_live_abt_lookup_far=0 AND far_in_map=1 AND entry_hi == far AND map == taskmap"
echo "                  => OFF-THE-END"
echo "     H-OTHER      any other combination => report it; pick NO fix (fail closed); 1027 instruments it"
echo "     REGRESSION   the 1024 controls regressed (the 1023 storm returns, or trap24 / port_construct"
echo "                  result=0 vanish) => the arm's switch set is wrong, not the fix"
echo "     NO-CELL      nothing in the table fired (report what was present; never fabricate)"
echo "   Machine check: python3 -I tools/check_1026_capture.py <capture>"
echo "   Read the 1025 reading beside it: records/1025-press-read.txt (the fault this rung exists to"
echo "   explain) and records/1025-globalfix-carrier.txt section 6 (the arm identity settlement)."