#!/bin/bash
# Stage 1026's abort-entry discriminator into the D13 tree (experiment 1026).
#
# `external/` is a re-provisionable, gitignored checkout, so every edit this makes to it must be a
# script a re-checkout can re-apply, not a hand edit it would lose (`stage_d13_board.sh`'s rule). This
# script is the single entry point for 1026's TWO tree edits, both staged by
# `tools/patch_d13_abt_entry_probe.py`:
#   * `osfmk/arm/trap.c` - INSIDE the existing 1025 publisher block (`#if defined(STAGE90_XNU_USTACK_PROBE)
#     && STAGE90_XNU_USTACK_PROBE`), immediately before its `#endif`, a NESTED guarded block
#     (`#if defined(STAGE90_XNU_ABT_ENTRY_PROBE) && STAGE90_XNU_ABT_ENTRY_PROBE`) that publishes, for the
#     failing fault only, the lookups that DISCRIMINATE H1 (wrong map) from H2 (off-the-end):
#     xnu_live_abt_lookup_far / entry_lo / entry_hi / far_in_map / map / taskmap / ustack.
#   * `bsd/kern/kern_exec.c` - the `xnu_live_abt_proc_ustack` accessor above `create_unix_stack`, which
#     reads `((proc_t)bsd_info)->user_stack`.  `struct proc` is only FOWARD-declared in trap.c
#     (`osfmk/arm/trap.c:58`), so the FIELD cannot be read there; the accessor lives where the struct is
#     complete and trap.c calls it by its extern name (the route `proc_pid` already takes).
#
# WHY TWO POOL FILES ARE A BUILD-LAYER EDIT.  trap.c and kern_exec.c are POOL objects
# (osfmk_arm_trap.o, bsd_kern_kern_exec.o); the switch rides the GLOBAL `DEFINES` array in
# `tools/build_xnu_arm_kernel.sh` (the array every compile line carries) - NOT `EXTRA_DEFINES` alone
# (the EABI-runtime and firehose blocks do not get EXTRA; records/1020-build-defect.txt).  The pool
# MUST be rebuilt (`build_1026.sh` runs `tools/build_xnu_arm_kernel.sh`) or the linked image keeps the
# old objects and the probe is absent while the record says it is on.
#
# Switch OFF compiles each file byte for byte: both blocks are wholly inside their `#if defined(X) && X`
# gates (`defined()` is checked FIRST), so an unset switch leaves each file exactly as before
# ([[mi4-off-option-two-spellings]]).  `--verify-off` proves BOTH arms with the REAL preprocessor:
# OFF -> the discriminator token is absent, ON -> present, for BOTH files.
#
# THE FOUR-RUNG SHARED TRAP.C NAMESPACE ([[mi4-one-file-many-rungs]]).  FOUR rungs edit
# `osfmk/arm/trap.c` (994 dyld_witness / 1020 undef_raise / 1025 ustack_probe / 1026 this one).  A
# cleanup `git checkout -- trap.c` reverts the others SILENTLY, so `build_1026.sh` RE-STAGES all four in
# order and every trap.c patcher's allow-set carries the other three switches.  This script stages ONLY
# 1026's two edits; the composition is the build script's job.
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
    [[ -f $XNU/$f ]] || { echo "stage_d13_abt_entry_probe: no $f in $XNU (D13 tree not provisioned?)" >&2; exit 2; }
done

python3 "$HERE/patch_d13_abt_entry_probe.py" "$XNU"
python3 "$HERE/patch_d13_abt_entry_probe.py" "$XNU" --apply
python3 "$HERE/patch_d13_abt_entry_probe.py" "$XNU" --apply >/dev/null   # idempotent no-op
python3 "$HERE/patch_d13_abt_entry_probe.py" "$XNU" --verify-off

echo "stage_d13_abt_entry_probe: done (XNU=$XNU)"
echo "stage_d13_abt_entry_probe: NOW RE-RUN tools/build_xnu_arm_kernel.sh with STAGE90_XNU_ABT_ENTRY_PROBE=1 exported (it reads that ENV variable into the global DEFINES at the 1026 switch block) - build_entry.sh only LINKS the pool objects, so without the rebuild the linked image keeps the old trap.o/kern_exec.o and the probe keys never appear"