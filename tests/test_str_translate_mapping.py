# str.translate over a mapping object, including the misses it signals with an
# exception.
#
# The old bug list carried this as open: "a mapping object whose __getitem__ raises
# LookupError to mean 'not in the table' propagates instead, where CPython
# carries on", with the note that catching it was impossible because
# raise_exception tail-jumps into the unwinder and never returns.  It works --
# str_parts.asm reaches a heaptype's __getitem__ through dunder_call_2, which
# does return -- so this file is what keeps it working.

class Miss:
    def __getitem__(self, k):
        raise LookupError

class KeyMiss:
    def __getitem__(self, k):
        raise KeyError(k)

class IndexMiss:
    def __getitem__(self, k):
        raise IndexError

class Some:
    def __getitem__(self, k):
        if k == ord("a"):
            return "A"
        raise LookupError

class Deleting:
    def __getitem__(self, k):
        if k == ord("b"):
            return None
        raise LookupError

class Angry:
    def __getitem__(self, k):
        raise ValueError("not a miss")

print("abc".translate(Miss()), "abc".translate(KeyMiss()), "abc".translate(IndexMiss()))
print("abc".translate(Some()), "abc".translate(Deleting()))
print("".translate(Miss()), "aaa".translate(Some()))

# A mapping that answers an ordinal, or a longer string, or a deletion.
class Wide:
    def __getitem__(self, k):
        if k == ord("a"):
            return ord("z")
        if k == ord("b"):
            return "long"
        raise LookupError
print("abc".translate(Wide()))

# Anything that is not a LookupError propagates, as it does in CPython.
try:
    "abc".translate(Angry())
except ValueError as e:
    print("ValueError:", e)

# The table forms with a length are unaffected.
print("abc".translate({ord("a"): "X"}), "abc".translate({ord("b"): None}))
print("abc".translate(str.maketrans("ab", "xy")))
print("abc".translate(str.maketrans("", "", "b")))
print("abc".translate([]), "abc".translate({}))
