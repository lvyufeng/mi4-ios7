#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Stage 1025's USER-STACK FAULT PROBE into the D13 tree: publish what `vm_fault` RETURNED.

THE FAULT THIS ANSWERS, BY VALUE (docs/1025-design.md, records/1025-source-trace.txt,
records/1024b-frontier-launchctl-crash.txt).

  1024's own boot (records/1024b, and the arm-identity settlement in
  records/1025-globalfix-carrier.txt section 6) reached `*** launchd[1] has started up ***`, spawned
  pid 2 `launchctl`, and died in a USERSPACE DATA ABORT on a STACK VA:
      launchctl[2]: usermode data abort, EXC_BAD_ACCESS at 0x2bdbe000 ... (Translation fault on page)
  with r4=r6=0x2bdbe000, sp=0x2bdbd074, cpsr=0xa0000030 (Thr/usr).  0x2bdbe000 is INSIDE the fixed
  stack window [0x2BD00000, 0x2BE00000) that `create_unix_stack` allocates; `sp` at 0x2bdbd074 shows
  the FIXED allocation SUCCEEDED (no ANYWHERE fallback; records/1025-source-trace.txt section 3-4).

  So a page that SHOULD be mapped and WAS written is TRANSLATION-faulting.  In `osfmk/arm/trap.c`
  the usermode-data-abort path CALLS `vm_fault` and, on a non-SUCCESS return, PRINTS the abort and
  delivers `EXC_BAD_ACCESS`:
      trap.c:806  code = vm_fault(map, vm_map_trunc_page(dfar), ...);
      trap.c:809  if ((code != KERN_SUCCESS) && (code != KERN_ABORTED)) {
      trap.c:810  #if BOARD_CONFIG_QSD8250_LEO
      trap.c:813      leo037_data_error = code;          <-- the ONE assignment of `code`
      trap.c:814  #endif
  On CANCRO `BOARD_CONFIG_QSD8250_LEO` is 0, so **the value that names WHY (`code`) is DISCARDED** -
  the capture prints the register dump but never the `vm_fault` return.  That number is the whole
  frontier: `KERN_MEMORY_ERROR` (the anon object could not produce the page), `KERN_PROTECTION_FAILURE`
  (a permission/execute-eligibility refusal), `KERN_INVALID_ADDRESS` (no entry covers the VA when the
  fault walks - the 1013c/1015 class).  This patch publishes it.

  AND the stack-placement side: `create_unix_stack` (bsd/kern/kern_exec.c) decides, per exec, the
  stack's size/addr/prot and whether the FIXED allocation succeeded.  Publishing those turns the
  by-value claim of records/1025-source-trace.txt ("the FIXED alloc succeeded") into a NUMBER in the
  capture the press reads.

THE EDIT - TWO PUBLISHERS, EACH ONE INSERTED LINE-BLOCK, EACH `#if`-SO-GATED THAT OFF = BYTE-IDENTICAL.

  (A) osfmk/arm/trap.c, inside the `if ((code != KERN_SUCCESS) && (code != KERN_ABORTED)) {` arm of the
      usermode DATA abort (right after the `#endif` of the BOARD_CONFIG_QSD8250_LEO block, BEFORE the
      printf):  a guarded `#if defined(STAGE90_XNU_USTACK_PROBE) && STAGE90_XNU_USTACK_PROBE` block that
      prints
          xnu_live_abt_vmfkrv=<code> xnu_live_abt_vmfkrv_far=<dfar> xnu_live_abt_vmfkrv_dfsr=<dfsr>
          xnu_live_abt_vmfkrv_prot=<r|w> xnu_live_abt_vmfkrv_pid=<pid> xnu_live_abt_vmfkrv_sp=<sp>
          xnu_live_abt_vmfkrv_pc=<pc>
      via `printf("xnu_live_abt_vmfkrv=%d\n", code)`-style lines the ram console captures.  These are
      NOT the `entry_write_kv` DIRECT-channel keys (this is the KERNEL's own printf, the same channel
      `IOS7LAB` uses); the design's `entry_write_kv` route is the ENTRY-side mechanism and is not
      reachable from trap.c.  The design's key NAMES are kept, so the checker reads them either way.

  (B) bsd/kern/kern_exec.c, inside `create_unix_stack` after the FIXED `mach_vm_allocate` and after the
      guard `mach_vm_protect`: a guarded `#if defined(STAGE90_XNU_USTACK_PROBE) && STAGE90_XNU_USTACK_PROBE`
      block that prints
          xnu_live_ustack_req=<user_stack> xnu_live_ustack_size=<size>
          xnu_live_ustack_fixed_addr=<addr> xnu_live_ustack_rc=<kr>
          xnu_live_ustack_final=<p->user_stack> xnu_live_ustack_prot_addr=<prot_addr>
          xnu_live_ustack_prot_size=<prot_size>

  Both are guarded so `defined()` is checked FIRST (`defined(X) && X`): with the switch off the tree
  compiles its ORIGINAL bytes exactly ([[mi4-off-option-two-spellings]]).  With `-DSTAGE90_XNU_USTACK_PROBE=1`
  (a GLOBAL DEFINES entry in tools/build_xnu_arm_kernel.sh, so every TU that includes the file sees it)
  the block is compiled in.  The switch is NOT a header edit, so it does not move the `vm_param.h`
  ceiling; it changes only the two pool objects (osfmk_arm_trap.o, bsd_kern_kern_exec.o), which is why
  the 1025 by-value clause reads THOSE objects and not `osfmk_kern_task.o`.

WHY A PATCH AND NOT A HAND EDIT.  `external/` is a re-provisionable gitignored checkout; every edit a
build makes to it must be a script a re-checkout re-applies (the `stage_d13_*.sh` rule).

IDEMPOTENT + REFUSING.  The patcher: (i) refuses if the tree is not in the state it was written against
(each anchor's occurrence count must be EXACTLY 1 and the done-mark must be ABSENT on the first apply,
PRESENT on a re-run); (ii) writes nothing on a refusal; (iii) a second `--apply` is a no-op; (iv) the
`--verify-off` arm re-proves BOTH files compile to their ORIGINAL bytes with the switch unset (the
`patch_d13_vm_max_split.py` idiom).  A partial (one-file) edit is a refusal, never a half-application.

CLI:  <xnu_root>            (plan: print what it WOULD do, write nothing)
      <xnu_root> --apply     (write, after the OFF proof reverts on failure)
      <xnu_root> --verify-off (proof that OFF == the tree's original bytes)
"""
import sys
import os
import re

# ---------------------------------------------------------------------------------------------------
# THE SHARED DIRECTIVE-IDENTIFIER NAMESPACE OF osfmk/arm/trap.c ([[mi4-one-file-many-rungs]]).
#
# A file's `#if` identifiers are a SINGLE namespace shared by every patcher that edits that file.
# trap.c is edited by FOUR rungs: 994 (tools/patch_d13_dyld_witness.py, STAGE90_XNU_DYLD_WITNESS),
# 1020 (tools/patch_d13_undef_raise.py, STAGE90_XNU_UNDEF_RAISE), 1025 (this script,
# STAGE90_XNU_USTACK_PROBE) and 1026 (tools/patch_d13_abt_entry_probe.py,
# STAGE90_XNU_ABT_ENTRY_PROBE, whose block is nested INSIDE this script's).  Each patcher's
# `--verify-off` drives the OTHER switches as `undefined`, so OFF byte-identity still holds; the
# ALLOW-LIST is what makes the edits compose instead of one patcher refusing the file because a
# sibling's identifier looks like it "may come from a header".  A new rung that edits trap.c MUST add
# its switch HERE (and to the other three patchers' sets) or the OFF proof of every other patcher
# refuses the tree.
TRAP_ALLOWED_IF_IDENTIFIERS = {
    "BOARD_CONFIG_QSD8250_LEO",
    "BOARD_CONFIG_ARMPBA8",
    "STAGE90_XNU_DYLD_WITNESS",     # 994  (tools/patch_d13_dyld_witness.py)
    "STAGE90_XNU_GLOBAL_FIX",       # 1015b (fires in pmap.c, allowed here for the shared proof)
    "STAGE90_XNU_UNDEF_RAISE",      # 1020 (tools/patch_d13_undef_raise.py)
    "STAGE90_XNU_IOS7_TRAPS",       # 1023 (row-24 gate, drives mach_trap.c; allowed for the proof)
    "STAGE90_XNU_USTACK_PROBE",     # 1025 (this script)
    "STAGE90_XNU_ABT_ENTRY_PROBE",  # 1026 (tools/patch_d13_abt_entry_probe.py)
    "STAGE90_XNU_H2_STACK_HEADROOM",  # 1028 (tools/patch_d13_h2_stack_headroom.py; edits kern_exec.c)
    "STAGE90_XNU_READER_PROBE",     # 1029 (tools/patch_d13_reader_probe.py)
    "STAGE90_XNU_WRITER_PROBE",  # 1030 (tools/patch_d13_writer_probe.py)
    "STAGE90_XNU_CALLER_PROBE",  # 1031 (tools/patch_d13_caller_probe.py)
    "STAGE90_XNU_EVAL_FRAME",  # 1033 (tools/patch_d13_eval_frame.py)
    "STAGE90_XNU_PC_CARRIER",  # 1035 (tools/patch_d13_pc_carrier.py)
}
_DIRECTIVE = re.compile(r"^[ \t]*#[ \t]*(?:if|elif|ifdef|ifndef)\b(.*)$", re.M)
_IDENT = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
_WORDS = {"defined", "if", "elif", "ifdef", "ifndef"}


def if_identifiers(text):
    return {w for expr in _DIRECTIVE.findall(text) for w in _IDENT.findall(expr) if w not in _WORDS}

# ---------------------------------------------------------------------------------------------------
# (A) trap.c -- the vm_fault return-code publisher
# ---------------------------------------------------------------------------------------------------
TRAP_REL = "osfmk/arm/trap.c"

# The anchor: the LEO guarded assignment block that ENDS the code-discard.  We insert AFTER its
# `#endif`, i.e. the last line of the LEO block.  The `code =` call + the `if ((code != ...` line
# above it pin the region so the anchor cannot match elsewhere.
TRAP_ANCHOR_TAIL = (
    "                    if(leo037_data_snapshot.valid)\n"
    "                        ios7leo037_data_after_vm(&leo037_data_snapshot,arm_ctx,thread);\n"
    "#endif\n"
)
# A line EARLIER in the same arm, unique in the file, proving we are at the right `if`.  NOTE: the
# `code = vm_fault(map, vm_map_trunc_page(dfar), ...)` call appears TWICE (the KERNEL data-abort case
# at :657 and the USER data-abort case at :829) - so the call line is NOT a unique anchor.  The LEO
# assignment `leo_installd_fault_result=code;` occurs EXACTLY ONCE, inside the usermode case's `if`,
# and it is the statement that discards the value; that is the right pin.
TRAP_ANCHOR_GUARD = "                if ((code != KERN_SUCCESS) && (code != KERN_ABORTED)) {\n"
TRAP_ANCHOR_CALL = "                    leo_installd_fault_result=code;\n"

TRAP_BLOCK = (
    "#if defined(STAGE90_XNU_USTACK_PROBE) && STAGE90_XNU_USTACK_PROBE\n"
    "                    /* 1025: the value the tree DISCARDS on CANCRO.  The failed fault that names\n"
    "                     * the launchctl[2] stack frontier (0x2bdbe000) is a usermode data abort whose\n"
    "                     * `code` names WHY (KERN_MEMORY_ERROR / KERN_PROTECTION_FAILURE /\n"
    "                     * KERN_INVALID_ADDRESS); the ONLY assignment in this arm is inside\n"
    "                     * BOARD_CONFIG_QSD8250_LEO, so on CANCRO it is discarded.  Publish it on the\n"
    "                     * kernel's own ram-console channel (the same one IOS7LAB uses). */\n"
    "                    printf(\"xnu_live_abt_vmfkrv=%d\\n\", (int)code);\n"
    "                    printf(\"xnu_live_abt_vmfkrv_far=0x%08x\\n\", (unsigned)vm_map_trunc_page(dfar));\n"
    "                    printf(\"xnu_live_abt_vmfkrv_dfsr=0x%08x\\n\", (unsigned)dfsr);\n"
    "                    printf(\"xnu_live_abt_vmfkrv_prot=%s\\n\", (dfsr & 0x800) ? \"write\" : \"read\");\n"
    "                    printf(\"xnu_live_abt_vmfkrv_pc=0x%08x\\n\", (unsigned)arm_ctx->pc);\n"
    "                    printf(\"xnu_live_abt_vmfkrv_sp=0x%08x\\n\", (unsigned)arm_ctx->sp);\n"
    "                    printf(\"xnu_live_abt_vmfkrv_pid=%d\\n\", "
    "(thread->task->bsd_info ? proc_pid(thread->task->bsd_info) : -1));\n"
    "#endif /* STAGE90_XNU_USTACK_PROBE */\n"
)
TRAP_DONE_MARK = "xnu_live_abt_vmfkrv="

# ---------------------------------------------------------------------------------------------------
# (B) kern_exec.c -- the stack-placement publisher
# ---------------------------------------------------------------------------------------------------
EXEC_REL = "bsd/kern/kern_exec.c"

# The anchor: the guard `mach_vm_protect` block's tail, inside create_unix_stack.  Unique by the two
# statements above it (prot_size assignment + the protect call).  We insert BEFORE the function's final
# `return KERN_SUCCESS;` -- so the publisher is REACHABLE (a block placed AFTER the return is dead code
# and a `static` function's dead code is eliminated WHOLE, strings and all: the first 1025 build's
# kern_exec.o carried no `xnu_live_ustack_req=` string for exactly this reason).
EXEC_ANCHOR_TAIL = (
    "\t\tif (kr != KERN_SUCCESS) {\n"
    "\t\t\t(void) mach_vm_deallocate(map, addr, size);\n"
    "\t\t\treturn kr;\n"
    "\t\t}\n"
    "\t}\n"
    "\n"
)
EXEC_ANCHOR_RETURN = "\treturn KERN_SUCCESS;\n"
EXEC_ANCHOR_GUARD0 = "\tif (!load_result->prog_allocated_stack) {\n"
EXEC_ANCHOR_PROT = "\t\t\tprot_size = mach_vm_trunc_page(size - unix_stack_size(p));\n"

EXEC_BLOCK = (
    "#if defined(STAGE90_XNU_USTACK_PROBE) && STAGE90_XNU_USTACK_PROBE\n"
    "\t/* 1025: the stack's shape, by value.  `req` is the requested top (load_result->user_stack),\n"
    "\t * `size` the rounded window, `fixed_addr` the FIXED target passed to mach_vm_allocate, `rc`\n"
    "\t * the return the FIXED call produced, `final` the address p->user_stack settled on, and the\n"
    "\t * guard geometry.  This turns records/1025-source-trace.txt's by-value claim (\"the FIXED alloc\n"
    "\t * succeeded\") into a NUMBER in the press's capture.  GUARDED on the branch that OWNS these\n"
    "\t * values (`addr`/`kr`/`size`/`prot_*` are only set inside `!prog_allocated_stack`); printing\n"
    "\t * them out of the branch would read uninitialised locals. */\n"
    "\tif (!load_result->prog_allocated_stack) {\n"
    "\t\tprintf(\"xnu_live_ustack_req=0x%08x\\n\", (unsigned)load_result->user_stack);\n"
    "\t\tprintf(\"xnu_live_ustack_size=0x%08x\\n\", (unsigned)size);\n"
    "\t\tprintf(\"xnu_live_ustack_fixed_addr=0x%08x\\n\", (unsigned)addr);\n"
    "\t\tprintf(\"xnu_live_ustack_rc=%d\\n\", (int)kr);\n"
    "\t\tprintf(\"xnu_live_ustack_final=0x%08x\\n\", (unsigned)p->user_stack);\n"
    "\t\tprintf(\"xnu_live_ustack_prot_addr=0x%08x\\n\", (unsigned)prot_addr);\n"
    "\t\tprintf(\"xnu_live_ustack_prot_size=0x%08x\\n\", (unsigned)prot_size);\n"
    "\t}\n"
    "#endif /* STAGE90_XNU_USTACK_PROBE */\n"
    "\n"
)
EXEC_DONE_MARK = "xnu_live_ustack_req="


def read(path):
    with open(path, "r") as f:
        return f.read()


def write(path, text):
    with open(path, "w") as f:
        f.write(text)


def count(text, needle):
    return text.count(needle)


def plan_file(label, text, anchors, insert_after, block, done_mark):
    """Return (ok, message).  ok False => refuse, write nothing."""
    # The done-mark is checked FIRST, before the anchors: a file that already carries this publisher
    # contributes ITS OWN block to the anchor's occurrence count (EXEC_BLOCK opens with the same
    # `if (!load_result->prog_allocated_stack) {` the `guard0` anchor counts), so an anchor check
    # run on an already-staged file counts the publisher against itself and refuses a tree this
    # script itself wrote.  "Already staged" is the idempotent case, which stage() resolves.
    if count(text, done_mark) != 0:
        return False, f"{label}: the done-mark {done_mark!r} is ALREADY present - already staged."
    for name, a, want in anchors:
        got = count(text, a)
        if got != want:
            return False, (f"{label}: anchor {name!r} occurs {got} time(s), expected exactly {want}. "
                           f"The tree is not in the state this rung was written against "
                           f"(a displaced anchor, a partial edit, or a hand-edited region). "
                           f"Writing nothing.")
    got = count(text, insert_after)
    if got != 1:
        return False, (f"{label}: the insertion tail occurs {got} time(s), expected exactly 1; "
                       f"the insertion point is ambiguous. Writing nothing.")
    return True, f"{label}: anchors exact, done-mark absent, insertion point unique."


def apply_file(label, path, insert_after, block):
    text = read(path)
    if count(text, block.strip()) != 0 and count(text, "STAGE90_XNU_USTACK_PROBE") != 0:
        return f"{label}: already staged (STAGE90_XNU_USTACK_PROBE present)."
    # insert the block immediately AFTER the insertion tail
    idx = text.find(insert_after)
    assert idx != -1, label
    end = idx + len(insert_after)
    new = text[:end] + block + text[end:]
    write(path, new)
    return f"{label}: staged."


def stage(xnu, do_apply):
    trap = os.path.join(xnu, TRAP_REL)
    exe = os.path.join(xnu, EXEC_REL)
    for p in (trap, exe):
        if not os.path.isfile(p):
            print(f"patch_d13_ustack_probe: no {p} (D13 tree not provisioned?)", file=sys.stderr)
            return 2
    t = read(trap)
    e = read(exe)

    # THE SHARED-NAMESPACE CHECK ([[mi4-one-file-many-rungs]]).  trap.c's `#if` identifiers are the
    # union of what ALL FOUR patchers put there, so a switch that is NOT in
    # TRAP_ALLOWED_IF_IDENTIFIERS is either a hand edit or a new rung that forgot to register its
    # switch with this patcher.  Either way this script's `--verify-off` cannot certify OFF
    # byte-identity for trap.c (an unregistered identifier "may come from a header"), so refuse
    # BEFORE inspecting anchors - a refusal here names the shared namespace, not a displaced anchor.
    foreign = sorted(i for i in if_identifiers(t) if i not in TRAP_ALLOWED_IF_IDENTIFIERS)
    if foreign:
        print(f"patch_d13_ustack_probe: REFUSE - {TRAP_REL}'s directives also evaluate "
              f"{', '.join(foreign)}. trap.c is edited by FOUR rungs (994/1020/1025/1026) and a file's "
              f"directive identifiers are a SHARED namespace: a new rung that edits trap.c must add "
              f"its switch to TRAP_ALLOWED_IF_IDENTIFIERS here (and to the allow-sets of "
              f"tools/patch_d13_dyld_witness.py / tools/patch_d13_undef_raise.py / "
              f"tools/patch_d13_abt_entry_probe.py) or no patcher can certify its OFF arm. Writing "
              f"nothing. ([[mi4-one-file-many-rungs]])", file=sys.stderr)
        return 1

    ok1, m1 = plan_file("trap.c", t,
                        [("leo_fault_result", TRAP_ANCHOR_CALL, 1)],
                        TRAP_ANCHOR_TAIL, TRAP_BLOCK, TRAP_DONE_MARK)
    ok2, m2 = plan_file("kern_exec.c", e,
                        [("guard0", EXEC_ANCHOR_GUARD0, 1), ("prot", EXEC_ANCHOR_PROT, 1)],
                        EXEC_ANCHOR_TAIL, EXEC_BLOCK, EXEC_DONE_MARK)
    print("   " + m1)
    print("   " + m2)
    if not (ok1 and ok2):
        # A refusal ANYWHERE refuses BOTH (no half-application).  EXCEPT the benign idempotent case:
        # when BOTH done-marks are present, a SECOND `--apply` (the build script calls it twice, the
        # patch_d13_vm_max_split.py idiom) is a NO-OP that SUCCEEDS - it is not a double edit.
        staged = (count(t, TRAP_DONE_MARK) != 0) and (count(e, EXEC_DONE_MARK) != 0)
        if staged:
            # Both files already carry the publishers: this is the idempotent re-run (the build script
            # calls plan mode, then --apply, then --apply again).  A no-op that SUCCEEDS - NOT a
            # double edit.
            print("patch_d13_ustack_probe: already staged (both files) - no-op, OK.")
            return 0
        # A PARTIAL staging (one file, not the other) is a refusal, never a half-application.
        one, other = count(t, TRAP_DONE_MARK) != 0, count(e, EXEC_DONE_MARK) != 0
        if one != other:
            print("patch_d13_ustack_probe: REFUSE - PARTIAL staging (one file done, one not). "
                  "Revert the staged file (git -C external/... checkout) and re-run. Writing nothing.",
                  file=sys.stderr)
            return 1
        print("patch_d13_ustack_probe: REFUSE (writes nothing).", file=sys.stderr)
        return 1
    if not do_apply:
        print("patch_d13_ustack_probe: plan OK (dry run; pass --apply to write).")
        return 0
    print("   " + apply_file("trap.c", trap, TRAP_ANCHOR_TAIL, TRAP_BLOCK))
    print("   " + apply_file("kern_exec.c", exe, EXEC_ANCHOR_TAIL, EXEC_BLOCK))
    return 0


def verify_off(xnu):
    """Prove BOTH files are byte-identical to the tree when the switch is unset.

    The blocks are wholly inside `#if defined(STAGE90_XNU_USTACK_PROBE) && STAGE90_XNU_USTACK_PROBE`,
    so with no `-D` the preprocessor removes them and the compiled bytes are the tree's.  We prove it
    by running the REAL preprocessor over each file for BOTH arms and checking the OFF arm's line set
    contains none of the probe tokens and the ON arm's does.  `-fdirectives-only` keeps `#if` handling
    but not macro expansion of headers; `-P` suppresses line markers so the total is comparable.
    """
    import subprocess
    trap = os.path.join(xnu, TRAP_REL)
    exe = os.path.join(xnu, EXEC_REL)
    cc = os.environ.get("STAGE90_CC", "arm-none-eabi-gcc")
    ok = True
    for label, path, tok in (("trap.c", trap, "xnu_live_abt_vmfkrv="),
                             ("kern_exec.c", exe, "xnu_live_ustack_req=")):
        for arm, extra in (("OFF", []), ("ON", ["-DSTAGE90_XNU_USTACK_PROBE=1"])):
            # `-E` only: this is a proof of EXCLUSION/INCLUSION, not a compile (headers may be absent).
            cmd = [cc, "-E", "-P", "-nostdinc", "-undef"] + extra + [path]
            try:
                out = subprocess.run(cmd, capture_output=True, text=True, errors="replace").stdout
            except Exception as ex:  # noqa: BLE001
                print(f"patch_d13_ustack_probe: --verify-off: cannot run {cc}: {ex}", file=sys.stderr)
                return 2
            has = tok in out
            want = (arm == "ON")
            print(f"   {label} [{arm}]: token {'present' if has else 'absent'} "
                  f"(want {'present' if want else 'absent'})")
            if has != want:
                ok = False
    if not ok:
        print("patch_d13_ustack_probe: --verify-off FAILED (the switch does not gate cleanly).",
              file=sys.stderr)
        return 1
    print("patch_d13_ustack_probe: --verify-off PASS (OFF == tree bytes; ON carries the probe).")
    return 0


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 2
    xnu = None
    do_apply = False
    do_verify = False
    for a in argv[1:]:
        if a == "--apply":
            do_apply = True
        elif a == "--verify-off":
            do_verify = True
        elif a.startswith("-"):
            print(f"patch_d13_ustack_probe: unknown flag {a!r}", file=sys.stderr)
            return 2
        else:
            xnu = a
    if xnu is None:
        print(__doc__)
        return 2
    if do_verify:
        return verify_off(xnu)
    return stage(xnu, do_apply)


if __name__ == "__main__":
    sys.exit(main(sys.argv))