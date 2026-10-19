1036 DESIGN -- READ THE CALLER AND THE TABLE, NOT THE CACHE
2026-10-19. Source question: records/1036-static-caller.txt (static) and records/1035-read.txt (measured).
This rung patches NOTHING in the shared cache and does not change the walk. It only prints.

====================================================================================================
1. WHAT IS MEASURED, AND WHAT THE ONE QUESTION IS
====================================================================================================
  1035 read, by value: at the fault launchctl[2] executed the file's walk word at VA 0x37C26474
  (`ldrb r1,[r1,#0x10]`) with r1 = 0, r2 = r5 = -1, r4 = 0x2BD27084, r7 = 0x2BD270AC, lr = 0x3812A9AF.
  getPreoptimizedClass's own entry cannot reach that r5 (its VLA path needs r5 == 1); 1032's clamp at
  0x37C26720 guards the map writer's loop, not this frame. So the frame was SET UP by code we have not
  named, and the -1 was carried into r5 from some producer we have not seen.
  The question, in one line: WHERE DID r5 = -1 COME FROM, AND WHICH INSTRUCTION ENTERED THE WALK?
  The rung answers it with raw bytes: the caller's lr words, the caller's stack frame, the table
  header words getPreoptimizedClass's r1 object points at, and every register in the frame.

====================================================================================================
2. THE BLOCK (tools/patch_d13_pc_carrier_caller.py, switch STAGE90_XNU_PC_CARRIER_CALLER)
====================================================================================================
  Same arm as 1035: trap.c, inside 1025's USTACK_PROBE publisher, data-abort failure arm, pid == 2,
  its own static counter capped at 4. Insertion anchor: the 1035 block's `#endif /* STAGE90_XNU_PC_CARRIER */`.
  Every read is the 1035 guarded idiom (aligned through the task map, `_ok` rows; a miss prints 0/0).
  Rows (raw values only; every predicate is the checker's):
    xnu_live_pcc2_seq / _pid / _pc / _lr / _sp / _r7 / _r3 / _r6 / _r8 / _r9 / _r12 / _slide
    xnu_live_pcc2_lr_m4(_ok) / _lr_m8(_ok)      the caller instruction (lr-4) and the word before it
    xnu_live_pcc2_tbl_hdr(_ok) / _tbl_used(_ok) [r8+0] and [r8+12] -- the table header, the two
                                                "can be -1" count candidates of 1036 static 3(a)
    xnu_live_pcc2_s0(_ok) .. _s15(_ok)          the caller frame: r7-0x40 .. r7-0x04, 16 words

====================================================================================================
3. PRE-REGISTERED CELLS (records/1036-read.txt, fixed before the press)
====================================================================================================
  C1 CALLER-BL-TO-WALK  lr_m4_ok == 1 AND lr_m8_ok == 1 AND lr_m4 != 0.
     The caller instruction is readable. Then the host decodes lr-4: a Thumb `bl` whose imm24 target,
     if it lands on the walk body or its function head, names the entry; otherwise the caller's
     section is named from the word. Next rung = that caller's trace.
  C2 TABLE-MINUS1        tbl_used_ok == 1 AND tbl_used == 0xFFFFFFFF.
     The count came out of the optimised-class table's -1 field. The fix is the table READER (dyld's
     reader feeding libobjc), not the walk and not the cache clamp.
  C3 NEITHER             pcc2 rows present, confirming conjuncts present, neither C1 nor C2.
     Report the tray; the frontier is named from the raw values, not from a fix.

  An absent row is NOT a cell. A capture without `xnu_live_pcc2_` rows is "no reading", not C3.
  Staleness is by content: entry mark present; in-log stamp when present. No filename-as-boot.

====================================================================================================
4. FALSIFIERS RECORDED NOW
====================================================================================================
  * If lr_m4 decodes as a `bx`/`pop`/data word, C1's premise (lr is a return address of a call) is
    false and the static reading's "lr is not a file VA + slide" becomes the frontier, not the caller.
  * If tbl_used != -1 while C1 holds, the -1 is not from the table header: 1036 static 3(a) is
    falsified and the count producer is elsewhere.
  * If the caller frame's 16 words do not contain sp+4 / sp+8 (r4, r6 anchors of 1035), the VLA frame
    is not the caller's -- read again before naming any function.