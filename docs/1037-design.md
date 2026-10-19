1037 DESIGN -- ONE BLOCK: pc, near, trap-frame sp/far, slide as an expression; and a by-value test of H-SHORTNAME
2026-10-19. Source: records/1036-read.txt (3-7). Instrument only; no cache patch, no walk change.

====================================================================================================
1. WHAT 1036 + THIS HOUR'S RE-READ ESTABLISHED
====================================================================================================
  (i) THE FRAME IS RIGHT: the register dump `sleh_abort` prints from `arm_ctx` (the trap entry's own
      uss stmea block, r8..r11 included) agrees with the evf/pcc/pcc2 rows register for register
      (r0 1, r1 0, r2 -1, r3 0x39b04020, r4 0x2bd8d084, r5 -1, r6 = sp, r7 0x2bd8d0ac, r8 0x2f232575,
      r9 0x1fff, r10 0x39aedc00, r11 0x2bd8d080, r12 0x4000, sp, lr, pc, cpsr 0x30).
  (ii) THE FAULT IS IN libobjc'S WALK -- read correctly this hour: the comment "the walk's load is a
      32-bit ldr.w" (1036-read 6) was WRONG.  File VA 0x37C26474 holds `09 7c 00 29` =
      ldrb r1,[r1,#0x10]; cmp r1,#0.  r9 = 0x1fff and r12 = 0x4000 are the walk's own constants (the
      chunk count and 0x8000>>1).  r2 = -1 is the VLA loop's count = r5, r6 = sp, r8 = the table
      pointer being scanned.
  (iii) WHY THE ROWS LOOKED IMPOSSIBLE: every function in this trap path is ARM (`.arm` in trap.c /
      traps_lo.s), so a fault `lr` has bit0 = 0 -- yet lr reads 0x399999af, and r10 = 0x39aedc00 has its
      LOW BIT SET too.  Two registers that cannot be odd are odd, so the trap entry stores some registers
      at the wrong OFFSET.  Same class as the 965-era 4-mod-8 C-stack defect, on the OPPOSITE side: not
      a shifted frame pointer, a shifted SAVE.  r1 = 0, r5 = r2 = -1 are therefore not established.
  (iv) THE SLIDE: 1035's xor slots that matched (pc, pc+8, pc+0x20) are the ones NOT relocated;
      the two that did not (pc-0x20, pc-0x08) hold MOVW/MOVT immediate PAIRS in the file
      (`4b f0 00 40` = movw r0,#0xf04b / movt r0,#0x40; `d2 04 18 00`), and the device's copies differ
      in EXACTLY the MOVT half and the MOVW half -- i.e. the page was RELOCATED (movw/movt patched by
      a slide), and the "modulation" near0 = 0xebad46a5 for file 0x4000f04b is the relocator's own
      arithmetic, not a different file.  THIS MAKES pc = the walk at file 0x37C26474 and pc's slide =
      pc - 0x37C26474 = 0x228E0000, with near1/near3 also explained.  The slide literal 0x577000 is
      WRONG; 1035-read's 0x50C000 was inferred from the same relocator arithmetic and is not the
      measured slide either.
  THE QUESTION 1037 ANSWERS: WHICH REGISTERS ARE SAVED AT THE WRONG OFFSET, AND WHAT IS THE TRUE FRAME?
  One block that compares trap-frame registers with the TASK-MAP's own copy of the uss (the trap entry
  writes it before entering C), plus a displacement-consistent slide derived from lr alone.

====================================================================================================
2. THE BLOCK (tools/patch_d13_frame_block.py, switch STAGE90_XNU_FRAME_BLOCK)
====================================================================================================
  Where: trap.c, inside 1025's USTACK_PROBE publisher, in the same arm 1033/1035/1036 use (data abort,
  pid 2).  It is inserted after 1036's block (`#endif /* STAGE90_XNU_PC_CARRIER_CALLER */`).
  Rows (names exact; every read is the 1035 guarded idiom, `_ok` rows, a miss prints 0/0):
    xnu_live_fb_seq / _pid
    xnu_live_fb_pc / _lr / _sp_tr / _far_tr / _far_tr_ok     (the TRAP frame: the handler's own
        `far` argument and the trap entry's saved sp -- whatever name the trap.c arm holds them under;
        the implementation must cite the variable it read, not the concept)
    xnu_live_fb_near0 = pc-0x10 / near1 = pc-0x08 / near2 = pc (both halfwords: _lo, _hi) / near3 = pc+0x08 /
        near4 = pc+0x10 / each with _ok
    xnu_live_fb_slide = pc - 0x37C26474   (EXPRESSION: the record's file VA of the walk's load; if this
        run's pc is not the walk the number is simply a different slide, and the near words say so)
    xnu_live_fb_uss      (the task's own copy: the uss VA the trap entry wrote -- read through the task
                        map as a 0x50-byte record; the 19 words the stmea stores, +40 spsr, +44 dfsr,
                        +48 far) and the six registers where a misplacement would show:
    xnu_live_fb_uss_r[0..12], _uss_sp, _uss_lr, _uss_pc   (17 rows, from the TASK-MAP read)
  xnu_live_fb_ctx_diff   (the words where arm_ctx and the uss disagree, as a bitmask -- computed in the
                        kernel by walking both with the two bases named, NOT assumed)
  xnu_live_fb_ldrh       (halfword at the walk's load site through the same slide) + _ok
    xnu_live_fb_dbg_off      (debug_buf_ptr - debug_buf, as a number; a symbol, if the pool links it)
  Cap: 4, own static counter.  Every value raw.

====================================================================================================
3. PRE-REGISTERED CELLS (records/1037-read.txt, fixed BEFORE the press)
====================================================================================================
  ctrl : fb_dbg_off_ok AND fb_dbg_off < debug_buf_size   (the rows were flushed: presence is a reading)
  D1   SAVE-MISPLACED      : ctrl AND ctx_diff != 0     -- the trap entry's uss copy and the C-side arm_ctx
        DIFFER.  The offending offsets are named by the mask bits; the fix is in the SAVE.  This is the
        cell (iii) predicts; H-SHORTNAME is then MOOT because r1 = 0 may itself be a misplacement.
  D2   SAVE-AGREES         : ctrl AND ctx_diff == 0     -- arm_ctx IS the uss copy.  Then an odd lr/r10
        is a real register value: either the abort came from Thumb code (are there Thumb frames on this
        path? measured by the code at lr under the derived slide) or the uss stmea block was itself
        polluted -- 1038 must re-derive the entry from the SPSR/CPSR path, not from the save.
  D3   NO-BLOCK            : ctrl AND the rows are absent -> the block did not run.  NOT a cell.
  L1   SLIDE-FROM-LR       : lr - slide points at a `blx/bl` return site in a FILE-EXACT NOT-RELOCATED
        region (file word == device word at lr-4 or lr-8, xor 0) -> the slide is measured, and S1/S2 of
        1036 are settled: pc IS the walk at 0x37C26474.  Reported as a row (`fb_lr_xor4`, `fb_lr_xor8`),
        ANDed with D1/D2, never instead of them.

  Each cell prints exactly one line.  A cell requires ctrl; ctrl absent = no reading.
====================================================================================================
4. FALSIFIERS RECORDED NOW
====================================================================================================
  * If pc-relative words still equal 1035's AND pc differs from 1035's, the block's own pc row is
    suspect (same failure mode as 1036): 1037 reports it as S2 only if the words are readable and differ.
  * If fb_walk_ldrh = 0x7C09, the walk's load is `ldrb` and H-SHORTNAME's model (r1=0 lets r5=-1 through
    a 32-bit load) is dead -- regardless of what the slide row says.
  * If the trap-frame sp row equals the 1036 pcc2 sp, the "trap entry's saved sp" name was wrong.