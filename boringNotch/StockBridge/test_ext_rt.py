"""Self-check for _attach_rt: `rt` must always describe the same session as `ext`.

The sparkline maps x onto the ext-session window whenever `ext` is set, so a
regular-session `rt` shipped alongside `ext` clamps the whole line to the right
edge (the 时分图错位 bug). No network, no OpenD.
"""
import importlib.util, sys
from datetime import datetime
from zoneinfo import ZoneInfo

spec = importlib.util.spec_from_file_location(
    "sb", __file__.replace("test_ext_rt.py", "stock_bridge.py"))
sb = importlib.util.module_from_spec(spec)
sys.modules["sb"] = sb
spec.loader.exec_module(sb)

CODE = "US.AAPL"
REG = [{"t": "09:30", "p": 300.0}, {"t": "16:00", "p": 310.0}]
sb.RT[CODE] = {"date": "2026-08-10", "points": REG}
base = {"symbol": CODE, "cur": 310.0, "lastClose": 300.0, "prePrice": 313.0}
today = datetime.now(ZoneInfo("America/New_York")).date()

# no ext session -> regular line
sb._ext_session = lambda: None
assert sb._attach_rt(dict(base))["rt"] == REG

# pre-market with 0/1 sampled point -> empty, never the regular line
sb._ext_session = lambda: "pre"
sb.EXT_RT.pop(CODE, None)
q = sb._attach_rt(dict(base))
assert q["ext"]["label"] == "盘前", q["ext"]
assert q["rt"] == [], q["rt"]
sb.EXT_RT[CODE] = {"key": f"{today}|pre", "points": [{"t": "08:45", "p": 313.0}]}
assert sb._attach_rt(dict(base))["rt"] == [{"t": "08:45", "p": 313.0}]

# points cached from a past session must not be served against today's axis
sb.EXT_RT[CODE] = {"key": "2020-01-02|after", "points": [{"t": "17:00", "p": 9.0}]}
assert sb._attach_rt(dict(base))["rt"] == []

# backfill keeps only today's bars inside the session window, and merges with
# whatever the local sampler already collected
NY = ZoneInfo("America/New_York")
midnight = datetime.now(NY).replace(hour=0, minute=0, second=0, microsecond=0)


def at(hh, mm, day=0):
    return int(midnight.replace(hour=hh, minute=mm).timestamp()) + day * 86400


bars = [(at(3, 59), 1.0), (at(4, 0), 2.0), (at(4, 5), None), (at(4, 6), 3.0),
        (at(9, 30), 4.0), (at(4, 10), 5.0, ), (at(4, 30, day=-1), 6.0)]
sb._curl_json = lambda url, retries=3: {"chart": {"result": [
    {"timestamp": [b[0] for b in bars],
     "indicators": {"quote": [{"close": [b[1] for b in bars]}]}}]}}
sb.EXT_RT[CODE] = {"key": f"{today}|pre", "points": [{"t": "08:45", "p": 313.0}]}
assert sb._ext_backfill(CODE, "pre", f"{today}|pre")
assert sb.EXT_RT[CODE]["points"] == [
    {"t": "04:00", "p": 2.0}, {"t": "04:06", "p": 3.0}, {"t": "04:10", "p": 5.0},
    {"t": "08:45", "p": 313.0}], sb.EXT_RT[CODE]["points"]

print("ok")
