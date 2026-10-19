#!/usr/bin/env bash
# ====================================================================================================
# park_1035.sh.  MODELLED ON scripts/park_1033.sh (no park_1034 exists; 1033 is the newest park): THIS
# rung's change FIRST, on its own claim, then the inherited regressions, then the CARD'S 10 BYTES (1035
# still serves 1032's patched cache).
#
# **WHAT 1035 IS.**  1033's instrument verbatim (evf/cal/wrp/rdr/abt rows) PLUS one new switch
# STAGE90_XNU_PC_CARRIER=1 and one new trap.c block (tools/patch_d13_pc_carrier.py) that copyin's the
# words around the faulting pc from the DEVICE's task map and prints their XOR against the host's file
# words for BOTH candidates (records/1035-carrier-by-pc-read.txt 2).  INSTRUMENT ONLY.
#
# The park is $LIVE/frozen/$ARM (the arm name MOVES: trap.c is a pool object and 1035 edits it).
# ====================================================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

LIVE=out/stage90
REC=records/revert-set.txt
CFG=$LIVE/xnu_arm_entry-config.txt
NEW=STAGE90_XNU_PC_CARRIER
PATCHER=tools/patch_d13_pc_carrier.py
CHECKER=tools/check_1035_capture.py
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

ARM=armed-d13-$(sha256sum "$LIVE/xnu_arm_entry.bin" | cut -c1-8)
# The arms this rung must NOT be mistaken for: every arm an EARLIER rung was pressed/parked as.  A park
# under one of those names would freeze an older run's bytes as 1035's own.
for _old in 49031dcb 8034562e 35a7e83e 10b79e5d; do
  [[ $ARM == armed-d13-$_old ]] && { echo "REFUSING: $LIVE holds an EARLIER rung's arm ($_old) - 1035 builds ON 1033 with its own trap.c edit, which moves the pool and therefore the bin. Build 1035 first"; exit 1; }
done

echo "== 1035's OWN change, by value, first =="

# (0) the patcher and the reader can FAIL.
[[ -f $PATCHER ]] || { echo "REFUSING: $PATCHER is absent - it is 1035's whole kernel edit"; exit 1; }
[[ -f $CHECKER ]] || { echo "REFUSING: $CHECKER is absent - it is the capture reader the press is adjudicated by; a park that skipped it would freeze an arm whose own claim nothing checks"; exit 1; }
python3 -I "$PATCHER" --selftest >/dev/null 2>&1 || { echo "REFUSING: $PATCHER --selftest did NOT PASS"; exit 1; }
python3 -I "$CHECKER" --selftest >/dev/null 2>&1 || { echo "REFUSING: $CHECKER --selftest did NOT PASS - an inert checker would bless any capture"; exit 1; }
echo "   BY VALUE(0): $PATCHER --selftest and $CHECKER --selftest PASS"

# (a) THE RECORD'S OWN KEY AND ITS PARENTS.
grep -q "^$NEW=1\$" "$CFG" || { echo "REFUSING: the record does not carry $NEW=1 - the pool was built with the pcc probe SHUT and the capture could carry no pcc row. Build with scripts/build_1035.sh"; exit 1; }
for k in STAGE90_XNU_EVAL_FRAME STAGE90_XNU_CALLER_PROBE STAGE90_XNU_WRITER_PROBE STAGE90_XNU_READER_PROBE STAGE90_XNU_ABT_ENTRY_PROBE \
         STAGE90_XNU_USTACK_PROBE STAGE90_XNU_H2_STACK_HEADROOM STAGE90_XNU_VM_MAX_SPLIT STAGE90_XNU_IOS7_TRAPS \
         STAGE90_XNU_GENERAL_REGS STAGE90_XNU_UNDEF_RAISE STAGE90_XNU_UNDEF_DIRECT; do
  grep -q "^$k=1\$" "$CFG" || { echo "REFUSING: the record does not carry $k=1 - 1035 carries the 1033 instrument and the inherited regressions verbatim. Build with scripts/build_1035.sh"; exit 1; }
done

# (a7) 1035'S OWN CHANGE, ON THE STAGED SOURCE -- one bracketed block AFTER 1033's evf block.
[[ -f $_tr_src ]] || { echo "REFUSING: $_tr_src is absent"; exit 1; }
[[ $(grep -c 'xnu_live_pcc_pc=' "$_tr_src") == 1 ]] || { echo "REFUSING: the staged $_tr_src does not carry EXACTLY 1 xnu_live_pcc_pc= line - the pcc rows are not staged, or a partial/double edit landed"; exit 1; }
[[ $(grep -c '^#endif /\* STAGE90_XNU_PC_CARRIER \*/' "$_tr_src") == 1 ]] || { echo "REFUSING: the staged $_tr_src does not carry EXACTLY 1 \`#endif /* STAGE90_XNU_PC_CARRIER */\` marker - the ON/OFF gate is not bracketed"; exit 1; }
_pcc=$(grep -n '^#endif /\* STAGE90_XNU_PC_CARRIER \*/' "$_tr_src" | head -1 | cut -d: -f1)
_evf=$(grep -n '^#endif /\* STAGE90_XNU_EVAL_FRAME \*/' "$_tr_src" | head -1 | cut -d: -f1)
_ust=$(grep -n '^#endif /\* STAGE90_XNU_USTACK_PROBE \*/' "$_tr_src" | head -1 | cut -d: -f1)
[[ -n $_pcc && -n $_evf && -n $_ust && $_evf -lt $_pcc && $_pcc -lt $_ust ]] || {
  echo "REFUSING: the pcc gate is NOT bracketed correctly (evf #endif=$_evf < pcc #endif=$_pcc < ustack #endif=$_ust). Its rows must sit INSIDE 1025's publisher and AFTER 1033's block (records/1035-carrier-by-pc-read.txt 2)"; exit 1; }
echo "   BY VALUE(1-a7): the staged trap.c carries the pcc block (x1 gate, x1 #endif) AFTER 1033 ($_evf) and INSIDE 1025's publisher ($_pcc < $_ust)"

# (b) THE OBJECTS AND THE LINKED IMAGE -- the press boots the ELF, which links the objects.
[[ -f $_trap_obj && -f $_exec_obj ]] || { echo "REFUSING: the pool objects are absent"; exit 1; }
for _k in '^xnu_live_pcc_seq=' '^xnu_live_pcc_pc=' '^xnu_live_pcc_lr=' '^xnu_live_pcc_r1=' '^xnu_live_pcc_r5=' \
          '^xnu_live_pcc_r2=' '^xnu_live_pcc_r7=' '^xnu_live_pcc_near\[2\]=' '^xnu_live_pcc_near_ok\[2\]=' \
          '^xnu_live_pcc_dev_xor_f0=' '^xnu_live_pcc_dev_xor_f1='; do
  grep -qa "$_k" <(strings "$_trap_obj") || { echo "REFUSING: $_trap_obj carries NO $_k row - the pool was not recompiled with $NEW=1, or the edit is partial. The cell reads the pc word's XOR against BOTH host candidates TOGETHER"; exit 1; }
  grep -qa "$_k" <(strings "$ELF") || { echo "REFUSING: the LINKED $ELF carries NO $_k string - the object was not linked into the image the press boots"; exit 1; }
done
echo "   BY VALUE(1): trap.o AND the linked image carry the pcc rows (seq/pc/lr/r1/r5/r2/r7/near[2]/near_ok[2]/xor_f0/xor_f1)"

# (1b) THE INHERITED PARENTS SURVIVE THE REBUILD.
for _k in '^xnu_live_evf_pc=' '^xnu_live_evf_far_raw=' '^xnu_live_abt_lookup_far=' '^xnu_live_rdr_far=' '^xnu_live_wrp_r4=' \
          '^xnu_live_abt_vmfkrv=' '^xnu_live_cal_r3=' '^xnu_live_cal_region_end='; do
  grep -qa "$_k" <(strings "$_trap_obj") || { echo "REFUSING: $_trap_obj lost $_k in this pool rebuild - the parent rows the pcc frame is read BESIDE are gone ([[mi4-one-file-many-rungs]])"; exit 1; }
  grep -qa "$_k" <(strings "$ELF") || { echo "REFUSING: the LINKED image lost $_k - the linker dropped a parent row"; exit 1; }
done
grep -qa '^xnu_live_abt_proc_ustack$' <(strings "$_exec_obj") || { echo "REFUSING: $_exec_obj carries NO xnu_live_abt_proc_ustack"; exit 1; }
grep -qa '^xnu_live_ustack_req=' <(strings "$_exec_obj") || { echo "REFUSING: $_exec_obj lost 1025's xnu_live_ustack_req="; exit 1; }
echo "   BY VALUE(1b): the parent chain survives (evf/cal/wrp/rdr/abt in trap.o and the ELF; ustack accessor + 1025 publisher in kern_exec.o)"

# (2) THE CARD'S 10 BYTES -- the delivered VALUE this arm's press serves.
[[ -f $CARD ]] || { echo "REFUSING: $CARD is absent - 1035's press serves 1032's patched cache"; exit 1; }
_got=$(dd if="$CARD" bs=1 skip=$SITE_DEC count=10 2>/dev/null | od -An -tx1 | tr -d ' \n')
[[ "$_got" == "$NEW_HEX" ]] || { echo "REFUSING: the card at 0x10183720 holds $_got, not 1032's guard $NEW_HEX - the park would describe an arm whose card is not the one it serves. Run scripts/build_1035.sh"; exit 1; }
python3 -I "$PRESSURE" --check >/dev/null 2>&1 || { echo "REFUSING: $PRESSURE --check FAILED on the card"; exit 1; }
echo "   BY VALUE(2): the card carries 1032's guard at 0x10183720 and --check PASSes (content anchor included)"

# ---- INHERITED, on the linked image and the pool (same tools the 1033 park runs).
python3 -I tools/check_1023_trap24.py --selftest >/dev/null 2>&1 && python3 -I tools/check_1023_trap24.py "$ELF" --expect on >/dev/null 2>&1 || {
  echo "REFUSING: 1023's row-24 claim does not hold on the linked image (or the checker cannot fail)"; exit 1; }
python3 -I tools/check_d13_undef_raise.py "$ELF" --expect on >/dev/null 2>&1 || { echo "REFUSING: 1020's raise is not in the linked image's sleh_undef"; exit 1; }
python3 -I tools/check_vm_max_split.py "$ELF" --expect on >/dev/null 2>&1 || { echo "REFUSING: 1024's ceiling is not on the linked image"; exit 1; }
python3 -I tools/check_d13_no_neon.py "$ELF" --symbol mach_msg_send --expect none >/dev/null 2>&1 || { echo "REFUSING: the linked mach_msg_send is not NEON-free (1021d)"; exit 1; }
python3 -I tools/check_1033_capture.py --selftest >/dev/null 2>&1 || { echo "REFUSING: 1033's reader --selftest fails - the evf rows this rung is read beside have no sound reader"; exit 1; }
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
echo "   INHERITED: row 24, 1020 raise, 1024 ceiling, 1021d NEON-free (pool census + linked), 1018 direct witness, 1015b GLOBAL-FIX, 1033 reader all PASS"

# ====================================================================================================
# THE PARK, the frozen re-read, and the record.
# ====================================================================================================
PARK=$LIVE/frozen/$ARM
[[ -d $PARK ]] && { echo "REFUSING: $PARK already exists"; exit 1; }
grep -q "role=1035-pc-carrier" "$REC" && { echo "REFUSING: $REC already carries a 1035-pc-carrier block"; exit 1; }
mkdir -p "$PARK"
for m in "${MEMBERS[@]}"; do cp -p "$LIVE/$m" "$PARK/$m"; done
cp -p "$PATCHER" "$PARK/patch_d13_pc_carrier.py"
cp -p "$CHECKER" "$PARK/check_1035_capture.py"
CARD_SHA=$(sha256sum "$CARD" | awk '{print $1}')

# THE FROZEN RE-READ: the rung's own claims on the PARKED bytes.
for _k in '^xnu_live_pcc_pc=' '^xnu_live_pcc_dev_xor_f0=' '^xnu_live_pcc_dev_xor_f1=' '^xnu_live_evf_pc=' \
          '^xnu_live_cal_region_end=' '^xnu_live_wrp_r4=' '^xnu_live_abt_lookup_far='; do
  grep -qa "$_k" <(strings "$PARK/xnu_arm_entry.elf") || { echo "REFUSING: the FROZEN $PARK/xnu_arm_entry.elf lost $_k - the copy is not the certified bytes; remove $PARK and re-run"; exit 1; }
done
python3 -I tools/check_vm_max_split.py "$PARK/xnu_arm_entry.elf" --expect on >/dev/null 2>&1 || { echo "REFUSING: the frozen image lost 1024's ceiling claim"; exit 1; }
python3 -I tools/check_1023_trap24.py "$PARK/xnu_arm_entry.elf" --expect on >/dev/null 2>&1 || { echo "REFUSING: the frozen image lost 1023's row-24 claim"; exit 1; }
python3 -I "$PARK/check_1035_capture.py" --selftest >/dev/null 2>&1 || { echo "REFUSING: the PARKED 1035 reader does not selftest"; exit 1; }
[[ $(sha256sum "$LIVE/xnu_card_hfs.img" | awk '{print $1}') == "$CARD_SHA" ]] || { echo "REFUSING: the card changed while parking"; exit 1; }
echo "   FROZEN: the parked image carries pcc + evf + cal + wrp + lookup_far, 1024's ceiling, 1023's row 24; the reader selftests; the card sha is pinned"

{
  printf '\n# =================================================================================================\n'
  printf '# %s  -  1035: THE pc CARRIER, BY THE DEVICE-S OWN PAGE CONTENT.  INSTRUMENT ONLY.\n' "$ARM"
  printf '# 1033 (records/1033-reading.txt) read EVF-U1-TRUE: launchctl[2] faults on a LOAD at 0x10 (dfsr 7),\n'
  printf '# pc 0x3819d474 lr 0x381959af.  records/1034-design-errata.txt E12 leaves two candidates for the\n'
  printf '# faulting instruction: (a) the caller-s walk at the host file VA 0x37C26474, (b) the data word at\n'
  printf '# pc in the host-s image.  NOT a return if the fault path runs: a resident rung.\n'
  printf '# NEW SWITCH: %s=1 (tools/patch_d13_pc_carrier.py), a trap.c block INSIDE\n' "$NEW"
  printf '# 1025-s publisher AFTER 1033-s evf block.  Rows xnu_live_pcc_*: pid, pc/lr/r1/r5/r2/r7, the words\n'
  printf '# at pc-0x20, pc-0x08, pc, pc+0x08, pc+0x20, lr read with copyin from the task map (+ _ok rows), and\n'
  printf '# their XOR against the host-s file words for both candidates.  READS ONLY.\n'
  printf '# CHANNEL: the global DEFINES array (build_xnu_arm_kernel.sh); a -D in EXTRA is not the channel.\n'
  printf '# THE POOL MOVES: trap.c is a pool object, so the entry bin (and the arm name) MOVES.\n'
  printf '# [[mi4-one-file-many-rungs]]: trap.c is edited by 994/1020/1025/1026/1029/1030/1031/1033/1035; the\n'
  printf '# new switch is in EVERY trap.c patcher-s ALLOWED_IF_IDENTIFIERS, and a bare\n'
  printf '# `git checkout --` reverts the others SILENTLY.\n'
  printf '# THE CARD: 1035 serves 1032-s 10 bytes (card 0x10183720 = %s).  Not a park member\n' "$NEW_HEX"
  printf '# (the card is ~900 MiB); the card-s sha256 is pinned here and its content anchor is checked by\n'
  printf '# patch_cache_libobjc_count.py --check [2].\n'
  printf '# THE READING: %s (pre-registered cells P1-P4 in records/1035-carrier-by-pc-read.txt 3).\n' "$CHECKER"
  printf '# Medium: 968 real iOS 7.1.2 HFSX rootfs over hfs_rmd0; CARD_COW=1, HDD_WRITE=0, base never\n'
  printf '# written - fully reversible.  fastboot boot only, NEVER flash.\n'
  printf '# card_sha256=%s card_off=0x10183720 card_new=%s\n' "$CARD_SHA" "$NEW_HEX"
  printf '# =================================================================================================\n'
  for m in "${MEMBERS[@]}"; do
    printf 'set=%s sha256=%s bytes=%s file=%s role=1035-pc-carrier;%s\n' "$ARM" "$(sha256sum "$PARK/$m" | awk '{print $1}')" "$(stat -c %s "$PARK/$m")" "$m" "$m"
  done
  printf 'set=%s sha256=%s bytes=%s file=%s role=1035-pc-carrier-editors-definition\n' "$ARM" "$(sha256sum "$PARK/patch_d13_pc_carrier.py" | awk '{print $1}')" "$(stat -c %s "$PARK/patch_d13_pc_carrier.py")" patch_d13_pc_carrier.py
  printf 'set=%s sha256=%s bytes=%s file=%s role=1035-pc-carrier-capture-reader\n' "$ARM" "$(sha256sum "$PARK/check_1035_capture.py" | awk '{print $1}')" "$(stat -c %s "$PARK/check_1035_capture.py")" check_1035_capture.py
} >> "$REC"

echo "recorded $ARM (role=1035-pc-carrier) in $REC"
echo "parked $ARM ($(ls -1 "$PARK" | wc -l) members)"
echo "   verify: tools/verify_revert_set.sh $PARK --set=$ARM"
# THE LIVE COPIES the record's file= lines also name (the press's preflight reads one directory at a time;
# same reasoning as park_1033.sh's tail).  Copying them NOW is what makes the gate read 28/28 on the
# FIRST press run instead of after a refused one.
cmp -s "$PATCHER" "$LIVE/$(basename "$PATCHER")" || cp -p "$PATCHER" "$LIVE/$(basename "$PATCHER")"
cmp -s "$CHECKER" "$LIVE/$(basename "$CHECKER")" || cp -p "$CHECKER" "$LIVE/$(basename "$CHECKER")"
echo "   live copies placed: $LIVE/$(basename "$PATCHER"), $LIVE/$(basename "$CHECKER") (identical bytes to the park's)"