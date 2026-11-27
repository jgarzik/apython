"""_socket - the sockets module, assembled from its two halves.

CPython implements all of _socket in C.  Here the syscalls are assembly, in
the builtin module _socketcore, and everything above them is this file, which
presents itself to the stdlib as `_socket`: CPython's own Lib/socket.py
imports it unchanged and subclasses the socket type below.

The line between the halves is the sockaddr.  _socketcore takes and returns
the raw bytes the kernel wants and knows nothing about what is in them; the
packing and parsing for AF_INET and AF_UNIX are here, where a family is a few
lines rather than a new struct.

What is deliberately missing: IPv6, sendmsg/recvmsg and share -- Lib/socket.py
guards each of the last three with hasattr and does without -- and a real
resolver.  getaddrinfo answers for dotted quads, for the names in /etc/hosts,
and for nothing else.
"""

import _socketcore as _c

# The constants are the platform's, and the platform is Linux; _socketcore
# carries them because that is where the ABI is known.
for _name in dir(_c):
    if _name.isupper():
        globals()[_name] = getattr(_c, _name)
del _name

error = OSError
timeout = TimeoutError


class gaierror(OSError):
    """Address-related error from getaddrinfo()."""


class herror(OSError):
    """Address-related error from the (absent) name resolver."""


has_ipv6 = False

_GLOBAL_DEFAULT_TIMEOUT = None


def getdefaulttimeout():
    return _GLOBAL_DEFAULT_TIMEOUT


def setdefaulttimeout(t):
    global _GLOBAL_DEFAULT_TIMEOUT
    if t is not None:
        t = float(t)
        if t < 0:
            raise ValueError("Timeout value out of range")
    _GLOBAL_DEFAULT_TIMEOUT = t


def gethostname():
    return _c.gethostname()


def dup(fd):
    return _c.dup(fd)


def close(fd):
    _c.close(fd)


# ---------------------------------------------------------------- byte order

def htons(x):
    x = int(x) & 0xFFFF
    return ((x & 0xFF) << 8) | (x >> 8)


def htonl(x):
    x = int(x) & 0xFFFFFFFF
    return (((x & 0xFF) << 24) | ((x & 0xFF00) << 8) |
            ((x >> 8) & 0xFF00) | (x >> 24))


ntohs = htons
ntohl = htonl


# ------------------------------------------------------------------ addresses

def _aton_part(text):
    """One field of an inet_aton address: decimal, octal or hex, as C does."""
    if not text:
        raise OSError("illegal IP address string passed to inet_aton")
    try:
        if text[:2].lower() == "0x":
            return int(text[2:], 16)
        if text[0] == "0" and len(text) > 1:
            return int(text[1:], 8)
        return int(text, 10)
    except ValueError:
        raise OSError("illegal IP address string passed to inet_aton")


def inet_aton(ip):
    """A dotted address as the four bytes the kernel stores.

    Not only the quad: inet_aton's short forms are part of its contract, and
    the last field takes over what the missing ones would have held -- "1.2.3"
    is 1.2.0.3 and "127.1" is 127.0.0.1.  argparse and half the network tools
    in the stdlib inherit that from it.
    """
    if isinstance(ip, bytes):
        ip = ip.decode("ascii")
    parts = ip.split(".")
    if len(parts) > 4:
        raise OSError("illegal IP address string passed to inet_aton")
    values = [_aton_part(p) for p in parts]
    last = values.pop()
    if last < 0 or last >= 1 << (8 * (4 - len(values))):
        raise OSError("illegal IP address string passed to inet_aton")
    out = []
    for v in values:
        if v > 255 or v < 0:
            raise OSError("illegal IP address string passed to inet_aton")
        out.append(v)
    while len(out) < 4:
        shift = 8 * (3 - len(out))
        out.append((last >> shift) & 0xFF)
    return bytes(out)


def inet_ntoa(packed):
    if len(packed) != 4:
        raise OSError("packed IP wrong length for inet_ntoa")
    return "%d.%d.%d.%d" % (packed[0], packed[1], packed[2], packed[3])


def inet_pton(family, ip):
    if family != AF_INET:
        raise OSError("unsupported address family")
    return inet_aton(ip)


def inet_ntop(family, packed):
    if family != AF_INET:
        raise OSError("unsupported address family")
    return inet_ntoa(packed)


def _is_dotted_quad(host):
    parts = host.split(".")
    if len(parts) != 4:
        return False
    for p in parts:
        if not p or not p.isdigit() or int(p) > 255:
            return False
    return True


_hosts_cache = None


def _hosts():
    """/etc/hosts, as a name -> address mapping.  This is the whole resolver."""
    global _hosts_cache
    if _hosts_cache is None:
        table = {}
        try:
            with open("/etc/hosts") as f:
                for line in f:
                    line = line.split("#")[0].split()
                    if len(line) < 2 or not _is_dotted_quad(line[0]):
                        continue
                    for name in line[1:]:
                        table.setdefault(name, line[0])
        except OSError:
            pass
        table.setdefault("localhost", "127.0.0.1")
        _hosts_cache = table
    return _hosts_cache


def gethostbyname(host):
    return _resolve(host)


def gethostbyaddr(ip):
    name = None
    for k, v in _hosts().items():
        if v == ip:
            name = k
            break
    if name is None:
        raise herror(1, "Unknown host")
    return (name, [], [ip])


def _resolve(host):
    """A host as a dotted quad, for the few names that can be answered."""
    if host is None or host == "":
        return "0.0.0.0"
    if host == "<broadcast>":
        return "255.255.255.255"
    if _is_dotted_quad(host):
        return host
    addr = _hosts().get(host)
    if addr is None:
        raise gaierror(EAI_NONAME, "Name or service not known")
    return addr


_SERVICES = {
    "echo": 7, "ftp-data": 20, "ftp": 21, "ssh": 22, "telnet": 23,
    "smtp": 25, "domain": 53, "http": 80, "www": 80, "pop3": 110,
    "sunrpc": 111, "nntp": 119, "ntp": 123, "imap2": 143, "snmp": 161,
    "https": 443, "submission": 587, "imaps": 993, "pop3s": 995,
}


def getservbyname(name, proto=None):
    port = _SERVICES.get(name)
    if port is None:
        raise OSError("service/proto not found")
    return port


def getservbyport(port, proto=None):
    for k, v in _SERVICES.items():
        if v == port:
            return k
    raise OSError("port/proto not found")


def getprotobyname(name):
    table = {"ip": 0, "icmp": 1, "igmp": 2, "tcp": 6, "udp": 17, "raw": 255}
    proto = table.get(name)
    if proto is None:
        raise OSError("protocol not found")
    return proto


def _port_number(port):
    if port is None:
        return 0
    if isinstance(port, bytes):
        port = port.decode("ascii")
    if isinstance(port, str):
        if port.isdigit():
            return int(port)
        return getservbyname(port)
    return int(port)


def getaddrinfo(host, port, family=0, type=0, proto=0, flags=0):
    """Numeric only, plus whatever /etc/hosts answers for."""
    if family not in (0, AF_INET):
        raise gaierror(EAI_FAMILY, "Address family for hostname not supported")
    if host is None:
        ip = "0.0.0.0" if flags & AI_PASSIVE else "127.0.0.1"
    else:
        if isinstance(host, bytes):
            host = host.decode("ascii")
        ip = _resolve(host)
    p = _port_number(port)
    kinds = [type] if type else [SOCK_STREAM, SOCK_DGRAM]
    out = []
    for k in kinds:
        pr = proto
        if not pr:
            pr = IPPROTO_TCP if k == SOCK_STREAM else IPPROTO_UDP
        out.append((AF_INET, k, pr, "", (ip, p)))
    return out


def getnameinfo(sockaddr, flags):
    host, port = sockaddr[0], sockaddr[1]
    return (host, str(port))


def _pack_addr(family, address):
    if family == AF_INET:
        host, port = address[0], address[1]
        port = _port_number(port)
        if port < 0 or port > 0xFFFF:
            raise OverflowError("getsockaddrarg: port must be 0-65535.")
        head = bytes([AF_INET & 0xFF, (AF_INET >> 8) & 0xFF,
                      (port >> 8) & 0xFF, port & 0xFF])
        return head + inet_aton(_resolve(host)) + bytes(8)
    if family == AF_UNIX:
        if isinstance(address, str):
            path = address.encode("utf-8")
        else:
            path = bytes(address)
        # A filesystem path is NUL-terminated; an ABSTRACT name -- one that
        # begins with a NUL -- is not, and its length is what delimits it, so
        # a terminator there would make it a different name.
        if path[:1] != b"\x00":
            path = path + bytes(1)
        return bytes([AF_UNIX & 0xFF, 0]) + path
    raise OSError("unsupported address family %r" % (family,))


def _unpack_addr(raw):
    if len(raw) < 2:
        return ""
    family = raw[0] | (raw[1] << 8)
    if family == AF_INET:
        port = (raw[2] << 8) | raw[3]
        return (inet_ntoa(raw[4:8]), port)
    if family == AF_UNIX:
        path = raw[2:]
        if path[:1] == b"\x00":
            return bytes(path)
        i = 0
        while i < len(path) and path[i] != 0:
            i += 1
        return path[:i].decode("utf-8")
    return bytes(raw)


# -------------------------------------------------------------------- socket

class socket:
    """The socket object CPython implements in C.

    A descriptor, the three numbers it was made with, and a timeout.  The
    timeout is not a socket option: like CPython's, it is a non-blocking
    descriptor plus a poll() before each operation that would have waited.
    """

    def __init__(self, family=AF_INET, type=SOCK_STREAM, proto=0, fileno=None):
        nonblock = bool(type & SOCK_NONBLOCK)
        if fileno is None:
            # SOCK_CLOEXEC, as CPython does: a descriptor Python opens is
            # non-inheritable by default (PEP 446), so it does not survive
            # into a child process.  The bit is not part of .type.
            self._fd = _c.socket(family, type | SOCK_CLOEXEC, proto)
        else:
            self._fd = int(fileno)
        self._family = family
        self._type = type & ~(SOCK_NONBLOCK | SOCK_CLOEXEC)
        self._proto = proto
        self._timeout = 0.0 if nonblock else None
        if not nonblock and _GLOBAL_DEFAULT_TIMEOUT is not None:
            self.settimeout(_GLOBAL_DEFAULT_TIMEOUT)

    # --- identity

    def fileno(self):
        return self._fd

    def detach(self):
        fd = self._fd
        self._fd = -1
        return fd

    def close(self):
        fd = self._fd
        self._fd = -1
        if fd != -1:
            _c.close(fd)

    def __del__(self):
        if getattr(self, "_fd", -1) != -1:
            self.close()

    def __repr__(self):
        return ("<socket object, fd=%d, family=%d, type=%d, proto=%d>"
                % (self._fd, self._family, self._type, self._proto))

    @property
    def family(self):
        return self._family

    @property
    def type(self):
        return self._type

    @property
    def proto(self):
        return self._proto

    @property
    def timeout(self):
        return self._timeout

    def _check(self):
        if self._fd == -1:
            raise OSError(EBADF, "Bad file descriptor")
        return self._fd

    # --- blocking mode

    def gettimeout(self):
        return self._timeout

    def getblocking(self):
        # Blocking is "not zero", not "no timeout": a socket with a timeout
        # blocks, it just gives up eventually.  CPython documents this as
        # equivalent to gettimeout() != 0.
        return self._timeout != 0

    def setblocking(self, flag):
        self.settimeout(None if flag else 0.0)

    def settimeout(self, value):
        if value is None:
            self._timeout = None
            _c.set_blocking(self._check(), True)
            return
        value = float(value)
        if value < 0:
            raise ValueError("Timeout value out of range")
        self._timeout = value
        _c.set_blocking(self._check(), False)

    def _wait(self, writing):
        """Wait out one timeout, or raise it."""
        if self._timeout is None or self._timeout == 0:
            return False
        events = POLLOUT if writing else POLLIN
        ms = int(self._timeout * 1000)
        if ms <= 0:
            ms = 1
        got = _c.poll([self._fd, events], ms)
        if not got or got[0] == 0:
            raise timeout("timed out")
        return True

    def _io(self, writing, fn, *args):
        while True:
            try:
                return fn(self._check(), *args)
            except BlockingIOError:
                if not self._wait(writing):
                    raise

    # --- setup

    def bind(self, address):
        _c.bind(self._check(), _pack_addr(self._family, address))

    def listen(self, backlog=None):
        if backlog is None:
            backlog = SOMAXCONN
        _c.listen(self._check(), backlog)

    def connect(self, address):
        raw = _pack_addr(self._family, address)
        try:
            _c.connect(self._check(), raw)
        except BlockingIOError:
            # A non-blocking connect reports EINPROGRESS and finishes later.
            if self._timeout is None or self._timeout == 0:
                raise
            self._wait(True)
            err = self._error()
            if err:
                raise OSError(err, _strerror(err))
        return None

    def connect_ex(self, address):
        return _c.connect_ex(self._check(), _pack_addr(self._family, address))

    def _error(self):
        raw = _c.getsockopt(self._check(), SOL_SOCKET, SO_ERROR, 4)
        return raw[0] | (raw[1] << 8) | (raw[2] << 16) | (raw[3] << 24)

    def _accept(self):
        fd, raw = self._io(False, _c.accept)
        return fd, _unpack_addr(raw)

    def shutdown(self, how):
        _c.shutdown(self._check(), how)

    def dup(self):
        return socket(self._family, self._type, self._proto,
                      fileno=_c.dup(self._check()))

    # --- names and options

    def getsockname(self):
        return _unpack_addr(_c.getsockname(self._check()))

    def getpeername(self):
        return _unpack_addr(_c.getpeername(self._check()))

    def setsockopt(self, level, optname, value, optlen=None):
        if optlen is not None:
            # setsockopt(level, optname, None, optlen) -- the zero-filled form
            value = bytes(optlen)
        elif isinstance(value, int):
            value = bytes([value & 0xFF, (value >> 8) & 0xFF,
                           (value >> 16) & 0xFF, (value >> 24) & 0xFF])
        _c.setsockopt(self._check(), level, optname, value)

    def getsockopt(self, level, optname, buflen=None):
        if buflen is None:
            raw = _c.getsockopt(self._check(), level, optname, 4)
            return (raw[0] | (raw[1] << 8) | (raw[2] << 16) | (raw[3] << 24))
        return _c.getsockopt(self._check(), level, optname, buflen)

    # --- transfer

    def send(self, data, flags=0):
        return self._io(True, _c.send, data, flags)

    def sendall(self, data, flags=0):
        view = memoryview(data)
        while len(view):
            n = self.send(view, flags)
            view = view[n:]
        return None

    def sendto(self, data, flags_or_addr, address=None):
        if address is None:
            flags, address = 0, flags_or_addr
        else:
            flags = flags_or_addr
        raw = _pack_addr(self._family, address)
        return self._io(True, _c.send, data, flags, raw)

    def sendmsg(self, buffers, ancdata=(), flags=0, address=None):
        bufs = list(buffers)
        control = None
        if ancdata:
            parts = []
            for cmsg_level, cmsg_type, cmsg_data in ancdata:
                data = bytes(cmsg_data)
                cmsg_len = CMSG_LEN(len(data))
                pad = CMSG_SPACE(len(data)) - cmsg_len
                hdr = (cmsg_len.to_bytes(8, "little")
                       + int(cmsg_level).to_bytes(4, "little", signed=True)
                       + int(cmsg_type).to_bytes(4, "little", signed=True))
                parts.append(hdr + data + bytes(pad))
            control = b"".join(parts)
        raw_addr = None if address is None else _pack_addr(self._family, address)
        return self._io(True, _c.sendmsg, bufs, control, flags, raw_addr)

    def recv(self, bufsize, flags=0):
        return self._io(False, _c.recv, bufsize, flags)

    def recv_into(self, buffer, nbytes=0, flags=0):
        return self._io(False, _c.recv_into, buffer, nbytes, flags)

    def recvfrom(self, bufsize, flags=0):
        data, raw = self._io(False, _c.recvfrom, bufsize, flags)
        return data, _unpack_addr(raw)

    def recvfrom_into(self, buffer, nbytes=0, flags=0):
        data, addr = self.recvfrom(nbytes or len(buffer), flags)
        buffer[:len(data)] = data
        return len(data), addr


SocketType = socket


def socketpair(family=AF_UNIX, type=SOCK_STREAM, proto=0):
    a, b = _c.socketpair(family, type, proto)
    return (socket(family, type, proto, fileno=a),
            socket(family, type, proto, fileno=b))


try:
    from errno import EBADF, EAGAIN
except ImportError:
    EBADF, EAGAIN = 9, 11


def _strerror(err):
    try:
        import os
        return os.strerror(err)
    except Exception:
        return "error %d" % err


def CMSG_LEN(length):
    length = int(length)
    if length < 0:
        raise OverflowError("CMSG_LEN() argument out of range")
    return 16 + length


def CMSG_SPACE(length):
    length = int(length)
    if length < 0:
        raise OverflowError("CMSG_SPACE() argument out of range")
    return 16 + ((length + 7) & ~7)


__all__ = ["socket", "socketpair", "SocketType", "error", "timeout",
           "gaierror", "herror", "has_ipv6", "getdefaulttimeout",
           "setdefaulttimeout", "gethostname", "gethostbyname",
           "gethostbyaddr", "getaddrinfo", "getnameinfo", "getservbyname",
           "getservbyport", "getprotobyname", "dup", "close",
           "inet_aton", "inet_ntoa", "inet_pton", "inet_ntop",
           "htons", "htonl", "ntohs", "ntohl",
           "CMSG_LEN", "CMSG_SPACE"]
__all__.extend([_n for _n in dir(_c) if _n.isupper()])
