import sys
from types import ModuleType


pkg = ModuleType("nfkc_package")
pkg.__path__ = []
child = ModuleType("nfkc_package.child")
child.μ = 13
pkg.child = child
sys.modules[pkg.__name__] = pkg
sys.modules[child.__name__] = child

source = """\
from __ｆｕｔｕｒｅ__ import ａｎｎｏｔａｔｉｏｎｓ
import ｎｆｋｃ_ｐａｃｋａｇｅ.ｃｈｉｌｄ as 𝓶
import ｎｆｋｃ_ｐａｃｋａｇｅ.ｃｈｉｌｄ
from .ｃｈｉｌｄ import µ as 𝓷

def identity(*, μ):
    return μ

class Result:
    def make(self):
        def labels(**labels):
            return labels
        return labels(__µ=19)

    def read(self, obj: Missing):
        match obj:
            case Result(__µ=value):
                return value

result = identity(µ=𝓶.µ + 𝓷)
"""

try:
    scope = {"__package__": pkg.__name__}
    exec(compile(source, "<nfkc labels>", "exec"), scope)
    assert scope["m"] is child and scope["nfkc_package"] is pkg
    assert scope["n"] == 13 and scope["result"] == 26
    cls = scope["Result"]
    assert cls.read.__annotations__ == {"obj": "Missing"}
    instance = cls()
    assert instance.make() == {"__μ": 19}
    setattr(instance, "__μ", 21)
    assert instance.read(instance) == 21
finally:
    del sys.modules[child.__name__]
    del sys.modules[pkg.__name__]

print("NFKC labels OK")
