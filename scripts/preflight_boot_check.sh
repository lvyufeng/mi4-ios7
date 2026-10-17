#!/usr/bin/env bash
#
# Gate a hardware run of the Stage90 payload.
#
# The 2026-09-16 PREFLIGHT_WATCHDOG_ONLY run ended with the device hung and a
# manual power-button hold needed. Knowing which switches an image was actually
# built with, and refusing the risky ones by default, is the cheapest way to stop
# that happening again - a rebuild that silently picks up a risky mode is exactly
# how an unintended hang gets booted.
#
# This script never runs fastboot and never touches the device. It verifies the
# image and prints the command to run, or refuses and says why.
#
# Usage: ./preflight_boot_check.sh [--allow-preflight] [--allow-full] [--allow-selftest] [--allow-attr-normal-nc] [--allow-attr-normal-wb] [--allow-icache] [--allow-dcache] [--allow-xnu-entry] [--allow-hw-watchdog-selftest] [--allow-fault-inject]

set -euo pipefail

cd "$(dirname "$0")"
SCRIPT_DIR=$PWD
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
SRC_DIR=$REPO_ROOT/src
OUT=$REPO_ROOT/out/stage90

ALLOW_PREFLIGHT=0
ALLOW_FULL=0
ALLOW_SELFTEST=0
ALLOW_ATTR=0
ALLOW_ATTR_WB=0
ALLOW_ICACHE=0
ALLOW_DCACHE=0
ALLOW_XNU_ENTRY=0
ALLOW_HW_SELFTEST=0
ALLOW_FAULT_INJECT=0

for arg in "$@"; do
  case "$arg" in
    --allow-preflight)   ALLOW_PREFLIGHT=1 ;;
    --allow-full)        ALLOW_FULL=1 ;;
    --allow-selftest)    ALLOW_SELFTEST=1 ;;
    --allow-attr-normal-nc) ALLOW_ATTR=1 ;;
    --allow-attr-normal-wb) ALLOW_ATTR_WB=1 ;;
    --allow-icache)       ALLOW_ICACHE=1 ;;
    --allow-dcache)       ALLOW_DCACHE=1 ;;
    --allow-xnu-entry)    ALLOW_XNU_ENTRY=1 ;;
    --allow-hw-watchdog-selftest) ALLOW_HW_SELFTEST=1 ;;
    --allow-fault-inject) ALLOW_FAULT_INJECT=1 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

fail() { echo "REFUSING: $*" >&2; exit 1; }

# This file's exit codes are meant to be total: 0 = green, 1 = a refusal printed above, 2 = the argument
# parser above and nothing else. `set -e` made that false. Under it an unguarded command that failed ended
# the script with **that command's own status**, so `exit 2` had two producers - and the one an operator is
# taught to read ("unknown argument") could equally mean a tool that could not READ an artifact. Measured:
# the entry record present with mode 000 gives `awk: fatal: cannot open file ... Permission denied` (status
# 2) straight through the `[[ -n $recorded_sha ]]` guard on the next line, with no REFUSING line and no
# section named. That is the defect this gate exists to catch in other files, arriving in this one: the
# rule here is "read a red gate by which section refused", and a bare tool status has no section - so a red
# gate whose only line is a tool's error cannot be read at all. It is 573's `UNREAD` line printed inside an
# `EXIT=0` run, one layer up: a status that does not carry its own reading. 580 named the same shape on the
# runner's side (`grep -c` prints 0 for input it never read); here the status is passed through rather than
# zeroed, and the repair is the same in kind - make the carrier say which reading it is.
#
# So every failure that reaches `set -e` is restated as this file's own refusal, naming the command that
# failed (most of them carry the path they could not read). `fail` is unaffected: it is the command
# following the final `||`, so its `exit` raises no ERR - and neither does the argument parser's `exit 2`.
# Both guarded idioms this file leans on (`cmd || true`, and a test in an `if`) are outside ERR by the same
# rule, so a read that succeeded cannot reach this line.
_errtrap() {
  local st=$?
  echo "REFUSING: the gate stopped with status $st at line $1, before any verdict; the command that failed was:" >&2
  echo "          $2" >&2
  echo "          That is the gate failing to READ something - not a finding about the artifact, and not the" >&2
  echo "          argument parser (the only exit 2). The last reading that completed is the one printed above" >&2
  echo "          this line; nothing below it was judged. Check that the path named above is readable." >&2
  exit 1
}
trap '_errtrap "$LINENO" "$BASH_COMMAND"' ERR

# Every artifact this gate draws a verdict from is opened by a *tool* below - cat, sed, awk, cmp, nm,
# sha256sum, the entry-blob python, the disassembler - and `[[ -f ]]` is true for a path this process
# cannot open (mode 000, another owner, a directory wearing the file's name). Measured on three of these
# paths, three different clauses answered an unreadable input three different ways: the entry record gave
# `awk`'s status 2, the build config gave `cat`'s status 1 with no refusal line at all, and the entry image
# gave the *entry-blob comparison's* verdict - "the image does not carry the arm ... byte for byte" - which
# is a finding about the artifact produced by a read that never happened, the defect class this project
# keeps meeting. So readability is checked where existence is checked. This list is the set of artifacts
# the gate *knows* it reads, and it is deliberately not the invariant: `_errtrap` above is, for the log,
# the fixture, the decoder and anything added later. And the entry ELF is deliberately not in this list -
# its unreadability is 579's four-way UNREAD, which is non-fatal by design, because that clause runs last
# and everything above it has already been judged.
_readable() {  # _readable <path> <what the gate reads out of it>
  # The `-e` branch is what the checksum list needs (it has no `-f` guard of its own, because the command
  # that reads it - `sha256sum -c` - used to be the thing that reported it, as "the image does not match
  # SHA256SUMS.txt", which is a finding about the image produced by a missing list); for the seven sites
  # that already have a `[[ -f ]]` guard above it, this branch is unreachable and the message is theirs.
  [[ -e $1 ]] || fail "no $1 - $2"
  # `-L`: GNU stat does not dereference by default, and `out/` uses symlinks, so without it this message
  # would print the *link's* mode (777) while the tools open the target - one value, two definitions, in
  # the line that exists to report a read that could not happen. And the leaf's mode is not the whole
  # answer (a parent directory or an ACL can deny the open with the leaf at 644), so the message says which
  # fact it is giving rather than implying it is the cause.
  [[ -r $1 ]] || fail "$1 exists but this gate cannot read it; the file's own mode is $(stat -Lc '%04a' "$1" 2>/dev/null || echo '?') (octal, the form chmod takes) and its owner $(stat -Lc '%U' "$1" 2>/dev/null || echo '?'), which is the leaf's fact only - a parent directory or an ACL can deny the open with these at their normal values. $2. A clause whose input could not be opened has no verdict about the artifact, so it stops here instead of reporting one; fix the permissions and re-run"
}

# The tools this gate calls. PYTHON is configurable for the same reason build.sh's is -
# the host may have python3 under another name.
PYTHON=${PYTHON:-python3}

CONFIG=$OUT/stage90-build-config.txt
IMAGE=$OUT/stage90-qcdt.img

[[ -f $CONFIG ]] || fail "no $CONFIG - run ./build.sh first to record the build switches"
_readable "$CONFIG" "the build switches every clause below narrates are read out of it"
[[ -f $IMAGE  ]] || fail "no $IMAGE - run ./build.sh first"
_readable "$IMAGE" "the boot image is what the entry-blob comparison and the string scans read"

echo "== build configuration =="
cat "$CONFIG"

# Read one `#define` out of the record. The key match is on the WHOLE second field rather than on
# a prefix, and this is why the function is awk rather than the obviously tidier tolerant `sed`:
# `s/^#define $1[[:space:]]*//p` repairs the whitespace cases below and opens a prefix collision in
# the same edit - `STAGE90_K_SHA256 abcd` answers for `STAGE90_K` with `_SHA256 abcd` and
# `STAGE90_KNEE 7` answers with `NEE 7` (both measured 2026-09-23). The bare `[[:space:]]*` after an
# unanchored `$1` is what does it; the pattern this replaces happened to be safe only because it
# demanded a literal space, which is a property of that accident and not of the rule.
# A key whose line carries no value prints empty here exactly like a key with no line at all. The
# two are different records and are told apart by `value_reason`, never by this function's output.
value_of() {
  awk -v k="$1" '
    $1 == "#define" && $2 == k {
      v = $0; sub(/^[[:space:]]*#define[[:space:]]+[^[:space:]]+[[:space:]]*/, "", v); print v; exit
    }' "$CONFIG"
}

# Why `value_of` came back empty, as a REASON and not as an emptiness: `absent` (the record has no
# such line) and `empty` (the line is there and carries nothing - a bare `#define K`, or a value the
# extractor cannot see) are two different records, and 632's shape is printing them as one sentence
# naming the wrong one. A tolerant extractor does not make this function unnecessary: `#define K`
# still answers empty however tolerant the pattern is, so the tolerance moves the boundary and does
# not remove it.
value_reason() {
  awk -v k="$1" '
    BEGIN { r = "absent" }
    $1 == "#define" && $2 == k {
      v = $0; sub(/^[[:space:]]*#define[[:space:]]+[^[:space:]]+[[:space:]]*/, "", v)
      r = (v == "") ? "empty" : "ok"; exit
    }
    END { print r }' "$CONFIG"
}

# OFF is a value the record STATES, not a value this gate failed to find. The `case` blocks below
# used to write `0|0u|""`, grouping the empty value with the off values - so a malformed record took
# the off branch in silence. At the fault-injection block that branch is where the
# `--allow-fault-inject` refusal sits, which is why that one was functional rather than cosmetic.
is_off() {
  case "$1" in
    0|0u) return 0 ;;
    *)    return 1 ;;
  esac
}

MODE=$(value_of STAGE90_HANDOFF_MODE)
SELFTEST=$(value_of STAGE90_DEADMAN_SELFTEST)
DEADMAN=$(value_of STAGE90_DEADMAN_ENABLE)
LADDER=$(value_of STAGE90_ENTRY_LADDER_LEVEL)
HWWDT=$(value_of STAGE90_HW_WATCHDOG)
HWSELFTEST=$(value_of STAGE90_HW_WATCHDOG_SELFTEST)
FAULT_INJECT=$(value_of STAGE90_HANDOFF_FAULT_INJECT_VA)

# The same discipline `ENTRY_CFG_KEYS` applies to the entry record, applied to THIS record - which
# had one of the sixteen keys asserted and the other fifteen read on faith. `$MODE` guarded the one
# key every clause below happens to mention; a record missing any other key printed its own absence
# as an OFF state, because `value_of` answers empty for "no line" and for "a line with no value"
# alike and the blocks that consumed it grouped empty with off. Presence here is a VALUE, not a
# line: `#define STAGE90_XNU_ENTRY` with nothing after it is a malformed record and not an off arm.
BUILD_CFG_KEYS=(STAGE90_HW_WATCHDOG STAGE90_HANDOFF_MODE STAGE90_CACHE_MODE
                STAGE90_ENTRY_LADDER_LEVEL STAGE90_XNU_ENTRY STAGE90_HANDOFF_FAULT_INJECT_VA
                STAGE90_DEADMAN_SELFTEST STAGE90_XNU_BOOT_ARGS STAGE90_XNU_MSM8974_FIQ_PROBE
                STAGE90_XNU_REAL_DT STAGE90_PMAP_ATTR_MODE STAGE90_BYPASS_ENTRY_STUB
                STAGE90_EXCLUSIVE_PROBE STAGE90_XNU_MSM8974_SHIM STAGE90_DEADMAN_ENABLE
                STAGE90_HW_WATCHDOG_SELFTEST)
for _k in "${BUILD_CFG_KEYS[@]}"
do
  case "$(value_reason "$_k")" in
    ok) ;;
    absent)
      fail "$CONFIG has no $_k line - every clause below reads this record and narrates a state from
it, and a key that is not in the record is a state nobody chose. This gate cannot refuse the run
for the key being unrecorded and useless: the record IS the only place the build's switches are
readable from, so a missing key would be narrated as the state the code defaults to."
      ;;
    empty)
      fail "$CONFIG has a $_k line with no value after it. This is NOT the same as the key being
absent: the line is there and the gate cannot read a value out of it. A bare '#define $_k' is the
common cause, and a value carrying leading whitespace the old extractor did not tolerate was the
other. Both used to print as an OFF state, and at STAGE90_HANDOFF_FAULT_INJECT_VA the off branch is
where the --allow-fault-inject refusal is skipped."
      ;;
  esac
  printf '  %s=%s\n' "$_k" "$(value_of "$_k")"
done
# And the converse, so a key this list does not name cannot arrive unread - the same arrow-reversed
# check ENTRY_CFG_KEYS carries, for the same reason: without it the list above would be the only
# definition of what is visible, and a key added on the build side would be recorded and never read.
_unshown=$(awk '$1 == "#define" && $2 ~ /^STAGE90_/ { print $2 }' "$CONFIG" | LC_ALL=C sort -u \
           | LC_ALL=C comm -23 - <(printf '%s\n' "${BUILD_CFG_KEYS[@]}" | LC_ALL=C sort -u))
[[ -z $_unshown ]] \
  || fail "$CONFIG carries key(s) this gate does not read: $(printf '%s\n' "$_unshown" | tr '\n' ' ')- a switch recorded on the build side and never read here is a switch this run goes out with unshown; add it to BUILD_CFG_KEYS above"
# `LC_ALL=C` on all three, the same pin the entry-sources comparison uses: the two agree with each
# other under the ambient locale only by accident.
MODE=$(value_of STAGE90_HANDOFF_MODE)

echo
echo "== image integrity =="
_readable "$OUT/SHA256SUMS.txt" "every artifact this run will load is checked against its hashes"
( cd "$OUT" && sha256sum -c SHA256SUMS.txt ) || fail "image does not match SHA256SUMS.txt; rebuild before booting"
echo "sha256 verified against $OUT/SHA256SUMS.txt"
# **The hash, computed here rather than written into the prose below, and 520 is why.** 519c's edit put
# the literal `40bf8a0b...` into the XNU-entry block, where it was true of the image it was written for -
# and then 520's build produced `25c4bc7d...` and the gate went on telling the operator that the image
# being checked was 519's. The manifest check above does not catch it: `40bf8a0b...` is not compared with
# anything, so a hash in a comment is a claim, which is this project's oldest rule about checks. This is
# the value the block below prints, and it is of the file about to be booted.
IMAGE_SHA=$(sha256sum "$OUT/stage90-qcdt.img" | cut -d' ' -f1)
IMAGE_SHA16=${IMAGE_SHA:0:16}

echo
echo "== image freshness =="
# The manifest check above proves the image matches SOMETHING, but not that the something
# is the current source. If a source file was edited and not rebuilt, the image and its
# manifest are both stale and agree with each other - so the gate would report the OLD
# switches and approve the OLD image, which is precisely the failure this gate exists to
# prevent, in the direction it was blind to. Verified: without this check, touching
# stage90.h and running the gate passes.
#
# **The two scans below refuse when they fail, and they used to approve instead.** 536 added `|| true`
# here to stop a `find` that exits non-zero on a directory it cannot read from ending the script with no
# message at all under `set -e`/`pipefail` - but `|| true` does not preserve the distinction the note
# above is about, it deletes it in the direction this gate exists to prevent: with the scan empty, the
# test below finds nothing newer than the image and the gate prints its PASS. Measured by running this
# block with `SRC_DIR` pointed at a directory that does not exist, and again at one with mode 000
# (uid 1001, so the test was meaningful): both printed "PASS: no source file is newer than the image".
# A scan that could not look is not a scan that found nothing, and "nothing is newer" is a clearance.
# This is the same defect as the entry-sources clause's empty scan below, reached from the other side -
# there an empty scan named all twenty sources as changed, here it names none - and it gets the same
# answer: assert the distinction rather than assume it. `|| fail` still ends the script *with* a message
# and a non-zero status, which is all the `|| true` was ever for, and `find`'s own stderr is no longer
# discarded so the reason is in the output rather than only in a comment.
#
# The window is narrow and not empty: both roots are resolved from the script's own location
# (`$SCRIPT_DIR=$PWD` after `cd "$(dirname "$0")"`, `$REPO_ROOT=$SCRIPT_DIR/..`, `$SRC_DIR=$REPO_ROOT/src`),
# so the tree's own root is present by construction and what this catches is the other root - a
# relocated or partial tree with no `tools/` - plus anything that removes a root mid-run.
#
# **THE ROOT MOVED WITH THE SOURCES IN THE 2026-09-26 RESTRUCTURE, AND `-maxdepth 1` DID NOT WIDEN.**
# The scan used to be rooted at the script's own directory because the script sat in the directory it
# scanned. The payload's sources are now `src/`, so the root is `$SRC_DIR` and the arguments are
# otherwise unchanged - deliberately, because widening to `-r` would put back exactly the class of
# false refusal the paragraph below is about. What `-maxdepth 1` at `src/` covers is *the same set of
# files* it covered at the old root: all 67 payload `.c` files, the 5 headers, the 3 `.S` and the 2
# `.ld` are flat in `src/`, and none of them moved one level down. The subtrees under `src/` hold
# things `build.sh` does not compile (`entry/` and `supply/` feed the *entry* image, `platform/` feeds
# the host-only compile proof) or things it reaches through `-I` (`shims/`, `shims_arm/`), and their
# mtimes are not a statement about this image for the reason below.
STALE=$(find "$SRC_DIR" -maxdepth 1 -type f \
         \( -name '*.c' -o -name '*.h' -o -name '*.S' -o -name '*.ld' \) \
         -newer "$IMAGE" -printf '%f\n' | sort) \
  || fail "the freshness scan of $SRC_DIR failed rather than finished, so this gate has no answer to \"is a source newer than the image\" - and an empty scan must not be read as \"none is\""
# **533 put the entry image's own sources in this sweep for one commit, and 533 removed them again -
# because an mtime is the wrong measurement for that directory and the refusal it produced was of a
# correct tree.** The entry sources are one directory down and `-maxdepth 1` never looked at them,
# which was true; but comparing their mtimes against the *payload image's* mtime asks about a file
# the payload's build never opens. `build.sh` consumes exactly one thing from `src/entry/` -
# `out/stage90/xnu_arm_entry.bin`, byte-embedded at `build.sh:93` - and mentions `build_entry.sh`
# only in prose, so a newer build script cannot make the payload stale. Measured on the committed
# tree at 4787622, `git status` empty: `build_entry.sh` 17:53:35 against the image it had produced
# at 17:53:15, refused, and the remedy this clause prescribes - rebuild - is the one thing this
# phase cannot do, because a payload rebuild would replace the arm those frozen bytes are, for a
# change in nothing the payload consumes.
#
# **THE REASON WAS WRONG WHEN IT WAS WRITTEN, AND IS CORRECTED HERE (760, 2026-09-27): it said "a
# payload rebuild does not reproduce (408)".** 666 section 5 measured the opposite on three builds -
# two plain builds whose `stage90-qcdt.img` was identical both times, and a rebuild from the tree of
# the parked arm `armed-seam-poc-a43304f2` identical to it in all seven members - and the 48 bytes
# 408 read as nondeterminism are exactly the `STAGE90_XNU_ENTRY` switch (`kernel_size` 6,015,356
# with it against 6,015,308 without). **So what refuses a rebuild here is not reproducibility: it is
# that a rebuild replaces the arm in `out/`, and a payload embeds `xnu_arm_entry.bin`, so once
# `src/` has moved a past arm can no longer be produced from the tree** (666 section 5). **The park
# is affected either way more narrowly than the old sentence implied**: it is bytes on disk outside
# the build path, a rebuild never opens `frozen/`, and reverting to it is a `cp`. "Cost the freeze"
# therefore means *the arm in `out/` stops matching its record*, not *the park is spent*. **A right
# rule carried by a wrong reason is the defect 760 records as m770**, and this comment was its worst
# site, because the sentence sat beside the remedy the clause itself prescribes.
#
# The entry side is now checked where content can be checked instead (the clause "the entry image's
# own sources" below, which reads the manifest `build_entry.sh` writes beside the image), so this
# sweep is back to the payload's own sources - the files `build.sh` actually compiles - and the
# tools that generate what it compiles.
# The generator is named here the same way `build.sh:18` names it (`$REPO_ROOT/tools/mkmacho_fixture.py`,
# the path that build invokes), and this root carries the same `|| fail` as the one above: a missing or
# unreadable `tools/` is a tool that could not be looked at, not a tool that is older than the image.
BUILD_TOOLS_NEWER=$(find "$REPO_ROOT/tools" -maxdepth 1 -name 'mkmacho_fixture.py' \
                    -newer "$IMAGE" -printf '%f\n') \
  || fail "the freshness scan of $REPO_ROOT/tools failed rather than finished, so the generator this gate names against the image was never compared with it - an empty scan is not \"the tool is old enough\""
if [[ -n $STALE || -n $BUILD_TOOLS_NEWER ]]; then
  echo "source newer than the image:"
  # `[[ ... ]] && echo` as a bare statement returns 1 when the test is false, which under `set -e`
  # would leave the script before the `fail` below and print no reason at all. Explicit `if`s.
  if [[ -n $STALE ]]; then echo "$STALE" | sed 's/^/  /'; fi
  if [[ -n $BUILD_TOOLS_NEWER ]]; then echo "  tools/$BUILD_TOOLS_NEWER"; fi
  echo "  (compared against the image's own mtime: $(stat -c '%y' "$IMAGE"))"
  # **"Run ./build.sh" is the wrong remedy about half the time, and for the XNU-entry arm it is the
  # actively harmful one.** Two different events produce this line and the gate cannot tell them apart:
  # an edit that was not rebuilt, and a `git checkout` / mirror that rewrote an *unchanged* file and so
  # bumped its mtime. Measured (2026-09-22): committing 533 and fast-forwarding master left
  # src/entry/build_entry.sh and entry_trace.c at 17:30:27 with `git diff HEAD` empty, two minutes
  # after the 17:28 image they had in fact produced - a false stale, and the safe direction, but the
  # operator's next move is a rebuild and a blind `./build.sh` drops -DSTAGE90_XNU_ENTRY back to the
  # header's default 0, i.e. it rebuilds a payload that never jumps into XNU. Hence the second half of
  # the message: a rebuild only clears this gate for the run the run was for if it carries the switches
  # that run needs.
  #
  # **The entry side of that pair is gone, and this clause is now payload-only; the false-stale
  # hazard is not.** A checkout that bumps a payload source (`stage90_main.c`, `stage90.h`, ...) still
  # reaches this line with the content unchanged, and here the prescribed rebuild is *not* free: a plain
  # `./build.sh` drops the `STAGE90_XNU_ENTRY=1` switch this arm needs and overwrites the armed image in
  # `out/`, so the arm survives only in its park. **763 corrected the reason this comment gave** - it cited
  # 408's "the payload link does not reproduce", and 666 section 5 measured that away on three builds, one
  # of them a parked arm rebuilt from the tree with all seven members identical. That is a decision for the step that takes it - the sound
  # repair is the same one the entry side got, a content manifest over build.sh's own sources - and
  # it is deliberately not being smuggled in with this one. What is *not* being deferred is the case
  # that has actually happened: a false stale produced by a file the payload's build never reads.
  fail "the image is stale - rebuild it, then re-run this gate. If the files above are unchanged (a checkout or a master mirror bumps an unchanged file's mtime), rebuild anyway - the gate compares mtimes and cannot tell an edit from a checkout. Rebuild with the switches the run needs: an XNU-entry run is STAGE90_EXTRA_CFLAGS='-DSTAGE90_XNU_ENTRY=1' ./build.sh (a plain ./build.sh produces a payload that never jumps into XNU)"
fi
echo "no source file is newer than the image"

echo
echo "== the entry image the payload embeds =="
# **The image carries the arm out/stage90/xnu_arm_entry.bin holds, byte for byte** - and until now
# nothing compared the two. The payload does not merely *name* the entry image, it IS it: build.sh
# generates xnu_arm_entry_blob.c from out/stage90/xnu_arm_entry.bin on every payload build and the
# linker puts those bytes in .rodata. So a rebuild of one and not the other leaves an image whose
# manifest verifies, whose build switches are the ones printed above, and whose *arm* is a different
# one from the source's - the single thing the XNU-entry prose further down describes and cannot
# check. Measured (2026-09-22, experiment 533's session): out/stage90/stage90-qcdt.img carried
# 05596cc1... (the 526 arm) at image offset 496100 while out/stage90/xnu_arm_entry.bin was
# f202f246... (the 533 arm) - the same length, 5519996 bytes, so neither the file size nor
# SHA256SUMS.txt betrays it.
#
# **That 496100 is a reading of an image that no longer exists, and the difference between it and
# today's 496148 is itself a reading.** The image measured above was built *without*
# STAGE90_XNU_ENTRY; the one this gate now passes was built with it, and the `#if` block's `bl` plus
# its argument setup is exactly 48 bytes: kernel_size 6015308 -> 6015356 and blob offset 496100 ->
# 496148, so the arm sits 48 bytes later in a payload 48 bytes longer, inside the same-sized image.
# Two consequences worth having. First, **the switch is visible in two numbers of the boot image's own
# header, with no disassembly** - a payload that never jumps has a `kernel_size` 48 bytes smaller than
# one that does, and that is a third way to tell them apart beside the call site and the config dump.
# Second, the flag-on 533 payload and 526's are the same size (6015356) and put the blob at the same
# offset (496148), which is what "533 is 526 minus the idle-cache enable" looks like when it is measured
# by layout rather than asserted. None of it is compared here - the numbers below are computed from
# these files at gate time, and the parenthetical is a date, not an expectation.
#
# Nothing here is written down: not the offset, not a hash of the entry image compared against
# prose. The arithmetic is build.sh's own, read back out of the files it produced - the boot image's
# header carries page_size (build.sh's `--pagesize 2048`) and kernel_addr (its `--kernel_offset
# 0x00008000`), and kernel_size is the size of the stage90.bin it handed to mkbootimg; the payload
# ELF's own symbol table carries where the blob and its size word sit. So four readings are compared
# and no two of them come from the same place: the blob's offset found by searching the bytes, the
# same offset derived from the symbol's address less kernel_addr, the blob's length as the linker
# recorded it, and the length the payload *compiled in* (stage90_xnu_entry_blob_size, which
# build.sh generates from `stat -c%s` of the entry image). That last one is a different reading from
# the byte comparison: a shrunken entry image would still match the blob's prefix, and only the
# payload's own size word would say so.
STAGE90_NM=${STAGE90_NM:-arm-none-eabi-nm}
ENTRY_BIN=$OUT/xnu_arm_entry.bin
PAYLOAD_BIN=$OUT/stage90.bin
PAYLOAD_ELF=$OUT/stage90.elf
[[ -f $ENTRY_BIN   ]] || fail "no $ENTRY_BIN - the payload embeds the entry image; run ./build.sh"
_readable "$ENTRY_BIN" "the blob the payload must carry is read out of it"
[[ -f $PAYLOAD_BIN ]] || fail "no $PAYLOAD_BIN - run ./build.sh"
_readable "$PAYLOAD_BIN" "the blob's offset inside it is searched for in its bytes"
[[ -f $PAYLOAD_ELF ]] || fail "no $PAYLOAD_ELF - run ./build.sh"
_readable "$PAYLOAD_ELF" "the blob's offset and length are read out of its symbol table"
# `set -euo pipefail` is on, so a missing tool would abort the assignment below and leave the script
# *before* the `fail` - a refusal with no reason, which is the same defect as the `[[ ... ]] &&` above.
command -v "$STAGE90_NM" >/dev/null 2>&1 \
  || fail "no '$STAGE90_NM' - the entry blob's offset is read out of the payload's symbol table; install binutils-arm-none-eabi, or set STAGE90_NM"
BLOB_SYM=$("$STAGE90_NM" -S "$PAYLOAD_ELF" 2>/dev/null \
           | awk '$4 == "stage90_xnu_entry_blob" { print $1, $2 }' || true)
BLOB_SIZE_SYM=$("$STAGE90_NM" -S "$PAYLOAD_ELF" 2>/dev/null \
                | awk '$4 == "stage90_xnu_entry_blob_size" { print $1, $2 }' || true)
[[ -n $BLOB_SYM && -n $BLOB_SIZE_SYM ]] \
  || fail "$PAYLOAD_ELF has no stage90_xnu_entry_blob / _size symbol - build.sh generates both from the entry image; rebuild"
BLOB_SIZE_ADDR=$((16#${BLOB_SIZE_SYM%% *}))
BLOB_SIZE_LEN=$((16#${BLOB_SIZE_SYM##* }))
[[ $BLOB_SIZE_LEN -eq 4 ]] \
  || fail "stage90_xnu_entry_blob_size is $BLOB_SIZE_LEN bytes, not 4 - it is not the uint32_t the payload compiled in"
if ! "$PYTHON" - "$IMAGE" "$PAYLOAD_BIN" "$ENTRY_BIN" \
                $((16#${BLOB_SYM%% *})) $((16#${BLOB_SYM##* })) "$BLOB_SIZE_ADDR" <<'PY'
import struct, sys

img_p, payload_p, entry_p = sys.argv[1:4]
blob_va, blob_sym_size, blob_size_va = (int(a, 0) for a in sys.argv[4:7])
img = open(img_p, 'rb').read()
payload = open(payload_p, 'rb').read()
entry = open(entry_p, 'rb').read()

def die(*a):
    sys.stdout.flush()
    print(*a, file=sys.stderr)
    sys.exit(1)

if img[:8] != b'ANDROID!':
    die("%s has no ANDROID! magic - it is not a boot image" % img_p)
# The v0 header, in the order build.sh's mkbootimg invocation fills it in.
ksize, kaddr = struct.unpack_from('<2I', img, 8)
psize, = struct.unpack_from('<I', img, 36)
print("  header: page_size=%d kernel_size=%d kernel_addr=0x%08x" % (psize, ksize, kaddr))
if psize <= 0 or psize + ksize > len(img):
    die("%s: the header's page_size (%d) + kernel_size (%d) runs past the file's %d bytes"
        % (img_p, psize, ksize, len(img)))
kern = img[psize:psize + ksize]
if kern != payload:
    die("%s's kernel section is not %s (%d bytes in the image, %d in the file)"
        % (img_p, payload_p, len(kern), len(payload)))
print("  the image's kernel section is %s, byte for byte (%d bytes)" % (payload_p, ksize))

# The payload's own compiled-in claim about the blob, printed before anything is compared so that a
# refusal below is read beside the length the payload itself believes: it is what catches an entry
# image that shrank instead of changing, which a prefix match cannot see.
size_off = blob_size_va - kaddr
if not 0 <= size_off <= len(payload) - 4:
    die("stage90_xnu_entry_blob_size at file offset %d is outside %s (%d bytes)"
        % (size_off, payload_p, len(payload)))
compiled = struct.unpack_from('<I', payload, size_off)[0]
if compiled != len(entry):
    die("%s compiled in a %d-byte entry blob; %s is %d bytes"
        % (payload_p, compiled, entry_p, len(entry)))
print("  the payload compiled in a %d-byte entry blob, and %s is %d bytes"
      % (compiled, entry_p, len(entry)))

def locate(hay, what):
    """The blob's offset in `hay`, by content: exactly one match, and it must fit whole."""
    o = hay.find(entry)
    if o < 0:
        # Two faults wear one message, and the test between them is made HERE rather than asserted
        # from the length clause above, because that clause is not this function's contract. Equal
        # lengths mean the payload does carry a blob of exactly this size and it belongs to another
        # build - an arm swapped for one of the same length, which is measurable: 151425c4 and
        # 696a0f39 are both 5519996 bytes, so 2026-09-23's swap reached this branch and no length
        # test could see it. Unequal lengths mean there is no blob of the size the payload compiled
        # in. The single wording this replaces stated the second for both, and the first is the case
        # a reader reads backwards: an absent blob is not what is there.
        if compiled == len(entry):
            die("%s does not contain the bytes of %s, while its own compiled-in blob is %d bytes "
                "and this entry image is %d - the lengths agree and the bytes do not, so what it "
                "carries at that length is a DIFFERENT build of the entry image rather than an "
                "absent blob. That is what swapping the arm for another of the same size looks "
                "like, and it is the reading a plain does-not-contain-it message inverts. The two "
                "are told apart by the sha256 of the entry image: rebuild the payload to embed the "
                "image now in out/, or put back the image the payload was built with. Nothing is "
                "rebuilt by this refusal"
                % (what, entry_p, compiled, len(entry)))
        die("%s does not contain %s at all, and its own compiled-in blob is %d bytes against this "
            "entry image's %d, so there is no blob of the size this payload was built with"
            % (what, entry_p, compiled, len(entry)))
    if hay.find(entry, o + 1) >= 0:
        die("%s contains %s more than once" % (what, entry_p))
    if len(hay) - o < len(entry):
        die("%s: only %d bytes follow the blob, of the %d it needs"
            % (what, len(hay) - o, len(entry)))
    return o

p_off = locate(payload, payload_p)
i_off = locate(kern, "the image's kernel section")
if i_off != p_off:
    die("the blob is at kernel-section offset %d in %s and %d in %s"
        % (i_off, img_p, p_off, payload_p))
print("  the blob is %d bytes at payload offset %d = image offset %d (page_size %d + %d)"
      % (len(entry), p_off, psize + i_off, psize, i_off))

# The same offset, from the linker's symbol table rather than from a search.
sym_off = blob_va - kaddr
if sym_off != p_off:
    die("the payload's symbol table puts stage90_xnu_entry_blob at file offset %d, but its bytes are at %d"
        % (sym_off, p_off))
if blob_sym_size != len(entry):
    die("the linker recorded a %d-byte stage90_xnu_entry_blob; %s is %d bytes"
        % (blob_sym_size, entry_p, len(entry)))
print("  the linker's symbol says the blob is %d bytes at %d, which agrees"
      % (blob_sym_size, sym_off))
PY
then
  fail "the image does not carry the arm $ENTRY_BIN holds, byte for byte (see above)"
fi

echo
echo "== the entry image's own switches =="
# **Which arm the entry image is, in its own words, bound to its own bytes.** The clause above proves
# the boot image carries the arm `xnu_arm_entry.bin` holds; it cannot say *which variant* that arm is,
# because the entry side had no record of its switches anywhere - `xnu_arm_entry.h` carries layout
# only, and `stage90-build-config.txt` is the payload's switches, not the entry image's. So a frozen
# `xnu_arm_entry.bin` was identified by hash and by prose, and the variant it was built as (null
# instrument or capture, the D-cache enable or not, the exit flush on or off, the separate interrupt
# stack or not) existed only in whatever command line made it - the same hole as 520's gate printing a
# hash out of a comment literal, one level down and for the other artifact.
#
# `build_entry.sh` now writes `out/xnu_arm_entry-config.txt` at every build, from the variables that
# build actually used, with the sha256 of the bin it produced. This reads it and refuses a record that
# describes a different image, so the three artifacts are chained: image <-> bin (above) and
# bin <-> record (here). Nothing is written down here: the hash compared is the hash of the file in
# front of it, computed at gate time.
ENTRY_CFG=$OUT/xnu_arm_entry-config.txt
[[ -f $ENTRY_CFG ]] \
  || fail "no $ENTRY_CFG - the entry image's switches are recorded there by build_entry.sh, and without it this gate can prove which bytes the image carries but not which arm they are; rebuild the entry image (src/entry/build_entry.sh) and then ./build.sh"
_readable "$ENTRY_CFG" "which arm this image is, and the fourteen switches it was built with, are read out of it"
recorded_sha=$(awk -F= '$1 == "STAGE90_XNU_ENTRY_SHA256" { print $2 }' "$ENTRY_CFG")
[[ -n $recorded_sha ]] \
  || fail "$ENTRY_CFG has no STAGE90_XNU_ENTRY_SHA256 line - a record that names no artifact is a note, not a reading"
actual_sha=$(sha256sum "$ENTRY_BIN" | awk '{ print $1 }')
[[ "$recorded_sha" == "$actual_sha" ]] \
  || fail "$ENTRY_CFG describes entry image $recorded_sha and $ENTRY_BIN is $actual_sha: the record names a different artifact than the one on disk, so the switches it lists are about some other image. Rebuild the entry image, then ./build.sh"
#
# **954: which XNU tree this image is, read from the same record.** The gate's clauses about the
# *tree's* machine (549's `up_style_idle_exit`, 515's token) must know the tree to publish a D13 skip
# instead of failing on a token D13 does not have. It is read out of the hash-bound record rather than
# the environment, so a gate talking about this image's tree cannot be reading a different shell. An
# older record (before 954) has no line: default 0 = 4570, which is what every recorded arm so far is.
_entry_tree_d13=$(awk -F= '$1 == "STAGE90_XNU_TREE_D13" { print $2 }' "$ENTRY_CFG")
[[ -n $_entry_tree_d13 ]] || _entry_tree_d13=0
#
# **The kernel objects this entry image LINKS are built from the XNU tree, and NO OTHER clause in
# this gate looks at that tree (experiment 980).** The freshness sweep above is rooted at `src/`
# (maxdepth 1) and the entry-source manifest covers `src/entry/` by content; `build_entry.sh` merely
# LINKS the prebuilt `out/xnu_kernel_obj_d13/*.o` and never recompiles the tree. So an edit to
# `osfmk/arm/pmap.c` (or `arm_vm_init.c`) that is not rebuilt leaves a stale `.o` the image links,
# while the recorded hash, the manifest, SHA256SUMS.txt and the revert-set record ALL AGREE with each
# other and this gate prints its PASS - the exact blind direction the sweep's own comment (233-238) is
# about, reached through the kernel pool instead of `src/`.
#
# The reading is a CONTENT hash, written by `tools/build_xnu_arm_kernel.sh` (via
# `tools/gen_kernel_source_manifest.py`) over the very source list its compile loop reads, and
# re-hashed here. **An mtime test would refuse a correct arm**: the HFS sources are staged into the
# tree and marked, and a re-provision resets an unchanged file's mtime - measured this session on
# `armed-d13-fa301bd7`, whose `bsd/hfs/hfs_vfsops.c` is newer than its `.o` while both the object and
# the image carry the staged patch.
#
# **A record that does not exist is the historical case, and it is REPORTED, not refused.** The
# press-ready arm `armed-d13-fa301bd7` PREDATES this record (its kernel pool is from 2026-10-10, the
# arm from 2026-10-11); refusing on a missing record would block the press this gate exists to
# clear - without evidence the record's absence is stale-kernel, only "predates the record". Every
# future kernel build writes one, and then a drift is a refusal.
if [[ $_entry_tree_d13 -eq 1 ]]; then
  # The record path is the producer's, derived the same way (the tree suffix comes from the tree's
  # own discriminator, `tools/xnu_tree_roots.sh:38`): `_d13` iff the legacy private header exists.
  _ksr_suffix=""
  [[ -f $REPO_ROOT/external/xnu-hd2-darwin13/xnu/osfmk/sys/types.h ]] && _ksr_suffix=_d13
  KERNEL_SRC_RECORD=$REPO_ROOT/out/xnu_kernel_src${_ksr_suffix}.sha256
  if [[ -f $KERNEL_SRC_RECORD ]]; then
    _ksm=$("$REPO_ROOT/tools/gen_kernel_source_manifest.py" --verify "$KERNEL_SRC_RECORD" 2>&1) && _ksm_rc=0 || _ksm_rc=$?
    if [[ $_ksm_rc -ne 0 ]]; then
      echo "kernel source newer than the pool it was compiled into:"
      printf '%s\n' "$_ksm" | sed 's/^/  /'
      fail "a source this image's kernel objects were built from has CHANGED (or gone) since the pool was compiled, so the linked objects may not be the tree's - rebuild the kernel pool (tools/build_xnu_arm_kernel.sh, which rewrites $KERNEL_SRC_RECORD) and then src/entry/build_entry.sh under this arm. Nothing is rebuilt by this refusal"
    fi
    echo "the kernel sources match the pool they were compiled into ($KERNEL_SRC_RECORD)"
  else
    echo "NOTE: no kernel-source content record at $KERNEL_SRC_RECORD - this arm's pool predates"
    echo "      the record (980), so its objects-vs-tree freshness is NOT checked here. The next"
    echo "      tools/build_xnu_arm_kernel.sh writes one and this gate then refuses on drift."
  fi
fi
#
# **Every key by name, because the ten that *are* the variant are not named like the artifact.** The
# four keys that identify the record (SHA256, BYTES, TRACE, REAL_ARM_INIT) all begin `STAGE90_XNU_ENTRY_`
# or `STAGE90_ENTRY_`, and the ten that say *which arm this is* - SLOT_NULL, EXIT_POC_FLUSH,
# IDLE_CACHE_ENABLE, ISTACK_SEPARATE, IDLE_STACK, SEAM_POC, SEAM_MEASURE, SEAM_END_RUN, POST_END_RUN,
# IDLE_NO_SLEEP - begin `STAGE90_XNU_` and end there. So the obvious
# display filter, `$1 ~ /^STAGE90_(XNU_ENTRY|ENTRY_)/`, prints four lines, drops all ten of the ones
# this clause exists to publish, and **prints no error doing it**: the gate would report success while
# saying nothing about the arm, which is the whole reason the clause was added. Measured on a record
# with the nine keys `build_entry.sh` wrote at the time: 9 in, 4 out.
#
# So the keys are named twice - once to be required, once to be printed - and a record missing one is
# refused rather than shown as a shorter list (`[[ -n $v ]]`, so an empty value is a missing key: an
# `X=` line is not `X=0`, which is [[mi4-off-option-two-spellings]] one register over).
#
# **The list was nine, then twelve, and is now fifteen, and each addition grew it by enumerating rather than
# by reading.** 540 found three
# more switches that shape the linked entry image and were in no record anywhere -
# `STAGE90_ENTRY_CHECKPOINT` and its two variants (`--wrap=<symbol>` plus an extra object in the link,
# `:218`-`:236` and `:27218`) - so `build_entry.sh` records them now and this run needs to *show* them:
# a switch that changes the image and is not printed is a run whose arm nobody read. They are written
# `(unset)` when empty, so the `[[ -n $_v ]]` test above still means "the key is there" - which is the
# whole reason that test is `-n` and not a comparison with zero.
#
# **The thirteenth is 535's, and it arrived from the build side.** `STAGE90_XNU_SEAM_POC` is the switch
# whose arm *is* the interception (`--wrap=FlushPoU_Dcache`) rather than a branch inside one, so it has to
# be named here for the same reason 540's checkpoint trio does: a switch that changes the image and is not
# printed is a run whose arm nobody read. It is also the first key this list gained *before* a record
# carried it - the build side writes it from the next entry build on - so a gate run between this change
# and that build refuses at the clause below, and the refusal names the key. That is the whole of the
# remedy, and it is deliberately not softened: a key that may or may not be there is a key nobody read.
#
# **The fourteenth is 572's, and it is the same seam's other arm.** `STAGE90_XNU_SEAM_MEASURE` turns the
# same interception on (`--wrap=FlushPoU_Dcache`, one wrapper, the same return-address filter) and leaves
# 535's operation out of its body, so the two switches are **one seam's two arms and not two switches**:
# `build_entry.sh` refuses a build with both at 1 and `entry_trace.c` `#error`s on it, which means a record
# carrying both describes an image that cannot exist - so this gate refuses that pair too, rather than
# narrating one of the two arms over it (the clause below is the only place the pair is visible at gate
# time). The pair is also why every sentence here that used to read `SEAM_POC=0` as "no interception" is
# now conditional: what turns the interception on is `SEAM_ON = SEAM_POC | SEAM_MEASURE`, so a 0 on one
# of the two is an arm and not an absence - one value with two definitions, arriving from the build side.
#
# **The fifteenth is 594's, and it is the first one whose arm is the *absence* of a call rather than a
# switch inside one.** `STAGE90_XNU_IDLE_NO_SLEEP` compiles out 514's one repair -
# `cpu_signal_handler_internal(FALSE)`, the single clearing of `SIGPdisabled` on this uniprocessor port -
# so `cpu_idle`'s first test is true on every pass, all three idle wrappers are skipped and the window
# whose `pop {fp, pc}` is this phase's frontier is **never entered** (593 sections 2 and 3: 32767+ passes
# leave by the first door before the repair, and exactly one leaves by the third after it). Two things
# follow for this gate, and the second is why the key must be here rather than in the build's own
# change-detector alone:
#
#   1. **Every family that lives inside that window becomes an expected ABSENCE on this arm** - the four
#      `xnu_live_slot_*` words, the bracket's `pre`/`rtcpre`/`post` counts, the `window`'s near and far end
#      (`cwe_*`), and the whole `xnu_live_seam_*` set, because the seam is a call inside the exit that the
#      arm never reaches. That is the same "absent is not zero" distinction 569 made and 526 named, and it
#      is what the narration below has to say out loud: an operator reading three absent bracket keys as
#      "the death is before the pre note" would be reading a window that never opened as a window that
#      opened and died early - and the *reading* of this arm is a `pop` that is never executed at all.
#   2. **The repair's own clause in `build_entry.sh` pins three numbers to the literal 1** (`:28193`'s
#      reference-kind set, `:28199`'s `R_ARM_CALL` count and `:28267`'s in-`__wrap_poll` count) and 594
#      derives them from this key instead - so the key is not decoration: with it at 1 those clauses expect
#      `R_ARM_JUMP24 ` and 0, and an image where the call is still made is refused by the build before this
#      gate ever sees it. The gate's half is that the key reaches the record at all (see the note at
#      `run_and_capture.sh`'s clauses): a switch the build reads and does not record is a run whose arm
#      nobody read, which is 591's defect one layer out - and there the record is the *only* thing this
#      gate can read, so an unrecorded switch is not even refutable here.
# 683: the sixteenth name, added from the other lane. 678's arm is the first the build records a key this
# gate did not print - `STAGE90_XNU_SEAM_END_RUN`, which `ENTRY_ARM_KEYS` (`build_entry.sh:543`) gained and
# `xnu_arm_entry-config.txt` therefore carries - so the converse clause below refused it and no press could be
# armed for it (measured: exit 1 / 69 lines without, exit 0 / 550 with). This file is the peer lane's; the
# change was made here because that session's owner was unreachable and the press was waiting on one name.
# **The added name weakens nothing**: it is one more key this gate *prints*, so the arm's record is read out
# loud rather than filtered, and no safety clause - the entry-sources manifest, the storage tripwire, the
# identity check - is touched. The two prose counts that named the variant set as eight are corrected in the
# same edit; the `9 in, 4 out` measurement further up is left as the historical record it is.
# 686: the seventeenth name, from the same lane and for the same reason, one arm later.
# `STAGE90_XNU_POST_END_RUN` is 686's ending - the same `entry_seam_end_run` called at the far end of
# `__wrap_platform_cache_idle_exit` instead of inside the seam - and it is a key `ENTRY_ARM_KEYS` gained
# (`build_entry.sh:577`) and the record therefore carries, so without this line the converse clause refuses
# every press of that arm exactly as it refused 678's. The change is the same class as 683's and is recorded
# the same way: **one more name this gate prints, and no clause moved.** The two counts that name the
# `ENTRY_CFG_KEYS` variant subset move from nine to ten again, for the same reason 683 moved them.
# 690: the eighteenth name, and it is the same class again - one more name this gate prints and no clause
# moved. `STAGE90_XNU_POST_END_TICKS` is 690's ending: the *same* `entry_seam_end_run`, called from the same
# site, with a clock behind it instead of a pass count (`ENTRY_ARM_KEYS` gained it and the record therefore
# carries it, exactly as 683's and 686's did). The variant subset counts move from ten to eleven. What a
# reader gets from this key is the one thing the arm's other keys cannot say on their own: with
# `POST_END_RUN` at 0 and `POST_END_TICKS` at a number, the log's `xnu_live_post_t0` /
# `xnu_live_post_elapsed` pair is a *duration* and not a pass count, and the press is read for
# `xnu_live_post_end_calls` rather than for `xnu_live_slot_post_calls`.
# 692: the nineteenth name, and it is the same class a third time - one more name this gate prints and no
# clause moved. `STAGE90_XNU_STORAGE_PROBE` is the storage line's first on-device act: `entry_storage.c`'s
# probe, called from `__wrap_platform_cache_idle_exit` before 690's clock block, installs **one** 1 MB
# section for the eMMC controller's megabyte (`0xF98`, both windows of 531 inside it) and reads six of its
# registers behind a clock-gate interlock read out of a megabyte the image already maps. The variant
# subset counts move from eleven to twelve, and the pair of counts in the converse check below moves with
# them. ~~What this key buys a reader is the one thing the arm's other keys cannot say: with it at 1 the run
# dereferences a device block the image has never touched, and its log carries `xnu_live_storage_*` - and
# with it at 0 the arm is 690's clock arm with an object in the link whose body compiles to nothing.~~
# **[STRUCK 727, and left visible rather than deleted - see the rung-key clause below.]** Those two
# sentences read the key as a **boolean**, which is what it was when 692 wrote them, and it is not one: the
# ladder ran to 12 on 2026-09-26 and the armed record says `STAGE90_XNU_STORAGE_PROBE=12`. So the one
# narration an operator reads to learn what the storage arm will DO to the device said *"the read-only
# probe"* about an arm that issues the driver's own commands and makes 32-bit stores to the controller.
# The sentence was not wrong when written and no clause ever contradicted it - which is exactly why it
# survived eleven rungs: a narration with no check behind it is not refuted by anything, and every build
# that raised the rung raised the record's number while this prose stayed where it was. The repair is not
# a longer sentence here (a restated rung list is a list that goes stale in silence, four times over in
# this file: 683, 686, 690, 692) - it is the clause below, which READS the ladder's bound out of the one
# line the compiler refuses on and refuses a record outside it.
# 713: the twentieth name, and it is the same class a fourth time - one more name this gate PRINTS and no
# clause moved. `STAGE90_XNU_PWR_WAIT_TICKS` is rung 9's bound: the statement `sdhci_set_power` makes
# immediately after the power byte rung 7 writes (`sdhci.c:1371-1372`, `host->ops->check_power_status(host,
# REQ_BUS_ON)`), whose vendor implementation (`sdhci-msm.c:2179-2210`) is a cache read of two driver-side
# fields plus an UNBOUNDED `wait_for_completion`. The arm ports the predicate and replaces the block with a
# bounded tick poll whose end condition is the CONTROLLER's own `CORE_PWRCTL_CTL & BUS_SUCCESS` and not the
# image-side flag - the probe runs inside Apple's cache-off idle-exit window (`SCTLR.C` clear) while the
# client handler may run with the caches on, so a flag written by one can sit in L1/L2 while the other's
# direct read is answered by DRAM. This key is that bound **in ticks of the device's own 19,200,000 Hz
# counter** (`xnu_live_post_cntfrq`); 1920000 is 100 ms. `entry_storage.c` `#error`s outside [1, 19200000]
# and **0 is REFUSED on purpose**, because the no-wait arm is rung 8 and a budget of 0 would make rung 9's
# cells indistinguishable from the rung below it while the record said otherwise. The variant subset counts
# move from twelve to thirteen, and the pair of counts in the converse check below moves with them. What
# this key buys a reader is the one thing the arm's other keys cannot say: with it at a number the run's
# wait has a bound this gate can see, and with it absent the arm's `_wait_*` cells would be read as a
# handshake that either completed or did not, with no way to tell a poll that SPENT its bound from one that
# was never given a budget - which is the shape this project's oldest silent defect has.
# 882: the twenty-first name, and it is the same class a fifth time - one more name this gate PRINTS and no
# clause moved. `STAGE90_XNU_HFS_ROOT_MEDIA` is the HFS+ root arm's switch and it is 862's `STAGE90_XNU_MOUNT`
# taken one step further, so the two are read as a PAIR and neither alone names the arm. With `MOUNT=1` the
# medium answers the OS's reads from the payload's own strategy at disk 0; with `HFS_ROOT_MEDIA=1` the SAME
# disk 0 answers TWO readers with different bytes - `DKIOCGETMEMDEVINFO` and the `spec_open` block count keep
# the Mach-O (`g_stage90_ramdisk`), so a failed HFS mount's mockfs fall-through still reaches an exec, while
# `st_media_strategy` serves the HFS+ volume (`g_stage90_root_hfs`). With it at 0 the split is absent and
# mockfs keeps the Mach-O on both paths. **A record without this key would let a run go out with the volume
# mapped where the exec image was expected, which is the one failure this arm was built to avoid and the only
# one its own log could not distinguish afterwards** - the two arms' `xnu_live_storage_*` cells agree. The
# variant subset counts move from fourteen to fifteen, and the pair of counts in the converse check below
# moves with them.
ENTRY_CFG_KEYS=(STAGE90_XNU_ENTRY_SHA256 STAGE90_XNU_ENTRY_BYTES STAGE90_ENTRY_TRACE
                STAGE90_ENTRY_REAL_ARM_INIT STAGE90_XNU_SLOT_NULL STAGE90_XNU_EXIT_POC_FLUSH
                STAGE90_XNU_IDLE_CACHE_ENABLE STAGE90_XNU_ISTACK_SEPARATE STAGE90_XNU_IDLE_STACK
                STAGE90_XNU_SEAM_POC STAGE90_XNU_SEAM_MEASURE STAGE90_XNU_SEAM_END_RUN
                STAGE90_XNU_POST_END_RUN STAGE90_XNU_POST_END_TICKS STAGE90_XNU_STORAGE_PROBE
                STAGE90_XNU_PWR_WAIT_TICKS STAGE90_XNU_MOUNT STAGE90_XNU_HFS_ROOT_MEDIA
                STAGE90_XNU_EMMC_STRATEGY STAGE90_XNU_ROOT_FROM_CARD STAGE90_XNU_HDD_WRITE
                STAGE90_XNU_HFS_ROOT_RW STAGE90_XNU_CARD_TOTAL STAGE90_XNU_FULL_EXTENT STAGE90_XNU_CARD_COW STAGE90_XNU_RESIDENT
                STAGE90_ENTRY_CHECKPOINT STAGE90_ENTRY_CHECKPOINT_SKIP
                STAGE90_ENTRY_CHECKPOINT_AFTER STAGE90_XNU_IDLE_NO_SLEEP
                STAGE90_XNU_USB_PROBE
                STAGE90_XNU_USB_DEV
                STAGE90_XNU_USB_DEV_FORCE
                STAGE90_XNU_USB_ENUM
                STAGE90_XNU_USB_STREAM
                STAGE90_XNU_SMEM_PROBE
                STAGE90_XNU_MEM_SIZE_MAX
                STAGE90_XNU_MEM_TOTAL
                STAGE90_XNU_ENTRY_WINDOW
                STAGE90_XNU_TREE_D13
                STAGE90_XNU_KEXTB_LOGIN
                STAGE90_XNU_SP_ALIGN
                STAGE90_XNU_VMHINT_GUARD
                STAGE90_XNU_COMMPAGE_ALIAS
                STAGE90_XNU_IOS7_TRAPS
                STAGE90_XNU_DYLD_WITNESS
                STAGE90_XNU_SHREG_PROBE
                STAGE90_XNU_SHREG_WIRE
                STAGE90_XNU_SHREG_GEOM
                STAGE90_XNU_USVC
                STAGE90_XNU_SUBMAP_PMAP_SKIP
                STAGE90_XNU_STALL
                STAGE90_XNU_ABORT_TRACE
                STAGE90_XNU_CADENCE
                STAGE90_XNU_FREEZE_WITNESS
                STAGE90_XNU_ABT_SPAN
                STAGE90_XNU_ABT_FAR
                STAGE90_XNU_ABT_PC
                STAGE90_XNU_ABT_PTE
                STAGE90_XNU_VME_PROT
                STAGE90_XNU_PMP_ENTER
                STAGE90_XNU_WRSTRIP
                STAGE90_XNU_PTE_WITNESS
                STAGE90_XNU_FLUSH_WITNESS
                STAGE90_XNU_PERM_WITNESS
                STAGE90_XNU_UNDEF_DIRECT
                STAGE90_XNU_UNDEF_RAISE
                STAGE90_XNU_GENERAL_REGS
                STAGE90_XNU_VM_MAX_SPLIT
                STAGE90_XNU_USTACK_PROBE
                STAGE90_XNU_ABT_ENTRY_PROBE
                STAGE90_XNU_H2_STACK_HEADROOM
                STAGE90_XNU_READER_PROBE
                STAGE90_XNU_WRITER_PROBE
                STAGE90_XNU_CALLER_PROBE)
# **1024: `STAGE90_XNU_VM_MAX_SPLIT`, the task map's ceiling (`VM_MAX_ADDRESS`).** It went in at the
# tail after `STAGE90_XNU_GENERAL_REGS`; like every key above it is a REQUIRED key whose value is
# printed by name, and the CONVERSE check below now accepts it. A record that does not carry it is a
# pre-1024 arm and is handled by its own grace branch in the loop (see the `-z` arm beside
# `STAGE90_XNU_GENERAL_REGS`'s): every arm parked before 1024 was built with the tree's `#else`
# ceiling 0x80000000 (`vm_param.h:63`), the only value a pre-1024 build could have written.
# **1015: `STAGE90_XNU_PERM_WITNESS`, the permission-inputs witness (the passive half of rung 1015).**
# It went in at the tail beside `STAGE90_XNU_FLUSH_WITNESS`, and the "variant subset / pair of counts"
# arithmetic the 882/683/686 notes above describe was **already retired by 1005** - the counts they name
# were a *pair* of numbers in the converse check, and 1005 dropped them in favour of comparing the whole
# sorted key set both ways. So this addition moves **no count**: the converse check below is a set
# difference, and both sides grew by exactly this one name. It is a REQUIRED key and an unconditional
# one, exactly like `STAGE90_XNU_FLUSH_WITNESS` beside it: `build_entry.sh` validates the switch at its
# own assignment (0/1 only) and echoes the line *unconditionally*, so every record this gate can see that
# was produced by a build at or after 1015 carries it. (An arm parked BEFORE 1015 - `armed-d13-29ec9e48`
# is the last - does NOT, and this gate would refuse it; that is the intended behaviour here, because
# those arms are retired and a build at this HEAD always writes the line. The 882/594/1003/1004 `-z`
# grace branches above exist only for records the ladder still owes a press.) The value is printed by the
# loop below like every other name in this list, and an off value (0) is a valid arm.
# **1018: `STAGE90_XNU_UNDEF_DIRECT`, the undefined-instruction witness's CHANNEL.** It goes in at the
# tail beside the other two witnesses, and it is the same unconditional key they are: `build_entry.sh`
# validates it at its own assignment (0/1 only) and the writer emits the line unconditionally, so every
# record produced by a build at this HEAD carries it and the 1017/1018-era parks do not (an arm parked
# before 1018 is refused here, which is intended - those arms are retired). What the key buys the gate's
# reader is the one thing the run's own cells cannot say for themselves: with it at 1 the
# `xnu_live_undef_*` keys ride `entry_write_kv`, the UNCAPPED channel, so their absence after
# `xnu_live_capped` means the `udf` did not happen; with it at 0 they ride `entry_live_write` and the cap
# can drop them - which is exactly how `records/1018-recon.txt` read a real `udf #254` as no `udf` at
# all (capture `:29963` published `xnu_live_capped`, the recorder writes nothing after, and the frontier
# sits ~4000 records later). The converse check below is a set difference and moves no count, so this
# addition moves no number either.
# **`STAGE90_XNU_HFS_ROOT_MEDIA` IS A REQUIRED KEY ONLY FOR THE ENTRY IMAGE THAT CARRIES THAT ARM.** 882
# added it above as an unconditional requirement, and that made every arm parked BEFORE 882's build
# UNPRESSABLE: their records were written when the key did not exist, so `awk` returns empty and this
# gate refused the rung-58 arm `armed-storage-b00b87bb` (recorded 05:24, before 882's 13:14) on a key its
# build could not have written. 882's own "nothing moved that must not move" section missed it because it
# checked only 882's live arm and never re-ran the gate against an older park - and the press this blocks
# is exactly the one 867 section 3.1 names as the unblocker for the eMMC-driver clause. The honest rule is
# grounded on the ARTIFACT and not on the calendar: the entry image carries `entry_root_media_hfs_root_arm_on`
# / `..._off` UNCONDITIONALLY (882 section 8), so this gate asks the entry ELF which arm it is rather than
# guessing from a date. An image that carries the HFS root arm MUST record the key - a record without it
# could send a run with the volume mapped where the exec image was expected, 882's one unloseable failure,
# and the two arms' `xnu_live_storage_*` cells would not tell them apart afterwards. An image that CANNOT
# carry the arm has no such value to record, and demanding one would refuse a correct record. The key stays
# in `ENTRY_CFG_KEYS` above, so the CONVERSE check below still ACCEPTS a post-882 record that carries it.
_entry_hfs_arm=""
if [[ -r $OUT/xnu_arm_entry.elf ]] && "$STAGE90_NM" "$OUT/xnu_arm_entry.elf" 2>/dev/null \
     | grep -q 'entry_root_media_hfs_root_arm_on'; then
  _entry_hfs_arm=on
fi
# **903: `STAGE90_XNU_ROOT_FROM_CARD` gets the same ARTIFACT-grounded treatment as HFS_ROOT_MEDIA.** A
# record written before 903 cannot carry the key, and demanding it would make every pre-903 park
# unpressable (882's own defect). The entry image carries `entry_root_media_cardroot_arm_on` / `..._off`
# unconditionally, so the ELF says whether the key is owed; an image that carries the card-root arm MUST
# record it (a record without it could send a run whose root device nobody named), and one that cannot
# carry the arm has no such value to record.
_entry_cardroot_arm=""
if [[ -r $OUT/xnu_arm_entry.elf ]] && "$STAGE90_NM" "$OUT/xnu_arm_entry.elf" 2>/dev/null \
     | grep -q 'entry_root_media_cardroot_arm_on'; then
  _entry_cardroot_arm=on
fi
# **905: `STAGE90_XNU_HDD_WRITE` gets the same ARTIFACT-grounded treatment as the two above.** A record
# written before 905 cannot carry the key, and demanding it would make every pre-905 park unpressable
# (882's own defect, twice repaired). The entry image carries `entry_root_media_write_arm_on` / `..._off`
# UNCONDITIONALLY, so the ELF says whether the key is owed; an image that carries the write arm MUST
# record it - a record without it could send a run whose strategy refuses or serves writes nobody named -
# and one that cannot carry the arm has no such value to record.
_entry_write_arm=""
if [[ -r $OUT/xnu_arm_entry.elf ]] && "$STAGE90_NM" "$OUT/xnu_arm_entry.elf" 2>/dev/null \
     | grep -q 'entry_root_media_write_arm_on'; then
  _entry_write_arm=on
fi
# **905 B2: `STAGE90_XNU_HFS_ROOT_RW` - the rw-root clear - gets the same ARTIFACT-grounded treatment.** A
# record written before 905 cannot carry the key, and demanding it would make every pre-905 park
# unpressable (882's own defect, thrice repaired). The entry image carries the write arm's marker
# `entry_root_media_write_arm_on` / `..._off` UNCONDITIONALLY (905 section 8), and the rw clear is the
# write arm's other half - so an image that carries the write arm MUST record this key (a record without
# it could send a run whose root mounts read-only while the record names a write arm), and one that
# cannot carry the arm has no such value to record.
_entry_root_rw=""
if [[ -r $OUT/xnu_arm_entry.elf ]] && "$STAGE90_NM" "$OUT/xnu_arm_entry.elf" 2>/dev/null \
     | grep -q 'entry_root_media_write_arm_on'; then
  _entry_root_rw=on
fi
# **909: `STAGE90_XNU_RESIDENT` gets the same ARTIFACT-grounded treatment as the four above.** A record
# written before 909 cannot carry the key, and demanding it would make every pre-909 park unpressable
# (882's own defect, four times repaired). The marker is grounded on the ARTIFACT and not on the
# calendar: the resident arm's pet is its own function `entry_wdt_pet`, compiled ONLY under
# `#if STAGE90_XNU_RESIDENT` (909 step 3, entry_trace.c) and asserted ABSENT when the switch is 0 by the
# build's own linked clause - so an entry ELF that DEFINES `entry_wdt_pet` (a `t`) is the residence arm
# and MUST record the key (a record without it could send a run whose deliberate ending nobody named, or
# whose watchdog pet nobody named), while an image that cannot carry the pet has no such value to record.
_entry_resident_arm=""
if [[ -r $OUT/xnu_arm_entry.elf ]] && "$STAGE90_NM" "$OUT/xnu_arm_entry.elf" 2>/dev/null \
     | awk '$3 == "entry_wdt_pet" && $2 == "t" { found = 1 } END { exit(found ? 0 : 1) }'; then
  _entry_resident_arm=on
fi
# **911d: `STAGE90_XNU_CARD_TOTAL` gets the same ARTIFACT-grounded treatment as the five above.** A record
# written before 911d cannot carry the key, and demanding it would make every pre-911d park unpressable
# (882's own defect, five times repaired). The entry image carries the marker
# `entry_root_media_card_total_arm_on` / `..._off` UNCONDITIONALLY (the module defines exactly one), so the
# ELF says whether the key is owed; an image that carries the raw whole-card unit MUST record it - a record
# without it could send a run that registers a fourth device nobody named - and one that cannot carry the
# arm has no such value to record.
_entry_card_total_arm=""
if [[ -r $OUT/xnu_arm_entry.elf ]] && "$STAGE90_NM" "$OUT/xnu_arm_entry.elf" 2>/dev/null \
     | grep -q 'entry_root_media_card_total_arm_on'; then
  _entry_card_total_arm=on
fi
# **965c: `STAGE90_XNU_FULL_EXTENT` is grounded the same way, and its marker is PRESENCE-ONLY.** The
# module defines `entry_root_media_full_extent_arm_on` only under the switch (there is no `_off`
# function, so the parked 512 KiB arm's image keeps its `b9c224c0` hash - a new unconditional marker
# would move it with no `--gc-sections` in the link). So the ELF carries the symbol iff the image's card
# unit bounds the whole partition; an image that carries it MUST record the key, and one that cannot
# (every pre-965c park, which bounded its 512 KiB fixture in 32 bits without harm) has no value to
# record - the N/A branch. This is the same grounded shape as CARD_TOTAL above, with presence standing
# in for the `_on`/`_off` pair.
_entry_full_extent_arm=""
if [[ -r $OUT/xnu_arm_entry.elf ]] && "$STAGE90_NM" "$OUT/xnu_arm_entry.elf" 2>/dev/null \
     | grep -q 'entry_root_media_full_extent_arm_on'; then
  _entry_full_extent_arm=on
fi
# **968: `STAGE90_XNU_CARD_COW` gets the same ARTIFACT-grounded treatment, and its marker is
# PRESENCE-ONLY for 965c's reason** (the module defines `entry_root_media_card_cow_arm_on` only under the
# switch, so a new unconditional `_off` marker would move the parked arms' image hashes with no
# `--gc-sections` in the link). An entry image that carries the COW marker MUST record the key - a record
# without it could send a run whose writable-root mechanism nobody named - and one that cannot (every
# pre-968 park, which served the card read-only) has no value to record: the N/A branch.
_entry_card_cow_arm=""
if [[ -r $OUT/xnu_arm_entry.elf ]] && "$STAGE90_NM" "$OUT/xnu_arm_entry.elf" 2>/dev/null \
     | grep -q 'entry_root_media_card_cow_arm_on'; then
  _entry_card_cow_arm=on
fi
for _k in "${ENTRY_CFG_KEYS[@]}"
do
  _v=$(awk -F= -v k="$_k" '$1 == k { print $2 }' "$ENTRY_CFG")
  if [[ -z $_v && $_k == STAGE90_XNU_HFS_ROOT_MEDIA && -z $_entry_hfs_arm ]]; then
    printf '  %s=(absent, and this entry image carries no HFS root arm to name - the key is N/A here)\n' "$_k"
    continue
  fi
  if [[ -z $_v && $_k == STAGE90_XNU_ROOT_FROM_CARD && -z $_entry_cardroot_arm ]]; then
    printf '  %s=(absent, and this entry image carries no card-root arm to name - the key is N/A here)\n' "$_k"
    continue
  fi
  if [[ -z $_v && $_k == STAGE90_XNU_HDD_WRITE && -z $_entry_write_arm ]]; then
    printf '  %s=(absent, and this entry image carries no eMMC-write arm to name - the key is N/A here)\n' "$_k"
    continue
  fi
  if [[ -z $_v && $_k == STAGE90_XNU_HFS_ROOT_RW && -z $_entry_root_rw ]]; then
    printf '  %s=(absent, and this entry image carries no eMMC-write arm whose rw clear it would name - the key is N/A here)\n' "$_k"
    continue
  fi
  if [[ -z $_v && $_k == STAGE90_XNU_RESIDENT && -z $_entry_resident_arm ]]; then
    printf '  %s=(absent, and this entry image carries no residence pet to name - the key is N/A here)\n' "$_k"
    continue
  fi
  if [[ -z $_v && $_k == STAGE90_XNU_CARD_TOTAL && -z $_entry_card_total_arm ]]; then
    printf '  %s=(absent, and this entry image carries no raw whole-card unit to name - the key is N/A here)\n' "$_k"
    continue
  fi
  if [[ -z $_v && $_k == STAGE90_XNU_FULL_EXTENT && -z $_entry_full_extent_arm ]]; then
    printf '  %s=(absent, and this entry image carries no full-extent arm to name - the key is N/A here)\n' "$_k"
    continue
  fi
  if [[ -z $_v && $_k == STAGE90_XNU_CARD_COW && -z $_entry_card_cow_arm ]]; then
    printf '  %s=(absent, and this entry image carries no RAM copy-on-write writable-root arm to name - the key is N/A here)\n' "$_k"
    continue
  fi
  # **912's window: absent names the 16 MB arm, because that is the ONLY value any pre-912 record could
  # have carried.** `STAGE90_XNU_ENTRY_WINDOW` reached the record only in 912; every arm parked before it
  # - and every owed press among them (`cabba670`, `b3fbcd31`, `979ded08`, `6deae815`) - was built with
  # the fixed 16 MB floor this key now defaults to, so an absent key is not a missing value but the value.
  # Unlike the conditional keys above this is NOT read off the entry ELF: the window is the one arm
  # parameter that shapes the PAYLOAD and not the entry image (the entry bin is byte-identical across
  # 16 MB and 64 MB - `build_entry.sh`'s own note), so no symbol in the entry ELF could report it, and
  # the default is what the absent case MEANS rather than a guess. A post-912 record can never reach this
  # branch: `build_entry.sh`'s 678 two-way check refuses a record whose arm-key list omits the key.
  if [[ -z $_v && $_k == STAGE90_XNU_ENTRY_WINDOW ]]; then
    printf '  %s=(absent, and a record that does not name the window is the 16 MB arm - the only value any pre-912 build could have written)\n' "$_k"
    continue
  fi
  # **911b's ceiling: absent names Apple's 1 GiB clamp.** Every arm parked before 911b (`cabba670`,
  # `b3fbcd31`, `979ded08`, `6deae815`, the window arms `aff86051`/`605a43c2`/`0d3591fe`) was built with
  # `MEM_SIZE_MAX` undefined - the patcher's guard had not been added - so an absent key is not a missing
  # value but the value. A post-911b record can never reach this branch: `build_entry.sh`'s 678 two-way
  # check refuses a record whose arm-key list omits the key, and the writer emits `(unset)` for the
  # default, which is a non-empty value. This is the same one-way rule as ENTRY_WINDOW, for the same
  # reason: demanding the key would make every pre-911b park unpressable (882's own defect, six times
  # repaired), and the ladder still owes those presses.
  if [[ -z $_v && $_k == STAGE90_XNU_MEM_SIZE_MAX ]]; then
    printf '  %s=(absent, and a record that does not name the ceiling is Apple\x27s 1 GiB clamp - the only value any pre-911b build could have written)\n' "$_k"
    continue
  fi
  # **911c's key, the same one-way rule as 911b's ceiling and 912's window, and for the same reason.**
  # Every arm parked before 911c was built with `entry_smem.c` not in the tree at all, so its record has
  # no `STAGE90_XNU_SMEM_PROBE` line; an absent key is not a missing value but the value - the probe was
  # off, because it did not exist. Demanding the key would make every existing park unpressable (882's
  # own defect, seven times repaired now) and the ladder still owes those presses. A post-911c record can
  # never reach this branch: the writer emits the line unconditionally (value 0 or 1), so a record this
  # build made carries a non-empty value and the branch above does not fire for it.
  if [[ -z $_v && $_k == STAGE90_XNU_SMEM_PROBE ]]; then
    printf '  %s=(absent, and a record that does not name the SMEM probe is one built before entry_smem.c existed - the probe was off, the only value a pre-911c build could have written)\n' "$_k"
    continue
  fi
  # **954's tree key, the same one-way rule as 911b/911c/912, and for the same reason.** 954 is the first
  # build to write `STAGE90_XNU_TREE_D13`; every arm parked before it was built against 4570 (the D13 line
  # had no press yet), so its record has no line, and an absent key is not a missing value but the value -
  # 4570, the only tree any pre-954 build could have selected. Demanding the key would make every existing
  # park unpressable (882's own defect, eight times repaired now), and those presses are still owed. A
  # post-954 record can never reach this branch: `build_entry.sh`'s 678 two-way check refuses a record
  # whose arm-key list omits the key, and the writer emits the line unconditionally (0 or 1).
  if [[ -z $_v && $_k == STAGE90_XNU_TREE_D13 ]]; then
    printf '  %s=(absent, and a record that does not name the tree is one built before 954 - the 4570 tree, the only value any pre-954 build could have selected)\n' "$_k"
    continue
  fi
  # **958's total, the same one-way rule as 911b/911c/912/954, and for the same reason.** Every arm
  # parked before 958 was built with `tools/patch_d13_memory_total.py`'s guard undefined, so its record
  # has no `STAGE90_XNU_MEM_TOTAL` line; an absent key is not a missing value but the value - the switch
  # was off, because it did not exist. Demanding the key would make every existing park unpressable
  # (882's own defect, nine times repaired now), and the ladder still owes those presses. A post-958
  # record can never reach this branch: the writer emits the line unconditionally (0 or 1), so a record
  # this build made carries a non-empty value and the branch above does not fire for it.
  if [[ -z $_v && $_k == STAGE90_XNU_MEM_TOTAL ]]; then
    printf '  %s=(absent, and a record that does not name the memory total is one built before 958 - the switch was off, the only value a pre-958 build could have written)\n' "$_k"
    continue
  fi
  # **988's switch, the same one-way rule as 911b/911c/912/954/958, and for the same reason.** Every arm
  # parked before 988 was built with the kext-bootstrap guard not in the tree at all, so its record has no
  # `STAGE90_XNU_KEXTB_LOGIN` line; an absent key is not a missing value but the value - the switch was
  # off, because it did not exist, so the `__LINKEDIT` dereference was compiled in, which is exactly the
  # fault 987's press stopped on. Demanding the key would make every existing park unpressable (882's own
  # defect, ten times repaired now), and the ladder still owes those presses. Unlike HFS_ROOT_MEDIA /
  # ROOT_FROM_CARD / HDD_WRITE / CARD_COW there is no entry-ELF marker to ground this on: the switch is a
  # POOL switch (it compiles the teardown out of `OSKext.cpp`), and a new unconditional `_off` marker
  # would move the parked arms' image hashes with no `--gc-sections` in the link (965c's reason). A
  # post-988 record can never reach this branch: `build_entry.sh`'s 678 two-way check refuses a record
  # whose arm-key list omits the key, and the writer emits the line unconditionally (0 or 1), so a record
  # this build made carries a non-empty value and the branch above does not fire for it.
  if [[ -z $_v && $_k == STAGE90_XNU_KEXTB_LOGIN ]]; then
    printf '  %s=(absent, and a record that does not name the kext-bootstrap guard is one built before 988 - the teardown was compiled in, the only value a pre-988 build could have written)\n' "$_k"
    continue
  fi
  # **990's switch, the same one-way rule as 911b/911c/912/954/958/988, and for the same reason.** Every arm
  # parked before 990 was built with the SP-alignment patch not in the tree at all, so its record has no
  # `STAGE90_XNU_SP_ALIGN` line; an absent key is not a missing value but the value - the switch was off,
  # because it did not exist, so the D13 tree handed C stacks at 4 (mod 8), which is exactly the fault
  # 989's press stopped on (an alignment fault at `parse_machfile+0x60c`, `vld1.32 {d18}, [r1 :64]`,
  # sp = 0xcfdbba7c). Demanding the key would make every existing park unpressable (882's own defect,
  # eleven times repaired now), and the ladder still owes those presses. Unlike HFS_ROOT_MEDIA /
  # ROOT_FROM_CARD / HDD_WRITE / CARD_COW there is no entry-ELF marker to ground this on: the switch moves
  # a POOL object (`pcb.c`) and the ASSEMBLY layer (`machine_routines_asm.s`), and a new unconditional
  # `_off` marker would move the parked arms' image hashes with no `--gc-sections` in the link (965c's
  # reason). A post-990 record can never reach this branch: `build_entry.sh`'s 678 two-way check refuses a
  # record whose arm-key list omits the key, and the writer emits the line unconditionally (0 or 1), so a
  # record this build made carries a non-empty value and the branch above does not fire for it.
  if [[ -z $_v && $_k == STAGE90_XNU_SP_ALIGN ]]; then
    printf '  %s=(absent, and a record that does not name the SP-alignment switch is one built before 990 - the tree handed C 4-mod-8 stacks, the only value a pre-990 build could have written)\n' "$_k"
    continue
  fi
  # **991's switch, the same one-way rule as 911b/911c/912/954/958/988/990, and for the same reason.**
  # Every arm parked before 991 was built with the memq_hint guard not in the tree at all, so its
  # record has no `STAGE90_XNU_VMHINT_GUARD` line; an absent key is not a missing value but the value -
  # the switch was off, because it did not exist, so `vm_page_lookup` dispatched a clobbered
  # `object->memq_hint` (0x1) straight into `ldrd r0,[r5,#24]` - exactly the fault 990's press stopped
  # on (pc=0x80020838, object = 0xc0005b48, lr = vm_map_pmap_enter, far = 0x19). Demanding the key
  # would make every existing park unpressable (882's own defect, twelve times repaired now), and the
  # ladder still owes those presses. Unlike HFS_ROOT_MEDIA / ROOT_FROM_CARD / HDD_WRITE / CARD_COW
  # there is no entry-ELF marker to ground this on: the switch is a POOL switch (`vm_resident.c`), and
  # a new unconditional `_off` marker would move the parked arms' image hashes with no `--gc-sections`
  # in the link (965c's reason). A post-991 record can never reach this branch: `build_entry.sh`'s 678
  # two-way check refuses a record whose arm-key list omits the key, and the writer emits the line
  # unconditionally (0 or 1), so a record this build made carries a non-empty value and the branch
  # above does not fire for it.
  if [[ -z $_v && $_k == STAGE90_XNU_VMHINT_GUARD ]]; then
    printf '  %s=(absent, and a record that does not name the memq_hint guard is one built before 991 - vm_page_lookup dispatched the clobbered hint, the only value a pre-991 build could have written)\n' "$_k"
    continue
  fi
  # **992's switch, the same one-way rule as 911b/911c/912/954/958/988/990/991, and for the same
  # reason.** Every arm parked before 992 was built with the IOS7LAB commpage-alias gates closed (the
  # switch did not exist), so its record has no `STAGE90_XNU_COMMPAGE_ALIAS` line; an absent key is not
  # a missing value but the value - the switch was off, because it did not exist, so the commpage was
  # mapped only at the tree's control-ABI address 0x40000000 while real iOS 7 userspace read
  # 0xffff4000 - exactly the translation fault 991's press stopped on (launchd[1] usermode data abort
  # at 0xffff4090, map 0xc00057b8). Demanding the key would make every existing park unpressable
  # (882's own defect, thirteen times repaired now), and the ladder still owes those presses. Unlike
  # HFS_ROOT_MEDIA / ROOT_FROM_CARD / HDD_WRITE / CARD_COW there is no entry-ELF marker to ground this
  # on: the switch is a POOL switch (`pmap.c` + `commpage.c`), and a new unconditional `_off` marker
  # would move the parked arms' image hashes with no `--gc-sections` in the link (965c's reason). A
  # post-992 record can never reach this branch: `build_entry.sh`'s two-way check refuses a record
  # whose arm-key list omits the key, and the writer emits the line unconditionally (0 or 1), so a
  # record this build made carries a non-empty value and the branch above does not fire for it.
  if [[ -z $_v && $_k == STAGE90_XNU_COMMPAGE_ALIAS ]]; then
    printf '  %s=(absent, and a record that does not name the commpage alias is one built before 992 - userspace read the iOS 7 commpage through an unmapped 0xffff4000, the only value a pre-992 build could have written)\n' "$_k"
    continue
  fi
  # **994's switch, the same one-way rule as 911b/911c/912/954/958/988/990/991/992, and for the same
  # reason.** Every arm parked before 994 was built with the IOS7LAB trap gates closed and the -3 SWI
  # fast return compiled in (the switch did not exist), so its record has no `STAGE90_XNU_IOS7_TRAPS`
  # line; an absent key is not a missing value but the value - the switch was off, because it did not
  # exist, so `mach_trap_table` entries 15/24/25/41/42 were `kern_invalid`, the trap-10 wire was read
  # as FOUR words (its `args->flags` the size's high half, 0), and userspace's `mach_absolute_time`
  # SWI (r12 == -3) returned r0 = 0 / r1 = stale through `swi_trap_tb: movs pc, lr` - exactly the
  # silent state 993's press stopped on (dyld's own deliberate halt, `udf #0xdefe` at 0x2be7e0c4,
  # reached from `dyld::throwf`'s out-of-memory path). Demanding the key would make every existing park
  # unpressable (882's own defect, fourteen times repaired now), and the ladder still owes those
  # presses. Unlike HFS_ROOT_MEDIA / ROOT_FROM_CARD / HDD_WRITE / CARD_COW there is no entry-ELF marker
  # to ground this on: the switch moves POOL objects (`mach_kernelrpc.c`, `ios7_compat.h`) and the
  # ASSEMBLY layer (`traps_lo.s`), and a new unconditional `_off` marker would move the parked arms'
  # image hashes with no `--gc-sections` in the link (965c's reason). A post-994 record can never reach
  # this branch: `build_entry.sh`'s two-way check refuses a record whose arm-key list omits the key, and
  # the writer emits the line unconditionally (0 or 1), so a record this build made carries a non-empty
  # value and the branch above does not fire for it.
  if [[ -z $_v && $_k == STAGE90_XNU_IOS7_TRAPS ]]; then
    printf '  %s=(absent, and a record that does not name the iOS 7 trap wire is one built before 994 - the mach traps were kern_invalid and the -3 SWI returned r0=0, the only value a pre-994 build could have written)\n' "$_k"
    continue
  fi
  # **995's switch, the same one-way rule as 911b/911c/912/954/958/988/990/991/992/994, and for the
  # same reason.** Every arm parked before 995 was built with the dyld witness compiled out (the switch
  # did not exist), so its record has no `STAGE90_XNU_DYLD_WITNESS` line; an absent key is not a missing
  # value but the value - the switch was off, because it did not exist, so `osfmk/arm/trap.c`'s
  # `sleh_undef` never called `ios7wit_dyld_message` and the halt message dyld formatted before its
  # fatal `udf #0xdefe` went to the console as nothing at all - exactly the silence 994's press stopped
  # on (235 identical `usermode undefined instruction ... at 0x2beb90c4` dumps and no text naming the
  # real dyld error). Demanding the key would make every existing park unpressable (882's own defect,
  # fifteen times repaired now), and the ladder still owes those presses. Unlike HFS_ROOT_MEDIA /
  # ROOT_FROM_CARD / HDD_WRITE / CARD_COW there is no entry-ELF marker to ground this on: the switch
  # moves ONE pool object (`osfmk/arm/trap.c`), and a new unconditional `_off` marker in the entry
  # image would move the parked arms' image hashes with no `--gc-sections` in the link (965c's reason).
  # A post-995 record can never reach this branch: `build_entry.sh`'s two-way check refuses a record
  # whose arm-key list omits the key, and the writer emits the line unconditionally (0 or 1), so a
  # record this build made carries a non-empty value and the branch above does not fire for it.
  if [[ -z $_v && $_k == STAGE90_XNU_DYLD_WITNESS ]]; then
    printf '  %s=(absent, and a record that does not name the dyld witness is one built before 995 - no reader was compiled into the sleh_undef udf path, the only value a pre-995 build could have written)\n' "$_k"
    continue
  fi
  # **996's switch, the same one-way rule as 911b/911c/912/954/958/988/990/991/992/994/995, and for
  # the same reason.** Every arm parked before 996 was built with the shared-region probe compiled out
  # (the switch did not exist), so its record has no `STAGE90_XNU_SHREG_PROBE` line; an absent key is
  # not a missing value but the value - the switch was off, because it did not exist, so
  # `bsd/vm/vm_unix.c`'s `shared_region_check_np` / `shared_region_map_and_slide_np` /
  # `_shared_region_map` printed no `IOS7SHREG` lines and the runtime returns of the two syscalls dyld's
  # `mapSharedCache` depends on stayed unmeasured - exactly the unknown 995's read left on the frontier
  # (dyld halted on `Library not loaded: /usr/lib/libbsm.0.dylib`, a library present in the shared
  # cache but with no file on the volume). Demanding the key would make every existing park unpressable
  # (882's own defect, sixteen times repaired now), and the ladder still owes those presses. Unlike
  # HFS_ROOT_MEDIA / ROOT_FROM_CARD / HDD_WRITE / CARD_COW there is no entry-ELF marker to ground this
  # on: the switch moves ONE pool object (`bsd/vm/vm_unix.c`), and a new unconditional `_off` marker in
  # the entry image would move the parked arms' image hashes with no `--gc-sections` in the link
  # (965c's reason). A post-996 record can never reach this branch: `build_entry.sh`'s two-way check
  # refuses a record whose arm-key list omits the key, and the writer emits the line unconditionally
  # (0 or 1), so a record this build made carries a non-empty value and the branch above does not fire
  # for it.
  if [[ -z $_v && $_k == STAGE90_XNU_SHREG_PROBE ]]; then
    printf '  %s=(absent, and a record that does not name the shared-region probe is one built before 996 - the 294/438 returns printed nothing, the only value a pre-996 build could have written)\n' "$_k"
    continue
  fi
  # **997's switch, the same one-way rule as 911b/911c/912/954/958/988/990/991/992/994/995/996, and for
  # the same reason.** Every arm parked before 997 was built with the 20-byte shared-region wire (the
  # switch did not exist), so its record has no `STAGE90_XNU_SHREG_WIRE` line; an absent key is not a
  # missing value but the value - the switch was off, because it did not exist, so
  # `bsd/vm/vm_unix.c`'s `shared_region_copyin_mappings` computed `count * 5 << 2` and syscall 438
  # returned EINVAL on the first mapping, exactly as 996's probe measured
  # (`out/stage90/captures/cancro-last_kmsg-996-armed-d13-cea0c1c2.txt:4101-4105`: `map_file kr=4` +
  # `map_slide ret=22`, the shared cache never mapped, dyld halted on `Library not loaded:
  # /usr/lib/libbsm.0.dylib`). Demanding the key would make every existing park unpressable (882's own
  # defect, seventeen times repaired now), and the ladder still owes those presses. Unlike
  # HFS_ROOT_MEDIA / ROOT_FROM_CARD / HDD_WRITE / CARD_COW there is no entry-ELF marker to ground this
  # on: the switch moves ONE pool object (`bsd/vm/vm_unix.c`), and a new unconditional `_off` marker in
  # the entry image would move the parked arms' image hashes with no `--gc-sections` in the link (965c's
  # reason). A post-997 record can never reach this branch: `build_entry.sh`'s two-way check refuses a
  # record whose arm-key list omits the key, and the writer emits the line unconditionally (0 or 1), so
  # a record this build made carries a non-empty value and the branch above does not fire for it.
  if [[ -z $_v && $_k == STAGE90_XNU_SHREG_WIRE ]]; then
    printf '  %s=(absent, and a record that does not name the shared-region wire is one built before 997 - the struct was 20 bytes wide, the only value a pre-997 build could have written)\n' "$_k"
    continue
  fi
  # **998's switch, the same one-way rule as 911b/911c/912/954/958/988/990/991/992/994/995/996/997, and
  # for the same reason.** Every arm parked before 998 was built with the tree's default shared-region
  # geometry (the switch did not exist), so its record has no `STAGE90_XNU_SHREG_GEOM` line; an absent
  # key is not a missing value but the value - the switch was off, because it did not exist, so
  # `osfmk/vm/vm_shared_region.c` created the 0x30000000/0x10000000 window and
  # `osfmk/arm/status.c` handed out USRSTACK 0x2FE00000, exactly as 997's press measured
  # (`out/stage90/captures/cancro-last_kmsg-997-armed-d13-518b6a94.txt:4096-4110`: the four `IOS7LAB
  # cache mapping` lines with already-slid addresses, then `map_file kr=1` + `map_slide ret=14` - the
  # window cannot hold dyld's slid shared cache). Demanding the key would make every existing park
  # unpressable (882's own defect, eighteen times repaired now), and the ladder still owes those
  # presses. Unlike HFS_ROOT_MEDIA / ROOT_FROM_CARD / HDD_WRITE / CARD_COW there is no entry-ELF marker
  # to ground this on: the switch moves TWO pool objects (`vm_shared_region.c` + `status.c`), and a new
  # unconditional `_off` marker in the entry image would move the parked arms' image hashes with no
  # `--gc-sections` in the link (965c's reason). A post-998 record can never reach this branch:
  # `build_entry.sh`'s two-way check refuses a record whose arm-key list omits the key, and the writer
  # emits the line unconditionally (0 or 1), so a record this build made carries a non-empty value and
  # the branch above does not fire for it.
  if [[ -z $_v && $_k == STAGE90_XNU_SHREG_GEOM ]]; then
    printf '  %s=(absent, and a record that does not name the shared-region geometry is one built before 998 - the window was 0x30000000/0x10000000 and the stack top 0x2FE00000, the only value a pre-998 build could have written)\n' "$_k"
    continue
  fi
  # **1000's one new switch: absent names the pre-USVC arm.** `STAGE90_XNU_USVC` reached the record
  # only in 1000; every arm parked before it was built from a tree whose `traps_lo.s` had no hook and
  # whose image defined no `entry_note_user_svc`, so an absent key is not a missing value but the
  # value. Demanding the key would make every pre-1000 park unpressable (882's defect, nineteen times
  # repaired now). A post-1000 record can never reach this branch: `build_entry.sh` validates the
  # switch at its own assignment (0/1 only) and emits the line unconditionally.
  if [[ -z $_v && $_k == STAGE90_XNU_USVC ]]; then
    printf '  %s=(absent, and a record that does not name the user-SVC frontier hook is a pre-1000 arm - the only value any pre-1000 build could have written)\n' "$_k"
    continue
  fi
  # **1001's one new switch: absent names the pre-submap-skip arm.** `STAGE90_XNU_SUBMAP_PMAP_SKIP`
  # reached the record only in 1001; every arm parked before it was built from a tree whose
  # `vm_map_enter` tail carried no `is_submap` guard and whose pool was compiled without the switch,
  # so an absent key is not a missing value but the value. Demanding the key would make every
  # pre-1001 park unpressable (882's defect, twenty times repaired now). A post-1001 record can never
  # reach this branch: `build_entry.sh` validates the switch at its own assignment (0/1 only) and
  # emits the line unconditionally.
  if [[ -z $_v && $_k == STAGE90_XNU_SUBMAP_PMAP_SKIP ]]; then
    printf '  %s=(absent, and a record that does not name the submap pmap-enter skip is a pre-1001 arm - the only value any pre-1001 build could have written)\n' "$_k"
    continue
  fi
  # **1003's one new switch: absent names the pre-stall-instrument arm.** `STAGE90_XNU_STALL` reached
  # the record only in 1003; every arm parked before it was built from a tree whose `pe_msm8974.c` had
  # no sampler call site and whose image defined no `entry_note_stall_sample`, so an absent key is not
  # a missing value but the value. Demanding the key would make every pre-1003 park unpressable (882's
  # defect, twenty-one times repaired now). A post-1003 record can never reach this branch:
  # `build_entry.sh` validates the switch at its own assignment (0/1 only) and emits the line
  # unconditionally.
  if [[ -z $_v && $_k == STAGE90_XNU_STALL ]]; then
    printf '  %s=(absent, and a record that does not name the pid-1 stall sampler is a pre-1003 arm - the only value any pre-1003 build could have written)\n' "$_k"
    continue
  fi
  # **1004's one new switch: absent names the pre-abort-trace arm.** `STAGE90_XNU_ABORT_TRACE` reached
  # the record only in 1004; every arm parked before it was built from a tree whose `entry_stubs.c` had
  # the legacy 8/16/64 caps and defined no `xnu_live_sleh_upc`, so an absent key is not a missing value
  # but the value (882's defect, twenty-two times repaired now). A post-1004 record can never reach this
  # branch: `build_entry.sh` validates the switch at its own assignment (0/1 only) and emits the line
  # unconditionally.
  if [[ -z $_v && $_k == STAGE90_XNU_ABORT_TRACE ]]; then
    printf '  %s=(absent, and a record that does not name the sleh abort-trace arm is a pre-1004 arm - the only value any pre-1004 build could have written)\n' "$_k"
    continue
  fi
  # **1021d's switch, the same one-way rule as 911b ... 1004, and for the same reason.** Every arm parked
  # before 1021d was built with the pool flags `-mfpu=neon-vfpv4 -mfloat-abi=softfp`, i.e. compiler-emitted
  # FP/NEON IS in its pool, so a record with no `STAGE90_XNU_GENERAL_REGS` line is one whose only possible
  # value is 0. Demanding the key would make every existing park unpressable (882's own defect, repaired
  # again here) and the ladder still owes those presses - including 1020b's, which is the run 1021d's
  # frontier answer is measured against. A post-1021d record can never reach this branch: `build_entry.sh`
  # writes the line unconditionally (0 or 1) and its 678 two-way check refuses a record whose arm-key list
  # omits the key.
  if [[ -z $_v && $_k == STAGE90_XNU_GENERAL_REGS ]]; then
    printf '  %s=(absent, and a record that does not name the FP/NEON-codegen switch is one built before 1021d - the pool was compiled with the FP register file available, the only value a pre-1021d build could have written)\n' "$_k"
    continue
  fi
  # **1024's switch, the same one-way rule as 911b ... 1021d, and for the same reason.** Every arm
  # parked before 1024 was built with NO ceiling switch at all: the task map's `VM_MAX_ADDRESS` was
  # this tree's `#else` 0x80000000 (`vm_param.h:63`), the only value a pre-1024 build could have
  # written. Demanding the key would make every existing park unpressable (882's defect, repaired
  # again here) and the ladder still owes those presses. A post-1024 record can never reach this
  # branch: `build_entry.sh` writes the line unconditionally (0 or 1), its 678 two-way check refuses
  # a record whose arm-key list omits the key, and the 1024 clause at the link site reads
  # `osfmk_kern_task.o` by value against the recorded value.
  if [[ -z $_v && $_k == STAGE90_XNU_VM_MAX_SPLIT ]]; then
    printf '  %s=(absent, and a record that does not name the user-map-ceiling switch is one built before 1024 - the task map ceiling was 0x80000000, the only value a pre-1024 build could have written)\n' "$_k"
    continue
  fi
  # **1025's switch, the same one-way rule as 911b ... 1024, and for the same reason.** Every arm
  # parked before 1025 was built with NO failed-fault probe at all: trap.c's usermode data-abort arm
  # discarded the `vm_fault` return and `create_unix_stack` published nothing, so a pre-1025 record's
  # only possible value is 0. Demanding the key would make every existing park unpressable (882's
  # defect, repaired again here) and the ladder still owes those presses. A post-1025 record can never
  # reach this branch: `build_entry.sh` writes the line unconditionally (0 or 1), its 678 two-way check
  # refuses a record whose arm-key list omits the key, and the 1025 clause at the link site reads
  # osfmk_arm_trap.o / bsd_kern_kern_exec.o by value against the recorded value.
  if [[ -z $_v && $_k == STAGE90_XNU_USTACK_PROBE ]]; then
    printf '  %s=(absent, and a record that does not name the failed-fault-probe switch is one built before 1025 - no publisher was compiled in, the only value a pre-1025 build could have written)\n' "$_k"
    continue
  fi
  # **1026's switch, the same one-way rule as 911b ... 1025, and for the same reason.** Every arm
  # parked before 1026 was built with NO abort-entry discriminator at all: trap.c's data-abort arm
  # published only the `vm_fault` return and `create_unix_stack` carried no accessor, so a pre-1026
  # record's only possible value is 0. Demanding the key would make every existing park unpressable
  # (882's defect, repaired again here) and the ladder still owes those presses. A post-1026 record can
  # never reach this branch: `build_entry.sh` writes the line unconditionally (0 or 1), its arm-key
  # list includes the key, and the 1026 clause at the link site reads osfmk_arm_trap.o /
  # bsd_kern_kern_exec.o by value against the recorded value.
  if [[ -z $_v && $_k == STAGE90_XNU_ABT_ENTRY_PROBE ]]; then
    printf '  %s=(absent, and a record that does not name the abort-entry-discriminator switch is one built before 1026 - no discriminator was compiled in, the only value a pre-1026 build could have written)\n' "$_k"
    continue
  fi
  # **1028's switch, the same one-way rule as 1026 ... 1025, and for the same reason.** Every arm parked
  # before 1028 was built with `create_unix_stack` allocating the FIXED extent as plain `size` (no
  # headroom), so a pre-1028 record's only possible value is 0. Demanding the key would make every
  # existing park unpressable and the ladder still owes those presses. A post-1028 record can never reach
  # this branch: `build_entry.sh` writes the line unconditionally (0 or 1) and its arm-key list includes
  # the key.
  if [[ -z $_v && $_k == STAGE90_XNU_H2_STACK_HEADROOM ]]; then
    printf '  %s=(absent, and a record that does not name the H2-stack-headroom switch is one built before 1028 - create_unix_stack allocated the FIXED extent as plain size, the only value a pre-1028 build could have written)\n' "$_k"
    continue
  fi
  # **1029's switch, the same one-way rule as 1028 ... 1025, and for the same reason.** Every arm
  # parked before 1029 was built with NO reader probe at all: trap.c's data-abort arm published no
  # reader identity and kern_exec.c carried no argslen/argc accessors, so a pre-1029 record's only
  # possible value is 0. Demanding the key would make every existing park unpressable (882's defect,
  # repaired again here) and the ladder still owes those presses. A post-1029 record can never reach
  # this branch: `build_entry.sh` writes the line unconditionally (0 or 1), its arm-key list includes
  # the key, and the 1029 clause at the link site reads osfmk_arm_trap.o / bsd_kern_kern_exec.o by
  # value against the recorded value.
  if [[ -z $_v && $_k == STAGE90_XNU_READER_PROBE ]]; then
    printf '  %s=(absent, and a record that does not name the reader-probe switch is one built before 1029 - no reader identity was compiled in, the only value a pre-1029 build could have written)\n' "$_k"
    continue
  fi
  # **1030's switch, the same one-way rule as 1029 ... 1025, and for the same reason.** Every arm parked
  # before 1030 was built with NO writer probe at all: trap.c's data-abort arm published no r4 derivation
  # and no writer identity, so a pre-1030 record's only possible value is 0. Demanding the key would make
  # every existing park unpressable (882's defect, repaired again here) and the ladder still owes those
  # presses. A post-1030 record can never reach this branch: `build_entry.sh` writes the line
  # unconditionally (0 or 1), its arm-key list includes the key, and the 1030 clause at the link site reads
  # the pool object by value against the recorded value.
  if [[ -z $_v && $_k == STAGE90_XNU_WRITER_PROBE ]]; then
    printf '  %s=(absent, and a record that does not name the writer-probe switch is one built before 1030 - no r4 derivation was published, the only value a pre-1030 build could have written)\n' "$_k"
    continue
  fi
  # **1031's switch, the same one-way rule as 1030 ... 1025, and for the same reason.**  Every arm parked
  # before 1031 was built with NO caller probe at all: trap.c published no caller frame and no region-top
  # row, so a pre-1031 record's only possible value is 0.  Demanding the key would make every existing
  # park unpressable (882's defect, repaired again here) and the ladder still owes those presses.  A
  # post-1031 record can never reach this branch: `build_entry.sh` writes the line unconditionally (0 or
  # 1), its arm-key list includes the key, and the 1031 clause at the link site reads the pool objects by
  # value against the recorded value.
  if [[ -z $_v && $_k == STAGE90_XNU_CALLER_PROBE ]]; then
    printf '  %s=(absent, and a record that does not name the caller-probe switch is one built before 1031 - no caller frame was published, the only value a pre-1031 build could have written)\n' "$_k"
    continue
  fi
  [[ -n $_v ]] \
    || fail "$ENTRY_CFG has no $_k line - this gate prints the entry image's variant by name, and a record without that key would let a run go out with a switch nobody recorded. The fifteen variant keys (SLOT_NULL, EXIT_POC_FLUSH, IDLE_CACHE_ENABLE, ISTACK_SEPARATE, IDLE_STACK, SEAM_POC, SEAM_MEASURE, SEAM_END_RUN, POST_END_RUN, POST_END_TICKS, STORAGE_PROBE, PWR_WAIT_TICKS, MOUNT, HFS_ROOT_MEDIA, IDLE_NO_SLEEP) are exactly the ones a display filter written around the artifact keys drops in silence - and HFS_ROOT_MEDIA is required only when this image is the HFS root arm, which the entry ELF above reports"
  printf '  %s=%s\n' "$_k" "$_v"
done
# And the converse, so a key the list above does not name cannot arrive unshown (a *tenth* when the list
# held nine; a nineteenth now): every `STAGE90_` key the record carries
# must be one of the names above. Without this the list above would be the only definition of what is
# visible, and a key added on the build side would be recorded and never read - the same defect with
# the arrow reversed.
# `LC_ALL=C` on all three, the same pin as the entry-sources comparison below: these agree with each
# other under the ambient locale only by accident, and a `comm` whose input was sorted in a different
# collation answers about the order rather than about the keys - see the note at that clause.
_unshown=$(awk -F= '!/^#/ && $1 ~ /^STAGE90_/ { print $1 }' "$ENTRY_CFG" | LC_ALL=C sort -u \
           | LC_ALL=C comm -23 - <(printf '%s\n' "${ENTRY_CFG_KEYS[@]}" | LC_ALL=C sort -u))
[[ -z $_unshown ]] \
  || fail "$ENTRY_CFG carries key(s) this gate does not print: $(printf '%s\n' "$_unshown" | tr '\n' ' ')- a switch recorded on the build side and not shown here is a switch the next run would go out with unread; add it to ENTRY_CFG_KEYS above"
echo "  (recorded in $ENTRY_CFG, bound to $actual_sha)"
#
# **965b: ON A CARD-ROOT HFS ARM, THE MEDIUM THE ROOT IS READ FROM IS THE CARD IMAGE - SO ITS FILESYSTEM
# FAMILY MUST BE CHECKED HERE, ON THE BYTES, NOT LEFT TO THE RECORD.** With `ROOT_FROM_CARD=1` +
# `HFS_ROOT_MEDIA=1`, `__wrap_mdevlookup` answers the card unit (`entry_trace.c:5131`) and disk 0 (the
# committed blob) is never registered - so the embedded blob is inert and `out/stage90/xnu_card_hfs.img`
# (written to userdata's head by `scripts/press_965b.sh`) is the whole root medium. Every check in the tree
# reads the BLOB, so before 965b the card could ship as HFS+ v4 while the tree's fixture was HFSX, and
# nothing refused - `check_hfs_root_blob.py` accepts both families, so a stale HFS+ card passes every gate
# and the mount silently probes a filesystem family the target does not use (the 965 defect). This clause
# grounds the family on the CARD bytes the mount will actually read: it must be HFSX (`0x4858 v5`), the
# family the real iOS 7.1.2 rootfs uses. It fires only when the record names BOTH switches, so it cannot
# refuse an arm whose root is not the card, and it never prescribes a rebuild of the frozen entry image -
# the card image is regenerated by `tools/build_root_volumes.sh`, which touches no tracked file.
_v_hfs_media=$(awk -F= '$1 == "STAGE90_XNU_HFS_ROOT_MEDIA" { print $2 }' "$ENTRY_CFG")
_v_root_card=$(awk -F= '$1 == "STAGE90_XNU_ROOT_FROM_CARD"  { print $2 }' "$ENTRY_CFG")
if [[ $_v_hfs_media == 1 && $_v_root_card == 1 ]]; then
  _card_img="$OUT/xnu_card_hfs.img"
  [[ -f $_card_img ]] \
    || fail "$ENTRY_CFG names an HFS arm whose root IS the card (HFS_ROOT_MEDIA=1, ROOT_FROM_CARD=1), but
        the card media for it is absent or the wrong family: $OUT/xnu_card_hfs.img does not exist. The
        embedded blob is NOT the medium on this arm (disk 0 is never registered - entry_trace.c:5131), so
        pressing without the card image would send a run whose root medium was never written. Build it with
        tools/build_root_volumes.sh (it also verifies the committed blob agrees)."
  _card_sig=$(python3 - "$_card_img" <<'PY'
import struct, sys
d = open(sys.argv[1], "rb").read()
print("%04x %d %d" % (struct.unpack(">H", d[1024:1026])[0],
                      struct.unpack(">H", d[1026:1028])[0], len(d)))
PY
)
  set -- $_card_sig
  _csig=$1; _cver=$2; _cbytes=$3
  [[ $_csig == 4858 && $_cver == 5 ]] \
    || fail "$ENTRY_CFG names an HFS arm whose root IS the card, but the card image $OUT/xnu_card_hfs.img
        is not HFSX: volume header signature 0x$_csig version $_cver ($_cbytes bytes). The arm's contract is
        that the PRESSED root medium is HFSX 0x4858 v5 - the family the real iOS 7.1.2 rootfs uses
        (experiment 965) - and a card that says HFS+ (0x482b v4) mounts the wrong family: 965a flipped only
        the INERT embedded blob, and this gate is what stops that split from shipping. Regenerate the card
        with tools/build_root_volumes.sh (HFSX), which writes out/xnu_card_hfs.img and touches no tracked file."
  printf '  root medium: the CARD image %s is HFSX 0x4858 v5 (%s bytes) - the family the pressed root uses\n' \
         "$_card_img" "$_cbytes"
  # **965c: the card image's SIZE against the strategy's BOUND, which is the one thing a 512 KiB fixture
  # never had to answer.** `STAGE90_XNU_FULL_EXTENT=0` bounds the card unit through 888's 32-bit product
  # `(unsigned)(selected_count * 512)`; `userdata` is 13,610,499,072 B, so that product is 725,597,184 B
  # (692 MiB). A card image larger than 692 MiB therefore cannot be served whole without the arm - the
  # strategy answers `EOF` for its top bytes and the mount reads a truncated medium. This grounds the arm
  # on the ARTIFACT (the card's own byte count), not the record: a 965c arm with the switch OFF shipping a
  # 896 MiB card is exactly the silent defect the rung exists to prevent, and it is refused here. The bound
  # is THIS device's userdata extent mod 2^32 (the same partition the arm selects, `_card_lba=0x400000`).
  _CARD_32BIT_BOUND=725597184
  _v_full_extent=$(awk -F= '$1 == "STAGE90_XNU_FULL_EXTENT" { print $2 }' "$ENTRY_CFG")
  if [[ $_v_full_extent == 1 && $_cbytes -gt $_CARD_32BIT_BOUND ]]; then
    printf '  root medium: FULL_EXTENT=on - the card unit bounds the WHOLE selected partition (13.6 GiB), so\n'
    printf '               the %s-byte card image is addressable in full (888\x27s 32-bit bound was 692 MiB)\n' "$_cbytes"
  elif [[ $_v_full_extent != 1 && $_cbytes -gt $_CARD_32BIT_BOUND ]]; then
    fail "$ENTRY_CFG names a card-root arm whose FULL_EXTENT is ${_v_full_extent:-<absent>} (not 1), but the
        card image $OUT/xnu_card_hfs.img is $_cbytes bytes = $((_cbytes / 1048576)) MiB, LARGER than the
        strategy's 32-bit bound of $_CARD_32BIT_BOUND B (692 MiB) for this device's 13.6 GiB userdata.
        Without STAGE90_XNU_FULL_EXTENT=1 the card unit's length is 888's (unsigned) product, so the
        strategy serves EOF for everything above 692 MiB and the mount reads a truncated medium: this is
        the silent defect 965c exists to prevent (a 512 KiB fixture never saw it).
        Rebuild the entry image under STAGE90_XNU_FULL_EXTENT=1 (with the platform module built with the
        same define), or write a card image no larger than 692 MiB."
  fi
fi
#
# **Which arm those keys add up to, and what it can be read for - because the checklist the XNU-entry arm
# prints further down is 526's and the image this gate passes is not 526's.** Measured 2026-09-22 on the
# frozen arm: the record says `SLOT_NULL=1 IDLE_CACHE_ENABLE=0` (entry bin `f202f246...`, the 533 arm -
# 526's null instrument with the enter-side `SCTLR.C` re-enable taken out), while the block under
# `== entering XNU ==` ends *"The image this preflight is being run against is 1daaf44e62456369..."* -
# pinning to this image a checklist written for an image that has the enable in it. Item 3 there says
# *"the enable is untouched, so ... xnu_live_slot_cwe_win shows C clear, _set shows it set with
# _calls >= 1"*, and in this arm those two are the same value **by construction**: the only writer of
# `SCTLR.C` sits inside `#if STAGE90_XNU_IDLE_CACHE_ENABLE` and the note is called either way
# (`entry_trace.c:1851-1854`), so with the switch at 0 the register is read twice and never written. An
# operator following item 3 sees `_cwe_set` with `C` still clear and reads a *designed absence* as a
# *failed enable* - the 533 doc's section 5 item 3 is that same criterion and 538 is where it was shown
# it cannot fail. So the arm is derived here, one consequence per recorded key, and the enable's line
# carries the reading rule that follows from its own value rather than a second assertion.
# The eight are read as `grep -c` of the whole `KEY=` prefix rather than as awk's last match, because the
# three ways a value can be unusable here are three different things and only one of them is `build_entry.sh`
# refusing a bad value at build time (`:350-352`): a key can be **absent** (a record older than the key, so
# the clause has no value and `[[ $V -eq 1 ]]` on an empty string would silently take the 0 branch *while the
# record printed above shows a blank* - a false clearance in the exact shape [[552's exit clause]] was mended
# for), **defined twice** (one value with two definitions, whose `[[ -eq ]]` would read a multi-line string),
# or **out of range**. All three refuse, each naming what it is, and **none of them prescribes a rebuild** -
# the frozen pair's payload embeds the entry image, so "rebuild the entry image" is a refusal whose remedy
# would spend the very freeze this gate exists to protect (539's defect, one arm later).
_vmiss=; _vdup=; _vbad=
for _vk in STAGE90_XNU_SLOT_NULL STAGE90_XNU_EXIT_POC_FLUSH STAGE90_XNU_IDLE_CACHE_ENABLE \
           STAGE90_XNU_ISTACK_SEPARATE STAGE90_XNU_IDLE_STACK STAGE90_XNU_SEAM_POC \
           STAGE90_XNU_SEAM_MEASURE STAGE90_XNU_IDLE_NO_SLEEP
do
  case $(grep -c "^$_vk=" "$ENTRY_CFG") in
    0) _vmiss="$_vmiss $_vk" ; continue ;;
    1) ;;
    *) _vdup="$_vdup $_vk" ; continue ;;
  esac
  _vline=$(grep "^$_vk=" "$ENTRY_CFG")
  _vv=${_vline#*=}
  case $_vk in
    STAGE90_XNU_SLOT_NULL)         V_SLOT_NULL=$_vv ;;
    STAGE90_XNU_EXIT_POC_FLUSH)    V_EXIT_POC_FLUSH=$_vv ;;
    STAGE90_XNU_IDLE_CACHE_ENABLE) V_IDLE_CACHE_ENABLE=$_vv ;;
    STAGE90_XNU_ISTACK_SEPARATE)   V_ISTACK_SEPARATE=$_vv ;;
    STAGE90_XNU_IDLE_STACK)        V_IDLE_STACK=$_vv ;;
    STAGE90_XNU_SEAM_POC)          V_SEAM_POC=$_vv ;;
    STAGE90_XNU_SEAM_MEASURE)      V_SEAM_MEASURE=$_vv ;;
    STAGE90_XNU_IDLE_NO_SLEEP)     V_IDLE_NO_SLEEP=$_vv ;;
  esac
  case $_vv in
    0|1) ;;
    *) _vbad="$_vbad $_vk=$_vv" ;;
  esac
done
[[ -z $_vmiss ]] \
  || fail "$ENTRY_CFG has no line for:$_vmiss - and this clause reads which arm the entry image is out of exactly those values, so without them it could only narrate the 0 arm while the record shows a blank. Nothing is rebuilt by this refusal and nothing should be: derive the arm from the record and the sources by hand before the run, or write the keys into the record only if they are what the image really was built with"
[[ -z $_vdup ]] \
  || fail "$ENTRY_CFG defines$_vdup more than once: one value with two definitions, and a gate that reads either of them is a gate that compared neither"
[[ -z $_vbad ]] \
  || fail "the record's variant key(s)$_vbad are not 0 or 1: these eight are switches, and a value that is neither is not an arm this clause can narrate - so the run would go out with a story about it that nothing supports"
# **727: the two RUNG keys, which the key list above PRINTS and nothing read.** `STAGE90_XNU_STORAGE_PROBE`
# is a rung (0..N) and `STAGE90_XNU_PWR_WAIT_TICKS` is a budget (1..19200000 ticks of the device's own
# counter), so neither belongs in the `0|1` test above - and neither was in it, nor in any other clause.
# What stood in for a check was the 692 sentence struck above: written when the key really was a boolean,
# left reading `with it at 1 ... and with it at 0` through eleven more rungs. **The class is this project's
# most-repeated one - one quantity, two readings, the prose taking one while the record means the other -
# and the reason it survived is the reason it is worth a clause rather than a sentence: nothing ever
# contradicted a comment.**
#
# **The bound is READ, not restated, and that is the repair rather than a style choice.** Both numbers have
# exactly one definition - the `#if ... < lo || ... > hi` guard in `src/entry/entry_storage.c`, the same
# line the compiler refuses on when a build names a rung that does not exist - so this clause parses that
# line. A rung the ladder grows is then a bound this gate picks up with no edit here, and a hand-kept copy
# of the ladder (the shape 683/686/690/692 each added one more line to) stops being a thing this file has.
#
# **And a bound that cannot be read is a REFUSAL, not a pass.** A gate that answers "in range" when it
# could not look has performed the check it claims to have performed - the file's own rule for a missing
# dependency, and the same one `tools/check_storage_refs.py` is held to further down. The refusal names
# which of the two it could not read, so the operator is not left guessing whether the ladder moved or the
# file went missing.
_rung_guard() {   # $1 = the key; prints "<lo> <hi>" out of that key's own `#if` guard, or nothing
  awk -v k="$1" '
    $0 ~ ("^#if " k " < [0-9]+ \\|\\| " k " > [0-9]+") {
      match($0, /< [0-9]+/); lo = substr($0, RSTART + 2, RLENGTH - 2)
      match($0, /> [0-9]+/); hi = substr($0, RSTART + 2, RLENGTH - 2)
      print lo, hi
      exit
    }' "$SRC_DIR/entry/entry_storage.c" 2>/dev/null
}
RUNG_KEYS=(STAGE90_XNU_STORAGE_PROBE STAGE90_XNU_PWR_WAIT_TICKS)
# **There is no `_rungmiss` here, and the reason is measured rather than stylistic.** The first draft had
# one, and the sandbox refused to let it fire: deleting the `STAGE90_XNU_STORAGE_PROBE=` line from a copy
# of the record and re-running gave the refusal from the `ENTRY_CFG_KEYS` loop ABOVE (`:627`, "has no
# ... line"), never this clause's - because that loop reads every key with `awk` and fails on an empty
# value, so a missing line and an empty one are both already gone by the time this runs. A second refusal
# for the same state would be a branch no record can reach, which is the shape
# [[a cell that cannot reach the branch its label names]] names, and the honest repair is to not write it
# rather than to leave a check that looks like coverage. **Presence is that clause's; this one owns the
# value.** Duplication is a different question and this clause does own it: the loop above tests
# `grep -c` only for the eight switches, so a second `STAGE90_XNU_STORAGE_PROBE=` line reaches here.
_rungdup=; _rungbad=; _rungnb=
for _rk in "${RUNG_KEYS[@]}"
do
  case $(grep -c "^$_rk=" "$ENTRY_CFG") in
    0|1) ;;
    *) _rungdup="$_rungdup $_rk" ; continue ;;
  esac
  _rv=$(awk -F= -v k="$_rk" '$1 == k { print $2 }' "$ENTRY_CFG")
  _rg=$(_rung_guard "$_rk")
  if [[ -z $_rg ]]; then _rungnb="$_rungnb $_rk" ; continue ; fi
  _rlo=${_rg% *}; _rhi=${_rg#* }
  case $_rv in
    ''|*[!0-9]*) _rungbad="$_rungbad $_rk=$_rv (not a whole number)" ;;
    *) (( _rv >= _rlo && _rv <= _rhi )) \
         || _rungbad="$_rungbad $_rk=$_rv (outside [$_rlo, $_rhi], the bound its own guard declares)" ;;
  esac
done
[[ -z $_rungdup ]] \
  || fail "$ENTRY_CFG defines$_rungdup more than once: one rung with two definitions, and a gate that reads either of them is a gate that compared neither"
[[ -z $_rungnb ]] \
  || fail "this gate could not read the ladder's own bound for$_rungnb out of src/entry/entry_storage.c, so it cannot say whether the record's value is a rung that exists - and a bound it cannot read is not a bound it may assume. Check that the file is present and that its \`#if <KEY> < lo || <KEY> > hi\` guard is still one line; if the guard was reformatted, this clause has to be taught the new shape rather than left answering 'in range' from a parse that found nothing"
[[ -z $_rungbad ]] \
  || fail "the record's rung key(s)$_rungbad - and the bound is not this gate's opinion: it is the guard in src/entry/entry_storage.c that refuses the build, so a record outside it describes either a rung that does not exist or a value that is not a number, and the run would go out with a story about the storage line that nothing supports. Read the ladder's own \`#error\` at that guard - it spells out every rung - and correct the record, or rebuild the entry image with the rung this arm really needs"
# **And the rung is PRINTED, because a checked value the operator cannot see is a check the operator cannot
# read.** The path and the bound are named here so that the sentence an operator takes to the log is the
# gate's own reading of the record and not a rung number they have to remember the meaning of: the ladder
# itself is described in exactly one place, the `#error` this clause just parsed, and this line says so
# instead of restating it.
echo "== how far up the storage line this arm goes, read against the ladder's own guard =="
for _rk in "${RUNG_KEYS[@]}"
do
  _rv=$(awk -F= -v k="$_rk" '$1 == k { print $2 }' "$ENTRY_CFG")
  _rg=$(_rung_guard "$_rk")
  [[ -n $_rg ]] || continue
  printf '  %s=%s  (within [%s, %s], the bound its own `#if` guard declares in src/entry/entry_storage.c;\n' \
         "$_rk" "$_rv" "${_rg% *}" "${_rg#* }"
  printf '      what that number DOES is spelled out at that guard, in the `#error` the build refuses on -\n'
  printf '      this gate prints the value and the bound and deliberately does not restate the rungs)\n'
done
# **And the pair, because the two seam switches are one seam's two arms and a record can name both.** The
# build refuses that pair (`build_entry.sh` exits on it and `entry_trace.c` `#error`s), so an image with
# both set has never been built and cannot be - which makes a record carrying both a record about *no*
# image, while the two narrations below are written for two different arms. Printing either over it would
# put a run's story on an artifact that does not exist, so this refuses by naming the pair instead.
[[ ! ( $V_SEAM_POC -eq 1 && $V_SEAM_MEASURE -eq 1 ) ]] \
  || fail "$ENTRY_CFG has STAGE90_XNU_SEAM_POC=1 and STAGE90_XNU_SEAM_MEASURE=1: one is the interception with 535's operation behind it and the other is the same interception with the operation removed, and no image can be both - build_entry.sh refuses that pair and entry_trace.c #errors on it, so this record describes an image that cannot exist and one of the two values is wrong. The gate cannot tell which, so it names the test rather than narrating an arm: read the seam's own body in out/stage90/xnu_arm_entry.elf (entry_seam_flush, and whether it calls FlushPoC_DcacheRegion) or rebuild the entry image with the switch this arm really needs. Nothing is rebuilt by this refusal, and nothing should be: the frozen pair embeds this entry image"
echo "== which arm the entry image in out/ is, in words =="
if [[ $V_IDLE_NO_SLEEP -eq 1 ]]; then
  echo "  idle sleep (IDLE_NO_SLEEP=1): 593 section 4's arm - 514's one repair is NOT in this image, so"
  echo "      nothing clears SIGPdisabled, cpu_idle's first test is true on every pass, it leaves by its"
  echo "      first door (Idle_load_context), and the window whose \`pop {fp, pc}\` is this phase's frontier"
  echo "      IS NEVER ENTERED. **Everything below about the slot, the bracket, the window's two ends and"
  echo "      the seam is narration about an arm this one is NOT**, and on this arm those keys are expected"
  echo "      ABSENT rather than zero - absent because the call inside the window is never made, which is a"
  echo "      different reading from the same keys missing in an arm that does enter it (569's absent-is-not-"
  echo "      zero, 526's distinction)."
  echo "      **And one of those absences is a different kind from the rest, so it is named here rather than"
  echo "      left to that sentence: \`xnu_live_repair_seq\`, \`_caller\`, \`_before\` and \`_after\` are absent on"
  echo "      this arm because the note that publishes them is inside the guard WITH THE CALL - in the"
  echo "      sources, \`entry_note_repair\` is the only writer of the four keys and its only call site sits"
  echo "      inside \`#if !STAGE90_XNU_IDLE_NO_SLEEP\`. The window's keys are absent because the code that"
  echo "      writes them is never reached; these are absent because the code is not in the image at all,"
  echo "      and the two are a different fault to look for when one of them shows up on the wrong arm.**"
  echo "      The reading differs in the same way, and in the direction that costs a boot: an operator seeing"
  echo "      the absence without this sentence reads it as the repair having failed, when on this arm it is"
  echo "      the switch - while on the 0 arm that same absence would be a bug. Its statement in words is"
  echo "      the park group's \`cpu_signal_handler_internal(FALSE) called 0 time(s)\`, a truthful count that"
  echo "      prints only if the park returns, so the group appearing at all is the run having passed the"
  echo "      death point - evidence for this arm and never against it, because its absence is also what the"
  echo "      0 arm's own captures show: the group is in neither parked log, for the reason 593 records,"
  echo "      that the park's poll is where that arm dies."
  echo "      **And the converse case is not only a different fault to look for - it is a different READING"
  echo "      of the whole run, because the runner chooses which ladder to print from these same keys.**"
  echo "      \`run_and_capture.sh --summarise\` decides between this arm's ladder and the baseline arm's"
  echo "      death block by a TWO-KEY test over the log itself (the \`idle_no_sleep_arm\` test, \`:819-828\`"
  echo "      in the runner at 626: counts of the two keys, then"
  echo "      \`if (( arm_door > 0 )) && (( arm_repair == 0 ))\` - \`door_seq\` present with \`repair_seq\` absent)."
  echo "      **Of the six terms the conjunction before 626 scored, \`repair_seq\`'s absence is the only one"
  echo "      that is BY CONSTRUCTION** - \`entry_note_repair\`, its only writer, sits inside"
  echo "      \`#if !STAGE90_XNU_IDLE_NO_SLEEP\` (\`entry_trace.c:1283\`, the call at \`:1295\`) - whereas the four"
  echo "      window keys (\`slot_cwe_\`, \`sip_seq\`, \`pce_seq\`, \`wfi_seq\`) are BEHAVIOURAL: compiled into"
  echo "      both images, published only by a pass that gets into the window. Scored as one kind, a"
  echo "      sleeper-arm pass that DID get in failed the test on behaviour and this arm's own success was"
  echo "      printed as the other arm's ordinary death. That is not hypothetical, it is measured on a"
  echo "      fixture built from 533 - appending ONE \`xnu_live_slot_cwe_win=...\` line to a log that scored"
  echo "      \`rung 1 PASS, rung 1b PASS\` turned the whole reading into a death block that names 533's arm,"
  echo "      with the ladder not run and no line anywhere saying so."
  echo "      **626 answers that in both directions, so read its table before the branch.** Every state now"
  echo "      prints all six keys with each key's KIND \`before\` it chooses: \`door_seq\` is the REACH GUARD"
  echo "      (published on both arms, so its absence says \`cpu_idle\` was never entered and neither arm's"
  echo "      clause applies), \`repair_seq\` is STRUCTURAL, and the other four are BEHAVIOURAL. A behavioural"
  echo "      key present with no \`repair_seq\` is a named \`AND A DISAGREEMENT\` state in which the ladder"
  echo "      still runs - its witnesses are published on both arms - and the pop-death block is withheld, so"
  echo "      the fixture above is now neither read as the baseline arm nor left unexplained, and the two"
  echo "      keys the branch is decided on are the two the table prints. After the run: **find the"
  echo "      pre-registered rung lines before concluding anything from their absence** - now backed by a"
  echo "      printed line rather than by the absence of one - and read a window key in this run's log as"
  echo "      'the window was entered on this boot', never as 'this is the baseline arm'.**"
  # --- the two figures the paragraph below used to TYPE, derived at gate time instead (520's rule) ---
  #
  # **That paragraph printed a record count, a byte size and a percentage - and two lines apart it
  # printed the console's limit while promising that the limit "is not typed here", a sentence falsified
  # by the line after it, which is the defect this file names most often.** Both figures come out of
  # `records/baseline-readings.txt` (627) now: 38 readings over the four captures the rungs are
  # measured against, each written as the runner's own reader, every one re-derived from the log it
  # names by `tools/verify_baseline_readings.sh`. A figure read from that record cannot go stale in this
  # file, which is the whole of the 520 rule. The two things it cannot supply - a count of live records
  # (it does not carry one) and the copies themselves on a host that never had `out/` - are said in
  # words instead, because a figure a reader can see is missing is a reading and a figure whose absence
  # reads as agreement is not.
  #
  # **None of this can refuse, and that is deliberate**: this gate must not gain a way to stop a press,
  # so every derivation is guarded (`set -euo pipefail` is on, and a `grep -c` that matched nothing is
  # exit 1) and every value is validated before it reaches a sentence.
  BASELINE_RECORD=$REPO_ROOT/records/baseline-readings.txt
  REC_NLOGS="?"; REC_CAP=""; REC_BYTES=""; REC_BYTES_LOG=""; REC_LIVE=""
  if [[ -r $BASELINE_RECORD ]]; then
    _n=$(awk '$1 ~ /^log=/{n++} END{print n+0}' "$BASELINE_RECORD" 2>/dev/null || true)
    _c=$(awk '$1=="reading=live_cap"{for(i=1;i<=NF;i++) if ($i ~ /^value=/) { v=$i; sub(/^value=/,"",v); print v }}' \
           "$BASELINE_RECORD" 2>/dev/null | sort -u | paste -sd, - || true)
    _b=$(awk '$1 ~ /^log=/{l="";b="";for(i=1;i<=NF;i++){ if($i ~ /^log=/){l=$i;sub(/^log=/,"",l)} if($i ~ /^bytes=/){b=$i;sub(/^bytes=/,"",b)} } if (b ~ /^[0-9]+$/) print b" "l }' \
           "$BASELINE_RECORD" 2>/dev/null | sort -n | tail -1 || true)
    if [[ $_n =~ ^[0-9]+$ ]]; then REC_NLOGS=$_n; fi
    if [[ $_c =~ ^0x[0-9a-fA-F]+(,0x[0-9a-fA-F]+)*$ ]]; then REC_CAP=$_c; fi
    if [[ $_b =~ ^([0-9]+)\ (.+)$ ]]; then REC_BYTES=${BASH_REMATCH[1]}; REC_BYTES_LOG=${BASH_REMATCH[2]}; fi
    _lmin=""; _lmax=""; _lmiss=""
    while IFS= read -r _f; do
      if [[ -n $_f && -r $OUT/captures/$_f ]]; then
        _k=$(grep -ac 'xnu_live_' "$OUT/captures/$_f" 2>/dev/null || true)
        if [[ $_k =~ ^[0-9]+$ ]]; then
          if [[ -z $_lmin || $_k -lt $_lmin ]]; then _lmin=$_k; fi
          if [[ -z $_lmax || $_k -gt $_lmax ]]; then _lmax=$_k; fi
        fi
      else
        _lmiss=1
      fi
    done < <(awk '$1 ~ /^log=/{for(i=1;i<=NF;i++) if ($i ~ /^file=/) { f=$i; sub(/^file=/,"",f); print f }}' \
               "$BASELINE_RECORD" 2>/dev/null || true)
    if [[ -n $_lmin && -z $_lmiss ]]; then REC_LIVE="$_lmin to $_lmax"; fi
  fi
  # The population is named as the record names it - "the captures the rungs are measured on", counted,
  # not "the baselines", because two of the four carry `role=counterexample-...`: a sentence that says
  # "baselines" while measuring a set that includes counterexamples is one value with two definitions.
  # The three degrading branches are kept apart on purpose: "not derivable because the record is
  # unreadable" and "not derivable because the copies it names are absent" are two different findings
  # about two different files, and a single sentence covering both would be a claim about whichever one
  # the reader assumed - the shape where one wording serves two states.
  if [[ -n $REC_LIVE ]]; then
    if [[ -n $REC_CAP ]]; then
      REC_CHANNEL="the ${REC_NLOGS} captures the rungs are measured on published ${REC_LIVE} live-channel records each, and the image's \`xnu_live_cap\` declares ${REC_CAP}"
    else
      REC_CHANNEL="the ${REC_NLOGS} captures the rungs are measured on published ${REC_LIVE} live-channel records each, against a capacity this gate could not derive"
    fi
  elif [[ ! -r $BASELINE_RECORD ]]; then
    REC_CHANNEL="the record counts of the captures the rungs are measured on are not derivable on this host, because \`records/baseline-readings.txt\` is not readable here"
  else
    REC_CHANNEL="the record counts of the captures the rungs are measured on are not derivable on this host, because the copies \`baseline-readings.txt\` names are not in ${OUT}/captures - read them there, where \`tools/verify_baseline_readings.sh\` re-derives them from the logs they name"
  fi
  if [[ -n $REC_BYTES ]]; then
    REC_MARGIN="The largest of the ${REC_NLOGS} captures the rungs are measured on is \`${REC_BYTES_LOG}\` at ${REC_BYTES} bytes, read out of \`records/baseline-readings.txt\` (627), every line of which \`tools/verify_baseline_readings.sh\` re-derives from the log it names"
  else
    REC_MARGIN="The largest capture's size is not derivable here, because \`records/baseline-readings.txt\` is not readable - it is recorded there, where \`tools/verify_baseline_readings.sh\` re-derives it from the log it names"
  fi
  echo "      **And that whole list is conditioned on something that is not about the arm, so it is named here"
  echo "      rather than left to the reader.** An absent \`xnu_live_*\` key is a reading about the machine"
  echo "      only if the channel that carries it published every record the boot made. The channel is finite"
  echo "      and says so: the entry image publishes \`xnu_live_cap\` (its capacity) at init and"
  echo "      \`xnu_live_capped\` at the first dropped record, and the runner reads both into its own"
  echo "      live-channel line after the run (609). **If that line reports the channel full, every absence"
  echo "      above stops being about the arm** - it becomes a record that was never published rather than an"
  echo "      event that did not happen, and this paragraph's list is a list of absences. Read the two"
  echo "      together: this one before the boot, the runner's line after it. It is not hypothetical for THIS"
  echo "      arm, which is the point of it: ${REC_CHANNEL}, and this is the arm built to run past where"
  echo "      those two stopped, so the run most likely to fill the channel is the one most likely to go"
  echo "      further - the two are the same run."
  echo "      **And which rung survives that is not a matter of degree: one of the three has a witness on the"
  echo "      other channel, so a full channel shortens the ladder rather than voiding it.** All three rung"
  echo "      keys are live-channel records (\`entry_stubs.c:4538\` \`xnu_live_poll_seq\`, \`:4542\`"
  echo "      \`xnu_live_poll_timeout_ms\`, \`:5270\` \`xnu_live_door_seq\`, each an \`entry_live_write\`), but"
  echo "      the timeout rung's predicate is also a *console* line's guard: \`entry_trace.c:1306\` is"
  echo "      \`if (timeout >= (uint32_t)ENTRY_PARK_MIN_MS && park_printed == 0u)\`, \`ENTRY_PARK_MIN_MS\`"
  echo "      is \`1000\` (\`:1164\`), and what that block prints at \`:1342\` is \`mini4: the OS has nothing to"
  echo "      run -- pid %d parked in poll for %d ms (caller 0x%x)\` - **carrying that timeout as its second"
  echo "      \`%d\`**. So that line printing at all IS rung 1b satisfied, with the value in it, and it is not"
  echo "      subject to \`xnu_live_cap\`/\`xnu_live_capped\`. It prints on THIS arm as well, which is the"
  echo "      direction a reader would doubt: the block sits outside the two"
  echo "      \`#if !STAGE90_XNU_IDLE_NO_SLEEP\` regions in that function (\`:1253-1264\`, \`:1283-1296\`), and"
  echo "      \`park_printed\` is declared at \`:1230\` and set at one place only, \`:1341\`, inside it."
  echo "      **Rung 1 and rung 0 have no such twin** - the console's door lines are counts read at the"
  echo "      park's return rather than the sequence, and \`poll_seq\` is a live-channel counter - so on a run"
  echo "      whose channel reports full, the timeout rung is still readable off the console and the other"
  echo "      two are not. This is the rule above pointed at the channel instead of at the arm: **before"
  echo "      concluding anything from the absence of a rung line, look for that rung on the other channel.**"
  echo "      And it is not a claim that the console is unbounded, and its bound is NOT a ring - the"
  echo "      difference is which END of the run survives. \`entry_stubs.c:2028-2046\` appends at"
  echo "      \`RAM_CONSOLE_BASE + 8\` up to \`0x00200000u - 12u\` bytes (\`:2034\`) and then simply stops -"
  echo "      the loop is \`size < max\` - writing the size back with **no refusal recorded**. A ring drops"
  echo "      the OLDEST records and keeps the newest; this keeps the FIRST 2 MiB and drops the tail, and"
  echo "      the tail is where this paragraph's console witness lives (:1342) along with the death shape."
  echo "      So it SATURATES IN SILENCE and it LOSES THE END OF THE RUN, and its tell - there is no"
  echo "      \`capped\` line to announce it - is that same size field reading the limit. The bound is not"
  echo "      typed here; derive it as \`:2034\` does. **And it is not typed two lines further down either:"
  echo "      this paragraph used to print that limit in the same breath as promising not to, which is this"
  echo "      file's own name for a sentence the line after it falsifies. Both of the margin's terms are"
  echo "      derived now - the bound from \`:2034\`, the largest size from the record, neither typed here.**"
  echo "      ${REC_MARGIN}; divide that by the console bound \`:2034\` derives - the limit, not the"
  echo "      headroom it leaves - and read a console near"
  echo "      its limit as one whose"
  echo "      tail, rung 1b's twin included, is missing. Accumulation is the other thing this gate does not"
  echo "      establish: the reset at \`:2036\` fires only when the signature is ABSENT, so a soft reset that"
  echo "      leaves DRAM and the signature intact would append to the previous boot's tail. What has been"
  echo "      measured - by the captures, not by this gate - is that every log held here carries exactly"
  echo "      ONE banner and carries it at byte 0: consistent with a buffer that restarts per boot, and not"
  echo "      proof of one, since a same-power-cycle pair is what would settle it."
  echo "      **So this arm's reading is a boot that does not die - and that is also what a live spin through"
  echo "      the scheduler looks like from the host.** The death is reachable only through 514's repair, so"
  echo "      skipping it is a lever that does not have to win the \`pop\`; but \"no death\" is satisfied by a"
  echo "      machine that is alive and never progresses just as well as by one that reached userland, so read"
  echo "      the run against a PROGRESS witness - a key or a console line that advances only if pid 1's thread"
  echo "      really runs past the old death point - pre-registered before the boot. A run of this arm whose"
  echo "      only reading is that it did not die is not a reading: a check that succeeds by printing"
  echo "      nothing cannot be told from one that never ran, and here the success and the failure mode are"
  echo "      the same silence."
  echo "      **What the arm gives up is the sleep itself** - 512/513's defect and 514's repair - so it is a"
  echo "      bring-up stopgap traded for a boot, and it is reversible with this one switch."
else
  # **The 0 arm had no line here until 639, and the header above it says "in words".** So a gate run on
  # the baseline arm printed `== which arm the entry image in out/ is, in words ==` and then nothing
  # about the arm - one line for this whole block, against 47 for the other arm, measured by extracting
  # the block and running it with each value. A reader cannot tell "the arm is 0" from "this revision has
  # no arm block", which is the shape this file names elsewhere and had here: a section that answers by
  # printing nothing. Only the *value* is new below; every sentence is the record's (the switch's
  # call-site guard, the two parked captures' keys, and 593's reason for the park group's absence).
  echo "  idle sleep (IDLE_NO_SLEEP=0): the arm that came back - 514's one repair IS in this image, so"
  echo "      \`SIGPdisabled\` is cleared once from \`__wrap_poll\` on pid 1's thread before the park's real"
  echo "      call and \`cpu_idle\` can leave by its SECOND door: **the window whose \`pop {fp, pc}\` is this"
  echo "      phase's frontier IS ENTERED, so everything below - the slot, the bracket, the window's two"
  echo "      ends and the seam - is narration about THIS arm, and its keys are expected PRESENT.** 533's"
  echo "      capture carries \`xnu_live_slot_cwe_win\` and \`xnu_live_pce_after_sctlr\`, which is the window"
  echo "      having been entered and read; 520's carries neither because its image predates the instrument,"
  echo "      which is why the pair and not one of them settles what this arm does."
  echo "      **On this arm an absent \`xnu_live_repair_seq\` is a bug rather than the switch** - the"
  echo "      converse of what the 1 arm's block says, and the pair is the reason this gate prints the arm's"
  echo "      value from the record before any run rather than leaving it to be inferred from the log after."
  echo "      Its death is the one both parked captures show and the reason this phase has a frontier at"
  echo "      all: the exit's \`push {fp, lr}\` / \`pop {fp, pc}\` inside \`platform_cache_idle_exit\`, with the"
  echo "      park's poll never returning. The park group's"
  echo "      \`cpu_signal_handler_internal(FALSE) called 1 time(s)\` is therefore **absent for that same"
  echo "      reason** - it prints only after the park's real poll returns, so on this arm the group's"
  echo "      absence says the park did not return and not that the repair was skipped."
fi
if [[ $V_SLOT_NULL -eq 1 ]]; then
  echo "  capture sites (SLOT_NULL=1): the NULL instrument - entry_slot_null_note publishes the pass"
  echo "      count alone, so the four slot words are neither loaded nor stored by this image and the"
  echo "      xnu_live_slot_{pre,post}_{sp,m16,m12,m8,m4} keys are expected ABSENT, not missing."
  # **And the run's own summary has to say that out loud, or the absence reads as agreement.** 583
  # built a four-state table on `slot_pre_m4` for this arm before 586 measured that this arm cannot
  # publish the key; the same step made the reader print an explicit UNREAD naming
  # `xnu_live_slot_pre_calls` where it used to print nothing. Whether the file in the tree does that
  # is read out of the file here rather than asserted, because a sentence about another file's
  # mechanics is a claim about that file's future (563) - and 586's own first version is the case in
  # point: the block was silent on exactly the arm this branch narrates.
  #
  # **And the read itself needs the ninth guard, because the two branches below are a verdict about
  # that file's contents.** `grep -q` returns 2 for a file it cannot open - absent, a directory, mode
  # 000 - so without these two lines an unreadable runner would take the `else` and the gate would
  # assert "does not name xnu_live_slot_pre_calls anywhere" about a file it never read. That is 584
  # section 2's R7/R8 shape exactly (a property asserted of an artifact by a comparison that never
  # ran), arriving one commit later inside the clause 586 added for the opposite reason - and it is
  # costly in the same direction, because the sentence that follows tells the operator to go and fix a
  # reader that may not be broken. The `-f` branch is here rather than in `_readable` because
  # `_readable`'s `-e`/`-r` pair is true of a directory of that name; the eight artifact sites above
  # each have their own `[[ -f ]]` for the same reason.
  [[ -f $SCRIPT_DIR/run_and_capture.sh ]] \
    || fail "no $SCRIPT_DIR/run_and_capture.sh, or it is not a regular file - this branch's sentence is about what that file's summary prints, so a gate that cannot open it has no verdict about what it does or does not name; and its absence also means the next command of the procedure cannot run at all. Nothing is rebuilt by this refusal"
  _readable "$SCRIPT_DIR/run_and_capture.sh" "the summary text this branch's sentence describes is read out of it"
  if grep -q 'xnu_live_slot_pre_calls=' "$SCRIPT_DIR/run_and_capture.sh"; then
    echo "      So a run of this arm prints two UNREAD lines for the slot's own capture, naming"
    echo "      xnu_live_slot_pre_calls - that is this switch and not a disagreement, and a successful"
    echo "      boot of this arm carries them. Read them as 'the comparison could not be made here'."
  else
    echo "      **And $SCRIPT_DIR/run_and_capture.sh does not name xnu_live_slot_pre_calls anywhere**, so"
    echo "      the summary of a run of this arm says NOTHING about the slot's own capture - neither a"
    echo "      reading nor an absence - and silence there is this project's own silence rule. Fix the"
    echo "      reader before spending a boot on this arm, or the run's verdict will look complete."
  fi
else
  echo "  capture sites (SLOT_NULL=0): the capture - eight loads and eight stores a pass, publishing the"
  echo "      four words of the idle exit's {fp, lr} slot at each of the two sites. That shape is present"
  echo "      in every image that did not return and absent from every one that did."
fi
echo "  bracket (pre note -> rtcpre note -> the real exit -> post note; 538 read the three call sites out of"
echo "      these very bytes): xnu_live_slot_pre_calls, xnu_live_slot_rtcpre_calls and"
echo "      xnu_live_slot_post_calls are published by the exit wrapper in the same pass, on one schedule"
echo "      and one gate - so pre without rtcpre localizes the death between the two notes, and pre and"
echo "      rtcpre without post puts it inside platform_cache_idle_exit, which is the localization this"
echo "      arm exists to buy. **xnu_live_slot_rtcab_* is NOT part of this bracket.** entry_stubs.c:1792"
echo "      publishes it from entry_note_sleh, the *abort* path, so it counts abort records and not"
echo "      entries: in 520's own log it has five (1,2,3,4,8), i.e. at least eight aborts, and a bracket"
echo "      read off it would put the window at eight entries when the exit wrapper's rtcpre has exactly"
echo "      one record. The entry-side pair is entry_trace.c:1973's rtcpre beside :1971's pre, and 556's"
echo "      narration below says the same pair."
if [[ $V_IDLE_CACHE_ENABLE -eq 1 ]]; then
  echo "  window's near end (IDLE_CACHE_ENABLE=1): entry_idle_cache_enable's one write to SCTLR.C IS in"
  echo "      this image, and xnu_live_slot_cwe_win (C clear, read with the cache still off) against"
  echo "      _cwe_set (C set, read back with it on) with _calls >= 1 is that write taking."
else
  echo "  window's near end (IDLE_CACHE_ENABLE=0): the SCTLR.C write is NOT in this image - the wrapper"
  echo "      calls entry_window_note(win, entry_sctlr()) with the register unchanged, so _cwe_win and"
  echo "      _cwe_set are the SAME value by construction and the pair says only that the site ran."
  echo "      **Agreement there is this arm's expected reading, not a failed enable.** The 526 narration"
  echo "      below predates this line; where its checklist and this derived line differ, this one governs."
fi
if [[ $V_EXIT_POC_FLUSH -eq 1 ]]; then
  echo "  window's far end (EXIT_POC_FLUSH=1): the exit-side FlushPoC_Dcache IS in this image - the one"
  echo "      operation this project has now twice seen a device not come back from. **Read where its site"
  echo "      is before reading this arm as the one under test: it is the FIRST statement of entry_trace.c's"
  echo "      __wrap_platform_cache_idle_exit, so it runs before that wrapper's own \`mov %0, sp\` and before"
  echo "      __real_platform_cache_idle_exit() - i.e. BEFORE the real exit's \`push {fp, lr}\`.** 565 section 2"
  echo "      measured what that costs: the seam 547 section 5 names for the next arm is the \`bl"
  echo "      FlushPoU_Dcache\` *inside* the real exit (the call this image's own ELF returns from at"
  echo "      0x800462dc), which is one call LATER than this flag's. A flush before the push cannot cover a"
  echo "      line the push has not written yet, so a run with this flag on does not test that arm, and"
  echo "      calling it that arm's run is one value with two definitions."
else
  echo "  window's far end (EXIT_POC_FLUSH=0): no exit-side flush of this image's own. That is an absence of"
  echo "      THIS flag and not evidence that the inner seam is absent: an arm that flushes inside the real"
  echo "      exit would arrive as its own switch, and the converse clause above refuses a record carrying a"
  echo "      switch this gate does not print - so such an arm cannot be booted with nobody having read it."
fi
if [[ $V_SEAM_MEASURE -eq 1 ]]; then
  echo "  the seam (SEAM_MEASURE=1): the interception IS in this image and **535's operation is NOT** -"
  echo "      this is 572's arm, the one seam's other arm. \`--wrap=FlushPoU_Dcache\` is in the link, so every"
  echo "      call site of that routine arrives at one wrapper, and the wrapper acts at exactly one: the call"
  echo "      whose return address is 0x800462dc - the \`bl FlushPoU_Dcache\` *inside* the real"
  echo "      platform_cache_idle_exit, AFTER that function's \`push {fp, lr}\` and BEFORE its \`pop {fp, pc}\`."
  echo "      What it does there is a \`dsb\`, the slot's two words read, Apple's own L1 flush through, the two"
  echo "      words read again - and nothing else: no \`FlushPoC_DcacheRegion\`, no clean, no invalidate, and"
  echo "      no store **to the slot** - this routine's stores are its own prologue's saves and its counting"
  echo "      words, counted out of this image below. 535's run did not come back and left no log, so \"the"
  echo "      operation cost the return\" and \"the interception did\" are still joined; this arm is the cell"
  echo "      that separates them,"
  echo "      and it is safe by construction because it cannot write the line at all. **So read its pair the"
  echo "      other way round**: with nothing behind it the two reads are of a line only Apple's flush touched,"
  echo "      an UNEQUAL \`b\`/\`a\` pair is that flush writing the line back, and an *equal* pair is the arm"
  echo "      working as designed - where in 535's arm an unequal pair is the operation's own write-back."
  echo "      **That rule presumes the run has a pair, so it needs the arm to be known from the log:** if"
  echo "      this run's log carries no \`xnu_live_seam_*\` keys at all, there is no \`b\`/\`a\` pair to compare,"
  echo "      and the rule above is NOT applied - not read as \"working as designed\" for the want of an"
  echo "      unequal pair. **That absence has two causes and one of them is this record's own switch:**"
  echo "      either the seam was never reached, or this image is *also* the sleepless arm"
  echo "      (\`IDLE_NO_SLEEP=1\`), where the acting site is unreachable by construction - the idle block"
  echo "      above says which of the two this record is, and on that arm the keys are absent on an image"
  echo "      that genuinely carries the arm, so its keyless log is NOT evidence about the seam at all."
  echo "      run_and_capture.sh's own clause dispatches the same"
  echo "      three ways this narration does (working as designed / the L1 flush writes the line back / unread"
  echo "      and the pair not interpreted), and the two readers must tell one story."
  if [[ $V_IDLE_NO_SLEEP -eq 1 ]]; then
    echo "      **The published arm key says 0 here, and on this record it still does not mean \"no seam\" - but"
    echo "      the usual way of telling those two apart does not run here:** \`xnu_live_seam_op\` publishes"
    echo "      SEAM_POC, so a measure arm and a no-seam arm both show it at 0, and the separator that"
    echo "      sentence used to name (\`xnu_live_seam_calls\` present) is FALSE on this record - the pair keys"
    echo "      are an expected absence above, so *presence* cannot be the test that separates them here."
    echo "      **No key in this run's log separates them**, so this paragraph is narration about an arm this"
    echo "      one is not: read the idle ladder instead, which is the ladder this arm can produce."
    echo "      **And the next sentence is that other arm's proof too:** 565 section 3's table and 547"
    echo "      section 4's enable cells both presume a run that reaches the window, and this one leaves by"
    echo "      the first door on every pass - so its proof is the ladder and the return, not a death shape."
  else
    echo "      **And the published arm key says 0 here, which does not mean \"no seam\":** \`xnu_live_seam_op\`"
    echo "      publishes SEAM_POC, so this run and a no-seam run both show it at 0. They are told apart by"
    echo "      whether the \`xnu_live_seam_*\` keys were written at all - for this arm \`xnu_live_seam_calls\` is"
    echo "      present - and a reader that read op=0 as the no-seam arm would be reading two arms as one"
    echo "      (absent is not zero, 569's reading and 526's distinction)."
    echo "      **Read this run against 565 section 3's table and not against 547 section 4's enable cells: this"
    echo "      arm is a state change at the seam itself, so its proof is the death's shape - recovered, or still"
    echo "      at the pop - and not the value of a key.**"
  fi
  echo "      **The body this paragraph describes is read out of this image and not out of the record, at"
  echo "      \"== the seam's own body, read out of this image and not out of the record ==\" below.**"
elif [[ $V_SEAM_POC -eq 1 ]]; then
  echo "  the seam (SEAM_POC=1): the interception IS in this image, and 535's arm is the record above with"
  echo "      this one key at 1. \`--wrap=FlushPoU_Dcache\` is in the link, so every call site of that routine"
  echo "      arrives at one wrapper, and the wrapper acts at exactly one: the call whose return address is"
  echo "      0x800462dc - the \`bl FlushPoU_Dcache\` *inside* the real platform_cache_idle_exit (547 section"
  echo "      5's seam), AFTER that function's \`push {fp, lr}\` and BEFORE its \`pop {fp, pc}\`. Every other"
  echo "      site is handed straight through. The operation is Apple's own \`FlushPoC_DcacheRegion\` over the"
  echo "      slot's eight bytes, bracketed by \`dsb\`, with the two words read either side of it. The readings"
  echo "      are the \`xnu_live_seam_*\` keys: the site's own \`calls\` and \`lr\`, the slot before (\`b0\`,"
  echo "      \`b1\`) and after (\`a0\`, \`a1\`), and \`other\`/\`other_lr\` for the calls handed through - which"
  echo "      is how a run shows the site test did not divert a call that is not the seam."
  echo "      **Read this run against 565 section 3's table and not against 547 section 4's enable cells: this"
  echo "      arm is a state change at the seam itself, so its proof is the death's shape - recovered, or still"
  echo "      at the pop - and not the value of a key.** Note also what this flag is NOT: it is not"
  echo "      EXIT_POC_FLUSH, whose flush is the first statement of the exit *wrapper* and therefore runs before"
  echo "      the real exit's \`push\`; that call cannot cover a line the push has not written yet, and one"
  echo "      name for the two arms is one value with two definitions."
else
  echo "  the seam (SEAM_POC=0, SEAM_MEASURE=0): NO interception of this image's own - no"
  echo "      \`--wrap=FlushPoU_Dcache\`, so no wrapper of ours sits between the real exit's \`push {fp, lr}\`"
  echo "      and its \`pop {fp, pc}\`, and the flush inside that function is Apple's own. **Both seam keys are"
  echo "      at 0 here, which is the only state this paragraph is printed in**: with either at 1 the"
  echo "      interception is in the link, so a 0 beside a 1 above is an arm and not this. The exit's call is"
  echo "      untested by such a run: this is the arm 568 already ran (533's configuration), so a record with"
  echo "      both keys at 0 is a re-run of that arm and not a test of 535 - 547 section 5's seam is unprobed,"
  echo "      and an absent flag here is an absent interception, not an absent problem."
fi
if [[ $V_ISTACK_SEPARATE -eq 1 ]]; then
  echo "  interrupt stack (ISTACK_SEPARATE=1): separate from the boot thread's, so an interrupt-path"
  echo "      fault is not a fault on the stack the boot is using."
else
  echo "  interrupt stack (ISTACK_SEPARATE=0): SHARED with the boot thread's - an interrupt-path fault"
  echo "      lands on the same stack the boot is using and must not be read as the cache first."
fi
if [[ $V_IDLE_STACK -eq 1 ]]; then
  echo "  idle stack (IDLE_STACK=1): the wrapper is in this image."
else
  echo "  idle stack (IDLE_STACK=0): the wrapper is NOT in this image."
fi
echo "  and the count keys are a schedule, never a total: n publishes while n <= 4 and then at the powers"
echo "      of two (entry_slot_publish, entry_stubs.c:6236), so a published 4 means AT LEAST four - which"
echo "      is why a count read as a total is 406's tell and not a reading."

echo
echo "== the entry image's own sources =="
# **Is this entry image the build of the tree in front of it - asked by content, because the question
# the gate used to ask it with was an mtime and the answer was wrong.** The entry sources used to sit
# in the freshness sweep above, compared against the *payload image's* mtime: a file the payload's
# build never opens, so committing an edit to `build_entry.sh` moved its mtime past the image the
# same file had just produced and the gate refused a tree that was byte-identical to what it was
# built from. Rebuild was the prescribed remedy and the wrong one here - 408, the payload link does
# not reproduce - so the repair is to ask the question the refusal was standing in for.
#
# `build_entry.sh` writes `out/xnu_arm_entry-sources.txt` beside the image: every regular file in
# `src/entry/`, hashed, with the image's own sha256 on its second line. This recomputes the same
# list by the same rule and refuses on any difference, which catches three things the mtime sweep
# either missed or got backwards:
#
#   1. an entry source edited and the image not rebuilt - the case the sweep existed for, now caught
#      by content rather than by a timestamp that a `git checkout` also moves;
#   2. a source *added or removed* since the build, in either direction: a file the manifest lists and
#      the directory no longer has, and a file the directory has that the manifest never saw. The
#      mtime sweep could only see the second, and only if the new file's mtime happened to be newer;
#   3. the case the sweep produced a false refusal for - a checkout, or a commit, that rewrote an
#      unchanged file. Same bytes, no difference, no refusal, which is what "unchanged" should mean.
#
# **And it closes a blind spot the sweep had from the day it was written: `*.S` is case-sensitive
# and every assembly source in that directory is lowercase `.s`.** `entry_vectors.s`,
# `entry_ramdisk.s`, `entry_macho.s`, `entry_arm_rtabi.s` and `assym.s` are all inputs to this image
# and not one of them was ever compared with anything. That is not a property of the fix being
# weaker than the sweep; it is the fix being the first check that ever looked at those files.
#
# Bound to the artifact the same way the switches are: the manifest's `STAGE90_XNU_ENTRY_SHA256` line
# must be the hash of the entry bin on disk, so a manifest left over from an earlier build cannot be
# read as this one's - which is the one way a content check can be satisfied by the wrong content.
ENTRY_SRC_MANIFEST=$OUT/xnu_arm_entry-sources.txt
[[ -f $ENTRY_SRC_MANIFEST ]] \
  || fail "no $ENTRY_SRC_MANIFEST - build_entry.sh writes it beside the image, and without it nothing compares the entry image with the sources it claims to be built from. Rebuild the entry image (src/entry/build_entry.sh)"
_readable "$ENTRY_SRC_MANIFEST" "the list of sources this entry image claims to be built from is read out of it"
manifest_sha=$(awk -F= '$1 == "STAGE90_XNU_ENTRY_SHA256" { print $2 }' "$ENTRY_SRC_MANIFEST")
[[ -n $manifest_sha ]] \
  || fail "$ENTRY_SRC_MANIFEST has no STAGE90_XNU_ENTRY_SHA256 line - a manifest bound to no artifact can be satisfied by any content"
[[ "$manifest_sha" == "$actual_sha" ]] \
  || fail "$ENTRY_SRC_MANIFEST was written for entry image $manifest_sha and $ENTRY_BIN is $actual_sha: the source list describes a different build, so it can say nothing about this one. Rebuild the entry image, then ./build.sh"
# The recorded list is `name hash` so the two sides of `comm` sort by name and a changed file appears
# once from each side - which is what lets the refusal name it rather than report a count.
#
# **`$2`, not `$3`, and the difference is every run.** The manifest is written as `hash` + **two**
# spaces + `name`, and awk's default field splitting collapses a run of whitespace into one separator,
# so that line has **two** fields: `$1` is the hash and `$2` is the name - there is no `$3`. Written
# as `$3 " " $1` this produced a leading space and the hash and **dropped the filename**, which is
# measured on the real directory rather than argued: the writer's own pipeline and this one both run
# over `src/entry/` give `comm -3` **40 lines for 20 files** - every file reported
# as both changed and added, with `comm` additionally printing `file 2 is not in sorted order`,
# because the space-prefixed lines sort differently from the `name hash` ones. The refusal would then
# name **hashes** where it promises filenames. With `$2` the same two pipelines give **0**. So the
# pattern was right - it is the one that matches the writer's two spaces - and the field was wrong,
# which is the shape this project records as a reader that recognises a shape and then consumes the
# wrong subject. Two implementations of one rule is the oldest defect here; this is the seam where
# they meet, so it is asserted by running both against the real directory rather than by eye.
ENTRY_SRC_RECORDED=$(awk '/^[0-9a-f][0-9a-f]*  / { print $2 " " $1 }' "$ENTRY_SRC_MANIFEST" | LC_ALL=C sort)
# `|| true` for the same reason as the sweeps above: a `find` that cannot read the directory exits
# non-zero, and under `set -e` the assignment would end the script with no message at all - a scan
# that could not look is not a scan that found nothing, in the direction that fails quietly.
ENTRY_SRC_NOW=$(cd "$SRC_DIR/entry" 2>/dev/null && find . -maxdepth 1 -type f -printf '%f\n' 2>/dev/null | LC_ALL=C sort \
                | while IFS= read -r _f; do
                    printf '%s %s\n' "$_f" "$(sha256sum -- "$_f" | awk '{print $1}')"
                  done || true)
# **A scan that could not look must not be reported as a tree that changed, and without this line it
# was.** The `|| true` above keeps a directory `find` cannot read from ending the script with no message
# at all - but it also makes that failure silent in a misleading direction: with `ENTRY_SRC_NOW` empty,
# *every* recorded file appears as a difference, and the clause refuses with "the entry image is not the
# build of these sources", naming all twenty of them. Measured by pointing `SCRIPT_DIR` at a directory
# that has no `src/entry/` under it: the output began `  on disk:  ` with no filename at all - a line
# whose second column is empty - and then listed all twenty names under `manifest:`, which is the same
# 40-lines-for-20-files signature the `$2`-vs-`$3` field defect produces, arrived at from the other side.
# The distinction the `|| true` was written to preserve is exactly the one it loses, so it is asserted
# here rather than assumed: an empty scan is a tool that could not reach the directory, and the honest
# answer to "did the sources change" is then "nothing was read", not "all of them did".
[[ -n $ENTRY_SRC_NOW ]] \
  || fail "the scan of $SRC_DIR/entry produced no files at all, while the manifest names $(printf '%s\n' "$ENTRY_SRC_RECORDED" | grep -c . || true) - so this is a scan that could not look, not a tree in which every source changed. Check that the directory exists and is readable before reading this clause's answer as one about content"
# **`LC_ALL=C` on `comm` itself, not only on the sorts that feed it - because the two sides were
# sorted in one locale and compared in another, and `comm` says so out loud.** Run under this host's
# ambient `LANG=en_US.UTF-8` against the real `src/entry/`, the line below printed
# `comm: file 1 is not in sorted order`, `comm: file 2 is not in sorted order` and
# `comm: input is not in sorted order`, and exited 1. Both files *are* sorted - by `LC_ALL=C`, three
# lines up - and glibc's `en_US.UTF-8` collation ignores punctuation at the primary level, so it orders
# the same twenty names differently from C: C puts `.gitignore` first and `entry.ld` fourth, the ambient
# order puts `.gitignore` **last** and `entry.ld` ninth. That is not cosmetic, because `comm` merges by
# walking two files in lockstep and comparing adjacent lines: an order the two sides do not agree on is
# the assumption the merge is built on, and the answers it can give instead are a line present in both
# files reported as a difference, or a differing line matched against the wrong counterpart. Measured
# both ways on one pair: `comm -3` -> three warnings, exit 1; `LC_ALL=C comm -3` -> exit 0, no output.
# One rule, one locale, so the clause's answer cannot depend on the environment of whoever runs the gate.
ENTRY_SRC_DIFF=$(LC_ALL=C comm -3 <(printf '%s\n' "$ENTRY_SRC_RECORDED") <(printf '%s\n' "$ENTRY_SRC_NOW") | LC_ALL=C sort || true)
if [[ -n $ENTRY_SRC_DIFF ]]; then
  ENTRY_SRC_NAMES=$(printf '%s\n' "$ENTRY_SRC_DIFF" | awk 'NF { print $1 }' | LC_ALL=C sort -u | tr '\n' ' ')
  echo "files that differ from the manifest $ENTRY_SRC_MANIFEST was written with:"
  # `s/^/` PREFIXES and `s/^[^ \t]/` REPLACES - and the difference is a character of the filename.
  # Written with the second form, the "changed" line below printed `ntry_arm_rtabi.s`, one letter
  # short, because `sed` was substituting the label *for* the first character instead of putting it in
  # front of the line. Measured on a manifest with one hash altered. The labels are also now the two
  # sides of `comm` rather than a claim about what happened: column 2 is what is on disk, column 1 is
  # what the manifest recorded, and a file whose content changed appears **once in each** - so
  # "added"/"changed" was a guess at an intent the comparison does not compute, while the summary
  # above it already names each file once. `comm -3` prints the second column with a leading TAB.
  #
  # **`t` is load-bearing and its absence is visible in the output.** Two `s` commands in one `sed`
  # both run over the line: without `t`, the relabelled `on disk` line is fed straight into the second
  # substitution and prints as `  manifest:   on disk:  <name>`, carrying *both* labels - measured on
  # the same altered-hash manifest, and it reads as a claim about both sides at once. `t` branches to
  # the end on a successful substitution, so the two labels are mutually exclusive: TAB -> `on disk`,
  # no TAB -> `manifest`.
  printf '%s\n' "$ENTRY_SRC_DIFF" | sed 's/^\t/  on disk:  /; t; s/^/  manifest: /' | awk 'NF'
  echo "  (manifest bound to entry image $manifest_sha, $ENTRY_BIN's own hash)"
  # **539: this clause fired for real, and the remedy it printed first was the harmful one.**
  # Measured 2026-09-22: a build input in src/entry/ was edited *after* the frozen entry image was
  # built - the manifest recorded `build_entry.sh 68528ccb...` where the file on disk was
  # `1b4e549a...`, and the committed version a third hash again - so the gate refused, correctly. But
  # the text then said "rebuild the entry image **and then ./build.sh**", and that second half is the
  # one instruction this phase cannot follow: a plain `./build.sh` rebuilds the payload WITHOUT the
  # `STAGE90_XNU_ENTRY=1` switch this arm needs (that switch's default is OFF - `check_payload_config_entry`
  # measures it), so it overwrites `out/stage90/` with an image that never jumps into XNU and **spends the
  # freeze** - the frozen `1daaf44e...` that is the whole point of the arm being ready, and after a source
  # change the only place it still exists is its park (`tools/verify_revert_set.sh DIR --set=NAME`).
  # **The reason this comment used to give - "the payload link does not reproduce (408)" - was wrong, and
  # 763 corrected it here and at the refusal below**: 666 section 5 built the payload three times, twice
  # plain and identical, and a parked arm rebuilt from the tree with all seven members identical - and
  # 408's own 48 bytes are exactly this switch (`kernel_size` 6,015,356 with it against 6,015,308
  # without). **The cost of a careless `./build.sh` is the SWITCH and not nondeterminism.** The distinction the clause was missing is not "did a
  # source change" (that is what it just proved) but **did the change reach the compiler**. A build
  # *recipe* can change without changing the bin - the measurement above is 152 inserted shell lines
  # and no compiler input - and in that case the entry rebuild alone settles everything: it rewrites
  # the manifest, and a byte-identical bin leaves the payload's embedded blob, and therefore the boot
  # image, exactly as they were.
  #
  # So the gate stops presuming which of the two it is and names the test that answers it, because the
  # gate cannot run that test itself (it would have to rebuild, and a gate that rebuilds is not a
  # reading of the artifact it is about). This is the same rule the freshness refusal above states for
  # mtime - the gate cannot tell an edit from a checkout, so it says so rather than prescribing - and
  # the same reason that clause now carries the switches the run needs. What is *not* left to prose is
  # the hash to compare against: the record's own `STAGE90_XNU_ENTRY_SHA256`, read 60 lines above.
  fail "the entry image is not the build of these sources: $ENTRY_SRC_NAMES. Two situations print this line and the gate cannot tell them apart, so it names the test rather than presuming the answer. First rebuild the entry image with the switches this arm needs - they are printed under \"the entry image's own switches\" above, and naming them is the whole rebuild: src/entry/build_entry.sh is byte-for-byte reproducible and writes nothing the payload reads except the bin. Then compare: if sha256sum out/stage90/xnu_arm_entry.bin still equals the STAGE90_XNU_ENTRY_SHA256 the record names, the changed source fed no compiler input, the payload's blob clause is already satisfied, and ./build.sh must NOT be run for it - a plain ./build.sh rebuilds the payload WITHOUT this arm's STAGE90_XNU_ENTRY=1 switch (that switch's default is OFF), so it overwrites the armed image in out/ with one that never jumps into XNU, and after a source change the armed bytes then exist only in their park (tools/verify_revert_set.sh restores them). The build itself is not the hazard: 666 section 5 measured it reproducible - three builds, twice plain and identical, and a parked arm rebuilt from the tree with all seven members identical - and 408's own 48 bytes ARE this switch. This sentence cited \"it does not reproduce (408)\" before 763 corrected it. If the hash differs, the arm really is a new one and ./build.sh is owed, with STAGE90_EXTRA_CFLAGS='-DSTAGE90_XNU_ENTRY=1' or the new image never jumps into XNU. Neither branch is a checkout: a commit or a git checkout that rewrites an unchanged source still reaches this line, and here that case is free, because the rebuild is reproducible and the hash test settles it in one command"
fi
echo "the entry image is the build of src/entry/ as it stands: $(printf '%s\n' "$ENTRY_SRC_NOW" | grep -c . || true) file(s), every one matching the manifest, and none the manifest does not name"

echo
echo "== the arm the record owes =="
# **660 section 3, repaired.** Every clause above asks whether this tree is the build of the image
# in front of it - a question a REBUILD answers "yes" to *by construction*, because
# `build_entry.sh` rewrites `xnu_arm_entry-config.txt` and `xnu_arm_entry-sources.txt` **bound to
# the new image's hash**. So the chain was satisfied by any internally consistent tree, and
# nothing asked *which arm* these bytes are. This does, and it reads the one record in the chain
# the build never writes: `records/revert-set.txt`, whose own header says it plainly -
# *"a record the build writes agrees with itself and constrains nothing"*.
#
# The question: do the bytes in $OUT equal, file for file, ONE of the sets recorded there?
#
#   * A rebuild of UNCHANGED sources passes, and that is correct rather than a loophole: the entry
#     build is byte-for-byte reproducible, so such a rebuild reproduces the same hashes.
#   * A rebuild of a CHANGED source is a set nobody recorded, and is refused.
#   * A set MIXED from two arms is refused even though every file matches some recorded set - which
#     is what the readiness tool's `--set` argument prevents by name and this clause cannot.
#   * The near-miss is named (`10/11 [differ: xnu_arm_entry.bin]`), so the operator sees *how* it is
#     wrong and not only *that* it is.
REVERT_RECORD=$REPO_ROOT/records/revert-set.txt
_readable "$REVERT_RECORD" "the sets this project can revert out/ to are read out of it"
_arm_match=""
_arm_partial=""
_arm_sets=$(grep -o '^set=[^ ]*' "$REVERT_RECORD" | sed 's/^set=//' | LC_ALL=C sort -u)
for _s in $_arm_sets; do
  _tot=0
  _hit=0
  _bad=""
  while IFS= read -r _line; do
    _f=$(printf '%s\n' "$_line" | sed -n 's/.*[ ]file=\([^ ]*\).*/\1/p')
    _h=$(printf '%s\n' "$_line" | sed -n 's/.*[ ]sha256=\([0-9a-f]\{64\}\).*/\1/p')
    [[ -n $_f && -n $_h ]] || continue
    _tot=$(( _tot + 1 ))
    if [[ -r $OUT/$_f ]] && [[ $(sha256sum "$OUT/$_f" | awk '{print $1}') == "$_h" ]]; then
      _hit=$(( _hit + 1 ))
    else
      _bad="$_bad $_f"
    fi
  done < <(grep "^set=$_s " "$REVERT_RECORD")
  echo "  set $_s: $_hit/$_tot file(s) of out/ match${_bad:+   [differ:$_bad]}"
  # A set the record names but whose lines could not be read (_tot 0) must not match, or a record
  # made unreadable would pass every press - which is the silent-success shape this file keeps
  # paying for.
  if [[ -z $_arm_match ]] && (( _tot > 0 && _hit == _tot )); then
    _arm_match=$_s
  fi
  if (( _hit > 0 && _hit < _tot )); then
    _arm_partial="$_arm_partial $_s($_hit/$_tot)"
  fi
done
if [[ -z $_arm_match ]]; then
  fail "the bytes in $OUT are NO set recorded in $REVERT_RECORD${_arm_partial:+, nearest:$_arm_partial}. **Nothing has been sent.** Either out/ is mid-edit - rebuild it, or put the parked set back - or these are a NEW arm, in which case record them in $REVERT_RECORD in the step that MEASURED them: that record is written by hand and never by the build, and that is the only reason it can constrain anything. A new arm must be recorded BEFORE its press, or this clause cannot tell it apart from a mistake"
fi
echo "the bytes in $OUT are the recorded set '$_arm_match', file for file; the other $(($(printf '%s\n' "$_arm_sets" | grep -c .) - 1)) recorded set(s) do not match"

echo
echo "== storage tripwire =="
# Two independent checks, because they catch different things and only one of them is
# sufficient. Symbols catch a NAMED storage reference. Addresses catch an unnamed one - a raw
# store to a controller register - which is the plausible case here, since the payload
# already writes raw literals to PS_HOLD and IMEM.
#
# Verified by negative test: with a deliberate `*(volatile uint32_t *)0xf9824000u = 1;`
# added to the payload, the symbol check below found NOTHING and would have approved the
# run. The address check caught it. Both are kept because the symbol check is cheap and
# catches a different shape.
# **661: the patterns are anchored, and the rule is a DELIMITER rather than a word boundary.**
# `\b` treats `_` as a word character, so `\bpartition` does not match `bdev_partition_scan` and
# `\bmmc\b` does not match `mmc_host_alloc` - measured on a synthetic positive control of nine
# storage-shaped names, the pattern below catches 9/9 where the old one caught 8/9. The old pattern
# was also noisy in the other direction: it matched **25** symbols in the entry image and all 25
# were false positives (`ufs` inside `bufsize`/`nkdbufs`/`ubc_upl_maxbufsize`, `partition` inside
# IODTNVRAM's `getNVRAMPartitions`), which is why 658 section 3(a) could not simply widen this
# check's scope. The pattern is fixed here, so the scope is widened with it: the check now covers
# the image the payload *jumps into* and not only the payload, and both real images come out at 0.
# The remaining hole is named rather than papered over: a **camelCase** storage name
# (`AppleSDXCController_probe`) still matches nothing, because a delimiter rule needs a delimiter.
# This is a heuristic - which is what `check_storage_refs.py` says of itself too.
# **954: NOT `nm -a`.** `-a` adds STT_FILE debug symbols - a compilation unit's *file name*, kept
# even when the linker's dead-code pass has discarded every function in it. On D13 the entry link's
# whole-kernel pool carries a storage module 4570's does not (`.../AppleARMPlatform/leo_sdcc.o`), and
# the GC kept only its STT_FILE name: a `leo_sdcc.c` line with value 0 and NO `leo_sd_*` function in
# the image (measured - `leo_sd_init`/`leo_sd_read_sector`/`leo_sd_write_sector` are all `T` in the .o
# but absent from the ELF). A name with no code is not a reference, and matching it made the tripwire
# red on every D13 arm. Plain `nm` lists FUNCTIONAL symbols (`T`/`t`/`D`/… ) and no STT_FILE, which is
# what this check has always meant. It still catches the shape it is for: a linked storage function
# (`mmc_*`, `sdhci_*`) is a `T` symbol and still matches.
STORAGE_SYM_RE='(^|[^A-Za-z0-9])(sdcc|emmc|nand|mmc|ufs|flash|partition)'
_storage_sym_hit=0
for _img in "$OUT/stage90.elf" "$OUT/xnu_arm_entry.elf"; do
  [[ -r $_img ]] || fail "no $_img - the symbol half of the storage tripwire now reads two images, and a clean answer from the other one would say nothing about this one"
  if arm-none-eabi-nm "$_img" 2>/dev/null | grep -iE "$STORAGE_SYM_RE"; then
    echo "  ^ in $(basename "$_img")"
    _storage_sym_hit=1
  fi
done
if (( _storage_sym_hit != 0 )); then
  fail "storage symbols in the payload or in the image it jumps into (see above) - the pattern is anchored on a delimiter, so a hit here is a storage-shaped NAME and not a substring of one"
fi
echo "no storage symbols in the payload or in the entry image it jumps into"

if [[ -x $REPO_ROOT/tools/check_storage_refs.py ]] || [[ -f $REPO_ROOT/tools/check_storage_refs.py ]]; then
  "$PYTHON" "$REPO_ROOT/tools/check_storage_refs.py" "$OUT/stage90.elf" \
    || fail "payload addresses a storage controller (see above)"
else
  fail "tools/check_storage_refs.py missing - the address half of the storage tripwire cannot run"
fi

echo
echo "== recovery net =="
# Two independent nets. The hardware watchdog is the one that matters, because it does
# not depend on the GIC, the timer, IRQ delivery or IRQs being unmasked - any of which
# may be exactly what broke in a given hang.
case "$HWWDT" in
  STAGE90_HW_WATCHDOG_ARMED|1|1u)
    echo "hardware watchdog: ARMED. The SoC resets itself if the payload stops making"
    echo "                   progress, whatever the CPU is doing - and platform_reboot()"
    echo "                   forces a bite so the reboot does not depend on PS_HOLD."
    ;;
  STAGE90_HW_WATCHDOG_DISABLED|0|0u)
    echo "WARNING: STAGE90_HW_WATCHDOG=disabled - there is NO hardware reset net."
    echo "         A hang that the software dead-man cannot see will need a manual"
    echo "         power-button hold."
    ;;
  *)
    fail "unrecognised STAGE90_HW_WATCHDOG: $HWWDT"
    ;;
esac

if [[ $DEADMAN != "1u" ]]; then
  echo "WARNING: STAGE90_DEADMAN_ENABLE=$DEADMAN - the software dead-man net is off."
else
  echo "software dead-man: armed (60s), as a second net."
fi

# **The net's record in *this* arm, because the line above promises a net that has not fired in it.**
# The paragraph above is about the mechanism ("whatever the CPU is doing"); what an operator needs at
# the moment of a hang is whether it has actually worked in the configuration they are about to boot.
# For the XNU-entry arm the last four hangs say it has not:
#
#   * **517's first run, 521, 522 and 526 did not come back, and each needed a power press.** 526's is
#     measured on this host rather than taken from a ledger: its `usb 3-10` fastboot device
#     disconnected at 16:35:47 and the port has been silent since - over two hours, against a bite due
#     28 s after the arming.
#   * **and the arm itself is the payload's, taken before the jump.** `0xf9017000` is named in exactly
#     one place in this tree - `hw_watchdog.c:94` - and `stage90_main.c:1205` arms it before
#     `stage90_xnu_entry_call()` transfers control. So the question this paragraph can answer is the
#     narrow one: does the image that runs *after* the jump carry an address in the watchdog's page?
#     As of this commit that is measured at gate time instead of asserted in prose - the clause below
#     scans the entry image for the three ways an instruction can carry an address (a literal-pool
#     word, a `movw`/`movt` pair, a `mov`/`mvn` immediate) and finds `[0xf9010000, 0xf901ffff]` empty
#     in all three, with a witness one nibble below that is not empty. **The claim is deliberately
#     narrower than "nothing can reach the watchdog's registers"**, and the reason is worth stating
#     where the check prints: the watchdog shares its 1 MB section with the GIC (`hw_watchdog.c:53`)
#     and `entry_gic.c:377` maps exactly that section at run time, so an image can reach the registers
#     without materialising an address in the page. What is established is what it says: no code in
#     this entry image carries one. The four hangs are not "the net was turned off" - the arm is the
#     payload's and it stays armed - but *why* they did not come back is not measured here, and the
#     next two readings (the four non-returns, and the returns that came back on XNU's own reset) are
#     all this paragraph claims.
#   * the last three *returns* (518, 519, 520) came back with XNU's own panic and its own
#     `Attempting system restart...MACH Reboot` in their logs, so XNU reset the machine itself. Whether
#     the net was also due around then cannot be settled from those logs - the payload's output carries
#     no timestamps - and the host's USB log can settle it (jump -> return) only while the ring buffer
#     still holds the run. What is not in doubt is that a `MACH Reboot` is a return path that does not
#     need the net.
#
# So this is printed for the XNU-entry arm only, and it does not claim the net is broken - 506-515's
# ledger says it has recovered runs, and those logs are not in hand to say whether the recovery was the
# net or a panic-driven `MACH Reboot`, which is the same conflation as the third bullet. What it claims
# is what has been measured *here*: **a hang in this arm should be expected to need a power press, and
# the log goes with it.**
if [[ $ALLOW_XNU_ENTRY -eq 1 ]]; then
  echo "MEASURED, this arm: the last four hangs (517's first run, 521, 522, 526) did NOT come back"
  echo "         and each needed a power press - 526's port has been silent for hours against a bite"
  echo "         due 28 s after the arming. Why they did not come back is NOT measured: the entry"
  echo "         image carries no address in the watchdog's page, which is checked below, but that is"
  echo "         not the same as unreachable - the watchdog shares its 1 MB section with the GIC, and"
  echo "         this image maps that section. Expect a power press, and expect the log to go with it."

  # **Whether the entry image can reach the net, measured here instead of asserted in prose.** An
  # instruction can carry an address in three ways, and all three are scanned: a literal-pool word (an
  # aligned `0xf901xxxx`, reached by `ldr rN, [pc, #imm]`), a `movw`/`movt` pair (caught by
  # `movt rD, #0xf901`, whose imm16 high half is the page), and a `mov`/`mvn` immediate. The last two
  # are matched out of the words rather than disassembled, and that is the whole point of doing it
  # here: **this ELF declares no arch in `e_flags` and its `BuildAttributes` block is empty, so
  # `llvm-objdump` defaults to a pre-ARMv7 decoder on it and prints `.word` for every `movw`, `movt`,
  # `ubfx` and `dmb` in the file** - 118,621 of them over 1.38 M words, with a `movw`/`movt` count of
  # zero. A search run that way answers "nothing materialises the watchdog's page" while being unable
  # to see the two encodings most likely to carry it, which is this project's own rule: before
  # concluding a value is absent, establish that the extractor could have seen it.
  # (`llvm-objdump --triple=armv7-none-eabi` is the decode that can, and against it these counts agree
  # exactly where it matters: 8 `movt rD, #0xf900` and 5 `mov` in the witness, 0 of both in the page.
  # The printed `movt` counts are ceilings because the mask frees the condition field - 17 for that
  # witness against the disassembler's 8, the extra nine being data words that share the low half -
  # which is the safe direction for a page that must read zero and harmless for a witness.)
  #
  # Two readings make a zero readable instead of merely quiet. The **witness** is one nibble below the
  # page: the GIC's `0xf9000000` and `0xf9002000` are in this image and it uses both, so the same
  # three reads must find them, and if they do not, the zero above is the scan failing rather than the
  # property holding. The **positive control** is the payload, which arms the net: it carries
  # `movt rD, #0xf901` ten times, so the form is demonstrably visible to this instrument on a real
  # artifact. A refusal is a build-stop and not a warning: a run of an image that carries the page
  # would be a run whose only net is the one under suspicion.
  echo
  echo "== the net's reach in the entry image =="
  if ! "$PYTHON" - "$ENTRY_BIN" "$PAYLOAD_BIN" "$OUT/xnu_arm_entry.elf" "$OUT/stage90.elf" <<'PY'
import struct, subprocess, sys

# The three encodings one or two instructions can carry an address in, over two ranges: the watchdog's
# page, and the GIC one nibble below it - the witness that the scan can see anything at all.
ENTRY, PAYLOAD, ENTRY_ELF, PAYLOAD_ELF = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
WATCH_LO, WATCH_HI = 0xf9010000, 0xf901ffff
WIT_LO, WIT_HI = 0xf9000000, 0xf900ffff

# ** A NAMED DATA OBJECT IS NOT A LITERAL POOL, and this clause counts literal pools. ** The census
# below matched a bare `0xf901xxxx` word anywhere in the flat image, and until the HFS+ port was
# linked into the entry image (895's step) nothing in it happened to carry one. The port brings 2050's
# Unicode tables, and `cjk_bitmap` (`hfs_encodings.c`, 0x28d8 bytes of CJK coverage bitmaps) contains
# exactly one word in the page - `0xf9011f7f` at VA 0x805296f0 - which is DATA, reached by no `ldr`,
# and materialises no address. The scan cannot tell it from a literal-pool word because the entry's
# linker script folds `.rodata` into the output `.text` (entry.ld: *".text (incl. .rodata ...)"*), so a
# data table and a literal pool are the same PROGBITS section and the same flat `nm`/bin bytes.
# readelf still separates them: the word is inside a named `OBJECT` symbol. So the scan now excludes
# every named `OBJECT` span before counting, which is the property the paragraph claims - **no CODE
# carries the page** - rather than "no word of any kind does". The exclusion is by symbol, so it is
# re-derived from the artifact: a data table that grows or moves is excluded wherever it lands, and a
# genuine literal pool (not a named object) is still counted. The positive control below is unaffected:
# the payload's `movt` sites are code, not named objects.
def load_base(elf):
    out = subprocess.run(["readelf", "-lW", elf], stdout=subprocess.PIPE, text=True).stdout
    for line in out.splitlines():
        f = line.split()
        if len(f) >= 3 and f[0] == "LOAD":
            return int(f[2], 16)          # the lowest LOAD vaddr; both images have exactly one
    return None

def obj_spans(elf, base, nbytes):
    # Every named OBJECT symbol's [vaddr, vaddr+size) span, mapped to bin offsets (bin = VA - base,
    # because objcopy -O binary drops the leading file offset and starts at the lowest loadable VA).
    out = subprocess.run(["readelf", "-sW", elf], stdout=subprocess.PIPE, text=True).stdout
    spans = []
    for line in out.splitlines():
        f = line.split()
        if len(f) >= 8 and f[3] == "OBJECT":
            try:
                va, sz = int(f[1], 16), int(f[2], 16)
            except ValueError:
                continue
            if sz:
                spans.append((va - base, va - base + sz))
    m = bytearray(nbytes)
    for a, b in spans:
        a, b = max(0, a), min(nbytes, b)
        if b > a:
            m[a:b] = b"\x01" * (b - a)
    return m

# **A NAMED FUNCTION IS CODE, AND A CLASS OF CODE THIS CLAUSE MUST BE ABLE TO TAKE BACK THE EXCLUSION OF.**
# The clause below refuses an image that carries the watchdog's page in any of three encodings, because a
# run whose only net is the one the image can reach is a run nobody can rescue. 909's residence arm
# INVERTS that premise on purpose: the pet's whole job is to reach the page and FEED the net, so the arm
# must carry the address. The remedy is not to weaken the clause for everyone but to let the image's own
# ELF say which functions are allowed to carry it - a whitelist read off the artifact, not a switch this
# gate remembers. `entry_wdt_pet` is the pet itself - compiled ONLY under `#if STAGE90_XNU_RESIDENT`
# (`entry_trace.c`), so an image that DEFINES it is the residence arm and nothing else is - and its body
# is the one place that may carry the address, because feeding the net is what it is for. **The pet alone
# is exempt, and the exempt set IS the residence test.** `entry_mmio_section` is deliberately NOT exempt:
# it is the generic mapper that links into EVERY entry image and takes the address as an argument, so its
# own body carries none of the three encodings (`movt 0` in the draft's measurement) - and exempting it
# would let a future build hide a real page reach inside the one function every image has. The residence
# test is therefore "this ELF defines `entry_wdt_pet`", which only the `#if STAGE90_XNU_RESIDENT` block
# can produce. A non-resident image defines no pet, so the clause for it is exactly the one it was: no
# code may carry the page. The exemption is by symbol, so it cannot be widened by moving bytes.
_PAGE_OK = {"entry_wdt_pet"}

def exempt_findings(elf, base, nbytes, names):
    """Bin spans of the FUNC symbols in `names` - the code allowed to carry the watchdog's page."""
    out = subprocess.run(["readelf", "-sW", elf], stdout=subprocess.PIPE, text=True).stdout
    spans = []
    for line in out.splitlines():
        f = line.split()
        if len(f) < 8 or f[3] != "FUNC":
            continue
        if f[7].split("@")[0] not in names:
            continue
        try:
            va, sz = int(f[1], 16), int(f[2], 16)
        except ValueError:
            continue
        if sz:
            spans.append((va - base, va - base + sz))
    m = bytearray(nbytes)
    for a, b in spans:
        a, b = max(0, a), min(nbytes, b)
        if b > a:
            m[a:b] = b"\x01" * (b - a)
    return m

def ror(v, n):
    n &= 31
    return ((v >> n) | (v << (32 - n))) & 0xffffffff if n else v

def movt_pattern(imm):
    # cond 0011 0100 imm4 Rd imm12 - imm4 is bits 19-16 and holds the high half of imm16, Rd is bits
    # 15-12. Masking out the condition and Rd leaves a conditional `movtne` no more hidden than an
    # unconditional one, and bits 27-25 of the pattern are 001, so nothing in the unconditional
    # (cond 1111) space can collide with it.
    return 0x03400000 | ((imm >> 12) & 0xf) << 16 | (imm & 0xfff), 0x0fff0fff

MOVT_WATCH, MASK = movt_pattern(0xf901)
MOVT_WITNESS, _ = movt_pattern(0xf900)

def census(path, objmask=None, keep=False):
    """Count page/witness reaches. `objmask` set + keep=False skips masked words (the refusable count
    excludes named objects AND the exempt code); keep=True counts ONLY masked words (the exempt code)."""
    d = open(path, 'rb').read()
    if len(d) < 4096:
        sys.exit("  %s is %d bytes - this is a scan that could not look" % (path, len(d)))
    hit = dict(pool=0, movt=0, mov=0)      # in the watchdog's page, by form
    wit = dict(pool=0, movt=0, mov=0)      # in the GIC's pages, one nibble below
    enc = 0                                # words carrying the movt encoding at all, data included
    for i in range(len(d) // 4):
        if objmask is not None and bool(objmask[i * 4]) != keep:
            continue
        w = struct.unpack_from('<I', d, i * 4)[0]
        if WATCH_LO <= w <= WATCH_HI:
            hit['pool'] += 1
        if WIT_LO <= w <= WIT_HI:
            wit['pool'] += 1
        if w & 0x0ff00000 == 0x03400000:
            enc += 1
        if w & MASK == MOVT_WATCH:
            hit['movt'] += 1
        if w & MASK == MOVT_WITNESS:
            wit['movt'] += 1
        # mov/mvn (immediate): 8 bits rotated right by an even amount, and never condition 1111
        if w >> 28 != 0xf and (w & 0x0fe00000) in (0x03a00000, 0x03e00000):
            v = ror(w & 0xff, ((w >> 8) & 0xf) * 2)
            if w & 0x03e00000 == 0x03e00000:
                v = ~v & 0xffffffff
            if WATCH_LO <= v <= WATCH_HI:
                hit['mov'] += 1
            if WIT_LO <= v <= WIT_HI:
                wit['mov'] += 1
    return len(d) // 4, enc, hit, wit

_en = len(open(ENTRY, 'rb').read())
_base = load_base(ENTRY_ELF)
_objm = obj_spans(ENTRY_ELF, _base, _en)
_exm  = exempt_findings(ENTRY_ELF, _base, _en, _PAGE_OK)  # the pet - the only code allowed to carry it
# **The refusable census excludes the exempt code; the exempt census counts only it.** Composing the two
# masks this way is what makes `carried` mean "a REACH THE GATE HAS NO NAME FOR": a page hit inside
# `entry_wdt_pet` is the arm's own pet, not a reach nobody can rescue, so it is counted in `hite` and not
# in `hit`. A hit OUTSIDE both masks (any other function, or the literal pools) is the refusal.
_refm = bytearray(a or b for a, b in zip(_objm, _exm))
words, enc, hit, wit = census(ENTRY, _refm)
_noneed, _, hite, wite = census(ENTRY, _exm, keep=True)   # the exempt code, and nothing else
print("  %s:" % ENTRY)
print("    %d aligned words, %d carrying the movt encoding (a ceiling)" % (words, enc))
print("    [0xf9010000, 0xf901ffff]   pool word %d   movt rD, #0xf901 %d   mov/mvn immediate %d"
      % (hit['pool'], hit['movt'], hit['mov']))
print("    witness, one nibble below - the GIC, which this image does use:")
print("    [0xf9000000, 0xf900ffff]   pool word %d   movt rD, #0xf900 %d   mov/mvn immediate %d"
      % (wit['pool'], wit['movt'], wit['mov']))
print("      the movt counts are ceilings for the same reason: the mask frees the condition field,")
print("      so a data word sharing the low half is counted too.")
# **The second census is what keeps this clause from turning into a check that cannot fail.** The
# exemption at the top takes `entry_wdt_pet` and `entry_mmio_section` out of the refusable count; those
# are exactly the symbols the residence arm DEFINES, so if a non-resident image ever came to define them,
# or a resident one lost the pet, the exemption could not silently excuse the whole clause - the exempt
# region itself is now required to CARRY the page. A resident image prints a non-zero count here (its pet
# materialises `0xf9017000`) and a non-resident image prints "0 exempt word(s) ... the exemption is
# empty". Both are readings: the first is the arm's reach being where it belongs, the second is the
# exemption not having widened the clause for an image that has no business reaching the page.
_residence = any(_exm)                 # this image DEFINES the pet - i.e. it IS the residence arm
print("    exempt code (%s), which a residence arm must carry the page in:"
      % ", ".join(sorted(_PAGE_OK)))
if _residence:
    print("      %d page reach(es) - pool word %d   movt rD, #0xf901 %d   mov/mvn immediate %d"
          % (hite['pool'] + hite['movt'] + hite['mov'], hite['pool'], hite['movt'], hite['mov']))
else:
    print("      the exemption is empty: this image defines neither pet nor mapper, so the count above")
    print("      is the whole clause and no code here may reach the page.")
# Both of these stop the gate, and the second is the one that is easy to leave as a warning: a page
# that reads zero because it is not carried and a page that reads zero because the instrument saw
# nothing print the same four numbers, and this project's rule is that a check which succeeds by
# printing nothing cannot be told from one that never ran. So an unread witness refuses the run
# loudly, and the remedy is to give the clause a witness it can see rather than to boot anyway.
unread = not any(wit.values())
carried = any(hit.values())
if unread:
    print("    the witness is EMPTY: this scan did not see the GIC either, so the zero above is a")
    print("    scan that saw nothing rather than a page that is not carried - that is not a reading.")
words, _, contr, _ = census(PAYLOAD, obj_spans(PAYLOAD_ELF, load_base(PAYLOAD_ELF), len(open(PAYLOAD, 'rb').read())))
print("  positive control - the payload, which arms the net, so it must carry the page:")
print("    %s" % PAYLOAD)
print("    pool word %d   movt rD, #0xf901 %d   mov/mvn immediate %d"
      % (contr['pool'], contr['movt'], contr['mov']))
if not any(contr.values()):
    print("    NOT SATISFIED: the payload carries the page in none of the three forms either, so")
    print("    this instrument is not demonstrably able to see one and the entry image's zero is not")
    print("    a reading - distrust the counts above it.")
if carried:
    print("    the entry image carries the watchdog's page OUTSIDE its residence code: pool word %d,"
          % hit['pool'])
    print("    movt %d, mov/mvn %d - that is a reach the gate does not have a name for, and it stops this"
          % (hit['movt'], hit['mov']))
    print("    image (a run whose only net is the one the image can touch).")
if unread or not any(contr.values()):
    print("    (the witness is unread, or the positive control is not satisfied - the counts above")
    print("    are not a reading, so the run is refused on the instrument rather than on the image.)")
# **The refusable condition - and the one exemption that is itself read.** A page hit OUTSIDE the
# exemption stops the run (above). But an image that DEFINES the residence pet must not reach the page
# ZERO times, because a pet that carries no address is not a pet: it is a function that cannot feed the
# net, and its presence is then the arm claiming an ability it does not have. So the direction is
# two-sided for an image that defines either exempt symbol: it must carry at least the movt sites that
# materialise `0xf9017000`. A non-resident image defines neither (`_residence` is false) and this clause
# is silent for it, exactly as it was before 909.
if carried or unread or not any(contr.values()) or (_residence and not any(hite.values())):
    sys.exit(1)
PY
  then
    fail "the entry image's reach into the watchdog's page is either real or unread, and both stop this image (see above): a run whose only net is the one the image can touch, or a zero read from an instrument that saw no witness, are the two ways this check can be a sentence instead of a reading"
  fi

  # **And the same measurement has a second consequence that the paragraph above does not draw, so it is
  # drawn here: with nothing in the entry image carrying the watchdog's page, a run of this arm is
  # CAPPED.** The net is armed before the jump and nothing pets it, so the SoC resets the machine on its
  # own clock - and that is a property of a *successful* run as much as of a hung one. The paragraph
  # above says "expect a power press"; what it does not say, and what an operator reading a green gate
  # would otherwise assume, is that **a run that goes well also ends within the net's interval**, with the
  # log intact and the phone back on Android. So "the machine stayed up" has a ceiling in this arm, and
  # the ceiling is a number in this tree rather than prose: the two constants are read out of `stage90.h`
  # (rung 1b's rule - a threshold quoted from the file that defines it, never written here again), and
  # the clause refuses rather than guessing if either cannot be read.
  #
  # **909's residence arm is the exception, and the `if` below IS that exception.** Everything in this
  # comment is a claim about an image that does not pet the net - `carried == 0` above, "nothing in it
  # does". A resident image petting the net is not capped, so it gets a different paragraph: the
  # countdown trace instead of the ceiling. The branch is taken on the entry ELF (`_entry_resident_arm`,
  # the same read the config-keys block uses) and not on a switch this gate remembers, so the paragraph
  # an operator reads is always about the artifact they are about to boot.
  #
  # **The claim that nothing pets it is the clause above, not this one - and the two are different
  # claims, which is why they are now printed as two.** `carried == 0` is "no code in the entry image
  # materialises an address in this page", and a store to the watchdog needs one, so the clause does
  # establish that nothing stores to it. What it does **not** establish is that the registers are
  # unreachable, and 584's own paragraph above says so in as many words. The reachability question has
  # a measured answer, and it is the opposite one: **the watchdog's registers are mapped, by this
  # image, on every boot.** `entry_gic_probe`'s first act is
  # `entry_mmio_section(0xf9000000, 0xf9000000, ...)` - one 1 MB section descriptor into XNU's own L1,
  # `entry_gic.c:109` - and 0xf9017000 is inside that megabyte. Both archived captures carry it:
  # `xnu_live_gic_map=0x00000001` with `xnu_live_gic_desc=0xf901040e`, whose bits[31:20] are 0xf90 and
  # whose bits[1:0] are 0b10 - base 0xf9000000, a section, so it covers 0xf9000000-0xf90fffff. Its
  # attribute index is 3 (`xnu_live_attr=0x0c`, `entry_stubs.c`'s `ARM_TTE_BLOCK_ATTRINDX` of the PRRR
  # field that is 0), which TRE remaps to Strongly-ordered - so the mapping is the *right* kind for a
  # pet, and a store through it would land uncached.
  #
  # So the honest sentence is **reachable and unused**, and the ceiling rests on the second. The
  # distinction is not pedantry: it is the difference between "this arm's clock cannot be changed
  # without new machinery" (false - a pet is one store to `0xf9017004` from a wrapper this image
  # already has) and "nothing in it does" (true, and what the scan measures).
  #
  # **And there is a hardware reading of what the ceiling looks like, which is why it is worth printing
  # rather than asserting.** 513's two captures (2026-09-21) are runs of an image with no repair - the
  # same regime this arm's switch restores - and their payload records end at `xnu_live_poll_over`
  # (the fifth poll), with `panic` 0, `Attempting system restart` 0, `MACH Reboot` 0,
  # `pc_sample_watchdog_fired` 0 and `platform_reboot entered` 0. So **no software path ended either
  # run**: not XNU's panic-restart, not the payload's own software dead-man. The only reset path left is
  # the net, and what a capture of that regime looks like is therefore "the records simply stop, after
  # the work, with no fault text". That is the shape to expect, and it is not a failure.
  WDT_TMO=$(sed -n 's/^#define STAGE90_HW_WATCHDOG_TIMEOUT_S \([0-9][0-9]*\)u.*/\1/p' "$SRC_DIR/stage90.h" | head -1)
  WDT_GAP=$(sed -n 's/^#define STAGE90_HW_WATCHDOG_BITE_GAP_S \([0-9][0-9]*\)u.*/\1/p' "$SRC_DIR/stage90.h" | head -1)
  if [[ -z $WDT_TMO || -z $WDT_GAP ]]; then
    fail "STAGE90_HW_WATCHDOG_TIMEOUT_S / _BITE_GAP_S could not be read from $SRC_DIR/stage90.h, so the ceiling this arm runs under cannot be stated - and a gate that describes a run without its ceiling is describing a different run"
  fi
  if [[ $_entry_resident_arm == on ]]; then
    # **909's residence arm is the one image for which that ceiling is FALSE, and this branch says so
    # rather than letting the paragraph below describe a run this image is not.** The pet's whole job is
    # to feed the net, so a resident image's clock is NOT the net's own interval: it is however long the
    # pet keeps writing `WDT0_RST`. The two constants are still read out of `stage90.h` (they are the
    # interval the pet must out-run), and the reading that replaces the ceiling is the countdown trace -
    # `xnu_live_wdt_countdown` published over many idle passes, each value below the bark and never zero.
    # A resident run that comes back reset is therefore a pet that did not fire, and the log's last
    # `xnu_live_wdt_*` cells name how far into the interval it got. This branch is keyed on the entry ELF
    # defining the pet (`_entry_resident_arm`, read at the top) and not on a switch named here.
    echo '  and this image DOES pet the net - its pet (`entry_wdt_pet`, the exempt code the scan above'
    echo '  reports carrying the page) writes WDT0_RST on the idle exit, so this run is NOT capped at the'
    echo '  net'"'"'s interval; it is resident until the pet stops. The interval it must out-run is read out of'
    echo '  stage90.h rather than quoted here:'
    echo "    STAGE90_HW_WATCHDOG_TIMEOUT_S    $WDT_TMO s   (the bark)"
    echo "    STAGE90_HW_WATCHDOG_BITE_GAP_S   $WDT_GAP s   (bark -> bite)"
    echo "    so a bite is due at most $(( WDT_TMO + WDT_GAP )) s after the payload arms it unless a pet lands"
    echo "    inside that window - and the payload spends about 1 s of it before the jump (measured: 533's"
    echo "    payload timebase sample to the idle's first read is 1.1805 s on one 19.2 MHz counter)."
    echo '  READ A CAPTURE OF THIS ARM AS A COUNTDOWN, NOT A CEILING. The evidence of residence is'
    echo '  `xnu_live_wdt_countdown` published over many passes, each value below the bark and never reaching'
    echo '  zero, with the raw `xnu_live_wdt_sts` moving - the pet keeping the countdown pinned low. The'
    echo '  negative cell is bounded and readable: if the pet'"'"'s read faults (the page is not mapped where the'
    echo '  install put it), the run dies AT THE PET SITE with a fault address in the watchdog'"'"'s page, not in'
    echo '  a hang - so `xnu_live_wdt_sts` absent plus a fault at the pet is a measurement, not silence.'
    echo '  ABSENCE TO EXPECT HERE AND NOT ELSEWHERE: `xnu_live_post_end_calls` (R1 deletes the deliberate'
    echo '  ending) - its presence would mean the ending this rung removes is still firing.'
  else
    echo "  and nothing in this image pets the net, so the run is CAPPED: a run of this arm that goes well"
    echo "  also ends within the net's own interval, not when the payload stops. The two constants are read"
    echo "  out of stage90.h rather than quoted here:"
    echo "    STAGE90_HW_WATCHDOG_TIMEOUT_S    $WDT_TMO s   (the bark)"
    echo "    STAGE90_HW_WATCHDOG_BITE_GAP_S   $WDT_GAP s   (bark -> bite)"
    echo "    so the bite is at most $(( WDT_TMO + WDT_GAP )) s after the payload arms it, and the payload"
    echo "    spends about 1 s of that before the jump (measured: 533's payload timebase sample to the"
    echo "    idle's first read is 1.1805 s on one 19.2 MHz counter)."
    echo "  READ IT AS 'UNUSED', NOT 'UNREACHABLE'. This image maps the watchdog's registers on every boot -"
    echo "  the GIC probe's own 1 MB section descriptor (0xf901040e, base 0xf9000000, attr index 3 ="
    echo "  strongly-ordered) covers 0xf9017000, and both archived captures carry it. What the scan above"
    echo "  measures is that nothing STORES to them, and a store is what a pet is. Changing this ceiling is"
    echo "  therefore not new machinery: it is one store to 0xf9017004 (WDT0_RST) from a path XNU already"
    echo "  runs, in a wrapper this image already has. That is a decision about the arm and not part of it."
    echo "  MEASURED, what that ceiling looks like: 513's two captures - the same regime, an image with no"
    echo "  repair - end their payload records at the fifth poll with panic 0, Attempting system restart 0,"
    echo "  MACH Reboot 0, pc_sample_watchdog_fired 0 and platform_reboot entered 0, so NO software path"
    echo "  ended either run and the records simply stop after the work, with no fault text. Read a capture"
    echo "  of this arm that way: 'the log ends without a fault' is the ceiling, not a missing reading."
  fi

  # **Which idle arm this image runs is a boot argument, and it is read out of the artifact that is
  # about to be booted.** 549's finding: `up_style_idle_exit` is a `.bss` global (default 0) set only by
  # `arm_init`'s `PE_parse_boot_argn` call, so the arm is a property of the command line and not of the
  # code. On this image the two arms are exact complements - `platform_cache_idle_enter` takes its
  # single-CPU branch iff `up != 0 && real_ncpus == 1`, and `platform_cache_idle_exit` skips
  # `invalidate_mmu_icache` and `flush_core_tlb` under the same condition - so this token decides *both*
  # sides of the window the run is spent on, and a run whose log is read as if it carried the token
  # while the image did not is a run read as the wrong instrument.
  #
  # **The count is required to be two, and it is read from the payload and the boot image - never from
  # the entry image.** Measured: `up_style_idle_exit=1` occurs twice in `stage90-qcdt.img` and in
  # `stage90.bin`, and **zero times in `xnu_arm_entry.bin`**, because the entry image carries only the
  # token's *name* - `arm_init`'s own parse literal and its two `up_style_idle_exit=%d` format strings.
  # A clause pointed at the entry image would find that name four times and pass without ever seeing the
  # argument, which is then a check that cannot fail (548's rule, one file over). Two is the number
  # because 515's repair is carried in two command lines by design: `boot_args.c`'s `CommandLine`, which
  # XNU's `PE_boot_args()` reads, and the payload's `/chosen` `boot-args` property, which the port's own
  # contracts read - and `stage90_main.c`'s comment states the hazard directly: *a token that only one of
  # the two carries is a token whose check and whose effect are about different strings.* So one
  # occurrence is refused as loudly as none.
  # **954: on D13 this clause's subject does not exist, and it PUBLISHES the skip.** D13 has no
  # `up_style_idle_exit` global and no `caches.c`; its idle is gated by `do_power_save`, a compile
  # default (`pmCPU.c:41`), not a boot argument. So there is no idle arm to select and no token for the
  # entry image's `arm_init` to name. Skipping is not enough on its own: the clause also REFUSES the
  # token if it is present, because a D13 image that carried one would be claiming an arm it cannot
  # take ([[mi4-off-option-two-spellings]]). `_entry_tree_d13` is read from the hash-bound record above.
  if [[ $_entry_tree_d13 -eq 1 ]]; then
    echo "== the boot argument that selects the idle arm =="
    _d13_tok=$(grep -ao -- "up_style_idle_exit=1" "$IMAGE" 2>/dev/null | wc -l || true)
    if [[ ${_d13_tok:-0} -ne 0 ]]; then
      fail "this is a D13 image (the record says STAGE90_XNU_TREE_D13=1) but the boot image carries 'up_style_idle_exit=1' $_d13_tok time(s). D13 has no such global and no caches.c, so the token has no reader - a claim the image does not honour. Rebuild with the D13 tree selected"
    fi
    echo "549: SKIPPED on D13 - the idle-cache boot argument does not exist in this tree."
    echo "  D13's arm_init parses only maxmem/-no-cache/serial and ships no caches.c; its idle is gated"
    echo "  by do_power_save (pmCPU.c:41), a compile default, not a boot argument. The boot image is"
    echo "  confirmed NOT to carry up_style_idle_exit=1, so no idle arm is being claimed."
  else
  echo "== the boot argument that selects the idle arm =="
  STRINGS=$(command -v strings || command -v arm-none-eabi-strings || true)
  if [[ -z $STRINGS ]]; then
    echo "UNREAD: neither 'strings' nor 'arm-none-eabi-strings' is on PATH, so the argument's name"
    echo "        cannot be read out of the entry image and nothing below could have seen the token."
    fail "the idle arm's boot argument is not established, and a boot whose arm is unknown cannot be read: this is a scan that could not look, not a token that is absent"
  fi
  # the name comes from the entry image rather than from this script, so a payload token spelled
  # differently is refused instead of compared against the gate's memory of it. `strings` runs to the
  # end of the stream: no `head` and no `awk ... exit` on it, because under `pipefail` the SIGPIPE from
  # a reader that stops early fails the pipeline (build.sh's own clause found that the hard way).
  ARGNAME=$("$STRINGS" -a "$ENTRY_BIN" | awk '$0 == "up_style_idle_exit" { n++; if (n == 1) print }')
  if [[ -z $ARGNAME ]]; then
    fail "the entry image carries no bare 'up_style_idle_exit' literal, so arm_init's own call site is not where 549's boot argument gets its name - check the entry build's switches before booting"
  fi
  N_IMG=$(grep -ao -- "$ARGNAME=1" "$IMAGE" | wc -l || true)
  N_PAY=$(grep -ao -- "$ARGNAME=1" "$PAYLOAD_BIN" | wc -l || true)
  N_OTH=$(grep -aoE -- "$ARGNAME=[0-9]+" "$IMAGE" | grep -vc -- "=1\$" || true)
  echo "token '$ARGNAME=1': $N_IMG occurrence(s) in $(basename "$IMAGE"), $N_PAY in $(basename "$PAYLOAD_BIN")"
  grep -aoE -- ".{0,40}$ARGNAME=1" "$IMAGE" | sed 's/^/  .../'
  if [[ $N_OTH -ne 0 ]]; then
    fail "'$ARGNAME' appears in this boot image with a value other than 1 ($N_OTH time(s)), and the arm is selected by that value: the analysis is written for $ARGNAME=1"
  fi
  if [[ $N_IMG -ne 2 || $N_PAY -ne 2 ]]; then
    fail "the boot image carries '$ARGNAME=1' $N_IMG time(s) and the payload $N_PAY, where 515's repair must be in two command lines (XNU's PE_boot_args() reads boot_args.c's CommandLine; the port's contracts read the /chosen boot-args property) - with one copy, the two sides are about different strings, and with none this image is not the arm 549's reading is written for"
  fi
  echo "ok: the arm 549's reading is written for is the arm in the bytes - both copies carry it"
  fi
fi

case "$HWSELFTEST" in 1|1u)
  [[ $ALLOW_HW_SELFTEST -eq 1 ]] || fail "the hardware-watchdog SELFTEST skips the normal boot path and spins until a net reboots it; needs --allow-hw-watchdog-selftest"
  echo "HW WATCHDOG SELFTEST: allowed. Three outcomes, and the time it takes is the result:"
  echo "          ~33s  the hardware watchdog fired - it works"
  echo "          ~90s  it did NOT, but the bounded spin's PS_HOLD reset brought the"
  echo "                device back - the watchdog needs investigating, PS_HOLD is fine"
  echo "          never both failed. Note this third case is reachable: platform_reboot()"
  echo "                falls back to the same watchdog, so a dead watchdog plus a PS_HOLD"
  echo "                that does not land means a manual power press. That is a real"
  echo "                finding, not a lost run, but it is the one outcome with no log."
  ;;
esac

echo
echo "== mode policy =="
# A -D override records the numeric value rather than the symbolic name, so accept
# either form. Reading the build's own config is only worth anything if the gate can
# actually recognise what it finds there.
case "$MODE" in
  STAGE90_HANDOFF_MODE_HARD_SKIP|0|0u)
    echo "HARD_SKIP: stops before the candidate L1, the watchdog loop and the jump."
    ;;
  STAGE90_HANDOFF_MODE_PREFLIGHT_WATCHDOG_ONLY|1|1u)
    [[ $ALLOW_PREFLIGHT -eq 1 ]] || fail "PREFLIGHT_WATCHDOG_ONLY is not allowed without --allow-preflight"
    echo "PREFLIGHT_WATCHDOG_ONLY: allowed."
    ;;
  STAGE90_HANDOFF_MODE_FULL|2|2u)
    [[ $ALLOW_FULL -eq 1 ]] || fail "FULL is not allowed without --allow-full"
    echo "FULL: allowed. This installs the candidate L1 and jumps to the high-VA target."
    ;;
  *)
    fail "unrecognised STAGE90_HANDOFF_MODE: $MODE"
    ;;
esac

if [[ $SELFTEST == "1u" ]]; then
  [[ $ALLOW_SELFTEST -eq 1 ]] || fail "dead-man SELFTEST hangs the payload on purpose; needs --allow-selftest"
  echo "SELFTEST: allowed. The payload will NOT reach platform_reboot();"
  echo "          the dead-man is the only route back to Android (~60s)."
fi

echo
echo "== ladder =="
# The ladder level decides how much of the payload runs, so it decides how much a green
# run tells you. Printing the raw macro said nothing useful: a level-0 build under HARD_SKIP
# exercises the device tree, the watchdog arm and kernel_entry's early checks and then
# returns - skipping the whole arm_init ladder - and the gate presented that identically to
# a FULL run. Spelling out what each level reaches makes the run's value visible before it
# is booted rather than after.
case "$LADDER" in
  STAGE90_ENTRY_LADDER_FULL|4|4u)
    echo "FULL (4): boot-args, early pmap, PE_init_platform, post-PE bootstrap, arm_vm_init,"
    echo "          the high-VA windows and the loader. The only level that reaches the handoff."
    ;;
  STAGE90_ENTRY_LADDER_POST_PE_BOOTSTRAP|3|3u)
    echo "POST_PE_BOOTSTRAP (3): stops before arm_vm_init - no candidate L1, no high-VA"
    echo "          windows, no loader, no handoff. Tests boot-args through post-PE only."
    ;;
  STAGE90_ENTRY_LADDER_PE_INIT_PLATFORM|2|2u)
    echo "PE_INIT_PLATFORM (2): stops before the post-PE bootstrap. Tests boot-args, early"
    echo "          pmap and PE_init_platform only."
    ;;
  STAGE90_ENTRY_LADDER_EARLY_PMAP|1|1u)
    echo "EARLY_PMAP (1): stops after the early pmap step. A thin test - boot-args plus one"
    echo "          stage of the ladder."
    ;;
  STAGE90_ENTRY_LADDER_BOOT_ARGS_ONLY|0|0u)
    echo "BOOT_ARGS_ONLY (0): the stub returns after validating boot-args. This run exercises"
    echo "          almost none of the ladder - useful only for isolating an early failure."
    ;;
  *)
    fail "unrecognised STAGE90_ENTRY_LADDER_LEVEL: $LADDER"
    ;;
esac

echo
echo "== fault injection =="
if is_off "$FAULT_INJECT"; then
    echo "off: the handoff targets the Stage-owned high-VA function as usual."
else
    [[ $ALLOW_FAULT_INJECT -eq 1 ]] || fail "this build jumps at an intentionally unmapped VA ($FAULT_INJECT); needs --allow-fault-inject"
    echo "FAULT INJECTION: this build will jump at $FAULT_INJECT, which is expected to be"
    echo "          unmapped, and the abort path should log the fault and reboot."
    echo "          Expected evidence: an 'exception pabort ... lr=$FAULT_INJECT' line."
    echo "          A silent hang or a boot loop instead means the address IS mapped -"
    echo "          the failure mode this mode exists to avoid."
fi
# `is_off` rather than `case "$FAULT_INJECT" in 0|0u|"")`: with the empty value grouped into the off
# arm, a record whose fault-inject key carried no value skipped this refusal entirely and narrated
# "the handoff targets the Stage-owned high-VA function as usual" - a statement about which function
# the handoff targets, made from a record that does not say. The presence loop above now refuses that
# record first, so this is the second line of defence and not the first.

echo
echo "== entering XNU =="
if is_off "$(value_of STAGE90_XNU_ENTRY)"; then
    # **The flag and the image can disagree, and until now nothing compared them.** Every step in
    # this line builds the payload with STAGE90_EXTRA_CFLAGS='-DSTAGE90_XNU_ENTRY=1' — e.g.
    # docs/experiments/experiment-491-the-bit-registration-sets.md, step 4 — and a payload built
    # without it never jumps: `xnu_kernel.c:234`'s call site is behind `#if STAGE90_XNU_ENTRY`, so the
    # linked image has no branch to `stage90_xnu_entry_run` at all and the run ends in the payload's
    # own ladder and a reboot. A `--allow-xnu-entry` run spent against one therefore produces no XNU
    # log, and the run is paid for with a power press. This is the 533 shape one level out: the gate
    # described the arm the image carries and could not compare it, and here it describes *whether
    # the run reaches XNU at all* in prose and then lets the run through. Measured (2026-09-22,
    # 17:28): out/stage90 was rebuilt without the flag, this gate printed "off" and exited 0, and
    # `arm-none-eabi-objdump` on that payload has no reference to `stage90_xnu_entry_run` outside its
    # own body — so the two readings agree and the prose was the only place the mismatch appeared.
    # Only the flag makes it a refusal: entry off is a legitimate configuration, and every stage
    # before 241 ran in it.
    [[ $ALLOW_XNU_ENTRY -eq 0 ]] \
      || fail "--allow-xnu-entry was passed, but this image was built with STAGE90_XNU_ENTRY off: it never jumps into XNU, so it cannot produce the log the flag is passed for. Rebuild the payload with STAGE90_EXTRA_CFLAGS='-DSTAGE90_XNU_ENTRY=1' (see docs/experiments/experiment-491-the-bit-registration-sets.md step 4), or drop the flag if a ladder run is what was meant"
    echo "off: the payload runs its own ladder and reboots, as in every stage so far."
    echo "          (--allow-xnu-entry was NOT passed, so this image is gated as a ladder run.)"
else
    [[ $ALLOW_XNU_ENTRY -eq 1 ]] || fail "this build jumps into XNU's _start and never returns; needs --allow-xnu-entry"
    echo "ENTERING XNU: the payload copies a linked image containing XNU's real osfmk/arm/start.s"
    echo "          to PA 0x80000000 (experiment 241's base; 0x00200000 before it), hands it a"
    echo "          boot_args (physBase == virtBase), and jumps."
    echo "          Nothing after that jump is the payload's: the page tables, vectors, caches"
    echo "          and MMU state are XNU's, and the payload never runs again."
    echo
    echo "          Endings, and the log says which:"
    echo "            '...real XNU entry: _start ran to completion and branched to arm_init'"
    echo "                 XNU's own entry sequence ran on this device, end to end."
    echo "            '...real XNU entry: exception: <which>'"
    echo "                 it faulted, and the vector names itself."
    echo "            neither, ending at 'jumping to XNU's _start'"
    echo "                 it hung; the hardware watchdog brings the phone back in ~28s."
    echo "            no log at all, and the device does not come back"
    echo "                 the net below did not recover it and the ram_console died with the"
    echo "                 cold boot; the phone needs a power-button press and the run is lost."
    echo "                 This is not hypothetical and it is not rare enough to ignore: it is"
    echo "                 experiment 517's first run (2026-09-21). One observation, and the"
    echo "                 cause is not known - the run had two changes in it, so the next image"
    echo "                 carries one (see STAGE90_XNU_EXIT_POC_FLUSH in build_entry.sh)."
    echo "                 A candidate mechanism exists and is now measured rather than"
    echo "                 reasoned (experiments 517/518): the interrupt handler's stack starts"
    echo "                 at cpu_data->istackptr, which is also where the idle loop runs, so"
    echo "                 the handler's 5th and 6th pushed words land on the return address"
    echo "                 the idle exit is about to pop - and 518's run shows it popping a"
    echo "                 timebase value into the PC. 518's arm (move istackptr to the middle"
    echo "                 of the interrupt stack) RAN on 2026-09-22 and could not test it:"
    echo "                 istackptr is read by the vector AND by the context switch that puts"
    echo "                 the idle thread on that stack, so the arm moved both and the gap is"
    echo "                 invariant (SS_SP == istackptr - 16 in 516 and in 518 alike). The"
    echo "                 same panic returned, with the device recovering on its own. The arm"
    echo "                 cannot be another value of that field, so 519 changes where the idle"
    echo "                 thread's stack comes from instead: Idle_context is the one place that"
    echo "                 choice is made, and the arm rewrites its ldr sp from"
    echo "                 cpu_data->istackptr into a load of this image's own 16 KB array - so"
    echo "                 the handler keeps the whole interrupt stack and the idle body runs"
    echo "                 outside [intstack_top - 16384, intstack_top), which is exactly what"
    echo "                 ml_at_interrupt_context() tests. (518 section 5 proposed"
    echo "                 __wrap_Idle_load_context; that hook restores sp from the thread's pcb,"
    echo "                 so it cannot choose the idle body's stack - experiment 519 section 1.)"
    echo "                 **519 RAN on 2026-09-22 and obtained both of its predictions.**"
    echo "                 The arm worked: xnu_live_idlestack_sp = 0x8054fea8 is inside"
    echo "                 [stage90_idle_stack, +16384) with xnu_live_idlestack_inwin = 0 and"
    echo "                 _calls = 1, so the idle body is out of the window the kernel's"
    echo "                 predicate tests - and the live chain agrees with the panic's own sp"
    echo "                 from two sides (array top 0x8054fee0, cpu_idle's 'sub sp, sp, #8',"
    echo "                 the exit wrapper's 8-byte frame => the exit's entry sp is"
    echo "                 0x8054fed0). And the run ends in the *diagnosed* panic, not"
    echo "                 Apple's flat one: 'sleh_abort: prefetch abort in kernel mode:"
    echo "                 fault_addr=0x7152a6c' with frame_ok = 1, fsr_frame = 5,"
    echo "                 sp 0x8054fed0, lr 0x800462dc, pc = far = 0x07152a6c - i.e."
    echo "                 ml_at_interrupt_context() answered false. The panel is the idle"
    echo "                 path's own registers one instruction before the pop (r0/r1 are"
    echo "                 the exit's own str, r5 and r4 are cpu_idle's, r4 = the value of"
    echo "                 cpu_data->rtcPop), so the two words the pop read are two counter"
    echo "                 readings one tick apart, the later one the deadline the idle loop"
    echo "                 held. 519 section 10 removes 518's mechanism by arithmetic:"
    echo "                 EXC_CTX_SIZE is 360 (80 + 264 + 16, genassym.c:188) and the VFP"
    echo "                 area never ends above the interrupted sp, so no exception frame"
    echo "                 writes above the sp it interrupted - the writer has to be"
    echo "                 WATCHED, not reasoned about. **520 RAN on 2026-09-22 and watched it.**"
    echo "                 That arm was 519's switch set unchanged with seven live-channel keys"
    echo "                 added per site and no state change anywhere. The death reproduced at"
    echo "                 the same instruction - xnu_live_sleh_storm = 9, sp = 0x8054fed0,"
    echo "                 lr = 0x800462dc, numerically identical to 519's - and the writer is"
    echo "                 now a number rather than a candidate: xnu_live_slot_rtcpre_pop ="
    echo "                 0x04b79075 is cpu_data->rtcPop read immediately before the fatal"
    echo "                 call, and the fault's pc = 0x04b79074 is rtcPop - 1, the Thumb"
    echo "                 relationship 519 read off its own r4/far pair. lr = 0x800462dc is"
    echo "                 the return address of platform_cache_idle_exit's bl FlushPoU_Dcache"
    echo "                 (0x800462d8) and its bcc at 0x80046300 is taken, so the faulting"
    echo "                 instruction is that function's own pop {fp, pc} at 0x8004633c - a"
    echo "                 pop, which is why lr still names the flush. The deadline reaches"
    echo "                 that word only via strd r4, [sp, #-12]! in"
    echo "                 __wrap_platform_cache_idle_enter (0x8047c8d4) and"
    echo "                 __wrap_cpu_idle_wfi (0x8047c888): pre-indexed 12 from the same X"
    echo "                 the exit wrapper's 8-byte frame lands on, so r4 goes to E-4, the"
    echo "                 slot's UPPER word. The exit's own push writes it first and still"
    echo "                 loses, because the window is open: caches.c:406 clears SCTLR.C,"
    echo "                 so the push reaches DRAM and touches neither the valid L1 line nor"
    echo "                 the L2 - 516's enter-side CleanPoC_Dcache is DCCSW (c7,c10,2),"
    echo "                 which CLEANS and leaves the line VALID - then caches.c:490 sets"
    echo "                 SCTLR.C again and the pop's load MISSES nothing, it hits. Apple's"
    echo "                 FlushPoU_Dcache is DCCISW, the right operation, but L1 only."
    echo "                 The repair is FlushPoC_Dcache (DCCISW over L1 AND L2), which is"
    echo "                 exactly the call 517 added at this site behind"
    echo "                 STAGE90_XNU_EXIT_POC_FLUSH and which has never been run on its own."
    echo "                 **So the arm to run is the exit-side PoC flush, switch on, with 520's"
    echo "                 instrument repaired per its section 11** - the two slot loads moved"
    echo "                 into the wrapper's inline asm (they were read through"
    echo "                 entry_slot_note's own frame: pre_m4 = 0x8047c974 is that note's own"
    echo "                 saved lr), the abort site publishing every abort instead of a"
    echo "                 geometric subsequence (the fatal seq 9 was neither <= 4 nor a power"
    echo "                 of two and its SS_SP 0x8054fed0 was INSIDE the guard - the one"
    echo "                 reading the arm existed for was sampled away), and the window"
    echo "                 widened to the kernel map's own bounds with the rtc note's inner"
    echo "                 refusals counted. The prediction is the panic's ABSENCE, not"
    echo "                 a further reading: the push then writes the only copy there is and"
    echo "                 the pop reads DRAM. Reading 4 answered its own question unused:"
    echo "                 ml_get_timebase was called >= 1024 times, 517's instrument"
    echo "                 published no xnu_live_tb_* record at all (its early return on"
    echo "                 SCTLR.C set), and its own pair spans exactly 24 ticks - so it is"
    echo "                 not the source of a 1-tick pair."
    echo "                 **That arm ran (521) and the device did not come back.** One"
    echo "                 non-persistent fastboot boot, 'Booting OKAY', and then no adb, no"
    echo "                 fastboot, no getvar - a power press, and the log lost with the cold"
    echo "                 boot. The second such non-return in the project and the second"
    echo "                 flag-on image, which is what leaves the flush as the only remaining"
    echo "                 difference from the flag-off runs that all come back: a full L1 AND"
    echo "                 L2 clean-and-invalidate inside the idle window, with SCTLR.C clear,"
    echo "                 is the one operation this hardware has never survived - 517's first"
    echo "                 run carried the same call and also needed a power press."
    echo "                 **So the arm to run is 522: turn the D-cache back ON at the window's"
    echo "                 near end and take the flush out of the picture.**"
    echo "                 entry_idle_cache_enable does the one thing Apple's own clear does in"
    echo "                 reverse - read SCTLR, orr #4, write it back, dsb, isb - and"
    echo "                 __wrap_platform_cache_idle_enter calls it the moment the real"
    echo "                 platform_cache_idle_enter returns (0x8047c924), before the WFI. That"
    echo "                 is a coherence property rather than a maintenance operation: the"
    echo "                 WFI, the exit's push {fp, lr} and the pop {fp, pc} that 519 and 520"
    echo "                 died in all run with the cache on, so a store updates the line a"
    echo "                 later load reads instead of landing in DRAM behind a line nothing"
    echo "                 had invalidated. The exit-side flush is OFF in this image, so the"
    echo "                 one change from 521 is the cache enable - and a run that does not"
    echo "                 come back after this is a datum rather than a failure to fix: the"
    echo "                 next arm is a null instrument (the same wrapper with the readings"
    echo "                 replaced by a counter) to separate the cost of the measurements"
    echo "                 from the cost of the state change."
    echo "                 Four things to read, and the first is the verdict: (1) no"
    echo "                 'sleh_abort' panic and no xnu_live_sleh_storm growth past 520's"
    echo "                 9 - the idle exit retires its own epilogue; (2)"
    echo "                 xnu_live_slot_cwe_win shows C clear and xnu_live_slot_cwe_set shows"
    echo "                 it set, with _calls >= 1 - the enable ran inside the window and"
    echo "                 really took; (3) xnu_live_slot_post_calls >= 1, which says the exit"
    echo "                 RETURNED through the wrapper (520's was 0, its pass dying inside the"
    echo "                 call); (4) any later ending than 520's is progress - a different pc"
    echo "                 or the boot moving on - and the same death at the same pc says the"
    echo "                 mechanism is not the cache state but something the window itself"
    echo "                 does."
    echo "                 **The 522 arm ran on 2026-09-22 and nothing came back to adb** (section 3.3"
    echo "                 of experiment 522 has the USB timeline: dev 88 = 18d1:d00d at 14:14:45, gone at"
    echo "                 14:14:46, nothing after) - and 551 is the repair of how that was concluded,"
    echo "                 because the same d00d-then-gone shape appears in the host log followed by a"
    echo "                 genuine return ([2163244] through [2173264], serial 4a2fe00b), which is why"
    echo "                 run_and_capture.sh now enters 2 only when the log itself shows no new enumeration"
    echo "                 of the serial - and 3, a capture failure and not a hang, when it does. Either way"
    echo "                 the prediction above is spent and the four readings it named have no values: if"
    echo "                 the device never came back there was no log, and if it came back unread the run"
    echo "                 was not the arm's run. What the run did produce is a"
    echo "                 ledger, and it is the reason the arm to run now is different in kind rather than"
    echo "                 in value: 521 and 522 both carry 521's repair of the exit wrapper's capture (the"
    echo "                 four words of the idle exit's {fp, lr} slot read by the caller at each of two"
    echo "                 sites, 8 loads and 8 stores a pass) and BOTH failed to come back, while 520 -"
    echo "                 which carries neither that capture nor any state change - came back; 521 and 522"
    echo "                 differ only in which state change they carry, the exit-side FlushPoC_Dcache and"
    echo "                 the enter-side SCTLR.C re-enable, so the capture is present in every image that"
    echo "                 did not return and absent from every one that did."
    echo "                 **So the arm to run is 526: the null instrument.** Its image is 522's with the"
    echo "                 capture replaced by a counter - STAGE90_XNU_SLOT_NULL=1, which takes the four"
    echo "                 loads and the four pend_* stores out of each capture site and leaves"
    echo "                 entry_slot_null_note publishing the pass count alone; the exit-side flush stays"
    echo "                 at 0 and everything else in the wrapper (the 8-byte frame, the single"
    echo "                 mov r?, sp, 516's CleanPoC_Dcache, 519's rtcPop reading, the one call to the"
    echo "                 real exit, and 522's re-enable in the enter wrapper) is unchanged. That was"
    echo "                 checked rather than intended: the same tree built with STAGE90_XNU_SLOT_NULL=0"
    echo "                 reproduces 522's image 13d771938336fe65... byte for byte, so the two images"
    echo "                 differ by the capture and by nothing else."
    echo "                 What to read, in the order that matters: (1) **does the device come back** - that"
    echo "                 is the whole experiment, and a return says the readings cost something (and the"
    echo "                 next arm bisects them: the two loads before the call, or the two after it) while a"
    echo "                 third non-return says the cost is the state change 521 and 522 do not share; (2) if"
    echo "                 it returns, xnu_live_slot_pre_calls and xnu_live_slot_post_calls are present and"
    echo "                 rising with the four words ABSENT - the site ran and published a count and nothing"
    echo "                 else, which is what a null run should look like, and their absence is the other"
    echo "                 reading (the site never ran); (3) the enable: whether the SCTLR.C write is in"
    echo "                 this image at all - and therefore whether the _cwe_* pair is a test or a"
    echo "                 formality - is what the derived line above the XNU-entry block reads out of"
    echo "                 the record, and that line governs this one; where the write IS in the image,"
    echo "                 522's block in run_and_capture.sh --summarise reads this log for it too -"
    echo "                 xnu_live_slot_cwe_win shows C clear, _set shows it set with _calls >= 1; (4) the"
    echo "                 ending, and here the arm decides what the ending means rather than the ending"
    echo "                 deciding the arm: 547 section 4 pre-registers this death for the enable-off arm -"
    echo "                 the pass reaches the exit, the push runs with C clear, the pop loads the stale"
    echo "                 words and the prefetch abort panics - so on that arm a death whose lr is the"
    echo "                 address the exit's own bl FlushPoU_Dcache returns to is the *prediction* and not"
    echo "                 a negative result, and what falsifies 546's mechanism is a **return with no pop"
    echo "                 death at all**, which is the one reading that forbids 535 as designed. Which"
    echo "                 cell this log is in, and whether the death is the predicted shape, is what"
    echo "                 run_and_capture.sh --summarise decides - it derives that address from this"
    echo "                 image's own ELF at run time and separates the two by the log's published"
    echo "                 xnu_live_sleh_lr, so nothing above restates the rule and a death read here by"
    echo "                 eye is read that way and not by this sentence."
    echo "                 What this arm costs, read off 520's own log rather than assumed: that log's"
    echo "                 per-pass publishers have exactly one record each"
    echo "                 (xnu_live_slot_pre_calls, xnu_live_slot_rtcpre_calls, xnu_live_sip_seq and the"
    echo "                 xnu_live_pce_seq/_after_seq pair), while the door counter's last published record"
    echo "                 is 32768 - so the cache window itself was entered once, and that one entry is the"
    echo "                 death. A run of this arm gets one pass at the exit, so a non-return costs a power"
    echo "                 press and nothing else, which is why this phase is expensive in boots and not in"
    echo "                 passes. And the item that localises the death is the *bracket*, not the ending:"
    echo "                 pre and rtcpre published with xnu_live_slot_post_calls absent is what puts the"
    echo "                 death inside platform_cache_idle_exit, with no second pass to confuse it. (Line"
    echo "                 numbers quoted from that log are readable within their own block only: the ram"
    echo "                 console's records and its console text are two writers into two blocks, so a"
    echo "                 line's number says nothing about its order against a line in the other one.)"
    echo "                 The image this preflight is being run against is"
    echo "                 ${IMAGE_SHA16}... , computed from the file itself two screens up."
    echo
    echo "          Safety: the hardware watchdog is the only net across the jump, deliberately"
    echo "          - the software dead-man needs the payload's GIC and vector state, which are"
    echo "          gone the moment _start switches tables. The watchdog needs neither."
    echo "          Its record, read from the ledgers rather than from this text: it recovered"
    echo "          every run from 506 to 515, including runs parked in the kernel's own idle"
    echo "          WFI and runs in an abort storm, and 516's two runs came back on XNU's own"
    echo "          'MACH Reboot'. It then did not recover 517's first run, and the two runs"
    echo "          whose non-return is what chose the current arm - 521 and 522 - are further"
    echo "          misses; net-pessimistic, and the route has drifted with the ledgers, so"
    echo "          what stands is the verdict and not the count. So: a net that has held many"
    echo "          times and is not proved to hold always - and not the way a non-return is"
    echo "          judged either, since 551 reads that out of the host log (exit 2 against"
    echo "          exit 3), which is a reading the net cannot give. A hang here may need a"
    echo "          power press, and the device is never at risk of being bricked - nothing in"
    echo "          this project is ever written to storage."
fi

echo
echo "== later-phase probes =="
# These two run inside kernel_entry and are non-fatal by construction: each reports and the boot
# continues, because they are the next phase's work rather than a precondition for this run. They
# are listed rather than ignored so that "the run passed" and "the shim passed" cannot be
# confused - the payload says so in the log too. Neither changes any mapping or boot decision, so
# there is nothing to allow; if either ever does, it needs a flag of its own.
if is_off "$(value_of STAGE90_XNU_BOOT_ARGS)"; then
  echo "conforming boot_args (Phase 2): off - only the ladder's own identity-based args exist."
else
  echo "conforming boot_args (Phase 2): ON, as a second object alongside the ladder's. It"
           echo "          is built and its invariants checked against the real __stage90_image_end."
           echo "          Non-fatal: read xnu_ba_checks/xnu_ba_failures in the log for its verdict."
fi
if is_off "$(value_of STAGE90_XNU_MSM8974_SHIM)"; then
  echo "MSM8974 platform shim (Phase 3): off."
else
  echo "MSM8974 platform shim (Phase 3): ON. Registers its tbd_ops and checks the EOI"
           echo "          pairing, the measured CNTP interrupt number and the validated CNTFRQ."
           echo "          Non-fatal: read msm8974_shim_failures in the log for its verdict."
fi

if is_off "$(value_of STAGE90_XNU_MSM8974_FIQ_PROBE)"; then
  echo "FIQ availability probe: off."
else
  echo "FIQ availability probe: ON. Unmasks CPSR.F with the timer armed and a bounded"
           echo "          spin, to measure whether non-secure PL1 can take an FIQ on this SoC."
           echo "          If a FIQ IS delivered the vector logs 'exception: fiq' and reboots,"
           echo "          which is the expected successful outcome, not a hang."
fi

echo
echo "== mapping attributes =="
case "$(value_of STAGE90_PMAP_ATTR_MODE)" in
  STAGE90_PMAP_ATTR_MODE_SO_ONLY|0|0u)
    echo "SO_ONLY: every mapping Strongly-ordered, as in every stage so far."
    ;;
  STAGE90_PMAP_ATTR_MODE_NORMAL_NC|1|1u)
    [[ $ALLOW_ATTR -eq 1 ]] || fail "NORMAL_NC changes DRAM memory types and is not allowed without --allow-attr-normal-nc"
    echo "NORMAL_NC: DRAM is Normal/Non-cacheable, MMIO stays Strongly-ordered."
    echo "           This changes the memory model of the whole payload, so run it"
    echo "           on its own and read the log."
    ;;
  STAGE90_PMAP_ATTR_MODE_NORMAL_WB|2|2u)
    [[ $ALLOW_ATTR_WB -eq 1 ]] || fail "NORMAL_WB marks DRAM cacheable and is not allowed without --allow-attr-normal-wb"
    echo "NORMAL_WB: DRAM is Normal/Write-Back/Write-Allocate and SHAREABLE, MMIO stays"
    echo "           Strongly-ordered. The section descriptor also drops PL0 access"
    echo "           (AP 11 -> 01), which is F-AM2 and safe because everything in the"
    echo "           payload runs at PL1. Cacheable descriptors do nothing on their own:"
    echo "           the cache switches below decide whether they are used."
    ;;
  *)
    fail "unrecognised STAGE90_PMAP_ATTR_MODE: $(value_of STAGE90_PMAP_ATTR_MODE)"
    ;;
esac

echo
echo "== caches =="
case "$(value_of STAGE90_CACHE_MODE)" in
  STAGE90_CACHE_MODE_NONE|0|0u)
    echo "none: SCTLR.C and SCTLR.I both clear, as in every stage so far."
    echo "      Cacheable DRAM descriptors, if the mode above sets them, are then"
    echo "      treated as non-cacheable by the hardware."
    ;;
  STAGE90_CACHE_MODE_ICACHE|1|1u)
    [[ $ALLOW_ICACHE -eq 1 ]] || fail "the I-cache is enabled and that is not allowed without --allow-icache"
    echo "I-cache: SCTLR.I set at MMU enable time, after an ICIALLU. This is XNU's own"
    echo "         order - its start.s enables the I-cache in its first instructions."
    echo "         It is safe here only because nothing in this payload writes code at"
    echo "         runtime; the Mach-O loader is the path that eventually would, and it"
    echo "         currently refuses to copy at all. What to look for in the log: the"
    echo "         same kernel_entry ok as the default build, and on a real regression a"
    echo "         prefetch abort with a plausible pc rather than a silent difference."
    ;;
  STAGE90_CACHE_MODE_ICACHE_DCACHE|2|2u)
    [[ $ALLOW_DCACHE -eq 1 ]] || fail "the D-cache is enabled and that is not allowed without --allow-dcache"
    echo "I-cache + D-cache: SCTLR.I and SCTLR.C, the D-cache after the MMU is already on"
    echo "         and after a whole-cache clean-and-invalidate. This is the full Phase 1"
    echo "         configuration. It is the first run where the payload is not"
    echo "         immediately-visible memory, so the things to read in the log are the"
    echo "         ones that depend on cache maintenance being right:"
    echo "           - ram_console must still log, and the whole log must be there (it is"
    echo "             mapped non-cacheable even in NORMAL_WB, so it should not need any"
    echo "             maintenance - a truncated or stale log would mean that failed);"
    echo "           - the candidate-L1 window and the TTBR0 roundtrip must still verify"
    echo "             their translations, which is what the table cleans are for;"
    echo "           - the timer IRQ must still be delivered and the device must come back"
    echo "             on its own."
    echo "         A device that hangs here costs a power press, and the two nets are both"
    echo "         armed, so it comes back either way - but the log is how the failure is"
    echo "         told apart from a stale-cache symptom, which is why it is read first."
    ;;
  *)
    fail "unrecognised STAGE90_CACHE_MODE: $(value_of STAGE90_CACHE_MODE)"
    ;;
esac

echo
echo "== mapping attributes: consistency =="
if [[ ! "$(value_of STAGE90_CACHE_MODE)" =~ ^(STAGE90_CACHE_MODE_NONE|0|0u)$ ]] &&
   [[ ! "$(value_of STAGE90_PMAP_ATTR_MODE)" =~ ^(STAGE90_PMAP_ATTR_MODE_NORMAL_WB|2|2u)$ ]]; then
  fail "the I-cache is enabled but DRAM is not marked cacheable, so it would cache nothing"
fi
echo "ok: cache and attribute switches agree"

echo
echo "All checks passed. The run is one command, which re-runs this gate with the same flags,"
echo "enters fastboot, boots the image without writing anything to storage, and captures the"
echo "log before anything else touches the device:"
echo
echo "  $SCRIPT_DIR/run_and_capture.sh $*"
echo
# What a run's exit status can mean is read out of run_and_capture.sh here rather than asserted above
# (the 520 rule: a claim in this gate's prose is computed at gate time from the artifact it
# describes). That is not academic. This gate said "exit 2 is adb's reading alone" - true when it was
# written, and false by the evening of 2026-09-22, when the runner's wait section gained a second
# channel: the host's own USB log, keyed on the *serial* rather than the port. The two readings differ
# on this phone, and the difference is measured, not hypothetical - at 19:22:45 that day the device
# enumerated 2717:0368 (serial 4a2fe00b) for 18 s and dropped without ever reaching 18d1:4ee7, so it
# returned to the host without returning to adb. Those are now different codes, and a sentence that
# names one code is stale the moment the runner grows another. So this clause reads the *shape* of the
# wait section and prints each code in the runner's own words, which cannot go stale in this file.
RUNNER=$SCRIPT_DIR/run_and_capture.sh
REGION=$(sed -n '/^# --- 4\. wait for it to come back/,/^# --- 5\./p' "$RUNNER" 2>/dev/null || true)
if [[ -n $REGION ]]; then
  # read in command position - leading whitespace then `exit N` - so a code named inside a message is
  # not counted as one the section can return. Both sorts are pinned to one locale: a set sorted in
  # one collation and merged in another is one value with two definitions, which is this project's
  # most-repeated defect (536).
  #
  # **`die` is the section's other spelling of an exit site, and a census that counted only the literal
  # one was invariant to a `die` being added.** Measured on this project's own two revisions of the
  # runner: the wait section went from one `die` to two (620), and the literal-only count printed `3`
  # for both - so the number the operator reads did not move when the section gained a state. The code
  # is therefore read out of `die()`'s own definition, the way `SERIAL`/`LOGFILE` are read below, rather
  # than assumed to be 1. The pattern is anchored to command position for the *listing* deliberately:
  # the paragraph above this clause quotes a historical "exit 2 ... exit 1" in prose, and an unanchored
  # substring scan would list this gate's own sentence as a site in the runner. The `|| die` spelling is
  # the same exit path written differently and is matched too - it is outside section 4 today
  # (measured, at :2182/:2202/:2204/:2329/:2337), so this changes nothing now and stops the next one
  # being invisible.
  DIE_DEF=$(grep -m1 -E '^die\(\)' "$RUNNER" 2>/dev/null || true)
  DIE_CODE=$(grep -oE 'exit [0-9]+' <<<"$DIE_DEF" 2>/dev/null | head -1 | awk '{print $2}' || true)
  DIE_RE='^[[:space:]]*(\|\|[[:space:]]*)?die[[:space:]]'
  DIE_SITES=$(grep -cE "$DIE_RE" <<<"$REGION" || true)
  NSITES_LIT=$(grep -cE '^[[:space:]]*exit [0-9]+' <<<"$REGION" || true)
  NSITES=$(( NSITES_LIT + DIE_SITES ))
  CODES=$( { grep -oE '^[[:space:]]*exit [0-9]+' <<<"$REGION" | awk '{print $2}' || true
             printf '%s\n' "$DIE_CODE"
           } | grep -E '^[0-9]+$' | LC_ALL=C sort -n | LC_ALL=C uniq | tr '\n' ' ' || true )
  CODES=${CODES% }
  # the serial and the log path are read out of the runner too, because they are one value with two
  # definitions otherwise: the runner's `${VAR:-default}` lines are the ones the boot actually uses, so
  # a change there moves the artifact and this gate's sentence together. Matched with a `case` glob
  # rather than a regex - `${SERIAL:-` contains a `$`, a `{` and a `:`, and every one of them is a
  # meta-character in some language; inside single quotes they are all literal.
  SER=; LOG=
  while IFS= read -r _l; do
    case $_l in
      'SERIAL=${SERIAL:-'*'}')  SER=${_l#'SERIAL=${SERIAL:-'};  SER=${SER%'}'} ;;
      'LOGFILE=${LOGFILE:-'*'}') LOG=${_l#'LOGFILE=${LOGFILE:-'}; LOG=${LOG%'}'} ;;
    esac
    if [[ -n $SER && -n $LOG ]]; then break; fi
  done < "$RUNNER"
  SER=${SERIAL:-${SER:-4a2fe00b}}
  LOG=${LOGFILE:-${LOG:-/tmp/cancro-last_kmsg.txt}}
  echo "== what run_and_capture.sh's exit status can mean =="
  if [[ -z ${CODES// /} ]]; then
    fail "run_and_capture.sh's wait section returns no exit code at all, so what a run's status means is not established from this gate - and a section that cannot say it failed is not a bounded wait"
  fi
  # The lines are named rather than the words quoted. A paraphrase here would be this gate's sentence
  # about another file, which is the defect this clause exists to remove; and quoting the last `say`
  # before each `exit` prints a *fragment*, because the runner wraps its messages - measured, it
  # printed `sudo adb -s $SERIAL exec-out ...` as if it were what exit 3 means. So the gate reads the
  # shape and points at the words, which are the runner's own and cannot go stale in this file.
  START=$(grep -m1 -n '^# --- 4\. wait for it to come back' "$RUNNER" | cut -d: -f1)
  echo "read out of that section at gate time: $NSITES exit site(s) ($NSITES_LIT written 'exit N', $DIE_SITES"
  echo "  written as a 'die' call whose code is die()'s own), distinct code(s) $CODES, at"
  # The two spellings are merged and sorted by line number before printing. Printed as two blocks they
  # come out of order - measured: with 620 uncommitted the `die` at 2657 printed *after* the literal
  # `exit` at 2714 - and a list of a file's exits that is not in the file's order reads as if the file
  # ran out of order. `|| true` on each pipeline because this gate runs under `set -e` with `pipefail`
  # (its :16): a `grep` that matches nothing fails the pipeline, and here that is a case with an
  # answer, not an error.
  { grep -nE '^[[:space:]]*exit [0-9]+' <<<"$REGION" \
      | awk -F: '{ c = $2; gsub(/[^0-9]/, "", c); printf "%d\t%s\texit %d\n", $1, $1, c }' || true
    if [[ $DIE_SITES -gt 0 ]]; then
      grep -nE "$DIE_RE" <<<"$REGION" \
        | awk -F: -v c="${DIE_CODE:-?}" '{ printf "%d\t%s\tdie -> exit %s\n", $1, $1, c }' || true
    fi
  } | LC_ALL=C sort -n \
    | awk -v s="${START:-0}" -F'\t' '{ printf "    run_and_capture.sh:%d   %s\n", s + $1 - 1, $3 }' || true
  echo "which code means which state is that file's own wording at those lines - read them there"
  # The code a `die` returns is not written on its line, so it is narrated here once rather than left
  # to the reader of several call sites. **Code ${DIE_CODE} has two producers in that section and
  # neither owes a power press**: the host could not read its own USB log (that is a reading of the
  # *host* failing - there is no reading of the device at all), and the boot call itself reporting no
  # success (so a non-return after it is not a verdict about the payload). Both are the section
  # refusing to call the run a non-return, which is exactly why a press spent on them buys nothing.
  if [[ $DIE_SITES -gt 0 ]]; then
    echo "the ${DIE_SITES} die site(s) above exit ${DIE_CODE:-?} - read out of die()'s definition, because a die"
    echo "call does not carry its code on the line. In this section that code has two producers and neither"
    echo "owes a power press: the host could not read its own USB log (a reading of the host failing, not of"
    echo "the device), and the boot call reporting no success (so a non-return after it is not a verdict"
    echo "about the payload). Both refuse to call the run a non-return - the press is owed only by the code"
    echo "whose own message says the device did not come back. The lines above name each producer's state in"
    echo "that file's own words, and the code set is checked against this gate below; the *count* of"
    echo "producers within one code is not checked, so a third one would change this sentence silently."
  fi
  # **Scope, stated, because the count above is a count of one region and reads like a count of the
  # file - and because it now counts both spellings of an exit site.** Section 5's capture step grew a
  # second `exit 3` (the returned run whose capture failed), so the section's number is false of the
  # file while true of the section; and the section's own `die` calls are exit sites whose code is not
  # written on the line, so a literal-only census was blind to one being added (measured above). Both
  # censuses are printed, each over both spellings; only the section's codes are the ones this clause
  # narrates, because that is the region whose states the sentences below describe.
  NSITES_ALL_LIT=$(grep -cE '^[[:space:]]*exit [0-9]+' "$RUNNER" || true)
  DIE_SITES_ALL=$(grep -cE "$DIE_RE" "$RUNNER" || true)
  NSITES_ALL=$(( NSITES_ALL_LIT + DIE_SITES_ALL ))
  CODES_ALL=$( { grep -oE '^[[:space:]]*exit [0-9]+' "$RUNNER" | awk '{print $2}' || true
                 if [[ $DIE_SITES_ALL -gt 0 ]]; then printf '%s\n' "$DIE_CODE"; fi
               } | grep -E '^[0-9]+$' | LC_ALL=C sort -n | LC_ALL=C uniq | tr '\n' ' ' || true )
  CODES_ALL=${CODES_ALL% }
  echo "for scope: this file has $NSITES_ALL exit site(s) in total over both spellings, code(s) $CODES_ALL -"
  echo "  so the count and the codes above are section 4's, and a code can have a second producer outside it."
  # The codes this gate's text explains. A code outside this set is not narrated here in the gate's
  # own words, and the safe direction is to stop rather than paraphrase a state nobody has read: that
  # is the same shape as the entry arm's build-stop repair, an alarm on a drift rather than a proof.
  # 1 is in the set because the section can reach it - through `die()`, whose code is read out of its
  # own definition above - and it is a state this gate does narrate (neither of its producers owes a
  # press). Leaving it out made the guard fire on a code the gate had just described.
  READ_CODES="1 2 3"
  for c in $CODES; do
    case " $READ_CODES " in
      *" $c "*) ;;
      *) fail "run_and_capture.sh's wait section can return $c, which is not a code this gate's reading explains ($READ_CODES) - read section 4 and update this gate before spending a boot on a run whose status it cannot narrate" ;;
    esac
  done
  if [[ $NSITES -gt 1 ]]; then
    echo "So a non-return is not one thing in that section: it distinguishes states, and its codes are"
    echo "not interchangeable - one of them says the device *did* come back, into a state adb cannot"
    echo "reach, which is a capture failure and not a hang. Before recording any of them, confirm"
    echo "against the host's own log, by serial and not by port (this host's port has a second occupant"
    echo "that appears on its own after hours of silence, so a port-only test reads *that* as a return):"
    echo "  sudo dmesg | grep $SER                 # bare dmesg prints nothing on this host"
    echo "and remember what that log cannot say: a payload that never returned and a phone whose Android"
    echo "failed to come up are the same reading in adb alone, which is why exit 2 was too wide a claim."
    echo "Only the code whose own message says the device did not come back owes a power press - not the"
    echo "one that refuses to call this a non-return - and the log at $LOG survives only until that"
    echo "press, so read it first."
  else
    echo "So that section has a single verdict and the code above is it. Before recording it as a hang,"
    echo "look for an enumeration on usb 3-10 *after* the fastboot disconnect (the jump) - an enumeration"
    echo "there is a return whatever adb said:"
    echo "  sudo dmesg | grep 'usb 3-10'           # bare dmesg prints nothing on this host"
    echo "The log of the run that returns is at $LOG. A power press is owed for that code, and the log"
    echo "goes with the power cycle, so read it first rather than power-cycling on the spot."
  fi
else
  echo "== what run_and_capture.sh's exit status can mean =="
  echo "UNREAD - the wait section could not be read out of run_and_capture.sh, so which states it"
  echo "distinguishes, and therefore what its exit status asserts about the device, is not established"
  echo "from here. Read section 4 of that file by hand before narrating a run's outcome."
fi

# **And the log those instructions name is, right now and usually, NOT the coming run's.** Both
# branches above end by telling the reader to read the file at `$LOG` - and the runner only writes it
# in step 5, which it reaches **only if the device returned** (`RETURNED` true). On the path that
# refuses to call a non-return (the code whose message names this file), and on both `exit 2` paths,
# the script leaves before that step - so as of 562 the file on disk is very often the previous run's,
# and there is a specific trap in that, not a general caution: the log left there by the 2026-09-22 run
# already carries **exactly the bracket 547 section 4 pre-registers** - one `pre_calls`, one
# `rtcpre_calls`, `post_calls` absent - because it is the death that prediction was written from. A run
# whose capture failed, read through that file, would confirm the prediction with the data that
# produced it, and the confirmation would be unattributable (the position of the keys in the file
# cannot separate the two runs either: the ram console's two blocks make line order chronological only
# within a block). The gate cannot check this after the run - it is a preflight - so it does the two
# things it can: it records what the file *is* at the only moment a "before" exists, and it names the
# bracket already in it rather than describing the hazard.
#
# **564 then removed the trap at the source, and it changed what "`$LOG` is untouched" means - do not
# read the next sentence the way 562 wrote it.** Its new step 2b **parks** the file - `mv $LOGFILE
# $LOGFILE.prev` - **before** step 3 boots anything, so on a non-return `$LOG` is not "untouched", it is
# **absent**, and the previous bytes are at **`$LOGFILE.prev`**. That is the operational point and it
# bites at the worst moment: after a non-return the reader who wants the previous bracket must read the
# parked path, and the absence of `$LOG` is the *expected* state rather than evidence about the run. On
# a returned run the name holds this run's capture or nothing, and the previous bytes cannot be mistaken
# for this run's **even if they are identical**, which a hash comparison cannot do. So the post-run test
# is **whether `$LOG` exists and is non-empty**, not a sha; the runner, not the gate, is where the
# before-state lives (one value, one definition).
#
# What this record still is, and why the block stays rather than being deleted: the operator's
# *independent* record, the fingerprint that identifies a **parked** file as the one this gate saw, and
# the one comparison that still applies - when step 2b's park **failed** (sticky `/tmp`, identities
# 511/512), the runner says so and tells the reader to compare this sha. What it is **not** is the test.
#
# **589: the printed block said less than this comment knew, and one of its sentences was false in the
# state the next run is in.** The narration asserted "the PREVIOUS log was parked rather than lost" for
# a name that is gone after the run - unconditionally, before the state test - while step 2b parks
# *nothing* when there was nothing at the name at gate time (`PARK=nofile`), which is `$LOG`'s state
# whenever the previous run's capture failed to return (the last several did; only `.prev`/`.prev.2`
# remain). So in the absent state the block offered the reassurance ("parked, not lost") for the very
# observation the next paragraph reads as *the capture failed*, and it asserted a `mv` that will not
# run - the same shape as 588 one file over, in the same moment (the log is in DRAM, one power press
# destroys it). It said **nothing** about the state where the sha *is* the test, which is the exception
# the paragraph above already describes: whether the park succeeds is a fact about `/tmp`'s sticky bit
# and the file's identity, and the gate cannot see it from here, so that one belongs in the output too.
# Both are printed text only - no branch, no exit code, no read added - and the park's `mv` is still
# the runner's, not the gate's.

echo "== the log those instructions name, as it stands at gate time =="
echo "  $LOG"
echo "  this is a reading of THIS moment, not a claim about the run: the gate cannot see whether a run"
echo "  follows it, and run_and_capture.sh's step 2b parks this file before the boot (that file's own"
echo "  564). So after the run the test is not this number: it is whether $LOG is there at all, and"
echo "  whether what is there is non-empty - the hand retry exit 3's message asks for is a shell"
echo "  redirect, which creates the file before adb can fail. One state is the exception and the gate"
echo "  cannot see it from here, because whether the park *succeeds* turns on /tmp's sticky bit and the"
echo "  file's identity (511/512): if step 2b could not move this file aside, the earlier log stays at"
echo "  this name, a capture that fails leaves it looking untouched, and *then* the fingerprint below is"
echo "  the test - the runner says so in its own words when it takes that branch."
echo "  And the earlier log is not lost when this name is gone after the run: step 2b parks the file"
echo "  at $LOG.prev (then .prev.2, ...) whenever there is one to park, and that path is where an"
echo "  earlier bracket lives. Read it for the earlier death and never as this run's, whatever the"
echo "  bracket in it says - and read 'gone with nothing parked' as the capture it is, not as the park"
echo "  it is not: with nothing at this name at gate time (the absent case below) step 2b has nothing to"
echo "  move, so an absence after the run is this run's capture having failed, not an earlier log tucked"
echo "  away."
if [[ ! -e $LOG ]]; then
  echo "  absent - and that is the useful part: after the run, this file *existing* is itself the first"
  echo "  check, because nothing here writes it before a capture succeeds. Step 2b says the same thing"
  echo "  about this exact state ('no log at ... yet'), and step 5 reads into $LOG.new and renames it"
  echo "  into place only on a non-empty read - so a name still absent afterwards captured nothing,"
  echo "  whatever the exit code said."
elif [[ ! -r $LOG ]]; then
  echo "  UNREAD - present but not readable by $(id -un), so its contents cannot be fingerprinted here."
  echo "  A hand re-capture under sudo leaves the file root-owned; read it as root before attributing"
  echo "  anything to the coming run, and fingerprint it as root too."
else
  LOG_SHA=$(sha256sum "$LOG" | cut -d' ' -f1 || true)
  echo "  now: $(stat -c '%s bytes, mtime %y' "$LOG")"
  echo "       sha256 $LOG_SHA"
  # The reader's own rule is `tail -1` (run_and_capture.sh's `keyval`: last occurrence wins), so the
  # last value is printed beside the count - a count alone cannot say *which* record a reader would
  # take, and this project has paid for that distinction more than once.
  for _k in pre rtcpre post; do
    _c=$(grep -ac "xnu_live_slot_${_k}_calls=" "$LOG" || true)
    _v=$(grep -ao "xnu_live_slot_${_k}_calls=[0-9a-fx]*" "$LOG" 2>/dev/null | tail -1 || true)
    printf '       %-40s %s record(s)%s\n' "xnu_live_slot_${_k}_calls" "$_c" \
      "${_v:+, last $_v}"
  done
  _p=$(grep -ac 'xnu_live_slot_pre_calls=' "$LOG" || true)
  _r=$(grep -ac 'xnu_live_slot_rtcpre_calls=' "$LOG" || true)
  _q=$(grep -ac 'xnu_live_slot_post_calls=' "$LOG" || true)
  if [[ ${_p:-0} -ge 1 && ${_r:-0} -ge 1 && ${_q:-0} -eq 0 ]]; then
    echo "  ** This file already carries the bracket 547 section 4 pre-registers for the arm in out/:"
    echo "     pre and rtcpre published, post absent. It is an EARLIER run's log - the 2026-09-22 death"
    echo "     the prediction was written from - so it cannot confirm anything about the coming run."
    echo "     If its sha256 is the same after the run, the run produced no capture at all, and the"
    echo "     bracket above is the one that was there before it."
  fi

  # =================================================================================================
  # **The report's two families, and the keys the stop is named by - because in this very file the two
  # keys a reader is taught to classify a stop with are not readings at all.**
  #
  # Every key the log carries from the epilogue is written *after* the epilogue has cleared SCTLR.C and
  # then SCTLR.M - i.e. after the mmu is off, so every address is physical - and so its value is
  # whatever a plain load finds in DRAM at that moment. Two things can make that not the value the run
  # had, and this project has paid for both: the line never reached DRAM (195: a dirty line "reads back
  # as the zeroes `.bss` was filled with"), or the read is not faithful while the memory is (272's
  # 88-word build, same source and same layout size as its working twin, "reads the small `.bss` globals
  # as garbage" - `xnu_entry_why` as the linker's `__entry_text_end`, and `.rodata` string bytes across
  # the `g_first_abort_*` block). 272's rule is the one to read this block by: **a field is only as good
  # as its second road.**
  #
  # The fixture publishes the second road itself, in the pair's own text: `xnu_entry_kv_written` "is
  # what the probes recorded, read from a register, so it is right even if the transfer to DRAM was
  # not", and `xnu_entry_kv_in_dram` "is what the transfer actually produced - they differ only when it
  # failed". **So the pair is the test that decides whether a report's small-`.bss` family is a reading
  # at all** - and it is a test over the *file*, not over the source, which is why it is computed below
  # from whatever $LOG holds at gate time rather than asserted here.
  #
  # What makes this worth a clause rather than a sentence in a document is that the family includes the
  # two keys a reader is most likely to take first. `xnu_entry_why` and `xnu_entry_why_byte` come from
  # `g_why`, a small `.bss` global, and 340's rule for them is that the byte "is the first byte of the
  # `why` string, which makes it a one-character telegraph" of the kind of stop (`0x61` = 'a', a stub;
  # `0x65` = 'e', an exception). **In the 2026-09-22 capture the byte reads `0x00000034`** - '4', and
  # the report's own opening line reads `real XNU entry: 47`, i.e. the first character of those same
  # two bytes, so the pair is two roads to one bad read and not two witnesses. **That line is the
  # fixture's own known artifact**: its note on `g_why` records that this line has come out as `... : `
  # with nothing after it and, in the storm run, as `... : 47`, and says of both that they are "what a
  # clobbered stack slot looks like, and neither is what the string says" - the `.bss` copy exists
  # *because* of that reading, so a report in which even the copy is wrong is the case 272 describes,
  # not a new one. Neither reading is a classification and neither is the stop's reason being absent:
  # `0x34` is not the first byte of any `why` string this image has, and the set of those first bytes
  # is derived below rather than written here, so a byte outside it is read as an *unreadable* reason
  # rather than as a kind - which is the reading that was once taken wrongly in this phase, from a
  # grep for the reason *strings* while the report was carrying these two keys all along.
  #
  # The same family explains the *absence* of the results buffer, and that absence is the one thing
  # this report is not allowed to leave ambiguous: the fixture's own doctrine, written for the trap
  # record's buffer, is that "one heading per buffer is also what makes the *absence* of one of them
  # readable" - its heading is printed together with the counter that says whether its writer ran. The
  # first buffer's heading is guarded instead on `g_kv_len`, the same small `.bss` global the pair's
  # `_in_dram` reads, so a failed transfer suppresses the buffer *and* the evidence of the failure with
  # it. The counts below are the reader's substitute: the fixture's own `entry_write()` sites for that
  # heading, against the number of them in the file.
  #
  # This is a reading of the file at gate time and never a claim about the coming run (563's tense
  # rule): after the run $LOG is this run's capture or absent, and this clause has already said what
  # the *parked* file's report can be quoted for.
  FIXTURE=$SRC_DIR/entry/entry_stubs.c
  _lastv() { grep -ao "$1=[0-9a-fx]*" "$LOG" 2>/dev/null | tail -1 || true; }
  _ishex() { [[ $1 =~ ^0x[0-9a-f]+$ ]]; }
  _zero()  { _ishex "$1" && (( 16#${1#0x} == 0 )); }
  # What the fixture publishes each key from: a `.bss` global, or a local the ABI keeps in a register.
  # Derived from the call rather than listed here, and it says so out loud when it cannot tell - a
  # classification that prints nothing when its subject moves is indistinguishable from one that ran.
  _fam() {
    [[ -f $FIXTURE ]] || { printf 'not read: no fixture at gate time'; return 0; }
    local call
    call=$(grep -o "entry_write_kv(\"$1\",[^;]*" "$FIXTURE" 2>/dev/null | head -1 || true)
    [[ -n $call ]] || call=$(grep -o "entry_panic_kv(\"$1\",[^;]*" "$FIXTURE" 2>/dev/null | head -1 || true)
    if [[ -z $call ]]; then printf 'NOT FOUND in this fixture'; return 0; fi
    local arg=${call#*\",}; arg=${arg# }; arg=${arg%)}
    if [[ $arg =~ (^|[^a-zA-Z0-9_])g_[a-z] ]]; then printf '`%s` (a .bss global)' "$arg"
    else printf '`%s` (a local - register-held)' "$arg"; fi
  }
  _whyfirst=$(grep -o 'entry_epilogue("[^"]' "$FIXTURE" 2>/dev/null | sed 's/.*"//' \
              | LC_ALL=C sort -u | tr -d '\n' || true)
  _whyhex=$(printf '%s' "$_whyfirst" | od -An -tx1 | tr -s ' ' | sed 's/^ //; s/ $//; s/ /-/g' || true)
  _hdr=$(grep -ac 'MI4IOS6_STAGE90_XNU real XNU entry' "$LOG" || true)
  _hdrsites=$(grep -c 'entry_write(".*MI4IOS6_STAGE90_XNU real XNU entry' "$FIXTURE" 2>/dev/null || true)
  _guard=$(grep -c 'if (g_kv_len != 0u)' "$FIXTURE" 2>/dev/null || true)
  _pw=$(_lastv xnu_entry_kv_written); _pw=${_pw#*=}
  _pd=$(_lastv xnu_entry_kv_in_dram); _pd=${_pd#*=}
  _val() { local v; v=$(_lastv "$1"); printf '%s' "${v#*=}"; }
  echo "== the report's two families, read out of the file and the fixture at gate time =="
  _hasreport=0
  for _k in xnu_entry_kv_written xnu_entry_kv_in_dram xnu_entry_why xnu_entry_why_byte; do
    if [[ -n $(_val "$_k") ]]; then _hasreport=1; fi
  done
  if (( _hasreport == 0 )); then
    echo "  this file carries no epilogue report at all, so there is nothing in it to classify by family"
    echo "  - no pair, no why, no heading. That is a statement about $LOG and not about the image: the"
    echo "  fixture still writes all of them, and a run's capture will carry them."
  elif ! _ishex "$_pw" || ! _ishex "$_pd"; then
    echo "  the pair is not here in full (written=${_pw:-absent}, in_dram=${_pd:-absent}): either this"
    echo "  file is older than the pair, or the pair is among the lines that did not survive the write."
    echo "  No *value* in it is classified by family below; the two lines that follow classify the"
    echo "  fixture's sources, which is not the same claim. Read the fixture's own note on the pair"
    echo "  before taking any report key here as a reading."
  else
    echo "  xnu_entry_kv_written=$_pw  from $(_fam xnu_entry_kv_written)"
    echo "  xnu_entry_kv_in_dram=$_pd  from $(_fam xnu_entry_kv_in_dram)"
    if _zero "$_pd" && ! _zero "$_pw"; then
      echo "  ** THE PAIR DISAGREES, and this is what that buys: with written non-zero the probes did"
      echo "     record bytes, so in THIS file the small-.bss family did not read back, and every key"
      echo "     published from a .bss global is the zeroes .bss was filled with and not a reading."
      echo "     That is the family the two keys below belong to, and by the same reading the results"
      echo "     buffer below was not empty, it was never dumped - the two are different absences."
    elif _zero "$_pw" && _zero "$_pd"; then
      echo "  the pair is zero on both sides, which is a report from a run whose probes recorded nothing:"
      echo "  it says nothing about the transfer, so the family classification below is unproven here."
      echo "  (On a real boot this pair going to zero on BOTH sides is itself the news: the probes run"
      echo "  unconditionally in the epilogue. Read the live channel, not this pair, for that.)"
    else
      echo "  the pair agrees, so this file's .bss family did read back: its report keys - the two below"
      echo "  included - may be taken as the fixture's own values, subject to the second road 272 asks"
      echo "  for, which for the death's shape is the live channel and not this report."
    fi
  fi
  _w=$(_val xnu_entry_why); _wyb=$(_val xnu_entry_why_byte)
  echo "  xnu_entry_why=${_w:-absent}  from $(_fam xnu_entry_why)"
  echo "  xnu_entry_why_byte=${_wyb:-absent}  from $(_fam xnu_entry_why_byte)"
  _wb=${_wyb: -2}
  if [[ -z $_whyhex ]]; then
    echo "  UNREAD - the first bytes of this fixture's why strings could not be derived from $FIXTURE,"
    echo "  so whether a why_byte is one of them is not a check this gate can make. Read them out of the"
    echo "  image by hand before classifying a stop with that byte."
  elif [[ -z $_wb ]]; then
    echo "  no why_byte in this file, so there is nothing to test against them."
  elif [[ $_whyhex == *"$_wb"* ]]; then
    echo "  ok: 0x$_wb is the first byte of one of this image's why strings ($_whyhex), which is the"
    echo "  cheapest classification there is - but it names the KIND of stop, never which one."
  else
    echo "  ** 0x$_wb is NOT one of this fixture's why strings' first bytes ($_whyhex), so it classifies"
    echo "     nothing: it is a byte read through a pointer that is not a string - 'a' and 'e' are the"
    echo "     two this project has read, and a value outside the set above means the read is the news."
  fi
  echo "  the report's opening line: $_hdr occurrence(s) here, $_hdrsites write site(s) in the fixture"
  if (( _hasreport == 0 )); then
    echo "  and there is no heading to compare, because the check above is a check on a report's"
    echo "  completeness and this file has no report: it says nothing about the run that wrote it."
  elif [[ -z $_hdrsites || $_hdrsites == 0 ]]; then
    echo "  UNREAD - the fixture's own heading count could not be derived, so the comparison below did"
    echo "  not happen. Read its own entry_write() sites for that literal before reading a missing"
    echo "  results buffer as an empty one."
  elif [[ ${_hdr:-0} -lt ${_hdrsites:-0} ]]; then
    echo "  and that is fewer than the fixture writes it: the later heading - the one before the results"
    if [[ ${_guard:-0} -gt 0 ]]; then
      echo "  buffer - was skipped, because it is guarded on g_kv_len, the same .bss global the pair reads."
    else
      echo "  buffer - was skipped, and its guard ($_guard site(s) matched in the fixture) is not one this"
      echo "  clause can name: read the guard out of the fixture by hand before attributing the skip."
    fi
    echo "  ** So the results buffer's absence in this file is 'not dumped', which is not 'empty' - the"
    echo "     buffer is printed only when g_kv_len is non-zero, and that is the same global _in_dram"
    echo "     above reads, so the guard and the evidence cancel. What the probes did record this run is"
    echo "     the register-held xnu_entry_kv_written, and where the arm and the death's shape are read is"
    echo "     the live channel (xnu_live_*) - the printed report is not the only road, which is the point."
  else
    echo "  which is what a complete report carries, so the results buffer is in this file."
  fi
fi

# **And the one address the result reader compares against, checked here because here is the only
# place both of its definitions are readable** - the reader's own rule, turned on the reader. 554's
# shape test separates a *predicted* pop death from a *surprise* by comparing the log's published
# `xnu_live_sleh_lr` against the address the exit's own `bl FlushPoU_Dcache` returns to, and the
# reader **derives** that address from `out/stage90/xnu_arm_entry.elf` at run time, falling back to a
# literal (`EXIT_POP_LR_LITERAL`) when the ELF cannot be read - a cleaned `out/`, or a summarise run
# in another tree. The fallback is *labelled* in the log, which is the right direction, but a label
# is not a check: it is a second definition of one address, and **this gate is the one place that can
# compare the two**, because at summarise time the ELF is precisely what was not readable. So the
# comparison happens here, and a disagreement stops the gate instead of a run: a log read through the
# fallback would attribute the death by a number that is not in the image, and 554's three-way test
# would print FAIL for the death 547 section 4 predicts. The test is scoped to the *function* the
# reader's comment names (`platform_cache_idle_exit`), because the image calls `FlushPoU_Dcache` from
# several sites and only the caller tells them apart - guarding on the callee is not a style choice
# here but the only thing that separates this seam from the others. **535 moved that**: with
# `--wrap=FlushPoU_Dcache` in the link every caller branches to one wrapper, so the seam is separated by
# the filter *inside* the wrapper and not by the call site - which is why the printed line below now
# says which of the two mechanisms this image uses instead of asserting the first one. **The count is printed from this
# image rather than asserted here**, because this project's notes carried six for it, having listed
# the two `FlushPoC_Dcache` references - a *different* callee, `0x80045828` - in the same breath as the
# `bl` sites that reach `FlushPoU_Dcache`. Measured, the second list is four: `0x80045d08`,
# `0x80046284`, `0x800462d8`, `0x800463bc`. That is why the printed line names which callee it counted.
ENTRY_ELF=$OUT/xnu_arm_entry.elf
_GATE_OD=${STAGE90_OBJDUMP:-arm-none-eabi-objdump}
# The parse accepts *both* disassemblers' shapes around that call, because they differ and the
# difference looks like an absence: GNU `arm-none-eabi-objdump` prints the instruction line
# `800462dc:\te30101a4 …` directly after the `bl`, while `llvm-objdump` prints a *symbol* line first
# (`800462dc <platform_cache_idle_exit+0x8>:`) and would leave a rule that requires a colon with
# nothing to print - the same failure shape 549 records, a decoder that answers by printing nothing.
# **And the callee's spelling is a property of the link, not of the routine** (535): with
# `--wrap=FlushPoU_Dcache` in it, the exit's call disassembles as `bl 8047cb9c
# <__wrap_FlushPoU_Dcache>` - the string `<FlushPoU_Dcache>` is not in that line, so a pattern written
# as `/<FlushPoU_Dcache>/` matched no line at all and this clause went quiet on the image it exists to
# bind. It was quiet on a `GATE EXIT=0` run, which is the whole defect: the exit code did not say
# that the one clause whose job is to bind the reader's criterion to this image had compared nothing.
# The pattern is therefore about the **routine** and accepts any wrapper prefix - and the branch below
# that used to be the resting state of a wrapped arm is now a hard stop when the decoder did run.
# So the address is taken from the first line after the call that begins with one, colon optional, and
# the function's own entry address is excluded: a parse that returned the entry would be comparing the
# reader's criterion against the top of the function instead of against the return address.
_pop_lr_from_elf() {
  "$_GATE_OD" -d --no-show-raw-insn "$ENTRY_ELF" 2>/dev/null | awk '
    /^[0-9a-f]+ <platform_cache_idle_exit>:/ { infn = 1; a = $1; sub(/:$/, "", a); entry = a; next }
    infn && /<[^<>]*FlushPoU_Dcache>/ && /bl/ { want = 1; next }
    want && /^[0-9a-f]+[[:space:]]*[:<]/     { a = $1; sub(/:$/, "", a); if (a != entry) { print a; exit } }
    /^[0-9a-f]+ <.*>:/                       { infn = 0 }
  '
}
PIN_LINE=$(grep -m1 '^EXIT_POP_LR_LITERAL=0x' "$RUNNER" 2>/dev/null || true)
PIN=${PIN_LINE#*=}
PIN=$(tr 'A-Z' 'a-z' <<<"$PIN")
# `|| true` is load-bearing, and its absence ended this gate's first run of this clause at 141: the
# awk stops at the instruction it wants, the objdump feeding it is still writing, and `pipefail` turns
# that SIGPIPE into the pipeline's status - which `set -e` then reads as a failure of the *gate*. The
# value was correct; the run died before printing it. Same shape as the reader's own `keyval || true`.
DERIVED=$(_pop_lr_from_elf | tr 'A-Z' 'a-z' || true)
# **Two counts, because the callee's spelling is a property of the link** (535). With
# `--wrap=FlushPoU_Dcache` in it, all four callers branch to one address, `<__wrap_FlushPoU_Dcache>`
# (`0x8047cb9c`), and the bare spelling survives only inside the wrapper's own body. A single count
# printed alone was read as "the callers" before 535 and would be read as "the wrapper" after it - one
# value with two definitions (558), and the sentence built on it named the wrong thing as the guard. So
# both spellings are measured and both are printed, and whether `--wrap` is in the link follows from
# the wrapped count being non-zero rather than from a claim here.
FLUSH_SITES=$("$_GATE_OD" -d --no-show-raw-insn "$ENTRY_ELF" 2>/dev/null \
          | grep -cE 'bl[[:space:]]+(0x)?[0-9a-f]+ <[^<>]*FlushPoU_Dcache>' || true)
FLUSH_WRAP=$("$_GATE_OD" -d --no-show-raw-insn "$ENTRY_ELF" 2>/dev/null \
          | grep -cE 'bl[[:space:]]+(0x)?[0-9a-f]+ <__wrap_FlushPoU_Dcache>' || true)
echo "== the address run_and_capture.sh's shape test compares against =="
# **954: on D13 the subject does not exist, and the clause PUBLISHES the skip (549's shape, one file
# over).** D13 ships no `platform_cache_idle_exit` and no `FlushPoU_Dcache` - a `grep` of the tree's
# `osfmk/arm/` is empty for both - so there is no `bl` return address for the reader's 554 shape test
# to be anchored to, exactly as there is no `up_style_idle_exit` for 549. The two are the same fact:
# the idle machinery this whole block narrates is 4570's, and D13's idle is `do_power_save` +
# `machine_routines_asm.s`. Skipping is a published absence rather than a silent one.
if [[ $_entry_tree_d13 -eq 1 ]]; then
  echo "  SKIPPED on D13 - the shape-test anchor does not exist in this tree."
  echo "  D13 ships no platform_cache_idle_exit and no FlushPoU_Dcache (grep of osfmk/arm is empty for"
  echo "  both), so there is no bl return address for run_and_capture.sh's 554 shape test to compare"
  echo "  against. This is 549's clause shape: the subject is 4570's idle machinery. THE READER'S 554"
  echo "  SHAPE TEST IS OWED A TREE-AWARE CRITERION (its lane), because until then a D13 summarise run"
  echo "  falls back to EXIT_POP_LR_LITERAL - a 4570 number - which is the one-value-two-definitions"
  echo "  defect this clause exists to catch from the other side."
elif [[ ! -f $ENTRY_ELF ]]; then
  echo "UNREAD - no $ENTRY_ELF, so the address the death is attributed by cannot be derived here. The"
  echo "reader will fall back to its literal at run time and label it; read $ENTRY_ELF back (it is a"
  echo "build product, and its bin is embedded in the frozen pair) before trusting that label."
elif [[ -z $PIN ]]; then
  # The address can live in the runner in two spellings: as the fallback the reader assigns to a
  # variable, and - before that derivation existed - as the literal inside the `grep` pattern the
  # reader matched the dump with (554 section 2). Only the first is a value this clause may compare:
  # the second is a *comment* in that file's present shape, and a check that read a comment would be
  # reading prose. So the second is printed as what it is, and the comparison does not happen.
  _stray=$(grep -oE 'lr: \*?0x[0-9a-fA-F]+' "$RUNNER" 2>/dev/null | head -1 || true)
  echo "UNREAD - run_and_capture.sh has no 'EXIT_POP_LR_LITERAL=0x...' line, so the fallback the reader"
  echo "uses when the ELF is unreadable is not a value this gate can compare. If that file's fallback"
  echo "was renamed or removed, say so here rather than letting this clause go quiet: a check that"
  echo "prints nothing when its subject moves is indistinguishable from one that never ran."
  if [[ -n $_stray ]]; then
    echo "  (that file does still carry the address as text - '$_stray' - but in a comment, and a"
    echo "  comment is not the value the reader keys on: find the variable it compares against.)"
  fi
elif [[ -z $DERIVED ]]; then
  # **This branch used to be the resting state of a wrapped arm, which is how 535 found it: the
  # pattern did not fit `--wrap`'s spelling, so the clause printed UNREAD and the gate still exited 0.**
  # A quiet clause on a green run is indistinguishable from one that never ran, so the branch now
  # separates the three things that can make DERIVED empty, and only the last of them is a finding
  # about the image: no decoder on PATH and a decoder that printed nothing are properties of *this
  # shell* (549's shape), while a full disassembly with no call in it means the reader's criterion has
  # no anchor - which is a stop, not a note, because the run after it would attribute the death by an
  # address that names no instruction.
  if ! command -v "$_GATE_OD" >/dev/null 2>&1; then
    echo "UNREAD - $_GATE_OD is not on PATH, so nothing in $ENTRY_ELF could be decoded here. That is a"
    echo "property of this shell and not of the arm: the comparison below did NOT happen, and this run"
    echo "says nothing either way about where platform_cache_idle_exit calls FlushPoU_Dcache. Re-run"
    echo "with STAGE90_OBJDUMP=<a disassembler that is installed> before booting."
  else
    _dis_n=$("$_GATE_OD" -d --no-show-raw-insn "$ENTRY_ELF" 2>/dev/null | grep -c '' || true)
    if (( _dis_n == 0 )); then
      echo "UNREAD - $_GATE_OD exited without printing anything for $ENTRY_ELF, which is 549's decoder"
      echo "that answers by printing nothing: a failure to read the image, not a finding about it. The"
      echo "comparison below did NOT happen; check that $ENTRY_ELF is the ELF it is claimed to be."
    else
      fail "$ENTRY_ELF decodes to $_dis_n lines and shows no 'bl <...FlushPoU_Dcache>' inside platform_cache_idle_exit - so the address run_and_capture.sh attributes a pop death by has no anchor in this image, and 554's shape test would compare the log's published lr against a number that names no instruction. The pattern accepts any wrapper prefix ('<__wrap_FlushPoU_Dcache>' as well as '<FlushPoU_Dcache>'), so this is not the --wrap spelling: either this arm moved or removed the exit's flush call, or the callee was renamed. If that was deliberate, the reader's criterion has to move with it and be re-derived where it is defined - do not let this clause go quiet instead, because a check that prints nothing when its subject moves is indistinguishable from one that never ran. Nothing is rebuilt by this refusal: the frozen pair embeds this entry image, so rebuilding it would spend the freeze this gate exists to protect"
    fi
  fi
elif (( 16#$DERIVED % 4 != 0 )) || (( 16#$DERIVED < 16#80000000 )) || (( 16#$DERIVED > 16#fffeffff )); then
  echo "UNREAD - the disassembly gave 0x$DERIVED for the address platform_cache_idle_exit's flush"
  echo "returns to, and that is not a 4-byte-aligned kernel address, so this clause parsed a line that"
  echo "is not that instruction - a data word, or the function's own entry label. The comparison below"
  echo "did NOT happen, and the reader's fallback is therefore unchecked; read the disassembly by hand."
elif [[ $DERIVED != "${PIN#0x}" ]]; then
  fail "run_and_capture.sh's fallback address for the idle exit's pop is $PIN and $ENTRY_ELF has platform_cache_idle_exit returning from that bl at 0x$DERIVED: two definitions of one address, and they disagree. The reader derives its criterion from this ELF at run time and uses the literal only when the ELF cannot be read, so a log summarised from a tree without out/ would attribute the death by a number that is not in this image - and 554's shape test would then print FAIL for the death 547 section 4 pre-registers for the enable-off arm, which is the defect that clause was written to remove. This gate cannot tell which of the two is stale - the literal, or this ELF and the bin built beside it - so it names the test rather than presuming the answer: disassemble platform_cache_idle_exit by hand. If the address above is this image's, the runner's literal is the one owed a change, and it is a one-line change to a variable that is not the artifact. Nothing is rebuilt by this refusal, and nothing should be: the frozen pair embeds this entry image, so rebuilding it would spend the freeze this gate exists to protect"
else
  echo "ok: the reader's criterion and this image agree - $PIN, derived from $ENTRY_ELF's own"
  echo "  platform_cache_idle_exit, the address its bl into FlushPoU_Dcache returns to. The scoping is what"
  if (( FLUSH_SITES > 0 )); then
    echo "  that function buys: the image branches into FlushPoU_Dcache from $FLUSH_SITES bl site(s) -"
    if (( FLUSH_WRAP > 0 )); then
      echo "  $FLUSH_WRAP of them through the *wrapper* (<__wrap_FlushPoU_Dcache>, one address) and"
      echo "  $(( FLUSH_SITES - FLUSH_WRAP )) spelling the bare callee, which is the wrapper's own body. So --wrap"
      echo "  IS in this link, every caller arrives at one place, and what separates this seam from the"
      echo "  other callers is the return-address filter *inside* the wrapper - the address above - and not"
      echo "  the call site, which is the separation the unwrapped arms had and this one does not."
    else
      echo "  and the guard is on the caller, because only the caller separates this seam from the others:"
      echo "  no call site in this image spells a wrapper, so no --wrap was in the link."
    fi
    echo "  Those are bl sites to *this* routine under each spelling; the two FlushPoC_Dcache references"
    echo "  are another function."
  else
    # The address was read out of a line the count then failed to match, which cannot both be true. So
    # the count is reported as unusable rather than printed as a zero: "no site found" and "the pattern
    # did not fit this decoder's spelling" are different readings, and printing the second as the first
    # is how a wrong number gets quoted as a fact.
    echo "  that function buys: the guard is on the caller and not on the callee, because the image"
    echo "  branches to FlushPoU_Dcache from several sites and only the caller separates this seam from"
    echo "  the others. **The count itself did not fit this decoder's spelling and is NOT reported** - a"
    echo "  zero here would be a parse failure, not a reading."
  fi
fi
echo
echo "== the seam's own body, read out of this image and not out of the record =="
# **575's rule, one layer down.** Which arm this image is gets narrated above out of
# xnu_arm_entry-config.txt - a text file the build writes - and every sentence of that narration is a
# claim about `entry_seam_flush`'s compiled body: "the interception IS in this image and 535's
# operation is NOT" for one arm, "the operation is Apple's own FlushPoC_DcacheRegion over the slot's
# eight bytes" for the other. The build checks the same property where it runs (it refuses
# SEAM_MEASURE=1 with a FlushPoC_DcacheRegion call in the body, and `entry_trace.c` #errors on both
# switches at once), and 575's own lesson is that a claim enforced only where the build runs is
# unchecked everywhere the build does not: this gate reads a record, and a record can describe an image
# that is not the one in out/. So the one property that licenses the boot - the operation is absent
# from the measurement arm and present in 535's - is read here out of the ELF, which is the third place
# it is answered and the only one at gate time. It is the same seam the pair clause above refuses a
# record for: that clause reads the record's two keys against each other, this one reads the record
# against the artifact, and neither is total alone (a record can be internally consistent and wrong).
#
# **What is checked is the callee, not an instruction census, and the difference is measured.** 574's
# table gives the measurement body "0 coprocessor instructions" and prints its test beside the number
# (`$3 ~ /^mcr/`): that pattern is right about `mcr` and blind to the class, because the routine in
# out/ carries one **`mrc`** - `entry_sctlr`'s `15, 0, sl, cr1, cr0, {0}`, a *read* of SCTLR and not a
# cache operation. Measured on both parked bodies: `^mcr` finds 0, `^mrc` finds 1. So the routine is
# 115 instruction lines and 8 stores on this arm, and 118 and 10 on 535's - counts that check against
# 574's own byte figures, 0x1CC = 115 x 4 and 0x1D8 = 118 x 4. Those stores are the
# prologue's callee-saved saves, the seam's own counting words, and, in 535's arm only, the two words
# it restores at `[r5]` and `[r5, #4]`. So "0 coprocessor instructions" and "no store of any kind" are
# false as counts of this routine and true of the slot - and 535's arm is precisely the arm that DOES
# store to the slot. A claim phrased as a census is one a census refutes, so the census below is
# printed as a reading and the stop is on the call that names the operation.
#
# Four UNREAD branches, none of them a finding (549's shape, and the clause above spends its own
# length on the same distinction): no ELF, no decoder, and a decoder that printed nothing are
# properties of *this shell*, while a symbol named in a full disassembly that yet yields no body is a
# parse that did not fit - reported as unusable rather than as a zero. Only the five
# record-versus-body disagreements below stop the gate.
#
# **591: the fourth of them was missing, and it is the one whose absence is silent rather than
# loud.** Each arm's branch stops the gate when the *other* arm's operation is the one in the body,
# and that pair is symmetric - both read `FlushPoC_DcacheRegion`. The measurement arm has a second
# premise and no guard on it: what makes the interception worth reading with nothing behind it is
# that the two reads bracket **Apple's own L1 flush**, i.e. the seam's own `bl FlushPoU_Dcache` - the
# call the ok line below names (its `$_POU_N`) and hands the whole meaning of the pair. With a body
# whose interception passes the call through by a tail branch instead of calling it, `_POC_N` is
# still 0, this branch's only test passes, the gate printed `ok`, and the rule narrated above for
# this arm - an equal pair is the arm working as designed - would be printed over a run in which
# nothing ran between the two reads, so the pair carries nothing and a *return* would be read as the
# arm's own reading. 584 section 2's shape (a property asserted of an artifact by a comparison that
# never ran) and 587's (a clause reading what it could not open), one branch over from the guard the
# other arm has carried since 579.
_SEAM_FN=entry_seam_flush
_seam_stream() { "$_GATE_OD" -d --no-show-raw-insn "$ENTRY_ELF" 2>/dev/null; }
_n_instr() { grep -cE '^[[:space:]]*[0-9a-f]+:[[:space:]]+([0-9a-f]{8}[[:space:]]+)?[a-z]' <<<"$1" || true; }
_n_mnem()  { grep -cE "^[[:space:]]*[0-9a-f]+:[[:space:]]+([0-9a-f]{8}[[:space:]]+)?($1)([[:space:]]|\$)" <<<"$2" || true; }
_n_call()  { grep -cE "bl[[:space:]]+(0x)?[0-9a-f]+ <$1>" <<<"$2" || true; }
if [[ ! -f $ENTRY_ELF ]]; then
  echo "UNREAD - no $ENTRY_ELF, so which arm's body this image carries cannot be read here, and the arm"
  echo "  narrated above rests on the record alone. A record is not the artifact: read the ELF back (it"
  echo "  is a build product whose bin is embedded in the frozen pair) before booting into this image."
elif ! command -v "$_GATE_OD" >/dev/null 2>&1; then
  echo "UNREAD - $_GATE_OD is not on PATH, so the seam's body in $ENTRY_ELF was NOT read. That is a"
  echo "  property of this shell and not of the image (549's shape): re-run with"
  echo "  STAGE90_OBJDUMP=<a disassembler that is installed>. The comparison below did NOT happen."
else
  _dis_n=$(_seam_stream | grep -c '' || true)
  _NAME_N=$(_seam_stream | grep -c "<$_SEAM_FN" || true)
  _BODY=$(_seam_stream | awk -v fn="$_SEAM_FN" '
    $0 ~ "^[0-9a-f]+ <" fn ">:" { infn = 1; next }
    infn && /^[0-9a-f]+ <[^>]+>:/      { infn = 0 }
    infn { print }
  ' || true)
  _BODY_N=$(_n_instr "$_BODY")
  _REC_SEAM=0
  (( V_SEAM_POC == 1 || V_SEAM_MEASURE == 1 )) && _REC_SEAM=1
  if (( _dis_n == 0 )); then
    echo "UNREAD - $_GATE_OD exited without printing anything for $ENTRY_ELF, which is 549's decoder"
    echo "  that answers by printing nothing: a failure to read the image, not a finding about it. The"
    echo "  comparison below did NOT happen; check that $ENTRY_ELF is the ELF it is claimed to be."
  elif (( _BODY_N == 0 && _NAME_N > 0 )); then
    echo "UNREAD - $_SEAM_FN is in $ENTRY_ELF ($_NAME_N line(s) name it) and this parse extracted no"
    echo "  body from it: a parse that did not fit its own shape, not an absent seam (549's shape, which"
    echo "  is why this is reported as unusable rather than as a zero). The comparison below did NOT"
    echo "  happen; disassemble $_SEAM_FN in $ENTRY_ELF by hand."
  elif (( _REC_SEAM == 1 && _BODY_N == 0 )); then
    fail "$ENTRY_CFG records a seam (STAGE90_XNU_SEAM_POC=$V_SEAM_POC, STAGE90_XNU_SEAM_MEASURE=$V_SEAM_MEASURE) and $ENTRY_ELF has no $_SEAM_FN symbol in it at all, so the record names an arm whose body is not in this image and the narration printed above describes a seam this image does not carry. The record-to-bin clause above binds the artifact by hash, and a hash says nothing about what is in the artifact: a record written beside the wrong image passes that clause and stops here instead. Which of the two is stale is not something this gate can tell, so it names the test rather than presuming it - disassemble $ENTRY_ELF and look for $_SEAM_FN, or rebuild the entry image with the switch this arm really needs. Nothing is rebuilt by this refusal, and nothing should be: the frozen pair embeds this entry image"
  elif (( _REC_SEAM == 0 && _BODY_N > 0 )); then
    fail "$ENTRY_CFG records no seam (STAGE90_XNU_SEAM_POC=0, STAGE90_XNU_SEAM_MEASURE=0) and $ENTRY_ELF carries $_SEAM_FN, so the 'NO interception of this image's own' paragraph printed above is being printed over an image that has one - and that paragraph's whole content is that the flush inside the real exit is Apple's own and untested by a run of this image, which is false here. This clause reads FLUSH_WRAP=$FLUSH_WRAP for this link. Which of the two is stale is not something this gate can tell: read $_SEAM_FN's body by hand, or rebuild the entry image with the switch this arm really needs. Nothing is rebuilt by this refusal, and nothing should be: the frozen pair embeds this entry image"
  elif (( _REC_SEAM == 0 )); then
    echo "  no seam in the record and none in the image: $_SEAM_FN is not in $ENTRY_ELF, and the clause"
    echo "  above reads FLUSH_WRAP=$FLUSH_WRAP - so the record's two zeros and this link agree that nothing"
    echo "  of ours sits between the real exit's push {fp, lr} and its pop {fp, pc}. **That the image"
    echo "  carries no seam at all is measured here rather than inferred from those two keys**; *which*"
    echo "  unseamed arm it is still rests on the other keys printed above, so a both-0 record over a"
    echo "  rebuilt non-seam image is that paragraph's shape without being 568's run."
  else
    _POC_N=$(_n_call 'FlushPoC_DcacheRegion' "$_BODY")
    _POU_N=$(_n_call 'FlushPoU_Dcache' "$_BODY")
    _ST_N=$(_n_mnem 'str|strb|strh|strd|stm|push' "$_BODY")
    _CP_N=$(_n_mnem 'mcr|mrc|mcrr|mrrc|cdp|ldc|stc' "$_BODY")
    _LD_N=$(_n_mnem 'ldr|ldrb|ldrh|ldrd|ldm|pop' "$_BODY")
    echo "  $_SEAM_FN, read out of this image: $_BODY_N instructions, $_ST_N stores, $_CP_N coprocessor"
    echo "  instruction(s), $_LD_N loads; it calls FlushPoU_Dcache=$_POU_N and"
    echo "  FlushPoC_DcacheRegion=$_POC_N. The stores are the prologue's callee-saved saves and the seam's"
    echo "  own counting words, plus the two restored words in 535's arm; the coprocessor instruction is"
    echo "  entry_sctlr's read of SCTLR in both arms. Those counts are a reading and not the check: the"
    echo "  check is on the call that names the operation, because the two bodies are built from the same"
    echo "  mnemonics and the same bl count - what differs between them is which routine a bl targets."
    if (( V_SEAM_MEASURE == 1 )); then
      if (( _POC_N != 0 )); then
        fail "STAGE90_XNU_SEAM_MEASURE=1 in $ENTRY_CFG and $_SEAM_FN in $ENTRY_ELF calls FlushPoC_DcacheRegion $_POC_N time(s): the record says 535's operation is NOT behind this seam and the image says it is. The narration printed above is the benign arm's, including the one reading rule that arm is worth - with nothing behind the interception an UNEQUAL b/a pair is Apple's own flush writing the line back - and that rule applied to a run of *this* image would invert the meaning of the very pair the arm exists to produce: the run would come back and be read as the other arm, which is the worst of the four states this clause tells apart. Read $_SEAM_FN's body in $ENTRY_ELF by hand, or rebuild the entry image with the switch this arm really needs. Nothing is rebuilt by this refusal, and nothing should be: the frozen pair embeds this entry image"
      fi
      if (( _POU_N < 1 )); then
        fail "STAGE90_XNU_SEAM_MEASURE=1 in $ENTRY_CFG and $_SEAM_FN in $ENTRY_ELF does not call FlushPoU_Dcache at all (FlushPoU_Dcache=$_POU_N): the record names the arm whose seam is the interception with nothing of 535's behind it, and that arm is worth exactly one reading - the two slot reads bracket Apple's own L1 flush, so an unequal b/a pair is that flush writing the line back and an equal pair is the arm working as designed. A body that never calls the routine has nothing between the two reads, so the pair carries nothing at all, and the 'ok' line this clause replaced would have asserted in the same breath the call its own number refutes (591). What this clause can tell is that the record and the body disagree, not which is stale: disassemble $_SEAM_FN in $ENTRY_ELF by hand, or rebuild the entry image with the switch this arm really needs. Nothing is rebuilt by this refusal, and nothing should be: the frozen pair embeds this entry image"
      fi
      echo "  ok: the measurement arm's record and its body agree - the interception is in the link"
      echo "  (FLUSH_WRAP=$FLUSH_WRAP) and $_SEAM_FN calls FlushPoC_DcacheRegion $_POC_N times, so nothing of"
      echo "  535's operation is behind it. Its $_POU_N bl into FlushPoU_Dcache is the wrapper's own call"
      echo "  into the real routine - the L1 flush this arm passes the line to - and a call the seam does"
      echo "  NOT divert leaves by a tail branch, which is not a bl and is not counted here."
    else
      if (( _POC_N < 1 )); then
        fail "STAGE90_XNU_SEAM_POC=1 in $ENTRY_CFG and $_SEAM_FN in $ENTRY_ELF does not call FlushPoC_DcacheRegion at all: the record names 535's arm - Apple's own FlushPoC_DcacheRegion over the slot's eight bytes, bracketed by dsb - and the image carries a seam with no operation behind it, which is the other arm under this arm's name. The two are read in opposite directions: 535's run is the one that has not come back, so a boot of this image would spend the window on the arm that was already spent, and its log would be read against 535's expectations instead of the inverted rule the measurement arm is worth. What this clause can tell is that the record and the body disagree, not which is stale: disassemble $_SEAM_FN in $ENTRY_ELF by hand, or rebuild the entry image with the switch this arm really needs. Nothing is rebuilt by this refusal, and nothing should be: the frozen pair embeds this entry image"
      fi
      echo "  ok: 535's arm's record and its body agree - $_SEAM_FN calls FlushPoC_DcacheRegion $_POC_N"
      echo "  time(s) over the slot's eight bytes, and the arms it is told apart from are the ones where"
      echo "  that count is 0. Its $_POU_N bl into FlushPoU_Dcache is the wrapper's own call into the real"
      echo "  routine, as on the other arm; a call the seam does not divert is not counted here."
    fi
  fi
fi

echo
echo "  image: $IMAGE"
echo "  booted, never flashed, so no outcome of this run can write to storage."
