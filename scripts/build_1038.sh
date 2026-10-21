#!/bin/bash
# 1038 -- THE FOREIGN CODE ON THE STACK (arm A) AND LITTLE ENDIAN AT THE TABLE (arm B).  INSTRUMENT ONLY.
#
# WHAT 1036 READ (records/1037-read.txt A-C): s3 == 0xffffffff sits at sp+0xc; the only rule that puts the
# file's bytes at 0x5d3bd7 under it is a one-byte-skewed copy; the walk ran with r1 = 0 (the `mov r0,r0`
# at file 0x140) and the ldrb faulted at 0x10.  docs/1038-design.md asks WHO WROTE THE STACK (A) and whether
# the table's word view and byte view DIFFER on the same four bytes (B).
#
# WHAT 1038 IS.  ONE switch STAGE90_XNU_WATCH_LE=1 and ONE patcher (tools/patch_d13_watch_le.py, another
# lane's file; this script only READ-calls it) that inserts, inside 1025's failure arm immediately after
# 1037's `#endif /* STAGE90_XNU_TRAP_FRAME */`, the A/B block (xnu_live_sweq_* / xnu_live_ler_* rows plus the
# xnu_live_wlg_* gates), and a hook at the top of sleh_abort (`thread = current_thread();`).  The design's
# per-block switches (STACK_WATCH / LE_READ / CACHE_HEAD) are NOT created; there is no C cell in this rung.
#
# STAGING ORDER ([[mi4-one-file-many-rungs]]): every earlier rung is RE-STAGED from the top each build;
# EVERY other TRAP patcher's TRAP_ALLOWED_IF_IDENTIFIERS must carry STAGE90_XNU_WATCH_LE or it refuses
# the composed tree at the step-1 acceptance sweep.
#
# THE KERNEL IS REBUILT (TRAP is a POOL object), so THE ARM NAME MOVES: armed-d13-<sha8 of the whole pack>
# (scripts/park_1038.sh names a set by every member's sha, not the entry bin's -- a rebuild at the same bin
# gets a new name).
#
# THE PAYLOAD REBUILD (step 6, scripts/build.sh with a NEW out/stage90/xnu_arm_entry.bin) MUST carry:
#     XNU_TREE=external/xnu-hd2-darwin13/xnu
#     STAGE90_EXTRA_CFLAGS = <the switches of THIS arm's record, out/stage90/xnu_arm_entry-config.txt>
#                            + -DSTAGE90_XNU_ENTRY=1
# Without -DSTAGE90_XNU_ENTRY=1 the runner REFUSES the entry image (at zero cost - the device is never
# reached).  Without the record's switches the payload is built for a different arm than the kernel in it.
#
# fastboot boot only, NEVER flash.  Builds host-side files; touches no device.
set -euo pipefail
cd "$(dirname "$0")/.."

XNU_TREE=${XNU_TREE:-$PWD/external/xnu-hd2-darwin13/xnu}
LIVE=out/stage90
REC=$LIVE/xnu_arm_entry-config.txt
POOL=out/xnu_kernel_obj_d13
TRAP_OBJ=$POOL/osfmk_arm_trap.o
EXEC_OBJ=$POOL/bsd_kern_kern_exec.o
TRAP_SRC=$XNU_TREE/osfmk/arm/TRAP
NEW=STAGE90_XNU_WATCH_LE
PATCHER=tools/patch_d13_watch_le.py
CHECKER=tools/check_1038_capture.py
PCC=STAGE90_XNU_PC_CARRIER
PC2=STAGE90_XNU_PC_CARRIER_CALLER
TF=STAGE90_XNU_TRAP_FRAME
# the TRAP patchers whose ALLOWED set must carry $NEW (the acceptance sweep below runs each on the tree)
TRAP_PATCHERS="tools/patch_d13_ustack_probe.py tools/patch_d13_undef_raise.py tools/patch_d13_dyld_witness.py
 tools/patch_d13_abt_entry_probe.py tools/patch_d13_reader_probe.py tools/patch_d13_writer_probe.py
 tools/patch_d13_caller_probe.py tools/patch_d13_eval_frame.py tools/patch_d13_pc_carrier.py
 tools/patch_d13_pc_carrier_caller.py tools/patch_d13_trap_frame.py"

echo "== 1038: THE STACK WATCH + THE LE TABLE ($NEW=1; instrument only) =="
[[ -f $PATCHER ]] || { echo "REFUSING: $PATCHER is absent - it is the whole edit"; exit 1; }
[[ -f $CHECKER ]] || { echo "REFUSING: $CHECKER is absent - the press would have no reader"; exit 1; }
# THE CHANNEL ([[mi4-build-variant-comes-from-an-env-default]]): a switch with no `DEFINES+=(-D...)` reader
# in the pool builder reaches nothing and step 4 refuses AFTER the object compile.  Refuse BEFORE it.
for _n in $PCC $PC2 $TF $NEW; do
  grep -q "DEFINES+=(-D$_n=1)" tools/build_xnu_arm_kernel.sh || { echo "REFUSING: tools/build_xnu_arm_kernel.sh carries no DEFINES+=(-D$_n=1) line - the export in step 2 would reach nothing and the pool would keep the un-instrumented TRAP. Add the reader to its global DEFINES array first (it is another lane's edit)"; exit 1; }
done
# THE SHARED NAMESPACE ([[mi4-one-file-many-rungs]]): each other TRAP patcher must already know $NEW.
for _p in $TRAP_PATCHERS; do
  [[ -f $_p ]] || { echo "REFUSING: $_p is absent - the TRAP chain is incomplete"; exit 1; }
  grep -q "\"$NEW\"" "$_p" || { echo "REFUSING: $_p does not list \"$NEW\" in TRAP_ALLOWED_IF_IDENTIFIERS - it would refuse the 1038-composed tree at the step-1 acceptance sweep ([[mi4-one-file-many-rungs]]). Another lane's edit; not made here"; exit 1; }
done
echo "   channel: $NEW has a DEFINES reader; all 11 other TRAP patchers allow $NEW"

# ====================================================================================================
# 0. THE RECORD MUST BE THE 1037 LINEAGE THE sweq/ler ROWS ARE READ BESIDE.
# ====================================================================================================
echo "-- 0. the record carries the 1037/1036/1035/1033/1025 chain (the parent rows must still publish) --"
[[ -r $REC ]] || { echo "REFUSING: no arm record at $REC -- build 1037 first"; exit 1; }
for k in $TF $PC2 $PCC STAGE90_XNU_EVAL_FRAME \
         STAGE90_XNU_CALLER_PROBE STAGE90_XNU_WRITER_PROBE STAGE90_XNU_READER_PROBE \
         STAGE90_XNU_ABT_ENTRY_PROBE STAGE90_XNU_USTACK_PROBE STAGE90_XNU_H2_STACK_HEADROOM \
         STAGE90_XNU_VM_MAX_SPLIT STAGE90_XNU_IOS7_TRAPS STAGE90_XNU_GENERAL_REGS \
         STAGE90_XNU_UNDEF_RAISE; do
  grep -q "^$k=1\$" "$REC" || { echo "REFUSING: $REC does not carry $k=1 - this is not the 1037 arm 1038 instruments. Build 1037 first (or, if 1037 was retired in favour of 1038, record that decision first)"; exit 1; }
done
echo "   the record carries the whole inherited chain (13 switches + $TF)"
for _f in src/entry/build_entry.sh scripts/preflight_boot_check.sh; do
  [[ -f $_f ]] || { echo "REFUSING: $_f is absent"; exit 1; }
done
grep -qE "^[[:space:]]*$NEW\)?$" src/entry/build_entry.sh || { echo "REFUSING: src/entry/build_entry.sh does not list $NEW in ENTRY_ARM_KEYS - the record would omit it and park_1038.sh would refuse the arm after the compile. (Registration is another lane's edit; build only READS these files.)"; exit 1; }
grep -qE "^[[:space:]]*$NEW\)$" scripts/preflight_boot_check.sh || { echo "REFUSING: scripts/preflight_boot_check.sh does not list $NEW in its gate key list - the next press would refuse the record the build just wrote. (Registration is another lane's edit.)"; exit 1; }
grep -qE "^[[:space:]]*$NEW\)[[:space:]]+_v=" src/entry/build_entry.sh || { echo "REFUSING: src/entry/build_entry.sh has no case arm for $NEW - the key would be read back empty. (Registration is another lane's edit.)"; exit 1; }
grep -q "echo \"$NEW=" src/entry/build_entry.sh || { echo "REFUSING: src/entry/build_entry.sh does not ECHO $NEW into the record - the arm would be recorded for a switch this image never compiled. (Registration is another lane's edit.)"; exit 1; }
echo "   the entry layer lists, reads and ECHOES $NEW (the record can carry it)"

# **IDEMPOTENT RE-ENTRY** (the record is shared live state): a half-staged value is a foreign arm - refuse.
if grep -q "^$NEW=" "$REC" && ! grep -q "^$NEW=1\$" "$REC"; then
  echo "REFUSING: $REC carries $NEW with a value other than 1 - a stale/foreign arm"; exit 1; fi
grep -q "^$NEW=1\$" "$REC" && echo "   note: $REC already carries $NEW=1 (this build's own prior trace); re-entering idempotently"

# ====================================================================================================
# 1. STAGE THE TREE EDITS -- the whole TRAP chain through 1037, then 1038's block LAST.
# ====================================================================================================
echo "-- 1. stage the tree edits (1025->1033, 1035's pc carrier, 1036's caller, 1037's trap frame, then 1038) --"
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
# 1020's udf-raise fix and 994's dyld witness edit the SAME TRAP; re-stage, never `git checkout --`.
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
# ---- 1033: THE EVAL FRAME
_stage tools/patch_d13_eval_frame.py
_stage tools/patch_d13_eval_frame.py --apply
_stage tools/patch_d13_eval_frame.py --apply
_stage tools/patch_d13_eval_frame.py --verify-off
# ---- 1035: THE PC CARRIER
export $PCC=1
_stage tools/patch_d13_pc_carrier.py
_stage tools/patch_d13_pc_carrier.py --apply
_stage tools/patch_d13_pc_carrier.py --apply
_stage tools/patch_d13_pc_carrier.py --verify-off
# ---- 1036: THE CALLER
export "$PC2=1"
_stage tools/patch_d13_pc_carrier_caller.py
_stage tools/patch_d13_pc_carrier_caller.py --apply
_stage tools/patch_d13_pc_carrier_caller.py --apply
_stage tools/patch_d13_pc_carrier_caller.py --verify-off
# ---- 1037: THE TRAP FRAME (1038's block is anchored on ITS #endif)
export "$TF=1"
_stage tools/patch_d13_trap_frame.py
_stage tools/patch_d13_trap_frame.py --apply
_stage tools/patch_d13_trap_frame.py --apply
_stage tools/patch_d13_trap_frame.py --verify-off
# ---- 1038: WATCH_LE (the A/B block inside 1025's failure arm after 1037; the hook at sleh_abort)
echo "-- $PATCHER (1038: TRAP xnu_live_sweq_* / xnu_live_ler_* rows + the sleh_abort hook) --"
export "$NEW=1"
_stage $PATCHER
_stage $PATCHER --apply
_stage $PATCHER --apply          # second apply = the idempotent no-op
_stage $PATCHER --verify-off
# The composed tree: every other TRAP patcher must still ACCEPT it (the shared namespace in effect).
for p in $TRAP_PATCHERS $PATCHER; do
  _stage "$p"
done
[[ $(grep -c 'xnu_live_fb_seq=' "$TRAP_SRC") == 1 ]] || { echo "FAIL: $TRAP_SRC does not carry EXACTLY 1 xnu_live_fb_seq= row - 1037's block is partial or doubled"; exit 1; }
[[ $(grep -c '^#endif /\* STAGE90_XNU_TRAP_FRAME \*/' "$TRAP_SRC") == 1 ]] || { echo "FAIL: $TRAP_SRC does not carry EXACTLY 1 \`#endif /* STAGE90_XNU_TRAP_FRAME */\`"; exit 1; }
[[ $(grep -c 'xnu_live_pcc2_seq=' "$TRAP_SRC") == 1 ]] || { echo "FAIL: $TRAP_SRC does not carry EXACTLY 1 xnu_live_pcc2_seq= row"; exit 1; }
[[ $(grep -c 'xnu_live_evf_pc=' "$TRAP_SRC") == 1 ]] || { echo "FAIL: $TRAP_SRC does not carry EXACTLY 1 xnu_live_evf_pc= row"; exit 1; }
[[ $(grep -c '^#endif /\* STAGE90_XNU_WATCH_LE \*/' "$TRAP_SRC") == 1 ]] || { echo "FAIL: $TRAP_SRC does not carry EXACTLY 1 \`#endif /* STAGE90_XNU_WATCH_LE */\` - the ON/OFF gate is not bracketed"; exit 1; }
[[ $(grep -c 'xnu_live_sweq_seq=' "$TRAP_SRC") == 1 ]] || { echo "FAIL: $TRAP_SRC does not carry EXACTLY 1 xnu_live_sweq_seq= row - a partial or double edit"; exit 1; }
# the rows THE READER reads must each be emitted (the checker's emitter test is the one spelling, and it
# knows the patcher's per-name GENERATOR rows that a plain grep cannot see;
# [[mi4-one-value-two-definitions]]: do not copy the list into this script).
python3 -I "$CHECKER" --emitter-missing "$PATCHER" || { echo "FAIL: $PATCHER does not emit every row the reader needs (listed above) - the image could not fill a cell it pre-registers"; exit 1; }
for s in $(python3 -I "$CHECKER" --required-rows); do
  [[ $(grep -c "$s=" "$TRAP_SRC") -ge 1 ]] || { echo "FAIL: $TRAP_SRC does not carry the reader's required row $s= - the staged tree lost a row the patcher emits"; exit 1; }
done
# record (do NOT gate) another lane's companion rows: the reader reports their presence, no 1038 cell uses them.
_miss_co=""
for s in $(python3 -I "$CHECKER" --companion-rows); do
  grep -q "$s=" "$TRAP_SRC" || _miss_co+=" $s"
done
[[ -z $_miss_co ]] || echo "   note: companion rows (STAGE90_XNU_USTACK_VALIDATE, another lane) NOT staged:$_miss_co - the reader will say so and use none of them"
_fb=$(grep -n '^#endif /\* STAGE90_XNU_TRAP_FRAME \*/' "$TRAP_SRC" | head -1 | cut -d: -f1)
_wl=$(grep -n '^#endif /\* STAGE90_XNU_WATCH_LE \*/' "$TRAP_SRC" | head -1 | cut -d: -f1)
_ust=$(grep -n '^#endif /\* STAGE90_XNU_USTACK_PROBE \*/' "$TRAP_SRC" | head -1 | cut -d: -f1)
[[ -n $_fb && -n $_wl && -n $_ust && $_fb -lt $_wl && $_wl -lt $_ust ]] || { echo "FAIL: the TRAP gate nesting is wrong (trap_frame #endif=$_fb < watch_le #endif=$_wl < ustack #endif=$_ust). 1038's block must sit INSIDE 1025's publisher and AFTER 1037's"; exit 1; }
echo "   staged: trap_frame($_fb) < watch_le($_wl) < ustack($_ust); 1038's block is last and inside 1025's gate"

# ====================================================================================================
# 2. EXPORT THE POOL SWITCHES (the record's set verbatim + THIS rung's), BEFORE THE POOL BUILD.
# ====================================================================================================
echo "-- 2. export the pool switch set (the record's, verbatim) + $PCC=1 + $PC2=1 + $TF=1 + $NEW=1 --"
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
EXPORTS+=("$PCC=1" "$PC2=1" "$TF=1" "$NEW=1")
echo "   carrying $(( ${#EXPORTS[@]} - 5 )) switch(es) from $REC + $PCC=1 + $PC2=1 + $TF=1 + $NEW=1"

# The -D set: everything the record names EXCEPT the switches whose channel is the global DEFINES array or
# a FLAG, plus 1015b's token which has NO record carrier (records/1020-build-defect.txt).
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
    STAGE90_XNU_PC_CARRIER|STAGE90_XNU_PC_CARRIER_CALLER|STAGE90_XNU_TRAP_FRAME|STAGE90_XNU_WATCH_LE) continue ;;
  esac
  [[ $k == STAGE90_* ]] || continue
  case $v in 0|1|0x*|[0-9]*) ;; *) continue ;; esac
  EXTRA="$EXTRA -D$k=$v"
done < "$REC"
EXTRA="${EXTRA# } -DSTAGE90_XNU_GLOBAL_FIX=1"
echo "-- extra defines: $EXTRA --"
[[ "$EXTRA" == *"-DSTAGE90_XNU_GLOBAL_FIX=1"* ]] || { echo "FAIL: -DSTAGE90_XNU_GLOBAL_FIX=1 is NOT in EXTRA - 1015b's fix has NO record carrier; without it the retry storm returns"; exit 1; }
for _g in VM_MAX_SPLIT USTACK_PROBE ABT_ENTRY_PROBE H2_STACK_HEADROOM READER_PROBE WRITER_PROBE CALLER_PROBE EVAL_FRAME PC_CARRIER PC_CARRIER_CALLER TRAP_FRAME WATCH_LE; do
  [[ "$EXTRA" != *"-DSTAGE90_XNU_$_g"* ]] || { echo "FAIL: -DSTAGE90_XNU_$_g is in EXTRA -- its channel is the global DEFINES array (env export), not XNU_KERNEL_EXTRA_DEFINES"; exit 1; }
done
# Every switch whose channel is the global DEFINES array is exported here; the skip list above and this
# loop are the same set spelled twice on purpose (the check below holds them equal).
_GLOBAL=${_GLOBAL_DEFINES_SWITCHES:-VM_MAX_SPLIT USTACK_PROBE ABT_ENTRY_PROBE H2_STACK_HEADROOM READER_PROBE WRITER_PROBE CALLER_PROBE EVAL_FRAME PC_CARRIER PC_CARRIER_CALLER TRAP_FRAME WATCH_LE}
for _g in $_GLOBAL; do
  export "STAGE90_XNU_$_g=1"
  grep -q "DEFINES+=(-DSTAGE90_XNU_$_g=1)" tools/build_xnu_arm_kernel.sh || { echo "FAIL: $_g was exported but tools/build_xnu_arm_kernel.sh has no reader for it"; exit 1; }
done
[[ $_GLOBAL == *PC_CARRIER\ PC_CARRIER_CALLER\ TRAP_FRAME\ WATCH_LE ]] || { echo "FAIL: the global-DEFINES list [$_GLOBAL] does not end PC_CARRIER PC_CARRIER_CALLER TRAP_FRAME WATCH_LE"; exit 1; }
# **1021d's FLAG switch** and **989's assembly-layer switch**: read back from the record, verified.
[[ $(awk -F= '$1=="STAGE90_XNU_GENERAL_REGS"{print $2}' "$REC") == 1 ]] || { echo "FAIL: $REC does not record STAGE90_XNU_GENERAL_REGS=1"; exit 1; }
export STAGE90_XNU_GENERAL_REGS=1
[[ $(awk -F= '$1=="STAGE90_XNU_SP_ALIGN"{print $2}' "$REC") == 1 ]] || { echo "FAIL: $REC does not record STAGE90_XNU_SP_ALIGN=1"; exit 1; }
export STAGE90_XNU_SP_ALIGN=1
# **EVERY SWITCH THE ASM LAYER READS FROM THE ENV** (tools/assemble_arm_layer.sh), DERIVED not hand-copied.
_asm_keys=$(grep -oE '^[A-Z0-9_]+=\$\{STAGE90_XNU_[A-Z0-9_]+:-' tools/assemble_arm_layer.sh | sed -E 's/.*STAGE90_XNU_([A-Z0-9_]+):-/\1/' | sort -u)
[[ $(grep -c . <<<"$_asm_keys") -ge 5 ]] || { echo "FAIL: the asm layer's env-switch list came out as [$_asm_keys] - the derivation regex no longer matches assemble_arm_layer.sh"; exit 1; }
_asmset=""
for _k in $_asm_keys; do
  case $_k in IDLE_STACK_SIZE) continue ;; esac       # a SIZE, not a 0/1 switch
  case $_k in IDLE_STACK) _asmset+=" [STAGE90_XNU_IDLE_STACK (record 1; asm layer's tree default applies)]"; continue ;; esac
  _v=$(awk -F= -v k="STAGE90_XNU_$_k" '$1==k{print $2}' "$REC")
  if [[ -z $_v ]]; then
    _asmset+=" [STAGE90_XNU_$_k (not in record; asm layer's tree default)]"; continue
  fi
  export "STAGE90_XNU_$_k=$_v"
done
echo "   exported the ASM layer's env switches, from the record:$_asmset"
[[ $(awk -F= '$1=="STAGE90_XNU_HFS_ROOT_RW"{print $2}' "$REC") == 1 ]] || { echo "FAIL: $REC does not record STAGE90_XNU_HFS_ROOT_RW=1 - the HFS port export below is only right for the rw arm"; exit 1; }
export STAGE90_XNU_HFS_ROOT_RW=1
export STAGE90_XNU_HFS=1
echo "   exported STAGE90_XNU_{${_GLOBAL// /,}}=1 (channel: global DEFINES; each reader verified above)"

# ====================================================================================================
# 3. BUILD: asm layer (untouched by 1038), pool, entry link, payload.
# ====================================================================================================
echo "-- 3. arm asm layer (1038 touches NO .s file) --"
XNU_TREE="$XNU_TREE" XNU_KERNEL_CONFIG=STAGE90_XNU tools/assemble_arm_layer.sh
echo "-- the D13 kernel pool (trap.o moves; every other object rebuilds identically) --"
XNU_TREE="$XNU_TREE" XNU_KERNEL_CONFIG=STAGE90_XNU \
XNU_MASTER_LOCAL="$PWD/tools/xnu_config/boot/STAGE90_XNU.local" \
XNU_KERNEL_EXTRA_DEFINES="$EXTRA" \
    ./tools/build_xnu_arm_kernel.sh

# ====================================================================================================
# 4. THE OBJECT-SIDE ASSERTIONS (grep -qa P <(strings X), never `strings X | grep -q P` -- SIGPIPE 141).
#    The row list is THE READER'S (--required-rows): one spelling.
# ====================================================================================================
echo "-- 4. the pool objects --"
[[ -f $TRAP_OBJ && -f $EXEC_OBJ ]] || { echo "FAIL: pool objects absent"; exit 1; }
for s in $(python3 -I "$CHECKER" --required-rows); do
  grep -qa "^$s=" <(strings "$TRAP_OBJ") || { echo "FAIL: $TRAP_OBJ carries NO $s= row - the pool was NOT recompiled with $NEW=1 (env channel) or the TRAP edit is not staged. Without it the press captures nothing and 1038 reads NO READING for a build-side reason"; exit 1; }
done
for s in xnu_live_evf_pc= xnu_live_evf_far_raw= xnu_live_pcc_pc= xnu_live_pcc_xor_walk= xnu_live_pcc2_seq= \
         xnu_live_pcc2_lr_m4_ok= xnu_live_pcc2_tbl_used= xnu_live_fb_seq= xnu_live_fb_ctx_diff= \
         xnu_live_cal_region_end= xnu_live_wrp_r4= xnu_live_rdr_far= xnu_live_abt_lookup_far= xnu_live_abt_vmfkrv=; do
  grep -qa "^$s" <(strings "$TRAP_OBJ") || { echo "FAIL: $TRAP_OBJ lost $s - the pool rebuild dropped an inherited rung"; exit 1; }
done
grep -q "$NEW" "$TRAP_SRC" || { echo "FAIL: the staged TRAP carries no $NEW"; exit 1; }
_src_rec=out/xnu_kernel_src_d13.sha256
[[ -s $_src_rec ]] || { echo "FAIL: $_src_rec absent - the pool's source record cannot certify the rebuild"; exit 1; }
_tc_want=$(sha256sum "$TRAP_SRC" | awk '{print $1}')
_tc_have=$(awk -v p="$TRAP_SRC" '$2==p{print $1}' "$_src_rec" | head -1)
[[ -n $_tc_have && "$_tc_want" == "$_tc_have" ]] || { echo "FAIL: $_src_rec's TRAP hash (${_tc_have:-none}) != the staged file's ($_tc_want) - the pool was NOT rebuilt from the staged trap.c"; exit 1; }
echo "   4 PASS: trap.o carries the reader's $(python3 -I "$CHECKER" --required-rows | wc -l | tr -d ' ') required rows, 1037/1036/1035/1033 and the parent families; the source record names the staged TRAP's sha256"

# ====================================================================================================
# 5. THE ENTRY LINK AND THE LINKED-IMAGE CLAUSES.
# ====================================================================================================
echo "-- 5. entry link --"
( cd src/entry && env -i PATH="$PATH" HOME="$HOME" "${EXPORTS[@]}" ./build_entry.sh )
ELF=$LIVE/xnu_arm_entry.elf
for s in $(python3 -I "$CHECKER" --required-rows | sed 's/$/=/') xnu_live_fb_seq= xnu_live_pcc2_seq= xnu_live_pcc_pc= \
         xnu_live_evf_pc= xnu_live_cal_region_end= xnu_live_wrp_r4= xnu_live_abt_lookup_far= xnu_live_abt_vmfkrv=; do
  grep -qa "^$s" <(strings "$ELF") || { echo "FAIL: the LINKED image carries NO $s - the linker dropped an object the press reads"; exit 1; }
done
python3 tools/check_vm_max_split.py "$ELF" --expect on >/dev/null || { echo "FAIL: the LINKED image's task map ceiling moved (1024)"; exit 1; }
python3 tools/check_1023_trap24.py "$ELF" --expect on >/dev/null || { echo "FAIL: the LINKED image's mach_trap_table[24] moved (1023)"; exit 1; }
echo "   5 PASS: the linked image carries the sweq/ler/wlg rows AND the 1037/1036/1035/1033 parents; 1024's ceiling and 1023's row 24 intact"

# ====================================================================================================
# 6. THE PAYLOAD, then 1032's CARD (the rung 1038 instruments must be ON the device).
# ====================================================================================================
echo "-- 6. payload --"
# The arm's OWN switches + the entry switch ([[mi4-build-variant-comes-from-an-env-default]]: a payload
# built without the record's switches is a different arm than the kernel inside it).
_arm_sw=$(tr '\n' ' ' < "$REC")
echo "   payload switches: $REC ($(tr ' ' '\n' <<<"$_arm_sw" | grep -c '=1') =1, $(tr ' ' '\n' <<<"$_arm_sw" | grep -c '=0') =0)"
XNU_TREE="$XNU_TREE" STAGE90_EXTRA_CFLAGS="$_arm_sw -DSTAGE90_XNU_ENTRY=1" ./scripts/build.sh
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

# arm-extra.txt is the arm's extra role marker.  It is WRITTEN only when the payload step above (build.sh)
# actually ran: this script has NOT been run, and a write here would make out/stage90's extra file claim
# role=1038-watch-le on whatever arm currently sits there.  Uncomment when this build is run for real.
# printf 'STAGE90_XNU_GLOBAL_FIX=1 role=1038-watch-le\n' > "$LIVE/xnu_arm_entry-arm-extra.txt"
echo "== result =="
printf 'entry bin sha (first 8): '
sha256sum "$LIVE/xnu_arm_entry.bin" | cut -c1-8
echo "-- what the record carries --"
grep -E 'WATCH_LE|TRAP_FRAME|PC_CARRIER' "$REC" || true
echo "== 1038 build DONE (1037 + $NEW, instrument only). Not pressed."
echo "   Park it (scripts/park_1038.sh), then press (scripts/press_1038.sh); the press is read by $CHECKER."