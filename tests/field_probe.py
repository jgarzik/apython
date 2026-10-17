"""field_probe.py - third-party code, imported and made to do work.

CPython's Lib/test asks whether the standard library behaves.  It does not ask
whether the code people actually run imports and works, and the two diverge:
on 2026-10-17 a sweep at 89.5% of CPython sat beside `attrs`, `jsonschema`
and `dateutil` failing at import, over three defects the sweep could not see.

Each case below is a function returning something printable.  It is run as

    <interpreter> field_probe.py CASE

one process per case, so a crash or a hang costs that case alone, and
tests/field_probe.sh diffs each case's output against CPython's.  The output
is the result's repr, so a case must return something whose repr is the same
on both sides: no addresses, no timings, no dict-ordering accidents.

The packages come from the host's dist-packages; whatever is not installed
reports MISSING on both sides and is not counted against anyone.
"""

import sys

DIST = "/usr/lib/python3/dist-packages"
if DIST not in sys.path:
    sys.path.append(DIST)

CASES = {}


def case(fn):
    CASES[fn.__name__] = fn
    return fn


def imports(*names):
    """A case per module that only imports it: the cheapest question first."""
    for n in names:
        def f(n=n):
            __import__(n)
            return "imported"
        f.__name__ = "import_" + n.replace(".", "_")
        CASES[f.__name__] = f


imports("attr", "babel", "blinker", "certifi", "chardet", "charset_normalizer",
        "click", "colorama", "configobj", "dateutil.parser", "distro",
        "docutils.core", "hamcrest", "httplib2", "hyperlink", "idna",
        "incremental", "jinja2", "jmespath", "jsonpatch", "jsonpointer",
        "jsonschema", "markdown", "markdown_it", "mako.template", "markupsafe",
        "mdurl", "more_itertools", "netaddr", "oauthlib", "packaging.version",
        "pexpect", "pkg_resources", "pluggy", "ptyprocess", "pyasn1",
        "pygments", "pyparsing", "pyrsistent", "pytz", "requests", "rich",
        "roman", "serial", "setuptools", "six", "sqlparse", "tabulate",
        "urllib3", "wheel", "yaml", "zope.interface", "botocore", "boto3",
        "s3transfer", "pip", "typing_extensions", "toml", "tomli", "wcwidth",
        "olefile", "pdfminer")


# -- the defects the 2026-10-17 probe found, asked directly --------------------

@case
def cell_contents():
    def outer():
        x = 41
        def inner():
            return x
        return inner
    c = outer().__closure__[0]
    before = c.cell_contents
    c.cell_contents = 42
    return before, outer.__code__.co_cellvars, c.cell_contents


@case
def meta_path_user_finder():
    import importlib.abc, importlib.util

    class Finder(importlib.abc.MetaPathFinder, importlib.abc.Loader):
        def find_spec(self, name, path, target=None):
            if name == "probe_virtual_mod":
                return importlib.util.spec_from_loader(name, self)
        def create_module(self, spec):
            return None
        def exec_module(self, module):
            module.answer = 42

    sys.meta_path.insert(0, Finder())
    import probe_virtual_mod
    return probe_virtual_mod.answer, type(probe_virtual_mod.__spec__).__name__


@case
def six_moves():
    from six.moves import urllib_parse, range as srange
    return urllib_parse.quote("a b"), list(srange(3))


@case
def metadata_entry_points():
    from importlib.metadata import entry_points, version
    return (len(entry_points(group="markdown.extensions")) > 0,
            version("six").count(".") >= 1)


@case
def module_spec():
    import json
    return (type(json.__spec__).__name__, json.__spec__.name,
            json.__loader__ is not None)


# -- packages doing work ---------------------------------------------------------

@case
def attrs_class():
    import attr

    @attr.s(frozen=True)
    class P:
        x = attr.ib()
        y = attr.ib(default=2)
    p = P(1)
    return repr(p), attr.asdict(p), p == P(1, 2), hash(p) == hash(P(1))


@case
def jsonschema_validate():
    import jsonschema
    s = {"type": "object", "properties": {"n": {"type": "integer"}},
         "required": ["n"]}
    jsonschema.validate({"n": 1}, s)
    try:
        jsonschema.validate({"n": "x"}, s)
    except jsonschema.ValidationError as e:
        return e.message


@case
def dateutil_parse():
    from dateutil import parser, relativedelta
    d = parser.parse("2026-10-17T12:34:56+02:00")
    return d.isoformat(), (d + relativedelta.relativedelta(months=+3)).isoformat()


@case
def markdown_render():
    import markdown
    return markdown.markdown("# Hi\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\n*e*",
                             extensions=["tables", "fenced_code"])


@case
def markdown_it_render():
    from markdown_it import MarkdownIt
    return MarkdownIt().render("# t\n\n- a\n- **b**\n")


@case
def jinja2_render():
    import jinja2
    env = jinja2.Environment(autoescape=True)
    t = env.from_string("{% for x in xs %}{{ loop.index }}:{{ x|upper }}"
                        "{% if not loop.last %}, {% endif %}{% endfor %} {{ h }}")
    return t.render(xs=["a", "b"], h="<i>")


@case
def mako_render():
    from mako.template import Template
    return Template("<%def name='f(x)'>${x*2}</%def>\n% for i in range(3):\n"
                    "${i}:${f(i)} ${'<&>'|h}\n% endfor\n").render()


@case
def yaml_roundtrip():
    import yaml
    d = yaml.safe_load("a: [1, 2, {b: c}]\nd: !!str 3\n")
    return d, yaml.safe_dump(d, sort_keys=True)


@case
def pygments_highlight():
    from pygments import highlight
    from pygments.lexers import PythonLexer
    from pygments.formatters import HtmlFormatter
    return highlight("def f(x):\n    return x + 1\n", PythonLexer(),
                     HtmlFormatter(nowrap=True))


@case
def rich_render():
    from rich.console import Console
    from rich.table import Table
    c = Console(width=40, record=True, color_system=None, force_terminal=False)
    t = Table("a", "b")
    t.add_row("1", "two")
    c.print(t)
    return c.export_text()


@case
def click_runner():
    import click
    from click.testing import CliRunner

    @click.command()
    @click.option("--n", type=int, default=1)
    @click.argument("name")
    def hello(n, name):
        for _ in range(n):
            click.echo(f"hi {name}")
    r = CliRunner().invoke(hello, ["--n", "2", "bob"])
    return r.exit_code, r.output


@case
def requests_prepare():
    import requests
    r = requests.Request("POST", "http://example.com/p", params={"q": "a b"},
                         json={"k": [1, 2]}).prepare()
    return r.url, r.body, sorted(r.headers.items())


@case
def urllib3_parse():
    from urllib3.util import parse_url, Retry
    return str(parse_url("https://u:p@h.example:8443/a?b#c")), Retry(3).total


@case
def babel_format():
    from babel.numbers import format_decimal, format_currency
    from babel.dates import format_date
    import datetime
    return (format_decimal(1234567.891, locale="de_DE"),
            format_currency(9.5, "EUR", locale="fr_FR"),
            format_date(datetime.date(2026, 10, 17), locale="en_US"))


@case
def pyparsing_grammar():
    import pyparsing as pp
    expr = pp.infix_notation(pp.pyparsing_common.integer,
                             [(pp.one_of("* /"), 2, pp.OpAssoc.LEFT),
                              (pp.one_of("+ -"), 2, pp.OpAssoc.LEFT)])
    return expr.parse_string("1 + 2 * 3 - 4").as_list()


@case
def packaging_versions():
    from packaging.version import Version
    from packaging.specifiers import SpecifierSet
    from packaging.requirements import Requirement
    vs = sorted(["1.10", "1.2", "1.2rc1", "2.0.post1"], key=Version)
    r = Requirement('foo[bar]>=1.0,<2; python_version >= "3.8"')
    return vs, "1.5" in SpecifierSet(">=1.0,<2"), str(r.specifier), r.extras


@case
def chardet_detect():
    import chardet
    return chardet.detect("naïve café résumé".encode("latin-1") * 4)["encoding"]


@case
def idna_encode():
    import idna
    return idna.encode("ドメイン.テスト"), idna.decode(b"xn--eckwd4c7c.xn--zckzah")


@case
def configobj_parse():
    from configobj import ConfigObj
    c = ConfigObj(["a = 1", "[s]", "b = x, y"])
    return c.dict()


@case
def netaddr_math():
    import netaddr
    n = netaddr.IPNetwork("10.0.0.0/22")
    return str(n.broadcast), len(list(n.subnet(24))), str(netaddr.IPAddress("::1"))


@case
def docutils_html():
    from docutils.core import publish_parts
    return publish_parts("Title\n=====\n\n*em* ``lit``\n\n- a\n- b\n",
                         writer_name="html")["body"]


@case
def sqlparse_format():
    import sqlparse
    return sqlparse.format("select a,b from t where x=1 order by a",
                           reindent=True, keyword_case="upper")


@case
def tabulate_grid():
    from tabulate import tabulate
    return tabulate([[1, "a", 2.5], [22, "bb", None]], headers=["n", "s", "f"],
                    tablefmt="grid")


@case
def more_itertools_ops():
    import more_itertools as mi
    return (list(mi.chunked(range(7), 3)), list(mi.windowed("abcd", 2)),
            list(mi.distinct_permutations([1, 1, 2])))


@case
def pluggy_hooks():
    import pluggy
    spec = pluggy.HookspecMarker("p")
    impl = pluggy.HookimplMarker("p")

    class S:
        @spec
        def h(self, a):
            pass

    class P1:
        @impl
        def h(self, a):
            return a + 1

    class P2:
        @impl(tryfirst=True)
        def h(self, a):
            return a * 10
    pm = pluggy.PluginManager("p")
    pm.add_hookspecs(S)
    pm.register(P1())
    pm.register(P2())
    return pm.hook.h(a=3)


@case
def jmespath_search():
    import jmespath
    return jmespath.search("a[?b > `1`].c", {"a": [{"b": 1, "c": "x"},
                                                   {"b": 2, "c": "y"}]})


@case
def jsonpatch_apply():
    import jsonpatch
    return jsonpatch.apply_patch({"a": [1]}, [{"op": "add", "path": "/a/-",
                                               "value": 2}])


@case
def pytz_localize():
    import pytz, datetime
    tz = pytz.timezone("America/New_York")
    return tz.localize(datetime.datetime(2026, 7, 1, 12)).isoformat()


@case
def pyrsistent_ops():
    import pyrsistent
    v = pyrsistent.pvector([1, 2]).append(3)
    m = pyrsistent.pmap({"a": 1}).set("b", 2)
    return list(v), sorted(m.items())


@case
def zope_interface():
    from zope.interface import Interface, implementer, providedBy

    class I(Interface):
        pass

    @implementer(I)
    class C:
        pass
    return I.providedBy(C()), [i.__name__ for i in providedBy(C())]


@case
def botocore_model():
    import botocore.session
    s = botocore.session.get_session()
    m = s.get_service_model("s3")
    return m.service_name, "PutObject" in m.operation_names


@case
def pkg_resources_parse():
    import pkg_resources
    return str(pkg_resources.parse_version("1.0.post1")), \
        str(pkg_resources.Requirement.parse("a>=1"))


@case
def roman_numerals():
    import roman
    return roman.toRoman(2026), roman.fromRoman("MMXXVI")


@case
def hamcrest_match():
    from hamcrest import assert_that, contains_string, has_length, all_of
    assert_that("hello world", all_of(contains_string("wor"), has_length(11)))
    return "matched"


def main():
    if len(sys.argv) < 2 or sys.argv[1] == "--list":
        print("\n".join(CASES))
        return
    name = sys.argv[1]
    try:
        r = CASES[name]()
    except ModuleNotFoundError as e:
        if name.startswith("import_") and e.name and \
           e.name.split(".")[0] == name[len("import_"):].split("_")[0]:
            print("MISSING", e.name)
            return
        print("EXC", type(e).__name__, str(e)[:300])
        return
    except BaseException as e:
        print("EXC", type(e).__name__, str(e)[:300])
        return
    print("OK", repr(r))


main()
