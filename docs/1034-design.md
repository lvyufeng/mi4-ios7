# 1034 DESIGN — NAME THE 0x10: which word carries NULL+0x10 in launchctl[2]'s frame, and what loads next

Status: DESIGN ONLY. INSTRUMENT ONLY. Nothing in this document has been built, pressed, or written to the
device. No fix is selected (§5.8). Every claim about the tree or the capture has a `file:line` or a capture
line number `N<n>` (1-based in
`out/stage90/captures/recovered-unknown-arm-20261018-192718-last_kmsg.txt`, 38085 lines, mtime epoch
1792351638). Every claim about card bytes is in §6 in the required form: VA, file offset, bytes read.
Companion inputs: `records/1033-reading.txt` (the reading being extended), `records/1032-design-errata.txt`
(r12 is not a VLA extent), `records/1033-capture-supplement.txt` (written 2026-10-19, between 1033 and this
document; its §4/§5 arithmetic is re-derived here in §6.6/§6.7 and quoted only where re-derived), and
`docs/1033-design.md` (the layout and cell conventions this document follows).

> **THE HEADLINE, STATED BEFORE THE DESIGN.** By value in the 1033 capture, **nothing in launchctl[2]'s
> faulting register file holds 0x10**: the thirteen general registers read at N4277-N4280 are 0x1, 0x0,
> 0xffffffff, 0x38300020, 0x2bdaa084, 0xffffffff, 0x2bdaa088, 0x2bdaa0ac, 0x2da2e575, 0x1fff, 0x382e9c00,
> 0x2bdaa080, 0x4000 (and sp=0x2bdaa088, lr=0x381959af, pc=0x3819d474). So the address 0x10 was **computed
> at the faulting instruction from a base register and a displacement**, and 1034's job is to find which
> instruction computed it — which needs the slide, which 1033 (and its supplement) left unresolved. §1.4
> shows the slide question reduces, on the card this tree holds, to choosing the cache-file offset base of
> the shared cache among **four candidates the capture itself prints**; §1.5 shows one of them makes the
> card decode the pc as `ldr r0,[r0,#0x10]` **with r0 = 0**, two instructions after `cs_invalid_page` on a
> page launchctl had never touched. 1034's probe is built so that this is a PREDICTION checked against live
> memory, never an assumption; if the live halfword disagrees the cell says so.

## 0. WHAT 1033 READ, AND WHAT IT DID NOT PROVE

### 0.1 The reading, quoted by value

`records/1033-reading.txt` §CELL: EVF-U1-TRUE, printed by `python3 -I tools/check_1033_capture.py <capture>`
(run for this document against the committed card, exit 0, one evf group). The rows as they stand in the
capture:

    N4245 xnu_live_evf_pc=0x3819d474            N4246 evf_lr=0x381959af        N4247 evf_sp=0x2bdaa088
    N4248 evf_cpsr=0x00000030 (User, Thumb)     N4249 evf_far_raw=0x00000010
    N4250 evf_far_trunc=0x00000000              N4253 evf_dfsr_raw=0x00000007  N4254 fault_code=1
    N4255 evf_pc_minus_far=0x3819d464           N4256 evf_lr_minus_sp=0x0c3eb927
    N4263 evf_slot10=0x38962ae0  N4264 ok=1     N4265 evf_slot14=0x00000001    N4267 evf_slot18=0x00000000
    N4269 evf_ptr_word=0x00000000 N4270 ok=0    N4271 evf_lr_slot=0xf0084640   N4272 lr_slot_ok=1
    N4273 evf_read_src=0                        N4274 evf_ustack=0x2bdab000

The panic/abort print's full frame, TWO LINES BELOW the last evf row (N4275 is the message line, N4276 is
`Thread has ARM register state:`, registers N4277-N4281):

    N4277  r0: 0x00000001  r1: 0x00000000  r2: 0xffffffff  r3: 0x38300020
    N4278  r4: 0x2bdaa084  r5: 0xffffffff  r6: 0x2bdaa088  r7: 0x2bdaa0ac
    N4279  r8: 0x2da2e575  r9: 0x00001fff r10: 0x382e9c00 r11: 0x2bdaa080
    N4280 r12: 0x00004000  sp: 0x2bdaa088  lr: 0x381959af  pc: 0x3819d474
    N4281 cpsr: 0x00000030

### 0.2 What that proves

A data abort on a LOAD (dfsr 7 = translation fault on read, page) at raw DFAR 0x10, in pid 2, with
`lookup_far=0`, `far_in_map=0` (N4187-N4198) — 0x10 is not in the task map, and `vm_fault` returned
KERN_INVALID_ADDRESS (`vmfkrv=1`, N4186). The frame is internally consistent (every r0-r3/r7/r8-r10/r12 row
of the wrp/cal/evf groups equals N4277-N4280).

### 0.3 What it did NOT prove (each is a 1034 question)

1. **The carrier.** 1033's cell text says "the NULL+0x10 carrier is named by slot10 / lr_slot"
   (`records/1033-reading.txt` §CELL, the checker's U1-TRUE print). Neither names a carrier: slot10 holds
   0x38962ae0, not 0x10 (N4263; 1033 says so itself in §WHAT IT NAMES), `lr_slot` is a memory word read
   after a guard that only reports copyin success (§7 D7), and **r0-r12 contain no 0x10** (§1.1).
2. **That the pc is a load at all.** 1033's "not a load of far" verdict is about the ADDRESS 0x37C26474,
   which is what you get if the cache near-base is 0x2C577000 instead of 0x2C000000 (§1.4); it is not a
   verdict about the instruction at the pc that was actually executing.
3. **The slide.** 1033's reading says the slide is unresolved; `docs/1033-design.md` §8 row 9 predicts
   `evf_cachemap_slide = 0x03921000`, a row **that does not exist in the capture** (N4243-N4274: no such
   row; `tools/check_1033_capture.py:122` looks for a different line, `nav=`, which the stage also never
   printed). §1.4 and §7 D1/D2.

## 1. THE QUESTION, AND THE CANDIDATES BY NAME

### 1.1 The census (by value, from N4277-N4280)

| word | value | equals 0x10? | equals sp+n? | note |
|---|---|---|---|---|
| r0 | 0x00000001 | no | | |
| r1 | 0x00000000 | no | | **a NULL register** |
| r2 | 0xffffffff | no | | count −1 (1031 CAL-CALLER-OTHER) |
| r3 | 0x38300020 | no | | VLA#2 base (records/1032-design-errata.txt E1c) |
| r4 | 0x2bdaa084 | no | sp−4 | |
| r5 | 0xffffffff | no | | 1030 frame r5 was 0x38c9ec00 (`records/1031-caller-derivation.txt` (5)) — see §3 EVF2-CONTROL |
| r6 | 0x2bdaa088 | no | sp+0 | = sp exactly |
| r7 | 0x2bdaa0ac | no | sp+0x24 | |
| r8 | 0x2da2e575 | no | | word at its map0 offset is ASCII (§6.5) |
| r9 | 0x00001fff | no | | |
| r10 | 0x382e9c00 | no | | |
| r11 | 0x2bdaa080 | no | sp−8 | fp candidate |
| r12 | 0x00004000 | no | | stale (records/1032-design-errata.txt E1b) |
| sp / lr / pc | 0x2bdaa088 / 0x381959af / 0x3819d474 | no | | |

**No register is the carrier.** The carrier is `base + disp` with a nonzero disp, or a loaded word.

### 1.2 The stack candidates

sp = 0x2bdaa088, the stack region's exclusive top is 0x2bdab000, and launchctl[2]'s first user pc was
0x2bdaaf0c (N4160). Known words: sp+0x10 = 0x38962ae0, sp+0x14 = 1, sp+0x18 = 0 (N4263/65/67). A word
equal to 0x10 could sit at sp+0x00..0x40 outside {0x10, 0x14, 0x18}; 1034 enumerates all 17.

### 1.3 Which rows separate which candidate

- `evf2_regs_eq_far` — the 13-bit mask of registers equal to `far_raw` (expect **0**: §1.1). Separates
  "register carrier" (EVF2-CARRIER-Rn) from "computed address" (everything else).
- `evf2_slotNN = 0x10` — a stack carrier. Separates EVF2-SLOT (only meaningful once the addressing mode
  names a stack base and a displacement; a stack word that happens to be 0x10 with r6=sp is consistent
  with the next literal word of a 1032-style stub, §1.5).
- `evf2_instr_hi/lo`, `evf2_idx`, `evf2_rd_*` — what the instruction AT THE LIVE pc is: a load from
  `[Rn, #imm]` with `imm = far−Rn`, and whether Rn holds 0. This is the chain "rn == 0 ∧ imm == 0x10 ⇒ the
  carrier is the NULL in Rn" (EVF2-INSTR-NAMES-RN) against "a load whose Rt is the address
  register" (EVF2-NULL-LOADED: the NULL came from memory).
- `evf2_readback_ok` / `evf2_far_of[N]` / `evf2_distinct_far` — what the next access after it is:
  re-executing the intercepted pc a bounded number of times, with a memory copy (below) so the registers the
  FIRST fault got are still there on the second. EVF2-NEXT-FAR / EVF2-SAME-FAR / EVF2-DIVERGED.
- `xnu_live_shreg_*` — the geometry control that makes the instruction decode possible without a slide
  assumption when it agrees with the capture, and says "slide unverified" when it does not (§7 D10).

### 1.4 The slide: one question, four bases the capture prints

A shared-cache file offset f sits at VA 0x2C000000 + f. A binary in the cache is loaded at
VA = 0x2C000000 + binary_file_offset + text_slide. The capture prints three geometry rows:

    N4111  IOS7SHREG map_slide ... slide=0x577000 slide_start=0x3c723000 size=0x00089000
    N4112  IOS7LAB cache mapping 0  va=2c577000 size=0c266000 offset=00000000
    N4113  IOS7LAB cache mapping 1  va=387df000 size=01ce0000 offset=0c266000
    N4114  IOS7LAB cache mapping 2  va=3a4bf000 size=022ed000 offset=0df46000
    N4115  IOS7LAB cache mapping 3  va=3c7ac000 size=00177000 offset=12bda000

Under either reading of the "va=" field (a plain file offset, or an address under the 0x2C near-base),
**pc/lr/r3/r10 and slot10 all satisfy base + f = VA with ONE base**; §6.7 checks each byte. Write
g = VA − f; then g ∈ {0x0BE05474 (6.1), 0x0BE05477, 0x0BE14477, 0x0BE2C477, ...} and the candidate bases
are 0x2C000000 + (g − (0x2C000000 + bin_off)). The four in play, each printed by the capture:

| # | name | base | source |
|---|---|---|---|
| C0 | slide 0 | 0x2C000000 | definitional |
| C1 | N4111 slide on the near-base | 0x2C577000 | N4111 (`slide=0x577000` over N4112's `va=2c577000`) |
| C2 | N4111's value as the slide itself | 0x2C000000 + 0x577000 = 0x2C577000 | the formula `0x2C000000 + text_slide` |
| C3 | 1032's "0x3921000" | 0x2C000000 + 0x3921000 = 0x2F921000 | `records/1032-reading.txt:37`, whose quoted row `nav=2f921000` **is not in this capture** (§7 D2) |

C0, C1 and C2 collapse to two distinct bases (0x2C000000, 0x2C577000); C3 is a third. There is **no
pre-existing committed resolution**: 1033 says unresolved, the supplement says 0x577000 is "not
established", both 1032 and 1033 have at some point equated pc − 0x577000 with 0x37C26474 and at other
points denied it. **1034 does not pick one.** It publishes the live halfwords and lets the card (the only
byte source the device demonstrably serves for map0, N4163) decide offline — plus a geometry control.

### 1.5 The four worlds, by value (card bytes from §6)

| base | pc offset on card | hw0 @ pc | decode of hw0 | a load of `[Rn, #0x10]` on the card? |
|---|---|---|---|---|
| 0x2C000000 | 0x10193474 | 0xc969 | 16-bit IA `stm/ldm` family — not a load | no |
| 0x2C577000 | 0x10179474 | 0xc969 | same unit | no |
| 0x2F921000 (C3) | 0x0FE31758 | 0xf8d0 | `ldr.w r0, [r0, #0xc]` (§6.3) | `#0xc`, not `#0x10` |
| 0x2C000000 + bin_off | varies | — | — | an app's own __TEXT (not the cache); its bytes on the card are §6.8's and are NOT the ledger stub |

(§6.3 lists hw0/hw1 and the decoded displacement for each. On the card only C3 is a load, and its
base is r0 with displacement 0xc — so "is pc a load" is answerable on the card per base, and
"which register is the base, holding what" is answerable only from the live halfwords and register file. The `ldr r0,[r0,#imm]` family is
what 0x10-with-r0=0 needs: a NULL object pointer, a fixed field offset 0x10.)

The 1032 ledger-stub reading — `37c26468 f8d8 1010 ldr.w r6,[r8,#16] ; 37c2646c bf00 nop ; 37c2646e bd80
pop {r7,pc}` (`records/1032-reading.txt:58-61`) — is this family (`Rn + 0x10`, non-NULL Rn). **It is not
reproducible from the card at any of the bases in §1.4** (§6.8: the card at 0x10183468 reads
`56 f8 20 10 …`), so it is cited here as the SHAPE 1032 attributed to the pc, not as a byte fact. The
card's only `[Rn,#imm]` world is C3's, with Rn = r0 and imm = 0xc — which is why the 1034 probe must
read Rn's live value before any cell that names the base register.

### 1.6 The question, in one sentence

    At the launchctl[2] abort, which register holds 0 or which stack word holds 0x10, does the instruction at
    the live pc read through it with displacement 0x10, and what address does the next execution of that
    same instruction access?

## 2. THE PROBE — `STAGE90_XNU_EVF2`, one trap.c block

### 2.1 Site, the same as 1033's, one block deeper

`osfmk/arm/trap.c`, physically inside the 1025 failure arm (`#if STAGE90_XNU_USTACK_PROBE`, trap.c:842 …
`#endif` trap.c:998), immediately after 1031's `#endif /* STAGE90_XNU_CALLER_PROBE */`, which — after the 1033
patcher ran — is immediately followed by `#endif /* STAGE90_XNU_EVAL_FRAME */` then 1025's `#endif`. The
1034 block is inserted **between `#endif /* STAGE90_XNU_EVAL_FRAME */` and `#endif /* STAGE90_XNU_USTACK_PROBE
*/`**, i.e. the same place 1033 was inserted, so the chain reads

    ... 1031 block ...
    #endif /* STAGE90_XNU_CALLER_PROBE */
    #if defined(STAGE90_XNU_EVAL_FRAME) && STAGE90_XNU_EVAL_FRAME
    ... 1033 block ...
    #endif /* STAGE90_XNU_EVAL_FRAME */
    #if defined(STAGE90_XNU_EVF2) && STAGE90_XNU_EVF2
    ... 1034 block ...
    #endif /* STAGE90_XNU_EVF2 */
    #endif /* STAGE90_XNU_USTACK_PROBE */

Identifiers in scope there (verified by reading `docs/1033-design.md` §2.1 against trap.c): `arm_ctx`,
`dfsr`, `dfar`, `thread`, `map`, `code`; `_cal_far` is NOT (braces, trap.c:967-996). The struct
`abort_information_context_t` (osfmk/arm/misc_protos.h:43-51) is `r[13], sp, lr, pc, cpsr, fsr, far` — the
FULL register file, which is what makes §1.1 possible from inside the trap (N4276-N4281 is the same `r[]`
metadata printed through kprintf's `%r` for the abort message; the probe proves the equality with EVF2-CONTROL,
§3).

### 2.2 Reuse of 1033's discipline — and the re-stage

1033's block stays **in the same build, switched on as well** (`EVAL_FRAME=1` AND `EVF2=1`): that is what
turns EVF2-CONTROL into a measurement (the frame two lines apart, from `arm_ctx`, must equal the panic
print of N4277-N4280). EVF2 reads nothing 1033 reads except `slot10/14/18` (for a cross-check) and it
does not depend on `evf_*` rows for any cell.

Discipline copied from 1033 (all are load-bearing):

1. **Read first.** The block performs every guarded read before its first `printf`; if a read returns
   non-zero the block stops reading (no second attempt on that address) and prints `_ok=0`.
2. **Gate by `vm_map_lookup_entry`** before copyin (the 1026/1027 idiom; a substitution helper
   `xnu_live_evf2_read_user()` in this same block does lookup → copyin → ok, and cannot panic on `xnu`,
   where the mainbranch `copyin` panics on faulting userspace addresses — osfmk/kern/kern_copyin.c,
   mainbranch).
3. **A remembered page.** Keeping `[0x0, 0x1000)` faulted-out matters: the run's ONE copy of the `[0x10]`
   fault's registers is in this trap. Before anything, the block copies the user page containing sp to
   a kernel staging buffer (`malloc` of one page; if `malloc` returns NULL, it prints `evf2_stage_ok=0` and
   does every dependency's row with `_ok=0`). After the first fault it may **replace the user page with the
   staging buffer's copy** (`copyout` the 4096 bytes) so the later re-executions (§2.4 step 3) start from
   the same stack bytes (§5.1: a userspace write is not delivered exactly once). This is the only WRITE the probe does to user memory, and it writes back the
   bytes it just read — if the thread wrote to that page between the copyin and the copyout, that write is
   lost; the block publishes `evf2_stage_src` (0 = untouched, 1 = rewritten) and the checker treats a
   `stage_src=1` burst as a lower-trust group for the EVF2-SLOT sub-cells only (never for the register
   cells).
4. **Bounded.** At most 1 stage page, at most 20 guarded user reads in the first burst, at most 6
   re-executions; a global `static unsigned _evf2_bursts` caps the whole switch at 3 bursts per boot, after
   which the block prints nothing but the `evf2_cancel` counter.
5. **No sleep, no busy-wait, no locks beyond copyin's**, all on the failing path, `< 60` rows (§5.3).

### 2.3 The rows (names final; every row unconditional within its own burst)

First burst (inside the 1025 failure arm, next trap of the faulting thread — the same deferred point 1033
printed from, N4243):

    xnu_live_evf2_seq=<n>                burst index, 1-based, the group key
    xnu_live_evf2_pid=<pid>
    xnu_live_evf2_pc=0x%08x  xnu_live_evf2_lr=0x%08x  xnu_live_evf2_sp=0x%08x  xnu_live_evf2_cpsr=0x%08x
    xnu_live_evf2_far=0x%08x             arm_ctx->far, raw
    xnu_live_evf2_regs_eq_far=0x%04x     bit i set iff arm_ctx->r[i] (i=0..11) == far;
                                         bit 12 iff arm_ctx->sp == far; bit 13 iff arm_ctx->lr == far;
                                         0xffff iff none (the 1033-shaped frame's answer is 0xffff)
    xnu_live_evf2_r0..xnu_live_evf2_r12=0x%08x   the 13 raw registers (independent of 1033's subset)
    xnu_live_evf2_instr_src=<0|1>        0 = copyin of user pc succeeded, 1 = staged (0 = ABSENT row means
                                         "not attempted"; a burst with a failed pc read prints instr_src=1
                                         and every instr row `_ok=0`)
    xnu_live_evf2_instr_vaddr=0x%08x     pc & ~1
    xnu_live_evf2_instr_raw=0x%08x       the 16 bytes at pc & ~1 (u32 of the first 4)
    xnu_live_evf2_instr_hw0=0x%04x  xnu_live_evf2_instr_hw1=0x%04x   the two halfwords (LE)
    xnu_live_evf2_idx=<0|2>              which of the two is the instruction start (0 unless hw0 is a
                                         32-bit prefix and pc&1 == 0, in which case 2; from the decode below)
    xnu_live_evf2_dec=<0..4>             0 = not decoded, 1 = LDR/LDRB/LDRH/LDR.W [Rn,#imm], 2 = LDR
                                         [pc,#imm] (literal), 3 = a 32-bit unit whose first halfword is not
                                         in the load family (prints its class only), 4 = ARM state (cpsr T=0)
    xnu_live_evf2_rd_rt=<0..15>          target register of the decoded load, 0xf = none
    xnu_live_evf2_rd_rn=<0..15>          base register, 0xf = none
    xnu_live_evf2_rd_imm=0x%08x          the decoded displacement (0 when dec != 1)
    xnu_live_evf2_rd_rn_val=0x%08x       arm_ctx register file value of RdRn (rn==13 -> sp, 14 -> lr,
                                         15 -> literal base Align(pc,4))
    xnu_live_evf2_rd_rt_val=0x%08x       same for Rt
    xnu_live_evf2_rd_expect=0x%08x       (rd_rn_val + rd_imm) & ~3 | (far & 3), dec==1 only; the checker
                                         compares it with far
    xnu_live_evf2_slot00 .. xnu_live_evf2_slot40=0x%08x   17 words at sp+0x00, +0x04, ..., +0x40
    xnu_live_evf2_slotNN_ok=<0|1>        for each of the 17 (one row per slot, same suffix)
    xnu_live_evf2_slots_eq_far=0x%02x    bit k set iff slot at sp+4k == far (k=0..16)
    xnu_live_evf2_slot10_x=0x%08x        this block's own (sp+0x10) read; EVF2-CONTROL compares it with
                                         N4263 (0x38962ae0)
    xnu_live_evf2_stage_ok=<0|1>  xnu_live_evf2_stage_src=<0|1>
    xnu_live_evf2_bursts=<n>             bursts left in the budget

Re-execution bursts (≤ 3 more, one per next trap at the SAME pc; group key the same seq + a suffix):

    xnu_live_evf2_rexec=<1..4>
    xnu_live_evf2_far_of1 .. evf2_far_of4=0x%08x    arm_ctx->far of each re-execution (-1 if absent)
    xnu_live_evf2_distinct_far=<n>       count of distinct far values in {far, far_of1..4}
    xnu_live_evf2_readback_ok=<0|1>      1 iff far_of1 == far == 0x10 (the "same" test); 0 otherwise;
                                         rows absent if rexec never happened -> checker says EVF2-NOREADBACK

Geometry control rows (emitted ONCE per boot, in the first burst, after the others):

    xnu_live_shreg_slide=0x%08x          the value the loader created (stage's slide; printed as read)
    xnu_live_shreg_slide_src=<0..3>      0 = read from the loader's own variable, 1 = from the stage's
                                         link-time constant, 2 = not found (rows below _ok=0), 3 = other
    xnu_live_shreg_start=0x%08x  xnu_live_shreg_n=0x%08x      slide_start, size (expected N4111 values)
    xnu_live_shreg_near=0x%08x           the base the DYLD shared.region print used for map0's va field
                                         (the `2c` in `va=2c577000`): 0x2C000000 when found (useful),
                                         0 = not located (then the checker uses both readings and says so)
    xnu_live_shreg_bin_off=0x%08x        the cache file offset of the executable's __TEXT (the faulting
                                         process's dyld image), or 0 = not located
    xnu_live_shreg_ok=<0|1>

### 2.4 The mechanics that make each row real

1. **The register file**: `arm_ctx->r[i]`, `arm_ctx->sp/lr/pc/cpsr/far` — the trap's own saved state. The
   equality with the panic print is EVF2-CONTROL, not an assumption.
2. **The instruction**: copyin `pc & ~1`, 16 bytes, guarded. Decode in the kernel in exactly two steps
   (kept small on purpose; everything else is printed raw): Thumb-2 prefix test
   `((hw0 >> 11) & 0x1f) ∈ {0x1d, 0x1e, 0x1f}` ⇒ 32-bit; for `11101xx1xxxxxxxx`,
   `(hw0 & 0xfff0) == 0xf8d0` ⇒ `LDR.W Rt,[Rn,#imm12]`, `Rn = hw0 & 0xf`, `Rt = (hw0 >> 12) & 0xf`,
   `imm = hw1 & 0xfff`; for the 16-bit literal form `01001 Rt imm8` ⇒ `Rn = 15`, `imm = imm8 << 2`,
   `Align(pc,4) + imm`; for the 16-bit `0110/0111/1000 0` register-offset forms ⇒ dec=1 with
   `imm = 0` (then `rd_expect` uses `rd_rt_val` instead of the register-offset operand — printed as
   `evf2_rd_expect_alt`). `dec=3` for anything else, so the checker sees "a load could not be decoded"
   rather than a guess.
3. **The next access**: keep `abort_exc` intercept on (1025/1026's existing `xnu_live_abt_*` publisher
   continues to run on each arm) and publish far per arm until the budget ends. The re-execution is the
   SAME instruction by construction: an intercepted user data abort whose `arm_ctx->pc` equals the first
   burst's pc and whose pid equals the first burst's pid, with the stack page replaced from the staging
   buffer first. If the next trap's pc differs, the block prints `evf2_pc_next=0x%08x` and no far_of rows
   (the "next access" question is then ANSWERED BY DIFFERENT PC and the checker's EVF2-NEXT-FAR requires
   `pc_next == pc` to fire).
4. **The slide discovery**: the loader's slide variable is located per §6.9 ("build-stage grep"), not
   guessed. If not located, the geometry rows are `_ok=0` and every cell still decides: the checker
   decodes for BOTH bases the capture prints and fires only cells whose prediction is the same.

### 2.5 RE-STAGE — every trap.c patcher's allowed-identifier set gains `STAGE90_XNU_EVF2`

trap.c is edited by 994/1020/1025/1026+1027/1029/1030/1031/1033 and now 1034 ([[mi4-one-file-many-rungs]]).
Every patcher below reads trap.c's (or kern_exec.c's) `#if` identifiers and REFUSES on an unknown one, so
each must be re-staged in the same build with the new switch in its set:

| patcher | set to extend | line |
|---|---|---|
| `tools/patch_d13_undef_raise.py` | `ALLOWED_IF_IDENTIFIERS` (sleh_undef OFF proof) | 109 |
| `tools/patch_d13_dyld_witness.py` | `ALLOWED_IF_IDENTIFIERS` | 395 |
| `tools/patch_d13_ustack_probe.py` | `TRAP_ALLOWED_IF_IDENTIFIERS` | 94 |
| `tools/patch_d13_abt_entry_probe.py` | `TRAP_ALLOWED_IF_IDENTIFIERS` | 213 |
| `tools/patch_d13_reader_probe.py` | `TRAP_ALLOWED_IF_IDENTIFIERS` (+ its `EXEC_ALLOWED_STAGE90` is NOT touched: 1034 edits no kern_exec.c; but passing through the reader's check means trap.c's set, and the reader refuses only on ITS set) | 88 |
| `tools/patch_d13_writer_probe.py` | `TRAP_ALLOWED_IF_IDENTIFIERS` | 95 |
| `tools/patch_d13_caller_probe.py` | `TRAP_ALLOWED_IF_IDENTIFIERS` | 119 |
| `tools/patch_d13_eval_frame.py` | `TRAP_ALLOWED_IF_IDENTIFIERS` **and** the `TRAP_ANCHOR` at 57-58 and the selftest at 316-317 ("closes immediately before 1025's `#endif`" stops holding once 1034 is inside): the 1033 `--verify-off` tail conjunct (`#endif /* STAGE90_XNU_EVAL_FRAME */\n#endif /* STAGE90_XNU_USTACK_PROBE */`, line 258) becomes false once 1034 sits between them and must be replaced by the structural form the patcher itself cites (`tools/patch_d13_caller_probe.py:378`, `caller_closes_inside_1025`). This does NOT break 1034's own apply: 1033's block is already staged, its `check_trap` returns "already staged" (line 208-209) before reaching the anchor test (217), and `--verify-off` is only run on a 1033-only tree's OFF proof (it runs after apply, line 328 — **so build_1034 must run the eval patcher's `--apply` no-op and skip its `--verify-off`, or repair the tail check**). | 163, 57, 316 |
| **new** `tools/patch_d13_evf2_probe.py` | carries the union set (all names above + `STAGE90_XNU_EVF2`); anchors on `#endif /* STAGE90_XNU_EVAL_FRAME */\n#endif /* STAGE90_XNU_USTACK_PROBE */`; `--verify-off` = all EVF2 rows inside the gated block; idempotent; `--selftest` | — |

`tools/patch_d13_h2_stack_headroom.py:101-113` (`ALLOWED_STAGE90`) needs `STAGE90_XNU_EVF2` **only if** 1034
stages kern_exec.c. It does not (1034 adds no kern_exec.c code: user_stack comes from 1026's existing
`xnu_live_abt_proc_ustack`). If the build order runs that patcher's check over a tree whose kern_exec.c
is untouched by 1034, nothing changes there. Verified for this document: all eight sets already carry `STAGE90_XNU_EVAL_FRAME` (grep of
tools/patch_d13_*.py); the only one whose *structure* breaks is the eval frame's anchor (§2.5 row 8).

`scripts/build_1034.sh` re-stages ALL of them in one stage (never after a `git checkout --`).

### 2.6 Registering the switch (exact additions proposed; not made)

**`src/entry/build_entry.sh`**

- `ENTRY_ARM_KEYS` (2076-2141). Currently its last lines are `STAGE90_XNU_EVAL_FRAME` (2138) then
  `STAGE90_XNU_TREE_D13)` (2139). `TREE_D13)` is a *closing element with a trailing paren* — a form that
  puts `STAGE90_XNU_TREE_D13)` (with paren) into the word-split list, not a form to imitate. Insert
  **before** 2138:

      STAGE90_XNU_EVF2

- `case` arm (2336-2360 region, after 2351):

      # 1034: the carrier probe (`xnu_live_evf2_*` rows), staged by tools/patch_d13_evf2_probe.py,
      # nested inside 1025's publisher immediately after 1033's block. POOL-only.
      STAGE90_XNU_EVF2)  _v=${STAGE90_XNU_EVF2:-0} ;;

- record echo (40680-40692 region, after 40691):

      echo "STAGE90_XNU_EVF2=${STAGE90_XNU_EVF2:-0}"

**`scripts/preflight_boot_check.sh`**

- `ENTRY_CFG_KEYS` (716-770). Its last line is `STAGE90_XNU_EVAL_FRAME)` (771). Replace that line with the
  two names, matching the file's own convention (every prior rung appended with a trailing `)`):

      STAGE90_XNU_EVAL_FRAME STAGE90_XNU_EVF2)

- The `-z` grace branch (1307-1311; the pattern at 1307), after it:

      if [[ -z $_v && $_k == STAGE90_XNU_EVF2 ]]; then
        printf '  %s=(absent, and a record that does not name the EVF2 switch is one built before 1034 - no carrier probe was compiled in, the only value a pre-1034 build could have written)\n' "$_k"
        continue
      fi

  Rationale (the same as 1029-1033's): every parked arm predating 1034 wrote no EVF2 line, so its only
  possible value is absent; a post-1034 record always writes the line.

**`tools/build_xnu_arm_kernel.sh`** (1137-1153 pattern, after 1153):

      [[ ${STAGE90_XNU_EVF2:-0} -eq 1 ]] && DEFINES+=(-DSTAGE90_XNU_EVF2=1)

Channel: the global `DEFINES` array via env export — never `XNU_KERNEL_EXTRA_DEFINES`
(records/1020-build-defect.txt; `scripts/build_1033.sh:171,180,186` enforces that split for its own set).

## 3. THE PRE-REGISTERED CELLS (fail closed; `tools/check_1034_capture.py`, to be written)

Rules shared by all cells: a cell is decided only from rows PRESENT in a capture whose mtime epoch is >
the press's boot epoch; an ABSENT row is not a negative (EVF2-MISSING unless another cell's *positive*
conjunct is fully present); `EVF2-PANIC` beats everything; the checker prints the EVF2-CONTROL line before
any verdict and refuses (NO READING) if the control is negative.

- **EVF2-CONTROL** (checked first): `evf2_r0..r3, r4..r7, r8..r11, r12, sp, lr, pc` == N4277-N4280 values
  **and** `evf2_slot10_x` == 0x38962ae0 **and** `evf2_far` == 0x10, for a burst with `pid == 2`. If any
  differs, the burst is not this fault; print the differing row and STOP (**NO READING**; a *different*
  frame is EVF2-OTHER-FRAME, reported, not judged). *Fixture:* a burst with r5 changed → NO READING.
- **EVF2-CARRIER-Rn** (n = 0..12, sp, lr): `evf2_regs_eq_far` has bit n set. Then the carrier is that
  register and `evf2_rd_rn == n ∧ evf2_rd_imm == 0x10 ∧ evf2_rd_expect == far` should also hold
  (printed alongside; if not, the cell still fires and appends "instruction disagrees: dec/rt/rn"). Expected
  in this frame: **does not fire** (§1.1). *Fixture:* a burst with r1 = 0x10 and regs_eq_far bit 1.
- **EVF2-SLOT** (k = 0..16): some `evf2_slotKK` == 0x10 and `evf2_slots_eq_far` bit k. Fires with the
  word index only; the checker never says "carrier = slot" unless `evf2_rd_rn == 13` and
  `evf2_rd_imm == 0x10` (base sp), in which case it prints EVF2-SLOT-AS-BASE. Expected: does not fire unless
  the live stack has a 0x10 word. *Fixture:* slot at +0x20 = 0x10.
- **EVF2-INSTR-NAMES-RN**: `dec == 1 ∧ rd_rn_val == 0 ∧ rd_imm == 0x10 ∧ rd_expect == 0x10`. The carrier is
  the NULL in Rn at the faulting instruction. This is the cell the card's `ldr rX,[rX,#0x10]` worlds predict.
- **EVF2-NULL-LOADED**: `dec == 1` and
  `rd_rt == rd_rn` and `rd_imm == 0x10` (the instruction loads `*[Rn+0x10]` INTO Rn: the next access after
  it is through the loaded word) **and** `rd_rn_val != 0`. Then the 0x10 came from an object's field
  (the "NULL field" hypothesis), the instruction named at pc is the LOAD that faults, and the next access
  is `[*(Rn+0x10)]`.
- **EVF2-NONE**: `regs_eq_far == 0xffff` and `slots_eq_far == 0` and `dec != 1` — no published word is the
  carrier and the instruction at pc is not a `[Rn,#imm]` load. NO close; next rung is a static decode of
  the live halfwords (which the burst printed). *Fixture:* the §1.1 frame with `dec = 3`.
- **EVF2-PC-LOAD** / **EVF2-PC-NOTLOAD**: `dec == 1` (or 2) vs `dec ∈ {0, 3, 4}` on a CONTROL-positive
  burst. Under the C-3 base (§1.5) the card's `0xf8d0` predicts PC-LOAD; under C0/C1 it predicts an
  `stm`-family unit (`dec = 3`) → PC-NOTLOAD. Each cell prints which base matches; a PC-NOTLOAD cell is
  a value against the live instruction, never a slide verdict.
- **EVF2-STAGE-DISAGREE**: `evf2_rd_expect != far` for the only decoded load in the burst: the live
  instruction names `[Rn+imm]` which does not include the far, so the decode's convention (32-bit prefix /
  PC-relative base) is wrong for this halfword; the rows are printed and NO cell that depends on `dec`
  fires.
- **EVF2-NEXT-FAR**: `readback_ok == 1` and `distinct_far == 1` and `far_of1 == far` — the next execution
  of the same instruction faults at the same address; this is the signature of `src + 0x10` with a store
  that has not yet written `src` (the writer at 0x37C266EC on the card stores `src` into the VLA *then*
  loads `src->field` — ledger shape), i.e. **the next access is a LOAD of the same field and it will not
  self-correct**. *Fixture:* far_of1 = 0x10.
- **EVF2-SAME-FAR-ONCE** / **EVF2-DIVERGED**: `distinct_far == 1` but `readback_ok == 0` (the row exists
  but far_of1 absent: re-trap did not arm) / `distinct_far ≥ 2` (the address moved: a write landed between
  the arms — the 1030 "store moved the fault" shape). DIVERGED is the *good* news for a fix later; it is
  NOT a reading of the carrier.
- **EVF2-NOREADBACK**: control-positive burst, no `evf2_rexec` burst within the capture → the "next
  access" question is OPEN; the carrier cells stand, the next-access cells do not.
- **EVF2-SLIDE-GEO**: geometry rows `_ok=1`: compute, for the control-positive burst, `k = pc - slide -
  bin_off - 0x2C000000`; if `k == 0` → prints "the capture's slide maps the pc into the cache at file offset
  `pc - slide - bin_off`"; else prints the mismatch. Does NOT pick the base.
- **EVF2-MISSING**: no evf2 group but a control-positive 1033 evf group with far == 0x10 → the EVF2 switch
  was not in the pool (build defect).
- **EVF2-NOPLANE**: `read_src`-equivalent `evf2_instr_src` shows a failed read on the first burst and
  nothing after; or a panic appears → **EVF2-PANIC** (a panic outranks NOPLANE).
- **EVF2-PANIC**: a panic, or the 1023 storm (0x40083008 / `abt_pcn >= 0x8000`), or launchd reached with
  no trap24/port_construct control.
- **EVF2-OTHER-FRAME**: control fails but far == 0x10 (a different thread/process also faulted at NULL+0x10):
  published as a separate cell, never merged into the launchctl[2] reading.

The cell set is ordered; exactly one primary cell is printed, plus any secondary lines. `--selftest` builds
≥ 14 synthetic captures (every cell above fired once, plus the panic, storm, missing, no-plane and
control-fail paths), each asserted to produce its cell, and a **control** fixture that would pass EVF2-NONE
if the checker did not check control first — the checker must fail that fixture "NO READING", which is the
test that the control actually gates.

## 4. BUILD / PARK / PRESS / RECOVER

1. **Build** — `scripts/build_1034.sh`, modeled on `scripts/build_1033.sh` but **exporting** every pool
   switch from the record's value (build_1033.sh:143-156 already does this and fixes the docs/1033-design.md
   §7.1 EXTRA-channel defect; keep its shape), re-staging all trap.c patchers (§2.5). Gates, in order,
   each a refusal: (0) record carries USTACK/ABT_ENTRY/H2/READER/WRITER/CALLER/EVAL_FRAME/EVF2 = 1,
   VM_MAX_SPLIT=1, IOS7_TRAPS=1, GLOBAL_FIX in EXTRA with the pmap.o fingerprint; (0a) the staged trap.c has
   exactly one `#if defined(STAGE90_XNU_EVF2)` and one `#endif /* STAGE90_XNU_EVF2 */`, between 1033's
   `#endif` and 1025's `#endif`, and 1033's block still has its single pair; (0b) the static lane's block-plane test (§6.9c, the (o | 0x400000) rule on the extracted cache)
   re-run for every §6.3/§1.5 row; (1) `patch_d13_evf2_probe.py
   --apply` then `--check`, then `--verify-off`, and the re-staged 1033 patcher's `--verify-off` still
   passes on the new tree; (2) pool rebuild; trap.o carries every `evf2_` string; (3) source record names
   the staged trap.c sha; (4) link; ELF carries evf2 rows, every inherited `--expect` PASS; (5) card ==
   pristine + the 10 bytes `5010012801daf0bdc046` at 0x10183720 and differs in exactly 10 bytes
   (`scripts/build_1033.sh:301-305` shape); (6) `check_1034_capture.py --selftest` PASS.
2. **Park** — `scripts/park_1034.sh`: new arm name `armed-d13-$(sha256sum out/stage90/xnu_arm_entry.bin |
   cut -c1-8)`; kernel/payload members byte-identical; park both `patch_d13_evf2_probe.py` and
   `check_1034_capture.py`; `records/revert-set.txt` line `card_patch=0x10183720=5010012801daf0bdc046` and
   `role=1034-carrier;instrument-only` per file; keep 1033's park copies where they resolve
   (`resolve_arm_set.sh` requires a named file in both places — records/1032-press-read.txt §2).
3. **Press** — `scripts/press_1034.sh`, modeled on `press_1033.sh`: step 0 by-value gates (record, trap.o
   rows, ELF rows, GLOBAL_FIX fingerprint, card differs from rootfs in exactly 10 bytes and holds the
   guard bytes); step 1 hardware gate (`adb` has serial 4a2fe00b, 33e80afe absent); step 2 `dd` the card to
   `/dev/block/mmcblk0p25` and read the 10 bytes back OFF the device; **never flash**; step 3 arm the USB
   reader BEFORE the send, `fastboot boot -s 4a2fe00b out/stage90/stage90-qcdt.img`, stamp
   `_BOOT_EPOCH=$(date +%s)` before the send, `set +e` around `wait` ([[mi4-unguarded-wait-aborts-resident-press]]);
   step 4 recover with `scripts/recover_last_kmsg.sh --read-only`; step 5 staleness guard: capture
   `stat -c %Y` > `_BOOT_EPOCH` or print **NO READING - STALE SLOT** and stop; then
   `python3 -I tools/check_1034_capture.py <capture>`.
4. **Operator**: a resident non-returning run leaves the phone dark; only the operator's power press brings
   it back ([[mi4-device-dark-needs-power-press]]). 1034 cannot be re-pressed without them. Expect the first
   recovery attempt to be stale (the 1032/1033 outcome).

## 5. RISKS, AND WHAT 1034 DOES NOT DO

1. **The stack restore is a userspace write, and it can be DELIVERED TWICE.** The re-execution writes the
   staged page back to userspace before re-arming. A userspace write is visible and can be applied again (or
   not at all) when the faulting instruction is restarted — the rule the 1031 caller-derivation cites for
   `count` ("a caller-return clamp cannot affect the writer's own re-read") has the same shape: a store made
   by the instruction that faults is not guaranteed to land once. So the stage copy is a restore of the bytes
   the probe just read, NOT a guarantee that the page's writes happened exactly once; EVF2-DIVERGED may
   therefore be caused by the probe itself and must be read as "OPEN", not as "the program wrote". The
   register cells (the carrier) do not depend on the restored page at all.
2. **The re-execution perturbs the run.** Re-arming the same pc runs the faulting code a few more times with
   the stack page restored. It can produce a different outcome (the ledger write now succeeds) — that is
   EVF2-DIVERGED and is a READING about the next access, not a fix; the run still ends in the crash or
   does not. Worst case, three more aborts before the budget ends. No sleeps, no stores except the staged
   page copy-out.
3. **`malloc` / `copyout` in the trap.** If `malloc` fails, all dependent rows print `_ok=0`. Copyout to a
   user page can itself page-in; it runs after the first copyin and its failure is `stage_src=0`.
4. **Window budget.** ≤ 60 rows × ≤ 46 B ≈ 2.8 KB worst case at the RAM-console text rate (~120 B/s that
   the 1031-1033 press reads are consistent with) ≈ 23 s against the ~2 min the boot takes to reach
   launchd — it cannot widen the window past the boot's own end. The budget is not the risk; a wrong read
   (§2.2.2) is.
5. **Coverage could move the frontier.** If the repair of the readback makes launchctl[2] pass that load and
   crash later, the capture's control frame is not the 1033 one → EVF2-CONTROL fails → NO READING for the
   1033-shaped cells, but a new frame is published (EVF2-OTHER-FRAME). That is not a regression; it is the
   probe having done what it says.
6. **Card identity.** Host and device copies must agree by value (read back after `dd`); a run where the
   read-back fails is not pressed.
7. **Slide geometry**: the geometry rows may be unlocatable (src=2); cells still decide by the two
   capture-printed bases and say so.
8. **Not a fix.** No libobjc bytes beyond 1032's 10, no kern_exec.c code, no allocation of user memory
   contents (the stage page is a copy of the stack, not an allocation of new VA).
9. **1034 SELECTS NO FIX.** It names a carrier and a next access; the choice (caller-side negative bound,
   writer-side store, table-side) belongs to the rung after the cell.

## 6. BY VALUE — every byte claim with VA, file offset and the bytes actually read

Method used for every read in this section: `xxd -s <off> -l <n> -p <file>` with
`off = 0x455D000 + (VA − 0x2C000000)` for the rootfs's map0 (the rule records/1032-design-errata.txt
states), and the corresponding `0x455D000 + (VA − base)` for other bases. Files:
`/mnt/data/ios7-payload/v2/ios7/rootfs.hfs` (**`rootfs`**) and `out/stage90/xnu_card_hfs.img`
(**`card`**, 939524096 B each, same mtime family).

### 6.1 The cache file is at 0x455D000 on both, by value

- VA 0x2C000000 → offset 0x455D000. `rootfs` @ 0x455d000, 16 B: `64 79 6c 64 5f 76 31 20 20 20 61 72 6d 76 37 00`
  = `dyld_v1   armv7\0`. Two u32s follow.

### 6.2 The card differs from the rootfs in exactly 10 bytes

- `cmp -l rootfs card` → 10 lines, byte positions 270022433..270022442 = 0x10183720..0x10183729 (1-based
  cmp positions; 0x10183721..0x1018372A 1-based file offsets → 0x10183720..0x10183729 0-based).
- `card` @ 0x10183720, 10 B: `50 10 01 28 01 da f0 bd c0 46`; `rootfs` @ 0x10183720, 10 B:
  `00 21 b1 eb 62 0f 08 bf f0 bd`.

### 6.3 The pc in each §1.4 world

- **C0** (base 0x2C000000): VA 0x3819d474 → offset **0x10193474**. `card`, 8 B: `c9 69 01 70 c9 70 00 bf`.
  halfwords LE: hw0 = 0xc969, hw1 = 0x7001. `0xc969` low 5 bits of `>> 11` = `0x19` ∉ {0x1d,0x1e,0x1f};
  `(0xc969 & 0xf800) == 0xc800` — the IA `stm/ldm r0,{…}` family, not a 32-bit prefix and not an [Rn,#imm]
  load ⇒ dec = 3. Under C1 the same 8 bytes (offset 0x10179474: `c9 69 01 70 c9 70 00 bf`).
- **C3** (base 0x2F921000, i.e. 1032's 0x3921000): VA 0x3819d474 → offset **0x0FE31758**. `card`, 8 B:
  `d0 f8 0c 10 00 ea 87 f8`. hw0 = 0xf8d0: `(0xf8d0 >> 11) & 0x1f == 0x1f` (32-bit prefix) and
  `(0xf8d0 & 0xfff0) == 0xf8d0` ⇒ `LDR.W Rt, [Rn, #imm12]` with **Rn = 0, Rt = 0**, imm = hw1 & 0xfff =
  **0x00c**. `rd_expect` = (r0 + 0xc) = **0x0000000c**, not 0x10 ⇒ by the card, this world predicts
  **EVF2-STAGE-DISAGREE**, not EVF2-INSTR-NAMES-RN — unless the live halfwords differ. (This is the value
  that replaces the design's draft reading "`ldr r0,[r0,#0x10]` with r0=0": on the CARD it is `#0xc`. I
  read the bytes; I do not adjust them.)
- **C2** (base 0x2C577000): VA 0x38962ae0 (slot10) → offset 0x10948ae0: `card`, 16 B: `00 ×16`. VA
  0x382e9c00 (r10) → 0x10178c00 (not in the windows read; unverified on this host for r10).

### 6.4 What `slot10`, `lr`, `r3` decode to under the bases

- slot10 0x38962ae0 at **C2** base: card 0x10948ae0 = 16 zero bytes — "a search-cache pointer" (1033) is,
  in this world, a pointer to a zeroed region of map1. Not a code pointer.
- lr 0x381959af at C0: card 0x101719af, 8 B: `bf 80 b5 40 69 6f 46 c2` (`bf80 nop; b540 push {r6,lr};
  4669 mov r9,r13`). At C2: 0x1016f9af (`f8d8 2020` `ldr.w r2,[r8,#0x20]`…), read: `f8 d8 20 20`.
- r8 0x2da2e575 at C2: card 0x5a14575, 16 B: `5f 5f 4e 53 43 46 4c 6f 63 61 6c 65 00 5f 5f 4e`
  = `__NSCFLocale\0__N` — a string in libobjc's data, i.e. r8 is `+1` mid-string (the 1032 reading's
  "r8 is a pointer" holds under this base). A second offset of the same family: 0x5a0b575
  (= C2 + 0x14AE575) reads `\0not found\0p2-pre-` — also ASCII.

### 6.5 libobjc's base is NOT the map0 plane

- libobjc segment base at cache-file offset 0x14B7000 (`records/1032-reading.txt:68`) → card offset
  0x5A14000. `card`, 16 B: `00 74 69 6d 65 20 70 6f 72 74 20 3d 20 30 78` — ASCII prose, not a Mach-O
  header. So **the r8 value 0x30dd8575 → "libobjc" identity of 1032 rests on a base whose card bytes are
  text** (EVF2's r8 is 0x2da2e575, and 0x2da2e575 − 0x2c577000 = 0x14b7575 = the same libobjc offset ⇒ the
  two faults share an r8-offset-of-string-identity, a control worth noting). The claim "r8 is inside
  libobjc" is recorded as **identity-by-offset, not identity-by-header**.
- Also read: offset 0x5A13756 (`countered unexpe`), 0x5A130D4 (`countered empty `), 0x5A14575
  (0x14B7575, `__NSCFLocale`) — three candidate bases for r8, all strings.

### 6.6 The supplement's lr_slot arithmetic, re-derived

- lr 0x381959af; (lr − 4) & ~3 = 0x381959A8. `records/1033-capture-supplement.txt` §4 says
  `(lr-4)&~3 = 0x381959ac` and searches BL targets landing on 0x381959ac; with the correct word
  **0x381959A8** the target is A8, and the captured word `0xf0084640` (N4271) is a `bl` pair
  `F008 4640`: halfword 2 0x4640 has `(hw2 >> 11) & 0x1f = 0x08` ∉ {0x1d,0x1e,0x1f} ⇒ not a BL's second
  halfword by construction, consistent with the supplement's conclusion by a different arithmetic. The
  supplement's "0x7ac5 ... negative-offset form" remains a hypothesis. **Do not use `0x381959ac`.**

### 6.7 The slide identity, by value

For VA ∈ {pc 0x3819d474, lr 0x381959af, r3 0x38300020, r10 0x382e9c00, slot10 0x38962ae0}: every one lies
in N4113's span + base: slot10 − 0x387df000 = 0x1183AE0 = N4113 offset + (VA − 0x387df000) check —
0x0c266000 + 0x1183AE0 = 0x1daa6ae0, which under base 0x2C000000 is file offset 0x1DAA6AE0; card @ that offset
was **not read** (outside the windows of this section) — **unverified on this host**. pc − 0x2C000000 =
0xC19D474 is **not** in any N4112-15 mapping (map0 of the cache near-base ends at 0x387dd000), which is the
supplement's C2 and is re-confirmed here by arithmetic only. The bases remain ← §1.4.

### 6.8 The 1032 stub bytes, re-read (the world 1032's pc claim lives in)

VA 0x37C26468 → offset 0x10183468. `card`, 24 B: `56 f8 20 10 01 30 09 7c 00 29 f7 d0 04 eb` — i.e.
`6468: 56f8 2010? ldrb …` — **this does NOT reproduce** `records/1032-reading.txt:58-61`'s
`37c26468 f8d8 1010 ldr.w r6,[r8,#16]` (the bytes there start `f8 d8 10 10`; the card has `56 f8 20 10`).
The `…60d` form (`f8d8 2010 1301 7c09 2900 d0f7 eb04`) is the ledger stub shifted by 0xA under yet another
base (0xC3). **The 1032 ledger-stub decode is not reproducible from the card at the offset 1032 names.** This
is recorded, not resolved: 1034 does not use it for any cell (it is cited in §1.5 only as the shape the
NULL+0x10 family implies, and the shape is independently present at C3 with Rn=0 and imm=0xc).

### 6.9 The loader's slide variable — where it must come from

`IOS7SHREG map_slide … slide=0x577000` (N4111) is produced by user-space code that is **not in this
tracked tree** (`grep -rn IOS7SHREG src/` finds only prose in `src/entry/entry_stubs.c:4592`; the producer
is in the payload's shell/launchd shim). The kernel-side xnu's own shared-region slide lives in the
kernel's `shared_region_slide` bookkeeping (external/xnu-hd2-darwin13, the tree this project builds —
**not a reference**, per the project index); the exact global is **unverified on this host** until
`grep -n "slide" external/xnu-hd2-darwin13/osfmk/vm/vm_shared_region.c` is run in the build lane.
Proposal: build-stage grep; if found, publish it and its `slide_src`; if not, `_ok=0` rows and the
two-base decode (§5.6).

### 6.9b THE FILE-of-BYTE-0 IS ONE CACHE; THE CARD AND THE ROOTFS ARE NOT ADDRESS-COMPARABLE (added after cross-check)

`records/1034-carrier-static.txt` (written by the static lane while this document was being written; not in
the brief) reports that byte 0 of `out/stage90/xnu_card_hfs.img` `/mnt/data/ios7-payload/v2/ios7/rootfs.hfs`
is NOT the cache header and that "0x455D000 is a STRING inside dyld code". **For the rootfs that is REFUTED
by value**:

- rootfs @ 0 (16 B): `64 79 6c 64 5f 76 31 20 20 20 61 72 6d 76 37 00` (`dyld_v1   armv7`), followed by
  u32 0x68, 0x3, 0xC8 — the cache header. The same 16 bytes stand at rootfs @ 0x455D000 (mine) and at
  `/tmp/dyld-extract/dyld_shared_cache_armv7` @ 0 (`cmp` of the extract and `/tmp/ios7/dsc`: **identical**;
  315952666 B each).
- The rootfs and the extract agree at the E1a anchors: rootfs @ 0x101833CC = `f0 b5 03 af 2d e9 00 0d 85
  b0 80 46 46 f6 24 40` and extract @ 0xBC263CC = the same; rootfs @ 0x1018344C = `1d d3 ad eb 85 04 eb 46`
  and extract @ 0xBC2644C = the same. So **rootfs map0 = 0x455D000 + (VA − 0x2C000000)**, four disjoint
  probes agreeing, and the static lane's own "E1a byte-for-byte EQUAL" table agrees with mine.
- **The static lane's "rootfs @ 0x10183720 = 84 97 2b 30 …" and "neither pristine copy carries `1d d3 ad eb
  85 04`" are FALSE for the files on this host**: rootfs @ 0x10183720 = `00 21 b1 eb 62 0f 08 bf` (§6.2) and
  the anchor is present (once, in the extract). Its check is not reproducible; its slide conclusion (§3.6,
  "not decidable on this host") stands on its own reasoning but not on those bytes.
- **What the lane is RIGHT about, and it matters for the mapping**: a cache file is not one plane. Its
  (N+1)-th 4 KiB-block group carries the metadata/data for the N-th code block. The 128 B at 0x106FA474
  read `1b 13 0b 03 …` (a counting sequence) because they are a block-map region, not map0 code — see
  6.9c. So card @ 0x106FA474 is **not** "the pc in C0/C1"; neither is card @ 0x10193474 (§6.3) or
  0x10179474 **code**. **Every §1.5 "card decode" is a statement about the cache FILE's code plane, and
  the (VA | 0x400000) test in 6.9c decides whether a given VA's bytes sit there.**

### 6.9c The block-plane test applied to this frame's addresses (the strongest candidate, and its limit)

The extracted cache's code-plane test is: bytes at (o | 0x400000) for a code VA whose cache-file offset is
o. Applying it to the four addresses that carry evidence:

| VA | cache-file offset o | bytes @ o\|0x400000 in the extract | reads as |
|---|---|---|---|
| pc 0x3819d474 | 0xBC26474 (C1) | `f8 d8 00 20 68 50 31 46 d8 f8 00 01` | `ldr.w r0,[r8,#0]` / `ldr.w r0,[r8,#0x1000]` — two loads through r8; **not decode-verified** (a stripped cache has no symbol/relocation name for them) |
| **r8 0x2da2e575** | 0x14B7575 (C1) | `00 6e 6f 74 20 66 6f 75 6e 64 00 70 32 2d 70 72` | **`\0not found\0p2-pre-`** |
| lr 0x381959af | 0xBC1D9AF (C1) | `32 d3 68 ff 00 0e 01 08 00 64 47 b5 32 05 69 ff` | not decode-verified; not a `bl`+return shape |
| slot10 0x38962ae0 | 0xBC3EAE0 (C1) | `63 68 53 69 6e 67 6c 65 4f 63 63 75 72 72 65 6e` | **`chSingleOccurren`** (a libobjc/Foundation string) |

- **slot10 is `chSingleOccurren` + 2** — slot10 (1033's "a search-cache pointer") is, in the cache file,
  a middle-of-string data pointer in the code plane, i.e. it is NOT a code address and the 1033 sentence
  "a search-cache pointer" is unproven for it (it could be a data chunk in the same plane; not resolved).
- **r8 = 0x2da2e575 reads `p2-pre-…`** — the process that faulted is pid 2 (`p2`), and the string
  `p2-pre-` (a launchd/dyld "before-cache" breadcrumb) sits at r8's offset. The same string was found by
  this document at card 0x5A0B575 in §6.4 under the **same C1 relation, un-blocked** — the two reads
  agree, which is the first cross-check that card and extract describe the same cache. **A string name is
  still identity-by-offset, not a relocation table**: 1034 does not claim r8 points at a known symbol.
- **This supports C1 for the FAULTING image's region but is NOT decisive for the pc**: under C1 the pc's
  offset 0xBC26474 is inside map0, in the code plane, and the halfword is 0xf8d8 (`ldr.w r0,[r8,#imm]` — a
  load through r8, not through r0; its displacement is hw1 & 0xfff = 0x000). If that is the instruction,
  the far 0x10 would be `r8 + 0` — contradicted by r8 = 0x2da2e575 — so this world's card decode does NOT
  by itself name the carrier either. 1033's reading that "pc is not a load" was a verdict about the
  **un-blocked** offset (0x10179474 = `c9 69 …`), which is not the code plane — 1033's bytes are not
  evidence about the instruction (whether the device executes the code plane or some other plane is a
  question the §2.3 geometry rows and the live halfwords answer). The design therefore does not
  promote C1 to a finding; it promotes the block-plane test to a REQUIRED step of the build lane's static
  check (§4 gate 0b: run it on every §1.5 row), and leaves the cell decision to the live halfwords and the
  geometry control rows.

### 6.10 Not verified on this host

- r10 0x382e9c00 at C2 (not read).
- 0x1DAA6AE0 (slot10's C2 file offset) — read status: not read.
- live instruction halfwords anywhere (§1.5's predictions are card predictions, checked by the probe).
- the loader's slide variable (§6.9).

## 7. DEFECTS FOUND IN THE 1033 TOOLING, ITS SCRIPTS, AND ITS READING

N numbers are capture lines; file:line otherwise.

1. **`tools/check_1033_capture.py:122` + `docs/1033-design.md:209,269-272`** define the slide row as
   `IOS7LAB cache mapping 0 nav=<hex>`. **The stage never prints a row with `nav=`, and `evf_cachemap_slide`
   was never emitted** (N4243-N4274; N4112 prints `va=… offset=…`). So `mapping0()` always returns None;
   the U2 cells (lines 205-221) can never fire on a real capture; and the unit-test fixtures (lines 266,
   313) are built on a row that does not exist. A 1034 checker must use `va=`/`slide=` (§1.4).
2. **`records/1032-reading.txt:37,46,67`** quote `IOS7LAB cache mapping 0 nav=2f921000` and derive
   slide 0x3921000 from it; that row is **not in the 1033 capture** (N4112 is `va=2c577000 …`). The only
   slide values the capture prints are N4111's 0x577000 and N4112's `2c577000` field. D1's cause is this
   line. 1032's own r8 = 0x30dd8575: 0x30dd8575 − 0x2f921000 = 0x14B7575, which equals libobjc's offset
   from C2 — so 1032's 0x2f921000 is the base under which libobjc sits at 0x14B7000. That is why the row is
   a real value and a real base — for libobjc, not proven for the faulting pc.
3. **`records/1033-reading.txt` "OPEN" §3**: "decodes pc−0x577000 = 0x37C26474 to f248 48f2 a…". That byte
   pair is not a Thumb-2 opcode prefix (both are 32-bit second halfwords by the prefix test); and the
   arithmetic contradicts itself: pc − 0x577000 = **0x37C26474**, not 0x37C26474 decoded — the '37C26474 is
   the result of the subtraction, and the quoted "f248 48f2" is therefore the bytes at another file offset
   than C1 names (C1 reads 0xc969 at 0x10179474, §6.3). Also `docs/1033-design.md:13-14` states
   "the halfword at 0x37C26474 is 0x0224 (`lsls`)": **card @ 0x10183474 = `09 7c`**, so that "0x0224" is
   not the card's halfword either; `docs/1033-design.md:490-491` repeats it. None of these bytes is what the
   files hold.
4. **`tools/check_1033_capture.py:11` vs `:196-201`**: the docstring's U1-TRUE conjunct is
   `(walk_pc_ok == 1 OR lr_slot_ok == 1)`; the code accepts `walk_pc_ok == 1 or lr_slot_ok == 1` where
   `walk_pc_ok` is **never emitted** by `tools/patch_d13_eval_frame.py` (`grep walk_pc` in it: none). The
   docstring "lr_slot_ok == 1 = the lr_slot call decode" (docs/1033-design.md §3) is false at runtime: the
   patcher's `_evf_ma[4]` (lines 97-103) is a **map lookup**, and `lr_slot_ok` only says the word at
   `(lr−4)&~3` was READ; N4271's 0xf0084640 is not a `bl` to lr (the supplement's §4 and §6.6). The cell
   stands; the proof attached to it is not a proof.
5. **`tools/patch_d13_eval_frame.py:97-103`**: slot 4's ADDRESS condition
   `((_evf_lr - 4U) & ~3U) <= 0xfffffffcU` wraps for every lr < 4 and the copyin at line 105 repeats the
   wrap; harmless at lr = 0x381959af but the guard is not a guard. It should be
   `(_evf_lr >= 4U && ((_evf_lr - 4U) & ~3U) <= 0xfffffffcU - 3U)`, i.e. also bound the aligned address,
   not the unaligned one.
6. **`records/1033-reading.txt:20`** "U2 (wrong slide) is refuted by value": far = 0x10 being slide-free
   refutes "far is image-relative", not "the pc's slide is wrong". The supplement's C2 says this; the design
   §1.4 shows the pc's base is a live choice among four. Not a reading the next rung may inherit.
7. **`docs/1033-design.md:296-327` lists cells the checker does not implement**: EVF-U1 row set lists
   `evf_walk_fr/walk_lr/walk_pc/walk_ok/walk_pc_ok/read_src/shadow_src/read_src/cachemap_slide` —
   `tools/patch_d13_eval_frame.py:150-159` (`EVF_ROWS`) has none of `walk_*`, `shadow_src`, `cachemap_slide`.
   The design's `EVF-U1-TRUE` requires `walk_pc_ok`; the shipped one does not. Design and tool disagree.
8. **`docs/1033-design.md:209` `xnu_live_evf_cachemap_slide=0x%08x … absent ⇒ row absent`** vs §8 row 9
   predicting a value: a row declared "may be absent" in §2 cannot carry a pre-registered prediction in §8
   unless its absence is itself a cell. It is not.
9. **`tools/check_1033_capture.py:143,146`** count "panics" with `"panic" in ln.lower()` over the WHOLE
   capture, and this capture prints `xnu_live_..._no panic` style rows (the guard `and "no panic" not in
   ln.lower()` exists) — but any new row whose text contains "panic" inside a compound word also fires.
   Check on this capture: 0 hits (the U1-TRUE print succeeded), so this is latent, not live.
10. **`scripts/build_1033.sh:186` exports `STAGE90_XNU_CALLER_PROBE=1` but the same file's
    skip-list `EXTRA` loop (171) and its gate (180) treat `EVAL_FRAME` as a global-DEFINES switch while
    `STAGE90_XNU_EVAL_FRAME` is read by `tools/build_xnu_arm_kernel.sh:1153` — consistent; but **the loop
    at 186 ends before EVAL_FRAME and line 189 exports only `$NEW`**, so the *next* rung (1034) that
    inherits this file must add its own name to line 186's list or it will be exported only via 189 —
    fine, but a 1034 copy that renames `NEW` and forgets 171's skip list would silently send EVF2 through
    `XNU_KERNEL_EXTRA_DEFINES`. Cite as a copy hazard, not a 1033 defect.
11. **`src/entry/build_entry.sh:2138-2139`**: `ENTRY_ARM_KEYS` ends with `STAGE90_XNU_EVAL_FRAME` followed
    by `STAGE90_XNU_TREE_D13)`. The trailing `)` belongs to the array literal and is harmless, but the
    `TREE_D13` element is the only one with an attached `)` — a 1034 edit that inserts after 2139 instead
    of before 2138 would create `STAGE90_XNU_TREE_D13)` + `STAGE90_XNU_EVF2` elements, one of which carries
    a paren. Insert before 2138 (§2.6).
12. **`records/1033-capture-supplement.txt` §4** `(lr-4)&~3 = 0x381959ac` is 4 off (0x381959A8; §6.6), and
    its §4 slot10 "LR-save slot" reading is not implied by any row (slot10 = 0x38962ae0, a pointer).
    The supplement's C1/C2/C4/C5 conclusions agree with this document's independent reading.

13. **`docs/1033-design.md` §0.2 and `records/1033-reading.txt:19-20`** claim `lr_slot` supplies the
    carrier-naming conjunct of EVF-U1-TRUE and that it "decodes as a real call-return"; the shipped
    patcher makes it a read-success bit (§7 D4) and the capture's word is not a call (§6.6). The banner in
    `docs/1033-design.md:8-17` rests on "the halfword at 0x37C26474 is 0x0224" which the card denies (§7 D3).
14. **`records/1033-reading.txt:20`** "lr_slot … a real call-return" repeated from the header; see D13.
15. **`tools/check_1033_capture.py` `self_test()` prints "SELFTEST PASS (13 fixtures, every cell fires)"**;
    run for this document it prints **14** `ok` lines (15 `expect(` call sites, one on a guard path), so
    the count string is stale-or-arbitrary — a claim in a string, not a check. And two cells are not
    exercised at all: **EVF-U2-SLIDE0 and EVF-U2-MISTAKE are unreachable on any real capture** because
    the slide they need (`nav=`, line 122) is never printed (§7 D1); the fixtures at lines 266/313 that
    "fire" them build the impossible row by hand.
16. **`docs/1033-design.md:555-571` (§8)** pre-registers `evf_cachemap_slide=0x03921000` and a
    "K − S = 0x0BE05474" that is neither a cache-file offset under map0 (`K − S` with S slid makes no sense
    for a SLID pc) nor checkable: the row and the `nav=` line it predates never appeared. A prediction whose
    row cannot exist is not a prediction.
17. **`docs/1033-design.md:209` row `xnu_live_evf_cachemap_slide … absent ⇒ row absent`** and
    `tools/check_1033_capture.py:43-52` `EVF_KEYS` omits it: the design's row set and the checker's key set
    differ by exactly the rows whose absence the design allows (walk_*, cachemap_slide). Group integrity
    (the 1030 key-count defect) is only as good as the key list; this one splits nothing because the rows
    are never emitted — but it means the 1033 checker cannot detect a build where the block printed the
    design's rows and not the patcher's.
18. **`src/entry/build_entry.sh:2139`** `STAGE90_XNU_TREE_D13)` closes the array (D11); harmless today, a
    mis-insertion hazard for 1034 (§2.6). Not a defect of 1033, recorded because 1034 edits next to it.
19. **The committed `records/1033-capture-supplement.txt` (not listed in the brief) reads r8's libobjc
    identity from byte offsets whose card content at the claimed base is ASCII prose** (§6.5): identity-by-
    offset is fine as a hypothesis; it is not a header check. 1034 does not use it for any cell.

20. **The static lane's `records/1034-carrier-static.txt`** has two byte claims that are false for the files
    on this host (§6.9b: rootfs byte 0 IS the cache header; the E1a anchor IS present in the pristine
    copies; rootfs @ 0x10183720 = `00 21 b1 eb …`, not `84 97 2b 30 …`), and it treats one cache file as
    one plane (§6.9b/6.9c). Its layout census (§2) and its C1-arithmetic are consistent with this
    document; its bytes are not adopted.
