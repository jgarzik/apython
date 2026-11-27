# A __aexit__ lookup that raises must not release the context manager.
#
# BEFORE_ASYNC_WITH's `.baw_lookup_raised` is reached only from
# `.baw_exit_missing` -- before anything is pushed -- so the manager is still
# in the value-stack slot VPOP_VAL read it from and the unwinder releases that.
# Releasing it here as well took one reference per failure, and the third
# `async with` over the same manager segfaulted in gc_list_remove.  The
# synchronous twin's own arm records the rule and does not release.
import asyncio
import gc
import sys


class Raises:
    async def __aenter__(self):
        return self

    @property
    def __aexit__(self):
        raise RuntimeError("nope")


class NoExit:
    async def __aenter__(self):
        return self


mgr = Raises()
plain = NoExit()


async def main():
    base = sys.getrefcount(mgr)
    for i in range(8):
        try:
            async with mgr:
                pass
        except RuntimeError:
            pass
        print(i, sys.getrefcount(mgr) - base)

    # A manager with no __aexit__ at all: a TypeError, and the reference
    # count has to stay put for that arm too.  (The message is not CPython's;
    # the old bug list recorded the wording.)
    base2 = sys.getrefcount(plain)
    for i in range(4):
        try:
            async with plain:
                pass
        except TypeError:
            print("TypeError", i, sys.getrefcount(plain) - base2)

    # And the working case still works.
    class Ok:
        async def __aenter__(self):
            return "in"

        async def __aexit__(self, *a):
            return False

    async with Ok() as v:
        print("entered", v)


asyncio.run(main())
gc.collect()
print("survived", type(mgr).__name__, type(plain).__name__)
