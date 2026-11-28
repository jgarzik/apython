# sqlite3, over _sqlite3core (-lsqlite3) and lib/_sqlite3.py.
# Diffed against CPython 3.12 by make check and make check-source.
import datetime
import sqlite3
import threading


def show(label, fn):
    try:
        print(label, "->", fn())
    except BaseException as e:
        print(label, "->", type(e).__name__ + ":", e)


# --- basic DDL/DML, parameter binding, types, Row -------------------------
con = sqlite3.connect(":memory:")
print("threadsafety :", sqlite3.threadsafety)
print("complete T/F :", sqlite3.complete_statement("SELECT 1;"),
      sqlite3.complete_statement("SELECT 1"))

cur = con.cursor()
cur.execute("CREATE TABLE items(id INTEGER PRIMARY KEY, name TEXT, val REAL, raw BLOB)")
cur.execute("INSERT INTO items(name, val, raw) VALUES (?, ?, ?)", ("alpha", 1.5, b"\x00\x01"))
cur.executemany(
    "INSERT INTO items(name, val, raw) VALUES (:name, :val, :raw)",
    [{"name": "beta", "val": 2.25, "raw": bytearray(b"xy")},
     {"name": "gamma", "val": None, "raw": memoryview(b"z")}],
)
con.commit()

cur.execute("SELECT id, name, val, raw FROM items ORDER BY id")
print("desc names   :", [d[0] for d in cur.description])
print("rows         :", cur.fetchall())

con.row_factory = sqlite3.Row
r = con.execute("SELECT id, name FROM items WHERE id = 1").fetchone()
print("row access   :", r[0], r["NAME"], r["name"], r.keys(), len(r), list(r))
con.row_factory = None

# --- transactions & autocommit --------------------------------------------
c2 = sqlite3.connect(":memory:", autocommit=False)
print("ac false in_tx:", c2.in_transaction, c2.autocommit)
c2.execute("CREATE TABLE t(x)")
c2.commit()
c2.execute("INSERT INTO t VALUES (1)")
c2.rollback()
print("after rollback:", c2.execute("SELECT * FROM t").fetchall())
c2.execute("INSERT INTO t VALUES (2)")
c2.commit()
c2.autocommit = True
print("ac true in_tx :", c2.in_transaction, c2.execute("SELECT * FROM t").fetchall())
c2.close()

# --- callbacks: scalar, aggregate, window, collation, hooks ---------------
con.create_function("triple", 1, lambda x: x * 3, deterministic=True)
print("udf          :", con.execute("SELECT triple(14)").fetchone())


class MySum:
    def __init__(self):
        self.total = 0

    def step(self, x):
        self.total += x

    def finalize(self):
        return self.total


con.create_aggregate("mysum", 1, MySum)
print("aggregate    :", con.execute("SELECT mysum(id) FROM items").fetchone())


class WinSum:
    def __init__(self):
        self.total = 0

    def step(self, x):
        self.total += x

    def value(self):
        return self.total

    def inverse(self, x):
        self.total -= x

    def finalize(self):
        return self.total


con.create_window_function("winsum", 1, WinSum)
print(
    "window       :",
    con.execute(
        "SELECT winsum(id) OVER (ORDER BY id ROWS BETWEEN 1 PRECEDING AND CURRENT ROW) "
        "FROM items"
    ).fetchall(),
)

con.create_collation("rev", lambda a, b: -((a > b) - (a < b)))
print("collation    :", con.execute("SELECT name FROM items ORDER BY name COLLATE rev").fetchall())

traced = []
con.set_trace_callback(lambda s: traced.append(s))
con.execute("SELECT 7").fetchall()
con.set_trace_callback(None)
print("traced       :", traced)

# Authorizer denies DROP TABLE
def deny_drop(action, a1, a2, db, src):
    if action == sqlite3.SQLITE_DROP_TABLE:
        return sqlite3.SQLITE_DENY
    return sqlite3.SQLITE_OK


con.set_authorizer(deny_drop)
show("auth deny    ", lambda: con.execute("DROP TABLE items"))
con.set_authorizer(None)

# --- incremental BLOB I/O -------------------------------------------------
con.execute("CREATE TABLE blobs(b BLOB)")
con.execute("INSERT INTO blobs VALUES (zeroblob(10))")
with con.blobopen("blobs", "b", 1) as blob:
    blob.write(b"0123456789")
    blob.seek(2)
    print("blob read    :", blob.tell(), blob.read(4), len(blob), blob[1], blob[1:8:2])
    blob[0] = ord("A")
    blob[6:10] = b"WXYZ"
print("blob final   :", con.execute("SELECT b FROM blobs").fetchone())
con.commit()

# --- backup & serialize/deserialize ---------------------------------------
dst = sqlite3.connect(":memory:")
steps = []
con.backup(dst, pages=1, progress=lambda rc, rem, tot: steps.append(rc))
print("backup rows  :", dst.execute("SELECT name FROM items ORDER BY id").fetchall(), len(steps) >= 1)
dst.close()

data = con.serialize()
con3 = sqlite3.connect(":memory:")
con3.deserialize(data)
print("deserialize  :", con3.execute("SELECT name FROM items ORDER BY id").fetchall())
con3.close()

# --- adapters, converters, iterdump ---------------------------------------
class Point:
    def __init__(self, x, y):
        self.x, self.y = x, y


sqlite3.register_adapter(Point, lambda p: f"{p.x};{p.y}".encode("ascii"))
sqlite3.register_converter("POINT", lambda b: tuple(map(int, b.split(b";"))))
tc = sqlite3.connect(":memory:", detect_types=sqlite3.PARSE_DECLTYPES | sqlite3.PARSE_COLNAMES)
tc.execute("CREATE TABLE pts(p POINT)")
tc.execute("INSERT INTO pts VALUES (?)", (Point(3, 4),))
print("decltype     :", tc.execute("SELECT p FROM pts").fetchone())
print("colname      :", tc.execute('SELECT "9;10" AS "q [point]"').fetchone())
dump_lines = list(tc.iterdump())
print("iterdump     :", dump_lines[0], dump_lines[-1], len(dump_lines))
tc.close()

# --- limits, config, errors, thread check ---------------------------------
orig_lim = con.getlimit(sqlite3.SQLITE_LIMIT_LENGTH)
print("limit > 0    :", orig_lim > 0)
fk = con.getconfig(sqlite3.SQLITE_DBCONFIG_ENABLE_FKEY)
con.setconfig(sqlite3.SQLITE_DBCONFIG_ENABLE_FKEY, not fk)
print("config toggle:", con.getconfig(sqlite3.SQLITE_DBCONFIG_ENABLE_FKEY) == (not fk))
con.setconfig(sqlite3.SQLITE_DBCONFIG_ENABLE_FKEY, fk)

try:
    con.execute("SELECT * FROM no_such_table")
except sqlite3.OperationalError as e:
    print("err attrs    :", e.sqlite_errorcode, e.sqlite_errorname)

thread_err = []
def wrong_thread():
    try:
        con.execute("SELECT 1")
    except sqlite3.ProgrammingError:
        thread_err.append("ProgrammingError")


t = threading.Thread(target=wrong_thread)
t.start()
t.join()
print("thread check :", thread_err)

con.close()
show("closed exec  ", lambda: con.execute("SELECT 1"))
