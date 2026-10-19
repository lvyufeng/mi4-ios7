#!/usr/bin/env python3
"""Stage 995's dyld halt-message witness into the D13 tree's `osfmk/arm/trap.c`.

THE FAULT THIS ANSWERS, BY VALUE.  994's press (arm `armed-d13-8b4c9a3e`, commit `a4a2532`, evidence
`out/stage90/captures/cancro-last_kmsg-994-armed-d13-8b4c9a3e.txt`) moved the frontier exactly: the
trap-10 wire-width fix works (`IOS7LAB vm_allocate64 ... flags=1 result=0`, log:4101), so dyld's
`throwf` no longer dies in `__simple_salloc`'s out-of-memory path - it formats the REAL error and
throws it - and the boot then halts at `_dyld_fatal_error` (`udf #0xdefe`, pc 0x2be010c4 unslid, 235x
from log:4103).  The message `dyld::halt` was handed is a heap string in dyld's malloc pool (994:
r5 = `__ZL18initialPoolContent+0x11e0`), and NOTHING in this kernel can print it: the tree's own
reader for it (the LEO witness, `trap.c:71-126`) is compiled out on CANCRO
(`#if defined(BOARD_CONFIG_QSD8250_LEO)`).

WHAT IS READ, AND FROM WHERE (every step re-derivable from `/tmp/dyld_ios7` with
`llvm-objdump-14 --triple=thumbv7-apple-ios -d`; the tree's dyld is Thumb, and a plain `llvm-objdump
-d` decodes it as ARM and returns nonsense):

  * the kernel's `task->all_image_info_addr` IS dyld's own `gProcessInfo` struct.  Mach-O
    `__DATA,__all_image_info` is at 0x2be21c8c, size 0xa4, version 0x0e; `gProcessInfo` - the global
    POINTER at 0x2be21b1c - holds exactly that address (file bytes `8c 1c e2 2b`); and
    `bsd/kern/mach_loader.c:249` `note_all_image_info_section()` sets
    `result->all_image_info_addr = <section addr> + slide` (`:269`, `+slide` at `:268`), which is the
    value `trap.c:919-920` prints as `dyld_all_image_info_addr` (994: 0x2bed9c8c = 0x2be21c8c +
    slide 0xB8000).
  * `setAlImageInfosHalt` @ 0x2be08d04 is six instructions and writes exactly two fields:
    `ldr r3, [r2]` (r2 = 0x2be08d10 + 0x18e0c = 0x2be21b1c = &gProcessInfo), then
    `str r0, [r3, #32]`  -> **struct + 0x20 receives the message pointer**, and
    `str r1, [r0, #36]`  -> **struct + 0x24 receives the flags word**.
  * `dyld::halt` @ 0x2be01ebc: `dyld::log("dyld: %s\\n", msg)` (r0 = 0x2be01ece + 0x1aec6 = 0x2be1cd94,
    which is the cstring `"dyld: %s\\n"`); then `strlcpy(_error_string, msg, 1024)` (r4 =
    0x2be01ee4 + 0x47680 = 0x2be49564 = `_error_string`, `__DATA,__common`, 0x428 bytes); then
    `setAlImageInfosHalt(_error_string, byte ^ 1)` with the byte at 0x2be219f3 = 0x00 - which is why
    994's dump shows `r0 = r4 = _error_string` and `r1 = 1`; then `blx _dyld_fatal_error`.
  * so `A + 0x20` points at `_error_string`, a NUL-terminated copy of the message.  The witness never
    needs the pool string, and never dereferences a user pointer directly.
  * `_dyld_fatal_error` @ 0x2be010c4 is the four bytes `fe de ff e7` = `udf #0xdefe` = `0xfedeffe7`
    big-endian, i.e. EXACTLY the word `trap.c:877` tests (`instruction != 0xfedeffe7` returns early
    for every other undefined instruction).  Reaching the witness therefore already proves the trap is
    dyld's own fatal `udf` - which is why the LEO matcher's magic offsets (`state->pc == A-0x20bc8`,
    `state->r[0] == A+0x278d8`, `all_image_info_size == 0xa4`) are NOT carried over: they are the
    ADDRESSES of two symbols in one dyld build, and if either moves the LEO shape reports "not a
    halt" - a silent witness, the `mi4-silence-is-a-reading-only-if-success-is-silent` trap.  What
    replaces them is the value itself (`aii != 0`, `size >= 0x24`, and the copyin results printed on
    every branch).

TWO READS, ONE TEXT (rev 2, team-lead's dyld-log-sink ruling): at this trap the SAME text is live
under two pointers - `A + 0x20` (`_error_string`, the strlcpy'd 1024-byte copy) and `r5` (`dyld::halt`
keeps halt()'s argument in a callee-saved register across log/strlcpy/setAlImageInfosHalt, and
`_dyld_fatal_error` is a bare udf that clobbers nothing).  The witness prints BOTH and states whether
they are equal: unequal texts mean the field and the register do not describe the same halt, and that
is reported loudly, never skipped (`DIFFERS from errorMessage`).

THE r8 CLASSIFICATION (docs/reference/d13-dyld-halt-message-recovery.md 9.3, re-measured in
`___cxa_throw` 0x2be148c0-0x2be14902: `movw r0,#20039; movt r0,#17228` builds 0x434c4e47 and
`movw r0,#11008; movt r0,#17195` builds 0x432b2b00, stored at object-0x1C and object-0x20 via
`str r0,[r4,#-28]` / `str r0,[r6,#-32]!`).  r8 is inherited from an outer frame, and only three
readings of it land on something: the signature pair sits 0x20 BELOW the exception object pointer, or
0x30 ABOVE the block base, or r8 is inside the message text itself.  The witness tests the two
signature windows (a 16-byte copyin each) before falling through to a string probe, and reports an
all-zero/all-failing r8 as the stale value it then is.

REV 3 (996 - the 995 press measured this).  The 995 log
(`out/stage90/captures/cancro-last_kmsg-995-armed-d13-4efcabae.txt`, lines 4111-4120) shows the
witness firing and reading correctly - two slots, both pointers, `matches errorMessage`, the real
message `Library not loaded: /usr/lib/libbsm.0.dylib` - but TRUNCATED: the first `dyld> ` chunk
printed and the next two printed empty, because `ios7wit_lines` NULed `text[index + count]` in
place, which for every chunk but the last is the NEXT chunk's first byte.  Rev 3 saves and restores
that byte.  Rev 3 also reads the rest of the same dyld_all_image_infos struct (version 0x0e):
errorKind (+0x40) and the shared-cache words sharedCacheSlide (+0x50) / sharedCacheBaseAddress
(+0x64) - a zero cacheBase is dyld saying the shared cache was never mapped - plus dyld's own
referrer / target-dylib / symbol strings (errorClientOfDylibPath +0x44, errorTargetDylibPath +0x48,
errorSymbol +0x4c), each fail-soft with its own branch printed, inside the SAME rate-limited firing;
the size gate rises to 0x68.  The new offsets live only in `IOS7WIT_AI_*` constants (dyldtrace
confirms them by value off the pinned dyld in parallel - if a number moves, it moves there).

WHAT IS INSERTED (two chunks, both inside `#if defined(STAGE90_XNU_DYLD_WITNESS) &&
STAGE90_XNU_DYLD_WITNESS`):

  1. the witness function, after the LEO block's `/* IOS7LEO_DYLD_END */` (trap.c:126): its reads are
     `copyin(A + 0x20, &msgp, 4)`, `copyinstr(msgp, ..., 256, ...)`, `copyinstr(state->r[5], ...)`,
     the comparison of the two, the r8 probe above, and (rev 3) the six version-0x0e field reads
     (`IOS7WIT_AI_*`), printing `IOS7WITNESS dyld msg=...` /
     `IOS7WITNESS r5 msg=...` / `IOS7WITNESS r5 <verdict>` / `IOS7WITNESS r8=...` headers with
     `dyld> `, `dyld5> ` and `dyld8> ` text lines;
  2. the call, immediately after the `dyld_all_image_info_addr` printf's continuation line
     (trap.c:920) and before the LEO marker at :921 - the SAME path that prints A, so the witness's A
     and the printed A are one expression (`thread->task->all_image_info_addr`), and `arm_ctx` is the
     same saved state the register block above it printed.

BOUNDED AND FAIL-SOFT.  The halt re-executes forever (235 identical dumps in 994) and the OS console
capture block silently drops everything past 128 KiB (`src/entry/entry_stubs.c:2506`, drop at
`:2762-2770`), so the witness claims a print slot BEFORE any I/O and returns once `IOS7WIT_MAX_PRINTS`
(2) slots are gone: the remaining 233 traps cost one load and one compare each and print nothing.  No
branch panics, allocates, sleeps or dereferences a user address; an unmapped or hostile pointer can
only produce a copyin error return, which is printed (`<no message pointer>` / `<copyinstr failed>` /
the `stale` line).

OFF IS BYTE-IDENTICAL, and this is proven with the REAL PREPROCESSOR over the WHOLE FILE before a
single byte is written: four `clang -E -P` runs (HEAD, staged with the switch undefined, staged with
`=0`, staged with `=1`) must give three identical outputs and a fourth, different one that is the only
one containing the witness.  Includes resolve through empty placeholder headers, and that is faithful
here because trap.c's OWN conditional directives evaluate only `BOARD_CONFIG_QSD8250_LEO`,
`BOARD_CONFIG_ARMPBA8`, `STAGE90_XNU_DYLD_WITNESS` and the literal `0` - the script scans them and
REFUSES the proof, writing nothing, if that set ever grows, rather than certifying a property it can
no longer see.  `defined()` is written FIRST in the gate, so an unset switch never evaluates the
identifier (`mi4-off-option-two-spellings`).

Idempotent, text based (`mi4-an-edit-on-a-prefix-deletes-the-suffix`: the two chunks are PREFIXES of
nothing, but the markers are, so the file is searched for the chunk text itself and for an exact
marker count, never by substring replacement of a line that the patch also writes).  Both anchors are
found by an exact two-line window with an asserted count of 1, every gate is decided before anything
is written, a partial or foreign edit is REFUSED with the file untouched, a file still carrying an
OLDER revision's chunks (markers present, chunks different) is RE-STAGED - the marker-bounded
regions are removed and the current chunks inserted - and a second run prints "nothing to do".  `--dry-run` decides and proves without writing; `--verify-off` runs the proof
alone - which is how this tool can be exercised on a tree it must not edit.
"""
import re
import subprocess
import sys
import tempfile
from pathlib import Path

REL = "osfmk/arm/trap.c"

# The file this patch was written for, by content - not by name.
IDENTITY = "void sleh_undef(arm_saved_state_t * state)"
IDENTITY2 = "dyld_all_image_info_addr: 0x%08x   dyld_all_image_info_size: 0x%08x"

SWITCH = "STAGE90_XNU_DYLD_WITNESS"
GATE = f"#if defined({SWITCH}) && {SWITCH}"

MARK = "/* IOS7WITNESS_BEGIN */"

# Anchor 1: the block goes between the LEO block's closing marker and the enum that follows it
# (trap.c:126-127).  `/* IOS7LEO_DYLD_END */` alone occurs 6 times; this window occurs once.
BLOCK_ANCHOR = "/* IOS7LEO_DYLD_END */\ntypedef enum {"
# Anchor 2: the call goes after the dyld_all_image_info_addr printf's continuation line (trap.c:920)
# and before the LEO marker at :921.  The continuation line alone occurs 3 times
# (trap.c:567/:670/:920); this window occurs once.
CALL_ANCHOR = ("thread->task->all_image_info_addr, thread->task->all_image_info_size);\n"
               "/* IOS7LEO_DYLD_BEGIN */")

BLOCK_BODY = """
#include <kern/misc_protos.h>
#include <sys/errno.h>

/* dyld_all_image_infos (version 0x0e) field offsets, proven by value against the pinned iOS 7 dyld:
 * `setAlImageInfosHalt` (0x2be08d04) is `str r0, [r3, #32]` / `str r1, [r0, #36]` once r3 is
 * `gProcessInfo` (0x2be21b1c -> 0x2be21c8c = `__DATA,__all_image_info`, size 0xa4), and `dyld::halt`
 * runs log -> strlcpy(_error_string) -> setAlImageInfosHalt BEFORE its `blx _dyld_fatal_error`, so
 * at the udf the word at +0x20 is a live NUL-terminated user pointer to the message. */
#define IOS7WIT_ERROR_MESSAGE_OFF   0x20U
/* The rest of the same version-0x0e struct (the +0x40..+0x64 offsets are confirmed by value off the
 * pinned dyld by dyldtrace in parallel; if one moves it moves here and nowhere else).  A zero
 * sharedCacheBaseAddress says dyld never mapped the shared cache; the three char* fields are dyld's
 * own referrer / target dylib / symbol for THIS halt - a second path to what the message says. */
#define IOS7WIT_AI_ERROR_KIND       0x40U   /* uintptr_t */
#define IOS7WIT_AI_CLIENT_PATH      0x44U   /* const char* */
#define IOS7WIT_AI_TARGET_PATH      0x48U   /* const char* */
#define IOS7WIT_AI_ERROR_SYMBOL     0x4cU   /* const char* */
#define IOS7WIT_AI_CACHE_SLIDE      0x50U   /* uintptr_t */
#define IOS7WIT_AI_CACHE_BASE       0x64U   /* uintptr_t */
#define IOS7WIT_MIN_INFO_SIZE       0x68U
#define IOS7WIT_MAX_PRINTS          2U
#define IOS7WIT_MAX_TEXT            256U
#define IOS7WIT_PATH_TEXT           128U
#define IOS7WIT_LINE                48U
/* The r8 classification (docs/reference/d13-dyld-halt-message-recovery.md 9.3, re-measured by value
 * in `___cxa_throw` 0x2be148c0: movw/movt build 0x434c4e47 and 0x432b2b00 and `str` them at
 * object-0x1C and object-0x20): the signature pair sits 0x20 ABOVE the exception object pointer and
 * 0x30 BELOW the block base, so the two windows below tell the three readings apart. */
#define IOS7WIT_EH_W0               0x432b2b00U
#define IOS7WIT_EH_W1               0x434c4e47U
#define IOS7WIT_OBJ_BACK            0x20U
#define IOS7WIT_BASE_FWD            0x30U

static volatile UInt32 ios7wit_prints;

/* NUL-terminate at the cap, replace non-printables with '?' and return the length. */
static unsigned ios7wit_clean(char *text, unsigned cap)
{
    unsigned used = 0;

    text[cap - 1U] = 0;
    while (used < cap - 1U && text[used]) {
        unsigned char ch = (unsigned char) text[used];
        if (ch < 0x20U || ch > 0x7eU) text[used] = '?';
        ++used;
    }
    return used;
}

/* Print `used` bytes of `text` as IOS7WIT_LINE-byte lines prefixed with `tag`.  The caller has
 * already cleaned it; the byte after each chunk is saved and restored, so `text` comes back intact.
 * (The first version NULed that byte in place - and for every chunk but the last it IS the next
 * chunk's first byte, so the 995 log printed one full line and then empty ones.) */
static void ios7wit_lines(const char *tag, char *text, unsigned used)
{
    unsigned index, count;

    for (index = 0; index < used; index += IOS7WIT_LINE) {
        char tail;
        count = used - index;
        if (count > IOS7WIT_LINE) count = IOS7WIT_LINE;
        tail = text[index + count];
        text[index + count] = 0;
        printf("%s%s\\n", tag, text + index);
        text[index + count] = tail;
    }
}

/* Print the message dyld recorded before executing its fatal `udf`, from BOTH live pointers, and
 * classify r8.  Entered only from the udf branch of sleh_undef (every other undefined instruction
 * returns at trap.c:877), and every user read goes through copyin/copyinstr - nothing here
 * dereferences a user address, allocates, sleeps or panics, so a bad pointer can only cost error
 * lines.  The rate-limit slot is claimed BEFORE any I/O: dyld re-executes the udf forever and the
 * console block is finite. */
__attribute__((noinline)) static void ios7wit_dyld_message(task_t task, arm_saved_state_t * state)
{
    char field[IOS7WIT_MAX_TEXT];
    char other[IOS7WIT_MAX_TEXT];
    uint32_t msgp = 0, probe[4] = { 0U, 0U, 0U, 0U };
    vm_size_t copied = 0, copied5 = 0;
    unsigned used = 0, used5 = 0;
    const char *verdict;
    boolean_t ok = FALSE, ok5 = FALSE;
    int kr, err, err5, kr8, kr8b;

    if (!task || !state || !task->bsd_info) return;
    if (task->all_image_info_addr == 0) return;
    if (task->all_image_info_size < IOS7WIT_MIN_INFO_SIZE) return;
    if (ios7wit_prints >= IOS7WIT_MAX_PRINTS) return;
    ++ios7wit_prints;

    /* (1) the ABI read: dyld_all_image_infos.errorMessage -> the strlcpy'd _error_string copy. */
    kr = copyin((user_addr_t)(task->all_image_info_addr + IOS7WIT_ERROR_MESSAGE_OFF),
                (char *)&msgp, sizeof(msgp));
    if (kr != 0 || msgp == 0) {
        printf("IOS7WITNESS dyld msg=0x%08x copyin=%d\\n", msgp, kr);
        printf("dyld> <no message pointer>\\n");
    } else {
        err = copyinstr((user_addr_t)msgp, field, sizeof(field), &copied);
        printf("IOS7WITNESS dyld msg=0x%08x copyinstr=%d len=%u\\n", msgp, err, (unsigned)copied);
        if (err == 0 || err == ENAMETOOLONG) {
            used = ios7wit_clean(field, sizeof(field));
            ok = TRUE;
        } else {
            printf("dyld> <copyinstr failed>\\n");
        }
    }

    /* (2) the register read: r5 is halt()'s argument, still live at the udf (dyld::halt keeps it in
     * a callee-saved register across log/strlcpy/setAlImageInfosHalt).  Same text, different
     * pointer - so the two reads are each other's consistency check, made in (3). */
    err5 = copyinstr((user_addr_t)state->r[5], other, sizeof(other), &copied5);
    printf("IOS7WITNESS r5 msg=0x%08x copyinstr=%d len=%u\\n", state->r[5], err5, (unsigned)copied5);
    if (err5 == 0 || err5 == ENAMETOOLONG) {
        used5 = ios7wit_clean(other, sizeof(other));
        ok5 = TRUE;
    } else {
        printf("dyld5> <copyinstr failed>\\n");
    }

    /* (3) the consistency verdict: unequal texts mean the field and the register do not describe the
     * same halt - say so, never skip silently. */
    if (ok && ok5) {
        verdict = (used == used5 && (used == 0 || bcmp(field, other, used) == 0))
                  ? "matches errorMessage" : "DIFFERS from errorMessage";
    } else {
        verdict = "unreadable, no comparison";
    }
    printf("IOS7WITNESS r5 %s\\n", verdict);

    if (ok) {
        if (!used) printf("dyld> <empty>\\n");
        ios7wit_lines("dyld> ", field, used);
    }
    if (ok5) {
        if (!used5) printf("dyld5> <empty>\\n");
        ios7wit_lines("dyld5> ", other, used5);
    }

    /* (4) the same dyld_all_image_infos, rest of the version-0x0e struct: the shared-cache words and
     * dyld's own referrer/target/symbol strings for this halt.  cacheBase == 0 says the shared cache
     * was never mapped; the three paths are dyld's second copy of what the message says.  Every read
     * is fail-soft and every failure branch prints, never skips. */
    {
        uint32_t cache_base = 0, cache_slide = 0, error_kind = 0, strp = 0;
        vm_size_t copieds = 0;
        char strv[IOS7WIT_PATH_TEXT];
        int kr64, kr50, kr40, krp;

        kr40 = copyin((user_addr_t)(task->all_image_info_addr + IOS7WIT_AI_ERROR_KIND),
                      (char *)&error_kind, sizeof(error_kind));
        kr50 = copyin((user_addr_t)(task->all_image_info_addr + IOS7WIT_AI_CACHE_SLIDE),
                      (char *)&cache_slide, sizeof(cache_slide));
        kr64 = copyin((user_addr_t)(task->all_image_info_addr + IOS7WIT_AI_CACHE_BASE),
                      (char *)&cache_base, sizeof(cache_base));
        if (kr40 || kr50 || kr64) {
            printf("IOS7WITNESS info cacheBase/slide/errKind copyin=%d,%d,%d\\n", kr64, kr50, kr40);
        } else {
            printf("IOS7WITNESS info cacheBase=0x%08x slide=0x%08x errKind=0x%08x\\n",
                   cache_base, cache_slide, error_kind);
        }

        krp = copyin((user_addr_t)(task->all_image_info_addr + IOS7WIT_AI_CLIENT_PATH),
                     (char *)&strp, sizeof(strp));
        if (krp) {
            printf("IOS7WITNESS info client copyin=%d\\n", krp);
        } else if (strp == 0) {
            printf("IOS7WITNESS info client=\\"<null>\\"\\n");
        } else {
            err = copyinstr((user_addr_t)strp, strv, sizeof(strv), &copieds);
            if (err) printf("IOS7WITNESS info client copyinstr=%d\\n", err);
            else if (copieds == 0) printf("IOS7WITNESS info client=\\"<null>\\"\\n");
            else printf("IOS7WITNESS info client=\\"%s\\"\\n", strv);
        }

        krp = copyin((user_addr_t)(task->all_image_info_addr + IOS7WIT_AI_TARGET_PATH),
                     (char *)&strp, sizeof(strp));
        if (krp) {
            printf("IOS7WITNESS info target copyin=%d\\n", krp);
        } else if (strp == 0) {
            printf("IOS7WITNESS info target=\\"<null>\\"\\n");
        } else {
            err = copyinstr((user_addr_t)strp, strv, sizeof(strv), &copieds);
            if (err) printf("IOS7WITNESS info target copyinstr=%d\\n", err);
            else if (copieds == 0) printf("IOS7WITNESS info target=\\"<null>\\"\\n");
            else printf("IOS7WITNESS info target=\\"%s\\"\\n", strv);
        }

        krp = copyin((user_addr_t)(task->all_image_info_addr + IOS7WIT_AI_ERROR_SYMBOL),
                     (char *)&strp, sizeof(strp));
        if (krp) {
            printf("IOS7WITNESS info symbol copyin=%d\\n", krp);
        } else if (strp == 0) {
            printf("IOS7WITNESS info symbol=\\"<null>\\"\\n");
        } else {
            err = copyinstr((user_addr_t)strp, strv, sizeof(strv), &copieds);
            if (err) printf("IOS7WITNESS info symbol copyinstr=%d\\n", err);
            else if (copieds == 0) printf("IOS7WITNESS info symbol=\\"<null>\\"\\n");
            else printf("IOS7WITNESS info symbol=\\"%s\\"\\n", strv);
        }
    }

    /* (5) classify r8 (inherited from an outer frame - see the reference doc 9.3): the exception
     * object carries the signature pair 0x20 below the pointer, the block base carries it 0x30
     * above, and anything else is either a message interior or a stale value - all four reported. */
    kr8 = copyin((user_addr_t)state->r[8] - IOS7WIT_OBJ_BACK, (char *)probe, sizeof(probe));
    if (kr8 == 0 && probe[0] == IOS7WIT_EH_W0 && probe[1] == IOS7WIT_EH_W1) {
        printf("IOS7WITNESS r8=0x%08x exception object (signature at r8-0x20)\\n", state->r[8]);
        return;
    }
    kr8b = copyin((user_addr_t)state->r[8] + IOS7WIT_BASE_FWD, (char *)probe, sizeof(probe));
    if (kr8b == 0 && probe[0] == IOS7WIT_EH_W0 && probe[1] == IOS7WIT_EH_W1) {
        printf("IOS7WITNESS r8=0x%08x exception block base (signature at r8+0x30)\\n", state->r[8]);
        return;
    }
    err = copyinstr((user_addr_t)state->r[8], field, sizeof(field), &copied);
    if (err == 0 || err == ENAMETOOLONG) {
        used = ios7wit_clean(field, sizeof(field));
        printf("IOS7WITNESS r8=0x%08x message interior len=%u\\n", state->r[8], used);
        ios7wit_lines("dyld8> ", field, used);
    } else {
        printf("IOS7WITNESS r8=0x%08x stale probe=0x%08x copyin=%d,%d err=%d\\n",
               state->r[8], probe[0], kr8, kr8b, err);
    }
}

#endif
/* IOS7WITNESS_END */"""

BLOCK = "/* IOS7WITNESS_BEGIN */\n" + GATE + "\n" + BLOCK_BODY

CALL = f"""/* IOS7WITNESS_BEGIN */
{GATE}
        ios7wit_dyld_message(thread->task, arm_ctx);
#endif
/* IOS7WITNESS_END */"""

CHUNKS = ((BLOCK_ANCHOR, BLOCK, "witness block"), (CALL_ANCHOR, CALL, "witness call"))

# The identifiers trap.c's own conditional directives evaluate.  The placeholder-include OFF proof is
# faithful to the real build ONLY while this set holds (a macro invented by a header and tested in a
# directive would be invisible to a placeholder), so the proof refuses if it ever grows.
# **`STAGE90_XNU_UNDEF_RAISE` (1020) is allow-listed here for the SAME reason `STAGE90_XNU_DYLD_WITNESS`
# is allow-listed in `patch_d13_undef_raise.py`'s counterpart set: the two patches edit the SAME pool file
# (`osfmk/arm/trap.c`) and either must compose over the other's already-staged chunk, in EITHER order and
# on a RE-RUN (the tree keeps whatever each patch staged).  This is faithful - not a loosened proof -
# because the switch is a BUILD switch (a command-line `-D`, never a header macro), the exact class the
# allow-list exists to accept: in all three OFF preprocessor runs (`head`, `staged_undefined`,
# `staged_zero`) it is UNDEFINED, so the 1020 block's `defined()`-first `#if` is false and its `#else`
# (the file's pre-existing bytes) is emitted, leaving the OFF byte-identity this proof certifies intact.
# An identifier a HEADER could invent would still be caught, because such a name is not in this set.
ALLOWED_IF_IDENTIFIERS = {"BOARD_CONFIG_QSD8250_LEO", "BOARD_CONFIG_ARMPBA8", SWITCH,
                          "STAGE90_XNU_UNDEF_RAISE",
                          # 1025's failed-fault publisher (tools/patch_d13_ustack_probe.py) edits the
                          # SAME file (osfmk/arm/trap.c) and adds its own
                          # `#if defined(STAGE90_XNU_USTACK_PROBE) && STAGE90_XNU_USTACK_PROBE` block
                          # in the usermode DATA-abort arm, far below `sleh_undef` where this patch's
                          # witness lives.  The OFF arm below drives STAGE90_XNU_USTACK_PROBE as
                          # `undefined`, so 1025's block is compiled OUT and the OFF text is still
                          # HEAD's; allowing the identifier is what lets the two edits compose in one
                          # file (a file's directive identifiers are a SHARED namespace -
                          # [[mi4-one-value-two-definitions]]).
                          "STAGE90_XNU_USTACK_PROBE",
                          # 1026's abort-entry discriminator (tools/patch_d13_abt_entry_probe.py) edits
                          # the SAME file (osfmk/arm/trap.c) and adds its own
                          # `#if defined(STAGE90_XNU_ABT_ENTRY_PROBE) && STAGE90_XNU_ABT_ENTRY_PROBE`
                          # block inside 1025's publisher in the usermode DATA-abort arm, far below
                          # `sleh_undef` where this patch's witness lives.  The OFF arm below drives
                          # STAGE90_XNU_ABT_ENTRY_PROBE as `undefined`, so 1026's block is compiled OUT
                          # and the OFF text is still HEAD's; allowing the identifier is what lets the
                          # three edits compose in one file (a file's directive identifiers are a
                          # SHARED namespace - [[mi4-one-file-many-rungs]]).
                          "STAGE90_XNU_ABT_ENTRY_PROBE",
                          # 1028's H2 stack-headroom FIX (tools/patch_d13_h2_stack_headroom.py) edits
                          # bsd/kern/kern_exec.c's `create_unix_stack`, NOT trap.c where this witness
                          # lives -- but it is the same shared-namespace rule, same OFF reasoning: the OFF
                          # arm below drives STAGE90_XNU_H2_STACK_HEADROOM as `undefined`, so 1028's block
                          # is compiled OUT and the OFF text is still HEAD's.
                          "STAGE90_XNU_H2_STACK_HEADROOM",
                          # 1029's READER PROBE (tools/patch_d13_reader_probe.py) edits the SAME file
                          # (osfmk/arm/trap.c), adding a Site A block in the usermode DATA-abort arm, far
                          # below `sleh_undef` where this witness lives.  Same shared-namespace rule, same
                          # OFF reasoning: the OFF arm below drives STAGE90_XNU_READER_PROBE as
                          # `undefined`, so 1029's block is compiled OUT and the OFF text is still
                          # HEAD's ([[mi4-one-file-many-rungs]]).
                          "STAGE90_XNU_READER_PROBE",
                          # 1030's WRITER PROBE (tools/patch_d13_writer_probe.py) edits the SAME file
                          # (osfmk/arm/trap.c), adding a Site A block in the usermode DATA-abort arm, far
                          # below `sleh_undef` where this witness lives.  Same shared-namespace rule, same
                          # OFF reasoning: the OFF arm below drives STAGE90_XNU_WRITER_PROBE as
                          # `undefined`, so 1030's block is compiled OUT and the OFF text is still
                          # HEAD's ([[mi4-one-file-many-rungs]]).
                          "STAGE90_XNU_WRITER_PROBE",
                          # 1031's CALLER PROBE (tools/patch_d13_caller_probe.py) edits the SAME file
                          # (osfmk/arm/trap.c), adding a Site A block after 1030's.  Same shared-namespace
                          # rule, same OFF reasoning: the OFF arm below drives STAGE90_XNU_CALLER_PROBE as
                          # `undefined`, so 1031's block is compiled OUT and the OFF text is still HEAD's
                          # ([[mi4-one-file-many-rungs]]).
                          "STAGE90_XNU_CALLER_PROBE",
                          # 1033's EVAL FRAME (tools/patch_d13_eval_frame.py) edits the SAME file, adding a
                          # block inside 1025's publisher after 1031's.  Same shared-namespace rule,
                          # same OFF reasoning ([[mi4-one-file-many-rungs]]).
                          "STAGE90_XNU_EVAL_FRAME",
                          # 1035's PC CARRIER (tools/patch_d13_pc_carrier.py) edits the SAME file, adding
                          # a block after 1033's.  Same shared-namespace rule, same OFF reasoning
                          # ([[mi4-one-file-many-rungs]]).
                          "STAGE90_XNU_PC_CARRIER"}
_DIRECTIVE = re.compile(r"^[ \t]*#[ \t]*(?:if|elif|ifdef|ifndef)\b(.*)$", re.M)
_IDENT = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
_WORDS = {"defined", "if", "elif", "ifdef", "ifndef"}
_INCLUDE = re.compile(r"^[ \t]*#[ \t]*include[ \t]*[<\"]([^>\"]+)[>\"]", re.M)

# What the ON state must contain and the three OFF states must not.  These are CODE and STRING-LITERAL
# tokens, never the `/* IOS7WITNESS_* */` markers: the preprocessor strips comments, so a marker can
# never survive `clang -E` and asserting on one would be a check that is false by construction.
ON_TOKENS = ("ios7wit_dyld_message", "IOS7WITNESS dyld msg=", "IOS7WITNESS r5 msg=",
             "IOS7WITNESS r8=0x%08x", "dyld> ", "dyld5> ", "dyld8> ",
             "DIFFERS from errorMessage",
             "IOS7WITNESS info cacheBase=0x%08x slide=0x%08x errKind=0x%08x",
             "IOS7WITNESS info cacheBase/slide/errKind copyin=",
             "IOS7WITNESS info client=", "IOS7WITNESS info target=", "IOS7WITNESS info symbol=",
             "<null>")


def refuse(msg: str, code: int):
    print(f"patch_d13_dyld_witness: REFUSING: {msg}", file=sys.stderr)
    raise SystemExit(code)


def stage(old: str):
    """(text, status, head) with status in {"staged", "already", "restage"} - every gate decided
    before a byte is written; SystemExit on a partial or foreign edit, with the file untouched
    (3 = anchor mismatch, 4 = partial/double edit).  `head` is the text the write is proved against
    (the original for "staged", the marker-stripped predecessor for "restage")."""
    marks = old.count(MARK)
    if marks == 0:
        if "ios7wit_dyld_message" in old:
            refuse(f"{REL} mentions ios7wit_dyld_message but carries no {MARK} marker - a hand edit "
                   f"is not completed in place", 4)
        new = old
        for anchor, chunk, what in CHUNKS:
            n = new.count(anchor)
            if n != 1:
                refuse(f"{REL} has {n} anchor(s) for the {what}, expected exactly 1 - this is not "
                       f"the tree state this patch was written for", 3 if n == 0 else 4)
            i = new.index(anchor)
            nl = new.index("\n", i)
            new = new[:nl + 1] + chunk + "\n" + new[nl + 1:]
        return new, "staged", old
    if marks != 2:
        refuse(f"{REL} carries {marks} {MARK} markers, expected 0 (unstaged) or 2 (staged)", 4)
    if all(chunk in old for _a, chunk, _w in CHUNKS):
        return old, "already", None
    stripped = strip_marked(old)
    if IDENTITY not in stripped or IDENTITY2 not in stripped:
        refuse(f"re-staging would remove the file's identity text - the markers do not bound this "
               f"script's chunks", 4)
    new, _status, _head = stage(stripped)
    return new, "restage", stripped


def unstaged(text: str) -> str:
    """`text` with this script's two chunks removed - the inverse of stage(), for the proof a staged
    file runs against itself."""
    out = text
    for _a, chunk, what in CHUNKS:
        if out.count(chunk) != 1:
            refuse(f"cannot reconstruct the unstaged text: {out.count(chunk)} {what} chunk(s)", 4)
        out = out.replace(chunk + "\n", "", 1)
    return out


_END = "/* IOS7WITNESS_END */"


def strip_marked(text: str) -> str:
    """`text` with every IOS7WITNESS region removed, BEGIN marker through END marker inclusive.

    Version-agnostic on purpose: the markers bound whatever chunks a PREVIOUS revision inserted, so
    this is what a re-stage (tool upgraded, tree still carrying the old chunks) removes before the
    current ones go in.  Called only on a file whose BEGIN count is already exactly 2."""
    out, inside, regions, removed = [], False, 0, 0
    for line in text.splitlines(keepends=True):
        if not inside and MARK in line:
            inside, regions = True, regions + 1
        if inside:
            removed += 1
            if _END in line:
                inside = False
            continue
        out.append(line)
    if inside or regions != 2:
        refuse(f"cannot re-stage: {regions} marker region(s), unterminated={inside}", 4)
    print(f"  re-stage: removed {removed} line(s) in {regions} marker-bounded region(s) - the "
          f"markers bound whatever version's chunks were there")
    return "".join(out)


def if_identifiers(text: str):
    return {w for expr in _DIRECTIVE.findall(text) for w in _IDENT.findall(expr) if w not in _WORDS}


def cpp_probe(text: str, defines, workdir: Path, tag: str) -> str:
    """The REAL preprocessor, over the WHOLE file, every #include resolved to an empty file."""
    inc = workdir / f"inc_{tag}"
    for name in _INCLUDE.findall(text):
        p = inc / name
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text("")
    src = workdir / f"{tag}.c"
    src.write_text(text)
    argv = ["clang", "-E", "-P", "-x", "c", "-nostdinc", f"-I{inc}"] + list(defines) + [str(src)]
    try:
        return subprocess.run(argv, capture_output=True, text=True, check=True).stdout
    except FileNotFoundError:
        refuse("no clang on PATH - the OFF byte-identity proof is the real preprocessor's, and an "
               "unproven write is not made", 5)
    except subprocess.CalledProcessError as exc:
        refuse(f"the preprocessor failed on the {tag} state: {exc.stderr.strip()[:400]}", 5)


def verify_off(head: str, staged: str, workdir: Path) -> bool:
    """True iff the real preprocessor makes OFF (undefined and =0) byte-identical to HEAD."""
    idents = if_identifiers(staged)
    print(f"  conditional identifiers in the file: {', '.join(sorted(idents))}")
    extra = sorted(i for i in idents if i not in ALLOWED_IF_IDENTIFIERS)
    if extra:
        print(f"patch_d13_dyld_witness: FAIL: {REL}'s directives also evaluate {', '.join(extra)} - "
              f"those may come from a header, which the placeholder-include proof cannot see, so the "
              f"OFF equality is NOT certified", file=sys.stderr)
        return False
    board = ("-DBOARD_CONFIG_MSM8974_CANCRO=1",)
    s_head = cpp_probe(head, board, workdir, "head")
    s_none = cpp_probe(staged, board, workdir, "staged_undefined")
    s_zero = cpp_probe(staged, board + (f"-D{SWITCH}=0",), workdir, "staged_zero")
    s_one = cpp_probe(staged, board + (f"-D{SWITCH}=1",), workdir, "staged_one")
    ok = True
    for tag, got in (("undefined", s_none), ("= 0", s_zero)):
        same = got == s_head
        print(f"  OFF ({SWITCH} {tag}): preprocessed output is "
              f"{'IDENTICAL to HEAD' if same else 'DIFFERENT FROM HEAD'} ({len(got)} chars)")
        ok = ok and same
    on = all(t in s_one for t in ON_TOKENS)
    clear = all(not any(t in s for t in ON_TOKENS) for s in (s_head, s_none, s_zero))
    print(f"  ON  ({SWITCH} = 1): preprocessed output carries the witness = {on} "
          f"({', '.join(t for t in ON_TOKENS if t in s_one)}); the three OFF outputs carry none of "
          f"{ON_TOKENS} = {clear}")
    return ok and on and clear and s_one != s_head


def main() -> int:
    argv = sys.argv[1:]
    dry = "--dry-run" in argv
    verify_only = "--verify-off" in argv
    argv = [a for a in argv if a not in ("--dry-run", "--verify-off")]
    if len(argv) != 1:
        print("usage: patch_d13_dyld_witness.py <xnu-tree-root> [--dry-run|--verify-off]",
              file=sys.stderr)
        return 2
    path = Path(argv[0]) / REL
    if not path.is_file():
        print(f"patch_d13_dyld_witness: no {REL} under {argv[0]} (D13 tree not provisioned?)",
              file=sys.stderr)
        return 2
    old = path.read_text()
    if IDENTITY not in old or IDENTITY2 not in old:
        refuse(f"{REL} carries no `{IDENTITY}` / dyld_all_image_info_addr dump - this is not the "
               f"file this patch was written for", 3)

    new, status, head = stage(old)
    print(f"patch_d13_dyld_witness: {path}")
    if status == "already":
        head = unstaged(new)
        print("  already staged: the OFF proof below runs against the text this script's own chunks "
              "are removed from (HEAD itself is not available once the tree is staged)")
    elif status == "restage":
        print("  re-staging over an older revision: the OFF proof below runs against the "
              "marker-stripped text - the previous chunks are removed by marker, not by content, so "
              "that text's provenance is the previous stage's own OFF proof, and its identity "
              "strings and both anchors are re-checked before the insert")
    with tempfile.TemporaryDirectory() as td:
        good = verify_off(head, new, Path(td))
    print(f"patch_d13_dyld_witness: OFF byte-identity proof {'PASS' if good else 'FAIL'}")
    if verify_only:
        return 0 if good else 1
    if not good:
        print("patch_d13_dyld_witness: REFUSING to write - the OFF byte-identity proof did not pass "
              "(the file is untouched)", file=sys.stderr)
        return 1
    if status == "already":
        print("patch_d13_dyld_witness: nothing to do")
        return 0
    if dry:
        if status == "restage":
            print(f"  --dry-run: would RE-STAGE (marker-bounded strip of the older chunks, then "
                  f"{len(BLOCK.splitlines())} witness lines + {len(CALL.splitlines())} call lines); "
                  f"nothing written")
        else:
            print(f"  --dry-run: would insert {len(BLOCK.splitlines())} witness lines + "
                  f"{len(CALL.splitlines())} call lines at the two anchors; nothing written")
        return 0
    path.write_text(new)
    if status == "restage":
        print(f"patch_d13_dyld_witness: re-staged the witness block + call into {REL} "
              f"(marker-bounded strip of the older revision, then insert)")
    else:
        print(f"patch_d13_dyld_witness: staged the witness block + call into {REL}")
    print(f"patch_d13_dyld_witness: NOW RE-RUN tools/build_xnu_arm_kernel.sh with "
          f"STAGE90_XNU_DYLD_WITNESS=1 exported AND -DSTAGE90_XNU_DYLD_WITNESS=1 in "
          f"XNU_KERNEL_EXTRA_DEFINES (the pool's osfmk_arm_trap.o is what the linked image gets)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())