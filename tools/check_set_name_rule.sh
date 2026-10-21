#!/usr/bin/env bash
#
# Does each recorded set's NAME come from its own bytes, and does the storage family's come from the
# entry image?
#
# WHY THIS EXISTS. A set name in `records/revert-set.txt` is `<something>-<8 hex>`, and those eight hex
# characters are not an abbreviation: they are the sha256 prefix of **one of that set's own members**.
# The rule is load-bearing because the name is the only thing the press path has after a compaction - a
# reader who wants to know "is `out/` the parked arm?" compares a directory name against a directory
# hash, and if the suffix came from anywhere else the comparison resolves nothing. It was written down,
# in the record, as prose inside a `role=` string that no tool parses:
#
#     ... this-is-the-STORAGE_PROBE-15-entry-the-8-hex-of-this-hash-is-the-sets-name ...
#
# and the very next arm's first draft broke it - 732 named its arm `armed-storage-enable-73d4a8f3`,
# taking the suffix from `stage90-qcdt.img` (the file `fastboot boot` sends) instead of the entry image.
# Nothing refused; the mistake was found only by measuring the other sixteen storage sets by hand. That
# is `mi4-a-claim-in-a-comment-is-not-a-check` in its most expensive form: the claim and its
# counter-example one line apart in the same block, with no check between them.
#
# WHAT THE RECORD ACTUALLY SHOWS, measured over all 25 sets when this file was written:
#
#   | suffix's source        | sets | which                                                     |
#   | ---------------------- | ---- | --------------------------------------------------------- |
#   | `xnu_arm_entry.bin`    |  23  | every `armed-storage-*` (17) and six earlier entry arms    |
#   | `stage90-qcdt.img`     |   1  | `armed-selftest-wdog-ef0361a2`, the one PRE-LADDER arm     |
#   | not a hash at all      |   1  | `frozen-574`, a human label for the 574 park               |
#
# So the rule has two halves and they are not the same half:
#
#   * **universal** - an 8-hex suffix must be the sha256 prefix of exactly one of the set's own members.
#     This is what makes the name evidence about the bytes rather than about the author.
#   * **the storage family** - for a set named `armed-storage-*`, that member must be
#     `xnu_arm_entry.bin`. The storage ladder is a change to the *entry image*; the payload is rebuilt
#     around it, so the qcdt and the payload's `.bin` both move for reasons that are not the arm. A name
#     taken from one of those would name the wrapper.
#
# **THE OTHER FAMILIES ARE MEASURED AND NOT CONSTRAINED, AND THAT IS DELIBERATE.** The pre-ladder arm's
# qcdt-derived name is kept: this project supersedes a record rather than editing it, and a check that
# refused the historical arm would be a check that is red on `master` - which is a check nobody reads.
# What it does instead is PRINT the census of which member each family's names came from, so a new
# convention is a line in that table on the day it appears rather than a discovery made later by hand.
#
# WHAT IT CANNOT SEE: whether the *chosen* member is the interesting one, outside the storage family. A
# set named after its own `SHA256SUMS.txt` would pass the universal half; only the storage half names a
# file. And it reads the RECORD, not the parks - it says each name was derived from a hash the record
# carries, not that the park on disk is that set (that is `tools/verify_revert_set.sh`).
#
# Usage:
#   tools/check_set_name_rule.sh                     # the record in this repository
#   tools/check_set_name_rule.sh --record PATH       # a different record, for falsification
#   tools/check_set_name_rule.sh --verbose           # print every set, not only the refusals
#   tools/check_set_name_rule.sh --help
#
# Exit: 0 = every set's suffix names exactly one of its own members and the storage family's is the entry
#       image. 1 = refused, with the set named and the reason. 2 = usage, from the argument loop only.

set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
RECORD=$ROOT/records/revert-set.txt
VERBOSE=0
FAMILY_PREFIX='armed-storage-'
FAMILY_MEMBER='xnu_arm_entry.bin'

usage() {
  sed -n '2,/^set -uo pipefail$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//; $d'
  exit "${1:-2}"
}

while (( $# )); do
  case $1 in
    --record)  [[ -n ${2:-} ]] || { printf 'check_set_name_rule: --record needs a path\n' >&2; exit 2; }
               RECORD=$2; shift 2 ;;
    --record=*) RECORD=${1#--record=}; shift ;;
    --verbose) VERBOSE=1; shift ;;
    --help|-h) usage 0 ;;
    *) usage 2 ;;
  esac
done

[[ -r $RECORD ]] || { printf 'check_set_name_rule: REFUSING: %s is not readable, and a record that cannot be read is not a record whose names obey anything\n' "$RECORD" >&2; exit 1; }

# --- parse the record, in awk, into `set<TAB>file<TAB>sha` --------------------------------------
# One process, and every malformed line is NAMED rather than skipped: a `set=` line this cannot read is
# a set this check would silently not examine, which is the class this whole file is about.
mapfile -t MEMBERS < <(awk '
  /^[[:space:]]*#/ { next }
  /^[[:space:]]*$/ { next }
  {
    if ($0 !~ /^set=[^ ]+ sha256=[0-9a-f]{64} bytes=[0-9]+ file=[^ ]+/) { bad++; printf("BAD\t%s\n", $0); next }
    s = substr($1, 5)
    h = ""
    f = ""
    for (i = 2; i <= NF; i++) {
      if (substr($i, 1, 7) == "sha256=") h = substr($i, 8)
      if (substr($i, 1, 5) == "file=")   f = substr($i, 6)
    }
    printf("%s\t%s\t%s\n", s, f, h)
  }
  END { if (bad) printf("BADCOUNT\t%d\n", bad) }
' "$RECORD")
[[ ${#MEMBERS[@]} -gt 0 ]] || { printf 'check_set_name_rule: REFUSING: %s yielded no member lines at all - an empty parse is the extractor failing, not a record with nothing to say\n' "$RECORD" >&2; exit 1; }

BADLINES=$(printf '%s\n' "${MEMBERS[@]}" | awk -F'\t' '$1 == "BAD" { n++ } END { print n + 0 }')
BADCOUNT=$(printf '%s\n' "${MEMBERS[@]}" | awk -F'\t' '$1 == "BADCOUNT" { print $2 }')
[[ $BADLINES -eq 0 ]] || { printf 'check_set_name_rule: REFUSING: %s carries %s line(s) that are not a well-formed set member line, and a set this cannot parse is a set this cannot examine. First: %s\n' \
    "$RECORD" "${BADCOUNT:-$BADLINES}" "$(printf '%s\n' "${MEMBERS[@]}" | awk -F'\t' '$1 == "BAD" { print substr($2,1,160); exit }')" >&2; exit 1; }

# --- the sets, in first-appearance order ---------------------------------------------------------
mapfile -t SETS < <(printf '%s\n' "${MEMBERS[@]}" | awk -F'\t' '$1 != "BAD" && $1 != "BADCOUNT" { if (!seen[$1]++) print $1 }')
NSETS=${#SETS[@]}

# --- one pass per set ----------------------------------------------------------------------------
REFUSE=()
CENSUS=()      # "<member-file> <count>"
NONHASH=()
N_MATCHED=0
for s in "${SETS[@]}"; do
  suffix=${s##*-}
  members=$(printf '%s\n' "${MEMBERS[@]}" | awk -F'\t' -v s="$s" '$1 == s { print $2 "\t" $3 }')
  nmem=$(printf '%s\n' "$members" | grep -c .)

  # a suffix that is not 8+ hex is a LABEL (frozen-574) - reported, never refused: the rule is about
  # names that claim to be a hash, and a name that claims to be a word is a different kind of record.
  if [[ ! $suffix =~ ^[0-9a-f]{8,}$ ]]; then
    NONHASH+=("$s")
    [[ $VERBOSE -eq 0 ]] || printf '  note   %-42s suffix `%s` is not a hash - a labelled set, measured and not constrained\n' "$s" "$suffix"
    continue
  fi

  # **The members are FILES, and a file can appear on more than one line.** A set that was
  # re-recorded under a second `role=` (1031 and 1032 both measured the same entry image) carries the
  # same path twice, with the same sha256 and the same byte count - one member, two lines. Counting
  # lines said "two members could claim it" and refused a name that is in fact uniquely resolved.
  # The count is over distinct file names, which is what the rule is about.
  hits=$(printf '%s\n' "$members" | awk -F'\t' -v p="$suffix" 'index($2, p) == 1 { print $1 }' \
         | LC_ALL=C sort -u)
  nhits=$(printf '%s\n' "$hits" | grep -c .)

  if (( nhits == 0 )); then
    # **A third source, measured and now named: the PACK's aggregate.** 4(a) of records/1037-press.txt
    # records why the d13 sets stopped being named by the entry bin's sha8 - two parks of the same bin
    # wrote the same name and produced a MIXED set - so a set is named by the sha of every member,
    # which is `_arm_files_sha` in scripts/park_*.sh: the members' `sha256sum` lines, sorted, hashed.
    # That value is a hash of the set's own bytes, but not of any ONE member, so the universal half
    # could not see it. It is recomputed here from the record; a suffix that matches neither a member
    # nor the aggregate is still a refusal.
    # The aggregate covers the PACK, and the pack is defined by `MEMBERS=( ... )` in the park script -
    # not by every path the record happens to mention (a park also records the tools it ran, and those
    # are not packed). The list is read from the script rather than assumed, so a park that changes its
    # manifest keeps this check honest.
    # `MEMBERS=( ... )` is written across several lines with trailing backslashes. Rather than parse
    # bash, take the record's own paths and drop the ones the pack does not hold: a park records the
    # tools it RAN beside the files it packed, and only the latter are in the aggregate
    # (`_arm_files_sha` in scripts/park_*.sh hashes "${MEMBERS[@]}" alone).
    # **The aggregate is over `sha256sum` LINES, not over the record's tab-separated pairs.**
    # `_arm_files_sha` runs `sha256sum "$_m"` for each packed member and hashes the sorted output, so
    # each line is `<sha>  <path>` - two spaces, hash first. `$members` is `<path><TAB><sha>`, the
    # record's order; hashing that directly gives a value no park ever wrote. The two tool scripts a
    # park also records are not in `MEMBERS`, so they are not in the aggregate either.
    pack=$(printf '%s\n' "$members" | LC_ALL=C sort -u \
           | awk -F'\t' '$1 !~ /\.(py|sh)$/ { printf "%s  %s\n", $2, $1 }' \
           | LC_ALL=C sort | sha256sum | cut -c1-8)
    if [[ $suffix == "$pack" ]]; then
      matched="PACK($pack)"
      N_MATCHED=$(( N_MATCHED + 1 ))
      CENSUS+=("$matched")
      [[ $VERBOSE -eq 0 ]] || printf '  ok     %-42s suffix %s <- %s\n' "$s" "$suffix" "$matched"
      continue
    fi
    REFUSE+=("$s: its suffix $suffix is the sha256 prefix of NONE of its own $(printf '%s\n' "$members" | awk -F'\t' '{ print $1 }' | LC_ALL=C sort -u | grep -c .) distinct member(s) ($(printf '%s\n' "$members" | awk -F'\t' '{ print $1 }' | LC_ALL=C sort -u | tr '\n' ' ')), nor of the pack's own aggregate ($pack) - so the name is evidence about something that is not in this set")
    continue
  fi
  if (( nhits > 1 )); then
    REFUSE+=("$s: its suffix $suffix is the sha256 prefix of $nhits of its own members ($(printf '%s' "$hits" | tr '\n' ' '))- a name that two members could claim resolves nothing")
    continue
  fi

  matched=$hits
  N_MATCHED=$(( N_MATCHED + 1 ))
  CENSUS+=("$matched")

  if [[ $s == ${FAMILY_PREFIX}* ]]; then
    if ! printf '%s\n' "$members" | awk -F'\t' -v m="$FAMILY_MEMBER" '$1 == m { found = 1 } END { exit !found }'; then
      REFUSE+=("$s: its name begins ${FAMILY_PREFIX} and it carries no $FAMILY_MEMBER member at all, so the rule that a storage arm is named by its ENTRY IMAGE cannot be applied to it - and a rule that cannot be applied is a refusal and not a pass")
      continue
    fi
    if [[ $matched != "$FAMILY_MEMBER" ]]; then
      REFUSE+=("$s: its name begins ${FAMILY_PREFIX}, its suffix $suffix comes from $matched, while a storage arm is a change to the ENTRY IMAGE - the name must come from $FAMILY_MEMBER, and ${FAMILY_PREFIX}*+$matched is the shape 732's first draft shipped")
      continue
    fi
  fi

  [[ $VERBOSE -eq 0 ]] || printf '  ok     %-42s suffix %s <- %s\n' "$s" "$suffix" "$matched"
done

printf 'check_set_name_rule: %s\n' "$RECORD"
printf '  %d set(s): %d named by a hash of one of their own members, %d a label rather than a hash, %d without a hash suffix that resolves\n' \
  "$NSETS" "$N_MATCHED" "${#NONHASH[@]}" "$(( NSETS - N_MATCHED - ${#NONHASH[@]} ))"

# --- the census is a reading, not decoration ------------------------------------------------------
# Which member each family derives its names from, COUNTED. A new convention shows up here as a new
# line, on the day it appears, instead of being discovered by hand the way 732's mis-name was.
if (( ${#CENSUS[@]} )); then
  printf '  the suffix source, counted:\n'
  printf '%s\n' "${CENSUS[@]}" | LC_ALL=C sort | uniq -c | LC_ALL=C sort -rn | awk '{ printf "    %4d  %s\n", $1, $2 }'
  printf '    the rule this file enforces: every %s* set must be in the %s row\n' "$FAMILY_PREFIX" "$FAMILY_MEMBER"
fi
if (( ${#NONHASH[@]} )); then
  # `printf '    %s\n' "${NONHASH[@]}"` when the array has ONE element prints a leading blank line only
  # if the caller asked for one; it does not. Kept as a statement of what a label is worth.
  printf '    (a LABEL and not a hash - measured, not constrained: %s)\n' "$(printf '%s ' "${NONHASH[@]}")"
fi

if (( ${#REFUSE[@]} )); then
  printf '\nREFUSING: %d set name(s) do not obey the rule.\n' "${#REFUSE[@]}" >&2
  for r in "${REFUSE[@]}"; do printf '  %s\n' "$r" >&2; done
  exit 1
fi

printf '\nEvery set name is a hash of one of its own members, and every %s* name is the entry image.\n' "$FAMILY_PREFIX"
exit 0
