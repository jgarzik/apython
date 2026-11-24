# Every set method and operator whose probe runs an __eq__ or __hash__ that
# raises: the error comes out, and nothing the method held is left alive --
# the key it kept for the turn, the half-built result, the coerced operand.
import gc, sys
class E:
    live = 0
    def __init__(s, h=1, bad=True): s.h=h; s.bad=bad; E.live += 1
    def __del__(s): E.live -= 1
    def __hash__(s): return s.h
    def __eq__(s,o):
        if s.bad or getattr(o,'bad',False): raise RuntimeError("eq")
        return s is o
class H:
    def __hash__(s): raise RuntimeError("hash")
def run(label, f):
    try: r = f(); print(label, "ok", type(r).__name__)
    except Exception as e: print(label, type(e).__name__, e)
def mk(): return {E(1, False)}
def other(): return {E(1, True)}
ops = [
 ("add", lambda: mk().add(E())), ("add-h", lambda: set().add(H())),
 ("remove", lambda: mk().remove(E())), ("discard", lambda: mk().discard(E())),
 ("union", lambda: mk().union(other())), ("or", lambda: mk() | other()),
 ("update-seq", lambda: mk().update([E()])), ("update-set", lambda: mk().update(other())),
 ("update-h", lambda: set().update([1, H()])),
 ("inter", lambda: mk().intersection(other())), ("and", lambda: mk() & other()),
 ("diff", lambda: mk().difference(other())), ("sub", lambda: mk() - other()),
 ("symdiff", lambda: mk().symmetric_difference(other())), ("xor", lambda: mk() ^ other()),
 ("issubset", lambda: mk().issubset(other())), ("issuperset", lambda: mk().issuperset(other())),
 ("isdisjoint", lambda: mk().isdisjoint(other())),
 ("issubset-l", lambda: mk().issubset([E()])), ("inter-l", lambda: mk().intersection([E()])),
 ("le", lambda: mk() <= other()), ("ior", lambda: mk().__ior__(other())),
 ("contains", lambda: E() in mk()), ("set()", lambda: set([E(1,False), E()])),
 ("frozenset()", lambda: frozenset([E(1,False), E()])),
]
for l, f in ops:
    for _ in range(3): run(l, f)
    gc.collect()
    print(l, "live", E.live)
