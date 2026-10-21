#!/usr/bin/env python3
"""910c's guard: the bulk stream arm's transcribed values, its SOURCE-OWNER cross-checks, the two-way
handover (who owns EP1-IN), the no-ENDPTCTRL refusal, and whether the switch reached the linked image.

910c is the first arm whose payload comes from ANOTHER part of this image (the RAM console ring the live
channel publishes into), so its guard has to answer a question the three earlier USB guards did not:
**does the source's layout here recompute the owner's, or has it drifted?** The console ring is
`{ u32 sig; u32 start; u32 size; u8 data[]; }` at 0xde500000, read through the `+0x01000000` alias - and
the offsets (sig 0, size 8, data 12) and the sig ('DBGC') are the owner's (`entry_stubs.c`), not this
arm's to restate. `[[mi4-one-value-two-definitions]]` is exactly this class.

1. **THE SOURCE'S VALUES against the owner's** - the console sig, the three offsets, the size bound, and
   the alias (`LIVE_CONSOLE_ALIAS_BASE = RAM_CONSOLE_BASE + 0x01000000`), each compared to the owner's
   own expression in `entry_stubs.c`, and the ENDPOINT BITS re-used from `entry_usb_enum.h`.

2. **THE COMPLETION ACCESSOR is the dTD `token`, not the qh `curr`.** The stream reads a completed
   transfer's byte count as `length - ((token & TD_TOTAL_MASK) >> TD_TOTAL_SHIFT)`; the guard refuses a
   stream that reads `QH_OFF_CURR` for a count (the vendor never does - `_hardware_dequeue:2176-2178`),
   and refuses a completion that does not test `TD_STATUS_ACTIVE` first (the `-EBUSY` guard).

3. **THE WRITE-TARGET WHITELIST, and the two boundaries.** Every `usb_stream_write32(<ARG>, ...)` first
   argument is a `STAGE90_USB_*` name a header defines; no store targets `ENDPTCTRL` (the enum arm owns
   the endpoint enable); no store targets `USBCMD` or `DEVICEADDR` (the enum arm owns those). The stream
   writes ONLY `ENDPTPRIME` and `ENDPTCOMPLETE` - one owner of the endpoint's state at a time.

4. **THE HANDOVER, at the source, both ways.** The stream arm requires the enum arm (`STREAM=1 ENUM=0`
   refused at build); and `entry_usb_enum.c` must guard its EP1-IN prime AND its EP1-IN completion
   re-prime on `STAGE90_XNU_USB_STREAM`, or both files write qh[IN1].

5. **THE SWITCH REACHED THE IMAGE, both ways.**
"""
import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.dirname(HERE)

STREAM_H = os.path.join(REPO_ROOT, "src/entry/entry_usb_stream.h")
STREAM_C = os.path.join(REPO_ROOT, "src/entry/entry_usb_stream.c")
ENUM_H = os.path.join(REPO_ROOT, "src/entry/entry_usb_enum.h")
ENUM_C = os.path.join(REPO_ROOT, "src/entry/entry_usb_enum.c")
STUBS_C = os.path.join(REPO_ROOT, "src/entry/entry_stubs.c")

NM = "arm-none-eabi-nm"
OBJDUMP = "arm-none-eabi-objdump"

# The source owners: `entry_stubs.c` for the console ring, `entry_usb_enum.h` for the endpoint bits.
OWNER_FILES = [STUBS_C, ENUM_H, os.path.join(REPO_ROOT, "src/entry/entry_usb.h")]

# This header's name -> an expression in the OWNER's own names / literals.
CROSS_VALUES = {
    # the console ring, owned by `entry_stubs.c`
    "STAGE90_USB_STREAM_CONSOLE_SIG":  "RAM_CONSOLE_SIG",
    "STAGE90_USB_STREAM_OFF_SIG":      "0",
    "STAGE90_USB_STREAM_OFF_SIZE":     "8",
    "STAGE90_USB_STREAM_OFF_DATA":     "12",
    # the endpoint bits re-used from the enum header (NOT restated - a copy would be the defect)
    "STAGE90_USB_STREAM_QH_IN1":       "STAGE90_USB_ENUM_QH_IN1",
}

# The values that must be a SPECIFIC literal, because the owner expresses them as arithmetic over an
# absolute address the guard cannot evaluate from a `#define` alone: the alias base is the ring's base
# plus 1 MB, and the size bound is the 2 MB buffer minus the 12-byte header.
LITERAL_EXPECT = {
    "STAGE90_USB_STREAM_RAM_CONSOLE_BASE": 0xde500000,
    "STAGE90_USB_STREAM_CONSOLE_VA":       0xde500000 + 0x01000000,
    "STAGE90_USB_STREAM_SIZE_MAX":         0x00200000 - 12,
    "STAGE90_USB_STREAM_CHUNK":            4096,
    "STAGE90_USB_STREAM_TD_LEN":           28,
}


class Refused(Exception):
    pass


def say(message):
    print(message)


def read(path):
    with open(path, "r", errors="replace") as handle:
        return handle.read()


def strip_comments(text):
    text = re.sub(r"/\*.*?\*/", " ", text, flags=re.S)
    text = re.sub(r"//[^\n]*", " ", text)
    return text


def header_values(text, prefix="STAGE90_USB_"):
    """`#define <prefix>NAME  <expr>` -> {NAME: expression-string}. Continuations joined first."""
    text = strip_comments(text)
    text = re.sub(r"\\\n", " ", text)
    out = {}
    for m in re.finditer(r"^#define[ \t]+%s([A-Z0-9_]+)[ \t]+([^\n]+)$" % re.escape(prefix), text, re.M):
        out[m.group(1)] = m.group(2).strip().rstrip("u").rstrip("U")
    return out


def owner_defines(*paths):
    table = {}
    for path in paths:
        for m in re.finditer(r"^#define[ \t]+([A-Za-z_][A-Za-z0-9_]*)[ \t]+([^\n]+)$",
                             strip_comments(read(path)), re.M):
            table[m.group(1)] = m.group(2).strip()
    return table


def first_arg(text, start):
    i = text.find("(", start)
    if i == -1:
        return None
    depth, j = 0, i
    while j < len(text):
        if text[j] == "(":
            depth += 1
        elif text[j] == ")":
            depth -= 1
            if depth == 0:
                return text[i + 1:j]
        elif text[j] == "," and depth == 1:
            return text[i + 1:j]
        j += 1
    return None


def eval_expr(expr, table, depth=0):
    if depth > 12:
        raise Refused("expression %r nests too deep" % expr)
    text = expr.strip().rstrip("u").rstrip("U")
    text = re.sub(r"\bBIT\((\d+)\)", r"(1 << \1)", text)
    text = re.sub(r"\bBIT\(([A-Za-z_][A-Za-z0-9_]*)\)", r"(1 << \1)", text)
    text = re.sub(r"\bUL\b", "", text)
    text = re.sub(r"(\d)[uU]\b", r"\1", text)

    def sub_name(m):
        name = m.group(0)
        if name not in table:
            raise Refused("the owner headers define no `%s`" % name)
        return "(%s)" % eval_expr(table[name], table, depth + 1)

    text = re.sub(r"(?<![\w.])[A-Za-z_][A-Za-z0-9_]*", sub_name, text)
    if not re.fullmatch(r"[0-9xXa-fA-F()\s<>\|&+~*-]+", text):
        raise Refused("expression %r is not evaluable: %s" % (expr, text))
    try:
        return eval(text, {"__builtins__": {}}, {})   # noqa: S307 - digits/operators only, checked above
    except Exception as exc:  # noqa: BLE001
        raise Refused("expression %r did not evaluate: %s" % (expr, exc))


def check_sources():
    stream_text = read(STREAM_H)
    stream_body = strip_comments(read(STREAM_C))
    enum_body = strip_comments(read(ENUM_C))
    problems = []

    vals = header_values(stream_text)

    # (1) the source's values against the owner's own expressions.
    table = owner_defines(*OWNER_FILES)
    # both keyed forms: the short name (`STREAM_CONSOLE_VA`) and the full one a sibling define references
    # (`STAGE90_USB_STREAM_RAM_CONSOLE_BASE`) - CROSS_VALUES names the latter, header_values yields the
    # former.
    from_shorts = header_values(stream_text)
    table.update(from_shorts)
    table.update({"STAGE90_USB_" + k: v for k, v in from_shorts.items()})
    for name, expr in sorted(CROSS_VALUES.items()):
        short = name[len("STAGE90_USB_"):]
        if short not in vals:
            problems.append("entry_usb_stream.h defines no %s, but the check names it" % name)
            continue
        try:
            got = eval_expr(vals[short], table)
            want = eval_expr(expr, table)
        except Refused as exc:
            problems.append("%s: %s" % (name, exc))
            continue
        if got != want:
            problems.append("%s = 0x%x but the owner's `%s` = 0x%x ([[mi4-one-value-two-definitions]])"
                            % (name, got, expr, want))

    # the literals the owner expresses as arithmetic over an absolute address.
    for name, want in sorted(LITERAL_EXPECT.items()):
        short = name[len("STAGE90_USB_"):]
        if short not in vals:
            problems.append("entry_usb_stream.h defines no %s, but the check names it" % name)
            continue
        try:
            got = eval_expr(vals[short], table)
        except Refused as exc:
            problems.append("%s: %s" % (name, exc))
            continue
        if got != want:
            problems.append("%s = 0x%x but the owner's layout fixes it at 0x%x "
                            "([[mi4-one-value-two-definitions]])" % (name, got, want))
    say("  source values: %d owner expressions + %d fixed literals (console ring, alias, chunk, dTD size)"
        % (len(CROSS_VALUES), len(LITERAL_EXPECT)))

    # (2) the completion accessor: the count is in the dTD `token`, never the qh `curr`.
    if "QH_OFF_CURR" in stream_body:
        problems.append("entry_usb_stream.c reads `QH_OFF_CURR` - the arrived byte count is in the dTD "
                        "`token` (`length - ((token & TD_TOTAL_MASK) >> TD_TOTAL_SHIFT)`), and the vendor "
                        "never reads `qh.curr` for a count (`_hardware_dequeue:2176-2178`)")
    if "TD_TOTAL_MASK" not in stream_body or "TD_TOTAL_SHIFT" not in stream_body:
        problems.append("entry_usb_stream.c does not compute the arrived count from `TD_TOTAL_MASK`/"
                        "`TD_TOTAL_SHIFT`: the completion accessor must be the dTD `token`")
    if "TD_ACTIVE" not in stream_body:
        problems.append("entry_usb_stream.c has no `TD_STATUS_ACTIVE` test: a still-active dTD is not "
                        "done and must not be read as a completed transfer (the vendor's -EBUSY guard)")
    if "FlushPoC_DcacheRegion" not in stream_body:
        problems.append("entry_usb_stream.c does not invalidate the dTD with `FlushPoC_DcacheRegion`: the "
                        "core's write to the dTD `token` is to DRAM and a stale cached line would shadow "
                        "it (and `FlushPoU_Dcache` is the seam-wrapped symbol, 910b design §9.b)")
    say("  completion: the dTD `token` count with the ACTIVE guard and the PoC invalidate; no `qh.curr`")

    # (3) the write-target whitelist, and the two boundaries.
    owned = set()
    for path in (ENUM_H, STREAM_H, os.path.join(REPO_ROOT, "src/entry/entry_usb.h"),
                 os.path.join(REPO_ROOT, "src/entry/entry_usb_dev.h")):
        for m in re.finditer(r"^#define[ \t]+([A-Za-z_][A-Za-z0-9_]*)",
                             strip_comments(read(path)), re.M):
            owned.add(m.group(1))
    writes = []
    for m in re.finditer(r"\busb_stream_write32\s*\(", stream_body):
        arg = (first_arg(stream_body, m.start()) or "").strip()
        if not arg or arg.startswith("uint32_t"):
            continue
        base = re.match(r"([A-Za-z_][A-Za-z0-9_]*)", arg)
        writes.append(base.group(1) if base else arg)
    bad = sorted({a for a in writes if a not in owned})
    if bad:
        problems.append("entry_usb_stream.c stores through usb_stream_write32 to a name no header defines: "
                        + ", ".join(bad) + " - a write to a register with no owner")
    if not writes:
        problems.append("entry_usb_stream.c takes no usb_stream_write32 store: the stream's whole point is "
                        "that it primes and completes the one bulk IN endpoint")
    # the stream writes ONLY ENDPTPRIME and ENDPTCOMPLETE: the enum arm owns the endpoint enable and the
    # address; a stream store to either is a second writer of one value.
    for forbidden, why in (("ENDPTCTRL", "the ENUM arm owns the endpoint enable (SET_CONFIGURATION)"),
                           ("USBCMD", "the ENUM arm / 910a2 own the link state"),
                           ("DEVICEADDR", "the ENUM arm owns the address")):
        if any(forbidden in w for w in writes):
            problems.append("entry_usb_stream.c stores `%s` - %s; the stream arm primes and completes only"
                            % (forbidden, why))
    say("  write-targets: %d stores, each a transcribed `STAGE90_USB_*` offset; only ENDPTPRIME/ENDPTCOMPLETE"
        % len(writes))

    # (4) the handover, at the source, both ways. The enum file must guard BOTH its EP1 prime and its EP1
    # completion re-prime on the stream switch, or both files write qh[IN1].
    if "STAGE90_XNU_USB_STREAM" not in enum_body:
        problems.append("entry_usb_enum.c does not mention `STAGE90_XNU_USB_STREAM`: with the stream arm "
                        "ON the enum arm must not prime or re-prime EP1-IN (it hands the endpoint over)")
    else:
        # both guarded primes: the arm-time prime and the completion re-prime.
        primes = [m.start() for m in re.finditer(r"usb_enum_prime\(\s*STAGE90_USB_ENUM_QH_IN1", enum_body)]
        if len(primes) < 2:
            problems.append("entry_usb_enum.c no longer primes EP1-IN twice (arm + completion): the "
                            "handover guard cannot be proven over %d site(s)" % len(primes))
        else:
            # each prime must sit inside a `#if !STAGE90_XNU_USB_STREAM` ... `#endif` region.
            for p in primes:
                before = enum_body[:p]
                guard = before.rfind("#if !STAGE90_XNU_USB_STREAM")
                if guard == -1 or enum_body[guard:p].find("#endif") != -1:
                    problems.append("an `usb_enum_prime(... QH_IN1 ...)` in entry_usb_enum.c is NOT under "
                                    "`#if !STAGE90_XNU_USB_STREAM`: with the stream ON both files would "
                                    "write qh[IN1]")
                    break
    say("  handover: entry_usb_enum.c guards both EP1-IN primes on the stream switch")

    if problems:
        raise Refused("\n".join("  - " + p for p in problems))


def record_switch(image_path, key):
    record = os.path.join(os.path.dirname(image_path), "xnu_arm_entry-config.txt")
    if not os.path.isfile(record):
        return None
    m = re.search(r"^%s=(\d+)$" % re.escape(key), read(record), re.M)
    return int(m.group(1)) if m else None


def nm_sizes(image):
    out = {}
    for line in subprocess.run([NM, "-S", "-n", image], capture_output=True, text=True).stdout.splitlines():
        parts = line.split()
        if len(parts) == 4:
            try:
                out[parts[3]] = (int(parts[0], 16), int(parts[1], 16), parts[2])
            except ValueError:
                continue
    return out


def body_of(image, name):
    syms = nm_sizes(image)
    if name not in syms:
        return None
    addr, size, _kind = syms[name]
    if size == 0:
        return ""
    return subprocess.run([OBJDUMP, "-d", "--start-address=0x%x" % addr,
                           "--stop-address=0x%x" % (addr + size), image],
                          capture_output=True, text=True).stdout


def check_image(image):
    syms = nm_sizes(image)
    if "entry_usb_stream_poll" not in syms:
        raise Refused("%s defines no `entry_usb_stream_poll`: the call site in entry_trace.c would be an "
                      "undefined symbol" % image)
    _addr, size, kind = syms["entry_usb_stream_poll"]
    if kind != "T":
        raise Refused("`entry_usb_stream_poll` is a `%s` symbol, not `T` (text)" % kind)
    switch = record_switch(image, "STAGE90_XNU_USB_STREAM")
    enum_switch = record_switch(image, "STAGE90_XNU_USB_ENUM")
    if switch == 1 and enum_switch != 1:
        raise Refused("the record says STAGE90_XNU_USB_STREAM=1 but STAGE90_XNU_USB_ENUM=%s: the stream "
                      "requires the enum arm (the build refuses STREAM=1 ENUM=0; this is the linked check)"
                      % enum_switch)
    if switch == 1:
        if size <= 8:
            raise Refused("the record says STAGE90_XNU_USB_STREAM=1 but the linked `entry_usb_stream_poll` "
                          "body is size %d: the arm's switch did not reach the image "
                          "([[mi4-off-option-two-spellings]])" % size)
        say("  image: STAGE90_XNU_USB_STREAM=1 and `entry_usb_stream_poll` is a %d-byte T body" % size)
    elif switch == 0:
        if size > 8:
            raise Refused("the record says STAGE90_XNU_USB_STREAM=0 but the linked `entry_usb_stream_poll` "
                          "body is %d bytes: the OFF arm must be a bare return" % size)
        say("  image: STAGE90_XNU_USB_STREAM=0 and `entry_usb_stream_poll` is a bare return")
    else:
        say("  image: no USB_STREAM key in the record; `entry_usb_stream_poll` is %d bytes" % size)


def selftest():
    original_h = read(STREAM_H)
    original_c = read(STREAM_C)
    original_enum = read(ENUM_C)
    cases = []

    def with_edit(name, paths, old, new, expect_in):
        # `paths` is a single letter: "h" (stream header), "c" (stream body), "e" (enum body).
        target = {"h": STREAM_H, "c": STREAM_C, "e": ENUM_C}[paths]
        text = {"h": original_h, "c": original_c, "e": original_enum}[paths]
        mutated = text.replace(old, new, 1)
        if mutated == text:
            cases.append((name, "the mutation did not apply: %r not in %s" % (old, paths), False))
            return
        open(target, "w").write(mutated)
        try:
            check_sources()
            cases.append((name, "check_sources accepted the mutation (it should have refused)", False))
        except Refused as exc:
            cases.append((name, str(exc).strip().splitlines()[0] if str(exc).strip() else "(refused)",
                          expect_in in str(exc)))
        finally:
            open(STREAM_H, "w").write(original_h)
            open(STREAM_C, "w").write(original_c)
            open(ENUM_C, "w").write(original_enum)

    # the console sig drifts
    with_edit("the console sig drifts", "h",
              "#define STAGE90_USB_STREAM_CONSOLE_SIG   0x43474244u",
              "#define STAGE90_USB_STREAM_CONSOLE_SIG   0x43474245u",
              "CONSOLE_SIG")
    # the data offset drifts off the 12-byte header
    with_edit("the console data offset drifts", "h",
              "#define STAGE90_USB_STREAM_OFF_DATA      12u",
              "#define STAGE90_USB_STREAM_OFF_DATA      16u",
              "OFF_DATA")
    # the alias base drifts off the ring + 1 MB
    with_edit("the alias base drifts", "h",
              "STAGE90_USB_STREAM_CONSOLE_VA    (STAGE90_USB_STREAM_RAM_CONSOLE_BASE + 0x01000000u)",
              "STAGE90_USB_STREAM_CONSOLE_VA    (STAGE90_USB_STREAM_RAM_CONSOLE_BASE + 0x00200000u)",
              "CONSOLE_VA")
    # the completion reads qh.curr instead of the dTD token
    with_edit("the completion reads qh.curr", "c",
              "token = td[STAGE90_USB_ENUM_TD_OFF_TOKEN / 4u];",
              "token = *(volatile uint32_t *)(uintptr_t)((uintptr_t)qh + STAGE90_USB_ENUM_QH_OFF_CURR);",
              "QH_OFF_CURR")
    # the stream enables the endpoint itself (the handover broken)
    with_edit("the stream writes ENDPTCTRL", "c",
              "usb_stream_write32(STAGE90_USB_ENDPTPRIME, STAGE90_USB_ENUM_EPBIT(STAGE90_USB_ENUM_EP_IN, 1u));",
              "usb_stream_write32(STAGE90_USB_ENDPTCTRL(1u), 0x00c80000u);\n    "
              "usb_stream_write32(STAGE90_USB_ENDPTPRIME, STAGE90_USB_ENUM_EPBIT(STAGE90_USB_ENUM_EP_IN, 1u));",
              "ENDPTCTRL")
    # the enum arm's handover guard is removed
    with_edit("the enum handover guard is removed", "e",
              "#if !STAGE90_XNU_USB_STREAM",
              "#if 1",
              "STAGE90_XNU_USB_STREAM")

    refused = sum(1 for _n, _r, ok in cases if ok)
    for name, reason, ok in cases:
        say("  %-45s %s  %s" % (name, "refused:" if ok else "ACCEPTED:", reason))
    say("  --selftest: %d of %d mutations were refused" % (refused, len(cases)))
    if refused != len(cases):
        raise SystemExit("the falsification battery is not watertight: %d of %d refused"
                         % (refused, len(cases)))


# ==================================================================================================
# (6) P1: the stream's one-writer ring, its publication, where the pump is called, and the HOST MODEL.
# ==================================================================================================
# The static halves read the tree; the model half builds two copies of the ARM's own file (from the
# tree, with ONE textual substitution: the device's register base -> the model's window) into a scratch
# image with the host's clang and runs the model's cases - the qh/dTD core, the host's IN tokens, the
# ring publisher - at -O0 and at the -O1 the arm is built with.
HOST_CC = "clang"
SRC_ENTRY = os.path.join(REPO_ROOT, "src/entry")
TRACE_C = os.path.join(SRC_ENTRY, "entry_trace.c")
MODEL_SRC = os.path.join(HERE, "usb_stream_model.inc")

# the five groups of model cases: (number, the case in usb_stream_model.inc, the argument it takes)
MODEL_CASES = [
    ("A  pc = 0", "model_case_cadence(0u)", "the host idles between polls"),
    ("B  pc = 1", "model_case_cadence(1u)", "one IN token per pass"),
    ("C  pc = 2", "model_case_cadence(2u)", "the host races the CPU"),
    ("D  short", "model_case_short()", "the host reads 100, then stops; the re-prime resumes at the cursor"),
    ("E  ring", "model_case_publish()", "len = 0, the full ring, the room, the 64 KiB wrap"),
    ("F  rate", "model_case_publish_rate()", "the 1 s CNTVCT publication"),
    ("G  refill", "model_case_refill()", "DRAINED -> STREAM on a producer refill; no overwrite while ACTIVE"),
]

# the glue's last macro: from here on the model's text must name no arm static (it names the glue's
# macros only)
MODEL_UNDEF = "#undef MODEL_ARM_TD__END__\n"

# copy 1's poll, declared by name: a call in a model case is never inlined into the arm's code (the model
# must not be measuring the code it changes)
HARNESS_PUMP = r"""
void m1_entry_usb_stream_poll(void) __attribute__((noinline));
"""
HARNESS_PUMP = [HARNESS_PUMP]

# `main`: the model's groups by number (each exits 0 iff its case held)
HARNESS_DISPATCH = r"""
int model_run(int group);

int main(int argc, char **argv)
{
    return model_run((argc > 1) ? atoi(argv[1]) : -1);
}
"""
HARNESS_DISPATCH = [HARNESS_DISPATCH]

def particles_to_text(parts):
    """Concatenate particles; one blank line between two, which is also what keeps two adjacent block
    comments from running into one (`*/` then `/*`)."""
    rows = ["".join(p).rstrip("\n") for p in parts]
    for i in range(len(rows) - 1):
        if rows[i] == "" and re.match(r" \*(?![/*])", rows[i + 1]) \
                and (i == 0 or not rows[i - 1].rstrip().endswith("*/")):
            rows[i] = "\n"                       # the comment's opener; this line was its first row
    return ("\n".join(rows) + "\n").encode()


# the glue between the arm's second copy and the model: ONE prefix, one macro list per arm static, and
# the reset that names every static the cases read (the copy's exact names).
REAL_GLUE_PREAMBLE = "/* the glue: every arm static the cases name -> the SECOND copy of the arm; it ends with\n * its last macro (`MODEL_ARM_TD__END__`), so neither side of the line names the other copy */\n"
REAL_GLUE = r"""
#define MODEL_ARM_TD         m2_g_usb_stream_td
#define MODEL_ARM_PRIME      model_prime
#define MODEL_ARM_ACNTR      model_acntr
#define MODEL_ARM_NOW        model_arm_now
#define MODEL_ARM_RING(k)    m2_g_usb_stream_ring[(k)]
#define MODEL_ARM_HEAD       m2_g_usb_stream_head
#define MODEL_ARM_CURSOR     m2_g_usb_stream_cursor
#define MODEL_ARM_CHUNKS     m2_g_usb_stream_chunks
#define MODEL_ARM_DROPPED    m2_g_usb_stream_dropped
#define MODEL_ARM_PUBLISHED  m2_g_usb_stream_published
#define MODEL_ARM_PUB_NEXT   m2_g_usb_stream_pub_next
#define MODEL_ARM_STATE      m2_g_usb_stream_state
#define MODEL_ARM_ACTIVE     m2_g_usb_stream_active
#define MODEL_ARM_PUBLISH    m2_entry_usb_stream_ring_publish
#define MODEL_ARM_TD__END__
#define MODEL_RUN(pc)        model_pass((pc))
#define MODEL_HZ             %(hz)uu
#define MODEL_RESET()        model_reset_2()

/* the macro block ends here: the two FUNCTIONS that use the .inc\'s names live in REAL_GLUE_TAIL and
 * are placed AFTER the .inc. The macros must precede it (it expands MODEL_GROUPS); the functions must
 * follow it (model_pass calls model_host_in_once and stores model_case_fail). */
"""

REAL_GLUE_TAIL = r"""
/* one poll pass: `pc` host IN tokens, the host stops until the next pass, 1 ms of the arm's CNTVCT,
 * then the arm's poll */
static void model_pass(uint32_t pc)
{
    uint32_t t;

    for (t = 0u; t < pc; t++)
        if (model_host_in_once() != 0) {
            model_case_fail = 1;                 /* a NAK while bytes were offered: never legal */
            return;
        }
    model_prime = 0u;
    model_arm_now += 19200u;
    m2_entry_usb_stream_poll();
}

/* the copy-2 reset: every static the cases read, to its reset state */
%(reset)s}
"""

# mrun.c: the window page and the register file (ONE object - a store into either is the store the arm's
# accessor reads), mapped over itself where the linker put it; the arm's RAM (the dTD and the buffer it
# names are device-physical addresses) at the address the arm's code names; the cases by name.
MODEL_RUNNER = """/* generated by tools/check_usb_stream.py -- the window page, the arm's RAM, the cases */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>


#define HOST_DRAM_BASE 0x48000000u
#define HOST_REG_BASE  ((uintptr_t)&model_window[0])

/* the arm's window page: the SAME object the accessor's `HOST_REG_BASE + off` names (defined here), mapped
 * over itself (anonymous, zero) - ONE object holding the registers: a model store and the arm's read are
 * one address and one definition (a second register array beside this one read as USBMODE = 0). */
unsigned char model_window[0x1000u] __attribute__((aligned(0x1000)));

static int model_map_one(void *want, unsigned long len, const char *what)
{
    void *got = mmap(want, (size_t)len, PROT_READ | PROT_WRITE, MAP_FIXED | MAP_PRIVATE | MAP_ANONYMOUS,
                     -1, 0);

    printf("  %-6s %p (want %p, %lu bytes)\\n", what, got, want, len);
    if (got != want || (uintptr_t)want < 0x10000u) {
        printf("FAIL the %s could not be mapped at its own address\\n", what);
        return 1;
    }
    memset(got, 0, (size_t)len);
    return 0;
}

void model_place(void);

void model_place(void)
{
    if (model_map_one((void *)HOST_DRAM_BASE, 1u << 16, "dram") != 0
        || model_map_one((void *)&model_window[0], 0x1000u, "window") != 0)
        exit(1);
    printf("  window %p\\n", (void *)&model_window[0]);
}

%(arm_text)s

#include <stdio.h>
#include <string.h>
/* the model's cases and `model_run` (tools/usb_stream_model.inc), beside copy 2; they name this file's
 * placement code above by its own (unprefixed) name - it is the model's furniture, not the arm's */
"""+HARNESS_PUMP[0]+HARNESS_DISPATCH[0]+"%(model_text)s"

# the model's unit, as particles: its own headers, the seams this TU needs, then the glue (which ends the
# arm's names), copy 2 of the arm and the cases.
MODEL_SEAM_PARTICLES = [r"""/* generated by tools/check_usb_stream.py -- the model's unit: the seams it needs, the arm's SECOND
 * copy (`m2_*`), and the cases that drive it (tools/usb_stream_model.inc) */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define HOST_DRAM_BASE 0x48000000u
#define HOST_REG_BASE  ((uintptr_t)&model_window[0])

extern unsigned char model_window[0x1000u] __attribute__((aligned(0x1000)));
uint32_t model_acntr, model_prime, model_now, model_arm_now;
struct model_kv { char k[64]; uint32_t v; uint32_t at; };
#define MODEL_KV_MAX 256u
struct model_kv model_kv[MODEL_KV_MAX];
uint32_t model_kv_n;
uint32_t g_usb_enum_settle = 2u;
uint32_t g_usb_enum_settle_last, g_usb_enum_settle_n, g_usb_enum_settle_gate;
void CleanPoU_DcacheRegion(uintptr_t va, unsigned length);
void FlushPoC_DcacheRegion(uintptr_t va, unsigned length);
uint64_t stage90_cntvct_read(void);
void entry_live_write(const char *key, uint32_t value);
volatile uint32_t *entry_usb_enum_qh_in1(void);
"""]


def model_headers():
    """The arm's headers (the enum chain first: they define what the stream header re-uses)."""
    probe = subprocess.run([HOST_CC, "-E", "-dM", "-x", "c", "-I", SRC_ENTRY, "-"],
                           capture_output=True, text=True, input='#include "entry_usb_stream.h"\n')
    if probe.returncode != 0:
        raise Refused("the macro probe did not preprocess:\n" + probe.stderr[-2000:])
    return probe.stdout


def model_defines():
    defines = {}
    for line in model_headers().splitlines():
        # the tree's own names only: the compiler's built-in macros are not ours to re-define
        if line.startswith("#define STAGE90_"):
            name, _, value = line[len("#define "):].partition(" ")
            defines[name] = value.strip() or "1"
    for need in ("STAGE90_USB_USBMODE", "STAGE90_USB_OTG_BASE", "STAGE90_USB_STREAM_CHUNK",
                 "STAGE90_USB_STREAM_RING_SIZE", "STAGE90_USB_STREAM_RING_MASK"):
        if need in defines:
            continue
        raise Refused("preprocessing entry_usb_stream.h names no `%s`" % need)
    defines["STAGE90_XNU_USB_STREAM"] = "1"        # the ON arm: the model hosts the ring path
    return defines


def arm_statics(text):
    """The file-scope statics of the arm's copy, as its text declares them (what the model resets)."""
    return sorted(set(re.findall(r"(?m)^static[ \t]+(?:volatile[ \t]+)?[A-Za-z_][A-Za-z0-9_]*[ \t\*]+"
                                 r"(g_usb_stream_[A-Za-z0-9_]+)", text)))


# The arm's two inline-assembly statements cannot assemble on x86 ("invalid instruction mnemonic dmb").
# A blanket `#define __asm__` is NOT the fix - glibc's stdio.h uses `asm` in its own declarations, and
# 12 errors follow. So exactly these two are rewritten, and only in the copies this file generates.
_HOST_ASM = [
    ('__asm__ volatile ("dmb" ::: "memory");', '__sync_synchronize();'),
    ('__asm__ volatile ("mrc p15, 0, %0, c14, c0, 0" : "=r"(freq));', 'freq = 19200000u;'),
]


def host_portable_asm(text):
    """Rewrite whichever statements are PRESENT: without_reset splits the file in halves and neither
    half necessarily holds both. The whole-file staleness guard lives in build_harness."""
    out = text
    for old, new in _HOST_ASM:
        out = out.replace(old, new)
    return out


def arm_body(text, prefix=""):
    """The arm's own text with ONE substitution: the device's register base -> the model's window page.
    Exactly the two accessors may name it; the text must carry the two tables the model reads
    (`g_usb_stream_td`, `g_usb_stream_ring`) - a rename must be re-checked here, not silently unhosted."""
    hits = text.count("STAGE90_USB_OTG_BASE")
    if hits != 2:
        raise Refused("entry_usb_stream.c names `STAGE90_USB_OTG_BASE` %d times (want 2: the read and the "
                      "write accessor); the harness's substitution must be re-checked" % hits)
    for need in ("g_usb_stream_td", "g_usb_stream_ring", "g_usb_stream_head", "g_usb_stream_cursor"):
        if not re.search(r"\b%s\b" % need, text):
            raise Refused("entry_usb_stream.c no longer names `%s`: the model's tables must be re-checked"
                          % need)
    text = host_portable_asm(text)
    text = text.replace("STAGE90_USB_OTG_BASE", "HOST_REG_BASE")
    if prefix:
        text = re.sub(r"\b(g_usb_stream_[A-Za-z0-9_]+)\b", lambda m, p=prefix: p + m.group(1), text)
        # **The arm's own FUNCTIONS are prefixed too, not just its statics.** Copy 2 is a second
        # translation-unit-namespace copy of the same file: its public entry points must not collide
        # with copy 1's, and the glue's MODEL_ARM_PUBLISH names `m2_entry_usb_stream_ring_publish`.
        # Prefixing only `g_usb_stream_*` left that definition under its original name, so the model
        # linked with `undefined reference to m2_entry_usb_stream_ring_publish` (and the poll beside
        # it). Only definitions are rewritten here - a *call* between the two copies would need its
        # own handling, and this file has none.
        text = re.sub(r"^(uint32_t|void|int|static void|static int|static uint32_t)\s+"
                      r"(entry_usb_stream_[A-Za-z0-9_]+)\s*\(",
                      lambda m, p=prefix: "%s %s%s(" % (m.group(1), p, m.group(2)),
                      text, flags=re.M)
    return text


def write_bytes(path, body):
    """Write BYTES and read them back: a generated file that does not read back is refused here."""
    with open(path, "wb") as handle:
        handle.write(body)
    with open(path, "rb") as handle:
        back = handle.read()
    if back != body:
        raise Refused("%s: wrote %d bytes, read back %d - the write is not the file"
                      % (os.path.basename(path), len(body), len(back)))


def glue_text(reset_body):
    """The glue between copy 1 and the model: ONE prefix, one macro list per arm name, and the reset
    (`%s` below is the reset body, written where copy 2 is defined)."""
    # The macro half only; REAL_GLUE_TAIL (the functions) is placed after the model's .inc.
    return REAL_GLUE.replace("%(hz)uu", "19200000u")


def reset_lines(statics, arrays=()):
    """Copy 2's statics to their reset state, as text (`m2_*`: the copy's own names).

    `arrays` are file-scope arrays in the arm's source - they cannot be assigned, so they are cleared
    with memset. Read from the source rather than hand-listed, since a hand-list is one more thing
    that can fall behind the file.
    """
    lines = "".join("    m2_%s = 0u;\n" % name for name in statics
                    if name not in arrays and name != "g_usb_stream_pub_next")
    lines += "    m2_g_usb_stream_pub_next = 0xffffffffu;    /* no publication until the deadline */\n"
    for name in sorted(arrays):
        lines += "    memset((void *)m2_%s, 0, sizeof m2_%s);\n" % (name, name)
    return lines


def array_statics(text):
    """The arm's file-scope arrays, by name: `static <type> name[...]`."""
    return set(re.findall(
        r"^static\s+[A-Za-z_][A-Za-z0-9_\s\*]*?\b(g_usb_stream_[A-Za-z0-9_]+)\s*\[", text, re.M))


def without_reset(text):
    """The arm's text up to its statics (every file-scope name is declared there): the model's glue and
    its reset are placed between the statics and the functions their reset clears."""
    at = text.find("g_usb_stream_")
    if at < 0:
        raise Refused("entry_usb_stream.c has no `g_usb_stream_*` statics: the glue's seam is gone")
    line = text.rfind("\n", 0, at) + 1
    return text[:line], text[line:]


def carry_join(parts):
    """Join particles for `particles_to_text`, carrying the comments the copy would otherwise drop: a blank
    line ends the row that drew it - so an unterminated comment is closed there (`*/`: one line of a
    comment's original form may have been a blank line), and a comment whose opener WAS a blank line (its
    first line is a ` *` row) gets the `/*` its line's head used to be."""
    out, open_ = [], False
    for part in parts:
        if open_ and part.strip() == "":
            out[-1] += "*/"
            open_ = False
        if (not open_ and part.startswith("\n") and re.match(r" \*(?![/*])", part.lstrip("\n")[0:2])
                and out and not out[-1].rstrip("\n").endswith("*/") and not out[-1].lstrip().startswith("/*")):
            part = "/*\n" + part.lstrip("\n")
        head = part.split("\n", 1)[0]
        if "/*" in head and "*/" not in head:
            open_ = True
        elif "*/" in head:
            open_ = False
        out.append(part)
    return out


def build_harness(scratch):
    """Write the image's sources into `scratch`; return the model's argv.

    Every `STAGE90_*` macro is taken from the headers AS THE PREPROCESSOR SEES THEM (`-E -dM`): one
    `#define` per name, the later re-definition winning, each with its value - so the arm's copy compiles
    against the tree's own text, read, not retyped."""
    if shutil.which(HOST_CC) is None:
        raise Refused("`%s` is not on PATH: the host model needs a compiler" % HOST_CC)
    if not os.path.isfile(MODEL_SRC):
        raise Refused("%s is missing (the host model's core)" % MODEL_SRC)
    defines = model_defines()
    dflags = ["-D%s=%s" % kv for kv in sorted(defines.items())]
    text = read(STREAM_C)
    # The substitution list must still describe this file, or the model would silently
    # run without the arm's real barrier and counter read.
    for _old, _new in _HOST_ASM:
        if _old not in text:
            raise Refused("inline assembly statement %r is gone from entry_usb_stream.c; "
                          "the host model's substitution list is stale" % _old)
    statics = arm_statics(text)
    for need in ("g_usb_stream_ring", "g_usb_stream_td", "g_usb_stream_head", "g_usb_stream_cursor"):
        if need not in statics:
            raise Refused("entry_usb_stream.c declares no file-scope `%s`: the model's tables must be "
                          "re-checked against the arm" % need)
    plain = strip_comments(text)
    keys = len(re.findall(r'entry_live_write\("xnu_live_usb_stream_[a-z_]+"', plain))
    # every identifier the arm defines at file scope and copy 2 renames: prefixed, so neither copy's name
    # has file scope in the other's unit and the two units' statics cannot collide
    outer = {m for m in re.findall(r"(?m)^(?:static[ \t]+)?[A-Za-z_][A-Za-z0-9_ \t\*]*?\b([A-Za-z_][A-Za-z0-9_]*)"
                                   r"\s*(?:\([^;{]*\)|\[|;|=)", plain)
             if m.startswith(("g_usb_stream_", "usb_stream_", "entry_usb_stream_"))}
    for m in re.findall(r"typedef\s+[^;]*?\b([A-Za-z_][A-Za-z0-9_]*)\s*;", plain):
        outer.add(m)
    outer.add("USB_STREAM_ST_DRAINED")        # an enum constant: its enumerator is the name
    unfinished = sorted(n for n in outer if not re.search(r"\b%s\s*[;{=(\[]" % n, plain))
    if unfinished:
        raise Refused("the arm's file-scope names the copy-2 rename cannot prefix (no definition after "
                      "them - a file-scope name that is only USED, like a call in a function body, would be "
                      "renamed and not defined): %s" % ", ".join(unfinished))
    model_code = read(MODEL_SRC) % {"source_len": 4096, "nkeys": keys}
    if "%(source_len)" in model_code or "%%[" in model_code:
        raise Refused("the model's text did not format ([[mi4-empty-model-text-passes-verify]])")
    groups = "".join('    MODEL_GROUP(%d, %s)\n' % (i, call)
                     for i, (_name, call, _why) in enumerate(MODEL_CASES))
    # ONE unit: the arm is compiled twice by the prefix (`m1_`/`m2_`), and the model's cases live beside
    # copy 2 - the model's reset of copy 2 is `MODEL_RESET` -> `model_reset_2`, so the glue and the cases
    # are one text from `MODEL_RESET` on and copy 2 never has to be renamed at all.
    runner = MODEL_RUNNER.replace("%(dram_base)s", "0x48000000u")
    if "%(dram_base)" in runner or "%[" in runner:
        raise Refused("the runner's text did not format")
    if "%(arm_text)s" not in runner:
        raise Refused("the runner does not carry the arm's copy: the one-unit layout is gone")
    head, _, runner_tail = runner.partition("%(arm_text)s")
    if "model_window" not in head or "\n}\n" not in head:
        raise Refused("the runner's head does not hold the window page and its mapping")
    first, rest = without_reset(plain)
    glue = glue_text("static void model_reset_2(void)\n{\n    (void)model_kv_n;\n" + reset_lines(statics, array_statics(text)))
    # Forward declarations: the .inc expands MODEL_RUN -> model_pass and MODEL_RESET -> model_reset_2
    # before either is defined, and an implicit first call would collide with the later `static`
    # definition ("static declaration follows non-static").
    glue = ("static void model_pass(uint32_t pc);\n"
            "static void model_reset_2(void);\n") + glue
    glue_tail = REAL_GLUE_TAIL.replace("%(hz)uu", "19200000u").replace(
        "%(reset)s",
        "static void model_reset_2(void)\n{\n    (void)model_kv_n;\n"
        + reset_lines(statics, array_statics(text)))
    if "MODEL_RESET()        model_reset_2()" not in glue:
        raise Refused("the glue's `MODEL_RESET` is not the copy-2 reset: the one-unit layout is gone")
    # MODEL_GROUPS is a MACRO the glue defines; the .inc guards it with #ifndef/#error precisely so a
    # .inc included without its glue is refused. Substituting the identifier in the text fed the case
    # list into that guard.
    cases = model_code
    groups_define = "#define MODEL_GROUPS \\\n" + " \\\n".join(
        "    " + g.strip() for g in groups.splitlines()) + "\n"
    # glue_tail goes where the .inc lands - right AFTER it.
    runner_tail = runner_tail.replace("%(model_text)s", cases + "\n" + glue_tail)
    tail_head = runner_tail.lstrip("\n").split("\n", 1)[0]
    if not (tail_head.lstrip().startswith("#include") or tail_head.lstrip().startswith("\n")):
        raise Refused("the runner's tail does not open with its headers (they would be spliced onto the "
                      "last line of the previous particle): %r" % tail_head[:60])
    unit = particles_to_text(carry_join(
        # Order, and why each position is forced:
        #   head, copy 1        - the first copy of the arm
        #   glue                - the MODEL_* macros (the .inc expands MODEL_RUN/MODEL_RESET, so these
        #                         must be defined before it) and the two forward declarations
        #   arm_body(rest)      - copy 2, the names the macros point at
        #   MODEL_UNDEF         - ends the macro block
        #   groups_define       - MODEL_GROUPS, which the .inc's guard requires
        #   runner_tail         - the .inc, then glue_tail (model_pass/model_reset_2, which need the
        #                         .inc's statics), then the dispatch and main
        # HARNESS_DISPATCH[0] is not appended on its own: MODEL_RUNNER already carries it.
        real_prelude(defines) + [head, real_arm(first), glue, arm_body(rest, "m2_"), MODEL_UNDEF,
                                 groups_define, runner_tail]))
    write_bytes(os.path.join(scratch, "harness.c"), unit)
    return [HOST_CC, "-std=gnu11", "-O1", "-Wall", "-Wextra", "-Wno-attributes", "-Wno-c99-extensions",
            "-Wno-unused-function", "-I", scratch, "-I", SRC_ENTRY] + dflags + \
           ["-o", os.path.join(scratch, "hs"), os.path.join(scratch, "harness.c")]


def host_model():
    """Build the host model and run every case on both copies; PASS iff each group exits 0."""
    scratch = tempfile.mkdtemp(prefix="usbstream-hs-")
    try:
        argv = build_harness(scratch)
        say("  host model: %s" % " ".join(argv))
        # Every group runs at -O0 AND at the -O1 the arm's own file is built with: the register and ring
        # paths must not depend on the host optimizer. A non-PIE image (`mrun.c` maps integer addresses):
        # `-Ttext-segment` rather than `-Ttext` (the segment's base is the address), `-z max-page-size` so
        # the `aligned(64 KiB)` ring's own segment is not mapped from file offset 0.
        for opt_level in ("-O0", "-O1"):
            opt = os.path.join(scratch, "hs-%s" % opt_level)
            o_argv = list(argv)
            o_argv[o_argv.index("-O1")] = opt_level
            o_argv[o_argv.index("-o") + 1] = opt
            o_argv += ["-fno-pie", "-no-pie", "-Wl,-Ttext-segment=0x2000000",
                       "-Wl,-z,common-page-size=0x1000", "-Wl,-z,noseparate-code",
                       "-Wl,-z,max-page-size=0x1000"]
            build = subprocess.run(o_argv, capture_output=True, text=True)
            if build.returncode != 0:
                raise Refused("the host model did not build at %s:\n  %s"
                              % (opt_level, "\n  ".join((build.stderr or build.stdout).strip()
                                                        .splitlines()[-12:])))
            bad = [ln for ln in build.stderr.splitlines() if "warning:" in ln]
            if bad:
                raise Refused("the host model builds at %s with warnings the arm's own build (-Werror) "
                              "would refuse:\n  %s" % (opt_level, "\n  ".join(bad[:8])))
            placed = subprocess.run([opt], capture_output=True, text=True)
            for i, (name, _call, why) in enumerate(MODEL_CASES):
                run = subprocess.run([opt, str(i)], capture_output=True, text=True)
                ok = run.returncode == 0 and "FAIL" not in run.stdout
                say("  %s %-6s %-6s %s" % (opt_level, name, "PASS" if ok else "FAIL", why))
                if not ok:
                    for line in run.stdout.splitlines():
                        say("      " + line)
                    raise Refused("the host model (%s, case %s) refuted the arm's state machine:\n%s"
                                  % (opt_level, name, run.stdout.strip()))
    finally:
        if os.environ.get("USB_STREAM_KEEP_SCRATCH"):
            say("  scratch kept: %s" % scratch)
        else:
            shutil.rmtree(scratch, ignore_errors=True)


NONE, BLOCK, STRING = 0, 1, 2


def lex_c(text):
    """A C text split into (`kind`, text) spans by the compiler's own token rules: `code` (code and
    `//` comments), `comment` (a `/* */` comment, unmatched is a refusal) and `lit` (a string or char
    literal). Nothing outside a literal is ever cut out of `code`, so a line's head can be trusted."""
    spans, cur, i, n = [], [], 0, len(text)
    state, q = NONE, ""

    def flush():
        if cur:
            spans.append(("code", "".join(cur)))
            del cur[:]

    while i < n:
        if state == NONE:
            if text.startswith("/*", i):
                flush()
                j = text.find("*/", i + 2)
                if j < 0:
                    raise Refused("an unterminated comment: the text cannot be copied, let alone prefixed")
                spans.append(("comment", text[i:j + 2]))
                i = j + 2
                continue
            if text.startswith("//", i):
                j = text.find("\n", i)
                cur.append(text[i:] if j < 0 else text[i:j])
                i = n if j < 0 else j
                continue
            if text[i] in "\"'":
                flush()
                state, q, start = STRING, text[i], i
                i += 1
                continue
            cur.append(text[i])
            i += 1
        elif state == STRING:
            ch = text[i]
            if ch == "\\" and i + 1 < n:
                i += 2
                continue
            i += 1
            if ch == q:
                spans.append(("lit", text[start:i]))
                state = NONE
    if state == STRING:
        spans.append(("lit", text[start:]))
    flush()
    return spans


C_TYPE_WORDS = frozenset("""
void char short int long float double signed unsigned const volatile static extern register
struct union enum bool size_t ssize_t off_t ptrdiff_t uintptr_t intptr_t
uint8_t uint16_t uint32_t uint64_t int8_t int16_t int32_t int64_t
uintmax_t intmax_t u_int u_long u_char u_short va_list
""".split())


def prefix_copy(text, prefix):
    """The arm's text as copy 1: every identifier the copy defines at file scope is `prefix`ed where it is
    DEFINED - in a `static`/`extern` declaration's head (the identifier right after the type words), or as
    a call's callee at brace depth 0 (an external function's own definition). A declaration's identifiers
    are prefixed too (a parameter may share a file-scope name), so the copy's names never reach the other
    unit. Comments and literals are carried as their own spans: the prefix can never land inside one."""
    spans = lex_c(text)
    out = []
    buf = []                   # consecutive code spans, lexed as one (a comment splits nothing)
    depth = 0

    def emit():
        joined = "".join(buf)
        del buf[:]
        if not joined:
            return
        # The line breaks are CARRIED: every non-newline run is preceded by the text (the newlines)
        # that separated it from the previous run, copied verbatim. Nothing is inserted anywhere, so a
        # run that ends mid-line - which is what a string-literal or comment span makes - stays
        # attached to what follows it.
        pieces = []
        last_end = 0
        for seg in re.finditer(r"[^\n]+", joined):
            line = seg.group(0)
            cut = line.find("#")
            if cut >= 0 and (cut == 0 or not line[:cut].strip()) and seg.start() == 0:
                tail = line[cut:]
                line = re.sub(r"\b(g_usb_stream_[A-Za-z0-9_]+)\b", lambda mm: prefix + mm.group(1), line)
                m = re.match(r"#define\s+([A-Za-z_][A-Za-z0-9_]*)", line[cut:])
                if m:
                    line = line[:cut + m.start(1)] + prefix + m.group(1) + line[cut + m.end(1):]
            head = re.match(r"[ \t]*(static|extern)\b", line)
            if head:
                m = re.match(r"[ \t]*(?:static|extern)\b[ \t]+((?:const|volatile|unsigned|signed|struct|enum"
                             r"|union|[A-Za-z_][A-Za-z0-9_]*)[ \t*]+)+", line)
                if m:
                    k = m.end()
                    # Only NAMES get the prefix. The parameter list carries types too
                    # (`uintptr_t va, unsigned length`), and prefixing everything turned them into
                    # m1_uintptr_t/m1_unsigned/m1_const, which do not exist.
                    rest = re.sub(r"\b([A-Za-z_][A-Za-z0-9_]*)\b",
                                  lambda mm: mm.group(1) if mm.group(1) in C_TYPE_WORDS
                                  else prefix + mm.group(1), line[k:])
                    line = line[:k] + rest
            elif depth == 0:
                m = re.match(r"[ \t]*(?:const[ \t]+|static[ \t]+|volatile[ \t]+)*[A-Za-z_][A-Za-z0-9_ \t\*]*?"
                             r"\b([A-Za-z_][A-Za-z0-9_]*)[ \t]*\([^;]*\)[ \t]*$", line)
                if m and line.rstrip().endswith(")") and "=" not in line:
                    line = line[:m.start(1)] + prefix + m.group(1) + line[m.end(1):]
            else:
                m = re.match(r"[ \t]*(static|extern)\b", line)
                if m:
                    k = len(m.group(0))
                    line = line[:k] + re.sub(r"\b([A-Za-z_][A-Za-z0-9_]*)\b",
                                             lambda mm: prefix + mm.group(1), line[k:])
            pieces.append(joined[last_end:seg.start()])
            pieces.append(line)
            last_end = seg.end()
        pieces.append(joined[last_end:])
        out.append("".join(pieces))

    # depth is PREPROCESSOR-AWARE: the file's `#if/#else/#endif` arms are both present in the text,
    # so counting every brace made depth drift and a top-level function fell into the "inside a
    # function" branch. A stack restores the depth at each #else/#endif to what it was at the #if.
    pp_stack = []
    for kind, span in spans:
        if kind != "code":
            emit()
            out.append(span)
            continue
        buf.append(span)
        for line in span.split("\n"):
            word = line.strip()
            if re.match(r"#\s*if", word):
                pp_stack.append(depth)
            elif re.match(r"#\s*(else|elif)", word):
                if pp_stack:
                    depth = pp_stack[-1]
            elif re.match(r"#\s*endif", word):
                if pp_stack:
                    depth = pp_stack.pop()
            else:
                depth += line.count("{") - line.count("}")
    emit()
    return "".join(out)


def real_arm(text):
    return prefix_copy(host_portable_asm(text), "m1_")



HEADERS = ("entry_usb_dev.h", "entry_usb_enum.h", "entry_usb.h", "entry_usb_stream.h")


def header_particles(path, defines):
    """A header as copy 1's text: the same prefix rule as `real_arm`, minus what the `-D`s already say - a
    header guard they set (`#ifndef X`, `X` among them) with everything to its `#endif` (the body would
    not be seen at all), and every `#define STAGE90_*` (the macro probe has resolved them)."""
    text = read(path)
    lines = text.splitlines(keepends=True)
    kept, inside = [], False
    for line in lines:
        word = line.strip()
        if inside:
            if word.startswith("#endif"):
                inside = False
            continue
        if word.startswith("#ifndef ") and word.split()[1] in defines:
            inside = True
            continue
        if re.match(r"#define STAGE90_", word):
            continue
        kept.append(line)
    return [prefix_copy("".join(kept), "m1_")]


def real_prelude(defines):
    """The harness TU before the arm's text (copy 1): the `STAGE90_*` macros as the preprocessor resolved
    them, the arm's headers as particles (each run of their lines under `m1_`, so their static definitions
    are copy 1's), and the seams this TU sees."""
    body = ["/* the harness (copy 1) */\n",
            "#include <stdint.h>\n#include <string.h>\n",
            "".join("#define %s %s\n" % kv for kv in sorted(defines.items()))]
    for name in HEADERS:
        body += header_particles(os.path.join(SRC_ENTRY, name), defines)
    body.append(r"""/* the DEVICE's window: the model's window page (the runner maps it), given to the arm by NAME -
 * measured on this host, clang 14 folds `0x40000000u + x` and `0x48000000u + x` to the TEXT `406`. */
extern unsigned char model_window[0x1000u] __attribute__((aligned(0x1000)));
#define HOST_REG_BASE ((uintptr_t)&model_window[0])

/* the core's state, this arm's clock, the live channel, and the enum arm's exports */
uint32_t model_acntr, model_prime, model_now, model_arm_now;
struct model_kv { char k[64]; uint32_t v; uint32_t at; };
#define MODEL_KV_MAX 256u
struct model_kv model_kv[MODEL_KV_MAX];
uint32_t model_kv_n;
uint32_t g_usb_enum_settle = 2u;
uint32_t g_usb_enum_settle_last, g_usb_enum_settle_n, g_usb_enum_settle_gate;

void CleanPoU_DcacheRegion(uintptr_t va, unsigned length) { (void)va; (void)length; }
void FlushPoC_DcacheRegion(uintptr_t va, unsigned length) { (void)va; (void)length; }
uint64_t stage90_cntvct_read(void) { return (uint64_t)model_now; }
void entry_live_write(const char *key, uint32_t value)
{
    if (model_kv_n < MODEL_KV_MAX && strlen(key) < sizeof model_kv[0].k) {
        strcpy(model_kv[model_kv_n].k, key);
        model_kv[model_kv_n].v = value;
        model_kv[model_kv_n].at = model_now;
        model_kv_n++;
    }
}
static uint32_t model_qh[32u * 16u];
volatile uint32_t *entry_usb_enum_qh_in1(void)
{
    return &model_qh[17u * 16u];
}
""")
    return body


def check_ring():
    """P1's ONE writer and its throttled publication, statically: the head has one store and it is after
    the barrier; the drops are counted; the publish is deadline-throttled to 1 s of CNTVCT."""
    body = strip_comments(read(STREAM_C))
    on = body[body.index("#if STAGE90_XNU_USB_STREAM"):] if "#if STAGE90_XNU_USB_STREAM" in body else body
    pub = body[body.index("uint32_t entry_usb_stream_ring_publish"):]
    pub = pub[:pub.index("\n}\n") + 3]
    heads = len(re.findall(r"(?<![=!<>])g_usb_stream_head\s*=(?!=)", pub))
    if heads != 1:
        raise Refused("entry_usb_stream_ring_publish stores `g_usb_stream_head` %d times (want 1: the ONE "
                      "publish, after the dmb)" % heads)
    store = re.search(r"g_usb_stream_head\s*=(?!=)[^;]*;", pub).start()
    dmb = pub.find("usb_stream_ring_dmb()")
    if dmb == -1 or dmb > store:
        raise Refused("the ring's `head` is published before `usb_stream_ring_dmb()`: the core would read "
                      "bytes that are not in DRAM yet (the producer's rule 2 then 3)")
    if not re.search(r"g_usb_stream_dropped\s*\+=", pub):
        raise Refused("the ring publisher does not count what it drops (`g_usb_stream_dropped += len - take`)")
    every = re.findall(r'entry_live_write\("xnu_live_usb_stream_[a-z_]+"', body)
    in_pub = re.findall(r'entry_live_write\("xnu_live_usb_stream_[a-z_]+"', pub)
    if in_pub:
        raise Refused("entry_usb_stream_ring_publish writes %d `xnu_live_usb_stream_*` key(s): the producer "
                      "takes bytes, the throttle's publication writes keys" % len(in_pub))
    fn = body.index("static void usb_stream_publish(void)")
    fbody = body[fn:body.index("\n}\n", fn)]
    keys = re.findall(r'entry_live_write\("xnu_live_usb_stream_[a-z_]+"', fbody)
    if len(keys) != len(every):
        raise Refused("%d of the stream's %d `xnu_live_usb_stream_*` keys are written OUTSIDE "
                      "usb_stream_publish (the throttle): every pass would write them" % (len(every) - len(keys),
                                                                                       len(every)))
    gate = fbody.index("if ((int32_t)(now - g_usb_stream_pub_next) < 0)")
    stamp = fbody.index("g_usb_stream_pub_next = now")
    if not gate < stamp < fbody.index("entry_live_write"):
        raise Refused("the publication does not gate on its deadline BEFORE it stamps the next one and "
                      "writes: a failed clock could repeat a publication within one second")
    if not re.search(r"USB_STREAM_PUBLISH_TICKS\s+\(\(uint64_t\)USB_STREAM_CNTVCT_HZ\)", body):
        raise Refused("the publication's deadline is not one second of CNTVCT (`USB_STREAM_PUBLISH_TICKS`)")
    say("  ring (source): one storage, after the dmb; dropped counted; %d keys, all inside the 1 s "
        "publication" % len(keys))


def check_call_sites():
    """P1's site rule: every call in the tree to `entry_usb_*_poll` is a bare statement of its own inside
    `__wrap_machine_idle` (D13's live site) or, on the 4570 arm, inside `__wrap_Idle_load_context` - and
    never inside anything else."""
    trace = strip_comments(read(TRACE_C))
    sites = []
    for m in re.finditer(r"(?<![A-Za-z0-9_>.])(entry_usb_(?:enum|stream)_poll)\s*\(\s*\)\s*;", trace):
        before = trace[:m.start()]
        line_start = before.rfind("\n") + 1
        head = trace[line_start:m.start()]
        if head.strip():
            # `return f();`, `x = f();`, `if (f())` ...: not a statement of its own
            raise Refused("the `%s()` call at entry_trace.c:%d is part of a larger expression (`%s`): the "
                          "poll must be a statement of its own, printed by the site rule"
                          % (m.group(1), trace.count("\n", 0, m.start()) + 1, head.strip()[-40:]))
        fn = None
        for f in re.finditer(r"(?m)^[A-Za-z_][A-Za-z0-9_ \*]*\b(__wrap_[A-Za-z0-9_]+|__real_[A-Za-z0-9_]+)"
                             r"\s*\([^;{]*\)\s*$", trace[:m.start()]):
            fn = f.group(1)
        sites.append((trace.count("\n", 0, m.start()) + 1, m.group(1), fn))
    if not sites:
        raise Refused("entry_trace.c calls neither `entry_usb_enum_poll()` nor `entry_usb_stream_poll()`: "
                      "the arms would never run")
    allowed = {"__wrap_machine_idle", "__wrap_Idle_load_context"}
    for line, name, fn in sites:
        if fn not in allowed:
            raise Refused("entry_trace.c:%d calls `%s()` from `%s` - not `__wrap_machine_idle` (D13) or "
                          "`__wrap_Idle_load_context` (4570)" % (line, name, fn))
    say("  call sites: %d `entry_usb_*_poll` calls, each a statement of its own in %s"
        % (len(sites), " / ".join(sorted({fn for _l, _n, fn in sites}))))
def main():
    parser = argparse.ArgumentParser(description="P1: the USB stream arm")
    parser.add_argument("--image", help="the linked xnu_arm_entry.elf")
    parser.add_argument("--selftest", action="store_true", help="run the falsification battery")
    parser.add_argument("--model", action="store_true",
                        help="build and run the host model (needs clang); implied by --selftest")
    args = parser.parse_args()

    try:
        check_sources()
        if args.image:
            check_image(args.image)
    except Refused as exc:
        print("FAIL: " + str(exc), file=sys.stderr)
        return 1

    if args.model or args.selftest:
        try:
            host_model()
        except Refused as exc:
            if args.model:
                print("FAIL: " + str(exc), file=sys.stderr)
                return 1
            say("  host model: skipped - %s" % exc)

    if args.selftest:
        try:
            selftest()
        except SystemExit as exc:
            print("FAIL: " + str(exc), file=sys.stderr)
            return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
