"""irface lock — a fullscreen Hyprland/Wayland lock screen unlocked by face
(recognition via the irface daemon) with a real-password fallback.

Uses gtk4-layer-shell: a TOP-layer, exclusive-keyboard, fullscreen surface
that covers the session and captures input, so the desktop behind is not
usable until it is dismissed.

Run:  irface-lock            (or bind a key, e.g. Super+L)
Unlock by looking at the camera, or enter the account password.
"""
import getpass
import os
import socket
import subprocess
import threading
import time

import gi
gi.require_version("Gtk", "4.0")
gi.require_version("Gdk", "4.0")
gi.require_version("Gtk4LayerShell", "1.0")
from gi.repository import Gtk, Gdk, GLib, Gtk4LayerShell as LS  # noqa: E402

SOCKET = os.environ.get("IRFACE_SOCKET", "/run/irface/irface.sock")
PASSCHECK = os.environ.get("IRFACE_PASSCHECK", "/usr/local/bin/irface-passcheck")
DAEMON_CALL_TIMEOUT = 8.0
UI_FEEDBACK_DELAY = 0.7  # show "Welcome back" briefly before unlocking

CSS = b"""
window.lock { background: #14161a; }
.box { margin: 0; }
.title { color: #e6e8eb; font-size: 26px; font-weight: 700; }
.status { color: #9aa4af; font-size: 15px; }
.hint { color: #5c6670; font-size: 12px; }
.spin { font-size: 40px; color: #4da3ff; }
entry.pw { background: #1e2228; color: #e6e8eb; border: 1px solid #2c3238;
           border-radius: 8px; padding: 10px 12px; }
.entry-error { border-color: #d9534f; }
.unlock-ok { color: #3ecf8e; }
"""


def daemon_auth(user, sock_path=SOCKET, timeout=DAEMON_CALL_TIMEOUT):
    """Ask the daemon to authenticate user. Returns (ok, reason)."""
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(timeout)
        s.connect(sock_path)
        s.sendall(f"AUTH {user}\n".encode())
        data = s.recv(256).decode(errors="replace").strip()
        s.close()
    except OSError:
        return False, "daemon-unavailable"
    parts = data.split()
    if parts and parts[0] == "OK":
        return True, "ok"
    reason = parts[1] if len(parts) > 1 else "no-match"
    return False, reason


def passcheck(user, password):
    try:
        p = subprocess.run([PASSCHECK, user], input=(password + "\n").encode(),
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                           timeout=20)
        return p.returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        return False


class LockWindow(Gtk.Window):
    def __init__(self, user, app):
        super().__init__(application=app, title="Locked")
        self.user = user
        self.unlocked = threading.Event()
        self._face_ok = False

        # --- layer-shell: fullscreen, topmost, grab keyboard ---
        LS.init_for_window(self)
        LS.set_namespace(self, "irface-lock")
        LS.set_layer(self, LS.Layer.OVERLAY)
        LS.set_keyboard_mode(self, LS.KeyboardMode.EXCLUSIVE)
        LS.set_anchor(self, LS.Edge.TOP, True)
        LS.set_anchor(self, LS.Edge.BOTTOM, True)
        LS.set_anchor(self, LS.Edge.LEFT, True)
        LS.set_anchor(self, LS.Edge.RIGHT, True)
        LS.set_exclusive_zone(self, -1)
        LS.set_margin(self, LS.Edge.TOP, 0)
        self.add_css_class("lock")
        self.set_default_size(800, 600)
        self.set_decorated(False)

        # --- UI ---
        root = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=18)
        root.set_valign(Gtk.Align.CENTER)
        root.set_halign(Gtk.Align.CENTER)
        root.add_css_class("box")

        self.spin = Gtk.Label(label="◉")
        self.spin.add_css_class("spin")
        root.append(self.spin)

        title = Gtk.Label(label=f"Locked — {user}")
        title.add_css_class("title")
        root.append(title)

        self.status = Gtk.Label(label="Looking at the camera…")
        self.status.add_css_class("status")
        root.append(self.status)

        # password fallback
        row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        self.entry = Gtk.Entry(hexpand=True)
        self.entry.set_visibility(False)  # mask the password
        self.entry.set_input_purpose(Gtk.InputPurpose.PASSWORD)
        self.entry.set_placeholder_text("or enter password")
        self.entry.add_css_class("pw")
        self.entry.connect("activate", self._on_password)
        self.button = Gtk.Button(label="Unlock")
        self.button.add_css_class("pw")
        self.button.connect("clicked", self._on_password)
        row.append(self.entry)
        row.append(self.button)
        row.set_halign(Gtk.Align.CENTER)
        root.append(row)

        hint = Gtk.Label(label="Press Enter to submit the password")
        hint.add_css_class("hint")
        root.append(hint)

        self.set_child(root)
        # block window-manager close (Alt+F4) so the lock can't be dismissed
        self.connect("close-request", lambda *_: not self.unlocked.is_set())

    # ---------- unlock ----------
    def _do_unlock(self):
        if self.unlocked.is_set():
            return
        self.unlocked.set()
        GLib.idle_add(self._close_now)

    def _close_now(self):
        self.destroy()
        app = self.get_application()
        if app:
            app.quit()
        return False

    # ---------- face worker ----------
    def _start_face_worker(self):
        threading.Thread(target=self._face_loop, daemon=True).start()

    def _face_loop(self):
        daemon_alive = True
        while not self.unlocked.is_set():
            if daemon_alive:
                ok, reason = daemon_auth(self.user)
                if reason == "daemon-unavailable":
                    daemon_alive = False
                    GLib.idle_add(self._set_status,
                                  "Face unlock unavailable — enter password")
                    break
                if ok:
                    self._face_ok = True
                    GLib.idle_add(self._on_face_success)
                    return
                if reason == "notemplate":
                    GLib.idle_add(self._set_status,
                                  "No face enrolled — enter password")
                    break
            else:
                time.sleep(1.0)
            time.sleep(0.2)

    def _on_face_success(self):
        self._set_status("Welcome back", "unlock-ok")
        self.spin.set_text("✓")
        # brief delay so the user sees confirmation, then unlock
        GLib.timeout_add(int(UI_FEEDBACK_DELAY * 1000), self._do_unlock_cb)
        return False

    def _do_unlock_cb(self):
        self._do_unlock()
        return False

    def _set_status(self, text, extra=None):
        self.status.set_text(text)
        if extra:
            self.status.add_css_class(extra)
        return False

    # ---------- password ----------
    def _on_password(self, *_):
        pw = self.entry.get_text()
        if not pw:
            return
        self.entry.set_sensitive(False)
        self.button.set_sensitive(False)
        self._set_status("Checking…")
        threading.Thread(target=self._pw_worker, args=(pw,), daemon=True).start()

    def _pw_worker(self, pw):
        ok = passcheck(self.user, pw)
        GLib.idle_add(self._after_password, ok)

    def _after_password(self, ok):
        self.entry.set_sensitive(True)
        self.button.set_sensitive(True)
        self.entry.set_text("")
        if ok:
            self._set_status("Welcome back", "unlock-ok")
            self.spin.set_text("✓")
            GLib.timeout_add(int(UI_FEEDBACK_DELAY * 1000), self._do_unlock_cb)
        else:
            self._set_status("Incorrect password — try again")
            self.entry.add_css_class("entry-error")
        self.entry.grab_focus()
        return False


class LockApp(Gtk.Application):
    def __init__(self, user):
        super().__init__(application_id="dev.irface.lock")
        self.user = user

    def do_activate(self):
        prov = Gtk.CssProvider()
        prov.load_from_data(CSS)
        Gtk.StyleContext.add_provider_for_display(
            Gdk.Display.get_default(), prov,
            Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)
        win = LockWindow(self.user, self)
        win.present()
        win.entry.grab_focus()
        win._start_face_worker()


def main():
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument("-u", "--user", default=getpass.getuser())
    args = ap.parse_args()
    if not os.path.exists(SOCKET):
        print(f"warning: irface socket {SOCKET} not found; face unlock disabled",
              flush=True)
    app = LockApp(args.user)
    return app.run([])


if __name__ == "__main__":
    raise SystemExit(main())
