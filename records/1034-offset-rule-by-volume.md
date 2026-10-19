1034 OFFSET RULE, SETTLED BY THE VOLUME — card file offset of every shared-cache VA, read from the HFS
catalog (7z list/extract) instead of assumed
Written 2026-10-19 by the team lead. READ-ONLY forensics: no build, no press, no device command.
It SETTLES: (a) the card's cache layout and the file-offset rule (records/1031-caller-derivation.txt
FILE OFFSETS / (N9), records/1032-design-errata.txt header line, records/1034-carrier-static.txt 1/3.1/5
— the last could not read the volume); (b) the caller-side statements of 1031, which hold except for the
ADDRESS SHIFT below; (c) what the live pc executed (objdump-verified, 3).

====================================================================================================
1. THE MEASUREMENT
====================================================================================================
  $ 7z l -slt out/stage90/xnu_card_hfs.img
    Type = HFS ; Method = HFSX ; Cluster Size = 4096 ; volume root IOS7MIN
    Path = IOS7MIN/System/Library/Caches/com.apple.dyld/dyld_shared_cache_armv7
      Size = 315952666   Packed Size = 315953152   (Packed = round_up(size, 4096))
  $ 7z x  out/stage90/xnu_card_hfs.img 'IOS7MIN/System/Library/Caches/com.apple.dyld/dyld_shared_cache_armv7'
    sha256 of the extracted file = cad2df775e122c660238f341e74c163a2ea0ed261e85bfd3190de750cd9c0d2c
    == sha256 of /tmp/dyld-extract/dyld_shared_cache_armv7 (the 1031 source)  -- SAME FILE.
  The SAME cache is in /mnt/data/ios7-payload/{v1,v2}/ios7/rootfs.hfs; the live card differs from v2's
  rootfs by EXACTLY the 10 clamp bytes at 0x10183720 (cmp -l, re-run this session: 270022433..270022442
  are the only differing positions).

  THE CACHE HEADER IS AT CARD FILE OFFSET 0x455D000 and carries:
    0x455D000  dyld_v1   armv7      0x455D010 mappingsOffset 0x68  mappingsCount 3   csOff/csSize 0
    map0 vmaddr 0x2c000000 size 0x0c266000 fileOff 0x0
    map1 vmaddr 0x38268000 size 0x01ce0000 fileOff 0x0c266000
    map2 vmaddr 0x39f48000 size 0x022ed000 fileOff 0x0df46000     (0x20-byte entries, u64 fields)

  THE RULE:  card(VA) = 0x455D000 + (VA - map.vmaddr) + map.fileOff, for the map containing VA.
  For map0 that is exactly the 1031 rule — RIGHT: VA 0x37C26720 -> 0x10183720, where 1032's clamp is.
  There was NEVER a "0x1018325C base": C' = 0x1018325C is 0x45A4 BELOW the true site for VA 0x37C26716
  (0x10183716). The neighbouring reads 1031 "verified" were bytes of the SAME instruction stream.
  NOTHING on the host maps the card's cache at kernel/slab addresses 0x0Cxxxxxx except a kernel
  in-zone copy — no position in this file is a "kernel address" (records/1033-capture-supplement's
  test read 0xbc26474 and got 09 7c 00 29 — that IS the cache at slide 0, see 3).

====================================================================================================
2. WHAT IS AT EACH VA (pristine card bytes, rule of 1; live card = same + 1032's clamp)
====================================================================================================
  0x37C263CC  f0 b5 03 af 2d e9 00 0d 85 b0 80 46 ...  = getPreoptimizedClass prologue. CONFIRMED.
  0x37C26720  00 21 b1 eb 62 0f 08 bf f0 bd        = movs r1,#0; cmp.w r1,r2,asr#1; it eq; popeq
              (live card: 50 10 01 28 01 da f0 bd c0 46 = 1032 clamp). CONFIRMED.
  0x37C26756  f8 04 2b 44                              = str.w r2,[r4],#4 at +2 -> the 1030 WRITER store.
  0x37C26F90  04 c0 9f e5                              = ARM `ldr ip,[pc,#4]` — an interworking THUNK,
              so 1031's "lr is a direct call to 0x37C26F90" is a call to a thunk, not to a body.

====================================================================================================
3. THE LIVE PC: 0x3819D474 DECODES TO `ldr r1,[r1,#0x10]`, AND HERE IS WHY lr DISAGREED
====================================================================================================
  The card's map0 bytes AT 0x3819D474 - 0x577000 = 0x37C26474 are
    09 7c 00 29 f7 d0 04 eb 80 00 50 f8 04 0c dd 46  ...   (cmp r1,#9; bne; add.w r0,r0,lsl#2; ...)
  i.e. slide 0x577000 puts pc in the caller's SECOND walk — a "not a load", as 1033 read. That is a
  MEASURED property of the card at that slide. The device's pc is the instruction that FAULTED with
  far=0x10 and dfsr 7 (load). Under the slide the frame's REGISTERS point at the caller with ONE
  instruction-shift:
    r7 0x2bdaa0ac = sp+0x24   — the caller's frame pointer is reopened by `sub.w r4,r7,#0x18` (0x37C264C8)
    r4 0x2bdaa084 = r7-0x28   — the VLA#1 base: VLA#1 = fp - 0x18 - 4*N (0x37C264AA..B0)
    r11 0x2bdaa080 = r7-0x2C  — the second opening step (0x37C264BC..C4)
    r10 0x382e9c00           — loaded by `ldr.w r2,[r1,#0xc]; adds.w sl,r1,r2` (0x37C26430..38)
    r3 0x38300020            — a base the caller stores into the frame (0x37C26442/46)
    r1 = 0, r2 = 0xffffffff  — the slot at fp-0x30 = 0x2bdaa07c, which this record does NOT place
  Under INTERPRETATION S1 — image bytes at 0x37C264* are the same instructions ONE SLOT EARLIER
  (card 0x37C26472 `29 7c 00 f8` = ldr r1,[r1,#0x10]; adds r3,#0; cmp r1,r3) — the device's
  0x37C26474 is `ldr r1,[r1,#0x10]` with r1 = 0: far 0x10, dfsr 7 (read of a NULL object's fld@0x10).
  S1 ALSO makes the caller's own objc idiom land where it belongs: the call at unslid 0x37C2646E ->
  0x37C266C6 (thunk 0x37C266C8), r5 = count, the VLAs at 0x37C2644E.., the writer call 0x37C26462
  (byte 2 of card 0x37C26460 f0 00 9c f0 f4 42 -> f000 f942), matching 1031's disassembly.
  THE ONE FACT S1 DOES NOT EXPLAIN: the panic frame's lr 0x381959AF decodes on the card (slide
  0x577000) to `blx r3; ...` inside a different libobjc function — not a call site of the pc. So lr's
  own slide is 0x575000 by ITS bytes, pc's is 0x577000 by ITS bytes, and the two differ by 0x2000.
  That 0x2000 is NOT explained by this record. It is a USER pc (cpsr 0x30, user 0x10) and the kernel
  does not slide user text; dye/2nd-stage wouldn't either (this is not dyld's path). Whatever its
  cause, BOTH frames (wrp/cal/evf rows, abort print) report the same lr, pc, and registers, so the
  register file is consistent with the FAULTING instruction wherever it is.
  ⇒ this record says: the pc's instruction is NOT on THIS card at slide 0x577000. Any fix built from
    "the device executed the card's 0x37C26474" is building on a refuted premise — 1033's own warning.

====================================================================================================
4. CORRECTION TO 1031's CALLER DISASSEMBLY (addresses only; the semantics hold)
====================================================================================================
  Card bytes from the true start (2, objdump -Mforce-thumb --adjust-vma=0x37C263CC, verbatim listing):
    37c263cc b5f0 push {r4-r7,lr}      37c263ce af03 add r7,sp,#12    37c263d0 e92d 0d00 stmdb
    37c263d4 b085 sub sp,#20           37c263d6 4680 mov r8,r0         37c263d8 f646 4024 movw r0,#0x6c24
    ...
    37c2641e f000 f93b bl 0x37C26698   37c26422 4605 mov r5,r0        37c26424 2d01 cmp r5,#1
    37c26426 d10f bne 0x37C26448       37c26448 2000 movs r0,#0    37c2644a 2d02 cmp r5,#2
    37c2644c d31d bcc 0x37C2648A       37c2644E ebad 0485 sub.w r4,sp,r5,lsl#2
    37c26452 46eb mov fp,sp            37c26454 46a5 mov sp,r4      37c26456 ebad 0685 sub.w r6,sp,r5,lsl#2
    37c2645a 46b5 mov sp,r6            37c2645c 4650 mov r0,sl    37c2645e 4641 mov r1,r8
    37c26460 4622 mov r2,r4            37c26462 4633 mov r3,r6      37c26464 f000 f942 bl 0x37C266EC
    37c26468 2000 movs r0,#0           37c2646a 42a8 cmp r0,r5     37c2646c d20b bcs 0x37C26486
    37c2646e f856 1020 ldr.w r1,[r6,r0,lsl#2]
    37c26472 3001 adds r0,#1            37c26474 7c09 ldrb r1,[r1,#0x10]   37c26476 2900 cmp r1,#0
    37c26478 d0f7 beq 0x37C2646A        37c2647a eb04 0080 add.w r0,r4,r0,lsl#2
    37c2647e f850 0c04 ldr.w r0,[r0,#-4]  37c26482 46dd mov sp,fp    37c26484 e001 b 0x37C2648A
    37c26486 46dd mov sp,fp            37c26488 2000 movs r0,#0      37c2648A (join)
    37c2648A f857 1c2c ldr.w r1,[r7,#-44] ... 37c264C8 f1a7 0418 sub.w r4,r7,#0x18 ; mov sp,r4 ;
    37c264CE e8bd 0d00 ldmia.w sp!,{r8,sl,fp} ; 37c264D2 bdf0 pop {r4-r7,pc} ; 37c264D4 blx 0x37C26B20
  (1031's site A instruction list is present, correctly spaced; its VLA/writer semantics — r3 = VLA#2
  base = sp0 - 8*count, the writer's 4th arg — are CONFIRMED. 1031's lr "blx 0x37C26F90" is a call
  to a THUNK (2).)

====================================================================================================
5. THE FAULT SHAPE FROM HERE (a vector for the next rung; NOT a fix)
====================================================================================================
  (i)   The caller after the writer call zeroes r0, compares r0 with r5 (the count from
        0x37C26698), and with r5 < 0 unsigned `bcs` skips the walk: for count = -1 the caller walks
        NOTHING. So the 1032 clamp is not even needed to stop the CALLER's walk for a negative count.
  (ii)  The walk it skips (`ldr.w r1,[r6,r0,lsl#2]; adds r0,#1; ldrb r1,[r1,#0x10]`) reads an OBJECT
        field at +0x10 — the same family as the fault. Note the order: r0 is INCREMENTED before the
        byte load, so a NULL object there makes far = 0x10 (a NULL's +0x10), and the walk leaves.
  (iii) pc's own instruction on the card (`ldrb r1,[r1,#0x10]`, 0x37C26474) IS a load with that
        exact far IF its base is NULL — a plausible S2 reading (pc slid 0x577000, r1 = the walk's
        element = NULL: block2[r0] = 0 because the writer never filled it), which contradicts NOTHING
        measured and does not need the 0x2000. Under S2, far=0x10, r1=0 (the loaded slot at
        fp-0x30 holds 0), r2=0xffffffff (r5 = -1), r7=sp+0x24 — the caller's own frame. Both S1 and
        S2 name the SAME instruction family; neither is a fix and neither decides count's producer.
  ⇒ a 1034 probe must publish: the halfword(s) AT pc and AT lr (copyin through the task map), the
        caller frame's fp and VLA1/VLA2 bases, and the count (r5) reaching 0x37C26698 — before a fix.

====================================================================================================
6. FALSIFIERS
====================================================================================================
  F1  If a map1/2 VA read with 1's map rule is not coherent code and map0's is, the rule is wrong.
  F2  If 7z's extraction sha differs from /tmp/dyld-extract's (it does not).
  F3  If the live capture's wrp/cal rows disagree with 3's register placement (they do not; the
      supplement 2 lists them register for register).
EOF