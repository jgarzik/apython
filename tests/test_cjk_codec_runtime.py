import codecs
import io


data = b"abc\xd6\xd0\xce\xc4"
assert data.decode("gb2312") == "abc中文"
assert "abc中文".encode("gbk") == data
assert codecs.encode("·—―", "gbk") == b"\xa1\xa4\xa1\xaa\xa8\x44"

decoder = codecs.getincrementaldecoder("gb2312")()
assert decoder.decode(data[:4]) == "abc"
state = decoder.getstate()
assert state == (b"\xd6", 0)
decoder.reset()
decoder.setstate(state)
assert decoder.decode(data[4:], True) == "中文"

source = codecs.getreader("gbk")(io.BytesIO(data + b"\n"))
assert source.readline(4) == "abc"
assert source.readline() == "中文\n"


def replaced(exc):
    assert exc.encoding == "gb2312"
    assert exc.object == "a☃b" and (exc.start, exc.end) == (1, 2)
    return b"?", exc.end


codecs.register_error("cjk_test_bytes", replaced)
assert "a☃b".encode("gb2312", "cjk_test_bytes") == b"a?b"
assert b"\xff".decode("gb2312", "replace") == "�"
print("CJK codec registry and incremental conversion OK")
