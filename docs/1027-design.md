# 1027 DESIGN — MAKE THE H2 CELL FIRE: PUBLISH THE FAR-4 ENTRY'S OWN BOUNDS

## 0. WHY 1027 EXISTS (one paragraph)

The 1026 press RAN and its own console was recovered
(`out/stage90/captures/recovered-unknown-arm-20261016-182042-last_kmsg.txt`). The reading is
`records/1026-press-read.txt`. The seven discriminator keys fired on the launchctl[2] abort:
`lookup_far=0`, `far_in_map=1`, `map == taskmap == 0xc0005688`, `ustack == far == 0x2bdeb000`,
`far - sp == 0xF8C` (identical to 1025 and 1024). The checker verdict was **H-OTHER (fail closed)** —
but that verdict is a **PROBE DEFECT, not a third hypothesis**. The pre-registered H2 cell demands
`entry_hi == far`, yet the publisher writes `entry_lo/entry_hi` **only when `_abt_hit` is TRUE**, and
in the H2 case `_abt_hit` is exactly FALSE (`lookup_far=0`): the covering entry is the **far-4
lookup's** (`_abt_e2`), which the publisher never printed. So 1026's H2 cell asked for a value the
probe was built never to emit — **the cell is internally contradictory** and H-OTHER is its
fail-closed artifact. 1027 exists to publish `_abt_e2->vme_start/vme_end` so `entry_hi == far` becomes
readable when H2 is true, and the H2 cell can fire.

## 1. THE DEFECT, BY VALUE (so 1027 does not re-derive it)

The 1026 publisher (now `tools/patch_d13_abt_entry_probe.py`, the amended BLOCK) reads:

    boolean_t _abt_hit  = vm_map_lookup_entry(map, vm_map_trunc_page(dfar),     &_abt_e);
    boolean_t _abt_hit2 = vm_map_lookup_entry(map, vm_map_trunc_page(dfar) - 4, &_abt_e2);
    printf("xnu_live_abt_entry_lo=0x%08x\n", (_abt_hit  && _abt_e ) ? _abt_e ->vme_start : 0);
    printf("xnu_live_abt_entry_hi=0x%08x\n", (_abt_hit  && _abt_e ) ? _abt_e ->vme_end   : 0);

When `far` is the region's EXCLUSIVE TOP (the measured geometry: `far == p->user_stack`, the entry
ends at `far`), `vm_map_lookup_entry(map, far)` returns FALSE — `far` is not a member of the
half-open entry `[start, end)`. `_abt_hit` is FALSE. The entry CONTAINING `far-4` is `_abt_e2`, and
**its `vme_end` IS `far`** — the value the H2 cell needs. 1026 printed `_abt_e` (0), never `_abt_e2`.

## 2. THE INSTRUMENT (probe-only; the SAME switch, TWO new rows)

Amend the 1026 publisher in place (SAME `STAGE90_XNU_ABT_ENTRY_PROBE` gate, same nesting inside 1025's
block), adding exactly two rows AFTER `entry_hi` and BEFORE `far_in_map`:

    xnu_live_abt_e2_lo=0x..   <- (_abt_hit2 && _abt_e2) ? _abt_e2->vme_start : 0
    xnu_live_abt_e2_hi=0x..   <- (_abt_hit2 && _abt_e2) ? _abt_e2->vme_end   : 0

Read-only, failure path only, no lock (identical to 1026's other seven). The 1026 rows are
**unchanged** — this ADDS two strings, so the 1026 keys, the 1025 re-reading, and every downstream
gate keyed on `xnu_live_abt_lookup_far=` are undisturbed.

## 3. PRE-REGISTERED READING (decided before the build; the SAME cells, now satisfiable)

    H1 (wrong map)     : lookup_far=0 AND far_in_map=0 AND map != taskmap AND ustack==far
    H2 (off-the-end)   : lookup_far=0 AND far_in_map=1 AND e2_hi==far AND map == taskmap
                         (the covering entry is now read from `_abt_e2`; e2_hi==far names the region
                          ending exactly at far; the word just below is mapped)
    H-OTHER            : any other combination -> report it; do NOT pick a fix (fail closed)

The H2 FIX (if H2 fires) is KERNEL-SIDE and one of (docs/1026-design.md §8): give the initial
argv/env block / `sp` a word of headroom so the block top `<` region top strictly; or reserve the
region so its top is strictly above the block. Neither touches the measured-correct `MAXSSIZ`,
`LAB_USER_STACK`, or the `VM_MAX_ADDRESS` split. The probe's `e2_lo/e2_hi` name the region the walk
DID see, so the fix is chosen against a number, not a guess.

## 4. WHAT 1027 DOES NOT DO

* Does not change any operator — the fault geometry is measured across three arms (`far - sp == 0xF8C`).
* Does not add a new switch — it AMENDS 1026's publisher under the same gate.
* Does not touch `LAB_USER_STACK`, `MAXSSIZ`, `VM_MAX_ADDRESS`, `exec_copyout_strings`.
* Does not add a fifth trap.c rung without re-staging the other three
  ([[mi4-one-file-many-rungs]]: 994 witness / 1020 undef_raise / 1025 probe / 1026 abt_entry).

## 5. FILE-LEVEL PLAN

1. `tools/patch_d13_abt_entry_probe.py` — AMENDED (the two `e2` rows; the DONE_MARK and the
   `_abt_e2` declaration are already present from 1026). Idempotent; the OFF arm is byte-identical.
   **1027 RE-STAGE (added after the amendment deadlocked):** the block's `DONE_MARK` is the OLD
   token `xnu_live_abt_lookup_far=`, so a tree staged by the PRE-amendment 1026 makes `plan_file`
   return "already staged" while `apply_file` only INSERTS — the e2 rows could never land, and a
   plain re-apply would DOUBLE the block. Fix: `strip_old_block()` removes the region bounded by the
   block's own one-line gate `#if defined(STAGE90_XNU_ABT_ENTRY_PROBE) && ...` and its matching
   `END`, but ONLY when the new token `xnu_live_abt_e2_hi=` is ABSENT and the old one PRESENT (the
   by-value signature of a stale block), and only when gate/END each occur exactly once. The strip
   short-circuits the "already staged" branch via `restaged`, feeds the stripped text to the insert,
   and — because kern_exec.c's accessor is UNCHANGED by 1027 — the accessor insert is skipped when
   `EXEC_DONE_MARK` is already present (else it double-landed; caught by value, count 2 -> 1).
   Proven: stale tree -> one amended block (gate count 2 = gate+END); second `--apply` is a no-op;
   `--verify-off` PASS ([mi4-one-file-many-rungs]: an amended rung must RE-STAGE the old edit).
2. `scripts/build_1027.sh` — re-stage EVERY trap.c/kern_exec.c edit in order (the four trap.c rungs +
   the accessor), carrying 1026's FULL switch set verbatim. The pool fingerprint is now the format
   strings `xnu_live_abt_lookup_far=` AND `xnu_live_abt_e2_hi=`.
3. `tools/check_1027_capture.py` (or the same `check_1026_capture.py` which now prefers `e2_hi`) —
   the H cells + the 1025 re-reading (FAULT-NAMED) + REGRESSION + G-CTL; `--selftest` with a capture
   shaped like the measured one, PLUS the 1027 shape (entry suppressed, `e2_hi == far` -> H2).
4. `scripts/{park,press}_1027.sh` — `grep -qa P <(strings X)` (NEVER `strings|grep -q`, 141 under
   pipefail — [[mi4-mutation-anchors-are-code-spans]] m1025); the negative control points at a
   PRE-rung arm (NOT 1027's own, NOT 1026's own).
5. `records/1027-press-read.txt`; memory `mi4-1027-*` updated by value.

## 6. EXPECTED READING (the source prior; docs/1026-design.md §8)

`thread->map == task->map == get_task_map(task)` throughout the spawn path, so H1 is expected FALSE
(the 1026 press already read `map == taskmap`). `far == p->user_stack` and `far - sp == 0xF8C`
identical across three arms is H2's mechanism to the letter. **Therefore 1027 is expected to read
H2** — with `e2_hi == far` now readable — and the fix chosen against that number. If it does NOT
(H-OTHER again), the e2 rows themselves become the thing to instrument (a second, different defect).
## 7. THE FIX, BY VALUE (source prior; owed only if the press reads H2)

The measured geometry is `far == p->user_stack == region EXCLUSIVE TOP`, and (1025/1026) `far - sp == 0xF8C`
across four arms.  By source (`bsd/kern/kern_exec.c`), the initial stack is placed so that its **top
equals `p->user_stack`**:

* `create_unix_stack` (3622-3657): `user_stack = load_result->user_stack`; `p->user_stack = user_stack`;
  the region is `[mach_vm_trunc_page(user_stack - size), user_stack)` — so `user_stack` IS the exclusive
  top and the last OWNED byte is `user_stack - 1`.
* `exec_copyout_strings` (2763-2813): `stack = *stackp` (= `p->user_stack`), then `stack -= string_size`
  (STRING+PATH areas), `stack -= ptr_area_size`, `stack -= ptr_size`, and `*stackp = stack`.  So
  `sp = user_stack - (string_size + ptr_area_size + ptr_size)` — strictly BELOW the top; the block's own
  TOP slot (the layout comment's "16b" at `p->user_stack`) is the region's last word (`user_stack-16`).
* `exec_mach_imgact` (974-975): `ap = thread_adjuserstack(thread, -4); copyoutptr(load_result.mach_header,
  ap, 4)` — for a DYNAMIC binary (launchctl[2] is one) the kernel writes the dyld mach_header at `sp-4`.

So the kernel's own writes all land STRICTLY below `far`.  The fault is a **userspace** write at
`sp + 0xF8C == far` — one word past the region's exclusive top.  H2's mechanism, to the letter.

**The minimal kernel-side fix (H2 fires):** make the block's top strictly below the region top.  Two
shapes, both in `create_unix_stack`:
  (a) *reserve the top word*: set `p->user_stack` (and `load_result->user_stack`) to `user_stack - 16`
      for the string/path/argv placement while keeping the region allocated up to `far` — the region then
      OWNS the word at `far - 16 .. far - 1` and the block top `< far` strictly.  This is what the layout
      comment's "16b" reserved slot already DESCRIBES but the placement does not HONOUR.
  (b) *grow the region a word*: allocate `size += 16` so the region top is `far + 16` while the block top
      stays at `far` — but this changes `p->user_stack`'s meaning (userspace reads it), so (a) is safer.
**The EABI argument:** (a) keeps every kernel store below `far` and gives userspace a legal word at the
last owned address; it does not move `sp`'s alignment (the argv/env area is pointer-aligned by
`ip_strspace % ptr_size`), and it does not touch `MAXSSIZ`, `LAB_USER_STACK`, or `VM_MAX_ADDRESS`.

**Falsifier:** if the press reads H1 (`map != taskmap`, `far_in_map=0`) the region top is not the cause
and this fix is wrong — the walk uses a different map than the one `create_unix_stack` allocated into
(see the checker's H1 fix hint: `exec_mach_imgact:948` `vm_map_switch` window).  If it reads H-OTHER
again, the `e2` rows themselves are the next thing to instrument.
