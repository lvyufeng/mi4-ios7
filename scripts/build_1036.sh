#!/bin/bash
# 1036 -- THE PC CARRIER'S CALLER PROBE.  INSTRUMENT ONLY: no fix, no card change beyond 1032's own 10 bytes.
#
# WHAT 1035 READ (records/1035-read.txt): the device RAN the walk.  1035's pcc rows put the carrier on the
# caller's walk (xnu_live_pcc_xor_walk=0; the walk is NOT on the path 1032's clamp guards).  1034's static
# trace (records/1034b-*) leaves OPEN which caller entered the walk: a Thumb `bl` from the long-name path,
# or a re-entry to the histogram bucket scan.  1036 names it BY VALUE on the device.
#
# WHAT 1036 IS.  ONE new switch STAGE90_XNU_PC_CARRIER_CALLER=1 and one new patcher
# (tools/patch_d13_pc_carrier_caller.py, modelled on 1035's) that inserts a block in trap.c AFTER 1035's
# pc-carrier block, INSIDE 1025's failure arm, gated on pid 2, printing rows `xnu_live_pcc2_*` that carry
# the walk's caller chain (lr_m4 / lr_m8 and their _ok rows) and the optimised-class table read
# (tbl_used / tbl_used_ok).  1035's pcc block and 1033's evf block are carried (their rows are what the
# pcc2 rows are read BESIDE).
# It carries 1032's CARD: the 10 bytes are applied by scripts/build_1032.sh's own step (below), so the
# press serves the patched cache AND the new instrument in one run.
#
# THE KERNEL IS REBUILT (trap.c is a POOL object), so THE ARM NAME MOVES: armed-d13-<sha8 of the new
# xnu_arm_entry.bin>.  Every switch rides the record; every file's OFF/ON proof is re-run.
#
# STAGING ORDER ([[mi4-one-file-many-rungs]]) -- the rungs edit ONE trap.c, so each is re-staged from the
# top each build; EVERY trap.c patcher's ALLOWED_IF_IDENTIFIERS must carry BOTH STAGE90_XNU_PC_CARRIER
# and STAGE90_XNU_PC_CARRIER_CALLER or it will refuse the 1036-composed tree at the acceptance sweep.
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
NEW=STAGE90_XNU_PC_CARRIER_CALLER
PATCHER=tools/patch_d13_pc_carrier_caller.py
# 1035's switch: this rung's block sits AFTER 1035's, and the pcc rows are a parent of the pcc2 rows.
PCC=STAGE90_XNU_PC_CARRIER
PCC_PATCHER=tools/patch_d13_pc_carrier.py

echo "== 1036: THE PC CARRIER'S CALLER PROBE ($NEW=1; instrument only) =="
[[ -f $PATCHER ]] || { echo "REFUSING: $PATCHER is absent - it is the whole edit"; exit 1; }
[[ -f $PCC_PATCHER ]] || { echo "REFUSING: $PCC_PATCHER is absent - 1036's block is anchored on 1035's block"; exit 1; }
# THE CHANNEL ([[mi4-build-variant-comes-from-an-env-default]]): a switch with no `DEFINES+=(-D...)` reader
# in the pool builder reaches nothing and step 4 refuses AFTER the 705-object compile.  Refuse BEFORE it.
# (1035's lesson, verbatim.)
for _n in $PCC $NEW; do
  grep -q "DEFINES+=(-D$_n=1)" tools/build_xnu_arm_kernel.sh || { echo "REFUSING: tools/build_xnu_arm_kernel.sh carries no DEFINES+=(-D$_n=1) line - the export in step 2 would reach nothing and the pool would keep the un-instrumented trap.c. Add the reader to its global DEFINES array first (it is another lane's edit)"; exit 1; }
done

# ====================================================================================================
# 0. THE RECORD MUST BE THE LINEAGE THE pcc2 ROWS ARE READ BESIDE.
# ====================================================================================================
echo "-- 0. the record carries the 1035/1033/1031/1025 chain (the parent rows must still publish) --"
[[ -r $REC ]] || { echo "REFUSING: no arm record at $REC -- build 1035 first"; exit 1; }
for k in $PCC STAGE90_XNU_EVAL_FRAME \
         STAGE90_XNU_CALLER_PROBE STAGE90_XNU_WRITER_PROBE STAGE90_XNU_READER_PROBE \
         STAGE90_XNU_ABT_ENTRY_PROBE STAGE90_XNU_USTACK_PROBE STAGE90_XNU_H2_STACK_HEADROOM \
         STAGE90_XNU_VM_MAX_SPLIT STAGE90_XNU_IOS7_TRAPS STAGE90_XNU_GENERAL_REGS \
         STAGE90_XNU_UNDEF_RAISE; do
  grep -q "^$k=1\$" "$REC" || { echo "REFUSING: $REC does not carry $k=1 - this is not the 1035 arm 1036 instruments. The pcc2 rows are read BESIDE 1035's pcc rows, 1033's evf frame and the 1025 publisher; without them the pcc2 rows describe a boot this rung was not written against. Build 1035 first"; exit 1; }
done
echo "   the record carries the whole inherited chain (12 switches + $PCC)"
# **AND THE RECORD MUST BE ABLE TO CARRY $NEW** (park_1036.sh's clause (a) reads it; a switch the pool can
# see and the record cannot is the [[mi4-build-variant-comes-from-an-env-default]] shape).  Each of the three
# registration files is ANOTHER LANE'S edit; the build only READS them.  The entry-file list closes its array
# with a bare `$NEW` line while the preflight list closes with `$NEW)`, so match the key at any indentation.
for _f in src/entry/build_entry.sh scripts/preflight_boot_check.sh; do
  [[ -f $_f ]] || { echo "REFUSING: $_f is absent"; exit 1; }
done
grep -qE "^[[:space:]]*$NEW\)?$" src/entry/build_entry.sh || { echo "REFUSING: src/entry/build_entry.sh does not list $NEW in ENTRY_ARM_KEYS - the record would omit it and park_1036.sh would refuse the arm after the compile. (Registration is another lane's edit; build only READS these files.)"; exit 1; }
grep -qE "^[[:space:]]*$NEW\)$" scripts/preflight_boot_check.sh || { echo "REFUSING: scripts/preflight_boot_check.sh does not list $NEW in its gate key list - the next press would refuse the record the build just wrote. (Registration is another lane's edit.)"; exit 1; }
grep -qE "^[[:space:]]*$NEW\)[[:space:]]+_v=" src/entry/build_entry.sh || { echo "REFUSING: src/entry/build_entry.sh has no case arm for $NEW - the key would be read back empty. (Registration is another lane's edit.)"; exit 1; }
grep -q "echo \"$NEW=" src/entry/build_entry.sh || { echo "REFUSING: src/entry/build_entry.sh does not ECHO $NEW into the record - build_entry.sh rewrites out/stage90/xnu_arm_entry-config.txt from ENTRY_ARM_KEYS, so the arm would be recorded for a switch this image never compiled. (Registration is another lane's edit.)"; exit 1; }
echo "   the entry layer lists, reads and ECHOES $NEW (the record can carry it)"

# **IDEMPOTENT RE-ENTRY** (the record is shared live state): a half-staged value is a foreign arm - refuse.
if grep -q "^$NEW=" "$REC" && ! grep -q "^$NEW=1\$" "$REC"; then
  echo "REFUSING: $REC carries $NEW with a value other than 1 - a stale/foreign arm with a half-staged caller probe"; exit 1; fi
grep -q "^$NEW=1\$" "$REC" && echo "   note: $REC already carries $NEW=1 (this build's own prior trace); re-entering idempotently"

# ====================================================================================================
# 1. STAGE THE TREE EDITS -- the whole trap.c chain (incl. 1033's eval frame and 1035's pcc block), then
#    1036's block LAST.
# ====================================================================================================
echo "-- 1. stage the tree edits (the 1025->1033 chain, 1035's pc carrier, then 1036's caller) --"
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
# rungs reverts them silently ([[mi4-one-file-many-rungs]]).  Re-stage, do not assume.
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
# ---- 1035: THE PC CARRIER (a block after 1033's evf block; 1036's block opens on ITS #endif)
echo "-- tools/patch_d13_pc_carrier.py (1035: trap.c xnu_live_pcc_* rows on the failing path) --"
export $PCC=1
_stage $PCC_PATCHER
_stage $PCC_PATCHER --apply
_stage $PCC_PATCHER --apply          # second apply = the idempotent no-op
_stage $PCC_PATCHER --verify-off
# ---- 1036: THE CALLER (a block in trap.c after 1035's pcc block, inside 1025's failure arm, pid 2)
echo "-- $PATCHER (1036: trap.c xnu_live_pcc2_* rows on the failing path) --"
export "$NEW=1"
_stage $PATCHER
_stage $PATCHER --apply
_stage $PATCHER --apply          # second apply = the idempotent no-op
_stage $PATCHER --verify-off
# The composed tree: every other trap.c patcher must still ACCEPT it (the shared namespace in effect).
for p in tools/patch_d13_ustack_probe.py tools/patch_d13_undef_raise.py tools/patch_d13_dyld_witness.py \
         tools/patch_d13_abt_entry_probe.py tools/patch_d13_reader_probe.py tools/patch_d13_writer_probe.py \
         tools/patch_d13_caller_probe.py tools/patch_d13_eval_frame.py $PCC_PATCHER $PATCHER; do
  _stage "$p"
done
[[ $(grep -c 'xnu_live_evf_pc=' "$TRAP_SRC") == 1 ]] || { echo "FAIL: $TRAP_SRC does not carry EXACTLY 1 xnu_live_evf_pc= row - a partial or double edit"; exit 1; }
[[ $(grep -c '^#endif /\* STAGE90_XNU_EVAL_FRAME \*/' "$TRAP_SRC") == 1 ]] || { echo "FAIL: $TRAP_SRC does not carry EXACTLY 1 \`#endif /* STAGE90_XNU_EVAL_FRAME */\` - the ON/OFF gate is not bracketed"; exit 1; }
[[ $(grep -c 'xnu_live_pcc_pc=' "$TRAP_SRC") == 1 ]] || { echo "FAIL: $TRAP_SRC does not carry EXACTLY 1 xnu_live_pcc_pc= row - 1035's block is partial or doubled"; exit 1; }
[[ $(grep -c '^#endif /\* STAGE90_XNU_PC_CARRIER \*/' "$TRAP_SRC") == 1 ]] || { echo "FAIL: $TRAP_SRC does not carry EXACTLY 1 \`#endif /* STAGE90_XNU_PC_CARRIER */\` - 1035's ON/OFF gate is not bracketed"; exit 1; }
# C1's confirming conjunct: BOTH lr words, exactly once each (a partial edit that prints only one cannot
# state C1, and the build must not ship an image whose own cell it cannot print).
[[ $(grep -c 'xnu_live_pcc2_seq=' "$TRAP_SRC") == 1 ]] || { echo "FAIL: $TRAP_SRC does not carry EXACTLY 1 xnu_live_pcc2_seq= row - a partial or double edit"; exit 1; }
for _r in lr_m4= lr_m4_ok= lr_m8= lr_m8_ok= tbl_used= tbl_used_ok=; do
  [[ $(grep -c "xnu_live_pcc2_$_r" "$TRAP_SRC") == 1 ]] || { echo "FAIL: $TRAP_SRC does not carry EXACTLY 1 xnu_live_pcc2_$_r row - C1/C2's confirming conjunct is absent or doubled"; exit 1; }
done
[[ $(grep -c '^#endif /\* STAGE90_XNU_PC_CARRIER_CALLER \*/' "$TRAP_SRC") == 1 ]] || { echo "FAIL: $TRAP_SRC does not carry EXACTLY 1 \`#endif /* STAGE90_XNU_PC_CARRIER_CALLER */\` - the ON/OFF gate is not bracketed"; exit 1; }
_evf=$(grep -n '^#endif /\* STAGE90_XNU_EVAL_FRAME \*/' "$TRAP_SRC" | cut -d: -f1)
_cal=$(grep -n '^#endif /\* STAGE90_XNU_CALLER_PROBE \*/' "$TRAP_SRC" | head -1 | cut -d: -f1)
_pcc=$(grep -n '^#endif /\* STAGE90_XNU_PC_CARRIER \*/' "$TRAP_SRC" | head -1 | cut -d: -f1)
_pc2=$(grep -n '^#endif /\* STAGE90_XNU_PC_CARRIER_CALLER \*/' "$TRAP_SRC" | head -1 | cut -d: -f1)
_ust=$(grep -n '^#endif /\* STAGE90_XNU_USTACK_PROBE \*/' "$TRAP_SRC" | head -1 | cut -d: -f1)
[[ -n $_cal && -n $_evf && -n $_pcc && -n $_pc2 && -n $_ust && $_cal -lt $_evf && $_evf -lt $_pcc && $_pcc -lt $_pc2 && $_pc2 -lt $_ust ]] || { echo "FAIL: the trap.c gate nesting is wrong (caller #endif=$_cal < evf=$_evf < pcc=$_pcc < pcc2=$_pc2 < ustack=$_ust). Every block's rows must sit INSIDE 1025's publisher, and in rung order"; exit 1; }
echo "   staged: caller($_cal) < evf($_evf) < pcc($_pcc) < pcc2($_pc2) < ustack($_ust); 1036's block is last and inside 1025's gate; kern_exec.c untouched by 1036"

# ====================================================================================================
# 2. EXPORT THE POOL SWITCHES (the record's set verbatim + 1035's + THIS rung's), BEFORE THE POOL BUILD.
# ====================================================================================================
echo "-- 2. export the pool switch set (the record's, verbatim) + $PCC=1 + $NEW=1 --"
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
EXPORTS+=("$PCC=1")
EXPORTS+=("$NEW=1")
echo "   carrying $(( ${#EXPORTS[@]} - 4 )) switch(es) from $REC + $PCC=1 + $NEW=1"

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
    STAGE90_XNU_WRITER_PROBE|STAGE90_XNU_CALLER_PROBE|STAGE90_XNU_EVAL_FRAME|\
    STAGE90_XNU_PC_CARRIER|STAGE90_XNU_PC_CARRIER_CALLER) continue ;;
  esac
  [[ $k == STAGE90_* ]] || continue
  case $v in 0|1|0x*|[0-9]*) ;; *) continue ;; esac
  EXTRA="$EXTRA -D$k=$v"
done < "$REC"
EXTRA="${EXTRA# } -DSTAGE90_XNU_GLOBAL_FIX=1"
echo "-- extra defines: $EXTRA --"
[[ "$EXTRA" == *"-DSTAGE90_XNU_GLOBAL_FIX=1"* ]] || { echo "FAIL: -DSTAGE90_XNU_GLOBAL_FIX=1 is NOT in EXTRA - 1015b's fix has NO record carrier; without it the retry storm returns"; exit 1; }
for _g in VM_MAX_SPLIT USTACK_PROBE ABT_ENTRY_PROBE H2_STACK_HEADROOM READER_PROBE WRITER_PROBE CALLER_PROBE EVAL_FRAME PC_CARRIER PC_CARRIER_CALLER; do
  [[ "$EXTRA" != *"-DSTAGE90_XNU_$_g"* ]] || { echo "FAIL: -DSTAGE90_XNU_$_g is in EXTRA -- its channel is the global DEFINES array (env export), not XNU_KERNEL_EXTRA_DEFINES"; exit 1; }
done

# Every switch whose channel is the global DEFINES array is exported here.  1035's file had EVAL_FRAME in
# its EXTRA skip list but NOT in this loop (the pool compiled without xnu_live_evf_*; step 4 refused); the
# two lists below are now the same set, spelled once, so a switch cannot be in one and not the other
# ([[mi4-one-value-two-definitions]]).
_GLOBAL=${_GLOBAL_DEFINES_SWITCHES:-VM_MAX_SPLIT USTACK_PROBE ABT_ENTRY_PROBE H2_STACK_HEADROOM READER_PROBE WRITER_PROBE CALLER_PROBE EVAL_FRAME PC_CARRIER PC_CARRIER_CALLER}
for _g in $_GLOBAL; do
  export "STAGE90_XNU_$_g=1"
  grep -q "DEFINES+=(-DSTAGE90_XNU_$_g=1)" tools/build_xnu_arm_kernel.sh || { echo "FAIL: $_g was exported but tools/build_xnu_arm_kernel.sh has no reader for it"; exit 1; }
done
[[ $_GLOBAL == *PC_CARRIER\ PC_CARRIER_CALLER* ]] || { echo "FAIL: the global-DEFINES list [$_GLOBAL] does not end PC_CARRIER PC_CARRIER_CALLER"; exit 1; }
# **1021d's FLAG switch**: build_xnu_arm_kernel.sh reads STAGE90_XNU_GENERAL_REGS into its FP_FLAGS; a
# COMPILER FLAG, not a -D.  Read it back from the record, verified (1031's lesson).
[[ $(awk -F= '$1=="STAGE90_XNU_GENERAL_REGS"{print $2}' "$REC") == 1 ]] || { echo "FAIL: $REC does not record STAGE90_XNU_GENERAL_REGS=1"; exit 1; }
export STAGE90_XNU_GENERAL_REGS=1
# **989's GENERIC switch**: the ASM layer reads STAGE90_XNU_SP_ALIGN from the env too (989 died on this).
[[ $(awk -F= '$1=="STAGE90_XNU_SP_ALIGN"{print $2}' "$REC") == 1 ]] || { echo "FAIL: $REC does not record STAGE90_XNU_SP_ALIGN=1"; exit 1; }
export STAGE90_XNU_SP_ALIGN=1
# **EVERY SWITCH THE ASM LAYER READS FROM THE ENV** (tools/assemble_arm_layer.sh).  [[mi4-off-option-two-
# spellings]]: a switch the .s layer reads as `${STAGE90_XNU_X:-0}` is a SECOND spelling -- the pool built
# with it and the asm layer at 0.  DERIVED, not hand-copied (a hand list dropped USVC=1).
_asm_keys=$(grep -oE '^[A-Z0-9_]+=\$\{STAGE90_XNU_[A-Z0-9_]+:-' tools/assemble_arm_layer.sh | sed -E 's/.*STAGE90_XNU_([A-Z0-9_]+):-/\1/' | sort -u)
[[ $(grep -c . <<<"$_asm_keys") -ge 5 ]] || { echo "FAIL: the asm layer's env-switch list came out as [$_asm_keys] - the derivation regex no longer matches assemble_arm_layer.sh"; exit 1; }
_asmset=""
for _k in $_asm_keys; do
  case $_k in IDLE_STACK_SIZE) continue ;; esac       # a SIZE, not a 0/1 switch
  case $_k in IDLE_STACK) _asmset+=" [STAGE90_XNU_IDLE_STACK (record 1; D13 cswitch.s has no Idle_context - asm layer's tree default applies)]"; continue ;; esac
  _v=$(awk -F= -v k="STAGE90_XNU_$_k" '$1==k{print $2}' "$REC")
  if [[ -z $_v ]]; then
    _asmset+=" [STAGE90_XNU_$_k (not in record; asm layer's tree default)]"; continue
  fi
  export "STAGE90_XNU_$_k=$_v"
done
echo "   exported the ASM layer's env switches, from the record:$_asmset"
export STAGE90_XNU_HFS_ROOT_RW=$(awk -F= '$1=="STAGE90_XNU_HFS_ROOT_RW"{print $2}' "$REC")
# **THE HFS PORT ITSELF** (1031 line 307; 1029 line 266): build_xnu_arm_kernel.sh emits the HFS sources only
# when the PORT is on (`HFS_PORT=${STAGE90_XNU_HFS:-0}`); without it the entry link refused LATE (1033).
[[ $(awk -F= '$1=="STAGE90_XNU_HFS_ROOT_RW"{print $2}' "$REC") == 1 ]] || { echo "FAIL: $REC does not record STAGE90_XNU_HFS_ROOT_RW=1 - the HFS port export below is only right for the rw arm"; exit 1; }
export STAGE90_XNU_HFS=1
echo "-- STAGE90_XNU_HFS=1 STAGE90_XNU_HFS_ROOT_RW=$STAGE90_XNU_HFS_ROOT_RW (the pool's hfs_vfsops.o carries the rw clear; the entry link reads it back) --"
echo "   exported STAGE90_XNU_{${_GLOBAL// /,}}=1 (channel: global DEFINES; each reader verified above)"

# ====================================================================================================
# 3. BUILD: asm layer (untouched by 1036), pool, entry link, payload.
# ====================================================================================================
echo "-- 3. arm asm layer (1036 touches NO .s file) --"
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
  grep -qa "^$s" <(strings "$TRAP_OBJ") || { echo "FAIL: $TRAP_OBJ carries NO $s row - the pool was NOT recompiled with ${PCC}=1/$NEW=1 (env channel) or the trap.c edit is not staged"; exit 1; }
done
# 1035's own rows must survive (the pcc2 rows are read BESIDE them).
for s in xnu_live_pcc_pc= xnu_live_pcc_xor_walk= xnu_live_pcc_xor_table= xnu_live_pcc_near2= xnu_live_pcc_near2_ok=; do
  grep -qa "^$s" <(strings "$TRAP_OBJ") || { echo "FAIL: $TRAP_OBJ lost 1035's $s row - the pool rebuild dropped the pcc block"; exit 1; }
done
# 1036's own rows: the two C1/C2 conjunct families must be IN the pool object, or refuse to link.
for s in xnu_live_pcc2_seq= xnu_live_pcc2_lr_m4_ok= xnu_live_pcc2_lr_m8_ok= xnu_live_pcc2_tbl_used=; do
  grep -qa "^$s" <(strings "$TRAP_OBJ") || { echo "FAIL: $TRAP_OBJ carries NO $s row - the pool was NOT recompiled with $NEW=1 (env channel) or the trap.c edit is not staged. Without it the press captures nothing and 1036 reads NO READING for a build-side reason"; exit 1; }
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
echo "   4 PASS: trap.o carries all 8 evf rows, 1035's pcc rows, the pcc2 seq/lr_m4_ok/lr_m8_ok/tbl_used rows and the 5 parent row families; the pool's source record names the staged trap.c's sha256"

# ====================================================================================================
# 5. THE ENTRY LINK AND THE LINKED-IMAGE CLAUSES.
# ====================================================================================================
echo "-- 5. entry link --"
( cd src/entry && env -i PATH="$PATH" HOME="$HOME" "${EXPORTS[@]}" ./build_entry.sh )
ELF=$LIVE/xnu_arm_entry.elf
for s in xnu_live_pcc2_seq= xnu_live_pcc2_lr_m4_ok= xnu_live_pcc2_tbl_used= \
         xnu_live_pcc_pc= xnu_live_evf_pc= xnu_live_evf_far_raw= xnu_live_cal_region_end= \
         xnu_live_wrp_r4= xnu_live_abt_lookup_far= xnu_live_abt_vmfkrv=; do
  grep -qa "^$s" <(strings "$ELF") || { echo "FAIL: the LINKED image carries NO $s - the linker dropped an object the press reads"; exit 1; }
done
python3 tools/check_vm_max_split.py "$ELF" --expect on >/dev/null || { echo "FAIL: the LINKED image's task map ceiling moved (1024)"; exit 1; }
python3 tools/check_1023_trap24.py "$ELF" --expect on >/dev/null || { echo "FAIL: the LINKED image's mach_trap_table[24] moved (1023)"; exit 1; }
echo "   5 PASS: the linked image carries the pcc2, pcc, evf rows AND the 1031/1030/1027/1025 parents; 1024's ceiling and 1023's row 24 intact"

# ====================================================================================================
# 6. THE PAYLOAD, then 1032's CARD (the rung 1036 instruments must be ON the device).
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

printf 'STAGE90_XNU_GLOBAL_FIX=1 role=1036-pc-carrier\n' > "$LIVE/xnu_arm_entry-arm-extra.txt"
echo "== result =="
printf 'entry bin sha (first 8): '
sha256sum "$LIVE/xnu_arm_entry.bin" | cut -c1-8
echo "-- what the record carries --"
grep -E '(PC_CARRIER|EVAL_FRAME|CALLER|WRITER|READER)_PROBE' "$REC" || true
echo "== 1036 build DONE (1035 + $NEW, instrument only). Not pressed."
echo "   Park it (scripts/park_1036.sh), then press (scripts/press_1036.sh); the press is read by tools/check_1036_capture.py."