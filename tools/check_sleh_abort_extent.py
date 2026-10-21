#!/usr/bin/env python3
"""Report where `sleh_abort` ends in trap.c, and whether `doexception` is still inside it.

WHY.  `check_fault_recovery.py`'s D13 claim slices the function with
`\\bvoid\\s+sleh_abort\\s*\\([^)]*\\)\\s*\\{(.*?)\\n\\}` - non-greedy to the first `\\n}`, i.e. the first
closing brace in column 0 - and then asks that slice for `doexception(`.  When a rung's block ends up
OUTSIDE the function, that brace closes `sleh_abort` early: the claim then reads a body that stops
before the handler's own tail and reports "`sleh_abort` no longer calls `doexception()`" on a tree
where the three calls are present and correct, 500 lines further down.

This tool answers the question directly, without the claim's own slicing:

  * the line of `void sleh_abort(...)`, of `void sleh_undef(`, and of the first column-0 `}` after
    the signature;
  * how many `doexception(` calls fall between the signature and that brace, and how many fall
    between the brace and `sleh_undef` - the second number is code that has escaped the function;
  * whether that second number is non-zero, which is the defect: NO rung may end `sleh_abort` before
    its own tail.

    tools/check_sleh_abort_extent.py <tree>/osfmk/arm/trap.c
"""
import re
import sys


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 2
    lines = open(argv[1]).read().split("\n")
    sig = next((k for k, l in enumerate(lines) if re.match(r"^void\s+sleh_abort\s*\(", l)), None)
    undef = next((k for k, l in enumerate(lines) if re.match(r"^void\s+sleh_undef\s*\(", l)), len(lines))
    if sig is None:
        print("no `void sleh_abort(` at column 0 - the function is not in this file")
        return 1
    close = next((k for k in range(sig + 1, undef) if lines[k] == "}"), None)
    if close is None:
        print("no column-0 `}` between sleh_abort and sleh_undef - the function never closes")
        return 1
    inside = sum(1 for l in lines[sig:close] if "doexception(" in l)
    escaped = sum(1 for l in lines[close:undef] if "doexception(" in l)
    print("sleh_abort   at line %d" % (sig + 1))
    print("first `}`     at line %d   (%d rows of body)" % (close + 1, close - sig))
    print("sleh_undef   at line %d" % (undef + 1))
    print("doexception inside the function: %d" % inside)
    print("doexception between the function's close and sleh_undef: %d" % escaped)
    if escaped:
        print("")
        print("DEFECT: %d `doexception(` call(s) stand OUTSIDE sleh_abort. A rung's block ends past"
              % escaped)
        print("        the function's own close, so the first column-0 `}` closes it early - and")
        print("        check_fault_recovery reports 'no longer calls doexception()' for a tree where")
        print("        the calls are present. The block(s) that run past the close are the thing to")
        print("        move back inside it.")
        return 1
    if inside == 0:
        print("")
        print("DEFECT: the function carries no `doexception(` call at all.")
        return 1
    print("")
    print("OK: every `doexception(` call is inside the function's own body.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
