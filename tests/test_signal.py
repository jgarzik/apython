"""signal: installing a handler, and having it run.

A C signal handler cannot run Python -- it has no frame, no value stack, and
it interrupted something half-finished -- so what it does is record that the
signal arrived, and the eval loop runs the Python handler at the top of the
next loop iteration.  Everything below turns on that delivery actually
happening, which is why each case ends in a loop rather than a bare call.
"""

import signal
import os

print("--- the numbers and the sentinels ---")
print(signal.SIGINT, signal.SIGTERM, signal.SIGUSR1, signal.SIGUSR2)
print(repr(signal.SIGINT), repr(signal.SIG_DFL), repr(signal.SIG_IGN))
print(int(signal.SIGHUP), int(signal.SIGALRM), int(signal.SIGCHLD))
print(signal.NSIG, signal.SIG_DFL == 0, signal.SIG_IGN == 1)
print(signal.Signals.SIGINT is signal.SIGINT)
print(sorted(int(x) for x in signal.valid_signals())[:5])
print(len(signal.valid_signals()))

print("--- what is installed to begin with ---")
print(signal.getsignal(signal.SIGINT))
print("default handler:", signal.getsignal(signal.SIGINT) is signal.default_int_handler)
print(signal.getsignal(signal.SIGUSR1))
print(signal.getsignal(signal.SIGTERM))

print("--- installing one, and running it ---")
seen = []
frames = []


def handler(signum, frame):
    seen.append(int(signum))
    frames.append(frame)


previous = signal.signal(signal.SIGUSR1, handler)
print("previous:", previous)
print("installed:", signal.getsignal(signal.SIGUSR1) is handler)

os.kill(os.getpid(), signal.SIGUSR1)
for _ in range(3):
    pass
print("delivered:", seen)

print("--- the handler is given the interrupted frame ---")
#
# CPython passes the frame the signal interrupted, and it has to be a real
# one: pdb's sigint_handler keeps it and traceback.print_stack(frame) walks
# it.  A two-Value argument array grows UPWARD from its slot, so getting the
# layout wrong handed the handler ITSELF as the frame.
print(type(frames[-1]).__name__)
print(frames[-1].f_code.co_name, frames[-1] is handler)
print(hasattr(frames[-1], "f_lineno"), hasattr(frames[-1], "f_globals"))


def from_a_function():
    seen.clear()
    frames.clear()
    signal.raise_signal(signal.SIGUSR1)
    for _ in range(3):
        pass
    return frames[-1].f_code.co_name


print(from_a_function())

print("--- raise_signal reaches the same place ---")
seen.clear()
signal.raise_signal(signal.SIGUSR1)
for _ in range(3):
    pass
print("delivered:", seen)

print("--- two different signals ---")
seen.clear()
signal.signal(signal.SIGUSR2, handler)
signal.raise_signal(signal.SIGUSR1)
signal.raise_signal(signal.SIGUSR2)
for _ in range(3):
    pass
print("delivered:", sorted(seen))

print("--- SIG_IGN and SIG_DFL round trip ---")
print(signal.signal(signal.SIGUSR1, signal.SIG_IGN) is handler)
print(signal.getsignal(signal.SIGUSR1))
print(signal.signal(signal.SIGUSR1, signal.SIG_DFL))
print(signal.getsignal(signal.SIGUSR1))
seen.clear()
signal.signal(signal.SIGUSR1, signal.SIG_IGN)
signal.raise_signal(signal.SIGUSR1)
for _ in range(3):
    pass
print("ignored:", seen)

print("--- a handler that raises unwinds the loop it interrupted ---")


def raiser(signum, frame):
    raise RuntimeError("from a handler")


signal.signal(signal.SIGUSR1, raiser)
n = 0
try:
    while True:
        n += 1
        if n == 5:
            signal.raise_signal(signal.SIGUSR1)
        if n > 1000:
            break
except RuntimeError as e:
    print("RuntimeError", e, "after", n < 1000)

print("--- KeyboardInterrupt is what SIGINT does by default ---")
signal.signal(signal.SIGUSR1, signal.SIG_DFL)
try:
    m = 0
    while True:
        m += 1
        if m == 5:
            signal.raise_signal(signal.SIGINT)
        if m > 1000:
            break
except KeyboardInterrupt:
    print("KeyboardInterrupt caught")

print("--- and it can be replaced and put back ---")
old_int = signal.getsignal(signal.SIGINT)
signal.signal(signal.SIGINT, handler)
seen.clear()
signal.raise_signal(signal.SIGINT)
for _ in range(3):
    pass
print("delivered:", seen)
signal.signal(signal.SIGINT, old_int)
print(signal.getsignal(signal.SIGINT) is old_int)

print("--- what it refuses ---")
for num, hnd in ((signal.SIGKILL, handler), (signal.SIGSTOP, handler)):
    try:
        signal.signal(num, hnd)
    except OSError as e:
        print("OSError", e.errno)
for num in (0, -1, 1234, signal.NSIG):
    try:
        signal.signal(num, handler)
    except ValueError as e:
        print("ValueError", e)
for bad in ("nope", 2, 3.5, [], None):
    try:
        signal.signal(signal.SIGUSR1, bad)
    except TypeError as e:
        print("TypeError", e)
for num in (0, -1, 1234):
    try:
        signal.getsignal(num)
    except ValueError as e:
        print("ValueError", e)

print("--- strsignal ---")
print(signal.strsignal(signal.SIGINT))
print(signal.strsignal(signal.SIGTERM))
print(signal.strsignal(signal.SIGUSR1))

print("--- alarm returns what was left, and cancels ---")
print(signal.alarm(0))
signal.alarm(100)
left = signal.alarm(0)
print(0 < left <= 100)
print(signal.alarm(0))

print("--- a signal interrupts the syscall, not the sleep ---")
# PEP 475.  nanosleep came back with EINTR and time.sleep took that for the
# end of the sleep: an alarm one second into a two-second sleep returned after
# one, and the handler did not run either, because nothing on the way out
# looked at the pending flag.  CPython runs what arrived and sleeps out the
# remainder.
import time

fired = []


def note(sig, frame):
    fired.append(sig)


signal.signal(signal.SIGALRM, note)
signal.alarm(1)
start = time.time()
time.sleep(2.0)
took = time.time() - start
print("handler ran", fired == [signal.SIGALRM], "slept it out", took >= 1.9)


def boom(sig, frame):
    raise KeyboardInterrupt("from the handler")


# ...and a handler that RAISES ends it, which is how Ctrl-C gets out of a
# long sleep.
signal.signal(signal.SIGALRM, boom)
signal.alarm(1)
start = time.time()
try:
    time.sleep(3.0)
    print("slept through, which is wrong")
except KeyboardInterrupt as e:
    print("interrupted:", e, "early:", time.time() - start < 2.5)

signal.signal(signal.SIGALRM, signal.SIG_DFL)
signal.alarm(0)

# An ordinary sleep is unchanged, and so are the arguments it refuses.
start = time.time()
time.sleep(0.05)
print("plain sleep", time.time() - start >= 0.04)
for bad in (-1, float("nan"), float("inf"), 10 ** 30):
    try:
        time.sleep(bad)
        print("%-20r accepted" % (bad,))
    except Exception as e:
        print("%-20r %s: %s" % (bad, type(e).__name__, e))

print("--- the interval timers ---")
# signal.alarm takes whole seconds and nothing else, so a test that wants a
# sub-second alarm -- which is most of the ones that test signal delivery at
# all -- had nothing to reach for.  setitimer and getitimer were not there.
print(sorted(n for n in ("setitimer", "getitimer", "ItimerError",
                         "ITIMER_REAL", "ITIMER_VIRTUAL", "ITIMER_PROF")
             if hasattr(signal, n)))
print(signal.ITIMER_REAL, signal.ITIMER_VIRTUAL, signal.ITIMER_PROF,
      issubclass(signal.ItimerError, OSError))

ticked = []


def tick(sig, frame):
    ticked.append(sig)


signal.signal(signal.SIGALRM, tick)
print("idle     ", signal.getitimer(signal.ITIMER_REAL))
print("replaced ", signal.setitimer(signal.ITIMER_REAL, 0.05))
armed = signal.getitimer(signal.ITIMER_REAL)
print("armed    ", 0 < armed[0] <= 0.05, armed[1])
start = time.time()
while not ticked and time.time() - start < 3.0:
    pass
print("fired    ", ticked == [signal.SIGALRM], time.time() - start < 2.0)
print("spent    ", signal.getitimer(signal.ITIMER_REAL))
print("disarmed ", signal.setitimer(signal.ITIMER_REAL, 0.0),
      signal.getitimer(signal.ITIMER_REAL))
signal.signal(signal.SIGALRM, signal.SIG_DFL)

print("--- and what they refuse ---")
for label, fn in (("getitimer()", lambda: signal.getitimer()),
                  ("getitimer(99)", lambda: signal.getitimer(99)),
                  ("getitimer(-1)", lambda: signal.getitimer(-1)),
                  ("getitimer('x')", lambda: signal.getitimer("x")),
                  ("setitimer()", lambda: signal.setitimer()),
                  ("setitimer(0)", lambda: signal.setitimer(0)),
                  ("setitimer(0,1,2,3)", lambda: signal.setitimer(0, 1, 2, 3)),
                  ("setitimer(0,-1)", lambda: signal.setitimer(0, -1)),
                  ("setitimer(0,nan)", lambda: signal.setitimer(0, float("nan"))),
                  ("setitimer(0,'x')", lambda: signal.setitimer(0, "x")),
                  ("setitimer(0,None)", lambda: signal.setitimer(0, None)),
                  ("setitimer(99,1)", lambda: signal.setitimer(99, 1))):
    try:
        print("%-20s %r" % (label, fn()))
    except Exception as e:
        print("%-20s %s: %s" % (label, type(e).__name__, e))

signal.signal(signal.SIGUSR1, signal.SIG_DFL)
signal.signal(signal.SIGUSR2, signal.SIG_DFL)
print("done")
