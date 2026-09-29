# Security Policy

## Scope

irface authenticates a person to their own machine using the built-in webcam's
infrared sensor. It runs a root daemon that owns the camera, a PAM module in the
`sudo` stack, and a patch to the omarchy lock screen.

## Reporting a vulnerability

**Do not open a public issue for a security problem.** Use GitHub's private
reporting instead: *Security → Report a vulnerability* on
<https://github.com/gaberortiz/irface>.

Please include the version or commit, your omarchy/Arch version, and how the
daemon behaved (`sudo journalctl -u irface -n 50`). Expect a few days for a
response; this is a one-person project.

## Known limitations that are design choices, not bugs

These are already documented in the README and are **not** vulnerabilities to
report — they are accepted trade-offs:

- **No liveness or anti-spoofing.** A printed photo or a phone screen showing
  your face will unlock the screen and authenticate `sudo`. A single 2D IR
  camera cannot do passive liveness detection.
- **`sudo` inherits the same gap as the lock screen**, so `sudo` is the weaker
  link in practice. Keep its timeout short.
- **Face templates are stored unencrypted** at
  `~/.local/share/irface/faces/<user>.npy`, mode `0600`. Anyone who can read
  that file can reconstruct an embedding of your face.
- **Threshold is fixed at cosine 0.36**, the SFace LFW 1:1 operating point.
  Loosening it trades false rejects for false accepts.

## Trust boundaries

For anyone auditing this, the pieces that matter:

- The daemon socket is `0666` so any local user can trigger their own auth.
  The daemon checks the peer uid via `SO_PEERCRED` and rejects requests for
  any user other than the caller, so it cannot be used to probe someone else's
  template.
- `pam/pam_irface.c` takes the target username from `pam_get_user()`, never
  from the socket request, so a client cannot forge an auth for another user.
- The PAM module is registered `auth sufficient` and returns `PAM_IGNORE` on
  any failure, so a broken or absent daemon degrades to password auth rather
  than locking you out.
- The IR camera is opened only while an auth is actually in flight, and closed
  after `idle_close` seconds of inactivity.
