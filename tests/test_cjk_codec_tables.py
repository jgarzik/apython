import codecs


for name, text in (
    ("gb18030", "中文𠀀\U0010ffff"),
    ("big5", "中文"),
    ("big5hkscs", "中文"),
    ("cp950", "中文"),
    ("cp932", "日本語"),
    ("shift_jis", "日本語"),
    ("shift_jis_2004", "日本語"),
    ("shift_jisx0213", "日本語"),
    ("euc_jp", "日本語"),
    ("euc_jis_2004", "日本語"),
    ("euc_jisx0213", "日本語"),
    ("euc_kr", "파이썬"),
    ("cp949", "파이썬"),
    ("johab", "파이썬"),
):
    data = text.encode(name)
    for split in range(len(data) + 1):
        decoder = codecs.getincrementaldecoder(name)()
        prefix = decoder.decode(data[:split])
        saved = decoder.getstate()
        tail = decoder.decode(data[split:], True)
        decoder.reset()
        decoder.setstate(saved)
        assert decoder.decode(data[split:], True) == tail
        assert prefix + tail == text, name
    print(name, data.hex())

encoder = codecs.getincrementalencoder("euc_jis_2004")()
assert encoder.encode("æ") == b""
saved = encoder.getstate()
assert encoder.encode("\u0300", True) == "æ\u0300".encode("euc_jis_2004")
encoder.reset()
encoder.setstate(saved)
assert encoder.encode("\u0300", True) == "æ\u0300".encode("euc_jis_2004")
