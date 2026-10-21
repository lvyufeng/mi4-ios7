#!/usr/bin/env python3
"""Check that this image's faults are recoverable by design, and that the run can say which were.

    tools/check_fault_recovery.py --image out/stage90/xnu_arm_entry.elf --verbose
    tools/check_fault_recovery.py --image out/stage90/xnu_arm_entry.elf --selftest

**489 closed by naming the wrong frontier, and the reason is the thing this check is about.** Its
document read two records - `pc = Lcopyin_wordwise_loop`, `far = 0x00000000` - as where the boot
stopped, on the inference that this image's `copyin` "faults rather than returning `EFAULT`". Apple's
ARM `copyin` does the opposite: it **arms a recovery address** before entering its copy loop, and the
fault is what makes the `EFAULT` return possible.

The mechanism, in four places, all of them checkable here:

    machine_routines_asm.s:542   COPYIO_SET_RECOVER   `adr r3, copyio_error` then `str r3,[r12,TH_RECOVER]`
    machine_routines_asm.s:584   COPYIO_BODY         the loop that faults
    trap.c:290-291               sleh_abort          `recover = thread->recover; thread->recover = 0;`
    trap.c:456-461               sleh_abort          after `arm_fast_fault` and `vm_fault` both fail,
                                                     `if (recover != 0) regs->pc = recover` - the
                                                     faulting instruction is *replaced* by the copy's
                                                     error exit, which returns `EFAULT`

So a non-zero `thread->recover` at the moment of a fault is the reading that separates "the kernel had
a plan for this" from "this is where it stopped", and `far`/`pc` cannot make that distinction at all -
a copy of an unmapped user address and the process's own thread faulting on the same address produce
the same pair. This check states eight properties of the *file* so that the number in the log is a
reading rather than an inference:

1. `copyio_error` is a failure exit (`mov r0, #14`) and **nothing branches or calls to it** - the
   recovery address is the only way in, which is what makes "the handler pointed `pc` at it" the only
   explanation for arriving there.
2. `copyin` and `copyout` each arm `TH_RECOVER` with `copyio_error`'s own address, read out of the
   **linked image's** instructions: the store's source register is resolved back to the `add/sub rX,
   pc, #imm` that defines it, and the arithmetic is done.
3. Every store of a computed text address into `TH_RECOVER` in the whole image belongs to a copy
   function and names a copy error label - so a non-zero value at a fault cannot have been put there
   by anything else.
4. `sleh_abort` consumes the word before it uses it, and uses it **only** in the kernel-mode arm and
   **only** after `arm_fast_fault` and `vm_fault` have both failed.
5. `TH_RECOVER` = 664 is materialised by the kernel's own compiled C: `out/xnu_kernel_obj/
   osfmk_arm_trap.o`'s `sleh_abort` loads it and zeroes it back through the same base register. The
   same kind of claim 488's check makes about `TH_KSTACKPTR` and `TH_CTH_SELF`, and the same reason:
   a transcribed offset that only the assembly agrees with is a number two parties believe.
6. The instrument reads it **before** `__real_sleh_abort` - the handler zeroes the field, so a read
   after the call reports 0 on every entry, and 0 is a value a reader would believe - and publishes
   it, per entry and as a count.
7. The instrument reads the frame's `pc` again **after** the call and compares it with the armed word
   with bit 0 cleared, because the word being armed and the word being *spent* are two events and
   only the second one says the copy returned `EFAULT`. `sleh_abort` reaches the recovery arm only
   after `arm_fast_fault` **and** `vm_fault` failed, and its write is `regs->pc = (recover & ~0x1)`;
   so `copyout` faulting on a page the kernel then paged in and retried is armed and not redirected -
   which is what 488's and 489's own console shows. The two counts are published under two names,
   `xnu_live_sleh_armed` and `xnu_live_sleh_redirected`, because a key named for the outcome it does
   not measure is the same defect as a comment that asserts a property nothing checks.
8. `sleh_abort`'s user half reaches `goto exception_return;` with no `goto exit;` in between, and that
   label ends in `thread_exception_return();` - so a user fault the kernel serviced **returns to user
   mode from inside the handler** and the wrapper's post-call read is never reached. That is why the
   run's two `user = 1` records are the two with no `xnu_live_sleh_back`, and it makes the absence of
   that key a reading with three cases behind it rather than an anomaly.

`--image` is required because claims 1, 2 and 3 are about the instructions that were linked, not
about the assembly that was written.
"""

import argparse
import bisect
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.dirname(HERE)
BOOT = os.path.join(REPO_ROOT, "src/entry")

# **949: the tree is a parameter, and D13's fault arrangement is not 4570's.** Everything the claims
# read about the *source* (`trap.c`), the *build* (`assym.s`, the kernel object pool) and the *linked
# image*'s shape is chosen by `configure()`, the same way `check_saved_state_offsets.py` and the other
# tree-pinned checks in this series do it. The three deltas that reach the claims:
#
# * 4570's copies arm a **shared** `copyio_error` (plus `copyinstr_error`); D13's four copies arm
#   **per-copy local labels** (`.Lcopyin_fault` etc.), which `objdump` prints relative to the function,
#   so the recovery target is identified by the address the arming `add rX, pc, #imm` computes.
# * 4570's `sleh_abort` tries `arm_fast_fault` first and then `vm_fault`, and its recovery arm writes
#   `regs->pc = (recover & ~0x1)` and relies on the frame's `pc` being read back; D13's handler tries
#   `vm_fault` twice (thread map, then kernel map), and its kernel recovery arm writes `arm_ctx->pc`
#   and `return`s - so D13's frame `pc` is *not* a post-call reading of the arm, and claim 7 is 4570's.
# * `TH_RECOVER` is 664 in 4570 and 552 in D13.
XNU = None
TRAP_C = None
MACHINE_ASM = None
ASSYM = None
KOBJ = None
IS_D13 = False

HEADER = os.path.join(BOOT, "entry_saved_state.h")
TRACE_C = os.path.join(BOOT, "entry_trace.c")
STUBS_C = os.path.join(BOOT, "entry_stubs.c")
BUILD_ENTRY = os.path.join(BOOT, "build_entry.sh")

NM = "arm-none-eabi-nm"
OBJDUMP = "arm-none-eabi-objdump"

# 4570's copies arm these two **named** labels as recovery addresses. `copyinstr` has one of its own
# because it returns ENAMETOOLONG or the byte count and not a plain EFAULT; everything else shares
# `copyio_error`. A name rather than "any label with `error` in it", because the claim is about these
# two and a pattern would grow to fit whatever the file happened to contain.
RECOVERY_LABELS_4570 = ("copyio_error", "copyinstr_error")
ARMED_COPIES_4570 = ("copyin", "copyout")
# D13's copies: the same two the exec path runs, plus the two string copies (which arm their own local
# labels). `ARMED_COPIES` is what claim 2 checks by name; on D13 it is all four.
ARMED_COPIES_D13 = ("copyin", "copyout", "copyinstr", "copyoutstr")
# The two of D13's four that arm an **EFAULT** exit. `copyinstr`/`copyoutstr` arm a shared label at
# the end of `copyoutstr` that preserves `r0` (the terminator count), not an EFAULT exit.
D13_EFAULT_COPIES = ("copyin", "copyout")

OFFSET_4570 = 664
OFFSET_D13 = 552
OFFSET = OFFSET_4570
ARMED_COPIES = ARMED_COPIES_4570
RECOVERY_LABELS = RECOVERY_LABELS_4570
EFAULT = 14


def is_d13(tree):
    """D13 ships the legacy private `osfmk/sys/types.h`; 4570 does not."""
    return os.path.isfile(os.path.join(tree, "osfmk/sys/types.h"))


def configure(tree):
    """Bind every tree-pinned path and constant the claims read. Called from `main()`."""
    global XNU, TRAP_C, MACHINE_ASM, ASSYM, KOBJ, IS_D13, OFFSET, ARMED_COPIES
    IS_D13 = is_d13(tree)
    XNU = tree
    TRAP_C = os.path.join(XNU, "osfmk/arm/trap.c")
    # 4570 has `machine_routines_asm.s`; D13 carries the same `COPYIO_*` macros in
    # `osfmk/arm/bcopyinout.s` instead, so this path is only used for its existence check in `main()`.
    MACHINE_ASM = (os.path.join(XNU, "osfmk/arm/bcopyinout.s") if IS_D13
                   else os.path.join(XNU, "osfmk/arm/machine_routines_asm.s"))
    ASSYM = os.path.join(REPO_ROOT, "out/xnu_assym" + ("_d13" if IS_D13 else "")
                         + "/STAGE90_XNU/assym.s")
    KOBJ = os.path.join(REPO_ROOT, "out/xnu_kernel_obj" + ("_d13" if IS_D13 else "")
                        + "/osfmk_arm_trap.o")
    OFFSET = OFFSET_D13 if IS_D13 else OFFSET_4570
    ARMED_COPIES = ARMED_COPIES_D13 if IS_D13 else ARMED_COPIES_4570
    return IS_D13
INSN = re.compile(r"^\s*([0-9a-f]+):\s+([0-9a-f]{8})\s+(.*?)\s*$")
SYMBOL = re.compile(r"^([0-9a-f]{8}) <(.+)>:$")
STORE_RECOVER = re.compile(r"^str\s+(r\d+|ip|fp|sl|sb|lr|sp),\s*\[(\w+), #(\d+)\]")
ADR_PC = re.compile(r"^(add|sub)\s+(r\d+|ip|fp|sl|sb|lr|sp),\s*pc,\s*#(0x[0-9a-fA-F]+|\d+)")
WRITES = re.compile(r"^([a-z][a-z0-9.]*)\s+(r\d+|ip|fp|sl|sb|lr|sp),\s*[^,\]]")
NO_WRITE = {"str", "strb", "strh", "strd", "stm", "stmia", "stmdb", "push", "vstr", "vstm",
            "cmp", "cmn", "tst", "teq", "mcr", "mcrr", "svc", "bkpt", "b", "bl", "bx", "blx"}


def say(message):
    print(message, flush=True)


def read(path):
    with open(path, encoding="utf-8", errors="replace") as handle:
        return handle.read()


def run(command):
    result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    if result.returncode != 0:
        raise SystemExit("%s failed (%d)" % (" ".join(command), result.returncode))
    return result.stdout.decode("utf-8", "replace")


def strip_comments(text):
    text = re.sub(r"/\*.*?\*/", " ", text, flags=re.S)
    return re.sub(r"//[^\n]*", " ", text)


def instructions(text):
    """`[(address, mnemonic-and-operands)]` from `objdump -d`, in file order."""
    out = []
    for line in text.split("\n"):
        match = INSN.match(line)
        if match:
            out.append((int(match.group(1), 16), match.group(3).strip()))
    return out


def symbol_table(text):
    """`[(address, name)]` for every `objdump -d` heading, in file order."""
    out = []
    for line in text.split("\n"):
        match = SYMBOL.match(line.strip())
        if match:
            out.append((int(match.group(1), 16), match.group(2)))
    return out


def globals_of(nm_text):
    """`[(address, name)]` of the image's **global** text symbols, from `nm`.

    `objdump` prints a heading for every local label too, so `copyin`'s arming instruction sits under
    the heading `Lcopyin_validate_done` and a body read to the next heading is the body of a label and
    not of the function. The first version of this check made exactly that mistake: it reported that
    `copyin` "contains no store into `[..., #664]`" and that two *local labels* "are not copy
    functions", on a correct image. `nm`'s kind column is what separates a function from a label
    inside one, and this is the same distinction 486's check records for `getMetaClass`.
    """
    out = []
    for line in nm_text.split("\n"):
        parts = line.split()
        if len(parts) == 3 and parts[1] in ("T", "W", "i"):
            try:
                out.append((int(parts[0], 16), parts[2]))
            except ValueError:
                continue
    out.sort()
    return out


def function_span(globals_, address):
    """The half-open range of the global function an address falls in."""
    addresses = [a for a, _ in globals_]
    index = bisect.bisect_right(addresses, address) - 1
    if index < 0:
        return None, None, None
    start, name = globals_[index]
    end = globals_[index + 1][0] if index + 1 < len(globals_) else 1 << 32
    return start, end, name


def body_of(insns, globals_, name):
    """The instructions of one global function, local labels and all.

    `insns` is the whole image's parsed instructions, passed in rather than re-parsed: the first
    version called `instructions(text)` inside here, which re-scanned a hundred-megabyte disassembly
    for every lookup and turned the selftest into a five-minute job. A helper that parses its input
    on every call is a helper that will be called in a loop.
    """
    start = None
    for address, symbol in globals_:
        if symbol == name:
            start = address
            break
    if start is None:
        return None
    # **The next global at a *strictly greater* address.** `copyin`/`copyinmsg` are two global
    # symbols at one address (the assembler's `EnterARM` alias), so taking the next table entry gives
    # a zero-length body; the end is the next entry after all the aliases.
    later = [a for a, _ in globals_ if a > start]
    end = min(later) if later else None
    addresses = [a for a, _ in insns]
    first = bisect.bisect_left(addresses, start)
    last = len(insns) if end is None else bisect.bisect_left(addresses, end)
    return insns[first:last]


def label_body(insns, headings, name):
    """The instructions under one `objdump` heading, to the next heading.

    For the labels that are not global symbols - `copyio_error` is one - so `globals_of` cannot see
    them. A heading is correct here and wrong for a function (see `globals_of`), and which one applies
    is a property of the name being asked about, not a preference.
    """
    for index, (address, symbol) in enumerate(headings):
        if symbol != name:
            continue
        end = headings[index + 1][0] if index + 1 < len(headings) else None
        addresses = [a for a, _ in insns]
        first = bisect.bisect_left(addresses, address)
        last = len(insns) if end is None else bisect.bisect_left(addresses, end)
        return insns[first:last]
    return None


def defines_register(insn, register):
    """Does this instruction write `register`? Stores and compares write nothing."""
    match = WRITES.match(insn)
    return bool(match and match.group(2) == register and match.group(1) not in NO_WRITE)


def value_of_previous_definition(insns, index, register):
    """`(address, text, value)` of the instruction that last wrote `register` before `index`.

    `value` is only returned for the two forms assembly reaches a label by - `add`/`sub rX, pc, #imm`
    and `adr rX, <label>`. Anything else comes back as None, which the callers treat as "not an
    address this claim knows how to derive" rather than as a wrong address.
    """
    for back in range(index - 1, max(-1, index - 12), -1):
        address, insn = insns[back]
        if not defines_register(insn, register):
            continue
        adr = ADR_PC.match(insn)
        if adr:
            size = int(adr.group(3), 16) if adr.group(3).startswith("0x") else int(adr.group(3))
            value = address + 8 + size if adr.group(1) == "add" else address + 8 - size
            return address, insn, value & 0xFFFFFFFF
        label = re.match(r"^(adr|add|sub)\s+%s,\s*(\w+)$" % re.escape(register), insn)
        if label:
            return address, insn, label.group(2)
        return address, insn, None
    return None, None, None


def address_of(dis_text, name):
    """The address a `objdump -d` heading gives for `name`, or None."""
    for address, symbol in symbol_table(dis_text):
        if symbol == name:
            return address
    return None


def _pc_relative_value(address, insn):
    """The target address an `add`/`sub rX, pc, #imm` computes, else None."""
    adr = ADR_PC.match(insn)
    if not adr:
        return None
    size = int(adr.group(3), 16) if adr.group(3).startswith("0x") else int(adr.group(3))
    value = address + 8 + size if adr.group(1) == "add" else address + 8 - size
    return value & 0xFFFFFFFF


def _copy_arm_sites(facts, name):
    """`[(store_addr, source_reg, target_value, defining_addr, defining_text)]` for one copy's arms.

    D13's recovery labels are **local** (`.Lcopyin_fault`), which `objdump` does not print as a
    heading, so the target is not a symbol to look up: it is the address the arming
    `add rX, pc, #imm` computes, and this resolves the store's source register back to that add the
    same way the 4570 path resolves it to `copyio_error`'s address. Returns `(body, sites)`.
    """
    body = body_of(facts["insns"], facts["globals"], name)
    if not body:
        return None, []
    sites = []
    for index, (address, insn) in enumerate(body):
        store = STORE_RECOVER.match(insn)
        if not store or int(store.group(3)) != OFFSET:
            continue
        defining, text, value = value_of_previous_definition(body, index, store.group(1))
        if isinstance(value, int):
            sites.append((address, store.group(1), value, defining, text))
    return body, sites


def _is_efault_exit(body, address, window=5):
    """Does a `mov rX, #14` sit at or just after `address`? D13's local fault label restores the
    saved recovery word before it sets EFAULT, so the EFAULT move is not the label's first
    instruction and this looks a few instructions past it rather than at it. **The window is tight
    on purpose**: an arm mis-pointed a few instructions up (into the copy's own body) must not find
    the *real* exit's `mov r0, #14` and pass - which is the mutation the selftest writes."""
    for index, (at, insn) in enumerate(body):
        if at != address:
            continue
        for ahead in range(index, min(len(body), index + window + 1)):
            if re.match(r"^mov\s+r\d+,\s*#%d(;|\s|$)" % EFAULT, body[ahead][1]):
                return True, body[ahead][0], body[ahead][1]
        return False, None, None
    return None, None, None


# ------------------------------------------------------------------------------------------------
# The claims
# ------------------------------------------------------------------------------------------------

def claim_target_is_a_failure_exit(facts, failures, notes):
    """1. `copyio_error` sets `r0 = EFAULT` and nothing branches to it."""
    address = facts["syms"].get("copyio_error")
    if address is None:
        failures.append("this image has no `copyio_error`: the label the copy paths arm as their "
                        "recovery address is not in the linked image, so the address a fault's "
                        "`thread->recover` would hold does not exist")
        return
    body = label_body(facts["insns"], facts["headings"], "copyio_error")
    if not body:
        failures.append("`copyio_error` is in the image's symbols but `objdump` produced no "
                        "instructions for it: nothing here can see what arriving there does")
        return
    first = body[0][1]
    if not re.match(r"^mov\s+r0,\s*#%d(;|\s|$)" % EFAULT, first):
        failures.append("`copyio_error`'s first instruction is `%s`, not `mov r0, #%d`: the recovery "
                        "address has to leave EFAULT in r0, or a fault it recovers is not reported "
                        "as a failed copy" % (first, EFAULT))
    else:
        notes.append("`copyio_error` is the EFAULT exit: its first instruction is `%s`" % first)

    branches = [text for _a, text in facts["insns"]
                if re.match(r"^(b|bl|blx)\s+%08x\s+<copyio_error>$" % address, text)]
    if branches:
        failures.append("something branches to `copyio_error` (%s): then arriving there does not "
                        "mean the abort handler pointed `pc` at it, and a record whose "
                        "`thread->recover` is this address would not be the reading it is here to "
                        "be" % "; ".join(branches[:3]))
    else:
        notes.append("no `b`/`bl`/`blx` in the image targets `copyio_error`, so the recovery address "
                     "is the only way in - which is what makes 'the handler pointed `pc` at it' the "
                     "only explanation for arriving there")


def claim_the_copies_arm_it(facts, failures, notes):
    """2. `copyin` and `copyout` arm `TH_RECOVER` with `copyio_error`'s own address.

    The store this is about is the **arming** one, not the first store at that offset: the copy
    writes the field three times - the arm, and the restore on each of its two exits - and only the
    arm's value is a computed address. The first draft of this claim took the first store at the
    offset, which is the arm in a correct build and is the *restore* in a build where the arm has
    moved, and then crashed on a `None` it had no right to see. So the arm is identified by what it
    is - the store whose source register comes from an `add`/`sub` of `pc` - rather than by its
    position.
    """
    target = facts["syms"].get("copyio_error")
    for name in ARMED_COPIES:
        body = body_of(facts["insns"], facts["globals"], name)
        if not body:
            failures.append("no `%s` in the linked image: the copy this build's exec path runs is "
                            "not there to arm a recovery address" % name)
            continue
        stores = [(address, insn, index, STORE_RECOVER.match(insn).group(1))
                  for index, (address, insn) in enumerate(body)
                  if STORE_RECOVER.match(insn) and int(STORE_RECOVER.match(insn).group(3)) == OFFSET]
        if not stores:
            failures.append("`%s` contains no store into `[..., #%d]`: the recovery address is never "
                            "armed, so a fault inside this copy is not a fault the kernel planned "
                            "for" % (name, OFFSET))
            continue
        arms = []
        for address, insn, index, register in stores:
            at, defining, value = value_of_previous_definition(body, index, register)
            if isinstance(value, int):
                arms.append((address, insn, defining, at, value))
        if not arms:
            failures.append("none of `%s`'s %d stores into `[..., #%d]` takes its value from an "
                            "`add`/`sub` of `pc`: the field is written, and no write of it is an "
                            "address, so nothing arms a recovery point at all"
                            % (name, len(stores), OFFSET))
            continue
        for address, insn, defining, at, value in arms:
            if value != target:
                failures.append("`%s` arms `[..., #%d]` with 0x%08x (from `%s` at 0x%x) and "
                                "`copyio_error` is at 0x%08x: a fault recovered to the wrong label "
                                "is not the failure exit this reading rests on"
                                % (name, OFFSET, value, defining, at, target))
            else:
                notes.append("`%s` arms `[..., #%d]` with **0x%08x** = `copyio_error` (from `%s` at "
                             "0x%x, +8 and the encoded offset)" % (name, OFFSET, value, defining, at))


def claim_no_other_function_arms_it(facts, failures, notes):
    """3. Every computed address stored into `TH_RECOVER` in this image belongs to a copy."""
    arms = []
    for index, (address, insn) in enumerate(facts["insns"]):
        store = STORE_RECOVER.match(insn)
        if not store or int(store.group(3)) != OFFSET:
            continue
        _at, defining, value = value_of_previous_definition(facts["insns"], index, store.group(1))
        if value is None or not isinstance(value, int):
            continue
        _start, _end, owner = function_span(facts["globals"], address)
        arms.append((address, owner, value, defining))

    names = sorted(set(name for _a, name, _v, _d in arms if name))
    outside = [a for a in arms if not (a[1] or "").startswith("copy")]
    if outside:
        failures.append("%s store a computed address into `[..., #%d]` and are not copy functions "
                        "(%s): a non-zero recovery address at a fault would then not be evidence "
                        "that a copy armed it"
                        % (", ".join("`%s`" % (a[1] or "?") for a in outside[:3]), OFFSET,
                           "; ".join("0x%x store" % a[0] for a in outside[:3])))
    else:
        notes.append("the whole image has %d stores of a computed address into `[..., #%d]`, in "
                     "%s - every one of them a copy path, so a non-zero value there at a fault can "
                     "only have been put there by one" % (len(arms), OFFSET, ", ".join(names)))

    wanted = {facts["syms"].get("copyio_error")}
    for name in RECOVERY_LABELS:
        wanted.add(facts["syms"].get(name))
    wanted.discard(None)
    stray = sorted(set(a[2] for a in arms) - wanted)
    if stray:
        failures.append("the copies arm %s, which %s not the recovery labels this image's `copyin`/"
                        "`copyout` share (%s): a fault recovered to an address nothing here has "
                        "read is a reading this check does not cover"
                        % (", ".join("0x%08x" % v for v in stray), "are" if len(stray) > 1 else "is",
                           ", ".join(sorted(RECOVERY_LABELS))))
    for name in ARMED_COPIES:
        if name not in names:
            failures.append("`%s` does not appear among the functions that arm `[..., #%d]`: the "
                            "two the exec path runs are the ones whose recovery this reading is "
                            "about" % (name, OFFSET))


def claim_the_handler_gates_on_it(facts, failures, notes):
    """4. `sleh_abort` consumes the word, and uses it only after both page-in attempts failed."""
    text = facts["trap"]
    body = re.search(r"\bvoid\s+sleh_abort\s*\([^)]*\)\s*\{(.*?)\n\}", text, re.S)
    if not body:
        failures.append("no `sleh_abort` definition in `trap.c`: the handler whose recovery arm this "
                        "claim is about is not in the file the image is built from")
        return
    body = body.group(1)

    consume = re.search(r"recover\s*=\s*thread->recover\s*;\s*thread->recover\s*=\s*0\s*;", body)
    if not consume:
        failures.append("`sleh_abort` no longer reads `thread->recover` into a local and zeroes the "
                        "field in the same breath: the wrapper in `entry_trace.c` reads that field "
                        "before this call precisely *because* this line consumes it, and if the "
                        "field survives the handler then a read after the call means something "
                        "else as well")
    else:
        notes.append("`sleh_abort` consumes the word first thing (`recover = thread->recover; "
                     "thread->recover = 0;`), which is why the instrument reads it in the wrapper "
                     "before calling the handler")

    fast = body.find("arm_fast_fault(")
    fault = body.find("vm_fault(")
    if fast < 0 or fault < 0:
        failures.append("`sleh_abort` no longer calls %s: the two attempts a fault gets before the "
                        "recovery address is used are not both in the function"
                        % " and ".join(n for n, i in (("`arm_fast_fault`", fast),
                                                       ("`vm_fault`", fault)) if i < 0))
        return
    if fast > fault:
        failures.append("`sleh_abort` calls `vm_fault` *before* `arm_fast_fault`: the order is what "
                        "makes a pmap ref/modify fault cheap and a real page-in expensive, and the "
                        "recovery arm below is written for the second of the two")
    else:
        notes.append("`sleh_abort` tries `arm_fast_fault` before `vm_fault`, and the recovery arm "
                     "comes after both")

    assign = re.search(r"if\s*\(\s*recover\s*!=\s*0\s*\)\s*\{[^}]*regs->pc\s*=\s*"
                       r"\(register_t\)\s*\(\s*recover\s*&\s*~0x1\s*\)", body)
    if not assign:
        failures.append("the `recover != 0` arm that points `regs->pc` at the recovery address is "
                        "gone or no longer tests `recover != 0`: with the test gone, a fault outside "
                        "any copy would be redirected to address 0 - and with the arm gone, a "
                        "`far = 0` inside `Lcopyin_wordwise_loop` would be a retry forever or a "
                        "panic instead of the `EFAULT` return a recovered copy makes")
        return
    if not (fault < assign.start()):
        failures.append("the `regs->pc = recover` assignment appears *before* `vm_fault`: the "
                        "recovery address is then used on a fault the page-in might still have "
                        "serviced, so a fault that should have been retried is turned into a failed "
                        "copy")
    else:
        notes.append("`regs->pc` is pointed at the recovery address only inside "
                     "`if (recover != 0)` and only after `vm_fault` has failed")


def claim_the_offset_is_materialised(facts, failures, notes):
    """5. `TH_RECOVER` = 664 is what the kernel's own compiled `sleh_abort` reads and zeroes."""
    match = re.search(r"^#define\s+TH_RECOVER\s+#(-?\d+)", facts["assym"], re.M)
    if not match:
        failures.append("this configuration's `assym.s` declares no `TH_RECOVER`: the assembly that "
                        "arms the recovery address and the C that consumes it would then be using "
                        "offsets neither of them can be checked against")
        return
    if int(match.group(1)) != OFFSET:
        failures.append("assym.s puts `TH_RECOVER` at %s and this image's copy paths write "
                        "`[..., #%d]`: the recovery address is armed at one offset and consumed at "
                        "another" % (match.group(1), OFFSET))
    else:
        notes.append("this configuration's assym.s has `TH_RECOVER` = %d, the offset this image's "
                     "copy paths store into" % OFFSET)

    body = body_of(facts["kobj_insns"], facts["kobj_globals"], "sleh_abort")
    if not body:
        failures.append("no `sleh_abort` in `%s`: the kernel's own compiled C is where the offset "
                        "has to appear, and this claim cannot read it"
                        % os.path.relpath(KOBJ, REPO_ROOT))
        return
    # The read and the zero, through one base register, with the `mov rZ, #0` that makes the second
    # a zeroing store in between. **Not "adjacent instructions"**: in the compiled function they are
    # 0x14 apart, with the `tst`/`str` that spill the frame pointer in between, and a claim written
    # over two adjacent lines would fail on a correct object.
    for index, (_address, insn) in enumerate(body):
        load = re.match(r"^ldr\s+(r\d+),\s*\[(\w+), #%d\]" % OFFSET, insn)
        if not load:
            continue
        for ahead in range(index + 1, min(len(body), index + 24)):
            store = re.match(r"^str\s+(r\d+),\s*\[(\w+), #%d\]" % OFFSET, body[ahead][1])
            if not store or store.group(2) != load.group(2):
                continue
            zeroed = any(re.match(r"^mov\s+%s,\s*#0(;|\s|$)" % re.escape(store.group(1)), body[k][1])
                         for k in range(index + 1, ahead))
            if zeroed:
                notes.append("`osfmk_arm_trap.o`'s `sleh_abort` materialises %d as a read-then-zero "
                             "pair through `%s`: `%s` then `%s` with `mov %s, #0` between them "
                             "(`trap.c:290-291`)"
                             % (OFFSET, load.group(2), insn, body[ahead][1], store.group(1)))
                return
            break
    failures.append("`osfmk_arm_trap.o`'s `sleh_abort` has no `ldr`/zeroing-`str` pair at "
                    "`[..., #%d]` through one base register: the C this image links does not read "
                    "and clear `thread->recover` at the offset the assembly arms, so the two sides "
                    "disagree about where the field is" % OFFSET)


def claim_the_instrument_reads_it_first(facts, failures, notes):
    """6. The wrapper reads the word before the call that zeroes it, and publishes it."""
    header = facts["header"]
    if not re.search(r"^#define\s+STAGE90_TH_RECOVER\s+%d\b" % OFFSET, header, re.M):
        failures.append("`entry_saved_state.h` does not define `STAGE90_TH_RECOVER` as %d: the one "
                        "place the image's own two files read the offset from is not there, and the "
                        "offset check has nothing to compare with the generated `assym.s`" % OFFSET)

    body = re.search(r"void\s+__wrap_sleh_abort\s*\([^)]*\)\s*\{(.*?)\n\}", facts["trace"], re.S)
    if not body:
        failures.append("no `__wrap_sleh_abort` in `entry_trace.c`: the record that carries the "
                        "recovery address is not written")
        return
    body = body.group(1)
    read = body.find("STAGE90_TH_RECOVER")
    call = body.find("__real_sleh_abort(")
    if read < 0:
        failures.append("`__wrap_sleh_abort` does not read `STAGE90_TH_RECOVER`: the run cannot say "
                        "whether a fault it took was one the kernel had a plan for")
    elif call < 0:
        failures.append("`__wrap_sleh_abort` no longer calls `__real_sleh_abort`: the record is not "
                        "a record of a handler that ran")
    elif read > call:
        failures.append("`__wrap_sleh_abort` reads `STAGE90_TH_RECOVER` *after* `__real_sleh_abort` "
                        "- and the handler's own first two statements zero that field, so the "
                        "record would say 0 on every entry: the same number 'nothing was armed' "
                        "produces, which is exactly the reading this step is here to make "
                        "distinguishable")
    else:
        notes.append("`__wrap_sleh_abort` reads the recovery address before `__real_sleh_abort`, "
                     "which is the only order that sees a value")

    if not re.search(r"entry_note_sleh\s*\([^;]*recover\s*\)", body, re.S):
        failures.append("`__wrap_sleh_abort` does not pass the recovery address to "
                        "`entry_note_sleh`: it is read and dropped")
    if not re.search(r"void\s+entry_note_sleh\s*\([^)]*uint32_t\s+recover\s*\)", facts["stubs"]):
        failures.append("`entry_stubs.c`'s `entry_note_sleh` takes no `recover` argument, or the two "
                        "files disagree about its position: a record whose fields line up by "
                        "accident is 487's and 488's class")
    elif 'entry_live_write("xnu_live_sleh_recover"' not in facts["stubs"]:
        failures.append("`entry_stubs.c` never publishes `xnu_live_sleh_recover`: a value nothing "
                        "writes to the log is not a reading")
    else:
        notes.append("the word is published per entry as `xnu_live_sleh_recover` and counted "
                     "whenever it is non-zero as `xnu_live_sleh_armed`")

    if "check_fault_recovery.py" not in facts["build_entry"]:
        failures.append("`build_entry.sh` does not run this check: the properties above would then "
                        "be read by hand, which is what this project replaced with checks")


def claim_the_instrument_sees_it_spent(facts, failures, notes):
    """7. The wrapper reads the frame again *after* the handler, and the two counts have two names.

    The armed word and the spent word are different readings, and the difference is the whole point:
    `sleh_abort` reaches the recovery arm only after `arm_fast_fault` **and** `vm_fault` failed
    (`trap.c:446-461`), so a copy that faulted on a page the kernel then paged in and retried has an
    armed word and no redirection. The handler's only write to `pc` on that path is
    `regs->pc = (register_t) (recover & ~0x1)`, so a post-call `pc` equal to the armed word with bit 0
    cleared *is* the arm having been taken - and it is taken from the frame, which is the only place
    the outcome is visible to a wrapper.
    """
    text = facts["trace"]
    body = re.search(r"\bvoid\s+__wrap_sleh_abort\s*\([^)]*\)\s*\{(.*?)\n\}", text, re.S)
    if not body:
        failures.append("no `__wrap_sleh_abort` definition in `entry_trace.c`: the handler wrapper "
                        "whose post-call reading this claim is about is not in the file the image is "
                        "built from")
        return
    body = body.group(1)

    call = body.find("__real_sleh_abort(")
    compare = body.find("STAGE90_SS_PC")
    if compare < 0:
        failures.append("`__wrap_sleh_abort` never reads `STAGE90_SS_PC` after the call: the run "
                        "would report how many aborts were *armed* and not how many the handler "
                        "actually converted into an `EFAULT`, and those are different events")
        return
    if compare < call:
        failures.append("`__wrap_sleh_abort` reads the frame's `pc` *before* `__real_sleh_abort`: the "
                        "comparison then sees the faulting instruction on every entry and counts "
                        "every armed abort as redirected")

    if not re.search(r"recover\s*&\s*~0x1u?", body):
        failures.append("`__wrap_sleh_abort` compares the post-call `pc` with the armed word without "
                        "clearing bit 0 - and the handler writes the word *masked*, because bit 0 is "
                        "the state bit it moves into `PSR_TF` (`trap.c:459`) - so the comparison would "
                        "report 0 on every entry that was redirected")

    if not re.search(r"entry_note_sleh_back\s*\(\s*redirected\s*\)", body):
        failures.append("`__wrap_sleh_abort` does not pass the outcome to `entry_note_sleh_back`: "
                        "the comparison is made and dropped")
    if not re.search(r"void\s+entry_note_sleh_back\s*\(\s*uint32_t\s+redirected\s*\)", facts["stubs"]):
        failures.append("`entry_stubs.c`'s `entry_note_sleh_back` takes no `redirected` argument, or "
                        "the two files disagree about it")

    # The names have to state what they count. `_armed` is fed by the `recover != 0` test at entry and
    # `_redirected` by the post-call comparison; a key named for the outcome it does not measure is
    # the same defect as a comment that asserts a property nothing checks.
    armed = facts["stubs"].find('entry_live_write("xnu_live_sleh_armed"')
    redirect = facts["stubs"].find('entry_live_write("xnu_live_sleh_redirected"')
    if armed < 0:
        failures.append("`entry_stubs.c` never publishes `xnu_live_sleh_armed`: the count of aborts "
                        "whose recovery address was non-zero has no key, or has one that names "
                        "something else")
    if redirect < 0:
        failures.append("`entry_stubs.c` never publishes `xnu_live_sleh_redirected`: the count of "
                        "aborts the handler actually re-pointed has no key")
    if armed > 0 and redirect > 0:
        armed_test = facts["stubs"].rfind("if (recover != 0u) {", 0, armed)
        redirect_test = facts["stubs"].rfind("if (redirected != 0u) {", 0, redirect)
        if armed_test < 0:
            failures.append("`xnu_live_sleh_armed` is not written from the entry-time test the name "
                            "claims: the key and the test that produces it have come apart")
        if redirect_test < 0:
            failures.append("`xnu_live_sleh_redirected` is not written from the post-call test the "
                            "name claims: the key and the test that produces it have come apart")
        if armed_test >= 0 and redirect_test >= 0:
            notes.append("the entry-time count is published as `xnu_live_sleh_armed` (from "
                         "`recover != 0u`) and the post-call one as `xnu_live_sleh_redirected` (from "
                         "`redirected != 0u`), with the per-entry flag as `xnu_live_sleh_redirect` "
                         "and the epilogue as `xnu_entry_sleh_armed`/`_redirected`")

    if 'xnu_entry_sleh_armed' not in facts["stubs"] or 'xnu_entry_sleh_redirected' not in facts["stubs"]:
        failures.append("`entry_stubs.c` does not report both counts in the epilogue: a run whose log "
                        "is cut before the epilogue would have only the live channel, and a run that "
                        "reaches it would have only one of the two numbers")

    # The count says how many; it does not say *which*. The per-entry flag is what lets a reader line
    # the outcome up with the `pc`/`lr`/`far` of the same record, and it is the only reading in the
    # run that ties one abort's site to the handler's decision about that abort.
    if 'entry_live_write("xnu_live_sleh_redirect"' not in facts["stubs"]:
        failures.append("`entry_stubs.c` publishes no per-entry `xnu_live_sleh_redirect`: the count "
                        "would say how many faults were converted into `EFAULT` and not one of them "
                        "could be tied to the record whose site it was")


def claim_the_user_path_never_comes_back(facts, failures, notes):
    """8. A serviced user-mode fault leaves through `thread_exception_return()`, so no wrapper sees it return.

    Run 490's second run reports eight entries into `sleh_abort` and six returns from it, and the two
    that never returned are exactly the two whose frame says user mode (`xnu_live_sleh_user = 1`).
    That is not an anomaly to be explained away: `sleh_abort`'s user half ends in

        if (result == KERN_SUCCESS || result == KERN_ABORTED)
            goto exception_return;
        ...
        exception_return:
            if (recover)
                thread->recover = recover;
            thread_exception_return();
            /* NOTREACHED */

    so a user fault the kernel serviced **returns to user mode from inside the handler** and
    `entry_note_sleh_back` is never reached. The absence of `xnu_live_sleh_back` for a record is
    therefore a reading with three cases behind it - serviced for a user thread (this one), the
    recovery arm taken and `goto exit` reached, and the handler dying - and the third of those is
    what `xnu_live_sleh_storm` and the panic path cover.
    """
    text = facts["trap"]
    body = re.search(r"\bvoid\s+sleh_abort\s*\([^)]*\)\s*\{(.*?)\n\}", text, re.S)
    if not body:
        failures.append("no `sleh_abort` definition in `trap.c`: the handler whose user-mode tail this "
                        "claim is about is not in the file the image is built from")
        return
    body = body.group(1)

    user = body.find("goto exception_return;")
    label = body.find("exception_return:")
    ret = body.find("thread_exception_return();", label if label >= 0 else 0)
    kernel_last = body.rfind("goto exit;")
    if user < 0:
        failures.append("`sleh_abort`'s user-mode half no longer reaches `goto exception_return;`: "
                        "every path would return to the caller, and the run's two user-mode records "
                        "would then be two faults with no record of whether they were serviced")
        return
    if label < 0 or ret < 0:
        failures.append("`sleh_abort` has no `exception_return:` label followed by "
                        "`thread_exception_return()`: the serviced-user-fault path does not return to "
                        "user mode from inside the handler")
        return
    if user > label:
        failures.append("`sleh_abort`'s `goto exception_return;` is after the label it names: the "
                        "user-mode path this claim is about is not the one that leaves")
    if kernel_last > user:
        failures.append("`sleh_abort`'s last `goto exit;` is *after* its `goto exception_return;`: the "
                        "kernel and user halves are not in the order that makes the user path "
                        "identifiable, and the claim about which one never returns would be a claim "
                        "about the wrong half")

    # The anchor is the *user* page-in call (`TRUE` where the kernel half passes `FALSE`), because
    # the second `goto exception_return;` in the file belongs to the alignment branch and would keep
    # the claim green while the page-in path had been changed to return.
    anchor = body.find("arm_fast_fault(map->pmap, trunc_page(fault_addr), fault_type, TRUE)")
    if anchor < 0:
        failures.append("`sleh_abort`'s user half no longer calls "
                        "`arm_fast_fault(..., fault_type, TRUE)`: the page-in path this claim is "
                        "about is not in the function")
        return
    serviced = body.find("goto exception_return;", anchor)
    returns = body.find("goto exit;", anchor)
    if serviced < 0:
        failures.append("`sleh_abort`'s user page-in result no longer reaches `goto exception_return;` "
                        "after it: a serviced user fault would return to `__wrap_sleh_abort`, and the "
                        "run's two `user = 1` records would no longer be the two with no `_back`")
    elif 0 <= returns < serviced:
        failures.append("`sleh_abort`'s user page-in result is followed by `goto exit;` before its "
                        "`goto exception_return;`: the serviced user fault would return to the caller")
    elif label >= 0 and ret >= 0:
        notes.append("`sleh_abort`'s user page-in result reaches `goto exception_return;` with no "
                     "`goto exit;` in between, and that label ends in `thread_exception_return();` - "
                     "so a serviced user fault does not return to the wrapper, which is why run 2's "
                     "two `user = 1` records are the two with no `xnu_live_sleh_back`")


def claim_d13_the_copies_arm_a_fault_exit(facts, failures, notes):
    """D13-2/D13-3. The copies that arm `TH_RECOVER` are exactly the copies, and the two the exec
    path runs arm an address that sets EFAULT.

    D13's copies (`bcopyinout.s`) arm **local** labels of their own (`.Lcopyin_fault` etc.) rather
    than sharing 4570's `copyio_error`, and the labels live inside the functions so `objdump` gives
    them no heading - so the target is the address the arming `add rX, pc, #imm` computes. The
    property has two halves: nothing outside a copy function arms the field (so a non-zero value there
    at a fault is a copy's doing), and `copyin`/`copyout`'s own arms point at a place that leaves
    `EFAULT` in `r0`.

    **D13's string copies are why this is not "all four".** `copyinstr`/`copyoutstr` arm a shared
    label at the end of `copyoutstr` that *preserves* `r0` (or leaves the terminator count in it) and
    returns - the label serves both copies and is not an EFAULT exit. So the EFAULT check is
    `ARMED_COPIES` (`copyin`, `copyout`) only, while the "armed at all" set is the four the
    instrument's records cover.
    """
    str_copies = ARMED_COPIES_D13
    armed_functions = []
    # `ARMED_COPIES` on D13 is `copyin`/`copyout` - the two the exec path runs and the two the EFAULT
    # check below applies to. `copyinstr`/`copyoutstr` are only required to arm *something*.
    arming_sites = 0
    for name in str_copies:
        body, sites = _copy_arm_sites(facts, name)
        if not body:
            failures.append("no `%s` in the linked image: the copy this build's exec path runs is "
                            "not there to arm a recovery address" % name)
            continue
        if not sites:
            failures.append("`%s` contains no store into `[..., #%d]`: the recovery address is never "
                            "armed, so a fault inside this copy is not a fault the kernel planned for"
                            % (name, OFFSET))
            continue
        armed_functions.append(name)
        arming_sites += len(sites)
        if name in D13_EFAULT_COPIES:
            for address, register, value, defining, text in sites:
                is_efault, at, mov = _is_efault_exit(body, value)
                if is_efault is None:
                    failures.append("`%s` arms `[..., #%d]` with 0x%08x (from `%s` at 0x%x) and the "
                                    "label is not in this function's instructions: the address the "
                                    "fault would be redirected to is not one this check can read"
                                    % (name, OFFSET, value, text, defining))
                elif not is_efault:
                    failures.append("`%s` arms `[..., #%d]` with 0x%08x (from `%s` at 0x%x) and the "
                                    "instructions at that address never set `r0` to EFAULT: a fault "
                                    "recovered to a label that is not the failure exit is not the "
                                    "`EFAULT` return this reading rests on"
                                    % (name, OFFSET, value, text, defining))
                else:
                    notes.append("`%s` arms `[..., #%d]` with **0x%08x** (from `%s` at 0x%x) and "
                                 "that label sets EFAULT (`%s`)"
                                 % (name, OFFSET, value, text, defining, mov))

    # Nothing outside a copy function may put a computed address there.
    others = []
    for index, (address, insn) in enumerate(facts["insns"]):
        store = STORE_RECOVER.match(insn)
        if not store or int(store.group(3)) != OFFSET:
            continue
        _at, defining, value = value_of_previous_definition(facts["insns"], index, store.group(1))
        if not isinstance(value, int):
            continue
        _start, _end, owner = function_span(facts["globals"], address)
        if not (owner or "").startswith("copy"):
            others.append((address, owner, value, defining))
    if others:
        failures.append("`%s` store a computed address into `[..., #%d]` and are not copy functions: "
                        "a non-zero recovery address at a fault would then not be evidence that a "
                        "copy armed it"
                        % (", ".join("`%s`" % (o[1] or "?") for o in others[:3]), OFFSET))
    else:
        notes.append("the whole image puts a computed address into `[..., #%d]` at %d sites, every "
                     "one of them in a copy function (%s), so a non-zero value there at a fault can "
                     "only have been put there by one"
                     % (OFFSET, arming_sites, ", ".join(armed_functions)))
    missing = [n for n in str_copies if n not in armed_functions]
    if missing:
        failures.append("`%s` do not appear among the functions that arm `[..., #%d]`: the copies "
                        "the exec path runs are the ones whose recovery this reading is about"
                        % ("`, `".join(missing), OFFSET))


def claim_d13_the_handler_gates_on_it(facts, failures, notes):
    """D13-4. `sleh_abort` reads the word only after both page-in attempts fail, and its recovery arm
    writes `arm_ctx->pc` and returns.

    D13's handler is a different shape from 4570's: it tries `vm_fault` on the thread's map and then
    `vm_fault` on the kernel map (no `arm_fast_fault`), and it reads `thread->recover` **inline** - the
    zero is materialised into a register *before* the read and stored back after it - rather than into
    a named local. So this claim reads the C for the two page-in calls in order and for the recovery
    arm that assigns to the frame's `pc` inside a `if (thread->recover)` test, and it reads the *kernel
    object* for the read-then-zero the 4570 C spelled as two statements.
    """
    text = facts["trap"]
    body = re.search(r"\bvoid\s+sleh_abort\s*\([^)]*\)\s*\{(.*?)\n\}", text, re.S)
    if not body:
        failures.append("no `sleh_abort` definition in `trap.c`: the handler whose recovery arm this "
                        "claim is about is not in the file the image is built from")
        return
    body = body.group(1)

    # D13 has no `arm_fast_fault`; the two attempts are the two `vm_fault` calls (thread map, kernel
    # map). The 4570 branch requires `arm_fast_fault` before `vm_fault`; here the check is that the
    # page-in is attempted (twice, one of them against the kernel map) before the recovery arm.
    recover_read = body.find("thread->recover")
    if recover_read < 0:
        failures.append("`sleh_abort` never reads `thread->recover`: the field the copies arm is not "
                        "consulted, so a fault inside a copy would not be recoverable at all")
        return
    faults = [m.start() for m in re.finditer(r"\bvm_fault\s*\(", body)]
    kernel_fault = body.find("vm_fault(kernel_map")
    if len(faults) < 2:
        failures.append("`sleh_abort` does not attempt the page-in twice (thread map then kernel map, "
                        "`vm_fault`): the recovery arm comes after both, and with one attempt a fault "
                        "the kernel could have serviced would be turned into a failed copy")
    else:
        notes.append("`sleh_abort` attempts the page-in with `vm_fault` twice (the thread's map and "
                     "then `kernel_map`); D13's handler has no `arm_fast_fault`, so those two are the "
                     "attempts the recovery arm comes after")

    assign = re.search(r"arm_ctx->pc\s*=\s*thread->recover\s*;", body)
    if not assign:
        failures.append("the recovery arm that points the frame's `pc` at `thread->recover` is gone, "
                        "or no longer tests the field: with the arm gone a fault inside a copy would "
                        "be a retry forever or a panic instead of the `EFAULT` return a recovered "
                        "copy makes")
        return
    test = re.search(r"if\s*\(\s*!?\s*thread->recover\s*\)", body[:assign.start()])
    if not test:
        failures.append("`sleh_abort`'s `arm_ctx->pc = thread->recover` is not guarded by a test on "
                        "`thread->recover`: an unarmed fault would then be redirected to a stale word")
    else:
        notes.append("`arm_ctx->pc` is pointed at `thread->recover` only inside a test on the field, "
                     "and only after both `vm_fault` attempts")
    if kernel_fault >= 0 and not (kernel_fault < assign.start()):
        failures.append("the `arm_ctx->pc = thread->recover` assignment appears *before* the "
                        "`vm_fault(kernel_map, ...)` attempt: the recovery address is used on a fault "
                        "the page-in might still have serviced")
    # The handler leaves by zeroing the field and returning (D13's kernel recovery arm does not rely on
    # a later read of the frame's `pc`): the zeroing store is in the *compiled* object, which claim 5
    # reads, and here the C is checked to clear the field on the recovery path.
    if not re.search(r"thread->recover\s*=\s*NULL\s*;|thread->recover\s*=\s*0\s*;", body):
        failures.append("`sleh_abort`'s recovery arm does not clear `thread->recover`: the field "
                        "would survive the handler, and the wrapper's before-call read would then "
                        "mean something different from what it means on 4570")


def _sleh_abort_body(text):
    """`sleh_abort`'s body, delimited by DEPTH rather than by the first column-0 `}`.

    A rung block's body stands inside an `#if`, so its closing brace sits at column 0 while the
    preprocessor never sees it alone. Slicing to that brace ended the body 500 rows early and this
    claim then reported "`sleh_abort` no longer calls `doexception()`" on a tree whose three calls are
    all inside the function. Depth is counted over the non-directive rows - what the preprocessor
    actually hands the compiler.
    """
    m = re.search(r"\bvoid\s+sleh_abort\s*\([^)]*\)\s*\{", text)
    if not m:
        return None
    start = m.end()
    depth, seen_open = 1, True
    i = start
    while i < len(text):
        nl = text.find("\n", i)
        row = text[i:] if nl < 0 else text[i:nl]
        if not row.lstrip().startswith("#"):
            depth += row.count("{") - row.count("}")
            if depth <= 0:
                return text[start:text.rfind("\n", start, i)]
        if nl < 0:
            break
        i = nl + 1
    return None


def claim_d13_the_user_path_never_comes_back(facts, failures, notes):
    """D13-8. D13's user half has no `goto exception_return;`: a serviced user fault **returns from
    the handler** and a failed one leaves through `doexception()`.

    This is why D13's user half returns to `__wrap_sleh_abort` (so the wrapper's post-call read *is*
    reached) while the kernel recovery arm also returns - and it means the 4570 claim about
    `thread_exception_return()` does not apply. What this claim states instead is the property the
    instrument's before/after pair rests on for D13: the handler **returns** on the serviced-user path
    (`ml_set_interrupts_enabled(TRUE); return;` in the user branch) and reaches `doexception()` only
    when the page-in failed - so a returned entry the wrapper sees is a serviced fault, not a panic.
    """
    text = facts["trap"]
    body = _sleh_abort_body(text)
    if body is None:
        failures.append("no `sleh_abort` definition in `trap.c`: the handler whose user tail this "
                        "claim is about is not in the file the image is built from")
        return

    # The user-mode branch is the `else if (cpsr == 0x10)` half; inside it the two abort cases each
    # end a serviced fault with `ml_set_interrupts_enabled(TRUE); return;`.
    user = body.find("cpsr == 0x10")
    if user < 0:
        failures.append("`sleh_abort` has no `cpsr == 0x10` user-mode branch: the half whose return "
                        "this claim is about is not in the function")
        return
    serviced = body.find("ml_set_interrupts_enabled(TRUE);", user)
    ret = body.find("return;", serviced if serviced >= 0 else user)
    if serviced < 0 or ret < 0:
        failures.append("`sleh_abort`'s user branch no longer ends a serviced fault with "
                        "`ml_set_interrupts_enabled(TRUE); return;`: the serviced-user path would not "
                        "reach the wrapper's post-call read")
        return
    if "goto exception_return;" in body[user:]:
        failures.append("`sleh_abort`'s user branch reaches `goto exception_return;`: that is 4570's "
                        "arrangement (the serviced user fault leaves through "
                        "`thread_exception_return()`), and D13's handler returns instead - the two "
                        "shapes make the wrapper's post-call read mean different things")
    else:
        notes.append("`sleh_abort`'s user branch ends a serviced fault with "
                     "`ml_set_interrupts_enabled(TRUE); return;` and never reaches "
                     "`thread_exception_return()` - D13's serviced user fault returns to "
                     "`__wrap_sleh_abort`, so its post-call `pc` read is reached")

    # A failed user fault leaves through `doexception`, which does not return to the wrapper.
    if "doexception(" not in body:
        failures.append("`sleh_abort` no longer calls `doexception()`: a user fault the kernel could "
                        "not service has no way out that the wrapper can distinguish from a return")


D13_CLAIMS = (claim_d13_the_copies_arm_a_fault_exit,
              claim_d13_the_handler_gates_on_it,
              claim_the_offset_is_materialised,
              claim_the_instrument_reads_it_first,
              claim_d13_the_user_path_never_comes_back)

CLAIMS = (claim_target_is_a_failure_exit, claim_the_copies_arm_it,
          claim_no_other_function_arms_it, claim_the_handler_gates_on_it,
          claim_the_offset_is_materialised, claim_the_instrument_reads_it_first,
          claim_the_instrument_sees_it_spent, claim_the_user_path_never_comes_back)


def compare(facts, mutate=None):
    if mutate is not None:
        facts = mutate_facts(facts, mutate)
    failures, notes = [], []
    for claim in (D13_CLAIMS if IS_D13 else CLAIMS):
        claim(facts, failures, notes)
    return failures, notes


# ------------------------------------------------------------------------------------------------
# The selftest
# ------------------------------------------------------------------------------------------------

def _bump(text, needle, replacement, count=1):
    assert needle in text, needle
    return text.replace(needle, replacement, count)


def _rebase_offset(kobj_dis, old_offset, new_offset, mnemonic, unique=True):
    """Rewrite an objdump line's `[<base>, #<old>]` to `#<new>`, BASE-REGISTER-FREE and COMMENT-FREE.

    A mutation pinned to a literal `mnemonic rN, [REG, #OFF]` text stops mutating the moment the
    compiler's register allocator picks another base (`sl` -> `fp` after a flag change) or the
    disassembler reformats the trailing comment: `_bump`'s `assert needle in text` then fires, the
    selftest reports `RAISED`, and a mutation that mutates nothing is indistinguishable from a claim
    that holds (the 228 class this file documents twice). The OFFSET, not the base register, is what
    these claims are about, so the anchor is the offset. `unique=True` asserts exactly ONE line moved
    (a field-MOVE mutates one access); `unique=False` rewrites EVERY access (a lost read or a moved
    field must leave no correct site behind).
    """
    pattern = re.compile(r"(^\s*[0-9a-f]+:\s+[0-9a-f]+\s+%s\s+r\d+,\s*\[[a-z0-9]+,\s*#)%d(\])"
                         % (re.escape(mnemonic), old_offset), re.M)

    def repl(match):
        return match.group(1) + str(new_offset) + match.group(2)

    new_text, n = pattern.subn(repl, kobj_dis)
    assert n > 0, ("no `%s [<base>, #%d]` line in the kernel object - the mutation would mutate "
                   "nothing" % (mnemonic, old_offset))
    if unique:
        assert n == 1, ("`%s [<base>, #%d]` occurs %d times; a field-MOVE mutation must move exactly "
                        "one access" % (mnemonic, old_offset, n))
    return new_text


def _edit_line_at(facts, address, transform):
    """Rewrite the one disassembly line at `address`, found by its address and not by its text.

    **The first version of these mutations spelled the lines out**, address, opcode and trailing
    comment included - and every one of them stopped mutating the moment step 3 relinked the image and
    moved `copyin`. The selftest reported seven ACCEPTED on a check that was right, which is 228's
    class exactly: a mutation written against a literal current value stops mutating when the value
    changes, and a mutation that mutates nothing is indistinguishable from a claim that holds. The
    address is derived from the facts and the *text* is only edited.
    """
    lines = facts["image_dis"].split("\n")
    prefix = "%08x:" % address
    hits = [index for index, line in enumerate(lines) if line.startswith(prefix)]
    assert len(hits) == 1, (hex(address), len(hits))
    lines[hits[0]] = transform(lines[hits[0]])
    facts["image_dis"] = "\n".join(lines)


def _arming_of(facts, name):
    """`(store address, source register, defining instruction address)` of a copy's arming store."""
    body = body_of(facts["insns"], facts["globals"], name)
    assert body, name
    for index, (address, insn) in enumerate(body):
        store = STORE_RECOVER.match(insn)
        if not store or int(store.group(3)) != OFFSET:
            continue
        at, _defining, value = value_of_previous_definition(body, index, store.group(1))
        if isinstance(value, int):
            return address, store.group(1), at
    raise AssertionError("no arming store in %s" % name)


def mutate_facts(facts, mutate):
    """Every mutation edits **source, assembly or disassembly text**, and the derived facts are
    re-derived from it at the end.

    489's selftest was defeated by three mutations that edited a *derived* body the harness re-derives
    from source, so the mutations were discarded before the claims saw them and the selftest reported
    ACCEPTED. Nothing here is derived before a mutation except what is re-derived below.

    And the disassembly mutations address their lines **by address, never by spelling**: the first
    version wrote them out, and step 3 relinked the image underneath them, so seven of them stopped
    mutating and were reported as accepted claims on a check that was right.
    """
    facts = dict(facts)
    if IS_D13:
        # **949: D13's mutations, over D13's arrangement.** The table below is 4570's: every entry
        # edits a 4570 form - the shared `copyio_error`, `arm_fast_fault`, `regs->pc = (recover &
        # ~0x1)`, `thread_exception_return()`, `TH_RECOVER #664` - none of which D13 has. These three
        # mutate the D13 forms the D13 claims read, and `selftest()` runs this set on D13.
        if mutate == "a_copy_stops_arming_the_recovery_address":
            body = body_of(facts["insns"], facts["globals"], "copyin")
            address = next(a for a, insn in body
                           if STORE_RECOVER.match(insn)
                           and int(STORE_RECOVER.match(insn).group(3)) == OFFSET)
            _edit_line_at(facts, address, lambda line: re.sub(r"str\s+\w+,", "str\tr0,", line))
        elif mutate == "a_copy_arms_an_address_that_is_not_its_exit":
            # Redirect the arm 0x100 past where it pointed - still inside the copy's own body, so the
            # target is a real instruction this check can read, but it is a loop instruction and not
            # the fault exit.
            body = body_of(facts["insns"], facts["globals"], "copyin")
            address = next(a for a, insn in body if ADR_PC.match(insn))
            _edit_line_at(facts, address,
                          lambda line: re.sub(r"#(0x[0-9a-fA-F]+|\d+)", "#0x100", line, count=1))
        elif mutate == "a_copy_leaves_the_functions_that_arm_it":
            facts["image_dis"] = re.sub(r"^%08x <copyin>:$" % facts["syms"]["copyin"],
                                        "%08x <copies_in>:" % facts["syms"]["copyin"],
                                        facts["image_dis"], count=1, flags=re.M)
            facts["nm_text"] = re.sub(r"^%08x T copyin$" % facts["syms"]["copyin"],
                                      "%08x T copies_in" % facts["syms"]["copyin"],
                                      facts["nm_text"], count=1, flags=re.M)
        elif mutate == "the_handler_stops_gating_on_the_word":
            facts["trap"] = _bump(facts["trap"],
                                  "arm_ctx->pc = thread->recover;", "arm_ctx->pc = 0;")
        elif mutate == "assym_moves_the_offset":
            facts["assym"] = _bump(facts["assym"], "#define TH_RECOVER\t#552",
                                   "#define TH_RECOVER\t#556")
        elif mutate == "assym_forgets_the_offset":
            facts["assym"] = _bump(facts["assym"], "#define TH_RECOVER\t#552\n", "")
        elif mutate == "the_kernel_object_moves_the_field":
            # **EVERY** access, not the first, and the trailing comment moves with the offset.
            # `sleh_abort` reads `thread->recover` TWICE in the source -- the `if (!thread->recover)`
            # guard (trap.c:676) and `arm_ctx->pc = thread->recover;` (:705) -- and BOTH materialize as
            # an `ldr r0, [<base>, #552]` load. A mutation that rewrites only the first leaves the
            # second correct read satisfying the claim, and a mutation that mutates nothing is
            # indistinguishable from a claim that holds (the 228 class). A field that genuinely MOVED
            # would move EVERY access, so this moves all of them.
            #
            # The BASE REGISTER is not part of the claim: the object's base for that load is whatever
            # the compiler chose (`sl` before, `fp` after the 1021d `-msoft-float` recompile), and a
            # mutation pinned to a literal `[sl, ...]` STOPS MUTATING the moment the allocator's
            # choice changes -- which is exactly what happened here, reported as `RAISED` because
            # `_bump`'s `assert needle in text` fired. So the anchor is the OFFSET, register-free.
            facts["kobj_dis"] = _rebase_offset(facts["kobj_dis"], OFFSET, OFFSET + 4, "ldr",
                                               unique=False)
        elif mutate == "the_kernel_object_loses_the_read":
            # Same reasoning as the field-move above: EVERY read site, because the claim accepts a
            # match at ANY read site, so dropping only one of the two reads leaves the other. Here the
            # mutation points the loads at a DIFFERENT (also register-free) offset so nothing reads the
            # field the assembly arms -- register-free for the same reason as the move mutation.
            facts["kobj_dis"] = _rebase_offset(facts["kobj_dis"], OFFSET, OFFSET - 4, "ldr",
                                               unique=False)
        elif mutate == "the_header_stops_defining_the_offset":
            facts["header"] = _bump(facts["header"],
                                    "#define STAGE90_TH_RECOVER     552",
                                    "#define STAGE90_TH_RECOVER_VALUE 552")
        elif mutate == "the_wrapper_reads_after_the_handler":
            facts["trace"] = _bump(
                facts["trace"],
                "    recover = ((const uint32_t *)(uintptr_t)thread)[STAGE90_TH_RECOVER / 4];\n\n"
                "    entry_note_sleh((uint32_t)type, fsr, far_, thread, (const uint32_t *)regs, recover);\n"
                "\n    __real_sleh_abort(regs, type);",
                "    entry_note_sleh((uint32_t)type, fsr, far_, thread, (const uint32_t *)regs, recover);\n"
                "\n    __real_sleh_abort(regs, type);\n\n"
                "    recover = ((const uint32_t *)(uintptr_t)thread)[STAGE90_TH_RECOVER / 4];")
        elif mutate == "the_wrapper_reads_and_drops_it":
            facts["trace"] = _bump(
                facts["trace"],
                "    entry_note_sleh((uint32_t)type, fsr, far_, thread, (const uint32_t *)regs, recover);",
                "    entry_note_sleh((uint32_t)type, fsr, far_, thread, (const uint32_t *)regs, 0u);")
        else:
            raise SystemExit("unknown D13 mutation %s" % mutate)
        facts["headings"] = symbol_table(facts["image_dis"])
        facts["syms"] = {name: address for address, name in facts["headings"]}
        facts["insns"] = instructions(facts["image_dis"])
        facts["globals"] = globals_of(facts["nm_text"])
        facts["kobj_insns"] = instructions(facts["kobj_dis"])
        return facts
    target = facts["syms"].get("copyio_error")

    if mutate == "the_recovery_target_stops_setting_efault":
        # The first `mov r0, #14` after `copyio_error`'s own heading - `L_copyin_word_fault` has one
        # too, so the heading is what picks the subject.
        body = label_body(facts["insns"], facts["headings"], "copyio_error")
        first = body[0][0]
        _edit_line_at(facts, first, lambda line: re.sub(r"mov\s+r0, #%d\b" % EFAULT,
                                                        "mov\tr0, #0", line))
    elif mutate == "the_recovery_target_gains_a_caller":
        facts["image_dis"] = facts["image_dis"].replace(
            "%08x <copyio_error>:" % target,
            "%08x <copyio_error>:\n%08x:\tea000000 \tb\t%08x <copyio_error>"
            % (target, target, target), 1)
    elif mutate == "copyin_stops_arming_the_recovery_address":
        address, register, _at = _arming_of(facts, "copyin")
        _edit_line_at(facts, address, lambda line: re.sub(r"str\s+r3,", "str\tr4,", line))
    elif mutate == "copyin_arms_the_wrong_offset":
        address, _register, _at = _arming_of(facts, "copyin")
        _edit_line_at(facts, address, lambda line: line.replace("#%d]" % OFFSET, "#668]")
                   .replace("; 0x298", "; 0x29c"))
    elif mutate == "copyin_arms_a_label_short_of_the_target":
        _address, _register, at = _arming_of(facts, "copyin")
        _edit_line_at(facts, at, lambda line: re.sub(r"#(0x[0-9a-fA-F]+|\d+)",
                                                     "#552", line, count=1))
    elif mutate == "copyout_stops_arming_the_recovery_address":
        address, register, _at = _arming_of(facts, "copyout")
        _edit_line_at(facts, address, lambda line: re.sub(r"str\s+r3,", "str\tr4,", line))
    elif mutate == "something_else_in_the_image_arms_it":
        # A store of a *computed address* into the field, in a function that is not a copy. Both lines
        # are injected, because the claim identifies an arm by its value being an `add`/`sub` of `pc`
        # and a lone store would be indistinguishable from one of the copies' own restores. The host
        # is the instrument's own frame read at that offset: it is a global text symbol, it is in the
        # image, and it is not a copy path by name. (The first host was another instrument function
        # that `nm` reports as a *local* symbol, so `body_of` returned None and the mutation raised
        # `TypeError` instead of being refused - a mutation that cannot run is not a mutation.)
        body = body_of(facts["insns"], facts["globals"], "entry_note_sleh_back")
        address = next(a for a, insn in body if re.match(r"^ldr\s+\w+,\s*\[\w+, #%d\]" % OFFSET, insn))
        _edit_line_at(facts, address,
                      lambda line: "%s:\te28f0000 \tadd\tr0, pc, #0\n"
                                   "%s:\te5840298 \tstr\tr0, [r4, #%d]\t; 0x298\n%s"
                                   % (line.split(":")[0], line.split(":")[0], OFFSET, line))
    elif mutate == "the_copies_arm_a_third_label":
        _address, register, at = _arming_of(facts, "copyin")
        _edit_line_at(facts, at, lambda line: re.sub(r"#(0x[0-9a-fA-F]+|\d+)", "#0", line, count=1))
    elif mutate == "copyin_leaves_the_functions_that_arm_it":
        facts["image_dis"] = re.sub(r"^%08x <copyin>:$" % facts["syms"]["copyin"],
                                    "%08x <copies_in>:" % facts["syms"]["copyin"],
                                    facts["image_dis"], count=1, flags=re.M)
        facts["nm_text"] = re.sub(r"^%08x T copyin$" % facts["syms"]["copyin"],
                                  "%08x T copies_in" % facts["syms"]["copyin"],
                                  facts["nm_text"], count=1, flags=re.M)
    elif mutate == "the_handler_stops_consuming_the_word":
        # The needle carries the *next* statement, because `sleh_undef` has the same two lines
        # earlier in the file: without it the mutation edits the other function and the claim
        # rightly sees nothing wrong with `sleh_abort`.
        facts["trap"] = _bump(facts["trap"],
                              "recover = thread->recover;\n\tthread->recover = 0;\n\n"
                              "\tstatus = regs->fsr & FSR_MASK;",
                              "recover = thread->recover;\n\n\tstatus = regs->fsr & FSR_MASK;")
    elif mutate == "the_handler_pages_in_before_the_cheap_check":
        facts["trap"] = _bump(facts["trap"],
                              "result = arm_fast_fault(map->pmap, trunc_page(fault_addr), "
                              "fault_type, FALSE);\n\t\t\tif (result == KERN_SUCCESS)\n\t\t\t\t"
                              "goto exit;",
                              "result = vm_fault(map, fault_addr, fault_type, FALSE, "
                              "VM_KERN_MEMORY_NONE, 0, NULL, 0);\n\t\t\tif (result == KERN_SUCCESS)\n"
                              "\t\t\t\tgoto exit;\n\t\t\tresult = arm_fast_fault(map->pmap, "
                              "trunc_page(fault_addr), fault_type, FALSE);")
    elif mutate == "the_recovery_arm_stops_testing_for_zero":
        facts["trap"] = _bump(facts["trap"], "if (recover != 0) {", "if (1) {")
    elif mutate == "the_recovery_arm_leaves_the_pc_alone":
        facts["trap"] = _bump(facts["trap"],
                              "regs->pc = (register_t) (recover & ~0x1);", "(void)recover;")
    elif mutate == "the_recovery_arm_moves_above_the_page_in":
        facts["trap"] = _bump(
            facts["trap"],
            "result = arm_fast_fault(map->pmap, trunc_page(fault_addr), fault_type, FALSE);",
            "if (recover != 0) {\n\t\t\t\tregs->pc = (register_t) (recover & ~0x1);\n"
            "\t\t\t\tregs->cpsr = (regs->cpsr & ~PSR_TF) | ((recover & 0x1) << PSR_TFb);\n"
            "\t\t\t\tgoto exit;\n\t\t\t}\n\t\t\tresult = arm_fast_fault(map->pmap, "
            "trunc_page(fault_addr), fault_type, FALSE);")
    elif mutate == "assym_moves_the_offset":
        facts["assym"] = _bump(facts["assym"], "#define TH_RECOVER #664", "#define TH_RECOVER #668")
    elif mutate == "assym_forgets_the_offset":
        facts["assym"] = _bump(facts["assym"], "#define TH_RECOVER #664\n", "")
    elif mutate == "the_kernel_object_moves_the_field":
        facts["kobj_dis"] = _bump(facts["kobj_dis"],
                                  "ldr\tr7, [r1, #664]\t; 0x298", "ldr\tr7, [r1, #668]\t; 0x298")
    elif mutate == "the_kernel_object_reads_without_zeroing":
        facts["kobj_dis"] = _bump(facts["kobj_dis"],
                                  "str\tr0, [r1, #664]\t; 0x298", "str\tr0, [r1, #660]\t; 0x294")
    elif mutate == "the_kernel_object_loses_the_read":
        facts["kobj_dis"] = _bump(facts["kobj_dis"],
                                  "ldr\tr7, [r1, #664]\t; 0x298", "ldr\tr7, [r1, #660]\t; 0x294")
    elif mutate == "the_header_stops_defining_the_offset":
        facts["header"] = _bump(facts["header"], "#define STAGE90_TH_RECOVER     664",
                                "#define STAGE90_TH_RECOVER_VALUE 664")
    elif mutate == "the_wrapper_reads_after_the_handler":
        facts["trace"] = _bump(
            facts["trace"],
            "    recover = ((const uint32_t *)(uintptr_t)thread)[STAGE90_TH_RECOVER / 4];\n\n"
            "    entry_note_sleh((uint32_t)type, fsr, far_, thread, (const uint32_t *)regs, recover);\n"
            "\n    __real_sleh_abort(regs, type);",
            "    entry_note_sleh((uint32_t)type, fsr, far_, thread, (const uint32_t *)regs, recover);\n"
            "\n    __real_sleh_abort(regs, type);\n\n"
            "    recover = ((const uint32_t *)(uintptr_t)thread)[STAGE90_TH_RECOVER / 4];")
    elif mutate == "the_wrapper_reads_and_drops_it":
        facts["trace"] = _bump(
            facts["trace"],
            "    entry_note_sleh((uint32_t)type, fsr, far_, thread, (const uint32_t *)regs, recover);",
            "    entry_note_sleh((uint32_t)type, fsr, far_, thread, (const uint32_t *)regs, 0u);")
    elif mutate == "the_record_stops_taking_the_argument":
        facts["stubs"] = _bump(
            facts["stubs"],
            "void entry_note_sleh(uint32_t type, uint32_t fsr, uint32_t far_, uint32_t thread,\n"
            "                     const uint32_t *frame, uint32_t recover)",
            "void entry_note_sleh(uint32_t type, uint32_t fsr, uint32_t far_, uint32_t thread,\n"
            "                     const uint32_t *frame)")
    elif mutate == "the_record_stops_publishing_it":
        facts["stubs"] = _bump(facts["stubs"],
                               'entry_live_write("xnu_live_sleh_recover", recover);', "(void)recover;")
    elif mutate == "the_wrapper_stops_asking_whether_it_was_spent":
        facts["trace"] = _bump(
            facts["trace"],
            "    redirected = 0u;\n"
            "    if ((recover != 0u) && (regs != 0)) {\n"
            "        if (((const uint32_t *)(uintptr_t)regs)[STAGE90_SS_PC / 4] == (recover & ~0x1u))\n"
            "            redirected = 1u;\n"
            "    }\n\n"
            "    entry_note_sleh_back(redirected);",
            "    redirected = recover & ~0x1u;\n\n"
            "    entry_note_sleh_back(redirected);")
    elif mutate == "the_wrapper_compares_before_the_handler":
        facts["trace"] = _bump(
            facts["trace"],
            "    entry_note_sleh((uint32_t)type, fsr, far_, thread, (const uint32_t *)regs, recover);\n\n"
            "    __real_sleh_abort(regs, type);",
            "    entry_note_sleh((uint32_t)type, fsr, far_, thread, (const uint32_t *)regs, recover);\n"
            "    redirected = 0u;\n"
            "    if (((const uint32_t *)(uintptr_t)regs)[STAGE90_SS_PC / 4] == (recover & ~0x1u))\n"
            "        redirected = 1u;\n\n"
            "    __real_sleh_abort(regs, type);")
    elif mutate == "the_wrapper_forgets_the_state_bit":
        facts["trace"] = _bump(facts["trace"], "== (recover & ~0x1u))", "== recover)")
    elif mutate == "the_record_counts_spending_as_arming":
        # The name and the test it is fed by are the two halves of one property: a key called
        # `_armed` fed by the post-call comparison would count armings while naming spendings.
        facts["stubs"] = _bump(facts["stubs"],
                               'entry_live_write("xnu_live_sleh_armed", g_sleh_armed);',
                               'entry_live_write("xnu_live_sleh_recovered", g_sleh_armed);')
    elif mutate == "the_record_drops_the_per_entry_outcome":
        facts["stubs"] = _bump(facts["stubs"],
                               '        entry_live_write("xnu_live_sleh_redirect", redirected);\n',
                               "")
    elif mutate == "the_user_path_returns_to_the_handler":
        facts["trap"] = _bump(facts["trap"],
                              "if (result == KERN_SUCCESS || result == KERN_ABORTED) {\n"
                              "\t\t\tgoto exception_return;",
                              "if (result == KERN_SUCCESS || result == KERN_ABORTED) {\n"
                              "\t\t\tgoto exit;")
    elif mutate == "the_user_path_leaves_without_returning_to_user_mode":
        facts["trap"] = _bump(facts["trap"], "thread_exception_return();\n\t \n\nexit:",
                              "(void)recover;\n\n"
                              "exit:")
    elif mutate == "the_check_leaves_the_build":
        facts["build_entry"] = _bump(facts["build_entry"],
                                     'run python3 "$REPO_ROOT/tools/check_fault_recovery.py" '
                                     '--image "$OUT/xnu_arm_entry.elf" --verbose || exit 1',
                                     "true")
        facts["build_entry"] = _bump(facts["build_entry"],
                                     'run python3 "$REPO_ROOT/tools/check_fault_recovery.py" '
                                     '--image "$OUT/xnu_arm_entry.elf" --selftest || exit 1',
                                     "true")
    else:
        raise SystemExit("unknown mutation %s" % mutate)

    facts["headings"] = symbol_table(facts["image_dis"])
    facts["syms"] = {name: address for address, name in facts["headings"]}
    facts["insns"] = instructions(facts["image_dis"])
    facts["globals"] = globals_of(facts["nm_text"])
    facts["kobj_insns"] = instructions(facts["kobj_dis"])
    return facts


MUTATIONS = (
    "the_recovery_target_stops_setting_efault", "the_recovery_target_gains_a_caller",
    "copyin_stops_arming_the_recovery_address", "copyin_arms_the_wrong_offset",
    "copyin_arms_a_label_short_of_the_target", "copyout_stops_arming_the_recovery_address",
    "something_else_in_the_image_arms_it", "copyin_leaves_the_functions_that_arm_it",
    "the_handler_stops_consuming_the_word", "the_handler_pages_in_before_the_cheap_check",
    "the_recovery_arm_stops_testing_for_zero", "the_recovery_arm_leaves_the_pc_alone",
    "the_recovery_arm_moves_above_the_page_in", "assym_moves_the_offset",
    "assym_forgets_the_offset", "the_kernel_object_moves_the_field",
    "the_kernel_object_reads_without_zeroing", "the_kernel_object_loses_the_read",
    "the_header_stops_defining_the_offset", "the_wrapper_reads_after_the_handler",
    "the_wrapper_reads_and_drops_it", "the_record_stops_taking_the_argument",
    "the_record_stops_publishing_it", "the_check_leaves_the_build",
    "the_wrapper_stops_asking_whether_it_was_spent", "the_wrapper_compares_before_the_handler",
    "the_wrapper_forgets_the_state_bit", "the_record_counts_spending_as_arming",
    "the_record_drops_the_per_entry_outcome", "the_user_path_returns_to_the_handler",
    "the_user_path_leaves_without_returning_to_user_mode",
)


D13_MUTATIONS = (
    "a_copy_stops_arming_the_recovery_address",
    "a_copy_arms_an_address_that_is_not_its_exit",
    "a_copy_leaves_the_functions_that_arm_it",
    "the_handler_stops_gating_on_the_word",
    "assym_moves_the_offset",
    "assym_forgets_the_offset",
    "the_kernel_object_moves_the_field",
    "the_kernel_object_loses_the_read",
    "the_header_stops_defining_the_offset",
    "the_wrapper_reads_after_the_handler",
    "the_wrapper_reads_and_drops_it",
)


def selftest(facts):
    baseline, _notes = compare(facts)
    if baseline:
        print("FAIL: the check does not hold for the image it was written against:", file=sys.stderr)
        for failure in baseline:
            print("      " + failure, file=sys.stderr)
        return 1
    mutations = D13_MUTATIONS if IS_D13 else MUTATIONS
    accepted = []
    for name in mutations:
        try:
            failures, _notes = compare(facts, mutate=name)
        except SystemExit:
            raise
        except Exception as error:                                  # noqa: BLE001
            print("      RAISED: %s: %s" % (name, error), file=sys.stderr)
            accepted.append(name)
            continue
        if not failures:
            accepted.append(name)
            print("      ACCEPTED: %s" % name, file=sys.stderr)
        else:
            say("      refused: %-48s %s" % (name, failures[0][:90]))
    if accepted:
        print("FAIL: %d of %d mutations were not refused: %s"
              % (len(accepted), len(mutations), ", ".join(accepted)), file=sys.stderr)
        return 1
    say("  --selftest: all %d %smutations were refused"
        % (len(mutations), "D13 " if IS_D13 else ""))
    return 0


def gather(image):
    facts = {"image": image}
    facts["image_dis"] = run([OBJDUMP, "-d", image])
    facts["headings"] = symbol_table(facts["image_dis"])
    facts["nm_text"] = run([NM, image])
    facts["globals"] = globals_of(facts["nm_text"])
    facts["syms"] = {name: address for address, name in symbol_table(facts["image_dis"])}
    facts["insns"] = instructions(facts["image_dis"])
    facts["kobj_dis"] = run([OBJDUMP, "-d", KOBJ])
    facts["kobj_insns"] = instructions(facts["kobj_dis"])
    facts["kobj_nm_text"] = run([NM, KOBJ])
    facts["kobj_globals"] = globals_of(facts["kobj_nm_text"])
    facts["trap"] = strip_comments(read(TRAP_C))
    facts["header"] = read(HEADER)
    facts["trace"] = strip_comments(read(TRACE_C))
    facts["stubs"] = strip_comments(read(STUBS_C))
    facts["build_entry"] = read(BUILD_ENTRY)
    facts["assym"] = read(ASSYM)
    return facts


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[1])
    parser.add_argument("--image", required=True, help="the linked entry image")
    parser.add_argument("--tree", default=None,
                        help="the XNU tree the image was built from (D13 detected by osfmk/sys/types.h)")
    parser.add_argument("--selftest", action="store_true")
    parser.add_argument("--verbose", action="store_true")
    args = parser.parse_args()

    tree = args.tree or os.environ.get("XNU_TREE") or os.path.join(
        REPO_ROOT, "external/xnu-4570.1.46")
    configure(tree)

    missing = [path for path in (args.image, KOBJ, ASSYM, TRAP_C, MACHINE_ASM)
               if not os.path.exists(path)]
    if missing:
        print("FAIL: %s: the claims are about the linked instructions and the kernel's own compiled "
              "C, so a build whose step 2 or step 3 has not run has nothing here to read"
              % ", ".join(os.path.relpath(p, REPO_ROOT) for p in missing), file=sys.stderr)
        return 1

    facts = gather(args.image)
    if args.selftest:
        return selftest(facts)

    failures, notes = compare(facts)
    if args.verbose:
        for note in notes:
            say("    " + note)
    if failures:
        print("FAIL: this image's copy faults are not recoverable by design, or the run cannot say "
              "which were:", file=sys.stderr)
        for failure in failures:
            print("      " + failure, file=sys.stderr)
        return 1
    if IS_D13:
        say("  xnu_entry_490: the fault inside `copyin` is the design, not the frontier - each of the "
            "four copies arms `TH_RECOVER` (= %d in this tree) with its own local fault label, out of "
            "the instructions this build linked, and nothing else in the image puts a computed address "
            "there; `sleh_abort` consults the word only after attempting the page-in twice and, in the "
            "recovery arm, points the frame's `pc` at it; the kernel's own compiled `sleh_abort` reads "
            "and zeroes the same offset; and the instrument publishes the before-call read and the "
            "after-call frame read as two numbers under two names" % OFFSET)
    else:
        say("  xnu_entry_490: the fault inside `copyin` is the design, not the frontier - both copy "
            "paths arm `TH_RECOVER` with `copyio_error`'s own address out of the instructions this "
            "build linked, nothing else in the image puts a computed address there, the handler "
            "consumes the word and is redirected to it only after both page-in attempts fail, the "
            "kernel's own compiled `sleh_abort` reads and zeroes the same offset, the instrument "
            "publishes it before the call that would spend it, and it reads the frame after that call "
            "so the run reports the faults the kernel planned for and the faults it actually converted "
            "into `EFAULT` as two numbers under two names - while the handler's user half leaves "
            "through `thread_exception_return()`, which is why the two records with no `_back` are the "
            "two the kernel serviced for a user thread")
    return 0


if __name__ == "__main__":
    sys.exit(main())
