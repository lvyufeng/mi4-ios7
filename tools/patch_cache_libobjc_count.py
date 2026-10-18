#!/usr/bin/env python3
"""1032 -- THE COUNT CLAMP INSIDE libobjc, IN THE dyld SHARED CACHE THE CARD SERVES.

THE FACT THIS EDITS.  `libobjc`'s class-header reader and the table-rebase writer that faults share ONE
piece of arithmetic: `count = (int32)header_word >> 1` (`asrs r0,r2,#1`).  For the optimised class the
header word is INDEX_NOT_FOUND (0xFFFFFFFF) and `count` is -1 (records/1031-caller-derivation.txt (I)/(J),
re-read in the bytes at (S)).  The writer (fn 0x37C266EC) guards its copy loop with
    37c26720  movs r1,#0
    37c26722  cmp.w r1,r2,asr #1
    37c26726  it eq
    37c26728  popeq {r4-r7,pc}
i.e. it returns ONLY for count == 0, and falls through for count < 0 into a loop whose bound
`r0 = (count-1)` is UNSIGNED: ~2^32 stores.  The 1030 fault is that loop.

THE EDIT (10 bytes at cache file offset 0x0BC26720 = VA 0x37C26720 = card offset 0x10183720):
    OLD  00 21 b1 eb 62 0f 08 bf f0 bd   movs r1,#0 / cmp.w r1,r2,asr#1 / it eq / popeq {r4-r7,pc}
    NEW  50 10 01 28 01 da f0 bd c0 46   asrs r0,r2,#1 / cmp r0,#1 / bge.n .Lc / pop {r4-r7,pc} / nop
`.Lc` is the `add.w r0,r3,r0,lsl#3` at 0x37C2672A (+0xA), which the OLD code also fell through to.  So
    count <  0 -> POP   (was: run away -- THE FIX)
    count == 0 -> POP   (unchanged)
    count >= 1 -> add.w (unchanged; the positive path is byte-identical)
The bytes were produced by the assembler with a SYMBOLIC label (records (P), (S)); both hand-encodings got
the `bge` displacement wrong (`01`, not `00`/`02`).  `01` is relative to the `add` at +0xA.

THE MEDIUM.  `/usr/lib/libobjc.dylib` lives INSIDE the dyld shared cache embedded in the real iOS 7.1.2
HFSX rootfs at file offset 0x455D000 of `/mnt/data/ios7-payload/v2/ios7/rootfs.hfs`, and the card image the
press dd's to userdata's head is a byte-for-byte copy of that rootfs (`build_root_volumes.sh --real`).
Patch the CARD image: 0x455D000 + (0x37C26720 - 0x2C000000) = 0x10183720.  (map0 is
base 0x2C000000 / fileOffset 0, so cache file offset == VA - base -- verified in the cache header.)

WHY NOTHING REJECTS IT (records/1031-caller-derivation.txt (R)).  The kernel never reads a cache code page:
`vm_shared_region_slide_sanity_check` walks only the TOC, `vm_shared_region_map_file` checks only geometry,
and dyld's `mapSharedCache()` takes the in-memory-check branch ONLY when `shared_region_check_np` returns 0
(not the case once mapped); on the file path its checks are the 16-byte magic, `mappingOffset >= 0x48`, the
`(0x40,0x44)` slide-info pair (which we leave 0), and `fileOffset == page_round(size)` per mapping.  None
touches a code page.  libobjc carries no LC_CODE_SIGNATURE and the cache header has no code signature.

WHAT IT DOES NOT TOUCH.  No kernel source, no trap.c/kern_exec.c -- the pool/namespace machinery is not in
play.  The OFF state is the pristine rootfs; `--revert` restores those 10 bytes in place.

USAGE
    python3 -I tools/patch_cache_libobjc_count.py --check            # verify both sites agree with the map
    python3 -I tools/patch_cache_libobjc_count.py --apply            # OLD -> NEW (refuses unless OLD)
    python3 -I tools/patch_cache_libobjc_count.py --apply            # again: idempotent, reports ALREADY
    python3 -I tools/patch_cache_libobjc_count.py --revert           # NEW -> OLD (refuses unless NEW)
    python3 -I tools/patch_cache_libobjc_count.py --apply --image P  # operate on P instead of the card
    python3 -I tools/patch_cache_libobjc_count.py --selftest         # fixtures: every state is decisive
Exit: 0 on the requested state, 3 on a refusal (wrong bytes -- never a write), 2 on a usage error.
"""
import hashlib
import os
import struct
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
CACHE_VA_BASE = 0x2C000000
PATCH_VA = 0x37C26720
CACHE_OFF = PATCH_VA - CACHE_VA_BASE          # 0x0BC26720
ROOTFS_CACHE_OFF = 0x455D000                  # the cache's start inside the HFSX rootfs
CARD_OFF = ROOTFS_CACHE_OFF + CACHE_OFF       # 0x10183720

OLD = bytes.fromhex("0021b1eb620f08bff0bd")
NEW = bytes.fromhex("5010 0128 01da f0bd c046".replace(" ", ""))
assert len(OLD) == 10 and len(NEW) == 10, (OLD, NEW)

# ONE line on purpose: build_1032.sh derives the park-only copy from it (sed + the image argument made
# REQUIRED), and a wrapped literal would dodge the sed and ship a park copy with a live default path.
DEFAULT_IMAGE = os.path.join(_HERE, "..", "out", "stage90", "xnu_card_hfs.img")

# The instructions the two sides must decode to -- asserted in the selftest via the bytes themselves, so a
# copy-paste error in OLD/NEW cannot pass.  (halfwords, little endian)
OLD_HW = [0x2100, 0xEBB1, 0x0F62, 0xBF08, 0xBDF0]
NEW_HW = [0x1050, 0x2801, 0xDA01, 0xBDF0, 0x46C0]


def rd(path, off, n):
    with open(path, "rb") as f:
        f.seek(off)
        b = f.read(n)
    if len(b) != n:
        raise SystemExit("patch_cache_libobjc_count: %s is shorter than offset %#x + %d -- not the card image" % (path, off, n))
    return b


def state_at(b):
    if b == OLD:
        return "OLD"
    if b == NEW:
        return "NEW"
    return "OTHER"


def apply_one(path, dry):
    b = rd(path, CARD_OFF, 10)
    s = state_at(b)
    print("  %s\n    offset %#x: %s -> %s  [%s]" % (path, CARD_OFF, b.hex(" "), NEW.hex(" "), s))
    if s == "NEW":
        print("    ALREADY PATCHED (idempotent no-op).")
        return 0
    if s != "OLD":
        print("    REFUSING: the 10 bytes are neither the 1031 OLD guard nor the 1032 NEW guard.  This is not\n"
              "    a rootfs this rung was written against (or it was half-written); NOT touching it.", file=sys.stderr)
        return 3
    if not dry:
        with open(path, "r+b") as f:
            f.seek(CARD_OFF)
            f.write(NEW)
            f.flush()
            os.fsync(f.fileno())
        back = rd(path, CARD_OFF, 10)
        if back != NEW:
            print("    FAIL: wrote NEW but read back %s" % back.hex(" "), file=sys.stderr)
            return 1
        print("    wrote; read back %s" % back.hex(" "))
    return 0


def revert_one(path, dry):
    b = rd(path, CARD_OFF, 10)
    s = state_at(b)
    print("  %s\n    offset %#x: %s -> %s  [%s]" % (path, CARD_OFF, b.hex(" "), OLD.hex(" "), s))
    if s == "OLD":
        print("    ALREADY PRISTINE (idempotent no-op).")
        return 0
    if s != "NEW":
        print("    REFUSING: the 10 bytes are not the 1032 NEW guard; there is nothing this script put\n"
              "    here to take back.  NOT touching it.", file=sys.stderr)
        return 3
    if not dry:
        with open(path, "r+b") as f:
            f.seek(CARD_OFF)
            f.write(OLD)
            f.flush()
            os.fsync(f.fileno())
        back = rd(path, CARD_OFF, 10)
        if back != OLD:
            print("    FAIL: wrote OLD but read back %s" % back.hex(" "), file=sys.stderr)
            return 1
        print("    wrote; read back %s" % back.hex(" "))
    return 0


def check(path):
    """Independent reads of the two facts the offset arithmetic rests on."""
    ok = True
    card = path
    # (1) the card is the real rootfs (header HFSX) -- the cache lives in it, so the offset is meaningful
    hd = rd(card, 1024, 2)
    print("  [1] card header signature at volhdr +0x400 = %s (HFSX = 48 58)" % hd.hex(" "))
    ok &= hd == bytes.fromhex("4858")
    # (2) the cache inside the card carries the dyld magic at the offset the rootfs map declares
    mag = rd(card, ROOTFS_CACHE_OFF, 16)
    print("  [2] cache magic at card %#x = %r (dyld_v1   armv7)" % (ROOTFS_CACHE_OFF, mag))
    ok &= mag.startswith(b"dyld_v1")
    # (3) map0 is base 0x2C000000 / fileOffset 0 and OUR VA LIES INSIDE ITS DECLARED EXTENT.  iOS7
    # mapping_info is BY VALUE {vmaddr u64, size u64, fileOffset u64, maxProt u32, initProt u32} = 32 B
    # (read off the header and confirmed by the extents tiling the cache with no gap and ending at EOF).
    moff = struct.unpack("<I", rd(card, ROOTFS_CACHE_OFF + 0x10, 4))[0]
    mcnt = struct.unpack("<I", rd(card, ROOTFS_CACHE_OFF + 0x14, 4))[0]
    m = struct.unpack("<QQQII", rd(card, ROOTFS_CACHE_OFF + moff, 32))
    inside = m[0] <= PATCH_VA and PATCH_VA + 10 <= m[0] + m[1] and m[2] == 0
    print("  [3] map0: vmaddr=%#x size=%#x file_offset=%#x -> [%#x,%#x);  VA %#x inside: %s"
          % (m[0], m[1], m[2], m[0], m[0] + m[1], PATCH_VA, inside))
    ok &= (m[0] == CACHE_VA_BASE and m[2] == 0 and inside)
    # (4) the cache carries NO code signature -- the header's 0x30/0x34 pair, and libobjc has no LC_CODE_SIG
    cs_off = struct.unpack("<I", rd(card, ROOTFS_CACHE_OFF + 0x30, 4))[0]
    cs_size = struct.unpack("<I", rd(card, ROOTFS_CACHE_OFF + 0x34, 4))[0]
    print("  [4] cache codeSignatureOffset=%#x codeSignatureSize=%#x (both 0 => unsigned)" % (cs_off, cs_size))
    ok &= (cs_off == 0 and cs_size == 0)
    # (5) our VA lies inside libobjc's __TEXT __text (addr 0x37c13000 size 0x138f0)
    in_text = 0x37C13000 <= PATCH_VA and PATCH_VA + 10 <= 0x37C13000 + 0x138F0
    print("  [5] VA %#x .. %#x inside libobjc __text [0x37c13000,0x37c268f0): %s" % (PATCH_VA, PATCH_VA + 10, in_text))
    ok &= in_text
    b = rd(card, CARD_OFF, 10)
    print("  [6] patch site = %s" % b.hex(" "))
    return ok


def selftest():
    """The three states are distinguishable and OLD/NEW decode to the instructions the design names."""
    def hw(bs):
        return list(struct.unpack("<5H", bs))
    cases = [(OLD, "OLD"), (NEW, "NEW"), (b"\0" * 10, "OTHER")]
    for b, want in cases:
        got = state_at(b)
        print("  state(%s) = %s" % (b.hex(), got))
        if got != want:
            print("SELFTEST FAIL: bytes %s read as %s, want %s" % (b.hex(), got, want), file=sys.stderr)
            return 1
    if hw(OLD) != OLD_HW or hw(NEW) != NEW_HW:
        print("SELFTEST FAIL: halfword decode %s / %s != %s / %s"
              % ([hex(x) for x in hw(OLD)], [hex(x) for x in hw(NEW)],
                 [hex(x) for x in OLD_HW], [hex(x) for x in NEW_HW]), file=sys.stderr)
        return 1
    print("  OLD decodes: movs r1,#0 / cmp.w r1,r2,asr#1 / it eq / popeq {r4-r7,pc}")
    print("  NEW decodes: asrs r0,r2,#1 / cmp r0,#1 / bge.n +0xa / pop {r4-r7,pc} / nop")
    print("  the MUTANT (nothing at the site) reads OTHER, not OLD -- the check can fail.")
    return 0


def main(argv):
    if "--selftest" in argv:
        return selftest()
    image = DEFAULT_IMAGE
    for i, a in enumerate(argv):
        if a == "--image":
            image = argv[i + 1]
    image = os.path.normpath(image)
    if not os.path.exists(image):
        print("patch_cache_libobjc_count: %s does not exist (run tools/build_root_volumes.sh --real)" % image, file=sys.stderr)
        return 2
    if "--check" in argv:
        ok = check(image)
        print("  %s" % ("CHECK OK" if ok else "CHECK FAILED"))
        return 0 if ok else 1
    if "--apply" in argv:
        return apply_one(image, "--dry-run" in argv)
    if "--revert" in argv:
        return revert_one(image, "--dry-run" in argv)
    print(__doc__.split("USAGE")[1].split("Exit:")[0], file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))