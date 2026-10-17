#!/bin/bash
# Stage 1024's user-map ceiling fix into the D13 tree (experiment 1024).
#
# `external/` is a re-provisionable, gitignored checkout, so every edit this makes to it must be a
# script a re-checkout can re-apply, not a hand edit it would lose (`stage_d13_board.sh`'s rule). This
# script is the single entry point for 1024's ONE tree edit:
#   * `osfmk/mach/arm/vm_param.h` - `patch_d13_vm_max_split.py`: the `VM_MAX_ADDRESS` split branch
#     (:63) gains ` || (defined(STAGE90_XNU_VM_MAX_SPLIT) && STAGE90_XNU_VM_MAX_SPLIT)`, so with
#     `-DSTAGE90_XNU_VM_MAX_SPLIT=1` CANCRO gets `VM_MAX_ADDRESS = 0x40000000` - the ceiling the
#     hardware actually has (`set_mmu_ttbcr(2)`, arm_vm_init.c:475: TTBR0 is exactly 1 GiB) and the
#     one the header's own comment demands ("Ordinary user allocations must stay below the
#     kernel-owned commpage at 0x40000000").  Without it the armed 1023 kernel links
#     `vm_map_create(pmap, 0, 0x80000000, ...)` in `task_create_internal` (80085cf0 `mov r2,
#     #-2147483648`), the FIRST anywhere-allocation in launchd lands above the split, and every
#     access to it walks TTBR1 (the KERNEL's empty tree) for ever: 1023's ~2^20-iteration
#     data-abort loop on `ldr r0,[r5,#8]` at `_pthread_create+0xbc` with `r5 = 0x40083000`.
#
# WHY ONE HEADER LINE IS A BUILD-LAYER EDIT.  `vm_param.h` is included by every kernel object that
# creates or bounds a user map (`task.c`'s `task_create_internal`, vm_map.c, mach_vm.c, ...), so the
# switch rides the GLOBAL `DEFINES` array in `tools/build_xnu_arm_kernel.sh` (the array every compile
# line carries) - NOT `EXTRA_DEFINES` (the EABI-runtime and firehose blocks do not get it) and NOT an
# assembly ASFLAGS entry (the whole VM_MAX_ADDRESS block is inside `#ifndef __ASSEMBLER__`; the
# assembly layer is unaffected, but `build_1024.sh` still re-runs `assemble_arm_layer.sh` to keep the
# layer's own OFF byte-identity claim on the standing footing).  `build_entry.sh` only LINKS the pool
# objects, so without the re-run of `tools/build_xnu_arm_kernel.sh` the linked image keeps the old
# ceiling and the patch is invisible (`records/1020-build-defect.txt`).
#
# Switch OFF compiles the tree's original condition byte for byte: the appended clause is
# ` || (defined(STAGE90_XNU_VM_MAX_SPLIT) && STAGE90_XNU_VM_MAX_SPLIT)`, so `defined()` is checked
# FIRST and an unset switch leaves the `#if` exactly as before - the `mi4-off-option-two-spellings`
# guard.  `--verify-off` proves BOTH arms with the REAL preprocessor (the file includes nothing, so a
# self-contained probe TU includes it directly): OFF -> 0x80000000, ON -> 0x40000000.
#
# The LINKED-image reading is `tools/check_vm_max_split.py <elf> --expect on|off` (the `mov r2,#imm`
# that feeds `vm_map_create` inside `task_create_internal`); the 1023 image is its OFF control.
#
# Idempotent: the patcher decides the gate before writing, asserts the anchor's occurrence count
# exactly, REFUSES (file untouched) on a partial/double edit, and a second run prints "already staged"
# and writes nothing.  A failed ON/OFF proof reverts the write.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$HERE/.." && pwd)
XNU=${XNU_TREE:-$REPO_ROOT/external/xnu-hd2-darwin13/xnu}

f=osfmk/mach/arm/vm_param.h
[[ -f $XNU/$f ]] || {
    echo "stage_d13_vm_max_split: no $f in $XNU (D13 tree not provisioned?)" >&2; exit 2; }

python3 "$HERE/patch_d13_vm_max_split.py" "$XNU"
python3 "$HERE/patch_d13_vm_max_split.py" "$XNU" --apply

echo "stage_d13_vm_max_split: done (XNU=$XNU)"
echo "stage_d13_vm_max_split: NOW RE-RUN tools/build_xnu_arm_kernel.sh with STAGE90_XNU_VM_MAX_SPLIT=1 exported (it reads that ENV variable into the global DEFINES at the 1024 switch block) - build_entry.sh only LINKS the pool objects, so without the rebuild the linked image keeps 0x80000000"