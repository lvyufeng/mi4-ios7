#!/usr/bin/env bash
# Rebuild the trap.c layout that compiles, from the tree the rung chain leaves behind.
#
# WHY THIS EXISTS.  The rungs between the plan's compose and the pool each assume a layout that no
# single patcher writes:
#
#   - 1038 inlines the older arm text, one row carrying literal backslash-n, and its statics
#     definitions land INSIDE sleh_abort's body, where C forbids both a `static` function declaration
#     and a nested function definition;
#   - 1039's hook anchors on `thread_t thread = current_thread();`, which BOTH `sleh_abort` and
#     `sleh_undef` open with, so it lands in the wrong function - the one it never runs in;
#   - the statics block has to sit ABOVE the helpers that read `_wl_fi`, and `_wl_claim`'s prototype
#     ahead of its first call, or the deferred `static` clashes with the implicit one;
#   - `watch_le_switch.inc` already defines the switch behind `#ifndef`, so an inline
#     `#define STAGE90_XNU_WATCH_LE 1` in trap.c is a second definition.
#
# Each stage is a defect that belongs in its owner eventually.  This script is the record of the order
# that was measured to work, and it is safe to re-run: a stage whose defect is already fixed is
# skipped.
#
#   ./tools/replay-1039-trap-layout.sh <xnu_root>
#
# Precondition: the rung chain has staged (plan compose + the inherited seven + 1037 + 1038).
# Postcondition: `clang <the pool's argv> -c trap.c` exits 0 and the object carries the fcr rows.
set -euo pipefail
XNU=${1:?usage: replay-1039-trap-layout.sh <xnu_root>}
TRAP="$XNU/osfmk/arm/trap.c"
[[ -f $TRAP ]] || { echo "REFUSING: no $TRAP"; exit 1; }

python3 - "$TRAP" <<'PY'
import os, sys

tp = sys.argv[1]
lines = open(tp).read().split("\n")
did = []


def first(pred):
    return next((i for i, l in enumerate(lines) if pred(l)), None)


# (1) THE STALE INLINE ARM.  It is not C: the whole body is one row carrying literal backslash-n, and
#     it sits inside the function body. The arm the module uses is watch_le_arm.inc, included by the
#     hook.
s = first(lambda l: l.strip().startswith("#if 1   /* 1038 chunk: arm */"))
if s is not None:
    depth, end = 0, None
    for j in range(s, len(lines)):
        row = lines[j].strip()
        if row.startswith("#if"):
            depth += 1
        elif row.startswith("#endif"):
            depth -= 1
            if depth == 0:
                end = j
                break
    if end is None:
        sys.exit("stage 1 failed: the inline arm is unterminated")
    del lines[s:end + 1]
    did.append("inline arm dropped (%d rows)" % (end - s + 1))

# (2) THE STATICS BLOCK: file scope, and ABOVE the helpers that read `_wl_fi`.
s = first(lambda l: l.strip() == "#ifndef WATCH_LE_STATICS_DEFINED")
# **Only when it is still INSIDE a function.** Once the block has been hoisted it is at file scope, and
# moving it again would take its own `_wl_ss_slot` definition with it. Decided by what precedes it:
# sleh_abort's signature with no other top-level definition in between.
if s is not None:
    _sig = next((i for i, l in enumerate(lines) if l.startswith("void sleh_abort(void *context")), None)
    _inside = _sig is not None and s > _sig
if s is not None and _inside:
    end = next(i for i in range(s, len(lines))
               if lines[i].strip() == "#endif /* WATCH_LE_STATICS_DEFINED */")
    block = lines[s:end + 1]
    del lines[s:end + 1]
    # (the block is DELETED above, so the remaining `_wl_ss_slot` definition is the helper's own)
    t = first(lambda l: l.startswith("static unsigned _wl_ss_slot(unsigned *ctx)")
              and not l.rstrip().endswith(";"))
    if t is None:
        # **The block carries its own `_wl_ss_slot` definition.** Deleting it and then looking for a
        # definition to hoist in front of leaves nothing to find - so the block is put back untouched
        # rather than dropped. (Measured: the stage used to abort here, which took the whole rung down
        # with it on a tree where the hoist had already happened once.)
        lines[s:s] = block
        did.append("statics left in place (no separate definition to anchor on)")
    else:
        lines[t:t] = block
        lines.insert(t, "static unsigned _wl_claim(void);")
        did.append("statics hoisted in front of their users")

# (2b) THE DEFS INCLUDE.  It stands in the SEAT, i.e. inside sleh_abort, and the file it names
#      DEFINES the statics - so C rejects every one of them ("function declared in block scope
#      cannot have 'static' storage class", "function definition is not allowed here"), once per
#      definition, 1199 errors in all. It belongs at file scope, in front of the seat.
s = first(lambda l: l.strip() == '#include "watch_le_defs.inc"')
if s is not None:
    _sig = next((i for i, l in enumerate(lines) if l.startswith("void sleh_abort(void *context")), None)
    if _sig is not None and s > _sig:
        row = lines[s]
        del lines[s]
        _sig = next(i for i, l in enumerate(lines) if l.startswith("void sleh_abort(void *context"))
        # the ABSOLUTE spelling: a relative include resolves against the compiler's cwd
        row = row.replace('#include "watch_le_defs.inc"',
                          '#include "' + os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(tp))),
                                                    "arm", "watch_le_defs.inc") + '"')
        lines[_sig:_sig] = [row]
        did.append("the defs include moved to file scope, in front of sleh_abort")

# (2c) THE STATICS, WHERE THEY STAND.  1038 writes them into the function the hook was anchored in,
#      and that function is not always sleh_abort - `sleh_undef` opens with the same line - so they
#      land inside a function body, where C rejects every definition ("function declared in block
#      scope cannot have 'static' storage class"). They belong at file scope, in front of the seat.
s = first(lambda l: l.strip() == "#ifndef WATCH_LE_STATICS_DEFINED")
if s is not None:
    end = next(i for i in range(s, len(lines))
               if lines[i].strip() == "#endif /* WATCH_LE_STATICS_DEFINED */")
    # **Is it inside a function?** Decided by the nearest function signature above it and that
    # function's closing row (a `}` in column 0). Looking at the row before the block tells nothing:
    # the block is preceded by `#define WATCH_LE_H_STANDIN 1`, not by a `{`.
    _sig2 = None
    for _j in range(s - 1, -1, -1):
        if (lines[_j] and lines[_j][0] not in " \t"
                and "(" in lines[_j] and ")" in lines[_j]
                and not lines[_j].lstrip().startswith("#")):
            _sig2 = _j
            break
    _inside = False
    if _sig2 is not None:
        _close2 = next((j for j in range(_sig2 + 1, s) if lines[j] == "}"), None)
        _inside = _close2 is None          # no closing row before the block: still inside
    if _inside:
        block = lines[s:end + 1]
        del lines[s:end + 1]
        _sig = next(i for i, l in enumerate(lines) if l.startswith("void sleh_abort(void *context"))
        lines[_sig:_sig] = block
        did.append("the statics moved to file scope, in front of sleh_abort")

# (2d) THE INLINE HOOK FRAME, OUTSIDE ANY FUNCTION.  1038's older form inlined the hook's body
#      after the include; it names `reason` and `arm_ctx`, which exist only inside sleh_abort, so
#      standing outside it the compiler says "use of undeclared identifier 'reason'". The frame the
#      module uses is watch_le_hook.inc; this copy is redundant.
_c = first(lambda l: l.strip().startswith("/* 1038's HOOK"))
if _c is not None:
    _sig = next(i for i, l in enumerate(lines) if l.startswith("void sleh_abort(void *context"))
    _close = next((j for j in range(_sig + 1, len(lines)) if lines[j] == "}"), None)
    if _close is not None and _c > _close:
        _b = next(k for k in range(_c, len(lines)) if lines[k].strip() == "{")
        _d, _e = 0, None
        for j in range(_b, len(lines)):
            _d += lines[j].count("{") - lines[j].count("}")
            if _d == 0 and j > _b:
                _e = j
                break
        if _e is not None:
            del lines[_c:_e + 1]
            did.append("the inline hook frame outside sleh_abort dropped (%d rows)" % (_e - _c + 1))

# (2e) THE DEFS INCLUDE, ONCE MORE THAN TWICE.  Every rung that publishes rows includes the file,
#      and the file guards its statics with `#ifndef WATCH_LE_STATICS_DEFINED`, so the extra
#      placements compile to one definition - but the build's own gate allows two, and three is what
#      a fully staged tree comes to. Keep the first two (the file-scope copy the seat needs, and the
#      first block's), drop the rest.
# **Only the FILE-SCOPE copy may stay.** The file DEFINES functions, and a definition inside a
# function body is illegal ("function definition is not allowed here") - which is exactly what the
# ALL switch combination hits, because that is the one that compiles the hook, and the hook's
# include drags the defs in from wherever it stands. So: keep the first row that is at file scope,
# drop every other.
def _in_function(idx):
    sig = None
    for j in range(idx - 1, -1, -1):
        if (lines[j] and lines[j][0] not in " \t" and "(" in lines[j] and ")" in lines[j]
                and not lines[j].lstrip().startswith("#")):
            sig = j
            break
    if sig is None:
        return False
    return next((j for j in range(sig + 1, idx) if lines[j] == "}"), None) is None

_rows = [k for k, l in enumerate(lines) if "watch_le_defs.inc" in l and l.lstrip().startswith("#include")]
_keep = next((k for k in _rows if not _in_function(k)), None)
if _keep is not None:
    _drop = [k for k in _rows if k != _keep]
    for k in reversed(_drop):
        del lines[k]
    if _drop:
        did.append("defs include reduced to the file-scope copy (%d dropped)" % len(_drop))

# (3) THE SECOND DEFINE.
n = len([l for l in lines if l.strip() == "#define STAGE90_XNU_WATCH_LE 1"])
if n:
    lines = [l for l in lines if l.strip() != "#define STAGE90_XNU_WATCH_LE 1"]
    did.append("inline switch define removed (%d)" % n)

open(tp, "w").write("\n".join(lines))
print("   " + ("; ".join(did) if did else "trap.c: nothing to do (already in layout)"))
PY

# (4) THE HOOK'S FUNCTION.  Both `sleh_abort` and `sleh_undef` open with the anchor line, so the hook
#     can land in the one it never runs in. It belongs to sleh_abort.
python3 - "$TRAP" <<'PY'
import os, sys

tp = sys.argv[1]
# (ABSOLUTE: the compiler resolves an include against its own cwd, and the rung's includes in trap.c
#  are all absolute for exactly that reason - a relative one resolves only by luck)
XNU_HOOK = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(tp))), "arm", "watch_le_hook.inc")
lines = open(tp).read().split("\n")
i = next((k for k, l in enumerate(lines)
          if "watch_le_hook.inc" in l and l.lstrip().startswith("#include")), None)
if i is None:
    # **1038's include has to be there at all.** Removing the stale inline block took it with it once,
    # and nothing put it back - the object compiled but emitted none of the rung's rows. It belongs
    # right after sleh_abort's preamble, which is where 1038 anchors its frame.
    sig = next(k for k, l in enumerate(lines) if l.startswith("void sleh_abort(void *context"))
    pre = next((k for k in range(sig, len(lines))
                if lines[k].strip() == "thread_t thread = current_thread();"), None)
    if pre is None:
        sys.exit("stage 4 failed: sleh_abort's preamble not found")
    lines.insert(pre + 1,
                 '\t#include "' + XNU_HOOK + '"')
    open(tp, "w").write("\n".join(lines))
    print("   trap.c: hook include inserted after the preamble")
    sys.exit(0)
sig = next(k for k, l in enumerate(lines) if l.startswith("void sleh_abort(void *context"))
undef = next((k for k, l in enumerate(lines) if l.startswith("void sleh_undef(")), len(lines))
# **sleh_abort ends at the first row that is exactly `}` in column 0.** Counting braces does not
# work here: the function's body carries preprocessor blocks whose rows open and close braces of
# their own, so a depth count reaches zero long before the function does and the hook was judged
# "inside sleh_abort" while it stood 500 rows below the real closing brace.
close = next((j for j in range(sig + 1, undef) if lines[j] == "}"), None)
if close is None:
    sys.exit("stage 4 failed: sleh_abort's closing brace not found")
if i < close:
    print("   trap.c: the hook is already inside sleh_abort")
    sys.exit(0)
row = lines[i]
del lines[i]
if close > i:
    close -= 1
lines[close:close] = [row]
open(tp, "w").write("\n".join(lines))
print("   trap.c: the hook include moved into sleh_abort")
PY

echo "replay done: $TRAP"