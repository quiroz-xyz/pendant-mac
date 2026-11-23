#!/usr/bin/env python3
"""Send commands to the pendant's USB shell and print the replies.

With the pendant plugged in over a USB data cable, it appears as a serial
port with a command shell (this is not documented by Limitless).

    python3 tools/pendant_usb.py help
    python3 tools/pendant_usb.py "storage status"
    python3 tools/pendant_usb.py "ble unpair"      # clears the phone pairing

Some shell commands erase recordings or rewrite the pendant's storage
(storage erase/clear/wipe, flash, ftl, mcuboot, devmem, crypto gen_keys).
Only send commands you understand.
"""
import glob
import os
import re
import select
import sys
import time


def main() -> int:
    commands = sys.argv[1:]
    if not commands:
        print(__doc__)
        return 1
    ports = sorted(glob.glob("/dev/cu.usbmodem*"))
    if not ports:
        print("No pendant found on USB. Check the cable carries data, and try "
              "unplugging and replugging the hub or cable.")
        return 2
    fd = os.open(ports[0], os.O_RDWR | os.O_NONBLOCK | os.O_NOCTTY)

    def drain(seconds: float) -> str:
        buf = b""
        end = time.time() + seconds
        while time.time() < end:
            ready, _, _ = select.select([fd], [], [], 0.3)
            if ready:
                try:
                    buf += os.read(fd, 4096)
                except BlockingIOError:
                    pass
        return re.sub(r"\x1b\[[0-9;]*[A-Za-z]", "", buf.decode("utf-8", "replace"))

    drain(1.5)  # discard the boot log the pendant replays on connect
    for command in commands:
        os.write(fd, (command + "\r").encode())
        print(f"===== {command} =====")
        print(drain(3))
    os.close(fd)
    return 0


if __name__ == "__main__":
    sys.exit(main())
