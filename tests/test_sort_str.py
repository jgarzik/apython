# list.sort()'s inline arm for two exact strs.
#
# The merge asks "is right < left" and used to reach str_compare through
# tp_richcompare, which builds a bool OBJECT that is then tested and released
# -- once per comparison, of which a sort does n log n.  Two exact strs are now
# compared where they stand.
#
# Three things have to hold and each is silent when it does not:
#
#   - the ORDER must be identical, including for strings that are prefixes of
#     one another and strings that differ only after an embedded NUL, which is
#     where a length-versus-bytes mistake shows;
#   - STABILITY must survive.  The arm answers "right < left"; answering
#     "right <= left" instead still sorts, and only reveals itself as equal
#     elements swapping places;
#   - a str SUBCLASS must not take it.  A subclass may define __lt__, and the
#     ones here define a lying one so that taking the fast path is visible in
#     the output rather than merely faster.
#
# reverse= flips the question the merge asks rather than reversing afterwards,
# so every case is run both ways.


def show(L):
    print(sorted(L))
    print(sorted(L, reverse=True))
    c = list(L)
    c.sort()
    print(c)
    c = list(L)
    c.sort(reverse=True)
    print(c)


def basics():
    for L in ([], ["a"], ["b", "a"], ["a", "b"], ["a", "a"],
              ["", "a", ""], ["z", "y", "x", "w"],
              ["banana", "apple", "cherry", "apple"]):
        show(L)


def prefixes():
    # A string against one that extends it, at every length: the common
    # prefix matches and the length decides.
    base = "abcdefghijklmnopqrstuvwxyz"
    show([base[:n] for n in range(len(base) + 1)])
    show([base[:n] for n in range(len(base), -1, -1)])
    # Differing only in the last byte, across the eight-byte stride.
    for n in (1, 7, 8, 9, 15, 16, 17):
        a = base[:n]
        b = a[:-1] + chr(ord(a[-1]) + 1)
        show([b, a, a, b])


def nul_bytes():
    show(["a\0b", "a\0a", "a\0c", "a"])
    show(["a\0", "a", "a\0\0", ""])
    show(["x\0z", "x\0y", "xy", "x"])


def wide():
    show(["é", "e", "z", "中", "\U0001f600", "a"])
    show(["été", "eta", "éta", "zebra", "中文", "é", "e", ""])
    show(["αβγ", "αβ", "αβγδ", "α"])
    # Same lead byte, differing continuation.
    show(["é", "ê", "è", "ë"])


def stability():
    # Equal keys must keep their input order, both ways round.
    pairs = [("b", 1), ("a", 2), ("b", 3), ("a", 4), ("b", 5), ("a", 6)]
    print(sorted(pairs, key=lambda p: p[0]))
    print(sorted(pairs, key=lambda p: p[0], reverse=True))
    # The same, with the strings themselves equal but distinct objects.
    words = [("x" * 3), ("x" * 3), ("y" * 3), ("x" * 3)]
    tagged = list(zip(words, range(4)))
    print(sorted(tagged, key=lambda t: t[0]))
    print(sorted(tagged, key=lambda t: t[0], reverse=True))


def subclasses():
    class Always(str):
        def __lt__(self, other):
            return True

    class Never(str):
        def __lt__(self, other):
            return False

    print([str(x) for x in sorted([Always("c"), Always("a"), Always("b")])])
    print([str(x) for x in sorted([Never("c"), Never("a"), Never("b")])])
    # Mixed: a plain str and a subclass in the same list, both orders.
    print([str(x) for x in sorted(["c", Always("a"), "b"])])
    print([str(x) for x in sorted([Always("a"), "c", "b"])])

    class Plain(str):
        pass

    print([str(x) for x in sorted([Plain("c"), "a", Plain("b")])])
    print([type(x).__name__ for x in sorted([Plain("c"), "a", Plain("b")])])


def keys_and_mixed():
    L = ["Banana", "apple", "Cherry", "date"]
    print(sorted(L), sorted(L, key=str.lower), sorted(L, key=len))
    print(sorted(L, key=str.lower, reverse=True))
    # Non-str elements must keep the generic path.
    print(sorted([3, 1, 2]), sorted([3.5, 1.0, 2.25]),
          sorted([True, False, True]))
    print(sorted([b"b", b"a"]), sorted([(2, "a"), (1, "b")]))
    for bad in (["a", 1], [1, "a"]):
        try:
            sorted(bad)
        except TypeError:
            print("TypeError", bad[0].__class__.__name__)
    # `sorted(["a", None])` is NOT here: it answers ['a', None] instead of
    # raising, while `sorted([None, "a"])` does raise -- the two differ only
    # in which side the None falls on.  Pre-existing, unrelated to the str
    # arm, and recorded in the old bug list.


def big():
    # A deterministic pseudo-random corpus, long enough for many merge levels.
    alpha = "abcdé中"
    st = 12345
    out = []
    for _ in range(400):
        chars = []
        for _ in range(8):
            st = (st * 1103515245 + 12345) % 2147483648
            chars.append(alpha[st % 6])
        out.append("".join(chars))
    s1 = sorted(out)
    print(len(s1), s1[0], s1[-1])
    print(s1 == sorted(out, reverse=True)[::-1])
    print(all(s1[i] <= s1[i + 1] for i in range(len(s1) - 1)))
    print(sorted(set(out))[:3], len(set(out)))
    # Already sorted, and reverse sorted.
    print(sorted(s1) == s1, sorted(s1[::-1]) == s1)


basics()
prefixes()
nul_bytes()
wide()
stability()
subclasses()
keys_and_mixed()
big()
