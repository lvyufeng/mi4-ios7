#!/usr/bin/env bash
# 1030 device-return sentinel.  Polls for 4a2fe00b; when it is back, recovers the
# last_kmsg (read-only) and reports whether the capture is NEWER than the 1030 boot
# epoch (1792217325 = 2026-10-17 06:08:45 UTC).  Does NOT boot anything.
BOOT_EPOCH=1792217325
while true; do
  if timeout 12 adb devices 2>/dev/null | grep -q 4a2fe00b; then
    echo "adb UP at $(date -u +%H:%M:%S)"
    scripts/recover_last_kmsg.sh --read-only >/tmp/recover_1030.log 2>&1 || true
    _last=$(ls -1t out/stage90/captures/recovered-*-last_kmsg.txt 2>/dev/null | head -1)
    if [[ -n $_last ]]; then
      _e=$(stat -c %Y "$_last")
      if (( _e >= BOOT_EPOCH )); then
        echo "NEW CAPTURE ($(date -d @$_e -u +%H:%M:%S) >= boot): $_last"
        python3 -I tools/check_1030_capture.py "$_last"
      else
        echo "STALE SLOT still ($(date -d @$_e -u +%H:%M:%S) < boot): $_last"
      fi
    fi
    break
  fi
  if timeout 15 fastboot devices 2>/dev/null | grep -q 4a2fe00b; then
    echo "fastboot UP at $(date -u +%H:%M:%S) - NOT booting anything"
    break
  fi
  sleep 30
done
