#!/usr/bin/env bash
# Build 1024: 1023 PLUS THE USER-MAP CEILING -- make `VM_MAX_ADDRESS` agree with the hardware's 1 GiB
# TTBR0 split (`0x80000000` -> `0x40000000`) under ONE new switch, STAGE90_XNU_VM_MAX_SPLIT=1, which
# widens `osfmk/mach/arm/vm_param.h:63`'s split branch (staged by tools/patch_d13_vm_max_split.py).
#
# WHY.  records/1023-press-read.txt: the 1023 press moved the wall -- trap 24 IS dispatched,
# `IOS7LAB trap24 frame` x4, `mach_port_construct` returns 0 x4 -- and pid 1 then dies in a
# ~1,048,577-iteration DATA-ABORT LOOP on `ldr r0,[r5,#8]` at `_pthread_create+0xbc`
# (abt_pc 0x38241790 + slide, libsystem_pthread.dylib) with abt_far 0x40083008 and abt_ptel2 = 0
# (the walk finds an empty L2 slot).  By value the mechanism is a ONE-VALUE DISAGREEMENT:
#
#   hardware:  `set_mmu_ttbcr(2)` (d13 osfmk/arm/arm_vm_init.c:475) gives TTBR0 exactly 1 GiB --
#              [0, 0x40000000); every VA at/above 0x40000000 is walked through TTBR1 (the KERNEL's
#              tree, cpu_ttb), so everything in [0x40000000, 0x80000000) is unreachable for user pages;
#   kernel:    `task_create_internal` links `vm_map_create(pmap, 0, VM_MAX_ADDRESS, TRUE, ...)` with
#              VM_MAX_ADDRESS = 0x80000000 -- MEASURED in the armed 1023 ELF at 80085cf0
#              `mov r2, #-2147483648` then 80085cfc `bl vm_map_create` -- because this tree's
#              vm_param.h:62-68 compiles the `#else` branch on CANCRO.
#
# So launchd's first big anywhere-allocation (pthread_create's stack mmap, out-param 1 of
# __pthread_allocate_stack) was placed ABOVE the split, `vm_fault` "succeeded" into a tree the
# hardware never walks for that VA, and the load faulted for ever.  The header's OWN comment states
# the rule the port was breaking: "This ARM pmap uses a 1 GiB TTBR0 split.  Ordinary user allocations
# must stay below the kernel-owned commpage at 0x40000000."
#
# THE FIX SHAPE.  One whole-line header edit: vm_param.h:63
#   `#if BOARD_CONFIG_ARMPBA8 || BOARD_CONFIG_QSD8250_LEO`
# ->`#if BOARD_CONFIG_ARMPBA8 || BOARD_CONFIG_QSD8250_LEO || (defined(STAGE90_XNU_VM_MAX_SPLIT) && STAGE90_XNU_VM_MAX_SPLIT)`
# `defined()` FIRST, so OFF compiles the tree's original condition byte for byte
# ([[mi4-off-option-two-spellings]]).  Why a switch and not BOARD_CONFIG_MSM8974_CANCRO: the board
# macro would flip EVERY gate keyed on the board names across the tree (traps_lo.s's -3 SWI routing,
# ios7_compat.h's ios7_compat_vmabi_enabled(), ...) -- not a one-value change; the port's idiom is one
# switch per fix.
#
# **THE CHANNEL IS THE GLOBAL `DEFINES` ARRAY OF tools/build_xnu_arm_kernel.sh, NOT `EXTRA_DEFINES`.**
# `vm_param.h` is a HEADER included by every TU that bounds a user map (task.c, vm_map.c, mach_vm.c,
# ...), and the EABI-runtime (~:1818) and firehose (~:1860) blocks expand `${DEFINES[@]}` but NOT
# `${EXTRA_DEFINES[@]}` -- a build that put the switch only in EXTRA would compile those TUs with the
# OLD ceiling behind a green build ([[mi4-one-value-two-definitions]]).  So step 3 EXPORTS the env
# variable the new block at :994 reads, and the EXTRA derivation below SKIPS the key.
#
# **THE CARRIERS.**  (1) tools/build_xnu_arm_kernel.sh:994, env-read into DEFINES (asserted in step 0
# by grep, in step 3 by the export, in step 5a BY VALUE on `osfmk_kern_task.o`'s own
# `task_create_internal`).  (2) build_entry.sh: the switch is in `ENTRY_ARM_KEYS`, its arm-key `case`,
# the record writer, and a link-site clause that runs tools/check_vm_max_split.py on the pool object
# in BOTH directions -- so a record-over-a-stale-pool is a REFUSAL, not a promise.  (3)
# preflight_boot_check.sh: `ENTRY_CFG_KEYS` + a `-z` grace branch (a pre-1024 record's only possible
# value is 0 -- the tree's `#else`).  (4) -DSTAGE90_XNU_GLOBAL_FIX=1 in EXTRA (no record carrier --
# records/1020-build-defect.txt).  (5) arm-extra carrier written LAST:
# `STAGE90_XNU_GLOBAL_FIX=1 role=1024-vm-max-split`.
#
# **THE BY-VALUE CLAUSES (docs/1024-design.md sections 3-4).**  `tools/check_vm_max_split.py` reads
# `task_create_internal`'s `mov r2,#<ceiling>` that feeds `bl vm_map_create`, resolving both ends by
# NAME from the symbol table: `--expect off` (0x80000000) is the negative control the shipped 1023
# image satisfies; `--expect on` (0x40000000) is this rung.  It runs on the pool OBJECT (5a), on the
# LINKED image before the payload (6b) -- and again inside build_entry.sh's own 1024 clause at the
# link, which refuses a record whose switch disagrees with the object it links.
set -euo pipefail
cd "$(dirname "$0")/.."

# ====================================================================================================
# ARGUMENTS.  `--resume-after-pool-build <log>` skips the (expensive) pool rebuild -- the
# build_1021d.sh/build_1023.sh pattern.  Clauses 5a/5b below then read the objects on disk LIVE.
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
PLATFORM_POOL=out/xnu_platform_obj_d13
MANIFEST=out/xnu_arm_manifest_d13.txt
ELF=out/stage90/xnu_arm_entry.elf
CHECK=tools/check_vm_max_split.py
PATCH=tools/patch_d13_vm_max_split.py
TASK_OBJ=$POOL/osfmk_kern_task.o

echo "== 1024: make VM_MAX_ADDRESS agree with set_mmu_ttbcr(2) (0x80000000 -> 0x40000000, POOL header edit + one new switch) =="
echo "-- carries the previous arm's FULL switch set (read out of $REC, never a default); ADDS STAGE90_XNU_VM_MAX_SPLIT=1 --"

# ====================================================================================================
# 0. PRECONDITIONS: the by-value tool must exist AND pass its own selftest (a checker whose selftest
#    cannot fail is the m1015b lesson).  The patcher and the staging wrapper must exist.
# ====================================================================================================
echo "-- step 0: the by-value tool and the two staging scripts are what this rung is read with --"
[[ -f $CHECK ]] || { echo "REFUSING: $CHECK does not exist. The fix's whole substance is ONE immediate in the linked image (the VM_MAX_ADDRESS word task_create_internal passes to vm_map_create), so reading that word off the ELF is the only reading of whether the ceiling moved -- and there is no other check -- a build that skipped this would be a record over an image whose user map still reaches 0x80000000 while the hardware walks TTBR1 above 0x40000000 ([[mi4-a-claim-in-a-comment-is-not-a-check]]). CLI: <elf-or-.o> --expect on|off | --selftest"; exit 1; }
python3 "$CHECK" --selftest >/dev/null || { echo "REFUSING: $CHECK --selftest did NOT pass. A checker whose own selftest fails cannot be the reading of this rung (m1015b). Do not build 1024 until the tool's selftest is green"; exit 1; }
echo "   step 0: $CHECK --selftest PASSes"
[[ -f $PATCH ]] || { echo "REFUSING: $PATCH does not exist - the tree's vm_param.h:63 branch is gated shut on CANCRO and this script stages it through that patcher"; exit 1; }
[[ -f tools/stage_d13_vm_max_split.sh ]] || { echo "REFUSING: tools/stage_d13_vm_max_split.sh does not exist (the re-checkoutable entry point for the header edit)"; exit 1; }
# The switch's channel: the global DEFINES block must be present, or every export below is a no-op.
grep -q 'DEFINES+=(-DSTAGE90_XNU_VM_MAX_SPLIT=1)' tools/build_xnu_arm_kernel.sh || { echo "REFUSING: tools/build_xnu_arm_kernel.sh carries no STAGE90_XNU_VM_MAX_SPLIT block in its global DEFINES array. The switch's channel is that array (every compile line carries it, incl. the EABI-runtime and firehose blocks, which do NOT get EXTRA_DEFINES); without it the export below reaches nothing and the pool keeps the old ceiling while every record says 1 -- the records/1020-build-defect.txt shape"; exit 1; }
grep -q 'STAGE90_XNU_VM_MAX_SPLIT' src/entry/build_entry.sh || { echo "REFUSING: src/entry/build_entry.sh does not carry STAGE90_XNU_VM_MAX_SPLIT (ENTRY_ARM_KEYS / the arm-key case / the record writer / the link-site clause). Without all four the record cannot say which ceiling its pool was built with, which is the 533 defect"; exit 1; }
grep -q 'STAGE90_XNU_VM_MAX_SPLIT' scripts/preflight_boot_check.sh || { echo "REFUSING: scripts/preflight_boot_check.sh does not carry STAGE90_XNU_VM_MAX_SPLIT in ENTRY_CFG_KEYS (+ its -z grace branch). A record key the gate does not print is a switch the next run would go out with unread (the converse check refuses it by design)"; exit 1; }
echo "   step 0: the switch's four carrier sites (kernel DEFINES, entry keys/case/writer/clause, gate key list) are present"

# ====================================================================================================
# 1. CARRY THE PREVIOUS ARM'S FULL SWITCH SET -- never a default
#    ([[mi4-build-variant-comes-from-an-env-default]]), read out of the arm's own record.
# ====================================================================================================
[ -r "$REC" ] || { echo "FAIL: no arm record at $REC -- build 1023 first (this rung carries ITS set)"; exit 1; }
grep -q '^STAGE90_XNU_IOS7_TRAPS=1$' "$REC" || { echo "FAIL: $REC does not carry STAGE90_XNU_IOS7_TRAPS=1 -- this is not 1023's arm, and that switch is what keeps rows 15/24 installed"; exit 1; }
grep -q '^STAGE90_XNU_GENERAL_REGS=1$' "$REC" || { echo "FAIL: $REC does not carry STAGE90_XNU_GENERAL_REGS=1 -- this is not 1022's arm (1021d's -msoft-float must be preserved: dropping it brings the kernel-mode NEON undef back)"; exit 1; }
grep -q '^STAGE90_XNU_UNDEF_RAISE=1$' "$REC" || { echo "FAIL: $REC does not carry STAGE90_XNU_UNDEF_RAISE=1 -- this is not the 1020b-derived arm"; exit 1; }
grep -q '^STAGE90_XNU_VM_MAX_SPLIT=' "$REC" && { echo "FAIL: $REC already carries STAGE90_XNU_VM_MAX_SPLIT -- this is not the fresh 1023 record this build was written against (use build_1024b.sh for a rebuild of the same arm, not this script)"; exit 1; }

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
# **THIS RUNG'S ONE NEW SWITCH.**  It rides the entry build's environment so (a) the record writer
# (build_entry.sh) carries it, (b) the arm-key comparison sees it, and (c) the 1024 link-site clause
# can read `osfmk_kern_task.o` against it.  The pool build gets it by direct export in step 3.
EXPORTS+=("STAGE90_XNU_VM_MAX_SPLIT=1")
echo "   carrying $(( ${#EXPORTS[@]} - 3 )) switch(es) from $REC + STAGE90_XNU_VM_MAX_SPLIT=1"

# ---- the -D set (EXTRA == XNU_KERNEL_EXTRA_DEFINES; the 1015b pattern) ------------------------------
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
    # **1024's switch is carried by the GLOBAL DEFINES array (the env variable build_xnu_arm_kernel.sh
    # reads at :994), NOT by EXTRA**: EXTRA is expanded by the per-file and platform compile lines only,
    # so a build whose ONLY channel was EXTRA would leave the EABI-runtime and firehose TUs on the old
    # ceiling ([[mi4-one-value-two-definitions]]).  Skipped here also so a future record that carries
    # the key cannot create the two-spellings state (env 0 / EXTRA 1) this rung exists to prevent.
    STAGE90_XNU_VM_MAX_SPLIT) continue ;;
  esac
  [[ $k == STAGE90_* ]] || continue
  case $v in
    0|1) ;;
    0x*|[0-9]*) ;;
    *) continue ;;
  esac
  EXTRA="$EXTRA -D$k=$v"
done < "$REC"
# **1015b's GLOBAL-FIX TOKEN, WHICH HAS NO RECORD CARRIER.**  `STAGE90_XNU_GLOBAL_FIX` is a POOL switch
# whose ONLY channel is this EXTRA token; a build that derives EXTRA from the record alone compiles the
# fix OUT and the retry storm returns (records/1020-build-defect.txt -- the 1020 defect 1020b repaired).
EXTRA="$EXTRA -DSTAGE90_XNU_GLOBAL_FIX=1"
EXTRA=${EXTRA# }
echo "-- extra defines: $EXTRA --"
[[ "$EXTRA" != *"-DSTAGE90_XNU_VM_MAX_SPLIT"* ]] || { echo "FAIL: -DSTAGE90_XNU_VM_MAX_SPLIT is in EXTRA ('$EXTRA') -- its channel is the global DEFINES array; in EXTRA alone the EABI-runtime and firehose blocks compile the old ceiling"; exit 1; }

# ====================================================================================================
# 2. STAGE THE TREE EDITS.  The earlier rungs' patches must still apply cleanly (this rung edits a
#    different FILE -- vm_param.h -- but the composition guarantee below keeps the whole staged set
#    honest), then this rung's header edit.
# ====================================================================================================
echo "-- stage the tree edits --"
# **CHECK ORDER IS LOAD-BEARING** (the 1023 comment): vmwire's inner-guard close anchor is the trap-15
# map trap's `done:` tail, and the trap-ports patcher edits the same region.  Run the whole chain in
# build_1023.sh's order, plan-first.
python3 tools/patch_d13_ios7_vmwire.py "$XNU_TREE" >/dev/null || { echo "FAIL: tools/patch_d13_ios7_vmwire.py refused or failed -- the tree is not in the state this rung was written against (run build_1023.sh first)"; exit 1; }
grep -qF 'ios7_traps_enabled' "$XNU_TREE/osfmk/arm/ios7_compat.h" || { echo "FAIL: $XNU_TREE/osfmk/arm/ios7_compat.h carries no ios7_traps_enabled() -- vmwire's selector is not staged"; exit 1; }

# **THE 994 CHECKER'S DEFERRAL TUPLE MUST STILL BE (25, 41, 42) -- 1023 dropped 24, this rung opens
# no further row.**  A tuple still containing 24 would make the entry build refuse at check 6.
grep -qE '^DEFERRED_TRAPS = \(25, 41, 42\)' tools/check_d13_ios7_vmwire.py || {
  echo "FAIL: tools/check_d13_ios7_vmwire.py's DEFERRED_TRAPS is not \`(25, 41, 42)\`. 1023 opens"
  echo "      trap 24; this rung opens none. docs/1023-port-construct-trap24-design.md section 8."
  exit 1; }
echo "   (check_d13_ios7_vmwire.py DEFERRED_TRAPS == (25, 41, 42): unchanged by this rung)"

echo "-- the 1022/1023 patches (must already be staged; this rung adds only the header edit) --"
python3 tools/patch_d13_mach_trap15.py "$XNU_TREE" >/dev/null || { echo "FAIL: tools/patch_d13_mach_trap15.py refused - 1022's widenings are not staged"; exit 1; }
python3 tools/patch_d13_mach_trap15.py "$XNU_TREE" --apply >/dev/null || { echo "FAIL: tools/patch_d13_mach_trap15.py --apply failed"; exit 1; }
python3 tools/patch_d13_mach_trap_ports.py "$XNU_TREE" >/dev/null || { echo "FAIL: tools/patch_d13_mach_trap_ports.py refused - 1023's row-24 edits are not staged"; exit 1; }
python3 tools/patch_d13_mach_trap_ports.py "$XNU_TREE" --apply >/dev/null || { echo "FAIL: tools/patch_d13_mach_trap_ports.py --apply failed"; exit 1; }
python3 tools/patch_d13_mach_trap_ports.py "$XNU_TREE" --apply >/dev/null || { echo "FAIL: a second --apply of tools/patch_d13_mach_trap_ports.py did not succeed"; exit 1; }
python3 tools/patch_d13_mach_trap_ports.py "$XNU_TREE" --verify-off >/dev/null || { echo "FAIL: tools/patch_d13_mach_trap_ports.py --verify-off did not PASS on the staged tree"; exit 1; }
# **THE COMPOSITION GUARANTEE (records/1023-patcher-composition.txt)** -- kept: after the whole set is
# staged, 1022's own patcher must still accept the tree.
python3 tools/patch_d13_mach_trap15.py "$XNU_TREE" >/dev/null || { echo "FAIL: after the staged set, tools/patch_d13_mach_trap15.py REFUSES the tree - the composition fix (records/1023-patcher-composition.txt) is not in effect: its whole-file gate count is a TOTAL, not a PROPERTY"; exit 1; }
grep -qF 'IOS7LAB trap24 frame' "$XNU_TREE/osfmk/ipc/mach_kernelrpc.c" || { echo "FAIL: the staged mach_kernelrpc.c carries NO \`IOS7LAB trap24 frame\` dump - 1023's dispute-resolver is absent from the tree this rung inherits, so the press could not decide the trap-24 wire question 1023 settled"; exit 1; }

# **THIS RUNG'S TREE EDIT.**  vm_param.h is a HEADER with no includes (pure preprocessor + #defines),
# so the patcher's two-arm proof runs the REAL preprocessor over a probe TU that includes it directly:
# OFF -> 0x80000000, ON -> 0x40000000.  Plan first (must refuse nothing on THIS tree), then apply (the
# proof runs BEFORE the write and the write is REVERTED on a failed proof), then a second apply must
# be a no-op, then --verify-off re-proves both arms on the file as it lies on disk.
echo "-- $PATCH (1024: widen vm_param.h:63's split branch with the switch) --"
python3 "$PATCH" "$XNU_TREE" || { echo "FAIL: $PATCH (plan mode) refused - the tree is not in the state this rung was written against (a displaced anchor, a partial edit, or a hand-edited region). It writes nothing on a refusal"; exit 1; }
python3 "$PATCH" "$XNU_TREE" --apply || { echo "FAIL: $PATCH --apply refused. The two-arm preprocessor proof runs BEFORE the write and reverts on failure, so a refusal here means an OFF arm does not reproduce the tree byte for byte"; exit 1; }
python3 "$PATCH" "$XNU_TREE" --apply >/dev/null || { echo "FAIL: a second --apply of $PATCH did not succeed"; exit 1; }
python3 "$PATCH" "$XNU_TREE" --verify-off >/dev/null || { echo "FAIL: $PATCH --verify-off did not PASS on the staged tree - the ON/OFF shapes are not the ones this rung declares ([[mi4-off-option-two-spellings]])"; exit 1; }
# The staged bytes themselves: exactly ONE widened gate line, and the anchor above it untouched.
[[ $(grep -c 'BOARD_CONFIG_ARMPBA8 || BOARD_CONFIG_QSD8250_LEO || (defined(STAGE90_XNU_VM_MAX_SPLIT) && STAGE90_XNU_VM_MAX_SPLIT)' "$XNU_TREE/osfmk/mach/arm/vm_param.h") == 1 ]] || { echo "FAIL: $XNU_TREE/osfmk/mach/arm/vm_param.h does not carry EXACTLY 1 widened gate line - a partial or double edit"; exit 1; }
grep -qF 'Ordinary user allocations must' "$XNU_TREE/osfmk/mach/arm/vm_param.h" || { echo "FAIL: the staged vm_param.h lost the split-branch comment (the anchor this patch was written for)"; exit 1; }
echo "   POOL: the staged vm_param.h carries the widened :63 gate, both preprocessor proofs PASS, the 1022/1023 set still composes"

# ====================================================================================================
# 3. Export the pool switches + the env-carried tree-layout define, BEFORE the pool/platform build.
# ====================================================================================================
echo "-- HFS (the port is on, hfs files join the pool) --"
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
# **1021d'S FLAG SWITCH, CARRIED UNCHANGED.**  Its channel is the FP flag list, NOT a `-D`; dropping it
# brings the kernel-mode NEON undef back (records/1021-fpu-rootcause.txt).
export STAGE90_XNU_GENERAL_REGS=1
# **THIS RUNG'S SWITCH, CHANNEL 1: the env variable tools/build_xnu_arm_kernel.sh:994 reads into the
# GLOBAL DEFINES array.**  Without the export EVERY object that includes vm_param.h (the whole pool)
# is recompiled with the tree's `#else` ceiling and the linked image keeps 0x80000000 -- and NOTHING
# in the entry build would notice on its own, because build_entry.sh only LINKS the pool
# (`records/1020-build-defect.txt`); the 1024 link-site clause and this script's 5a/6b readings exist
# precisely to turn that silent state into a refusal.
export STAGE90_XNU_VM_MAX_SPLIT=1
echo "-- STAGE90_XNU_VM_MAX_SPLIT=$STAGE90_XNU_VM_MAX_SPLIT STAGE90_XNU_IOS7_TRAPS=$STAGE90_XNU_IOS7_TRAPS STAGE90_XNU_GENERAL_REGS=$STAGE90_XNU_GENERAL_REGS STAGE90_XNU_UNDEF_RAISE=$STAGE90_XNU_UNDEF_RAISE (pool DEFINES + the FP flag list + asm ASFLAGS + EXTRA agree) --"
export STAGE90_XNU_HFS_ROOT_RW=$(awk -F= '$1=="STAGE90_XNU_HFS_ROOT_RW"{print $2}' "$REC")
echo "-- STAGE90_XNU_HFS_ROOT_RW=$STAGE90_XNU_HFS_ROOT_RW (the pool's hfs_vfsops.o carries the rw clear) --"

# **THE CHANNEL PRECONDITION, ASSERTED AT THE SITE THAT ESTABLISHES IT.**  The switch's ONE pool
# channel is this env variable (asserted NOT in EXTRA above); the by-value reading of whether the
# channel worked is step 5a's clause on `osfmk_kern_task.o`.
[[ -n ${STAGE90_XNU_VM_MAX_SPLIT:-} ]] || { echo "FAIL: STAGE90_XNU_VM_MAX_SPLIT is not exported - tools/build_xnu_arm_kernel.sh:994 reads that ENV variable into the global DEFINES array, so without it the whole pool is recompiled with the OLD ceiling while the record says 1 (the 1010 lesson: an absent effect whose channel was wrong)"; exit 1; }
[[ "$EXTRA" == *"-DSTAGE90_XNU_GLOBAL_FIX=1"* ]] || { echo "FAIL: -DSTAGE90_XNU_GLOBAL_FIX=1 is NOT in EXTRA ('$EXTRA') - 1015b's fix has NO record carrier (records/1020-build-defect.txt); without this token the retry storm returns and the run stops on the storm, not on anything 1024 is about"; exit 1; }
echo "   the ceiling switch's pool channel (env -> the global DEFINES array) is live, and GLOBAL_FIX is in EXTRA"

# 4. The asm layer.  1024 touches NO asm file (the whole VM_MAX_ADDRESS block is inside
#    `#ifndef __ASSEMBLER__`) -- the layer is re-run so its own OFF byte-identity claim stays on the
#    standing footing, exactly as every rung since 994 has.
echo "-- arm asm layer (1024 touches NO .s file: vm_param.h's block is outside __ASSEMBLER__) --"
XNU_TREE="$XNU_TREE" XNU_KERNEL_CONFIG=STAGE90_XNU tools/assemble_arm_layer.sh

# 5. The POOL build -- the change is a HEADER every pool TU includes, so the pool MUST be rebuilt or
#    the linked image keeps the old ceiling (build_entry.sh only LINKS the objects).
echo "-- the D13 kernel pool + platform block, recompiled (EVERY object that includes vm_param.h moves) --"
if [[ -n $RESUME_LOG ]]; then
  echo "   RESUME: SKIPPING the pool rebuild -- the first run rebuilt the pool before dying later."
  echo "   Clauses 5a/5b below read the objects on disk LIVE."
else
  XNU_TREE="$XNU_TREE" \
  XNU_KERNEL_CONFIG=STAGE90_XNU \
  XNU_MASTER_LOCAL="$PWD/tools/xnu_config/boot/STAGE90_XNU.local" \
  XNU_KERNEL_EXTRA_DEFINES="$EXTRA" \
      ./tools/build_xnu_arm_kernel.sh
fi

# ====================================================================================================
# 5a. THE OBJECT-SIDE ASSERTIONS.  THIS rung's fingerprint is an INSTRUCTION, read by value.
# ====================================================================================================
echo "-- POOL(5a): the object where the ceiling becomes an instruction --"
[[ -f $TASK_OBJ ]] || { echo "FAIL: $TASK_OBJ is absent - the pool build did not produce task.o (task_create_internal's file)"; exit 1; }
# (a) BY VALUE: task_create_internal's vm_map_create max argument must read 0x40000000.  A stale pool
#     (or a pool built without the env export) keeps 0x80000000 and refuses HERE, on the object, before
#     the link -- which is the earliest by-value site the defect can be caught.
python3 "$CHECK" "$TASK_OBJ" --expect on || { echo "FAIL: $TASK_OBJ's task_create_internal does NOT pass 0x40000000 to vm_map_create - the pool was NOT recompiled with STAGE90_XNU_VM_MAX_SPLIT=1 (env channel) or the header edit is not staged. A build that linked this pool would carry the 1023 storm's mechanism with a record that says it was fixed"; exit 1; }
echo "   POOL(5a): $TASK_OBJ's task_create_internal carries the 0x40000000 ceiling (read from the object's own instruction)"
# (b) the 1023 row is untouched by this rung: the same object set still relocates row 24's handler and
#     leaves rows 25/41/42 bare (a widened gate that displaced a neighbour fails HERE, not at the press).
SSW_OBJ=$POOL/osfmk_kern_syscall_sw.o
[[ -f $SSW_OBJ ]] || { echo "FAIL: $SSW_OBJ is absent - the pool build did not produce syscall_sw.o (the trap table)"; exit 1; }
[[ $(grep -c 'IOS7_COMPAT_PLATFORM || (defined(STAGE90_XNU_IOS7_TRAPS) && STAGE90_XNU_IOS7_TRAPS)' "$XNU_TREE/osfmk/kern/syscall_sw.c") == 3 ]] || { echo "FAIL: $XNU_TREE/osfmk/kern/syscall_sw.c does not carry EXACTLY 3 widened gates (the extern block + row 15 + row 24) - 1024 inherits 1023's set and must not disturb it"; exit 1; }
[[ $(grep -c '^#if IOS7_COMPAT_PLATFORM$' "$XNU_TREE/osfmk/kern/syscall_sw.c") == 2 ]] || { echo "FAIL: $XNU_TREE/osfmk/kern/syscall_sw.c does not carry EXACTLY 2 bare gates (rows 25/41/42) - the deferred rows must stay closed"; exit 1; }
echo "   POOL(5a): syscall_sw.c still has 3 widened gates (extern + row 15 + row 24) and 2 bare gates (rows 25/41/42)"

# ====================================================================================================
# 5b. THE GLOBAL-FIX BY-VALUE CLAUSE -- KEPT FROM build_1021d.sh:365-373 (this is a POOL-rebuild rung).
# ====================================================================================================
gf_obj=$POOL/osfmk_arm_pmap.o
[[ -f $gf_obj ]] || { echo "FAIL: $gf_obj is absent - the 1024 pool build did not produce the pmap object 1015b's fix lives in"; exit 1; }
_gf_kp=$(arm-none-eabi-objdump -r "$gf_obj" 2>/dev/null | awk '$1>="00000418" && $1<="00000640"' | grep -c 'MOVW_ABS_NC.*kernel_pmap' || true)
_gf_full=$(arm-none-eabi-objdump -r "$gf_obj" 2>/dev/null | awk '$1>="00000418" && $1<="00000640"' | grep -c 'R_ARM_CALL.*arm_tlb_flushID$' || true)
_gf_asid=$(arm-none-eabi-objdump -r "$gf_obj" 2>/dev/null | awk '$1>="00000418" && $1<="00000640"' | grep -c 'R_ARM_CALL.*arm_tlb_flushID_ASID$' || true)
echo "   POOL(5b): kernel_pmap materializations in pmap_flush_tlbs x$_gf_kp (want 3); arm_tlb_flushID x$_gf_full, arm_tlb_flushID_ASID x$_gf_asid (want 1/1)"
[[ "$_gf_kp" == "3" ]] || { echo "FAIL: pmap_flush_tlbs materializes kernel_pmap at $_gf_kp site(s), want EXACTLY 3 -- 2 is OFF/Apple, i.e. STAGE90_XNU_GLOBAL_FIX is NOT in this pool object, so the retry storm 1015b killed is BACK and the run would stop on the storm, not on anything 1024 is about (records/1020-build-defect.txt). -DSTAGE90_XNU_GLOBAL_FIX=1 rides XNU_KERNEL_EXTRA_DEFINES ONLY"; exit 1; }
[[ "$_gf_full" == "1" && "$_gf_asid" == "1" ]] || { echo "FAIL: the flush arms are not the declared shape (full=$_gf_full asid=$_gf_asid, want 1/1)"; exit 1; }
echo "   POOL(5b): pmap_flush_tlbs carries the 3rd kernel_pmap materialization (1015b's fix is IN this object)"

# Also re-verify the 1020 raise and 1021d flags are still in the staged tree / objects.
python3 tools/patch_d13_undef_raise.py "$XNU_TREE" --verify-off >/dev/null || { echo "FAIL: tools/patch_d13_undef_raise.py --verify-off did not PASS - the udf raise this whole ladder rests on is not in the staged tree"; exit 1; }
[[ -f $POOL/osfmk_arm_trap.o ]] || { echo "FAIL: $POOL/osfmk_arm_trap.o is absent - the pool build did not produce 1020's object"; exit 1; }
echo "   POOL(5b): the 1020 udf-raise and 1021d's flag arm are both still staged"

# ====================================================================================================
# 6. The ENTRY link.  build_entry.sh LINKS the freshly built pool objects and runs its OWN 1024 clause
#    (the link-site byte-identity check between this record's switch and osfmk_kern_task.o).
# ====================================================================================================
echo "-- entry link (build_entry.sh reads the pool objects it just baked, and its 1024 clause refuses a record over a stale pool) --"
( cd src/entry && env -i PATH="$PATH" HOME="$HOME" "${EXPORTS[@]}" ./build_entry.sh )

# ====================================================================================================
# 6b. THE BY-VALUE CLAUSES, CALLED AGAIN HERE, **BEFORE THE PAYLOAD IS EMBEDDED** -- so a refusal does
#     not leave a blob on disk that is the ON arm's.  Read off the LINKED image, not the `.o`.
# ====================================================================================================
echo "-- by value (6b): the LINKED image's task map ceiling must read --expect on, BEFORE the payload --"
python3 "$CHECK" "$ELF" --expect on || { echo "FAIL: $CHECK $ELF --expect on did NOT pass (see the FAIL lines above) - the linked image's task_create_internal does not carry the 0x40000000 ceiling. The pool object may have been rebuilt (5a proves the word), but the ENTRY image was linked from something else or from a STALE object: build_entry.sh only LINKS $TASK_OBJ (records/1020-build-defect.txt)"; exit 1; }
echo "   6b PASS: the linked image's task map ceiling reads 0x40000000 (== the 1 GiB TTBR0 split)"
echo "-- by value (6b): the 1023 row must be UNTOUCHED by this rung --"
python3 tools/check_1023_trap24.py "$ELF" --expect on || { echo "FAIL: tools/check_1023_trap24.py $ELF --expect on did NOT pass - this rung moved the ceiling and must ADD nothing else; row 24 (mach_port_construct) is no longer the installed handler, so the 1023 frontier would be back and the press would not be a reading of THIS rung"; exit 1; }
echo "   6b PASS: mach_trap_table[24] == &ios7lab_mach_port_construct_trap still holds (rows 25/41/42 still kern_invalid)"

# 7. The PAYLOAD rebuild (embeds the new entry blob; preflight REFUSES a payload carrying a different
#    image).
echo "-- payload (embeds the new entry blob; preflight REFUSES a payload carrying a different image) --"
XNU_TREE="$XNU_TREE" STAGE90_EXTRA_CFLAGS='-DSTAGE90_XNU_ENTRY=1' ./scripts/build.sh

echo "== result =="
printf 'entry bin sha (first 8): '
sha256sum out/stage90/xnu_arm_entry.bin | cut -c1-8
echo "   (compare against 1023's - read it from 1023's own build log or the frozen park; a MATCH would mean the ceiling reached no compiled byte, which 5a/6b already refuse)"
echo "-- what the record carries (the press gate reads the RECORD) --"
grep -E 'STAGE90_XNU_VM_MAX_SPLIT|STAGE90_XNU_IOS7_TRAPS|STAGE90_XNU_GENERAL_REGS|STAGE90_XNU_UNDEF_RAISE' "$REC"

# **THE DECLARATION CARRIER, WRITTEN LAST, FROM THE ARM THIS BUILD COMPILED -- EXACTLY ONE LINE.**
# Its content is a declaration OF A DIFFERENT BUILD the moment the arm moves
# ([[mi4-self-written-record-is-not-a-constraint]]), so the 1024 line REPLACES 1023's -- a surviving
# 1023 line would be a press reading a previous run's claim.
_b_extra=out/stage90/xnu_arm_entry-arm-extra.txt
printf 'STAGE90_XNU_GLOBAL_FIX=1 role=1024-vm-max-split\n' > "$_b_extra"
echo "-- 1024 wrote the declaration carrier $_b_extra:"
sed 's/^/     /' "$_b_extra"

echo "== 1024 build DONE (1023 + VM_MAX_ADDRESS 0x40000000 under STAGE90_XNU_VM_MAX_SPLIT=1; object side at 5a, linked image at 6b, gate key at preflight). Not pressed."
echo "   Park it, then press -- but see docs/1024-design.md section 4: the press is read by tools/check_1024_capture.py. =="