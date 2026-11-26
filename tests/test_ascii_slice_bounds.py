class Index:
    def __index__(self):
        return 1


class Text(str):
    def __getitem__(self, key):
        return key.start, key.stop, key.step


def cut(text, start, stop):
    return text[start:stop]


word = "abcd"
assert cut(word, 0, 3) == "abc"
assert cut(word, 2, 4) == "cd"
assert cut(word, 4, 4) == ""
assert cut(word, 1, 2) is word[1]
assert cut(word, -3, 2) == "b"
assert cut(word, 2, -1) == "c"
assert cut(word, 3, 1) == ""
assert cut(word, 1, 2 ** 70) == "bcd"
assert cut(word, None, None) == word
assert cut(word, Index(), 3) == "bc"
assert cut("aé😀d", 1, 3) == "é😀"
assert cut(Text(word), 1, 3) == (1, 3, None)
