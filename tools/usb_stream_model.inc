/* ------------------------------------------------------------------------------------------------
 * tools/usb_stream_model.inc - the CORE and the HOST, for tools/check_usb_stream.py's host model.
 * ------------------------------------------------------------------------------------------------
 * ONE function `model_run(int group)` and one case per group. It is generated TWICE, as two translation
 * units of the same image (`model_a.c`, `model_b.c`), so every name below is `static` and the two copies
 * cannot collide - and each copy drives its OWN copy of the arm: the arm's file is `#include`d once per
 * copy, from a different translation unit, with that copy's name prefix. The arm's identifiers reach this
 * file as macros the glue (the generated `model_a.c`) `#define`s between the two includes; nothing here
 * names an arm identifier directly, so this file compiles against either copy unchanged. The glue's names:
 *
 *   MODEL_ARM_TD       the arm's dTD (bytes)
 *   MODEL_ARM_PRIME    the core's view of ENDPTPRIME (raised by the arm's stores, cleared by the core)
 *   MODEL_ARM_ACNTR    the core's ENDPTCOMPLETE bits (raised by the core, W1C by the arm)
 *   MODEL_ARM_NOW      the arm's clock input (one store per poll pass)
 *   MODEL_ARM_RING(k)  the arm's ring (byte k)
 *   MODEL_ARM_HEAD, _CURSOR, _CHUNKS, _DROPPED, _PUBLISHED, _PUB_NEXT, _STATE, _ACTIVE
 *   MODEL_ARM_PUBLISH(buf, len)   the arm's ONE producer interface
 *   MODEL_RUN(pc)      one poll pass: `pc` host IN tokens, the host stops, 1 ms of clock, the arm's poll
 *   MODEL_RESET()      the arm's statics to their reset state
 *   MODEL_HZ           the arm's CNTVCT rate;
 *   MODEL_GROUPS       the `case` lines of `model_run` (one per case, below)
 *
 * The model is written from the OWNER's rules (`ci13xxx_udc.c`), not from the arm:
 *   - the qh links a dTD; the core fetches it when the endpoint is PRIMED (`ENDPTPRIME`, bit 17);
 *   - an IN token with nothing primed (or a dTD no longer ACTIVE) is a NAK - the vendor's automatic NAK
 *     on an unprimed endpoint, the mechanism the arm's back-pressure relies on;
 *   - a token moves `min(offered, maxpacket)` bytes; `maxpacket` is the arm's own FS 64, and a dTD whose
 *     TOTAL_BYTES is at or under it is one packet - everything (the arm always sets ZLT) - so an offered
 *     count under one packet still moves;
 *   - the CORE, not the CPU, clears ACTIVE and raises the endpoint's ENDPTCOMPLETE bit, and only the
 *     CPU's ENDPTCOMPLETE acknowledge (W1C) clears it;
 *   - the host never takes more than it asked for (`offered`), whatever the dTD offers;
 *   - the dTD is the ARM's: the model reads the bytes the arm wrote, with the core's own byte order, and
 *     writes the `token` back the way the core does.
 * The host is a script: per poll pass, `pc` IN tokens, each accepted only while the endpoint is primed
 * (anything else is a NAK, which the non-racing cases make a FAILURE - no case here may NAK while bytes
 * are still offered). The harness is compiled with the HOST's clang and run; nothing is Python.
 */
#include <stdio.h>
#include <string.h>

/* the glue's (a missing one is a compile error where the glue names it) */
#ifndef MODEL_HZ
#error model: MODEL_HZ is not defined
#endif
#ifndef MODEL_RUN
#error model: MODEL_RUN is not defined
#endif
#ifndef MODEL_RESET
#error model: MODEL_RESET is not defined
#endif
#ifndef MODEL_GROUPS
#error model: MODEL_GROUPS is not defined
#endif

#define MODEL_SRC_LEN  %(source_len)d
#define MODEL_NKEYS    %(nkeys)d

/* the case's bookkeeping: this file's, one copy each */
static uint8_t  model_out[MODEL_SRC_LEN + 64u];
static uint32_t model_naks, model_primed, model_out_n, model_offered;
/* the current dTD's original length: the countdown in its token gives the offset into the page */
static uint32_t model_seg_len;
static int      model_failed, model_case_fail;

static void model_fail(const char *what)
{
    printf("      FAIL %%s\n", what);
    model_failed = 1;
    model_case_fail = 1;
}

static void model_expect(const char *what, uint32_t got, uint32_t want)
{
    if (got != want) {
        char buf[160];
        snprintf(buf, sizeof(buf), "%%s: got 0x%%x want 0x%%x", what, got, want);
        model_fail(buf);
    }
}

/* the source's bytes, by a rule of this file's own: `model_src_byte(i)` needs no table to re-derive */
static uint8_t model_src_byte(uint32_t i)
{
    return (uint8_t)(0x5au * (uint8_t)(i * 7u + 11u) + (uint8_t)(i / 3u));
}

static uint32_t model_td_field(uint32_t off)
{
    return (uint32_t)MODEL_ARM_TD[off] | ((uint32_t)MODEL_ARM_TD[off + 1u] << 8)
           | ((uint32_t)MODEL_ARM_TD[off + 2u] << 16) | ((uint32_t)MODEL_ARM_TD[off + 3u] << 24);
}

static void model_td_store(uint32_t off, uint32_t v)
{
    MODEL_ARM_TD[off] = (uint8_t)(v & 0xffu);
    MODEL_ARM_TD[off + 1u] = (uint8_t)((v >> 8) & 0xffu);
    MODEL_ARM_TD[off + 2u] = (uint8_t)((v >> 16) & 0xffu);
    MODEL_ARM_TD[off + 3u] = (uint8_t)((v >> 24) & 0xffu);
}

/* one host IN token: 0 = the core moved bytes (or finished the dTD), 1 = NAK */
static int model_host_in_once(void)
{
    uint32_t t = model_td_field(STAGE90_USB_ENUM_TD_OFF_TOKEN);
    uint32_t total = (t & STAGE90_USB_ENUM_TD_TOTAL_MASK) >> STAGE90_USB_ENUM_TD_TOTAL_SHIFT;
    uint32_t n, k;
    uint8_t *page = (uint8_t *)(uintptr_t)model_td_field(STAGE90_USB_ENUM_TD_OFF_PAGE0);

    /* **A NAK with nothing primed is the NORMAL answer** - the host polled before the arm had
     * anything to send, which is most of the time on a real bus. Only a primed-but-inactive dTD is a
     * defect (the arm offered a transfer the core cannot fetch). The old code returned 1 for both,
     * and model_pass treats 1 as a case failure, so the first pass of every case failed before the
     * arm had ever been polled once: the model never reached the arm's poll at all. */
    if (MODEL_ARM_PRIME == 0u && (t & STAGE90_USB_ENUM_TD_ACTIVE) == 0u) {
        model_naks++;
        return 0;                                   /* nothing offered yet: a plain NAK */
    }
    if ((t & STAGE90_USB_ENUM_TD_ACTIVE) == 0u) {
        model_naks++;
        return 1;                                   /* primed but not ACTIVE: the arm's defect */
    }
    model_primed++;
    /* **The dTD's total is a COUNTDOWN, so the offset into the page is the segment length minus
     * what is left.** Reading `page[0]` every time is what the model did, and it re-sent the first
     * packet over and over: the host received 64 copies of byte 0 and the order check reported
     * "out of order or corrupted". On real hardware the DMA engine advances its own address; here the
     * model has to, and the countdown in the token is exactly the bookkeeping that says how far.
     * The segment's own length is remembered when a dTD first becomes ACTIVE. */
    if ((t & STAGE90_USB_ENUM_TD_ACTIVE) != 0u && model_seg_len == 0u)
        model_seg_len = total;
    n = (total < STAGE90_USB_ENUM_EP_IN_MAXPKT) ? total : STAGE90_USB_ENUM_EP_IN_MAXPKT;
    if (n == 0u)
        n = total;                                      /* one packet, ZLT: take everything */
    /* **The host stops asking after `model_offered` bytes: that ends the transfer with a SHORT
     * packet and the arm completes it.** A real dTD carries the count the core actually moved, and
     * the core retires the dTD (ACTIVE clear, ACTUAL set) when the host ACKs a short transfer - the
     * arm's complete() then advances the cursor by ACTUAL, not by the length it primed. Without this
     * the model took 100 bytes and left the dTD ACTIVE with 500 still "to send", so the arm never
     * completed, the cursor never moved, and the re-prime resumed at 0 (case D's failure). */
    if (model_offered == 0u) {
        if ((t & STAGE90_USB_ENUM_TD_ACTIVE) != 0u) {
            /* **Retire it with the countdown LEFT AS IT IS.** The arm computes
             * `actual = last - remaining` (usb_stream_complete), so `remaining` is what the core did
             * NOT move: keeping it means the arm advances by exactly what the host took. Zeroing the
             * countdown - which the first attempt did - told the arm the whole segment had gone and
             * moved the cursor to 600 instead of 100. Only ACTIVE clears. */
            model_td_store(STAGE90_USB_ENUM_TD_OFF_TOKEN,
                           t & ~(uint32_t)STAGE90_USB_ENUM_TD_ACTIVE);
            MODEL_ARM_ACNTR |= STAGE90_USB_ENUM_EPBIT(STAGE90_USB_ENUM_EP_IN, 1u);
            MODEL_ARM_PRIME = 0u;
            model_seg_len = 0u;
        }
        model_naks++;
        return 0;
    }
    if (n > model_offered)                              /* the host never takes more than it asked for */
        n = model_offered;
    for (k = 0; k < n; k++)
        model_out[model_out_n++] = page[(model_seg_len - total) + k];
    model_offered -= n;
    total -= n;
    model_td_store(STAGE90_USB_ENUM_TD_OFF_TOKEN,
                   (t & ~STAGE90_USB_ENUM_TD_TOTAL_MASK) | (total << STAGE90_USB_ENUM_TD_TOTAL_SHIFT));
    if (total == 0u) {
        model_td_store(STAGE90_USB_ENUM_TD_OFF_TOKEN,
                       (t & ~(STAGE90_USB_ENUM_TD_TOTAL_MASK | STAGE90_USB_ENUM_TD_ACTIVE))
                       | (total << STAGE90_USB_ENUM_TD_TOTAL_SHIFT));
        MODEL_ARM_ACNTR |= STAGE90_USB_ENUM_EPBIT(STAGE90_USB_ENUM_EP_IN, 1u);   /* ENDPTCOMPLETE */
        MODEL_ARM_PRIME = 0u;
        model_seg_len = 0u;                         /* the next dTD is a new segment */
    }
    return 0;
}

static void model_check_order(void)
{
    uint32_t i;
    for (i = 0u; i < model_out_n; i++)
        if (model_out[i] != model_src_byte(i)) {
            model_fail("the bytes arrived out of order or corrupted");
            return;
        }
}

/* (a) the host's pass cadence: `pc` = 0, 1, 2 tokens between polls. 600 bytes in the ring at head = 600;
 * poll (bounded) until DRAINED; every byte arrives, in order, one chunk of segments at pc = 0 and one per
 * packet otherwise; the cursor is every byte offered; the state ends DRAINED (nothing else to prime). */
static int model_case_cadence(uint32_t pc)
{
    uint32_t p, i;

    model_out_n = 0u;
    model_offered = 600u;
    for (i = 0u; i < 600u; i++)
        MODEL_ARM_RING(i) = model_src_byte(i);
    MODEL_ARM_HEAD = 600u;
    for (p = 0u; p < 300u && MODEL_ARM_STATE != USB_STREAM_ST_DRAINED; p++)
        MODEL_RUN(pc);
    /* **pc == 0 means the host issues NO IN token, so nothing can arrive; that is the case's whole
     * point ("the host idles between polls").** It asserted 600 bytes arrived regardless, which no
     * transport can deliver without the host asking - a correct arm failed it. What pc == 0 must show
     * is the other half: the arm primes without being asked (one dTD, state STREAM), the bytes it
     * copied are the ring's, the cursor has NOT advanced (the cursor moves on completion, and there
     * was no completion), and the host took nothing. The pc >= 1 cases below are the ones that must
     * deliver all 600. */
    if (pc == 0u) {
        model_expect("pc=0: the host took nothing (it never asked)", model_out_n, 0u);
        model_expect("pc=0: the arm primed without being asked", MODEL_ARM_ACTIVE, 1u);
        model_expect("pc=0: the stream is running, not stalled", MODEL_ARM_STATE, USB_STREAM_ST_STREAM);
        model_expect("pc=0: the cursor has not advanced (advance is on completion)",
                     MODEL_ARM_CURSOR, 0u);
        model_expect("pc=0: the bytes offered are still all there", MODEL_ARM_HEAD, 600u);
        return model_case_fail;
    }
    if (model_out_n != 600u) {
        char buf[96];
        snprintf(buf, sizeof(buf), "pc=%%u: %%u of 600 bytes arrived", pc, model_out_n);
        model_fail(buf);
    }
    model_check_order();
    model_expect("the cursor is every byte offered", MODEL_ARM_CURSOR, 600u);
    model_expect("the end state is DRAINED (nothing left to prime)", MODEL_ARM_STATE,
                 USB_STREAM_ST_DRAINED);
    /* **One chunk, not eighteen.** A chunk is one dTD, sized by STAGE90_USB_STREAM_CHUNK (4096), not
     * by the 64-byte max packet: 600 bytes fit in a single dTD and the arm primes once, then the core
     * drains that one transfer in ten 64-byte packets. The old expectation divided by 32 - a packet
     * size that is not what the arm uses - so a correct arm failed this check. */
    model_expect("chunks (600 bytes fit in ONE dTD, drained in 64-byte packets)", MODEL_ARM_CHUNKS, 1u);
    return model_case_fail;
}

/* (b) a short transfer: the host reads 100 and stops. The cursor advances by ACTUAL (the 100 the host
 * accepted, not the 600 offered), and the re-prime resumes AT the cursor: the next 32 bytes are ring
 * bytes 100..131. */
static int model_case_short(void)
{
    uint32_t k;

    model_out_n = 0u;
    model_offered = 100u;
    for (k = 0u; k < 600u; k++)
        MODEL_ARM_RING(k) = model_src_byte(k);
    MODEL_ARM_HEAD = 600u;
    for (k = 0u; k < 200u && MODEL_ARM_CURSOR < 100u; k++)
        MODEL_RUN(1u);
    if (model_out_n != 100u)
        model_fail("short: a count other than 100 arrived");
    model_expect("short: the cursor is the actual (100)", MODEL_ARM_CURSOR, 100u);
    model_out_n = 0u;
    model_offered = 32u;
    for (k = 0u; k < 100u && model_out_n < 32u; k++)
        MODEL_RUN(1u);
    if (model_out_n == 32u) {
        for (k = 0u; k < 32u; k++)
            if (model_out[k] != model_src_byte(100u + k)) {
                model_fail("the re-prime after a short transfer did not resume at the cursor");
                break;
            }
    } else {
        model_fail("the re-prime after a short transfer delivered nothing");
    }
    return model_case_fail;
}

/* (c) the ring publisher, against ring facts this file states for itself (64 KiB; the 32-byte arm packet
 * over one 64 KiB ring is 2048 chunks): len = 0, an empty ring, a full ring, room, and the wrap - with
 * every byte read back AFTER the head that published it, as the consumer's would be. */
static int model_case_publish(void)
{
    uint8_t buf[700];
    uint32_t i;

    for (i = 0u; i < sizeof(buf); i++)
        buf[i] = (uint8_t)(0xa5u ^ (uint8_t)i);
    model_expect("the ring this file assumes is 64 KiB", STAGE90_USB_STREAM_RING_SIZE, 65536u);
    model_expect("publish(0) takes nothing", MODEL_ARM_PUBLISH(buf, 0u), 0u);
    model_expect("publish(0) drops nothing", MODEL_ARM_DROPPED, 0u);
    MODEL_ARM_CURSOR = 0u; MODEL_ARM_HEAD = 0u;
    model_expect("publish(600) into an empty ring", MODEL_ARM_PUBLISH(buf, 600u), 600u);
    model_expect("publish(600): head", MODEL_ARM_HEAD, 600u);
    model_expect("publish(600): byte 0", MODEL_ARM_RING(0u), buf[0]);
    model_expect("publish(600): byte 599", MODEL_ARM_RING(599u), buf[599]);
    /* **A 64 KiB ring holding 600 bytes is not full.** The case asserted that a second publish(600)
     * was refused, but `head - cursor` was 600 of 65536 - the arm correctly took it, and a correct
     * arm failed. To exercise fullness the tail has to sit one ring behind the head; the counters are
     * u32 and the ring is a mask, so "one ring behind" is exact and does not wrap the subtraction. */
    MODEL_ARM_CURSOR = 600u - STAGE90_USB_STREAM_RING_SIZE;
    model_expect("publish(600) again (the ring is full)", MODEL_ARM_PUBLISH(buf, 600u), 0u);
    model_expect("full ring: drops", MODEL_ARM_DROPPED, 600u);
    /* **"Room 4" means `head - cursor` is one ring minus 4, not 4.** `head - cursor` is
     * the USED count (`usb_stream_available`), so the pair that leaves 4 bytes of room has
     * used = RING_SIZE - 4. The old pair, head = 0 / cursor = 2^32 - 4, wraps the subtraction
     * to 4 - i.e. it said the ring held 4 bytes and had 65532 free, the opposite of what the
     * case wanted, and a correct arm was failed for taking all 10. Putting the head just below
     * 2^32 keeps every index in the ring: `head & MASK` is 0xfffc, so the 4 that fit occupy the
     * LAST four slots and nothing spills past index 0. */
    MODEL_ARM_HEAD = 0xfffffffcu;
    MODEL_ARM_CURSOR = 0xfffffffcu - (STAGE90_USB_STREAM_RING_SIZE - 4u);
    model_expect("publish(10) with room 4", MODEL_ARM_PUBLISH(buf + 10u, 10u), 4u);
    model_expect("wrap: drops", MODEL_ARM_DROPPED, 600u + 6u);
    model_expect("wrap: head advanced by the 4 taken", MODEL_ARM_HEAD, 0xfffffffcu + 4u);
    model_expect("wrap: ring[64K-1] is src[13]",
                 MODEL_ARM_RING(STAGE90_USB_STREAM_RING_SIZE - 1u), buf[13]);
    model_expect("wrap: the 5th byte did not land on index 0",
                 MODEL_ARM_RING(0u) != buf[14], 1u);
    return model_case_fail;
}

/* (d) the publication: at most once per second of CNTVCT, the deadline inclusive, and the next one a full
 * second later; every stream key once per publication. */
static int model_case_publish_rate(void)
{
    /* **The deadline is set relative to the clock the pass will read.** `model_pass` advances the
     * arm's CNTVCT by 1 ms (19200 ticks) BEFORE the arm's poll runs, so a case that sets NOW=999 and
     * PUB_NEXT=1000 is not "one tick short" - the poll sees 20199 and is 19 ms past due, publishing
     * immediately. The old expectations never matched for that reason. Now the deadline is anchored
     * to what the poll will actually see, and the pass that crosses it is exact. */
    MODEL_ARM_NOW = 1000u;
    MODEL_ARM_PUB_NEXT = 1000u + 19200u + 1u;      /* one tick past the next pass's clock */
    MODEL_RUN(0u);                                  /* clock -> 20199, one short */
    model_expect("before the deadline: nothing published", model_kv_n, 0u);
    MODEL_ARM_PUB_NEXT = 1000u + 19200u;            /* exactly the next pass's clock */
    MODEL_RUN(0u);                                  /* clock -> 39219, due */
    model_expect("at the deadline: every stream key", model_kv_n, MODEL_NKEYS);
    model_expect("at the deadline: _published = 1", MODEL_ARM_PUBLISHED, 1u);
    /* the next deadline is one second after the last publication; step the clock in two passes so
     * the one that crosses it is the only one that publishes */
    MODEL_ARM_PUB_NEXT = MODEL_ARM_NOW + 2u * 19200u + 1u;
    MODEL_RUN(0u);
    model_expect("one tick before the next deadline: nothing", model_kv_n, MODEL_NKEYS);
    MODEL_ARM_PUB_NEXT = MODEL_ARM_NOW + 19200u;    /* exactly the clock this pass will see */
    MODEL_RUN(0u);
    model_expect("at the next deadline: every stream key again", model_kv_n, 2u * MODEL_NKEYS);
    model_expect("at the next deadline: _published = 2", MODEL_ARM_PUBLISHED, 2u);
    return model_case_fail;
}

/* (e) a producer refill after DRAINED: the pump leaves DRAINED and primes (a host that waited is not
 * NAKed forever while bytes sit in the ring), the first chunk still sends its one-time `_armed` notice,
 * and - once primed - a re-poll does NOT overwrite the ACTIVE dTD (the core might be DMA'ing it). */
static int model_case_refill(void)
{
    uint32_t token, head;

    MODEL_ARM_HEAD = 0u;
    MODEL_ARM_CURSOR = 0u;
    MODEL_RUN(0u);
    MODEL_RUN(0u);
    model_expect("empty ring: state DRAINED", MODEL_ARM_STATE, USB_STREAM_ST_DRAINED);
    MODEL_ARM_HEAD = 3u;                        /* three bytes: a short dTD, the arm offers one packet */
    MODEL_RUN(0u);
    model_expect("refilled ring: state STREAM", MODEL_ARM_STATE, USB_STREAM_ST_STREAM);
    model_expect("refilled ring: primed", MODEL_ARM_PRIME != 0u, 1u);
    model_expect("refilled ring: the dTD is ACTIVE",
                 model_td_field(STAGE90_USB_ENUM_TD_OFF_TOKEN) & STAGE90_USB_ENUM_TD_ACTIVE,
                 STAGE90_USB_ENUM_TD_ACTIVE);
    /* **The `_armed` notice is somewhere in the log, not necessarily first.** The arm publishes its
     * seven periodic keys on the FIRST poll (`pub_next` is 0 in BSS, and `now - 0` is "due"), and the
     * `_armed` write happens later in the same pass - so the log is keyed by time, not by importance.
     * Asserting `kv[0]` was the armed notice failed a correct arm. What the case is about is that the
     * notice is emitted ONCE, on the refill, so that is what is counted. */
    {
        uint32_t a, armed = 0u;
        for (a = 0u; a < model_kv_n; a++)
            if (strcmp(model_kv[a].k, "xnu_live_usb_stream_armed") == 0)
                armed++;
        model_expect("refilled ring: exactly one _armed notice", armed, 1u);
    }
    token = model_td_field(STAGE90_USB_ENUM_TD_OFF_TOKEN);
    head = MODEL_ARM_HEAD;
    MODEL_RUN(0u);                              /* still ACTIVE: nothing may be re-primed */
    model_expect("ACTIVE dTD: the dTD is not rewritten", model_td_field(STAGE90_USB_ENUM_TD_OFF_TOKEN),
                 token);
    model_expect("ACTIVE dTD: the producer's head is untouched", MODEL_ARM_HEAD, head);
    model_expect("ACTIVE dTD: still one chunk outstanding", MODEL_ARM_ACTIVE, 1u);
    return model_case_fail;
}

int model_run(int group)
{
    MODEL_RESET();
    /* **The device state the arm's poll requires, before every case.** poll() reads USBMODE and
     * returns ST_IDLE unless it says DEVICE; it then returns ST_WAITING unless ENDPTCTRL(EP_IN) has
     * TXE. Both are reads of the arm's register window, which the model maps as `model_window`.
     * Starting from zeroes made every case see zero bytes - the first real run of this model
     * reported "0 of 600 bytes arrived" for exactly that reason. The values are what the
     * enumeration arm leaves on SET_CONFIGURATION. Set here rather than per case so a case is about
     * the ring and not about the device. */
    *(volatile uint32_t *)(HOST_REG_BASE + STAGE90_USB_USBMODE) = STAGE90_USB_USBMODE_CM_DEVICE;
    *(volatile uint32_t *)(HOST_REG_BASE + STAGE90_USB_ENDPTCTRL(STAGE90_USB_ENUM_EP_IN)) =
        STAGE90_USB_ENDPTCTRL_TXE | STAGE90_USB_ENDPTCTRL_TXR | STAGE90_USB_ENUM_ENDPTCTRL_TXT_BULK;
    model_failed = 0;
    model_case_fail = 0;
    model_naks = 0u;
    model_seg_len = 0u;
    model_primed = 0u;
    model_offered = 0u;
    switch (group) {
#define MODEL_GROUP(n, call) case n: call; break;
    MODEL_GROUPS
#undef MODEL_GROUP
    default: return 1;
    }
    return model_failed ? 1 : 0;
}