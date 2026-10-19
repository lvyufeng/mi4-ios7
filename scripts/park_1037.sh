#!/usr/bin/env bash
# ====================================================================================================
# park_1037.sh.  MODELLED ON scripts/park_1036.sh: THIS rung's change FIRST, on its own claim, then the
# inherited regressions, then the CARD'S 10 BYTES (1037 still serves 1032's patched cache).
#
# **WHAT 1037 IS.**  1036's instrument verbatim (pcc2/pcc/evf/cal/wrp/rdr/abt rows) PLUS one new switch
# STAGE90_XNU_TRAP_FRAME=1 and one new trap.c block (tools/patch_d13_trap_frame.py) that compares the trap
# entry's own uss `stmea {r0-lr}^` copy, read through the TASK MAP, with the C-side `arm_ctx`, and derives
# the slide from lr alone.  Rows `xnu_live_fb_*` (seq/ctx_diff/uss/dbg_off/dbg_off_ok and the tray).
# INSTRUMENT ONLY.  Cells D1/D2/D3/L1: records/1037-read.txt 2.
#
# The park is $LIVE/frozen/$ARM (the arm name MOVES: trap.c is a pool object and 1037 edits it).
# ====================================================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

LIVE=out/stage90
REC=records/revert-set.txt
CFG=$LIVE/xnu_arm_entry-config.txt
NEW=STAGE90_XNU_TRAP_FRAME
PC2=STAGE90_XNU_PC_CARRIER_CALLER
PATCHER=tools/patch_d13_trap_frame.py
CHECKER=tools/check_1037_capture.py
PC2_PATCHER=tools/patch_d13_pc_carrier_caller.py
PRESSURE=tools/patch_cache_libobjc_count.py
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

# THE ARM'S NAME IS A CONTENT ADDRESS OF THE ENTRY IMAGE, so TWO runs of this script against the same
# entry bin write the SAME set name - and the second would overwrite the first's pinned record with a
# merged set (1037, this hour: phase-1 trap.c only, then after the entry rebuild, trap.c + WATCH_LE
# registration).  A set must be named by ITS OWN CONTENT: the loading-class sha8 of everything the
# pack holds, entry bin included.  Unchanged bytes re-park under the unchanged name (and re-copy).
_arm_files_sha() {
  ( cd "$LIVE" && for _m in "${MEMBERS[@]}"; do sha256sum "$_m"; done ) | LC_ALL=C sort | sha256sum | cut -c1-8
}
ARM=armed-d13-$(_arm_files_sha)
# The arms this rung must NOT be mistaken for: every arm an EARLIER rung was pressed/parked as (1036's own
# is 67782da0; the rest are 1035's, 1033's and 1031's).
for _old in 67782da0 f4c3aaa5 49031dcb 8034562e 35a7e83e 10b79e5d; do
  [[ $ARM == armed-d13-$_old ]] && { echo "REFUSING: $LIVE holds an EARLIER rung's arm ($_old) - 1037 builds ON 1036 with its own trap.c edit, which moves the pool and therefore the bin. Build 1037 first"; exit 1; }
done

echo "== 1037's OWN change, by value, first =="

# (0) the patcher and the reader can FAIL.
[[ -f $PATCHER ]] || { echo "REFUSING: $PATCHER is absent - it is 1037's whole kernel edit"; exit 1; }
[[ -f $PC2_PATCHER ]] || { echo "REFUSING: $PC2_PATCHER is absent - 1037's block is anchored on 1036's block and its pcc2 rows are the parent the fb rows are read beside"; exit 1; }
[[ -f $CHECKER ]] || { echo "REFUSING: $CHECKER is absent - it is the capture reader the press is adjudicated by; a park that skipped it would freeze an arm whose own claim nothing checks"; exit 1; }
python3 -I "$PATCHER" --selftest >/dev/null 2>&1 || { echo "REFUSING: $PATCHER --selftest did NOT PASS"; exit 1; }
python3 -I "$CHECKER" --selftest >/dev/null 2>&1 || { echo "REFUSING: $CHECKER --selftest did NOT PASS - an inert checker would bless any capture"; exit 1; }
echo "   BY VALUE(0): $PATCHER --selftest and $CHECKER --selftest PASS"

# (a) THE RECORD'S OWN KEY AND ITS PARENTS.
grep -q "^$NEW=1\$" "$CFG" || { echo "REFUSING: the record does not carry $NEW=1 - the pool was built with the trap-frame block SHUT and the capture could carry no fb row. Build with scripts/build_1037.sh"; exit 1; }
for k in $PC2 STAGE90_XNU_PC_CARRIER STAGE90_XNU_EVAL_FRAME STAGE90_XNU_CALLER_PROBE STAGE90_XNU_WRITER_PROBE STAGE90_XNU_READER_PROBE STAGE90_XNU_ABT_ENTRY_PROBE \
         STAGE90_XNU_USTACK_PROBE STAGE90_XNU_H2_STACK_HEADROOM STAGE90_XNU_VM_MAX_SPLIT STAGE90_XNU_IOS7_TRAPS \
         STAGE90_XNU_GENERAL_REGS STAGE90_XNU_UNDEF_RAISE STAGE90_XNU_UNDEF_DIRECT; do
  grep -q "^$k=1\$" "$CFG" || { echo "REFUSING: the record does not carry $k=1 - 1037 carries the 1036/1035/1033 instrument and the inherited regressions verbatim. Build with scripts/build_1037.sh"; exit 1; }
done

# (a7) 1037'S OWN CHANGE, ON THE STAGED SOURCE -- one bracketed block AFTER 1036's pcc2 block, inside 1025.
[[ -f $_tr_src ]] || { echo "REFUSING: $_tr_src is absent"; exit 1; }
[[ $(grep -c 'xnu_live_fb_seq=' "$_tr_src") == 1 ]] || { echo "REFUSING: the staged $_tr_src does not carry EXACTLY 1 xnu_live_fb_seq= line - the fb rows are not staged, or a partial/double edit landed"; exit 1; }
for _r in ctx_diff= uss= dbg_off= dbg_off_ok=; do
  [[ $(grep -c "xnu_live_fb_$_r" "$_tr_src") == 1 ]] || { echo "REFUSING: the staged $_tr_src does not carry EXACTLY 1 xnu_live_fb_$_r row - the D1/D2/ctrl conjunct is absent or doubled"; exit 1; }
done
[[ $(grep -c '^#endif /\* STAGE90_XNU_TRAP_FRAME \*/' "$_tr_src") == 1 ]] || { echo "REFUSING: the staged $_tr_src does not carry EXACTLY 1 \`#endif /* STAGE90_XNU_TRAP_FRAME */\` marker - the ON/OFF gate is not bracketed"; exit 1; }
_fb=$(grep -n '^#endif /\* STAGE90_XNU_TRAP_FRAME \*/' "$_tr_src" | head -1 | cut -d: -f1)
_pc2=$(grep -n '^#endif /\* STAGE90_XNU_PC_CARRIER_CALLER \*/' "$_tr_src" | head -1 | cut -d: -f1)
_pcc=$(grep -n '^#endif /\* STAGE90_XNU_PC_CARRIER \*/' "$_tr_src" | head -1 | cut -d: -f1)
_evf=$(grep -n '^#endif /\* STAGE90_XNU_EVAL_FRAME \*/' "$_tr_src" | head -1 | cut -d: -f1)
_cal=$(grep -n '^#endif /\* STAGE90_XNU_CALLER_PROBE \*/' "$_tr_src" | head -1 | cut -d: -f1)
_ust=$(grep -n '^#endif /\* STAGE90_XNU_USTACK_PROBE \*/' "$_tr_src" | head -1 | cut -d: -f1)
[[ -n $_cal && -n $_evf && -n $_pcc && -n $_pc2 && -n $_fb && -n $_ust && $_cal -lt $_evf && $_evf -lt $_pcc && $_pcc -lt $_pc2 && $_pc2 -lt $_fb && $_fb -lt $_ust ]] || {
  echo "REFUSING: the fb gate is NOT bracketed correctly (caller=$_cal < evf=$_evf < pcc=$_pcc < pcc2=$_pc2 < fb=$_fb < ustack=$_ust). Its rows must sit INSIDE 1025's publisher and AFTER 1036's block"; exit 1; }
echo "   BY VALUE(1-a7): the staged trap.c carries the fb block (x1 gate, x1 #endif) AFTER 1036's ($_pc2) and INSIDE 1025's publisher ($_fb < $_ust)"

# (b) THE OBJECTS AND THE LINKED IMAGE -- the press boots the ELF, which links the objects.
[[ -f $_trap_obj && -f $_exec_obj ]] || { echo "REFUSING: the pool objects are absent"; exit 1; }
# THE LIST IS THE CHECKER'S (REQUIRED_ROWS), not a second spelling of the row names here.
for _n in $(python3 -I "$CHECKER" --required-rows); do _k="^xnu_live_fb_${_n}="
  grep -qa "$_k" <(strings "$_trap_obj") || { echo "REFUSING: $_trap_obj carries NO $_k row - the pool was not recompiled with $NEW=1, or the edit is partial"; exit 1; }
  grep -qa "$_k" <(strings "$ELF") || { echo "REFUSING: the LINKED $ELF carries NO $_k string - the object was not linked into the image the press boots"; exit 1; }
done
echo "   BY VALUE(1): trap.o AND the linked image carry the checker's REQUIRED_ROWS ($(python3 -I "$CHECKER" --required-rows | tr '\n' ' ')- the names tools/patch_d13_trap_frame.py prints)"

# (1a) 1036'S pcc2 ROWS SURVIVE (they are the parent the fb rows are read beside).
for _k in '^xnu_live_pcc2_seq=' '^xnu_live_pcc2_lr_m4=' '^xnu_live_pcc2_lr_m4_ok=' '^xnu_live_pcc2_lr_m8=' \
          '^xnu_live_pcc2_lr_m8_ok=' '^xnu_live_pcc2_tbl_used=' '^xnu_live_pcc2_tbl_used_ok='; do
  grep -qa "$_k" <(strings "$_trap_obj") || { echo "REFUSING: $_trap_obj carries NO $_k row - the pool rebuild dropped 1036's pcc2 block, which the fb rows are read beside"; exit 1; }
  grep -qa "$_k" <(strings "$ELF") || { echo "REFUSING: the LINKED $ELF carries NO $_k string - 1036's pcc2 block was lost in the link"; exit 1; }
done
echo "   BY VALUE(1a): the pcc2 rows (1036) survive in trap.o and the linked image"

# (1b) THE INHERITED PARENTS SURVIVE THE REBUILD (pcc/evf/cal/wrp/rdr/abt).
for _k in '^xnu_live_pcc_seq=' '^xnu_live_pcc_pc=' '^xnu_live_pcc_lr=' '^xnu_live_pcc_xor_walk=' '^xnu_live_pcc_xor_table=' \
          '^xnu_live_evf_pc=' '^xnu_live_evf_far_raw=' '^xnu_live_abt_lookup_far=' '^xnu_live_rdr_far=' '^xnu_live_wrp_r4=' \
          '^xnu_live_abt_vmfkrv=' '^xnu_live_cal_r3=' '^xnu_live_cal_region_end='; do
  grep -qa "$_k" <(strings "$_trap_obj") || { echo "REFUSING: $_trap_obj lost $_k in this pool rebuild - the parent rows the fb frame is read BESIDE are gone ([[mi4-one-file-many-rungs]])"; exit 1; }
  grep -qa "$_k" <(strings "$ELF") || { echo "REFUSING: the LINKED image lost $_k - the linker dropped a parent row"; exit 1; }
done
grep -qa '^xnu_live_abt_proc_ustack$' <(strings "$_exec_obj") || { echo "REFUSING: $_exec_obj carries NO xnu_live_abt_proc_ustack"; exit 1; }
grep -qa '^xnu_live_ustack_req=' <(strings "$_exec_obj") || { echo "REFUSING: $_exec_obj lost 1025's xnu_live_ustack_req="; exit 1; }
echo "   BY VALUE(1b): the parent chain survives (pcc/evf/cal/wrp/rdr/abt in trap.o and the ELF; ustack accessor + 1025 publisher in kern_exec.o)"

# (2) THE CARD'S 10 BYTES -- the delivered VALUE this arm's press serves.
[[ -f $CARD ]] || { echo "REFUSING: $CARD is absent - 1037's press serves 1032's patched cache"; exit 1; }
_got=$(dd if="$CARD" bs=1 skip=$SITE_DEC count=10 2>/dev/null | od -An -tx1 | tr -d ' \n')
[[ "$_got" == "$NEW_HEX" ]] || { echo "REFUSING: the card at 0x10183720 holds $_got, not 1032's guard $NEW_HEX - the park would describe an arm whose card is not the one it serves. Run scripts/build_1037.sh"; exit 1; }
python3 -I "$PRESSURE" --check >/dev/null 2>&1 || { echo "REFUSING: $PRESSURE --check FAILED on the card"; exit 1; }
echo "   BY VALUE(2): the card carries 1032's guard at 0x10183720 and --check PASSes (content anchor included)"

# ---- INHERITED, on the linked image and the pool (same tools the 1036 park runs).
python3 -I tools/check_1023_trap24.py --selftest >/dev/null 2>&1 && python3 -I tools/check_1023_trap24.py "$ELF" --expect on >/dev/null 2>&1 || {
  echo "REFUSING: 1023's row-24 claim does not hold on the linked image (or the checker cannot fail)"; exit 1; }
python3 -I tools/check_d13_undef_raise.py "$ELF" --expect on >/dev/null 2>&1 || { echo "REFUSING: 1020's raise is not in the linked image's sleh_undef"; exit 1; }
python3 -I tools/check_vm_max_split.py "$ELF" --expect on >/dev/null 2>&1 || { echo "REFUSING: 1024's ceiling is not on the linked image"; exit 1; }
python3 -I tools/check_d13_no_neon.py "$ELF" --symbol mach_msg_send --expect none >/dev/null 2>&1 || { echo "REFUSING: the linked mach_msg_send is not NEON-free (1021d)"; exit 1; }
python3 -I tools/check_1033_capture.py --selftest >/dev/null 2>&1 || { echo "REFUSING: 1033's reader --selftest fails - the evf rows this rung is read beside have no sound reader"; exit 1; }
python3 -I tools/check_1035_capture.py --selftest >/dev/null 2>&1 || { echo "REFUSING: 1035's reader --selftest fails - the pcc rows this rung is read beside have no sound reader"; exit 1; }
python3 -I tools/check_1036_capture.py --selftest >/dev/null 2>&1 || { echo "REFUSING: 1036's reader --selftest fails - the pcc2 rows this rung is read beside have no sound reader"; exit 1; }
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
echo "   INHERITED: row 24, 1020 raise, 1024 ceiling, 1021d NEON-free (pool census + linked), 1018 direct witness, 1015b GLOBAL-FIX, 1033 + 1035 + 1036 readers all PASS"

# ====================================================================================================
# THE PARK, the frozen re-read, and the record.
# ====================================================================================================
PARK=$LIVE/frozen/$ARM
[[ -d $PARK ]] && { echo "REFUSING: $PARK already exists"; exit 1; }
grep -q "role=1037-trap-frame" "$REC" && { echo "REFUSING: $REC already carries a 1037-trap-frame block"; exit 1; }
mkdir -p "$PARK"
for m in "${MEMBERS[@]}"; do cp -p "$LIVE/$m" "$PARK/$m"; done
cp -p "$PATCHER" "$PARK/patch_d13_trap_frame.py"
cp -p "$CHECKER" "$PARK/check_1037_capture.py"
CARD_SHA=$(sha256sum "$CARD" | awk '{print $1}')

# THE FROZEN RE-READ: the rung's own claims on the PARKED bytes.
for _k in $(python3 -I "$CHECKER" --required-rows | sed 's/^/^xnu_live_fb_/; s/$/=/' | tr '\n' ' ') \
          '^xnu_live_pcc2_seq=' '^xnu_live_pcc2_tbl_used=' \
          '^xnu_live_pcc_pc=' '^xnu_live_pcc_xor_walk=' '^xnu_live_pcc_xor_table=' '^xnu_live_evf_pc=' \
          '^xnu_live_cal_region_end=' '^xnu_live_wrp_r4=' '^xnu_live_abt_lookup_far='; do
  grep -qa "$_k" <(strings "$PARK/xnu_arm_entry.elf") || { echo "REFUSING: the FROZEN $PARK/xnu_arm_entry.elf lost $_k - the copy is not the certified bytes; remove $PARK and re-run"; exit 1; }
done
python3 -I tools/check_vm_max_split.py "$PARK/xnu_arm_entry.elf" --expect on >/dev/null 2>&1 || { echo "REFUSING: the frozen image lost 1024's ceiling claim"; exit 1; }
python3 -I tools/check_1023_trap24.py "$PARK/xnu_arm_entry.elf" --expect on >/dev/null 2>&1 || { echo "REFUSING: the frozen image lost 1023's row-24 claim"; exit 1; }
python3 -I "$PARK/check_1037_capture.py" --selftest >/dev/null 2>&1 || { echo "REFUSING: the PARKED 1037 reader does not selftest"; exit 1; }
[[ $(sha256sum "$LIVE/xnu_card_hfs.img" | awk '{print $1}') == "$CARD_SHA" ]] || { echo "REFUSING: the card changed while parking"; exit 1; }
echo "   FROZEN: the parked image carries fb + pcc2 + pcc + evf + cal + wrp + lookup_far, 1024's ceiling, 1023's row 24; the reader selftests; the card sha is pinned"

{
  printf '\n# =================================================================================================\n'
  printf '# %s  -  1037: THE TRAP FRAME vs THE TASK MAP-S OWN COPY OF THE uss, BY VALUE.  INSTRUMENT ONLY.\n' "$ARM"
  printf '# 1036 READ = lr and r10 read ODD on an all-ARM path, while arm_ctx agrees with evf/pcc/pcc2;\n'
  printf '# so the trap entry stores some register at the WRONG OFFSET.  1037 compares the trap\n'
  printf '# entry-s own uss stmea block (TASK-MAP read) with arm_ctx and derives the slide from lr.\n'
  printf '# NOT a return if the fault path runs: a resident rung.\n'
  printf '# NEW SWITCH: %s=1 (tools/patch_d13_trap_frame.py), a trap.c block INSIDE\n' "$NEW"
  printf '# 1025-s publisher AFTER 1036-s pcc2 block.  Rows xnu_live_fb_*: seq/ctx_diff/uss/dbg_off/\n'
  printf '# dbg_off_ok (+ the tray: pc/lr/sp_tr/near/uss_r0..r12/slide/lr_xor4/lr_xor8/ldrh).  READS ONLY.\n'
  printf '# CHANNEL: the global DEFINES array (build_xnu_arm_kernel.sh); a -D in EXTRA is not the channel.\n'
  printf '# THE POOL MOVES: trap.c is a pool object, so the entry bin (and the arm name) MOVES.\n'
  printf '# [[mi4-one-file-many-rungs]]: trap.c is edited by 994/1020/1025/1026/1029/1030/1031/1033/1035/1036/1037;\n'
  printf '# PC_CARRIER, PC_CARRIER_CALLER and TRAP_FRAME must be in EVERY trap.c patcher-s ALLOWED_IF_IDENTIFIERS.\n'
  printf '# THE CARD: 1037 serves 1032-s 10 bytes (card 0x10183720 = %s).  Not a park member; the card-s\n' "$NEW_HEX"
  printf '# sha256 is pinned here and its content anchor is checked by patch_cache_libobjc_count.py --check [2].\n'
  printf '# THE READING: %s (pre-registered cells ctrl/D1/D2/D3/L1 in records/1037-read.txt 2).\n' "$CHECKER"
  printf '# Medium: 968 real iOS 7.1.2 HFSX rootfs over hfs_rmd0; CARD_COW=1, HDD_WRITE=0, base never\n'
  printf '# written - fully reversible.  fastboot boot only, NEVER flash.\n'
  printf '# card_sha256=%s card_off=0x10183720 card_new=%s\n' "$CARD_SHA" "$NEW_HEX"
  printf '# =================================================================================================\n'
  for m in "${MEMBERS[@]}"; do
    printf 'set=%s sha256=%s bytes=%s file=%s role=1037-trap-frame;%s\n' "$ARM" "$(sha256sum "$PARK/$m" | awk '{print $1}')" "$(stat -c %s "$PARK/$m")" "$m" "$m"
  done
  printf 'set=%s sha256=%s bytes=%s file=%s role=1037-trap-frame-editors-definition\n' "$ARM" "$(sha256sum "$PARK/patch_d13_trap_frame.py" | awk '{print $1}')" "$(stat -c %s "$PARK/patch_d13_trap_frame.py")" patch_d13_trap_frame.py
  printf 'set=%s sha256=%s bytes=%s file=%s role=1037-trap-frame-capture-reader\n' "$ARM" "$(sha256sum "$PARK/check_1037_capture.py" | awk '{print $1}')" "$(stat -c %s "$PARK/check_1037_capture.py")" check_1037_capture.py
} >> "$REC"

echo "recorded $ARM (role=1037-trap-frame) in $REC"
echo "parked $ARM ($(ls -1 "$PARK" | wc -l) members)"
echo "   verify: tools/verify_revert_set.sh $PARK --set=$ARM"
# THE LIVE COPIES the record's file= lines also name (the press's preflight reads one directory at a time).
cmp -s "$PATCHER" "$LIVE/$(basename "$PATCHER")" || cp -p "$PATCHER" "$LIVE/$(basename "$PATCHER")"
cmp -s "$CHECKER" "$LIVE/$(basename "$CHECKER")" || cp -p "$CHECKER" "$LIVE/$(basename "$CHECKER")"
echo "   live copies placed: $LIVE/$(basename "$PATCHER"), $LIVE/$(basename "$CHECKER") (identical bytes to the park's)"