# sys.getallocatedblocks(): how many blocks the allocator has handed out and
# not had back.  The number itself is the implementation's business; what a
# program can rely on is that it is an int, that holding more objects raises
# it, and that an operation which cleans up after itself does not.
import sys

n = sys.getallocatedblocks()
print(type(n).__name__, n > 0)

keep = [[i] for i in range(1000)]
grew = sys.getallocatedblocks() - n
print("holding 1000 lists raised it by at least 1000:", grew >= 1000)
del keep


def churn():
    return [str(i) for i in range(50)]


for _ in range(20):
    churn()
a = sys.getallocatedblocks()
for _ in range(200):
    churn()
print("a clean loop does not climb:", sys.getallocatedblocks() - a < 50)

try:
    sys.getallocatedblocks(1)
except TypeError as exc:
    print(type(exc).__name__)
