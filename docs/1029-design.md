# 1029 DESIGN — READ THE READER: PUBLISH THE DERIVATION CHAIN THAT PUTS THE STORE AT `user_stack + 0x1000`

## 0. WHAT 1028 DECIDED (the premise this rung acts on)

1028 was a FIX (grow the initial user-stack region by one word; see §1) and it came back
**FIX-NOOP — page-exact**.  The reading is `records/1028-press-read.txt`; the by-value arithmetic is:

    arm              : armed-d13-35a7e83e
    xnu_live_ustack_rc   = 0                 <- the FIXED allocate SUCCEEDED (no ANYWHERE fallback)
    p->user_stack (final)= 0x2bd0d000
    far                  = 0x2bd0e000
    far - ustack         = 0x1000            <- the fault moved UP by exactly the page the region grew
    sp                   = 0x2bd0c074
    ustack - sp          = 0x0F8C            <- the block size, UNCHANGED from 1024-1027
    far - sp             = 0x1F8C = 0xF8C + 0x1000

Compare the SAME two offsets on 1024/1025/1026/1027: `far == p->user_stack` and `far - sp == 0xF8C`.
On 1028 the fault is `p->user_stack + 0x1000`, one page ABOVE even the newly-grown region top, while
the block top (`ustack`) and `sp` did NOT move.  **The fix took effect and the fault FOLLOWED it.**

That is the whole decision: **H2, as a fix target, is REFUTED.**  H2 said "the region ends flush with
the block top, so the word at `far == user_stack` is unowned."  If that were the cause, growing the
region so it OWNS that word would have REMOVED the fault; instead the fault reappeared one page higher.
The failing write is not the block's top word.  It is a userspace store whose address is a function of
`p->user_stack` — the writer derives its store address FROM the advertised stack top, so raising the
top raises the fault ([[mi4-a-window-is-an-interval-not-a-function]], the "boundary can be in a READER"
shape).

Per the pre-registered cell (docs/1028-design.md §5): **report, do NOT re-fix.**  1029 exists to
**name the reader by value**, not to allocate another page — allocating another page would move the
fault again and prove nothing.

## 1. THE FIX 1028 APPLIED (stated so 1029 does not re-derive it)

One source edit in `create_unix_stack` (`external/xnu-hd2-darwin13/xnu/bsd/kern/kern_exec.c`), the
FIXED `mach_vm_allocate` only: extent `size` -> `size + 16`, base unchanged, guard unchanged,
`p->user_stack` unchanged.  Function `create_unix_stack` at kern_exec.c:3615; the FIXED call at
kern_exec.c:3646-3656 (the `#if defined(STAGE90_XNU_H2_STACK_HEADROOM)` arm).  `mach_vm_allocate`
(`osfmk/vm/vm_user.c`) rounds the extent up, so the region's exclusive top landed at
`user_stack + 0x1000`, not `+16` (docs/1028-design.md §5).  By-value certification in
`records/1028-build.txt`: `out/stage90/xnu_arm_entry.elf` `create_unix_stack @ 0x8020a768` carries
`orr r2, r6, #16` at 0x8020a7c4 (FIXED) vs `mov r2, r6` at 0x8020a7fc (ANYWHERE fallback).

## 2. WHY A PROBE, AND WHAT IT MUST READ BY VALUE

The chain we must prove is: **whoever writes at `far` obtained `far` from `p->user_stack`.**  The 1028
reading is consistent with that but does not prove it — three things could produce "the fault follows
the region top":

  (a) **READER-TOP**: the writer reads the top from `thread_userstack` (status.c:90/98, the value the
      kernel returns to userspace) and stores one page above it.  Then the reader IS
      `thread_userstack`'s consumer, and the fix is at that value/an offset in it.
  (b) **READER-BLOCK**: the writer reads the argv/env block's own top bound from something in the
      block (e.g. a header word) and adds.  Distinguishable from (a) only if we publish the block's
      [start,end) and show `far` is derived from THAT, not from `ustack`.
  (c) **NOT-A-READER**: the coincidence is false — the fault is at a fixed VA that happens to be
      `ustack + 0x1000` on THIS arm only (ASLR).  Refuted if, on the same row, `far - ustack` is a
      constant the writer cannot get from a fixed VA.

The 1026/1027 rows already give us `far`, `map`, `ustack`, and the far-4 covering entry. What they do
NOT publish is: (i) the covering entry AT the fault when `far` is inside an entry (they suppress the
`entry_*` rows when `lookup_far=0`), and (ii) the **process's argv/env block bounds** (`p->p_argc`,
`p->p_argslen`, or the block's `[sp, user_stack)` span) so "the writer tracks the block top" can be
told from "the writer tracks `user_stack`".  1029 publishes exactly those, in ONE row.

## 3. THE INSTRUMENT (probe-only; ONE new publisher, TWO sites, same switch discipline)

New switch: `STAGE90_XNU_READER_PROBE`.  Probe-only: no value is written, no lock is taken beyond what
the sites already hold, and the two sites are on the FAILING fault path only (the same place the 1025
prints already live).

### 3.1 Site A — `osfmk/arm/trap.c`, the usermode DATA-abort failure arm

**File:line:** `external/xnu-hd2-darwin13/xnu/osfmk/arm/trap.c:838-892` — the usermode DATA-abort
case (`case SLEH_ABORT_TYPE_DATA_ABORT:`, reached from `map = thread->map;` at :822 and the
`vm_fault(...)` call at :829-832), the `if ((code != KERN_SUCCESS) && (code != KERN_ABORTED)) {`
failure arm, INSIDE the existing
`#if defined(STAGE90_XNU_USTACK_PROBE)` publisher (1025) and AFTER the existing
`#if defined(STAGE90_XNU_ABT_ENTRY_PROBE)` block (1026/1027).  This is the ONE place in the tree
where, at the moment of the fault, ALL of the following are in scope simultaneously:

    dfar                    <- the faulting effective address (the store's VA)
    dfsr, arm_ctx->sp, arm_ctx->pc
    thread                  <- so thread->map, thread->task, thread->task->bsd_info
    map = thread->map       <- the map the walk used (set at trap.c:822)
    code                    <- the vm_fault return (KERN_INVALID_ADDRESS)

This is why Site A is in `trap.c` and not in `vm_fault`: `vm_fault` (`osfmk/vm/vm_fault.c:2766`) has
`map` and `vaddr` and the failing `vm_map_lookup_locked` return (`vm_fault.c:2855`, returning
`KERN_INVALID_ADDRESS` from `vm_map.c:8756`), but it does NOT have the PROCESS (`p->user_stack`,
`p->p_argc`, `p->p_argslen`) — those are `bsd/kern` fields and `vm_fault` is `osfmk`, which forward-
declares `struct proc` only.  1026 already solved exactly this by adding an accessor
(`xnu_live_abt_proc_ustack`, kern_exec.c:3586-3595 — the declaration/comment at :3580, the function
body at :3588) that `trap.c` calls by name; 1029 RE-USES it and
ADDS the block-bounds accessor beside it (§3.3).

### 3.2 The rows Site A publishes (ONE row per key, same non-ringed ram-console channel as 1025/1026)

    xnu_live_rdr_far            = dfar (page-aligned)         <- the faulting store's VA
    xnu_live_rdr_ustack         = p->user_stack               <- the ADVERTISED top (re-used accessor)
    xnu_live_rdr_far_minus_ustack= far - ustack               <- the DERIVATION distance (expect 0x1000)
    xnu_live_rdr_blk_lo         = block low bound             <- sp_lo from the accessor, §3.3
    xnu_live_rdr_blk_hi         = p->user_stack               <- the block's TOP bound (== p->user_stack)
    xnu_live_rdr_blk_bytes      = p->p_argslen                <- the argv/env block's own recorded size
    xnu_live_rdr_argc           = p->p_argc                   <- the recorded argc (block header sanity)
    xnu_live_rdr_entry_at_lo    = covering entry of far, lo   <- from vm_map_lookup_entry(map, far, &e)
    xnu_live_rdr_entry_at_hi    = covering entry of far, hi    (prints 0/0 when far is not in the map)
    xnu_live_rdr_entry_at_hit   = 1 if far is INSIDE an entry, 0 if not   (the READER-TOP tell: on 1028
                                  the far-4 word is mapped but far itself is not -> hit=0)

Site A does NOT touch `sp`, `far`, `map`, or any register: six `printf`s and ONE extra
`vm_map_lookup_entry` read (the same read-only call 1026/1027 already make on this path, no lock taken
in this tree — `VM_MAP_STORE_USE_LL`).  It runs ONLY when `vm_fault` already failed
(`code != KERN_SUCCESS && code != KERN_ABORTED`), i.e. strictly after the decision to deliver
`EXC_BAD_ACCESS` — nothing downstream consults these values.

### 3.3 Site B — `bsd/kern/kern_exec.c`, the accessor (extend, do NOT duplicate)

**File:line:** the 1026 accessor `xnu_live_abt_proc_ustack`, kern_exec.c:3586-3595 (already staged,
guarded by `#if defined(STAGE90_XNU_ABT_ENTRY_PROBE)`).  1029 ADDS a sibling accessor in the SAME
`#if`/namespace region, kern_exec.c immediately after :3595:

    /* 1029: the initial argv/env block's own bounds.  `p_argslen` is recorded by
     * exec_copyout_strings (kern_exec.c:2804-2805, `p->p_argslen = (int)(*stackp - string_area)`), so the
     * block's [sp, p->user_stack) span and its recorded byte length are readable from the proc. */
    unsigned xnu_live_rdr_proc_argc(void *bsd_info);
    unsigned xnu_live_rdr_proc_argslen(void *bsd_info);

(the STRING/PTR/ARGC areas themselves are `user_addr_t` locals inside `exec_copyout_strings`
(kern_exec.c:2700-2860) and are NOT in scope at fault time — the PROC's recorded `p_argc`/`p_argslen`
are the durable by-value stand-ins, and `p_argslen` is EXACTLY what `sysctl_procargs` returns).

Why not a `printf` inside `exec_copyout_strings` itself (one row per exec)?  Because the derivation
question is "what was true AT THE FAULT", and the block is built once per exec while the fault happens
later in userspace; publishing at exec time would print for every process and answer nothing (this is
the 1026 probe-defect lesson: a row that cannot fire on the H case is not a reading).  Site B exists
ONLY to make the two proc fields reachable BY NAME from Site A (the 1026 accessor idiom), under the
same switch.

### 3.4 Row-shape rule (the 1026/1027 lesson, [[mi4-1026-abt-entry-probe]])

Every row MUST be printed UNCONDITIONALLY on the failure path — NO `if (_hit)` gating of a row whose
value the verdict needs.  On 1026 the `entry_hi` row was gated on `_abt_hit`, so the H2 cell demanded
`entry_hi == far` while the probe was built to suppress it in exactly the H2 case: a self-
contradictory cell (H-OTHER was its fail-closed artifact).  1029 prints `entry_at_lo/hi` as `0/0` when
`far` is unmapped and `entry_at_hit=0` — the ZERO IS the reading, printed, never suppressed.

## 4. PRE-REGISTERED CELLS (decided before the build; each names its confirming VALUE)

    READER-NAMED     : far_minus_ustack == 0x1000 AND entry_at_hit == 0 AND blk_hi == ustack
                       AND blk_bytes == (ustack - blk_lo) AND far == ustack + 0x1000.
                       Meaning BY VALUE: the store is one PAGE above the advertised top `p->user_stack`,
                       the block's top bound IS `p->user_stack` (so the block did NOT grow), and `far`
                       is NOT covered by any entry.  The writer's store address is a function of
                       `p->user_stack`; the derivation is PROVEN.  (This is the expected reading: it is
                       1028's arithmetic reproduced with the process's own fields appended.)
    READER-UNKNOWN   : any OTHER combination -> fail closed, and the missing conjunct is NAMED in the
                       report (e.g. "blk_hi != ustack" names the block-top reader; "far_minus_ustack
                       != 0x1000" names the fixed-VA hypothesis (c); "entry_at_hit == 1" names
                       READER-BLOCK, because then the writer wrote INSIDE a mapped region and the
                       derivation is not from the top at all).  Do NOT pick a fix on READER-UNKNOWN.
    REGRESSION       : `*** launchd[1] has started up ***` absent, or trap24 rows vanish, or
                       port_construct result=0 rows vanish, or a panic appears -> WITHHOLD; the arm's
                       switch set is wrong ([[mi4-build-variant-comes-from-an-env-default]]).
    G-CTL            : no capture NEWER than this press's boot epoch -> WITHHOLD (the 1028 stale-slot
                       rule; a resident rung that does not return keeps no `/proc/last_kmsg` of its
                       own — [[mi4-last-kmsg-reader-carrier]]).

**NEVER A NEGATIVE.**  A cell is decided ONLY by a value PRESENT in a capture newer than the boot.  The
ABSENCE of a row is NOT evidence for anything except "the probe did not run" (G-CTL).  In particular:
`xnu_live_rdr_*` absent => the failure path was not reached on this arm (report G-CTL, do not read it
as "no fault").  `entry_at_hit=0` with `entry_at_lo/hi == 0` is a POSITIVE reading (far is unmapped),
not a missing one — but it is the PRINTED zero, not an absent line, that counts.  This is the
[[mi4-silence-is-a-reading-only-if-success-is-silent]] rule: here success is NOT silent (the row
prints on every failing fault), so silence means the path did not run.

**VALVE (do not over-read one row).**  `far_minus_ustack == 0x1000` on ONE arm is the SIGN of a page
offset, not proof of the constant: IF a later rung ever reads a different distance on a same-shaped
arm, the reader is not `+PAGE` and (a)/(b)/(c) must be re-discriminated — the DECISIVE conjuncts are
`entry_at_hit == 0` AND `blk_hi == ustack` together (the store left the map AND the block did not
move), not the literal `0x1000`.

## 5. WHAT 1029 DOES **NOT** DO

* Does NOT allocate a page (or a word) — 1028 proved the fault follows the top; a second allocation
  would move it again and read nothing.  Pre-registered: "report, do not re-fix".
* Does NOT change `sp`, the argv/env block, the guard, `p->user_stack`, `LAB_USER_STACK`, `MAXSSIZ`,
  or `VM_MAX_ADDRESS` (all measured-correct across 1011-1028).
* Does NOT add a second `vm_fault` call, take a map lock, or alter the `EXC_BAD_ACCESS` delivery.
* Does NOT add a fourth trap.c rung without re-staging the other three
  ([[mi4-one-file-many-rungs]]: 994 witness / 1020 undef_raise / 1025 probe / 1026 abt_entry / 1029
  reader).

## 6. FILE-LEVEL PLAN

1. **`tools/patch_d13_reader_probe.py`** — NEW.  Edits TWO files:
   * `osfmk/arm/trap.c` — insert Site A's block AFTER the 1026/1027 `#endif
     /* STAGE90_XNU_ABT_ENTRY_PROBE */` (trap.c:891) and BEFORE the 1025 block's `#endif
     /* STAGE90_XNU_USTACK_PROBE */` (trap.c:892).  Anchor: the exact `#endif /*
     STAGE90_XNU_ABT_ENTRY_PROBE */\n` tail, count==1; DONE_MARK `xnu_live_rdr_far=`.
   * `bsd/kern/kern_exec.c` — insert Site B's accessor block immediately after the 1026 accessor
     (kern_exec.c:3595, the `#endif /* STAGE90_XNU_ABT_ENTRY_PROBE */`), BEFORE the
     `create_unix_stack` comment (the 1026 patcher's `EXEC_INSERT_BEFORE` anchor).  DONE_MARK
     `xnu_live_rdr_proc_argslen`.
   * **RE-STAGE EVERY PRIOR EDIT to both files** ([[mi4-one-file-many-rungs]]).  trap.c is touched by
     994 witness / 1020 undef_raise / 1025 probe / 1026+1027 abt_entry; kern_exec.c by 1025
     (publisher + accessor... ) / 1026 (accessor) / 1028 (`create_unix_stack` extent).  This patcher
     must (i) check its DONE_MARK FIRST, before anchors; (ii) carry a `strip_old_block()` for the
     1025/1026 blocks if their DONE_MARK is present but its own token is absent (the 1027 idiom); (iii)
     be idempotent (a second `--apply` is a no-op); (iv) `--verify-off` proves the OFF arm is
     byte-identical (the `#if` idiom, [[mi4-off-option-two-spellings]]).
   * **`ALLOWED_IF_IDENTIFIERS` must carry EVERY other switch** that appears in an `#if` in each file:
     trap.c -> {`STAGE90_XNU_IOS7_TRAPS`, `STAGE90_XNU_UNDEF_RAISE`, `STAGE90_XNU_USTACK_PROBE`,
     `STAGE90_XNU_ABT_ENTRY_PROBE`, `STAGE90_XNU_READER_PROBE`}; kern_exec.c -> the union plus
     `STAGE90_XNU_H2_STACK_HEADROOM` and `STAGE90_XNU_READER_PROBE`.  AND the other three patchers'
     sets (1025's `TRAP_ALLOWED_IF_IDENTIFIERS`, 1026's, 1028's `ALLOWED_STAGE90`) must each GAIN
     `STAGE90_XNU_READER_PROBE`, or the shared-namespace check refuses.

2. **`scripts/build_1029.sh`** — carry 1028's FULL switch set VERBATIM (read out of
   `scripts/build_1028.sh`'s `export STAGE90_*` lines; the 1028 record says the set is 65 switches),
   **ADDing** `STAGE90_XNU_READER_PROBE=1` — never replacing
   ([[mi4-build-variant-comes-from-an-env-default]]; the 1028 build record's Defect 2 was exactly a
   replacing export).  Re-stage every kern_exec.c/trap.c edit IN ORDER: 1025 trap publisher, 1025
   kern_exec publisher, 1026 abt_entry (trap + accessor), 1027 amendment (stripped/re-staged), 1028
   H2 headroom, then 1029.  Gate (`6b` idiom): the LINKED image's `trap.o` carries the string
   `xnu_live_rdr_far=` AND `kern_exec.o` carries `xnu_live_rdr_proc_argslen`, read by value from the
   OBJECTS, not the record; `comm` of the two scripts' switch sets must differ by EXACTLY
   `STAGE90_XNU_READER_PROBE`.

3. **`tools/check_1029_capture.py`** — the four cells of §4 + the 1025/1026/1027 re-reading
   (FAULT-NAMED / H2 must still fire) + REGRESSION + G-CTL; `--selftest` with (i) a capture shaped
   like 1028's measured one plus a `xnu_live_rdr_*` row -> READER-NAMED, and (ii) a capture where
   `entry_at_hit == 1` -> READER-UNKNOWN naming the block-top conjunct.  `grep -qa P <(strings X)`,
   NEVER the pipe form (`strings|grep -q`, 141 under pipefail —
   [[mi4-mutation-anchors-are-code-spans]] m1025).

4. **`scripts/{park,press}_1029.sh`** — the 1028 idiom; the negative control points at a PRE-rung arm
   (NOT 1029's own, NOT 1028's own); the press stamps its boot epoch and REFUSES to read a capture
   older than it (the 1028 stale-slot guard — the reading must be NEWER than the boot,
   [[mi4-stale-slot-impersonates-a-reading]]); `wait $USB_PID` gets `set +e`
   ([[mi4-unguarded-wait-aborts-resident-press]]: 1024/1025/1026/1027 all lost their own readings
   this way; 1028 fixed it — do not regress it).

5. **`records/1029-press-read.txt`** — the reading, by value.

## 7. RISK — WHAT MUST NOT CHANGE, AND WHY A PROBE IS SAFE

**MUST NOT change (any of these changing turns a probe into a fix):**

    sp                       <- the userspace ABI's argv/env base; every consumer reads argc at sp.
    the argv/env block       <- `exec_copyout_strings`' arena and its `stack -= ...` arithmetic.
    the guard page           <- prot_addr == addr, prot_size == 0x1000 (the bottom page).
    p->user_stack            <- the stack's ADVERTISED top, returned to userspace (status.c:90/98);
                                changing it is a silent ABI change and RAISES the fault (1028 proved
                                the writer derives from it).

**Why a probe is safe, by value:**

* Both sites are on the FAILING path only: Site A runs strictly after `vm_fault` already returned
  non-SUCCESS and the trap already decided `EXC_BAD_ACCESS` (trap.c:838 arm; the delivery at :916); Site B is a
  pair of read-only accessors called only from Site A.  No successful fault and no successful exec
  takes any new branch.
* Site A takes NO new lock.  The extra `vm_map_lookup_entry(map, far, &e)` is the SAME read-only call
  1026/1027 already make on this exact line range (`vm_map_lookup_entry` in this tree takes no lock —
  `VM_MAP_STORE_USE_LL`, reads `map->hint` + entry links), on the faulting thread's own map, before
  any mutation.
* Site B's accessors return fields ALREADY in `struct proc` (`p->user_stack`, `p->p_argc`,
  `p->p_argslen`); they read, never write, and guard NULL (`bsd_info == NULL` -> 0), exactly like the
  1026 accessor.
* The switch is OFF by default: with `STAGE90_XNU_READER_PROBE` undefined, both files compile
  BYTE-IDENTICAL to the 1028 tree (`--verify-off` proves it against the real preprocessor).
* Reversible medium: the arm is `fastboot boot` only, never flash; the CARD COW ([[mi4-hardware-run-safety-gate]]);
  park + revert-set before the press.

## 8. THE ONE THING THAT WOULD FALSIFY THIS DESIGN (state it, so 1029 does not over-read)

**UPDATE 2026-10-17 — the design is ALREADY FALSIFIED, before the 1029 reading came back.**  The
premise stated in §0-§2 ("the writer derives its store address FROM `p->user_stack`") is refuted by
the prior captures themselves, read by value:

| rung | far | ustack | far−ustack |
|---|---|---|---|
| 1025 | 0x2bd35000 | 0x2bd35000 | 0 |
| 1026 | 0x2bdeb000 | 0x2bdeb000 | 0 |
| 1027 | 0x2bde0000 | 0x2bde0000 | 0 |
| 1028 | 0x2bd0e000 | 0x2bd0d000 | 0x1000 |

If a writer added a constant page to `p->user_stack`, 1025-1027 would each have faulted a page ABOVE
their region top.  They faulted EXACTLY AT it.  So **`far` is ALWAYS the region's EXCLUSIVE TOP**;
the 1028 fix moved the top by one page (`size+16` → `round_page` → `+0x1000`) and the fault FOLLOWED
it.  The fault is a **BOUNDARY WRITE at the region end**: the region is short by one page.  The
`far - ustack` column is a *consequence of the top having moved*, not a "derivation distance".

The CORRECT next-rung direction (§5's "do NOT add to `size`" is now the whole story): make the
region's exclusive top land STRICTLY ABOVE the block top by a whole page — anchor the base one page
LOWER (`addr = trunc_page(user_stack - size) - PAGE_SIZE`) or set the allocation so
`top >= round_page(user_stack) + PAGE_SIZE`.  Adding to `size` alone can never do it: `size + Δ`
always rounds up to a page-aligned top.

The ORIGINAL falsifier below still stands as the *other* branch (an adjacent-object collision):

If Site A publishes `xnu_live_rdr_entry_at_hit = 1` for the faulting `far` — i.e. the store DID land
inside a mapped entry — then `far` is NOT the region's unowned end; a different entry covers it and
this is an ADJACENT-OBJECT COLLISION (which also reopens the 1013c/1015 "a mapped VA still failed the
lookup" walker family).  That is a READER-UNKNOWN reading; the design REFUSES to pick a fix on it,
and the NEXT rung instruments the walker (`vm_map_lookup_locked`, vm_map.c:8756) and reads WHICH
entry follows `far`.  Fail closed.