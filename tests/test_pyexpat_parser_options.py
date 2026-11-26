from xml.parsers import expat


p = expat.ParserCreate()
try:
    p.__setattr__(range(2), 0)
except TypeError as exc:
    assert str(exc) == "attribute name must be string, not 'range'"
else:
    raise AssertionError("expected TypeError for a non-string name")

supported = expat.version_info >= (2, 6, 0)
assert p.GetReparseDeferralEnabled() is supported

for enabled in (False, True):
    p = expat.ParserCreate()
    assert p.SetReparseDeferralEnabled([1] if enabled else []) is None
    effective = enabled and supported
    assert p.GetReparseDeferralEnabled() is effective

    starts = []
    p.StartElementHandler = lambda name, attrs: starts.append(name)
    p.Parse(b"<doc", False)
    p.Parse(b"/>", False)
    assert starts == ([] if effective else ["doc"])
    p.Parse(b"", True)
    assert starts == ["doc"]

print("pyexpat parser options OK")
