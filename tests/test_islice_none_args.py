# islice takes None for any of start, stop and step, meaning its default.
# A None start was compared against each index as given, so
# `islice(it, None, None)` yielded nothing -- which is how rich's
# Console.render_lines, slicing to a height of None, drew a table with every
# cell empty.  The arguments are also checked at the call, as CPython's are.
from itertools import islice

print(list(islice(iter([1, 2, 3]), None, None)))
print(list(islice(range(10), None)))
print(list(islice(range(10), None, 4)))
print(list(islice(range(10), 2, None)))
print(list(islice(range(10), 2, None, None)))
print(list(islice(range(10), None, None, 3)))
print(list(islice(range(10), 1, 8, 2)))
print(list(islice(range(10), True, 5, 2)))
print(list(islice(range(10), 5, 2)))


class Idx:
    def __index__(self):
        return 3


print(list(islice(range(10), Idx())))
print(list(islice(range(10), Idx(), None, Idx())))

for args in [(-1,), (1, -1), (-1, 3), (0, 2, 0), (0, 2, -1), ("x",),
             (1.0,), ("a", 3), (0, 3, 1.5)]:
    try:
        islice([1], *args)
        print(args, "accepted")
    except ValueError as e:
        print(args, "ValueError", e)

# The check is eager: a generator would only notice at the first next().
try:
    islice(iter([]), -2)
    print("lazy")
except ValueError:
    print("eager")
