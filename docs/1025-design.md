# 1025 DESIGN v2 — RETIRE THE launchctl[2] STACK ABORT BY MEASURING THE FAILED PAGE FAULT

## 0. WHAT THIS RUNG IS FOR (one paragraph)

The 1024 press's own boot reached `*** launchd[1] has started up ***` and spawned pid 2
`launchctl`, then died: `launchctl[2]: usermode data abort, EXC_BAD_ACCESS at 0x2bdbe000 ...
(Translation fault on page)` (records/1024b-frontier-launchctl-crash.txt). v1 of this design
(docs/1025-design.md) explained that as a `create_unix_stack` FIXED-allocation COLLISION. **v1's
mechanism is FALSIFIED** by records/1025-source-trace.txt: the child's task map is FRESH
(osfmk/kern/task.c:426-428) and the FIXED target 0x2BD00000 lies BELOW the shared window base
0x2C000000, so the allocation SUCCEEDS. By value the page at 0x2bdbe000 is INSIDE the allocated,
already-written stack region [0x2BD00000, 0x2BE00000). What actually happened is a **failed page
fault**: `vm_fault` was called on `0x2bdbe000` and returned non-SUCCESS, and the trap delivered
that failure to launchctl as `EXC_BAD_ACCESS` (osfmk/arm/trap.c:806-875, 968). 1025 exists to
**publish the value `vm_fault` returned** — which CANCRO currently discards — so the frontier
becomes a NUMBER (KERN_MEMORY_ERROR? KERN_PROTECTION_FAILURE? KERN_INVALID_ADDRESS?) and the next
rung can fix the right thing.

## 1. THE READING, BY VALUE (what 1024b + the source trace established)

From `out/stage90/captures/recovered-unknown-arm-20261016-122008-last_kmsg.txt`:
- Boot reached `bsd_init: done` (:4095), `BSD root: md0` (:4096), `attempting to start init of
  /sbin/launchd` (:4098), `*** launchd[1] has started up. ***` (:4139), then pid 2.
- `mini4: the OS starts the process at 0x2be43028 (the thread's user pc was 0x2bdbdf0c)` (:4146).
- `IOS7SHREG check_np pid=2 out=0x2bdbb980` / `ret=0` (:4147-4148) — a stack write SUCCEEDS.
- `IOS7LAB trap15 frame ... r1=2bdbd108 / 2bdbd0b8 / 2bdbcb50 ... result=0` (:4153-4164) — more
  stack writes SUCCEED.
- Crash (:4172): `usermode data abort, EXC_BAD_ACCESS at 0x2bdbe000 ... (Translation fault on
  page)`. Registers (:4173-4178): `r4=r6=0x2bdbe000`, `r7=r11=0x2bdbd080`, `sp=0x2bdbd074`,
  `lr=0x3adbc9af`, `pc=0x3adc4756`, `cpsr=0xa0000030` (T=1 ⇒ Thumb, mode=USR).

## 2. THE MECHANISM, BY VALUE, FROM THE TREE (osfmk/arm/trap.c)

The usermode data-abort path (trap.c:794-910):
```
:806   code = vm_fault(map, vm_map_trunc_page(dfar),
:807            (dfsr & 0x800) ? (VM_PROT_READ|VM_PROT_WRITE) : (VM_PROT_READ),
:808            FALSE, THREAD_UNINT, NULL, vm_map_trunc_page(0));
:809   if ((code != KERN_SUCCESS) && (code != KERN_ABORTED)) {
:810   #if BOARD_CONFIG_QSD8250_LEO
:811       leo_installd_fault_result = code;
:812       leo_installd_failed = TRUE;
:813       leo037_data_error = code;          <-- the value, published ONLY on LEO
:814   #endif
...     (the printf of the abort + register dump, :871-901)
:902   } else { ml_set_interrupts_enabled(TRUE); return; }   <-- the STORM retry path
:865   exception_type = EXC_BAD_ACCESS;
:968   doexception(exception_type, exception_subcode, 0);      <-- delivered to the process
```
So when `vm_fault` fails on a usermode data abort, the trap (a) prints the abort line and registers
and (b) calls `doexception`, delivering `EXC_BAD_ACCESS` to launchctl — which is the "System
bootstrapper has crashed: Bus error: 10". **The value that explains WHY (`code`, plus `dfar`, `dfsr`
and the prot) is discarded on CANCRO** because the only assignment is inside
`#if BOARD_CONFIG_QSD8250_LEO`.

`vm_fault`'s possible non-SUCCESS returns (osfmk/vm/vm_fault.c): `KERN_MEMORY_ERROR` (:1048, :3088,
:3533, :3732, :4680), `KERN_PROTECTION_FAILURE` (:3985, the execute-eligibility path), plus
`KERN_INVALID_ADDRESS` / `KERN_FAILURE` from the mapping-validity checks (:2823). The value
distinguishes the CAUSE:
- `KERN_MEMORY_ERROR` ⇒ the backing object/page could not be produced (a real VM defect in the
  stack's anonymous object);
- `KERN_PROTECTION_FAILURE` ⇒ a permission/execute-eligibility refusal;
- `KERN_INVALID_ADDRESS` ⇒ the address is not covered by any entry when the fault walks (the
  "vm_map leaf absent" 1013c/1015 class).

## 3. THE INSTRUMENT (probe-only; no behaviour change; no hazard)  -- AS IMPLEMENTED

**The channel is the kernel's OWN `printf`, not `entry_write_kv`.** `entry_write_kv` is an ENTRY-side
primitive (`src/entry/entry_stubs.c`), reachable only from the entry image; trap.c and kern_exec.c are
POOL objects and reach the ram console through `printf` — the SAME channel the existing `IOS7LAB ...`
lines (and the 1024 capture's `IOS7LAB trap24 frame` rows) already use. So the design's key NAMES are
kept, printed as `key=value` lines the capture and `tools/check_1025_capture.py` read; the mechanism is
`printf`. Because these are plain prints on the ram console and NOT the capped `xnu_live_abt_*` RING
(cap 0x400), the launchctl fault IS captured even though the ring filled earlier with the shared-cache
fault (§5).

**3.1 The trap-side publisher** (`osfmk/arm/trap.c`, the usermode DATA-abort case's
`if ((code != KERN_SUCCESS) && (code != KERN_ABORTED))` arm, right after the `#if
BOARD_CONFIG_QSD8250_LEO` block — the LEO-only assignment that discards the value on CANCRO):
```
xnu_live_abt_vmfkrv=<code>          xnu_live_abt_vmfkrv_far=<dfar page-aligned>
xnu_live_abt_vmfkrv_dfsr=<dfsr>     xnu_live_abt_vmfkrv_prot=<read|write>
xnu_live_abt_vmfkrv_pc=<pc>         xnu_live_abt_vmfkrv_sp=<sp>     xnu_live_abt_vmfkrv_pid=<pid>
```
guarded `#if defined(STAGE90_XNU_USTACK_PROBE) && STAGE90_XNU_USTACK_PROBE`. The anchor is the LEO
assignment `leo_installd_fault_result=code;` — UNIQUE in the file. (NOTE: the `code = vm_fault(...)`
call appears TWICE, in the KERNEL case at :657 and the USER case at :829; the LEO pin disambiguates.)

**3.2 The stack-placement publisher** (`bsd/kern/kern_exec.c`, `create_unix_stack`, after the guard
`mach_vm_protect` block):
```
xnu_live_ustack_req=<load_result->user_stack>  xnu_live_ustack_size=<size>
xnu_live_ustack_fixed_addr=<addr>              xnu_live_ustack_rc=<kr from the FIXED call>
xnu_live_ustack_final=<p->user_stack>          xnu_live_ustack_prot_addr=<prot_addr>
xnu_live_ustack_prot_size=<prot_size>
```
(`xnu_live_ustack_rc=0` + no ANYWHERE fallback is the by-value confirmation of §1.) Behind the same
switch.

Both are POOL-side edits, staged by `tools/patch_d13_ustack_probe.py` +
`tools/stage_d13_ustack_probe.sh` (idempotent; `--verify-off` proves both arms with the real
preprocessor), and compiled by `tools/build_xnu_arm_kernel.sh`'s GLOBAL `DEFINES` from
`STAGE90_XNU_USTACK_PROBE` (the two spellings carry the SAME value, [[mi4-one-value-two-definitions]]).
The switch does NOT change the entry image's own bytes, so the record is its only carrier; the 1025
link-site clause (`build_entry.sh`) reads the two pool objects by `strings` for the publishers
(`xnu_live_abt_vmfkrv=` / `xnu_live_ustack_req=`) and refuses a record over a stale pool.

## 4. FALSIFIERS (what the 1025 press must read)

- **FAULT-NAMED** — the press prints `xnu_live_abt_vmfkrv_*` for `far=0x2bdbe000` with a
  `vm_fault` return that names the cause ⇒ the next rung fixes that cause. (This is the goal of
  1025.)
- **FAULT-NOT-RUN** — the press reaches launchctl but prints NO `xnu_live_abt_vmfkrv_*` ⇒ the
  abort is not this path (re-read: is the fault a PREFETCH abort? then instrument that arm too).
- **STACK-SHAPE** — `xnu_live_ustack_*` shows `rc=0` and `fallback=0` ⇒ confirms §2's by-value
  claim that the FIXED alloc succeeded (an independent check of records/1025-source-trace.txt).
- **REGRESSION** — the 1024 controls regress (the 1023 pthread storm returns, or
  `IOS7LAB trap24 frame` / `port_construct result=0` vanish) ⇒ the arm's switch set is wrong.

## 5. WHAT WAS RULED OUT (kept so 1026 does not re-walk it)

- **The collision / ANYWHERE-fallback mechanism** (v1 §2/§2.1) — FALSIFIED by value
  (records/1025-source-trace.txt §1: fresh child map; §3: 0x2BD00000 < window base 0x2C000000).
- **Code-signing rejection** — `cs_invalid_page(0x2f19e000)` printed "clearing CS_VALID"
  (kern_proc.c:2786-2798): with `CS_HARD`/`CS_KILL` clear, `retval = 0`, so the fault PROCEEDS.
  The code-signing fault is on the shared cache (`0x2f19e000`), not the stack (`0x2bdbe000`).
- **The shared-cache fault witness** (`xnu_live_abt_far=0x3adc6031`, `abt_pc=0x3b3d7fe4`) is a
  DIFFERENT event from the launchctl stack abort; the `xnu_live_abt_*` family in the capture is all
  for the shared-cache fault, and the ring capped at `n=0x400` before the launchctl abort. This is
  the structural reason 1025 needs a NON-ringed publisher (§3.1).
- **USB console** is not a reading path for a boot that reaches launchd and crashes (v1 §5).

## 6. FILE-LEVEL PLAN

- `tools/patch_d13_ustack_probe.py` + `tools/stage_d13_ustack_probe.sh` — stage the two publishers
  (trap.c + kern_exec.c) with anchor + done-mark; refuse a double-edit or a hand edit.
- `tools/build_xnu_arm_kernel.sh` — a `STAGE90_XNU_USTACK_PROBE` block in the global DEFINES array.
- `src/entry/build_entry.sh` — ENTRY_ARM_KEYS + the arm-key case + the record writer + the link-site
  by-value clause (the 1024 idiom: with the switch on, the linked image carries the publisher body;
  off ⇒ byte-identical).
- `scripts/preflight_boot_check.sh` — add the key to `ENTRY_CFG_KEYS` (+ `-z` grace branch).
- `tools/check_1025_capture.py` — read `xnu_live_abt_vmfkrv_*` + `xnu_live_ustack_*`; assert the
  positive controls (launchd reach, trap24 frames); `--selftest`.
- `scripts/build_1025.sh`, `scripts/press_1025.sh`, `scripts/park_1025.sh` — in the 1024 idiom:
  carry the previous arm's FULL switch set from `out/stage90/xnu_arm_entry-config.txt` (which
  already has `SHREG_GEOM=1`, `VM_MAX_SPLIT=1`, `GLOBAL_FIX=1`), ADD `STAGE90_XNU_USTACK_PROBE=1`.
- `records/1025-press-read.txt` — the reading.

### 6.2 Discipline (unchanged)

One switch; the reading is the by-value check on the linked image; the ram console / `last_kmsg` is
the capture; `fastboot boot` only, never flash; park + revert-set before the press
([[mi4-hardware-run-safety-gate]]). Probe-only ⇒ no new device hazard.

## 7. HONEST RISKS

- The launchctl abort may be a **PREFETCH** abort, not a data abort — the capture prints "data
  abort" and `fsr`/`dfsr` confirms, but if the 1025 press shows a prefetch abort at the same VA,
  §3.1 must cover the prefetch arm (trap.c:718-800) too. The design covers the data arm first
  because the capture names it.
- The failed fault may be **intermittent** (a race in the shared-region slide / TLB). If the 1025
  press does not reproduce the launchctl reach, read the capture's own boot markers to date it
  against the 1024 press before drawing any conclusion.
- `far` in the abort line is `dfar`; the abort may be a **write** (`dfsr & 0x800`). §3.1 publishes
  the prot so a write is distinguishable from a read.