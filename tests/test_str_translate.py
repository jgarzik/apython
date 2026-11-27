# str.translate takes any subscriptable table, not only a dict.
#
# str_method_translate called dict_get on whatever it was handed, with no
# type check at all, so a list read its fields as a dict's and the
# interpreter segfaulted.  `"abc".translate([None] * 200)` was enough.
#
# It is reachable from ordinary stdlib code: re.escape() is
# `pattern.translate(_special_chars_map)`, and fnmatch builds its pattern
# through it -- so `fnmatch.fnmatch("a.txt", "*.txt")` crashed once os and
# fnmatch could import at all.
#
# CPython's rule: look the ordinal up in the table; a LookupError -- which is
# what a short list or a str table gives -- means leave the character alone;
# None means delete it; an int is an ordinal and a str is substituted; and a
# table with no subscript at all is a TypeError.
#
# A second bug was in the same function and is why this file churns at the
# end: dict_get hands back a BORROWED reference where mp_subscript hands back
# an owned one, and the release afterwards was freeing the table's own values.


def check(label, fn):
    try:
        print("%-30s %r" % (label, fn()))
    except BaseException as e:
        print("%-30s %s" % (label, type(e).__name__))


print("--- a dict table, which always worked ---")
check("ord -> str", lambda: "a.b".translate({ord("."): "\\."}))
check("ord -> ord", lambda: "abc".translate({ord("a"): ord("z")}))
check("ord -> None", lambda: "abc".translate({ord("b"): None}))
check("ord -> multichar", lambda: "abc".translate({ord("b"): "XYZ"}))
check("ord -> empty", lambda: "abc".translate({ord("b"): ""}))
check("empty dict", lambda: "abc".translate({}))
check("maketrans", lambda: "abc".translate(str.maketrans("ab", "zy")))
check("maketrans delete", lambda: "abc".translate(str.maketrans("", "", "b")))
check("no match", lambda: "abc".translate({ord("z"): "!"}))
check("empty string", lambda: "".translate({ord("a"): "z"}))

print()
print("--- a list table: this is what crashed ---")
check("list of None", lambda: "abc".translate([None] * 200))
check("list of str", lambda: "abc".translate(["X"] * 200))
check("list of ord", lambda: "abc".translate([ord("z")] * 200))
# A short list raises IndexError for every lookup, which means "leave alone".
check("short list", lambda: "abc".translate([1, 2, 3]))
check("empty list", lambda: "abc".translate([]))

print()
print("--- and the other sequences ---")
check("tuple", lambda: "abc".translate((None,) * 200))
check("str table", lambda: "abc".translate("xyz"))
check("bytes table", lambda: "abc".translate(b"xyz"))

print()
print("--- a class with __getitem__ ---")


class Always:
    def __getitem__(self, key):
        return "Z"


class Boom:
    def __getitem__(self, key):
        raise RuntimeError("boom")


check("always Z", lambda: "abc".translate(Always()))
# A mapping that signals "not in the table" by RAISING is not covered here.
# An exception raised inside a subscript cannot be caught: raise_exception
# tail-jumps into eval_exception_unwind, which resumes the eval loop from
# saved globals rather than returning through the C stack, so it propagates
# where CPython would carry on.  The old bug list recorded it.  Every table that has a
# LENGTH -- dict, list, tuple, str, bytes -- is exact, because the bound is
# checked before the lookup rather than after, and those are the tables real
# code uses.
check("RuntimeError", lambda: "abc".translate(Boom()))

print()
print("--- a table that cannot be subscripted at all ---")
check("int", lambda: "abc".translate(5))
check("None", lambda: "abc".translate(None))
check("float", lambda: "abc".translate(1.5))
check("a plain object", lambda: "abc".translate(object()))

print()
print("--- what re.escape does, which is the reachable case ---")
special = "()[]{}?*+-|^$\\.&~# \t\n\r\v\f"
escape_map = {i: "\\" + chr(i) for i in b"()[]{}?*+-|^$\\.&~# \t\n\r\v\f"}
check("re.escape shape", lambda: "a.b*c".translate(escape_map))
check("nothing special", lambda: "abc".translate(escape_map))
check("all special", lambda: special.translate(escape_map))

print()
print("--- churn, since every substitution allocates ---")
out = [("x%d.y" % i).translate(escape_map) for i in range(200)]
print("churn        :", len([[i, i] for i in range(3000)]))
print("intact       :", out[7], out[199])
print("count        :", len(out), len(set(out)))
