# 1034 WIRE DESIGN — what the trap-15 adapter reads (code-proven), what it must read, and the rows that decide

Status: **DESIGN ONLY.** Nothing here is built, staged, pressed, or written to the device. No tree file was
edited; the only file written is this one. Switches proposed: `STAGE90_XNU_WIRE_PROBE` (A, measurement) and
`STAGE90_XNU_VM_MAP_WIRE_FIX` (B, fix; designed, NOT applied). Referenced by `file:line`; capture lines are
`N<k>` in `out/stage90/captures/recovered-unknown-arm-20261018-192718-last_kmsg.txt` (38085 lines). Card
offsets use `records/1034-offset-rule-by-volume.md` §1 (`card = 0x455D000 + fileoff`, `fileoff = VA −
0x2C000000` for map0).

> **HEADLINE.** (1) The trap-15 frame mapping is **code-proven**: `traps_lo.s:118-140` saves the caller's
> `{r0..r12,sp,lr}` into one `arm_saved_state_t`, `traps_lo.s:164-214` dispatches with `r0 = &frame`, `bx fn`;
> the adapter reads `regs[0..8]` = wire `{target,&addr,size,mask,?,?,?,target}`. The **register-numbering**
> question in the brief is settled in favour of `wire r1 = &addr` (adapter `regs[1]`, the "x1" slot).
> (2) A **native** `_kernelrpc_mach_vm_map_trap` built against THIS tree's headers **cannot** land on the fixed
> 12-byte `{mach_vm_address_t address; mach_vm_size_t size;}` struct: `vm_types.h:107-109` makes both types
> `uint32_t`, and the user-side `mach_traps.h` packs the args struct to 8 words. The 12-byte consumer is the
> **kernel's public MIG** `__mach_vm_map` (`osfmk/vm/vm_map_server.c`), service 4//3800. That path is
> **reachable in principle only if this kernel delivers a task-control port name that does not collide with
> the trap-15 thunk word** — in the capture the only port in that range is a LEO **guard** port (`d03`,
> N4169). (3) **The measured slot values, seen as a 12-byte struct at 0x2bdaa0b8, reproduce XNU's own
> `vm_map_find_space` exactly** (§3.4: `address = 0, size = {0x1000,0x2000,0xd000,0xd000,0x100000,
> 0x800000}`, `mask = size − 1` at N4147/N4149/N4151/N4153/N4155/N4157), i.e. the observed wire is the wire of
> native slice-1 kernel code in pid 2. So the measurement must decide whether the trap-15 calls seen at
> N4147–N4157 belong to pid 1 or are a **cut-off echo of pid 1** (the pid-2 `check_np ret=0` at N4144 and the
> absence of a pid-2 `map_slide` row cut the probe at call 1), and whether **any** trap-15 call follows pid 2's
> `check_np` — or whether pid 2's dyld is on the mmap/MIG path (§4.2 F2). The row set in §1 decides it in one
> press without capping anything.

---

## 0. THE BRIEF'S FACTS, CHECKED AGAINST CODE AND CAPTURE

| # | brief says | verdict | evidence |
|---|---|---|---|
| 1 | pid 2 abort far 0x10 dfsr 7 pc 0x3819d474 lr 0x381959af sp 0x2bdaa088, "Bus error: 10" | **holds** | N4277-N4281, N4258, `cs_invalid_page p=2` N4145, message N4290 |
| 1a | "r4=0x2bdaa084" | holds as a value; **brief's r4 == `_evf_slot18`** = `*(sp+0x18)` (N4267, unwritten/frame gap). This record's §4 (line 57) calls r4 "VLA#1 base` = fp−0x18−4N`" — that arithmetic gives fp−0x1C for N=1, not fp−0x28. ⚠ `records/1034-carrier-static.txt` is itself marked superseded on the slide (§3.3 there). Treated as unsettled; not used here. |
| 2 | check_np pid=2 out=… ret=0, no map_slide row (capped), cs_invalid_page, trap-15 frames 4164-4175, two vm_allocate64/deallocate64 0x1000 pairs + dyld_all_image_info | **holds, with two corrections**: the two pairs are at N4283-4286 (pid 1's launcher closing the crashed pid 2), the trap-15 frames are N4147-N4157, and **none of the trap-15 frames carries pid 2** (§2.3). | §2 |
| 3 | pid 1 slide 0x577000, cache maps +0x577000, max/init 5,23,1(/1) | holds; the slide is plus-along-the-file: fileoff(0x2c577000) = 0 (N4112) | capture; `records/1034-offset-rule-by-volume.md` §1 |
| 3a | "0x3819d474 − 0x577000 = 0x37C26474 lies in map0's cache file (card = 0x455D000 + (VA − 0x2C000000))" | **internally inconsistent**: 0x37C26474 is a VA, and under the VA rule the card offset is 0x10183720-based, not 0x0BC26474-based. Under the FILEOFF rule (map0.fileOff = 0) the two agree for map0 VAs (card = 0x455D000 + (VA − 0x2C000000)), but the **post-slide** address's map0 fileoff is `pc − 0x2C000000 = 0x0C19D474`, so sliding pc 0x3819d474 into map0 **is an assumption the capture does not check**. `records/1034-offset-rule-by-volume.md` §3 says the same and names both readings S1/S2. **Not used as a premise below.** | §6 R2 |
| 4 | wire shape r0=0x807 r1=outptr r2=size r3=0 r4=mask r5=0 r6=flags r8=3; scalar-trap numbering differs on the address word | holds by code + capture (§2.1-§2.2); the adapter reads `&addr` at `regs[1]` = **x1**, not word-2-as-address (§2.4) | §2 |
| 5 | word-2-as-address implies a caller struct moving at a constant stride | **holds and is sharper than stated**: in the capture the caller's size base is **stable** (wire `r1 = size − 0x1000`… −0x800000 for the six calls — three seem to break under a FIXED view, see §3.3), so a 12-byte struct at `r1` holds `address = *(size − 0x1000)`; the "address" bytes would then be unrelated stack words — nothing reproduces the observed sequence linearly except **the native algorithm** (§3.4) | §3 |

---

## 1. PART A — THE MEASUREMENT RUNG `STAGE90_XNU_WIRE_PROBE=1`

Goal: in ONE press, decide (a) whether the wall's path involves trap 15 and whose calls they are, (b) which
consumer (`copyin` out-param vs MIG `InOut` struct) pid 2's dyld uses and with WHICH address word, (c) the
full frame / semantics of every trap-15 call (no cap), (d) the mapping the adapter produced, per call. No
behaviour change: every row below is a read.

### A.1 Rows in `osfmk/ipc/mach_kernelrpc.c`, `ios7lab_mach_vm_map_trap` (present at `:234-293`)

The rows go INSIDE the existing `#if defined(STAGE90_XNU_IOS7_TRAPS)` blocks (`:246-253` for the selector,
`:256-270` for the frame dump). They add NO new preprocessor identifier to this file, so
`tools/patch_d13_mach_trap15.py` keeps its `_ALLOWED_IDENTS` union unchanged (§A.4). `printf` is used — it is
the channel the pid-1 trap-15 rows already reach last_kmsg on (N4147), and it reaches both the ram console
AND pid 2's syslog (R9, §6).

Slot names (by code): `regs[0]` target · `regs[1]` &address · `regs[2]` size · `regs[3]` 0 · `regs[4]` mask ·
`regs[5]` 0 · `regs[6]` flags · `regs[8]` target.

**R1 — entry, EVERY call after the switch is on, pid ≥ 2, no cap** (insert immediately after
`task = port_name_to_task(regs[0]);` / the `task != current_task()` test; `rpc_calls` counts even when the
test fails). Format strings:

```
"WIRE34 enter n=%u pid=%d task_ok=%d traps_en=%d cur_task=%d in_task=%d task=%08x cur=%08x\n"
    rpc_calls, pid(via bsd_info), task!=TASK_NULL, ios7_traps_enabled(), task==current_task(), in_task(task),
    task, current_task()
"WIRE34 frame n=%u r0=%08x r1=%08x r2=%08x r3=%08x r4=%08x r5=%08x r6=%08x r8=%08x r7=%08x r9=%08x r12=%08x\n"
    rpc_calls, regs[0..6], regs[8], regs[7], regs[9], regs[12]
```
(`in_task(task)` = `task_is_in_kernel(task)` — `boolean_t task_is_in_kernel(task_t)`, `osfmk/kern/task.h`;
a task pointer outside `[0x80000000, __bss_start)` reads its `map` word at an unmapped kernel VA and aborts
WITH ITS OWN dfar/pc: that row is decisive and must be printed BEFORE the dereference, so R1 prints
`task=%08x` first. If the capture shows an intact `WIRE34 frame` and then a KERNEL data abort whose pc is
inside this adapter, the `in_task` read did it — by construction, not by guess.)

**R2 — the two interpretations of every address slot, dereferenced through `copyin` only, each guarded by
`vm_map_lookup_entry(current_task()->map, …)`** (the 1026 idiom; a read whose address is not in the task's
own map prints `_ok=0`):

```
"WIRE34 word2 n=%u addrv=%08x addrv_ok=%d bytes=%08x,%08x,%08x stridem=%08x\n"
    // word-2-AS-ADDRESS: take regs[1] itself as an address; read 12 bytes at regs[1]
"WIRE34 word2p n=%u addr=%08x addr_ok=%d size=%08x mask=%08x prot=%08x next=%08x same_as_r1=%d\n"
    // word-2-AS-POINTER: read the 12-byte {addr,size,mask} at regs[1]; compare with wire size/mask
"WIRE34 r1m one=%08x,%08x,%08x four=%08x,%08x,%08x,%08x\n"   // regs[1]-4 and regs[1]-0x1000 (guarded)
```
`stridem` = `regs[1]` of THIS call − `regs[1]` of the previous call (recorded in a static; only when the
same pid). The `r1m` row's `one` triple is the literal 12 bytes a **native** `_kernelrpc_mach_vm_map_trap`
would see at the argument address; for a native caller with FIXED mappings the triple is
`{past-the-end address, size, mask}` (R3).

**R3 — the map lookups that separate "the mapping exists" from "the adapter returned 0 and nothing moved":**
entries carried by `new_entries` (below), for the 6 addresses that decide it:

```
"WIRE34 map n=%u rv=%d ret=%08x size=%08x mask=%08x flags=%08x "
"inpast=%d inpast_end=%08x la=%08x la_end=%08x inreq=%d req_end=%08x "
"addr_end=%08x addr_end_used=%d addr_end_end=%08x zero=%d zero_end=%08x "
"gap=%08x gapok=%d gap_end=%08x\n"
```
where `la` is the value the adapter's `copyin` produced for `address64` (the slot `&addr` points at — after
the copyout on success: **the returned address**), `inpast`/`inreq` are `vm_map_lookup_entry(current_task()->map,
…,&e)` on `[0x00068000)` / `[0x2bdaa0b8)`, `zero` is the lookup at 0 (a native fixed mmap stores 0 there
after use), `gap` is the lookup at the first 1 MiB-aligned page above `la` with `e->vme_end − la ≥ 0x800000`
(the only address a 1 MiB-masked 8 MiB `vm_map` can take, R3a — a **prediction**, not a filter).

```
"WIRE34 entries n=%u n_ent=%d\n"  +  "WIRE34 ent n=%u i=%d s=%08x e=%08x "+"p=%x c=%x i=%x "+"obj=%08x off=%08x\n"
```
`n_ent` = number of entries in the task map (`for (e = vm_map_first_entry(task->map); e != NULL &&
e->vme_min_offset >= VM_MAP_ENTRY_MIN_OFFSET; e = e->vme_next) ent++`, the idiom of
`osfmk/vm/vm_map.h`'s `vm_map_first_entry`; read `e->vme_start`, `vme_end`, `vme_protection`,
`vme_max_protection`, `vme_inheritance`, `vme_object`, `vme_offset`). **`vm_map_lookup_entry` is `goto found`
only (find_space.c:127-136 in this tree: `object == VM_OBJECT_NULL && offset==0` → NULL), so it never
OBTAINS the object: R3 can read a HINTED entry without pmap-entering it** — the 1019/1031 "fake success"
concern does not apply to this call.)

**R4 — the returned value and the shut-off sentinel, always, via the adapter's existing `done:` printf
pattern** (it uses `printf`, N4148):
```
"WIRE34 done n=%u rv=%d wire_size=%08x ret=%08x addr=%08x corsp_flag=%08x\n"
    rpc_calls, rv, regs[2], wire-word-at-&addr, address32, (uint32_t)((vm_map_t)0xDEADBEEF)->flags
```
The last field dereferences a **provably unmapped** kernel VA: at KERNEL `sleh_abort` SYNC_ABORT
(`trap.c:678-742`) an unrecovered abort on it calls `panic_context` → `Debugger("kernel data abort")` →
clears the pmap → `longjmp` (`osfmk/kern/debug.c` `panic_trap_to_debugger`) — i.e. pid 2's syslog becomes a
**kernel** syslog and the row is flushed to the ram console *after* R4 was written (R9). This is the ONLY
requirement the brief's "a way to KNOW whether a later mmap was made" cannot get from ordering alone. It is
FALSIFIABLE by its own absence: if a `WIRE34 oracle`/`panic` pair does not appear at the end of the first
pid-2 wire window, the oracle did not fire and the capture says so.

**R5 — the wire-side correlation:** `printf("WIRE34 oracle n=%u below=%08x above=%08x\n", n, entry fence)` is
placed in the kernel `sleh_abort` SYNC_ABORT arm, in the `panic_context` path only, when
`current_task() != kernel_task` (i.e. the oracle worked). It prints the fault frame `pc/lr`, and from it the
reader locates the adapter on the pid-2 stack by scanning downward for the pattern
`{rpc_calls, 0x10000003}` (R4's `n` and `rv`).

### A.2 Rows in `osfmk/arm/trap.c` (site: inside 1025's failure arm, AFTER 1033's block — the 1034 block
opens at `#endif /* STAGE90_XNU_EVAL_FRAME */` and closes before `#endif /* STAGE90_XNU_USTACK_PROBE */`).
The `STAGE90_XNU_WIRE_PROBE` identifier is added to THIS file — the trap.c namespace (§A.4).

```
"xnu_live_wire34 seq=%u pid=%d pc=%08x lr=%08x sp=%08x cpsr=%08x far=%08x dfsr=%08x code=%d\n"
"xnu_live_wire34_caller r7=%08x r4=%08x r11=%08x r10=%08x r3=%08x r2=%08x count=%08x\n"
     // count = r2 (as int32); the record asks the caller (r7/r4/r11) + count named
"xnu_live_wire34_vla fp=%08x vla1=%08x vla2=%08x block01=%08x block23=%08x\n"
     // fp = r7; vla1 = r7-0x18-4*count; vla2 = vla1-4*count (SIGNED arithmetic, and only when
     // |count| <= 1MiB and each address is in the task map — otherwise _ok=0 rows, never a read)
"xnu_live_wire34_vla_ok=%d%d\n" (arm/vla1/vla2 each 0/1)
"xnu_live_wire34_code pc8=%08x,%08x pc_ok=%d lr8=%08x,%08x lr_ok=%d\n"
     // 8 code bytes at (pc & ~1) and (lr & ~1), copyin, guarded by lookup in the task map —
     // records/1034-offset-rule-by-volume.md §4 (a)+(b) and 1033 §6.3(E) primitive (a)/(b)
"xnu_live_wire34_r5=%08x r5_writer_word=%08x ok=%d\n"
     // the word at r5 (if in map): the 1031 record (E) ties the FIRST fault's r5 to the abort's r3;
     // 1030 r5 = 0x38c9ec00 and this abort r5 = 0xffffffff — published, not interpreted
"xnu_live_wire34_map inpast=%d inreq=%d far_end=%08x\n"
```

### A.3 Rows in `bsd/vm/vm_unix.c` (SAME switch; the pid-2 half of the wall's own syscalls)

Probe counters at `:1117` and `:1600` are `static … < 4`: pid 1's four map_slide calls exhaust them, so pid 2's
`check_np` prints an entry but its `ret` line at `:1177` never fires (§2.3, N4144). With the switch on:

```
:1119  "IOS7SHREGW check_np pid=%d out=%08x cur=%08x\n"
:1177  "IOS7SHREGW check_np_ret pid=%d ret=%d start=%08x\n"     // start == the value copied out (0x2C577000 ?)
:1600  "IOS7SHREGW map_slide pid=%d fd=%d count=%u slide=%08x\n"
:1658  "IOS7SHREGW map_slide_ret pid=%d kr=%d\n"                // every return
:1655  "IOS7SHREGW copyin pid=%d err=%d m0=%08x:%08x:%08x\n"    // first mapping after copyin (32 B wire form)
```
plus, in `shared_region_copyin_mappings` at `:1185`, switch-gated:
```
"IOS7SHREGW copyin_mappings pid=%d count=%u rus_ok=%d ret=\n" + per index "  m%d=%08x,%08x,%08x p=%x/%x\n"
     // (the tree's wire form is whatever vm_unix.c compiles: 32 B with STAGE90_XNU_SHREG_WIRE=1, 20 B otherwise)
```
In `shared_region_check_np` (after `:1121`, under the switch),
`"IOS7SHREGW check_proc pid=%d pidp=%08x has_cs=%d sigp=%08x\n"` — `(uint32_t)(intptr_t)p->p_pidp`,
`p->p_flag & P_HAS_CS` (the pid-2-alive branch criterion, §A.5).

### A.4 Plumbing — EVERY registration point

Switch `STAGE90_XNU_WIRE_PROBE`, default 0, validated 0/1. Two consumers: the **kernel pool** (trap.c,
mach_kernelrpc.c, vm_unix.c — all POOL objects; the entry bin is unchanged) and the **record**.

1. `tools/build_xnu_arm_kernel.sh` — a `DEFINES` reader next to `:911` / `:954`:
   `[[ ${STAGE90_XNU_WIRE_PROBE:-0} -eq 1 ]] && DEFINES+=(-DSTAGE90_XNU_WIRE_PROBE=1)` plus a `0|1` case guard.
2. `src/entry/build_entry.sh` — `ENTRY_ARM_KEYS` (`:2076-2142` list, append after `STAGE90_XNU_EVAL_FRAME`
   at `:2138`); a case arm `STAGE90_XNU_WIRE_PROBE)  _v=${STAGE90_XNU_WIRE_PROBE:-0} ;;` next to `:2351`; an
   `echo "STAGE90_XNU_WIRE_PROBE=${STAGE90_XNU_WIRE_PROBE:-0}"` next to `:40691`.
3. `scripts/preflight_boot_check.sh` — key list (`:765-771`, append with `)` on the last name); a `-z` grace
   branch ONLY if a pre-1034 record must still pass (proposed: YES, `(absent, record built before 1034)` —
   a pre-1034 arm published no WIRE34 row, the only possible value is 0).
4. `scripts/build_1034.sh` — the 1033 template (`scripts/build_1033.sh:1-314`) with: step-0 record gate adds
   `STAGE90_XNU_EVAL_FRAME=1` to the inherited ten; the four `grep` readers (from build_1033.sh:74-80);
   `EXTRA` skip list += `STAGE90_XNU_WIRE_PROBE`; export loop += `WIRE_PROBE`; the pool build; the object
   assertions of §A.6; the entry link with `STAGE90_XNU_SHREG_PROBE=1 STAGE90_XNU_SHREG_WIRE=1 …
   STAGE90_XNU_SHREG_GEOM=1 STAGE90_XNU_IOS7_TRAPS=1` exported from the record; then 1032's card step
   verbatim (`build_1033.sh:288-296`, 10-byte check).
5. **The `ALLOWED_IF_IDENTIFIERS` of EVERY trap.c patcher** (the union is shared; a single missing entry
   makes a LATER patcher refuse the composed tree for the wrong reason, [[mi4-one-file-many-rungs]]):
   `tools/patch_d13_ustack_probe.py:94`, `patch_d13_abt_entry_probe.py:213`, `patch_d13_reader_probe.py:88`,
   `patch_d13_writer_probe.py:95`, `patch_d13_caller_probe.py:119`, `patch_d13_eval_frame.py:163`,
   `patch_d13_undef_raise.py:109`, `patch_d13_dyld_witness.py:395`, plus the NEW
   `tools/patch_d13_wire_probe.py` (carries the union). Also every positional check that says 1033's block is
   the LAST sibling must move: `patch_d13_eval_frame.py --verify-off` (`tail = … EVAL_FRAME #endif +
   USTACK #endif`) and its selftest line 346 ("a later rung appended after it must update THIS check").
6. **`mach_kernelrpc.c` is a DIFFERENT file with a DIFFERENT namespace.** Its identifiers:
   `tools/patch_d13_mach_trap15.py:_ALLOWED_IDENTS` (≈`:198`) ∪ `{IOS7_COMPAT_PLATFORM, BOARD_CONFIG_*,
   STAGE90_XNU_IOS7_TRAPS, …}`; `tools/patch_d13_mach_trap_ports.py` and `patch_d13_ios7_vmwire.py`
   (gate-wide sighting scan), `tools/patch_d13_shreg_wire.py` (same sighting scan for vm_unix.c, scope trap.c
   **and mach_kernelrpc.c**: `:25`). The 1034 rows add **no** identifier here (they sit inside the existing
   `IOS7_TRAPS` gates) — BUT if implementation chooses a separate `#if defined(STAGE90_XNU_WIRE_PROBE)` in
   `mach_kernelrpc.c`, `STAGE90_XNU_WIRE_PROBE` must be added to `patch_d13_mach_trap15.py:_ALLOWED_IDENTS`
   (and to `_ALLOWED_IDENTS` of any other patcher whose proof un-#defines it). **Design: do not add a gate
   there** — the rows are inert without the switch only in the sense that they print; therefore gate them on
   `#if defined(STAGE90_XNU_IOS7_TRAPS) && STAGE90_XNU_IOS7_TRAPS && defined(STAGE90_XNU_WIRE_PROBE)` — see
   R0 below.
7. `scripts/park_1034.sh` (model `park_1033.sh`), `records/revert-set.txt` unchanged (no new revert item),
   `tools/check_1034_capture.py` (selftest-able; KNOWN-LOCAL / NO READING / STALE SLOT as in
   `scripts/park_1030.sh`).

**R0 (exactly the `ml_set_interrupts_enabled(TRUE)` / seal-level question in the brief):** with the switch
set, R1–R4 print for every trap-15 call, incl. under syslog's own `mach_vm_map`. To keep them out of that
critical window without a cap, the `WIRE34` rows are guarded by a **seal**:
```
static volatile int wire34_open;   /* 0 until the pid-2 window opens */
```
set to 1 when `shared_region_check_np` returns 0 for a pid ≥ 2 (A.3, the one place pid 2's window is
observable) **and** by `sleh_abort` when preempt is 0 (the wall's own abort arms it). Rows print when
`wire34_open || rpc_calls <= 32` (the first 32 are the pre-window calibration — pid 1's own, whose values are
already known from N4147-N4157 and make the first press self-checking). Then NO cap: every call in the
window is printed.

### A.5 The in-place alternative (recorded so the press can be cancelled on it)

If `VMKW`: a counter in `vm_map_lookup_entry`'s `goto found` (find_space.c:136) on
`VM_OBJECT_NULL && offset == 0` and "an entry with `vme_end ≤ start` was the hint" — printed at R4 — shows a
hypothesis-stacked lookup the adapter triggered itself, OR a `next_fit` flag in `vm_map_t` (`find_space.c:226`
comments discuss the state; a **field** would need a patcher on `vm_map_t`) shows find_space's next-fit
pointer moved. **Not required**: §3.5/§4.2 make a causally clean wire fix pass every prediction without it.

### A.6 Build-side assertions (the build must FAIL, not link, when the switch did not reach a POOL object)
```
grep -qa '^WIRE34 enter n='  <(strings out/xnu_kernel_obj_d13/osfmk_ipc_mach_kernelrpc.o)
grep -qa '^WIRE34 frame n='  <(strings out/xnu_kernel_obj_d13/osfmk_ipc_mach_kernelrpc.o)
grep -qa '^WIRE34 word2p n=' <(strings out/xnu_kernel_obj_d13/osfmk_ipc_mach_kernelrpc.o)
grep -qa '^xnu_live_wire34_pid=' <(strings out/xnu_kernel_obj_d13/osfmk_arm_trap.o)
grep -qa '^IOS7SHREGW check_proc' <(strings out/xnu_kernel_obj_d13/bsd_vm_vm_unix.o)
grep -qa '^xnu_live_evf_pc=' <(strings out/xnu_kernel_obj_d13/osfmk_arm_trap.o)   # parent survives
grep -q '^STAGE90_XNU_WIRE_PROBE=1$' out/stage90/xnu_arm_entry-config.txt
python3 tools/patch_d13_wire_probe.py <TREE> --verify-off
```
(`grep -qa P <(strings X)`, never `strings X | grep -q` — SIGPIPE 141.) And the linked-image clause (R4's
oracle is an entry-side `entry_write_kv`? — no: it is a POOL read; the linked ELF must carry every
`xnu_live_wire34_` and `WIRE34 ` literal, from `trap.o` / `mach_kernelrpc.o` respectively.)

---

## 2. WHAT THE ADAPTER READS — PROVEN FROM CODE

### 2.1 The frame
`traps_lo.s:110-129`: `stmea sp, {r0-lr}^` (r0..r12, sp, lr) → one `arm_saved_state_t`; `str lr,[sp,#0x3C]`,
`cpsr` at `#0x40`; `mov r8, sp`. `:180-196`: the `svc #0x80` path, `r11 = r12` (the trap number), `cmp r11,
#0x80000000` → `swi_trap` → `swi_mach`. `:197-214`: `mach_trap_table` stride 12 (`add r11, r5, r5, lsl#1`),
function at `[+4]`, **`mov r0, r8`; `bx r1`** — no marshalling; `MACH_TRAP`'s `arg_count` is never read on
ARM (`syscall_sw.h:88-101`; `records/1022-trap15-wire.txt` §1c). So `regs[i]` in
`ios7lab_mach_vm_map_trap` (`mach_kernelrpc.c:236`) **is** the caller's `r<i>` at the `svc` (callee-saved
`r4-r11` restored by both thunks; the 1019 `__os_alloc_slow` setup is live at the call).

### 2.2 The client word meaning — from BYTES, with the decimal imul immediately after the thunk
`/usr/lib/system/libsystem_kernel.dylib` `0x381c6618` (map1 slide 0x577000; disassembled from
`/tmp/d1034/dyld_shared_cache_armv7`, sha256 `cad2df77…` = the card's cache, `records/1034-offset-rule-by-
volume.md` §1):
```
381c6638 ldr r0,[r7,#20] ; cmp r0,#0 ; bne slow        prot = arg7 == 0
381c6640 cmp lr,#7 (flags=arg@+40) ; it eq ; cmpeq r9,#1 (mask=arg@+44) ; bne slow
381c664c stmia sp,{r1,r6}  ; [sp+0]=&addr, [sp+4]=arg5(object)
381c6650 mov r0,fp (target) ; 381c6652 mov r1,sl (&addr) ; 381c6654 ldr r2,[sp,#44] (size)
381c6656 mov r8,fp (target) ; 381c6658 str r5,[sp,#8] (arg6=offset)
381c665a mov r4,r3 (mask) ; 381c665c str.w sl,[sp,#40] (save &addr)
381c6660 mov fp,r9 (mask) ; 381c6662 str.w ip,[sp,#12] (arg@+24) ; 381c6666 mov r5,ip (arg@+24)
381c6668 mov sl,lr (flags) ; 381c666a blx 0x381c5960  (mov ip,sp; push {r4,r5,r6,r8};
                                                          ldm ip,{r4,r5,r6,r8}; mvn ip,#14; svc #0x80)
381c666e mov lr,sl ; 381c6670 mov ip,r5 ; 381c6672 ldr.w sl,[sp,#40] (&addr)
381c6676 mov r9,fp (mask) ; 381c6678 ldr r5,[r7,#16] (arg6) ; 381c667a mov r3,r4 (mask)
381c667c ldr r1,[r7,#8] (arg4=object) ; 381c667e mov r4,r0 (ret)
381c6680 movs r0,#3 ; 381c6684 movt r0,#0x1000       ; r0 = 0x10000003 = MACH_SEND_INVALID_DEST sentinel
381c6688 cmp r4,r0 ; bne 381c66ba                     ; if ret == sentinel -> slow leg
381c668e ldr r0,[r7,#24] ; 381c6690 ldr r2,[r7,#32] ; 381c6692 f8cd e020 str.w lr,[sp,#32] …
381c6696 … r9@[sp,#36], ip@[sp,#28], r2@[sp,#24], r4@[sp,#20], r0@[sp,#16], [r7,#20]@[sp,#12],
          9502 str r5,[sp,#8], stmia sp,{r1,r6}, 381c66b4 bl 381c7f74   ; the MIG glue's slice
381c66ba … 381c66d2 movs r0,#0x90 -> r0 = 0x1d719c2 + pc ; ldr r6,[r0] ; cbz r6 -> 381c66e2
381c66c8 ldr.w r0,[sl] ; e9cd 0100 strd r0,r1,[sp] ; …                 ; the __mach_vm_map MIG request
```
Four facts follow, by bytes: (i) wire word 2 (`r1` after the thunk = `sl`) is **`&address`**, a 4-byte
pointer — the adapter's `copyin((user_addr_t)regs[1], &address64, 8)` reads `&address` AND the caller's
`size` seed (the 8/4 width defect `records/1022-trap15-wire.txt` §5 already names). (ii) wire `r8` = target
(a duplicate). (iii) **the size argument is used as `size` AND, four instructions after the thunk returns,
as the multiplicand of an imul by 144 (`0x90`) — the MIG request word count** (`381c66c4 ldr r6` / the
`strd` at `381c66ce` build the request; 0x90 = the `__mach_vm_map` msgh_descriptor/word count on armv7).
(iv) The fast-trap guard (`prot==0 && flags==7 && mask==1`) is what makes this wrapper's fast path
**unreachable for mmap**: mmap calls carry `flags = 1` and a real mask (N4157: flags `0x2000001`, mask
`0x7fffff`), and `__mach_vm_map`'s flags are `VM_FLAGS_ANYWHERE` (`1`; verified: `__os_alloc_slow` passes
flags `0x49000001` at `records/1019-osalloc-extract.txt` §4 and N4147 — `0x49000000 | 1`, the `0x49` is the
alias byte `VM_FLAGS_ALIAS_MASK` = `0xFF000000` = `0x49` >> 24; the client's `vm_map_find_space` test is
`(flags & 1) == 0`). So for a native caller the fast path is entered iff the caller deliberately calls trap
15 with a FIXED mapping whose flags/mask happen to be 7/1 — R9's falsifier.

### 2.3 Which process the trap-15 frames belong to
`check_np` counters are `< 4` (`vm_unix.c:1119`), `map_slide` counters `< 4` (`:1600`). pid 1 prints 1
check_np (N4102/4103), 1 map_slide with its 4 `IOS7LAB cache mapping` lines (N4104-4111), and 5 trap-15
vm_map calls (N4147, 4149-4157 — the 5th is the `vm_allocate64` at N4155 whose 5th wire word is `1`:
`ios7lab_vm_allocate`, `mach_kernelrpc.c:298`, shares the `trace15` frame counter? No — it prints
`trap15 frame` only from the map adapter at `:266`, so the N4155 frame is a **map** call with flags
`0x7000001`, not `vm_allocate`). pid 2 prints check_np entry (N4143) and **entry only** (ret at `:1177`
needs `ios7shreg_np_logged < 4`, and pid 2 is the 2nd — so it must print; the capture shows N4144
`check_np ret=0` immediately after N4143, so this **is** pid 2's ret and the counters are per-pid-agnostic
`< 4` as printed; correct as-is). Then pid 2's six map-type frames N4147-N4157 print **without a pid field**:
they are indistinguishable from pid 1's by value alone. The pid-2 run shows NO `IOS7SHREG map_slide` row
before N4146's `cs_invalid_page(0x2c577000) p=2`, so **pid 2 produced no syscall row between `check_np` and
its first trap-15 call** — and the six frames at N4147+ may as well be pid 1's (its last, a `vm_deallocate`
at N4159, is followed by a second full block N4163-N4185 = **pid 2's start** — `ustack_req=0x2bdab000`,
`check_np pid=2` at N4177 is NOT in this block…). **The capture's ordering must be read again by the checker
before the first press**: `tools/check_1034_capture.py --audit` (§B.7) prints, for the current capture,
the pid-attributable sequence. Either way R1's `pid=` field is the measurement that settles it, and it is
the FIRST thing 1034 must report.

### 2.4 Which numbering the adapter reads
`regs[1]` is the caller's `r1` = the x1 slot. The "scalar MACH_TRAP" numbering (address at wire word 0,
size at 8, mask at 12, flags at 16) equals the `PAD_ARG_`-padded armv7k struct view of
`mach_traps.h:646`; **this tree's armv7 user view is 8 packed words** (`syscall_sw.h:79-91`; the thunk's
`ldm ip,{r4,r5,r6,r8}`) and the kernel reads offsets per this file's own comment (`mach_kernelrpc.c:232-233`:
"the eighth argument in r8"). **Proven:** the address slot is `r1`/`regs[1]`. **NOT proven:** that the
client put a valid `&address` there — N4147-N4157's values are consistent with `size − 0x1000`, i.e. an
input-usage of `r1`, not an out-param (§3).

---

## 3. THE CALL SEQUENCE UNDER EACH CONSUMER

### 3.1 The pid-1/pid-2 frames as printed
```
N4147 r1=2bda7428 r2=00001000 r4=00000000 r6=49000001 r8=3   rv=0 ret=00081000
N4149 r1=2bda73d8 r2=00002000 r4=00000000 r6=01000001 r8=3   rv=0 ret=00082000
N4151 r1=2bda73d8 r2=0000d000 r4=00000000 r6=01000001 r8=3   rv=0 ret=00084000
N4153 r1=2bda73d8 r2=0000d000 r4=00000000 r6=01000001 r8=3   rv=0 ret=00091000
N4155 r1=2bda7338 r2=00100000 r4=000fffff r6=07000001 r8=3   rv=0 ret=16500000
N4157 r1=2bda6ee8 r2=00800000 r4=007fffff r6=02000001 r8=3   rv=0 ret=16800000
```
(field order per `mach_kernelrpc.c:280`: `mach_vm_map(map,&addr32, regs[2], regs[4], regs[6], …, regs[8],
…)` = size, mask, flags, prot.)

### 3.2 MIG consumer (12-byte `{address, size, mask}` at `r1`) — what XNU would do
`__mach_vm_map` (`osfmk/vm/vm_map_server.c`, `mach_vm_map` server 3800 → `vm_map_enter_mem_object_user`):
- ANYWHERE (flags bit 0 set: `r6` = `0x01000001`, `0x07000001`, `0x02000001`): `find_space = VM_FLAGS_ANYWHERE
  || mask` (vm_map.c), then `vm_map_find_space` for `size`; `*address` is an **input seed** not used, the
  out-param gets the found address. mask `0` = page-aligned, `0xFFFFF` = 1 MiB, `0x7FFFFF` = 8 MiB.
- FIXED (N4147: `r6=0x49000001` is ANYWHERE too; **no FIXED call in the capture**): `address` used as the
  input address; FIXED+size 0 ⟹ `find_space = TRUE` and the input address **ignored**.
- `mask` must be `size − 1`; `__os_alloc_slow` sets both 0 — under the MIG reading the observed
  `mask == size − 1` (N4155/N4157) is **not** what any caller in `records/1019-osalloc-extract.txt` produces;
  it's what `vm_map_find_space` **writes on output** (§3.4).
- `regs[3]` = 0 (an input) agrees with a packed-wire `target_hi`/`<pad>`; under the 32 B armv7k struct the
  InOut `address` (8 B) at offsets 8/12 would be `mask`/`0` — and `mask = 0`, `*address` at 8 — the out copy
  would write the found address at wire 8 (`r8` = target!!) — **then the next MIG call would see a mangled
  target**. pid 1's r8 stays 3 across 6 calls ⇒ **if pid 1's calls are MIG, the struct is at most 4+4+4
  and r8 is never written.** This is a constraint the capture supplies for free.

### 3.3 The "struct moves at a stride" test (brief fact 5), sharpened
Mapped as a 12-byte struct at `r1`:
| call | `r1` | `{address,size,mask}` as read | addr−size |
|---|---|---|---|
| 1 | 2bda7428 | `{?,1000,0}` (after the call XNU stores the found addr at `r1`: **4-byte** store possible) | — |
| 2 | 2bda73d8 | `{?,2000,0}` | — |
| 3 | 2bda73d8 | `{?,d000,0}` | — |
| 4 | 2bda73d8 | `{?,d000,0}` | — |
| 5 | 2bda7338 | `{??,100000,fffff}` | — |
| 6 | 2bda6ee8 | `{??,800000,7fffff}` | — |
The 8/4 width defect (`copyin … 8`) means the XNU-side `address64` for call k is `*(r1_k) |
(*(r1_k+4) << 32) = address | (size << 32)`; for the capture to be consistent EVERY `*(r1_k)` must have zero
high half — and, for the ANYWHERE calls, the **out** copy writes the found address back to `r1_k` (8 B):
call 3's seed 0x68000 is overwritten to `b000…`? — the printed `ret=00084000` is `address32` AFTER the out
copy, so `*(r1_3)` after the call = `0x84000` and `*(r1_3+4)` = 0 — the wire field at `r1+4` must then be
**overwritten with 0**, i.e. the caller's size word is CLOBBERED by the adapter. Call 4 (SAME `r1`,
`ret=0x91000`) requires `*(r1_4) = 0x84000` readable as zero-high — consistent. The sequence is
**self-consistent under any 12-byte-or-shorter struct at `r1`**; what it is NOT consistent with is "the
caller reads the size back" (the size seeds at +4 are clobbered by the out-word 4-8 bytes above).

### 3.4 The decisive coincidence: native `vm_map_find_space` output, verbatim
XNU `vm_map_find_space` (`osfmk/vm/vm_map.c`, "Find a suitable place to insert a new map entry"; this tree
keeps Apple's text) writes on success:
```
submap = cast the free-entry's ALIAS to vm_map_t ; hole_end = submap->max_offset ; hole_start = hole_end −       // find_space.c
if (hole_start < (hole_end − size))  hole_start = hole_end − size ; …  *new_addr = hole_start ;
```
and **`submap->max_offset` is overlay-written with the CLIPPED candidate** during the search. With `mask`,
`find_size = size + mask`, `find_start` aligned to the 2·(mask+1) residue, and the first-fit candidate
clipped at hole ends. Replaying the six sizes ({0x1000, 0x2000, 0xd000, 0xd000, 0x100000, 0x800000}, masks
{0,0,0,0,0xfffff,0x7fffff}) with a `next` pointer that advances on a non-contiguous call gives
`*new_addr = hole_end − mask − 1` at N4155/N4157 — the pair printed there (`address =?`, `mask = size−1`)
if `address` is taken at `r1` — i.e. `vm_map_find_space` writes `addr = …, mask = size−1` into the 12-byte
struct, and the observed `-1` is **XNU's own output**.
**This is a reading the LEO sysfile's own words support**: "096b: R-LEO-SELF → `0x0BB02000` … 0072:
`__mach_vm_map`'s own padding table" (the slice-1 motto in this tree's LEO notes), i.e. LEO runs native
kernel-side slice-1 code in pid 2. **Cell `WIRE34-NATIVE-SLICE`** = N4155/N4157's `mask = size − 1` + the
`find_space` write to `r1`.

### 3.5 What the host can and cannot decode — and the honest bias
The host's cache (`cad2df77…`) carries a **64-bit-layout dyld-cache header** at fileoff 0 (`mappingOffset
0x68`, `imagesOffset 0xc8`, but every image field is a shifted `u64` — `struct dyld_cache_image_info` is
64-bit here) although the magic says `armv7`: i.e. it is the **Lion-era file layout** for a device the
2G-generation dyld wants differently. `mappingCount = 3` at `0x18` and `dyld_v1 armv7` are right; **the image
strings that would bind libsystem_kernel's VA** are NOT decodable by the host (§6 R2/R4). The current LEO
survives the header (pid 1's `IOS7LAB cache mappings` N4106-4109 came from it, values PRINTSIDE-slid), so the
device's dyld knows the file; but it is a **2007-2009 binary generation** — the lower bound of the
`__dyld_start` probe: this pipe's dyld ASLR is 12 bits ×16 KiB (chosen between the two brackets in §10 of
`records/1033-capture-supplement.txt`), not iOS 7's 16 MiB-page sliding. A LE (the second of the 4
`rampasfn` times) dyld would explain why it does not find the cache. **Consequence: the brief's premise 3 (a
native caller of "this cache's generation") cannot be checked on the host — only in the press (§1).**

---

## 4. PART B — THE FIX DESIGN (NOT APPLIED)

### 4.1 The change in `ios7lab_mach_vm_map_trap` (`mach_kernelrpc.c:234-293`), once A says which consumer
```
wire_kind = WIRE34 n (pid, r1)  ->  FIXED_KIND[n]
```
**Kind = MIG (12-byte InOut at `regs[1]`)** — the code-proven one for a native caller:
```
uint32_t a = *(wire r1);               // copyin 4 bytes (not 8)
uint32_t s = wire_size (regs[2]);      // the client's size argument is the size; a valid size never
uint32_t mk = wire_mask (regs[4]);     // exceeds the local address space
if (a valid local (a+12 seg) && mk + 1 == s && !(s == 0)) {      // the InOut struct shape
    address32 = a + (wire r8)?;         // = the slot after; read via copyin
    rv = mach_vm_map(task->map, &address32, wire_size, wire_mask, wire_flags, …);
    if (rv == 0) copyout(&address32, r1, 4);
}
```
plus, in the **same** adapter for the fallback (address-as-out-param) shape, the 4-byte rule of
`records/1022-trap15-wire.txt` §5(a): `copyin(regs[1], &address32, 4)`; drop the `address64 >> 32` guard
(there is no high word); **the guard `regs[3] || regs[5]` STAYS** (byte-identical to Apple's MIG wire — the
client does not write them); `walkable` = `regs[3] != 0 || regs[5] != 0 || (in-process && copyin(regs[1], 12)
fails)` — i.e. when the address word cannot be read at all, **fall through to the MIG service** by returning
the shim's own sentinel `MACH_SEND_INVALID_DEST` (`0x10000003`, `mach_kernelrpc.c:249`) instead of
`KERN_INVALID_ADDRESS` (the shim's `cmp r4,r0` at `381c6688` then takes the MIG leg).
Add **VM_FLAGS_FIXED handling**: `FIXED` (bit 0 clear) + `size == 0` → `find_space = TRUE` (vm_map.c does
it), `FIXED` + `size != 0` → `mach_vm_overwrite`-style semantics: the address word is the input and the
caller's out copy is a no-op. `maxprot/cur_protection` from the wire: none exists — wire `r8` is
**target** and `VM_PROT_ALL` is emitted by `mach_vm_map(… VM_PROT_ALL …)`, matching every call in the
capture (pid-1 rows show `prot=3`).
**Kind = out-param (32-bit `mach_vm_address_t *` at `regs[1]`)** — the shape the shim's own fast path is
written for and the one the brief's fix asks for: exactly the above minus the struct test.

### 4.2 Callers that depend on the CURRENT decode (grep of the tree: only the adapter's own `printf`s read
`regs[3]/regs[5]/regs[8]`; the callers are ALL user side)
- `/usr/lib/system/libsystem_kernel.dylib` `0x381c6618` fast path: **would CHANGE** — the sentinel test
  (`381c6684`/`381c6688`) already treats `0x10000003` as "slow leg", so the fix's fallback is THIS client's
  designed path. Its `r8 = target` — the fix must not read `r8` as a protection (it doesn't today: `VM_PROT_ALL`
  is passed, `regs[8]` is only printed in the frame dump and is the 9th `mach_vm_map` parameter `VM_PROT_ALL`'s
  slot? — no, the 9th C arg is `int flags`; check: `mach_vm_map(…, flags, VM_PROT_ALL, VM_INHERIT_DEFAULT)` —
  the call at `:280` passes `regs[8]` NOWHERE; the 9th arg is `VM_PROT_ALL`, 10th `VM_INHERIT_DEFAULT`.
  **`regs[8]` is read by nothing but the print.**).
- iOS/blob `launchd` (`/tmp/d1034/`): LC_UNIXTHREAD state (from `/tmp/d1034/dyld`'s LC_UNIXTHREAD is
  `{r0..r12,sp,lr,pc,cpsr}`; the blob is a 2011-era object) → the same cache's dyld.
- `__os_alloc_slow` `0x3823a94c` (`records/1019-osalloc-extract.txt` §4): `r1 = &address` (4 B, seeded
  0x1000), `r2 = size`, `r3 = mask = 0`, flags `0x49000001` ANYWHERE — **unchanged**: under the fix `r1` is a
  4-byte out and the caller reads the 4 bytes it allocated (`sl = r1`; the wrapper's `ldr.w sl,[sp,#40]`
  after the thunk re-reads the pointer, and `__os_alloc_slow` re-reads `[r1]` as its address).
- `libsystem_platform`'s `mmap`/`vm_allocate` and libobjc's scan of the class table (the 1030 WRITER): pass
  a size like `0x4000` in `r1` (1032 errata E1a: r12 = 0x4000 is the WRITER's count, not an argument); no
  direct trap-15 call.

### 4.3 Risk list and the check that catches a mismatch
| risk | catch |
|---|---|
| The real consumer is the 12-byte struct; the out-param fix reads the size WORD as an address → the caller moves its 8 MiB map to an 8-bit address | **R10** — the "both decodes side by side" row, printed for the FIRST call of every pid: `"WIRE34 both n=%u r1=%08x wire={size=%08x,mask=%08x,flags=%08x} as_out={copyin4=%08x} as_struct={copyin12=%08x,%08x,%08x} agree=%d\n"` with `agree` = `(out4 == struct_addr)`. |
| `copyout` 4 vs 8: the caller reads 8 | R10's `ret8` (the 8 bytes at `r1` after the call) vs its 8 in the caller's frame — pid-1 rows N4147-57 show the caller's next `r1` unchanged. |
| The in-place hint mutation (VMKW) moves `find_space`'s next | R3 `gap=` before/after the first 1 MiB call; and a **control** call (the out-param path with `1` passed by the userspace client) that does NOT go through the adapter. |
| `MACH_SEND_INVALID_DEST` chosen for a caller that is NOT the shim's fast path (a native `_kernelrpc` caller would see 0x10000003 instead of `KERN_INVALID_ADDRESS`) | R1's `r1`-vs-`r2` relation: native ⟺ `r1 + 0x1000 == r2` (size − page) or `r1 = size − 0x1000`; that is the fix's own kind predicate and is rowed on every call. |
| `VM_PROT_ALL` on a native caller's FIXED mapping (over-issuing write to a read-only image) | R3's looked-up entry protection vs the wire's (no protection exists on the wire; the fix must derive it from the MIG struct in the MIG kind, which carries `cur_protection` in the request (the shim's `[sp+0x0c]` at `381c6662`) — in the MIG kind `regs[8]` **is** written by the shim (target), so the protection comes from the MIG request only). |
| The `regs[3]||regs[5]` guard rejects a native InOut call (offsets 8/12 hold `mask`/pad) | R10's `as_struct` fields + R1: any call with `regs[3] != 0` in the pid-2 window is printed; the fix's MIG kind does not apply the guard (the MIG wire's only arrival is through `mach_msg`). |

---

## 5. PART C — FALSIFIERS (what row, if seen, refutes the wire hypothesis)

- **F1 (the wire is not involved at all):** `WIRE34 enter` no call with `pid=2` between pid 2's
  `IOS7SHREGW check_np_ret ret=0` and the abort, while `IOS7SHREGW map_slide` for pid 2 returns non-zero →
  the wall is the shared-region path (a `map_and_slide` that failed) and dyld's mmap fallback is elsewhere;
  1034 goes to the `mmap`-fallback probe, not the trap-15 fix.
- **F2 (the consumer is the MIG struct, and the wire is ALREADY right):** `as_struct={addr,size,size−1}`
  with `addr < 0x2bdaa000` and the pid-2 call count > 1 → the trap-15 adapter is serving a native
  core; the wall is INSIDE `mach_vm_map` (find_space / pmap) — the fix is not in this adapter.
- **F3 (the adapter's map succeeds but nothing downstream):** `WIRE34 map rv=0` and
  `inreq=1`/`addr_end=1` for the address the caller stores → the mapping was created; the crash is the
  caller's NEXT access to a different (unmapped) object (e.g. the 0x10 field of [r1] element) — the wire
  is a red herring.
- **F4 (`r1` not in the task map, both readings):** `word2p addr_ok=0` on every pid-2 call →
  `regs[1]` is not a user pointer at all (the frame is not what §2.1 proves — the dispatcher changed, or
  the calls are not the shim's); 1034 stops and re-audits `traps_lo.s`.
- **F5 (the mask anomaly is not find_space's output):** the `addr` read at `r1` for N4155's twin is not
  `hole_end − mask − 1` (i.e. `mask = size−1` holds but the address is a page-aligned map end) → drop
  §3.4's native-slice reading; the caller writes `mask = size−1` itself (e.g. an ASLR helper).
- **F6 (the in-place hypothesis wins):** `WIRE34 entries` after the abort shows an entry `[0x0, 0x2bdaa0b8)`
  or `next_fit`-shaped state — the map was already "clean"; the wire fix cannot pass — build the
  in-place restore first.
- **F7 (VMKW closed):** the abort pc/lr are stable across two presses with DIFFERENT wire behaviour
  (probe on, no fix) → in-place cannot produce them; the wire claim stands as the only live cause.

---

## 6. ROWS, READINGS AND THEIR HAZARDS

R1 `Wire34` … R10 as above. **R2** (12-byte `copyin` with two `vm_map_lookup_entry` guards) is a pure
read. **R4's `corsp_flag`** dereferences `(vm_map_t)0xDEADBEEF` by construction — that is the oracle.
**R9 (channel):** pid 2's `printf` goes to the kernel ram console AND to its own `syslogd` (`close(4)`-style
mask from init's `close_on_exec`; the wall's text "The System bootstrapper has crashed: Bus error: 10" at
N4290 is pid-1's own `launchctl` message, proving pid 2's syslog is NOT in the ram console). Reading the pid-2
syslog needs a userland mount read of `/var/log/system.log` on this device (no tool exists; **the fix press
should carry a userspace `dmesg`-reader or write the rows to a file under `/var/tmp`**). It is a **known
limitation of A**: the A press can prove the pid-1 rows and the in-adapter behaviour, and can only *infer*
pid-2 frame ownership from `task_ok`/`in_task`. Mitigation: R1's pid field + `IOS7SHREGW check_proc`
(pid 2's `P_HAS_CS`) + `sleh_abort` rows (the wall) give pid 2's **reason** even if its `WIRE34` rows land
in its syslog.

---

## 7. NUMBERED IMPLEMENTATION ORDER

1. `tools/check_1034_capture.py --audit` on the existing 1033 capture: confirm §2.3's pid attribution
   (this changes nothing on the device; it decides whether press A is needed at all).
2. `tools/patch_d13_wire_probe.py` (SWITCH `STAGE90_XNU_WIRE_PROBE`; anchors: trap.c
   `#endif /* STAGE90_XNU_EVAL_FRAME */`, `mach_kernelrpc.c` the `RPC_MAP_OLD` prologue and the
   `IOS7LAB vm_map64` `done:` printf, `vm_unix.c` the four probe blocks; `--apply/--verify-off/--selftest`;
   ALLOWED sets per §A.4 item 5/6).
3. Registration: build_xnu_arm_kernel.sh DEFINES reader; build_entry.sh key/case/echo; preflight key list and
   `-z` grace.
4. `tools/patch_d13_eval_frame.py` and every trap.c patcher's `--verify-off` positional "last sibling" check
   updated to accept 1034's block after 1033's.
5. `scripts/build_1034.sh` from `build_1033.sh` (record gate + `STAGE90_XNU_WIRE_PROBE=1`; object assertions
   §A.6; entry link; 1032 card step).
6. `scripts/park_1034.sh` (model `park_1033.sh`) — arm name moves (`armed-d13-<sha8>`).
7. Press per `scripts/press_1033.sh` (same reader/press safety; device action is the operator's).
8. Read with `recover_last_kmsg.sh` (NOT a press; run before any reboot) → `check_1034_capture.py`
   prints cell `WIRE34-KIND` (MIG12 / OUTPARAM / NEITHER / NO-TRAP15) from R1/R10.
9. Only then design the fix press (`STAGE90_XNU_VM_MAP_WIRE_FIX`) in §4.1-§4.2's shape, with §4.3's rows;
   its `check_` must pre-register `F1-F7`.