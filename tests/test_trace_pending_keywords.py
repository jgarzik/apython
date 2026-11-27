"""The opcode tracer must leave the traced call's keyword arguments alone."""

import sys


def tracer(frame, event, arg):
    if event == "call":
        frame.f_trace_opcodes = True
    return tracer


def keyword_only(*, value):
    return value


def call():
    return keyword_only(value=42)


sys.settrace(tracer)
try:
    assert call() == 42
finally:
    sys.settrace(None)

print("opcode tracing preserves pending keywords")
