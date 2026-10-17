#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Stage 1028's H2 FIX into the D13 tree: give the initial user-stack block one word of headroom.

THE DEFECT THIS FIXES, BY VALUE (docs/1028-design.md, records/1027-press-read.txt).

  1027 read H2 (off-the-end) at the launchctl[2] stack fault:

      lookup_far=0  far_in_map=1  entry=[0,0)  e2=[0x2bce1000,0x2bde0000)
      e2_hi == far == ustack == 0x2bde0000     map == taskmap == 0xc0005688

  The user-stack region is `[0x2bce1000, 0x2bde0000)`, its EXCLUSIVE TOP is `far`, and the word just
  below (far-4) IS mapped.  A write AT `far` is a write ONE WORD PAST the region's end.

  By source, `create_unix_stack` sets `p->user_stack` to the requested top and allocates the region
  `[user_stack - size, user_stack)` -- the region's exclusive top IS `p->user_stack`.  Then
  `exec_copyout_strings` places the initial argv/env block with its TOP at `*stackp` (= `p->user_stack`),
  so the block's last byte is `user_stack - 1` and the word AT `user_stack` is UNOWNED.  The layout
  comment (kern_exec.c 2596-2610) even draws a "16b" reserved slot there that the placement never leaves
  room for.  The measured 1025 rows (`xnu_live_ustack_rc=0`, FIXED allocate succeeded) fix the geometry:
  the region top and the block top coincide.

THE FIX.  In the FIXED `mach_vm_allocate` only, pass `size + 16` instead of `size`, anchored so the
region's TOP moves UP by 16 while the base, the block, `sp`, `p->user_stack`, and the guard math are
unchanged.  The region then OWNS the word at `user_stack` that userspace touches.

WHY A PATCH, NOT A HAND EDIT.  `external/` is a re-provisionable gitignored checkout; every edit a build
makes to it must be a script a re-checkout re-applies (the `stage_d13_*.sh` rule).

IDEMPOTENT + REFUSING.  The patcher refuses unless the tree is in the state it was written against (the
anchor's occurrence count is EXACTLY 1 and the switch is ABSENT on the first apply, PRESENT on a re-run);
writes nothing on a refusal; a second `--apply` is a no-op; and `--verify-off` proves the OFF arm compiles
the ORIGINAL call (the `patch_d13_vm_max_split.py` idiom).

CLI:  <xnu_root>             plan (write nothing)
      <xnu_root> --apply      write
      <xnu_root> --verify-off prove OFF == original
"""
import sys
import os
import re

REL = "bsd/kern/kern_exec.c"
SWITCH = "STAGE90_XNU_H2_STACK_HEADROOM"
HEADROOM = 16

# The FIXED-allocation anchor.  Unique in the file.  We replace exactly this block.
ANCHOR = (
    "\t\taddr = mach_vm_trunc_page(load_result->user_stack - size);\n"
    "\t\tkr = mach_vm_allocate(map, &addr, size,\n"
    "\t\t\t\t\tVM_MAKE_TAG(VM_MEMORY_STACK) |\n"
    "\t\t\t\t\tVM_FLAGS_FIXED);\n"
)

# The replacement: the SAME base computation, then an #if/#else that chooses the allocation extent.
# With the switch OFF the #else branch reproduces the ORIGINAL call BYTE-FOR-BYTE (same whitespace), so
# `--verify-off` reads the tree's original bytes.
REPLACEMENT = (
    "\t\taddr = mach_vm_trunc_page(load_result->user_stack - size);\n"
    "#if defined({S}) && {S}\n"
    "\t\t/* 1028 (H2 fix): reserve a word of headroom ABOVE the block.  The region's exclusive top\n"
    "\t\t * moves ABOVE user_stack (mach_vm_allocate rounds the extent up: the top lands at\n"
    "\t\t * user_stack + PAGE_SIZE, not + HEADROOM), so the block (top = user_stack, from\n"
    "\t\t * exec_copyout_strings) no longer ends flush with the region end and the word at\n"
    "\t\t * user_stack -- which userspace touches -- is OWNED by the region.  Base unchanged, guard\n"
    "\t\t * (prot_addr == addr) unchanged, block unchanged, p->user_stack (the value userspace sees)\n"
    "\t\t * UNCHANGED.  docs/1028-design.md 3, 5. */\n"
    "\t\tkr = mach_vm_allocate(map, &addr, size + {H},\n"
    "\t\t\t\t\tVM_MAKE_TAG(VM_MEMORY_STACK) |\n"
    "\t\t\t\t\tVM_FLAGS_FIXED);\n"
    "#else\n"
    "\t\tkr = mach_vm_allocate(map, &addr, size,\n"
    "\t\t\t\t\tVM_MAKE_TAG(VM_MEMORY_STACK) |\n"
    "\t\t\t\t\tVM_FLAGS_FIXED);\n"
    "#endif /* {S} */\n"
).format(S=SWITCH, H=HEADROOM)


def read(p):
    with open(p) as f:
        return f.read()


def write(p, t):
    with open(p, "w") as f:
        f.write(t)


def if_stage90_ids(text):
    ids = set()
    for m in re.finditer(r"^\s*#\s*(?:if|elif|ifdef|ifndef)\b(.*)$", text, re.M):
        for ident in re.findall(r"[A-Za-z_][A-Za-z0-9_]*", m.group(1)):
            if ident.startswith("STAGE90_"):
                ids.add(ident)
    return ids


# kern_exec.c's STAGE90 namespace is shared by 1025 (xnu_live_ustack_* publisher) and 1026 (the
# xnu_live_abt_proc_ustack accessor).  This rung adds its own switch; all three must be allowed to
# coexist or the shared-namespace check refuses ([[mi4-one-file-many-rungs]]).
ALLOWED_STAGE90 = {
    "STAGE90_XNU_USTACK_PROBE",       # 1025
    "STAGE90_XNU_ABT_ENTRY_PROBE",    # 1026
    "STAGE90_XNU_H2_STACK_HEADROOM",  # 1028 (this rung)
    "STAGE90_XNU_READER_PROBE",       # 1029 (tools/patch_d13_reader_probe.py)
}


def exe_path(xnu):
    return os.path.join(xnu, REL)


def check(xnu):
    """Return (ok, path, text, message).  ok False => refuse, write nothing."""
    p = exe_path(xnu)
    if not os.path.isfile(p):
        return False, p, "", f"no {p} (D13 tree not provisioned?)"
    t = read(p)
    if SWITCH in t:
        return True, p, t, "already staged"
    foreign = sorted(i for i in if_stage90_ids(t) if i not in ALLOWED_STAGE90)
    if foreign:
        return False, p, t, (
            f"{REL}'s directives also evaluate {', '.join(foreign)}. kern_exec.c's STAGE90 identifiers "
            f"are a SHARED namespace (1025/1026/1028): this rung must add its switch to the other "
            f"patchers' sets. ([[mi4-one-file-many-rungs]])")
    if t.count(ANCHOR) != 1:
        return False, p, t, (
            f"the FIXED-allocation anchor occurs {t.count(ANCHOR)} time(s), expected exactly 1. "
            f"The tree is not in the state this rung was written against (a displaced anchor, a "
            f"partial edit, or a hand-edited region).")
    return True, p, t, "anchor unique, switch absent"


def stage(xnu, do_apply):
    ok, p, t, msg = check(xnu)
    if not ok:
        print(f"patch_d13_h2_stack_headroom: REFUSE - {msg}. Writing nothing.", file=sys.stderr)
        return 1
    if msg == "already staged":
        print("patch_d13_h2_stack_headroom: already staged - no-op, OK.")
        return 0
    print(f"   kern_exec.c: {msg}.")
    if not do_apply:
        print("patch_d13_h2_stack_headroom: plan OK (dry run; pass --apply to write).")
        return 0
    write(p, t.replace(ANCHOR, REPLACEMENT))
    print(f"   kern_exec.c: staged the H2 headroom (FIXED mach_vm_allocate extent = size + {HEADROOM}).")
    return 0


def verify_off(xnu):
    """Prove the OFF arm compiles the ORIGINAL call: with the switch unset the #else branch is taken,
    whose bytes are the anchor's original text.  We check by TEXT (the branch bodies), which is exact
    for this edit -- no preprocessor needed, and no harness that could lie."""
    p = exe_path(xnu)
    t = read(p)
    if SWITCH not in t:
        print("patch_d13_h2_stack_headroom: --verify-off: switch ABSENT (nothing staged).", file=sys.stderr)
        return 1
    # The #else arm must contain the ORIGINAL call exactly.
    orig = ("\t\tkr = mach_vm_allocate(map, &addr, size,\n"
            "\t\t\t\t\tVM_MAKE_TAG(VM_MEMORY_STACK) |\n"
            "\t\t\t\t\tVM_FLAGS_FIXED);\n")
    on = ("\t\tkr = mach_vm_allocate(map, &addr, size + %d,\n" % HEADROOM)
    have_off = t.count(orig) == 1
    have_on = t.count(on) == 1
    have_else = t.count("#else\n") >= 1 and t.count(f"#endif /* {SWITCH} */") == 1
    print(f"   kern_exec.c [OFF]: the #else arm carries the ORIGINAL call: {have_off}")
    print(f"   kern_exec.c [ON] : the guarded arm carries size + {HEADROOM}: {have_on}")
    print(f"   kern_exec.c      : a #else/#endif pair brackets them: {have_else}")
    if have_off and have_on and have_else:
        print(f"patch_d13_h2_stack_headroom: --verify-off PASS (OFF takes the #else arm == original bytes; "
              f"ON takes size + {HEADROOM}).")
        return 0
    print("patch_d13_h2_stack_headroom: --verify-off FAIL.", file=sys.stderr)
    return 1


def main(argv):
    if len(argv) < 2:
        print("usage: patch_d13_h2_stack_headroom.py <xnu_root> [--apply|--verify-off]", file=sys.stderr)
        return 2
    xnu = argv[1]
    if "--verify-off" in argv:
        return verify_off(xnu)
    return stage(xnu, do_apply="--apply" in argv)


if __name__ == "__main__":
    sys.exit(main(sys.argv))