# A replacement field whose intermediate object is a TEMPORARY: the property
# below builds a new list on every read, so nothing but the format machinery
# holds it.  Releasing it while the next object in the chain sat in a
# caller-saved register handed back whatever the deallocator left there.


class A:
    @property
    def b(self):
        return [1, 2, 3]

    @property
    def c(self):
        return A()


class M:
    def __getitem__(self, k):
        return A()


for i in range(5):
    print('{0.b}|{0.b[1]}|{0.c.b[2]}|{0.c.c.b}'.format(A()))
    print('{x.b}|{x.b[1]}|{x.c.b[2]}'.format(x=A()))
    print('{a.b}|{a.b[1]}|{a.c.b[2]}'.format_map({'a': A()}))
    print('{a.b}|{a.b[1]}|{a.c.b[2]}'.format_map(M()))

for bad in ['{a.zz}', '{q}', '{a[0]}']:
    try:
        print(bad.format_map({'a': A()}))
    except Exception as e:
        print(type(e).__name__)
for bad in ['{0.zz}', '{1}', '{q}', '{0[0]}', '{', '}']:
    try:
        print(bad.format(A()))
    except Exception as e:
        print(type(e).__name__)
