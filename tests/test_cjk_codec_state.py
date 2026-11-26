import codecs

names = ("hz", "iso2022_kr", "iso2022_jp", "iso2022_jp_1", "iso2022_jp_2",
         "iso2022_jp_2004", "iso2022_jp_3", "iso2022_jp_ext")
for name in names:
    sample = ("中文" if name == "hz" else "한글" if name == "iso2022_kr" else "日本語")
    text = sample + "~\n" + sample
    raw = text.encode(name)
    print(name, raw.hex())
    decoder = codecs.getincrementaldecoder(name)()
    for split in range(len(raw) + 1):
        decoder = codecs.getincrementaldecoder(name)()
        head = decoder.decode(raw[:split])
        state = decoder.getstate()
        assert head + decoder.decode(raw[split:], True) == text
        decoder.setstate(state)
        assert head + decoder.decode(raw[split:], True) == text
    encoder = codecs.getincrementalencoder(name)()
    head = encoder.encode(sample)
    state = encoder.getstate()
    assert head + encoder.encode("~\n" + sample, True) == raw
    encoder.reset()
    encoder.setstate(state)
    assert head + encoder.encode("~\n" + sample, True) == raw

decoder = codecs.getincrementaldecoder("shift_jis")("replace")
assert decoder.decode(b"\x80") == "�"
assert decoder.getstate() == (b"", 0)
assert b"\xaf\xfe\xb4t".decode("euc_jisx0213", "replace") == "��t"

decoder = codecs.getincrementaldecoder("iso2022_jp_2")()
assert decoder.decode(b"\x1b.A") == ""
decoder.reset()
assert decoder.decode(b"\x1bN#") == "£"
