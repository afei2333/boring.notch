"""Self-check for /refresh: a manual pull of an inactive market must hand its
OpenD slots straight back, and must never touch codes outside WATCHED.
No network, no OpenD — the quote context is stubbed.
"""
import importlib.util, sys, types
from datetime import datetime
from zoneinfo import ZoneInfo

spec = importlib.util.spec_from_file_location(
    "sb", __file__.replace("test_refresh.py", "stock_bridge.py"))
sb = importlib.util.module_from_spec(spec)
sys.modules["sb"] = sb
spec.loader.exec_module(sb)

calls = []


class FakeCtx:
    def subscribe(self, codes, subs):
        calls.append(("sub", sorted(codes)))
        return "OK", None

    def unsubscribe(self, codes, subs):
        calls.append(("unsub", sorted(codes)))
        return "OK", None


sb.FT = types.SimpleNamespace(RET_OK="OK",
                              SubType=types.SimpleNamespace(**{t: t for t in sb.SUB_TYPES}))
sb._ctx = lambda: FakeCtx()
sb._fetch_snapshot = lambda codes: calls.append(("snap", sorted(codes))) or True
sb._prime_rt_history = lambda codes: calls.append(("prime", sorted(codes)))

sb.WATCHED.update({"HK.00700", "HK.01810", "US.AAPL"})
sb.ACTIVE.update({"US.AAPL"})            # US session: HK is not subscribed
real_is_open = sb._is_open
open_us = lambda code, now=None: code.startswith("US.")
sb._is_open = open_us

# refreshing the inactive HK tab: snapshot both, prime both, then release both
assert sb._refresh(["HK.00700", "HK.01810"])
assert calls == [("snap", ["HK.00700", "HK.01810"]),
                 ("sub", ["HK.00700", "HK.01810"]),
                 ("prime", ["HK.00700", "HK.01810"]),
                 ("unsub", ["HK.00700", "HK.01810"])], calls

# refreshing the active tab: no temporary subscription at all
calls.clear()
assert sb._refresh(["US.AAPL"])
assert calls == [("snap", ["US.AAPL"])], calls

# a code still listed ACTIVE right after its close must hand the slot back too
calls.clear()
sb._is_open = lambda code, now=None: False
assert sb._refresh(["US.AAPL"])
assert calls == [("snap", ["US.AAPL"]), ("sub", ["US.AAPL"]),
                 ("prime", ["US.AAPL"]), ("unsub", ["US.AAPL"])], calls
sb._is_open = open_us

# unknown codes are dropped, and an all-unknown request is a no-op
calls.clear()
assert sb._refresh(["US.NOPE"])
assert calls == [], calls

# the real session windows: weekday in-session vs. closed vs. weekend
ny = lambda *a: datetime(*a, tzinfo=ZoneInfo("America/New_York"))
hk = lambda *a: datetime(*a, tzinfo=ZoneInfo("Asia/Hong_Kong"))
assert real_is_open("US.AAPL", ny(2026, 8, 10, 9, 30))     # 周一盘中
assert real_is_open("US.AAPL", ny(2026, 8, 10, 5, 0))      # 盘前
assert not real_is_open("US.AAPL", ny(2026, 8, 10, 21, 0))  # 盘后收市
assert not real_is_open("US.AAPL", ny(2026, 8, 8, 10, 0))  # 周六
assert real_is_open("HK.00700", hk(2026, 8, 10, 16, 5))    # 收市竞价
assert not real_is_open("HK.00700", hk(2026, 8, 10, 16, 30))
assert not real_is_open("SH.000001", hk(2026, 8, 10, 15, 30))
assert real_is_open("JP.N225")                             # 无 OpenD 订阅，永远 active

print("ok")
