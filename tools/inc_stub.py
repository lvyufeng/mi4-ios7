#!/usr/bin/env python3
"""Create an empty stand-in file for every `#include` a translation unit names.

`cpp_probe()` in patch_d13_dyld_witness.py (and its callers) run the REAL preprocessor over a whole
trap.c with `-nostdinc`: the point is to ask the preprocessor what the directive structure resolves
to, not to have the tree's headers participate. Reaching the real headers instead would drag in
XNU's include graph and answer a different question - and would need the compiler's own search path,
which is exactly what is being tested.

So every include is resolved to an empty file, in a directory given to clang with `-I`.

    inc_stub.stub([...names...], Path("/tmp/inc_tag"))

A name that carries a directory (`arm/misc_protos.h`) gets that directory made too, so the
include's own spelling still resolves.
"""
import os


def stub(names, root):
    """Make `root` hold an empty file for every name in `names`; returns `root` as a str."""
    root = str(root)
    os.makedirs(root, exist_ok=True)
    for name in names:
        path = os.path.join(root, name)
        parent = os.path.dirname(path)
        if parent:
            os.makedirs(parent, exist_ok=True)
        # (an existing file is left alone: the caller may have written real content for one)
        if not os.path.exists(path):
            with open(path, "w"):
                pass
    return root