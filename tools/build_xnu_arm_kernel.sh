#!/usr/bin/env bash
#
# Compile the kernel Apple's own manifest says an ARM RELEASE build is made of.
#
#   ./tools/build_xnu_arm_kernel.sh                 # compile everything in the manifest
#   ./tools/build_xnu_arm_kernel.sh --limit 50      # the first 50, for a quick look
#   ./tools/build_xnu_arm_kernel.sh --dir osfmk     # one component
#   ./tools/build_xnu_arm_kernel.sh --blockers 25   # the distinct things blocking the rest
#   ./tools/build_xnu_arm_kernel.sh --platform-only # only the three out-of-manifest blocks, whose
#                                                   # objects the pool's own `rm -f *.o` would eat
#
# The manifest is both halves of the kernel: `.c` compiled with `clang` and `.cpp` with `clang++`,
# through one pipeline and one per-component define table, reported separately. `.s` is still
# skipped — that is `xnu_arm_assemble.sh`'s job.
#
# Two environment variables that exist for controlled comparisons rather than for building:
#
#   XNU_KERNEL_EXTRA_DEFINES='-DFOO=1'   appended after this configuration's own defines, so a
#                                        "what if this flag were global" question is one command
#                                        against the real build instead of a hand-copied flag list.
#                                        That difference is not cosmetic: the hand-copied list is
#                                        how the C++ block was measured wrong — see experiment-154.
#   XNU_KERNEL_OBJ_OUT=/absolute/path    where the objects go. Must be absolute: this script `cd`s.
#
# This is the honest measurement. `build_xnu_arm_layer.sh` answers "does osfmk/arm compile" — all
# 32 files in the directory — and it does. But a kernel is not a directory: it is the files
# `list_sources.py RELEASE` selects from Apple's `*/conf/files` lists under Apple's own
# configuration. This compiles that set.
#
#   XNU_TREE=/absolute/path/to/xnu          which tree to compile.  It selects the output suffix as
#                                        well (`tools/xnu_tree_roots.sh`: a tree with `osfmk/sys/types.h`
#                                        -> `_d13`, else none), so a D13 build MUST be pointed at the D13
#                                        tree: **the default is the 4570 tree**, and a run without
#                                        XNU_TREE compiles 4570's sources into `out/xnu_kernel_obj`
#                                        (MEASURED 2026-10-18: a debug run done exactly that way began
#                                        `rm -f out/xnu_kernel_obj/*.o` and left it a partial 483-object
#                                        census; that directory is NOT the D13 pool).
#
# Prerequisites, both reproducible:
#   ./tools/build_mig.sh                        -> out/mig/build/migcom
#   ./tools/gen_mach_headers.sh                 -> out/mach_headers/ (the MIG output)
#   ./tools/gen_option_headers.py               -> out/xnu_options/ (the OPTIONS/ macros)
#   ./tools/gen_libkern_version.sh              -> out/xnu_generated/libkern/version.h
#   ./tools/gen_confdep.py                      -> out/xnu_generated/confdep.h (Darwin-13 only; no-op on 4570)
#   ./tools/gen_bsd_headers.sh                  -> out/xnu_generated/bsd/sys/sysproto.h
#   ./tools/xnu_config/list_sources.py RELEASE --write out/xnu_arm_manifest.txt
#
# The generated roots come BEFORE every source tree, which is Apple's own order:
# `INCFLAGS = $(INCFLAGS_LOCAL) $(INCFLAGS_GEN) ...` with `INCFLAGS_LOCAL = -I.` (MakeInc.def:466-469)
# - the build directory, which is where MIG and makesyscalls put their output, ahead of the
# component's source tree. experiment-119 measured the opposite and concluded the generated root
# must go last; that was right for what it was testing and wrong as a general rule, because the
# generated root at the time held MIG output for *every* `.defs`, including `mach/notify.h`, which
# Apple never generates and which shadows the hand-written one. With the output set taken from
# Apple's Makefiles (xnu_config/mig_outputs.py), the order flips: 395 vs 384 in the minimal
# configuration. See experiment-124.
#
# What to expect: the ARM layer compiles and most of the kernel does not. The output that matters is
# `--blockers`: a per-file error count is not actionable, but the list of distinct missing names is,
# because each is either a header to supply, a value to choose, or a file to compile.

set -uo pipefail

cd "$(dirname "$0")"
TOOLS_DIR=$PWD
REPO_ROOT=$(cd "$TOOLS_DIR/.." && pwd)

# **Every out-root this build reads or writes follows the selected tree (experiment 933).** The rule
# (`XNU_TREE` -> `XNU_OBJ_SUFFIX` -> the roots) is defined once in `tools/xnu_tree_roots.sh` and
# shared with the other five builders, so `XNU_TREE=<d13>` alone selects the `_d13` outputs and a
# plain run on 4570 is byte-identical. See that file for why a hand-typed multi-variable D13
# environment was a defect rather than a convenience.
. "$TOOLS_DIR/xnu_tree_roots.sh"

XNU=$XNU_TREE
# The non-MIG generated headers (`bsd/sys/sysproto.h` from makesyscalls.sh, `libkern/version.h`).
# Defined here rather than beside its use below because the **manifest** needs it too: `list_sources.py
# --generated-dir` resolves the generated `_server.c`/`init_sysent.c` sources against it, and a
# manifest that names another tree's generated sources is the same one-value-two-definitions shape as
# the MIG root.
GENERATED=$XNU_GENERATED
SHIMS=$REPO_ROOT/src/shims
SHIMS_ARM=$REPO_ROOT/src/shims_arm
# The kserver variant goes BESIDE `$MIG_HEADERS`, not at a fixed root: the two are different outputs
# of the SAME `.defs` set (the `-DKERNEL_SERVER` half), so pairing one tree's headers with another
# tree's kserver is `one value, two definitions`. `xnu_tree_roots.sh` derives it from `$MIG_HEADERS`,
# so a per-tree `MIG_HEADERS` carries its own kserver automatically.
MIG_KSERVER=$MIG_KSERVER_OUT
OUT=$XNU_KERNEL_OBJ_OUT

# **The HFS+ port's sources, which are not in any `conf/files`** (experiments 875/877).  2050's HFS
# is staged into this tree by `tools/stage_hfs.sh`, but its rows are deliberately NOT added to the
# untracked `bsd/conf/files`: the port's additions live in TRACKED files, so the build names them from
# a tracked list instead.  Two halves, and both are needed or neither works:
#
#   HFS_FILES   37 paths (36 `.c` under `bsd/hfs/` plus `bsd/vfs/vfs_journal.c`), handed to
#               `list_sources.py --extra` so the manifest contains them.  `--extra` REFUSES a
#               named-but-absent path, so an unstaged tree stops the build instead of producing a
#               kernel that quietly has no HFS in it.
#   HFS_FORCE   the ONE header that IS the port's additions (the five malloc types, the journal's two,
#               the obsolete namei flags, the `kmem_alloc` arity macros, and the port's own options
#               `HFS`/`HFS_COMPRESSION`/`CONFIG_HFS_STD`/`JOURNALING`).  It is force-included for the
#               HFS files ONLY - it is the port's definition and no other file should see it - for the
#               same reason `-include sys/types.h` is per-BSD-file: a global `-include` would put these
#               macros in front of 730 files that were never measured with them.
#
# `hfs_files.txt` is the same 37 the in-place measurement in experiment 876 compiled, so the list and
# the measurement cannot disagree; `tools/check_hfs_staged.sh` (in `make check`) guards that.
HFS_FILES=$REPO_ROOT/src/supply/hfs_files.txt
HFS_FORCE=$REPO_ROOT/src/shims/hfs/hfs_port_force.h
# The second force header: 2050's HFS-facing cprotect layer (the constants and structures 4570
# replaced with an opaque kext API), restored for the HFS files only.  Included AFTER hfs_port_force.h
# because it uses the macro-definition style of the first and reads nothing from it.  See the file.
HFS_FORCE_CP=$REPO_ROOT/src/shims/hfs/hfs_cprotect_port.h

# **And it is OFF by default, because the wiring is correct and the port is not yet complete** (877).
# Measured through this very pipeline in that step: 32 of the port's 36 `.c` files compile, and the
# four that do not - `hfs_cprotect.c`, `hfs_readwrite.c`, `hfs_vfsops.c`, `hfs_vnops.c` - fail in the
# cprotect API family (`CP_WRITE_ACCESS`, `CP_PREFETCH`, `struct cprotect`, `struct cp_root_xattr`,
# `CP_PREV_MAJOR_VERS`, ...).  That is exactly the gap 865 named when it measured the port at 34/38
# under `CONFIG_PROTECT=1`, and **it cannot be closed by a per-file switch**: `bsd/sys/buf_internal.h`
# gates two fields *inside `struct bufattr`* (`:82-92`) on `CONFIG_PROTECT`, so the option is a
# struct-LAYOUT axis, not a filesystem one.  Compiling these four with `-DCONFIG_PROTECT=0` while the
# other 704 files are built with the configuration's `CONFIG_PROTECT=1` would be a second definition of
# `struct bufattr` - silent, and wrong at the wrong offset ([[mi4-one-value-two-definitions]]).  So the
# switch stays 0 and the port does not reach a kernel until its cprotect work lands; the build is
# correct in both positions and this is the one that cannot lie about what the tree can do.
HFS_PORT=${STAGE90_XNU_HFS:-0}

# Apple's COMPONENT_LIST, `makedefs/MakeInc.def:46`. It is named once here because it is read in
# two places - the per-file import roots below, and the runtime block after the loop - and a second
# copy of it is how `-I$XNU/bsd` went missing for 68 libkern files once already. The error that
# produced was `sys/_types/_u_int.h not found`, from a force-include, naming neither the component
# nor the missing root.
COMPONENT_LIST=(osfmk bsd libkern iokit pexpert security san)

# **The import order** - which is a property of the TREE, and derived from the one list above so it
# cannot drift from it.  A file sees its own component's headers first (the `COMP_ROOTS` head below)
# and the other components after, and the order of "the others" decides which header wins when two
# components ship the same path.
#
# Apple's own order is by **curation**, not by component: `INCFLAGS_IMPORT = -I$(OBJROOT)/EXPORT_HDRS/%`
# (`makedefs/MakeInc.def:463`), where `EXPORT_HDRS/<component>/` holds only the headers that component
# *exports* (`EXPORT_MI_LIST`/`EXPORT_MD_LIST`; see tools/gen_export_headers.sh).  BSD's exported
# POSIX headers all land under `EXPORT_HDRS/bsd/`, so in Apple's build they beat any component's
# private copy of the same path.  This build imports the **raw source trees** instead - the curated
# roots are incomplete and were measured worse (2026-09-17, in gen_export_headers.sh) - so the same
# resolution has to be reproduced by putting `bsd` ahead of the others in the import chain.
#
# The shape this fixes (913/916, Darwin-13): the 2013 tree ships a **legacy private
# `osfmk/sys/types.h`** whose guard is `_SYS_TYPES_H_` - the SAME guard the modern
# `bsd/sys/types.h` uses.  With osfmk ahead, a libkern/libsa file's `#include <sys/types.h>` resolves
# to the legacy header, which defines the guard and the old `time_t`/`dev_t`/`daddr_t`, so
# `bsd/sys/types.h`'s entire modern body (gid_t, uid_t, off_t, mode_t, …) is skipped - the ~1800
# `unknown type name` sites.  Apple never sees it: its osfmk import is the curated export, where that
# private header is not exported.  **4570 ships no `osfmk/sys/types.h`**, so the condition below is
# false on the base tree and the order is exactly Apple's COMPONENT_LIST - every 4570 object stays as
# it was (the one place this can move a 4570 file is the five paths bsd and osfmk share there, and
# the build re-measures those rather than assuming).
if [[ -f $XNU/osfmk/sys/types.h ]]; then
    COMPONENT_IMPORT_ORDER=(bsd)
    for _c in "${COMPONENT_LIST[@]}"; do
        [[ $_c == bsd ]] || COMPONENT_IMPORT_ORDER+=("$_c")
    done
    unset _c
else
    COMPONENT_IMPORT_ORDER=("${COMPONENT_LIST[@]}")
fi

# **The C++ dialect is the tree's too (922).** `CXX_ARGS` below pins no `-std`, so `clang++` picks
# its own default - gnu++14 today - and the 2013-era Darwin-13 C++ was never written for it. Eight of
# D13's C++ files begin with a brace-initializer whose value does not fit the declared type
# (`int foo = {self->reserved | 0xC0000000};` - `[-Wc++11-narrowing]`, an *error* since clang 16 and
# a warning/*pass* in the Xcode-5 clang that built D13), and two (`S5L8930XIO`, `AppleARMNMI`) reach
# IOKit headers whose `UINT32_MAX` is defined only under the legacy `stdint.h` the dialect selects.
# Measured: D13 C++ is **82/96 with the default, 93/96 under `gnu++98`** - the dialect D13's era
# actually used (Xcode 5's default).
#
# It is gated on the SAME filesystem test that discriminates the two trees above (D13 ships the
# legacy `osfmk/sys/types.h`, 4570 does not), so the flag is **absent on 4570 and every 4570 object is
# unchanged** - which it must be, because gnu++98 *regresses* 4570: one file (`IOPMrootDomain.cpp`)
# uses a genuine C++11 construct and fails only under the old dialect. So the fix is to give each tree
# the dialect it was written for, not to impose one on both.
CXX_STD_FLAGS=()
if [[ -f $XNU/osfmk/sys/types.h ]]; then
    CXX_STD_FLAGS=(-std=gnu++98)
fi

# **The board macro and one dialect macro, both the tree's (923).** The fork is an HD2 board port and
# gates the kernel on its own board target: four C++ translation units (`IOService.cpp`,
# `IOUserClient.cpp`, `IOStartIOKit.cpp`, `OSKext.cpp`) and `libsa/bootstrap.cpp` `#include` the
# fork's `nokextd/IOS7NoKextd035.h`, whose line 7 is an `#error` unless a board is named.
# `IOService.cpp` is a **base class the whole IOKit object graph derives from**, so without a board
# the link has no `IOService` - the gate is not optional. The board is `BOARD_CONFIG_MSM8974_CANCRO`,
# a *new* board (the fork's own name was `QSD8250_LEO`): reusing LEO compiles the gate but pulls the
# fork's HD2 lab instrumentation into core files - `osfmk/arm/trap.c:56`, `osfmk/kern/thread_act.c:82`
# and the `pexpert/arm/pe_qsd8250_leo.c` board PE all `#include "ios7..."` headers under LEO, and
# `trap.c` is load-bearing, so the machine would carry the wrong board's tracing. The new name
# satisfies the nokextd gate (its guard was widened to a board test, a one-line tree edit staged by
# `tools/stage_d13_board.sh`) and `osfmk/arm/PlatformConfigs.h` maps it to the Qualcomm-Krait class
# the MSM8960_TOUCHPAD precedent uses. That class is consumed at exactly one site
# (`osfmk/arm/locore.s:229`, "Enable automatic-clock gating" - a Cortex-A9 CP15 `c15` write, the
# right path for MSM8974's Krait).
#
# `__STDC_LIMIT_MACROS` is the companion: `EXTERNAL_HEADERS/stdint.h:77` gates every `*_MAX`/`*_MIN`
# on `(! defined(__cplusplus)) || defined(__STDC_LIMIT_MACROS)`, the pre-C++11 rule. `IOMedia.cpp`,
# `IODeviceTreeSupport.cpp` and `IOS7LeoSDCC2.cpp` use `UINT32_MAX`, which the C path gets for free
# and the C++ path needs the macro for. Both are gated on the SAME `osfmk/sys/types.h` filesystem test
# 922 used, so **4570 is untouched** (its stdint idiom is C++11-native and it has no `nokextd` gate).
if [[ -f $XNU/osfmk/sys/types.h ]]; then
    COMP_DEFINES_EXTRA=(-DBOARD_CONFIG_MSM8974_CANCRO=1)
    CXX_STD_FLAGS+=(-D__STDC_LIMIT_MACROS=1)
fi

# **958: recognise the device's full RAM.** `tools/patch_d13_memory_total.py` guards a read of
# `/defaults hw.memsize` in `arm_vm_init.c` on `STAGE90_XNU_MEM_TOTAL`, and this switch defines it for
# every D13 compilation. It is a SWITCH, not always-on: with it off the guard's `#else` arm is Apple's
# line exactly, so a D13 object built without the switch is byte-for-byte the tree's - the arms the
# ladder has already run do not move. It is D13-only: 4570 has no `MANAGED_BASE` (956), so it would
# recognise a total its linear map cannot bound - and 4570 does not need it (its `arm_init` already
# reads `hw.memsize` into `xmaxmem`). The refusal below is the 4570 half of build_entry.sh's D13-only
# arm gate, so a 4570 build cannot silently carry a D13 switch.
if [[ ${STAGE90_XNU_MEM_TOTAL:-0} -eq 1 ]]; then
    if [[ -f $XNU/osfmk/sys/types.h ]]; then
        COMP_DEFINES_EXTRA+=(-DSTAGE90_XNU_MEM_TOTAL=1)
    else
        echo "REFUSING: STAGE90_XNU_MEM_TOTAL=1 is a Darwin-13 switch; this tree is 4570 (no" >&2
        echo "          osfmk/sys/types.h). 4570 reads hw.memsize in arm_init already, and its linear" >&2
        echo "          map is bounded by MEM_SIZE_MAX, not the D13 fixed MANAGED_BASE (956)." >&2
        exit 2
    fi
fi

# **915-B rungs 3a-5: the region-list switch must reach the KERNEL corpus, not just the payload.**
# `scripts/build.sh:182-187` defines `STAGE90_XNU_REGIONS` for the PAYLOAD and records it, but every
# reader of the switch is in the KERNEL corpus - `osfmk/arm/pmap.c` and `osfmk/arm/arm_vm_init.c` -
# which this script compiles. Until this line those files' `#if STAGE90_XNU_REGIONS` were fed an
# UNDEFINED name, i.e. evaluated as 0: the whole port was dead on arrival no matter what the payload
# emitted. This is the kernel half of that single value; the payload half is `build.sh`.
#
# It is threaded UNCONDITIONALLY with a `:-0` default, and always passes the macro (never leaves it
# undefined), so `#if STAGE90_XNU_REGIONS` reads a defined `0` when the arm is off - not the
# undefined-name spelling of off ([[mi4-off-option-two-spellings]]). At 0 every reader's `#if` is
# false, so the D13 object is byte-for-byte the tree's and the arms the ladder has already run do not
# move. Unlike MEM_TOTAL there is no 4570 refusal: the switch is symmetric - build_entry.sh refuses
# 4570 only for the D13-only switches, and `src/regions/` (915-B rung 0) is host-side.
#
# The value is checked BEFORE it is used: `[[ x -eq 1 ]]` on a non-numeric value is a false, so
# `STAGE90_XNU_REGIONS=2` would otherwise silently become `=0` - the placement is the check
# ([[mi4-a-claim-in-a-comment-is-not-a-check]]). The accepted set matches `scripts/build.sh:183-186`
# so the payload and the kernel cannot disagree on the spelling of the switch.
case "${STAGE90_XNU_REGIONS:-0}" in
    0|1) ;;
    *) echo "REFUSING: STAGE90_XNU_REGIONS='${STAGE90_XNU_REGIONS}' is neither 0 nor 1" >&2; exit 1 ;;
esac
[[ ${STAGE90_XNU_REGIONS:-0} -eq 1 ]] \
    && COMP_DEFINES_EXTRA+=(-DSTAGE90_XNU_REGIONS=1) \
    || COMP_DEFINES_EXTRA+=(-DSTAGE90_XNU_REGIONS=0)
# Self-check: this script has no `--dry-run`/`-n` mode (the only `--` switches are --limit/--dir/
# --blockers/--platform-only), so there is no seam that prints the define list. The assertion below
# is the seam that can run: the append above must have landed in the array this loop compiles with.
# It is not paranoia - an always-defined macro is the entire off-path argument, and a future edit that
# moved the append behind a branch would otherwise re-create exactly the undefined-name defect this
# line exists to fix, silently.
case " ${COMP_DEFINES_EXTRA[*]} " in
    *" -DSTAGE90_XNU_REGIONS="*) ;;
    *) echo "REFUSING: -DSTAGE90_XNU_REGIONS did not enter COMP_DEFINES_EXTRA" >&2; exit 3 ;;
esac

# The EABI runtime, which is not in the manifest and is not Apple's. `armv7-unknown-netbsd-eabi`
# (and `armv7-none-eabi` before it) lowers an aggregate copy to `__aeabi_memcpy4`, where a Darwin
# target lowers it to `memcpy` - so the ELF path needs four symbols Apple's tree never mentions.
# They are compiled here, with the loop's own flags, because a second flag list is this project's
# most repeated defect: the target triple used to be spelled out in four scripts before
# experiment-161. See src/xnu_aeabi_runtime.c.
RUNTIME_SOURCES=("$REPO_ROOT/src/xnu_aeabi_runtime.c")
RT_OUT=$XNU_RT_OBJ_OUT

# The configuration to build. `RELEASE` is Apple's full iOS kernel; `STAGE90_BOOT` is the minimal
# one declared in tools/xnu_config/minimal/STAGE90_BOOT.local, and its manifest is built by passing
# the same XNU_MASTER_LOCAL to list_sources.py. Default is the full one, because the full one is
# what "does XNU compile" means; the minimal one is what "can this boot" means.
CONFIG=${XNU_KERNEL_CONFIG:-RELEASE}
DEVICE_TABLE=$XNU_DEVICE_TABLE

LIMIT=0
ONLY_DIR=""
SHOW_BLOCKERS=0
ONLY_PLATFORM=0
PRINT_FLAGS=0
TRAP_ARGV_MODE=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --limit)    LIMIT=$2; shift 2 ;;
        --dir)      ONLY_DIR=$2; shift 2 ;;
        --blockers) SHOW_BLOCKERS=${2:-25}; shift 2 ;;
        # `--platform-only`: compile the four out-of-manifest blocks and nothing else.
        #
        # It exists so that the files in this build that are *this project's* - the platform expert
        # in `src/platform/` and the pthread function table in
        # `src/supply/`, whose every edit needs a compile to check - can be iterated
        # on without recompiling 698 Apple objects to reach them. Measured cost of the alternative: a
        # full run is minutes, and the first version of that file failed on one undeclared
        # identifier; measured cost of this mode, at the platform block alone: 0.9 seconds.
        #
        # Two things make it safe rather than a second build path:
        #   * the manifest is emptied, so the loop body cannot run - not skipped by a branch, but
        #     given nothing to read. Every counter stays 0 and the per-file machinery above is
        #     untouched.
        #   * the `rm -f "$OUT"/*.o` truncation is skipped, because the objects it would delete are
        #     the pool's, which the entry link needs and this mode is not going to rebuild.
        #   * the pool's `config.stamp` is **read and not written**, and this mode stops if the pool is
        #     not the configuration it would compile the platform blocks with - see the 492 block at
        #     the end of this script for what a stamp written by a mode that builds no pool cost.
        # It still checks the component table, the device table and the generated roots, so a
        # platform-only run is a real build of those four blocks under the same conditions.
        --platform-only) ONLY_PLATFORM=1; shift ;;
        # **1021d.** `--print-flags` prints the two resolved compile argv arrays (and the pool
        # census the FP by-value clause is read against) and exits before any object is written. It
        # exists because this script's answer to "which flags did the pool actually get" was, until
        # now, only the text near the append - and the 1021d switch's OFF-identity claim is *about*
        # the argv. `build_1021d.sh` runs it as a step-0 precondition and the clause reads it as the
        # OFF reading. The flag itself is acted on far below, beside the arrays it prints, so that
        # the print and the compile cannot be two definitions of the same list.
        --print-flags) PRINT_FLAGS=1; shift ;;
        --trap-argv) TRAP_ARGV_MODE=1; shift ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

# ====================================================================================================
# 1021d -- THE FP/NEON CODEGEN SWITCH, RESOLVED **BEFORE ANY SIDE EFFECT**.
# ====================================================================================================
# **WHY THIS BLOCK IS HERE AND NOT BESIDE THE FLAG ARRAYS (and it is not a style choice).** The switch
# is `STAGE90_XNU_GENERAL_REGS`, and `--print-flags` exists so the resolved argv can be read from
# OUTSIDE this script instead of grepped out of its text. The first version of this rung put that
# block beside `CC_ARGS`, ~1000 lines down -- i.e. **below the `mkdir -p "$OUT"` + `rm -f "$OUT"/*.o`
# truncation**. So a `--print-flags` invocation TORE DOWN the 705-object D13 pool and then printed its
# flags and exited: a read-only-looking mode with a destructive side effect, which is this project's
# `[[mi4-measurement-defects]]`/`[[mi4-out-stage90-is-shared-live-state]]` shape exactly, and it was
# MEASURED (it cost the pool once). The resolve and the print are therefore the FIRST thing after
# argument parsing, above every `mkdir`, `rm`, generator and compile in this file.
GENERAL_REGS=${STAGE90_XNU_GENERAL_REGS:-0}
case "$GENERAL_REGS" in
    0|1) ;;
    *) echo "REFUSING: STAGE90_XNU_GENERAL_REGS='$GENERAL_REGS' is neither 0 nor 1" >&2; exit 1 ;;
esac
# OFF is today's two flags, word for word; ON is Apple's `-msoft-float` (MakeInc.def:377-379) ALONE
# -- both FP flags dropped, exactly as docs/1021c section 2.1 prescribes. `-mfpu=neon-vfpv4` is not
# KEPT beside `-msoft-float`: it is INERT for codegen (it changes neither the FP-register allocation
# nor anything else -- MEASURED, and see the note by `CC_ARGS`), so keeping it would only leave a flag
# that READS as "NEON is on" next to the switch that says it is off, which is the two-spellings shape.
if [[ $GENERAL_REGS -eq 0 ]]; then
    FP_FLAGS=(-mfpu=neon-vfpv4 -mfloat-abi=softfp)
else
    FP_FLAGS=(-msoft-float)
fi
if [[ $PRINT_FLAGS -eq 1 ]]; then
    # The census count is computed here, from the manifest, for the same reason: a reader of this
    # output must not have to run a build to learn the floor the by-value clause uses.
    _pfn=0
    while IFS= read -r _pfp; do
        [[ -n $_pfp && -f $_pfp ]] && _pfn=$((_pfn + 1))
    done < <(grep -E '\.(c|cpp)$' "$MANIFEST" 2>/dev/null || true)
    _pfplat=$(ls "$XNU_PLATFORM_OBJ_OUT"/*.o 2>/dev/null | wc -l)
    echo "STAGE90_XNU_GENERAL_REGS=$GENERAL_REGS"
    echo "FP_FLAGS=${FP_FLAGS[*]}"
    echo "CC_ARGS=clang --target=$("$TOOLS_DIR/xnu_config/arm_target.sh") -mcpu=cortex-a15 -marm ${FP_FLAGS[*]} -ffreestanding -fno-builtin -fno-common -fno-pic -O2 -w -ferror-limit=0"
    echo "CXX_ARGS=clang++ --target=$("$TOOLS_DIR/xnu_config/arm_target.sh") -mcpu=cortex-a15 -marm ${FP_FLAGS[*]} -ffreestanding -fno-builtin -fno-common -fno-pic -O2 -w -ferror-limit=0 -fno-exceptions -fno-rtti"
    echo "POOL_OBJ_DIR=$OUT"
    echo "POOL_PLATFORM_OBJ_DIR=$XNU_PLATFORM_OBJ_OUT"
    echo "POOL_OBJ_EXPECT=$((_pfn + _pfplat))"
    echo "POOL_C_CPP_EXPECT=$_pfn"
    echo "POOL_PLATFORM_EXPECT=$_pfplat"
    exit 0
fi

if [[ $ONLY_PLATFORM -eq 1 ]]; then
    # An empty regular file rather than `/dev/null`: the check above asks `[[ -f $MANIFEST ]]`, which
    # is false for a character device, and the first version of this mode stopped there.
    MANIFEST=$REPO_ROOT/out/.platform_only_manifest.txt
    : > "$MANIFEST"
fi

# And the same check for the conditions this script defines by hand: each must agree with
# xnu_config/device_table.py, which is what the manifest reads. They disagreed for several stages -
# `-DMONOTONIC=1` was defined here while the manifest excluded the only file implementing it - and
# nothing compared them, so it is compared here now.
# Check first, write second: the tool does the comparison and exits 1 on a disagreement, so writing
# before checking would overwrite the very file the check is about.
#
# **And this block runs before the manifest, not after it (470).** It used to sit forty lines below,
# and the manifest - which *reads* `$DEVICE_TABLE` - was therefore written from the table the
# *previous* build left behind. The comment above says the property in words ("A required input that
# a generated input determines has to be generated too, or the report is about two different
# configurations") and the order contradicted it, which cost one device run: experiment 468's
# configuration selects three lines the previous one did not, one of them
# `pseudo-device vndevice 4 init vndevice_init` (`config/MASTER:436`), the table gained `vndevice 1`,
# and the manifest written from the old table omitted `bsd/dev/vn/vn.c` and `shadow.c` - so
# `pseudo_inits[]` (generated from the *configuration*, which was current) named `vndevice_init` and
# no object in the pool defined it. The run stopped there, at the first stand-in the boot has entered
# in four hundred experiments.
"$TOOLS_DIR/xnu_config/device_table.py" >/dev/null || {
    echo "the conditions this script defines disagree with xnu_config/device_table.py:" >&2
    "$TOOLS_DIR/xnu_config/device_table.py" >/dev/null
    exit 2
}
"$TOOLS_DIR/xnu_config/device_table.py" --write "$DEVICE_TABLE" >/dev/null

# **The manifest is generated from the table, not required** (experiment 440). It was a hand-run
# prerequisite and the table is written by this script, so the two could disagree — and they did: the
# first 440 build wrote a table turning `ether`, `loop` and `bpfilter` on, compiled the *previous*
# manifest that omits `bpf.c`, `bpf_if_loop.c`'s neighbours and four ethernet files, and reported
# `615 tried / 614 compile / 1 fail` — a clean success that had not built anything the step was
# about. A required input that a generated input determines has to be generated too, or the report is
# about two different configurations.
# THE POOL'S MANIFEST IS REGENERATED BY A POOL BUILD (2026-10-20).  It used to be: generated in
# `--platform-only`'s branch (emptied first) and otherwise left exactly as `xnu_tree_roots.sh` found it
# -- and that file exports `MANIFEST=${MANIFEST:-<out>/...}`, so a caller selecting a different path got
# it honoured and the build then refused ("no manifest at ...").  A path is a place; the LIST is a
# property of the configuration, and leaving a caller's (or a previous build's) list in place is the
# `one value, two definitions` shape one level up.  So every run that will compile the pool empties the
# file and re-lists from the same table the rest of this script uses.  (Empty FIRST, not after: the
# list is written after the device table below, and a manifest left over from a run that died between
# the two must never be the one this build compiles.)
if [[ $ONLY_PLATFORM -eq 0 ]]; then
    : > "$MANIFEST"
fi

if [[ $ONLY_PLATFORM -eq 0 ]]; then
    # The HFS sources join the manifest here when the port is on (`$HFS_PORT`, above), from the
    # tracked list (`--extra`); with it off the manifest is the base 733 exactly as before, so this
    # edit changes nothing about the arm on disk.  When it IS on, `--extra` exits non-zero and writes
    # NO manifest for a path it cannot find, so a tree that has not been staged cannot produce a kernel
    # that claims to have HFS.
    _hfs_extra=()
    [[ $HFS_PORT -eq 1 ]] && _hfs_extra=(--extra "$HFS_FILES")
    # `--generated-dir` and `--device-table` are named explicitly, not left to `list_sources.py`'s
    # defaults, because those defaults are pinned to the BASE tree's `out/` roots.  A build pointed
    # at another tree would otherwise resolve its MIG `_server.c` sources (and its device conditions)
    # into 4570's directories - the `one value, two definitions` class.  The values derived here equal
    # the defaults on 4570 (MIG_KSERVER/MIG_HEADERS/DEVICE_TABLE all default to the same paths), so
    # the base tree's manifest is byte-identical; on another tree they follow its own roots.
    LS_MESSAGE=$("$TOOLS_DIR/xnu_config/list_sources.py" "$CONFIG" --xnu "$XNU" --write "$MANIFEST" \
                 --generated-dir "$MIG_KSERVER:$MIG_HEADERS:$GENERATED/bsd" \
                 --device-table "$DEVICE_TABLE" \
                 "${_hfs_extra[@]}" 2>&1) || {
        echo "$LS_MESSAGE" >&2
        exit 2
    }
    [[ ${VERBOSE:-0} -eq 0 ]] || printf '%s\n' "$LS_MESSAGE"
fi

[[ -f $MANIFEST ]] || {
    echo "no manifest at $MANIFEST - run:" >&2
    echo "  ./tools/xnu_config/list_sources.py RELEASE --write $MANIFEST" >&2
    exit 2
}
[[ -d $MIG_HEADERS/mach ]] || {
    echo "no generated mach headers - run tools/gen_mach_headers.sh first" >&2; exit 2; }

# The per-component flag table is an invariant of every count this script prints, so check it here
# rather than discovering a drift from a surprising number. It is a table transcribed out of XNU's
# own Makefile templates, and a transcription is exactly what drifts.
"$TOOLS_DIR/check_component_defines.py" >/dev/null || {
    echo "component_defines.sh no longer matches the Makefile templates - run:" >&2
    echo "  ./tools/check_component_defines.py" >&2
    exit 2
}

# And the **device** headers, generated here rather than required, for the reason `gen_pseudo_inits.py`
# is run here: the value has to belong to the configuration, and a stale one is not an error, it is a
# wrong answer. `mkheaders.c:85-101` writes `#define N<COND> <count>` from the configuration's own
# `d_slave`, and until experiment 440 four of these five headers were hand-written constants - with
# values that disagreed with both the table and the generated `pseudo_inits[]`. The generator rewrites
# the directory and removes headers for conditions the configuration no longer has.
XD_MESSAGE=$("$TOOLS_DIR/gen_device_headers.py" 2>&1) || {
    echo "$XD_MESSAGE" >&2
    exit 2
}
[[ ${VERBOSE:-0} -eq 0 ]] || printf '%s\n' "$XD_MESSAGE"

# And the third table, for the same reason and with a sharper failure mode: which options a
# translation unit sees is a property of its *component* (experiment-438), and the generator that
# writes the per-component `meta_features.h` files was, until then, making a claim in a comment
# instead of a check. Structural, so it fails in a second rather than after 680 files.
#
# **And it is generated here, not merely checked (471).** Until this step `gen_option_headers.py` was
# a hand-run prerequisite and only `check_option_headers.py` ran below - and that check compares the
# generated files against `conf/files` (membership and reads), not against the *configuration*
# (values), so it passed over a header set that was one configuration out of date. The cost is
# measured: the STAGE90_XNU headers on disk from 10:42 spelled `#define DEVELOPMENT 0`, the 468
# configuration selects `options DEVELOPMENT` (`config/MASTER:611`, and
# `xnu_config/make_defines.sh STAGE90_XNU` says `-DDEVELOPMENT=1`), so `mach_loader.c:634`'s
# `#if !(DEVELOPMENT || DEBUG) return (LOAD_FAILURE);` - the static-executable refusal Apple's own
# comment calls "disallowed except for development" - refused the RAM disk's Mach-O. The device run
# reported `xnu_entry_lmf_ret = 0x04` (`LOAD_FAILURE`) and the exec path's reason
# `namespace 9 code 1` (`OS_REASON_EXEC`, `EXEC_EXIT_REASON_BAD_MACHO`), then killed `initproc` and
# panicked about it. One regenerated header is the whole of the fix; the *ordering* is what was
# wrong, which is 440's defect (the manifest generated from a stale device table) in the one input
# whose staleness the check below cannot see.
XO_MESSAGE=$(XNU_KERNEL_CONFIG=$CONFIG XNU_MASTER_LOCAL=${XNU_MASTER_LOCAL:-} \
             "$TOOLS_DIR/gen_option_headers.py" 2>&1) || {
    echo "$XO_MESSAGE" >&2
    exit 2
}
[[ ${VERBOSE:-0} -eq 0 ]] || printf '%s\n' "$XO_MESSAGE"
XOC_MESSAGE=$("$TOOLS_DIR/check_option_headers.py" 2>&1) || {
    echo "$XOC_MESSAGE" >&2
    exit 2
}

# And the pseudo-device table's array (experiment-439). `bsd_autoconf()` walks `pseudo_inits` and
# 438's run faulted fetching `0xE52DE004` - the ARM encoding of `push {lr}` - because that symbol had
# been stubbed as a *function* and the walk read the stand-in's own prologue as the first entry's
# `ps_func`. The array is generated rather than typed, from the same expanded configuration Apple's
# `mkioconf.c` reads, and generated **into this configuration's own directory**: RELEASE keeps
# `bpfilter` and `fsevents` and STAGE90_BOOT does not, so a shared path would let whichever
# generation ran last decide for both.
PI_MESSAGE=$(XNU_KERNEL_CONFIG=$CONFIG "$TOOLS_DIR/gen_pseudo_inits.py" --write 2>&1) || {
    echo "$PI_MESSAGE" >&2
    exit 2
}
# The path comes from the generator rather than being spelled again here: one value with two
# definitions is this project's most-repeated defect, and a `$REPO_ROOT/out/...` written in two
# places has nothing comparing them.
PSEUDO_INITS_SRC=$(XNU_KERNEL_CONFIG=$CONFIG "$TOOLS_DIR/gen_pseudo_inits.py" --print-path)

# And the check that compares the three halves of one device decision (experiment-440). "Is
# `bpfilter` on?" is answered by the manifest's table, by the generated `NBPFILTER` header, and by
# the `{4, bpf_init}` entry in the array above - and for several stages those three gave three
# different answers with nothing comparing them, which is how the boot came to stop on `bpf_init`:
# a symbol this image was simultaneously claiming, in a count taken from `config/MASTER`, and
# refusing to compile. Run here, after all three exist and before any file is compiled.
DC_MESSAGE=$("$TOOLS_DIR/check_device_conditions.py" 2>&1) || {
    echo "$DC_MESSAGE" >&2
    exit 2
}

mkdir -p "$OUT"
# Truncate every output. A build script that appends leaves the previous run's failures in the
# list, and a count read from it is then a count of two runs - which is how a 397-file result
# became 582 here before anyone noticed.
#
# The per-file logs need the same treatment, and did not get it until 2026-09-17: a file that fails
# leaves `$OUT/$key.log` behind and nothing removes it, so an `ls *.log` or a "first error per file"
# sweep silently mixes two runs - after the per-component fix, out/xnu_min_obj still held the
# baseline run's `ffs` logs and read as if nothing had changed. Delete them before recreating
# all.log, since this glob would otherwise match it.
rm -f "$OUT"/*.log
# And the objects, for the same reason and one level worse. A file that leaves the manifest - or
# moves, as the MIG `_server.c` files did when the two server-header variants were separated
# (experiment-145) - leaves its `.o` behind, and the link then reports **duplicate symbols for files
# the manifest no longer names**. That is how this was found: the measurement link failed on
# `multiple definition of iokit_server_routine` between `mach_headers/device_device_server.o` and
# `mach_headers/kserver_device_device_server.o`, one of which was stale.
#
# **Not in `--platform-only` mode**, where the manifest is empty and these objects are exactly the
# ones the entry link is holding on to: deleting them would leave the project with no pool until a
# full run, which is the run the mode exists to avoid.
# **`--trap-argv` is read-only too** (2026-10-20): it prints one file's resolved compile argv and
# writes no object, so the pool it is describing must not be torn down -- that is the same shape the
# 1021d note at the top of this file records, one level down.
[[ $ONLY_PLATFORM -eq 1 || $TRAP_ARGV_MODE -eq 1 ]] || rm -f "$OUT"/*.o
: > "$OUT/all.log"
: > "$OUT/failed.txt"

# The force-include set and the values are build_xnu_arm_layer.sh's, which is where they were
# worked out and where each one's reason is recorded. Duplicated here rather than factored out
# because the two scripts want to stay independently runnable; if they drift, this comment is the
# pointer back.
#
# **`-include kern/queue.h` was in both lists and is gone from both.** `kern/queue.h:224-225` defines
# two *function-like* macros —
#
#     #define enqueue(queue,elt)  enqueue_tail(queue, elt)
#     #define dequeue(queue)      dequeue_head(queue)
#
# — so `iokit/IOKit/IODataQueue.h:131`'s `virtual Boolean enqueue(void *data, UInt32 dataSize);` was
# rewritten to `enqueue_tail(...)` on the way through the preprocessor, while the out-of-line
# definition at `IODataQueue.cpp:157` (which `#undef`s the macro at `:47`, too late) kept its own
# name. Two IOKit files failed with "out-of-line definition of 'enqueue' does not match any
# declaration", a message that names neither the macro nor the header. Removing the force-include
# leaves **every other object byte-identical** and takes C++ from 78 to 80 of 83. Apple force-includes
# nothing; see experiment-157.
FORCE_INCLUDES=(
    -include sys/_types/_u_int.h
    -include arm/simple_lock.h
    -include kern/ast.h
    -include mach/task_policy.h
    -include mach/thread_policy.h
    -include mi4ios6_build_config.h
    # `caddr_t`, for the same reason `u_int` is above: osfmk/vm/vm_compressor.c uses it and reaches
    # no header that defines it. Apple's build does reach one - the BSD `<sys/types.h>` chain - and
    # which one differs between the two builds enough that chasing it is guesswork; what is measured
    # is that the narrow header (it defines `caddr_t` and nothing else) takes RELEASE from 591 to 592
    # with no regressions, and vm_compressor.c is the largest single item on the boot path.
    -include sys/_types/_caddr_t.h
    # `u_char`, for the same reason and the same place: `osfmk/kern/btlog.c:641` casts to it and
    # reaches no header that defines it — the files that *do* reach `u_char` do so through
    # `osfmk/libsa/types.h`, via `<libsa/stdlib.h>`, which most of osfmk does not include.
    -include sys/_types/_u_char.h
    -include meta_features.h
)
# `-include stdatomic.h` used to be in that list, to get `enum memory_order` for the osfmk/arm
# atomics. It is NOT there any more, and the reason is a side effect nine files wide:
# EXTERNAL_HEADERS/stdatomic.h:38 includes <stddef.h>, which defines `ptrdiff_t`, and
# `libkern/zlib/zutil.h:193-194` is
#
#     #if KERNEL
#         typedef long ptrdiff_t;
#
# in a file Apple compiles into the ARM kernel - so in Apple's build `ptrdiff_t` is NOT defined at
# that point and Apple's kernel <string.h> does not pull stddef.h in. Force-including stdatomic.h
# put it into every translation unit and failed eight libkern/zlib files with "typedef redefinition
# with different types ('long' vs ... 'int')". Removing it is 381 -> 389 of 419 with no regressions.
# Nothing that needs the atomics header includes it by name, so this was invisible until the
# zlib failures were attributed to their actual source.

# The configuration's own options, expanded from MASTER via the doconf pipeline. These are the
# values Apple's build would have; the block below is only the flags that configure the *toolchain*
# and the two that resolve collisions the config cannot express.
# **488: read once, with the status seen.** The form this replaces was `done < <(...)`, and a process
# substitution hides its command's failure: the loop then runs zero times and the whole kernel is
# compiled with none of the configuration's options, silently. This script was the *lucky* caller - it
# passes `XNU_MASTER_LOCAL` through, so its expansion did not fail - and the three that were not are
# what experiment 488 is about. The ordinary `while read` over a here-string is the house form now.
CONFIG_DEFINES=()
if ! defines=$("$TOOLS_DIR/xnu_config/make_defines.sh" "$CONFIG"); then
    echo "build_xnu_arm_kernel.sh: make_defines.sh failed for $CONFIG" >&2
    exit 1
fi
if [[ -z $defines ]]; then
    echo "build_xnu_arm_kernel.sh: $CONFIG expanded to no options - refusing to compile without them" >&2
    exit 1
fi
while IFS= read -r d; do
    [[ -n $d ]] && CONFIG_DEFINES+=("$d")
done <<<"$defines"

# A conditional device define chosen by the TREE, not by its name (913), the same way
# `select_master.sh` picks the MASTER dir by layout. `-DMONOTONIC=1` is 4570's
# `osfmk/kern/kern_monotonic.c optional monotonic`; the 2013-era Darwin-13 (iOS 7) tree has **no
# kern_monotonic.c** and no `monotonic` condition at all, so defining it there both exposes a
# condition the tree never tests and makes `xnu_config/device_table.py` (which reads `XNU_TREE`)
# refuse the build with "an override for a name that is not a device of RELEASE". Chosen from the
# tree's own conf/files: for 4570 the grep matches and this is `-DMONOTONIC=1` exactly as before, so
# nothing about the 4570 arm on disk changes.
if grep -q 'kern_monotonic\.c' "$XNU/osfmk/conf/files" 2>/dev/null; then
    MONOTONIC_DEFINE=(-DMONOTONIC=1)
else
    MONOTONIC_DEFINE=()
fi

DEFINES=(
    # `CONFIG_DEFINES` is NOT here. It is per-component: on a tree with a per-component MASTER layout
    # (Darwin-13) each component's `conf/MASTER` declares its own `RELEASE` with its own size
    # attributes, and a single global set takes whichever the union happened to satisfy. The main
    # loops take `$CONFIG_COMP_DEFINES[@]` per file instead; the few non-manifest blocks
    # (EABI runtime, firehose, the platform expert) prepend `$CONFIG_DEFINES[@]` themselves, because
    # their sources are this project's own and belong to no component. On 4570 `component_conf_dir`
    # returns empty, so both slices are the one `config/MASTER` expansion and nothing changes.
    # MACH_KERNEL_PRIVATE is NOT here. It is per-component, and putting it here was this build's
    # single largest defect: see xnu_config/component_defines.sh for the table and the reason. In
    # short, MACH_KERNEL_PRIVATE is what reaches kern/misc_protos.h, whose ffs/fls/copyinstr
    # declarations collide with bsd/libkern/libkern.h's, so defining it globally broke every BSD
    # translation unit that includes <sys/systm.h> - 127 files in the minimal configuration.
    -DXNU_KERNEL_PRIVATE=1 -DKERNEL_PRIVATE=1
    -DMACH_BSD=1 -DPRIVATE=1 -DKPC=1 "${MONOTONIC_DEFINE[@]}" -DXPR_DEBUG=0 -DLOCK_PRIVATE=1
    -DARMA7=1 -DKERNEL=1 -D__arm__=1 -DCONFIG_EMBEDDED=1 -D__ARM_L2CACHE_SIZE_LOG__=21
    # `__ARM__`, and the case is the whole point. `bsd/kern/kern_sysctl.c:2772` is
    # `#if defined(__ARM__)`, and the build defined only the compiler's lowercase `__arm__` - so the
    # 64-bit `SYSCTL_QUAD` branch was taken for 32-bit values and the file failed with
    # `'_sysctl__vm_global_no_user_wire_amount_size_check' declared as an array with a negative
    # size`. One define; and the error named neither the macro nor the file that uses it.
    -D__ARM__=1
    # NPTY/NPTMX: the device conditions this configuration turns on, so that bsd/kern/tty_pty.c,
    # tty_ptmx.c and tty_dev.c are both compiled (device_table.py) and preprocessed consistently.
    # NPTY 1 rather than 0 because 0 does not compile: conf.c's #else branch is missing ptsselect
    # (experiment-130), and tty_pty.c promotes 1 to 32 itself with a #warning.
    -DNPTY=1 -DNPTMX=1
    # __APPLE__ is what Apple's compiler defines and this project's does not. The scripts here use
    # an ELF target triple (see xnu_config/arm_target.sh); Apple's build uses a Darwin target triple,
    # and `__APPLE__` is part of that triple rather than of the source. Supplying the macro is worth
    # 17 files in the minimal configuration and 99 in RELEASE, with no regressions in either:
    #
    #     osfmk/prng/YarrowCoreLib/include/yarrow.h:91   #if defined(macintosh) || defined(__APPLE__)
    #
    # is the clearest case - on that branch YARROWAPI is empty and `WindowsTypesForMac.h` is
    # included, which is where BYTE, UINT, LONGLONG and LPVOID come from. Off it, the vendored
    # Windows library takes its `__declspec(dllimport)` path and seven files die on it.
    #
    # Measured: `-D__MACH__=1` alongside it changes nothing (345 either way), and swapping the whole
    # target triple for `armv7-apple-darwin` is worth exactly one more file (346) while changing the
    # object format from ELF to Mach-O - which is a decision for the link step, not for this
    # measurement. See experiment-121. **And the type widths that triple carries ARE now available
    # without Mach-O** - that is what xnu_config/arm_target.sh is about, and it is worth three files
    # and 35 symbols. experiment-161.
    -D__APPLE__=1
    -DCONFIG_SCHED_TIMESHARE_CORE=1 -DCONFIG_SCHED_TRADITIONAL=1
    # `-D_CLOCK_T=1` used to be here, to force kern_types.h's `typedef struct clock *clock_t` to win
    # over bsd/sys/_types/_clock_t.h's `__darwin_clock_t`. It is gone, and the reason is the same
    # one experiment-118 was about: it was a workaround for MACH_KERNEL_PRIVATE being global. With
    # the per-component defines, kern_types.h's definition is only reachable from osfmk and iokit
    # files, bsd files get _clock_t.h's, and the two no longer meet. Removing it is 560 -> 564.
    #
    # ---------------------------------------------------------------------------------------------
    # 459: the configuration's `no_printf_str`, cancelled - and `-U` rather than `-D...=0`.
    #
    # `STAGE90_XNU` inherits RELEASE, and RELEASE's `BSD_RELEASE` attribute carries `no_printf_str`
    # (`config/MASTER.arm:24`), which `options CONFIG_NO_PRINTF_STRINGS` (`config/MASTER:302`) turns
    # into -DCONFIG_NO_PRINTF_STRINGS=1. `bsd/libkern/libkern.h:171-178` and
    # `osfmk/kern/misc_protos.h:150-157` then make `printf` a *macro* -
    # `printf(x, ...) -> _consume_printf_args(0, ## __VA_ARGS__)` - so the format string is not only
    # unprinted, it is not in the object. 458 measured both halves of that: `bsd_init`'s
    # `printf(copyright)` is `mov r0,#0; bl _consume_printf_args` in the image, and
    # `arm-none-eabi-strings out/xnu_kernel_obj/bsd_kern_bsd_init.o` does not contain
    # `"cannot mount root, errno = %d\n"` at all.
    #
    # The flag has to be *cancelled*, not set to 0: two of the three readers are `#if CONFIG_...`,
    # which reads 0 either way, but the macro's other spelling is `#ifdef` - and "an off option has
    # two spellings" is a defect this project has recorded (mi4-off-option-two-spellings,
    # experiment-164). `-U` after the configuration's own `-D` leaves the macro undefined for every
    # reader, which is the same reading Apple's macOS builds get. Measured both ways on the two
    # compilers in this build before it was written here: with `-DCONFIG_NO_PRINTF_STRINGS=1` ahead
    # of it, `arm-none-eabi-gcc` and `clang` both leave the macro undefined, and the control (no
    # `-U`) fails on `#error DEFINED_TRUTHY`.
    #
    # What it buys: the class of message `bsd_init.c` and `load_init_program` print about the root
    # device can reach the console. What it costs: the strings themselves, which Apple's own comment
    # prices at "around 45K of kernel footprint" (`config/MASTER:300`). `no_kprintf_str` stays ON:
    # `kprintf`'s call sites are macro'd away in the same way (`pexpert/pexpert/pexpert.h:204`), it is
    # *also* gated at run time by `disable_serial_output` (`pexpert/arm/pe_kprintf.c:66`, TRUE unless
    # `debug & DB_KPRT`), and nothing on this step's path prints through it - including `panic()`,
    # which routes to the debugger's own printer. That is why a panic in this configuration is
    # silent, and it is written down here rather than discovered.
    -UCONFIG_NO_PRINTF_STRINGS
    # ---------------------------------------------------------------------------------------------
    # 472: the configuration's `secure_kernel`, cancelled - for the same reason and by the same
    # mechanism.
    #
    # `RELEASE` inherits `BSD_RELEASE`, which is `[ BSD_BASE no_printf_str no_kprintf_str
    # secure_kernel ]` (`config/MASTER.arm:24`), so `options SECURE_KERNEL # <secure_kernel>`
    # (`config/MASTER:101`) is on in every configuration this project composes from RELEASE -
    # `xnu_config/make_defines.sh RELEASE` and `... STAGE90_XNU` both print `-DSECURE_KERNEL=1`. What
    # that costs is measured, and it is the whole of experiment 471's frontier:
    # `bsd/kern/kern_cs.c:82-84` is `#if SECURE_KERNEL` / `const int cs_enforcement_enable = 1;`, and
    # `arm-none-eabi-nm out/xnu_kernel_obj/bsd_kern_kern_cs.o` reports it **`R`** - read-only, the
    # `const` - while the `cs_enforcement_disable` boot-arg string is absent from the same object,
    # because `cs_init`'s `#if !SECURE_KERNEL` block (`:133-155`) that reads it is compiled out. So
    # `cs_enforcement(NULL)` returns 1 unconditionally, and `mach_loader.c:1126-1130`
    #
    #     if (!got_code_signatures) { if (cs_enforcement(NULL)) { ret = LOAD_FAILURE; } ... }
    #
    # refuses **any executable without an embedded code signature**. The RAM disk's Mach-O has three
    # load commands and no `LC_CODE_SIGNATURE`, so `load_machfile` returns `LOAD_FAILURE` (4), and
    # 471's wrappers measured the rest of that path on the device: `xnu_entry_lmf_ret = 0x04`,
    # `xnu_entry_osr_ns = 9` (`OS_REASON_EXEC`) with `xnu_entry_osr_code = 1`
    # (`EXEC_EXIT_REASON_BAD_MACHO`), and then `kern_exec.c`'s `badtoolate` arms
    # `psignal_with_reason(p, SIGKILL, reason)` - which `kern_sig.c:2132-2142` answers with
    # `panic_plain("unexpected SIGKILL of %s %s with reason -- ...")` because `p == initproc`.
    #
    # Undefined rather than 0, and that is not a style choice. **Twenty-four files read this macro
    # and they use all four spellings** - `#if SECURE_KERNEL` (`kern_cs.c:82`, `vfs_syscalls.c:491`),
    # `#if !SECURE_KERNEL` (`kern_exec.c:563`, `cprotect.h:59`), `#ifdef SECURE_KERNEL`
    # (`OSKextLib.cpp:263`, `kern_core.c:121`, `kern_sysctl.c:2284`), `#ifndef SECURE_KERNEL`
    # (`vm_unix.c:307`) - and for `#define SECURE_KERNEL 0` only two of the four flip. `-U` after the
    # configuration's own `-D` is the one spelling that leaves every reader reading "off", which is
    # the defect `mi4-off-option-two-spellings` recorded and what the cancellation above says in
    # general. The check that it took is over the object rather than the flag list: this script fails
    # the build if `cs_enforcement_enable` is still read-only in `bsd_kern_kern_cs.o`, because that
    # is the one measured consequence the whole frontier turns on.
    -USECURE_KERNEL
)

# **874's root row.** The HFS+ port supplies `hfs_mountroot` (the `vfc_mountroot` slot a root mount
# needs), and the row that carries it must be in the STATIC `vfstbllist[]`, before `mockfs` - 874
# measured that a row registered after boot (`vfs_fsadd`) lands after mockfs and is never tried. That
# table is inside the untracked 4570 tree, so the row is a **tracked patch** to `bsd/vfs/vfs_conf.c`
# (`tools/patch_vfs_conf_hfs_row.py`, applied by `tools/stage_hfs.sh`) guarded by `STAGE90_HFS_ROOT`.
# The guard is DEFINED for every compilation exactly when the port is on, so `vfs_conf.c` - a bsd file
# compiled by this loop - sees the same switch the HFS sources do, and the patch is inert when the
# port is off (the row's `#if STAGE90_HFS_ROOT` is false and `vfs_conf.c` compiles byte-for-byte as
# 4570 shipped it). It is added to the array rather than to `EXTRA_DEFINES` because it is a property
# of the configuration the pool is, and the pool's external `hfs_mountroot` lives in the HFS objects.
[[ ${HFS_PORT:-0} -eq 1 ]] && DEFINES+=(-DSTAGE90_HFS_ROOT=1)

# **899's mount-path live step markers.** The stager (`tools/hfs_patch_mount_markers.py`) inserts an
# `entry_live_write("xnu_live_hfs_stage", N)` at the five steps of the HFS+ mount, each guarded by
# `STAGE90_HFS_MOUNT_MARKERS`.  `STAGE90_XNU_HFS_MARKERS=1` defines the guard for the whole build, so
# the next press reports the last step the mount reached (897 served one read and the mount never
# returned).  Off by default, so a normal arm compiles the markers to nothing and is byte-for-byte
# unaffected.
[[ ${STAGE90_XNU_HFS_MARKERS:-0} -eq 1 ]] && DEFINES+=(-DSTAGE90_HFS_MOUNT_MARKERS=1)

# **905 B2's read-write root.** The stager (`tools/hfs_patch_root_rw.py`) inserts a guarded
# `vfs_clearflags(mp, MNT_RDONLY)` immediately before `hfs_mountroot`'s `hfs_mountfs` call, so the
# root mount is not read-only and the card unit's write path is reachable.  The guard
# `STAGE90_HFS_ROOT_RW` is DEFINED for the whole build exactly when the port is on AND the arm asks
# for it, so `hfs_vfsops.c` (a bsd/hfs file compiled by this build) sees the switch the port files do.
# Off by default: a normal port build compiles the `#if` false and the object is byte-for-byte the
# port-off one.  It is added to the array rather than to `EXTRA_DEFINES` because it is a property of
# this configuration's pool, like `STAGE90_HFS_ROOT` above.
[[ ${HFS_PORT:-0} -eq 1 && ${STAGE90_XNU_HFS_ROOT_RW:-0} -eq 1 ]] && DEFINES+=(-DSTAGE90_HFS_ROOT_RW=1)

# **The port's `kmem_alloc` tag redirect, only where the tree wants one.** `hfs_port_force.h` rewrites
# `kmem_alloc(map, addr, size)` to the 4-argument form 4570 introduced (`..., VM_KERN_MEMORY_FILE`).
# The Darwin-13 tree's `osfmk/vm/vm_kern.h` still has the 3-argument prototype and no `vm_tag_t`, so
# that rewrite collides with the tree's OWN declaration. Define the guard iff the tree has `vm_tag_t`,
# so D13 compiles the HFS calls against the tree's real prototype. Same authoring rule as the cprotect
# bridge gate in the force-include block above: judge the tree by its own header.
[[ ${HFS_PORT:-0} -eq 1 ]] && grep -q 'vm_tag_t' "$XNU/osfmk/vm/vm_kern.h" && DEFINES+=(-DSTAGE90_HFS_KMEM_TAG=1)

# **The port's HFS `MALLOC_ZONE` redirect, only where the tree's zone table cannot serve HFS.** §3 of
# `hfs_port_force.h` rewrites the HFS `MALLOC_ZONE`/`FREE_ZONE` onto `__MALLOC`/`_FREE` because 4570's
# `kmzones[]` rows 75/76/77/91/92/95 are the literal `{0, KMZ_MALLOC}` - its `kern_malloc.c` cannot see
# `struct cnode`, so `__MALLOC_ZONE` would PANIC (`_malloc_zone ZONE`) at the first cnode allocation
# (900). The Darwin-13 tree's `kern_malloc.c` DOES include `<hfs/hfs_cnode.h>` and its rows are the real
# `{SOS(cnode),KMZ_CREATEZONE}`..`{SOS(journal),...}` - so D13 serves every HFS type through its OWN
# zone path and the redirect is not owed. Worse, D13 names the allocator `_MALLOC` (3-arg), not 4570's
# `__MALLOC` (4-arg), so the redirect targets a symbol the D13 pool does not define: it becomes one of
# `xnu_arm_entry_undef.txt`'s stub bodies, and a boot stops with `stub_hit=__MALLOC` from
# `hfs_chash_getcnode` - the FIRST cnode allocation of the mount (the same site 900 panicked at, by the
# other route). Define the guard iff the tree's own `kern_malloc.c` does NOT see `hfs_cnode.h` (i.e. its
# rows are the `KMZ_MALLOC` fallback and it needs the redirect); the force header makes §3 a no-op
# without it. Same authoring rule as `STAGE90_HFS_KMEM_TAG` above: judge the tree by the definition it
# actually carries.
[[ ${HFS_PORT:-0} -eq 1 ]] && ! grep -q 'hfs/hfs_cnode.h' "$XNU/bsd/kern/kern_malloc.c" && DEFINES+=(-DSTAGE90_HFS_MALLOC_ZONE=1)

# **988's `removeKextBootstrap` __LINKEDIT teardown, compiled out where the segment cannot exist.**
# `osfmk/kern/startup.c:408 OSKextRemoveKextBootstrap()` is the first statement after `bsd_init()`
# returns, and on D13 it reached `OSKext::removeKextBootstrap()` (`libkern/c++/OSKext.cpp`) and
# prefetch-aborted at `800b2c90 e590501c ldr r5,[r0,#28]` with r0=0: `getsegbyname("__LINKEDIT")`
# (`:843`) returned NULL - our synthetic Mach-O declares ncmds=3, `__TEXT`/`__DATA`/`__PRELINK_TEXT`,
# and no `__LINKEDIT` - and the live `#if CONFIG_KXLD` block (`:861-950`; Apple's `:850-939` before the
# guard below was staged) dereferences `seg_to_remove` unguarded at `:870`
# (`seg_data = (void *) seg_to_remove->vmaddr;`). There is no `__LINKEDIT` here for kxld to make
# pageable, so the whole block is dead on
# this target: `SECURE_KERNEL` is cancelled by `DEFINES`' own `-USECURE_KERNEL`, and `keepsyms` is not
# passed, so the `#else` branch is empty too - the block executes nothing. The guarded edit lives in
# the untracked tree, so it is a **tracked patch** (`tools/stage_d13_kextb_login.sh`) wrapping
# `#if CONFIG_KXLD … #endif` in `#ifndef STAGE90_XNU_KEXTB_LOGIN`; when defined, the teardown compiles
# out and only `seg_to_remove`'s assignment and the `alreadyDone` return remain. `OSKext.cpp` is a
# kernel-pool file - it is compiled in the per-file loop of this same manifest (`:1456`), which passes
# `$DEFINES` - so the guard is added to the array rather than to `EXTRA_DEFINES`, exactly like
# `STAGE90_HFS_ROOT` above; a `--platform-only` run never sees it because the pool is not recompiled.
[[ ${STAGE90_XNU_KEXTB_LOGIN:-0} -eq 1 ]] && DEFINES+=(-DSTAGE90_XNU_KEXTB_LOGIN=1)

# 990's stack-alignment edit (`osfmk/arm/pcb.c`: `machine_stack_attach`/`machine_stack_handoff` round
# the saved-state block - `iss` = `stack_top - 68` = 4 mod 8 - and the frame below it down to 8, so
# every continuation/syscall C entry runs at an 8-aligned sp; 989 died at
# `parse_machfile+0x60c`'s `vld1.32 {d18},[r1 :64]` on a 4-mod-8 sp). `pcb.c` is a kernel-pool file,
# so the switch goes to the SAME array as the kext guard, not to `EXTRA_DEFINES`
# (`tools/stage_d13_sp_align.sh`). The `.s` half of 990 (`machine_routines_asm.s`'s astloop) is an
# ASSEMBLY-layer file - its `-D` rides `tools/assemble_arm_layer.sh`'s ASFLAGS instead.
[[ ${STAGE90_XNU_SP_ALIGN:-0} -eq 1 ]] && DEFINES+=(-DSTAGE90_XNU_SP_ALIGN=1)

# 991's memq_hint guard (`osfmk/vm/vm_resident.c`: `vm_page_lookup` treats `((vm_offset_t)mem <
# 0x80000000u || (mem & 3u))` as no hint for that call - a local shadow, the field is never written -
# after a bounded kprintf beginning `VMHINT991:`). 990's press died INSIDE that function (`ldrd
# r0,[r5,#24]` at pc=0x80020838, r5 = object->memq_hint = 0x1, object = 0xc0005b48, lr =
# vm_map_pmap_enter). `vm_resident.c` is a kernel-pool file, so the switch goes to the SAME array as
# the kext guard and the alignment switch, not to `EXTRA_DEFINES` (`tools/stage_d13_vmhint_guard.sh`).
[[ ${STAGE90_XNU_VMHINT_GUARD:-0} -eq 1 ]] && DEFINES+=(-DSTAGE90_XNU_VMHINT_GUARD=1)

# 1001's submap pmap-enter skip (`osfmk/vm/vm_map.c`: `vm_map_enter`'s pmap-enter tail is wrapped
# `if (!is_submap) { ... } else { bounded SUBMAPSKIP kprintf }`, keeping `pmap_empty = FALSE`). On a
# SUBMAP enter the `object` parameter IS the submap (`~:2063`), a vm_map-zone element, and the
# unguarded call locked/probed it as if it were a vm_object: 1000's press died at
# `hw_lock_lock(): PANIC: Lock 0xc0005b50 = 0xffb5be0b` on the FREED vm_map-zone element 0xc0005b48
# (w04 = 0xbaddecaf) - 990 died one field over (+0x18). `vm_map.c` is a kernel-pool file, so the
# switch goes to the SAME array as the kext/login guard, the alignment switch and the memq_hint
# guard, not to `EXTRA_DEFINES` (`tools/stage_d13_submap_pmap_skip.sh`).
[[ ${STAGE90_XNU_SUBMAP_PMAP_SKIP:-0} -eq 1 ]] && DEFINES+=(-DSTAGE90_XNU_SUBMAP_PMAP_SKIP=1)

# 1012's strip-site trace (`osfmk/vm/vm_fault.c`: five `entry_note_abt_wr(<site>,<va>,<prot>)` calls
# inserted by `tools/patch_d13_wrstrip.py`, each behind `#if defined(STAGE90_XNU_WRSTRIP) &&
# STAGE90_XNU_WRSTRIP`). They name WHICH strip site removes `VM_PROT_WRITE` from `prot` on the storm's
# VA, complementing the PMP_ENTER cell (`_pmpprot` says WHETHER write was lost at the enter). `vm_fault.c`
# is a kernel-pool file (`out/xnu_kernel_obj_d13/osfmk_vm_vm_fault.o`), so the switch goes to the SAME
# array as the kext/login guard, the alignment switch, the memq_hint guard and the submap-pmap skip,
# NOT to `EXTRA_DEFINES`; the entry-side recorder `entry_note_abt_wr` is gated separately through
# `STUB_DEFINES` in `src/entry/build_entry.sh`. OFF (WRSTRIP unset or 0) the `#if` excludes every
# probe, so this object is the tree's ORIGINAL bytes - the define IS the patch.
[[ ${STAGE90_XNU_WRSTRIP:-0} -eq 1 ]] && DEFINES+=(-DSTAGE90_XNU_WRSTRIP=1)

# 1014's TLB-FLUSH WITNESS (`osfmk/arm/pmap.c`: `pmap_flush_tlbs` gains a gated `entry_note_abt_wf(...)`
# call at the enter and at the exit of its flush decision, inserted by
# `tools/patch_d13_flushwitness.py`, each behind `#if defined(STAGE90_XNU_FLUSH_WITNESS) &&
# STAGE90_XNU_FLUSH_WITNESS`). It names WHICH flush arm ran for the faulting pmap (`_wfkind` 0 = none /
# 1 = full `arm_tlb_flushID` / 2 = `arm_tlb_flushID_ASID`), under WHICH ASID, with WHICH live TTBR0 -
# the ONE mechanism 1013's writable-leaf reading left unread. `pmap.c` is a kernel-pool file
# (`out/xnu_kernel_obj_d13/osfmk_arm_pmap.o`), so the switch goes to the SAME array as the kext/login
# guard, the alignment switch, the memq_hint guard, the submap-pmap skip and 1012's strip trace, NOT to
# `EXTRA_DEFINES`; the entry-side recorder `entry_note_abt_wf` is gated separately through
# `STUB_DEFINES` in `src/entry/build_entry.sh`. OFF (FLUSH_WITNESS unset or 0) the `#if` excludes every
# probe, so this object is the tree's ORIGINAL bytes - the define IS the patch.
#
# **A `--wrap=pmap_flush_tlbs` WOULD BE A HOOK THAT CANNOT FIRE** (`mi4-hooks-live-at-calls`), which is
# why this one is a source edit: MEASURED on this object, all 13 `R_ARM_CALL pmap_flush_tlbs`
# relocations are INTRA-object (11 caller functions, every one of them in `pmap.c`), so a wrap would
# redirect zero of the calls the storm rides.
[[ ${STAGE90_XNU_FLUSH_WITNESS:-0} -eq 1 ]] && DEFINES+=(-DSTAGE90_XNU_FLUSH_WITNESS=1)

# 992's iOS 7 commpage alias (`osfmk/arm/pmap.c` + `osfmk/arm/commpage/commpage.c`: the six dormant
# IOS7LAB board gates open, so `pmap_create_sharedpage` maps the commpage page a second time at
# 0xFFFF4000 - user read-only, XN - and `commpage_populate` fills the iOS 7 count bytes at
# `_COMM_PAGE_BASE_ADDRESS+0x34..0x36`). 991's press reached userspace: launchd EXECUTED (dyld ran
# from the mapped shared cache) and then aborted 231x at `0xffff4090` - translation fault - the
# address the real iOS 7 dyld reads the commpage at. Both files are kernel-pool files, so the switch
# goes to the SAME array as the kext guard / alignment / memq_hint switches, not to `EXTRA_DEFINES`
# (`tools/stage_d13_commpage_alias.sh`).
[[ ${STAGE90_XNU_COMMPAGE_ALIAS:-0} -eq 1 ]] && DEFINES+=(-DSTAGE90_XNU_COMMPAGE_ALIAS=1)

# 994's iOS 7 VM wire width + timebase (`osfmk/ipc/mach_kernelrpc.c` + `osfmk/arm/ios7_compat.h`: the
# three `_kernelrpc_*` VM trap bodies (10/12/14) route through their real-width iOS 7 wire adapters
# (5/5/7 words) when the narrow `ios7_traps_enabled()` selector answers 1, so trap-10's `args->flags`
# reads the FIFTH word instead of the size's high half - the 4-word
# read of a 5-word wire that makes dyld's `__simple_salloc` `vm_allocate` look like a failure
# (`syscall_sw.c` needs NO edit: traps 10/12/14 already carry arg counts 5/5/7 and on `__arm__` the
# mungers are ignored; traps 15/24/25/41/42 stay `kern_invalid`); and
# `osfmk/arm/traps_lo.s`'s `r12 == -3` SWI returns the real 64-bit timebase instead of the silent
# `movs pc, lr`). 993's press reached dyld's own deliberate halt: `dyld::halt` -> `_dyld_fatal_error`
# (`udf #0xdefe` at pc 0x2be7e0c4, slide 0x7d000), thrown by `dyld::throwf`'s out-of-memory path after
# that `vm_allocate`. The C files are kernel-pool files, so the switch goes to the SAME array as the
# kext guard / alignment / memq_hint / commpage switches, not to `EXTRA_DEFINES`. The `.s` half is an
# ASSEMBLY-layer file - its `-D` rides `tools/assemble_arm_layer.sh`'s ASFLAGS instead - and the two
# spellings must carry the SAME value (`mi4-one-value-two-definitions`).
[[ ${STAGE90_XNU_IOS7_TRAPS:-0} -eq 1 ]] && DEFINES+=(-DSTAGE90_XNU_IOS7_TRAPS=1)

# 995's dyld halt-message witness (`osfmk/arm/trap.c`: `ios7wit_dyld_message` reads the message dyld
# recorded before executing its fatal `udf #0xdefe` - the word at `task->all_image_info_addr + 0x20`
# is dyld's `setAlImageInfosHalt`-written message pointer, and `copyin`/`copyinstr` bring it out,
# fail-soft and print-bounded to two slots). 994's press confirmed the trap-10 wire fix and then
# halted at dyld's own deliberate trap with a message NOTHING in this kernel can print: the tree's
# own reader (the LEO witness) is compiled out on CANCRO. `trap.c` is a kernel-pool file, so the
# switch goes to the SAME array as the kext guard / alignment / memq_hint / commpage / trap-wire
# switches, not to `EXTRA_DEFINES` - and the linked image only LINKS
# `out/xnu_kernel_obj_d13/osfmk_arm_trap.o`, so without this `-D` the witness is silently absent
# (`tools/stage_d13_dyld_witness.sh` stages the tree; its gate is `defined()`-first, so switch OFF
# compiles trap.c's original bytes).
[[ ${STAGE90_XNU_DYLD_WITNESS:-0} -eq 1 ]] && DEFINES+=(-DSTAGE90_XNU_DYLD_WITNESS=1)

# 1020's undefined-instruction RAISE (`osfmk/arm/trap.c`: `sleh_undef`'s user-mode arm moves its
# `return;` INSIDE the `if (!thread->machine.vfp_enable)` block, so a genuine `udf` with VFP already
# enabled falls through to the printf + `EXC_BAD_INSTRUCTION` instead of returning with the PC still on
# the `udf` and re-trapping forever). The defect is `records/1019-rootcause.txt`: pid 1's `udf #254`
# at `__os_alloc_slow+0x108` looped 8183x in USER mode because the tree classifies EVERY undefined
# instruction as a lazy VFP/NEON enable and returns without advancing PC; the port's own LEO machinery
# (`ios7leo_dyld_repeat`, `trap.c:105`) already assumes the two-trip shape this switch restores.
# `trap.c` is a kernel-pool file, so the switch goes to the SAME array as the kext guard / alignment /
# witness / wire switches, not to `EXTRA_DEFINES` - and the linked image only LINKS
# `out/xnu_kernel_obj_d13/osfmk_arm_trap.o`, so without this `-D` the raise is silently absent
# (`tools/stage_d13_undef_raise.sh` stages the tree; its gate is `defined()`-first, so switch OFF
# compiles trap.c's original bytes).
[[ ${STAGE90_XNU_UNDEF_RAISE:-0} -eq 1 ]] && DEFINES+=(-DSTAGE90_XNU_UNDEF_RAISE=1)

# 996's shared-region syscall probe (`bsd/vm/vm_unix.c`: bounded, fail-soft `IOS7SHREG` lines at the
# entry and every return of `shared_region_check_np` (294) and `shared_region_map_and_slide_np` (438),
# plus the kr immediately after `vm_shared_region_map_file()` inside `_shared_region_map`). 995's press
# read dyld's real halt message by measurement (`Library not loaded: /usr/lib/libbsm.0.dylib` - launchd's
# FIRST LC_LOAD_DYLIB, no file on the volume but present in the shared cache), so the frontier is WHY
# the cache lookup missed; the leading hypothesis is that `mapSharedCache` failed silently and every
# cached dylib degraded to a file lookup. dyld's two entry points are BSD syscalls 294/438, BOTH wired
# in this tree (`init_sysent.c:440/:649`), so only the RUNTIME returns are unknown - and they are what
# this probe measures (it changes no behaviour). `vm_unix.c` is a kernel-pool file, so the switch goes
# to the SAME array as the kext guard / alignment / memq_hint / commpage / trap-wire / witness
# switches, not to `EXTRA_DEFINES` - and the linked image only LINKS
# `out/xnu_kernel_obj_d13/bsd_vm_vm_unix.o`, so without this `-D` the probe is silently absent
# (`tools/stage_d13_shreg_probe.sh` stages the tree; its gate is `defined()`-first, so switch OFF
# compiles vm_unix.c's original bytes).
[[ ${STAGE90_XNU_SHREG_PROBE:-0} -eq 1 ]] && DEFINES+=(-DSTAGE90_XNU_SHREG_PROBE=1)

# 997's shared-region WIRE WIDTH (`bsd/vm/vm_unix.c`: the tree's OWN 32 B `struct
# shared_file_mapping_np` branch behind `IOS7_COMPAT_PLATFORM`, opened by exactly three gate lines + a
# gated `ios7lab_cache_abi()` body - the per-mapping `IOS7LAB cache mapping ...` printf rides inside
# it). 996's press MEASURED the 20 B-vs-32 B misparse by value (`IOS7SHREG map_file kr=4` + `map_slide
# ret=22`: the 20 B struct read dyld's 32 B array at stride 20, m[0].size = 0, `vm_map_enter_mem_object`
# EINVAL), so this rung compiles the wire dyld 239 actually speaks. `vm_unix.c` is a kernel-pool file,
# so the switch goes to the SAME array as the kext guard / alignment / memq_hint / commpage / trap-wire /
# witness / probe switches, not to `EXTRA_DEFINES` - and the linked image only LINKS
# `out/xnu_kernel_obj_d13/bsd_vm_vm_unix.o`, so without this `-D` the wire is silently the old 20 B one
# (`tools/stage_d13_shreg_wire.sh` stages the tree; its gate spelling is `defined()`-first, so switch
# OFF compiles vm_unix.c's original bytes).
[[ ${STAGE90_XNU_SHREG_WIRE:-0} -eq 1 ]] && DEFINES+=(-DSTAGE90_XNU_SHREG_WIRE=1)

# 998's shared-region GEOMETRY + process stack top, ONE switch (G1): `osfmk/vm/vm_shared_region.c`'s
# own iOS 7 block (base 0x2C000000 / size 0x14000000, behind `#if IOS7_COMPAT_PLATFORM` + the runtime
# selector) and `osfmk/arm/status.c`'s stack half (ios7lab_user_stack() -> 0x2BE00000, so
# create_unix_stack's FIXED target clears the new window - audit section 2: without it EVERY process's
# stack relays out). 997's press MEASURED the geometry wall by value (the four `IOS7LAB cache mapping`
# lines print with already-slid addresses, then `map_file kr=1` + `map_slide ret=14`: the default
# 0x30000000/0x10000000 window cannot hold dyld's slid shared cache). Both files are kernel-pool files,
# so the switch goes to the SAME array as the wire / probe / witness switches, not to `EXTRA_DEFINES` -
# and the linked image only LINKS `out/xnu_kernel_obj_d13/osfmk_vm_vm_shared_region.o` +
# `osfmk_arm_status.o`, so without this `-D` the linked geometry is silently the default one
# (`tools/stage_d13_shreg_geom.sh` stages the three tree files; the 1:1 gate spelling is
# `defined()`-first, so switch OFF compiles each file's original bytes with no line moved).
[[ ${STAGE90_XNU_SHREG_GEOM:-0} -eq 1 ]] && DEFINES+=(-DSTAGE90_XNU_SHREG_GEOM=1)

# 1024's USER-MAP CEILING (`osfmk/mach/arm/vm_param.h:63`: the split-consistent branch's condition
# gains ` || (defined(STAGE90_XNU_VM_MAX_SPLIT) && STAGE90_XNU_VM_MAX_SPLIT)`, so `-DSTAGE90_XNU_VM_MAX_SPLIT=1`
# makes `VM_MAX_ADDRESS = 0x40000000` on CANCRO instead of this tree's `#else` 0x80000000).  1023's press
# moved the wall - trap 24 dispatches and `mach_port_construct` returns 0 - and pid 1 then died in a
# ~2^20-iteration DATA-ABORT LOOP on `_pthread_create+0xbc` at user VA 0x40083008: `set_mmu_ttbcr(2)`
# (`arm_vm_init.c:475`) gives TTBR0 exactly 1 GiB, so the first big anywhere-allocation in launchd was
# placed where the hardware walks TTBR1 (the KERNEL's tree) and `vm_fault` installed a PTE nothing reads.
#
# WHY THE GLOBAL ARRAY AND NOT `EXTRA_DEFINES`.  `vm_param.h` is a HEADER, included by every kernel
# translation unit that bounds a user map (`task.c`'s `task_create_internal`, vm_map.c, mach_vm.c, ...),
# so the switch has to be in the argv EVERY compile line carries.  `EXTRA_DEFINES` (`XNU_KERNEL_EXTRA_DEFINES`,
# ~:1399) is appended LAST and is NOT seen by the EABI-runtime block (~:1796) or the firehose block
# (~:1838) - a build that put it there would compile those extra TUs with the OLD ceiling while every
# other object carried the new one, a partial fix behind a green build (`mi4-one-value-two-definitions`).
# Not an ASFLAGS entry either: the whole VM_MAX_ADDRESS block sits inside `#ifndef __ASSEMBLER__`, so
# the assembly layer is unaffected.  `tools/build_xnu_arm_kernel.sh` is run separately from
# `build_entry.sh` (which only LINKS the pool objects), so without the re-run of THIS script the linked
# image keeps 0x80000000 and the patch is invisible (`records/1020-build-defect.txt`).  The tree edit is
# staged by `tools/stage_d13_vm_max_split.sh`; OFF the `#if` compiles the tree's original bytes
# (`defined()` comes first), and the LINKED-image by-value clause is `tools/check_vm_max_split.py`.
[[ ${STAGE90_XNU_VM_MAX_SPLIT:-0} -eq 1 ]] && DEFINES+=(-DSTAGE90_XNU_VM_MAX_SPLIT=1)

# ---------------------------------------------------------------------------------------------------
# 1025: STAGE90_XNU_USTACK_PROBE -- publish what `vm_fault` RETURNED, and the stack's shape.
#
# The 1024 boot reached `launchd[1] has started up`, spawned pid 2 `launchctl`, and died in a USERSPACE
# DATA ABORT on a STACK VA: `launchctl[2]: usermode data abort, EXC_BAD_ACCESS at 0x2bdbe000
# (Translation fault on page)` (records/1024b-frontier-launchctl-crash.txt; arm identity settled in
# records/1025-globalfix-carrier.txt section 6 - it IS the 1024-shaped arm, so GLOBAL_FIX is already in
# it and did NOT retire this fault).  0x2bdbe000 is INSIDE the fixed stack window [0x2BD00000,
# 0x2BE00000) `create_unix_stack` allocates, and `sp=0x2bdbd074` shows the FIXED allocation SUCCEEDED
# (no ANYWHERE fallback) - so a page that should be mapped is TRANSLATION-faulting (by value:
# records/1025-source-trace.txt sections 3-4).  In `osfmk/arm/trap.c` the usermode data-abort path CALLS
# `vm_fault` and, on a non-SUCCESS return, delivers `EXC_BAD_ACCESS`; the ONE assignment of the return
# code sits inside `#if BOARD_CONFIG_QSD8250_LEO`, so on CANCRO the value that NAMES the cause is
# DISCARDED.  This switch compiles in two guarded publishers (staged by tools/stage_d13_ustack_probe.sh):
#   * trap.c          -> `xnu_live_abt_vmfkrv*` (the `vm_fault` return + far/dfsr/prot/pc/sp/pid)
#   * kern_exec.c     -> `xnu_live_ustack_*`   (the stack's req/size/fixed_addr/rc/final/guard)
#
# WHY THE GLOBAL ARRAY AND NOT `EXTRA_DEFINES`.  Both files are POOL TUs, but the switch must be visible
# on the SAME argv every object gets, so the two guarded `#if`s compile in; `EXTRA_DEFINES`
# (`XNU_KERNEL_EXTRA_DEFINES`, ~:1399) is appended LAST and is NOT seen by the EABI-runtime block
# (~:1796) or the firehose block (~:1838).  `tools/build_xnu_arm_kernel.sh` is run separately from
# `build_entry.sh` (which only LINKS the pool objects), so without the re-run of THIS script the linked
# image keeps the old trap.o/kern_exec.o and the probe keys never appear (`records/1020-build-defect.txt`).
# OFF the two `#if`s compile the tree's original bytes (`defined()` comes first,
# [[mi4-off-option-two-spellings]]); the by-value reading of whether the switch reached the objects is
# the presence of the `xnu_live_abt_vmfkrv=` / `xnu_live_ustack_req=` format strings in the .o
# (tools/check_1025_capture.py reads the CAPTURE; the build-side object check is a `strings` refuse in
# build_1025.sh).
[[ ${STAGE90_XNU_USTACK_PROBE:-0} -eq 1 ]] && DEFINES+=(-DSTAGE90_XNU_USTACK_PROBE=1)

# ---------------------------------------------------------------------------------------------------
# 1026: STAGE90_XNU_ABT_ENTRY_PROBE -- name WHY the launchctl stack VA has no vm_map entry (H1 wrong map
# vs H2 off-the-end), by value, on the kernel's ram console.
#
# 1025's press recovered its own console (records/1025-press-read.txt): the discarded `vm_fault` return
# is `code=1` = KERN_INVALID_ADDRESS on `far=0x2bd35000` (the EXCLUSIVE TOP of launchctl's
# [0x2bc35000, 0x2bd35000)), `dfsr=0x807`, `prot=write`, `sp=0x2bd34074`, `pc=0x3b4ce756`, `pid=2`.
# KERN_INVALID_ADDRESS means `vm_map_lookup_entry(map, VA)` returned FALSE.  1026 publishes, for the
# failing fault only, the lookups that DISCRIMINATE the two candidate causes (docs/1026-design.md 3-4):
#   * trap.c       -> `xnu_live_abt_lookup_far/entry_lo/entry_hi/far_in_map/map/taskmap/ustack`
#                     (NESTED inside 1025's `#if STAGE90_XNU_USTACK_PROBE` publisher block - ONE gate on
#                     the shared fault path, so 1026 prints nothing unless BOTH switches are on);
#   * kern_exec.c  -> `xnu_live_abt_proc_ustack`, the `p->user_stack` accessor trap.c calls (`struct
#                     proc` is only FOWARD-declared in trap.c, so the FIELD is unreadable there).
#
# WHY THE GLOBAL ARRAY AND NOT `EXTRA_DEFINES`.  Same reason as the 1024 ceiling and the 1025 probe: the
# switch must be on the SAME argv every pool object gets, and `EXTRA_DEFINES`
# (`XNU_KERNEL_EXTRA_DEFINES`, ~:1399) is appended LAST and is NOT seen by the EABI-runtime block
# (~:1796) or the firehose block (~:1838).  `tools/build_xnu_arm_kernel.sh` is run separately from
# `build_entry.sh` (which only LINKS the pool objects), so without the re-run of THIS script the linked
# image keeps the old trap.o/kern_exec.o and the keys never appear (records/1020-build-defect.txt).
# OFF the two `#if`s compile the tree's original bytes (`defined()` comes first,
# [[mi4-off-option-two-spellings]]); the by-value reading of whether the switch reached the objects is
# the format string / symbol in the .o (build_1026.sh refuses on its absence).
[[ ${STAGE90_XNU_ABT_ENTRY_PROBE:-0} -eq 1 ]] && DEFINES+=(-DSTAGE90_XNU_ABT_ENTRY_PROBE=1)

# ---------------------------------------------------------------------------------------------------
# 1029: STAGE90_XNU_READER_PROBE -- name WHO re-faults the user stack AFTER 1028's fix, by value, on the
# kernel's ram console (docs/1029-design.md 3.1/3.3).
#
# 1028's press read FIX-NOOP: the fault MOVED with the region by 0x1000, so the region was not the last
# word and H2 is refuted.  1029 publishes, for the failing fault only, the reader's identity and the
# derivation distance:
#   * trap.c       -> `xnu_live_rdr_far/far_minus_ustack/...` (NESTED inside 1025's
#                     `#if STAGE90_XNU_USTACK_PROBE` publisher block - ONE gate on the shared fault path,
#                     so 1029 prints nothing unless BOTH switches are on);
#   * kern_exec.c  -> `xnu_live_rdr_proc_argslen` / `xnu_live_rdr_proc_argc`, the accessors trap.c calls
#                     (`struct proc` is only FOWARD-declared in trap.c, so the FIELDS are unreadable
#                     there).
#
# WHY THE GLOBAL ARRAY AND NOT `EXTRA_DEFINES`.  Same reason as the 1024 ceiling and the 1025/1026
# probes: the switch must be on the SAME argv every pool object gets, and `EXTRA_DEFINES`
# (`XNU_KERNEL_EXTRA_DEFINES`, ~:1399) is appended LAST and is NOT seen by the EABI-runtime block
# (~:1796) or the firehose block (~:1838).  `tools/build_xnu_arm_kernel.sh` is run separately from
# `build_entry.sh` (which only LINKS the pool objects), so without the re-run of THIS script the linked
# image keeps the old trap.o/kern_exec.o and the keys never appear (records/1020-build-defect.txt).
# OFF the two `#if`s compile the tree's original bytes (`defined()` comes first,
# [[mi4-off-option-two-spellings]]); the by-value reading of whether the switch reached the objects is
# the format string / symbol in the .o (build_1029.sh refuses on its absence; the link-site clause in
# build_entry.sh refuses too).
[[ ${STAGE90_XNU_READER_PROBE:-0} -eq 1 ]] && DEFINES+=(-DSTAGE90_XNU_READER_PROBE=1)

# ---------------------------------------------------------------------------------------------------
# 1030: STAGE90_XNU_WRITER_PROBE -- name the WRITER's derivation of r4, by value, on the kernel's ram
# console (docs/1030-design.md 0b/1, records/1030-audit.txt).
#
# 1030 was designed as a region-extent fix and REFUTED BEFORE BUILD: base-down and extent-up CANCEL
# (size is already page-aligned, so the exclusive top is unchanged), and across all 60 captures
# `far == the region's EXCLUSIVE TOP` in every run -- raising the top raises `far` (1028, page-exact),
# lowering it lowers `far`. NO allocation-geometry change can help.  So 1030 is a PROBE of the writer,
# not a fix: libobjc+0x14756's `str.w r2,[r4],#4` faults with `r4 = r6 = far`, and this switch makes the
# data-abort arm publish the values that separate W-A (r4 = sp + const, a compile-time frame offset --
# the initial stack is too shallow), W-B (r4 derived from a saved region top -- a stack-limit store) and
# W-C (r4 from a shared-cache/objc structure -- an undersized userspace buffer).  Pre-registered cells:
# W-A-NAMED / W-B-NAMED / W-OTHER; if the rows are absent it is W-OTHER-missing, never a negative.
#
# WHY THE GLOBAL ARRAY AND NOT `EXTRA_DEFINES`.  Same reason as the 1024 ceiling and the
# 1025/1026/1028/1029 switches: the switch must be on the SAME argv every pool object gets, and
# `EXTRA_DEFINES` (`XNU_KERNEL_EXTRA_DEFINES`, ~:1399) is appended LAST and is NOT seen by the
# EABI-runtime block (~:1796) or the firehose block (~:1838).  `tools/build_xnu_arm_kernel.sh` is run
# separately from `build_entry.sh` (which only LINKS the pool objects), so without the re-run of THIS
# script the linked image keeps the old trap.o and the probe prints nothing (records/1020-build-defect.txt).
# OFF the `#if` compiles the tree's original bytes (`defined()` comes first,
# [[mi4-off-option-two-spellings]]); the by-value reading of whether the switch reached the object is the
# format string the compiler materialized for the probe key in trap.o (build_1030.sh refuses on its
# absence; the link-site clause in build_entry.sh refuses too).
[[ ${STAGE90_XNU_WRITER_PROBE:-0} -eq 1 ]] && DEFINES+=(-DSTAGE90_XNU_WRITER_PROBE=1)

# ---------------------------------------------------------------------------------------------------
# 1031: STAGE90_XNU_CALLER_PROBE -- READ THE CALLER (its registers at the fault) AND PRINT the stack
# region's EXCLUSIVE TOP by value (docs/1031-design.md 2).
#
# 1030 read the writer's cursor `r4 == far == the region's exclusive top`, but the writer's prologue
# (`add r7,sp,#12`) shows the boundary decision is the CALLER's, and 1030 could not see the caller frame.
# 1031 publishes the caller's registers (r0/r1/r2/r3/r9/r10/r7/lr/pc), the writer's fp self-check
# (`r7 - sp`, must be 0xC), and -- the crux -- the covering vm_map entry's `vme_end` for `far - 4`, which
# IS the region's exclusive top when `far` is the top.  Pre-registered cells: CAL-CALLER-TOP /
# CAL-CALLER-SIZE / CAL-CALLER-OTHER / CAL-MISSING; absent rows are CAL-MISSING, never a negative.
#
# WHY THE GLOBAL ARRAY AND NOT `EXTRA_DEFINES`.  Same reason as the 1024 ceiling and the
# 1025/1026/1028/1029/1030 switches: the switch must be on the SAME argv every pool object gets, and
# `EXTRA_DEFINES` (`XNU_KERNEL_EXTRA_DEFINES`, ~:1399) is appended LAST and is NOT seen by the
# EABI-runtime block (~:1796) or the firehose block (~:1838).  `tools/build_xnu_arm_kernel.sh` is run
# separately from `build_entry.sh` (which only LINKS the pool objects), so without the re-run of THIS
# script the linked image keeps the old trap.o and the probe prints nothing (records/1020-build-defect.txt).
# OFF the `#if` compiles the tree's original bytes (`defined()` comes first,
# [[mi4-off-option-two-spellings]]); the by-value reading of whether the switch reached the object is the
# format string the compiler materialized for the probe key in trap.o (build_1031.sh refuses on its
# absence; the link-site clause in build_entry.sh refuses too).
[[ ${STAGE90_XNU_CALLER_PROBE:-0} -eq 1 ]] && DEFINES+=(-DSTAGE90_XNU_CALLER_PROBE=1)

# ---------------------------------------------------------------------------------------------------
# 1033: STAGE90_XNU_EVAL_FRAME -- publish the 1032 frame by value (docs/1033-design.md 2).
#
# 1032 (FIX-PARTIAL) removed the 1030 stack-end write and the boot now ends in launchctl[2] usermode
# data abort EXC_BAD_ACCESS at 0x10 (dfsr type 7).  1025's row prints `vm_map_trunc_page(dfar)`, which is
# 0 for dfar 0x10, and cannot tell a NULL deref from a truncated page-zero write -- so this switch adds a
# trap.c block that prints the RAW DFAR, the frame (pc/lr/sp/cpsr), pc-far, and the words at far and
# sp+0x10 read with copyin only (+ their copyin results).  Pre-registered cells: EVF-U1-TRUE /
# EVF-U1-SUSPECT / EVF-U2-SLIDE0 / EVF-U2-MISTAKE / EVF-FAR0 / EVF-NOPLANE / EVF-MISSING / EVF-PANIC.
#
# WHY THE GLOBAL ARRAY AND NOT `EXTRA_DEFINES`.  Same reason as 1024-1031 above: the switch must be on
# the SAME argv every pool object gets.  **The carrier was ABSENT while build_1033.sh exported the env
# variable**, so the pool compiled trap.c without the block and step 4 reported "pool objects carry no
# evf row" (the [[mi4-build-variant-comes-from-an-env-default]] shape: an env switch with no reader).
# OFF the `#if` compiles the tree's original bytes (`defined()` comes first,
# [[mi4-off-option-two-spellings]]); the by-value reading is the format string `xnu_live_evf_pc=` in
# trap.o (build_1033.sh and park_1033.sh refuse on its absence).
[[ ${STAGE90_XNU_EVAL_FRAME:-0} -eq 1 ]] && DEFINES+=(-DSTAGE90_XNU_EVAL_FRAME=1)

# ---------------------------------------------------------------------------------------------------
# 1035: STAGE90_XNU_PC_CARRIER -- read the DEVICE's page content at the faulting pc (records/1035-
# carrier-by-pc-read.txt).  INSTRUMENT ONLY.  1033's pc 0x3819d474 and far 0x10 are the CPU's own
# registers; what is open is WHICH bytes the device executed there (the host's file at pc-0x577000
# is the libobjc walk, at pc itself the SAME bytes then decode as a small-integer table --
# records/1034-design-errata.txt E12).  The switch adds a trap.c block (owned by
# tools/patch_d13_pc_carrier.py) that copyin's the words around pc from the task map and prints
# their XOR against the host's file words for BOTH candidates: a zero XOR is the whole reading.
# Same GLOBAL ARRAY channel as every probe above (one argv for every pool object).  OFF compiles the
# tree's bytes; the by-value reading is the format string `xnu_live_pcc_pc=` in trap.o.
[[ ${STAGE90_XNU_PC_CARRIER:-0} -eq 1 ]] && DEFINES+=(-DSTAGE90_XNU_PC_CARRIER=1)

# 1036: STAGE90_XNU_PC_CARRIER_CALLER -- trace who enters the getPreoptimizedClass walk with r5=-1
# (records/1036-static-caller.txt).  INSTRUMENT ONLY.  1035 read the pc-0x20 word and found it
# modulated (device 0xebad46a5 vs the file's `bl`), so the walk's caller is still unknown; this
# switch adds a caller-side block (owned by the 1036 patcher) that records the caller's lr/sp/pc.
# Same GLOBAL ARRAY channel as every probe above (one argv for every pool object).  OFF compiles the
# tree's bytes; the by-value reading is the 1036 block's format string in trap.o.
[[ ${STAGE90_XNU_PC_CARRIER_CALLER:-0} -eq 1 ]] && DEFINES+=(-DSTAGE90_XNU_PC_CARRIER_CALLER=1)

# 1037: STAGE90_XNU_TRAP_FRAME -- compare the trap frame with the task map's own copy of the uss
# (docs/1037-design.md).  INSTRUMENT ONLY.  1036 read an lr and an r10 with bit0 set on a path whose
# every function is ARM, so the trap entry stores some register at the wrong offset; this switch adds a
# block (owned by the 1037 patcher) that prints the trap-frame registers beside the uss copy read
# through the task map, the near words, and a slide derived from lr alone.  [name note: the design
# doc's section 2 names this switch STAGE90_XNU_FRAME_BLOCK; the registration uses TRAP_FRAME.]
# Same GLOBAL ARRAY channel as every probe above (one argv for every pool object).  OFF compiles the
# tree's bytes; the by-value reading is the 1037 block's format string in trap.o.
[[ ${STAGE90_XNU_TRAP_FRAME:-0} -eq 1 ]] && DEFINES+=(-DSTAGE90_XNU_TRAP_FRAME=1)

# 1038: STAGE90_XNU_WATCH_LE -- blocks A (who wrote the stack) and B (little endian at the table)
# (docs/1038-design.md sections 1-2).  INSTRUMENT ONLY.  Adds a block (owned by the 1038 patcher) to the
# same trap.c publisher: block A reads the sixteen words at sp-4 through the task map beside the trap
# frame, block B reads the count word at r3+0xc through a byte accessor and assembles it little-endian.
# Same GLOBAL ARRAY channel as every probe above (one argv for every pool object).  OFF compiles the
# tree's bytes; the by-value reading is the block's xnu_live_sweq_s0..s15 / xnu_live_ler_cnt_b literals
# in trap.o (entry's 1038 link-site clause).
# (2026-10-19: the rows travel in the tree's own arm, so no `-include` of a switch-define stand-in is
# needed -- the one that forced the macro ON for every trap.c compile is retired here, see build_1039.)
# **A switch that is OFF is DEFINED to 0, not left undefined.** `watch_le_switch.inc` - the file
# `#include`d inside the hook, because the defs file that declares the statics lives 600 lines below -
# carries `#ifndef STAGE90_XNU_WATCH_LE / #define ... 1 / #endif`. With the switch simply absent from
# argv, that guard fires and defines it to 1, so a rung that RECORDS the arm as off (1039 does:
# STAGE90_XNU_WATCH_LE=0) still compiled 1038's rows - and every symbol they touch came up
# "use of undeclared identifier", 283 errors and no trap.o. Passing the 0 explicitly is what makes
# the record and the compilation agree.
if [[ ${STAGE90_XNU_WATCH_LE:-0} -eq 1 ]]; then
  DEFINES+=(-DSTAGE90_XNU_WATCH_LE=1)
else
  DEFINES+=(-DSTAGE90_XNU_WATCH_LE=0)
fi
# 1039: STAGE90_XNU_FRAME_CARRIER -- the frame carrier (records/1037-read.txt RUNG READING
# 2-3).  INSTRUMENT ONLY.  Adds a block (owned by the 1039 patcher) inside 1025's data-abort
# publisher that reads thread->machine.uss through its pointer/task map (not through arm_ctx),
# TH_PCB_ISS, the entry's saved spsr, thread->continuation and the pc/lr bit0.
# Same GLOBAL ARRAY channel as every probe above.  OFF compiles the 1038 tree's bytes.
[[ ${STAGE90_XNU_FRAME_CARRIER:-0} -eq 1 ]] && DEFINES+=(-DSTAGE90_XNU_FRAME_CARRIER=1)

# 1028: STAGE90_XNU_H2_STACK_HEADROOM -- the H2 FIX (docs/1028-design.md).  1027 read H2 (off-the-end):
# the user-stack region's exclusive top IS p->user_stack, and the initial argv/env block's top is ALSO
# p->user_stack, so the word at the top is unowned and userspace's touch faults.  This switch makes the
# FIXED mach_vm_allocate in create_unix_stack (bsd/kern/kern_exec.c) allocate `size + 16`, moving the
# region's exclusive top to user_stack+16 while the block, sp, p->user_stack, and the guard are
# unchanged.  Its channel is the GLOBAL DEFINES array (every compile line, incl. the EABI-runtime and
# firehose blocks that do NOT get EXTRA_DEFINES -- records/1020-build-defect.txt).  OFF takes the #else
# arm, which is the ORIGINAL call byte-for-byte ([[mi4-off-option-two-spellings]]); the by-value reading
# of whether the switch reached the object is the `size + 16` immediate in create_unix_stack's
# mach_vm_allocate (build_1028.sh refuses on its absence).
[[ ${STAGE90_XNU_H2_STACK_HEADROOM:-0} -eq 1 ]] && DEFINES+=(-DSTAGE90_XNU_H2_STACK_HEADROOM=1)

# Generated headers that are not MIG output: bsd/sys/sysproto.h comes from
# bsd/kern/makesyscalls.sh, and it is included by 55 of the failing files. Produced by
# tools/gen_bsd_headers.sh, and placed first so it wins over anything stale.  (`$GENERATED` is
# defined at the top, because the manifest needs it too - see there.)
# Per configuration: see tools/gen_option_headers.py. RELEASE and STAGE90_BOOT disagree on 20 of
# these macros, so one shared directory silently gives whichever build was generated last its own
# values - which is what happened, and it surfaced as a duplicate-symbol error in the link.
OPTION_HEADERS=$XNU_OPTION_HEADERS_OUT/$CONFIG
LIBSA_EXPORT=${XNU_LIBSA_EXPORT:-$REPO_ROOT/out/xnu_libsa_export}
# The third generator: `device`/`pseudo-device` headers from config(8) - `loop.h`, `pty.h`,
# `ptmx.h`, `bpfilter.h`.
DEVICE_HEADERS=$XNU_DEVICE_HEADERS_OUT/$CONFIG
[[ -d $OPTION_HEADERS ]] || {
    echo "no option headers for $CONFIG at $OPTION_HEADERS - run:" >&2
    echo "  XNU_KERNEL_CONFIG=$CONFIG ./tools/gen_option_headers.py" >&2
    echo "  (the other configuration's directory must not be used: they disagree on 20 macros)" >&2
    exit 2
}
# ------------------------------------------------------------------------------------------------
# 438: which options a file sees is a property of its COMPONENT, and the boot's last stub was a
#      phantom of getting that wrong.
#
# 437's run stopped at `stub_hit=kmstartup`, caller key `0x8003B238` = `bsd_init + 0x848`. The walk
# says `bsd_init` has 232 calls and that is the only one still a stub, so the goal's bar was one
# function away - and that function turned out to be one no shipping configuration can define.
#
# `bsd_init.c:852` is `#ifdef GPROF` around `kmstartup();`, and `GPROF` is declared by **libkern**:
# `libkern/conf/files:5` is `OPTIONS/gprof optional gprof`, so `tools/gen_option_headers.py` wrote
# `gprof.h` with `#define GPROF 0` and the FLAT `meta_features.h` force-included it into **every**
# translation unit. `#define GPROF 0` is not "off" to `#ifdef`; it is *defined*. So a BSD file called
# a profiler entry point. Its only definer is `bsd/kern/subr_prof.c` - `standard` in
# `bsd/conf/files:430`, so always compiled - and that file cannot compile: between
# `#ifdef GPROF` (line 83) and `#endif /* GPROF */` (line 339) it uses the macro `STATIC` at line 160,
# which nothing it includes defines. The two facts are the same fact. The body must be dead in every
# build that ships, which means the call must be dead too - and it was not, because this build
# aggregated all eight components' options into one header.
#
# That is not a fudge this project invented: `mkheaders.c` writes each OPTIONS header into the object
# directory of the `conf/files` that declared it, and `MakeInc.def:466` puts **that** directory first
# (`INCFLAGS_LOCAL = -I.`, with `-I$(OBJROOT)/EXPORT_HDRS/$(COMPONENT)` beside it) - so a component
# sees its own options and no others. `scan_options()`'s comment asserted the membership did not
# matter because "the value is the same whichever component declared it", and the value is; the
# membership is not. See `mi4-generator-output-kinds` and `mi4-a-claim-in-a-comment-is-not-a-check`.
#
# **The membership rule alone is not enough, and the measurement is the reason.** Scanning every
# manifest source and all 1411 component headers for `#ifdef`/`#ifndef`/`defined()` reads of an
# option macro finds exactly TWO cross-component reads in the whole tree:
#
#     GPROF        declared by libkern, read by bsd/kern/{bsd_init,kern_clock,subr_prof,subr_xxx}.c
#                  and bsd/sys/gmon.h - the profiler, and every one of those blocks is DEAD when the
#                  option is off. Not shared: bsd simply stops seeing it, which is the only reading
#                  under which Apple's own subr_prof.c compiles. `nm` over all 695 objects finds no
#                  reference to `mcount`, `_gmonparam` or `cfreemem`; `kmstartup` is referenced only
#                  by the call this step removes.
#     CONFIG_MACF  declared by bsd and security, read by osfmk - `osfmk/kern/task.h:241` guards a
#                  `struct task` field with `#ifdef CONFIG_MACF` and `task.c` guards the same
#                  parameter with `#if CONFIG_MACF`. **Shared**: with the macro invisible to osfmk,
#                  `struct task` would have two layouts in one kernel, and the bsd and security code
#                  that allocates and reads it would use the other one. That is an ABI mismatch no
#                  compiler can see, so the shared list keeps the value it has always had.
#
# So the change is: `tools/gen_option_headers.py` writes `<component>/meta_features.h` as well as the
# flat one; this script puts the component's own directory ahead of the flat one for every manifest
# file; and `tools/check_option_headers.py` makes both halves structural - the slices against
# `conf/files`, and the reads against an explicit list (`SHARED` with a reason, or the inert ones
# with a reason; anything else stops the build). The four out-of-manifest translation units (the EABI
# runtime, firehose, the platform expert, the pthread and crypto tables) belong to no component and
# keep the flat header, which is what they were measured with.
#
# **Prediction, written before the build and before the run.**
#
#   * `tools/check_option_headers.py` passes for RELEASE and STAGE90_BOOT, and fails when a slice is
#     made to disagree (demonstrated while writing it: dropping `<gprof.h>` from libkern's slice
#     reported `libkern: missing gprof.h`; the include parser's first version reported five
#     components "missing" the header it had just written, because the shared entries carry a
#     trailing comment).
#   * pool: **695 objects -> 696, 3 failures -> 2.** `bsd_kern_subr_prof.o` is produced for the first
#     time; the two that remain are `bsd_net_if_bridge.c` and `osfmk_kperf/kperfbsd.c`, which this
#     step does not touch. `bsd/kern/subr_prof.c`'s body is inside `#ifdef GPROF`, so the object
#     defines nothing - `kmstartup`, `mcount`, `sysctl_doprof` and `_gmonparam` all vanish with it.
#   * `nm -u out/xnu_kernel_obj/bsd_kern_bsd_init.o` no longer lists `kmstartup`; `bsd_kern_subr_xxx.o`
#     loses `cfreemem`; nothing anywhere references any of them.
#   * **Every other object is byte-identical, and the reason is a property this step's whole design
#     rests on:** the only thing membership changes for a file is which option macros are *defined*.
#     `#if X` reads 0 either way, so only `#ifdef`/`#ifndef`/`defined()` can move - and those are the
#     two reads above, one inert and one held by the shared list. So the expected diff is exactly
#     four objects: `bsd_kern_bsd_init.o` (call gone), `bsd_kern_subr_xxx.o` (`cfreemem` gone),
#     `bsd_kern_subr_prof.o` (new), and `bsd_kern_kern_clock.o` (its `#ifdef GPROF` wraps an
#     `#include <sys/gmon.h>` and nothing else - identical is the prediction).
#   * entry image: the stub set **44 -> 43** (`kmstartup` is a name nothing references any more),
#     `.text` down by one stub body and one name slot - **0x24**, so 0x4B4AC0 -> 0x4B4A9C if no
#     boundary moves - and the layout rows shift by that and no more.
#   * the run: `bsd_init` runs past `+0x844`, and since 435 measured the rest of its statement list
#     real it **returns** - the first time this boot has left `bsd_init` - and the stop moves into
#     `kernel_bootstrap_thread`: `OSKextRemoveKextBootstrap`, `kdebug_free_early_buf`,
#     `serial_keyboard_init`, `vm_page_init_local_q`, `thread_bind`, `vm_pageout()`.
#
# Falsifiers, named in advance: (1) a stop that is still `kmstartup` - the narrowing did not reach
# `bsd_init.o`, which `nm -u` on the object decides in one line; (2) a new `data abort` naming a
# profiler-era symbol - the narrowing removed a definition something did need, and the symbol says
# which; (3) `bsd_init` still not returning, with the stop inside its own body - then "one stub left"
# was a statement about the pre-438 image and something else on that statement list depends on the
# GPROF path; (4) a `struct task` sized differently in two objects - what the shared list exists to
# prevent, and visible as a fault on a task pointer rather than as a compile error.
#
# ------------------------------- measured, 2026-09-19 --------------------------------------------
#
# **None of the four falsifiers fired, and two of the predictions were wrong in a way worth keeping.**
#
# The pool: **695 objects -> 696, 3 failures -> 2**, exactly as predicted, and `bsd_kern_subr_prof.o`
# is the new one. The byte comparison over all 695 before-hashes is the part that carries the design
# argument: **exactly two objects changed, `bsd_kern_bsd_init.o` and `bsd_kern_subr_xxx.o`, and the
# other 693 are byte-identical** - including `bsd_kern_kern_clock.o`, which the prediction called
# identical and which is the one whose `#ifdef GPROF` wraps an `#include <sys/gmon.h>` with nothing
# else in it. Two changed files out of 695 is what "membership only moves `#ifdef`" means when it is
# measured rather than argued.
#
# The two symbols the step was aiming at are both gone:
#
#     nm -u bsd_kern_bsd_init.o   U kmstartup   -> nothing
#     nm -u bsd_kern_subr_xxx.o   U cfreemem    -> nothing
#
# **Prediction miss (a), and it is the interesting one: the stub count went 44 -> 42, not 44 -> 43.**
# The prediction said the new `subr_prof.o` "defines nothing - `kmstartup`, `mcount`, `sysctl_doprof`
# and `_gmonparam` all vanish with it". That is wrong about the file, and the file says so: the
# preprocessor structure is `#ifdef GPROF` at 83, `#endif /* GPROF */` at 339, and `addupc_task` at
# line 370 is **outside it** (so are `PROFILE_LOCK`/`PROFILE_UNLOCK`/`PC_TO_INDEX` at 341-351).
# `subr_prof.c` is not the profiler; it is the profiler *plus* `addupc_task`, which `resourcevar.h:124`
# expands unguarded and `kern_clock.c:379` and `kern_sig.c:3346` call behind nothing but a runtime
# `P_PROFIL`/`P_OWEUPC` flag test. So `addupc_task` was a stub before this step - the closure needed it
# and nothing defined it - and the object that retires it is the one this step made compile:
#
#     nm out/stage90/xnu_arm_entry.elf   T addupc_task 0x8028bb7c
#
# Two stubs retired by one change, from two different directions: `kmstartup` because the caller
# stopped existing, `addupc_task` because the definer started existing. The reading to keep: **a file's
# name is not its `#ifdef` structure, and "an object defines nothing" is a claim about a line range
# that was never checked.** The '380 bytes' the new object carries is the measure of it.
#
# **Prediction miss (b): `.text` grew 0x4B4AC0 -> 0x4B4C00, +0x140, not -0x24.** Removing two stub
# bodies and their name slots is not what sets Δ`.text` - the new real `addupc_task` body more than
# pays for them - and the +0x40 then **changed nothing else at all**:
#
#     text size    4934656 (.text)      <- was 4934336: +0x140 = 0x4B4C00
#     image bytes  5141584              <- unmoved
#     .data        0x804B8000 (0x2E360) <- unmoved, address and size
#     .sysctl_set  0x804E6360 (0xFD8)   <- unmoved
#     .init_array  0x804E7338 (0x118)   <- unmoved
#     bss          0x804E7480 .. 0x805388F8 (332920)   <- unmoved
#     entry bin    sha256 2e7354519b9ecf81573be3729a068de3cf1afb0faa5df3dc9e41d9eb1d99250a
#
# The whole of the growth sat in the `.text` section's own alignment slack, so the image is the same
# 5141584 bytes with the same `.bss` boundary 48 bytes below its end - and the entry bin's hash still
# moved, which is the point: **equal size is not equal layout.** This is `mi4-linker-fill-term` from
# the other side: Δ`.text` was +0x40 and Δimage was 0.
#
# The closure went 423 -> 424 objects (`bsd_kern_subr_prof.o` joined it, since `addupc_task` is
# referenced from two files the closure already had). `copyin` and `copyout`, the new object's only
# unresolvable references, cost nothing because the image already defines both - `T copyin
# 0x8000d3e4`, `T copyout 0x8000d4cc` - and `proc_is64bit` and `stopprofclock` are in the pool. The
# 42 remaining stubs are the pre-437 set minus the two profiler entries, and the two *LLVM* profiler
# stubs are untouched by this step and stay (`__llvm_profile_get_size_for_buffer_internal`,
# `__llvm_profile_write_buffer_internal`) - a reminder that "the profiler" is two unrelated things in
# this tree and only one of them is GPROF.
#
# **Miss (c), the hardware run, and it is the one that names the next step.** The prediction said
# `bsd_init` would return and the stop would move into `kernel_bootstrap_thread`. It did not: the
# result line has **no `stub_hit=` field for the first time**, and a fault block 436 and 437 never
# printed:
#
#     real XNU entry: exception: prefetch abort
#     xnu_entry_prefetch_abort_ifar = 0xE52DE004     xnu_entry_prefetch_abort_ifsr = 0x00000005
#     xnu_entry_prefetch_abort_lr   = 0xE52DE008     xnu_entry_prefetch_abort_spsr = 0xA0000013
#     xnu_entry_prefetch_abort_ttbr0 = ttbr1 = 0x8070404A   ttbcr = 1   sctlr = 0x30C5787D
#     checks=5  failures=0  abort_entries=0  kv_dropped=0  kv_written = 0x226 -> 0x346
#
# `0x346 - 0x226 = 0x120 = 9 x 32`, exactly `fleh_prefabt`'s nine records and nothing else, so **no
# stub was hit on this run at all** - and the reason 437 printed *nothing* for those keys rather than
# zeros is that the handler writes them only when it runs.
#
# `0xE52DE004` is the ARM encoding of `push {lr}`, and `IFAR` and `LR_abt` are independent registers
# that agree on it, so the processor really was fetching from that address. It appears in the image
# as a code word in exactly 43 places - a search for the little-endian word, not a reading: 42 are
# the `push {lr}` of the 42 stub bodies (laid out in `xnu_arm_entry_undef.txt`'s order, 0x18 bytes
# apart, which is a second and independent measurement of the count) and the 43rd is the first
# instruction of `inv_shift_rows`. Every stub is
#
#     movw r0,#name  push {lr}  mov r1,lr  movt r0,#name  pop {lr}  b entry_stub_hit
#
# **and that is the whole stop.** `bsd_init.c:861` is `bsd_autoconf();`, inside `bsd_init` itself, and
# `bsd_autoconf` is `for (pi = pseudo_inits; pi->ps_func; pi++) (*pi->ps_func)(pi->ps_count);` over
# `struct pseudo_init { int ps_count; int (*ps_func)(int); }` - which `bsd/dev/busvar.h:46` declares
# **`extern struct pseudo_init pseudo_inits[]`**. The linked loop is `movw/movt r4,#0x80444e3c;
# ldr r1,[r4,#4]; beq exit; ldr r0,[r4]; blx r1; ldr r1,[r4,#12]; add r4,#8`, and at `0x80444e3c` -
# `pseudo_inits`, entry **28** of the alphabetical undefined list - the two words are `0xE3020928`
# (`movw r0, #0x2928`, read as `ps_count`) and **`0xE52DE004`** (`push {lr}`, read as `ps_func`).
#
# **`pseudo_inits` is supplied as a *function* stub where the header says the symbol is an *array of
# structs*.** The `0` that terminates the walk *is* the array's first `ps_func`, and this image put
# its own prologue there - so `pi->ps_func` is non-NULL, the `blx r1` at `bsd_autoconf+0x28` jumps to
# it, and the fault follows. `tools/xnu_entry_callwalk.py --root bsd_autoconf` says "reached no stub on
# the straight-line path ... indirect calls the walk could not follow: bsd_autoconf+0x28: blx r1" -
# **the walk's blindness and the device's fault are the same instruction.**
#
# **A third face of this instrument's symptom, and the first of its kind measured on hardware: the
# stop is not a missing symbol, not an invented zero and not a boot-arg string - it is a stand-in of
# the wrong *kind*.** The undefined list gives names and never kinds, so nothing host-side could have
# said the symbol was declared an array; the `nm` view (`T pseudo_inits`) is wrong only relative to
# `busvar.h:46`. The step that follows supplies it as the array, generated from the device table the
# way `mkioconf.c:79-100` generates it (one `{count, func}` per `PSEUDO_DEVICE` with a `d_init`,
# terminated by `{0,0}`), and the check that must stop the build is a kind check.
# ------------------------------------------------------------------------------------------------

# And the per-component slices, which the loop puts ahead of the flat header. Refused rather than
# fallen back on: the loop *does* fall back when a component has no slice, and for the one file in
# the manifest whose first path segment is not a component directory that is right. For the ones
# that are, a missing slice would silently hand the file the whole kernel's option set - which is
# the defect of experiment-438, whose effect was a boot that stopped on a symbol no shipping
# configuration can define. A fallback that reproduces the bug it was written to fix has to be a
# refusal, and this is the one place that can tell the two cases apart.
#
# The predicate is "declares options", read from the same `conf/files` the generator reads, rather
# than "is in COMPONENT_LIST" - which the first version of this check used and it fired on `san`,
# the one component with a `conf/files` and no `OPTIONS/` line. The measurement says the two agree
# about san and agree for a reason: its `conf/Makefile.template` is also the only one of the eight
# with no `-include meta_features.h`, so Apple's build gives san no option view either. A component
# that sees nothing has no slice to be missing from.
for _c in "${COMPONENT_LIST[@]}"; do
    grep -q '^OPTIONS/' "$XNU/$_c/conf/files" 2>/dev/null || continue
    [[ -f $OPTION_HEADERS/$_c/meta_features.h ]] && continue
    echo "no per-component option headers for $CONFIG at $OPTION_HEADERS/$_c/meta_features.h - run:" >&2
    echo "  XNU_KERNEL_CONFIG=$CONFIG ./tools/gen_option_headers.py" >&2
    exit 2
done
# Required for the same reason the option headers are, and it is worth spelling out why this check
# is not a formality: **a header that is missing from the include path is not an error here, it is
# the host's header**. `bsd/dev/arm/conf.c:111`'s `#include <pty.h>` with no `pty.h` anywhere on the
# path resolved to `/usr/include/pty.h` - the target is an ELF triple whose driver sysroot is `/`,
# so glibc's headers are reachable - and the file died in
# `features-time64.h:20: 'bits/wordsize.h' file not found`, naming neither XNU nor the header that
# was really absent. That is how a missing generated directory stayed invisible for as long as it
# did (experiment-166).
#
# **Experiment 440 turned this from a requirement into a check on an invariant.** The headers are
# written by `gen_device_headers.py` earlier in this script, so "does the directory exist" is no
# longer a question about the operator's last command; what can still be wrong is a *missing*
# directory (something deleted it between the two), which is what this catches.
[[ -n $(compgen -G "$DEVICE_HEADERS/*.h") ]] || {
    echo "no device headers for $CONFIG at $DEVICE_HEADERS - run:" >&2
    echo "  XNU_KERNEL_CONFIG=$CONFIG ./tools/gen_device_headers.py" >&2
    exit 2
}

# The component order is Apple's, from makedefs/MakeInc.def:46-48:
#
#   COMPONENT_LIST        = osfmk bsd libkern iokit pexpert libsa security san
#   COMPONENT_IMPORT_LIST = $(filter-out $(COMPONENT),$(COMPONENT_LIST))
#
# so a component sees its own tree first and then the others in that order. A single build cannot
# vary the order per file the way that mechanism does, so this uses the list's own order and the
# components' headers are mostly in disjoint namespaces (sys/, kern/, mach/, iokit/, pexpert/,
# security/, san/, libkern/), which keeps the approximation honest.
#
# `-I$XNU` is what makes <security/_label.h> and <san/kasan.h> resolve. Both exist in the tarball
# and two hand-written shims used to shadow them - see docs/experiments/experiment-117.
#
# osfmk/libsa is a real component in COMPONENT_LIST and its types.h defines uint_t, but its *source*
# directory must NOT go on the include path: it holds `string.h`, `stdlib.h` and a `sys/` subdir for
# the bootloader context, and putting it there cost 4 files (191 -> 187) by shadowing the real ones.
# Apple exports a *selected list* from each component (EXPORT_MI_LIST in each Makefile) into
# EXPORT_HDRS; exposing the whole directory is not the same thing, and this is the fourth time in
# this project that a broad include path has been the bug rather than the fix.
INCLUDES=(
    -I"$GENERATED/bsd" -I"$GENERATED"
    # The component's OWN option headers, ahead of the flat ones, so that `<meta_features.h>`
    # resolves to this component's slice of them. That is the whole of experiment-438: `libkern`'s
    # `conf/files` declares `gprof`, and a flat `meta_features.h` handed `#define GPROF 0` to a BSD
    # translation unit, where `#ifdef GPROF` at `bsd/kern/bsd_init.c:852` is *defined* - so the boot
    # called `kmstartup()`, which nothing in this image could define. Apple's build separates the two
    # because each component compiles from its own object directory (`MakeInc.def:466`,
    # `INCFLAGS_LOCAL = -I.`), which is what `tools/gen_option_headers.py` now reproduces.
    #
    # Per-file, like `COMP_FIRST_PLACEHOLDER` below, and for the same reason: which slice applies is
    # a property of the file being compiled. The four other readers of this list (the EABI runtime,
    # firehose, the platform block) resolve it to nothing and keep the flat header, which is the
    # behaviour they were measured with - they are this project's own files and belong to no
    # component.
    OPTION_FIRST_PLACEHOLDER
    -I"$OPTION_HEADERS"
    -I"$DEVICE_HEADERS"
    -I"$MIG_HEADERS"
    # `-I$XNU/osfmk` and `-I$XNU/bsd` are NOT here: they are inserted per file by `COMP_FIRST`,
    # because which of the two comes first is a property of the file being compiled and not of the
    # build. They go after the generated roots, never before - putting the component ahead of MIG's
    # output re-breaks the six `osfmk/vm` files experiment-124 fixed.
    COMP_FIRST_PLACEHOLDER
    -I"$XNU/iokit"
    -I"$XNU/libkern"
    -I"$XNU/pexpert"
    -I"$XNU"
    # The filtered `osfmk/libsa` types headers, before `bsd/arm` so that `<types.h>` resolves to the
    # kernel's own rather than to Darwin's machine types. See tools/gen_libsa_export.sh.
    -I"$LIBSA_EXPORT"
    -I"$XNU/osfmk/arm" -I"$XNU/bsd/arm"
    -I"$XNU/EXTERNAL_HEADERS"
    -I"$SHIMS" -I"$SHIMS/kern" -I"$SHIMS/mach"
    -I"$SHIMS_ARM" -I"$SHIMS_ARM/kern" -I"$SHIMS_ARM/mach"
    -I"$SHIMS_ARM/sys" -I"$SHIMS_ARM/sys/_pthread"
)

# ====================================================================================================
# 1021d -- THE FP/NEON CODEGEN SWITCH (`STAGE90_XNU_GENERAL_REGS`) AND WHY IT IS AN APPEND.
# ====================================================================================================
# **The defect this closes (records/1021-fpu-rootcause.txt, docs/1021c-general-regs-design.md).**
# 1020b's `udf` raise let pid 1 die, and the kernel then faulted in KERNEL mode at `0x8047b0ac`
# (`vld1.32 {d16-d17},[r0]!`, `lr=0x8047b0b0`) because `save_vfp_context` clears `FPEXC.EN` on the
# first context switch (`osfmk/arm/pcb.c:298-306`) and kernel mode never restores it. The fix is not
# to keep `FPEXC.EN` on (that clobbers the preempted thread's vector state in silence,
# docs/1021c 6.2); it is to stop the COMPILER emitting FP/NEON into the pool at all -- which is what
# Apple's own ARM kernel does (`makedefs/MakeInc.def:377-379`, `CFLAGS_ARM = ... -msoft-float`).
#
# **WHY IT IS `-msoft-float` AND WHY BOTH OLD FLAGS GO.** The pool today is built
# `-mfpu=neon-vfpv4 -mfloat-abi=softfp`. The flag that ALLOCATES the FP register file is
# `-mfloat-abi=softfp`: it says "the calling convention is soft but a hardware FPU is present and
# may be used for codegen", so the vectorizer emits NEON. `-msoft-float` maps to `-mfloat-abi=soft`
# and says the FPU is NOT usable, so no FP register is allocated at all (MEASURED, this host:
# a kernel-shaped TU goes 17 FP instructions -> 0). `-mfpu=neon-vfpv4` is dropped WITH it: beside a
# switch that declares NEON off it would still stamp a NEON-capable CPU on the objects, and that is
# the two-spellings shape ([[mi4-off-option-two-spellings]]). `-mfpu` alone (no `-mfloat-abi`) also
# measured 0 today, but it is `-msoft-float` that is Apple's spelling, so it is the one used.
# **`-mgeneral-regs-only` is deliberately NOT the flag**: it is accepted and then SILENTLY DROPPED
# by clang 14 on armv7 (measured: identical `-S` output, with an "argument unused" warning), so it
# would produce a pool byte-identical to today's while the record read "NEON off" -- design 1021c's
# opening finding.
#
# **`-mfpu=neon-vfpv4` IS DROPPED WITH IT, AND THE ONE THING THAT COULD HAVE ARGUED FOR KEEPING IT
# IS FALSE -- MEASURED, not assumed.** The worry is `proc_reg.h`'s cp10 moves
# (`mrc p10,7,%0,c8,c0,0`, 18 `mrc` + 15 `mcr` sites across the pool): could `-msoft-float` lower
# those to a real FP-register instruction (`vmrs r0, fpexc`) that faults with `FPEXC.EN` off? It does
# NOT, and `-mfpu` is not what would prevent it: on this host `mrc p10,7,%0,c8,c0,0` lowers to
# `vmrs`/`vmsr` under EVERY flag set tried -- `-mfpu=neon-vfpv4 -mfloat-abi=softfp`, `-msoft-float`,
# `-msoft-float -mfpu=neon-vfpv4`, `-mfloat-abi=soft`, `-msoft-float -mfpu=vfpv3` -- i.e. the
# lowering is a property of the assembler's reading of `mrc p10`, not of `-mfpu`. So `-mfpu` is INERT
# beside `-msoft-float` for both codegen and this family, and per docs/1021c section 2.1 it is dropped:
# a flag that reads "NEON is on" next to the switch that says it is off is the two-spellings shape,
# and its only effect here would be to stamp a NEON-capable CPU on objects the switch declares are not.
# `-msoft-float` does not change either `-mcpu` or `-marm`, so the ISA selection and the cp15 feature
# reads are unaffected. (The `vmrs`/`vmsr` sites are a KNOWN, PRE-EXISTING surface: they are in the
# pool today too -- 18 `mrc`/15 `mcr` -- and `-msoft-float` neither adds nor removes any.)
#
# **OFF IS BYTE-IDENTICAL, AND HERE IS THE MECHANISM.** The FP flags below are not edited in place.
# Each array expands `${FP_FLAGS[@]}` -- TWO ELEMENTS either way. With the switch at 0 those two
# elements are `-mfpu=neon-vfpv4 -mfloat-abi=softfp`, i.e. the SAME WORD LIST this script handed clang
# before the edit (it used to be one array element holding both words; a compile argv has no idea
# where one array element ended, so `CC_ARGS[*]` is unchanged word for word). Word-preserving, not
# merely same-result: `-msoft-float` is exactly the list the by-value census in
# docs/1021c section 1.1 measured at **0** FP instructions, so the OFF build is the pre-rung pool by
# construction and not by a second, unmeasured flag spelling. `--print-flags` (resolved at the TOP of
# this file, before any side effect) is the seam that makes "OFF is identical" checkable rather than
# asserted, and the two case statements below are the assertion that the seam and the compile cannot
# disagree.
CC_ARGS=(
    clang --target=$("$TOOLS_DIR/xnu_config/arm_target.sh") -mcpu=cortex-a15 -marm
    "${FP_FLAGS[@]}"
    -ffreestanding -fno-builtin -fno-common -fno-pic -O2 -w -ferror-limit=0
)
# The C++ half of the kernel - libkern/libkern/c++ and iokit, 83 of the manifest's files - is the
# same compiler with `clang++` and the two flags Apple's own rules pass for a kernel build
# (MakeInc.def: `-fno-exceptions -fno-rtti`; there is no exception unwinder or RTTI in a kernel).
# Nothing else differs, which is the point: the per-component define table, the generated roots,
# the include order and the shim placement are the *same mechanism*, because a `.cpp` in `libkern`
# is a `libkern` translation unit like any other.
CXX_ARGS=(
    clang++ --target=$("$TOOLS_DIR/xnu_config/arm_target.sh") -mcpu=cortex-a15 -marm
    "${FP_FLAGS[@]}"
    -ffreestanding -fno-builtin -fno-common -fno-pic -O2 -w -ferror-limit=0
    -fno-exceptions -fno-rtti
)

# **THE ASSERTION THAT THE SEAM AND THE COMPILE AGREE.** `--print-flags` is resolved at the top of
# this file and prints these same lists; the case statements here read the ARRAY the compile loops
# actually expand (`${CC_ARGS[@]}` at the four per-file/platform call sites, plus `CXX_ARGS`) and
# refuse if it does not carry what the switch resolved to. A future edit that moved the expansion
# behind a branch would otherwise re-create exactly the silent no-op this switch exists to avoid
# ([[mi4-a-claim-in-a-comment-is-not-a-check]]).
case "$GENERAL_REGS" in
    1) _gr_want="-msoft-float" ;;
    0) _gr_want="-mfpu=neon-vfpv4 -mfloat-abi=softfp" ;;
esac
case " ${CC_ARGS[*]} " in
    *" $_gr_want "*) ;;
    *) echo "REFUSING: CC_ARGS does not carry '$_gr_want' with STAGE90_XNU_GENERAL_REGS=$GENERAL_REGS -- the FP flags did not reach the array this build compiles with" >&2; exit 3 ;;
esac
case " ${CXX_ARGS[*]} " in
    *" $_gr_want "*) ;;
    *) echo "REFUSING: CXX_ARGS does not carry '$_gr_want' with STAGE90_XNU_GENERAL_REGS=$GENERAL_REGS -- the FP flags did not reach the array this build compiles the C++ half with" >&2; exit 3 ;;
esac
# The OFF half of the proof: with the switch at 0 neither array may contain `-msoft-float`. A build
# that carried it anyway would be a NEON-free pool under a record that says "unchanged", i.e. the
# OFF arm silently becoming the ON arm.
if [[ $GENERAL_REGS -eq 0 ]]; then
    case " ${CC_ARGS[*]} ${CXX_ARGS[*]} " in
        *"-msoft-float"*) echo "REFUSING: STAGE90_XNU_GENERAL_REGS=0 but the resolved flag list carries -msoft-float: OFF must be the exact pre-1021d argv" >&2; exit 3 ;;
    esac
fi
# The same reading is emitted into the ordinary build's own output, so a build log is by itself
# evidence of which flag list produced the objects below it. grep for the `xnu_1021d:` tag.
echo "  xnu_1021d: STAGE90_XNU_GENERAL_REGS=$GENERAL_REGS -> ... -mcpu=cortex-a15 -marm ${FP_FLAGS[*]} ..."
echo "  xnu_1021d: the flag list above is the argv both compile loops expand; OFF reads '-mfpu=neon-vfpv4 -mfloat-abi=softfp' and ON reads '-msoft-float' (run this script with --print-flags to read the resolved arrays without building)"

PER_FILE_TIMEOUT=${PER_FILE_TIMEOUT:-60}
: > "$OUT/timedout.txt"

# Extra `-D` flags for a controlled comparison, appended after the configuration's own. This exists
# because the alternative is a hand-copied flag list, and a hand-copied flag list is how the C++
# block got measured wrong in the first place: the sweep that produced "all 83 fail on
# osfmk/kern/misc_protos.h:254" passed `-DMACH_KERNEL_PRIVATE=1` for every file, which is a
# *component* define (xnu_config/component_defines.sh) and one no libkern or iokit file gets. With
# this hook the same experiment is one command against the real build:
#
#   XNU_KERNEL_EXTRA_DEFINES=-DMACH_KERNEL_PRIVATE=1 ./tools/build_xnu_arm_kernel.sh --dir libkern
#
EXTRA_DEFINES=()
if [[ -n ${XNU_KERNEL_EXTRA_DEFINES:-} ]]; then
    # shellcheck disable=SC2206
    EXTRA_DEFINES=( ${XNU_KERNEL_EXTRA_DEFINES} )
fi

# Extra C++-only flags, for the same reason and with the same shape as the define hook above: a
# controlled comparison has to be one command against the real build, not a hand-copied flag list.
# Only `.cpp` files get these, so a measurement can change the C++ half and nothing else.
#
#   XNU_KERNEL_EXTRA_CXXFLAGS=-fapple-kext ./tools/build_xnu_arm_kernel.sh --dir libkern
#
EXTRA_CXX_FLAGS=()
if [[ -n ${XNU_KERNEL_EXTRA_CXXFLAGS:-} ]]; then
    # shellcheck disable=SC2206
    EXTRA_CXX_FLAGS=( ${XNU_KERNEL_EXTRA_CXXFLAGS} )
fi

# The per-component define set. Apple's build compiles each component with its own
# `<component>/conf/Makefile.template` CFLAGS rather than one global flag set, and the difference is
# not cosmetic - see xnu_config/component_defines.sh, which holds the table and the citations.
# `build_xnu_arm_layer.sh` does not need this: it compiles only osfmk/arm, which is the osfmk row.
#
# Build output has no component path to read, so it needs the same mapping stated explicitly. Apple
# builds each generated file in the component that declares it, and the three roots follow that:
#
#   out/mach_headers/...            from osfmk/*/*.defs        -> osfmk
#   out/xnu_generated/bsd/...       from bsd/kern/syscalls.master, and the sys/ headers -> bsd
#   out/xnu_generated/libkern/...   from libkern/libkern/Makefile:79  -> libkern
#
# Getting this wrong is not silent for long: `init_sysent.c` compiled as osfmk picked up
# `-DMACH_KERNEL_PRIVATE`, which reaches kern/misc_protos.h, and died on the `ffs`/`fls` collision
# that experiment-118 is about. Defaulting to osfmk was the first version of this function and it
# was wrong in exactly that way.
component_of() {
    local p=$1 rel
    case "$p" in
        "$GENERATED"/bsd/*)      printf 'bsd'    ; return ;;
        "$GENERATED"/libkern/*)  printf 'libkern'; return ;;
        "$MIG_HEADERS"/*)        printf 'osfmk'  ; return ;;
    esac
    rel=$(printf '%s' "${p#"$XNU"/}" | cut -d/ -f1)
    printf '%s' "${rel:-osfmk}"
}

# The MASTER dir for one component's configuration, or empty when the tree has none - the input
# `select_master.sh` takes as `XNU_MASTER_DIR`. The modern tree (4570) keeps ONE `config/MASTER`
# shared by every component, so this is empty there and every file sees the same defines. The
# 2013-era tree keeps `<component>/conf/MASTER`, each declaring its own `RELEASE` with its own size
# attributes (`bsmall` in bsd/osfmk, `medium` in libkern), and each component is configured by
# `conf/Makefile`'s per-component `doconf` run - so a file must see ITS OWN component's defines. A
# single global expansion takes whichever attributes the union satisfied, which for the size axes is
# both, and `CONFIG_MAX_CLUSTERS` becomes `=4` and `=8` at once. Empty result = "use the default".
component_conf_dir() {
    local c=$1
    if [[ -n $c && -f $XNU/$c/conf/MASTER ]]; then
        printf '%s' "$XNU/$c/conf"
    fi
}

ok=0
fail=0
absent=0
skipped=0
tried=0
timedout=0
# Counted separately, because "does XNU compile" is a question about the C and the C++ halves
# together and a single pooled number hides which half moved. The C++ half's denominator is 83 of
# the manifest's 698 - the same manifest, one build.
cpp_ok=0
cpp_fail=0

# **1039 `--trap-argv`: one file's argv, by value** (2026-10-20).  `scripts/build_1039.sh`'s compile
# guard must check trap.c under the argv the POOL gives it.  The first version of that guard built the
# argv by hand and got it wrong twice (force-includes first let the driver eat an `-I` as the
# `-include` path; a whitespace split broke `-DNMBCLUSTERS=((1024 * 256) / MCLBYTES)` into three
# elements) -- [[mi4-one-value-two-definitions]].  So the argv is taken from here, where the pool
# assembles it, for the same file the pool compiles: no objects, no teardown, one line per element.
while read -r src; do
    # argv mode: drop every other file BEFORE any per-file work, so the pool's loop keeps its
    # counters and only this one iteration runs.
    if [[ $TRAP_ARGV_MODE -eq 1 ]] && [[ ${src#"$XNU"/} != "${TRAP_ARGV_SRC#xnu/}" ]]; then
        continue
    fi
    if [[ ! -f $src ]]; then
        absent=$((absent + 1))
        continue
    fi
    # `.s` only. The assembler is `xnu_arm_assemble.sh`'s job (Darwin dialect, a translation step,
    # and the toolchain question experiment-150 closed), not this script's.
    #
    # `.cpp` used to be skipped here too, with a comment saying it "needs libkern's C++ runtime,
    # which is a separate and larger problem than this measures". That was true of the *link* and
    # false of the compile, and skipping it cost the project a wrong answer: the 83 C++ files were
    # measured by hand, in a loop whose flags were not this script's, and one of those flags
    # (`-DMACH_KERNEL_PRIVATE` globally) made all 83 report the same error - which experiment-152
    # then recorded as "the whole C++ block is behind one dead line". It is behind no such line.
    # See experiment-154. Attempting them here, with this script's own flags, is what makes the
    # count comparable to the C count and the mistake unrepeatable.
    case "$src" in
        *.s|*.S) skipped=$((skipped + 1)); continue ;;
    esac
    is_cpp=0
    case "$src" in *.cpp) is_cpp=1 ;; esac
    if [[ -n $ONLY_DIR && $src != *"/$ONLY_DIR/"* ]]; then
        continue
    fi

    tried=$((tried + 1))
    if [[ $LIMIT -gt 0 && $tried -gt $LIMIT ]]; then
        break
    fi

    # Disambiguate: the manifest has files of the same name in different components. Both
    # extensions are stripped so the object names of the 615 C files are exactly what they were
    # before this script learned about C++, and the collision that could hide in doing so - one
    # `X.c` and one `X.cpp` in the same directory, one object path, whichever compiled last wins,
    # silently - is checked for rather than assumed absent (see the key check after the loop).
    key=$(printf '%s' "$src" | sed "s|$XNU/||; s|/|_|g; s|\.c$||; s|\.cpp$||")
    # Apple's include order puts the file's OWN component first:
    #   INCFLAGS_GEN = -I$(SRCROOT)/$(COMPONENT) -I$(OBJROOT)/EXPORT_HDRS/$(COMPONENT)
    # (MakeInc.def:465), and a single flat include list cannot express that. It matters:
    # `osfmk/kern/ast.h` and `bsd/kern/ast.h` **guard themselves with the same `_KERN_AST_H_`**,
    # and `bsd/kern/kern_event.c:101` includes `<kern/ast.h>` for `AST_KEVENT_REDRIVE_THREADREQ`,
    # which only the BSD one defines. With osfmk first the guard is already taken, the BSD header is
    # skipped, and the error is "use of undeclared identifier" for a macro that is in the file the
    # line above asked for. The array goes BEFORE `INCLUDES` - `-I` order is left to right, and a
    # first version appended it, which made the component LAST and changed nothing.
    # The component roots go where the placeholder is - after the generated roots, before the other
    # The component list is Apple's, from `makedefs/MakeInc.def:46-48`, and the rule is exact:
    #
    #   COMPONENT_LIST        = osfmk bsd libkern iokit pexpert libsa security san
    #   COMPONENT_IMPORT_LIST = $(filter-out $(COMPONENT),$(COMPONENT_LIST))
    #
    # so a file sees its OWN component root first and then every other component in that fixed
    # order. Written as the list minus the file's own component rather than as a case for the two
    # components that happen to have `.cpp` files, because a case is how this was got wrong: adding
    # rows for `libkern` and `iokit` and forgetting `bsd` in them silently dropped
    # `-I$XNU/bsd` for 68 libkern files, and the error - `sys/_types/_u_int.h not found`, from a
    # force-include - named neither the component nor the missing root.
    #
    # `-I$XNU/libsa` is deliberately NOT in the list even though it is a component: its source
    # directory holds `string.h`, `stdlib.h` and a `sys/` for the bootloader context, and putting
    # it on the path costs 4 files by shadowing the real ones (tools/gen_libsa_export.sh exports
    # the three type headers Apple actually exports, and only those).
    # `component_of` is the ONE definition of "which component is this file built in", and this line
    # used to be a second one - a naive first-path-segment cut. They agree for every file inside
    # `$XNU`, and disagree for the MIG-generated sources, which live OUTSIDE it: the cut yields the
    # empty string (the path does not start with `$XNU/`, so `cut` hands back the leading empty
    # field), while `component_of` correctly answers `osfmk` (their `.defs` are osfmk's). With
    # `bsd`-first import ordering (see COMPONENT_IMPORT_ORDER) the empty string made a generated
    # server's `-I` chain start at bsd, so `<arm/locks.h>` resolved to `bsd/arm/locks.h` and died on
    # its `#include <ARM/hw_lock_types.h>`. On 4570 the reorder is the identity, so the empty string
    # was invisible; correcting it here is required for D13 and inert for 4570.
    SRC_COMPONENT=$(component_of "$src")
    COMP_IMPORT=()
    for _c in "${COMPONENT_IMPORT_ORDER[@]}"; do
        [[ $_c == "$SRC_COMPONENT" ]] && continue
        COMP_IMPORT+=(-I"$XNU/$_c")
    done
    COMP_ROOTS=(-I"$XNU/$SRC_COMPONENT" "${COMP_IMPORT[@]}")
    # And the same split for the MIG server headers, which Apple builds TWICE from one rule pair
    # (`osfmk/mach/Makefile:231` with MIGFLAGS, `:372` with MIGFLAGS+MIGKSFLAGS). The `simport`
    # lines are behind `#if KERNEL_SERVER`, so the two variants differ; EXPORT_MI_GEN_LIST exports
    # only the first. osfmk reads the build dir (`INCFLAGS_LOCAL`, `INCFLAGS_GEN`) and gets the
    # variant WITH them; every other component reads export roots only (`INCFLAGS_IMPORT`) and gets
    # the one without — which is what keeps a BSD file out of `osfmk/ipc/ipc_kmsg.h`
    # (experiment-145).
    KSERVER_FIRST=()
    [[ $SRC_COMPONENT == osfmk ]] && KSERVER_FIRST=(-I"$MIG_KSERVER")

    # `libkern/gen/OSAtomicOperations.c` needs one thing no other file does: `stdbool.h` NOT to have
    # defined `false`/`true` before its own `enum { false = 0, true = 1 }`. Measured: it is reached
    # because the force-include set drags `mach/vm_param.h` (-> `libkern/os/overflow.h` ->
    # `EXTERNAL_HEADERS/stdbool.h`) into translation units that never include it. A `stdbool.h` shim
    # that defines `bool` but not the two macros fixes this file and **breaks 78 others** - because
    # 78 files write `true`/`false` and need the macros - so it is applied to this file only, with
    # the same per-file mechanism the component roots use. Apple's build needs neither: it
    # force-includes nothing, so it does not reach `stdbool.h` here at all.
    ONE_FILE=()
    [[ ${src#"$XNU"/} == "libkern/gen/OSAtomicOperations.c" ]] &&
        ONE_FILE=(-I"$REPO_ROOT/tools/shims_stdbool")
    # `bsd/sys/kauth.h:113` uses `uid_t` and `gid_t`, and includes nothing that defines them:
    # `sys/types.h` — which does, through `_types/_uid_t.h` — arrives later in the same closure
    # (`kern_ktrace.c`'s trace puts types.h at line 128 and kauth.h at 107). Apple's build reaches
    # them some other way; the narrow answer that does not drag in the whole BSD type set is
    # `sys/types.h` for BSD files only, where `kern_types.h`'s competing `clock_t` is not reachable
    # (it is behind `MACH_KERNEL_PRIVATE`, which a BSD file does not define — experiment-118).
    BSD_FORCE=()
    [[ $SRC_COMPONENT == bsd ]] && BSD_FORCE=(-include sys/types.h)

    # And the HFS+ port's own additions, for the HFS files only (experiments 875/877).  Every file
    # under `bsd/hfs/` - the staged 2050 sources - plus the one out-of-directory member of the port,
    # `bsd/vfs/vfs_journal.c` (the journal HFS calls; it is `#if JOURNALING`, which this header turns
    # on).  The test is on the PATH and not on "is it in `$HFS_FILES`" deliberately: a membership test
    # would have to read the list again per file, and the path test is the same set by construction -
    # `hfs_files.txt` names exactly these paths, and `tools/stage_hfs.sh` stages exactly them.
    # `-include` rather than a flag because the additions are macros a 2050 source reads without
    # declaring (see the header's own comment): nothing in the port may be edited to add an #include.
    if [[ $HFS_PORT -eq 1 && ( ${src#"$XNU"/} == bsd/hfs/* || ${src#"$XNU"/} == bsd/vfs/vfs_journal.c ) ]]; then
        BSD_FORCE+=(-include "$HFS_FORCE")
        # **The cprotect bridge is for a tree that made `struct cprotect` OPAQUE.** 4570 deleted
        # those structs (`bsd/sys/cprotect.h` is only `typedef struct cprotect *cprotect_t`, :99) and
        # turned the layer into an opaque kext API, so 878's bridge `hfs_cprotect_port.h` restores
        # them for the HFS files alone. The Darwin-13 (hd2) tree did NOT do that: its
        # `bsd/sys/cprotect.h` still DEFINES `struct cprotect` (:102) and the rest (:112/:117/:129/
        # :138/:153), layout-identical to the bridge's 2050 copies, and it carries the constants and
        # the two prototypes too. Force-including the bridge there is what redefines them, and that
        # is the collision that stopped all 36 `bsd/hfs` objects plus `vfs_journal` on D13. Gate on
        # the DEFINITION, not on the tree name, so a future tree is judged by its own header.
        grep -q '^struct cprotect' "$XNU/bsd/sys/cprotect.h" || BSD_FORCE+=(-include "$HFS_FORCE_CP")
    fi

    # `bsd/dev/unix_startup.c` includes `<netinet/tcp_var.h>`, which includes `<netinet/in_pcb.h>`,
    # and **in 4570 `in_pcb.h` is not self-contained**: it uses `struct in_addr`, `struct in6_addr`,
    # `struct route` and `struct sockaddr_in` at `:114,176,185,295` and includes `<netinet/in.h>`,
    # `<netinet6/in6.h>` and `<net/route.h>` nowhere. It does not have to be self-contained, because
    # Apple's configurations all set `IPSEC=1`, and `in_pcb.h:84`'s `#if IPSEC` then includes
    # `<netinet6/ipsec.h>` → `<net/if.h>` → `<net/if_var.h>` → **`<net/route.h>`** →
    # `<net/radix.h>` → `<net/if_llatbl.h>` → `<netinet/in.h>`. Every one of those four headers is
    # defined by a chain that starts at `net/route.h`. Newer xnu fixed it in the header rather than
    # in the configuration — `in_pcb.h` now opens with `#include <netinet/in.h>` and
    # `#include <sys/socketvar.h>` — which is the same fix, in the other file.
    #
    # So this is not a new dependency; it is the one Apple's build supplies, named directly. Measured
    # on `STAGE90_BOOT`, where `IPSEC` is off and nothing else in `unix_startup.c`'s closure reaches
    # it: one error, `netinet/in_pcb.h:114:17: field has incomplete type 'struct in_addr'`, and
    # `-include net/route.h` is the whole difference. Three other files in the same manifest also
    # reach `in_pcb.h` — `kern_malloc.c`, `sys_generic.c`, `audit_syscalls.c` — and all three compile
    # today because their own closure reaches `net/route.h` anyway (`kern_malloc.c` through
    # `<sys/kpi_mbuf.h>`), which is the control that says the header is the missing piece and not a
    # symptom.
    ROUTE_FORCE=()
    [[ ${src#"$XNU"/} == "bsd/dev/unix_startup.c" ]] && ROUTE_FORCE=(-include net/route.h)

    # `libkern/OSKextLib.cpp` and one declaration that disagrees with itself. `kext_request` is a
    # `friend` of `OSKext` (`OSKext.h:189`) and its definition sits inside the file's
    # `extern "C" {` block (`:38`), so clang reads the friend as C++ linkage and the definition as C
    # linkage. Two of the three errors that follow are not about linkage at all —
    # `'loadFromMkext' is a private member of 'OSKext'` and the same for `handleRequest` — because a
    # `friend` declaration grants access to *that function* and clang does not believe this is it.
    # One `extern "C"` declaration ahead of everything fixes all three, and it is the smallest
    # possible statement of what Apple's source already means; see the header's own comment.
    KEXT_FORCE=()
    [[ ${src#"$XNU"/} == "libkern/OSKextLib.cpp" ]] && KEXT_FORCE=(-include kext_request_c.h)

    # `clock_t`, per component, and this is the `-D_CLOCK_T` question arriving from the other side.
    # experiment-126 removed that flag because the per-component defines made both halves agree:
    # a BSD file gets `bsd/sys/_types/_clock_t.h`'s `__darwin_clock_t`, and `kern_types.h`'s
    # `struct clock *` is not reachable from it. **But `osfmk/kperf/kperfbsd.c` is an osfmk file
    # that includes `bsd/libkern/libkern.h` → `bsd/sys/types.h` → `_clock_t.h`**, so it sees both and
    # they conflict. The flag answers it in the direction that is now correct for osfmk files - it
    # takes `_clock_t.h`'s guard so `kern_types.h`'s definition is the one that survives - and it
    # is given to osfmk files only, which is the same restriction the BSD-only `sys/types.h` above
    # needs and for the same reason: which definition is right depends on the component.
    CLOCK_FORCE=()
    [[ $SRC_COMPONENT == osfmk ]] && CLOCK_FORCE=(-D_CLOCK_T=1)

    # The one file whose source cannot be compiled as written, and the switch that answers it.
    #
    # `osfmk/vm/vm_object.c:355` is `*object = vm_object_template;`, a whole-struct assignment, and
    # `osfmk/vm/vm_object.h:174` gives that struct a `const` member:
    #
    #     const unsigned int wired_page_count;
    #
    # C11 6.3.2.1p1: a structure is not a modifiable lvalue if any member is const-qualified, so the
    # assignment is a constraint violation. It is an **error**, not a warning, and it has no
    # `[-W...]` group, so there is nothing to suppress — `-w`, `-Wno-error`, `-fms-extensions`,
    # `-fms-compatibility` and `-fno-strict-aliasing` were each measured and each changes nothing,
    # and so does every `-std` from gnu89 to gnu17, with clang *or* arm-none-eabi-gcc. No define,
    # include order or target makes the construct legal. experiment-127 found exactly that and left
    # the file failing.
    #
    # What makes it worth answering anyway is the price, which experiment-158 measured: `vm_object.o`
    # defines **58 of the 189** symbols a whole-kernel link leaves undefined — the largest single
    # block, and its referrers are `vm_map.o`, `vm_pageout.o`, `memory_object.o` and `bsd_vm.o`. The
    # object this flag produces defines 152 symbols and exactly 58 of them are in that set.
    #
    # `-Dconst=` is a macro named `const` with an empty body, so every `const` in the translation
    # unit evaporates. It is cruder than the defect and it is deliberate: **it has to be defined
    # before the first token**, because the only other lever is the same trick scoped to
    # `vm/vm_object.h`, and that was measured to fail. A scoped `#define const` around the include
    # leaves the rest of the unit const-qualified, and a declaration reached inside the window then
    # disagrees with the same declaration reached outside it — `src/shims/kern/debug.h:6`
    # and `osfmk/kern/debug.h:423` both declare `Debugger`, and reading one `const char *` and the
    # other `char *` is "conflicting types for 'Debugger'". A unit-wide macro cannot produce that
    # class of disagreement, because there is only one reading of every header.
    #
    # What it cannot do is change a struct's layout, a symbol's name or a calling convention, and in
    # C, removing a `const` can only make the compiler *more* conservative about assuming a value's
    # stability. The visible effect is that const objects defined by this unit land in `.data`
    # rather than `.rodata`, which a flat ELF link does not distinguish.
    #
    # Scoped to this file by name, and the scope is load-bearing rather than tidy: applied to the
    # whole `osfmk/vm` directory it *costs* two files. `osfmk/vm/lz4.c` and
    # `osfmk/vm/vm_compressor_algorithms.c` compile today and fail under it — `lz4.h:68`'s
    # `static const size_t lz4_encode_scratch_size = lz4_hash_table_size;` is an initializer that
    # needs `const` to be a constant expression, and dropping it turns the array in
    # `vm_compressor_algorithms.c:52` into a variable-length one. That is the one-value-two-
    # definitions shape from the other side, and it is why this is a per-file switch.
    #
    # Apple's own source accommodates the same `const` a hundred lines below, at vm_object.c:469-470
    # — `// vm_object_template.wired_page_count = 0;`, commented out with the note that static
    # storage is already zero. The whole-struct copy at :355 is what is left.
    CONST_RELAX=()
    [[ ${src#"$XNU"/} == "osfmk/vm/vm_object.c" ]] &&
        CONST_RELAX=(-Dconst=)

    FILE_INCLUDES=("${KSERVER_FIRST[@]}")
    for _inc in "${INCLUDES[@]}"; do
        if [[ $_inc == COMP_FIRST_PLACEHOLDER ]]; then
            FILE_INCLUDES+=("${COMP_ROOTS[@]}")
        elif [[ $_inc == OPTION_FIRST_PLACEHOLDER ]]; then
            # This component's slice of the option headers, or the flat set when this file's first
            # path segment is not a component directory. The fallback is not a nicety: a manifest
            # entry outside the eight component roots would otherwise get *no* option macro at all,
            # and `#define X 0` and "undefined" read the same under `#if` but not under `#ifdef`.
            if [[ -d $OPTION_HEADERS/$SRC_COMPONENT ]]; then
                FILE_INCLUDES+=(-I"$OPTION_HEADERS/$SRC_COMPONENT")
            else
                FILE_INCLUDES+=(-I"$OPTION_HEADERS")
            fi
        else
            FILE_INCLUDES+=("$_inc")
        fi
    done
    FILE_DEFINES=("${CLOCK_FORCE[@]}" "${CONST_RELAX[@]}")

    # shellcheck disable=SC2207
    COMP_DEFINES=( $("$TOOLS_DIR/xnu_config/component_defines.sh" "$(component_of "$src")") )
    # The configuration's options for THIS file's component. `select_master.sh` falls back to the
    # shared `config/MASTER` when the component has no `conf/MASTER` (4570), so the two branches
    # below are the same expansion there and this is inert on the base tree.
    #
    # **This slice goes BEFORE `$DEFINES`, not after, and that is not cosmetic.** `DEFINES` ends
    # with two *cancellation* flags - `-UCONFIG_NO_PRINTF_STRINGS` and `-USECURE_KERNEL` (472) - and
    # clang resolves a macro by the last flag naming it. When this slice sat after `DEFINES`, the
    # `-DSECURE_KERNEL=1` the configuration declares came last and **overrode its own cancellation**:
    # 182 of 4570's 703 objects differed from the base, the linked-`cs_enforcement_enable` check
    # flipped to the secure branch, and the whole-image byte control failed. Keeping the
    # configuration slice first mirrors the original single-array layout, where it was `DEFINES[0]`.
    CONFIG_COMP_DEFINES=("${CONFIG_DEFINES[@]}")
    _ccd=$(component_conf_dir "$(component_of "$src")")
    if [[ -n $_ccd ]]; then
        CONFIG_COMP_DEFINES=()
        while IFS= read -r _d; do
            [[ -n $_d ]] && CONFIG_COMP_DEFINES+=("$_d")
        done < <(XNU_MASTER_DIR=$_ccd "$TOOLS_DIR/xnu_config/make_defines.sh" "$CONFIG" 2>/dev/null)
    fi
    # C++ goes through the same pipeline with the same flags, plus its own compiler and the two
    # rules flags. `CPP_FORCE` starts empty: the first measurement of the C++ block in this script
    # is the one with *no* C++-specific accommodation at all, so that whatever is added later has a
    # number to be worth. (The hand sweep this replaces force-included `sys/types.h` for every
    # `.cpp`; that is measured against this baseline below, not assumed.)
    CPP_FORCE=()
    CXX_EXTRA=()
    case "$src" in
        *.cpp) CXX_EXTRA=("${CXX_ARGS[@]}" "${CXX_STD_FLAGS[@]}" "${EXTRA_CXX_FLAGS[@]}"); CPP_FORCE=("${CPP_FORCE[@]}") ;;
        *)     CXX_EXTRA=("${CC_ARGS[@]}") ;;
    esac
    # 1038: trap.c ALONE is forced to read the switch's `#define` before its first line.  clang's
    # legacy "header heuristic" (`-I` of the CWD's ancestors switches a .c into header mode) folds
    # the 1037/1025 groups as header guards, which moves 1038's seam chunk out of the function it
    # was staged into and leaves 1025's `#endif` unmatched -- the tree's LAST function in header
    # context, where a definition is refused.  A `#define` as a forced include disables that fold
    # and is inert otherwise.  Per-file: the other pool objects' argv is unchanged.  The statics
    # arrive through trap.c's own seam `#include` (a header, one-time).
    case "${src##*/}" in
    esac
    # Bounded. A file that sends clang into a loop must cost seconds, not the whole session: one
    # did, for 45 minutes, because this had no timeout and its output was buffered behind a pipe.
    # A timeout is reported as its own outcome rather than as a compile failure, because "clang
    # hung" and "XNU does not compile" are different findings.
    # (1039 --trap-argv: the compile's own command, printed instead of run -- EVERY element in the
    # order the compile passes them, the compiler and its target/dialect flags FIRST.  The earlier
    # version printed the array list alone, and a caller that took it for the whole argv compiled
    # with a target the pool never uses ([[mi4-one-value-two-definitions]]: the MACH_KERNEL_PRIVATE
    # defect, this time in the guard).  `-c`/`-o` are NOT part of it: the caller adds
    # `-fsyntax-only` and its own switch flags.)
    if [[ $TRAP_ARGV_MODE -eq 1 ]]; then
        _ta=("${CXX_EXTRA[@]}" "${FORCE_INCLUDES[@]}" "${COMP_DEFINES_EXTRA[@]}" "${CONFIG_COMP_DEFINES[@]}" "${DEFINES[@]}" "${COMP_DEFINES[@]}" "${FILE_DEFINES[@]}" "${BSD_FORCE[@]}" "${ROUTE_FORCE[@]}" "${KEXT_FORCE[@]}" "${ONE_FILE[@]}" "${CPP_FORCE[@]}" "${EXTRA_DEFINES[@]}" "${FILE_INCLUDES[@]}")
        _ta_out=${TRAP_ARGV_CAPTURE:-/dev/stdout}
        [[ $_ta_out == /dev/stdout ]] || : > "$_ta_out"
        # (the head IS CXX_EXTRA here -- the compile passes it once, and printing it twice put a
        # second `clang` in the middle of the command: [[mi4-1039-guard-argv-not-pool-argv]])
        for _ta_a in "${_ta[@]}"; do printf '%s\n' "$_ta_a" >> "$_ta_out"; done
        printf '%s\n' "$src" >> "$_ta_out"
        echo "trap argv: ${#_ta[@]} elements + source (-> $src)" >&2
        exit 0
    fi
    if timeout "$PER_FILE_TIMEOUT" "${CXX_EXTRA[@]}" "${FORCE_INCLUDES[@]}" "${COMP_DEFINES_EXTRA[@]}" "${CONFIG_COMP_DEFINES[@]}" "${DEFINES[@]}" "${COMP_DEFINES[@]}" "${FILE_DEFINES[@]}" "${BSD_FORCE[@]}" "${ROUTE_FORCE[@]}" "${KEXT_FORCE[@]}" "${ONE_FILE[@]}" "${CPP_FORCE[@]}" "${EXTRA_DEFINES[@]}" "${FILE_INCLUDES[@]}" \
         -c "$src" -o "$OUT/$key.o" 2>"$OUT/$key.log"; then
        ok=$((ok + 1))
        [[ $is_cpp == 1 ]] && cpp_ok=$((cpp_ok + 1))
        rm -f "$OUT/$key.log"
    elif [[ $? -eq 124 ]]; then
        timedout=$((timedout + 1))
        printf '%s\n' "$src" >> "$OUT/timedout.txt"
        cat "$OUT/$key.log" >> "$OUT/all.log"
    else
        fail=$((fail + 1))
        [[ $is_cpp == 1 ]] && cpp_fail=$((cpp_fail + 1))
        cat "$OUT/$key.log" >> "$OUT/all.log"
        printf '%s\n' "$src" >> "$OUT/failed.txt"
    fi
done < "$MANIFEST"

# The EABI runtime. Outside the loop because it is not in the manifest and gets no component
# defines - it is this project's file, and the only thing it may read is what the loop's `INCLUDES`
# and `CC_ARGS` already give it. The `COMP_FIRST_PLACEHOLDER` in `INCLUDES` is per-file in the loop;
# for this one it is `osfmk`, the same default `component_of` uses, and `osfmk` is the right answer
# for a file that includes nothing from the tree.
mkdir -p "$RT_OUT"
RT_INCLUDES=()
for _inc in "${INCLUDES[@]}"; do
    if [[ $_inc == COMP_FIRST_PLACEHOLDER ]]; then
        # **The whole component chain in `COMPONENT_IMPORT_ORDER`'s order** - not a hardcoded `osfmk`
        # head followed by the rest. That was the D13 firehose `time_t` wall (920b): the firehose is
        # not a tree file, so `component_of` gives it `osfmk`, and a hardcoded `osfmk` head put
        # Darwin-13's private `osfmk/sys/types.h` (`typedef int time_t`) before bsd's, so
        # `bsd/sys/time.h:97`'s `typedef __darwin_time_t time_t` redefined it ('long' vs 'int').
        # `COMPONENT_IMPORT_ORDER` is `(osfmk bsd ...)` on a tree without that legacy header and
        # `(bsd osfmk ...)` on one with it (line 143-155), so reading it here gives osfmk the head on
        # 4570 (the identity) and bsd the head on D13. The EABI runtime, the other `RT_INCLUDES`
        # consumer, includes nothing from the tree, so the order cannot move it either way.
        for _c in "${COMPONENT_IMPORT_ORDER[@]}"; do
            RT_INCLUDES+=(-I"$XNU/$_c")
        done
    elif [[ $_inc == OPTION_FIRST_PLACEHOLDER ]]; then
        : # the flat option headers, which the next entry in the list already gives it (experiment-438)
    else
        RT_INCLUDES+=("$_inc")
    fi
done
rt_fail=0
for _src in "${RUNTIME_SOURCES[@]}"; do
    _o="$RT_OUT/$(basename "${_src%.c}").o"
    if "${CC_ARGS[@]}" "${FORCE_INCLUDES[@]}" "${CONFIG_DEFINES[@]}" "${DEFINES[@]}" "${RT_INCLUDES[@]}" \
           -c "$_src" -o "$_o" 2>"$RT_OUT/$(basename "${_src%.c}").log"; then
        rm -f "$RT_OUT/$(basename "${_src%.c}").log"
    else
        echo "runtime: $(basename "$_src") FAILED - $RT_OUT/$(basename "${_src%.c}").log" >&2
        rt_fail=$((rt_fail + 1))
    fi
done
[[ $rt_fail -eq 0 ]] || exit 4

# The firehose, which is not in the manifest and is not in the tarball at all. `osfmk/kern/firehose.c`
# does not exist: Apple ships the implementation as a closed kernel library (`libkern/firehose/` in the
# tarball has `KERNELFILES =` empty), and `bsd/kern/subr_log.c:874` calls `__firehose_buffer_create`
# anyway - so experiment 255 stopped there. The source is libdispatch's `src/firehose/firehose_buffer.c`,
# Apache-2.0, unmodified; see `src/firehose/README.md` for its provenance. It is compiled
# here, with the loop's own flags, for the same reason `RUNTIME_SOURCES` is: a second flag list is this
# project's most repeated defect, and this file reads the same kernel headers the loop's files do.
# `portinc/` is not a shim - it is the newer tree's `libkern/os/` atomics surface, which this 10.13-era
# tree does not ship, placed where `<os/...>` resolves (experiment 256).
#
# **It is a property of the TREE, and Darwin-13 has no firehose at all (920b).** The port exists for
# 4570 because 4570's `bsd/kern/subr_log.c` calls `__firehose_buffer_create`; **no file in Darwin-13's
# `bsd`, `osfmk` or `libkern` names it** (measured), so compiling the port there is building a
# `__firehose_buffer_create` nothing links. Worse, the source is from a newer tree than either (the
# 2015+ `os_log` era) and needs `atm_get_diagnostic_config()` and `<atm/atm_internal.h>`, which Darwin-13
# predates entirely - so it *cannot* compile against that tree, which is the wall that stopped the build.
# The gate below is `grep -rIl` for the symbol's name in the tree's own kernel sources, so it is
# **tree-derived, not tree-named** (`[[mi4-board-constants-from-device-dt]]`: pick by what exists).
# On 4570 the grep matches `bsd/kern/subr_log.c` and the firehose compiles exactly as before; on
# Darwin-13 it matches nothing and the block is a no-op.
if grep -rIlq '__firehose_buffer_create' "$XNU/bsd" "$XNU/osfmk" "$XNU/libkern" 2>/dev/null; then
FIREHOSE_SOURCES=("$REPO_ROOT/src/firehose/firehose_buffer.c" \
                  "$REPO_ROOT/src/firehose/firehose_kernel_config.c")
FH_OUT=$XNU_FIREHOSE_OBJ_OUT
FIREHOSE_INCLUDES=(-I"$REPO_ROOT/src/firehose/portinc" -I"$REPO_ROOT/src/firehose" -I"$XNU/libkern/firehose")
mkdir -p "$FH_OUT"
fh_fail=0
for _src in "${FIREHOSE_SOURCES[@]}"; do
    _o="$FH_OUT/$(basename "${_src%.c}").o"
    # The port's include roots go FIRST, ahead of the tree's: `portinc/` carries a newer tree's
    # `os/base.h` (which has `OS_OPTIONS`) and newer `firehose_types_private.h`, and the 4570 tree's
    # `libkern/os/base.h` would shadow them from further down the list.
    if "${CC_ARGS[@]}" "${FORCE_INCLUDES[@]}" "${CONFIG_DEFINES[@]}" "${DEFINES[@]}" "${FIREHOSE_INCLUDES[@]}" \
           "${RT_INCLUDES[@]}" \
           -c "$_src" -o "$_o" 2>"$FH_OUT/$(basename "${_src%.c}").log"; then
        rm -f "$FH_OUT/$(basename "${_src%.c}").log"
    else
        echo "firehose: $(basename "$_src") FAILED - $FH_OUT/$(basename "${_src%.c}").log" >&2
        fh_fail=$((fh_fail + 1))
    fi
done
[[ $fh_fail -eq 0 ]] || exit 5
fi

# The platform expert, which is not in the manifest because no configuration of Apple's has it. The
# open-source tree contains no concrete platform expert at all (experiment 362 measured the
# consequence: `IOStartIOKit.cpp:155`'s `IOPlatformExpertDevice` matches the kernel catalogue's one
# personality, `IOPanicPlatform`, and Apple designed that one to panic), so this stage authors the
# missing class - a concrete `IODTPlatformExpert` subclass whose whole content is its metaclass and
# the two pure virtuals the base leaves - and compiles it here.
#
# Here, and with the loop's own flags, for the reason `RUNTIME_SOURCES` and `FIREHOSE_SOURCES` are
# both compiled here rather than in a stage script: a second flag list is this project's most
# repeated defect, and this file is a C++ IOKit translation unit that must be ABI-identical to the
# 83 the loop compiles. Two things are stated rather than derived, and both are stated because
# `component_of` cannot answer them for a file outside the tree:
#
#   * the component is **iokit**, so the per-component defines are iokit's (`component_defines.sh`)
#     and the import roots are COMPONENT_LIST minus iokit, in Apple's order - which is exactly what
#     the loop's `COMP_ROOTS` computes for `$XNU/iokit/Kernel/IOPlatformExpert.cpp`, the file this
#     one subclasses.
#   * `-fapple-kext` is NOT passed, and must not be: the loop's C++ flags do not have it (it was
#     only ever *measured* through `XNU_KERNEL_EXTRA_CXXFLAGS`, experiment-330), so the kernel's
#     `OSObject` vtable is emitted by the class's own key translation unit rather than as a
#     kernel-kext weak definition, and an object built with the flag would disagree with the 83
#     about which vtable that is.
#
# And beside it, one C file: the kernel's personality table with this machine's platform expert in
# front of Apple's fallback (`gIOKernelConfigTables`, `iokit/KernelConfigTables.cpp:35`), which the
# same step replaces one object for one object. It is compiled with `CC_ARGS` - clang - and the
# compiler is load-bearing rather than incidental: clang puts the table string in `.rodata.str1.1`,
# which is where the stock object's table text lives, while gcc puts an identical source in
# `.rodata`, a different input section placed at a different point of the `.text` output section's
# `.rodata` run. It includes nothing, so the component defines and the force-include set cannot
# affect it; the compiler, the target triple and `-O2` are the whole of its configuration.
#
# **457's second class is the second entry of `PLATFORM_SOURCES`, and it is the same kind of thing for
# a different reason.** `MSM8974RootResource.cpp` is an `IOService` subclass whose personality
# (`IOProviderClass = IOResources`) is what makes `gIOCatalogue->findDrivers(gIOResources)` non-empty -
# so it is an iokit translation unit with an `OSMetaClass` and a vtable exactly as the platform expert
# is, compiled by the loop below with the same flags, into the same directory. It carries one extra
# requirement the platform expert does not: its `start` calls the entry image's `entry_live_write`,
# declared `extern "C"` rather than included, so `src/entry/build_entry.sh` is what must link it
# (the object is not in the manifest, so nothing else ever will).
#
# **And 492's `MSM8974Timer.cpp` is the third, which is the first one whose personality names a
# *device* class.** Nothing about the compilation changes - it is the same kind of iokit translation
# unit as the other two and its `start` calls `entry_live_write` for the same reason - but the entry
# it is matched by is filed under `IOPlatformDevice`, the class `IODTPlatformExpert::createNub` builds
# (`IOPlatformExpert.cpp:1283`), so it is the first driver here whose provider is a nub the *device
# tree* produced rather than an object the kernel itself creates. `tools/check_driver_catalogue.py`
# reads this list to check that the class each personality names exists in the link: a personality
# naming a class no object defines is `OSMetaClass::allocClassWithName` failing at match time, which
# prints nothing and starts nothing.
#
# **493's `MSM8974GIC.cpp` is the fourth, and the second under the same provider class as the timer.**
# It compiles exactly as the other three do; what it adds is a second node, so that "the catalogue's
# `IOPlatformDevice` bucket is searched for every nub and the *candidate test* is what selects" is a
# statement one run can falsify - `probeCandidates` probes every entry in the bucket against every nub,
# and two entries that name disjoint node names must each start on their own node and no other.
PLATFORM_SOURCES=("$REPO_ROOT/src/platform/MSM8974PlatformExpert.cpp"
                  "$REPO_ROOT/src/platform/MSM8974Timer.cpp"
                  "$REPO_ROOT/src/platform/MSM8974GIC.cpp"
                  "$REPO_ROOT/src/platform/MSM8974RootResource.cpp")

# And the two answers the platform expert above gives `IODTPlatformExpert::processTopLevel`, checked
# against the *same list* the loop below compiles rather than against a path repeated here - one
# value, one definition. Experiment 462's defect was a `return( (const char *)0 );` in
# `deleteList`, which is not "no names" to `IODTFindMatchingEntries` but "every entry", so the
# infanticide detached the device tree's whole top level - `chosen` among them - and `IOFindBSDRoot`
# could not root this machine. Apple's own subclasses answer with an OSUnserialize name list; this
# check refuses anything that is not one, including NULL, and refuses a file where only one of the
# two methods is defined (the stub generator would supply the other one, so it would link).
PL_MESSAGE=$("$TOOLS_DIR/check_platform_lists.py" --file "${PLATFORM_SOURCES[@]}" 2>&1) || {
    echo "$PL_MESSAGE" >&2
    exit 2
}
[[ ${VERBOSE:-0} -eq 0 ]] || printf '%s\n' "$PL_MESSAGE"

PLATFORM_C_SOURCES=("$REPO_ROOT/src/platform/stage90_platform_config_tables.c")
# **973: the board platform expert (the 914 PE), compiled HERE so it is in the pipeline.** 914
# *measured* that `src/platform/darwin13/pe_msm8974.c` compiles 1/1 against Darwin-13 (via
# `tools/build_xnu_arm_layer.sh`'s `XNU_ARM_EXTRA_DIRS`), but that probe is a standalone tool - it is
# in no build pipeline - so the object landed in `out/xnu_arm_obj_d13/`, a directory the entry link
# never reads. The 972 press found the consequence: `PE_init_platform` calls `PE_init_SocSupport`,
# which the kernel pool's `pexpert_arm_common_pe_socsupport.o` leaves undefined, so the entry build's
# stub generator fabricated `PE_init_SocSupport_stub` and the boot stopped on it
# (`stub_hit=PE_init_SocSupport_stub`). This file DEFINES that symbol (`pe_msm8974.c:182`). It is
# compiled here, with the pexpert component defines (which supply `PEXPERT_KERNEL_PRIVATE`, the gate
# that makes `<pexpert/protos.h>` - where `gPESocDispatch` lives - reachable) plus the board define
# the file's own `#if defined(BOARD_CONFIG_MSM8974)` requires.
PLATFORM_SOC_SOURCES=("$REPO_ROOT/src/platform/darwin13/pe_msm8974.c")
PL_OUT=$XNU_PLATFORM_OBJ_OUT
PL_ROOTS=(-I"$XNU/iokit")
for _c in "${COMPONENT_IMPORT_ORDER[@]}"; do
    [[ $_c == iokit ]] && continue
    PL_ROOTS+=(-I"$XNU/$_c")
done
PL_INCLUDES=()
for _inc in "${INCLUDES[@]}"; do
    if [[ $_inc == COMP_FIRST_PLACEHOLDER ]]; then
        PL_INCLUDES+=("${PL_ROOTS[@]}")
    elif [[ $_inc == OPTION_FIRST_PLACEHOLDER ]]; then
        : # the flat option headers, which the next entry in the list already gives it (experiment-438)
    else
        PL_INCLUDES+=("$_inc")
    fi
done
# shellcheck disable=SC2207
PL_COMP_DEFINES=( $("$TOOLS_DIR/xnu_config/component_defines.sh" iokit) )

# **And a third list (432): the one stage source in this block that includes an XNU header.**
#
# `src/supply/stage90_pthread_functions.c` supplies `struct pthread_functions_s` -
# the table `bsd/kern/pthread_shims.c:275` guards on, whose only writer in Apple's tree is
# `pthread.kext`, a binary that is not in the tarball and that no object in the pool stands in for.
# 431's run is what named it: the boot reached `bsd_init + 0x7F4` and panicked with
# "pthread kernel extension not loaded (function table is NULL)."
#
# It is here, rather than compiled by `build_entry.sh`'s own toolchain, for one reason: **the file
# includes `<sys/pthread_shims.h>`**, and the whole value of that is that the table's layout is the
# layout the kernel was compiled against rather than a copy of it. A second compiler, a second
# include order or a second define set is a second definition of the struct's layout - the defect
# class this project has a memory about - and it would not fail loudly: it would call a function
# through the wrong offset.
#
# So the flags are the loop's own, with two things named rather than derived, for the same reason
# the platform expert's block names them (`component_of` cannot answer them for a file outside the
# tree):
#
#   * the component is **bsd**, because `<sys/pthread_shims.h>` is a BSD header and the file that
#     reads the table (`bsd/kern/pthread_shims.c`) is compiled under `bsd/conf/Makefile.template`'s
#     defines. The import roots are therefore COMPONENT_LIST with `bsd` in front and dropped from
#     the tail, which is what the loop's `COMP_ROOTS` computes for that file.
#   * **the force-includes stay exactly as they are** - the same `FORCE_INCLUDES` the loop's 698
#     files get, plus `-w`. Nothing extra is added for this file, and that is measured rather than
#     assumed: with `eventvar.h` included first inside the source (see its header comment for the
#     circular include that makes the order load-bearing) it compiles under the plain set, under
#     `-include sys/types.h` and under those two plus `sys/kernel_types.h` alike.
# **And a fourth file in that list (437): the crypto dispatch table.**
#
# `src/supply/stage90_crypto_functions.c` supplies `g_crypto_funcs` - the table
# `aes_encrypt_key128` reads through, whose only writer `register_crypto_functions()` is called by
# nothing in this tree. 436's whole-kernel run is what named it: `tcp_init`'s inlined `tcp_tfo_init`
# called `aes_encrypt_key128` unconditionally, and it faulted on `g_crypto_funcs` being NULL.
#
# It is in this block for the same reason the pthread table is, and the reason is the *structs*:
# `crypto_functions_t` and the six descriptor types it is made of come from
# `<libkern/crypto/register_crypto.h>` and `<corecrypto/ccmode.h>`, so the table's member offsets and
# each descriptor's method offsets are the kernel's own rather than a copy. A mirror of any of these
# layouts would not fail loudly - it would call a method through the wrong offset.
#
# The component is **bsd**, the same one the pthread table and `bsd/netinet/flow_divert.c` get: that
# file includes `libkern/crypto/crypto_internal.h` and reads this very table, so the BSD define set is
# *measured* to be sufficient for these headers rather than assumed - and the include roots are
# COMPONENT_LIST with the component in front and dropped from the tail, which reaches
# `$XNU/libkern/libkern/crypto/register_crypto.h` through `-I$XNU/libkern`.
#
# Unlike the pthread table it needs no special treatment of the force-include set: it includes only
# libkern and corecrypto headers, none of which reach a BSD header that `eventvar.h`'s circular
# include is about. The AES implementation it points at is *not* here - `stage90_aes.c` includes
# nothing from the tree at all, so `build_entry.sh` compiles it, for the reason written there: the
# same translation unit has to be runnable on the host for its known-answer tests.
# **And a fifth file in that list (439), which is generated rather than written.**
#
# `pseudo_inits` is the array `bsd_autoconf()` walks (`bsd/kern/bsd_init.c:1083`), and 438's run is
# what named it: a prefetch abort fetching `0xE52DE004` - the ARM encoding of `push {lr}`, which is
# the first word inside every one of that image's 42 stub bodies. The symbol had been stubbed as a
# *function*, and `bsd/dev/busvar.h:46` declares it `extern struct pseudo_init pseudo_inits[]`, so
# the walk's first `ps_func` was the stand-in's own prologue word and `blx r1` jumped to it.
#
# Apple generates this array too - `SETUP/config/mkioconf.c:79-100` writes one `{count, func}` per
# `pseudo-device` line with an `init` word, in the configuration's order, terminated by `{0, 0}` -
# and `tools/gen_pseudo_inits.py` reproduces that derivation from `tools/xnu_config/expand.sh`, which
# is this project's own reproduction of doconf's `<feature>` filtering. So the content is measured
# rather than typed, and it is **per configuration**: RELEASE keeps `bpfilter` and `fsevents`,
# STAGE90_BOOT does not, which is why the generated file lives in its own configuration's directory.
#
# It is in *this* block for the same reason the pthread and crypto tables are: the file includes
# `<dev/busvar.h>`, so `struct pseudo_init`'s layout is the kernel's own rather than a copy of it -
# `-DDRIVER_PRIVATE=1` is in the bsd define set and is what exposes it. The component is **bsd**
# because that is the header's component and because `bsd_autoconf` is the reader.
PLATFORM_BSD_SOURCES=("$REPO_ROOT/src/supply/stage90_pthread_functions.c"
                      "$REPO_ROOT/src/supply/stage90_crypto_functions.c"
                      "$REPO_ROOT/src/platform/stage90_root_media.c"
                      "$PSEUDO_INITS_SRC")
# And the HFS+ port's ten shims, only when the port is on (`$HFS_PORT`, above): with it off nothing in
# the manifest references them, so compiling the object would add ten definitions no link needs - and
# `build_entry.sh`'s `require` for it would then be owed an object the pool mode never builds.
#
# **But ONLY on a tree that actually LACKS those ten symbols.** `stage90_hfs_shims.c` is a 4570-port
# artifact: it supplies `vnode_name`, `is_suser`, `ubc_create_upl`, `proc_tbe`, `vfs_markdependency`,
# `proc_apply_thread_selfdiskacc`, `fslog_fs_corrupt`, and the three `IOBSD*` helpers because 4570
# dropped or renamed them. The Darwin-13 (hd2) tree DEFINES all ten itself - `vnode_name`
# (bsd/vfs/kpi_vfs.c:2061), `is_suser` (bsd/kern/kern_prot.c), `ubc_create_upl` (bsd/kern/ubc_subr.c),
# `proc_tbe` (bsd/kern/kern_proc.c), `vfs_markdependency` (bsd/vfs/kpi_vfs.c), `fslog_fs_corrupt`
# (bsd/vfs/vfs_fslog.c:344), `IOBSD*` (iokit/bsddev/IOKitBSDInit.cpp), and `proc_apply_thread_selfdiskacc`
# (osfmk/kern/task_policy.c) - so compiling the shim object there is not an addition but TEN duplicate
# definitions, and the link dies with `multiple definition of 'vnode_name'` from the HFS pool's own file
# resolving to the pool, then colliding with the shim. Gate on the tree DEFINING the file's first shim
# (`bsd/vfs/vfs_fslog.c`, which 4570 does not carry at all), so the tree judges itself.
[[ $HFS_PORT -eq 1 && ! -f "$XNU/bsd/vfs/vfs_fslog.c" ]] &&
    PLATFORM_BSD_SOURCES+=("$REPO_ROOT/src/supply/stage90_hfs_shims.c")
PL_BSD_ROOTS=(-I"$XNU/bsd")
for _c in "${COMPONENT_LIST[@]}"; do
    [[ $_c == bsd ]] && continue
    PL_BSD_ROOTS+=(-I"$XNU/$_c")
done
PL_BSD_INCLUDES=()
for _inc in "${INCLUDES[@]}"; do
    if [[ $_inc == COMP_FIRST_PLACEHOLDER ]]; then
        PL_BSD_INCLUDES+=("${PL_BSD_ROOTS[@]}")
    elif [[ $_inc == OPTION_FIRST_PLACEHOLDER ]]; then
        : # the flat option headers, which the next entry in the list already gives it (experiment-438)
    else
        PL_BSD_INCLUDES+=("$_inc")
    fi
done
# shellcheck disable=SC2207
PL_BSD_COMP_DEFINES=( $("$TOOLS_DIR/xnu_config/component_defines.sh" bsd) )
# **The BSD-rooted platform sources take the BSD component's CONFIG slice, not the global one.**
# `stage90_hfs_shims.c` and `stage90_root_media.c` include BSD's private headers (`sys/ubc_internal.h`
# reads `MAX_CLUSTERS` -> `CONFIG_MAX_CLUSTERS`), so they must see the same CONFIG slice the pool's
# *bsd* files are compiled with: the `bsd/conf/MASTER` expansion, which on Darwin-13 is a per-component
# directory and supplies `CONFIG_MAX_CLUSTERS=4` (`bsd/conf/MASTER:321`). The global `${CONFIG_DEFINES[@]}`
# is a DIFFERENT set: it is expanded with `XNU_TREE` set, so `make_defines.sh $CONFIG` resolves to the
# *bsd* MASTER only in the 4570 layout (one `config/MASTER`, where `component_conf_dir` returns empty
# and the two slices coincide). On the Darwin-13 tree the global expansion yields 41 defines and NO
# `CONFIG_MAX_CLUSTERS`, so the shim failed to compile while every pool bsd object - compiled with the
# per-component slice at the pool loop - was fine. This is the same per-component split the pool already
# makes (see the `CONFIG_COMP_DEFINES` block); here it is made once for the block, keyed off the tree's
# own `component_conf_dir` so 4570 is unchanged (`component_conf_dir` returns empty -> the global set).
PL_BSD_CONFIG_DEFINES=("${CONFIG_DEFINES[@]}")
_bsd_ccd=$(component_conf_dir bsd)
if [[ -n $_bsd_ccd ]]; then
    PL_BSD_CONFIG_DEFINES=()
    while IFS= read -r _d; do
        [[ -n $_d ]] && PL_BSD_CONFIG_DEFINES+=("$_d")
    done < <(XNU_MASTER_DIR=$_bsd_ccd "$TOOLS_DIR/xnu_config/make_defines.sh" "$CONFIG" 2>/dev/null)
fi
mkdir -p "$PL_OUT"
pl_fail=0

# **The platform block's Darwin-13 compat, tree-derived (921).** Our `src/platform/*.cpp` were written
# against the modern tree's IOKit surface, and two spellings differ on Darwin-13:
#
#   * `APPLE_KEXT_OVERRIDE` — 4570's `OSMetaClass.h:106` defines it; Darwin-13 does not define it at
#     all, so every `virtual ... APPLE_KEXT_OVERRIDE` declaration is a syntax error. Supplied by
#     `src/platform/msm8974_build_compat.h`, gated so it is inert where the tree already defines it.
#   * `ABSOLUTETIME_SCALAR_TYPE` — Darwin-13 declares `options ABSOLUTETIME_SCALAR_TYPE` in
#     `bsd/conf/MASTER:85`, so its BSD units see `AbsoluteTime` as the scalar `UInt64` and call the
#     real `absolutetime_to_nanoseconds(uint64_t, uint64_t *)`. The platform block is `iokit` and
#     takes only `iokit/conf/MASTER`'s defines (experiment 918), so without the define it sees the
#     `UnsignedWide` struct and the wrapping macro, whose `__OSAbsoluteTime` won't take a `uint64_t`.
#     Forced here to the same scalar spelling the BSD half and 4570 use.
#
# Both are gated on the tree (`grep`/`-f`), so 4570 takes neither and its platform objects are
# unchanged. The force-include goes FIRST, so a file's own `#include <IOKit/...>` follows it.
PL_COMPAT_INCLUDES=()
PL_COMPAT_DEFINES=()
if [[ -f $XNU/bsd/conf/MASTER ]] && grep -q 'ABSOLUTETIME_SCALAR_TYPE' "$XNU/bsd/conf/MASTER"; then
    PL_COMPAT_INCLUDES=(-include "$REPO_ROOT/src/platform/msm8974_build_compat.h")
    PL_COMPAT_DEFINES=(-DABSOLUTETIME_SCALAR_TYPE=1)
fi

for _src in "${PLATFORM_SOURCES[@]}"; do
    _o="$PL_OUT/$(basename "${_src%.cpp}").o"
    if timeout "$PER_FILE_TIMEOUT" "${CXX_ARGS[@]}" "${CXX_STD_FLAGS[@]}" "${EXTRA_CXX_FLAGS[@]}" "${PL_COMPAT_INCLUDES[@]}" "${FORCE_INCLUDES[@]}" \
           "${PL_COMPAT_DEFINES[@]}" "${CONFIG_DEFINES[@]}" "${DEFINES[@]}" "${PL_COMP_DEFINES[@]}" "${EXTRA_DEFINES[@]}" "${PL_INCLUDES[@]}" \
           -c "$_src" -o "$_o" 2>"$PL_OUT/$(basename "${_src%.cpp}").log"; then
        rm -f "$PL_OUT/$(basename "${_src%.cpp}").log"
    else
        echo "platform: $(basename "$_src") FAILED - $PL_OUT/$(basename "${_src%.cpp}").log" >&2
        pl_fail=$((pl_fail + 1))
    fi
done
# The C one: no component defines, no force-includes, no import roots - it includes nothing, and the
# only thing that has to match the objects around it is the compiler and the target triple.
for _src in "${PLATFORM_C_SOURCES[@]}"; do
    _o="$PL_OUT/$(basename "${_src%.c}").o"
    if timeout "$PER_FILE_TIMEOUT" "${CC_ARGS[@]}" -c "$_src" -o "$_o" \
           2>"$PL_OUT/$(basename "${_src%.c}").log"; then
        rm -f "$PL_OUT/$(basename "${_src%.c}").log"
    else
        echo "platform: $(basename "$_src") FAILED - $PL_OUT/$(basename "${_src%.c}").log" >&2
        pl_fail=$((pl_fail + 1))
    fi
done
# 973: the board platform expert. Unlike the C file above it INCLUDES XNU headers
# (`<pexpert/protos.h>`, `<pexpert/arm/boot.h>`, `<machine/machine_routines.h>`, ...), so it needs the
# include roots and the pexpert component defines - the shape the BSD-rooted loop below uses, with the
# component's own defines. `-DBOARD_CONFIG_MSM8974=1` selects the file's `#if` gate; the pexpert
# defines supply `PEXPERT_KERNEL_PRIVATE`, which is what makes `pexpert.h:43` include
# `<pexpert/protos.h>` (where `gPESocDispatch` is declared). The Python-heredoc-less form keeps the
# define list visible; a compile failure is reported with its log, never swallowed.
# 1039: the OWNER of this define set reads `PEXPERT_KERNEL_PRIVATE` from component_defines.sh, not from
# a copy of it here ([[mi4-one-value-two-definitions]]: the block above still says "the pexpert
# component defines" and handed it iokit's, so `pexpert.h`'s gate never opened and `gPESocDispatch`
# read as undeclared -- a 1039 BUILD defect, measured at the platform block alone).
PL_SOC_COMP_DEFINES=( $("$TOOLS_DIR/xnu_config/component_defines.sh" pexpert) )
case " ${PL_SOC_COMP_DEFINES[*]} " in
    *" -DPEXPERT_KERNEL_PRIVATE=1 "*) ;;
    *) echo "REFUSING: component_defines.sh pexpert does not carry PEXPERT_KERNEL_PRIVATE=1 - the board PE's <pexpert/protos.h> gate cannot open" >&2; exit 3 ;;
esac
for _src in "${PLATFORM_SOC_SOURCES[@]}"; do
    _o="$PL_OUT/$(basename "${_src%.c}").o"
    if timeout "$PER_FILE_TIMEOUT" "${CC_ARGS[@]}" "${FORCE_INCLUDES[@]}" "${CONFIG_DEFINES[@]}" "${DEFINES[@]}" \
           "${PL_SOC_COMP_DEFINES[@]}" "${EXTRA_DEFINES[@]}" "${PL_INCLUDES[@]}" -DBOARD_CONFIG_MSM8974=1 \
           -c "$_src" -o "$_o" 2>"$PL_OUT/$(basename "${_src%.c}").log"; then
        rm -f "$PL_OUT/$(basename "${_src%.c}").log"
    else
        echo "platform: $(basename "$_src") FAILED - $PL_OUT/$(basename "${_src%.c}").log" >&2
        pl_fail=$((pl_fail + 1))
    fi
done
# 1039: THE SOC OBJECT'S OWN GATE.  The loop above's `rm -f "$log"` on success and its `pl_fail` count
# are the only report, and a stale object from an earlier run (or another directory) can stand in for
# this one silently -- measured 2026-10-20: the pool build refused with "pool objects absent" while
# every platform loop said 0 failures.  So the object is checked BY VALUE, here, where it is made.
[[ -f "$PL_OUT/$(basename "${PLATFORM_SOC_SOURCES[0]%.c}").o" ]] || {
    echo "REFUSING: the SOC object $PL_OUT/$(basename "${PLATFORM_SOC_SOURCES[0]%.c}").o was not written" >&2; exit 3; }
# (the needle is the LINE, not " T sym ": the symbol is the object's LAST line, where no trailing
# space stands -- a gate spelled with one refused a correct object, 2026-10-20)
_soc_sym=$(nm "$PL_OUT/$(basename "${PLATFORM_SOC_SOURCES[0]%.c}").o" 2>/dev/null | awk '$2 == "T" && $3 == "PE_init_SocSupport_msm8974" {n++} END {print n+0}')
if [[ $_soc_sym == 1 ]]; then :
else echo "REFUSING: the SOC object does not define PE_init_SocSupport_msm8974 (the board PE the entry link needs)" >&2; exit 3; fi
# The BSD-rooted C one, and the only difference from the loop above is which defines and which
# roots it gets: the BSD half's, because the header it includes is read by BSD code. Same compiler,
# same `-O2`, same force-include set - `-w` is in `CC_ARGS` for every file in this build.
for _src in "${PLATFORM_BSD_SOURCES[@]}"; do
    _o="$PL_OUT/$(basename "${_src%.c}").o"
    # 862: the root-media module has to name the RAM disk's END symbol, which only `entry_ramdisk.s`
    # defines and only `build_entry.sh` links. The other two BSD sources do not name it, so it is
    # added per file rather than to the whole loop; the module `#error`s if it is ever missing, so a
    # future source that grows the same need fails loudly rather than reading an empty macro.
    _bsd_defs=("${PL_BSD_COMP_DEFINES[@]}")
    [[ ${_src##*/} == stage90_root_media.c ]] &&
        _bsd_defs+=(-DSTAGE90_ROOT_MEDIA_SIZE_SYM=g_stage90_ramdisk_end)
    if timeout "$PER_FILE_TIMEOUT" "${CC_ARGS[@]}" "${FORCE_INCLUDES[@]}" "${PL_BSD_CONFIG_DEFINES[@]}" "${DEFINES[@]}" \
           "${_bsd_defs[@]}" "${EXTRA_DEFINES[@]}" "${PL_BSD_INCLUDES[@]}" \
           -c "$_src" -o "$_o" 2>"$PL_OUT/$(basename "${_src%.c}").log"; then
        rm -f "$PL_OUT/$(basename "${_src%.c}").log"
    else
        echo "platform: $(basename "$_src") FAILED - $PL_OUT/$(basename "${_src%.c}").log" >&2
        pl_fail=$((pl_fail + 1))
    fi
done
[[ $pl_fail -eq 0 ]] || exit 6

# The key check the loop's comment promises. Two sources, one object path, whichever compiled last
# wins - and it would show up as nothing at all: a build that reports success and an object that
# belongs to a different file. It is the same defect as `-D_CLOCK_T` and the shadowed headers
# (memory: mi4-one-value-two-definitions), so it is checked rather than reasoned about.
dupes=$(sed "s|$XNU/||; s|/|_|g; s|\.c$||; s|\.cpp$||" "$MANIFEST" | sort | uniq -d)
if [[ -n $dupes ]]; then
    echo "ERROR: two manifest sources share one object name:" >&2
    printf '%s\n' "$dupes" | sed 's/^/  /' >&2
    exit 3
fi

# Which configuration this pool *is*. It is read back by the entry link, and it exists because the
# entry image's objects are a **glob** over this directory (`build_entry.sh`'s 436 block):
# whichever build ran last decides what the whole kernel in the image is made of, and until 459
# nothing recorded that. A pool built for one configuration and an image linked expecting another is
# the "one value, two definitions" defect with a build in the middle of it, and it shows up as
# nothing at all - the image links, the checks pass, and the kernel is a different kernel.
#
# **And under `--platform-only` it is read rather than written (492).** This mode builds the
# out-of-manifest blocks and *not* the pool, so a stamp from it would be a fact about a build that did
# not happen: the pool objects stay whatever they were while `config` becomes this run's - and the
# first time that happened it was a `--platform-only` run without `XNU_KERNEL_CONFIG`, which stamped
# `config RELEASE` over a `STAGE90_XNU` pool whose 708 objects were never touched. `build_entry.sh`'s
# `verify_root_device` refused the next link for it, which is the guard working and the *writer* being
# wrong. So the mode now compares the stamp instead: the pool has to be the configuration this run
# would compile the platform blocks with, and a mode that cannot say so stops before building them.
if [[ $ONLY_PLATFORM -eq 1 ]]; then
    stamp=$OUT/config.stamp
    if [[ ! -f $stamp ]]; then
        {
            echo "ERROR: --platform-only has no $stamp to compare against, so it cannot tell which"
            echo "       configuration the pool in $OUT is. Build the pool first:"
            echo "         XNU_KERNEL_CONFIG=$CONFIG XNU_MASTER_LOCAL=<fragment> ./tools/build_xnu_arm_kernel.sh"
        } >&2
        exit 3
    fi
    pool_config=$(awk '$1 == "config" { print $2 }' "$stamp")
    if [[ $pool_config != "$CONFIG" ]]; then
        {
            echo "ERROR: --platform-only would compile the out-of-manifest blocks with $CONFIG's"
            echo "       defines, and the kernel pool in $OUT is the '$pool_config' kernel. Set"
            echo "       XNU_KERNEL_CONFIG=$pool_config (and the same XNU_MASTER_LOCAL the pool was"
            echo "       built with) and re-run. It is not a warning: the blocks are linked into the"
            echo "       image beside that pool."
        } >&2
        exit 3
    fi
    echo "  platform-only: the pool in $OUT is the '$pool_config' kernel, and the stamp is left alone"
else
    {
        printf 'config %s\n' "$CONFIG"
        printf 'master_local %s\n' "${XNU_MASTER_LOCAL:-}"
        printf 'objects %s\n' "$(ls "$OUT"/*.o 2>/dev/null | wc -l)"
        printf 'defines %s\n' "$(printf '%s\n' "${DEFINES[@]}" | grep -c .)"
        printf 'pool_printf_shim %s\n' "$(grep -l 'U _consume_printf_args' "$OUT"/*.o 2>/dev/null | wc -l)"
        printf 'pool_mockfs_objects %s\n' "$(ls "$OUT"/bsd_miscfs_mockfs_*.o 2>/dev/null | wc -l)"
    } > "$OUT/config.stamp"
fi

echo
echo "== $CONFIG manifest for arm, compiled =="
echo "  C files tried:        $((tried - cpp_ok - cpp_fail))"
echo "  compile:              $((ok - cpp_ok))"
echo "  fail:                 $((fail - cpp_fail))"
echo "  absent from tarball:  $absent"
echo "  timed out (${PER_FILE_TIMEOUT}s): $timedout"
echo "  C++ files tried:      $((cpp_ok + cpp_fail))"
echo "  C++ compile:          $cpp_ok"
echo "  C++ fail:             $cpp_fail"
echo "  skipped (.s):         $skipped"
echo "  objects in $OUT"
echo "  EABI runtime:         ${#RUNTIME_SOURCES[@]} file(s) -> $RT_OUT (not in the manifest)"
echo "  platform expert:      ${#PLATFORM_SOURCES[@]} C++ and ${#PLATFORM_C_SOURCES[@]} C file(s) -> $PL_OUT (not in the manifest)"
echo "  tables this image supplies: ${#PLATFORM_BSD_SOURCES[@]} C file(s) -> $PL_OUT (not in the manifest)"

# ---- the kernel-source CONTENT record (experiment 980) --------------------------------------------
#
# **The pool's own sources are hashed here, at the moment they are compiled, because nothing else
# looks at them.** `preflight_boot_check.sh` decides staleness by MTIMES over `src/`, and
# `src/entry/build_entry.sh` merely LINKS `$OUT/osfmk_arm_pmap.o` (and `..._arm_vm_init.o`, ...) - so
# an edit to `osfmk/arm/pmap.c` that is not rebuilt leaves a stale object that the gate cannot see.
# This writes the CONTENT hash of every source in `$MANIFEST` (the list the loop above compiled from,
# `tools/xnu_tree_roots.sh:67`) to one record the gate re-checks by re-hashing the same paths.
#
# **CONTENT, not mtime**: the HFS sources are STAGED into the tree by `tools/stage_hfs.sh` and marked
# (`hfs_vfsops.c` carries 905 B2's guarded `vfs_clearflags`), and a re-provision or checkout resets an
# unchanged file's mtime - an mtime test would refuse a correct tree (measured: `hfs_vfsops.c` is
# newer than its `.o` while the pool object and the image both carry the staged patch).
#
# A `--limit`/`--dir` run compiles only part of the pool, so its record would be a lie about the rest;
# write none, and say so.
KERNEL_SRC_RECORD=$REPO_ROOT/out/xnu_kernel_src$XNU_OBJ_SUFFIX.sha256
if [[ $ONLY_PLATFORM -eq 1 ]]; then
    # `--platform-only` compiles no pool object and its `$MANIFEST` is the emptied platform-only list
    # (line 313), so a record here would hash the WRONG sources - a lie about the pool. Write none.
    echo "  kernel source record: NOT written (--platform-only builds no pool objects)"
elif [[ $LIMIT -eq 0 && $ONLY_DIR == "" ]]; then
    KSM_OUT=$("$TOOLS_DIR/gen_kernel_source_manifest.py" "$MANIFEST" --write "$KERNEL_SRC_RECORD" 2>&1) || {
        echo "REFUSING: the kernel-source content record could not be written - see above" >&2
        echo "$KSM_OUT" >&2
        exit 5
    }
    echo "  kernel source record: $KERNEL_SRC_RECORD"
    echo "$KSM_OUT" | sed 's/^/  /'
else
    echo "  kernel source record: NOT written (a partial build - --limit/--dir - is not the whole pool,"
    echo "                        so its record would misrepresent the objects the entry image links)"
fi

# 472: and the one measured consequence of `-USECURE_KERNEL`, checked over the object rather than
# over the flag list. `kern_cs.c:82-84` is `#if SECURE_KERNEL` / `const int cs_enforcement_enable = 1;`
# and `:94` is `SECURE_READ_ONLY_LATE(int) cs_enforcement_enable = DEFAULT_CS_ENFORCEMENT_ENABLE;`
# for the other branch, so **the symbol's `nm` type is the reading**: `R` means the `const` was
# compiled (a secure kernel, and `cs_enforcement(NULL)` is unconditionally 1), `D`/`B` means it was
# not. Nothing else about this build reports which of the two happened - the flag is one word in a
# command line that carries hundreds, and a `-U` swallowed by a later `-D` looks exactly like a `-U`
# that worked. The second half is the boot-arg string: `cs_init`'s `PE_parse_boot_argn
# ("cs_enforcement_disable", ...)` is inside `#if !SECURE_KERNEL` (`:133-155`), so the string's
# presence in the object is the same reading from the other end.
#
# It runs only when the object exists, so a `--dir` or a partial run does not fail on it.
if [[ -f $OUT/bsd_kern_kern_cs.o ]]; then
    _cs_type=$(arm-none-eabi-nm "$OUT/bsd_kern_kern_cs.o" 2>/dev/null |
                   awk '$3=="cs_enforcement_enable"{print $2}' | head -1)
    if [[ $_cs_type == R ]]; then
        echo "ERROR: bsd_kern_kern_cs.o has cs_enforcement_enable read-only ($_cs_type), i.e. the" >&2
        echo "       SECURE_KERNEL branch of kern_cs.c:82-84 was compiled: this is a secure kernel," >&2
        echo "       cs_enforcement(NULL) is 1 unconditionally, and mach_loader.c:1127 refuses any" >&2
        echo "       binary without an embedded code signature with LOAD_FAILURE - so 'execve' of the" >&2
        echo "       RAM disk's Mach-O cannot succeed. The '-USECURE_KERNEL' in the cancellation list" >&2
        echo "       above is not taking effect (a later -D, or a header defining it)." >&2
        exit 2
    fi
    if ! arm-none-eabi-strings "$OUT/bsd_kern_kern_cs.o" | grep -qx "cs_enforcement_disable"; then
        echo "ERROR: bsd_kern_kern_cs.o does not carry the 'cs_enforcement_disable' boot-arg string," >&2
        echo "       so cs_init's !SECURE_KERNEL block is compiled out and the kernel has no run-time" >&2
        echo "       route to enforcement at all - the same finding as the check above, seen from the" >&2
        echo "       reader that consumes it." >&2
        exit 2
    fi
    echo "  cs_enforcement_enable is $_cs_type (writable) and cs_enforcement_disable is a boot arg:"
    echo "    SECURE_KERNEL is undefined, so an unsigned executable can be activated"
fi

if [[ $SHOW_BLOCKERS -gt 0 ]]; then
    echo
    echo "== distinct missing names, most common first =="
    grep -hoE "unknown type name '[A-Za-z_][A-Za-z0-9_]*'|use of undeclared identifier '[A-Za-z_][A-Za-z0-9_]*'" "$OUT/all.log" \
        | sed "s/unknown type name '//;s/use of undeclared identifier '//;s/'//" \
        | sort | uniq -c | sort -rn | head -"$SHOW_BLOCKERS"
    if [[ -s $OUT/timedout.txt ]]; then
        echo
        echo "== clang did not finish in ${PER_FILE_TIMEOUT}s =="
        sed 's/^/  /' "$OUT/timedout.txt"
    fi
    echo
    echo "== missing headers =="
    grep -hoE "'[^']*\.h' file not found" "$OUT/all.log" | sort | uniq -c | sort -rn | head -"$SHOW_BLOCKERS"
fi
