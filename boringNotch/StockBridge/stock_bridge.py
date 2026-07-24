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
import math
import os
import subprocess
import threading
import time as _time
import urllib.request
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs
from zoneinfo import ZoneInfo

LOCK = threading.Lock()
QUOTES = {}       # code -> merged quote dict (snapshot + pushes)
RT = {}           # code -> {"date": "YYYY-MM-DD", "points": [{"t": "HH:MM", "p": price}]}
EXT_RT = {}       # code -> {"key": "date|session", "points": [...]} sampled pre/after prices
WATCHED = set()
PULL_ONLY = set()  # no subscribe rights but futu snapshots work — 60s pulls only
FALLBACK = set()   # OpenD refuses entirely (A股指数/日韩指数) — public quote APIs
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
    if pts:
        if pts[-1]["t"] == hhmm:
            pts[-1]["p"] = price
        elif hhmm > pts[-1]["t"]:
            pts.append({"t": hhmm, "p": price})
            if len(pts) > 1000:
                del pts[: len(pts) - 1000]
    else:
        pts.append({"t": hhmm, "p": price})


def _merge_quote(code, **fields):
    q = QUOTES.setdefault(code, {"symbol": code})
    q.update({k: v for k, v in fields.items() if v is not None})


def _f(row, key):
    """Finite float field or None. Futu uses 'N/A' strings AND NaN floats for
    missing values (e.g. ETF pe/marketCap); a bare NaN in json.dumps output is
    invalid JSON and makes Swift's JSONDecoder reject the whole payload."""
    v = row.get(key)
    try:
        f = float(v)
    except (TypeError, ValueError):
        return None
    return f if math.isfinite(f) else None


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
        time=str(row["update_time"]) if row.get("update_time") else None,
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
    """Route each code to its working source (futu / Tencent / sina), so every
    caller — /snapshot, the 60s loop, _subscribe — handles all of them."""
    with LOCK:
        fb_intl = [c for c in codes if c in FALLBACK and c in INTL_IDS]
        fb_tc = [c for c in codes if c in FALLBACK and c not in INTL_IDS]
        futu = [c for c in codes if c not in FALLBACK]
    ok = _tencent_fetch(fb_tc) if fb_tc else True
    ok = (_intl_fetch(fb_intl) if fb_intl else True) and ok
    return (_futu_snapshot(futu) if futu else True) and ok


def _futu_snapshot(codes):
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
            if row["code"] in PULL_ONLY:
                # No pushes for these — build the sparkline from snapshot ticks.
                _append_rt(row["code"], str(row.get("update_time") or ""),
                           _f(row, "last_price"))
    _set_error(None)
    return True


def _tencent_fetch(codes):
    """Free public quote API for SH./SZ. codes OpenD has no rights to (A股指数
    需要行情权限，腾讯接口不需要). Fields are '~'-separated, GBK, per docs of
    qt.gtimg.cn: 1 name, 2 bare code, 3 cur, 4 prev close, 5 open, 6 vol(手),
    30 time YYYYMMDDHHMMSS, 33 high, 34 low, 37 turnover(万)."""
    q = ",".join(c.replace(".", "").lower() for c in codes)  # SH.000001 -> sh000001
    try:
        with urllib.request.urlopen(f"https://qt.gtimg.cn/q={q}", timeout=5) as r:
            raw = r.read().decode("gbk", "replace")
    except OSError as e:
        _set_error(f"A股指数备用行情源不可用: {e}")
        return False
    got = False
    with LOCK:
        for chunk in raw.split(";"):
            var, sep, val = chunk.partition("=")
            f = val.strip().strip('"').split("~")
            if not sep or len(f) < 38 or not f[3]:
                continue

            def g(i, scale=1.0):
                try:
                    v = float(f[i]) * scale
                except ValueError:
                    return None
                return v if math.isfinite(v) else None

            code = f"{var.strip()[-8:-6].upper()}.{f[2]}"
            t = f[30]
            ts = (f"{t[:4]}-{t[4:6]}-{t[6:8]} {t[8:10]}:{t[10:12]}:{t[12:14]}"
                  if len(t) >= 14 else None)
            _merge_quote(code, name=f[1], cur=g(3), lastClose=g(4), open=g(5),
                         volume=g(6, 100), high=g(33), low=g(34),
                         turnover=g(37, 1e4), time=ts)
            if ts:
                _append_rt(code, ts, g(3))
            got = True
    if got:
        _set_error(None)
    return got


def _tencent_prime(code):
    """Backfill today's minute line so the sparkline is full on first load."""
    sym = code.replace(".", "").lower()
    url = f"https://web.ifzq.gtimg.cn/appstock/app/minute/query?code={sym}"
    try:
        with urllib.request.urlopen(url, timeout=5) as r:
            d = json.load(r)["data"][sym]["data"]
        day = f"{d['date'][:4]}-{d['date'][4:6]}-{d['date'][6:8]}"
        with LOCK:
            RT.pop(code, None)
            for line in d["data"]:
                parts = line.split()
                if len(parts) >= 2:
                    _append_rt(code, f"{day} {parts[0][:2]}:{parts[0][2:4]}",
                               float(parts[1]))
    except Exception:
        pass  # sparkline fills from the 60s ticks instead


# 日韩指数: futu has no JP/KR indices at all, Tencent no codes for them either.
# Quotes come from sina 国际指数 (reliable); eastmoney only backfills the
# minute line (its LB randomly drops connections — fine for a one-shot prime).
INTL_IDS = {"JP.N225": ("znb_NKY", "100.N225"), "KR.KOSPI": ("znb_KOSPI", "100.KS11")}


def _em_json(url, retries=3):
    """eastmoney via curl: their CDN fingerprint-blocks python's TLS, and any
    client gets connections randomly dropped — curl + retries rides it out."""
    for i in range(retries):
        p = subprocess.run(["curl", "-s", "--max-time", "5", url],
                           capture_output=True)
        if p.returncode == 0:
            try:
                return json.loads(p.stdout)
            except ValueError:
                pass
        _time.sleep(0.3 * (i + 1))
    raise OSError(f"curl failed after {retries} tries (last exit {p.returncode})")


def _intl_fetch(codes):
    """sina znb_ fields: name,cur,chg,chg%,localtime,epoch,date,time(北京),
    open,prevClose,high,low,volume."""
    keys = {INTL_IDS[c][0]: c for c in codes if c in INTL_IDS}
    if not keys:
        return False
    req = urllib.request.Request(
        "https://hq.sinajs.cn/list=" + ",".join(keys),
        headers={"Referer": "https://finance.sina.com.cn"})
    try:
        with urllib.request.urlopen(req, timeout=5) as r:
            raw = r.read().decode("gbk", "replace")
    except OSError as e:
        _set_error(f"日韩指数行情源不可用: {e}")
        return False
    got = False
    with LOCK:
        for line in raw.splitlines():
            if "hq_str_" not in line or '="' not in line:
                continue
            key = line.split("hq_str_", 1)[1].split("=", 1)[0]
            code = keys.get(key)
            f = line.split('="', 1)[1].rstrip('";').split(",")
            if not code or len(f) < 12 or not f[1]:
                continue

            def g(i):
                try:
                    v = float(f[i])
                except ValueError:
                    return None
                return v if math.isfinite(v) and v != 0 else None

            ts = f"{f[6]} {f[7]}" if len(f[6]) == 10 else None
            _merge_quote(code, name=f[0], cur=g(1), open=g(8), lastClose=g(9),
                         high=g(10), low=g(11), time=ts)
            if ts:
                _append_rt(code, ts, g(1))
            got = True
    if got:
        _set_error(None)
    return got


def _eastmoney_prime(code):
    """Backfill today's minute line (Beijing-time timestamps)."""
    secid = INTL_IDS.get(code, (None, None))[1]
    if not secid:
        return
    url = ("https://push2his.eastmoney.com/api/qt/stock/trends2/get?secid=" + secid
           + "&fields1=f1&fields2=f51,f53&ndays=1&iscr=0")
    try:
        rows = (_em_json(url).get("data") or {}).get("trends") or []
    except (OSError, ValueError, subprocess.SubprocessError):
        return  # sparkline fills from the 60s ticks instead
    try:
        with LOCK:
            RT.pop(code, None)
            for row in rows:
                parts = row.split(",")
                if len(parts) >= 2:
                    _append_rt(code, parts[0], float(parts[1]))
    except (OSError, ValueError):
        pass


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


SUB_TYPES = ["QUOTE", "RT_DATA", "K_1M"]  # names — FT is imported lazily


def _subscribe(codes):
    """Subscribe + prime. K_1M is only pulled (get_cur_kline off-hours backfill)
    but pulls require a subscription. One call per code so a single bad/mistyped
    code can't block the valid ones."""
    qc = _ctx()
    if qc is None:
        return False
    ok, errors = [], []
    for code in codes:
        if code in INTL_IDS:  # futu can't know these — straight to fallback
            if _intl_fetch([code]):
                with LOCK:
                    FALLBACK.add(code)
                threading.Thread(target=_eastmoney_prime, args=(code,), daemon=True).start()
            else:
                errors.append(f"{code}: 日韩指数行情源不可用")
            continue
        ret, err = qc.subscribe([code], [getattr(FT.SubType, t) for t in SUB_TYPES])
        if ret != FT.RET_OK:
            # Some securities (ETFs, new listings) reject RT_DATA/K_1M; quotes
            # still work — degrade to QUOTE-only instead of failing entirely.
            ret, err = qc.subscribe([code], [FT.SubType.QUOTE])
        if ret == FT.RET_OK:
            with LOCK:
                PULL_ONLY.discard(code)
                FALLBACK.discard(code)
            ok.append(code)
        elif _futu_snapshot([code]):
            # No subscribe rights but snapshot pulls work — 60s pull-only.
            with LOCK:
                PULL_ONLY.add(code)
        elif code[:3] in ("SH.", "SZ.") and _tencent_fetch([code]):
            # OpenD refuses A-share indices entirely without 指数行情权限;
            # Tencent's public endpoint doesn't need one.
            with LOCK:
                FALLBACK.add(code)
            threading.Thread(target=_tencent_prime, args=(code,), daemon=True).start()
        else:
            errors.append(f"{code}: {err}")
    if ok:
        _fetch_snapshot(ok)  # names, 52w, initial prices
        threading.Thread(target=_prime_rt_history, args=(ok,), daemon=True).start()
    # after the fetches: a successful fetch clears LAST_ERROR, don't let it
    # swallow real subscribe failures
    _set_error("; ".join(errors) if errors else None)
    return not errors


def _watch(symbols):
    """/watch always posts the whole watchlist, so it is the desired set, not a
    delta: WATCHED tracks what the app wants (even if subscribing fails — the
    reconcile in _snapshot_loop retries), and codes the user removed are
    unsubscribed because each one holds 3 of OpenD's 100 subscription slots."""
    qc = _ctx()
    if qc is None:
        return False
    with LOCK:
        new = [s for s in symbols if s not in WATCHED]
        dropped = [s for s in WATCHED if s not in symbols]
        WATCHED.clear()
        WATCHED.update(symbols)
        PULL_ONLY.intersection_update(symbols)
        FALLBACK.intersection_update(symbols)
    if dropped:
        qc.unsubscribe(dropped, [getattr(FT.SubType, t) for t in SUB_TYPES])
    if not new:
        _set_error(None)  # nothing pending — don't let an old bad-code error linger
        return True
    return _subscribe(new)


# Symbol search: full code+name universe per (market, type), loaded lazily on
# first /search (~26s: get_stock_basicinfo quota is 10/30s), then in-memory.
BASICINFO = {}          # (market, sectype) -> [{"symbol", "name"}]
BASICINFO_STATE = "idle"  # idle | loading | ready
SEARCH_UNIVERSE = [("HK", "STOCK"), ("US", "STOCK"), ("SH", "STOCK"), ("SZ", "STOCK"),
                   ("HK", "ETF"), ("US", "ETF"), ("SH", "ETF"), ("SZ", "ETF")]
UNIVERSE_CACHE = os.path.expanduser(
    "~/Library/Caches/theboringteam.boringnotch.stock-universe.json")


def _load_basicinfo():
    global BASICINFO_STATE
    # Disk cache: the universe barely changes and a fresh fetch takes ~30s of
    # empty search results per bridge restart. 7-day TTL.
    try:
        if _time.time() - os.path.getmtime(UNIVERSE_CACHE) < 7 * 86400:
            with open(UNIVERSE_CACHE) as f:
                cached = json.load(f)
            if len(cached) == len(SEARCH_UNIVERSE):
                with LOCK:
                    for key, rows in cached.items():
                        BASICINFO[tuple(key.split("|"))] = rows
                BASICINFO_STATE = "ready"
                return
    except (OSError, ValueError):
        pass
    qc = _ctx()
    if qc is None:
        BASICINFO_STATE = "idle"  # retry on next search
        return
    for market, stype in SEARCH_UNIVERSE:
        if (market, stype) in BASICINFO:
            continue
        ret, data = qc.get_stock_basicinfo(getattr(FT.Market, market),
                                           getattr(FT.SecurityType, stype))
        if ret == FT.RET_OK:
            rows = [{"symbol": str(r["code"]), "name": str(r.get("name") or "")}
                    for r in data.to_dict("records")]
            with LOCK:
                BASICINFO[(market, stype)] = rows
        _time.sleep(3.2)  # frequency limit
    BASICINFO_STATE = "ready"
    with LOCK:
        dump = {"|".join(k): v for k, v in BASICINFO.items()}
    if len(dump) == len(SEARCH_UNIVERSE):  # don't freeze a partial load for 7 days
        try:
            with open(UNIVERSE_CACHE, "w") as f:
                json.dump(dump, f)
        except OSError:
            pass


# Indices aren't in get_stock_basicinfo's universe — searchable by hand.
STATIC_INDEXES = [
    {"symbol": "SH.000001", "name": "上证指数"},
    {"symbol": "SZ.399001", "name": "深证成指"},
    {"symbol": "SZ.399006", "name": "创业板指"},
]


def _search_payload(q):
    global BASICINFO_STATE
    if BASICINFO_STATE == "idle":
        BASICINFO_STATE = "loading"
        threading.Thread(target=_load_basicinfo, daemon=True).start()
    ql = q.strip().upper()
    exact, prefix, contains = [], [], []
    if ql:
        for r in STATIC_INDEXES:
            bare = r["symbol"].split(".", 1)[-1]
            if ql in r["symbol"] or ql in r["name"].upper() or bare.startswith(ql):
                exact.append(r)
        with LOCK:
            lists = list(BASICINFO.values())
        for rows in lists:
            for r in rows:
                code = r["symbol"].upper()
                bare = code.split(".", 1)[-1]
                name = r["name"].upper()
                if code == ql or bare == ql or bare.lstrip("0") == ql.lstrip("0"):
                    exact.append(r)
                elif bare.startswith(ql) or code.startswith(ql) or name.startswith(ql):
                    prefix.append(r)
                elif ql in name or ql in code:
                    contains.append(r)
            if len(exact) + len(prefix) >= 20:
                break
    return {"ok": True, "loading": BASICINFO_STATE != "ready",
            "results": (exact + prefix + contains)[:20]}


def _downsample(points, limit=120):
    n = len(points)
    if n <= limit:
        return points
    step = (n - 1) / (limit - 1)
    return [points[round(i * step)] for i in range(limit)]


def _get_clean_rt(entry):
    if not entry or not entry["points"]:
        return []
    sorted_pts = sorted(entry["points"], key=lambda x: x["t"])
    deduped = []
    for p in sorted_pts:
        if deduped and deduped[-1]["t"] == p["t"]:
            deduped[-1] = {"t": p["t"], "p": p["p"]}
        else:
            deduped.append({"t": p["t"], "p": p["p"]})
    return _downsample(deduped)


def _quotes_payload():
    with LOCK:
        quotes = []
        for code, q in QUOTES.items():
            out = dict(q)
            entry = RT.get(code)
            out["rt"] = _get_clean_rt(entry)
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
                            time=(f"{row.get('data_date', '')} {row.get('data_time', '')}".strip() or None),
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
        elif url.path == "/search":
            q = (parse_qs(url.query).get("q") or [""])[0]
            self._json(_search_payload(q))
        elif url.path == "/snapshot":
            symbol = (parse_qs(url.query).get("symbol") or [""])[0]
            if not symbol:
                self._json({"ok": False, "error": "missing symbol"}, 400)
                return
            _fetch_snapshot([symbol])
            with LOCK:
                q = dict(QUOTES.get(symbol, {"symbol": symbol}))
                entry = RT.get(symbol)
                q["rt"] = _get_clean_rt(entry)
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


# ponytail: only exchanges we watch; default covers HK/US regular session
SESSION_HOURS = {"SH": ("09:30", "15:00"), "SZ": ("09:30", "15:00")}


def _rt_is_stale(code, q):
    """True when the market is in-session (per exchange-local update_time) but
    the cached timeshare is from another day, empty, or >15 min behind. Happens
    when OpenD drops the connection and the SDK's auto-resubscribe fails
    (e.g. transient 拉取美股夜盘状态失败): pulls keep working, pushes are gone,
    and the chart silently freezes on the last primed session."""
    t = str(q.get("time") or "")
    if len(t) < 16:
        return False
    date, hhmm = t[:10], t[11:16]
    start, end = SESSION_HOURS.get(code.split(".", 1)[0], ("09:30", "16:00"))
    if not (start <= hhmm <= end):
        return False
    entry = RT.get(code)
    if not entry or not entry["points"] or entry["date"] != date:
        return True
    last = entry["points"][-1]["t"]
    gap = (int(hhmm[:2]) - int(last[:2])) * 60 + int(hhmm[3:]) - int(last[3:])
    return gap > 15


def _live_subs():
    """Codes OpenD actually holds on our connection, or None if it can't say.
    WATCHED alone lies: OpenD drops subscriptions on reconnect/quota pressure
    without telling the SDK, and a code whose subscribe failed once would never
    be retried — either way the quote freezes silently (A-share indices did)."""
    qc = _ctx()
    if qc is None:
        return None
    ret, data = qc.query_subscription(is_all_conn=False)
    if ret != FT.RET_OK:
        return None
    return set(data.get("sub_list", {}).get("QUOTE", []))


def _snapshot_loop():
    """Refresh snapshots every 60s: keeps ext-session prices, volume and 52w
    fresh even when OpenD sends no pushes (one batched call, quota 10/30s).
    Also re-subscribes anything OpenD no longer has, plus stale timeshares."""
    while True:
        _time.sleep(60)
        with LOCK:
            codes = sorted(WATCHED)
        if not codes:
            continue
        _fetch_snapshot(codes)
        live = _live_subs()
        with LOCK:
            broken = [c for c in codes if c not in PULL_ONLY and c not in FALLBACK
                      and ((live is not None and c not in live)
                           or _rt_is_stale(c, QUOTES.get(c) or {}))]
        if broken:
            _subscribe(broken)  # resubscribe + re-prime the timeshare


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
