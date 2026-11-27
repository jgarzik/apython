# The sys attributes a program asks for by name.
#
# None of these is decoration.  test.support and regrtest read _xoptions and
# _git on the way in, so their absence stopped fifty-five and twenty-seven of
# CPython's tests before any of them ran; api_version and _stdlib_dir are read
# by platform; getsizeof is what test.support.check_sizeof is written on and
# what lib/_testinternalcapi.py adds a GC header to; and __spec__, __loader__
# and __package__ are what every module HAS -- sys is built by hand in
# assembly and never goes through import_load_module, which is the only reason
# it had none of them.
#
# breakpoint() was a no-op stub, so it silently did nothing at all.  It now
# calls sys.breakpointhook, which is where a debugger replaces it -- and
# sys.breakpointhook IS sys.__breakpointhook__, which is how a program asks
# whether anything has.
import sys

# --- values ------------------------------------------------------------
print("api_version:", type(sys.api_version).__name__, sys.api_version > 0)
print("_xoptions:", type(sys._xoptions).__name__, sys._xoptions.get("nope"))
print("_git:", type(sys._git).__name__, len(sys._git),
      all(isinstance(x, str) for x in sys._git))
# __spec__ exists; its VALUE is None here, because nothing builds a
# ModuleSpec -- the import system is assembly rather than
# importlib._bootstrap, which the old bug list recorded.  What is compared is that the
# attribute is there at all, which is what a module walker needs.
print("__spec__ present:", hasattr(sys, "__spec__"))
print("__loader__ present:", hasattr(sys, "__loader__"))
print("__package__:", repr(sys.__package__))

# --- getsizeof ---------------------------------------------------------
print("list > 0:", sys.getsizeof([]) > 0)
print("str > 0:", sys.getsizeof("abc") > 0)
print("int > 0:", sys.getsizeof(1) > 0)
print("float > 0:", sys.getsizeof(1.5) > 0)
print("dict > 0:", sys.getsizeof({}) > 0)
print("an instance > 0:", sys.getsizeof(sys) > 0)


class Override:
    def __sizeof__(self):
        return 4242


# getsizeof is __sizeof__ plus the collector's header when the object is
# tracked, which is CPython's rule; the header is 16 bytes here and 32 there,
# so the relationship is compared rather than the number.
print("override honoured:", sys.getsizeof(Override()) > 4242)


class NotCallable:
    __sizeof__ = None


try:
    sys.getsizeof(NotCallable())
    print("non-callable: NO ERROR")
except TypeError:
    print("non-callable: TypeError")
try:
    sys.getsizeof()
    print("no argument: NO ERROR")
except TypeError:
    print("no argument: TypeError")

# object.__sizeof__ is the same number, because the two share a body.
print("dunder agrees:", sys.getsizeof([]) >= [].__sizeof__())
print("dunder on an instance:", Override().__sizeof__())

# --- _clear_type_cache -------------------------------------------------
class Cached:
    def m(self):
        return 1


c = Cached()
print("before:", c.m())
print("_clear_type_cache:", sys._clear_type_cache())
print("after:", c.m())
# And the cache really was consulted: change the class and the change takes.
Cached.m = lambda self: 2
print("changed:", c.m())
sys._clear_type_cache()
print("changed after clear:", c.m())

# --- _current_frames ---------------------------------------------------
frames = sys._current_frames()
print("_current_frames:", type(frames).__name__, len(frames) >= 1)
print("keys are ints:", all(isinstance(k, int) for k in frames))
print("values are frames:",
      all(type(v).__name__ == "frame" for v in frames.values()))
print("the frame has a lineno:",
      all(isinstance(v.f_lineno, int) for v in frames.values()))

# --- breakpointhook ----------------------------------------------------
print("hook is the dunder:", sys.breakpointhook is sys.__breakpointhook__)
print("hook is callable:", callable(sys.breakpointhook))
calls = []
sys.breakpointhook = lambda *a, **k: calls.append((a, k))
breakpoint()
breakpoint(1, 2, x=3)
print("breakpoint() reaches the hook:", calls)
sys.breakpointhook = sys.__breakpointhook__
print("restored:", sys.breakpointhook is sys.__breakpointhook__)
print("survived")
