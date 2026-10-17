# 1032 DESIGN — CONDITIONAL: the caller of the boundary writer, keyed on 1031's cell

Status: **DESIGN ONLY. Nothing here is built, staged, scripted, or pressed. No source file, script or
record is touched by this document.** Every claim below is either quoted BY VALUE from a committed record,
or explicitly marked as a PREDICTION that the named rung must MEASURE.

**This document picks NO fix.** Its whole structure is that **1031's cell SELECTS among the branches**.
Three of the four branches end in "no fix is selected yet"; the fourth (CAL-CALLER-OTHER) ends in "no fix
at all". §0 states what is settled and what is open; §1–§3 give the three branches (fix class, where it
belongs, the by-value instrument that measures whether it works, and its falsifier); §4 is the
fail-closed branch; §5 is the shared build/blast-radius/one-file-many-rungs material; §6 is the STANDING
FALSIFIER — the clause that fires for EVERY branch and that no amount of 1031 data can defeat.

---

## 0. WHERE 1031 STANDS

### 0.1 The premise (settled, BY VALUE)

1030 read **W-B-NAMED** (`records/1030-press-read.txt`; capture
`recovered-unknown-arm-20261017-064216-last_kmsg.txt`, mtime 06:42:16 = epoch 1792218196 > the press's
boot epoch 1792217325, staleness discharged; arm `armed-d13-8034562e`). All 14 `xnu_live_wrp_*` rows:

    xnu_live_wrp_r4              = 0x2bdae000   (the faulting store's destination cursor)
    xnu_live_wrp_r6              = 0x2bdae000   (== r4: the LOCKSTEP output cursor)
    xnu_live_wrp_r12             = 0x00004000   (16 KiB — the copy/VLA extent)
    xnu_live_wrp_sp              = 0x2bdac074
    xnu_live_wrp_pc              = 0x38b52756   (userspace, slid)
    xnu_live_wrp_lr              = 0x38b4a9af   (the CALLER — still unresolved to a call site)
    xnu_live_wrp_userstack       = 0x2bdad000
    xnu_live_wrp_r4_minus_ustack = 0x00001000   (one PAGE above the advertised top)
    xnu_live_wrp_far             = 0x2bdae000
    xnu_live_wrp_r4_minus_far    = 0x00000000
    xnu_live_wrp_block_bytes     = 188

The writer is `/usr/lib/libobjc.dylib + 0x14756` (`records/1029-press-read.txt`; the VA→offset rule is the
cache's OWN mapping table, `file_offset(v) = map[i].fileOffset + (v − map[i].address)`, NOT
`v − 0x2c000000`, which is a map0-only coincidence):

    37c266ec: push {r4,r5,r6,r7,lr} ; add r7,sp,#12
              mov  r4,r3        ; r4 (the FAULTING cursor) = the caller's 4th ARGUMENT
              mov  r6,r2        ; r6 (the LOCKSTEP cursor) = the caller's 3rd ARGUMENT
              mov  r5,r0        ; r5 = the caller's 1st ARGUMENT (the table base)
    37c26742: ldr.w r2,[r1,#-4] ; subs r0,#1 ; add r2,r5 ; str.w r2,[r6],#4   ; cursor #1 (r6)
    37c2674e: ldr   r2,[r1,#0]  ; add r1,#8  ; add r2,r5
    37c26756: str.w r2,[r4],#4  ; <-- FAULT (r4 == far)                        ; cursor #2 (r4)
    37c2675a: bne.n 0x37c26742                                                  ; loop
    37c2675c: pop  {r4-r7,pc}

`r4 == r6` at the fault while the function sets them from `r3` and `r2` SEPARATELY ⇒ the caller passed
`r2 == r3 == far`. **The boundary decision is therefore in the CALLER.** Both the 1030 audit negative and
`docs/1031-design.md` §0 state it: the fault function ALONE does not discriminate how the caller produced
that address.

**※ TWO CROSS-CHECK DISCREPANCIES (records/1031-caller-derivation.txt §5).** The 1030 frame's `r3 =
0xffffffff` while `r4 = r6 = 0x2bdae000` — so "r4==r6 ⇒ caller passed r2==r3==far" is an INFERENCE from
`mov r4,r3; mov r6,r2`, not a reading (at the fault `r3` has been reused; the dump is not the entry frame).
And the disasm lane's claimed `r5 = 0x3b868c00` does NOT cross-check: the frame's `r5 = 0x38c9ec00`
(unslides to `0x37D72C00`). The lane's `lr` (`0x38b4a9af` → `0x37C1E9AF`) DOES cross-check. Treat any
register VALUE that does not cross-check as unsupported ([[mi4-measurement-defects]]).

The same `.text` window carries a `sub.w rN, sp, r#N, lsl #2` (a downward `alloca`). **CORRECTED
2026-10-17 (see docs/1031-design.md §5 CORRECTION 2 and records/1031-caller-derivation.txt): this
downward alloca IS the producer of the caller's `r3` — it is NOT refuted.** An earlier draft of this doc
(and of 1031 §5) asserted the opposite by comparing the alloca BASE against the OBSERVED `r4`; but `r4`
is a **post-increment cursor** (`str.w r2,[r4],#4`), so its INITIAL value (the alloca base, BELOW `sp`)
and its OBSERVED value (`base + 4·k` after `k` iterations, which legitimately ends ABOVE `sp`) are
different points in the cursor's life. The caller (`0x37C263CC`) does `sub.w r4,sp,r5,lsl #2; mov sp,r4;
sub.w r6,sp,r5,lsl #2; mov sp,r6; mov r3,r6` at both call sites (`0x37C26464`, `0x37C26550`) and passes
`r3` = the LOW end of a `count`-word block carved below `sp`; the writer's cursor walks it UP. So the
mechanism is **cursor-overshoot of an under-sized block (or a `count` one element too large)**, not a
wrong alloca direction. **Do NOT write a branch narrative that flips the alloca to `add`.**

### 0.2 The GEOMETRY fix is REFUTED, and precisely why (this binds every branch below)

Population across all 61 captures (`records/1030-audit.txt` ADDENDUM 2, the lead's re-run):

    ustack - sp   == 0xF8C    in ALL runs      (the argv/env block size is INVARIANT)
    far - ustack  == 0        in 57 runs       (pre-H2: far == the region's exclusive top)
    far - ustack  == 0x1000   in  3 runs       (post-H2 ONLY: 1028 x2 + 1029 x1)
    far == e2_hi  in EVERY run with an e2 row
    NO other value of (far - ustack) ever appears

⇒ **`far` == the region's EXCLUSIVE TOP in every measured run, and the ONLY mover of `far` is H2 growing
the region.** 1028 (`STAGE90_XNU_H2_STACK_HEADROOM`, `kern_exec.c:3690`, extent `size` → `size + 16`)
grew the region by a whole page (`mach_vm_allocate` calls `vm_map_round_page`, `vm_user.c:220`) and the
fault **FOLLOWED, page-exact**: `far - ustack` 0 → 0x1000, `far - sp` 0xF8C → 0x1F8C, `ustack - sp`
UNCHANGED at 0xF8C (`records/1028-press-read.txt`; `xnu_live_ustack_rc = 0`, so the FIXED allocate
succeeded — not a silent ANYWHERE fallback).

> **Therefore: ANY fix of the "add another page to the region" / "move the base down a page" / "own the
> page at the top" class is REFUTED and MUST NOT appear in any branch below.** Owning the top page means
> extending the extent; extending the extent moves the top; the writer targets the top; the fault
> follows. The base-down variant is additionally dead arithmetically (audit1030 CHECK 1: base-down and
> extent-up CANCEL, `top = (user_stack − size − PAGE) + (size + PAGE) = user_stack`, unchanged). There is
> no version of "re-size the region" that is not 1028.

**Consequence for every branch: the fix, if one is selected at all, lives OUTSIDE the region geometry.**
That leaves exactly two places: **(i) the caller's address computation** (which instruction / which field
produced `r3`), and **(ii) the value the caller READ** (the field or global it loaded to compute it).
Those are the only two fix-classes that are not already refuted.

### 0.3 The open question — and the fact that 1031 is not yet read

1031 (`STAGE90_XNU_CALLER_PROBE=1`, arm `armed-d13-49031dcb`, `docs/1031-design.md`, `tools/patch_d13_caller_probe.py`)
publishes the caller's register frame plus a *printed* region-end lookup (`vm_map_lookup_entry(map,
trunc_page(far) − 4, &e); e->vme_end`) and a Site B accessor for the allocator's own top
(`xnu_live_cal_proc_region_top`, fed by a `p->p_live_stack_top` stash at `kern_exec.c:3705-3714`/`3726-3730`).

**1031's press was a NON-RETURN and its capture is WITHHELD** (`records/1031-press-read.txt`; boot epoch
1792222536, 2026-10-17 07:35:36 UTC; runner exit 2, USB console ZERO BYTES, device dark; step 5 correctly
printed **NO READING - STALE SLOT**). The newest capture on disk is 1030's own slot, older than the boot.

**So this document is written BEFORE the reading exists.** It is conditional in the strict sense: each
§1–§4 section names the cell that would open it, and §6 is the clause that binds regardless. The branches
are the four pre-registered cells of `docs/1031-design.md` §2, as implemented by
`tools/check_1031_capture.py` (fail-closed, never a negative):

    CAL-CALLER-TOP    region_end_hit == 1 AND region_end == far AND r3 == r2 == far AND r7-sp == 0xC
    CAL-CALLER-SIZE   r3 == r2, r3 != region_end, 0 < (region_end − r3) <= 0x1000
    CAL-CALLER-OTHER  a complete frame naming neither shape (fail closed, name the missing conjunct)
    CAL-MISSING       the cal group did not print  =>  WITHHELD (never a negative)

---

## 1. BRANCH A — `CAL-CALLER-TOP`: the caller handed the writer the region's exclusive top

### 1.1 What the cell means (the caller-side computation it names)

The map's OWN `vme_end` for the entry covering `[far−4, far)` **IS** `far` (`region_end_hit == 1`,
`region_end == far`), and the caller passed that exact address as BOTH cursors (`r3 == r2 == far`), with
the writer's frame shape intact (`r7 − sp == 0xC`, the prologue `add r7,sp,#12` — so the frame we read is
the RIGHT call site and not a lookalike).

**Named computation:** the caller derived `r3` as *the stack region's exclusive top* — the address it
believes is the end of the stack region — and handed that value to a 16 KiB table-rebase copy
(`r12 = 0x4000`) as its output base. The address is an **END**, not a `base + size`; the two operands the
caller might have combined are already merged by the time the value reaches `r3`.

**What the cell does NOT say — and this is the load-bearing negative.** `r3 == region_top` is consistent
with *at least two* distinct upstream computations, and 1031's rows cannot separate them:

    A1  the caller LOADED a stored top      (a field/global that equals the region top)
    A2  the caller COMPUTED the top         (e.g. `sp` + a constant, or `p->user_stack`-derived)

The `sp`-anchor trap is live here and must be quoted: `sp = 0x2bdac074`, `user_stack = 0x2bdad000`,
`ustack − sp = 0xF8C` (the block size, INVARIANT across all 61 captures). **`sp` and the region top are
ONE anchor** — so `r3 == sp + 0x1F8C` and `r3 == user_stack + 0x1000` are the SAME statement. A
`sp`-relative tell holds TRIVIALLY on this arm and *cannot discriminate*. `records/1030-press-read.txt`
calls reading it as W-A a MEASUREMENT DEFECT (`[[mi4-measurement-defects]]`). **No branch below may be
keyed on `r4 − sp`.**

`records/1030-press-read.txt`'s own NEXT section points at the limit/ownership accounting around
`create_unix_stack` / the exec's advertised stack top. `docs/1031-design.md` §0b (D) sharpens it: a
16 KiB buffer whose **END the caller set to the stack top** — i.e. the caller laid a `[top − 0x4000, top)`
buffer down and the loop walked past `top`.

### 1.2 The candidate fix class, and WHERE it belongs

**Candidate class: (B) — the caller's derivation of the address is the lever.** Two sub-classes, and
**1032 does not choose between them; 1031's own rows cannot, and neither can this document**:

* **A1 — a STORED top.** The caller loads the address from a field/global that happens to equal the
  region top (candidate: `p->user_stack` / the value `thread_userstack` advertises
  (`osfmk/arm/status.c:82-101`), or an objc/table-rebase bookkeeping field). Then the lever is **the
  value that field holds** — i.e. the value must be corrected at its SOURCE, because the writing party
  computes from a value we already changed once and it tracked us (`[[mi4-a-window-is-an-interval-not-a-function]]`,
  the "the boundary can be in a READER" shape 1028 already exhibited).
* **A2 — a COMPUTED top.** The caller computes the end itself (e.g. a `[…, top)` buffer bound), and the
  lever is the **caller's own computation**.

**WHERE the fix belongs, stated negatively and then positively.** It is **NOT** in the region's extent,
base, guard, `p->user_stack`, `LAB_USER_STACK`, `MAXSSIZ` or `VM_MAX_ADDRESS` — §0.2 refutes all of
those, and 1028 is the proof. It IS in **whichever of A1/A2 the caller's INSTRUCTIONS show** — and that
requires the caller's **instructions**, which 1031 does not publish (only its REGISTERS).

**Honest status of branch A: NO FIX IS SELECTED by 1031 alone.** `CAL-CALLER-TOP` converts the 1030
inference into a printed conjunction; it names the caller's *derivation shape*, not its *instruction*.
The disassembly that names the instruction is a separate, static step (§6.2), and 1031 was explicitly
pre-registered to say so (`docs/1031-design.md` §5: "if the caller's `lr` is unresolved, the fix is NOT
picked and the next rung is a STATIC disassembly of `libobjc` around `lr`").

### 1.3 The by-value instrument that would MEASURE whether an A1/A2 fix works

The instrument is a **rung with a candidate fix and a by-value PROOF OF THAT FIX'S EFFECT**, in the shape
of the existing rungs. It is **conditional twice**: it must be selected by the disassembly (§1.2), and it
must be measured on the resulting capture. Concretely, if the disassembly names **A1 (a stored top)**:

**New switch:** `STAGE90_XNU_CALLER_SOURCE=1` (probe — prints, changes no geometry).
**Staged:** the SAME Site A (inside 1025's `STAGE90_XNU_USTACK_PROBE` publisher, after 1031's block) via a
NEW `tools/patch_d13_caller_source_probe.py`, plus the Site B namespace region in `kern_exec.c`.

**The rows it must print (each UNCONDITIONAL — the 1026 lesson, `[[mi4-1026-abt-entry-probe]]`):**

    xnu_live_cal_src_caller_pc        = the caller's own pc (NOT the writer's) — see §1.4
    xnu_live_cal_src_top_thread       = thread_userstack's advertised top for THIS thread   (arm/status.c)
    xnu_live_cal_src_top_proc_ustack  = p->user_stack                                       (1026/1029 accessor)
    xnu_live_cal_src_top_alloc_stash  = p->p_live_stack_top                                 (1031 Site B)
    xnu_live_cal_src_top_map_vmeend   = the covering entry's vme_end for `far − 4`          (1031 Site A idiom)
    xnu_live_cal_src_r3_minus_each    = r3 − (each of the four above)   <- THE DISCRIMINATOR
    xnu_live_cal_src_r12              = the copy extent                  (1030: 0x4000)
    xnu_live_cal_src_r3_minus_r12     = r3 − r12     <- "is r3 a `[., top)` base?" by value

**The discriminating reading, by value.** If `r3 − top_X == 0` for exactly ONE of the four candidate
tops `X`, the caller's source is NAMED as `X` and the fix belongs at whoever writes `X`. If
`r3 − r12 == 0` (i.e. `r3 = top − 0x4000`), the caller laid a `[top − 0x4000, top)` buffer and the
boundary is the caller's **size**, not the top — that is branch B (§2), reached from A.

**Arm-identity rule (the project's rule, unchanged):** the arm id IS
`armed-d13-$(sha256sum out/stage90/xnu_arm_entry.bin | cut -c1-8)`; the new switch moves the pool
(`trap.c` and `kern_exec.c` are BOTH pool files), so the pool moves and the entry `.bin` — and therefore
the arm — moves with it (`scripts/park_1031.sh:94`). **The arm must NOT be `armed-d13-49031dcb`** (1031's
pressed arm, `records/1031-press-read.txt`), nor any parked arm; the park's static refusal list is the
pattern (`scripts/park_1031.sh:95-97`).

**The park/press/checker trio** — same three scripts, same shapes, new rung numbers:

* `scripts/build_1032.sh` — models `scripts/build_1031.sh`: reads `$REC`, carries 1031's whole
  `STAGE90_XNU_*` set **VERBATIM** from the record (never a default,
  `[[mi4-build-variant-comes-from-an-env-default]]`), ADDS `STAGE90_XNU_CALLER_SOURCE=1`, and refuses if
  any parent switch is missing or carries a non-`1` value. Gate checks: the new switch appears in
  `tools/build_xnu_arm_kernel.sh`'s global `DEFINES` array, in `src/entry/build_entry.sh`'s
  `ENTRY_ARM_KEYS`/arm-key case/record writer, in `scripts/preflight_boot_check.sh`'s `ENTRY_CFG_KEYS`
  (+ its `-z` grace branch), and in EVERY `ALLOWED_*_IF_IDENTIFIERS` set in §5.2. It must ALSO arrest a
  `-DSTAGE90_XNU_CALLER_SOURCE` in EXTRA (`build_1031.sh:182`'s shape — the 1020 build-defect channel).
* `scripts/park_1032.sh` — the `park_1031.sh` shape, `MEMBERS=(…)` the same 13 files, role carrier
  `STAGE90_XNU_GLOBAL_FIX=1 role=1032-caller-source`, with the FROZEN re-read on the parked bytes (a
  park that freezes bytes it did not certify is the defect `park_1031.sh:327-353` guards).
* `scripts/press_1032.sh` — the `press_1031.sh` shape: step-0 record gates in ORDER (this rung's switch
  FIRST, then each parent), the boot-epoch staleness stamp, the by-value fingerprints on BOTH the pool
  objects AND the LINKED image (the object-vs-linked split), `fastboot boot` ONLY, the USB reader armed
  FIRST, and on NON-RETURN: print NO READING and do NOT clear the slot.
* `tools/check_1032_capture.py` — models `tools/check_1031_capture.py`. Its key list must include EVERY
  emitted `cal_src_*` row (the 1030 `[[mi4-one-value-two-definitions]]` defect: `WRP_KEYS` listed 9 of 14
  emitted rows, `group_rows` split the group, and a COMPLETE capture read as W-OTHER). It must carry a
  `--selftest` that (a) builds fixtures from the patcher's REAL emission order and (b) asserts the cell is
  UNCHANGED when emitted-but-unread rows are stripped (the group-split guard, `check_1031_capture.py:441-450`).

**And the record:** a NEW arm MUST be recorded BY HAND in `records/revert-set.txt` BEFORE its press
(`[[mi4-self-written-record-is-not-a-constraint]]`; the 1030 press's own revert-set clause REFUSED the arm
until the record existed — that cost one press cycle, `mi4-1030-writer-probe-pressed`). Write the 13-file
set under the new arm id and commit it BEFORE the press.

### 1.4 The falsifier — what measurement would REFUTE branch A's candidate fix

In order of strength:

1. **REFUTED BY THE DISASSEMBLY (before any press).** If the caller's instructions show the address is
   NOT derived from a stored top and NOT computed as a `[…, top)` bound — e.g. it is a table/selector
   base plus a fixed offset, or a value that is *coincidentally* equal to the region top — then **both
   A1 and A2 are refuted as descriptions of the computation**, and the "LEVER = the caller's derivation"
   label is WRONG for this fault: the coincidence must be broken some other way. This is the cheap
   falsifier and it fires BEFORE the instrument is worth building. **The static disassembly is the first
   act of branch A, not a fallback.**
2. **REFUTED BY `r3 − r12 == 0`** (with `r12 = 0x4000`): the caller's buffer END *is* `top − r12`, so the
   address is a **buffer base**, not a top — branch A's premise ("the caller derived the TOP") is
   mis-stated and branch B (§2) is the correct branch.
3. **REFUTED BY THE FIX'S OWN CAPTURE — the by-value proof of INEFFECTIVENESS.** A fix in the caller's
   derivation is *effective* only if the fault **VANISHES** (no `cal` group at all on a boot that
   otherwise reaches launchd), or **MOVES to a value that is demonstrably no longer `region_top`**. If the
   new capture shows `far` still `== region_top` and the fault at the SAME geometry, the fix is a
   **FIX-NOOP of the 1028 class** and the derivation is NOT where the address comes from — exactly the
   1028 lesson: "a present-but-ineffective fix reads as the fault having MOVED, not vanished"
   (`[[mi4-1028-fix-noop-page-exact-h2-refuted]]`).
4. **NOT A FALSIFIER, and must not be read as one: a fix that merely moves `far` by a constant.** The
   population (§0.2) shows `far` tracks the region top in every run; a fix that changes the top changes
   `far` and proves nothing. The certification that a fix is *present* (an `rc = 0`, a by-value
   disassembly delta) is INDEPENDENT of whether it *works*.

---

## 2. BRANCH B — `CAL-CALLER-SIZE`: the caller produced a `base + size` one page short of the region end

### 2.1 What the cell means

`r3 == r2` (one value, two cursors), `r3 != region_end`, and `0 < (region_end − r3) <= 0x1000`: the address
is NOT the region's exclusive top, but sits a SMALL (at most one page) distance below it, with the lookup
still hitting (`region_end_hit == 1`).

**Named computation:** the caller produced the write address as a **base + size expression** whose result
lands one page short of the region end. The address the writer is handed is the **caller's own buffer
end** — not the stack region's end. `docs/1031-design.md` §2 gives the same reading and adds the
requirement: **naming the size needs the caller disassembled.**

### 2.2 The candidate fix class, and WHERE it belongs

**Candidate class: (C)/(D) — the caller's own buffer size / bound is the lever.** Where it belongs:

* If the off-by-one-page is an **integer/rounding slip in the caller's size** (e.g. the caller computed
  `n` entries and wrote `n + 1`, or rounded a bound the wrong way), the fix belongs **in the caller's
  computation** — a userspace/shared-cache edit, or (if the size arrives from the kernel) at the kernel
  value that feeds it.
* If the size is **correct for the caller's buffer but the buffer is placed wrongly** — i.e. the caller
  asked for a buffer ending at `top − 0x1000` because that is the value it was TOLD — then the lever is
  the **value it was told**, and the fix belongs to whoever advertises that value (`p->user_stack` /
  `thread_userstack` / `sp` setup). This is the boundary-is-in-a-READER shape again.

**Same negative as branch A, verbatim:** the fix is **NOT** in the region's extent/base/guard. A region
re-size would move the top and the caller's `base + size` would follow it if the base or size is itself
top-derived — and 1028 already demonstrated the follow at page granularity.

**Honest status: NO FIX IS SELECTED by 1031 alone.** `CAL-CALLER-SIZE` names the *shape* (base + size,
one page short) and the *distance* (`region_end − r3`, a printed value), but **which size, and which
base, is an instruction-level question.** 1031 publishes `cal_r3`, `cal_region_end`, `cal_r3_minus_region_end`
and `cal_r12` — enough to state the arithmetic, not enough to name the expression.

### 2.3 The by-value instrument

Because branch B's key row is a **distance the caller must be shown to have produced**, the instrument is
a probe that **prints the candidate decompositions of `r3` and, above all, the CALLER's own
instructions**. Concretely:

**New switch:** `STAGE90_XNU_CALLER_FRAME=1` (probe; prints, changes no geometry).
**Staged:** Site A (inside 1025's publisher, after 1031's block) via a NEW
`tools/patch_d13_caller_frame_probe.py`; no `kern_exec.c` change is strictly required for the arithmetic
rows (Site A already has `map`, `dfar`, `arm_ctx`, `thread`), but the region-top rows it compares against
are 1031's Site B accessor — so the parent's accessor must stay linked.

**The rows it must print (each UNCONDITIONAL):**

    xnu_live_calf_r3_minus_region_end   = the printed distance (1031 emits this; re-emit it)
    xnu_live_calf_r3_minus_r12          = r3 − r12
    xnu_live_calf_r3_minus_ustack       = r3 − p->user_stack
    xnu_live_calf_r12_mod_page          = r12 & 0xFFF       <- a rounded/unrounded extent tell
    xnu_live_calf_r12_div_page          = r12 >> 12         <- the page count the caller used
    xnu_live_calf_r3_mod_page           = r3  & 0xFFF       <- a non-page-aligned base is a fingerprint
    xnu_live_calf_caller_lo             = 4 words of the CALLER's stack, IF AND ONLY IF a SAFE read
                                          (§2.4) — the caller's own spilled bound lives here, or nowhere

**The discriminating reading, by value.** If `r3 + r12 == region_end` EXACTLY, the caller's buffer is
`[region_end − r12, region_end)`: the caller placed its buffer END at the region top and the base is what
the writer was handed — the boundary is the **caller's buffer placement**, and the fix belongs there.
If `r3 mod page != 0` while `region_end` and `region_end − r12` are both page-aligned, the address is a
**byte-granular** computed value (a real `base + size`), which points at the size arithmetic rather than
at any region value. If `r12 mod page != 0`, the extent the caller used is not page-rounded and a
`round_page` is the candidate.

**Arm-identity rule, park/press/checker trio, and the hand-written `records/revert-set.txt` clause:** all
identical to §1.3, with 1032's numbers and `role=1032-caller-frame`; the three scripts model
`build_1031.sh` / `park_1031.sh` / `press_1031.sh` and the checker models `check_1031_capture.py`
including the emitted-row parity selftest and the group-split guard.

### 2.4 The standing limitation that makes a read SAFE-or-nothing

`docs/1031-design.md` §5 last bullet binds here and is quoted rather than restated: **Site A does NOT
`copyin` the caller frame.** Reading user memory on the failure path (`vm_fault` has already returned
`KERN_INVALID_ADDRESS`) risks a nested fault. Any instrument that wants the caller's spilled bound MUST
either (a) read it from a kernel-safe source, or (b) find a safe read AFTER the thread is marked (e.g.
from the exec's own path), and must say which. **An instrument that cannot read it must print nothing for
that row and be judged on the rows it can print** — an absent row is `CAL-MISSING`, never a negative (the
1026 defect, `[[mi4-1026-abt-entry-probe]]`).

### 2.5 The falsifier — what measurement would REFUTE branch B's candidate fix

1. **REFUTED BY `r3 == region_end`** (i.e. 1031 actually reads `CAL-CALLER-TOP`): the "one page short"
   framing is wrong by value and branch A is the branch. **The cells are mutually exclusive by
   construction and the checker tests TOP first** (`check_1031_capture.py:251-267`), so this is a
   selection, not a defect — but a narrative that asserts SIZE on a TOP capture is a measurement defect
   (`[[mi4-measurement-defects]]`).
2. **REFUTED BY `r3 + r12 != region_end`** for EVERY candidate `r12` the caller could have used: the
   buffer-placement story is refuted; the address is not a `[…, top)` base and the size is not the
   caller's copy extent. Then branch B's lever is unnamed again and the rung reverts to a disassembly.
3. **REFUTED BY THE FIX'S OWN CAPTURE**: a size/placement fix must make the fault **vanish**, not move.
   If `far` is again `== region_top` after the fix, it is a FIX-NOOP of the 1028 class. A fix that changes
   the distance (`region_end − r3`) but leaves the writer still targeting an address at the region's edge
   has relocated the boundary, not removed it — the **boundary-can-be-in-a-reader** trap
   (`[[mi4-a-window-is-an-interval-not-a-function]]`).
4. **NOT A FALSIFIER: an unchanged `far`.** `far` is the *fault address*, and the instrument's own premise
   (§0.2) is that it tracks the region top. Reading an unchanged `far` as "the fix failed" is only valid
   TOGETHER with an unchanged caller derivation; `far` alone cannot decide it.

---

## 3. BRANCH C — `CAL-CALLER-OTHER`: the frame is complete but names NEITHER shape (fail closed)

### 3.1 What the cell means

Any OTHER combination of the present `cal_*` rows with `cal_region_end_hit == 1` — e.g. `cal_r3 != cal_far`
(the two cursors DIFFER from 1030's `r2 == r3 == far`), or the loud frame shape is wrong
(`r7 − sp != 0xC`, i.e. an early return before the call, so we read a lookalike frame).
`docs/1031-design.md` §2 is explicit: **NAME the first failing conjunct. Do NOT pick a fix.**

`check_1031_capture.py` implements this in two places and both must be honoured:

* the frame-shape leg — `r3 == far == region top` holds but `r7 − sp != 0xC` ⇒ `CAL-CALLER-OTHER`, NOT
  `CAL-CALLER-TOP` (`check_1031_capture.py:256-261`);
* the fall-through — a complete frame matching neither predicate
  (`check_1031_capture.py:283-289`).

### 3.2 The candidate fix class — there is NONE

**Files no fix. No candidate class. Nothing is selected, and nothing may be.** The honest consequence of
`CAL-CALLER-OTHER` is that the writer's shape itself must be **re-derived**: either the caller's two
cursor arguments differ (and 1030's `r2 == r3` register reconciliation was a measurement artifact), or the
frame we read is not the call frame we think it is (an early return / a lookalike). Both of those
invalidate an input to EVEN §1 and §2 — **a fix picked here would be a fix picked on a refuted premise.**

### 3.3 What replaces the instrument

Not a fix probe: a **re-derivation**. Two steps, in order:

1. **The reader lane's image table.** `records/1029-press-read.txt` names the correct VA→offset pipeline
   (the cache's OWN mapping table, `file_offset(v) = map[i].fileOffset + (v − map[i].address)`; map0
   `[0x2c000000..0x38266000)` off 0, map1 `[0x38268000..0x39f48000)` off 0xc266000, map2
   `[0x39f48000..0x3c235000)` off 0xdf46000). `xnu_live_cal_lr` (1031 re-publishes the caller's `lr`) and
   `xnu_live_cal_pc` are resolved through it, statically. **`v − 0x2c000000` is NOT general** — it is a
   map0-only coincidence, and using it is the defect 1029 caught in the lead's first rule.
2. **A VA-provenance rung** (a probe, one new switch) if the disassembly still does not land: publish the
   caller frame plus the two cursors' provenance — `r3` and `r2` separately, and the value each was
   derived from — so that "the two cursors differ" becomes a value rather than a suspicion.

### 3.4 The falsifier

* **Falsified by the disassembly landing.** If `lr` resolves to a real call of the fault function, the
  "lookalike frame" leg is refuted and the cell collapses to a complete TOP-or-SIZE read; the branch
  reverts to §1/§2.
* **Falsified by the population.** If, across the captures, `far != region_top` in even ONE run with a
  trustworthy `region_end_hit == 1`, then the population claim of §0.2 (61/61) is wrong and the entire
  1030 reading — and 1031's premise — must be re-derived from scratch. This is the strongest possible
  refutation of this document's own §0.
* **NOT a falsifier: `CAL-CALLER-OTHER` itself.** It is a fail-closed verdict, not a negative finding
  about the device. Reading it as "the caller derives the address some other way — here is the fix" is
  exactly the error `CAL-CALLER-OTHER` exists to prevent.

---

## 4. THE FOURTH CELL — `CAL-MISSING`: WITHHELD

An ABSENT row means **THE PROBE DID NOT RUN**, never a negative
(`docs/1031-design.md` §2: "`cal_region_end == 0` printed WITH `cal_region_end_hit == 0` is a POSITIVE
reading … and it must be the PRINTED zero, never a suppressed line"). `CAL-MISSING` also covers a
`region_end_hit == 0` with `region_end == 0`: the word at `far − 4` was itself unmapped — a DIFFERENT
failure in which `far` is NOT the region top.

**This is the cell that closes §0 entirely.** If `cal_region_end_hit == 0`, then the 1030 reading and the
61-run population are both wrong: the writer is a fixed-VA writer (1029's hypothesis (c)) and the next
rung is a **VA-provenance probe**, not any branch of §1–§3. **No fix from this document applies.**

**`CAL-MISSING` and `G-CTL` are readings OF THE INSTRUMENT, not of the device.** The press's step 5
already prints `NO READING - STALE SLOT` and does NOT run the checker in that case
(`scripts/press_1031.sh:386-414`); the same discipline binds 1032.

---

## 5. THE SHARED MATERIAL (identical for every branch — this is where the build actually breaks)

### 5.1 The switch set, carried VERBATIM

Every branch's build reads `$REC` and carries **1031's whole set from the record, never a default**
(`[[mi4-build-variant-comes-from-an-env-default]]`; instance m1028: an agent wrote `export
STAGE90_XNU_H2_STACK_HEADROOM=1` where 1027 had `export STAGE90_XNU_ABT_ENTRY_PROBE=1` and the 1027
instrument was silently un-built while the record still said 1). The set is `docs/1031-design.md` §3's
list verbatim, i.e. 1029's full set plus:

    STAGE90_XNU_USTACK_PROBE=1        <- 1025 PARENT gate (every later block is NESTED inside it)
    STAGE90_XNU_ABT_ENTRY_PROBE=1     <- 1026/1027 parent cells
    STAGE90_XNU_H2_STACK_HEADROOM=1   <- 1028 (defines the `far − ustack` geometry every conjunct assumes)
    STAGE90_XNU_READER_PROBE=1        <- 1029 (far == region exclusive top)
    STAGE90_XNU_WRITER_PROBE=1        <- 1030 (the writer shape this work builds on)
    STAGE90_XNU_CALLER_PROBE=1        <- 1031 (the caller frame + the PRINTED region end)
    <the branch's ONE new switch>     <- §1.3 / §2.3 / §3.3

`tools/build_xnu_arm_kernel.sh`'s **global `DEFINES` array** is the channel (every compile line carries
it, including the EABI-runtime and firehose blocks, which do NOT get `EXTRA_DEFINES`); `build_1031.sh:182`
ARRESTs a `-DSTAGE90_XNU_CALLER_PROBE` appearing in EXTRA, because an EXTRA-only build can ship a stale
pool behind a green build (`records/1020-build-defect.txt`).

### 5.2 The `#if` identifier namespace — every patcher's allow-set gains the new switch

Per `[[mi4-one-file-many-rungs]]`, a file's conditional-directive identifiers are **ONE shared namespace**,
and every patcher that edits the file must list the new switch in its allow-set or its OFF proof refuses
the composed tree. **`osfmk/arm/trap.c` is edited by SEVEN rungs today (994 / 1020 / 1025 / 1026+1027 /
1029 / 1030 / 1031)** and **`bsd/kern/kern_exec.c` by FIVE (1025 / 1026 / 1028 / 1029 / 1031)**; 1031 ALSO
edits **`bsd/sys/proc_internal.h`** (the `p_live_stack_top` field, `proc_internal.h` beside the
`user_addr_t user_stack;` field):

    tools/patch_d13_ustack_probe.py        (trap.c + kern_exec.c)
    tools/patch_d13_abt_entry_probe.py     (trap.c + kern_exec.c)
    tools/patch_d13_reader_probe.py        (trap.c + kern_exec.c)
    tools/patch_d13_writer_probe.py        (trap.c)
    tools/patch_d13_caller_probe.py        (trap.c + kern_exec.c + proc_internal.h)   <- 1031
    tools/patch_d13_undef_raise.py         (trap.c)
    tools/patch_d13_dyld_witness.py        (trap.c)
    tools/patch_d13_h2_stack_headroom.py   (kern_exec.c)

**Every one of those sets must gain the new switch** — in `TRAP_ALLOWED_IF_IDENTIFIERS`,
`EXEC_ALLOWED_STAGE90`, or the equivalent. **The RE-STAGE rule:** the new patcher does NOT re-apply the
old ones; the build's patcher chain re-stages 1025/1026/1027/1028/1029/1030/1031's edits ON TOP of each
other, because `git checkout -- <file>` on the re-provisionable tree SILENTLY reverts every prior rung's
edit and the failure surfaces LATE — the pool compiles, and the INHERITED check refuses the LINKED image.
**A build refusal naming the new switch is the page-move signature, not a licence to skip it.**

The build trap is measured, not hypothetical: 1029's build refused until `patch_d13_undef_raise.py` AND
`patch_d13_dyld_witness.py` carried the reader switch (the last two were missed first pass), and 1030's
refused until `patch_d13_h2_stack_headroom.py` carried the writer switch
(`mi4-1030-writer-probe-pressed`). **1031's chain already shows the fully-composed shape; copy it.**

### 5.3 The `#endif`-bracketing and nesting proofs

`park_1031.sh:152-188` is the pattern and is BY VALUE, not by count alone:

* the staged `trap.c` carries EXACTLY 1 `xnu_live_cal_r3=` line, EXACTLY 1 `xnu_live_cal_region_end=`
  line, and EXACTLY 1 `#endif /* STAGE90_XNU_CALLER_PROBE */` (`park_1031.sh:152-157`);
* the staged `kern_exec.c` carries EXACTLY 3 plain `#endif /* STAGE90_XNU_CALLER_PROBE */` markers and 3
  matching `#if` openers, PLUS exactly 1 RETAGGED
  `#endif /* STAGE90_XNU_CALLER_PROBE: H2 extent */` for the nested H2 gate inside the FIXED stash
  (`park_1031.sh:171-176`) — **the retag exists because `kern_exec.c` must NOT carry a second literal
  `#endif /* STAGE90_XNU_H2_STACK_HEADROOM */`** (the build's step assertion requires exactly 1 of that
  marker, and the inner gate there is H2's extent, so its closer is retagged). `[[mi4-off-option-two-spellings]]`;
* **NESTING READ BY LINE NUMBER** — a text count cannot see a displaced block:
  `tr_1026 < tr_1029 < tr_1030 < tr_1031 < tr_1025` (`park_1031.sh:177-187`). Site A must sit INSIDE
  1025's `#endif /* STAGE90_XNU_USTACK_PROBE */` (or the rows never execute) and AFTER 1030's block (or
  they are gated on the wrong switch).

**Every branch of this document inherits that geometry unchanged** and adds exactly one nested block.

---

## 6. THE STANDING FALSIFIER — caller resolution NOT achieved: the `pc − slide` rule

**⚠ CORRECTED 2026-10-17 (after this doc was first written): THE CALLER IS NOW RESOLVED STATICALLY, so the
"lr does not resolve" premise below is REFUTED.** A byte-accurate objdump (by the disasm lane AND
independently re-verified by the lead — records/1031-caller-derivation.txt, "LEAD'S INDEPENDENT
VERIFICATION") establishes:
  * `lr = 0x38b4a9af` unslides (slide 0x00F2C000) to `0x37C1E9AF` = the return of a **direct `blx 0x37c26f90`**
    at `0x37C1E9AA`. It IS a real call-return; the earlier search failed only because lr's target is
    `0x37C26F90`, not the writer.
  * The caller of the writer is at **`0x37C263CC`** with two call sites into the writer prologue
    `0x37C266EC`: **`0x37C26464`** (Site A) and **`0x37C26550`** (Site B).
  * At both, r3 (the writer's r4) is built by a **downward VLA alloca**: `sub.w r4,sp,r5,lsl #2; mov sp,r4;
    sub.w r6,sp,r5,lsl #2; mov sp,r6; mov r2,r4; mov r3,r6; bl`. `r5` is the ELEMENT COUNT (the return of
    `bl 0x37c26698` at `0x37C2641E`). So **r3 = the LOW end of a `count`-word block carved BELOW sp**.
  **CONSEQUENCE (binds §1–§3):** the caller does NOT compute the region's exclusive top, and it is not an
  obvious base+size of the region either. `r3 ≈ sp` (near `0x2bdac088`), far below `far = 0x2bdae000`; it
  is the WRITER's post-increment cursor that walks UP to the region top. So 1031's cell is EXPECTED to
  read **CAL-CALLER-OTHER** (r3 is neither `region_end` nor a base+size one page short) UNLESS the `count`
  is large enough that block2 reaches the region top. **The fix location this points to is the CALLER's own
  VLA block sizing / `count` — not any region geometry** (still consistent with §0.2). The `count` itself is
  a runtime value (register `r5` at the bl → the writer's `r5`): 1031 publishes `r3` and `r12`, so if
  `r12`/`r3` encode the block extent the cell can still discriminate it. **Read the capture before choosing
  §1 vs §2 vs §3 of this doc; the branches may collapse to §3 + a caller-sizing fix.**
  *(The rule below — require a by-value proof of identity before building on a disassembly — STILL STANDS
  and is what made this resolution trustworthy; it is kept verbatim.)*

**This clause binds EVERY branch of §1–§3. It does not depend on 1031's cell, on any capture, or on any
press. It is the clause most likely to decide the next rung, and misapplying it is how PREVIOUS rungs lost
a press cycle.**

`records/1030-audit.txt` ADDENDUM 3 resolves the WRITER because, for the FAULTING pc,
`pc − slide` lands **EXACTLY** at `function_start + 0x6a` (`0x38b52756 − 0xcce000 = 0x37c26756 =
0x37c266ec + 0x6a`). **That identity is a proof of identity.** It is not a general rule.

**The caller's `lr` has NO such proof.** `records/1030-press-read.txt` and `docs/1031-design.md` §0 both
record the negative plainly: `lr = 0x38b4a9af` **does not land at a call of the fault function in the
mapped image** (likely a tail call / a different image). The 1030 lane could not resolve it; the reader
lane owns the image table.

**The standing falsifier, stated as a rule for whoever writes the next rung:**

1. **A caller derivation asserted from a `pc`/`lr`-derived disassembly is REFUTED — do not build on it —
   unless the disassembly anchor satisfies a BY-VALUE proof of identity of the same strength as the
   writer's.** The acceptable proofs are: (a) `pc − slide` lands on an instruction boundary at an exact
   known offset from a function start; or (b) the site is anchored by a **data reference** — e.g. the
   `printf` format string / the frame shape — that is present at the same address in the image table.
   **A bare `pc − slide` into the middle of a plausible instruction stream is NOT a proof**; the correct
   VA→offset pipeline is the cache's OWN mapping table (§3.3, `records/1029-press-read.txt`), and
   `v − 0x2c000000` is a map0-only coincidence.
2. **If the caller remains UNRESOLVED after 1031, then NO branch of §1–§3 has its premise, and the correct
   next rung is a STATIC DISASSEMBLY — not a press.** `docs/1031-design.md` §5 pre-registered exactly
   this ("if the caller's `lr` is unresolved, the fix is NOT picked and the next rung is a STATIC
   disassembly of `libobjc` around `lr`"). A press spent to resolve a symbol the image table can resolve
   offline is a **press with no question behind it** — the same "not to read a log" discipline
   `press_1031.sh:59-62` states.
3. **The already-refuted shapes must not reappear** (they are not branches; they are dead):
   * **region re-sizing** — 1028, page-exact (§0.2);
   * **base-down + extent-up** — cancels arithmetically (audit1030 CHECK 1, §0.2);
   * **flipping the caller's alloca to `add` (an upward sp-move)** — the caller's `sub.w rN, sp, r#N,
     lsl #2` is the CORRECT producer of `r3` (docs/1031-design.md §5 CORRECTION 2); the cursor legitimately
     ends above `sp` after `k` post-increments. The dead shape is the OPPOSITE claim ("a down-alloca cannot
     produce it"). Do not invert the alloca;
   * **the `sp`-relative tell (`r4 − sp == 0x1F8C`) as a discriminator** — TRIVIALLY true on this arm
     because `sp` and the region top are ONE anchor (`ustack − sp = 0xF8C` invariant).

**The rule in one line: BUILD A BRANCH ONLY ON A DERIVATION WITH A BY-VALUE PROOF OF IDENTITY AT LEAST
AS STRONG AS THE ONE THAT NAMED THE WRITER.**

---

## 7. WHAT THIS DOCUMENT DELIBERATELY DOES NOT DO

* It does **not** pick a fix. `CAL-CALLER-TOP` and `CAL-CALLER-SIZE` are separated by whether `r3` equals
  the region top or a smaller buffer end; **if `r3` equals BOTH (the caller set its buffer end `==` the
  region top), the cell is `CAL-CALLER-TOP`** — the weaker, boundary-write reading — and the size reading
  is deferred to a caller disassembly (`docs/1031-design.md` §5, undermine bullet).
* It does **not** re-measure `far`. 1030 settled `far == region exclusive top` by value across 61 runs;
  re-measuring it produces no new information and would be the `[[mi4-measurement-defects]]` class.
* It does **not** propose any change to any allocation, extent, base, guard, `p->user_stack`,
  `LAB_USER_STACK`, `MAXSSIZ` or `VM_MAX_ADDRESS`. §0.2 refutes all of them and 1028 is the proof.
* It follows `docs/1031-design.md` §5's limitation unchanged: any instrument may read ONLY kernel-side
  facts (registers from `arm_ctx`, the map entry via `vm_map_lookup_entry`, the proc's stashed top). If
  the caller's derivation lives ONLY in its stack frame (not in a register), no Site-A instrument can see
  it and a later rung must find a safe read first (§2.4).
* **Hardware safety, verbatim, always:** `fastboot boot` ONLY, **NEVER `fastboot flash`**; never boot
  TWRP; never press the power button (that is the operator's job); unplug device `33e80afe` if present
  (`[[mi4-hardware-run-safety-gate]]`). A resident rung that does not return keeps NO `/proc/last_kmsg` of
  its own (`[[mi4-last-kmsg-reader-carrier]]`), so the reading arrives only via the operator's power
  press + `scripts/recover_last_kmsg.sh --read-only`, and any capture OLDER than the press's boot epoch
  must be refused as a stale slot (`[[mi4-stale-slot-impersonates-a-reading]]`).