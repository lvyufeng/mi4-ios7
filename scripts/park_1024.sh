#!/usr/bin/env bash
# ====================================================================================================
# park_1024.sh.  MODELLED BYTE-STRUCTURALLY ON scripts/park_1023.sh (itself the 1021d/1015b pattern),
# WITH 1015b's POOL-MOVED DISCIPLINE: this rung's edit is a HEADER (`osfmk/mach/arm/vm_param.h`) that
# every pool TU includes, so the whole pool moves and the entry .bin whose sha8 IS the arm moves with it.
#
# Park 1024 (make the task map's ceiling agree with the hardware split: VM_MAX_ADDRESS 0x80000000 ->
# 0x40000000 under the new switch STAGE90_XNU_VM_MAX_SPLIT=1) and append its block to
# records/revert-set.txt.
#
# 1024 = 1023's switch set VERBATIM with **ONE NEW SWITCH: STAGE90_XNU_VM_MAX_SPLIT=1**.  Design:
# docs/1024-design.md.
#
# WHY.  The 1023 press read T24-FIRES (records/1023-press-read.txt): trap 24 IS dispatched
# (`IOS7LAB trap24 frame` x4), `mach_port_construct` returns 0 x4, and the frontier moved to a
# ~2^20-iteration DATA-ABORT loop in pid 1 at user VA `0x40083008`: `abt_pc = 0x39ded790 - slide
# 0x01bac000 = 0x38241790` = `libsystem_pthread.dylib + 0x2790` = `_pthread_create+0xbc`, the
# instruction `ldr r0,[r5,#8]` with `r5 = 0x40083000` (out-param 1 of `__pthread_allocate_stack`), and
# `abt_ptel2 = 0` (the walk finds an empty L2 slot).  Root cause, all read by value: `set_mmu_ttbcr(2)`
# (`osfmk/arm/arm_vm_init.c:475`) gives TTBR0 exactly 1 GiB - `[0, 0x40000000)` - while
# `task_create_internal` links `vm_map_create(pmap, 0, VM_MAX_ADDRESS, TRUE, ...)` with
# **VM_MAX_ADDRESS = 0x80000000** (MEASURED at 80085cf0 `mov r2,#-2147483648` before 80085cfc
# `bl vm_map_create` in the armed 1023 image), because `vm_param.h:62-68` compiles the `#else` branch
# on CANCRO.  The first big anywhere-allocation (pthread stack) was placed ABOVE the split, where the
# hardware walks TTBR1 (the kernel's tree) and finds nothing; `vm_fault` "succeeds" for ever.  The
# header's OWN comment states the rule: "Ordinary user allocations must stay below the kernel-owned
# commpage at 0x40000000."
#
# **THE ARM (ONE header line).**  vm_param.h:63
#   `#if BOARD_CONFIG_ARMPBA8 || BOARD_CONFIG_QSD8250_LEO`
# ->` || (defined(STAGE90_XNU_VM_MAX_SPLIT) && STAGE90_XNU_VM_MAX_SPLIT)`, `defined()` first so OFF
# compiles the tree's original line byte for byte ([[mi4-off-option-two-spellings]]).  Staged by
# tools/patch_d13_vm_max_split.py with a two-arm real-preprocessor proof, refused on hand edits.
#
# **THE CHANNEL IS THE GLOBAL `DEFINES` ARRAY of tools/build_xnu_arm_kernel.sh (env), NOT EXTRA.**
# The EABI-runtime and firehose blocks expand `${DEFINES[@]}` but NOT `${EXTRA_DEFINES[@]}`, so an
# EXTRA-only build would leave those TUs on the old ceiling behind a green build
# ([[mi4-one-value-two-definitions]]).
#
# **THIS IS A POOL-REBUILD RUNG (the 1015b shape).**  vm_param.h is a HEADER included by every TU that
# bounds a user map; `build_entry.sh` only LINKS the pool objects, so a green entry build says NOTHING
# about this half.  The park's OWN change is asserted BY VALUE on the LINKED image
# (tools/check_vm_max_split.py) and on the FROZEN PRE-RUNG arm (the negative control) before every
# inherited clause.
#
# **THE CARRIERS.**  The record carries `STAGE90_XNU_VM_MAX_SPLIT=1` (the readability carrier AND the
# switch the widened header line reads; the plumbing record shows it reaches the pool DEFINES at
# build_xnu_arm_kernel.sh:994, the asm layer, and the entry EXPORTS).  The declaration carrier
# out/stage90/xnu_arm_entry-arm-extra.txt is written by THIS build's tail as
# `STAGE90_XNU_GLOBAL_FIX=1 role=1024-vm-max-split` (1015b's GLOBAL_FIX is a POOL switch no writer in
# src/entry/ echoes).  A grep of that file is a PROCESS check; the by-value clauses below are what
# actually certify the arm ([[mi4-self-written-record-is-not-a-constraint]]).
#
# THE 1024 VERDICT CELLS (docs/1024-design.md section 4; the press reads them off the capture via
# tools/check_1024_capture.py):
#   STORM-GONE     - the 1023 storm signature (abt_pc 0x38241790 slide-corrected / abt_far 0x40083008)
#                    is ABSENT AND the prior rungs' positive controls still hold (trap24 frame x4,
#                    port_construct result=0 x4, xnu_live_undef_seq = 0x, zero panics)  => WALL MOVED
#   STORM-PERSISTS - the storm recurs at 1023's pc/far at scale => the patch did not reach the compiled
#                    image; read `tools/check_vm_max_split.py <elf> --expect on` before anything else
#   STORM-MOVED    - a storm exists elsewhere; any abt_far >= 0x40000000 means the map was not the
#                    only producer (1024-W's registry names the culprit)
#   PRIOR-RUNGS-REGRESSED - one of the prior rungs' controls regressed => the arm's switch set is wrong
#   G-CTL / WITHHOLD - neither the live channel nor any IOS7LAB line is live => no reading
#
# Medium: 968 real iOS 7.1.2 HFSX rootfs over hfs_rmd0; CARD_COW=1, HDD_WRITE=0, the base is never
# written - fully reversible.  fastboot boot only, NEVER flash.
# ====================================================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

LIVE=out/stage90
REC=records/revert-set.txt
MEMBERS=(xnu_arm_entry.bin xnu_arm_entry.elf xnu_arm_entry.h xnu_arm_entry-config.txt \
         xnu_arm_entry-arm-extra.txt xnu_arm_entry-sources.txt stage90.bin stage90.elf stage90.img \
         stage90-qcdt.img stage90_fixture.macho stage90-build-config.txt SHA256SUMS.txt)

# The arm name IS the entry bin's sha8 (the project's rule).  Derive it, and refuse to re-park the
# RECENT PRESSED arms under a new name (build 1024 first).  10b79e5d is the arm the 1023 press SPENT
# and is the arm 1024 must MOVE AWAY from; b47131c8 is the 1022 arm 1023 moved away from; the rest are
# earlier rungs.
ARM=armed-d13-$(sha256sum "$LIVE/xnu_arm_entry.bin" | cut -c1-8)
[[ $ARM == armed-d13-10b79e5d ]] && { echo "REFUSING: $LIVE holds 1023's PRESSED arm (10b79e5d) - the arm whose trap-24 row 1023 installed and spent, and the arm whose storm 1024 exists to move. A park of the SAME arm would freeze a set that does not carry this rung's ceiling; build 1024 first"; exit 1; }
[[ $ARM == armed-d13-b47131c8 ]] && { echo "REFUSING: $LIVE holds 1022's PRESSED arm (b47131c8); build 1024 first"; exit 1; }
[[ $ARM == armed-d13-ee2dd4fb ]] && { echo "REFUSING: $LIVE holds 1021d's PRESSED arm (ee2dd4fb); build 1024 first"; exit 1; }
[[ $ARM == armed-d13-b5093f00 ]] && { echo "REFUSING: $LIVE holds 1020b's PRESSED arm (b5093f00); build 1024 first"; exit 1; }
[[ $ARM == armed-d13-47f664c4 ]] && { echo "REFUSING: $LIVE holds 1020's DROPPED-GLOBAL-FIX arm (47f664c4); build 1024 first"; exit 1; }
[[ $ARM == armed-d13-c2168632 ]] && { echo "REFUSING: $LIVE holds 1018's arm (c2168632); build 1024 first"; exit 1; }
[[ $ARM == armed-d13-16fe8885 ]] && { echo "REFUSING: $LIVE holds 1015b's arm (16fe8885); build 1024 first"; exit 1; }
[[ $ARM == armed-d13-e51d14fa ]] && { echo "REFUSING: $LIVE holds 1015's arm (e51d14fa); build 1024 first"; exit 1; }
[[ $ARM == armed-d13-29ec9e48 ]] && { echo "REFUSING: $LIVE holds 1014's arm (29ec9e48); build 1024 first"; exit 1; }
[[ $ARM == armed-d13-9bf25f8f ]] && { echo "REFUSING: $LIVE holds 1013b's arm (9bf25f8f); build 1024 first"; exit 1; }
[[ $ARM == armed-d13-ffdc8ba1 ]] && { echo "REFUSING: $LIVE holds 1012's arm (ffdc8ba1); build 1024 first"; exit 1; }

# ====================================================================================================
# 1024'S OWN CHANGE, BY VALUE, FIRST - BEFORE EVERY INHERITED REGRESSION CLAUSE.
# **THE ORDER IS THE POINT.**  A park that lost this rung's ceiling must fail HERE, on ITS OWN claim
# (the ceiling fingerprint on the LINKED image), rather than further down where an inherited clause
# would stop it for a reason that names the wrong thing.
# ====================================================================================================
echo "== 1024's OWN change, by value, first =="

# (a) THE RECORD'S OWN KEY.  `STAGE90_XNU_VM_MAX_SPLIT=1` is BOTH the readability carrier AND the
#     switch the widened vm_param.h:63 line reads.  Absent it, the pool was compiled with the OLD
#     ceiling (0x80000000) and the arm is not 1024's.
grep -q '^STAGE90_XNU_VM_MAX_SPLIT=1$' "$LIVE/xnu_arm_entry-config.txt" || {
  echo "REFUSING: the record does not carry STAGE90_XNU_VM_MAX_SPLIT=1 - 1024's widened vm_param.h:63 line reads THIS switch, and it is set on this arm. Its absence means the pool was built with the OLD ceiling, so the task map still reaches 0x80000000 while the hardware walks TTBR1 above 0x40000000 and the 1023 storm recurs. Build with scripts/build_1024.sh"; exit 1; }

# (b) THE BY-VALUE CLAUSE - THE PARK'S OWN CLAIM, ON THE LINKED IMAGE THE PRESS WILL BOOT.
#     `tools/check_vm_max_split.py <elf> --expect on` reads `task_create_internal` BY VALUE (both ends
#     resolved by NAME from the symbol table) and asserts the `mov r2,#imm` feeding `bl vm_map_create`
#     reads 0x40000000.  `build_entry.sh` only LINKS the pool objects, so this must be read on the
#     LINKED image (a stale pool object keeps the old ceiling).
#
#     **THE CHECKER IS REQUIRED, AND ITS ABSENCE IS A REFUSAL, NOT A SKIP.**  A park that skipped this
#     would freeze an arm whose own claim nothing checks ([[mi4-a-claim-in-a-comment-is-not-a-check]]).
[[ -f tools/check_vm_max_split.py ]] || {
  echo "REFUSING: tools/check_vm_max_split.py is ABSENT. It is this park's by-value claim on the LINKED image's task-map ceiling, and there is no sound fallback (a grep of the source cannot distinguish 'the switch reached the object' from 'the header edit never compiled'). An absent checker means the by-value half of this rung cannot be certified"; exit 1; }

# 1024-0. THE CHECKER'S OWN SELF-TEST.  A checker that cannot fail is not a check
#         ([[mi4-a-claim-in-comment-is-not-a-check]]).  Refuse the park unless it PASSes its selftest.
python3 -I tools/check_vm_max_split.py --selftest >/dev/null 2>&1 || {
  echo "REFUSING: tools/check_vm_max_split.py --selftest did NOT PASS - the checker cannot certify anything (an inert checker would bless any image). Fix the checker before parking the arm it is supposed to prove"; exit 1; }
echo "   BY VALUE(0): tools/check_vm_max_split.py --selftest PASSes (the checker is live)"

# 1024-1. THE RUNG'S OWN CLAIM, ON THE LINKED IMAGE.  Read on `$LIVE/xnu_arm_entry.elf` (the image the
#         press boots), because the change is a HEADER that recompiles POOL objects the entry build
#         only LINKS.
[[ -s $LIVE/xnu_arm_entry.elf ]] || { echo "REFUSING: $LIVE/xnu_arm_entry.elf is absent - there is nothing to read the task-map ceiling out of"; exit 1; }
python3 -I tools/check_vm_max_split.py "$LIVE/xnu_arm_entry.elf" --expect on >/dev/null 2>&1 || {
  echo "REFUSING: the LINKED image's task_create_internal does NOT pass 0x40000000 to vm_map_create - either the widened vm_param.h:63 line did not reach the pool (the env -> global DEFINES channel), or a STALE pool object was linked (build_entry.sh only LINKS it). Re-run scripts/build_1024.sh"; exit 1; }
echo "   BY VALUE(1): the LINKED $LIVE/xnu_arm_entry.elf's task_create_internal passes 0x40000000 to vm_map_create (== the hardware's 1 GiB TTBR0 split)"

# 1024-2. THE DISCRIMINATING CONTROL.  A clause that cannot FAIL is not a check
#         ([[mi4-a-claim-in-comment-is-not-a-check]]); so the SAME checker is run in the `--expect off`
#         direction on the FROZEN PRE-RUNG arm (1023, 10b79e5d), whose ceiling IS 0x80000000 (1023
#         never touched VM_MAX_ADDRESS - 1024 is the FIRST rung to move it).  The pair (pre-rung ->
#         off PASS, this arm -> on PASS) is what proves the checker DISCRIMINATES rather than always
#         saying the same thing.
_ctrl=$LIVE/frozen/armed-d13-10b79e5d/xnu_arm_entry.elf
[[ -s $_ctrl ]] || { echo "REFUSING: the frozen 1023 elf ($_ctrl) is absent - the NEGATIVE CONTROL for this rung's by-value clause cannot be taken, so the clause above cannot be shown to DISCRIMINATE. 1023's park must exist before 1024's"; exit 1; }
python3 -I tools/check_vm_max_split.py "$_ctrl" --expect off >/dev/null 2>&1 || {
  echo "REFUSING: the frozen 1023 elf's ceiling does NOT read 0x80000000 in the --expect off direction - the checker is either broken or pointed at the wrong immediate, so the 'on' PASS above certifies nothing. This is the control; a control that agrees with the test proves only that the checker says one thing"; exit 1; }
echo "   BY VALUE(2): NEGATIVE CONTROL - the frozen 1023 elf (10b79e5d) reads the ceiling == 0x80000000 (--expect off PASSes), so the 'on' above is a reading and not a constant"

# (c) THE ARM-EXTRA DECLARATION CARRIER.  1024's build WRITES this file at its tail
#     (`STAGE90_XNU_GLOBAL_FIX=1 role=1024-vm-max-split`), so THIS park requires it verbatim and never
#     appends.  1015b's GLOBAL_FIX is a POOL switch no writer in src/entry/ echoes, so the record
#     cannot carry it; this drop-in is its ONE declaration, and the role tag names 1024 so a stale
#     1023 line is distinguishable by content.  **THE GREP IS THE PROCESS CHECK, NOT THE PROOF** - the
#     pmap_flush_tlbs fingerprint below is what certifies the fix is in the object
#     ([[mi4-self-written-record-is-not-a-constraint]]).
_b_extra="$LIVE/xnu_arm_entry-arm-extra.txt"
[[ -f $_b_extra ]] || { echo "REFUSING: $_b_extra is absent - 1024's build writes the declaration carrier at its tail; an absent one means this arm's build did not finish"; exit 1; }
[[ $(wc -l < "$_b_extra") == 1 && $(cat "$_b_extra") == 'STAGE90_XNU_GLOBAL_FIX=1 role=1024-vm-max-split' ]] || {
  echo "REFUSING: $_b_extra is not EXACTLY the one 1024 line (it holds '$(cat "$_b_extra")' across $(wc -l < "$_b_extra") line(s)). 1015b's GLOBAL_FIX is a POOL switch no writer in src/entry/ echoes, so this drop-in is its ONE declaration, and 1024's build writes it as exactly this line. A surviving 1023 line (role=1023-trap24) would be a declaration OF A DIFFERENT BUILD ([[mi4-self-written-record-is-not-a-constraint]]). Re-run scripts/build_1024.sh"; exit 1; }
echo "   DECLARATION: $_b_extra carries exactly '$(cat "$_b_extra")' (written by THIS build; the proof is the fingerprint below)"

# ---- THE INHERITED GLOBAL-FIX CLAUSE: IT IS IN THE FROZEN POOL OBJECT, BY VALUE ----
# 1020's pool rebuild DROPPED 1015b (records/1020-build-defect.txt): the storm returned.  1024 rebuilds
# the WHOLE pool (vm_param.h is a header), so the same defect is available.  The fix's fingerprint is
# the count of `kernel_pmap` MOVW materializations inside `pmap_flush_tlbs` (OFF/Apple = 2, ON = 3).
_gf_obj=out/xnu_kernel_obj_d13/osfmk_arm_pmap.o
[[ -f "$_gf_obj" ]] || { echo "REFUSING: $_gf_obj is absent - 1015b's GLOBAL-FIX lives in pmap_flush_tlbs, and a park that cannot read it cannot certify the storm stays gone"; exit 1; }
_gf_kp=$(arm-none-eabi-objdump -r "$_gf_obj" 2>/dev/null | awk '$1>="00000418" && $1<="00000640"' | grep -c 'MOVW_ABS_NC.*kernel_pmap' || true)
_gf_full=$(arm-none-eabi-objdump -r "$_gf_obj" 2>/dev/null | awk '$1>="00000418" && $1<="00000640"' | grep -c 'R_ARM_CALL.*arm_tlb_flushID$' || true)
_gf_asid=$(arm-none-eabi-objdump -r "$_gf_obj" 2>/dev/null | awk '$1>="00000418" && $1<="00000640"' | grep -c 'R_ARM_CALL.*arm_tlb_flushID_ASID$' || true)
[[ "$_gf_kp" == "3" && "$_gf_full" == "1" && "$_gf_asid" == "1" ]] || {
  echo "REFUSING: pmap_flush_tlbs materializes kernel_pmap x$_gf_kp (want 3), arm_tlb_flushID x$_gf_full / arm_tlb_flushID_ASID x$_gf_asid (want 1/1) - GLOBAL-FIX is NOT in the pool object, so the retry storm 1015b killed is BACK and the run would never reach pid 1's pthread-create fault this rung exists to move. -DSTAGE90_XNU_GLOBAL_FIX=1 has NO record carrier (records/1020-build-defect.txt). Re-run scripts/build_1024.sh."; exit 1; }
echo "   POOL(GLOBAL-FIX): by value - pmap_flush_tlbs carries the 3rd kernel_pmap materialization ($_gf_kp sites) and the declared 1/1 flush arms, so 1015b's GLOBAL-FIX IS in the pool object"

# ---- THE INHERITED NEON-FREE CLAUSE: -msoft-float must still hold (this rung re-OBJECTs the WHOLE
# pool, so the flag must still reach every object).  The census is whole-pool with a source-count
# cross-check (a stale/partial dir is a refusal, not a vacuous pass, defect class m1015b).
[[ -f tools/check_d13_no_neon.py ]] || { echo "REFUSING: tools/check_d13_no_neon.py is ABSENT - it is the inherited 1021d claim's by-value check (the -msoft-float flag reached the pool). An absent one means the build tree is incomplete"; exit 1; }
python3 -I tools/check_d13_no_neon.py --selftest >/dev/null 2>&1 || { echo "REFUSING: tools/check_d13_no_neon.py --selftest did NOT PASS - the inherited NEON-free checker cannot certify anything"; exit 1; }
_pool=out/xnu_kernel_obj_d13
[[ -d $_pool ]] || { echo "REFUSING: $_pool is absent - the pool the linked image was built from is not on disk"; exit 1; }
_src_rec=out/xnu_kernel_src_d13.sha256
[[ -s $_src_rec ]] || { echo "REFUSING: $_src_rec is absent - the pool's own source-content record is the independent count this clause compares against. Its absence means the pool build did not complete"; exit 1; }
_want_objs=$(grep -c '^[0-9a-f]\{64\} ' "$_src_rec" || true)
_got_objs=$(ls "$_pool"/*.o 2>/dev/null | wc -l)
[[ $_want_objs -gt 0 && $_got_objs -eq $_want_objs ]] || {
  echo "REFUSING: $_pool holds $_got_objs object(s) but $_src_rec names $_want_objs source(s) - the census would count the WRONG set (a partial or stale directory passes any NEON-free test vacuously). Re-run scripts/build_1024.sh"; exit 1; }
python3 -I tools/check_d13_no_neon.py --pool "$_pool" --expect none --min-objects "$_want_objs" >/dev/null 2>&1 || {
  echo "REFUSING: tools/check_d13_no_neon.py --pool $_pool --expect none did NOT pass - the pool the linked image was built from still contains FP/NEON instructions. 1024 recompiles the WHOLE pool (vm_param.h is a header), so the -msoft-float flag must still reach every object or the kernel-mode NEON undef at 0x8047b0ac returns. Re-run scripts/build_1024.sh"; exit 1; }
python3 -I tools/check_d13_no_neon.py "$LIVE/xnu_arm_entry.elf" --symbol mach_msg_send --expect none >/dev/null 2>&1 || {
  echo "REFUSING: the LINKED image's mach_msg_send still contains FP/NEON instructions - 1021d's -msoft-float flag did not reach the object the linker saw, or a STALE pool object was linked. Re-run scripts/build_1024.sh"; exit 1; }
echo "   POOL(NEON-FREE): by value - $_got_objs objects NEON-free (== $_want_objs source(s)), and the LINKED mach_msg_send is NEON-free (1021d's -msoft-float holds)"

# ====================================================================================================
# THE INHERITED REGRESSION CLAUSES - 1023's / 1022's / 1021d's / 1020b's / 1018's, kept VERBATIM IN
# MEANING (placed AFTER 1024's own change, so a park that lost this rung's ceiling has already stopped
# above).
# ====================================================================================================
echo "== inherited regressions =="
# 1021d's general-regs switch stays on (the whole pool must stay NEON-free).
grep -q '^STAGE90_XNU_GENERAL_REGS=1$' "$LIVE/xnu_arm_entry-config.txt" || {
  echo "REFUSING: the record does not carry STAGE90_XNU_GENERAL_REGS=1 - 1021d's -msoft-float flag switch is part of this arm's set verbatim and must stay on (without it the kernel-mode NEON undef at 0x8047b0ac returns and this rung would measure a different frontier than pid 1's pthread-create fault it exists to move)"; exit 1; }
# 1020's raise switch stays on: 1024 must not regress the fix that killed the udf loop.
grep -q '^STAGE90_XNU_UNDEF_RAISE=1$' "$LIVE/xnu_arm_entry-config.txt" || {
  echo "REFUSING: the record does not carry STAGE90_XNU_UNDEF_RAISE=1 - 1020's raise fix is part of this arm's set verbatim and must stay on (without it pid 1's genuine udf loops forever again, 8183x measured)"; exit 1; }
# 1018's direct-channel switch stays on (its witness survives the cap) - the recorder that names the udf.
grep -q '^STAGE90_XNU_UNDEF_DIRECT=1$' "$LIVE/xnu_arm_entry-config.txt" || {
  echo "REFUSING: the record does not carry STAGE90_XNU_UNDEF_DIRECT=1 - 1018's direct channel is part of this arm's set verbatim and must stay on (without it the udf witness rides the CAPPED channel and can be silenced - the 1017/1018 instrument defect)"; exit 1; }
# 1023's row-24 switch stays on: 1024 MOVES THE CEILING AND ADDS NOTHING ELSE, so trap 24 must still be
# installed and rows 25/41/42 still kern_invalid.
grep -q '^STAGE90_XNU_IOS7_TRAPS=1$' "$LIVE/xnu_arm_entry-config.txt" || {
  echo "REFUSING: the record does not carry STAGE90_XNU_IOS7_TRAPS=1 - 1023's row-24 gate widens to read THIS switch; its absence means row 24 is kern_invalid again, the 1023 frontier is back, and the press would not be a reading of THIS rung"; exit 1; }
# 1023's by-value clause, re-run on the LINKED image: mach_trap_table[24] must still be the construct
# handler with rows 25/41/42 still kern_invalid (the composition this rung inherits unchanged).
[[ -f tools/check_1023_trap24.py ]] || { echo "REFUSING: tools/check_1023_trap24.py is ABSENT - it is the inherited 1023 claim's by-value check on the linked image (build_1023's row 24)"; exit 1; }
python3 -I tools/check_1023_trap24.py --selftest >/dev/null 2>&1 || { echo "REFUSING: tools/check_1023_trap24.py --selftest did NOT PASS - the inherited row-24 checker cannot certify anything"; exit 1; }
python3 -I tools/check_1023_trap24.py "$LIVE/xnu_arm_entry.elf" --expect on >/dev/null 2>&1 || {
  echo "REFUSING: the LINKED image's mach_trap_table[24] is NOT the ios7lab_mach_port_construct_trap row any more (or rows 25/41/42 moved) - 1024 moves the ceiling and must ADD nothing else; with the row gone the 1023 frontier is back. Re-run scripts/build_1024.sh"; exit 1; }
echo "   BY VALUE(3): tools/check_1023_trap24.py --expect on PASSes (1023's row 24 is intact, rows 25/41/42 still kern_invalid)"
# 1020's by-value clause, re-run on the LINKED image: `sleh_undef`'s user arm must still reach the
# EXC-printf raise on the VFP-already-enabled path.
[[ -f tools/check_d13_undef_raise.py ]] || { echo "REFUSING: tools/check_d13_undef_raise.py is ABSENT - it is the inherited 1020 claim's by-value check on the linked image (the build writes it, so an absent one means the build tree is incomplete)"; exit 1; }
python3 -I tools/check_d13_undef_raise.py "$LIVE/xnu_arm_entry.elf" --expect on >/dev/null 2>&1 || {
  echo "REFUSING: tools/check_d13_undef_raise.py --expect on did NOT pass on the linked image - 1020's moved \`return\` is NOT in this image's sleh_undef, so the udf loop is back and this rung would measure a different frontier. Re-run scripts/build_1024.sh"; exit 1; }
echo "   BY VALUE(4): tools/check_d13_undef_raise.py --expect on PASSes (1020's raise is intact in the linked image)"
# 1018's by-value census: `__wrap_sleh_undef` in the LINKED image must branch to the DIRECT writer
# (entry_write_kv), NOT the capped one ([[mi4-linked-code-order-is-not-source-order]]).
_ua=$(arm-none-eabi-nm "$LIVE/xnu_arm_entry.elf" | awk '$3=="__wrap_sleh_undef"{print "0x" $1; n++} END{exit(n==1?0:1)}') || {
  echo "REFUSING: __wrap_sleh_undef is not in the parked image (or is defined more than once) - the undef witness is gone"; exit 1; }
_ub=$(arm-none-eabi-nm -n "$LIVE/xnu_arm_entry.elf" | awk -v s="${_ua#0x}" 'BEGIN{sv=strtonum("0x" s)}{a=strtonum("0x" $1)} a>sv{if(!d){print "0x" $1; d=1}}') || true
[[ -n $_ub ]] || { echo "REFUSING: no symbol follows __wrap_sleh_undef ($_ua) - its range cannot be read"; exit 1; }
_ud=$(arm-none-eabi-objdump -d "$LIVE/xnu_arm_entry.elf" --start-address="$_ua" --stop-address="$_ub")
_kv=$(grep -c '<entry_write_kv>' <<<"$_ud" || true)
_lw=$(grep -c '<entry_live_write>' <<<"$_ud" || true)
[[ $_kv -ge 6 && $_lw -eq 0 ]] || {
  echo "REFUSING: the parked image's __wrap_sleh_undef ($_ua..$_ub) branches to entry_write_kv $_kv time(s) and entry_live_write $_lw time(s) - with the switch on it must be >=6 direct and 0 counted. A park that kept the counted branch freezes an arm whose witness the cap can still silence."; exit 1; }
echo "   BY VALUE(5): __wrap_sleh_undef ($_ua..$_ub) branches to entry_write_kv x$_kv, entry_live_write x$_lw (1018's witness is on the DIRECT channel)"

PARK=$LIVE/frozen/$ARM
[[ -d $PARK ]] && { echo "REFUSING: $PARK already exists"; exit 1; }
mkdir -p "$PARK"
for m in "${MEMBERS[@]}"; do cp -p "$LIVE/$m" "$PARK/$m"; done

# THE FROZEN RE-READ.  The checks above ran on the LIVE artifacts (so a bad arm never creates a park
# directory); this re-runs the rung's own claims on the PARKED bytes, so what is frozen is what was
# certified - a later build cannot silently change what was pressed.
python3 -I tools/check_vm_max_split.py "$PARK/xnu_arm_entry.elf" --expect on >/dev/null 2>&1 || {
  echo "REFUSING: the FROZEN $PARK/xnu_arm_entry.elf does not carry the ceiling claim the live one did - the copy is not the certified bytes. This park's directory is incomplete; remove $PARK and re-run"; exit 1; }
python3 -I tools/check_1023_trap24.py "$PARK/xnu_arm_entry.elf" --expect on >/dev/null 2>&1 || {
  echo "REFUSING: the FROZEN $PARK/xnu_arm_entry.elf lost 1023's row-24 claim - the copy is not the certified bytes. This park's directory is incomplete; remove $PARK and re-run"; exit 1; }
echo "   BY VALUE(6): the FROZEN $PARK/xnu_arm_entry.elf's task map ceiling reads 0x40000000 AND 1023's row 24 is intact (the parked bytes are the certified bytes)"

{
  printf '# %s  -  1024: MAKE THE TASK MAP CEILING AGREE WITH THE HARDWARE SPLIT (VM_MAX_ADDRESS 0x80000000 -> 0x40000000).\n' "$ARM"
  printf '# (The 1023 press read T24-FIRES: trap 24 IS dispatched, mach_port_construct returns 0 x4, and the\n'
  printf '#  frontier moved to a ~2^20-iteration DATA-ABORT loop in pid 1 at user VA 0x40083008\n'
  printf '#  (records/1023-press-read.txt): abt_pc = 0x39ded790 - slide 0x01bac000 = 0x38241790 =\n'
  printf '#  libsystem_pthread.dylib + 0x2790 = _pthread_create+0xbc, the instruction `ldr r0,[r5,#8]` with\n'
  printf '#  r5 = 0x40083000 (out-param 1 of __pthread_allocate_stack), abt_ptel2 = 0.\n'
  printf '#  ROOT CAUSE, all read by value: set_mmu_ttbcr(2) (osfmk/arm/arm_vm_init.c:475) gives TTBR0\n'
  printf '#  exactly 1 GiB - [0, 0x40000000) - while task_create_internal links\n'
  printf '#  vm_map_create(pmap, 0, VM_MAX_ADDRESS, TRUE, ...) with VM_MAX_ADDRESS = 0x80000000 (MEASURED\n'
  printf '#  at 80085cf0 `mov r2,#-2147483648` before 80085cfc `bl vm_map_create` in the armed 1023 image),\n'
  printf '#  because vm_param.h:62-68 compiles the `#else` branch on CANCRO. The first big\n'
  printf '#  anywhere-allocation (pthread stack) was placed ABOVE the split, where the hardware walks TTBR1\n'
  printf '#  (the kernel tree) and finds nothing; vm_fault "succeeds" for ever. docs/1024-design.md.)\n'
  printf '# Switch set is 1023-s VERBATIM with **ONE NEW SWITCH: STAGE90_XNU_VM_MAX_SPLIT=1**.\n'
  printf '# THE ARM: ONE header line - vm_param.h:63\n'
  printf '#   `#if BOARD_CONFIG_ARMPBA8 || BOARD_CONFIG_QSD8250_LEO`\n'
  printf '# ->` || (defined(STAGE90_XNU_VM_MAX_SPLIT) && STAGE90_XNU_VM_MAX_SPLIT)`, `defined()` FIRST so\n'
  printf '# OFF compiles the tree-s original line byte for byte; staged by tools/patch_d13_vm_max_split.py\n'
  printf '# with a two-arm real-preprocessor proof (OFF -> 0x80000000, ON -> 0x40000000).\n'
  printf '# THE CHANNEL IS THE GLOBAL DEFINES ARRAY of tools/build_xnu_arm_kernel.sh (env), NOT EXTRA: the\n'
  printf '# EABI-runtime and firehose blocks expand ${DEFINES[@]} but NOT ${EXTRA_DEFINES[@]}, so an\n'
  printf '# EXTRA-only build would leave those TUs on the old ceiling behind a green build.\n'
  printf '# THE POOL MOVES: vm_param.h is a HEADER every pool TU includes, so the WHOLE pool (and the\n'
  printf '# entry .bin whose sha8 IS the arm) MOVES (10b79e5d -> %s). build_entry.sh only LINKS the pool\n'
  printf '# objects, so a green entry build says nothing about this half.\n#\n' "${ARM#armed-d13-}"
  printf '# THE BY-VALUE PROOF OF 1024-S CHANGE, asserted FIRST and re-run on the FROZEN bytes.\n'
  printf '# tools/check_vm_max_split.py reads task_create_internal BY VALUE (both ends resolved by NAME):\n'
  printf '#   (0) --selftest PASSes (the checker can fail);\n'
  printf '#   (1) --expect on PASSes on the LINKED out/stage90/xnu_arm_entry.elf: the mov r2,#imm feeding\n'
  printf '#       bl vm_map_create reads 0x40000000;\n'
  printf '#   (2) NEGATIVE CONTROL - the SAME checker --expect off PASSes on the frozen PRE-RUNG arm\n'
  printf '#       1023 (armed-d13-10b79e5d), whose ceiling IS 0x80000000 (1024 is the FIRST rung to move\n'
  printf '#       it), so the on direction is a reading and not a constant\n'
  printf '#       ([[mi4-a-claim-in-a-comment-is-not-a-check]]).\n#\n'
  printf '# THE CARRIERS ([[mi4-one-value-two-definitions]]). The record carries STAGE90_XNU_VM_MAX_SPLIT=1\n'
  printf '# (the switch the widened header line reads AND the readability carrier). The declaration carrier\n'
  printf '# out/stage90/xnu_arm_entry-arm-extra.txt is written by THIS build-s tail as\n'
  printf '# STAGE90_XNU_GLOBAL_FIX=1 role=1024-vm-max-split (1015b-s GLOBAL_FIX is a POOL switch no writer\n'
  printf '# in src/entry/ echoes, so the record cannot carry it); the grep of it is the process check and\n'
  printf '# the pmap_flush_tlbs fingerprint is the proof.\n#\n'
  printf '# THE INHERITED REGRESSIONS held (asserted by the park): STAGE90_XNU_GENERAL_REGS=1 (1021d-s\n'
  printf '# -msoft-float; the WHOLE pool re-OBJECTed), STAGE90_XNU_UNDEF_RAISE=1 and\n'
  printf '# STAGE90_XNU_UNDEF_DIRECT=1 and STAGE90_XNU_IOS7_TRAPS=1 in the record, the pmap_flush_tlbs\n'
  printf '# kernel_pmap==3 fingerprint (1015b-s kernel fix), the whole-pool NEON-free census + the linked\n'
  printf '# mach_msg_send NEON-free read (1021d), check_1023_trap24.py --expect on (1023-s row 24 intact,\n'
  printf '# rows 25/41/42 still kern_invalid), check_d13_undef_raise.py --expect on on the linked image\n'
  printf '# (1020-s raise intact), and by value __wrap_sleh_undef branching to entry_write_kv (>=6) and\n'
  printf '# NOT entry_live_write (0).\n#\n'
  printf '# THE 1024 VERDICT CELLS (docs/1024-design.md sec.4; read via tools/check_1024_capture.py):\n'
  printf '#   STORM-GONE     - the 1023 storm signature (abt_pc 0x38241790 slide-corrected / abt_far\n'
  printf '#                    0x40083008) is ABSENT AND the prior controls still hold (trap24 frame x4,\n'
  printf '#                    port_construct result=0 x4, xnu_live_undef_seq = 0x, zero panics) =>\n'
  printf '#                    WALL MOVED (the checker reports the NEW frontier).\n'
  printf '#   STORM-PERSISTS - the storm recurs at 1023-s pc/far at scale => the patch did not reach the\n'
  printf '#                    compiled image; read check_vm_max_split.py <elf> --expect on first.\n'
  printf '#   STORM-MOVED    - a storm exists elsewhere; any abt_far >= 0x40000000 means the map was not\n'
  printf '#                    the only producer (1024-W-s registry names the culprit).\n'
  printf '#   PRIOR-RUNGS-REGRESSED - one of the prior rungs- controls regressed => the arm-s switch set\n'
  printf '#                    is wrong, not the fix.\n'
  printf '#   G-CTL / WITHHOLD - neither the live channel nor any IOS7LAB line is live => no reading.\n'
  printf '# Medium: 968 real iOS 7.1.2 HFSX rootfs over hfs_rmd0; CARD_COW=1, HDD_WRITE=0, base never\n'
  printf '# written - fully reversible. fastboot boot only, NEVER flash.\n'
  printf '# =================================================================================================\n'
  for m in "${MEMBERS[@]}"; do
    h=$(sha256sum "$PARK/$m" | awk '{print $1}')
    b=$(stat -c %s "$PARK/$m")
    printf 'set=%s sha256=%s bytes=%s file=%s role=1024-vm-max-split;%s\n' \
      "$ARM" "$h" "$b" "$m" "$m"
  done
} >> "$REC"

echo "parked $ARM ($(ls -1 "$PARK" | wc -l) members)"
tools/verify_revert_set.sh "$PARK" --set="$ARM" 2>&1 | tail -3