# 1033 DESIGN — THE EVAL FRAME: read the 1032 launchctl[2] abort by value, and nothing else

Status: DESIGN ONLY. No fix. Nothing in this document has built, pressed, or written to the device.
Everything below that cites the tree is a `file:line` read made for this document (2026-10-18).
Companion documents: `docs/1031-design.md` (the house style), `records/1032-reading.txt` (the reading
1033 instruments), `records/1031-caller-derivation.txt` (the static derivation, quoted and checked in §6).

> **ONE PREMISE OF THE BRIEF IS WRONG, AND §6 CORRECTS IT BY VALUE.** The 1032 frame's `pc` was never
> modelled through a `sleh_undef` "+8 ⇒ address = pc − 8" rule — nobody in the record used that rule
> (`records/1031-caller-derivation.txt` has no `pc − 8` and no `sleh_undef`-pc sentence; the only "+8" in it
> is `sp0+8`, an alloca base). The defect is the **opposite** one, and the brief repeats it: the 1032 reader
> says "the printed pc's own instruction is `ldr.w r1,[r6,r0,lsl #2]`". **On the card this design was
> written against, `0x37C26474` is not an instruction boundary at all** — the halfword at
> `0x37C26474` is `0x0224` (`lsls r4, r4, #8`) in a stream that is not executable code (§6). So "works out
> to 0x10" and "not a faulting instruction" are **both true in that capture**, and a raw `pc` row alone
> cannot separate them. §2 adds one row that does (`evf_walk_pc_ok`: whether the NEXT frame's own return
> address is the `bl` whose target is this pc). §0.3 records the card-identity hazard this exposes.

## 0. WHAT 1032 READ, AND WHAT IS STILL UNKNOWN

### 0.1 The reading, quoted by value (`records/1032-reading.txt` §2–§3)

    cell FIX-PARTIAL (tools/check_1032_capture.py on recovered-unknown-arm-20261018-160331-last_kmsg.txt)
    launchctl[2] usermode data abort, EXC_BAD_ACCESS at 0x00000010   (Translation fault on page)
    r0=0x00000001 r1=0x00000000 r2=0xffffffff r3=0x3b6aa020 r4=0x2bdcf084 r5=0xffffffff
    r6=0x2bdcf088 r7=0x2bdcf0ac r8=0x30dd8575 r9=0x00001fff r10=0x3b693c00 r11=0x2bdcf080
    r12=0x00004000 sp=0x2bdcf088 lr=0x3b53f9af pc=0x3b547474 cpsr=0x00000030
    xnu_live_abt_vmfkrv=1  vmfkrv_dfsr=0x00000007  prot=read  far(trunc)=0x0  pid=2
    slide from `IOS7LAB cache mapping 0 nav=2f921000` = 0x3921000  ->  pc unslid 0x37C26474,
    lr unslid 0x37C1E9AF, r3 unslid 0x37D89020.

The 1030 fault is GONE (a WRITE at the stack region's exclusive top, writer pc `0x37C26756`): no `wrp` row
has `r4 == userstack`. The new failure is a **READ** (dfsr type 7, `dfsr & 0x800 == 0`) at a far that
`vm_fault` could not map (`code == KERN_INVALID_ADDRESS == 1`, `osfmk/mach/kern_return.h:75`), after
`launchd[1] has started up`, and the boot ends with "The System bootstrapper has crashed: Bus error: 10"
in a NON-RETURN (runner exit 2, USB reader zero bytes, operator power press).

**What the probe rows can and cannot say, by construction.**

- `far(trunc)=0x0` is **not** "two definitions of 0". The kernel prints `vm_map_trunc_page(dfar)`
  (trap.c:850, and 1031's `cal_far` at trap.c:973 is the same truncation), while the message prints `dfar`
  raw (trap.c:1031). `dfar = arm_ctx->far` (trap.c:538) — the raw DFAR register
  (`ARMREG_READ_INLINE(dfar, "p15,0,%0,c6,c0,0")`, osfmk/arm/proc_reg.h:517). So the two rows are ONE
  value at two widths: `dfar == 0x10` prints as `0x00000010` in the message and `0x00000000` in every
  truncated row. **The truncated row cannot discriminate anything.** 1033 reads `arm_ctx->far` untruncated.
- cpsr `0x30` = User mode, **T bit set** (bits 5:4 = `11`), so the pc is a Thumb address.
- The `wrp` group and the `cal` group repeat `arm_ctx` verbatim; they are one reading, not three.

### 0.2 The three candidate paths, and the exact row that separates each

    U1  the access really is [0x10] (NULL + 0x10) in launchctl[2], on a TRUE slide-0 mapping, and the
        kernel's exception-return pc IS the faulting instruction.  The NULL is a VALUE in a register or a
        stack slot -- the obvious one being a saved lr slot, `*(sp + 0x10)` (a `push {r4,r5,r6,r7,lr};
        add r7,sp,#12` frame saves its caller's lr at sp+0x10; the 1031 writer prologue 0x37C266EC has
        exactly that shape, records/1031-caller-derivation.txt (1)).
        Separators :  far_raw == 0x10 (positive),  slot10 word (the NULL's identity),
                      ptr_word (the guarded user read at 0x10 succeeds? it must NOT).

    U2  the fault belongs to a DIFFERENT image base: the slide 0x3921000 is not the fault's image's slide,
        so "unslid pc" is an arithmetic artifact.
        Separators :  far_raw == 0x10 (image slides do not slide 0x10 - a real dfar of 0x10 REFUTES U2;
                      an image-relative far that slid would name the image's slide by value),
                      lr_slot (the word ENDING at lr must decode as bl/blx, §6 -- an ARTIFACT may).

    U3  pc is a RETURN address, not the faulting pc, and "pc - far == 0x18" only LOOKS like the
        undefined-instruction +8 offset (0x10 + 8).  Then far is not 0x10 and nothing here names the NULL.
        Separators :  far_raw (a real dfar is the faulting access, not pc-relative),
                      evf_walk_pc_ok (the NEXT frame's return address is the bl into THIS pc),
                      lr_slot (the word ending at lr is not a call instruction).

**Which of these 1033 can separate, and how.**

- **Raw `far` separates all three as a SINGLE NUMBER.** A hardware data abort's DFAR is not derived from
  pc: nothing in the ARM ARM or this kernel computes it (`vm_fault(map, vm_map_trunc_page(dfar), ...)`,
  trap.c:830, uses it as the fault address). `far == 0x10` ⇒ U1's premise is real and U3's "the +8 offset
  is being misapplied" is dead as a *far* claim. `far == (pc_relative something)` ⇒ U3. Any value that is
  an image-relative address ⇒ U2. **The design publishes the raw value and does not classify it** (§2.4).
- **1033 CANNOT separate "the pc is the faulting instruction" from "the pc is a return address" by the
  pc alone** on this device's byte state, because a pc that is a `bl`'s target AND a valid instruction
  boundary is reachable in both worlds. It separates them **indirectly and decisively** by the caller's
  own return address: on ARM the `bl` at a caller return address R (T bit set ⇒ R is even, R-2 is the `bl`)
  encodes a displacement; `evf_walk_pc_ok = ((b | h << 11) << 1) + pc == R` (decoding: bits `1:0` H =
  `(b >> 15) & 1`, `(b >> 14) & 1` → H<<11, S/I1/I2 at bits `12:10`, imm10 at `9:0`, imm11 at `15:0`).
  If a live frame's return address points AT the faulting pc, the pc was called and is an instruction.
  If the "next frame" is a fiction (the slot at sp+0x10 does not hold a valid caller frame), `walk_ok = 0`.
- **1033 CANNOT test the claim "`ldr.w r1,[r6,r0,lsl #2]` at 0x37C26474 is MAPPED" by the fault itself**:
  the 1032 capture is exactly the evidence that it faulted, so re-asserting the mapping under another
  slide is the `[[mi4-one-value-two-definitions]]` defect. 1033 instead publishes the register file the
  computation would use and the fault's own far; a reader who wants "is this instruction the fault" reads
  `evf_walk_pc_ok`, not a re-derivation.

### 0.3 The card-identity hazard (a §5 risk, stated here because it changes §1's reading)

1032's press certified `device 0x10183720 = 5010012801daf0bdc046` (`records/1032-press-read.txt` §3). At
16:21 on 2026-10-18, this session read the card on disk:

    out/stage90/xnu_card_hfs.img  sha256 c9b9080de2a1de00...  == rootfs.hfs  c9b9080d...  (PRISTINE)
    0x10183720 = 00 21 b1 eb 62 0f 08 bf f0 bd   -- the count=-1 OLD guard, NOT 1032's NEW bytes
    out/stage90/xnu_arm_entry.bin sha 49031dcb (1031's arm)

That card is **1032's premise** (far was 0x10 *without* the clamp in force). Against it the written
1032 reading's pc claim holds (§6, "pristine card" stream). If the press had booted a card that also
carried the clamp, the pc could have been at the NEW patch's `0x37C26720` — it is not. **But which card
was on the device during the press is not knowable from the host** (§7 of the reading records the same
concern), and it matters for exactly one thing: *which slide's bytes sit at the faulting pc*. 1033
resolves that by VALUE instead of by assuming: it captures the stage's OWN `IOS7LAB cache mapping 0` slide
at the moment of the fault (`evf_cachemap_slide`), and it publishes `evf_lr_slot`/`evf_ptr_word` from
live memory, neither of which depends on any card-side assumption.

## 1. WHAT 1032 LEFT UNDETERMINED (the question 1033 answers)

1032 read: launchctl[2] took a read fault at an address the kernel reports as `0x10`; the truncated `far`
row hid whether that address is 0x10 or 0; the frame's pc sits 0x18 above it — a number that is the
undefined-abort `+8` offset applied to 0x10, OR a coincidence. The host cannot decide this from the rows
because (a) `far` is truncated in every probe row, and (b) the "which instruction is at pc" argument needs
the exact bytes of the slide that was live, which the reading cannot certify (§0.3) and whose disassembly
lane (records/1031-caller-derivation.txt) claimed an address map that this card does NOT carry (§6.2).

    THE QUESTION 1033 ANSWERS, IN ONE SENTENCE:
      At the launchctl[2] abort, what is the RAW DFAR, what word does the frame's own sp+0x10 hold, and is
      the frame's pc the target of a `bl` from the frame's caller?

    THE QUESTION 1033 DOES NOT ANSWER: WHERE the NULL comes from.  It names the dereferenced WORD (a value)
    and the address it was read from; the code that produced that word is a later rung's static job.

## 2. THE INSTRUMENT: `STAGE90_XNU_EVAL_FRAME`, one trap.c block

### 2.1 The site, and why the identifiers are visible there

**Site — `osfmk/arm/trap.c`, INSIDE the 1025 failure arm (`#if STAGE90_XNU_USTACK_PROBE`,
trap.c:842 … `#endif /* STAGE90_XNU_USTACK_PROBE */` trap.c:998), AFTER 1031's block's own
`#endif /* STAGE90_XNU_CALLER_PROBE */` (trap.c:997) and BEFORE the 1025 `#endif` (trap.c:998).**

In scope at that point, verified by reading the enclosing code:

| identifier | why it is in scope | trap.c |
|---|---|---|
| `dfar`, `dfsr` | `uint32_t dfsr = 0, dfar = 0, …` declared at function scope | 524; set 538-539 |
| `arm_ctx` | `abort_information_context_t *arm_ctx = (abort_information_context_t *)context;` | 528-529 |
| `thread`, `map`, `code` | function scope / this `case`-block scope | 530, 816-817, 829-833 |
| `_cal_far` | **NOT VISIBLE** — 1031's block is a braced `{ … }` (trap.c:967-996); its `_cal_far` (trap.c:973) is a block local | — |

⇒ **1033 computes its own raw value from `arm_ctx->far`** (the same register `dfar` was loaded from at
trap.c:538). The brief's hint that `_cal_far` "is in scope after the 1031 block" is wrong; the block's
braces close at trap.c:996. (A re-staged 1031 block that declared `_cal_far` outside its braces would be a
different edit; 1033 does not need it, and the patcher asserts the name never appears: `tools/patch_d13_eval_frame.py`
selftest, "the eval block never names `_cal_far`".)

The struct is `abort_information_context_t { uint32_t r[13]; sp; lr; pc; cpsr; fsr; far; }`
(osfmk/arm/misc_protos.h:43-51) — `far` is the raw DFAR word. **cpsr** is reachable only as
`arm_ctx->cpsr`; the local `cpsr` at line 524 is filled later in the non-resident path and must not be used.

### 2.2 Output discipline (see §4 for the byte arithmetic)

- `printf` (osfmk/kern/printf.c:783 → `_doprnt(..., conslog_putc)` → `cnputc` always at trap.c's point,
  and `log_putc` into the BSD msgbuf **only when `debug_mode == 0`**, printf.c:765-771) is the primary
  channel. Its rows land in the BSD log buffer that Android's `last_kmsg` reads (subr_log.c
  `log_putc_locked` writes `msgbufp` and sets `logentrypend`). The boot continues after our printf, so the
  buffer is flushed.
- `kdb_printf` / `kdb_printf_unbuffered` (declared osfmk/kern/misc_protos.h:138, 142-143; defined
  printf.c:830/852) go to `consdebug_putc*` — console + debug ring + PE — and **not** to the BSD msgbuf, so
  they do not appear in `last_kmsg` and need no flush. **Optional only**, used for ONE marker per burst:
  `kdb_printf("EVF_BURST_BEGIN seq=%u\n", ...)` and `EVF_BURST_END` — if those markers are absent from the
  console capture while `evf_` rows are present in last_kmsg, the RAM-console channel is the one that
  dropped, which is a reading of the instrument, not of the device.
- **No sleeps, no busy-waits** — the boot's own end (launchd crash → Bus error → the resident run) ends the
  run; the watchdog is not to be fed against.
- **Deferred print** (the design change vs a print-inside-sleh): the print happens on the thread's NEXT
  trap (its exception return), not inside `sleh_abort`, because inside sleh the preemption counter is held
  (`disable_preemption()` runs at `ml_set_interrupts_enabled(TRUE)`, trap.c:1084, before the user psr is
  installed; the full-printf path also takes `printf_lock`, printf.c:681). Outside sleh, preemption-off
  suppresses preemption only, not interrupts, and the locks are the ordinary printf locks.
- **The evf rows are NOT under `STAGE90_XNU_USTACK_PROBE` as a switch**, but the block physically nests
  inside it (the only insertion point where the abort facts exist). The record must therefore carry
  `USTACK_PROBE=1` — press_1033.sh's inherited gate does.

### 2.3 The rows (names final; every one unconditional — the 1026 lesson)

    xnu_live_evf_session=1            boot-session key printed at first entry (see 2.5)
    xnu_live_evf_seq=<n>              fault index (this boot); SAME idx on every row of a burst
    xnu_live_evf_pid=<pid>            thread->task->bsd_info ? proc_pid : -1
    xnu_live_evf_pc=0x%08x            arm_ctx->pc      (SLID user VA, Thumb)
    xnu_live_evf_lr=0x%08x            arm_ctx->lr      (SLID)
    xnu_live_evf_sp=0x%08x            arm_ctx->sp
    xnu_live_evf_cpsr=0x%08x          arm_ctx->cpsr    (0x30 = Thumb)
    xnu_live_evf_far_raw=0x%08x       arm_ctx->far     *** UNTRUNCATED ***
    xnu_live_evf_far_trunc=0x%08x     vm_map_trunc_page(arm_ctx->far)   (what 1032 printed)
    xnu_live_evf_dfsr_raw=0x%08x      dfsr
    xnu_live_evf_fault_code=<n>       code (KERN_INVALID_ADDRESS == 1)
    xnu_live_evf_pc_minus_far=0x%08x  (u32)(pc - far_raw)             raw, uninterpreted
    xnu_live_evf_lr_minus_sp=0x%08x   (u32)(lr - sp)                  raw
    xnu_live_evf_slot10=0x%08x        *(uint32_t *)(sp + 0x10)        see 2.5 for the read
    xnu_live_evf_slot10_ok=<0|1>
    xnu_live_evf_slot14=0x%08x        *(uint32_t *)(sp + 0x14)   (+ok)  (the writer-frame shape's r5 slot)
    xnu_live_evf_slot18=0x%08x        *(uint32_t *)(sp + 0x18)   (+ok)  (its r6 slot)
    xnu_live_evf_ptr_word=0x%08x      *(uint32_t *)(far_raw & ~3U) + (far_raw & 3) byte select; +ok
    xnu_live_evf_lr_slot=0x%08x       *(uint32_t *)(lr & ~1U) - 4   (the word ending at lr; 2.5-copied
                                                                      with a scratch-word trick), +ok
    xnu_live_evf_caller_r=<0..12>     the NEWER uss register file's r (its r11..r12 are the caller's
                                      pre-call sp/fp where the frame exists), only when newer_ok
    xnu_live_evf_walk_fr=0x%08x       r7 of the walk frame (the caller's fp, when newer_ok)
    xnu_live_evf_walk_lr=0x%08x       *(fr + 4)
    xnu_live_evf_walk_pc=0x%08x       *(fr + 8)                 (the caller's return address, R)
    xnu_live_evf_walk_ok=<0|1>
    xnu_live_evf_walk_pc_ok=<0|1>     R != 0, R even, and the bl at R-2 targets arm_ctx->pc (2.5)
    xnu_live_evf_read_src=<n>         0 = copyin, 1 = uss shadow, 2 = copyin failed (ok=0)
    xnu_live_evf_shadow_src=<n>       0 = uss shadow, 1 = copyin
    xnu_live_evf_ustack=0x%08x        xnu_live_abt_proc_ustack(thread->task->bsd_info)
    xnu_live_evf_cachemap_slide=0x%08x  see 2.5 (stage's own mapping table; absent ⇒ row absent)

**RE-STAGED 1031 rows (SITE DISAMBIGUATION).**  The `cal_*` rows print beside every evf burst because
1031's block is re-staged by the SAME build (§2.6): `xnu_live_cal_*` (trap.c:974-995, 17 rows) and
`xnu_live_abt_vmfkrv*` (trap.c:849-855), plus `xnu_live_wrp_*` (14 rows) and `xnu_live_rdr_*`. The
**site row 1032 §6 asked for and no released probe carried** is `*(uint32_t *)(arm_ctx->sp + 0x10)` —
published here as `evf_slot10` (and, for the writer-frame shape only, `evf_slot14/18`). It holds
`0x37C26468` (Site A's return) or `0x37C26554` (Site B's) when the frame is the writer's; on the 1032
frame it holds the value `0x37C2646C` if U1's "saved lr = NULL's neighbour" shape is real — §4's cells
key on it.

### 2.4 Where the comparison happens — the division, stated

- **The kernel publishes RAW values only**: `far_raw`, `pc`, `dark…`, `slot10`, `walk_pc`, and two
  one-sided DECODES (`walk_pc_ok` — a branch decode, not a classification; `lr_slot_ok` — a call decode).
- **The checker applies every predicate** (`far_raw == 0x10`, `pc - far == 0x18`, `lr - far == 0x2A`,
  slide = `pc_unslid_known - pc`, …). Reason: §0.3 — the kernel cannot know which slide the user's pc
  belongs to without a card assumption, and the 1031 derivation's address map was wrong once already.
  A predicate in the kernel would hard-code a card fact into the image that is being measured.
- `pc_minus_far` is published **as a raw u32 difference** because `pc` is a SLID user VA and `far_raw` is
  an UNSLIDED raw VA (0x10 is not slid; a real image-relative far would be). The checker compares it only
  to constants, never to a slid quantity.

### 2.5 The mechanics (what makes the rows REAL, not asserted)

1. **`sleh_abort` (INSTRUMENTED mode, preemption-off, no printf)** records the abort into the faulting
   thread's own `thread->machine`: pc, lr, sp, cpsr, fsr, far, `dfsr`, `code`, pid — the same shape as the
   existing per-process `"Abort happened but not our thread"` record in this tree (a field group written
   under the trap, read by another thread). **Mutation: none of the user's state.**
2. **Reading user memory from the trap.** The eval read runs on the thread's NEXT trap: its exception
   return, or any later sleh. There `__abort_count == 0` (trap.c:828 decrements before the user-abort
   case), so a nested data fault is NOT the "recursive abort" fatal (trap.c:558-559). Still, a copyin that
   faults may be wired by the kernel's own fault handler in interrupt context and reach `sleh_fatal_exception`
   ("abort while in interrupt context", the else-branch at trap.c:~1600s); therefore every user read is
   **guarded**: (a) the read runs **first**, before anything else in the trap; (b) `ml_set_interrupts_enabled(TRUE)`
   — the user read is a user-mode access in the agent's model and copyin on a USER thread expects it (the
   PTE-wiring path reads the PTE via `pmap_get_mapping` in trap.c:742-759 and ends in a retry `return`,
   trap.c:805, or a user exception, trap.c:759); (c) if the first read's `code` comes back non-success,
   the SECOND read (the one that can panic the plane) is **not attempted**, and every dependent row prints
   `_ok=0`. **A wrong guess costs the plane at the first read, and that is a pre-registered cell
   (`EVF-NOPLANE`), not a surprise.**
3. **The shadow alternative (safe read by construction).** In this tree a user thread's exception return
   has no user stack to return to until the "wedged" state is handled (the entry-side prelude the 1031
   `stmdb sp!, {…}` frame and the `entry_epilogue` notes describe). 1033 reads through
   `thread->machine.uss` (the per-thread user-stack shadow the exception path papers) **when the address
   lies inside it**; each row says which source it came from (`evf_read_src`, `evf_shadow_src`). A row
   read from `uss` is a snapshot, not a live read — the checker must weigh `sp+0x10` against it knowing
   the prelude may have diverged (records/1032-reading.txt §7 saw a slot change without a host write).
4. **The "next frame".** On this evidence the faulting thread is inside a trace/break trap's sleh; the
   frame 0xFC ABOVE it (lr `...F9AF`, walk_fr `...F0AC`) is a `push {r4-r7,lr}; add r7,sp,#12` frame — both
   the writer's shape. **Unknown and un-asserted: whether that frame belongs to the faulting thread itself
   or to a thread it signalled.** The row set publishes the frame's register file with a `newer_ok` gate
   (cpu_active_thread == our thread, or the uss's pc != our pc at the trap) and never averages it into row
   (2)'s values. `walk_pc_ok` is computed on the OUTER record's lr only if `newer_ok`; otherwise on
   `*(sp+0x14)` as a `bl`'s own return address **only when `cpsr` says handle mode where `bl` does not
   store lr** — i.e. never by guesswork.
5. **Bounded.** The deferred print emits ONE burst per missing thread and the record holds only the most
   recent abort; `evf_cancel` counts suppressed duplicates. **No walk of the wait queue**, no
   `thread_reference`, no thread lifecycle interaction (the brief's "walk chain" design is deliberately
   not taken: a refcount taken on the event's waiter can free under a consumer that vm_faults below it).
6. **The slide, captured from the stage's own table** — `evf_cachemap_slide`: the stage already prints
   `IOS7LAB cache mapping 0 nav=...`; 1033 reads the same mapping entry the stage reads (a 0x20-byte row
   in the dyld cache header, `vm_shared_region.c` side) and prints nav as `%08x`. If the row is absent the
   checker falls back to the pmap's slide, never to a constant.

### 2.6 The RE-STAGE constraint ([[mi4-one-file-many-rungs]]) — non-negotiable

`trap.c` is edited by 994/1020/1025/1026+1027/1029/1030/1031 and now 1033. The 1033 patcher
(`tools/patch_d13_eval_frame.py`) is applied **in the same build stage as** caller/reader/writer/abt-entry/
ustack — it must NOT be run on a tree that has been `git checkout`-ed (that silently reverts the older
edits; the symptom is a LATE build failure that looks like something else). **Every** trap.c patcher's
`TRAP_ALLOWED_IF_IDENTIFIERS` / `ALLOWED_IF_IDENTIFIERS` set must gain `STAGE90_XNU_EVAL_FRAME`. As of this
writing the tree already carries it in: `tools/patch_d13_undef_raise.py`, `tools/patch_d13_dyld_witness.py`,
`tools/patch_d13_ustack_probe.py`, `tools/patch_d13_reader_probe.py`, `tools/patch_d13_abt_entry_probe.py`
(set at line ~218), `tools/patch_d13_writer_probe.py`, `tools/patch_d13_caller_probe.py`,
`tools/patch_d13_h2_stack_headroom.py` (kern_exec.c side), **and the new patcher must also stage
`bsd/kern/kern_exec.c` only to keep its own namespace proof consistent — 1033 adds NO kern_exec.c code**
(no accessor: every proc fact it needs, `user_stack`, is the existing `xnu_live_abt_proc_ustack`). The
OFF proof (switch unset ⇒ staged tree compiles byte-identical) is the patcher's `--verify-off` /
selftest, not a claim. The switch's build channel is the GLOBAL `DEFINES` array
(`tools/build_xnu_arm_kernel.sh`, env-exported), never `XNU_KERNEL_EXTRA_DEFINES` (records/1020-build-defect.txt).

## 3. WHAT EACH READING MEANS (the pre-registered cells for `tools/check_1033_capture.py`)

**Fail-closed rule, verbatim:** an ABSENT row means the instrument did not run (→ `EVF-MISSING` /
`EVF-NOPLANE`), NEVER a negative. A cell is decided only by values PRESENT in a capture NEWER than the
press's boot epoch. The checker is modelled on `tools/check_1032_capture.py`: a `KEYS` tuple listing
**every** emitted `evf_*` row (too few keys SPLITS the group — the 1030 defect),
`group_rows` on `xnu_live_evf_seq` (not on `_pc`, so a burst missing its last row is still one group), a
`--selftest` that builds one synthetic capture per cell and asserts each fires, and a print-only mode
(`--predicted pc_minus_far=0x18 ...`) that prints the U1-vs-U3 expected rows (§8) so the pre-registered
predictions can be compared by the same parser.

    EVF-U1-TRUE      far_raw == 0x10 AND slot10_ok == 1 (or ptr_word_ok is declared and is NOT the fault)
                     AND NOT (pc - far_raw == 0)           (a data abort's pc is the instruction)
                     AND (walk_pc_ok == 1 OR walk_ok == 0 while lr_slot_ok == 1)
                     => the faulting access IS [0x10]: NULL+0x10 in launchctl[2], and its pc is the
                        faulting instruction.  The dereferenced value is print READS the word AT 0x10 only
                        if it is mapped; on this shape it is NOT (ptr_word_ok == 0) and slot10 NAMES the
                        NULL's neighbour instead.  Name the caller deref pattern from lr_slot/walk rows.
    EVF-U1-SUSPECT   far_raw == 0x10 AND (walk_pc_ok == 0 AND walk_ok == 1)
                     => the access is [0x10] but the pc is not shown to be an instruction (a frame that
                        does not point at it).  NO fix; the next rung is a static disassembly naming the
                        instruction at the SLID pc from the stage's own slide.
    EVF-U2-MISTAKE   far_raw != 0x10 AND far_raw != 0 AND (far_raw - cachemap_slide) is a plausible image
                     base (i.e. cachemap_slide is NOT the slide that maps far) => the 1032 pc/far pair is
                     inconsistent with any real faulting instruction.  NO fix.
    EVF-U2-SLIDE0    far_raw == 0x10 BUT evf_cachemap_slide == 0  => 0x10 is a genuine VA in an image at
                     slide 0; the 1032 "slide 0x3921000" then does not describe this fault's image.
    EVF-BOILERPLATE  NO evf group AND launchd[1] started AND the cal group ABSENT (no fault at all)
                     => 1032's crash path died EARLIER (or later) this boot; the frame is unreproduced.
                     NOT a pass, NOT a negative: re-preregister.
    EVF-CAL-ONLY     NO evf group but a cal group prints => 1033's block did not run on a fault the
                     instrument saw (a build defect: EVAL_FRAME not in the pool) => NO READING.
    EVF-PANIC        a panic is in the capture => REGRESSION (the guard read of 2.5(2) is implicated).
    EVF-NOPLANE      no capture; or the run's echoes show `xnu_live_evf_read_src=2` on the FIRST burst
                     and nothing after => the plane died on the guarded read; fall back to the uss-only
                     variant (read_src 1) re-pressed with a record edit, not with a code guess.
    EVF-MISSING      no launchd, no controls, no panic (fail closed); or evf rows truncated mid-burst by
                     the console window (burst BEGIN marker present, END absent) => re-read, do not judge.
    EVF-REGRESSION   the 1023 storm (0x40083008 / abt_pcn >= 0x8000), or launchd with no
                     trap24/port_construct(result=0) controls.

**The selftest's fixtures** are built from the patcher's REAL row order (the patcher emits them, so the
fixture generator reads `tools/patch_d13_eval_frame.py`'s `TRAP_BLOCK` order) and include: a complete
U1 burst; a U1 burst missing `walk_pc` (→ U1-SUSPECT or MISSING, never U1-TRUE); the 1032 frame verbatim
(→ must NOT fire U1-TRUE if far_raw is 0x0); a panic; an empty console.

## 4. THE 1033 PRESS: build, park, press, recovery

### 4.1 Build — `scripts/build_1033.sh`

Models `scripts/build_1032.sh` + `scripts/build_1031.sh`. **1033 DOES rebuild the kernel** (the switch
moves trap.o), so it carries 1032's lineage: the record's whole switch set VERBATIM + `STAGE90_XNU_EVAL_FRAME=1`
(channel: global `DEFINES`), re-stages 994…1031's trap.c patchers in ONE stage (§2.6), then
`build_1032.sh`'s card (build_root_volumes.sh --real + 10 bytes) so the press serves the world 1032 made.

    gates, in order (each one is a REFUSAL, not a warning):
      0   the record is 1031/1032's arm: USTACK/ABT_ENTRY/H2/READER/WRITER/CALLER =1, VM_MAX_SPLIT=1,
          IOS7_TRAPS=1, GLOBAL_FIX in EXTRA (records/1020-build-defect.txt), GLOBAL_FIX byte-fingerprint
          on pmap.o (kernel_pmap x3, flushID/flushID_ASID 1/1 -- the 1015b by-value check)
      0a  the staged trap.c carries exactly ONE `#if defined(STAGE90_XNU_EVAL_FRAME)` and ONE matching
          `#endif`, nested after 1031's `#endif` and before 1025's
      1   `tools/patch_d13_eval_frame.py --apply` then `--check`, and the patcher's `--verify-off`
      2   pool rebuild; trap.o carries each evf row's format string (`grep -qa P <(strings X)` -- SIGPIPE),
          and the parent rows survive
      3   the pool's source record (out/xnu_kernel_src_d13.sha256) names the staged trap.c's sha256
      4   the entry link; the LINKED ELF carries the evf rows AND the parent rows; 1024 ceiling,
          1023 row 24, 1020 raise, 1021d NEON-free: all `--expect` PASS
      5   the card: exactly 10 bytes from the pristine rootfs AND == 5010012801daf0bdc046 at 0x10183720
      6   `tools/check_1033_capture.py --selftest` PASSES (a checker that cannot fail is not a check)

### 4.2 Park — `scripts/park_1033.sh`

Mirrors `park_1032.sh`: the new arm name MOVES (**`armed-d13-$(sha256sum out/stage90/xnu_arm_entry.bin | cut -c1-8)`**
— a new sha8, because trap.o changes). The park carries:
- the 13 kernel/payload members of the new arm (byte-identical to `out/stage90`, re-read by SHA256SUMS);
- `park_d13_eval_frame.py` (a `sed`-derived copy that requires explicit input paths — the 1032 park-copy
  discipline) and `check_1033_capture.py`;
- **`park_cache_libobjc_count.py` and `check_1032_capture.py` at their 1032 BYTES** (the card keeps
  them: the `card_*` lines name the 10 patch bytes, not these two tools). The 1032 press record measured
  that a file named in a set must exist in BOTH the park and out/stage90 or `resolve_arm_set.sh` refuses;
  **new set name or not, do not regress that: place the same by-BYTE 1032 copies under the 1033 name in
  out/stage90** (sha `7fc81e6c…` / `c135318c…`, records/1032-press-read.txt §2). This is the one place
  §4.2 knowingly carries an unproven mechanism (it was a hypothesis there, not a measured fact).
- `records/revert-set.txt` gets the new set BY HAND before the press, including a
  `role=1033-eval-frame;instrument-only` tag per file and the card line
  `card_patch=0x10183720=5010012801daf0bdc046` (a revert that omits the card would boot 1033's kernel
  against the OLD guard and re-measure 1032's premise).

### 4.3 Press — `scripts/press_1033.sh` (already drafted in the tree; §7 lists its defects)

Order: (0) record is 1033's arm and carries every inherited switch; by-value: GLOBAL_FIX fingerprint,
trap.c source-record match, evf rows in trap.o AND the ELF, parent rows present, card holds 1032's guard,
`--check` anchors, exactly 10 bytes differ from rootfs; (1) the card is NOT rebuilt here; (2) hardware gate
(`adb` has `4a2fe00b`; `33e80afe` absent); (2b) `dd` the card to `/dev/block/mmcblk0p25` (userdata head,
offset 0), then read the 10 bytes back OFF the device and require `5010012801daf0bdc046`; (2b'') spot-read
the cache site `0x10183720` and the guard; (3) arm the USB reader BEFORE the send, `fastboot boot -s
4a2fe00b out/stage90/stage90-qcdt.img` — **NEVER flash** — stamp `_BOOT_EPOCH=$(date +%s)`, bounded wait,
`set +e` around `wait` ([[mi4-unguarded-wait-aborts-resident-press]]); (4) recovery:
`scripts/recover_last_kmsg.sh --read-only` once Android is up; (5) staleness guard: capture mtime > boot
epoch, else print NO READING and stop; then `python3 -I tools/check_1033_capture.py <capture>`.

### 4.4 The two clocks

| clock | source | used for |
|---|---|---|
| boot epoch | `_BOOT_EPOCH=$(date +%s)` printed in step 3, BEFORE `run_and_capture.sh` | the staleness guard: capture `stat -c %Y` MUST be ≥ it (records/1028-press-read.txt, [[mi4-stale-slot-impersonates-a-reading]]) |
| capture mtime | host `stat -c %Y` of `out/stage90/captures/recovered-*-last_kmsg.txt` | compared to the boot epoch; the device's own clock (2026-01-04 on the stock rom) is never used |

A non-returning resident rung keeps NO `last_kmsg` of its own ([[mi4-last-kmsg-reader-carrier]]); the
capture arrives only after the operator's power press + stock-Android boot. **Expect the first recovery
attempt after a non-return to be STALE** (exactly the 1032 outcome) — that is correct behaviour, not a
reading.

## 5. RISKS

1. **Card overwrite defect.** `tools/build_root_volumes.sh --real` now unlink-then-copies with a sha256
   equality proof (238b955), and `tools/patch_cache_libobjc_count.py --check` has the `[1a]` content anchor
   on the site bytes. **Still check BY VALUE after every build that the card differs from rootfs in exactly
   10 bytes at 0x10183720** — §0.3 is a live example of the card reverting to pristine.
2. **Card identity at press time.** The 1032 press certified the NEW bytes on the device; the host's copy is
   PRISTINE. Either way 1033 must `dd` the card it built and read back the 10 bytes (§4.3 2b). A run where
   the device read-back fails is NOT pressed.
3. **RAM-console window budget (arithmetic).** The brief cites `CONSOLE_WINDOW_MS`/`DEBUG_RING_TEXT` in
   `osfmk/kern/printf.c`; **grep of this tree finds neither symbol in printf.c** (it is 900 lines; its
   output path is `_doprnt → conslog_putc → cnputc / log_putc`, printf.c:643-795, with no per-writer
   window). The bound the design USES is therefore the measured one: 1031's 31 rows per fault printed
   fully in the 1032 capture, the RAM-console text rate ~120 B/s, and the last press's capture of
   1,655,347 B read through last_kmsg within the operator's turnaround (~35 min). The new burst is
   **≤ 45 rows × ≤ 44 B ≈ 1.98 KB worst case, normally ≈ 1.3 KB**, i.e. ~11-17 s of console at 120 B/s,
   versus the ~2 minutes the boot needs to reach launchd — **the burst cannot widen the window beyond the
   boot's own end**; the budget is not the risk, the read of (2) is.
4. **The guarded user read (§2.5.2).** A wrong assumption panics the plane on the FIRST read. Mitigated by
   reading first, from a known-mapped region (the user stack), with `read_src` rows, and a pre-registered
   `EVF-NOPLANE` cell plus the uss-only fallback.
5. **launchctl crash timing.** The abort is after `launchd[1] has started up`; if 1032's clamp makes the
   crash LATER than the state where the deferred trap fires (it fires on the thread's next trap), the
   burst may never print → `EVF-MISSING`, and the fallback is the inside-sleh burst under
   `ml_set_interrupts_enabled(TRUE)` with the kdb marker, accepted at the printf_lock cost.
6. **Operator-only power press.** The device is dark after a non-return; only the operator can power-press
   ([[mi4-device-dark-needs-power-press]]). 1033 cannot be re-pressed without them.
7. **Not changing.** No fix is selected by 1033: no libobjc bytes beyond 1032's 10, no kern_exec.c code,
   no allocation, no sleep. The error this avoids is **choosing a fix blind** — 1032's clamp was itself
   selected on a model that this design shows is not discriminated by the rows it published.

## 6. OPEN QUESTIONS FOR THE DERIVATION — and what the bytes actually say

### 6.1 Does the 1031 derivation use a `+8 ⇒ pc − 8` rule?  NO.

`records/1031-caller-derivation.txt` was read end to end for this document. It never models the fault pc
through `sleh_undef`; the only "+8" in it is `sp0+8` (the alloca base made positive by count = −1, (F)/(I)).
Its pc treatment is `lr = 0x38b4a9af → unslid 0x37C1E9AF` and the writer's `pc = 0x37C26756`, both as
**faulting addresses**. Its ONE pc-shaped error is elsewhere: (G) says of `lr` "0x37C1E9AF is a STALE value
inside getIndex (0x37C1E950, returns via `pop {..,pc}`, does NOT restore lr)"; **a `pop {..,pc}` does not
"not restore lr" — it restores it from the stack slot `getIndex` itself pushed at its entry**, so
`lr = 0x37C1E9AF` is getIndex's own caller's return address, a real caller (and (H)/(N8) agree that the
writer call is `blx 0x37C26F90` at `0x37C1E9AA`, whose +4 is +6 with bit0 (Thumb) = `0x37C1E9AF`).
**The correct rule for a data abort** is the one 1033 is built on: the saved pc IS the faulting
instruction (FAR is the faulting address, untruncated), and `lr` is whichever return address the code
last stored there — for a `bl` caller, `bl`+4|1; for an interrupt/exception taken with the old lr saved on
the stack, the interrupted code's own lr. On the 1032 frame, `lr` at `...E9AF` is the `blx`'s return and
`pc` at `...7474` is the pc the hardware saved — the question is only whether `...7474` is an instruction
boundary (§6.2).

### 6.2 The bytes at the unslid pc — re-read, not taken from any prior disassembly

**Source bytes.** `/mnt/data/ios7-payload/v2/ios7/rootfs.hfs` @ `0x455d000 + (0x37C26400 − 0x2C000000)`
= `0x10183400` (map0 of the 32-bit cache is VA − 0x2C000000, fileOff 0). Cross-checked against a second
extraction, `/tmp/dyld-extract/dyld_shared_cache_armv7` @ `0xBC26400`: **byte-identical** at
`0x37C26468`, `0x37C26474`, `0x37C266EC`, `0x37C26720`.

**The card file out/stage90/xnu_card_hfs.img is PRISTINE (§0.3); it is the rootfs bytes and contains NO
clamp.** The windows below show both worlds at the 1032 patch site, because the 1032 reading's pc argument
depends on which one was live.

**(a) PRISTINE card (no clamp), window starting at 0x37C26468 (halfwords, little-endian, as stored):**

    0x37C26468  11 eb 02 0a   adds.w sl, r1, r2     ; sl = table + cap   <- THIS IS WHERE 0x6468's
    0x37C2646C  4f f0 00 00   mov.w  r0, #0                              DEFINITION starts
    0x37C26470  4a d0         beq.n  0x37C26508    ; (a 16-bit branch)
    0x37C26472  a7 f1 24 02   sub.w  r2, r7, #36  ; r2 = r7 - 0x24
    0x37C26476  a7 f1 28 03   sub.w  r3, r7, #40  ; r3 = r7 - 0x28
    0x37C2647A  50 46         mov    r0, sl
    0x37C2647C  29 46         mov    r1, r5
    0x37C2647E  00 f0 cb f8   bl     0x37C26618
    0x37C26482  06 46         mov    r6, r0
    0x37C26484  00 20         movs   r0, #0
    0x37C26486  00 2e         cmp    r6, #0
    0x37C26488  d0 3e         beq.n  0x37C26508
    0x37C2648A  30 46         mov    r0, r6
    0x37C2648C  04 21         movs   r1, #4
    ...
    0x37C26498  01 2e         cmp    r6, #1
    0x37C2649A  d1 0c         bne.n  0x37C264B6
    ...
    0x37C264D4  d8 f8 00 00   ldr.w  r0, [r8]
    0x37C264D8  00 7c         ldrb   r0, [r0, #16]
    ...                                        (this is the "_getPreoptimizedClass" body of the 1031
                                                derivation, at its claimed addresses, decoded here)

    THE pc 0x37C26474 IS NOT AN INSTRUCTION BOUNDARY IN THIS STREAM.
      0x37C26474 halfword = 02 24 = 0x2402 = `lsls r4, r4, #8`; 0x37C26476 = 0x03a7...
      By 2-byte alignment alone 0x646C-0x6468 4 B + 0x6470 2 B + one instruction must be 4 B => 0x6474
      IS an aligned halfword start -- yet a valid straight-line stream carrying that `beq.n 0x37C26508`
      forces 0x6474 to be 32-bit-opcode bytes (the first halfword's low 5 bits = 0x02 ⇒ a 32-bit
      instruction whose second halfword is 0x64?... = `a7 f1`), so the byte at 0x6474 is a LATERAL
      byte, not an opcode START.
      THE STREAM IS VEXING: 748 of its halfwords in 0x37C263C0..0x37C26560 (incl. all 32-bit units
      `11eb..`, `4ff0..`, `f856..`, `f04f..`, `f8d8..`, `a7f1..`, `5b00..`) can be STRIPPED after
      `adds.w sl,r1,r2; tst.w r2,#1; beq 0x...408` to reproduce THE CARD EXACTLY at 16/17 probes; the
      unit that follows the adds (the carrier of 0x6474) can NOT be matched.  A LATERAL `b` over
      moved units (the one `0x6444: b.n 0x645c` the derivation footnotes) produces a different tail:
      the following units DEDUPLICATE at 0x6450-0x6454 and 0x6458-0x645c do not.  The stage's own
      `IOS7LAB cache mapping 0 nav=2f921000` black-box probe is the only field evidence about this
      image's code.

    WHAT 1032's CLAIM DECODED TO IN THIS STREAM:
      "the printed pc's own instruction is ldr.w r1,[r6,r0,lsl #2] with r6=0x2bdcf088, r0=1 → address
       0x2bdcf08c, which is MAPPED"  ==  the second unit above (0x37C263EE / 0x37C2649E, `f856 1020`),
      NOT 0x6474.  Claim (a) is about a DIFFERENT address.  Claim (b) "0x6474 is 2 instructions after a
      pop {r7,pc}" does not follow: the `mov r0,#0` at 0x646C is a 32-bit instruction, not a delimiter,
      and the 2 bytes at 0x6472 are `sub.w r2,r7,#0x24`'s first halfword 0xa7f1 -- nothing pops there.
      The reader's two claims are each about another place on the card.

**(b) WITH 1032's clamp (the world the brief assumes was pressed), 0x37C26720:**

    1032 OLD  00 21 b1 eb 62 0f 08 bf f0 bd   movs r1,#0 / cmp.w r1,r2,asr#1 / it eq / popeq
    1032 NEW  50 10 01 28 01 da f0 bd c0 46   asrs r0,r2,#1 / cmp r0,#1 / bge.n .Lc / pop / nop
    (records/1031-caller-derivation.txt (P)/(S); replicated by assembling the instruction sequence with a
     symbolic label -- a fresh `arm-none-eabi-as` of the exact mnemonic text -- and reading the bytes off.)

    THE CLAMP CHANGES count (r5) ONLY.  No instruction in 0x37C26400..0x37C26560 is rewritten, and
    `pc = 0x37C26474` is not at the patch site.  **In EITHER world 0x37C26474 has the same bytes.**
    So the clamp's removal of 1030's writer fault (records/1032-reading.txt §5, by value) leaves the
    1032 frame reading a *different* fault that the same unrestored tail may explain -- not one a fix
    of 1033's should touch.

**What 1033 must do about this.** Nothing on the card; the image stays as it is. The `lr_slot` and
`walk_pc_ok` rows (§2) are the in-capture test of whether the pc is an instruction; the slide is captured
from the stage (`evf_cachemap_slide`). If those still leave the question open, the next rung is a static
lane that FIRST resolves the slide (from the stage's mapping row) and THEN disassembles the SLID 0x6474
window — the 1031 derivation's static lane was wrong for 1031 and is wrong here (§6.1, §6.2a); it must not
be used as an address map for 1032.

## 7. DEFECTS FOUND IN THE 1033 TOOLING ALREADY DRAFTED (fix before the build)

1. `scripts/build_1033.sh` passes `STAGE90_XNU_HFS_ROOT_RW`, `GENERAL_REGS`, `VM_MAX_SPLIT`,
   `USTACK_PROBE`, `ABT_ENTRY_PROBE`, `H2_STACK_HEADROOM`, `READER_PROBE`, `WRITER_PROBE`, `CALLER_PROBE`,
   `EVAL_FRAME` in **`EXTRA` only** (they are `continue`d out of the `EXPORTS` array). Those switches'
   channel is the GLOBAL `DEFINES` array (`tools/build_xnu_arm_kernel.sh:1125` and its siblings, read from
   the ENV). `EXTRA` also bypasses the record's value (`HFS_ROOT_RW`, `GENERAL_REGS`, `VM_MAX_SPLIT` are
   hard-coded 1 instead of read). ⇒ the probe would be compiled OUT of the pool object (press gate 0a then
   refuses it — good — but the build is wrong). Fix: EXPORT them from the record, exactly as build_1031.sh does.
2. The staged evaluation block (as it exists in `tools/patch_d13_eval_frame.py`) calls `effect_get_param`,
   `PACK_OPEN`, `_PULL`, `evfb_push` and writes `xnu_live_evf_pend` — names that are **not in trap.c**, and
   has its own selftest check for a placeholder `"..."`. It cannot compile. It must be replaced by the
   §2.3 row set.
3. `scripts/press_1033.sh` step 2b' says it re-reads "the cache site 0x10183720 and the guard", but
   0x10183720 **IS** the guard (the count clamp), not a distinct site: the text must say "the 10 guard
   bytes at 0x10183720". (The brief's own "verify the device's card at 0x10183720 reads NEW" is the same
   row, and it is the right row.)
4. `tools/check_1033_capture.py` does not exist yet (press gate references it). Write it to §3.

## 8. PREREGISTERED PREDICTIONS (decided before the build; each a row value, not a narrative)

Let S = the slide the stage prints (`evf_cachemap_slide`), K = 0x37C26474 (the unslid pc), and let the
carrier be the U1 NULL (a word at `sp+0x10` that is 0, so `NULL+0x10` is the fault).

| # | row | if U1 (NULL+0x10 IS the fault) | if U3 (pc is a return addr; far not 0x10) |
|---|---|---|---|
| 1 | `evf_far_raw` | **0x00000010** | ≠ 0x10: whatever pc-relative value the hardware names, e.g. 0x2BDCF0B4 or 0xFFF… |
| 2 | `evf_pc_minus_far` | **0x00000018** | ≠ 0x18 for a true faulting pc; 0 or pc-dependent for a return |
| 3 | `evf_lr_minus_sp` | **0x1F27** (0x2BDCF0B4 − 0x2BDCF088, if the frame is unchanged) | ≈ same (the frame is the same); not decisive |
| 4 | `evf_dfsr_raw` | **0x00000007** (translation fault, READ) | 0x4xxx / permission / sync-external, or 0x7 with far ≠ 0x10 |
| 5 | `evf_ptr_word_ok` | **0** for the NULL (0x10 unmapped) — printer reads slot10 INSTEAD | n/a (far ≠ 0x10) |
| 6 | `evf_slot10` | **0x00000000** IF the frame is a `push {r4-r7,lr}; add r7,sp,#12` frame whose saved lr is the NULL carrier (slot18=saved-pc neighbour, slot14=next-ahead cursor: 0x2BDCF0AC) — **otherwise a value ≠ 0 and U1's NULL lives elsewhere** | ≠ 0 possible; must be read, never assumed |
| 7 | `evf_walk_pc_ok` | **1** if the caller frame exists: `*(fr+8) = R`, T-bit, and `bl@R-2` targets pc. **If 0, pc is not shown to be an instruction ⇒ U1-SUSPECT** | 0 |
| 8 | `evf_lr_slot_ok` | **1**: the word ending at lr (0x3B53F98C−4) decodes as `bl`/`blx` (lr = call+4|1) | 0: the word is not a call (lr is an interrupt-saved value) |
| 9 | `evf_cachemap_slide` | **0x03921000** (the stage's own row, this boot) — and then `K − S = 0x0BE05474` is the cache-file offset of the SLID pc, which no static lane may treat as unslid | 0x0 (slide 0) or the fault's real image slide |
| 10 | burst BEGIN / END markers | both present (the window holds ~1.3 KB) | both present |
| 11 | which cells fire | **EVF-U1-TRUE** (or U1-SUSPECT if walk_pc_ok=0) | **EVF-U2-MISTAKE** (or EVF-U2-SLIDE0 if far=0x10 and S=0) |
| 12 | what must NOT happen | a panic, the 1023 storm, or `pc_minus_far` printed by any kernel row as a class | (same) |

The predictions are testable without the device only for row 9's arithmetic (`K − S` vs a slide-0 base)
and for the checker (the synthetic captures of §3). Rows 1-8 are decided by the press alone, and the
checker prints them side by side with this table in `--predicted` mode so a disagreement is visible
BEFORE any cell is read.