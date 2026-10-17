# TLS end to end, in one process and with no network: a client and a server
# talking through two MemoryBIOs (what asyncio's sslproto does), then through
# a non-blocking socketpair (what an SSLSocket does).  Neither needs a thread.
# The certificates are tests/ssldata: a throwaway CA and a localhost server
# certificate it signed.

import os
import socket
import ssl

# Run from the .py this is tests/, run from the .pyc it is tests/__pycache__/.
HERE = os.path.dirname(os.path.abspath(__file__))
if os.path.basename(HERE) == "__pycache__":
    HERE = os.path.dirname(HERE)
DATA = os.path.join(HERE, "ssldata")
CA = os.path.join(DATA, "ca.pem")
SERVER = os.path.join(DATA, "server.pem")
SERVER_CERT = os.path.join(DATA, "server_cert.pem")
SERVER_KEY_ENC = os.path.join(DATA, "server_key_encrypted.pem")


def server_context(**kw):
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(SERVER)
    for k, v in kw.items():
        setattr(ctx, k, v)
    return ctx


def client_context(ca=True):
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    if ca:
        ctx.load_verify_locations(CA)
    return ctx


class Pair:
    """A client and a server SSLObject, wired back to back."""

    def __init__(self, cctx, sctx, hostname="localhost", session=None):
        self.c_in, self.c_out = ssl.MemoryBIO(), ssl.MemoryBIO()
        self.s_in, self.s_out = ssl.MemoryBIO(), ssl.MemoryBIO()
        self.client = cctx.wrap_bio(self.c_in, self.c_out,
                                    server_hostname=hostname, session=session)
        self.server = sctx.wrap_bio(self.s_in, self.s_out, server_side=True)

    def shuttle(self):
        moved = 0
        data = self.c_out.read()
        if data:
            self.s_in.write(data)
            moved += len(data)
        data = self.s_out.read()
        if data:
            self.c_in.write(data)
            moved += len(data)
        return moved

    def step(self, obj, fn):
        try:
            return True, fn()
        except ssl.SSLWantReadError:
            return False, None

    def handshake(self):
        cdone = sdone = False
        for _ in range(50):
            if not cdone:
                cdone, _r = self.step(self.client, self.client.do_handshake)
            if not sdone:
                sdone, _r = self.step(self.server, self.server.do_handshake)
            moved = self.shuttle()
            if cdone and sdone and not moved:
                return
        raise RuntimeError("handshake did not finish")

    def send(self, src, dst, payload):
        src.write(payload)
        self.shuttle()
        got = b""
        while len(got) < len(payload):
            try:
                got += dst.read(65536)
            except ssl.SSLWantReadError:
                if not self.shuttle():
                    break
        return got


def show_error(label, e):
    print(label, type(e).__name__, getattr(e, "library", None),
          getattr(e, "reason", None))


# --- the module surface ------------------------------------------------------

print("constants", ssl.PROTOCOL_TLS_CLIENT, ssl.CERT_REQUIRED,
      ssl.HAS_SNI, ssl.HAS_ALPN, ssl.HAS_TLSv1_3)
print("version", ssl.OPENSSL_VERSION_INFO[:2] >= (1, 1),
      ssl.OPENSSL_VERSION.startswith("OpenSSL"))
print("rand", len(ssl.RAND_bytes(32)), ssl.RAND_status())
print("txt2obj", ssl._ssl.txt2obj("1.3.6.1.5.5.7.3.1"))
print("nid2obj", ssl._ssl.nid2obj(13))
print("purpose", ssl.Purpose.SERVER_AUTH.oid)
print("mro", [c.__name__ for c in ssl.SSLCertVerificationError.__mro__])
print("str", str(ssl.SSLError(1, "boom")), str(ssl.SSLError("x")))

cert = ssl._ssl._test_decode_cert(SERVER_CERT)
print("decode subject", cert["subject"])
print("decode issuer", cert["issuer"])
print("decode rest", cert["version"], cert["serialNumber"],
      cert["notAfter"].endswith("GMT"), cert["subjectAltName"])

# --- contexts ----------------------------------------------------------------

c = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
print("client defaults", c.verify_mode, c.check_hostname,
      c.protocol, c.minimum_version, c.maximum_version)
s = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
print("server defaults", s.verify_mode, s.check_hostname)
try:
    c.verify_mode = ssl.CERT_NONE
except ValueError as e:
    print("verify_mode", e)
c.check_hostname = False
c.verify_mode = ssl.CERT_NONE
print("relaxed", c.verify_mode, c.check_hostname)
c.minimum_version = ssl.TLSVersion.TLSv1_2
print("min", c.minimum_version)
print("options", bool(c.options & ssl.OP_NO_COMPRESSION))
try:
    c.set_ciphers("NOT-A-CIPHER")
except ssl.SSLError as e:
    print("set_ciphers", e)
names = [d["name"] for d in s.get_ciphers()]
print("ciphers", "TLS_AES_256_GCM_SHA384" in names)

ctx = client_context()
print("store", ctx.cert_store_stats())
print("ca subject", ctx.get_ca_certs()[0]["subject"])
pem = open(CA).read()
der = ssl.PEM_cert_to_DER_cert(pem)
for label, data in (("pem", pem), ("der", der)):
    x = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    x.load_verify_locations(cadata=data)
    print("cadata", label, x.cert_store_stats())
try:
    ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT).load_verify_locations(
        cadata="no certificate here")
except ssl.SSLError as e:
    show_error("cadata garbage", e)
try:
    ctx.load_cert_chain(os.path.join(DATA, "missing.pem"))
except OSError as e:
    print("missing", type(e).__name__, e.errno)

srv = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
for pw in ("somepass", b"somepass", lambda: "somepass"):
    srv.load_cert_chain(SERVER_CERT, SERVER_KEY_ENC, password=pw)
print("password ok")
try:
    srv.load_cert_chain(SERVER_CERT, SERVER_KEY_ENC, password="wrong")
except ssl.SSLError as e:
    show_error("password wrong", e)
try:
    srv.load_cert_chain(SERVER_CERT, SERVER_KEY_ENC, password=lambda: 3)
except TypeError as e:
    print("password type", e)

# --- MemoryBIO ---------------------------------------------------------------

bio = ssl.MemoryBIO()
print("bio", bio.pending, bio.eof, bio.write(b"hello"), bio.pending)
print("bio read", bio.read(2), bio.read(), bio.read())
bio.write_eof()
print("bio eof", bio.eof)
try:
    bio.write(b"x")
except ssl.SSLError as e:
    print("bio after eof", type(e).__name__)
try:
    bio.write("text")
except TypeError:
    print("bio str refused")

# --- a full handshake over MemoryBIOs ----------------------------------------

sctx = server_context()
sctx.set_alpn_protocols(["h2", "http/1.1"])
cctx = client_context()
cctx.set_alpn_protocols(["http/1.1"])
p = Pair(cctx, sctx)
p.handshake()
print("version", p.client.version(), p.server.version())
print("cipher", p.client.cipher()[1], p.client.cipher() == p.server.cipher())
print("alpn", p.client.selected_alpn_protocol(),
      p.server.selected_alpn_protocol())
peer = p.client.getpeercert()
print("peer", peer["subject"][-1], peer["subjectAltName"])
print("peer der", p.client.getpeercert(True) == ssl.PEM_cert_to_DER_cert(
    open(SERVER_CERT).read()))
print("server sees", p.server.getpeercert())
print("hostname", p.client.server_hostname, p.server.server_hostname,
      p.client.server_side, p.server.server_side)
cb = p.client.get_channel_binding()
print("binding", len(cb), cb == p.server.get_channel_binding())
print("shared", p.server.shared_ciphers() is not None)
print("echo", p.send(p.client, p.server, b"ping" * 1000) == b"ping" * 1000,
      p.send(p.server, p.client, b"pong") == b"pong")
buf = bytearray(10)
p.client.write(b"0123456789")
p.shuttle()
print("read into", p.server.read(10, buf), bytes(buf))
try:
    p.client.unwrap()
except ssl.SSLWantReadError:
    pass
p.shuttle()
try:
    p.server.unwrap()
except ssl.SSLWantReadError:
    pass
p.shuttle()
print("shutdown", p.c_out.pending, p.s_out.pending)

# --- verification failures ---------------------------------------------------

p = Pair(client_context(), server_context(), hostname="wronghost")
try:
    p.handshake()
except ssl.SSLCertVerificationError as e:
    show_error("mismatch", e)
    print("mismatch detail", e.verify_code, e.verify_message)
    print("mismatch text", str(e).split(" (_ssl.c")[0])

p = Pair(client_context(ca=False), server_context())
try:
    p.handshake()
except ssl.SSLCertVerificationError as e:
    show_error("unknown ca", e)
    print("unknown ca detail", e.verify_code, e.verify_message)

try:
    client_context().wrap_bio(ssl.MemoryBIO(), ssl.MemoryBIO(),
                              server_side=True)
except ssl.SSLError as e:
    print("wrong side", str(e).split(" (_ssl.c")[0])

# --- SNI ----------------------------------------------------------------------

seen = []
sctx = server_context()
sctx.sni_callback = lambda obj, name, ctx: seen.append(name)
p = Pair(client_context(), sctx)
p.handshake()
print("sni", seen)

sctx = server_context()
sctx.sni_callback = lambda obj, name, ctx: ssl.ALERT_DESCRIPTION_ACCESS_DENIED
p = Pair(client_context(), sctx)
try:
    p.handshake()
except ssl.SSLError as e:
    show_error("sni refused", e)

# --- session reuse, over TLS 1.2 so the session exists after the handshake ---

sctx = server_context()
cctx = client_context()
cctx.maximum_version = ssl.TLSVersion.TLSv1_2
p = Pair(cctx, sctx)
p.handshake()
sess = p.client.session
print("session", p.client.session_reused, len(sess.id) > 0, sess.has_ticket,
      sess.timeout > 0)
p2 = Pair(cctx, sctx, session=sess)
p2.handshake()
print("resumed", p2.client.session_reused, p2.client.session == sess)

# --- the same over a non-blocking socketpair -----------------------------------

a, b = socket.socketpair()
a.setblocking(False)
b.setblocking(False)
cs = client_context().wrap_socket(a, server_hostname="localhost",
                                  do_handshake_on_connect=False)
ss = server_context().wrap_socket(b, server_side=True,
                                  do_handshake_on_connect=False)
done = [False, False]
for _ in range(100):
    for i, sk in enumerate((cs, ss)):
        if not done[i]:
            try:
                sk.do_handshake()
                done[i] = True
            except (ssl.SSLWantReadError, ssl.SSLWantWriteError):
                pass
    if all(done):
        break
print("socket handshake", done, cs.version())
cs.sendall(b"over a socket")
got = b""
for _ in range(100):
    try:
        got += ss.recv(100)
        break
    except ssl.SSLWantReadError:
        pass
print("socket echo", got)
cs.close()
ss.close()

# --- a timeout honoured: nobody answers, so the handshake gives up ------------

a, b = socket.socketpair()
a.settimeout(0.2)
cs = client_context().wrap_socket(a, server_hostname="localhost",
                                  do_handshake_on_connect=False)
try:
    cs.do_handshake()
except TimeoutError as e:
    print("timeout", e)
cs.close()
b.close()
