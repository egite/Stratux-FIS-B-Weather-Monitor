param(
    [Parameter(Mandatory = $true)]
    [string]$Version
)

$ErrorActionPreference = 'Stop'

$src = Split-Path -Parent $MyInvocation.MyCommand.Definition
$out = Join-Path $src "update-stratux-v$Version-fisb-weather.sh"

$payloads = @(
    @{ Marker = 'WEATHER_HTML'; File = 'Weather.html' },
    @{ Marker = 'WX_STATIONS';  File = 'wx_stations.json' },
    @{ Marker = 'NAVAIDS';      File = 'navaids.json' },
    @{ Marker = 'DAEMON_PY';    File = 'stratux-fisb-buffer.py' },
    @{ Marker = 'SERVICE_UNIT'; File = 'stratux-fisb-buffer.service' },
    @{ Marker = 'VENDOR_LIBS';  File = 'vendor-libs.tar.gz' }
)

foreach ($p in $payloads) {
    $f = Join-Path $src $p.File
    if (-not (Test-Path -LiteralPath $f)) {
        throw "Missing source file: $($p.File)"
    }
}

$headerTemplate = @'
#!/bin/bash

WWWDIR="/opt/stratux/www"
INDEXFILE="${WWWDIR}/index.html"
WEATHERFILE="${WWWDIR}/Weather.html"
WXSTNFILE="${WWWDIR}/wx_stations.json"
NAVAIDFILE="${WWWDIR}/navaids.json"
DAEMONFILE="/opt/stratux/stratux-fisb-buffer.py"
UNITFILE="/etc/systemd/system/stratux-fisb-buffer.service"
VENDORDIR="/opt/stratux/lib"
VENDORTAR="/tmp/stratux-fisb-vendor-libs.tar.gz"

echo "=== Installing FIS-B Weather Monitor v__VERSION__ ==="

echo "[1/5] Enabling persistent journald..."
mkdir -p /var/log/journal
systemctl restart systemd-journald

echo "[2/5] Extracting files..."
extract_payload() {
    local marker="$1"
    local endmarker="$2"
    local outfile="$3"
    local mode="${4:-644}"
    local startline=$(grep -n "^${marker}$" "$0" | cut -d: -f1)
    local endline=$(grep -n "^${endmarker}$" "$0" | cut -d: -f1)
    if [ -z "$startline" ] || [ -z "$endline" ]; then
        echo "ERROR: Could not find payload markers for ${outfile}"
        return 1
    fi
    mkdir -p "$(dirname "${outfile}")"
    sed -n "$((startline + 1)),$((endline - 1))p" "$0" | base64 -d > "${outfile}"
    chmod "${mode}" "${outfile}"
    echo "         $(basename ${outfile}) ($(wc -c < ${outfile}) bytes)"
}

set -e
extract_payload "__WEATHER_HTML_BEGIN__"   "__WEATHER_HTML_END__"   "${WEATHERFILE}"
extract_payload "__WX_STATIONS_BEGIN__"    "__WX_STATIONS_END__"    "${WXSTNFILE}"
extract_payload "__NAVAIDS_BEGIN__"        "__NAVAIDS_END__"        "${NAVAIDFILE}"
extract_payload "__DAEMON_PY_BEGIN__"      "__DAEMON_PY_END__"      "${DAEMONFILE}" 755
extract_payload "__SERVICE_UNIT_BEGIN__"   "__SERVICE_UNIT_END__"   "${UNITFILE}"
extract_payload "__VENDOR_LIBS_BEGIN__"    "__VENDOR_LIBS_END__"    "${VENDORTAR}"
set +e

echo "[3/5] Installing vendored websocket-client + six..."
mkdir -p "${VENDORDIR}"
if tar -xzf "${VENDORTAR}" -C "${VENDORDIR}"; then
    echo "         unpacked into ${VENDORDIR}/"
    rm -f "${VENDORTAR}"
else
    echo "         ERROR: failed to unpack ${VENDORTAR}"
fi

DAEMON_READY=true
if ! PYTHONPATH="${VENDORDIR}" python3 -c "import websocket" 2>/dev/null; then
    echo "         WARNING: vendored websocket import failed."
    echo "         Daemon will be installed but NOT enabled."
    DAEMON_READY=false
fi

echo "[4/5] Updating navigation menu..."
if [ -f "${INDEXFILE}" ]; then
    if ! grep -q 'Weather.html' "${INDEXFILE}"; then
        sed -i '/<a class="list-group-item" href="#\/map"/a \
\t\t\t\t\t<a class="list-group-item" href="/Weather.html" target="_blank"><i class="fa fa-sun-o"><\/i>    FIS-B Weather <i class="fa fa-chevron-right pull-right"><\/i><\/a>' "${INDEXFILE}"
        echo "         nav entry added"
    else
        echo "         nav entry already present"
    fi
else
    echo "         WARNING: ${INDEXFILE} not found"
fi

echo "[5/5] Enabling stratux-fisb-buffer.service..."
if ! command -v systemctl >/dev/null 2>&1; then
    echo "         WARNING: systemctl not found, daemon not enabled"
elif [ "$DAEMON_READY" != "true" ]; then
    echo "         skipping enable — websocket import failed"
    systemctl stop stratux-fisb-buffer 2>/dev/null || true
    systemctl disable stratux-fisb-buffer 2>/dev/null || true
else
    systemctl daemon-reload
    systemctl enable stratux-fisb-buffer.service
    systemctl restart --no-block stratux-fisb-buffer.service 2>/dev/null || true
    echo "         service enabled (will activate ~60s after stratux is up)"
fi

echo ""
echo "=== FIS-B Weather Monitor v__VERSION__ installation complete ==="
echo "Weather page: http://192.168.10.1/Weather.html"
echo "Backlog API:  http://192.168.10.1:8089/fisb-status"

exit 0

'@

$header = $headerTemplate -replace '__VERSION__', $Version

$sb = New-Object System.Text.StringBuilder
[void]$sb.Append($header)

foreach ($p in $payloads) {
    $f = Join-Path $src $p.File
    Write-Host ("  encoding {0,-32} ({1:N0} bytes)" -f $p.File, (Get-Item -LiteralPath $f).Length)
    $bytes = [IO.File]::ReadAllBytes($f)
    $b64 = [Convert]::ToBase64String($bytes)
    [void]$sb.Append("__$($p.Marker)_BEGIN__`n")
    for ($i = 0; $i -lt $b64.Length; $i += 76) {
        $len = [Math]::Min(76, $b64.Length - $i)
        [void]$sb.Append($b64.Substring($i, $len)).Append("`n")
    }
    [void]$sb.Append("__$($p.Marker)_END__`n`n")
}

$text = $sb.ToString() -replace "`r`n", "`n"
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[IO.File]::WriteAllBytes($out, $utf8NoBom.GetBytes($text))

$size = (Get-Item -LiteralPath $out).Length
Write-Host ""
Write-Host "Wrote $out ($('{0:N0}' -f $size) bytes)"
