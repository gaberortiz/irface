# irface — Windows-Hello-style face auth for the Zenbook IR camera

Uses the infrared interface of the built-in UVC webcam (`/dev/video2`,
640x360 8-bit grayscale) with OpenCV's **YuNet** (detection) + **SFace**
(ArcFace-style 128-d embedding) on CPU. No extra pip deps.

## Install

```bash
git clone <this-repo> irface && cd irface
sudo ./install.sh
```

`install.sh` fetches the model weights (verifying SHA-256), builds and installs
`pam_irface.so`, renders `irface.service` with this checkout's absolute path,
enables and starts the daemon, and wires the module into `/etc/pam.d/sudo`.
Re-running is safe — existing files are backed up, never silently clobbered.

Useful flags: `--download-models` (weights only, no root), `--no-pam` (skip
editing the sudo stack), `--user alice` (enroll another account during install).

Manual prerequisites, if you are not on Arch: a system `python3` with OpenCV
bindings (`python-opencv` on Arch, `python3-opencv` on Debian/Ubuntu), plus
`base-devel` and PAM headers to build the module. The `bin/irface` launcher
hardcodes `/usr/bin/python3` because that is where Arch ships the bindings;
change `PY` there if yours lives elsewhere.

Face enrollment is separate from install and needs no root — see `./enroll.sh`
below.

## Enrolling a face

Anyone with an account on the machine can train irface to accept their face:

```bash
./enroll.sh                  # enroll yourself
./enroll.sh -u alice         # enroll another user
./enroll.sh --overwrite      # retrain an existing template
./enroll.sh --device /dev/video4
```

`enroll.sh` captures ~20 samples, averages them into one 128-d embedding stored
at `~/.local/share/irface/faces/<user>.npy` (mode 0600), then **verifies the
new template against a live frame** and fails loudly if it does not
authenticate. No daemon restart is needed — the template is re-read from disk on
every auth request.

The PAM module is `auth sufficient` and falls through to the password on any
failure, so an unenrolled or broken template degrades to normal password login
rather than locking you out.

## Usage
```bash
./bin/irface enroll  -u $USER            # capture ~20 samples, store averaged embedding
./bin/irface verify  -u $USER            # authenticate once, print cosine sim
./bin/irface verify  -u $USER --watch    # keep reporting scores
./bin/irface debug                        # dump raw/overlay/aligned frames to /tmp
```

Template is stored `0600` at `~/.local/share/irface/faces/<user>.npy`.

## IR-camera notes (measured, not assumed)
- Auto-exposure ramps for ~8 frames after open; `capture.py` discards a warm-up
  and keeps a rolling buffer that yields the **brightest** recent frame, because
  the illuminator alternates bright/dark frames. Effective ~7.5 usable fps.
- Verified landmark mapping: YuNet emits `[right_eye, left_eye, nose, mouth_r,
  mouth_l]`; this order already matches the SFace 112x112 template positionally,
  so **no reorder** is applied. This was confirmed numerically (intra-class
  cosine 0.93 identity vs 0.82 for a swapped map) — see `pipeline.py`.

## Matching
Cosine similarity; default threshold **0.36** (SFace LFW 1:1 point). Observed
genuine scores are ~0.82–0.95, a large margin, so `--threshold 0.5` is also
safe if you want more headroom against impostors.

## Known limitations (Phase 1)
- No liveness/anti-spoofing: a **printed photo or phone screen of your face**
  will authenticate. Fine for a personal laptop; not suitable as a sole factor
  for high-value targets.
- Single enrolled user; pick the largest face in frame.
- Threshold is not yet tuned against real impostors.

## Phase 2 — PAM auth (installed & working)
- `irface/daemon.py` — systemd service `irface.service` owns `/dev/video2` and
  answers `AUTH <user>` over the Unix socket `/run/irface/irface.sock`
  (world-writable so any local PAM client can reach it).
- `pam/pam_irface.c` — thin PAM module installed to `/usr/lib/security/pam_irface.so`.
  It calls the daemon and returns **PAM_SUCCESS** only on a real match; on *any*
  failure it returns **PAM_IGNORE** so the password path always runs. This means
  a stopped daemon, no match, timeout, or bad reply can never lock you out.
- Wired into `/etc/pam.d/sudo` as `auth sufficient` (backup at
  `/etc/pam.d/sudo.irface.bak`).

Verify end-to-end (no password):
```bash
sudo -k && sudo -n true     # exits 0 only if the face authenticates
```

Note: after one successful auth, `sudo` caches a timestamp for
`timestamp_timeout` (~5 min, standard sudo behavior) and won't re-scan your face
during that window. Use `sudo -k` to force a fresh (face) auth when testing.

**Revert sudo auth:**
```bash
sudo mv /etc/pam.d/sudo.irface.bak /etc/pam.d/sudo
```

**Manage the daemon:**
```bash
sudo systemctl {status,restart,stop} irface
sudo journalctl -u irface -f
```

## Screen lock / unlock

Face unlock is integrated into **omarchy's own stock lock screen** (the
Quickshell `omarchy.lock` plugin) rather than replacing it with a custom
locker. A separate lock screen was tried first and backed out: omarchy's lock
uses `WlSessionLock`, and once it reaches `secure` state the compositor shows
**only** the lock surface, so a face overlay can never be drawn on top of it.
Patching the lock itself is the only way to get a face affordance.

Files patched (all under `/usr/share/omarchy/shell/plugins/lock/`):
- `Service.qml` — a `faceProbeProc` / `facePollTimer` pair that calls the
  daemon, plus `faceState` (`idle`/`scanning`/`recognized`). Started from
  `onSecureStateChanged`, the same place the fingerprint flow starts, which is
  why it also works after a lid-close resume. The timer interval is switched
  between `facePollIntervalMs` (900 ms, someone is present) and
  `faceIdleRecheckMs` (4 s, nobody around).
- `LockView.qml` — the Face ID scanner drawn above the password field.

- **Unlock by face** — polls the daemon via `bin/irface-lockauth`; measured
  round trip ~1.8 s. The scanner sweeps while a probe is in flight and shows a
  green check on match.
- **Fallback** — the stock password field is untouched and always works.
- **Camera safety** — the daemon opens `/dev/video2` only for the duration of
  a probe and closes it after. An unreachable daemon disables the feature
  rather than retrying forever, and three consecutive *rejected faces* stop the
  poller so a persistent mismatch does not keep waking the illuminator.

### Probe exit codes
`bin/irface-lockauth` distinguishes why a probe failed, which matters because
the two cases deserve very different treatment:

| Exit | Meaning | Lock screen reaction |
| --- | --- | --- |
| 0 | face matched | unlock |
| 1 | a face was present but did not match | counts toward `faceMaxFailures` |
| 2 | daemon unreachable | disables the feature |
| 3 | **no face in frame at all** | does *not* count; re-arms in 4 s, capped at 3 |

The distinction exists because of a real bug. The poller used to treat every
non-zero exit as a failure, so locking the machine and walking away burned all
three attempts on an empty room. The poller then stopped for the remainder of
the lock session, so returning to the machine did nothing and the owner had to
type a password with their face right in front of the camera.

An empty room is not a rejected attempt, so it must not spend the budget. A
`noface` result re-arms on a slower 4 s cadence instead, and the fast 900 ms
interval resumes as soon as a face is actually detected. Practical effect:
**walking away is free, and coming back unlocks** — no mouse movement required,
which matters because "walk up and look at the camera" is the intended gesture.

Only genuine rejections (exit 1) still accumulate, so an impostor holding a
photo in front of the sensor still runs the poller out after three tries.

### Backing off so the machine can sleep

The empty-room re-arm is **capped** at `faceMaxNoFace` (3). An unbounded
re-arm was a second bug: the probe runs every few seconds forever, which keeps
`faceAuthenticating` true often enough to hold the display awake, and a blanked
display under the lock screen is what lets the machine drop to suspend. The
symptom is the machine sleeping as soon as face unlock fails to find anyone.

Capping it only helps if returning restarts it, so `resumeFaceOnWake()` is
called from every signal that means a person is present again:

- `onWakeRequested` — a mouse or keyboard wake request
- the suspend/resume transition, via `Qt.callLater`
- any wake while the lock screen is up

This is the piece that makes walk-away work *and* lets the machine sleep: the
loop stops so the box can idle, and the act of coming back re-arms it.

A rejected face (exit 1) is different from an empty room — someone is standing
there — so after `faceMaxFailures` it keeps trying, just slowly, at
`faceRejectedRecheckMs` (1.5 s).

`omarchy update` overwrites these files, which silently removes face unlock.
Restore it with:
```bash
omarchy-patch/reapply.sh          # install if missing
omarchy-patch/reapply.sh --check   # status only
omarchy-patch/reapply.sh --revert  # back to stock
```
Pristine upstream copies are kept in `omarchy-patch/originals/`.

> Quickshell does **not** hot-reload these files. After editing, run
> `omarchy-restart-shell` or the new code stays dormant with no error.

### Not used
- `irface/lock_gui.py` + `bin/irface-lock` (the standalone gtk4-layer-shell
  locker) are no longer wired to any keybinding. The files remain for
  reference; the live path is the QML patch.
- `hypridle` is not needed. omarchy's shell has its own `IdleMonitor`
  (screensaver at 150 s, lock at 300 s) and the stock lock recovers correctly
  across lid suspend/resume via its stranded-lock path.

## Security notes (important)
See [SECURITY.md](SECURITY.md) for the trust boundaries and how to report a
vulnerability privately. Key points:
- **No liveness/anti-spoofing.** A printed photo or a phone screen showing your
  face will unlock the screen and authenticate `sudo`. A single 2D IR camera
  cannot do passive liveness — that needs depth or IR reflectance analysis.
  Challenge-response (randomized blink / head-turn) is the realistic upgrade
  and blocks photos plus most video replay, at the cost of ~1–3 s and having to
  look at the screen. Not implemented; deliberately skipped.
- The stock lock is hardened: it uses `ext-session-lock-v1` in secure state, so
  the session *is* hard-frozen and screenshots are blocked.
- The daemon socket is `0666` so any local user can reach it and trigger their
  own auth, but the daemon verifies the peer's uid with `SO_PEERCRED` and
  refuses any request for a user other than the caller (root excepted). Without
  that check the socket was an oracle: any local user could ask about someone
  else's template and get back a live similarity score, which both confirmed
  whether a user was enrolled and let an attacker measure their own face
  against a victim's. The PAM path is independently safe — `pam_irface.c` takes
  the username from `pam_get_user()`, never from the request.
- The screen lock and `sudo` share the same anti-spoofing gap, so `sudo` is the
  weaker link in practice; keep `sudo` timeout short if you're worried.

## Hardware notes (corrected)
- `ASUP1206` on `hidraw1` is the **ASUS ambient-light sensor**, *not* a
  fingerprint reader. This laptop has **no fingerprint reader**, so there is no
  fingerprint fallback. (Earlier note claiming a fingerprint sensor was wrong.)
- The IR camera (`/dev/video2`) is opened **only while an auth is running** and
  closed ~8 s after the last request (`daemon.py` idle-close), so the scanner
  is not powered on at rest.

