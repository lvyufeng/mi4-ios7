#!/usr/bin/env bash
# ====================================================================================================
# press_1031.sh.  MODELLED ON scripts/press_1030.sh (itself the RESIDENT-rung press: the USB console
# reader + the /proc/last_kmsg recovery).  Design: docs/1031-design.md (rewritten 2026-10-17).
#
# Press 1031: **PROBE THE CALLER - publish the CALLER's register frame at the fault AND the stack
# region's EXCLUSIVE TOP by value, so the writer's derivation is NAMED.**
# Switch: **ONE NEW: STAGE90_XNU_CALLER_PROBE=1** (1030's FULL set is carried VERBATIM otherwise; the
# reader AND writer probes STAY ON so the parent cells are comparable row-for-row).
#
# THE PREMISE (docs/1031-design.md sections 0/1; records/1030-press-read.txt).  1030 read
# **W-B-NAMED** on 2026-10-17: the faulting store target IS the region's EXCLUSIVE TOP, BY VALUE --
#     xnu_live_wrp_r4        = r4 == far               (the store target IS the fault address)
#     xnu_live_wrp_r6        = r6 == r4               (the caller passed the same value as r2 and r3)
#     xnu_live_wrp_userstack = 0x2bdad000
#     xnu_live_wrp_r4_minus_ustack = 0x00001000       (one PAGE above the block top)
#     xnu_live_wrp_r4_minus_far = 0
# The writer is `/usr/lib/libobjc.dylib + 0x14756`, `str.w r2,[r4],#4`, a post-increment cursor store
# inside a shared-cache / objc table REBASE.  Its prologue is `push {r4,r5,r6,r7,lr}; add r7,sp,#12`
# and it does `mov r4,r3`, so **`r4` is the CALLER's 4th argument** and the boundary decision is in the
# CALLER.  r4 == r6 at the fault says the caller passed `r2 == r3 == 0x2bdae000`.
#
# **THE PRIOR DISASSEMBLY CLAIM IS REFUTED BY THE RAW FRAME.**  A disassembly of the caller claimed it
# derives r3 as `sub.w rN, sp, r#N, lsl #2` (a DOWNWARD alloca off sp).  But the 1030 capture shows
# `sp = 0x2bdac074` and `r4 = sp + 0x1F8C`, so r4 lies ABOVE sp -- a sub-off-sp cannot produce it.  The
# caller's derivation is therefore **UNRESOLVED**, and 1031 is the instrument that measures it (it makes
# NO fix and changes NO allocation).  See docs/1031-design.md section 5.
#
# THE PROBE (tools/patch_d13_caller_probe.py, behind the ONE new switch):
#   Site A -- osfmk/arm/trap.c, on the launchctl[2] usermode DATA-abort FAILURE arm (inside 1025's
#     publisher, after 1026/1027/1029's and 1030's blocks): republishes the caller's register frame
#     (xnu_live_cal_r0/r1/r2/r3/r9/r10/r12/r7/r7_minus_sp/lr/pc) plus the fault's own frame
#     (xnu_live_cal_far/ustack/far_minus_ustack) AND a region-end lookup:
#     `vm_map_lookup_entry(map, trunc_page(far) - 4, &e); e->vme_end` -> xnu_live_cal_region_end_hit /
#     xnu_live_cal_region_end / xnu_live_cal_r3_minus_region_end.
#   Site B -- bsd/kern/kern_exec.c, a NEW accessor `xnu_live_cal_proc_region_top` beside 1026's, plus a
#     stash of the allocator's own exclusive top at create_unix_stack (FIXED success + ANYWHERE
#     fallback), so the region top is readable BY VALUE, not by a stand-in `addr + size`.
#
# THE PRE-REGISTERED CELLS (docs/1031-design.md section 2; read by tools/check_1031_capture.py):
#   CAL-CALLER-TOP    - the region-end lookup HIT and r3 == r2 == far == region_end (with the writer's
#                 loud frame shape r7 - sp == 0xC): the caller derived the WRITE ADDRESS **as the
#                 stack region's exclusive top** -- the address IS the region's END, not a base+size.
#   CAL-CALLER-SIZE   - r3 == r2 but r3 is NOT the region end, sitting a small (<= 0x1000) distance
#                 short of it: the caller produced the address as a **base+size expression** one page
#                 short of the region end.
#   CAL-CALLER-OTHER  - a complete frame naming NEITHER shape (or the loud frame shape is wrong): name
#                 what it is; **do NOT pick a fix** (fail closed; the next step is to single-step the
#                 caller, docs/1031-design.md section 6).
#   CAL-MISSING       - the cal group did not print (probe did not run / incomplete): WITHHOLD.  **NEVER
#                 a negative** -- an absent row means the PROBE DID NOT RUN, not "no fault".
#   REGRESSION  - launchd not reached, or trap24/port_construct marks vanish, or a panic appears, or
#                 the 1023 pthread storm signature is back => WITHHOLD.
#   G-CTL       - no capture NEWER than this press's boot epoch, or no controls live at all => WITHHOLD
#                 (the 1028 stale-slot rule: a resident rung that does not return keeps no
#                 `/proc/last_kmsg` of its own, so a capture OLDER than this boot is a PREVIOUS arm's
#                 slot and MUST NOT be adjudicated, [[mi4-stale-slot-impersonates-a-reading]]).
#
# **THIS PRESS IS NOT TO READ A LOG.**  A `fastboot boot` spent to look at a log has no question behind
# it: this rung's question is the one above, and the arm must be the one the by-value gates below
# certify.  The recovery step reads `/proc/last_kmsg` only because the run's own log is the reading
# ([[mi4-last-kmsg-reader-carrier]]: the carrier is the FLASHED ROM).
#
# Medium: 968 real iOS 7.1.2 HFSX rootfs over hfs_rmd0; CARD_COW=1, HDD_WRITE=0, the base is never
# written - fully reversible.  fastboot boot only, NEVER flash.  [[mi4-hardware-run-safety-gate]]:
# fastboot boot only, unplug 33e80afe first, target 4a2fe00b, keep fastboot reachable.
# ====================================================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

LIVE=out/stage90
REC=$LIVE/xnu_arm_entry-config.txt

echo "== 0. the record must be 1031's arm =="
# **1031'S OWN SWITCH FIRST: STAGE90_XNU_CALLER_PROBE.**  This rung IS the caller probe: the
# xnu_live_cal_* rows are published from osfmk/arm/trap.c's DATA-abort failure arm (inside 1025's
# publisher, after 1026/1027/1029's and 1030's blocks; Site B in kern_exec.c) behind THIS switch
# (tools/patch_d13_caller_probe.py).  A record without it means the pool was built with the probe SHUT
# ([[mi4-build-variant-comes-from-an-env-default]]: the switch rides the env -> global DEFINES channel
# of build_xnu_arm_kernel.sh), so the capture would carry NO cal row while the record claimed 1 - and
# the press would read CAL-MISSING for a reason that is the BUILD's, not the device's (the
# records/1020-build-defect.txt shape).
grep -q '^STAGE90_XNU_CALLER_PROBE=1$' "$REC" || {
  echo "REFUSING: the record does not carry STAGE90_XNU_CALLER_PROBE=1 - the caller probe this rung IS is gated by THIS switch (osfmk/arm/trap.c's xnu_live_cal_* rows on the usermode DATA-abort failure arm + kern_exec.c's Site B accessor/stash, staged by tools/patch_d13_caller_probe.py). Its absence means the pool was built with the probe SHUT, so the capture would carry no cal row at all while the record says the probe is live, and this press would not be a reading of THIS rung. Build it with scripts/build_1031.sh first"; exit 1; }
# 1030's own switch, CARRIED VERBATIM: the WRITER probe (xnu_live_wrp_* rows) stays ON.  1031's premise
# -- `r4 == far == the region's exclusive top` -- is READ FROM THOSE ROWS, and they ride the same
# failure arm as the cal rows.  Without them the parent evidence that the fault is the known boundary
# write is gone, and the checker would be reading a caller row with no corroboration of WHICH fault it
# describes.
grep -q '^STAGE90_XNU_WRITER_PROBE=1$' "$REC" || {
  echo "REFUSING: the record does not carry STAGE90_XNU_WRITER_PROBE=1 - 1031's premise (r4 == far == the region's exclusive top) is READ FROM the xnu_live_wrp_* rows 1030 published, and they ride the same failure arm as the cal rows. A pool built with the writer probe SHUT would leave the caller row uncorroborated. Build it with scripts/build_1031.sh first"; exit 1; }
# 1029's switch, CARRIED: the reader probe (xnu_live_rdr_* rows) stays ON.  It is the row-for-row parent
# this probe narrows (the reader-named boundary write) and it makes the cal frame's `far`/`ustack`
# independent of the cal block itself.
grep -q '^STAGE90_XNU_READER_PROBE=1$' "$REC" || {
  echo "REFUSING: the record does not carry STAGE90_XNU_READER_PROBE=1 - 1031 carries the reader probe verbatim so the cal row is read beside the reader row it describes (the same failure arm). Its absence would leave the boundary-write reading uncorroborated. Build it with scripts/build_1031.sh first"; exit 1; }
# 1028's switch, CARRIED: 1031 changes no allocation at all (it is a probe).  The H2 edit stays IN the
# tree so the geometry the readings were taken against is unchanged (1028's arm is what put far at
# region_top / ustack + 0x1000 on 1028/1029/1030).  Reverting it would move the geometry and make 1031's
# reading incomparable with 1030's.
grep -q '^STAGE90_XNU_H2_STACK_HEADROOM=1$' "$REC" || {
  echo "REFUSING: the record does not carry STAGE90_XNU_H2_STACK_HEADROOM=1 - 1031 probes the caller WITHOUT changing the allocation, so the geometry the 1028 fix established (far == region top, +0x1000 vs pre-fix) must stay in the tree or the cal row describes a DIFFERENT geometry than 1030's. Build it with scripts/build_1031.sh first"; exit 1; }
# 1027's switch, CARRIED VERBATIM: the PARENT cells are read beside its xnu_live_abt_* rows, so a record
# without STAGE90_XNU_ABT_ENTRY_PROBE=1 means the pool was built with the discriminator SHUT and the
# capture would be silent on WHETHER the fault 1031's cal row describes is the known fault.
grep -q '^STAGE90_XNU_ABT_ENTRY_PROBE=1$' "$REC" || {
  echo "REFUSING: the record does not carry STAGE90_XNU_ABT_ENTRY_PROBE=1 - 1031 carries 1027's discriminator verbatim, and the cal row it reads rides on that same failure arm. Its absence means the pool was built with the discriminator SHUT and the parent evidence would be gone. Build it with scripts/build_1031.sh first"; exit 1; }
# 1025's PARENT switch: 1027's block AND 1029's reader block AND 1030's writer block AND 1031's caller
# block are NESTED INSIDE 1025's publisher (the fault path is SHARED: ONE gate for it), so a record
# without STAGE90_XNU_USTACK_PROBE=1 means the cal rows print NOTHING.
grep -q '^STAGE90_XNU_USTACK_PROBE=1$' "$REC" || {
  echo "REFUSING: the record does not carry STAGE90_XNU_USTACK_PROBE=1 - 1027's discriminator, 1029's reader rows, 1030's writer rows AND 1031's caller rows are NESTED INSIDE 1025's publisher (the fault path is SHARED: ONE gate for it). With the parent gate shut the cal rows never execute ([[mi4-one-file-many-rungs]]). Build it with scripts/build_1031.sh first"; exit 1; }
# 1024's own switch: the widened vm_param.h:63 line reads STAGE90_XNU_VM_MAX_SPLIT, and it is what keeps
# the 1023 pthread storm away - the boot must reach launchctl for 1031 to have a caller row to read.
grep -q '^STAGE90_XNU_VM_MAX_SPLIT=1$' "$REC" || {
  echo "REFUSING: the record does not carry STAGE90_XNU_VM_MAX_SPLIT=1 - 1024's widened vm_param.h:63 line reads THIS switch. Its absence means the pool was built with the OLD ceiling (0x80000000), so the 1023 storm recurs and this rung would measure the wrong wall. Build it with scripts/build_1031.sh first"; exit 1; }
# 1023's row-24 gate reads STAGE90_XNU_IOS7_TRAPS; 1031 ADDS ONLY THE CALLER PROBE, so trap 24 must
# still be installed or the 1023 frontier (libxpc's port-allocation udf) is back.
grep -q '^STAGE90_XNU_IOS7_TRAPS=1$' "$REC" || {
  echo "REFUSING: the record does not carry STAGE90_XNU_IOS7_TRAPS=1 - 1023's row-24 gate widens to read THIS switch. Its absence means the pool was built without -DSTAGE90_XNU_IOS7_TRAPS=1, so row 24 stays kern_invalid and this rung would measure the 1023 frontier. Build it with scripts/build_1031.sh first"; exit 1; }
# The inherited switches this arm's set carries VERBATIM (1021d's set).
grep -q '^STAGE90_XNU_GENERAL_REGS=1$' "$REC" || {
  echo "REFUSING: the record does not carry STAGE90_XNU_GENERAL_REGS=1 - 1021d's -msoft-float flag must stay on, or the kernel-mode NEON undef at 0x8047b0ac returns and this rung would measure a different frontier"; exit 1; }
grep -q '^STAGE90_XNU_UNDEF_RAISE=1$' "$REC" || {
  echo "REFUSING: the record does not carry STAGE90_XNU_UNDEF_RAISE=1 - 1020's raise fix must stay on, or pid 1's genuine udf loops forever again (8183x measured) and 1031 would measure a different frontier"; exit 1; }
grep -q '^STAGE90_XNU_UNDEF_DIRECT=1$' "$REC" || {
  echo "REFUSING: the record does not carry STAGE90_XNU_UNDEF_DIRECT=1 - without the direct channel the udf witness can be silenced by the cap before the frontier (the 1017/1018 instrument defect)"; exit 1; }
# GLOBAL_FIX is a POOL switch declared only in the arm-extra drop-in (records/1020-build-defect.txt); it
# cannot be in the record.  **THE GREP BELOW IS THE PROCESS CHECK, NOT THE PROOF** - the by-value
# fingerprint below is what certifies the fix is in the pool object
# ([[mi4-self-written-record-is-not-a-constraint]]).
grep -qx 'STAGE90_XNU_GLOBAL_FIX=1 role=1031-caller-probe' "$LIVE/xnu_arm_entry-arm-extra.txt" || {
  echo "REFUSING: out/stage90/xnu_arm_entry-arm-extra.txt does not carry 'STAGE90_XNU_GLOBAL_FIX=1 role=1031-caller-probe' (it holds: '$(cat "$LIVE/xnu_arm_entry-arm-extra.txt" 2>/dev/null)') - the pool fix that keeps the retry storm gone is not declared by THIS build (build_1031.sh writes this line at its tail)"; exit 1; }
EXPECT_ARM=armed-d13-$(sha256sum "$LIVE/xnu_arm_entry.bin" | cut -c1-8)
echo "   arm = $EXPECT_ARM"

# BY VALUE (0-POOL): the inherited GLOBAL-FIX (1015b) is in the pool object the linked image was built
# from - `pmap_flush_tlbs` materializes `kernel_pmap` EXACTLY 3 times (OFF/Apple = 2).  1031 rebuilds the
# WHOLE pool (kern_exec.c is a POOL object), so the 1020 defect (a record-derived EXTRA dropping the
# GLOBAL_FIX token) is available again.
_gf_obj=out/xnu_kernel_obj_d13/osfmk_arm_pmap.o
[[ -f "$_gf_obj" ]] || { echo "REFUSING: $_gf_obj is absent - 1015b's GLOBAL-FIX cannot be certified"; exit 1; }
_gf_kp=$(arm-none-eabi-objdump -r "$_gf_obj" 2>/dev/null | awk '$1>="00000418" && $1<="00000640"' | grep -c 'MOVW_ABS_NC.*kernel_pmap' || true)
_gf_full=$(arm-none-eabi-objdump -r "$_gf_obj" 2>/dev/null | awk '$1>="00000418" && $1<="00000640"' | grep -c 'R_ARM_CALL.*arm_tlb_flushID$' || true)
_gf_asid=$(arm-none-eabi-objdump -r "$_gf_obj" 2>/dev/null | awk '$1>="00000418" && $1<="00000640"' | grep -c 'R_ARM_CALL.*arm_tlb_flushID_ASID$' || true)
[[ "$_gf_kp" == "3" && "$_gf_full" == "1" && "$_gf_asid" == "1" ]] || {
  echo "REFUSING: pmap_flush_tlbs materializes kernel_pmap x$_gf_kp (want 3), arm_tlb_flushID x$_gf_full / arm_tlb_flushID_ASID x$_gf_asid (want 1/1) - GLOBAL-FIX is NOT in the pool object, so the retry storm 1015b killed is BACK and the run would never reach the launchctl fault this rung exists to remove. Re-run scripts/build_1031.sh."; exit 1; }
echo "   (0-POOL) by value: pmap_flush_tlbs carries the 3rd kernel_pmap materialization ($_gf_kp sites) and the 1/1 flush arms - 1015b's GLOBAL-FIX IS in the pool object this image was built from"

# BY VALUE (0a): 1031'S OWN PROBE (STAGE90_XNU_CALLER_PROBE) IS IN THE POOL OBJECT - IT PRINTS, SO IT
# HAS A REAL `strings` FINGERPRINT.  The rows are published from osfmk/arm/trap.c's usermode DATA-abort
# failure arm (Site A); the staged tree must carry the gate and the FIRST/LAST row's format strings, and
# the POOL OBJECT must carry them too (build_entry.sh only LINKS pool objects, so an object the linker
# compiled from an un-staged trap.c would leave the press's capture with no cal row at all).  The
# source-content record is checked as a SECOND, independent read: the pool's manifest
# (out/xnu_kernel_src_d13.sha256, written by tools/gen_kernel_source_manifest.py) must name the SAME
# sha256 the staged trap.c hashes to, so a stale pool object (built before the probe was staged) fails
# even if its strings happen to match.
[[ -f tools/check_1031_capture.py ]] || {
  echo "REFUSING: tools/check_1031_capture.py is ABSENT - it is this press's capture reader and its by-value claim's checker, and there is no sound fallback. A press that skipped it could not adjudicate the pre-registered CAL-CALLER-TOP/CAL-CALLER-SIZE/CAL-CALLER-OTHER/CAL-MISSING/REGRESSION/G-CTL cells"; exit 1; }
_ke_src=$PWD/external/xnu-hd2-darwin13/xnu/osfmk/arm/trap.c
_src_rec=out/xnu_kernel_src_d13.sha256
[[ -f $_ke_src ]] || { echo "REFUSING: $_ke_src is absent - the staged trap.c is where 1031's caller-probe rows live, and a press that cannot read it cannot certify the probe is in the pool"; exit 1; }
[[ -f $_src_rec ]] || { echo "REFUSING: $_src_rec is absent - the pool's own source-content record is the independent read that the pool compiled THIS trap.c. Without it a stale object cannot be told from a fresh one. Re-run scripts/build_1031.sh"; exit 1; }
# (i) the staged source carries the switch gate, the first row's format string, and the patcher's marker.
grep -q 'defined(STAGE90_XNU_CALLER_PROBE) && STAGE90_XNU_CALLER_PROBE' "$_ke_src" || {
  echo "REFUSING: $_ke_src does not carry the STAGE90_XNU_CALLER_PROBE gate - tools/patch_d13_caller_probe.py was not staged into the tree, so the pool the linker saw was built WITHOUT the probe (build_entry.sh only LINKS pool objects) and the capture would carry no cal row. Re-run scripts/build_1031.sh"; exit 1; }
_cal_row=$(grep -c 'xnu_live_cal_r3=' "$_ke_src" || true)
_cal_end=$(grep -c '^#endif /\* STAGE90_XNU_CALLER_PROBE \*/' "$_ke_src" || true)
[[ "$_cal_row" == "1" && "$_cal_end" == "1" ]] || {
  echo "REFUSING: $_ke_src carries the xnu_live_cal_r3= row publisher x$_cal_row and the patcher's #endif marker x$_cal_end (want 1/1) - a partial or DOUBLE edit is exactly what the patcher REFUSES on, so the source is in a state no build of this rung produced. Re-stage with the builder's own staging step"; exit 1; }
# (ii) BY VALUE ON THE OBJECT: the pool's own source-content record names THIS content.
_ke_want=$(sha256sum "$_ke_src" | awk '{print $1}')
_ke_have=$(awk -v p="$_ke_src" '$2==p{print $1}' "$_src_rec" | head -1)
[[ -n "$_ke_have" ]] || {
  echo "REFUSING: $_src_rec names NO entry for $_ke_src - the pool's manifest does not cover trap.c, so the probe's content is unrecorded and cannot be certified (the record of record is written by tools/gen_kernel_source_manifest.py; ask who writes the file, [[mi4-self-written-record-is-not-a-constraint]]). Re-run scripts/build_1031.sh"; exit 1; }
[[ "$_ke_want" == "$_ke_have" ]] || {
  echo "REFUSING: $_ke_src hashes $_ke_want but the pool's source-content record says $_ke_have - the pool object was compiled from DIFFERENT content than the tree holds now ([[mi4-self-written-record-is-not-a-constraint]]: the record is written by the build that compiles, so a mismatch means the staged probe is NOT in the object the linker saw). Re-run scripts/build_1031.sh"; exit 1; }
echo "   (0a) by value: the staged trap.c carries the STAGE90_XNU_CALLER_PROBE gate with the xnu_live_cal_r3= row (x1) and the patcher's #endif marker (x1), AND the pool's own source-content record names the SAME sha256 ($_ke_want) - the caller probe IS in the object the linked image was built from"

# 0a-1. THE INHERITED PROBES ARE STILL IN THE TWO POOL OBJECTS (1027/1029/1030's parent evidence,
# carried VERBATIM).  1031 does not remove them: the PARENT cells are adjudicated FROM their
# xnu_live_abt_* / rdr_* / wrp_* rows, and a cal row can only be read if the fault it describes is the
# known fault.  The fingerprints are FORMAT STRINGS (trap.o) and SYMBOLS (kern_exec.o).  It also
# re-reads 1025's two survivors: 1027's block is NESTED inside 1025's, so a build that dropped the
# parent gate would leave the discriminator compiled-out ([[mi4-one-file-many-rungs]]).
_trap_obj=out/xnu_kernel_obj_d13/osfmk_arm_trap.o
_exec_obj=out/xnu_kernel_obj_d13/bsd_kern_kern_exec.o
[[ -f "$_trap_obj" ]] || { echo "REFUSING: $_trap_obj is absent - trap.c is where xnu_live_abt_lookup_far=* lives, and a press whose trap.o is missing cannot adjudicate the parent evidence"; exit 1; }
[[ -f "$_exec_obj" ]] || { echo "REFUSING: $_exec_obj is absent - kern_exec.c is where xnu_live_abt_proc_ustack and 1031's Site B accessor live, and a press whose kern_exec.o is missing cannot read user_stack (the advertised top the boundary write sits above) nor the region top"; exit 1; }
grep -qa '^xnu_live_abt_lookup_far=' <(strings "$_trap_obj") || {
  echo "REFUSING: $_trap_obj carries NO xnu_live_abt_lookup_far= publisher - the pool was NOT recompiled with STAGE90_XNU_ABT_ENTRY_PROBE=1 (the env -> global DEFINES channel of build_xnu_arm_kernel.sh) or the trap.c edit is not staged. The parent cells would have nothing to read. Re-run scripts/build_1031.sh"; exit 1; }
grep -qa '^xnu_live_rdr_far=' <(strings "$_trap_obj") || {
  echo "REFUSING: $_trap_obj lost 1029's xnu_live_rdr_far= publisher in this pool rebuild - 1031 BUILDS ON 1029's reader reading AND 1030's writer reading, so their rows must remain readable ([[mi4-one-file-many-rungs]]). Re-run scripts/build_1031.sh"; exit 1; }
grep -qa '^xnu_live_wrp_r4=' <(strings "$_trap_obj") || {
  echo "REFUSING: $_trap_obj lost 1030's xnu_live_wrp_r4= publisher in this pool rebuild - 1031's premise (r4 == far == the region's exclusive top) is READ FROM the wrp rows; without them the cal row is uncorroborated. Re-run scripts/build_1031.sh"; exit 1; }
grep -qa '^xnu_live_abt_vmfkrv=' <(strings "$_trap_obj") || {
  echo "REFUSING: $_trap_obj lost 1025's xnu_live_abt_vmfkrv= publisher in this pool rebuild - 1027's block is NESTED inside 1025's, so the parent rows would never run ([[mi4-one-file-many-rungs]]). Re-run scripts/build_1031.sh"; exit 1; }
grep -qa '^xnu_live_abt_proc_ustack$' <(strings "$_exec_obj") || {
  echo "REFUSING: $_exec_obj carries NO xnu_live_abt_proc_ustack symbol - the pool was NOT recompiled with STAGE90_XNU_ABT_ENTRY_PROBE=1 or the kern_exec.c edit is not staged. The \`far == ustack\` conjunct that names the known fault could not be read. Re-run scripts/build_1031.sh"; exit 1; }
grep -qa '^xnu_live_ustack_req=' <(strings "$_exec_obj") || {
  echo "REFUSING: $_exec_obj lost 1025's xnu_live_ustack_req= publisher in this pool rebuild - 1031 builds ON 1025/1026/1027/1028/1029/1030, not over them. Re-run scripts/build_1031.sh"; exit 1; }
echo "   (0a-1) by value: trap.o carries the xnu_live_abt_lookup_far= discriminator AND 1029's xnu_live_rdr_far= AND 1030's xnu_live_wrp_r4=; kern_exec.o carries the xnu_live_abt_proc_ustack accessor AND 1025's xnu_live_ustack_req= (the whole parent chain is still in the pool objects)"

# 0a-2. **1031'S OWN ROWS (xnu_live_cal_*) MUST BE IN THE POOL OBJECT *AND* IN THE LINKED IMAGE - A
# PROBE THAT PRINTS HAS A REAL strings FINGERPRINT, and THIS is where that fingerprint is read.**  The
# linked-image read matters independently of the object read: build_entry.sh only LINKS the pool
# objects, so an object the linker DROPPED would leave the press's capture with no cal row at all and
# 1031 could not answer its own question.  The `grep -qa P <(strings X)` form is required -
# `strings X | grep -q P` under pipefail returns 141 (SIGPIPE) when the string IS present
# ([[mi4-mutation-anchors-are-code-spans]] m1025).
grep -qa '^xnu_live_cal_r3=' <(strings "$_trap_obj") || {
  echo "REFUSING: $_trap_obj carries NO xnu_live_cal_r3= publisher - the pool was NOT recompiled with STAGE90_XNU_CALLER_PROBE=1 (the env -> global DEFINES channel of build_xnu_arm_kernel.sh) or the trap.c caller-probe edit is not staged. Without this string the press captures NO cal row and 1031's CAL-CALLER-TOP/CAL-CALLER-SIZE/CAL-CALLER-OTHER cells are UNSATISFIABLE. Re-run scripts/build_1031.sh"; exit 1; }
grep -qa '^xnu_live_cal_region_end=' <(strings "$_trap_obj") || {
  echo "REFUSING: $_trap_obj carries the cal row block but NOT xnu_live_cal_region_end= - a PARTIAL edit of the probe (the region-top tell row, the one the WHOLE rung turns on, is missing). Re-run scripts/build_1031.sh"; exit 1; }
grep -qa '^xnu_live_cal_proc_region_top$' <(strings "$_exec_obj") || {
  echo "REFUSING: $_exec_obj carries NO xnu_live_cal_proc_region_top symbol - 1031's Site B accessor (the region top BY VALUE from the allocator's own stash) is not in the pool object, so the cal frame's region_end would have to be believed from Site A's lookup alone with no independent value. Re-run scripts/build_1031.sh"; exit 1; }
grep -qa '^xnu_live_cal_r3=' <(strings "$LIVE/xnu_arm_entry.elf") || {
  echo "REFUSING: the LINKED $LIVE/xnu_arm_entry.elf carries NO xnu_live_cal_r3= string - the pool object carrying the cal rows was not linked into the image the press BOOTS, so the capture would have no cal row and 1031 could not answer its own question. Re-run scripts/build_1031.sh"; exit 1; }
grep -qa '^xnu_live_cal_region_end=' <(strings "$LIVE/xnu_arm_entry.elf") || {
  echo "REFUSING: the LINKED $LIVE/xnu_arm_entry.elf carries NO xnu_live_cal_region_end= string - the row the WHOLE rung turns on did not reach the image the press boots. Re-run scripts/build_1031.sh"; exit 1; }
echo "   (0a-2) by value: trap.o carries the STAGE90_XNU_CALLER_PROBE publisher xnu_live_cal_r3= AND the region-top tell xnu_live_cal_region_end=, kern_exec.o carries the Site B accessor xnu_live_cal_proc_region_top, AND the LINKED image carries xnu_live_cal_r3= / xnu_live_cal_region_end= (the reading 1031 is decided by reached the image the press boots)"

# 0a-0. the checker's OWN self-test - a checker that cannot fail is not a check
# ([[mi4-a-claim-in-a-comment-is-not-a-check]]).
python3 -I tools/check_1031_capture.py --selftest >/dev/null 2>&1 || {
  echo "REFUSING: tools/check_1031_capture.py --selftest did NOT PASS - the checker cannot certify anything (an inert checker would bless any capture)"; exit 1; }
echo "   (0a-0) by value: tools/check_1031_capture.py --selftest PASSes (the checker is live; CAL-CALLER-TOP / CAL-CALLER-SIZE / CAL-CALLER-OTHER / CAL-MISSING / REGRESSION / G-CTL arms all exercise, and the emitted-row parity is asserted against the patcher)"

# BY VALUE (0b): the inherited 1024 ceiling claim still holds on the LINKED image - 1031 adds only a
# print-only probe (it changes NO allocation and NO dispatch), so `task_create_internal` must still pass
# 0x40000000 to `vm_map_create`.
[[ -f tools/check_vm_max_split.py ]] || {
  echo "REFUSING: tools/check_vm_max_split.py is ABSENT - it is the inherited 1024 claim's by-value check on the linked image's task-map ceiling, and there is no sound fallback"; exit 1; }
python3 -I tools/check_vm_max_split.py --selftest >/dev/null 2>&1 || {
  echo "REFUSING: tools/check_vm_max_split.py --selftest did NOT PASS - the inherited ceiling checker cannot certify anything"; exit 1; }
python3 -I tools/check_vm_max_split.py "$LIVE/xnu_arm_entry.elf" --expect on >/dev/null 2>&1 || {
  echo "REFUSING: the LINKED image's task_create_internal does NOT pass 0x40000000 to vm_map_create - either 1024's widened vm_param.h:63 line did not reach the pool (the env -> global DEFINES channel), or a STALE pool object was linked (build_entry.sh only LINKS it). The task map's ceiling would then read 0x80000000 and this press would re-measure 1023's storm. Re-run scripts/build_1031.sh"; exit 1; }
echo "   (0b) by value: the LINKED image's task_create_internal passes 0x40000000 to vm_map_create (1024's ceiling is intact)"

# 0b-2. THE DISCRIMINATING CONTROL.  The SAME checker, `--expect off`, on a FROZEN arm whose ceiling is
# the PRE-SPLIT value 0x80000000.  The 1023 arm (armed-d13-10b79e5d) is exactly that arm.  **NOT THIS
# RUNG'S OWN ARM.**  If 10b79e5d's park is absent the clause SKIPS (this press must not hard-depend on a
# park).
_ctrl=$LIVE/frozen/armed-d13-10b79e5d/xnu_arm_entry.elf
if [[ -s $_ctrl ]]; then
  python3 -I tools/check_vm_max_split.py "$_ctrl" --expect off >/dev/null 2>&1 || {
    echo "REFUSING: the frozen 1023 elf (10b79e5d)'s ceiling does NOT read 0x80000000 in the --expect off direction - the checker is either broken or pointed at the wrong immediate, so the 'on' PASS above certifies nothing. A control that agrees with the test proves only that the checker says one thing"; exit 1; }
  echo "   (0b-2) by value: NEGATIVE CONTROL - the frozen 1023 elf (10b79e5d, PRE-SPLIT) reads the ceiling == 0x80000000 (--expect off PASSes), so the 'on' above is a reading and not a constant"
else
  echo "   (0b-2) SKIP: the frozen 1023 elf ($_ctrl) is absent - the pre-split park does not exist here, so this press does not hard-depend on it. The 'on' PASS above still stands; the discriminating control can be taken once a pre-split arm is parked"
fi

# BY VALUE (0c): the inherited 1021d NEON-free claim still holds on the LINKED image - 1031 recompiles
# the WHOLE pool (kern_exec.c), so the -msoft-float flag must still reach every object.
[[ -f tools/check_d13_no_neon.py ]] || { echo "REFUSING: tools/check_d13_no_neon.py is ABSENT - the inherited 1021d claim's by-value check"; exit 1; }
python3 -I tools/check_d13_no_neon.py --selftest >/dev/null 2>&1 || { echo "REFUSING: tools/check_d13_no_neon.py --selftest did NOT PASS"; exit 1; }
python3 -I tools/check_d13_no_neon.py "$LIVE/xnu_arm_entry.elf" --symbol mach_msg_send --expect none >/dev/null 2>&1 || {
  echo "REFUSING: the LINKED image's mach_msg_send still contains FP/NEON instructions - 1021d's -msoft-float flag did not reach the object the linker saw, or a STALE pool object was linked. Re-run scripts/build_1031.sh"; exit 1; }
echo "   (0c) by value: the LINKED image's mach_msg_send is NEON-free (1021d's -msoft-float holds)"

# BY VALUE (0d): the inherited 1020 raise claim still holds on the LINKED image.
[[ -f tools/check_d13_undef_raise.py ]] || { echo "REFUSING: tools/check_d13_undef_raise.py is ABSENT"; exit 1; }
python3 -I tools/check_d13_undef_raise.py "$LIVE/xnu_arm_entry.elf" --expect on >/dev/null 2>&1 || {
  echo "REFUSING: tools/check_d13_undef_raise.py \"$LIVE/xnu_arm_entry.elf\" --expect on did NOT pass - the linked image's sleh_undef does not carry 1020's moved \`return\`, so the udf loop is back. Re-run scripts/build_1031.sh"; exit 1; }
echo "   (0d) by value: tools/check_d13_undef_raise.py --expect on PASSes (1020's raise is intact)"

# BY VALUE (0e): the inherited 1023 row-24 claim still holds on the LINKED image - 1031 adds only a
# print-only probe, so `mach_trap_table[24]` must still be the construct handler with rows 25/41/42 still
# kern_invalid (the composition this rung inherits unchanged).  The 1023 control is also the G-CTL
# cell's live-control witness.
[[ -f tools/check_1023_trap24.py ]] || { echo "REFUSING: tools/check_1023_trap24.py is ABSENT - it is the inherited 1023 claim's by-value check on the linked image (build_1023's row 24)"; exit 1; }
python3 -I tools/check_1023_trap24.py --selftest >/dev/null 2>&1 || { echo "REFUSING: tools/check_1023_trap24.py --selftest did NOT PASS - the inherited row-24 checker cannot certify anything"; exit 1; }
python3 -I tools/check_1023_trap24.py "$LIVE/xnu_arm_entry.elf" --expect on >/dev/null 2>&1 || {
  echo "REFUSING: the LINKED image's mach_trap_table[24] is NOT the ios7lab_mach_port_construct_trap row any more (or rows 25/41/42 moved) - 1031 adds only a print-only probe and must ADD nothing else; with the row gone the 1023 frontier is back and this press would measure the wrong wall. Re-run scripts/build_1031.sh"; exit 1; }
echo "   (0e) by value: the LINKED image's mach_trap_table[24] IS the ios7lab_mach_port_construct_trap row (arg_count=5, rows 25/41/42 still kern_invalid)"

# BY VALUE (0f): the INHERITED PARENT probes ARE in the LINKED image - the discriminator's format string,
# 1029's reader row, 1030's writer row, AND 1031's own cal row must be reachable from the ELF (an object
# carrying them that the linker DROPPED would leave the parent cells blind).  build_1031.sh's 6b clause
# reads the same.
grep -qa '^xnu_live_abt_lookup_far=' <(strings "$LIVE/xnu_arm_entry.elf") || {
  echo "REFUSING: the LINKED $LIVE/xnu_arm_entry.elf carries NO xnu_live_abt_lookup_far= string - the pool object that has it was not linked, so the parent read would be blind. Re-run scripts/build_1031.sh"; exit 1; }
grep -qa '^xnu_live_wrp_r4=' <(strings "$LIVE/xnu_arm_entry.elf") || {
  echo "REFUSING: the LINKED $LIVE/xnu_arm_entry.elf carries NO xnu_live_wrp_r4= string - the pool object that has it was not linked, so 1031's premise cannot be corroborated. Re-run scripts/build_1031.sh"; exit 1; }
echo "   (0f) by value: the LINKED image carries the xnu_live_abt_lookup_far= discriminator AND 1030's xnu_live_wrp_r4= publisher (the parent probe reached the image the press boots)"

echo "== 1. the real iOS 7.1.2 rootfs as the card image (the COW base) =="
# [[mi4-one-value-two-definitions]]: `--real` COPIES the pristine rootfs over the card image, so a
# re-run of this press after 1032 would silently discard the 1032 guard (10 bytes at card 0x10183720)
# and the press would re-measure 1031 while every kernel gate stayed green.  Refuse a card that is
# already the 1032 patched one instead of overwriting the rung.
_guard=$(dd if=out/stage90/xnu_card_hfs.img bs=1 skip=$((16#10183720)) count=10 2>/dev/null | od -An -tx1 | tr -d ' \n')
[[ "$_guard" == "5010012801daf0bdc046" ]] && {
  echo "REFUSING: out/stage90/xnu_card_hfs.img carries the 1032 guard (5010012801daf0bdc046 at 0x10183720);"
  echo "  build_root_volumes.sh --real would OVERWRITE it with the pristine rootfs and this press would"
  echo "  re-measure 1031. Use scripts/press_1032.sh for this card, or revert the patch"
  echo "  (tools/patch_cache_libobjc_count.py --revert) and rebuild deliberately."; exit 1; }
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
# 1031 is a RESIDENT rung: if it does not return it keeps NO /proc/last_kmsg of its own, so start the
# HOST reader FIRST; it attaches the moment the payload enumerates. Primary channel: step 4.
USB_OUT="out/stage90/captures/usb-console-1031-$(date -u +%Y%m%d-%H%M%S).txt"
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
# **THE `set +e` AROUND `wait` IS LOAD-BEARING** ([[mi4-unguarded-wait-aborts-resident-press]]): a
# sigterm(143) under `set -e` aborts the script before the capture check, recovery and reading run -
# exactly what truncated the 1024/1025/1026/1027 press logs at the runner's line.
USB_RC=0
for _ in $(seq 1 40); do
  kill -0 "$USB_PID" 2>/dev/null || break
  sleep 0.25
done
if kill -0 "$USB_PID" 2>/dev/null; then
  kill "$USB_PID" 2>/dev/null || true
  USB_RC=-1
else
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

echo "== 5. read the recovered capture: run the 1031 reader and print its cell =="
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
  echo "   (its byte-identity to an EARLIER rung's crash family is the check that the slot was re-written"
  echo "    this run: if $_last still matches the 1030 press's own log, the run did NOT re-write the"
  echo "    ram-console slot and this is the stale slot, not the 1031 press's own boot)"
  set +e
  python3 -I tools/check_1031_capture.py "$_last"
  _rd_rc=$?
  set -e
  echo "   (reader exit $_rd_rc; 0 = a cell fired, 1 = G-CTL/WITHHOLD - both are readings)"
  fi
else
  echo "   NO recovered capture found under out/stage90/captures/recovered-*-last_kmsg.txt - there is"
  echo "   nothing to read; the run's log did not reach a recovery. Read records/1030-press-read.txt (the"
  echo "   reading this rung acts on) and re-run the recovery once the phone is visible"
  echo "   ([[mi4-device-dark-needs-power-press]])"
fi

echo "== DONE =="
echo "   adjudicate against docs/1031-design.md section 2 (1031 is a PROBE: it selects NO fix):"
echo "     CAL-CALLER-TOP   the region-end lookup HIT and r3 == r2 == far == region_end (with the writer's"
echo "                 loud frame shape r7-sp == 0xC) => the caller derived the WRITE ADDRESS as the stack"
echo "                 region's EXCLUSIVE TOP (the address IS the region's END).  NAME it; do NOT pick a"
echo "                 fix.  (A fix, if any, belongs in the CALLER's address computation, not the region"
echo "                 geometry - the geometry was already refuted, docs/1031-design.md section 5.)"
echo "     CAL-CALLER-SIZE  r3 == r2 but r3 is NOT the region end, a small (<= 0x1000) distance short of"
echo "                 it => the caller produced the address as a BASE+SIZE expression one page short of"
echo "                 the region end. NAME it; do NOT pick a fix."
echo "     CAL-CALLER-OTHER a complete frame naming NEITHER shape (or the loud frame shape is wrong, i.e."
echo "                 an early return before the call) => FAIL CLOSED: report CAL-CALLER-OTHER,"
echo "                 disassemble the caller (xnu_live_cal_pc / lr), do NOT choose a fix from this run."
echo "     CAL-MISSING     the cal group did not print (probe did not run / incomplete) => WITHHOLD."
echo "                 NEVER A NEGATIVE: an absent xnu_live_cal_* row means the PROBE DID NOT RUN, not"
echo "                 'no fault'."
echo "     REGRESSION  the boot stops EARLIER than 1030 (launchd not reached, or the trap24 /"
echo "                 port_construct / abt_pc control marks vanish, or a panic / the 1023 storm appears)"
echo "                 => WITHHOLD; a print-only probe must not have moved a lower address, so this is a"
echo "                 build/arm defect, not a finding"
echo "     G-CTL       no capture NEWER than this press's boot epoch, or no CONTROL mark live => WITHHOLD"
echo "                 (fail closed; an unsound instrument cannot read an absence)"
echo "   The 1030 writer rows (xnu_live_wrp_*) and 1029 reader rows (xnu_live_rdr_*) remain readable and"
echo "   are the parent readings this probe narrows; the probe itself adds NO fix (the geometry fix was"
echo "   REFUTED and the caller derivation is UNRESOLVED - docs/1031-design.md section 5)."
echo "   Machine check: python3 -I tools/check_1031_capture.py <capture>"
echo "   Read the 1030 reading this rung acts on: records/1030-press-read.txt (W-B-NAMED: r4 == far =="
echo "   the region's exclusive top, r4 - ustack == 0x1000) and docs/1031-design.md section 2 (the cell"
echo "   definitions) / section 5 (the refuted caller disassembly)."