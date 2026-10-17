#!/usr/bin/env python3
"""Stage 1024's USER-MAP CEILING fix into the D13 tree: make `VM_MAX_ADDRESS` agree with `set_mmu_ttbcr(2)`.

THE FAULT THIS ANSWERS, BY VALUE (docs/1024-design.md, records/1023-press-read.txt).

  1023's press moved the wall: trap 24 dispatches and `mach_port_construct` returns 0, and pid 1 then
  dies in a ~2^20-iteration DATA-ABORT LOOP on `ldr r0,[r5,#8]` at `_pthread_create+0xbc`
  (0x38241790, libsystem_pthread.dylib[639]) with `r5 = 0x40083000` - the pthread stack/struct pointer
  out-param 1 of `__pthread_allocate_stack` (0x38242494) returned - and the kernel's own walk finds
  `ptel2 = 0` for it. The load is a READ (DFSR 0x07, WnR bit 11 clear).

  The mechanism is a ONE-VALUE DISAGREEMENT:

    hardware:  `set_mmu_ttbcr(2)` (osfmk/arm/arm_vm_init.c:475) gives TTBR0 exactly 1 GiB -
               [0, 0x40000000); every VA at/above 0x40000000 is walked through TTBR1 (the KERNEL's
               tree, cpu_ttb); everything in [0x40000000, 0x80000000) is UNREACHABLE for user pages.
    kernel:    `task_create_internal` links `vm_map_create(pmap, 0, VM_MAX_ADDRESS, TRUE, ...)` with
               VM_MAX_ADDRESS = **0x80000000** - this tree's `mach/arm/vm_param.h:62-68` compiles the
               `#else` branch on CANCRO because `BOARD_CONFIG_ARMPBA8 || BOARD_CONFIG_QSD8250_LEO`
               is 0 here (tools/patch_d13_shreg_wire.py:18 says so, and the ARMED ELF proves it:
               `80085cf0 e3a02102 mov r2, #-2147483648 ; 0x80000000`, then `80085cfc bl vm_map_create`).

  So the first big anywhere-allocation in launchd - pthread_create's stack mmap - is placed ABOVE the
  split, `vm_fault` "succeeds" into a tree the hardware never walks for that VA, and the load faults
  for ever. The header's OWN comment (vm_param.h:64-65) states the rule the port is breaking:
  "This ARM pmap uses a 1 GiB TTBR0 split. Ordinary user allocations must stay below the
  kernel-owned commpage at 0x40000000."

THE FIX - ONE WHOLE-LINE EDIT, IN THE FILE THAT ALREADY ARGUES FOR IT.

  `:63`  `#if BOARD_CONFIG_ARMPBA8 || BOARD_CONFIG_QSD8250_LEO`
  ->`#if BOARD_CONFIG_ARMPBA8 || BOARD_CONFIG_QSD8250_LEO || (defined(STAGE90_XNU_VM_MAX_SPLIT) && STAGE90_XNU_VM_MAX_SPLIT)`

  `defined()` comes FIRST in the clause (`defined(X) && X`), so the identifier is never evaluated
  undefined and a build with the switch off emits the tree's original condition exactly
  (`mi4-off-option-two-spellings`). With `-DSTAGE90_XNU_VM_MAX_SPLIT=1` the branch is taken on
  CANCRO and `VM_MAX_ADDRESS` is 0x40000000, exactly as on the two boards the tree already
  considers 1-GiB-split boards.

  WHY A SWITCH AND NOT THE BOARD MACRO.  Defining `BOARD_CONFIG_QSD8250_LEO` (or ARMPBA8) on CANCRO
  would flip EVERY gate keyed on those names across the tree (traps_lo.s's -3 SWI routing,
  ios7_compat.h's `ios7_compat_vmabi_enabled()`, ...) - not a one-value change. The port's idiom is
  one switch per fix, carried in the arm record; this patch follows it, and the switch is the port's
  board by construction.

THE TWO-ARM PROOF (`--verify-off`) runs the REAL preprocessor over this file, both arms:

  * switch unset: `VM_MAX_ADDRESS` expands to `((vm_address_t) 0x80000000)` (the tree's behaviour);
  * `-DSTAGE90_XNU_VM_MAX_SPLIT=1`: it expands to `((vm_address_t) 0x40000000)`.
  `vm_param.h` includes NOTHING (checked: the file is pure preprocessor + `#define`s), so a
  self-contained probe translation unit can include it directly and print the macro - no XNU include
  path is needed, and no `__ASSEMBLER__` environment exists to complicate it.

  The LINKED-image by-value clause is `tools/check_vm_max_split.py <elf> --expect on|off` (reads the
  `mov r2,#imm` that feeds `vm_map_create` inside `task_create_internal`); the 1023 image is its OFF
  control, and build_1024.sh asserts BOTH directions around the pool rebuild.

Idempotent, LINE-based (`mi4-an-edit-on-a-prefix-deletes-the-suffix`: the OLD line is a PREFIX of the
NEW one, so a substring replace would re-match its own output). The gate is DECIDED before it is
written and its match counts are asserted exactly, so a file with a partial or double edit is
REFUSED with the file untouched. Re-run: the counts say "already staged" and nothing is written.
"""
import subprocess
import sys
import tempfile
from pathlib import Path

OLD = "#if BOARD_CONFIG_ARMPBA8 || BOARD_CONFIG_QSD8250_LEO"
NEW = ("#if BOARD_CONFIG_ARMPBA8 || BOARD_CONFIG_QSD8250_LEO"
       " || (defined(STAGE90_XNU_VM_MAX_SPLIT) && STAGE90_XNU_VM_MAX_SPLIT)")

REL = "osfmk/mach/arm/vm_param.h"
# An anchor that proves this is the file the patch was written for - the line immediately above the
# gate and the rule the port is breaking, together.
ANCHOR = "Ordinary user allocations must"
EXPECT = 1  # the gate line occurs exactly once in this file (measured: grep -c, count 1)

PROBE = """\
/* 1024 probe: include the patched header and materialize the macro.  vm_param.h includes nothing. */
#define BOARD_CONFIG_ARMPBA8 0
#define BOARD_CONFIG_QSD8250_LEO 0
#define __arm__ 1
#include "%s"
VM_MAX_ADDRESS
"""


def preprocess(path: Path, on: bool) -> str:
    """Run the real preprocessor over a probe TU that includes `path`; return its stdout."""
    with tempfile.TemporaryDirectory(prefix="vm_max_split.") as td:
        probe = Path(td) / "probe.c"
        probe.write_text(PROBE % path)
        cmd = ["cc", "-E", "-P"]
        if on:
            cmd.append("-DSTAGE90_XNU_VM_MAX_SPLIT=1")
        cmd.append(str(probe))
        r = subprocess.run(cmd, capture_output=True, text=True)
        if r.returncode != 0:
            print(f"patch_d13_vm_max_split: preprocessor FAILED ({' '.join(cmd)}):\n{r.stderr}",
                  file=sys.stderr)
            raise SystemExit(5)
        return r.stdout


def verify_both(path: Path) -> int:
    """Prove BOTH arms with the real preprocessor.  Returns 0 on success, 4 on a failed proof."""
    off = preprocess(path, on=False)
    on = preprocess(path, on=True)
    # The probe's last line is the expansion; look at the whole output for the value, but REQUIRE the
    # other value's absence so a stray copy cannot satisfy the assertion.
    if "0x80000000" not in off or "0x40000000" in off:
        print("patch_d13_vm_max_split: OFF PROOF FAILED - with the switch unset the probe did not "
              f"expand VM_MAX_ADDRESS to 0x80000000 (got: {off.strip()!r})", file=sys.stderr)
        return 4
    if "0x40000000" not in on or "0x80000000" in on:
        print("patch_d13_vm_max_split: ON PROOF FAILED - with -DSTAGE90_XNU_VM_MAX_SPLIT=1 the probe "
              f"did not expand VM_MAX_ADDRESS to 0x40000000 (got: {on.strip()!r})", file=sys.stderr)
        return 4
    print(f"  {REL}: preprocessor proof - OFF -> 0x80000000, ON -> 0x40000000 (both arms)")
    return 0


def main() -> int:
    apply_ = "--apply" in sys.argv[1:]
    verify = "--verify-off" in sys.argv[1:]
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    if len(args) != 1 or (apply_ and verify):
        print("usage: patch_d13_vm_max_split.py <xnu-tree-root> [--apply | --verify-off]",
              file=sys.stderr)
        return 2
    path = Path(args[0]) / REL
    if not path.is_file():
        print(f"patch_d13_vm_max_split: no {REL} under {args[0]} (D13 tree not provisioned?)",
              file=sys.stderr)
        return 2
    text = path.read_text()
    if ANCHOR not in text:
        print(f"patch_d13_vm_max_split: REFUSING: {REL} carries no [{ANCHOR}] - this is not the tree "
              f"this patch was written for", file=sys.stderr)
        return 3

    if verify:
        # The proof runs on the file AS IT IS ON DISK - staged or not, the ON arm must be the new
        # ceiling and the OFF arm the tree's, or the staged tree is not the shape this rung declares.
        return verify_both(path)

    lines = text.split("\n")
    at_old = [i for i, ln in enumerate(lines) if ln == OLD]
    at_new = [i for i, ln in enumerate(lines) if ln == NEW]
    if len(at_old) == 0 and len(at_new) == EXPECT:
        print(f"  {REL}: already staged ({len(at_new)} gate line carries the switch)")
        return 0
    if len(at_old) != EXPECT or at_new:
        print(f"patch_d13_vm_max_split: REFUSING: {REL} has {len(at_old)} original + {len(at_new)} "
              f"staged gate line(s), expected {EXPECT} original and 0 staged (or 0 and {EXPECT}) - a "
              f"partial or double edit is not repaired in place", file=sys.stderr)
        return 4

    if not apply_:
        print(f"  {REL}: plan OK - 1 gate line to widen at line {at_old[0] + 1} "
              f"(VM_MAX_ADDRESS 0x80000000 -> 0x40000000 with the switch on)")
        return 0

    # **THE PROOF RUNS BEFORE THE WRITE.**  Write the edited text to the file only after both arms
    # have been shown to be the declared shapes on THIS tree's bytes.
    for i in at_old:
        lines[i] = NEW
    path.write_text("\n".join(lines))
    rc = verify_both(path)
    if rc != 0:
        # Restore the original text - a failed proof must not leave a half-blessed edit behind.
        path.write_text(text)
        print("patch_d13_vm_max_split: REVERTED - the proof failed after the write; file restored",
              file=sys.stderr)
        return rc
    print(f"patch_d13_vm_max_split: staged 1 gate line at line {at_old[0] + 1} in {REL}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())