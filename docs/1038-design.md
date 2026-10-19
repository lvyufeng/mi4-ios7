1038 DESIGN -- THE FOREIGN CODE ON THE STACK, THE BY-PASS AT THE COUNT, AND THE FIRST 64 KiB OF THE CACHE
2026-10-19.  Source: records/1037-read.txt A-C (the 1036 capture, recovered 08:01:48, read on the host this
hour).  Instrument only; no cache patch, no walk change.  Three blocks, three questions, ONE press.

====================================================================================================
0. WHAT THE 1036 CAPTURE PRE-REGISTERS THIS RUN AGAINST (each a row 1038 must REPRODUCE, not a fact)
====================================================================================================
   S  the frame is real (sp 0x2bd8d088, r4 sp-4, r7 sp+0x24, far 0x10, pc 0x399a1474, cpsr 0x30)
   T  s3 (frame sp+0xc) == 0xffffffff (1037-read B2: the H-SHORTNAME imm16 `ff f0`, one byte late)
   W  r1 == 0 at the walk and the ldrb faults at 0x10 (1037-read B3: the `mov r0,r0` by-pass)
   V  the count the walk reads: r5 == -1 AND the word at [r3+0xc] (the table's own word 2, the count)
      -- 1037-read B3 predicts [r3+0xc] == 0
   H  launchd logs `The System bootstrapper has crashed: Bus error: 10`; pid 1 survives and
      re-launches; after a short storm the machine resets with no user activity
   U1 the run's own slide: IOS7SHREG map_slide `slide=0x1d7b000 slide_start=0x3df27000` (pid 1 and 2
      both printed it; 1038 derives its candidate addresses from THIS row and never from a literal)

====================================================================================================
1. BLOCK A -- WHO WROTE THE STACK (switch STAGE90_XNU_STACK_WATCH, tools/patch_d13_stack_watch.py)
====================================================================================================
   Where: the same 1025 USTACK_PROBE publisher in trap.c (the pid-2 arm), placed so it runs BEFORE the
   first frame read.  One-shot per thread (a guard word in the block's own static).
   Rows (raw; every read the 1035 guarded idiom; a miss prints 0 and _ok=0):
     xnu_live_sweq_seq / _pid / _ssid            (current_thread()->thread_id, as 0x%08x)
     xnu_live_sweq_sp / _usp / _k  (the user's r13 -- twl_last_accessed or the uss slot named by the
                                    tree, cited in the patch's comment)
     xnu_live_sweq_s0 .. _s15       (16 words at sp-4, task-map read, _ok each)  -- 1036's s3 must land
     xnu_live_sweq_tdfar / _tdpc / _td_ok
     xnu_live_sweq_bp[0..3] (32 bytes at the VALUE of s3 if s3 != 0, _ok each)   -- the rest of the copy
     FAULT-IN-USER-CODE: the (dfar, pc) pair recorded from the user-mode data abort that immediately
     precedes this arm (1033 error path): the rule is F(far) = read32(pc - 0x40), tested with
     xnu_live_swb_far / _pc  and the pre-registered conjunct  far == *(pc - 0x40).
   If the block cannot read DFSR/DFAR itself, it prints the trap.c `dfsr`/`dfar` arguments (reason 4 arm)
   and the caller's arm_ctx->pc; the patch must state WHICH it read.
   THE READER (tools/check_1038_capture.py) prints:
     A1 WATCH-FATAL       bp rows fault (s3 points at the copy and the copy is not mapped) AND
                          far == *(pc-0x40) AND s3 == 0xffffffff
     A2 WATCH-ALIVE       bp readable AND the 32 bytes equal capture B2's 0x5d3bd7.. (given)
     A3 WATCH-READS-ZERO  bp readable and zero
     A4 WATCH-NO-STORE    bp readable with s3's source absent -> the copy hypothesis is DEAD
   FALSIFIERS: if far != *(pc-0x40) the faulting instruction is not what B3 names and A1 must not be
   read; if s3 == 0 the block never ran and there is no reading.

====================================================================================================
2. BLOCK B -- LITTLE ENDIAN AT THE TABLE (switch STAGE90_XNU_LE_READ, tools/patch_d13_walk_le.py)
====================================================================================================
   Where: the same arm, beside A.  Reads the SAME page through a BYTE access function in this kernel:
     the tree's own `in_byte` / `read_byte`-shaped load used by copyin (the patch cites the symbol from
     `arm-none-eabi-nm out/xnu_kernel_obj_d13/`), or a PMAP-supported mapping of the page full-SOD at
     VA 0xe0000000-0x1000... whichever the tree HAS; if NEITHER exists the block prints _ok=0 and the
     rung has no B cell (do not invent a mapping).
   Rows: xnu_live_ler_seq / _pid / _r3 / _cnt_w (the word at r3+0xc as the kernel reads it) /
         _cnt_b (the same four bytes read one byte at a time, assembled LITTLE-endian) / _cnt_b_ok /
         _al0 (the `bx pc` at r3) / _mfp (the value of `mov r0, fp` at r3+0x1c and r3+0x2c) /
         _ppc (text at pc-0x40 raw) / _le (v)<8 : the same text assembled little-endian) / _le_ok
   Cells:
     B1 LE-CONFIRMED   _cnt_w == 0 AND _cnt_b != 0 AND _le_ok AND _le != _ppc
     B2 NOT-BE          either conjunct false -> the byte-swap model is DEAD
   THE CONJUNCTS ARE THE POINT: one word equal under both views says nothing; the cell needs the
   KERNEL's view to differ from the BYTE view on the same four bytes.

====================================================================================================
3. BLOCK C -- THE FIRST 64 KiB (switch STAGE90_XNU_CACHE_HEAD, tools/patch_d13_cache_head.py)
====================================================================================================
   Where: same publisher.  Reads 0x10000 bytes of the task's shared-cache mapping (base = pc - slide,
   trunc 0x10000) 16 bytes at a time through the same byte accessor as B; every 0x10-byte row is
   classified by a tiny in-kernel rule and the row (offset, first 8 bytes, class, _ok) is published for
   the FIRST row of each class present, in a fixed precedence:
     1 count   : int32 at row+0x90.. is small (0<v<0x100000) and 0x1c bytes of zeros follow
     2 hdr     : the 32-byte mapping-record shape {addr, size, fileOffset} with addr<0x40000000 and
                 fileOffset monotonically < 0x40000000 and size non-taking   (any of three records)
     3 text    : >= 12 of the 16 bytes >= 0x20 (a rough "code-like ASCII" test)  -- used only to EXCLUDE
   Rows: xnu_live_chd_seq / _pid / _base / _scan_len / _n_count / _n_hdr / _n_text / _first_count
         (offset at which 1 first held) / _ok
   Cells:
     C1     no count-shaped word anywhere for (= 0)                    -> the head is TEXT from 0:
              the file on card is the wrong-layout cache
     C2     every count candidate > 0x10000                            -> a table exists but not near the
              head (NOT-A)
     C3     every count candidate < 0x10000 and none readable as user code -> the count table sits in
              an executable page (NOT-B)
     C1/C2/C3 need _ok=1 and scan_len == 0x10000; otherwise no reading.

====================================================================================================
4. PRE-REGISTERED READING OF THE PRESS AS A WHOLE
====================================================================================================
   IF A1 fires: the foreign copy is on record with its source -- the bootstrap killer is file 0x5d3bd7
   landing on arg pages; 1039 = find who copies it (the same narrative as the count path, and the
   kernel must be made not to).
   IF B1 and C1: the file served to userland has no count table near the walk's page; 1039 = which
   dyld and which file (the share-cache driver's ruled-out RejectMapping branch).
   IF A4 and B2: 1037-read B2/B3 are dead; the walk question returns to the 1037 cells only.
   None of these can print more than one line each; the kernel publishes raw rows, the host decides.

====================================================================================================
5. WHAT 1038 DELIBERATELY DOES NOT DO
====================================================================================================
   * No change to the walk, the count, the cache card, or any code page.
   * No new address literals for the cache: every candidate comes from a row printed in the SAME run.
   * No press uses the current card if a patch is staged after the press (park_press ordering is 1039's
     if a fix is chosen).
   * THE CARD'S FILE LAYOUT IS NOT A CELL OF 1038.  1036's capture shows the U1 mapping of the card's
     cache SUCCEEDING and userland running on it; whether that file is an ARMv7S raw image is NOT
     settled here, and any conclusion about it must rest on a byte-level read of the volume (slot-read
     AND buffer-read, both), recorded in its own file -- not on a page of this design.
