#!/bin/bash
# The entry link's object pool must follow the tree the build selected (experiment 926; 933 moved
# the derivation into one shared file and extended the guard to the build tools' roots).
#
# `src/entry/build_entry.sh` used to read one hard-pinned tree (`external/xnu-4570.1.46`) and one
# hard-pinned object pool (`$REPO_ROOT/out/xnu_{kernel,asm,platform}_obj`), 289 times. That is the
# recurring defect class: a path pinned to the 4570 line that has to follow the selected tree. 926
# derived `XNU`, the pool directories and the generated roots from `XNU_TREE` + `XNU_OBJ_SUFFIX`;
# **933 moved that derivation into `tools/xnu_tree_roots.sh`**, sourced by `build_entry.sh` and by the
# six builders, so "which tree" is one definition across the whole build - an entry link and a kernel
# build cannot disagree about which pool is which tree's.
#
# Source-half: no compiler, no device. It reads `build_entry.sh` and the rules file and refuses DRIFT:
#   (a) the rules file derives the `_d13` suffix from the D13 header, and `build_entry.sh` sources it;
#   (b) no LIVE out-path literal remains for a TREE-derived root (a re-pin reads 4570's on D13);
#   (c) `XNU` is `$XNU_TREE`, not a hard pin;
#   (d) the DEFAULT tree is 4570, matching `tools/build_xnu_arm_kernel.sh`'s default, so a plain
#       `./build_entry.sh` is unchanged.
# The `--selftest` feeds the pre-926 text (the literal pool), and a rule-less rules file, and asserts
# both are refused.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$HERE/.." && pwd)
BE=$REPO_ROOT/src/entry/build_entry.sh

note() { printf '  %s\n' "$*"; }

# The lines that are NOT comments: a `#` only counts at the start of a line or after whitespace.
live() { grep -vE '^[[:space:]]*#' "$1"; }

# The rule itself, in the one file that defines it (933 moved it here from `build_entry.sh`, so the
# six build tools and the entry link share it). This guard is the reason the file cannot quietly lose
# the derivation: a `build_entry.sh` that sources a rules file with no rule in it would link 4570.
ROOTS=$REPO_ROOT/tools/xnu_tree_roots.sh

check_roots() {
    local L; L=$(live "$ROOTS")
    # (a) the suffix is derived from the tree's own D13 discriminator.
    if ! grep -q 'XNU_OBJ_SUFFIX=_d13' <<<"$L"; then
        note "(a) the rules file does not select the _d13 pool"; return 1
    fi
    if ! grep -q 'osfmk/sys/types.h' <<<"$L"; then
        note "(a) the rules file does not key the pool on the D13 header osfmk/sys/types.h"; return 1
    fi
    # (d) the default tree is 4570 (matches build_xnu_arm_kernel.sh's default), so a plain run is
    # byte-identical on the base tree.
    if ! grep -q 'XNU_TREE=\${XNU_TREE:-\$REPO_ROOT/external/xnu-4570.1.46}' <<<"$L"; then
        note "(d) the rules file's default XNU_TREE is not the 4570 tree"; return 1
    fi
    return 0
}
# The selftest's entry to the same body; `check_roots` reads the real path.
check_roots_file() { ROOTS=$1 check_roots; }

check_one() {
    local f="$1"
    # Read the live lines once. (`live | grep -q` would be wrong under `set -o pipefail`: grep -q
    # exits at the first match, the producer takes SIGPIPE, and the pipeline's status becomes 141 -
    # a passing check reads as a failure. This is the defect class check_mem_size_max.py names.)
    local L; L=$(live "$f")
    # (a) the derivation is *sourced* from the shared rules file, not spelled here a second time.
    if ! grep -qE '^\.\s+"\$REPO_ROOT/tools/xnu_tree_roots\.sh"$' <<<"$L"; then
        note "(a) does not source tools/xnu_tree_roots.sh (the one definition of the tree->roots rule)"; return 1
    fi
    # (b) no live object-path literal (the pool refs must go through the derived variable).
    # **The pattern must tolerate the `"$REPO_ROOT"/out/…` form.** The 926 substitution re-rooted
    # `$REPO_ROOT/out/xnu_kernel_obj/…` but not the quoted-before-slash form `"$REPO_ROOT"/out/…`,
    # and 12 such literals survived — including the `436`/`POOL_OBJS` glob that adds the WHOLE pool to
    # the link. On D13 that glob would pull 4570's objects (a D13 link that silently links 4570 code).
    # The failure was the earlier regex requiring `$REPO_ROOT/out` with no quote between; it matched
    # the substituted form and not the surviving one, so the check passed vacuously — the defect class
    # "a claim in a comment is not a check", in the check itself.
    #
    # **933 widens it to every tree-derived root**, not just the three object pools: `xnu_assym` and
    # `xnu_generated` are read here too, and a re-pin of either is the same defect. The unsuffixed
    # project roots (`xnu_firehose_obj`, `stage90`) are deliberately NOT matched - they belong to no
    # tree, and their literal is correct on both.
    # **`$XNU_OBJ_SUFFIX` is the fix, not the defect.** A tree-derived root carries the suffix
    # (`out/xnu_kernel_obj$XNU_OBJ_SUFFIX`); a pinned one does not (`out/xnu_kernel_obj`, which on
    # D13 silently means 4570's pool). The regex matched both, so every corrected call site was
    # reported as still-broken and this check could never be green - the "a check that cannot
    # fail" family pointing the other way. The negative lookahead separates them, and it needs
    # PCRE (grep -P), which the check now requires and tests for.
    local POOL_RE='\$REPO_ROOT"?/out/(xnu_(kernel|asm|platform|arm|macho)_obj|xnu_assym|xnu_generated|mach_headers|device_table|xnu_arm_manifest)(?!\$XNU_OBJ_SUFFIX)'
    if grep -qP "$POOL_RE" <<<"$L"; then
        note "(b) a live out-path is still pinned to a literal directory that belongs to one tree"
        grep -nE "$POOL_RE" <<<"$L" | head -3
        return 1
    fi
    # (c) `XNU` is the selected tree.
    if ! grep -q '^XNU=\$XNU_TREE$' <<<"$L"; then
        note "(c) XNU is not \$XNU_TREE"; return 1
    fi
    echo "check_entry_tree_pools: ok - the entry link's pool follows the selected tree"
    return 0
}

# **And the six builders must source the same rule (933).** They wrote - and, worse, *read* - 4570's
# roots on a D13 run before this; the measured cost was a D13 kernel build driven by a hand-typed
# twelve-variable environment, and a platform block that silently compiled against 4570's MIG headers.
# Each must (a) source the rules file and (b) carry no live literal for a tree-derived root. The two
# unsuffixed project roots (`xnu_firehose_obj`, `xnu_rt_obj`) are NOT tree-derived and are exempt.
BUILDERS=("$REPO_ROOT/tools/build_xnu_arm_kernel.sh"
          "$REPO_ROOT/tools/gen_mach_headers.sh"
          "$REPO_ROOT/tools/gen_assym.sh"
          "$REPO_ROOT/tools/build_xnu_arm_layer.sh"
          "$REPO_ROOT/tools/build_xnu_arm_macho.sh"
          "$REPO_ROOT/tools/assemble_arm_layer.sh")

check_builder() {
    local f="$1" L; L=$(live "$f")
    if ! grep -qE '^\.\s+"\$TOOLS_DIR/xnu_tree_roots\.sh"$' <<<"$L"; then
        note "$(basename "$f"): does not source tools/xnu_tree_roots.sh"; return 1
    fi
    # The same widened pattern as check_one (b): any tree-derived root spelled as a literal.
    local POOL_RE='\$REPO_ROOT"?/out/(xnu_(kernel|asm|platform|arm|macho)_obj|xnu_assym|xnu_generated|mach_headers|device_table|xnu_arm_manifest)'
    if grep -qE "$POOL_RE" <<<"$L"; then
        note "$(basename "$f"): a live out-path is still pinned to a literal that belongs to one tree"
        grep -nE "$POOL_RE" <<<"$L" | head -3
        return 1
    fi
    return 0
}

if [[ ${1:-} == --selftest ]]; then
    # The pre-926 text: a live `XNU=$REPO_ROOT/external/xnu-4570.1.46` and a literal pool path. It must
    # be refused, or the check proves nothing.
    tmp=$(mktemp)
    cat >"$tmp" <<'EOF'
XNU_TREE=${XNU_TREE:-$REPO_ROOT/external/xnu-4570.1.46}
XNU=$REPO_ROOT/external/xnu-4570.1.46
ARM_INIT_OBJ=${STAGE90_ENTRY_ARM_INIT_OBJ:-$REPO_ROOT/out/xnu_kernel_obj/osfmk_arm_arm_init.o}
for _o in "$REPO_ROOT"/out/xnu_kernel_obj/*.o; do :; done
EOF
    if check_one "$tmp" >/dev/null 2>&1; then
        echo "check_entry_tree_pools: SELFTEST FAIL - the pre-926 text was accepted" >&2
        rm -f "$tmp"; exit 1
    fi
    # And a rules file with the derivation deleted must be refused, even if `build_entry.sh` sources it.
    tmp2=$(mktemp)
    printf 'XNU_TREE=${XNU_TREE:-$REPO_ROOT/external/xnu-4570.1.46}\n' >"$tmp2"
    if check_roots_file "$tmp2" >/dev/null 2>&1; then
        echo "check_entry_tree_pools: SELFTEST FAIL - a rule-less roots file was accepted" >&2
        rm -f "$tmp" "$tmp2"; exit 1
    fi
    rm -f "$tmp" "$tmp2"
    echo "check_entry_tree_pools: selftest ok (the pre-926 pinned pool is refused)"
    exit 0
fi

# `check_roots_file` is the selftest's entry to the same body; `check_roots` reads the real path.
check_roots || exit 1
check_one "$BE" || exit 1
for _b in "${BUILDERS[@]}"; do check_builder "$_b" || exit 1; done
echo "check_entry_tree_pools: ok - the six builders source the same rule"