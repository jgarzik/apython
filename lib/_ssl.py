"""_ssl - TLS over OpenSSL, the module CPython's Lib/ssl.py is written against.

The public half of the `_sslcore`/`_ssl` split, the same one `_zlibcore`/
`zlib` and `_hashlibcore`/`_hashlib` use.  `src/modules/ssl.asm` is a table of
libssl and libcrypto calls behind a handle table -- every row there is one C
function, called with plain ints, strs and bytes -- and everything a program
sees is here: _SSLContext, _SSLSocket, MemoryBIO, SSLSession, the exception
hierarchy, the constants, the certificate decoder and every error message,
worded as _ssl.c words them because programs and tests match on them.

Three things are different in kind from CPython's C, and all three come from
OpenSSL never being allowed to call Python:

* A password callable for an encrypted key is called BEFORE the load, and its
  answer parked in the core, rather than from inside the PEM read.  It is
  called only when the key file says it is encrypted, so a callable that
  raises is still only raised when it is needed.
* An SNI callback runs between two halves of the handshake: the core's
  client-hello callback pauses SSL_do_handshake (SSL_ERROR_WANT_CLIENT_HELLO_CB)
  and _SSLSocket.do_handshake runs the callback, records its verdict on the
  connection and resumes.
* A peer certificate is decoded here, from its DER, by the small ASN.1 reader
  at the bottom of the file, into the same dict _decode_certificate builds.

The timeout semantics are CPython's: a socket with a timeout is a
non-blocking descriptor (lib/_socket.py makes it so), OpenSSL answers
WANT_READ or WANT_WRITE, and the wait is a poll() on the descriptor bounded
by what is left of the timeout.
"""

import _sslcore as _c
import _socketcore as _sc
import _weakref
import os as _os
import time as _time

# --- constants, as this OpenSSL defines them -------------------------------

_DEFAULT_CIPHERS = 'ALL:!COMPLEMENTOFDEFAULT:!eNULL'

ALERT_DESCRIPTION_ACCESS_DENIED = 49
ALERT_DESCRIPTION_BAD_CERTIFICATE = 42
ALERT_DESCRIPTION_BAD_CERTIFICATE_HASH_VALUE = 114
ALERT_DESCRIPTION_BAD_CERTIFICATE_STATUS_RESPONSE = 113
ALERT_DESCRIPTION_BAD_RECORD_MAC = 20
ALERT_DESCRIPTION_CERTIFICATE_EXPIRED = 45
ALERT_DESCRIPTION_CERTIFICATE_REVOKED = 44
ALERT_DESCRIPTION_CERTIFICATE_UNKNOWN = 46
ALERT_DESCRIPTION_CERTIFICATE_UNOBTAINABLE = 111
ALERT_DESCRIPTION_CLOSE_NOTIFY = 0
ALERT_DESCRIPTION_DECODE_ERROR = 50
ALERT_DESCRIPTION_DECOMPRESSION_FAILURE = 30
ALERT_DESCRIPTION_DECRYPT_ERROR = 51
ALERT_DESCRIPTION_HANDSHAKE_FAILURE = 40
ALERT_DESCRIPTION_ILLEGAL_PARAMETER = 47
ALERT_DESCRIPTION_INSUFFICIENT_SECURITY = 71
ALERT_DESCRIPTION_INTERNAL_ERROR = 80
ALERT_DESCRIPTION_NO_RENEGOTIATION = 100
ALERT_DESCRIPTION_PROTOCOL_VERSION = 70
ALERT_DESCRIPTION_RECORD_OVERFLOW = 22
ALERT_DESCRIPTION_UNEXPECTED_MESSAGE = 10
ALERT_DESCRIPTION_UNKNOWN_CA = 48
ALERT_DESCRIPTION_UNKNOWN_PSK_IDENTITY = 115
ALERT_DESCRIPTION_UNRECOGNIZED_NAME = 112
ALERT_DESCRIPTION_UNSUPPORTED_CERTIFICATE = 43
ALERT_DESCRIPTION_UNSUPPORTED_EXTENSION = 110
ALERT_DESCRIPTION_USER_CANCELLED = 90

CERT_NONE = 0
CERT_OPTIONAL = 1
CERT_REQUIRED = 2

ENCODING_PEM = 1
ENCODING_DER = 2

HAS_ALPN = True
HAS_ECDH = True
HAS_NPN = False
HAS_SNI = True
HAS_SSLv2 = False
HAS_SSLv3 = False
HAS_TLS_UNIQUE = True
HAS_TLSv1 = True
HAS_TLSv1_1 = True
HAS_TLSv1_2 = True
HAS_TLSv1_3 = True

HOSTFLAG_ALWAYS_CHECK_SUBJECT = 1
HOSTFLAG_NO_WILDCARDS = 2
HOSTFLAG_NO_PARTIAL_WILDCARDS = 4
HOSTFLAG_MULTI_LABEL_WILDCARDS = 8
HOSTFLAG_SINGLE_LABEL_SUBDOMAINS = 16
HOSTFLAG_NEVER_CHECK_SUBJECT = 32

OP_ALL = 0x80000050
OP_CIPHER_SERVER_PREFERENCE = 0x400000
OP_ENABLE_KTLS = 0x8
OP_ENABLE_MIDDLEBOX_COMPAT = 0x100000
OP_IGNORE_UNEXPECTED_EOF = 0x80
OP_LEGACY_SERVER_CONNECT = 0x4
OP_NO_COMPRESSION = 0x20000
OP_NO_RENEGOTIATION = 0x40000000
OP_NO_SSLv2 = 0
OP_NO_SSLv3 = 0x2000000
OP_NO_TICKET = 0x4000
OP_NO_TLSv1 = 0x4000000
OP_NO_TLSv1_1 = 0x10000000
OP_NO_TLSv1_2 = 0x8000000
OP_NO_TLSv1_3 = 0x20000000
OP_SINGLE_DH_USE = 0
OP_SINGLE_ECDH_USE = 0

PROTOCOL_SSLv23 = 2
PROTOCOL_TLS = 2
PROTOCOL_TLS_CLIENT = 16
PROTOCOL_TLS_SERVER = 17
PROTOCOL_TLSv1 = 3
PROTOCOL_TLSv1_1 = 4
PROTOCOL_TLSv1_2 = 5

PROTO_MAXIMUM_SUPPORTED = -1
PROTO_MINIMUM_SUPPORTED = -2
PROTO_SSLv3 = 0x300
PROTO_TLSv1 = 0x301
PROTO_TLSv1_1 = 0x302
PROTO_TLSv1_2 = 0x303
PROTO_TLSv1_3 = 0x304

SSL_ERROR_SSL = 1
SSL_ERROR_WANT_READ = 2
SSL_ERROR_WANT_WRITE = 3
SSL_ERROR_WANT_X509_LOOKUP = 4
SSL_ERROR_SYSCALL = 5
SSL_ERROR_ZERO_RETURN = 6
SSL_ERROR_WANT_CONNECT = 7
SSL_ERROR_EOF = 8
SSL_ERROR_INVALID_ERROR_CODE = 10

VERIFY_DEFAULT = 0
VERIFY_CRL_CHECK_LEAF = 0x4
VERIFY_CRL_CHECK_CHAIN = 0xc
VERIFY_X509_STRICT = 0x20
VERIFY_ALLOW_PROXY_CERTS = 0x40
VERIFY_X509_TRUSTED_FIRST = 0x8000
VERIFY_X509_PARTIAL_CHAIN = 0x80000

OPENSSL_VERSION = _c.OpenSSL_version(0)
OPENSSL_VERSION_NUMBER = _c.OpenSSL_version_num()


def _version_info(n):
    # 0xMNN00PP0L, as _ssl.c's parse_openssl_version reads it.
    status = n & 0xf
    n >>= 4
    patch = n & 0xff
    n >>= 8
    fix = n & 0xff
    n >>= 8
    minor = n & 0xff
    n >>= 8
    major = n & 0xff
    return (major, minor, fix, patch, status)


OPENSSL_VERSION_INFO = _version_info(OPENSSL_VERSION_NUMBER)
_OPENSSL_API_VERSION = OPENSSL_VERSION_INFO

# --- libssl's own numbers, private ------------------------------------------

_M_TLS, _M_TLS_CLIENT, _M_TLS_SERVER, _M_BIO_MEM = 0, 1, 2, 3
_M_TLSv1, _M_TLSv1_1, _M_TLSv1_2 = 4, 5, 6
_CB_PASSWORD, _CB_ALPN, _CB_HELLO, _CB_KEYLOG = 0, 1, 2, 3

_SSL_VERIFY_NONE = 0
_SSL_VERIFY_PEER = 1
_SSL_VERIFY_FAIL_IF_NO_PEER_CERT = 2
_SSL_VERIFY_POST_HANDSHAKE = 8
_SSL_ERROR_NONE = 0
_SSL_ERROR_WANT_CLIENT_HELLO_CB = 11
_SSL_RECEIVED_SHUTDOWN = 2
_SSL_SENT_SHUTDOWN = 1

_CTRL_MODE = 33
_CTRL_SET_READ_AHEAD = 41
_CTRL_SET_TLSEXT_HOSTNAME = 55
_CTRL_SET_GROUPS_LIST = 92
_CTRL_SET_TMP_DH = 3
_CTRL_SET_MIN_PROTO = 123
_CTRL_SET_MAX_PROTO = 124
_CTRL_GET_MIN_PROTO = 130
_CTRL_GET_MAX_PROTO = 131
_MODE_ACCEPT_MOVING_WRITE_BUFFER = 2
_MODE_AUTO_RETRY = 4
_MODE_RELEASE_BUFFERS = 0x10

_BIO_CTRL_EOF = 2
_BIO_C_SET_BUF_MEM_EOF_RETURN = 130
_BIO_FLAGS_RETRY = 0x0f

_ERR_LIB_SYS = 2
_ERR_LIB_PEM = 9
_ERR_LIB_X509 = 11
_ERR_LIB_SSL = 20
_SSL_R_CERTIFICATE_VERIFY_FAILED = 134
_SSL_R_UNEXPECTED_EOF_WHILE_READING = 294
_X509_R_CERT_ALREADY_IN_HASH_TABLE = 101
_PEM_R_NO_START_LINE = 108
_X509_V_ERR_HOSTNAME_MISMATCH = 62
_X509_V_ERR_IP_ADDRESS_MISMATCH = 64
_X509_LU_X509 = 1
_FILETYPE_PEM = 1

_PROTO_MIN_AVAILABLE = PROTO_TLSv1
_PROTO_MAX_AVAILABLE = PROTO_TLSv1_3

# CPython's lib_codes_to_names, from Modules/_ssl_data_300.h.
_LIB_NAMES = {
    13: 'ASN1', 51: 'ASYNC', 32: 'BIO', 3: 'BN', 7: 'BUF', 58: 'CMP',
    46: 'CMS', 41: 'COMP', 14: 'CONF', 56: 'CRMF', 15: 'CRYPTO', 50: 'CT',
    5: 'DH', 10: 'DSA', 37: 'DSO', 16: 'EC', 43: 'ECDH', 42: 'ECDSA',
    38: 'ENGINE', 54: 'ESS', 6: 'EVP', 45: 'FIPS', 48: 'HMAC', 61: 'HTTP',
    49: 'JPAKE', 52: 'KDF', 12: 'METH', 8: 'OBJ', 39: 'OCSP',
    60: 'OSSL_DECODER', 59: 'OSSL_ENCODER', 44: 'OSSL_STORE', 9: 'PEM',
    35: 'PKCS12', 33: 'PKCS7', 55: 'PROP', 57: 'PROV', 31: 'PROXY',
    36: 'RAND', 4: 'RSA', 30: 'RSAREF', 53: 'SM2', 20: 'SSL', 22: 'SSL2',
    21: 'SSL23', 23: 'SSL3', 2: 'SYS', 47: 'TS', 40: 'UI', 11: 'X509',
    34: 'X509V3', 128: 'USER',
}

# CPython's err_codes_to_names maps (library, reason) to a mnemonic.  For
# all but these the mnemonic is the reason string itself, upper-cased
# with its spaces made underscores ("certificate verify failed" ->
# CERTIFICATE_VERIFY_FAILED), so that is computed and only the exceptions
# are written down.
_REASON_EXCEPTIONS = {
    (4, 135): 'SLEN_RECOVERY_FAILED', (4, 136): 'SLEN_CHECK_FAILED',
    (5, 102): 'INVALID_PUBKEY', (6, 142): 'EXPECTING_A_EC_KEY',
    (6, 162): 'PARTIALLY_OVERLAPPING', (6, 166): 'ERROR_SETTING_FIPS_MODE',
    (6, 167): 'FIPS_MODE_NOT_SUPPORTED', (6, 168): 'INVALID_FIPS_MODE',
    (6, 219): 'EXPECTING_A_ECX_KEY', (10, 110): 'SEED_LEN_SMALL',
    (15, 101): 'FIPS_MODE_NOT_SUPPORTED',
    (20, 143): 'AT_LEAST_TLS_1_0_NEEDED_IN_FIPS_MODE',
    (20, 158): 'AT_LEAST_TLS_1_2_NEEDED_IN_SUITEB_MODE',
    (20, 330): 'NO_GOST_CERTIFICATE_SENT_BY_PEER',
    (20, 358): 'MISSING_SRP_PARAM', (20, 361): 'SRP_A_CALC',
    (20, 380): 'ILLEGAL_SUITEB_DIGEST', (36, 101): 'FUNC_NOT_IMPLEMENTED',
    (36, 123): 'FWRITE_ERROR',
    (36, 137): 'DERIVATION_FUNCTION_MANDATORY_FOR_FIPS',
    (37, 100): 'CTRL_FAILED', (37, 102): 'FINISH_FAILED',
    (37, 103): 'LOAD_FAILED', (37, 104): 'NULL_HANDLE',
    (37, 105): 'STACK_ERROR', (37, 106): 'SYM_FAILURE',
    (37, 107): 'UNLOAD_FAILED', (37, 108): 'UNSUPPORTED',
    (38, 105): 'ENGINE_IS_NOT_IN_LIST', (38, 108): 'ID_OR_NAME_MISSING',
    (40, 109): 'SYSASSIGN_ERROR', (40, 110): 'SYSDASSGN_ERROR',
    (40, 111): 'SYSQIOW_ERROR', (47, 136): 'VAR_LOOKUP_FAILURE',
    (47, 137): 'CANNOT_LOAD_CERT', (47, 138): 'CANNOT_LOAD_KEY',
    (53, 100): 'ASN1_ERROR', (53, 101): 'BAD_SIGNATURE',
    (53, 102): 'INVALID_DIGEST', (53, 103): 'INVALID_DIGEST_TYPE',
    (53, 104): 'INVALID_ENCODING', (53, 105): 'INVALID_FIELD',
    (53, 106): 'USER_ID_TOO_LARGE', (53, 107): 'BUFFER_TOO_SMALL',
    (53, 108): 'INVALID_CURVE', (53, 109): 'NO_PARAMETERS_SET',
    (53, 110): 'DIST_ID_TOO_LARGE', (53, 111): 'ID_TOO_LARGE',
    (53, 112): 'ID_NOT_SET', (53, 113): 'INVALID_PRIVATE_KEY',
    (59, 100): 'INCORRECT_PROPERTY_QUERY', (59, 101): 'ENCODER_NOT_FOUND',
    (59, 102): 'MISSING_GET_PARAMS', (60, 100): 'MISSING_GET_PARAMS',
    (60, 101): 'COULD_NOT_DECODE_OBJECT', (60, 102): 'DECODER_NOT_FOUND',
}


def _err_lib(e):
    if e & 0x80000000:
        return _ERR_LIB_SYS
    return (e >> 23) & 0xff


def _err_reason(e):
    if e & 0x80000000:
        return e & 0x7fffffff
    return e & 0x7fffff


def _reason_name(e):
    lib = _err_lib(e)
    reason = _err_reason(e)
    name = _REASON_EXCEPTIONS.get((lib, reason))
    if name is not None:
        return name
    if lib == _ERR_LIB_SYS or reason >= 1 << 18:
        # A reason carrying ERR_RFLAG_* bits is one common to every library
        # (ERR_R_PEM_LIB and friends), and CPython's table has none.
        return None
    text = _c.ERR_reason_error_string(e)
    if not text:
        return None
    return text.upper().replace(' ', '_')


# --- the exceptions ---------------------------------------------------------

class _ImmutableType(type):
    """The _ssl types are C types in CPython: their attributes cannot be set.

    test_ssl.test_ssl_types requires a TypeError for every one of them.  Only
    a class that says `_frozen_ = True` in its own body is frozen, because
    Lib/ssl.py subclasses _SSLContext and then sets attributes on its
    subclass (SSLContext.sslsocket_class), as it may of a heap type.
    """

    def __setattr__(cls, name, value):
        if cls.__dict__.get('_frozen_'):
            raise TypeError("cannot set %r attribute of immutable type '%s.%s'"
                            % (name, cls.__module__, cls.__name__))
        type.__setattr__(cls, name, value)

    def __delattr__(cls, name):
        if cls.__dict__.get('_frozen_'):
            raise TypeError("cannot delete %r attribute of immutable type "
                            "'%s.%s'" % (name, cls.__module__, cls.__name__))
        type.__delattr__(cls, name)



class SSLError(OSError, metaclass=_ImmutableType):
    """An error occurred in the SSL implementation."""

    __module__ = 'ssl'
    _frozen_ = True

    def __str__(self):
        if isinstance(self.strerror, str):
            return self.strerror
        return str(self.args)


class SSLZeroReturnError(SSLError):
    """SSL/TLS session closed cleanly."""

    __module__ = 'ssl'
    _frozen_ = True


class SSLWantReadError(SSLError):
    """Non-blocking SSL socket needs to read more data
before the requested operation can be completed."""

    __module__ = 'ssl'
    _frozen_ = True


class SSLWantWriteError(SSLError):
    """Non-blocking SSL socket needs to write more data
before the requested operation can be completed."""

    __module__ = 'ssl'
    _frozen_ = True


class SSLSyscallError(SSLError):
    """System error when attempting SSL operation."""

    __module__ = 'ssl'
    _frozen_ = True


class SSLEOFError(SSLError):
    """SSL/TLS connection terminated abruptly."""

    __module__ = 'ssl'
    _frozen_ = True


class SSLCertVerificationError(SSLError, ValueError):
    """A certificate could not be verified."""

    __module__ = 'ssl'
    _frozen_ = True



_LINE = 1000    # the "(_ssl.c:NNNN)" every message carries
_ERRSTR = "_ssl.c:983: "    # ERRSTR(): what the handshake's own errors start with


def _fill_error(sslsock, cls, ssl_errno, errstr, errcode):
    """fill_and_set_sslerror: the exception, worded and attributed."""
    reason_obj = lib_obj = None
    if errcode:
        lib_obj = _LIB_NAMES.get(_err_lib(errcode))
        reason_obj = _reason_name(errcode)
        if errstr is None:
            errstr = _c.ERR_reason_error_string(errcode)
    if errstr is None:
        errstr = "unknown error"
    verify_obj = verify_code = None
    is_verify = sslsock is not None and cls is SSLCertVerificationError
    if is_verify:
        verify_code = _c.SSL_get_verify_result(sslsock._h)
        if verify_code == _X509_V_ERR_HOSTNAME_MISMATCH:
            verify_obj = ("Hostname mismatch, certificate is not valid for "
                          "'%s'." % (sslsock._server_hostname,))
        elif verify_code == _X509_V_ERR_IP_ADDRESS_MISMATCH:
            verify_obj = ("IP address mismatch, certificate is not valid "
                          "for '%s'." % (sslsock._server_hostname,))
        else:
            verify_obj = _c.X509_verify_cert_error_string(verify_code)
    if verify_obj and reason_obj and lib_obj:
        msg = "[%s: %s] %s: %s (_ssl.c:%d)" % (lib_obj, reason_obj, errstr,
                                               verify_obj, _LINE)
    elif reason_obj and lib_obj:
        msg = "[%s: %s] %s (_ssl.c:%d)" % (lib_obj, reason_obj, errstr,
                                           _LINE)
    elif lib_obj:
        msg = "[%s] %s (_ssl.c:%d)" % (lib_obj, errstr, _LINE)
    else:
        msg = "%s (_ssl.c:%d)" % (errstr, _LINE)
    err = cls(_err_reason(ssl_errno), msg)
    err.reason = reason_obj
    err.library = lib_obj
    if is_verify:
        err.verify_code = verify_code
        err.verify_message = verify_obj
    return err


def _ssl_error(errstr=None):
    """_setSSLError: an SSLError from the error queue, which it clears."""
    errcode = _c.ERR_peek_last_error() if errstr is None else 0
    err = _fill_error(None, SSLError, errcode, errstr, errcode)
    _c.ERR_clear_error()
    return err


def _oserror(eno, filename=None):
    if filename is not None:
        return OSError(eno, _os.strerror(eno), filename)
    return OSError(eno, _os.strerror(eno))


def _deprecated(msg, stacklevel=3):
    import warnings
    warnings.warn(msg, DeprecationWarning, stacklevel=stacklevel)


def _fspath_bytes(obj, what):
    try:
        path = _os.fspath(obj)
    except TypeError:
        raise TypeError("%s should be a valid filesystem path" % what) from None
    if isinstance(path, str):
        path = _os.fsencode(path)
    if b'\0' in path:
        raise ValueError("embedded null byte")
    return path


# --- one borrowed handle, freed however the block ends ----------------------

class _Borrowed:
    __slots__ = ('h',)

    def __init__(self, h):
        self.h = h

    def __enter__(self):
        return self.h

    def __exit__(self, *exc):
        if self.h is not None:
            _c.free(self.h)
        return False


def _cipher_to_tuple(h):
    return (_c.SSL_CIPHER_get_name(h), _c.SSL_CIPHER_get_version(h),
            _c.SSL_CIPHER_get_bits(h, None))


def _nid_ln(nid):
    return _c.OBJ_nid2ln(nid) if nid else None


def _cipher_to_dict(h):
    desc = _c.SSL_CIPHER_description(h, 511)
    if len(desc) > 1 and desc.endswith('\n'):
        desc = desc[:-1]
    return {
        'id': _c.SSL_CIPHER_get_id(h),
        'name': _c.SSL_CIPHER_get_name(h),
        'protocol': _c.SSL_CIPHER_get_version(h),
        'description': desc,
        'strength_bits': _c.SSL_CIPHER_get_bits(h, None),
        'alg_bits': _c.SSL_CIPHER_get_alg_bits(h),
        'aead': bool(_c.SSL_CIPHER_is_aead(h)),
        'symmetric': _nid_ln(_c.SSL_CIPHER_get_cipher_nid(h)),
        'digest': _nid_ln(_c.SSL_CIPHER_get_digest_nid(h)),
        'kea': _nid_ln(_c.SSL_CIPHER_get_kx_nid(h)),
        'auth': _nid_ln(_c.SSL_CIPHER_get_auth_nid(h)),
    }


def _stack_items(stack_h):
    """The borrowed handles of an OpenSSL stack; the caller frees them."""
    n = _c.OPENSSL_sk_num(stack_h)
    return [_c.OPENSSL_sk_value(stack_h, i) for i in range(max(n, 0))]


def _free_all(handles):
    for h in handles:
        if h is not None:
            _c.free(h)


def _x509_der(x509_h):
    der = _c.i2d_X509(x509_h)
    if der is None:
        raise _ssl_error()
    return der


# --- the context ------------------------------------------------------------

class _SSLContext(metaclass=_ImmutableType):
    """The SSLContext CPython implements in C; ssl.SSLContext subclasses it."""

    __module__ = '_ssl'
    _frozen_ = True

    def __new__(cls, protocol):
        method = None
        if protocol == PROTOCOL_TLS:
            _deprecated("ssl.PROTOCOL_TLS is deprecated")
            method = _M_TLS
        elif protocol == PROTOCOL_TLS_CLIENT:
            method = _M_TLS_CLIENT
        elif protocol == PROTOCOL_TLS_SERVER:
            method = _M_TLS_SERVER
        elif protocol == PROTOCOL_TLSv1:
            _deprecated("ssl.PROTOCOL_TLSv1 is deprecated")
            method = _M_TLSv1
        elif protocol == PROTOCOL_TLSv1_1:
            _deprecated("ssl.PROTOCOL_TLSv1_1 is deprecated")
            method = _M_TLSv1_1
        elif protocol == PROTOCOL_TLSv1_2:
            _deprecated("ssl.PROTOCOL_TLSv1_2 is deprecated")
            method = _M_TLSv1_2
        if method is None:
            raise ValueError("invalid or unsupported protocol version %i"
                             % (protocol,))
        h = _c.SSL_CTX_new(method)
        if h is None:
            raise _ssl_error()
        self = object.__new__(cls)
        self._h = h
        self._protocol = protocol
        self._hostflags = HOSTFLAG_NO_PARTIAL_WILDCARDS
        self._check_hostname = False
        self._post_handshake_auth = False
        self._sni_cb = None
        self._msg_cb = None
        self._keylog_filename = None
        self._alpn = None
        if protocol == PROTOCOL_TLS_CLIENT:
            self._check_hostname = True
            self._set_verify_mode(CERT_REQUIRED)
        else:
            self._set_verify_mode(CERT_NONE)
        options = (OP_ALL | OP_NO_SSLv2 | OP_NO_SSLv3 | OP_NO_COMPRESSION
                   | OP_CIPHER_SERVER_PREFERENCE | OP_SINGLE_DH_USE
                   | OP_SINGLE_ECDH_USE)
        _c.SSL_CTX_set_options(h, options)
        _c.SSL_CTX_ctrl(h, _CTRL_MODE, _MODE_RELEASE_BUFFERS, None)
        _c.SSL_CTX_set_session_id_context(h, b"Python\0")
        _c.X509_VERIFY_PARAM_set_flags(h, VERIFY_X509_TRUSTED_FIRST)
        _c.X509_VERIFY_PARAM_set_hostflags(h, self._hostflags)
        _c.SSL_CTX_set_post_handshake_auth(h, 0)
        # Never let a key file prompt on the terminal: with no password
        # parked, the core's callback refuses.
        _c.SSL_CTX_set_default_passwd_cb(h, _CB_PASSWORD)
        return self

    def __init__(self, *args, **kwargs):
        pass

    def __del__(self):
        h = getattr(self, '_h', None)
        if h is not None:
            self._h = None
            _c.free(h)

    # --- verification

    def _set_verify_mode(self, n):
        if n == CERT_NONE:
            mode = _SSL_VERIFY_NONE
        elif n == CERT_OPTIONAL:
            mode = _SSL_VERIFY_PEER
        elif n == CERT_REQUIRED:
            mode = _SSL_VERIFY_PEER | _SSL_VERIFY_FAIL_IF_NO_PEER_CERT
        else:
            raise ValueError("invalid value for verify_mode")
        _c.SSL_CTX_set_verify(self._h, mode, -1)

    @property
    def verify_mode(self):
        mode = _c.SSL_CTX_get_verify_mode(self._h) & 3
        if mode == _SSL_VERIFY_NONE:
            return CERT_NONE
        if mode == _SSL_VERIFY_PEER:
            return CERT_OPTIONAL
        if mode == 3:
            return CERT_REQUIRED
        raise SSLError("invalid return value from SSL_CTX_get_verify_mode")

    @verify_mode.setter
    def verify_mode(self, n):
        n = _as_int(n)
        if n == CERT_NONE and self._check_hostname:
            raise ValueError("Cannot set verify_mode to CERT_NONE when "
                             "check_hostname is enabled.")
        self._set_verify_mode(n)

    @property
    def verify_flags(self):
        return _c.X509_VERIFY_PARAM_get_flags(self._h)

    @verify_flags.setter
    def verify_flags(self, new):
        new = _as_int(new)
        if new < 0:
            raise OverflowError("can't convert negative int to unsigned")
        flags = _c.X509_VERIFY_PARAM_get_flags(self._h)
        clear = flags & ~new
        add = ~flags & new
        if clear and not _c.X509_VERIFY_PARAM_clear_flags(self._h, clear):
            raise _ssl_error()
        if add and not _c.X509_VERIFY_PARAM_set_flags(self._h, add):
            raise _ssl_error()

    @property
    def check_hostname(self):
        return self._check_hostname

    @check_hostname.setter
    def check_hostname(self, value):
        value = bool(value)
        if value and _c.SSL_CTX_get_verify_mode(self._h) == _SSL_VERIFY_NONE:
            self._set_verify_mode(CERT_REQUIRED)
        self._check_hostname = value

    @property
    def _host_flags(self):
        return self._hostflags

    @_host_flags.setter
    def _host_flags(self, value):
        value = _as_int(value)
        self._hostflags = value
        _c.X509_VERIFY_PARAM_set_hostflags(self._h, value)

    @property
    def post_handshake_auth(self):
        return self._post_handshake_auth

    @post_handshake_auth.setter
    def post_handshake_auth(self, value):
        self._post_handshake_auth = bool(value)

    # --- protocol

    @property
    def protocol(self):
        return self._protocol

    @property
    def options(self):
        return _c.SSL_CTX_get_options(self._h)

    @options.setter
    def options(self, new):
        if not isinstance(new, int):
            raise TypeError("an integer is required (got type %s)"
                            % type(new).__name__)
        if new < 0:
            raise OverflowError("can't convert negative int to unsigned")
        if new >= 1 << 64:
            raise OverflowError("int too big to convert")
        opts = _c.SSL_CTX_get_options(self._h)
        clear = opts & ~new
        add = ~opts & new
        opt_no = (OP_NO_SSLv2 | OP_NO_SSLv3 | OP_NO_TLSv1 | OP_NO_TLSv1_1
                  | OP_NO_TLSv1_2 | OP_NO_TLSv1_3)
        if add & opt_no:
            _deprecated("ssl.OP_NO_SSL*/ssl.OP_NO_TLS* options are "
                        "deprecated")
        if clear:
            _c.SSL_CTX_clear_options(self._h, clear)
        if add:
            _c.SSL_CTX_set_options(self._h, add)

    def _set_min_max(self, v, what):
        v = _as_int(v)
        if v > 0x7fffffff:
            raise OverflowError("Option is too long")
        if self._protocol not in (PROTOCOL_TLS_CLIENT, PROTOCOL_TLS_SERVER,
                                  PROTOCOL_TLS):
            raise ValueError("The context's protocol doesn't support "
                             "modification of highest and lowest version.")
        if v == PROTO_SSLv3:
            _deprecated("ssl.TLSVersion.SSLv3 is deprecated")
        elif v == PROTO_TLSv1:
            _deprecated("ssl.TLSVersion.TLSv1 is deprecated")
        elif v == PROTO_TLSv1_1:
            _deprecated("ssl.TLSVersion.TLSv1_1 is deprecated")
        elif v not in (PROTO_MINIMUM_SUPPORTED, PROTO_MAXIMUM_SUPPORTED,
                       PROTO_TLSv1_2, PROTO_TLSv1_3):
            raise ValueError("Unsupported TLS/SSL version 0x%x" % (v,))
        if what == 0:
            if v == PROTO_MINIMUM_SUPPORTED:
                v = 0
            elif v == PROTO_MAXIMUM_SUPPORTED:
                v = _PROTO_MAX_AVAILABLE
            r = _c.SSL_CTX_ctrl(self._h, _CTRL_SET_MIN_PROTO, v, None)
        else:
            if v == PROTO_MAXIMUM_SUPPORTED:
                v = 0
            elif v == PROTO_MINIMUM_SUPPORTED:
                v = _PROTO_MIN_AVAILABLE
            r = _c.SSL_CTX_ctrl(self._h, _CTRL_SET_MAX_PROTO, v, None)
        if r == 0:
            raise ValueError("Unsupported protocol version 0x%x" % (v,))

    @property
    def minimum_version(self):
        v = _c.SSL_CTX_ctrl(self._h, _CTRL_GET_MIN_PROTO, 0, None)
        return v if v else PROTO_MINIMUM_SUPPORTED

    @minimum_version.setter
    def minimum_version(self, v):
        self._set_min_max(v, 0)

    @property
    def maximum_version(self):
        v = _c.SSL_CTX_ctrl(self._h, _CTRL_GET_MAX_PROTO, 0, None)
        return v if v else PROTO_MAXIMUM_SUPPORTED

    @maximum_version.setter
    def maximum_version(self, v):
        self._set_min_max(v, 1)

    @property
    def num_tickets(self):
        return _c.SSL_CTX_get_num_tickets(self._h)

    @num_tickets.setter
    def num_tickets(self, num):
        num = _as_int(num)
        if num < 0:
            raise ValueError("value must be non-negative")
        if self._protocol != PROTOCOL_TLS_SERVER:
            raise ValueError("SSLContext is not a server context.")
        if _c.SSL_CTX_set_num_tickets(self._h, num) != 1:
            raise ValueError("failed to set num tickets.")

    @property
    def security_level(self):
        return _c.SSL_CTX_get_security_level(self._h)

    # --- callbacks

    @property
    def sni_callback(self):
        return self._sni_cb

    @sni_callback.setter
    def sni_callback(self, cb):
        if self._protocol == PROTOCOL_TLS_CLIENT:
            raise ValueError("sni_callback cannot be set on TLS_CLIENT "
                             "context")
        self._sni_cb = None
        if cb is None:
            _c.SSL_CTX_set_client_hello_cb(self._h, -1, None)
            return
        if not callable(cb):
            _c.SSL_CTX_set_client_hello_cb(self._h, -1, None)
            raise TypeError("not a callable object")
        self._sni_cb = cb
        _c.SSL_CTX_set_client_hello_cb(self._h, _CB_HELLO, None)

    @property
    def _msg_callback(self):
        return self._msg_cb

    @_msg_callback.setter
    def _msg_callback(self, cb):
        if cb is not None and not callable(cb):
            raise TypeError("not a callable object")
        self._msg_cb = cb

    @property
    def keylog_filename(self):
        return self._keylog_filename

    @keylog_filename.setter
    def keylog_filename(self, name):
        if name is None:
            self._keylog_filename = None
            _c.SSL_CTX_set_keylog_callback(self._h, -1)
            return
        path = _fspath_bytes(name, "keylog_filename")
        # Open once up front, as CPython does: an unwritable path is an
        # error now rather than at the first handshake.
        with open(path, 'ab') as f:
            if f.tell() == 0:
                f.write(b"# TLS secrets log file, generated by OpenSSL / "
                        b"Python\n")
        self._keylog_filename = name
        _c.SSL_CTX_set_keylog_callback(self._h, _CB_KEYLOG)

    def _flush_keylog(self):
        data = _c.keylog_drain()
        if data and self._keylog_filename is not None:
            with open(_fspath_bytes(self._keylog_filename, "keylog_filename"),
                      'ab') as f:
                f.write(data)

    # --- ciphers, ALPN, curves

    def set_ciphers(self, cipherlist):
        if not isinstance(cipherlist, str):
            raise TypeError("set_ciphers() argument must be str, not %s"
                            % type(cipherlist).__name__)
        if '\0' in cipherlist:
            raise ValueError("embedded null character")
        if _c.SSL_CTX_set_cipher_list(self._h, cipherlist) == 0:
            _c.ERR_clear_error()
            raise SSLError("No cipher can be selected.")

    def get_ciphers(self):
        ssl = _c.SSL_new(self._h)
        if ssl is None:
            raise _ssl_error()
        try:
            with _Borrowed(_c.SSL_get_ciphers(ssl)) as sk:
                items = _stack_items(sk)
                try:
                    return [_cipher_to_dict(c) for c in items]
                finally:
                    _free_all(items)
        finally:
            _c.free(ssl)

    def _set_alpn_protocols(self, protos):
        protos = bytes(memoryview(protos))
        self._alpn = protos
        if _c.SSL_CTX_set_alpn_protos(self._h, protos):
            raise MemoryError()
        _c.set_alpn_server(self._h, protos)

    def set_ecdh_curve(self, name):
        bname = _os.fsencode(name)
        if _c.OBJ_sn2nid(bname) == 0:
            raise ValueError("unknown elliptic curve name %r" % (name,))
        if not _c.SSL_CTX_ctrl(self._h, _CTRL_SET_GROUPS_LIST, 0, bname):
            raise _ssl_error()

    # --- certificates and keys

    def load_cert_chain(self, certfile, keyfile=None, password=None):
        _c.ERR_clear_error()
        cert = _fspath_bytes(certfile, "certfile")
        key = cert if keyfile is None else _fspath_bytes(keyfile, "keyfile")
        pw = None
        if password is not None:
            if callable(password):
                if _key_is_encrypted(key):
                    pw = password()
                    pw = _password_bytes(
                        pw, "password callback must return a string")
            else:
                pw = _password_bytes(
                    password, "password should be a string or callable")
            if pw is not None and len(pw) > 1023:
                raise ValueError("password cannot be longer than 1023 bytes")
        _c.set_password(pw)
        try:
            if _c.SSL_CTX_use_certificate_chain_file(self._h, cert) != 1:
                raise self._load_error()
            if _c.SSL_CTX_use_PrivateKey_file(self._h, key,
                                              _FILETYPE_PEM) != 1:
                raise self._load_error()
            if _c.SSL_CTX_check_private_key(self._h) != 1:
                raise _ssl_error()
        finally:
            _c.set_password(None)

    def _load_error(self):
        eno = _c.errno()
        if eno:
            _c.ERR_clear_error()
            return _oserror(eno)
        return _ssl_error()

    def load_verify_locations(self, cafile=None, capath=None, cadata=None):
        if cafile is None and capath is None and cadata is None:
            raise TypeError("cafile, capath and cadata cannot be all omitted")
        cafile_b = None if cafile is None else _fspath_bytes(cafile, "cafile")
        capath_b = None if capath is None else _fspath_bytes(capath, "capath")
        if cadata is not None:
            if isinstance(cadata, str):
                try:
                    data = cadata.encode('ascii')
                except UnicodeEncodeError:
                    raise TypeError("cadata should be an ASCII string or a "
                                    "bytes-like object") from None
                self._add_ca_certs(data, _FILETYPE_PEM)
            else:
                try:
                    view = memoryview(cadata)
                except TypeError:
                    raise TypeError("cadata should be an ASCII string or a "
                                    "bytes-like object") from None
                if not view.c_contiguous or view.ndim > 1:
                    raise TypeError("cadata should be a contiguous buffer "
                                    "with a single dimension")
                self._add_ca_certs(view.tobytes(), 2)
        if cafile_b is not None or capath_b is not None:
            if _c.SSL_CTX_load_verify_locations(self._h, cafile_b,
                                                capath_b) != 1:
                eno = _c.errno()
                if eno:
                    _c.ERR_clear_error()
                    raise _oserror(eno)
                raise _ssl_error()

    def _add_ca_certs(self, data, filetype):
        if len(data) == 0:
            raise ValueError("Empty certificate data")
        bio = _c.BIO_new_mem_buf(data)
        if bio is None:
            raise _ssl_error("Can't allocate buffer")
        loaded = 0
        was_eof = False
        try:
            while True:
                if filetype != _FILETYPE_PEM:
                    if _c.BIO_ctrl(bio, _BIO_CTRL_EOF, 0, None):
                        was_eof = True
                        break
                    cert = _c.d2i_X509_bio(bio, None)
                else:
                    cert = _c.PEM_read_bio_X509(bio, None, _CB_PASSWORD,
                                                None)
                if cert is None:
                    break
                r = _c.X509_STORE_add_cert(self._h, cert)
                _c.free(cert)
                if not r:
                    err = _c.ERR_peek_last_error()
                    if (_err_lib(err) == _ERR_LIB_X509 and _err_reason(err)
                            == _X509_R_CERT_ALREADY_IN_HASH_TABLE):
                        _c.ERR_clear_error()
                    else:
                        break
                loaded += 1
        finally:
            _c.free(bio)
        err = _c.ERR_peek_last_error()
        if loaded == 0:
            if filetype == _FILETYPE_PEM:
                msg = "no start line: cadata does not contain a certificate"
            else:
                msg = ("not enough data: cadata does not contain a "
                       "certificate")
            raise _ssl_error(msg)
        if filetype != _FILETYPE_PEM and was_eof:
            _c.ERR_clear_error()
        elif (filetype == _FILETYPE_PEM and _err_lib(err) == _ERR_LIB_PEM
              and _err_reason(err) == _PEM_R_NO_START_LINE):
            _c.ERR_clear_error()
        elif err:
            raise _ssl_error()

    def load_dh_params(self, path):
        bpath = _fspath_bytes(path, "path")
        bio = _c.BIO_new_file(bpath, b"rb")
        if bio is None:
            eno = _c.errno()
            _c.ERR_clear_error()
            raise _oserror(eno or 2, path)
        try:
            dh = _c.PEM_read_bio_DHparams(bio, None, None, None)
        finally:
            _c.free(bio)
        if dh is None:
            raise _ssl_error()
        try:
            if not _c.SSL_CTX_ctrl_ptr(self._h, _CTRL_SET_TMP_DH, 0, dh):
                raise _ssl_error()
        finally:
            _c.DH_free(dh)
            _c.free(dh)

    def set_default_verify_paths(self):
        if not _c.SSL_CTX_set_default_verify_paths(self._h):
            raise _ssl_error()

    def _store_certs(self):
        """(x509 count, crl count, [DER of each CA cert])"""
        x509 = crl = 0
        cas = []
        with _Borrowed(_c.X509_STORE_get0_objects(self._h)) as sk:
            objs = _stack_items(sk)
            try:
                for obj in objs:
                    t = _c.X509_OBJECT_get_type(obj)
                    if t == _X509_LU_X509:
                        x509 += 1
                        with _Borrowed(_c.X509_OBJECT_get0_X509(obj)) as x:
                            if _c.X509_check_ca(x):
                                cas.append(_x509_der(x))
                    elif t == 2:
                        crl += 1
            finally:
                _free_all(objs)
        return x509, crl, cas

    def cert_store_stats(self):
        x509, crl, cas = self._store_certs()
        return {'x509': x509, 'crl': crl, 'x509_ca': len(cas)}

    def get_ca_certs(self, binary_form=False):
        cas = self._store_certs()[2]
        if binary_form:
            return cas
        return [_decode_der(der) for der in cas]

    def session_stats(self):
        names = (("number", 20), ("connect", 21), ("connect_good", 22),
                 ("connect_renegotiate", 23), ("accept", 24),
                 ("accept_good", 25), ("accept_renegotiate", 26),
                 ("hits", 27), ("misses", 29), ("timeouts", 30),
                 ("cache_full", 31))
        return {k: _c.SSL_CTX_ctrl(self._h, n, 0, None) for k, n in names}

    # --- wrapping

    def _wrap_socket(self, sock, server_side, server_hostname=None, *,
                     owner=None, session=None):
        import _socket
        if not isinstance(sock, _socket.socket):
            raise TypeError("_wrap_socket() argument 'sock' must be "
                            "_socket.socket, not %s" % type(sock).__name__)
        return _SSLSocket._new(self, sock, bool(server_side),
                               _hostname_arg(server_hostname), owner,
                               session, None, None)

    def _wrap_bio(self, incoming, outgoing, server_side,
                  server_hostname=None, *, owner=None, session=None):
        if not isinstance(incoming, MemoryBIO):
            raise TypeError("_wrap_bio() argument 'incoming' must be "
                            "_ssl.MemoryBIO, not %s"
                            % type(incoming).__name__)
        if not isinstance(outgoing, MemoryBIO):
            raise TypeError("_wrap_bio() argument 'outgoing' must be "
                            "_ssl.MemoryBIO, not %s"
                            % type(outgoing).__name__)
        return _SSLSocket._new(self, None, bool(server_side),
                               _hostname_arg(server_hostname), owner,
                               session, incoming, outgoing)




def _as_int(v):
    if isinstance(v, bool) or not isinstance(v, int):
        try:
            return v.__index__()
        except AttributeError:
            raise TypeError("an integer is required (got type %s)"
                            % type(v).__name__) from None
    return v


def _hostname_arg(name):
    if name is None:
        return None
    if isinstance(name, str):
        try:
            name.encode('ascii')
        except UnicodeEncodeError:
            raise
    elif isinstance(name, (bytes, bytearray)):
        name = bytes(name).decode('ascii')
    else:
        raise TypeError("server_hostname must be str or bytes, not %s"
                        % type(name).__name__)
    if '\0' in name:
        raise TypeError("argument 'server_hostname' must be encoded string "
                        "without null bytes")
    return name


def _password_bytes(pw, bad_type):
    if isinstance(pw, str):
        return pw.encode('utf-8')
    if isinstance(pw, (bytes, bytearray)):
        return bytes(pw)
    raise TypeError(bad_type)


def _key_is_encrypted(path):
    try:
        with open(path, 'rb') as f:
            head = f.read(1 << 16)
    except OSError:
        return True     # let OpenSSL report it, and ask for a password then
    return (b'ENCRYPTED' in head) or (b'Proc-Type: 4,ENCRYPTED' in head)


def _parse_ip(name):
    """a2i_IPADDRESS: the packed address, or None for a host name."""
    if ':' not in name:
        parts = name.split('.')
        if len(parts) != 4:
            return None
        out = []
        for p in parts:
            if not p.isdigit() or not p.isascii():
                return None
            v = int(p)
            if v > 255:
                return None
            out.append(v)
        return bytes(out)
    try:
        import ipaddress
        return ipaddress.IPv6Address(name).packed
    except ValueError:
        return None


# --- poll on the socket, with what is left of its timeout --------------------

_SOCKET_IS_NONBLOCKING = 0
_SOCKET_IS_BLOCKING = 1
_SOCKET_HAS_TIMED_OUT = 2
_SOCKET_HAS_BEEN_CLOSED = 3
_SOCKET_OPERATION_OK = 5


def _select(sock, writing, timeout):
    if sock is None or timeout == 0:
        return _SOCKET_IS_NONBLOCKING
    if timeout is None:
        return _SOCKET_IS_BLOCKING
    if timeout < 0:
        return _SOCKET_HAS_TIMED_OUT
    fd = sock.fileno()
    if fd == -1:
        return _SOCKET_HAS_BEEN_CLOSED
    events = _sc.POLLOUT if writing else _sc.POLLIN
    ms = int(timeout * 1000)
    if ms * 0.001 < timeout:
        ms += 1
    got = _sc.poll([fd, events], ms)
    if not got or got[0] == 0:
        return _SOCKET_HAS_TIMED_OUT
    return _SOCKET_OPERATION_OK


class _Deadline:
    """GET_SOCKET_TIMEOUT and _PyDeadline: the timeout left, re-read."""
    __slots__ = ('timeout', 'deadline')

    def __init__(self, sock):
        t = None if sock is None else sock.gettimeout()
        self.timeout = t
        self.deadline = _time.monotonic() + t if t else None

    def left(self):
        if self.deadline is None:
            return self.timeout
        return self.deadline - _time.monotonic()


# --- the connection ---------------------------------------------------------

class _SSLSocket(metaclass=_ImmutableType):
    """One TLS connection, over a socket or over a pair of MemoryBIOs."""

    __module__ = '_ssl'
    _frozen_ = True

    def __new__(cls, *args, **kwargs):
        raise TypeError("cannot create '_ssl._SSLSocket' instances")

    @classmethod
    def _new(cls, ctx, sock, server_side, hostname, owner, session,
             inbio, outbio):
        if server_side and ctx._protocol == PROTOCOL_TLS_CLIENT:
            raise _ssl_error("Cannot create a server socket with a "
                             "PROTOCOL_TLS_CLIENT context")
        if not server_side and ctx._protocol == PROTOCOL_TLS_SERVER:
            raise _ssl_error("Cannot create a client socket with a "
                             "PROTOCOL_TLS_SERVER context")
        self = object.__new__(cls)
        self._h = None
        self._ctx = ctx
        self._server_side = server_side
        self._server_hostname = None
        self._owner = None
        self._socket = None
        self._shutdown_seen_zero = False
        self._err = (0, 0)
        self._bios = None
        _c.ERR_clear_error()
        h = _c.SSL_new(ctx._h)
        if h is None:
            raise _ssl_error()
        self._h = h
        if sock is not None:
            _c.SSL_set_fd(h, sock.fileno())
        else:
            _c.BIO_up_ref(inbio._h)
            _c.BIO_up_ref(outbio._h)
            _c.SSL_set_bio(h, inbio._h, outbio._h)
            self._bios = (inbio, outbio)
        _c.SSL_ctrl(h, _CTRL_MODE,
                    _MODE_ACCEPT_MOVING_WRITE_BUFFER | _MODE_AUTO_RETRY, None)
        if ctx._post_handshake_auth:
            if server_side:
                mode = _c.SSL_get_verify_mode(h)
                if mode & _SSL_VERIFY_PEER:
                    _c.SSL_set_verify(h, mode | _SSL_VERIFY_POST_HANDSHAKE,
                                      -1)
            else:
                _c.SSL_set_post_handshake_auth(h, 1)
        if hostname is not None:
            self._configure_hostname(hostname)
        if server_side:
            _c.SSL_set_accept_state(h)
        else:
            _c.SSL_set_connect_state(h)
        if sock is not None:
            self._socket = _weakref.ref(sock)
        if owner is not None:
            self.owner = owner
        if session is not None:
            self.session = session
        return self

    def _configure_hostname(self, name):
        if not name or name[0] == '.':
            raise ValueError("server_hostname cannot be an empty string or "
                             "start with a leading dot.")
        ip = _parse_ip(name)
        self._server_hostname = name
        bname = name.encode('ascii')
        if ip is None:
            if not _c.SSL_ctrl(self._h, _CTRL_SET_TLSEXT_HOSTNAME, 0, bname):
                raise _ssl_error()
        if self._ctx._check_hostname:
            if ip is None:
                ok = _c.X509_VERIFY_PARAM_set1_host(self._h, bname)
            else:
                ok = _c.X509_VERIFY_PARAM_set1_ip(self._h, ip)
            if not ok:
                raise _ssl_error()

    def __del__(self):
        h = getattr(self, '_h', None)
        if h is not None:
            self._h = None
            _c.SSL_set_shutdown(h, _SSL_SENT_SHUTDOWN
                                | _c.SSL_get_shutdown(h))
            _c.free(h)

    # --- attributes

    @property
    def context(self):
        return self._ctx

    @context.setter
    def context(self, ctx):
        if not isinstance(ctx, _SSLContext):
            raise TypeError("The value must be a SSLContext")
        self._ctx = ctx
        _c.SSL_set_SSL_CTX(self._h, ctx._h)

    @property
    def server_side(self):
        return self._server_side

    @property
    def server_hostname(self):
        return self._server_hostname

    @property
    def owner(self):
        if self._owner is None:
            return None
        return self._owner()

    @owner.setter
    def owner(self, value):
        self._owner = _weakref.ref(value)

    @property
    def session(self):
        s = _c.SSL_get1_session(self._h)
        if s is None:
            return None
        return SSLSession._new(self._ctx, s)

    @session.setter
    def session(self, value):
        if not isinstance(value, SSLSession):
            raise TypeError("Value is not a SSLSession.")
        if self._ctx._h != value._ctx._h:
            raise ValueError("Session refers to a different SSLContext.")
        if self._server_side:
            raise ValueError("Cannot set session for server-side SSLSocket.")
        if _c.SSL_is_init_finished(self._h):
            raise ValueError("Cannot set session after handshake.")
        if _c.SSL_set_session(self._h, value._h) == 0:
            raise _ssl_error()

    @property
    def session_reused(self):
        return bool(_c.SSL_session_reused(self._h))

    # --- the socket underneath

    def _get_socket(self):
        """The socket, or None for a BIO pair; raises if it is gone."""
        if self._socket is None:
            return None
        sock = self._socket()
        if sock is None:
            raise _ssl_error("Underlying socket connection gone")
        return sock

    def _set_error(self, ret):
        """PySSL_SetError: the exception this failed call deserves."""
        cls = SSLError
        errstr = None
        p = 0
        e = _c.ERR_peek_last_error()
        err_ssl, err_c = self._err
        if err_ssl == SSL_ERROR_ZERO_RETURN:
            errstr = "TLS/SSL connection has been closed (EOF)"
            cls = SSLZeroReturnError
            p = SSL_ERROR_ZERO_RETURN
        elif err_ssl == SSL_ERROR_WANT_READ:
            errstr = "The operation did not complete (read)"
            cls = SSLWantReadError
            p = SSL_ERROR_WANT_READ
        elif err_ssl == SSL_ERROR_WANT_WRITE:
            errstr = "The operation did not complete (write)"
            cls = SSLWantWriteError
            p = SSL_ERROR_WANT_WRITE
        elif err_ssl == SSL_ERROR_WANT_X509_LOOKUP:
            errstr = "The operation did not complete (X509 lookup)"
            p = SSL_ERROR_WANT_X509_LOOKUP
        elif err_ssl == SSL_ERROR_WANT_CONNECT:
            errstr = "The operation did not complete (connect)"
            p = SSL_ERROR_WANT_CONNECT
        elif err_ssl == SSL_ERROR_SYSCALL:
            if e == 0:
                s = self._socket() if self._socket is not None else None
                if ret == 0 or (self._socket is not None and s is None):
                    p = SSL_ERROR_EOF
                    cls = SSLEOFError
                    errstr = "EOF occurred in violation of protocol"
                elif s is not None and ret == -1:
                    _c.ERR_clear_error()
                    if err_c:
                        return _oserror(err_c)
                    p = SSL_ERROR_EOF
                    cls = SSLEOFError
                    errstr = "EOF occurred in violation of protocol"
                else:
                    p = SSL_ERROR_SYSCALL
                    cls = SSLSyscallError
                    errstr = "Some I/O error occurred"
            else:
                if (_err_lib(e) == _ERR_LIB_SSL and _err_reason(e)
                        == _SSL_R_CERTIFICATE_VERIFY_FAILED):
                    cls = SSLCertVerificationError
                if _err_lib(e) == _ERR_LIB_SYS:
                    _c.ERR_clear_error()
                    return _oserror(_err_reason(e))
                p = SSL_ERROR_SYSCALL
        elif err_ssl == SSL_ERROR_SSL:
            p = SSL_ERROR_SSL
            if e == 0:
                errstr = "A failure in the SSL library occurred"
            if (_err_lib(e) == _ERR_LIB_SSL and _err_reason(e)
                    == _SSL_R_CERTIFICATE_VERIFY_FAILED):
                cls = SSLCertVerificationError
            if (_err_lib(e) == _ERR_LIB_SSL and _err_reason(e)
                    == _SSL_R_UNEXPECTED_EOF_WHILE_READING):
                p = SSL_ERROR_EOF
                cls = SSLEOFError
                errstr = "EOF occurred in violation of protocol"
            if _err_lib(e) == _ERR_LIB_SYS:
                _c.ERR_clear_error()
                return _oserror(_err_reason(e))
        else:
            p = SSL_ERROR_INVALID_ERROR_CODE
            errstr = "Invalid error code"
        err = _fill_error(self, cls, p, errstr, e)
        _c.ERR_clear_error()
        return err

    def _record(self, failed, ret):
        """_PySSL_errno: SSL_get_error and errno, when the call failed."""
        if failed:
            eno = _c.errno()
            self._err = (_c.SSL_get_error(self._h, ret), eno)
        else:
            self._err = (_SSL_ERROR_NONE, 0)
        if self._ctx._keylog_filename is not None:
            self._ctx._flush_keylog()
        return self._err[0]

    def _wait(self, sock, err_ssl, dl, what):
        """Wait for the socket as err_ssl asks; True to retry the call."""
        if err_ssl == SSL_ERROR_WANT_READ:
            state = _select(sock, False, dl.left())
        elif err_ssl == SSL_ERROR_WANT_WRITE:
            state = _select(sock, True, dl.left())
        else:
            return False
        if state == _SOCKET_HAS_TIMED_OUT:
            raise TimeoutError("The %s operation timed out" % what)
        if state == _SOCKET_HAS_BEEN_CLOSED:
            raise SSLError("Underlying socket has been closed.")
        if state == _SOCKET_IS_NONBLOCKING:
            return False
        return True

    # --- the protocol

    def do_handshake(self):
        sock = self._get_socket()
        dl = _Deadline(sock)
        while True:
            ret = _c.SSL_do_handshake(self._h)
            err_ssl = self._record(ret < 1, ret)
            if err_ssl == _SSL_ERROR_WANT_CLIENT_HELLO_CB:
                self._run_sni_callback()
                continue
            if err_ssl == SSL_ERROR_WANT_READ:
                state = _select(sock, False, dl.left())
            elif err_ssl == SSL_ERROR_WANT_WRITE:
                state = _select(sock, True, dl.left())
            else:
                state = _SOCKET_OPERATION_OK
            if state == _SOCKET_HAS_TIMED_OUT:
                raise TimeoutError(_ERRSTR + "The handshake operation timed "
                                   "out")
            if state == _SOCKET_HAS_BEEN_CLOSED:
                raise SSLError(_ERRSTR + "Underlying socket has been closed.")
            if state == _SOCKET_IS_NONBLOCKING:
                break
            if err_ssl not in (SSL_ERROR_WANT_READ, SSL_ERROR_WANT_WRITE):
                break
        if ret < 1:
            raise self._set_error(ret)
        return None

    def _run_sni_callback(self):
        """_servername_callback, run while the handshake is paused."""
        ctx = self._ctx
        cb = ctx._sni_cb
        verdict = 1
        if cb is not None:
            ext = _c.SSL_client_hello_get0_ext(self._h, 0)
            name = _parse_sni(ext)
            if self._owner is not None:
                target = self._owner()
            elif self._socket is not None:
                target = self._socket()
            else:
                target = self
            if target is None:
                verdict = (ALERT_DESCRIPTION_INTERNAL_ERROR << 8) | 2
            else:
                try:
                    result = cb(target, name, ctx)
                except BaseException:
                    import sys
                    sys.unraisablehook(_unraisable(sys.exc_info(), cb))
                    verdict = (ALERT_DESCRIPTION_HANDSHAKE_FAILURE << 8) | 2
                else:
                    if result is not None:
                        try:
                            alert = int(result)
                        except Exception:
                            import sys
                            sys.unraisablehook(_unraisable(sys.exc_info(),
                                                           result))
                            alert = ALERT_DESCRIPTION_INTERNAL_ERROR
                        verdict = ((alert & 0xffffff) << 8) | 2
        _c.SSL_set_ex_data(self._h, 0, verdict)

    def read(self, len=1024, buffer=None):
        if buffer is None:
            if len < 0:
                raise ValueError("size should not be negative")
        sock = self._get_socket()
        if buffer is None:
            if len == 0:
                return b""
            n = len
        else:
            view = memoryview(buffer)
            if view.readonly:
                raise TypeError("read() argument 2 must be read-write "
                                "bytes-like object, not %s"
                                % type(buffer).__name__)
            n = len
            if n <= 0 or n > view.nbytes:
                n = view.nbytes
                if n == 0:
                    return 0
        dl = _Deadline(sock)
        data = b""
        while True:
            got = _c.SSL_read(self._h, n)
            if isinstance(got, bytes):
                self._record(False, 0)
                data = got
                break
            err_ssl = self._record(True, got)
            if (err_ssl == SSL_ERROR_ZERO_RETURN
                    and _c.SSL_get_shutdown(self._h)
                    == _SSL_RECEIVED_SHUTDOWN):
                data = b""
                break
            if not self._wait(sock, err_ssl, dl, "read"):
                raise self._set_error(got)
        if buffer is None:
            return data
        k = data.__len__()
        view = memoryview(buffer).cast('B')
        view[:k] = data
        return k

    def write(self, b):
        data = bytes(memoryview(b))
        sock = self._get_socket()
        dl = _Deadline(sock)
        state = _select(sock, True, dl.left())
        if state == _SOCKET_HAS_TIMED_OUT:
            raise TimeoutError("The write operation timed out")
        if state == _SOCKET_HAS_BEEN_CLOSED:
            raise SSLError("Underlying socket has been closed.")
        if len(data) > 0x7fffffff:
            raise OverflowError("string longer than 2147483647 bytes")
        while True:
            ret = _c.SSL_write(self._h, data)
            if data == b"" and ret <= 0 and _c.SSL_is_init_finished(self._h):
                # SSL_write_ex writes nothing and succeeds; SSL_write calls
                # that an error.  CPython calls the former.
                _c.ERR_clear_error()
                self._record(False, 0)
                return 0
            err_ssl = self._record(ret <= 0, ret)
            if ret > 0:
                return ret
            if not self._wait(sock, err_ssl, dl, "write"):
                raise self._set_error(ret)

    def pending(self):
        count = _c.SSL_pending(self._h)
        if count < 0:
            self._record(True, count)
            raise self._set_error(count)
        return count

    def shutdown(self):
        sock = None
        if self._socket is not None:
            sock = self._socket()
            if sock is None or sock.fileno() == -1:
                raise _ssl_error("Underlying socket connection gone")
        dl = _Deadline(sock)
        zeros = 0
        while True:
            if self._shutdown_seen_zero:
                _c.SSL_ctrl(self._h, _CTRL_SET_READ_AHEAD, 0, None)
            ret = _c.SSL_shutdown(self._h)
            err_ssl = self._record(ret < 0, ret)
            if ret > 0:
                break
            if ret == 0:
                zeros += 1
                if zeros > 1:
                    break
                self._shutdown_seen_zero = True
                continue
            if err_ssl == SSL_ERROR_WANT_READ:
                state = _select(sock, False, dl.left())
            elif err_ssl == SSL_ERROR_WANT_WRITE:
                state = _select(sock, True, dl.left())
            else:
                break
            if state == _SOCKET_HAS_TIMED_OUT:
                if err_ssl == SSL_ERROR_WANT_READ:
                    raise TimeoutError("The read operation timed out")
                raise TimeoutError("The write operation timed out")
            if state != _SOCKET_OPERATION_OK:
                break
        if ret < 0:
            raise self._set_error(ret)
        return sock

    # --- what was negotiated

    def getpeercert(self, der=False):
        if not _c.SSL_is_init_finished(self._h):
            raise ValueError("handshake not done yet")
        x = _c.SSL_get1_peer_certificate(self._h)
        if x is None:
            return None
        try:
            if der:
                return _x509_der(x)
            if (_c.SSL_CTX_get_verify_mode(self._ctx._h)
                    & _SSL_VERIFY_PEER) == 0:
                return {}
            return _decode_der(_x509_der(x))
        finally:
            _c.free(x)

    def get_verified_chain(self):
        chain = _c.SSL_get0_verified_chain(self._h)
        if chain is None:
            return None
        return _certs_from_stack(chain)

    def get_unverified_chain(self):
        chain = _c.SSL_get_peer_cert_chain(self._h)
        if chain is None:
            return None
        certs = _certs_from_stack(chain)
        if self._server_side:
            # OpenSSL leaves the peer's own certificate out on this side.
            x = _c.SSL_get1_peer_certificate(self._h)
            if x is None:
                certs.insert(0, None)
            else:
                try:
                    certs.insert(0, Certificate._new(_x509_der(x)))
                finally:
                    _c.free(x)
        return certs

    def cipher(self):
        if self._h is None:
            return None
        cur = _c.SSL_get_current_cipher(self._h)
        if cur is None:
            return None
        with _Borrowed(cur) as h:
            return _cipher_to_tuple(h)

    def shared_ciphers(self):
        server = _c.SSL_get_ciphers(self._h)
        if server is None:
            return None
        client = _c.SSL_get_client_ciphers(self._h)
        if client is None:
            _c.free(server)
            return None
        s_items = _stack_items(server)
        c_items = _stack_items(client)
        try:
            ids = set(_c.SSL_CIPHER_get_id(h) for h in c_items)
            return [_cipher_to_tuple(h) for h in s_items
                    if _c.SSL_CIPHER_get_id(h) in ids]
        finally:
            _free_all(s_items + c_items + [server, client])

    def version(self):
        if self._h is None or not _c.SSL_is_init_finished(self._h):
            return None
        v = _c.SSL_get_version(self._h)
        if v == "unknown":
            return None
        return v

    def selected_alpn_protocol(self):
        out = _c.SSL_get0_alpn_selected(self._h)
        if out is None:
            return None
        return out.decode('utf-8', 'surrogateescape')

    def compression(self):
        return None

    def get_channel_binding(self, cb_type="tls-unique"):
        if cb_type != "tls-unique":
            raise ValueError("'%s' channel binding type not implemented"
                             % (cb_type,))
        if bool(_c.SSL_session_reused(self._h)) ^ (not self._server_side):
            got = _c.SSL_get_finished(self._h, 64)
        else:
            got = _c.SSL_get_peer_finished(self._h, 64)
        if not isinstance(got, bytes) or not got:
            return None
        return got

    def verify_client_post_handshake(self):
        if _c.SSL_verify_client_post_handshake(self._h) == 0:
            raise _ssl_error()
        return None




def _parse_sni(ext):
    """The host name in a client hello's server_name extension, or None."""
    if not ext or len(ext) < 5:
        return None
    total = (ext[0] << 8) | ext[1]
    pos = 2
    end = min(len(ext), 2 + total)
    while pos + 3 <= end:
        kind = ext[pos]
        n = (ext[pos + 1] << 8) | ext[pos + 2]
        pos += 3
        name = ext[pos:pos + n]
        pos += n
        if kind == 0:
            try:
                return name.decode('ascii')
            except UnicodeDecodeError:
                return None
    return None


class _UnraisableHookArgs:
    def __init__(self, exc_info, obj):
        self.exc_type, self.exc_value, self.exc_traceback = exc_info
        self.err_msg = None
        self.object = obj


def _unraisable(exc_info, obj):
    return _UnraisableHookArgs(exc_info, obj)


# --- certificates ------------------------------------------------------------

def _certs_from_stack(stack_h):
    """A borrowed STACK_OF(X509) as a list of Certificate; frees the handle."""
    items = _stack_items(stack_h)
    try:
        return [Certificate._new(_x509_der(x)) for x in items]
    finally:
        _free_all(items + [stack_h])


def _der_to_pem(der):
    import binascii
    b64 = binascii.b2a_base64(der, newline=False).decode('ascii')
    lines = [b64[i:i + 64] for i in range(0, len(b64), 64)]
    return ("-----BEGIN CERTIFICATE-----\n" + "\n".join(lines)
            + "\n-----END CERTIFICATE-----\n")


class Certificate(metaclass=_ImmutableType):
    """One X.509 certificate of a chain, held as its DER."""

    __module__ = '_ssl'
    _frozen_ = True

    def __new__(cls, *args, **kwargs):
        raise TypeError("cannot create '_ssl.Certificate' instances")

    @classmethod
    def _new(cls, der):
        self = object.__new__(cls)
        self._der = der
        return self

    def public_bytes(self, format=ENCODING_PEM):
        if format == ENCODING_DER:
            return self._der
        if format in (ENCODING_PEM, 0x101):
            return _der_to_pem(self._der)
        raise ValueError("Unsupported format")

    def get_info(self):
        return _decode_der(self._der)

    def __eq__(self, other):
        if not isinstance(other, Certificate):
            return NotImplemented
        return self._der == other._der

    def __ne__(self, other):
        if not isinstance(other, Certificate):
            return NotImplemented
        return self._der != other._der

    def __hash__(self):
        return hash(self._der)

    def __repr__(self):
        return "<_ssl.Certificate '%s'>" % (_rfc2253(self._der),)


def _rfc2253(der):
    """X509_NAME_print_ex(XN_FLAG_RFC2253) of the subject: last RDN first."""
    buf = memoryview(der)
    _t, cs, ce = _der_read(buf, 0)
    _t, ts, te = _der_read(buf, cs)
    fields = _der_children(buf, ts, te)
    i = 1 if fields[0][0] == 0xa0 else 0
    _st, ss, se = fields[i + 4]
    rdns = []
    for _r, rs, re_ in _der_children(buf, ss, se):
        parts = []
        for _a, as_, ae in _der_children(buf, rs, re_):
            (_o, os_, oe), (vtag, vs, ve) = _der_children(buf, as_, ae)
            dotted = _oid_text(buf[os_:oe])
            nid = _c.OBJ_txt2nid(dotted)
            key = (_c.OBJ_nid2sn(nid) if nid else None) or dotted
            val = _string_value(vtag, bytes(buf[vs:ve]))
            val = "".join("\\" + ch if ch in ',+"\\<>;' else ch
                          for ch in val)
            parts.append("%s=%s" % (key, val))
        rdns.append("+".join(parts))
    return ",".join(reversed(rdns))


# --- memory BIOs ------------------------------------------------------------

class MemoryBIO(metaclass=_ImmutableType):
    """A buffer OpenSSL reads from or writes to, in place of a socket."""

    __module__ = '_ssl'
    _frozen_ = True

    def __init__(self):
        h = _c.BIO_new(_M_BIO_MEM)
        if h is None:
            raise MemoryError("failed to allocate BIO")
        # Reading an empty BIO is "retry", not EOF, until write_eof().
        _c.BIO_ctrl(h, _BIO_C_SET_BUF_MEM_EOF_RETURN, -1, None)
        self._h = h
        self._eof_written = False

    def __del__(self):
        h = getattr(self, '_h', None)
        if h is not None:
            self._h = None
            _c.free(h)

    @property
    def pending(self):
        return _c.BIO_ctrl_pending(self._h)

    @property
    def eof(self):
        return _c.BIO_ctrl_pending(self._h) == 0 and self._eof_written

    def read(self, size=-1):
        avail = _c.BIO_ctrl_pending(self._h)
        n = avail if (size < 0 or size > avail) else size
        if n == 0:
            return b""
        got = _c.BIO_read(self._h, n)
        if not isinstance(got, bytes):
            raise _ssl_error()
        return got

    def write(self, b):
        view = memoryview(b)
        if not view.c_contiguous:
            raise BufferError("memoryview: underlying buffer is not "
                              "C-contiguous")
        if view.nbytes > 0x7fffffff:
            raise OverflowError("string longer than 2147483647 bytes")
        if self._eof_written:
            raise _fill_error(None, SSLError, 0,
                              "cannot write() after write_eof()", 0)
        data = view.tobytes()
        if not data:
            return 0
        n = _c.BIO_write(self._h, data)
        if n < 0:
            raise _ssl_error()
        return n

    def write_eof(self):
        self._eof_written = True
        _c.BIO_clear_flags(self._h, _BIO_FLAGS_RETRY)
        _c.BIO_ctrl(self._h, _BIO_C_SET_BUF_MEM_EOF_RETURN, 0, None)




# --- sessions ---------------------------------------------------------------

class SSLSession(metaclass=_ImmutableType):
    """A TLS session, to resume on another connection."""

    __module__ = '_ssl'
    _frozen_ = True

    __hash__ = None

    def __new__(cls, *args, **kwargs):
        raise TypeError("cannot create '_ssl.SSLSession' instances")

    @classmethod
    def _new(cls, ctx, h):
        self = object.__new__(cls)
        self._ctx = ctx
        self._h = h
        return self

    def __del__(self):
        h = getattr(self, '_h', None)
        if h is not None:
            self._h = None
            _c.free(h)

    def __eq__(self, other):
        if not isinstance(other, SSLSession):
            return NotImplemented
        return self.id == other.id

    def __ne__(self, other):
        if not isinstance(other, SSLSession):
            return NotImplemented
        return self.id != other.id

    @property
    def time(self):
        return _c.SSL_SESSION_get_time(self._h)

    @property
    def timeout(self):
        return _c.SSL_SESSION_get_timeout(self._h)

    @property
    def ticket_lifetime_hint(self):
        return _c.SSL_SESSION_get_ticket_lifetime_hint(self._h)

    @property
    def id(self):
        got = _c.SSL_SESSION_get_id(self._h)
        return b"" if got is None else got

    @property
    def has_ticket(self):
        return bool(_c.SSL_SESSION_has_ticket(self._h))




# --- module functions -------------------------------------------------------

def RAND_status():
    return bool(_c.RAND_status())


def RAND_add(string, entropy):
    if isinstance(string, str):
        string = string.encode('utf-8')
    data = bytes(memoryview(string))
    float(entropy)
    if data:
        _c.RAND_seed(data)
    return None


def RAND_bytes(n):
    n = _as_int(n)
    if n < 0:
        raise ValueError("num must be positive")
    if n == 0:
        return b""
    got = _c.RAND_bytes(n)
    if not isinstance(got, bytes):
        raise _ssl_error()
    return got


def get_default_verify_paths():
    return (_c.X509_get_default_cert_file_env(),
            _c.X509_get_default_cert_file(),
            _c.X509_get_default_cert_dir_env(),
            _c.X509_get_default_cert_dir())


def _obj_text(obj_h, no_name):
    got = _c.OBJ_obj2txt(256, obj_h, 1 if no_name else 0)
    if not isinstance(got, bytes):
        if got == 0 and no_name:
            return None
        if got == 0:
            return ""
        raise _ssl_error()
    return got.decode('ascii', 'replace')


def _asn1obj2py(obj_h):
    nid = _c.OBJ_obj2nid(obj_h)
    if nid == 0:
        raise ValueError("Unknown object")
    return (nid, _c.OBJ_nid2sn(nid), _c.OBJ_nid2ln(nid),
            _obj_text(obj_h, True))


def txt2obj(txt, name=False):
    if not isinstance(txt, str):
        raise TypeError("txt2obj() argument 'txt' must be str, not %s"
                        % type(txt).__name__)
    if '\0' in txt:
        raise ValueError("embedded null character")
    obj = _c.OBJ_txt2obj(txt, 0 if name else 1)
    if obj is None:
        _c.ERR_clear_error()
        raise ValueError("unknown object '%.100s'" % txt)
    try:
        return _asn1obj2py(obj)
    finally:
        _c.ASN1_OBJECT_free(obj)
        _c.free(obj)


def nid2obj(nid):
    nid = _as_int(nid)
    if nid < 1:
        raise ValueError("NID must be positive.")
    obj = _c.OBJ_nid2obj(nid)
    if obj is None:
        _c.ERR_clear_error()
        raise ValueError("unknown NID %i" % nid)
    try:
        return _asn1obj2py(obj)
    finally:
        _c.free(obj)


def _test_decode_cert(path):
    bpath = _fspath_bytes(path, "path")
    bio = _c.BIO_new_file(bpath, b"r")
    if bio is None:
        _c.ERR_clear_error()
        raise SSLError("Can't open file")
    try:
        x = _c.PEM_read_bio_X509(bio, None, -1, None)
    finally:
        _c.free(bio)
    if x is None:
        _c.ERR_clear_error()
        raise SSLError("Error decoding PEM-encoded file")
    try:
        return _decode_der(_x509_der(x))
    finally:
        _c.free(x)


# --- the certificate, from its DER -------------------------------------------
#
# Just enough of X.690 to walk an X.509 certificate: tag, length, contents,
# and the handful of universal types a name or an extension uses.  It builds
# the dict _decode_certificate does, field for field and in the same order.

class _DERError(ValueError):
    pass


def _der_read(buf, pos):
    """(tag, contents start, contents end) of the element at pos."""
    if pos + 2 > len(buf):
        raise _DERError("truncated")
    tag = buf[pos]
    pos += 1
    if tag & 0x1f == 0x1f:
        while buf[pos] & 0x80:
            pos += 1
        pos += 1
    n = buf[pos]
    pos += 1
    if n & 0x80:
        k = n & 0x7f
        if k == 0 or k > 4:
            raise _DERError("bad length")
        n = int.from_bytes(buf[pos:pos + k], 'big')
        pos += k
    end = pos + n
    if end > len(buf):
        raise _DERError("truncated")
    return tag, pos, end


def _der_children(buf, start, end):
    out = []
    pos = start
    while pos < end:
        tag, s, e = _der_read(buf, pos)
        out.append((tag, s, e))
        pos = e
    return out


def _oid_text(content):
    """The dotted form of an OBJECT IDENTIFIER's contents."""
    arcs = []
    v = 0
    for b in content:
        v = (v << 7) | (b & 0x7f)
        if not b & 0x80:
            arcs.append(v)
            v = 0
    if not arcs:
        return ""
    first = arcs[0]
    if first < 40:
        head = [0, first]
    elif first < 80:
        head = [1, first - 40]
    else:
        head = [2, first - 80]
    return ".".join(str(a) for a in head + arcs[1:])


_oid_name_cache = {}


def _oid_name(content):
    """OBJ_obj2txt(no_name=0): the long name, else the short, else dotted."""
    key = bytes(content)
    got = _oid_name_cache.get(key)
    if got is None:
        dotted = _oid_text(content)
        nid = _c.OBJ_txt2nid(dotted)
        got = None
        if nid:
            got = _c.OBJ_nid2ln(nid) or _c.OBJ_nid2sn(nid)
        if got is None:
            _c.ERR_clear_error()
            got = dotted
        _oid_name_cache[key] = got
    return got


def _string_value(tag, content):
    """ASN1_STRING_to_UTF8, for the string types a name can hold."""
    if tag == 0x1e:                         # BMPString
        return content.decode('utf-16-be')
    if tag == 0x1c:                         # UniversalString
        return content.decode('utf-32-be')
    if tag in (0x14, 0x15):                 # T61String / VideotexString
        return content.decode('latin-1')
    if tag == 0x0c:                         # UTF8String
        return content.decode('utf-8', 'surrogateescape')
    return content.decode('latin-1')


def _name_tuple(buf, start, end):
    """_create_tuple_for_X509_NAME"""
    dn = []
    for tag, s, e in _der_children(buf, start, end):        # each RDN (SET)
        rdn = []
        for _t, s2, e2 in _der_children(buf, s, e):         # each attribute
            parts = _der_children(buf, s2, e2)
            otag, os_, oe = parts[0]
            vtag, vs, ve = parts[1]
            name = _oid_name(buf[os_:oe])
            if vtag == 0x03:
                rdn.append((name, bytes(buf[vs + 1:ve])))
            else:
                rdn.append((name, _string_value(vtag, bytes(buf[vs:ve]))))
        if rdn:
            dn.append(tuple(rdn))
    return tuple(dn)


_MONTHS = ("Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep",
           "Oct", "Nov", "Dec")


def _time_text(tag, content):
    """ASN1_TIME_print"""
    s = content.decode('ascii')
    if tag == 0x17:                         # UTCTime
        yy = int(s[0:2])
        year = 2000 + yy if yy < 50 else 1900 + yy
        rest = s[2:]
    else:                                   # GeneralizedTime
        year = int(s[0:4])
        rest = s[4:]
    month = int(rest[0:2])
    day = int(rest[2:4])
    hour = int(rest[4:6])
    minute = int(rest[6:8])
    sec = int(rest[8:10]) if rest[8:10].isdigit() else 0
    tail = rest[10:]
    frac = ""
    if tag != 0x17 and tail.startswith('.'):
        i = 1
        while i < len(tail) and tail[i].isdigit():
            i += 1
        frac = tail[:i]
        tail = tail[i:]
    gmt = " GMT" if tail.endswith('Z') else ""
    return "%s %2d %02d:%02d:%02d%s %d%s" % (_MONTHS[month - 1], day, hour,
                                             minute, sec, frac, year, gmt)


def _serial_text(content):
    """i2a_ASN1_INTEGER"""
    v = int.from_bytes(content, 'big', signed=True)
    mag = -v if v < 0 else v
    text = "%X" % mag
    if len(text) % 2:
        text = "0" + text
    return ("-" if v < 0 else "") + text


def _general_name(buf, tag, s, e):
    """One GeneralName, as _get_peer_alt_names renders it."""
    kind = tag & 0x1f
    if kind == 1:
        return ("email", bytes(buf[s:e]).decode('latin-1'))
    if kind == 2:
        return ("DNS", bytes(buf[s:e]).decode('latin-1'))
    if kind == 6:
        return ("URI", bytes(buf[s:e]).decode('latin-1'))
    if kind == 4:
        _t, ns, ne = _der_read(buf, s)
        return ("DirName", _name_tuple(buf, ns, ne))
    if kind == 7:
        p = bytes(buf[s:e])
        if len(p) == 4:
            return ("IP Address", "%d.%d.%d.%d" % tuple(p))
        if len(p) == 16:
            return ("IP Address", ":".join(
                "%X" % ((p[i] << 8) | p[i + 1]) for i in range(0, 16, 2)))
        return ("IP Address", "<invalid>")
    if kind == 8:
        return ("Registered ID", _oid_name(buf[s:e]))
    if kind == 0:
        return ("othername", "<unsupported>")
    if kind == 3:
        return ("X400Name", "<unsupported>")
    if kind == 5:
        return ("EdiPartyName", "<unsupported>")
    return None


_OID_SAN = bytes([0x55, 0x1d, 0x11])                       # 2.5.29.17
_OID_CRLDP = bytes([0x55, 0x1d, 0x1f])                     # 2.5.29.31
_OID_AIA = bytes([0x2b, 6, 1, 5, 5, 7, 1, 1])              # 1.3.6.1.5.5.7.1.1
_OID_AD_OCSP = bytes([0x2b, 6, 1, 5, 5, 7, 48, 1])
_OID_AD_CAISSUERS = bytes([0x2b, 6, 1, 5, 5, 7, 48, 2])


def _decode_der(der):
    """_decode_certificate, from the certificate's DER."""
    buf = memoryview(der)
    try:
        return _decode_cert(buf)
    except (_DERError, IndexError, ValueError, UnicodeDecodeError):
        raise SSLError("failed to decode certificate") from None


def _decode_cert(buf):
    _t, cs, ce = _der_read(buf, 0)
    tbs_tag, ts, te = _der_read(buf, cs)
    fields = _der_children(buf, ts, te)
    i = 0
    version = 0
    if fields[0][0] == 0xa0:
        _vt, vs, ve = _der_read(buf, fields[0][1])
        version = int.from_bytes(buf[vs:ve], 'big')
        i = 1
    serial = fields[i]
    issuer = fields[i + 2]
    validity = fields[i + 3]
    subject = fields[i + 4]
    exts = None
    for tag, s, e in fields[i + 6:]:
        if tag == 0xa3:
            _st, ss, se = _der_read(buf, s)
            exts = _der_children(buf, ss, se)
    retval = {}
    retval['subject'] = _name_tuple(buf, subject[1], subject[2])
    retval['issuer'] = _name_tuple(buf, issuer[1], issuer[2])
    retval['version'] = version + 1
    retval['serialNumber'] = _serial_text(bytes(buf[serial[1]:serial[2]]))
    times = _der_children(buf, validity[1], validity[2])
    retval['notBefore'] = _time_text(times[0][0],
                                     bytes(buf[times[0][1]:times[0][2]]))
    retval['notAfter'] = _time_text(times[1][0],
                                    bytes(buf[times[1][1]:times[1][2]]))
    ext_values = {}
    for _et, es, ee in exts or ():
        parts = _der_children(buf, es, ee)
        oid = bytes(buf[parts[0][1]:parts[0][2]])
        val = parts[-1]
        if oid not in ext_values:
            ext_values[oid] = (val[1], val[2])
    if _OID_SAN in ext_values:
        s, e = ext_values[_OID_SAN]
        _st, ss, se = _der_read(buf, s)
        names = []
        for tag, gs, ge in _der_children(buf, ss, se):
            got = _general_name(buf, tag, gs, ge)
            if got is not None:
                names.append(got)
        retval['subjectAltName'] = tuple(names)
    if _OID_AIA in ext_values:
        s, e = ext_values[_OID_AIA]
        _st, ss, se = _der_read(buf, s)
        ocsp = []
        issuers = []
        for _at, as_, ae in _der_children(buf, ss, se):
            parts = _der_children(buf, as_, ae)
            method = bytes(buf[parts[0][1]:parts[0][2]])
            ltag, ls, le = parts[1]
            if ltag & 0x1f != 6:
                continue
            uri = bytes(buf[ls:le]).decode('latin-1')
            if method == _OID_AD_OCSP:
                ocsp.append(uri)
            elif method == _OID_AD_CAISSUERS:
                issuers.append(uri)
        if ocsp:
            retval['OCSP'] = tuple(ocsp)
        if issuers:
            retval['caIssuers'] = tuple(issuers)
    if _OID_CRLDP in ext_values:
        s, e = ext_values[_OID_CRLDP]
        _st, ss, se = _der_read(buf, s)
        uris = []
        for _dt, ds, de in _der_children(buf, ss, se):
            for ftag, fs, fe in _der_children(buf, ds, de):
                if ftag != 0xa0:
                    continue        # no distributionPoint: CVE-2019-5010
                ntag, ns, ne = _der_read(buf, fs)
                if ntag != 0xa0:
                    continue        # nameRelativeToCRLIssuer
                for gtag, gs, ge in _der_children(buf, ns, ne):
                    if gtag & 0x1f == 6:
                        uris.append(bytes(buf[gs:ge]).decode('latin-1'))
        if uris:
            retval['crlDistributionPoints'] = tuple(uris)
    return retval
