#!/usr/bin/env bash
# Train irface to accept a user's face.
#
# One-shot onboarding: preflight checks, capture ~20 samples, write the averaged
# 128-d embedding, then confirm it actually authenticates. Safe to re-run --
# existing templates are kept unless --overwrite is passed.
#
#   ./enroll.sh                 # enroll the invoking user
#   ./enroll.sh -u alice        # enroll another user (needs their permission)
#   ./enroll.sh --overwrite     # retrain from scratch
#   ./enroll.sh --device /dev/video4
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PY=/usr/bin/python3          # Arch ships the OpenCV bindings for the system python
THRESHOLD=0.36               # must match the daemon's default (daemon.py)
SAMPLES=20
DEVICE=/dev/video2           # overridable below; must match daemon.py too
OVERWRITE=""
USER_ARG=""

die() { printf '\nERROR: %s\n' "$1" >&2; exit 1; }
info() { printf '  %s\n' "$1"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    -u|--user)     USER_ARG="${2:?--user needs a name}"; shift 2 ;;
    -d|--device)   DEVICE="${2:?--device needs a path}"; shift 2 ;;
    -n|--samples)  SAMPLES="${2:?--samples needs a number}"; shift 2 ;;
    -t|--threshold) THRESHOLD="${2:?--threshold needs a number}"; shift 2 ;;
    --overwrite)   OVERWRITE="--overwrite"; shift ;;
    -h|--help)     sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

TARGET="${USER_ARG:-${USER:-$(id -un)}}"
export PYTHONPATH="$DIR${PYTHONPATH:+:$PYTHONPATH}"
export PYTHONDONTWRITEBYTECODE=1

echo "irface enrollment"
echo "  user     : $TARGET"
echo "  camera   : $DEVICE"
echo "  samples  : $SAMPLES"
echo "  threshold: $THRESHOLD"

# --- preflight ----------------------------------------------------------------
echo
echo "[1/4] Checking dependencies"

[[ -x "$PY" ]] || die "$PY not found. On Arch: sudo pacman -S python"
"$PY" -c 'import cv2' 2>/dev/null \
  || die "python-opencv missing for $PY. On Arch: sudo pacman -S python-opencv
       (the plain 'opencv' package has no Python bindings)"

for m in face_detection_yunet_2023mar.onnx face_recognition_sface_2021dec.onnx; do
  [[ -f "$DIR/models/$m" ]] || die "missing model: $DIR/models/$m"
done
info "python + opencv + models OK"

# Camera must be readable *by the enrolling user*. Enrolling needs no root:
# the template lands in that user's own ~/.local/share, mode 0600.
if [[ ! -e "$DEVICE" ]]; then
  die "$DEVICE does not exist. Find the IR sensor with: ls /dev/video*
       then re-run with --device <path>."
fi
if ! "$PY" - "$DEVICE" <<'EOF'
import sys, cv2
cap = cv2.VideoCapture(sys.argv[1], cv2.CAP_V4L2)
ok = cap.isOpened()
cap.release()
sys.exit(0 if ok else 1)
EOF
then
  die "cannot open $DEVICE as $(id -un).
       Fix camera access, then re-run:
         sudo usermod -aG video $USER   # then log out and back in
       or run the enrollment itself with: sudo -E $0 ${USER_ARG:+-u $TARGET}
       (an IR sensor in use by a running daemon can also block this --
        stop it first: sudo systemctl stop irface)"
fi
info "camera $DEVICE is accessible"

# Refuse to clobber a working template without being asked.
TPL="$("$PY" -c "from irface import store; print(store.template_path('$TARGET'))")"
if [[ -f "$TPL" && -z "$OVERWRITE" ]]; then
  die "a template already exists for $TARGET at:
       $TPL
       Re-run with --overwrite to retrain, or leave it as is."
fi

# --- capture ------------------------------------------------------------------
echo
echo "[2/4] Capturing samples -- look at the camera and stay still"
"$PY" -m irface.enroll -u "$TARGET" -d "$DEVICE" -n "$SAMPLES" $OVERWRITE \
  || die "enrollment failed (not enough good samples? check lighting/position)."

# --- confirm ------------------------------------------------------------------
# Enrolling only proves samples were captured. Verify that the stored template
# actually authenticates a live face, otherwise a bad capture looks successful.
echo
echo "[3/4] Verifying the new template (this is the real test)"
if "$PY" -m irface.verify -u "$TARGET" -d "$DEVICE" -t "$THRESHOLD" --timeout 8; then
  echo
  echo "[4/4] Done -- $TARGET is enrolled."
else
  echo
  die "verification FAILED. The template was written but does not authenticate.
       Most likely cause: inconsistent lighting or a partial face in frame.
       Re-run with --overwrite and retry in even lighting."
fi

cat <<EOF

Next steps
  Template : $TPL (mode 0600, owned by $TARGET)
  Live test: ./bin/irface verify -u $TARGET --watch
  Lock test: sudo bin/irface-lockauth

Notes
  - No restart needed. The daemon reloads the template from disk on every
    auth request, so it picks this up immediately.
  - Keep the camera and threshold consistent. If you enrolled with
    --device X, the daemon must also use X, or scores will not match.
  - Genuine scores run ~0.82-0.95 against a 0.36 threshold, so there is a
    wide margin. Raise it with -t if you want it stricter.
EOF
