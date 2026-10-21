#!/usr/bin/env python3
"""Stage a chained rung's trap.c half when its OTHER file is already staged.

The inherited rungs (abt_entry .. pc_carrier_caller) each edit trap.c and some also edit
kern_exec.c. Their patchers refuse a PARTIAL state - one file staged, the other not - because that
is a half-applied edit, and their own remedy is `git checkout` the staged file. That remedy is
wrong here: kern_exec.c carries several rungs at once, so reverting it to satisfy one of them
throws away the others.

So when `stage()` refuses as PARTIAL and the trap.c done-mark is still absent, the trap half is
applied on its own, through the patcher's own `plan_file()` / `apply_file()` and its own anchor.

    tools/stage_trap_half.py <xnu_root> <rung-name>        # e.g. abt_entry_probe
    tools/stage_trap_half.py <xnu_root> --chain            # the whole chain, in order

Exit 0 when every rung it was asked for is staged (by either path), 1 otherwise.
"""
import importlib.util
import os
import sys

CHAIN = ("abt_entry_probe", "reader_probe", "writer_probe", "caller_probe",
         "eval_frame", "pc_carrier", "pc_carrier_caller")


def _load(name):
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "patch_d13_%s.py" % name)
    spec = importlib.util.spec_from_file_location("_c_%s" % name, path)
    mod = importlib.util.module_from_spec(spec)
    sys.modules["_c_%s" % name] = mod
    spec.loader.exec_module(mod)
    return mod


def _trap_half(mod, xnu, name):
    """Apply just the trap.c side, if it is not there yet."""
    tp = os.path.join(xnu, "osfmk", "arm", "trap.c")
    text = open(tp).read()
    if mod.DONE_MARK in text:
        return "already in trap.c"
    anchor = mod._anchor(text) if hasattr(mod, "_anchor") else mod.INSERT_AFTER
    if text.count(anchor) != 1:
        return "anchor occurs %d time(s) - not this tree" % text.count(anchor)
    block = getattr(mod, "TRAP_BLOCK", None) or getattr(mod, "BLOCK", None)
    if block is None:
        return "no block text on the patcher"
    ok, msg = mod.plan_file("trap.c", text,
                            [("leo_installd_fault_result", mod.ANCHOR_GUARD, 1),
                             ("parent_gate", mod.ANCHOR_PARENT, 1)],
                            anchor, mod.DONE_MARK, before=False)
    if not ok:
        return msg
    mod.apply_file("trap.c", tp, anchor, block, False, "trap half for %s" % name)
    return "staged (trap half)"


def stage_one(name, xnu):
    mod = _load(name)
    rc = mod.stage(xnu, True)
    if rc == 0:
        return True, "staged"
    # PARTIAL, or a refusal the trap half can still satisfy
    msg = _trap_half(mod, xnu, name)
    return (mod.DONE_MARK in open(os.path.join(xnu, "osfmk", "arm", "trap.c")).read()), msg


def main(argv):
    if len(argv) < 3:
        print(__doc__)
        return 2
    xnu = argv[1]
    names = CHAIN if argv[2] == "--chain" else (argv[2],)
    bad = 0
    for name in names:
        ok, why = stage_one(name, xnu)
        print("   %-20s %s%s" % (name, why, "" if ok else "  <- FAILED"))
        if not ok:
            bad += 1
            break                      # the chain is ordered: a gap stops the rest
    return 0 if bad == 0 else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))