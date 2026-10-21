/*
 * 910c (first arm): the bulk STREAM - the one IN endpoint's payload becomes a cursor over the RAM
 * console's key/value ring, instead of the fixed 4-byte magic 910b sent forever.
 *
 * ------------------------------------------------------------------------------------------------
 * What this changes, and what it deliberately does not
 * ------------------------------------------------------------------------------------------------
 *
 * 910b (`entry_usb_enum.c`) arms EP0 and answers enumeration, and arms one bulk IN endpoint (EP1) whose
 * payload is, on every completion, the same `STAGE90_USB_ENUM_IN_MAGIC` word. This arm makes that
 * endpoint a **stream**: it takes its bytes from the RAM console ring the live channel itself publishes
 * into, so a host `read()` receives the boot's own `xnu_live_*` lines - a verdict measured from OUTSIDE
 * the phone, self-describing, which is the rung's whole point.
 *
 * It is a SEPARATE file from the enum arm for 910b's own reason: **the properties of one arm must be
 * properties of one file.** `entry_usb_enum.c` is provably "answers control, sends a fixed magic"; this
 * file is "moves a variable-length run with a cursor and back-pressure". The enum guard's clause ("EP1-IN
 * sends only the magic") stays true and checkable, and this arm's clause ("EP1-IN sends `[cursor,
 * cursor+len)` bounded by the ring's size") is a separate assertion over a separate file.
 *
 * **THE ENDPOINT IS HANDED OVER, NOT SHARED.** When this switch is ON the enum arm arms EP1's
 * endpoint-control register (enable) but does NOT prime it and does NOT re-prime it on completion
 * (`entry_usb_enum.c` guards both with `#if !STAGE90_XNU_USB_STREAM`), so EP1-IN has exactly ONE owner of
 * its qh and dTD at any time: the enum arm at arm time, this arm from the first stream prime on. A second
 * writer of the same qh would be the exact defect [[mi4-one-value-two-definitions]] names.
 *
 * ------------------------------------------------------------------------------------------------
 * P1: the ONE writer interface, and the SPSC ring behind it
 * ------------------------------------------------------------------------------------------------
 *
 * The design's P1 (records/usb-channel-plan.txt §5) gives the stream a single-producer/single-consumer
 * byte ring, 64 KiB, fed through ONE function - `entry_usb_stream_ring_publish(buf, len)` - that any
 * sink can call (the entry text today, XNU printfs later). The producer's rules, in the order they must
 * happen:
 *
 *   1. count what fits by `head - tail` and DROP the rest, counting every dropped byte (a dropped byte
 *      is a recorded READING, never silence);
 *   2. write the bytes, then a full `dmb` - the ring is read by the CORE, which bypasses the dcache, so
 *      the data must be in DRAM before the index that publishes it (this is also the clean point);
 *   3. publish `head` LAST, clean it, and read the consumer's `tail`.
 *
 * The consumer advances `tail` only by the dTD's `actual` count (the bytes the host accepted), never by
 * what was offered. **When the switch is OFF the source stays the RAM console ring** (910c's first arm,
 * forward-only cursor), because that path's bytes are what has been read on a device; either way the
 * `xnu_live_usb_stream_*` keys are FILE STATICS published at most once a second (`usb_stream_publish`)
 * instead of on every idle pass.
 *
 * ------------------------------------------------------------------------------------------------
 * The three stream changes (design §3)
 * ------------------------------------------------------------------------------------------------
 *
 * 1. **A page-aligned buffer, and the dTD `page[0]` beyond a constant.** `g_usb_stream_buf[4096]` is
 *    `aligned(4096)`, so `page[0]`'s low 12 bits are a well-defined in-page offset and one dTD - never a
 *    `page[1..4]` chain - covers a chunk of up to one page (the map §2.1 20 KiB spread is a later rung).
 * 2. **A cursor-driven re-prime, reading the dTD `token`'s ACTUAL count.** The vendor reads the arrived
 *    byte count from the dTD `token` - `actual = len - ((token & TD_TOTAL_BYTES) >> 16)` - and NEVER from
 *    `qh.curr` (`ci13xxx_udc.c:2176-2178`). So on completion this arm invalidates the dTD line, checks
 *    `TD_STATUS_ACTIVE` is clear, reads the count, and **advances the source cursor by `actual`** (the
 *    bytes the host accepted), not by the length it offered.
 * 3. **Back-pressure = leave `BIT(17)` unset.** The vendor never enables `USBi_NAKI`, so an unprimed
 *    endpoint makes the core NAK the host automatically - there is no register to write. The arm primes
 *    only when the source has bytes past the cursor, and never overwrites the buffer while the current
 *    dTD is still ACTIVE (writing the next chunk before the core finished DMA'ing the previous one
 *    silently corrupts both).
 *
 * ------------------------------------------------------------------------------------------------
 * The cache direction (the same discipline 910b paid)
 * ------------------------------------------------------------------------------------------------
 *
 * CPU -> core (the buffer, the dTD): **clean** with `CleanPoU_DcacheRegion` - the core reads DRAM.
 * core -> CPU (the dTD `token` the core updated): **invalidate** with `FlushPoC_DcacheRegion` - the same
 * PoC operation 910b uses for the SETUP bytes, and NOT `FlushPoU_Dcache`, which the seam wraps (910b
 * design §9.b). The RAM console is read with the CPU *and* written by the CPU-side `entry_write_kv`, so
 * no invalidate is needed for it: the CPU's own view is coherent.
 *
 * ------------------------------------------------------------------------------------------------
 * The gate
 * ------------------------------------------------------------------------------------------------
 *
 * Writes nothing unless the core is ALREADY a device (`USBMODE[1:0] == 2`, the 910a2 rule) AND the enum arm
 * has already enabled EP1 (its `ENDPTCTRL` TXE bit is set - the endpoint the enum arm enables on
 * `SET_CONFIGURATION`). Even with this switch ON and the enum arm OFF, this arm does not enable the
 * endpoint itself: it refuses and publishes why once, because enabling it here would be a second, silent
 * definition of "who owns EP1-IN". A build refusal in `build_entry.sh` stops the two switches being set
 * in an order that could leave the endpoint armed twice or not at all.
 */
#include <stdint.h>

#include "entry_usb_stream.h"

#ifndef STAGE90_XNU_USB_STREAM
#define STAGE90_XNU_USB_STREAM 0
#endif

extern void entry_live_write(const char *key, uint32_t value);
extern void CleanPoU_DcacheRegion(uintptr_t va, unsigned length);
extern void FlushPoC_DcacheRegion(uintptr_t va, unsigned length);
/* The kernel timebase's CNTVCT (`entry_timebase.c`, the one owner of the five CNTV* accesses) - used for
 * the once-a-second publication, so the keys reach the ring at a RATE rather than once per idle pass. */
extern uint64_t stage90_cntvct_read(void);
/*
 * The ENUM arm's `usb_enum_settle` var (its header §4), read the way the enum arm writes it - one
 * definition across two files. Rung 4 ("the stream's first chunk is primed") is waited HERE, once, after
 * the first `_armed`; `_last` past 3 is what makes it never back-to-back with rung 3.
 */
extern uint32_t g_usb_enum_settle;
extern uint32_t g_usb_enum_settle_last;
extern uint32_t g_usb_enum_settle_n;
extern uint32_t g_usb_enum_settle_gate;

/* ------------------------------------------------------------------------------------------------
 * The graph: one page-aligned buffer and one 32-byte-aligned dTD, both this arm's own. The qh is the
 * enum arm's array (the hardware has one endpoint list); the enum arm exports `entry_usb_enum_qh_in1()`
 * and this arm is its sole writer while the switch is on.
 * ------------------------------------------------------------------------------------------------
 */
static uint8_t g_usb_stream_buf[STAGE90_USB_STREAM_CHUNK]
    __attribute__((aligned(STAGE90_USB_STREAM_CHUNK)));
static uint8_t g_usb_stream_td[STAGE90_USB_ENUM_TD_STRIDE] __attribute__((aligned(32)));

/*
 * The ring (P1, header §3): `g_usb_stream_cursor` IS the consumer position (`tail`; its old name is kept
 * because the completion path and the console reading both already speak it), `g_usb_stream_head` the
 * producer's published position. Both are free-running BYTE counters and sit on their own cache lines.
 */
static volatile uint32_t g_usb_stream_cursor __attribute__((aligned(64)));  /* = tail.           */
/* the ring and its producer index exist only when there IS a ring consumer (switch ON); with it OFF a
 * defined-but-unused 64 KiB would be both dead weight and a claim the console path does not make. */
#if STAGE90_XNU_USB_STREAM
static uint8_t  g_usb_stream_ring[STAGE90_USB_STREAM_RING_SIZE]
    __attribute__((aligned(STAGE90_USB_STREAM_RING_SIZE)));
static volatile uint32_t g_usb_stream_head __attribute__((aligned(64)));
#endif

static uint32_t g_usb_stream_last;      /* bytes in the current chunk (offered to the core).     */
static uint32_t g_usb_stream_active;    /* 1 while a chunk's dTD is outstanding at the core.     */
static uint32_t g_usb_stream_chunks;    /* IN transfers completed.                               */
static uint32_t g_usb_stream_actual;    /* the last dTD's arrived count (the `token` read).      */
static uint32_t g_usb_stream_state;     /* a small published enum.                               */
static uint32_t g_usb_stream_dropped;   /* bytes the producer could not take: a READING, not a hole. */
static uint32_t g_usb_stream_published; /* records the publish has written (the throttle's witness).  */
static uint32_t g_usb_stream_pub_next;  /* CNTVCT low word at which the next publication is due.       */

#define USB_STREAM_ST_IDLE     0u   /* not a device yet.                         */
#define USB_STREAM_ST_WAITING  1u   /* a device; the endpoint is not enabled yet. */
#define USB_STREAM_ST_STREAM   2u   /* priming / re-priming chunks.               */
#define USB_STREAM_ST_DRAINED  3u   /* the source is consumed past the cursor.     */

/* 19.2 MHz is the rate this image's own `entry_counter` comment states (CNTVCT is that counter). */
#define USB_STREAM_CNTVCT_HZ            19200000u
#define USB_STREAM_PUBLISH_TICKS        ((uint64_t)USB_STREAM_CNTVCT_HZ)

static uint32_t usb_stream_read32(uint32_t off)
{
    return *(volatile uint32_t *)(uintptr_t)(STAGE90_USB_OTG_BASE + off);
}

static void usb_stream_write32(uint32_t off, uint32_t value)
{
    *(volatile uint32_t *)(uintptr_t)(STAGE90_USB_OTG_BASE + off) = value;
}

static volatile uint32_t *usb_stream_td(void)
{
    return (volatile uint32_t *)(uintptr_t)g_usb_stream_td;
}

#if STAGE90_XNU_USB_STREAM
/* The ring's full `dmb`: the bytes are in DRAM before the index that publishes them. */
static void usb_stream_ring_dmb(void)
{
    __asm__ volatile ("dmb" ::: "memory");
}
#endif

/*
 * The source's depth, by name once, with the two arms' definitions right beside each other: the ring's
 * `head - tail` when the switch is ON (free-running; a wrap of the sum is exact), the console ring's
 * `min(size, ceiling) - cursor` when it is OFF.
 */
static uint32_t usb_stream_available(void)
{
#if STAGE90_XNU_USB_STREAM
    return g_usb_stream_head - g_usb_stream_cursor;
#else
    {
        uint32_t size = *(volatile uint32_t *)(uintptr_t)(STAGE90_USB_STREAM_CONSOLE_VA
                                                          + STAGE90_USB_STREAM_OFF_SIZE);
        if (size > STAGE90_USB_STREAM_SIZE_MAX)
            size = STAGE90_USB_STREAM_SIZE_MAX;
        return (size > g_usb_stream_cursor) ? (size - g_usb_stream_cursor) : 0u;
    }
#endif
}

/* ================================================================================================
 * The publication - the stream's own counters, AT MOST ONCE PER SECOND of CNTVCT.
 * ================================================================================================
 * P1: the `xnu_live_usb_stream_*` keys used to be written into the ring on EVERY idle pass, so the ring
 * the stream reads grew at its own reading (ten-plus records a pass, mostly identical). The counters are
 * statics now and `usb_stream_publish` is the ONLY writer of these names; it runs on the pump's enter
 * (the WAITING branch included, so `waiting` is not silent) and returns without writing until CNTVCT
 * has advanced a second. The next deadline is stamped BEFORE any store, so a clock that fails to
 * advance can only delay the next publication, never repeat one within the same second.
 */
static void usb_stream_publish(void)
{
    uint32_t now = (uint32_t)stage90_cntvct_read();

    if ((int32_t)(now - g_usb_stream_pub_next) < 0)
        return;
    g_usb_stream_pub_next = now + (uint32_t)USB_STREAM_PUBLISH_TICKS;
    g_usb_stream_published++;

    entry_live_write("xnu_live_usb_stream_state", g_usb_stream_state);
    entry_live_write("xnu_live_usb_stream_cursor", g_usb_stream_cursor);
    entry_live_write("xnu_live_usb_stream_chunks", g_usb_stream_chunks);
    entry_live_write("xnu_live_usb_stream_actual", g_usb_stream_actual);
    entry_live_write("xnu_live_usb_stream_avail", usb_stream_available());
    entry_live_write("xnu_live_usb_stream_published", g_usb_stream_published);
    entry_live_write("xnu_live_usb_stream_dropped", g_usb_stream_dropped);
}

#if STAGE90_XNU_USB_STREAM

/* ------------------------------------------------------------------------------------------------
 * Prime one chunk: copy `len` bytes from the ring at the consumer's cursor into the buffer, build a
 * one-dTD one-page transfer, link it into the endpoint's qh, clean, and prime BIT(17).
 * ------------------------------------------------------------------------------------------------
 */
static void usb_stream_prime(uint32_t len)
{
    volatile uint32_t *td = usb_stream_td();
    volatile uint32_t *qh = entry_usb_enum_qh_in1();
    uint32_t token, cap, i;

    if (len > STAGE90_USB_STREAM_CHUNK)
        len = STAGE90_USB_STREAM_CHUNK;

    /* copy the bytes the producer published. Its `dmb` put them in DRAM before `head`; the invalidate
     * keeps a stale cached line from shadowing them (P2 may run the producer on another core). Nodes
     * are powers of two, so the index is a mask. */
    FlushPoC_DcacheRegion((uintptr_t)g_usb_stream_ring, STAGE90_USB_STREAM_RING_SIZE);
    for (i = 0u; i < len; i++)
        g_usb_stream_buf[i] = g_usb_stream_ring[(g_usb_stream_cursor + i) & STAGE90_USB_STREAM_RING_MASK];

    token = ((len & 0x7fffu) << STAGE90_USB_ENUM_TD_TOTAL_SHIFT)
            | STAGE90_USB_ENUM_TD_ACTIVE | STAGE90_USB_ENUM_TD_IOC;

    td[STAGE90_USB_ENUM_TD_OFF_NEXT / 4u]   = STAGE90_USB_ENUM_TD_TERMINATE;
    td[STAGE90_USB_ENUM_TD_OFF_TOKEN / 4u]  = token;
    td[STAGE90_USB_ENUM_TD_OFF_PAGE0 / 4u]  = (uint32_t)(uintptr_t)g_usb_stream_buf;

    /* CPU -> core: clean the dTD and the (one page) buffer the core will DMA. */
    CleanPoU_DcacheRegion((uintptr_t)td, STAGE90_USB_ENUM_TD_STRIDE);
    CleanPoU_DcacheRegion((uintptr_t)g_usb_stream_buf, STAGE90_USB_STREAM_CHUNK);

    /* the endpoint's qh: cap (ZLT | maxpacket(FS 64)) and the embedded link to this arm's dTD. The cap
     * value is the enum arm's for this endpoint; this arm is its one writer while the stream is on. */
    cap = STAGE90_USB_ENUM_QH_ZLT | STAGE90_USB_ENUM_QH_MAX_PKT(STAGE90_USB_ENUM_EP_IN_MAXPKT);
    qh[STAGE90_USB_ENUM_QH_OFF_CAP / 4u]    = cap;
    qh[STAGE90_USB_ENUM_QH_OFF_TDNEXT / 4u] = (uint32_t)(uintptr_t)td & ~0x1fu;
    qh[STAGE90_USB_ENUM_QH_OFF_TDTOK / 4u]  = 0u;
    CleanPoU_DcacheRegion((uintptr_t)qh, STAGE90_USB_ENUM_QH_STRIDE);

    g_usb_stream_last = len;
    g_usb_stream_active = 1u;
    g_usb_stream_state = USB_STREAM_ST_STREAM;

    usb_stream_write32(STAGE90_USB_ENDPTPRIME, STAGE90_USB_ENUM_EPBIT(STAGE90_USB_ENUM_EP_IN, 1u));
}

/* ------------------------------------------------------------------------------------------------
 * On completion: read the dTD's ACTUAL count, advance the cursor by it, clear the completion bit, and
 * re-prime iff the ring has more.
 * ------------------------------------------------------------------------------------------------
 */
static void usb_stream_complete(void)
{
    volatile uint32_t *td = usb_stream_td();
    uint32_t token, remaining, actual;

    /* core -> CPU: invalidate the dTD line the core updated (PoC, the operation 910b uses for SETUP). */
    FlushPoC_DcacheRegion((uintptr_t)td, STAGE90_USB_STREAM_TD_LEN);
    token = td[STAGE90_USB_ENUM_TD_OFF_TOKEN / 4u];

    /* the vendor's guard: a still-ACTIVE dTD is not done (`ci13xxx_udc.c:2134`). Re-poll next pass. */
    if ((token & STAGE90_USB_ENUM_TD_ACTIVE) != 0u)
        return;

    remaining = (token & STAGE90_USB_ENUM_TD_TOTAL_MASK) >> STAGE90_USB_ENUM_TD_TOTAL_SHIFT;
    actual = (g_usb_stream_last > remaining) ? (g_usb_stream_last - remaining) : 0u;

    g_usb_stream_actual = actual;
    /* advance by the bytes the HOST accepted, not by what we offered; with the ring ON this is also the
     * consumer's `tail`, and the `dmb` publishes it before the producer's next `head - tail` read. */
    g_usb_stream_cursor += actual;
    usb_stream_ring_dmb();
    FlushPoC_DcacheRegion((uintptr_t)&g_usb_stream_cursor, sizeof(g_usb_stream_cursor));
    g_usb_stream_chunks++;
    g_usb_stream_active = 0u;
    usb_stream_write32(STAGE90_USB_ENDPTCOMPLETE, STAGE90_USB_ENUM_EPBIT(STAGE90_USB_ENUM_EP_IN, 1u));

    if (usb_stream_available() == 0u)
        g_usb_stream_state = USB_STREAM_ST_DRAINED;   /* stop priming: the core NAKs the host. */
    else
        usb_stream_prime(usb_stream_available());
}

#else /* !STAGE90_XNU_USB_STREAM */

/* ------------------------------------------------------------------------------------------------
 * Prime one chunk from the RAM console ring: `available = min(size, ceiling) - cursor`, with `size` read
 * LIVE from the ring. A forward-only cursor (design §2): the ring is a monotonic append, so the source
 * only grows and the cursor only moves toward it. A wrap would need a second invariant this arm does not
 * take on.
 * ------------------------------------------------------------------------------------------------
 */
static void usb_stream_prime(uint32_t len)
{
    volatile uint32_t *td = usb_stream_td();
    volatile uint32_t *qh = entry_usb_enum_qh_in1();
    volatile uint8_t *src;
    uint32_t token, cap, i;

    if (len > STAGE90_USB_STREAM_CHUNK)
        len = STAGE90_USB_STREAM_CHUNK;

    /* copy the chunk out of the console ring (the console is CPU-coherent; a volatile read per byte,
     * appended by the CPU-side entry_write_kv, needs no invalidate - the CPU's own view is live). */
    src = (volatile uint8_t *)(uintptr_t)(STAGE90_USB_STREAM_CONSOLE_VA
                                          + STAGE90_USB_STREAM_OFF_DATA + g_usb_stream_cursor);
    for (i = 0u; i < len; i++)
        g_usb_stream_buf[i] = src[i];

    token = ((len & 0x7fffu) << STAGE90_USB_ENUM_TD_TOTAL_SHIFT)
            | STAGE90_USB_ENUM_TD_ACTIVE | STAGE90_USB_ENUM_TD_IOC;

    td[STAGE90_USB_ENUM_TD_OFF_NEXT / 4u]   = STAGE90_USB_ENUM_TD_TERMINATE;
    td[STAGE90_USB_ENUM_TD_OFF_TOKEN / 4u]  = token;
    td[STAGE90_USB_ENUM_TD_OFF_PAGE0 / 4u]  = (uint32_t)(uintptr_t)g_usb_stream_buf;

    /* CPU -> core: clean the dTD and the (one page) buffer the core will DMA. */
    CleanPoU_DcacheRegion((uintptr_t)td, STAGE90_USB_ENUM_TD_STRIDE);
    CleanPoU_DcacheRegion((uintptr_t)g_usb_stream_buf, STAGE90_USB_STREAM_CHUNK);

    cap = STAGE90_USB_ENUM_QH_ZLT | STAGE90_USB_ENUM_QH_MAX_PKT(STAGE90_USB_ENUM_EP_IN_MAXPKT);
    qh[STAGE90_USB_ENUM_QH_OFF_CAP / 4u]    = cap;
    qh[STAGE90_USB_ENUM_QH_OFF_TDNEXT / 4u] = (uint32_t)(uintptr_t)td & ~0x1fu;
    qh[STAGE90_USB_ENUM_QH_OFF_TDTOK / 4u]  = 0u;
    CleanPoU_DcacheRegion((uintptr_t)qh, STAGE90_USB_ENUM_QH_STRIDE);

    g_usb_stream_last = len;
    g_usb_stream_active = 1u;
    g_usb_stream_state = USB_STREAM_ST_STREAM;

    usb_stream_write32(STAGE90_USB_ENDPTPRIME, STAGE90_USB_ENUM_EPBIT(STAGE90_USB_ENUM_EP_IN, 1u));
}

static void usb_stream_complete(void)
{
    volatile uint32_t *td = usb_stream_td();
    uint32_t token, remaining, actual;

    FlushPoC_DcacheRegion((uintptr_t)td, STAGE90_USB_STREAM_TD_LEN);
    token = td[STAGE90_USB_ENUM_TD_OFF_TOKEN / 4u];

    /* the vendor's guard: a still-ACTIVE dTD is not done (`ci13xxx_udc.c:2134`). Re-poll next pass. */
    if ((token & STAGE90_USB_ENUM_TD_ACTIVE) != 0u)
        return;

    remaining = (token & STAGE90_USB_ENUM_TD_TOTAL_MASK) >> STAGE90_USB_ENUM_TD_TOTAL_SHIFT;
    actual = (g_usb_stream_last > remaining) ? (g_usb_stream_last - remaining) : 0u;

    g_usb_stream_actual = actual;
    g_usb_stream_cursor += actual;   /* advance by the bytes the HOST accepted, not by what we offered */
    g_usb_stream_chunks++;
    g_usb_stream_active = 0u;
    usb_stream_write32(STAGE90_USB_ENDPTCOMPLETE, STAGE90_USB_ENUM_EPBIT(STAGE90_USB_ENUM_EP_IN, 1u));

    if (usb_stream_available() == 0u)
        g_usb_stream_state = USB_STREAM_ST_DRAINED;   /* stop priming: the core NAKs the host. */
    else
        usb_stream_prime(usb_stream_available());
}

#endif /* STAGE90_XNU_USB_STREAM */

/* rung 4 - the stream's first chunk: waited ONCE, only if the enum var asks for it (4), the gate says
 * someone can answer, and rung 3 (EP1-IN's data) has stood aside - never two waits back to back. A
 * bounded busy-wait on CNTVCT: a delay, not a poll of a device. */
static void usb_stream_settle_wait4(void)
{
    uint32_t freq, t0, now;

    if (g_usb_enum_settle < 4u || g_usb_enum_settle_gate == 0u)
        return;
    if (g_usb_enum_settle_last >= 3u)
        return;
    g_usb_enum_settle_last = 4u;
    g_usb_enum_settle_n++;
    __asm__ volatile ("mrc p15, 0, %0, c14, c0, 0" : "=r"(freq));
    if (freq == 0u)
        return;
    t0 = (uint32_t)stage90_cntvct_read();
    do {
        now = (uint32_t)stage90_cntvct_read();
    } while ((uint32_t)(now - t0) < freq);
}

/* ------------------------------------------------------------------------------------------------
 * The poll - the one entry point, called from `__wrap_Idle_load_context` after `entry_usb_enum_poll`.
 * ------------------------------------------------------------------------------------------------
 */
void entry_usb_stream_poll(void)
{
    uint32_t usbmode, avail;

    /* the gate: a device, and the endpoint already ENABLED by the enum arm (not this one). */
    usbmode = usb_stream_read32(STAGE90_USB_USBMODE);
    if ((usbmode & STAGE90_USB_USBMODE_CM) != STAGE90_USB_USBMODE_CM_DEVICE) {
        g_usb_stream_state = USB_STREAM_ST_IDLE;
        return;
    }
    if ((usb_stream_read32(STAGE90_USB_ENDPTCTRL(STAGE90_USB_ENUM_EP_IN))
         & STAGE90_USB_ENDPTCTRL_TXE) == 0u) {
        if (g_usb_stream_state != USB_STREAM_ST_WAITING) {
            g_usb_stream_state = USB_STREAM_ST_WAITING;
            entry_live_write("xnu_live_usb_stream_waiting", 1u);   /* once per transition only */
        }
        usb_stream_publish();
        return;
    }

#if STAGE90_XNU_USB_STREAM
    /* A chunk outstanding: only a completion advances us. Otherwise prime the next if the ring has it. */
    if (g_usb_stream_active != 0u) {
        if ((usb_stream_read32(STAGE90_USB_ENDPTCOMPLETE)
             & STAGE90_USB_ENUM_EPBIT(STAGE90_USB_ENUM_EP_IN, 1u)) != 0u)
            usb_stream_complete();
    } else if ((avail = usb_stream_available()) != 0u) {
        /*
         * The producer refilled the ring after the last DRAINED: the pump MUST leave DRAINED and prime,
         * or a host that read to DRAINED and then waited would be NAKed forever while bytes sat in the
         * ring (the `_avail` reading reports exactly that state).
         */
        if (g_usb_stream_chunks == 0u) {
            entry_live_write("xnu_live_usb_stream_armed", 1u);   /* once, before the first chunk */
            usb_stream_settle_wait4();
        }
        usb_stream_prime(avail);
    } else if (g_usb_stream_state != USB_STREAM_ST_DRAINED) {
        g_usb_stream_state = USB_STREAM_ST_DRAINED;
    }
#else
    if (g_usb_stream_active != 0u) {
        if ((usb_stream_read32(STAGE90_USB_ENDPTCOMPLETE)
             & STAGE90_USB_ENUM_EPBIT(STAGE90_USB_ENUM_EP_IN, 1u)) != 0u)
            usb_stream_complete();
    } else if (g_usb_stream_state != USB_STREAM_ST_DRAINED) {
        avail = usb_stream_available();
        if (avail == 0u) {
            g_usb_stream_state = USB_STREAM_ST_DRAINED;
        } else {
            if (g_usb_stream_chunks == 0u) {
                entry_live_write("xnu_live_usb_stream_armed", 1u);
                usb_stream_settle_wait4();
            }
            usb_stream_prime(avail);
        }
    }
#endif

    usb_stream_publish();
}

/*
 * The producer's body - the ONE writer interface (header §3). Takes up to `len` bytes into the ring and
 * returns the count taken; what does not fit is counted in `xnu_live_usb_stream_dropped`. Calls no cache
 * primitive: the pump owns the clean/invalidate, so a caller that is not the pump is safe. `len == 0`
 * (with any `buf`) is a legal "flush the counters" call.
 */
uint32_t entry_usb_stream_ring_publish(const void *buf, uint32_t len)
{
    const uint8_t *src = (const uint8_t *)buf;
    uint32_t take = 0u;

#if STAGE90_XNU_USB_STREAM
    uint32_t head, used, room, i;
    head = g_usb_stream_head;
    FlushPoC_DcacheRegion((uintptr_t)&g_usb_stream_cursor, sizeof(g_usb_stream_cursor)); /* the tail */
    used = head - g_usb_stream_cursor;
    room = STAGE90_USB_STREAM_RING_SIZE - used;
    take = (len < room) ? len : room;
    for (i = 0u; i < take; i++)
        g_usb_stream_ring[(head + i) & STAGE90_USB_STREAM_RING_MASK] = src[i];
    usb_stream_ring_dmb();                 /* the bytes reach DRAM BEFORE `head` */
    g_usb_stream_head = head + take;       /* the publish: one store, after the barrier   */
    CleanPoU_DcacheRegion((uintptr_t)&g_usb_stream_head, sizeof(g_usb_stream_head));
    if (take < len)
        g_usb_stream_dropped += len - take;   /* counted: a reading, never silence            */
#else
    /* the console path has no ring consumer, so it takes nothing: every offered byte is a drop - a
     * reading, never silence - and the interface resolves for a sink linked against a switch-OFF image. */
    g_usb_stream_dropped += len;
    (void)src;
#endif
    return take;
}
