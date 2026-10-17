#!/usr/bin/env bash
# Build 1025: 1024 PLUS THE FAILED-FAULT PROBE -- publish the value `vm_fault` RETURNS for the
# launchctl[2] stack abort, and the stack's shape, under ONE new switch STAGE90_XNU_USTACK_PROBE=1.
#
# WHY.  The 1024 boot (records/1024b-frontier-launchctl-crash.txt; its arm identity settled in
# records/1025-globalfix-carrier.txt section 6: it IS the 1024-shaped arm, so VM_MAX_SPLIT=1 AND
# GLOBAL_FIX=1 are BOTH already in it) reached `*** launchd[1] has started up ***`, spawned pid 2
# `launchctl`, and died in a USERSPACE DATA ABORT on a STACK VA:
#
#     launchctl[2]: usermode data abort, EXC_BAD_ACCESS at 0x2bdbe000 in map 0xc0005688
#                   (pmap 0xc0ba3b28) (Translation fault on page)
#     r4=r6=0x2bdbe000  sp=0x2bdbd074  lr=0x3adbc9af  pc=0x3adc4756  cpsr=0xa0000030
#
# 0x2bdbe000 is INSIDE the fixed stack window [0x2BD00000, 0x2BE00000) `create_unix_stack` allocates,
# and `sp=0x2bdbd074` shows the FIXED allocation SUCCEEDED (no ANYWHERE fallback) - so a page that
# should be mapped is TRANSLATION-faulting (by value: records/1025-source-trace.txt sections 3-4, which
# FALSIFIED the v1 collision hypothesis).  In osfmk/arm/trap.c the usermode data-abort path CALLS
# `vm_fault` and, on a non-SUCCESS return, PRINTS the abort and delivers EXC_BAD_ACCESS; the ONE
# assignment of the return code sits inside `#if BOARD_CONFIG_QSD8250_LEO`, so on CANCRO **the value
# that NAMES the cause is DISCARDED**.  1025 compiles in a publisher for it (trap.c) plus a stack-shape
# publisher (kern_exec.c) so the frontier becomes a NUMBER the next rung can act on.
#
# WHAT THIS RUNG IS NOT.  It is PROBE-ONLY: no behaviour change, no new device hazard.  It does NOT
# fix the fault; it MEASURES it.  The switch is a POOL-only switch - it does NOT change the ENTRY
# image's own linked bytes - so the record must name it (build_entry.sh writes it unconditionally) and
# the link-site clause reads the two pool objects by value (a record over a stale pool is a refusal).
#
# NOTE (the R1/R2 settlement).  records/1025-globalfix-carrier.txt section 6: the crash arm IS the
# 1024-shaped arm (split ON, no storm), so GLOBAL_FIX did NOT retire the launchctl stack abort (case
# R2).  The probe is therefore REQUIRED, not optional - its `xnu_live_abt_vmfkrv_*` row names the cause
# the tree discards.

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
CHECK=tools/check_1025_capture.py
PATCH=tools/patch_d13_ustack_probe.py
TRAP_OBJ=$POOL/osfmk_arm_trap.o
EXEC_OBJ=$POOL/bsd_kern_kern_exec.o

echo "== 1025: publish the discarded vm_fault return + the stack shape (POOL probe, ONE new switch STAGE90_XNU_USTACK_PROBE=1) =="
echo "-- carries the previous arm's FULL switch set (read out of $REC, never a default); ADDS STAGE90_XNU_USTACK_PROBE=1 --"

# ====================================================================================================
# 0. PRECONDITIONS: the checker must exist AND pass its own selftest; the patcher and the staging
#    wrapper must exist; the switch's four carrier sites must be present.
# ====================================================================================================
echo "-- step 0: the capture checker, the patcher and the staging wrapper are what this rung is read with --"
[[ -f $CHECK ]] || { echo "REFUSING: $CHECK does not exist. 1025's whole substance is TWO publishers the pool objects carry (trap.c's xnu_live_abt_vmfkrv=* + kern_exec.c's xnu_live_ustack_req=*); the reading of whether they reached the linked image is the CAPTURE the press produces, and $CHECK is its reader. A build that skipped this would be a record over an image whose probe the press could not read"; exit 1; }
python3 -I "$CHECK" --selftest >/dev/null || { echo "REFUSING: $CHECK --selftest did NOT pass. A checker whose own selftest fails cannot be the reading of this rung (m1015b). Do not build 1025 until the tool's selftest is green"; exit 1; }
echo "   step 0: $CHECK --selftest PASSes"
[[ -f $PATCH ]] || { echo "REFUSING: $PATCH does not exist - the tree's trap.c/kern_exec.c publishers are gated shut on CANCRO and this script stages them through that patcher"; exit 1; }
[[ -f tools/stage_d13_ustack_probe.sh ]] || { echo "REFUSING: tools/stage_d13_ustack_probe.sh does not exist (the re-checkoutable entry point for the two pool edits)"; exit 1; }
# The switch's channel: the global DEFINES block must be present, or the export below is a no-op.
grep -q 'DEFINES+=(-DSTAGE90_XNU_USTACK_PROBE=1)' tools/build_xnu_arm_kernel.sh || { echo "REFUSING: tools/build_xnu_arm_kernel.sh carries no STAGE90_XNU_USTACK_PROBE block in its global DEFINES array. The switch's channel is that array (every compile line carries it, incl. the EABI-runtime and firehose blocks, which do NOT get EXTRA_DEFINES); without it the export below reaches nothing and the pool objects keep no publisher while the record says 1 -- the records/1020-build-defect.txt shape"; exit 1; }
grep -q 'STAGE90_XNU_USTACK_PROBE' src/entry/build_entry.sh || { echo "REFUSING: src/entry/build_entry.sh does not carry STAGE90_XNU_USTACK_PROBE (ENTRY_ARM_KEYS / the arm-key case / the record writer / the link-site clause). Without all four the record cannot say which probe its pool was built with"; exit 1; }
grep -q 'STAGE90_XNU_USTACK_PROBE' scripts/preflight_boot_check.sh || { echo "REFUSING: scripts/preflight_boot_check.sh does not carry STAGE90_XNU_USTACK_PROBE in ENTRY_CFG_KEYS (+ its -z grace branch). A record key the gate does not print is a switch the next run would go out with unread"; exit 1; }
echo "   step 0: the switch's four carrier sites (kernel DEFINES, entry keys/case/writer/clause, gate key list) are present"

# ====================================================================================================
# 1. CARRY THE PREVIOUS ARM'S FULL SWITCH SET -- never a default, read out of the arm's own record.
# ====================================================================================================
[ -r "$REC" ] || { echo "FAIL: no arm record at $REC -- build 1024 first (this rung carries ITS set)"; exit 1; }
grep -q '^STAGE90_XNU_VM_MAX_SPLIT=1$' "$REC" || { echo "FAIL: $REC does not carry STAGE90_XNU_VM_MAX_SPLIT=1 -- this is not the 1024 arm, and that switch is what keeps the 1023 pthread storm away (the boot must reach launchctl to be a 1025 reading)"; exit 1; }
grep -q '^STAGE90_XNU_IOS7_TRAPS=1$' "$REC" || { echo "FAIL: $REC does not carry STAGE90_XNU_IOS7_TRAPS=1 -- this is not the 1023-derived arm (rows 15/24 must stay installed)"; exit 1; }
grep -q '^STAGE90_XNU_GENERAL_REGS=1$' "$REC" || { echo "FAIL: $REC does not carry STAGE90_XNU_GENERAL_REGS=1 -- 1021d's -msoft-float must be preserved (dropping it brings the kernel-mode NEON undef back)"; exit 1; }
grep -q '^STAGE90_XNU_UNDEF_RAISE=1$' "$REC" || { echo "FAIL: $REC does not carry STAGE90_XNU_UNDEF_RAISE=1 -- this is not the 1020b-derived arm"; exit 1; }
grep -q '^STAGE90_XNU_USTACK_PROBE=' "$REC" && { echo "FAIL: $REC already carries STAGE90_XNU_USTACK_PROBE -- this is not the fresh 1024 record this build was written against"; exit 1; }

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
EXPORTS+=("STAGE90_XNU_USTACK_PROBE=1")
echo "   carrying $(( ${#EXPORTS[@]} - 3 )) switch(es) from $REC + STAGE90_XNU_USTACK_PROBE=1"

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

# ====================================================================================================
# 2. STAGE THE TREE EDITS.  The earlier rungs' patches must still apply cleanly, then THIS rung's two
#    pool edits (trap.c + kern_exec.c).
# ====================================================================================================
echo "-- stage the tree edits (1021d/1022/1023/1024's set must already be staged, then 1025's two) --"
python3 tools/patch_d13_ios7_vmwire.py "$XNU_TREE" >/dev/null || { echo "FAIL: tools/patch_d13_ios7_vmwire.py refused or failed -- the tree is not in the state this rung was written against (run build_1024.sh first)"; exit 1; }
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
# 1020's udf-raise fix (SAME file as 1025's trap.c edit: osfmk/arm/trap.c).  It MUST be re-staged
# HERE, not assumed: it lives in trap.c's `sleh_undef`, a DIFFERENT function from the usermode
# DATA-abort arm 1025 edits, so the two compose - but a bare `git checkout -- osfmk/arm/trap.c` (a
# cleanup between rungs) reverts it silently while leaving 1025's publisher intact, and then the
# linked image's `sleh_undef` misses the raise and the INHERITED check_d13_undef_raise refuses the
# build AFTER the pool compile.  Re-stage before 1025's own edit so the composer's identity proof
# sees both directives.  (patch_d13_undef_raise.py's ALLOWED_IF_IDENTIFIERS carries
# STAGE90_XNU_USTACK_PROBE so the two edits are allowed to coexist in one file.)
python3 tools/patch_d13_undef_raise.py "$XNU_TREE" >/dev/null || { echo "FAIL: tools/patch_d13_undef_raise.py (plan) refused - 1020's udf-raise fix is not staged in trap.c"; exit 1; }
python3 tools/patch_d13_undef_raise.py "$XNU_TREE" --verify-off >/dev/null || { echo "FAIL: tools/patch_d13_undef_raise.py --verify-off did not PASS with 1025's probe in the same file - the two edits do not compose"; exit 1; }
# ...and so must 994's dyld witness (the THIRD edit in the same file, osfmk/arm/trap.c's `sleh_undef`).
# Same failure mode, same file: a cleanup `git checkout -- osfmk/arm/trap.c` reverts it, the pool
# rebuilds trap.o without the witness, and the INHERITED check_d13_dyld_witness refuses the LINKED
# image after the whole pool compile.  Its plan mode also re-proves OFF byte-identity, so a refusal
# here is a real statement about the tree, not noise.
python3 tools/patch_d13_dyld_witness.py "$XNU_TREE" >/dev/null || { echo "FAIL: tools/patch_d13_dyld_witness.py (plan) refused - 994's witness block is not staged in trap.c"; exit 1; }
python3 tools/patch_d13_dyld_witness.py "$XNU_TREE" --verify-off >/dev/null || { echo "FAIL: tools/patch_d13_dyld_witness.py --verify-off did not PASS with 1025's probe in the same file - the two edits do not compose"; exit 1; }
echo "-- $PATCH (1025: trap.c + kern_exec.c publishers) --"
python3 "$PATCH" "$XNU_TREE" || { echo "FAIL: $PATCH (plan mode) refused - the tree is not in the state this rung was written against. It writes nothing on a refusal"; exit 1; }
python3 "$PATCH" "$XNU_TREE" --apply || { echo "FAIL: $PATCH --apply refused"; exit 1; }
python3 "$PATCH" "$XNU_TREE" --apply >/dev/null || { echo "FAIL: a second --apply of $PATCH did not succeed (the idempotent no-op)"; exit 1; }
python3 "$PATCH" "$XNU_TREE" --verify-off >/dev/null || { echo "FAIL: $PATCH --verify-off did not PASS - the ON/OFF shapes are not the ones this rung declares ([[mi4-off-option-two-spellings]])"; exit 1; }
# The staged bytes themselves: exactly ONE of each gate line.
[[ $(grep -c 'xnu_live_abt_vmfkrv=' "$XNU_TREE/osfmk/arm/trap.c") == 1 ]] || { echo "FAIL: $XNU_TREE/osfmk/arm/trap.c does not carry EXACTLY 1 xnu_live_abt_vmfkrv= line - a partial or double edit"; exit 1; }
[[ $(grep -c 'xnu_live_ustack_req=' "$XNU_TREE/bsd/kern/kern_exec.c") == 1 ]] || { echo "FAIL: $XNU_TREE/bsd/kern/kern_exec.c does not carry EXACTLY 1 xnu_live_ustack_req= line - a partial or double edit"; exit 1; }
echo "   POOL: the staged trap.c/kern_exec.c carry the publishers, both files' OFF/ON proofs PASS, the inherited set still composes"

# ====================================================================================================
# 3. Export the pool switches (1024's set VERBATIM) + THIS rung's switch, BEFORE the pool build.
# ====================================================================================================
echo "-- exporting 1024's pool switch set, unchanged --"
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
# **THIS RUNG'S SWITCH, CHANNEL 1: the env variable tools/build_xnu_arm_kernel.sh reads into the global
# DEFINES array.**  Without the export the pool objects carry no publisher while the record says 1.
export STAGE90_XNU_USTACK_PROBE=1
echo "-- STAGE90_XNU_USTACK_PROBE=$STAGE90_XNU_USTACK_PROBE STAGE90_XNU_VM_MAX_SPLIT=$STAGE90_XNU_VM_MAX_SPLIT STAGE90_XNU_IOS7_TRAPS=$STAGE90_XNU_IOS7_TRAPS STAGE90_XNU_GENERAL_REGS=$STAGE90_XNU_GENERAL_REGS STAGE90_XNU_UNDEF_RAISE=$STAGE90_XNU_UNDEF_RAISE (pool DEFINES + FP flag list + asm ASFLAGS + EXTRA agree) --"
export STAGE90_XNU_HFS_ROOT_RW=$(awk -F= '$1=="STAGE90_XNU_HFS_ROOT_RW"{print $2}' "$REC")
echo "-- STAGE90_XNU_HFS_ROOT_RW=$STAGE90_XNU_HFS_ROOT_RW (the pool's hfs_vfsops.o carries the rw clear) --"
[[ -n ${STAGE90_XNU_USTACK_PROBE:-} ]] || { echo "FAIL: STAGE90_XNU_USTACK_PROBE is not exported - tools/build_xnu_arm_kernel.sh reads that ENV variable into the global DEFINES array"; exit 1; }
[[ "$EXTRA" == *"-DSTAGE90_XNU_GLOBAL_FIX=1"* ]] || { echo "FAIL: -DSTAGE90_XNU_GLOBAL_FIX=1 is NOT in EXTRA - 1015b's fix has NO record carrier; without it the retry storm returns"; exit 1; }

# 4. The asm layer.  1025 touches NO asm file.
echo "-- arm asm layer (1025 touches NO .s file) --"
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
# 5a. THE OBJECT-SIDE ASSERTIONS.  THIS rung's fingerprint is a FORMAT STRING, read by `strings`.
# ====================================================================================================
echo "-- POOL(5a): the two objects where the publishers live --"
[[ -f $TRAP_OBJ ]] || { echo "FAIL: $TRAP_OBJ is absent - the pool build did not produce trap.o"; exit 1; }
[[ -f $EXEC_OBJ ]] || { echo "FAIL: $EXEC_OBJ is absent - the pool build did not produce kern_exec.o"; exit 1; }
_t=$(strings "$TRAP_OBJ" | grep -c '^xnu_live_abt_vmfkrv=' || true)
_e=$(strings "$EXEC_OBJ" | grep -c '^xnu_live_ustack_req=' || true)
[[ "$_t" -ge 1 ]] || { echo "FAIL: $TRAP_OBJ carries NO xnu_live_abt_vmfkrv= publisher - the pool was NOT recompiled with STAGE90_XNU_USTACK_PROBE=1 (env channel) or the trap.c edit is not staged"; exit 1; }
[[ "$_e" -ge 1 ]] || { echo "FAIL: $EXEC_OBJ carries NO xnu_live_ustack_req= publisher - the pool was NOT recompiled with STAGE90_XNU_USTACK_PROBE=1 or the kern_exec.c edit is not staged"; exit 1; }
echo "   POOL(5a): trap.o carries the xnu_live_abt_vmfkrv= publisher (x$_t), kern_exec.o carries xnu_live_ustack_req= (x$_e)"

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
# 6. The ENTRY link.  build_entry.sh LINKS the pool objects and runs its OWN 1025 clause.
# ====================================================================================================
echo "-- entry link (build_entry.sh reads the pool objects and its 1025 clause refuses a record over a stale pool) --"
( cd src/entry && env -i PATH="$PATH" HOME="$HOME" "${EXPORTS[@]}" ./build_entry.sh )

# 6b. The by-value clauses on the LINKED image, before the payload is embedded.
echo "-- by value (6b): the LINKED image still carries 1024's ceiling + 1023's row 24 --"
python3 tools/check_vm_max_split.py "$ELF" --expect on >/dev/null || { echo "FAIL: the LINKED image's task map ceiling is not 0x40000000"; exit 1; }
python3 tools/check_1023_trap24.py "$ELF" --expect on >/dev/null || { echo "FAIL: the LINKED image's mach_trap_table[24] moved - 1025 must ADD nothing but the probe"; exit 1; }
echo "   6b PASS: the linked image's ceiling reads 0x40000000 and row 24 is untouched"
# The probe IS in the linked image: the two publishers' format strings must be reachable from the ELF.
_objdump_strs=$(strings "$ELF" | grep -c '^xnu_live_abt_vmfkrv=' || true)
[[ "$_objdump_strs" -ge 1 ]] || { echo "FAIL: the LINKED image carries NO xnu_live_abt_vmfkrv= string - the pool object that has it was not linked"; exit 1; }
echo "   6b PASS: the linked image carries the xnu_live_abt_vmfkrv= publisher"

# 7. The PAYLOAD rebuild.
echo "-- payload (embeds the new entry blob) --"
XNU_TREE="$XNU_TREE" STAGE90_EXTRA_CFLAGS='-DSTAGE90_XNU_ENTRY=1' ./scripts/build.sh

echo "== result =="
printf 'entry bin sha (first 8): '
sha256sum out/stage90/xnu_arm_entry.bin | cut -c1-8
echo "-- what the record carries (the press gate reads the RECORD) --"
grep -E 'STAGE90_XNU_USTACK_PROBE|STAGE90_XNU_VM_MAX_SPLIT|STAGE90_XNU_IOS7_TRAPS|STAGE90_XNU_GENERAL_REGS|STAGE90_XNU_UNDEF_RAISE' "$REC"

# **THE DECLARATION CARRIER, WRITTEN LAST.**  Exactly one line.
_b_extra=out/stage90/xnu_arm_entry-arm-extra.txt
printf 'STAGE90_XNU_GLOBAL_FIX=1 role=1025-ustack-probe\n' > "$_b_extra"
echo "-- 1025 wrote the declaration carrier $_b_extra:"
sed 's/^/     /' "$_b_extra"

echo "== 1025 build DONE (1024 + the failed-fault probe under STAGE90_XNU_USTACK_PROBE=1; object side at 5a, linked image at 6b, gate key at preflight). Not pressed."
echo "   Park it, then press -- the press is read by tools/check_1025_capture.py. =="