#!/bin/bash
# 1039 -- THE FRAME CARRIER: is the user context the trap saved the one the hardware faulted with?
# INSTRUMENT ONLY.
#
# WHAT 1037 READ (records/1037-read.txt RUNG READING): the fb block's second witness did not exist
# (_uss_ok=0, every uss_r*_ok=0: arm_ctx is not a kernel VA, so fb_ctx_diff compared zeros with
# themselves); lr reads 0x37C1E9AF where file 0x37C1E9AE is `cmp r0,#0` after a `blx` (records/
# 1039-static-lr.txt, mechanisms only -- its byte decode was corrected 2026-10-19); r1 == 0 at the
# ldrb while the loop had just loaded a pointer; the run's own slide 0x86c000 puts pc off the file's
# walk page.  docs: records/1039-read.txt (pre-registration).
#
# WHAT 1039 IS.  THREE edits, all switches default OFF:
#   1. tools/patch_d13_frame_carrier.py, STAGE90_XNU_FRAME_CARRIER=1: one trap.c block inside 1025's
#      data-abort publisher after 1037's, reading thread->machine.uss THROUGH THE PORT'S POINTER (not
#      through arm_ctx), the TH_PCB_ISS words, the entry's saved spsr, thread->continuation, pc/lr
#      bit0, and the kernel's own boot epoch (so a capture can be proven newer than the press even
#      when the press log's epoch is lost).  Rows xnu_live_fcr_*.
#   2. tools/patch_d13_trap_frame.py (1037's body, RE-STAGED from the top): fb_ctx_diff against the
#      uss VA, not against itself (xnu_live_fb_uss_ptr_eq / _ctx_diff_self / _mask_kind), and fb_ldrh
#      selecting the halfword the Thumb pc points AT ((VA & 3) < 2, not (VA & 2)).
#   3. 1038's ROW side (STAGE90_XNU_WATCH_LE) rides along with its switch UNDEFINED: its arm is laid
#      out by tools/patch_d13_watch_le_rowside.py so it compiles OUT (no stray `#define`), and its rows
#      are a NEGATIVE reading -- their absence from the capture is expected, not unchecked.
#
# STAGING ORDER ([[mi4-one-file-many-rungs]]): every earlier rung is re-staged from the top; every
# other TRAP patcher's allowed-if set carries STAGE90_XNU_FRAME_CARRIER (--register verified).
#
# THE KERNEL IS REBUILT (TRAP is a POOL object): the arm name MOVES.  THE PAYLOAD REBUILD MUST carry
# XNU_TREE=external/xnu-hd2-darwin13/xnu and STAGE90_EXTRA_CFLAGS = <this arm's record switches>
# + -DSTAGE90_XNU_ENTRY=1.
#
# fastboot boot only, NEVER flash.  Builds host-side files; touches no device.
set -euo pipefail
cd "$(dirname "$0")/.."

SR="${SR:-$PWD}"; XNU_TREE=${XNU_TREE:-$PWD/external/xnu-hd2-darwin13/xnu}
LIVE=out/stage90
REC=$LIVE/xnu_arm_entry-config.txt
POOL=out/xnu_kernel_obj_d13
TRAP_OBJ=$POOL/osfmk_arm_trap.o
TRAP_SRC=$SR/external/xnu-hd2-darwin13/xnu/osfmk/arm/trap.c
TRAP_ARGV=${TRAP_ARGV:-out/1039-trap-argv.txt}
NEW=STAGE90_XNU_FRAME_CARRIER
CHECKER=tools/check_1039_capture.py
EXEC_OBJ=$POOL/bsd_kern_kern_exec.o
OTHER=STAGE90_XNU_WATCH_LE
TF=STAGE90_XNU_TRAP_FRAME
PATCHER=tools/patch_d13_frame_carrier.py
TF_PATCHER=tools/patch_d13_trap_frame.py
LE_PATCHER=tools/patch_d13_watch_le.py
RS_PATCHER=tools/patch_d13_watch_le_rowside.py

echo "== 1039: THE FRAME CARRIER ($NEW=1, $TF re-staged, $OTHER=0: 1038's row side inert; instrument only) =="
for _f in $PATCHER $TF_PATCHER $LE_PATCHER tools/patch_d13_plan.py; do
  [[ -f $_f ]] || { echo "REFUSING: $_f is absent - it is part of the edit"; exit 1; }
done
# THE CHANNEL: a switch with no DEFINES reader is an env default that reaches nothing.
for _n in $NEW $OTHER $TF; do
  grep -q "DEFINES+=(-D$_n=1)" tools/build_xnu_arm_kernel.sh || {
    echo "REFUSING: tools/build_xnu_arm_kernel.sh carries no DEFINES+=(-D$_n=1) reader"; exit 1; }
done
# THE CHANNEL MUST BE GATED (1039's own defect found before it could build): an UNGATED reader applies
# the switch to EVERY build.  tools/build_xnu_arm_kernel.sh line for $NEW must start with a test.
grep -qE "^\[\[ \\\$\{$NEW:-0\} -eq 1 \]\] && DEFINES\+=" tools/build_xnu_arm_kernel.sh || {
  echo "REFUSING: the $NEW reader is not gated on \${$NEW:-0} - every build would carry the block"; exit 1; }

# 1. THE PLAN'S AND THE OWNERS' SELFTESTS.  The trap.c text is composed by ONE record
#    (tools/patch_d13_plan.py) from the blocks each OWNER's patcher holds BY VALUE -- 1037's
#    TRAP_BLOCK, 1039's TRAP_BLOCK, and 1038's three include files (watch_le_*.inc).  The old
#    in-trap.c 1038 text (chunk markers, --restage, the rowside re-form) is GONE from the tree:
#    1038 lives in the .inc files, reached by an #include at file scope and one inside sleh_abort.
#    [[mi4-1039-plan-composer-preprocesses]], [[mi4-one-file-many-rungs]].
echo "-- 1. the owners' selftests + the plan's selftest --"
# (the PATCHERS' selftests judge their own fixtures, never the live tree -- the plan's --verify at
#  step 2 and the preprocessor at step 3 are what judge trap.c itself)
for _t in $PATCHER $TF_PATCHER $LE_PATCHER tools/patch_d13_plan.py; do
  python3 -I "$_t" --selftest 2>&1 | grep -E 'selftest .*(PASS|FAIL)|SELFTEST (PASS|FAIL)' | tail -1 \
    || { echo "FAIL: $_t --selftest"; exit 1; }
  python3 -I "$_t" --selftest >/dev/null 2>&1 || { echo "FAIL: $_t --selftest did not pass"; exit 1; }
done
python3 -I $LE_PATCHER --model-files "$XNU_TREE" >/dev/null 2>&1 \
  || { echo "FAIL: the rows loop's model (watch_le_*.inc) cannot be written"; exit 1; }
# (the check must be the one that WRITES: --verify-model printed PASS beside three 0-byte files --
# --model-files' REFUSE path returned a files tuple with no text, wrote nothing, and exited 0, and the
# verifier then called the empty files "the model's, byte for byte".  The writer's own status and a
# non-empty check are both required.  [[mi4-silence-is-a-reading-only-if-success-is-silent]])
python3 -I $LE_PATCHER --model-files "$XNU_TREE" >/dev/null 2>&1 \
  || { echo "FAIL: the rows loop's model (watch_le_*.inc) cannot be written"; exit 1; }
for _inc in watch_le_defs.inc watch_le_fwd.inc watch_le_arm.inc watch_le_hook.inc; do
  [[ -s $XNU_TREE/osfmk/arm/$_inc ]] || { echo "FAIL: $XNU_TREE/osfmk/arm/$_inc is EMPTY - the model wrote no text"; exit 1; }
done
python3 -I $LE_PATCHER --verify-model "$XNU_TREE" | tail -1 \
  || { echo "REFUSING: the include files on disk do not verify"; exit 1; }

# 2. THE TREE IS EITHER THE 1036 TREE OR ALREADY THIS RUNG'S COMPOSITE (the staging is IDEMPOTENT).
#    The plan INSERTS its seam in front of 1025's close and the hook at sleh_abort's preamble; a tree
#    that already carries the plan BYTE FOR BYTE is this rung's own and is re-staged over (the .inc
#    files the seam includes are rewritten by --model-files, which is why re-staging is the honest
#    move); anything else is refused by name -- never a silent re-compose of a foreign tree.
echo "-- 2. compose trap.c from the plan --"
_st=$(python3 -I - "$XNU_TREE" <<'PYST' || true
import importlib.util, os, sys
p = os.path.join("tools", "patch_d13_plan.py")
spec = importlib.util.spec_from_file_location("_plan", p); m = importlib.util.module_from_spec(spec)
sys.modules["_plan"] = m; spec.loader.exec_module(m)
xnu = sys.argv[1]; t = m.read(m.trap_path(xnu))
if m.verify(t, xnu) == []:
    # **`verify` passing IS the ready state.** The tree is exactly what this rung produces, so there is
    # nothing to fold out and compose again - and trying to made the fold refuse ("the seat carries 2
    # model row(s), expected 3"), because a staged tree's seat also holds 1038's rows. The build reads
    # this state the same way it reads `ready` below: verify what is there and go on.
    print("staged"); sys.exit(0)
# PRISTINE = the COMPOSER CAN PLACE its seam here.  (2026-10-20: a COMPOSED tree was classified by a
# str.strip()ed fold comparison; the 1037 body is TAB-indented, the stripped fold matched, nothing was
# folded, and the plan composed a SECOND seam -- trap.c carried it twice and step 6 caught the doubled
# row.  Ask the composer, never a look-alike of it.)
_at, _why = m.place(t, xnu)
if _at is None and "carries 1038's defs include" in str(_why):
    print("ready"); sys.exit(0)
if _at is None:
    # (2026-10-20: a tree that still carries the OLD composite -- 1037's switch present, the plan's
    # bytes changed under it -- refused here.  It is not pristine: compose() INSERTS and the tree
    # would come out with two 1037 blocks.  FOLD it if the plan recognises it; refuse otherwise.)
    if t.count("#if defined(STAGE90_XNU_TRAP_FRAME) && STAGE90_XNU_TRAP_FRAME") >= 1:
        _f, _fw = m.off(t, xnu)
        if _f is not None:
            print("old-composite"); sys.exit(0)
    print("composed-under-a-second-seam: " + _why); sys.exit(0)
print("pristine"); sys.exit(0)
PYST
)
echo "   trap.c is: ${_st:-unknown}"
case "${_st%%:*}" in
  staged)
    # **A tree whose text already verifies is READY: use it.** This branch used to fold the plan out
    # and compose it again, which refused on a fully staged tree ("the seat carries 2 model row(s),
    # expected 3") because a staged seat also holds 1038's rows - the fold's model is the 1036 one.
    # There is nothing to rebuild here: verify() has just certified the text against every one of the
    # plan's facts, so the edit is what this rung produces. (The old `ready)` arm below repeated this
    # for the case where place() refused on the defs include; that arm is now unreachable, which the
    # duplicate `staged|ready)` pattern made obvious - a later pattern never wins.)
    echo "   trap.c already verifies as this rung's: folding skipped"
    ;;
  pristine) ;;
  old-composite)
    # (fold the plan's older bytes out: the tree carries 1037's block + a carrier under an earlier
    #  seam spelling.  Folding is the plan's own --off, and it proves the text is ONE composite.)
    python3 -I - "$XNU_TREE" <<'PYFOLD'
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("_plan", os.path.join("tools", "patch_d13_plan.py"))
m = importlib.util.module_from_spec(spec); sys.modules["_plan"] = m; spec.loader.exec_module(m)
xnu = sys.argv[1]; tp = m.trap_path(xnu)
out, why = m.off(m.read(tp), xnu)
if out is None:
    print("REFUSING: " + str(why)); sys.exit(1)
m.write(tp, out)
print("   folded the old composite out (the 1036 bytes, then composed again)")
PYFOLD
    ;;
  ready)
    # (the tree already carries this rung's whole edit - the plan's seam, the inherited chain, 1037 and
    #  1038's defs include. There is nothing to compose: composing again would put a second seam in.)
    echo "   trap.c is already this rung's: composing skipped, the staged text is used as it stands"
    ;;
  composed-under-a-second-seam)
    # (a tree staged under TWO seams is not this rung's composite and not the 1036 tree: the fold
    # would have to guess which seam is real.  Never re-compose it -- start from a pristine tree.)
    echo "REFUSING: $TRAP_SRC carries 1037's rows or the hook outside this rung's plan (a second seam?) - start from the 1036 tree"; exit 1 ;;
  *) echo "REFUSING: the plan will not compose on $TRAP_SRC (not the 1036 tree)"; exit 1 ;;
esac
if [[ "${_st%%:*}" == ready || "${_st%%:*}" == staged ]]; then
  # (nothing to compose; the staged text is verified as it stands)
  python3 -I tools/patch_d13_plan.py "$XNU_TREE" --verify | tail -1 \
    || { echo "REFUSING: the staged plan does not verify"; exit 1; }
else
  python3 -I tools/patch_d13_plan.py "$XNU_TREE" --apply | tail -1 \
    || { echo "REFUSING: the plan will not compose on $TRAP_SRC (not the 1036 tree)"; exit 1; }
  python3 -I tools/patch_d13_plan.py "$XNU_TREE" --verify | tail -1 \
    || { echo "REFUSING: the plan does not verify after --apply"; exit 1; }
fi
# **The plan composes the SEAM - 1037's and 1038's blocks are their OWN rungs and must be staged on
# top of it.** They were never applied here: `$TF_PATCHER` and `$LE_PATCHER` were defined at the top
# and used only by the preflight's selftests, so a freshly composed tree reached the pool with no
# `xnu_live_fb_*` rows at all and step 6 failed its "1037's own body carries 0" count. 1037 first (the
# plan's seam carries its text), then 1038's model, which lands inside it.
# **The seven inherited rungs run between the compose and 1037.** Their anchors are a strict chain:
# abt_entry wants "ABT_ENTRY_PROBE/USTACK_PROBE", reader wants "READER_PROBE/USTACK_PROBE", and so on
# down to pc_carrier_caller - each one's close must stand immediately in front of 1025's. None of them
# was applied here, because the tree this script used to meet already carried them from an earlier
# build. Start from a freshly composed tree and they are simply absent, so every later rung found "0
# time(s)" and the chain stopped wherever it began. They run in dependency order, before 1037 and 1038:
# 1038 names PC_CARRIER_CALLER as "this block's immediate predecessor", i.e. it goes last.
python3 tools/stage_trap_half.py "$XNU_TREE" --chain \
  || { echo "REFUSING: the inherited rung chain did not stage in order"; exit 1; }
python3 -I "$TF_PATCHER" "$XNU_TREE" --apply | tail -1 \
  || { echo "REFUSING: 1037's frame body did not stage on the composed seam"; exit 1; }
python3 -I "$LE_PATCHER" "$XNU_TREE" --apply | tail -1 \
  || { echo "REFUSING: 1038's model did not stage"; exit 1; }

# 2b. THE LAYOUT THE COMPILER ACCEPTS.  The rungs leave trap.c in a shape C rejects: 1038's older
#     inline arm (one row of literal backslash-n), its statics defined inside sleh_abort, block-scope
#     `static` prototypes, and - when the include has gone missing - no hook at all. Each stage in
#     tools/replay-1039-trap-layout.sh is a defect that belongs in its owner eventually; the script is
#     the measured order, and it is idempotent, so this runs unconditionally.
echo "-- 2b. the trap.c layout (tools/replay-1039-trap-layout.sh) --"
bash tools/replay-1039-trap-layout.sh "$XNU_TREE" | sed 's/^/  /' \
  || { echo "REFUSING: the trap.c layout could not be replayed"; exit 1; }

# 3. THE STAGED TEXT PREPROCESSES, BY THE COMPILER.  The defect this rung fixes was structural (a
#    close with nothing open); the guard is the real preprocessor over the seam's DIRECTIVE lines
#    under three switch combinations (OFF / 1025 only / all on).  A missing #endif, a doubled close,
#    or an unclosed include pair fails here -- not 705 objects later.
python3 - "$TRAP_SRC" <<'PYPP' || { echo "REFUSING: the staged seam does not preprocess"; exit 1; }
import subprocess, sys, tempfile, os
t = open(sys.argv[1]).read()
o = "#if defined(STAGE90_XNU_USTACK_PROBE) && STAGE90_XNU_USTACK_PROBE" + chr(10)
c = "#endif /* STAGE90_XNU_USTACK_PROBE */" + chr(10)
i = t.index(o); j = t.index(c, i) + len(c)
lines = [l for l in t[i:j].split(chr(10)) if l.strip().startswith("#")]
d = tempfile.mkdtemp(); src = os.path.join(d, "probe.c")
open(src, "w").write(chr(10).join(lines) + chr(10))
combos = {"OFF": [],
          "1025": ["-DSTAGE90_XNU_USTACK_PROBE=1"],
          "ALL": ["-DSTAGE90_XNU_USTACK_PROBE=1", "-DSTAGE90_XNU_TRAP_FRAME=1",
                  "-DSTAGE90_XNU_FRAME_CARRIER=1", "-DSTAGE90_XNU_WATCH_LE=1"]}
for name, defs in combos.items():
    r = subprocess.run(["arm-none-eabi-gcc", "-E", "-P", "-nostdinc", "-undef"] + defs + [src],
                       capture_output=True, text=True)
    if r.returncode != 0:
        print("   %s: the preprocessor REFUSED: %s" % (name, (r.stderr or "").strip().splitlines()[:3]))
        sys.exit(1)
    left = [l for l in r.stdout.split(chr(10)) if l.strip().startswith("#")]
    if left:
        print("   %s: a directive survived the preprocessor: %r" % (name, left[:3])); sys.exit(1)
    print("   %s: preprocesses, no directive survives (%d bytes)" % (name, len(r.stdout)))
PYPP

# 3b. THE SEMANTIC HALF OF 3 NOW RUNS LATER, AS 6c, ON THE POOL'S OWN ARGV.  3 is STRUCTURAL (the
#     staged region's directive lines through the real preprocessor) and passed once while
#     `watch_le_arm.inc` was spliced into BOTH sleh_abort and sleh_undef -- it names sleh_abort's
#     locals, so with WATCH_LE=1 the undef arm did not compile (2026-10-20, a 1039 BUILD defect).
#     The compile needs the SAME argv the pool compiles trap.c with, and a hand-built copy of that
#     argv is a second definition of it (measured: a target, a force-include and a PER-COMPONENT
#     define each went missing or wrong).  The pool prints its own argv at 6b; 6c appends the
#     switch combinations to it.  [[mi4-1039-guard-argv-not-pool-argv]]

# 4. EVERY OTHER trap.c PATCHER ACCEPTS THE COMPOSED TREE (the shared namespace in effect).  The
#    plan's own file is skipped: it is the composer, not a rung.
for _p in tools/patch_d13_*.py; do
  case $_p in
    $PATCHER|$TF_PATCHER|$LE_PATCHER|$RS_PATCHER|tools/patch_d13_plan.py|*/patch_d13_abt_retry_bound.py|*/patch_d13_boot_path*.py|*/patch_d13_commpage_alias.py) continue ;;
  esac
  python3 -I $_p "$XNU_TREE" 2>&1 | grep -i 'REFUSE' && {
    echo "REFUSING: $(basename $_p) refuses the composed tree"; exit 1; } || true
done

# 5. THE PARENT RECORD, read BEFORE the build (it names the image this rung replaces), then the chain:
#    the record carries the parents and the entry layer names the new switch (the record can carry it;
#    park_1039 would refuse otherwise).
echo "-- 5. the record's inherited chain --"
[[ -r $REC ]] || { echo "REFUSING: no arm record at $REC -- build 1037 first"; exit 1; }
# $OTHER (1038) stays OFF.  The tree carries 1038's ROW side, laid out aright (2026-10-19) so that it
# PREPROCESSES without its switch: `#ifndef WATCH_LE_STATICS_DEFINED` group, the arm behind
# `#if defined(STAGE90_XNU_WATCH_LE)`, and NO `#define` of the switch.  Undefined, the arm is compiled
# out and the build_entry's WATCH_LE=0 clause reads the pool: none of the 17 sw eq / ler literals.
# (2026-10-19 17:4x: the earlier `=1` demand was written for a stray `#define` in the seam; that define
# is gone, and `=1` would now demand rows that are not compiled.)
# (the record is READ, never written: a rung that rewrote its parent's record left every later build
# reading a value this one chose.  $OTHER is passed in -- a heredoc cannot see the shell's variables.)
PYFIX=1 python3 - "$REC" "$OTHER" <<'PYEOF'
import sys
p, other = sys.argv[1], sys.argv[2]
t = open(p).read()
NL = chr(10)
key = "STAGE90_XNU_WATCH_LE="
if key + "0" + NL in t:
    print("   1038 (%s) is 0 in the record (its ROW side compiles out: the switch is undefined)" % other)
    raise SystemExit(0)
_other = (key + "1" + NL, key + "(unset)" + NL)
for _one in _other:
    if _one in t:
        print("REFUSING: the record has %s=%s; this rung builds with 1038's row side compiled OUT. "
              "Set it to 0 in the record (a parent's record is not this rung's to rewrite)."
              % (key.rstrip("="), _one[len(key):].rstrip(NL)))
        raise SystemExit(1)
raise SystemExit("REFUSING: the record carries no %s line at all" % key)
PYEOF
for k in $TF STAGE90_XNU_PC_CARRIER_CALLER STAGE90_XNU_PC_CARRIER STAGE90_XNU_EVAL_FRAME \
         STAGE90_XNU_CALLER_PROBE STAGE90_XNU_WRITER_PROBE STAGE90_XNU_READER_PROBE \
         STAGE90_XNU_ABT_ENTRY_PROBE STAGE90_XNU_USTACK_PROBE STAGE90_XNU_H2_STACK_HEADROOM \
         STAGE90_XNU_VM_MAX_SPLIT STAGE90_XNU_IOS7_TRAPS STAGE90_XNU_GENERAL_REGS \
         STAGE90_XNU_UNDEF_RAISE; do
  grep -q "^$k=1\$" "$REC" || { echo "REFUSING: $REC does not carry $k=1 - not the arm 1039 instruments"; exit 1; }
done
for _f in src/entry/build_entry.sh scripts/preflight_boot_check.sh; do [[ -f $_f ]] || { echo "REFUSING: $_f is absent"; exit 1; }; done
grep -qE "^[[:space:]]*$NEW\)?$" src/entry/build_entry.sh || { echo "REFUSING: build_entry.sh does not list $NEW in ENTRY_ARM_KEYS"; exit 1; }
grep -qE "^[[:space:]]*$NEW\)[[:space:]]+_v=" src/entry/build_entry.sh || { echo "REFUSING: build_entry.sh has no case arm for $NEW"; exit 1; }
grep -q "echo \"$NEW=" src/entry/build_entry.sh || { echo "REFUSING: build_entry.sh does not ECHO $NEW into the record"; exit 1; }
grep -q "_fc_req=\${STAGE90_XNU_FRAME_CARRIER:-0}" src/entry/build_entry.sh || { echo "REFUSING: build_entry.sh has no LINK-time pool clause for $NEW (a record saying 1 over a pool carrying none would link)"; exit 1; }
grep -qE "^[[:space:]]*$NEW\)$" scripts/preflight_boot_check.sh || { echo "REFUSING: preflight_boot_check.sh does not list $NEW in its gate key list"; exit 1; }
grep -q "\"$NEW\"" $PATCHER || { echo "REFUSING: $PATCHER does not name $NEW"; exit 1; }
echo "   the record and the entry layer carry $NEW"

# 6. THE KERNEL POOL (TRAP is a POOL object: without a pool rebuild the record's $NEW=1 stands over a
#    trap.o that carries NO fcr row - [[mi4-build-variant-comes-from-an-env-default]]).
echo "-- 6. the D13 kernel pool (the record's switch set verbatim + $NEW=1) --"
EXPORTS=()
while IFS= read -r line; do
  line=${line%%$'\r'}
  [[ -z $line || $line == \#* ]] && continue
  k=${line%%=*}; v=${line#*=}
  [[ $v == '(unset)' ]] && continue
  case $k in STAGE90_XNU_ENTRY_SHA256|STAGE90_XNU_ENTRY_BYTES) continue ;; esac
  EXPORTS+=("$k=$v")
done < "$REC"
EXPORTS+=("STAGE90_ENTRY_ARM_CHANGE=1" "XNU_TREE=$XNU_TREE" "$NEW=1")
echo "   carrying $(( ${#EXPORTS[@]} - 3 )) switch(es) from $REC + $NEW=1"
# The -D set: everything the record names EXCEPT the switches whose channel is the global DEFINES array
# or a FLAG, plus 1015b's token which has NO record carrier (records/1020-build-defect.txt).
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
    STAGE90_XNU_PC_CARRIER|STAGE90_XNU_PC_CARRIER_CALLER|STAGE90_XNU_TRAP_FRAME|STAGE90_XNU_WATCH_LE|\
    STAGE90_XNU_FRAME_CARRIER) continue ;;
  esac
  [[ $k == STAGE90_* ]] || continue
  case $v in 0|1|0x*|[0-9]*) ;; *) continue ;; esac
  EXTRA="$EXTRA -D$k=$v"
done < "$REC"
EXTRA="${EXTRA# } -DSTAGE90_XNU_GLOBAL_FIX=1"
[[ "$EXTRA" == *"-DSTAGE90_XNU_GLOBAL_FIX=1"* ]] || { echo "FAIL: -DSTAGE90_XNU_GLOBAL_FIX=1 is NOT in EXTRA - 1015b's fix has NO record carrier; without it the retry storm returns"; exit 1; }
for _g in $NEW TRAP_FRAME WATCH_LE; do
  [[ "$EXTRA" != *"-D$_g"* ]] || { echo "FAIL: -D$_g is in EXTRA -- its channel is the global DEFINES array (env export), not XNU_KERNEL_EXTRA_DEFINES"; exit 1; }
done
# Every switch whose channel is the global DEFINES array is exported here (spelled once, checked once).
_GLOBAL="${_GLOBAL_DEFINES_SWITCHES:-VM_MAX_SPLIT USTACK_PROBE ABT_ENTRY_PROBE H2_STACK_HEADROOM READER_PROBE WRITER_PROBE CALLER_PROBE EVAL_FRAME PC_CARRIER PC_CARRIER_CALLER TRAP_FRAME FRAME_CARRIER}"
for _g in $_GLOBAL; do
  export "STAGE90_XNU_$_g=1"
  grep -q "DEFINES+=(-DSTAGE90_XNU_$_g=1)" tools/build_xnu_arm_kernel.sh || { echo "FAIL: $_g was exported but tools/build_xnu_arm_kernel.sh has no reader for it"; exit 1; }
done
# 1021d's FLAG switch and 989's assembly-layer switch (not global-DEFINES): read back from the record.
[[ $(awk -F= '$1=="STAGE90_XNU_GENERAL_REGS"{print $2}' "$REC") == 1 ]] || { echo "FAIL: $REC does not record STAGE90_XNU_GENERAL_REGS=1"; exit 1; }
export STAGE90_XNU_GENERAL_REGS=1
[[ $(awk -F= '$1=="STAGE90_XNU_SP_ALIGN"{print $2}' "$REC") == 1 ]] || { echo "FAIL: $REC does not record STAGE90_XNU_SP_ALIGN=1"; exit 1; }
export STAGE90_XNU_SP_ALIGN=1
# EVERY SWITCH THE ASM LAYER READS FROM THE ENV (tools/assemble_arm_layer.sh), DERIVED not hand-copied.
_asm_keys=$(grep -oE '^[A-Z0-9_]+=\$\{STAGE90_XNU_[A-Z0-9_]+:-' tools/assemble_arm_layer.sh | sed -E 's/.*STAGE90_XNU_([A-Z0-9_]+):-/\1/' | sort -u)
[[ $(grep -c . <<<"$_asm_keys") -ge 5 ]] || { echo "FAIL: the asm layer's env-switch list came out as [$_asm_keys] - the derivation regex no longer matches assemble_arm_layer.sh"; exit 1; }
for _k in $_asm_keys; do
  case $_k in IDLE_STACK_SIZE|IDLE_STACK) continue ;; esac
  _v=$(awk -F= -v k="STAGE90_XNU_$_k" '$1==k{print $2}' "$REC")
  [[ -z $_v ]] || export "STAGE90_XNU_$_k=$_v"
done
[[ $(awk -F= '$1=="STAGE90_XNU_HFS_ROOT_RW"{print $2}' "$REC") == 1 ]] || { echo "FAIL: $REC does not record STAGE90_XNU_HFS_ROOT_RW=1 - the HFS port export below is only right for the rw arm"; exit 1; }
export STAGE90_XNU_HFS_ROOT_RW=1
export STAGE90_XNU_HFS=1
(( ${STAGE90_XNU_FRAME_CARRIER:-0} == 1 )) || { echo "FAIL: $NEW=1 did not export"; exit 1; }
# THE REPRODUCER: the pool's own trap.c ARGV, for a host-side syntax check.  The pool compiles 705
# objects; `--trap-argv` walks the same manifest, stops at osfmk/arm/trap.c and prints the argv THAT
# loop would have run -- no object written, the pool NOT torn down (the mode is read-only by
# construction: its teardown is skipped beside `--platform-only`'s).
if [[ ${STAGE90_1039_TRAP_ARGV_ONLY:-0} == 1 ]]; then
  # (the host gates are the work; steps 6b/6c print and judge the argv and stop here)
  :
else
XNU_TREE="$XNU_TREE" XNU_KERNEL_CONFIG=STAGE90_XNU \
XNU_MASTER_LOCAL="$PWD/tools/xnu_config/boot/STAGE90_XNU.local" \
XNU_KERNEL_EXTRA_DEFINES="$EXTRA" \
    ./tools/build_xnu_arm_kernel.sh
fi
if [[ ${STAGE90_1039_TRAP_ARGV_ONLY:-0} != 1 ]]; then
[[ -f $TRAP_OBJ && -f $EXEC_OBJ ]] || { echo "FAIL: pool objects absent"; exit 1; }
for s in $(python3 -I "$CHECKER" --required-rows); do
  grep -qa "^$s" <(strings "$TRAP_OBJ") || { echo "FAIL: $TRAP_OBJ carries NO $s row - the pool was NOT recompiled with $NEW=1 (env channel) or the TRAP edit is not staged"; exit 1; }
done
# (1038's sweep/LER rows are NOT in this list: step 5 just read the record's WATCH_LE=0, so its arm
# is compiled OUT and the rows' absence is the reading (build_1039.sh's own note at 3.) -- demanding
# them here refused a pool that built exactly what the record says.  WATCH_LE=1 -> the arm's own
# rows travel in watch_le_arm.inc and appear without this list naming them.)
for s in xnu_live_fb_seq= xnu_live_pcc2_seq= xnu_live_pcc_pc= \
         xnu_live_evf_pc= xnu_live_cal_region_end= xnu_live_wrp_r4= xnu_live_rdr_far= xnu_live_abt_lookup_far= xnu_live_abt_vmfkrv=; do
  grep -qa "^$s" <(strings "$TRAP_OBJ") || { echo "FAIL: $TRAP_OBJ lost $s - the pool rebuild dropped an inherited rung"; exit 1; }
done
grep -q "$NEW" "$TRAP_SRC" || { echo "FAIL: the staged TRAP carries no $NEW"; exit 1; }
# 2026-10-20: the arm (inside sleh_abort) names the defs file's objects and helpers, and the defs are
# included ~1300 lines BELOW the function -- C declares downward only, so the fwd include must stand
# at FILE SCOPE in front of sleh_abort (552 "use of undeclared identifier" without it on the pool's
# argv).  The fact is checked by value: one include, in front of sleh_abort's signature line.
python3 - "$TRAP_SRC" "$XNU_TREE/osfmk/arm" <<'PYFWD' || { echo "FAIL: the staged TRAP does not include watch_le_fwd.inc at file scope in front of sleh_abort"; exit 1; }
import os, sys
t = open(sys.argv[1]).read()
d = sys.argv[2]
fwd = "#include " + chr(34) + os.path.join(d, "watch_le_fwd.inc") + chr(34)
sig = "void sleh_abort("
assert t.count(fwd) == 1, "the fwd include is not in the tree exactly once"
assert t.index(fwd) < t.index(sig), "the fwd include stands at or below sleh_abort (not file scope)"
dep = 0
for l in t[:t.index(fwd)].split(chr(10)):
    s = l.strip()
    if s.startswith("#if"):
        dep += 1
    elif s.startswith("#endif"):
        dep -= 1
assert dep == 0, "the fwd include stands at preprocessor depth %d, not file scope" % dep
print("   fwd include: once, at depth 0, in front of sleh_abort")
PYFWD
_src_rec=out/xnu_kernel_src_d13.sha256
[[ -s $_src_rec ]] || { echo "FAIL: $_src_rec absent - the pool's source record cannot certify the rebuild"; exit 1; }
_tc_want=$(sha256sum "$TRAP_SRC" | awk '{print $1}')
_tc_have=$(awk -v p="$TRAP_SRC" '$2==p{print $1}' "$_src_rec" | head -1)
[[ -n $_tc_have && "$_tc_want" == "$_tc_have" ]] || { echo "FAIL: $_src_rec's TRAP hash (${_tc_have:-none}) != the staged file's ($_tc_want) - the pool was NOT rebuilt from the staged trap.c"; exit 1; }
echo "   6 PASS: trap.o carries the fcr rows (from $CHECKER --required-rows) and the fb/sweq/pcc2/pcc/evf parents; the source record names the staged TRAP's sha256"
# THE EXPECTED COUNT IS THE OWNER'S, not a constant: 1037's re-staged body carries the row twice (its
# constant witness and its distinct-VA witness).  A constant would call the complete body "doubled".
# THE EXPECTED COUNT IS THE OWNER'S, READ FROM 1037's OWN BODY -- never a constant (1037's RE-STAGED
# body carries the row twice: its constant witness and its distinct-VA witness; a constant called the
# complete body "doubled").  Boundary: the body is the text between 1037's head and its two close lines.
# THE EXPECTED COUNT IS THE OWNER'S, READ FROM 1037's OWN BODY -- never a constant (1037's RE-STAGED
# body carries the row twice: its constant witness and its distinct-VA witness; a constant called the
# complete body "doubled").  The source record already ties $TRAP_SRC to the pool, so the count is
# read from the STAGED file against the owner's body, and the owner's body must be exactly 1037's
# block between its head (carrier close + switch) and its two close lines.
_fb_owner() {
  python3 -I - "$XNU_TREE" "$1" <<'PYR'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("_plan", "tools/patch_d13_plan.py")
m = importlib.util.module_from_spec(spec); sys.modules["_plan"] = m; spec.loader.exec_module(m)
print(m.row_count(sys.argv[1], sys.argv[2]))
PYR
}
_fb_want=$(_fb_owner 'xnu_live_fb_seq=') || _fb_want=0
_fb_have=$(grep -c 'xnu_live_fb_seq=' "$TRAP_SRC")
[[ ${_fb_want:-0} -ge 1 && "$_fb_have" == "$_fb_want" ]] || { echo "FAIL: the staged TRAP carries $_fb_have xnu_live_fb_seq= row(s), 1037's own body carries ${_fb_want:-0} - 1037's block is partial or doubled"; exit 1; }
# 1038's arm lives in watch_le_arm.inc, reached by ONE hook include inside sleh_abort; its rows
# reach trap.o through that include.  Check the FACT by value, not the old in-trap.c markers.
python3 - "$TRAP_SRC" "$XNU_TREE/osfmk/arm" <<'PYLE' || { echo "FAIL: 1038's includes are not the model's"; exit 1; }
import os, sys
t = open(sys.argv[1]).read()
d = sys.argv[2]
defs = os.path.join(d, "watch_le_defs.inc")
arm = os.path.join(d, "watch_le_arm.inc")
assert t.count("#include " + chr(34) + defs + chr(34)) == 1, "the defs include is not in the tree exactly once"
assert t.count(os.path.join(d, "watch_le_arm.inc")) == 1, "the arm include is not in the tree exactly once"
a = open(arm).read()
o = "#if defined(STAGE90_XNU_WATCH_LE) && STAGE90_XNU_WATCH_LE"
assert o in a, "the arm file does not open with its switch"
print("   1038: defs+arm includes once each; the arm stands behind its switch in its own file")
PYLE
fi
# 6b. THE POOL'S OWN ARGV, PRINTED BY THE POOL (`--trap-argv`), FOR 3c.  This is the argv the pool
#     COMPILES osfmk/arm/trap.c with -- the compiler, its target and dialect flags, every include
#     root in its order, every define (the configuration's AND osfmk's component set), every
#     force-include -- printed, never run: no object written, the pool NOT torn down.  A guard that
#     spells any of it itself compiles an argv the pool never runs
#     ([[mi4-one-value-two-definitions]]; the MACH_KERNEL_PRIVATE case of 2026-10-20).
[[ $TRAP_ARGV == /* ]] || TRAP_ARGV=$PWD/$TRAP_ARGV    # (the pool may chdir inside itself)
: > "$TRAP_ARGV"
env XNU_TREE="$XNU_TREE" XNU_KERNEL_CONFIG=STAGE90_XNU \
  XNU_MASTER_LOCAL="$PWD/tools/xnu_config/boot/STAGE90_XNU.local" \
  XNU_KERNEL_EXTRA_DEFINES="$EXTRA" TRAP_ARGV_CAPTURE="$TRAP_ARGV" \
  TRAP_ARGV_SRC=xnu/osfmk/arm/trap.c \
      ./tools/build_xnu_arm_kernel.sh --trap-argv || { echo "FAIL: the pool would not print trap.c's argv"; exit 1; }
[[ $(grep -c . "$TRAP_ARGV") -ge 100 ]] || { echo "FAIL: $TRAP_ARGV has $(grep -c . "$TRAP_ARGV") element(s) - not a command"; exit 1; }
grep -qxF -- "-fno-common" "$TRAP_ARGV" && grep -qxF -- "$XNU_TREE/osfmk" <(sed 's/^-I//' "$TRAP_ARGV") \
  || { echo "FAIL: $TRAP_ARGV is not the pool's compile argv (no dialect flag or no osfmk root)"; exit 1; }
echo "   trap argv: $(grep -c . "$TRAP_ARGV") element(s), the pool's own (compiler first, source last)"

# 6c. THE TREE THE POOL WOULD COMPILE COMPILES UNDER EVERY SWITCH COMBINATION -- on THAT argv, not a
#     second spelling of it.
python3 - "$TRAP_SRC" "$TRAP_ARGV" <<'PYCC3' || { echo "REFUSING: the staged trap.c does not compile on the pool's own argv"; exit 1; }
import os, subprocess, sys
src, cap = os.path.abspath(sys.argv[1]), sys.argv[2]
argv = [l.rstrip(chr(10)) for l in open(cap) if l.strip()]
if len(argv) < 10 or argv[-1] != src:
    print("   %s: %d element(s), last %r" % (cap, len(argv), argv[-1:] or None)); sys.exit(1)
argv = argv[:-1]
combos = {"OFF": [], "1025": ["-DSTAGE90_XNU_USTACK_PROBE=1"],
          "framecarrier": ["-DSTAGE90_XNU_USTACK_PROBE=1", "-DSTAGE90_XNU_TRAP_FRAME=1",
                           "-DSTAGE90_XNU_FRAME_CARRIER=1"],
          "ALL": ["-DSTAGE90_XNU_USTACK_PROBE=1", "-DSTAGE90_XNU_TRAP_FRAME=1",
                  "-DSTAGE90_XNU_FRAME_CARRIER=1", "-DSTAGE90_XNU_WATCH_LE=1"]}
for name, defs in combos.items():
    # (the switch flags go LAST: a `#define` of the switch must win over any the pool's argv carries)
    # (`clang`, never the pool's `-O2` object: the argv is the list the pool gives its compiler, and
    #  the compile does not need the pool's optimization level -- [[mi4-1039-guard-argv-not-pool-argv]])
    r = subprocess.run(["clang"] + argv[1:] + defs + ["-fsyntax-only", src], capture_output=True, text=True)
    if r.returncode != 0:
        print("   %s: DOES NOT COMPILE:" % name)
        for l in [x for x in r.stderr.splitlines() if "error" in x][:5]:
            print("     " + l)
        sys.exit(1)
    print("   %s: compiles (the pool's own argv, syntax only)" % name)
PYCC3
if [[ ${STAGE90_1039_TRAP_ARGV_ONLY:-0} == 1 ]]; then
  echo "== 1039 HOST GATES PASS (trap.c composed + the pool's own argv compiles it under every combo). No pool, no device. =="
  exit 0
fi

# 1039's OWN gate (FCR rows) is the carrier's: it must pass.  1038's rows are a COMPANION here --
# measured and reported, never this rung's conjunct: the arm prints them from the .inc files, which the
# patcher's python source cannot show (a check on another rung's text through the wrong text).
python3 -I "$CHECKER" --emitter-missing $PATCHER 2>&1 | grep -v '^COMPANION ' \
  || { echo "FAIL: $PATCHER does not emit every row the reader needs"; exit 1; }

# 7. THE ENTRY IMAGE, rebuilt reproducibly (build_entry.sh changed: its key list now names $NEW).
echo "-- 7. entry image (reproducible: same sources -> same bin) --"
ENTRY_EXPORTS=()
while IFS= read -r line; do
  line=${line%%$'\r'}; [[ -z $line || $line == \#* ]] && continue
  k=${line%%=*}; v=${line#*=}; [[ $v == '(unset)' ]] && continue
  case $k in STAGE90_XNU_ENTRY_SHA256|STAGE90_XNU_ENTRY_BYTES|STAGE90_XNU_TREE_D13) continue ;; esac
  ENTRY_EXPORTS+=("$k=$v")
done < "$REC"
ENTRY_EXPORTS+=("$NEW=1" "XNU_TREE=$XNU_TREE" "STAGE90_ENTRY_ARM_CHANGE=1")
( cd src/entry && env -i PATH="$PATH" HOME="$HOME" "${ENTRY_EXPORTS[@]}" ./build_entry.sh ) || { echo "FAIL: the entry build refused"; exit 1; }
( cd src/entry && env -i PATH="$PATH" HOME="$HOME" "${ENTRY_EXPORTS[@]}" ./build_entry.sh ) || { echo "FAIL: the second entry build refused"; exit 1; }
_eb1=$(sha256sum $LIVE/xnu_arm_entry.bin | awk '{print $1}')
( cd src/entry && env -i PATH="$PATH" HOME="$HOME" "${ENTRY_EXPORTS[@]}" ./build_entry.sh ) >/dev/null || exit 1
_eb2=$(sha256sum $LIVE/xnu_arm_entry.bin | awk '{print $1}')
[[ $_eb1 == "$_eb2" ]] || { echo "FAIL: the entry image did not reproduce ($_eb1 != $_eb2) - it is not a function of src/entry/"; exit 1; }
echo "   entry bin sha256=$_eb1 (twice)"

# 8. THE PAYLOAD, with the arm's switches + the entry switch.
echo "-- 8. payload (arm switches + -DSTAGE90_XNU_ENTRY=1) --"
_arm_sw=$(tr '\n' ' ' < "$REC")
XNU_TREE="$XNU_TREE" STAGE90_EXTRA_CFLAGS="$_arm_sw -DSTAGE90_XNU_ENTRY=1" ./scripts/build.sh || { echo "FAIL: payload build refused"; exit 1; }

# 9. THE CARD (1032's guard must be the one on the device).
echo "-- 9. the card --"
scripts/build_1032.sh | tail -3
_card=$LIVE/xnu_card_hfs.img
_rs=${STAGE90_REAL_ROOTFS:-/mnt/data/ios7-payload/v2/ios7/rootfs.hfs}
[[ -f $_card && -f $_rs ]] || { echo "FAIL: card or pristine rootfs absent"; exit 1; }
_n=$(cmp -l "$_card" "$_rs" 2>/dev/null | wc -l || true)
[[ $_n == 10 ]] || { echo "FAIL: the card differs from the pristine rootfs in $_n bytes, want 10"; exit 1; }
_got=$(dd if="$_card" bs=1 skip=$((0x10183720)) count=10 2>/dev/null | od -An -tx1 | tr -d ' \n')
[[ $_got == 5010012801daf0bdc046 ]] || { echo "FAIL: card 0x10183720 = $_got"; exit 1; }
echo "   9 PASS: card carries 1032's guard"

echo "== 1039 BUILD DONE (trap.c + pool + entry + payload + card). Not pressed. =="
echo "   NEXT: bash scripts/park_1039.sh   (names the arm, appends role=1039-frame-carrier)"
echo "         then, when the device is up and 1037's console is recovered: bash scripts/press_1039.sh"
