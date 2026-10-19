#!/usr/bin/env python3
"""1036 -- THE PC CARRIER'S CALLER (the pc-carrier caller probe).  INSTRUMENT ONLY.

1035 (records/1036-* ) read whether the launchctl[2] fault runs the dyld bucket walk: `xnu_live_pcc_*`
puts the pc/lr and the words around them on the record.  1036 takes the NEXT step -- it asks WHO called
the faulting frame and WHAT the caller is walking: the frame's r3/r6/r8/r9/r12/sp and r7, the caller's
return-address words at lr-4 / lr-8, the candidate TABLE at r8 (its header word and its `used` count at
+12, the -1 candidate) and the sixteen words of the stack slot at r7-0x40 .. r7-0x04.

    xnu_live_pcc2_pc / _lr / _sp / _r3 / _r6 / _r7 / _r8 / _r9 / _r12 / _slide
    xnu_live_pcc2_lr_m4 / _lr_m4_ok, _lr_m8 / _lr_m8_ok         the caller's last two return words
    xnu_live_pcc2_tbl_hdr / _tbl_hdr_ok, _tbl_used / _tbl_used_ok   the table at r8 and its count
    xnu_live_pcc2_s0 .. _s15 / _s<k>_ok                        r7-0x40, r7-0x3c, ... r7-0x04

Every read goes through copyin AND is gated on vm_map_lookup_entry (1035's idiom: address >= 4, masked
to 4-byte alignment, a read that is not attempted prints _ok=0, never a silent value).  pid 2 only,
first 4 faults, failing path only.  Reads only: no sleep, no allocation, no map mutation.

SITE -- osfmk/arm/trap.c, INSIDE 1025's failure arm, IMMEDIATELY AFTER 1035's pc-carrier block's
`#endif /* STAGE90_XNU_PC_CARRIER */` (the first such line; probe rows use `xnu_live_pcc_`, so this
rung's `xnu_live_pcc2_pc=` mark cannot collide with 1035's).  arm_ctx / thread / map are in scope;
no other block's locals are.

SHARED NAMESPACE ([[mi4-one-file-many-rungs]]): every trap.c patcher's ALLOWED_IF_IDENTIFIERS must
carry STAGE90_XNU_PC_CARRIER_CALLER.  With the switch undefined the tree compiles to the 1035 tree's
bytes (`--verify-off`).
"""
import os
import re
import sys

SWITCH = "STAGE90_XNU_PC_CARRIER_CALLER"

TRAP_REL = "osfmk/arm/trap.c"

# 1035's block closes with `#endif /* STAGE90_XNU_PC_CARRIER */` immediately before 1025's `#endif`.
# Insert BETWEEN them.  A later rung appended after this block must widen verify_off's `tail` the way
# tools/patch_d13_eval_frame.py's evf_closes_inside_1025 does (whole later sibling blocks allowed).
TRAP_ANCHOR = ("#endif /* STAGE90_XNU_PC_CARRIER */\n"
               "#endif /* STAGE90_XNU_USTACK_PROBE */\n")

TRAP_DONE_MARK = "xnu_live_pcc2_pc="

TRAP_BLOCK = (
    "#endif /* STAGE90_XNU_PC_CARRIER */\n"
    "#if defined(STAGE90_XNU_PC_CARRIER_CALLER) && STAGE90_XNU_PC_CARRIER_CALLER\n"
    "\t\t\t\t\t/* 1036: THE PC CARRIER'S CALLER.  INSTRUMENT ONLY -- no fix.  Names the caller of the\n"
    "\t\t\t\t\t * faulting frame (lr-4 / lr-8), the candidate table at r8 (header word + `used` count\n"
    "\t\t\t\t\t * at +12: the -1 candidate) and the 16 words of the stack slot at r7-0x40..r7-0x04.\n"
    "\t\t\t\t\t * Every word read through copyin AND gated on vm_map_lookup_entry (a read not\n"
    "\t\t\t\t\t * attempted prints _ok=0: a row that cannot say its conjunct is not a reading).\n"
    "\t\t\t\t\t * pid 2 only, first 4 faults, failing path only.  vm_map_lookup_entry takes NO lock\n"
    "\t\t\t\t\t * in this tree (the 1026/1033/1035 idiom). */\n"
    "\t\t\t\t\tif ((int)(thread->task->bsd_info ? proc_pid(thread->task->bsd_info) : -1) == 2) {\n"
    "\t\t\t\t\t\tstatic unsigned _pcc2_seq;\n"
    "\t\t\t\t\t\tif (_pcc2_seq < 4U) {\n"
    "\t\t\t\t\t\t\tunsigned _pcc2_pc = (unsigned)arm_ctx->pc;\n"
    "\t\t\t\t\t\t\tunsigned _pcc2_lr = (unsigned)arm_ctx->lr;\n"
    "\t\t\t\t\t\t\tunsigned _pcc2_r8 = (unsigned)arm_ctx->r[8];\n"
    "\t\t\t\t\t\t\tunsigned _pcc2_a[20];\n"
    "\t\t\t\t\t\t\tuint32_t _pcc2_w[20];\n"
    "\t\t\t\t\t\t\tboolean_t _pcc2_ok[20];\n"
    "\t\t\t\t\t\t\tvm_map_entry_t _pcc2_e;\n"
    "\t\t\t\t\t\t\tunsigned _pcc2_i;\n"
    "\t\t\t\t\t\t\t_pcc2_a[0] = _pcc2_lr - 4U;\n"
    "\t\t\t\t\t\t\t_pcc2_a[1] = _pcc2_lr - 8U;\n"
    "\t\t\t\t\t\t\t_pcc2_a[2] = _pcc2_r8;\n"
    "\t\t\t\t\t\t\t_pcc2_a[3] = _pcc2_r8 + 12U;\n"
    "\t\t\t\t\t\t\tfor (_pcc2_i = 0; _pcc2_i < 16U; _pcc2_i++) {\n"
    "\t\t\t\t\t\t\t\t_pcc2_a[4U + _pcc2_i] = (unsigned)arm_ctx->r[7] - 0x40U + 4U * _pcc2_i;\n"
    "\t\t\t\t\t\t\t}\n"
    "\t\t\t\t\t\t\t/* (ir[bx]) extends as unsigned => FAT registers wrap to a HIGH address, which\n"
    "\t\t\t\t\t\t\t * the at-or-above-4 / at-or-below-0xfffffffc pair below rejects un-attempted. */\n"
    "\t\t\t\t\t\t\tfor (_pcc2_i = 0; _pcc2_i < 20U; _pcc2_i++) {\n"
    "\t\t\t\t\t\t\t\tunsigned _pcc2_m = _pcc2_a[_pcc2_i] & ~3U;\n"
    "\t\t\t\t\t\t\t\t_pcc2_w[_pcc2_i] = 0U;\n"
    "\t\t\t\t\t\t\t\t_pcc2_ok[_pcc2_i] = FALSE;\n"
    "\t\t\t\t\t\t\t\tif (_pcc2_a[_pcc2_i] >= 4U && _pcc2_m <= 0xfffffffcU &&\n"
    "\t\t\t\t\t\t\t\t    vm_map_lookup_entry(map, _pcc2_m, &_pcc2_e)) {\n"
    "\t\t\t\t\t\t\t\t\t_pcc2_ok[_pcc2_i] = (copyin((user_addr_t)(uintptr_t)_pcc2_m,\n"
    "\t\t\t\t\t\t\t\t\t    (char *)&_pcc2_w[_pcc2_i], 4) == 0);\n"
    "\t\t\t\t\t\t\t\t}\n"
    "\t\t\t\t\t\t\t}\n"
    "\t\t\t\t\t\t\t_pcc2_seq++;\n"
    "\t\t\t\t\t\t\tprintf(\"xnu_live_pcc2_seq=%u\\n\", _pcc2_seq);\n"
    "\t\t\t\t\t\t\tprintf(\"xnu_live_pcc2_pid=%d\\n\", (int)proc_pid(thread->task->bsd_info));\n"
    "\t\t\t\t\t\t\tprintf(\"xnu_live_pcc2_pc=0x%08x\\n\", _pcc2_pc);\n"
    "\t\t\t\t\t\t\tprintf(\"xnu_live_pcc2_lr=0x%08x\\n\", _pcc2_lr);\n"
    "\t\t\t\t\t\t\tprintf(\"xnu_live_pcc2_r3=0x%08x\\n\", (unsigned)arm_ctx->r[3]);\n"
    "\t\t\t\t\t\t\tprintf(\"xnu_live_pcc2_r6=0x%08x\\n\", (unsigned)arm_ctx->r[6]);\n"
    "\t\t\t\t\t\t\tprintf(\"xnu_live_pcc2_r8=0x%08x\\n\", _pcc2_r8);\n"
    "\t\t\t\t\t\t\tprintf(\"xnu_live_pcc2_r9=0x%08x\\n\", (unsigned)arm_ctx->r[9]);\n"
    "\t\t\t\t\t\t\tprintf(\"xnu_live_pcc2_r12=0x%08x\\n\", (unsigned)arm_ctx->r[12]);\n"
    "\t\t\t\t\t\t\tprintf(\"xnu_live_pcc2_sp=0x%08x\\n\", (unsigned)arm_ctx->sp);\n"
    "\t\t\t\t\t\t\tprintf(\"xnu_live_pcc2_r7=0x%08x\\n\", (unsigned)arm_ctx->r[7]);\n"
    "\t\t\t\t\t\t\tprintf(\"xnu_live_pcc2_slide=0x00577000\\n\");\n"
    "\t\t\t\t\t\t\tprintf(\"xnu_live_pcc2_lr_m4=0x%08x\\n\", (unsigned)_pcc2_w[0]);\n"
    "\t\t\t\t\t\t\tprintf(\"xnu_live_pcc2_lr_m4_ok=%d\\n\", (int)(_pcc2_ok[0] ? 1 : 0));\n"
    "\t\t\t\t\t\t\tprintf(\"xnu_live_pcc2_lr_m8=0x%08x\\n\", (unsigned)_pcc2_w[1]);\n"
    "\t\t\t\t\t\t\tprintf(\"xnu_live_pcc2_lr_m8_ok=%d\\n\", (int)(_pcc2_ok[1] ? 1 : 0));\n"
    "\t\t\t\t\t\t\tprintf(\"xnu_live_pcc2_tbl_hdr=0x%08x\\n\", (unsigned)_pcc2_w[2]);\n"
    "\t\t\t\t\t\t\tprintf(\"xnu_live_pcc2_tbl_hdr_ok=%d\\n\", (int)(_pcc2_ok[2] ? 1 : 0));\n"
    "\t\t\t\t\t\t\tprintf(\"xnu_live_pcc2_tbl_used=0x%08x\\n\", (unsigned)_pcc2_w[3]);\n"
    "\t\t\t\t\t\t\tprintf(\"xnu_live_pcc2_tbl_used_ok=%d\\n\", (int)(_pcc2_ok[3] ? 1 : 0));\n"
    "\t\t\t\t\t\t\tprintf(\"xnu_live_pcc2_s0=0x%08x\\n\", (unsigned)_pcc2_w[4]);\n"
    "\t\t\t\t\t\t\tprintf(\"xnu_live_pcc2_s0_ok=%d\\n\", (int)(_pcc2_ok[4] ? 1 : 0));\n"
    "\t\t\t\t\t\t\tprintf(\"xnu_live_pcc2_s1=0x%08x\\n\", (unsigned)_pcc2_w[5]);\n"
    "\t\t\t\t\t\t\tprintf(\"xnu_live_pcc2_s1_ok=%d\\n\", (int)(_pcc2_ok[5] ? 1 : 0));\n"
    "\t\t\t\t\t\t\tprintf(\"xnu_live_pcc2_s2=0x%08x\\n\", (unsigned)_pcc2_w[6]);\n"
    "\t\t\t\t\t\t\tprintf(\"xnu_live_pcc2_s2_ok=%d\\n\", (int)(_pcc2_ok[6] ? 1 : 0));\n"
    "\t\t\t\t\t\t\tprintf(\"xnu_live_pcc2_s3=0x%08x\\n\", (unsigned)_pcc2_w[7]);\n"
    "\t\t\t\t\t\t\tprintf(\"xnu_live_pcc2_s3_ok=%d\\n\", (int)(_pcc2_ok[7] ? 1 : 0));\n"
    "\t\t\t\t\t\t\tprintf(\"xnu_live_pcc2_s4=0x%08x\\n\", (unsigned)_pcc2_w[8]);\n"
    "\t\t\t\t\t\t\tprintf(\"xnu_live_pcc2_s4_ok=%d\\n\", (int)(_pcc2_ok[8] ? 1 : 0));\n"
    "\t\t\t\t\t\t\tprintf(\"xnu_live_pcc2_s5=0x%08x\\n\", (unsigned)_pcc2_w[9]);\n"
    "\t\t\t\t\t\t\tprintf(\"xnu_live_pcc2_s5_ok=%d\\n\", (int)(_pcc2_ok[9] ? 1 : 0));\n"
    "\t\t\t\t\t\t\tprintf(\"xnu_live_pcc2_s6=0x%08x\\n\", (unsigned)_pcc2_w[10]);\n"
    "\t\t\t\t\t\t\tprintf(\"xnu_live_pcc2_s6_ok=%d\\n\", (int)(_pcc2_ok[10] ? 1 : 0));\n"
    "\t\t\t\t\t\t\tprintf(\"xnu_live_pcc2_s7=0x%08x\\n\", (unsigned)_pcc2_w[11]);\n"
    "\t\t\t\t\t\t\tprintf(\"xnu_live_pcc2_s7_ok=%d\\n\", (int)(_pcc2_ok[11] ? 1 : 0));\n"
    "\t\t\t\t\t\t\tprintf(\"xnu_live_pcc2_s8=0x%08x\\n\", (unsigned)_pcc2_w[12]);\n"
    "\t\t\t\t\t\t\tprintf(\"xnu_live_pcc2_s8_ok=%d\\n\", (int)(_pcc2_ok[12] ? 1 : 0));\n"
    "\t\t\t\t\t\t\tprintf(\"xnu_live_pcc2_s9=0x%08x\\n\", (unsigned)_pcc2_w[13]);\n"
    "\t\t\t\t\t\t\tprintf(\"xnu_live_pcc2_s9_ok=%d\\n\", (int)(_pcc2_ok[13] ? 1 : 0));\n"
    "\t\t\t\t\t\t\tprintf(\"xnu_live_pcc2_s10=0x%08x\\n\", (unsigned)_pcc2_w[14]);\n"
    "\t\t\t\t\t\t\tprintf(\"xnu_live_pcc2_s10_ok=%d\\n\", (int)(_pcc2_ok[14] ? 1 : 0));\n"
    "\t\t\t\t\t\t\tprintf(\"xnu_live_pcc2_s11=0x%08x\\n\", (unsigned)_pcc2_w[15]);\n"
    "\t\t\t\t\t\t\tprintf(\"xnu_live_pcc2_s11_ok=%d\\n\", (int)(_pcc2_ok[15] ? 1 : 0));\n"
    "\t\t\t\t\t\t\tprintf(\"xnu_live_pcc2_s12=0x%08x\\n\", (unsigned)_pcc2_w[16]);\n"
    "\t\t\t\t\t\t\tprintf(\"xnu_live_pcc2_s12_ok=%d\\n\", (int)(_pcc2_ok[16] ? 1 : 0));\n"
    "\t\t\t\t\t\t\tprintf(\"xnu_live_pcc2_s13=0x%08x\\n\", (unsigned)_pcc2_w[17]);\n"
    "\t\t\t\t\t\t\tprintf(\"xnu_live_pcc2_s13_ok=%d\\n\", (int)(_pcc2_ok[17] ? 1 : 0));\n"
    "\t\t\t\t\t\t\tprintf(\"xnu_live_pcc2_s14=0x%08x\\n\", (unsigned)_pcc2_w[18]);\n"
    "\t\t\t\t\t\t\tprintf(\"xnu_live_pcc2_s14_ok=%d\\n\", (int)(_pcc2_ok[18] ? 1 : 0));\n"
    "\t\t\t\t\t\t\tprintf(\"xnu_live_pcc2_s15=0x%08x\\n\", (unsigned)_pcc2_w[19]);\n"
    "\t\t\t\t\t\t\tprintf(\"xnu_live_pcc2_s15_ok=%d\\n\", (int)(_pcc2_ok[19] ? 1 : 0));\n"
    "\t\t\t\t\t\t}\n"
    "\t\t\t\t\t}\n"
    "#endif /* STAGE90_XNU_PC_CARRIER_CALLER */\n"
    "#endif /* STAGE90_XNU_USTACK_PROBE */\n"
)

# Every row the block emits -- the build's row gate and any checker read THIS.
PCC2_ROWS = (
    "xnu_live_pcc2_seq=", "xnu_live_pcc2_pid=", "xnu_live_pcc2_pc=", "xnu_live_pcc2_lr=",
    "xnu_live_pcc2_r3=", "xnu_live_pcc2_r6=", "xnu_live_pcc2_r8=", "xnu_live_pcc2_r9=",
    "xnu_live_pcc2_r12=", "xnu_live_pcc2_sp=", "xnu_live_pcc2_r7=", "xnu_live_pcc2_slide=",
    "xnu_live_pcc2_lr_m4=", "xnu_live_pcc2_lr_m4_ok=",
    "xnu_live_pcc2_lr_m8=", "xnu_live_pcc2_lr_m8_ok=",
    "xnu_live_pcc2_tbl_hdr=", "xnu_live_pcc2_tbl_hdr_ok=",
    "xnu_live_pcc2_tbl_used=", "xnu_live_pcc2_tbl_used_ok=",
) + tuple("xnu_live_pcc2_s%d=" % k for k in range(16)) \
  + tuple("xnu_live_pcc2_s%d_ok=" % k for k in range(16))

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
    "STAGE90_XNU_PC_CARRIER",         # 1035 (this block's immediate predecessor)
    "STAGE90_XNU_PC_CARRIER_CALLER",  # 1036 (this rung)
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
        return False, p, "", "no %s (D13 tree not provisioned?)" % p
    t = read(p)
    if SWITCH in t:
        return True, p, t, "already staged"
    foreign = sorted(i for i in if_stage90_ids(t) if i not in TRAP_ALLOWED_IF_IDENTIFIERS)
    if foreign:
        return False, p, t, (
            "%s's directives also evaluate %s. trap.c is edited by TEN rungs "
            "(994/1020/1025/1026/1029/1030/1031/1033/1035/1036) and a file's directive identifiers are "
            "a SHARED namespace: add the new switch to TRAP_ALLOWED_IF_IDENTIFIERS here and to the "
            "other patchers' sets. ([[mi4-one-file-many-rungs]])" % (TRAP_REL, ", ".join(foreign)))
    if t.count(TRAP_ANCHOR) != 1:
        return False, p, t, (
            "the PC_CARRIER/USTACK_PROBE `#endif` tail occurs %d time(s), expected exactly 1. The tree "
            "is not in the state this rung was written against (1035's block is not staged, or a "
            "displaced anchor / partial edit)." % t.count(TRAP_ANCHOR))
    return True, p, t, "anchor unique, switch absent"


def stage(xnu, do_apply):
    ok_t, tp, t, msg_t = check_trap(xnu)
    if not ok_t:
        print("patch_d13_pc_carrier_caller: REFUSE (trap.c) - %s. Writing nothing." % msg_t,
              file=sys.stderr)
        return 1
    if msg_t == "already staged":
        print("patch_d13_pc_carrier_caller: already staged - no-op, OK.")
        return 0
    print("   trap.c : %s." % msg_t)
    if not do_apply:
        print("patch_d13_pc_carrier_caller: plan OK (dry run; pass --apply to write).")
        return 0
    write(tp, t.replace(TRAP_ANCHOR, TRAP_BLOCK))
    print("   trap.c : staged Site A (xnu_live_pcc2_* rows, %d) after 1035's block, inside 1025's arm."
          % len(PCC2_ROWS))
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
    """With the switch undefined the preprocessor removes the whole block -> the 1035 tree's text."""
    tp = trap_path(xnu)
    if not os.path.isfile(tp):
        print("patch_d13_pc_carrier_caller: --verify-off: no %s" % tp, file=sys.stderr)
        return 1
    t = read(tp)
    if SWITCH not in t:
        print("patch_d13_pc_carrier_caller: --verify-off: switch ABSENT (nothing staged).",
              file=sys.stderr)
        return 1
    have = (t.count(TRAP_DONE_MARK) == 1
            and t.count("#if defined(%s) && %s\n" % (SWITCH, SWITCH)) == 1
            and t.count("#endif /* %s */\n" % SWITCH) == 1)
    between = t.count("#endif /* STAGE90_XNU_PC_CARRIER */\n#if defined(%s)" % SWITCH) == 1
    # 1035's own switch text must not match this rung's bracket counts (it does not: the prefix
    # STAGE90_XNU_PC_CARRIER never appears as `#if defined(X) && X\n` for this X).
    tail = closes_inside_1025(t)
    # every emitted row is INSIDE the gated block (so OFF removes it, not just the switch name)
    s = t.find("#if defined(%s) && %s" % (SWITCH, SWITCH))
    e = t.find("#endif /* %s */" % SWITCH)
    inside = t[s:e] if (s >= 0 and e > s) else ""
    missing = [r for r in PCC2_ROWS if ("\"%s" % r) not in inside]
    # the block shape 1035's structural scan (evf_closes_inside_1025) accepts: `#if defined(SW) && SW`
    # opening and `#endif /* SW */` closing, no nested directive inside it.
    shape = re.compile(r"#if defined\((STAGE90_[A-Z0-9_]+)\) && \1\n.*?#endif /\* \1 \*/\n", re.S)
    print("   trap.c [ON] : xnu_live_pcc2_pc row present + one #if/#endif pair: %s" % have)
    print("   trap.c      : the block sits immediately after 1035's, inside 1025's publisher: %s"
          % between)
    print("   trap.c      : it closes inside 1025's publisher (whole sibling blocks allowed after it): %s" % tail)
    print("   trap.c      : all %d rows inside the gated block: %s"
          % (len(PCC2_ROWS), "yes" if not missing else "NO: %s" % ", ".join(missing)))
    print("   trap.c      : whole-block shape `#if defined(SW) && SW .. #endif /* SW */`: %s"
          % ("yes" if (s >= 0 and shape.match(t, s)) else "NO"))
    if have and between and tail and not missing and s >= 0 and shape.match(t, s):
        print("patch_d13_pc_carrier_caller: --verify-off PASS (all edits gated on the switch; OFF "
              "removes them -> the 1035 tree bytes).")
        return 0
    print("patch_d13_pc_carrier_caller: --verify-off FAIL.", file=sys.stderr)
    return 1


# ---------------------------------------------------------------- selftest

def selftest():
    import tempfile
    fails = []
    tmp = tempfile.mkdtemp(prefix="p1036-")

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
            "#if defined(STAGE90_XNU_EVAL_FRAME) && STAGE90_XNU_EVAL_FRAME\n"
            "\t\t\t\t\t{ int _evf = 0; (void)_evf; }\n"
            "#endif /* STAGE90_XNU_EVAL_FRAME */\n"
            "#if defined(STAGE90_XNU_PC_CARRIER) && STAGE90_XNU_PC_CARRIER\n"
            "\t\t\t\t\t{ int _pcc = 0; (void)_pcc; }\n"
            "#endif /* STAGE90_XNU_PC_CARRIER */\n"
            "#endif /* STAGE90_XNU_USTACK_PROBE */\n")
    r = tree("good", base)

    ok, p, t, msg = check_trap(r)
    expect(ok and msg == "anchor unique, switch absent", "the 1035 tree: plan accepts it (%s)" % msg)

    rc = stage(r, do_apply=True)
    t1 = read(trap_path(r))
    expect(rc == 0 and t1.count("\"xnu_live_pcc2_pc=") == 1, "staged: exactly one pcc2 pc row")
    expect(t1.count("\"xnu_live_pcc_pc=") == 0, "staged: does not emit 1035's pcc_pc row")
    expect((t1.count("#if defined(STAGE90_XNU_PC_CARRIER_CALLER) && STAGE90_XNU_PC_CARRIER_CALLER\n")
            == 1
            and t1.count("#endif /* STAGE90_XNU_PC_CARRIER_CALLER */\n") == 1),
           "staged: exactly one #if/#endif pair for the switch")
    expect(t1.count("#endif /* STAGE90_XNU_PC_CARRIER */\n#if defined(STAGE90_XNU_PC_CARRIER_CALLER)")
           == 1, "staged: the block opens immediately after 1035's #endif")
    expect(t1.count("#endif /* STAGE90_XNU_PC_CARRIER_CALLER */\n"
                    "#endif /* STAGE90_XNU_USTACK_PROBE */\n") == 1,
           "staged: the block closes immediately before 1025's #endif")
    rc2 = stage(r, do_apply=True)
    expect(rc2 == 0 and read(trap_path(r)) == t1, "second --apply is an idempotent no-op")
    rc3 = verify_off(r)
    expect(rc3 == 0, "--verify-off PASS on the staged tree")
    s = t1.find("#if defined(STAGE90_XNU_PC_CARRIER_CALLER) && STAGE90_XNU_PC_CARRIER_CALLER")
    e = t1.find("#endif /* STAGE90_XNU_PC_CARRIER_CALLER */")
    inside = t1[s:e]
    expect(all(("\"%s" % row) in inside for row in PCC2_ROWS), "every emitted row is inside the gated block")
    expect(len(PCC2_ROWS) == (12 + 2 + 2 + 2 + 2) + 32, "row count is 14 single + 4 value/ok + 32 slot rows")
    expect("_evf" not in inside and "_pcc " not in inside and "_pcc_" not in inside, "the block never names an earlier sibling's locals")
    # the shape 1035's evf_closes_inside_1025 accepts: whole sibling block then 1025's #endif
    # the scan is 1033's own, verbatim (tools/patch_d13_eval_frame.py evf_closes_inside_1025), replayed
    # over the fixture: walk whole blocks from 1025's #endif until 1025's own close line is reached.
    # (The first draft here searched forward from 1025's `#if` for 1035's close and landed on 1036's
    # own close line -- the scanner read its own output.)
    blocks = re.compile(r"#if defined\((STAGE90_[A-Z0-9_]+)\) && \1\n.*?#endif /\* \1 \*/\n", re.S)
    off0 = t1.find("#endif /* STAGE90_XNU_USTACK_PROBE */\n") + 1
    off1 = t1.find("#endif /* STAGE90_XNU_EVAL_FRAME */\n") + len("#endif /* STAGE90_XNU_EVAL_FRAME */\n")
    m0 = blocks.match(t1, off1)
    expect(m0 is not None and m0.group(1) == "STAGE90_XNU_PC_CARRIER", "the fixture's 1035 block is a whole block")
    m = blocks.match(t1, m0.end()) if m0 is not None else None
    # (the block's own closing line is part of the match, so the suffix begins at 1025's close)
    expect(m is not None and m.group(1) == SWITCH
           and t1.startswith("#endif /* STAGE90_XNU_USTACK_PROBE */\n", m.end()),
           "1033's structural scan accepts 1036 as a whole later sibling block")

    r2 = tree("noanchor", base.replace("#endif /* STAGE90_XNU_PC_CARRIER */\n", ""))
    before = read(trap_path(r2))
    ok2, _, _, msg2 = check_trap(r2)
    expect(not ok2 and "expected exactly 1" in msg2, "missing 1035 tail: REFUSE (%s)" % msg2)
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
    write(trap_path(r4), t4.replace("#endif /* STAGE90_XNU_PC_CARRIER_CALLER */\n",
                                    "#endif /* STAGE90_XNU_PC_CARRIER_CALLER */\n"
                                    "\t\t\t\t\tprintf(\"xnu_live_pcc2_seq=%u\\n\", 0U);\n"))
    expect(verify_off(r4) != 0, "--verify-off FAILS when one row escapes the gate")

    if fails:
        print("SELFTEST FAIL: " + " | ".join(fails), file=sys.stderr)
        return 1
    print("SELFTEST PASS (13 checks: plan/apply/idempotent/bracket/namespace/OFF-can-fail)")
    return 0


def main(argv):
    if "--selftest" in argv:
        return selftest()
    if len(argv) < 2:
        print("usage: patch_d13_pc_carrier_caller.py <xnu_root> [--apply|--verify-off] [--selftest]",
              file=sys.stderr)
        return 2
    xnu = argv[1]
    if "--verify-off" in argv:
        return verify_off(xnu)
    return stage(xnu, do_apply="--apply" in argv)


if __name__ == "__main__":
    sys.exit(main(sys.argv))