"""Gate inspection for scenario 16: the five criteria the plan names, per repetition."""
import json, re, sys, glob, os

# A question that seeks permission to ADD. Not "quer mais alguma coisa?" (an offer),
# not the checkout question (that one is required).
PERMISSION = re.compile(
    r"(pode(?:mos)?\s+(?:eu\s+)?(?:confirmar|adicionar|colocar|incluir)"
    r"|quer\s+que\s+(?:eu\s+)?(?:adicione|coloque|inclua)"
    r"|confirma(?:r)?\s+(?:pra|para)\s+(?:eu\s+)?(?:adicionar|colocar)"
    r"|adiciono\s*\?|coloco\s*\?|posso\s+adicionar|posso\s+colocar)", re.I)

def calls(turn, name=None, status=None):
    return [c for c in turn["tool_calls"]
            if (name is None or c["name"] == name) and (status is None or c["status"] == status)]

rows = []
for d in sorted(glob.glob(sys.argv[1]), key=lambda p: int(re.search(r"rep(\d+)", p).group(1))):
    rep = int(re.search(r"rep(\d+)", d).group(1))
    t = json.load(open(d))
    turns = t["turns"]
    fails = []

    # 1. add_to_cart on turn one.
    if not calls(turns[0], "add_to_cart", "ok"):
        fails.append("no add_to_cart@turn1")
    # 2. no question asking permission to add, on the turn that should just add.
    m = PERMISSION.search(turns[0]["reply"])
    if m:
        fails.append(f"permission question@turn1: {m.group(0)!r}")
    # 3. a checkout hold before any execution.
    held = [(i, c) for i, tu in enumerate(turns, 1) for c in calls(tu, "create_order", "held")]
    ok = [(i, c) for i, tu in enumerate(turns, 1) for c in calls(tu, "create_order", "ok")]
    if not held:
        fails.append("no create_order hold")
    elif ok and held[0][0] >= ok[0][0]:
        fails.append("order executed before the hold")
    # 4. exactly one successful order after the confirmation.
    if len(ok) != 1:
        fails.append(f"{len(ok)} successful create_order (want 1)")
    # 5. no second checkout attempt after the purchase already landed. Anchored on
    # the successful call, not on "the last turn": when the whole exchange slips a
    # turn, the last turn IS the legitimate execution.
    if ok and any(calls(tu, "create_order") for tu in turns[ok[0][0]:]):
        fails.append("second checkout attempt after the order landed")
    # Cost, not correctness: the recheck closed on turn 3. Turn 4 means an extra
    # round trip the customer paid for — the friction this pilot is measuring.
    if ok and ok[0][0] > 3:
        fails.append(f"close landed on turn {ok[0][0]} (recheck: 3) — extra round trip")

    store_orders = len(t.get("store", {}).get("orders", []))
    rows.append((rep, t["pass"], ok[0][0] if ok else None, store_orders, fails))

bad = [r for r in rows if r[4] or not r[1]]
for rep, p, close, orders, fails in rows:
    print(f"rep{rep:<3} grader={'PASS' if p else 'FAIL':4} close_turn={close} orders={orders} "
          + ("OK" if not fails else "| " + "; ".join(fails)))
print(f"\n{len(rows)-len(bad)}/{len(rows)} clean on all five criteria")
