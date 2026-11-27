# The eight posix calls the module was short of: chdir, truncate, link, chown,
# utime, dup2, fsync and fchmod.  The old bug list listed ftruncate among them, but
# ftruncate was already here; it is `truncate`, the path-taking form that
# shutil and tempfile reach for, that was missing.
#
# This test uses posix directly rather than os: os is CPython's own os.py and
# only imports when a stdlib checkout is on the path.
import posix
def t(l,f):
    try: print(l,"=>",repr(f()))
    except BaseException as e: print(l,"!!",type(e).__name__,e)
t("names", lambda: [n for n in ('chdir','truncate','ftruncate','link','chown','utime','dup2','fsync','fchmod') if hasattr(posix,n)])
D = "/tmp/apy_posix_test"
# Start from a clean directory: the test creates a hard link and truncates a
# file, so anything left behind by a previous run changes the answers.
for _leftover in ("/f1", "/f2"):
    try:
        posix.unlink(D + _leftover)
    except OSError:
        pass
try:
    posix.rmdir(D)
except OSError:
    pass
posix.mkdir(D)
P = D + "/f1"
fd = posix.open(P, 0o1 | 0o100 | 0o1000, 0o644)   # O_WRONLY|O_CREAT|O_TRUNC
posix.write(fd, b"hello world")
posix.close(fd)
def rd(p):
    f = posix.open(p, 0)
    b = posix.read(f, 100)
    posix.close(f)
    return b
t("truncate", lambda: (posix.truncate(P, 5), rd(P)))
t("truncate missing", lambda: posix.truncate(D + "/nope", 5))
t("link", lambda: (posix.link(P, D+"/f2"), rd(D+"/f2")))
t("link exists", lambda: posix.link(P, D+"/f2"))
fd = posix.open(P, 0o2)
t("fsync", lambda: posix.fsync(fd))
t("ftruncate", lambda: (posix.ftruncate(fd, 2), rd(P)))
t("fchmod", lambda: (posix.fchmod(fd, 0o600), oct(posix.stat(P).st_mode & 0o777)))
t("dup2", lambda: (lambda n: (n, posix.close(n)))(posix.dup2(fd, 77)))
posix.close(fd)
t("chown same", lambda: posix.chown(P, -1, -1))
t("chown bad", lambda: posix.chown(D+"/nope", 0, 0))
t("utime now", lambda: posix.utime(P))
t("utime pair", lambda: (posix.utime(P, (1000000, 2000000)), int(posix.stat(P).st_mtime)))
t("utime bad", lambda: posix.utime(P, 5))
t("utime missing", lambda: posix.utime(D+"/nope"))
t("fsync bad", lambda: posix.fsync(9999))
t("fchmod bad", lambda: posix.fchmod(9999, 0o600))
t("dup2 bad", lambda: posix.dup2(9999, 78))
cwd = posix.getcwd()
t("chdir", lambda: (posix.chdir("/tmp"), posix.getcwd()))
posix.chdir(cwd)
t("chdir missing", lambda: posix.chdir("/no/such/dir/xyz"))
t("chdir arity", lambda: posix.chdir())
t("truncate arity", lambda: posix.truncate(P))
t("link arity", lambda: posix.link(P))
t("chown arity", lambda: posix.chown(P, 0))
posix.unlink(P); posix.unlink(D+"/f2"); posix.rmdir(D)
