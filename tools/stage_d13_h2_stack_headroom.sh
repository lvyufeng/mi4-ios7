#!/bin/bash
# Stage 1028's H2 stack-headroom FIX into the D13 tree (experiment 1028).
#
# `external/` is a re-provisionable, gitignored checkout, so every edit this makes to it must be a
# script a re-checkout can re-apply, not a hand edit it would lose (`stage_d13_board.sh`'s rule). This
# script is the single entry point for 1028's ONE tree edit, staged by
# `tools/patch_d13_h2_stack_headroom.py`:
#   * `bsd/kern/kern_exec.c` - in `create_unix_stack`, the FIXED `mach_vm_allocate(map, &addr, size, ...)`
#     extent becomes `size + 16`, anchored so the region's EXCLUSIVE TOP moves UP by 16 (to
#     `user_stack + 16`) while the base, the block, `sp`, `p->user_stack`, and the guard math are
#     UNCHANGED.  1027 read H2 (off-the-end): the region's exclusive top IS `p->user_stack`, and
#     `exec_copyout_strings` places the initial argv/env block with its top ALSO at `p->user_stack`, so
#     the word at the top is unowned and userspace's touch faults.  docs/1028-design.md.
#
# WHY THIS IS A BUILD-LAYER EDIT.  kern_exec.c is a POOL object (bsd_kern_kern_exec.o); the switch rides
# the GLOBAL `DEFINES` array in `tools/build_xnu_arm_kernel.sh` (the array every compile line carries) -
# NOT `EXTRA_DEFINES` alone (the EABI-runtime and firehose blocks do not get EXTRA;
# records/1020-build-defect.txt).  The pool MUST be rebuilt (`build_1028.sh` runs
# `tools/build_xnu_arm_kernel.sh`) or the linked image keeps the old object and the fix is absent while
# the record says it is on.
#
# Switch OFF compiles the file byte for byte: the fix is wholly inside its `#if defined(X) && X` gate
# (`defined()` is checked FIRST), so an unset switch leaves the ORIGINAL `mach_vm_allocate` call exactly
# as before ([[mi4-off-option-two-spellings]]).  `--verify-off` proves BOTH arms BY TEXT: OFF -> the
# `#else` arm carries the ORIGINAL call, ON -> the guarded arm carries `size + 16`.
#
# THE SHARED KERN_EXEC.C NAMESPACE ([[mi4-one-file-many-rungs]]).  THREE rungs edit
# `bsd/kern/kern_exec.c` (1025 ustack_probe / 1026 abt_entry_probe / 1028 this one).  A cleanup
# `git checkout -- kern_exec.c` reverts the others SILENTLY, so `build_1028.sh` RE-STAGES all of them in
# order and every kern_exec.c patcher's allow-set carries the other switches.  This script stages ONLY
# 1028's edit; the composition is the build script's job.
#
# Idempotent: the patcher decides before writing, asserts the anchor's occurrence count exactly,
# REFUSES (untouched) on a partial/double edit or a foreign STAGE90 identifier, and a second `--apply` is
# a no-op that SUCCEEDS (the build script calls it twice).
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$HERE/.." && pwd)
XNU=${XNU_TREE:-$REPO_ROOT/external/xnu-hd2-darwin13/xnu}

f=bsd/kern/kern_exec.c
[[ -f $XNU/$f ]] || { echo "stage_d13_h2_stack_headroom: no $f in $XNU (D13 tree not provisioned?)" >&2; exit 2; }

python3 "$HERE/patch_d13_h2_stack_headroom.py" "$XNU"
python3 "$HERE/patch_d13_h2_stack_headroom.py" "$XNU" --apply
python3 "$HERE/patch_d13_h2_stack_headroom.py" "$XNU" --apply >/dev/null   # idempotent no-op
python3 "$HERE/patch_d13_h2_stack_headroom.py" "$XNU" --verify-off

echo "stage_d13_h2_stack_headroom: done (XNU=$XNU)"
echo "stage_d13_h2_stack_headroom: NOW RE-RUN tools/build_xnu_arm_kernel.sh with STAGE90_XNU_H2_STACK_HEADROOM=1 exported (it reads that ENV variable into the global DEFINES at the 1028 switch block) - build_entry.sh only LINKS the pool objects, so without the rebuild the linked image keeps the old kern_exec.o and the fix never appears"