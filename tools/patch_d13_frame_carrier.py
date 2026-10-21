#!/usr/bin/env python3
"""1039 -- THE FRAME CARRIER: what the kernel holds for the faulting thread, read independently of arm_ctx.

Source: records/1037-read.txt, the RUNG READING (2(a) the one odd register is lr; 2(c) r1=0, the ldrb
faults at 0x10; 3. NEXT: 1039).  1037's fb block read thread->machine.uss THROUGH arm_ctx itself (arm_ctx
IS that VA on traps_lo.s's user entry), so its mask compares an address with itself -- a tautology.  This
rung reads the SAME question three ways, none through arm_ctx:

  - arm_ctx, as the kernel holds it now            (fcr_seq / _pid / _pc / _lr / _cpsr)
  - thread->machine.uss, the record arm_ctx POINTS AT, through its kernel-side address, selected by
    address: a VA below 0x80000000 is a user address and is read through the task map (the 1025/1035
    guarded idiom); any other VA is a kernel pointer and is read with a plain ldr.  fcr_uss_via says
    WHICH was used (1 = task map, 2 = kernel ldr, 0 = not attempted) -- 1037's named defect.
  - thread->machine.iss: read NOWHERE (its layout is a register block, see THE OFFSETS); dropped
    from the rows after review.
  - thread->continuation (osfmk/kern/thread.h:164).
  - the trap entry's saved spsr: in THIS tree trap.c's arm passes no spsr argument, and on
    traps_lo.s's data_abort_crash_in_usermode the spsr is stored ONLY as uss word 0x40 (the entry's
    `mrs r0, spsr; str r0, [sp, #0x40]`; kprintf's own `arm_ctx->cpsr` is the same word), so
    fcr_spsr is uss[0x40] and fcr_spsr_ok repeats the uss record's own read status.
  - fcr_tbit: bit 5 of the saved pc (the ARM T-bit position; fcr_spsr carries the real PSR).  A draft
    read bit 1 of the address instead -- fixed here.  The odd bit is fcr_pc_odd / fcr_lr_odd.

THE OFFSETS (the uss record; arm_saved_state_t = arm_thread_state_t, osfmk/mach/arm/_structs.h:47-65:
r[13] at 0x00, sp 0x34, lr 0x38, pc 0x3c, cpsr 0x40):
    word 0..12  r0..r12                    (0x00..0x30)
    word 13     sp                         (0x34)
    word 14     lr                         (0x38)
    word 15     pc                         (0x3c)
    word 16     cpsr (the entry's spsr)    (0x40)
A first draft read word 13 as sp / 14 as lr (word 14 IS lr, but 13 is sp, not lr) -- the sp/lr rows
are words 13/14 exactly as below; what was WRONG in the draft was the iss (see next).
THE ISS IS NOT READ AT THESE OFFSETS.  machine.iss points at an arm_saved_state_t (thread_status.h:97),
but the tree writes it as a REGISTER BLOCK (pcb.c:331 `iss->r[7] = 0`, pcb.c:334 `iss->cpsr = 0x13`,
pcb.c:337 `iss->lr = thread_continue`) and cswitch.s:132 walks it with `ldmia r3!,{r4-lr}` (9 words
from iss+0x10).  Reading iss words 13..16 would reproduce that walk's field jumble without naming it,
so the iss rows are DROPPED; the I cell (thread->continuation) is what this rung decides, and the
walk is records/1039-static-lr.txt (iii), a static reading, not re-printed here.
TH_PCB_USS / TH_PCB_ISS are genassym.c:230/229 names for offsetof(thread_t, machine.uss / machine.iss);
the same words are written in C as thread->machine.uss / thread->machine.iss (this block's form).

SITE -- osfmk/arm/trap.c, INSIDE 1025's user-mode data-abort publisher, after BOTH of its current
neighbours: 1037's `#endif /* STAGE90_XNU_TRAP_FRAME */` (after 1038's whole STAGE90_XNU_WATCH_LE slot
writer + block, if 1038 is staged: the first `#endif /* STAGE90_XNU_TRAP_FRAME */` IS then followed by
1038's `#if`) and immediately before 1025's `#endif /* STAGE90_XNU_USTACK_PROBE */`.  The anchor is that
LAST line; the inserted text closes the switch and re-opens 1025's `#if` switch, so that with this switch
undefined the preprocessor restores 1025's single bracket (`--verify-off` is exact by construction).

Every read guarded; a miss prints 0 / _ok=0; no lock on the failing path; one-shot per thread_id (a
static word: bit0 = armed, bits 31:1 = thread_id & 0x7fffffff), cap 4.  READ ONLY.  Selftest FAILS on a
missing anchor, a missing row, or an unguarded user read.

SHARED NAMESPACE ([[mi4-one-file-many-rungs]]): STAGE90_XNU_FRAME_CARRIER is registered into
tools/build_xnu_arm_kernel.sh DEFINES and every tools/patch_d13_*.py TRAP_ALLOWED_IF_IDENTIFIERS (this
script does the PATCHERS tuple: add the file to it); the other patchers' ANCHORS are not this rung's to
edit -- they are stale against the 1038/Darwin-13 tree (memory note [lane 1039] to the coordinator).

records/1037-read.txt (RUNG READING); [mi4-one-file-many-rungs].
"""
import os
import re
import sys
import textwrap

SWITCH = "STAGE90_XNU_FRAME_CARRIER"

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TRAP_REL = "osfmk/arm/trap.c"
BUILD_REL = "tools/build_xnu_arm_kernel.sh"
BUILD_READER = "DEFINES+=(-DSTAGE90_XNU_FRAME_CARRIER=1)"
BUILD_ANCHOR = "[[ ${STAGE90_XNU_WATCH_LE:-0} -eq 1 ]] && DEFINES+=(-DSTAGE90_XNU_WATCH_LE=1)\n"

TRAP_USTACK_OPEN = "#if defined(STAGE90_XNU_USTACK_PROBE) && STAGE90_XNU_USTACK_PROBE\n"
TRAP_USTACK_CLOSE = "#endif /* STAGE90_XNU_USTACK_PROBE */\n"
# 1025's close -- the LAST line of its directive region in either tree (with or without 1038).
# The anchor is 1038's seam, not 1025's close: since 1039 the tail after 1037's `#endif` holds 1038's
# block (it re-states 1025's close line), so our block goes IMMEDIATELY AFTER 1037's close and IN
# FRONT OF 1038's.  --verify-off proves both readings of that seam compile to the pre-1039 text; the
# over structure is the same as the verify-off checker's OFF readings (identical mechanism).
TRAP_ANCHOR = ("#endif /* STAGE90_XNU_TRAP_FRAME */\n" + TRAP_USTACK_CLOSE)
# RE-STAGE (2026-10-19, after 1038's slot splice landed): 1038 now stages as 1037's close / `#include`
# slot a / `#define STAGE90_XNU_WATCH_LE 1` / 1025's close / `#include` slot b -- NOT as a block after
# 1037's close.  Our block still goes after 1037's close and IN FRONT of slot a, so on an ALREADY
# STAGED tree the anchor is the first two lines of that seam.  The selftest proves the OFF text of
# BOTH anchors equals the pre-1039 compiled view, and --staged-at picks the one the tree shows.
STAGED_ANCHORS = (TRAP_ANCHOR, "#endif /* STAGE90_XNU_TRAP_FRAME */\n")
_OLD_STAGED = (
    "#endif /* %s */\n" % SWITCH
    + "#if defined(%s) && %s\n" % (SWITCH, SWITCH)
    + "\t\t\t\t\t/* 1039: THE FRAME CARRIER.  INSTRUMENT ONLY --"
)


I = "\t\t\t\t\t"          # the indent of every block in 1025's arm
OP_LINE = "#if defined(%s) && %s" % (SWITCH, SWITCH)
# The block's BODY, byte-exact (statements only: the head and body-close are built around it).
TRAP_BODY = (
    '/* 1039: THE FRAME CARRIER.  INSTRUMENT ONLY -- no fix.  Where 1037 read thread->machine.uss\n'
    ' * THROUGH arm_ctx (the same address: a tautology), this block reads it through the POINTER\n'
    ' * (kernel-side ldr) or the task map (user VA), reads TH_PCB_ISS beside it, and prints the\n'
    " * trap entry's saved spsr (uss word 0x40) and bit0 of the pc/lr the kernel will return to.\n"
    ' * Every user read is vm_map_lookup_entry + copyin; a miss prints 0 / _ok=0.  pid 2, first\n'
    ' * fault of each thread, cap 4, failing path only.  READ ONLY, no lock.  See patcher header. */\n'
    'if ((int)(thread->task->bsd_info ? proc_pid(thread->task->bsd_info) : -1) == 2) {\n'
    '\tstatic unsigned _fcr_shot;\n'
    '\tunsigned _fcr_tid = (unsigned)thread->thread_id & 0x7fffffffU;\n'
    '\tunsigned _fcr_old = __atomic_load_n((unsigned *)&_fcr_shot, __ATOMIC_ACQUIRE);\n'
    '\tif (!(_fcr_old & 1U) && _fcr_tid != 0U &&\n'
    '\t    __atomic_compare_exchange_n((unsigned *)&_fcr_shot, &_fcr_old, _fcr_tid | 1U,\n'
    '\t\tFALSE, __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE) &&\n'
    '\t    ((_fcr_old >> 1) & 0x7fffffffU) < 4U) {\n'
    '\t\tunsigned _fcr_uss_p = (unsigned)(uintptr_t)thread->machine.uss;\n'
    '\t\tunsigned _fcr_via = 0U;           /* 1 = task map (user VA), 2 = kernel ldr */\n'
    '\t\tunsigned _fcr_w[17];              /* uss 0x00..0x40 */\n'

    '\t\tboolean_t _fcr_ok[17];\n'
    '\t\tunsigned _fcr_i;\n'
    '\t\tvm_map_entry_t _fcr_e;\n'
    '\t\tvm_map_t _fcr_map = thread->task->map;   /* the FAULTED task; `map` here is the\n'
    "\t\t * kernel's (thread->map) on this path -- 1038's lesson */\n"
    '\t\tfor (_fcr_i = 0; _fcr_i < 17U; _fcr_i++) {\n'
    '\t\t\t_fcr_w[_fcr_i] = 0U;\n'
    '\t\t\t_fcr_ok[_fcr_i] = FALSE;\n'
    '\t\t}\n'
    '\t\t/* THE RECORD: choose the loader BY THE ADDRESS, then read 17 words. */\n'
    '\t\tif (_fcr_uss_p != 0U && _fcr_uss_p < 0x80000000U) {\n'
    '\t\t\t_fcr_via = 1U;\n'
    '\t\t\tfor (_fcr_i = 0; _fcr_i < 17U; _fcr_i++) {\n'
    '\t\t\t\tunsigned _fcr_a = _fcr_uss_p + 4U * _fcr_i;\n'
    '\t\t\t\tif (_fcr_a >= 4U && (_fcr_a & ~3U) <= 0xfffffffcU &&\n'
    '\t\t\t\t    vm_map_lookup_entry(_fcr_map, _fcr_a & ~3U, &_fcr_e)) {\n'
    '\t\t\t\t\t_fcr_ok[_fcr_i] = (copyin((user_addr_t)(uintptr_t)(_fcr_a & ~3U),\n'
    '\t\t\t\t\t    (char *)&_fcr_w[_fcr_i], 4) == 0);\n'
    '\t\t\t\t}\n'
    '\t\t\t}\n'
    '\t\t} else if (_fcr_uss_p >= 0x80000000U) {\n'
    '\t\t\t_fcr_via = 2U;\n'
    '\t\t\tfor (_fcr_i = 0; _fcr_i < 17U; _fcr_i++) {\n'
    '\t\t\t\t_fcr_w[_fcr_i] = *(volatile uint32_t *)(uintptr_t)(_fcr_uss_p + 4U * _fcr_i);\n'
    '\t\t\t\t_fcr_ok[_fcr_i] = TRUE;\n'
    '\t\t\t}\n'
    '\t\t}\n'
    '\t\t{\n'
    '\t\t\tuint64_t _fcr_ab = 0, _fcr_ns = 0;\n'
    '\t\t\tclock_get_uptime(&_fcr_ab);\n'
    '\t\t\tabsolutetime_to_nanoseconds(_fcr_ab, &_fcr_ns);\n'
    '\t\t\t/* uss record word 16 == 0x40: the trap entry\'s saved spsr.  _ok repeats the record\'s\n'
    "\t\t\t * own status, so a spsr that could not be read is never a reading. */\n"
    '\t\t\tprintf("xnu_live_fcr_seq=%u\\n", (unsigned)((_fcr_old >> 1) & 0x7fffffffU) + 1U);\n'
    "\t\t\t/* THIS kernel's own uptime: clock_get_uptime (the boot epoch on this kernel) and the\n"
    "\t\t\t * timebase's count/s; _ok=1 always: no memory is dereferenced for it. */\n"
    '\t\t\tprintf("xnu_live_fcr_uptime_ok=1\\n");\n'
    '\t\t\tprintf("xnu_live_fcr_uptime_s=%llu\\n", (unsigned long long)(_fcr_ab / 1000000000ULL));\n'
    '\t\t\tprintf("xnu_live_fcr_time_abs=%llu\\n", (unsigned long long)_fcr_ab);\n'
    '\t\t\tprintf("xnu_live_fcr_time_ns=%llu\\n", (unsigned long long)_fcr_ns);\n'
    '\t\t\tprintf("xnu_live_fcr_pid=%d\\n", (int)proc_pid(thread->task->bsd_info));\n'
    '\t\t\tprintf("xnu_live_fcr_tid=0x%08x\\n", _fcr_tid);\n'
    '\t\t\tprintf("xnu_live_fcr_pc=0x%08x\\n", (unsigned)arm_ctx->pc);\n'
    '\t\t\tprintf("xnu_live_fcr_lr=0x%08x\\n", (unsigned)arm_ctx->lr);\n'
    '\t\t\tprintf("xnu_live_fcr_cpsr=0x%08x\\n", (unsigned)arm_ctx->cpsr);\n'
    '\t\t\tprintf("xnu_live_fcr_uss_va=0x%08x\\n", _fcr_uss_p);\n'
    '\t\t\tprintf("xnu_live_fcr_uss_via=%u\\n", _fcr_via);\n'
    '\t\t\tprintf("xnu_live_fcr_uss_pc=0x%08x\\n", (unsigned)_fcr_w[15]);\n'
    '\t\t\tprintf("xnu_live_fcr_uss_pc_ok=%d\\n", (int)(_fcr_ok[15] ? 1 : 0));\n'
    '\t\t\tprintf("xnu_live_fcr_uss_sp=0x%08x\\n", (unsigned)_fcr_w[13]);\n'
    '\t\t\tprintf("xnu_live_fcr_uss_sp_ok=%d\\n", (int)(_fcr_ok[13] ? 1 : 0));\n'
    '\t\t\tprintf("xnu_live_fcr_uss_lr=0x%08x\\n", (unsigned)_fcr_w[14]);\n'
    '\t\t\tprintf("xnu_live_fcr_uss_lr_ok=%d\\n", (int)(_fcr_ok[14] ? 1 : 0));\n'
    "\t\t\t/* the tautology 1037 could not see: arm_ctx against the pointed-to record's contents */\n"
    '\t\t\tprintf("xnu_live_fcr_uss_armctx_diff=0x%08x\\n",\n'
    '\t\t\t    (unsigned)((_fcr_ok[13] ? ((unsigned)arm_ctx->sp ^ _fcr_w[13]) : 0x80000000U) |\n'
    '\t\t\t    (_fcr_ok[14] ? ((unsigned)arm_ctx->lr ^ _fcr_w[14]) : 0x40000000U) |\n'
    '\t\t\t    (_fcr_ok[15] ? ((unsigned)arm_ctx->pc ^ _fcr_w[15]) : 0x20000000U)));\n'
    '\t\t\tprintf("xnu_live_fcr_cont=0x%08x\\n", (unsigned)(uintptr_t)thread->continuation);\n'
    '\t\t\tprintf("xnu_live_fcr_cont_ok=1\\n");\n'
    '\t\t\tprintf("xnu_live_fcr_spsr=0x%08x\\n", (unsigned)_fcr_w[16]);\n'
    '\t\t\tprintf("xnu_live_fcr_spsr_ok=%d\\n", (int)(_fcr_ok[16] ? 1 : 0));\n'
    '\t\t\tprintf("xnu_live_fcr_pc_odd=%d\\n", (int)((unsigned)arm_ctx->pc & 1U));\n'
    '\t\t\tprintf("xnu_live_fcr_lr_odd=%d\\n", (int)((unsigned)arm_ctx->lr & 1U));\n'
    '\t\t\tprintf("xnu_live_fcr_tbit=%d\\n",\n'
    '\t\t\t    (int)(((((unsigned)arm_ctx->pc & 1U) || ((unsigned)arm_ctx->lr & 1U))) ? 1 : 0));\n'
    '\t\t}\n'
    '\t}\n'
    '}\n'
)
_SW_CLOSE = "#endif /* %s */" % SWITCH
CHR10 = chr(10)
OP_L = OP_LINE + chr(10)
CLOSE = _SW_CLOSE + chr(10)
# 1037's staged text opens the switch at TWO levels (rites/save and the parent line); its close stands
# INSIDE 1025's bracket (`\t#endif /* USTACK */`), so the block's head must close it there and the body's
# close resumes it -- the block is bracketed exactly as cleanly as the single-level form, and the
# per-board directives 1037's body carries do not meet a column-0 `#endif` inside our switch.
# 2026-10-19 19:2x (1039's tree): the block goes in at 1037's close, and 1037's close is inside 1025's
# bracket with 1038's seam IN FRONT of it (1038 lane) or 1025's close after it.  Either way the text in
# front of our opener ALREADY closes 1025 -- so the block is ONE direct pair and the anchor line after it
# is 1037's close, restored: OFF (the switch undefined) is that line plus 1025's close in front of it, the
# pre-1039 bytes.  The head-pair form (close + 1025 close + opener) is SUPERSEDED; see _old_span_any.
ANCHOR_LINE = "#endif /* STAGE90_XNU_TRAP_FRAME */" + chr(10)
TRAP_BLOCK = OP_L + TRAP_BODY + CLOSE + ANCHOR_LINE
BLOCK_LINES = TRAP_BLOCK.splitlines(True)
K = [CLOSE, OP_LINE, _SW_CLOSE, TRAP_USTACK_CLOSE.rstrip(chr(10))]
SEAM = "#endif /* STAGE90_XNU_TRAP_FRAME */" + chr(10)       # 1037's close: where our block goes

FCR_ROWS = (
    "xnu_live_fcr_cont=",
    "xnu_live_fcr_cont_ok=",
    "xnu_live_fcr_cpsr=",
    "xnu_live_fcr_lr=",
    "xnu_live_fcr_lr_odd=",
    "xnu_live_fcr_pc=",
    "xnu_live_fcr_pc_odd=",
    "xnu_live_fcr_pid=",
    "xnu_live_fcr_seq=",
    "xnu_live_fcr_spsr=",
    "xnu_live_fcr_spsr_ok=",
    "xnu_live_fcr_tbit=",
    "xnu_live_fcr_tid=",
    "xnu_live_fcr_time_abs=",
    "xnu_live_fcr_time_ns=",
    "xnu_live_fcr_uptime_ok=",
    "xnu_live_fcr_uptime_s=",
    "xnu_live_fcr_uss_armctx_diff=",
    "xnu_live_fcr_uss_lr=",
    "xnu_live_fcr_uss_lr_ok=",
    "xnu_live_fcr_uss_pc=",
    "xnu_live_fcr_uss_pc_ok=",
    "xnu_live_fcr_uss_sp=",
    "xnu_live_fcr_uss_sp_ok=",
    "xnu_live_fcr_uss_va=",
    "xnu_live_fcr_uss_via=",
)

TRAP_FRAME_CLOSE = "#endif /* STAGE90_XNU_TRAP_FRAME */\n"
# 1037's own close -- STAGED TEXT, not ours (the anchor is its whole line).
SITE_FAST = "#endif /* STAGE90_XNU_TRAP_FRAME */" + chr(10)
# 1038's ROW side (2026-10-19, tools/patch_d13_watch_le_rowside.py) stands AFTER 1037's close, inside
# 1025's bracket, as ONE directive-balanced block: `#if 1` chunk (statics + gate, its own close), the
# `#if 1` chunk with the arm's switch (indented SW close), the gate rows, and a TAB `#endif` closing
# the block.  Our block goes IN FRONT of it; this line -- the block's end -- is where 1037's close and
# 1025's close would have met, and where 1025's bracket is re-closed after us.
CHUNK_END = "#endif /* 1038 BLOCK END */" + chr(10)
PATCHERS = (
    "tools/patch_d13_dyld_witness.py",
    "tools/patch_d13_undef_raise.py",
    "tools/patch_d13_abt_entry_probe.py",
    "tools/patch_d13_writer_probe.py",
    "tools/patch_d13_reader_probe.py",
    "tools/patch_d13_caller_probe.py",
    "tools/patch_d13_eval_frame.py",
    "tools/patch_d13_pc_carrier.py",
    "tools/patch_d13_pc_carrier_caller.py",
    "tools/patch_d13_trap_frame.py",
    "tools/patch_d13_watch_le.py",
    "tools/patch_d13_frame_carrier.py",      # this rung
    "tools/patch_d13_ustack_probe.py",
)
TRAP_ALLOWED_IF_IDENTIFIERS = {
    "WATCH_LE_H_STANDIN",           # 1038 (its hook's stand-in guard)
    "BOARD_CONFIG_QSD8250_LEO",
    "BOARD_CONFIG_ARMPBA8",
    # 1038's chunk (the parked ROW-side), laid out aright 2026-10-19: its `#ifndef` guard, the arm's
    # chunk marker and the arm's switch pair.  Directive identifiers are a SHARED namespace
    # ([[mi4-one-file-many-rungs]]); 1039 does not read these rows.
    "WATCH_LE_STATICS_DEFINED", "chunk", "arm",
    "STAGE90_XNU_DYLD_WITNESS",       # 994
    "STAGE90_XNU_WATCH_LE",           # 1038
    "STAGE90_XNU_GLOBAL_FIX",         # 1015b (fires in pmap.c; allowed for the proof)
    "STAGE90_XNU_UNDEF_RAISE",        # 1020
    "STAGE90_XNU_IOS7_TRAPS",         # 1023
    "STAGE90_XNU_USTACK_PROBE",       # 1025 (this block's PARENT)
    "STAGE90_XNU_ABT_ENTRY_PROBE",    # 1026/1027
    "STAGE90_XNU_H2_STACK_HEADROOM",  # 1028
    "STAGE90_XNU_READER_PROBE",       # 1029
    "STAGE90_XNU_WRITER_PROBE",       # 1030
    "STAGE90_XNU_CALLER_PROBE",       # 1031
    "STAGE90_XNU_EVAL_FRAME",         # 1033
    "STAGE90_XNU_PC_CARRIER",         # 1035
    "STAGE90_XNU_PC_CARRIER_CALLER",  # 1036
    "STAGE90_XNU_TRAP_FRAME",         # 1037 (this block's base)
    "STAGE90_XNU_FRAME_CARRIER",      # 1039 (this rung)
}


def read(p):
    with open(p) as f:
        return f.read()


def write(p, t):
    with open(p, "w") as f:
        f.write(t)


def trap_path(xnu):
    return os.path.join(xnu, TRAP_REL)


def if_stage90_ids(text):
    """STAGE90_* identifiers evaluated at the start of a #if/#ifdef/#ifndef line.  LINE-STARTING
    directives only (a `#if` quoted inside 1038's staged string literal is not a directive); an id must
    stand WHOLE (not as a prefix of a longer one) and outside quotes.  A prefixed or quoted spelling of a
    switch is not that switch ([[mi4-one-file-many-rungs]]: a switch is a directive ID, not a substring)."""
    dirs = [m.group(1) for m in re.finditer(r"^[ \t]*#\s*(?:if|elif|ifdef|ifndef)\b(.*)$", text, re.M)]
    ids = set()
    for e in dirs:
        ids.update(i for i in re.findall(r"[A-Za-z_][A-Za-z0-9_]*", e) if i.startswith("STAGE90_"))
    whole = set()
    for e in dirs:
        e = re.sub(r'"(?:[^"\\]|\\.)*"', "", e)
        whole.update(i for i in re.findall(r"(?<![A-Za-z0-9_])[A-Za-z_][A-Za-z0-9_]*", e) if i in ids)
    return whole


def staged_anchor(t):
    """The exact anchor text the tree shows (the staged pair, or the plain 1037 close)."""
    for a in STAGED_ANCHORS:
        if t.count(a) >= 1:
            return a
    return None


def old_span(t):
    """(start, end) of an OLD staged block (a body written before the 2026-10-19 row changes): our close
    line .. our body-close line inclusive (the next line is the anchor).  FOUND BY SHAPE, never by
    reading the text forwards: the seam this block may sit at now also holds 1038's slot ([[mi4-one-file-
    many-rungs]] -- a body that carries `#endif`s at the same indent defeats a nearest-close search, and
    it would remove the WRONG text while reporting success)."""
    i = t.find(_OLD_STAGED)
    if i < 0:
        return None
    open_ = "#if defined(%s) && %s\n" % (SWITCH, SWITCH)
    for m in re.finditer(r"(?m)^#endif /\* %s \*/\n" % SWITCH, t[i + len(_OLD_STAGED):]):
        end = m.end()                  # the close line only: the anchor line after it is NOT ours
        if t.startswith(open_, end):
            return i, end
    return None


_V1039 = r"(?m)^#endif /\* STAGE90_XNU_FRAME_CARRIER \*/\n"


def pieces(t):
    """(pre, body, post, sim, why) for a tree staged by this patcher.  The tree holds

        pre + CLOSE + OP_L + TRAP_BODY + CLOSE + post            (post = the anchor's own text, ...)

    i.e. head = our column-0 close + our OPEN line; body = the statements; then OUR column-0 close; the
    anchor (1025's close, tab-indented or at column 0) follows.  The region is FOUND BY SHAPE and must
    occur exactly ONCE.  sim drops the whole region's head+body+close, leaving the anchor where it stood:
    the pre-1039 text after a preprocessor run.  --off-check proves sim == the pre copy byte for byte."""
    H = TRAP_FRAME_CLOSE + OP_L      # the head-pair form's head (a SUPERSEDED block)
    HL = SITE_FAST + OP_L            # the current form: in front of 1037's close line
    if t.count(H) == 1:
        i = t.index(H)                  # a SUPERSEDED head-pair block still in the tree
    elif t.count(OP_L) == 1 and t.count(SEAM) >= 1 and t.index(OP_L) == t.index(SEAM):
        i = t.index(OP_L)               # the current form: opener at the seam, body, close, 1037's close
        k0 = t.find(CLOSE, i + len(OP_L))
        _sk = k0 + len(CLOSE)
        if k0 < 0 or t.startswith(("\n", chr(9) + "#", chr(9) + "}", TRAP_FRAME_CLOSE), _sk):
            pre, mid = t[:i], t[i + len(OP_L):_sk]   # what pieces() calls the body
            if pre.count(TRAP_USTACK_OPEN) != 1:
                return None, None, None, None, "1025's bracket is not the single open before the anchor"
            return pre, mid, None, pre + ANCHOR_LINE + mid, None
        return None, None, None, None, "the block's body-close is not followed by 1037's close"
    else:
        n = t.count(H)
        return None, None, None, None, ("the block's head (close + open) occurs %d time(s) in the file, "
                                        "expected exactly 1" % n)
    # where a body is written (a UTF-8 tab is three bytes on disk, not one -- compare SLICES, never offsets)
    k = t.find(CLOSE, i + len(H))
    if k < 0 or not t[i + len(H):k].rstrip(chr(10)) == TRAP_BODY.rstrip(chr(10)):
        return None, None, None, None, "the block's body does not run to a body-close"
    if not t.startswith(CLOSE, k):
        return None, None, None, None, "the block's body-close does not follow its body"
    pre, post = t[:i], t[k + len(CLOSE):]
    sim = pre + post
    if pre.count(TRAP_USTACK_OPEN) != 1:
        return None, None, None, None, "1025's bracket is not the single open before the anchor"
    return pre, TRAP_BODY, post, sim, None


def pre_off_sim(t):
    """The text with THIS block's lines alone removed: 1025's close kept (our open line), the re-opened
    1025 `#if` dropped -- i.e. the pre-1039 text when the switch is OFF for a preprocessor that lets our
    unmatched-at-that-point close stand.  --off-check against a pre-staged COPY is the exact proof."""
    _p, _m, _o, sim, why = pieces(t)
    return t if why else sim


def _old_span_any(t):
    """(start, end) of an OLD 1039 block, by SHAPE: opener offset .. the FC close LINE that follows, with
    the anchor line(s) it displaced still in front of the body-close.  The closest FC line to the opener
    is the HEAD's own close (head = FC close + opener) -- the body-close is the first FC close LINE after
    the head.  Measured on the 2026-10-19 draft (opener 75012, head close 74973, body-close 80867)."""
    i = t.find(OP_L)
    if i < 0 or t.count(OP_L) != 1:
        return None
    # a "close LINE": the close text, starting at a line start and followed by a newline or EOF
    # (t[k - 1] would underflow at k == 0)
    CR = CLOSE.rstrip(chr(10))
    def is_line(k):
        return (k == 0 or t[k - 1] == chr(10)) and (k + len(CR) == len(t) or t[k + len(CR)] == chr(10))
    k = t.find(CR, i)
    while k >= 0 and not is_line(k):
        k = t.find(CR, k + 1)
    if k < 0:
        return None
    return i, k + len(CR)


def _op(t):
    """the opener's offset (the body starts right after it)"""
    i = t.find(OP_L)
    return i + len(OP_L) if i >= 0 else -1


def off_text(t, fold_head=False):
    """The tree's text with THIS rung's edit folded out (the pre-1039 text) -- or None and the reason.

    A staged 1039 is ONE contiguous block, so the fold is a delete: from the block's FIRST line to the
    line after its LAST 1025 close, where the draft that still carries the head pair
    (`CLOSE, opener`) starts one line earlier and keeps a blank line where 1025's close was.  A draft
    or an old block is an OLD_SPAN: the anchor line 1025 had, re-closing what 1037's frame and 1025's
    bracket need after it, is put back where the block was removed.  Every shape is proven by
    compiled view (directives and 1025's bracket do not change program text) and, where a pre-insert
    exists, by rebuilding: stage(fold(x)) == x.  [[mi4-one-file-many-rungs]]"""
    # 1. the current staging: delete our block, prove the result is a program with the same compiled view
    # (TWO shapes reach here: the block as written, and a DRAFT whose body text predates the current
    # patcher - its close/opener/body prefix - which the block is then written OVER, never stacked on.)
    _hy = CLOSE + OP_L + TRAP_BODY              # the SUPERSEDED head-pair body still in some trees
    _i = t.rfind(TRAP_BLOCK) if t.count(TRAP_BLOCK) >= 1 else t.find(_hy)
    if _i >= 0:
        i = _i
        if True:
            j = i + len(TRAP_BLOCK)                         # TRAP_BLOCK = head, opener .. body-close, anchor
            # past the anchor line 1025 had (when the draft carried it); 1037's close stays
            _U = chr(9) + TRAP_USTACK_CLOSE
            if t[j:].startswith(_U):
                j += len(_U)
            # the pre-1039 text is the block out -- its anchor line (TRAP_BLOCK's last) with it -- and
            # 1037's close, which the block was written OVER, put back where it stood.  (The tree's ONE
            # FC close is 1037's; the stranded closes after the block are ours and go out with it.)
            cand = t[:i] + ANCHOR_LINE + t[j:]          # 1037's close, which the block stands IN FRONT OF
            _blk = [TRAP_BLOCK, CLOSE, chr(10) + _U, chr(10) + CLOSE + _U]
            if _compiled(cand, _blk) != _compiled(t, _blk):
                return None, "the fold of a staged block changes the compiled view"
            return cand, None
    # 1b (the CURRENT composed staging: after 1's block, 1037's close comes FIRST in the seam).  The
    # block was written IN FRONT OF 1037's close (the canonical staging after 1037's own build), so the
    # splice point is that close and the anchor line (the block's last) is the pre's own there.
    _cc = (TRAP_BLOCK[:-len(ANCHOR_LINE)] if TRAP_BLOCK.endswith(ANCHOR_LINE)
           else _hy + CLOSE if t.count(_hy) == 1 else _hy)
    if t.count(_cc) == 1:
        i = t.index(_cc)
        j = i + len(_cc)
        _U = chr(9) + TRAP_USTACK_CLOSE
        if t[j:].startswith(_U):
            j += len(_U)
        cand = t[:i] + t[j:]
        _blk = [TRAP_BLOCK, CLOSE, CLOSE + _U, chr(10) + _U, chr(10) + CLOSE + _U]
        if _compiled(cand, _blk) != _compiled(t, _blk):
            return None, "the fold of the staged block changes the compiled view"
        return cand, None
    # 1c. the head-pair draft (the staged block, plus the old `#endif` in front and one more line)
    if t.count(CLOSE + OP_L) == 1:
        _i = t.find(CLOSE + OP_L)
        if t[_i + len(CLOSE):].startswith(OP_L + TRAP_BODY):
            j = _i + len(CLOSE) + len(OP_L) + len(TRAP_BODY) + len(CLOSE)  # through the body-close
            _U = chr(9) + TRAP_USTACK_CLOSE
            cand = t[:_i] + t[j:]
            if t[j:].startswith(_U):
                j += len(_U)
            cand = t[:_i] + chr(10) + t[j:]         # the head draft never carried the anchor line back
            if _compiled(cand) != _compiled(t):
                return None, "the fold of a head-pair draft changes the compiled view"
            return cand, None
    # 2. an OLD_SPAN: no block; the span re-closes what the anchor line closes
    sp = _old_span_any(t)
    if sp is None:
        return None, "no 1039 block (staged, draft or old span) is in the text"
    return _fold_old_span(t, sp, fold_head)


def _compiled(x, blocks=()):
    """x's program text: the directive lines, 1025's tab-indented close and this rung's block(s) removed
    (a line at a time).  A block's lines are ordinary statements, so they must be taken by LINE, and
    only where the block stands -- a global replace would also take the lines that equal its head."""
    lines = set()
    for b in blocks:
        lines |= set(b.splitlines(True))
    return "".join(l for l in x.splitlines(True)
                   if not l.lstrip().startswith("#") and l != chr(9) + TRAP_USTACK_CLOSE
                   and l.strip() and l not in lines)


def _fold_old_span(t, sp, fold_head):
    """off_text on an OLD_SPAN tree (an early draft / a staged block with a different print set)"""
    pre, mid, post, sim, why = pieces(t)
    if not why:
        return pre + post, None
    _a = t.find(OP_L)
    if _a < 0 or t.count(OP_L) != 1 or t.find(chr(10) + OP_L) != _a - 1 or (_a > 0 and t[_a - 1] != chr(10)):
        return None, "the OLD block's opener is not a single line in the text"
    if _a != sp[0]:
        return None, "the OLD block's opener is not at its span's start"
    _cr = chr(10) + CLOSE
    _b = t.find(_cr, _a + len(OP_L))
    if _b < 0:
        return None, "the OLD block's body-close is not a line after its opener"
    _b += 1
    _body = t[_a: _b]
    _head = t[_a: _b] if t[:_a].endswith(chr(10) + TRAP_FRAME_CLOSE) else ""
    _root = _a - (len(_head) + 1 if _head else 0)
    # the body: this patcher's statements (a draft's comments / print set may differ; not its statements)
    _lines = _body.splitlines(True)
    _n = [k for k, l in enumerate(_lines) if l.startswith("if (") and not l[0] in " \t"]
    if not _n:
        return None, "the OLD block's body does not start with its pid gate"
    _n = _n[0]
    _body_text = "".join(_lines[_n:])
    def _core(x):
        return "".join(l for l in x.splitlines(True)
                       if l.strip() and not (l.lstrip().startswith("/*") or l.lstrip().startswith("*")))
    _old = None   # (the iss-rows draft is SUPERSEDED: it is refused by name in verify, never folded)
    if not (_core(_body_text) == _core(TRAP_BODY)):
        return None, ("the OLD block's body is not this patcher's body (not a whole block to replace; "
                      "an altered block is never silently accepted as 'staged')")
    # the 1037 close, and the anchor line 1025 had: the LAST one in the tail; closes may follow it
    _fc1037 = t.find(chr(10) + TRAP_FRAME_CLOSE, _b)
    if _fc1037 < 0:
        return None, "the OLD block's 1037 close is not after its body"
    _fc1037 += 1
    _tail = t[_b:_fc1037]
    _anchor = chr(9) + TRAP_USTACK_CLOSE
    _k = _tail.rfind(chr(10) + _anchor)
    if _k < 0:
        return None, "the OLD block's tail does not carry a 1025 anchor line"
    _k += 1
    _stranded = _tail[_k + len(_anchor):]
    if re.sub(r"(?m)^.*?(?:/\*.*?\*/|#.*)$", "", _stranded + t[_fc1037:_fc1037 + 200]).strip("\n \t"):
        if re.sub(r"(?m)^.*?(?:/\*.*?\*/|#.*)$", "", _stranded).strip():
            return None, "the OLD block's close is followed by statements, not by closes"
    _closes = [l for l in _stranded.splitlines(True) if l.strip()]
    if not _closes and t[:_a].endswith(chr(10) + TRAP_FRAME_CLOSE):
        return None, "an FC close stands in front of the opener without the 1037 close in the tail"
    cand = t[:_root] + t[_b:]
    _keep = [l for l in [CLOSE, TRAP_FRAME_CLOSE] if l not in _closes] or [CLOSE]
    _at = _root
    for _l in _keep:
        cand = cand[:_at] + _l + cand[_at:]
        _at += len(_l)
    _blk = set(t[_root:_fc1037].splitlines(True))
    def strip(x):
        return "".join(l for l in x.splitlines(True)
                       if not l.lstrip().startswith("#") and l not in _blk)
    if strip(cand) != strip(t):
        return None, ("the folded text is not the pre-1039 text (a strip that takes both directives and "
                      "1025's close changes with the fold)")
    return cand, None


def verify_off(xnu):
    """Structural, on the staged tree: pieces() consumed the block (its text is byte-exact); the switch
    is ONE direct `#if`..`#endif` pair around exactly that block; every row is inside it; no directive
    sits among the statements; and our K[2]+K[3] seam is the only one in the file.  --off-check is the
    byte-exact OFF proof against a pre-staged copy."""
    tp = trap_path(xnu)
    if not os.path.isfile(tp):
        print("patch_d13_frame_carrier: --verify-off: no %s" % tp, file=sys.stderr)
        return 1
    t = read(tp)
    # A SUPERSEDED BODY (measured 2026-10-19): the tree carries this rung's block, but the block reads
    # thread->machine.iss -- a REGISTER block at pcb.c:331/334/337 and cswitch.s:132, NOT an
    # arm_saved_state_t -- and prints iss words 13..16 under the names pc/lr/sp/spsr.  The registered
    # design (this script's docstring and records/1039-read.txt) DROPS the iss rows: a wrong-layout
    # reading under a role name is a cell that would decide itself.  Refuse by value; the repair is
    # fold the block out (--verify-off on a tree that HAS it is refused, so the fold's proof is the
    # shape: docstring AND rows) -- say which row names the superseded reading.
    _o = t.find(OP_L)
    _sup = [] if _o < 0 else [r for r in ("xnu_live_fcr_iss_pc=", "xnu_live_fcr_iss_lr=",
                                          "xnu_live_fcr_iss_sp=") if r in t[_o:]]
    if _sup:
        print("patch_d13_frame_carrier: --verify-off FAIL: the staged block is a SUPERSEDED body (it "
              "reads thread->machine.iss and prints %s); the registered design has NO iss rows. Fold it "
              "out and re-stage from the pre-1039 tree." % ", ".join(_sup), file=sys.stderr)
        return 1
    # pieces() first: in a composed tree the switch's SPELLING also stands inside 1038's staged literal
    # (off_text folds OLD->NEW), so "switch absent" can only be read off the block's SHAPE.
    pre, mid, post, sim, why = pieces(t)
    _hh = OP_L + TRAP_BODY + CLOSE + SITE_FAST
    if t.count(_hh) == 1:
        # THE CURRENT FORM (2026-10-19 19:2x): one direct pair in front of 1037's close, at the seam.
        _o = t.index(_hh)
        pre, mid, post = t[:_o], TRAP_BODY, t[_o + len(_hh):]
        why, sim = None, pre + SITE_FAST + post
        post_anchor = 0
        TAIL = SITE_FAST
    elif why:
        # the composed tree: 1037's close does NOT follow the head (1038's slot stands between), so the
        # block is found by its END line (ours, K[2]) plus the 1025 close after it -- ours where stage()
        # wrote the block in place of 1037's close, the pre's own (tab-indented) where it spliced in
        # FRONT of 1037's close -- and its body runs BACK from there.
        TAIL = K[2] + chr(10) + chr(9) + TRAP_USTACK_CLOSE
        if t.count(TAIL) != 1:
            TAIL = K[2] + chr(10) + K[3] + chr(10)
        if t.count(TAIL) != 1:
            # a tree with a STRAY K[0] after the block (measured 2026-10-19: one stood between our
            # body-close and 1025's close, pushing both seams past 1): anchor the body at OUR open
            # line and count the closes after it instead of the whole file's.
            _o = t.find(OP_L)
            _body = TRAP_BODY.rstrip(chr(10)) + chr(10)
            if _o >= 0 and t[_o + len(OP_L):_o + len(OP_L) + len(_body)] == _body and \
                    t[_o + len(OP_L) + len(_body):].startswith(K[2] + chr(10)):
                TAIL = K[2]                             # our body-close; ours is the FIRST line after the body
        if t.count(TAIL) != 1:
            print("patch_d13_frame_carrier: --verify-off: switch ABSENT (nothing staged).", file=sys.stderr)
            return 1
        e = t.index(TAIL)
        post0 = e + len(TAIL)
        for _ in range(32):                 # OUR anchor line(s); past them the pre text's own closes
            if t.startswith(chr(9) + TRAP_USTACK_CLOSE, post0):
                post0 += len(chr(9) + TRAP_USTACK_CLOSE)
            else:
                break
        body = TRAP_BODY.rstrip(chr(10)) + chr(10)
        o = e - len(body) - len(OP_L)
        if o < 0 or t[o:o + len(OP_L)] != OP_L or t[o + len(OP_L):e] != body:
            print("patch_d13_frame_carrier: --verify-off FAIL: the tail (body-close + anchor) is not "
                  "preceded by this patcher's opener and body.", file=sys.stderr)
            return 1
        mid = t[o + len(OP_L):e]                    # what pieces() calls the body: opener + body
        # the head: our head close K[0] (the block's first line) -- it re-closes 1025's bracket
        pre = t[:o]
        # THE HEAD IS OURS: the close that stands immediately before OUR open line, not the file's last
        # K[0] -- 2026-10-19 a stray staging put a K[0] AFTER the block (at the 1025 tail), and rfind
        # read that one, slicing `pre` past 1037's bracket (shape=False on a correct tree).
        head0 = o - len(K[0]) if pre.endswith(K[0], 0, o) else o - len(OP_L)
        pre, post = t[:head0], t[post0:]
        why = None
        post_anchor = post0 - (e + len(TAIL))
    if why:
        print("patch_d13_frame_carrier: --verify-off FAIL: %s." % why, file=sys.stderr)
        return 1
    # mid may be the composed tree's synthetic copy (built in verify_off's tail-back walk), so this
    # dedent must not touch the function's own variables ([[mi4-measurement-defects]]).
    _stmts_text = textwrap.dedent(mid.replace(TRAP_USTACK_CLOSE, "<ANCHOR>"))
    stmts = [l for l in _stmts_text.splitlines() if l.strip()]
    # the block carries NO preprocessor directive of its own (the uptime rows are plain statements):
    # OFF cannot change trap.c's directive namespace, and the shape below rejects any directive.
    nlin = [l for l in stmts if re.match(r"^\t+#", l)]
    rest = [l for l in stmts if l not in nlin]
    DIRS = []
    ncom = len([l for l in rest if l.startswith("/*") or l.startswith(" *")])
    # the switch is looked for as a DIRECTIVE ID (its spelling also occurs inside 1038's staged literal);
    # the shape below is the real test.
    # STRIPPED directives only: 1038's chunk is written with tab-indented directive lines, whose
    # trailing spaces (`  /* 1038 chunk: arm */`) would otherwise keep K[1] from standing alone.
    kl = [l.strip() for l in t.splitlines(True) if l.lstrip().startswith("#")]
    raw = [l.lstrip(chr(9)) for l in t.splitlines(True) if l.lstrip().startswith("#")]  # newlines kept
    # 2026-10-19: the body-close's anchor line and the bare K[0] are counted AFTER OUR OPEN (a stray K[0]
    # stood between the body-close and 1025's close once; it is not this block's).
    _oo = t.find(OP_L)
    _after = t[_oo + len(OP_L):] if _oo >= 0 else ""
    _cur = t.count(_hh) == 1
    have = (_cur and t.count(OP_L) == 1 and t.count(CLOSE) == 1
            and _after.startswith(TRAP_BODY + CLOSE + SITE_FAST)
            and _after.count(TRAP_FRAME_CLOSE) == 1      # 1037's: the line this tree carries its SPLICE on
            and not [r for r in FCR_ROWS if (r not in t[_oo:_oo + len(_hh)])])
    have = have and (_cur or (t.count(K[0] + K[1]) == 1                              # our head: close, then our open
            and _after.startswith(TRAP_BODY + K[2] + chr(10))  # our body-close stands right after the body
            and _after.count(K[2] + chr(10) + chr(9) + TRAP_USTACK_CLOSE) >= 1  # ... and the anchor line after it
            and len([l for l in raw if l.strip() == _SW_CLOSE]) >= 2  # head + body-close at least
            # SIX in a tree whose old 1037 draft was written over (it left its head close), five in
            # one only 1039's block stands in; a duplicated staging pushes both counts past 6.
            and _after.count(K[0]) <= 2     # exactly ours; a duplicate pushes 4+
            and not re.search(r"^\s*#", "\n".join(rest), re.M)      # no OTHER directive among the statements
            and bool(rest) and rest[0].startswith("/*")             # the block's comment first
            and rest[-1] == "}"                                     # ... and its outer brace last
            and rest[ncom].lstrip(chr(9)).startswith("if (") and rest[ncom].endswith(") {")))
    missing = [r for r in FCR_ROWS if (r not in mid)]
    # the switch is ONE direct pair, apart from the column-0 head close that re-closes 1025's bracket:
    # exactly two `#if`-opens of the switch, of which the first follows our head's close.
    n_open = len([l for l in kl if l.strip() == OP_LINE])
    nnde = kl.count(CLOSE)
    from collections import Counter as _Ct
    _dirs = _Ct(("open" if l.lstrip().startswith(("#if", "#ifdef", "#ifndef")) else "close")
                if l.lstrip().startswith(("#if", "#ifdef", "#ifndef", "#endif")) else "other" for l in kl)
    have = (bool(have) and (_cur or (n_open in (1, 2) and t.count(K[0] + K[1]) == 1)))
    # the switch is not merely spelled: it is a DIRECTIVE ID (a prefixed or quoted spelling is not it),
    # counted by the directive LINE (never by substring: K[0] already ends in a newline)
    have = bool(have) and SWITCH in if_stage90_ids(t) and \
        (len([l for l in raw if l.strip() == _SW_CLOSE]) == 1 if _cur else
         len([l for l in raw if l.strip() == _SW_CLOSE]) >= 2)  # (current: the body's only) else head and body-close
                                                            # (pieces() proves the second follows the body,
                                                            # and the anchor line follows the second)
    # an altered body: rows spelled wrongly, or a body whose outer brace no longer closes as written
    have = bool(have) and not [r for r in FCR_ROWS if (r not in mid)]
    body_exact = mid.rstrip(chr(10)) == TRAP_BODY.rstrip(chr(10))

    # our OPEN line is NOT unique in a 1038-composed OFF text (1038's chunk-a literal carries its
    # spelling), and with pieces()' body there is exactly one line on which K[1] stands alone.
    # the composed tree's head close is STAGED TEXT (1038's literal carries it indented or quoted),
    # not a live directive: the raw count above is the test there; a live directive is in `kl`.
    # ... the composed tree counts OUR pattern (`close` then `open`) instead of the bare close: a stray
    # K[0] after the block (2026-10-19) is not ours.
    _oo = t.find(OP_L)
    shape = bool(have) and body_exact and (_cur or (K[1] in kl or
            (t[_oo + len(OP_L):] if _oo >= 0 else "").startswith(TRAP_BODY + K[2] + chr(10))))
        # OFF, by construction: pieces() located the block as the literal run span = K[0] K[1] body K[2] K[3],
    # so sim = pre + post IS the pre-1039 text exactly (our five lines dropped, the anchor line kept);
    # pieces() also required this block once and 1025's own bracket open exactly once before it.  This
    # check states what must be true of pre + post itself; --off-check proves it byte for byte.
    # Our block sits IN FRONT of 1038's block, so dropping our lines leaves 1038's `#endif /* TRAP_FRAME */`
    # doing the work ours does when ON: the source is not directive-balanced either way (that is 1038's
    # seam shape), and the OFF proof is the COMPILED view -- directive lines dropped, everything else
    # kept -- of the pre-1039 text and of both OFF readings of our seam.  Identical mechanism to
    # tools/patch_d13_trap_frame.py's verify_off and the 1039 build's seam check.
    base = pre + post
    def kept(x):
        return "".join(l for l in x.splitlines(True) if not l.lstrip().startswith("#"))
    # pieces()' sim drops head..tail's body and keeps our CLOSE as the tail; the 1038-composed OFF text
    # (build_1039.sh step 3) drops the OPEN line instead and keeps both closes.  Both are the compiled
    # view only if the outcome does not depend on which line stands in front of 1038's slot a.
    # head = K[0] + newline; the body starts after the OPEN line; our body-close begins the tail.
    _h = pre.__len__() + len(K[0]) + 1
    # past the OPEN line first: with the block in place the close 1038's OFF acts on is the body's, not
    # the head's (the head's close stands inside the block, which the OFF text does not carry).
    _c = t.find(CLOSE, _h)
    if _c >= 0 and t.startswith(OP_L, _c):
        _c = t.find(CLOSE, _c + len(OP_L))
    sim_alt = t[:_h] + t[_c:]
    seam_ok = (kept(pre + TRAP_USTACK_OPEN + post) == kept(base)
               and kept(pre + TRAP_USTACK_CLOSE + post) == kept(base)
               and kept(pre + CLOSE + post) == kept(base)
               and kept(sim_alt) == kept(base))
    print("   trap.c [ON] : ONE switch pair (close..open), no nested directive: %s (body_exact=%s shape=%s seam=%s)"
          % (bool(have), body_exact, shape, seam_ok))
    print("   trap.c      : the body is byte-exact as this patcher writes it: %s" % body_exact)
    print("   trap.c      : all %d rows inside the gated block: %s"
          % (len(FCR_ROWS), "yes" if not missing else "NO: %s" % ", ".join(missing)))
    print("   trap.c      : block shape as this patcher writes it, switch line unique: %s"
          % ("yes" if shape else "NO"))
    print("   trap.c      : OFF text (our lines dropped) = the pre-1039 text with 1025's bracket closed "
          "at the anchor: %s" % seam_ok)
    if have and body_exact and not missing and shape and seam_ok:
        print("patch_d13_frame_carrier: --verify-off PASS (the seam is understood; --off-check <pre copy>")
        print("                               makes the OFF text exact against the pre-staging bytes).")
        return 0
    print("patch_d13_frame_carrier: --verify-off FAIL.", file=sys.stderr)
    return 1


def off_check(xnu, pre):
    """Exact OFF proof: stage a COPY of `pre` (a pre-staged trap.c), then the simulated OFF text of the
    copy must equal `pre` byte for byte."""
    import shutil
    import tempfile
    d = tempfile.mkdtemp(prefix="p1039-off-")
    os.makedirs(os.path.join(d, "osfmk", "arm"))
    tp = trap_path(d)
    shutil.copyfile(pre, tp)
    before = read(tp)
    if stage(d, do_apply=True) != 0:
        print("patch_d13_frame_carrier: --off-check: stage refused", file=sys.stderr)
        return 1
    sim = pre_off_sim(read(tp))
    ok = (sim == before and sim.count(TRAP_USTACK_CLOSE) == before.count(TRAP_USTACK_CLOSE))
    print("   off-check: OFF text == the pre-1039 copy byte for byte: %s (%d bytes vs %d)"
          % ("yes" if ok else "NO", len(sim), len(before)))
    if not ok:
        import difflib
        for l in list(difflib.unified_diff(before.splitlines(), sim.splitlines(), "pre", "off",
                                           lineterm=""))[:40]:
            print(l)
        print("patch_d13_frame_carrier: --off-check FAIL.", file=sys.stderr)
        return 1
    print("patch_d13_frame_carrier: --off-check PASS.")
    return 0


# ---------------------------------------------------------------- shared-namespace registration

def _check_text(t):
    """check_trap's reading of a TEXT this patcher would write (the refused/hand-folded trees are a
    closed set this patcher understands; anything else is refused in the checker's words)."""
    if SWITCH in if_stage90_ids(t):
        if TRAP_BLOCK in t:
            return True, None, t, "already staged"
        if off_text(t)[0] is not None:
            return True, None, t, "re-stage"
        return False, None, t, "trap.c carries a %s block this patcher can neither keep nor fold" % SWITCH
    foreign = sorted(i for i in if_stage90_ids(t) if i not in TRAP_ALLOWED_IF_IDENTIFIERS)
    if foreign:
        return False, None, t, "foreign directives: %s" % ", ".join(foreign)
    if t.count(TRAP_ANCHOR) != 1:
        return False, None, t, "the anchor occurs %d time(s), not once" % t.count(TRAP_ANCHOR)
    return True, None, t, "anchor unique, switch absent"


def check_trap(xnu):
    p = trap_path(xnu)
    if not os.path.isfile(p):
        return False, p, "", "no %s (D13 tree not provisioned?)" % p
    t = read(p)
    # the SWITCH is looked for as a DIRECTIVE ID, not as a substring: 1038 (staged before this rung) can
    # stand with this switch absent, and a staged literal may spell it in a comment.
    if SWITCH in if_stage90_ids(t):
        if TRAP_BLOCK in t:
            return True, p, t, "already staged"
        _sp = old_span(t)
        u = t[:_sp[0]] + TRAP_FRAME_CLOSE + t[_sp[1]:] if _sp else t
        if _sp and TRAP_BLOCK not in u and SWITCH not in u:
            return True, p, u, "re-stage"
        # a DRAFT staged by an earlier session: the switch is present, the body is not current -- the
        # RE-STAGE folds it by shape (off_text).  Only a block that RUNS TO ITS BODY-CLOSE is a whole
        # block; an altered one (a row removed) has no body-close to fold to and is REFUSED.
        u2, _why2 = off_text(t)
        if u2 is not None:
            return True, p, t, "re-stage"
        return False, p, t, (
            "trap.c carries a %s block this patcher can neither keep nor fold (%s). Nothing is written."
            % (SWITCH, _why2))
    foreign = sorted(i for i in if_stage90_ids(t) if i not in TRAP_ALLOWED_IF_IDENTIFIERS)
    if foreign:
        return False, p, t, (
            "%s's directives also evaluate %s. trap.c is a SHARED namespace across rungs: add the "
            "switch to TRAP_ALLOWED_IF_IDENTIFIERS here and to the other patchers' sets. "
            "([[mi4-one-file-many-rungs]])" % (TRAP_REL, ", ".join(foreign)))
    # THE PRE-1039 TREES.  1037 replaces this switch's own parent `#if` (its block is the 10635 B text
    # written between that anchor and 1025's close), so the two-line anchor may stand zero times.  What
    # this rung needs is the site: 1037's `#if` (unique) and, after it, its close and 1025's close.
    _sfast, _sseam = t.count(SITE_FAST), t.count(CHUNK_END)
    if _sfast + _sseam == 1:
        # 1037's close is a whole line: its FAST form, or the SEAM form the 1038 ROW side leaves (its
        # chunk opens on that line).  After it: the seam's own closes, else 1025's close.
        _p, _c = (t.find(SITE_FAST), SITE_FAST) if _sfast else (t.find(CHUNK_END), CHUNK_END)
        _q = _p + len(_c)
        # what the site carries before 1025's own close: its closes (`#endif /* USTACK */`, or 1038's
        # staged block, whose own directives and statements end at its `#endif /* 1038 BLOCK END */`).
        _e = t.find(TRAP_USTACK_CLOSE, _q)        # 1025's close, tab-indented (1037) or at column 0
        _site = t[_q:_e] if _e >= 0 else ""
        _dirs = [l.strip() for l in _site.splitlines() if l.strip().startswith("#exit"[:-1] + "if")]
        if _q < 0 or _e < 0 or (_sfast and _dirs != []) or (_sseam and CHUNK_END not in _site):
            return False, p, t, ("1037's close line at byte %d is not followed by its closes and 1025's "
                                 "close" % _p)
        return True, p, t, "1037's site (1037's close line, 1025's close after it), switch absent"
    if t.count(TRAP_ANCHOR) != 1:
        _h = "#if defined(STAGE90_XNU_TRAP_FRAME) && STAGE90_XNU_TRAP_FRAME\n"
        _tc = t.replace(TRAP_ANCHOR, "", 1)        # ONE anchor is legitimate; a second leaves a bare close
        _i = t.find(_h)
        _c = t.find(TRAP_FRAME_CLOSE, _i)
        _u = t.find(TRAP_USTACK_CLOSE, _c) if _c >= 0 else -1
        # exactly ONE contract.  1037's text has one inner close of its own and (1038 at the seam) the
        # 1038 chunk carries one more, so 1025's opener may occur two or three times - but each opener
        # has exactly one column-0 close of its own, AND 1025's outer close has none beside it; a
        # duplicated anchor adds an unpaired one.
        # (1037's OWN text closes 1025's bracket once with a TAB-indented close before the column-0 one;
        # the count is "an opener AND its close", i.e. >= 1 of each, and the boundary closes carry at
        # most the seam's one extra pair.)
        if not (_i >= 0 and t.count(_h) == 1 and _c > _i and _u > _c
                and t.count(TRAP_FRAME_CLOSE) <= 3
                and 1 <= t.count(TRAP_USTACK_OPEN) <= 2
                and (	# 1025's bracket: every opener of it is closed (its tab-indented close is its own)
                     t.count(chr(10) + TRAP_USTACK_CLOSE)
                     + t.count(chr(10) + chr(9) + TRAP_USTACK_CLOSE)
                     == t.count(TRAP_USTACK_OPEN) + 1)
                and t.count(TRAP_FRAME_CLOSE) == t.count(_h) + 1   # ditto, close-counted: 1037 runs one
                                                            # round more than 1025 (its printf, then 1025)
                # 1037's text carries ONE inner close of its own, and the two-line anchor that replaced it
                # none besides (the anchor is blanked first): a duplicated anchor leaves one bare.
                and _tc.count(TRAP_FRAME_CLOSE) <= 1
                and _h not in _tc):                     # no body left without its opener (a bare printf block)
            return False, p, t, (
                "the anchor occurs %d time(s), expected exactly 1 (1037's contract - one `#if`, then "
                "its close, then 1025's close - does not stand either)." % t.count(TRAP_ANCHOR))
        # (this branch is also where a WHOLE 1037 block stands with the anchor gone: its body is a
        # literal that spells `#if defined(...)` at a line start but is not a directive, so the
        # strict opener close-count above matches.  An old draft without 1037's inner close: one fewer.)
        return True, p, t, "1037's site (anchor replaced by 1037's block), switch absent"
    opens = t.splitlines(True).count(TRAP_USTACK_OPEN)
    if opens != 1:
        return False, p, t, "1025's `#if` occurs %d time(s), expected exactly 1" % opens
    return True, p, t, "anchor unique, switch absent"


def stage(xnu, do_apply):
    ok_t, tp, t, msg_t = check_trap(xnu)
    if msg_t == "already staged":
        if old_span(t) is not None:
            msg_t = "re-stage"
            ok_t = True
    if not ok_t:
        print("patch_d13_frame_carrier: REFUSE (trap.c) - %s. Writing nothing." % msg_t, file=sys.stderr)
        return 1
    if msg_t == "already staged":
        print("patch_d13_frame_carrier: already staged - no-op, OK.")
        return 0
    if msg_t == "re-stage":
        print("   trap.c : an OLD %s block - replaced whole." % SWITCH)
    else:
        print("   trap.c : %s." % msg_t)
    if not do_apply:
        print("patch_d13_frame_carrier: plan OK (dry run; pass --apply to write).")
        return 0
    if msg_t != "re-stage" and pieces(t)[4] is None and t.count(TRAP_BLOCK) != 1:
        # stage() would splice IN FRONT OF 1037's close; with this block already staged that leaves TWO
        # top-level regions.  A second stage of the SAME text is a no-op (a re-stage of a new body is a
        # fold first; --restage).
        print("patch_d13_frame_carrier: already staged - no-op, OK.")
        return 0
    if msg_t == "re-stage" and TRAP_BLOCK not in t:
        t, _why_fold = off_text(t, fold_head=True)    # a draft: fold it out, then the block goes in place
    if t is None:
        print("patch_d13_frame_carrier: REFUSE (trap.c) - the block could not be folded out. Writing nothing.",
              file=sys.stderr)
        return 1
    # the block WE write, in place: when the kept text already holds it (the canonical staging after
    # 1037's close), replacing it with itself is the identity -- that is what makes a second apply a
    # no-op.  Otherwise splice it where the anchor line's first line (1037's close) stands: the block
    # ends with that form (head, opener, body, body-close, anchor), so the splice starts AT 1037's close
    # and takes no line with it.
    _U = chr(9) + TRAP_USTACK_CLOSE
    if t.count(TRAP_BLOCK) == 1:
        n = t
        msg = "block already stands where this patcher writes it (kept; xnu_live_fcr_* rows)."
    else:
        i = t.index(SEAM)
        e = i + len(SEAM)
        if t.startswith(_U, e):
            e += len(_U)
        n = t[:i] + TRAP_BLOCK + t[e:]
        msg = ("staged (xnu_live_fcr_* rows, %d) after 1037's close, inside 1025's data-abort publisher "
               "(in front of 1038's slot)." % len(FCR_ROWS))
    ok_n, _p, _t, why_n = _check_text(n)
    if not ok_n:
        print("patch_d13_frame_carrier: REFUSE (trap.c) - the staged text would not be understood by this "
              "patcher (%s). Writing nothing." % why_n, file=sys.stderr)
        return 1
    write(tp, n)
    print("   trap.c : " + msg)
    return 0


def register_into(text, rel):
    """STAGE90_XNU_FRAME_CARRIER into one file's allow list.  Returns (text, status) with status in
    {"present", "added", "ABSENT"}."""
    if SWITCH in text:
        return text, "present"
    if rel == BUILD_REL:
        if BUILD_ANCHOR not in text:
            return text, "ABSENT"
        line = ("# 1039: STAGE90_XNU_FRAME_CARRIER -- the frame carrier (records/1037-read.txt RUNG READING\n"
                "# 2-3).  INSTRUMENT ONLY.  Adds a block (owned by the 1039 patcher) inside 1025's data-abort\n"
                "# publisher that reads thread->machine.uss through its pointer/task map (not through arm_ctx),\n"
                "# TH_PCB_ISS, the entry's saved spsr, thread->continuation and the pc/lr bit0.\n"
                "# Same GLOBAL ARRAY channel as every probe above.  OFF compiles the 1038 tree's bytes.\n"
                + BUILD_READER + "\n")
        return text.replace(BUILD_ANCHOR, BUILD_ANCHOR + line, 1), "added"
    # elsewhere: the anchor is a member of the file's trap.c allow SET (TRAP_ALLOWED_IF_IDENTIFIERS, or
    # EXEC_ALLOWED_STAGE90 in caller_probe), not 1037's switch specifically (1035's set never carried it).
    # Every such set gets the switch; any set we cannot find the end of is a refusal, never a silent skip.
    return _register_sets(text, rel)


def _members(line):
    """(prefix, n_quoted, rest) for a line; a member line has n_quoted == 1."""
    q = re.findall(r'"[A-Z0-9_]+"', line)
    return len(q)


def _set_end(text, pos):
    """((start, end, line), closing-brace offset) of the set's LAST member and its brace, or None.
    A member is a line carrying exactly ONE quoted identifier; prose comments containing quotes are
    not members (the patchers' sets have plenty of prose in `# ...` comments)."""
    member = re.compile(r'^[ \t]*"[A-Z0-9_]+"[ \t]*(?:,[ \t]*#[^\n]*|[ \t]*#[^\n]*|,?[ \t]*)$')
    depth, k, prev_line_start = 0, pos, 0
    while k < len(text):
        c = text[k]
        if c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                close = k
                ls = text.rfind("\n", 0, close) + 1
                le = text.find("\n", close)
                le = len(text) if le < 0 else le
                line = text[ls:le]
                body = line[:close - ls]                 # the members on the brace's line
                if _members(body) == 1 and member.match(body.lstrip()):   # `"LAST"}` inline
                    return (ls, ls + len(body), body), close
                # members on their own lines, going up from the brace's line
                p = ls if ls > 0 else 0
                while p > 0:
                    pe = p - 1
                    ps = text.rfind("\n", 0, pe) + 1
                    body = text[ps:pe]
                    if body.strip() == "":
                        return None
                    if _members(body) == 1 and member.match(body):
                        return (ps, pe, body), close
                    if body.lstrip().startswith("#"):            # a comment between members
                        p = ps
                        continue
                    return None
                return None
        k += 1
    return None


def _register_sets(text, rel):
    # every allow-set spelling in the patchers: ALLOWED_IF_IDENTIFIERS (dyld_witness, undef_raise),
    # TRAP_ALLOWED_IF_IDENTIFIERS, EXEC_ALLOWED_STAGE90, ALLOWED_STAGE90 (h2_stack_headroom)
    names = [m for m in re.finditer(r'(?:TRAP_ALLOWED_IF_IDENTIFIERS|ALLOWED_IF_IDENTIFIERS|'
                                    r'EXEC_ALLOWED_STAGE90|ALLOWED_STAGE90)\s*=\s*\{', text)]
    if not names:
        return text, "ABSENT"
    edited = 0
    for m in reversed(names):
        r = _set_end(text, m.end() - 1)
        if r is None:      # not a set: a string or a fixture inside this file's own selftest
            continue
        (ms, me_, body), close = r
        indent = re.match(r"[ \t]*", body).group(0)
        run = body.rstrip()
        if not run.endswith(",") and not re.search(r'#[^\n]*$', run):
            run += ","
        # the brace moves to our line; text after it (on its old line, up to the next newline) is
        # re-emitted in place AFTER our line's comment -- never between the quote and the comment
        nl = text.find("\n", close)
        after = text[close + 1:nl] if nl >= 0 else text[close + 1:]
        ins = (run + "\n" + indent + '"STAGE90_XNU_FRAME_CARRIER"}' +
               "  # 1039 (tools/patch_d13_frame_carrier.py)" + after)
        text = text[:ms] + ins + text[close + 1 + len(after):]
        edited += 1
    return (text, "added") if edited else (text, "ABSENT")


def register(root=REPO, do_apply=False):
    report, ok = [], True
    paths = [os.path.join(root, p) for p in PATCHERS] + [os.path.join(root, BUILD_REL)]
    for p in paths:
        rel = os.path.relpath(p, root)
        if not os.path.isfile(p):
            report.append((rel, "ABSENT-FILE"))
            ok = False
            continue
        nt, st = register_into(read(p), rel)
        if st == "ABSENT":
            ok = False
        report.append((rel, st))
        if st == "added" and do_apply:
            write(p, nt)
    return ok, report


# ---------------------------------------------------------------- selftest

BASE_TRAP = (
    "#if defined(STAGE90_XNU_USTACK_PROBE) && STAGE90_XNU_USTACK_PROBE\n"
    "#if defined(STAGE90_XNU_TRAP_FRAME) && STAGE90_XNU_TRAP_FRAME\n"
    "\t\t\t\t\tprintf(\"xnu_live_fb_pc=0x%08x\\n\", 0U);\n"
    "#endif /* STAGE90_XNU_TRAP_FRAME */\n"
    "#endif /* STAGE90_XNU_USTACK_PROBE */\n"
    "int after(void) { return 0; }\n"
)

# variants of a staged block that must be REJECTED
_UNGUARDED = "vm_map_lookup_entry(map, _fcr_a & ~3U, &_fcr_e)) {"


def selftest():
    import tempfile
    fails = []
    tmp = tempfile.mkdtemp(prefix="p1039-")

    def tree(name, trap_text):
        root = os.path.join(tmp, name)
        os.makedirs(os.path.join(root, "osfmk", "arm"))
        write(os.path.join(root, TRAP_REL), trap_text)
        return root

    def expect(cond, label):
        print("   ok" if cond else "   FAIL", label)
        if not cond:
            fails.append(label)

    r = tree("good", BASE_TRAP)
    ok, p, t, msg = check_trap(r)
    # (2026-10-19: 1037's close is a WHOLE LINE (`#endif /* TRAP_FRAME */\n`) and 1025's close follows
    # it; the two-line anchor text never stands in a 1037 tree, so the site line is what plan reports.)
    expect(ok and msg == "1037's site (1037's close line, 1025's close after it), switch absent",
           "the pre-1039 tree: plan accepts it (%s)" % msg)
    rc = stage(r, do_apply=False)
    expect(rc == 0 and read(trap_path(r)) == BASE_TRAP, "dry run writes nothing")
    rc = stage(r, do_apply=True)
    t1 = read(trap_path(r))
    expect(rc == 0 and t1.count("\"xnu_live_fcr_pc=") == 1, "staged: exactly one fcr pc row")
    expect(t1.count("\"xnu_live_fb_pc=") == 1, "staged: 1037's row is untouched")
    # OFF: stage() writes TRAP_BLOCK (head, opener, body, body-close, then 1025's ANCHOR line) in place
    # of nothing, so the block-less text is exactly the pre text.  The fixture has no anchor line of its
    # own, so the comparison is on PROGRAM TEXT (`_compiled`): the anchor is a directive.
    def _off(x):
        k = x.rfind(TRAP_BLOCK)
        return x if k < 0 else x[:k] + x[k + len(TRAP_BLOCK):]
    expect(_compiled(_off(pre_off_sim(t1))) == _compiled(_off(BASE_TRAP)),
           "OFF removes every edit -> the pre-1039 text (our pair dropped as the preprocessor drops it)")
    rc2 = stage(r, do_apply=True)
    expect(rc2 == 0 and read(trap_path(r)) == t1, "second --apply is an idempotent no-op")
    expect(verify_off(r) == 0, "--verify-off PASS on the staged tree")
    # the PASS is not vacuous: a staged copy whose block text was altered must FAIL verify_off.
    import tempfile as _tf, shutil as _sh
    _x = _tf.mkdtemp(prefix="p1039-vx-")
    os.makedirs(os.path.join(_x, "osfmk", "arm"))
    write(trap_path(_x), read(trap_path(r)).replace("xnu_live_fcr_seq=", "xnu_live_fcr_SEQ=", 1))
    expect(verify_off(_x) != 0, "--verify-off FAILS on a staged tree whose block text was altered")
    _sh.rmtree(_x, ignore_errors=True)
    # a switch ID that is only a PREFIX of a registered one must not count as present
    expect(not if_stage90_ids("#if defined(STAGE90_XNU_FRAME_CARRIER_EVIL)\n") & {SWITCH}
           and if_stage90_ids('"#if defined(STAGE90_XNU_FRAME_CARRIER)"\n') == set(),
           "a prefixed or quoted switch spelling is not the switch")
    _o = t1.index(OP_L + TRAP_BODY + CLOSE + SITE_FAST)
    inside0 = t1[_o + len(OP_L):_o + len(OP_L) + len(TRAP_BODY)]   # the statements, as pieces() reports them
    _w = None
    from collections import Counter
    _c = Counter(len(l) - len(l.lstrip("\t")) for l in inside0.splitlines() if l.strip())
    inside = "\n".join(l for l in textwrap.dedent(inside0).splitlines() if l.strip()) + "\n"   # statements only
    expect(all(("\"%s" % row) in inside for row in FCR_ROWS),
           "every one of the %d rows is inside the gated block" % len(FCR_ROWS))
    _nlin = [l for l in inside.split("\n") if re.match(r"^\s*#", l)]
    _be = [l for l in inside.split("\n") if not re.match(r"^\s*#", l)]
    expect(_nlin == [],
           "the block carries NO directive that OPENS (OFF cannot change trap.c's directive namespace)")
    # NEGATIVE: a directive that opens inside the block and never closes there defeats --verify-off
    _pat = [l for l in t1.splitlines(True) if "xnu_live_fcr_uptime_ok=1" in l][0]
    _bad = t1.replace(_pat, _pat + I + "\t#if defined(BAD_OPEN)\n", 1)
    assert _bad != t1, "the negative fixture did not apply"
    write(trap_path(r), _bad)
    expect(verify_off(r) != 0, "--verify-off FAILS on a block with an unbalanced directive")
    write(trap_path(r), t1)
    # (2026-10-19: the iss words were DROPPED from the registered design -- never re-add them; the
    # depth counts are the uss-only body: the loaders (3) and the prints+uptime (4).)
    expect(sorted(_c.items()) == [(0, 8), (1, 7), (2, 17), (3, 46), (4, 6), (5, 2)],
           "every block line sits at a brace depth the body has (8 outer, 7 pid gate, 17 shot, 46 in "
           "the loaders, 6 in the uptime+uss prints, 2 closing) (%s)" % sorted(_c.items()))
    expect(all(n not in inside for n in ("_fb", "_wl", "_evf", "_pcc", "_abt")),
           "the block never names an earlier sibling's locals")
    # the read discipline: every record word goes through the gate; the ≤4 loop counts match
    expect(inside.count("vm_map_lookup_entry(_fcr_map, _fcr_a & ~3U, &_fcr_e)) {") == 1
           and "(char *)&_fcr_w[_fcr_i], 4) == 0" in inside,
           "user records are read only under vm_map_lookup_entry + copyin")
    expect(inside.count("< 17U; _fcr_i++") == 3 and inside.count("for (_fcr_i = 0;") == 3 and inside.count("_fcr_ok[_fcr_i] = FALSE") == 1,
           "three 17-word loops: init and the two uss loaders (the iss read was dropped before the press)")
    expect("thread->machine.iss" not in inside, "the block does not read thread->machine.iss")
    expect("_fcr_uss_p < 0x80000000U" in inside and "_fcr_uss_p >= 0x80000000U" in inside,
           "the loader is chosen BY THE ADDRESS and the choice is printed (uss_via)")
    expect("(unsigned)arm_ctx->sp ^ _fcr_w[13]" in inside and "xnu_live_fcr_uss_armctx_diff=" in inside,
           "the diff compares arm_ctx with the pointed-to record's CONTENTS")
    expect("< 4U) {" in inside and "_fcr_tid | 1U" in inside, "one-shot per thread, cap 4")

    # FAILURE MODES
    r2 = tree("noanchor", BASE_TRAP + "/* a later */\n" + TRAP_ANCHOR)
    ok2, _, _, msg2 = check_trap(r2)
    expect(not ok2 and "expected exactly 1" in msg2, "a duplicated anchor: REFUSE (%s)" % msg2)
    r2b = tree("noanchor2", BASE_TRAP.replace(TRAP_ANCHOR, ""))
    ok2b, _, _, msg2b = check_trap(r2b)
    expect(not ok2b and "expected exactly 1" in msg2b, "a missing anchor: REFUSE")
    r2c = tree("unbalanced", BASE_TRAP.replace("#endif /* STAGE90_XNU_USTACK_PROBE */\n", "", 1))
    ok2c, _, t2c, _ = check_trap(r2c)
    expect(not ok2c or read(trap_path(r2c)) == t2c, "an unbalanced 1025 bracket: REFUSE or no write")
    r3 = tree("foreign", BASE_TRAP.replace(TRAP_ANCHOR, "#if defined(STAGE90_XNU_NOBODY_ADDED_ME)\n"
                                           "#endif /* STAGE90_XNU_NOBODY_ADDED_ME */\n" + TRAP_ANCHOR))
    ok3, _, _, msg3 = check_trap(r3)
    expect(not ok3 and "STAGE90_XNU_NOBODY_ADDED_ME" in msg3, "a foreign identifier: REFUSE")
    before = read(trap_path(r3))
    stage(r3, do_apply=True)
    expect(read(trap_path(r3)) == before, "a refused stage writes nothing")

    # a MISSING ROW: one printed row removed from the staged text -> its `=]` name is gone
    r4 = tree("row", BASE_TRAP)
    stage(r4, do_apply=True)
    t4 = read(trap_path(r4))
    write(trap_path(r4), t4.replace(
        "\t\t\t\t\tprintf(\"xnu_live_fcr_spsr=0x%08x\\n\", (unsigned)_fcr_w[16]);\n", "", 1))
    write(trap_path(r4), read(trap_path(r4)).replace(TRAP_BLOCK, TRAP_BLOCK))   # keep the block text
    t4b = t4.replace("\t\tprintf(\"xnu_live_fcr_spsr=0x%08x\\n\", (unsigned)_fcr_w[16]);\n", "", 1)
    write(trap_path(r4), t4b)
    ok4, _, _, msg4 = check_trap(r4)
    expect(not ok4 and ("neither" in msg4 or "restore the pre-1039" in msg4),
           "a row-removed tree is REFUSED (not this patcher's body, not a whole block to replace) - "
           "an altered block is never silently accepted as 'staged'")
    expect(read(trap_path(r4)) == t4b, "... and the refusal wrote nothing")
    # -- the row check lives in verify_off/selftest, not in check_trap: judge the staged text directly
    s4 = t4b.find("#if defined(%s) && %s\n" % (SWITCH, SWITCH))
    e4 = t4b.find(CLOSE, s4)
    expect(not all(("\"%s" % row) in t4b[s4:e4] for row in FCR_ROWS),
           "a missing row is detectable: xnu_live_fcr_spsr is absent from the gated block")

    # an UNGUARDED USER READ: copyin lifted out of the task-map gate.  The fixture is cut from the
    # STAGED text (so it cannot drift from TRAP_BLOCK) and re-indented by the line's own whitespace.
    r5 = tree("unguarded", BASE_TRAP)
    stage(r5, do_apply=True)
    t5 = read(trap_path(r5))

    def lift_guard(x):
        i = x.find("if (_fcr_a >= 4U")
        if i < 0:
            return x
        j = x.find("copyin(", i)
        ind = x[x.rfind("\n", 0, i) + 1:i]             # the `if`'s indent
        if ind.strip():
            return x
        return x[:i] + x[j:]

    t5u = lift_guard(t5)
    expect(t5u != t5, "fixture: the guard lines were found and lifted")
    s5 = t5u.find("#if defined(%s) && %s\n" % (SWITCH, SWITCH))
    e5 = t5u.find(CLOSE, s5)
    body5 = t5u[s5:e5]
    read_lor = re.search(r"copyin\(", body5)
    gate_before = body5.rfind("vm_map_lookup_entry", 0, read_lor.start()) if read_lor else -1
    expect(read_lor is not None and gate_before >= 0,
           "the staged block's copyin sits under its gate")
    ungated_lor = None
    for mm in re.finditer(r"copyin\(", body5):
        blk = body5[body5.rfind("for (", 0, mm.start()):mm.start()]
        if "vm_map_lookup_entry" not in blk:
            ungated_lor = mm.start()
    expect(ungated_lor is not None,
           "an unguarded copyin IS detected by the discipline scan (built into the selftest)")

    # a later whole sibling block after 1039's does not disturb plan mode
    r6 = tree("later", BASE_TRAP)
    stage(r6, do_apply=True)
    ok6, _, _, msg6 = check_trap(r6)
    expect(ok6 and msg6 == "already staged", "a re-run on the staged tree is a no-op")

    # registration: a python allow list and the build's DEFINES reader
    py = ('TRAP_ALLOWED_IF_IDENTIFIERS = {\n    "X",\n    "STAGE90_XNU_TRAP_FRAME",         # 1037\n}\n')
    npy, st = register_into(py, "tools/patch_d13_ustack_probe.py")
    expect(st == "added" and npy.count('"STAGE90_XNU_FRAME_CARRIER"') == 1
           and npy.count("STAGE90_XNU_FRAME_CARRIER") == 1     # the member (the comment says RUNG 1039)
           and npy.count("}") == npy.count("{"),
           "registration: the python allow list gains the switch, the set stays closed")
    nobj = {}
    exec(compile(npy, "<py>", "exec"), nobj)
    expect(SWITCH in nobj["TRAP_ALLOWED_IF_IDENTIFIERS"] and "STAGE90_XNU_TRAP_FRAME" in
           nobj["TRAP_ALLOWED_IF_IDENTIFIERS"], "registration: the edited list still parses")
    npy2, st2 = register_into(npy, "tools/patch_d13_ustack_probe.py")
    expect(st2 == "present" and npy2 == npy, "registration: idempotent")
    # a set that never carried 1037's switch (1035's shape: comment runs into the brace) still takes it
    py35 = ('TRAP_ALLOWED_IF_IDENTIFIERS = {\n    "A",\n    "STAGE90_XNU_PC_CARRIER",         # 1035\n}\n')
    npy35, st35 = register_into(py35, "tools/patch_d13_pc_carrier.py")
    o35 = {}
    exec(compile(npy35, "<py>", "exec"), o35)
    expect(st35 == "added" and SWITCH in o35["TRAP_ALLOWED_IF_IDENTIFIERS"]
           and o35["TRAP_ALLOWED_IF_IDENTIFIERS"] == {"A", "STAGE90_XNU_PC_CARRIER", SWITCH},
           "registration: a set without 1037's switch is edited too (no silent ABSENT)")
    noset, stn = register_into("x = 1\n", "tools/patch_d13_nobody.py")
    expect(stn == "ABSENT" and noset == "x = 1\n", "registration: a file with no set is reported ABSENT")
    bsh = BUILD_ANCHOR + "[[ ${NEXT:-0} -eq 1 ]] && DEFINES+=(-DNEXT=1)\n"
    nbsh, st3 = register_into(bsh, BUILD_REL)
    expect(st3 == "added" and BUILD_READER in nbsh and nbsh.index(BUILD_READER) > nbsh.index(BUILD_ANCHOR)
           and nbsh.endswith("[[ ${NEXT:-0} -eq 1 ]] && DEFINES+=(-DNEXT=1)\n"),
           "registration: the DEFINES reader goes right after 1038's, nothing else moves")

    if fails:
        print("SELFTEST FAIL: " + " | ".join(fails), file=sys.stderr)
        return 1
    print("SELFTEST PASS")
    return 0


def main(argv):
    if "--selftest" in argv:
        return selftest()
    # --register reads the flag directly; for the staging modes the flag must NOT be taken as the root
    do_apply = "--apply" in argv
    argv = [a for a in argv if a != "--apply"]
    if "--register" in argv:
        ok, report = register(do_apply=do_apply)
        for rel, st in report:
            print("   %-48s %s" % (rel, st))
        if not ok:
            print("patch_d13_frame_carrier: REGISTRATION INCOMPLETE - %s lacks an anchor for the switch "
                  "and it is not present. Nothing is hidden: see the statuses above." % SWITCH,
                  file=sys.stderr)
            return 1
        print("patch_d13_frame_carrier: registration %s on every patcher and the build."
              % ("APPLIED" if do_apply else "PLANNED (pass --apply)"))
        return 0
    if len(argv) < 1:
        print("usage: patch_d13_frame_carrier.py <xnu_root> [--apply|--verify-off] [--off-check PRE] | --selftest | "
              "--register [--apply]", file=sys.stderr)
        return 2
    xnu = argv[0]
    if "--restage" in argv:
        tp = trap_path(xnu)
        if not os.path.isfile(tp):
            print("patch_d13_frame_carrier: --restage: no %s" % tp, file=sys.stderr)
            return 1
        # --restage means: write the text this build stages -- the staging in place when the tree already
        # carries it, the pre-1039 text otherwise -- then stage() ONCE (it validates what it writes).
        t = read(tp)
        if TRAP_BLOCK in t:                 # OUR block stands (with or without 1037's close after it):
            nt = t                          # stage() stages the block in place / re-splices it
        else:
            nt, why = off_text(t)           # a draft: folded out first
        if nt is None:
            if TRAP_BLOCK not in t:
                nt = t                      # the pre-1039 text: stage() writes the block into it
            else:
                print("patch_d13_frame_carrier: --restage: REFUSE - %s. Writing nothing." % why,
                      file=sys.stderr)
                return 1
        if not do_apply:
            print("patch_d13_frame_carrier: --restage: plan OK (fold our block out, then stage; pass "
                  "--apply to write).")
            return 0
        write(tp, nt)
        print("   trap.c : --restage: text to stage (%d bytes -> %d)" % (len(t), len(nt)))
        return stage(xnu, True)
    if "--verify-off" in argv:
        return verify_off(xnu)
    if "--off-check" in argv:
        return off_check(xnu, argv[argv.index("--off-check") + 1])
    return stage(xnu, do_apply)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
