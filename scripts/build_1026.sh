#!/usr/bin/env bash
# Build 1026: 1025 PLUS THE ABORT-ENTRY DISCRIMINATOR -- publish WHAT `vm_map_lookup_entry` found for
# the launchctl[2] stack VA, so H1 (wrong map) and H2 (off-the-end) can be told apart BY VALUE, under
# ONE new switch STAGE90_XNU_ABT_ENTRY_PROBE=1.
#
# WHY.  1025's press RAN and its own console was recovered (records/1025-press-read.txt).  The reading is
# FAULT-NAMED: the discarded `vm_fault` return is
#
#     xnu_live_abt_vmfkrv=1                 <- KERN_INVALID_ADDRESS
#     xnu_live_abt_vmfkrv_far=0x2bd35000    (dfsr=0x807 translation/page, prot=write,
#     xnu_live_abt_vmfkrv_sp=0x2bd34074      pc=0x3b4ce756, pid=2)
#
# and the stack's shape once per exec:
#
#     xnu_live_ustack_req=0x2bd35000 size=0x00100000 fixed_addr=0x2bc35000 rc=0
#     xnu_live_ustack_final=0x2bd35000 prot_addr=0x2bc35000 prot_size=0x00001000
#
# So the FIXED allocation SUCCEEDED and created [0x2bc35000, 0x2bd35000); the faulting VA is that
# entry's EXCLUSIVE TOP.  `vm_fault` returning KERN_INVALID_ADDRESS means `vm_map_lookup_entry(map, VA)`
# returned FALSE (osfmk/vm/vm_map.c:8761ff).  1026 exists to name WHY, and the two candidate causes
# predict DIFFERENT fixes, so it must DISCRIMINATE before either is built:
#   (H1) WRONG MAP   - `create_unix_stack` allocated into `get_task_map(task)` but the walk uses
#                      `thread->map`; if they differ the entry is invisible although far is a legal
#                      region byte.  Fix = walk the task's map.
#   (H2) OFF-THE-END - the entry ends exactly at far and a legal word sits just below; the cause is
#                      upstream (the initial argv/env block / sp one word too high).  Fix = headroom
#                      (kernel-side; userspace is correct).
#
# WHAT THIS RUNG IS NOT.  It is a PROBE (7 read-only prints on the failing-fault path) plus one
# read-only accessor.  It does NOT fix anything and it changes NO behaviour: every value is READ.
#
# THE ARM.  Two POOL edits (osfmk/arm/trap.c, bsd/kern/kern_exec.c), staged by
# tools/patch_d13_abt_entry_probe.py.  1026's trap.c block is NESTED INSIDE 1025's publisher (the fault
# path is SHARED - one gate for it), so it prints nothing unless BOTH switches are on.  The accessor
# lives in kern_exec.c because `struct proc` is only FOWARD-declared in trap.c.
#
# NOTE ([[mi4-one-file-many-rungs]]).  FOUR rungs edit osfmk/arm/trap.c (994 witness / 1020 undef_raise
# / 1025 ustack_probe / 1026 abt_entry_probe).  A cleanup `git checkout -- trap.c` reverts the others
# SILENTLY and the failure surfaces LATE (the pool compiles; the INHERITED check refuses the LINKED
# image).  Step 2 therefore RE-STAGES all four in order, and every trap.c patcher's allow-set carries
# the other three switches.

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
CHECK=tools/check_1026_capture.py
PATCH=tools/patch_d13_abt_entry_probe.py
TRAP_OBJ=$POOL/osfmk_arm_trap.o
EXEC_OBJ=$POOL/bsd_kern_kern_exec.o

echo "== 1026: name WHY the launchctl stack VA has no vm_map entry (POOL probe, ONE new switch STAGE90_XNU_ABT_ENTRY_PROBE=1) =="
echo "-- carries the previous arm's FULL switch set (read out of $REC, never a default); ADDS STAGE90_XNU_ABT_ENTRY_PROBE=1 --"

# ====================================================================================================
# 0. PRECONDITIONS: the checker must exist AND pass its own selftest; the patcher and the staging
#    wrapper must exist; the switch's four carrier sites must be present.
# ====================================================================================================
echo "-- step 0: the capture checker, the patcher and the staging wrapper are what this rung is read with --"
[[ -f $CHECK ]] || { echo "REFUSING: $CHECK does not exist. 1026's whole substance is the abort-entry discriminator the pool objects carry (trap.c's xnu_live_abt_lookup_far=* + kern_exec.c's xnu_live_abt_proc_ustack); the reading of WHICH the fault is comes from the CAPTURE the press produces, and $CHECK is its reader. A build that skipped this would be a record over an image whose probe the press could not read"; exit 1; }
python3 -I "$CHECK" --selftest >/dev/null || { echo "REFUSING: $CHECK --selftest did NOT pass. A checker whose own selftest fails cannot be the reading of this rung (m1015b). Do not build 1026 until the tool's selftest is green"; exit 1; }
echo "   step 0: $CHECK --selftest PASSes"
[[ -f $PATCH ]] || { echo "REFUSING: $PATCH does not exist - the tree's trap.c/kern_exec.c discriminator is gated shut on CANCRO and this script stages it through that patcher"; exit 1; }
[[ -f tools/stage_d13_abt_entry_probe.sh ]] || { echo "REFUSING: tools/stage_d13_abt_entry_probe.sh does not exist (the re-checkoutable entry point for the two pool edits)"; exit 1; }
# The switch's channel: the global DEFINES block must be present, or the export below is a no-op.
grep -q 'DEFINES+=(-DSTAGE90_XNU_ABT_ENTRY_PROBE=1)' tools/build_xnu_arm_kernel.sh || { echo "REFUSING: tools/build_xnu_arm_kernel.sh carries no STAGE90_XNU_ABT_ENTRY_PROBE block in its global DEFINES array. The switch's channel is that array (every compile line carries it, incl. the EABI-runtime and firehose blocks, which do NOT get EXTRA_DEFINES); without it the export below reaches nothing and the pool objects keep no discriminator while the record says 1 -- the records/1020-build-defect.txt shape"; exit 1; }
grep -q 'STAGE90_XNU_ABT_ENTRY_PROBE' src/entry/build_entry.sh || { echo "REFUSING: src/entry/build_entry.sh does not carry STAGE90_XNU_ABT_ENTRY_PROBE (ENTRY_ARM_KEYS / the arm-key case / the record writer / the link-site clause). Without all four the record cannot say which discriminator its pool was built with"; exit 1; }
grep -q 'STAGE90_XNU_ABT_ENTRY_PROBE' scripts/preflight_boot_check.sh || { echo "REFUSING: scripts/preflight_boot_check.sh does not carry STAGE90_XNU_ABT_ENTRY_PROBE in ENTRY_CFG_KEYS (+ its -z grace branch). A record key the gate does not print is a switch the next run would go out with unread"; exit 1; }
# The four-rung shared namespace: each trap.c patcher must allow the others' switches.
for _p in tools/patch_d13_undef_raise.py tools/patch_d13_dyld_witness.py tools/patch_d13_ustack_probe.py; do
  grep -q 'STAGE90_XNU_ABT_ENTRY_PROBE' "$_p" || { echo "REFUSING: $_p's ALLOWED_IF_IDENTIFIERS does not carry STAGE90_XNU_ABT_ENTRY_PROBE. Four rungs edit osfmk/arm/trap.c (994/1020/1025/1026) and a file's directive identifiers are a SHARED namespace: without the new switch in every patcher's allow-set the OFF proofs refuse the composed tree ([[mi4-one-file-many-rungs]])"; exit 1; }
done
echo "   step 0: the switch's four carrier sites (kernel DEFINES, entry keys/case/writer/clause, gate key list) are present, and all four trap.c patchers share the namespace"

# ====================================================================================================
# 1. CARRY THE PREVIOUS ARM'S FULL SWITCH SET -- never a default, read out of the arm's own record.
# ====================================================================================================
[ -r "$REC" ] || { echo "FAIL: no arm record at $REC -- build 1025 first (this rung carries ITS set)"; exit 1; }
grep -q '^STAGE90_XNU_USTACK_PROBE=1$' "$REC" || { echo "FAIL: $REC does not carry STAGE90_XNU_USTACK_PROBE=1 -- this is not the 1025 arm, and 1026's block is NESTED inside 1025's publisher (it prints nothing without it)"; exit 1; }
grep -q '^STAGE90_XNU_VM_MAX_SPLIT=1$' "$REC" || { echo "FAIL: $REC does not carry STAGE90_XNU_VM_MAX_SPLIT=1 -- this is not the 1024 arm, and that switch is what keeps the 1023 pthread storm away (the boot must reach launchctl to be a 1026 reading)"; exit 1; }
grep -q '^STAGE90_XNU_IOS7_TRAPS=1$' "$REC" || { echo "FAIL: $REC does not carry STAGE90_XNU_IOS7_TRAPS=1 -- this is not the 1023-derived arm (rows 15/24 must stay installed)"; exit 1; }
grep -q '^STAGE90_XNU_GENERAL_REGS=1$' "$REC" || { echo "FAIL: $REC does not carry STAGE90_XNU_GENERAL_REGS=1 -- 1021d's -msoft-float must be preserved (dropping it brings the kernel-mode NEON undef back)"; exit 1; }
grep -q '^STAGE90_XNU_UNDEF_RAISE=1$' "$REC" || { echo "FAIL: $REC does not carry STAGE90_XNU_UNDEF_RAISE=1 -- this is not the 1020b-derived arm"; exit 1; }
# **IDEMPOTENT RE-ENTRY (2026-10-16).** This rung's own switch MAY already be in $REC: the record
# is the SHARED LIVE state ([[mi4-out-stage90-is-shared-live-state]]) and a prior run of THIS build
# (interrupted, or a re-run after a build-side fix) writes it. Refusing on that trace made the build
# UNRE-ENTRANT: the first attempt reached the entry layer, and every later attempt died here on its
# own output. The check that MATTERS is the five `=1` pins above -- they prove $REC is the
# 1025/1024/1023/1021d/1020b lineage this rung carries; with all five present, a pre-existing
# STAGE90_XNU_ABT_ENTRY_PROBE is this build's own trace and is HARMLESS (the exporter appends the
# same `=1` again; the patcher's done-mark reports "already staged"). So we do NOT refuse on it.
# What we DO refuse -- the real half-on hazard -- is the switch present with a DIFFERENT value,
# which would mean a stale/foreign arm carrying a half-staged discriminator.
if grep -q '^STAGE90_XNU_ABT_ENTRY_PROBE=' "$REC" && \
   ! grep -q '^STAGE90_XNU_ABT_ENTRY_PROBE=1$' "$REC"; then
  echo "FAIL: $REC carries STAGE90_XNU_ABT_ENTRY_PROBE with a value other than 1 -- a stale/foreign arm with a half-staged 1026 discriminator; rebuild from a clean 1025 record"; exit 1
fi
if grep -q '^STAGE90_XNU_ABT_ENTRY_PROBE=1$' "$REC"; then
  echo "   note: $REC already carries STAGE90_XNU_ABT_ENTRY_PROBE=1 (this build's own prior trace); re-entering idempotently"
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
EXPORTS+=("STAGE90_XNU_ABT_ENTRY_PROBE=1")
echo "   carrying $(( ${#EXPORTS[@]} - 3 )) switch(es) from $REC + STAGE90_XNU_ABT_ENTRY_PROBE=1"

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

# ====================================================================================================
# 2. STAGE THE TREE EDITS.  ALL FOUR trap.c rungs in order, then THIS rung's two pool edits.
# ====================================================================================================
echo "-- stage the tree edits (1021d/1022/1023/1024/1025's set must already be staged, then 1026's two) --"
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
# ---- 1026: THE ABORT-ENTRY DISCRIMINATOR ----------------------------------------------------------
echo "-- $PATCH (1026: trap.c discriminator nested in 1025's block + kern_exec.c accessor) --"
python3 "$PATCH" "$XNU_TREE" || { echo "FAIL: $PATCH (plan mode) refused - the tree is not in the state this rung was written against. It writes nothing on a refusal"; exit 1; }
python3 "$PATCH" "$XNU_TREE" --apply || { echo "FAIL: $PATCH --apply refused"; exit 1; }
python3 "$PATCH" "$XNU_TREE" --apply >/dev/null || { echo "FAIL: a second --apply of $PATCH did not succeed (the idempotent no-op)"; exit 1; }
python3 "$PATCH" "$XNU_TREE" --verify-off >/dev/null || { echo "FAIL: $PATCH --verify-off did not PASS - the ON/OFF shapes are not the ones this rung declares ([[mi4-off-option-two-spellings]])"; exit 1; }
# ---- after 1026 lands, the THREE inherited patchers must still accept the composed tree -----------
python3 tools/patch_d13_ustack_probe.py "$XNU_TREE" >/dev/null || { echo "FAIL: after 1026 is staged, tools/patch_d13_ustack_probe.py REFUSES trap.c - the four-rung shared namespace is not in effect ([[mi4-one-file-many-rungs]])"; exit 1; }
python3 tools/patch_d13_undef_raise.py "$XNU_TREE" >/dev/null || { echo "FAIL: after 1026 is staged, tools/patch_d13_undef_raise.py REFUSES trap.c - the shared namespace is not in effect"; exit 1; }
python3 tools/patch_d13_dyld_witness.py "$XNU_TREE" >/dev/null || { echo "FAIL: after 1026 is staged, tools/patch_d13_dyld_witness.py REFUSES trap.c - the shared namespace is not in effect"; exit 1; }
python3 tools/patch_d13_abt_entry_probe.py "$XNU_TREE" >/dev/null || { echo "FAIL: a third plan-mode run of $PATCH refused - its own idempotency is not stable"; exit 1; }
# The staged bytes themselves: exactly ONE of each gate line, and 1026's block INSIDE 1025's.
[[ $(grep -c 'xnu_live_abt_vmfkrv=' "$XNU_TREE/osfmk/arm/trap.c") == 1 ]] || { echo "FAIL: $XNU_TREE/osfmk/arm/trap.c does not carry EXACTLY 1 xnu_live_abt_vmfkrv= line - a partial or double edit"; exit 1; }
[[ $(grep -c 'xnu_live_abt_lookup_far=' "$XNU_TREE/osfmk/arm/trap.c") == 1 ]] || { echo "FAIL: $XNU_TREE/osfmk/arm/trap.c does not carry EXACTLY 1 xnu_live_abt_lookup_far= line - a partial or double edit"; exit 1; }
[[ $(grep -c 'xnu_live_abt_proc_ustack' "$XNU_TREE/bsd/kern/kern_exec.c") == 1 ]] || { echo "FAIL: $XNU_TREE/bsd/kern/kern_exec.c does not carry EXACTLY 1 xnu_live_abt_proc_ustack - a partial or double edit"; exit 1; }
# 1026's gate must sit INSIDE 1025's (ONE gate on the shared fault path): the 1025 `#endif` must come
# strictly AFTER the 1026 `#endif`.
_abt_105=$(grep -n '^#endif /\* STAGE90_XNU_USTACK_PROBE \*/' "$XNU_TREE/osfmk/arm/trap.c" | head -1 | cut -d: -f1)
_abt_106=$(grep -n '^#endif /\* STAGE90_XNU_ABT_ENTRY_PROBE \*/' "$XNU_TREE/osfmk/arm/trap.c" | head -1 | cut -d: -f1)
[[ -n $_abt_105 && -n $_abt_106 && $_abt_106 -lt $_abt_105 ]] || { echo "FAIL: 1026's gate is NOT nested inside 1025's (1026 #endif line=$_abt_106 must precede 1025 #endif line=$_abt_105). The discriminator must be INSIDE the shared fault-path gate, not a second competing block"; exit 1; }
echo "   POOL: the staged trap.c/kern_exec.c carry the discriminator NESTED inside 1025's block, both files' OFF/ON proofs PASS, the inherited set still composes"

# ====================================================================================================
# 3. Export the pool switches (1025's set VERBATIM) + THIS rung's switch, BEFORE the pool build.
# ====================================================================================================
echo "-- exporting 1025's pool switch set, unchanged --"
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
# **THIS RUNG'S SWITCH, CHANNEL 1: the env variable tools/build_xnu_arm_kernel.sh reads into the global
# DEFINES array.**  Without the export the pool objects carry no discriminator while the record says 1.
export STAGE90_XNU_ABT_ENTRY_PROBE=1
echo "-- STAGE90_XNU_ABT_ENTRY_PROBE=$STAGE90_XNU_ABT_ENTRY_PROBE STAGE90_XNU_USTACK_PROBE=$STAGE90_XNU_USTACK_PROBE STAGE90_XNU_VM_MAX_SPLIT=$STAGE90_XNU_VM_MAX_SPLIT STAGE90_XNU_IOS7_TRAPS=$STAGE90_XNU_IOS7_TRAPS STAGE90_XNU_GENERAL_REGS=$STAGE90_XNU_GENERAL_REGS STAGE90_XNU_UNDEF_RAISE=$STAGE90_XNU_UNDEF_RAISE (pool DEFINES + FP flag list + asm ASFLAGS + EXTRA agree) --"
export STAGE90_XNU_HFS_ROOT_RW=$(awk -F= '$1=="STAGE90_XNU_HFS_ROOT_RW"{print $2}' "$REC")
echo "-- STAGE90_XNU_HFS_ROOT_RW=$STAGE90_XNU_HFS_ROOT_RW (the pool's hfs_vfsops.o carries the rw clear) --"
[[ -n ${STAGE90_XNU_ABT_ENTRY_PROBE:-} ]] || { echo "FAIL: STAGE90_XNU_ABT_ENTRY_PROBE is not exported - tools/build_xnu_arm_kernel.sh reads that ENV variable into the global DEFINES array"; exit 1; }
[[ -n ${STAGE90_XNU_USTACK_PROBE:-} ]] || { echo "FAIL: STAGE90_XNU_USTACK_PROBE is not exported - 1026's block is NESTED inside 1025's, so it prints nothing without it"; exit 1; }
[[ "$EXTRA" == *"-DSTAGE90_XNU_GLOBAL_FIX=1"* ]] || { echo "FAIL: -DSTAGE90_XNU_GLOBAL_FIX=1 is NOT in EXTRA - 1015b's fix has NO record carrier; without it the retry storm returns"; exit 1; }

# 4. The asm layer.  1026 touches NO asm file.
echo "-- arm asm layer (1026 touches NO .s file) --"
XNU_TREE="$XNU_TREE" XNU_KERNEL_CONFIG=STAGE90_XNU tools/assemble_arm_layer.sh

# 5. The POOL build -- trap.c/kern_exec.c are POOL objects, so the pool MUST be rebuilt.
echo "-- the D13 kernel pool + platform block, recompiled (trap.o/kern_exec.o move) --"
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
# 5a. THE OBJECT-SIDE ASSERTIONS.  THIS rung's fingerprint is a FORMAT STRING + a SYMBOL, read by
#     `strings`.  THE PIPE-ARGUMENT FORM IS REQUIRED: `strings X | grep -q P` under `set -o pipefail`
#     returns 141 (SIGPIPE) when the string IS present, because grep exits early and strings dies on
#     the write - a gate that is fail-closed but UNPASSABLE ([[mi4-mutation-anchors-are-code-spans]]
#     instance m1025).  Use `grep -qa P <(strings X)`.
# ====================================================================================================
echo "-- POOL(5a): the two objects where the discriminator lives --"
[[ -f $TRAP_OBJ ]] || { echo "FAIL: $TRAP_OBJ is absent - the pool build did not produce trap.o"; exit 1; }
[[ -f $EXEC_OBJ ]] || { echo "FAIL: $EXEC_OBJ is absent - the pool build did not produce kern_exec.o"; exit 1; }
_t=$(strings "$TRAP_OBJ" | grep -c '^xnu_live_abt_lookup_far=' || true)
_e=$(strings "$EXEC_OBJ" | grep -c '^xnu_live_abt_proc_ustack$' || true)
[[ "$_t" -ge 1 ]] || { echo "FAIL: $TRAP_OBJ carries NO xnu_live_abt_lookup_far= publisher - the pool was NOT recompiled with STAGE90_XNU_ABT_ENTRY_PROBE=1 (env channel) or the trap.c edit is not staged"; exit 1; }
[[ "$_e" -ge 1 ]] || { echo "FAIL: $EXEC_OBJ carries NO xnu_live_abt_proc_ustack symbol - the pool was NOT recompiled with STAGE90_XNU_ABT_ENTRY_PROBE=1 or the kern_exec.c edit is not staged"; exit 1; }
echo "   POOL(5a): trap.o carries the xnu_live_abt_lookup_far= publisher (x$_t), kern_exec.o carries xnu_live_abt_proc_ustack (x$_e)"
# The 1025 publishers must STILL be there (this rung rebuilds the whole pool with 1025's set).
grep -qa '^xnu_live_abt_vmfkrv=' <(strings "$TRAP_OBJ") || { echo "FAIL: $TRAP_OBJ lost 1025's xnu_live_abt_vmfkrv= publisher - the pool rebuild dropped 1025's switch"; exit 1; }
grep -qa '^xnu_live_ustack_req=' <(strings "$EXEC_OBJ") || { echo "FAIL: $EXEC_OBJ lost 1025's xnu_live_ustack_req= publisher - the pool rebuild dropped 1025's switch"; exit 1; }
echo "   POOL(5a): 1025's publishers survive (trap.o has xnu_live_abt_vmfkrv=, kern_exec.o has xnu_live_ustack_req=)"

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
# 6. The ENTRY link.  build_entry.sh LINKS the pool objects and runs its OWN 1026 clause.
# ====================================================================================================
echo "-- entry link (build_entry.sh reads the pool objects and its 1026 clause refuses a record over a stale pool) --"
( cd src/entry && env -i PATH="$PATH" HOME="$HOME" "${EXPORTS[@]}" ./build_entry.sh )

# 6b. The by-value clauses on the LINKED image, before the payload is embedded.
echo "-- by value (6b): the LINKED image still carries 1024's ceiling + 1023's row 24 --"
python3 tools/check_vm_max_split.py "$ELF" --expect on >/dev/null || { echo "FAIL: the LINKED image's task map ceiling is not 0x40000000"; exit 1; }
python3 tools/check_1023_trap24.py "$ELF" --expect on >/dev/null || { echo "FAIL: the LINKED image's mach_trap_table[24] moved - 1026 must ADD nothing but the discriminator"; exit 1; }
echo "   6b PASS: the linked image's ceiling reads 0x40000000 and row 24 is untouched"
# THIS rung's keys ARE in the linked image: the format string + the accessor symbol must be reachable.
# `grep -qa P <(strings X)` NOT `strings X | grep -q P` (pipefail/SIGPIPE = 141 - instance m1025).
grep -qa '^xnu_live_abt_lookup_far=' <(strings "$ELF") || { echo "FAIL: the LINKED image carries NO xnu_live_abt_lookup_far= string - the pool object that has it was not linked"; exit 1; }
grep -qa '^xnu_live_abt_vmfkrv='   <(strings "$ELF") || { echo "FAIL: the LINKED image carries NO xnu_live_abt_vmfkrv= string - 1025's publisher was dropped from the link"; exit 1; }
grep -qa '^xnu_live_ustack_req='   <(strings "$ELF") || { echo "FAIL: the LINKED image carries NO xnu_live_ustack_req= string - 1025's stack-shape publisher was dropped from the link"; exit 1; }
echo "   6b PASS: the linked image carries the xnu_live_abt_lookup_far= discriminator AND 1025's two publishers"

# 7. The PAYLOAD rebuild.
echo "-- payload (embeds the new entry blob) --"
XNU_TREE="$XNU_TREE" STAGE90_EXTRA_CFLAGS='-DSTAGE90_XNU_ENTRY=1' ./scripts/build.sh

echo "== result =="
printf 'entry bin sha (first 8): '
sha256sum out/stage90/xnu_arm_entry.bin | cut -c1-8
echo "-- what the record carries (the press gate reads the RECORD) --"
grep -E 'STAGE90_XNU_ABT_ENTRY_PROBE|STAGE90_XNU_USTACK_PROBE|STAGE90_XNU_VM_MAX_SPLIT|STAGE90_XNU_IOS7_TRAPS|STAGE90_XNU_GENERAL_REGS|STAGE90_XNU_UNDEF_RAISE' "$REC"

# **THE DECLARATION CARRIER, WRITTEN LAST.**  Exactly one line.
_b_extra=out/stage90/xnu_arm_entry-arm-extra.txt
printf 'STAGE90_XNU_GLOBAL_FIX=1 role=1026-abt-entry-probe\n' > "$_b_extra"
echo "-- 1026 wrote the declaration carrier $_b_extra:"
sed 's/^/     /' "$_b_extra"

echo "== 1026 build DONE (1025 + the abort-entry discriminator under STAGE90_XNU_ABT_ENTRY_PROBE=1; object side at 5a, linked image at 6b, gate key at preflight). Not pressed."
echo "   Park it, then press -- the press is read by tools/check_1026_capture.py. =="