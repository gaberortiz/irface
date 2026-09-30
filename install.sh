#!/usr/bin/env bash
# Install irface: fetch models, build the PAM module, install and start the
# systemd service, and optionally enroll a face.
#
#   sudo ./install.sh                       # full install, then prompt to enroll
#   sudo ./install.sh --download-models     # just fetch the ONNX weights
#   sudo ./install.sh --no-pam              # skip editing /etc/pam.d/sudo
#
# Re-running is safe: existing files are backed up, never silently clobbered.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PY=/usr/bin/python3
UNIT_SRC="$DIR/irface.service"
UNIT_DST=/etc/systemd/system/irface.service
PLUGIN_DIR="$HOME/.config/omarchy/plugins/irface"
DO_PAM=1
DO_MODELS=1
MODELS_ONLY=0
ENROLL_USER=""

die() { printf '\nERROR: %s\n' "$1" >&2; exit 1; }
step() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
info() { printf '    %s\n' "$1"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --download-models) MODELS_ONLY=1; shift ;;
    --no-pam)  DO_PAM=0; shift ;;
    --no-models) DO_MODELS=0; shift ;;
    --user)    ENROLL_USER="${2:?--user needs a name}"; shift 2 ;;
    -h|--help) sed -n '2,10p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

# --- root ---------------------------------------------------------------------
if [[ $MODELS_ONLY -eq 0 ]]; then
  [[ $EUID -eq 0 ]] || die "run as root: sudo $0"
  command -v systemctl >/dev/null || die "systemd not found; this installer targets systemd systems."
fi

# --- deps ---------------------------------------------------------------------
step "Checking dependencies"
if ! "$PY" -c 'import cv2' 2>/dev/null; then
  if command -v pacman >/dev/null; then
    die "python-opencv missing. Install it and re-run: sudo pacman -S python-opencv"
  fi
  die "python3 cannot import cv2. Install your distro's python-opencv bindings."
fi
info "opencv OK ($("$PY" -c 'import cv2; print(cv2.__version__)'))"

# --- models ------------------------------------------------------------------
if [[ $DO_MODELS -eq 1 ]]; then
  step "Fetching model weights"
  BASE=https://github.com/opencv/opencv_zoo/raw/main/models
  fetch() {
    local name="$1" want="$2" dest="$DIR/models/$1"
    if [[ -f "$dest" ]] && [[ "$(sha256sum "$dest" | cut -d' ' -f1)" == "$want" ]]; then
      info "$name already present and verified"; return
    fi
    [[ -f "$dest" ]] && info "$name present but checksum differs; re-downloading"
    mkdir -p "$DIR/models"
    curl -fL --progress-bar "$BASE/$(dirname "$name")/$name" -o "$dest.tmp" \
      || die "download failed for $name"
    local got; got="$(sha256sum "$dest.tmp" | cut -d' ' -f1)"
    [[ "$got" == "$want" ]] || { rm -f "$dest.tmp"; die "checksum mismatch for $name"; }
    mv "$dest.tmp" "$dest"
    info "$name OK"
  }
  fetch face_detection_yunet_2023mar.onnx \
        8f2383e4dd3cfbb4553ea8718107fc0423210dc964f9f4280604804ed2552fa4
  fetch face_recognition_sface_2021dec.onnx \
        0ba9fbfa01b5270c96627c4ef784da859931e02f04419c829e83484087c34e79
fi

if [[ $MODELS_ONLY -eq 1 ]]; then
  echo; info "models ready in $DIR/models"; exit 0
fi

for m in face_detection_yunet_2023mar.onnx face_recognition_sface_2021dec.onnx; do
  [[ -f "$DIR/models/$m" ]] || die "missing $DIR/models/$m (run: sudo $0 --download-models)"
done

# --- PAM module --------------------------------------------------------------
step "Building the PAM module"
if ! command -v make >/dev/null || ! [[ -e /usr/include/security/pam_appl.h ]]; then
  die "need make and PAM headers. On Arch: sudo pacman -S base-devel pam"
fi
make -C "$DIR/pam" clean >/dev/null
make -C "$DIR/pam"
make -C "$DIR/pam" install
info "installed /usr/lib/security/pam_irface.so"

# --- service -----------------------------------------------------------------
# The unit must embed this checkout's absolute path, so it is rendered from the
# template rather than shipped with a hardcoded one.
step "Installing the systemd service"
[[ -f "$UNIT_SRC" ]] || die "missing $UNIT_SRC"
if [[ -f "$UNIT_DST" ]] && ! grep -q "$DIR" "$UNIT_DST"; then
  cp -a "$UNIT_DST" "$UNIT_DST.irface.bak"
  info "backed up existing unit to $UNIT_DST.irface.bak"
fi
sed -e "s|@IRFACE_DIR@|$DIR|g" "$UNIT_SRC" > "$UNIT_DST"
chmod 644 "$UNIT_DST"
systemctl daemon-reload
systemctl enable --now irface.service
sleep 1
if systemctl is-active --quiet irface.service; then
  info "irface.service active (socket /run/irface/irface.sock)"
else
  info "WARNING: service did not start. Check: journalctl -u irface -n 30"
fi

# --- post-update hook --------------------------------------------------------
# `omarchy update` reinstalls the lock screen and silently drops face unlock.
# Omarchy calls `omarchy-hook post-update` after packages and migrations, which
# is the supported place to put this. The hook re-applies in --safe mode only.
step "Installing the post-update hook"
# omarchy-hook looks for ~/.config/omarchy/hooks/<name> and
# ~/.config/omarchy/hooks/<name>.d/. So a post-update hook belongs in
# hooks/post-update.d/, NOT hooks.d/ -- a top-level hooks.d/ is never read.
HOOK_D="$HOME/.config/omarchy/hooks/post-update.d"
HOOK_PATH="$HOOK_D/irface-reapply"
mkdir -p "$HOOK_D"
# The hook runs unattended, so it must be able to find the checkout without the
# plugin being loaded. Record the path; the hook reads it back.
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/irface"
mkdir -p "$CACHE_DIR"
printf '%s\n' "$DIR" > "$CACHE_DIR/root"
# .d/ is used rather than the plain hook name so an omarchy change to
# post-update itself cannot collide with ours, and so it is visibly ours.
cp "$DIR/omarchy-patch/hook-post-update" "$HOOK_PATH"
chmod +x "$HOOK_PATH"
info "hook installed ($HOOK_PATH)"
info "if it ever needs a password, run: sudo $DIR/omarchy-patch/reapply.sh --safe"

# --- bar panel plugin --------------------------------------------------------
# The settings UI is a real Omarchy plugin rather than a patch, so it survives
# `omarchy update` and gets the native enable/disable. The panel needs to know
# where this checkout lives to reach enroll.sh and reapply.sh, and the shell
# does not pass the environment through to plugins, so that path is baked into
# the deployed copy.
step "Installing the Face ID bar panel"
if command -v omarchy-plugin-validate >/dev/null; then
  rm -rf "$PLUGIN_DIR"
  mkdir -p "$PLUGIN_DIR"
  cp "$DIR/plugin/manifest.json" "$DIR/plugin/Panel.qml" "$PLUGIN_DIR/"
  sed -i "s|@IRFACE_DIR@|$DIR|g" "$PLUGIN_DIR/Panel.qml"
  if omarchy-plugin-validate "$PLUGIN_DIR" >/dev/null 2>&1; then
    # omarchy plugin add records the plugin in shell.json and hot-reloads it.
    omarchy plugin enable user.irface >/dev/null 2>&1 \
      || info "panel copied to $PLUGIN_DIR; enable it with: omarchy plugin enable user.irface"
    info "panel installed ($PLUGIN_DIR)"
  else
    info "WARNING: panel failed validation; not enabled. Run: omarchy plugin validate $PLUGIN_DIR"
  fi
else
  info "omarchy-plugin-validate not found; skipping the bar panel"
  info "the daemon, sudo auth, and the lock screen patch are unaffected"
fi

# --- PAM stack ---------------------------------------------------------------
if [[ $DO_PAM -eq 1 ]]; then
  step "Wiring pam_irface into sudo"
  "$DIR/install-sudo-pam.sh" || info "skipped (already present, or declined)"
fi

# --- enroll ------------------------------------------------------------------
step "Next: enroll a face"
if [[ -n "$ENROLL_USER" ]]; then
  info "enrolling $ENROLL_USER"
  sudo -u "$ENROLL_USER" env PYTHONPATH="$DIR" "$DIR/enroll.sh" -u "$ENROLL_USER" \
    || die "enrollment failed"
else
  cat <<EOF
    Enroll yourself (run as your normal user, not root):

        cd $DIR && ./enroll.sh

    Or for another account:  sudo $0 --user alice

    Until a template exists the daemon replies 'notemplate' and the password
    path is used, so nothing is locked out in the meantime.
EOF
fi

cat <<EOF

Done. Verify with:
    sudo -k && sudo -v          # look at the camera instead of typing
    $DIR/bin/irface verify -u ${SUDO_USER:-$(logname 2>/dev/null || echo <you>)} --watch

Uninstall: sudo ./remove.sh   (see --dry-run, --keep-models, --keep-data)
EOF
