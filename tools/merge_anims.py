"""Replaces animation definitions in AnimationData.luau with the ones in a
snippet file.

The snippet holds optional helper locals plus `Data.Name = ...` blocks. Each
named block in AnimationData is removed and the whole snippet is inserted
where the first of them was (so its helpers sit just above the clips that
use them). Names not present yet are added before `return Data`.

    python3 tools/merge_anims.py snippet.luau [path/to/AnimationData.luau]
"""
import os, re, sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
DEFAULT = os.path.join(ROOT, "src", "ReplicatedStorage", "Combat", "AnimationData.luau")
DEF = re.compile(r"^Data\.(\w+)\s*=")
LOCAL = re.compile(r"^local\s+(?:function\s+)?(\w+)")


def braces(line):
    code = line.split("--", 1)[0]
    code = re.sub(r'"[^"]*"', "", code)
    return code.count("{") - code.count("}")


def blocks(lines):
    """Yields (name, start, end) for each top-level Data.X definition."""
    i = 0
    while i < len(lines):
        m = DEF.match(lines[i])
        if not m:
            i += 1
            continue
        depth, j = braces(lines[i]), i
        while depth > 0:
            j += 1
            depth += braces(lines[j])
        yield m.group(1), i, j
        i = j + 1


def main(snippet_path, target_path=DEFAULT):
    with open(snippet_path) as f:
        snippet = f.read().strip("\n") + "\n"
    with open(target_path) as f:
        lines = f.read().split("\n")
    names = {m.group(1) for m in (DEF.match(l) for l in snippet.split("\n")) if m}
    if not names:
        sys.exit("snippet defines no Data.X blocks")

    existing_locals = {m.group(1) for m in (LOCAL.match(l) for l in lines) if m}
    new_locals = {m.group(1) for m in (LOCAL.match(l) for l in snippet.split("\n")) if m}
    clash = sorted(existing_locals & new_locals)
    if clash:
        sys.exit("snippet redefines existing locals: " + ", ".join(clash))

    spans = [(n, s, e) for n, s, e in blocks(lines) if n in names]
    found = {n for n, _, _ in spans}
    keep, insert_at = [], None
    skip = set()
    for _, s, e in spans:
        skip.update(range(s, e + 1))
    for idx, line in enumerate(lines):
        if idx in skip:
            if insert_at is None:
                insert_at = len(keep)
            continue
        keep.append(line)
    if insert_at is None:
        insert_at = max(i for i, l in enumerate(keep) if l.startswith("return Data"))
    # drop blank runs left behind by removed blocks
    out = keep[:insert_at] + snippet.rstrip("\n").split("\n") + [""] + keep[insert_at:]
    text = re.sub(r"\n{3,}", "\n\n", "\n".join(out))
    with open(target_path, "w") as f:
        f.write(text)
    missing = sorted(names - found)
    print(f"merged {len(names)} clip(s)" + (f"; added new: {', '.join(missing)}" if missing else ""))


if __name__ == "__main__":
    main(*sys.argv[1:])
