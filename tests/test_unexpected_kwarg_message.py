# A Python function refusing a keyword names itself and the keyword, as
# CPython does: "h() got an unexpected keyword argument 'nosuch'".  The bare
# "got an unexpected keyword argument" said neither.


def h(a, b=1):
    pass


def star(*a, x=1):
    pass


def kwonly(*, x):
    pass


class C:
    def m(self, a):
        pass

    @staticmethod
    def s(a):
        pass


def nested():
    def inner(a):
        pass
    return inner


for call in (
    lambda: h(1, nosuch=2),
    lambda: h(**{"a": 1, "zz": 2}),
    lambda: star(nosuch=1),
    lambda: kwonly(x=1, y=2),
    lambda: C().m(1, q=1),
    lambda: C.s(1, q=1),
    lambda: nested()(1, q=1),
    lambda: (lambda a: a)(1, q=1),
    lambda: h(1, b=2, **{"nosuch": 3}),
):
    try:
        call()
    except TypeError as e:
        print(e)
