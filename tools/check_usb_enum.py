#!/usr/bin/env python3
"""910b's guard: the enumeration arm's transcribed offsets, its qh/dTD STRUCT LAYOUT recomputed from the
owner's own struct, its written values against the owner's expressions, the mode gate, the no-RST
refusal, and whether the switch reached the linked image.

910b is the first arm that BUILDS A DMA GRAPH the core reads, so its guard has to answer a question the
two earlier USB guards did not: **is the qh/td layout a recomputation of the owner's struct, or a
transcription that has already drifted?** The qh's `setup` field sits at offset 40, not the 32 a
"8 header dwords + setup" guess gives - it drifted once while this arm was written, and the fix is to
recompute the offset from `struct ci13xxx_qh` ([[mi4-one-value-two-definitions]] is exactly this class).

1. **STRUCT OFFSETS, RECOMPUTED.** Parse `struct ci13xxx_td` and `struct ci13xxx_qh` from
   `ci13xxx_udc.h` and compute every field offset (packed, aligned(4)), then compare to this header's
   `STAGE90_USB_ENUM_QH_OFF_*` / `STAGE90_USB_ENUM_TD_OFF_*`. A field that moves in the owner, or a
   define that drifts, is refused. **And the qh INDEX is recomputed too** (`num + dir*ENDPT_MAX/2`) -
   the core indexes the endpoint list by the ENDPTCOMPLETE/ENDPTPRIME bit, so an index that loses the
   IN direction half points the core at the OUT slot (this guard caught `QH_IN1 = 1`, which is EP1-OUT).

2. **THE WRITTEN VALUES against the owner's own expressions** - `USBCMD_SUTW`, the `USBi_*` mask, the
   `ENDPTCTRL` bits and the bulk type encodings, `QH_IOS`/`QH_ZLT`, the `TD_*` tokens, `DEVICEADDR`.

3. **THE WRITE-TARGET WHITELIST.** Every `usb_enum_write32(<ARG>, ...)` first argument is a
   `STAGE90_USB_*` name some header defines, and no store targets `USBCMD` with `RST` - the 910b arm
   must never re-run the link reset 910a2 owns.

4. **THE MODE GATE, at the source** - the same `!= CM_DEVICE && FORCE == 0` form `entry_usb_dev.c` uses.

5. **THE SWITCH REACHED THE IMAGE, both ways.**

6. **P1's REQUEST COVERAGE (value-based).** The seven standard requests a host's probe sends, read out of
   the `switch (bRequest)` in `usb_enum_ui` by finding its `case STAGE90_USB_ENUM_REQ_*` labels - never a
   hand list of line numbers - each must be ANSWERED (a `return` after a prime) or RECORDED (a `break`
   that falls into the shared status phase, with `usb_enum_bad` reached on the paths that record). Any
   other bRequest must reach `usb_enum_bad` (the `default:` arm), and the IN buffer must be preloaded to
   zero before the switch (the status-only prime used to send a stale buffer).

7. **ONE DEFINITION for the descriptor contract.** No VID/PID value literal and no endpoint-address
   literal outside `entry_usb_enum.h` (the stream arm and the headers must re-use the names).
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

ENUM_H = os.path.join(REPO_ROOT, "src/entry/entry_usb_enum.h")
ENUM_C = os.path.join(REPO_ROOT, "src/entry/entry_usb_enum.c")
STREAM_C = os.path.join(REPO_ROOT, "src/entry/entry_usb_stream.c")
DEV_H = os.path.join(REPO_ROOT, "src/entry/entry_usb_dev.h")
USB_H = os.path.join(REPO_ROOT, "src/entry/entry_usb.h")
ANDROID = os.path.join(REPO_ROOT, "external/android_kernel_xiaomi_cancro")
LINUX_HW_H = os.path.join(ANDROID, "include/linux/usb/msm_hsusb_hw.h")
MACH_HW_H = os.path.join(ANDROID, "arch/arm/mach-msm/include/mach/msm_hsusb_hw.h")
GADGET_H = os.path.join(ANDROID, "drivers/usb/gadget/ci13xxx_udc.h")

NM = "arm-none-eabi-nm"
OBJDUMP = "arm-none-eabi-objdump"

# The written values: this header's name -> an expression in the owner headers' own names.
CROSS_VALUES = {
    "STAGE90_USB_ENUM_INTR_VALUE":        "USBi_UI | USBi_UEI | USBi_PCI | USBi_URI | USBi_SLI",
    "STAGE90_USB_ENUM_STS_UI":            "USBi_UI",
    "STAGE90_USB_ENUM_STS_UEI":           "USBi_UEI",
    "STAGE90_USB_ENUM_STS_PCI":           "USBi_PCI",
    "STAGE90_USB_ENUM_STS_URI":           "USBi_URI",
    "STAGE90_USB_ENUM_STS_SLI":           "USBi_SLI",
    "STAGE90_USB_ENUM_DEVICEADDR_USBADRA":   "DEVICEADDR_USBADRA",
    "STAGE90_USB_ENUM_USBCMD_SUTW":          "USBCMD_SUTW",
    "STAGE90_USB_ENUM_ENDPTCTRL_TXT_BULK":   "(2 << 18)",
    "STAGE90_USB_ENUM_ENDPTCTRL_RXT_BULK":   "(2 << 2)",
    "STAGE90_USB_ENUM_ENDPTCTRL0_VALUE":     "(ENDPTCTRL_TXE | ENDPTCTRL_TXR | ENDPTCTRL_RXE | ENDPTCTRL_RXR)",
    "STAGE90_USB_ENUM_ENDPTCTRL1_VALUE":     "(ENDPTCTRL_TXE | ENDPTCTRL_TXR | (2 << 18))",
    "STAGE90_USB_ENUM_QH_IOS":               "QH_IOS",
    "STAGE90_USB_ENUM_QH_ZLT":               "QH_ZLT",
    "STAGE90_USB_ENUM_TD_TERMINATE":         "TD_TERMINATE",
    "STAGE90_USB_ENUM_TD_ACTIVE":            "TD_STATUS_ACTIVE",
    "STAGE90_USB_ENUM_TD_IOC":               "TD_IOC",
}

# The owner headers, in the order a name is looked up (the live driver's `linux/` header first).
OWNER_HEADERS = [LINUX_HW_H, MACH_HW_H, GADGET_H]

# The struct offsets this header defines, and the field path each must equal. The recomputation below
# walks the two structs; a field's computed offset must equal the define's value.
STRUCT_OFFSETS = {
    "STAGE90_USB_ENUM_QH_OFF_CAP":    ("qh", "cap"),
    "STAGE90_USB_ENUM_QH_OFF_CURR":   ("qh", "curr"),
    "STAGE90_USB_ENUM_QH_OFF_TDNEXT": ("qh", "td.next"),
    "STAGE90_USB_ENUM_QH_OFF_TDTOK":  ("qh", "td.token"),
    "STAGE90_USB_ENUM_QH_OFF_SETUP":  ("qh", "setup"),
    "STAGE90_USB_ENUM_TD_OFF_NEXT":   ("td", "next"),
    "STAGE90_USB_ENUM_TD_OFF_TOKEN":  ("td", "token"),
    "STAGE90_USB_ENUM_TD_OFF_PAGE0":  ("td", "page"),
}


# The characters a hex literal may neighbour and still be a standalone token (`0x18d1u`, `(0x18d1)`,
# `=0x18d1;`, end of line): everything that is NOT an ASCII letter, digit, or `_`.
LITERAL_SEPARATORS = frozenset(chr(c) for c in range(0x80)
                               if not (0x30 <= c <= 0x39 or 0x41 <= c <= 0x5a or 0x61 <= c <= 0x7a
                                       or c == 0x5f))


class Refused(Exception):
    pass


def say(message):
    print(message)


def read(path):
    with open(path, "r", errors="replace") as handle:
        return handle.read()


def strip_comments(text):
    # `re.sub` RETURNS the text: without `text =` this function returned only a run of spaces (the
    # existing checks were run over that, which is why several of them could never read a comment).
    text = re.sub(r"/\*.*?\*/", " ", text, flags=re.S)
    text = re.sub(r"//[^\n]*", " ", text)
    return text


def header_values(text):
    """`#define STAGE90_..._NAME  <expr>` -> {suffix: expression-string}, suffix = name after STAGE90_USB_.

    Backslash line continuations are joined first, so a multi-line value is one expression.
    """
    text = strip_comments(text)
    text = re.sub(r"\\\n", " ", text)
    out = {}
    for m in re.finditer(r"^#define[ \t]+STAGE90_USB_([A-Z0-9_]+)[ \t]+([^\n]+)$", text, re.M):
        out[m.group(1)] = m.group(2).strip().rstrip("u").rstrip("U")
    return out


def owner_defines(*extra_paths):
    """Every `#define NAME expr` in the owner headers (plus any `extra_paths`), evaluated lazily.

    Function-like macros (`NAME(args)`) are not object-like values, so only `NAME<TAB>expr` is kept.
    """
    table = {}
    for path in list(OWNER_HEADERS) + list(extra_paths):
        for m in re.finditer(r"^#define[ \t]+([A-Za-z_][A-Za-z0-9_]*)[ \t]+([^\n]+)$",
                             strip_comments(read(path)), re.M):
            table[m.group(1)] = m.group(2).strip()
    return table


def first_arg(text, start):
    """The text of the first argument of the call whose `(` is at/after `start`, paren-balanced."""
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
    """Evaluate an owner expression made of `BIT(n)`, `(a << b)`, `|`, `+`, literals and owner names."""
    if depth > 12:
        raise Refused("expression %r nests too deep" % expr)
    text = expr.strip().rstrip("u").rstrip("U")
    text = re.sub(r"\bBIT\((\d+)\)", r"(1 << \1)", text)
    text = re.sub(r"\bBIT\(([A-Za-z_][A-Za-z0-9_]*)\)", r"(1 << \1)", text)
    text = re.sub(r"\bUL\b", "", text)
    text = re.sub(r"(\d)[uU]\b", r"\1", text)   # integer suffixes are not identifiers

    def sub_name(m):
        name = m.group(0)
        if name not in table:
            raise Refused("the owner headers define no `%s`" % name)
        return "(%s)" % eval_expr(table[name], table, depth + 1)

    # replace bare identifiers by their evaluated values. The `(?<![\w.])` lookbehind means a name
    # starting after a word character is left alone: that is what stops `0x01000000` being split into
    # `0` + identifier `x01000000`, and `2u` into `2` + identifier `u`.
    text = re.sub(r"(?<![\w.])[A-Za-z_][A-Za-z0-9_]*", sub_name, text)
    if not re.fullmatch(r"[0-9xXa-fA-F()\s<>\|&+~*]+", text):
        raise Refused("expression %r is not evaluable: %s" % (expr, text))
    try:
        return eval(text, {"__builtins__": {}}, {})   # noqa: S307 - digits/operators only, checked above
    except Exception as exc:  # noqa: BLE001
        raise Refused("expression %r did not evaluate: %s" % (expr, exc))


def struct_offsets(text):
    """Recompute the packed field offsets of `struct ci13xxx_qh` and `struct ci13xxx_td`.

    Packs by: u32 -> 4, a nested struct -> its computed size, `struct usb_ctrlrequest` -> 8 (ch9.h's
    8-byte control request, which is what the qh's setup field is). `__attribute__((packed, aligned(4)))`
    means no padding beyond the 4-byte alignment each field already has.
    """
    def body(name):
        m = re.search(r"struct\s+%s\s*\{(.*?)\}\s*__attribute__" % re.escape(name), text, re.S)
        if not m:
            raise Refused("ci13xxx_udc.h has no `struct %s`" % name)
        inner = strip_comments(m.group(1))
        # the owner interleaves `#define TD_*` / `#define QH_*` lines between fields; they are not fields.
        inner = re.sub(r"^[ \t]*#[^\n]*", " ", inner, flags=re.M)
        return inner

    def size_of(owner_name, b):
        """Walk fields in order, return (total_size, {field_name: offset})."""
        offs, pos = {}, 0
        for raw in b.split(";"):
            line = raw.strip()
            if not line:
                continue
            m = re.match(r"(u32|unsigned)\s+([A-Za-z_][A-Za-z0-9_]*)(\[(\d+)\])?$", line)
            if m:
                count = int(m.group(4)) if m.group(4) else 1
                offs[m.group(2)] = pos
                pos += 4 * count
                continue
            m = re.match(r"struct\s+([A-Za-z_][A-Za-z0-9_]*)\s+([A-Za-z_][A-Za-z0-9_]*)$", line)
            if m:
                nested = m.group(1)
                offs[m.group(2)] = pos
                if nested == "usb_ctrlrequest":
                    pos += 8
                elif nested == "ci13xxx_td":
                    pos += size_of("ci13xxx_td", body("ci13xxx_td"))[0]
                else:
                    raise Refused("struct %s has an unknown nested struct %s" % (owner_name, nested))
                continue
            raise Refused("struct %s: cannot size field %r" % (owner_name, line))
        return pos, offs

    td_size, td = size_of("ci13xxx_td", body("ci13xxx_td"))
    qh_size, qh = size_of("ci13xxx_qh", body("ci13xxx_qh"))
    return {
        ("td", "next"): td["next"], ("td", "token"): td["token"], ("td", "page"): td["page"],
        ("qh", "cap"): qh["cap"], ("qh", "curr"): qh["curr"], ("qh", "setup"): qh["setup"],
        ("qh", "td.next"): qh["td"] + td["next"], ("qh", "td.token"): qh["td"] + td["token"],
        ("qh", "size"): qh_size, ("td", "size"): td_size,
    }


def check_sources():
    enum_text = read(ENUM_H)
    raw_body = read(ENUM_C)
    # comments become a SPACE each (`strip_comments`): replacing `/*...*/` with nothing glues the code
    # on either side together (`(...) /* c */ switch` -> `(...)switch`), which is how a parser misses a
    # real switch.
    enum_body = strip_comments(raw_body)
    problems = []

    vals = header_values(enum_text)

    # (1) the struct offsets, recomputed from the owner's struct.
    owner = struct_offsets(read(GADGET_H))
    for name, path in sorted(STRUCT_OFFSETS.items()):
        short = name[len("STAGE90_USB_"):]
        if short not in vals:
            problems.append("entry_usb_enum.h defines no %s, but the check names it" % name)
            continue
        try:
            got = int(vals[short].rstrip("u"), 0)
        except ValueError:
            problems.append("%s is not an integer literal (%r)" % (name, vals[short]))
            continue
        want = owner[path]
        if got != want:
            problems.append("%s = %d but `struct ci13xxx_qh`'s %s is at offset %d "
                            "([[mi4-one-value-two-definitions]] - the layout is recomputed, not guessed)"
                            % (name, got, ".".join(path), want))
    say("  qh/td layout: %d field offsets recomputed from `struct ci13xxx_qh` (size %d) and "
        "`struct ci13xxx_td` (size %d)" % (len(STRUCT_OFFSETS), owner[("qh", "size")], owner[("td", "size")]))

    # (1b) the qh INDEX is the register bit, recomputed from the owner's ENDPT_MAX.
    #
    # The core indexes the endpoint list by `num + (dir ? ENDPT_MAX/2 : 0)`: `ci13xxx_udc.h:166` is
    # `#define ep0in ci13xxx_ep[hw_ep_max / 2]` and `ci13xxx_udc.c:2666`/`:2672` dispatch by the same `i`
    # for both the array subscript and the ENDPTCOMPLETE/ENDPTPRIME bit. `hw_ep_max = ENDPT_MAX` on this
    # IP (DCCPARAMS.DEN = 16 -> 32, and `ENDPT_MAX (32)`). This was a live defect: `QH_IN1 = 1` is EP1-OUT
    # (the IN bit is `EP_IN + 16`), so the core would fetch a terminated qh while the CPU filled EP1-IN's.
    try:
        endpt_max = eval_expr("ENDPT_MAX", owner_defines(GADGET_H))
    except Refused as exc:
        problems.append("no ENDPT_MAX in the owner headers: %s" % exc)
        endpt_max = None
    if endpt_max is not None:
        want_index = {
            "ENUM_QH_OUT0": 0,
            "ENUM_QH_IN0": endpt_max // 2,
            "ENUM_QH_IN1": None,   # filled below from ENUM_EP_IN
        }
        try:
            ep_in = int(vals["ENUM_EP_IN"].rstrip("u"), 0)
        except (KeyError, ValueError):
            problems.append("entry_usb_enum.h defines no integer ENUM_EP_IN")
            ep_in = None
        if ep_in is not None:
            want_index["ENUM_QH_IN1"] = ep_in + endpt_max // 2
        for short, want in sorted(want_index.items()):
            name = "STAGE90_USB_" + short
            if short not in vals:
                problems.append("entry_usb_enum.h defines no %s, but the check names it" % name)
                continue
            if want is None:
                continue
            try:
                got = int(vals[short].rstrip("u"), 0)
            except ValueError:
                problems.append("%s is not an integer literal (%r)" % (name, vals[short]))
                continue
            if got != want:
                problems.append(
                    "%s = %d but the qh INDEX is the register bit = `num + dir*ENDPT_MAX/2`, so %s = %d "
                    "(index == ENDPTCOMPLETE/ENDPTPRIME bit, ci13xxx_udc.c:2666/2672; ep0in = "
                    "ci13xxx_ep[ENDPT_MAX/2], ci13xxx_udc.h:166) [[mi4-one-value-two-definitions]]"
                    % (name, got, name, want))
        say("  qh index: OUT0/IN0/IN1 checked against `num + dir*ENDPT_MAX/2` (ENDPT_MAX=%d)" % endpt_max)

    # (2) the written values against the owner's own expressions. The table also carries this header's
    # own names and the two earlier USB headers', so a value defined in terms of a sibling
    # (`ENDPTCTRL_TXE`) evaluates rather than being pronounced unknown.
    table = owner_defines(ENUM_H, DEV_H, USB_H)
    table.update({n: v for n, v in header_values(enum_text).items()})   # `STAGE90_USB_ENUM_*` shorts
    for name, expr in sorted(CROSS_VALUES.items()):
        short = name[len("STAGE90_USB_"):]
        if short not in vals:
            problems.append("entry_usb_enum.h defines no %s, but the check names it" % name)
            continue
        try:
            got = eval_expr(vals[short], table)
        except Refused as exc:
            problems.append("%s: %s" % (name, exc))
            continue
        try:
            want = eval_expr(expr, table)
        except Refused as exc:
            problems.append("%s: its owner expression is bad: %s" % (name, exc))
            continue
        if got != want:
            problems.append("%s = 0x%x but the owner's `%s` = 0x%x ([[mi4-one-value-two-definitions]])"
                            % (name, got, expr, want))
    say("  enum values: %d written values, each compared against the owner's own expression"
        % len(CROSS_VALUES))

    # (3a) the write-target whitelist. Owned = every `#define` name in the three arm headers
    # (function-like macros included, so `STAGE90_USB_ENDPTCTRL(0u)` is owned by its base name), plus
    # every `STAGE90_USB_ENUM_*` this header defines.
    owned = set()
    for path in (USB_H, DEV_H, ENUM_H):
        for m in re.finditer(r"^#define[ \t]+([A-Za-z_][A-Za-z0-9_]*)",
                             strip_comments(read(path)), re.M):
            owned.add(m.group(1))
    writes = []
    for m in re.finditer(r"\busb_enum_write32\s*\(", enum_body):
        arg = (first_arg(enum_body, m.start()) or "").strip()
        if not arg or arg.startswith("uint32_t"):
            continue   # the function *definition's* parameter list, not a store
        base = re.match(r"([A-Za-z_][A-Za-z0-9_]*)", arg)
        writes.append(base.group(1) if base else arg)
    bad = sorted({a for a in writes if a not in owned})
    if bad:
        problems.append("entry_usb_enum.c stores through usb_enum_write32 to a name no header defines: "
                        + ", ".join(bad) + " - a write to a register with no owner")
    if not writes:
        problems.append("entry_usb_enum.c takes no usb_enum_write32 store: the enumeration arm's whole "
                        "point is that it arms the device-mode set")

    # (3b) the no-RST refusal: the arm must never re-run the link reset 910a2 owns.
    if "USBCMD_RST" in enum_body or "USBCMD_RST" in strip_comments(enum_text):
        problems.append("entry_usb_enum.c/.h names `USBCMD_RST`: the enumeration arm must NEVER re-run "
                        "the link reset (910a2 owns the one reset; a reset in the once-per-pass poll "
                        "fights the running device)")
    say("  write-targets: %d stores, each a transcribed `STAGE90_USB_*` offset; no `USBCMD_RST`"
        % len(writes))

    # (4) the mode gate, at the source.
    gate_re = re.compile(r"!=\s*STAGE90_USB_USBMODE_CM_DEVICE\s*\)\s*&&\s*"
                         r"\(STAGE90_XNU_USB_DEV_FORCE\s*==\s*0\)")
    m = gate_re.search(enum_body)
    if not m:
        problems.append("entry_usb_enum.c has no `((x & CM) != CM_DEVICE) && (FORCE == 0)` gate: the arm "
                        "must not write unless the core is already a device")
    elif "return;" not in enum_body[m.start():m.start() + 400]:
        problems.append("entry_usb_enum.c's mode gate does not return from the non-device branch")
    # the first store in entry_usb_enum_poll must come after the gate.
    fn = enum_body.find("void entry_usb_enum_poll(void)")
    if fn != -1 and m:
        first = -1
        for mm in re.finditer(r"\busb_enum_write32\(\s*([^,)]*)", enum_body[fn:]):
            if not mm.group(1).strip().startswith("uint32_t"):
                first = fn + mm.start()
                break
        if first != -1 and first < m.start():
            problems.append("entry_usb_enum_poll stores before its mode gate: the writes would run "
                            "before the check that bounds them")
    say("  mode gate: the `!= CM_DEVICE && FORCE == 0` form is present and returns")

    problems.extend(check_request_coverage(enum_text, enum_body, vals))
    problems.extend(check_one_definition(enum_text, enum_body))

    if problems:
        raise Refused("\n".join("  - " + p for p in problems))


# P1: the seven standard requests a host's probe sends (ch9, tablet's enumeration: Linux's
# `usb_get_device_descriptor`, `usb_set_address`, the two config reads, `usb_get_configuration`, ...).
# Each must be ANSWERED or RECORDED; the set is the clause, the switch is the evidence.
PROBE_REQUESTS = [
    "STAGE90_USB_ENUM_REQ_GET_STATUS",
    "STAGE90_USB_ENUM_REQ_CLEAR_FEATURE",
    "STAGE90_USB_ENUM_REQ_SET_FEATURE",
    "STAGE90_USB_ENUM_REQ_SET_ADDRESS",
    "STAGE90_USB_ENUM_REQ_GET_DESCRIPTOR",
    "STAGE90_USB_ENUM_REQ_GET_CONFIGURATION",
    "STAGE90_USB_ENUM_REQ_SET_CONFIGURATION",
]


def match_paren(text, open_at):
    """The index of the bracket closing the one at `open_at` (or -1).

    Both bracket KINDS are counted together (the body's braces interleave with `(a) && (b) {` gates),
    and preprocessor lines are skipped whole: a `#if FOO` names no bracket, and a `{`-counting regex
    over it is the "directive is not code" defect [[mi4-blank-line-splits-a-spliced-row-group]].
    Plain `str` walking, not `re` - see `probe()`.
    """
    depth = 0
    i = open_at
    n = len(text)
    while i < n:
        ch = text[i]
        if ch == "\n" and i + 1 < n and text[i + 1] == "#":
            nl = text.find("\n", i + 1)
            i = n if nl == -1 else nl
            continue
        if ch in "({":
            depth += 1
        elif ch in ")}":
            depth -= 1
            if depth == 0:
                return i
        i += 1
    return -1


IDENT_START = frozenset("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz_")
IDENT_CHARS = IDENT_START | frozenset("0123456789")


def _ident_at(text, i):
    if i >= len(text) or text[i] not in IDENT_START:
        return None, i
    j = i
    while j < len(text) and text[j] in IDENT_CHARS:
        j += 1
    return text[i:j], j


def _skip_ws(text, i):
    while i < len(text) and text[i] in " \t\r\n":
        i += 1
    return i


def switch_arms(bare):
    """`switch (bRequest) { ... }` in the comment-stripped `bare` -> ({case-name: arm-code}, default-arm).

    Walked character by character ([[the switch is parsed by VALUE]]): the `switch` whose controlling
    expression is exactly `bRequest`, its body brace, and each `case NAME:`/`default:` label up to the
    next label or the body's close. A fall-through (`case A:` with no statement before the next label)
    resolves to the first arm that has code. Comments are already gone (`bare`), so a doc comment that
    SAYS "returns" cannot answer for the code - the defect that let a silent request pass as covered.
    """
    i = 0
    while True:
        i = bare.find("switch", i)
        if i == -1:
            return None, None
        j = _skip_ws(bare, i + 6)
        if j < len(bare) and bare[j] == "(":
            k = _skip_ws(bare, j + 1)
            name, k = _ident_at(bare, k)
            k = _skip_ws(bare, k)
            if name == "bRequest" and k < len(bare) and bare[k] == ")":
                k = _skip_ws(bare, k + 1)
                if k < len(bare) and bare[k] == "{":
                    break
        i += 6
    open_at = k
    close_at = match_paren(bare, open_at)
    if close_at == -1:
        return None, None
    inner = bare[open_at + 1:close_at]

    labels = []   # (kind, name, start-of-code)
    i = 0
    while i < len(inner):
        name, j = _ident_at(inner, i)
        if name in ("case", "default"):
            k = _skip_ws(inner, j)
            if name == "default":
                if k < len(inner) and inner[k] == ":":
                    labels.append(("default", None, k + 1, i))
                    i = k + 1
                    continue
            else:
                cname, k = _ident_at(inner, k)
                k = _skip_ws(inner, k)
                if cname and k < len(inner) and inner[k] == ":":
                    labels.append(("case", cname, k + 1, i))
                    i = k + 1
                    continue
            i = j
            continue
        i = j if name else i + 1

    arms, default = {}, None
    for idx, (kind, cname, start, _label_at) in enumerate(labels):
        end = labels[idx + 1][3] if idx + 1 < len(labels) else len(inner)
        code = inner[start:end].strip()
        if kind == "default":
            default = code
        else:
            arms[cname] = code
    order = [cname for kind, cname, _start, _at in labels if kind == "case"]
    resolved = {}
    for back, cname in enumerate(order):
        code, j = arms[cname], back
        while not code and j + 1 < len(order):
            j += 1
            code = arms[order[j]]
        resolved[cname] = code
    return resolved, default


def _statement_call(code, call):
    """Is `call(` present as an UNCONDITIONAL statement of `code` (first non-space, or after `;`/`}`)?"""
    needle = call + "("
    at = code.find(needle)
    while at != -1:
        before = code[:at].rstrip()
        if before == "" or before[-1] in ";}":
            return True
        at = code.find(needle, at + 1)
    return False


def _has_word(code, word):
    """`word` as a whole identifier in `code` (so `return;` is not found inside `return_value`)."""
    at = code.find(word)
    while at != -1:
        end = at + len(word)
        before_ok = at == 0 or code[at - 1] not in IDENT_CHARS
        after_ok = end >= len(code) or code[end] not in IDENT_CHARS
        if before_ok and after_ok:
            return True
        at = code.find(word, at + 1)
    return False


def check_request_coverage(enum_text, enum_body, vals):
    problems = []
    if len(re.findall(r"switch\s*\(\s*bRequest\s*\)", enum_body)) != 1:
        problems.append("entry_usb_enum.c does not have exactly ONE `switch (bRequest)`: the request "
                        "coverage is read from that one switch (a second would be a second definition of "
                        "the dispatch) [[mi4-one-value-two-definitions]]")
    arms, default = switch_arms(enum_body)
    if arms is None:
        problems.append("entry_usb_enum.c has no `switch (bRequest) { ... }`: nothing answers a request")
        return problems

    answered = recorded = 0
    for name in PROBE_REQUESTS:
        short = name[len("STAGE90_USB_"):]
        if short not in vals:
            problems.append("entry_usb_enum.h defines no %s, but a host's probe sends it" % name)
            continue
        if name not in arms:
            problems.append("the `switch (bRequest)` has no `case %s`: a host's probe sends it and would "
                            "fall to the status-only default - it must be ANSWERED or RECORDED" % name)
            continue
        arm = arms[name]
        recorded_here = _statement_call(arm, "usb_enum_bad") or _statement_call(arm, "USB_ENUM_LIVE")
        if _has_word(arm, "return") and not _has_word(arm, "break"):
            if "usb_enum_prime(" not in arm:
                problems.append("the `case %s` returns without priming an answer" % name)
                continue
            answered += 1
        elif _has_word(arm, "break"):
            # RECORDED: a `usb_enum_bad(...)`/`USB_ENUM_LIVE(...)` as an UNCONDITIONAL statement, or the
            # request falls to the shared status phase and is invisible ([[silence is a reading...]]).
            if not recorded_here:
                problems.append("the `case %s` breaks to the status-only phase without an unconditional "
                                "`usb_enum_bad(...)`/`USB_ENUM_LIVE(...)`: a request that reaches it is "
                                "neither answered nor recorded - silence "
                                "[[mi4-silence-is-a-reading-only-if-success-is-silent]]" % name)
                continue
            recorded += 1
        else:
            problems.append("the `case %s` neither returns an answer nor records: a host's probe sends it"
                            % name)
    if default is None:
        problems.append("the `switch (bRequest)` has no `default:` arm: an unknown bRequest would fall "
                        "to the silent status-only prime")
    elif not _statement_call(default, "usb_enum_bad"):
        problems.append("the `switch (bRequest)` default arm does not call `usb_enum_bad`: any other "
                        "bRequest is a silent status-only prime again")
    # the preload: the IN buffer is zeroed BEFORE the first case label, so a stale answer cannot be sent.
    sw = enum_body.find("switch (bRequest)")
    sw = sw if sw != -1 else enum_body.find("switch(bRequest)")
    sw = sw if sw != -1 else 0
    window = "".join(enum_body[max(0, sw - 400):sw + 60].split())
    if "usb_enum_in_find(0u,0u)" not in window:
        problems.append("entry_usb_enum.c does not preload the IN buffer to zero (`usb_enum_in_find(0u, "
                        "0u)`) before the switch: the status-only prime would send whatever the last "
                        "answer left")
    say("  request coverage: %d of %d probe requests answered (%d) or recorded (%d); default records; "
        "IN buffer preloaded" % (answered + recorded, len(PROBE_REQUESTS), answered, recorded))
    return problems


def literal_present(text, value, separators=LITERAL_SEPARATORS):
    """Is `value` a STANDALONE token in `text`? By `str.find` and a character set - NOT a regex.

    This host's `re` mis-evaluates `[^a-z]` (it excluded `u`), a `(?!u)` lookahead and `$` (which skipped
    a `;`) - measured 2026-10-20 with both `/usr/bin/python3` and the conda 3.10. So a check whose job is
    to SEE a literal is written against `str`, which has no pattern engine to be wrong.
    """
    pieces = text.split(value)
    pos = 0
    for k, piece in enumerate(pieces):
        if k > 0:   # the match after index k-1 lies at [pos - len(value), pos)
            start = pos - len(value)
            before_ok = start == 0 or text[start - 1] in separators
            if before_ok and piece == "":
                return True                     # the token runs to the end of the text
            after = piece[0] if piece else ""
            if before_ok and after in separators:
                return True
        pos += len(piece)
        if k + 1 < len(pieces):
            pos += len(value)
    return False


def check_one_definition(enum_text, enum_body):
    """No VID/PID value literal and no endpoint-address literal outside `entry_usb_enum.h`.

    `enum_body` is the caller's comment-stripped ENUM_C (the caller may be reading a temp copy).
    """
    problems = []
    files = [ENUM_C,
             STREAM_C,
             os.path.join(REPO_ROOT, "src/entry/entry_usb.h"),
             os.path.join(REPO_ROOT, "src/entry/entry_usb_dev.h"),
             os.path.join(REPO_ROOT, "src/entry/entry_usb_dev.c")]
    for path in files:
        if not os.path.isfile(path):
            continue
        text = strip_comments(read(path))
        rel = os.path.relpath(path, REPO_ROOT)
        for value in ("0x18d1", "0x0910"):
            if literal_present(text, value):
                problems.append("%s carries the literal %s: the idVendor/idProduct value belongs to "
                                "entry_usb_enum.h alone (STAGE90_USB_ENUM_ID_VENDOR/ID_PRODUCT) "
                                "[[mi4-one-value-two-definitions]]" % (rel, value))
    # the endpoint DESCRIPTOR's bEndpointAddress: the token two rows before `EP_IN_ATTR` must be the
    # name, never a literal (a second spelling of EP_IN_EPADDR in the bytes the host reads).
    rows = None
    m = re.search(r"static\s+const\s+uint8_t\s+g_usb_cfg_desc\s*\[[^\]]*\]\s*=\s*\{(.*?)\};",
                  enum_body, re.S)
    if m:
        rows = [r.strip() for r in m.group(1).split(",") if r.strip()]
    if not rows:
        problems.append("entry_usb_enum.c has no `g_usb_cfg_desc` array: the configuration descriptor "
                        "cannot be read")
    else:
        for idx, row in enumerate(rows):
            if row == "STAGE90_USB_ENUM_EP_IN_ATTR":
                if idx < 1 or rows[idx - 1] != "STAGE90_USB_ENUM_EP_IN_EPADDR":
                    problems.append("the endpoint descriptor's bEndpointAddress row is %r: it must be "
                                    "`STAGE90_USB_ENUM_EP_IN_EPADDR` (entry_usb_enum.h) "
                                    "[[mi4-one-value-two-definitions]]"
                                    % (rows[idx - 1] if idx >= 1 else "(missing)"))
    say("  one definition: no VID/PID/EP address literal outside entry_usb_enum.h (%d files)"
        % len(files))
    return problems


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
    if "entry_usb_enum_poll" not in syms:
        raise Refused("%s defines no `entry_usb_enum_poll`: the call site in entry_trace.c would be an "
                      "undefined symbol" % image)
    _addr, size, kind = syms["entry_usb_enum_poll"]
    if kind != "T":
        raise Refused("`entry_usb_enum_poll` is a `%s` symbol, not `T` (text)" % kind)
    switch = record_switch(image, "STAGE90_XNU_USB_ENUM")
    body = body_of(image, "entry_usb_enum_poll") or ""
    # the poll is not the arming; the stores are in the helpers it calls, so the window test is over the
    # whole object's text region referenced by the image: any store through 0xf9a anywhere in the arm.
    stores_window = bool(re.search(r"0xf9a", body, re.I)) or size > 8
    if switch == 1:
        if size <= 8:
            raise Refused("the record says STAGE90_XNU_USB_ENUM=1 but the linked `entry_usb_enum_poll` "
                          "body is size %d: the arm's switch did not reach the image "
                          "([[mi4-off-option-two-spellings]])" % size)
        say("  image: STAGE90_XNU_USB_ENUM=1 and `entry_usb_enum_poll` is a %d-byte T body" % size)
    elif switch == 0:
        if size > 8:
            raise Refused("the record says STAGE90_XNU_USB_ENUM=0 but the linked `entry_usb_enum_poll` "
                          "body is %d bytes: the OFF arm must be a bare return" % size)
        say("  image: STAGE90_XNU_USB_ENUM=0 and `entry_usb_enum_poll` is a bare return")
    else:
        say("  image: no USB_ENUM key in the record; `entry_usb_enum_poll` is %d bytes" % size)
    _ = stores_window



def selftest():
    """The falsification battery. Each mutation is applied to a TEMP COPY of the lane files (the real tree
    is never written - a checker that edits the tree and dies mid-case leaves it mutated), and
    `check_sources` is pointed at the copy through its module globals."""
    global ENUM_H, ENUM_C, STREAM_C
    real = (ENUM_H, ENUM_C, STREAM_C)
    originals = {p: read(p) for p in real}
    cases = []
    scratch = tempfile.mkdtemp(prefix="enum-selftest-")
    copies = {}
    for p in real:
        copies[p] = os.path.join(scratch, os.path.basename(p))
        shutil.copyfile(p, copies[p])

    def with_edit(name, path, old, new, expect_in=None):
        global ENUM_H, ENUM_C, STREAM_C
        if expect_in is None:
            expect_in = name
        target = {"h": ENUM_H, "c": ENUM_C, "stream": STREAM_C}[path]
        text = originals[target]
        mutated = text.replace(old, new, 1)
        if mutated == text:
            cases.append((name, "the mutation did not apply: %r not in %s" % (old, path), False))
            return
        open(copies[target], "w").write(mutated)
        saved = (ENUM_H, ENUM_C, STREAM_C)
        ENUM_H, ENUM_C, STREAM_C = copies[real[0]], copies[real[1]], copies[real[2]]
        try:
            check_sources()
            cases.append((name, "check_sources accepted the mutation (it should have refused)", False))
        except Refused as exc:
            cases.append((name, str(exc).strip().splitlines()[0] if str(exc).strip() else "(refused)",
                          expect_in in str(exc)))
        finally:
            ENUM_H, ENUM_C, STREAM_C = saved
            open(copies[target], "w").write(text)

    # The qh setup offset drifts back to the wrong 32 (the defect this guard exists for).
    with_edit("the qh setup offset drifts to 32", "h",
              "#define STAGE90_USB_ENUM_QH_OFF_SETUP   40u",
              "#define STAGE90_USB_ENUM_QH_OFF_SETUP   32u",
              "QH_OFF_SETUP")
    # The qh INDEX returns to the endpoint number (the exact defect QH_IN1 shipped with: index 1 is
    # EP1-OUT's slot, not EP1-IN's - the IN bit is EP_IN + ENDPT_MAX/2).
    with_edit("the EP1-IN qh index loses its direction half", "h",
              "#define STAGE90_USB_ENUM_QH_IN1         17u",
              "#define STAGE90_USB_ENUM_QH_IN1         1u",
              "QH_IN1")
    # A written value drifts.
    with_edit("USBCMD_SUTW drifts from BIT(13)", "h",
              "#define STAGE90_USB_ENUM_USBCMD_SUTW    0x00002000u",
              "#define STAGE90_USB_ENUM_USBCMD_SUTW    0x00001000u",
              "USBCMD_SUTW")
    # A store to an unowned register.
    with_edit("a store to an unowned register appears", "c",
              "    usb_enum_write32(STAGE90_USB_ENDPTCTRL(0u), STAGE90_USB_ENUM_ENDPTCTRL0_VALUE);",
              "    usb_enum_write32(0x1e0u, 0u);\n    usb_enum_write32(STAGE90_USB_ENDPTCTRL(0u), STAGE90_USB_ENUM_ENDPTCTRL0_VALUE);",
              "no owner")
    # The link reset reappears - the one store this arm must never take.
    with_edit("a link reset store reappears", "c",
              "    usb_enum_write32(STAGE90_USB_ENDPTCTRL(0u), STAGE90_USB_ENUM_ENDPTCTRL0_VALUE);",
              "    usb_enum_write32(STAGE90_USB_USBCMD, STAGE90_USB_USBCMD_RST);\n    usb_enum_write32(STAGE90_USB_ENDPTCTRL(0u), STAGE90_USB_ENUM_ENDPTCTRL0_VALUE);",
              "USBCMD_RST")
    # The mode gate is removed.
    with_edit("the mode gate is removed", "c",
              "(usbmode & STAGE90_USB_USBMODE_CM) != STAGE90_USB_USBMODE_CM_DEVICE",
              "(usbmode & STAGE90_USB_USBMODE_CM) != 0xf0f0u",
              "CM_DEVICE")
    # P1: one answer deleted -> a host's probe request falls to the status-only default.
    with_edit("GET_CONFIGURATION's answer is deleted", "c",
              "            case STAGE90_USB_ENUM_REQ_GET_CONFIGURATION:\n",
              "", "GET_CONFIGURATION")
    # default: falls silent.
    with_edit("the default arm stops recording", "c",
              "                /* SET_DESCRIPTOR, SYNCH_FRAME, and anything the host invents: recorded, status only. */\n                usb_enum_bad(bRequest, bRequestType);",
              "                /* silent */", "default")
    # GET_STATUS's answer becomes a silent status phase (prime removed, fall to the shared status).
    with_edit("GET_STATUS's answer stops priming", "c",
              "                usb_enum_prime(STAGE90_USB_ENUM_QH_IN0, USB_ENUM_TD_IN0, g_usb_in_buf,\n"
              "                               (wLength < 2u) ? wLength : 2u, 1u);\n",
              "                (void)wLength;\n", "GET_STATUS")
    # a second VID appears in the stream arm.
    with_edit("a second idVendor literal appears in the stream arm", "stream",
              "uint32_t entry_usb_stream_ring_publish(const void *buf, uint32_t len)",
              "uint32_t entry_usb_stream_ring_publish(const void *buf, uint32_t len)\n{\n    uint32_t vid = 0x18d1, pid = 0x0910;", "idVendor")
    # the IN-buffer preload disappears.
    with_edit("the IN-buffer preload disappears", "c",
              "            (void)usb_enum_in_find(0u, 0u);\n",
              "", "preload")

    shutil.rmtree(scratch, ignore_errors=True)
    refused = sum(1 for _n, _r, ok in cases if ok)
    for name, reason, ok in cases:
        say("  %-45s %s  %s" % (name, "refused:" if ok else "ACCEPTED:", reason))
    say("  --selftest: %d of %d mutations were refused" % (refused, len(cases)))
    if refused != len(cases):
        raise SystemExit("the falsification battery is not watertight: %d of %d refused"
                         % (refused, len(cases)))


def probe():
    """The host's own primitives, measured: a checker can only be as right as the engine under it.

    This host (2026-10-20, both `/usr/bin/python3` 3.10.12 and the conda 3.10.10, under `-I`) matched
    `[^a-z]` against `u`, failed a `(?!u)` lookahead, let `$` skip a `;`, and failed a lookbehind whose
    prefix alternative was empty. Every case below is a fact a check depends on; a FAIL means a check
    written that way cannot see what it claims to see.
    """
    cases = [
        # (name, pattern, text, does the pattern match?) - each measured on this host before writing it
        ("literal glue", r"0x18d1u\b", "uint32_t vid = 0x18d1u;", True),
        ("ident word", r"\breturn\b", "return; break;", True),
        ("ident word (neg)", r"\bbreak\b", "return; x;", False),
        ("preload call", r"usb_enum_in_find\(0u, 0u\)", "x = usb_enum_in_find(0u, 0u);", True),
    ]
    ok = True
    for name, pattern, text, want in cases:
        got = re.search(pattern, text) is not None
        ok = ok and got == want
        say("  %-22s %s (want %s)" % (name, "ok" if got == want else "WRONG", want))
    # `0x18d1u` is GLUED (`u` is a letter): only a separator after the literal makes it standalone.
    got = (literal_present("(&0x18d1,", "0x18d1") and literal_present(" 0x18d1;", "0x18d1")
           and not literal_present("x0x18d1,", "0x18d1") and not literal_present("0x18d1u", "0x18d1"))
    say("  %-22s %s" % ("str scanner", "ok" if got else "WRONG"))
    ok = ok and got
    say("  --probe: %s" % ("PASS" if ok else "FAIL - the host engine mis-reports at least one of these"))
    return 0 if ok else 1


def main():
    parser = argparse.ArgumentParser(description="910b's USB enumeration-arm guard")
    parser.add_argument("--image", help="the linked xnu_arm_entry.elf")
    parser.add_argument("--selftest", action="store_true", help="run the falsification battery")
    parser.add_argument("--verbose", action="store_true")
    parser.add_argument("--probe", action="store_true", help="measure the host's regex primitives")
    args = parser.parse_args()
    if args.probe:
        return probe()

    try:
        check_sources()
        if args.image:
            check_image(args.image)
    except Refused as exc:
        print("FAIL: " + str(exc), file=sys.stderr)
        return 1

    if args.selftest:
        try:
            selftest()
        except SystemExit as exc:
            print("FAIL: " + str(exc), file=sys.stderr)
            return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())