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
import sys

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
        sys.exit("stage 2 failed: _wl_ss_slot's definition not found")
    lines[t:t] = block
    lines.insert(t, "static unsigned _wl_claim(void);")
    did.append("statics hoisted in front of their users")

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
import sys

tp = sys.argv[1]
lines = open(tp).read().split("\n")
i = next((k for k, l in enumerate(lines)
          if "watch_le_hook.inc" in l and l.lstrip().startswith("#include")), None)
if i is None:
    print("   trap.c: no hook include")
    sys.exit(0)
sig = next(k for k, l in enumerate(lines) if l.startswith("void sleh_abort(void *context"))
undef = next((k for k, l in enumerate(lines) if l.startswith("void sleh_undef(")), len(lines))
depth, close = 0, None
for j in range(sig, undef):
    depth += lines[j].count("{") - lines[j].count("}")
    if depth == 0 and j > sig and lines[j].strip() == "}":
        close = j
        break
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