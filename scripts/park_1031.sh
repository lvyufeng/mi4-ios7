#!/usr/bin/env bash
# ====================================================================================================
# park_1031.sh.  MODELLED BYTE-STRUCTURALLY ON scripts/park_1029.sh (itself the 1028/1027/1024/1021d/
# 1015b pattern), WITH 1015b's POOL-MOVED DISCIPLINE: this rung's edits are POOL FILES
# (`osfmk/arm/trap.c` AND `bsd/kern/kern_exec.c`), so the pool moves and the entry .bin whose sha8 IS the
# arm moves with it.
#
# Park 1031 (THE CALLER PROBE: publish the CALLER's register frame at the fault AND the stack region's
# EXCLUSIVE TOP by value) and append its block to records/revert-set.txt.
#
# 1031 = 1030's switch set VERBATIM with **ONE NEW SWITCH: STAGE90_XNU_CALLER_PROBE=1**.  Design:
# docs/1031-design.md.
#
# WHY.  1030's press RAN and its own console was recovered (records/1030-press-read.txt).  The reading is
# **W-B-NAMED**, BY VALUE:
#     xnu_live_wrp_r4   == xnu_live_wrp_far            (the store target IS the fault address)
#     xnu_live_wrp_r6   == xnu_live_wrp_r4             (the caller passed the same value as r2 and r3)
#     xnu_live_wrp_userstack = 0x2bdad000
#     xnu_live_wrp_r4_minus_ustack = 0x00001000        (one PAGE above the block top)
#     xnu_live_wrp_r4_minus_far = 0
# The writer is `/usr/lib/libobjc.dylib + 0x14756`, `str.w r2,[r4],#4`, and its prologue is
# `push {r4,r5,r6,r7,lr}; add r7,sp,#12` with `mov r4,r3`, so **r4 is the CALLER's 4th argument**.  The
# faulting store target IS the region's EXCLUSIVE TOP; WHO derived it -- the caller -- is unresolved.
#
# **THE PRIOR DISASSEMBLY CLAIM IS REFUTED BY THE RAW FRAME.**  A disassembly of the caller claimed it
# derives r3 as `sub.w rN, sp, r#N, lsl #2` (a DOWNWARD alloca off sp).  The 1030 capture shows
# `sp = 0x2bdac074` and `r4 = sp + 0x1F8C`, so r4 lies ABOVE sp -- a sub-off-sp cannot produce it.  The
# caller's derivation is UNRESOLVED, and 1031 is the instrument that measures it (it makes NO fix and
# changes NO allocation).  docs/1031-design.md section 5.
#
# **THE ARM (TWO POOL EDITS, one switch).**  Staged by tools/patch_d13_caller_probe.py (anchor +
# done-mark per file; refuses a hand edit) with a two-arm proof (`--verify-off` proves the OFF arm is the
# 1030 tree's bytes):
#   osfmk/arm/trap.c      Site A: the `xnu_live_cal_*` rows on the usermode DATA-abort FAILURE arm,
#                         INSIDE 1025's publisher and AFTER 1026/1027/1029's AND 1030's blocks (dfar /
#                         arm_ctx / thread / map / code all in scope).  REPUBLISHES the caller's register
#                         frame plus ONE read-only `vm_map_lookup_entry(map, trunc_page(far) - 4, &e)`
#                         whose `e->vme_end` IS the region's exclusive top when far is the top.
#   bsd/kern/kern_exec.c  Site B: the accessor `xnu_live_cal_proc_region_top` (the region top BY VALUE
#                         from the allocator's own stash) beside 1026's, PLUS two `p_live_stack_top`
#                         stashes at create_unix_stack (FIXED success + ANYWHERE fallback).
#
# **THE CHANNEL IS THE GLOBAL `DEFINES` ARRAY of tools/build_xnu_arm_kernel.sh (env), NOT EXTRA.**
# build_1031.sh carries that array's block and arrests a `-DSTAGE90_XNU_CALLER_PROBE` in EXTRA (the
# records/1020-build-defect.txt shape), so an EXTRA-only build cannot ship a stale pool behind a green
# build.
#
# **THIS IS A POOL-REBUILD RUNG (the 1015b shape).**  trap.c and kern_exec.c are POOL files;
# `build_entry.sh` only LINKS the pool objects, so a green entry build says NOTHING about this half.
# **THIS RUNG DOES PRINT**, so it HAS a real `strings` fingerprint in the objects (`xnu_live_cal_r3=` in
# trap.o, the `xnu_live_cal_proc_region_top` symbol in kern_exec.o) - and the park reads them OFF THE
# OBJECTS first, then re-reads them on the FROZEN bytes.
#
# **[[mi4-one-file-many-rungs]].**  FIVE rungs edit bsd/kern/kern_exec.c (1025 / 1026 / 1028 / 1029 /
# 1031) and SEVEN edit osfmk/arm/trap.c (994 / 1020 / 1025 / 1026 / 1029 / 1030 / 1031).  A cleanup
# `git checkout --` SILENTLY reverts the others and the failure surfaces LATE (the pool compiles; the
# INHERITED check refuses the LINKED image).  The park's own by-value clauses catch a build that dropped
# the parents.
#
# **THE CARRIERS.**  The record carries `STAGE90_XNU_CALLER_PROBE=1` (the switch the probe is gated by AND
# the readability carrier) AND 1030's `STAGE90_XNU_WRITER_PROBE=1` AND 1029's `STAGE90_XNU_READER_PROBE=1`
# (the parent readings).  The declaration carrier out/stage90/xnu_arm_entry-arm-extra.txt is written by
# THIS build's tail as `STAGE90_XNU_GLOBAL_FIX=1 role=1031-caller-probe` (1015b's GLOBAL_FIX is a POOL
# switch no writer in src/entry/ echoes).  A grep of that file is a PROCESS check; the by-value clauses
# below are what actually certify the arm ([[mi4-self-written-record-is-not-a-constraint]]).
#
# THE 1031 VERDICT CELLS (docs/1031-design.md section 2; the press reads them off the capture via
# tools/check_1031_capture.py):
#   CAL-CALLER-TOP   - region_end_hit == 1 AND region_end == far AND r3 == r2 == far AND r7 - sp == 0xC:
#                      the caller derived the WRITE ADDRESS as the stack region's EXCLUSIVE TOP.
#   CAL-CALLER-SIZE  - r3 == r2, r3 != region_end, 0 < (region_end - r3) <= 0x1000: a base+size
#                      expression one page short of the region end.
#   CAL-CALLER-OTHER - a complete frame naming NEITHER shape (or the loud frame shape is wrong): fail
#                      closed and NAME the missing conjunct; pick NO fix.
#   CAL-MISSING      - the cal group did not print (probe did not run / incomplete) => WITHHOLD.
#   REGRESSION       - launchd absent / trap24 rows vanish / port_construct result=0 vanish / panic / the
#                      1023 storm.
#   G-CTL            - no capture NEWER than this press's boot epoch => WITHHOLD (the stale-slot rule).
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

# The arm name IS the entry bin's sha8 (the project's rule).  Derive it.  (The static refusal list that
# 1029 kept cannot fire for a 1031 build - 1031's probe moves the pool and therefore the bin.)
ARM=armed-d13-$(sha256sum "$LIVE/xnu_arm_entry.bin" | cut -c1-8)
[[ $ARM == armed-d13-8034562e ]] && { echo "REFUSING: $LIVE holds 1030's PRESSED arm (8034562e) - the arm 1030 was pressed as (its writer-probe pool); 1031 builds ON it, and re-parking it under a 1031 label would freeze 1030's bytes as this rung's own. build 1031 first"; exit 1; }
[[ $ARM == armed-d13-35a7e83e ]] && { echo "REFUSING: $LIVE holds 1028's arm (35a7e83e); build 1031 first"; exit 1; }
[[ $ARM == armed-d13-10b79e5d ]] && { echo "REFUSING: $LIVE holds 1023's arm (10b79e5d); build 1031 first"; exit 1; }

# ====================================================================================================
# 1031'S OWN CHANGE, BY VALUE, FIRST - BEFORE EVERY INHERITED REGRESSION CLAUSE.
# **THE ORDER IS THE POINT.**  A park that lost this rung's probe must fail HERE, on ITS OWN claim (the
# record's switch + the STAGED source's two blocks + the two pool objects' `strings` fingerprints),
# rather than further down where an inherited clause would stop it for a reason that names the wrong thing.
# ====================================================================================================
echo "== 1031's OWN change, by value, first =="

# (a) THE RECORD'S OWN KEY.  `STAGE90_XNU_CALLER_PROBE=1` is BOTH the switch the probe is gated by AND the
#     readability carrier.  Absent it, the pool was compiled with BOTH blocks SHUT: the trap.c rows never
#     print and the kern_exec.c accessor/stashes do not exist, so the press would read CAL-MISSING for a
#     reason that is not the device's, and the arm is not 1031's.
grep -q '^STAGE90_XNU_CALLER_PROBE=1$' "$LIVE/xnu_arm_entry-config.txt" || {
  echo "REFUSING: the record does not carry STAGE90_XNU_CALLER_PROBE=1 - the caller probe this rung IS is gated by THIS switch, and it is set on this arm. Its absence means the pool was built with Site A/B SHUT, so no xnu_live_cal_* row could ever be published and 1031 would read CAL-MISSING for a reason that is not the device's. Build with scripts/build_1031.sh"; exit 1; }

# (a2) 1030'S KEY, CARRIED VERBATIM.  1031's premise -- `r4 == far == the region's exclusive top` -- is
#      READ FROM the wrp rows; a record without STAGE90_XNU_WRITER_PROBE=1 would leave the caller reading
#      uncorroborated (the cal row would describe an unnamed fault).
grep -q '^STAGE90_XNU_WRITER_PROBE=1$' "$LIVE/xnu_arm_entry-config.txt" || {
  echo "REFUSING: the record does not carry STAGE90_XNU_WRITER_PROBE=1 - 1031 carries 1030's writer probe verbatim, and its premise (r4 == far == the region's exclusive top) is READ FROM the xnu_live_wrp_* rows. Its absence means the pool was built with the writer probe SHUT, so the cal row would be uncorroborated. Build with scripts/build_1031.sh"; exit 1; }

# (a3) 1029'S KEY, CARRIED VERBATIM.  1030's premise (far IS the region's exclusive top) is itself READ
#      FROM the rdr rows; a record without STAGE90_XNU_READER_PROBE=1 would break the parent chain.
grep -q '^STAGE90_XNU_READER_PROBE=1$' "$LIVE/xnu_arm_entry-config.txt" || {
  echo "REFUSING: the record does not carry STAGE90_XNU_READER_PROBE=1 - 1031 carries 1030's and 1029's probes verbatim (the parent readings this probe narrows). Its absence breaks the parent chain. Build with scripts/build_1031.sh"; exit 1; }

# (a4) 1028'S KEY, CARRIED VERBATIM.  1031 ADDS the caller probe to 1030's set, not instead of it: the H2
#      fix is what PUT the region top at ustack + 0x1000, and that geometry IS the reading 1031 adjudicates
#      (r4 - ustack == 0x1000).  Reverting it would move the boundary and the cal frame would describe a
#      different geometry.
grep -q '^STAGE90_XNU_H2_STACK_HEADROOM=1$' "$LIVE/xnu_arm_entry-config.txt" || {
  echo "REFUSING: the record does not carry STAGE90_XNU_H2_STACK_HEADROOM=1 - 1031 carries 1030's and 1028's H2 fix verbatim, and its `r4 - ustack == 0x1000` conjunct is the geometry THAT fix produced. Its absence means the fault would sit at the region top and this arm is not the one docs/1031-design.md s.2 pre-registers. Build with scripts/build_1031.sh"; exit 1; }

# (a5) 1027'S KEY, CARRIED VERBATIM.  1031's cal rows ride the SAME failure arm as the 1026/1027
#      discriminator (the parent cells must still fire); a record without STAGE90_XNU_ABT_ENTRY_PROBE=1
#      would leave the parent cells impossible.
grep -q '^STAGE90_XNU_ABT_ENTRY_PROBE=1$' "$LIVE/xnu_arm_entry-config.txt" || {
  echo "REFUSING: the record does not carry STAGE90_XNU_ABT_ENTRY_PROBE=1 - 1031 carries 1027's discriminator verbatim as its PARENT CELLS, and the capture's xnu_live_abt_* rows are read beside the new ones. Its absence means the pool was built with the discriminator SHUT and half the reading would be gone. Build with scripts/build_1031.sh"; exit 1; }

# (a6) 1025'S PARENT KEY.  1031's Site A rows are NESTED INSIDE 1025's publisher block, so a record
#      without STAGE90_XNU_USTACK_PROBE=1 means the rows never execute (their parent gate is shut) even
#      with 1031's switch on.
grep -q '^STAGE90_XNU_USTACK_PROBE=1$' "$LIVE/xnu_arm_entry-config.txt" || {
  echo "REFUSING: the record does not carry STAGE90_XNU_USTACK_PROBE=1 - 1031's Site A rows are NESTED INSIDE 1025's publisher block, so with the parent gate shut the rows never execute and the capture would be silent on the caller question while the record says the probe is live ([[mi4-one-file-many-rungs]]). Build with scripts/build_1031.sh"; exit 1; }

# (a7) **1031'S OWN CHANGE, ON THE STAGED SOURCE.**  This rung PRINTS, so the object-side fingerprints
#      below are REAL strings - but the staged-tree counts are still the first (cheapest, most specific)
#      read of a partial or double edit, and the `#endif` counts prove each gate is BRACKETED
#      ([[mi4-off-option-two-spellings]]).
_tr_src=$PWD/external/xnu-hd2-darwin13/xnu/osfmk/arm/trap.c
_ke_src=$PWD/external/xnu-hd2-darwin13/xnu/bsd/kern/kern_exec.c
[[ -f $_tr_src ]] || { echo "REFUSING: $_tr_src is absent - the staged trap.c this park reads is not on disk"; exit 1; }
[[ -f $_ke_src ]] || { echo "REFUSING: $_ke_src is absent - the staged kern_exec.c this park reads is not on disk"; exit 1; }
[[ $(grep -c 'xnu_live_cal_r3=' "$_tr_src") == 1 ]] || {
  echo "REFUSING: the staged $_tr_src does not carry EXACTLY 1 xnu_live_cal_r3= line - Site A's rows are not staged, or a partial/double edit landed (the 1031 patcher REFUSES the latter, so the tree is in a state no build of this rung produced). Build with scripts/build_1031.sh"; exit 1; }
[[ $(grep -c 'xnu_live_cal_region_end=' "$_tr_src") == 1 ]] || {
  echo "REFUSING: the staged $_tr_src does not carry EXACTLY 1 xnu_live_cal_region_end= line - the region-top tell, the row the WHOLE rung turns on, is missing. Build with scripts/build_1031.sh"; exit 1; }
[[ $(grep -c '^#endif /\* STAGE90_XNU_CALLER_PROBE \*/' "$_tr_src") == 1 ]] || {
  echo "REFUSING: the staged $_tr_src does not carry EXACTLY 1 \`#endif /* STAGE90_XNU_CALLER_PROBE */\` marker - Site A's ON/OFF gate is not bracketed, so the OFF arm is not the 1030 tree's bytes"; exit 1; }
_pi_src=$PWD/external/xnu-hd2-darwin13/xnu/bsd/sys/proc_internal.h
# Site B's accessor: the DEFINITION (`xnu_live_cal_proc_region_top(void *bsd_info)`), i.e. the line with a
# `(`, so a bare mention in Site A's `extern` (which lives in trap.c, not here) cannot satisfy it.
[[ $(grep -c 'xnu_live_cal_proc_region_top(void \*bsd_info)' "$_ke_src") == 1 ]] || {
  echo "REFUSING: the staged $_ke_src does not carry EXACTLY 1 xnu_live_cal_proc_region_top(void *bsd_info) DEFINITION - Site B's accessor is not staged, so Site A's `extern` would be unresolved at the link (or two definitions would collide)"; exit 1; }
# THREE `p_live_stack_top` writes in kern_exec.c: the FIXED-success stash (a local `_cal_top`) AND the
# ANYWHERE-fallback stash, PLUS the `_cal_top` read.  The `p->p_live_stack_top` assignment is a single
# cite; assert the field is WRITTEN on both allocator paths (the FIXED one and the fallback one).
[[ $(grep -c 'p->p_live_stack_top *=' "$_ke_src") == 2 ]] || {
  echo "REFUSING: the staged $_ke_src does not carry EXACTLY 2 \`p->p_live_stack_top =\` stashes - Site B's FIXED-success and ANYWHERE-fallback stashes are NOT both staged, so on one allocator path the region top is never recorded and Site A would read a STALE top BY VALUE (the loudest possible wrong reading)"; exit 1; }
[[ -f $_pi_src ]] || { echo "REFUSING: $_pi_src is absent - the proc struct this rung adds a field to is not on disk"; exit 1; }
[[ $(grep -c 'uint32_t p_live_stack_top;' "$_pi_src") == 1 ]] || {
  echo "REFUSING: the staged $_pi_src does not carry EXACTLY 1 \`uint32_t p_live_stack_top;\` field - the stash's destination does not exist, so the pool would not compile (or a duplicate field was added). 1031 edits THREE files ([[mi4-one-file-many-rungs]]): trap.c, kern_exec.c AND this header"; exit 1; }
[[ $(grep -c '^#endif /\* STAGE90_XNU_CALLER_PROBE \*/$' "$_ke_src") == 3 ]] || {
  echo "REFUSING: the staged $_ke_src carries $(grep -c '^#endif /\* STAGE90_XNU_CALLER_PROBE \*/$' "$_ke_src") plain \`#endif /* STAGE90_XNU_CALLER_PROBE */\` markers, expected EXACTLY 3 (the accessor block + the FIXED stash + the fallback stash). Site B is THREE bracketed sub-blocks; a 4th plain marker would be an unstaged stray edit, fewer means a gate is not bracketed. (The nested H2 extent inside the FIXED stash is deliberately retagged \`: H2 extent\` and is NOT counted here.)"; exit 1; }
[[ $(grep -c '^#if defined(STAGE90_XNU_CALLER_PROBE) && STAGE90_XNU_CALLER_PROBE$' "$_ke_src") == 3 ]] || {
  echo "REFUSING: the staged $_ke_src carries $(grep -c '^#if defined(STAGE90_XNU_CALLER_PROBE) && STAGE90_XNU_CALLER_PROBE$' "$_ke_src") \`#if defined(STAGE90_XNU_CALLER_PROBE)\` openers, expected EXACTLY 3 - every plain \`#endif\` must have its own bracketing opener, or the OFF arm is not the 1030 tree's bytes"; exit 1; }
[[ $(grep -c '^#endif /\* STAGE90_XNU_CALLER_PROBE: H2 extent \*/$' "$_ke_src") == 1 ]] || {
  echo "REFUSING: the staged $_ke_src does not carry EXACTLY 1 retagged \`#endif /* STAGE90_XNU_CALLER_PROBE: H2 extent */\` marker - the nested H2 gate inside the FIXED stash is the ONLY thing that keeps kern_exec.c from carrying a SECOND literal \`#endif /* STAGE90_XNU_H2_STACK_HEADROOM */\` (the build's step assertion requires exactly 1 of that marker, and the inner gate here is H2's extent, so its closer is retagged - docs/1031-design.md s.4)"; exit 1; }
# NESTING: Site A's gate must sit INSIDE 1025's publisher and OUTSIDE 1026/1027's, 1029's AND 1030's
# blocks.  Read the line numbers BY VALUE (a text count cannot see a displaced block).
_tr_105=$(grep -n '^#endif /\* STAGE90_XNU_USTACK_PROBE \*/' "$_tr_src" | head -1 | cut -d: -f1)
_tr_106=$(grep -n '^#endif /\* STAGE90_XNU_ABT_ENTRY_PROBE \*/' "$_tr_src" | head -1 | cut -d: -f1)
_tr_109=$(grep -n '^#endif /\* STAGE90_XNU_READER_PROBE \*/' "$_tr_src" | head -1 | cut -d: -f1)
_tr_110=$(grep -n '^#endif /\* STAGE90_XNU_WRITER_PROBE \*/' "$_tr_src" | head -1 | cut -d: -f1)
_tr_111=$(grep -n '^#endif /\* STAGE90_XNU_CALLER_PROBE \*/' "$_tr_src" | head -1 | cut -d: -f1)
[[ -n $_tr_111 && $_tr_106 -lt $_tr_111 && $_tr_111 -lt $_tr_105 ]] || {
  echo "REFUSING: 1031's gate is NOT between its two parents (trap.c lines: 1026 #endif=$_tr_106, 1031 #endif=$_tr_111, 1025 #endif=$_tr_105). Site A's rows must sit INSIDE the shared fault-path gate (or they never execute) AND OUTSIDE 1026/1027's block (or they are gated on the wrong switch)"; exit 1; }
[[ -n $_tr_110 && $_tr_109 -lt $_tr_110 && $_tr_110 -lt $_tr_111 ]] || {
  echo "REFUSING: 1031's block is NOT appended after 1030's and 1029's (trap.c lines: 1029 #endif=$_tr_109, 1030 #endif=$_tr_110, 1031 #endif=$_tr_111). 1031 builds ON 1030/1029, not over or before them ([[mi4-one-file-many-rungs]])"; exit 1; }
echo "   BY VALUE(1-a7): the staged trap.c carries xnu_live_cal_r3= (x1) + xnu_live_cal_region_end= (x1) + one bracketing #endif, sitting INSIDE 1025's gate (1031 #endif=$_tr_111 < 1025 #endif=$_tr_105) and AFTER 1026/1029/1030 (1026=$_tr_106 < 1029=$_tr_109 < 1030=$_tr_110 < 1031=$_tr_111); kern_exec.c carries the xnu_live_cal_proc_region_top DEFINITION + 2 p->p_live_stack_top stashes + 3 plain bracketing #if/#endif pairs (+ the retagged nested H2-extent closer), and proc_internal.h carries the p_live_stack_top field"

# (b) THE BY-VALUE CLAUSE - THE PARK'S OWN CLAIM, ON THE TWO POOL OBJECTS.  The fingerprints are a FORMAT
#     STRING (`xnu_live_cal_r3=` / `xnu_live_cal_region_end=`, read by `strings`) and a SYMBOL
#     (`xnu_live_cal_proc_region_top`).  Read the OBJECTS (the edit's home), `grep -qa P <(strings X)` NOT
#     `strings X | grep -q P` (pipefail/SIGPIPE = 141 - m1025).
#
#     **THE CHECKER IS REQUIRED, AND ITS ABSENCE IS A REFUSAL, NOT A SKIP.**  A park that skipped this
#     would freeze an arm whose own claim nothing checks ([[mi4-a-claim-in-a-comment-is-not-a-check]]).
[[ -f tools/check_1031_capture.py ]] || {
  echo "REFUSING: tools/check_1031_capture.py is ABSENT. It is this park's capture reader (the CAL-CALLER-TOP / CAL-CALLER-SIZE / CAL-CALLER-OTHER / CAL-MISSING / REGRESSION / G-CTL cells the press is adjudicated by), and there is no sound fallback. An absent checker means the by-value half of this rung cannot be certified"; exit 1; }

# 1031-0. THE CHECKER'S OWN SELF-TEST.  A checker that cannot fail is not a check
#         ([[mi4-a-claim-in-a-comment-is-not-a-check]]).  Refuse the park unless it PASSes its selftest.
python3 -I tools/check_1031_capture.py --selftest >/dev/null 2>&1 || {
  echo "REFUSING: tools/check_1031_capture.py --selftest did NOT PASS - the checker cannot certify anything (an inert checker would bless any capture). Fix the checker before parking the arm it is supposed to prove"; exit 1; }
echo "   BY VALUE(0): tools/check_1031_capture.py --selftest PASSes (the checker is live; the emitted-row parity is asserted against the patcher)"

# 1031-1. **THIS RUNG'S OWN FINGERPRINTS, ON THE TWO POOL OBJECTS.**  This rung PRINTS, so it has REAL
#         `strings` evidence.  Read the OBJECTS (the edit's home).
[[ -d out/xnu_kernel_obj_d13 ]] || { echo "REFUSING: out/xnu_kernel_obj_d13 is absent - the pool the linked image was built from is not on disk"; exit 1; }
_trap_obj=out/xnu_kernel_obj_d13/osfmk_arm_trap.o
_exec_obj=out/xnu_kernel_obj_d13/bsd_kern_kern_exec.o
[[ -f $_trap_obj ]] || { echo "REFUSING: $_trap_obj is absent - trap.c is where Site A's xnu_live_cal_* rows live; a park that cannot read it cannot certify the probe"; exit 1; }
[[ -f $_exec_obj ]] || { echo "REFUSING: $_exec_obj is absent - kern_exec.c is where Site B's accessor lives; a park that cannot read it cannot certify that Site A's `extern` would resolve"; exit 1; }
grep -qa '^xnu_live_cal_r3=' <(strings "$_trap_obj") || {
  echo "REFUSING: $_trap_obj carries NO xnu_live_cal_r3= publisher - the pool was NOT recompiled with STAGE90_XNU_CALLER_PROBE=1 (the env -> global DEFINES channel of build_xnu_arm_kernel.sh) or Site A's trap.c edit is not staged. Without this row the press captures NOTHING on the launchctl fault and 1031 reads CAL-MISSING for a reason that is not the device's. Re-run scripts/build_1031.sh"; exit 1; }
grep -qa 'xnu_live_cal_proc_region_top' <(strings "$_exec_obj") || {
  echo "REFUSING: $_exec_obj carries NO xnu_live_cal_proc_region_top symbol - Site B's accessor is not in the pool object, so the linked image would carry Site A's unresolved `extern` (or a stale object). The region-top value could not be read independently. Re-run scripts/build_1031.sh"; exit 1; }
# SITE A PUBLISHES THE WHOLE KEY SET, not just the first row: a partial block would print `r3` and stop
# exactly where the cell's other conjuncts are read.
for _k in '^xnu_live_cal_r0=' '^xnu_live_cal_r1=' '^xnu_live_cal_r2=' '^xnu_live_cal_r9=' '^xnu_live_cal_r10=' '^xnu_live_cal_r12=' '^xnu_live_cal_r7=' '^xnu_live_cal_r7_minus_sp=' '^xnu_live_cal_lr=' '^xnu_live_cal_pc=' '^xnu_live_cal_far=' '^xnu_live_cal_ustack=' '^xnu_live_cal_far_minus_ustack=' '^xnu_live_cal_region_end_hit=' '^xnu_live_cal_region_end=' '^xnu_live_cal_r3_minus_region_end='; do
  grep -qa "$_k" <(strings "$_trap_obj") || {
    echo "REFUSING: $_trap_obj carries NO $_k row - Site A's block is PARTIAL (a truncated edit). Every row is required: the CAL-CALLER-TOP cell reads region_end_hit / region_end / r2 / r3 / r7_minus_sp TOGETHER, and docs/1031-design.md s.2 forbids gating any of them". exit 1; }
done
echo "   BY VALUE(1): $_trap_obj carries 1031's xnu_live_cal_r3= + the whole row set, $_exec_obj carries the xnu_live_cal_proc_region_top accessor (Site A and Site B both reached the pool objects)"

# 1031-1b. THE INHERITED PARENT CELLS, ON THE SAME OBJECTS.  1031 rebuilds the WHOLE pool (its own trap.c
#          AND kern_exec.c edits), so the 1025/1026/1027/1029/1030 publishers its cells are read BESIDE
#          must SURVIVE.
grep -qa '^xnu_live_abt_lookup_far=' <(strings "$_trap_obj") || {
  echo "REFUSING: $_trap_obj carries NO xnu_live_abt_lookup_far= publisher - the pool was NOT recompiled with STAGE90_XNU_ABT_ENTRY_PROBE=1 or the trap.c edit is not staged. 1031 carries 1027 as its parent cells. Re-run scripts/build_1031.sh"; exit 1; }
grep -qa '^xnu_live_rdr_far=' <(strings "$_trap_obj") || {
  echo "REFUSING: $_trap_obj lost 1029's xnu_live_rdr_far= publisher in this pool rebuild - 1031's premise chains through 1030's to 1029's reader reading. Re-run scripts/build_1031.sh"; exit 1; }
grep -qa '^xnu_live_wrp_r4=' <(strings "$_trap_obj") || {
  echo "REFUSING: $_trap_obj lost 1030's xnu_live_wrp_r4= publisher in this pool rebuild - 1031's premise (r4 == far == the region's exclusive top) is READ FROM the wrp rows. Re-run scripts/build_1031.sh"; exit 1; }
grep -qa '^xnu_live_abt_proc_ustack$' <(strings "$_exec_obj") || {
  echo "REFUSING: $_exec_obj carries NO xnu_live_abt_proc_ustack symbol - the pool was NOT recompiled with STAGE90_XNU_ABT_ENTRY_PROBE=1 or the kern_exec.c accessor is not staged. Re-run scripts/build_1031.sh"; exit 1; }
# 1025'S PUBLISHERS MUST SURVIVE THE SAME POOL REBUILD (the [[mi4-one-file-many-rungs]] check, BY VALUE):
# 1031's Site A rows are NESTED inside 1025's publisher, so a build that dropped 1025's switch would
# leave the caller block compiled-out while the pointer still pointed at dead text.
grep -qa '^xnu_live_abt_vmfkrv=' <(strings "$_trap_obj") || {
  echo "REFUSING: $_trap_obj lost 1025's xnu_live_abt_vmfkrv= publisher in this pool rebuild - 1031's Site A rows are NESTED inside 1025's publisher, so they would never run ([[mi4-one-file-many-rungs]]). Re-run scripts/build_1031.sh"; exit 1; }
grep -qa '^xnu_live_ustack_req=' <(strings "$_exec_obj") || {
  echo "REFUSING: $_exec_obj lost 1025's xnu_live_ustack_req= publisher in this pool rebuild - 1031 builds ON 1025/1026/1027/1028/1029/1030, not over them. Re-run scripts/build_1031.sh"; exit 1; }
echo "   BY VALUE(1b): the inherited parents survive the rebuild (trap.o has xnu_live_abt_lookup_far= + xnu_live_rdr_far= + xnu_live_wrp_r4= + xnu_live_abt_vmfkrv=, kern_exec.o has xnu_live_abt_proc_ustack + xnu_live_ustack_req=)"

# 1031-2. THE LINKED-IMAGE CO-READING.  build_entry.sh LINKS the pool objects, so the read this rung's
#         cells are taken from must ALSO be reachable from the linked ELF the press boots (an object the
#         linker DROPPED would leave the press's capture with no cal row).
grep -qa '^xnu_live_cal_r3=' <(strings "$LIVE/xnu_arm_entry.elf") || {
  echo "REFUSING: the LINKED $LIVE/xnu_arm_entry.elf carries NO xnu_live_cal_r3= string - the pool object carrying the cal rows was not linked into the image the press boots, so the capture would have no cal row and 1031 could not answer its own question. Re-run scripts/build_1031.sh"; exit 1; }
grep -qa '^xnu_live_cal_region_end=' <(strings "$LIVE/xnu_arm_entry.elf") || {
  echo "REFUSING: the LINKED $LIVE/xnu_arm_entry.elf carries NO xnu_live_cal_region_end= string - the row the WHOLE rung turns on did not reach the image the press boots. Re-run scripts/build_1031.sh"; exit 1; }
grep -qa '^xnu_live_wrp_r4=' <(strings "$LIVE/xnu_arm_entry.elf") || {
  echo "REFUSING: the LINKED $LIVE/xnu_arm_entry.elf lost 1030's xnu_live_wrp_r4= row - 1031's premise cannot be corroborated from the booted image. Re-run scripts/build_1031.sh"; exit 1; }
grep -qa '^xnu_live_abt_lookup_far=' <(strings "$LIVE/xnu_arm_entry.elf") || {
  echo "REFUSING: the LINKED $LIVE/xnu_arm_entry.elf carries NO xnu_live_abt_lookup_far= string - the pool object that has it was not linked, so the parent read would be blind. Re-run scripts/build_1031.sh"; exit 1; }
echo "   BY VALUE(2): the LINKED image carries 1031's xnu_live_cal_r3= / xnu_live_cal_region_end=, 1030's xnu_live_wrp_r4= AND the xnu_live_abt_lookup_far= discriminator (the linker dropped none of them)"

# ---- THE INHERITED CEILING CLAUSE (1024's task-map ceiling on the LINKED image).
[[ -f tools/check_vm_max_split.py ]] || { echo "REFUSING: tools/check_vm_max_split.py is ABSENT - it is the inherited 1024 claim's by-value check on the linked image's task-map ceiling"; exit 1; }
python3 -I tools/check_vm_max_split.py --selftest >/dev/null 2>&1 || { echo "REFUSING: tools/check_vm_max_split.py --selftest did NOT PASS - the inherited ceiling checker cannot certify anything"; exit 1; }
python3 -I tools/check_vm_max_split.py "$LIVE/xnu_arm_entry.elf" --expect on >/dev/null 2>&1 || {
  echo "REFUSING: the LINKED image's task_create_internal does NOT pass 0x40000000 to vm_map_create - either 1024's widened vm_param.h:63 line did not reach the pool, or a STALE pool object was linked (build_entry.sh only LINKS it). Re-run scripts/build_1031.sh"; exit 1; }
echo "   POOL(CEILING): by value - the LINKED image's task_create_internal passes 0x40000000 to vm_map_create (1024's ceiling is intact)"

# ---- THE INHERITED NEON-FREE CLAUSE: -msoft-float must still hold (this rung re-OBJECTs the WHOLE pool).
[[ -f tools/check_d13_no_neon.py ]] || { echo "REFUSING: tools/check_d13_no_neon.py is ABSENT - it is the inherited 1021d claim's by-value check (the -msoft-float flag reached the pool)"; exit 1; }
python3 -I tools/check_d13_no_neon.py --selftest >/dev/null 2>&1 || { echo "REFUSING: tools/check_d13_no_neon.py --selftest did NOT PASS - the inherited NEON-free checker cannot certify anything"; exit 1; }
_pool=out/xnu_kernel_obj_d13
_src_rec=out/xnu_kernel_src_d13.sha256
[[ -s $_src_rec ]] || { echo "REFUSING: $_src_rec is absent - the pool's own source-content record is the independent count this clause compares against"; exit 1; }
_want_objs=$(grep -c '^[0-9a-f]\{64\} ' "$_src_rec" || true)
_got_objs=$(ls "$_pool"/*.o 2>/dev/null | wc -l)
[[ $_want_objs -gt 0 && $_got_objs -eq $_want_objs ]] || {
  echo "REFUSING: $_pool holds $_got_objs object(s) but $_src_rec names $_want_objs source(s) - the census would count the WRONG set (a partial or stale directory passes any NEON-free test vacuously). Re-run scripts/build_1031.sh"; exit 1; }
python3 -I tools/check_d13_no_neon.py --pool "$_pool" --expect none --min-objects "$_want_objs" >/dev/null 2>&1 || {
  echo "REFUSING: tools/check_d13_no_neon.py --pool $_pool --expect none did NOT pass - the pool the linked image was built from still contains FP/NEON instructions. 1031 recompiles the WHOLE pool, so the -msoft-float flag must still reach every object or the kernel-mode NEON undef at 0x8047b0ac returns. Re-run scripts/build_1031.sh"; exit 1; }
python3 -I tools/check_d13_no_neon.py "$LIVE/xnu_arm_entry.elf" --symbol mach_msg_send --expect none >/dev/null 2>&1 || {
  echo "REFUSING: the LINKED image's mach_msg_send still contains FP/NEON instructions - 1021d's -msoft-float flag did not reach the object the linker saw, or a STALE pool object was linked. Re-run scripts/build_1031.sh"; exit 1; }
echo "   POOL(NEON-FREE): by value - $_got_objs objects NEON-free (== $_want_objs source(s)), and the LINKED mach_msg_send is NEON-free (1021d's -msoft-float holds)"

# ====================================================================================================
# THE INHERITED REGRESSION CLAUSES, kept IN MEANING (placed AFTER 1031's own change, so a park that lost
# this rung's probe has already stopped above).
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
  echo "REFUSING: the LINKED image's mach_trap_table[24] is NOT the ios7lab_mach_port_construct_trap row any more (or rows 25/41/42 moved) - 1031 adds only the caller probe and must MOVE nothing else. Re-run scripts/build_1031.sh"; exit 1; }
echo "   BY VALUE(3): tools/check_1023_trap24.py --expect on PASSes (1023's row 24 is intact, rows 25/41/42 still kern_invalid)"
# 1020's by-value clause, re-run on the LINKED image.
[[ -f tools/check_d13_undef_raise.py ]] || { echo "REFUSING: tools/check_d13_undef_raise.py is ABSENT - it is the inherited 1020 claim's by-value check on the linked image"; exit 1; }
python3 -I tools/check_d13_undef_raise.py "$LIVE/xnu_arm_entry.elf" --expect on >/dev/null 2>&1 || {
  echo "REFUSING: tools/check_d13_undef_raise.py --expect on did NOT pass on the linked image - 1020's moved \`return\` is NOT in this image's sleh_undef, so the udf loop is back. Re-run scripts/build_1031.sh"; exit 1; }
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
grep -qa '^xnu_live_cal_r3=' <(strings "$PARK/xnu_arm_entry.elf") || {
  echo "REFUSING: the FROZEN $PARK/xnu_arm_entry.elf lost 1031's xnu_live_cal_r3= row - the copy is not the certified bytes, and a press of this arm would capture nothing on the launchctl fault. This park's directory is incomplete; remove $PARK and re-run"; exit 1; }
grep -qa '^xnu_live_cal_region_end=' <(strings "$PARK/xnu_arm_entry.elf") || {
  echo "REFUSING: the FROZEN $PARK/xnu_arm_entry.elf lost 1031's xnu_live_cal_region_end= row - the row the WHOLE rung turns on is not in the copy. This park's directory is incomplete; remove $PARK and re-run"; exit 1; }
grep -qa '^xnu_live_wrp_r4=' <(strings "$PARK/xnu_arm_entry.elf") || {
  echo "REFUSING: the FROZEN $PARK/xnu_arm_entry.elf lost 1030's xnu_live_wrp_r4= row - the copy is not the certified bytes. This park's directory is incomplete; remove $PARK and re-run"; exit 1; }
grep -qa '^xnu_live_abt_lookup_far=' <(strings "$PARK/xnu_arm_entry.elf") || {
  echo "REFUSING: the FROZEN $PARK/xnu_arm_entry.elf lost the xnu_live_abt_lookup_far= publisher - the copy is not the certified bytes. This park's directory is incomplete; remove $PARK and re-run"; exit 1; }
grep -qa '^xnu_live_abt_vmfkrv=' <(strings "$PARK/xnu_arm_entry.elf") || {
  echo "REFUSING: the FROZEN $PARK/xnu_arm_entry.elf lost 1025's xnu_live_abt_vmfkrv= publisher - the copy is not the certified bytes. This park's directory is incomplete; remove $PARK and re-run"; exit 1; }
python3 -I tools/check_vm_max_split.py "$PARK/xnu_arm_entry.elf" --expect on >/dev/null 2>&1 || {
  echo "REFUSING: the FROZEN $PARK/xnu_arm_entry.elf does not carry 1024's ceiling claim the live one did - the copy is not the certified bytes. This park's directory is incomplete; remove $PARK and re-run"; exit 1; }
python3 -I tools/check_1023_trap24.py "$PARK/xnu_arm_entry.elf" --expect on >/dev/null 2>&1 || {
  echo "REFUSING: the FROZEN $PARK/xnu_arm_entry.elf lost 1023's row-24 claim - the copy is not the certified bytes. This park's directory is incomplete; remove $PARK and re-run"; exit 1; }
# 1031's own edit is in SOURCE the arm's record binds by content (the pool compiled it), so re-read the
# STAGED source: both sites must still be present, on the parked arm's identity.
grep -q 'STAGE90_XNU_CALLER_PROBE' "$_tr_src" || {
  echo "REFUSING: the staged $_tr_src no longer carries STAGE90_XNU_CALLER_PROBE - the source the certified pool was built from has changed under the parked arm; the park's own claim is not re-readable. remove $PARK, re-stage the probe, and re-run"; exit 1; }
grep -q 'STAGE90_XNU_CALLER_PROBE' "$_ke_src" || {
  echo "REFUSING: the staged $_ke_src no longer carries STAGE90_XNU_CALLER_PROBE - Site B's accessor/stashes are gone from the source the certified pool was built from. remove $PARK, re-stage the probe, and re-run"; exit 1; }
grep -q 'STAGE90_XNU_H2_STACK_HEADROOM' "$_ke_src" || {
  echo "REFUSING: the staged $_ke_src no longer carries STAGE90_XNU_H2_STACK_HEADROOM - the PARENT 1028 fix the parked arm carries has been reverted under it. remove $PARK, re-stage, and re-run"; exit 1; }
grep -q 'STAGE90_XNU_WRITER_PROBE' "$_tr_src" || {
  echo "REFUSING: the staged $_tr_src no longer carries STAGE90_XNU_WRITER_PROBE - the PARENT 1030 probe the parked arm carries has been reverted under it. remove $PARK, re-stage, and re-run"; exit 1; }
grep -q 'STAGE90_XNU_CALLER_PROBE' "$_pi_src" || {
  echo "REFUSING: the staged $_pi_src no longer carries STAGE90_XNU_CALLER_PROBE - the p_live_stack_top field's gate is gone from the source the certified pool was built from, so the stash's destination is unbracketed. remove $PARK, re-stage, and re-run"; exit 1; }
echo "   BY VALUE(6): the FROZEN $PARK/xnu_arm_entry.elf carries 1031's xnu_live_cal_r3= / xnu_live_cal_region_end= rows, 1030's xnu_live_wrp_r4=, the 1027 discriminator (lookup_far) and 1025's publisher, 1024's ceiling (0x40000000) AND 1023's row 24; the staged trap.c, kern_exec.c AND proc_internal.h still carry STAGE90_XNU_CALLER_PROBE, trap.c still carries STAGE90_XNU_WRITER_PROBE, and kern_exec.c still carries STAGE90_XNU_H2_STACK_HEADROOM (the parked bytes are the certified bytes)"

{
  printf '# %s  -  1031: THE CALLER PROBE - NAME HOW THE CALLER DERIVED THE WRITE ADDRESS.\n' "$ARM"
  printf '# 1030-s press RAN and its own console was recovered (records/1030-press-read.txt). The reading is\n'
  printf '# W-B-NAMED, BY VALUE - the faulting store target IS the region-#s EXCLUSIVE TOP:\n'
  printf '#   xnu_live_wrp_r4                == xnu_live_wrp_far        (r4 - far == 0)\n'
  printf '#   xnu_live_wrp_r6                == xnu_live_wrp_r4         (the caller passed r2 == r3)\n'
  printf '#   xnu_live_wrp_userstack         = 0x2bdad000\n'
  printf '#   xnu_live_wrp_r4_minus_ustack   = 0x00001000              (one PAGE above the block top)\n'
  printf '# The writer is /usr/lib/libobjc.dylib + 0x14756, `str.w r2,[r4],#4`, prologue\n'
  printf '# `push {r4,r5,r6,r7,lr}; add r7,sp,#12`, `mov r4,r3` -> **r4 IS THE CALLER-s 4TH ARGUMENT**.\n'
  printf '# WHO derived it is UNRESOLVED.  docs/1031-design.md sec.0-1. REPORT IT; DO NOT RE-FIX IT.\n'
  printf '# **THE PRIOR DISASSEMBLY CLAIM IS REFUTED BY THE RAW FRAME.**  A disassembly of the caller\n'
  printf '# claimed it derives r3 as `sub.w rN, sp, r#N, lsl #2` (a DOWNWARD alloca off sp).  The 1030\n'
  printf '# capture shows sp = 0x2bdac074 and r4 = sp + 0x1F8C, so r4 lies ABOVE sp - a sub-off-sp cannot\n'
  printf '# produce it.  The caller-s derivation is UNRESOLVED, and 1031 MEASURES it (no fix, no\n'
  printf '# allocation change).  docs/1031-design.md sec.5.\n'
  printf '# Switch set is 1030-s VERBATIM with **ONE NEW SWITCH: STAGE90_XNU_CALLER_PROBE=1**.\n'
  printf '# THE ARM (TWO SITES, one switch), staged by tools/patch_d13_caller_probe.py:\n'
  printf '#   Site A  osfmk/arm/trap.c  - rows INSIDE 1025-s publisher, AFTER 1026/1027/1029/1030-s blocks\n'
  printf '#                              but WITHIN 1025-s block, so the caller rows ride the SAME fault the\n'
  printf '#                              discriminator fires on. Rows: r0, r1, r2, r3, r9, r10, r12, r7,\n'
  printf '#                              r7_minus_sp, lr, pc, far, ustack, far_minus_ustack, region_end_hit,\n'
  printf '#                              region_end, r3_minus_region_end -> xnu_live_cal_* (RAM console).\n'
  printf '#   Site B  bsd/kern/kern_exec.c - the accessor `xnu_live_cal_proc_region_top` (the region top BY\n'
  printf '#                              VALUE from the allocator-s own stash) beside 1026-s, PLUS two\n'
  printf '#                              p_live_stack_top stashes at create_unix_stack (FIXED + ANYWHERE).\n'
  printf '# *** THE REGION-TOP LOOKUP IS THE POINT OF Site A. ***  `vm_map_lookup_entry(map, trunc_page(far)\n'
  printf '# - 4, &e); e->vme_end` IS the region-s exclusive top when far is the top (region_end_hit == 1),\n'
  printf '# so r3 == region_end NAMES the derivation as "the region-s END" rather than a base+size.\n'
  printf '# THE CHANNEL IS THE GLOBAL DEFINES ARRAY of tools/build_xnu_arm_kernel.sh (env), NOT EXTRA\n'
  printf '# (build_1031.sh arrests a -DSTAGE90_XNU_CALLER_PROBE in EXTRA), so an EXTRA-only build cannot\n'
  printf '# ship a stale pool behind a green build.\n'
  printf '# THE POOL MOVES TWICE OVER: trap.c AND kern_exec.c are BOTH pool files, so the pool (and the\n'
  printf '# entry .bin whose sha8 IS the arm) MOVES (8034562e -> %s). build_entry.sh only LINKS the pool\n' "${ARM#armed-d13-}"
  printf '# objects, so a green entry build says nothing about this half.\n'
  printf '# [[mi4-one-file-many-rungs]]: FIVE rungs edit bsd/kern/kern_exec.c (1025 / 1026 / 1028 / 1029 /\n'
  printf '# 1031) and SEVEN edit osfmk/arm/trap.c (994 / 1020 / 1025 / 1026 / 1029 / 1030 / 1031); a\n'
  printf '# cleanup `git checkout --` reverts the others SILENTLY and the failure surfaces LATE.\n#\n'
  printf '# THE BY-VALUE PROOF OF 1031-S CHANGE (Site A rows ARE prints, so this rung has real strings\n'
  printf '# evidence):\n'
  printf '#   (0)  tools/check_1031_capture.py --selftest PASSes (the checker can fail; the emitted-row\n'
  printf '#        parity is asserted against the patcher);\n'
  printf '#   (1)  the POOL OBJECTS carry it: osfmk_arm_trap.o has `xnu_live_cal_r3=` AND the WHOLE row set,\n'
  printf '#        bsd_kern_kern_exec.o has `xnu_live_cal_proc_region_top` (Site A + Site B both reached the\n'
  printf '#        objects); the INHERITED 1025/1026/1027/1029/1030 rows SURVIVE the same rebuild;\n'
  printf '#   (2)  the LINKED out/stage90/xnu_arm_entry.elf carries 1031-s rows, 1030-s wrp row AND the\n'
  printf '#        inherited rows (the linker did not drop any of them);\n'
  printf '#   (6)  the FROZEN bytes still carry them AND the staged sources still carry the switch (the\n'
  printf '#        parked bytes are the certified bytes).\n#\n'
  printf '# THE CARRIERS ([[mi4-one-value-two-definitions]]). The record carries\n'
  printf '# STAGE90_XNU_CALLER_PROBE=1 (the switch the probe is gated by AND the readability carrier) AND\n'
  printf '# 1030-s STAGE90_XNU_WRITER_PROBE=1 AND 1029-s STAGE90_XNU_READER_PROBE=1 AND 1028-s\n'
  printf '# STAGE90_XNU_H2_STACK_HEADROOM=1 AND 1027-s STAGE90_XNU_ABT_ENTRY_PROBE=1 AND 1025-s\n'
  printf '# STAGE90_XNU_USTACK_PROBE=1 (the PARENT gate). The declaration carrier\n'
  printf '# out/stage90/xnu_arm_entry-arm-extra.txt is written by THIS build-s tail as\n'
  printf '# STAGE90_XNU_GLOBAL_FIX=1 role=1031-caller-probe; the grep of it is the process check and the\n'
  printf '# pmap_flush_tlbs fingerprint is the proof.\n'
  printf '# THE INHERITED REGRESSIONS held (asserted by the park): STAGE90_XNU_GENERAL_REGS=1 (1021d-s\n'
  printf '# -msoft-float), STAGE90_XNU_UNDEF_RAISE=1, STAGE90_XNU_UNDEF_DIRECT=1, STAGE90_XNU_IOS7_TRAPS=1\n'
  printf '# and STAGE90_XNU_VM_MAX_SPLIT=1 in the record, 1024-s ceiling on the linked image, the\n'
  printf '# pmap_flush_tlbs kernel_pmap==3 fingerprint, the whole-pool NEON-free census + the linked\n'
  printf '# mach_msg_send NEON-free read, check_1023_trap24.py --expect on, check_d13_undef_raise.py\n'
  printf '# --expect on, and by value __wrap_sleh_undef branching to entry_write_kv (>=6) and NOT\n'
  printf '# entry_live_write (0).\n#\n'
  printf '# THE 1031 VERDICT CELLS (docs/1031-design.md sec.2; read via tools/check_1031_capture.py):\n'
  printf '#   CAL-CALLER-TOP  - region_end_hit == 1 AND region_end == far AND r3 == r2 == far AND\n'
  printf '#                    r7 - sp == 0xC => the caller derived the WRITE ADDRESS as the stack region-s\n'
  printf '#                    EXCLUSIVE TOP (the address IS the region-s END). The NEXT rung names WHAT\n'
  printf '#                    produced that value; 1031 self-selects NO fix.\n'
  printf '#   CAL-CALLER-SIZE - r3 == r2, r3 != region_end, 0 < (region_end - r3) <= 0x1000 => the caller\n'
  printf '#                    produced the address as a BASE+SIZE expression one page short of the region\n'
  printf '#                    end. NAME it; do NOT pick a fix.\n'
  printf '#   CAL-CALLER-OTHER - a complete frame naming NEITHER shape, or the loud frame shape is wrong\n'
  printf '#                    (r7 - sp != 0xC, an early return before the call). FAIL CLOSED: report it,\n'
  printf '#                    disassemble the caller (xnu_live_cal_pc / lr), do NOT choose a fix.\n'
  printf '#   CAL-MISSING     - the cal group did not print (probe did not run / incomplete) => WITHHOLD.\n'
  printf '#                    NEVER A NEGATIVE: an absent xnu_live_cal_* row means the PROBE DID NOT RUN.\n'
  printf '#   REGRESSION      - trap24 / port_construct(result=0) vanish, or a panic appears, or the 1023\n'
  printf '#                    storm is back => the probe changed the pool-s behaviour, not just its console.\n'
  printf '#   G-CTL / WITHHOLD - launchd never reached and no prior control live => no reading (fail closed).\n'
  printf '# Medium: 968 real iOS 7.1.2 HFSX rootfs over hfs_rmd0; CARD_COW=1, HDD_WRITE=0, base never\n'
  printf '# written - fully reversible. fastboot boot only, NEVER flash.\n'
  printf '# =================================================================================================\n'
  for m in "${MEMBERS[@]}"; do
    h=$(sha256sum "$PARK/$m" | awk '{print $1}')
    b=$(stat -c %s "$PARK/$m")
    printf 'set=%s sha256=%s bytes=%s file=%s role=1031-caller-probe;%s\n' \
      "$ARM" "$h" "$b" "$m" "$m"
  done
} >> "$REC"

echo "parked $ARM ($(ls -1 "$PARK" | wc -l) members)"
tools/verify_revert_set.sh "$PARK" --set="$ARM" 2>&1 | tail -3