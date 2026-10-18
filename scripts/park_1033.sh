#!/usr/bin/env bash
# ====================================================================================================
# park_1033.sh.  MODELLED ON scripts/park_1031.sh (the same by-value order: THIS rung's change FIRST, on
# its own claim, then the inherited regressions), PLUS one clause 1031/1032 did not have: THE CARD'S
# 10 BYTES, because 1033 serves 1032's patched cache and a park that froze only the kernel would record an
# arm whose press is not the run this park describes.
#
# **WHAT 1033 IS.**  1031's instrument verbatim (cal/wrp/rdr/abt_abt rows) PLUS one new switch
# STAGE90_XNU_EVAL_FRAME=1 and one new trap.c block (tools/patch_d13_eval_frame.py) publishing the 1032
# frame by value: the raw untruncated DFAR, pc/lr/sp/cpsr, pc-far, the far word, and the word at sp+0x10 --
# all read with copyin only.  INSTRUMENT ONLY: no fix, no allocation change.  records/1032-reading.txt 6.
#
# The park is $LIVE/frozen/$ARM (the arm name MOVES: trap.c is a pool object and 1033 edits it).
# ====================================================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

LIVE=out/stage90
REC=records/revert-set.txt
CFG=$LIVE/xnu_arm_entry-config.txt
NEW=STAGE90_XNU_EVAL_FRAME
PATCHER=tools/patch_d13_eval_frame.py
CHECKER=tools/check_1033_capture.py
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

ARM=armed-d13-$(sha256sum "$LIVE/xnu_arm_entry.bin" | cut -c1-8)
# The arms this rung must NOT be mistaken for: every arm an EARLIER rung was pressed as.  A park under one
# of those names would freeze an older run's bytes as 1033's own.
for _old in 49031dcb 8034562e 35a7e83e 10b79e5d; do
  [[ $ARM == armed-d13-$_old ]] && { echo "REFUSING: $LIVE holds an EARLIER rung's arm ($_old) - 1033 builds ON it with its own trap.c edit, which moves the pool and therefore the bin. Build 1033 first"; exit 1; }
done

echo "== 1033's OWN change, by value, first =="

# (0) the two checkers can FAIL.
[[ -f $PATCHER ]] || { echo "REFUSING: $PATCHER is absent - it is 1033's whole kernel edit"; exit 1; }
[[ -f $CHECKER ]] || { echo "REFUSING: $CHECKER is absent - it is the capture reader the press is adjudicated by; a park that skipped it would freeze an arm whose own claim nothing checks"; exit 1; }
python3 -I "$PATCHER" --selftest >/dev/null 2>&1 || { echo "REFUSING: $PATCHER --selftest did NOT PASS"; exit 1; }
python3 -I "$CHECKER" --selftest >/dev/null 2>&1 || { echo "REFUSING: $CHECKER --selftest did NOT PASS - an inert checker would bless any capture"; exit 1; }
echo "   BY VALUE(0): $PATCHER --selftest and $CHECKER --selftest PASS"

# (a) THE RECORD'S OWN KEY AND ITS PARENTS.
grep -q "^$NEW=1\$" "$CFG" || { echo "REFUSING: the record does not carry $NEW=1 - the pool was built with the eval probe SHUT and the capture could carry no evf row. Build with scripts/build_1033.sh"; exit 1; }
for k in STAGE90_XNU_CALLER_PROBE STAGE90_XNU_WRITER_PROBE STAGE90_XNU_READER_PROBE STAGE90_XNU_ABT_ENTRY_PROBE \
         STAGE90_XNU_USTACK_PROBE STAGE90_XNU_H2_STACK_HEADROOM STAGE90_XNU_VM_MAX_SPLIT STAGE90_XNU_IOS7_TRAPS \
         STAGE90_XNU_GENERAL_REGS STAGE90_XNU_UNDEF_RAISE STAGE90_XNU_UNDEF_DIRECT; do
  grep -q "^$k=1\$" "$CFG" || { echo "REFUSING: the record does not carry $k=1 - 1033 carries the 1031 instrument and the inherited regressions verbatim. Build with scripts/build_1033.sh"; exit 1; }
done

# (a7) 1033'S OWN CHANGE, ON THE STAGED SOURCE -- one bracketed block INSIDE 1025's publisher, AFTER 1031's.
[[ -f $_tr_src ]] || { echo "REFUSING: $_tr_src is absent"; exit 1; }
[[ $(grep -c 'xnu_live_evf_pc=' "$_tr_src") == 1 ]] || { echo "REFUSING: the staged $_tr_src does not carry EXACTLY 1 xnu_live_evf_pc= line - the eval-frame rows are not staged, or a partial/double edit landed"; exit 1; }
[[ $(grep -c '^#endif /\* STAGE90_XNU_EVAL_FRAME \*/' "$_tr_src") == 1 ]] || { echo "REFUSING: the staged $_tr_src does not carry EXACTLY 1 \`#endif /* STAGE90_XNU_EVAL_FRAME */\` marker - the ON/OFF gate is not bracketed"; exit 1; }
_evf=$(grep -n '^#endif /\* STAGE90_XNU_EVAL_FRAME \*/' "$_tr_src" | head -1 | cut -d: -f1)
_cal=$(grep -n '^#endif /\* STAGE90_XNU_CALLER_PROBE \*/' "$_tr_src" | head -1 | cut -d: -f1)
_ust=$(grep -n '^#endif /\* STAGE90_XNU_USTACK_PROBE \*/' "$_tr_src" | head -1 | cut -d: -f1)
[[ -n $_evf && -n $_cal && $_cal -lt $_evf && $_evf -lt $_ust ]] || {
  echo "REFUSING: the eval-frame gate is NOT bracketed correctly (caller #endif=$_cal < evf #endif=$_evf < ustack #endif=$_ust). Its rows must sit INSIDE 1025's publisher and AFTER 1031's block"; exit 1; }
echo "   BY VALUE(1-a7): the staged trap.c carries the evf block (x1 gate, x1 #endif) AFTER 1031 ($_cal) and INSIDE 1025's publisher ($_evf < $_ust)"

# (b) THE OBJECTS AND THE LINKED IMAGE -- the press boots the ELF, which links the objects.
[[ -f $_trap_obj && -f $_exec_obj ]] || { echo "REFUSING: the pool objects are absent"; exit 1; }
for _k in '^xnu_live_evf_pc=' '^xnu_live_evf_far_raw=' '^xnu_live_evf_far_is_0x10=' '^xnu_live_evf_pc_minus_far=' \
          '^xnu_live_evf_slot10=' '^xnu_live_evf_slot10_ok=' '^xnu_live_evf_ptr_word=' '^xnu_live_evf_ptr_word_ok='; do
  grep -qa "$_k" <(strings "$_trap_obj") || { echo "REFUSING: $_trap_obj carries NO $_k row - the pool was not recompiled with $NEW=1, or the edit is partial. Every evf row is required: the cell reads far/pc/far_word/slot10 TOGETHER"; exit 1; }
  grep -qa "$_k" <(strings "$ELF") || { echo "REFUSING: the LINKED $ELF carries NO $_k string - the object was not linked into the image the press boots"; exit 1; }
done
echo "   BY VALUE(1): trap.o AND the linked image carry all 8 evf rows"

# (1b) THE INHERITED PARENTS SURVIVE THE REBUILD.
for _k in '^xnu_live_abt_lookup_far=' '^xnu_live_rdr_far=' '^xnu_live_wrp_r4=' '^xnu_live_abt_vmfkrv=' \
          '^xnu_live_cal_r3=' '^xnu_live_cal_region_end='; do
  grep -qa "$_k" <(strings "$_trap_obj") || { echo "REFUSING: $_trap_obj lost $_k in this pool rebuild - the parent rows the eval frame is read BESIDE are gone ([[mi4-one-file-many-rungs]])"; exit 1; }
  grep -qa "$_k" <(strings "$ELF") || { echo "REFUSING: the LINKED image lost $_k - the linker dropped a parent row"; exit 1; }
done
grep -qa '^xnu_live_abt_proc_ustack$' <(strings "$_exec_obj") || { echo "REFUSING: $_exec_obj carries NO xnu_live_abt_proc_ustack"; exit 1; }
grep -qa '^xnu_live_ustack_req=' <(strings "$_exec_obj") || { echo "REFUSING: $_exec_obj lost 1025's xnu_live_ustack_req="; exit 1; }
echo "   BY VALUE(1b): the parent chain survives (cal/wrp/rdr/abt in trap.o and the ELF; ustack accessor + 1025 publisher in kern_exec.o)"

# (2) THE CARD'S 10 BYTES -- the delivered VALUE this arm's press serves (1031/1032 had no such clause
#     because 1031 carried no card patch; 1033 DOES).
[[ -f $CARD ]] || { echo "REFUSING: $CARD is absent - 1033's press serves 1032's patched cache"; exit 1; }
_got=$(dd if="$CARD" bs=1 skip=$SITE_DEC count=10 2>/dev/null | od -An -tx1 | tr -d ' \n')
[[ "$_got" == "$NEW_HEX" ]] || { echo "REFUSING: the card at 0x10183720 holds $_got, not 1032's guard $NEW_HEX - the park would describe an arm whose card is not the one it serves. Run scripts/build_1033.sh"; exit 1; }
python3 -I tools/patch_cache_libobjc_count.py --check >/dev/null 2>&1 || { echo "REFUSING: patch_cache_libobjc_count.py --check FAILED on the card"; exit 1; }
echo "   BY VALUE(2): the card carries 1032's guard at 0x10183720 and --check PASSes (content anchor included)"

# ---- INHERITED, on the linked image and the pool (same tools the 1031 park runs).
python3 -I tools/check_1023_trap24.py --selftest >/dev/null 2>&1 && python3 -I tools/check_1023_trap24.py "$ELF" --expect on >/dev/null 2>&1 || {
  echo "REFUSING: 1023's row-24 claim does not hold on the linked image (or the checker cannot fail)"; exit 1; }
python3 -I tools/check_d13_undef_raise.py "$ELF" --expect on >/dev/null 2>&1 || { echo "REFUSING: 1020's raise is not in the linked image's sleh_undef"; exit 1; }
python3 -I tools/check_vm_max_split.py "$ELF" --expect on >/dev/null 2>&1 || { echo "REFUSING: 1024's ceiling is not on the linked image"; exit 1; }
python3 -I tools/check_d13_no_neon.py "$ELF" --symbol mach_msg_send --expect none >/dev/null 2>&1 || { echo "REFUSING: the linked mach_msg_send is not NEON-free (1021d)"; exit 1; }
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
echo "   INHERITED: row 24, 1020 raise, 1024 ceiling, 1021d NEON-free (pool census + linked), 1018 direct witness, 1015b GLOBAL-FIX all PASS"

# ====================================================================================================
# THE PARK, the frozen re-read, and the record.  A park that is not recorded is a park nothing reverts to.
# ====================================================================================================
PARK=$LIVE/frozen/$ARM
[[ -d $PARK ]] && { echo "REFUSING: $PARK already exists"; exit 1; }
grep -q "role=1033-eval-frame" "$REC" && { echo "REFUSING: $REC already carries a 1033-eval-frame block"; exit 1; }
mkdir -p "$PARK"
for m in "${MEMBERS[@]}"; do cp -p "$LIVE/$m" "$PARK/$m"; done
# The two DEFINITIONS this arm's edit and reading consist of, frozen beside the kernel members (the same
# shape as park_1032's tool copies).
cp -p "$PATCHER" "$PARK/patch_d13_eval_frame.py"
cp -p "$CHECKER" "$PARK/check_1033_capture.py"
CARD_SHA=$(sha256sum "$CARD" | awk '{print $1}')

# THE FROZEN RE-READ: the rung's own claims on the PARKED bytes.
for _k in '^xnu_live_evf_pc=' '^xnu_live_evf_far_raw=' '^xnu_live_cal_region_end=' '^xnu_live_wrp_r4=' '^xnu_live_abt_lookup_far='; do
  grep -qa "$_k" <(strings "$PARK/xnu_arm_entry.elf") || { echo "REFUSING: the FROZEN $PARK/xnu_arm_entry.elf lost $_k - the copy is not the certified bytes; remove $PARK and re-run"; exit 1; }
done
python3 -I tools/check_vm_max_split.py "$PARK/xnu_arm_entry.elf" --expect on >/dev/null 2>&1 || { echo "REFUSING: the frozen image lost 1024's ceiling claim"; exit 1; }
python3 -I tools/check_1023_trap24.py "$PARK/xnu_arm_entry.elf" --expect on >/dev/null 2>&1 || { echo "REFUSING: the frozen image lost 1023's row-24 claim"; exit 1; }
[[ $(sha256sum "$LIVE/xnu_card_hfs.img" | awk '{print $1}') == "$CARD_SHA" ]] || { echo "REFUSING: the card changed while parking"; exit 1; }
echo "   FROZEN: the parked image carries evf + cal + wrp + lookup_far, 1024's ceiling, 1023's row 24; the card sha is pinned"

{
  printf '\n# =================================================================================================\n'
  printf '# %s  -  1033: THE EVAL-FRAME PROBE - NAME THE 1032 FRAME BY VALUE.  INSTRUMENT ONLY.\n' "$ARM"
  printf '# 1032 (records/1032-reading.txt) read FIX-PARTIAL: the 10-byte libobjc clamp removed the 1030\n'
  printf '# stack-end WRITE (writer pc 0x37C26756), and the boot now ends with launchctl[2] usermode data\n'
  printf '# abort EXC_BAD_ACCESS at 0x10 (dfsr type 7) after `launchd[1] has started up`, then\n'
  printf '# "The System bootstrapper has crashed: Bus error: 10".  NOT a return: a resident rung.\n'
  printf '# NEW SWITCH: %s=1 (tools/patch_d13_eval_frame.py), a trap.c block inside\n' "$NEW"
  printf '# 1025-s publisher AFTER 1031-s caller block.  Rows xnu_live_evf_*: pid, pc, lr, sp, cpsr, the RAW\n'
  printf '# untruncated DFAR (arm_ctx->far; 1025-s row prints vm_map_trunc_page(dfar), which is 0 for dfar\n'
  printf '# 0x10 and cannot tell them apart), dfsr, code, pc_minus_far, far_is_0x10, ustack, and the words at\n'
  printf '# far and sp+0x10 read with copyin only (+ their copyin results).  READS ONLY, failing path only.\n'
  printf '# CHANNEL: the global DEFINES array (env export); a -DSTAGE90_XNU_EVAL_FRAME in EXTRA is refused.\n'
  printf '# THE POOL MOVES: trap.c is a pool object, so the entry bin (and the arm name) MOVES.\n'
  printf '# [[mi4-one-file-many-rungs]]: EIGHT rungs edit osfmk/arm/trap.c (994/1020/1025/1026/1029/1030/\n'
  printf '# 1031/1033); the new switch is in EVERY trap.c patcher-s ALLOWED_IF_IDENTIFIERS, and a bare\n'
  printf '# `git checkout --` reverts the others SILENTLY.\n'
  printf '# THE CARD: 1033 serves 1032-s 10 bytes (card 0x10183720 = %s).  Not a park member\n' "$NEW_HEX"
  printf '# (the card is ~900 MiB); the bytes and the card-s sha256 are pinned here and its content anchor is\n'
  printf '# checked by patch_cache_libobjc_count.py --check [1a].\n'
  printf '# THE BY-VALUE PROOF (park_1033.sh): the staged trap.c carries the block x1 with ONE bracketed\n'
  printf '# #endif AFTER 1031-s and INSIDE 1025-s; trap.o AND the linked image carry ALL 8 evf rows; the\n'
  printf '# parent chain (cal/wrp/rdr/lookup_far/vmfkrv) survives both; the card carries the guard and --check\n'
  printf '# PASSes; and the inherited clauses (1023 row 24, 1020 raise, 1024 ceiling, 1021d NEON-free census\n'
  printf '# + linked mach_msg_send, 1018 direct witness, 1015b GLOBAL-FIX x3) hold.\n'
  printf '# THE READING: tools/check_1033_capture.py (pre-registered cells in docs/1033-design.md).\n'
  printf '# Medium: 968 real iOS 7.1.2 HFSX rootfs over hfs_rmd0; CARD_COW=1, HDD_WRITE=0, base never\n'
  printf '# written - fully reversible.  fastboot boot only, NEVER flash.\n'
  printf '# card_sha256=%s card_off=0x10183720 card_new=%s\n' "$CARD_SHA" "$NEW_HEX"
  printf '# =================================================================================================\n'
  for m in "${MEMBERS[@]}"; do
    printf 'set=%s sha256=%s bytes=%s file=%s role=1033-eval-frame;%s\n' "$ARM" "$(sha256sum "$PARK/$m" | awk '{print $1}')" "$(stat -c %s "$PARK/$m")" "$m" "$m"
  done
  printf 'set=%s sha256=%s bytes=%s file=%s role=1033-eval-frame-editors-definition\n' "$ARM" "$(sha256sum "$PARK/patch_d13_eval_frame.py" | awk '{print $1}')" "$(stat -c %s "$PARK/patch_d13_eval_frame.py")" patch_d13_eval_frame.py
  printf 'set=%s sha256=%s bytes=%s file=%s role=1033-eval-frame-capture-reader\n' "$ARM" "$(sha256sum "$PARK/check_1033_capture.py" | awk '{print $1}')" "$(stat -c %s "$PARK/check_1033_capture.py")" check_1033_capture.py
} >> "$REC"

echo "recorded $ARM (role=1033-eval-frame) in $REC"
echo "parked $ARM ($(ls -1 "$PARK" | wc -l) members)"
echo "   verify: tools/verify_revert_set.sh $PARK --set=$ARM"
# THE LIVE COPIES the record's file= lines also name.  records/revert-set.txt refuses a path-shaped
# file=, and every file= line is checked against ONE directory at a time (verify_revert_set.sh reads one),
# so the two tool lines are only true of the park unless the live tree carries identical bytes.  Measured
# on 1032 (records/1032-press-read.txt 1): the press's preflight required 28/28 in out/stage90 and refused
# until the two people were copied there.  Copying them NOW is what makes the gate read 28/28 on the
# FIRST press run instead of after a refused one.
cmp -s "$PATCHER" "$LIVE/$(basename "$PATCHER")" || cp -p "$PATCHER" "$LIVE/$(basename "$PATCHER")"
cmp -s "$CHECKER" "$LIVE/$(basename "$CHECKER")" || cp -p "$CHECKER" "$LIVE/$(basename "$CHECKER")"
echo "   live copies placed: $LIVE/$(basename "$PATCHER"), $LIVE/$(basename "$CHECKER") (identical bytes to the park's)"