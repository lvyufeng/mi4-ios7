#!/usr/bin/env bash
# ====================================================================================================
# press_1030.sh.  MODELLED ON scripts/press_1029.sh (itself the RESIDENT-rung press: the USB console
# reader + the /proc/last_kmsg recovery).  Design: docs/1030-design.md (rewritten 2026-10-17).
#
# Press 1030: **PROBE THE WRITER'S DERIVATION - publish the registers/fields that name WHY the store
# target lands AT the region's moving top.**
# Switch: **ONE NEW: STAGE90_XNU_WRITER_PROBE=1** (1029's FULL set is carried VERBATIM otherwise; the
# reader probe STAYS ON so the parent cells are comparable row-for-row).
#
# THE PREMISE (docs/1030-design.md sections 0b/0/1; records/1030-audit.txt).  1029 was a PROBE and it
# read **READER-NAMED / TOP-CONFIRMED BY VALUE** on 2026-10-17 (records/1029-press-read.txt):
#     xnu_live_rdr_far              = 0x2bd39000
#     xnu_live_rdr_ustack           = 0x2bd38000
#     xnu_live_rdr_far_minus_ustack = 0x00001000   <- one PAGE above the block top
#     xnu_live_rdr_blk_hi           = 0x2bd38000   <- == ustack: the block did NOT grow
#     xnu_live_rdr_entry_at_hit     = 0            <- `far` covered by NO entry (the decisive conjunct)
#     xnu_live_ustack_rc            = 0            <- the FIXED allocate SUCCEEDED (no ANYWHERE fallback)
# `entry_at_hit == 0` (far unowned) plus the population result (records/1030-audit.txt: `far` == the
# region's EXCLUSIVE TOP in ALL 61 far-rows) says the fault is a **boundary write AT the region's
# moving top**.
#
# **THE BASE-MOVE FIX (1030's FIRST SHAPE) WAS REFUTED BEFORE BUILD.**  docs/1030-design.md section 0b
# + records/1030-audit.txt CHECK 1: base-down and extent-up CANCEL.  `size` is already page-aligned, so
# `round_page(size + PAGE) == size + PAGE`; `top = (user_stack - size - PAGE) + (size + PAGE) =
# user_stack` -- the region's exclusive top is UNCHANGED (the same flush-top boundary).  And since `far
# == the region top` in every run, raising the top raises `far` (1028 proved it, page-exact) and
# lowering it lowers `far`.  **NO allocation-geometry change can help.**  The rung is therefore a PROBE
# of the WRITER's derivation, not a fix.
#
# THE WRITER (records/1030-audit.txt, lead's disassembly).  The fault site is
# `/usr/lib/libobjc.dylib + 0x14756`, `str.w r2,[r4],#4` -- a post-increment cursor store with
# `r4 == far`, inside a shared-cache / objc table REBASE (dyld slide fixup) writing into a
# CALLER-provided buffer.  The routine does `mov r4, r3` at entry, so **`r4` is the CALLER's 4th
# argument** and the boundary decision is in the CALLER.  The probe publishes, on the launchctl[2]
# usermode DATA-abort FAILURE arm (inside 1025's publisher, after 1026/1027/1029's blocks), the
# registers and process fields that separate the candidate derivations (tools/patch_d13_writer_probe.py,
# behind the ONE new switch): xnu_live_wrp_r4 / _sp / _r4_minus_sp / _userstack / _pc / _r3 / _r6 /
# _r12 / _block_bytes.
#
# THE PRE-REGISTERED CELLS (docs/1030-design.md section 2; read by tools/check_1030_capture.py):
#   W-A-NAMED   - `r4 - sp` is a SMALL CONSTANT frame offset (the store's base is sp-relative) => the
#                 initial stack handed to the thread is TOO SHALLOW; the fix (if any) is in the exec's
#                 initial-thread stack / frame size, NOT the region geometry.
#   W-B-NAMED   - `r4 == thread_userstack` / `p->user_stack` (the advertised top) => a stack-LIMIT /
#                 canary store; the fault is the intended limit check firing one page early.
#   W-OTHER     - `r4` is NEITHER => name what it is; **do NOT pick a fix** (fail closed; the next step
#                 is to single-step the writer, records/1030-audit.txt section 6).
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

echo "== 0. the record must be 1030's arm =="
# **1030'S OWN SWITCH FIRST: STAGE90_XNU_WRITER_PROBE.**  This rung IS the writer probe: the
# xnu_live_wrp_* rows are published from osfmk/arm/trap.c's DATA-abort failure arm (inside 1025's
# publisher, after 1026/1027/1029's blocks; tools/patch_d13_writer_probe.py).  A record without it
# means the pool was built with the probe SHUT ([[mi4-build-variant-comes-from-an-env-default]]: the
# switch rides the env -> global DEFINES channel of build_xnu_arm_kernel.sh), so the capture would
# carry NO wrp row while the record claimed 1 - and the press would read W-OTHER-missing for a reason
# that is the BUILD's, not the device's (the records/1020-build-defect.txt shape).
grep -q '^STAGE90_XNU_WRITER_PROBE=1$' "$REC" || {
  echo "REFUSING: the record does not carry STAGE90_XNU_WRITER_PROBE=1 - the writer probe this rung IS is gated by THIS switch (osfmk/arm/trap.c's xnu_live_wrp_* rows on the usermode DATA-abort failure arm, staged by tools/patch_d13_writer_probe.py). Its absence means the pool was built with the probe SHUT, so the capture would carry no wrp row at all while the record says the probe is live, and this press would not be a reading of THIS rung. Build it with scripts/build_1030.sh first"; exit 1; }
# 1029's switch, CARRIED: the reader probe (xnu_live_rdr_* rows) stays ON.  1030's premise -- `far` IS
# the region's exclusive/top boundary -- is READ FROM THOSE ROWS (entry_at_hit=0 + far == the region
# top); without them the parent evidence that the fault is the known boundary write is gone, and the
# checker would be reading a writer row with no corroboration of WHICH fault it describes.
grep -q '^STAGE90_XNU_READER_PROBE=1$' "$REC" || {
  echo "REFUSING: the record does not carry STAGE90_XNU_READER_PROBE=1 - 1030's premise (far IS the region's exclusive/top boundary) is READ FROM the xnu_live_rdr_* rows 1029 published, and they ride the same failure arm as the wrp rows. A pool built with the reader probe SHUT would leave the writer row uncorroborated. Build it with scripts/build_1030.sh first"; exit 1; }
# 1028's switch, CARRIED: 1030 changes no allocation at all (it is a probe).  The H2 edit stays IN the
# tree so the geometry the readings were taken against is unchanged (1028's arm is what put far at
# region_top / ustack + 0x1000 on 1028/1029).  Reverting it would move the geometry and make 1030's
# reading incomparable with 1029's.
grep -q '^STAGE90_XNU_H2_STACK_HEADROOM=1$' "$REC" || {
  echo "REFUSING: the record does not carry STAGE90_XNU_H2_STACK_HEADROOM=1 - 1030 probes the writer WITHOUT changing the allocation, so the geometry the 1028 fix established (far == region top, +0x1000 vs pre-fix) must stay in the tree or the wrp row describes a DIFFERENT geometry than 1029's. Build it with scripts/build_1030.sh first"; exit 1; }
# 1027's switch, CARRIED VERBATIM: the PARENT cells are read beside its xnu_live_abt_* rows, so a record
# without STAGE90_XNU_ABT_ENTRY_PROBE=1 means the pool was built with the discriminator SHUT and the
# capture would be silent on WHETHER the fault 1030's wrp row describes is the known fault.
grep -q '^STAGE90_XNU_ABT_ENTRY_PROBE=1$' "$REC" || {
  echo "REFUSING: the record does not carry STAGE90_XNU_ABT_ENTRY_PROBE=1 - 1030 carries 1027's discriminator verbatim, and the wrp row it reads rides on that same failure arm. Its absence means the pool was built with the discriminator SHUT and the parent evidence would be gone. Build it with scripts/build_1030.sh first"; exit 1; }
# 1025's PARENT switch: 1027's block AND 1029's reader block AND 1030's writer block are NESTED INSIDE
# 1025's publisher (the fault path is SHARED: ONE gate for it), so a record without
# STAGE90_XNU_USTACK_PROBE=1 means the wrp rows print NOTHING.
grep -q '^STAGE90_XNU_USTACK_PROBE=1$' "$REC" || {
  echo "REFUSING: the record does not carry STAGE90_XNU_USTACK_PROBE=1 - 1027's discriminator, 1029's reader rows AND 1030's writer rows are NESTED INSIDE 1025's publisher (the fault path is SHARED: ONE gate for it). With the parent gate shut the wrp rows never execute ([[mi4-one-file-many-rungs]]). Build it with scripts/build_1030.sh first"; exit 1; }
# 1024's own switch: the widened vm_param.h:63 line reads STAGE90_XNU_VM_MAX_SPLIT, and it is what keeps
# the 1023 pthread storm away - the boot must reach launchctl for 1030 to have a writer row to read.
grep -q '^STAGE90_XNU_VM_MAX_SPLIT=1$' "$REC" || {
  echo "REFUSING: the record does not carry STAGE90_XNU_VM_MAX_SPLIT=1 - 1024's widened vm_param.h:63 line reads THIS switch. Its absence means the pool was built with the OLD ceiling (0x80000000), so the 1023 storm recurs and this rung would measure the wrong wall. Build it with scripts/build_1030.sh first"; exit 1; }
# 1023's row-24 gate reads STAGE90_XNU_IOS7_TRAPS; 1030 ADDS ONLY THE WRITER PROBE, so trap 24 must
# still be installed or the 1023 frontier (libxpc's port-allocation udf) is back.
grep -q '^STAGE90_XNU_IOS7_TRAPS=1$' "$REC" || {
  echo "REFUSING: the record does not carry STAGE90_XNU_IOS7_TRAPS=1 - 1023's row-24 gate widens to read THIS switch. Its absence means the pool was built without -DSTAGE90_XNU_IOS7_TRAPS=1, so row 24 stays kern_invalid and this rung would measure the 1023 frontier. Build it with scripts/build_1030.sh first"; exit 1; }
# The inherited switches this arm's set carries VERBATIM (1021d's set).
grep -q '^STAGE90_XNU_GENERAL_REGS=1$' "$REC" || {
  echo "REFUSING: the record does not carry STAGE90_XNU_GENERAL_REGS=1 - 1021d's -msoft-float flag must stay on, or the kernel-mode NEON undef at 0x8047b0ac returns and this rung would measure a different frontier"; exit 1; }
grep -q '^STAGE90_XNU_UNDEF_RAISE=1$' "$REC" || {
  echo "REFUSING: the record does not carry STAGE90_XNU_UNDEF_RAISE=1 - 1020's raise fix must stay on, or pid 1's genuine udf loops forever again (8183x measured) and 1030 would measure a different frontier"; exit 1; }
grep -q '^STAGE90_XNU_UNDEF_DIRECT=1$' "$REC" || {
  echo "REFUSING: the record does not carry STAGE90_XNU_UNDEF_DIRECT=1 - without the direct channel the udf witness can be silenced by the cap before the frontier (the 1017/1018 instrument defect)"; exit 1; }
# GLOBAL_FIX is a POOL switch declared only in the arm-extra drop-in (records/1020-build-defect.txt); it
# cannot be in the record.  **THE GREP BELOW IS THE PROCESS CHECK, NOT THE PROOF** - the by-value
# fingerprint below is what certifies the fix is in the pool object
# ([[mi4-self-written-record-is-not-a-constraint]]).
grep -qx 'STAGE90_XNU_GLOBAL_FIX=1 role=1030-writer-probe' "$LIVE/xnu_arm_entry-arm-extra.txt" || {
  echo "REFUSING: out/stage90/xnu_arm_entry-arm-extra.txt does not carry 'STAGE90_XNU_GLOBAL_FIX=1 role=1030-writer-probe' (it holds: '$(cat "$LIVE/xnu_arm_entry-arm-extra.txt" 2>/dev/null)') - the pool fix that keeps the retry storm gone is not declared by THIS build (build_1030.sh writes this line at its tail)"; exit 1; }
EXPECT_ARM=armed-d13-$(sha256sum "$LIVE/xnu_arm_entry.bin" | cut -c1-8)
echo "   arm = $EXPECT_ARM"

# BY VALUE (0-POOL): the inherited GLOBAL-FIX (1015b) is in the pool object the linked image was built
# from - `pmap_flush_tlbs` materializes `kernel_pmap` EXACTLY 3 times (OFF/Apple = 2).  1030 rebuilds the
# WHOLE pool (kern_exec.c is a POOL object), so the 1020 defect (a record-derived EXTRA dropping the
# GLOBAL_FIX token) is available again.
_gf_obj=out/xnu_kernel_obj_d13/osfmk_arm_pmap.o
[[ -f "$_gf_obj" ]] || { echo "REFUSING: $_gf_obj is absent - 1015b's GLOBAL-FIX cannot be certified"; exit 1; }
_gf_kp=$(arm-none-eabi-objdump -r "$_gf_obj" 2>/dev/null | awk '$1>="00000418" && $1<="00000640"' | grep -c 'MOVW_ABS_NC.*kernel_pmap' || true)
_gf_full=$(arm-none-eabi-objdump -r "$_gf_obj" 2>/dev/null | awk '$1>="00000418" && $1<="00000640"' | grep -c 'R_ARM_CALL.*arm_tlb_flushID$' || true)
_gf_asid=$(arm-none-eabi-objdump -r "$_gf_obj" 2>/dev/null | awk '$1>="00000418" && $1<="00000640"' | grep -c 'R_ARM_CALL.*arm_tlb_flushID_ASID$' || true)
[[ "$_gf_kp" == "3" && "$_gf_full" == "1" && "$_gf_asid" == "1" ]] || {
  echo "REFUSING: pmap_flush_tlbs materializes kernel_pmap x$_gf_kp (want 3), arm_tlb_flushID x$_gf_full / arm_tlb_flushID_ASID x$_gf_asid (want 1/1) - GLOBAL-FIX is NOT in the pool object, so the retry storm 1015b killed is BACK and the run would never reach the launchctl fault this rung exists to remove. Re-run scripts/build_1030.sh."; exit 1; }
echo "   (0-POOL) by value: pmap_flush_tlbs carries the 3rd kernel_pmap materialization ($_gf_kp sites) and the 1/1 flush arms - 1015b's GLOBAL-FIX IS in the pool object this image was built from"

# BY VALUE (0a): 1030'S OWN PROBE (STAGE90_XNU_WRITER_PROBE) IS IN THE POOL OBJECT - IT PRINTS, SO IT
# HAS A REAL `strings` FINGERPRINT (unlike 1028's value-only H2 edit and unlike the refuted base-move).
# The rows are published from osfmk/arm/trap.c's usermode DATA-abort failure arm (Site A); the staged
# tree must carry the gate and the FIRST row's format string, and the POOL OBJECT must carry it too
# (build_entry.sh only LINKS pool objects, so an object the linker compiled from an un-staged trap.c
# would leave the press's capture with no wrp row at all).  The source-content record is checked as a
# SECOND, independent read: the pool's manifest (out/xnu_kernel_src_d13.sha256, written by
# tools/gen_kernel_source_manifest.py) must name the SAME sha256 the staged trap.c hashes to, so a
# stale pool object (built before the probe was staged) fails even if its strings happen to match.
[[ -f tools/check_1030_capture.py ]] || {
  echo "REFUSING: tools/check_1030_capture.py is ABSENT - it is this press's capture reader and its by-value claim's checker, and there is no sound fallback. A press that skipped it could not adjudicate the pre-registered W-A-NAMED/W-B-NAMED/W-OTHER/REGRESSION/G-CTL cells"; exit 1; }
_ke_src=$PWD/external/xnu-hd2-darwin13/xnu/osfmk/arm/trap.c
_src_rec=out/xnu_kernel_src_d13.sha256
[[ -f $_ke_src ]] || { echo "REFUSING: $_ke_src is absent - the staged trap.c is where 1030's writer-probe rows live, and a press that cannot read it cannot certify the probe is in the pool"; exit 1; }
[[ -f $_src_rec ]] || { echo "REFUSING: $_src_rec is absent - the pool's own source-content record is the independent read that the pool compiled THIS trap.c. Without it a stale object cannot be told from a fresh one. Re-run scripts/build_1030.sh"; exit 1; }
# (i) the staged source carries the switch gate, the first row's format string, and the patcher's marker.
grep -q 'defined(STAGE90_XNU_WRITER_PROBE) && STAGE90_XNU_WRITER_PROBE' "$_ke_src" || {
  echo "REFUSING: $_ke_src does not carry the STAGE90_XNU_WRITER_PROBE gate - tools/patch_d13_writer_probe.py was not staged into the tree, so the pool the linker saw was built WITHOUT the probe (build_entry.sh only LINKS pool objects) and the capture would carry no wrp row. Re-run scripts/build_1030.sh"; exit 1; }
_wrp_row=$(grep -c 'xnu_live_wrp_r4=' "$_ke_src" || true)
_wrp_end=$(grep -c '^#endif /\* STAGE90_XNU_WRITER_PROBE \*/' "$_ke_src" || true)
[[ "$_wrp_row" == "1" && "$_wrp_end" == "1" ]] || {
  echo "REFUSING: $_ke_src carries the xnu_live_wrp_r4= row publisher x$_wrp_row and the patcher's #endif marker x$_wrp_end (want 1/1) - a partial or DOUBLE edit is exactly what the patcher REFUSES on, so the source is in a state no build of this rung produced. Re-stage with the builder's own staging step"; exit 1; }
# (ii) BY VALUE ON THE OBJECT: the pool's own source-content record names THIS content.
_ke_want=$(sha256sum "$_ke_src" | awk '{print $1}')
_ke_have=$(awk -v p="$_ke_src" '$2==p{print $1}' "$_src_rec" | head -1)
[[ -n "$_ke_have" ]] || {
  echo "REFUSING: $_src_rec names NO entry for $_ke_src - the pool's manifest does not cover trap.c, so the probe's content is unrecorded and cannot be certified (the record of record is written by tools/gen_kernel_source_manifest.py; ask who writes the file, [[mi4-self-written-record-is-not-a-constraint]]). Re-run scripts/build_1030.sh"; exit 1; }
[[ "$_ke_want" == "$_ke_have" ]] || {
  echo "REFUSING: $_ke_src hashes $_ke_want but the pool's source-content record says $_ke_have - the pool object was compiled from DIFFERENT content than the tree holds now ([[mi4-self-written-record-is-not-a-constraint]]: the record is written by the build that compiles, so a mismatch means the staged probe is NOT in the object the linker saw). Re-run scripts/build_1030.sh"; exit 1; }
echo "   (0a) by value: the staged trap.c carries the STAGE90_XNU_WRITER_PROBE gate with the xnu_live_wrp_r4= row (x1) and the patcher's #endif marker (x1), AND the pool's own source-content record names the SAME sha256 ($_ke_want) - the writer probe IS in the object the linked image was built from"

# 0a-1. THE INHERITED DISCRIMINATOR IS STILL IN THE TWO POOL OBJECTS (1027/1029's parent evidence,
# carried VERBATIM).  1030 does not remove it: the PARENT cells are adjudicated FROM its xnu_live_abt_*
# rows, and a 1030 rdr row can only be read if the fault it describes is the known fault.  The
# fingerprints are a FORMAT STRING (trap.o) and a SYMBOL (kern_exec.o).  It also re-reads 1025's two
# survivors: 1027's block is NESTED inside 1025's, so a build that dropped the parent gate would leave
# the discriminator compiled-out ([[mi4-one-file-many-rungs]]).
_trap_obj=out/xnu_kernel_obj_d13/osfmk_arm_trap.o
_exec_obj=out/xnu_kernel_obj_d13/bsd_kern_kern_exec.o
[[ -f "$_trap_obj" ]] || { echo "REFUSING: $_trap_obj is absent - trap.c is where xnu_live_abt_lookup_far=* lives, and a press whose trap.o is missing cannot adjudicate the parent evidence"; exit 1; }
[[ -f "$_exec_obj" ]] || { echo "REFUSING: $_exec_obj is absent - kern_exec.c is where xnu_live_abt_proc_ustack lives, and a press whose kern_exec.o is missing cannot read user_stack (the advertised top the boundary write sits above)"; exit 1; }
grep -qa '^xnu_live_abt_lookup_far=' <(strings "$_trap_obj") || {
  echo "REFUSING: $_trap_obj carries NO xnu_live_abt_lookup_far= publisher - the pool was NOT recompiled with STAGE90_XNU_ABT_ENTRY_PROBE=1 (the env -> global DEFINES channel of build_xnu_arm_kernel.sh) or the trap.c edit is not staged. The parent cells would have nothing to read. Re-run scripts/build_1030.sh"; exit 1; }
grep -qa '^xnu_live_abt_proc_ustack$' <(strings "$_exec_obj") || {
  echo "REFUSING: $_exec_obj carries NO xnu_live_abt_proc_ustack symbol - the pool was NOT recompiled with STAGE90_XNU_ABT_ENTRY_PROBE=1 or the kern_exec.c edit is not staged. The `far == ustack` conjunct that names the known fault could not be read. Re-run scripts/build_1030.sh"; exit 1; }
grep -qa '^xnu_live_abt_vmfkrv=' <(strings "$_trap_obj") || {
  echo "REFUSING: $_trap_obj lost 1025's xnu_live_abt_vmfkrv= publisher in this pool rebuild - 1027's block is NESTED inside 1025's, so the parent rows would never run ([[mi4-one-file-many-rungs]]). Re-run scripts/build_1030.sh"; exit 1; }
grep -qa '^xnu_live_ustack_req=' <(strings "$_exec_obj") || {
  echo "REFUSING: $_exec_obj lost 1025's xnu_live_ustack_req= publisher in this pool rebuild - 1030 builds ON 1025/1026/1027/1028/1029, not over them. Re-run scripts/build_1030.sh"; exit 1; }
echo "   (0a-1) by value: trap.o carries the xnu_live_abt_lookup_far= publisher AND 1025's xnu_live_abt_vmfkrv=; kern_exec.o carries the xnu_live_abt_proc_ustack accessor AND 1025's xnu_live_ustack_req= (the parent discriminator AND its parent are still in the pool objects)"

# 0a-2. **1030'S OWN ROWS (xnu_live_wrp_*) MUST BE IN THE POOL OBJECT *AND* IN THE LINKED IMAGE - A
# PROBE THAT PRINTS HAS A REAL strings FINGERPRINT, and THIS is where that fingerprint is read.**  The
# linked-image read matters
# independently of the object read: build_entry.sh only LINKS the pool objects, so an object the linker
# DROPPED would leave the press's capture with no wrp row at all and 1030 could not answer its own
# question.  The `grep -qa P <(strings X)` form is required - `strings X | grep -q P` under pipefail
# returns 141 (SIGPIPE) when the string IS present ([[mi4-mutation-anchors-are-code-spans]] m1025).
grep -qa '^xnu_live_wrp_r4=' <(strings "$_trap_obj") || {
  echo "REFUSING: $_trap_obj carries NO xnu_live_wrp_r4= publisher - the pool was NOT recompiled with STAGE90_XNU_WRITER_PROBE=1 (the env -> global DEFINES channel of build_xnu_arm_kernel.sh) or the trap.c writer-probe edit is not staged. Without this string the press captures NO wrp row and 1030's W-A-NAMED/W-B-NAMED/W-OTHER cells are UNSATISFIABLE. Re-run scripts/build_1030.sh"; exit 1; }
grep -qa '^xnu_live_wrp_userstack=' <(strings "$_trap_obj") || {
  echo "REFUSING: $_trap_obj carries the wrp row block but NOT xnu_live_wrp_userstack= - a PARTIAL edit of the probe (the W-B tell row, the one that names r4 == p->user_stack, is missing). Re-run scripts/build_1030.sh"; exit 1; }
grep -qa '^xnu_live_wrp_r4=' <(strings "$LIVE/xnu_arm_entry.elf") || {
  echo "REFUSING: the LINKED $LIVE/xnu_arm_entry.elf carries NO xnu_live_wrp_r4= string - the pool object carrying the wrp rows was not linked into the image the press BOOTS, so the capture would have no wrp row and 1030 could not answer its own question. Re-run scripts/build_1030.sh"; exit 1; }
# The 1029 reader rows stay READABLE (they are the parent reading this probe narrows), so keep the
# inherited-rows clause: a rung that silently dropped its parent's rows could not be compared to it.
grep -qa '^xnu_live_rdr_far=' <(strings "$_trap_obj") || {
  echo "REFUSING: $_trap_obj lost 1029's xnu_live_rdr_far= publisher in this pool rebuild - 1030 BUILDS ON 1029's reader reading (far == the region exclusive top), so its rows must remain readable ([[mi4-one-file-many-rungs]]). Re-run scripts/build_1030.sh"; exit 1; }
grep -qa '^xnu_live_rdr_proc_argslen$' <(strings "$_exec_obj") || {
  echo "REFUSING: $_exec_obj lost 1029's xnu_live_rdr_proc_argslen symbol - Site B's kern_exec.c accessor is not in the pool object, so Site A's blk_lo/blk_bytes rows would be unreadable (or a stale object carries the old text). Re-run scripts/build_1030.sh"; exit 1; }
echo "   (0a-2) by value: trap.o carries the STAGE90_XNU_WRITER_PROBE publisher xnu_live_wrp_r4= AND the W-B tell xnu_live_wrp_userstack=, the LINKED image carries xnu_live_wrp_r4= (the reading 1030 is decided by reached the image the press boots), AND 1029's xnu_live_rdr_far= / xnu_live_rdr_proc_argslen are still present (the parent reading is not dropped)"

# 0a-0. the checker's OWN self-test - a checker that cannot fail is not a check
# ([[mi4-a-claim-in-a-comment-is-not-a-check]]).
python3 -I tools/check_1030_capture.py --selftest >/dev/null 2>&1 || {
  echo "REFUSING: tools/check_1030_capture.py --selftest did NOT PASS - the checker cannot certify anything (an inert checker would bless any capture)"; exit 1; }
echo "   (0a-0) by value: tools/check_1030_capture.py --selftest PASSes (the checker is live; W-A-NAMED / W-B-NAMED / W-OTHER / REGRESSION / G-CTL arms all exercise)"

# BY VALUE (0b): the inherited 1024 ceiling claim still holds on the LINKED image - 1030 adds only a
# PRINT-ONLY probe (it changes NO allocation and NO dispatch), so `task_create_internal` must still pass
# 0x40000000 to `vm_map_create`.
# Read on the LINKED image, because build_entry.sh only LINKS the pool objects (a stale object hides the
# old ceiling; records/1020-build-defect.txt).
[[ -f tools/check_vm_max_split.py ]] || {
  echo "REFUSING: tools/check_vm_max_split.py is ABSENT - it is the inherited 1024 claim's by-value check on the linked image's task-map ceiling, and there is no sound fallback"; exit 1; }
python3 -I tools/check_vm_max_split.py --selftest >/dev/null 2>&1 || {
  echo "REFUSING: tools/check_vm_max_split.py --selftest did NOT PASS - the inherited ceiling checker cannot certify anything"; exit 1; }
python3 -I tools/check_vm_max_split.py "$LIVE/xnu_arm_entry.elf" --expect on >/dev/null 2>&1 || {
  echo "REFUSING: the LINKED image's task_create_internal does NOT pass 0x40000000 to vm_map_create - either 1024's widened vm_param.h:63 line did not reach the pool (the env -> global DEFINES channel), or a STALE pool object was linked (build_entry.sh only LINKS it). The task map's ceiling would then read 0x80000000 and this press would re-measure 1023's storm. Re-run scripts/build_1030.sh"; exit 1; }
echo "   (0b) by value: the LINKED image's task_create_internal passes 0x40000000 to vm_map_create (1024's ceiling is intact)"

# 0b-2. THE DISCRIMINATING CONTROL.  The SAME checker, `--expect off`, on a FROZEN arm whose ceiling is
# the PRE-SPLIT value 0x80000000 - i.e. an arm built BEFORE 1024's vm_param.h:63 widening.  The 1023 arm
# (armed-d13-10b79e5d, role=1023-trap24, VM_MAX_SPLIT UNSET) is exactly that arm.  The (10b79e5d -> off
# PASS, this arm -> on PASS) pair is what proves the checker DISCRIMINATES rather than reporting one
# constant in both directions.  **NOT THIS RUNG'S OWN ARM.**  If 10b79e5d's park is absent the clause
# SKIPS (this press must not hard-depend on a park).
_ctrl=$LIVE/frozen/armed-d13-10b79e5d/xnu_arm_entry.elf
if [[ -s $_ctrl ]]; then
  python3 -I tools/check_vm_max_split.py "$_ctrl" --expect off >/dev/null 2>&1 || {
    echo "REFUSING: the frozen 1023 elf (10b79e5d)'s ceiling does NOT read 0x80000000 in the --expect off direction - the checker is either broken or pointed at the wrong immediate, so the 'on' PASS above certifies nothing. A control that agrees with the test proves only that the checker says one thing"; exit 1; }
  echo "   (0b-2) by value: NEGATIVE CONTROL - the frozen 1023 elf (10b79e5d, PRE-SPLIT) reads the ceiling == 0x80000000 (--expect off PASSes), so the 'on' above is a reading and not a constant"
else
  echo "   (0b-2) SKIP: the frozen 1023 elf ($_ctrl) is absent - the pre-split park does not exist here, so this press does not hard-depend on it. The 'on' PASS above still stands; the discriminating control can be taken once a pre-split arm is parked"
fi

# BY VALUE (0c): the inherited 1021d NEON-free claim still holds on the LINKED image - 1030 recompiles
# the WHOLE pool (kern_exec.c), so the -msoft-float flag must still reach every object.
[[ -f tools/check_d13_no_neon.py ]] || { echo "REFUSING: tools/check_d13_no_neon.py is ABSENT - the inherited 1021d claim's by-value check"; exit 1; }
python3 -I tools/check_d13_no_neon.py --selftest >/dev/null 2>&1 || { echo "REFUSING: tools/check_d13_no_neon.py --selftest did NOT PASS"; exit 1; }
python3 -I tools/check_d13_no_neon.py "$LIVE/xnu_arm_entry.elf" --symbol mach_msg_send --expect none >/dev/null 2>&1 || {
  echo "REFUSING: the LINKED image's mach_msg_send still contains FP/NEON instructions - 1021d's -msoft-float flag did not reach the object the linker saw, or a STALE pool object was linked. Re-run scripts/build_1030.sh"; exit 1; }
echo "   (0c) by value: the LINKED image's mach_msg_send is NEON-free (1021d's -msoft-float holds)"

# BY VALUE (0d): the inherited 1020 raise claim still holds on the LINKED image.
[[ -f tools/check_d13_undef_raise.py ]] || { echo "REFUSING: tools/check_d13_undef_raise.py is ABSENT"; exit 1; }
python3 -I tools/check_d13_undef_raise.py "$LIVE/xnu_arm_entry.elf" --expect on >/dev/null 2>&1 || {
  echo "REFUSING: tools/check_d13_undef_raise.py \"$LIVE/xnu_arm_entry.elf\" --expect on did NOT pass - the linked image's sleh_undef does not carry 1020's moved \`return\`, so the udf loop is back. Re-run scripts/build_1030.sh"; exit 1; }
echo "   (0d) by value: tools/check_d13_undef_raise.py --expect on PASSes (1020's raise is intact)"

# BY VALUE (0e): the inherited 1023 row-24 claim still holds on the LINKED image - 1030 adds only a
# print-only probe, so `mach_trap_table[24]` must still be the construct handler with rows 25/41/42 still
# kern_invalid (the composition this rung inherits unchanged).  The 1023 control is also the G-CTL
# cell's live-control witness.
[[ -f tools/check_1023_trap24.py ]] || { echo "REFUSING: tools/check_1023_trap24.py is ABSENT - it is the inherited 1023 claim's by-value check on the linked image (build_1023's row 24)"; exit 1; }
python3 -I tools/check_1023_trap24.py --selftest >/dev/null 2>&1 || { echo "REFUSING: tools/check_1023_trap24.py --selftest did NOT PASS - the inherited row-24 checker cannot certify anything"; exit 1; }
python3 -I tools/check_1023_trap24.py "$LIVE/xnu_arm_entry.elf" --expect on >/dev/null 2>&1 || {
  echo "REFUSING: the LINKED image's mach_trap_table[24] is NOT the ios7lab_mach_port_construct_trap row any more (or rows 25/41/42 moved) - 1030 adds only a print-only probe and must ADD nothing else; with the row gone the 1023 frontier is back and this press would measure the wrong wall. Re-run scripts/build_1030.sh"; exit 1; }
echo "   (0e) by value: the LINKED image's mach_trap_table[24] IS the ios7lab_mach_port_construct_trap row (arg_count=5, rows 25/41/42 still kern_invalid)"

# BY VALUE (0f): the INHERITED PARENT probe IS in the LINKED image - the discriminator's format string
# AND 1025's publisher must be reachable from the ELF (an object carrying them that the linker DROPPED
# would leave the parent cells blind; 1030's own rdr dependency is certified in 0a-2 above and has the
# same shape).  build_1030.sh's 6b clause reads the same.
grep -qa '^xnu_live_abt_lookup_far=' <(strings "$LIVE/xnu_arm_entry.elf") || {
  echo "REFUSING: the LINKED $LIVE/xnu_arm_entry.elf carries NO xnu_live_abt_lookup_far= string - the pool object that has it was not linked, so the parent read would be blind. Re-run scripts/build_1030.sh"; exit 1; }
grep -qa '^xnu_live_abt_vmfkrv=' <(strings "$LIVE/xnu_arm_entry.elf") || {
  echo "REFUSING: the LINKED $LIVE/xnu_arm_entry.elf carries NO xnu_live_abt_vmfkrv= string - the pool object that has it was not linked, so the fault's own co-reading is impossible. Re-run scripts/build_1030.sh"; exit 1; }
echo "   (0f) by value: the LINKED image carries the xnu_live_abt_lookup_far= discriminator AND 1025's xnu_live_abt_vmfkrv= publisher (the parent probe reached the image the press boots)"

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
# 1030 is a RESIDENT rung: if it does not return it keeps NO /proc/last_kmsg of its own, so start the
# HOST reader FIRST; it attaches the moment the payload enumerates. Primary channel: step 4.
USB_OUT="out/stage90/captures/usb-console-1030-$(date -u +%Y%m%d-%H%M%S).txt"
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

echo "== 5. read the recovered capture: run the 1030 reader and print its cell =="
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
  echo "    this run: if $_last still matches the 1029 press's own log, the run did NOT re-write the"
  echo "    ram-console slot and this is the stale slot, not the 1030 press's own boot)"
  set +e
  python3 -I tools/check_1030_capture.py "$_last"
  _rd_rc=$?
  set -e
  echo "   (reader exit $_rd_rc; 0 = a cell fired, 1 = G-CTL/WITHHOLD - both are readings)"
  fi
else
  echo "   NO recovered capture found under out/stage90/captures/recovered-*-last_kmsg.txt - there is"
  echo "   nothing to read; the run's log did not reach a recovery. Read records/1029-press-read.txt (the"
  echo "   reading this rung acts on) and re-run the recovery once the phone is visible"
  echo "   ([[mi4-device-dark-needs-power-press]])"
fi

echo "== DONE =="
echo "   adjudicate against docs/1030-design.md section 2 (1030 is a PROBE: it selects NO fix):"
echo "     W-A-NAMED   the wrp rows are live and r4 is SP-RELATIVE: 0 < (r4 - sp) <= 0x10000 (a small"
echo "                 frame-shaped offset) => the faulting cursor is a stack frame slot, so the initial"
echo "                 stack / block is too shallow for the writer's VLA.  NAME it; do NOT pick a fix."
echo "     W-B-NAMED   r4 == p->user_stack (xnu_live_wrp_r4_minus_ustack == 0) OR r4 == the region's"
echo "                 exclusive top (== 0x1000 on the H2-grown arm 1028/1029 built) => the writer is"
echo "                 storing AT the advertised/region top, i.e. a stack-LIMIT store, not a frame offset."
echo "     W-OTHER     r4 is NEITHER (or r4 == sp exactly, delta 0) => the probe names a value it does not"
echo "                 explain.  FAIL CLOSED: report W-OTHER, disassemble the caller (xnu_live_wrp_pc /"
echo "                 xnu_live_wrp_r3), do NOT choose a fix from this run."
echo "     REGRESSION  the boot stops EARLIER than 1029 (launchd not reached, or the trap24 /"
echo "                 port_construct / abt_pc control rows vanish, or a panic / the 1023 storm appears)"
echo "                 => WITHHOLD; a print-only probe must not have moved a lower address, so this is a"
echo "                 build/arm defect, not a finding"
echo "     G-CTL       no capture NEWER than this press's boot epoch, or no CONTROL row live => WITHHOLD"
echo "                 (fail closed; an unsound instrument cannot read an absence).  NEVER A NEGATIVE: an"
echo "                 absent xnu_live_wrp_* row means the PROBE DID NOT RUN, not 'no fault'"
echo "   The 1029 reader rows (xnu_live_rdr_*) remain readable and are the parent reading this probe"
echo "   narrows; the probe itself adds NO fix (the base-move shape was REFUTED - see records/1030-audit.txt)."
echo "   Machine check: python3 -I tools/check_1030_capture.py <capture>"
echo "   Read the 1029 reading this rung acts on: records/1029-press-read.txt (READER-NAMED /"
echo "   TOP-CONFIRMED BY VALUE - entry_at_hit=0, far - ustack == 0x1000) and docs/1030-design.md"
echo "   section 0b (the refuted extent fix) / section 2 (the cell definitions)."