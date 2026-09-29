#!/usr/bin/env bash
# Re-apply the irface face-unlock patch to the Omarchy stock lock screen.
#
# `omarchy update` overwrites /usr/share/omarchy/shell/plugins/lock/*.qml,
# which silently removes face unlock. Run this afterwards to restore it.
#
#   ./reapply.sh            # install if the current files differ from ours
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
else
  omarchy-restart-shell >/dev/null 2>&1 || true
  echo "shell reloading. Test with: SUPER+CTRL+L"
fi
