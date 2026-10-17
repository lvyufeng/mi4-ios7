#!/bin/bash
# Stage 1025's user-stack fault probe into the D13 tree (experiment 1025).
#
# `external/` is a re-provisionable, gitignored checkout, so every edit this makes to it must be a
# script a re-checkout can re-apply, not a hand edit it would lose (`stage_d13_board.sh`'s rule). This
# script is the single entry point for 1025's TWO tree edits, both staged by
# `tools/patch_d13_ustack_probe.py`:
#   * `osfmk/arm/trap.c` - the USER data-abort case's `if ((code != KERN_SUCCESS) && (code !=
#     KERN_ABORTED))` arm gains a guarded block that PRINTS the `vm_fault` return code (`code`), the
#     fault VA (`dfar`), the DFSR, the prot (read/write), the faulting pc/sp and the pid.  On CANCRO
#     the ONLY assignment of `code` is inside `#if BOARD_CONFIG_QSD8250_LEO`, so the value that NAMES
#     the launchctl[2] stack fault (0x2bdbe000) is DISCARDED today - this publishes it.
#   * `bsd/kern/kern_exec.c` - `create_unix_stack` gains a guarded block that PRINTS the requested
#     stack top, the rounded size, the FIXED allocation target, the return the FIXED call produced,
#     the settled `p->user_stack`, and the guard geometry - turning records/1025-source-trace.txt's
#     by-value claim ("the FIXED alloc succeeded") into a NUMBER in the press's capture.
#
# WHY TWO POOL FILES ARE A BUILD-LAYER EDIT.  trap.c and kern_exec.c are POOL objects
# (osfmk_arm_trap.o, bsd_kern_kern_exec.o); the switch rides the GLOBAL `DEFINES` array in
# `tools/build_xnu_arm_kernel.sh` (the array every compile line carries) - NOT `EXTRA_DEFINES` alone
# (the EABI-runtime and firehose blocks do not get EXTRA; records/1020-build-defect.txt).  The pool
# MUST be rebuilt (`build_1025.sh` runs `tools/build_xnu_arm_kernel.sh`) or the linked image keeps the
# old objects and the probe is absent while the record says it is on.
#
# Switch OFF compiles each file byte for byte: both blocks are wholly inside
# `#if defined(STAGE90_XNU_USTACK_PROBE) && STAGE90_XNU_USTACK_PROBE`, so `defined()` is checked FIRST
# and an unset switch leaves the file exactly as before ([[mi4-off-option-two-spellings]]).
# `--verify-off` proves BOTH arms with the REAL preprocessor: OFF -> the probe token is absent, ON ->
# it is present, for BOTH files.
#
# Idempotent: the patcher decides before writing, asserts each anchor's occurrence count exactly,
# REFUSES (both files untouched) on a partial/double edit, and a second `--apply` is a no-op that
# SUCCEEDS (the build script calls it twice).  A partial (one-file) edit is a refusal, never a
# half-application.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$HERE/.." && pwd)
XNU=${XNU_TREE:-$REPO_ROOT/external/xnu-hd2-darwin13/xnu}

for f in osfmk/arm/trap.c bsd/kern/kern_exec.c; do
    [[ -f $XNU/$f ]] || { echo "stage_d13_ustack_probe: no $f in $XNU (D13 tree not provisioned?)" >&2; exit 2; }
done

python3 "$HERE/patch_d13_ustack_probe.py" "$XNU"
python3 "$HERE/patch_d13_ustack_probe.py" "$XNU" --apply
python3 "$HERE/patch_d13_ustack_probe.py" "$XNU" --apply >/dev/null   # idempotent no-op
python3 "$HERE/patch_d13_ustack_probe.py" "$XNU" --verify-off

echo "stage_d13_ustack_probe: done (XNU=$XNU)"
echo "stage_d13_ustack_probe: NOW RE-RUN tools/build_xnu_arm_kernel.sh with STAGE90_XNU_USTACK_PROBE=1 exported (it reads that ENV variable into the global DEFINES at the 1025 switch block) - build_entry.sh only LINKS the pool objects, so without the rebuild the linked image keeps the old trap.o/kern_exec.o and the probe keys never appear"