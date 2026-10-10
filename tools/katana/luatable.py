"""Reads the plain-data Luau tables the katana tools exchange (KatanaPoses,
KatanaChoreoSpec): nested { }, `key = value`, numbers, strings, booleans,
and `v(x, y, z)` vector calls. Not a Luau parser; just enough for data files.
"""
import re

TOKEN = re.compile(r"""\s*(?:(--\[\[.*?\]\])|(--[^\n]*)|("(?:[^"\\]|\\.)*")|([A-Za-z_][A-Za-z_0-9]*)|(-?\d+\.?\d*(?:[eE][-+]?\d+)?)|(.))""", re.S)


def tokenize(text):
    out = []
    for m in TOKEN.finditer(text):
        block, line, string, name, number, other = m.groups()
        if block or line:
            continue
        if string:
            out.append(("str", string[1:-1]))
        elif name:
            out.append(("name", name))
        elif number:
            out.append(("num", float(number)))
        elif other and other.strip():
            out.append(("sym", other))
    return out


class Parser:
    def __init__(self, tokens, env):
        self.t = tokens
        self.i = 0
        self.env = env

    def peek(self, k=0):
        return self.t[self.i + k] if self.i + k < len(self.t) else (None, None)

    def take(self):
        tok = self.t[self.i]
        self.i += 1
        return tok

    def expect(self, sym):
        tok = self.take()
        assert tok == ("sym", sym), f"expected {sym}, got {tok}"

    def value(self):
        kind, v = self.peek()
        if kind == "sym" and v == "{":
            return self.table()
        if kind == "sym" and v == "-":
            self.take()
            return -self.value()
        if kind in ("num", "str"):
            self.take()
            return v
        if kind == "name":
            self.take()
            if v == "true":
                return True
            if v == "false":
                return False
            if v == "nil":
                return None
            if self.peek() == ("sym", "("):
                self.take()
                args = []
                while self.peek() != ("sym", ")"):
                    args.append(self.value())
                    if self.peek() == ("sym", ","):
                        self.take()
                self.take()
                return self.env[v](*args)
            return self.env[v]
        raise ValueError(f"unexpected {kind} {v}")

    def table(self):
        self.expect("{")
        arr, rec = [], {}
        while self.peek() != ("sym", "}"):
            if self.peek()[0] == "name" and self.peek(1) == ("sym", "="):
                key = self.take()[1]
                self.take()
                rec[key] = self.value()
            elif self.peek() == ("sym", "["):
                self.take()
                key = self.value()
                self.expect("]")
                self.expect("=")
                rec[key] = self.value()
            else:
                arr.append(self.value())
            if self.peek() in (("sym", ","), ("sym", ";")):
                self.take()
        self.take()
        if rec and arr:
            rec["__array"] = arr
            return rec
        return rec if rec else arr


def load(path, start_marker="return", env=None):
    """Parses the table after the first `return` (or after `start_marker`)."""
    text = open(path, encoding="utf8").read()
    tokens = tokenize(text[text.index(start_marker) + len(start_marker):])
    return Parser(tokens, env or {}).value()


def load_spec(path):
    """KatanaChoreoSpec: `S.Name = {...}` assignments with v(x, y, z) vectors."""
    text = open(path, encoding="utf8").read()
    env = {"v": lambda x, y, z: (x, y, z)}
    ready_at = text.index("local READY =") + len("local READY =")
    env["READY"] = Parser(tokenize(text[ready_at:]), env).value()
    specs = {}
    for m in re.finditer(r"^S\.(\w+)\s*=", text, re.M):
        specs[m.group(1)] = Parser(tokenize(text[m.end():]), env).value()
    return specs, env["READY"]
