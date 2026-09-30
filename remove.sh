#!/usr/bin/env bash
# Remove irface from this machine, restoring what it changed.
#
# Reverses install.sh and install-sudo-pam.sh. The Omarchy lock patch is
# restored too, because leaving a half-removed face unlock on the lock screen
# is worse than never having installed it.
#
#   sudo ./remove.sh                # remove everything
#   sudo ./remove.sh --keep-models  # keep the downloaded ONNX weights
#   sudo ./remove.sh --keep-data    # keep enrolled face templates
#   sudo ./remove.sh --dry-run      # print what would happen, change nothing
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UNIT=/etc/systemd/system/irface.service
UNIT_BAK="$UNIT.irface.bak"
SUDO_PAM=/etc/pam.d/sudo
LOCK_DIR=/usr/share/omarchy/shell/plugins/lock
KEEP_MODELS=0
KEEP_DATA=0
DRY=0

for arg in "$@"; do
  case "$arg" in
    --keep-models) KEEP_MODELS=1 ;;
    --keep-data)   KEEP_DATA=1 ;;
    --dry-run)     DRY=1 ;;
    -h|--help)     sed -n '2,10p' "$0"; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

[[ $EUID -eq 0 ]] || { echo "run as root: sudo $0" >&2; exit 1; }

# Everything below is a no-op when the thing is already absent, so this is safe
# to run twice and safe to run on a machine that never had irface.
run() {
  if [[ $DRY -eq 1 ]]; then printf '  would: %s\n' "$*"; return; fi
  "$@"
}

step() { printf '\n\033[1m%s\033[0m\n' "$*"; }
info() { printf '  %s\n' "$*"; }

# A message about something this run did. In dry-run mode nothing is done, so
# saying "removed x" there is a lie; this keeps the two modes honest. The verb
# is passed in so the dry-run line reads as a plan rather than a mangled past
# tense.
did() {
  if [[ $DRY -eq 1 ]]; then printf '  %s\n' "$*"; else printf '  %s\n' "$*"; fi
}
# Same, for a completed action: "would remove x" in dry-run, "removed x" live.
done_verb() {
  local past="$1" verb="$2" rest="${*:3}"
  if [[ $DRY -eq 1 ]]; then printf '  would %s %s\n' "$verb" "$rest"
  else printf '  %s %s\n' "$past" "$rest"; fi
}

# `systemctl list-unit-files | grep -q pat` is wrong under `set -o pipefail`:
# grep -q exits on its first match, systemctl dies of SIGPIPE, the pipeline
# reports failure, and the "is it installed?" check answers no. Read it into a
# variable first so there is no early-exiting pipe in the way.
unit_installed() {
  local listing
  listing="$(systemctl list-unit-files 2>/dev/null || true)"
  grep -qE '^irface\.service' <<<"$listing"
}

# --- 1. stop the service -----------------------------------------------------
step "Stopping the service"
if unit_installed; then
  run systemctl disable --now irface.service
  done_verb disabled "disable" "and stop irface.service"
else
  info "irface.service not installed"
fi
run rm -f /run/irface/irface.sock
run rmdir /run/irface 2>/dev/null || true

# --- 2. unhook PAM ------------------------------------------------------------
# The sudo stack is a security-critical file, so it is restored from the backup
# install-sudo-pam.sh made. If that backup is gone, the inserted line is removed
# instead, but the "#%PAM-1.0" marker must stay the first line, so this is done
# with the same in-place rewrite the installer used rather than a blind sed.
step "Unwiring pam_irface from sudo"
if [[ -f "$SUDO_PAM.irface.bak" ]]; then
  run cp -a "$SUDO_PAM.irface.bak" "$SUDO_PAM"
  run rm -f "$SUDO_PAM.irface.bak"
  done_verb restored restore "$SUDO_PAM from its backup"
elif grep -q "pam_irface.so" "$SUDO_PAM" 2>/dev/null; then
  warn="no backup found; removing the pam_irface line in place"
  printf '  %s\n' "$warn" >&2
  if [[ $DRY -eq 0 ]]; then
    python3 - "$SUDO_PAM" <<'PY'
import sys
path = sys.argv[1]
lines = [l for l in open(path).read().splitlines() if "pam_irface.so" not in l]
out = []
placed = False
for l in lines:
    if not placed and l.strip() == "#%PAM-1.0":
        out.append(l)
        continue
    if not placed:
        placed = True
    out.append(l)
open(path, "w").write("\n".join(out) + "\n")
PY
    chmod --reference="$SUDO_PAM" "$SUDO_PAM" 2>/dev/null || chmod 644 "$SUDO_PAM"
  fi
  done_verb removed remove "the pam_irface line from $SUDO_PAM"
else
  info "sudo PAM stack is untouched"
fi

# --- 3. restore the Omarchy lock screen --------------------------------------
# Left last, and only if it is actually patched: this touches files owned by
# the OS package, so it must not run when the lock screen is already stock.
step "Restoring the Omarchy lock screen"
if grep -ql "irface" "$LOCK_DIR"/*.qml 2>/dev/null; then
  if [[ -x "$DIR/omarchy-patch/reapply.sh" ]]; then
    if [[ $DRY -eq 1 ]]; then
      info "would run: $DIR/omarchy-patch/reapply.sh --revert"
    else
      "$DIR/omarchy-patch/reapply.sh" --revert
    fi
  else
    info "WARNING: lock files are patched but $DIR/omarchy-patch/reapply.sh is missing."
    info "Reinstall irface and re-run, or restore the files by hand from"
    info "  pacman -S omarchy-shell   # or your package manager"
  fi
else
  info "lock screen is already stock"
fi

# --- 4. unit + PAM module ----------------------------------------------------
step "Removing the unit and PAM module"
if [[ -f "$UNIT_BAK" ]]; then
  run cp -a "$UNIT_BAK" "$UNIT"
  run rm -f "$UNIT_BAK"
  done_verb restored restore "the previous $UNIT"
else
  run rm -f "$UNIT"
  done_verb removed remove "$UNIT"
fi
run rm -f /usr/lib/security/pam_irface.so
run systemctl daemon-reload

# --- 5. enrolled templates ---------------------------------------------------
# Biometric data, so it is only deleted when the owner asked for a full removal.
# Left to a non-root invocation for the per-user files.
step "Enrolled face templates"
if [[ $KEEP_DATA -eq 1 ]]; then
  info "kept (--keep-data)"
else
  if [[ $DRY -eq 1 ]]; then
    for d in /home/*/.local/share/irface/faces /root/.local/share/irface/faces; do
      [[ -d "$d" ]] && done_verb deleted delete "$d"
    done
  else
    for d in /home/*/.local/share/irface/faces /root/.local/share/irface/faces; do
      [[ -d "$d" ]] || continue
      rm -rf "$d"
      done_verb deleted delete "$d"
    done
    rmdir -p --ignore-fail-on-non-empty /home/*/.local/share/irface 2>/dev/null || true
  fi
fi

# --- 6. models ---------------------------------------------------------------
step "Model weights"
if [[ $KEEP_MODELS -eq 1 ]]; then
  info "kept (--keep-models)"
else
  for m in "$DIR"/models/*.onnx; do
    [[ -f "$m" ]] || continue
    run rm -f "$m"
    done_verb deleted delete "$(basename "$m")"
  done
  run rmdir "$DIR/models" 2>/dev/null || true
fi

if [[ $DRY -eq 1 ]]; then
cat <<EOF

Dry run: nothing above was changed. Re-run without --dry-run to apply.
EOF
else
cat <<EOF

Removed. Your lock screen, sudo, and face templates are back to normal.

Left in place on purpose:
  $DIR            the source checkout (delete it yourself if you are done)
  $DIR/models/README.md

  Models are ~36MB of third-party weights and are safe to delete; pass
  --keep-models to keep them, or --keep-data to keep your templates.
EOF
fi
