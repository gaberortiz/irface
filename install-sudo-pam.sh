#!/usr/bin/env bash
# Wire pam_irface into the sudo PAM stack. Backs up first.
# The module is `auth sufficient` and returns PAM_IGNORE on any failure, so
# the password path is always preserved as a fallback.
set -euo pipefail
SUDO_PAM=/etc/pam.d/sudo
MODULE=/usr/lib/security/pam_irface.so
SOCK=/run/irface/irface.sock
LINE="auth sufficient $MODULE socket=$SOCK timeout=6"

[ -f "$SUDO_PAM" ] || { echo "no $SUDO_PAM"; exit 1; }
[ -f "$MODULE" ]   || { echo "no $MODULE (build+install pam_irface.so first)"; exit 1; }

if grep -q "pam_irface.so" "$SUDO_PAM"; then
  echo "pam_irface already present in $SUDO_PAM; nothing to do."
  exit 0
fi

sudo cp -a "$SUDO_PAM" "$SUDO_PAM.irface.bak"
# Insert as the first auth line, but AFTER the "#%PAM-1.0" format marker,
# which MUST remain the first line for PAM to recognize the file.
sudo python3 - "$SUDO_PAM" "$LINE" <<'PY'
import sys
p, line = sys.argv[1], sys.argv[2]
lines = [l for l in open(p).read().splitlines() if "pam_irface.so" not in l]
out, inserted = [], False
for l in lines:
    out.append(l)
    if not inserted and l.startswith("#"):
        out.append(line)
        inserted = True
if not inserted:
    out.insert(0, line)
open(p, "w").write("\n".join(out) + "\n")
PY
echo "Inserted into $SUDO_PAM (backup: $SUDO_PAM.irface.bak):"
head -3 "$SUDO_PAM"
echo
echo "Test with:  sudo -k && sudo -v   (look at the camera)"
echo "Revert with: sudo mv $SUDO_PAM.irface.bak $SUDO_PAM"
