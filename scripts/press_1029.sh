#!/usr/bin/env bash
# ====================================================================================================
# press_1028.sh.  MODELLED ON scripts/press_1027.sh (itself the RESIDENT-rung press: the USB console
# reader + the /proc/last_kmsg recovery).
#
# Press 1028: THE H2 FIX - GIVE THE INITIAL USER-STACK BLOCK ONE WORD OF HEADROOM, so the region's
# EXCLUSIVE TOP moves to `user_stack + 16` and the top word userspace touches is OWNED.  Switch: **ONE
# NEW: STAGE90_XNU_H2_STACK_HEADROOM=1** (1027's set VERBATIM otherwise).  Design: docs/1028-design.md.
#
# THE ONE QUESTION THIS RUNG DECIDES.  1027's press RAN and its own console was recovered
# (records/1027-press-read.txt).  The reading is **H2 (off-the-end)**, by value, at the launchctl[2]
# stack fault:
#     lookup_far=0  far_in_map=1  entry=[0,0)  e2=[0x2bce1000,0x2bde0000)
#     e2_hi == far == ustack == 0x2bde0000     map == taskmap == 0xc0005688
# The user-stack region is `[0x2bce1000, 0x2bde0000)` and its EXCLUSIVE TOP IS `far`; the word just below
# (`far-4`) IS in the map.  H1 (wrong map) is refuted by value (`map == taskmap`).  By source,
# `create_unix_stack` sets `p->user_stack` to the requested top and allocates `[user_stack - size,
# user_stack)`, and `exec_copyout_strings` places the initial argv/env block with its TOP at
# `p->user_stack` - so the word AT `user_stack` is UNOWNED and userspace's touch of it faults.  1028
# gives the region ONE WORD (16 B) of headroom by allocating `size + 16` in the FIXED `mach_vm_allocate`:
# the region's exclusive top becomes `user_stack + 16`, the block base, `sp`, `p->user_stack`, and the
# guard math are UNCHANGED.
#
# THE PRE-REGISTERED CELLS (docs/1029-design.md section 4; read by tools/check_1029_capture.py):
#   FIX-HOLDS    - the launchctl[2] data abort at `far == p->user_stack` is GONE (0 rows with
#                  xnu_live_abt_vmfkrv=1 on a far in the stack window) AND launchd still starts
#                  (*** launchd[1] has started up ***) AND the next frontier is NAMED by the existing rows
#   FIX-NOOP     - the same abort at the same `far - sp == 0xF8C` recurs => the top word was not the
#                  cause; report, do not re-fix
#   REGRESSION   - trap24 / port_construct(result=0) vanish, or a panic appears => the +16 moved
#                  something the guard math depended on; report and revert
#   G-CTL        - launchd never reached and no prior control live => WITHHOLD (fail closed)
#   e2_hi        - must now read `far + 16` (the region's new exclusive top) if the fix landed; if it
#                  still reads `far`, the allocation edit did not take effect (a build defect)
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

echo "== 0. the record must be 1028's arm =="
# 1028's own new switch: the H2 fix (kern_exec.c's create_unix_stack FIXED extent = size + 16) is gated
# by STAGE90_XNU_H2_STACK_HEADROOM, and it is ALSO the readability carrier (there is no other trace of
# the fix on the object, so a record without it means the pool was built with the FIXED extent SHUT and
# the launchctl[2] fault would recur at the same far).
grep -q '^STAGE90_XNU_H2_STACK_HEADROOM=1$' "$REC" || {
  echo "REFUSING: the record does not carry STAGE90_XNU_H2_STACK_HEADROOM=1 - the H2 fix this rung IS is gated by THIS switch (kern_exec.c's create_unix_stack allocates size + 16). Its absence means the pool was built with the FIXED extent SHUT, so the launchctl[2] fault would recur at the same far and this press would not be a reading of THIS rung. Build it with scripts/build_1028.sh first"; exit 1; }
# 1027's switch, CARRIED VERBATIM: the fix's cells are read beside its xnu_live_abt_* rows, so a record
# without STAGE90_XNU_ABT_ENTRY_PROBE=1 means the pool was built with the discriminator SHUT and the
# capture would be silent on WHETHER the fix held.
grep -q '^STAGE90_XNU_ABT_ENTRY_PROBE=1$' "$REC" || {
  echo "REFUSING: the record does not carry STAGE90_XNU_ABT_ENTRY_PROBE=1 - 1028 carries 1027's discriminator verbatim, and the FIX-HOLDS / FIX-NOOP cells are adjudicated from its xnu_live_abt_* rows. Its absence means the pool was built with the discriminator SHUT and the fix's own reading would be gone. Build it with scripts/build_1028.sh first"; exit 1; }
# 1025's PARENT switch: 1027's block (which 1028 carries) is NESTED INSIDE 1025's publisher (the fault
# path is SHARED: ONE gate for it), so a record without STAGE90_XNU_USTACK_PROBE=1 means the
# discriminator prints NOTHING - and the 1025 re-reading the reader depends on would be gone too.
grep -q '^STAGE90_XNU_USTACK_PROBE=1$' "$REC" || {
  echo "REFUSING: the record does not carry STAGE90_XNU_USTACK_PROBE=1 - 1027's discriminator (which 1028 carries) is NESTED INSIDE 1025's publisher block (the fault path is SHARED), so with the parent gate shut the seven reads never execute and the capture would be silent on the fix's question while the record says the probe is live ([[mi4-one-file-many-rungs]]). Build it with scripts/build_1028.sh first"; exit 1; }
# 1024's own switch: the widened vm_param.h:63 line reads STAGE90_XNU_VM_MAX_SPLIT, and it is what keeps
# the 1023 pthread storm away - the boot must reach launchctl for 1028 to have anything to read.
grep -q '^STAGE90_XNU_VM_MAX_SPLIT=1$' "$REC" || {
  echo "REFUSING: the record does not carry STAGE90_XNU_VM_MAX_SPLIT=1 - 1024's widened vm_param.h:63 line reads THIS switch. Its absence means the pool was built with the OLD ceiling (0x80000000), so the task map still reaches above the hardware's 1 GiB TTBR0 split and the 1023 storm recurs - the boot would never reach the launchctl abort 1028 exists to fix. Build it with scripts/build_1028.sh first"; exit 1; }
# 1023's row-24 gate reads STAGE90_XNU_IOS7_TRAPS; 1028 ADDS ONLY THE H2 FIX, so trap 24 must
# still be installed or the 1023 frontier (libxpc's port-allocation udf) is back.
grep -q '^STAGE90_XNU_IOS7_TRAPS=1$' "$REC" || {
  echo "REFUSING: the record does not carry STAGE90_XNU_IOS7_TRAPS=1 - 1023's row-24 gate widens to read THIS switch. Its absence means the pool was built without -DSTAGE90_XNU_IOS7_TRAPS=1, so row 24 stays kern_invalid, libxpc's port-allocation udf recurs, and this rung would measure the 1023 frontier instead of the launchctl stack fault it exists to fix (build it with scripts/build_1028.sh first)"; exit 1; }
# The inherited switches this arm's set carries VERBATIM (1021d's set).
grep -q '^STAGE90_XNU_GENERAL_REGS=1$' "$REC" || {
  echo "REFUSING: the record does not carry STAGE90_XNU_GENERAL_REGS=1 - 1021d's -msoft-float flag must stay on, or the kernel-mode NEON undef at 0x8047b0ac returns and this rung would measure a different frontier"; exit 1; }
grep -q '^STAGE90_XNU_UNDEF_RAISE=1$' "$REC" || {
  echo "REFUSING: the record does not carry STAGE90_XNU_UNDEF_RAISE=1 - 1020's raise fix must stay on, or pid 1's genuine udf loops forever again (8183x measured) and 1028 would measure a different frontier"; exit 1; }
grep -q '^STAGE90_XNU_UNDEF_DIRECT=1$' "$REC" || {
  echo "REFUSING: the record does not carry STAGE90_XNU_UNDEF_DIRECT=1 - without the direct channel the udf witness can be silenced by the cap before the frontier (the 1017/1018 instrument defect)"; exit 1; }
# GLOBAL_FIX is a POOL switch declared only in the arm-extra drop-in (records/1020-build-defect.txt); it
# cannot be in the record.  **THE GREP BELOW IS THE PROCESS CHECK, NOT THE PROOF** - the by-value
# fingerprint below is what certifies the fix is in the pool object
# ([[mi4-self-written-record-is-not-a-constraint]]).
grep -qx 'STAGE90_XNU_GLOBAL_FIX=1 role=1029-reader-probe' "$LIVE/xnu_arm_entry-arm-extra.txt" || {
  echo "REFUSING: out/stage90/xnu_arm_entry-arm-extra.txt does not carry 'STAGE90_XNU_GLOBAL_FIX=1 role=1029-reader-probe' (it holds: '$(cat "$LIVE/xnu_arm_entry-arm-extra.txt" 2>/dev/null)') - the pool fix that keeps the retry storm gone is not declared by THIS build (build_1029.sh writes this line at its tail)"; exit 1; }
EXPECT_ARM=armed-d13-$(sha256sum "$LIVE/xnu_arm_entry.bin" | cut -c1-8)
echo "   arm = $EXPECT_ARM"

# BY VALUE (0-POOL): the inherited GLOBAL-FIX (1015b) is in the pool object the linked image was built
# from - `pmap_flush_tlbs` materializes `kernel_pmap` EXACTLY 3 times (OFF/Apple = 2).  1028 rebuilds the
# WHOLE pool (kern_exec.c is a POOL object), so the 1020 defect (a record-derived EXTRA dropping
# the GLOBAL_FIX token) is available again.  It also proves the arm is the same 1024-shaped arm whose
# launchctl fault 1028 exists to fix.
_gf_obj=out/xnu_kernel_obj_d13/osfmk_arm_pmap.o
[[ -f "$_gf_obj" ]] || { echo "REFUSING: $_gf_obj is absent - 1015b's GLOBAL-FIX cannot be certified"; exit 1; }
_gf_kp=$(arm-none-eabi-objdump -r "$_gf_obj" 2>/dev/null | awk '$1>="00000418" && $1<="00000640"' | grep -c 'MOVW_ABS_NC.*kernel_pmap' || true)
_gf_full=$(arm-none-eabi-objdump -r "$_gf_obj" 2>/dev/null | awk '$1>="00000418" && $1<="00000640"' | grep -c 'R_ARM_CALL.*arm_tlb_flushID$' || true)
_gf_asid=$(arm-none-eabi-objdump -r "$_gf_obj" 2>/dev/null | awk '$1>="00000418" && $1<="00000640"' | grep -c 'R_ARM_CALL.*arm_tlb_flushID_ASID$' || true)
[[ "$_gf_kp" == "3" && "$_gf_full" == "1" && "$_gf_asid" == "1" ]] || {
  echo "REFUSING: pmap_flush_tlbs materializes kernel_pmap x$_gf_kp (want 3), arm_tlb_flushID x$_gf_full / arm_tlb_flushID_ASID x$_gf_asid (want 1/1) - GLOBAL-FIX is NOT in the pool object, so the retry storm 1015b killed is BACK and the run would never reach the launchctl fault this rung exists to fix. Re-run scripts/build_1028.sh."; exit 1; }
echo "   (0-POOL) by value: pmap_flush_tlbs carries the 3rd kernel_pmap materialization ($_gf_kp sites) and the 1/1 flush arms - 1015b's GLOBAL-FIX IS in the pool object this image was built from"

# BY VALUE (0a): THE RUNG'S OWN CLAIM - THE H2 FIX IS IN THE POOL OBJECT.  This is 1028's substance:
# without it the press boots an image whose create_unix_stack still allocates the FIXED extent as plain
# `size`, and the launchctl[2] fault recurs at the same far (the records/1020-build-defect.txt shape).
#
# **THE FIX HAS NO STRING FINGERPRINT.**  Unlike its USTACK_PROBE/ABT_ENTRY_PROBE siblings, 1028's edit
# is a VALUE change - the FIXED `mach_vm_allocate` extent becomes `size + 16` - so the compiler emits no
# format string and no new symbol, and the entry bin's hash is IDENTICAL with the switch on and off (the
# record is the ONLY place the arm appears).  Fabricating a "fingerprint string" would be a check that
# cannot fail, so the target-side gate is two honest halves instead:
#   (i)  the SOURCE the pool was built from carries the switch AND the `size + 16` extent and the
#        patcher's own `#endif` marker (read from the staged tree), and
#   (ii) the pool's OWN source-content record (out/xnu_kernel_src_d13.sha256, written by
#        tools/gen_kernel_source_manifest.py) names the SAME sha256 for that file.
# A stale pool object (built before the fix) fails (ii): the record hashes the PRE-fix content, which no
# longer matches the staged file.  This is the same gate build_1028.sh's 5a clause runs.
[[ -f tools/check_1029_capture.py ]] || {
  echo "REFUSING: tools/check_1029_capture.py is ABSENT - it is this press's capture reader and its by-value claim's checker, and there is no sound fallback. A press that skipped it could not adjudicate the pre-registered FIX-HOLDS/FIX-NOOP/REGRESSION cells"; exit 1; }
_ke_src=$PWD/external/xnu-hd2-darwin13/xnu/bsd/kern/kern_exec.c
_src_rec=out/xnu_kernel_src_d13.sha256
[[ -f $_ke_src ]] || { echo "REFUSING: $_ke_src is absent - the staged kern_exec.c is where 1028's fix lives, and a press that cannot read it cannot certify the fix is in the pool"; exit 1; }
[[ -f $_src_rec ]] || { echo "REFUSING: $_src_rec is absent - the pool's own source-content record is the ONLY by-value witness 1028's value-only fix has (it has no format string, so no `strings` fingerprint can exist). Without it the fix cannot be certified present. Re-run scripts/build_1028.sh"; exit 1; }
# (i) the staged source carries the switch, the patched extent, and the patcher's marker, EXACTLY once.
grep -q 'defined(STAGE90_XNU_H2_STACK_HEADROOM) && STAGE90_XNU_H2_STACK_HEADROOM' "$_ke_src" || {
  echo "REFUSING: $_ke_src does not carry the STAGE90_XNU_H2_STACK_HEADROOM gate - tools/patch_d13_h2_stack_headroom.py was not staged into the tree, so the pool the linker saw was built WITHOUT the fix (build_entry.sh only LINKS pool objects) and the launchctl[2] fault would recur at the same far. Re-run scripts/build_1028.sh"; exit 1; }
_hr16=$(grep -c 'mach_vm_allocate(map, &addr, size + 16,' "$_ke_src" || true)
_hr_end=$(grep -c '^#endif /\* STAGE90_XNU_H2_STACK_HEADROOM \*/' "$_ke_src" || true)
[[ "$_hr16" == "1" && "$_hr_end" == "1" ]] || {
  echo "REFUSING: $_ke_src carries the size + 16 extent x$_hr16 and the patcher's #endif marker x$_hr_end (want 1/1) - a partial or DOUBLE edit is exactly what the patcher REFUSES on, so the source is in a state no build of this rung produced. Re-stage with tools/stage_d13_h2_stack_headroom.sh"; exit 1; }
# (ii) BY VALUE ON THE OBJECT: the pool's own source-content record names THIS content.
_ke_want=$(sha256sum "$_ke_src" | awk '{print $1}')
_ke_have=$(awk -v p="$_ke_src" '$2==p{print $1}' "$_src_rec" | head -1)
[[ -n "$_ke_have" ]] || {
  echo "REFUSING: $_src_rec names NO entry for $_ke_src - the pool's manifest does not cover kern_exec.c, so the fix's content is unrecorded and cannot be certified (the record of record is written by tools/gen_kernel_source_manifest.py; ask who writes the file, [[mi4-self-written-record-is-not-a-constraint]]). Re-run scripts/build_1028.sh"; exit 1; }
[[ "$_ke_want" == "$_ke_have" ]] || {
  echo "REFUSING: $_ke_src hashes $_ke_want but the pool's source-content record says $_ke_have - the pool object was compiled from DIFFERENT content than the tree holds now ([[mi4-self-written-record-is-not-a-constraint]]: the record is written by the build that compiles, so a mismatch means the staged fix is NOT in the object the linker saw). Re-run scripts/build_1028.sh"; exit 1; }
echo "   (0a) by value: the staged kern_exec.c carries the STAGE90_XNU_H2_STACK_HEADROOM gate with the size + 16 extent (x1) and the patcher's #endif marker (x1), AND the pool's own source-content record names the SAME sha256 ($_ke_want) - the H2 fix IS in the object the linked image was built from"

# 0a-1. THE INHERITED DISCRIMINATOR IS STILL IN THE TWO POOL OBJECTS (1027's substance, carried
# VERBATIM).  1028 does not remove it: the FIX-HOLDS / FIX-NOOP cells are adjudicated FROM its
# xnu_live_abt_* rows.  The fingerprints are a FORMAT STRING (trap.o) and a SYMBOL (kern_exec.o).  It
# also re-reads 1025's two survivors: 1027's block is NESTED inside 1025's, so a build that dropped the
# parent gate would leave the discriminator compiled-out ([[mi4-one-file-many-rungs]]).
_trap_obj=out/xnu_kernel_obj_d13/osfmk_arm_trap.o
_exec_obj=out/xnu_kernel_obj_d13/bsd_kern_kern_exec.o
[[ -f "$_trap_obj" ]] || { echo "REFUSING: $_trap_obj is absent - trap.c is where xnu_live_abt_lookup_far=* lives, and a press whose trap.o is missing cannot adjudicate whether the fix held"; exit 1; }
[[ -f "$_exec_obj" ]] || { echo "REFUSING: $_exec_obj is absent - kern_exec.c is where xnu_live_abt_proc_ustack lives, and a press whose kern_exec.o is missing cannot read user_stack (the far the fix must move)"; exit 1; }
grep -qa '^xnu_live_abt_lookup_far=' <(strings "$_trap_obj") || {
  echo "REFUSING: $_trap_obj carries NO xnu_live_abt_lookup_far= publisher - the pool was NOT recompiled with STAGE90_XNU_ABT_ENTRY_PROBE=1 (the env -> global DEFINES channel of build_xnu_arm_kernel.sh) or the trap.c edit is not staged. The FIX-HOLDS/FIX-NOOP cells would have nothing to read. Re-run scripts/build_1028.sh"; exit 1; }
grep -qa '^xnu_live_abt_proc_ustack$' <(strings "$_exec_obj") || {
  echo "REFUSING: $_exec_obj carries NO xnu_live_abt_proc_ustack symbol - the pool was NOT recompiled with STAGE90_XNU_ABT_ENTRY_PROBE=1 or the kern_exec.c edit is not staged. The `far == ustack` conjunct that names the fixed fault could not be read. Re-run scripts/build_1028.sh"; exit 1; }
grep -qa '^xnu_live_abt_vmfkrv=' <(strings "$_trap_obj") || {
  echo "REFUSING: $_trap_obj lost 1025's xnu_live_abt_vmfkrv= publisher in this pool rebuild - 1027's block is NESTED inside 1025's, so the discriminator would never run and the FIX-HOLDS absence could not be read ([[mi4-one-file-many-rungs]]). Re-run scripts/build_1028.sh"; exit 1; }
grep -qa '^xnu_live_ustack_req=' <(strings "$_exec_obj") || {
  echo "REFUSING: $_exec_obj lost 1025's xnu_live_ustack_req= publisher in this pool rebuild - 1028 builds ON 1025/1027, not over them. Re-run scripts/build_1028.sh"; exit 1; }
echo "   (0a-1) by value: trap.o carries the xnu_live_abt_lookup_far= publisher AND 1025's xnu_live_abt_vmfkrv=; kern_exec.o carries the xnu_live_abt_proc_ustack accessor AND 1025's xnu_live_ustack_req= (1027's discriminator AND its parent are still in the pool objects)"

# 0a-0. the checker's OWN self-test - a checker that cannot fail is not a check
# ([[mi4-a-claim-in-a-comment-is-not-a-check]]).
python3 -I tools/check_1029_capture.py --selftest >/dev/null 2>&1 || {
  echo "REFUSING: tools/check_1029_capture.py --selftest did NOT PASS - the checker cannot certify anything (an inert checker would bless any capture)"; exit 1; }
echo "   (0a-0) by value: tools/check_1029_capture.py --selftest PASSes (the checker is live; FIX-HOLDS / FIX-NOOP / REGRESSION / G-CTL arms all exercise)"

# BY VALUE (0b): the inherited 1024 ceiling claim still holds on the LINKED image - 1028 ADDS ONLY THE
# H2 FIX, so `task_create_internal` must still pass 0x40000000 to `vm_map_create`.
# Read on the LINKED image, because build_entry.sh only LINKS the pool objects (a stale object hides the
# old ceiling; records/1020-build-defect.txt).
[[ -f tools/check_vm_max_split.py ]] || {
  echo "REFUSING: tools/check_vm_max_split.py is ABSENT - it is the inherited 1024 claim's by-value check on the linked image's task-map ceiling, and there is no sound fallback"; exit 1; }
python3 -I tools/check_vm_max_split.py --selftest >/dev/null 2>&1 || {
  echo "REFUSING: tools/check_vm_max_split.py --selftest did NOT PASS - the inherited ceiling checker cannot certify anything"; exit 1; }
python3 -I tools/check_vm_max_split.py "$LIVE/xnu_arm_entry.elf" --expect on >/dev/null 2>&1 || {
  echo "REFUSING: the LINKED image's task_create_internal does NOT pass 0x40000000 to vm_map_create - either 1024's widened vm_param.h:63 line did not reach the pool (the env -> global DEFINES channel), or a STALE pool object was linked (build_entry.sh only LINKS it). The task map's ceiling would then read 0x80000000 and this press would re-measure 1023's storm. Re-run scripts/build_1028.sh"; exit 1; }
echo "   (0b) by value: the LINKED image's task_create_internal passes 0x40000000 to vm_map_create (1024's ceiling is intact)"

# 0b-2. THE DISCRIMINATING CONTROL.  The SAME checker, `--expect off`, on a FROZEN arm whose ceiling is
# the PRE-SPLIT value 0x80000000 - i.e. an arm built BEFORE 1024's vm_param.h:63 widening.  The 1023 arm
# (armed-d13-10b79e5d, role=1023-trap24, VM_MAX_SPLIT UNSET) is exactly that arm: it reads 0x80000000
# and PASSes --expect off.  The (10b79e5d -> off PASS, this arm -> on PASS) pair is what proves the
# checker DISCRIMINATES rather than reporting one constant in both directions.
#
# **NOT THIS RUNG'S OWN ARM.** A control taken on the arm the FIX produced (or on 1028's own arm) agrees
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

# BY VALUE (0c): the inherited 1021d NEON-free claim still holds on the LINKED image - 1028 recompiles
# the WHOLE pool (trap.c/kern_exec.c), so the -msoft-float flag must still reach every object.
[[ -f tools/check_d13_no_neon.py ]] || { echo "REFUSING: tools/check_d13_no_neon.py is ABSENT - the inherited 1021d claim's by-value check"; exit 1; }
python3 -I tools/check_d13_no_neon.py --selftest >/dev/null 2>&1 || { echo "REFUSING: tools/check_d13_no_neon.py --selftest did NOT PASS"; exit 1; }
python3 -I tools/check_d13_no_neon.py "$LIVE/xnu_arm_entry.elf" --symbol mach_msg_send --expect none >/dev/null 2>&1 || {
  echo "REFUSING: the LINKED image's mach_msg_send still contains FP/NEON instructions - 1021d's -msoft-float flag did not reach the object the linker saw, or a STALE pool object was linked. Re-run scripts/build_1028.sh"; exit 1; }
echo "   (0c) by value: the LINKED image's mach_msg_send is NEON-free (1021d's -msoft-float holds)"

# BY VALUE (0d): the inherited 1020 raise claim still holds on the LINKED image.
[[ -f tools/check_d13_undef_raise.py ]] || { echo "REFUSING: tools/check_d13_undef_raise.py is ABSENT"; exit 1; }
python3 -I tools/check_d13_undef_raise.py "$LIVE/xnu_arm_entry.elf" --expect on >/dev/null 2>&1 || {
  echo "REFUSING: tools/check_d13_undef_raise.py \"$LIVE/xnu_arm_entry.elf\" --expect on did NOT pass - the linked image's sleh_undef does not carry 1020's moved \`return\`, so the udf loop is back. Re-run scripts/build_1028.sh"; exit 1; }
echo "   (0d) by value: tools/check_d13_undef_raise.py --expect on PASSes (1020's raise is intact)"

# BY VALUE (0e): the inherited 1023 row-24 claim still holds on the LINKED image - 1028 ADDS ONLY THE
# H2 FIX, so `mach_trap_table[24]` must still be the construct handler with rows 25/41/42 still
# kern_invalid (the composition this rung inherits unchanged).
[[ -f tools/check_1023_trap24.py ]] || { echo "REFUSING: tools/check_1023_trap24.py is ABSENT - it is the inherited 1023 claim's by-value check on the linked image (build_1023's row 24)"; exit 1; }
python3 -I tools/check_1023_trap24.py --selftest >/dev/null 2>&1 || { echo "REFUSING: tools/check_1023_trap24.py --selftest did NOT PASS - the inherited row-24 checker cannot certify anything"; exit 1; }
python3 -I tools/check_1023_trap24.py "$LIVE/xnu_arm_entry.elf" --expect on >/dev/null 2>&1 || {
  echo "REFUSING: the LINKED image's mach_trap_table[24] is NOT the ios7lab_mach_port_construct_trap row any more (or rows 25/41/42 moved) - 1028 adds only the H2 fix and must ADD nothing else; with the row gone the 1023 frontier is back and this press would measure the wrong wall. Re-run scripts/build_1028.sh"; exit 1; }
echo "   (0e) by value: the LINKED image's mach_trap_table[24] IS the ios7lab_mach_port_construct_trap row (arg_count=5, rows 25/41/42 still kern_invalid)"

# BY VALUE (0f): the probe IS in the LINKED image - the discriminator's format string AND 1025's
# publisher must be reachable from the ELF (an object carrying them that the linker DROPPED would leave
# the arm's claim unmet; the 1028 build's 6b clause reads the same).
grep -qa '^xnu_live_abt_lookup_far=' <(strings "$LIVE/xnu_arm_entry.elf") || {
  echo "REFUSING: the LINKED $LIVE/xnu_arm_entry.elf carries NO xnu_live_abt_lookup_far= string - the pool object that has it was not linked, so the FIX-HOLDS read would be blind. Re-run scripts/build_1028.sh"; exit 1; }
grep -qa '^xnu_live_abt_vmfkrv=' <(strings "$LIVE/xnu_arm_entry.elf") || {
  echo "REFUSING: the LINKED $LIVE/xnu_arm_entry.elf carries NO xnu_live_abt_vmfkrv= string - the pool object that has it was not linked, so the fix’s own co-reading is impossible. Re-run scripts/build_1028.sh"; exit 1; }
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
# 1028 is a RESIDENT rung: if it does not return it keeps NO /proc/last_kmsg of its own, so start the
# HOST reader FIRST; it attaches the moment the payload enumerates. Primary channel: step 4.
USB_OUT="out/stage90/captures/usb-console-1028-$(date -u +%Y%m%d-%H%M%S).txt"
tools/usb_console_read.py --out "$USB_OUT" --wait 600 --seconds 0 &
USB_PID=$!
echo "   (USB console reader armed: pid $USB_PID -> $USB_OUT)"
trap 'kill "$USB_PID" 2>/dev/null || true' EXIT

scripts/preflight_boot_check.sh --allow-xnu-entry
# **THE COMMAND LINE, PRINTED BEFORE IT IS ISSUED.** The SINGLE device write this press makes is
# `fastboot boot` of the payload - never `fastboot flash`.
    echo "   fastboot boot -s 4a2fe00b out/stage90/stage90-qcdt.img   (fastboot boot, NEVER flash)"
# **THE BOOT STAMP.**  Step 5 must refuse to adjudicate a capture OLDER than this boot: a resident rung
# that does not return keeps NO /proc/last_kmsg of its own, so the recovery reads whatever slot the LAST
# returning boot left ([[mi4-last-kmsg-reader-carrier]]).  Without this stamp the reader reports a cell
# that describes a DIFFERENT arm's boot (records/1028-press-read.txt: the 1028 press read the 1027 slot).
_BOOT_EPOCH=$(date +%s)
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
  # `wait` returns 128+signal (143 here, the EXIT trap's SIGTERM) when the reader was signaled rather
  # than exiting on its own; under `set -e` an UNGUARDED `wait` then ABORTS THE SCRIPT before the
  # capture check, the recovery, and the reading ever run.  That is exactly what truncated the 1024 and
  # 1027 press's log at the runner's line: the USB verdict step is the one that says whether the reader
  # saw the device, so losing it turned every non-returning press into "no way to tell".  `set +e`
  # around the wait keeps the script alive AND keeps the reader's real exit (0/2/3/-1 = the reading).
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

echo "== 5. read the recovered capture: run the 1028 reader and print its cell =="
# **THE READING IS TAKEN HERE, OR NOWHERE.**  The recovered run's own log is the reading of this rung's
# question ([[mi4-last-kmsg-reader-carrier]]), so the LAST step invokes the reader on the NEWEST
# recovered `last_kmsg` and PRINTS the cell.  The reader's exit is NOT this press's exit: `G-CTL`
# legitimately exits 1 (WITHHOLD), and a WITHHOLD is a reading of the instrument, not a failed press -
# so the invocation is wrapped and its status reported, never propagated ([[mi4-silence-is-a-reading]]).
_last=$(ls -1t out/stage90/captures/recovered-*-last_kmsg.txt 2>/dev/null | head -1 || true)
if [[ -n $_last ]]; then
  # **STALENESS GUARD: the capture MUST be newer than this press's boot.**  A resident rung that does
  # not return leaves no /proc/last_kmsg of its own, so the newest file can be a PREVIOUS boot's slot.
  # Adjudicating it would print a cell about a DIFFERENT arm (the 1028 press read the 1027 slot:
  # records/1028-press-read.txt).  Fail closed: print NO READING and stop, never run the checker.
  _last_epoch=$(stat -c %Y "$_last" 2>/dev/null || echo 0)
  if [[ -n ${_BOOT_EPOCH:-} && $_last_epoch -lt $_BOOT_EPOCH ]]; then
    echo "   NO READING - STALE SLOT: the newest capture is OLDER than this press's boot."
    echo "     capture: $_last"
    echo "     capture mtime: $(stat -c %y "$_last")   (epoch $_last_epoch)"
    echo "     this boot:     $(date -d "@$_BOOT_EPOCH" '+%Y-%m-%d %H:%M:%S%z' 2>/dev/null)   (epoch $_BOOT_EPOCH)"
    echo "   This run did NOT re-write the RAM-console slot (a resident rung that does not return keeps"
    echo "   none of its own), so this capture is a PREVIOUS boot's log.  Running the checker on it would"
    echo "   report a cell about a different arm ([[mi4-last-kmsg-reader-carrier]]).  NOT adjudicating."
    echo "   The device needs the OPERATOR's power press; then: scripts/recover_last_kmsg.sh --read-only"
    echo "   while Android is up, and re-run this reading ONLY on a capture newer than this boot."
    echo "   (NOT pressed again - the slot must not be cleared; do NOT fastboot boot anything first.)"
  else
  echo "   reading the NEWEST recovered capture: $_last"
  echo "   (its byte-identity to the 1025 crash family is the check that the slot was re-written this run:"
  echo "    if $_last still matches the 1025 press's own log, the run did NOT re-write the ram-console slot"
  echo "    and this is the stale slot, not the 1028 press's own boot)"
  set +e
  python3 -I tools/check_1029_capture.py "$_last"
  _rd_rc=$?
  set -e
  echo "   (reader exit $_rd_rc; 0 = a cell fired, 1 = G-CTL/WITHHOLD - both are readings)"
  fi
else
  echo "   NO recovered capture found under out/stage90/captures/recovered-*-last_kmsg.txt - there is"
  echo "   nothing to read; the run's log did not reach a recovery. Read records/1025-press-read.txt and"
  echo "   re-run the recovery once the phone is visible ([[mi4-device-dark-needs-power-press]])"
fi

echo "== DONE =="
echo "   adjudicate against docs/1029-design.md section 4:"
echo "     FIX-HOLDS    the launchctl[2] data abort at far == p->user_stack is GONE (0 xnu_live_abt_vmfkrv"
echo "                  rows with vmfkrv=1 on a far in the stack window) AND launchd still starts AND the"
echo "                  next frontier is NAMED by the existing rows"
echo "     FIX-NOOP     the same abort at the same far - sp == 0xF8C recurs => the top word was not the"
echo "                  cause; report, do NOT re-fix"
echo "     REGRESSION   trap24 / port_construct(result=0) vanish, or a panic appears => the +16 moved"
echo "                  something the guard math depended on; report and revert"
echo "     G-CTL        launchd never reached and no prior control (trap24 / vmfkrv) live => WITHHOLD"
echo "                  (fail closed; an unsound instrument cannot read an absence)"
echo "     e2_hi        must now read far + 16 (the region's new exclusive top); if it still reads far, the"
echo "                  allocation edit did NOT take effect => a BUILD defect, not a device fact"
echo "   Machine check: python3 -I tools/check_1029_capture.py <capture>"
echo "   Read the 1027 reading beside it: records/1027-press-read.txt (the H2 by-value reading this rung"
echo "   exists to fix) and records/1025-globalfix-carrier.txt section 6 (the arm identity settlement)."