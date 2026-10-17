# 1031 DESIGN — NAME THE CALLER: publish the WRITER's frame, its registers, and the region's `vme_end`, so `far`'s derivation is by-value

Status: DESIGN ONLY. Not built, not pressed. Nothing in this document has touched the device.

## 0. THE READING 1030 PRODUCED (W-B-NAMED) — quoted by value

Source: `records/1030-press-read.txt` (capture `out/stage90/captures/recovered-unknown-arm-20261017-064216-last_kmsg.txt`,
mtime 06:42:16 UTC = epoch 1792218196, NEWER than the press's boot epoch 1792217325 — the staleness guard
is discharged; the device returned via the operator's power press and the stock-Android boot read the RAM
console). Arm `armed-d13-8034562e`; `fastboot boot` ONLY, never flash.

The 1030 verdict is **W-B-NAMED**, from the 14 `xnu_live_wrp_*` rows (all present):

    xnu_live_wrp_r4              = 0x2bdae000    (the faulting store's destination cursor)
    xnu_live_wrp_r3             = 0xffffffff
    xnu_live_wrp_r5              = 0x38c9ec00
    xnu_live_wrp_r6              = 0x2bdae000    (== r4: the LOCKSTEP output cursor)
    xnu_live_wrp_r12             = 0x00004000    (16 KiB — the copy/VLA extent seen at 1029)
    xnu_live_wrp_sp              = 0x2bdac074
    xnu_live_wrp_pc              = 0x38b52756    (userspace, slid)
    xnu_live_wrp_lr              = 0x38b4a9af    (the CALLER to disassemble)
    xnu_live_wrp_r4_minus_sp     = 0x00001f8c
    xnu_live_wrp_userstack       = 0x2bdad000
    xnu_live_wrp_r4_minus_ustack = 0x00001000
    xnu_live_wrp_far             = 0x2bdae000
    xnu_live_wrp_r4_minus_far    = 0x00000000
    xnu_live_wrp_block_bytes     = 188

The pre-registered cell, quoted:

> `r4 == far == 0x2bdae000 == user_stack + 0x1000 == the region's EXCLUSIVE TOP`.
> `r6 == r4`: BOTH output cursors of the table-rebase copy point at the region's edge.
> The reader rows agree: `xnu_live_rdr_far = 0x2bdae000`, `xnu_live_rdr_ustack = 0x2bdad000`,
> `xnu_live_rdr_entry_at_hit = 0` (far is still UNOWNED) — the SAME fault as 1029, on a FRESH base
> (0x2bdae000 vs 1029's 0x2bd39000), so the boot re-ran.
>
> => This is a **STACK-LIMIT / BOUNDARY store**: the writer deliberately writes the word AT the region's
> advertised end, and the fault is the region top not being owned (or the limit check firing one page
> early).

Controls were all live (no regression): `launchd_reached=True`, `trap24=8`, `port_construct(result=0)=8`,
`abt_pc_live=12`, `undef_seq=None`, `panics=0`. The 1023 pthread storm did not return.

The writer (records/1030-audit.txt ADDENDUM 3, the lead's byte-verified disassembly of the pinned shared
cache, `pc - slide` == function_start + 0x6a EXACTLY):

    37c266ec: push {r4,r5,r6,r7,lr} ; add r7,sp,#12
              mov  r4,r3        ; r4 (the FAULTING cursor) = the caller's 4th ARGUMENT
              mov  r6,r2        ; r6 (the lockstep cursor) = the caller's 3rd ARGUMENT
              mov  r5,r0        ; r5 = the caller's 1st ARGUMENT (the table base)
              bl   0x37c1e950   ; helper
    37c26742: ldr.w r2,[r1,#-4] ; subs r0,#1 ; add r2,r5 ; str.w r2,[r6],#4   ; cursor #1 (r6)
    37c2674e: ldr   r2,[r1,#0]  ; add r1,#8  ; add r2,r5
    37c26756: str.w r2,[r4],#4  ; <-- FAULT (r4 == far)                         ; cursor #2 (r4)
    37c2675a: bne.n 0x37c26742                                                  ; loop
    37c2675c: pop  {r4-r7,pc}

`r4 == r6` at the fault, and the function sets them from `r3` and `r2` SEPARATELY, so **the caller passed
`r2 == r3 == 0x2bdae000`** — the SAME destination address for both cursors. The boundary decision is
therefore **in the CALLER**, not in this function, and the 1030 audit says so explicitly:

> the boundary decision is in the CALLER (who passes r3 = far), not this function. The probe must publish
> the caller's derivation of r4 (is it sp-relative? user_stack-derived? a selector-table dest?).
> … Whether the CALLER derived it as sp+const (W-A), as the region top (W-B), or from a shared-cache size
> (W-C) is **DECIDED BY THE CALLER (lr=0x3b7149af), which this lane could not resolve to a call site**
> (the lr does not land at a call of the fault fn in the mapped image — likely a tail call / different
> image; the reader lane owns the image table).
> **NEGATIVE (do not over-claim): the fault function ALONE does NOT discriminate W-A/W-B/W-C.**

That negative is the load-bearing fact for 1031: **the caller's derivation is UNRESOLVED.** W-B was
selected by value (`r4 == far == the region exclusive top`) as the *shape* of the store, but the *pointer
chain* that produced `r3` is not yet read.

## 0b. WHAT IS REFUTED — and WHY, precisely (the (A)/(B)/(C) weighing)

### The population fact (decides most of the field)

Across ALL 60→61 captures (`out/stage90/captures/recovered-unknown-arm-2026101{6,7}-*-last_kmsg.txt`;
records/1030-audit.txt ADDENDUM 2 Q1/Q2, the lead's population re-run):

    ustack - sp   == 0xF8C  in ALL runs                (the argv/env block size is INVARIANT)
    far - ustack  == 0      in 57 runs  (pre-H2:  far == the region's exclusive top)
    far - ustack  == 0x1000 in  3 runs  (post-H2 ONLY: 1028 x2 + 1029 x1)
    far == e2_hi  in EVERY run with an e2 row
    NO other value of (far - ustack) ever appears.

=> **`far` == the region's EXCLUSIVE TOP in every measured run, and the ONLY mover of `far` is H2 growing
the region.** Hypothesis A (far == the owned region top) holds on 1025/1026/1027/1028/1029/1030;
Hypothesis B (far == `ustack + 0x1000` as a *derivation distance*) is REFUTED by 1025/1026/1027 (there
`far == ustack`, no `+0x1000`). The `+0x1000` on 1028/1029/1030 is a CONSEQUENCE of the grown top, not a
constant the writer adds.

### REFUTED: region re-sizing, and precisely WHICH shape

1028 was a FIX: `create_unix_stack`'s FIXED `mach_vm_allocate` extent `size` → `size + 16`
(`STAGE90_XNU_H2_STACK_HEADROOM`, kern_exec.c:3668-3679). `mach_vm_allocate` rounds the extent up
(`vm_map_round_page`), so `size + 16` grew the region by **a whole page**: base unchanged, exclusive top
`ustack` → `ustack + 0x1000`. The reading came back **FIX-NOOP, page-exact**
(`records/1028-press-read.txt`; `xnu_live_ustack_rc = 0`, so the FIXED allocate succeeded — not a silent
ANYWHERE fallback):

    far - ustack : 0     (1024-1027)  ->  0x1000  (1028)
    far - sp     : 0xF8C (1024-1027)  ->  0x1F8C  (1028 = 0xF8C + 0x1000)
    ustack - sp  : 0xF8C UNCHANGED    (the block did NOT move)

**1028's refutation is about "the top moves and `far` tracks it", full stop.** The word "block" in H2's
motivation is the *motivation*, not the *mechanism*: H2 was built to OWN the word at `user_stack`
(so the block would no longer end flush with the region), and the block indeed did not move
(`ustack - sp` stayed 0xF8C) — but the store **moved up with the region top** regardless. So the
refutation is **`far` is a function of the region's exclusive top**, not of the block.

### Candidate (A) — "own the page at the region top by growing the extent" — IS 1028, verbatim

The task's (A) is: *make the stack region's exclusive top END one page HIGHER (allocate
`[addr, addr+size+PAGE)`)*. That is **byte-identical to what 1028 did**: `size → size + 16` rounds to
`size + PAGE`, base unchanged, exclusive top `ustack → ustack + PAGE`. The audit's own
"WHAT WOULD ACTUALLY LAND THE TOP ONE PAGE HIGHER" already states the correct shape
(`addr = trunc_page(user_stack - size)` unchanged, allocate `size + PAGE`) and then states the outcome:

> moving the top up by a page makes far = ustack+PAGE (a MOVE), not a FIX — the boundary-write READER …
> says far == region top, so raising the top raises far.

**Therefore (A) is the same no-op as 1028**, for the identical reason: the writer's target *is* the region
top (the population proves `far == region top` in all 61 runs), so growing the top moves the target.
There is no version of "own the page at the region top" that is not 1028: owning the page means
extending the extent, and extending the extent moves the top, and moving the top moves `far`. A 1031 that
allocates another page would be a third FIX-NOOP of the 1028 class and would read nothing new.

*(The audit's base-down-one-page variant — `addr = trunc_page(user_stack - size) - PAGE` with extent
`size + PAGE` — was already killed arithmetically in audit1030 CHECK 1: base-down and extent-up CANCEL,
`top = (user_stack - size - PAGE) + (size + PAGE) = user_stack`, unchanged. That is the dead 1030 shape.)*

### Candidate (B) — "the caller's derivation" — the LEVER, but UNRESOLVED

(B) is the correct *location* of the lever: the writer's `r4` is the caller's `r3`, so if the caller
derives `r3` as `p->user_stack + size` (the region end) — or from any value that tracks the region top —
then owning the top page cannot help and changing what the writer is handed is the lever. But **the
evidence does not yet name the caller's derivation.** The audit:
(i) resolved the fault function byte-for-byte, but
(ii) could NOT resolve `lr = 0x3b7149af` to a call site ("does not land at a call of the fault fn in the
mapped image"), and
(iii) published no row that shows what the caller read to build `r3`.

So (B) is an *open question with a named gap*, not a fix we can test yet.

### Candidate (C) — "stop the writer / the caller's size" — partially excluded by value

(C) says: if the destination is an oversized VLA whose size the caller computed wrongly, the fix is the
caller's size. The 1030/1029 arithmetic argues against an oversized-stack-VLA reading:

    1029/052951:  sp = 0x2bd37074   ustack = 0x2bd38000   far = 0x2bd39000
      region RW body = [0x2bc39000, 0x2bd39000)  (1 MiB = MAXSSIZ)
      space BELOW sp to the region bottom = sp - 0x2bc39000 = 0xFE074 = **1016 KiB FREE**
      space ABOVE sp to the region top    = far - sp        = 0x1F8C  = **7.9 KiB**
      the VLA/copy extent r12 = 0x4000 = 16 KiB

A stack VLA grows DOWNWARD into 1016 KiB of untouched region; the writer's destination is 7.9 KiB **ABOVE
sp**, past the block, past `ustack`, **AT the region top** (records/1030-audit.txt ADDENDUM 2 Q3). So the
destination is a **deliberate "fill up to the top" write**, not an oversized downward VLA. (C) as
"oversized VLA" is refuted by value; (C)'s *general* form — "the caller computed the destination wrongly"
— collapses into (B), because the only way to see the computation is to read the caller.

### Candidate (D) — what the code shows that was not named: the two cursors are the SAME address, and one of them is a *source-relative bound*

The disassembly shows the caller passed `r2 == r3 == 0x2bdae000`: two independent output cursors at the
identical address. A table-rebase writes each fixed-up entry to **one** cursor; the second cursor being
identical (and the loop advancing both by 4) means the caller is running the pass **twice into the same
place**, or — more likely given `r12 = 0x4000` and the "fill up to the top" shape — the buffer is a
**16 KiB region whose END the caller set to the stack top**, i.e. the caller laid a `[top - 0x4000, top)`
buffer down and the loop walked past `top`. That is a *caller* bug whose size/end we cannot see without
the caller frame. (D) is thus not a competing fix; it is a **sharper statement of (B)**: publish the
caller frame and the two cursor origins, and one of two things will be true by value —
`r3 == p->user_stack + <computed size>` (a caller end-of-buffer derivation), or `r3` is a stored value
that happens to equal the region top (then a *stored* top is the lever).

## 1. THE 1031 RUNG — a PROBE THAT NAMES THE CALLER (ONE new switch)

**Verdict on the fix question: the evidence does NOT support picking a single fix.** (A) is exactly 1028
(refuted by value); (B)/(C)/(D) all require reading the caller's derivation, and the 1030 lane could not
resolve it. Per the task's own rule — and matching how 1029→1030 was handled — **1031 is a PROBE that
names the caller.** It is not another re-measurement of `far` (1030 already settled the shape); it
publishes facts the 1030 probe structurally could NOT: **the caller's frame, the caller's registers, and
the region's exclusive top as a printed row.**

### The one new switch

    STAGE90_XNU_CALLER_PROBE=1

### The site (sites) and files

**Site A — `osfmk/arm/trap.c`** (the SAME usermode DATA-abort failure arm 1025/1026/1027/1029/1030 use,
inside the existing `#if defined(STAGE90_XNU_USTACK_PROBE)` publisher, AFTER the `STAGE90_XNU_WRITER_PROBE`
block's `#endif` at trap.c:958). This is the ONE place where, at the fault, simultaneously in scope:
`dfar` (the store VA), `arm_ctx` (all of r0-r12, sp, lr, pc), `thread` (-> `thread->map`,
`thread->task`, `thread->task->bsd_info`), and `map`. It ADDS facts to the same non-ringed ram-console
channel.

**What Site A publishes BY VALUE (the rows, each printed UNCONDITIONALLY — the 1026 lesson):**

    xnu_live_cal_r0            = arm_ctx->r[0]        <- the caller's 1st arg to the writer (table base r5)
    xnu_live_cal_r1            = arm_ctx->r[1]        <- the caller's table iterator
    xnu_live_cal_r2            = arm_ctx->r[2]        <- the caller's 3rd arg to the writer (cursor #1 == r6)
    xnu_live_cal_r9            = arm_ctx->r[9]        <- (1029's capture printed r9 = 0x1fff; NOT published by 1030)
    xnu_live_cal_r10           = arm_ctx->r[10]       <- the objc table iterator (audit: r5 == r10)
    xnu_live_cal_r7            = arm_ctx->r[7]        <- the writer's frame pointer (== sp + 0xC, provable)
    xnu_live_cal_r7_minus_sp   = r[7] - arm_ctx->sp   <- must be 0xC; a self-check that r7 IS the frame fp
    xnu_live_cal_lr            = arm_ctx->lr          <- the caller's return address (== the 1030 lr)
    xnu_live_cal_pc            = arm_ctx->pc          <- the faulting pc (== 1030's 0x38b52756)
    xnu_live_cal_far           = vm_map_trunc_page(dfar)
    xnu_live_cal_ustack        = p->user_stack        (REUSE xnu_live_abt_proc_ustack, kern_exec.c:3586)
    xnu_live_cal_region_end    = the covering entry's vme_end for `far - 4`   <- SEE BELOW

The **region_end** row is the crux. The writer's target is the region's EXCLUSIVE top; 1030 *inferred*
this (`far == ustack + 0x1000` plus the population), but never **printed a row that IS the region's
exclusive top**. Site A reads it directly, re-using the 1026/1027/1029 idiom:

    {
        vm_map_entry_t _cal_e = VM_MAP_ENTRY_NULL;
        /* the entry covering [far-4, far): when far is the exclusive top, far-4 IS inside the
         * region, so this entry's vme_end IS the region's exclusive top, by value. */
        boolean_t _cal_hit = vm_map_lookup_entry(map, vm_map_trunc_page(dfar) - 4, &_cal_e);
        printf("xnu_live_cal_region_end=0x%08x\n",
               (unsigned)((_cal_hit && _cal_e) ? _cal_e->vme_end : 0));
        printf("xnu_live_cal_region_end_hit=%d\n", (int)(_cal_hit ? 1 : 0));
    }

`vm_map_lookup_entry` takes NO lock in this tree (the 1026/1027/1029 idiom, `VM_MAP_STORE_USE_LL`), and
this is on the failure path only, before any mutation. READ ONLY.

With `region_end` PRINTED, the 1031 capture can assert the 1030 shape as a **single conjunction**
(`far == region_end`) instead of an inference from `far - ustack`. That is the discriminating reading —
not a re-measurement.

**Site B — `bsd/kern/kern_exec.c`: a NEW accessor beside `xnu_live_abt_proc_ustack` (kern_exec.c:3586),
for the region's exclusive top as the KERNEL derived it.** The `far`-4 entry's `vme_end` (Site A) is the
region top as it exists in the map; the kernel's `addr + size` at `create_unix_stack` (kern_exec.c:3666,
`addr = mach_vm_trunc_page(user_stack - size)`) is the top as the allocator computed it. Publishing BOTH
makes "the writer's target IS the region's exclusive top" provable from two independent derivations
(the map's and the allocator's). Site B ADDS, in the SAME `#if` namespace region:

    unsigned xnu_live_cal_unix_stack_top(void *bsd_info);   /* p->user_stack, the block top (reuse ustack) */
    unsigned xnu_live_cal_region_top(void *bsd_info);       /* addr + size, computed at create_unix_stack */

`region_top` cannot be recovered from `p` alone (the `addr`/`size` locals are gone after `create_unix_stack`
returns), so it is **stashed into the proc** at `create_unix_stack` and read back by the accessor — the
minimal, honest way to make the allocator's own top durable. (Alternatively, if a proc field cannot be
added cleanly, publish `region_top` as a `printf` in `create_unix_stack` itself under the same switch —
but that prints once per exec and loses the at-fault correlation, so the PROC stash is preferred.)

### What 1031 changes BY VALUE

- **No allocation changes.** No `mach_vm_allocate` extent, no base, no guard, no `p->user_stack`, no
  `LAB_USER_STACK`/`MAXSSIZ`/`VM_MAX_ADDRESS`. 1031 is a PROBE: it writes (at most) one durable stash field
  (`p`'s region_top, for Site B) and prints rows. It is the opposite of the refuted (A).
- The ONLY state change is a **read-back stash** (`region_top`) written once in `create_unix_stack` and
  read once at fault; if the stash is judged a mutation, the fall-back (a `printf` in `create_unix_stack`)
  changes nothing at all.

### Why this is the discriminating test (not another probe that re-measures)

1030 published `r4 == far` and the *shape* (a boundary store). What it could not publish is **`far`'s
derivation**, because the caller frame and the region top were never on the wire. 1031 publishes exactly
those, and the two candidate derivations of `r3` are separated by value:

- If the caller derived `r3` from the region top (`r3 == region_top`, i.e. `r3` equals the allocator's
  `addr + size` AND the map's `vme_end`), then the writer is handed the region end explicitly → the lever
  is **what the caller is handed** (candidate (B)), and (A)/(region-re-sizing) stays refuted.
- If the caller derived `r3` from a size/end it computed itself (e.g. `r3 == p->user_stack + r12`, the
  16 KiB buffer end), then the writer's destination is a **caller buffer whose END the caller set high**
  (candidate (C)/(D)), and the lever is the **caller's size**.
- If `r3` equals neither and `cal_region_end_hit == 0` (the entry does NOT end at `far`), the 1030 reading
  itself would be wrong (a fixed-VA writer) — the fail-closed W-OTHER case 1030 pre-registered.

This is a reading 1030 could not produce and that no re-measurement of `far` can produce.

## 2. THE PRE-REGISTERED CELLS (decided before the build; each an exact conjunct over named rows)

Fail-closed: an ABSENT row means the PROBE DID NOT RUN (→ `CAL-MISSING`), NEVER a negative. A cell is
decided ONLY by values PRESENT in a capture NEWER than the press's boot epoch.

    CAL-CALLER-TOP      : cal_region_end_hit == 1 AND cal_region_end == cal_far
                          AND cal_r3 == cal_far AND cal_r2 == cal_far AND cal_r7_minus_sp == 0xC
                          AND cal_far - cal_ustack == 0x1000 (post-H2) OR == 0 (pre-H2, if H2 is off).
                          Meaning BY VALUE: the region's exclusive top (the map's own vme_end) IS `far`,
                          and the caller handed BOTH cursors that exact address. => the writer's target
                          is the region end; the caller's derivation is the region top. LEVER = (B).
                          (1030 predicted this; 1031 CONFIRMS it by printing the region end, not by
                          inferring it. Still NO fix selected: (B) needs the caller disassembled, below.)
    CAL-CALLER-SIZE     : cal_r3 == cal_far AND cal_r3 == (cal_ustack + <a value printed in cal_r12 or a
                          new size row>) AND cal_r3 != cal_region_end (the buffer END is BELOW the region
                          top, so the caller's own buffer, not the region, is the boundary).
                          => the writer's destination is the CALLER's buffer end (candidate (C)/(D));
                          LEVER = the caller's buffer size. Requires the caller disassembled to name the
                          size.
    CAL-CALLER-OTHER    : any OTHER combination of the present cal_* rows (e.g. cal_r3 != cal_far — the
                          two cursors differ from 1030's r2==r3==far), with cal_region_end_hit == 1.
                          => the caller's derivation is something not modelled; NAME the first failing
                          conjunct. Do NOT pick a fix.
    CAL-MISSING         : cal_region_end_hit and the cal_r* rows are ABSENT (or cal_region_end_hit == 0
                          with `cal_region_end` == 0). The probe did not run, or `far - 4` was itself
                          unmapped (a DIFFERENT failure: `far` is NOT the region top). => NO READING.
                          NEVER read an absent row as "far != region end".
    REGRESSION          : `*** launchd[1] has started up ***` absent, OR the trap24 rows vanish, OR the
                          `port_construct result=0` rows vanish, OR `panics != 0`. => WITHHOLD; the arm's
                          switch set is wrong ([[mi4-build-variant-comes-from-an-env-default]]).
    G-CTL               : no capture NEWER than this press's boot epoch (the 1028/1029/1030 stale-slot
                          rule; a resident rung that does not return keeps no `/proc/last_kmsg` of its own
                          — [[mi4-last-kmsg-reader-carrier]], [[mi4-stale-slot-impersonates-a-reading]]).
                          => WITHHOLD; the newest slot describes a DIFFERENT arm.

Every conjunct is a POSITIVE equality over a PRINTED row. `cal_region_end == 0` printed WITH
`cal_region_end_hit == 0` is a POSITIVE reading (the far-4 word is unmapped → far is not the region top),
and it must be the PRINTED zero, never a suppressed line (the 1026 defect:
`[[mi4-1026-abt-entry-probe]]`).

## 3. BLAST RADIUS — switches to carry VERBATIM, namespaces joined, patchers to amend

### The switch set the build must carry (1029's FULL set, taken from its record, never a default)

From `scripts/build_1030.sh` (the current arm, which is 1029's set + `WRITER_PROBE`), the rung carries
**verbatim**:

    STAGE90_XNU_ENTRY=1                       STAGE90_XNU_HFS=<the record's value, 0 on D13>
    STAGE90_XNU_HFS_ROOT_RW=<the record's value>
    STAGE90_XNU_SP_ALIGN=1                    STAGE90_XNU_IOS7_TRAPS=1
    STAGE90_XNU_RESIDENT=1                    STAGE90_XNU_USVC=1
    STAGE90_XNU_VMHINT_GUARD=1                STAGE90_XNU_SUBMAP_PMAP_SKIP=1
    STAGE90_XNU_COMMPAGE_ALIAS=1              STAGE90_XNU_DYLD_WITNESS=1
    STAGE90_XNU_SHREG_PROBE=1                 STAGE90_XNU_SHREG_WIRE=1
    STAGE90_XNU_SHREG_GEOM=1                  STAGE90_XNU_STALL=1
    STAGE90_XNU_CADENCE=1                     STAGE90_XNU_FLUSH_WITNESS=1
    STAGE90_XNU_KEXTB_LOGIN=1                 STAGE90_XNU_UNDEF_RAISE=1
    STAGE90_XNU_GENERAL_REGS=1                STAGE90_XNU_VM_MAX_SPLIT=1
    STAGE90_XNU_GLOBAL_FIX=1                  STAGE90_XNU_USTACK_PROBE=1        <- 1025 parent
    STAGE90_XNU_ABT_ENTRY_PROBE=1             <- 1026/1027 parent of the abort-entry rows
    STAGE90_XNU_H2_STACK_HEADROOM=1           <- the 1028 FIX (kept: it defines the `far - ustack` geometry)
    STAGE90_XNU_READER_PROBE=1                <- 1029 (defines `far == region exclusive top`)
    STAGE90_XNU_WRITER_PROBE=1                <- 1030 (defines the writer shape this rung builds on)
    STAGE90_XNU_CALLER_PROBE=1                <- THIS rung's ONE new switch
    STAGE90_ENTRY_ARM_CHANGE=1
    XNU_TREE=<as recorded>

The 1031 Site A block is **nested inside 1025's publisher and after 1030's block**, so
`STAGE90_XNU_USTACK_PROBE=1` is its parent gate; `WRITER_PROBE` is not a parent but the block it extends —
both are carried for the parent cells to remain readable.

### The `#if` identifier namespaces the switch joins

Per memory `mi4-one-file-many-rungs`, a file's conditional-directive identifiers are a SHARED namespace,
and every patcher that edits the file must list the new switch in its allow-set or its OFF proof refuses
the composed tree:

- **`osfmk/arm/trap.c`** — edited by SIX patchers today, each carrying a `TRAP_ALLOWED_IF_IDENTIFIERS`
  (or `ALLOWED_IF_IDENTIFIERS`) union that MUST gain `STAGE90_XNU_CALLER_PROBE`:
    - `tools/patch_d13_ustack_probe.py`      (`TRAP_ALLOWED_IF_IDENTIFIERS`, line ~94)
    - `tools/patch_d13_abt_entry_probe.py`   (`TRAP_ALLOWED_IF_IDENTIFIERS`, line ~213)
    - `tools/patch_d13_reader_probe.py`      (`TRAP_ALLOWED_IF_IDENTIFIERS`, line ~88)
    - `tools/patch_d13_writer_probe.py`      (`TRAP_ALLOWED_IF_IDENTIFIERS`, line ~95)
    - `tools/patch_d13_undef_raise.py`       (`ALLOWED_IF_IDENTIFIERS`, line ~109)
    - `tools/patch_d13_dyld_witness.py`      (`ALLOWED_IF_IDENTIFIERS`, line ~395)
- **`bsd/kern/kern_exec.c`** — edited by `patch_d13_ustack_probe.py`, `patch_d13_abt_entry_probe.py`,
  `patch_d13_reader_probe.py`, and `patch_d13_h2_stack_headroom.py`; each carries a kern_exec.c
  identifier allow-set that MUST gain `STAGE90_XNU_CALLER_PROBE` (the reader probe's
  `if_stage90_ids`-of-kern_exec check, ~line 207, and the h2 patcher's ~line 98).

**The RE-STAGE rule.** The new patcher does NOT re-apply the old ones; it MUST be **composed the same way
every prior rung was** — the build's patcher chain re-stages 1025/1026/1027/1029/1030's edits on top of
each other (the `[[mi4-one-file-many-rungs]]` discipline: `git checkout` would silently revert the older
edits; every `ALLOWED_*_IF_IDENTIFIERS` set must carry every switch the composed tree evaluates). A
build refusal naming the new switch is the page-move signature, not a licence to skip it.

### The list of OTHER patchers whose ALLOWED sets must gain the new switch

    tools/patch_d13_ustack_probe.py          (trap.c + kern_exec.c)
    tools/patch_d13_abt_entry_probe.py       (trap.c + kern_exec.c)
    tools/patch_d13_reader_probe.py          (trap.c + kern_exec.c)
    tools/patch_d13_writer_probe.py          (trap.c)
    tools/patch_d13_undef_raise.py           (trap.c)
    tools/patch_d13_dyld_witness.py          (trap.c)
    tools/patch_d13_h2_stack_headroom.py     (kern_exec.c)

and the NEW `tools/patch_d13_caller_probe.py` (trap.c + kern_exec.c). Plus the four build-artifact
channels the prior rungs all amended (`[[mi4-one-file-many-rungs]]` + `[[mi4-build-variant-comes-from-an-env-default]]`):
`tools/build_xnu_arm_kernel.sh` (global `DEFINES+=(-DSTAGE90_XNU_CALLER_PROBE=1)`),
`src/entry/build_entry.sh` (`ENTRY_ARM_KEYS` / the arm-key case / the record writer / the link-site
clause), `scripts/preflight_boot_check.sh` (`ENTRY_CFG_KEYS` + its `-z` grace branch).

## 4. THE BUILD/PRESS/CHECKER TRIO TO WRITE, and the revert-set requirement

Author, in this order:

1. **`tools/patch_d13_caller_probe.py`** — NEW patcher. Edits `osfmk/arm/trap.c` (Site A, anchored at the
   exact `#endif /* STAGE90_XNU_WRITER_PROBE */\n` tail, count==1, DONE_MARK `xnu_live_cal_region_end=`)
   and `bsd/kern/kern_exec.c` (Site B, the `region_top` stash + the accessor, in the reader/h2 namespace
   region). Carries `TRAP_ALLOWED_IF_IDENTIFIERS` and the kern_exec allow-set, each INCLUDING every other
   rung's switch plus `STAGE90_XNU_CALLER_PROBE`. Must have an OFF proof (a tree with the switch unset
   compiles to the pre-1031 bytes).

2. **`scripts/build_1031.sh`** — models `scripts/build_1030.sh`: reads `$REC` (the 1030 record), carries
   its whole `STAGE90_XNU_*` set VERBATIM, ADDS `STAGE90_XNU_CALLER_PROBE=1`, and refuses if any parent
   switch is missing or carries a non-`1` value. Gate checks: the new switch appears in
   `tools/build_xnu_arm_kernel.sh`'s global DEFINES, in `src/entry/build_entry.sh`'s keys, in
   `preflight_boot_check.sh`'s `ENTRY_CFG_KEYS`, and in EVERY `ALLOWED_*_IF_IDENTIFIERS` set above. Then
   verify the OBJECT side: `trap.o` carries the `xnu_live_cal_region_end=` publisher AND `kern_exec.o`
   carries the new accessor symbol; and the LINKED image carries both (the object-vs-linked split, the
   1028 lesson).

3. **`scripts/press_1031.sh`** — models `scripts/press_1030.sh`. First checks, IN ORDER:
   (a) `STAGE90_XNU_CALLER_PROBE=1` (this rung IS the caller probe — its absence means the pool was built
   with the probe SHUT); (b) `STAGE90_XNU_WRITER_PROBE=1` and `STAGE90_XNU_READER_PROBE=1` and
   `STAGE90_XNU_ABT_ENTRY_PROBE=1` and `STAGE90_XNU_USTACK_PROBE=1` (the parent cells);
   (c) `STAGE90_XNU_H2_STACK_HEADROOM=1` (defines the `far - ustack` geometry the new cell's conjuncts
   assume). Then the arm gate, the staleness stamp (boot epoch printed and checked), the
   `xnu_live_cal_region_end=` string present in BOTH the trap.o and the linked image. **`fastboot boot`
   ONLY, NEVER `fastboot flash`.** It arms the USB reader (which has delivered ZERO bytes on 1024-1030 —
   the EP1-IN blind spot stays), boots, and on NON-RETURN prints NO READING and does NOT clear the slot.

4. **`tools/check_1031_capture.py`** — models `tools/check_1030_capture.py`. Its key list must include
   EVERY emitted `cal_*` row (the 1030 `[[mi4-one-value-two-definitions]]` defect: `WRP_KEYS` listed 9 of
   14 emitted rows and the group-split produced W-OTHER on a complete capture). It must have a
   `--selftest` that (a) builds fixtures from the patcher's REAL emission order and (b) asserts the cell is
   UNCHANGED when emitted-but-unread rows are stripped (the group-split guard). The cells are exactly §2:
   `CAL-CALLER-TOP` / `CAL-CALLER-SIZE` / `CAL-CALLER-OTHER` / `CAL-MISSING` / `REGRESSION` / `G-CTL`,
   fail-closed, NEVER a negative for an absent row.

5. **`records/revert-set.txt`** — a NEW arm MUST be recorded BY HAND in `records/revert-set.txt` BEFORE
   its press (the record the build does not write; `[[mi4-self-written-record-is-not-a-constraint]]`).
   The 1030 press's own revert-set clause REFUSED the arm until the record existed — that is the designed
   behaviour and it applies verbatim to 1031. Write the 13-file set (the same set the 1030 arm recorded,
   measured by hand, verified by `tools/verify_revert_set.sh`) under the new arm id, and commit it BEFORE
   `press_1031.sh` is run. Also carry `STAGE90_XNU_CALLER_PROBE` in the record the arm-key case writes.

## 5. OPEN RISKS AND WHAT WOULD FALSIFY THE CHOSEN PROBE

- **The chosen rung is a PROBE, so the "chosen fix" falsification is really: what would make this probe
  the wrong instrument.**
  - **Falsified by `cal_region_end_hit == 0`** (the far-4 word is unmapped): then `far` is NOT the region
    top and the ENTIRE 1030 reading (and the 60-run population) is wrong — the writer is a fixed-VA
    writer (1029's hypothesis (c)), and the next rung is a VA-provenance probe, not this one.
  - **Falsified by `cal_r3 != cal_far`** (the caller's two cursor args differ): then 1030's
    `r2 == r3` register reconciliation was a measurement artifact, and the writer shape must be
    re-derived.
  - **Undermined if both `CAL-CALLER-TOP` and `CAL-CALLER-SIZE` are reachable** from one capture: they are
    separated by whether `r3` equals the region top or a smaller buffer end; if `r3` equals BOTH (i.e. the
    caller set its buffer end == the region top), the cell is CAL-CALLER-TOP (the weaker, boundary-write
    reading) and the size reading is deferred to a caller disassembly.
- **The caller STILL unresolved after 1031.** If `cal_lr = 0x38b4a9af` still does not land at a call site
  in the mapped image (the 1030 lane's failure), then even with the caller's REGISTERS published we have
  not seen the caller's INSTRUCTIONS. The honest next step is then the shared-cache image table
  (the reader lane owns it) — a static disassembly, not another press. 1031 should be pre-registered to
  say so: **if the caller's `lr` is unresolved, the fix is NOT picked and the next rung is a STATIC
  disassembly of `libobjc` around `lr`.**
- **CORRECTION (2026-10-17, before the build) — a down-alloca caller derivation is REFUTED by the raw
  frame, so it must NOT enter any cell's premise.** A first pass at static disassembly proposed the caller
  derives `r3` as `sub.w rN, sp, r#N, lsl #2` — a *downward* `alloca` off `sp`. The captured frame
  (`records/1030-press-read.txt`; `recovered-unknown-arm-20261017-064216`) refutes it outright: `sp =
  0x2bdac074`, `r7 = r11 = sp + 12` (the writer's own frame pointer, per the prologue `add r7,sp,#12`),
  and the faulting `r4 = 0x2bdae000 = sp + 0x1F8C` — the destination is **ABOVE `sp`**, one page above
  `user_stack` (`= user_stack + 0x1000`), at the region's exclusive top. A `sub.w rN, sp, …` places a
  pointer *below* `sp` and **cannot** produce `sp + 0x1F8C`. That alloca exists in the image but is not
  the instruction that set this `r4`. The cells in §2 are value-decided (they read `cal_r3`/`cal_far`/
  `cal_region_end` printed rows), so they need no change — but any narrative that says "the caller alloca's
  a stack buffer downward" is pre-refuted and must not be asserted. The caller's derivation remains
  UNRESOLVED (§5 first bullet stands); 1031 is the instrument that measures it.
- **User-memory read.** Site A does NOT `copyin` the caller frame. Reading user memory on the failure path
  (`vm_fault` already returned `KERN_INVALID_ADDRESS`) risks a nested fault. 1031 reads ONLY kernel-side
  facts (registers from `arm_ctx`, the map entry via `vm_map_lookup_entry`, the proc's stashed top). This
  is a deliberate limitation: if the caller's derivation is a value that lives ONLY in its stack frame
  (not in a register), 1031 cannot see it and a later rung must find a safe read (e.g. after the thread is
  marked, from the exec's own path).
- **`p` stash mutation.** If stashing `region_top` into the proc is judged a mutation of tracked state,
  the fall-back (a `printf` in `create_unix_stack` under the same switch) changes nothing but loses the
  at-fault correlation; that trade must be decided at build time, and the record must say which shape
  was built.
- **Blast radius (the standing risks).** Every prior `STAGE90_XNU_*` switch must be carried verbatim
  ([[mi4-build-variant-comes-from-an-env-default]]); the new switch must enter EVERY
  `ALLOWED_*_IF_IDENTIFIERS` set ([[mi4-one-file-many-rungs]]); `STAGE90_XNU_HFS=0` on D13; the reader's
  EP1-IN blind spot (1024-1030) means the capture likely arrives ONLY via the operator's power press +
  `scripts/recover_last_kmsg.sh --read-only`, and the staleness guard must refuse any slot older than the
  boot epoch.
- **Hardware safety (verbatim, always).** `fastboot boot` ONLY, NEVER `fastboot flash`; never boot TWRP;
  never press the power button (the operator's job); unplug device `33e80afe` if present.