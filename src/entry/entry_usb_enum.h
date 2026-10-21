/*
 * 910b (first arm): the enumeration rung's register values and graph constants - every one named beside
 * the Android source that OWNS it.
 *
 * **Why a third header.** `entry_usb.h` is 910a's read-only offset map; `entry_usb_dev.h` is the values
 * 910a2 WRITES for the PHY and the mode transition. This arm writes a *different* register set - the
 * device-mode interrupt enable, the endpoint list address, EP0's control register, the endpoint prime
 * and complete/setup semaphores, and the queue-head / transfer-descriptor fields the core DMAs - so those
 * values live here, one definition each, with the value's owner named ([[mi4-one-value-two-definitions]]).
 * It includes the two earlier headers and re-uses every offset they already define rather than restating
 * one: a second copy of `USB_USBMODE` would be the exact defect this project keeps paying for.
 *
 * **THE OWNER IS `external/android_kernel_xiaomi_cancro`** - the same three files 910a2 names:
 * `drivers/usb/gadget/ci13xxx_udc.c` + `ci13xxx_udc.h` (the ChipIdea UDC: the qh/td layout, the
 * endpoint-control bits, the register bit-fields), and `arch/arm/mach-msm/include/mach/msm_hsusb_hw.h`
 * (the absolute offsets). Where a value is a *layout* fact (a struct field's offset, a stride) the
 * owner is `ci13xxx_udc.h`; where it is a device register bit, `ci13xxx_udc.h`'s `CAP_*` bitfields are
 * the one the live driver uses, and `tools/check_usb_enum.py` reads those headers to prove it.
 */
#ifndef STAGE90_ENTRY_USB_ENUM_H
#define STAGE90_ENTRY_USB_ENUM_H

#include <stdint.h>

#include "entry_usb_dev.h"   /* pulls in entry_usb.h: every device register offset this arm re-uses. */

/* =================================================================================================
 * (1) The constants 910a2 did NOT set and this arm owns.
 * =================================================================================================
 */

/*
 * `USBINTR` - the vendor's enable mask, `ci13xxx_udc.c`'s `hw_device_state`: `USBi_UI|USBi_UEI|USBi_PCI|
 * USBi_URI|USBi_SLI` = `BIT(0)|BIT(1)|BIT(2)|BIT(6)|BIT(8)` = `0x147`. 910a2 deliberately published this
 * as 0 (`_dev_intr`); this arm sets it. **`USBi_NAKI` (bit 16) is NOT in the mask** - the driver never
 * enables it and never handles it (experiment-910 §10.1), so a poller that used all of `USBSTS` would act
 * on a bit the vendor's own code ignores.
 */
#define STAGE90_USB_ENUM_INTR_VALUE     0x00000147u

/* `USBSTS` / `USBINTR` bit positions, by name. `ci13xxx_udc.h` `USBi_*`. */
#define STAGE90_USB_ENUM_STS_UI         0x00000001u  /* bit 0 - USB (transaction) interrupt.   */
#define STAGE90_USB_ENUM_STS_UEI        0x00000002u  /* bit 1 - USB error.                     */
#define STAGE90_USB_ENUM_STS_PCI        0x00000004u  /* bit 2 - port change.                   */
#define STAGE90_USB_ENUM_STS_URI        0x00000040u  /* bit 6 - USB reset received.            */
#define STAGE90_USB_ENUM_STS_SLI        0x00000100u  /* bit 8 - suspend.                       */

/* `DEVICEADDR`: `ci13xxx_udc.c` `hw_usb_set_address` - `(addr << 25) | USBADRA(bit24)`. */
#define STAGE90_USB_ENUM_DEVICEADDR_ADDR_MASK   0xfe000000u  /* bits [31:25] - the address.   */
#define STAGE90_USB_ENUM_DEVICEADDR_ADDR_SHIFT  25u
#define STAGE90_USB_ENUM_DEVICEADDR_USBADRA     0x01000000u  /* bit 24 - the update latch.    */

/*
 * `ENDPOINTLISTADDR` (offset `USB_ENDPOINTLISTADDR`, already named `STAGE90_USB_ENDPOINTLISTADDR` in
 * `entry_usb.h`): the *physical* address of the queue-head array's base. **The hardware indexes endpoint
 * N at `base + N*64`** (`ci13xxx_udc.c`: the vendor's dma_pool has align 64, boundary 4096), so the base
 * and every entry must be 64-byte aligned - asserted at the array below.
 */
#define STAGE90_USB_ENUM_QH_STRIDE      64u

/*
 * The endpoint number of the one enumerable IN endpoint, and the qh index for each.
 *
 * **THE QH INDEX IS THE REGISTER BIT.** The core indexes the endpoint list by `num + (dir ? 16 : 0)`:
 * the vendor's `ep0in` is `ci13xxx_ep[hw_ep_max/2]` (`ci13xxx_udc.h:166`), and `isr_tr_complete_handler`
 * walks `mEp = &ci13xxx_ep[i]` against `hw_test_and_clear_complete(i)` (`ci13xxx_udc.c:2666`/`:2672`),
 * i.e. the SAME `i` is both the array subscript and the `ENDPTCOMPLETE`/`ENDPTPRIME` bit. So an
 * endpoint's `ENDPTPRIME` bit IS its qh index, and **EP1-IN is `EP_IN + 16 = 17`, not `EP_IN = 1`**
 * (index 1 is EP1-OUT's slot, which is empty here - the core would fetch a terminated qh and never
 * move a byte, while the CPU filled EP1-IN's slot). With `hw_ep_max = 32` (= `ENDPT_MAX`, DEN=16 on this
 * IP) the half offset is 16 = `ENDPT_MAX/2`. `tools/check_usb_enum.py` refuses any qh index that is not
 * `num + ENDPT_MAX/2`, so this cannot drift back into a comment
 * ([[mi4-one-value-two-definitions]]; [[mi4-a-claim-in-a-comment-is-not-a-check]]).
 */
#define STAGE90_USB_ENUM_EP_IN          1u    /* endpoint 1, IN direction - the one a host reads.    */
#define STAGE90_USB_ENUM_QH_OUT0        0u    /* ep0out = ci13xxx_ep[0]                     (bit 0).  */
#define STAGE90_USB_ENUM_QH_IN0         16u   /* ep0in  = ci13xxx_ep[ENDPT_MAX/2]           (bit 16). */
#define STAGE90_USB_ENUM_QH_IN1         17u   /* ep1in  = ci13xxx_ep[EP_IN + ENDPT_MAX/2]   (bit 17). */
#define STAGE90_USB_ENUM_QH_COUNT       32u   /* the vendor's array: 16 RX halves + 16 TX halves.     */

/* `ENDPTPRIME` / `ENDPTCOMPLETE` bit for an endpoint: `BIT(num + (dir?16:0))`. */
#define STAGE90_USB_ENUM_EPBIT(num, dir) ((uint32_t)1u << ((uint32_t)(num) + ((dir) ? 16u : 0u)))

/* The 4-bit-per-direction `ENDPTCTRL(n)` type/flag values this arm writes. Fields are in
 * `entry_usb_dev.h`; the *bulk* type encoding and the reset-toggle/enable bits are here.
 * `USB_ENDPOINT_XFER_BULK = 2` (the low two bits of `RXT`/`TXT` at their shift). */
#define STAGE90_USB_ENUM_ENDPTCTRL_TXT_BULK  (2u << 18)   /* TX type field = bulk.  */
#define STAGE90_USB_ENUM_ENDPTCTRL_RXT_BULK  (2u << 2)    /* RX type field = bulk.  */
/* EP0's control-register value: enable + toggle-reset + control type (0), both directions. §10.3(c). */
#define STAGE90_USB_ENUM_ENDPTCTRL0_VALUE    0x00c000c0u
/* EP1's control-register value: the TX (IN) half - enable + toggle-reset + bulk; RX half stays 0. */
#define STAGE90_USB_ENUM_ENDPTCTRL1_VALUE    (STAGE90_USB_ENDPTCTRL_TXE | STAGE90_USB_ENDPTCTRL_TXR | \
                                              STAGE90_USB_ENUM_ENDPTCTRL_TXT_BULK)

/*
 * `USBCMD.SUTW` (bit 13) - the setup-lockout guard the vendor toggles around the SETUP memcpy
 * (`ci13xxx_udc.c` `hw_test_and_set_setup_guard` / `hw_test_and_clear_setup_guard`). `msm_hsusb_hw.h`
 * names it `USBCMD_ATDTW` at bit 14; SUTW is bit 13.
 */
#define STAGE90_USB_ENUM_USBCMD_SUTW    0x00002000u

/* =================================================================================================
 * (2) The queue head (`struct ci13xxx_qh`) - `ci13xxx_udc.h`, 48 bytes, HW stride 64.
 * =================================================================================================
 * The core writes the 8 SETUP bytes at offset **40** (`0x28`) and the in-flight dTD address at offset 4
 * (`curr`); the CPU writes `cap` (0) and the embedded td's `next`/`token` (8/12). **The offset is 40, not
 * 32**: `cap`(0..3) + `curr`(4..7) + the packed `ci13xxx_td`(8..35) + `RESERVED`(36..39) = 40, so the
 * setup buffer is the LAST 8 bytes of the 48-byte struct. Getting this one wrong is a qh whose SETUP
 * bytes the CPU reads from the middle of the embedded td - the exact transcription defect
 * ([[mi4-one-value-two-definitions]]) this header exists to prevent, and `tools/check_usb_enum.py`
 * recomputes it from the struct rather than trusting this comment.
 */
#define STAGE90_USB_ENUM_QH_OFF_CAP     0u
#define STAGE90_USB_ENUM_QH_OFF_CURR    4u
#define STAGE90_USB_ENUM_QH_OFF_TDNEXT  8u    /* embedded ci13xxx_td.next  */
#define STAGE90_USB_ENUM_QH_OFF_TDTOK   12u   /* embedded ci13xxx_td.token */
#define STAGE90_USB_ENUM_QH_OFF_SETUP   40u   /* struct usb_ctrlrequest setup, at the tail (0x28) */

/* `qh.cap` bitfields: `QH_IOS` (IRQ on setup, bit 15), `QH_MAX_PKT` (bits [26:16]), `QH_ZLT` (bit 29). */
#define STAGE90_USB_ENUM_QH_IOS         0x00008000u
#define STAGE90_USB_ENUM_QH_MAX_PKT(n)  (((uint32_t)(n) & 0x7ffu) << 16)
#define STAGE90_USB_ENUM_QH_ZLT         0x20000000u

/* =================================================================================================
 * (3) The transfer descriptor (`struct ci13xxx_td`) - `ci13xxx_udc.h`, 28 bytes, aligned(4).
 * =================================================================================================
 * `token` is `(total_bytes << 16) | flags`; the core clears `ACTIVE` and updates `TOTAL_BYTES` as it
 * moves the transfer. `page[i]` low 12 bits are a byte offset within a 4 KiB page.
 */
#define STAGE90_USB_ENUM_TD_STRIDE      32u   /* >= 28, aligned(4); 32 keeps a clean power-of-two slot. */

#define STAGE90_USB_ENUM_TD_OFF_NEXT    0u
#define STAGE90_USB_ENUM_TD_OFF_TOKEN   4u
#define STAGE90_USB_ENUM_TD_OFF_PAGE0   8u

#define STAGE90_USB_ENUM_TD_TERMINATE   0x00000001u  /* `next` bit 0 - no further dTD.            */
#define STAGE90_USB_ENUM_TD_STATUS_MASK 0x000000ffu  /* `token` bits [7:0].                       */
#define STAGE90_USB_ENUM_TD_ACTIVE      0x00000080u  /* bit 7 - the core owns the dTD.            */
#define STAGE90_USB_ENUM_TD_IOC         0x00008000u  /* bit 15 - interrupt on complete.            */
#define STAGE90_USB_ENUM_TD_TOTAL_SHIFT 16u          /* bits [30:16] - remaining byte count.       */
#define STAGE90_USB_ENUM_TD_TOTAL_MASK  0x7fff0000u

/* =================================================================================================
 * (4) The descriptors - the vendor's values, with the arm's deliberate divergences (design §5).
 * =================================================================================================
 * Owner: `drivers/usb/gadget/android.c` + `f_adb.c`. `bMaxPacketSize0 = CTRL_PAYLOAD_MAX = 64`
 * (`ci13xxx_udc.h:27`) - NOT a field of the source struct, but it IS byte 7 of the 18-byte descriptor
 * and must equal the EP0 qh `maxpacket` or the host's first control read mis-sizes.
 */
#define STAGE90_USB_ENUM_DESC_DEVICE    1u    /* USB_DT_DEVICE   */
#define STAGE90_USB_ENUM_DESC_CONFIG    2u    /* USB_DT_CONFIG   */
#define STAGE90_USB_ENUM_DESC_STRING    3u    /* USB_DT_STRING   */

#define STAGE90_USB_ENUM_REQ_GET_STATUS        0u
#define STAGE90_USB_ENUM_REQ_CLEAR_FEATURE     1u
#define STAGE90_USB_ENUM_REQ_SET_FEATURE       3u
#define STAGE90_USB_ENUM_REQ_SET_ADDRESS       5u
#define STAGE90_USB_ENUM_REQ_GET_DESCRIPTOR    6u
#define STAGE90_USB_ENUM_REQ_SET_DESCRIPTOR    7u
#define STAGE90_USB_ENUM_REQ_GET_CONFIGURATION 8u
#define STAGE90_USB_ENUM_REQ_SET_CONFIGURATION 9u

#define STAGE90_USB_ENUM_DIR_IN         0x80u  /* `bRequestType` bit 7: device-to-host.              */
#define STAGE90_USB_ENUM_TYPE_MASK      0x60u  /* bits [6:5]: 0=standard, 1=class, 2=vendor.         */
#define STAGE90_USB_ENUM_TYPE_STANDARD  0x00u
#define STAGE90_USB_ENUM_RECIP_MASK     0x1fu  /* bits [4:0].                                        */
#define STAGE90_USB_ENUM_RECIP_DEVICE   0x00u  /* the recipient a device_remote_wakeup names.         */
#define STAGE90_USB_ENUM_RECIP_INTERFACE 0x01u

/* The feature selectors `SET_FEATURE`/`CLEAR_FEATURE` carry in `wValue` (ch9 `USB_FEATURE_*`). A device
 * records the remote-wakeup selector; any other selector is a `bad_req`, not a silent success. */
#define STAGE90_USB_ENUM_FEATURE_REMOTE_WAKEUP 1u

/*
 * The `usb_enum_settle` console var (design §4, "settling"): 0..4, default 2. The fastboot boot's "no
 * device on the bus" is ambiguous - a host that probes before the entry image has armed EP0 sees nothing,
 * a host that probes after SET_ADDRESS but before the device has taken it sees the wrong answer - so the
 * arm names where the settle points are; this var SELECTS where it waits, and each rung of the ladder is
 * one more second of the kernel timebase (`stage90_cntvct_read` at CNTFRQ):
 *   0  none                1  after SET_ADDRESS         2  after SET_CONFIGURATION (the default)
 *   3  after EP1-IN's data is primed                   4  after the stream's first chunk is primed
 * The wait is a BOUNDED busy-wait on CNTVCT (a delay, not a poll of a device), so a host that never
 * asks costs the idle path one second per idle branch - the cost §4 accepts - and never a hang.
 */
#define STAGE90_USB_ENUM_SETTLE_MIN     0u
#define STAGE90_USB_ENUM_SETTLE_MAX     4u
#define STAGE90_USB_ENUM_SETTLE_DEFAULT 2u

/*
 * The device descriptor's mutable values, chosen here and published in the arm's own record. `idVendor`
 * keeps the Google/Android id (what a host's driver matches); `idProduct` is unique to this arm so a
 * `lsusb` proves THIS image enumerated; `bcdDevice` is literal ("910"); `iSerialNumber` is hard-coded to
 * the phone's serial because the vendor only gets the CID from a userspace sysfs write (§10.8).
 */
#define STAGE90_USB_ENUM_ID_VENDOR      0x18d1u
#define STAGE90_USB_ENUM_ID_PRODUCT     0x0910u
#define STAGE90_USB_ENUM_BCD_DEVICE     0x0910u
#define STAGE90_USB_ENUM_MAX_PACKET0    64u

/* The configuration: one interface, one bulk IN endpoint, full-speed. */
#define STAGE90_USB_ENUM_CONFIG_VALUE   1u
#define STAGE90_USB_ENUM_MAX_POWER_MA   50u   /* 100 mA units: 50*2 = 100 mA, matching the vendor's. */
#define STAGE90_USB_ENUM_IFACE_CLASS    0xffu /* ADB signature, so 910d is a step from here (§10.8). */
#define STAGE90_USB_ENUM_IFACE_SUBCLASS 0x42u
#define STAGE90_USB_ENUM_IFACE_PROTOCOL 1u
#define STAGE90_USB_ENUM_EP_IN_ATTR     0x02u /* bulk.                                              */
#define STAGE90_USB_ENUM_EP_IN_MAXPKT   64u   /* FS bulk; the vendor's 512 is HS, not reachable here.*/
#define STAGE90_USB_ENUM_EP_IN_EPADDR   (STAGE90_USB_ENUM_DIR_IN | STAGE90_USB_ENUM_EP_IN)

/* String descriptor indices (iManufacturer / iProduct / iSerialNumber). iConfiguration = 0. */
#define STAGE90_USB_ENUM_STR_MANUFACTURER 1u
#define STAGE90_USB_ENUM_STR_PRODUCT      2u
#define STAGE90_USB_ENUM_STR_SERIAL       3u

/* The IN endpoint's published payload: a magic word + this arm's identity, so a host read is
 * self-describing. Owner: this arm (a value the arm invents, not a transcription). */
#define STAGE90_USB_ENUM_IN_MAGIC       0x910b0910u

/*
 * The single entry point. Called from `__wrap_Idle_load_context` (the one wrapper every idle pass
 * reaches, §9.6), once per pass - it drains the latched `USBSTS` and advances the EP0 state machine. It
 * must NOT re-run the link reset (910a2 owns that) and must NOT write at all unless the core is already
 * in device mode (the 910a2 hazard rule).
 */
void entry_usb_enum_poll(void);

/*
 * **910c: the handover.** When the stream arm is ON (`STAGE90_XNU_USB_STREAM=1`) the enum arm arms EP1's
 * endpoint-control register but does NOT prime it (nor re-prime it); the stream arm owns EP1's qh and dTD
 * from the first stream prime on. The hardware has ONE endpoint list, so the qh array cannot be split -
 * this accessor is how the stream arm reaches qh[IN1] without a second, editable copy of `g_usb_qh`
 * ([[mi4-one-value-two-definitions]]). It is exported from the enum file because the enum file owns the
 * array, and its caller is `entry_usb_stream.c` (a build refusal pins that).
 */
volatile uint32_t *entry_usb_enum_qh_in1(void);

#endif /* STAGE90_ENTRY_USB_ENUM_H */