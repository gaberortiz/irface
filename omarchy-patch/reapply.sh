#!/usr/bin/env bash
# Re-apply the irface face-unlock patch to the Omarchy stock lock screen.
#
# `omarchy update` overwrites /usr/share/omarchy/shell/plugins/lock/*.qml,
# which silently removes face unlock. Run this afterwards to restore it.
#
#   ./reapply.sh            # install if the current files differ from ours
#   ./reapply.sh --safe     # like the default, but never clobber changed upstream
#   ./reapply.sh --force    # install unconditionally
#   ./reapply.sh --check    # report only, change nothing
#   ./reapply.sh --revert   # restore the pristine upstream files
set -euo pipefail

here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd -- "$here/.." && pwd)"
target="/usr/share/omarchy/shell/plugins/lock"
mode="${1:-}"

# The patched QML refers to this checkout by absolute path, so it carries an
# @IRFACE_DIR@ placeholder that is rendered on install. That keeps the file
# portable across machines and across clone locations.
render() {
  sed "s|@IRFACE_DIR@|$root|g" "$1"
}

# Upstream ships a newer copy after an update; warn so it is never lost.
if [[ -f /usr/share/omarchy/shell/plugins/lock/.stock ]]; then
  echo "note: .stock marker present; upstream may have changed since backup."
fi

pristine() { md5sum "$1" | cut -d' ' -f1; }

SAFE_SKIPPED=0
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

for f in Service.qml LockView.qml; do
  ours="$here/$f"
  stock="$here/originals/$f"
  live="$target/$f"
  rendered="$tmp/$f"      # template with @IRFACE_DIR@ substituted
  render "$ours" > "$rendered"

  [[ -r "$rendered" ]] || { echo "missing patched file: $ours" >&2; exit 1; }
  [[ -r "$stock" ]] || { echo "missing pristine backup: $stock" >&2; exit 1; }

  case "$mode" in
    --check)
      if [[ "$(pristine "$rendered")" == "$(pristine "$live")" ]]; then
        echo "  $f: patched (live)"
      elif [[ "$(pristine "$stock")" == "$(pristine "$live")" ]]; then
        echo "  $f: STOCK -- face unlock is not active"
      else
        echo "  $f: DIVERGED from both patch and stock (upstream changed?)"
      fi
      ;;
    --revert)
      sudo install -m644 "$stock" "$live"
      echo "reverted $f to upstream"
      ;;
    --force)
      sudo install -m644 "$rendered" "$live"
      echo "installed $f"
      ;;
    --safe)
      # Used by the post-update hook, where nobody is watching. The live file
      # must be either already-patched or exactly the pristine copy this patch
      # was built against. If it is neither, upstream shipped a changed lock
      # screen and re-installing our old patch on top of it would silently
      # revert whatever they changed -- possibly breaking the lock screen. In
      # that case leave it alone and say so; a working stock lock screen with
      # no face unlock beats a patched one that does not open.
      if [[ "$(pristine "$rendered")" == "$(pristine "$live")" ]]; then
        echo "  $f: already patched"
      elif [[ "$(pristine "$stock")" == "$(pristine "$live")" ]]; then
        sudo install -m644 "$rendered" "$live"
        echo "  $f: re-applied after update"
      else
        echo "  $f: SKIPPED, upstream changed since this patch was built." >&2
        echo "    Review with: $0 --check" >&2
        SAFE_SKIPPED=1
      fi
      ;;
    "")
      if [[ "$(pristine "$rendered")" != "$(pristine "$live")" ]]; then
        sudo install -m644 "$rendered" "$live"
        echo "installed $f (patch was missing or stale)"
      fi
      ;;
    *)
      echo "unknown option: $mode" >&2; exit 2
      ;;
  esac
done

if [[ "$mode" == "--revert" ]]; then
  omarchy-restart-shell >/dev/null 2>&1 || true
  echo "shell reloading; stock lock restored."
elif [[ "$mode" == "--check" ]]; then
  :
elif [[ $SAFE_SKIPPED -eq 1 ]]; then
  # Nothing was installed, so the running shell is already correct. Restarting
  # it here would be a pointless reload of a live session.
  echo "upstream lock screen left untouched; no reload needed."
else
  omarchy-restart-shell >/dev/null 2>&1 || true
  echo "shell reloading. Test with: SUPER+CTRL+L"
fi
