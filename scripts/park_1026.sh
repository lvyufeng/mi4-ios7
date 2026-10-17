#!/usr/bin/env bash
# ====================================================================================================
# park_1026.sh.  MODELLED BYTE-STRUCTURALLY ON scripts/park_1025.sh (itself the 1024/1021d/1015b
# pattern), WITH 1015b's POOL-MOVED DISCIPLINE: this rung's edit is TWO POOL FILES
# (`osfmk/arm/trap.c` + `bsd/kern/kern_exec.c`), so the pool moves and the entry .bin whose sha8 IS
# the arm moves with it.
#
# Park 1026 (name WHY the launchctl[2] stack VA has no vm_map entry - H1 wrong map vs H2 off-the-end -
# by value, under the new switch STAGE90_XNU_ABT_ENTRY_PROBE=1) and append its block to
# records/revert-set.txt.
#
# 1026 = 1025's switch set VERBATIM with **ONE NEW SWITCH: STAGE90_XNU_ABT_ENTRY_PROBE=1**.  Design:
# docs/1026-design.md.
#
# WHY.  1025's press RAN and its own console was recovered (records/1025-press-read.txt).  The reading
# is FAULT-NAMED: the discarded `vm_fault` return is `code=1` = KERN_INVALID_ADDRESS on
# `far=0x2bd35000` (the EXCLUSIVE TOP of launchctl's [0x2bc35000, 0x2bd35000)), `dfsr=0x807`,
# `prot=write`, `sp=0x2bd34074`, `pc=0x3b4ce756`, `pid=2`.  By source, KERN_INVALID_ADDRESS means
# `vm_map_lookup_entry(map, VA)` returned FALSE - no entry covered the VA when the walk ran.  1025's own
# `xnu_live_ustack_*` rows then FALSIFIED the 1025 design's "inside a written region" premise: the
# region ENDS at far.  1026 discriminates the two remaining causes, which predict DIFFERENT fixes:
#   (H1) WRONG MAP   - `create_unix_stack` allocated into `get_task_map(task)` but the walk uses
#                      `thread->map`; the entry is invisible to the walk.
#   (H2) OFF-THE-END - the entry ends exactly at far and a legal word sits just below; the cause is
#                      upstream (the initial argv/env block / sp one word too high).
#
# **THE ARM (TWO POOL EDITS, one switch).**  Both are staged by tools/patch_d13_abt_entry_probe.py
# (anchor + done-mark; refuses a double-edit or a hand edit) with a two-arm real-preprocessor proof:
#   trap.c       `xnu_live_abt_lookup_far/entry_lo/entry_hi/far_in_map/map/taskmap/ustack` - the seven
#                reads that discriminate H1 from H2, printed for the failing fault only.  The block is
#                NESTED INSIDE 1025's publisher (the fault path is SHARED: ONE gate for it), so it
#                prints nothing unless BOTH switches are on.  NON-RINGED (the 1025 publishers are).
#   kern_exec.c  `xnu_live_abt_proc_ustack(void *)` - the `p->user_stack` accessor trap.c calls,
#                because `struct proc` is only FOWARD-declared in trap.c (`osfmk/arm/trap.c:58`), so the
#                FIELD cannot be read there without including bsd/sys/proc_internal.h (which no osfmk
#                file includes).  READ ONLY.
#
# **THE CHANNEL IS THE GLOBAL `DEFINES` ARRAY of tools/build_xnu_arm_kernel.sh (env), NOT EXTRA.**
# build_1026.sh carries that array's block and arrests a `-DSTAGE90_XNU_ABT_ENTRY_PROBE` in EXTRA (the
# records/1020-build-defect.txt shape), so an EXTRA-only build cannot ship a stale pool behind a green
# build.
#
# **THIS IS A POOL-REBUILD RUNG (the 1015b shape).**  trap.c and kern_exec.c are POOL files;
# `build_entry.sh` only LINKS the pool objects, so a green entry build says NOTHING about this half.  The
# park's OWN change is asserted BY VALUE on the two POOL OBJECTS (the publisher FORMAT STRING and the
# accessor SYMBOL, read by `strings`) and re-read on the FROZEN bytes.
#
# **[[mi4-one-file-many-rungs]].**  FOUR rungs edit osfmk/arm/trap.c (994 / 1020 / 1025 / 1026).  A
# cleanup `git checkout -- trap.c` SILENTLY reverts the others and the failure surfaces LATE (the pool
# compiles; the INHERITED check refuses the LINKED image).  The park's own by-value clauses are what
# catch a build that lost 1025's publisher under 1026's switch.
#
# **THE CARRIERS.**  The record carries `STAGE90_XNU_ABT_ENTRY_PROBE=1` (the readability carrier AND the
# switch the discriminator is gated by).  The declaration carrier
# out/stage90/xnu_arm_entry-arm-extra.txt is written by THIS build's tail as
# `STAGE90_XNU_GLOBAL_FIX=1 role=1026-abt-entry-probe` (1015b's GLOBAL_FIX is a POOL switch no writer in
# src/entry/ echoes).  A grep of that file is a PROCESS check; the by-value clauses below are what
# actually certify the arm ([[mi4-self-written-record-is-not-a-constraint]]).
#
# THE 1026 VERDICT CELLS (docs/1026-design.md section 4; the press reads them off the capture via
# tools/check_1026_capture.py; reader ORDER is G-CTL first, then REGRESSION before the H cells):
#   FAULT-NAMED  - the 1025 re-reading still HOLDS (vmfkrv=1 on a far in the stack window): the
#                  discriminator is being asked about the RIGHT fault
#   H1           - lookup_far=0 AND far_in_map=0 AND map != taskmap AND ustack == far => WRONG MAP
#   H2           - lookup_far=0 AND far_in_map=1 AND entry_hi == far AND map == taskmap => OFF-THE-END
#   H-OTHER      - any other combination => report it; pick NO fix (fail closed); 1027 instruments it
#   REGRESSION   - the 1024 controls regressed (the 1023 pthread storm returns, or trap24 /
#                  port_construct result=0 vanish) => the arm's switch set is wrong
#   G-CTL / WITHHOLD - neither launchd-reached nor any prior control is live => no reading
#   NO-CELL      - nothing in the table fired
#
# Medium: 968 real iOS 7.1.2 HFSX rootfs over hfs_rmd0; CARD_COW=1, HDD_WRITE=0, the base is never
# written - fully reversible.  fastboot boot only, NEVER flash.
# ====================================================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

LIVE=out/stage90
REC=records/revert-set.txt
MEMBERS=(xnu_arm_entry.bin xnu_arm_entry.elf xnu_arm_entry.h xnu_arm_entry-config.txt \
         xnu_arm_entry-arm-extra.txt xnu_arm_entry-sources.txt stage90.bin stage90.elf stage90.img \
         stage90-qcdt.img stage90_fixture.macho stage90-build-config.txt SHA256SUMS.txt)

# The arm name IS the entry bin's sha8 (the project's rule).  Derive it, and refuse to re-park the
# RECENT PRESSED arms under a new name (build 1026 first).  10b79e5d is the arm the 1023 press SPENT;
# the 1025 arm's sha (armed-d13-d7f1e533, its park name) is refused DYNAMICALLY below.
ARM=armed-d13-$(sha256sum "$LIVE/xnu_arm_entry.bin" | cut -c1-8)
[[ $ARM == armed-d13-10b79e5d ]] && { echo "REFUSING: $LIVE holds 1023's PRESSED arm (10b79e5d) - the arm whose storm 1024 moved away from; build 1026 first"; exit 1; }
[[ $ARM == armed-d13-d7f1e533 ]] && { echo "REFUSING: $LIVE holds 1025's PRESSED arm (d7f1e533) - the arm 1026 builds ON; build 1026 first"; exit 1; }
[[ $ARM == armed-d13-b47131c8 ]] && { echo "REFUSING: $LIVE holds 1022's PRESSED arm (b47131c8); build 1026 first"; exit 1; }
[[ $ARM == armed-d13-ee2dd4fb ]] && { echo "REFUSING: $LIVE holds 1021d's PRESSED arm (ee2dd4fb); build 1026 first"; exit 1; }
[[ $ARM == armed-d13-b5093f00 ]] && { echo "REFUSING: $LIVE holds 1020b's PRESSED arm (b5093f00); build 1026 first"; exit 1; }
[[ $ARM == armed-d13-47f664c4 ]] && { echo "REFUSING: $LIVE holds 1020's DROPPED-GLOBAL-FIX arm (47f664c4); build 1026 first"; exit 1; }
[[ $ARM == armed-d13-c2168632 ]] && { echo "REFUSING: $LIVE holds 1018's arm (c2168632); build 1026 first"; exit 1; }
[[ $ARM == armed-d13-16fe8885 ]] && { echo "REFUSING: $LIVE holds 1015b's arm (16fe8885); build 1026 first"; exit 1; }
[[ $ARM == armed-d13-e51d14fa ]] && { echo "REFUSING: $LIVE holds 1015's arm (e51d14fa); build 1026 first"; exit 1; }
[[ $ARM == armed-d13-29ec9e48 ]] && { echo "REFUSING: $LIVE holds 1014's arm (29ec9e48); build 1026 first"; exit 1; }
[[ $ARM == armed-d13-9bf25f8f ]] && { echo "REFUSING: $LIVE holds 1013b's arm (9bf25f8f); build 1026 first"; exit 1; }
[[ $ARM == armed-d13-ffdc8ba1 ]] && { echo "REFUSING: $LIVE holds 1012's arm (ffdc8ba1); build 1026 first"; exit 1; }

# ====================================================================================================
# 1026'S OWN CHANGE, BY VALUE, FIRST - BEFORE EVERY INHERITED REGRESSION CLAUSE.
# **THE ORDER IS THE POINT.**  A park that lost this rung's discriminator must fail HERE, on ITS OWN
# claim (the pool objects' FORMAT STRING + SYMBOL), rather than further down where an inherited clause
# would stop it for a reason that names the wrong thing.
# ====================================================================================================
echo "== 1026's OWN change, by value, first =="

# (a) THE RECORD'S OWN KEY.  `STAGE90_XNU_ABT_ENTRY_PROBE=1` is BOTH the readability carrier AND the
#     switch the discriminator is gated by.  Absent it, the pool was compiled with the discriminator
#     SHUT (the fault would still leave H1/H2 unseparated) and the arm is not 1026's.
grep -q '^STAGE90_XNU_ABT_ENTRY_PROBE=1$' "$LIVE/xnu_arm_entry-config.txt" || {
  echo "REFUSING: the record does not carry STAGE90_XNU_ABT_ENTRY_PROBE=1 - the discriminator this rung IS is gated by THIS switch, and it is set on this arm. Its absence means the pool was built with the discriminator SHUT, so the launchctl fault would still leave WHICH unreadable. Build with scripts/build_1026.sh"; exit 1; }

# (a2) 1025'S PARENT KEY.  1026's block is NESTED INSIDE 1025's publisher, so a record without
#      STAGE90_XNU_USTACK_PROBE=1 means the discriminator prints NOTHING (its parent gate is shut) even
#      with 1026's switch on - and the 1025 re-reading the reader depends on would be gone too.
grep -q '^STAGE90_XNU_USTACK_PROBE=1$' "$LIVE/xnu_arm_entry-config.txt" || {
  echo "REFUSING: the record does not carry STAGE90_XNU_USTACK_PROBE=1 - 1026's discriminator is NESTED INSIDE 1025's publisher block, so with the parent gate shut the seven reads never execute and the capture would be silent on the 1026 question while the record says the probe is live ([[mi4-one-file-many-rungs]]). Build with scripts/build_1026.sh"; exit 1; }

# (b) THE BY-VALUE CLAUSE - THE PARK'S OWN CLAIM, ON THE TWO POOL OBJECTS.
#     The fingerprints are a FORMAT STRING (`xnu_live_abt_lookup_far=`, read by `strings`) and a SYMBOL
#     (`xnu_live_abt_proc_ustack`, read by `strings`), off the POOL OBJECTS (the 1026 build's 5a
#     clause).  The park reads the objects directly because the edit's home IS the objects; the press
#     re-reads the LINKED image.
#
#     **THE CHECKER IS REQUIRED, AND ITS ABSENCE IS A REFUSAL, NOT A SKIP.**  A park that skipped this
#     would freeze an arm whose own claim nothing checks ([[mi4-a-claim-in-a-comment-is-not-a-check]]).
[[ -f tools/check_1026_capture.py ]] || {
  echo "REFUSING: tools/check_1026_capture.py is ABSENT. It is this park's capture reader (the H1/H2/H-OTHER cells the press is adjudicated by), and there is no sound fallback. An absent checker means the by-value half of this rung cannot be certified"; exit 1; }

# 1026-0. THE CHECKER'S OWN SELF-TEST.  A checker that cannot fail is not a check
#         ([[mi4-a-claim-in-a-comment-is-not-a-check]]).  Refuse the park unless it PASSes its selftest.
python3 -I tools/check_1026_capture.py --selftest >/dev/null 2>&1 || {
  echo "REFUSING: tools/check_1026_capture.py --selftest did NOT PASS - the checker cannot certify anything (an inert checker would bless any capture). Fix the checker before parking the arm it is supposed to prove"; exit 1; }
echo "   BY VALUE(0): tools/check_1026_capture.py --selftest PASSes (the checker is live)"

# 1026-1. THE RUNG'S OWN CLAIM, ON THE TWO POOL OBJECTS.  trap.c and kern_exec.c are POOL files; the
#         change is a POOL-only switch, so it does NOT change the entry image's own linked text - the
#         only object-side evidence the discriminator reached the build is the FORMAT STRING + SYMBOL.
[[ -d out/xnu_kernel_obj_d13 ]] || { echo "REFUSING: out/xnu_kernel_obj_d13 is absent - the pool the linked image was built from is not on disk"; exit 1; }
_trap_obj=out/xnu_kernel_obj_d13/osfmk_arm_trap.o
_exec_obj=out/xnu_kernel_obj_d13/bsd_kern_kern_exec.o
[[ -f $_trap_obj ]] || { echo "REFUSING: $_trap_obj is absent - trap.c is where xnu_live_abt_lookup_far=* lives; a park that cannot read it cannot certify the discriminator"; exit 1; }
[[ -f $_exec_obj ]] || { echo "REFUSING: $_exec_obj is absent - kern_exec.c is where xnu_live_abt_proc_ustack lives; a park that cannot read it cannot certify the accessor side"; exit 1; }
grep -qa '^xnu_live_abt_lookup_far=' <(strings "$_trap_obj") || {
  echo "REFUSING: $_trap_obj carries NO xnu_live_abt_lookup_far= publisher - the pool was NOT recompiled with STAGE90_XNU_ABT_ENTRY_PROBE=1 (the env -> global DEFINES channel of build_xnu_arm_kernel.sh) or the trap.c edit is not staged. Re-run scripts/build_1026.sh"; exit 1; }
grep -qa '^xnu_live_abt_proc_ustack$' <(strings "$_exec_obj") || {
  echo "REFUSING: $_exec_obj carries NO xnu_live_abt_proc_ustack symbol - the pool was NOT recompiled with STAGE90_XNU_ABT_ENTRY_PROBE=1 or the kern_exec.c edit is not staged. Re-run scripts/build_1026.sh"; exit 1; }
echo "   BY VALUE(1): $_trap_obj carries the xnu_live_abt_lookup_far= publisher and $_exec_obj carries the xnu_live_abt_proc_ustack accessor (the discriminator reached the pool objects)"

# 1026-1b. 1025'S PUBLISHER MUST SURVIVE THE SAME POOL REBUILD (the [[mi4-one-file-many-rungs]] check,
#          BY VALUE): 1026's block is nested inside 1025's, so a build that dropped 1025's switch would
#          leave the discriminator compiled-out while the pointer still pointed at dead text.
grep -qa '^xnu_live_abt_vmfkrv=' <(strings "$_trap_obj") || {
  echo "REFUSING: $_trap_obj lost 1025's xnu_live_abt_vmfkrv= publisher in this pool rebuild - 1026's block is NESTED inside 1025's, so the discriminator would never run ([[mi4-one-file-many-rungs]]). Re-run scripts/build_1026.sh"; exit 1; }
grep -qa '^xnu_live_ustack_req=' <(strings "$_exec_obj") || {
  echo "REFUSING: $_exec_obj lost 1025's xnu_live_ustack_req= publisher in this pool rebuild - 1026 builds ON 1025, not over it. Re-run scripts/build_1026.sh"; exit 1; }
echo "   BY VALUE(1b): 1025's publishers survive the rebuild (trap.o has xnu_live_abt_vmfkrv=, kern_exec.o has xnu_live_ustack_req=)"

# 1026-2. THE LINKED-IMAGE CO-READING.  build_entry.sh LINKS the pool objects, so the discriminator must
#         ALSO be reachable from the linked ELF the press boots (an object the linker DROPPED would leave
#         the arm's claim unmet).  Read here as the CONTEXT for the object-side clause above; the press
#         re-runs it as its step 0f.
grep -qa '^xnu_live_abt_lookup_far=' <(strings "$LIVE/xnu_arm_entry.elf") || {
  echo "REFUSING: the LINKED $LIVE/xnu_arm_entry.elf carries NO xnu_live_abt_lookup_far= string - the pool object that has it was not linked, so the press would capture nothing on the launchctl fault. Re-run scripts/build_1026.sh"; exit 1; }
grep -qa '^xnu_live_abt_vmfkrv=' <(strings "$LIVE/xnu_arm_entry.elf") || {
  echo "REFUSING: the LINKED $LIVE/xnu_arm_entry.elf carries NO xnu_live_abt_vmfkrv= string - 1025's publisher was dropped from the link. Re-run scripts/build_1026.sh"; exit 1; }
echo "   BY VALUE(2): the LINKED $LIVE/xnu_arm_entry.elf carries BOTH the 1026 discriminator and 1025's publisher (the probe reached the image the press boots)"

# (c) THE ARM-EXTRA DECLARATION CARRIER.  1026's build WRITES this file at its tail
#     (`STAGE90_XNU_GLOBAL_FIX=1 role=1026-abt-entry-probe`), so THIS park requires it verbatim and never
#     appends.  1015b's GLOBAL_FIX is a POOL switch no writer in src/entry/ echoes, so the record cannot
#     carry it; this drop-in is its ONE declaration, and the role tag names 1026 so a stale 1024/1025 line
#     is distinguishable by content.  **THE GREP IS THE PROCESS CHECK, NOT THE PROOF** - the pmap_flush_tlbs
#     fingerprint below is what certifies the fix is in the object
#     ([[mi4-self-written-record-is-not-a-constraint]]).
_b_extra="$LIVE/xnu_arm_entry-arm-extra.txt"
[[ -f $_b_extra ]] || { echo "REFUSING: $_b_extra is absent - 1026's build writes the declaration carrier at its tail; an absent one means this arm's build did not finish"; exit 1; }
[[ $(wc -l < "$_b_extra") == 1 && $(cat "$_b_extra") == 'STAGE90_XNU_GLOBAL_FIX=1 role=1026-abt-entry-probe' ]] || {
  echo "REFUSING: $_b_extra is not EXACTLY the one 1026 line (it holds '$(cat "$_b_extra")' across $(wc -l < "$_b_extra") line(s)). 1015b's GLOBAL_FIX is a POOL switch no writer in src/entry/ echoes, so this drop-in is its ONE declaration, and 1026's build writes it as exactly this line. A surviving 1025 line (role=1025-ustack-probe) would be a declaration OF A DIFFERENT BUILD ([[mi4-self-written-record-is-not-a-constraint]]). Re-run scripts/build_1026.sh"; exit 1; }
echo "   DECLARATION: $_b_extra carries exactly '$(cat "$_b_extra")' (written by THIS build; the proof is the fingerprint below)"

# ---- THE INHERITED GLOBAL-FIX CLAUSE: IT IS IN THE FROZEN POOL OBJECT, BY VALUE ----
# 1020's pool rebuild DROPPED 1015b (records/1020-build-defect.txt): the storm returned.  1026 rebuilds
# the WHOLE pool (trap.c/kern_exec.c), so the same defect is available.  The fix's fingerprint is the
# count of `kernel_pmap` MOVW materializations inside `pmap_flush_tlbs` (OFF/Apple = 2, ON = 3).
_gf_obj=out/xnu_kernel_obj_d13/osfmk_arm_pmap.o
[[ -f "$_gf_obj" ]] || { echo "REFUSING: $_gf_obj is absent - 1015b's GLOBAL-FIX lives in pmap_flush_tlbs, and a park that cannot read it cannot certify the storm stays gone"; exit 1; }
_gf_kp=$(arm-none-eabi-objdump -r "$_gf_obj" 2>/dev/null | awk '$1>="00000418" && $1<="00000640"' | grep -c 'MOVW_ABS_NC.*kernel_pmap' || true)
_gf_full=$(arm-none-eabi-objdump -r "$_gf_obj" 2>/dev/null | awk '$1>="00000418" && $1<="00000640"' | grep -c 'R_ARM_CALL.*arm_tlb_flushID$' || true)
_gf_asid=$(arm-none-eabi-objdump -r "$_gf_obj" 2>/dev/null | awk '$1>="00000418" && $1<="00000640"' | grep -c 'R_ARM_CALL.*arm_tlb_flushID_ASID$' || true)
[[ "$_gf_kp" == "3" && "$_gf_full" == "1" && "$_gf_asid" == "1" ]] || {
  echo "REFUSING: pmap_flush_tlbs materializes kernel_pmap x$_gf_kp (want 3), arm_tlb_flushID x$_gf_full / arm_tlb_flushID_ASID x$_gf_asid (want 1/1) - GLOBAL-FIX is NOT in the pool object, so the retry storm 1015b killed is BACK and the run would never reach the launchctl abort this rung exists to name. -DSTAGE90_XNU_GLOBAL_FIX=1 has NO record carrier (records/1020-build-defect.txt). Re-run scripts/build_1026.sh."; exit 1; }
echo "   POOL(GLOBAL-FIX): by value - pmap_flush_tlbs carries the 3rd kernel_pmap materialization ($_gf_kp sites) and the declared 1/1 flush arms, so 1015b's GLOBAL-FIX IS in the pool object"

# ---- THE INHERITED 1024 CEILING CLAUSE: IT IS IN THE LINKED IMAGE, BY VALUE ----
# 1026 ADDS ONLY THE DISCRIMINATOR, so 1024's task-map ceiling (VM_MAX_ADDRESS 0x40000000) must still be
# in the image the press boots.  `tools/check_vm_max_split.py` reads `task_create_internal` BY VALUE.
[[ -f tools/check_vm_max_split.py ]] || { echo "REFUSING: tools/check_vm_max_split.py is ABSENT - it is the inherited 1024 claim's by-value check on the linked image's task-map ceiling"; exit 1; }
python3 -I tools/check_vm_max_split.py --selftest >/dev/null 2>&1 || { echo "REFUSING: tools/check_vm_max_split.py --selftest did NOT PASS - the inherited ceiling checker cannot certify anything"; exit 1; }
python3 -I tools/check_vm_max_split.py "$LIVE/xnu_arm_entry.elf" --expect on >/dev/null 2>&1 || {
  echo "REFUSING: the LINKED image's task_create_internal does NOT pass 0x40000000 to vm_map_create - either 1024's widened vm_param.h:63 line did not reach the pool, or a STALE pool object was linked (build_entry.sh only LINKS it). The 1023 storm would return and the run would never reach launchctl. Re-run scripts/build_1026.sh"; exit 1; }
echo "   POOL(CEILING): by value - the LINKED image's task_create_internal passes 0x40000000 to vm_map_create (1024's ceiling is intact)"

# ---- THE INHERITED NEON-FREE CLAUSE: -msoft-float must still hold (this rung re-OBJECTs the WHOLE
# pool).  The census is whole-pool with a source-count cross-check (a stale/partial dir is a refusal).
[[ -f tools/check_d13_no_neon.py ]] || { echo "REFUSING: tools/check_d13_no_neon.py is ABSENT - it is the inherited 1021d claim's by-value check (the -msoft-float flag reached the pool)"; exit 1; }
python3 -I tools/check_d13_no_neon.py --selftest >/dev/null 2>&1 || { echo "REFUSING: tools/check_d13_no_neon.py --selftest did NOT PASS - the inherited NEON-free checker cannot certify anything"; exit 1; }
_pool=out/xnu_kernel_obj_d13
[[ -d $_pool ]] || { echo "REFUSING: $_pool is absent - the pool the linked image was built from is not on disk"; exit 1; }
_src_rec=out/xnu_kernel_src_d13.sha256
[[ -s $_src_rec ]] || { echo "REFUSING: $_src_rec is absent - the pool's own source-content record is the independent count this clause compares against"; exit 1; }
_want_objs=$(grep -c '^[0-9a-f]\{64\} ' "$_src_rec" || true)
_got_objs=$(ls "$_pool"/*.o 2>/dev/null | wc -l)
[[ $_want_objs -gt 0 && $_got_objs -eq $_want_objs ]] || {
  echo "REFUSING: $_pool holds $_got_objs object(s) but $_src_rec names $_want_objs source(s) - the census would count the WRONG set (a partial or stale directory passes any NEON-free test vacuously). Re-run scripts/build_1026.sh"; exit 1; }
python3 -I tools/check_d13_no_neon.py --pool "$_pool" --expect none --min-objects "$_want_objs" >/dev/null 2>&1 || {
  echo "REFUSING: tools/check_d13_no_neon.py --pool $_pool --expect none did NOT pass - the pool the linked image was built from still contains FP/NEON instructions. 1026 recompiles the WHOLE pool, so the -msoft-float flag must still reach every object or the kernel-mode NEON undef at 0x8047b0ac returns. Re-run scripts/build_1026.sh"; exit 1; }
python3 -I tools/check_d13_no_neon.py "$LIVE/xnu_arm_entry.elf" --symbol mach_msg_send --expect none >/dev/null 2>&1 || {
  echo "REFUSING: the LINKED image's mach_msg_send still contains FP/NEON instructions - 1021d's -msoft-float flag did not reach the object the linker saw, or a STALE pool object was linked. Re-run scripts/build_1026.sh"; exit 1; }
echo "   POOL(NEON-FREE): by value - $_got_objs objects NEON-free (== $_want_objs source(s)), and the LINKED mach_msg_send is NEON-free (1021d's -msoft-float holds)"

# ====================================================================================================
# THE INHERITED REGRESSION CLAUSES - 1025's / 1024's / 1023's / 1022's / 1021d's / 1020b's / 1018's, kept
# IN MEANING (placed AFTER 1026's own change, so a park that lost this rung's discriminator has already
# stopped above).
# ====================================================================================================
echo "== inherited regressions =="
grep -q '^STAGE90_XNU_GENERAL_REGS=1$' "$LIVE/xnu_arm_entry-config.txt" || {
  echo "REFUSING: the record does not carry STAGE90_XNU_GENERAL_REGS=1 - 1021d's -msoft-float flag switch is part of this arm's set verbatim and must stay on (without it the kernel-mode NEON undef at 0x8047b0ac returns)"; exit 1; }
grep -q '^STAGE90_XNU_UNDEF_RAISE=1$' "$LIVE/xnu_arm_entry-config.txt" || {
  echo "REFUSING: the record does not carry STAGE90_XNU_UNDEF_RAISE=1 - 1020's raise fix is part of this arm's set verbatim and must stay on (without it pid 1's genuine udf loops forever again, 8183x measured)"; exit 1; }
grep -q '^STAGE90_XNU_UNDEF_DIRECT=1$' "$LIVE/xnu_arm_entry-config.txt" || {
  echo "REFUSING: the record does not carry STAGE90_XNU_UNDEF_DIRECT=1 - 1018's direct channel is part of this arm's set verbatim and must stay on (without it the udf witness rides the CAPPED channel and can be silenced)"; exit 1; }
grep -q '^STAGE90_XNU_IOS7_TRAPS=1$' "$LIVE/xnu_arm_entry-config.txt" || {
  echo "REFUSING: the record does not carry STAGE90_XNU_IOS7_TRAPS=1 - 1023's row-24 gate widens to read THIS switch; its absence means row 24 is kern_invalid again and the 1023 frontier is back"; exit 1; }
grep -q '^STAGE90_XNU_VM_MAX_SPLIT=1$' "$LIVE/xnu_arm_entry-config.txt" || {
  echo "REFUSING: the record does not carry STAGE90_XNU_VM_MAX_SPLIT=1 - 1024's ceiling switch is part of this arm's set verbatim and must stay on (without it the 1023 storm returns and the boot never reaches the launchctl abort)"; exit 1; }
# 1023's by-value clause, re-run on the LINKED image.
[[ -f tools/check_1023_trap24.py ]] || { echo "REFUSING: tools/check_1023_trap24.py is ABSENT - it is the inherited 1023 claim's by-value check on the linked image"; exit 1; }
python3 -I tools/check_1023_trap24.py --selftest >/dev/null 2>&1 || { echo "REFUSING: tools/check_1023_trap24.py --selftest did NOT PASS - the inherited row-24 checker cannot certify anything"; exit 1; }
python3 -I tools/check_1023_trap24.py "$LIVE/xnu_arm_entry.elf" --expect on >/dev/null 2>&1 || {
  echo "REFUSING: the LINKED image's mach_trap_table[24] is NOT the ios7lab_mach_port_construct_trap row any more (or rows 25/41/42 moved) - 1026 adds only the discriminator and must ADD nothing else. Re-run scripts/build_1026.sh"; exit 1; }
echo "   BY VALUE(3): tools/check_1023_trap24.py --expect on PASSes (1023's row 24 is intact, rows 25/41/42 still kern_invalid)"
# 1020's by-value clause, re-run on the LINKED image.
[[ -f tools/check_d13_undef_raise.py ]] || { echo "REFUSING: tools/check_d13_undef_raise.py is ABSENT - it is the inherited 1020 claim's by-value check on the linked image"; exit 1; }
python3 -I tools/check_d13_undef_raise.py "$LIVE/xnu_arm_entry.elf" --expect on >/dev/null 2>&1 || {
  echo "REFUSING: tools/check_d13_undef_raise.py --expect on did NOT pass on the linked image - 1020's moved \`return\` is NOT in this image's sleh_undef, so the udf loop is back. Re-run scripts/build_1026.sh"; exit 1; }
echo "   BY VALUE(4): tools/check_d13_undef_raise.py --expect on PASSes (1020's raise is intact in the linked image)"
# 1018's by-value census: `__wrap_sleh_undef` in the LINKED image must branch to the DIRECT writer.
_ua=$(arm-none-eabi-nm "$LIVE/xnu_arm_entry.elf" | awk '$3=="__wrap_sleh_undef"{print "0x" $1; n++} END{exit(n==1?0:1)}') || {
  echo "REFUSING: __wrap_sleh_undef is not in the parked image (or is defined more than once) - the undef witness is gone"; exit 1; }
_ub=$(arm-none-eabi-nm -n "$LIVE/xnu_arm_entry.elf" | awk -v s="${_ua#0x}" 'BEGIN{sv=strtonum("0x" s)}{a=strtonum("0x" $1)} a>sv{if(!d){print "0x" $1; d=1}}') || true
[[ -n $_ub ]] || { echo "REFUSING: no symbol follows __wrap_sleh_undef ($_ua) - its range cannot be read"; exit 1; }
_ud=$(arm-none-eabi-objdump -d "$LIVE/xnu_arm_entry.elf" --start-address="$_ua" --stop-address="$_ub")
_kv=$(grep -c '<entry_write_kv>' <<<"$_ud" || true)
_lw=$(grep -c '<entry_live_write>' <<<"$_ud" || true)
[[ $_kv -ge 6 && $_lw -eq 0 ]] || {
  echo "REFUSING: the parked image's __wrap_sleh_undef ($_ua..$_ub) branches to entry_write_kv $_kv time(s) and entry_live_write $_lw time(s) - with the switch on it must be >=6 direct and 0 counted. A park that kept the counted branch freezes an arm whose witness the cap can still silence."; exit 1; }
echo "   BY VALUE(5): __wrap_sleh_undef ($_ua..$_ub) branches to entry_write_kv x$_kv, entry_live_write x$_lw (1018's witness is on the DIRECT channel)"

PARK=$LIVE/frozen/$ARM
[[ -d $PARK ]] && { echo "REFUSING: $PARK already exists"; exit 1; }
mkdir -p "$PARK"
for m in "${MEMBERS[@]}"; do cp -p "$LIVE/$m" "$PARK/$m"; done

# THE FROZEN RE-READ.  The checks above ran on the LIVE artifacts (so a bad arm never creates a park
# directory); this re-runs the rung's own claims on the PARKED bytes, so what is frozen is what was
# certified - a later build cannot silently change what was pressed.
grep -qa '^xnu_live_abt_lookup_far=' <(strings "$PARK/xnu_arm_entry.elf") || {
  echo "REFUSING: the FROZEN $PARK/xnu_arm_entry.elf lost the xnu_live_abt_lookup_far= publisher - the copy is not the certified bytes. This park's directory is incomplete; remove $PARK and re-run"; exit 1; }
grep -qa '^xnu_live_abt_vmfkrv=' <(strings "$PARK/xnu_arm_entry.elf") || {
  echo "REFUSING: the FROZEN $PARK/xnu_arm_entry.elf lost 1025's xnu_live_abt_vmfkrv= publisher - the copy is not the certified bytes. This park's directory is incomplete; remove $PARK and re-run"; exit 1; }
python3 -I tools/check_vm_max_split.py "$PARK/xnu_arm_entry.elf" --expect on >/dev/null 2>&1 || {
  echo "REFUSING: the FROZEN $PARK/xnu_arm_entry.elf does not carry 1024's ceiling claim the live one did - the copy is not the certified bytes. This park's directory is incomplete; remove $PARK and re-run"; exit 1; }
python3 -I tools/check_1023_trap24.py "$PARK/xnu_arm_entry.elf" --expect on >/dev/null 2>&1 || {
  echo "REFUSING: the FROZEN $PARK/xnu_arm_entry.elf lost 1023's row-24 claim - the copy is not the certified bytes. This park's directory is incomplete; remove $PARK and re-run"; exit 1; }
echo "   BY VALUE(6): the FROZEN $PARK/xnu_arm_entry.elf carries the 1026 discriminator, 1025's publisher, 1024's ceiling (0x40000000) AND 1023's row 24 (the parked bytes are the certified bytes)"

{
  printf '# %s  -  1026: NAME WHY THE launchctl[2] STACK VA HAS NO vm_map ENTRY (H1 wrong map vs H2 off-the-end).\n' "$ARM"
  printf '# 1025-s press RAN and its own console was recovered (records/1025-press-read.txt): the discarded\n'
  printf '#  `vm_fault` return is code=1 = KERN_INVALID_ADDRESS on far=0x2bd35000 (the EXCLUSIVE TOP of\n'
  printf '#  launchctl-s [0x2bc35000, 0x2bd35000)), dfsr=0x807 (translation/page), prot=write,\n'
  printf '#  sp=0x2bd34074, pc=0x3b4ce756, pid=2. By source, KERN_INVALID_ADDRESS means\n'
  printf '#  vm_map_lookup_entry(map, VA) returned FALSE (vm_map.c:8761ff) - no entry covered the VA when\n'
  printf '#  the walk ran. 1025-s own xnu_live_ustack_* rows then FALSIFIED the 1025 design-s premise\n'
  printf '#  (the region ENDS at far, it does not contain it). 1026 discriminates the two remaining\n'
  printf '#  causes, which predict DIFFERENT fixes: (H1) WRONG MAP - create_unix_stack allocated into\n'
  printf '#  get_task_map(task) but the walk uses thread->map; (H2) OFF-THE-END - the entry ends exactly\n'
  printf '#  at far and a legal word sits just below (cause upstream: the initial argv/env block / sp one\n'
  printf '#  word too high). docs/1026-design.md.\n'
  printf '# Switch set is 1025-s VERBATIM with **ONE NEW SWITCH: STAGE90_XNU_ABT_ENTRY_PROBE=1**.\n'
  printf '# THE ARM (TWO POOL EDITS, one switch), staged by tools/patch_d13_abt_entry_probe.py:\n'
  printf '#   trap.c      -> `xnu_live_abt_lookup_far/entry_lo/entry_hi/far_in_map/map/taskmap/ustack`,\n'
  printf '#                  printed for the failing fault only and NESTED INSIDE 1025-s publisher block\n'
  printf '#                  (the fault path is SHARED: ONE gate for it), so it prints nothing unless BOTH\n'
  printf '#                  switches are on. NON-RINGED (the 1025 publishers are).\n'
  printf '#   kern_exec.c -> `xnu_live_abt_proc_ustack(void *)`, the p->user_stack accessor trap.c calls,\n'
  printf '#                  because `struct proc` is only FOWARD-declared in trap.c (osfmk/arm/trap.c:58)\n'
  printf '#                  and the FIELD cannot be read there without bsd/sys/proc_internal.h (which no\n'
  printf '#                  osfmk file includes). READ ONLY.\n'
  printf '# THE CHANNEL IS THE GLOBAL DEFINES ARRAY of tools/build_xnu_arm_kernel.sh (env), NOT EXTRA\n'
  printf '# (build_1026.sh arrests a -DSTAGE90_XNU_ABT_ENTRY_PROBE in EXTRA), so an EXTRA-only build\n'
  printf '# cannot ship a stale pool behind a green build.\n'
  printf '# THE POOL MOVES: trap.c/kern_exec.c are POOL files, so the pool (and the entry .bin whose sha8\n'
  printf '# IS the arm) MOVES (d7f1e533 -> %s). build_entry.sh only LINKS the pool objects, so a green\n' "${ARM#armed-d13-}"
  printf '# entry build says nothing about this half.\n'
  printf '# [[mi4-one-file-many-rungs]]: FOUR rungs edit osfmk/arm/trap.c (994 / 1020 / 1025 / 1026); a\n'
  printf '# cleanup `git checkout -- trap.c` reverts the others SILENTLY and the failure surfaces LATE.\n#\n'
  printf '# THE BY-VALUE PROOF OF 1026-S CHANGE, asserted FIRST and re-run on the FROZEN bytes:\n'
  printf '#   (0)  tools/check_1026_capture.py --selftest PASSes (the checker can fail);\n'
  printf '#   (1)  osfmk_arm_trap.o carries `xnu_live_abt_lookup_far=` AND bsd_kern_kern_exec.o carries\n'
  printf '#        the `xnu_live_abt_proc_ustack` accessor (the discriminator reached the pool objects);\n'
  printf '#   (1b) 1025-s `xnu_live_abt_vmfkrv=` / `xnu_live_ustack_req=` SURVIVE the same rebuild\n'
  printf '#        (1026-s block is nested inside 1025-s, so a dropped parent gate means no reading);\n'
  printf '#   (2)  the LINKED out/stage90/xnu_arm_entry.elf carries BOTH (the linker did not drop them);\n'
  printf '#   (6)  the FROZEN bytes still carry them (the parked bytes are the certified bytes).\n#\n'
  printf '# THE CARRIERS ([[mi4-one-value-two-definitions]]). The record carries\n'
  printf '# STAGE90_XNU_ABT_ENTRY_PROBE=1 (the switch the discriminator is gated by AND the readability\n'
  printf '# carrier) AND STAGE90_XNU_USTACK_PROBE=1 (the PARENT gate). The declaration carrier\n'
  printf '# out/stage90/xnu_arm_entry-arm-extra.txt is written by THIS build-s tail as\n'
  printf '# STAGE90_XNU_GLOBAL_FIX=1 role=1026-abt-entry-probe; the grep of it is the process check and\n'
  printf '# the pmap_flush_tlbs fingerprint is the proof.\n'
  printf '# THE INHERITED REGRESSIONS held (asserted by the park): STAGE90_XNU_GENERAL_REGS=1 (1021d-s\n'
  printf '# -msoft-float), STAGE90_XNU_UNDEF_RAISE=1, STAGE90_XNU_UNDEF_DIRECT=1, STAGE90_XNU_IOS7_TRAPS=1\n'
  printf '# and STAGE90_XNU_VM_MAX_SPLIT=1 in the record, 1024-s ceiling on the linked image, the\n'
  printf '# pmap_flush_tlbs kernel_pmap==3 fingerprint, the whole-pool NEON-free census + the linked\n'
  printf '# mach_msg_send NEON-free read, check_1023_trap24.py --expect on, check_d13_undef_raise.py\n'
  printf '# --expect on, and by value __wrap_sleh_undef branching to entry_write_kv (>=6) and NOT\n'
  printf '# entry_live_write (0).\n#\n'
  printf '# THE 1026 VERDICT CELLS (docs/1026-design.md sec.4; read via tools/check_1026_capture.py;\n'
  printf '# reader ORDER is G-CTL first, then REGRESSION before the H cells):\n'
  printf '#   FAULT-NAMED  - the 1025 re-reading still HOLDS => the discriminator is asked about the\n'
  printf '#                  RIGHT fault;\n'
  printf '#   H1           - lookup_far=0 AND far_in_map=0 AND map != taskmap AND ustack == far => WRONG\n'
  printf '#                  MAP; fix = walk the task-s map;\n'
  printf '#   H2           - lookup_far=0 AND far_in_map=1 AND entry_hi == far AND map == taskmap =>\n'
  printf '#                  OFF-THE-END; fix = a word of headroom (kernel-side; userspace is correct);\n'
  printf '#   H-OTHER      - any other combination => report it; pick NO fix (fail closed); 1027\n'
  printf '#                  instruments whatever the combination names;\n'
  printf '#   REGRESSION   - the 1024 controls regressed (the 1023 storm returns, or trap24 /\n'
  printf '#                  port_construct result=0 vanish) => the arm-s switch set is wrong;\n'
  printf '#   G-CTL / WITHHOLD - neither launchd-reached nor any prior control is live => no reading;\n'
  printf '#   NO-CELL      - nothing in the table fired (report what was present; never fabricate).\n'
  printf '# Medium: 968 real iOS 7.1.2 HFSX rootfs over hfs_rmd0; CARD_COW=1, HDD_WRITE=0, base never\n'
  printf '# written - fully reversible. fastboot boot only, NEVER flash.\n'
  printf '# =================================================================================================\n'
  for m in "${MEMBERS[@]}"; do
    h=$(sha256sum "$PARK/$m" | awk '{print $1}')
    b=$(stat -c %s "$PARK/$m")
    printf 'set=%s sha256=%s bytes=%s file=%s role=1026-abt-entry-probe;%s\n' \
      "$ARM" "$h" "$b" "$m" "$m"
  done
} >> "$REC"

echo "parked $ARM ($(ls -1 "$PARK" | wc -l) members)"
tools/verify_revert_set.sh "$PARK" --set="$ARM" 2>&1 | tail -3