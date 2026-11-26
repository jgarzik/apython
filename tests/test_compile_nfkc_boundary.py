import ast


source = """\
𝔘𝔫𝔦𝔠𝔬𝔡𝔢 = 5
K = Unicode
result = f'{K=}'
ｉｆ = 7
ｍａｔｃｈ = 8
ｃａｓｅ = 9
ｔｙｐｅ = 10
"""

tree = ast.parse(source)
target = tree.body[0].targets[0]
assert target.id == "Unicode"
assert (target.lineno, target.col_offset, target.end_lineno, target.end_col_offset) == (1, 0, 1, 28)
target = tree.body[1].targets[0]
assert target.id == "K"
assert (target.lineno, target.col_offset, target.end_lineno, target.end_col_offset) == (2, 0, 2, 3)

code = compile(source, "<nfkc boundary>", "exec")
assert code.co_names == ("Unicode", "K", "result", "if", "match", "case", "type")
scope = {}
exec(code, scope)
assert scope["Unicode"] == scope["K"] == 5
assert scope["result"] == "K=5"
assert [scope[name] for name in ("if", "match", "case", "type")] == [7, 8, 9, 10]

tree = ast.parse("x=1")
tree.body[0].targets[0].id = "µ"
code = compile(tree, "<manual AST>", "exec")
assert code.co_names == ("µ",)
scope = {}
exec(code, scope)
assert scope["µ"] == 1 and "μ" not in scope

class Holder:
    pass


value = Holder()
setattr(value, "K", 12)
setattr(value, "K", 13)
assert getattr(value, "K") == 12 and value.K == 13
assert {"µ": 1, "μ": 2} == dict([("µ", 1), ("μ", 2)])

print("NFKC source boundary OK")
