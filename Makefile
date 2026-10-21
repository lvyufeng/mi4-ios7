# Convenience entry point for the Xiaomi Mi 4 (cancro) / MSM8974 XNU bring-up.
#
#   make                 build the live tree -> out/stage90/stage90-qcdt.img
#   make list            the archived stage snapshots and where they live now
#   make restore STAGE=50   bring an archived snapshot back (tools/stage-archive.sh)
#   make check           no tracked file still names the retired snapshot layout
#   make clean           REFUSED - see below, and read it before changing it
#
# **There is one tree and it is not a snapshot.** Until 2026-09-26 this repository was one directory
# per stage and `make` discovered the newest one from the directory listing. That model was retired:
# the live code is `src/`, the scripts that build and fire it are `scripts/`, the arm record is
# `records/`, and the five snapshots that were still in the working tree are `archive/stages/`
# (`stage0` .. `stage84` live at the tag `stage-archive-base`). Read `archive/stages/README.md`.
# There is therefore no `stage%` pattern rule any more: a second stage does not exist to match it, and
# the rule that used to build one was a directory-discovery trick rather than a build step.
#
# Booting is deliberately NOT a make target, unchanged from before. `fastboot boot` is a per-action
# decision and it is non-persistent; nothing here flashes.

LIVE_OUT := out/stage90

.DEFAULT_GOAL := all

.PHONY: all build list restore check clean help

all: build

build:
	@./scripts/build.sh
	@echo
	@echo "built into $(LIVE_OUT)/"
	@echo "Verify it non-persistently with:"
	@echo "    sudo fastboot boot $(LIVE_OUT)/stage90-qcdt.img"

list:
	@tools/stage-archive.sh list

# The retired model's own escape hatch, kept because the archived snapshots are still readable and
# restorable. A restored snapshot lands at the repository ROOT so that its pre-2026-09-26 scripts
# resolve `../out`, `../external` and `../tools`; see tools/stage-archive.sh.
restore:
	@if [ -z "$(STAGE)" ]; then \
	  echo "usage: make restore STAGE=<N>   (e.g. make restore STAGE=50)"; \
	  exit 1; \
	fi
	tools/stage-archive.sh restore $(STAGE)

# Two claims that are commit-message prose otherwise, and both are about the repository's own bookkeeping
# rather than about the artifact:
#   check_stage_paths.sh    reads every tracked file outside docs/ and archive/ and refuses an executable
#                           literal that names the retired snapshot layout.
#   check_set_name_rule.sh  reads records/revert-set.txt and refuses a set NAME whose 8 hex characters are
#                           not the sha256 prefix of one of that set's own members - and, for the storage
#                           family, not the entry image's. The rule was prose inside a `role=` string until
#                           732 named an arm after its qcdt and nothing noticed (see that file's header).
# Neither one touches the device, `out/`, or the gate.
#   read_storage_key_order.py --selftest
#                           re-derives the two landed *moments* defects - m732 (a rung-3/4 cell
#                           read for a moment that belongs to rung 7) and m763 (the key quoted
#                           for "after the power byte" is published by the reset stage, first) -
#                           from the call order of `entry_storage.c` alone. It is a fifth check
#                           rather than a fourth because the tool it guards was WRONG TWICE
#                           while it was being written: once naming every function `__attribute__`,
#                           once truncating a macro-generated key to half a name. Both times the
#                           table it printed looked plausible. A reference tool that can lie like
#                           that has to carry a self-test, and the self-test has to run.
#   check_count_citations.py
#                           reads every tracked file outside archive/ and refuses a count quoted in two
#                           bases that do not agree with each other. The hexadecimal word is the reading
#                           and the decimal beside it is a transcription of it, and the transcription had
#                           never been checked: three were wrong at once in one sentence, and one of them
#                           is the count the ladder's `#error` text, the record and this repository's
#                           readiness narration all quote for CMD1 - the device printed 5,091,328 there and
#                           the decimal written down was 5,088,000 (778). **This comment quotes that pair
#                           in prose and NOT as the form the tool reads, deliberately**: a citation of a
#                           defect and the defect are the same characters, so the note in
#                           records/revert-set.txt that refutes the wrong pair spells its two halves in
#                           separate sentences, and so does this one.
#                           It REFUSES on `tools/`, `scripts/`, `records/`, `Makefile` and `src/` minus
#                           `src/entry/` - exempt for a COST reason and not a lane reason, because an
#                           entry source is a member of the entry image's recorded source manifest and a
#                           comment there makes the gate refuse the arm a press is waiting on - and it
#                           only PRINTS what it finds under docs/experiments/, which is the historical
#                           record and is superseded rather than rewritten. It carries a self-test, run by
#                           the line above it, because it is a reference tool like the one above - and the
#                           self-test asserts the four idioms that look like a citation and are not:
#                           `offset (step)`, a tick count beside a millisecond figure, a decimal with no
#                           separators, and a pair three orders of magnitude apart.
#   report_int_enable_windows.py
#                           the census of every store to INT_ENABLE 0x34: which word each command
#                           window writes, resolved by NAME through the assignment that builds it and
#                           never by line number. Reports the SCOPE of the rung-23 widening (one window
#                           of three) and refuses a store whose value is a bare literal, because a
#                           literal there is one value with two definitions.
#   derive_sdc1_pads.py --selftest
#                           the pad arithmetic and the census rules, as cells. The ptr-only cells need
#                           no input at all; the four census cells run against the device's own dt.img and
#                           are SKIPPED BY NAME where it does not exist, so a cell that cannot run never
#                           reads as one that ran and agreed.
#   check_line_citations.py
#                           reads the press path's own prose - `tools/verify_press_ready.sh` and
#                           `records/revert-set.txt` - and refuses a `file.c:NNNN` citation whose site has
#                           MOVED. The baseline is GIT and not a file, because a tool that records its own
#                           expected values is a self-written record: for each citation it takes the commit
#                           that WROTE it (`git log -p --reverse`, one history walk per citing file) and
#                           asks what that line said then. 802 section 7 measured by hand that the ladder's
#                           CMD2 gate had moved from `:4785` to `:4964` and the single CMD1 call from
#                           `:4702` to `:4808`; the same question over this tree finds THIRTY-THREE moved
#                           citations in the press path, so this is a population and not three instances.
#                           **It refuses only the prose that PRINTS FOR THE LIVE ARM** - the `rung_para N`
#                           line and the `entry_conseq+=` lines for the rung the artifact's own switch
#                           record names - because a paragraph for another rung does not print on this arm
#                           and the `#` comments never print; and it only PRINTS what it finds in the
#                           historical record for the same reason check_count_citations.py does. It does
#                           NOT decide a citation whose text now appears at more than one line (147 lines of
#                           `entry_storage.c` are duplicated), because guessing which one it moved to is
#                           the defect it exists to catch. `--live-rung N` examines another rung's paragraph,
#                           which is how the refusal path is demonstrated without editing the tool.
#   check_sdc1_pad_expectation.py
#                           reads the TRACKED record records/sdc1-pad-candidates.txt and refuses an
#                           `ST_TLMM_SDC1_EXPECT` that matches no board the DEVICE'S OWN device tree
#                           declares. It reads the record and not the device tree because the device
#                           tree is `.gitignore`d (`xiaomi4-cancro-backup-*/`, like `external/`), so a
#                           clone cannot have it - and that is the point of the record: the source's
#                           comment cites `msm8974pro-ac-pm8941-mtp-v5.dts` as *the Mi 4's own board
#                           file*, and the vendor checkout holds no cancro device tree at all, only
#                           Qualcomm's reference boards. The tool that writes the record
#                           (`tools/derive_sdc1_pads.py --write-record`) does need the dt.img, and says
#                           so when it is missing. It does NOT refuse on ambiguity: this device declares
#                           two different pad words and the bootloader's choice is made on the device,
#                           so an ambiguous record prints its candidates and passes, and a no-match is
#                           the only refusal (779).
#   check_response_word_order.py
#                           the 136-bit response has ONE word order and it is the driver's. The vendor's
#                           `sdhci_finish_command` (external/.../sdhci.c:1163-1172) reads the four words
#                           WORD 3 FIRST (`SDHCI_RESPONSE + (3-i)*4`), shifts each left by 8, and ORs the
#                           stripped CRC's low byte back in from the address ONE BELOW the word, except for
#                           the last (`i != 3`). Every part of that is invisible in the register's name, and
#                           a copy that gets it wrong CANNOT FAIL LOUDLY: ascending word order, or a dropped
#                           byte, still yields 128 plausible bits that decode to a zeroed-out CSD or CID -
#                           no fault, no error, no cell. Rung 33 read a real SanDisk CID through this
#                           arithmetic and the tree holds SIX response-reading functions, in three shapes
#                           (the four-word assembly, the word-0 pair `:3995`'s comment calls "one arithmetic
#                           at three times", and the four raw words as a freshness witness). It refuses an
#                           offset the register does not have, an ascending or repeated word inside one
#                           command segment, and a CRC byte that is not the one below its own word. The
#                           NEXT rung is CMD9 (SEND_CSD, `ac R2`), which is the next place a fifth copy
#                           would be written: experiment 809's instruction to call the existing assembler
#                           rather than re-derive it was, until this runs, only a sentence in a document.
#                           `--selftest` holds nine fixtures - the four shapes this tree holds, and each of
#                           the five ways the arithmetic goes wrong - and exits 2 for a failed selftest,
#                           which is a different failure from the tree being wrong (experiment 810).
#   check_hfs_staged.sh
#                           the HFS+ port's tracked additions (src/shims/hfs/hfs_port_force.h,
#                           src/shims/hfs/hfs_cprotect_port.h and src/supply/stage90_hfs_shims.c) are
#                           the ONE definition the host-only probe AND tools/stage_hfs.sh both use; the
#                           untracked 4570 tree is a re-provisionable checkout that can fall behind them.
#                           It refuses a force-header #define that 4570 already defines at a different
#                           value - the "one value, two definitions" defect, silent when it happens - and
#                           a shims file that no longer defines the ten symbols 871 measured the port at.
#                           It also checks that the build force-includes the cprotect header second (877),
#                           and checks src/supply/hfs_files.txt (the manifest's HFS additions) against the
#                           staged tree, SKIPPING that part with a printed note when the tree is not
#                           staged rather than passing quietly. No compiler, no device. (874/875/876/877.)
check:
	@tools/check_stage_paths.sh
	@tools/check_set_name_rule.sh
	@tools/check_backtick_messages.sh --selftest >/dev/null
	@tools/check_backtick_messages.sh
	@tools/check_payload_config_entry.sh
	@tools/read_storage_key_order.py --selftest >/dev/null
	@tools/check_count_citations.py --selftest >/dev/null
	@tools/check_count_citations.py
	@tools/report_int_enable_windows.py --selftest >/dev/null
	@tools/report_int_enable_windows.py
	@tools/derive_sdc1_pads.py --selftest >/dev/null
	@tools/check_sdc1_pad_expectation.py --selftest >/dev/null
	@tools/check_sdc1_pad_expectation.py
	@tools/check_line_citations.py --selftest >/dev/null
	@tools/check_line_citations.py
	@tools/check_response_word_order.py --selftest >/dev/null
	@tools/check_response_word_order.py
	@tools/check_hfs_staged.sh
	@tools/check_d13_board_staged.sh
# 1000: the saved-state frame table `entry_saved_state.h` writes must agree with the tree's own
# assym tables - the USVC recorder (`entry_stubs.c`'s `entry_note_user_svc`) reads R0/R12/PC/LR/CPSR
# out of the frame by these offsets, and a wrong offset prints a field of the WRONG frame word with
# the right name on it (the one-value-two-definitions class, at the frame level). The tool derives
# the r_span from the assym source (never restates it), compares the header against BOTH the 4570
# and the D13 tables, and its selftest mutates an offset in each direction. Source half, no
# compiler, no device.
	@tools/check_saved_state_offsets.py --selftest >/dev/null
	@tools/check_saved_state_offsets.py
	@XNU_TREE=external/xnu-hd2-darwin13/xnu tools/check_saved_state_offsets.py
# 968: the COW writable-root arm needs D13's `hfs_mountroot` to mount the root read-write. `tools/
# hfs_patch_root_rw.py`'s guarded `vfs_clearflags(mp, MNT_RDONLY)` is the one edit that makes it so, and
# on D13 it is applied by `tools/stage_d13_root_rw.sh`. `check_d13_root_rw_staged.sh` re-derives the
# property (present, guarded, adjacent to the ROOT hfs_mountfs call) and refuses drift, so a re-provisioned
# `external/` cannot leave the arm silently disarmed. Source half, no compiler, no device.
	@tools/check_d13_root_rw_staged.sh
# 988: the statement after `bsd_init: done`. 987's run booted the whole mount and all of BSD init, then
# prefetch-aborted at `startup.c:408 OSKextRemoveKextBootstrap()` - `OSKext::removeKextBootstrap()`'s live
# `#if CONFIG_KXLD` block dereferences `getsegbyname("__LINKEDIT")`'s NULL return, and this image's
# synthetic Mach-O has no `__LINKEDIT` segment to find. On D13 the teardown is compiled out by wrapping
# that block in `#ifndef STAGE90_XNU_KEXTB_LOGIN` (`tools/stage_d13_kextb_login.sh`), and
# `tools/build_xnu_arm_kernel.sh` defines the switch for the pool when `STAGE90_XNU_KEXTB_LOGIN=1`.
# `check_d13_kextb_login_staged.py` re-derives the property (guard present, wrapping the KXLD block) and
# refuses drift, so a re-provisioned `external/` cannot leave the teardown silently compiled back in.
# Source half, no compiler, no device.
	@tools/check_d13_kextb_login_staged.py
# 971: the console fix's SECOND half. 970g (`tools/stage_d13_boot_path.sh`) makes the entry's console
# reachable through the boot table; but D13's `arm_vm_init` bzeroes a FRESH system table where 4570
# `bcopy`s the boot table into it, so the console is lost again the moment `set_mmu_ttb(cpu_ttb)` runs.
# `tools/stage_d13_vm_init.sh` applies the `bzero` -> `bcopy` edit; `check_d13_vm_init_staged.sh`
# re-derives the property (copy present, adjacent to the cpu_ttb assignment, bzero gone) and refuses
# drift, so a re-provisioned `external/` cannot leave the second half silently unapplied. Source half,
# no compiler, no device.
	@tools/check_d13_vm_init_staged.sh
# 970h: the LAST instruction of the D13 `_start` silence. 970g restored the boot path, but left a
# whole-TLB invalidate (`locore.s:85`) running BEFORE the TTBR0 write and before the zero/map loops
# build the boot table. The payload hands off with the MMU ON and its L1 identity-maps
# [0x80000000,0x81000000), so VA 0x80a00000 (the boot table) has a live identity TLB entry at the jump;
# the flush destroys it and the zero loop's first store walks the just-switched stale table and faults -
# silently. 4570's `_start` has no pre-switch invalidate (its only one is after the table is built).
# `tools/stage_d13_boot_path_970h.sh` removes the one instruction; `check_d13_boot_path_970h_staged.sh`
# re-derives the property BY POSITION (no `c8,c7,0` between `mmu_reinitialize:` and `mmu_initialized:`,
# exactly one post-build `c8,c7,0` remains) and refuses drift. Source half, no compiler, no device.
	@tools/check_d13_boot_path_970h_staged.sh
# 973: the 914 board platform expert (`src/platform/darwin13/pe_msm8974.c`) must be COMPILED (with
# `-DBOARD_CONFIG_MSM8974=1`) and LINKED into the entry image - the 914 experiment proved it compiles
# but left it in a pool no link list read, so `PE_init_platform`'s call to `PE_init_SocSupport` resolved
# to a generated stub and the 2026-10-10 press of `armed-d13-0184b928` stopped on it
# (`stub_hit=PE_init_SocSupport_stub`, caller `PE_init_platform+0x2c`). `check_board_pe_wired.sh`
# re-derives the four wiring links (the compile + its board gate, the variable's pool default, the
# LINK_OBJS entry - a `require` alone does not link - and the by-value linked-image clause that refuses
# the generated stub body), and refuses drift. Its `--selftest` mutates each of the five and asserts
# each is refused. Source half, no compiler, no device.
	@tools/check_board_pe_wired.sh --selftest >/dev/null
	@tools/check_board_pe_wired.sh
# 926: the entry link's object pool must follow the selected tree. `build_entry.sh` read one
# hard-pinned tree (4570) and one hard-pinned pool, 289 times; the D13 link needs the `_d13` pool.
# Re-derives the derivation from the tree's own header and refuses a re-pin. Source half, no device.
	@tools/check_entry_tree_pools.sh --selftest >/dev/null
	@tools/check_entry_tree_pools.sh
# 911b: the physical-memory ceiling port. `check_mem_size_max.py` re-derives the property the arm's
# whole safety argument rests on - an UNDEFINED STAGE90_XNU_MEM_SIZE_MAX leaves arm_vm_init.o
# byte-for-byte as Apple shipped it (both marker arms inside the #ifdef; the outer #else a bare
# define) - and refuses a ceiling that would map the ram_console (0xde500000) or MMIO as RAM, or wrap
# gPhysBase + mem_size past 32 bits. Source half, no compiler, no device; its --selftest feeds the
# MEASURED defect (a marker outside the #ifdef) and asserts it is refused.
	@tools/check_mem_size_max.py --selftest >/dev/null
	@tools/check_mem_size_max.py
# 956 (fifteenth tree-pin rung's cousin): `build_entry.sh` refuses `ENTRY_WINDOW >= 1 GiB` on D13,
# because D13's managed map is `gMemSize` long from the FIXED `MANAGED_BASE` 0xC0000000 - so the
# window IS memSize and 1 GiB fills its 16 KB L1 exactly (byte 0x3000..0x4000), with a 32-bit VA
# wrap one byte past. The refusal rests on four source facts; `check_d13_managed_base.py` re-derives
# each (MANAGED_BASE's value, the fixed assignment, `gMemSize` as the map length, L1_SIZE/tte_offset,
# and the `xnu_entry_jump.c` -> `args->memSize` -> `gMemSize` chain) and refuses if one moves, with
# the 4570 tree as the control. Its `--selftest` feeds nine measured mutations. No tree named: checks
# BOTH repo trees. Source half, no compiler, no device.
	@tools/check_d13_managed_base.py --selftest >/dev/null
	@tools/check_d13_managed_base.py
# 958: recognising the device's 3 GB. `check_d13_memory_total.py` re-derives the port: `max_mem` is
# what `hw.memsize` reads (kern_mib.c), the D13 edit is byte-neutral off (Apple's line as the `#else`
# arm, the include inside the guard), the managed map still maps `gMemSize` from the fixed
# MANAGED_BASE (so the 3 GB rides the report, not the map — 956), and the payload publishes the two
# DIFFERENT quantities: /memory/reg the boot bank 0x5e500000, /defaults hw.memsize the total
# 0xC0000000. `--selftest` feeds measured mutations; no `--tree` checks both repo trees (4570 is the
# control). Source half, no compiler, no device.
	@tools/check_d13_memory_total.py --selftest >/dev/null
	@tools/check_d13_memory_total.py
# 882: the HFS+ root volume and the arm that mounts it. Three claims, each one a committed artifact
# or a copied claim rather than a preference:
#   check_hfs_root_blob.py     reads the volume header out of the COMMITTED blob and refuses the fields
#                              the HFS sources index by (a stale blob still parses; it just mounts
#                              nothing). It reads the file, not a build, so it runs on any machine.
#   check_hfs_root_arm_split.py  the property experiment-881 section 3 is about - disk 0's strategy and
#                              DKIOCGETMEMDEVINFO must answer with DIFFERENT bytes on the HFS arm,
#                              because a failed hfs_mountroot has to fall through to a working mockfs.
#                              The one-line "cleanup" that undoes it reads as an improvement.
	@tools/check_hfs_root_blob.py src/entry/blob/xnu_arm_entry_root_hfs.img
	@tools/check_hfs_root_arm_split.py
# 910a: the USB2 OTG probe. The source half of `check_usb_probe.py` is switch-independent - it compares
# every offset `entry_usb.h` transcribed against the Android header that owns it, both directions, and
# asserts the write-nothing property - so it runs here on any machine with no build and no device. The
# image half (the switch read out of the linked ELF) needs a build and runs inside build_entry.sh.
	@tools/check_usb_probe.py --selftest >/dev/null
	@tools/check_usb_probe.py
# 910a2: the USB write arm. `check_usb_dev.py` compares every offset it writes and every value it sets
# against the Android source that OWNS it (the owner's own expression, evaluated), asserts the
# write-target whitelist and the mode gate at the source, and reads the switch out of the linked ELF.
# The source half is switch-independent, so it runs here with no build and no device.
	@tools/check_usb_dev.py --selftest >/dev/null
	@tools/check_usb_dev.py
# 910b: the enumeration arm. `check_usb_enum.py` RECOMPUTES the qh/dTD field offsets from
# `struct ci13xxx_qh` / `struct ci13xxx_td` (rather than trusting the header's comment - the qh `setup`
# field is at 40, not 32), compares every written value against the owner's own expression, asserts the
# write-target whitelist has no `USBCMD.RST`, and reads the switch out of the linked ELF. Source half is
# switch-independent, so it runs here with no build and no device.
	@tools/check_usb_enum.py --selftest >/dev/null
	@tools/check_usb_enum.py
# 910c: the bulk stream arm. `check_usb_stream.py` cross-checks the RAM console ring's layout against its
# owner (`entry_stubs.c`), refuses a completion that reads `qh.curr` instead of the dTD `token`, refuses a
# stream that enables the endpoint itself, and proves the EP1-IN handover both ways. Source half is
# switch-independent, so it runs here with no build and no device.
	@tools/check_usb_stream.py --selftest >/dev/null
	@tools/check_usb_stream.py
# The stream arm's BEHAVIOUR, not just its source: `--model` generates a host unit holding two copies of
# entry_usb_stream.c, maps the register window over itself, and drives the ring through seven cases
# (idle, one token per pass, host racing the CPU, a short transfer, the ring's fullness and wrap, the
# 1 s publication, and the DRAINED -> STREAM refill) at -O0 and -O1. It needs clang and mmap(MAP_FIXED)
# and reports `skipped` without them; it is not skipped for a failure.
	@tools/check_usb_stream.py --model
# 959-962: the RUNNER half of the clause-3 ladder. The four USB rungs are checked by the four guards
# above, but a key the entry image WRITES and the runner never READS makes a press's summary silent
# about that arm - the recorded "unread family" defect ([[mi4-911-runner-now-reads-all-goal-clauses]]).
# `check_runner_usb_families.py` runs both directions: the runner's USB block must name a marker key
# for each of the four families, and every `xnu_live_usb*` key it names must be published by a
# `src/entry/entry_usb*.c`. Source half, no build and no device; its --selftest feeds three measured
# mutations (a dropped family, an invented key, no block).
	@tools/check_runner_usb_families.py --selftest >/dev/null
	@tools/check_runner_usb_families.py
# 968: the RUNNER half of the COW writable root. The arm's ENTIRE adequacy claim is the shadow's three
# keys, and before this rung the runner read none of them - the same "unread family" defect, one rung
# after the USB ladder. `check_runner_cow_family.py` runs both directions: the runner's COW block must
# read BOTH the served key (`_cow_wr_blocks`) and the refused key (`_cow_refused` - a presence-only
# check would miss the failure), and every `xnu_live_rootmedia_cow*` key it names must be published by
# `src/platform/stage90_root_media.c`. Source half, no build and no device; its --selftest feeds four
# measured mutations (the served marker dropped, the refused marker dropped, an invented key, no block).
	@tools/check_runner_cow_family.py --selftest >/dev/null
	@tools/check_runner_cow_family.py
# 970: the RUNNER half of the entry WINDOW. 969 said the wall was the 16 MiB window; 970 found the window
# IS the allocator's physical-RAM end (`arm_vm_init.c:422 avail_end = gPhysBase + gMemSize`) and widened
# it payload-only, so what a reader must SEE is `xnu_entry_args_memSize` - the RAM XNU was handed. The
# runner read NO `xnu_entry_args*` key before this rung (and `keyval` cannot read the family anyway: it
# prepends `xnu_live_`, while the jump publishes `xnu_entry_*`). `check_runner_window_family.py` runs both
# directions: the runner's window block must read the memSize key, and every `xnu_entry_args*` key it
# names must be published by `src/xnu_entry_jump.c`. Source half, no build and no device; its --selftest
# feeds three measured mutations (the window marker dropped, an invented key, no block).
	@tools/check_runner_window_family.py --selftest >/dev/null
	@tools/check_runner_window_family.py
# 972: the asm de-underscore step. `tools/assemble_arm_layer.sh` strips ONE leading underscore off every
# symbol it assembles for the ELF - correct for Apple's `_foo` -> `foo`, but WRONG for names a C header
# deliberately defines WITH the underscore (`cpu_data.h:145` `#define disable_preemption
# _disable_preemption`). On D13 the strip turned the asm-defined `_disable_preemption` into
# `disable_preemption`, and the C caller reached a stub that the image does not provide (971 press:
# `stub_hit=_disable_preemption`). The builder now DERIVES a keep-set from `osfmk/arm/*.h` - every name
# a header aliases to an underscore form - and skips those in the rename loop. `check_deunderscore_guard.sh`
# re-derives the same set from both trees, asserts the builder's derivation is present, that D13 keeps the
# C-facing names, and that 4570's set intersects no 4570 asm object (the control). `--selftest` feeds a
# mutated builder + a stripped D13 object and asserts each is refused. Source half, no compiler, no device.
	@tools/check_deunderscore_guard.sh --selftest >/dev/null
	@tools/check_deunderscore_guard.sh
# 959-962: the HOST half of the USB ladder. `tools/usb_console_read.py` opens EP1-IN of VID:PID
# `0x18d1:0x0910` and drains the RAM console the ladder streams - the one way to read a *resident* run
# live (a resident arm has no ending, so it keeps no `/proc/last_kmsg`; [[mi4-975-window-on-the-working-entry]]).
# Its three constants are a PROTOCOL CONTRACT with `src/entry/entry_usb_enum.h`. `check_usb_host_reader.py`
# derives `ID_VENDOR`/`ID_PRODUCT`/`DIR_IN|EP_IN` from the device header and refuses a reader that has
# drifted - otherwise it opens the wrong device/endpoint and goes dark ([[mi4-one-value-two-definitions]]).
# Source half, no build and no device; `--selftest` mutates each of the three and asserts each is refused.
	@tools/check_usb_host_reader.py --selftest >/dev/null
	@tools/check_usb_host_reader.py
# 915-B rung 1: the low bank appended to DT /memory, and PROVABLY INERT. `STAGE90_XNU_REGIONS=1`
# appends `[0x00000000, 0x60000000)` to /memory/reg as words 2/3, leaving the boot pair at 0/1. It is
# a NO-OP for every reader (pe_state.c, pexpert.c, xnu_pe_init_platform_false.c all read pair 0), so
# the inertness is the arm's WHOLE claim. `check_d13_regions.py` makes it structural: the switch is
# `#if` not `#ifdef` (always-defined 0/1); the boot pair is FIRST in both arms and the off arm is the
# boot pair ALONE; the three readers read words 0/1 only (a reader reaching word 2/3 consumes the low
# bank without the rest of the port -> refused); build.sh records the switch. Source half, no build, no
# device; `--selftest` mutates each fact and asserts the refusal.
	@tools/check_d13_regions.py --selftest >/dev/null
	@tools/check_d13_regions.py

# **980: the press gate's staleness HOLE over the XNU kernel tree, and the content record that closes
# it.** `preflight_boot_check.sh` decides staleness by MTIMES over `src/` alone, and `build_entry.sh`
# merely LINKS the prebuilt `out/xnu_kernel_obj_d13/*.o` - so an unrebuilt `osfmk/arm/pmap.c` edit is
# invisible to the gate (its recorded hash, manifest, SHA256SUMS and revert-set all agree with each
# other). `tools/build_xnu_arm_kernel.sh` now writes a CONTENT hash of every source its compile loop
# reads (`out/xnu_kernel_src_d13.sha256`), and the gate re-hashes the same paths and refuses on drift.
# `gen_kernel_source_manifest.py --selftest` proves the record bites (content drift and a missing
# source refuse; an mtime-only change does not, which is why the reading is content and not mtime - the
# staged `hfs_vfsops.c` is newer than its `.o` on a correct arm). Host-only: no compiler, no device.
	@tools/gen_kernel_source_manifest.py --selftest >/dev/null
	@tools/check_kernel_source_record_wired.sh

# **915-B rung 0 (host half): the ONE /memory/reg region accessor.** `src/xnu_memory_regions.c` is the
# single walk of `/memory/reg` (v2 section 2.4/6.8): the boot region is the pair whose base equals the
# boot base and it MUST be pair 0, so "pair 0 is the boot region" stops being a convention the data can
# violate. It is PURE (`<stdint.h>` only), so `check_memory_regions_walk.py` compiles it with the HOST
# compiler and runs it against the exact word arrays the payload emits - no target compiler, no device.
# It is deliberately NOT in `scripts/build.sh` SOURCES yet: wiring it into the payload is the
# region-registration rung's job, and while rung 0 is host-only the shipped press arm stays byte-frozen
# (the check REFUSES the module appearing in build.sh). `--selftest` mutates the gate and the wiring.
	@tools/check_memory_regions_walk.py --selftest >/dev/null
	@tools/check_memory_regions_walk.py

# **1018: the CAP-EXEMPT undef witness's reader.** `tools/check_1018_capture.py` adjudicates the rung's
# five pre-registered cells (U-CTL / U-SILENT / U-FIRES-{DIES,LOOPS,ONCE}) on a recovered capture. Its
# `--selftest` builds a synthetic capture per cell and asserts the EXACT cell string (asserting only
# "refused" is what let an earlier broken control - the boot self-test row lives outside the
# `xnu_live_*` namespace the shared parser tokenizes, so it was never seen - pass a wrong cell). It also
# proves the reader holds NO literal for the frontier pc: two different pcs must yield the same cell.
# Source half, no compiler, no device.
	@python3 -I tools/check_1018_capture.py --selftest >/dev/null

# **`make clean` IS REFUSED, AND THAT IS THE POINT OF IT.** It used to `rm -rf out/stageNN` for every
# retained snapshot. There is exactly one `out/` now and it is not reproducible: `./build.sh` does not
# produce byte-identical output (experiment 408 measured that), so `out/stage90/stage90-qcdt.img` and
# the parked arms under `out/stage90/frozen/` are the only in-tree copies of images this device was
# already booted from, and `out/stage90/captures/` holds the logs those runs came back with. A target
# that deletes all three is one keystroke from destroying the record, and the keystroke is a word every
# operator types from habit.
#
# Removing the recoverable half is still available and is spelled out rather than hidden behind a flag:
# the object directories and the entry image rebuild from the tree. Nothing here deletes a park, a
# capture, or the payload.
clean:
	@echo "make clean is refused: $(LIVE_OUT)/ holds artifacts this repository cannot rebuild."
	@echo
	@echo "  not reproducible   $(LIVE_OUT)/stage90-qcdt.img, $(LIVE_OUT)/stage90.img,"
	@echo "                     $(LIVE_OUT)/stage90.bin, $(LIVE_OUT)/stage90.elf,"
	@echo "                     $(LIVE_OUT)/stage90-build-config.txt, $(LIVE_OUT)/SHA256SUMS.txt,"
	@echo "                     $(LIVE_OUT)/frozen/ (the parked arms),"
	@echo "                     $(LIVE_OUT)/captures/ (the run logs)"
	@echo "  reproducible       $(LIVE_OUT)/xnu_arm_entry.bin, the object directories, out/xnu_*_obj/"
	@echo
	@echo "  ./build.sh is reproducible from the tree AND this arm's switch set (666 section 5: three"
	@echo "  builds, twice plain and identical, and a parked arm rebuilt file-for-file) - but not"
	@echo "  from a tree that has since moved, and not without STAGE90_XNU_ENTRY=1, which the build"
	@echo "  leaves OFF by default. So a deleted payload is a press that cannot be re-verified."
	@echo "  763 corrected the 408 citation this line used to carry. To clear only the reproducible"
	@echo "  half - the object directories, the payload's"
	@echo "  own objects, and the entry image, which was measured byte-for-byte reproducible across"
	@echo "  the 2026-09-26 restructure - run:"
	@echo "      rm -rf out/stage90/xnu-objects out/xnu_*_obj out/xnu_assym \\"
	@echo "             out/stage90/*.o out/stage90/xnu_arm_entry.bin out/stage90/xnu_arm_entry.elf"
	@echo
	@echo "  That list is every glob here that resolves today; if one of them stops matching, the"
	@echo "  directory moved and this target's remedy is stale rather than the tree's."
	@exit 1

help:
	@echo "make                     build the live tree into $(LIVE_OUT)/"
	@echo "make list                the archived snapshots and where they live now"
	@echo "make restore STAGE=50    bring an archived snapshot back"
	@echo "make check               the repository's own bookkeeping: the retired layout, set names, backticked"
	@echo "                         messages (a code span that would run a command is refused too), the"
	@echo "                         payload's entry switch, every count quoted in two bases, the board-derived"
	@echo "                         pad constant against the device's own device tree, and a cited line"
	@echo "                         number whose site has moved out from under it"
	@echo "make clean               refused; the payload and the parks cannot be rebuilt"
	@echo
	@echo "Booting is not a make target: flash nothing, and boot non-persistently with"
	@echo "  sudo fastboot boot $(LIVE_OUT)/stage90-qcdt.img"
	@echo "Gate a run first: ./scripts/preflight_boot_check.sh --allow-xnu-entry"
