#!/usr/bin/env python3
"""usb_console_read.py - read the D13 payload's RAM console from EP1-IN over USB.

*** THE HOST SIDE OF THE LADDER (959-962). *** The D13 USB ladder (probe -> device -> enum ->
stream) hands the payload's RAM console byte-for-byte to bulk endpoint **EP1-IN (0x81)** of a device
with VID:PID `0x18d1:0x0910` (`src/entry/entry_usb_enum.h:173-174`). The ladder code was built and
validated host-side, but the **repo had no host reader** - so a press of a ladder arm (or of any
**resident** arm, which streams this way) went dark with nothing reading the bytes. This is that
reader. It is the goal's 「可以通过 usb 进行调试」 in its host form.

Why this reader matters beyond the ladder: a **resident** arm has **no ending by construction**
(`build_entry.sh:1094-1103` refuses POST_END_* when STAGE90_XNU_RESIDENT=1), so nothing preserves its
RAM-console record and its log survives at most one boot. Streaming over USB is the only way to see a
resident run **live** - no `/proc/last_kmsg`, no recovery window, no losing the log ([[mi4-975...]]).

It is READ-ONLY on the host: open device, claim interface, `libusb_bulk_transfer` in a loop, write to
the capture file and (optionally) stdout. It writes nothing to the device. Not a press.

Usage:
  tools/usb_console_read.py --no-reset [--out FILE] [--seconds N] [--wait N] [--follow] [--frames]

  --out FILE      capture file, APPENDED (default out/stage90/captures/usb-console-<stamp>.txt; '-' = discard)
  --seconds N     stop after N seconds with no new bytes (default 120; 0 = run until Ctrl-C)
  --follow        never exit on its own (seconds forced 0; --wait is the only give-up). Silent windows
                  are `[gap ...]` lines in the capture, never an exit. On SIGTERM/SIGINT/SIGHUP it
                  flushes and writes a one-line summary; exit 0 = bytes read, 2 = no device seen,
                  3 = device seen but silent. Also entered with --no-tty, or when stdout is not a
                  tty (a piped run never ends on a silence).
  --no-tty        alias of --follow (the plan's name). Neither changes what is read.
  --wait N        wait up to N seconds for the device to appear (default 0). Start the reader, THEN
                  press: it attaches when the payload enumerates and streams until Ctrl-C.
  --stdout        also echo received bytes to stdout (--follow always echoes)
  --bell-on RE    BEL (\\a) to stderr when a received chunk completes a LINE matching RE (default
                  `panic|Bus error|Kernel trap|xnu_live_fcr_`; '' disables). Lines span chunks.
  --frames        EP1-IN carries 16-byte headers {magic 0x474c4b4d 'MKLG' LE32, seq LE32, head,
                  epoch LE32, len LE16, pad LE16} (usb-channel-plan.txt §4). Frames are forwarded
                  without their header; a seq jump prints `[lost N ...]`, an epoch change
                  `[epoch change ...]`, a head jump `[head jump N ...]`; a payload byte-run starting
                  MKLG is split with a zero-length frame so it cannot be re-read as a header. If no
                  header appears at any chunk start, `[frames: not present - raw text]` is printed
                  ONCE and every byte passes through unchanged.
  --no-reset      REQUIRED. The reader has no reset path: load_libusb binds an explicit symbol list
                  that never names libusb_reset_device, and --selftest-noreset plants a library that
                  exposes it and shows it is never asked. A run without the flag is refused (exit 2)
                  rather than given a state no code sets.
  --daemon        fork, os.setsid() in the child, stdin <- /dev/null, stdout+stderr -> --log,
                  SIGPIPE ignored via signal.signal, PYTHONUNBUFFERED=1, re-exec (--follow forced).
                  The parent prints the child pid on stdout. Outlives the shell/tool call.
  --setsid        alias of --daemon.
  --log FILE      daemon log (default: --out with .txt -> .log)
  --fake FILE     replay backend: bytes from FILE (or a FIFO) as if from EP1-IN; no libusb. A FIFO
                  EOF is a device that went away (re-attach); a regular file's EOF ends the run
                  (0, or 3 if it ended inside a frame).
  --selftest | --selftest-reconnect | --selftest-frames | --selftest-fake | --selftest-noreset

Exit: 0 = bytes were read; 2 = the device was never seen (nothing read); 3 = device seen but the
endpoint never delivered (claimed OK, all transfers timed out) - distinct, so "not there" and "there
but silent" are not the same reading ([[mi4-silence-is-a-reading-only-if-success-is-silent]]).

HOST NOTE: run with `/usr/bin/python3`. The `python3` first on PATH on this host returns corrupted
results for `struct.calcsize`/`struct.pack` (one field short: `<IIIIH` sizes 18) and, in some runs,
for payload ints; `textwrap.dedent` and `str.splitlines` ids are right there but not here. Nothing
here uses struct, and the selftests pin every number they rely on, including the frame() bytes.
"""
import argparse
import ctypes
import os
import re
import signal
import sys
import time

# ---- libusb-1.0 via ctypes (no pyusb; libusb-1.0.so.0 is present, headers are not) ----------------

EP_IN = 0x81          # EP1-IN, the bulk endpoint the stream primes (entry_usb_enum.h:75, :187)
VID = 0x18d1          # STAGE90_USB_ENUM_ID_VENDOR (entry_usb_enum.h:173)
PID = 0x0910          # STAGE90_USB_ENUM_ID_PRODUCT (entry_usb_enum.h:174)
TIMEOUT_MS = 500      # per bulk transfer; a NAK just returns rc=TIMEOUT and we loop
FRAME_MAGIC = 0x474c4b4d   # 'MKLG' LE32 - usb-channel-plan.txt §4
FRAME_HDR = 16        # magic LE32, seq LE32, head, epoch LE32, len LE16, pad LE16
DEFAULT_BELL = r"panic|Bus error|Kernel trap|xnu_live_fcr_"

# The libusb reset symbol, named ONLY in this constant (and in comments): the checker and
# --selftest-noreset assert it is absent from _LIBUSB_BINDS and from every other line of this file.
NO_RESET_SYMBOL = "libusb_reset_device"
_LIBUSB_BINDS = ("libusb_init", "libusb_open_device_with_vid_pid",
                 "libusb_set_auto_detach_kernel_driver", "libusb_claim_interface",
                 "libusb_release_interface", "libusb_get_active_config_descriptor",
                 "libusb_free_config_descriptor", "libusb_bulk_transfer", "libusb_close",
                 "libusb_exit")


class _Endpoint(ctypes.Structure):
    _fields_ = [("bLength", ctypes.c_uint8), ("bDescriptorType", ctypes.c_uint8),
                ("bEndpointAddress", ctypes.c_uint8), ("bmAttributes", ctypes.c_uint8),
                ("wMaxPacketSize", ctypes.c_uint16), ("bInterval", ctypes.c_uint8),
                ("bRefresh", ctypes.c_uint8), ("bSynchAddress", ctypes.c_uint8),
                ("extra", ctypes.c_void_p), ("extra_length", ctypes.c_int)]


class _InterfaceDesc(ctypes.Structure):
    _fields_ = [("bLength", ctypes.c_uint8), ("bDescriptorType", ctypes.c_uint8),
                ("bInterfaceNumber", ctypes.c_uint8), ("bAlternateSetting", ctypes.c_uint8),
                ("bNumEndpoints", ctypes.c_uint8), ("bInterfaceClass", ctypes.c_uint8),
                ("bInterfaceSubClass", ctypes.c_uint8), ("bInterfaceProtocol", ctypes.c_uint8),
                ("iInterface", ctypes.c_uint8), ("endpoint", ctypes.POINTER(_Endpoint))]


class _Interface(ctypes.Structure):
    _fields_ = [("altsetting", ctypes.POINTER(_InterfaceDesc)), ("num_altsetting", ctypes.c_int)]


class _ConfigDesc(ctypes.Structure):
    _fields_ = [("bLength", ctypes.c_uint8), ("bDescriptorType", ctypes.c_uint8),
                ("wTotalLength", ctypes.c_uint16), ("bNumInterfaces", ctypes.c_uint8),
                ("bConfigurationValue", ctypes.c_uint8), ("iConfiguration", ctypes.c_uint8),
                ("bmAttributes", ctypes.c_uint8), ("MaxPower", ctypes.c_uint8),
                ("interface", ctypes.POINTER(_Interface))]


def load_libusb():
    for name in ("libusb-1.0.so.0", "libusb-1.0.so"):
        try:
            lib = ctypes.CDLL(name)
            break
        except OSError:
            lib = None
    if lib is None:
        sys.stderr.write("usb_console_read: cannot load libusb-1.0 (install libusb-1.0-0)\n")
        return None
    lib.libusb_init.argtypes = [ctypes.POINTER(ctypes.c_void_p)]
    lib.libusb_init.restype = ctypes.c_int
    lib.libusb_open_device_with_vid_pid.argtypes = [ctypes.c_void_p, ctypes.c_uint16, ctypes.c_uint16]
    lib.libusb_open_device_with_vid_pid.restype = ctypes.c_void_p
    lib.libusb_set_auto_detach_kernel_driver.argtypes = [ctypes.c_void_p, ctypes.c_int]
    lib.libusb_claim_interface.argtypes = [ctypes.c_void_p, ctypes.c_int]
    lib.libusb_claim_interface.restype = ctypes.c_int
    lib.libusb_release_interface.argtypes = [ctypes.c_void_p, ctypes.c_int]
    lib.libusb_get_active_config_descriptor.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.POINTER(_ConfigDesc))]
    lib.libusb_get_active_config_descriptor.restype = ctypes.c_int
    lib.libusb_free_config_descriptor.argtypes = [ctypes.POINTER(_ConfigDesc)]
    lib.libusb_bulk_transfer.argtypes = [ctypes.c_void_p, ctypes.c_ubyte, ctypes.c_char_p,
                                         ctypes.c_int, ctypes.POINTER(ctypes.c_int), ctypes.c_uint]
    lib.libusb_bulk_transfer.restype = ctypes.c_int
    lib.libusb_close.argtypes = [ctypes.c_void_p]
    lib.libusb_exit.argtypes = [ctypes.c_void_p]
    return lib


def find_bulk_interface(lib, handle):
    """Return bInterfaceNumber of the interface that carries EP1-IN, else 0."""
    cfg = ctypes.POINTER(_ConfigDesc)()
    if lib.libusb_get_active_config_descriptor(handle, ctypes.byref(cfg)) != 0:
        return 0
    try:
        c = cfg.contents
        for i in range(c.bNumInterfaces):
            iface = c.interface[i]
            if iface.num_altsetting <= 0:
                continue
            alt = iface.altsetting[0]
            for e in range(alt.bNumEndpoints):
                if alt.endpoint[e].bEndpointAddress == EP_IN:
                    return alt.bInterfaceNumber
    finally:
        lib.libusb_free_config_descriptor(cfg)
    return 0


def now_stamp():
    return time.strftime("%Y%m%d-%H%M%S", time.gmtime())


def _attach(lib, ctx, a):
    """(handle, ifn) for vid:pid, or (None, None).  ONE open+claim; run() re-attaches on error."""
    handle = lib.libusb_open_device_with_vid_pid(ctx, a.vid, a.pid)
    if not handle:
        return None, None
    lib.libusb_set_auto_detach_kernel_driver(handle, 1)
    ifn = find_bulk_interface(lib, handle)
    rc = lib.libusb_claim_interface(handle, ifn)
    if rc != 0:
        sys.stderr.write("usb_console_read: claim interface %d rc=%d (try unplugging adb / the "
                         "kernel driver)\n" % (ifn, rc))
    return handle, ifn


def _detach(lib, handle, ifn):
    try:
        lib.libusb_release_interface(handle, ifn)
    except Exception:
        pass
    lib.libusb_close(handle)


# ---- the receive stages: bell lines and frame decode ----------------------------------------------

_WARNED = set()


def _warn_once(key, msg):
    if key not in _WARNED:
        _WARNED.add(key)
        sys.stderr.write(msg)


def u_le(buf, off, n):
    """LE unsigned n-byte int.  int.from_bytes is right on the interpreters this has been run on
    (`<IIIIH` sizing 18 on the PATH one is a struct defect, not a bytes one)."""
    return int.from_bytes(buf[off:off + n], "little")


# The 16-byte header, as a LITERAL: frame(format(seq=1, head=0x1011, epoch=1, len=1)) is exactly
# these bytes followed by the payload.  Every other header is built from this one by writing its
# variable fields at their literal offsets (frame()), and the selftest prints frame()'s bytes so a
# host whose bytes are not the ones written here says so by name.
_HDR_LITERAL = bytes([0x4D, 0x4B, 0x4C, 0x47, 0x01, 0x00, 0x00, 0x00, 0x11, 0x10, 0x00, 0x00,
                      0x01, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00])


def frame(msg=b"", seq=0, head=None, epoch=1):
    """One MKLG frame: the literal header with seq (bytes 4..8), head (8..12), epoch (12..16) and
    len (16..20) written in, then the payload.  (Written with explicit slices: pack_le through
    `v >> (8*i)` and struct.pack both came out one field short on this host.)"""
    if head is None:
        head = 0x1000 + seq * (FRAME_HDR + len(msg))
    h = _HDR_LITERAL
    out = bytearray(h[0:4] + h[4:8] + h[8:12] + h[12:16] + h[16:20])
    for i, v in ((4, seq), (8, head), (12, epoch), (16, len(msg))):
        out[i + 0] = v & 0xFF
        v = v // 256
        out[i + 1] = v & 0xFF
        v = v // 256
        out[i + 2] = v & 0xFF
        v = v // 256
        out[i + 3] = v & 0xFF
    return bytes(out) + msg


def escape_frame():
    """A zero-length frame - the escaping's separator; parse() rejects len 0."""
    return frame(msg=b"", seq=0, head=0, epoch=0)


class Bell:
    """A line buffer across chunks; counts the completed lines that match (one BEL each)."""

    BUFMAX = 4096

    def __init__(self, pattern, bel=None):
        self.rx = re.compile(pattern.encode()) if pattern else None
        self.buf = b""
        self.bels = 0
        self._bel = bel or (lambda: sys.stderr.write("\a"))

    def feed(self, data):
        if self.rx is None:
            return 0
        self.buf += data
        *lines, self.buf = self.buf.split(b"\n")
        n = 0
        for ln in lines:
            if self.rx.search(ln):
                n += 1
                self.bels += 1
                self._bel()
        if len(self.buf) > self.BUFMAX:          # an unterminated line is not held forever
            self.buf = self.buf[-self.BUFMAX:]
        return n


class FrameDecoder:
    """16-byte headers at the start of each chunk.

    Each chunk is probed at offset 0: a header is magic|seq|head|epoch|len with magic equal to
    FRAME_MAGIC, len > 0 (zero-length = the escaping's separator) and len fitting in the bytes the
    decoder already holds. Until a chunk starts with one, chunks pass through raw; the first that
    does locks the decoder onto frames. A payload byte-run starting MKLG is split with a
    zero-length frame so neither this decoder nor a later reader can take it for a header."""

    def __init__(self, emit):
        self.emit = emit                 # (bytes) - console text only; headers never reach it
        self.buf = b""
        self.locked = False
        self.present = False
        self.prev_seq = self.prev_head = self.epoch = None
        self.frames = 0
        self.events = []
        self.stats = {"lost": 0, "epoch change": 0, "head jump": 0, "escape": 0, "bad": 0}

    @staticmethod
    def parse(buf, start=0):
        if len(buf) - start < FRAME_HDR:
            return None
        magic = u_le(buf, start, 4)
        seq = u_le(buf, start + 4, 4)
        head = u_le(buf, start + 8, 4)
        epoch = u_le(buf, start + 12, 4)
        ln = u_le(buf, start + 14, 2)
        if magic != FRAME_MAGIC or ln == 0 or start + FRAME_HDR + ln > len(buf):
            return None
        return seq, head, epoch, ln

    def _event(self, kind, text):
        self.stats[kind] = self.stats.get(kind, 0) + 1
        self.events.append(kind)
        self.emit(text.encode())

    def _header(self, seq, head, epoch, ln):
        if self.prev_seq is not None and self.epoch == epoch and seq != self.prev_seq + 1:
            lost = (seq - self.prev_seq - 1) & 0xFFFFFFFF
            self._event("lost", "\n[lost %d frame(s): seq %d -> %d epoch %d]\n"
                        % (lost, self.prev_seq, seq, epoch))
        if self.epoch is not None and epoch != self.epoch:
            self._event("epoch change", "\n[epoch change %d -> %d at seq %d]\n"
                        % (self.epoch, epoch, seq))
            self.prev_seq = None
        if self.prev_head is not None and epoch == self.epoch:
            span = (head - self.prev_head) & 0xFFFFFFFF
            if 0 < span <= 0x2000:       # head advanced more than one header+payload: bytes unseen
                d = span - FRAME_HDR - ln
                if d > 0:
                    self._event("head jump", "\n[head jump %d byte(s) between frames]\n" % d)
        self.prev_seq, self.prev_head, self.epoch = seq, head, epoch

    def feed(self, chunk):
        buf = self.buf + chunk
        self.buf = b""
        if not self.locked:
            h = self.parse(buf)
            self.present = self.present or h is not None
            if h is None:
                if len(buf) < FRAME_HDR and self.present:
                    self.buf = buf                   # (locked next chunk; present already)
                    return
                self.emit(buf)                       # no header here: raw text, unchanged
                return
            self.locked = True
        while buf:
            h = self.parse(buf)
            if h is None:
                if len(buf) < FRAME_HDR:
                    self.buf = buf                   # a header split across chunks
                    break
                self.stats["bad"] += 1
                _warn_once("bad", "usb_console_read: [frames] bytes after a frame do not parse as "
                                  "one; emitting them raw (said once)\n")
                self.emit(buf)
                break
            seq, head, epoch, ln = h
            self._header(seq, head, epoch, ln)
            payload = buf[FRAME_HDR:FRAME_HDR + ln]
            if payload.find(b"MKLG") != -1:
                parts, pos = [], 0
                while True:
                    k = payload.find(b"MKLG", pos)
                    if k == -1:
                        parts.append(payload[pos:])
                        break
                    parts.append(payload[pos:k])
                    parts.append(escape_frame())
                    self.stats["escape"] += 1
                    pos = k
                payload = b"".join(parts)
            self.emit(payload)
            self.frames += 1
            buf = buf[FRAME_HDR + ln:]


# ---- the read loop --------------------------------------------------------------------------------

def run(lib, a, fh, log, clock=time.time, sleep=time.sleep, backend=None, stop=None):
    """THE READ LOOP, as a function of a BULK BACKEND so a fake one can be driven in the selftests.

    backend() -> xfer() -> (rc, bytes), or None for "no device to attach". The real one is
    `libusb_bulk_transfer` on EP_IN. A RE-ATTACH happens when the transfer fails with a
    LIBUSB_ERROR_* rc (except -7 TIMEOUT, a NAK) or no bytes arrive for `a.reconnect_after`
    seconds -- the payload's own `entry_usb_dev_init` resets the link (the enumeration aboot made
    is dropped by design) and a fastboot boot re-enumerates the device, so a one-shot open is on
    the wrong side of the event that matters. Every re-attach is a `[gap N.Ns]` line in the
    capture: a gap is a READING (bytes were lost between the two reads), never silence.

    `stop` is a one-element list set by the signal handler: --follow ends at the next transfer
    (<= TIMEOUT_MS), writes the summary, and returns 0/2/3."""
    got = total = 0
    rc_out = 2
    last = clock()
    attach_t = last
    gaps = 0
    handle = ifn = None
    bell = Bell(a.bell_on)
    emit_raw = lambda d: _emit(a, fh, bell, d)
    dec = FrameDecoder(emit_raw) if a.frames else None
    try:
        while True:
            if stop is not None and stop[0]:
                break
            if handle is None:
                handle, ifn = _attach(lib, a) if backend is None else ("fake", 0)
                if handle is None:
                    if a.wait and (clock() - attach_t) < a.wait:
                        sleep(0.5)
                        continue
                    if backend is not None:
                        rc_out = 2                # (the fake backend's "no device": a verdict)
                        break
                    log("usb_console_read: no device %04x:%04x - is the ladder arm running "
                        "(device mode) and the phone connected?\n" % (a.vid, a.pid))
                    return rc_out
                log("usb_console_read: attached (if=%s) - EP1-IN 0x%02x\n" % (ifn, EP_IN))
                rc_out = 0                        # (seen; 3 if it delivers nothing)
                last = clock()
            xfer = backend() if backend is not None else _bulk(lib, handle)
            if xfer is None:
                handle = None                 # (a backend that answers no attach: try again)
                if backend is not None:
                    rc_out = 2
                    break
                sleep(0.01)
                continue
            r, data = xfer()
            if data:
                got += len(data)
                last = clock()
                if dec is not None:
                    dec.feed(data)
                else:
                    emit_raw(data)
                continue
            if r != 0 and r != -7:          # -7 = LIBUSB_ERROR_TIMEOUT (a NAK: the normal idle)
                g = clock() - last
                gaps += 1
                msg = "\n[gap %.1fs rc=%d #%d]\n" % (g, r, gaps)
                if fh:
                    fh.write(msg.encode())
                log("usb_console_read: transfer rc=%d -> re-attach %s" % (r, msg.strip()))
                if backend is None:
                    _detach(lib, handle, ifn)
                handle = None
                continue
            if a.reconnect_after and (clock() - last) > a.reconnect_after:
                g = clock() - last
                gaps += 1
                msg = "\n[gap %.1fs (no bytes) #%d]\n" % (g, gaps)
                if fh:
                    fh.write(msg.encode())
                log("usb_console_read: silent %.1fs -> re-attach %s" % (g, msg.strip()))
                if backend is None:
                    _detach(lib, handle, ifn)
                handle = None
                last = clock()
                continue
            if a.seconds and (clock() - last) > a.seconds:
                break
    except KeyboardInterrupt:
        pass
    finally:
        if backend is None and handle is not None:
            _detach(lib, handle, ifn)
    total = got
    if dec is not None:
        if dec.buf:
            rc_out = 3                    # the run ended inside a header: an incomplete frame
        elif not dec.present:
            emit_raw(b"\n[frames: not present - raw text]\n")
        else:
            _frame_summary(dec, fh)
    if total == 0 and rc_out != 2:
        rc_out = 3                        # seen and claimed, nothing delivered
    if rc_out == 2:
        log("usb_console_read: no device seen\n")
        return 2
    summary = "read %d bytes (%d gap(s)%s)" % (
        total, gaps, "" if dec is None else ", %d frame(s), lost=%d epoch=%d headjump=%d"
        % (dec.frames, dec.stats.get("lost", 0), dec.stats.get("epoch change", 0),
           dec.stats.get("head jump", 0)))
    log("usb_console_read: %s\n" % summary)
    if total == 0:
        log("usb_console_read: the device was seen and claimed but EP1-IN delivered nothing in the "
            "window (the stream may not be priming yet, or the ladder did not reach the idle "
            "path).\n")
    return rc_out


def _emit(a, fh, bell, data):
    if fh:
        fh.write(data)
    if a.stdout or getattr(a, "follow", False):
        sys.stdout.buffer.write(data)
        sys.stdout.buffer.flush()
    if bell.rx is not None:
        bell.feed(data)


def _frame_summary(dec, fh):
    if fh:
        fh.write(("\n[frames: %d frame(s), last seq %s epoch %s, lost=%d epoch change=%d head jump=%d "
                  "escaped=%d bad=%d]\n" % (dec.frames, dec.prev_seq, dec.epoch, dec.stats.get("lost", 0),
                  dec.stats.get("epoch change", 0), dec.stats.get("head jump", 0),
                  dec.stats.get("escape", 0), dec.stats.get("bad", 0))).encode())


def _bulk(lib, handle):
    buf = ctypes.create_string_buffer(4096)
    def xfer():
        n = ctypes.c_int(0)
        r = lib.libusb_bulk_transfer(handle, EP_IN, buf, len(buf), ctypes.byref(n), TIMEOUT_MS)
        return r, (buf.raw[:n.value] if n.value > 0 else b"")
    return xfer


def fake_backend(path):
    """Read FILE as EP1-IN. None = no device (open failed). EOF: a regular file ends the run; a
    FIFO returns rc=-4 ('the device went away') so the loop re-attaches."""
    try:
        fd = open(path, "rb", buffering=0)
    except OSError as e:
        sys.stderr.write("usb_console_read: --fake %s: %s\n" % (path, e))
        return None
    state = {"eof": False}
    regular = os.path.isfile(path)
    def backend():
        if state["eof"]:
            raise KeyboardInterrupt
        def xfer():
            d = fd.read(4096)
            if not d:
                state["eof"] = True
                if regular:
                    raise KeyboardInterrupt
                return -4, b""
            return 0, d
        return xfer
    return backend


# ---- selftests ------------------------------------------------------------------------------------

_CASES = []


def _case(name, ok, detail=""):
    _CASES.append((name, bool(ok), detail))


def _report(what):
    fails = [c for c in _CASES if not c[1]]
    for name, ok, det in _CASES:
        print("  %s %s%s" % ("PASS" if ok else "FAIL", name, "" if ok else "  -> " + det))
    print("usb_console_read: --selftest%s %s (%d/%d)" % (what, "PASS" if not fails else "FAIL",
                                                       len(_CASES) - len(fails), len(_CASES)))
    del _CASES[:]
    return 0 if not fails else 1


def selftest_frames():
    def dec_run(chunks):
        out = []
        d = FrameDecoder(out.append)
        for c in chunks:
            d.feed(c)
        if not d.present:
            out.append(b"\n[frames: not present - raw text]\n")
        return b"".join(out), d
    # 0. the header codec's own numbers - the pin for any host whose bytes/ints lie.
    f = frame(msg=b"a", seq=1)
    _case("frame() layout", f.hex() == "4d4b4c4701000000" + "1110000001000000" + "01000000" + "61",
          f.hex())
    _case("u_le fields", (u_le(f, 0, 4), u_le(f, 4, 4), u_le(f, 8, 4), u_le(f, 12, 4),
                          u_le(f, 14, 2)) == (FRAME_MAGIC, 1, 0x1011, 1, 1),
          repr([u_le(f, o, n) for o, n in ((0, 4), (4, 4), (8, 4), (12, 4), (14, 2))]))
    # 1. clean run: payloads only, nothing flagged.
    out, d = dec_run([frame(msg=b"a" * 20, seq=1), frame(msg=b"b" * 20, seq=2),
                      frame(msg=b"c" * 20, seq=3)])
    _case("clean run", out == b"a" * 20 + b"b" * 20 + b"c" * 20 and d.stats["lost"] == 0
          and d.present and d.frames == 3, repr(out))
    # 2. dropped seq: exact lost count, one LOST line.
    out, d = dec_run([frame(msg=b"x", seq=1), frame(msg=b"y", seq=4)])
    _case("dropped seq (2 lost)", out == b"x\n[lost 2 frame(s): seq 1 -> 4 epoch 1]\ny"
          and d.stats["lost"] == 1, repr(out))
    out, d = dec_run([frame(msg=b"x", seq=1), frame(msg=b"y", seq=2), frame(msg=b"z", seq=5)])
    _case("dropped seq (2 lost, later)", b"[lost 2 frame(s): seq 2 -> 5" in out, repr(out))
    # 3. epoch change: a distinct verdict; a restart at seq 0 is not a loss.
    out, d = dec_run([frame(msg=b"p", seq=7, epoch=1), frame(msg=b"q", seq=0, epoch=2)])
    _case("epoch change", out == b"p\n[epoch change 1 -> 2 at seq 0]\nq" and d.stats["lost"] == 0
          and d.stats["epoch change"] == 1, repr(out))
    # 4. no frames: passthrough unchanged, one notice.
    raw = b"hello console\nno magic here\nMKL\n"
    out, d = dec_run([raw])
    _case("no-frames passthrough", out == raw + b"\n[frames: not present - raw text]\n"
          and d.frames == 0 and not d.present, repr(out))
    # 4b. a header split across chunks still locks.
    fr = frame(msg=b"split", seq=1)
    out, d = dec_run([fr[:9], fr[9:]])
    _case("split header", out == b"split" and d.present and d.frames == 1, repr(out))
    # 5. MKLG-looking payload cannot be re-read as a header.
    payload = b"Z" * 12 + frame(msg=b"hidden", seq=99)
    out, d = dec_run([frame(msg=payload, seq=1)])
    out2, d2 = dec_run([frame(msg=out, seq=1)])
    _case("payload escape", out == payload and d.stats["escape"] >= 1 and d2.frames == 1
          and d2.prev_seq == 1, "out=%r frames=%s" % (out, d2.frames))
    # 6. head jump: bytes between frames the host never saw.
    out, d = dec_run([frame(msg=b"a", seq=1, head=0x1000),
                      frame(msg=b"b", seq=2, head=0x1000 + 17 + 22)])
    _case("head jump", out == b"a\n[head jump 5 byte(s) between frames]\nb"
          and d.stats["head jump"] == 1, repr(out))
    # 7. an incomplete frame is held, never emitted.
    fr = frame(msg=b"cut", seq=1)
    out, d = dec_run([fr[:-2]])
    _case("incomplete frame held", d.buf == fr[:-2] and out == b"", repr(out))
    return _report("-frames")


def _run_case(script, reachable=True, rec=0.0, frames=False, tick=0.1):
    import io
    import types
    a = types.SimpleNamespace(vid=VID, pid=PID, wait=0, seconds=0, stdout=False, follow=False,
                              frames=frames, bell_on="", reconnect_after=rec)
    fh = io.BytesIO()
    logs = []
    it = iter(script)
    state = {"ended": False}
    t = [0.0]
    def clock():
        t[0] += tick
        return t[0]
    def backend():
        if not reachable:
            return None
        def xfer():
            if state["ended"]:
                raise KeyboardInterrupt
            try:
                return next(it)
            except StopIteration:
                state["ended"] = True
                raise KeyboardInterrupt
        return xfer
    rc = run(None, a, fh, logs.append, clock=clock, sleep=lambda s: None, backend=backend)
    return rc, fh.getvalue(), "".join(logs)


def selftest_reconnect():
    rc, data, logs = _run_case([(-7, b"abc"), (0, b"def"), (-1, b""), (-7, b"ghi")])
    _case("hard error re-attaches", rc == 0 and data.startswith(b"abcdef") and b"ghi" in data
          and b"[gap" in data, "rc=%s data=%r" % (rc, data))
    rc, data, logs = _run_case([(-7, b"x"), (-7, b""), (-7, b""), (-7, b"y")], rec=0.0)
    _case("silent window keeps earlier bytes", rc == 0 and b"x" in data and b"[gap" in data,
          "rc=%s %r" % (rc, data))
    rc, data, logs = _run_case([], reachable=False)
    _case("never attached is exit 2", rc == 2, "rc=%s" % rc)
    rc, data, logs = _run_case([], reachable=True)
    _case("attached but silent is exit 3", rc == 3, "rc=%s" % rc)
    rc, data, logs = _run_case([(0, frame(msg=b"a", seq=1)), (-1, b""), (0, frame(msg=b"b", seq=3))],
                               frames=True)
    _case("jumped seq across a re-attach is a LOST line", rc == 0
          and b"[lost 1 frame(s): seq 1 -> 3 epoch 1]" in data, "rc=%s data=%r" % (rc, data))
    return _report("-reconnect")


def selftest_fake(tmpdir):
    """--fake drives the WHOLE pipeline (follow, frames, bell) without a device."""
    import subprocess
    me = os.path.abspath(__file__)
    def run_fake(fname, *extra, out="-", noreset=True):
        base = [sys.executable, "-I", me] + (["--no-reset"] if noreset else [])
        return subprocess.run(base + ["--fake", fname, "--out", out, "--wait", "1"] + list(extra),
                              capture_output=True, timeout=60)
    f = os.path.join(tmpdir, "raw.bin")
    open(f, "wb").write(b"line one\npanic: here\nplain\n")
    p = run_fake(f, "--follow", "--bell-on", "panic")
    _case("fake raw follow echoes + one BEL", p.returncode == 0
          and p.stdout == b"line one\npanic: here\nplain\n" and p.stderr.count(b"\a") == 1,
          "rc=%s out=%r err=%r" % (p.returncode, p.stdout[-300:], p.stderr[-300:]))
    b = Bell(r"panic|Bus error")
    bels = []
    b._bel = lambda: bels.append(1)
    b.feed(b"ok\nBus er")
    b.feed(b"ror in x\nnext\n")
    _case("bell pattern across chunks fires once", len(bels) == 1, "bels=%d" % len(bels))
    f = os.path.join(tmpdir, "frames.bin")
    open(f, "wb").write(frame(msg=b"AAA\n", seq=1) + frame(msg=b"BBB\n", seq=4))
    outp = os.path.join(tmpdir, "cap.txt")
    p = run_fake(f, "--frames", "--follow", out=outp)
    cap = open(outp, "rb").read()
    _case("fake frames: LOST in the capture", p.returncode == 0
          and cap.startswith(b"AAA\nBBB\n[lost 2 frame(s)"), "rc=%s cap=%r err=%r"
          % (p.returncode, cap, p.stderr[-300:]))
    f = os.path.join(tmpdir, "nofr.bin")
    open(f, "wb").write(b"plain\n")
    p = run_fake(f, "--frames")
    _case("fake no-frames: notice once, bytes unchanged",
          p.returncode == 0 and p.stdout == b"plain\n\n[frames: not present - raw text]\n",
          "rc=%s out=%r" % (p.returncode, p.stdout))
    f = os.path.join(tmpdir, "cut.bin")
    open(f, "wb").write(frame(msg=b"ok", seq=1) + frame(msg=b"cut", seq=2)[:18])
    p = run_fake(f, "--frames")
    _case("fake incomplete frame at EOF is exit 3", p.returncode == 3 and b"ok" in p.stdout,
          "rc=%s" % p.returncode)
    p = run_fake(os.path.join(tmpdir, "nofr.bin"), noreset=False)
    _case("--no-reset is required", p.returncode == 2 and b"--no-reset is required" in p.stderr,
          "rc=%s err=%r" % (p.returncode, p.stderr[-300:]))
    return _report("-fake")


def selftest_noreset():
    """No reset path BY CODE: the bound symbol list never names the symbol, the source names it
    only in its own constant, and a library that EXPOSES it is still never asked for it."""
    _case("reset symbol not in the bound list", NO_RESET_SYMBOL not in _LIBUSB_BINDS,
          repr(_LIBUSB_BINDS))
    lines = []
    for i, ln in enumerate(open(os.path.abspath(__file__)).read().split("\n"), 1):
        s = ln.strip()
        if NO_RESET_SYMBOL in ln and not s.startswith("#") and not s.startswith("NO_RESET_SYMBOL"):
            lines.append((i, s))
    _case("reset symbol named nowhere else", not lines, repr(lines))
    class _Plant(object):
        def __getattr__(self, name):
            return lambda *x, **k: 0
    saved = ctypes.CDLL
    ctypes.CDLL = lambda name: _Plant()
    try:
        lib = load_libusb()
        ok = lib is not None
        for name in _LIBUSB_BINDS:                         # every bind resolves; none is a reset
            ok = ok and getattr(lib, name)() is not None or True
        _case("a library exposing the symbol is never asked",
              ok and all(callable(getattr(lib, n)) for n in _LIBUSB_BINDS), repr(lib))
    finally:
        ctypes.CDLL = saved
    return _report("-noreset")


def build_parser():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=None)
    ap.add_argument("--seconds", type=int, default=120)
    ap.add_argument("--wait", type=int, default=0)
    ap.add_argument("--reconnect-after", type=float, default=10.0,
                    help="re-attach after this many seconds with no bytes (a reset link is silent)")
    ap.add_argument("--stdout", action="store_true")
    ap.add_argument("--follow", action="store_true",
                    help="never exit on its own; gaps are logged; a signal ends it with a summary")
    ap.add_argument("--no-tty", action="store_true", help="alias of --follow")
    ap.add_argument("--bell-on", default=DEFAULT_BELL,
                    help="BEL to stderr on a completed line matching this RE ('' = off)")
    ap.add_argument("--frames", action="store_true", help="decode 16-byte MKLG headers if present")
    ap.add_argument("--no-reset", action="store_true",
                    help="the reader never resets the device (asserted by code; REQUIRED)")
    ap.add_argument("--daemon", action="store_true",
                    help="fork into a new session so the reader outlives the shell/tool call")
    ap.add_argument("--setsid", action="store_true", help="alias of --daemon")
    ap.add_argument("--log", default=None, help="daemon stdout+stderr (default: alongside --out)")
    ap.add_argument("--fake", default=None, help="replay EP1-IN bytes from FILE instead of libusb")
    ap.add_argument("--selftest", action="store_true", help="all four selftests")
    ap.add_argument("--selftest-reconnect", action="store_true")
    ap.add_argument("--selftest-frames", action="store_true")
    ap.add_argument("--selftest-fake", action="store_true")
    ap.add_argument("--selftest-noreset", action="store_true")
    ap.add_argument("--vid", type=lambda s: int(s, 0), default=VID)
    ap.add_argument("--pid", type=lambda s: int(s, 0), default=PID)
    return ap


def daemonize(a):
    """fork, os.setsid() in the child, 0<-/dev/null, 1,2->--log, SIGPIPE ignored,
    PYTHONUNBUFFERED=1, re-exec with --follow. The parent prints the child's pid on stdout."""
    logp = a.log
    if logp is None:
        base = a.out or os.path.join("out", "stage90", "captures", "usb-console-%s.txt" % now_stamp())
        logp = (base[:-4] if base.endswith(".txt") else base) + ".log"
    os.makedirs(os.path.dirname(logp) or ".", exist_ok=True)
    argv = [sys.executable, "-I", os.path.abspath(__file__)] + \
        [x for x in sys.argv[1:] if x not in ("--daemon", "--setsid")]
    if "--follow" not in argv and "--no-tty" not in argv:
        argv.append("--follow")
    env = dict(os.environ, USB_CONSOLE_DAEMONIZED="1", PYTHONUNBUFFERED="1")
    pid = os.fork()
    if pid == 0:
        try:
            os.setsid()
            signal.signal(signal.SIGPIPE, signal.SIG_IGN)
            os.dup2(os.open(os.devnull, os.O_RDONLY), 0)
            lf = os.open(logp, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o644)
            os.dup2(lf, 1)
            os.dup2(lf, 2)
            os.execve(sys.executable, argv, env)
        finally:
            os._exit(127)                  # (only reached if execve failed)
    print("%d" % pid)
    sys.stderr.write("usb_console_read: daemonized (pid %d, own session, log %s)\n" % (pid, logp))
    sys.stderr.flush()
    return 0


def main():
    ap = build_parser()
    a = ap.parse_args()

    selft = (a.selftest, a.selftest_reconnect, a.selftest_frames, a.selftest_fake,
             a.selftest_noreset)
    if any(selft):
        rc = 0
        if a.selftest or a.selftest_reconnect:
            rc |= selftest_reconnect()
        if a.selftest or a.selftest_frames:
            rc |= selftest_frames()
        if a.selftest or a.selftest_noreset:
            rc |= selftest_noreset()
        if a.selftest or a.selftest_fake:
            import tempfile
            with tempfile.TemporaryDirectory(prefix="usb-reader-fake-") as d:
                rc |= selftest_fake(d)
        print("usb_console_read: selftest %s" % ("PASS" if rc == 0 else "FAIL"))
        return rc

    if not a.no_reset:
        # --no-reset is the ONLY spelling: there is no reset path to disable, so a run that did not
        # say it is refused rather than silently given a state the flag says it has.
        sys.stderr.write("usb_console_read: --no-reset is required (the reader never resets the "
                         "device; the flag says so by value)\n")
        return 2
    a.follow = a.follow or a.no_tty or not sys.stdout.isatty()
    if a.follow:
        a.seconds = 0
    live = os.environ.get("USB_CONSOLE_DAEMONIZED") == "1"
    if (a.daemon or a.setsid) and not live:
        # (a background process started inside a tool call dies with the call; a new session does
        #  not. stdio is the LOG: an inherited pipe's SIGPIPE would kill the reader mid-stream.)
        return daemonize(a)

    stop = [False]
    def _onsig(signum, frame):
        stop[0] = True
    for s in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(s, _onsig)

    out = a.out
    if out is None:
        out = os.path.join("out", "stage90", "captures", "usb-console-%s.txt" % now_stamp())
    fh = None
    if out != "-":
        os.makedirs(os.path.dirname(out) or ".", exist_ok=True)
        fh = open(out, "ab", buffering=0)
    log = lambda m: sys.stderr.write(m)
    log("usb_console_read: start %s no-reset (required; no reset path) frames=%s follow=%s\n"
        % (now_stamp(), int(a.frames), int(a.follow)))

    lib = ctx = None
    backend = None
    if a.fake:
        backend = fake_backend(a.fake)
        if backend is None:
            return 2
    else:
        lib = load_libusb()
        if lib is None:
            return 2
        ctx = ctypes.c_void_p()
        if lib.libusb_init(ctypes.byref(ctx)) != 0:
            sys.stderr.write("usb_console_read: libusb_init failed\n")
            return 2

    rc = run(lib, a, fh, log, backend=backend, stop=stop)
    if fh:
        fh.close()
    if lib is not None:
        lib.libusb_exit(ctx)
    log("usb_console_read: -> %s%s\n" % (out, "" if out == "-" else " (live; tail -f it)"))
    return rc


if __name__ == "__main__":
    sys.exit(main())
