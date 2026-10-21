#!/usr/bin/env python3
"""1033 -- READ THE 1032 FRAME BY VALUE (the eval-frame probe).  INSTRUMENT ONLY.

1032 (records/1032-reading.txt) read FIX-PARTIAL: the 10-byte libobjc clamp removed the 1030 stack-end
WRITE, and the boot now ends with a DIFFERENT usermode data abort -- launchctl[2], EXC_BAD_ACCESS at
0x00000010, dfsr type 7, far(trunc)=0, after `launchd[1] has started up` -- printed only as the 1025

    xnu_live_abt_vmfkrv_far=0x00000000

which is `vm_map_trunc_page(dfar)` and therefore CANNOT tell dfar==0x10 from dfar==0x0.  1032's §6 named the
two rows it owed and no released probe carried:

    *(uint32_t *)((uintptr_t)arm_ctx->sp + 0x10)      the writer-frame's saved-lr slot
    arm_ctx->far, UNTRUNCATED                          the real DFAR

This rung publishes those (plus the frame's pc/lr/sp/cpsr, pc-far, the word AT far, and a decode of the
call site), INSIDE 1025's failure arm, AFTER 1031's caller block, on the SAME failing path.

THE MISREADING THIS RUNG EXISTS TO SEPARATE (docs/1033-design.md §2.5, §6).  A DATA abort's saved pc is the
FAULTING INSTRUCTION (FAR is the faulting address); the "+8 ⇒ subtract" rule belongs to sleh_undef (its pc
is a pointer into the image).  1032's published pc 0x37C26474 sits 0x18 above far 0x10 -- a number that is
the undefined-instruction +8 offset applied to 0x10, OR a coincidence.  The rows here decide by value:

    xnu_live_evf_pc, _far_raw, _pc_minus_far  -- the raw triple, uninterpreted
    xnu_live_evf_slot10 / _slot14 / _slot18   -- the words the frame's own sp holds (copyin only)
    xnu_live_evf_ptr_word                     -- the word AT far (copyin only; a NULL page has no word)
    xnu_live_evf_caller_r0/_r1/_r2            -- the caller's registers the callee left behind
    xnu_live_evf_pid / _ustack / _seq         -- WHICH process/thread/burst

COST DISCIPLINE.  copyin on an UNMAPPED address returns EFAULT on this tree but still goes through
vm_fault; every read here is therefore GUARDED: a read whose address is not inside the thread's own task
map (vm_map_lookup_entry, the 1026 idiom) is NOT ATTEMPTED and its row prints _ok=0 (the 1026 lesson: a
cell that cannot print its own confirming conjunct is not a reading).  At most 5 copyins per fault, all on
the failing path.  Reads only: no sleep, no allocation, no map mutation.

SITE -- osfmk/arm/trap.c, INSIDE 1025's failure arm, immediately AFTER 1031's block's own
`#endif /* STAGE90_XNU_CALLER_PROBE */` and BEFORE 1025's `#endif /* STAGE90_XNU_USTACK_PROBE */`.
arm_ctx / thread / map / dfar / code are all in scope there; 1031's `_cal_far` is NOT (its braces close).

SHARED NAMESPACE ([[mi4-one-file-many-rungs]]): trap.c is edited by 994/1020/1025/1026+1027/1029/1030/1031
and now 1033.  Every trap.c patcher's ALLOWED_IF_IDENTIFIERS must carry STAGE90_XNU_EVAL_FRAME; this
script carries the whole union.  With the switch undefined the tree compiles BYTE-IDENTICAL to the 1031
tree (`--verify-off`).  kern_exec.c is NOT edited (every proc fact used here, user_stack, is 1026's
existing xnu_live_abt_proc_ustack).

docs/1033-design.md.
"""
import os
import re
import sys

SWITCH = "STAGE90_XNU_EVAL_FRAME"

TRAP_REL = "osfmk/arm/trap.c"

# The 1031 block closes with `#endif /* STAGE90_XNU_CALLER_PROBE */` immediately followed by 1025's
# `#endif`.  Insert BETWEEN them.
TRAP_ANCHOR = ("#endif /* STAGE90_XNU_CALLER_PROBE */\n"
               "#endif /* STAGE90_XNU_USTACK_PROBE */\n")

TRAP_DONE_MARK = "xnu_live_evf_pc="

TRAP_BLOCK = (
    "#endif /* STAGE90_XNU_CALLER_PROBE */\n"
    "#if defined(STAGE90_XNU_EVAL_FRAME) && STAGE90_XNU_EVAL_FRAME\n"
    "\t\t\t\t\t/* 1033: READ THE 1032 FRAME BY VALUE (the eval frame).  INSTRUMENT ONLY -- no fix.  1032\n"
    "\t\t\t\t\t * published far only as vm_map_trunc_page(dfar)=0, which cannot tell dfar 0x10 from 0, and\n"
    "\t\t\t\t\t * never carried the word at sp+0x10 its own section 6 owed.  Publish BOTH raw, the\n"
    "\t\t\t\t\t * frame's registers, pc-far, and the word AT far.  Every user read goes through copyin\n"
    "\t\t\t\t\t * AND is gated on vm_map_lookup_entry (a read that is not attempted prints _ok=0: a row\n"
    "\t\t\t\t\t * that cannot say its conjunct is not a reading).  READS only; failing path only;\n"
    "\t\t\t\t\t * vm_map_lookup_entry takes NO lock in this tree (the 1026/1027 idiom).\n"
    "\t\t\t\t\t * docs/1033-design.md 2. */\n"
    "\t\t\t\t\t{\n"
    "\t\t\t\t\t\tstatic unsigned _evf_seq;\n"
    "\t\t\t\t\t\textern unsigned xnu_live_abt_proc_ustack(void *);\n"
    "\t\t\t\t\t\tunsigned _evf_pc = (unsigned)arm_ctx->pc;\n"
    "\t\t\t\t\t\tunsigned _evf_lr = (unsigned)arm_ctx->lr;\n"
    "\t\t\t\t\t\tunsigned _evf_sp = (unsigned)arm_ctx->sp;\n"
    "\t\t\t\t\t\tunsigned _evf_far = (unsigned)arm_ctx->far;\n"
    "\t\t\t\t\t\tunsigned _evf_ust = xnu_live_abt_proc_ustack(thread->task->bsd_info);\n"
    "\t\t\t\t\t\tuint32_t _evf_w[5] = { 0U, 0U, 0U, 0U, 0U };\n"
    "\t\t\t\t\t\tboolean_t _evf_ok[5] = { FALSE, FALSE, FALSE, FALSE, FALSE };\n"
    "\t\t\t\t\t\tboolean_t _evf_ma[5];\n"
    "\t\t\t\t\t\tvm_map_entry_t _evf_e;\n"
    "\t\t\t\t\t\tunsigned _evf_src = 0U;\n"
    "\t\t\t\t\t\tunsigned _evf_i;\n"
    "\t\t\t\t\t\t_evf_ma[0] = vm_map_lookup_entry(map, _evf_sp + 0x10, &_evf_e);\n"
    "\t\t\t\t\t\t_evf_ma[1] = (_evf_sp <= 0xffffffe8U) ?\n"
    "\t\t\t\t\t\t    vm_map_lookup_entry(map, _evf_sp + 0x14, &_evf_e) : FALSE;\n"
    "\t\t\t\t\t\t_evf_ma[2] = (_evf_sp <= 0xffffffe4U) ?\n"
    "\t\t\t\t\t\t    vm_map_lookup_entry(map, _evf_sp + 0x18, &_evf_e) : FALSE;\n"
    "\t\t\t\t\t\t_evf_ma[3] = (_evf_far <= 0xfffffffcU) ?\n"
    "\t\t\t\t\t\t    vm_map_lookup_entry(map, _evf_far & ~3U, &_evf_e) : FALSE;\n"
    "\t\t\t\t\t\t/* (4) the word ENDING at lr by VALUE is *(lr & ~3) - 4: never dump the 4-byte word\n"
    "\t\t\t\t\t\t * AT lr (that formulation is 4 bytes off and reads the NEXT instruction). */\n"
    "\t\t\t\t\t\t_evf_ma[4] = (_evf_lr >= 4U && ((_evf_lr - 4U) & ~3U) <= 0xfffffffcU) ?\n"
    "\t\t\t\t\t\t    vm_map_lookup_entry(map, (_evf_lr - 4U) & ~3U, &_evf_e) : FALSE;\n"
    "\t\t\t\t\t\tfor (_evf_i = 0; _evf_i < 5U; _evf_i++) {\n"
    "\t\t\t\t\t\t\tunsigned _evf_a = (_evf_i == 0U) ? (_evf_sp + 0x10) :\n"
    "\t\t\t\t\t\t\t    (_evf_i == 1U) ? (_evf_sp + 0x14) :\n"
    "\t\t\t\t\t\t\t    (_evf_i == 2U) ? (_evf_sp + 0x18) :\n"
    "\t\t\t\t\t\t\t    (_evf_i == 3U) ? (_evf_far & ~3U) : ((_evf_lr - 4U) & ~3U);\n"
    "\t\t\t\t\t\t\tif (_evf_ma[_evf_i]) {\n"
    "\t\t\t\t\t\t\t\tint _evf_r = copyin((user_addr_t)(uintptr_t)_evf_a,\n"
    "\t\t\t\t\t\t\t\t    &_evf_w[_evf_i], sizeof(uint32_t));\n"
    "\t\t\t\t\t\t\t\t_evf_ok[_evf_i] = (_evf_r == 0);\n"
    "\t\t\t\t\t\t\t\tif (_evf_r != 0) _evf_src = 2U;\n"
    "\t\t\t\t\t\t\t}\n"
    "\t\t\t\t\t\t}\n"
    "\t\t\t\t\t\t_evf_seq++;\n"
    "\t\t\t\t\t\tprintf(\"xnu_live_evf_seq=%u\\n\", _evf_seq);\n"
    "\t\t\t\t\t\tprintf(\"xnu_live_evf_pid=%d\\n\", (int)(thread->task->bsd_info ? proc_pid(thread->task->bsd_info) : -1));\n"
    "\t\t\t\t\t\tprintf(\"xnu_live_evf_pc=0x%08x\\n\", _evf_pc);\n"
    "\t\t\t\t\t\tprintf(\"xnu_live_evf_lr=0x%08x\\n\", _evf_lr);\n"
    "\t\t\t\t\t\tprintf(\"xnu_live_evf_sp=0x%08x\\n\", _evf_sp);\n"
    "\t\t\t\t\t\tprintf(\"xnu_live_evf_cpsr=0x%08x\\n\", (unsigned)arm_ctx->cpsr);\n"
    "\t\t\t\t\t\tprintf(\"xnu_live_evf_far_raw=0x%08x\\n\", _evf_far);\n"
    "\t\t\t\t\t\tprintf(\"xnu_live_evf_far_trunc=0x%08x\\n\", (unsigned)vm_map_trunc_page(_evf_far));\n"
    "\t\t\t\t\t\tprintf(\"xnu_live_evf_far_is_0x10=%d\\n\", (int)(_evf_far == 0x10U));\n"
    "\t\t\t\t\t\tprintf(\"xnu_live_evf_far_is_0=%d\\n\", (int)(_evf_far == 0U));\n"
    "\t\t\t\t\t\tprintf(\"xnu_live_evf_dfsr_raw=0x%08x\\n\", (unsigned)dfsr);\n"
    "\t\t\t\t\t\tprintf(\"xnu_live_evf_fault_code=%d\\n\", (int)code);\n"
    "\t\t\t\t\t\tprintf(\"xnu_live_evf_pc_minus_far=0x%08x\\n\", (unsigned)(_evf_pc - _evf_far));\n"
    "\t\t\t\t\t\tprintf(\"xnu_live_evf_lr_minus_sp=0x%08x\\n\", (unsigned)(_evf_lr - _evf_sp));\n"
    "\t\t\t\t\t\tprintf(\"xnu_live_evf_caller_r0=0x%08x\\n\", (unsigned)arm_ctx->r[0]);\n"
    "\t\t\t\t\t\tprintf(\"xnu_live_evf_caller_r1=0x%08x\\n\", (unsigned)arm_ctx->r[1]);\n"
    "\t\t\t\t\t\tprintf(\"xnu_live_evf_caller_r2=0x%08x\\n\", (unsigned)arm_ctx->r[2]);\n"
    "\t\t\t\t\t\tprintf(\"xnu_live_evf_caller_r3=0x%08x\\n\", (unsigned)arm_ctx->r[3]);\n"
    "\t\t\t\t\t\tprintf(\"xnu_live_evf_caller_r7=0x%08x\\n\", (unsigned)arm_ctx->r[7]);\n"
    "\t\t\t\t\t\tprintf(\"xnu_live_evf_caller_r4_minus_sp=0x%08x\\n\", (unsigned)(arm_ctx->r[4] - _evf_sp));\n"
    "\t\t\t\t\t\tprintf(\"xnu_live_evf_slot10=0x%08x\\n\", (unsigned)_evf_w[0]);\n"
    "\t\t\t\t\t\tprintf(\"xnu_live_evf_slot10_ok=%d\\n\", (int)(_evf_ok[0] ? 1 : 0));\n"
    "\t\t\t\t\t\tprintf(\"xnu_live_evf_slot14=0x%08x\\n\", (unsigned)_evf_w[1]);\n"
    "\t\t\t\t\t\tprintf(\"xnu_live_evf_slot14_ok=%d\\n\", (int)(_evf_ok[1] ? 1 : 0));\n"
    "\t\t\t\t\t\tprintf(\"xnu_live_evf_slot18=0x%08x\\n\", (unsigned)_evf_w[2]);\n"
    "\t\t\t\t\t\tprintf(\"xnu_live_evf_slot18_ok=%d\\n\", (int)(_evf_ok[2] ? 1 : 0));\n"
    "\t\t\t\t\t\tprintf(\"xnu_live_evf_ptr_word=0x%08x\\n\", (unsigned)_evf_w[3]);\n"
    "\t\t\t\t\t\tprintf(\"xnu_live_evf_ptr_word_ok=%d\\n\", (int)(_evf_ok[3] ? 1 : 0));\n"
    "\t\t\t\t\t\tprintf(\"xnu_live_evf_lr_slot=0x%08x\\n\", (unsigned)_evf_w[4]);\n"
    "\t\t\t\t\t\tprintf(\"xnu_live_evf_lr_slot_ok=%d\\n\", (int)(_evf_ok[4] ? 1 : 0));\n"
    "\t\t\t\t\t\tprintf(\"xnu_live_evf_read_src=%u\\n\", _evf_src);\n"
    "\t\t\t\t\t\tprintf(\"xnu_live_evf_ustack=0x%08x\\n\", _evf_ust);\n"
    "\t\t\t\t\t}\n"
    "#endif /* STAGE90_XNU_EVAL_FRAME */\n"
    "#endif /* STAGE90_XNU_USTACK_PROBE */\n"
)

# Every row the block emits -- the checker's KEYS/parity list and the build's string gate both read THIS.
EVF_ROWS = (
    "xnu_live_evf_seq=", "xnu_live_evf_pid=", "xnu_live_evf_pc=", "xnu_live_evf_lr=",
    "xnu_live_evf_sp=", "xnu_live_evf_cpsr=", "xnu_live_evf_far_raw=", "xnu_live_evf_far_trunc=",
    "xnu_live_evf_far_is_0x10=", "xnu_live_evf_far_is_0=", "xnu_live_evf_dfsr_raw=",
    "xnu_live_evf_fault_code=", "xnu_live_evf_pc_minus_far=", "xnu_live_evf_lr_minus_sp=",
    "xnu_live_evf_caller_r0=", "xnu_live_evf_caller_r1=", "xnu_live_evf_caller_r2=",
    "xnu_live_evf_caller_r3=", "xnu_live_evf_caller_r7=", "xnu_live_evf_caller_r4_minus_sp=",
    "xnu_live_evf_slot10=", "xnu_live_evf_slot10_ok=", "xnu_live_evf_slot14=", "xnu_live_evf_slot14_ok=",
    "xnu_live_evf_slot18=", "xnu_live_evf_slot18_ok=", "xnu_live_evf_ptr_word=", "xnu_live_evf_ptr_word_ok=",
    "xnu_live_evf_lr_slot=", "xnu_live_evf_lr_slot_ok=", "xnu_live_evf_read_src=", "xnu_live_evf_ustack=",
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
    "STAGE90_XNU_EVAL_FRAME",         # 1033 (this rung)
    "STAGE90_XNU_PC_CARRIER",         # 1035
    "STAGE90_XNU_PC_CARRIER_CALLER",  # 1036
    "STAGE90_XNU_TRAP_FRAME",  # 1037 (tools/patch_d13_trap_frame.py)
    "STAGE90_XNU_FRAME_CARRIER"}  # 1039 (tools/patch_d13_frame_carrier.py)


def read(p):
    with open(p) as f:
        return f.read()


def write(p, t):
    with open(p, "w") as f:
        f.write(t)


def if_stage90_ids(text):
    # LINE-STARTING directives only, and an id must stand WHOLE (a prefix of a longer id, or one quoted
    # inside 1038's staged string literal, is not a directive ID) -- [[mi4-one-file-many-rungs]]
    dirs = [m.group(1) for m in re.finditer(r"^[ \t]*#\s*(?:if|elif|ifdef|ifndef)\b(.*)$", text, re.M)]
    ids = set()
    for e in dirs:
        ids.update(i for i in re.findall(r"[A-Za-z_][A-Za-z0-9_]*", e) if i.startswith("STAGE90_"))
    whole = set()
    for e in dirs:
        e = re.sub(r'"(?:[^"\\]|\\.)*"', "", e)
        whole.update(i for i in re.findall(r"(?<![A-Za-z0-9_])[A-Za-z_][A-Za-z0-9_]*", e) if i in ids)
    return whole


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
            "%s's directives also evaluate %s. trap.c is edited by EIGHT rungs "
            "(994/1020/1025/1026/1029/1030/1031/1033) and a file's directive identifiers are a SHARED "
            "namespace: add the new switch to TRAP_ALLOWED_IF_IDENTIFIERS here and to the other "
            "patchers' sets. ([[mi4-one-file-many-rungs]])" % (TRAP_REL, ", ".join(foreign)))
    if t.count(TRAP_ANCHOR) != 1:
        return False, p, t, (
            "the CALLER_PROBE/USTACK_PROBE `#endif` tail occurs %d time(s), expected exactly 1. The tree "
            "is not in the state this rung was written against (1031's block is not staged, or a "
            "displaced anchor / partial edit)." % t.count(TRAP_ANCHOR))
    return True, p, t, "anchor unique, switch absent"


def stage(xnu, do_apply):
    ok_t, tp, t, msg_t = check_trap(xnu)
    if not ok_t:
        print("patch_d13_eval_frame: REFUSE (trap.c) - %s. Writing nothing." % msg_t, file=sys.stderr)
        return 1
    if msg_t == "already staged":
        print("patch_d13_eval_frame: already staged - no-op, OK.")
        return 0
    print("   trap.c : %s." % msg_t)
    if not do_apply:
        print("patch_d13_eval_frame: plan OK (dry run; pass --apply to write).")
        return 0
    write(tp, t.replace(TRAP_ANCHOR, TRAP_BLOCK))
    print("   trap.c : staged Site A (xnu_live_evf_* rows, %d) after 1031's block, inside 1025's arm."
          % len(EVF_ROWS))
    return 0


def evf_closes_inside_1025(t):
    """True iff this block's #endif closes inside 1025's publisher: after it come zero or more WHOLE
    STAGE90 sibling blocks (`#if defined(SW) && SW` .. `#endif /* SW */`), then 1025's #endif.
    Literal adjacency was true while this was the last sibling; 1035's pc_carrier appends after it
    (47df67c's rule, [[mi4-one-file-many-rungs]]: a new rung re-stages and the OFF proofs must
    accept a whole later block)."""
    close = "#endif /* %s */\n" % SWITCH
    blocks = re.compile(r"#if defined\((STAGE90_[A-Z0-9_]+)\) && \1\n.*?#endif /\* \1 \*/\n", re.S)
    # (1040) 1025's arm re-opens its bracket a second time (the first close shuts the region 1025 wrote
    # its publisher in; the rows live in the PUBLISHER, which the next plain close shuts).  The re-open
    # is one more "later whole thing" for this scan; the bracket's pairing is the build's to prove.
    reopen = "#if defined(STAGE90_XNU_USTACK_PROBE) && STAGE90_XNU_USTACK_PROBE\n"
    for m in re.finditer(re.escape(close), t):
        rest = t[m.end():]
        pos, ok = 0, True
        while True:
            if rest.startswith("#endif /* STAGE90_XNU_USTACK_PROBE */\n", pos):
                return True
            # 1025's arm re-opens its bracket a second time behind 1036's block so 1037's block lands
            # inside it.  NB `#if defined(STAGE90_XNU_USTACK_PROBE) && STAGE90_XNU_USTACK_PROBE` is a
            # PREFIX of the close's raw text (`#endif /* STAGE90_XNU_USTACK_PROBE */`), so a raw splice
            # would answer "open" where the preprocessor closes: classify by LINE, not by prefix.
            if rest.startswith(reopen, pos):
                nxt = rest[pos + len(reopen):]
                line = nxt[:(nxt.find("\n") + 1) if nxt.find("\n") >= 0 else len(nxt)]
                if line.lstrip().startswith("#endif"):
                    return True          # the close, ordered exactly (the close line's own end)
                pos += len(reopen)
                continue
            b = blocks.match(rest, pos)
            if b is None:
                break
            pos = b.end()
    return False


def verify_off(xnu):
    """With the switch undefined the preprocessor removes the whole block -> the 1031 tree's text."""
    tp = trap_path(xnu)
    if not os.path.isfile(tp):
        print("patch_d13_eval_frame: --verify-off: no %s" % tp, file=sys.stderr)
        return 1
    t = read(tp)
    if SWITCH not in t:
        print("patch_d13_eval_frame: --verify-off: switch ABSENT (nothing staged).", file=sys.stderr)
        return 1
    have = (t.count(TRAP_DONE_MARK) == 1
            and t.count("#if defined(%s) && %s\n" % (SWITCH, SWITCH)) == 1
            and t.count("#endif /* %s */\n" % SWITCH) == 1)
    between = t.count("#endif /* STAGE90_XNU_CALLER_PROBE */\n#if defined(%s)" % SWITCH) == 1
    tail = evf_closes_inside_1025(t)
    # every emitted row is INSIDE the gated block (so OFF removes it, not just the switch name)
    s = t.find("#if defined(%s) && %s" % (SWITCH, SWITCH))
    e = t.find("#endif /* %s */" % SWITCH)
    inside = t[s:e] if (s >= 0 and e > s) else ""
    missing = [r for r in EVF_ROWS if ("\"%s" % r) not in inside]
    print("   trap.c [ON] : xnu_live_evf_pc row present + one #if/#endif pair: %s" % have)
    print("   trap.c      : the block sits immediately after 1031's, inside 1025's publisher: %s" % between)
    print("   trap.c      : it closes inside 1025's publisher (whole sibling blocks allowed after it): %s" % tail)
    print("   trap.c      : all %d rows inside the gated block: %s"
          % (len(EVF_ROWS), "yes" if not missing else "NO: %s" % ", ".join(missing)))
    if have and between and tail and not missing:
        print("patch_d13_eval_frame: --verify-off PASS (all edits gated on the switch; OFF removes "
              "them -> the 1031 tree bytes).")
        return 0
    print("patch_d13_eval_frame: --verify-off FAIL.", file=sys.stderr)
    return 1


# ---------------------------------------------------------------- selftest

def selftest():
    import tempfile
    fails = []
    tmp = tempfile.mkdtemp(prefix="p1033-")

    def mk(name, text):
        p = os.path.join(tmp, name)
        with open(p, "w") as f:
            f.write(text)
        return p

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

    base = ("\t\t\t\t\t{\n\t\t\t\t\t\tint _x = 0; (void)_x;\n\t\t\t\t\t}\n"
            "#endif /* STAGE90_XNU_WRITER_PROBE */\n"
            "\t\t\t\t\t{ int _cal = 0; (void)_cal; }\n"
            "#endif /* STAGE90_XNU_CALLER_PROBE */\n"
            "#endif /* STAGE90_XNU_USTACK_PROBE */\n"
            "\t\t\t\t\t{\n\t\t\t\t\t\t/* after */\n\t\t\t\t\t}\n")
    base = ("#if defined(STAGE90_XNU_USTACK_PROBE) && STAGE90_XNU_USTACK_PROBE\n"
            "#if defined(STAGE90_XNU_WRITER_PROBE) && STAGE90_XNU_WRITER_PROBE\n"
            + base)
    r = tree("good", base)

    ok, p, t, msg = check_trap(r)
    expect(ok and msg == "anchor unique, switch absent", "the 1031 tree: plan accepts it (%s)" % msg)

    # --apply stages; the rows land BETWEEN 1031's #endif and 1025's; a second apply is a no-op
    rc = stage(r, do_apply=True)
    t1 = read(trap_path(r))
    expect(rc == 0 and t1.count("\"xnu_live_evf_pc=") == 1, "staged: exactly one evf pc row")
    expect((t1.count("#if defined(STAGE90_XNU_EVAL_FRAME) && STAGE90_XNU_EVAL_FRAME\n") == 1
            and t1.count("#endif /* STAGE90_XNU_EVAL_FRAME */\n") == 1),
           "staged: exactly one #if/#endif pair for the switch")
    expect(t1.count("#endif /* STAGE90_XNU_CALLER_PROBE */\n#if defined(STAGE90_XNU_EVAL_FRAME)")
           == 1, "staged: the block opens immediately after 1031's #endif")
    expect(evf_closes_inside_1025(t1),
           "staged: the block closes inside 1025's publisher (zero or more whole STAGE90 sibling blocks follow it, then 1025's #endif -- 47df67c's structural form; 1035 appended pc_carrier after it)")
    rc2 = stage(r, do_apply=True)
    expect(rc2 == 0 and read(trap_path(r)) == t1, "second --apply is an idempotent no-op")
    rc3 = verify_off(r)
    expect(rc3 == 0, "--verify-off PASS on the staged tree")
    s = t1.find("#if defined(STAGE90_XNU_EVAL_FRAME)")
    e = t1.find("#endif /* STAGE90_XNU_EVAL_FRAME */")
    inside = t1[s:e]
    expect(all(("\"%s" % row) in inside for row in EVF_ROWS), "every emitted row is inside the gated block")
    expect("_cal_far" not in inside, "the eval block never names 1031's block-local _cal_far")

    # a tree whose 1031 tail is absent -> refuse, write nothing
    r2 = tree("noanchor", base.replace("#endif /* STAGE90_XNU_CALLER_PROBE */\n", ""))
    before = read(trap_path(r2))
    ok2, _, _, msg2 = check_trap(r2)
    expect(not ok2 and "expected exactly 1" in msg2, "missing 1031 tail: REFUSE (%s)" % msg2)
    expect(read(trap_path(r2)) == before, "a refused stage writes nothing")

    # a foreign switch in the tree -> the namespace proof fires
    r3 = tree("foreign", base.replace("#endif /* STAGE90_XNU_WRITER_PROBE */\n",
                                      "#endif /* STAGE90_XNU_WRITER_PROBE */\n"
                                      "#if defined(STAGE90_XNU_NOBODY_ADDED_ME) && STAGE90_XNU_NOBODY_ADDED_ME\n"
                                      "#endif /* STAGE90_XNU_NOBODY_ADDED_ME */\n"))
    ok3, _, _, msg3 = check_trap(r3)
    expect(not ok3 and "STAGE90_XNU_NOBODY_ADDED_ME" in msg3, "a foreign identifier: REFUSE")

    # the OFF proof can FAIL: a row moved OUTSIDE the gated block is caught
    r4 = tree("leak", base)
    stage(r4, do_apply=True)
    t4 = read(trap_path(r4))
    leak = t4.replace("#endif /* STAGE90_XNU_EVAL_FRAME */\n", "#endif /* STAGE90_XNU_EVAL_FRAME */\n"
                      "\t\t\t\t\tprintf(\"xnu_live_evf_seq=%u\\n\", 0U);\n")
    write(trap_path(r4), leak)
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
        print("usage: patch_d13_eval_frame.py <xnu_root> [--apply|--verify-off] [--selftest]",
              file=sys.stderr)
        return 2
    xnu = argv[1]
    if "--verify-off" in argv:
        return verify_off(xnu)
    return stage(xnu, do_apply="--apply" in argv)


if __name__ == "__main__":
    sys.exit(main(sys.argv))