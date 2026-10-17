#!/usr/bin/env bash
# ====================================================================================================
# park_1025.sh.  MODELLED BYTE-STRUCTURALLY ON scripts/park_1024.sh (itself the 1021d/1015b pattern),
# WITH 1015b's POOL-MOVED DISCIPLINE: this rung's edit is TWO POOL FILES (`osfmk/arm/trap.c` +
# `bsd/kern/kern_exec.c`), so the pool moves and the entry .bin whose sha8 IS the arm moves with it.
#
# Park 1025 (publish the discarded `vm_fault` return for the launchctl[2] stack abort + the stack's
# shape, under the new switch STAGE90_XNU_USTACK_PROBE=1) and append its block to records/revert-set.txt.
#
# 1025 = 1024's switch set VERBATIM with **ONE NEW SWITCH: STAGE90_XNU_USTACK_PROBE=1**.  Design:
# docs/1025-design.md.
#
# WHY.  The 1024 boot (records/1024b-frontier-launchctl-crash.txt) reached `*** launchd[1] has started up
# ***`, spawned pid 2 `launchctl`, then died in a USERSPACE DATA ABORT on a STACK VA
# (`launchctl[2]: usermode data abort, EXC_BAD_ACCESS at 0x2bdbe000 ... (Translation fault on page)`,
# `r4=r6=0x2bdbe000`, `sp=0x2bdbd074`, `pc=0x3adc4756`, `cpsr=0xa0000030`).  By value 0x2bdbe000 is
# INSIDE the fixed stack window [0x2BD00000, 0x2BE00000) `create_unix_stack` allocates and `sp` shows the
# FIXED allocation SUCCEEDED (records/1025-source-trace.txt sections 3-4, which FALSIFIED the v1 collision
# hypothesis): a page that SHOULD be mapped is TRANSLATION-faulting.  In osfmk/arm/trap.c the usermode
# data-abort path CALLS `vm_fault` (trap.c:806) and, on a non-SUCCESS return (trap.c:809), prints the
# abort and delivers EXC_BAD_ACCESS (`doexception`, trap.c:968); the ONE assignment of the return code
# (`code`) sits inside `#if BOARD_CONFIG_QSD8250_LEO` (trap.c:810-814), so on CANCRO **the value that
# NAMES the cause is DISCARDED**.  1025 compiles in a publisher for it (trap.c) plus a stack-shape
# publisher (kern_exec.c) so the frontier becomes a NUMBER (KERN_MEMORY_ERROR? KERN_PROTECTION_FAILURE?
# KERN_INVALID_ADDRESS?) the next rung can act on.
#
# THE ARM IDENTITY SETTLEMENT (the R1/R2 decision).  records/1025-globalfix-carrier.txt section 6: the
# crash capture family (sha 685941a3c47c) carries `xnu_live_abt_wdsplit=0x40000000` (the split IS
# active), ZERO "=0x40083008" storm rows, and `launchd[1] has started up` + the launchctl crash => it is
# a LATER, SPLIT-ON arm than the storm family, i.e. THE 1024-SHAPED ARM.  Per that record's section 3,
# GLOBAL_FIX=1 is ALSO in the 1024 arm (verified in osfmk_arm_pmap.o).  So the launchctl stack abort is
# NOT retired by GLOBAL_FIX => case (R2) => **the probe is REQUIRED, not optional**.
#
# **THE ARM (TWO POOL EDITS, one switch).**  Both are staged by tools/patch_d13_ustack_probe.py (anchor
# + done-mark; refuses a double-edit or a hand edit) with a two-arm real-preprocessor proof:
#   trap.c       `xnu_live_abt_vmfkrv=<code>` + `_far=/_dfsr=/_prot=/_pc=/_sp=/_pid=` (the discarded
#                vm_fault return for EVERY failed usermode data abort) - NON-RINGED, because the
#                `xnu_live_abt_*` RING capped at `n=0x400` on the shared-cache fault before this abort.
#   kern_exec.c  `xnu_live_ustack_req/size/fixed_addr/rc/fallback/final/prot_addr/prot_size` (once per
#                exec) - the stack placement the fault leaves unknown.
#
# **THE CHANNEL IS THE GLOBAL `DEFINES` ARRAY of tools/build_xnu_arm_kernel.sh (env), NOT EXTRA.**
# build_1025.sh carries that array's block and arrests a `-DSTAGE90_XNU_USTACK_PROBE` in EXTRA (the
# records/1020-build-defect.txt shape), so an EXTRA-only build cannot ship a stale pool behind a green
# build.
#
# **THIS IS A POOL-REBUILD RUNG (the 1015b shape).**  trap.c and kern_exec.c are POOL files;
# `build_entry.sh` only LINKS the pool objects, so a green entry build says NOTHING about this half.  The
# park's OWN change is asserted BY VALUE on the two POOL OBJECTS (the publisher FORMAT STRINGS, read by
# `strings`) and re-read on the FROZEN bytes.
#
# **THE CARRIERS.**  The record carries `STAGE90_XNU_USTACK_PROBE=1` (the readability carrier AND the
# switch the two publishers are gated by).  The declaration carrier
# out/stage90/xnu_arm_entry-arm-extra.txt is written by THIS build's tail as
# `STAGE90_XNU_GLOBAL_FIX=1 role=1025-ustack-probe` (1015b's GLOBAL_FIX is a POOL switch no writer in
# src/entry/ echoes).  A grep of that file is a PROCESS check; the by-value clauses below are what
# actually certify the arm ([[mi4-self-written-record-is-not-a-constraint]]).
#
# THE 1025 VERDICT CELLS (docs/1025-design.md section 4; the press reads them off the capture via
# tools/check_1025_capture.py):
#   FAULT-NAMED    - a xnu_live_abt_vmfkrv_* row whose _far is INSIDE [0x2BD00000, 0x2BE00000) with a
#                    _vmfkrv return that NAMES the cause => report the cause (the 1025 goal)
#   FAULT-NOT-RUN  - launchd reached but NO xnu_live_abt_vmfkrv= row => the abort is NOT this (data) path
#   STACK-SHAPE    - xnu_live_ustack_* with _rc=0 and no ANYWHERE fallback => confirms the source trace
#   REGRESSION     - the 1024 controls regressed (the 1023 pthread storm returns, or trap24 /
#                    port_construct result=0 vanish) => the arm's switch set is wrong
#   G-CTL / WITHHOLD - neither launchd-reached nor any prior control is live => no reading
#   NO-CELL        - nothing in the table fired
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
# RECENT PRESSED arms under a new name (build 1025 first).  10b79e5d is the arm the 1023 press SPENT
# (1024 moved away from it); 1020/1020b/1018/1015b/1015/1014/1013b/1012 are earlier rungs.  The 1024
# arm's sha (its park name armed-d13-<sha>) is refused DYNAMICALLY below, because the park directory
# name is the ONLY content-independent way to name it (a static list cannot carry a sha learned at
# build time).
ARM=armed-d13-$(sha256sum "$LIVE/xnu_arm_entry.bin" | cut -c1-8)
[[ $ARM == armed-d13-10b79e5d ]] && { echo "REFUSING: $LIVE holds 1023's PRESSED arm (10b79e5d) - the arm whose storm 1024 moved away from and whose pthread-create fault 1025 must not re-measure; build 1025 first"; exit 1; }
[[ $ARM == armed-d13-b47131c8 ]] && { echo "REFUSING: $LIVE holds 1022's PRESSED arm (b47131c8); build 1025 first"; exit 1; }
[[ $ARM == armed-d13-ee2dd4fb ]] && { echo "REFUSING: $LIVE holds 1021d's PRESSED arm (ee2dd4fb); build 1025 first"; exit 1; }
[[ $ARM == armed-d13-b5093f00 ]] && { echo "REFUSING: $LIVE holds 1020b's PRESSED arm (b5093f00); build 1025 first"; exit 1; }
[[ $ARM == armed-d13-47f664c4 ]] && { echo "REFUSING: $LIVE holds 1020's DROPPED-GLOBAL-FIX arm (47f664c4); build 1025 first"; exit 1; }
[[ $ARM == armed-d13-c2168632 ]] && { echo "REFUSING: $LIVE holds 1018's arm (c2168632); build 1025 first"; exit 1; }
[[ $ARM == armed-d13-16fe8885 ]] && { echo "REFUSING: $LIVE holds 1015b's arm (16fe8885); build 1025 first"; exit 1; }
[[ $ARM == armed-d13-e51d14fa ]] && { echo "REFUSING: $LIVE holds 1015's arm (e51d14fa); build 1025 first"; exit 1; }
[[ $ARM == armed-d13-29ec9e48 ]] && { echo "REFUSING: $LIVE holds 1014's arm (29ec9e48); build 1025 first"; exit 1; }
[[ $ARM == armed-d13-9bf25f8f ]] && { echo "REFUSING: $LIVE holds 1013b's arm (9bf25f8f); build 1025 first"; exit 1; }
[[ $ARM == armed-d13-ffdc8ba1 ]] && { echo "REFUSING: $LIVE holds 1012's arm (ffdc8ba1); build 1025 first"; exit 1; }

# ====================================================================================================
# 1025'S OWN CHANGE, BY VALUE, FIRST - BEFORE EVERY INHERITED REGRESSION CLAUSE.
# **THE ORDER IS THE POINT.**  A park that lost this rung's publisher must fail HERE, on ITS OWN claim
# (the two pool objects' FORMAT STRINGS), rather than further down where an inherited clause would stop
# it for a reason that names the wrong thing.
# ====================================================================================================
echo "== 1025's OWN change, by value, first =="

# (a) THE RECORD'S OWN KEY.  `STAGE90_XNU_USTACK_PROBE=1` is BOTH the readability carrier AND the switch
#     the two publishers are gated by.  Absent it, the pool was compiled with the probe SHUT (the
#     discarded `vm_fault` return stays discarded) and the arm is not 1025's.
grep -q '^STAGE90_XNU_USTACK_PROBE=1$' "$LIVE/xnu_arm_entry-config.txt" || {
  echo "REFUSING: the record does not carry STAGE90_XNU_USTACK_PROBE=1 - the two publishers this rung IS are gated by THIS switch, and it is set on this arm. Its absence means the pool was built with the probe SHUT, so the launchctl fault would still leave no readable cause. Build with scripts/build_1025.sh"; exit 1; }

# (b) THE BY-VALUE CLAUSE - THE PARK'S OWN CLAIM, ON THE TWO POOL OBJECTS.
#     The two publishers' fingerprints are FORMAT STRINGS (`xnu_live_abt_vmfkrv=`, `xnu_live_ustack_req=`),
#     read by `strings` off the POOL OBJECTS (the 1025 build's 5a clause).  The park reads the objects
#     directly because the edit's home IS the objects; the press re-reads the LINKED image (step 0f).
#
#     **THE CHECKER IS REQUIRED, AND ITS ABSENCE IS A REFUSAL, NOT A SKIP.**  A park that skipped this
#     would freeze an arm whose own claim nothing checks ([[mi4-a-claim-in-a-comment-is-not-a-check]]).
[[ -f tools/check_1025_capture.py ]] || {
  echo "REFUSING: tools/check_1025_capture.py is ABSENT. It is this park's capture reader (the cells the press is adjudicated by), and there is no sound fallback. An absent checker means the by-value half of this rung cannot be certified"; exit 1; }

# 1025-0. THE CHECKER'S OWN SELF-TEST.  A checker that cannot fail is not a check
#         ([[mi4-a-claim-in-a-comment-is-not-a-check]]).  Refuse the park unless it PASSes its selftest.
python3 -I tools/check_1025_capture.py --selftest >/dev/null 2>&1 || {
  echo "REFUSING: tools/check_1025_capture.py --selftest did NOT PASS - the checker cannot certify anything (an inert checker would bless any capture). Fix the checker before parking the arm it is supposed to prove"; exit 1; }
echo "   BY VALUE(0): tools/check_1025_capture.py --selftest PASSes (the checker is live)"

# 1025-1. THE RUNG'S OWN CLAIM, ON THE TWO POOL OBJECTS.  trap.c and kern_exec.c are POOL files; the
#         change is a POOL-only switch, so it does NOT change the entry image's own linked text - the
#         only object-side evidence the publisher reached the build is the FORMAT STRING.
[[ -d out/xnu_kernel_obj_d13 ]] || { echo "REFUSING: out/xnu_kernel_obj_d13 is absent - the pool the linked image was built from is not on disk"; exit 1; }
_trap_obj=out/xnu_kernel_obj_d13/osfmk_arm_trap.o
_exec_obj=out/xnu_kernel_obj_d13/bsd_kern_kern_exec.o
[[ -f $_trap_obj ]] || { echo "REFUSING: $_trap_obj is absent - trap.c is where xnu_live_abt_vmfkrv=* lives; a park that cannot read it cannot certify the fault side"; exit 1; }
[[ -f $_exec_obj ]] || { echo "REFUSING: $_exec_obj is absent - kern_exec.c is where xnu_live_ustack_req=* lives; a park that cannot read it cannot certify the stack-shape side"; exit 1; }
grep -qa '^xnu_live_abt_vmfkrv=' <(strings "$_trap_obj") || {
  echo "REFUSING: $_trap_obj carries NO xnu_live_abt_vmfkrv= publisher - the pool was NOT recompiled with STAGE90_XNU_USTACK_PROBE=1 (the env -> global DEFINES channel of build_xnu_arm_kernel.sh) or the trap.c edit is not staged. Re-run scripts/build_1025.sh"; exit 1; }
grep -qa '^xnu_live_ustack_req=' <(strings "$_exec_obj") || {
  echo "REFUSING: $_exec_obj carries NO xnu_live_ustack_req= publisher - the pool was NOT recompiled with STAGE90_XNU_USTACK_PROBE=1 or the kern_exec.c edit is not staged. Re-run scripts/build_1025.sh"; exit 1; }
echo "   BY VALUE(1): $_trap_obj carries the xnu_live_abt_vmfkrv= publisher and $_exec_obj carries xnu_live_ustack_req= (the probe reached the pool objects)"

# 1025-2. THE LINKED-IMAGE CO-READING.  build_entry.sh LINKS the pool objects, so the publishers must
#         ALSO be reachable from the linked ELF the press boots (an object the linker DROPPED would leave
#         the arm's claim unmet).  Read here as the CONTEXT for the object-side clause above; the press
#         re-runs it as its step 0f.
grep -qa '^xnu_live_abt_vmfkrv=' <(strings "$LIVE/xnu_arm_entry.elf") || {
  echo "REFUSING: the LINKED $LIVE/xnu_arm_entry.elf carries NO xnu_live_abt_vmfkrv= string - the pool object that has it was not linked, so the press would capture nothing on the launchctl fault. Re-run scripts/build_1025.sh"; exit 1; }
grep -qa '^xnu_live_ustack_req=' <(strings "$LIVE/xnu_arm_entry.elf") || {
  echo "REFUSING: the LINKED $LIVE/xnu_arm_entry.elf carries NO xnu_live_ustack_req= string - the pool object that has it was not linked. Re-run scripts/build_1025.sh"; exit 1; }
echo "   BY VALUE(2): the LINKED $LIVE/xnu_arm_entry.elf carries BOTH publishers (the probes reached the image the press boots)"

# (c) THE ARM-EXTRA DECLARATION CARRIER.  1025's build WRITES this file at its tail
#     (`STAGE90_XNU_GLOBAL_FIX=1 role=1025-ustack-probe`), so THIS park requires it verbatim and never
#     appends.  1015b's GLOBAL_FIX is a POOL switch no writer in src/entry/ echoes, so the record cannot
#     carry it; this drop-in is its ONE declaration, and the role tag names 1025 so a stale 1024 line is
#     distinguishable by content.  **THE GREP IS THE PROCESS CHECK, NOT THE PROOF** - the pmap_flush_tlbs
#     fingerprint below is what certifies the fix is in the object
#     ([[mi4-self-written-record-is-not-a-constraint]]).
_b_extra="$LIVE/xnu_arm_entry-arm-extra.txt"
[[ -f $_b_extra ]] || { echo "REFUSING: $_b_extra is absent - 1025's build writes the declaration carrier at its tail; an absent one means this arm's build did not finish"; exit 1; }
[[ $(wc -l < "$_b_extra") == 1 && $(cat "$_b_extra") == 'STAGE90_XNU_GLOBAL_FIX=1 role=1025-ustack-probe' ]] || {
  echo "REFUSING: $_b_extra is not EXACTLY the one 1025 line (it holds '$(cat "$_b_extra")' across $(wc -l < "$_b_extra") line(s)). 1015b's GLOBAL_FIX is a POOL switch no writer in src/entry/ echoes, so this drop-in is its ONE declaration, and 1025's build writes it as exactly this line. A surviving 1024 line (role=1024-vm-max-split) would be a declaration OF A DIFFERENT BUILD ([[mi4-self-written-record-is-not-a-constraint]]). Re-run scripts/build_1025.sh"; exit 1; }
echo "   DECLARATION: $_b_extra carries exactly '$(cat "$_b_extra")' (written by THIS build; the proof is the fingerprint below)"

# ---- THE INHERITED GLOBAL-FIX CLAUSE: IT IS IN THE FROZEN POOL OBJECT, BY VALUE ----
# 1020's pool rebuild DROPPED 1015b (records/1020-build-defect.txt): the storm returned.  1025 rebuilds
# the WHOLE pool (trap.c/kern_exec.c), so the same defect is available.  The fix's fingerprint is the
# count of `kernel_pmap` MOVW materializations inside `pmap_flush_tlbs` (OFF/Apple = 2, ON = 3).  This is
# ALSO the proof that the arm is the 1024-shaped one whose crash 1025 names
# (records/1025-globalfix-carrier.txt section 3).
_gf_obj=out/xnu_kernel_obj_d13/osfmk_arm_pmap.o
[[ -f "$_gf_obj" ]] || { echo "REFUSING: $_gf_obj is absent - 1015b's GLOBAL-FIX lives in pmap_flush_tlbs, and a park that cannot read it cannot certify the storm stays gone"; exit 1; }
_gf_kp=$(arm-none-eabi-objdump -r "$_gf_obj" 2>/dev/null | awk '$1>="00000418" && $1<="00000640"' | grep -c 'MOVW_ABS_NC.*kernel_pmap' || true)
_gf_full=$(arm-none-eabi-objdump -r "$_gf_obj" 2>/dev/null | awk '$1>="00000418" && $1<="00000640"' | grep -c 'R_ARM_CALL.*arm_tlb_flushID$' || true)
_gf_asid=$(arm-none-eabi-objdump -r "$_gf_obj" 2>/dev/null | awk '$1>="00000418" && $1<="00000640"' | grep -c 'R_ARM_CALL.*arm_tlb_flushID_ASID$' || true)
[[ "$_gf_kp" == "3" && "$_gf_full" == "1" && "$_gf_asid" == "1" ]] || {
  echo "REFUSING: pmap_flush_tlbs materializes kernel_pmap x$_gf_kp (want 3), arm_tlb_flushID x$_gf_full / arm_tlb_flushID_ASID x$_gf_asid (want 1/1) - GLOBAL-FIX is NOT in the pool object, so the retry storm 1015b killed is BACK and the run would never reach the launchctl abort this rung exists to name. -DSTAGE90_XNU_GLOBAL_FIX=1 has NO record carrier (records/1020-build-defect.txt). Re-run scripts/build_1025.sh."; exit 1; }
echo "   POOL(GLOBAL-FIX): by value - pmap_flush_tlbs carries the 3rd kernel_pmap materialization ($_gf_kp sites) and the declared 1/1 flush arms, so 1015b's GLOBAL-FIX IS in the pool object"

# ---- THE INHERITED 1024 CEILING CLAUSE: IT IS IN THE LINKED IMAGE, BY VALUE ----
# 1025 ADDS ONLY THE PROBE, so 1024's task-map ceiling (VM_MAX_ADDRESS 0x40000000) must still be in the
# image the press boots.  `tools/check_vm_max_split.py` reads `task_create_internal` BY VALUE (both ends
# resolved by NAME from the symbol table) and asserts the `mov r2,#imm` feeding `bl vm_map_create` reads
# 0x40000000 (the 1024 park's own clause, retargeted to a co-reading here).
[[ -f tools/check_vm_max_split.py ]] || { echo "REFUSING: tools/check_vm_max_split.py is ABSENT - it is the inherited 1024 claim's by-value check on the linked image's task-map ceiling"; exit 1; }
python3 -I tools/check_vm_max_split.py --selftest >/dev/null 2>&1 || { echo "REFUSING: tools/check_vm_max_split.py --selftest did NOT PASS - the inherited ceiling checker cannot certify anything"; exit 1; }
python3 -I tools/check_vm_max_split.py "$LIVE/xnu_arm_entry.elf" --expect on >/dev/null 2>&1 || {
  echo "REFUSING: the LINKED image's task_create_internal does NOT pass 0x40000000 to vm_map_create - either 1024's widened vm_param.h:63 line did not reach the pool, or a STALE pool object was linked (build_entry.sh only LINKS it). The 1023 storm would return and the run would never reach launchctl. Re-run scripts/build_1025.sh"; exit 1; }
echo "   POOL(CEILING): by value - the LINKED image's task_create_internal passes 0x40000000 to vm_map_create (1024's ceiling is intact)"

# ---- THE INHERITED NEON-FREE CLAUSE: -msoft-float must still hold (this rung re-OBJECTs the WHOLE
# pool, so the flag must still reach every object).  The census is whole-pool with a source-count
# cross-check (a stale/partial dir is a refusal, not a vacuous pass, defect class m1015b).
[[ -f tools/check_d13_no_neon.py ]] || { echo "REFUSING: tools/check_d13_no_neon.py is ABSENT - it is the inherited 1021d claim's by-value check (the -msoft-float flag reached the pool). An absent one means the build tree is incomplete"; exit 1; }
python3 -I tools/check_d13_no_neon.py --selftest >/dev/null 2>&1 || { echo "REFUSING: tools/check_d13_no_neon.py --selftest did NOT PASS - the inherited NEON-free checker cannot certify anything"; exit 1; }
_pool=out/xnu_kernel_obj_d13
[[ -d $_pool ]] || { echo "REFUSING: $_pool is absent - the pool the linked image was built from is not on disk"; exit 1; }
_src_rec=out/xnu_kernel_src_d13.sha256
[[ -s $_src_rec ]] || { echo "REFUSING: $_src_rec is absent - the pool's own source-content record is the independent count this clause compares against. Its absence means the pool build did not complete"; exit 1; }
_want_objs=$(grep -c '^[0-9a-f]\{64\} ' "$_src_rec" || true)
_got_objs=$(ls "$_pool"/*.o 2>/dev/null | wc -l)
[[ $_want_objs -gt 0 && $_got_objs -eq $_want_objs ]] || {
  echo "REFUSING: $_pool holds $_got_objs object(s) but $_src_rec names $_want_objs source(s) - the census would count the WRONG set (a partial or stale directory passes any NEON-free test vacuously). Re-run scripts/build_1025.sh"; exit 1; }
python3 -I tools/check_d13_no_neon.py --pool "$_pool" --expect none --min-objects "$_want_objs" >/dev/null 2>&1 || {
  echo "REFUSING: tools/check_d13_no_neon.py --pool $_pool --expect none did NOT pass - the pool the linked image was built from still contains FP/NEON instructions. 1025 recompiles the WHOLE pool (trap.c/kern_exec.c), so the -msoft-float flag must still reach every object or the kernel-mode NEON undef at 0x8047b0ac returns. Re-run scripts/build_1025.sh"; exit 1; }
python3 -I tools/check_d13_no_neon.py "$LIVE/xnu_arm_entry.elf" --symbol mach_msg_send --expect none >/dev/null 2>&1 || {
  echo "REFUSING: the LINKED image's mach_msg_send still contains FP/NEON instructions - 1021d's -msoft-float flag did not reach the object the linker saw, or a STALE pool object was linked. Re-run scripts/build_1025.sh"; exit 1; }
echo "   POOL(NEON-FREE): by value - $_got_objs objects NEON-free (== $_want_objs source(s)), and the LINKED mach_msg_send is NEON-free (1021d's -msoft-float holds)"

# ====================================================================================================
# THE INHERITED REGRESSION CLAUSES - 1024's / 1023's / 1022's / 1021d's / 1020b's / 1018's, kept VERBATIM
# IN MEANING (placed AFTER 1025's own change, so a park that lost this rung's publisher has already
# stopped above).
# ====================================================================================================
echo "== inherited regressions =="
# 1021d's general-regs switch stays on (the whole pool must stay NEON-free).
grep -q '^STAGE90_XNU_GENERAL_REGS=1$' "$LIVE/xnu_arm_entry-config.txt" || {
  echo "REFUSING: the record does not carry STAGE90_XNU_GENERAL_REGS=1 - 1021d's -msoft-float flag switch is part of this arm's set verbatim and must stay on (without it the kernel-mode NEON undef at 0x8047b0ac returns and this rung would measure a different frontier than the launchctl stack abort it exists to name)"; exit 1; }
# 1020's raise switch stays on: 1025 must not regress the fix that killed the udf loop.
grep -q '^STAGE90_XNU_UNDEF_RAISE=1$' "$LIVE/xnu_arm_entry-config.txt" || {
  echo "REFUSING: the record does not carry STAGE90_XNU_UNDEF_RAISE=1 - 1020's raise fix is part of this arm's set verbatim and must stay on (without it pid 1's genuine udf loops forever again, 8183x measured)"; exit 1; }
# 1018's direct-channel switch stays on (its witness survives the cap) - the recorder that names the udf.
grep -q '^STAGE90_XNU_UNDEF_DIRECT=1$' "$LIVE/xnu_arm_entry-config.txt" || {
  echo "REFUSING: the record does not carry STAGE90_XNU_UNDEF_DIRECT=1 - 1018's direct channel is part of this arm's set verbatim and must stay on (without it the udf witness rides the CAPPED channel and can be silenced - the 1017/1018 instrument defect)"; exit 1; }
# 1023's row-24 switch stays on: 1025 ADDS ONLY THE PROBE, so trap 24 must still be installed and rows
# 25/41/42 still kern_invalid.
grep -q '^STAGE90_XNU_IOS7_TRAPS=1$' "$LIVE/xnu_arm_entry-config.txt" || {
  echo "REFUSING: the record does not carry STAGE90_XNU_IOS7_TRAPS=1 - 1023's row-24 gate widens to read THIS switch; its absence means row 24 is kern_invalid again, the 1023 frontier is back, and the press would not be a reading of THIS rung"; exit 1; }
# 1024's ceiling switch stays on: 1025 carries the set verbatim and must not drop it (without it the
# task map reaches above the 1 GiB TTBR0 split and the 1023 pthread storm returns - the boot never
# reaches launchctl).
grep -q '^STAGE90_XNU_VM_MAX_SPLIT=1$' "$LIVE/xnu_arm_entry-config.txt" || {
  echo "REFUSING: the record does not carry STAGE90_XNU_VM_MAX_SPLIT=1 - 1024's ceiling switch is part of this arm's set verbatim and must stay on (without it the task map reaches 0x80000000 while the hardware walks TTBR1 above 0x40000000, the 1023 storm returns, and the boot never reaches the launchctl abort 1025 exists to name)"; exit 1; }
# 1023's by-value clause, re-run on the LINKED image: mach_trap_table[24] must still be the construct
# handler with rows 25/41/42 still kern_invalid (the composition this rung inherits unchanged).
[[ -f tools/check_1023_trap24.py ]] || { echo "REFUSING: tools/check_1023_trap24.py is ABSENT - it is the inherited 1023 claim's by-value check on the linked image (build_1023's row 24)"; exit 1; }
python3 -I tools/check_1023_trap24.py --selftest >/dev/null 2>&1 || { echo "REFUSING: tools/check_1023_trap24.py --selftest did NOT PASS - the inherited row-24 checker cannot certify anything"; exit 1; }
python3 -I tools/check_1023_trap24.py "$LIVE/xnu_arm_entry.elf" --expect on >/dev/null 2>&1 || {
  echo "REFUSING: the LINKED image's mach_trap_table[24] is NOT the ios7lab_mach_port_construct_trap row any more (or rows 25/41/42 moved) - 1025 adds only the probe and must ADD nothing else; with the row gone the 1023 frontier is back. Re-run scripts/build_1025.sh"; exit 1; }
echo "   BY VALUE(3): tools/check_1023_trap24.py --expect on PASSes (1023's row 24 is intact, rows 25/41/42 still kern_invalid)"
# 1020's by-value clause, re-run on the LINKED image: `sleh_undef`'s user arm must still reach the
# EXC-printf raise on the VFP-already-enabled path.
[[ -f tools/check_d13_undef_raise.py ]] || { echo "REFUSING: tools/check_d13_undef_raise.py is ABSENT - it is the inherited 1020 claim's by-value check on the linked image (the build writes it, so an absent one means the build tree is incomplete)"; exit 1; }
python3 -I tools/check_d13_undef_raise.py "$LIVE/xnu_arm_entry.elf" --expect on >/dev/null 2>&1 || {
  echo "REFUSING: tools/check_d13_undef_raise.py --expect on did NOT pass on the linked image - 1020's moved \`return\` is NOT in this image's sleh_undef, so the udf loop is back and this rung would measure a different frontier. Re-run scripts/build_1025.sh"; exit 1; }
echo "   BY VALUE(4): tools/check_d13_undef_raise.py --expect on PASSes (1020's raise is intact in the linked image)"
# 1018's by-value census: `__wrap_sleh_undef` in the LINKED image must branch to the DIRECT writer
# (entry_write_kv), NOT the capped one ([[mi4-linked-code-order-is-not-source-order]]).
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
# certified - a later build cannot silently change what was pressed.  (The two publishers' fingerprints
# are read off the PARKED entry ELF here, the same `strings` clause as BY VALUE(2).)
grep -qa '^xnu_live_abt_vmfkrv=' <(strings "$PARK/xnu_arm_entry.elf") || {
  echo "REFUSING: the FROZEN $PARK/xnu_arm_entry.elf lost the xnu_live_abt_vmfkrv= publisher - the copy is not the certified bytes. This park's directory is incomplete; remove $PARK and re-run"; exit 1; }
grep -qa '^xnu_live_ustack_req=' <(strings "$PARK/xnu_arm_entry.elf") || {
  echo "REFUSING: the FROZEN $PARK/xnu_arm_entry.elf lost the xnu_live_ustack_req= publisher - the copy is not the certified bytes. This park's directory is incomplete; remove $PARK and re-run"; exit 1; }
python3 -I tools/check_vm_max_split.py "$PARK/xnu_arm_entry.elf" --expect on >/dev/null 2>&1 || {
  echo "REFUSING: the FROZEN $PARK/xnu_arm_entry.elf does not carry 1024's ceiling claim the live one did - the copy is not the certified bytes. This park's directory is incomplete; remove $PARK and re-run"; exit 1; }
python3 -I tools/check_1023_trap24.py "$PARK/xnu_arm_entry.elf" --expect on >/dev/null 2>&1 || {
  echo "REFUSING: the FROZEN $PARK/xnu_arm_entry.elf lost 1023's row-24 claim - the copy is not the certified bytes. This park's directory is incomplete; remove $PARK and re-run"; exit 1; }
echo "   BY VALUE(6): the FROZEN $PARK/xnu_arm_entry.elf carries BOTH publishers, 1024's ceiling (0x40000000) AND 1023's row 24 (the parked bytes are the certified bytes)"

{
  printf '# %s  -  1025: PUBLISH THE DISCARDED vm_fault RETURN FOR THE launchctl[2] STACK ABORT + THE STACK SHAPE.\n' "$ARM"
  printf '# (The 1024 boot (records/1024b-frontier-launchctl-crash.txt) reached `*** launchd[1] has started\n'
  printf '#  up ***`, spawned pid 2 `launchctl`, then died in a USERSPACE DATA ABORT on a STACK VA:\n'
  printf '#  launchctl[2]: usermode data abort, EXC_BAD_ACCESS at 0x2bdbe000 in map 0xc0005688\n'
  printf '#  (pmap 0xc0ba3b28) (Translation fault on page); r4=r6=0x2bdbe000 sp=0x2bdbd074 lr=0x3adbc9af\n'
  printf '#  pc=0x3adc4756 cpsr=0xa0000030. 0x2bdbe000 is INSIDE the fixed stack window\n'
  printf '#  [0x2BD00000, 0x2BE00000) create_unix_stack allocates and sp shows the FIXED alloc SUCCEEDED\n'
  printf '#  (no ANYWHERE fallback) - records/1025-source-trace.txt sections 3-4 FALSIFIED v1-s collision\n'
  printf '#  hypothesis - so a page that SHOULD be mapped is TRANSLATION-faulting. In osfmk/arm/trap.c\n'
  printf '#  the usermode data-abort path CALLS vm_fault (trap.c:806) and, on a non-SUCCESS return\n'
  printf '#  (trap.c:809), prints the abort and delivers EXC_BAD_ACCESS (doexception, trap.c:968); the\n'
  printf '#  ONE assignment of the return code sits inside `#if BOARD_CONFIG_QSD8250_LEO` (trap.c:810-814),\n'
  printf '#  so on CANCRO the value that NAMES the cause is DISCARDED. docs/1025-design.md.)\n'
  printf '# Switch set is 1024-s VERBATIM with **ONE NEW SWITCH: STAGE90_XNU_USTACK_PROBE=1**.\n'
  printf '# THE ARM IDENTITY SETTLEMENT (records/1025-globalfix-carrier.txt sec.6): the crash family\n'
  printf '# (sha 685941a3c47c) carries xnu_live_abt_wdsplit=0x40000000 + ZERO 0x40083008 storm rows +\n'
  printf '# launchd/launchctl, i.e. it IS the 1024-shaped arm; and per that record-s sec.3 GLOBAL_FIX=1 is\n'
  printf '# ALREADY in the 1024 arm - so GLOBAL_FIX did NOT retire the launchctl abort => case (R2) => the\n'
  printf '# probe is REQUIRED, not optional.\n'
  printf '# THE ARM (TWO POOL EDITS, one switch), staged by tools/patch_d13_ustack_probe.py:\n'
  printf '#   trap.c      -> `xnu_live_abt_vmfkrv=<code>` + _far=/_dfsr=/_prot=/_pc=/_sp=/_pid= (the\n'
  printf '#                  discarded vm_fault return for EVERY failed usermode data abort), NON-RINGED\n'
  printf '#                  because the xnu_live_abt_* RING capped at n=0x400 before the launchctl abort;\n'
  printf '#   kern_exec.c -> `xnu_live_ustack_req/size/fixed_addr/rc/fallback/final/prot_addr/prot_size`\n'
  printf '#                  (once per exec - the stack placement the fault leaves unknown).\n'
  printf '# THE CHANNEL IS THE GLOBAL DEFINES ARRAY of tools/build_xnu_arm_kernel.sh (env), NOT EXTRA\n'
  printf '# (build_1025.sh arrests a -DSTAGE90_XNU_USTACK_PROBE in EXTRA), so an EXTRA-only build cannot\n'
  printf '# ship a stale pool behind a green build.\n'
  printf '# THE POOL MOVES: trap.c/kern_exec.c are POOL files, so the pool (and the entry .bin whose sha8\n'
  printf '# IS the arm) MOVES (64558b47 -> %s). build_entry.sh only LINKS the pool objects, so a green\n'
  printf '# entry build says nothing about this half.\n#\n' "${ARM#armed-d13-}"
  printf '# THE BY-VALUE PROOF OF 1025-S CHANGE, asserted FIRST and re-run on the FROZEN bytes.  The change\n'
  printf '# is a POOL-only switch, so it does NOT change the entry text - the only object-side evidence is\n'
  printf '# the publisher FORMAT STRING, read by `strings`:\n'
  printf '#   (0) tools/check_1025_capture.py --selftest PASSes (the checker can fail);\n'
  printf '#   (1) osfmk_arm_trap.o carries `xnu_live_abt_vmfkrv=` AND bsd_kern_kern_exec.o carries\n'
  printf '#       `xnu_live_ustack_req=` (the probe reached the TWO pool objects);\n'
  printf '#   (2) the LINKED out/stage90/xnu_arm_entry.elf carries BOTH (the linker did not drop them);\n'
  printf '#   (6) the FROZEN bytes still carry BOTH (the parked bytes are the certified bytes).\n#\n'
  printf '# THE CARRIERS ([[mi4-one-value-two-definitions]]). The record carries STAGE90_XNU_USTACK_PROBE=1\n'
  printf '# (the switch the two publishers are gated by AND the readability carrier). The declaration\n'
  printf '# carrier out/stage90/xnu_arm_entry-arm-extra.txt is written by THIS build-s tail as\n'
  printf '# STAGE90_XNU_GLOBAL_FIX=1 role=1025-ustack-probe (1015b-s GLOBAL_FIX is a POOL switch no writer\n'
  printf '# in src/entry/ echoes, so the record cannot carry it); the grep of it is the process check and\n'
  printf '# the pmap_flush_tlbs fingerprint is the proof.\n#\n'
  printf '# THE INHERITED REGRESSIONS held (asserted by the park): STAGE90_XNU_GENERAL_REGS=1 (1021d-s\n'
  printf '# -msoft-float; the WHOLE pool re-OBJECTed), STAGE90_XNU_UNDEF_RAISE=1 and\n'
  printf '# STAGE90_XNU_UNDEF_DIRECT=1 and STAGE90_XNU_IOS7_TRAPS=1 and STAGE90_XNU_VM_MAX_SPLIT=1 in the\n'
  printf '# record, 1024-s ceiling on the linked image (task_create_internal -> 0x40000000), the\n'
  printf '# pmap_flush_tlbs kernel_pmap==3 fingerprint (1015b-s kernel fix), the whole-pool NEON-free\n'
  printf '# census + the linked mach_msg_send NEON-free read (1021d), check_1023_trap24.py --expect on\n'
  printf '# (1023-s row 24 intact, rows 25/41/42 still kern_invalid), check_d13_undef_raise.py --expect on\n'
  printf '# on the linked image (1020-s raise intact), and by value __wrap_sleh_undef branching to\n'
  printf '# entry_write_kv (>=6) and NOT entry_live_write (0).\n#\n'
  printf '# THE 1025 VERDICT CELLS (docs/1025-design.md sec.4; read via tools/check_1025_capture.py;\n'
  printf '# reader ORDER is G-CTL first, then REGRESSION before FAULT-NAMED):\n'
  printf '#   FAULT-NAMED    - a xnu_live_abt_vmfkrv_* row whose _far is INSIDE [0x2BD00000,0x2BE00000)\n'
  printf '#                    with a _vmfkrv return that NAMES the cause => report the cause (the goal).\n'
  printf '#   FAULT-NOT-RUN  - launchd reached but NO xnu_live_abt_vmfkrv= row => the abort is NOT this\n'
  printf '#                    (data) path; re-read (a PREFETCH abort? then instrument that arm too).\n'
  printf '#   STACK-SHAPE    - xnu_live_ustack_* present with _rc=0 and no ANYWHERE fallback => confirms\n'
  printf '#                    records/1025-source-trace.txt-s by-value claim independently.\n'
  printf '#   REGRESSION     - the 1024 controls regressed (the 1023 pthread storm returns, or trap24 /\n'
  printf '#                    port_construct result=0 vanish) => the arm-s switch set is wrong.\n'
  printf '#   G-CTL / WITHHOLD - neither launchd-reached nor any prior control is live => no reading.\n'
  printf '#   NO-CELL        - nothing in the table fired (report what was present; never fabricate).\n'
  printf '# Medium: 968 real iOS 7.1.2 HFSX rootfs over hfs_rmd0; CARD_COW=1, HDD_WRITE=0, base never\n'
  printf '# written - fully reversible. fastboot boot only, NEVER flash.\n'
  printf '# =================================================================================================\n'
  for m in "${MEMBERS[@]}"; do
    h=$(sha256sum "$PARK/$m" | awk '{print $1}')
    b=$(stat -c %s "$PARK/$m")
    printf 'set=%s sha256=%s bytes=%s file=%s role=1025-ustack-probe;%s\n' \
      "$ARM" "$h" "$b" "$m" "$m"
  done
} >> "$REC"

echo "parked $ARM ($(ls -1 "$PARK" | wc -l) members)"
tools/verify_revert_set.sh "$PARK" --set="$ARM" 2>&1 | tail -3