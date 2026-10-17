"""_warnings - the warning machinery's C half.

CPython's is C so that the interpreter itself can warn before `warnings` is
importable, and so that the filter list can be consulted from the eval loop.
Neither applies here: nothing in this interpreter raises a warning from
assembly, and `warnings` is an ordinary module.

What is left is the interface `importlib._bootstrap` and `warnings` expect --
the filter list, the default action, the once-registry and `warn` itself --
so that a module which reaches for it finds it rather than falling back.
CPython's `warnings.py` does have that fallback; `importlib._bootstrap`'s
_setup does not, and twenty-one modules of the standard library stop there.
"""

filters = []
_defaultaction = "default"
_onceregistry = {}
_filters_version = 1


def _filters_mutated():
    global _filters_version
    _filters_version += 1


def _is_ignored(category, action):
    return action == "ignore"


def _match(pattern, text):
    """A filter's message and module patterns are compiled regexes in
    CPython; here `None` means "everything", which is what every filter this
    tree installs uses, and anything else is compared with `re.match` when re
    is importable and by equality when it is not."""
    if pattern is None:
        return True
    try:
        return pattern.match(text) is not None
    except AttributeError:
        return pattern == text


def _live(name, fallback):
    """The value `warnings` currently has for `name`, not the one here.

    `catch_warnings.__enter__` does `warnings.filters = warnings.filters[:]`
    -- it REBINDS the attribute rather than mutating the list -- so inside
    such a block `warnings.filters` and this module's `filters` are two
    different lists, and every simplefilter() call goes into the one this
    module was not reading.  The whole error action was therefore dead inside
    a catch_warnings block, which is how every test suite asserts a warning.

    CPython's C half re-reads the attribute off the warnings module on every
    warning -- `get_warnings_attr(interp, &_Py_ID(filters), ...)` -- and that
    dynamic lookup is exactly what makes the rebinding work.  This is the same
    thing, and warn_explicit already reached for `showwarning` this way.

    The module's own value is the fallback, for the window before `warnings`
    has finished importing: `importlib._bootstrap` can warn during it.
    """
    import sys
    mod = sys.modules.get("warnings")
    if mod is None:
        return fallback
    return getattr(mod, name, fallback)


def _find_action(message, category, module, lineno):
    for item in _live("filters", filters):
        action, msg, cat, mod, ln = item
        if ((msg is None or _match(msg, str(message)))
                and (cat is None or issubclass(category, cat))
                and (mod is None or _match(mod, module))
                and (ln == 0 or lineno == ln)):
            return action
    return _live("defaultaction", _defaultaction)


def _is_internal_filename(filename):
    return 'importlib' in filename and '_bootstrap' in filename


def _is_filename_to_skip(filename, skip_file_prefixes):
    return any(filename.startswith(prefix) for prefix in skip_file_prefixes)


def _next_external_frame(frame, skip_file_prefixes):
    """The next frame out that is neither importlib's nor one to skip."""
    frame = frame.f_back
    while frame is not None and (
            _is_internal_filename(filename := frame.f_code.co_filename) or
            _is_filename_to_skip(filename, skip_file_prefixes)):
        frame = frame.f_back
    return frame


def _caller(stacklevel, skip_file_prefixes=()):
    """Where the warning is being reported FROM, as CPython's warn() finds it.

    stacklevel frames out from warn()'s caller -- which is what puts a
    deprecation on the line that used the deprecated thing -- except that
    importlib's own frames do not count, nor any under skip_file_prefixes:
    a module that warns at import time is reporting on the line that
    imported it, not on _bootstrap's.  Called from warn() itself, so frame 2
    here is warn()'s caller.
    """
    import sys
    try:
        if stacklevel <= 1 or _is_internal_filename(
                sys._getframe(2).f_code.co_filename):
            frame = sys._getframe(stacklevel + 1)
        else:
            frame = sys._getframe(2)
            for _ in range(stacklevel - 1):
                frame = _next_external_frame(frame, skip_file_prefixes)
                if frame is None:
                    raise ValueError
    except ValueError:
        return "sys", 1, "sys", sys.__dict__.setdefault(
            "__warningregistry__", {})
    globals_ = frame.f_globals
    filename = frame.f_code.co_filename
    lineno = frame.f_lineno
    module = globals_.get("__name__", filename) or filename
    if module.endswith(".py"):
        module = module[:-3]
    registry = globals_.setdefault("__warningregistry__", {})
    return filename, lineno, module, registry


def _source_line(filename, lineno):
    """The line the warning is about, which CPython prints under it.

    linecache is not in this tree, so the file is read directly and any
    failure means no line -- which is also what CPython shows for a warning
    from a file it cannot open.
    """
    if not filename or lineno <= 0:
        return None
    try:
        with open(filename, "r") as fh:
            for n, text in enumerate(fh, 1):
                if n == lineno:
                    return text
    except (OSError, UnicodeDecodeError):
        return None
    return None


def warn(message, category=None, stacklevel=1, source=None, *,
         skip_file_prefixes=()):
    """Show a warning, unless a filter says not to."""
    if category is None:
        category = UserWarning if not isinstance(message, Warning) \
            else type(message)
    if isinstance(message, Warning):
        category = type(message)
    if not (isinstance(category, type) and issubclass(category, Warning)):
        raise TypeError("category must be a Warning subclass, not '%s'"
                        % (type(category).__name__,))
    if not isinstance(skip_file_prefixes, tuple):
        raise TypeError("warn() argument 'skip_file_prefixes' must be tuple, "
                        "not " + type(skip_file_prefixes).__name__)
    if skip_file_prefixes:
        stacklevel = max(2, stacklevel)
    filename, lineno, module, registry = _caller(stacklevel,
                                                 skip_file_prefixes)
    warn_explicit(message, category, filename, lineno, module, registry,
                  source=source)


def _already_warned(registry, key, should_set=False):
    """-> True when this warning has been shown under the CURRENT filters.

    The registry remembers what "once", "module" and "default" have already
    shown, and that memory has to be thrown away whenever the filters change
    -- otherwise a filter installed after a warning was seen can never show
    it, and every `with warnings.catch_warnings():` block changes the filters
    twice.  CPython stamps the registry with a version counter and CLEARS THE
    WHOLE DICT when the stamp no longer matches.

    This module wrote the stamp and never compared it, so the registry was
    permanent: a "default" filter turned on after anything had warned from
    the same line showed nothing at all, and nothing raised.
    """
    version = registry.get("version")
    if type(version) is not int or version != _filters_version:
        registry.clear()
        registry["version"] = _filters_version
    elif registry.get(key):
        return True
    if should_set:
        registry[key] = True
    return False


def warn_explicit(message, category, filename, lineno, module=None,
                  registry=None, module_globals=None, source=None):
    """The whole of the action protocol, which used to be only "ignore".

    "error" RAISES the warning, which is what a test suite turns on to make
    a deprecation fail; "once", "module" and "default" each remember what
    they have shown, in the registry the caller's globals carry.  All four
    were shown unconditionally.
    """
    import sys
    if module is None:
        module = filename
        if module and module.endswith(".py"):
            module = module[:-3]
    text = str(message)
    if isinstance(message, Warning):
        category = type(message)
    else:
        # What is SHOWN is a Warning instance, not the string: CPython wraps
        # it, and a recorded warning's .message is the instance -- which is
        # what a test reads .args off.
        message = category(text)
    key = (text, category, lineno)
    # The registry is consulted BEFORE the filters are, which is CPython's
    # order and the reason the version stamp exists at all.
    if registry is not None and _already_warned(registry, key):
        return
    action = _find_action(message, category, module, lineno)
    if action == "ignore":
        return
    if action == "error":
        if isinstance(message, Warning):
            raise message
        raise category(message)

    # "Store in the registry that we've been here, except when the action is
    # always."  The second key -- (text, category), with no line -- is what
    # makes "once" and "module" forget the line, and consulting it is what
    # suppresses the second occurrence.
    rc = 0
    if action != "always":
        if registry is not None:
            registry[key] = True
        if action == "once":
            once = registry
            if once is None:
                once = _live("onceregistry", _onceregistry)
            rc = _already_warned(once, (text, category), should_set=True)
        elif action == "module":
            if registry is not None:
                rc = _already_warned(registry, (text, category),
                                     should_set=True)
        elif action != "default":
            raise RuntimeError("Unrecognized action (%r) in warnings.filters"
                               % (action,))
    if rc:
        return
    line = _source_line(filename, lineno)
    mod = sys.modules.get("warnings")
    show = getattr(mod, "showwarning", None) if mod is not None else None
    if show is not None:
        try:
            show(message, category, filename, lineno, None, line)
        except TypeError:
            # A showwarning of the four-argument shape, which is what a
            # program that replaced it may well have written.
            show(message, category, filename, lineno)
        return
    try:
        sys.stderr.write("%s:%s: %s: %s\n"
                         % (filename, lineno, category.__name__, text))
        if line:
            sys.stderr.write("  %s\n" % (line.strip(),))
    except Exception:
        pass


def _acquire_lock():
    return None


def _release_lock():
    return None
