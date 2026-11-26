import ast
import unicodedata


source = """\
µ = 3
𝔘𝔫𝔦𝔠𝔬𝔡𝔢 = μ

def outer():
    á = 5
    def inner():
        nonlocal á
        á += 2
        return á
    return inner

def set_global():
    global µ
    μ = 9

class K:
    def store(self, __µ):
        self.__μ = __µ

    def load(self):
        return self.__µ
"""

scope = {}
exec(compile(source, "<nfkc names>", "exec"), scope)
assert scope["μ"] == scope["Unicode"] == 3
inner = scope["outer"]()
assert inner() == 7 and inner() == 9
assert inner.__code__.co_freevars == ("á",)
scope["set_global"]()
assert scope["μ"] == 9
assert "µ" not in scope and "𝔘𝔫𝔦𝔠𝔬𝔡𝔢" not in scope

klass = scope["K"]
obj = klass()
obj.store(23)
assert obj.load() == 23 and vars(obj) == {"_K__μ": 23}
assert klass.__name__ == "K"
tree = ast.parse(source)
klass_node = tree.body[-1]
assert klass_node.name == "K"
assert klass_node.body[0].args.args[1].arg == "__μ"
assert klass_node.body[0].body[0].targets[0].attr == "__μ"

try:
    compile("def f(µ, μ): pass", "<nfkc duplicate>", "exec")
except SyntaxError as exc:
    assert exc.msg == "duplicate argument 'μ' in function definition", exc.msg
else:
    raise AssertionError("canonical duplicate parameter was accepted")

old = unicodedata.ucd_3_2_0
assert old.normalize("NFKC", "ᴬ") == "ᴬ"
scope = {}
exec("ᴬ = 12", scope)
assert scope["A"] == 12
assert old.normalize("NFKC", "ᴬ") == "ᴬ"

print("NFKC names OK")
