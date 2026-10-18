#!/usr/bin/env bash
# ====================================================================================================
# park_1032.sh.  MODELLED ON scripts/park_1031.sh (itself the 1015b/1029/1024 pattern), WITH THE PART
# THAT IS NOT: 1032 BUILDS NO KERNEL AND EDITS NO POOL FILE.
#
# **WHAT 1032 IS.**  The kernel arm is 1031's OWN, verbatim (armed-d13-49031dcb).  The rung is TEN BYTES in
# libobjc, inside the dyld shared cache embedded in the iOS 7.1.2 HFSX rootfs, carried to the device as the
# card image the press streams to userdata's head:
#     cache file offset 0x0BC26720 = VA 0x37C26720 = card offset 0x10183720
#     OLD  00 21 b1 eb 62 0f 08 bf f0 bd   movs r1,#0 / cmp.w r1,r2,asr#1 / it eq / popeq {r4-r7,pc}
#     NEW  50 10 01 28 01 da f0 bd c0 46   asrs r0,r2,#1 / cmp r0,#1 / bge.n +0xa / pop / nop
# count < 0 (header word INDEX_NOT_FOUND -> -1) now POPS instead of running a loop bounded by an unsigned
# count-1 (~2^32 stores off the stack end: the 1030 fault).  records/1031-caller-derivation.txt (I)-(S).
#
# **THE BY-VALUE PROOF OF 1032'S CHANGE IS THE CARD'S BYTES, NOT AN OBJECT'S STRINGS.**  1031's clauses
# read `strings` off pool objects because 1031 PRINTS.  1032 prints nothing new; it changes a shipped
# binary.  The equivalent by-value reads here are:
#   (0)  tools/patch_cache_libobjc_count.py --selftest PASSes and tools/check_1032_capture.py --selftest
#        PASSes -- a checker that cannot fail is not a check ([[mi4-a-claim-in-a-comment-is-not-a-check]]);
#   (1)  THE CARD IMAGE (the value the press delivers) carries NEW at 0x10183720, and differs from the
#        pristine rootfs in EXACTLY those 10 bytes ([[mi4-one-value-two-definitions]]: the card IS the
#        delivered value -- a rootfs that is patched while the card is not would read FIX-NOOP for a
#        reason that is the DELIVERY's);
#   (2)  THE CARD'S CACHE HEADER still puts map0 at VA 0x2C000000 / fileOffset 0 with the site inside
#        libobjc's __text and no code signature -- the offset arithmetic re-read, not assumed;
#   (3)  the 10 bytes DISASSEMBLE as the design in a fresh `objdump -D -b binary` at the VA;
#   (4)  THE KERNEL ARM IS 1031'S, BY CONTENT: the live out/stage90 members are byte-identical to the
#        frozen armed-d13-49031dcb park (so this press really does carry 1031's probes as its instrument),
#        the record still carries 1031's switch set, and the LINKED image still carries the cal/wrp
#        format strings the FIX-HOLDS cell is read FROM.
# Every inherited regression (NEON-free pool, 1024's ceiling, 1023's row 24, 1020's raise, ...) was
# asserted by park_1031 on THESE SAME BYTES; (4) is what makes that assertion carry forward to 1032
# rather than being re-derived.  [[mi4-self-written-record-is-not-a-constraint]]: (4) is the bytes.
#
# **THE CARD IS ~900 MiB AND IS NOT PARKED AS A COPY.**  The 10 bytes are pinned in THIS record (the
# `card_*` lines) and the image is reconstructible (build_root_volumes.sh --real + --apply); the park
# directory holds the two tools and their hashes so the edit's definition is frozen with the arm.
#
# **THE ARM NAME.**  1032 does NOT move the name (the arm name IS the entry bin's sha8 and the byte set is
# 1031's).  The record separates it from 1031 by ROLE and by the card lines, which name the SAME set --
# a second set name on the same artifact bytes would make tools/resolve_arm_set.sh find TWO sets for one
# directory (measured: it refuses two sets).  There is no frozen/armed-d13-49031dcb-1032 directory.
#
# THE 1032 VERDICT CELLS (tools/check_1032_capture.py --selftest asserts all of them):
#   FIX-HOLDS    no cal group AND launchd reached AND trap24/port_construct(result=0) live.
#   FIX-NOOP     the same 1031 cal frame (by value); a PATCH defect, not a delivery one.
#   FIX-PARTIAL  a cal frame that CHANGED; name it, patch nothing blind.
#   REGRESSION   panic / 1023 storm / launchd with no controls.
#   G-CTL/WITHHOLD  no positive evidence: fail closed, never a pass.
#
# Medium: 968 real iOS 7.1.2 HFSX rootfs over hfs_rmd0; CARD_COW=1, HDD_WRITE=0, the base is never
# written - fully reversible.  fastboot boot only, NEVER flash.
# ====================================================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

LIVE=out/stage90
REC=records/revert-set.txt
PARK=$LIVE/frozen/armed-d13-49031dcb
CARD=$LIVE/xnu_card_hfs.img
ROOTFS=${STAGE90_REAL_ROOTFS:-/mnt/data/ios7-payload/v2/ios7/rootfs.hfs}
PARKER=tools/park_cache_libobjc_count.py
PATCHER=tools/patch_cache_libobjc_count.py
CHECKER=tools/check_1032_capture.py
SITE_HEX=10183720
SITE_DEC=$((16#10183720))
NEW_HEX=5010012801daf0bdc046
OLD_HEX=0021b1eb620f08bff0bd

ARM=armed-d13-$(sha256sum "$LIVE/xnu_arm_entry.bin" | cut -c1-8)
[[ $ARM == armed-d13-49031dcb ]] || {
  echo "REFUSING: out/stage90 holds $ARM, not 1031's arm (armed-d13-49031dcb). 1032 builds NO kernel: it is 1031's arm with 10 bytes changed in libobjc.  A different arm means the pool moved and the probes this rung reads its absence FROM are not the ones certified. Restore/build 1031's arm first"; exit 1; }

# ====================================================================================================
# 1032'S OWN CHANGE, BY VALUE, FIRST - BEFORE EVERY INHERITED CLAUSE.
# ====================================================================================================
echo "== 1032's OWN change, by value, first =="

# (0) the two checkers can fail.  Absent = refusal, not a skip.
[[ -f $PATCHER ]] || { echo "REFUSING: $PATCHER is ABSENT - it is 1032's whole edit and the definition of the 10 bytes"; exit 1; }
[[ -f $CHECKER ]] || { echo "REFUSING: $CHECKER is ABSENT - it is the capture reader the press is adjudicated by; without it the rung's own claim has no machine check"; exit 1; }
python3 -I "$PATCHER" --selftest >/dev/null 2>&1 || { echo "REFUSING: $PATCHER --selftest did NOT PASS - the patcher cannot tell OLD from NEW from OTHER"; exit 1; }
python3 -I "$CHECKER" --selftest >/dev/null 2>&1 || { echo "REFUSING: $CHECKER --selftest did NOT PASS - the 1032 reader cannot fire its cells (an inert reader would bless any capture)"; exit 1; }
echo "   BY VALUE(0): $PATCHER --selftest and $CHECKER --selftest PASS"

# (1) THE CARD IS THE DELIVERED VALUE.
[[ -f $CARD ]] || { echo "REFUSING: $CARD is absent - nothing to park and nothing to serve. Run tools/build_root_volumes.sh --real then $PATCHER --apply"; exit 1; }
[[ -f $ROOTFS ]] || { echo "REFUSING: the pristine rootfs $ROOTFS is absent - the 'differs in exactly 10 bytes' clause has nothing to compare against"; exit 1; }
_card10=$(dd if="$CARD" bs=1 skip=$SITE_DEC count=10 2>/dev/null | od -An -tx1 | tr -d ' \n')
[[ $_card10 == "$NEW_HEX" ]] || {
  echo "REFUSING: the CARD at 0x$SITE_HEX holds $_card10, not 1032's NEW guard $NEW_HEX.  The card is what the press dd's, so a park of it would freeze (and a press of it would re-measure) 1031. Run scripts/build_1032.sh"; exit 1; }
_root10=$(dd if="$ROOTFS" bs=1 skip=$SITE_DEC count=10 2>/dev/null | od -An -tx1 | tr -d ' \n')
[[ $_root10 == "$OLD_HEX" ]] || {
  echo "REFUSING: the pristine rootfs at 0x$SITE_HEX holds $_root10, not the OLD guard $OLD_HEX.  This rootfs is not the one the offset arithmetic was derived on; the site is not the guard"; exit 1; }
# `|| true` INSIDE the substitution is load-bearing: `cmp` exits 1 WHENEVER the files DIFFER, and
# `set -euo pipefail` here would abort on the GOOD case (the first run of this park stopped here).
_ndiff=$(cmp -l "$CARD" "$ROOTFS" 2>/dev/null | wc -l || true)
_diffat=$(cmp -l "$CARD" "$ROOTFS" 2>/dev/null | awk '{printf "%#x ", $1-1}' || true)
[[ $_ndiff == 10 ]] || {
  echo "REFUSING: the card differs from the pristine rootfs in $_ndiff bytes (at: $_diffat), want EXACTLY 10.  Either the patch is not in the card, or something else changed the image under this rung.  The 10-byte arithmetic is only valid for the pristine rootfs"; exit 1; }
echo "   BY VALUE(1): card 0x$SITE_HEX = $_card10 (NEW), rootfs = $_root10 (OLD), and the card differs from the rootfs in EXACTLY $_ndiff bytes at $_diffat"

# (2) the cache header the offset arithmetic rests on - re-read out of the CARD.
python3 -I "$PATCHER" --check >/dev/null 2>&1 || { echo "REFUSING: $PATCHER --check FAILED on the card - HFSX/magic/map0 (0x2c000000, fileOffset 0)/__text containment/code signature is not what 1032 was written against.  The site bytes above could be NEW for the wrong reason (a different image)"; exit 1; }
echo "   BY VALUE(2): the patcher --check PASSes on the card (HFSX, dyld_v1 armv7, map0 0x2c000000/0, site inside __text, no code signature)"

# (3) the 10 bytes DISASSEMBLE as the design in a FRESH decode (not the patcher's own table).
dd if="$CARD" bs=1 skip=$SITE_DEC count=10 2>/dev/null > /tmp/1032_park_site.bin
_de=$(arm-none-eabi-objdump -D -b binary -m arm -M force-thumb --adjust-vma=0x37c26720 /tmp/1032_park_site.bin 2>/dev/null \
      | grep -cE 'asrs[[:space:]]+r0, r2, #1|cmp[[:space:]]+r0, #1|bge\.n[[:space:]]+0x37c2672a|pop[[:space:]]+\{r4, r5, r6, r7, pc\}' || true)
[[ $_de == 4 ]] || { echo "REFUSING: the card site decodes as $_de/4 of the design's instructions (asrs / cmp #1 / bge.n 0x37c2672a / pop). The bytes are NEW but the design inside them is not what the fix reasoning proved"; exit 1; }
echo "   BY VALUE(3): a fresh objdump of the card's 10 bytes: asrs r0,r2,#1 / cmp r0,#1 / bge.n 0x37c2672a / pop  -- 4/4"

# (4) THE KERNEL ARM IS 1031'S, BY CONTENT.
for m in xnu_arm_entry.bin xnu_arm_entry.elf xnu_arm_entry-config.txt stage90.bin stage90.elf \
         stage90.img stage90-qcdt.img stage90-build-config.txt SHA256SUMS.txt xnu_arm_entry-sources.txt \
         xnu_arm_entry-arm-extra.txt xnu_arm_entry.h stage90_fixture.macho; do
  [[ -f $PARK/$m ]] || { echo "REFUSING: the frozen 1031 park lacks $m - 1032 cannot prove its kernel arm is 1031's by content"; exit 1; }
  cmp -s "$LIVE/$m" "$PARK/$m" || { echo "REFUSING: out/stage90/$m differs from the frozen armed-d13-49031dcb park's copy. 1032 changes no kernel byte; a moved member means the pool/image was rebuilt and the arm name above is a coincidence, not an identity. Rebuild 1031 exactly, or re-park deliberately"; exit 1; }
done
# The instrument's own rows must be reachable from the LINKED image (the FIX-HOLDS cell reads the cal
# group's ABSENCE and the controls' PRESENCE from this very image).
for _s in '^xnu_live_cal_r3=' '^xnu_live_wrp_r4=' '^xnu_live_abt_lookup_far='; do
  grep -qa "$_s" <(strings "$LIVE/xnu_arm_entry.elf") || { echo "REFUSING: the LINKED image carries no $_s string - the probe the FIX-HOLDS/NOOP cells are read from is not in the image the press boots"; exit 1; }
done
for _k in '^STAGE90_XNU_CALLER_PROBE=1$' '^STAGE90_XNU_WRITER_PROBE=1$' '^STAGE90_XNU_READER_PROBE=1$' \
          '^STAGE90_XNU_H2_STACK_HEADROOM=1$' '^STAGE90_XNU_ABT_ENTRY_PROBE=1$' '^STAGE90_XNU_USTACK_PROBE=1$' \
          '^STAGE90_XNU_VM_MAX_SPLIT=1$' '^STAGE90_XNU_IOS7_TRAPS=1$' '^STAGE90_XNU_GENERAL_REGS=1$'; do
  grep -q "$_k" "$LIVE/xnu_arm_entry-config.txt" || { echo "REFUSING: the record lost $_k - the card patch is only readable through 1031's instrument, and this record is not 1031's set verbatim"; exit 1; }
done
echo "   BY VALUE(4): all 13 kernel members are byte-identical to the frozen 1031 park; the linked image carries cal/wrp/lookup_far; the record carries 1031's switch set"

# ---- THE INHERITED REGRESSIONS, carried from park_1031 by CONTENT (4), not re-derived.
python3 -I tools/check_d13_no_neon.py --pool out/xnu_kernel_obj_d13 --expect none --min-objects 1 >/dev/null 2>&1 || {
  echo "REFUSING: the pool is no longer NEON-free - 1021d's -msoft-float has moved under 1031's frozen bytes (impossible if (4) passed unless the pool dir itself was rebuilt). 1032 reuses 1031's park; re-verify before pressing"; exit 1; }
echo "   INHERITED: the pool is NEON-free (1021d) and 1031's park is byte-identical (so 1024/1023/1020's by-value clauses hold on the same bytes park_1031 certified)"

# ====================================================================================================
# THE RECORD - appended BEFORE the press.  A park that is not recorded is a park nothing can revert to.
# ====================================================================================================
grep -q "role=1032-count-clamp" "$REC" && { echo "REFUSING: $REC already carries a 1032-count-clamp block - not appending twice"; exit 1; }

# THE PARK: 1031's 13 kernel members stay at the park root (byte-identical copies) and the two 1032
# editors sit beside them, named as the record names them (`file=` takes no path separator):
#   park_cache_libobjc_count.py   derived by build_1032.sh from the live patcher, default card path
#                                 removed; `park_`-prefixed so it cannot be mistaken for, or run as,
#                                 the live tool (which uses the default card path)
#   check_1032_capture.py         a copy of tools/check_1032_capture.py.  This name is the LIVE tool's
#                                 too, and the record's line for it is a claim about BOTH directories
#                                 (verify_revert_set.sh reads one at a time), so a park-only line would
#                                 be false of the live tree (measured).  The live tree has no park of its
#                                 own, so THAT line is unsatisfied in out/stage90 - stated, not hidden:
#                                 the park is the directory this set is verified in (VERIFIED, 28 files).
[[ -f $PARKER ]] || { echo "REFUSING: $PARKER is absent - run scripts/build_1032.sh, which derives it from $PATCHER"; exit 1; }
[[ ! -e $PARK/patch_cache_libobjc_count.py ]] || { echo "REFUSING: $PARK/patch_cache_libobjc_count.py exists - that name is the LIVE tool's"; exit 1; }
[[ ! -e $PARK/frozen_check_1032_capture.py ]] || { echo "REFUSING: $PARK/frozen_check_1032_capture.py exists - a name nothing records"; exit 1; }
cp -p "$PARKER" "$PARK/park_cache_libobjc_count.py"
cp -p "$CHECKER" "$PARK/check_1032_capture.py"
cmp -s "$PARKER" "$PARK/park_cache_libobjc_count.py" || { echo "REFUSING: the park's editor copy differs from $PARKER"; exit 1; }
cmp -s "$CHECKER" "$PARK/check_1032_capture.py" || { echo "REFUSING: the park's checker copy differs from $CHECKER"; exit 1; }
# The live tool must still be the recorded definition (a tool edited after the park would leave the
# arm certifying bytes nobody sent).
[[ $(sha256sum "$CHECKER" | awk '{print $1}') == $(sha256sum "$PARK/check_1032_capture.py" | awk '{print $1}') ]] || { echo "REFUSING: live $CHECKER and the park copy differ"; exit 1; }
printf 'park=%s card_sha256=%s card_bytes=%s\n' "$PARK" "$(sha256sum "$CARD" | awk '{print $1}')" "$(stat -c %s "$CARD")" > "$PARK/1032-park.txt"

CARD_SHA=$(sha256sum "$CARD" | awk '{print $1}')
CARD_BYTES=$(stat -c %s "$CARD")
{
  printf '\n'
  printf '# =================================================================================================\n'
  printf '# 1032 - THE COUNT CLAMP, IN libobjc, INSIDE THE dyld SHARED CACHE THE CARD DELIVERS.  2026-10-18.\n'
  printf '# NO KERNEL BUILD.  The arm is 1031-s own (armed-d13-49031dcb) verbatim: its cal_*/wrp_*/rdr_*\n'
  printf '# probes are the INSTRUMENT, and the success cell is their ABSENCE with launchd up and the\n'
  printf '# trap24/port_construct controls live (tools/check_1032_capture.py).\n'
  printf '# THE CHANGE: 10 bytes at cache file offset 0x0BC26720 = VA 0x37C26720 = card offset 0x10183720\n'
  printf '#   OLD 0021b1eb620f08bff0bd  movs r1,#0 / cmp.w r1,r2,asr#1 / it eq / popeq {r4-r7,pc}\n'
  printf '#   NEW %s  asrs r0,r2,#1 / cmp r0,#1 / bge.n +0xa / pop {r4-r7,pc} / nop\n' "$NEW_HEX"
  printf '#   (returns for count<1; the OLD guard returned only for count==0, and count<0 fell into a loop\n'
  printf '#    bounded by unsigned count-1 = ~2^32 stores off the stack end. records/1031-caller-derivation.txt\n'
  printf '#    (I)-(S); the bytes are the assembler-s with a symbolic label (P).)\n'
  printf '# THE BY-VALUE PROOF (park_1032.sh): card 0x10183720 == NEW, pristine rootfs == OLD, card differs\n'
  printf '# from rootfs in EXACTLY 10 bytes; the patcher --check PASSes on the card; a fresh\n'
  printf '# objdump decodes asrs/cmp/bge.n/pop 4/4; all 13 kernel members byte-identical to the frozen\n'
  printf '# armed-d13-49031dcb park; linked image carries cal/wrp/lookup_far; record carries 1031-s switches.\n'
  printf '# THE PARK holds the two tools (the edit-s definition), not the 900 MiB card (reconstructible).\n'
  printf '# THE VERIFY: tools/verify_revert_set.sh out/stage90/frozen/armed-d13-49031dcb --set=armed-d13-49031dcb\n'
  printf '#   = VERIFIED, 28 file(s).  The park is the directory this set is verified in: the checkers file=\n'
  printf '#   line is also the LIVE tools/check_1032_capture.py, and no park can carry a copy into out/stage90\n'
  printf '#   without becoming a file the gate reads (both directions were measured and are refused).\n'
  printf '# Revert the card: python3 -I tools/patch_cache_libobjc_count.py --revert ; then re-apply/build per whichever press is next.\n'
  printf '# fastboot boot only, NEVER flash. =================================================================\n'
  for m in xnu_arm_entry.bin xnu_arm_entry.elf xnu_arm_entry.h xnu_arm_entry-config.txt \
           xnu_arm_entry-arm-extra.txt xnu_arm_entry-sources.txt stage90.bin stage90.elf stage90.img \
           stage90-qcdt.img stage90_fixture.macho stage90-build-config.txt SHA256SUMS.txt; do
    h=$(sha256sum "$LIVE/$m" | awk '{print $1}'); b=$(stat -c %s "$LIVE/$m")
    printf 'set=%s sha256=%s bytes=%s file=%s role=1032-count-clamp;%s\n' "$ARM" "$h" "$b" "$m" "$m"
  done
  _nom=$(basename "$PARKER"); _h=$(sha256sum "$PARKER" | awk '{print $1}'); _b=$(stat -c %s "$PARKER")
  printf 'set=%s sha256=%s bytes=%s file=%s role=1032-count-clamp-editors-definition\n' "$ARM" "$_h" "$_b" "$_nom"
  _nom=check_1032_capture.py; _h=$(sha256sum "$CHECKER" | awk '{print $1}'); _b=$(stat -c %s "$CHECKER")
  printf 'set=%s sha256=%s bytes=%s file=%s role=1032-count-clamp-capture-reader\n' "$ARM" "$_h" "$_b" "$_nom"
  printf '# CACHE the card serves (the delivered value). Not a file named in out/stage90/frozen/ - the card\n'
  printf '# is ~900 MiB and is rebuilt by build_root_volumes.sh --real + %s --apply:\n' "$PATCHER"
  # A COMMENT, not a line field: tools/verify_revert_set.sh REFUSES an unknown key=value field (measured:
  # 'card_set=...' refused at the append's own line), and the card is not a park member.  The bytes are
  # pinned here for a reader and are checked by park_1032.sh's BY VALUE (1)-(3) and press_1032.sh (0g).
  printf '# card_set=%s card_sha256=%s card_bytes=%s card_off=0x%s card_old=%s card_new=%s card_rootfs_sha256=%s\n' \
    "$ARM" "$CARD_SHA" "$CARD_BYTES" "$SITE_HEX" "$OLD_HEX" "$NEW_HEX" "$(sha256sum "$ROOTFS" | awk '{print $1}')"
} >> "$REC"

echo "recorded $ARM (role=1032-count-clamp) in $REC; card sha256=$(cut -c1-16 <<<"$CARD_SHA")... ${CARD_BYTES} B"
echo "parked $ARM (1031's 13 members + $(basename "$PATCHER") + $(basename "$CHECKER")) at $PARK"