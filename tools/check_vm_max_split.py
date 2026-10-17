#!/usr/bin/env python3
"""Assert BY VALUE that the linked image's user-map ceiling IS (or is NOT) the 1 GiB TTBR0 split obtainable from
`task_create_internal`'s `vm_map_create` call -- rung 1024, switch `STAGE90_XNU_VM_MAX_SPLIT`.

WHY A SEPARATE TOOL.  The fix is a HEADER value (`osfmk/mach/arm/vm_param.h:66/:68`), so the ONLY place the
decision becomes a machine fact is the arithmetic the compiler emits at the ONE site that consumes it:
`task_create_internal`'s `vm_map_create(pmap, 0, VM_MAX_ADDRESS, TRUE, ...)`.  The build_1023/1024 pool
rebuild is a separate step from the ENTRY link (`build_entry.sh` only LINKS the pool objects), so a stale
or half-rebuilt pool silently keeps the OLD ceiling while every source-level check passes
(`records/1020-build-defect.txt`).  This tool reads the TWO instructions that decide it, out of the linked
image, in BOTH directions -- and the 1023 image is its OWN negative control.

WHAT IT READS.  Inside `task_create_internal` (measured: `0x80085c44 T task_create_internal`), the
non-fork arm does `bl pmap_create`, then materializes its three arguments (`mov r1,#0`, `mov r2,#<ceiling>`,
`mov r3,#1`) and `bl vm_map_create`:

    80085ce8:  ebfe99fb  bl  8002c4dc <pmap_create>
    80085cec:  e3a01000  mov r1, #0
    80085cf0:  e3a02102  mov r2, #-2147483648   ; 0x80000000   <<< VM_MAX_ADDRESS (OFF/CANCRO today)
    80085cf4:  e3a03001  mov r3, #1
    80085cfc:  ebfedac7  bl  8003c820 <vm_map_create>
    80085d04:  e5850018  str r0, [r5, #24]

So the ceiling is the immediate of the `mov r2, #...` that PRECEDES the `bl <vm_map_create>`, and this tool
resolves both ends by NAME from the ELF symbol table -- never a typed address -- then reads the instruction
words between them.  It requires (a) the `bl` targets exactly the symbol `vm_map_create`, (b) the closest
preceding `mov r2, #imm` (arm, or a `movw`/`movt` pair for any immediate not encodable in one ARM `mov`) is
the value it asserts, and (c) that value is read from an instruction whose PROVENANCE is the function body,
not a neighbouring literal pool.

  `--expect on`:  the ceiling word must read 0x40000000 (the 1 GiB split the hardware has, `set_mmu_ttbcr(2)`,
                  and the value `vm_param.h:64-65`'s own comment demands).  A MISSING symbol is a FAILURE.
  `--expect off`: the ceiling word must read 0x80000000 -- the tree's `#else` branch, i.e. the OFF (and
                  1023-press) shape.  This is the negative control: the shipped 1023 ELF must satisfy it.

The two modes assert disjoint values, so an ON image fails `--expect off` and vice versa.

  `--selftest`: build a real object with the host `arm-none-eabi` toolchain (a hand-written `.s` defines
                `task_create_internal`, `vm_map_create`, `pmap_create` and the `bl`-plus-`mov r2` sequence for
                a chosen ceiling), link it, and assert this tool's VERDICTS (exit codes) over a fixture matrix:
                ON-ceiling must PASS `--expect on` and FAIL `--expect off`; OFF-ceiling the reverse; a fixture
                with NO `vm_map_create` must FAIL both.

Exit 0 iff the requested expectation holds; nonzero on violation OR on refusal (a missing symbol, an
unreadable image, no `mov r2` before the call, an immediate that does not decode).
"""
import os
import re
import shutil
import subprocess
import sys
import tempfile

OBJDUMP = "arm-none-eabi-objdump"
NM = "arm-none-eabi-nm"
AS = "arm-none-eabi-as"
LD = "arm-none-eabi-ld"

TASK_FN = "task_create_internal"
VM_MAP_FN = "vm_map_create"

CEIL_ON = 0x40000000      # 1 GiB TTBR0 split -- what the port MUST emit with STAGE90_XNU_VM_MAX_SPLIT=1
CEIL_OFF = 0x80000000     # the tree's `#else` branch -- the OFF shape

_LINE = re.compile(r"^\s*([0-9a-f]+):\s+([0-9a-f]{8})\s+(\S+)\s*(.*)$")


def symbols(elf, names):
    """Return {name: addr} for the requested nm names; a missing name simply does not appear."""
    out = subprocess.run([NM, elf], capture_output=True, text=True)
    if out.returncode != 0:
        raise SystemExit(6)
    want = set(names)
    got = {}
    for line in out.stdout.splitlines():
        parts = line.split()
        if len(parts) == 3 and parts[2] in want and parts[1] in ("T", "t"):
            got[parts[2]] = int(parts[0], 16)
    return got


def disasm(elf, start, stop):
    """[(addr:int, word:int, mnem:str, ops:str)] for [start, stop) of the linked image."""
    out = subprocess.run([OBJDUMP, "-d", "--start-address", hex(start), "--stop-address", hex(stop), elf],
                         capture_output=True, text=True)
    if out.returncode != 0:
        raise SystemExit(6)
    rows = []
    for line in out.stdout.splitlines():
        m = _LINE.match(line)
        if m:
            rows.append((int(m.group(1), 16), int(m.group(2), 16), m.group(3), m.group(4).strip()))
    return rows


def _imm(ops):
    """Parse the `#imm` of an arm data-processing operand list; None if there is none."""
    m = re.search(r"#(-?(?:0x[0-9a-f]+|\d+))", ops)
    return None if not m else int(m.group(1), 16) if m.group(1).startswith(("0x", "-0x")) else int(m.group(1))


def ceiling_word(elf):
    """(value:int, addr:int) of the VM_MAX_ADDRESS immediate feeding `bl <vm_map_create>`, or raise."""
    syms = symbols(elf, [TASK_FN, VM_MAP_FN])
    if TASK_FN not in syms:
        raise LookupError(f"{TASK_FN} is not a defined function in {elf}")
    fn = syms[TASK_FN]

    # The function's own extent: the next symbol above it, else a bounded window.
    upper = None
    for line in subprocess.run([NM, elf], capture_output=True, text=True).stdout.splitlines():
        parts = line.split()
        if len(parts) == 3 and parts[1] in ("T", "t"):
            a = int(parts[0], 16)
            if a > fn and (upper is None or a < upper):
                upper = a
    if upper is None or upper - fn > 0x2000:
        upper = fn + 0x800

    rows = disasm(elf, fn, upper)

    # The `bl <vm_map_create>`: the target must be resolved through the symbol, not a typed address.
    if VM_MAP_FN in syms:
        target = syms[VM_MAP_FN]
    else:
        target = None
    cand = []
    for i, (addr, word, mnem, ops) in enumerate(rows):
        if mnem.startswith("bl") and not mnem.startswith("blx") and "<" in ops and ">" in ops:
            sym = ops[ops.rindex("<") + 1:ops.rindex(">")]
            if sym == VM_MAP_FN:
                cand.append(i)
        elif mnem.startswith("bl") and target is not None:
            m = re.search(r"([0-9a-f]+)", ops)
            if m and int(m.group(1), 16) == target:
                cand.append(i)
    if not cand:
        raise LookupError(f"no `bl {VM_MAP_FN}` inside {TASK_FN} ({elf})")
    call_i = cand[0]          # the non-fork arm is the FIRST such call (the fork arm calls vm_map_fork)

    # Walk BACKWARDS over the argument materialization, remembering movw/movt halves: the ceiling is the
    # `mov r2, #imm`.  arm `mov r2,#imm` encodes any single-byte-rotatable value; larger values arrive as
    # `movw r2,#lo` + `movt r2,#hi`.  Both shapes are read.
    lo = hi = None
    for i in range(call_i - 1, max(0, call_i - 12) - 1, -1):
        addr, word, mnem, ops = rows[i]
        if mnem in ("mov", "movs") and re.match(r"r2,\s*#", ops):
            v = _imm(ops)
            if v is not None:
                # objdump prints the OFF ceiling as `mov r2, #-2147483648	; 0x80000000` (the assembler
                # picks the rotatable single-`mov` encoding for 0x80000000 and 0x40000000 alike), so a
                # NEGATIVE immediate is a first-class spelling of the value under test, not a reject.
                return v & 0xFFFFFFFF, addr
        # NB the walk is BACKWARDS, so `movt` is seen BEFORE `movw`; the pair completes on whichever
        # half arrives second (the `movw` for the compiler's usual movw-then-movt order) and the
        # return must live in BOTH branches or the pair is silently dropped.
        if mnem == "movw" and re.match(r"r2,\s*#", ops):
            lo = _imm(ops)
            if lo is not None and hi is not None:
                return ((hi << 16) | (lo & 0xFFFF)) & 0xFFFFFFFF, addr
        if mnem == "movt" and re.match(r"r2,\s*#", ops):
            hi = _imm(ops)
            if lo is not None:
                return ((hi << 16) | (lo & 0xFFFF)) & 0xFFFFFFFF, addr
    raise LookupError(f"no `mov r2,#ceiling` materialization before `bl {VM_MAP_FN}` in {TASK_FN} ({elf})")


ASM = """
        .syntax unified
        .arm
        .text
        .globl pmap_create
pmap_create:
        bx lr
@TARGET_DEF@        .globl task_create_internal
task_create_internal:
        push {r4, r5, lr}
        bl pmap_create
        mov r1, #0
        @MATERIALIZE@
        mov r3, #1
        @CALL@
        pop {r4, r5, pc}
"""
TARGET_DEF = """        .globl vm_map_create
vm_map_create:
        bx lr
"""


def self_test():
    """Build real ELFs and assert the verdicts (exit codes) over the fixture matrix.

    The matrix covers BOTH spellings the compiler can emit for the two values under test -- a single
    rotatable `mov` (which is what the shipped 1023 image uses: `mov r2, #-2147483648`) and the
    `movw`/`movt` pair -- plus a wrong value and a fixture with no `vm_map_create` at all.  A selftest
    that cannot fail on a wrong value is not a selftest.
    """
    with tempfile.TemporaryDirectory(prefix="vm_max_split.elf.") as td:
        def build(name, materialize, has_target=True):
            s = os.path.join(td, name + ".s")
            o = os.path.join(td, name + ".o")
            e = os.path.join(td, name + ".elf")
            body = (ASM.replace("@TARGET_DEF@", TARGET_DEF if has_target else "")
                       .replace("@MATERIALIZE@", materialize)
                       .replace("@CALL@", "bl vm_map_create" if has_target else "nop"))
            with open(s, "w") as f:
                f.write(body)
            subprocess.run([AS, "-o", o, s], check=True, capture_output=True)
            subprocess.run([LD, "-Ttext=0x80000000", "-e", "task_create_internal", "-o", e, o],
                           check=True, capture_output=True)
            return e

        def mov_shape(imm):
            return "        mov r2, #0x%x" % imm

        def wt_shape(imm):
            return "        movw r2, #%d\n        movt r2, #%d" % (imm & 0xFFFF, (imm >> 16) & 0xFFFF)

        on_mov = build("on_mov", mov_shape(CEIL_ON))
        off_mov = build("off_mov", mov_shape(CEIL_OFF))
        on_wt = build("on_wt", wt_shape(CEIL_ON))
        off_wt = build("off_wt", wt_shape(CEIL_OFF))
        wrong = build("wrong", mov_shape(0x20000000))
        nope = build("nope", mov_shape(CEIL_ON), has_target=False)

        def verdict(elf, expect):
            try:
                v, _ = ceiling_word(elf)
            except LookupError:
                return 1
            return 0 if v == (CEIL_ON if expect == "on" else CEIL_OFF) else 1

        matrix = [
            (on_mov, "on", 0), (on_mov, "off", 1),
            (off_mov, "off", 0), (off_mov, "on", 1),
            (on_wt, "on", 0), (off_wt, "off", 0),
            (wrong, "on", 1), (wrong, "off", 1),
            (nope, "on", 1), (nope, "off", 1),
        ]
        bad = 0
        for elf, expect, want in matrix:
            got = verdict(elf, expect)
            tag = "ok " if got == want else "BAD"
            if got != want:
                bad += 1
            print(f"   selftest[{tag}] {os.path.basename(elf)} --expect {expect} -> exit {got} (want {want})")
        if bad:
            print(f"check_vm_max_split: SELFTEST FAILED ({bad} case(s))", file=sys.stderr)
            return 1
        print("check_vm_max_split: selftest PASS (mov + movw/movt spellings, wrong value, missing symbol)")
        return 0


def main() -> int:
    args = sys.argv[1:]
    if "--selftest" in args:
        return self_test()
    expect = None
    if "--expect" in args:
        i = args.index("--expect")
        expect = args[i + 1] if i + 1 < len(args) else None
    paths = [a for a in args if not a.startswith("--") and a != expect]
    if expect not in ("on", "off") or len(paths) != 1:
        print("usage: check_vm_max_split.py <elf> --expect on|off | --selftest", file=sys.stderr)
        return 2
    elf = paths[0]
    if not os.path.isfile(elf):
        print(f"check_vm_max_split: no such image: {elf}", file=sys.stderr)
        return 2
    try:
        v, addr = ceiling_word(elf)
    except LookupError as e:
        print(f"check_vm_max_split: REFUSING: {e}", file=sys.stderr)
        return 3
    want = CEIL_ON if expect == "on" else CEIL_OFF
    if v != want:
        print(f"check_vm_max_split: FAIL: {TASK_FN}'s `vm_map_create` ceiling at {addr:#x} reads "
              f"{v:#010x}, expected {want:#010x} for --expect {expect} "
              f"(VM_MAX_ADDRESS from vm_param.h:{'66' if expect == 'on' else '68'})", file=sys.stderr)
        return 4
    print(f"check_vm_max_split: PASS: {TASK_FN}'s vm_map_create ceiling at {addr:#x} reads {v:#010x} "
          f"(== {expect.upper()})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())