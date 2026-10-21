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
    xnu_live_fb_uss_ptr_eq / _ctx_diff_self / _mask_kind   (1039: is the uss side a SECOND witness?)

WHERE THE USS SIDE IS READ FROM (1039).  1037's device run (records/1037-read.txt RUNG READING 1) showed
_uss_ok=0 and every _uss_r*_ok=0: `arm_ctx` was NOT a kernel VA, so the block never read the record, the
mask compared zeros with themselves and fb_ctx_diff==0 was a tautology.  The VA the trap entry loaded is
`thread->machine.uss` (traps_lo.s:421 `ldr sp,[sp,TH_PCB_USS]`, TH_PCB_USS = offsetof(thread_t,
machine.uss), arm/genassym.c:230).  So the uss side is now the 16-word array AT *(unsigned*)&thread->
machine.uss -- i.e. thread->machine.uss->.<the word arm_ctx->.<word> would be> -- and is read through
thread->task's map (map == thread->map, trap.c:822) with the same guarded idiom.  arm_ctx supplies only
the ADDRESS the record is read at (_fb_uss) and the operand of `_fb_uss_armctx_diff`, an address check;
it is no longer the source of any compared word.  Starting from thread->machine.uss is not an
assumption about where arm_ctx points: if arm_ctx IS thread->machine.uss the mask is a SELF-COMPARISON
again and says so -- _uss_ptr_eq=1 and _ctx_diff_self=1, and _mask_kind prints 1 (1 = self-comparison,
0 = content comparison against a distinct uss VA), which tools/check_1037_capture.py turns into D2-EMPTY.
    xnu_live_fb_slide                                       (arm_ctx->pc - 0x37C26474u, an expression)
    xnu_live_fb_lr_xor4 / _lr_xor8 + _ok each               (device word ^ file word at (lr - slide) - 4/-8)
    xnu_live_fb_ldrh / _ldrh_ok                             (halfword at 0x37C26474 + slide via the task map)
    (the halfword is the one the Thumb pc points AT: select by (VA & 3) < 2, not (VA & 2) -- the old
     test swapped halves for VA%4==1, so the walk's 0x...475 showed 0x7C09 by accident)
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
    + I + " * VA as `context`.  The uss side is read at (1) arm_ctx as an ADDRESS gated on (2)\n"
    + I + " * vm_map_lookup_entry(thread->task's map) and the words START from (3) thread->machine.uss\n"
    + I + " * (traps_lo.s:421, TH_PCB_USS) and compare with (4) arm_ctx word for word (mask bits; if the VA\n"
    + I + " * equals arm_ctx it is a SELF-comparison and _ctx_diff_self/_mask_kind say so), derive the slide\n"
    + I + " * from pc as an expression, xor lr's\n"
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
    + I + "\t\t/* TH_PCB_USS (arm/genassym.c:230): the VA traps_lo.s:421 loaded into sp before the stmea */\n"
    + I + "\t\tunsigned _fb_usth = *(unsigned *)(void *)&thread->machine.uss;\n"
    + I + "\t\tunsigned _fb_off = (unsigned)__builtin_offsetof(arm_saved_state_t, r[0]);\n"
    + I + "\t\tvm_map_t _fb_tmap = thread->task ? get_task_map(thread->task) : kernel_map;\n"
    + I + "\t\tunsigned _fb_self = (_fb_uss == _fb_usth) ? 1U : 0U;\n"
    + I + "\t\tunsigned _fb_slide = _fb_pc - 0x37C26474u;      /* EXPRESSION, as pre-registered */\n"
    + I + "\t\tunsigned _fb_a[22];\n"
    + I + "\t\tuint32_t _fb_w[22];\n"
    + I + "\t\tuint32_t _fb_u[17];\n"
    + I + "\t\tboolean_t _fb_ok[22];\n"
    + I + "\t\tboolean_t _fb_uok[17];\n"
    + I + "\t\tunsigned _fb_sp_now, _fb_diff = 0U, _fb_ldrh = 0U;\n"
    + I + "\t\tboolean_t _help = FALSE;\n"
    + I + "\t\tvm_map_entry_t _fb_e;\n"
    + I + "\t\tunsigned _fb_i;\n"
    + I + "\t\t__asm__(\"mov %0, sp\" : \"=r\" (_fb_sp_now));\n"
    + I + "\t\t/* 0..15 at arm_ctx, the address the trap entry passed.  THE DISCRIMINATOR IS THE 1035 IDIOM\n"
    + I + "\t\t * ITSELF: a non-kernel VA fails vm_map_lookup_entry(thread->task's map) or copyin and reads\n"
    + I + "\t\t * _ok=0.  (No `_fb_uss & 0xf0000000U` test: on this kernel a task's map is a KERNEL submap,\n"
    + I + "\t\t * so task VAs carry the 0xc... tag too and that test would gate nothing.) */\n"
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
    + I + "\t\t/* 0..16: the SECOND witness -- (3) thread->machine.uss's record, word k at\n"
    + I + "\t\t * _fb_usth + _fb_off + 4*k (the byte offsets arm_saved_state_t gives r0/sp/lr/pc), in\n"
    + I + "\t\t * THREAD->TASK's map, same guard.  No #if/#ifdef here (this block's shape is checked). */\n"
    + I + "\t\tfor (_fb_i = 0; _fb_i < 17U; _fb_i++) {\n"
    + I + "\t\t\tunsigned _fb_m = (_fb_usth + _fb_off + 4U * _fb_i) & ~3U;\n"
    + I + "\t\t\t_fb_u[_fb_i] = 0U;\n"
    + I + "\t\t\t_fb_uok[_fb_i] = FALSE;\n"
    + I + "\t\t\tif (_fb_usth >= 4U && _fb_m >= _fb_usth && _fb_m <= 0xfffffffcU &&\n"
    + I + "\t\t\t    vm_map_lookup_entry(_fb_tmap, _fb_m, &_fb_e)) {\n"
    + I + "\t\t\t\t_fb_uok[_fb_i] = (copyin((user_addr_t)(uintptr_t)_fb_m,\n"
    + I + "\t\t\t\t    (char *)&_fb_u[_fb_i], 4) == 0);\n"
    + I + "\t\t\t}\n"
    + I + "\t\t}\n"
    + I + "\t\t/* the mask.  (4) arm_ctx word vs (3) the uss word; a word compared only when the\n"
    + I + "\t\t * uss read landed.  With distinct VAs and every uss read landing, _ctx_diff_self=0 and\n"
    + I + "\t\t * the mask is a real comparison: bit i = the i-th saved word differs between the two\n"
    + I + "\t\t * readers of the record.  Otherwise _ctx_diff_self=1 and _mask_kind=1. */\n"
    + I + "\t\tfor (_fb_i = 0; _fb_i < 16U; _fb_i++) {\n"
    + I + "\t\t\tunsigned _fb_c = (_fb_i < 13U) ? (unsigned)arm_ctx->r[_fb_i]\n"
    + I + "\t\t\t    : (_fb_i == 13U) ? (unsigned)arm_ctx->sp\n"
    + I + "\t\t\t    : (_fb_i == 14U) ? (unsigned)arm_ctx->lr : (unsigned)arm_ctx->pc;\n"
    + I + "\t\t\tif (_fb_uok[_fb_i] && _fb_u[_fb_i] != _fb_c) {\n"
    + I + "\t\t\t\t_fb_diff |= (1U << _fb_i);\n"
    + I + "\t\t\t}\n"
    + I + "\t\t}\n"
    + I + "\t\tif (!(_fb_self == 0U && _fb_uok[0] && _fb_uok[1] && _fb_uok[2] && _fb_uok[3] &&\n"
    + I + "\t\t      _fb_uok[4] && _fb_uok[5] && _fb_uok[6] && _fb_uok[7] && _fb_uok[8] &&\n"
    + I + "\t\t      _fb_uok[9] && _fb_uok[10] && _fb_uok[11] && _fb_uok[12] && _fb_uok[13] &&\n"
    + I + "\t\t      _fb_uok[14] && _fb_uok[15])) {\n"
    + I + "\t\t\t_fb_diff = 0U;\n"
    + I + "\t\t}\n"
    + I + "\t\t/* the halfword from the word read at _fb_a[20] (bit-1 select) */\n"
    + I + "\t\t_help = _fb_ok[20];\n"
    + I + "\t\tif (_help) {\n"
    # (bit 1 SET => the halfword is at +2 in the word => the HIGH half.  A bit test, not
    #  `(VA & 3) < 2` -- that spelling picked the HIGH half for the walk page 0x...474, where the
    #  Thumb pc points at the LOW one 0x7C09 (2026-10-19, 1039's static read).)
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
    + I + "\t\t    (unsigned)(_fb_uss ^ _fb_usth));\n"
    + I + "\t\tprintf(\"xnu_live_fb_uss_ptr_eq=%d\\n\", (int)_fb_self);\n"
    + I + "\t\tprintf(\"xnu_live_fb_ctx_diff_self=%d\\n\",\n"
    + I + "\t\t    (int)((_fb_self == 0U && _fb_uok[0] && _fb_uok[1] && _fb_uok[2] && _fb_uok[3] &&\n"
    + I + "\t\t      _fb_uok[4] && _fb_uok[5] && _fb_uok[6] && _fb_uok[7] && _fb_uok[8] &&\n"
    + I + "\t\t      _fb_uok[9] && _fb_uok[10] && _fb_uok[11] && _fb_uok[12] && _fb_uok[13] &&\n"
    + I + "\t\t      _fb_uok[14] && _fb_uok[15]) ? 0 : 1));\n"
    + I + "\t\tprintf(\"xnu_live_fb_mask_kind=%d\\n\",\n"
    + I + "\t\t    (int)((_fb_self == 0U && _fb_uok[0] && _fb_uok[1] && _fb_uok[2] && _fb_uok[3] &&\n"
    + I + "\t\t      _fb_uok[4] && _fb_uok[5] && _fb_uok[6] && _fb_uok[7] && _fb_uok[8] &&\n"
    + I + "\t\t      _fb_uok[9] && _fb_uok[10] && _fb_uok[11] && _fb_uok[12] && _fb_uok[13] &&\n"
    + I + "\t\t      _fb_uok[14] && _fb_uok[15]) ? 0 : 1));\n"
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
     "xnu_live_fb_uss_armctx_diff=", "xnu_live_fb_uss_ptr_eq=", "xnu_live_fb_ctx_diff_self=",
     "xnu_live_fb_mask_kind=", "xnu_live_fb_ctx_diff=", "xnu_live_fb_slide=",
     "xnu_live_fb_lr_xor4=", "xnu_live_fb_lr_xor4_ok=", "xnu_live_fb_lr_xor8=", "xnu_live_fb_lr_xor8_ok=",
     "xnu_live_fb_ldrh=", "xnu_live_fb_ldrh_ok=", "xnu_live_fb_dbg_off=", "xnu_live_fb_dbg_off_ok=")
    + tuple("xnu_live_fb_uss_%s=" % n for n in _USS_ROWS)
    + tuple("xnu_live_fb_uss_%s_ok=" % n for n in _USS_ROWS)
)

# trap.c's `#if` identifiers are the union of what ALL the patchers put there.
TRAP_ALLOWED_IF_IDENTIFIERS = {
    "WATCH_LE_H_STANDIN",           # 1038 (its hook's stand-in guard)
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
    # "already staged" is the EDITED TEXT (directive ids), not a substring: 1039's block pastes the
    # switch's own spelling into its text (a staged-call teaching example), and the substring test then
    # answered "already staged" over a tree still carrying the PRE-1037 anchor -- --restage refused,
    # 1037's edit never ran, and the pool folded three stale closes `#endif /* TRAP_FRAME */` above
    # 1039's block (measured 2026-10-19).
    if SWITCH in if_stage90_ids(t):
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


# trap_restage: scripts re-stage later rungs INTO a trap.c that still carries 1037's block (build_1038.sh
# `_stage tools/patch_d13_trap_frame.py --apply` is a no-op there).  This replaces the text between 1037's
# own pair with TRAP_BLOCK, which is the same edit the later rung made, and adds/removes nothing else:
# with the null-body form check_trap returns the same verdict as `already staged` (passes).
def restage(xnu):
    ok_t, tp, t, msg = check_trap(xnu)
    if not ok_t or msg != "already staged":
        print("patch_d13_trap_frame: RESTAGE refused - %s. Writing nothing." % msg, file=sys.stderr)
        return 1
    # 1037's staged text opens the switch twice (rites/save INDENTED at the top of its region, then the
    # edit's own COLUMN-0 opener after 1036's close): 1039's rows are inside the edit's opener, so that
    # one is the head.  It is the FIRST column-0 `#if` of this switch (2026-10-19: 1039's carrier
    # stages a column-0 `#if defined(stage sw) && sw` INSIDE 1037's block -- inside 1025's arm -- so
    # `^#if` also matches the carrier's; the edit's head is the one 1037's text writes first).
    head = "#if defined(%s) && %s\n" % (SWITCH, SWITCH)
    tail = "#endif /* %s */\n" % SWITCH
    _all = [m.start() for m in re.finditer("(?m)^" + re.escape(head), t)]
    # (@: an END: the anchor's byte is the newline BEFORE 1036's close; with an OFFSET the head's own
    # start was filtered out and --restage refused on every tree, 2026-10-19 19:1x.)
    g = t.find(chr(10) + "@#endif /* STAGE90_XNU_PC_CARRIER_CALLER */" + chr(10), 0)
    opens = [o for o in _all if g < 0 or o < g]
    s = opens[0] if opens else -1
    # The edit's close is the LAST one after the head.  Measured 2026-10-19 16:52: this function, taking
    # the FIRST, closed 1037's switch at either 1039's opener or at 1037's own first inner close (1037's
    # staged text opens the switch TWICE - rites/save, parent line - and closes it ONCE), so the nest
    # unwound and 1039's block fell OUTSIDE 1025's block.  The refresher is for a reshaped BODY; close(s)
    # the refreshed text does not write are refused, never removed.
    # (1039's rows are pasted INSIDE the edit's opener but AFTER the switch's first close -- rites/save's
    # inner one; on this tree the edit's close is the LAST column-0 close of the switch)
    # (16:52's -1: `chr(10) + tail` asked for a line where the tail IS the line start -- the search
    # could only ever find the NEXT line's ending, so every restage refused.  The edit's close is the
    # LAST tail, and its start is s + the head's line.)
    # (a TAB-indented tail is the switch's real close on trees whose staged text is column-0-indented --
    # work5's arm closes at column 0 once and at one TAB before 1025's close; measured 2026-10-19.)
    _cl = [m.start() for m in re.finditer("(?m)^" + re.escape(tail), t)]
    _cl += [m.start() + 1 for m in re.finditer("(?m)^" + re.escape(chr(9) + tail), t)]
    _cl = [c for c in _cl if s < c and (g < 0 or c > g)]
    _cl = sorted(_cl)
    # the LAST tail is the one 1025's close follows (with a carrier's close in front of it once 1039 has
    # staged): a close mid-arm -- rites/save's inner one -- is not this switch's close.  Nothing to scan
    # here: the block's own head is the same text, so `@` is never a boundary on this tree.
    _at = t.find("\n@#endif /* STAGE90_XNU_PC_CARRIER_CALLER */")
    _cl = [c for c in _cl if _at < 0 or c > _at]
    e = _cl[-1] if (s >= 0 and _cl) else -1
    if e < 0:
        print("patch_d13_trap_frame: RESTAGE refused - no close for this switch after the head. "
              "Writing nothing.", file=sys.stderr)
        return 1
    # a nested run this rung's text does not write (a 1039 carrier inside the block, closed by its own
    # indented `#endif /* ... */`): refused, never removed -- and found by its OPENING lines, not by the
    # body's close count (a nested run's `#endif` is not this switch's tail).
    _body_cur = t[s + len(head):e]
    _nest = [l.strip() for l in _body_cur.split(chr(10))
             if re.match(r"#if ", l) and l.strip() + chr(10) not in TRAP_BLOCK]
    if _nest:
        print("patch_d13_trap_frame: RESTAGE refused - the block's body carries %d nested opener(s) this "
              "rung's text does not write (a nested rung owns them); a refresh would delete the nest. "
              "Writing nothing: %s" % (len(_nest), ", ".join(_nest[:3])), file=sys.stderr)
        return 1
    cur = t[s:e + len(tail)]
    with open(tp, "w") as f:
        f.write(t[:s] + TRAP_BLOCK + t[e + len(tail):])
    print("   trap.c : RESTAGED 1037's block in place (%d -> %d bytes; the switch's own pair kept as the "
          "block's head and tail, nothing else touched)." % (len(cur), len(TRAP_BLOCK)))
    return 0


def _block_shape(t, s):
    """The shape 1033's structural scan (evf_closes_inside_1025) accepts, checked by VALUE:
    at `s` a column-0 `#if defined(SW) && SW`, SW being one of THIS edit's names; after it, before
    the first other STAGE90 rung's directive line, one line-wise `#endif /* SW */` (the body may
    carry C's own `#if`/`#endif` and any comment that merely SPELLS `#if defined(STAGE90_`); 1037's
    close line follows.  Returns SW or None.
    (python `re` with a tempered `(?!#if defined\\()(?!...)` loop, run through re.match at `s` over
    the whole text, stops 172 lines short on the 1039 tree and rejects both correct forms -- a
    regex-engine fact, not a tree fact; measured [[mi4-measurement-defects]].  Hence by value.)"""
    m = re.compile(r"#if defined\(([A-Z0-9_]+)\) && \1\n").match(t, s)
    if not m or m.group(1) not in (SWITCH, "STAGE90_XNU_FRAME_CARRIER"):
        return None
    sw = m.group(1)
    close = "#endif /* %s */\n" % sw
    # the block's own C code may carry `#if`/`#endif`; a STAGE90 directive line is the first one
    # that is neither our switch's close (the line is the close, nothing else) nor a nested 1039
    # carrier block's inner close (a `#endif /* STAGE90_XNU_FRAME_CARRIER */` line)
    pos = m.end()
    while True:
        k = t.find(close, pos)
        if k < 0:
            return None
        ls = t.rfind(chr(10), 0, k) + 1
        nl = t.find(chr(10), k + len(close))
        if t[ls:k].strip() == "" and not (
                t[k + len(close):nl].strip() == "STAGE90_XNU_FRAME_CARRIER"):
            return sw
        pos = k + len(close)


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
    # 1039 stages its carrier between this block's close and 1025's USTACK close, so neither the
    # "immediately" facts nor xnu_live_fb_pc='s line can be required at 1039 ([[mi4-one-file-many-rungs]]);
    # the row is counted inside the block below like every other.  1037's staged text opens this switch
    # TWICE (rites/save and the parent line) and closes it once: the pair the edit added is one `#if`
    # and one `#endif` of this name - not equal counts.
    head = "#if defined(%s) && %s\n" % (SWITCH, SWITCH)
    have = head in t and ("#endif /* %s */\n" % SWITCH) in t
    # 1039 stages its carrier between 1037's close and 1025's USTACK close, so with 1039 at 1 the
    # USTACK close after 1037's is no longer the NEXT line ([[mi4-one-file-many-rungs]]).  What is
    # checked is the same fact: this block is the last thing before 1025's close.
    tail = re.search(r"#endif /\* %s \*/\n(?:\t?#endif /\* STAGE90_XNU_[A-Z0-9_]+ \*/\n)*\t?#endif /\* "
                     r"STAGE90_XNU_USTACK_PROBE \*/\n" % SWITCH, t) is not None
    # every emitted row is INSIDE the gated block (so OFF removes it, not just the switch name)
    s = t.find("#if defined(%s) && %s" % (SWITCH, SWITCH))
    e = t.find("#endif /* %s */" % SWITCH)
    inside = t[s:e] if (s >= 0 and e > s) else ""
    missing = [r for r in FB_ROWS if (r not in inside)]
    # the block shape 1033's structural scan (evf_closes_inside_1025) accepts: `#if defined(SW) && SW`
    # opening and `#endif /* SW */` closing, no OTHER STAGE90 rung's directive inside it.  A nested
    # `#if BOARD_CONFIG_*` C pair is 1037's own text (the arm's per-board guards); 1039's tree also
    # carries 1038's row side (no rung of its own inside 1037's).
    # 1039's block stands between 1037's close and 1025's, OUTSIDE our switch (a sibling, not a leak):
    # 1037's switch closes right before it opens, and 1037's own close line follows it (that line is not
    # part of this pattern: the match ends at our switch's close).
    # (the tempered-regex version is retired: see _block_shape's docstring.)
    shape = s >= 0 and _block_shape(t, s) == SWITCH
    print("   trap.c [ON] : one #if/#endif pair for the switch: %s" % have)
    print("   trap.c      : it closes immediately before 1025's #endif: %s" % tail)
    print("   trap.c      : all %d rows inside the gated block: %s"
          % (len(FB_ROWS), "yes" if not missing else "NO: %s" % ", ".join(missing)))
    print("   trap.c      : whole-block shape `#if defined(SW) && SW .. #endif /* SW */`: %s"
          % ("yes" if shape else "NO"))
    if have and tail and not missing and shape:
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
    # 22 named rows + 17 value rows + 17 ok rows
    expect(len(FB_ROWS) == 33 + 21, "row count is 33 value rows + 21 _ok rows")
    expect("#include" not in inside and not re.search(r"^\s*#", inside, re.M),
           "no directive inside the block (OFF cannot change trap.c's directive namespace)")
    # 1039's spec, by value on the emitted text (not on this file's own comments):
    src = "\n".join(l[5:] if l.startswith(I) else l for l in inside.splitlines())
    expect("unsigned _fb_uss = (unsigned)(uintptr_t)arm_ctx;" in src
           and "unsigned _fb_usth = *(unsigned *)(void *)&thread->machine.uss;" in src,
           "the uss side starts at thread->machine.uss; arm_ctx is the address read at")
    mask = src[src.find("/* the mask."):src.find("/* the halfword")]
    expect("_fb_u[_fb_i] != _fb_c" in mask and "_fb_uok[_fb_i]" in mask and "_fb_w[" not in mask
           and "copyin" not in mask,
           "the mask compares arm_ctx with the thread->machine.uss reads, gated on their _ok")
    expect(src.count("_fb_self == 0U") == 3
           and all("printf(\"xnu_live_fb_%s=%%d" % n in src for n in ("mask_kind", "ctx_diff_self", "uss_ptr_eq")),
           "_mask_kind / _ctx_diff_self / _uss_ptr_eq all print, all on `_fb_self == 0U and all 16 _ok`")
    expect("_fb_diff = 0U;" in src and src.find("_fb_diff = 0U;") > mask.find("_fb_uok[_fb_i]"),
           "a mask that is not a content comparison is zeroed before it is printed")
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

    # 1039: --restage replaces a previously staged 1037 block in place (build_1038.sh re-stages into a
    # trap.c that still carries 1037's block; `--apply` there is a no-op).  The staged source keeps a
    # text AFTER 1025's #endif: anchor, like build_1038.sh, and a text of 1039's AFTER 1037's block.
    base8 = base.replace("}\n#endif /* STAGE90_XNU_USTACK_PROBE */\n",
                         "}\n\t#endif /* STAGE90_XNU_USTACK_PROBE */\nTAIL_1038_TEXT 0;\n")
    r6 = tree("stale_1037", base8)
    stage(r6, do_apply=True)
    t6 = read(trap_path(r6))
    # the stale block is a 2-line `#if`/`#endif` pair where 1037's staged block was
    _h = "#if defined(STAGE90_XNU_TRAP_FRAME) && STAGE90_XNU_TRAP_FRAME\n"
    _e = "#endif /* STAGE90_XNU_TRAP_FRAME */\n"
    _lo, _hi = t6.find(_h), t6.rfind(_e)   # the text's LAST close is the edit's (16:52)
    _body = _h + "\t\t\t\t\t{ int _fb_old = 0; }\n" + _e
    stale = t6[:_lo] + _body + t6[_hi + len(_e):]
    # positions INSIDE stale (the block's length changed, so t6's offsets do not carry over)
    stale_lo, stale_end = stale.find(_body), stale.rfind(_body) + len(_body)
    write(trap_path(r6), stale)
    ok6, _, _, msg6 = check_trap(r6)
    expect(ok6 and msg6 == "already staged", "a stale 1037 block still reads as `already staged`")
    rc6 = stage(r6, do_apply=True)
    expect(rc6 == 0 and read(trap_path(r6)) == stale, "stage --apply cannot refresh it (the defect 1039 fixes)")
    want6 = stale[:stale_lo] + TRAP_BLOCK + stale[stale_end:]
    expect(restage(r6) == 0 and read(trap_path(r6)) == want6
           and read(trap_path(r6)).count("\"xnu_live_fb_mask_kind=%d") == 1,
           "--restage replaces exactly 1037's pair with TRAP_BLOCK and changes nothing else")
    # a later rung (1039) inserted its block after 1037's close; the refreshed block must carry only
    # 1037's text, never the later rung's.
    later = "#if defined(STAGE90_XNU_LATER_LATER_RUNG) && STAGE90_XNU_LATER_LATER_RUNG\n" \
        "\t\t\t\t\tprintf(\"xnu_live_later_seq=%u\\n\", 0U);\n" \
        "#endif /* STAGE90_XNU_LATER_LATER_RUNG */\n"
    after = "#endif /* STAGE90_XNU_TRAP_FRAME */\n"
    r6b = tree("stale_1039_with_later", base8)
    _k = "TAIL_1038_TEXT"     # build_1038.sh's text after 1025's #endif: where the later rung's block goes
    _a = stale.find(_k)
    write(trap_path(r6b), stale[:_a] + later + stale[_a:])
    _t = want6.find(_k)                             # the same place in the refreshed text
    expect(restage(r6b) == 0 and read(trap_path(r6b)) == want6[:_t] + later + want6[_t:],
           "--restage refreshes 1037's body and leaves a later sibling block untouched")
    r7 = tree("nothing_staged", base)
    before7 = read(trap_path(r7))
    expect(restage(r7) != 0 and read(trap_path(r7)) == before7,
           "--restage REFUSES on a tree with no staged 1037 block (never stages afresh)")
    expect(restage("./no/such/tree") != 0, "--restage on a missing tree refuses")

    if fails:
        print("SELFTEST FAIL: " + " | ".join(fails), file=sys.stderr)
        return 1
    print("SELFTEST PASS (23 checks: plan/apply/idempotent/bracket/namespace/OFF-can-fail/structural/"
          "uss-side/restage)")
    return 0


def main(argv):
    if "--selftest" in argv:
        return selftest()
    if len(argv) < 2:
        print("usage: patch_d13_trap_frame.py <xnu_root> [--apply|--verify-off] [--selftest]",
              file=sys.stderr)
        return 2
    xnu = argv[1]
    if "--restage" in argv:
        return restage(xnu)
    if "--verify-off" in argv:
        return verify_off(xnu)
    return stage(xnu, do_apply="--apply" in argv)


if __name__ == "__main__":
    sys.exit(main(sys.argv))