"""Face-auth daemon: owns the IR camera and answers auth requests over a
Unix socket for the pam_irface PAM shim.

Run as root (needs camera access + serves all users):
    sudo python3 -m irface.daemon
"""
import argparse
import os
import pwd
import signal
import socket
import struct
import sys
import threading
import time

from . import auth, capture, models, store

DEFAULT_SOCKET = "/run/irface/irface.sock"
DEFAULT_DEVICE = capture.DEFAULT_DEVICE
DEFAULT_TIMEOUT = 5.0
DEFAULT_THRESHOLD = 0.36
BACKLOG = 8


def _ensure_sock_dir(path):
    d = os.path.dirname(path)
    if d and not os.path.isdir(d):
        os.makedirs(d, exist_ok=True)


def _uid_of(user):
    try:
        return pwd.getpwnam(user).pw_uid
    except KeyError:
        return None


def _peer_allowed(conn, user):
    """Check the connecting process really is `user` (or root).

    The socket is world-writable on purpose so any local user can trigger their
    own auth. Without this check that also lets any local user ask about
    *someone else's* template: a single request returns a similarity score,
    which both confirms whether a user is enrolled and acts as an oracle for
    measuring an attacker's own face against a victim's template.

    Returns (allowed: bool, reason: str).
    """
    try:
        raw = conn.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED,
                              struct.calcsize("3i"))
    except (OSError, AttributeError):
        # No SO_PEERCRED (non-Linux): fall back to trusting the request rather
        # than breaking auth outright. Documented as weaker in the README.
        return True, "nopee"
    _pid, uid, _gid = struct.unpack("3i", raw)
    if uid == 0:
        return True, "root"
    want = _uid_of(user)
    if want is not None and uid == want:
        return True, "self"
    return False, "notuser"


IDLE_CLOSE_SEC = 8.0  # close the camera this long after the last auth request


class FaceDaemon:
    def __init__(self, device=DEFAULT_DEVICE, socket_path=DEFAULT_SOCKET,
                 threshold=DEFAULT_THRESHOLD, timeout=DEFAULT_TIMEOUT,
                 idle_close=IDLE_CLOSE_SEC):
        self.device = device
        self.socket_path = socket_path
        self.threshold = threshold
        self.timeout = timeout
        self.idle_close = idle_close
        # Camera is opened lazily and closed when idle, so the IR sensor is
        # powered ONLY while an auth is actually being attempted.
        self._cap = None
        self._last_use = 0.0
        # Models load on first use rather than at startup. Measured: OpenCV's
        # DNN cache never returns the memory, so once loaded it is held for the
        # life of the process -- which means a daemon that never authenticates
        # never pays for it at all. The SFace session alone is ~59MB resident
        # on a ~112MB OpenCV baseline, and the daemon is idle nearly always.
        # The first probe after a cold start pays a ~1s load.
        self.det = None
        self.rec = None
        self.auth_lock = threading.Lock()  # camera is single-use; serialize
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self._stop = threading.Event()

    def _ensure_models(self):
        """Load the ONNX sessions on demand. Caller must hold auth_lock."""
        if self.det is None:
            self.det = models.detector()
        if self.rec is None:
            self.rec = models.recognizer()
        return self.det, self.rec

    def _ensure_cap(self):
        if self._cap is None:
            self._cap = capture.IRCapture(device=self.device)
        self._last_use = time.time()
        return self._cap

    def _janitor(self):
        """Close the camera once it's been idle for idle_close seconds.

        Models are deliberately NOT released here. OpenCV's DNN module caches
        each net for the life of the process and will not hand the memory back:
        measured, dropping the handles and forcing gc left RSS unchanged at
        176MB. So releasing them would only add a ~1s reload to the next probe
        for no benefit. Lazy loading at startup is what actually saves memory.
        """
        while not self._stop.wait(1.0):
            with self.auth_lock:
                if (self._cap is not None
                        and time.time() - self._last_use > self.idle_close):
                    self._cap.release()
                    self._cap = None

    def authenticate(self, user):
        tpl = store.load(user)
        if tpl is None:
            return False, 0.0, "notemplate"
        with self.auth_lock:
            cap = self._ensure_cap()
            det, rec = self._ensure_models()
            ok, sim, reason = auth.authenticate(cap, tpl, self.threshold,
                                                 self.timeout, det, rec)
            self._last_use = time.time()
        if ok:
            reason = "ok"
        return ok, sim, reason

    def _recv_line(self, conn):
        conn.settimeout(self.timeout + 5)
        buf = b""
        while b"\n" not in buf and len(buf) < 512:
            chunk = conn.recv(256)
            if not chunk:
                break
            buf += chunk
        return buf.split(b"\n", 1)[0].decode(errors="replace").strip()

    def handle(self, conn):
        try:
            req = self._recv_line(conn)
            parts = req.split()
            if len(parts) != 2 or parts[0].upper() != "AUTH":
                conn.sendall(b"NO badrequest\n")
                return
            user = parts[1]
            allowed, why = _peer_allowed(conn, user)
            if not allowed:
                # Deliberately generic: do not confirm whether `user` exists
                # or has a template to a caller with no right to ask.
                conn.sendall(b"NO denied 0.0000\n")
                return
            ok, sim, reason = self.authenticate(user)
            resp = f"{'OK' if ok else 'NO'} {reason} {sim:.4f}\n"
            conn.sendall(resp.encode())
        except (BrokenPipeError, ConnectionResetError):
            pass
        except socket.timeout:
            try:
                conn.sendall(b"NO timeout 0.0000\n")
            except OSError:
                pass
        finally:
            try:
                conn.close()
            except OSError:
                pass

    def serve_forever(self):
        _ensure_sock_dir(self.socket_path)
        if os.path.exists(self.socket_path):
            os.remove(self.socket_path)
        self.sock.bind(self.socket_path)
        os.chmod(self.socket_path, 0o666)
        self.sock.listen(BACKLOG)
        self.sock.settimeout(1.0)
        print(f"irface daemon: socket={self.socket_path} device={self.device} "
              f"threshold={self.threshold} timeout={self.timeout}", flush=True)
        threading.Thread(target=self._janitor, daemon=True).start()
        try:
            while not self._stop.is_set():
                try:
                    conn, _ = self.sock.accept()
                except socket.timeout:
                    continue
                except OSError:
                    if self._stop.is_set():
                        break
                    continue
                t = threading.Thread(target=self.handle, args=(conn,), daemon=True)
                t.start()
        finally:
            self.shutdown()

    def shutdown(self):
        self._stop.set()
        try:
            self.sock.close()
        except OSError:
            pass
        try:
            if os.path.exists(self.socket_path):
                os.remove(self.socket_path)
        except OSError:
            pass
        with self.auth_lock:
            if self._cap is not None:
                self._cap.release()
                self._cap = None
        print("irface daemon: stopped", flush=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-d", "--device", default=DEFAULT_DEVICE)
    ap.add_argument("-s", "--socket", default=DEFAULT_SOCKET)
    ap.add_argument("-t", "--threshold", type=float, default=DEFAULT_THRESHOLD)
    ap.add_argument("--timeout", type=float, default=DEFAULT_TIMEOUT)
    args = ap.parse_args()

    d = FaceDaemon(device=args.device, socket_path=args.socket,
                   threshold=args.threshold, timeout=args.timeout)
    signal.signal(signal.SIGTERM, lambda *_: d._stop.set())
    signal.signal(signal.SIGINT, lambda *_: d._stop.set())
    try:
        d.serve_forever()
    except Exception as e:
        print(f"daemon error: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
