#!/usr/bin/env python3
"""1037 -- THE TRAP FRAME BY VALUE (trap entry's saved user state vs. the C-side arm_ctx).  INSTRUMENT ONLY.

1036 (records/1036-read.txt) established that the evf/pcc/pcc2 rows are NOT the trap frame (pc moves run to
run while its neighbourhood does not; an ARM-only path yields an ODD lr and an ODD r10).  1037 compares the
trap entry's OWN save with what C reads: traps_lo.s `data_abort_crash_in_usermode` does

    LoadThreadRegister(sp); ldr sp,[sp,TH_PCB_USS]; stmea sp,{r0-lr}^   ; r0-lr at +0x00..+0x38
    str lr,[sp,#0x3C]; str spsr,[sp,#0x40]; str dfsr,[sp,#0x44]; str dfar,[sp,#0x48]
    mov r0, sp ; ... blx _sleh_abort

so `context` (=> trap.c's `arm_ctx`) IS the user uss VA (thread->machine.uss), and the record occupies
0x4C bytes there.  This block reads that record back THROUGH THE TASK MAP and compares word for word with
`arm_ctx`, derives the slide from pc as an EXPRESSION, checks lr's return word against the file, and reads
the halfword at the walk's load site.

    xnu_live_fb_seq / _pid / _pc / _lr / _sp_tr / _sp
    xnu_live_fb_uss / _uss_ok / _uss_armctx_diff           (arm_ctx vs thread->machine.uss, an address check)
    xnu_live_fb_uss_r0 .. _uss_r12 / _uss_sp / _uss_lr / _uss_pc   (17 rows + _ok each, TASK-MAP reads)
    xnu_live_fb_ctx_diff                                    (bit i: uss word i != arm_ctx word i; 13 sp, 14 lr, 15 pc)
    xnu_live_fb_slide                                       (arm_ctx->pc - 0x37C26474u, an expression)
    xnu_live_fb_lr_xor4 / _lr_xor8 + _ok each               (device word ^ file word at (lr - slide) - 4/-8)
    xnu_live_fb_ldrh / _ldrh_ok                             (halfword at 0x37C26474 + slide via the task map)
    xnu_live_fb_dbg_off / _dbg_off_ok                       (debug_buf_ptr - debug_buf; the 1036 tail bound)

THE DEVICE PAGE AND THE FILE PAGE.  The device maps the shared cache at FILE VA + slide (1037-design 1(iv)),
so a device word at device VA V corresponds to the file word at FILE VA V - slide.  `slide =
arm_ctx->pc - 0x37C26474` is emitted exactly as 1037 pre-registers it (records/1037-read.txt: the walk's
load's file VA minus 0x37C26474, the device VA the walk's row carries).  As an expression it moves every
run (pc moves run to run, 1036-read 3); the same pre-registration fixes the consistency demand: the file
must hold 0x7C09 at (0x37C26474 + slide).  Its arithmetic sign is the design's, not this patcher's --
the capture decides, and the row is printed raw.

fb_sp is the CURRENT kernel sp, captured with inline asm `__asm__("mov %0, sp")` INSIDE the block (a
top-level asm, not a barriered volatile one, so it creates no local barrier; the compiler in use is the
tree's armv7 clang which supports `mov %0, sp` on this target; there is no __builtin for sp and
__builtin_frame_address is NOT sp).  fb_sp_tr is `arm_ctx->sp`: in this function arm_ctx IS the trap
frame (see above), so fb_sp_tr and fb_sp differ only by the C frames sleh_abort pushed on TH_PCB_ISS.

fb_dbg_off: kern/debug.h (lines 118, 157-158) declares debug_buf[] / debug_buf_ptr / debug_buf_size, and
debug.c:118-120 defines them; trap.c includes kern/thread.h but NOT kern/debug.h.  The block does NOT
include debug.h (it would enter trap.c's top-level directive namespace on OFF builds); it declares the
three externs itself, exactly as debug.h does.  If the link ever rejects them, an undefined symbol stops
the build of THIS rung only -- that is the signal, not a silent _ok=0.

Each user read is the 1035 guarded idiom: word-aligned, address >= 4, vm_map_lookup_entry(task map),
copyin; a read not attempted prints 0 / _ok=0.  pid 2 only, first 4 faults, failing path only.  For the
halfword, copyin reads a word at the aligned address and the block selects by address bit 1 (the task map
is a byte-granularity map; no separate halfword union is assumed).  Reads only: no sleep, no allocation,
no map mutation, no write.  vm_map_lookup_entry takes NO lock in this tree (the 1026/1033/1035/1036 idiom).

SITE -- osfmk/arm/trap.c, INSIDE 1025's failure arm, IMMEDIATELY AFTER 1036's block's
`#endif /* STAGE90_XNU_PC_CARRIER_CALLER */` (the first such line) and so immediately before 1025's own
`#endif`.  arm_ctx / thread / map are in scope; no other block's locals are.

SHARED NAMESPACE ([[mi4-one-file-many-rungs]]): every trap.c patcher's ALLOWED_IF_IDENTIFIERS must carry
STAGE90_XNU_TRAP_FRAME.  With the switch undefined the tree compiles to the 1036 tree's bytes
(`--verify-off`).

docs/1037-design.md; records/1037-read.txt.
"""
import os
import re
import sys

SWITCH = "STAGE90_XNU_TRAP_FRAME"

TRAP_REL = "osfmk/arm/trap.c"

# 1036's block closes with `#endif /* STAGE90_XNU_PC_CARRIER_CALLER */` immediately before 1025's
# `#endif`.  Insert BETWEEN them.
TRAP_ANCHOR = ("#endif /* STAGE90_XNU_PC_CARRIER_CALLER */\n"
               "#endif /* STAGE90_XNU_USTACK_PROBE */\n")

TRAP_DONE_MARK = "xnu_live_fb_pc="

I = "\t\t\t\t\t"   # the indent of every block in 1025's arm

_USS_ROWS = ("r0 r1 r2 r3 r4 r5 r6 r7 r8 r9 r10 r11 r12 sp lr pc".split())
# uss record word index of each read: r0..r12 => 0..12, sp => 13, lr => 14, pc => 15
_USS_IDX = dict((n, k) for k, n in enumerate(_USS_ROWS))

TRAP_BLOCK = (
    "#endif /* STAGE90_XNU_PC_CARRIER_CALLER */\n"
    "#if defined(STAGE90_XNU_TRAP_FRAME) && STAGE90_XNU_TRAP_FRAME\n"
    + I + "/* 1037: THE TRAP FRAME BY VALUE.  INSTRUMENT ONLY -- no fix.  traps_lo.s's\n"
    + I + " * data_abort_crash_in_usermode writes 19 words + cpsr/dfsr/dfar at TH_PCB_USS and passes that\n"
    + I + " * VA as `context`, so arm_ctx IS the user record; read it back through the task map and compare\n"
    + I + " * it with arm_ctx word for word (mask bits), derive the slide from pc as an expression, xor lr's\n"
    + I + " * return word with the file's, and read the halfword at the walk's load site.  Every user read\n"
    + I + " * is copyin AND gated on vm_map_lookup_entry (a read not attempted prints 0 / _ok=0).\n"
    + I + " * pid 2 only, first 4 faults, failing path only.  READ ONLY.  docs/1037-design.md. */\n"
    + I + "if ((int)(thread->task->bsd_info ? proc_pid(thread->task->bsd_info) : -1) == 2) {\n"
    + I + "\tstatic unsigned _fb_seq;\n"
    + I + "\tif (_fb_seq < 4U) {\n"
    + I + "\t\t/* kern/debug.h:118,157-158 declares these; debug.c:118-120 defines them. */\n"
    + I + "\t\textern char debug_buf[];\n"
    + I + "\t\textern char *debug_buf_ptr;\n"
    + I + "\t\textern unsigned int debug_buf_size;\n"
    + I + "\t\tunsigned _fb_pc = (unsigned)arm_ctx->pc;\n"
    + I + "\t\tunsigned _fb_lr = (unsigned)arm_ctx->lr;\n"
    + I + "\t\tunsigned _fb_uss = (unsigned)(uintptr_t)arm_ctx;\n"
    + I + "\t\tunsigned _fb_slide = _fb_pc - 0x37C26474u;      /* EXPRESSION, as pre-registered */\n"
    + I + "\t\tunsigned _fb_a[22];\n"
    + I + "\t\tuint32_t _fb_w[22];\n"
    + I + "\t\tboolean_t _fb_ok[22];\n"
    + I + "\t\tunsigned _fb_sp_now, _fb_diff = 0U, _fb_ldrh = 0U;\n"
    + I + "\t\tboolean_t _help = FALSE;\n"
    + I + "\t\tvm_map_entry_t _fb_e;\n"
    + I + "\t\tunsigned _fb_i;\n"
    + I + "\t\t__asm__(\"mov %0, sp\" : \"=r\" (_fb_sp_now));\n"
    + I + "\t\t/* 0..15: the uss record r0..r12, sp, lr, pc */\n"
    + I + "\t\tfor (_fb_i = 0; _fb_i < 16U; _fb_i++) {\n"
    + I + "\t\t\t_fb_a[_fb_i] = _fb_uss + 4U * _fb_i;\n"
    + I + "\t\t}\n"
    + I + "\t\t/* 16,17: the device word at lr-4 / lr-8; 18,19: the FILE word at (lr - slide) - 4 / - 8. */\n"
    + I + "\t\t_fb_a[16] = _fb_lr - 4U;\n"
    + I + "\t\t_fb_a[17] = _fb_lr - 8U;\n"
    + I + "\t\t_fb_a[18] = (_fb_lr - _fb_slide) - 4U;\n"
    + I + "\t\t_fb_a[19] = (_fb_lr - _fb_slide) - 8U;\n"
    + I + "\t\t/* 20: a word containing the walk's halfword: the aligned VA (0x37C26474 + slide) if its\n"
    + I + "\t\t * bit 1 is clear, else one below.  (No halfword union: selection is by address bit 1.) */\n"
    + I + "\t\t_fb_a[20] = (0x37C26474u + _fb_slide) & ~2U;\n"
    + I + "\t\t_fb_a[21] = _fb_uss;   /* a halfword probe of the record's own head: uss_ok discriminator */\n"
    + I + "\t\t/* (ir[bx]) extends as unsigned => FAT registers wrap to a HIGH address, which the at-or-above-4\n"
    + I + "\t\t * / at-or-below-0xfffffffc pair rejects un-attempted. */\n"
    + I + "\t\tfor (_fb_i = 0; _fb_i < 22U; _fb_i++) {\n"
    + I + "\t\t\tunsigned _fb_m = _fb_a[_fb_i] & ~3U;\n"
    + I + "\t\t\t_fb_w[_fb_i] = 0U;\n"
    + I + "\t\t\t_fb_ok[_fb_i] = FALSE;\n"
    + I + "\t\t\tif (_fb_a[_fb_i] >= 4U && _fb_m <= 0xfffffffcU &&\n"
    + I + "\t\t\t    vm_map_lookup_entry(map, _fb_m, &_fb_e)) {\n"
    + I + "\t\t\t\t_fb_ok[_fb_i] = (copyin((user_addr_t)(uintptr_t)_fb_m,\n"
    + I + "\t\t\t\t    (char *)&_fb_w[_fb_i], 4) == 0);\n"
    + I + "\t\t\t}\n"
    + I + "\t\t}\n"
    + I + "\t\t/* the mask: computed here by walking BOTH bases, not assumed */\n"
    + I + "\t\tif (_fb_ok[0]) {\n"
    + I + "\t\t\tfor (_fb_i = 0; _fb_i < 16U; _fb_i++) {\n"
    + I + "\t\t\t\tunsigned _fb_c = (_fb_i < 13U) ? (unsigned)arm_ctx->r[_fb_i]\n"
    + I + "\t\t\t\t    : (_fb_i == 13U) ? (unsigned)arm_ctx->sp\n"
    + I + "\t\t\t\t    : (_fb_i == 14U) ? (unsigned)arm_ctx->lr : (unsigned)arm_ctx->pc;\n"
    + I + "\t\t\t\tif (_fb_w[_fb_i] != _fb_c) {\n"
    + I + "\t\t\t\t\t_fb_diff |= (1U << _fb_i);\n"
    + I + "\t\t\t\t}\n"
    + I + "\t\t\t}\n"
    + I + "\t\t}\n"
    + I + "\t\t/* the halfword from the word read at _fb_a[20] (bit-1 select) */\n"
    + I + "\t\t_help = _fb_ok[20];\n"
    + I + "\t\tif (_help) {\n"
    + I + "\t\t\t_fb_ldrh = ((0x37C26474u + _fb_slide) & 2U) ? (_fb_w[20] >> 16) : (_fb_w[20] & 0xffffU);\n"
    + I + "\t\t}\n"
    + I + "\t\t_fb_seq++;\n"
    + I + "\t\tprintf(\"xnu_live_fb_seq=%u\\n\", _fb_seq);\n"
    + I + "\t\tprintf(\"xnu_live_fb_pid=%d\\n\", (int)proc_pid(thread->task->bsd_info));\n"
    + I + "\t\tprintf(\"xnu_live_fb_pc=0x%08x\\n\", _fb_pc);\n"
    + I + "\t\tprintf(\"xnu_live_fb_lr=0x%08x\\n\", _fb_lr);\n"
    + I + "\t\tprintf(\"xnu_live_fb_sp_tr=0x%08x\\n\", (unsigned)arm_ctx->sp);\n"
    + I + "\t\tprintf(\"xnu_live_fb_sp=0x%08x\\n\", _fb_sp_now);\n"
    + I + "\t\tprintf(\"xnu_live_fb_uss=0x%08x\\n\", _fb_uss);\n"
    + I + "\t\tprintf(\"xnu_live_fb_uss_ok=%d\\n\", (int)(_fb_ok[0] ? 1 : 0));\n"
    + I + "\t\tprintf(\"xnu_live_fb_uss_armctx_diff=0x%08x\\n\",\n"
    + I + "\t\t    (unsigned)(_fb_uss ^ (unsigned)(uintptr_t)thread->machine.uss));\n"
    + "".join(
        I + (("\t\tprintf(\"xnu_live_fb_uss_%s=0x%%08x\\n\", (unsigned)_fb_w[%d]);\n"
              "\t\tprintf(\"xnu_live_fb_uss_%s_ok=%%d\\n\", (int)(_fb_ok[%d] ? 1 : 0));\n")
             % (n, k, n, k)).replace("\n\t\t", "\n" + I + "\t\t")
        for n, k in _USS_IDX.items())
    + I + "\t\tprintf(\"xnu_live_fb_ctx_diff=0x%08x\\n\", _fb_diff);\n"
    + I + "\t\tprintf(\"xnu_live_fb_slide=0x%08x\\n\", _fb_slide);\n"
    + I + "\t\tprintf(\"xnu_live_fb_lr_xor4=0x%08x\\n\",\n"
    + I + "\t\t    (unsigned)(_fb_ok[16] && _fb_ok[18] ? (_fb_w[16] ^ _fb_w[18]) : 0U));\n"
    + I + "\t\tprintf(\"xnu_live_fb_lr_xor4_ok=%d\\n\", (int)((_fb_ok[16] && _fb_ok[18]) ? 1 : 0));\n"
    + I + "\t\tprintf(\"xnu_live_fb_lr_xor8=0x%08x\\n\",\n"
    + I + "\t\t    (unsigned)(_fb_ok[17] && _fb_ok[19] ? (_fb_w[17] ^ _fb_w[19]) : 0U));\n"
    + I + "\t\tprintf(\"xnu_live_fb_lr_xor8_ok=%d\\n\", (int)((_fb_ok[17] && _fb_ok[19]) ? 1 : 0));\n"
    + I + "\t\tprintf(\"xnu_live_fb_ldrh=0x%04x\\n\", (unsigned)_fb_ldrh);\n"
    + I + "\t\tprintf(\"xnu_live_fb_ldrh_ok=%d\\n\", (int)(_help ? 1 : 0));\n"
    + I + "\t\tprintf(\"xnu_live_fb_dbg_off=0x%08x\\n\",\n"
    + I + "\t\t    (debug_buf_ptr != 0)\n"
    + I + "\t\t    ? (unsigned)((uintptr_t)debug_buf_ptr - (uintptr_t)debug_buf) : 0U);\n"
    + I + "\t\tprintf(\"xnu_live_fb_dbg_off_ok=%d\\n\",\n"
    + I + "\t\t    (int)((debug_buf_ptr != 0\n"
    + I + "\t\t    && (unsigned)((uintptr_t)debug_buf_ptr - (uintptr_t)debug_buf) < debug_buf_size) ? 1 : 0));\n"
    + I + "\t}\n"
    + I + "}\n"
    "#endif /* STAGE90_XNU_TRAP_FRAME */\n"
    "#endif /* STAGE90_XNU_USTACK_PROBE */\n"
)

# Every row the block emits -- the build's row gate and any checker read THIS.
FB_ROWS = (
    ("xnu_live_fb_seq=", "xnu_live_fb_pid=", "xnu_live_fb_pc=", "xnu_live_fb_lr=",
     "xnu_live_fb_sp_tr=", "xnu_live_fb_sp=", "xnu_live_fb_uss=", "xnu_live_fb_uss_ok=",
     "xnu_live_fb_uss_armctx_diff=", "xnu_live_fb_ctx_diff=", "xnu_live_fb_slide=",
     "xnu_live_fb_lr_xor4=", "xnu_live_fb_lr_xor4_ok=", "xnu_live_fb_lr_xor8=", "xnu_live_fb_lr_xor8_ok=",
     "xnu_live_fb_ldrh=", "xnu_live_fb_ldrh_ok=", "xnu_live_fb_dbg_off=", "xnu_live_fb_dbg_off_ok=")
    + tuple("xnu_live_fb_uss_%s=" % n for n in _USS_ROWS)
    + tuple("xnu_live_fb_uss_%s_ok=" % n for n in _USS_ROWS)
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
    "STAGE90_XNU_PC_CARRIER",         # 1035
    "STAGE90_XNU_PC_CARRIER_CALLER",  # 1036 (this block's immediate predecessor)
    "STAGE90_XNU_TRAP_FRAME",         # 1037 (this rung)
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
            "%s's directives also evaluate %s. trap.c is edited by ELEVEN rungs "
            "(994/1020/1025/1026/1029/1030/1031/1033/1035/1036/1037) and a file's directive identifiers "
            "are a SHARED namespace: add the new switch to TRAP_ALLOWED_IF_IDENTIFIERS here and to the "
            "other patchers' sets. ([[mi4-one-file-many-rungs]])" % (TRAP_REL, ", ".join(foreign)))
    if t.count(TRAP_ANCHOR) != 1:
        return False, p, t, (
            "the PC_CARRIER_CALLER/USTACK_PROBE `#endif` tail occurs %d time(s), expected exactly 1. The "
            "tree is not in the state this rung was written against (1036's block is not staged, or a "
            "displaced anchor / partial edit)." % t.count(TRAP_ANCHOR))
    return True, p, t, "anchor unique, switch absent"


def stage(xnu, do_apply):
    ok_t, tp, t, msg_t = check_trap(xnu)
    if not ok_t:
        print("patch_d13_trap_frame: REFUSE (trap.c) - %s. Writing nothing." % msg_t, file=sys.stderr)
        return 1
    if msg_t == "already staged":
        print("patch_d13_trap_frame: already staged - no-op, OK.")
        return 0
    print("   trap.c : %s." % msg_t)
    if not do_apply:
        print("patch_d13_trap_frame: plan OK (dry run; pass --apply to write).")
        return 0
    write(tp, t.replace(TRAP_ANCHOR, TRAP_BLOCK))
    print("   trap.c : staged (xnu_live_fb_* rows, %d) after 1036's block, inside 1025's arm."
          % len(FB_ROWS))
    return 0


def verify_off(xnu):
    """With the switch undefined the preprocessor removes the whole block -> the 1036 tree's text."""
    tp = trap_path(xnu)
    if not os.path.isfile(tp):
        print("patch_d13_trap_frame: --verify-off: no %s" % tp, file=sys.stderr)
        return 1
    t = read(tp)
    if SWITCH not in t:
        print("patch_d13_trap_frame: --verify-off: switch ABSENT (nothing staged).", file=sys.stderr)
        return 1
    have = (t.count(TRAP_DONE_MARK) == 1
            and t.count("#if defined(%s) && %s\n" % (SWITCH, SWITCH)) == 1
            and t.count("#endif /* %s */\n" % SWITCH) == 1)
    between = t.count("#endif /* STAGE90_XNU_PC_CARRIER_CALLER */\n#if defined(%s)" % SWITCH) == 1
    tail = t.count("#endif /* %s */\n#endif /* STAGE90_XNU_USTACK_PROBE */\n" % SWITCH) == 1
    # every emitted row is INSIDE the gated block (so OFF removes it, not just the switch name)
    s = t.find("#if defined(%s) && %s" % (SWITCH, SWITCH))
    e = t.find("#endif /* %s */" % SWITCH)
    inside = t[s:e] if (s >= 0 and e > s) else ""
    missing = [r for r in FB_ROWS if ("\"%s" % r) not in inside]
    # the block shape 1033's structural scan (evf_closes_inside_1025) accepts: `#if defined(SW) && SW`
    # opening and `#endif /* SW */` closing, no nested directive inside it.
    shape = re.compile(r"#if defined\((STAGE90_[A-Z0-9_]+)\) && \1\n.*?#endif /\* \1 \*/\n", re.S)
    print("   trap.c [ON] : xnu_live_fb_pc row present + one #if/#endif pair: %s" % have)
    print("   trap.c      : the block sits immediately after 1036's, inside 1025's publisher: %s"
          % between)
    print("   trap.c      : it closes immediately before 1025's #endif: %s" % tail)
    print("   trap.c      : all %d rows inside the gated block: %s"
          % (len(FB_ROWS), "yes" if not missing else "NO: %s" % ", ".join(missing)))
    print("   trap.c      : whole-block shape `#if defined(SW) && SW .. #endif /* SW */`: %s"
          % ("yes" if (s >= 0 and shape.match(t, s)) else "NO"))
    if have and between and tail and not missing and s >= 0 and shape.match(t, s):
        print("patch_d13_trap_frame: --verify-off PASS (all edits gated on the switch; OFF removes them "
              "-> the 1036 tree bytes).")
        return 0
    print("patch_d13_trap_frame: --verify-off FAIL.", file=sys.stderr)
    return 1


# ---------------------------------------------------------------- selftest

def selftest():
    import tempfile
    fails = []
    tmp = tempfile.mkdtemp(prefix="p1037-")

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
            "#if defined(STAGE90_XNU_PC_CARRIER_CALLER) && STAGE90_XNU_PC_CARRIER_CALLER\n"
            "\t\t\t\t\tprintf(\"xnu_live_pcc2_pc=0x%08x\\n\", 0U);\n"
            "#endif /* STAGE90_XNU_PC_CARRIER_CALLER */\n"
            "#endif /* STAGE90_XNU_USTACK_PROBE */\n")
    r = tree("good", base)

    ok, p, t, msg = check_trap(r)
    expect(ok and msg == "anchor unique, switch absent", "the 1036 tree: plan accepts it (%s)" % msg)

    rc = stage(r, do_apply=True)
    t1 = read(trap_path(r))
    expect(rc == 0 and t1.count("\"xnu_live_fb_pc=") == 1, "staged: exactly one fb pc row")
    expect(t1.count("\"xnu_live_pcc2_pc=") == 1, "staged: 1036's row is untouched")
    expect((t1.count("#if defined(STAGE90_XNU_TRAP_FRAME) && STAGE90_XNU_TRAP_FRAME\n") == 1
            and t1.count("#endif /* STAGE90_XNU_TRAP_FRAME */\n") == 1),
           "staged: exactly one #if/#endif pair for the switch")
    expect(t1.count("#endif /* STAGE90_XNU_PC_CARRIER_CALLER */\n#if defined(STAGE90_XNU_TRAP_FRAME)")
           == 1, "staged: the block opens immediately after 1036's #endif")
    expect(t1.count("#endif /* STAGE90_XNU_TRAP_FRAME */\n"
                    "#endif /* STAGE90_XNU_USTACK_PROBE */\n") == 1,
           "staged: the block closes immediately before 1025's #endif")
    rc2 = stage(r, do_apply=True)
    expect(rc2 == 0 and read(trap_path(r)) == t1, "second --apply is an idempotent no-op")
    rc3 = verify_off(r)
    expect(rc3 == 0, "--verify-off PASS on the staged tree")
    s = t1.find("#if defined(STAGE90_XNU_TRAP_FRAME) && STAGE90_XNU_TRAP_FRAME")
    e = t1.find("#endif /* STAGE90_XNU_TRAP_FRAME */")
    inside = t1[s + len("#if defined(%s) && %s\n" % (SWITCH, SWITCH)):e]
    expect(all(("\"%s" % row) in inside for row in FB_ROWS), "every emitted row is inside the gated block")
    # 19 named rows + 17 value rows + 17 ok rows
    expect(len(FB_ROWS) == 30 + 21, "row count is 30 value rows + 21 _ok rows")
    expect("#include" not in inside and "#define" not in inside and not re.search(r"^\s*#", inside, re.M),
           "no directive inside the block (OFF cannot change trap.c's directive namespace)")
    expect(all((not l.strip()) or l.startswith("\t") for l in inside.splitlines()),
           "every block line is indented inside 1025's arm (nothing lands at column 0)")
    expect(all(name not in inside for name in ("_evf", "_pcc ", "_pcc_", "_pcc2")),
           "the block never names an earlier sibling's locals")
    # the shape 1033's evf_closes_inside_1025 accepts: whole sibling blocks then 1025's #endif.  Replay
    # that scan over the fixture: from 1033's close, walk whole blocks until 1025's own close line.
    blocks = re.compile(r"#if defined\((STAGE90_[A-Z0-9_]+)\) && \1\n.*?#endif /\* \1 \*/\n", re.S)
    off = t1.find("#endif /* STAGE90_XNU_EVAL_FRAME */\n") + len("#endif /* STAGE90_XNU_EVAL_FRAME */\n")
    seen = []
    while True:
        if t1.startswith("#endif /* STAGE90_XNU_USTACK_PROBE */\n", off):
            break
        m = blocks.match(t1, off)
        if m is None:
            break
        seen.append(m.group(1))
        off = m.end()
    expect(seen == ["STAGE90_XNU_PC_CARRIER", "STAGE90_XNU_PC_CARRIER_CALLER", SWITCH]
           and t1.startswith("#endif /* STAGE90_XNU_USTACK_PROBE */\n", off),
           "1033's structural scan accepts 1037 as a whole later sibling block")

    r2 = tree("noanchor", base.replace("#endif /* STAGE90_XNU_PC_CARRIER_CALLER */\n", ""))
    before = read(trap_path(r2))
    ok2, _, _, msg2 = check_trap(r2)
    expect(not ok2 and "expected exactly 1" in msg2, "missing 1036 tail: REFUSE (%s)" % msg2)
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
    write(trap_path(r4), t4.replace("#endif /* STAGE90_XNU_TRAP_FRAME */\n",
                                    "#endif /* STAGE90_XNU_TRAP_FRAME */\n"
                                    "\t\t\t\t\tprintf(\"xnu_live_fb_seq=%u\\n\", 0U);\n"))
    expect(verify_off(r4) != 0, "--verify-off FAILS when one row escapes the gate")

    r5 = tree("structurally_inside", base)   # a later rung inserts a whole block after 1037's
    stage(r5, do_apply=True)
    t5 = read(trap_path(r5))
    write(trap_path(r5), t5.replace(
        "#endif /* STAGE90_XNU_TRAP_FRAME */\n",
        "#endif /* STAGE90_XNU_TRAP_FRAME */\n"
        "#if defined(STAGE90_XNU_LATER_LATER_RUNG) && STAGE90_XNU_LATER_LATER_RUNG\n"
        "#endif /* STAGE90_XNU_LATER_LATER_RUNG */\n"))
    ok5, _, _, msg5 = check_trap(r5)
    expect(ok5 and msg5 == "already staged", "a later whole sibling block does not disturb plan mode")

    if fails:
        print("SELFTEST FAIL: " + " | ".join(fails), file=sys.stderr)
        return 1
    print("SELFTEST PASS (16 checks: plan/apply/idempotent/bracket/namespace/OFF-can-fail/structural)")
    return 0


def main(argv):
    if "--selftest" in argv:
        return selftest()
    if len(argv) < 2:
        print("usage: patch_d13_trap_frame.py <xnu_root> [--apply|--verify-off] [--selftest]",
              file=sys.stderr)
        return 2
    xnu = argv[1]
    if "--verify-off" in argv:
        return verify_off(xnu)
    return stage(xnu, do_apply="--apply" in argv)


if __name__ == "__main__":
    sys.exit(main(sys.argv))