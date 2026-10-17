# 1026 DESIGN — NAME WHY THE launchctl STACK VA HAS NO vm_map ENTRY, THEN FIX IT

## 0. WHAT THIS RUNG IS FOR (one paragraph)

The 1025 press RAN and its own console was recovered. The reading (records/1025-press-read.txt) is
**FAULT-NAMED**: the discarded `vm_fault` return for the launchctl[2] abort is `code=1`
= **KERN_INVALID_ADDRESS**, on `far=0x2bd35000`, `dfsr=0x807` (translation fault, page),
`prot=write`, `pc=0x3b4ce756`, `sp=0x2bd34074`, `pid=2`. `vm_fault` returning
KERN_INVALID_ADDRESS means, by source (`vm_map_lookup_locked` -> `vm_map_lookup_entry` FALSE ->
`return KERN_INVALID_ADDRESS`, `osfmk/vm/vm_map.c:8761ff`), that **no vm_map entry covered the VA
when the walk ran**. 1026 exists to name WHY, and to fix it. The 1025 press's own probe also
publishes the stack's shape, and THAT falsifies the 1025 design's premise (see §1).

## 1. THE 1025 PROBE FALSIFIED THE 1025 DESIGN'S OWN PREMISE (by value)

1025 design §1 said "0x2bdbe000 is INSIDE the allocated, already-written stack region
[0x2BD00000, 0x2BE00000)". That was a reading of the **1024** arm. The **1025** arm's own
`xnu_live_ustack_*` rows (`out/stage90/captures/recovered-unknown-arm-20261016-153359-last_kmsg.txt`
:4099-4105, :4153-4159) say otherwise:

    pid 1 launchd : req=0x2bdcd000 size=0x00100000 fixed_addr=0x2bccd000 rc=0 guard=[0x2bccd000,+0x1000)
    pid 2 launchctl: req=0x2bd35000 size=0x00100000 fixed_addr=0x2bc35000 rc=0 guard=[0x2bc35000,+0x1000)

So launchctl's region is `[0x2bc35000, 0x2bd35000)` and the fault VA `0x2bd35000` is its
**EXCLUSIVE TOP** — one byte past the last byte. The 1025 design's "inside a written region"
premise is FALSE for the 1025 arm. What is TRUE, and identical across both arms:

    far == p->user_stack (the requested region top)        [both arms]
    far - sp == 0xF8C                                      [both arms]

`far - sp == 0xF8C` in *both* crashes is the tell: the same userspace instruction, at the same
offset above `sp`, walks off the top of the argv/env block that `exec_copyout_strings` built.

## 2. WHAT THE TREE SAYS, BY VALUE (so 1026 does not re-walk it)

* The stack region is placed by `create_unix_stack` (`bsd/kern/kern_exec.c:3596-3680`):
  `size = round_page(user_stack_size)` (= MAXSSIZ = `0x100000`, `bsd/arm/vmparam.h:21`),
  `addr = trunc_page(user_stack - size)`, `mach_vm_allocate(FIXED)` -> entry `[addr, addr+size)`,
  then `mach_vm_protect(prot_addr = addr, prot_size)` sets the **BOTTOM** page `VM_PROT_NONE`
  (the guard; `prot_size=0x1000` measured). So the TOP page `[req-0x1000, req)` IS mapped.
* `exec_copyout_strings` (`bsd/kern/kern_exec.c:2700-2870`) starts at `stack = p->user_stack = req`
  and grows DOWN: `string_area = stack - string_size`, `ptr_area = string_area - ptr_area_size`,
  `argc_area = ptr_area - ptr_size`, `*stackp = argc_area`. **No code reserves the "16b" header the
  file's own layout comment draws above the string area** — but the string area's top byte is
  `req-1`, so nothing this function writes touches `req`. This arithmetic is **byte-identical to
  4570** (`external/xnu-4570.1.46/bsd/kern/kern_exec.c:3803+`), so it is NOT a D13 regression.
* `exec_mach_imgact` order (`bsd/kern/kern_exec.c:940-996`): `create_unix_stack` ->
  `exec_copyout_strings` -> `thread_setuserstack(sp)` -> (dynlinker) `ap = thread_adjuserstack(-4)`
  + `copyoutptr(mach_header)` -> `exec_prefault_data(p, imgp, &load_result)` -> `thread_setentrypoint`.
* The requested top `LAB_USER_STACK = 0x2BE00000` (`osfmk/arm/status.c:63-70`, the SHREG_GEOM arm)
  equals the **dyld base address** (`dyldBaseAddress` in the cache header, `docs/reference/
  d13-dyld-shared-cache-study.md` §1) — "the constants interlock (stack top == dyld base < region
  base)". The *observed* `req` is `0x2be00000 - <what the loader slid/consumed>`: launchd
  0x23000, launchctl 0xcb000.

So: the region, the guard, the argv/env layout, and the entry/slide arithmetic are all
upstream-correct and internally consistent. The fault is a genuine access to a VA **above the
region top**, by userspace, one word past the argv/env block — and the kernel *correctly* reports
no entry there. **The open question 1026 must answer is therefore a WHICH, not a what:**

  (H1) **Wrong map.** `create_unix_stack` allocated into `get_task_map(task)`, but the fault walks
       `thread->map` (trap.c:822). If those differ for this task (shared-region submap / vm_map_switch
       in progress), the entry is invisible to the walk even though `far` is a legal region byte.
  (H2) **Off-the-end.** The entry genuinely ends at `far` (as the numbers show), and the *cause* is
       upstream: the argv/env block or the initial `sp` is one word too high, so a correct userspace
       scan (`[sp .. req]`) reads/writes one word past. In this case the FIX is on the kernel side
       (give the block a word of headroom / lower the initial sp), because userspace is behaving.

These predict DIFFERENT fixes, so 1026 must DISCRIMINATE before building the fix.

## 3. THE INSTRUMENT (probe-only; discriminates H1 vs H2 by value)

Extend the 1025 publisher at `osfmk/arm/trap.c:846-856` (same `#if STAGE90_XNU_USTACK_PROBE`
block, same `code != KERN_SUCCESS` guard), adding — for the failing fault only:

    xnu_live_abt_lookup_far=0x..    <- vm_map_lookup_entry(map, dfar, &e)  -> 1/0  (H2: 0)
    xnu_live_abt_entry_lo=0x..      <- e->vme_start   (when found)          (names the region)
    xnu_live_abt_entry_hi=0x..      <- e->vme_end
    xnu_live_abt_far_in_map=0x..    <- vm_map_lookup_entry(map, dfar-4, &e2) -> 1/0  (H2: 1 if the word below is in)
    xnu_live_abt_map=0x..           <- `map` (thread->map)
    xnu_live_abt_taskmap=0x..       <- get_task_map(thread->task)            (H1: map != taskmap)
    xnu_live_abt_ustack=0x..        <- (thread->task->bsd_info) ? p->user_stack : 0

All seven are plain `printf` on the ram-console channel (non-ringed, like 1025). No behaviour
change: the values are read, never written; the `vm_map_lookup_entry` calls are read-only under the
map's read lock is NOT taken here — they must run **before** the map is mutated and only on the
failure path, exactly where the 1025 prints are. (If taking the lock is judged unsafe in the abort
path, the fallback is to read `map->hint`/the pmap entry alone and publish those; the by-value
decision is unchanged.)

## 4. PRE-REGISTERED READING (what each cell means, decided before the build)

    H1 (wrong map)     : lookup_far=0 AND far_in_map=0 AND map != taskmap AND ustack==far
                         -> the entry lives in taskmap, the walk used `map`; fix = walk taskmap
                            (or make the two equal at this point in exec).
    H2 (off-the-end)   : lookup_far=0 AND far_in_map=1 AND entry_hi==far AND map == taskmap
                         -> the region ends exactly at far; a legal word sits just below.
                            fix = give the initial argv/env block / sp a word of headroom so the
                            block top < region top (kernel-side; userspace is correct).
    H-OTHER            : any other combination -> report it; do NOT pick a fix (fail closed), and
                         1027 instruments whatever the combination names.

## 5. WHAT 1026 DOES NOT DO

* Does not change `LAB_USER_STACK`, `MAXSSIZ`, or `VM_MAX_ADDRESS` (all measured correct).
* Does not touch `exec_copyout_strings`' arithmetic (byte-identical to 4570 — a change there would
  be a guess against a correct reference).
* Does not add a fifth trap.c rung without re-staging the other three
  ([[mi4-one-file-many-rungs]]: 994 witness / 1020 undef_raise / 1025 probe).

## 6. FILE-LEVEL PLAN (a team implements it; the goal requires a team per stage)

1. `tools/patch_d13_abt_entry_probe.py` (+ `stage_d13_abt_entry_probe.sh`): stage the §3 publisher
   behind `STAGE90_XNU_ABT_ENTRY_PROBE`; `ALLOWED_IF_IDENTIFIERS` must carry 994/1020/1025's
   switches. Idempotent, done-mark-first, anchors asserted by count.
2. `scripts/build_1026.sh`: re-stage ALL trap.c edits in order, then this one; carry 1025's switch
   set verbatim + the new switch; assert the linked image carries both 1025's and 1026's keys.
3. `tools/check_1026_capture.py`: cells H1/H2/H-OTHER + the 1025 re-reading (FAULT-NAMED must
   still fire) + REGRESSION (storm/trap24) + G-CTL; `--selftest` with a capture shaped like the
   measured one (blank-separated keys).
4. `scripts/{park,press}_1026.sh`: `grep -qa P <(strings X)` (NOT `strings|grep -q`, which returns
   141 under pipefail — [[mi4-mutation-anchors-are-code-spans]] instance m1025); the negative
   control must point at a PRE-rung arm (NOT 1025's own).
5. `records/1026-press-read.txt` from the press; memory `mi4-1026-*` updated by value.

## 7. H1 HAS A NAMED MECHANISM IN THIS TREE (found while writing 1026; the probe confirms it)

The abort walks `map = thread->map` (`osfmk/arm/trap.c:822`). In this ARM port **`thread->map` is a
CACHED COPY of `task->map`**, and two code paths update them DIFFERENTLY:

* `PMAP_SWITCH_USER(th, map, cpu)` = `pmap_switch(map->pmap), th->map = map;`
  (`osfmk/arm/pmap.h:156`) — sets **`thread->map` only**, never `task->map`.
  `vm_map_switch(map)` (`osfmk/vm/vm_map.c:11788`) is exactly this macro.
* `swap_task_map(task, thread, map, doswitch)` (`osfmk/kern/bsd_kern.c:297-307`) sets
  `thread->map = task->map = map` (both), and `panic("swap_task_map")` if `task != thread->task`.

`exec_mach_imgact` brackets its setup with `old_map = vm_map_switch(get_task_map(task))`
(`bsd/kern/kern_exec.c:948`) and later `vm_map_switch(old_map)` (`:995`). Each call sets
`thread->map` (thread only) and returns the previous `thread->map`. So if `task->map` is set to the
new map by a *different* path (`swap_task_map`) while `thread->map` is left at `old_map` by the
exec's restore, the two DESYNC — and a later userspace fault walks `thread->map`, a map that does
NOT contain the stack entry `create_unix_stack` put into `get_task_map(task)`.

That is a concrete, fixable H1: **the walking map is stale.** The 1026 probe decides it by value:
`xnu_live_abt_map` vs `xnu_live_abt_taskmap` — if they differ at the fault, H1 is CONFIRMED.

## 8. PRIOR — H1 LOOKS RULED OUT BY SOURCE; H2 IS THE EXPECTED READING

Walking the spawn path by value (this is what launchd uses for launchctl):

* `exec_mach_imgact` (`kern_exec.c:839-855`): for `spawn`, `thread = imgp->ip_new_thread` (the
  freshly forked thread), `task = get_threadtask(thread)` (the child task), `map = get_task_map(task)`.
* `load_machfile(imgp, mach_header, thread, map, &load_result)` (`:881`) ends with
  `old_map = swap_task_map(old_task, thread, map, !spawn)` (`mach_loader.c:438`) — with `spawn=TRUE`
  this sets **`thread->map = task->map = map`** (both), `doswitch=FALSE` (no pmap switch), then
  `vm_map_deallocate(old_map)`.
* `create_unix_stack(get_task_map(task), ...)` (`:940`) allocates into that SAME map.
* `exec_mach_imgact:948` `vm_map_switch(get_task_map(task))` re-sets `thread->map` to the same map.

So on this path `thread->map == task->map == get_task_map(task)` at every point, including the
later userspace fault (trap.c:822 reads `thread->map`). The `thread.c:749 new_thread->map =
parent_task->map` staleness is fixed by `swap_task_map` before the stack is built. **Therefore H1
(wrong map) is expected to read FALSE, and the 1026 probe should report `map == taskmap`,
`lookup_far=0`, `far_in_map=1`, `entry_hi == far` — i.e. H2.**

If the press confirms H2, the fix is KERNEL-SIDE and one of (decided by value after the probe):
1. `create_unix_stack` reserves the region so its TOP is strictly above the initial stack block,
   i.e. the region covers `[addr, req]` including the top word (one extra page at the top), or
2. the initial `sp`/argv block is placed one word lower so `[sp + frame] < req` strictly.

Both are `create_unix_stack`/`exec_copyout_strings`-adjacent; neither touches the measured-correct
`MAXSSIZ`, `LAB_USER_STACK`, or the `VM_MAX_ADDRESS` split. The probe's `entry_lo/entry_hi` name
which region the walk DID see, so the fix is chosen against a number, not a guess.

* The abort path may not be safe to call `vm_map_lookup_entry` in (map lock). Mitigation in §3.
* The fault `pc=0x3b4ce756`/`lr=0x3b4c69af` are in the shared cache; no cache artifact is present
  in the repo to disassemble (`docs/reference/d13-dyld-shared-cache-study.md` names the header in
  `/mnt/data/ios7-payload/v2/ios7/rootfs.hfs` @0x455d000). If §3 leaves H2 alive and the fix is
  contested, 1027 extracts that cache and names the instruction.