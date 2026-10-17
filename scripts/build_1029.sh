#!/usr/bin/env bash
# Build 1029: 1028 PLUS THE READER PROBE -- PUBLISH THE DERIVATION CHAIN THAT PUTS THE STORE AT
# `user_stack + 0x1000`.  ONE new switch STAGE90_XNU_READER_PROBE=1, whose edit is
# tools/patch_d13_reader_probe.py -- TWO sites in TWO files:
#   osfmk/arm/trap.c       Site A: the `xnu_live_rdr_*` rows, on the usermode DATA-abort FAILURE arm
#                          INSIDE 1025's publisher and AFTER 1026/1027's block (where dfar / dfsr /
#                          arm_ctx / thread / map / code are ALL in scope at once).
#   bsd/kern/kern_exec.c   Site B: the accessors xnu_live_rdr_proc_argslen / xnu_live_rdr_proc_argc
#                          (the PROC's own recorded argv/env block bounds, read BY NAME from trap.c).
#
# WHY.  1028's press RAN and its own console was recovered (records/1028-press-read.txt).  The reading is
# **FIX-NOOP -- page-exact**, by value:
#
#     xnu_live_ustack_rc   = 0                 <- the FIXED allocate SUCCEEDED (no ANYWHERE fallback)
#     p->user_stack (final)= 0x2bd0d000
#     far                  = 0x2bd0e000
#     far - ustack         = 0x1000            <- the fault MOVED UP by exactly the page the region grew
#     sp                   = 0x2bd0c074   ustack - sp = 0x0F8C   far - sp = 0x1F8C
#
# The fix TOOK EFFECT and the fault FOLLOWED it, one page higher.  On 1024/1025/1026/1027 the same two
# offsets read `far == p->user_stack` and `far - sp == 0xF8C`.  So the failing store is NOT the block's
# top word (that was H2, and growing the region would have removed it): it is a userspace store whose
# address is a FUNCTION of `p->user_stack` -- the writer derives its store address FROM the advertised
# stack top, so raising the top raises the fault ([[mi4-a-window-is-an-interval-not-a-function]], the
# "the boundary can be in a READER" shape).  H2, AS A FIX TARGET, IS REFUTED.
#
# WHY A PROBE AND NOT A SECOND FIX.  Per the pre-registered 1028 cell: **report, do NOT re-fix.**
# Allocating another page would move the fault again and prove nothing.  1029 exists to NAME THE READER
# BY VALUE: it publishes, on the failing path only, `far`, `p->user_stack`, the DERIVATION DISTANCE
# `far - ustack`, the argv/env block's own bounds (`p_argc` / `p_argslen`), and whether `far` is covered
# by ANY vm_map entry (`entry_at_hit`).
#
# WHAT THIS RUNG IS NOT.  It allocates NOTHING and fixes NOTHING: SIX `printf`s plus ONE extra read-only
# `vm_map_lookup_entry(map, far, &e)` -- the SAME call 1026/1027 already make on this exact line range,
# taking no lock in this tree (`VM_MAP_STORE_USE_LL`) -- strictly AFTER `vm_fault` already returned
# non-SUCCESS and the trap already decided `EXC_BAD_ACCESS`.  No successful fault and no successful exec
# takes any new branch.  `sp`, the argv/env block, the guard page, `p->user_stack`, `LAB_USER_STACK`,
# `MAXSSIZ` and `VM_MAX_ADDRESS` are ALL UNCHANGED.  Read the reader: docs/1029-design.md.
#
# THE POOL EDITS.  FOUR rungs now edit bsd/kern/kern_exec.c (1025/1026 accessors + 1028 fix + 1029's
# accessor) and FIVE edit osfmk/arm/trap.c (994 witness / 1020 undef_raise / 1025 ustack_probe / 1026
# abt_entry_probe / 1029 reader).  1029's blocks are staged by tools/patch_d13_reader_probe.py, whose
# allow-sets carry EVERY other switch in each file ([[mi4-one-file-many-rungs]]).  A cleanup
# `git checkout --` reverts the others SILENTLY and the failure surfaces LATE (the pool compiles; the
# INHERITED check refuses the LINKED image), so step 2 RE-STAGES all of them in order.

set -euo pipefail

# ====================================================================================================
# ARGUMENTS.  `--resume-after-pool-build <log>` skips the (expensive) pool rebuild.
# ====================================================================================================
RESUME_LOG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --resume-after-pool-build) RESUME_LOG=$2; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

XNU_TREE=$PWD/external/xnu-hd2-darwin13/xnu
REC=out/stage90/xnu_arm_entry-config.txt
POOL=out/xnu_kernel_obj_d13
ELF=out/stage90/xnu_arm_entry.elf
CHECK=tools/check_1029_capture.py
PATCH=tools/patch_d13_reader_probe.py
TRAP_OBJ=$POOL/osfmk_arm_trap.o
EXEC_OBJ=$POOL/bsd_kern_kern_exec.o

echo "== 1029: READ THE READER (the PROBE that names who derives the store at user_stack + 0x1000; ONE new switch STAGE90_XNU_READER_PROBE=1) =="
echo "-- carries the previous arm's FULL switch set (read out of $REC, never a default); ADDS STAGE90_XNU_READER_PROBE=1 --"

# ====================================================================================================
# 0. PRECONDITIONS: the checker must exist AND pass its own selftest; the patcher and the staging
#    wrapper must exist; the switch's four carrier sites must be present.
# ====================================================================================================
echo "-- step 0: the capture checker, the patcher and the staging wrapper are what this rung is read with --"
[[ -f $CHECK ]] || { echo "REFUSING: $CHECK does not exist. 1029's whole substance is the READER PROBE (trap.c's xnu_live_rdr_* rows + kern_exec.c's xnu_live_rdr_proc_* accessors, staged by tools/patch_d13_reader_probe.py); the reading of WHICH reader derived the store comes from the CAPTURE the press produces, and $CHECK is its reader. A build that skipped this would be a record over an image whose probe the press could not adjudicate"; exit 1; }
python3 -I "$CHECK" --selftest >/dev/null || { echo "REFUSING: $CHECK --selftest did NOT pass. A checker whose own selftest fails cannot be the reading of this rung (m1015b). Do not build 1029 until the tool's selftest is green"; exit 1; }
echo "   step 0: $CHECK --selftest PASSes"
[[ -f $PATCH ]] || { echo "REFUSING: $PATCH does not exist - the tree's reader-probe blocks are gated shut on CANCRO and this script stages them through that patcher"; exit 1; }
# The switch's channel: the global DEFINES block must be present, or the export below is a no-op.
grep -q 'DEFINES+=(-DSTAGE90_XNU_READER_PROBE=1)' tools/build_xnu_arm_kernel.sh || { echo "REFUSING: tools/build_xnu_arm_kernel.sh carries no STAGE90_XNU_READER_PROBE block in its global DEFINES array. The switch's channel is that array (every compile line carries it, incl. the EABI-runtime and firehose blocks, which do NOT get EXTRA_DEFINES); without it the export below reaches nothing and the pool objects keep the UNINSTRUMENTED trap.c/kern_exec.c while the record says 1 -- the records/1020-build-defect.txt shape"; exit 1; }
grep -q 'STAGE90_XNU_READER_PROBE' src/entry/build_entry.sh || { echo "REFUSING: src/entry/build_entry.sh does not carry STAGE90_XNU_READER_PROBE (ENTRY_ARM_KEYS / the arm-key case / the record writer). Without all three the record cannot say which reader-probe arm its pool was built with"; exit 1; }
grep -q 'STAGE90_XNU_READER_PROBE' scripts/preflight_boot_check.sh || { echo "REFUSING: scripts/preflight_boot_check.sh does not carry STAGE90_XNU_READER_PROBE in ENTRY_CFG_KEYS (+ its -z grace branch). A record key the gate does not print is a switch the next run would go out with unread"; exit 1; }
# The shared namespace: kern_exec.c carries 1025/1026/1028's switches and trap.c carries 994/1020/1025/
# 1026's, and this rung adds one to EACH.  Every patcher's allow-set on both files must carry the new
# switch, or the OFF proofs refuse the composed tree ([[mi4-one-file-many-rungs]]).
for _p in tools/patch_d13_ustack_probe.py tools/patch_d13_abt_entry_probe.py tools/patch_d13_h2_stack_headroom.py tools/patch_d13_undef_raise.py tools/patch_d13_dyld_witness.py; do
  grep -q 'STAGE90_XNU_READER_PROBE' "$_p" || { echo "REFUSING: $_p's allow-set does not carry STAGE90_XNU_READER_PROBE. FOUR rungs edit bsd/kern/kern_exec.c and FIVE edit osfmk/arm/trap.c, and a file's directive identifiers are a SHARED namespace: without the new switch in every patcher's allow-set the OFF proofs refuse the composed tree ([[mi4-one-file-many-rungs]])"; exit 1; }
done
echo "   step 0: the switch's carrier sites (kernel DEFINES, entry keys/case/writer, gate key list) are present, and the trap.c/kern_exec.c patchers share the namespace"

# ====================================================================================================
# 1. CARRY THE PREVIOUS ARM'S FULL SWITCH SET -- never a default, read out of the arm's own record.
# ====================================================================================================
[ -r "$REC" ] || { echo "FAIL: no arm record at $REC -- build 1028 first (this rung carries ITS set)"; exit 1; }
grep -q '^STAGE90_XNU_H2_STACK_HEADROOM=1$' "$REC" || { echo "FAIL: $REC does not carry STAGE90_XNU_H2_STACK_HEADROOM=1 -- this is not the 1028 arm, and 1029 carries the whole 1028 set verbatim. The H2 fix is what MOVED the fault to far = ustack + 0x1000 -- the derivation 1029 exists to name -- so it is carried, not reverted"; exit 1; }
grep -q '^STAGE90_XNU_ABT_ENTRY_PROBE=1$' "$REC" || { echo "FAIL: $REC does not carry STAGE90_XNU_ABT_ENTRY_PROBE=1 -- this is not the 1027 arm, and 1029's rows are read BESIDE the 1026/1027 discriminator (the parent cells must still fire)"; exit 1; }
grep -q '^STAGE90_XNU_USTACK_PROBE=1$' "$REC" || { echo "FAIL: $REC does not carry STAGE90_XNU_USTACK_PROBE=1 -- this is not the 1025 arm, and 1029's Site A rows are NESTED inside 1025's publisher (they print nothing without it)"; exit 1; }
grep -q '^STAGE90_XNU_VM_MAX_SPLIT=1$' "$REC" || { echo "FAIL: $REC does not carry STAGE90_XNU_VM_MAX_SPLIT=1 -- this is not the 1024 arm, and that switch is what keeps the 1023 pthread storm away (the boot must reach launchctl to be a 1029 reading)"; exit 1; }
grep -q '^STAGE90_XNU_IOS7_TRAPS=1$' "$REC" || { echo "FAIL: $REC does not carry STAGE90_XNU_IOS7_TRAPS=1 -- this is not the 1023-derived arm (rows 15/24 must stay installed)"; exit 1; }
grep -q '^STAGE90_XNU_GENERAL_REGS=1$' "$REC" || { echo "FAIL: $REC does not carry STAGE90_XNU_GENERAL_REGS=1 -- 1021d's -msoft-float must be preserved (dropping it brings the kernel-mode NEON undef back)"; exit 1; }
grep -q '^STAGE90_XNU_UNDEF_RAISE=1$' "$REC" || { echo "FAIL: $REC does not carry STAGE90_XNU_UNDEF_RAISE=1 -- this is not the 1020b-derived arm"; exit 1; }
# **IDEMPOTENT RE-ENTRY.** This rung's own switch MAY already be in $REC: the record is the SHARED LIVE
# state ([[mi4-out-stage90-is-shared-live-state]]) and a prior run of THIS build (interrupted, or a
# re-run after a build-side fix) writes it. Refusing on that trace made the build UNRE-ENTRANT: the
# first attempt reached the entry layer, and every later attempt died here on its own output. The check
# that MATTERS is the seven `=1` pins above -- they prove $REC is the
# 1028/1027/1025/1024/1023/1021d/1020b lineage this rung carries; with all seven present, a
# pre-existing STAGE90_XNU_READER_PROBE is this build's own trace and is HARMLESS (the exporter appends
# the same `=1` again; the patcher's done-mark reports "already staged"). So we do NOT refuse on it.
# What we DO refuse -- the real half-on hazard -- is the switch present with a DIFFERENT value, which
# would mean a stale/foreign arm carrying a half-staged probe.
if grep -q '^STAGE90_XNU_READER_PROBE=' "$REC" && \
   ! grep -q '^STAGE90_XNU_READER_PROBE=1$' "$REC"; then
  echo "FAIL: $REC carries STAGE90_XNU_READER_PROBE with a value other than 1 -- a stale/foreign arm with a half-staged 1029 probe; rebuild from a clean 1028 record"; exit 1
fi
if grep -q '^STAGE90_XNU_READER_PROBE=1$' "$REC"; then
  echo "   note: $REC already carries STAGE90_XNU_READER_PROBE=1 (this build's own prior trace); re-entering idempotently"
fi

EXPORTS=()
while IFS= read -r line; do
  line=${line%%$'\r'}
  [[ -z $line || $line == \#* ]] && continue
  k=${line%%=*}; v=${line#*=}
  [[ $v == '(unset)' ]] && continue
  case $k in
    STAGE90_XNU_ENTRY_SHA256|STAGE90_XNU_ENTRY_BYTES) continue ;;   # outputs, not inputs
  esac
  EXPORTS+=("$k=$v")
done < "$REC"
EXPORTS+=("STAGE90_ENTRY_ARM_CHANGE=1")
EXPORTS+=("XNU_TREE=$XNU_TREE")
# **THIS RUNG'S ONE NEW SWITCH.**
EXPORTS+=("STAGE90_XNU_READER_PROBE=1")
echo "   carrying $(( ${#EXPORTS[@]} - 3 )) switch(es) from $REC + STAGE90_XNU_READER_PROBE=1"

# ---- the -D set (EXTRA == XNU_KERNEL_EXTRA_DEFINES) -------------------------------------------------
EXTRA=""
while IFS= read -r line; do
  line=${line%%$'\r'}
  [[ -z $line || $line == \#* ]] && continue
  k=${line%%=*}; v=${line#*=}
  [[ $v == '(unset)' ]] && continue
  case $k in
    STAGE90_XNU_ENTRY_SHA256|STAGE90_XNU_ENTRY_BYTES) continue ;;
    STAGE90_XNU_HFS_ROOT_RW) continue ;;                             # env-carried tree-layout define
    STAGE90_XNU_GENERAL_REGS) continue ;;                            # FLAG-carried switch, not a -D
    STAGE90_XNU_VM_MAX_SPLIT) continue ;;                            # GLOBAL DEFINES array, not EXTRA
    STAGE90_XNU_USTACK_PROBE) continue ;;                            # GLOBAL DEFINES array, not EXTRA
    STAGE90_XNU_ABT_ENTRY_PROBE) continue ;;                         # GLOBAL DEFINES array, not EXTRA
    STAGE90_XNU_H2_STACK_HEADROOM) continue ;;                       # GLOBAL DEFINES array, not EXTRA
    STAGE90_XNU_READER_PROBE) continue ;;                            # GLOBAL DEFINES array, not EXTRA
  esac
  [[ $k == STAGE90_* ]] || continue
  case $v in
    0|1) ;;
    0x*|[0-9]*) ;;
    *) continue ;;
  esac
  EXTRA="$EXTRA -D$k=$v"
done < "$REC"
# **1015b's GLOBAL-FIX TOKEN, WHICH HAS NO RECORD CARRIER** (records/1020-build-defect.txt).
EXTRA="$EXTRA -DSTAGE90_XNU_GLOBAL_FIX=1"
EXTRA=${EXTRA# }
echo "-- extra defines: $EXTRA --"
[[ "$EXTRA" != *"-DSTAGE90_XNU_VM_MAX_SPLIT"* ]] || { echo "FAIL: -DSTAGE90_XNU_VM_MAX_SPLIT is in EXTRA ('$EXTRA') -- its channel is the global DEFINES array"; exit 1; }
[[ "$EXTRA" != *"-DSTAGE90_XNU_USTACK_PROBE"* ]] || { echo "FAIL: -DSTAGE90_XNU_USTACK_PROBE is in EXTRA ('$EXTRA') -- its channel is the global DEFINES array"; exit 1; }
[[ "$EXTRA" != *"-DSTAGE90_XNU_ABT_ENTRY_PROBE"* ]] || { echo "FAIL: -DSTAGE90_XNU_ABT_ENTRY_PROBE is in EXTRA ('$EXTRA') -- its channel is the global DEFINES array"; exit 1; }
[[ "$EXTRA" != *"-DSTAGE90_XNU_H2_STACK_HEADROOM"* ]] || { echo "FAIL: -DSTAGE90_XNU_H2_STACK_HEADROOM is in EXTRA ('$EXTRA') -- its channel is the global DEFINES array"; exit 1; }
[[ "$EXTRA" != *"-DSTAGE90_XNU_READER_PROBE"* ]] || { echo "FAIL: -DSTAGE90_XNU_READER_PROBE is in EXTRA ('$EXTRA') -- its channel is the global DEFINES array"; exit 1; }

# ====================================================================================================
# 2. STAGE THE TREE EDITS.  ALL FIVE trap.c rungs + kern_exec.c's three prior blocks in order, then THIS
#    rung's reader probe (which is a block in BOTH files).
# ====================================================================================================
echo "-- stage the tree edits (1021d/1022/1023/1024/1025/1026/1028's set must already be staged, then 1029's probe) --"
python3 tools/patch_d13_ios7_vmwire.py "$XNU_TREE" >/dev/null || { echo "FAIL: tools/patch_d13_ios7_vmwire.py refused or failed -- the tree is not in the state this rung was written against (run build_1025.sh first)"; exit 1; }
python3 tools/patch_d13_mach_trap15.py "$XNU_TREE" >/dev/null || { echo "FAIL: tools/patch_d13_mach_trap15.py refused - 1022's widenings are not staged"; exit 1; }
python3 tools/patch_d13_mach_trap15.py "$XNU_TREE" --apply >/dev/null || { echo "FAIL: tools/patch_d13_mach_trap15.py --apply failed"; exit 1; }
python3 tools/patch_d13_mach_trap_ports.py "$XNU_TREE" >/dev/null || { echo "FAIL: tools/patch_d13_mach_trap_ports.py refused - 1023's row-24 edits are not staged"; exit 1; }
python3 tools/patch_d13_mach_trap_ports.py "$XNU_TREE" --apply >/dev/null || { echo "FAIL: tools/patch_d13_mach_trap_ports.py --apply failed"; exit 1; }
python3 tools/patch_d13_mach_trap_ports.py "$XNU_TREE" --apply >/dev/null || { echo "FAIL: a second --apply of tools/patch_d13_mach_trap_ports.py did not succeed"; exit 1; }
python3 tools/patch_d13_mach_trap_ports.py "$XNU_TREE" --verify-off >/dev/null || { echo "FAIL: tools/patch_d13_mach_trap_ports.py --verify-off did not PASS on the staged tree"; exit 1; }
python3 tools/patch_d13_mach_trap15.py "$XNU_TREE" >/dev/null || { echo "FAIL: after the staged set, tools/patch_d13_mach_trap15.py REFUSES the tree - the composition fix is not in effect"; exit 1; }
# 1024's header edit (must be staged; this rung ADDS to it, does not re-do it).
python3 tools/patch_d13_vm_max_split.py "$XNU_TREE" >/dev/null || { echo "FAIL: tools/patch_d13_vm_max_split.py refused - 1024's vm_param.h ceiling edit is not staged"; exit 1; }
python3 tools/patch_d13_vm_max_split.py "$XNU_TREE" --apply >/dev/null || { echo "FAIL: a second --apply of tools/patch_d13_vm_max_split.py did not succeed"; exit 1; }
python3 tools/patch_d13_vm_max_split.py "$XNU_TREE" --verify-off >/dev/null || { echo "FAIL: tools/patch_d13_vm_max_split.py --verify-off did not PASS"; exit 1; }
# ---- 1020's udf-raise fix (SAME file as 1025/1026's trap.c edits) --------------------------------
# It MUST be re-staged HERE, not assumed: a bare `git checkout -- osfmk/arm/trap.c` between rungs
# reverts it silently while leaving 1025/1026's publishers intact, and then the linked image's
# `sleh_undef` misses the raise and the INHERITED check_d13_undef_raise refuses the build AFTER the
# pool compile ([[mi4-one-file-many-rungs]]).  Its ALLOWED_IF_IDENTIFIERS carries both probe switches
# so the edits are allowed to coexist in one file.
python3 tools/patch_d13_undef_raise.py "$XNU_TREE" >/dev/null || { echo "FAIL: tools/patch_d13_undef_raise.py (plan) refused - 1020's udf-raise fix is not staged in trap.c"; exit 1; }
python3 tools/patch_d13_undef_raise.py "$XNU_TREE" --verify-off >/dev/null || { echo "FAIL: tools/patch_d13_undef_raise.py --verify-off did not PASS with 1025/1026's probes in the same file - the edits do not compose"; exit 1; }
# ---- 994's dyld witness (the THIRD edit in the same file, trap.c's `sleh_undef`) ------------------
python3 tools/patch_d13_dyld_witness.py "$XNU_TREE" >/dev/null || { echo "FAIL: tools/patch_d13_dyld_witness.py (plan) refused - 994's witness block is not staged in trap.c"; exit 1; }
python3 tools/patch_d13_dyld_witness.py "$XNU_TREE" --verify-off >/dev/null || { echo "FAIL: tools/patch_d13_dyld_witness.py --verify-off did not PASS with 1025/1026's probes in the same file - the edits do not compose"; exit 1; }
# ---- 1025's probe (SAME file; 1026's block is NESTED inside it) -----------------------------------
# Re-staged so the parent block is present before 1026's child lands inside it.
python3 tools/patch_d13_ustack_probe.py "$XNU_TREE" >/dev/null || { echo "FAIL: tools/patch_d13_ustack_probe.py (plan) refused - 1025's publishers are not staged in trap.c/kern_exec.c"; exit 1; }
python3 tools/patch_d13_ustack_probe.py "$XNU_TREE" --apply >/dev/null || { echo "FAIL: tools/patch_d13_ustack_probe.py --apply failed"; exit 1; }
python3 tools/patch_d13_ustack_probe.py "$XNU_TREE" --apply >/dev/null || { echo "FAIL: a second --apply of tools/patch_d13_ustack_probe.py did not succeed"; exit 1; }
python3 tools/patch_d13_ustack_probe.py "$XNU_TREE" --verify-off >/dev/null || { echo "FAIL: tools/patch_d13_ustack_probe.py --verify-off did not PASS - the ON/OFF shapes are not the ones this rung declares"; exit 1; }
# ---- 1026: THE ABORT-ENTRY DISCRIMINATOR (re-staged; 1028's edit is a CHILD of it in kern_exec.c) --
echo "-- tools/patch_d13_abt_entry_probe.py (1027: trap.c discriminator nested in 1025's block + kern_exec.c accessor) --"
python3 tools/patch_d13_abt_entry_probe.py "$XNU_TREE" || { echo "FAIL: tools/patch_d13_abt_entry_probe.py (plan mode) refused - the tree is not in the state this rung was written against. It writes nothing on a refusal"; exit 1; }
python3 tools/patch_d13_abt_entry_probe.py "$XNU_TREE" --apply || { echo "FAIL: tools/patch_d13_abt_entry_probe.py --apply refused"; exit 1; }
python3 tools/patch_d13_abt_entry_probe.py "$XNU_TREE" --apply >/dev/null || { echo "FAIL: a second --apply of tools/patch_d13_abt_entry_probe.py did not succeed (the idempotent no-op)"; exit 1; }
python3 tools/patch_d13_abt_entry_probe.py "$XNU_TREE" --verify-off >/dev/null || { echo "FAIL: tools/patch_d13_abt_entry_probe.py --verify-off did not PASS - the ON/OFF shapes are not the ones this rung declares ([[mi4-off-option-two-spellings]])"; exit 1; }
# ---- 1028: THE H2 FIX (the THIRD kern_exec.c block; a SIBLING of 1025/1026's, not nested in trap.c) --
echo "-- tools/patch_d13_h2_stack_headroom.py (1028: create_unix_stack's FIXED mach_vm_allocate extent = size + 16) --"
python3 tools/patch_d13_h2_stack_headroom.py "$XNU_TREE" || { echo "FAIL: tools/patch_d13_h2_stack_headroom.py (plan mode) refused - the tree is not in the state this rung was written against. It writes nothing on a refusal"; exit 1; }
python3 tools/patch_d13_h2_stack_headroom.py "$XNU_TREE" --apply || { echo "FAIL: tools/patch_d13_h2_stack_headroom.py --apply refused"; exit 1; }
python3 tools/patch_d13_h2_stack_headroom.py "$XNU_TREE" --apply >/dev/null || { echo "FAIL: a second --apply of tools/patch_d13_h2_stack_headroom.py did not succeed (the idempotent no-op)"; exit 1; }
python3 tools/patch_d13_h2_stack_headroom.py "$XNU_TREE" --verify-off >/dev/null || { echo "FAIL: tools/patch_d13_h2_stack_headroom.py --verify-off did not PASS - the OFF arm does not reproduce the original mach_vm_allocate ([[mi4-off-option-two-spellings]])"; exit 1; }
# ---- 1029: THE READER PROBE (a block in BOTH files: trap.c's rows INSIDE 1025's publisher + AFTER
#      1026/1027's block, and kern_exec.c's accessors after the 1026 accessor) ----------------------
echo "-- tools/patch_d13_reader_probe.py (1029: trap.c xnu_live_rdr_* rows + kern_exec.c xnu_live_rdr_proc_* accessors) --"
python3 tools/patch_d13_reader_probe.py "$XNU_TREE" || { echo "FAIL: tools/patch_d13_reader_probe.py (plan mode) refused - the tree is not in the state this rung was written against. It writes nothing on a refusal"; exit 1; }
python3 tools/patch_d13_reader_probe.py "$XNU_TREE" --apply || { echo "FAIL: tools/patch_d13_reader_probe.py --apply refused"; exit 1; }
python3 tools/patch_d13_reader_probe.py "$XNU_TREE" --apply >/dev/null || { echo "FAIL: a second --apply of tools/patch_d13_reader_probe.py did not succeed (the idempotent no-op)"; exit 1; }
python3 tools/patch_d13_reader_probe.py "$XNU_TREE" --verify-off >/dev/null || { echo "FAIL: tools/patch_d13_reader_probe.py --verify-off did not PASS - the OFF arm does not reproduce the 1028 tree bytes ([[mi4-off-option-two-spellings]])"; exit 1; }
# ---- after 1026+1028+1029 land, the SIX inherited patchers must still accept the composed tree -------
python3 tools/patch_d13_ustack_probe.py "$XNU_TREE" >/dev/null || { echo "FAIL: after 1026/1028/1029 are staged, tools/patch_d13_ustack_probe.py REFUSES trap.c - the shared namespace is not in effect ([[mi4-one-file-many-rungs]])"; exit 1; }
python3 tools/patch_d13_undef_raise.py "$XNU_TREE" >/dev/null || { echo "FAIL: after 1026/1028/1029 are staged, tools/patch_d13_undef_raise.py REFUSES trap.c - the shared namespace is not in effect"; exit 1; }
python3 tools/patch_d13_dyld_witness.py "$XNU_TREE" >/dev/null || { echo "FAIL: after 1026/1028/1029 are staged, tools/patch_d13_dyld_witness.py REFUSES trap.c - the shared namespace is not in effect"; exit 1; }
python3 tools/patch_d13_abt_entry_probe.py "$XNU_TREE" >/dev/null || { echo "FAIL: a third plan-mode run of tools/patch_d13_abt_entry_probe.py refused - its own idempotency is not stable"; exit 1; }
python3 tools/patch_d13_h2_stack_headroom.py "$XNU_TREE" >/dev/null || { echo "FAIL: after 1029 is staged, tools/patch_d13_h2_stack_headroom.py REFUSES kern_exec.c - the shared namespace is not in effect"; exit 1; }
python3 tools/patch_d13_reader_probe.py "$XNU_TREE" >/dev/null || { echo "FAIL: a third plan-mode run of tools/patch_d13_reader_probe.py refused - its own idempotency is not stable"; exit 1; }
# The staged bytes themselves: exactly ONE of each gate line, and 1026's block INSIDE 1025's.  (1028's
# kern_exec.c fix has its own counts added after the abt_entry_probe accessor's.)
[[ $(grep -c 'xnu_live_abt_vmfkrv=' "$XNU_TREE/osfmk/arm/trap.c") == 1 ]] || { echo "FAIL: $XNU_TREE/osfmk/arm/trap.c does not carry EXACTLY 1 xnu_live_abt_vmfkrv= line - a partial or double edit"; exit 1; }
[[ $(grep -c 'xnu_live_abt_lookup_far=' "$XNU_TREE/osfmk/arm/trap.c") == 1 ]] || { echo "FAIL: $XNU_TREE/osfmk/arm/trap.c does not carry EXACTLY 1 xnu_live_abt_lookup_far= line - a partial or double edit"; exit 1; }
[[ $(grep -c 'xnu_live_abt_proc_ustack' "$XNU_TREE/bsd/kern/kern_exec.c") == 1 ]] || { echo "FAIL: $XNU_TREE/bsd/kern/kern_exec.c does not carry EXACTLY 1 xnu_live_abt_proc_ustack - a partial or double edit"; exit 1; }
# **1028's own staged bytes on kern_exec.c: EXACTLY 1 switch gate, EXACTLY 1 `size + 16` extent, and the
# `#else` arm carrying the ORIGINAL `size` call.**  The fix prints nothing, so these TEXT counts are the
# staged-tree half of the by-value evidence (the pool half is step 5a's source-carries-switch + rebuild).
[[ $(grep -c 'STAGE90_XNU_H2_STACK_HEADROOM' "$XNU_TREE/bsd/kern/kern_exec.c") -ge 1 ]] || { echo "FAIL: $XNU_TREE/bsd/kern/kern_exec.c carries NO STAGE90_XNU_H2_STACK_HEADROOM - the H2 fix is not staged (a partial/refused edit)"; exit 1; }
[[ $(grep -c 'mach_vm_allocate(map, &addr, size + 16,' "$XNU_TREE/bsd/kern/kern_exec.c") == 1 ]] || { echo "FAIL: $XNU_TREE/bsd/kern/kern_exec.c does not carry EXACTLY 1 \`size + 16\` FIXED mach_vm_allocate - a partial or double edit of the H2 fix"; exit 1; }
[[ $(grep -c '^#endif /\* STAGE90_XNU_H2_STACK_HEADROOM \*/' "$XNU_TREE/bsd/kern/kern_exec.c") == 1 ]] || { echo "FAIL: $XNU_TREE/bsd/kern/kern_exec.c does not carry EXACTLY 1 \`#endif /* STAGE90_XNU_H2_STACK_HEADROOM */\` marker - the ON/OFF gate is not bracketed"; exit 1; }
# **1029's own staged bytes: EXACTLY 1 row publisher in trap.c, EXACTLY 1 accessor in kern_exec.c, and ONE
# bracketing `#endif` per file.**  These are the staged-tree half of the by-value evidence; the OBJECT half
# is step 5a's `strings` fingerprints (this rung DOES print, so unlike 1028 it has them).
[[ $(grep -c 'xnu_live_rdr_far=' "$XNU_TREE/osfmk/arm/trap.c") == 1 ]] || { echo "FAIL: $XNU_TREE/osfmk/arm/trap.c does not carry EXACTLY 1 xnu_live_rdr_far= line - a partial or double edit of the reader probe"; exit 1; }
[[ $(grep -c '^#endif /\* STAGE90_XNU_READER_PROBE \*/' "$XNU_TREE/osfmk/arm/trap.c") == 1 ]] || { echo "FAIL: $XNU_TREE/osfmk/arm/trap.c does not carry EXACTLY 1 \`#endif /* STAGE90_XNU_READER_PROBE */\` marker - Site A's ON/OFF gate is not bracketed"; exit 1; }
[[ $(grep -c 'xnu_live_rdr_proc_argslen' "$XNU_TREE/bsd/kern/kern_exec.c") -ge 1 ]] || { echo "FAIL: $XNU_TREE/bsd/kern/kern_exec.c carries NO xnu_live_rdr_proc_argslen - Site B's accessor is not staged"; exit 1; }
[[ $(grep -c '^#endif /\* STAGE90_XNU_READER_PROBE \*/' "$XNU_TREE/bsd/kern/kern_exec.c") == 1 ]] || { echo "FAIL: $XNU_TREE/bsd/kern/kern_exec.c does not carry EXACTLY 1 \`#endif /* STAGE90_XNU_READER_PROBE */\` marker - Site B's ON/OFF gate is not bracketed"; exit 1; }
# 1026's gate must sit INSIDE 1025's (ONE gate on the shared fault path): the 1025 `#endif` must come
# strictly AFTER the 1026 `#endif`.  1029's `#endif` must sit BETWEEN the two -- INSIDE 1025's publisher,
# AFTER 1026/1027's block (the 1029 patcher's own `--verify-off` asserts the same boundary).
_abt_105=$(grep -n '^#endif /\* STAGE90_XNU_USTACK_PROBE \*/' "$XNU_TREE/osfmk/arm/trap.c" | head -1 | cut -d: -f1)
_abt_106=$(grep -n '^#endif /\* STAGE90_XNU_ABT_ENTRY_PROBE \*/' "$XNU_TREE/osfmk/arm/trap.c" | head -1 | cut -d: -f1)
_abt_109=$(grep -n '^#endif /\* STAGE90_XNU_READER_PROBE \*/' "$XNU_TREE/osfmk/arm/trap.c" | head -1 | cut -d: -f1)
[[ -n $_abt_105 && -n $_abt_106 && $_abt_106 -lt $_abt_105 ]] || { echo "FAIL: 1026's gate is NOT nested inside 1025's (1026 #endif line=$_abt_106 must precede 1025 #endif line=$_abt_105). The discriminator must be INSIDE the shared fault-path gate, not a second competing block"; exit 1; }
[[ -n $_abt_109 && $_abt_106 -lt $_abt_109 && $_abt_109 -lt $_abt_105 ]] || { echo "FAIL: 1029's gate is NOT between its two parents (line=$_abt_109 must satisfy 1026 #endif=$_abt_106 < 1029 #endif < 1025 #endif=$_abt_105). Site A's rows must sit INSIDE the shared fault-path gate (or they never execute) AND OUTSIDE 1026/1027's block (or they are gated on the wrong switch)"; exit 1; }
echo "   POOL: the staged trap.c/kern_exec.c carry the discriminator NESTED inside 1025's block, AND 1028's H2 fix (size + 16), AND 1029's reader probe bracketed between them, every file's OFF/ON proofs PASS, the inherited set still composes"

# ====================================================================================================
# 3. Export the pool switches (1027's set VERBATIM) + THIS rung's switch, BEFORE the pool build.
# ====================================================================================================
echo "-- exporting 1027's pool switch set, unchanged --"
export STAGE90_XNU_HFS=1
export STAGE90_XNU_SP_ALIGN=1
export STAGE90_XNU_IOS7_TRAPS=1
export STAGE90_XNU_RESIDENT=1
export STAGE90_XNU_USVC=1
export STAGE90_XNU_VMHINT_GUARD=1
export STAGE90_XNU_SUBMAP_PMAP_SKIP=1
export STAGE90_XNU_COMMPAGE_ALIAS=1
export STAGE90_XNU_DYLD_WITNESS=1
export STAGE90_XNU_SHREG_PROBE=1
export STAGE90_XNU_SHREG_WIRE=1
export STAGE90_XNU_SHREG_GEOM=1
export STAGE90_XNU_STALL=1
export STAGE90_XNU_CADENCE=1
export STAGE90_XNU_FLUSH_WITNESS=1
export STAGE90_XNU_KEXTB_LOGIN=1
export STAGE90_XNU_UNDEF_RAISE=1
export STAGE90_XNU_GENERAL_REGS=1
export STAGE90_XNU_VM_MAX_SPLIT=1
export STAGE90_XNU_USTACK_PROBE=1
# 1027's discriminator, carried VERBATIM: its xnu_live_abt_* rows are the PARENT CELLS 1029's reading is
# adjudicated BESIDE (FAULT-NAMED must still fire), and 1028's kern_exec.c fix is a SIBLING block in the
# same file.  Dropping it would silently un-build the by-value rows the 1029 reading is read against
# ([[mi4-build-variant-comes-from-an-env-default]]).
export STAGE90_XNU_ABT_ENTRY_PROBE=1
# 1028's H2 fix, carried VERBATIM: it is the INSTRUMENT that produced this rung's premise (the fault MOVED
# to `far = ustack + 0x1000` when the region grew a page).  Reverting it would put the fault back at the
# region top and 1029 would be measuring a DIFFERENT geometry than the one the design adjudicates.
export STAGE90_XNU_H2_STACK_HEADROOM=1
# **THIS RUNG'S SWITCH, CHANNEL 1: the env variable tools/build_xnu_arm_kernel.sh reads into the global
# DEFINES array.**  Without the export the pool objects keep the UNINSTRUMENTED trap.c/kern_exec.c while
# the record says 1.
export STAGE90_XNU_READER_PROBE=1
echo "-- STAGE90_XNU_READER_PROBE=$STAGE90_XNU_READER_PROBE STAGE90_XNU_H2_STACK_HEADROOM=$STAGE90_XNU_H2_STACK_HEADROOM STAGE90_XNU_ABT_ENTRY_PROBE=$STAGE90_XNU_ABT_ENTRY_PROBE STAGE90_XNU_USTACK_PROBE=$STAGE90_XNU_USTACK_PROBE STAGE90_XNU_VM_MAX_SPLIT=$STAGE90_XNU_VM_MAX_SPLIT STAGE90_XNU_IOS7_TRAPS=$STAGE90_XNU_IOS7_TRAPS STAGE90_XNU_GENERAL_REGS=$STAGE90_XNU_GENERAL_REGS STAGE90_XNU_UNDEF_RAISE=$STAGE90_XNU_UNDEF_RAISE (pool DEFINES + FP flag list + asm ASFLAGS + EXTRA agree) --"
export STAGE90_XNU_HFS_ROOT_RW=$(awk -F= '$1=="STAGE90_XNU_HFS_ROOT_RW"{print $2}' "$REC")
echo "-- STAGE90_XNU_HFS_ROOT_RW=$STAGE90_XNU_HFS_ROOT_RW (the pool's hfs_vfsops.o carries the rw clear) --"
[[ -n ${STAGE90_XNU_READER_PROBE:-} ]] || { echo "FAIL: STAGE90_XNU_READER_PROBE is not exported - tools/build_xnu_arm_kernel.sh reads that ENV variable into the global DEFINES array"; exit 1; }
[[ -n ${STAGE90_XNU_H2_STACK_HEADROOM:-} ]] || { echo "FAIL: STAGE90_XNU_H2_STACK_HEADROOM is not exported - 1029 carries 1028's H2 fix (the geometry this rung names)"; exit 1; }
[[ -n ${STAGE90_XNU_ABT_ENTRY_PROBE:-} ]] || { echo "FAIL: STAGE90_XNU_ABT_ENTRY_PROBE is not exported - 1029 carries 1027's discriminator as its parent cells, and 1026's block is NESTED inside 1025's"; exit 1; }
[[ -n ${STAGE90_XNU_USTACK_PROBE:-} ]] || { echo "FAIL: STAGE90_XNU_USTACK_PROBE is not exported - 1029's Site A rows are NESTED inside 1025's publisher, so they print nothing without it"; exit 1; }
[[ "$EXTRA" == *"-DSTAGE90_XNU_GLOBAL_FIX=1"* ]] || { echo "FAIL: -DSTAGE90_XNU_GLOBAL_FIX=1 is NOT in EXTRA - 1015b's fix has NO record carrier; without it the retry storm returns"; exit 1; }

# 4. The asm layer.  1029 touches NO asm file.
echo "-- arm asm layer (1029 touches NO .s file) --"
XNU_TREE="$XNU_TREE" XNU_KERNEL_CONFIG=STAGE90_XNU tools/assemble_arm_layer.sh

# 5. The POOL build -- trap.c/kern_exec.c are POOL objects, so the pool MUST be rebuilt.
echo "-- the D13 kernel pool + platform block, recompiled (trap.o AND kern_exec.o move) --"
if [[ -n $RESUME_LOG ]]; then
  echo "   RESUME: SKIPPING the pool rebuild."
else
  XNU_TREE="$XNU_TREE" \
  XNU_KERNEL_CONFIG=STAGE90_XNU \
  XNU_MASTER_LOCAL="$PWD/tools/xnu_config/boot/STAGE90_XNU.local" \
  XNU_KERNEL_EXTRA_DEFINES="$EXTRA" \
      ./tools/build_xnu_arm_kernel.sh
fi

# ====================================================================================================
# 5a. THE OBJECT-SIDE ASSERTIONS.  The INHERITED 1025/1026/1027 fingerprints AND THIS RUNG'S OWN are
#     FORMAT STRINGS read by `strings`.  THE PIPE-ARGUMENT FORM IS REQUIRED: `strings X | grep -q P`
#     under `set -o pipefail` returns 141 (SIGPIPE) when the string IS present, because grep exits early
#     and strings dies on the write - a gate that is fail-closed but UNPASSABLE
#     ([[mi4-mutation-anchors-are-code-spans]] instance m1025).  Use `grep -qa P <(strings X)`.
#     **1029 DOES print** (unlike 1028's value-only fix), so it has a REAL `strings` fingerprint in the
#     object: `xnu_live_rdr_far=` in trap.o and the `xnu_live_rdr_proc_argslen` symbol in kern_exec.o.
#     1028's OWN stringless gate (staged `size + 16` + the pool's source-content sha256) is KEPT below,
#     because with 1028's switch still =1 the fixed extent must still be in this pool.
# ====================================================================================================
echo "-- POOL(5a): the two objects where the discriminator lives --"
[[ -f $TRAP_OBJ ]] || { echo "FAIL: $TRAP_OBJ is absent - the pool build did not produce trap.o"; exit 1; }
[[ -f $EXEC_OBJ ]] || { echo "FAIL: $EXEC_OBJ is absent - the pool build did not produce kern_exec.o"; exit 1; }
_t=$(strings "$TRAP_OBJ" | grep -c '^xnu_live_abt_lookup_far=' || true)
_e=$(strings "$EXEC_OBJ" | grep -c '^xnu_live_abt_proc_ustack$' || true)
# **1027'S OWN NEW FINGERPRINT: the far-4 entry's bounds.**  Without these two strings the H2 cell's
# `e2_hi == far` conjunct is UNREADABLE (the exact 1026 defect this rung fixes), so a trap.o lacking
# them is a 1026 pool object masquerading as 1027's - refuse.
_f2=$(strings "$TRAP_OBJ" | grep -c '^xnu_live_abt_e2_hi=' || true)
# **1029'S OWN FINGERPRINT.**  Site A publishes `xnu_live_rdr_far=` on the failing path; Site B's
# accessor `xnu_live_rdr_proc_argslen` is a SYMBOL.  A pool object without them was NOT recompiled with
# STAGE90_XNU_READER_PROBE=1 (the env -> global DEFINES channel of build_xnu_arm_kernel.sh) or the 1029
# edit is not staged -- and the press would capture NOTHING on the fault this rung exists to name.
_rd=$(strings "$TRAP_OBJ" | grep -c '^xnu_live_rdr_far=' || true)
[[ "$_t" -ge 1 ]] || { echo "FAIL: $TRAP_OBJ carries NO xnu_live_abt_lookup_far= publisher - the pool was NOT recompiled with STAGE90_XNU_ABT_ENTRY_PROBE=1 (env channel) or the trap.c edit is not staged"; exit 1; }
[[ "$_f2" -ge 1 ]] || { echo "FAIL: $TRAP_OBJ carries NO xnu_live_abt_e2_hi= publisher - this is a 1026 SHAPE pool object (entry_hi suppressed in the H2 case, e2 never printed), so the H2 cell would AGAIN be unsatisfiable and the press would read H-OTHER for a second time. The 1027 amendment to tools/patch_d13_abt_entry_probe.py did not reach the object"; exit 1; }
[[ "$_e" -ge 1 ]] || { echo "FAIL: $EXEC_OBJ carries NO xnu_live_abt_proc_ustack symbol - the pool was NOT recompiled with STAGE90_XNU_ABT_ENTRY_PROBE=1 or the kern_exec.c edit is not staged"; exit 1; }
[[ "$_rd" -ge 1 ]] || { echo "FAIL: $TRAP_OBJ carries NO xnu_live_rdr_far= publisher - the pool was NOT recompiled with STAGE90_XNU_READER_PROBE=1 (the env -> global DEFINES channel) or Site A's trap.c edit is not staged. Without this string the press captures NOTHING and 1029 reads G-CTL instead of a cell"; exit 1; }
grep -qa '^xnu_live_rdr_proc_argslen$' <(strings "$EXEC_OBJ") || { echo "FAIL: $EXEC_OBJ carries NO xnu_live_rdr_proc_argslen symbol - Site B's kern_exec.c accessor is not in the pool object, so Site A would fail to LINK (or the stale object would carry the old text)"; exit 1; }
echo "   POOL(5a): trap.o carries xnu_live_abt_lookup_far= (x$_t) AND xnu_live_abt_e2_hi= (x$_f2) publishers AND 1029's xnu_live_rdr_far= (x$_rd), kern_exec.o carries xnu_live_abt_proc_ustack (x$_e) AND xnu_live_rdr_proc_argslen"
# The 1025 publishers must STILL be there (this rung rebuilds the whole pool with 1025's set).
grep -qa '^xnu_live_abt_vmfkrv=' <(strings "$TRAP_OBJ") || { echo "FAIL: $TRAP_OBJ lost 1025's xnu_live_abt_vmfkrv= publisher - the pool rebuild dropped 1025's switch"; exit 1; }
grep -qa '^xnu_live_ustack_req=' <(strings "$EXEC_OBJ") || { echo "FAIL: $EXEC_OBJ lost 1025's xnu_live_ustack_req= publisher - the pool rebuild dropped 1025's switch"; exit 1; }
echo "   POOL(5a): 1025's publishers survive (trap.o has xnu_live_abt_vmfkrv=, kern_exec.o has xnu_live_ustack_req=)"

# **1028'S OWN OBJECT-SIDE GATE.**  The H2 fix is a VALUE change (`size` -> `size + 16`), so it has NO
# format string and NO `strings` fingerprint -- a gate that looked for one would be inventing evidence
# that cannot exist ([[mi4-a-claim-in-a-comment-is-not-a-check]]).  The honest pair is:
#   (i)  the STAGED kern_exec.c carries the switch, the `size + 16` extent, and the gate's `#endif`; and
#   (ii) the POOL compiled THAT content -- the pool's own source-content record names kern_exec.c's
#        sha256, and it must equal the staged file's.  Without (ii) a record saying 1 could sit over a
#        pool object built from an OLD kern_exec.c (the records/1020-build-defect.txt shape).
_ke_src=$XNU_TREE/bsd/kern/kern_exec.c
_src_rec=out/xnu_kernel_src_d13.sha256
[[ -f $_ke_src ]] || { echo "FAIL: $_ke_src is absent - the staged kern_exec.c this gate reads is not on disk"; exit 1; }
grep -q 'STAGE90_XNU_H2_STACK_HEADROOM' "$_ke_src" || { echo "FAIL: the staged $_ke_src carries NO STAGE90_XNU_H2_STACK_HEADROOM - the H2 fix was not staged before the pool build, so the pool compiled the UNFIXED create_unix_stack"; exit 1; }
[[ -s $_src_rec ]] || { echo "FAIL: $_src_rec is absent - it is the pool's own source-content record, the independent read that the pool compiled THIS kern_exec.c. A gate that cannot read it cannot tell a fixed object from a stale one"; exit 1; }
_ke_want=$(sha256sum "$_ke_src" | awk '{print $1}')
_ke_have=$(awk -v p="$_ke_src" '$2==p{print $1}' "$_src_rec" | head -1)
[[ -n $_ke_have ]] || { echo "FAIL: $_src_rec names no content hash for $_ke_src - the pool's manifest does not include kern_exec.c, so the rebuild cannot be certified"; exit 1; }
[[ "$_ke_want" == "$_ke_have" ]] || { echo "FAIL: $_src_rec's kern_exec.c hash ($_ke_have) != the staged file's ($_ke_want) - the pool was NOT rebuilt from the staged kern_exec.c (a stale bsd_kern_kern_exec.o the linker would still LINK). The record would say STAGE90_XNU_H2_STACK_HEADROOM=1 over an object built from the UNFIXED source. Re-run the pool rebuild"; exit 1; }
echo "   POOL(5a): 1028's H2 fix is in the pool's OWN source record - kern_exec.c content sha256 matches the staged file (the pool compiled the fixed source; no strings fingerprint exists for a value change)"

# The inherited GLOBAL-FIX (1015b) is still in the pool object (this rung rebuilds the whole pool).
gf_obj=$POOL/osfmk_arm_pmap.o
[[ -f $gf_obj ]] || { echo "FAIL: $gf_obj is absent"; exit 1; }
_gf_kp=$(arm-none-eabi-objdump -r "$gf_obj" 2>/dev/null | awk '$1>="00000418" && $1<="00000640"' | grep -c 'MOVW_ABS_NC.*kernel_pmap' || true)
[[ "$_gf_kp" == "3" ]] || { echo "FAIL: pmap_flush_tlbs materializes kernel_pmap at $_gf_kp site(s), want EXACTLY 3 -- 1015b's GLOBAL_FIX is NOT in this pool object, so the retry storm is BACK and the run would never reach launchctl. -DSTAGE90_XNU_GLOBAL_FIX=1 rides XNU_KERNEL_EXTRA_DEFINES ONLY"; exit 1; }
echo "   POOL(5a): pmap_flush_tlbs carries the 3rd kernel_pmap materialization (1015b's GLOBAL-FIX is IN this object)"

# The 1024 ceiling is still in the pool (this rung rebuilds the whole pool with 1024's set).
TASK_OBJ=$POOL/osfmk_kern_task.o
[[ -f $TASK_OBJ ]] || { echo "FAIL: $TASK_OBJ is absent"; exit 1; }
python3 tools/check_vm_max_split.py "$TASK_OBJ" --expect on >/dev/null || { echo "FAIL: $TASK_OBJ's task_create_internal does NOT pass 0x40000000 to vm_map_create - 1024's ceiling is not in this pool"; exit 1; }
echo "   POOL(5a): task.o still carries the 0x40000000 ceiling (1024's switch survived the rebuild)"

# ====================================================================================================
# 6. The ENTRY link.  build_entry.sh LINKS the pool objects and runs its OWN clauses (1025's reads
#    kern_exec.o by value; 1028's switch rides the record and the pool's source-content record).
# ====================================================================================================
echo "-- entry link (build_entry.sh LINKS the pool objects; its clauses refuse a record over a stale pool) --"
( cd src/entry && env -i PATH="$PATH" HOME="$HOME" "${EXPORTS[@]}" ./build_entry.sh )

# 6b. The by-value clauses on the LINKED image, before the payload is embedded.
echo "-- by value (6b): the LINKED image still carries 1024's ceiling + 1023's row 24, AND 1029's reader rows --"
python3 tools/check_vm_max_split.py "$ELF" --expect on >/dev/null || { echo "FAIL: the LINKED image's task map ceiling is not 0x40000000"; exit 1; }
python3 tools/check_1023_trap24.py "$ELF" --expect on >/dev/null || { echo "FAIL: the LINKED image's mach_trap_table[24] moved - 1029 must ADD nothing but the reader rows"; exit 1; }
echo "   6b PASS: the linked image's ceiling reads 0x40000000 and row 24 is untouched"
# 1028's fix has no string, so the LINKED-image clause here reads the SOURCE staged state -- build_entry.sh
# relinked the ELF from the pool objects this build produced, and step 5a certified the pool compiled the
# staged kern_exec.c.
grep -q 'STAGE90_XNU_H2_STACK_HEADROOM' "$XNU_TREE/bsd/kern/kern_exec.c" || { echo "FAIL: the staged kern_exec.c does not carry STAGE90_XNU_H2_STACK_HEADROOM at the link site - the H2 fix is not in the tree this image was linked from"; exit 1; }
[[ $(grep -c 'mach_vm_allocate(map, &addr, size + 16,' "$XNU_TREE/bsd/kern/kern_exec.c") == 1 ]] || { echo "FAIL: the staged kern_exec.c does not carry EXACTLY 1 \`size + 16\` FIXED mach_vm_allocate at the link site"; exit 1; }
echo "   6b PASS: xnu_entry_1028 - the staged bsd/kern/kern_exec.c carries STAGE90_XNU_H2_STACK_HEADROOM with the FIXED extent = size + 16"
# **1029'S OWN LINKED-IMAGE CLAUSE.**  The reader probe PRINTS, so -- unlike 1028 -- it has a real
# `strings` fingerprint, and the linked image is where the press's capture comes from: an object the
# linker DROPPED would leave the arm's claim unmet.  `grep -qa P <(strings X)` NOT `strings X | grep -q P`
# (pipefail/SIGPIPE = 141 - m1025).  Read the OBJECTS first (the edit's home), then the ELF.
grep -qa '^xnu_live_rdr_far=' <(strings "$TRAP_OBJ") || { echo "FAIL: $TRAP_OBJ carries NO xnu_live_rdr_far= publisher at the link site"; exit 1; }
grep -qa '^xnu_live_rdr_far=' <(strings "$ELF") || { echo "FAIL: the LINKED image carries NO xnu_live_rdr_far= string - Site A's rows did not reach the image the press boots. The press would capture nothing on the launchctl fault and 1029 would read G-CTL for a reason that is not the device's"; exit 1; }
grep -qa 'xnu_live_rdr_proc_argslen' <(strings "$EXEC_OBJ") || { echo "FAIL: $EXEC_OBJ carries NO xnu_live_rdr_proc_argslen symbol at the link site"; exit 1; }
echo "   6b PASS: xnu_entry_1029 - the LINKED image carries 1029's xnu_live_rdr_far= publisher (trap.o) and kern_exec.o carries xnu_live_rdr_proc_argslen"
# THIS rung's INHERITED keys ARE in the linked image too: the format strings + the accessor symbol must be
# reachable beside the new rows (1029's reading is adjudicated BESIDE the 1025/1026/1027 parent cells).
grep -qa '^xnu_live_abt_lookup_far=' <(strings "$ELF") || { echo "FAIL: the LINKED image carries NO xnu_live_abt_lookup_far= string - the pool object that has it was not linked"; exit 1; }
grep -qa '^xnu_live_abt_e2_hi='    <(strings "$ELF") || { echo "FAIL: the LINKED image carries NO xnu_live_abt_e2_hi= string - 1027's far-4 entry bounds did not reach the link, so the parent cell cannot be re-read"; exit 1; }
grep -qa '^xnu_live_abt_vmfkrv='   <(strings "$ELF") || { echo "FAIL: the LINKED image carries NO xnu_live_abt_vmfkrv= string - 1025's publisher was dropped from the link"; exit 1; }
grep -qa '^xnu_live_ustack_req='   <(strings "$ELF") || { echo "FAIL: the LINKED image carries NO xnu_live_ustack_req= string - 1025's stack-shape publisher was dropped from the link"; exit 1; }
echo "   6b PASS: the linked image carries 1029's rows, the xnu_live_abt_lookup_far= discriminator, 1027's xnu_live_abt_e2_hi= bounds, AND 1025's two publishers"

# 7. The PAYLOAD rebuild.
echo "-- payload (embeds the new entry blob) --"
XNU_TREE="$XNU_TREE" STAGE90_EXTRA_CFLAGS='-DSTAGE90_XNU_ENTRY=1' ./scripts/build.sh

echo "== result =="
printf 'entry bin sha (first 8): '
sha256sum out/stage90/xnu_arm_entry.bin | cut -c1-8
echo "-- what the record carries (the press gate reads the RECORD) --"
grep -E 'STAGE90_XNU_READER_PROBE|STAGE90_XNU_H2_STACK_HEADROOM|STAGE90_XNU_ABT_ENTRY_PROBE|STAGE90_XNU_USTACK_PROBE|STAGE90_XNU_VM_MAX_SPLIT|STAGE90_XNU_IOS7_TRAPS|STAGE90_XNU_GENERAL_REGS|STAGE90_XNU_UNDEF_RAISE' "$REC"

# **THE DECLARATION CARRIER, WRITTEN LAST.**  Exactly one line.
_b_extra=out/stage90/xnu_arm_entry-arm-extra.txt
printf 'STAGE90_XNU_GLOBAL_FIX=1 role=1029-reader-probe\n' > "$_b_extra"
echo "-- 1029 wrote the declaration carrier $_b_extra:"
sed 's/^/     /' "$_b_extra"

echo "== 1029 build DONE (1028 + the reader probe under STAGE90_XNU_READER_PROBE=1; object side at 5a, linked image at 6b, gate key at preflight). Not pressed."
echo "   Park it, then press -- the press is read by tools/check_1029_capture.py. =="