"""Self-check for the 日韩 codes. Network only — no OpenD needed.

Covers what breaks silently: the yahoo field mapping for 韩股 (prices are raw
KRW, timestamps must land in 北京时间 like every other source), and that
/search can find them at all — futu's basicinfo universe has no JP/KR market,
so STATIC_SYMBOLS is their only entry point.
Run during KRX/TSE hours (北京 08:00–14:30) for a non-empty timeshare.
"""
import importlib.util, sys

spec = importlib.util.spec_from_file_location(
    "sb", __file__.replace("test_kr_jp.py", "stock_bridge.py"))
sb = importlib.util.module_from_spec(spec)
sys.modules["sb"] = sb
spec.loader.exec_module(sb)

SAMSUNG, HYNIX = "KR.005930", "KR.000660"

assert sb._yahoo_fetch([SAMSUNG, HYNIX]), sb.LAST_ERROR
for code in (SAMSUNG, HYNIX):
    q = sb.QUOTES[code]
    pts = sb.RT[code]["points"]
    print(code, q["name"], q["cur"], "昨收", q["lastClose"], q["time"],
          "| 分时", len(pts), pts[0]["t"], "->", pts[-1]["t"])
    assert q["name"] and q["cur"] > 1000, q          # raw KRW, never rescaled
    assert q["lastClose"] and abs(q["cur"] / q["lastClose"] - 1) < 0.35, q
    assert q["high"] >= q["cur"] >= q["low"], q
    assert len(q["time"]) == 19, q                   # '2026-07-27 09:16:00'
    # 北京时间, so the app's 日韩 session segments (480–870) line up
    assert "08:00" <= pts[0]["t"] <= "14:30", pts[0]
    assert pts[0]["t"] < pts[-1]["t"] <= "14:30", (pts[0], pts[-1])
    # yahoo sometimes stamps a stale 昨收 onto the last bar — a point outside
    # the day's own range is that bug, and it drew a cliff in the 时分图
    assert all(q["low"] <= p["p"] <= q["high"] for p in pts), q

# 新浪 side: the indices must still parse
assert sb._intl_fetch(["JP.N225", "KR.KOSPI"]), sb.LAST_ERROR
for code in ("JP.N225", "KR.KOSPI"):
    print(code, sb.QUOTES[code]["name"], sb.QUOTES[code]["cur"])
    assert sb.QUOTES[code]["cur"] > 0

# routing: FALLBACK codes must reach their own source, not futu
with sb.LOCK:
    sb.FALLBACK.update({SAMSUNG, "JP.N225"})
assert sb._fetch_snapshot([SAMSUNG, "JP.N225"]), sb.LAST_ERROR

for q in ("三星", "005930", "海力士", "N225", "KOSPI"):
    hits = [r["symbol"] for r in sb._search_payload(q)["results"]]
    print(f"search {q!r} ->", hits[:3])
    assert hits, f"{q} not searchable"

print("OK — 韩股行情+分时, 日韩指数, 回退路由, 搜索")
