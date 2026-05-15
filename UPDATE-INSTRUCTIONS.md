# FIS-B Weather Monitor &mdash; Stratux Update Script

## File

`update-stratux-v1.0-fisb-weather.sh` (~1.6 MB)

A self-contained, fully-offline Stratux update script that installs the FIS-B Weather Monitor into the Stratux web UI along with a background buffer daemon. No Internet access is required on the Stratux device.

## What It Does

The script extracts six embedded base64 payloads and configures the system in five steps:

1. **Enables persistent journald** &mdash; so any future failure leaves logs in `/var/log/journal/`.
2. **Extracts files:**
   - `Weather.html` &rarr; `/opt/stratux/www/Weather.html` (the application)
   - `wx_stations.json` &rarr; `/opt/stratux/www/wx_stations.json` (weather station coordinate database)
   - `navaids.json` &rarr; `/opt/stratux/www/navaids.json` (NDB/VOR coordinate database)
   - `stratux-fisb-buffer.py` &rarr; `/opt/stratux/stratux-fisb-buffer.py` (backlog buffer daemon)
   - `stratux-fisb-buffer.service` &rarr; `/etc/systemd/system/stratux-fisb-buffer.service` (systemd unit)
   - `vendor-libs.tar.gz` &rarr; unpacked into `/opt/stratux/lib/` (vendored `websocket-client` + `six` Python libs)
3. **Installs vendored Python libs** &mdash; `websocket-client` and `six` are unpacked under `/opt/stratux/lib/` so the daemon can run without `pip` or Internet access. The script then sanity-checks the import; if it fails, the daemon is installed but left disabled.
4. **Adds a "FIS-B Weather" nav entry** to `/opt/stratux/www/index.html` (inserted after "Map", using the `fa-sun-o` icon). Idempotent &mdash; skipped if already present.
5. **Enables `stratux-fisb-buffer.service`** &mdash; the daemon captures FIS-B frames from the Stratux WebSocket starting ~60 s after boot, so they aren't lost in the gap before a browser connects. Uses `systemctl restart --no-block` to avoid blocking `stratux-pre-start.sh`'s tight start timeout.

## How to Install

1. Open the Stratux web UI at `http://192.168.10.1`
2. Navigate to the **Settings** page
3. Click **"Click to select system update file"**
4. Select `update-stratux-v1.0-fisb-weather.sh`
5. The device will **reboot automatically**
6. On next boot the script runs and installs everything above
7. After reboot, the **FIS-B Weather** link appears in the sidebar menu

## Access

- Via the sidebar menu: click **FIS-B Weather** (opens in a new tab)
- Direct URL: `http://192.168.10.1/Weather.html`
- Backlog status API: `http://192.168.10.1:8089/fisb-status`

## Notes

- **Idempotent.** Safe to run multiple times &mdash; the nav-entry injection is skipped if it's already present, and payload extraction simply overwrites prior copies.
- **Standalone page.** `Weather.html` is a self-contained single-file app, not part of the Stratux AngularJS SPA. The menu link opens it in a new browser tab.
- **Re-apply after Stratux updates.** Official Stratux software updates overwrite `/opt/stratux/www/` and may also reset systemd state, which removes the page, nav entry, and possibly the daemon unit. Re-upload this script after any official Stratux update.
- **Script naming.** The filename matches the required pattern `update*stratux*v*.sh` so the Stratux boot process recognizes and executes it.
- **Buffer daemon activation.** `stratux-fisb-buffer.service` has a 60-second `ExecStartPre` so it doesn't race the main Stratux process. Expect the `fisb-status` endpoint to come online ~60 seconds after Stratux is fully up.

## How It Works

The script is a bash file with six base64-encoded payloads appended after the install logic, each fenced by paired markers:

```
__WEATHER_HTML_BEGIN__   ...   __WEATHER_HTML_END__
__WX_STATIONS_BEGIN__    ...   __WX_STATIONS_END__
__NAVAIDS_BEGIN__        ...   __NAVAIDS_END__
__DAEMON_PY_BEGIN__      ...   __DAEMON_PY_END__
__SERVICE_UNIT_BEGIN__   ...   __SERVICE_UNIT_END__
__VENDOR_LIBS_BEGIN__    ...   __VENDOR_LIBS_END__
```

On execution, an `extract_payload` shell function locates each marker pair in `$0`, base64-decodes the lines between them, and writes the result to the target path with the requested mode (the daemon script gets `0755`; everything else gets `0644`).

## Rebuilding the Update Script

Use the included builder, which re-encodes all six payloads from the source files in this directory:

```cmd
Build-Installer.bat 1.0
```

This produces `update-stratux-v1.0-fisb-weather.sh`. Pass any version string &mdash; `Build-Installer.bat 1.1` produces `update-stratux-v1.1-fisb-weather.sh`, and so on. The version string is substituted into the install/complete echo lines inside the script.

Requirements: Windows PowerShell 5.1 or PowerShell 7. No external tools needed; base64 encoding is done via `[System.Convert]::ToBase64String`. The script writes UTF-8 with LF line endings so the resulting `.sh` runs unmodified on the Stratux.

Source files the builder reads:

- `Weather.html`
- `wx_stations.json`
- `navaids.json`
- `stratux-fisb-buffer.py`
- `stratux-fisb-buffer.service`
- `vendor-libs.tar.gz`
