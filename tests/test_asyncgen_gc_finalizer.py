import gc
import sys


pending = []
closed = []


def abandon():
    cycle = []

    async def values():
        try:
            yield 1
        finally:
            closed.append(len(cycle))

    generator = values()
    cycle.append(generator)
    try:
        generator.__anext__().send(None)
    except StopIteration as done:
        assert done.value == 1


hooks = sys.get_asyncgen_hooks()
sys.set_asyncgen_hooks(finalizer=pending.append)
gc.disable()
try:
    abandon()
    assert not pending
    gc.collect()
    assert len(pending) == 1
    assert not closed
    try:
        pending.pop().aclose().send(None)
    except StopIteration:
        pass
    gc.collect()
    assert not pending
    assert closed == [1]
    print(closed)
finally:
    gc.enable()
    sys.set_asyncgen_hooks(*hooks)
