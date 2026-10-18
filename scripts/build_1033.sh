#!/bin/bash
# 1033 -- THE EVAL-FRAME PROBE.  INSTRUMENT ONLY: no fix, no card change beyond 1032's own 10 bytes.
#
# WHAT 1032 READ (records/1032-reading.txt): FIX-PARTIAL.  The 10-byte libobjc count clamp removed the
# 1030 fault (a WRITE at the stack region's exclusive top, writer pc 0x37C26756) from the capture, but
# the boot now ends with a DIFFERENT usermode data abort -- launchctl[2], EXC_BAD_ACCESS at 0x10,
# dfsr type 7 (far(trunc)=0), after `launchd[1] has started up`, ending in
# "The System bootstrapper has crashed: Bus error: 10".  The frame printed pc=0x3b547474 lr=0x3b53f9af
# sp=0x2bdcf088 r2=r5=0xffffffff r3=0x3b6aa020 r7=0x2bdcf0ac r8=0x30dd8575.
#
# WHAT 1033 IS.  ONE new switch STAGE90_XNU_EVAL_FRAME=1 and one new patcher
# (tools/patch_d13_eval_frame.py) that adds trap.c rows naming the 1032 frame BY VALUE:
#   - arm_ctx->far UNTRUNCATED (the raw DFAR; the 1025 row prints vm_map_trunc_page(dfar), which is 0 for
#     dfar=0x10 and therefore cannot tell 0x10 from 0 -- records/1032-reading.txt 3);
#   - pc/lr/sp/cpsr and pc-far raw, so the +8-ptr / ptr-0x08 / faulting-instruction readings separate;
#   - the words the frame's own registers point at, read with copyin only;
#   - 1031's caller block is carried VERBATIM (its rows are the local neighbourhood of the frame).
# It carries 1032's CARD: the 10 bytes are applied by scripts/build_1032.sh's own step (below), so the
# press serves the patched cache AND the new instrument in one run.
#
# THE KERNEL IS REBUILT (trap.c is a POOL object), so THE ARM NAME MOVES: armed-d13-<sha8 of the new
# xnu_arm_entry.bin>.  Every switch rides the record; every file's OFF/ON proof is re-run.
#
# STAGING ORDER ([[mi4-one-file-many-rungs]]) -- the rungs edit ONE trap.c, so each is re-staged from the
# top each build; the eval-frame block belongs to the SAME file, so its identifiers are a shared
# namespace and EVERY trap.c patcher's ALLOWED_IF_IDENTIFIERS carries STAGE90_XNU_EVAL_FRAME.
#
# fastboot boot only, NEVER flash.  Builds host-side files; touches no device.
set -euo pipefail
cd "$(dirname "$0")/.."

XNU_TREE=${XNU_TREE:-$PWD/external/xnu-hd2-darwin13/xnu}
# ABSOLUTE: patch_d13_vm_max_split.py runs the real preprocessor from a temp dir over a probe TU
# that #includes this path -- a relative one resolves from /tmp and 1024's proof fails on its
# include, AFTER the staging (build_1031.sh pins $PWD for the same reason).
LIVE=out/stage90
REC=$LIVE/xnu_arm_entry-config.txt
POOL=out/xnu_kernel_obj_d13
TRAP_OBJ=$POOL/osfmk_arm_trap.o
EXEC_OBJ=$POOL/bsd_kern_kern_exec.o
TRAP_SRC=$XNU_TREE/osfmk/arm/trap.c
EXEC_SRC=$XNU_TREE/bsd/kern/kern_exec.c
NEW=STAGE90_XNU_EVAL_FRAME
PATCHER=tools/patch_d13_eval_frame.py

echo "== 1033: THE EVAL-FRAME PROBE ($NEW=1; instrument only) =="
[[ -f $PATCHER ]] || { echo "REFUSING: $PATCHER is absent - it is the whole edit"; exit 1; }
# THE CHANNEL.  The first 1033 pool build exported $NEW=1 but tools/build_xnu_arm_kernel.sh had NO
# `DEFINES+=(...)` reader for it, so the env variable reached nothing, the pool compiled the
# un-instrumented trap.c, and step 4 refused on the absent evf rows with a message blaming the edit --
# the [[mi4-build-variant-comes-from-an-env-default]] shape (an env switch with no reader).  Refuse
# BEFORE the 705-object compile.
grep -q "DEFINES+=(-D$NEW=1)" tools/build_xnu_arm_kernel.sh || { echo "REFUSING: tools/build_xnu_arm_kernel.sh carries no DEFINES+=(-D$NEW=1) line - the export in step 2 would reach nothing and the pool would keep the un-instrumented trap.c. Add the reader to its global DEFINES array first"; exit 1; }

# ====================================================================================================
# 0. THE RECORD MUST BE 1032'S LINEAGE (each inherited switch is what makes the parent rows live).
# ====================================================================================================
echo "-- 0. the record is the 1031/1032 arm's (the parent rows must still publish) --"
[[ -r $REC ]] || { echo "REFUSING: no arm record at $REC -- build 1031 first (1032 built no kernel)"; exit 1; }
for k in STAGE90_XNU_CALLER_PROBE STAGE90_XNU_WRITER_PROBE STAGE90_XNU_READER_PROBE \
         STAGE90_XNU_ABT_ENTRY_PROBE STAGE90_XNU_USTACK_PROBE STAGE90_XNU_H2_STACK_HEADROOM \
         STAGE90_XNU_VM_MAX_SPLIT STAGE90_XNU_IOS7_TRAPS STAGE90_XNU_GENERAL_REGS \
         STAGE90_XNU_UNDEF_RAISE; do
  grep -q "^$k=1\$" "$REC" || { echo "REFUSING: $REC does not carry $k=1 - this is not the 1031 arm 1033 instruments. The rows 1033 is read BESIDE (cal/wrp/rdr/abt) and the geometry it names (H2) ride those switches; without them the eval rows describe a boot this rung was not written against. Build 1031 first"; exit 1; }
done
echo "   the record carries all 10 inherited switches"

# **IDEMPOTENT RE-ENTRY** (the record is shared live state): our own switch may be a prior run's trace,
# but a half-staged one (present with a value != 1) is a foreign arm - refuse.
if grep -q "^$NEW=" "$REC" && ! grep -q "^$NEW=1\$" "$REC"; then
  echo "REFUSING: $REC carries $NEW with a value other than 1 - a stale/foreign arm with a half-staged eval-frame probe"; exit 1; fi
grep -q "^$NEW=1\$" "$REC" && echo "   note: $REC already carries $NEW=1 (this build's own prior trace); re-entering idempotently"

# ====================================================================================================
# 1. STAGE THE TREE EDITS -- the whole trap.c chain, then 1033's eval-frame block LAST.
# ====================================================================================================
echo "-- 1. stage the tree edits (the 1025->1031 chain, then 1033's eval frame) --"
_stage() { # name, [--apply]
  local p=$1; shift
  python3 "$p" "$XNU_TREE" "$@" >/dev/null || { echo "FAIL: $p $* refused on the tree"; exit 1; }
}
_stage tools/patch_d13_ios7_vmwire.py
_stage tools/patch_d13_mach_trap15.py
_stage tools/patch_d13_mach_trap15.py --apply
_stage tools/patch_d13_mach_trap_ports.py
_stage tools/patch_d13_mach_trap_ports.py --apply
_stage tools/patch_d13_mach_trap_ports.py --verify-off
# 1020's udf-raise fix and 994's dyld witness edit the SAME trap.c; a bare `git checkout --` between
# rungs reverts them silently ([[mi4-one-file-many-rungs]]), and the linked image's inherited check would
# fail LATE (after the pool compile).  Re-stage, do not assume.
_stage tools/patch_d13_vm_max_split.py --apply
_stage tools/patch_d13_vm_max_split.py --verify-off
_stage tools/patch_d13_undef_raise.py
_stage tools/patch_d13_undef_raise.py --verify-off
_stage tools/patch_d13_dyld_witness.py
_stage tools/patch_d13_dyld_witness.py --verify-off
_stage tools/patch_d13_ustack_probe.py --apply
_stage tools/patch_d13_ustack_probe.py --verify-off
_stage tools/patch_d13_abt_entry_probe.py --apply
_stage tools/patch_d13_abt_entry_probe.py --verify-off
_stage tools/patch_d13_h2_stack_headroom.py --apply
_stage tools/patch_d13_h2_stack_headroom.py --verify-off
_stage tools/patch_d13_reader_probe.py --apply
_stage tools/patch_d13_reader_probe.py --verify-off
_stage tools/patch_d13_writer_probe.py --apply
_stage tools/patch_d13_writer_probe.py --verify-off
_stage tools/patch_d13_caller_probe.py --apply
_stage tools/patch_d13_caller_probe.py --verify-off
# ---- 1033: THE EVAL FRAME (a block in trap.c inside 1025's publisher; NOTHING is changed in kern_exec.c)
echo "-- tools/patch_d13_eval_frame.py (1033: trap.c xnu_live_evf_* rows on the failing path) --"
_stage tools/patch_d13_eval_frame.py
_stage tools/patch_d13_eval_frame.py --apply
_stage tools/patch_d13_eval_frame.py --apply          # second apply = the idempotent no-op
_stage tools/patch_d13_eval_frame.py --verify-off
# The composed tree: every other trap.c patcher must still ACCEPT it (the shared namespace in effect).
for p in tools/patch_d13_ustack_probe.py tools/patch_d13_undef_raise.py tools/patch_d13_dyld_witness.py \
         tools/patch_d13_abt_entry_probe.py tools/patch_d13_reader_probe.py tools/patch_d13_writer_probe.py \
         tools/patch_d13_caller_probe.py tools/patch_d13_eval_frame.py; do
  _stage "$p"
done
[[ $(grep -c 'xnu_live_evf_pc=' "$TRAP_SRC") == 1 ]] || { echo "FAIL: $TRAP_SRC does not carry EXACTLY 1 xnu_live_evf_pc= row - a partial or double edit"; exit 1; }
[[ $(grep -c '^#endif /\* STAGE90_XNU_EVAL_FRAME \*/' "$TRAP_SRC") == 1 ]] || { echo "FAIL: $TRAP_SRC does not carry EXACTLY 1 \`#endif /* STAGE90_XNU_EVAL_FRAME */\` - the ON/OFF gate is not bracketed"; exit 1; }
_evf=$(grep -n '^#endif /\* STAGE90_XNU_EVAL_FRAME \*/' "$TRAP_SRC" | cut -d: -f1)
_cal=$(grep -n '^#endif /\* STAGE90_XNU_CALLER_PROBE \*/' "$TRAP_SRC" | head -1 | cut -d: -f1)
_ust=$(grep -n '^#endif /\* STAGE90_XNU_USTACK_PROBE \*/' "$TRAP_SRC" | head -1 | cut -d: -f1)
[[ -n $_evf && -n $_cal && $_cal -lt $_evf && $_evf -lt $_ust ]] || { echo "FAIL: the eval-frame gate is NOT bracketed correctly (caller #endif=$_cal < evf #endif=$_evf < ustack #endif=$_ust). Its rows must sit INSIDE 1025's publisher (or they never execute) and AFTER 1031's"; exit 1; }
echo "   staged: the eval-frame rows sit after 1031's block ($_cal) and inside 1025's gate ($_evf < $_ust); kern_exec.c untouched by 1033"

# ====================================================================================================
# 2. EXPORT THE POOL SWITCHES (the 1031 set verbatim + THIS rung's), BEFORE THE POOL BUILD.
# ====================================================================================================
echo "-- 2. export the pool switch set (the record's, verbatim) + $NEW=1 --"
EXPORTS=()
while IFS= read -r line; do
  line=${line%%$'\r'}
  [[ -z $line || $line == \#* ]] && continue
  k=${line%%=*}; v=${line#*=}
  [[ $v == '(unset)' ]] && continue
  case $k in STAGE90_XNU_ENTRY_SHA256|STAGE90_XNU_ENTRY_BYTES) continue ;; esac
  EXPORTS+=("$k=$v")
done < "$REC"
EXPORTS+=("STAGE90_ENTRY_ARM_CHANGE=1")
EXPORTS+=("XNU_TREE=$XNU_TREE")
EXPORTS+=("$NEW=1")
echo "   carrying $(( ${#EXPORTS[@]} - 3 )) switch(es) from $REC + $NEW=1"

# The -D set: everything the record names EXCEPT the switches whose channel is the global DEFINES array or
# a FLAG (build_xnu_arm_kernel.sh reads those from the ENV, exported below), plus 1015b's token which has
# NO record carrier (records/1020-build-defect.txt).
EXTRA=""
while IFS= read -r line; do
  line=${line%%$'\r'}
  [[ -z $line || $line == \#* ]] && continue
  k=${line%%=*}; v=${line#*=}
  [[ $v == '(unset)' ]] && continue
  case $k in
    STAGE90_XNU_ENTRY_SHA256|STAGE90_XNU_ENTRY_BYTES) continue ;;
    STAGE90_XNU_HFS_ROOT_RW|STAGE90_XNU_GENERAL_REGS|STAGE90_XNU_VM_MAX_SPLIT|STAGE90_XNU_USTACK_PROBE|\
    STAGE90_XNU_ABT_ENTRY_PROBE|STAGE90_XNU_H2_STACK_HEADROOM|STAGE90_XNU_READER_PROBE|\
    STAGE90_XNU_WRITER_PROBE|STAGE90_XNU_CALLER_PROBE|STAGE90_XNU_EVAL_FRAME) continue ;;
  esac
  [[ $k == STAGE90_* ]] || continue
  case $v in 0|1|0x*|[0-9]*) ;; *) continue ;; esac
  EXTRA="$EXTRA -D$k=$v"
done < "$REC"
EXTRA="${EXTRA# } -DSTAGE90_XNU_GLOBAL_FIX=1"
echo "-- extra defines: $EXTRA --"
[[ "$EXTRA" == *"-DSTAGE90_XNU_GLOBAL_FIX=1"* ]] || { echo "FAIL: -DSTAGE90_XNU_GLOBAL_FIX=1 is NOT in EXTRA - 1015b's fix has NO record carrier; without it the retry storm returns"; exit 1; }
for _g in VM_MAX_SPLIT USTACK_PROBE ABT_ENTRY_PROBE H2_STACK_HEADROOM READER_PROBE WRITER_PROBE CALLER_PROBE EVAL_FRAME; do
  [[ "$EXTRA" != *"-DSTAGE90_XNU_$_g"* ]] || { echo "FAIL: -DSTAGE90_XNU_$_g is in EXTRA -- its channel is the global DEFINES array (env export), not XNU_KERNEL_EXTRA_DEFINES"; exit 1; }
done

# Every switch whose channel is the global DEFINES array is exported from the RECORD's value (never a
# hard-coded default: [[mi4-build-variant-comes-from-an-env-default]]), and THIS rung's switch is set here.
for _g in VM_MAX_SPLIT USTACK_PROBE ABT_ENTRY_PROBE H2_STACK_HEADROOM READER_PROBE WRITER_PROBE CALLER_PROBE; do
  export "STAGE90_XNU_$_g=1"
done
export "$NEW=1"
# **1021d's FLAG switch** (1031 line 324).  build_xnu_arm_kernel.sh reads STAGE90_XNU_GENERAL_REGS into
# its FP_FLAGS (`--print-flags` showed "STAGE90_XNU_GENERAL_REGS=0 -> ... -mfpu=neon-vfpv4"): it is a
# COMPILER FLAG, not a -D, so it is in EXTRA's skip list and this loop (which ended before GENERAL_REGS)
# never exported it.  The pool therefore compiled with NEON ON while the record said 1, and the entry
# link refused after the compile: "mach_msg_send's own extent still reads the other way".  Export it
# from the RECORD's value, verified, exactly as 1031 does.
[[ $(awk -F= '$1=="STAGE90_XNU_GENERAL_REGS"{print $2}' "$REC") == 1 ]] || { echo "FAIL: $REC does not record STAGE90_XNU_GENERAL_REGS=1"; exit 1; }
export STAGE90_XNU_GENERAL_REGS=1
export STAGE90_XNU_HFS_ROOT_RW=$(awk -F= '$1=="STAGE90_XNU_HFS_ROOT_RW"{print $2}' "$REC")
# **THE HFS PORT ITSELF** (1031 line 307; 1029 line 266).  `STAGE90_XNU_HFS_ROOT_RW` is a tree-layout
# define that build_xnu_arm_kernel.sh emits only when the PORT is on (`HFS_PORT=${STAGE90_XNU_HFS:-0}`).
# 1031 exported HFS=1 beside it; 1033's first two runs did NOT, so the pool skipped the HFS sources,
# hfs_vfsops.o kept its stale no-clear form, and the entry link refused LATE -- after the 705-object
# compile -- with "the pool's hfs_vfsops.o predates 905 B2's clear" ([[mi4-off-option-two-spellings]]:
# the record asked for a writable root the pool was built without).  The record-vs-export agreement is checked here.
[[ $(awk -F= '$1=="STAGE90_XNU_HFS_ROOT_RW"{print $2}' "$REC") == 1 ]] || { echo "FAIL: $REC does not record STAGE90_XNU_HFS_ROOT_RW=1 - the HFS port export below is only right for the rw arm"; exit 1; }
export STAGE90_XNU_HFS=1
echo "-- STAGE90_XNU_HFS=1 STAGE90_XNU_HFS_ROOT_RW=$STAGE90_XNU_HFS_ROOT_RW (the pool's hfs_vfsops.o carries the rw clear; the entry link reads it back) --"
echo "   exported STAGE90_XNU_{VM_MAX_SPLIT,USTACK,ABT_ENTRY,H2_STACK_HEADROOM,READER,WRITER,CALLER,EVAL_FRAME}_PROBE=1 (channel: global DEFINES)"

# ====================================================================================================
# 3. BUILD: asm layer (untouched by 1033), pool, entry link, payload.
# ====================================================================================================
echo "-- 3. arm asm layer (1033 touches NO .s file) --"
XNU_TREE="$XNU_TREE" XNU_KERNEL_CONFIG=STAGE90_XNU tools/assemble_arm_layer.sh
echo "-- the D13 kernel pool (trap.o moves; kern_exec.c is unchanged and rebuilds identically) --"
XNU_TREE="$XNU_TREE" XNU_KERNEL_CONFIG=STAGE90_XNU \
XNU_MASTER_LOCAL="$PWD/tools/xnu_config/boot/STAGE90_XNU.local" \
XNU_KERNEL_EXTRA_DEFINES="$EXTRA" \
    ./tools/build_xnu_arm_kernel.sh

# ====================================================================================================
# 4. THE OBJECT-SIDE ASSERTIONS (grep -qa P <(strings X), never `strings X | grep -q P` -- SIGPIPE 141).
# ====================================================================================================
echo "-- 4. the pool objects --"
[[ -f $TRAP_OBJ && -f $EXEC_OBJ ]] || { echo "FAIL: pool objects absent"; exit 1; }
for s in xnu_live_evf_pc= xnu_live_evf_far_raw= xnu_live_evf_far_is_0x10= xnu_live_evf_pc_minus_far= \
         xnu_live_evf_slot10= xnu_live_evf_slot10_ok= xnu_live_evf_ptr_word= xnu_live_evf_ptr_word_ok=; do
  grep -qa "^$s" <(strings "$TRAP_OBJ") || { echo "FAIL: $TRAP_OBJ carries NO $s row - the pool was NOT recompiled with $NEW=1 (env channel) or the trap.c edit is not staged. Without it the press captures nothing and 1033 reads NO READING for a build-side reason"; exit 1; }
done
# the parents must survive the rebuild
for s in xnu_live_cal_region_end= xnu_live_wrp_r4= xnu_live_rdr_far= xnu_live_abt_lookup_far= xnu_live_abt_vmfkrv=; do
  grep -qa "^$s" <(strings "$TRAP_OBJ") || { echo "FAIL: $TRAP_OBJ lost $s - the pool rebuild dropped an inherited switch"; exit 1; }
done
grep -q "$NEW" "$TRAP_SRC" || { echo "FAIL: the staged trap.c carries no $NEW"; exit 1; }
_src_rec=out/xnu_kernel_src_d13.sha256
[[ -s $_src_rec ]] || { echo "FAIL: $_src_rec absent - the pool's source record cannot certify the rebuild"; exit 1; }
_tc_want=$(sha256sum "$TRAP_SRC" | awk '{print $1}')
_tc_have=$(awk -v p="$TRAP_SRC" '$2==p{print $1}' "$_src_rec" | head -1)
[[ -n $_tc_have && "$_tc_want" == "$_tc_have" ]] || { echo "FAIL: $_src_rec's trap.c hash (${_tc_have:-none}) != the staged file's ($_tc_want) - the pool was NOT rebuilt from the staged trap.c"; exit 1; }
echo "   4 PASS: trap.o carries all 8 evf rows and the 5 parent row families; the pool's source record names the staged trap.c's sha256"

# ====================================================================================================
# 5. THE ENTRY LINK AND THE LINKED-IMAGE CLAUSES.
# ====================================================================================================
echo "-- 5. entry link --"
( cd src/entry && env -i PATH="$PATH" HOME="$HOME" "${EXPORTS[@]}" ./build_entry.sh )
ELF=$LIVE/xnu_arm_entry.elf
for s in xnu_live_evf_pc= xnu_live_evf_far_raw= xnu_live_cal_region_end= xnu_live_wrp_r4= xnu_live_abt_lookup_far= xnu_live_abt_vmfkrv=; do
  grep -qa "^$s" <(strings "$ELF") || { echo "FAIL: the LINKED image carries NO $s - the linker dropped an object the press reads"; exit 1; }
done
python3 tools/check_vm_max_split.py "$ELF" --expect on >/dev/null || { echo "FAIL: the LINKED image's task map ceiling moved (1024)"; exit 1; }
python3 tools/check_1023_trap24.py "$ELF" --expect on >/dev/null || { echo "FAIL: the LINKED image's mach_trap_table[24] moved (1023)"; exit 1; }
echo "   5 PASS: the linked image carries the evf rows AND the 1031/1030/1027/1025 parents; 1024's ceiling and 1023's row 24 intact"

# ====================================================================================================
# 6. THE PAYLOAD, then 1032's CARD (the rung 1033 instruments must be ON the device).
# ====================================================================================================
echo "-- 6. payload --"
XNU_TREE="$XNU_TREE" STAGE90_EXTRA_CFLAGS='-DSTAGE90_XNU_ENTRY=1' ./scripts/build.sh
echo "-- 6b. the card: 1032's 10 bytes, applied by scripts/build_1032.sh (the patched cache must be the one served) --"
scripts/build_1032.sh | tail -4
_card=$LIVE/xnu_card_hfs.img
_rs=${STAGE90_REAL_ROOTFS:-/mnt/data/ios7-payload/v2/ios7/rootfs.hfs}
[[ -f $_card ]] || { echo "FAIL: the card is absent after build_1032.sh"; exit 1; }
_n=$(cmp -l "$_card" "$_rs" 2>/dev/null | wc -l || true)
[[ $_n == 10 ]] || { echo "FAIL: the card differs from the pristine rootfs in $_n bytes, want EXACTLY the 10 guard bytes"; exit 1; }
_got=$(dd if="$_card" bs=1 skip=$((0x10183720)) count=10 2>/dev/null | od -An -tx1 | tr -d ' \n')
[[ $_got == 5010012801daf0bdc046 ]] || { echo "FAIL: card 0x10183720 = $_got, want the 1032 guard"; exit 1; }
echo "   6b PASS: card carries 1032's guard (10 bytes) on the pristine rootfs"

printf 'STAGE90_XNU_GLOBAL_FIX=1 role=1033-eval-frame\n' > "$LIVE/xnu_arm_entry-arm-extra.txt"
echo "== result =="
printf 'entry bin sha (first 8): '
sha256sum "$LIVE/xnu_arm_entry.bin" | cut -c1-8
echo "-- what the record carries --"
grep -E 'STAGE90_XNU_(EVAL_FRAME|CALLER|WRITER|READER)_PROBE' "$REC" || true
echo "== 1033 build DONE (1031 + $NEW, instrument only). Not pressed."
echo "   Park it (scripts/park_1033.sh), then press (scripts/press_1033.sh); the press is read by tools/check_1033_capture.py."