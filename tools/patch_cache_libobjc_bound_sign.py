#!/usr/bin/env python3
"""1040 -- libobjc's alloca bound is checked UNSIGNED, so a -1 sails into it.

THE FACT THIS EDITS.  In `libobjc.A.dylib` (inside the dyld shared cache the card serves):

    37c2641e  bl    0x37c26698
    37c26422  mov   r5, r0          <- the buffer bound IS this call's return value
    37c26424  cmp   r5, #1
    37c26426  bne.n 0x37c26448      <- != 1, so the two-buffer path below
    37c26448  movs  r0, #0
    37c2644a  cmp   r5, #2
    37c2644c  bcc.n 0x37c2648a      <- UNSIGNED "too small to bother"; -1 does NOT take it
    37c2644e  sub.w r4, sp, r5, lsl #2
    37c26456  sub.w r6, sp, r5, lsl #2   <- alloca of `r5` words
    37c26464  bl    0x37c266ec           <- fills the buffers
    37c2646e  ldr.w r1, [r6, r0, lsl #2]
    37c26474  ldrb  r1, [r1, #16]        <- THE FAULT

With `r5 = -1`, `r5 lsl #2` is 0xfffffffc and subtracting it ADDS 4, so `r6` ends up equal to `sp`.
That is not a guess: the captured frame has `sp == r6 == 0x2bddf088` and `r5 == 0xffffffff`. The
buffer does not exist, the loop walks it, picks a word that happens to be 0, and reads address 0x10.

THE EDIT (2 bytes at cache file offset 0x0BC2644C = VA 0x37C2644C = card offset 0x1004C44C):
    OLD  d3 1d    bcc.n 0x37c2648a     (unsigned: the "too small" exit)
    NEW  db 1d    blt.n 0x37c2648a     (signed:   negative counts take it too)

    `cmp r5,#2; bcc` becomes `cmp r5,#2; blt` - the conditional's opcode nibble changes from `3`
    (unsigned CC) to `b` (signed LT). The displacement and the target are untouched.

WHY THESE TWO BYTES AND NOT A GUESS
  * r5 in {0, 1} -> jumps, exactly as before (0 and 1 are < 2 signed as they were unsigned).
  * r5 >= 2      -> falls through, exactly as before. The positive path is byte-identical.
  * r5 < 0       -> NOW jumps. That is the only behavioural change, and it is the case that faults.
  Nothing else reads this flag: the block at 0x37c2644e is entered only from 0x37c2644c.

WHAT IT DOES NOT DO.  It does not fix whatever produced a -1 bound - the capture does not carry that
frame, and 0x37c26698's two visible exits return 0 and 1. It stops the -1 from becoming an alloca,
which is the difference between a bounded return and a fault.

    tools/patch_cache_libobjc_bound_sign.py <card.img> [--check]
"""
import sys

# Card offset = the dyld cache's own start INSIDE the HFS image + the cache file offset.
# Found by searching the card for the cache magic "dyld_v1   armv7": the page-aligned hit at
# 0x0455D000 is the real one (a stray copy of the string sits at 0x04549F46), and
#   0x0455D000 + 0x0BC2644C = 0x1018344C
OFFSET = 0x1018344C
OLD = b"\x1d\xd3"            # halfword 0xd31d = bcc.n, as stored (little-endian)
NEW = b"\x1d\xdb"            # halfword 0xdb1d = blt.n, as stored


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 2
    path = argv[1]
    check = "--check" in argv[2:]
    with open(path, "r+b") as f:
        f.seek(OFFSET)
        got = f.read(2)
        if got == NEW:
            print("already patched: %s at 0x%08x" % (NEW.hex(), OFFSET))
            return 0
        if got != OLD:
            print("REFUSING: 0x%08x holds %s, expected %s or %s"
                  % (OFFSET, got.hex(), OLD.hex(), NEW.hex()))
            return 1
        print("0x%08x: %s (bcc.n) -> %s (blt.n)%s"
              % (OFFSET, OLD.hex(), NEW.hex(), "  [--check]" if check else ""))
        if not check:
            f.seek(OFFSET)
            f.write(NEW)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
