# `from m import x` on a module whose body is still running -- a circular
# import -- says so, in CPython's fourth wording, decided by
# __spec__._initializing.  It could not be told apart from a missing name
# while modules carried no __spec__.
try:
    import circ_partner_a
except ImportError as e:
    msg = str(e)
    print(msg[:msg.index("(/")] if "(/" in msg else msg)
    print(e.name)
    print(e.path.endswith("circ_partner_a.py"))

try:
    from json import no_such_name
except ImportError as e:
    print(str(e).split(" (")[0])
