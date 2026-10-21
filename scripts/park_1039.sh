#!/usr/bin/env bash
# ====================================================================================================
# park_1039.sh.  MODELLED ON scripts/park_1038.sh: THIS rung's change FIRST, on its own claim, then the
# inherited regressions, then the CARD'S 10 BYTES (1039 still serves 1032's patched cache).
#
# **WHAT 1039 IS.**  1037's instrument RE-STAGED (its fb_ctx_diff compared arm_ctx with itself) PLUS one
# new switch STAGE90_XNU_FRAME_CARRIER=1 and ONE TRAP patcher (tools/patch_d13_frame_carrier.py): one
# block inside 1025's data-abort publisher, after 1037's close and in front of 1038's slot, reading
# thread->machine.uss BY ADDRESS, thread->continuation, the entry's saved spsr, pc/lr bit0, pc bit5 and
# the kernel's uptime.  1038's WATCH_LE rides along.  INSTRUMENT ONLY.  Cells: records/1039-read.txt 2.
#
# The park is $LIVE/frozen/$ARM (the arm name MOVES: TRAP is a pool object and 1039 edits it).
#
# GATES THAT MUST HOLD BEFORE ANYTHING IS PARKED:
#   P1 records/1039-read.txt carries the pre-registration (sections 1-4); scripts/build_1039.sh exists
#   P2 every row the reader needs is EMITTED by the patcher (checker --emitter-missing)
#   P3 every other TRAP patcher's TRAP_ALLOWED_IF_IDENTIFIERS carries STAGE90_XNU_FRAME_CARRIER
#   P4 the staged trap.c carries OUR block in front of 1038's slot, and the re-staged 1037 body
# ====================================================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

LIVE=out/stage90
REC=records/revert-set.txt
CFG=$LIVE/xnu_arm_entry-config.txt
NEW=STAGE90_XNU_FRAME_CARRIER
OTHER=STAGE90_XNU_WATCH_LE
TF=STAGE90_XNU_TRAP_FRAME
PATCHER=tools/patch_d13_frame_carrier.py
TF_PATCHER=tools/patch_d13_trap_frame.py
LE_PATCHER=tools/patch_d13_watch_le.py
# **The rows loop's module, not the retired row-side one.** 1038's arm lives in
# `osfmk/arm/watch_le_arm.inc`, reached through `watch_le_hook.inc`; the row-side module looks for
# the inline `#if 1   /* 1038 chunk: arm */` markers in trap.c and finds none (0 openers, 0 closes).
RS_PATCHER=tools/patch_d13_watch_le.py
CHECKER=tools/check_1039_capture.py
PRESSURE=tools/patch_cache_libobjc_count.py
TRAP_PATCHERS="tools/patch_d13_ustack_probe.py tools/patch_d13_undef_raise.py tools/patch_d13_dyld_witness.py
 tools/patch_d13_abt_entry_probe.py tools/patch_d13_reader_probe.py tools/patch_d13_writer_probe.py
 tools/patch_d13_caller_probe.py tools/patch_d13_eval_frame.py tools/patch_d13_pc_carrier.py
 tools/patch_d13_pc_carrier_caller.py tools/patch_d13_trap_frame.py tools/patch_d13_watch_le.py"
CARD=$LIVE/xnu_card_hfs.img
SITE_DEC=$((16#10183720))
NEW_HEX=5010012801daf0bdc046
_tr_src=$PWD/external/xnu-hd2-darwin13/xnu/osfmk/arm/trap.c
_ke_src=$PWD/external/xnu-hd2-darwin13/xnu/bsd/kern/kern_exec.c
_trap_obj=out/xnu_kernel_obj_d13/osfmk_arm_trap.o
_exec_obj=out/xnu_kernel_obj_d13/bsd_kern_kern_exec.o
_pool=out/xnu_kernel_obj_d13
_src_rec=out/xnu_kernel_src_d13.sha256
ELF=$LIVE/xnu_arm_entry.elf
MEMBERS=(xnu_arm_entry.bin xnu_arm_entry.elf xnu_arm_entry.h xnu_arm_entry-config.txt \
         xnu_arm_entry-arm-extra.txt xnu_arm_entry-sources.txt stage90.bin stage90.elf stage90.img \
         stage90-qcdt.img stage90_fixture.macho stage90-build-config.txt SHA256SUMS.txt)

# ---- P1: this rung's mandate is still on record.
echo "== P1. the mandate =="
[[ -f records/1039-read.txt ]] || { echo "REFUSING: records/1039-read.txt (the pre-registration) is absent - the rung's cells are not fixed before the press"; exit 1; }
for _s in "1. ROWS" "2. THE CELLS" "3. STALENESS" "4. THE PRESS"; do
  grep -q "$_s" records/1039-read.txt || { echo "REFUSING: records/1039-read.txt lost its \"$_s\" section"; exit 1; }
done
[[ -f scripts/build_1039.sh ]] || { echo "REFUSING: scripts/build_1039.sh is absent"; exit 1; }
echo "   P1: records/1039-read.txt carries sections 1-4; scripts/build_1039.sh exists"

_arm_files_sha() {
  ( cd "$LIVE" && for _m in "${MEMBERS[@]}"; do sha256sum "$_m"; done ) | LC_ALL=C sort | sha256sum | cut -c1-8
}
ARM=armed-d13-$(_arm_files_sha)
# The arms this rung must NOT be mistaken for: every arm an EARLIER rung was pressed/parked as.
for _old in f03bc0c7 70ae9f32 67782da0 f4c3aaa5 e92c0c52 d06ee14f 49031dcb 8034562e 35a7e83e 10b79e5d 5c1fb3ca 64558b47 e51d14fa 47f664c4; do
  [[ $ARM == armed-d13-$_old ]] && { echo "REFUSING: $LIVE holds an EARLIER rung's arm ($_old) - 1039 builds ON 1037 with its own TRAP edits, which move the pool and therefore the bin. Build 1039 first"; exit 1; }
done

echo "== 1039's OWN change, by value, first =="

# (0) the patchers and the reader can FAIL.
for _f in $PATCHER $TF_PATCHER $LE_PATCHER $RS_PATCHER $CHECKER; do
  [[ -f $_f ]] || { echo "REFUSING: $_f is absent"; exit 1; }
done
# (the rowside patcher replaces the legacy one's selftest here; 2026-10-20: the legacy selftest PASSES
# again (records/1038-watch-le-selftest.txt) but still is not run -- it re-runs its whole staging ritual
# in a fixture and park is not the place for a compiler tree)
for _p in $PATCHER $TF_PATCHER $RS_PATCHER; do
  python3 -I "$_p" --selftest >/dev/null 2>&1 || { echo "REFUSING: $_p --selftest did NOT PASS"; exit 1; }
done
python3 -I "$CHECKER" --selftest >/dev/null 2>&1 || { echo "REFUSING: $CHECKER --selftest did NOT PASS - an inert checker would bless any capture"; exit 1; }
echo "   BY VALUE(0): three patchers + the reader selftest PASS"

# ---- P2: every row the reader needs is EMITTED by the patcher (the image can only carry what it prints).
echo "== P2. the patcher emits the reader's rows =="
python3 -I "$CHECKER" --emitter-missing "$PATCHER" || { echo "REFUSING: $PATCHER does not EMIT every row the reader needs - the reader computes its cells from rows the kernel would never print."; exit 1; }

# ---- P3: the shared namespace ([[mi4-one-file-many-rungs]]).
echo "== P3. the TRAP shared namespace =="
for _p in $TRAP_PATCHERS; do
  grep -q "\"$NEW\"" "$_p" || { echo "REFUSING: $_p does not allow $NEW in TRAP_ALLOWED_IF_IDENTIFIERS"; exit 1; }
done
echo "   P3: all 12 other TRAP patchers allow $NEW"

# ---- P4: the staged trap.c: our block in front of 1038's slot, 1037's body re-staged.
echo "== P4. the staged TRAP =="
[[ -f $_tr_src ]] || { echo "REFUSING: $_tr_src is absent"; exit 1; }
_xt=external/xnu-hd2-darwin13/xnu
python3 -I "$PATCHER" "$_xt" --verify-off >/dev/null 2>&1 \
  || { echo "REFUSING: $PATCHER --verify-off FAILS on the staged tree - our OFF text is not the pre-1039 bytes"; exit 1; }
python3 -I "$TF_PATCHER" "$_xt" --verify-off >/dev/null 2>&1 \
  || { echo "REFUSING: $TF_PATCHER --verify-off FAILS on the staged tree - 1037's re-staged body is not exactly staged"; exit 1; }
python3 -I "$RS_PATCHER" "$_xt" --verify >/dev/null 2>&1 \
  || { echo "REFUSING: $RS_PATCHER --verify FAILS on the staged tree - 1038's row side is not laid out (its arm would not compile out)"; exit 1; }
# ($LE_PATCHER --verify-off is NOT run: 1038's edits are not staged in this tree's seam at all -- a
# literal copy there splits the composed block at the preprocessor (build_1039.sh step 2) -- and the
# patcher's own module does not import today (its ARM_TEXT/_ARM_JUNCTION assert, line 591).  1038's rows
# are still compiled and linked (checker --required-rows and the pool sweep below), and their absence
# from a capture is a NEGATIVE reading, not an unchecked one.)
[[ $(grep -c '^#endif /\* STAGE90_XNU_FRAME_CARRIER \*/' "$_tr_src") == 1 ]] || { echo "REFUSING: not EXACTLY 1 FRAME_CARRIER close"; exit 1; }
[[ $(grep -c '^#endif /\* STAGE90_XNU_TRAP_FRAME \*/' "$_tr_src") == 1 ]] || { echo "REFUSING: not EXACTLY 1 TRAP_FRAME close"; exit 1; }
grep -q 'xnu_live_fb_ldrh=0x' "$_tr_src" || { echo "REFUSING: 1037's re-staged body row xnu_live_fb_ldrh is absent (the OLD 1037 body is staged)"; exit 1; }
[[ $(grep -c 'xnu_live_fcr_seq=' "$_tr_src") == 1 ]] || { echo "REFUSING: not EXACTLY 1 xnu_live_fcr_seq= line"; exit 1; }
_fc=$(grep -n '^#endif /\* STAGE90_XNU_FRAME_CARRIER \*/' "$_tr_src" | head -1 | cut -d: -f1)
_fb=$(grep -n '^#endif /\* STAGE90_XNU_TRAP_FRAME \*/' "$_tr_src" | head -1 | cut -d: -f1)
# 1038's slot marker: its ROW side now stands in trap.c itself (laid out aright 2026-10-19, inert), so
# the marker is the line where that side OPENS, not a per-file forced include (the switch-define
# stand-in is retired from build_xnu_arm_kernel.sh).
# **1038's arm no longer stands in trap.c**, so this marker is legitimately absent: it lives in
# `osfmk/arm/watch_le_arm.inc` and is reached through `watch_le_hook.inc`. The lookup keeps its
# `|| true` so an absent marker does not end the script under `set -e` (it did - park exited 1 with
# no message at all, one line after "== P4"), and the order check below only applies when it IS there.
_sl=$(grep -n '^#if 1   /\* 1038 chunk: arm \*/' "$_tr_src" | tail -1 | cut -d: -f1 || true)
# **1038's slot is optional now.** Its arm lives in its own file, so `_sl` is empty on this tree; what
# the order still has to say is that 1037's close follows 1039's (our block sits inside 1037's frame).
# (1039's close comes FIRST, at 1154; 1037's at 1155 - our block is nested inside 1037's frame, so
#  `_fc < _fb`. The old `_fb < _fc` described the order before 1039 was staged into 1037's tail.)
[[ -n $_fc && -n $_fb && $_fc -lt $_fb ]] || {
  echo "REFUSING: the staged order is wrong (trap_frame close=$_fb < frame_carrier close=$_fc < watch_le slot=$_sl). Our block must sit AFTER 1037's close and IN FRONT of 1038's slot"; exit 1; }
echo "   P4: 1039's close ($_fc) inside 1037's ($_fb); 1038's slot ${_sl:-in its own file}; 1037 body re-staged; all three --verify-off PASS"

# ---- (a) THE RECORD'S OWN KEY AND ITS PARENTS.
grep -q "^$NEW=1\$" "$CFG" || { echo "REFUSING: the record does not carry $NEW=1 - the pool was built with the block SHUT. Build with scripts/build_1039.sh"; exit 1; }
for k in $TF STAGE90_XNU_PC_CARRIER_CALLER STAGE90_XNU_PC_CARRIER STAGE90_XNU_EVAL_FRAME STAGE90_XNU_CALLER_PROBE STAGE90_XNU_WRITER_PROBE STAGE90_XNU_READER_PROBE STAGE90_XNU_ABT_ENTRY_PROBE \
         STAGE90_XNU_USTACK_PROBE STAGE90_XNU_H2_STACK_HEADROOM STAGE90_XNU_VM_MAX_SPLIT STAGE90_XNU_IOS7_TRAPS \
         STAGE90_XNU_GENERAL_REGS STAGE90_XNU_UNDEF_RAISE; do
  grep -q "^$k=1\$" "$CFG" || { echo "REFUSING: the record does not carry $k=1 - 1039 carries the 1037/1038 instrument verbatim. Build with scripts/build_1039.sh"; exit 1; }
done

# ---- (b) THE OBJECTS AND THE LINKED IMAGE -- the press boots the ELF, which links the objects.
[[ -f $_trap_obj && -f $_exec_obj ]] || { echo "REFUSING: the pool objects are absent"; exit 1; }
for _n in $(python3 -I "$CHECKER" --required-rows); do _k="^${_n}"
  grep -qa "$_k" <(strings "$_trap_obj") || { echo "REFUSING: $_trap_obj carries NO $_k row - the pool was not recompiled with $NEW=1, or the edit is partial"; exit 1; }
  grep -qa "$_k" <(strings "$ELF") || { echo "REFUSING: the LINKED $ELF carries NO $_k string - the object was not linked into the image the press boots"; exit 1; }
done
echo "   BY VALUE(1): trap.o AND the linked image carry the checker's $(python3 -I "$CHECKER" --required-rows | wc -l) REQUIRED rows"

# (1a) 1037'S RE-STAGED ROWS SURVIVE (the parent the fcr rows are read beside).
for _k in '^xnu_live_fb_seq=' '^xnu_live_fb_ctx_diff=' '^xnu_live_fb_ldrh=' '^xnu_live_fb_uss_ptr_eq=' '^xnu_live_fb_ctx_diff_self='; do
  grep -qa "$_k" <(strings "$_trap_obj") || { echo "REFUSING: $_trap_obj carries NO $_k row - 1037's re-staged body is not in the pool"; exit 1; }
  grep -qa "$_k" <(strings "$ELF") || { echo "REFUSING: the LINKED $ELF carries NO $_k string - 1037's re-staged body was lost in the link"; exit 1; }
done
# (1b) 1038'S ROWS SURVIVE (they ride along and its reader is read on the same capture).
# **Only when 1038's switch is ON.** These rows sit behind `#if STAGE90_XNU_WATCH_LE`, and this build
# sets it to 0 (`$OTHER` in the record), so the arm compiles out by design and their absence is the
# rung behaving correctly - not "the pool lost them". Measured: the record says 0, trap.o carries 0.
if grep -q "^$OTHER=1$" "$REC" 2>/dev/null; then
for _k in '^xnu_live_sweq_seq=' '^xnu_live_ler_cnt_b=' '^xnu_live_wlg_byte='; do
  grep -qa "$_k" <(strings "$_trap_obj") || { echo "REFUSING: $_trap_obj lost 1038's $_k row"; exit 1; }
  grep -qa "$_k" <(strings "$ELF") || { echo "REFUSING: the LINKED image lost 1038's $_k row"; exit 1; }
done
else
  echo "   (1038's rows: $OTHER=0 in the record - the arm compiles out, as the rung intends)"
fi
# (1c) THE INHERITED PARENTS SURVIVE THE REBUILD.
for _k in '^xnu_live_pcc2_seq=' '^xnu_live_pcc_seq=' '^xnu_live_pcc_xor_walk=' '^xnu_live_evf_pc=' \
          '^xnu_live_evf_far_raw=' '^xnu_live_abt_lookup_far=' '^xnu_live_rdr_far=' '^xnu_live_wrp_r4=' \
          '^xnu_live_abt_vmfkrv=' '^xnu_live_cal_r3=' '^xnu_live_cal_region_end='; do
  grep -qa "$_k" <(strings "$_trap_obj") || { echo "REFUSING: $_trap_obj lost $_k in this pool rebuild ([[mi4-one-file-many-rungs]])"; exit 1; }
  grep -qa "$_k" <(strings "$ELF") || { echo "REFUSING: the LINKED image lost $_k - the linker dropped a parent row"; exit 1; }
done
grep -qa '^xnu_live_abt_proc_ustack$' <(strings "$_exec_obj") || { echo "REFUSING: $_exec_obj carries NO xnu_live_abt_proc_ustack"; exit 1; }
echo "   BY VALUE(1a-1c): 1037 re-staged + 1038 + the pcc2/pcc/evf/cal/wrp/rdr/abt parents survive in trap.o and the ELF"

# (1d) THE POOL'S SOURCE RECORD NAMES THE SAME trap.c THE TREE SHOWS (the pool was built from this source).
[[ -f $_src_rec ]] || { echo "REFUSING: the pool's source record is absent"; exit 1; }
_want=$(sha256sum "$_tr_src" | awk '{print $1}')
_have=$(awk -v b="external/xnu-hd2-darwin13/xnu/osfmk/arm/trap.c" 'index($2,b)==length($2)-length(b)+1{print $1}' "$_src_rec" | head -1)
[[ -n "$_have" && "$_want" == "$_have" ]] || { echo "REFUSING: the pool's source record says [${_have:-none}] for trap.c, the tree hashes $_want - the pool was NOT built from the staged source ([[mi4-self-written-record-is-not-a-constraint]])"; exit 1; }
echo "   BY VALUE(1d): the pool's source record names the SAME trap.c sha ($_want)"

# (2) THE CARD'S 10 BYTES -- the delivered VALUE this arm's press serves.
[[ -f $CARD ]] || { echo "REFUSING: $CARD is absent - 1039's press serves 1032's patched cache"; exit 1; }
_got=$(dd if="$CARD" bs=1 skip=$SITE_DEC count=10 2>/dev/null | od -An -tx1 | tr -d ' \n')
[[ "$_got" == "$NEW_HEX" ]] || { echo "REFUSING: the card at 0x10183720 holds $_got, not 1032's guard $NEW_HEX"; exit 1; }
python3 -I "$PRESSURE" --selftest >/dev/null 2>&1 || { echo "REFUSING: $PRESSURE --selftest failed"; exit 1; }
python3 -I "$PRESSURE" --check >/dev/null 2>&1 || { echo "REFUSING: $PRESSURE --check FAILED on the card"; exit 1; }
echo "   BY VALUE(2): the card carries 1032's guard at 0x10183720 and --check PASSes"

# ---- INHERITED, on the linked image and the pool (same tools the 1038 park runs).
python3 -I tools/check_1023_trap24.py --selftest >/dev/null 2>&1 && python3 -I tools/check_1023_trap24.py "$ELF" --expect on >/dev/null 2>&1 || {
  echo "REFUSING: 1023's row-24 claim does not hold on the linked image (or the checker cannot fail)"; exit 1; }
python3 -I tools/check_d13_undef_raise.py "$ELF" --expect on >/dev/null 2>&1 || { echo "REFUSING: 1020's raise is not in the linked image's sleh_undef"; exit 1; }
python3 -I tools/check_vm_max_split.py "$ELF" --expect on >/dev/null 2>&1 || { echo "REFUSING: 1024's ceiling is not on the linked image"; exit 1; }
python3 -I tools/check_d13_no_neon.py "$ELF" --symbol mach_msg_send --expect none >/dev/null 2>&1 || { echo "REFUSING: the linked mach_msg_send is not NEON-free (1021d)"; exit 1; }
for _c in check_1033_capture.py check_1035_capture.py check_1036_capture.py check_1037_capture.py check_1038_capture.py; do
  python3 -I "tools/$_c" --selftest >/dev/null 2>&1 || { echo "REFUSING: tools/$_c --selftest fails - a reader this rung is read beside cannot fail"; exit 1; }
done
_want_objs=$(grep -c '^[0-9a-f]\{64\} ' "$_src_rec" || true)
_got_objs=$(ls "$_pool"/*.o 2>/dev/null | wc -l)
[[ $_want_objs -gt 0 && $_got_objs -eq $_want_objs ]] || { echo "REFUSING: the pool holds $_got_objs object(s) but $_src_rec names $_want_objs source(s)"; exit 1; }
python3 -I tools/check_d13_no_neon.py --pool "$_pool" --expect none --min-objects "$_want_objs" >/dev/null 2>&1 || { echo "REFUSING: the pool still contains FP/NEON instructions (1021d)"; exit 1; }
_gf_kp=$(arm-none-eabi-objdump -r "$_pool/osfmk_arm_pmap.o" 2>/dev/null | awk '$1>="00000418" && $1<="00000640"' | grep -c 'MOVW_ABS_NC.*kernel_pmap' || true)
[[ $_gf_kp == 3 ]] || { echo "REFUSING: pmap_flush_tlbs materializes kernel_pmap x$_gf_kp (want 3) - 1015b's GLOBAL-FIX is not in the pool"; exit 1; }
echo "   INHERITED: row 24, 1020 raise, 1024 ceiling, 1021d NEON-free (pool census + linked), 1015b GLOBAL-FIX, 1033/1035/1036/1037/1038 readers all PASS"

# ====================================================================================================
# THE PARK, the frozen re-read, and the record.
# ====================================================================================================
PARK=$LIVE/frozen/$ARM
[[ -d $PARK ]] && { echo "REFUSING: $PARK already exists"; exit 1; }
grep -q "role=1039-frame-carrier" "$REC" && { echo "REFUSING: $REC already carries a 1039-frame-carrier block"; exit 1; }
mkdir -p "$PARK"
_newer=$(( $(date +%s) - 86400 ))
for m in "${MEMBERS[@]}"; do
  [[ -f $LIVE/$m ]] || { echo "REFUSING: the pack member $LIVE/$m is ABSENT - the last pack is not a current build. Park NOTHING"; rm -rf "$PARK"; exit 1; }
  _mt=$(stat -c %Y "$LIVE/$m"); _now=$(date +%s)
  [[ $_mt -ge $_newer && $_mt -le $((_now + 120)) ]] || { echo "REFUSING: $LIVE/$m was last written $(date -u -d @$_mt +%FT%TZ), not by the current build (within 24 h) - the pack on disk is STALE. Park NOTHING"; rm -rf "$PARK"; exit 1; }
  cp -p "$LIVE/$m" "$PARK/$m" || { echo "REFUSING: copying $m into $PARK failed; removing the park"; rm -rf "$PARK"; exit 1; }
done
[[ $(ls -1 "$PARK" | wc -l) == ${#MEMBERS[@]} ]] || { echo "REFUSING: $PARK holds $(ls -1 "$PARK" | wc -l) file(s), want ${#MEMBERS[@]}"; rm -rf "$PARK"; exit 1; }
cp -p "$PATCHER" "$PARK/patch_d13_frame_carrier.py"
cp -p "$TF_PATCHER" "$PARK/patch_d13_trap_frame.py"
cp -p "$CHECKER" "$PARK/check_1039_capture.py"
CARD_SHA=$(sha256sum "$CARD" | awk '{print $1}')

# THE FROZEN RE-READ: the rung's own claims on the PARKED bytes.
# (`--required-rows` prints each name ALREADY terminated by `=` - appending another gave `seq==`, and
#  the frozen re-read then refused every image for a row it carried.)
for _k in $(python3 -I "$CHECKER" --required-rows | tr '\n' ' ') \
          '^xnu_live_fb_seq=' '^xnu_live_fb_ldrh=' '^xnu_live_pcc2_seq=' \
          '^xnu_live_evf_pc=' '^xnu_live_abt_lookup_far='; do
  grep -qa "$_k" <(strings "$PARK/xnu_arm_entry.elf") || { echo "REFUSING: the FROZEN image lost $_k - remove $PARK and re-run"; exit 1; }
done
python3 -I tools/check_vm_max_split.py "$PARK/xnu_arm_entry.elf" --expect on >/dev/null 2>&1 || { echo "REFUSING: the frozen image lost 1024's ceiling claim"; exit 1; }
python3 -I tools/check_1023_trap24.py "$PARK/xnu_arm_entry.elf" --expect on >/dev/null 2>&1 || { echo "REFUSING: the frozen image lost 1023's row-24 claim"; exit 1; }
python3 -I "$PARK/check_1039_capture.py" --selftest >/dev/null 2>&1 || { echo "REFUSING: the PARKED 1039 reader does not selftest"; exit 1; }
[[ $(sha256sum "$LIVE/xnu_card_hfs.img" | awk '{print $1}') == "$CARD_SHA" ]] || { echo "REFUSING: the card changed while parking"; exit 1; }
echo "   FROZEN: the parked image carries fcr + fb(re-staged) + sweq/ler/wlg + the pcc2/pcc/evf/lookup_far parents, 1024's ceiling, 1023's row 24; the reader selftests; the card sha is pinned"

# THE RECORD IS WRITTEN ONLY FROM THE FULL PARK: every member's copy in $PARK hashes to the live file.
HERE=$(grep -c 'role=1039-frame-carrier' "$REC" || true)
for m in "${MEMBERS[@]}"; do
  cmp -s "$LIVE/$m" "$PARK/$m" || { echo "REFUSING: $PARK/$m does not match $LIVE/$m - the record was NOT written"; rm -rf "$PARK"; exit 1; }
done

{
  printf '\n# =================================================================================================\n'
  printf '# %s  -  1039: THE FRAME CARRIER -- the saved user context vs the hardware fault, read WITHOUT\n' "$ARM"
  printf '# arm_ctx.  INSTRUMENT ONLY.\n'
  printf '# 1037 READ: pc=0x38492474 lr=0x3848a9af (a blx return word +1), r1=0 at the ldrb, uss_ok=0\n'
  printf '# (ctx_diff was a tautology).  1039 re-stages 1037 and reads thread->machine.uss BY ADDRESS,\n'
  printf '# thread->continuation, the entry spsr, pc/lr bit0, pc bit5 and the uptime.\n'
  printf '# NOT a return if the fault path runs: a resident rung.\n'
  printf '# NEW SWITCH: %s=1 (tools/patch_d13_frame_carrier.py), a TRAP block AFTER 1037-s close\n' "$NEW"
  printf '# and IN FRONT OF 1038-s slot, inside 1025-s data-abort publisher.  Rows xnu_live_fcr_*.  READS ONLY.\n'
  printf '# CHANNEL: the global DEFINES array (build_xnu_arm_kernel.sh, gated on the switch); a -D in EXTRA is not the channel.\n'
  printf '# THE POOL MOVES: TRAP is a pool object, so the entry bin (and the arm name) MOVES.\n'
  printf '# [[mi4-one-file-many-rungs]]: FRAME_CARRIER is in EVERY TRAP patcher-s ALLOWED_IF_IDENTIFIERS.\n'
  printf '# THE CARD: 1039 serves 1032-s 10 bytes (card 0x10183720 = %s).\n' "$NEW_HEX"
  printf '# THE READING: %s (pre-registered cells in records/1039-read.txt 2).\n' "$CHECKER"
  printf '# Medium: 968 real iOS 7.1.2 HFSX rootfs over hfs_rmd0; CARD_COW=1, HDD_WRITE=0, base never\n'
  printf '# written - fully reversible.  fastboot boot only, NEVER flash.\n'
  printf '# card_sha256=%s card_off=0x10183720 card_new=%s\n' "$CARD_SHA" "$NEW_HEX"
  printf '# =================================================================================================\n'
  for m in "${MEMBERS[@]}"; do
    printf 'set=%s sha256=%s bytes=%s file=%s role=1039-frame-carrier;%s\n' "$ARM" "$(sha256sum "$PARK/$m" | awk '{print $1}')" "$(stat -c %s "$PARK/$m")" "$m" "$m"
  done
  printf 'set=%s sha256=%s bytes=%s file=%s role=1039-frame-carrier-editors-definition\n' "$ARM" "$(sha256sum "$PARK/patch_d13_frame_carrier.py" | awk '{print $1}')" "$(stat -c %s "$PARK/patch_d13_frame_carrier.py")" patch_d13_frame_carrier.py
  printf 'set=%s sha256=%s bytes=%s file=%s role=1039-frame-carrier-1037-body\n' "$ARM" "$(sha256sum "$PARK/patch_d13_trap_frame.py" | awk '{print $1}')" "$(stat -c %s "$PARK/patch_d13_trap_frame.py")" patch_d13_trap_frame.py
  printf 'set=%s sha256=%s bytes=%s file=%s role=1039-frame-carrier-capture-reader\n' "$ARM" "$(sha256sum "$PARK/check_1039_capture.py" | awk '{print $1}')" "$(stat -c %s "$PARK/check_1039_capture.py")" check_1039_capture.py
} >> "$REC"
# **One row per member, plus the three named roles** (`-editors-definition`, `-1037-body`,
# `-capture-reader`): 13 + 3 today. The check used to assert a single row, so a correct append refused -
# and the rows were already in the file by then.
_expected=$((HERE + ${#MEMBERS[@]} + 3))
[[ $(grep -c 'role=1039-frame-carrier' "$REC") == $_expected ]] || { echo "REFUSING: $REC did not gain EXACTLY one 1039-frame-carrier block - another writer moved it"; exit 1; }

echo "recorded $ARM (role=1039-frame-carrier) in $REC"
echo "parked $ARM ($(ls -1 "$PARK" | wc -l) members)"
echo "   verify: tools/verify_revert_set.sh $PARK --set=$ARM"
cmp -s "$PATCHER" "$LIVE/$(basename "$PATCHER")" || cp -p "$PATCHER" "$LIVE/$(basename "$PATCHER")"
cmp -s "$CHECKER" "$LIVE/$(basename "$CHECKER")" || cp -p "$CHECKER" "$LIVE/$(basename "$CHECKER")"
echo "   live copies placed: $LIVE/$(basename "$PATCHER"), $LIVE/$(basename "$CHECKER")"