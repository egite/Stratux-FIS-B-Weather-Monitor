#!/bin/bash
#
# Uninstall the Stratux FIS-B Weather Monitor (any prior version) and the
# backlog buffer daemon. Returns the Pi to its pre-install state so a fresh
# v2.2 install can be tested cleanly.
#
# Usage:
#   scp uninstall-fisb-weather.sh pi@stratux:/tmp/
#   ssh pi@stratux "sudo bash /tmp/uninstall-fisb-weather.sh"
#
# Persistent journald is intentionally LEFT enabled — it's a useful
# default and reverting it loses no information.
#

WWWDIR="/opt/stratux/www"
INDEXFILE="${WWWDIR}/index.html"
WEATHERFILE="${WWWDIR}/Weather.html"
WXSTNFILE="${WWWDIR}/wx_stations.json"
NAVAIDFILE="${WWWDIR}/navaids.json"
DAEMONFILE="/opt/stratux/stratux-fisb-buffer.py"
UNITFILE="/etc/systemd/system/stratux-fisb-buffer.service"
VENDORDIR="/opt/stratux/lib"

echo "=== Uninstalling FIS-B Weather Monitor ==="

# 1. Stop + disable + remove the systemd service
echo "[1/6] Removing systemd service..."
if command -v systemctl >/dev/null 2>&1; then
    systemctl stop    stratux-fisb-buffer.service 2>/dev/null || true
    systemctl disable stratux-fisb-buffer.service 2>/dev/null || true
    systemctl reset-failed stratux-fisb-buffer.service 2>/dev/null || true
fi
if [ -f "${UNITFILE}" ]; then
    rm -f "${UNITFILE}"
    echo "         removed ${UNITFILE}"
fi
if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload
fi

# 2. Remove the daemon binary
echo "[2/6] Removing daemon..."
if [ -f "${DAEMONFILE}" ]; then
    rm -f "${DAEMONFILE}"
    echo "         removed ${DAEMONFILE}"
else
    echo "         not present"
fi
pkill -f stratux-fisb-buffer.py 2>/dev/null || true

# 3. Remove the vendored Python libs (v2.1+)
echo "[3/6] Removing vendored libs..."
if [ -d "${VENDORDIR}" ]; then
    # Only remove the bits this installer put there, in case the user has
    # other stuff under /opt/stratux/lib for unrelated reasons.
    rm -rf "${VENDORDIR}/websocket" "${VENDORDIR}/six.py" \
           "${VENDORDIR}/__pycache__" 2>/dev/null
    rmdir "${VENDORDIR}" 2>/dev/null || true
    echo "         cleaned ${VENDORDIR}"
else
    echo "         not present"
fi
# Defensive: remove the temp tarball if the install left it behind
rm -f /tmp/stratux-fisb-vendor-libs.tar.gz 2>/dev/null || true

# 4. Remove any system-installed websocket-client (legacy v2.0/v2.1-rc paths)
echo "[4/6] Removing any system-installed websocket-client..."
if dpkg -l python3-websocket 2>/dev/null | grep -q '^ii'; then
    apt-get remove -y python3-websocket || true
    apt-get autoremove -y || true
    echo "         removed apt package"
elif command -v pip3 >/dev/null 2>&1 && pip3 show websocket-client >/dev/null 2>&1; then
    pip3 uninstall -y --break-system-packages websocket-client 2>/dev/null \
      || pip3 uninstall -y websocket-client 2>/dev/null || true
    echo "         removed pip package"
else
    echo "         not present"
fi

# 5. Remove web UI files
echo "[5/6] Removing web UI files..."
for f in "${WEATHERFILE}" "${WXSTNFILE}" "${NAVAIDFILE}"; do
    if [ -f "$f" ]; then
        rm -f "$f"
        echo "         removed $f"
    fi
done

# 6. Remove nav menu entry from index.html
echo "[6/6] Removing nav menu entry..."
if [ -f "${INDEXFILE}" ] && grep -q 'Weather.html' "${INDEXFILE}"; then
    sed -i '/href="\/Weather\.html".*FIS-B Weather/d' "${INDEXFILE}"
    if grep -q 'Weather.html' "${INDEXFILE}"; then
        echo "         WARNING: residual Weather.html reference left in ${INDEXFILE}"
    else
        echo "         removed nav entry"
    fi
else
    echo "         not present"
fi

echo ""
echo "=== Uninstall complete ==="
echo "Persistent journald was left enabled (harmless and useful)."
echo "You can now upload update-stratux-v2.2-fisb-weather.sh for a clean install test."

exit 0
