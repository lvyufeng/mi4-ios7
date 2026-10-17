# 1028 DESIGN — THE H2 FIX: GIVE THE INITIAL USER-STACK BLOCK ONE WORD OF HEADROOM

## 0. WHAT 1027 DECIDED (the premise this rung acts on)

1027 read **H2 (off-the-end)**, by value, at the launchctl[2] stack fault
(`records/1027-press-read.txt`):

    lookup_far=0  far_in_map=1  entry=[0,0)  e2=[0x2bce1000,0x2bde0000)
    e2_hi == far == ustack == 0x2bde0000     map == taskmap == 0xc0005688

The user-stack region is `[0x2bce1000, 0x2bde0000)` and its **EXCLUSIVE TOP is `far`**. The word just
below (`far-4`) IS in the map (`far_in_map=1`), so a write AT `far` is a write ONE WORD PAST the region's
end. H1 (wrong map) is refuted by value (`map == taskmap`). Therefore the cause is UPSTREAM of
`vm_fault`: the initial argv/env block is placed so its TOP EQUALS the region top, leaving the word at
`far` unowned, and userspace's touch of the top word faults.

## 1. THE GEOMETRY, BY VALUE (measured, not guessed)

From the SAME press's 1025 rows (`xnu_live_ustack_*`):

    req=0x2bdc5000  size=0x00100000  fixed_addr=0x2bcc5000  rc=0  final=0x2bdc5000
    prot_addr=0x2bcc5000  prot_size=0x00001000

So for launchd[1]: `mach_vm_allocate(FIXED)` **SUCCEEDED** (`rc=0`, no ANYWHERE fallback), the region is
`[0x2bcc5000, 0x2bdc5000)` with top `= req = p->user_stack` (0x2bdc5000), and the guard page is the bottom
4 KiB (`prot_addr=base`, `prot_size=0x1000`). The faulting launchctl[2] has a different `far`
(0x2bde0000) because ASLR gives each exec its own `req`, but the SHAPE is identical: **region top ==
`p->user_stack` == the block top**.

## 2. WHY THE BLOCK TOP LANDS AT THE REGION TOP (source, by value)

`create_unix_stack` (bsd/kern/kern_exec.c 3620-3672):

    user_stack = load_result->user_stack;          // the requested top (ASLR value)
    p->user_stack = user_stack;                    // <-- p->user_stack IS the region top basis
    size = mach_vm_round_page(load_result->user_stack_size);
    addr = mach_vm_trunc_page(load_result->user_stack - size);
    mach_vm_allocate(map, &addr, size, VM_FLAGS_FIXED);   // region = [addr, addr+size) = [user_stack-size, user_stack)

`exec_copyout_strings` (kern_exec.c 2763-2813):

    stack = *stackp;                    // *stackp == p->user_stack (the CALLER passes &ap, ap = p->user_stack)
    stack -= string_size;               // string_area
    stack -= ptr_area_size;             // ptr_area
    stack -= ptr_size;                  // argc_area
    *stackp = stack;                    // the returned sp

So the block occupies `[sp, user_stack)` and its TOP is EXACTLY `user_stack` == the region's exclusive
top. **The last byte the region owns is `user_stack - 1`; the block's top word IS the first byte past
it.** The layout comment (kern_exec.c 2596-2610) even draws a "16b" slot at `p->user_stack` ABOVE the
string area — i.e. the ABI expects the top of the stack to hold a 16-byte reserved area the block does
NOT consume — but the placement never leaves room for it.

## 3. THE FIX (one shape; the choice is forced)

Give the region ONE WORD (4 B; use 16 B to also honour the comment's reserved slot) of headroom ABOVE
the block, so the region's exclusive top is `user_stack + 16` while the block top stays at `user_stack`
and `p->user_stack` (the userspace-visible top) is UNCHANGED.

**Edit site: `create_unix_stack`, the FIXED allocation only.** Allocate `size + 16` bytes anchored so the
TOP moves up by 16, keeping the base where it was:

    size = mach_vm_round_page(load_result->user_stack_size);
    if (load_result->prog_stack_size) size += PAGE_SIZE;
    /* 1028: reserve 16 B above the block so the region's exclusive top is user_stack+16, not
     * user_stack.  The block (exec_copyout_strings) still tops out at user_stack, so its last byte
     * is user_stack-1 and the region now OWNS the word at user_stack that userspace touches.  The
     * base is unchanged (addr), the guard math is unchanged (prot at base), and p->user_stack -- the
     * value userspace sees -- is unchanged. */
    alloc_size = size + 16;                       // the region only
    addr = mach_vm_trunc_page(load_result->user_stack - size);   // base UNCHANGED
    mach_vm_allocate(map, &addr, alloc_size, VM_FLAGS_FIXED);   // top = user_stack + 16

## 4. WHY THIS SHAPE AND NOT THE ALTERNATIVES

* **Not "shift the block down 16"** (`stack -= 16` in `exec_copyout_strings`): that moves `sp`, and `sp`
  is the userspace ABI's argv/env base — every consumer (dyld, libsystem's `_start`) reads argc at `sp`.
  Moving it by 16 is a silent ABI change and risks the launchd[1] path that WORKS today (it re-execs and
  reaches the fault, so its own block is fine).
* **Not "lower `p->user_stack`"**: `p->user_stack` is returned to userspace (`thread_userstack`,
  status.c:90/98) and is the stack's advertised top; changing it changes the ABI. Keep it.
* **Not `MAXSSIZ`/`LAB_USER_STACK`/`VM_MAX_ADDRESS`**: all three are MEASURED-CORRECT (1024/1025/1011);
  the fault is a one-word boundary, not a window-size error.

## 5. PRE-REGISTERED READING (decided before the build)

The arm = 1027's set (1025's pumps + the discriminator) **minus nothing**, plus the fix. The fix is a
KERNEL behaviour change, not a probe, so the reading is the FRONTIER MOVING:

    FIX-HOLDS   : the launchctl[2] data abort at `far == p->user_stack` is GONE (0 rows with
                  `xnu_live_abt_vmfkrv=1` on a far in the stack window), AND launchd still starts
                  (`*** launchd[1] has started up ***`), AND the next frontier (whatever it is) is
                  NAMED by the existing rows.
    FIX-NOOP    : the same abort at the same `far - sp == 0xF8C` recurs => the top word was not the
                  cause; re-instrument (report, do not re-fix).
    REGRESSION  : trap24 / port_construct(result=0) vanish, or a panic appears => the +16 moved
                  something the guard math depended on; report and revert.
    G-CTL       : launchd never reached and no prior control live => WITHHOLD (fail closed).

    NO-READING  : (added AFTER the first press, records/1028-press-read.txt) the device did not return
                  and the only capture on disk is OLDER than this press's boot (a PREVIOUS arm's slot).
                  A resident rung that does not return keeps NO /proc/last_kmsg of its own
                  ([[mi4-last-kmsg-reader-carrier]]), so the recovery reads whatever slot the last
                  RETURNING boot left.  Adjudicating it reports a cell about a different arm.  The
                  press now stamps its boot epoch and REFUSES to read any capture older than it.

`e2_hi` must now read `far + 16` (the region's new exclusive top) if the fix landed; if it still reads
`far`, the allocation edit did not take effect (a build defect, [[mi4-one-obj-dir-two-builds-corrupts]]).

**VALVE ON THE `e2_hi` CLAUSE (2026-10-17, after the stale-slot press).**  `e2_hi` is the far-4
lookup's covering entry; the +16 moves the REGION's exclusive top, not that entry's bound, so `e2_hi`
need not literally become `far + 16` — what must change is that the region's top is no longer flush
with the block top.  The DECISIVE cell is FIX-HOLDS (the `vmfkrv=1` stack-window row is GONE), not a
single `e2_hi` literal; read them together, and only from a capture NEWER than the boot.

**THE EXTENT LANDS ONE PAGE HIGH, NOT ONE WORD (measured 2026-10-17, source by value).**
`mach_vm_allocate` (`osfmk/vm/vm_user.c`) does `map_size = vm_map_round_page(size)` BEFORE
`vm_map_enter`, so the `size + 16` extent is rounded up and the region actually grows by a full
**PAGE**: the new exclusive top is **`user_stack + 0x1000`**, not `user_stack + 16`.  This is
functionally a superset (the word at `user_stack` is owned either way) and changes nothing about the
block, `sp`, `p->user_stack`, or the guard — but it means (a) the staged comment in
`patch_d13_h2_stack_headroom.py` is INACCURATE where it says the top becomes `user_stack + 16`, and
(b) the `e2_hi` row, if it moves at all, is expected at `far + 0x1000`.  Do NOT treat "`e2_hi !=
far + 16`" as a build defect — that was never the arithmetic.  **NO-OP RISK:** if `[req, req + 0x1000)`
were already occupied the FIXED allocate would fail and fall through to the ANYWHERE branch
(`8020a7fc: mov r2, r6`), which re-creates the SAME flush-top geometry — a silent no-op.  The
`xnu_live_ustack_rc` row (0 = FIXED succeeded, non-zero = fell back) in the future capture tells which
path was taken; if FIX-NOOP fires, read `xnu_live_ustack_rc` FIRST to distinguish "fix had no room"
from "top word was not the cause".

## 6. FILE-LEVEL PLAN

1. `tools/patch_d13_h2_stack_headroom.py` — NEW. Edits `create_unix_stack` in kern_exec.c: replace the
   FIXED `mach_vm_allocate(map, &addr, size, ...)` extent with `size + 16`, and add `alloc_size`. Gate:
   OFF = byte-identical (the `#if` idiom, [[mi4-off-option-two-spellings]]); the switch is
   `STAGE90_XNU_H2_STACK_HEADROOM`. This is the SAME file as 1025/1026's accessor — the new rung must
   RE-STAGE those and add its switch to their `ALLOWED_IF_IDENTIFIERS` ([[mi4-one-file-many-rungs]]).
2. `scripts/build_1028.sh` — carry 1027's full switch set verbatim, re-stage every kern_exec.c/trap.c
   edit in order, add the fix's switch. The 6b gate: the LINKED image's `create_unix_stack` allocates
   `size + 16` (read by value out of the image, not the record).
3. `tools/check_1028_capture.py` + `scripts/{park,press}_1028.sh` — FIX-HOLDS / FIX-NOOP / REGRESSION /
   G-CTL cells; `grep -qa P <(strings X)`, never the pipe form.
4. `records/1028-press-read.txt`.

## 7. RISK

The fix touches the ONE path every process's stack comes through. It is +16 bytes of ADDRESS SPACE per
non-prog-allocated stack and changes nothing about the block, sp, p->user_stack, or the guard. The
reversible medium (CARD COW) means a bad arm cannot brick storage. `fastboot boot` only.