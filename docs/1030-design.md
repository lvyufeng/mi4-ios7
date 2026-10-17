# 1030 — the region-extent fix is a NO-OP; instrument the WRITER's derivation

## 0b. THIS DESIGN WAS REFUTED BEFORE BUILD (2026-10-17) — read this first

The original §0/§1 below proposed a base-move fix (`addr = trunc_page(user_stack - size) - PAGE_SIZE`,
allocate `size + PAGE_SIZE`). **Two independent checks killed it:**

1. **ARITHMETIC (audit1030 check 1):** base-down and extent-up CANCEL. `size` is already page-aligned,
   so `round_page(size + PAGE_SIZE) == size + PAGE_SIZE`; `top = (user_stack - size - PAGE) + (size +
   PAGE) = user_stack`. The region's exclusive top is **UNCHANGED** — the same flush-top boundary.
2. **MECHANISM (audit1030 check 4 + lead population):** across ALL 60 captures
   (`out/stage90/captures/recovered-unknown-arm-2026101{6,7}-*-last_kmsg.txt`):

       ustack - sp   == 0xF8C  in ALL 60   (argv/env block size INVARIANT)
       far - ustack  == 0      in 57       (pre-fix: far == the region's exclusive top)
       far - ustack  == 0x1000 in  3       (post-fix ONLY: 1028 x2 + 1029 x1)
       far == e2_hi  in EVERY run with an e2 row.

   Post-fix matched rows (faulting exec, `req == ustack`):
       1028 base=0x2bc0d000 size=0x100000 -> far=0x2bd0e000 = base+size+0x1000
       1029 base=0x2bc38000 size=0x100000 -> far=0x2bd39000 = base+size+0x1000
   Pre-fix: 1027 base=0x2bce0000 size=0x100000 -> far=0x2bde0000 = base+size.

   **`far` == the region's EXCLUSIVE TOP in EVERY run.** Hypothesis A (far == owned region top) holds on
   1025/1026/1027/1028/1029; Hypothesis B (far == ustack + 0x1000 as a *derivation distance*) is REFUTED
   by 1025/1026/1027 (there far == ustack, no +0x1000). The `+0x1000` on 1028/1029 is a CONSEQUENCE of
   1028 having grown the top by a page.

   => **The writer stores AT the region's exclusive top.** Raising the top raises `far` (1028 proved it,
   page-exact); lowering the top lowers `far` (1030 would have). **NO allocation-geometry change can
   help.** This is the SAME conclusion as the corrected 1029 record ([[mi4-1029-premise-falsified-far-is-region-top]],
   [[mi4-1028-fix-noop-page-exact-h2-refuted]]).

   The real requirement: make the writer's derived `far` land INSIDE an owned page, not AT the (moving)
   boundary — i.e. **fix or understand the WRITER's derivation.**

## 0. WHAT 1029 DECIDED (the reading this rung acts on) — SURVIVES, corrected

1029 read **READER-NAMED / TOP-CONFIRMED BY VALUE** (capture `recovered-...-052951`, newer than the
04:55:11 boot epoch; `records/1029-press-read.txt`):

    xnu_live_rdr_far               = 0x2bd39000      far_minus_ustack = 0x1000
    xnu_live_rdr_ustack            = 0x2bd38000      blk_hi == ustack (block did NOT grow)
    xnu_live_rdr_entry_at_hit      = 0               far covered by NO entry
    xnu_live_ustack_rc             = 0               FIXED allocate succeeded

Controls: launchd_reached=True, trap24=8, port_construct(result=0)=8, abt_pc_live=12, panics=0.

`entry_at_hit == 0` (far unowned) + `far == region exclusive top` => the fault is a **boundary write at
the region's moving top**. Writer (reader lane, byte-verified 4 ways via the cache image table):
`/usr/lib/libobjc.dylib + 0x14756`, `str.w r2,[r4],#4`, with `r4 = r6 = far`, `r9 = 0x1fff`,
`r12 = 0x4000` (a 16 KiB VLA/copy; the cursor would run `far .. far + 0x7FFC`, 0x8000 past the block top).

## 1. THE CORRECTED RUNG (1030 = a PROBE of the writer, not a fix)

Instrument the writer's VLA/copy setup so the reading says WHY `far` lands exactly at the region top and
what derives it. Candidates to discriminate (publish, on the fault arm, the values that separate them):

    W-A  r4 is derived from a STACK pointer: `r4 = sp + const` (a stack VLA whose base the compiler
         placed at sp+0x1F8C). If so, the base is a COMPILE-TIME frame offset -- the writer's frame is
         one page past the advertised stack top because the initial block+frame chain is too tall; the
         fix is in how much stack the exec hands the initial thread (or the frame size), not the region.
    W-B  r4 is derived from the REGION TOP (reads a saved p->user_stack / thread_userstack). If so, the
         writer deliberately writes at the advertised top -- a "canary"/bounds store, and the fault is
         the intended stack-limit check firing one page early (MAXSSIZ / LAB_USER_STACK off by a page).
    W-C  r4 is derived from a shared-cache/objc data structure (a copy DESTINATION computed from
         selector-table size). If so this is objc metadata being copied into a stack buffer that is
         undersized relative to the region -- a userspace buffer/limit mismatch.

The probe must publish, on the launchctl[2] usermode DATA-abort arm (inside 1025's publisher, after
1026/1027/1029 blocks): `r4`, `sp`, `r4 - sp`, the thread's `thread_userstack`/`p->user_stack`, the
current `pc` (slid), and the block bytes. That, plus the pc→cache-offset naming rule
(`file_offset(v) = map[i].fileOffset + (v - map[i].address)`; docs/1017 as corrected), names which of
W-A/W-B/W-C holds.

## 2. PRE-REGISTERED CELLS

    W-A-NAMED : r4 - sp is a small constant (a frame offset) => the initial stack is too shallow.
    W-B-NAMED : r4 == thread_userstack (or == some saved region top) => a stack-limit store.
    W-OTHER   : r4 is neither sp-relative nor the region top => name what it is; do NOT pick a fix.
    REGRESSION / G-CTL as usual.

Fail closed: if the rows are absent, that is W-OTHER-missing (the probe did not run), never a negative.

## 3. REUSABLE ARTIFACTS ALREADY WRITTEN (kept, but retargeted)

`scripts/build_1030.sh`, `scripts/press_1030.sh`, `tools/check_1030_capture.py`, and the
`STAGE90_XNU_OWN_END_PAGE` entry-channel wiring were written for the (refuted) fix shape. They are
KEPT as scaffolding; the switch/patcher are re-pointed to the writer probe. `records/1030-audit.txt`
holds the full adversarial audit.

## 5. RISK

- `p->user_stack`, the block, `sp`, the guard shape, LAB_USER_STACK/MAXSSIZ/VM_MAX_ADDRESS: UNCHANGED
  (a probe changes no allocation at all).
- `STAGE90_XNU_HFS=0` on D13.

## 6. THE ONE THING THAT WOULD FALSIFY THIS

If the probe shows `r4` is NOT derived from either sp or the region top (W-OTHER), then the writer's
derivation is something we have not modelled and the next step is to disassemble and single-step the
writer (`libobjc+0x14756`) frame by frame — not another kernel-side guess.