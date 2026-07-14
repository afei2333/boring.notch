#!/usr/bin/env python3
"""stock_bridge.py — boring.notch <-> Futu OpenD quote bridge.

Spawned by BoringNotchXPCHelper (the sandboxed app cannot exec). Talks the
Futu private protocol to OpenD via the official futu-api SDK, keeps the
latest quotes + intraday timeshare in memory, and serves them to the app
over a tiny localhost JSON API:

  POST /watch     {"symbols": ["HK.00700", ...]}   subscribe (full list)
  GET  /quotes    all cached quotes incl. downsampled intraday points
  GET  /snapshot?symbol=HK.00700   fresh market snapshot for one symbol

Binds port 0 and prints "listening on http://127.0.0.1:PORT" so the helper
can report the port back to the app (same contract as the mimo daemon).

futu-api is imported lazily so the bridge starts (and the app gets a clear
error message via /quotes) even when the SDK is not installed.
"""

import argparse
import json
import threading
import time as _time
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs
from zoneinfo import ZoneInfo

LOCK = threading.Lock()
QUOTES = {}       # code -> merged quote dict (snapshot + pushes)
RT = {}           # code -> {"date": "YYYY-MM-DD", "points": [{"t": "HH:MM", "p": price}]}
EXT_RT = {}       # code -> {"key": "date|session", "points": [...]} sampled pre/after prices
WATCHED = set()
LAST_ERROR = None
CTX = None
FT = None
OPEND_HOST = "127.0.0.1"
OPEND_PORT = 11111
MAX_RT_POINTS = 150


def _set_error(msg):
    global LAST_ERROR
    LAST_ERROR = str(msg) if msg else None


def _ctx():
    """Lazily import futu and connect to OpenD. Returns None on failure."""
    global CTX, FT
    if CTX is not None:
        return CTX
    try:
        import futu as ft
        FT = ft
    except ImportError:
        _set_error("futu-api not installed: pip3 install futu-api")
        return None
    try:
        CTX = FT.OpenQuoteContext(host=OPEND_HOST, port=OPEND_PORT)
        CTX.set_handler(_QuoteHandler())
        CTX.set_handler(_RTHandler())
    except Exception as e:
        CTX = None
        _set_error(f"cannot connect OpenD at {OPEND_HOST}:{OPEND_PORT}: {e}")
        return None
    return CTX


def _append_rt(code, time_str, price):
    """time_str like '2026-07-13 09:31:00'. Resets on day rollover."""
    if not time_str or len(time_str) < 16 or price is None:
        return
    date, hhmm = time_str[:10], time_str[11:16]
    entry = RT.setdefault(code, {"date": date, "points": []})
    if entry["date"] != date:
        entry["date"] = date
        entry["points"] = []
    pts = entry["points"]
    if pts and pts[-1]["t"] == hhmm:
        pts[-1]["p"] = price
    else:
        pts.append({"t": hhmm, "p": price})
        if len(pts) > 1000:
            del pts[: len(pts) - 1000]


def _merge_quote(code, **fields):
    q = QUOTES.setdefault(code, {"symbol": code})
    q.update({k: v for k, v in fields.items() if v is not None})


def _f(row, key):
    """Float field or None (futu uses 'N/A' strings for missing values)."""
    v = row.get(key)
    try:
        return float(v)
    except (TypeError, ValueError):
        return None


# US extended-hours raw fields kept on the quote dict; the active session is
# decided by NY clock at payload time (see _ext).
EXT_RAW = {
    "prePrice": "pre_price", "preChangePct": "pre_change_rate",
    "afterPrice": "after_price", "afterChangePct": "after_change_rate",
}


def _merge_snapshot_row(row):
    code = row["code"]
    name = row.get("name") or row.get("stock_name")
    _merge_quote(
        code,
        name=str(name) if name else None,
        cur=_f(row, "last_price"),
        open=_f(row, "open_price"),
        high=_f(row, "high_price"),
        low=_f(row, "low_price"),
        lastClose=_f(row, "prev_close_price"),
        volume=_f(row, "volume"),
        turnover=_f(row, "turnover"),
        high52w=_f(row, "highest52weeks_price"),
        low52w=_f(row, "lowest52weeks_price"),
        marketCap=_f(row, "total_market_val"),
        pe=_f(row, "pe_ttm_ratio") or _f(row, "pe_ratio"),
        time=str(row.get("update_time") or ""),
    )
    # Force-set (incl. None) so yesterday's ext prices don't linger into today.
    QUOTES[code].update({k: _f(row, src) for k, src in EXT_RAW.items()})
    _append_ext_rt(code, row)


def _append_ext_rt(code, row):
    """Sample the ext-session price into EXT_RT (caller holds LOCK). Points
    come from 60s snapshots + quote pushes, deduped per minute."""
    session = _ext_session()
    if not session or not code.startswith("US."):
        return
    price = _f(row, "pre_price" if session == "pre" else "after_price")
    if price is None:
        return
    now = datetime.now(ZoneInfo("America/New_York"))
    key = f"{now.date()}|{session}"
    entry = EXT_RT.setdefault(code, {"key": key, "points": []})
    if entry["key"] != key:
        entry["key"] = key
        entry["points"] = []
    hhmm = now.strftime("%H:%M")
    pts = entry["points"]
    if pts and pts[-1]["t"] == hhmm:
        pts[-1]["p"] = price
    else:
        pts.append({"t": hhmm, "p": price})


def _ext_session():
    """'pre' 4:00-9:30, 'after' 16:00-20:00 NY time on weekdays, else None."""
    now = datetime.now(ZoneInfo("America/New_York"))
    if now.weekday() >= 5:
        return None
    minutes = now.hour * 60 + now.minute
    if 4 * 60 <= minutes < 9 * 60 + 30:
        return "pre"
    if 16 * 60 <= minutes < 20 * 60:
        return "after"
    return None


def _ext(q):
    """{"label","price","changePct"} for the active US extended session, or None."""
    session = _ext_session()
    if not session or not str(q.get("symbol", "")).startswith("US."):
        return None
    price = q.get(f"{session}Price")
    if price is None:
        return None
    # Sparkline baseline: pre-market moves off yesterday's close, after-hours
    # off today's regular close (== last regular price).
    base = q.get("lastClose") if session == "pre" else q.get("cur")
    return {"label": "盘前" if session == "pre" else "盘后",
            "price": price, "changePct": q.get(f"{session}ChangePct"), "base": base}


def _fetch_snapshot(codes):
    qc = _ctx()
    if qc is None:
        return False
    ret, data = qc.get_market_snapshot(codes)
    if ret != FT.RET_OK:
        _set_error(data)
        return False
    with LOCK:
        for row in data.to_dict("records"):
            _merge_snapshot_row(row)
    _set_error(None)
    return True


def _prime_rt_history(codes):
    """Backfill the timeshare so sparklines are full on first load. Off-hours
    get_rt_data returns nothing, so fall back to the latest session's 1-min
    klines (subscription-based, no monthly quota). One code per call,
    throttled to stay under the 10/30s frequency limit."""
    qc = _ctx()
    if qc is None:
        return
    for code in codes:
        filled = False
        ret, data = qc.get_rt_data(code)
        if ret == FT.RET_OK:
            rows = [r for r in data.to_dict("records")
                    if not r.get("is_blank", False) and _f(r, "cur_price")]
            if rows:
                with LOCK:
                    RT.pop(code, None)
                    for row in rows:
                        _append_rt(code, str(row.get("time") or ""), _f(row, "cur_price"))
                filled = True
        if not filled:
            ret, data = qc.get_cur_kline(code, 400, FT.KLType.K_1M)
            if ret == FT.RET_OK:
                rows = data.to_dict("records")
                last_date = str(rows[-1].get("time_key") or "")[:10] if rows else ""
                with LOCK:
                    RT.pop(code, None)
                    for row in rows:
                        time_key = str(row.get("time_key") or "")
                        close = _f(row, "close")
                        if time_key[:10] == last_date and close:
                            _append_rt(code, time_key, close)
        _time.sleep(3.5)


def _watch(symbols):
    qc = _ctx()
    if qc is None:
        return False
    with LOCK:
        new = [s for s in symbols if s not in WATCHED]
    if not new:
        _set_error(None)  # nothing pending — don't let an old bad-code error linger
        return True
    # ponytail: subscribe-only, never unsubscribe — quota is 100+, watchlists are small
    # K_1M is only pulled (get_cur_kline off-hours backfill) but pulls require a subscription.
    # One call per code so a single bad/mistyped code can't block the valid ones.
    ok, errors = [], []
    for code in new:
        ret, err = qc.subscribe([code], [FT.SubType.QUOTE, FT.SubType.RT_DATA, FT.SubType.K_1M])
        (ok.append(code) if ret == FT.RET_OK else errors.append(f"{code}: {err}"))
    with LOCK:
        WATCHED.update(ok)
    _set_error("; ".join(errors) if errors else None)
    if ok:
        _fetch_snapshot(ok)  # names, 52w, initial prices
        threading.Thread(target=_prime_rt_history, args=(ok,), daemon=True).start()
    return not errors


def _downsample(points, limit=120):
    n = len(points)
    if n <= limit:
        return points
    step = (n - 1) / (limit - 1)
    return [points[round(i * step)] for i in range(limit)]


def _quotes_payload():
    with LOCK:
        quotes = []
        for code, q in QUOTES.items():
            out = dict(q)
            entry = RT.get(code)
            out["rt"] = _downsample(list(entry["points"])) if entry else []
            out["ext"] = _ext(out)
            if out["ext"]:
                ext_pts = EXT_RT.get(code, {}).get("points", [])
                if len(ext_pts) >= 2:
                    out["rt"] = _downsample(list(ext_pts))
            quotes.append(out)
    return {"ok": LAST_ERROR is None, "error": LAST_ERROR, "quotes": quotes}


# futu push handlers — classes defined lazily since futu import is lazy
def _QuoteHandler():
    class H(FT.StockQuoteHandlerBase):
        def on_recv_rsp(self, rsp_pb):
            ret, data = super().on_recv_rsp(rsp_pb)
            if ret == FT.RET_OK:
                with LOCK:
                    for row in data.to_dict("records"):
                        _merge_quote(
                            row["code"],
                            cur=_f(row, "last_price"),
                            open=_f(row, "open_price"),
                            high=_f(row, "high_price"),
                            low=_f(row, "low_price"),
                            lastClose=_f(row, "prev_close_price"),
                            volume=_f(row, "volume"),
                            turnover=_f(row, "turnover"),
                            time=f"{row.get('data_date', '')} {row.get('data_time', '')}".strip(),
                            **{k: _f(row, src) for k, src in EXT_RAW.items()},
                        )
                        _append_ext_rt(row["code"], row)
            return ret, data

    return H()


def _RTHandler():
    class H(FT.RTDataHandlerBase):
        def on_recv_rsp(self, rsp_pb):
            ret, data = super().on_recv_rsp(rsp_pb)
            if ret == FT.RET_OK:
                with LOCK:
                    for row in data.to_dict("records"):
                        p = _f(row, "cur_price")
                        if not row.get("is_blank", False) and p:
                            _append_rt(row["code"], str(row.get("time") or ""), p)
            return ret, data

    return H()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def _json(self, obj, status=200):
        body = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        url = urlparse(self.path)
        if url.path == "/quotes":
            self._json(_quotes_payload())
        elif url.path == "/snapshot":
            symbol = (parse_qs(url.query).get("symbol") or [""])[0]
            if not symbol:
                self._json({"ok": False, "error": "missing symbol"}, 400)
                return
            _fetch_snapshot([symbol])
            with LOCK:
                q = dict(QUOTES.get(symbol, {"symbol": symbol}))
                entry = RT.get(symbol)
                q["rt"] = _downsample(list(entry["points"])) if entry else []
                q["ext"] = _ext(q)
                if q["ext"]:
                    ext_pts = EXT_RT.get(symbol, {}).get("points", [])
                    if len(ext_pts) >= 2:
                        q["rt"] = _downsample(list(ext_pts))
            self._json({"ok": LAST_ERROR is None, "error": LAST_ERROR, "quote": q})
        else:
            self._json({"ok": False, "error": "not found"}, 404)

    def do_POST(self):
        if urlparse(self.path).path != "/watch":
            self._json({"ok": False, "error": "not found"}, 404)
            return
        length = int(self.headers.get("Content-Length") or 0)
        try:
            payload = json.loads(self.rfile.read(length) or b"{}")
            symbols = [s for s in payload.get("symbols", []) if isinstance(s, str) and "." in s]
        except (ValueError, AttributeError):
            self._json({"ok": False, "error": "bad json"}, 400)
            return
        ok = _watch(symbols) if symbols else True
        self._json({"ok": ok, "error": LAST_ERROR})


def _snapshot_loop():
    """Refresh snapshots every 60s: keeps ext-session prices, volume and 52w
    fresh even when OpenD sends no pushes (one batched call, quota 10/30s)."""
    while True:
        _time.sleep(60)
        with LOCK:
            codes = sorted(WATCHED)
        if codes:
            _fetch_snapshot(codes)


def main():
    global OPEND_HOST, OPEND_PORT
    parser = argparse.ArgumentParser()
    parser.add_argument("--opend-host", default="127.0.0.1")
    parser.add_argument("--opend-port", type=int, default=11111)
    args = parser.parse_args()
    OPEND_HOST, OPEND_PORT = args.opend_host, args.opend_port

    threading.Thread(target=_snapshot_loop, daemon=True).start()
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    print(f"listening on http://127.0.0.1:{server.server_address[1]}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
