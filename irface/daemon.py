"""Face-auth daemon: owns the IR camera and answers auth requests over a
Unix socket for the pam_irface PAM shim.

Run as root (needs camera access + serves all users):
    sudo python3 -m irface.daemon
"""
import argparse
import os
import signal
import socket
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
        self.det = models.detector()
        self.rec = models.recognizer()
        self.auth_lock = threading.Lock()  # camera is single-use; serialize
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self._stop = threading.Event()

    def _ensure_cap(self):
        if self._cap is None:
            self._cap = capture.IRCapture(device=self.device)
        self._last_use = time.time()
        return self._cap

    def _janitor(self):
        """Close the camera once it's been idle for idle_close seconds."""
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
            ok, sim, reason = auth.authenticate(cap, tpl, self.threshold,
                                                 self.timeout, self.det, self.rec)
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
