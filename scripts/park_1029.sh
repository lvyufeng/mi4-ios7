#!/usr/bin/env bash
# ====================================================================================================
# park_1029.sh.  MODELLED BYTE-STRUCTURALLY ON scripts/park_1028.sh (itself the 1027/1024/1021d/1015b
# pattern), WITH 1015b's POOL-MOVED DISCIPLINE: this rung's edits are POOL FILES
# (`osfmk/arm/trap.c` AND `bsd/kern/kern_exec.c`), so the pool moves and the entry .bin whose sha8 IS the
# arm moves with it.
#
# Park 1029 (THE READER PROBE: publish the derivation chain that puts the store at `user_stack + 0x1000`)
# and append its block to records/revert-set.txt.
#
# 1029 = 1028's switch set VERBATIM with **ONE NEW SWITCH: STAGE90_XNU_READER_PROBE=1**.  Design:
# docs/1029-design.md.
#
# WHY.  1028's press RAN and its own console was recovered (records/1028-press-read.txt).  The reading is
# **FIX-NOOP - page-exact**, BY VALUE:
#     xnu_live_ustack_rc=0   p->user_stack=0x2bd0d000   far=0x2bd0e000
#     far - ustack = 0x1000      (the fault MOVED UP by exactly the page the region grew)
#     sp = 0x2bd0c074    ustack - sp = 0x0F8C    far - sp = 0x1F8C
# On 1024/1025/1026/1027 the same two offsets read `far == p->user_stack` and `far - sp == 0xF8C`.  The
# H2 fix TOOK EFFECT and the fault FOLLOWED it one page higher, so the failing store is NOT the block's
# top word: it is a userspace store whose ADDRESS IS A FUNCTION OF `p->user_stack`.  H2, as a fix target,
# is REFUTED, and 1029 **reports, does not re-fix** (another page would move the fault again).
#
# **THE ARM (TWO POOL EDITS, one switch).**  Staged by tools/patch_d13_reader_probe.py (anchor +
# done-mark per file; refuses a hand edit) with a two-arm proof (`--verify-off` proves the OFF arm is the
# 1028 tree's bytes):
#   osfmk/arm/trap.c      Site A: the `xnu_live_rdr_*` rows on the usermode DATA-abort FAILURE arm,
#                         INSIDE 1025's publisher and AFTER 1026/1027's block (dfar / dfsr / arm_ctx /
#                         thread / map / code all in scope).  READS only; one extra read-only
#                         `vm_map_lookup_entry(map, far, &e)` - the same call 1026/1027 already make.
#   bsd/kern/kern_exec.c  Site B: the accessors `xnu_live_rdr_proc_argslen` / `xnu_live_rdr_proc_argc`
#                         (the PROC's recorded argv/env block bounds, read BY NAME from Site A).
#
# **THE CHANNEL IS THE GLOBAL `DEFINES` ARRAY of tools/build_xnu_arm_kernel.sh (env), NOT EXTRA.**
# build_1029.sh carries that array's block and arrests a `-DSTAGE90_XNU_READER_PROBE` in EXTRA (the
# records/1020-build-defect.txt shape), so an EXTRA-only build cannot ship a stale pool behind a green
# build.
#
# **THIS IS A POOL-REBUILD RUNG (the 1015b shape).**  trap.c and kern_exec.c are POOL files;
# `build_entry.sh` only LINKS the pool objects, so a green entry build says NOTHING about this half.
# **UNLIKE 1028, THIS RUNG DOES PRINT**, so it HAS a real `strings` fingerprint in the objects
# (`xnu_live_rdr_far=` in trap.o, the `xnu_live_rdr_proc_argslen` symbol in kern_exec.o) - and the park
# reads them OFF THE OBJECTS first, then re-reads them on the FROZEN bytes.
#
# **[[mi4-one-file-many-rungs]].**  FOUR rungs edit bsd/kern/kern_exec.c (1025 / 1026 / 1028 / 1029) and
# FIVE edit osfmk/arm/trap.c (994 / 1020 / 1025 / 1026 / 1029).  A cleanup `git checkout --` SILENTLY
# reverts the others and the failure surfaces LATE (the pool compiles; the INHERITED check refuses the
# LINKED image).  The park's own by-value clauses are what catch a build that dropped the parents.
#
# **THE CARRIERS.**  The record carries `STAGE90_XNU_READER_PROBE=1` (the switch the probe is gated by AND
# the readability carrier).  The declaration carrier out/stage90/xnu_arm_entry-arm-extra.txt is written by
# THIS build's tail as `STAGE90_XNU_GLOBAL_FIX=1 role=1029-reader-probe` (1015b's GLOBAL_FIX is a POOL
# switch no writer in src/entry/ echoes).  A grep of that file is a PROCESS check; the by-value clauses
# below are what actually certify the arm ([[mi4-self-written-record-is-not-a-constraint]]).
#
# THE 1029 VERDICT CELLS (docs/1029-design.md section 4; the press reads them off the capture via
# tools/check_1029_capture.py):
#   READER-NAMED   - far_minus_ustack == 0x1000 AND entry_at_hit == 0 AND blk_hi == ustack AND
#                    blk_bytes == (ustack - blk_lo) AND far == ustack + 0x1000: the store is one PAGE
#                    above the advertised top, the block did NOT grow, and `far` is covered by NO entry
#                    => the derivation from `p->user_stack` is PROVEN
#   READER-UNKNOWN - any other combination => fail closed and NAME the missing conjunct; pick NO fix
#   REGRESSION     - launchd absent / trap24 rows vanish / port_construct result=0 vanish / panic
#   G-CTL          - no capture NEWER than this press's boot epoch => WITHHOLD (the stale-slot rule)
#   FAULT-NAMED    - the 1025/1026/1027 PARENT CELLS must still fire beside the new rows
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
# RECENT PRESSED arms under a new name (build 1029 first).  10b79e5d is the arm the 1023 press SPENT;
# 1028's own arm (armed-d13-35a7e83e, its park name) is the arm 1029 builds ON and is refused
# DYNAMICALLY below: re-parking it would freeze 1028's bytes under a 1029 label and read FIX-NOOP as
# if it were 1029's own reading.
# NOTE: 35a7e83e is 1028's PARK name = the sha8 of ITS OWN xnu_arm_entry.bin, so the static row below
# cannot fire for a 1029 build (1029's probe moves the pool and therefore the bin).  The dynamic,
# by-value form is the one that actually binds.
ARM=armed-d13-$(sha256sum "$LIVE/xnu_arm_entry.bin" | cut -c1-8)
[[ $ARM == armed-d13-10b79e5d ]] && { echo "REFUSING: $LIVE holds 1023's PRESSED arm (10b79e5d) - the arm whose storm 1024 moved away from; build 1029 first"; exit 1; }
[[ $ARM == armed-d13-35a7e83e ]] && { echo "REFUSING: $LIVE holds 1028's arm (35a7e83e) - the arm 1028 was PARKED under (its reader-probe-less pool); 1029 builds ON it, and re-parking it under a 1029 label would freeze 1028's bytes as this rung's own. build 1029 first"; exit 1; }
[[ $ARM == armed-d13-d06ee14f ]] && { echo "REFUSING: $LIVE holds 1027's PRESSED arm (d06ee14f) - the arm 1028 built on; build 1029 first"; exit 1; }
[[ $ARM == armed-d13-5c1fb3ca ]] && { echo "REFUSING: $LIVE holds 1026's PRESSED arm (5c1fb3ca) - the arm 1027 built on; build 1029 first"; exit 1; }
[[ $ARM == armed-d13-d7f1e533 ]] && { echo "REFUSING: $LIVE holds 1025's PRESSED arm (d7f1e533) - the arm 1027 built on; build 1029 first"; exit 1; }
[[ $ARM == armed-d13-b47131c8 ]] && { echo "REFUSING: $LIVE holds 1022's PRESSED arm (b47131c8); build 1029 first"; exit 1; }
[[ $ARM == armed-d13-ee2dd4fb ]] && { echo "REFUSING: $LIVE holds 1021d's PRESSED arm (ee2dd4fb); build 1029 first"; exit 1; }
[[ $ARM == armed-d13-b5093f00 ]] && { echo "REFUSING: $LIVE holds 1020b's PRESSED arm (b5093f00); build 1029 first"; exit 1; }
[[ $ARM == armed-d13-47f664c4 ]] && { echo "REFUSING: $LIVE holds 1020's DROPPED-GLOBAL-FIX arm (47f664c4); build 1029 first"; exit 1; }
[[ $ARM == armed-d13-c2168632 ]] && { echo "REFUSING: $LIVE holds 1018's arm (c2168632); build 1029 first"; exit 1; }
[[ $ARM == armed-d13-16fe8885 ]] && { echo "REFUSING: $LIVE holds 1015b's arm (16fe8885); build 1029 first"; exit 1; }
[[ $ARM == armed-d13-e51d14fa ]] && { echo "REFUSING: $LIVE holds 1015's arm (e51d14fa); build 1029 first"; exit 1; }
[[ $ARM == armed-d13-29ec9e48 ]] && { echo "REFUSING: $LIVE holds 1014's arm (29ec9e48); build 1029 first"; exit 1; }
[[ $ARM == armed-d13-9bf25f8f ]] && { echo "REFUSING: $LIVE holds 1013b's arm (9bf25f8f); build 1029 first"; exit 1; }
[[ $ARM == armed-d13-ffdc8ba1 ]] && { echo "REFUSING: $LIVE holds 1012's arm (ffdc8ba1); build 1029 first"; exit 1; }

# ====================================================================================================
# 1029'S OWN CHANGE, BY VALUE, FIRST - BEFORE EVERY INHERITED REGRESSION CLAUSE.
# **THE ORDER IS THE POINT.**  A park that lost this rung's probe must fail HERE, on ITS OWN
# claim (the record's switch + the STAGED source's two blocks + the two pool objects' `strings`
# fingerprints), rather than further down where an inherited clause would stop it for a reason that
# names the wrong thing.
# ====================================================================================================
echo "== 1029's OWN change, by value, first =="

# (a) THE RECORD'S OWN KEY.  `STAGE90_XNU_READER_PROBE=1` is BOTH the switch the probe is gated by AND
#     the readability carrier.  Absent it, the pool was compiled with BOTH blocks SHUT: the trap.c rows
#     never print and the kern_exec.c accessors do not exist, so the press would read G-CTL (silence)
#     for a reason that is not the device's, and the arm is not 1029's.
grep -q '^STAGE90_XNU_READER_PROBE=1$' "$LIVE/xnu_arm_entry-config.txt" || {
  echo "REFUSING: the record does not carry STAGE90_XNU_READER_PROBE=1 - the reader probe this rung IS is gated by THIS switch, and it is set on this arm. Its absence means the pool was built with Site A/B SHUT, so no xnu_live_rdr_* row could ever be published and 1029 would read G-CTL for a reason that is not the device's. Build with scripts/build_1029.sh"; exit 1; }

# (a2) 1028'S KEY, CARRIED VERBATIM.  1029 ADDS the reader probe to 1028's set, not instead of it: the H2
#      fix is what MOVED the fault to `far = ustack + 0x1000`, and that geometry IS the reading 1029
#      adjudicates (far_minus_ustack == 0x1000).  Reverting it would put the fault back at the region top
#      and the READER-NAMED cell would be measuring a different arm.
grep -q '^STAGE90_XNU_H2_STACK_HEADROOM=1$' "$LIVE/xnu_arm_entry-config.txt" || {
  echo "REFUSING: the record does not carry STAGE90_XNU_H2_STACK_HEADROOM=1 - 1029 carries 1028's H2 fix verbatim, and its \`far - ustack == 0x1000\` conjunct is the geometry THAT fix produced. Its absence means the pool was built with the FIXED extent SHUT, so the fault would sit at the region top and this arm is not the one docs/1029-design.md s.4 pre-registers. Build with scripts/build_1029.sh"; exit 1; }

# (a3) 1027'S KEY, CARRIED VERBATIM.  1029's rows are read BESIDE the 1026/1027 discriminator (FAULT-NAMED
#      must still fire); a record without STAGE90_XNU_ABT_ENTRY_PROBE=1 would leave the parent cells (and
#      the `entry_at_hit` family's own co-reading) impossible.
grep -q '^STAGE90_XNU_ABT_ENTRY_PROBE=1$' "$LIVE/xnu_arm_entry-config.txt" || {
  echo "REFUSING: the record does not carry STAGE90_XNU_ABT_ENTRY_PROBE=1 - 1029 carries 1027's discriminator verbatim as its PARENT CELLS, and the capture's xnu_live_abt_* rows are read beside the new ones. Its absence means the pool was built with the discriminator SHUT and half the reading would be gone. Build with scripts/build_1029.sh"; exit 1; }

# (a3b) 1025'S PARENT KEY.  1029's Site A rows are NESTED INSIDE 1025's publisher block, so a record
#       without STAGE90_XNU_USTACK_PROBE=1 means the rows never execute (their parent gate is shut) even
#       with 1029's switch on - and the 1025 re-reading would be gone too.
grep -q '^STAGE90_XNU_USTACK_PROBE=1$' "$LIVE/xnu_arm_entry-config.txt" || {
  echo "REFUSING: the record does not carry STAGE90_XNU_USTACK_PROBE=1 - 1029's Site A rows are NESTED INSIDE 1025's publisher block, so with the parent gate shut the ten reads never execute and the capture would be silent on the reader question while the record says the probe is live ([[mi4-one-file-many-rungs]]). Build with scripts/build_1029.sh"; exit 1; }

# (a4) **1029'S OWN CHANGE, ON THE STAGED SOURCE.**  UNLIKE 1028's value-only fix, this rung PRINTS, so
#      the object-side fingerprints below are REAL strings - but the staged-tree counts are still the
#      first (cheapest, most specific) read of a partial or double edit, and the `#endif` counts prove
#      each gate is BRACKETED ([[mi4-off-option-two-spellings]]).
_tr_src=$PWD/external/xnu-hd2-darwin13/xnu/osfmk/arm/trap.c
_ke_src=$PWD/external/xnu-hd2-darwin13/xnu/bsd/kern/kern_exec.c
[[ -f $_tr_src ]] || { echo "REFUSING: $_tr_src is absent - the staged trap.c this park reads is not on disk"; exit 1; }
[[ -f $_ke_src ]] || { echo "REFUSING: $_ke_src is absent - the staged kern_exec.c this park reads is not on disk"; exit 1; }
[[ $(grep -c 'xnu_live_rdr_far=' "$_tr_src") == 1 ]] || {
  echo "REFUSING: the staged $_tr_src does not carry EXACTLY 1 xnu_live_rdr_far= line - Site A's rows are not staged, or a partial/double edit landed (the 1029 patcher REFUSES the latter, so the tree is in a state no build of this rung produced). Build with scripts/build_1029.sh"; exit 1; }
[[ $(grep -c '^#endif /\* STAGE90_XNU_READER_PROBE \*/' "$_tr_src") == 1 ]] || {
  echo "REFUSING: the staged $_tr_src does not carry EXACTLY 1 \`#endif /* STAGE90_XNU_READER_PROBE */\` marker - Site A's ON/OFF gate is not bracketed, so the OFF arm is not the 1028 tree's bytes"; exit 1; }
[[ $(grep -c 'xnu_live_rdr_proc_argslen' "$_ke_src") -ge 1 ]] || {
  echo "REFUSING: the staged $_ke_src carries NO xnu_live_rdr_proc_argslen - Site B's accessor is not staged, so Site A's \`extern\` would be unresolved at the link"; exit 1; }
[[ $(grep -c '^#endif /\* STAGE90_XNU_READER_PROBE \*/' "$_ke_src") == 1 ]] || {
  echo "REFUSING: the staged $_ke_src does not carry EXACTLY 1 \`#endif /* STAGE90_XNU_READER_PROBE */\` marker - Site B's ON/OFF gate is not bracketed"; exit 1; }
# NESTING: Site A's gate must sit INSIDE 1025's publisher and OUTSIDE 1026/1027's block.  Read the line
# numbers BY VALUE (a text count cannot see a displaced block).
_tr_105=$(grep -n '^#endif /\* STAGE90_XNU_USTACK_PROBE \*/' "$_tr_src" | head -1 | cut -d: -f1)
_tr_106=$(grep -n '^#endif /\* STAGE90_XNU_ABT_ENTRY_PROBE \*/' "$_tr_src" | head -1 | cut -d: -f1)
_tr_109=$(grep -n '^#endif /\* STAGE90_XNU_READER_PROBE \*/' "$_tr_src" | head -1 | cut -d: -f1)
[[ -n $_tr_109 && $_tr_106 -lt $_tr_109 && $_tr_109 -lt $_tr_105 ]] || {
  echo "REFUSING: 1029's gate is NOT between its two parents (trap.c lines: 1026 #endif=$_tr_106, 1029 #endif=$_tr_109, 1025 #endif=$_tr_105). Site A's rows must sit INSIDE the shared fault-path gate (or they never execute) AND OUTSIDE 1026/1027's block (or they are gated on the wrong switch)"; exit 1; }
echo "   BY VALUE(1-a4): the staged trap.c carries xnu_live_rdr_far= (x1) + one bracketing #endif, sitting between its two parents (1026=$_tr_106 < 1029=$_tr_109 < 1025=$_tr_105), and kern_exec.c carries the xnu_live_rdr_proc_argslen accessor + one bracketing #endif"

# (b) THE BY-VALUE CLAUSE - THE PARK'S OWN CLAIM, ON THE TWO POOL OBJECTS.
#     The fingerprints are a FORMAT STRING (`xnu_live_abt_lookup_far=`, read by `strings`) and a SYMBOL
#     (`xnu_live_abt_proc_ustack`, read by `strings`), off the POOL OBJECTS (the 1027 build's 5a
#     clause).  The park reads the objects directly because the edit's home IS the objects; the press
#     re-reads the LINKED image.
#
#     **THE CHECKER IS REQUIRED, AND ITS ABSENCE IS A REFUSAL, NOT A SKIP.**  A park that skipped this
#     would freeze an arm whose own claim nothing checks ([[mi4-a-claim-in-a-comment-is-not-a-check]]).
[[ -f tools/check_1029_capture.py ]] || {
  echo "REFUSING: tools/check_1029_capture.py is ABSENT. It is this park's capture reader (the READER-NAMED / READER-UNKNOWN / REGRESSION / G-CTL cells the press is adjudicated by), and there is no sound fallback. An absent checker means the by-value half of this rung cannot be certified"; exit 1; }

# 1029-0. THE CHECKER'S OWN SELF-TEST.  A checker that cannot fail is not a check
#         ([[mi4-a-claim-in-a-comment-is-not-a-check]]).  Refuse the park unless it PASSes its selftest.
python3 -I tools/check_1029_capture.py --selftest >/dev/null 2>&1 || {
  echo "REFUSING: tools/check_1029_capture.py --selftest did NOT PASS - the checker cannot certify anything (an inert checker would bless any capture). Fix the checker before parking the arm it is supposed to prove"; exit 1; }
echo "   BY VALUE(0): tools/check_1029_capture.py --selftest PASSes (the checker is live)"

# 1029-1. **THIS RUNG'S OWN FINGERPRINTS, ON THE TWO POOL OBJECTS.**  This is the park's own claim and it
#         comes FIRST among the object clauses: 1029 PRINTS, so unlike 1028 it has REAL `strings`
#         evidence.  Read the OBJECTS (the edit's home), `grep -qa P <(strings X)` NOT
#         `strings X | grep -q P` (pipefail/SIGPIPE = 141 - m1025).
[[ -d out/xnu_kernel_obj_d13 ]] || { echo "REFUSING: out/xnu_kernel_obj_d13 is absent - the pool the linked image was built from is not on disk"; exit 1; }
_trap_obj=out/xnu_kernel_obj_d13/osfmk_arm_trap.o
_exec_obj=out/xnu_kernel_obj_d13/bsd_kern_kern_exec.o
[[ -f $_trap_obj ]] || { echo "REFUSING: $_trap_obj is absent - trap.c is where Site A's xnu_live_rdr_* rows live; a park that cannot read it cannot certify the probe"; exit 1; }
[[ -f $_exec_obj ]] || { echo "REFUSING: $_exec_obj is absent - kern_exec.c is where Site B's accessors live; a park that cannot read it cannot certify that Site A's \`extern\` would resolve"; exit 1; }
grep -qa '^xnu_live_rdr_far=' <(strings "$_trap_obj") || {
  echo "REFUSING: $_trap_obj carries NO xnu_live_rdr_far= publisher - the pool was NOT recompiled with STAGE90_XNU_READER_PROBE=1 (the env -> global DEFINES channel of build_xnu_arm_kernel.sh) or Site A's trap.c edit is not staged. Without this row the press captures NOTHING on the launchctl fault and 1029 reads G-CTL for a reason that is not the device's. Re-run scripts/build_1029.sh"; exit 1; }
grep -qa 'xnu_live_rdr_proc_argslen' <(strings "$_exec_obj") || {
  echo "REFUSING: $_exec_obj carries NO xnu_live_rdr_proc_argslen symbol - Site B's accessor is not in the pool object, so the linked image would carry Site A's unresolved \`extern\` (or a stale object). The READER-NAMED cell's blk_bytes/blk_lo conjuncts would be unreadable. Re-run scripts/build_1029.sh"; exit 1; }
# SITE A PUBLISHES THE WHOLE KEY SET, not just the first row: a partial block would print `far` and stop
# exactly where the cell's other conjuncts are read.
for _k in '^xnu_live_rdr_ustack=' '^xnu_live_rdr_far_minus_ustack=' '^xnu_live_rdr_blk_hi=' '^xnu_live_rdr_blk_lo=' '^xnu_live_rdr_blk_bytes=' '^xnu_live_rdr_entry_at_hit=' '^xnu_live_rdr_entry_at_lo=' '^xnu_live_rdr_entry_at_hi='; do
  grep -qa "$_k" <(strings "$_trap_obj") || {
    echo "REFUSING: $_trap_obj carries NO $_k row - Site A's block is PARTIAL (a truncated edit). Every row is required: the READER-NAMED cell reads far_minus_ustack / blk_hi / blk_lo / blk_bytes / entry_at_hit TOGETHER, and docs/1029-design.md s.3.4 forbids gating any of them". exit 1; }
done
echo "   BY VALUE(1): $_trap_obj carries 1029's xnu_live_rdr_far= + the whole row set, $_exec_obj carries the xnu_live_rdr_proc_argslen accessor (Site A and Site B both reached the pool objects)"

# 1029-1b. THE INHERITED PARENT CELLS, ON THE SAME OBJECTS.  1029 rebuilds the WHOLE pool (its own trap.c
#          AND kern_exec.c edits), so the 1025/1026/1027 publishers its cells are read BESIDE must SURVIVE.
grep -qa '^xnu_live_abt_lookup_far=' <(strings "$_trap_obj") || {
  echo "REFUSING: $_trap_obj carries NO xnu_live_abt_lookup_far= publisher - the pool was NOT recompiled with STAGE90_XNU_ABT_ENTRY_PROBE=1 or the trap.c edit is not staged. 1029 carries 1027 as its parent cells. Re-run scripts/build_1029.sh"; exit 1; }
grep -qa '^xnu_live_abt_e2_hi=' <(strings "$_trap_obj") || {
  echo "REFUSING: $_trap_obj carries NO xnu_live_abt_e2_hi= publisher - this is a 1026 SHAPE pool (e2 bounds never printed). 1029 carries 1027's amendment, so it must be here. Re-run scripts/build_1029.sh"; exit 1; }
grep -qa '^xnu_live_abt_proc_ustack$' <(strings "$_exec_obj") || {
  echo "REFUSING: $_exec_obj carries NO xnu_live_abt_proc_ustack symbol - the pool was NOT recompiled with STAGE90_XNU_ABT_ENTRY_PROBE=1 or the kern_exec.c accessor is not staged. Re-run scripts/build_1029.sh"; exit 1; }
# 1025'S PUBLISHERS MUST SURVIVE THE SAME POOL REBUILD (the [[mi4-one-file-many-rungs]] check, BY VALUE):
# 1029's Site A rows are NESTED inside 1025's publisher, so a build that dropped 1025's switch would
# leave the reader block compiled-out while the pointer still pointed at dead text.
grep -qa '^xnu_live_abt_vmfkrv=' <(strings "$_trap_obj") || {
  echo "REFUSING: $_trap_obj lost 1025's xnu_live_abt_vmfkrv= publisher in this pool rebuild - 1029's Site A rows are NESTED inside 1025's publisher, so they would never run ([[mi4-one-file-many-rungs]]). Re-run scripts/build_1029.sh"; exit 1; }
grep -qa '^xnu_live_ustack_req=' <(strings "$_exec_obj") || {
  echo "REFUSING: $_exec_obj lost 1025's xnu_live_ustack_req= publisher in this pool rebuild - 1029 builds ON 1025/1026/1027/1028, not over them. Re-run scripts/build_1029.sh"; exit 1; }
echo "   BY VALUE(1b): the inherited parents survive the rebuild (trap.o has xnu_live_abt_lookup_far= + xnu_live_abt_e2_hi= + xnu_live_abt_vmfkrv=, kern_exec.o has xnu_live_abt_proc_ustack + xnu_live_ustack_req=)"

# 1029-2. THE LINKED-IMAGE CO-READING.  build_entry.sh LINKS the pool objects, so the read this rung's
#         cells are taken from must ALSO be reachable from the linked ELF the press boots (an object the
#         linker DROPPED would leave the arm's claim unmet).  Read here as CONTEXT; the press re-runs it
#         as its step 0f.
grep -qa '^xnu_live_rdr_far=' <(strings "$LIVE/xnu_arm_entry.elf") || {
  echo "REFUSING: the LINKED $LIVE/xnu_arm_entry.elf carries NO xnu_live_rdr_far= string - Site A's rows did not reach the image the press boots, so the press would capture nothing on the launchctl fault and 1029 would read G-CTL for a reason that is not the device's. Re-run scripts/build_1029.sh"; exit 1; }
grep -qa '^xnu_live_abt_lookup_far=' <(strings "$LIVE/xnu_arm_entry.elf") || {
  echo "REFUSING: the LINKED $LIVE/xnu_arm_entry.elf carries NO xnu_live_abt_lookup_far= string - the pool object that has it was not linked, so the FAULT-NAMED parent cell could not be re-read. Re-run scripts/build_1029.sh"; exit 1; }
grep -qa '^xnu_live_abt_e2_hi=' <(strings "$LIVE/xnu_arm_entry.elf") || {
  echo "REFUSING: the LINKED $LIVE/xnu_arm_entry.elf carries NO xnu_live_abt_e2_hi= string - 1027's far-4 bounds did not reach the image the press boots. Re-run scripts/build_1029.sh"; exit 1; }
grep -qa '^xnu_live_abt_vmfkrv=' <(strings "$LIVE/xnu_arm_entry.elf") || {
  echo "REFUSING: the LINKED $LIVE/xnu_arm_entry.elf carries NO xnu_live_abt_vmfkrv= string - 1025's publisher was dropped from the link. Re-run scripts/build_1029.sh"; exit 1; }
echo "   BY VALUE(2): the LINKED $LIVE/xnu_arm_entry.elf carries 1029's xnu_live_rdr_far= row, the 1027 discriminator (lookup_far + e2_hi) AND 1025's publisher (the read reached the image the press boots)"

# (c) THE ARM-EXTRA DECLARATION CARRIER.  1028's build WRITES this file at its tail
#     (`STAGE90_XNU_GLOBAL_FIX=1 role=1029-reader-probe`), so THIS park requires it verbatim and never
#     appends.  1015b's GLOBAL_FIX is a POOL switch no writer in src/entry/ echoes, so the record cannot
#     carry it; this drop-in is its ONE declaration, and the role tag names 1028 so a stale 1024/1025/1027
#     line is distinguishable by content.  **THE GREP IS THE PROCESS CHECK, NOT THE PROOF** - the
#     pmap_flush_tlbs fingerprint below is what certifies the fix is in the object
#     ([[mi4-self-written-record-is-not-a-constraint]]).
_b_extra="$LIVE/xnu_arm_entry-arm-extra.txt"
[[ -f $_b_extra ]] || { echo "REFUSING: $_b_extra is absent - 1029's build writes the declaration carrier at its tail; an absent one means this arm's build did not finish"; exit 1; }
[[ $(wc -l < "$_b_extra") == 1 && $(cat "$_b_extra") == 'STAGE90_XNU_GLOBAL_FIX=1 role=1029-reader-probe' ]] || {
  echo "REFUSING: $_b_extra is not EXACTLY the one 1029 line (it holds '$(cat "$_b_extra")' across $(wc -l < "$_b_extra") line(s)). 1015b's GLOBAL_FIX is a POOL switch no writer in src/entry/ echoes, so this drop-in is its ONE declaration, and 1029's build writes it as exactly this line. A surviving 1027 line (role=1027-abt-entry-probe) would be a declaration OF A DIFFERENT BUILD ([[mi4-self-written-record-is-not-a-constraint]]). Re-run scripts/build_1029.sh"; exit 1; }
echo "   DECLARATION: $_b_extra carries exactly '$(cat "$_b_extra")' (written by THIS build; the proof is the fingerprint below)"

# ---- THE INHERITED GLOBAL-FIX CLAUSE: IT IS IN THE FROZEN POOL OBJECT, BY VALUE ----
# 1020's pool rebuild DROPPED 1015b (records/1020-build-defect.txt): the storm returned.  1028 rebuilds
# the WHOLE pool (kern_exec.c is a POOL file), so the same defect is available.  The fix's fingerprint is
# the count of `kernel_pmap` MOVW materializations inside `pmap_flush_tlbs` (OFF/Apple = 2, ON = 3).
_gf_obj=out/xnu_kernel_obj_d13/osfmk_arm_pmap.o
[[ -f "$_gf_obj" ]] || { echo "REFUSING: $_gf_obj is absent - 1015b's GLOBAL-FIX lives in pmap_flush_tlbs, and a park that cannot read it cannot certify the storm stays gone"; exit 1; }
_gf_kp=$(arm-none-eabi-objdump -r "$_gf_obj" 2>/dev/null | awk '$1>="00000418" && $1<="00000640"' | grep -c 'MOVW_ABS_NC.*kernel_pmap' || true)
_gf_full=$(arm-none-eabi-objdump -r "$_gf_obj" 2>/dev/null | awk '$1>="00000418" && $1<="00000640"' | grep -c 'R_ARM_CALL.*arm_tlb_flushID$' || true)
_gf_asid=$(arm-none-eabi-objdump -r "$_gf_obj" 2>/dev/null | awk '$1>="00000418" && $1<="00000640"' | grep -c 'R_ARM_CALL.*arm_tlb_flushID_ASID$' || true)
[[ "$_gf_kp" == "3" && "$_gf_full" == "1" && "$_gf_asid" == "1" ]] || {
  echo "REFUSING: pmap_flush_tlbs materializes kernel_pmap x$_gf_kp (want 3), arm_tlb_flushID x$_gf_full / arm_tlb_flushID_ASID x$_gf_asid (want 1/1) - GLOBAL-FIX is NOT in the pool object, so the retry storm 1015b killed is BACK and the run would never reach the launchctl abort this rung acts on. -DSTAGE90_XNU_GLOBAL_FIX=1 has NO record carrier (records/1020-build-defect.txt). Re-run scripts/build_1029.sh."; exit 1; }
echo "   POOL(GLOBAL-FIX): by value - pmap_flush_tlbs carries the 3rd kernel_pmap materialization ($_gf_kp sites) and the declared 1/1 flush arms, so 1015b's GLOBAL-FIX IS in the pool object"

# ---- THE INHERITED 1024 CEILING CLAUSE: IT IS IN THE LINKED IMAGE, BY VALUE ----
# 1028 ADDS ONLY THE H2 FIX, so 1024's task-map ceiling (VM_MAX_ADDRESS 0x40000000) must still be
# in the image the press boots.  `tools/check_vm_max_split.py` reads `task_create_internal` BY VALUE.
[[ -f tools/check_vm_max_split.py ]] || { echo "REFUSING: tools/check_vm_max_split.py is ABSENT - it is the inherited 1024 claim's by-value check on the linked image's task-map ceiling"; exit 1; }
python3 -I tools/check_vm_max_split.py --selftest >/dev/null 2>&1 || { echo "REFUSING: tools/check_vm_max_split.py --selftest did NOT PASS - the inherited ceiling checker cannot certify anything"; exit 1; }
python3 -I tools/check_vm_max_split.py "$LIVE/xnu_arm_entry.elf" --expect on >/dev/null 2>&1 || {
  echo "REFUSING: the LINKED image's task_create_internal does NOT pass 0x40000000 to vm_map_create - either 1024's widened vm_param.h:63 line did not reach the pool, or a STALE pool object was linked (build_entry.sh only LINKS it). The 1023 storm would return and the run would never reach launchctl. Re-run scripts/build_1029.sh"; exit 1; }
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
  echo "REFUSING: $_pool holds $_got_objs object(s) but $_src_rec names $_want_objs source(s) - the census would count the WRONG set (a partial or stale directory passes any NEON-free test vacuously). Re-run scripts/build_1029.sh"; exit 1; }
python3 -I tools/check_d13_no_neon.py --pool "$_pool" --expect none --min-objects "$_want_objs" >/dev/null 2>&1 || {
  echo "REFUSING: tools/check_d13_no_neon.py --pool $_pool --expect none did NOT pass - the pool the linked image was built from still contains FP/NEON instructions. 1028 recompiles the WHOLE pool, so the -msoft-float flag must still reach every object or the kernel-mode NEON undef at 0x8047b0ac returns. Re-run scripts/build_1029.sh"; exit 1; }
python3 -I tools/check_d13_no_neon.py "$LIVE/xnu_arm_entry.elf" --symbol mach_msg_send --expect none >/dev/null 2>&1 || {
  echo "REFUSING: the LINKED image's mach_msg_send still contains FP/NEON instructions - 1021d's -msoft-float flag did not reach the object the linker saw, or a STALE pool object was linked. Re-run scripts/build_1029.sh"; exit 1; }
echo "   POOL(NEON-FREE): by value - $_got_objs objects NEON-free (== $_want_objs source(s)), and the LINKED mach_msg_send is NEON-free (1021d's -msoft-float holds)"

# ====================================================================================================
# THE INHERITED REGRESSION CLAUSES - 1025's / 1024's / 1023's / 1022's / 1021d's / 1020b's / 1018's, kept
# IN MEANING (placed AFTER 1027's own change, so a park that lost this rung's discriminator has already
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
  echo "REFUSING: the LINKED image's mach_trap_table[24] is NOT the ios7lab_mach_port_construct_trap row any more (or rows 25/41/42 moved) - 1029 adds only the reader probe and must MOVE nothing else. Re-run scripts/build_1029.sh"; exit 1; }
echo "   BY VALUE(3): tools/check_1023_trap24.py --expect on PASSes (1023's row 24 is intact, rows 25/41/42 still kern_invalid)"
# 1020's by-value clause, re-run on the LINKED image.
[[ -f tools/check_d13_undef_raise.py ]] || { echo "REFUSING: tools/check_d13_undef_raise.py is ABSENT - it is the inherited 1020 claim's by-value check on the linked image"; exit 1; }
python3 -I tools/check_d13_undef_raise.py "$LIVE/xnu_arm_entry.elf" --expect on >/dev/null 2>&1 || {
  echo "REFUSING: tools/check_d13_undef_raise.py --expect on did NOT pass on the linked image - 1020's moved \`return\` is NOT in this image's sleh_undef, so the udf loop is back. Re-run scripts/build_1029.sh"; exit 1; }
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
# certified - a later build cannot silently change what was pressed.  1029's Site A rows ARE prints, so
# (unlike 1028's value-only H2 fix) this rung's own edit has a string the frozen entry ELF can be
# re-read for.
grep -qa '^xnu_live_rdr_far=' <(strings "$PARK/xnu_arm_entry.elf") || {
  echo "REFUSING: the FROZEN $PARK/xnu_arm_entry.elf lost 1029's xnu_live_rdr_far= row - the copy is not the certified bytes, and a press of this arm would capture nothing on the launchctl fault. This park's directory is incomplete; remove $PARK and re-run"; exit 1; }
grep -qa '^xnu_live_abt_lookup_far=' <(strings "$PARK/xnu_arm_entry.elf") || {
  echo "REFUSING: the FROZEN $PARK/xnu_arm_entry.elf lost the xnu_live_abt_lookup_far= publisher - the copy is not the certified bytes. This park's directory is incomplete; remove $PARK and re-run"; exit 1; }
grep -qa '^xnu_live_abt_e2_hi=' <(strings "$PARK/xnu_arm_entry.elf") || {
  echo "REFUSING: the FROZEN $PARK/xnu_arm_entry.elf lost 1027's xnu_live_abt_e2_hi= publisher - the copy is not the certified bytes. This park's directory is incomplete; remove $PARK and re-run"; exit 1; }
grep -qa '^xnu_live_abt_vmfkrv=' <(strings "$PARK/xnu_arm_entry.elf") || {
  echo "REFUSING: the FROZEN $PARK/xnu_arm_entry.elf lost 1025's xnu_live_abt_vmfkrv= publisher - the copy is not the certified bytes. This park's directory is incomplete; remove $PARK and re-run"; exit 1; }
python3 -I tools/check_vm_max_split.py "$PARK/xnu_arm_entry.elf" --expect on >/dev/null 2>&1 || {
  echo "REFUSING: the FROZEN $PARK/xnu_arm_entry.elf does not carry 1024's ceiling claim the live one did - the copy is not the certified bytes. This park's directory is incomplete; remove $PARK and re-run"; exit 1; }
python3 -I tools/check_1023_trap24.py "$PARK/xnu_arm_entry.elf" --expect on >/dev/null 2>&1 || {
  echo "REFUSING: the FROZEN $PARK/xnu_arm_entry.elf lost 1023's row-24 claim - the copy is not the certified bytes. This park's directory is incomplete; remove $PARK and re-run"; exit 1; }
# 1029's own edit is in SOURCE the arm's record binds by content (the pool compiled it), so re-read the
# STAGED source: both sites must still be present, on the parked arm's identity.
grep -q 'STAGE90_XNU_READER_PROBE' "$_tr_src" || {
  echo "REFUSING: the staged $_tr_src no longer carries STAGE90_XNU_READER_PROBE - the source the certified pool was built from has changed under the parked arm; the park's own claim is not re-readable. remove $PARK, re-stage the probe, and re-run"; exit 1; }
grep -q 'STAGE90_XNU_READER_PROBE' "$_ke_src" || {
  echo "REFUSING: the staged $_ke_src no longer carries STAGE90_XNU_READER_PROBE - Site B's accessors are gone from the source the certified pool was built from. remove $PARK, re-stage the probe, and re-run"; exit 1; }
grep -q 'STAGE90_XNU_H2_STACK_HEADROOM' "$_ke_src" || {
  echo "REFUSING: the staged $_ke_src no longer carries STAGE90_XNU_H2_STACK_HEADROOM - the PARENT 1028 fix the parked arm carries has been reverted under it. remove $PARK, re-stage, and re-run"; exit 1; }
echo "   BY VALUE(6): the FROZEN $PARK/xnu_arm_entry.elf carries 1029's xnu_live_rdr_far= row, the 1027 discriminator (lookup_far + e2_hi), 1025's publisher, 1024's ceiling (0x40000000) AND 1023's row 24; the staged trap.c AND kern_exec.c still carry STAGE90_XNU_READER_PROBE and kern_exec.c still carries STAGE90_XNU_H2_STACK_HEADROOM (the parked bytes are the certified bytes)"

{
  printf '# %s  -  1029: THE READER PROBE - NAME WHAT COVERS THE FAULTING WORD (AND WHAT READS THE ARGS).\n' "$ARM"
  printf '# 1028-s press RAN and its own console was recovered (records/1028-press-read.txt). The reading is\n'
  printf '# FIX-NOOP, BY VALUE, PAGE-EXACT - the H2 fix moved the region and the fault MOVED WITH IT:\n'
  printf '#   xnu_live_ustack_rc=0   p->user_stack=0x2bd0d000   far=0x2bd0e000\n'
  printf '#   far - ustack = 0x1000 (NOT 16: mach_vm_allocate rounds the extent up)   sp=0x2bd0c074\n'
  printf '#   ustack - sp = 0x0F8C        far - sp = 0x1F8C\n'
  printf '# H2 IS REFUTED AS A FIX TARGET by that page-exact displacement: the word at the region-s top was\n'
  printf '# NOT the cause, because the fault followed the top. docs/1029-design.md sec.0. REPORT IT; DO NOT\n'
  printf '# RE-FIX IT.\n'
  printf '# WHAT THE FAULT IS, THEREFORE, IS A QUESTION THE EXISTING ROWS CANNOT ANSWER: something is\n'
  printf '# writing one page ABOVE the advertised stack top, and NOTHING in the 1025/1026/1027/1028 set says\n'
  printf '# WHO OWNS THAT PAGE. 1029 answers it with a READER probe.\n'
  printf '# Switch set is 1028-s VERBATIM with **ONE NEW SWITCH: STAGE90_XNU_READER_PROBE=1**.\n'
  printf '# THE ARM (TWO SITES, one switch), staged by tools/patch_d13_reader_probe.py:\n'
  printf '#   Site A  osfmk/arm/trap.c  - rows INSIDE 1025-s publisher, AFTER 1026/1027-s block but WITHIN\n'
  printf '#                              1025-s block, so the reader rows ride the SAME fault the\n'
  printf '#                              discriminator fires on. Rows: far, ustack, far_minus_ustack, blk_hi,\n'
  printf '#                              blk_lo, blk_bytes, argc, entry_at_hit, entry_at_lo, entry_at_hi ->\n'
  printf '#                              xnu_live_rdr_* (RAM console, one key per line).\n'
  printf '#   Site B  bsd/kern/kern_exec.c - accessors that expose the `struct proc` the trap-side cannot see\n'
  printf '#                              (1026-s idiom): xnu_live_rdr_proc_argslen + the block bounds.\n'
  printf '# *** THE ARGS LENGTH IS THE POINT OF Site B. ***  blk_bytes vs (blk_hi - blk_lo) and argc separate\n'
  printf '# "the block did not grow" from "the block grew and its top is NOT p->user_stack" - the two\n'
  printf '# READER-UNKNOWN shapes sec.4 distinguishes.\n'
  printf '# THE CHANNEL IS THE GLOBAL DEFINES ARRAY of tools/build_xnu_arm_kernel.sh (env), NOT EXTRA\n'
  printf '# (build_1029.sh arrests a -DSTAGE90_XNU_READER_PROBE in EXTRA), so an EXTRA-only build cannot\n'
  printf '# ship a stale pool behind a green build.\n'
  printf '# THE POOL MOVES TWICE OVER: trap.c AND kern_exec.c are BOTH pool files, so the pool (and the\n'
  printf '# entry .bin whose sha8 IS the arm) MOVES (35a7e83e -> %s). build_entry.sh only LINKS the pool\n' "${ARM#armed-d13-}"
  printf '# objects, so a green entry build says nothing about this half.\n'
  printf '# [[mi4-one-file-many-rungs]]: FOUR rungs edit bsd/kern/kern_exec.c (1025 / 1026 / 1028 / 1029)\n'
  printf '# and FIVE edit osfmk/arm/trap.c (994 / 1020 / 1025 / 1026 / 1029); a cleanup `git checkout --`\n'
  printf '# reverts the others SILENTLY and the failure surfaces LATE.\n#\n'
  printf '# THE BY-VALUE PROOF OF 1029-S CHANGE (Site A rows ARE prints, so this rung has real strings\n'
  printf '# evidence - unlike 1028-s value-only fix):\n'
  printf '#   (0)  tools/check_1029_capture.py --selftest PASSes (the checker can fail);\n'
  printf '#   (1)  the POOL OBJECTS carry it: osfmk_arm_trap.o has `xnu_live_rdr_far=` AND the WHOLE row\n'
  printf '#        set, bsd_kern_kern_exec.o has `xnu_live_rdr_proc_argslen` (Site A + Site B both reached\n'
  printf '#        the objects); the INHERITED 1025/1026/1027 rows SURVIVE the same rebuild;\n'
  printf '#   (2)  the LINKED out/stage90/xnu_arm_entry.elf carries 1029-s row AND the inherited rows (the\n'
  printf '#        linker did not drop any of them);\n'
  printf '#   (6)  the FROZEN bytes still carry them AND the staged sources still carry the switch (the\n'
  printf '#        parked bytes are the certified bytes).\n#\n'
  printf '# THE CARRIERS ([[mi4-one-value-two-definitions]]). The record carries\n'
  printf '# STAGE90_XNU_READER_PROBE=1 (the switch the probe is gated by AND the readability carrier) AND\n'
  printf '# 1028-s STAGE90_XNU_H2_STACK_HEADROOM=1 AND 1027-s STAGE90_XNU_ABT_ENTRY_PROBE=1 AND 1025-s\n'
  printf '# STAGE90_XNU_USTACK_PROBE=1 (the PARENT gate). The declaration carrier\n'
  printf '# out/stage90/xnu_arm_entry-arm-extra.txt is written by THIS build-s tail as\n'
  printf '# STAGE90_XNU_GLOBAL_FIX=1 role=1029-reader-probe; the grep of it is the process check and the\n'
  printf '# pmap_flush_tlbs fingerprint is the proof.\n'
  printf '# THE INHERITED REGRESSIONS held (asserted by the park): STAGE90_XNU_GENERAL_REGS=1 (1021d-s\n'
  printf '# -msoft-float), STAGE90_XNU_UNDEF_RAISE=1, STAGE90_XNU_UNDEF_DIRECT=1, STAGE90_XNU_IOS7_TRAPS=1\n'
  printf '# and STAGE90_XNU_VM_MAX_SPLIT=1 in the record, 1024-s ceiling on the linked image, the\n'
  printf '# pmap_flush_tlbs kernel_pmap==3 fingerprint, the whole-pool NEON-free census + the linked\n'
  printf '# mach_msg_send NEON-free read, check_1023_trap24.py --expect on, check_d13_undef_raise.py\n'
  printf '# --expect on, and by value __wrap_sleh_undef branching to entry_write_kv (>=6) and NOT\n'
  printf '# entry_live_write (0).\n#\n'
  printf '# THE 1029 VERDICT CELLS (docs/1029-design.md sec.4; read via tools/check_1029_capture.py):\n'
  printf '#   READER-NAMED - far is EXACTLY one page above p->user_stack (far - ustack == 0x1000), NO entry\n'
  printf '#                 covers far (entry_at_hit == 0), and the block-s TOP bound IS p->user_stack\n'
  printf '#                 (blk_hi == ustack, blk_bytes == ustack - blk_lo) => the store is off the END of\n'
  printf '#                 a region whose top IS the advertised stack top. The NEXT rung names the writer\n'
  printf '#                 of that page. VALVE: the DECISIVE conjuncts are `entry_at_hit == 0` AND\n'
  printf '#                 `blk_hi == ustack` - NOT the literal 0x1000.\n'
  printf '#   READER-UNKNOWN - entry_at_hit == 1 (some entry DOES cover far: the fault is a permission /\n'
  printf '#                 attribute problem on a MAPPED page, a different bug), or far - ustack != 0x1000\n'
  printf '#                 (the geometry moved again: sec.8 says REFUSE TO PICK A FIX and instrument the\n'
  printf '#                 WALKER next). Both fail closed - a reading, not a blessing.\n'
  printf '#   REGRESSION  - trap24 / port_construct(result=0) vanish, or a panic appears => the probe\n'
  printf '#                 changed the pool-s behaviour, not just its console; report and revert.\n'
  printf '#   G-CTL / WITHHOLD - launchd never reached and no prior control live => no reading (fail closed).\n'
  printf '# Medium: 968 real iOS 7.1.2 HFSX rootfs over hfs_rmd0; CARD_COW=1, HDD_WRITE=0, base never\n'
  printf '# written - fully reversible. fastboot boot only, NEVER flash.\n'
  printf '# =================================================================================================\n'
  for m in "${MEMBERS[@]}"; do
    h=$(sha256sum "$PARK/$m" | awk '{print $1}')
    b=$(stat -c %s "$PARK/$m")
    printf 'set=%s sha256=%s bytes=%s file=%s role=1029-reader-probe;%s\n' \
      "$ARM" "$h" "$b" "$m" "$m"
  done
} >> "$REC"

echo "parked $ARM ($(ls -1 "$PARK" | wc -l) members)"
tools/verify_revert_set.sh "$PARK" --set="$ARM" 2>&1 | tail -3