# 1017 — NAMING THE SHARED-CACHE FRONTIER: what is at `pc = 0x3b04aa54`

Method: read-only. No build, no press, no device action, no write to `out/stage90`. One file written
(this one). Extractors run from `/tmp` (outside the repo). Every value is a machine reading with the
command shown; anything not measured is marked `# UNMEASURED`.

The rung it answers: `records/1016a-read.txt` (commit `dbe6793`) placed the interrupted pid-1 frame at
`pc = 0x3b04aa54`, `cpsr = 0x20000030` (USR/Thumb), identical across 5 stall samples. Its §6 asked
1017 to name the shared-cache image/symbol at that pc and classify the spin.

---

## 0. RESULT IN ONE LINE

`0x3b04aa54` resolves to file offset `0x0c23aa54` of the dyld shared cache, which is **offset `0x1a54`
of `/usr/lib/system/libsystem_platform.dylib`** (`__TEXT`), inside the local function
**`__os_alloc_slow`** (symbol `0x3823a94c`). The instruction byte pair there is **`fe de` = Thumb
`udf #254`** — a trap, at the tail of that function, reached only when its `_mach_vm_map` call returns
`!= KERN_SUCCESS`. It is **not** a lock CAS loop, not a countdown, not a self-referential store
(§3): it is the compiler's `udf` (trap) instruction. What the liveness means is stated carefully in
§3 — the sampler shows the pc, not the mechanism.

---

## 1. EXTRACTION — the method, and its independent verification

### 1.1 Precedent, re-measured
A prior line of work already extracted both `/usr/lib/dyld` (196,576 B) **and** the full shared cache.
The artifacts are on disk:

```
$ ls -l /tmp/dyld-extract/
-rw-rw-r-- 1 lvyufeng lvyufeng    196576 Sep 29 12:24 dyld
-rw-rw-r-- 1 lvyufeng lvyufeng 315952666 Sep 29 12:24 dyld_shared_cache_armv7
```

`315952666` = the size the prompt names (301 MiB / `0x12d50e1a`), and `196576` is exactly the
`/usr/lib/dyld` size at `records/1003-stall-forensics-preliminary.txt:209`. So this is the same
extraction method 1003 used.

### 1.2 The cache is contiguous in the image at raw offset `0x455d000` — verified, not assumed
The reference study (`docs/reference/d13-dyld-shared-cache-study.md` §1) recorded the cache at file
offset `0x455d000` of `/mnt/data/ios7-payload/v2/ios7/rootfs.hfs`. That is measured here **end to
end** — the whole 315,952,666-byte slice is byte-identical to the extracted file, not just its head:

```
$ python3 -I - <<'EOF'
import hashlib
p='/mnt/data/ios7-payload/v2/ios7/rootfs.hfs'; off=0x455d000; size=315952666
h=hashlib.sha256(); f=open(p,'rb'); f.seek(off); rem=size
while rem>0:
    b=f.read(min(rem,1<<22))
    if not b: break
    h.update(b); rem-=len(b)
print('rootfs slice sha256', h.hexdigest())
print('extracted   sha256', hashlib.sha256(open('/tmp/dyld-extract/dyld_shared_cache_armv7','rb').read()).hexdigest())
EOF
rootfs slice sha256 cad2df775e122c660238f341e74c163a2ea0ed261e85bfd3190de750cd9c0d2c
extracted   sha256 cad2df775e122c660238f341e74c163a2ea0ed261e85bfd3190de750cd9c0d2c
```

**MATCH.** Method = a raw byte-range read at `0x455d000`: the file's first data-fork extent begins
there and the extent is contiguous for its whole length (proven by the full-length hash, which would
diverge on the first out-of-order extent). No HFS B-tree walk was needed — the offset was already a
recorded measurement, and the hash confirms it is the right one. The extracted copy is what every
reading below uses; it is byte-for-byte the shipped file.

### 1.3 Header, re-read from the extracted file (matches the study's cells)
```
magic                b'dyld_v1   armv7'      imagesCount      696 (0x2b8)
mappingOffset/count  0x68 / 3                dyldBaseAddress  0x2be00000
imagesOffset/count   0xc8 / 696              codeSignatureOffset 0x12bda000 (size 0)
uuid                 52d48b54f455394f8c84732df0ae4ac9
```
The image table entry is **32 bytes**: `{u64 address, u64 modTime, u64 inode, u32 pathFileOffset,
u32 pad}` (pathFileOffset is a u32 at `+0x18`; the study's "u64 pathFileOffset" was an
over-宽 read — the low word is the file offset and it indexes the cstring correctly).

---

## 2. RESOLVING THE ADDRESS

### 2.1 The arithmetic, re-derived (not trusted)
```
$ python3 -I -c "..."
slide  from map0 (0x2ee10000 - 0x2c000000) = 0x2e10000
slide  from map1 (0x3b078000 - 0x38268000) = 0x2e10000      # two independent derivations agree
unslid VA           = 0x3b04aa54 - 0x2e10000 = 0x3823aa54
cache FILE offset   = 0x3823aa54 - 0x2c000000 = 0x0c23aa54
```
`0xc23aa54` lies in mapping 0's file range `[0x0, 0x0c266000)` (artifact map[0] `off=0 size=0x0c266000`)
— confirmed. The prompt's arithmetic is correct; this re-derives it from the capture's own geometry
rows (`IOS7LAB cache mapping 0/1`, capture `:4105`,`:4106`), not from a memory of 1016-A.

⚠ The capture lists **4** mappings (`:4105-4108`), init_prot `5,23,1,1`. 1016-A quoted only 2. The
spin's pc is in mapping 0 (`init=5`, `r-x`) either way; §4 of this doc uses all four.

⚠ **The `VA − 0x2c000000` shortcut is NOT a general rule** (corrected 2026-10-17, reader1029). It
equals `fileOffset + (VA − map.address)` ONLY because the VA here is in **map0**, whose
`fileOffset == 0` and `address == 0x2c000000`. It breaks silently for any VA in map1/map2 (map1
`[0x38268000..0x39f48000)` has `fileOffset 0xc266000`) and it is invalid on a **slid** VA. Always
resolve through the cache's own mapping table:
`file_offset(v) = map[i].fileOffset + (v − map[i].address)` for the `i` with `map[i].address ≤ v <
map[i].address + map[i].size`. VERIFIED against the header (map0 `[0x2c000000..0x38266000)` off 0,
map1 `[0x38268000..0x39f48000)` off 0xc266000, map2 `[0x39f48000..0x3c235000)` off 0xdf46000):
`0x3823aa54 → 0xc23aa54` ✓ (this doc's pair, in map0) and `0x37c26756 → 0xbc26756` ✓ (1029's fault
pc, also map0).

### 2.2 Which image — by value, from the image table
Decoding the 696-entry table at `imagesOffset 0xc8` (VA-sorted) and binary-searching `0x3823aa54`:

```
0x38231000  /usr/lib/system/libsystem_notify.dylib
0x38239000  /usr/lib/system/libsystem_platform.dylib     <-- contains 0x3823aa54
0x3823f000  /usr/lib/system/libsystem_pthread.dylib
```
**Image: `/usr/lib/system/libsystem_platform.dylib`** (Mach-O at cache file offset `0xc239000`,
`magic 0xfeedface`). Offset into image = `0x3823aa54 - 0x38239000 = 0x1a54`, inside its `__TEXT`
(`vmaddr 0x38239000 size 0x6000 fileoff 0`).

### 2.3 Which symbol — the cache's own local-symbols table
The cache carries `localSymbolsInfo` (`u64 @ 0x48`): `offset 0x10233000 size 0x29a6a80`;
sub-header `nlistOffset 0x1e48, nlistCount 790345, stringsOffset 0x90d5b4`. Searching all 790,345
local nlists for value `0x3823a94c`:

```
FOUND local sym idx 789270 val 0x3823a94c name b'__os_alloc_slow'
```

The enclosing function is **`__os_alloc_slow`** (also `__os_alloc` at `0x3823a8e8`; its neighbours
`__os_lock_handoff_lock/trylock/unlock` at `0x3823abc8`/`0x3823ab08`/`0x3823ab34`). Note the
function-start table (`LC_FUNCTION_STARTS`, dataoff `0xf792a54`) decodes this start as `0x3823a94d`
— exactly **symbol + 1**, because a function-start encodes the **Thumb bit** (bit0). (Verified: every
one of the first 8 decoded starts equals a symbol value `+1`, and none equals a symbol value.) The
true code address is `0x3823a94c` (even), and target `0x3823aa54` is offset `0x108` into it.

> ⚠ HONESTY NOTE ON <redacted>: the local-symbol string table of this cache contains the literal
> 10-byte ASCII string `<redacted>` (bytes `60 72 65 64 61 63 74 65 64 3e`, verified as raw byte
> integers and again directly in `rootfs.hfs` at `0x13ec342a`). **125 of the 270** global/external
> symbols of this image share strx `0x46a` → that one string. So the image's local names are
> (largely) pinned out of this artifact; `__os_alloc_slow` survived because it is a *local* symbol
> reached via the cache's separate `localSymbolsInfo` strings, not the image string table. This is a
> fact about the shipped file, not a redaction by my tooling.

### 2.4 The instruction — the file bytes
```
$ python3 -I ... (hexdump of the cache at 0x3823aa40..0x3823aa60)
3823aa40  08 44 0e 46 08 30 d2 d0 a7 f1 18 04 a5 46 bd e8
3823aa50  00 0d f0 bd fe de c0 46 44 f2 c0 50 44 f2 21 02
                       ^^^^^ = offset 0x3823aa54
```
The halfword at `0xc23aa54` is **`fe de` → `0xdefe`** (little-endian).

### 2.5 Disassembly window (Thumb)
```
$ arm-none-eabi-objdump -D -b binary -m arm -M force-thumb --adjust-vma=0x3823a94c /tmp/osalloc.bin
3823a94c: b5f0        push    {r4, r5, r6, r7, lr}      <-- __os_alloc_slow (Thumb bit set)
3823a94e: af03        add     r7, sp, #12
3823a950: e92d 0d00   stmdb   sp!, {r8, sl, fp}
3823a954: b08c        sub     sp, #48
...
3823a95e: 4606        mov     r6, r0
3823a960: f244 609a   movw    r0, #0x469a             ; _os_alloc_ring slot (per-image data)
3823a964: f2c0 10d0   movt    r0, #0x1d0
...
3823a986: f8da 0000   ldr.w   r0, [sl]
3823a9aa: f003 ee9c   blx     0x3823e6e4              ; -> PIC stub = _mach_vm_map
3823a9ae: 2800        cmp     r0, #0
3823a9b0: d150        bne.n   0x3823aa54             ; <== vm_map FAILED -> trap   (1st site)
3823a9b2: f644 1b26   movw    fp, #0x4926
3823a9b6: f2c0 1bd0   movt    fp, #0x1d0
3823a9ba: 44fb        add     fp, pc
3823a9bc: 980a        ldr     r0, [sp, #40]
3823a9be: e85b 1f00   ldrex   r1, [fp]                ; ---- CAS retry loop on the bump pointer ----
3823a9c2: 42b1        cmp     r1, r6
3823a9c4: d130        bne.n   0x3823aa28
3823a9c6: e84b 0100   strex   r1, r0, [fp]
3823a9ca: 2900        cmp     r1, #0
3823a9cc: d1f7        bne.n   0x3823a9be             ; <- inner CAS loop (bounded, succeeds)
...
3823aa1e: f003 ee62   blx     0x3823e6e4              ; -> _mach_vm_map (second call)
3823aa22: 2800        cmp     r0, #0
3823aa24: d0ca        beq.n   0x3823a9bc
3823aa26: e015        b.n     0x3823aa54             ; <== vm_map FAILED -> trap   (2nd site)
3823aa28: 990a        ldr     r1, [sp, #40]
3823aa2a: f44f 5380   mov.w   r3, #4096
3823aa30: f8da 0000   ldr.w   r0, [sl]
3823aa36: f003 ee4e   blx     0x3823e6d4              ; -> PIC stub = _mach_vm_deallocate
...
3823aa48: f1a7 0418   sub.w   r4, r7, #24
3823aa4c: 46a5        mov     sp, r4
3823aa4e: e8bd 0d00   ldmia.w sp!, {r8, sl, fp}
3823aa52: bdf0        pop     {r4, r5, r6, r7, pc}    ; <-- normal return of __os_alloc_slow
3823aa54: defe        udf     #254                   ; <== THE SAMPLED PC
3823aa56: 46c0        nop
3823aa58: f244 50c0   movw    r0, #0x45c0            ; (next function: _OSAtomicCompareAndSwap32Barrier)
```
The two `blx` targets resolve through the image's `__picsymbolstub4` indirect table to
**`_mach_vm_deallocate`** (`stub 0x3823e6d4`, pic idx 58) and **`_mach_vm_map`** (`stub 0x3823e6e4`,
pic idx 59) — resolved from `indirectsymoff/nindirectsyms` + the symbol table, not guessed.

---

## 3. CLASSIFYING THE SPIN

### 3.1 The instruction is a trap, not a loop body
`0xdefe` decodes as Thumb **`udf #254`** — the permanent-undefined encoding compilers emit for
`__builtin_trap()` / an unreachable/`abort` fallthrough. **It is not any of the four candidates in
the brief:**

| brief's candidate | verdict |
|---|---|
| (a) lock/atomic CAS retrying on itself | **No.** The CAS loops exist *above* it (`ldrex/strex` at `0x3823a9be` and `0x3823a9d6`) and they are bounded, self-resolving `strex` retries, not the trapped pc. |
| (b) bounded-but-huge countdown | **No.** No subtract-and-branch at `0x3823aa54`; it is a single `udf`. |
| (c) compare that never satisfies | **No.** The compares (`cmp r0,#0` at `0x3823a9ae`/`0x3823aa22`) *guard* the branch here; the branch target is the trap. |
| (d) self-referential store | **No.** No store at `0x3823aa54`. |

### 3.2 What the code path is (measured, not inferred)
`__os_alloc_slow` is the slow path of `os_alloc`: it maps an `os_alloc_ring` page with
**`_mach_vm_map`** (`blx 0x3823e6e4`), and if that returns **`!= 0`** it branches to the `udf`. The
`udf` at `0x3823aa54` is the **shared tail target of both `_mach_vm_map` failure checks**
(`bne.n 0x3823aa54` at `0x3823a9b0`; `b.n 0x3823aa54` at `0x3823aa26`). On the success path the
function returns normally at `0x3823aa52` and never reaches `0x3823aa54`.

### 3.3 What the stall sampler actually witnesses
The sampler records the interrupted frame's `pc`/`cpsr` (`src/entry/entry_stubs.c:4607-4664`). Five
samples read `pc = 0x3b04aa54`, `cpsr = 0x20000030` (USR, Thumb), `sp = 0x2bd2b400` (the capture's
own user stack for that run) — identical. Since the resident instruction there is `udf`, the faithful
statement is:

> **pid 1 is faulting on a user-mode `udf #254` at `0x3823aa54+slide`, and the `pc` is not advancing
> across the sampled ticks.** The instruction executed is a trap, not a documented spin loop.
> `# UNMEASURED`: which of the two mechanisms produces the identical pc — (i) the undefined-instruction
> handler returns to `0x3823aa54` and it re-traps forever, or (ii) an outer retry re-enters the same
> failure path — **cannot be decided from this capture.** The capture has no record keyed to
> `3b04aa54` other than the 5 stall samples (§5 null control), and `xnu_live_sleh_*` (the user-abort
> recorder) shows only *other* user pcs (`0x2beea058`, `0x8049xxxx`).

This is the same *shape* as the 1010–1015 finding — a fault re-executed at a constant pc — but here
in **user** mode at a **`udf`**, not a kernel abort on a bad PTE. The honest 1017 claim is the
naming + the instruction; the "why it never advances" is left as the explicit `# UNMEASURED` above.

### 3.4 Corroboration — the two failure sites share one trap address
The `udf` is a **single** instruction reached from both `_mach_vm_map`-failure branches, and there is
**one** `udf` immediately before the next function starts (`_OSAtomicCompareAndSwap32Barrier` at
`0x3823aa58`). A sampled pc that is the trap tail is consistent with `os_alloc`'s `_mach_vm_map`
having failed — i.e. **`__os_alloc_slow` was called and `_mach_vm_map` returned an error**, for a
user-space allocator (`os_alloc`/`malloc`), in pid 1. That is the load-bearing, checkable statement.

---

## 4. THE LOW NUMBERS — cross-checks

- **First capture in the line where pid 1 executes shared-cache code** (`records/1016a-read.txt` §5).
  Confirmed here by *what* the code is: `libsystem_platform`'s `os_alloc` slow path.
- **init_prot of mapping 0 = 5 (`r-x`)**. The spin is an **execute** (fetch) at a `__TEXT` address
  with `r-x` for both `max` and `init` (capture `:4105`) — so **not** a write/permission fault. The
  trap is a *code* `udf`, independent of mapping protection.
- **`sp = 0x2bd2b400`** lies in the region below the cache (`shared region 0x2c000000..0x40000000`;
  the *stack* is below `0x2be00000`, capture `:4098`) — consistent with a user stack, not the cache
  mapping. `# UNMEASURED`: the exact VMA name of `0x2bd2b400` (no map table is in this capture).
- **`lr = 0x00000007`** across all five samples is the sampler's dummy, per 1016-A §6 — not a return
  address; the direction of the pc is not readable from `lr`.

---

## 5. NULL CONTROL (guarding against a coincidental match)
Only `xnu_live_stall_pc` reads `0x3b04aa54` (5 occurrences, `grep -c 3b04aa54` = 5). The other two
`3b04…`-prefixed values in the capture are unrelated:
- `0x3b01f800` (`:26124`, `xnu_live_storage_drv_w1`) — a storage data word.
- `0x004a3823` — an LBA, its hex merely contains `3823`.
Neither is the sampled pc. The identification rests solely on the 5 stall samples.

---

## 6. EXACT COMMANDS (reproducible)

```bash
# (0) the cache was already extracted; verify it is byte-identical to the shipped image
python3 -I - <<'EOF'
import hashlib
p='/mnt/data/ios7-payload/v2/ios7/rootfs.hfs'; off=0x455d000; size=315952666
h=hashlib.sha256(); f=open(p,'rb'); f.seek(off); rem=size
while rem>0:
    b=f.read(min(rem,1<<22));  h.update(b);  rem-=len(b)
print(h.hexdigest())
EOF
# expect cad2df775e122c660238f341e74c163a2ea0ed261e85bfd3190de750cd9c0d2c  (== extracted file)

# (1) resolve address -> image -> symbol (parse cache header, image table, localSymbols)
#     -> /usr/lib/system/libsystem_platform.dylib, __os_alloc_slow @0x3823a94c, off 0x1a54

# (2) the instruction window
python3 -I -c "d=open('/tmp/dyld-extract/dyld_shared_cache_armv7','rb').read(); \
  open('/tmp/osalloc.bin','wb').write(d[0x3823a94c-0x2c000000:][:0x110])"
arm-none-eabi-objdump -D -b binary -m arm -M force-thumb --adjust-vma=0x3823a94c /tmp/osalloc.bin

# (3) the raw bytes at the sampled offset (independent of objdump)
python3 -I -c "d=open('/tmp/dyld-extract/dyld_shared_cache_armv7','rb').read(); \
  print(d[0xc23aa54:0xc23aa56].hex())"      # -> fede
```

Capture references (all in `out/stage90/captures/recovered-unknown-arm-20261015-163856-last_kmsg.txt`):
`:4098` shared region, `:4105-4108` the 4 cache mappings, `:33977-34007` the 5 stall samples
(`pc=0x3b04aa54 cpsr=0x20000030 sp=0x2bd2b400`).

---

## 7. WHAT THIS DOES AND DOES NOT CLAIM

- **Names, by value:** image `libsystem_platform.dylib`; function `__os_alloc_slow`; instruction
  `udf #254` at `+0x108`; reached from the `_mach_vm_map`-failure branches.
- **Reconciles with 1016-A:** the "user-space spin in the shared cache" is real as a *fact of the
  sampled pc*, but the instruction there is a **trap**, not a documented loop — so "spin" is a
  description of the observed pc invariance, not of a loop body. This corrects the *flavour* of
  1016-A §4/§6 (which guessed a lock/countdown/compare) while keeping its *identification*.
- **Does NOT claim** iOS 7 userspace is launched, nor that this trap is the run's only frontier, nor
  the mechanism by which the pc stays put (§3.3, `# UNMEASURED`).
- **Next rung (1018), suggested by the code, not asserted:** the frontier is now "pid 1's `os_alloc`
  slow path took the `_mach_vm_map` failure branch". A witness of that call's **return value and the
  map arguments** (`_mach_vm_map` r0 across the two `blx 0x3823e6e4` sites) would decide whether the
  allocator's ring mapping is being refused — the SHREG/`map_file` territory of 998, now reached from
  inside pid 1's own allocator.