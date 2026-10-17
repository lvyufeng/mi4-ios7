RUNGS 1024 (D) + 1024-W — THE USER MAP IS 2x THE HARDWARE SPLIT: make `VM_MAX_ADDRESS` agree with `set_mmu_ttbcr(2)`

## 0. WHAT THIS RUNG IS FOR, IN ONE PARAGRAPH

The 1023 press moved the wall: trap 24 dispatches and `mach_port_construct` returns 0
(`records/1023-press-read.txt`). The boot now dies in pid 1 in a **~2^20-iteration data-abort loop**
at user VA `0x40083008`. Rung 1024's finding, all read by value (card bytes + the armed kernel's own
instructions + the 1023 capture): **the task map's ceiling is `0x80000000` while the hardware's
TTBR0 covers only `0x40000000`** — `task_create_internal` passes `VM_MAX_ADDRESS = 0x80000000` to
`vm_map_create`, and `arm_vm_init.c:475` sets `TTBCR.N = 2` (1 GiB). The first big anywhere-map in
launchd — `_pthread_create`'s stack allocation — is placed above the split, where the hardware walks
the KERNEL's TTBR1 tree and finds nothing. `vm_fault` "succeeds" for ever (it installs into the user
pmap's TTBR0-side tree, which the hardware never consults for that VA). The fix is one value, in the
file that already documents it.

## 1. THE MECHANISM, BY VALUE

### 1.1 The faulting instruction and the value it loads

`abt_pc = 0x39ded790 - slide 0x01bac000 = 0x38241790` = `/usr/lib/system/libsystem_pthread.dylib
+0x2790` (image[639], base `0x3823f000`). Its own symtab names the function:
`0x382416d4 _pthread_create` (span `..0x38241823`) ⇒ the pc is **`_pthread_create+0xbc`**. Card
window (`xnu_card_hfs.img` + `0x1079E790`; rule in §6.0), `--adjust-vma=0x38241700`:

```
38241750  add r0,sp,#8 / add r2,sp,#4 / bl 0x38242494     ; __pthread_allocate_stack (out-params)
38241758  cmp r0,#0 / bne.n 0x3824181a                    ; only SUCCESS falls through
3824175c  ldr r5,[sp,#8]                                  ; r5 = the returned pthread struct / stack
3824175e  orr.w r6,r6,#0x1000000                          ; PTHREAD_START_CUSTOM (pthread_synch.c:166)
38241762  strd sl,fp,[r5,#28]                             ; {start_routine, arg} -> struct+28/+32
38241770  blx 0x382439d0                                  ; __bsdthread_create (NOT reached)
38241790  ldr r0,[r5,#8]                                  ; <<< abt_pc / last stall_pc
38241792  orr.w r1,r0,#2 / str r1,[r5,#8]                 ; the struct's flags word at +8
```

`abt_far = 0x40083008 = r5 + 8` ⇒ **`r5 = 0x40083000` exactly**, and it came from out-param 1 of the
allocator (`0x38242494`, which mmaps through the libsystem_kernel veneer `0x38243c30` → GOT
`0x39f400c8` → `0x381c6619`, computes the stack top at `0x38242594`, and stores it to the
out-param at `0x382425bc`). **The faulting access is a LOAD** — DFSR `0x07` has WnR (bit 11) clear
(the tree's own write case is `0x0000080f`, `entry_stubs.c:2082`) — and that agrees with the
instruction: `ldr r0,[r5,#8]`, `_pthread_create` reading the new struct's flags word.

### 1.2 The kernel side

`abt_ptel1 = 0x8173b001` (a valid COARSE table descriptor) → L2 at PA `0x8173b000`; index for
`0x40083000` = 0 → `abt_ptel2 = 0`, `abt_pteu = 0`, `abt_wkleaf2=0`, `abt_wkstable=1` (double read
after `dsb`), `abt_wkoow=0`. The control VA (`0x80080000`, `_WCTL`) reads `0x8008021a` — a PTE_SMALL
section — so the walker is healthy and the zero is a real absence. The same L2 answers
`0x40000000`/`0x40001000` (the port's 2-page commpage — `IOS7LAB commpage alias` line in all three
captures) and nothing else. **The 1 MB slot at `0x40000000` is the commpage's slot, and `0x83000` is
0x81000 past the commpage's second page.**

### 1.3 The mismatch (the defect)

| side | value | where |
|---|---|---|
| hardware split | TTBR0 owns `[0, 0x40000000)`, TTBR1 the rest | `set_mmu_ttbcr(2)`, `d13 arm_vm_init.c:475`; `entry_stubs.c:2325` |
| task map ceiling | **`0x80000000`** | `out/stage90/xnu_arm_entry.elf` `80085cf0 mov r2,#-2147483648` → `vm_map_create` at `80085cfc`; `task.c:1014` |
| why that branch | `BOARD_CONFIG_ARMPBA8 \|\| BOARD_CONFIG_QSD8250_LEO` = 0 on CANCRO | `tools/patch_d13_shreg_wire.py:18`; `d13 vm_param.h:62-68` |

The header's own comment for the split-consistent branch: *"This ARM pmap uses a 1 GiB TTBR0 split.
Ordinary user allocations must stay below the kernel-owned commpage at 0x40000000."* CANCRO
compiles the **other** branch. Nothing in the port has yet forced the two definitions of "the split"
to agree ([[mi4-one-value-two-definitions]]).

### 1.4 Why it is an infinite loop rather than a crash

For a VA above the split the hardware reads TTBR1 = `cpu_ttb` (kernel_pmap's tree). The task's own
pmap tree is reached via TTBR0 — which the hardware does **not** use for that VA. So when
`vm_map_lookup` finds the freshly-mapped pthread stack (prot 3) and `vm_fault` runs, the PTE is
installed where nothing walks it; every re-execution of the load faults again. That is exactly the
measured shape: ~2^20 iterations, `wdt_pets` healthy, `vm_map_lookup`/`vm_fault` pairs recorded at
the ladder ordininals, the process never killed (the fault is "handled" every time).

**The value 0x83000** (why that offset, not the exact page) is a *hypothesis for the offset only*:
consistent with the first big anywhere-allocation in launchd landing just above the first free hole
after the shared region (the port prints `shared region 0x2c000000..0x40000000; stack below
0x2be00000`), but nothing measured this rung pins the exact page — the mmap hint, the port's own
reservations and the allocator's choice all contribute. **Nothing in the fix depends on it**, and the
falsifiers key on the *bounds* (`usr_map_max`) and on the *absence* of a storm at/above the split,
never on a re-used absolute address. 1024-W measures the offset if a later rung needs it.

## 2. THE FIX — ONE LINE, IN THE FILE THAT ALREADY ARGUES FOR IT

`d13 osfmk/mach/arm/vm_param.h:62-68`: extend the split-consistent branch's condition (`:63`) with the
port's own switch — ` || (defined(STAGE90_XNU_VM_MAX_SPLIT) && STAGE90_XNU_VM_MAX_SPLIT)` — so with
`-DSTAGE90_XNU_VM_MAX_SPLIT=1` `VM_MAX_ADDRESS` becomes `0x40000000` on CANCRO exactly as it is on the
two other 1-GiB-split boards, and with the switch off the `#if` is the tree's original line byte for
byte (`defined()` is checked first — [[mi4-off-option-two-spellings]]). **Why a switch and not
`BOARD_CONFIG_MSM8974_CANCRO`:** defining that board macro would flip *every* gate keyed on the board
names across the tree (traps_lo.s's `-3` SWI routing, `ios7_compat.h`'s `ios7_compat_vmabi_enabled()`,
…), which is not a one-value change; the port's idiom is one switch per fix, and this switch is the
port's board by construction. That is the whole behavioural change. Staged as
`tools/patch_d13_vm_max_split.py` (plus the `tools/stage_d13_vm_max_split.sh` wrapper) in the
established idiom (anchor + done-mark, refuse on hand edits, `#!/usr/bin/env python3`, `-I`-safe),
threaded through the **GLOBAL `DEFINES` array** of `tools/build_xnu_arm_kernel.sh` (every compile line
carries it, including the EABI-runtime and firehose blocks) under the arm switch
`STAGE90_XNU_VM_MAX_SPLIT` (default 0 ⇒ byte-identical image). **Not `EXTRA_DEFINES`** — it is appended
last and the two non-manifest blocks (`:1818`, `:1860`) do not get it, so a partial fix would compile
some objects with the old ceiling behind a green build ([[mi4-one-value-two-definitions]]); not an
ASFLAGS entry either — the whole `VM_MAX_ADDRESS` block is inside `#ifndef __ASSEMBLER__`.

**Consequences that must be swept, not discovered ([[mi4-a-claim-in-a-comment-is-not-a-check]]):**
- `tools/check_1022_capture.py:179` hard-codes `USER_PTR_HI = 0x80000000  # VM_MAX_ADDRESS on CANCRO
  (vm_param.h:63)` — the recorded reason, and the value it names, both change. Every consumer of that
  constant must be re-derived from the new definition in the same commit as the patch.
- Anything else that treats `[0x40000000, 0x80000000)` as allocatable user VA (dyld's `mmap` hints,
  the shreg wire's own reservation, the fixture's mmaps) must be checked against the new ceiling; the
  sweep is §6's second row, and it is a *reading* task, not a guess.
- `_LMB_FIX` stays 0 ([[mi4-957-3gb-measurement-and-region-reader]]); `MEM_SIZE_MAX` is untouched by
  this rung (it is the pmap's own ceiling, a different value — do not conflate the two).

## 3. THE READS THAT MAKE THE FIX FALSIFIABLE (1024-D); THE ON-DEVICE CELLS (1024-W)

### 1024-D — the decisive reading is the LINKED ELF, not a runtime publisher

The fix changes ONE value the compiler folds into ONE call site. The place the decision becomes a
machine fact is therefore the **linked image**, and `out/stage90/xnu_arm_entry.elf` is where a stale or
half-rebuilt pool shows up (`records/1020-build-defect.txt`: `build_entry.sh` only LINKS the pool
objects, so a stale pool silently keeps the old ceiling while every source-level check passes).

1. **The ELF cell — `tools/check_vm_max_split.py <elf> --expect on|off`** (BY VALUE, in both
   directions; the 1023 image is its own OFF control). Inside `task_create_internal` the non-fork arm
   materializes `vm_map_create`'s max argument:
   ```
   80085cf0  e3a02102  mov r2, #-2147483648   ; 0x80000000   <<< OFF / 1023 image
   80085cfc  ebfedac7  bl  8003c820 <vm_map_create>
   ```
   `--expect off` ⇒ that word must read `0x80000000` (the shipped 1023 ELF satisfies this — the
   negative control, MEASURED); `--expect on` ⇒ it must read `0x40000000` (a single `mov r2,#imm` or a
   `movw r2,#lo` + `movt r2,#hi` pair — both spellings are read). A MISSING symbol or an undecodable
   immediate is a REFUSAL, never a pass. This cell runs **before the pool rebuild** (`--expect off`:
   the tree is still the old shape) and **on the linked image** (`--expect on`), so the build cannot
   ship a press whose image disagrees with the arm — see §4's honest negative and `mi4-measurement-defects`.

**The runtime publisher rows below are DEFERRED to 1024-W.** The entry layer (`src/entry/entry_stubs.c`,
`entry_trace.c`) is **libc-free and includes no kernel headers** (it pulls in only `<stdint.h>`, its
own `entry_*.h`, and `<arm/proc_reg.h>`), so it cannot read a `vm_map_t`'s `min_offset`/`max_offset` —
there is no `current_map`/`usr_map`/`uvspace`/`min_offset`/`max_offset` anywhere in `src/`, `tools/` or
`scripts/`, and the only `thread->map` readers use fixed byte offsets (`STAGE90_ACT_MAP 956`,
`STAGE90_MAP_PMAP 44`) and publish the *pointer*, not the bounds. So a `xnu_live_usr_map_{min,max}`
publisher is a **kernel-pool** change (inside the XNU tree, behind the same switch), and it belongs to
1024-W, run only if the 1024 press shows a survivor at VA ≥ `0x40000000` that the ELF cell cannot
explain. All of 1024-W lives behind `STAGE90_XNU_VM_MAX_SPLIT` so it costs nothing when off:

1. **`xnu_live_usr_map_min` / `xnu_live_usr_map_max`** — the *task map's own* bounds, read from the
   current map at the first abort (`map->min_offset`, `map->max_offset`). Before the patch this reads
   `0x0 / 0x80000000`; after it, `0x0 / 0x40000000`. Published by the same instrument that reads the
   storm; implemented pool-side.
2. **`xnu_live_arm_vspace_start`** — `virtual_space_start = (gVirtBase + MEM_SIZE_MAX + 0x3FFFFF) &
   0xFFC00000` = **`0x40400000`** in this port (`gVirtBase = 0x00200000`, `MEM_SIZE_MAX =
   0x40000000`), with `xnu_live_arm_vspace_at_5e500000` = `0x60000000` (the value
   `tools/check_mem_size_max.py` re-derives) and `xnu_live_arm_vspace_clear` = predicate vs
   `[ptewbase, ptewbase+ptewlen)`. Today the pmap's own tables and the user map's top share the
   1 MiB slot at `0x40000000` — that is `abt_ptel1 = 0x8173b001`, the coarse table the walk keeps
   reading. This cell makes the collision a NUMBER; it does not move anything.
3. **the (U) registry** — every `pmap_enter`/`page_alloc` at VA ≥ the split, published as
   `xnu_live_uv_{va,l1,l2,seq,caller}` (first 16, then a count). If the fix is complete, it stays
   empty; if something else also maps ≥ `0x40000000`, it names the VA and the caller, and 1024-W reads
   the leaf at the top of the user map it implies. Implemented pool-side (the entry layer cannot see
   `pmap_enter`).
4. **`uvspace_word` redefined self-identifying** — the 1015b sentinel's `if (wv != w1)` proves only
   "the word differs", not "the VA is unmapped" ([[mi4-measurement-defects]]); 1024 republishes it
   with the L1 descriptor, the L2 index and the same VA, so the cell identifies its own slot.



### 1024-D's grep-able sweep (a reading task, done before the press)

## 4. FALSIFIERS (what the 1024 press must read)

The press is read by `tools/check_1024_capture.py`, whose pre-registered cells are:

- **`STORM-GONE`** — the 1023 storm signature is ABSENT (no `abt_pc` at slide-corrected `0x38241790`;
  no cluster of `abt_far == 0x40083008`) **and** the prior rungs' positive controls still hold in the
  same capture: `IOS7LAB trap24 frame` x4, `IOS7LAB port_construct … result=0` x4,
  `xnu_live_undef_seq` = 0x, and zero panics. The checker then reports the NEW frontier: the last
  non-storm `abt_pc` (slide-corrected), its `abt_far`, the last user SVC record, the last stall pc.
- **`STORM-PERSISTS`** — the storm recurs at 1023's pc/far at scale. The patch did **not** reach the
  compiled image; the build-side gate that must have refused is
  `tools/check_vm_max_split.py <elf> --expect on` (the `mov r2,#-2147483648` at `task_create_internal`
  must have become `mov r2,#0x40000000` / `movw+movt`). Read that ELF cell before anything else.
- **`STORM-MOVED`** — a storm exists elsewhere; in particular any `abt_far ≥ 0x40000000` means the map
  was not the only producer. The capture names the pc and far; 1024-W's (U) registry names the culprit.
  ⚠ **READ THIS AS THE PRE-REGISTERED TRADE IT IS, NOT A FAILED FIX.** The guard fires on ANY tail
  abort with `far ≥ 0x40000000` that is not the exact 1023 pc/far pair (check_1024_capture.py:681-700),
  so it SHADOWS `STORM-GONE` on a working press whenever a legal above-split VA is touched: the fix keeps
  *user allocations* below the split, but the commpage alias, the dyld shared cache, and the mmap arena
  can legitimately sit at/above `0x40000000`, and a 1015-classified tail at a non-1023 VA recurs there
  too. So the cell most likely to fire on a SUCCESSFUL 1024 press is `STORM-MOVED`. Before reading it as
  a non-fix outcome, (a) read the pc/far pairs the cell prints — a fix that worked shows NO storm at the
  1023 `pc 0x38241790 / far 0x40083008` pair, just other VA; (b) confirm
  `tools/check_vm_max_split.py out/stage90/xnu_arm_entry.elf --expect on` PASSes (it does on the parked
  `64558b47` image at `0x80085cf0 = 0x40000000`). "The map was not the only producer" (1024-W's registry
  names the culprit) is a DIFFERENT reading from "the fix failed".
  *(Found by an independent by-value audit of the 1024 scripts, 2026-10-16; also noted there: a tail
  abort row carrying `_pcn`+`_pc` but no `_pcfar` is invisible to the reader rather than a refusal —
  fail-open in principle, but the recorder emits all five abort keys as one contiguous block
  (`entry_stubs.c:2058-2063`, 22/22 in the 1023 capture), so it needs a mid-block cut that also kept
  the terminal marker. Recorded as a checker limitation, not edited while the arm is parked.)*
- **`PRIOR-RUNGS-REGRESSED`** — one of the prior rungs' controls (trap-24 dispatch/result, undef_seq,
  no-panic) regressed ⇒ the arm's switch set is wrong, not the fix.
- **`G-CTL` / WITHHOLD** — neither the live channel nor any `IOS7LAB` line is live ⇒ no reading.

## 5. WHAT WAS RULED OUT ON THE WAY (kept so 1025 does not re-walk it)

- **Not a commpage-contract defect.** `far = 0x40000000 + 0x83000` is the pthread stack/struct
  address; the commpage (data page + `_COMM_PAGE_TEXT_START` page) is intact and its alias at
  `0xffff4000` reads fine. The earlier "the dylib derives a commpage pointer and indexes 0x83000"
  reading was a numerological coincidence (`0x40000000 = _COMM_PAGE32_BASE_ADDRESS` **and** the
  shared region's end **and** the split).
- **Not "NULL the L2 slot" / not `TTBCR.N=1`**: the first would map the kernel's own table read-only
  and hand the walk a null leaf for ever; the second moves the DRAM window into TTBR0 and breaks the
  control VA. Both were considered and rejected by value.
- **Not the two-L1 churn** (`0x8173a000` at commpage-enter vs `0x8173b000` at the stall): per-process
  pmap churn, normal — a peer correction accepted and recorded.
- **Not an L1 bit-1 defect**: `ptel1 = 0x8173b001` is a valid table descriptor (`&2` is the L2
  small-page bit, an L1 descriptor's bit 1 means COARSE — but the observed word is *used* through the
  walker's TTBR1 branch and its type is consistent); the earlier "one value two definitions" note
  there is withdrawn rather than left standing.

## 6. FILE-LEVEL PLAN

### 6.0 The card-offset rule (prerequisite for every card claim above)

`card_off = 0x455d000 + slice.fileOff + (va − slice.base)`; slice `fileOff` is CACHE-relative
(validated: `0x3815bc38 → 0x106b0c38` reads `f0 b5 03 af 2d e9 00 0d` = `push {r4-r7,lr}`; `0x38241790
→ 0x1079E790` reads `68 a8` = `ldr r0,[r5,#8]`). A LE byte search of the 947 MB card finds
`00 30 08 40` **zero** times ⇒ `0x40083000` is computed at run time (it is the mmap result).

### 6.1 Files

| file | change |
|---|---|
| `tools/patch_d13_vm_max_split.py` + `tools/stage_d13_vm_max_split.sh` | NEW — widen `vm_param.h:63` with the `defined()`-first switch; real-preprocessor two-arm proof, refuse on hand edits, revert on a failed proof. **DONE** (plan + apply + verify) |
| `tools/check_vm_max_split.py` | NEW — BY VALUE in the linked ELF: `task_create_internal`'s `vm_map_create` max arg is `0x40000000` with `--expect on` / `0x80000000` with `--expect off`; missing symbol ⇒ REFUSAL. **DONE** (selftest matrix + the 1023 ELF reads OFF=PASS / ON=FAIL) |
| `tools/build_xnu_arm_kernel.sh` | NEW switch block at `:994` in the GLOBAL `DEFINES` array (`STAGE90_XNU_VM_MAX_SPLIT`), NOT `EXTRA_DEFINES`. **DONE** (`bash -n` clean; block greps at `:994`) |
| `tools/check_1022_capture.py:179` | comment correction (the value stays: it describes the OFF kernel that produced the 1022 capture); the 1024 checker carries the tri-class where `[0x40000000, 0x80000000)` is its own shape (ABOVE-SPLIT), not "fast" |
| `tools/check_1024_capture.py` | NEW — §4's cells |
| `scripts/build_1024.sh` | NEW — ladder from `build_1023.sh`: carries 1023's record set + `STAGE90_XNU_VM_MAX_SPLIT=1`; asserts the four carrier sites; stages the header; pool build; by-value clauses on the pool object (5a) and the linked image (6b) — **written; first run logged at `out/stage90/build_1024.log`** |
| `scripts/park_1024.sh`, `press_1024.sh` | NEW — park/press ladder from `park_1023.sh`/`press_1023.sh` |
| `src/entry/entry_stubs.c`, `entry_trace.c` | **1024-W only** (deferred, §3): the pool-side publisher rows cannot live in the libc-free entry layer |
| `records/1024-*.txt`, `memory/mi4-1024-*.md` | on read / after |

### 6.2 Discipline (unchanged)

Full previous switch set from `out/stage90/xnu_arm_entry-config.txt`; `STAGE90_XNU_GLOBAL_FIX=1`
unconditional (no record carrier — `records/1020-build-defect.txt`); `_LMB_FIX` explicitly 0 and the
checker refuses if it flips; `DEFERRED_TRAPS = (25, 41, 42)` untouched; never `fastboot boot
<golden>` to read a log; never flash; never press power; `scripts/recover_last_kmsg.sh --read-only`
before any power cycle.

## 7. HONEST RISKS

1. **A one-line header change moves user allocations.** Every assumption about user VA ceilings in
   checkers and tools is part of the change, not after it (§2's sweep).
2. **The exact landing site may differ** from 0x40083000 after the fix (different hint, different
   first allocator); the cells key on the *bounds* (`usr_map_max`) and on the *absence* of a storm
   above the split, never on a re-used absolute address.
3. **If the storm is still there after the fix at the same VA**, the compiled image is not what the
   checker blessed — read `check_vm_max_split.py`'s ELF cell before anything else.