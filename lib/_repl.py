"""Interactive startup using the standard-library console."""

import code
import sys


class Console(code.InteractiveConsole):
    def raw_input(self, prompt=""):
        sys.stdout.flush()
        sys.stderr.write(prompt)
        sys.stderr.flush()
        line = sys.stdin.readline()
        if line == "":
            raise EOFError
        return line.removesuffix("\n")

    def runsource(self, source, filename="<stdin>", symbol="single"):
        # The compiler's single mode does not emit expression display.
        # Use eval mode for expressions and leave statements to the console.
        try:
            expression = compile(source, filename, "eval")
        except SyntaxError:
            return super().runsource(source, filename, symbol)
        try:
            sys.displayhook(eval(expression, self.locals))
        except SystemExit:
            raise
        except BaseException:
            self.showtraceback()
        return False


def interact(namespace):
    banner = "" if sys.flags.quiet else "Python " + sys.version + " on " + sys.platform
    Console(namespace, filename="<stdin>").interact(banner=banner, exitmsg="")
