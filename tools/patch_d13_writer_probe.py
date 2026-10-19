#!/usr/bin/env python3
"""1030 -- READ THE WRITER.

1029 read READER-NAMED / TOP-CONFIRMED BY VALUE: at the fault `far` is UNOWNED
(`xnu_live_rdr_entry_at_hit == 0`) and `far` equals the region's EXCLUSIVE TOP -- across all 61
captures `far - ustack` is 0 or 0x1000 and never anything else, and the only run that ever moved it
is 1028's extent-grow.  So the failing store is a BOUNDARY WRITE AT THE REGION'S MOVING TOP, and
NO allocation-geometry change can help (1028 raised the top and the fault FOLLOWED, page-exact;
1030's base-move would lower it and the fault would follow down -- see docs/1030-design.md 0b).

The corrected rung is therefore a PROBE of the WRITER's derivation, not a fix.  The disassembly
(records/1030-audit.txt, libobjc+0x14756 `str.w r2,[r4],#4`) shows the faulting cursor `r4` is the
CALLER's 4th argument -- a table-rebase COPY destination.  Publishing `r4`, `sp`, `pc` and the
thread's user-stack at the moment of the fault discriminates:
  W-A  r4 - sp is a small constant (a frame offset)          => the initial stack is too shallow.
  W-B  r4 == user_stack (or some saved region top)            => a stack-limit store.
  W-C  r4 is neither                                          => W-OTHER; do NOT pick a fix.

ONE site, ONE file: osfmk/arm/trap.c, on the launchctl[2] usermode DATA-abort arm, INSIDE 1025's
publisher (STAGE90_XNU_USTACK_PROBE) and IMMEDIATELY AFTER the 1029 reader-probe block's closing
`#endif /* STAGE90_XNU_READER_PROBE */` (trap.c ~924).  At that point arm_ctx
(abort_information_context_t *), thread, map and dfar are ALL in scope.

READS ONLY; on the failing path only; NO new vm_map calls (r4/sp/pc come straight from arm_ctx).
With the switch undefined the tree compiles BYTE-IDENTICAL to the 1029 tree (`--verify-off`).

SHARED NAMESPACE ([[mi4-one-file-many-rungs]]): trap.c is edited by 994/1020/1025/1026+1027/1029 and
now 1030.  A file's `#if` identifiers are ONE namespace; every OTHER trap.c patcher's allow-set must
gain STAGE90_XNU_WRITER_PROBE, and this script carries the whole union.

docs/1030-design.md.
"""
import os
import re
import sys

SWITCH = "STAGE90_XNU_WRITER_PROBE"

TRAP_REL = "osfmk/arm/trap.c"

# ---------------------------------------------------------------- trap.c (the one site)

# The block is inserted AFTER the 1029 reader block's `#endif` and BEFORE 1025's publisher `#endif`,
# i.e. still INSIDE the 1025 failure arm where arm_ctx / thread / map / dfar are all in scope.  The
# two-line tail is unique because only 1029 sits between 1026/1027 and 1025's close today.
TRAP_ANCHOR = ("#endif /* STAGE90_XNU_READER_PROBE */\n"
               "#endif /* STAGE90_XNU_USTACK_PROBE */\n")

TRAP_DONE_MARK = "xnu_live_wrp_r4="

# The inserted text: opens its own `#if defined(STAGE90_XNU_WRITER_PROBE)`, publishes the rows, closes
# with a matching `#endif`.  Placed BETWEEN the two existing `#endif` lines, so the anchor above is
# rewritten as: <READER #endif> <WRITER block> <USTACK #endif>.
TRAP_BLOCK = (
    "#endif /* STAGE90_XNU_READER_PROBE */\n"
    "#if defined(STAGE90_XNU_WRITER_PROBE) && STAGE90_XNU_WRITER_PROBE\n"
    "\t\t\t\t\t/* 1030: READ THE WRITER.  1029 read `far` UNOWNED at the region's exclusive top; the\n"
    "\t\t\t\t\t * faulting store is `str.w r2,[r4],#4` (libobjc+0x14756), a table-rebase copy whose\n"
    "\t\t\t\t\t * DESTINATION cursor r4 is the CALLER's 4th argument.  Publish r4/sp/pc and the\n"
    "\t\t\t\t\t * thread's user_stack so the WRITER's DERIVATION is by-value (docs/1030-design.md 1-2):\n"
    "\t\t\t\t\t *   W-A  r4 - sp is a small constant   => a frame offset; the initial stack is shallow.\n"
    "\t\t\t\t\t *   W-B  r4 == user_stack              => a stack-limit store at the advertised top.\n"
    "\t\t\t\t\t *   W-C  neither                       => W-OTHER; do NOT pick a fix.\n"
    "\t\t\t\t\t * READS only; on the failing path only; NO new vm_map calls (r4/sp/pc come straight\n"
    "\t\t\t\t\t * from arm_ctx). */\n"
    "\t\t\t\t\t{\n"
    "\t\t\t\t\t\textern unsigned xnu_live_abt_proc_ustack(void *);\n"
    "\t\t\t\t\t\textern unsigned xnu_live_rdr_proc_argslen(void *);\n"
    "\t\t\t\t\t\tunsigned _wrp_sp = (unsigned)arm_ctx->sp;\n"
    "\t\t\t\t\t\tunsigned _wrp_r4 = (unsigned)arm_ctx->r[4];\n"
    "\t\t\t\t\t\tunsigned _wrp_ust = xnu_live_abt_proc_ustack(thread->task->bsd_info);\n"
    "\t\t\t\t\t\tunsigned _wrp_far = (unsigned)vm_map_trunc_page(dfar);\n"
    "\t\t\t\t\t\tprintf(\"xnu_live_wrp_r4=0x%08x\\n\", _wrp_r4);\n"
    "\t\t\t\t\t\tprintf(\"xnu_live_wrp_r3=0x%08x\\n\", (unsigned)arm_ctx->r[3]);\n"
    "\t\t\t\t\t\tprintf(\"xnu_live_wrp_r5=0x%08x\\n\", (unsigned)arm_ctx->r[5]);\n"
    "\t\t\t\t\t\tprintf(\"xnu_live_wrp_r6=0x%08x\\n\", (unsigned)arm_ctx->r[6]);\n"
    "\t\t\t\t\t\tprintf(\"xnu_live_wrp_r12=0x%08x\\n\", (unsigned)arm_ctx->r[12]);\n"
    "\t\t\t\t\t\tprintf(\"xnu_live_wrp_sp=0x%08x\\n\", _wrp_sp);\n"
    "\t\t\t\t\t\tprintf(\"xnu_live_wrp_pc=0x%08x\\n\", (unsigned)arm_ctx->pc);\n"
    "\t\t\t\t\t\tprintf(\"xnu_live_wrp_lr=0x%08x\\n\", (unsigned)arm_ctx->lr);\n"
    "\t\t\t\t\t\tprintf(\"xnu_live_wrp_r4_minus_sp=0x%08x\\n\", (unsigned)(_wrp_r4 - _wrp_sp));\n"
    "\t\t\t\t\t\tprintf(\"xnu_live_wrp_userstack=0x%08x\\n\", _wrp_ust);\n"
    "\t\t\t\t\t\tprintf(\"xnu_live_wrp_r4_minus_ustack=0x%08x\\n\", (unsigned)(_wrp_r4 - _wrp_ust));\n"
    "\t\t\t\t\t\tprintf(\"xnu_live_wrp_far=0x%08x\\n\", _wrp_far);\n"
    "\t\t\t\t\t\tprintf(\"xnu_live_wrp_r4_minus_far=0x%08x\\n\", (unsigned)(_wrp_r4 - _wrp_far));\n"
    "\t\t\t\t\t\tprintf(\"xnu_live_wrp_block_bytes=%u\\n\",\n"
    "\t\t\t\t\t\t    xnu_live_rdr_proc_argslen(thread->task->bsd_info));\n"
    "\t\t\t\t\t}\n"
    "#endif /* STAGE90_XNU_WRITER_PROBE */\n"
    "#endif /* STAGE90_XNU_USTACK_PROBE */\n"
)

# trap.c's `#if` identifiers are the union of what ALL the patchers put there.  A foreign one is a
# hand edit or an unregistered rung; refuse before the anchors, naming the real cause.
TRAP_ALLOWED_IF_IDENTIFIERS = {
    "BOARD_CONFIG_QSD8250_LEO",
    "BOARD_CONFIG_ARMPBA8",
    "STAGE90_XNU_DYLD_WITNESS",       # 994
    "STAGE90_XNU_WATCH_LE",  # 1038 (tools/patch_d13_watch_le.py)
    "STAGE90_XNU_GLOBAL_FIX",         # 1015b (fires in pmap.c; allowed for the proof)
    "STAGE90_XNU_UNDEF_RAISE",        # 1020
    "STAGE90_XNU_IOS7_TRAPS",         # 1023
    "STAGE90_XNU_USTACK_PROBE",       # 1025 (this block's PARENT)
    "STAGE90_XNU_ABT_ENTRY_PROBE",    # 1026/1027
    "STAGE90_XNU_H2_STACK_HEADROOM",  # 1028 (edits kern_exec.c; allowed for the proof)
    "STAGE90_XNU_READER_PROBE",       # 1029
    "STAGE90_XNU_WRITER_PROBE",       # 1030 (this rung)
    "STAGE90_XNU_CALLER_PROBE",       # 1031 (tools/patch_d13_caller_probe.py)
    "STAGE90_XNU_EVAL_FRAME",         # 1033 (tools/patch_d13_eval_frame.py)
    "STAGE90_XNU_PC_CARRIER",         # 1035 (tools/patch_d13_pc_carrier.py)
    "STAGE90_XNU_PC_CARRIER_CALLER",  # 1036 (tools/patch_d13_pc_carrier_caller.py)
    "STAGE90_XNU_TRAP_FRAME",  # 1037 (tools/patch_d13_trap_frame.py)
}


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


def trap_path(xnu):
    return os.path.join(xnu, TRAP_REL)


def check_trap(xnu):
    p = trap_path(xnu)
    if not os.path.isfile(p):
        return False, p, "", f"no {p} (D13 tree not provisioned?)"
    t = read(p)
    if SWITCH in t:
        return True, p, t, "already staged"
    foreign = sorted(i for i in if_stage90_ids(t) if i not in TRAP_ALLOWED_IF_IDENTIFIERS)
    if foreign:
        return False, p, t, (
            f"{TRAP_REL}'s directives also evaluate {', '.join(foreign)}. trap.c is edited by SIX "
            f"rungs (994/1020/1025/1026/1029/1030) and a file's directive identifiers are a SHARED "
            f"namespace: add the new switch to TRAP_ALLOWED_IF_IDENTIFIERS here and to the other "
            f"patchers' sets. ([[mi4-one-file-many-rungs]])")
    if t.count(TRAP_ANCHOR) != 1:
        return False, p, t, (
            f"the READER_PROBE/USTACK_PROBE `#endif` tail occurs {t.count(TRAP_ANCHOR)} time(s), "
            f"expected exactly 1. The tree is not in the state this rung was written against (1029's "
            f"block is not staged, or a displaced anchor / partial edit).")
    return True, p, t, "anchor unique, switch absent"


def stage(xnu, do_apply):
    ok_t, tp, t, msg_t = check_trap(xnu)
    if not ok_t:
        print(f"patch_d13_writer_probe: REFUSE (trap.c) - {msg_t}. Writing nothing.", file=sys.stderr)
        return 1
    if msg_t == "already staged":
        print("patch_d13_writer_probe: already staged - no-op, OK.")
        return 0
    print(f"   trap.c : {msg_t}.")
    if not do_apply:
        print("patch_d13_writer_probe: plan OK (dry run; pass --apply to write).")
        return 0
    write(tp, t.replace(TRAP_ANCHOR, TRAP_BLOCK))
    print(f"   trap.c : staged the writer probe (xnu_live_wrp_* rows) inside 1025's failure arm, "
          f"after 1029's block.")
    return 0


def verify_off(xnu):
    """Prove the file compiles to the 1029 tree's bytes with 1030's switch unset.  The block is wholly
    inside `#if defined(STAGE90_XNU_WRITER_PROBE) && STAGE90_XNU_WRITER_PROBE`, so with the switch
    undefined the preprocessor removes it.  Check by TEXT (the ON block is present and bracketed by
    its own #if/#endif pair, sitting between the two pre-existing #endif lines)."""
    tp = trap_path(xnu)
    t = read(tp)
    if SWITCH not in t:
        print("patch_d13_writer_probe: --verify-off: switch ABSENT (nothing staged).", file=sys.stderr)
        return 1
    have_t = (t.count(TRAP_DONE_MARK) == 1
              and t.count(f"#if defined({SWITCH}) && {SWITCH}\n") >= 1
              and t.count(f"#endif /* {SWITCH} */\n") >= 1)
    between = t.count("#endif /* STAGE90_XNU_READER_PROBE */\n#if defined(STAGE90_XNU_WRITER_PROBE)") == 1
    # The writer block closes before EITHER 1025's #endif (if it is the LAST sibling) OR a LATER rung's
    # `#if` (a new rung may be APPENDED after this one -- [[mi4-one-file-many-rungs]]: 1031's caller
    # block sits between 1030's #endif and 1025's). Both are correct; only "nowhere to close" is wrong.
    tail = (t.count("#endif /* STAGE90_XNU_WRITER_PROBE */\n#endif /* STAGE90_XNU_USTACK_PROBE */\n")
            + t.count("#endif /* STAGE90_XNU_WRITER_PROBE */\n#if defined(STAGE90_XNU_")) == 1
    print(f"   trap.c [ON] : xnu_live_wrp_r4 row present + #if/#endif pair: {have_t}")
    print(f"   trap.c      : the writer block sits after 1029's block, inside 1025's publisher: {between}")
    print(f"   trap.c      : it closes before 1025's #endif OR a later rung's #if: {tail}")
    if have_t and between and tail:
        print("patch_d13_writer_probe: --verify-off PASS (the block is gated on the switch; OFF removes "
              "it -> 1029 tree bytes).")
        return 0
    print("patch_d13_writer_probe: --verify-off FAIL.", file=sys.stderr)
    return 1


def main(argv):
    if len(argv) < 2:
        print("usage: patch_d13_writer_probe.py <xnu_root> [--apply|--verify-off]", file=sys.stderr)
        return 2
    xnu = argv[1]
    if "--verify-off" in argv:
        return verify_off(xnu)
    return stage(xnu, do_apply="--apply" in argv)


if __name__ == "__main__":
    sys.exit(main(sys.argv))