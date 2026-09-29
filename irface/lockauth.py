"""One-shot face authentication for the Omarchy stock lock screen.

Exits 0 on a face match, 1 on no match, 2 when the daemon is unreachable.
The whole call is hard-bounded so a wedged daemon can never leave the QML
timer spinning.
"""

import os
import socket
import sys

# Deliberately NOT imported from .daemon: that module pulls in the OpenCV and
# model stack at import time, which costs ~120MB RSS and ~0.5s CPU per call.
# This probe runs on a timer while the screen is locked, so it must stay tiny.
# Keep this literal in sync with daemon.DEFAULT_SOCKET.
DEFAULT_SOCKET = "/run/irface/irface.sock"

# Must stay below the QML poll interval's timeout wrapper, which is 10s.
RECV_TIMEOUT = 9.0


def main(argv=None):
    sock_path = (argv or sys.argv[1:]) or [os.environ.get("IRFACE_SOCKET", DEFAULT_SOCKET)]
    sock_path = sock_path[0]
    user = os.environ.get("USER", "")

    if not os.path.exists(sock_path):
        print("no-daemon", file=sys.stderr)
        return 2

    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(RECV_TIMEOUT)
        s.connect(sock_path)
        s.sendall(f"AUTH {user}\n".encode())
        data = s.recv(256).decode(errors="replace").strip()
        s.close()
    except OSError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2

    if data.startswith("OK"):
        return 0
    if "noface" in data:
        print(data or "no-face", file=sys.stderr)
        return 3  # no face seen at all; don't count as a failure
    print(data or "no-match", file=sys.stderr)
    return 1  # face seen but did not match


if __name__ == "__main__":
    raise SystemExit(main())
