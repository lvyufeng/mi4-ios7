#!/usr/bin/env bash
# ====================================================================================================
# park_1038.sh.  MODELLED ON scripts/park_1037.sh: THIS rung's change FIRST, on its own claim, then the
# inherited regressions, then the CARD'S 10 BYTES (1038 still serves 1032's patched cache).
#
# **WHAT 1038 IS.**  1037's instrument verbatim (fb/pcc2/pcc/evf/cal/wrp/rdr/abt rows) PLUS one new switch
# STAGE90_XNU_WATCH_LE=1 and ONE TRAP patcher (tools/patch_d13_watch_le.py) with two arms inside 1025's
# failure arm: A (who wrote the stack: xnu_live_sweq_* + the wlg gates) and B (little endian at the table:
# xnu_live_ler_*), plus a hook at sleh_abort.  INSTRUMENT ONLY.  Cells A1-A4/B1-B2: records/1038-read.txt 2.
#
# The park is $LIVE/frozen/$ARM (the arm name MOVES: TRAP is a pool object and 1038 edits it).
#
# GATES THAT MUST HOLD BEFORE ANYTHING IS PARKED (added by the ops lane after review):
#   P1 records/1037-read.txt still carries "1038's TEST" (this rung's mandate) and docs/1038-design.md exists
#   P2 every row the reader needs is EMITTED by the patcher (checker --emitter-missing; generator rows included)
#   P3 every other TRAP patcher's TRAP_ALLOWED_IF_IDENTIFIERS carries STAGE90_XNU_WATCH_LE
# ====================================================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

LIVE=out/stage90
REC=records/revert-set.txt
CFG=$LIVE/xnu_arm_entry-config.txt
NEW=STAGE90_XNU_WATCH_LE
TF=STAGE90_XNU_TRAP_FRAME
PC2=STAGE90_XNU_PC_CARRIER_CALLER
PATCHER=tools/patch_d13_watch_le.py
CHECKER=tools/check_1038_capture.py
TF_PATCHER=tools/patch_d13_trap_frame.py
PC2_PATCHER=tools/patch_d13_pc_carrier_caller.py
PRESSURE=tools/patch_cache_libobjc_count.py
TRAP_PATCHERS="tools/patch_d13_ustack_probe.py tools/patch_d13_undef_raise.py tools/patch_d13_dyld_witness.py
 tools/patch_d13_abt_entry_probe.py tools/patch_d13_reader_probe.py tools/patch_d13_writer_probe.py
 tools/patch_d13_caller_probe.py tools/patch_d13_eval_frame.py tools/patch_d13_pc_carrier.py
 tools/patch_d13_pc_carrier_caller.py tools/patch_d13_trap_frame.py"
CARD=$LIVE/xnu_card_hfs.img
SITE_DEC=$((16#10183720))
NEW_HEX=5010012801daf0bdc046
_tr_src=$PWD/external/xnu-hd2-darwin13/xnu/osfmk/arm/TRAP
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
[[ -f docs/1038-design.md ]] || { echo "REFUSING: docs/1038-design.md is absent - the rung has no design"; exit 1; }
[[ -f records/1037-read.txt ]] && grep -q "1038's TEST" records/1037-read.txt || { echo "REFUSING: records/1037-read.txt no longer carries \"1038's TEST\" - the finding this rung tests was withdrawn or renumbered; a park now would freeze an arm for a question the record no longer asks"; exit 1; }
echo "   P1: docs/1038-design.md exists; records/1037-read.txt still says \"1038's TEST\""

# THE ARM'S NAME IS A CONTENT ADDRESS OF THE WHOLE PACK, not of the entry bin alone (park_1037.sh, this
# hour): two parks against the same bin (e.g. a registration change that touches no entry source) would
# otherwise share one name and the second would overwrite the first's pinned record.  Unchanged bytes
# re-park under the unchanged name.
_arm_files_sha() {
  ( cd "$LIVE" && for _m in "${MEMBERS[@]}"; do sha256sum "$_m"; done ) | LC_ALL=C sort | sha256sum | cut -c1-8
}
ARM=armed-d13-$(_arm_files_sha)
# The arms this rung must NOT be mistaken for: every arm an EARLIER rung was pressed/parked as (1037's own is
# 70ae9f32; the rest are 1036's, 1035's, 1033's, 1031's and 1024-1029's, from records/ and the park scripts).
for _old in 70ae9f32 67782da0 f4c3aaa5 e92c0c52 d06ee14f 49031dcb 8034562e 35a7e83e 10b79e5d 5c1fb3ca 64558b47 e51d14fa 47f664c4; do
  [[ $ARM == armed-d13-$_old ]] && { echo "REFUSING: $LIVE holds an EARLIER rung's arm ($_old) - 1038 builds ON 1037 with its own TRAP edits, which move the pool and therefore the bin. Build 1038 first"; exit 1; }
done

echo "== 1038's OWN change, by value, first =="

# (0) the patcher and the reader can FAIL.
[[ -f $PATCHER ]] || { echo "REFUSING: $PATCHER is absent - it is 1038's whole kernel edit"; exit 1; }
[[ -f $CHECKER ]] || { echo "REFUSING: $CHECKER is absent - it is the capture reader the press is adjudicated by; a park that skipped it would freeze an arm whose own claim nothing checks"; exit 1; }
python3 -I "$PATCHER" --selftest >/dev/null 2>&1 || { echo "REFUSING: $PATCHER --selftest did NOT PASS"; exit 1; }
python3 -I "$CHECKER" --selftest >/dev/null 2>&1 || { echo "REFUSING: $CHECKER --selftest did NOT PASS - an inert checker would bless any capture"; exit 1; }
echo "   BY VALUE(0): $PATCHER --selftest and $CHECKER --selftest PASS"

# ---- P2: every row the reader needs is EMITTED by the patcher (the image can only carry what it prints).
echo "== P2. the patcher emits the reader's rows =="
# A row is emitted either as a prefix LITERAL (`printf("xnu_live_sweq_tdfar=0x%08x\n"`) or through the
# patcher's per-name GENERATOR (`printf("xnu_live_sweq_%s=...", "bp0", k)`).  One shared spelling: the
# SAME parser runs in the checker's selftest (TRAY-COMPLETE case), so the reader and this gate cannot
# drift.  Until 2026-10-19 this block was a hand-rolled grep that could not see generator rows.
python3 -I "$CHECKER" --emitter-missing "$PATCHER" || { echo "REFUSING: $PATCHER does not EMIT every row the reader needs (listed above) - the reader computes its cells from rows the kernel would never print."; exit 1; }

# ---- P3: the shared namespace ([[mi4-one-file-many-rungs]]).
echo "== P3. the TRAP shared namespace =="
for _p in $TRAP_PATCHERS; do
  grep -q "\"$NEW\"" "$_p" || { echo "REFUSING: $_p does not allow $NEW in TRAP_ALLOWED_IF_IDENTIFIERS - build_1038.sh's acceptance sweep refuses the tree, and a tree that did get staged would not be one this rung can own"; exit 1; }
done
echo "   P3: all 11 other TRAP patchers allow $NEW"

# (a) THE RECORD'S OWN KEY AND ITS PARENTS.
grep -q "^$NEW=1\$" "$CFG" || { echo "REFUSING: the record does not carry $NEW=1 - the pool was built with the WATCH_LE block SHUT and the capture could carry no sweq/ler row. Build with scripts/build_1038.sh"; exit 1; }
for k in $TF $PC2 STAGE90_XNU_PC_CARRIER STAGE90_XNU_EVAL_FRAME STAGE90_XNU_CALLER_PROBE STAGE90_XNU_WRITER_PROBE STAGE90_XNU_READER_PROBE STAGE90_XNU_ABT_ENTRY_PROBE \
         STAGE90_XNU_USTACK_PROBE STAGE90_XNU_H2_STACK_HEADROOM STAGE90_XNU_VM_MAX_SPLIT STAGE90_XNU_IOS7_TRAPS \
         STAGE90_XNU_GENERAL_REGS STAGE90_XNU_UNDEF_RAISE STAGE90_XNU_UNDEF_DIRECT; do
  grep -q "^$k=1\$" "$CFG" || { echo "REFUSING: the record does not carry $k=1 - 1038 carries the 1037/1036/1035/1033 instrument and the inherited regressions verbatim. Build with scripts/build_1038.sh"; exit 1; }
done

# (a7) 1038'S OWN CHANGE, ON THE STAGED SOURCE -- one bracketed block AFTER 1037's fb block, inside 1025.
[[ -f $_tr_src ]] || { echo "REFUSING: $_tr_src is absent"; exit 1; }
[[ $(grep -c 'xnu_live_sweq_seq=' "$_tr_src") == 1 ]] || { echo "REFUSING: the staged $_tr_src does not carry EXACTLY 1 xnu_live_sweq_seq= line - the A rows are not staged, or a partial/double edit landed"; exit 1; }
[[ $(grep -c 'xnu_live_ler_seq=' "$_tr_src") == 1 ]] || { echo "REFUSING: the staged $_tr_src does not carry EXACTLY 1 xnu_live_ler_seq= line - the B rows are not staged, or a partial/double edit landed"; exit 1; }
[[ $(grep -c '^#endif /\* STAGE90_XNU_WATCH_LE \*/' "$_tr_src") == 1 ]] || { echo "REFUSING: the staged $_tr_src does not carry EXACTLY 1 \`#endif /* STAGE90_XNU_WATCH_LE */\` marker - the ON/OFF gate is not bracketed"; exit 1; }
_fb=$(grep -n '^#endif /\* STAGE90_XNU_TRAP_FRAME \*/' "$_tr_src" | head -1 | cut -d: -f1)
_wl=$(grep -n '^#endif /\* STAGE90_XNU_WATCH_LE \*/' "$_tr_src" | head -1 | cut -d: -f1)
_ust=$(grep -n '^#endif /\* STAGE90_XNU_USTACK_PROBE \*/' "$_tr_src" | head -1 | cut -d: -f1)
[[ -n $_fb && -n $_wl && -n $_ust && $_fb -lt $_wl && $_wl -lt $_ust ]] || {
  echo "REFUSING: the WATCH_LE gate is NOT bracketed correctly (fb=$_fb < watch_le=$_wl < ustack=$_ust). Its rows must sit INSIDE 1025's publisher and AFTER 1037's block"; exit 1; }
echo "   BY VALUE(1-a7): the staged TRAP carries the WATCH_LE block (x1 gate, x1 #endif) AFTER 1037's ($_fb) and INSIDE 1025's publisher ($_wl < $_ust)"

# (b) THE OBJECTS AND THE LINKED IMAGE -- the press boots the ELF, which links the objects.
[[ -f $_trap_obj && -f $_exec_obj ]] || { echo "REFUSING: the pool objects are absent"; exit 1; }
for _n in $(python3 -I "$CHECKER" --required-rows); do _k="^${_n}="
  grep -qa "$_k" <(strings "$_trap_obj") || { echo "REFUSING: $_trap_obj carries NO $_k row - the pool was not recompiled with $NEW=1, or the edit is partial"; exit 1; }
  grep -qa "$_k" <(strings "$ELF") || { echo "REFUSING: the LINKED $ELF carries NO $_k string - the object was not linked into the image the press boots"; exit 1; }
done
echo "   BY VALUE(1): trap.o AND the linked image carry the checker's REQUIRED_ROWS ($(python3 -I "$CHECKER" --required-rows | tr '\n' ' ')- the names tools/patch_d13_watch_le.py prints)"

# (1a) 1036's pcc2 AND 1037's fb ROWS SURVIVE (the parents the sweq/ler rows are read beside).
for _k in '^xnu_live_pcc2_seq=' '^xnu_live_pcc2_lr_m4=' '^xnu_live_pcc2_tbl_used=' '^xnu_live_fb_seq=' '^xnu_live_fb_ctx_diff='; do
  grep -qa "$_k" <(strings "$_trap_obj") || { echo "REFUSING: $_trap_obj carries NO $_k row - the pool rebuild dropped 1036's pcc2 block or 1037's fb block, which the sweq rows are read beside"; exit 1; }
  grep -qa "$_k" <(strings "$ELF") || { echo "REFUSING: the LINKED $ELF carries NO $_k string - a parent block was lost in the link"; exit 1; }
done
echo "   BY VALUE(1a): the pcc2 (1036) and fb (1037) rows survive in trap.o and the linked image"

# (1b) THE INHERITED PARENTS SURVIVE THE REBUILD (pcc/evf/cal/wrp/rdr/abt).
for _k in '^xnu_live_pcc_seq=' '^xnu_live_pcc_pc=' '^xnu_live_pcc_lr=' '^xnu_live_pcc_xor_walk=' '^xnu_live_pcc_xor_table=' \
          '^xnu_live_evf_pc=' '^xnu_live_evf_far_raw=' '^xnu_live_abt_lookup_far=' '^xnu_live_rdr_far=' '^xnu_live_wrp_r4=' \
          '^xnu_live_abt_vmfkrv=' '^xnu_live_cal_r3=' '^xnu_live_cal_region_end='; do
  grep -qa "$_k" <(strings "$_trap_obj") || { echo "REFUSING: $_trap_obj lost $_k in this pool rebuild - the parent rows are gone ([[mi4-one-file-many-rungs]])"; exit 1; }
  grep -qa "$_k" <(strings "$ELF") || { echo "REFUSING: the LINKED image lost $_k - the linker dropped a parent row"; exit 1; }
done
grep -qa '^xnu_live_abt_proc_ustack$' <(strings "$_exec_obj") || { echo "REFUSING: $_exec_obj carries NO xnu_live_abt_proc_ustack"; exit 1; }
grep -qa '^xnu_live_ustack_req=' <(strings "$_exec_obj") || { echo "REFUSING: $_exec_obj lost 1025's xnu_live_ustack_req="; exit 1; }
echo "   BY VALUE(1b): the parent chain survives (pcc/evf/cal/wrp/rdr/abt in trap.o and the ELF; ustack accessor + 1025 publisher in kern_exec.o)"

# (2) THE CARD'S 10 BYTES -- the delivered VALUE this arm's press serves.
[[ -f $CARD ]] || { echo "REFUSING: $CARD is absent - 1038's press serves 1032's patched cache"; exit 1; }
_got=$(dd if="$CARD" bs=1 skip=$SITE_DEC count=10 2>/dev/null | od -An -tx1 | tr -d ' \n')
[[ "$_got" == "$NEW_HEX" ]] || { echo "REFUSING: the card at 0x10183720 holds $_got, not 1032's guard $NEW_HEX - the park would describe an arm whose card is not the one it serves. Run scripts/build_1038.sh"; exit 1; }
python3 -I "$PRESSURE" --check >/dev/null 2>&1 || { echo "REFUSING: $PRESSURE --check FAILED on the card"; exit 1; }
echo "   BY VALUE(2): the card carries 1032's guard at 0x10183720 and --check PASSes (content anchor included)"

# ---- INHERITED, on the linked image and the pool (same tools the 1037 park runs).
python3 -I tools/check_1023_trap24.py --selftest >/dev/null 2>&1 && python3 -I tools/check_1023_trap24.py "$ELF" --expect on >/dev/null 2>&1 || {
  echo "REFUSING: 1023's row-24 claim does not hold on the linked image (or the checker cannot fail)"; exit 1; }
python3 -I tools/check_d13_undef_raise.py "$ELF" --expect on >/dev/null 2>&1 || { echo "REFUSING: 1020's raise is not in the linked image's sleh_undef"; exit 1; }
python3 -I tools/check_vm_max_split.py "$ELF" --expect on >/dev/null 2>&1 || { echo "REFUSING: 1024's ceiling is not on the linked image"; exit 1; }
python3 -I tools/check_d13_no_neon.py "$ELF" --symbol mach_msg_send --expect none >/dev/null 2>&1 || { echo "REFUSING: the linked mach_msg_send is not NEON-free (1021d)"; exit 1; }
for _c in check_1033_capture.py check_1035_capture.py check_1036_capture.py check_1037_capture.py; do
  python3 -I "tools/$_c" --selftest >/dev/null 2>&1 || { echo "REFUSING: tools/$_c --selftest fails - a reader this rung is read beside cannot fail"; exit 1; }
done
_want_objs=$(grep -c '^[0-9a-f]\{64\} ' "$_src_rec" || true)
_got_objs=$(ls "$_pool"/*.o 2>/dev/null | wc -l)
[[ $_want_objs -gt 0 && $_got_objs -eq $_want_objs ]] || { echo "REFUSING: the pool holds $_got_objs object(s) but $_src_rec names $_want_objs source(s) - the census would count the WRONG set"; exit 1; }
python3 -I tools/check_d13_no_neon.py --pool "$_pool" --expect none --min-objects "$_want_objs" >/dev/null 2>&1 || { echo "REFUSING: the pool still contains FP/NEON instructions (1021d's -msoft-float did not reach every object)"; exit 1; }
_ua=$(arm-none-eabi-nm "$ELF" | awk '$3=="__wrap_sleh_undef"{print "0x" $1; n++} END{exit(n==1?0:1)}') || { echo "REFUSING: __wrap_sleh_undef not found exactly once in the linked image"; exit 1; }
_ub=$(arm-none-eabi-nm -n "$ELF" | awk -v s="${_ua#0x}" 'BEGIN{sv=strtonum("0x" s)}{a=strtonum("0x" $1)} a>sv{if(!d){print "0x" $1; d=1}}') || true
[[ -n $_ub ]] || { echo "REFUSING: no symbol follows __wrap_sleh_undef"; exit 1; }
_ud=$(arm-none-eabi-objdump -d "$ELF" --start-address="$_ua" --stop-address="$_ub")
_ud_kv=$(grep -c '<entry_write_kv>' <<<"$_ud" || true); _ud_lw=$(grep -c '<entry_live_write>' <<<"$_ud" || true)
[[ $_ud_kv -ge 6 && $_ud_lw -eq 0 ]] || { echo "REFUSING: __wrap_sleh_undef branches to entry_write_kv x$_ud_kv (want >=6) / entry_live_write x$_ud_lw (want 0) - 1018's DIRECT witness is not in the image"; exit 1; }
_gf_kp=$(arm-none-eabi-objdump -r "$_pool/osfmk_arm_pmap.o" 2>/dev/null | awk '$1>="00000418" && $1<="00000640"' | grep -c 'MOVW_ABS_NC.*kernel_pmap' || true)
[[ $_gf_kp == 3 ]] || { echo "REFUSING: pmap_flush_tlbs materializes kernel_pmap x$_gf_kp (want 3) - 1015b's GLOBAL-FIX is not in the pool"; exit 1; }
echo "   INHERITED: row 24, 1020 raise, 1024 ceiling, 1021d NEON-free (pool census + linked), 1018 direct witness, 1015b GLOBAL-FIX, 1033/1035/1036/1037 readers all PASS"

# ====================================================================================================
# THE PARK, the frozen re-read, and the record.
# ====================================================================================================
PARK=$LIVE/frozen/$ARM
[[ -d $PARK ]] && { echo "REFUSING: $PARK already exists"; exit 1; }
grep -q "role=1038-watch-le" "$REC" && { echo "REFUSING: $REC already carries a 1038-watch-le block"; exit 1; }
mkdir -p "$PARK"
# THE MEMBER LIST IS THE CURRENT PACK'S, read off the files the builder JUST wrote -- never a list copied
# from a previous park.  (A stale name here hit ENOENT, and `set -e` did not stop the record write: the
# record then named a set with a missing member.)  A member that is absent REFUSES, by name.
_newer=$(( $(date +%s) - 86400 ))
for m in "${MEMBERS[@]}"; do
  [[ -f $LIVE/$m ]] || { echo "REFUSING: the pack member $LIVE/$m is ABSENT - the last pack is not a current build (scripts/build_1038.sh names every member it writes). Park NOTHING"; exit 1; }
  _mt=$(stat -c %Y "$LIVE/$m"); _now=$(date +%s)
  [[ $_mt -ge $_newer && $_mt -le $((_now + 120)) ]] || { echo "REFUSING: $LIVE/$m was last written $(date -u -d @$_mt +%FT%TZ), not by the current build (within 24 h) - the pack on disk is STALE. Park NOTHING"; exit 1; }
  cp -p "$LIVE/$m" "$PARK/$m" || { echo "REFUSING: copying $m into $PARK failed - the park is incomplete; removing it"; rm -rf "$PARK"; exit 1; }
done
[[ $(ls -1 "$PARK" | wc -l) == ${#MEMBERS[@]} ]] || { echo "REFUSING: $PARK holds $(ls -1 "$PARK" | wc -l) file(s), want ${#MEMBERS[@]} - an incomplete pack; removing it"; rm -rf "$PARK"; exit 1; }
cp -p "$PATCHER" "$PARK/patch_d13_watch_le.py"
cp -p "$CHECKER" "$PARK/check_1038_capture.py"
CARD_SHA=$(sha256sum "$CARD" | awk '{print $1}')

# THE FROZEN RE-READ: the rung's own claims on the PARKED bytes.
for _k in $(python3 -I "$CHECKER" --required-rows | sed 's/$/=/' | tr '\n' ' ') \
          '^xnu_live_fb_seq=' '^xnu_live_pcc2_seq=' '^xnu_live_pcc_pc=' '^xnu_live_evf_pc=' \
          '^xnu_live_cal_region_end=' '^xnu_live_wrp_r4=' '^xnu_live_abt_lookup_far='; do
  grep -qa "$_k" <(strings "$PARK/xnu_arm_entry.elf") || { echo "REFUSING: the FROZEN $PARK/xnu_arm_entry.elf lost $_k - the copy is not the certified bytes; remove $PARK and re-run"; exit 1; }
done
python3 -I tools/check_vm_max_split.py "$PARK/xnu_arm_entry.elf" --expect on >/dev/null 2>&1 || { echo "REFUSING: the frozen image lost 1024's ceiling claim"; exit 1; }
python3 -I tools/check_1023_trap24.py "$PARK/xnu_arm_entry.elf" --expect on >/dev/null 2>&1 || { echo "REFUSING: the frozen image lost 1023's row-24 claim"; exit 1; }
python3 -I "$PARK/check_1038_capture.py" --selftest >/dev/null 2>&1 || { echo "REFUSING: the PARKED 1038 reader does not selftest"; exit 1; }
[[ $(sha256sum "$LIVE/xnu_card_hfs.img" | awk '{print $1}') == "$CARD_SHA" ]] || { echo "REFUSING: the card changed while parking"; exit 1; }
echo "   FROZEN: the parked image carries sweq/ler/wlg + fb + pcc2 + pcc + evf + cal + wrp + lookup_far, 1024's ceiling, 1023's row 24; the reader selftests; the card sha is pinned"


# THE RECORD IS WRITTEN ONLY FROM THE FULL PARK: every member's copy in $PARK hashes to the live file.  A
# stale or absent member is a NAMED refusal HERE, before the record moves - `set -e` alone did not stop the
# write (measured this hour on 1037), so the check is the writer, not the shell.
HERE=$(grep -c 'role=1038-watch-le' "$REC" || true)     # the record must not move between here and the write
for m in "${MEMBERS[@]}"; do
  cmp -s "$LIVE/$m" "$PARK/$m" || { echo "REFUSING: $PARK/$m does not match $LIVE/$m - the record was NOT written"; exit 1; }
done

{
  printf '\n# =================================================================================================\n'
  printf '# %s  -  1038: THE STACK WATCH (A) AND LITTLE ENDIAN AT THE TABLE (B), BY VALUE.  INSTRUMENT ONLY.\n' "$ARM"
  printf '# 1036 READ: s3 == 0xffffffff at sp+0xc is the one-byte-skewed copy of file 0x5d3bd7 (STRONG, NOT\n'
  printf '# PROVEN); the walk ran with r1 = 0 and the ldrb faulted at 0x10.  1038 records who wrote the\n'
  printf '# stack and whether the kernel word view and the byte view of the count differ.\n'
  printf '# NOT a return if the fault path runs: a resident rung.\n'
  printf '# NEW SWITCH: %s=1 (tools/patch_d13_watch_le.py), a TRAP block INSIDE\n' "$NEW"
  printf '# 1025-s publisher AFTER 1037-s fb block, plus a hook at the top of sleh_abort.\n'
  printf '# Rows xnu_live_sweq_* (A), xnu_live_ler_* (B), xnu_live_wlg_* (the kernel-s own gates).  READS ONLY.\n'
  printf '# CHANNEL: the global DEFINES array (build_xnu_arm_kernel.sh); a -D in EXTRA is not the channel.\n'
  printf '# THE POOL MOVES: TRAP is a pool object, so the entry bin (and the arm name) MOVES.\n'
  printf '# [[mi4-one-file-many-rungs]]: WATCH_LE is in EVERY TRAP patcher-s ALLOWED_IF_IDENTIFIERS.\n'
  printf '# THE CARD: 1038 serves 1032-s 10 bytes (card 0x10183720 = %s).\n' "$NEW_HEX"
  printf '# THE READING: %s (pre-registered cells A1-A4/B1-B2 in records/1038-read.txt 2).\n' "$CHECKER"
  printf '# Medium: 968 real iOS 7.1.2 HFSX rootfs over hfs_rmd0; CARD_COW=1, HDD_WRITE=0, base never\n'
  printf '# written - fully reversible.  fastboot boot only, NEVER flash.\n'
  printf '# card_sha256=%s card_off=0x10183720 card_new=%s\n' "$CARD_SHA" "$NEW_HEX"
  printf '# =================================================================================================\n'
  for m in "${MEMBERS[@]}"; do
    printf 'set=%s sha256=%s bytes=%s file=%s role=1038-watch-le;%s\n' "$ARM" "$(sha256sum "$PARK/$m" | awk '{print $1}')" "$(stat -c %s "$PARK/$m")" "$m" "$m"
  done
  printf 'set=%s sha256=%s bytes=%s file=%s role=1038-watch-le-editors-definition\n' "$ARM" "$(sha256sum "$PARK/patch_d13_watch_le.py" | awk '{print $1}')" "$(stat -c %s "$PARK/patch_d13_watch_le.py")" patch_d13_watch_le.py
  printf 'set=%s sha256=%s bytes=%s file=%s role=1038-watch-le-capture-reader\n' "$ARM" "$(sha256sum "$PARK/check_1038_capture.py" | awk '{print $1}')" "$(stat -c %s "$PARK/check_1038_capture.py")" check_1038_capture.py
} >> "$REC"
[[ $(grep -c 'role=1038-watch-le' "$REC") == $((HERE + 1)) ]] || { echo "REFUSING: $REC did not gain EXACTLY one 1038-watch-le block - another writer moved it"; exit 1; }

echo "recorded $ARM (role=1038-watch-le) in $REC"
echo "parked $ARM ($(ls -1 "$PARK" | wc -l) members)"
echo "   verify: tools/verify_revert_set.sh $PARK --set=$ARM"
# THE LIVE COPIES the record's file= lines also name (the press's preflight reads one directory at a time).
cmp -s "$PATCHER" "$LIVE/$(basename "$PATCHER")" || cp -p "$PATCHER" "$LIVE/$(basename "$PATCHER")"
cmp -s "$CHECKER" "$LIVE/$(basename "$CHECKER")" || cp -p "$CHECKER" "$LIVE/$(basename "$CHECKER")"
echo "   live copies placed: $LIVE/$(basename "$PATCHER"), $LIVE/$(basename "$CHECKER") (identical bytes to the park's)"