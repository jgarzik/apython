"""pyexpat - the XML parser the whole of `xml` is built on.

The public half of the `_pyexpatcore`/`pyexpat` split, the same one
`_zlibcore`/`zlib` and `_hashlibcore`/`_hashlib` use.
`src/modules/pyexpat.asm` and `src/modules/pyexpat_cb.asm` do what is
genuinely C -- libexpat's parser and the 22 callback trampolines -- and
everything here is the surface CPython's `xml` package is written against.

There is no fallback for this module in 3.12.  `xml.etree` has no non-expat
builder (`SimpleXMLTreeBuilder` was removed in 3.9), `xml.sax`'s only
registered parser is `expatreader`, and `xml.dom.minidom`, `plistlib` and
`xmlrpc.client` all reach it too, so without pyexpat every one of them raises
on import or on first use.

The xmlparser object lives HERE rather than being a heaptype in assembly, and
that is a deliberate choice: CPython's `xmlparseobject` is 22 `PyObject*`, an
intern dict, three flags, a byte buffer and two counters, and exactly ONE
field of it is genuinely C -- the `XML_Parser` itself, which is what the
handle table holds.  A heaptype whose `tp_basicsize` was patched to make room
for that one field would need its own `tp_traverse` and `tp_clear`, a dealloc
that zeroes the raw fields before delegating, and would forbid `__slots__` in
any subclass (CLAUDE.md records all three).  An integer handle in an ordinary
Python object needs none of it.

The 22 handlers are held TWICE, by the core for calling and by `_handlers`
here for reading back, and both copies are load-bearing.  `expatbuilder` does
`self._old_start = parser.StartElementHandler` and puts it back afterwards, so
a handler must read back as the exact object that was set; and the
Python-side copy is what makes the parser -> bound method -> parser cycle
VISIBLE to the collector, which a malloc'd struct in a .data table is not.
All five stdlib consumers build that cycle.
"""

import sys
import types

import _pyexpatcore as _core

EXPAT_VERSION = _core.EXPAT_VERSION
native_encoding = "UTF-8"


def _parse_version(text):
    """`expat_2.6.1` -> `(2, 6, 1)`.

    From the string rather than from `XML_ExpatVersionInfo`, which returns a
    12-byte struct BY VALUE -- classified INTEGER,INTEGER, so it arrives split
    across two registers.  That is the kind of ABI assumption that is
    invisible when it is wrong; the string is unambiguous.
    """
    digits = text.rpartition("_")[2]
    parts = []
    for piece in digits.split("."):
        number = ""
        for ch in piece:
            if not ch.isdigit():
                break
            number += ch
        parts.append(int(number) if number else 0)
    while len(parts) < 3:
        parts.append(0)
    return tuple(parts[:3])


version_info = _parse_version(EXPAT_VERSION)

XML_PARAM_ENTITY_PARSING_NEVER = 0
XML_PARAM_ENTITY_PARSING_UNLESS_STANDALONE = 1
XML_PARAM_ENTITY_PARSING_ALWAYS = 2


class ExpatError(Exception):
    """The one exception pyexpat raises.

    `pyexpat.error` is the same class, not a subclass -- `xml.sax` and
    `xml.dom` both catch it under one name and check `.code` against
    `errors.codes` under the other.  `.offset` IS the column: CPython sets it
    from XML_GetErrorColumnNumber and words the message
    "%s: line %d, column %d".

    The three attributes are set on the INSTANCE when the parser raises, and
    are deliberately not class defaults: a hand-built `ExpatError("boom")` has
    no `.code` in CPython either, so supplying 0 would make `hasattr` answer
    yes where CPython answers no.
    """


error = ExpatError

# ---------------------------------------------------------------------------
# The `errors` submodule.
#
# Only the NAMES and their codes are transcribed, in the enum order from
# expat.h.  Every message comes from `_core.ErrorString`, which is
# XML_ErrorString -- so the text a program sees is the text the linked expat
# actually produces.  CPython's `add_error` does the same, and its comment
# gives the reason: a table compiled in here would drift from the library.
# ---------------------------------------------------------------------------
_ERROR_NAMES = (
    "XML_ERROR_NONE",
    "XML_ERROR_NO_MEMORY",
    "XML_ERROR_SYNTAX",
    "XML_ERROR_NO_ELEMENTS",
    "XML_ERROR_INVALID_TOKEN",
    "XML_ERROR_UNCLOSED_TOKEN",
    "XML_ERROR_PARTIAL_CHAR",
    "XML_ERROR_TAG_MISMATCH",
    "XML_ERROR_DUPLICATE_ATTRIBUTE",
    "XML_ERROR_JUNK_AFTER_DOC_ELEMENT",
    "XML_ERROR_PARAM_ENTITY_REF",
    "XML_ERROR_UNDEFINED_ENTITY",
    "XML_ERROR_RECURSIVE_ENTITY_REF",
    "XML_ERROR_ASYNC_ENTITY",
    "XML_ERROR_BAD_CHAR_REF",
    "XML_ERROR_BINARY_ENTITY_REF",
    "XML_ERROR_ATTRIBUTE_EXTERNAL_ENTITY_REF",
    "XML_ERROR_MISPLACED_XML_PI",
    "XML_ERROR_UNKNOWN_ENCODING",
    "XML_ERROR_INCORRECT_ENCODING",
    "XML_ERROR_UNCLOSED_CDATA_SECTION",
    "XML_ERROR_EXTERNAL_ENTITY_HANDLING",
    "XML_ERROR_NOT_STANDALONE",
    "XML_ERROR_UNEXPECTED_STATE",
    "XML_ERROR_ENTITY_DECLARED_IN_PE",
    "XML_ERROR_FEATURE_REQUIRES_XML_DTD",
    "XML_ERROR_CANT_CHANGE_FEATURE_ONCE_PARSING",
    "XML_ERROR_UNBOUND_PREFIX",
    "XML_ERROR_UNDECLARING_PREFIX",
    "XML_ERROR_INCOMPLETE_PE",
    "XML_ERROR_XML_DECL",
    "XML_ERROR_TEXT_DECL",
    "XML_ERROR_PUBLICID",
    "XML_ERROR_SUSPENDED",
    "XML_ERROR_NOT_SUSPENDED",
    "XML_ERROR_ABORTED",
    "XML_ERROR_FINISHED",
    "XML_ERROR_SUSPEND_PE",
    "XML_ERROR_RESERVED_PREFIX_XML",
    "XML_ERROR_RESERVED_PREFIX_XMLNS",
    "XML_ERROR_RESERVED_NAMESPACE_URI",
    "XML_ERROR_INVALID_ARGUMENT",
    "XML_ERROR_NO_BUFFER",
    "XML_ERROR_AMPLIFICATION_LIMIT_BREACH",
    "XML_ERROR_NOT_STARTED",
)


def _build_errors():
    mod = types.ModuleType("pyexpat.errors")
    mod.__doc__ = "Constants used to describe error conditions."
    codes = {}
    messages = {}
    for code, name in enumerate(_ERROR_NAMES):
        text = _core.ErrorString(code)
        if text is None:
            # A code this expat does not know about: the name is still
            # published, because a program comparing `.code` against it must
            # not get an AttributeError, but it has no message.
            setattr(mod, name, "")
            continue
        setattr(mod, name, text)
        codes[text] = code
        messages[code] = text
    mod.codes = codes
    mod.messages = messages
    return mod


errors = _build_errors()


def _build_model():
    mod = types.ModuleType("pyexpat.model")
    mod.__doc__ = "Constants used to interpret content model information."
    # XML_Content_Type starts at 1, XML_Content_Quant at 0; both from
    # expat.h, and the ElementDeclHandler's model tuples are built out of
    # them.
    mod.XML_CTYPE_EMPTY = 1
    mod.XML_CTYPE_ANY = 2
    mod.XML_CTYPE_MIXED = 3
    mod.XML_CTYPE_NAME = 4
    mod.XML_CTYPE_CHOICE = 5
    mod.XML_CTYPE_SEQ = 6
    mod.XML_CQUANT_NONE = 0
    mod.XML_CQUANT_OPT = 1
    mod.XML_CQUANT_REP = 2
    mod.XML_CQUANT_PLUS = 3
    return mod


model = _build_model()

# `xml.parsers.expat` does `from pyexpat import *` and then refers to `model`
# and `errors` by bare name, so both have to survive the star import; the core
# is bound as `_core`, which a star import skips for the leading underscore.
# No __all__ is defined, deliberately, for the same reason CPython defines
# none: the star import is the documented way in.

_HANDLER_NAMES = (
    "StartElementHandler",
    "EndElementHandler",
    "ProcessingInstructionHandler",
    "CharacterDataHandler",
    "UnparsedEntityDeclHandler",
    "NotationDeclHandler",
    "StartNamespaceDeclHandler",
    "EndNamespaceDeclHandler",
    "CommentHandler",
    "StartCdataSectionHandler",
    "EndCdataSectionHandler",
    "DefaultHandler",
    "DefaultHandlerExpand",
    "NotStandaloneHandler",
    "ExternalEntityRefHandler",
    "StartDoctypeDeclHandler",
    "EndDoctypeDeclHandler",
    "EntityDeclHandler",
    "XmlDeclHandler",
    "ElementDeclHandler",
    "AttlistDeclHandler",
    "SkippedEntityHandler",
)

# The index each name has in the core.  CPython's `handler_info[]` order is the
# source of truth for this AND for the enum in src/include/pyexpat.inc, and the
# two must not drift: the core bounds-checks the index, so a mismatch is a
# wrong handler rather than a wild call -- but a wrong handler has no symptom
# anywhere near its cause.
_HANDLER_INDEX = {name: i for i, name in enumerate(_HANDLER_NAMES)}

# The seven numbers parser_status answers with, and which slot each comes from.
# ErrorLineNumber and CurrentLineNumber are the SAME libexpat getter read at
# different times -- expat.h defines the Error* names as macros for the
# Current* ones, so there is nothing else they could be.
_STATUS_INDEX = {
    "ErrorCode": 0,
    "ErrorLineNumber": 1,
    "ErrorColumnNumber": 2,
    "ErrorByteIndex": 3,
    "CurrentLineNumber": 1,
    "CurrentColumnNumber": 2,
    "CurrentByteIndex": 3,
    "buffer_used": 4,
    "buffer_size": 5,
    "buffer_text": 6,
}

_FLAG_INDEX = {
    "ordered_attributes": 0,
    "specified_attributes": 1,
    "namespace_prefixes": 2,
    "buffer_text": 3,
    "buffer_size": 4,
    "reparse_deferral": 5,
}


class xmlparser:
    """The parser object, with libexpat's parser held as an integer handle."""

    __slots__ = ("_h", "_handlers", "_intern",
                 "_ordered", "_specified", "_nsprefixes", "_reparse")

    def __init__(self, encoding=None, namespace_separator=None, intern=None):
        # object.__setattr__ throughout, because __setattr__ REFUSES every
        # private name: `PxHandle.handlers` borrows and `_handlers` is the only
        # owner, so `p._handlers = [None]*22` dropped the last reference while
        # the core kept calling the pointer -- a use-after-free that reached a
        # recycled object.  CPython's parser has no such attribute to rebind.
        set = object.__setattr__
        set(self, "_handlers", [None] * len(_HANDLER_NAMES))
        set(self, "_intern", intern)
        set(self, "_ordered", False)
        set(self, "_specified", False)
        set(self, "_nsprefixes", False)
        # libexpat has no XML_GetReparseDeferralEnabled -- only the setter --
        # so the state is kept here, as CPython keeps it on the object.
        set(self, "_reparse", version_info >= (2, 6, 0))
        set(self, "_h", _core.parser_new(encoding, namespace_separator, intern))

    # -- attributes ---------------------------------------------------------
    #
    # __getattr__ rather than 22 properties: it is reached only when normal
    # lookup fails, which for a slotted class with no class attribute of that
    # name is every handler and every computed attribute.  Properties would
    # mean 22 descriptor objects per process and a tp_dict entry each.

    def __getattr__(self, name):
        index = _HANDLER_INDEX.get(name)
        if index is not None:
            return self._handlers[index]
        index = _STATUS_INDEX.get(name)
        if index is not None:
            return _core.parser_status(self._h)[index]
        if name == "intern":
            return self._intern
        if name == "ordered_attributes":
            return self._ordered
        if name == "specified_attributes":
            return self._specified
        if name == "namespace_prefixes":
            return self._nsprefixes
        raise AttributeError(
            # CPython's is a C type whose tp_name is the QUALIFIED name, and
            # that is what its message says; type().__name__ is still the bare
            # last component on both sides.
            "'pyexpat.xmlparser' object has no attribute %r" % (name,))

    # -- parsing ------------------------------------------------------------

    def GetReparseDeferralEnabled(self, /):
        """Return whether Expat defers retrying incomplete tokens."""
        return self._reparse

    def SetReparseDeferralEnabled(self, enabled, /):
        """Set whether Expat defers retrying incomplete tokens."""
        enabled = _core.parser_set_flag(
            self._h, _FLAG_INDEX["reparse_deferral"], int(bool(enabled)))
        object.__setattr__(self, "_reparse", enabled)

    def Parse(self, data, isfinal=False):
        """Feed a chunk of the document.

        The core answers three different things and they are three different
        things: 1 for a clean parse, 0 when libexpat reported an error and
        NOTHING is pending, and None -- a NULL Value -- when a HANDLER raised,
        in which case the exception is already on its way out and there is
        nothing to do here but return.

        That split is why there is no `except ValueError` anywhere near this.
        `plistlib`'s handler raises InvalidFileException, `expatreader`'s raise
        SAXException and ElementTree's target raises ParseError; a converting
        handler here would swallow whichever of them happened to be a
        ValueError and report an ExpatError instead.
        """
        status = _core.parser_parse(self._h, data, isfinal)
        if status == 1:
            return 1
        self._raise_parse_error()

    def _raise_parse_error(self):
        code, lineno, column = _core.parser_status(self._h)[:3]
        raise _expat_error(code, lineno, column)

    def ParseFile(self, file):
        """Parse a whole file-like object, a chunk at a time.

        Keep Expat's character buffer between reads and deliver it at EOF.
        """
        try:
            read = file.read
        except AttributeError:
            raise TypeError("argument must have 'read' attribute") from None
        while True:
            chunk = read(2048)
            if not isinstance(chunk, (bytes, bytearray)):
                raise TypeError("read() did not return a bytes object (type=%s)"
                                % type(chunk).__name__)
            if type(chunk) is bytes:
                size = len(chunk)
            else:
                view = memoryview(chunk)
                size = view.nbytes
                # Own a stable snapshot across callbacks for mutable input.
                if isinstance(chunk, bytearray) and size <= 2048:
                    chunk = bytes(view)
                view.release()
            if size > 2048:
                raise ValueError("read() returned too much data: "
                                 "2048 bytes requested, %d returned" % size)
            final = size == 0
            if _core.parser_parse(self._h, chunk, final, final) == 0:
                self._raise_parse_error()
            if final:
                return 1

    def __setattr__(self, name, value):
        if not isinstance(name, str):
            raise TypeError("attribute name must be string, not '%s'"
                            % type(name).__name__)
        if name.startswith("_"):
            # Refused, not forwarded.  `_handlers` owns the references the
            # core BORROWS, and `_h` is the handle it dereferences; rebinding
            # either is a use-after-free rather than a mistake the caller pays
            # for.  __init__ goes through object.__setattr__ directly.
            raise AttributeError(
                "'pyexpat.xmlparser' object attribute %r is read-only"
                % (name,))
        index = _HANDLER_INDEX.get(name)
        if index is not None:
            # The core is told FIRST and BORROWS; this list OWNS.  An owning
            # reference in the core's malloc'd struct is invisible to the
            # collector, which made every parser -> bound method -> parser
            # cycle look externally reachable and leaked all of them -- the
            # shape all five stdlib consumers build.  Telling the core first
            # means the pointer it holds is always to an object something else
            # owns: the caller's reference now, this list's in a moment.
            _core.parser_set_handler(self._h, index, value)
            self._handlers[index] = value
            return
        if name == "buffer_text":
            _core.parser_set_flag(self._h, _FLAG_INDEX[name], int(bool(value)))
            return
        if name in ("ordered_attributes",
                    "specified_attributes", "namespace_prefixes"):
            flag = bool(value)
            object.__setattr__(self, _FLAG_SLOT[name], flag)
            # The trampolines read these while building their arguments, so
            # the core needs its own copy -- it must not cross back into
            # Python to ask.  This side keeps one so the attribute reads back
            # as a real bool rather than as the int the core stores.
            _core.parser_set_flag(self._h, _FLAG_INDEX[name], int(flag))
            return
        if name == "buffer_size":
            if not isinstance(value, int):
                raise TypeError("buffer_size must be an integer")
            _core.parser_set_flag(self._h, _FLAG_INDEX["buffer_size"], value)
            return
        # Anything else is refused, and that arm is load-bearing:
        # `xmlrpc.client` and `expatreader` both do
        # `try: parser.buffer_text = True / except AttributeError: pass`, and
        # ElementTree probes `parser.ordered_attributes` the same way.  The
        # read-only attributes -- intern, ErrorCode, the Current* family,
        # buffer_used -- land here too.
        raise AttributeError(
            # CPython's is a C type whose tp_name is the QUALIFIED name, and
            # that is what its message says; type().__name__ is still the bare
            # last component on both sides.
            "'pyexpat.xmlparser' object has no attribute %r" % (name,))

    def __del__(self):
        # A __del__ runs on a path the collector chooses, and _h may already
        # be gone if this object was reached through a cycle whose tp_clear
        # ran first.  The core tolerates a stale index; lib/zlib.py's __del__
        # is defensive here for the same reason.
        try:
            _core.parser_free(self._h)
        except Exception:
            pass


_FLAG_SLOT = {
    "ordered_attributes": "_ordered",
    "specified_attributes": "_specified",
    "namespace_prefixes": "_nsprefixes",
}

XMLParserType = xmlparser


def ParserCreate(encoding=None, namespace_separator=None, intern=None):
    """Return a new XML parser object."""
    if encoding is not None and not isinstance(encoding, str):
        raise TypeError("ParserCreate() argument 'encoding' must be str or "
                        "None, not " + type(encoding).__name__)
    if namespace_separator is not None:
        if not isinstance(namespace_separator, str):
            raise TypeError("ParserCreate() argument 'namespace_separator' "
                            "must be str or None, not "
                            + type(namespace_separator).__name__)
        if len(namespace_separator) > 1:
            raise ValueError("namespace_separator must be at most one "
                             "character, omitted, or None")
        # An EMPTY separator is legal and is NOT the same as None: it still
        # builds a namespace-aware parser, joining uri and local name with a
        # NUL.  CPython accepts it, so the core has to be told the difference
        # between "" and absent.
    if intern is None:
        # CPython gives every parser an intern dict of its own unless one is
        # passed, and `expatbuilder` reaches into it with
        # `parser.intern.setdefault(...)`, so it has to be a real dict.
        intern = {}
    return xmlparser(encoding, namespace_separator, intern)


def ErrorString(code):
    """The message expat gives for an error code."""
    return _core.ErrorString(code)


def _expat_error(code, lineno, column):
    """The ExpatError libexpat's own failures become.

    CPython's wording, from pyexpat.c's set_error: "%s: line %d, column %d",
    and `.offset` IS the column -- there is no separate byte offset in the
    message.
    """
    err = ExpatError("%s: line %d, column %d"
                     % (_core.ErrorString(code) or "unknown error",
                        lineno, column))
    err.code = code
    err.lineno = lineno
    err.offset = column
    return err
