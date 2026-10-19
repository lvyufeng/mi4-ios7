#!/usr/bin/env python3
"""1035 -- NAME THE PC'S CARRIER (the pc-carrier probe).  INSTRUMENT ONLY.

1033 (records/1033-carrier-by-pc-read.txt) read EVF-U1-TRUE: launchctl[2] faults on a LOAD (dfsr type 7)
at 0x10 after `launchd[1] has started up`, and the eval frame's rows put that reader on the frame by
value -- but the frame itself only says WHERE the load happened (pc/lr), not WHAT was being loaded and
from where.  This rung publishes, on the SAME failing path, for pid 2 only and only on the first four
faults:

    xnu_live_pcc_pc / _lr / _r1 / _r2 / _r5 / _r7          the frame's registers
    xnu_live_pcc_near<k> / _near<k>_ok   (k = 0..5)        the words at pc-0x20, pc-0x08, pc, pc+0x08,
                                                          pc+0x20, lr -- each read through copyin AND
                                                          gated on vm_map_lookup_entry (the 1026/1033
                                                          idiom: a read that is not attempted prints
                                                          _ok=0, never a silent value)
    xnu_live_pcc_xor_<name>                                near2/near1/near3/near4/near5 XOR fixed
                                                          constants -- a match names the carrier by value

COST DISCIPLINE.  At most 6 copyins per fault, all on the failing path, all gated.  Reads only: no
sleep, no allocation, no map mutation.  vm_map_lookup_entry takes NO lock in this tree.

SITE -- osfmk/arm/trap.c, INSIDE 1025's failure arm, IMMEDIATELY AFTER 1033's eval-frame block's
`#endif /* STAGE90_XNU_EVAL_FRAME */` (which 1033 put immediately before 1025's
`#endif /* STAGE90_XNU_USTACK_PROBE */`).  arm_ctx / thread / map / dfar / code are in scope there;
no other block's locals are.

SHARED NAMESPACE ([[mi4-one-file-many-rungs]]): trap.c is edited by 994/1020/1025/1026+1027/1029/1030/
1031/1033 and now 1035.  Every trap.c patcher's ALLOWED_IF_IDENTIFIERS must carry STAGE90_XNU_PC_CARRIER;
this script carries the whole union.  With the switch undefined the tree compiles to the 1033 tree's
bytes (`--verify-off`).

scripts/build_1035.sh.
"""
import os
import re
import sys

SWITCH = "STAGE90_XNU_PC_CARRIER"

TRAP_REL = "osfmk/arm/trap.c"

# 1033's block closes with `#endif /* STAGE90_XNU_EVAL_FRAME */` immediately followed by 1025's
# `#endif`.  Insert BETWEEN them (1035's block is the LAST sibling; a later rung appended after it must
# widen verify_off's `tail` the way tools/patch_d13_writer_probe.py does).
TRAP_ANCHOR = ("#endif /* STAGE90_XNU_EVAL_FRAME */\n"
               "#endif /* STAGE90_XNU_USTACK_PROBE */\n")

TRAP_DONE_MARK = "xnu_live_pcc_pc="

# The pid-2 gate; the same proc_pid(thread->task->bsd_info) expression 1033's evf block uses.
TRAP_BLOCK = (
    "#endif /* STAGE90_XNU_EVAL_FRAME */\n"
    "#if defined(STAGE90_XNU_PC_CARRIER) && STAGE90_XNU_PC_CARRIER\n"
    "\t\t\t\t\t/* 1035: NAME THE PC'S CARRIER.  INSTRUMENT ONLY -- no fix.  1033 put the reader on the\n"
    "\t\t\t\t\t * launchctl[2] frame by value (pc/lr); this block publishes what that frame was loading\n"
    "\t\t\t\t\t * and from where: the words at pc-0x20/-0x08/+0x00/+0x08/+0x20 and at lr, each read\n"
    "\t\t\t\t\t * through copyin AND gated on vm_map_lookup_entry (a read not attempted prints _ok=0:\n"
    "\t\t\t\t\t * a row that cannot say its conjunct is not a reading), plus signed XOR checks that\n"
    "\t\t\t\t\t * name the carrier in one number.  pid 2 only, first 4 faults, failing path only.\n"
    "\t\t\t\t\t * vm_map_lookup_entry takes NO lock in this tree (the 1026/1033 idiom). */\n"
    "\t\t\t\t\tif ((int)(thread->task->bsd_info ? proc_pid(thread->task->bsd_info) : -1) == 2) {\n"
    "\t\t\t\t\t\tstatic unsigned _pcc_seq;\n"
    "\t\t\t\t\t\tif (_pcc_seq < 4U) {\n"
    "\t\t\t\t\t\t\tunsigned _pcc_pc = (unsigned)arm_ctx->pc;\n"
    "\t\t\t\t\t\t\tunsigned _pcc_lr = (unsigned)arm_ctx->lr;\n"
    "\t\t\t\t\t\t\tunsigned _pcc_a[6];\n"
    "\t\t\t\t\t\t\tuint32_t _pcc_w[6] = { 0U, 0U, 0U, 0U, 0U, 0U };\n"
    "\t\t\t\t\t\t\tboolean_t _pcc_ok[6] = { FALSE, FALSE, FALSE, FALSE, FALSE, FALSE };\n"
    "\t\t\t\t\t\t\tvm_map_entry_t _pcc_e;\n"
    "\t\t\t\t\t\t\tunsigned _pcc_i;\n"
    "\t\t\t\t\t\t\t_pcc_a[0] = _pcc_pc - 0x20U;\n"
    "\t\t\t\t\t\t\t_pcc_a[1] = _pcc_pc - 0x08U;\n"
    "\t\t\t\t\t\t\t_pcc_a[2] = _pcc_pc;\n"
    "\t\t\t\t\t\t\t_pcc_a[3] = _pcc_pc + 0x08U;\n"
    "\t\t\t\t\t\t\t_pcc_a[4] = _pcc_pc + 0x20U;\n"
    "\t\t\t\t\t\t\t_pcc_a[5] = _pcc_lr;\n"
    "\t\t\t\t\t\t\t/* (ir[bx]) extends as unsigned => FAT registers wrap to a HIGH address, which\n"
    "\t\t\t\t\t\t\t * the at-or-above-4 / at-or-below-0xfffffffc pair below rejects un-attempted. */\n"
    "\t\t\t\t\t\t\tfor (_pcc_i = 0; _pcc_i < 6U; _pcc_i++) {\n"
    "\t\t\t\t\t\t\t\tunsigned _pcc_m = _pcc_a[_pcc_i] & ~3U;\n"
    "\t\t\t\t\t\t\t\tif (_pcc_a[_pcc_i] >= 4U && _pcc_m <= 0xfffffffcU &&\n"
    "\t\t\t\t\t\t\t\t    vm_map_lookup_entry(map, _pcc_m, &_pcc_e)) {\n"
    "\t\t\t\t\t\t\t\t\t_pcc_ok[_pcc_i] = (copyin((user_addr_t)(uintptr_t)_pcc_m,\n"
    "\t\t\t\t\t\t\t\t\t    (char *)&_pcc_w[_pcc_i], 4) == 0);\n"
    "\t\t\t\t\t\t\t\t}\n"
    "\t\t\t\t\t\t\t}\n"
    "\t\t\t\t\t\t\t_pcc_seq++;\n"
    "\t\t\t\t\t\t\tprintf(\"xnu_live_pcc_seq=%u\\n\", _pcc_seq);\n"
    "\t\t\t\t\t\t\tprintf(\"xnu_live_pcc_pid=%d\\n\", (int)proc_pid(thread->task->bsd_info));\n"
    "\t\t\t\t\t\t\tprintf(\"xnu_live_pcc_pc=0x%08x\\n\", _pcc_pc);\n"
    "\t\t\t\t\t\t\tprintf(\"xnu_live_pcc_lr=0x%08x\\n\", _pcc_lr);\n"
    "\t\t\t\t\t\t\tprintf(\"xnu_live_pcc_r1=0x%08x\\n\", (unsigned)arm_ctx->r[1]);\n"
    "\t\t\t\t\t\t\tprintf(\"xnu_live_pcc_r2=0x%08x\\n\", (unsigned)arm_ctx->r[2]);\n"
    "\t\t\t\t\t\t\tprintf(\"xnu_live_pcc_r5=0x%08x\\n\", (unsigned)arm_ctx->r[5]);\n"
    "\t\t\t\t\t\t\tprintf(\"xnu_live_pcc_r7=0x%08x\\n\", (unsigned)arm_ctx->r[7]);\n"
    "\t\t\t\t\t\t\tprintf(\"xnu_live_pcc_near0=0x%08x\\n\", (unsigned)_pcc_w[0]);\n"
    "\t\t\t\t\t\t\tprintf(\"xnu_live_pcc_near0_ok=%d\\n\", (int)(_pcc_ok[0] ? 1 : 0));\n"
    "\t\t\t\t\t\t\tprintf(\"xnu_live_pcc_near1=0x%08x\\n\", (unsigned)_pcc_w[1]);\n"
    "\t\t\t\t\t\t\tprintf(\"xnu_live_pcc_near1_ok=%d\\n\", (int)(_pcc_ok[1] ? 1 : 0));\n"
    "\t\t\t\t\t\t\tprintf(\"xnu_live_pcc_near2=0x%08x\\n\", (unsigned)_pcc_w[2]);\n"
    "\t\t\t\t\t\t\tprintf(\"xnu_live_pcc_near2_ok=%d\\n\", (int)(_pcc_ok[2] ? 1 : 0));\n"
    "\t\t\t\t\t\t\tprintf(\"xnu_live_pcc_near3=0x%08x\\n\", (unsigned)_pcc_w[3]);\n"
    "\t\t\t\t\t\t\tprintf(\"xnu_live_pcc_near3_ok=%d\\n\", (int)(_pcc_ok[3] ? 1 : 0));\n"
    "\t\t\t\t\t\t\tprintf(\"xnu_live_pcc_near4=0x%08x\\n\", (unsigned)_pcc_w[4]);\n"
    "\t\t\t\t\t\t\tprintf(\"xnu_live_pcc_near4_ok=%d\\n\", (int)(_pcc_ok[4] ? 1 : 0));\n"
    "\t\t\t\t\t\t\tprintf(\"xnu_live_pcc_near5=0x%08x\\n\", (unsigned)_pcc_w[5]);\n"
    "\t\t\t\t\t\t\tprintf(\"xnu_live_pcc_near5_ok=%d\\n\", (int)(_pcc_ok[5] ? 1 : 0));\n"
    "\t\t\t\t\t\t\tprintf(\"xnu_live_pcc_xor_walk=0x%08x\\n\", (unsigned)(_pcc_w[2] ^ 0x29007c09U));\n"
    "\t\t\t\t\t\t\tprintf(\"xnu_live_pcc_xor_table=0x%08x\\n\", (unsigned)(_pcc_w[2] ^ 0x030b131bU));\n"
    "\t\t\t\t\t\t\tprintf(\"xnu_live_pcc_xor_m08=0x%08x\\n\", (unsigned)(_pcc_w[1] ^ 0xf856d20bU));\n"
    "\t\t\t\t\t\t\tprintf(\"xnu_live_pcc_xor_p08=0x%08x\\n\", (unsigned)(_pcc_w[3] ^ 0xf8500080U));\n"
    "\t\t\t\t\t\t\tprintf(\"xnu_live_pcc_xor_p20=0x%08x\\n\", (unsigned)(_pcc_w[4] ^ 0xd1054291U));\n"
    "\t\t\t\t\t\t\t/* the lr operand assumes lr's file VA is lr - slide; near5 / near5_ok above are the\n"
    "\t\t\t\t\t\t\t * raw operands, so no reading depends on the slide. */\n"
    "\t\t\t\t\t\t\tprintf(\"xnu_live_pcc_xor_lr=0x%08x\\n\", (unsigned)(_pcc_w[5] ^ 0x2871fff6U));\n"
    "\t\t\t\t\t\t\tprintf(\"xnu_live_pcc_slide=0x00577000\\n\");\n"
    "\t\t\t\t\t\t}\n"
    "\t\t\t\t\t}\n"
    "#endif /* STAGE90_XNU_PC_CARRIER */\n"
    "#endif /* STAGE90_XNU_USTACK_PROBE */\n"
)

# Every row the block emits -- the build's row gate and any checker read THIS.
PCC_ROWS = (
    "xnu_live_pcc_seq=", "xnu_live_pcc_pid=", "xnu_live_pcc_pc=", "xnu_live_pcc_lr=",
    "xnu_live_pcc_r1=", "xnu_live_pcc_r2=", "xnu_live_pcc_r5=", "xnu_live_pcc_r7=",
    "xnu_live_pcc_near0=", "xnu_live_pcc_near0_ok=", "xnu_live_pcc_near1=", "xnu_live_pcc_near1_ok=",
    "xnu_live_pcc_near2=", "xnu_live_pcc_near2_ok=", "xnu_live_pcc_near3=", "xnu_live_pcc_near3_ok=",
    "xnu_live_pcc_near4=", "xnu_live_pcc_near4_ok=", "xnu_live_pcc_near5=", "xnu_live_pcc_near5_ok=",
    "xnu_live_pcc_xor_walk=", "xnu_live_pcc_xor_table=", "xnu_live_pcc_xor_m08=",
    "xnu_live_pcc_xor_p08=", "xnu_live_pcc_xor_p20=", "xnu_live_pcc_xor_lr=", "xnu_live_pcc_slide=",
)

# trap.c's `#if` identifiers are the union of what ALL the patchers put there.
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
    "STAGE90_XNU_WRITER_PROBE",       # 1030
    "STAGE90_XNU_CALLER_PROBE",       # 1031
    "STAGE90_XNU_EVAL_FRAME",         # 1033
    "STAGE90_XNU_PC_CARRIER",         # 1035 (this rung)
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
        return False, p, "", "no %s (D13 tree not provisioned?)" % p
    t = read(p)
    if SWITCH in t:
        return True, p, t, "already staged"
    foreign = sorted(i for i in if_stage90_ids(t) if i not in TRAP_ALLOWED_IF_IDENTIFIERS)
    if foreign:
        return False, p, t, (
            "%s's directives also evaluate %s. trap.c is edited by NINE rungs "
            "(994/1020/1025/1026/1029/1030/1031/1033/1035) and a file's directive identifiers are a "
            "SHARED namespace: add the new switch to TRAP_ALLOWED_IF_IDENTIFIERS here and to the other "
            "patchers' sets. ([[mi4-one-file-many-rungs]])" % (TRAP_REL, ", ".join(foreign)))
    if t.count(TRAP_ANCHOR) != 1:
        return False, p, t, (
            "the EVAL_FRAME/USTACK_PROBE `#endif` tail occurs %d time(s), expected exactly 1. The tree "
            "is not in the state this rung was written against (1033's block is not staged, or a "
            "displaced anchor / partial edit)." % t.count(TRAP_ANCHOR))
    return True, p, t, "anchor unique, switch absent"


def stage(xnu, do_apply):
    ok_t, tp, t, msg_t = check_trap(xnu)
    if not ok_t:
        print("patch_d13_pc_carrier: REFUSE (trap.c) - %s. Writing nothing." % msg_t, file=sys.stderr)
        return 1
    if msg_t == "already staged":
        print("patch_d13_pc_carrier: already staged - no-op, OK.")
        return 0
    print("   trap.c : %s." % msg_t)
    if not do_apply:
        print("patch_d13_pc_carrier: plan OK (dry run; pass --apply to write).")
        return 0
    write(tp, t.replace(TRAP_ANCHOR, TRAP_BLOCK))
    print("   trap.c : staged Site A (xnu_live_pcc_* rows, %d) after 1033's block, inside 1025's arm."
          % len(PCC_ROWS))
    return 0


def closes_inside_1025(t):
    """True iff this block's #endif closes inside 1025's publisher: after it come zero or more WHOLE
    STAGE90 sibling blocks (`#if defined(SW) && SW` .. `#endif /* SW */`), then 1025's #endif.  1033's
    evf_closes_inside_1025 widen, as that scan's own docstring asks a later rung to do (1037 stages its
    block here and its --verify-off must pass; [[mi4-one-file-many-rungs]])."""
    close = "#endif /* %s */\n" % SWITCH
    blocks = re.compile(r"#if defined\((STAGE90_[A-Z0-9_]+)\) && \1\n.*?#endif /\* \1 \*/\n", re.S)
    for m in re.finditer(re.escape(close), t):
        rest = t[m.end():]
        pos = 0
        while True:
            if rest.startswith("#endif /* STAGE90_XNU_USTACK_PROBE */\n", pos):
                return True
            b = blocks.match(rest, pos)
            if b is None:
                break
            pos = b.end()
    return False


def verify_off(xnu):
    """With the switch undefined the preprocessor removes the whole block -> the 1033 tree's text."""
    tp = trap_path(xnu)
    if not os.path.isfile(tp):
        print("patch_d13_pc_carrier: --verify-off: no %s" % tp, file=sys.stderr)
        return 1
    t = read(tp)
    if SWITCH not in t:
        print("patch_d13_pc_carrier: --verify-off: switch ABSENT (nothing staged).", file=sys.stderr)
        return 1
    have = (t.count(TRAP_DONE_MARK) == 1
            and t.count("#if defined(%s) && %s\n" % (SWITCH, SWITCH)) == 1
            and t.count("#endif /* %s */\n" % SWITCH) == 1)
    between = t.count("#endif /* STAGE90_XNU_EVAL_FRAME */\n#if defined(%s)" % SWITCH) == 1
    tail = closes_inside_1025(t)
    # every emitted row is INSIDE the gated block (so OFF removes it, not just the switch name)
    s = t.find("#if defined(%s) && %s" % (SWITCH, SWITCH))
    e = t.find("#endif /* %s */" % SWITCH)
    inside = t[s:e] if (s >= 0 and e > s) else ""
    missing = [r for r in PCC_ROWS if ("\"%s" % r) not in inside]
    print("   trap.c [ON] : xnu_live_pcc_pc row present + one #if/#endif pair: %s" % have)
    print("   trap.c      : the block sits immediately after 1033's, inside 1025's publisher: %s" % between)
    print("   trap.c      : it closes inside 1025's publisher (whole sibling blocks allowed after it): %s" % tail)
    print("   trap.c      : all %d rows inside the gated block: %s"
          % (len(PCC_ROWS), "yes" if not missing else "NO: %s" % ", ".join(missing)))
    if have and between and tail and not missing:
        print("patch_d13_pc_carrier: --verify-off PASS (all edits gated on the switch; OFF removes "
              "them -> the 1033 tree bytes).")
        return 0
    print("patch_d13_pc_carrier: --verify-off FAIL.", file=sys.stderr)
    return 1


# ---------------------------------------------------------------- selftest

def selftest():
    import tempfile
    fails = []
    tmp = tempfile.mkdtemp(prefix="p1035-")

    def tree(name, trap_text):
        root = os.path.join(tmp, name)
        os.makedirs(os.path.join(root, "osfmk", "arm"))
        with open(os.path.join(root, TRAP_REL), "w") as f:
            f.write(trap_text)
        return root

    def expect(cond, label):
        print("   ok" if cond else "   FAIL", label)
        if not cond:
            fails.append(label)

    base = ("#if defined(STAGE90_XNU_USTACK_PROBE) && STAGE90_XNU_USTACK_PROBE\n"
            "\t\t\t\t\t{ int _cal = 0; (void)_cal; }\n"
            "#endif /* STAGE90_XNU_CALLER_PROBE */\n"
            "\t\t\t\t\t{ int _evf = 0; (void)_evf; }\n"
            "#endif /* STAGE90_XNU_EVAL_FRAME */\n"
            "#endif /* STAGE90_XNU_USTACK_PROBE */\n")
    r = tree("good", base)

    ok, p, t, msg = check_trap(r)
    expect(ok and msg == "anchor unique, switch absent", "the 1033 tree: plan accepts it (%s)" % msg)

    rc = stage(r, do_apply=True)
    t1 = read(trap_path(r))
    expect(rc == 0 and t1.count("\"xnu_live_pcc_pc=") == 1, "staged: exactly one pcc pc row")
    expect((t1.count("#if defined(STAGE90_XNU_PC_CARRIER) && STAGE90_XNU_PC_CARRIER\n") == 1
            and t1.count("#endif /* STAGE90_XNU_PC_CARRIER */\n") == 1),
           "staged: exactly one #if/#endif pair for the switch")
    expect(t1.count("#endif /* STAGE90_XNU_EVAL_FRAME */\n#if defined(STAGE90_XNU_PC_CARRIER)")
           == 1, "staged: the block opens immediately after 1033's #endif")
    expect(t1.count("#endif /* STAGE90_XNU_PC_CARRIER */\n#endif /* STAGE90_XNU_USTACK_PROBE */\n")
           == 1, "staged: the block closes immediately before 1025's #endif")
    rc2 = stage(r, do_apply=True)
    expect(rc2 == 0 and read(trap_path(r)) == t1, "second --apply is an idempotent no-op")
    rc3 = verify_off(r)
    expect(rc3 == 0, "--verify-off PASS on the staged tree")
    s = t1.find("#if defined(STAGE90_XNU_PC_CARRIER)")
    e = t1.find("#endif /* STAGE90_XNU_PC_CARRIER */")
    inside = t1[s:e]
    expect(all(("\"%s" % row) in inside for row in PCC_ROWS), "every emitted row is inside the gated block")
    expect("_cal" not in inside and "_evf" not in inside, "the block never names an earlier sibling's locals")

    r2 = tree("noanchor", base.replace("#endif /* STAGE90_XNU_EVAL_FRAME */\n", ""))
    before = read(trap_path(r2))
    ok2, _, _, msg2 = check_trap(r2)
    expect(not ok2 and "expected exactly 1" in msg2, "missing 1033 tail: REFUSE (%s)" % msg2)
    expect(read(trap_path(r2)) == before, "a refused stage writes nothing")

    r3 = tree("foreign", base.replace("#endif /* STAGE90_XNU_USTACK_PROBE */\n",
                                      "#if defined(STAGE90_XNU_NOBODY_ADDED_ME) && STAGE90_XNU_NOBODY_ADDED_ME\n"
                                      "#endif /* STAGE90_XNU_NOBODY_ADDED_ME */\n"
                                      "#endif /* STAGE90_XNU_USTACK_PROBE */\n"))
    ok3, _, _, msg3 = check_trap(r3)
    expect(not ok3 and "STAGE90_XNU_NOBODY_ADDED_ME" in msg3, "a foreign identifier: REFUSE")

    r4 = tree("leak", base)
    stage(r4, do_apply=True)
    t4 = read(trap_path(r4))
    write(trap_path(r4), t4.replace("#endif /* STAGE90_XNU_PC_CARRIER */\n",
                                    "#endif /* STAGE90_XNU_PC_CARRIER */\n"
                                    "\t\t\t\t\tprintf(\"xnu_live_pcc_seq=%u\\n\", 0U);\n"))
    expect(verify_off(r4) != 0, "--verify-off FAILS when one row escapes the gate")

    if fails:
        print("SELFTEST FAIL: " + " | ".join(fails), file=sys.stderr)
        return 1
    print("SELFTEST PASS (9 checks: plan/apply/idempotent/bracket/namespace/OFF-can-fail)")
    return 0


def main(argv):
    if "--selftest" in argv:
        return selftest()
    if len(argv) < 2:
        print("usage: patch_d13_pc_carrier.py <xnu_root> [--apply|--verify-off] [--selftest]",
              file=sys.stderr)
        return 2
    xnu = argv[1]
    if "--verify-off" in argv:
        return verify_off(xnu)
    return stage(xnu, do_apply="--apply" in argv)


if __name__ == "__main__":
    sys.exit(main(sys.argv))