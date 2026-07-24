"""Self-check for the WATCHED/OpenD reconcile. Needs a live OpenD on 11111.

Simulates the two real failure modes and asserts the 60s loop repairs both:
  1. code in WATCHED but OpenD dropped its subscription (unsubscribe behind
     the bridge's back)
  2. code the app asked for whose subscribe failed (never in OpenD at all)
"""
import importlib.util, sys, time

spec = importlib.util.spec_from_file_location(
    "sb", __file__.replace("test_reconcile.py", "stock_bridge.py"))
sb = importlib.util.module_from_spec(spec)
sys.modules["sb"] = sb
spec.loader.exec_module(sb)

# HK codes: this account can subscribe these. A-share indices now route to the
# Tencent fallback (no OpenD subscription), covered at the bottom.
A, B = "HK.00700", "HK.01810"
assert sb._watch([A, B]), sb.LAST_ERROR
live = sb._live_subs()
assert live is not None and {A, B} <= live, live

# mode 1: OpenD loses A behind our back; WATCHED still claims it
sb._ctx().unsubscribe([A], [getattr(sb.FT.SubType, t) for t in sb.SUB_TYPES])
time.sleep(1)
assert A not in (sb._live_subs() or set()), "unsubscribe did not take"
assert A in sb.WATCHED

# mode 2: app wants C but it is not subscribed (as if subscribe had failed)
C = "HK.09988"
with sb.LOCK:
    sb.WATCHED.add(C)
assert C not in (sb._live_subs() or set())

# what the loop body does each tick
codes = sorted(sb.WATCHED)
live = sb._live_subs()
with sb.LOCK:
    broken = [c for c in codes
              if (live is not None and c not in live) or sb._rt_is_stale(c, sb.QUOTES.get(c) or {})]
assert A in broken and C in broken, broken
sb._subscribe(broken)
time.sleep(1)
live = sb._live_subs()
assert {A, B, C} <= live, f"not repaired: {live}"

# dropping B from the watchlist releases its quota
sb._watch([A, C])
time.sleep(1)
live = sb._live_subs()
print("after drop:", sorted(live), "WATCHED:", sorted(sb.WATCHED))
assert B not in live and {A, C} <= live, live
assert B not in sb.WATCHED

sb._ctx().unsubscribe([A, C], [getattr(sb.FT.SubType, t) for t in sb.SUB_TYPES])
print("OK — resubscribes dropped + never-subscribed codes, releases removed ones")
sb._ctx().close()  # futu's net threads are non-daemon; without this we hang at exit
