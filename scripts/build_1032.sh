#!/bin/bash
# 1032 -- THE COUNT CLAMP.  NOT A KERNEL BUILD: the fault this rung removes is in libobjc.
#
# 1031 READ (twice, byte-identical) CAL-CALLER-OTHER, and the static derivation named the fault:
# libobjc's table-rebase writer (fn 0x37C266EC) computes `count = (int32)header_word >> 1` == -1 for the
# optimised class (header word 0xFFFFFFFF = INDEX_NOT_FOUND), guards its copy loop only against
# count == 0, and runs ~2^32 stores off the stack end.  records/1031-caller-derivation.txt
# (I)(J)(M)(O)(P)(Q)(R)(S).  THE FIX IS IN USERSPACE: 10 bytes inside libobjc, in the dyld shared cache,
# in the rootfs the card serves.
#
# SO THIS SCRIPT BUILDS NO KERNEL.  It (1) reproduces the card image the press serves -- the real iOS 7.1.2
# HFSX rootfs, byte-for-byte -- (2) checks the cache header and the VA->card offset arithmetic BY VALUE,
# (3) writes the 10 bytes, and (4) reads them back OUT OF THE CARD at the offset the press copies from.
# The kernel arm is untouched: the press carries armed-d13-49031dcb (1031's own arm) verbatim, so the
# wrp_*/rdr_*/cal_* rows still publish on the fault path.  If the patch works they must now be ABSENT
# (there is no fault) -- that absence is the reading, and 1031's contributors are its own control.
#
# WHAT IT REFUSES: a card image that is not the real rootfs, a cache header that does not put map0 at
# 0x2C000000/fileOffset 0, or a site whose 10 bytes are neither the 1031 OLD guard nor the 1032 NEW one.
set -euo pipefail
cd "$(dirname "$0")/.."
LIVE=out/stage90
CARD=$LIVE/xnu_card_hfs.img
PATCHER=tools/patch_cache_libobjc_count.py

echo "== 1032: THE COUNT CLAMP (libobjc count < 0 returns instead of running away) =="
[[ -f $PATCHER ]] || { echo "REFUSING: $PATCHER is absent -- it is the whole edit"; exit 1; }

echo "-- 0. the patcher's own self-test (a checker that cannot fail is not a check) --"
python3 -I "$PATCHER" --selftest

# THE PARK-ONLY COPY.  park_1032.sh pins the editor's DEFINITION in the arm's park, but a copy of this
# file under a path-shaped name is refused by records/revert-set.txt, and a copy under its ORIGINAL name
# tells tools/verify_revert_set.sh the live tree must carry it.  So the park takes `park_`-prefixed copies
# derived HERE: identical bytes except the default image becomes REQUIRED (`--image` / explicit path), so
# the copy can never run against a default card path resolved through the park's own ../out.
PARKER=tools/park_cache_libobjc_count.py
sed 's|^DEFAULT_IMAGE = .*|DEFAULT_IMAGE = None  # park copy: the image argument is REQUIRED (no default card path)|' "$PATCHER" > "$PARKER.tmp"
grep -q '^DEFAULT_IMAGE = None' "$PARKER.tmp" || { echo "REFUSING: the park copy was not produced - $PATCHER no longer has a one-line DEFAULT_IMAGE"; rm -f "$PARKER.tmp"; exit 1; }
_diff=$(grep -v '^DEFAULT_IMAGE = ' "$PATCHER" | diff - <(grep -v '^DEFAULT_IMAGE = ' "$PARKER.tmp") | wc -l || true)
[[ $_diff == 0 ]] || { echo "REFUSING: the park copy differs from $PATCHER in more than the DEFAULT_IMAGE line"; rm -f "$PARKER.tmp"; exit 1; }
mv "$PARKER.tmp" "$PARKER"
python3 -I "$PARKER" --selftest >/dev/null || { echo "REFUSING: $PARKER --selftest failed (no-argument --selftest must still work)"; exit 1; }
echo "   $PARKER = $PATCHER with DEFAULT_IMAGE required (park copy for records/revert-set.txt; only the DEFAULT_IMAGE line differs)"

echo "-- 1. reproduce the card image (the real rootfs, byte-for-byte) --"
tools/build_root_volumes.sh --real
_rs=${STAGE90_REAL_ROOTFS:-/mnt/data/ios7-payload/v2/ios7/rootfs.hfs}
cmp "$CARD" "$_rs" || { echo "REFUSING: the card image is NOT a byte copy of $_rs -- the offset arithmetic (rootfs 0x455d000 + cache 0xbc26720) is only valid for that volume"; exit 1; }
echo "   card == rootfs ($(sha256sum "$CARD" | cut -c1-16)..., $(stat -c %s "$CARD") B)"

echo "-- 2. the cache header and the offset arithmetic, by value --"
python3 -I "$PATCHER" --check

echo "-- 3. write the 10 bytes (OLD -> NEW; refuses any other state, idempotent when already NEW) --"
python3 -I "$PATCHER" --apply

echo "-- 4. READ BACK OUT OF THE CARD IMAGE, at the offset the press dd's --"
# The press streams the whole image from byte 0, so the check is on the FILE THE PRESS READS, not on the
# rootfs it was copied from ([[mi4-one-value-two-definitions]]: the card IS the delivered value).
_site_hex=10183720
_site_dec=$((16#$_site_hex))
_expect=5010012801daf0bdc046
_got=$(dd if="$CARD" bs=1 skip=$_site_dec count=10 2>/dev/null | od -An -tx1 | tr -d ' \n')
[[ "$_got" == "$_expect" ]] || { echo "REFUSING: card offset 0x10183720 reads $_got, want $_expect"; exit 1; }
echo "   card 0x10183720 = $_got  (asrs r0,r2,#1 / cmp r0,#1 / bge.n +0xa / pop {r4-r7,pc} / nop)"
dd if="$CARD" bs=1 skip=$_site_dec count=10 2>/dev/null > /tmp/1032_site.bin
_de=$(arm-none-eabi-objdump -D -b binary -m arm -M force-thumb --adjust-vma=0x37c26720 /tmp/1032_site.bin 2>/dev/null | grep -cE 'asrs[[:space:]]+r0, r2, #1|cmp[[:space:]]+r0, #1|bge\.n[[:space:]]+0x37c2672a|pop[[:space:]]+\{r4, r5, r6, r7, pc\}' || true)
[[ "$_de" == "4" ]] || { echo "REFUSING: the four instructions at the card site do not disassemble as the design (matched $_de, want 4)"; exit 1; }
echo "   objdump of the card bytes: asrs / cmp / bge.n 0x37c2672a / pop  -- 4/4 instructions"

echo "-- 5. the kernel arm is NOT rebuilt (this rung changes no kernel object) --"
_arm=armed-d13-$(sha256sum "$LIVE/xnu_arm_entry.bin" | cut -c1-8)
echo "   arm = $_arm  (1031's arm: its fault-path probes must now stay SILENT, which is the reading)"

echo "== 1032 card image ready: $CARD =="
echo "   The 8 MiB read-back of userdata's head does NOT cover 0x10183720, so the press reads the"
echo "   PATCHED 10 BYTES back at that offset (scripts/press_1032.sh, step 2b')."