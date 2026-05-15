#!/usr/bin/env python3
"""Stratux FIS-B backlog buffer daemon (v2.1).

Subscribes to the local Stratux /weather and /gdl90 WebSocket endpoints,
accumulates messages in memory, and exposes them via HTTP for the Weather
page to replay on load.

Listens on TCP :8089. Requires the `websocket-client` Python package.
"""

import base64
import json
import os
import sys
import threading
import time
from collections import deque
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# Prefer the vendored websocket-client + six bundled by the v2.1 installer.
# Falls through to a system-installed version if the vendor dir is absent.
_VENDOR_DIR = '/opt/stratux/lib'
if os.path.isdir(_VENDOR_DIR) and _VENDOR_DIR not in sys.path:
    sys.path.insert(0, _VENDOR_DIR)

try:
    import websocket  # noqa: E402
except ImportError as e:
    sys.stderr.write(
        f"ERROR: cannot import 'websocket': {e}\n"
        f"Expected vendored copy under {_VENDOR_DIR}/websocket/\n"
    )
    sys.exit(1)

# --- Configuration ---------------------------------------------------------
STRATUX_HOST = os.environ.get('STRATUX_HOST', '127.0.0.1')
STRATUX_PORT = int(os.environ.get('STRATUX_PORT', '80'))
LISTEN_HOST  = os.environ.get('FISB_BUFFER_HOST', '0.0.0.0')
LISTEN_PORT  = int(os.environ.get('FISB_BUFFER_PORT', '8089'))

# Conservative reconnect cadence so a flaky upstream can't cause a connect storm.
CONNECT_TIMEOUT_SEC = int(os.environ.get('CONNECT_TIMEOUT_SEC', '30'))
RECV_TIMEOUT_SEC    = int(os.environ.get('RECV_TIMEOUT_SEC', '300'))
RECONNECT_DELAY_SEC = int(os.environ.get('RECONNECT_DELAY_SEC', '15'))

# Memory caps. Worst case ~10 MB on a Pi.
MAX_GDL90_FRAMES     = 4000
MAX_UNKEYED_MESSAGES = 2000

# Text-product types deduplicated by (Type, Location) — only the most recent
# observation per station is useful. Everything else is FIFO.
KEYED_TYPES = {'METAR', 'SPECI', 'TAF', 'ATIS', 'WINDS'}

# --- Shared state ----------------------------------------------------------
state_lock         = threading.Lock()
weather_keyed      = {}                              # (Type, Location) -> msg
weather_unkeyed    = deque(maxlen=MAX_UNKEYED_MESSAGES)
gdl90_frames       = deque(maxlen=MAX_GDL90_FRAMES)  # base64 strings
start_time         = time.monotonic()
last_weather_ts    = 0.0
last_gdl90_ts      = 0.0
weather_recv_count = 0
gdl90_recv_count   = 0


def log(msg):
    sys.stdout.write(f'[{time.strftime("%H:%M:%S")}] {msg}\n')
    sys.stdout.flush()


# --- GDL90 helper: identify uplink (FIS-B) frames -------------------------
def first_unstuffed_byte(raw):
    """Return the GDL90 message ID of a frame, applying one level of byte
    unstuffing on the first content byte. Returns -1 for empty input."""
    i, n = 0, len(raw)
    while i < n and raw[i] == 0x7E:
        i += 1
    if i >= n:
        return -1
    if raw[i] == 0x7D and i + 1 < n:
        return raw[i + 1] ^ 0x20
    return raw[i]


# --- Storage ---------------------------------------------------------------
def store_weather(msg):
    global last_weather_ts, weather_recv_count
    msg_type = (msg.get('Type') or '').upper()
    loc = msg.get('Location') or ''
    with state_lock:
        if msg_type in KEYED_TYPES:
            weather_keyed[(msg_type, loc)] = msg
        else:
            weather_unkeyed.append(msg)
        last_weather_ts = time.time()
        weather_recv_count += 1


def store_gdl90_b64(b64):
    global last_gdl90_ts, gdl90_recv_count
    with state_lock:
        gdl90_frames.append(b64)
        last_gdl90_ts = time.time()
        gdl90_recv_count += 1


# --- WebSocket loops -------------------------------------------------------
def open_ws(path):
    url = f'ws://{STRATUX_HOST}:{STRATUX_PORT}{path}'
    ws = websocket.create_connection(
        url,
        timeout=CONNECT_TIMEOUT_SEC,
        origin='http://localhost',
    )
    ws.settimeout(RECV_TIMEOUT_SEC)
    return ws, url


def weather_loop():
    while True:
        ws = None
        try:
            ws, url = open_ws('/weather')
            log(f'[weather] connected to {url}')
            while True:
                payload = ws.recv()
                if not payload:
                    # Empty payload typically means the peer closed the conn.
                    raise ConnectionError('empty recv (closed)')
                if isinstance(payload, bytes):
                    payload = payload.decode('utf-8', 'replace')
                try:
                    msg = json.loads(payload)
                except Exception:
                    continue
                if isinstance(msg, dict):
                    store_weather(msg)
        except Exception as e:
            log(f'[weather] disconnect: {type(e).__name__}: {e}')
        finally:
            try:
                if ws:
                    ws.close()
            except Exception:
                pass
        time.sleep(RECONNECT_DELAY_SEC)


def gdl90_loop():
    while True:
        ws = None
        try:
            ws, url = open_ws('/gdl90')
            log(f'[gdl90] connected to {url}')
            while True:
                payload = ws.recv()
                if not payload:
                    raise ConnectionError('empty recv (closed)')
                if isinstance(payload, str):
                    # Stratux sends GDL90 frames as JSON-quoted base64.
                    try:
                        s = json.loads(payload)
                    except Exception:
                        continue
                    if not isinstance(s, str):
                        continue
                    try:
                        raw = base64.b64decode(s)
                    except Exception:
                        continue
                    if first_unstuffed_byte(raw) == 0x07:
                        store_gdl90_b64(s)
                else:
                    if first_unstuffed_byte(payload) == 0x07:
                        store_gdl90_b64(base64.b64encode(payload).decode())
        except Exception as e:
            log(f'[gdl90] disconnect: {type(e).__name__}: {e}')
        finally:
            try:
                if ws:
                    ws.close()
            except Exception:
                pass
        time.sleep(RECONNECT_DELAY_SEC)


def stats_loop():
    """Periodic counters so the dry-run operator can see progress."""
    while True:
        time.sleep(30)
        with state_lock:
            wk, wu, gf = len(weather_keyed), len(weather_unkeyed), len(gdl90_frames)
            wr, gr = weather_recv_count, gdl90_recv_count
        uptime = int(time.monotonic() - start_time)
        log(f'[stats] uptime={uptime}s '
            f'weather: {wk} keyed + {wu} unkeyed (rcv={wr}), '
            f'gdl90: {gf} frames (rcv={gr})')


# --- HTTP backlog server ---------------------------------------------------
class BacklogHandler(BaseHTTPRequestHandler):
    def _send_json(self, code, obj):
        body = json.dumps(obj, separators=(',', ':')).encode()
        self.send_response(code)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Cache-Control', 'no-store')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_OPTIONS(self):
        self.send_response(204)
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Access-Control-Allow-Methods', 'GET,OPTIONS')
        self.end_headers()

    def do_GET(self):
        path = self.path.split('?', 1)[0]
        if path == '/fisb-backlog':
            with state_lock:
                weather = list(weather_keyed.values()) + list(weather_unkeyed)
                gdl90   = list(gdl90_frames)
                uptime  = int(time.monotonic() - start_time)
                lwt, lgt = last_weather_ts, last_gdl90_ts
            self._send_json(200, {
                'version': 1,
                'daemon_uptime_sec': uptime,
                'last_weather_epoch': lwt,
                'last_gdl90_epoch':   lgt,
                'weather': weather,
                'gdl90':   gdl90,
            })
        elif path == '/fisb-status':
            with state_lock:
                self._send_json(200, {
                    'weather_keyed_count':   len(weather_keyed),
                    'weather_unkeyed_count': len(weather_unkeyed),
                    'gdl90_frame_count':     len(gdl90_frames),
                    'weather_recv_count':    weather_recv_count,
                    'gdl90_recv_count':      gdl90_recv_count,
                    'daemon_uptime_sec':     int(time.monotonic() - start_time),
                    'last_weather_epoch':    last_weather_ts,
                    'last_gdl90_epoch':      last_gdl90_ts,
                })
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, fmt, *args):
        return


def main():
    log(f'starting stratux-fisb-buffer (PID {os.getpid()}, websocket-client {websocket.__version__})')
    log(f'  upstream={STRATUX_HOST}:{STRATUX_PORT}  listen={LISTEN_HOST}:{LISTEN_PORT}')
    log(f'  reconnect_delay={RECONNECT_DELAY_SEC}s  recv_timeout={RECV_TIMEOUT_SEC}s')
    threading.Thread(target=weather_loop, daemon=True, name='weather').start()
    threading.Thread(target=gdl90_loop,   daemon=True, name='gdl90').start()
    threading.Thread(target=stats_loop,   daemon=True, name='stats').start()
    server = ThreadingHTTPServer((LISTEN_HOST, LISTEN_PORT), BacklogHandler)
    log(f'[http] listening on {LISTEN_HOST}:{LISTEN_PORT}')
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        log('shutdown')


if __name__ == '__main__':
    main()
