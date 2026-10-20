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
for _f in $PATCHER $TF_PATCHER $LE_PATCHER $RS_PATCHER; do
  [[ -f $_f ]] || { echo "REFUSING: $_f is absent - it is part of the edit"; exit 1; }
done
# 1038's ROW side, laid out aright ([[mi4-off-option-two-spellings]]): `#if 1` with a STAGE90 switch
# inside it has no OFF and the stray `#define` forces it ON.  The rowside patcher re-forms the arm's
# chunk IN PLACE (the statics group + gate table kept byte for byte) so the arm stands behind its real
# switch, undefined => compiled out, the block closed by 1039's seam line `#endif /* 1038 BLOCK END */`.
# It runs BEFORE 1037's --restage: while 1037's block is still 1037's, its close line carries the `}`
# braces the arm's re-form must keep; the re-form turns them into the arm's statements, and 1037's
# re-stage then nests them under 1037's switch where 1038's slot stands (measured 2026-10-19: the
# reverse order leaves 1038's statics + stray define before CHUNK_END's line search and the seam
# double-brackets).
python3 -I $RS_PATCHER --selftest | tail -1
python3 -I $LE_PATCHER --selftest | tail -1   # 2026-10-20: PASSES again (records/1038-watch-le-selftest.txt)
# THE TREE'S PRE-CONDITION, checked BEFORE anything writes (2026-10-19: a build found trap.c already
# carrying 1038's laid-out block and its own step-1 --verify-off refused halfway through the rung).
# 1039's pre-1039 tree is 1037's staged body with 1038's three-section row side and NO block end;
# anything else is another rung's write or a half-staged tree, and no patcher of ours should touch it.
if grep -q '^#endif /\* 1038 BLOCK END \*/' "$TRAP_SRC" 2>/dev/null; then
  python3 -I $RS_PATCHER $XNU_TREE --verify >/dev/null 2>&1 \
    || { echo "REFUSING: $TRAP_SRC already carries 1038's block end but it does not verify (a half-laid-out or foreign write) - restore the pre-1039 tree first"; exit 1; }
  echo "   1038's row side ALREADY laid out (a tree an earlier run of this script staged) - continuing"
fi
# THE CHANNEL: a switch with no DEFINES reader is an env default that reaches nothing.
for _n in $NEW $OTHER $TF; do
  grep -q "DEFINES+=(-D$_n=1)" tools/build_xnu_arm_kernel.sh || {
    echo "REFUSING: tools/build_xnu_arm_kernel.sh carries no DEFINES+=(-D$_n=1) reader"; exit 1; }
done
# THE CHANNEL MUST BE GATED (1039's own defect found before it could build): an UNGATED reader applies
# the switch to EVERY build.  tools/build_xnu_arm_kernel.sh line for $NEW must start with a test.
grep -qE "^\[\[ \\\$\{$NEW:-0\} -eq 1 \]\] && DEFINES\+=" tools/build_xnu_arm_kernel.sh || {
  echo "REFUSING: the $NEW reader is not gated on \${$NEW:-0} - every build would carry the block"; exit 1; }

# 1. THE PATCHERS' SELFTESTS (each refuses on a missing anchor, a missing row, an unguarded read).
python3 -I $PATCHER --selftest | tail -1
python3 -I $TF_PATCHER --selftest | tail -1
# 1037's refresh: --restage rewrites 1037's own block between its pair (the class the build needs
# every run -- 1039's --apply once wrote stray closes into that seam).  On a tree that already holds
# the current body it is a no-op; on one that needs it, it refuses or rewrites exactly that pair.
_rst=$(python3 -I $TF_PATCHER $XNU_TREE --restage 2>&1 | tail -1) && echo "   $_rst" || echo "   $_rst"
# 1038's ROW side, laid out aright BEFORE 1037's body is re-staged (the order is measured: see the
# rowside patcher's header).  Idempotent: on a tree already laid out it is a no-op.
_rs=$(python3 -I $RS_PATCHER $XNU_TREE --apply 2>&1 | tail -1) && echo "   $_rs" || { echo "$_rs"; echo "REFUSING: 1038's row side is not laid out"; exit 1; }
python3 -I $RS_PATCHER $XNU_TREE --verify >/dev/null || { echo "REFUSING: 1038's row side --verify FAILS after --apply"; exit 1; }
# the tree's own 1037 --verify-off on the PRE-1039 text (before step 2 stages anything): a tree whose
# 1037 body was half-reverted fails here, by name, instead of surfacing as an odd seam later.
python3 -I $TF_PATCHER $XNU_TREE --verify-off >/dev/null \
  || { echo "REFUSING: 1037's --verify-off FAILS on the tree BEFORE 1039 stages - its re-staged body is not whole"; exit 1; }
python3 -I $PATCHER $XNU_TREE --verify-off >/dev/null 2>&1 || true   # informational: absent before staging
# 2026-10-20: watch_le's selftest PASSES (0 failed, commit 0efd8fa; the "line 744 SyntaxError" note was a
# defect of the HOST process -- see records/1038-watch-le-selftest.txt).  Its --emitter-missing still
# names the s3/bp window rows (records/1038-window-gap.txt): the arms never populate _wl_bw/_wl_bo, so
# those rows would print a right-sized ZERO.  1039 does not stage 1038 (seam below).

# 2. RE-STAGE FROM THE TOP.  Rungs already in the tree are idempotent; 1037's BODY is replaced by
#    --restage (the tree still carries 1037's block from 1037's build).  THE PATCHERS READ THEIR SWITCH
#    FROM THE ENVIRONMENT: with it unset this step REPORTS "switch absent" and stages/verifies NOTHING
#    (measured 2026-10-19: --verify-off then FAILs "occurs 0 time(s)"), so every one is exported first.
# ORDER ([[mi4-one-file-many-rungs]], measured 2026-10-19): 1038 FIRST -- it SPLICES its seam, and its
# ORIGINAL `--apply` refuses once 1039's block stands at that seam.  1037's BODY -- --restage replaces
# its block in place and keeps 1038's spliced slot.  1039 LAST -- it anchors right after 1037's close,
# in front of slot a.
# 2026-10-19 ($OTHER): 1038's TWO trap.c edits are NOT STAGED in this seam.  Its "hook" was a literal
# COPY of watch_le_hook.inc pasted into sleh_abort (the include itself is behind the same switch
# `-(unset)` in the parent, so the forced include defines nothing: the copy is how the text got in),
# and the A/B arm is absent from the seam.  In a composed TRAP_FRAME block a literal holding
# `#if`/`#endif` lines splits the block at the preprocessor and the closed libobjc abort path -- the path
# the run needs -- never links as one bracket.  So the seam carries NO 1038 text; 1038's rows are
# reached the way they were DESIGNED: a hook `#include` inside sleh_abort and the arm right after 1037's
# close (park_1039's P4 sits it by slot marker and 1025's close).
# 1038's UN-STAGED literal ("hook" was a copy of watch_le_hook.inc pasted into sleh_abort).  The tree's
# own `#include ".../watch_le_hook.inc"` in sleh_abort is NOT it: it is 1038's intended carrier (its
# content is behind WATCH_LE in the include's own text = 0 lines on this tree), and build_entry's
# 1038 clause links only when WATCH_LE=1.  The literal's fingerprint is the slot writer's body.
python3 - "$TRAP_SRC" <<'PYLE'
import sys
t = open(sys.argv[1]).read()
assert "#if 1   /* 1038 chunk: arm */" in t, "1038's row side is absent - not the 1039 tree"
head = t[:t.index("#if 1   /* 1038 chunk: arm */")]
assert "_wl_ss_slot(unsigned *ctx)" not in head, (
    "1038's un-staged literal (the slot writer's body) is in sleh_abort, before its row side")
print("   the seam carries no un-staged 1038 literal")
PYLE
export $NEW=1 $TF=1
# 1037's --restage only where
# 1037's --restage only where 1037's text is already the staged body: on a pre-1039 tree its text is
# absent (it refuses) and on a 1039-staged tree the refresher would have to remove a nested rung's close
# (it refuses).  Both refusals are the right answer; say which.
# (not called: 16:52 measured that on a tree carrying 1039's block it would take the LAST TRAP_FRAME
# close - the one after this rung's - and unwind the nest; it refuses, but the call is pointless here.)
# A tree that carries 1039's block from 1039's own build: plain --apply keeps it (idempotent).
# 2026-10-19: --apply on a tree whose block is ALREADY staged is not harmless here -- it wrote two
# stray `#endif /* STAGE90_XNU_FRAME_CARRIER */` at the tail (one between the body-close and 1025's
# close).  --verify-off PASSes on the staged tree => stage() is not called; only an unstaged tree gets
# the patcher at all.
if python3 -I $PATCHER $XNU_TREE --verify-off >/dev/null 2>&1; then
  echo "   $NEW: already staged and verified - no --apply"
else
  _got=$(python3 -I $PATCHER $XNU_TREE --apply 2>&1 | tail -1) && echo "$_got" || echo "$_got"
fi
# 1037's staged text opens STAGE90_XNU_TRAP_FRAME ONLY -- and our block's own OFF text re-opens it (its
# last line is 1037's close, restored) -- so the switch counts READ the switch, they do not decide it.
# (2026-10-19: `grep -c xnu_live_fcr_seq=` == 1 was never a fact this tree can hold: 1037's pair gives
# the switch two openers, the block's OFF text the second; the check refused a tree the patcher had
# just verified.  The fact that matters is 1039's block: one pair, inside the block, once.)
python3 - "$TRAP_SRC" <<'PYLE'
import sys
t = open(sys.argv[1]).read()
SW = "STAGE90_XNU_FRAME_CARRIER"
o = t.index("\n#if defined(%s) && %s\n" % (SW, SW)) + 1
c = t.index("#endif /* %s */\n" % SW, o)
assert t[o:o + len("#if defined(%s) && %s\n" % (SW, SW))] == "#if defined(%s) && %s\n" % (SW, SW)
body = t[o:c]
assert body.count("xnu_live_fcr_seq=") == 1, "1039's block does not carry exactly one xnu_live_fcr_seq= row"
assert body.count("\n#if ") <= 1, "1039's block carries another opener"
print("   1039's block: one switch pair, one xnu_live_fcr_seq= row")
PYLE

# 1038's ROW side is laid out aright: no switch `#define` in the file (its arm must be able to compile OUT)
[[ $(grep -c '^#define STAGE90_XNU_WATCH_LE' "$TRAP_SRC") -eq 0 ]] || { echo "FAIL: trap.c carries a stray switch define (#define STAGE90_XNU_WATCH_LE) - 1038's ROW side would ignore the record's 0"; exit 1; }

# 3. VERIFY-OFF on the composed tree: every rung's OFF text is its predecessor's bytes.
# (frame_carrier's --verify-off is informational here: the 1039 tree carries the block's OFF text as
# 1037's close line, which is the check above; on the composed tree the patcher itself reports the tree
# "already staged" and its OFF reading is the block's own body.  trap_frame's --verify-off is REQUIRED.)
python3 -I $PATCHER $XNU_TREE --verify-off | tail -1 || true
python3 -I $TF_PATCHER $XNU_TREE --verify-off | tail -1
# THE COMPOSED SEAM, by value (rewritten 2026-10-19 20:3x, by the compiler's reading): on work5 1025's
# data-abort arm opens in front of 1037's block and stays OPEN past it -- 1037 nests INSIDE it, and
# 1038's statics + rows + block end live in it after 1037's close; its one close is the tab-indented
# `#endif /* STAGE90_XNU_USTACK_PROBE */` at 1038's block end (step 6).  The `\t<1025 close>` at 1037's
# tail, once read as the bracket's close, is an EMPTY rung (a `\t#if` and `\t#endif` with only C
# comments between); writing chunk c's statements between them closed 1025 early.  What must hold: ONE
# 1037 pair, ONE FC pair inside it closing on 1037's close with nothing between, 1025's opener in front
# of both, and the block naming none of 1038's rows.
python3 - "$TRAP_SRC" <<'PY'
import sys
t = open(sys.argv[1]).read()
SW = "STAGE90_XNU_FRAME_CARRIER"
o37 = "#if defined(STAGE90_XNU_TRAP_FRAME) && STAGE90_XNU_TRAP_FRAME" + chr(10)
c37 = "#endif /* STAGE90_XNU_TRAP_FRAME */" + chr(10)
oFC = "#if defined(%s) && %s" % (SW, SW) + chr(10)
cFC = "#endif /* %s */" % SW + chr(10)
o25 = "#if defined(STAGE90_XNU_USTACK_PROBE) && STAGE90_XNU_USTACK_PROBE" + chr(10)
c25 = "#endif /* STAGE90_XNU_USTACK_PROBE */" + chr(10)
assert t.count(o37) == 1, "1037's opener: %d" % t.count(o37)
assert t.count(oFC) == 1, "1039's opener: %d" % t.count(oFC)
assert t.count(cFC) == 1, "1039's close: %d" % t.count(cFC)
assert t.count(c37) == 1, "1037's close: %d" % t.count(c37)
assert t.count(o25) == 1, "1025's opener: %d" % t.count(o25)
i37 = t.index(o37)
i = t.index(oFC)
k = t.index(cFC)
j = t.index(c37)
assert k < j, "1039's close does not stand inside 1037's block (before its close)"
assert t[j - len(cFC):j] == cFC, "1037's close does not immediately follow 1039's close"
assert t.index(o25) < i37 < i < k < j, "the order is not 1025 open < 1037 open < 1039 open < close < close"
# 1025's data-abort arm stays OPEN past the seam: 1038's statics and rows live in it, and its one close
# after them is the TAB-indented `#endif /* STAGE90_XNU_USTACK_PROBE */` at 1038's block end (checked in
# step 6); a column-0 close here would end the arm in front of 1037 and un-nest the seam (2026-10-19 20:3x).
body = t[i + len(oFC):k]
assert body.count("xnu_live_fcr_seq=") == 1, "1039's block does not carry exactly one xnu_live_fcr_seq= row"
assert (chr(10) + "#if ") not in body, "1039's block carries another opener"
assert "sweq_" not in body and "wlg_" not in body, "1039's block names none of 1038's rows"
print("   1039's block: one pair inside 1037's bracket at its close, naming none of 1038's rows")
PY
# 4. SWEEPS: every composite patcher accepts the composed tree; the trap.c report names the switches.
for _p in tools/patch_d13_*.py; do
  case $_p in
    $PATCHER|$TF_PATCHER|$LE_PATCHER|*/patch_d13_abt_retry_bound.py|*/patch_d13_boot_path*.py|*/patch_d13_commpage_alias.py) continue ;;
  esac
  if grep -q 'ALLOWED_IF_IDENTIFIERS\s*=' $_p; then
    python3 -I $_p $XNU_TREE 2>&1 | grep -i 'REFUSE' && {
      echo "REFUSING: $(basename $_p) refuses the composed tree"; exit 1; } || true
  fi
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
PYFIX=1 python3 - "$REC" <<'PYEOF'
import sys
p = sys.argv[1]
t = open(p).read()
NL = chr(10)
key = "STAGE90_XNU_WATCH_LE="
if key + "0" + NL in t:
    print("   1038 ($OTHER) is 0 in the record (its ROW side compiles out: the switch is undefined)")
    raise SystemExit(0)
for _one in (key + "1" + NL, key + "(unset)" + NL):
    if _one in t:
        open(p, "w").write(t.replace(_one, key + "0" + NL, 1))
        raise SystemExit(0)
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
XNU_TREE="$XNU_TREE" XNU_KERNEL_CONFIG=STAGE90_XNU \
XNU_MASTER_LOCAL="$PWD/tools/xnu_config/boot/STAGE90_XNU.local" \
XNU_KERNEL_EXTRA_DEFINES="$EXTRA" \
    ./tools/build_xnu_arm_kernel.sh
[[ -f $TRAP_OBJ && -f $EXEC_OBJ ]] || { echo "FAIL: pool objects absent"; exit 1; }
for s in $(python3 -I "$CHECKER" --required-rows); do
  grep -qa "^$s" <(strings "$TRAP_OBJ") || { echo "FAIL: $TRAP_OBJ carries NO $s row - the pool was NOT recompiled with $NEW=1 (env channel) or the TRAP edit is not staged"; exit 1; }
done
for s in xnu_live_fb_seq= xnu_live_sweq_seq= xnu_live_ler_cnt_b= xnu_live_wlg_byte= xnu_live_pcc2_seq= xnu_live_pcc_pc= \
         xnu_live_evf_pc= xnu_live_cal_region_end= xnu_live_wrp_r4= xnu_live_rdr_far= xnu_live_abt_lookup_far= xnu_live_abt_vmfkrv=; do
  grep -qa "^$s" <(strings "$TRAP_OBJ") || { echo "FAIL: $TRAP_OBJ lost $s - the pool rebuild dropped an inherited rung"; exit 1; }
done
grep -q "$NEW" "$TRAP_SRC" || { echo "FAIL: the staged TRAP carries no $NEW"; exit 1; }
_src_rec=out/xnu_kernel_src_d13.sha256
[[ -s $_src_rec ]] || { echo "FAIL: $_src_rec absent - the pool's source record cannot certify the rebuild"; exit 1; }
_tc_want=$(sha256sum "$TRAP_SRC" | awk '{print $1}')
_tc_have=$(awk -v p="$TRAP_SRC" '$2==p{print $1}' "$_src_rec" | head -1)
[[ -n $_tc_have && "$_tc_want" == "$_tc_have" ]] || { echo "FAIL: $_src_rec's TRAP hash (${_tc_have:-none}) != the staged file's ($_tc_want) - the pool was NOT rebuilt from the staged trap.c"; exit 1; }
echo "   6 PASS: trap.o carries the fcr rows (from $CHECKER --required-rows) and the fb/sweq/pcc2/pcc/evf parents; the source record names the staged TRAP's sha256"
[[ $(grep -c 'xnu_live_fb_seq=' "$TRAP_SRC") == 1 ]] || { echo "FAIL: the staged TRAP does not carry EXACTLY 1 xnu_live_fb_seq= row - 1037's block is partial or doubled"; exit 1; }
# 1038's arm has NO column-0 close: its close stands inside 1037's block, one TAB further in for every
# rung 1037 nests under itself.  What is checked is the FACT, by value: its real switch line is present
# (its `#if`), a close for it stands after it, its rows are inside that bracket, and the block end is
# the last of 1039's seam lines, followed by the 1025 close 1038 carried (one TAB in: it closes 1025's
# arm, not the bracket -- the bracket's own close is at column 0, after 1037's block).
python3 -I $RS_PATCHER $XNU_TREE --verify | tail -1
python3 - "$TRAP_SRC" <<'PYLE'
import sys
t = open(sys.argv[1]).read()
SW = "STAGE90_XNU_WATCH_LE"
o = t.index("#if defined(%s) && %s\n" % (SW, SW))
c = t.find("#endif /* %s */" % SW, o)
assert c > o, "1038's arm never closes"
body = t[o:c]
assert "_wl_ss_slot(" in body and "wlg_need_" not in body, "1038's arm is not the arm, or the gate table is inside it"
e = t.index("#if 1   /* 1038 chunk: arm */", o)
assert e > c, "1038's arm chunk does not follow its switch"
assert "#endif /* 1038 chunk */\n#endif /* 1038 BLOCK END */\n\t#endif /* STAGE90_XNU_USTACK_PROBE */\n" in t, "1038's block does not end at its seam (chunk close, block end, 1025's arm as 1037 carries it)"
assert t.count("#define %s" % SW) == 0, "a switch define stands"
print("   1038's arm: behind its real switch, closed, its rows inside; the block ends at 1025's close")
PYLE
python3 -I "$CHECKER" --emitter-missing $PATCHER || { echo "FAIL: $PATCHER does not emit every row the reader needs"; exit 1; }

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
