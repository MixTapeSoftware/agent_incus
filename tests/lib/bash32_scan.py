#!/usr/bin/env python3
"""Report comments inside $(...) that hold a quote or a paren, and `case`
inside $(...): Bash 3.2 scans $(...) for its closing paren without parsing it,
so these end it early or leave a quote open."""
import re
import sys


def scan(path):
    s = open(path, encoding="utf-8", errors="replace").read()
    i, n, line = 0, len(s), 1
    stack = []  # "(" for $( ), '"' for a double-quoted string
    heredocs = []
    out = []
    at_word_start = True
    while i < n:
        c = s[i]
        top = stack[-1] if stack else ""
        if c == "\n":
            line += 1
            i += 1
            at_word_start = True
            # Skip the bodies of here-documents that start on this line.
            for delim, dash in heredocs:
                while i < n:
                    j = s.find("\n", i)
                    j = n if j < 0 else j
                    text = s[i:j]
                    i = min(j + 1, n)
                    line += 1
                    if (text.lstrip("\t") if dash else text) == delim:
                        break
            heredocs = []
            continue
        if top == '"':
            if c == "\\":
                if i + 1 < n and s[i + 1] == "\n":
                    line += 1
                i += 2
            elif c == '"':
                stack.pop()
                i += 1
            elif s.startswith("$(", i) and not s.startswith("$((", i):
                stack.append("(")
                i += 2
                at_word_start = True
            else:
                i += 1
            continue
        if c == "\\":
            if i + 1 < n and s[i + 1] == "\n":
                line += 1
            i += 2
            at_word_start = False
            continue
        if c == "'":
            j = s.find("'", i + 1)
            j = n if j < 0 else j
            line += s.count("\n", i, j)
            i = j + 1
            at_word_start = False
            continue
        if c == '"':
            stack.append('"')
            i += 1
            at_word_start = False
            continue
        if c == "#" and at_word_start:
            j = s.find("\n", i)
            j = n if j < 0 else j
            text = s[i:j]
            if "(" in stack and re.search(r"['\"()]", text):
                out.append((line, "comment in $(...)", text.strip()))
            i = j
            continue
        if s.startswith("$((", i):
            j = s.find("))", i)
            j = n if j < 0 else j
            line += s.count("\n", i, j)
            i = j + 2
            at_word_start = False
            continue
        if s.startswith("$(", i):
            stack.append("(")
            i += 2
            at_word_start = True
            continue
        if c == "(" and "(" in stack:
            stack.append("(")
            i += 1
            at_word_start = True
            continue
        if c == ")" and top == "(":
            stack.pop()
            i += 1
            at_word_start = False
            continue
        m = re.match(r"<<(-?)\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\2", s[i:i + 80])
        if m and not s.startswith("<<<", i):
            heredocs.append((m.group(3), m.group(1) == "-"))
            i += m.end()
            at_word_start = False
            continue
        if s.startswith("<<<", i):
            i += 3
            continue
        if "(" in stack and at_word_start and re.match(r"case\b", s[i:i + 5]):
            out.append((line, "case in $(...)", s[i:s.find("\n", i)].strip()))
        at_word_start = c in " \t;|&("
        i += 1
    if stack:
        out.append((line, "unbalanced at end of file", repr(stack[-3:])))
    return out


bad = 0
for path in sys.argv[1:]:
    for line, what, text in scan(path):
        print(f"{path}:{line}: {what}: {text[:90]}")
        bad += 1
print(f"{bad} found in {len(sys.argv) - 1} files")
