#!/usr/bin/env bash
# Build 1028: 1027 PLUS THE H2 FIX -- give the initial user-stack block ONE WORD OF HEADROOM above it,
# so the region's EXCLUSIVE TOP moves to user_stack+16 and the top word userspace touches is OWNED.
# ONE new switch STAGE90_XNU_H2_STACK_HEADROOM=1, whose edit is tools/patch_d13_h2_stack_headroom.py
# (bsd/kern/kern_exec.c's create_unix_stack: the FIXED `mach_vm_allocate` extent becomes `size + 16`).
#
# WHY.  1027's press RAN and its own console was recovered (records/1027-press-read.txt).  The reading is
# **H2 (off-the-end)**, by value, at the launchctl[2] stack fault:
#
#     lookup_far=0  far_in_map=1  entry=[0,0)  e2=[0x2bce1000,0x2bde0000)
#     e2_hi == far == ustack == 0x2bde0000     map == taskmap == 0xc0005688
#
# The user-stack region is `[0x2bce1000, 0x2bde0000)` and its EXCLUSIVE TOP IS `far`.  The word just
# below (`far-4`) IS in the map (`far_in_map=1`), so a write AT `far` is a write ONE WORD PAST the
# region's end.  H1 (wrong map) is refuted by value (`map == taskmap`).  By source, `create_unix_stack`
# sets `p->user_stack` to the requested top and allocates `[user_stack - size, user_stack)`, and then
# `exec_copyout_strings` places the initial argv/env block with its TOP at `p->user_stack` -- so the
# block's last byte is `user_stack - 1` and the word AT `user_stack` is UNOWNED.  The measured 1025 rows
# (`xnu_live_ustack_rc=0`, FIXED allocate succeeded) fix the geometry: the region top and the block top
# COINCIDE.
#
# THE FIX.  In the FIXED `mach_vm_allocate` ONLY, pass `size + 16` instead of `size`, anchored so the
# region's TOP moves UP by 16 while the base, the block, `sp`, `p->user_stack`, and the guard math are
# UNCHANGED.  The region then OWNS the word at `user_stack` that userspace touches.  docs/1028-design.md.
#
# WHAT THIS RUNG IS NOT.  It changes NO string and prints NOTHING: it is a BEHAVIOUR change (+16 bytes of
# address space per non-prog-allocated stack), so unlike 1025/1026 there is NO `strings` fingerprint on
# the object.  The object-side evidence is that the staged kern_exec.c carries the switch AND the pool
# was rebuilt with it (step 5a).
#
# THE POOL EDITS.  THREE rungs now edit bsd/kern/kern_exec.c (1025/1026 accessor + 1028 fix) and FOUR
# edit osfmk/arm/trap.c (994 witness / 1020 undef_raise / 1025 ustack_probe / 1026 abt_entry_probe).
# 1028's edit is a THIRD block in kern_exec.c, staged by tools/patch_d13_h2_stack_headroom.py (its own
# ALLOWED_STAGE90 carries 1025/1026 so the three compose).  A cleanup `git checkout --` reverts the
# others SILENTLY and the failure surfaces LATE (the pool compiles; the INHERITED check refuses the
# LINKED image), so step 2 RE-STAGES all of them in order ([[mi4-one-file-many-rungs]]).

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
CHECK=tools/check_1028_capture.py
PATCH=tools/patch_d13_h2_stack_headroom.py
TRAP_OBJ=$POOL/osfmk_arm_trap.o
EXEC_OBJ=$POOL/bsd_kern_kern_exec.o

echo "== 1028: give the initial user-stack block ONE WORD OF HEADROOM (the H2 FIX; POOL fix, ONE new switch STAGE90_XNU_H2_STACK_HEADROOM=1) =="
echo "-- carries the previous arm's FULL switch set (read out of $REC, never a default); ADDS STAGE90_XNU_H2_STACK_HEADROOM=1 --"

# ====================================================================================================
# 0. PRECONDITIONS: the checker must exist AND pass its own selftest; the patcher and the staging
#    wrapper must exist; the switch's four carrier sites must be present.
# ====================================================================================================
echo "-- step 0: the capture checker, the patcher and the staging wrapper are what this rung is read with --"
[[ -f $CHECK ]] || { echo "REFUSING: $CHECK does not exist. 1028's whole substance is the H2 FIX (create_unix_stack's FIXED mach_vm_allocate extent = size + 16, staged by tools/patch_d13_h2_stack_headroom.py); the reading of whether it HOLDS comes from the CAPTURE the press produces, and $CHECK is its reader. A build that skipped this would be a record over an image whose fix the press could not adjudicate"; exit 1; }
python3 -I "$CHECK" --selftest >/dev/null || { echo "REFUSING: $CHECK --selftest did NOT pass. A checker whose own selftest fails cannot be the reading of this rung (m1015b). Do not build 1028 until the tool's selftest is green"; exit 1; }
echo "   step 0: $CHECK --selftest PASSes"
[[ -f $PATCH ]] || { echo "REFUSING: $PATCH does not exist - the tree's create_unix_stack headroom edit is gated shut on CANCRO and this script stages it through that patcher"; exit 1; }
[[ -f tools/stage_d13_h2_stack_headroom.sh ]] || { echo "REFUSING: tools/stage_d13_h2_stack_headroom.sh does not exist (the re-checkoutable entry point for the kern_exec.c fix)"; exit 1; }
# The switch's channel: the global DEFINES block must be present, or the export below is a no-op.
grep -q 'DEFINES+=(-DSTAGE90_XNU_H2_STACK_HEADROOM=1)' tools/build_xnu_arm_kernel.sh || { echo "REFUSING: tools/build_xnu_arm_kernel.sh carries no STAGE90_XNU_H2_STACK_HEADROOM block in its global DEFINES array. The switch's channel is that array (every compile line carries it, incl. the EABI-runtime and firehose blocks, which do NOT get EXTRA_DEFINES); without it the export below reaches nothing and the pool objects keep the UNFIXED create_unix_stack while the record says 1 -- the records/1020-build-defect.txt shape"; exit 1; }
grep -q 'STAGE90_XNU_H2_STACK_HEADROOM' src/entry/build_entry.sh || { echo "REFUSING: src/entry/build_entry.sh does not carry STAGE90_XNU_H2_STACK_HEADROOM (ENTRY_ARM_KEYS / the arm-key case / the record writer). Without all three the record cannot say which stack-headroom arm its pool was built with"; exit 1; }
grep -q 'STAGE90_XNU_H2_STACK_HEADROOM' scripts/preflight_boot_check.sh || { echo "REFUSING: scripts/preflight_boot_check.sh does not carry STAGE90_XNU_H2_STACK_HEADROOM in ENTRY_CFG_KEYS (+ its -z grace branch). A record key the gate does not print is a switch the next run would go out with unread"; exit 1; }
# The shared namespace: kern_exec.c already carries 1025/1026's switches, and this rung adds a third.
# Every kern_exec.c patcher's allow-set must carry the new switch, or the OFF proofs refuse the composed
# tree ([[mi4-one-file-many-rungs]]).
for _p in tools/patch_d13_ustack_probe.py tools/patch_d13_abt_entry_probe.py; do
  grep -q 'STAGE90_XNU_H2_STACK_HEADROOM' "$_p" || { echo "REFUSING: $_p's ALLOWED_IF_IDENTIFIERS does not carry STAGE90_XNU_H2_STACK_HEADROOM. THREE rungs edit bsd/kern/kern_exec.c (1025/1026/1028) and a file's directive identifiers are a SHARED namespace: without the new switch in every kern_exec.c patcher's allow-set the OFF proofs refuse the composed tree ([[mi4-one-file-many-rungs]])"; exit 1; }
done
echo "   step 0: the switch's carrier sites (kernel DEFINES, entry keys/case/writer, gate key list) are present, and the kern_exec.c patchers share the namespace"

# ====================================================================================================
# 1. CARRY THE PREVIOUS ARM'S FULL SWITCH SET -- never a default, read out of the arm's own record.
# ====================================================================================================
[ -r "$REC" ] || { echo "FAIL: no arm record at $REC -- build 1027 first (this rung carries ITS set)"; exit 1; }
grep -q '^STAGE90_XNU_ABT_ENTRY_PROBE=1$' "$REC" || { echo "FAIL: $REC does not carry STAGE90_XNU_ABT_ENTRY_PROBE=1 -- this is not the 1027 arm, and 1028 carries the whole 1027 set verbatim (the H2 fix is ADDED to the discriminator, not instead of it)"; exit 1; }
grep -q '^STAGE90_XNU_USTACK_PROBE=1$' "$REC" || { echo "FAIL: $REC does not carry STAGE90_XNU_USTACK_PROBE=1 -- this is not the 1025 arm, and 1026's block (which 1028 carries) is NESTED inside 1025's publisher (it prints nothing without it)"; exit 1; }
grep -q '^STAGE90_XNU_VM_MAX_SPLIT=1$' "$REC" || { echo "FAIL: $REC does not carry STAGE90_XNU_VM_MAX_SPLIT=1 -- this is not the 1024 arm, and that switch is what keeps the 1023 pthread storm away (the boot must reach launchctl to be a 1028 reading)"; exit 1; }
grep -q '^STAGE90_XNU_IOS7_TRAPS=1$' "$REC" || { echo "FAIL: $REC does not carry STAGE90_XNU_IOS7_TRAPS=1 -- this is not the 1023-derived arm (rows 15/24 must stay installed)"; exit 1; }
grep -q '^STAGE90_XNU_GENERAL_REGS=1$' "$REC" || { echo "FAIL: $REC does not carry STAGE90_XNU_GENERAL_REGS=1 -- 1021d's -msoft-float must be preserved (dropping it brings the kernel-mode NEON undef back)"; exit 1; }
grep -q '^STAGE90_XNU_UNDEF_RAISE=1$' "$REC" || { echo "FAIL: $REC does not carry STAGE90_XNU_UNDEF_RAISE=1 -- this is not the 1020b-derived arm"; exit 1; }
# **IDEMPOTENT RE-ENTRY (2026-10-16).** This rung's own switch MAY already be in $REC: the record
# is the SHARED LIVE state ([[mi4-out-stage90-is-shared-live-state]]) and a prior run of THIS build
# (interrupted, or a re-run after a build-side fix) writes it. Refusing on that trace made the build
# UNRE-ENTRANT: the first attempt reached the entry layer, and every later attempt died here on its
# own output. The check that MATTERS is the six `=1` pins above -- they prove $REC is the
# 1027/1025/1024/1023/1021d/1020b lineage this rung carries; with all six present, a pre-existing
# STAGE90_XNU_H2_STACK_HEADROOM is this build's own trace and is HARMLESS (the exporter appends the
# same `=1` again; the patcher's done-mark reports "already staged"). So we do NOT refuse on it.
# What we DO refuse -- the real half-on hazard -- is the switch present with a DIFFERENT value,
# which would mean a stale/foreign arm carrying a half-staged fix.
if grep -q '^STAGE90_XNU_H2_STACK_HEADROOM=' "$REC" && \
   ! grep -q '^STAGE90_XNU_H2_STACK_HEADROOM=1$' "$REC"; then
  echo "FAIL: $REC carries STAGE90_XNU_H2_STACK_HEADROOM with a value other than 1 -- a stale/foreign arm with a half-staged 1028 fix; rebuild from a clean 1027 record"; exit 1
fi
if grep -q '^STAGE90_XNU_H2_STACK_HEADROOM=1$' "$REC"; then
  echo "   note: $REC already carries STAGE90_XNU_H2_STACK_HEADROOM=1 (this build's own prior trace); re-entering idempotently"
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
EXPORTS+=("STAGE90_XNU_H2_STACK_HEADROOM=1")
echo "   carrying $(( ${#EXPORTS[@]} - 3 )) switch(es) from $REC + STAGE90_XNU_H2_STACK_HEADROOM=1"

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

# ====================================================================================================
# 2. STAGE THE TREE EDITS.  ALL FOUR trap.c rungs + kern_exec.c's accessor in order, then THIS rung's
#    kern_exec.c fix.
# ====================================================================================================
echo "-- stage the tree edits (1021d/1022/1023/1024/1025/1026's set must already be staged, then 1028's fix) --"
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
echo "-- $PATCH (1028: create_unix_stack's FIXED mach_vm_allocate extent = size + 16) --"
python3 "$PATCH" "$XNU_TREE" || { echo "FAIL: $PATCH (plan mode) refused - the tree is not in the state this rung was written against. It writes nothing on a refusal"; exit 1; }
python3 "$PATCH" "$XNU_TREE" --apply || { echo "FAIL: $PATCH --apply refused"; exit 1; }
python3 "$PATCH" "$XNU_TREE" --apply >/dev/null || { echo "FAIL: a second --apply of $PATCH did not succeed (the idempotent no-op)"; exit 1; }
python3 "$PATCH" "$XNU_TREE" --verify-off >/dev/null || { echo "FAIL: $PATCH --verify-off did not PASS - the OFF arm does not reproduce the original mach_vm_allocate ([[mi4-off-option-two-spellings]])"; exit 1; }
# ---- after 1026+1028 land, the FOUR inherited patchers must still accept the composed tree --------
python3 tools/patch_d13_ustack_probe.py "$XNU_TREE" >/dev/null || { echo "FAIL: after 1026/1028 are staged, tools/patch_d13_ustack_probe.py REFUSES trap.c - the shared namespace is not in effect ([[mi4-one-file-many-rungs]])"; exit 1; }
python3 tools/patch_d13_undef_raise.py "$XNU_TREE" >/dev/null || { echo "FAIL: after 1026/1028 are staged, tools/patch_d13_undef_raise.py REFUSES trap.c - the shared namespace is not in effect"; exit 1; }
python3 tools/patch_d13_dyld_witness.py "$XNU_TREE" >/dev/null || { echo "FAIL: after 1026/1028 are staged, tools/patch_d13_dyld_witness.py REFUSES trap.c - the shared namespace is not in effect"; exit 1; }
python3 tools/patch_d13_abt_entry_probe.py "$XNU_TREE" >/dev/null || { echo "FAIL: a third plan-mode run of tools/patch_d13_abt_entry_probe.py refused - its own idempotency is not stable"; exit 1; }
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
# 1026's gate must sit INSIDE 1025's (ONE gate on the shared fault path): the 1025 `#endif` must come
# strictly AFTER the 1026 `#endif`.
_abt_105=$(grep -n '^#endif /\* STAGE90_XNU_USTACK_PROBE \*/' "$XNU_TREE/osfmk/arm/trap.c" | head -1 | cut -d: -f1)
_abt_106=$(grep -n '^#endif /\* STAGE90_XNU_ABT_ENTRY_PROBE \*/' "$XNU_TREE/osfmk/arm/trap.c" | head -1 | cut -d: -f1)
[[ -n $_abt_105 && -n $_abt_106 && $_abt_106 -lt $_abt_105 ]] || { echo "FAIL: 1026's gate is NOT nested inside 1025's (1026 #endif line=$_abt_106 must precede 1025 #endif line=$_abt_105). The discriminator must be INSIDE the shared fault-path gate, not a second competing block"; exit 1; }
echo "   POOL: the staged trap.c/kern_exec.c carry the discriminator NESTED inside 1025's block AND 1028's H2 fix (size + 16), every file's OFF/ON proofs PASS, the inherited set still composes"

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
# 1027's discriminator, carried VERBATIM: it is the INSTRUMENT that produced this rung's premise (the
# far-4 covering entry), and 1028's kern_exec.c fix is a SIBLING block in the same file.  Dropping it
# would silently un-build the by-value rows the 1028 reading is adjudicated against
# ([[mi4-build-variant-comes-from-an-env-default]]).
export STAGE90_XNU_ABT_ENTRY_PROBE=1
# **THIS RUNG'S SWITCH, CHANNEL 1: the env variable tools/build_xnu_arm_kernel.sh reads into the global
# DEFINES array.**  Without the export the pool objects keep the UNFIXED create_unix_stack while the
# record says 1.
export STAGE90_XNU_H2_STACK_HEADROOM=1
echo "-- STAGE90_XNU_H2_STACK_HEADROOM=$STAGE90_XNU_H2_STACK_HEADROOM STAGE90_XNU_ABT_ENTRY_PROBE=$STAGE90_XNU_ABT_ENTRY_PROBE STAGE90_XNU_USTACK_PROBE=$STAGE90_XNU_USTACK_PROBE STAGE90_XNU_VM_MAX_SPLIT=$STAGE90_XNU_VM_MAX_SPLIT STAGE90_XNU_IOS7_TRAPS=$STAGE90_XNU_IOS7_TRAPS STAGE90_XNU_GENERAL_REGS=$STAGE90_XNU_GENERAL_REGS STAGE90_XNU_UNDEF_RAISE=$STAGE90_XNU_UNDEF_RAISE (pool DEFINES + FP flag list + asm ASFLAGS + EXTRA agree) --"
export STAGE90_XNU_HFS_ROOT_RW=$(awk -F= '$1=="STAGE90_XNU_HFS_ROOT_RW"{print $2}' "$REC")
echo "-- STAGE90_XNU_HFS_ROOT_RW=$STAGE90_XNU_HFS_ROOT_RW (the pool's hfs_vfsops.o carries the rw clear) --"
[[ -n ${STAGE90_XNU_H2_STACK_HEADROOM:-} ]] || { echo "FAIL: STAGE90_XNU_H2_STACK_HEADROOM is not exported - tools/build_xnu_arm_kernel.sh reads that ENV variable into the global DEFINES array"; exit 1; }
[[ -n ${STAGE90_XNU_ABT_ENTRY_PROBE:-} ]] || { echo "FAIL: STAGE90_XNU_ABT_ENTRY_PROBE is not exported - 1028 carries 1027's discriminator, and 1026's block is NESTED inside 1025's"; exit 1; }
[[ -n ${STAGE90_XNU_USTACK_PROBE:-} ]] || { echo "FAIL: STAGE90_XNU_USTACK_PROBE is not exported - 1026's block is NESTED inside 1025's, so it prints nothing without it"; exit 1; }
[[ "$EXTRA" == *"-DSTAGE90_XNU_GLOBAL_FIX=1"* ]] || { echo "FAIL: -DSTAGE90_XNU_GLOBAL_FIX=1 is NOT in EXTRA - 1015b's fix has NO record carrier; without it the retry storm returns"; exit 1; }

# 4. The asm layer.  1028 touches NO asm file.
echo "-- arm asm layer (1028 touches NO .s file) --"
XNU_TREE="$XNU_TREE" XNU_KERNEL_CONFIG=STAGE90_XNU tools/assemble_arm_layer.sh

# 5. The POOL build -- trap.c/kern_exec.c are POOL objects, so the pool MUST be rebuilt.
echo "-- the D13 kernel pool + platform block, recompiled (kern_exec.o moves) --"
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
# 5a. THE OBJECT-SIDE ASSERTIONS.  The INHERITED 1025/1026/1027 fingerprints are FORMAT STRINGS read by
#     `strings`.  THE PIPE-ARGUMENT FORM IS REQUIRED: `strings X | grep -q P` under `set -o pipefail`
#     returns 141 (SIGPIPE) when the string IS present, because grep exits early and strings dies on
#     the write - a gate that is fail-closed but UNPASSABLE ([[mi4-mutation-anchors-are-code-spans]]
#     instance m1025).  Use `grep -qa P <(strings X)`.
#     **1028's OWN FIX HAS NO STRING** (it changes the FIXED mach_vm_allocate extent, not a print), so
#     its object-side gate is the honest pair: (i) the STAGED kern_exec.c carries the switch and the
#     `size + 16` extent, and (ii) the POOL compiled THAT content - the pool's own source record names
#     kern_exec.c's content hash and it must equal the staged file's sha256.  Without (ii) the record
#     could say 1 over a pool object built from an OLD kern_exec.c.
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
[[ "$_t" -ge 1 ]] || { echo "FAIL: $TRAP_OBJ carries NO xnu_live_abt_lookup_far= publisher - the pool was NOT recompiled with STAGE90_XNU_ABT_ENTRY_PROBE=1 (env channel) or the trap.c edit is not staged"; exit 1; }
[[ "$_f2" -ge 1 ]] || { echo "FAIL: $TRAP_OBJ carries NO xnu_live_abt_e2_hi= publisher - this is a 1026 SHAPE pool object (entry_hi suppressed in the H2 case, e2 never printed), so the H2 cell would AGAIN be unsatisfiable and the press would read H-OTHER for a second time. The 1027 amendment to tools/patch_d13_abt_entry_probe.py did not reach the object"; exit 1; }
[[ "$_e" -ge 1 ]] || { echo "FAIL: $EXEC_OBJ carries NO xnu_live_abt_proc_ustack symbol - the pool was NOT recompiled with STAGE90_XNU_ABT_ENTRY_PROBE=1 or the kern_exec.c edit is not staged"; exit 1; }
echo "   POOL(5a): trap.o carries xnu_live_abt_lookup_far= (x$_t) AND xnu_live_abt_e2_hi= (x$_f2) publishers, kern_exec.o carries xnu_live_abt_proc_ustack (x$_e)"
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
echo "-- by value (6b): the LINKED image still carries 1024's ceiling + 1023's row 24, and the staged kern_exec.c carries the 1028 switch --"
python3 tools/check_vm_max_split.py "$ELF" --expect on >/dev/null || { echo "FAIL: the LINKED image's task map ceiling is not 0x40000000"; exit 1; }
python3 tools/check_1023_trap24.py "$ELF" --expect on >/dev/null || { echo "FAIL: the LINKED image's mach_trap_table[24] moved - 1028 must ADD nothing but the headroom"; exit 1; }
echo "   6b PASS: the linked image's ceiling reads 0x40000000 and row 24 is untouched"
# 1028's fix has no string, so the LINKED-image clause here reads the SOURCE staged state (the record-
# level clause is 6b's `xnu_entry_1028` line) -- build_entry.sh relinked the ELF from the pool objects
# this build produced, and step 5a certified the pool compiled the staged kern_exec.c.
grep -q 'STAGE90_XNU_H2_STACK_HEADROOM' "$XNU_TREE/bsd/kern/kern_exec.c" || { echo "FAIL: the staged kern_exec.c does not carry STAGE90_XNU_H2_STACK_HEADROOM at the link site - the H2 fix is not in the tree this image was linked from"; exit 1; }
[[ $(grep -c 'mach_vm_allocate(map, &addr, size + 16,' "$XNU_TREE/bsd/kern/kern_exec.c") == 1 ]] || { echo "FAIL: the staged kern_exec.c does not carry EXACTLY 1 \`size + 16\` FIXED mach_vm_allocate at the link site"; exit 1; }
echo "   6b PASS: xnu_entry_1028 - the staged bsd/kern/kern_exec.c carries STAGE90_XNU_H2_STACK_HEADROOM with the FIXED extent = size + 16"
# THIS rung's INHERITED keys ARE in the linked image: the format strings + the accessor symbol must be
# reachable.  `grep -qa P <(strings X)` NOT `strings X | grep -q P` (pipefail/SIGPIPE = 141 - m1025).
grep -qa '^xnu_live_abt_lookup_far=' <(strings "$ELF") || { echo "FAIL: the LINKED image carries NO xnu_live_abt_lookup_far= string - the pool object that has it was not linked"; exit 1; }
grep -qa '^xnu_live_abt_e2_hi='    <(strings "$ELF") || { echo "FAIL: the LINKED image carries NO xnu_live_abt_e2_hi= string - 1027's far-4 entry bounds did not reach the link, so the fix cannot be adjudicated"; exit 1; }
grep -qa '^xnu_live_abt_vmfkrv='   <(strings "$ELF") || { echo "FAIL: the LINKED image carries NO xnu_live_abt_vmfkrv= string - 1025's publisher was dropped from the link"; exit 1; }
grep -qa '^xnu_live_ustack_req='   <(strings "$ELF") || { echo "FAIL: the LINKED image carries NO xnu_live_ustack_req= string - 1025's stack-shape publisher was dropped from the link"; exit 1; }
echo "   6b PASS: the linked image carries the xnu_live_abt_lookup_far= discriminator, 1027's xnu_live_abt_e2_hi= bounds, AND 1025's two publishers"

# 7. The PAYLOAD rebuild.
echo "-- payload (embeds the new entry blob) --"
XNU_TREE="$XNU_TREE" STAGE90_EXTRA_CFLAGS='-DSTAGE90_XNU_ENTRY=1' ./scripts/build.sh

echo "== result =="
printf 'entry bin sha (first 8): '
sha256sum out/stage90/xnu_arm_entry.bin | cut -c1-8
echo "-- what the record carries (the press gate reads the RECORD) --"
grep -E 'STAGE90_XNU_H2_STACK_HEADROOM|STAGE90_XNU_ABT_ENTRY_PROBE|STAGE90_XNU_USTACK_PROBE|STAGE90_XNU_VM_MAX_SPLIT|STAGE90_XNU_IOS7_TRAPS|STAGE90_XNU_GENERAL_REGS|STAGE90_XNU_UNDEF_RAISE' "$REC"

# **THE DECLARATION CARRIER, WRITTEN LAST.**  Exactly one line.
_b_extra=out/stage90/xnu_arm_entry-arm-extra.txt
printf 'STAGE90_XNU_GLOBAL_FIX=1 role=1028-h2-stack-headroom\n' > "$_b_extra"
echo "-- 1028 wrote the declaration carrier $_b_extra:"
sed 's/^/     /' "$_b_extra"

echo "== 1028 build DONE (1027 + the H2 stack-headroom fix under STAGE90_XNU_H2_STACK_HEADROOM=1; object side at 5a, linked image at 6b, gate key at preflight). Not pressed."
echo "   Park it, then press -- the press is read by tools/check_1028_capture.py. =="