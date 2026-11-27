# groupdict(default) must own the default it stores.
#
# sre_match_groupdict_method substituted the caller's `default` for every
# unmatched group and then DECREFed after dict_set -- correct for the fresh
# strings sre_match_get_group_str hands back, one short for the default, which
# is borrowed from the argument array.  groups() had always INCREFed there and
# even said why; groupdict() had not.
#
# The damage was invisible in ordinary use because the default is usually a
# constant the code object keeps alive.  It surfaced at interpreter shutdown,
# where whichever of the two owners died first took the string with it and the
# other read freed memory -- and only became a crash when an unrelated change
# moved the heap enough for glibc to notice.  See the old bug list's history and
# tests/test_sre2.py, which exercised groupdict('N/A') without catching it.
#
# So this file builds the default at RUN TIME and drops every other reference
# to it before touching the dict: if groupdict does not own it, the string is
# freed while the dict still points at it.

import _sre

# (?P<first>hello)(?:(?P<second>world)|) -- second never matches "hello"
hello_opt_code = [14, 16, 1, 5, 10, 5, 0, 104, 101, 108, 108, 111, 0, 0, 0, 0,
                  0, 17, 0, 16, 104, 16, 101, 16, 108, 16, 108, 16, 111, 17, 1,
                  7, 17, 17, 2, 16, 119, 16, 111, 16, 114, 16, 108, 16, 100,
                  17, 3, 15, 5, 3, 15, 2, 0, 1]
p = _sre.compile("(?P<first>hello)(?:(?P<second>world)|)", 0, hello_opt_code, 2,
                 {'first': 1, 'second': 2}, (None, 'first', 'second'))


def fresh_default():
    # Built by concatenation, so it is a new object rather than a constant the
    # code object holds a reference to.
    return "miss" + "ing"


m = p.match('hello')
d = m.groupdict(fresh_default())

# The temporary is gone now.  The dict must be the only owner.
print("first :", d['first'])
print("second:", d['second'])

# Churn the allocator: a freed value would be reused by these.
print("churn :", len([[i, i] for i in range(3000)]))

# And read it again afterwards.
print("second:", d['second'])
print("equal :", d['second'] == "missing")
print("sorted:", sorted(d.items()))

# The same for a default that is a list, so a wrong refcount corrupts a
# container rather than a string.
m2 = p.match('hello')
d2 = m2.groupdict(["a", "b"])
print("list  :", d2['second'])
print("churn :", len([[i, i] for i in range(3000)]))
print("list  :", d2['second'])

# groups() takes the same default and has always been right; keep it covered
# alongside, so the two cannot drift apart again.
g = p.match('hello').groups(fresh_default())
print("groups:", g)
print("churn :", len([[i, i] for i in range(3000)]))
print("groups:", g)
