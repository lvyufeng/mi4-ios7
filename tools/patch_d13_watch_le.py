#!/usr/bin/env python3
"""1038 -- THE FOREIGN CODE ON THE STACK (A) AND LITTLE ENDIAN AT THE TABLE (B).  INSTRUMENT ONLY.

Source: docs/1038-design.md sections 1-2; records/1037-read.txt A-C (the 1036 capture).  ONE rung, TWO
trap.c edits, ONE switch STAGE90_XNU_WATCH_LE (the reg lane's name; the design's per-block switches
STAGE90_XNU_STACK_WATCH / STAGE90_XNU_LE_READ are not created -- two blocks in one file are one rung,
[[mi4-one-file-many-rungs]]):

  1  BLOCK SITE -- inside 1025's failure arm, immediately after 1037's
     `#endif /* STAGE90_XNU_TRAP_FRAME */` (so before 1025's own `#endif`).  Arm A and arm B.
  2  HOOK SITE  -- osfmk/arm/trap.c, top of `sleh_abort` (trap.c:510), the hook's `#if` opening ON the
     anchor's last line: HOOK_ANCHOR is five lines ending `    thread_t thread = current_thread();`
     (the sleh_abort preamble trap.c:524-528).  The same FIVE lines open `sleh_undef` too
     (trap.c:536-540); the only difference is its 17-line IOS7LEO_DYLD `#if` block between
     `leo_instruction_error` and the preamble, and NO text on either side distinguishes them -- the bare
     `thread_t thread = current_thread();` line matches THREE times (sleh_abort 528, sleh_undef 540,
     sleh_fatal_exception ~1925).  This tree is accepted as staged by --verify-off only on 1054's
     per-symbol selector ([[mi4-a-fixed-string-cannot-say-which-function]]); until then the accepted
     tree is position-blind between sleh_abort and sleh_undef (both arms reach launchctl[2]).

ROWS (names exact; docstring rows carry their gate, see GATES):
    A  xnu_live_sweq_seq / _pid / _ssid                     (current_thread()->thread_id, 0x%08x)
       xnu_live_sweq_sp / _usp / _k                         sp = arm_ctx->sp; usp = thread->machine.hu_usp
                                                            (the PCB's saved user sp); k = sp - usp
       xnu_live_sweq_s0 .. _s15 (+ _ok each)                the 16 words at sp-4 .. sp+0x3c, TASK-MAP reads
       xnu_live_sweq_bp0 .. _bp3 (+ _ok each)               32 bytes at the VALUE of s3
       xnu_live_sweq_wpc / _wfp / _w_ok                     the WALK'S pc, through the saved-r11 chain
       xnu_live_sweq_swb_slot / _far / _pc / _ok / _tag    the hook's slot for THIS thread: the last
       xnu_live_sweq_swb_m40 / _m40_ok / _swb_ge              user-mode data abort's (saved user r3,
                                                              FAR), _ok = tag is this thread_id; the
                                                              word at far-0x40 = pc-0x40, _ge = it
                                                              equals far (A1's conjunct)
       xnu_live_sweq_tdfar / _tdpc / _td_ok                 ALIASES of swb_far/_pc/_ok (same slot read)
    B  xnu_live_ler_seq / _pid / _r3
       xnu_live_ler_cnt_w / _cnt_w_ok                       [r3+0xc] -- SEE (iii): 0 + _ok=0 BY CONSTRUCTION
       xnu_live_ler_cnt_b / _cnt_b_ok                       the same 4 bytes, byte at a time, assembled LE
       xnu_live_ler_al0 / _al0_ok                           [r3]       the `bx pc` (or first word)
       xnu_live_ler_mfp1 / _mfp1_ok                         [r3+0x1c] -- UNWRITTEN (slot 3 is named, not
                                                            read: printed as 0 + _ok=0 BY CONSTRUCTION)
       xnu_live_ler_mfp2 / _mfp2_ok                         [r3+0x2c]
       xnu_live_ler_ppc / _ppc_ok                           text at pc-0x40 (task-map word)
       xnu_live_ler_le / _le_ok                             the same text, byte reads, assembled LE
    L  xnu_live_wlg_byte  1 / 0 / 2   one 1-byte copyin at the walk's page start (0x37C26474+slide),
                                      at its last byte, and at sp-4; 1 = the first succeeded, 0 = it
                                      returned EFAULT, 2 = not in the task map (not attempted)
       xnu_live_wlg_lev   0 / 1 / 2   0: no function-boundary level found; 1: a `pop {pc}` word was found
                                      (allowing arm B at the higher levels too); 2: found, arm B only
       xnu_live_wlg_need_<A/B row>    1 << gate id, for every row (0 = an unguarded task-map word read)

THE THREE LOADERS BLOCK B USES (each EXISTS in this kernel):
  1  BYTE through the task map: copyin(addr, &b, 1).  bcopyinout.s `copyin` (:47) sends r0 >= 0x80000000
     to copyio_kernel and otherwise stores `.Lcopyin_fault` in TH_RECOVER and tails into `.Lcopyin_guts`,
     whose unaligned-source loop is `ldrbt ip,[r0],#0x01` (:96-101); a miss returns EFAULT.  Unprivileged
     .user, it nevertheless passes through the kernel's "is this user address valid at the fault" check
     because copyin ARMS TH_RECOVER -- which is exactly why its own gate exists (wlg_byte, gate 6).
     There is NO `copyin_word` / `in_byte` symbol in this tree (`grep copyin_word` over osfmk/ and bsd/
     hits only an asm label).
  2  `ldrb` on a KERNEL pointer: *(volatile uint8_t *)(uintptr_t)a.  Used for r3 in the kernel half
     (a >= 0x80000000 is a kernel page by this tree's PMAP scheme) and for the stack chain (gate 1).
  3  `ldr` on a KERNEL pointer: *(volatile uint32_t *)(uintptr_t)(a & ~3), then its bytes.  Used ONLY
     for the `pop {pc}` pop-follow (a kernel stack address; gate 1).  cf. `_evf_ma[4]`/kprintf in this
     same file, which read lr-4 / pc-4 raw and do not fault.
  cnt_w and ppc are the CONTROL (the kernel's own word read of the same bytes through the task map);
  cnt_b and le are the byte-at-a-time LE assembly.  Neither cnt_b nor le sits on a kernel word load.

(i) THE FUNCTION BOUNDARY -- so A1's `far == *(pc-0x40)` is evaluated at the WALK's pc, not at an
    arbitrary sp+0xc.  A1's conjunct needs `*(pc-0x40)`; the stack's only guaranteed function pointer is
    a saved r11, and A1's own mode (the ucontext says the pc was inside a callee, so pc is NOT the walk)
    says the walk's pc is up the chain.  bp0 = s3's value = a saved r11.  ARM frames push {r4,r7,r11,lr}
    and pop pc at:
        bark v7: push {r4,r7,r11,lr}                                    pop {pc}  -> a + 0x10
        bark v8: push {r4,r7,r11,lr}; sub sp,sp,#k                       pop {r4,r7,r11,pc} -> a + 4k + 0x10
    fp = bp0; walk up while 0x0 < fp < 0x80000000 (30 levels); at each level read fp[1] with loader 2:
    a LE ldrd'ed value |v| < 0x1000000 (0x399a1474 and every library VA) IS the fp's return word; a
    |v| >= 0x00400000 is `pop {pc}` (the |v| is not used, how we got there is the answer); else a BYTE
    read of (fp+4) & ~3 selecting bytes 0..3 -> |v| - 1.  A GCC v7 index >= 0xc0 is the BYTE encoding
    (bits 7:5 = 101) and would give +0x10.  The FIRST level whose return VA `r` lies in the FAULTING
    PAGE, or within 0x1000 BELOW it, under one 1 MiB section (the walk's skid), names wpc = r, wfp = fp.
    If no level matches, wpc = 0, _w_ok = 0: the design's rule is NOT evaluable on this path.

(ii) THE PRECEDING FAULT (swb_*, td* is its alias): the hook in sleh_abort records, for the SLOT's owner
    only, (saved user r3, arm_ctx->far).  The saved user r3 is read at [r1 - 4] where r1 = TH_PCB_ISS
    (USS + 4) -- true only on traps_lo.s's USER entries, which reach sleh_abort by `blx` with r1 intact;
    the kernel copyin entry uses `bl`, so there r1 is a PBX/PBZ and _wl_ss_slot returns 0 (nothing is
    recorded).  The slot's owner is the first user-mode data abort's thread (16 buckets, thread_id & 0xf,
    claimed by CAS-like tag store); the hook runs only when arm_ctx->r[3] == thread_id | 0x80000000, i.e.
    when the kernel arm handed r3 the ownership word -- never on the hook's own recording pass (it does
    not write r3), so the (r3, far) pair it stores is the NEXT abort of the same thread.  far is
    arm_ctx->far of the 7-argument context (+0x18): what the arm itself uses at trap.c:561.  swb_ok = 1
    only if the slot's tag is this thread_id and re-reads equal; the block prints far and far-0x40, never
    a neighbour's fault as a reading.  swb_pc = far - 0x40 is the A1 mode's pc (the faulting FAR inside
    the walk's table read); swb_ge = the word AT far-0x40 equals far.
    r3 IS NOT THE SAME IN THE TWO ARMS: the hook's arm_ctx->r[3] is the fault's register (user r3 -- the
    table base -- on a USER entry), the block's arm_ctx->r[3] is the kernel copyin arm's.  No row equates
    them; the block prints its own as ler_r3 and the hook its saved user r3 as swb_* (indirectly).

(iii) cnt_w IS 0 / _ok=0 BY CONSTRUCTION.  On this tree the 32-bit armv7 usermode data abort takes
    SLEH_ABORT_TYPE_DATA_ABORT in the else-arm (trap.c: `if ((cpsr & 0x1f) == 0x10) {...} else { ml_set_
    interrupts_enabled(TRUE); return; }`) -- vm_fault aborts before 1025's publisher.  1025's failure
    arm runs only because TRAP.c's KERNEL arm (reason 4: data_abort_crash_in_kernel) brings a kernel
    copyin fault here, and then `map` is thread->map while r3 / sp are the KERNEL's.  So a task-map read
    of [r3+0xc] / sp / the walk's page cannot be a read of user memory except by accident.  The block
    still attempts each one under its guard; the gates (wlg_byte, wlg_lev) are how the host reader
    knows whether the row it was given is a reading or a miss.

ONE-SHOT PER THREAD: the static `_wl_seqlock`, bit0 = armed, bits 31:1 = thread_id & 0x7fffffff; the
block runs only when bit0 is set and the bits name THIS thread.  `_wl_ss_slot` claims the bucket
(thread_id & 0xf) on the FIRST user-mode data abort and returns that thread's saved user r3 for every
later abort whose [r1-4] still reads it (a different thread_id or bucket: 0, no reading).  The slot
writer stores tag then words (release); the block's loads are acquire.  __atomic_* builtins are the 1026/1029
idiom here (clang, -mcpu=cortex-a15, -marm).

GUARDED READS, no lock on the failing path: every TASK-MAP read is `a >= 4 && (a & ~3) <= 0xfffffffc &&
vm_map_lookup_entry(map, a & ~3, &e) && copyin(...) == 0`; a read not attempted, or copyin failing,
prints 0 / _ok=0.  vm_map_lookup_entry (vm_map.c:1177 -> vm_map_store_lookup_entry) takes NO lock and
writes NOTHING on this tree's map store (no LEASE field) -- the 1026/1027/1029-1037 idiom.

SITE / SHARED NAMESPACE ([[mi4-one-file-many-rungs]]): trap.c is edited by 994/1020/1025/1026+1027/1029/
1030/1031/1033/1035/1036/1037 and now 1038.  Every trap.c patcher's ALLOWED_IF_IDENTIFIERS carries
STAGE90_XNU_WATCH_LE; this script edits every patcher's allow list AND tools/build_xnu_arm_kernel.sh
(self-registration, one run), and REFUSES, writing nothing, if any of them lacks the switch.  With the
switch undefined both edits vanish and the tree is the 1037 tree's bytes (`--verify-off`).

Block C (the first 64 KiB, docs/1038-design.md 3) is NOT here: a 0x10000-byte scan does not fit this
one-shot publisher, and on this tree it would read KERNEL memory at pc-slide (see (iii)).  docs/1038-
design.md; records/1037-read.txt.
"""
import os
import re
import sys

SWITCH = "STAGE90_XNU_WATCH_LE"

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TRAP_REL = "osfmk/arm/trap.c"
BUILD_REL = "tools/build_xnu_arm_kernel.sh"
BUILD_READER = "DEFINES+=(-DSTAGE90_XNU_WATCH_LE=1)"

TRAP_ANCHOR = ("#endif /* STAGE90_XNU_TRAP_FRAME */\n"
               "#endif /* STAGE90_XNU_USTACK_PROBE */\n")

# sleh_abort's own line, leading spaces included: trap.c's OTHER copy is indented with a TAB (in
# `other()`) and must not match.  The caret search line-breaks around the name (a literal `thread_t
# thread = current_thread();` closes immediately before `\n` here and the compiler folds it).
# ([[mi4-one-value-two-definitions]]: a one-character anchor difference is a different anchor)
_CT = "current" + "_thread()" + ";"
_ANCHOR_BODY = "thread_t thread = " + _CT
HOOK_ANCHOR = ("    uint32_t dfsr = 0, dfar = 0, ifsr = 0, ifar = 0, cpsr, exception_type =\n"
               "        0, exception_subcode = 0;\n"
               "    abort_information_context_t *arm_ctx =\n"
               "        (abort_information_context_t *) context;\n"
               "    " + _ANCHOR_BODY + "\n")

TRAP_DONE_MARK = "xnu_live_wlg_need_s0="
HOOK_DONE_MARK = "_wl_i = (unsigned)(thread->thread_id & 0xfU);"      # the hook's own first body line
# the hook's first line after HOOK_ANCHOR: the ONLY place in trap.c where this switch's `#if` follows the
# anchor (the block site has 1037's `#endif` before it)
HOOK_OPEN = "#if defined(STAGE90_XNU_WATCH_LE) && STAGE90_XNU_WATCH_LE\n"

QUOTE = "\x22"      # a row's name is matched as  <QUOTE><name>=  in the block's text
I = "\t\t\t\t\t"   # the indent of every block in 1025's arm

SWEQ_ROWS = ("seq", "pid", "ssid", "sp", "usp", "k", "tdfar", "tdpc", "td_ok",
             "wpc", "wfp", "w_ok") \
    + tuple("s%d" % k for k in range(16)) + tuple("s%d_ok" % k for k in range(16)) \
    + tuple("bp%d" % k for k in range(4)) + tuple("bp%d_ok" % k for k in range(4))

# row, gate id (0 = plain guarded task-map word read)
LETTER_ROWS = (("seq", 0), ("pid", 0), ("r3", 0),
               ("cnt_w", 0), ("cnt_w_ok", 0), ("cnt_b", 0), ("cnt_b_ok", 0),
               ("al0", 2), ("al0_ok", 2), ("mfp1", 3), ("mfp1_ok", 3),
               ("mfp2", 3), ("mfp2_ok", 3), ("ppc", 0), ("ppc_ok", 0),
               ("le", 7), ("le_ok", 7),
               ("lr_cnt", 0), ("lr_mfp1", 0), ("lr_mfp2", 0), ("lr_ppc", 0))

# gate id -> what the host reader must see for the rows that need it (printed by --gates)
GATES = (
    (0, "plain task-map word read (guard + copyin)"),
    (1, "((xnu_live_sweq_usp | xnu_live_sweq_sp) & 7) == 0"),
    (2, "(xnu_live_ler_al0 & 0xffffff7f) == 0xe12fff1c"),
    (3, "(((xnu_live_ler_r3 ^ xnu_live_sweq_sp) | (xnu_live_ler_r3 ^ xnu_live_sweq_usp)) & 0xfff00000) == 0"),
    (4, "xnu_live_sweq_bp0_ok == 1 && 0 < xnu_live_sweq_bp0 < 0x80000000"),
    (5, "xnu_live_wlg_lev > 0 && 0x80000000 <= xnu_live_sweq_wpc <= 0xfffeffff"),
    (6, "unused (the ppc word is the plain task-map read, gate 0)"),
    (7, "xnu_live_wlg_byte == 1"),
    (8, "xnu_live_wlg_byte == 1 && xnu_live_wlg_lev >= 1"),
    (9, "xnu_live_wlg_byte == 1 && xnu_live_wlg_lev >= 2"),
)

SWEQ_GATE = (("seq", 0), ("pid", 0), ("ssid", 0), ("sp", 0), ("usp", 1), ("k", 1),
             ("tdfar", 0), ("tdpc", 0), ("td_ok", 0), ("wpc", 5), ("wfp", 5), ("w_ok", 5)) \
    + tuple(("s%d" % k, 1) for k in range(16)) + tuple(("s%d_ok" % k, 1) for k in range(16)) \
    + (("bp0", 4), ("bp0_ok", 4)) \
    + tuple(("bp%d" % k, 4) for k in range(1, 4)) + tuple(("bp%d_ok" % k, 4) for k in range(1, 4))

GATE_ROWS = ("xnu_live_wlg_byte=", "xnu_live_wlg_lev=") \
    + tuple("xnu_live_wlg_need_%s=" % r for r, _ in SWEQ_GATE if r not in ("seq", "pid")) \
    + tuple("xnu_live_wlg_need_%s=" % r for r, _ in LETTER_ROWS if r not in ("seq", "pid")) \
    + tuple("xnu_live_wlr_%s=" % r for r in ("cnt", "mfp1", "mfp2", "ppc"))
# (`seq` and `pid` are emitted by BOTH arms; their gate row is the A arm's, the one with an index)

TRAP_BLOCK = (
    "#endif /* STAGE90_XNU_TRAP_FRAME */\n"
    "#if defined(STAGE90_XNU_WATCH_LE) && STAGE90_XNU_WATCH_LE\n"
    + I + "/* 1038: THE FOREIGN CODE ON THE STACK (A) AND LITTLE ENDIAN AT THE TABLE (B).  INSTRUMENT\n"
    + I + " * ONLY -- no fix.  A reads sp-4..sp+0x3c, follows s3 to its 32 bytes, names the walk's pc\n"
    + I + " * through the saved-r11 chain; B reads [r3], [r3+0xc], [r3+0x1c], [r3+0x2c] and pc-0x40\n"
    + I + " * byte at a time and assembles them LITTLE-endian, beside the kernel's own control word.\n"
    + I + " * Every task-map read is guarded (vm_map_lookup_entry + copyin); a miss prints 0 / _ok=0;\n"
    + I + " * a kernel-pointer ldr only where a < 0x80000000.  ONE-SHOT PER THREAD (_wl_seqlock),\n"
    + I + " * armed by the hook in sleh_abort.  Every row names its gate (xnu_live_wlg_need_*).\n"
    + I + " * pid 2 only, failing path only.  READ ONLY, no lock.  docs/1038-design.md 1-2. */\n"
    + I + "if ((int)(thread->task->bsd_info ? proc_pid(thread->task->bsd_info) : -1) == 2) {\n"

    + I + "\tunsigned _wl_s = __atomic_load_n(&_wl_owned, __ATOMIC_ACQUIRE);\n"
    + I + "\t/* bit0 = a DATA fault was recorded; bits 12:1 = its slot (ring index + 1); upper bits = 0 */\n"
    + I + "\tif ((_wl_s & 1U) && (_wl_s < 0x2000U)) {\n"
    + I + "\t\tunsigned _wl_pc = (unsigned)arm_ctx->pc;\n"
    + I + "\t\tunsigned _wl_sp = (unsigned)arm_ctx->sp;\n"
    + I + "\t\tunsigned _wl_usp = (unsigned)(thread->machine.hu_usp);\n"
    + I + "\t\tunsigned _wl_r3 = (unsigned)arm_ctx->r[3];\n"
    + I + "\t\tunsigned _wl_wpb = _wl_pc;          /* THE WALK'S PAGE (1035 pcc row: pc 0x37C26474 + slide) */\n"
    + I + "\t\tunsigned _wl_b;                     /* bp0 = the VALUE of s3, set after the s rows */\n"
    + I + "\t\tunsigned _wl_gb = 2U, _wl_gl = 0U, _wl_wpc = 0U, _wl_wfp = 0U;\n"
    + I + "\t\tunsigned _wl_le = 0U, _wl_i, _wl_n;\n"
    + I + "\t\tunsigned _wl_wln[6];                /* the four named B addresses, printed raw */\n"
    + I + "\t\tuint32_t _wl_sv[16];\n"
    + I + "\t\tuint32_t _wl_bw[4];\n"
    + I + "\t\t/* slots: 0 cnt_w (kernel word), 1 cnt_b (byte LE), 2 al0 ([r3]), 3 UNUSED, 4 mfp2\n"
    + I + "\t\t * ([r3+0x2c]), 5 le, 6 ppc (pc-0x40).  (4 and 6 were ONE slot: ppc read back mfp2.) */\n"
    + I + "\t\tuint32_t _wl_lt[7];\n"
    + I + "\t\tboolean_t _wl_so[16], _wl_bo[4], _wl_lo[7];\n"
    + I + "\t\tunsigned _wl_na[16], _wl_nb[4], _wl_lb[7];\n"
    + I + "\t\tvm_map_entry_t _wl_e;\n"
    + I + "\t\t/* ===== A: THE STACK WATCH (first: it reads before this arm's own copyins) ===== */\n"
    + I + "\t\t/* the 16 words at sp-4 .. sp+0x3c (the 1037 pcc2 window was r7-0x40..r7-0x04) */\n"
    + I + "\t\tfor (_wl_i = 0; _wl_i < 16U; _wl_i++) {\n"
    + I + "\t\t\t_wl_na[_wl_i] = _wl_sp - 4U + 4U * _wl_i;\n"
    + I + "\t\t}\n"
    + I + "\t\tfor (_wl_i = 0; _wl_i < 16U; _wl_i++) {\n"
    + I + "\t\t\t_wl_sv[_wl_i] = 0U; _wl_so[_wl_i] = FALSE;\n"
    + I + "\t\t\tif (_wl_na[_wl_i] >= 4U && (_wl_na[_wl_i] & ~3U) <= 0xfffffffcU &&\n"
    + I + "\t\t\t    vm_map_lookup_entry(map, _wl_na[_wl_i] & ~3U, &_wl_e) &&\n"
    + I + "\t\t\t    copyin((user_addr_t)(uintptr_t)(_wl_na[_wl_i] & ~3U), (char *)&_wl_sv[_wl_i], 4) == 0) {\n"
    + I + "\t\t\t\t_wl_so[_wl_i] = TRUE;\n"
    + I + "\t\t\t}\n"
    + I + "\t\t}\n"
    + I + "\t\t_wl_b = _wl_sv[2];                  /* s3 = sp+0xc */\n"
    + I + "\t\t/* the 32 bytes at the VALUE of s3 */\n"
    + I + "\t\tfor (_wl_i = 0; _wl_i < 4U; _wl_i++) {\n"
    + I + "\t\t\t_wl_nb[_wl_i] = _wl_b + 4U * _wl_i;\n"
    + I + "\t\t}\n"
    + I + "\t\tfor (_wl_i = 0; _wl_i < 4U; _wl_i++) {\n"
    + I + "\t\t\t_wl_bw[_wl_i] = 0U; _wl_bo[_wl_i] = FALSE;\n"
    + I + "\t\t\tif (_wl_nb[_wl_i] >= 4U && (_wl_nb[_wl_i] & ~3U) <= 0xfffffffcU &&\n"
    + I + "\t\t\t    vm_map_lookup_entry(map, _wl_nb[_wl_i] & ~3U, &_wl_e) &&\n"
    + I + "\t\t\t    copyin((user_addr_t)(uintptr_t)(_wl_nb[_wl_i] & ~3U), (char *)&_wl_bw[_wl_i], 4) == 0) {\n"
    + I + "\t\t\t\t_wl_bo[_wl_i] = TRUE;\n"
    + I + "\t\t\t}\n"
    + I + "\t\t}\n"
    + I + "\t\t/* THE FUNCTION BOUNDARY: bp0 = saved r11 -> the walk's pc (docstring (i)) */\n"
    + I + "\t\tif (_wl_bo[0] && _wl_bw[0] >= 4U && _wl_bw[0] < 0x80000000U &&\n"
    + I + "\t\t    ((_wl_usp | _wl_sp) & 7U) == 0U) {\n"
    + I + "\t\t\tunsigned _wl_fp = _wl_bw[0];\n"
    + I + "\t\t\tfor (_wl_n = 0; _wl_n < 30U; _wl_n++) {\n"
    + I + "\t\t\t\tunsigned _wl_g = _wl_fp + 4U;\n"
    + I + "\t\t\t\tunsigned _wl_m = _wl_g & ~3U, _wl_off = _wl_g - _wl_m;\n"
    + I + "\t\t\t\tunsigned _wl_r;\n"
    + I + "\t\t\t\tuint32_t _wl_v = 0U;\n"
    + I + "\t\t\t\t/* loader 2: a KERNEL-pointer byte (the arm's ldrb) */\n"
    + I + "\t\t\t\tfor (_wl_i = 0; _wl_i < 4U; _wl_i++) {\n"
    + I + "\t\t\t\t\tif (_wl_off > _wl_i) {\n"
    + I + "\t\t\t\t\t\t_wl_v |= (uint32_t)*(volatile uint8_t *)(uintptr_t)(_wl_m + _wl_i)\n"
    + I + "\t\t\t\t\t\t    << (8U * _wl_i);\n"
    + I + "\t\t\t\t\t}\n"
    + I + "\t\t\t\t}\n"
    + I + "\t\t\t\tif (_wl_v < 0x1000000U) {\n"
    + I + "\t\t\t\t\t_wl_r = _wl_v;                          /* the fp's return word (LE ldrd) */\n"
    + I + "\t\t\t\t\t_wl_gl = 2U;\n"
    + I + "\t\t\t\t} else {\n"
    + I + "\t\t\t\t\t/* loader 3: a KERNEL-pointer word -- only when its bytes are `pop {pc}` /\n"
    + I + "\t\t\t\t\t * `pop {r4,r7,r11,pc}`; never for `push {r4,r7,sp,lr}` (0xe92d49b0). */\n"
    + I + "\t\t\t\t\t_wl_v = *(volatile uint32_t *)(uintptr_t)_wl_m;\n"
    + I + "\t\t\t\t\tif ((_wl_v & 0x7ffc0000U) != 0U) {\n"
    + I + "\t\t\t\t\t\t_wl_r = (_wl_v & 0x00400000U) ? 0x00010000U : 0x00080000U;\n"
    + I + "\t\t\t\t\t\tif (_wl_gl < 1U) { _wl_gl = 1U; }\n"
    + I + "\t\t\t\t\t} else {\n"
    + I + "\t\t\t\t\t\t_wl_r = 0x00020000U + _wl_off + 1U; /* byte B at (fp+4) & ~3: +4..+8 */\n"
    + I + "\t\t\t\t\t\t_wl_gl = 2U;\n"
    + I + "\t\t\t\t\t}\n"
    + I + "\t\t\t\t}\n"
    + I + "\t\t\t\tif (_wl_r >= _wl_pc && _wl_r - _wl_pc < 0x1000U &&\n"
    + I + "\t\t\t\t    ((_wl_r ^ _wl_pc) & 0xfff00000U) == 0U) {\n"
    + I + "\t\t\t\t\t_wl_wpc = _wl_r; _wl_wfp = _wl_fp;\n"
    + I + "\t\t\t\t\tbreak;\n"
    + I + "\t\t\t\t}\n"
    + I + "\t\t\t\t_wl_fp = *(volatile uint32_t *)(uintptr_t)_wl_fp;      /* the next saved r11 */\n"
    + I + "\t\t\t\tif (_wl_fp < 8U || _wl_fp >= 0x80000000U) { break; }\n"
    + I + "\t\t\t}\n"
    + I + "\t\t}\n"
    + I + "\t\t/* ===== A1's PAIR: the last USER-mode data-abort (far, pc) this thread saw, recorded by\n"
    + I + "\t\t * the hook in the slot SWSS_BLOCK below names.  far = the ARM's FAR (mrc c6,c0,0, the Instr\n"
    + I + "\t\t * FSR+'far' the 1035 evf rows are read from), NOT the 7-arg arm_ctx->far at +0x18.  _ok=1\n"
    + I + "\t\t * only if the slot's tag is THIS thread_id AND re-reads equal (a writer may have overtaken);\n"
    + I + "\t\t * a bucket collision then prints _ok=0, not a neighbour's fault as a reading. */\n"
    + I + "\t\t_wl_swb_ss = __atomic_load_n(&_wl_ssslot, __ATOMIC_ACQUIRE);\n"
    + I + "\t\tif (_wl_swb_ss >= 1U && _wl_swb_ss <= 16U &&\n"
    + I + "\t\t    __atomic_load_n(&_wl_ssslot, __ATOMIC_ACQUIRE) == _wl_swb_ss) {\n"
    + I + "\t\t\t_wl_swb_p = (_wl_swb_ss - 1U) * 2U;\n"
    + I + "\t\t\t_wl_swb_tag = __atomic_load_n(&_wl_swb[_wl_swb_p + 1U], __ATOMIC_ACQUIRE);\n"
    + I + "\t\t\tif (__atomic_load_n(&_wl_swb[_wl_swb_p + 1U], __ATOMIC_ACQUIRE) == _wl_swb_tag &&\n"
    + I + "\t\t\t    _wl_swb_tag == (unsigned)(thread->thread_id & 0xffffffffULL)) {\n"
    + I + "\t\t\t\t_wl_swb_far = _wl_swb[_wl_swb_p];\n"
    + I + "\t\t\t\t_wl_swb_pc = _wl_swb_far - 0x40U;\n"
    + I + "\t\t\t\t_wl_swb_ok = TRUE;\n"
    + I + "\t\t\t}\n"
    + I + "\t\t}\n"
    + I + "\t\t/* the word at pc-0x40 (A1's conjunct): 1-byte copyin in the task map (the B/PCI address is\n"
    + I + "\t\t * user memory in the kernel copyin arm) else, only for pc-0x40 in the kernel half, an ldrb\n"
    + I + "\t\t * loop -- the loader-2 case, gated on _wl_wlhalf */\n"
    + I + "\t\t_wl_wlhalf = (_wl_swb_pc & ~3U) >= 0x80000000U;\n"
    + I + "\t\tif (_wl_swb_ok && !_wl_wlhalf && (_wl_swb_pc & ~3U) >= 4U &&\n"
    + I + "\t\t    vm_map_lookup_entry(map, _wl_swb_pc & ~3U, &_wl_e)) {\n"
    + I + "\t\t\t_wl_swb_m40ok = (0 == copyin((user_addr_t)(uintptr_t)(_wl_swb_pc & ~3U),\n"
    + I + "\t\t\t    (char *)&_wl_swb_m40, 4));         /* compared: a miss -> _ok=0 */\n"
    + I + "\t\t} else if (_wl_swb_ok && _wl_wlhalf) {\n"
    + I + "\t\t\t_wl_swb_m40 = 0U;\n"
    + I + "\t\t\tfor (_wl_i = 0; _wl_i < 4U; _wl_i++) {\n"
    + I + "\t\t\t\t_wl_swb_m40 |= (uint32_t)*(volatile uint8_t *)(uintptr_t)((_wl_swb_pc & ~3U) + _wl_i)\n"
    + I + "\t\t\t\t    << (8U * _wl_i);\n"
    + I + "\t\t\t}\n"
    + I + "\t\t\t_wl_swb_m40ok = TRUE;\n"
    + I + "\t\t}\n"
    + I + "\t\t/* ===== THE GATES, MEASURED BEFORE THEY ARE USED ===== */\n"
    + I + "\t\t/* ONE 1-byte copyin at each of three expected-valid VAs: 1 = succeeded, 0 = EFAULT, 2 = not\n"
    + I + "\t\t * in the task map (not attempted).  THE FIRST is the walk's page, and it precedes every\n"
    + I + "\t\t * word read at that page (and at every page, when the first one is the one answered). */\n"
    + I + "\t\t{\n"
    + I + "\t\t\tunsigned _wl_ga[3];\n"
    + I + "\t\t\tuint8_t _wl_c = 0U;\n"
    + I + "\t\t\t_wl_ga[0] = _wl_wpb;\n"
    + I + "\t\t\t_wl_ga[1] = _wl_wpb + 0xfffU;\n"
    + I + "\t\t\t_wl_ga[2] = _wl_sp - 4U;\n"
    + I + "\t\t\t_wl_gb = 2U;\n"
    + I + "\t\t\tfor (_wl_i = 0; _wl_i < 3U; _wl_i++) {\n"
    + I + "\t\t\t\t_wl_c = 0U;\n"
    + I + "\t\t\t\tif (_wl_ga[_wl_i] <= 0xfffffffeU && vm_map_lookup_entry(map, _wl_ga[_wl_i], &_wl_e)) {\n"
    + I + "\t\t\t\t\t_wl_gb = (copyin((user_addr_t)(uintptr_t)_wl_ga[_wl_i], (char *)&_wl_c, 1) == 0)\n"
    + I + "\t\t\t\t\t    ? 1U : 0U;\n"
    + I + "\t\t\t\t\tbreak;\n"
    + I + "\t\t\t\t}\n"
    + I + "\t\t\t}\n"
    + I + "\t\t}\n"
    + I + "\t\t/* ===== B: LITTLE ENDIAN AT THE TABLE ===== */\n"
    + I + "\t\t_wl_lb[0] = _wl_r3;                     /* al0  */\n"
    + I + "\t\t_wl_lb[1] = _wl_r3 + 0xcU;              /* cnt  */\n"
    + I + "\t\t_wl_lb[2] = _wl_r3 + 0x1cU;             /* NOT read (a raw word is not a cell) */\n"
    + I + "\t\t_wl_lb[3] = _wl_r3 + 0x2cU;             /* NOT read: _wl_lt[4] is the mfp2 cell */\n"
    + I + "\t\t_wl_lb[4] = _wl_ppca & ~3U;             /* ppc  */\n"
    + I + "\t\t_wl_lb[5] = _wl_ppca & ~3U;             /* le   */\n"
    + I + "\t\t_wl_lb[6] = _wl_ppca & ~3U;             /* ppc  (same VA as le, read as a WORD) */\n"
    + I + "\t\t_wl_wln[0] = _wl_lb[1]; _wl_wln[1] = _wl_lb[2];\n"
    + I + "\t\t_wl_wln[2] = _wl_lb[3]; _wl_wln[3] = _wl_lb[4];\n"
    + I + "\t\tfor (_wl_i = 0; _wl_i < 7U; _wl_i++) {\n"
    + I + "\t\t\t_wl_lt[_wl_i] = 0U; _wl_lo[_wl_i] = FALSE;\n"
    + I + "\t\t}\n"
    + I + "\t\t/* loader 1: byte through the task map -- the BYTES FIRST for the two LE assemblies */\n"
    + I + "\t\tif (_wl_gb == 1U) {\n"
    + I + "\t\t\tfor (_wl_i = 0; _wl_i < 4U; _wl_i++) {\n"
    + I + "\t\t\t\tuint8_t _wl_x = 0U;\n"
    + I + "\t\t\t\tif (copyin((user_addr_t)(uintptr_t)(_wl_lb[5] + _wl_i), (char *)&_wl_x, 1) != 0) {\n"
    + I + "\t\t\t\t\tbreak;\n"
    + I + "\t\t\t\t}\n"
    + I + "\t\t\t\t_wl_le |= (uint32_t)_wl_x << (8U * _wl_i);\n"
    + I + "\t\t\t\tif (_wl_i == 3U) { _wl_lo[5] = TRUE; }\n"
    + I + "\t\t\t}\n"
    + I + "\t\t}\n"
    + I + "\t\tif (_wl_gb == 1U) {\n"
    + I + "\t\t\tfor (_wl_i = 0; _wl_i < 4U; _wl_i++) {\n"
    + I + "\t\t\t\tuint8_t _wl_x = 0U;\n"
    + I + "\t\t\t\tif (copyin((user_addr_t)(uintptr_t)(_wl_lb[1] + _wl_i), (char *)&_wl_x, 1) != 0) {\n"
    + I + "\t\t\t\t\tbreak;\n"
    + I + "\t\t\t\t}\n"
    + I + "\t\t\t\t_wl_lt[1] |= (uint32_t)_wl_x << (8U * _wl_i);\n"
    + I + "\t\t\t\tif (_wl_i == 3U) { _wl_lo[1] = TRUE; }\n"
    + I + "\t\t\t}\n"
    + I + "\t\t} else if (_wl_gb == 0U && _wl_r3 >= 0x80000000U) {\n"
    + I + "\t\t\t/* NOT the gate-answered page: loader 2, ldrb on a kernel pointer.  Only for r3 in\n"
    + I + "\t\t\t * the kernel half -- by this tree's PMAP scheme a VA >= 0x80000000 is a kernel page,\n"
    + I + "\t\t\t * the split _evf_ma[4] / kprintf(pc-4) / stage90_abt_thread_l1_base depend on. */\n"
    + I + "\t\t\tfor (_wl_i = 0; _wl_i < 4U; _wl_i++) {\n"
    + I + "\t\t\t\t_wl_lt[1] |= (uint32_t)*(volatile uint8_t *)(uintptr_t)(_wl_lb[1] + _wl_i)\n"
    + I + "\t\t\t\t    << (8U * _wl_i);\n"
    + I + "\t\t\t}\n"
    + I + "\t\t\t_wl_lo[1] = TRUE;\n"
    + I + "\t\t}\n"
    + I + "\t\t/* the CONTROL: the kernel's own word read of the same four bytes, through the task map */\n"
    + I + "\t\tif (_wl_r3 < 0x80000000U && vm_map_lookup_entry(map, _wl_lb[1] & ~3U, &_wl_e) &&\n"
    + I + "\t\t    copyin((user_addr_t)(uintptr_t)(_wl_lb[1] & ~3U), (char *)&_wl_lt[0], 4) == 0) {\n"
    + I + "\t\t\t_wl_lo[0] = TRUE;\n"
    + I + "\t\t}\n"
    + I + "\t\t/* ppc: the kernel's word at pc-0x40, through the task map (slot 6, own slot) */\n"
    + I + "\t\tif (_wl_r3 < 0x80000000U &&\n"
    + I + "\t\t    vm_map_lookup_entry(map, _wl_lb[6] & ~3U, &_wl_e) &&\n"
    + I + "\t\t    copyin((user_addr_t)(uintptr_t)(_wl_lb[6] & ~3U), (char *)&_wl_lt[6], 4) == 0) {\n"
    + I + "\t\t\t_wl_lo[6] = TRUE;\n"
    + I + "\t\t}\n"
    + I + "\t\tfor (_wl_i = 0; _wl_i < 7U; _wl_i++) {\n"
    + I + "\t\t\t/* read: 2 al0 ([r3]) and 4 (the mfp2 cell, [r3+0x2c]); skipped: 0 cnt_w (its\n"
    + I + "\t\t\t * control read is above), 1 cnt_b / 5 le (byte reads above), 3 (the wlr_mfp1 VA is\n"
    + I + "\t\t\t * printed as an ADDRESS, not read), 6 ppc (own read below) */\n"
    + I + "\t\t\tif (_wl_i != 2U && _wl_i != 4U) { continue; }\n"
    + I + "\t\t\tif (_wl_lb[_wl_i] >= 4U && (_wl_lb[_wl_i] & ~3U) <= 0xfffffffcU &&\n"
    + I + "\t\t\t    vm_map_lookup_entry(map, _wl_lb[_wl_i] & ~3U, &_wl_e) &&\n"
    + I + "\t\t\t    copyin((user_addr_t)(uintptr_t)(_wl_lb[_wl_i] & ~3U), (char *)&_wl_lt[_wl_i], 4) == 0) {\n"
    + I + "\t\t\t\t_wl_lo[_wl_i] = TRUE;\n"
    + I + "\t\t\t}\n"
    + I + "\t\t}\n"
    + I + "\t\t/* ===== THE ROWS ===== */\n"
    + I + "\t\tprintf(\"xnu_live_sweq_seq=%u\\n\", (unsigned)((_wl_s >> 1) & 0x7fffffffU));\n"
    + I + "\t\tprintf(\"xnu_live_sweq_pid=%d\\n\", (int)proc_pid(thread->task->bsd_info));\n"
    + I + "\t\tprintf(\"xnu_live_sweq_ssid=0x%08x\\n\", (unsigned)(uint32_t)thread->thread_id);\n"
    + I + "\t\tprintf(\"xnu_live_sweq_sp=0x%08x\\n\", _wl_sp);\n"
    + I + "\t\tprintf(\"xnu_live_sweq_usp=0x%08x\\n\", _wl_usp);\n"
    + I + "\t\tprintf(\"xnu_live_sweq_k=0x%08x\\n\", (unsigned)(_wl_sp - _wl_usp));\n"
    + I + "\t\tprintf(\"xnu_live_sweq_tdfar=0x%08x\\n\", (unsigned)_wl_swb_far);\n"
    + I + "\t\tprintf(\"xnu_live_sweq_tdpc=0x%08x\\n\", (unsigned)_wl_swb_pc);\n"
    + I + "\t\tprintf(\"xnu_live_sweq_td_ok=%d\\n\", (int)(_wl_swb_ok ? 1 : 0));\n"
    + I + "\t\tprintf(\"xnu_live_sweq_swb_slot=%u\\n\", _wl_swb_ss);\n"
    + I + "\t\tprintf(\"xnu_live_sweq_swb_far=0x%08x\\n\", (unsigned)_wl_swb_far);\n"
    + I + "\t\tprintf(\"xnu_live_sweq_swb_pc=0x%08x\\n\", (unsigned)_wl_swb_pc);\n"
    + I + "\t\tprintf(\"xnu_live_sweq_swb_ok=%d\\n\", (int)(_wl_swb_ok ? 1 : 0));\n"
    + I + "\t\tprintf(\"xnu_live_sweq_swb_tag=0x%08x\\n\", _wl_swb_tag);\n"
    + I + "\t\tprintf(\"xnu_live_sweq_swb_m40=0x%08x\\n\", (unsigned)_wl_swb_m40);\n"
    + I + "\t\tprintf(\"xnu_live_sweq_swb_m40_ok=%d\\n\", (int)(_wl_swb_m40ok ? 1 : 0));\n"
    + I + "\t\tprintf(\"xnu_live_sweq_swb_ge=%d\\n\", (int)((_wl_swb_m40ok && _wl_swb_m40 == _wl_swb_far)\n"
    + I + "\t\t    ? 1 : 0));\n"
    + I + "\t\tprintf(\"xnu_live_sweq_wpc=0x%08x\\n\", _wl_wpc);\n"
    + I + "\t\tprintf(\"xnu_live_sweq_wfp=0x%08x\\n\", _wl_wfp);\n"
    + I + "\t\tprintf(\"xnu_live_sweq_w_ok=%d\\n\", (int)(_wl_wpc != 0U ? 1 : 0));\n"
    + "".join(
        I + "\t\tprintf(\"xnu_live_sweq_%s=0x%%08x\\n\", (unsigned)_wl_sv[%d]);\n" % (n, k)
        + I + "\t\tprintf(\"xnu_live_sweq_%s_ok=%%d\\n\", (int)(_wl_so[%d] ? 1 : 0));\n" % (n, k)
        for k, n in enumerate("s%d" % k for k in range(16)))
    + "".join(
        I + "\t\tprintf(\"xnu_live_sweq_%s=0x%%08x\\n\", (unsigned)_wl_bw[%d]);\n" % (n, k)
        + I + "\t\tprintf(\"xnu_live_sweq_%s_ok=%%d\\n\", (int)(_wl_bo[%d] ? 1 : 0));\n" % (n, k)
        for k, n in enumerate("bp%d" % k for k in range(4)))
    + I + "\t\tprintf(\"xnu_live_ler_seq=%u\\n\", (unsigned)((_wl_s >> 1) & 0x7fffffffU));\n"
    + I + "\t\tprintf(\"xnu_live_ler_pid=%d\\n\", (int)proc_pid(thread->task->bsd_info));\n"
    + I + "\t\tprintf(\"xnu_live_ler_r3=0x%08x\\n\", _wl_r3);\n"
    + I + "\t\tprintf(\"xnu_live_ler_cnt_w=0x%08x\\n\", (unsigned)_wl_lt[0]);\n"
    + I + "\t\tprintf(\"xnu_live_ler_cnt_w_ok=%d\\n\", (int)(_wl_lo[0] ? 1 : 0));\n"
    + I + "\t\tprintf(\"xnu_live_wlr_cnt=0x%08x\\n\", _wl_wln[0]);\n"
    + I + "\t\tprintf(\"xnu_live_ler_cnt_b=0x%08x\\n\", (unsigned)_wl_lt[1]);\n"
    + I + "\t\tprintf(\"xnu_live_ler_cnt_b_ok=%d\\n\", (int)(_wl_lo[1] ? 1 : 0));\n"
    + I + "\t\tprintf(\"xnu_live_ler_al0=0x%08x\\n\", (unsigned)_wl_lt[2]);\n"
    + I + "\t\tprintf(\"xnu_live_ler_al0_ok=%d\\n\", (int)(_wl_lo[2] ? 1 : 0));\n"
    + I + "\t\tprintf(\"xnu_live_ler_mfp1=0x%08x\\n\", (unsigned)_wl_lt[3]);\n"
    + I + "\t\tprintf(\"xnu_live_ler_mfp1_ok=%d\\n\", (int)(_wl_lo[3] ? 1 : 0));\n"
    + I + "\t\tprintf(\"xnu_live_wlr_mfp1=0x%08x\\n\", _wl_wln[1]);\n"
    + I + "\t\tprintf(\"xnu_live_ler_mfp2=0x%08x\\n\", (unsigned)_wl_lt[4]);\n"
    + I + "\t\tprintf(\"xnu_live_ler_mfp2_ok=%d\\n\", (int)(_wl_lo[4] ? 1 : 0));\n"
    + I + "\t\tprintf(\"xnu_live_wlr_mfp2=0x%08x\\n\", _wl_wln[2]);\n"
    + I + "\t\tprintf(\"xnu_live_ler_ppc=0x%08x\\n\", (unsigned)_wl_lt[6]);     /* task-map word at pc-0x40 */\n"
    + I + "\t\tprintf(\"xnu_live_ler_ppc_ok=%d\\n\", (int)(_wl_lo[6] ? 1 : 0));\n"
    + I + "\t\tprintf(\"xnu_live_wlr_ppc=0x%08x\\n\", _wl_wln[3]);\n"
    + I + "\t\tprintf(\"xnu_live_ler_le=0x%08x\\n\", _wl_le);\n"
    + I + "\t\tprintf(\"xnu_live_ler_le_ok=%d\\n\", (int)(_wl_lo[5] ? 1 : 0));\n"
    + I + "\t\tprintf(\"xnu_live_wlg_byte=%u\\n\", _wl_gb);\n"
    + I + "\t\tprintf(\"xnu_live_wlg_lev=%u\\n\", _wl_gl);\n"
    + "".join(
        I + "\t\tprintf(\"xnu_live_wlg_need_%s=%%u\\n\", (unsigned)(1U << %d));\n" % (r, g)
        for r, g in SWEQ_GATE if r not in ("seq", "pid"))
    + "".join(
        I + "\t\tprintf(\"xnu_live_wlg_need_%s=%%u\\n\", (unsigned)(1U << %d));\n" % (r, g)
        for r, g in LETTER_ROWS if r not in ("seq", "pid"))
    + I + "\t}\n"
    + I + "}\n"
    "#endif /* STAGE90_XNU_WATCH_LE */\n"
    "#endif /* STAGE90_XNU_USTACK_PROBE */\n"
    "#if defined(STAGE90_XNU_WATCH_LE) && STAGE90_XNU_WATCH_LE\n"
    "/* 1038's SLOT WRITER (tools/patch_d13_watch_le.py; called by the HOOK in sleh_abort, and only from\n"
    " * there -- a kernel TEXT symbol, so the block below reaches the same statics).  traps_lo.s's USER\n"
    " * entry does LoadThreadRegister(r1) + `ldr sp, [r1, TH_PCB_ISS]` then `blx _sleh_abort` with r1\n"
    " * intact: r1 here = TH_PCB_ISS = USS + 4 (machine_thread: iss, uss, uvfp, user_regs), s3 = word\n"
    " * [r1 - 4] = the SAVED USER r3 (the table base the walk used).  The kernel copyin entry uses `bl`\n"
    " * (r1 clobbered), so there r1 < 8 or holds no TH_PCB_ISS and this returns 0.  Sixteen buckets=thread_id & 0xf,\n"
    " * entries [far, tag]; a collision replaces the tag so the block prints _ok=0, never a neighbour's\n"
    " * fault as a reading. */\n"
    "/* 1038's FAULT SLOT (tools/patch_d13_watch_le.py; written by the HOOK in sleh_abort, read by the\n"
    " * BLOCK).  Both are in the kernel arm, so the file-scope statics are the SAME objects.  The slot is\n"
    " * THE FAULT'S OWN CONTEXT (abort_information_context_t, misc_protos.h: r[13], sp, lr, pc, cpsr, fsr,\n"
    " * far) read at the hook's entry -- NOT a register or a derived address.  The USER data-abort entry\n"
    " * (traps_lo.s data_abort_crash_in_usermode) saves lr as the faulting pc (lr - 8) and fills the context\n"
    " * on the user stack under SVC (which pre-aborts as a user-mode abort, so the app's lr is untouched);\n"
    " * the KERNEL entry (data_abort_crash_in_kernel) reaches here by `bl` with the SAME context shape.\n"
    " * Every record is armed: pc != 0 && user-mode cpsr && lr in the user half; far may be 0 (the kernel\n"
    " * entry never writes +0x48 -- the app lr is at +0x3c), which the block marks ok=0.  Slots are ring\n"
    " * positions (pid2 builds alternate USER/KERNEL in practice), tag = prolog<<16 | lr>>20; 64 entries\n"
    " * of the 19 context words (far at [2i+18]). */\n"
    "static unsigned _wl_fs[64U * 19U];\n"
    "static unsigned _wl_fi[2];\n"
    "static unsigned _wl_ss_slot(unsigned *ctx)   /* returns ring index, 0 = not recorded */\n"
    "{\n"
    "\tunsigned _wl_i, _wl_j, _wl_ss, _wl_n;\n"
    "\tif (!ctx || !ctx[15] || (ctx[16] & 0x1fU) != 0x10U || ctx[14] < 0x80000000U ||\n"
    "\t    (ctx[14] & 3U) || !ctx[13] || ctx[18] < 0x80000000U) { return 0U; }   /* ARM mode */\n"
    "\t_wl_ss = __atomic_load_n(&_wl_fi[0], __ATOMIC_ACQUIRE);\n"
    "\tif (_wl_ss < 64U) { _wl_j = _wl_ss; }\n"
    "\telse { _wl_j = (__atomic_load_n(&_wl_fi[1], __ATOMIC_ACQUIRE) - 1U) & 63U; }\n"
    "\t__atomic_store_n(&_wl_fs[19U * _wl_j], (ctx[14] & 0x000fffffU) << 12, __ATOMIC_RELEASE);   /* prolog */\n"
    "\tfor (_wl_i = 0; _wl_i < 19U; _wl_i++) {\n"
    "\t\t__atomic_store_n(&_wl_fs[19U * _wl_j + _wl_i], ctx[_wl_i], __ATOMIC_RELEASE);\n"
    "\t}\n"
    "\tif (_wl_ss < 64U) {\n"
    "\t\t__atomic_store_n(&_wl_fi[0], _wl_ss + 1U, __ATOMIC_RELEASE);\n"
    "\t} else {\n"
    "\t\t_wl_n = __atomic_load_n(&_wl_fi[1], __ATOMIC_ACQUIRE) + 1U;\n"
    "\t\t__atomic_store_n(&_wl_fi[1], _wl_n, __ATOMIC_RELEASE);\n"
    "\t}\n"
    "\treturn _wl_j + 1U;\n"
    "}\n"
"#endif /* STAGE90_XNU_WATCH_LE */\n"
)

HOOK_BLOCK = (
    # the anchor's five lines, verbatim, so the edit is idempotent ("already staged" is checked on the
    # switch first, but a re-run of the SPLICE without that check must not stack a second hook) ...
    HOOK_ANCHOR
    # ... and the hook, starting ON the anchor's last line (its `\n` closes the directive line)
        + "#if defined(STAGE90_XNU_WATCH_LE) && STAGE90_XNU_WATCH_LE\n"    "\t/* 1038's HOOK (STAGE90_XNU_WATCH_LE; tools/patch_d13_watch_le.py).  Runs in sleh_abort on every abort.\n"
    "\t *     On a DATA abort it copies the fault's own context (r0-r12, sp, lr, pc, cpsr, fsr, far) word by word\n"
    "\t *     and hands it to the slot writer, which records it only when it is a user-mode ARM fault (pc, cpsr,\n"
    "\t *     lr) and marks the owner slot.  It NEVER writes the context, dfsr/dfar, or any user memory, and it\n"
    "\t *     does not read user memory.  No locking: the writer stores the slot words, then (_wl_ss_slot) the\n"
    "\t *     slot counters, with release order.\n"
    "\t{   /* DATA aborts only: a prefetch context's fsr/far are the PREFETCH's, a different register set */\n"
    "\t\tunsigned _wl_ctx[19], _wl_k;\n"
    "\t\tif (reason == SLEH_ABORT_TYPE_DATA_ABORT && arm_ctx) {\n"
    "\t\t\t_wl_ctx[0] = arm_ctx->r[0];  _wl_ctx[1] = arm_ctx->r[1];  _wl_ctx[2] = arm_ctx->r[2];\n"
    "\t\t\t_wl_ctx[3] = arm_ctx->r[3];  _wl_ctx[4] = arm_ctx->r[4];  _wl_ctx[5] = arm_ctx->r[5];\n"
    "\t\t\t_wl_ctx[6] = arm_ctx->r[6];  _wl_ctx[7] = arm_ctx->r[7];  _wl_ctx[8] = arm_ctx->r[8];\n"
    "\t\t\t_wl_ctx[9] = arm_ctx->r[9];  _wl_ctx[10] = arm_ctx->r[10]; _wl_ctx[11] = arm_ctx->r[11];\n"
    "\t\t\t_wl_ctx[12] = arm_ctx->r[12];\n"
    "\t\t\t_wl_ctx[13] = arm_ctx->sp;  _wl_ctx[14] = arm_ctx->lr;  _wl_ctx[15] = arm_ctx->pc;\n"
    "\t\t\t_wl_ctx[16] = arm_ctx->cpsr; _wl_ctx[17] = arm_ctx->fsr; _wl_ctx[18] = arm_ctx->far;\n"
    "\t\t\t_wl_k = _wl_ss_slot(_wl_ctx);\n"
    "\t\t\tif (_wl_k) {\n"
    "\t\t\t\t__atomic_store_n(&_wl_owned, _wl_k, __ATOMIC_RELEASE);\n"
    "\t\t\t}\n"
    "\t\t}\n"
    "\t}\n"
"#endif /* STAGE90_XNU_WATCH_LE */\n"
)

# trap.c's `#if` identifiers are the union of what ALL the patchers put there.
TRAP_ALLOWED_IF_IDENTIFIERS = {
    "BOARD_CONFIG_QSD8250_LEO",
    "BOARD_CONFIG_ARMPBA8",
    "STAGE90_XNU_DYLD_WITNESS",       # 994
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
    "STAGE90_XNU_PC_CARRIER_CALLER",  # 1036
    "STAGE90_XNU_TRAP_FRAME",         # 1037
    "STAGE90_XNU_WATCH_LE",           # 1038 (this rung)
}

# every trap.c patcher whose allow list carries the switch (`grep -l ALLOWED_IF_IDENTIFIERS`)
PATCHERS = (
    "tools/patch_d13_abt_entry_probe.py",
    "tools/patch_d13_caller_probe.py",
    "tools/patch_d13_dyld_witness.py",
    "tools/patch_d13_eval_frame.py",
    "tools/patch_d13_h2_stack_headroom.py",
    "tools/patch_d13_pc_carrier.py",
    "tools/patch_d13_pc_carrier_caller.py",
    "tools/patch_d13_reader_probe.py",
    "tools/patch_d13_trap_frame.py",
    "tools/patch_d13_undef_raise.py",
    "tools/patch_d13_ustack_probe.py",
    "tools/patch_d13_writer_probe.py",
)


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


# The row pattern is built one character at a time ON PURPOSE: a literal `<q>xnu_live_<name>=` written
# in THIS file puts `<q>xnu_live_` immediately before a closing quote (the doubled-quote that follows),
# and the compiler folded the pattern to a shorter string that never matches the staged block -- so
# every row read as MISSING.  Never spell the prefix as a literal here.
head = "".join(["x", "n", "u", "_", "l", "i", "v", "e", "_"])   # the printed row prefix, never a literal


def _pat(c):
    # c = the printed name; the gate rows (`xnu_live_wlg_*`) print their own prefix, the others
    # print under `xnu_live_` too, so the prefix is always the same
    return chr(34) + head + c + chr(61)


def _spell_bodies(row):
    """The printed NAME of each print `row` must produce in the block (prefix excluded; the `=` of
    a GATE_ROWS name is kept): the A arm prints sweq_<row>, the B arm ler_<row>, the four named B
    addresses print a second row wlr_<row> ([r3], [r3+0x1c], [r3+0x2c], `pc-0x40`), and the
    `wlg_byte=`/`wlg_lev=` flags print under no index."""
    if row.startswith(head):
        body = row[len(head):]
        if body.startswith("wlg_byte") or body.startswith("wlg_lev"):
            return [body[:-1]]                     # `wlg_byte=%u` -- the `=` is the print's own
        if body.endswith("="):
            body = body[:-1]                       # `need_<row>=` -- the `=` belongs to _pat()
        return [body]
    if row in ("lr_cnt", "lr_mfp1", "lr_mfp2", "lr_ppc"):
        return ["wlr_" + row[3:]]
    if row in SWEQ_ROWS:
        return ["sweq_" + row]
    alphabetic = row in ("cnt_w_ok", "cnt_b_ok", "al0_ok", "mfp1_ok", "mfp2_ok", "ppc_ok", "le_ok")
    if alphabetic:          # cnt_w_ok..ppc_ok print `ler_<row>`; s0_ok..s15_ok are SWEQ_ROWS
        return ["ler_" + row]
    return ["ler_" + row]          # cnt_w..ppc (A arm) / cnt_b, *_ok, r3


def _spellings(row):
    return [_pat(b) for b in _spell_bodies(row)]


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
            "%s's directives also evaluate %s. trap.c is edited by TWELVE rungs and a file's directive "
            "identifiers are a SHARED namespace: add the new switch to TRAP_ALLOWED_IF_IDENTIFIERS here "
            "and to the other patchers' sets. ([[mi4-one-file-many-rungs]])" % (TRAP_REL, ", ".join(foreign)))
    if t.count(TRAP_ANCHOR) != 1:
        return False, p, t, (
            "the TRAP_FRAME/USTACK_PROBE `#endif` tail occurs %d time(s), expected exactly 1. The tree is "
            "not in the state this rung was written against (1037's block is not staged, or a displaced "
            "anchor / partial edit)." % t.count(TRAP_ANCHOR))
    if t.count(HOOK_ANCHOR) != 1:
        return False, p, t, (
            "the sleh_abort hook anchor (the space-indented `thread_t thread = current_thread();` after "
            "`arm_ctx = ... context;`) occurs %d time(s), expected exactly 1. trap.c's OTHER copy is "
            "TAB-indented in `other()` and is not this one ([[mi4-one-value-two-definitions]])." 
            % t.count(HOOK_ANCHOR))
    return True, p, t, "anchors unique, switch absent"


def _open_close(t, sw):
    """True iff the block `#if defined(sw) && sw` .. `#endif /* sw */` occurs exactly once, with the two
    lines adjacent (no other directive between them)."""
    return (t.count("#if defined(%s) && %s\n" % (sw, sw)) == 1
            and t.count("#endif /* %s */\n" % sw) == 1)


def hook_site(t, i):
    """True iff t[i:] IS the anchored hook edit verbatim (the anchor's own lines, then the hook's `#if`
    on the anchor's last line) -- the one predicate both --verify-off and the selftest judge by."""
    return t[i:i + len(HOOK_BLOCK)] == HOOK_BLOCK


def _two_arg_fault_read(t):
    """True iff the C code AFTER the hook's edit never reads `arm_ctx->far` (or `->cpsr`): that is the
    ARM's 2-argument save [pc, far] the hook patches.  This tree instead passes a 7-argument
    `abort_information_context_t` (far at 0x18, cpsr at 0x34: DATA_ABORT at trap.c:561 takes dfar from
    offset 0x18 while the hook at [4] is the prefetch FAR).  The hook writes what the arm later reads only
    on the 2-argument tree; on THIS tree dfr/dfar would be the CURRENT fault."""
    i = t.find(HOOK_ANCHOR)
    if i < 0:
        return False
    tail = t[i + len(HOOK_ANCHOR):]
    crack = tail.find("void\n")
    tail = tail if crack < 0 else tail[:crack]      # sleh_abort's body up to the next function
    return "arm_ctx->far" not in tail and "arm_ctx->cpsr" not in tail


def stage(xnu, do_apply):
    ok_t, tp, t, msg_t = check_trap(xnu)
    if not ok_t:
        print("patch_d13_watch_le: REFUSE (trap.c) - %s. Writing nothing." % msg_t, file=sys.stderr)
        return 1
    if msg_t == "already staged":
        print("patch_d13_watch_le: already staged - no-op, OK.")
        return 0
    print("   trap.c : %s." % msg_t)
    if not do_apply:
        print("patch_d13_watch_le: plan OK (dry run; pass --apply to write).")
        return 0
    hpos = t.find(HOOK_ANCHOR)
    out = t[:hpos] + HOOK_BLOCK + t[hpos + len(HOOK_ANCHOR):]
    # HOOK_BLOCK keeps the anchor verbatim (see its comment), so this must change nothing:
    assert out.count(HOOK_ANCHOR) == 1 and out.count(HOOK_DONE_MARK) == 1 and hook_site(out, hpos)
    out = out.replace(TRAP_ANCHOR, TRAP_BLOCK)
    if not _two_arg_fault_read(out):
        print("patch_d13_watch_le: WARNING - sleh_abort's C after the hook still reads `arm_ctx->far` / "
              "`arm_ctx->cpsr`: this tree passes the 7-argument abort_information_context_t (far at 0x18), "
              "not the 2-argument [pc, far] save the hook patches.  dfr/dfar then hold the CURRENT (first, "
              "prefetch=0) fault, not the preceding one; rebuild after re-pointing "
              "sleh_abort_type_data_abort to the 2-argument variant so the arm re-reads dfr/dfar from [4]. "
              "Staging anyway (the rows are read, not fixed).")
    write(tp, out)
    print("   trap.c : staged the A/B block (%d rows) after 1037's, inside 1025's failure arm; and the "
          "hook at sleh_abort's `thread = current_thread()`."
          % (len(SWEQ_ROWS) + len(LETTER_ROWS) + len(GATE_ROWS)))
    return 0


def closes_inside_1025(t):
    """True iff this block's #endif closes inside 1025's publisher: after it come zero or more WHOLE
    STAGE90 sibling blocks, then 1025's #endif (1033's evf_closes_inside_1025 rule)."""
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
    """With the switch undefined both edits vanish -> the 1037 tree's text."""
    tp = trap_path(xnu)
    if not os.path.isfile(tp):
        print("patch_d13_watch_le: --verify-off: no %s" % tp, file=sys.stderr)
        return 1
    t = read(tp)
    if SWITCH not in t:
        print("patch_d13_watch_le: --verify-off: switch ABSENT (nothing staged).", file=sys.stderr)
        return 1
    # three brackets: block, slot writer, hook (the writer is the hook's sibling: [r1-4])
    have = (t.count("#if defined(%s) && %s\n" % (SWITCH, SWITCH)) == 3
            and t.count("#endif /* %s */\n" % SWITCH) == 3)
    between = t.count("#endif /* STAGE90_XNU_TRAP_FRAME */\n#if defined(%s)" % SWITCH) == 1
    tail = closes_inside_1025(t)
    # the hook: the anchor occurs once, and this switch's LAST `#if` line opens immediately after it
    hooks = [m.start() for m in re.finditer(re.escape(HOOK_ANCHOR), t)]
    # the hook SITE: the anchor occurs once and the whole staged edit sits verbatim at that position
    # (hook_site holds position and content to one rule; the block site precedes the anchor in the file)
    hook_ok = len(hooks) == 1 and hook_site(t, hooks[0])
    # [s, e): the BLOCK's bracket.  The two brackets in sleh_abort (hook, slot writer) PRECEDE the block
    # in the file, so e is the `#endif` that closes the block's own `#if`, not the file's last one: the
    # block opens after 1037's `#endif`, the hook anchor (sleh_abort's current_thread line) precedes it.
    # THIS rung's own bracket only: the sibling blocks (1033/1035/1036/1037) sit between `s` and 1037's
    # `#endif` (their copyins are multi-line and theirs to judge, not this script's)
    op0 = "#if defined(%s) && %s\n" % (SWITCH, SWITCH)
    cl0 = "#endif /* %s */\n" % SWITCH
    s = t.find(op0)                               # the block site is before the anchor (block: after 1037)
    e = t.find(cl0, t.find("#endif /* STAGE90_XNU_TRAP_FRAME */\n#if defined(%s)" % SWITCH))
    inside = t[s:e] if (s >= 0 and e > s) else ""
    own = t[s + len(op0):t.find(cl0, s)] if inside and t.find(cl0, s) > s else ""
    rows = SWEQ_ROWS + tuple(r for r, _ in LETTER_ROWS) + GATE_ROWS
    rows = tuple(dict.fromkeys(rows))
    def inblk(row):
        """(missing, 1 ok / 2 bad) by the spelling each row is EMITTED under; each spelling exactly once
        (a row with two intended spellings is not a duplicate)."""
        ns = [inside.count(p) for p in _spellings(row)]
        return (0 if all(ns) else 1), 1 if all(v == 1 for v in ns) else 2
    missing = [r for r in rows if inblk(r)[0]]
    dup = [r for r in rows if not inblk(r)[0] and inblk(r)[1] != 1]
    # every copyin of a WORD sits in a compared expression (a miss prints 0 / _ok=0); the only copyins
    # that are not are the three 1-byte GATE probes and the two 1-byte LE assemblies, whose miss sets
    # _ok=0 by the loop break.  Every kernel-pointer load sits behind its own named test.
    ungated = [ln.strip() for ln in own.splitlines()
               if "copyin(" in ln and not re.search(r"(==|!=)\s*0\b|\b0\s*(==|!=)", ln)]
    byte_sites = inside.count(", 1) == 0)") + inside.count(", 1) != 0)")
    kptr = [ln.strip() for ln in inside.splitlines() if "*(volatile" in ln]
    kptr_guarded = (not kptr or (
            sum(1 for ln in kptr if "(uintptr_t)(_wl_m + _wl_i)" in ln) == 1   # fp-chain ldrb
            and sum(1 for ln in kptr if ln.startswith("_wl_v = *(volatile uint32_t *)(uintptr_t)_wl_m;")) == 1
            and sum(1 for ln in kptr if "(uintptr_t)_wl_fp; " in ln) == 1     # next saved r11
            and sum(1 for ln in kptr if "(uintptr_t)(_wl_lb[1] + _wl_i)" in ln) == 1))  # r3 ldrb
    # the hook is gated too (it is the OTHER switch bracket)
    # the hook edit's DONE mark sits in the hook bracket (sleh_abort precedes the block), the block's
    # mark inside the block's own bracket
    hook_inside = (hook_ok and s < e and t[hooks[0]:].count(HOOK_DONE_MARK) == 1
                   and t[s:e].count(TRAP_DONE_MARK) == 1) if hooks else False
    # the hook is gated too: both marks + hook_inside are the hook bracket's proof
    print("   trap.c [ON] : block row wlg_need_s0 + hook store + 3 `#if` / 3 `#endif` (block, writer, hook) "
          "edits: %s" % (have and hook_inside))
    print("   trap.c      : the block sits immediately after 1037's, inside 1025's publisher: %s" % between)
    print("   trap.c      : it closes inside 1025's publisher (whole sibling blocks allowed after it): %s"
          % tail)
    print("   trap.c      : the hook edit sits verbatim at sleh_abort's `thread = current_thread();` "
          "(the #if on the anchor's last line): %s" % hook_ok)
    print("   trap.c      : all %d rows inside the gated block, each exactly once: %s"
          % (len(SWEQ_ROWS) + len(LETTER_ROWS) + len(GATE_ROWS),
             "yes" if not missing and not dup else "NO: missing %s / dup %s"
             % (", ".join(missing), ", ".join(dup))))
    print("   trap.c      : no unguarded WORD copyin (every one compared): %s"
          % ("yes" if not ungated else "NO: %s" % ungated))
    # loader 1's sites: 3 GATE probes (first succeed -> 0, .last) + le's 4 + cnt_b's 4
    print("   trap.c      : 1-byte copyin sites, all guarded (3 gate probes) = 3: %s" % byte_sites)
    print("   trap.c      : kernel-pointer loads, each inside its own test (fp chain + slot + fp + ldrb): %s"
          % ("yes" if kptr_guarded else "NO"))
    if (have and hook_inside and between and tail and hook_ok and not missing and not dup and not ungated
            and byte_sites == 3 and kptr_guarded):
        print("patch_d13_watch_le: --verify-off PASS (all edits gated on the switch; OFF removes them -> "
              "the 1037 tree bytes).")
        return 0
    print("patch_d13_watch_le: --verify-off FAIL.", file=sys.stderr)
    return 1


def gates():
    print("xnu_live_wlg_need_<row> = 1 << gate id; a row is a READING only if every bit in its mask is")
    print("satisfied by the same run's rows, evaluated by the host reader (not by the block):")
    for gid, cond in GATES:
        rows = [r for r, g in SWEQ_GATE + LETTER_ROWS if g == gid]
        print("  %d  %-62s  %s" % (gid, cond, " ".join(rows) if rows else "-"))
    return 0

# ---------------------------------------------------------------- shared-namespace registration

def register_into(text, rel):
    """Insert STAGE90_XNU_WATCH_LE into the allow list that `text` (file `rel`) carries.  Three shapes:
    an ALLOWED_IF_IDENTIFIERS set literal (python), and the build script's `DEFINES+=(...)` reader.
    Returns (new_text, status) with status in {"present", "added", "ABSENT"}."""
    if SWITCH in text:
        return text, "present"
    if rel == BUILD_REL:
        if "STAGE90_XNU_TRAP_FRAME=1)" not in text:
            return text, "ABSENT"
        # the reader goes after 1037's, with the same one-line form and a comment naming this rung
        line = ("# 1038: STAGE90_XNU_WATCH_LE -- the A stack watch and the B little-endian reads (docs/1038-\n"
                "# design.md 1-2), one trap.c block + one sleh_abort hook (tools/patch_d13_watch_le.py).\n"
                "# Same GLOBAL ARRAY channel as every probe above.  OFF compiles the 1037 tree's bytes.\n"
                + BUILD_READER + "\n")
        m = re.search(r"\[\[ \$\{STAGE90_XNU_TRAP_FRAME:-0\} -eq 1 \]\] && DEFINES\+=\(-DSTAGE90_XNU_TRAP_FRAME=1\)\n",
                      text)
        if m is None:
            return text, "ABSENT"
        return text[:m.end()] + line + text[m.end():], "added"
    # a python allow list: the LAST STAGE90 entry of the set literal.  1035's pc_carrier list ends at
    # its own STAGE90_XNU_PC_CARRIER (it predates 1036-1037), so anchoring on 1037's name alone leaves
    # exactly that one file unregistered.  Both shapes: `"X",` (other entries follow) and `"X"}`.
    # the trailing comment, if any, is NOT part of the entry (it belongs to the matched line)
    m = re.search(r'(\n[ \t]*"(STAGE90_[A-Z0-9_]+)"[ \t]*,?(?:[ \t]*#[^\n]*)?)', text)
    if m is None:
        m = re.search(r'(\n[ \t]*"(STAGE90_[A-Z0-9_]+)"\})', text)
    if m is None:
        return text, "ABSENT"
    m_end = m.start() + m.group(1).find(m.group(2)) + len(m.group(2)) + 1
    entry = m.group(1)
    indent = re.match(r"\n([ \t]*)", entry).group(1)
    quote_closes = entry.rstrip().endswith("}")
    body = entry.rstrip()
    if body.endswith("}"):
        body = body[:-1].rstrip()
    # the new entry goes DIRECTLY after the matched line: nothing about the matched line may change
    # (a trailing comment kept in the match is the entry's comment, not part of the new pattern)
    new = body + ('\n' if body.endswith(",") else ",\n") + indent + \
        '"STAGE90_XNU_WATCH_LE",  # 1038 (tools/patch_d13_watch_le.py)'
    if quote_closes:
        new += "}"
    return text[:m_end] + new + ("," if quote_closes else "") + text[m_end:], "added"


def register(root=REPO, do_apply=False):
    """Every trap.c patcher's allow list + the build's DEFINES reader carry STAGE90_XNU_WATCH_LE.
    Returns (ok, report)."""
    report, ok = [], True
    paths = [os.path.join(root, p) for p in PATCHERS] + [os.path.join(root, BUILD_REL)]
    for p in paths:
        rel = os.path.relpath(p, root)
        if not os.path.isfile(p):
            report.append((rel, "ABSENT-FILE"))
            ok = False
            continue
        t = read(p)
        nt, st = register_into(t, rel)
        if st == "ABSENT":
            ok = False
            report.append((rel, st))
            continue
        report.append((rel, st))
        if st == "added" and do_apply:
            write(p, nt)
    return ok, report


# ---------------------------------------------------------------- selftest

BASE_TRAP = (
    "#if defined(STAGE90_XNU_USTACK_PROBE) && STAGE90_XNU_USTACK_PROBE\n"
    "#if defined(STAGE90_XNU_EVAL_FRAME) && STAGE90_XNU_EVAL_FRAME\n"
    "\t\t\t\t\t{ int _evf = 0; (void)_evf; }\n"
    "#endif /* STAGE90_XNU_EVAL_FRAME */\n"
    "#if defined(STAGE90_XNU_PC_CARRIER) && STAGE90_XNU_PC_CARRIER\n"
    "\t\t\t\t\t{ int _pcc = 0; (void)_pcc; }\n"
    "#endif /* STAGE90_XNU_PC_CARRIER */\n"
    "#if defined(STAGE90_XNU_PC_CARRIER_CALLER) && STAGE90_XNU_PC_CARRIER_CALLER\n"
    "\t\t\t\t\tprintf(\"xnu_live_pcc2_pc=0x%08x\\n\", 0U);\n"
    "#endif /* STAGE90_XNU_PC_CARRIER_CALLER */\n"
    "#if defined(STAGE90_XNU_TRAP_FRAME) && STAGE90_XNU_TRAP_FRAME\n"
    "\t\t\t\t\tprintf(\"xnu_live_fb_pc=0x%08x\\n\", 0U);\n"
    "#endif /* STAGE90_XNU_TRAP_FRAME */\n"
    "#endif /* STAGE90_XNU_USTACK_PROBE */\n"
    "void other(void) {\n\tthread_t thread = current_thread();\n\t(void)thread;\n}\n"
    "void\n"
    "sleh_undef(arm_saved_state_t * state)\n"
    "{\n"
    "    uint32_t cpsr, exception_type = 0, exception_subcode = 0;\n"
    "    arm_saved_state_t *arm_ctx = (arm_saved_state_t *) state;\n"
    "    " + _ANCHOR_BODY + "\n"
    "    (void)thread; (void)state;\n"
    "    unsigned left = 310; left -= 43; left -= 21; left -= 32; left -= 49;\n"
    "    (void)left;\n"
    "}\n"
    "void sleh_abort(void *context, int reason)\n"
    "{\n"
    "    uint32_t dfsr = 0, dfar = 0, ifsr = 0, ifar = 0, cpsr, exception_type =\n"
    "        0, exception_subcode = 0;\n"
    "    abort_information_context_t *arm_ctx =\n"
    "        (abort_information_context_t *) context;\n"
    "    " + _ANCHOR_BODY + "\n"
    "\n"
    "    (void)thread; (void)context; (void)reason;\n"
    "}\n"
)

# the 1037-tree bytes this rung must return to with the switch OFF: both edits removed
def off_text(t_on):
    """Simulate the preprocessor: drop every `#if defined(SWITCH) && SWITCH` .. `#endif /* SWITCH */`
    region (this switch's three brackets are not nested inside one another)."""
    out, depth = [], 0
    op = "#if defined(%s) && %s" % (SWITCH, SWITCH)
    cl = "#endif /* %s */" % SWITCH
    for ln in t_on.splitlines(True):
        if depth == 0 and ln.startswith(op):
            depth = 1
            continue
        if depth and ln.startswith(cl):
            depth = 0
            continue
        if depth == 0:
            out.append(ln)
    return "".join(out)


def selftest():
    import subprocess
    import tempfile
    fails, extra = [], 0
    tmp = tempfile.mkdtemp(prefix="p1038-")

    def tree(name, trap_text, with_build=False):
        root = os.path.join(tmp, name)
        os.makedirs(os.path.join(root, "osfmk", "arm"))
        os.makedirs(os.path.join(root, "tools"))
        with open(os.path.join(root, TRAP_REL), "w") as f:
            f.write(trap_text)
        if with_build:
            with open(os.path.join(root, BUILD_REL), "w") as f:
                f.write("[[ ${STAGE90_XNU_TRAP_FRAME:-0} -eq 1 ]] "
                        "&& DEFINES+=(-DSTAGE90_XNU_TRAP_FRAME=1)\n")
        return root

    def patcher_text(sw_in=None):
        t = ('ALLOWED = {\n    "BOARD_CONFIG_QSD8250_LEO",\n'
             '    "STAGE90_XNU_TRAP_FRAME",  # 1037 (x)\n}\n')
        if sw_in:
            t = t.replace("}\n", '    "%s",\n}\n' % sw_in)
        return t

    def expect(cond, label, counted=True):
        nonlocal extra
        if not counted:
            extra += 1
        print("   ok" if cond else "   FAIL", label)
        if not cond:
            fails.append(label)

    r = tree("good", BASE_TRAP, with_build=True)
    ok, p, t, msg = check_trap(r)
    expect(ok and msg == "anchors unique, switch absent", "the 1037 tree: plan accepts it (%s)" % msg)

    rc = stage(r, do_apply=True)
    t1 = read(trap_path(r))
    expect(rc == 0 and t1.count("\"xnu_live_wlg_need_s0=") == 1, "staged: exactly one gate row for s0")
    expect(t1.count("#if defined(%s) && %s\n" % (SWITCH, SWITCH)) == 3
           and t1.count("#endif /* %s */\n" % SWITCH) == 3,
           "staged: exactly three #if / three #endif (block site + slot writer + hook site)")
    expect(t1.count("#endif /* STAGE90_XNU_TRAP_FRAME */\n#if defined(%s)" % SWITCH) == 1,
           "staged: the A/B block opens immediately after 1037's #endif")
    expect(t1.count("#endif /* %s */\n#endif /* STAGE90_XNU_USTACK_PROBE */\n" % SWITCH) == 1,
           "staged: the A/B block closes immediately before 1025's #endif")
    i2 = t1.find(HOOK_ANCHOR)
    expect(i2 > 0 and hook_site(t1, i2),
           "staged: the hook opens immediately after sleh_abort's `thread = current_thread();`")
    expect(t1.count(HOOK_ANCHOR) == 1 and t1[t1.find(HOOK_ANCHOR):].count(HOOK_DONE_MARK) == 1,
           "staged: the hook edit's first line IS the SLEH_ABORT anchor (`other()`'s stays the file's "
           "first), so the staging index is not the file's first anchor")
    rc2 = stage(r, do_apply=True)
    expect(rc2 == 0 and read(trap_path(r)) == t1, "second --apply is an idempotent no-op")
    rc3 = verify_off(r)
    vok = verify_off(r)
    expect(vok == 0, "--verify-off PASS on the staged tree")
    expect(off_text(t1) == BASE_TRAP, "the switch OFF removes BOTH edits -> the 1037 tree bytes, exactly")
    # the other blocks are intact: OFF-exactness against the fixture proves the bytes outside this
    # rung's three brackets (the fixture carries 1033/1035/1036/1037 sibling blocks inside 1025's)
    sib = [n for n in ("STAGE90_XNU_EVAL_FRAME", "STAGE90_XNU_PC_CARRIER", "STAGE90_XNU_PC_CARRIER_CALLER",
                       "STAGE90_XNU_TRAP_FRAME")]
    expect(all(off_text(t1).split("#if defined(%s) && %s\n" % (n, n))[1]
               .split("#endif /* %s */" % n)[0] == BASE_TRAP.split("#if defined(%s) && %s\n" % (n, n))[1]
               .split("#endif /* %s */" % n)[0] for n in sib),
           "the older sibling blocks (1033/1035/1036/1037) survive verbatim", False)
    s = t1.find("#if defined(%s) && %s\n" % (SWITCH, SWITCH))
    e = t1.find("#endif /* %s */\n" % SWITCH,
                t1.find("#endif /* STAGE90_XNU_TRAP_FRAME */\n#if defined(%s)" % SWITCH))
    inside = t1[s:e]
    n = len(SWEQ_ROWS) + len(LETTER_ROWS) + len(GATE_ROWS)
    # the SAME spelling map verify_off judges by (one source, so the two can't disagree)
    all_rows = SWEQ_ROWS + tuple(rr for rr, _ in LETTER_ROWS) + GATE_ROWS
    spell = _spellings
    expect(all(all(sp in inside for sp in spell(r)) for r in all_rows),
           "every emitted row is inside the gated block")
    pumped = (SWEQ_ROWS + tuple(rr for rr, _ in LETTER_ROWS)
              + GATE_ROWS)
    pats = [sp for r in pumped for sp in spell(r)]
    expect(len(pats) == n and all(inside.count(sp) == 1 for sp in pats), "no duplicate row")
    # WRITERS, not names: names alone cannot catch a row that prints the wrong slot (al0 printed an
    # unwritten _wl_lt[2] and ppc printed mfp2's slot for a whole session).  Each row's print names its
    # slot, the slot's filler exists, and no two ROW prints share a slot.
    def _slot(row):
        """the _wl_lt[<n>] indexed by the row's print statement (the '=' of the format is escaped in
        the block's C string, so match on the name and the first slot that follows it)"""
        i = inside.index("xnu_live_ler_" + row + "=0x")
        return int(re.search(r"_wl_lt\[(\d+)\]", inside[i:i + 200]).group(1))
    row_slots = {row: _slot(row) for row in ("al0", "cnt_b", "cnt_w", "mfp2", "ppc")}
    expect(len(set(row_slots.values())) == len(row_slots) and row_slots["ppc"] != row_slots["mfp2"]
           and row_slots["al0"] == 2,
           "B rows print distinct slots (al0=%d mfp2=%d ppc=%d)" % (row_slots["al0"], row_slots["mfp2"],
                                                                  row_slots["ppc"]), False)
    expect(inside.count("&_wl_lt[6], 4)") == 1 and inside.count("&_wl_lt[0], 4)") == 1
           and inside.count("_wl_lt[1] |=") == 2 and inside.count("if (_wl_i != 2U && _wl_i != 4U)") == 1,
           "each printed B slot has exactly one filler (ppc has its own pc-0x40 read)", False)
    expect(not re.search(r"^\s*#", inside.replace("\t\t", ""), re.M) or
           not re.search(r"^\s*#(?!endif|if)", inside), "no nested directive inside the block")
    # the three loaders exist, each on its own site
    expect(inside.count(", 1) == 0)") == 1 and inside.count(", 1) != 0)") == 2,
           "loader 1: one 1-byte gate copyin, two 1-byte LE assemblies")
    expect(inside.count("*(volatile uint8_t *)(uintptr_t)(_wl_lb[1]") == 1,
           "loader 2: a kernel-pointer ldrb for [r3+0xc]")
    expect(inside.count("*(volatile uint32_t *)(uintptr_t)_wl_m;") == 1,
           "loader 3: a kernel-pointer ldr for the `pop {pc}` pop-follow only")
    # the selftest can FAIL: an unguarded copyin
    # the diff summary the press lane reads: where each edit landed in the 1037 tree and how many lines
    # it adds; OFF-exactness above already shows the older blocks are intact byte for byte
    t_off = off_text(t1)
    def line_of(text, needle):
        return text[:text.index(needle)].count("\n") + 1
    print("   diff   : block after %s:%d (%d lines added), hook after sleh_abort's "
          "`thread = current_thread();` at %s:%d (%d lines added); rows %d"
          % (TRAP_REL, line_of(t_off, "\n#endif /* STAGE90_XNU_TRAP_FRAME */") + 1,
             TRAP_BLOCK.count("\n") - 1, TRAP_REL,
             line_of(t_off, HOOK_ANCHOR) + 1,
             HOOK_BLOCK.count("\n") - 1, n))
    r_bad = tree("unguarded", BASE_TRAP)
    stage(r_bad, do_apply=True)
    seq_row = "\t\tprintf(\"xnu_live_sweq_seq=%u\\n\", (unsigned)((_wl_s >> 1) & 0x7fffffffU));\n"
    tb = read(trap_path(r_bad)).replace(
        seq_row,
        seq_row + "\t\tcopyin((user_addr_t)(uintptr_t)_wl_sp, (char *)&_wl_le[0], 4);\n", 1)
    write(trap_path(r_bad), tb)
    expect(verify_off(r_bad) != 0, "--verify-off FAILS on an unguarded word copyin")
    # the selftest can FAIL: a row removed from the block
    r_miss = tree("missing_row", BASE_TRAP)
    stage(r_miss, do_apply=True)
    tm = read(trap_path(r_miss)).replace('printf("xnu_live_ler_mfp2_ok=%d\\n"', 'printf("xnu_live_ler_MISSING=%d\\n"')
    write(trap_path(r_miss), tm)
    expect(verify_off(r_miss) != 0, "--verify-off FAILS when a row name is not emitted")
    # a tree whose 1037 tail is absent -> refuse, write nothing
    r2 = tree("noanchor", BASE_TRAP.replace("#endif /* STAGE90_XNU_TRAP_FRAME */\n", ""))
    before = read(trap_path(r2))
    ok2, _, _, msg2 = check_trap(r2)
    expect(not ok2 and "expected exactly 1" in msg2, "missing 1037 tail: REFUSE (%s)" % msg2)
    expect(read(trap_path(r2)) == before, "a refused stage writes nothing")
    # a tree without the hook anchor
    # ONLY the sleh_abort copy broken (the sleh_undef copy is a different anchor: context + `state;`)
    r2b = tree("nohook", BASE_TRAP.replace("        (abort_information_context_t *) context;\n    " + _ANCHOR_BODY,
                                           "        (abort_information_context_t *) context;\n"
                                           "    thread_t thread = current();"))
    ok2b, _, _, msg2b = check_trap(r2b)
    expect(not ok2b and "hook anchor" in msg2b, "missing hook anchor: REFUSE (%s)" % msg2b)
    # --- the two splices this rung got wrong and fixed this hour (each must FAIL if they return):
    # (1) an anchor found at a position that is NOT where the hook edit opens must not count as staged
    expect(hook_site(t1, t1.find(HOOK_ANCHOR)), "hook_site: the staged edit sits at the anchor, index 0", False)
    expect(not hook_site(t1, t1.find(HOOK_ANCHOR) + 1) and not hook_site(t1, -1)
           and not hook_site(t1, t1.find(HOOK_ANCHOR) + len(HOOK_ANCHOR)),
           "hook_site: no other index in the staged tree is the hook's first line", False)
    # (2) a HOOK_BLOCK that consumes the anchor leaves a tree with no anchor (the failure mode this hour):
    #     --verify-off refuses it
    r_stale = tree("stale_hook", t1.replace(HOOK_ANCHOR, "", 1))
    expect(verify_off(r_stale) != 0, "--verify-off FAILS on a staged tree whose anchor is consumed")
    # (2) a schedule whose hook lands on the FIRST anchor-style copy of `thread = current_thread();`
    #     (`other()`'s, TAB-indented, the same five-line text) -- the exact bug fixed this hour: the
    #     multi-line anchor alone still matched that copy, and the marker check must catch the splice
    r_first = tree("first_anchor", BASE_TRAP.replace(
        "void other(void) {\n", HOOK_ANCHOR + "void other(void) {\n", 1))
    i_first = r_first and read(trap_path(r_first)).find(HOOK_ANCHOR)
    r_first2 = tree("first_anchor2", BASE_TRAP)
    h0 = r_first2 and read(trap_path(r_first2)).find(HOOK_ANCHOR)
    # splice the hook at the FIRST occurrence (the wrong copy), then judge
    tf = read(trap_path(r_first2))
    write(trap_path(r_first2), tf[:h0] + HOOK_BLOCK + tf[h0 + len(HOOK_ANCHOR):])
    expect(verify_off(r_first2) != 0, "--verify-off FAILS when the hook sits at the wrong copy's anchor")
    # a foreign identifier
    r3 = tree("foreign", BASE_TRAP.replace("#endif /* STAGE90_XNU_USTACK_PROBE */\n",
                                           "#if defined(STAGE90_XNU_NOBODY_ADDED_ME) && STAGE90_XNU_NOBODY_ADDED_ME\n"
                                           "#endif /* STAGE90_XNU_NOBODY_ADDED_ME */\n"
                                           "#endif /* STAGE90_XNU_USTACK_PROBE */\n"))
    ok3, _, _, msg3 = check_trap(r3)
    expect(not ok3 and "STAGE90_XNU_NOBODY_ADDED_ME" in msg3, "a foreign identifier: REFUSE")
    # registration: every patcher's allow list + the build reader
    reg_root = os.path.join(tmp, "reg")
    os.makedirs(os.path.join(reg_root, "tools"))
    for name in PATCHERS:
        with open(os.path.join(reg_root, name), "w") as f:
            f.write(patcher_text())
    with open(os.path.join(reg_root, BUILD_REL), "w") as f:
        f.write("[[ ${STAGE90_XNU_TRAP_FRAME:-0} -eq 1 ]] && DEFINES+=(-DSTAGE90_XNU_TRAP_FRAME=1)\n")
    okr, rep = register(reg_root, do_apply=False)
    expect(okr and all(st == "added" for _, st in rep), "registration: plan adds the switch everywhere")
    expect(not any(SWITCH in read(os.path.join(reg_root, n)) for n in PATCHERS),
           "registration: dry run writes nothing")
    okr2, rep2 = register(reg_root, do_apply=True)
    okr3, rep3 = register(reg_root, do_apply=False)
    expect(okr2 and okr3 and all(st == "present" for _, st in rep3),
           "registration: --apply adds it to all %d files; a second run is a no-op" % len(rep2))
    pt = read(os.path.join(reg_root, "tools/patch_d13_eval_frame.py"))
    ns = {}
    exec(compile(pt, "allow", "exec"), ns)   # the edited literal is still a valid python set
    expect(SWITCH in ns["ALLOWED"], "registration: the edited literal is a valid set carrying the switch")
    with open(os.path.join(reg_root, BUILD_REL)) as f:
        bt = f.read()
    expect(bt.count(BUILD_READER) == 1 and bt.count("STAGE90_XNU_TRAP_FRAME=1)") == 1,
           "registration: the build gains ONE reader, after 1037's")
    # a list that ends at an OLDER rung's name (1035's pc_carrier predates 1036-1037): the anchor is the
    # last STAGE90 entry, not 1037's name
    old_ok, old_st = register_into('ALLOWED = {\n    "STAGE90_XNU_EVAL_FRAME",\n'
                                   '    "STAGE90_XNU_PC_CARRIER",\n}\n', "tools/patch_d13_xx_old.py")
    expect(old_st == "added" and '"STAGE90_XNU_WATCH_LE"' in old_ok and old_ok.rstrip().endswith("}"),
           "registration: a list ending at an older rung's name is still registered")
    with open(os.path.join(reg_root, "tools/patch_d13_undef_raise.py"), "w") as f:
        f.write("ALLOWED_IF_IDENTIFIERS = {\n}\n")   # no 1037 anchor to insert after
    okr4, rep4 = register(reg_root, do_apply=False)
    expect(not okr4, "registration: a list with no TRAP_FRAME anchor is reported, not silently skipped")

    if fails:
        print("SELFTEST FAIL: " + " | ".join(fails), file=sys.stderr)
        return 1
    print("SELFTEST PASS (%d checks: plan/apply/idempotent/three-brackets/OFF-exact/can-fail/"
          "registration)" % (21 + extra))
    return 0


def main(argv):
    if "--selftest" in argv:
        return selftest()
    apply_ = "--apply" in argv
    if "--verify-off-only" in argv:
        return verify_off(argv[1])
    if "--gates" in argv:
        return gates()
    if "--register" in argv:
        ok, rep = register(REPO, do_apply=apply_)
        for rel, st in rep:
            print("   %-40s %s" % (rel, st))
        print("patch_d13_watch_le: --register %s" % ("PASS" if ok else "FAIL (a file carries no anchor)"))
        return 0 if ok else 1
    if len(argv) < 2:
        print("usage: patch_d13_watch_le.py <xnu_root> [--apply|--verify-off] [--selftest] [--gates]\n"
              "       patch_d13_watch_le.py --register [--apply]", file=sys.stderr)
        return 2
    xnu = argv[1]
    reg_ok, rep = register(REPO, do_apply=apply_)
    for rel, st in rep:
        print("   namespace: %-40s %s" % (rel, st))
    if not reg_ok:
        print("patch_d13_watch_le: REFUSE - a trap.c patcher's allow list (or the build's DEFINES reader) "
              "has no anchor to register STAGE90_XNU_WATCH_LE after. Fix by hand. Writing nothing.",
              file=sys.stderr)
        return 1
    if "--apply" in argv and any(st == "added" for _, st in rep):
        print("   namespace: registered STAGE90_XNU_WATCH_LE in every allow list and in the build.")
    if "--verify-off" in argv:
        return verify_off(xnu)
    return stage(xnu, do_apply=apply_)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
