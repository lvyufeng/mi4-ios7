#!/usr/bin/env bash
# ====================================================================================================
# park_1020.sh.  MODELLED BYTE-STRUCTURALLY ON scripts/park_1018.sh, WITH 1015b's POOL-MOVED DISCIPLINE.
#
# Park 1020 (STAGE90_XNU_UNDEF_RAISE) and append its block to records/revert-set.txt.
#
# 1020 = 1018's switch set VERBATIM (STAGE90_XNU_GLOBAL_FIX=1, STAGE90_XNU_UNDEF_DIRECT=1 and the whole
# inherited set stay) + exactly ONE new switch: STAGE90_XNU_UNDEF_RAISE=1.  Design: docs/1020-design.md.
# Root cause: records/1019-rootcause.txt (commit d8c350b).  Superseded premise (the udf is the LOOP, not
# upstream of it): the 1019 re-read of the 1018 capture corrected docs/1019-design.md.
#
# WHY.  1019 named the resident no-return, by value: pid 1's Thumb `udf #254` (un-slid VA 0x3823aa54 =
# libsystem_platform.dylib `__os_alloc_slow`+0x108) RE-EXECUTES FOREVER - 8183x measured, invariant pc,
# NO PC advance.  In `external/xnu-hd2-darwin13/xnu/osfmk/arm/trap.c`'s `sleh_undef` user-mode arm the
# `if (instruction != 0xfedeffe7)` test is a STAND-IN for "is this a coprocessor/VFP instruction" (the
# code's own comment says so: "i should really fix this crap properly"), and it takes an UNCONDITIONAL
# `return;` for EVERY other undefined instruction - so a genuine `udf` is mis-classified as NEON, VFP is
# enabled once, and the handler returns with the PC still on the `udf`.  The port's OWN LEO machinery
# already assumes the two-trip shape (`ios7leo_dyld_matches` trap.c:84 / `ios7leo_dyld_repeat` :105); it
# simply never wired the first trip's `return` to allow the second.
#
# THE ARM (ONE `return;` MOVED, ONE switch).  `STAGE90_XNU_UNDEF_RAISE` (default 0) moves `sleh_undef`'s
# user-mode `return;` INSIDE the `if (!thread->machine.vfp_enable)` block, so a genuine `udf` arriving
# with VFP ALREADY enabled FALLS THROUGH to the printf + `EXC_BAD_INSTRUCTION` + `doexception` below
# instead of silently looping.  The gate is `defined()`-FIRST
# (`#if defined(STAGE90_XNU_UNDEF_RAISE) && STAGE90_XNU_UNDEF_RAISE`), so switch OFF compiles the file's
# pre-existing bytes exactly ([[mi4-off-option-two-spellings]]).
#
# **THIS IS A POOL-REBUILD RUNG (the 1015b shape), NOT ENTRY-ONLY.**  `trap.c` is a KERNEL-POOL file
# (`out/xnu_kernel_obj_d13/osfmk_arm_trap.o`), and `build_entry.sh` only LINKS that object -- the pool's
# `.text` is INSIDE the `.bin` whose sha256 IS the arm, so the arm MOVES only if the POOL is rebuilt with
# the -D.  A green entry build says NOTHING about this half: the linked image keeps Apple's bytes if the
# pool object is stale.  This is why the park's OWN change is asserted BY VALUE on the pool OBJECT FIRST,
# before every inherited regression clause.
#
# THE TWO CARRIERS ([[mi4-one-value-two-definitions]]).  `tools/build_xnu_arm_kernel.sh:872` gates its
# OWN `DEFINES+=(-DSTAGE90_XNU_UNDEF_RAISE=1)` on the ENV var of the same name, AND `scripts/build_1020.sh`
# passes `-DSTAGE90_XNU_UNDEF_RAISE=1` through `XNU_KERNEL_EXTRA_DEFINES` (the pool channel).  BOTH must
# carry it; `build_1020.sh` asserts BOTH before the pool build.  The record's `STAGE90_XNU_UNDEF_RAISE=`
# line is the arm's OWN entry key, written by `src/entry/build_entry.sh:40251` (`echo
# "STAGE90_XNU_UNDEF_RAISE=$UNDEF_RAISE"`), and it IS in `scripts/preflight_boot_check.sh`'s
# `ENTRY_CFG_KEYS` (`:762`) - so the record can and DOES carry it (unlike GLOBAL_FIX, below).
#
# THE DECLARATION CARRIER IS CORRUPT-SENSITIVE, AND THIS PARK DOES NOT APPEND TO IT.  In 1015b the record
# could NOT carry `STAGE90_XNU_GLOBAL_FIX` (no writer in src/entry/ echoes it), so the switch lived in the
# drop-in file `out/stage90/xnu_arm_entry-arm-extra.txt`, which `scripts/build_1015b.sh:439` writes EMPTY
# at the top and `park_1015b.sh` appends ONE line to.  **`scripts/build_1020.sh` does NOT touch that file
# at all** (MEASURED: build_1020.sh does not reset or append it - its EXPORTS are built only from the
# record's own keys), and no writer echoes a 1020 line for it either.  So 1020's own switch rides the
# RECORD (`STAGE90_XNU_UNDEF_RAISE=1`, verified in (a) below) plus the `-D`, and the arm-extra file must
# be carried through FROZEN AND UNCHANGED - it still holds exactly the one 1015b line.  THIS PARK
# THEREFORE ASSERTS THE FILE IS EXACTLY THAT ONE LINE AND NEVER APPENDS A SECOND (appending would put a
# declaration 1020's build never wrote in the file, [[mi4-a-claim-in-a-comment-is-not-a-check]]).
#
# THE 1020 VERDICT CELLS (docs/1020-design.md §5; read by tools/check_1020_capture.py):
#   R-RAISES-ONCE  - the udf fires at the frontier and `xnu_live_undef_seq` advances to 2 at ONE pc and
#                    STOPS, the `usermode undefined instruction` printf fires >=1x, and either the process
#                    is gone or a panic follows             => FIXED (the genuine udf raised after the
#                    lazy-VFP trip; the loop is dead)
#   R-RAISES-CLEAN - `_seq == 1` only (VFP was already on) + printf >=1x + no loop  => FIXED (even cleaner)
#   R-STILL-LOOPS  - `_seq` climbs to > 100 at one invariant pc, printf 0x   => NOT FIXED (the moved
#                    `return` did not take effect - check the `-D` reached the pool object; the 1010
#                    lesson: an absent effect whose channel was wrong)
#   R-VFP-CONTINUES- the boot advances PAST the udf to a DIFFERENT frontier (no undef loop, no panic) =>
#                    MOVED (the udf is passed; the next frontier is downstream)
#   R-CTL          - no `xnu_live_undef_*` keys at all AND no boot self-test `undef_handler_undef_handled`
#                    row                                  => INSTRUMENT_UNSOUND, WITHHOLD
#   R-CTL is MANDATORY FIRST: the control is the boot self-test row
#   `stage90_xnu_arm_vm_init_high_va_undef_handler_undef_handled=0x1` AND a `xnu_live_undef_seq` row.
# The witness rides the EXISTING `xnu_live_undef_*` keys on the DIRECT channel (STAGE90_XNU_UNDEF_DIRECT=1,
# which this arm carries) PLUS the handler's own printf.
#
# Medium: 968 real iOS 7.1.2 HFSX rootfs over hfs_rmd0; CARD_COW=1, HDD_WRITE=0, the base is never
# written - fully reversible.  fastboot boot only, NEVER flash.
# ====================================================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

LIVE=out/stage90
REC=records/revert-set.txt
# xnu_arm_entry-arm-extra.txt is 1015b's declaration carrier and is FROZEN with the arm it describes
# (see the header).  park_1015b.sh's MEMBERS list, PLUS this file, verbatim.
MEMBERS=(xnu_arm_entry.bin xnu_arm_entry.elf xnu_arm_entry.h xnu_arm_entry-config.txt \
         xnu_arm_entry-arm-extra.txt xnu_arm_entry-sources.txt stage90.bin stage90.elf stage90.img \
         stage90-qcdt.img stage90_fixture.macho stage90-build-config.txt SHA256SUMS.txt)

# The arm name IS the entry bin's sha8 (the project's rule).  Derive it, and refuse to re-park the
# RECENT PRESSED arms under a new name (build 1020 first).
ARM=armed-d13-$(sha256sum "$LIVE/xnu_arm_entry.bin" | cut -c1-8)
[[ $ARM == armed-d13-c2168632 ]] && { echo "REFUSING: $LIVE holds 1018's arm (c2168632), the PRESSED predecessor this rung builds on; build 1020 first"; exit 1; }
[[ $ARM == armed-d13-16fe8885 ]] && { echo "REFUSING: $LIVE holds 1015b's arm (16fe8885); build 1020 first"; exit 1; }
[[ $ARM == armed-d13-e51d14fa ]] && { echo "REFUSING: $LIVE holds 1015's arm (e51d14fa); build 1020 first"; exit 1; }
[[ $ARM == armed-d13-29ec9e48 ]] && { echo "REFUSING: $LIVE holds 1014's arm (29ec9e48); build 1020 first"; exit 1; }
[[ $ARM == armed-d13-9bf25f8f ]] && { echo "REFUSING: $LIVE holds 1013b's arm (9bf25f8f); build 1020 first"; exit 1; }
[[ $ARM == armed-d13-ffdc8ba1 ]] && { echo "REFUSING: $LIVE holds 1012's arm (ffdc8ba1); build 1020 first"; exit 1; }

# ====================================================================================================
# 1020'S OWN CHANGE, BY VALUE, FIRST - BEFORE EVERY INHERITED REGRESSION CLAUSE.
# **THE ORDER IS THE POINT.**  A park that lost 1020's switch must fail HERE, on ITS OWN claim, rather
# than further down where an inherited (1018/1015b) clause would stop it for a reason that names the
# wrong thing.  The 1015b lesson (its first draft asserted 1015's pool-UNMOVED shape as its own).
# ====================================================================================================
echo "== 1020's OWN change, by value, first =="
# (a) THE RECORD'S OWN KEY.  1020's switch IS written by src/entry/build_entry.sh (MEASURED:
#     `:1648` UNDEF_RAISE=${STAGE90_XNU_UNDEF_RAISE:-0}, `:2296` the arm-key arm, `:40251` the record
#     echo) and IS in preflight's ENTRY_CFG_KEYS (`:762`), so the gate reads THIS line.  The park refuses
#     an arm whose record does not carry it ([[mi4-one-value-two-definitions]]).
grep -q '^STAGE90_XNU_UNDEF_RAISE=1$' "$LIVE/xnu_arm_entry-config.txt" || {
  echo "REFUSING: the record does not carry STAGE90_XNU_UNDEF_RAISE=1 - 1020's raise switch was not recorded this run (the gate reads THIS line; [[mi4-one-value-two-definitions]])"; exit 1; }

# (b) THE BUILD'S OWN LINKED-IMAGE CHECKER, RE-RUN ON THE FROZEN ARTIFACT - THE PARK'S BY-VALUE CLAIM.
#     This is the build clause re-checked at the freeze point (park_1018.sh's own wording): it walks the
#     LINKED `sleh_undef` CFG and asserts the 'already enabled' successor of the vfp_enable test REACHES
#     the EXC-printf block WITHOUT entering the VFP-enable block's terminating return.  It DISCRIMINATES
#     - MEASURED this session, switch OFF -> FAIL, switch ON (arm 47f664c4) -> PASS - so it is the proof
#     and not a formality.
#
#     **WHY THERE IS NO POOL-OBJECT CENSUS HERE (and this clause's first draft had one: it was UNSOUND).**
#     The draft asserted "the fix adds an IN-RANGE BACKWARD non-call branch inside sleh_undef" (OFF = 0,
#     ON >= 1).  That was written before an ON object existed.  MEASURED on the rebuilt ON object: the
#     predicate reads **0** - the compiler REORDERED the function so the raise block is reached by
#     FALL-THROUGH, not by a back edge (the non-magic arm's `ldr rX,[..,#676] vfp_enable` test at 9d8
#     falls through at 9e8 straight into the `.L.str.24` printf / `exception_triage` raise, and both its
#     `beq` targets are FORWARD).  A predicate that reads 0 on a CORRECT arm is the copy-paste defect
#     class - it would REFUSE the park's own arm.  There is no sound, simple object-side byte/reloc census
#     for "a \`return;\` moved inside an \`if\`" (unlike 1015b's `kernel_pmap` materialization count), so the
#     object-side confidence is the STAGED-TREE check in `scripts/build_1020.sh` step 5, and the by-value
#     proof is the LINKED image below ([[mi4-measurement-defects]]: a census that measures the wrong
#     thing is worse than none).
_t_obj=out/xnu_kernel_obj_d13/osfmk_arm_trap.o
[[ -f "$_t_obj" ]] || { echo "REFUSING: $_t_obj is absent - the pool build did not produce the object 1020 edits (\`trap.c\` is a KERNEL-POOL file, and build_entry.sh only LINKS it)"; exit 1; }
echo "   POOL: $_t_obj present (the pool was rebuilt; the by-value proof is the LINKED image below)"

if [[ -f tools/check_d13_undef_raise.py ]]; then
  python3 -I tools/check_d13_undef_raise.py "$LIVE/xnu_arm_entry.elf" --expect on >/dev/null 2>&1 || {
    echo "REFUSING: tools/check_d13_undef_raise.py \"$LIVE/xnu_arm_entry.elf\" --expect on did NOT pass - the frozen linked image's sleh_undef does not carry the moved \`return\`: the vfp_enable test's 'already enabled' successor does NOT reach the EXC-printf raise. The pool object was not rebuilt with -DSTAGE90_XNU_UNDEF_RAISE=1, or the -D never reached the compile (build_entry.sh only LINKS out/xnu_kernel_obj_d13/osfmk_arm_trap.o). Re-run scripts/build_1020.sh."; exit 1; }
  echo "park_1020: by value - tools/check_d13_undef_raise.py confirms the FROZEN linked image's sleh_undef user arm reaches the raise on the VFP-already-enabled path (--expect on PASSes)"
else
  echo "REFUSING: tools/check_d13_undef_raise.py is ABSENT - it is the park's by-value claim on the frozen artifact (the build writes it, so an absent one means the build tree is incomplete) and there is no sound object-side census to fall back on"; exit 1
fi

# (c) THE ARM-EXTRA CARRIER: 1020 does NOT write it (build_1020.sh does not touch it - MEASURED), so the
#     park REQUIRES it to be EXACTLY the one 1015b line and NEVER appends a second.  A second line would
#     be a declaration 1020's build never wrote ([[mi4-a-claim-in-a-comment-is-not-a-check]]); an absent
#     or emptied file would drop 1015b's kernel-moving switch (the storm would be re-litigated).
_b_extra="$LIVE/xnu_arm_entry-arm-extra.txt"
[[ -f "$_b_extra" ]] || { echo "REFUSING: $_b_extra is absent - 1015b's declaration carrier (STAGE90_XNU_GLOBAL_FIX) was not created; scripts/build_1015b.sh:439 writes it EMPTY at the top, and this rung carries it through UNCHANGED"; exit 1; }
[[ $(wc -l < "$_b_extra") == 1 && $(cat "$_b_extra") == 'STAGE90_XNU_GLOBAL_FIX=1 role=1015b-globalfix' ]] || {
  echo "REFUSING: $_b_extra is not EXACTLY the one 1015b line ('$(cat "$_b_extra")' across $(wc -l < "$_b_extra") line(s)). 1020's build does NOT write this file and 1020's switch rides the RECORD + the -D; this park must carry the file through UNCHANGED (one line). A second line is a declaration 1020's build never wrote; an empty file drops 1015b's kernel-moving switch and the retry storm returns"; exit 1; }
echo "   DECLARATION: $_b_extra carried through UNCHANGED: '$(cat "$_b_extra")' (1020's own switch rides the record + the -D, NOT this file)"

# ====================================================================================================
# THE INHERITED REGRESSION CLAUSES - 1018's and 1015b's, kept VERBATIM IN MEANING (placed AFTER 1020's
# own change, so a park that lost 1020's switch has already stopped above).
# ====================================================================================================
echo "== inherited regressions =="
# 1018's direct-channel switch stays on (its witness survives the cap) - the recorder that names the udf.
grep -q '^STAGE90_XNU_UNDEF_DIRECT=1$' "$LIVE/xnu_arm_entry-config.txt" || {
  echo "REFUSING: the record does not carry STAGE90_XNU_UNDEF_DIRECT=1 - 1018's direct channel is part of this arm's set verbatim and must stay on (without it the udf witness rides the CAPPED channel and can be silenced)"; exit 1; }
# 1015b's GLOBAL_FIX stays on as a REGRESSION (it is why the storm is gone and the frontier is the udf).
# **IT IS NOT IN THE RECORD AND CANNOT BE** (press_1015b.sh (0g), MEASURED): STAGE90_XNU_GLOBAL_FIX is a
# POOL switch (osfmk/arm/pmap.c:1357) that NO writer in src/entry/ echoes, so the config record cannot
# carry it and preflight_boot_check.sh's ENTRY_CFG_KEYS set-difference would refuse any press that named
# it there.  Its ONE declaration is the drop-in line (asserted in (c) above).
grep -qx 'STAGE90_XNU_GLOBAL_FIX=1 role=1015b-globalfix' "$_b_extra" || {
  echo "REFUSING: $_b_extra does not carry 'STAGE90_XNU_GLOBAL_FIX=1 role=1015b-globalfix' - 1015b's fix must stay on, or the single-address retry storm would be re-litigated"; exit 1; }
# 1018's by-value census (re-run on the FROZEN artifact): `__wrap_sleh_undef` in the LINKED image must
# branch to the DIRECT writer (entry_write_kv), NOT the capped one ([[mi4-linked-code-order-is-not-
# source-order]]).
_ua=$(arm-none-eabi-nm "$LIVE/xnu_arm_entry.elf" | awk '$3=="__wrap_sleh_undef"{print "0x" $1; n++} END{exit(n==1?0:1)}') || {
  echo "REFUSING: __wrap_sleh_undef is not in the parked image (or is defined more than once) - the undef witness is gone"; exit 1; }
_ub=$(arm-none-eabi-nm -n "$LIVE/xnu_arm_entry.elf" | awk -v s="${_ua#0x}" 'BEGIN{sv=strtonum("0x" s)}{a=strtonum("0x" $1)} a>sv{if(!d){print "0x" $1; d=1}}') || true
[[ -n $_ub ]] || { echo "REFUSING: no symbol follows __wrap_sleh_undef ($_ua) - its range cannot be read"; exit 1; }
_ud=$(arm-none-eabi-objdump -d "$LIVE/xnu_arm_entry.elf" --start-address="$_ua" --stop-address="$_ub")
_kv=$(grep -c '<entry_write_kv>' <<<"$_ud" || true)
_lw=$(grep -c '<entry_live_write>' <<<"$_ud" || true)
[[ $_kv -ge 6 && $_lw -eq 0 ]] || {
  echo "REFUSING: the parked image's __wrap_sleh_undef ($_ua..$_ub) branches to entry_write_kv $_kv time(s) and entry_live_write $_lw time(s) - with the switch on it must be >=6 direct and 0 counted (the six keys off the capped channel). A park that kept the counted branch freezes an arm whose witness the cap can still silence."; exit 1; }
echo "park_1020: by value - __wrap_sleh_undef ($_ua..$_ub) branches to entry_write_kv x$_kv, entry_live_write x$_lw (1018's witness is on the DIRECT channel)"

PARK=$LIVE/frozen/$ARM
[[ -d $PARK ]] && { echo "REFUSING: $PARK already exists"; exit 1; }
mkdir -p "$PARK"
for m in "${MEMBERS[@]}"; do cp -p "$LIVE/$m" "$PARK/$m"; done

{
  printf '# %s  -  1019/1020: KILL THE VFP FALSE POSITIVE - a genuine `udf` must RAISE, not loop.\n# (the resident no-return was pid 1-s `udf #254` RE-EXECUTING FOREVER, 8183x measured; the user-mode\n# `sleh_undef` arm returned WITHOUT advancing PC for every undefined instruction but one hard-coded\n# Apple-dyld value).\n' "$ARM"
  printf '# Switch set is 1018-s VERBATIM (STAGE90_XNU_GLOBAL_FIX=1 and STAGE90_XNU_UNDEF_DIRECT=1 and the\n'
  printf '# whole inherited set stay) plus exactly ONE new switch: STAGE90_XNU_UNDEF_RAISE=1.\n'
  printf '# **THE TREE MOVES AND THE KERNEL MOVES WITH IT - THAT IS THE RUNG.** Where 1018 was ENTRY-ONLY,\n'
  printf '# 1020 stages ONE SOURCE EDIT: tools/stage_d13_undef_raise.sh (via tools/patch_d13_undef_raise.py)\n'
  printf '# MOVES the `return;` in external/xnu-hd2-darwin13/xnu/osfmk/arm/trap.c-s `sleh_undef` user-mode\n'
  printf '# arm from OUTSIDE the `if (!thread->machine.vfp_enable)` block (where it returned unconditionally\n'
  printf '# for every non-`0xfedeffe7` instruction, so the PC never advanced) to INSIDE it:\n'
  printf '#       #if defined(STAGE90_XNU_UNDEF_RAISE) && STAGE90_XNU_UNDEF_RAISE\n'
  printf '#           if (!thread->machine.vfp_enable) { ...enable...; return; }\n'
  printf '#           /* VFP already on and still undefined: fall through to printf + EXC_BAD_INSTRUCTION */\n'
  printf '#       #else\n'
  printf '#           <the tree-s ORIGINAL block, byte for byte>\n'
  printf '#       #endif\n'
  printf '# A REAL VFP/NEON instruction with VFP off: trip 1 enables VFP and returns; the CPU re-executes it\n'
  printf '# with VFP on and it now runs - UNCHANGED. A genuine `udf` with VFP off: trip 1 enables VFP, trip 2\n'
  printf '# finds VFP on and FALLS THROUGH to the raise. A genuine `udf` with VFP already on: falls through\n'
  printf '# immediately. The port-s OWN LEO machinery already assumed the two-trip shape\n'
  printf '# (ios7leo_dyld_matches trap.c:84 / ios7leo_dyld_repeat :105); this rung wires it.\n'
  printf '# OFF compiles the tree-s ORIGINAL text byte for byte (`defined()` is written FIRST in the gate),\n'
  printf '# PROVEN with the real preprocessor over the whole file before any byte is written\n'
  printf '# (tools/patch_d13_undef_raise.py --verify-off).\n'
  printf '# THE POOL OBJECT MOVES: out/xnu_kernel_obj_d13/osfmk_arm_trap.o (trap.c is a KERNEL-POOL file;\n'
  printf '# build_entry.sh only LINKS it). The pool-s `.text` is INSIDE the entry `.bin` whose sha8 IS the\n'
  printf '# arm, so the arm MOVES (c2168632 -> %s) and the PAYLOAD moves (it embeds the entry blob).\n#\n' "${ARM#armed-d13-}"
  printf '# THE BY-VALUE PROOF OF 1020-S CHANGE (this park-s OWN claim, asserted FIRST). A CFG walk of the\n'
  printf '# FROZEN LINKED image-s `sleh_undef`: the vfp_enable test-s `already enabled` successor must REACH\n'
  printf '# the EXC-printf raise block (printf with the usermode-EXC_BAD_INSTRUCTION literal + the\n'
  printf '# `bl exception_triage`) WITHOUT entering the VFP-enable block-s terminating return. It\n'
  printf '# DISCRIMINATES, MEASURED this session: switch OFF (arm c2168632) -> FAIL; switch ON (this arm) ->\n'
  printf '# PASS. tools/check_d13_undef_raise.py --expect on, re-run on the frozen artifact (the build clause\n'
  printf '# re-checked at the freeze point).\n'
  printf '# **AND THE OBJECT-SIDE CENSUS THIS PARK-S FIRST DRAFT HELD WAS UNSOUND AND IS GONE.** It asserted\n'
  printf '# "the fix adds an IN-RANGE BACKWARD non-call branch inside sleh_undef" (OFF = 0, ON >= 1). Written\n'
  printf '# before an ON object existed; MEASURED on the rebuilt ON object it reads 0 - the compiler REORDERED\n'
  printf '# the function so the raise is reached by FALL-THROUGH (the vfp_enable test-s beq targets are both\n'
  printf '# FORWARD), not by a back edge. A predicate that reads 0 on a correct arm would REFUSE this park-s\n'
  printf '# own arm; there is no sound simple object-side census for "a `return;` moved inside an `if`", so\n'
  printf '# the object-side confidence is the staged-tree check (build_1020.sh step 5) and the by-value proof\n'
  printf '# is the LINKED image above ([[mi4-measurement-defects]]).\n#\n'
  printf '# THE TWO CARRIERS. STAGE90_XNU_UNDEF_RAISE is BOTH an env-gated pool DEFINE\n'
  printf '# (tools/build_xnu_arm_kernel.sh gates `-DSTAGE90_XNU_UNDEF_RAISE=1` on the ENV var) AND a\n'
  printf '# XNU_KERNEL_EXTRA_DEFINES token (the pool channel); scripts/build_1020.sh asserts BOTH before the\n'
  printf '# pool build. Its DECLARATION in the record is the resolved `STAGE90_XNU_UNDEF_RAISE=1` line\n'
  printf '# (src/entry/build_entry.sh:40251; also in preflight-s ENTRY_CFG_KEYS :762), so the RECORD carries\n'
  printf '# 1020-s own switch. The drop-in file xnu_arm_entry-arm-extra.txt carries ONLY 1015b-s\n'
  printf '# STAGE90_XNU_GLOBAL_FIX line (a POOL switch no writer in src/entry/ echoes, so the record cannot\n'
  printf '# carry it) - and it is frozen here UNCHANGED; 1020-s build does NOT write it and this park does\n'
  printf '# NOT append to it (appending would put a declaration 1020-s build never wrote in the file).\n#\n'
  printf '# THE INHERITED REGRESSIONS held (asserted by the park): STAGE90_XNU_UNDEF_DIRECT=1 in the record\n'
  printf '# (1018-s cap-exempt witness), STAGE90_XNU_GLOBAL_FIX=1 in the arm-extra file (1015b-s kernel fix),\n'
  printf '# and by value __wrap_sleh_undef in the LINKED image branches to entry_write_kv (>=6) and NOT\n'
  printf '# entry_live_write (0).\n#\n'
  printf '# THE 1020 VERDICT CELLS (docs/1020-design.md §5; tools/check_1020_capture.py):\n'
  printf '#   R-RAISES-ONCE  - `xnu_live_undef_seq` advances to 2 at ONE pc and STOPS + the `usermode\n'
  printf '#     undefined instruction` printf fires >=1x + (the process is gone or a panic follows) => FIXED.\n'
  printf '#   R-RAISES-CLEAN - `_seq == 1` only (VFP was already on) + printf >=1x + no loop => FIXED.\n'
  printf '#   R-STILL-LOOPS  - `_seq` climbs to > 100 at one invariant pc, printf 0x => NOT FIXED (the moved\n'
  printf '#     `return` did not take effect; check the `-D` reached the pool object - the 1010 lesson).\n'
  printf '#   R-VFP-CONTINUES- the boot advances PAST the udf to a DIFFERENT frontier => MOVED.\n'
  printf '#   R-CTL          - no `xnu_live_undef_*` keys AND no boot self-test\n'
  printf '#     `stage90_xnu_arm_vm_init_high_va_undef_handler_undef_handled=0x1` row => INSTRUMENT_UNSOUND,\n'
  printf '#     WITHHOLD (mandatory first - the control is BOTH the self-test row AND a `_seq` row).\n'
  printf '# The witness is the EXISTING `xnu_live_undef_*` keys on the DIRECT channel + the handler-s printf.\n'
  printf '# Medium: 968 real iOS 7.1.2 HFSX rootfs over hfs_rmd0; CARD_COW=1, HDD_WRITE=0, base never\n'
  printf '# written - fully reversible. fastboot boot only, NEVER flash.\n'
  printf '# =================================================================================================\n'
  for m in "${MEMBERS[@]}"; do
    h=$(sha256sum "$PARK/$m" | awk '{print $1}')
    b=$(stat -c %s "$PARK/$m")
    printf 'set=%s sha256=%s bytes=%s file=%s role=1020-undef-raise;%s\n' \
      "$ARM" "$h" "$b" "$m" "$m"
  done
} >> "$REC"

echo "parked $ARM ($(ls -1 "$PARK" | wc -l) members)"
tools/verify_revert_set.sh "$PARK" --set="$ARM" 2>&1 | tail -3