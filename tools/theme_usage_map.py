#!/usr/bin/env python3
"""Write the map from an element's identifier to the theme tokens it is drawn with.

The View Explorer inspects UIKit views, and SwiftUI draws into layers: the view a person
taps holds no colour and no font to read back. The source does. Every identified element
is a view expression that ends in `.uiKitIdentifier("…")` (or `.accessibilityIdentifier`),
and the theme accessors written in that expression are what it is drawn with. This script
reads them and writes one JSON file, which the app bundles and the SDK's
`RipulBaseTokenProvider` looks up (docs/theming.md, "The View Explorer").

Run it through `ripul-theme usage-map` (the file beside this one). In an app's build that
is the whole of the setup: one Run Script phase holding one line,

  "<the package>/tools/ripul-theme" usage-map

It reads Xcode's own settings: it does nothing outside a Debug build, reads the Swift
files under the project's folder and the SDK's own screens, and writes
`ripul-theme-usage.json` into the app being built.

  ripul-theme usage-map                    in an Xcode build: as above
  ripul-theme usage-map --roots A B ...    read these directories (relative to the project's folder)
  ripul-theme usage-map --out <file>       write the map there
  ripul-theme usage-map --stats            how many identifiers it could name tokens for
  ripul-theme usage-map --explain <id>     the entry for one identifier, as JSON
  ripul-theme usage-map --no-sdk           leave the SDK's own screens out
  ripul-theme usage-map --always           write it in any configuration

A host's own identifier modifier is followed. A function that hands its own parameter to
`uiKitIdentifier` or `accessibilityIdentifier`, as in

  func identified(_ name: String) -> some View { uiKitIdentifier(name) }

makes `.identified("…")` a stamp like the two it wraps. Nothing declares it.

For each identifier it records the accessors

  own        in the element's own expression, and not inside a part with its own identifier
  inherited  on a `.font(…)`, `.foregroundStyle(…)`, `.foregroundColor(…)` or `.tint(…)`
             applied to a view that encloses the element in the same function
  via        in a view type, a view-returning member or a View-extension modifier the
             expression names, two steps deep and sixteen tokens at most

An accessor inside a `Button`, `Menu` or `Link` is marked with the control and any
`.buttonStyle` chained to it: there the system's hierarchical styles follow the control's
tint, so a default text role is drawn in the accent whatever the source names. A control
with no foreground written at all is recorded too, since its label is the tint.

It is a reader of text, not a compiler. What it cannot see, it leaves out: an identifier
held in a variable, a font set by a caller in another type, a colour passed in as a
parameter. An identifier with an interpolation (`"row.\\(id)"`) is kept as a pattern
(`row.*`). It never fails a build: any error is a warning and an empty map.
"""
import json
import pathlib
import re
import sys

import os

SDK = pathlib.Path(__file__).resolve().parents[1]
SDK_SOURCES = SDK / "Sources" / "RipulAgent"
SKIP_DIRS = {"ThemeCore", ".git", ".build", ".swiftpm", "build", "DerivedData", "Pods", "Carthage",
             "SourcePackages", "node_modules", "checkouts"}
# The SDK's own two modifiers that name an element. A host's wrappers of them are found.
STAMPS = ("uiKitIdentifier", "accessibilityIdentifier")

COLOUR_ROLES = {"accent", "onAccent", "canvas", "surface", "surfaceSunken", "text", "textSecondary",
                "textTertiary", "textQuaternary", "separator", "success", "warning", "danger", "info", "neutral"}
TEXT_ROLES = {"largeTitle", "title", "title2", "title3", "headline", "body", "callout", "subheadline",
              "footnote", "caption", "caption2", "display", "eyebrow", "code"}
KEYWORDS = {"return", "in", "else", "if", "let", "var", "case", "default", "guard", "while", "for", "do",
            "try", "await", "throw", "where", "switch", "some", "any", "is", "as", "func", "static"}
PROPERTY = {"foregroundStyle": "Foreground", "foregroundColor": "Foreground", "fill": "Fill",
            "background": "Background", "tint": "Tint", "stroke": "Stroke", "strokeBorder": "Stroke",
            "border": "Border", "shadow": "Shadow", "font": "Font", "listRowBackground": "Row background",
            "overlay": "Overlay", "toolbarBackground": "Bar background", "scrollContentBackground": "Background",
            "presentationBackground": "Sheet background", "symbolRenderingMode": "Symbol"}
INHERITING = ("font", "foregroundStyle", "foregroundColor", "tint", "ripulTextStyle")
MAX_TOKENS = 40
MAX_DEPTH = 2
MAX_VIA = 16
IDENT = re.compile(r"[A-Za-z0-9_]")


def mask(src: str) -> str:
    """The source with comments blanked and string contents replaced, same length.

    Code inside a string's `\\( )` is kept, so brackets still pair up across it.
    """
    out = list(src)
    n = len(src)
    i = 0

    def blank(a, b):
        for k in range(a, b):
            if out[k] != "\n":
                out[k] = " "

    def string(start):
        triple = src.startswith('"""', start)
        q = 3 if triple else 1
        k = start + q
        while k < n:
            if src[k] == "\\" and k + 1 < n:
                if src[k + 1] == "(":
                    out[k] = "\x01"
                    k = code(k + 2, close=")")
                    continue
                out[k] = out[k + 1] = "\x01"
                k += 2
                continue
            if src.startswith('"' * q, k):
                return k + q
            if not triple and src[k] == "\n":
                return k
            if src[k] != "\n":
                out[k] = "\x01"
            k += 1
        return n

    def code(start, close=None):
        k = start
        depth = 0
        while k < n:
            c = src[k]
            if c == "/" and src.startswith("//", k):
                e = src.find("\n", k)
                e = n if e < 0 else e
                blank(k, e)
                k = e
            elif c == "/" and src.startswith("/*", k):
                e = src.find("*/", k + 2)
                e = n if e < 0 else e + 2
                blank(k, e)
                k = e
            elif c == '"':
                k = string(k)
            elif close and c == "(":
                depth += 1
                k += 1
            elif close and c == ")":
                if depth == 0:
                    return k + 1
                depth -= 1
                k += 1
            else:
                k += 1
        return n

    code(0)
    # A compiler directive on a line of its own does not end a chain of modifiers: both
    # branches of an `#if` are read as one expression.
    masked = "".join(out)
    return re.sub(r"(?m)^[ \t]*#(?:if|elseif|else|endif)\b[^\n]*", lambda m: " " * len(m.group(0)), masked)


def pair(code: str):
    match = {}
    stack = []
    opens = {"(": ")", "[": "]", "{": "}"}
    for i, c in enumerate(code):
        if c in opens:
            stack.append(i)
        elif c in ")]}":
            while stack and opens[code[stack[-1]]] != c:
                stack.pop()
            if stack:
                o = stack.pop()
                match[o] = i
                match[i] = o
    return match


class File:
    def __init__(self, rel: str, src: str):
        self.rel = rel
        self.src = src
        self.code = mask(src)
        self.match = pair(self.code)
        self.starts = [0]
        for m in re.finditer("\n", src):
            self.starts.append(m.end())
        self.types = []      # (name, open, close, header)
        self.members = []    # (type name, member, open, close, header)
        self.stamps = []     # dicts
        self.accessors = []  # dicts
        self.modifiers = []  # (name, receiver start, dot, args open, args close)
        self.locals = []     # (name, let position, initialiser start, initialiser end)
        self.controls = []   # dicts: a Button, Menu or Link call, label closures included
        self.toolbars = []   # (start, end) of `.toolbar { }` and `ToolbarItem( ) { }`
        self.menus = []      # (start, end) where the system draws items its own way: a menu's
                             # content, a context menu, swipe actions, an alert, a dialog

    def line(self, pos: int) -> int:
        lo, hi = 0, len(self.starts) - 1
        while lo < hi:
            mid = (lo + hi + 1) // 2
            if self.starts[mid] <= pos:
                lo = mid
            else:
                hi = mid - 1
        return lo + 1

    def back(self, i: int) -> int:
        """The last character at or before i that is not white space; -1 if none."""
        code = self.code
        while i >= 0 and code[i] in " \t\n\r":
            i -= 1
        return i

    def ident_start(self, k: int) -> int:
        code = self.code
        while k > 0 and IDENT.match(code[k - 1]):
            k -= 1
        return k

    def chain_start(self, dot: int) -> int:
        """Where the expression that `.modifier` at `dot` is applied to begins."""
        code, match = self.code, self.match
        j = dot
        while True:
            k = self.back(j - 1)
            if k < 0:
                return j
            c = code[k]
            if c in ")]}":
                o = match.get(k)
                if o is None:
                    return j
                if c == "}":
                    p = self.back(o - 1)
                    if p >= 0 and code[p] == ":":
                        # `} label: {`: one of several trailing closures.
                        s = self.ident_start(p)
                        q = self.back(s - 1)
                        if s < p and q >= 0 and code[q] == "}":
                            j = s
                            continue
                        return o
                    if p >= 0 and (code[p] == ")" or IDENT.match(code[p])):
                        if code[p] != ")" and code[self.ident_start(p):p + 1] in KEYWORDS:
                            return o
                        j = o
                        continue
                    return o
                # Arguments or a subscript: the callee sits against the bracket.
                if o > 0 and (IDENT.match(code[o - 1]) or code[o - 1] in ")]}?!>"):
                    j = o
                    continue
                return o
            if IDENT.match(c):
                s = self.ident_start(k)
                if code[s:k + 1] in KEYWORDS:
                    return j
                j = s
                p = self.back(s - 1)
                if p >= 0 and code[p] == ".":
                    j = p
                    pp = self.back(p - 1)
                    if pp >= 0 and code[pp] in "?!" and pp > 0 and (IDENT.match(code[pp - 1]) or code[pp - 1] in ")]}"):
                        j = pp
                        continue
                    if pp >= 0 and (code[pp] in ")]}" or IDENT.match(code[pp])):
                        if IDENT.match(code[pp]) and code[self.ident_start(pp):pp + 1] in KEYWORDS:
                            return j
                        continue
                    return j
                return j
            if c in "?!" and k > 0 and (IDENT.match(code[k - 1]) or code[k - 1] in ")]}"):
                j = k
                continue
            return j

    def in_branch(self, pos: int, start: int) -> bool:
        """True when `pos` is inside the body of an `if`, `else` or `switch` that begins after `start`."""
        code, match = self.code, self.match
        i = pos - 1
        while i > start:
            c = code[i]
            if c in ")]}":
                i = match.get(i, i) - 1
                continue
            if c == "{":
                head = code[max(start, i - 400):i]
                if re.search(r"\belse\s*$", head) or re.search(r"(?:^|[\n{};(])\s*(?:\}\s*else\s+)?(?:if|switch)\b[^{}]*$", head):
                    return True
            i -= 1
        return False

    def enclosing_call(self, pos: int):
        """(callee name, argument label, open, close) of the nearest call around `pos`."""
        code, match = self.code, self.match
        i = pos - 1
        hops = 0
        while i >= 0 and hops < 6:
            c = code[i]
            if c in ")]}":
                i = match.get(i, i) - 1
                continue
            if c in "([{":
                close = match.get(i, len(code) - 1)
                if c == "(":
                    k = i - 1
                    s = self.ident_start(k + 1)
                    name = code[s:i]
                    if name:
                        label = None
                        m = re.search(r"(\w+)\s*:\s*[^,:]*$", code[i + 1:pos])
                        if m:
                            label = m.group(1)
                        if name in PROPERTY or name in INHERITING or hops >= 5:
                            return name, label, i, close
                        if label and re.search(r"(?i)colou?r|tint|font|fill|stroke|style|background|foreground", label):
                            return name, label, i, close
                hops += 1
                i -= 1
                continue
            i -= 1
        return None, None, None, None


def call_end(f: File, i: int) -> int:
    """Where a call that starts its arguments or closures at `i` ends: `( ) { } label: { }`."""
    code, match = f.code, f.match
    n = len(code)

    def ws(k):
        while k < n and code[k] in " \t\n\r":
            k += 1
        return k

    k = ws(i)
    if k < n and code[k] == "(" and k in match:
        i = match[k] + 1
    while True:
        k = ws(i)
        if k < n and code[k] == "{" and k in match:
            i = match[k] + 1
            continue
        m = re.match(r"[a-z]\w*\s*:\s*\{", code[k:k + 80])
        if m and (k + m.end() - 1) in match:
            i = match[k + m.end() - 1] + 1
            continue
        return i


def chained_style(f: File, i: int):
    """The argument of a `.buttonStyle( )` among the modifiers after `i`."""
    code, match = f.code, f.match
    for _ in range(30):
        m = re.match(r"\s*\.([A-Za-z_]\w*)\s*\(", code[i:i + 400])
        if not m:
            return None, i
        o = i + m.end() - 1
        if o not in match:
            return None, i
        if m.group(1) == "buttonStyle":
            return "".join(code[o + 1:match[o]].split()), match[o] + 1
        i = call_end(f, o)
    return None, i


def args_text(f: File, open_paren: int) -> str:
    close = f.match.get(open_paren)
    return f.code[open_paren + 1:close] if close else ""


def wrappers_in(code: str, match: dict, stamps):
    """Functions that hand their own parameter to one of `stamps`: a host's identifier modifier."""
    found = set()
    for m in re.finditer(r"\bfunc\s+([A-Za-z_]\w*)\s*\(\s*(?:[A-Za-z_]\w*\s+)?([A-Za-z_]\w*)\s*:\s*String\b[^{};]*\{", code):
        o = m.end() - 1
        if o not in match or m.group(1) in stamps:
            continue
        body = code[o:match[o]]
        if re.search(r"(?<![\w])(?:" + "|".join(stamps) + r")\(\s*" + re.escape(m.group(2)) + r"\s*[,)]", body):
            found.add(m.group(1))
    return found


def scan_file(f: File, stamps=STAMPS):
    code, match = f.code, f.match

    for m in re.finditer(r"\b(struct|class|enum|extension|actor)\s+([A-Za-z_][\w.]*)([^{};]*)\{", code):
        o = m.end() - 1
        if o in match:
            f.types.append((m.group(2).split(".")[-1], o, match[o], m.group(3)))

    def type_at(pos):
        best = None
        for t in f.types:
            if t[1] < pos < t[2] and (best is None or t[1] > best[1]):
                best = t
        return best

    for m in re.finditer(r"\b(var|func)\s+([A-Za-z_]\w*)", code):
        i = m.end()
        header_start = i
        depth = 0
        body = None
        while i < len(code):
            c = code[i]
            if c in "(<[":
                depth += 1
            elif c in ")>]":
                if c == ">" and code[i - 1] == "-":
                    pass
                else:
                    depth -= 1
            elif depth <= 0 and c == "{":
                body = i
                break
            elif depth <= 0 and (c == "=" or c == "}" or (c == "\n" and m.group(1) == "var")):
                break
            i += 1
        if body is None or body not in match:
            continue
        t = type_at(m.start())
        f.members.append((t[0] if t else None, m.group(2), body, match[body], code[header_start:body],
                          t[3] if t else ""))

    # Controls whose label the system colours: inside a Button, Menu or Link the system's
    # hierarchical styles follow the control's tint, whatever role the source names.
    for m in re.finditer(r"(?<![\w.])(Button|Menu|Link|ShareLink)\s*(?=[({])", code):
        end = call_end(f, m.end())
        style, _ = chained_style(f, end)
        f.controls.append({"name": m.group(1), "start": m.start(), "end": end, "style": style})
    for m in re.finditer(r"\.toolbar\s*(?=[({])|\bToolbarItem(?:Group)?\s*(?=\()", code):
        f.toolbars.append((m.start(), call_end(f, m.end())))
    for m in re.finditer(r"\.(?:contextMenu|swipeActions|confirmationDialog|alert)\s*(?=[({])", code):
        f.menus.append((m.start(), call_end(f, m.end())))
    for control in f.controls:
        if control["name"] != "Menu":
            continue
        # Everything in a Menu but its `label:` closure is the menu's content.
        span = code[control["start"]:control["end"]]
        label = [x for x in re.finditer(r"\blabel\s*:\s*\{", span)]
        if label and (control["start"] + label[-1].end() - 1) in match:
            lo = control["start"] + label[-1].start()
            f.menus.append((control["start"] + 4, lo))
            f.menus.append((match[control["start"] + label[-1].end() - 1], control["end"]))
        else:
            f.menus.append((control["start"] + 4, control["end"]))

    # A value kept in a local before it is used: `let tint: Color = flag ? … : Color.ripul(.textSecondary)`.
    for m in re.finditer(r"\blet\s+([a-z_]\w*)\b[^=\n{}]*=(?!=)", code):
        i = m.end()
        depth = 0
        while i < len(code):
            c = code[i]
            if c in "([{":
                i = match.get(i, i)
            elif c in ")]}":
                break
            elif c == "\n":
                nxt = code[i + 1:i + 200].lstrip()
                if not nxt.startswith((".", "?", ":", "&&", "||", "??")):
                    break
            i += 1
        f.locals.append((m.group(1), m.start(), m.end(), i))

    # Identifier stamps.
    for m in re.finditer(r"\.(" + "|".join(stamps) + r")\(", code):
        dot = m.start()
        o = m.end() - 1
        close = match.get(o)
        if close is None:
            continue
        raw = f.src[o + 1:close]
        lit = re.match(r'\s*(?:[A-Za-z_]\w*\s*:\s*)?"((?:[^"\\]|\\.|\\\((?:[^()]|\([^()]*\))*\))*)"\s*(?:,|$)', raw, re.S)
        if not lit:
            f.stamps.append({"dynamic": True, "line": f.line(dot)})
            continue
        ident = re.sub(r"\\\((?:[^()]|\((?:[^()]|\([^()]*\))*\))*\)", "*", lit.group(1))
        ident = re.sub(r"\*+", "*", ident)
        start = f.chain_start(dot)
        f.stamps.append({"id": ident, "start": start, "end": close + 1, "dot": dot, "line": f.line(dot),
                         "type": (type_at(dot) or [None])[0]})

    # Modifiers whose value the views inside them inherit.
    for m in re.finditer(r"\.(" + "|".join(INHERITING) + r")\(", code):
        o = m.end() - 1
        if o in match:
            f.modifiers.append((m.group(1), f.chain_start(m.start()), m.start(), o, match[o]))

    def add(pos, token):
        name, label, o, close = f.enclosing_call(pos)
        token["pos"] = pos
        inside = [c for c in f.controls if c["start"] <= pos < c["end"]]
        if inside:
            control = max(inside, key=lambda c: c["start"])
            token["ctl"] = control["name"]
            if control["style"]:
                token["ctlStyle"] = control["style"]
            if any(a <= control["start"] < b for a, b in f.menus):
                token["ctlIn"] = "menu"
            elif any(a <= control["start"] < b for a, b in f.toolbars):
                token["ctlIn"] = "toolbar"
        token["line"] = f.line(pos)
        token["call"] = name
        if name in PROPERTY:
            token["property"] = PROPERTY[name]
        elif label:
            token["property"] = label[0].upper() + label[1:]
        if o is not None and close is not None:
            snippet = " ".join(f.src[f.ident_start(o) - 1 if o > 0 else o:close + 1].split())
            token["src"] = snippet if len(snippet) <= 140 else snippet[:137] + "..."
            if re.search(r"\?[^.]", code[o:close]) or " if " in code[o:close] or "switch " in code[o:close]:
                token["cond"] = True
        f.accessors.append(token)

    def weight_family(text, token):
        w = re.search(r"weight:\s*\.(\w+)", text)
        if w:
            token["weight"] = w.group(1)
        elif re.search(r"weight:\s*\w", text):
            token["weight"] = "?"
        fam = re.search(r"family:\s*(?:[^,)]*\?\s*)?\.(\w+)", text)
        if fam:
            token["family"] = fam.group(1)

    for m in re.finditer(r"(\b(?:Color|UIColor|NSColor|Font|UIFont)\s*)?\.ripul\(", code):
        o = m.end() - 1
        text = args_text(f, o)
        owner = (m.group(1) or "").strip()
        pos = m.start()
        mm = re.match(r"\s*accentOr:\s*\.(\w+)", text)
        if mm:
            add(pos, {"k": "colour", "role": mm.group(1), "accentOr": True, "form": owner or "style"})
            continue
        mm = re.match(r"\s*system:\s*\.(\w+)", text)
        if mm:
            add(pos, {"k": "system", "name": mm.group(1), "form": owner or "style"})
            continue
        mm = re.match(r"\s*size:\s*([^,)]+)", text)
        if mm:
            token = {"k": "size", "size": mm.group(1).strip()}
            weight_family(text, token)
            add(pos, token)
            continue
        mm = re.match(r"\s*\.(\w+)", text)
        if mm and mm.group(1) in COLOUR_ROLES:
            add(pos, {"k": "colour", "role": mm.group(1), "form": owner or "style"})
        elif mm and mm.group(1) in TEXT_ROLES:
            token = {"k": "type", "role": mm.group(1)}
            weight_family(text, token)
            add(pos, token)
        else:
            add(pos, {"k": "dynamic"})

    for m in re.finditer(r"\.ripulIcon\(", code):
        text = args_text(f, m.end() - 1)
        token = {"k": "icon"}
        mm = re.match(r"\s*size:\s*([^,)]+)", text)
        if mm:
            token["size"] = mm.group(1).strip()
        else:
            mm = re.match(r"\s*\.(\w+)", text)
            if mm:
                token["style"] = mm.group(1)
        weight_family(text, token)
        add(m.start(), token)

    for m in re.finditer(r"\.ripulTextStyle\(\s*\.(\w+)", code):
        token = {"k": "type", "role": m.group(1), "full": True}
        weight_family(args_text(f, code.index("(", m.start())), token)
        add(m.start(), token)

    controls = [
        (r"\.ripulProminentButtonStyle\(", "prominentButton"),
        (r"\.ripulGlassProminentButtonStyle\(", "glassProminentButton"),
        (r"\bSection\(\s*themed:", "sectionHeader"),
        (r"\bRipulSectionHeader\b", "sectionHeader"),
        (r"\.ripulSectionHeader\(", "sectionHeader"),
        (r"\bRipulSectionFooter\b", "sectionFooter"),
        (r"\.ripulSectionFooter\(", "sectionFooter"),
        (r"\bContentUnavailableView\(\s*themed:", "emptyTitle"),
        (r"\bRipulEmptyStateLabel\(", "emptyTitle"),
        (r"\.ripulEmptyStateTitle\(", "emptyTitle"),
        (r"\.ripulEmptyStateDescription\(", "emptyDescription"),
        (r"(?<![\w.])Toggle\s*\(", "toggle"),
    ]
    for pattern, name in controls:
        for m in re.finditer(pattern, code):
            f.accessors.append({"k": "control", "name": name, "pos": m.start(), "line": f.line(m.start())})

    # The accent read through the window's tint, which the theme root sets.
    for m in re.finditer(r"(?<![\w)\]}])\.tint\b(?!\s*[(:\w])|\bColor\.accentColor\b|\bUIColor\.tintColor\b", code):
        add(m.start(), {"k": "tint"})


def public(token, f, extra=None):
    out = {k: v for k, v in token.items() if k not in ("pos", "call")}
    out["file"] = f.rel
    if extra:
        out.update(extra)
    return out


def build(roots, base=None):
    """`roots`: directories, absolute or relative to `base`. A file is named relative to
    `base` where it is under it, and to the folder that holds the SDK where it is the SDK's."""
    base = pathlib.Path(base or os.getcwd()).resolve()
    read = []
    seen = set()
    for root in roots:
        top = (base / root) if not pathlib.Path(root).is_absolute() else pathlib.Path(root)
        top = top.resolve()
        for path in sorted(top.rglob("*.swift")):
            inside = path.relative_to(top).parts[:-1]
            if path in seen or any(part in SKIP_DIRS or part.startswith("build-") for part in inside):
                continue
            seen.add(path)
            try:
                src = path.read_text(encoding="utf-8")
            except (OSError, UnicodeDecodeError):
                continue
            rel = str(path)
            for anchor in (base, SDK.parent):
                try:
                    rel = str(path.relative_to(anchor))
                    break
                except ValueError:
                    continue
            try:
                read.append(File(rel, src))
            except Exception as error:  # one unreadable file must not lose the rest
                print(f"warning: theme usage map: {rel}: {error}", file=sys.stderr)

    # A host's own identifier modifiers, and the modifiers that wrap those.
    stamps = set(STAMPS)
    for _ in range(3):
        more = set()
        for f in read:
            more |= wrappers_in(f.code, f.match, stamps)
        if more <= stamps:
            break
        stamps |= more
    stamps = tuple(sorted(stamps))

    files = []
    for f in read:
        try:
            scan_file(f, stamps)
        except Exception as error:
            print(f"warning: theme usage map: {f.rel}: {error}", file=sys.stderr)
            continue
        files.append(f)

    # Symbols a view expression can name.
    view_types = {}     # name -> [(file, open, close)]
    members = {}        # (type, member) -> [(file, open, close)]
    view_modifiers = {}  # member of an `extension View` -> [(file, open, close)]
    value_members = {}   # (type, member) whose type is a font or a colour -> [(file, open, close)]
    for f in files:
        for name, o, c, header in f.types:
            if f.code[:o].rstrip().rsplit(None, 1) and not re.search(r"\bextension\s+[\w.]+[^{};]*$", f.code[max(0, o - 300):o]):
                view_types.setdefault(name, []).append((f, o, c))
        for tname, member, o, c, header, theader in f.members:
            if "View" in header or "Content" in header:
                members.setdefault((tname, member), []).append((f, o, c))
                if tname == "View":
                    view_modifiers.setdefault(member, []).append((f, o, c))
            elif re.search(r"\b(Font|Color|UIFont|UIColor|ShapeStyle|RipulColorStyle)\b", header):
                value_members.setdefault((tname, member), []).append((f, o, c))

    def owned_elsewhere(f, pos, a, b, own=None):
        """True when `pos` sits inside a part of [a, b) that has an identifier of its own."""
        for s in f.stamps:
            if s is own or s.get("dynamic"):
                continue
            if a <= s["start"] and s["end"] <= b and s["start"] <= pos < s["end"]:
                if own is None or not (s["start"] == own["start"] and s["end"] >= own["end"]):
                    return True
        return False

    def tokens_in(f, a, b, own=None):
        return [t for t in f.accessors if a <= t["pos"] < b and not owned_elsewhere(f, t["pos"], a, b, own)]

    def references(f, a, b, tname):
        code = f.code[a:b]
        found = []
        for m in re.finditer(r"(?<![\w.])([A-Z]\w*)\s*[({]", code):
            if re.search(r"(some|any|->|:)\s*$", code[max(0, m.start() - 8):m.start()]):
                continue
            if m.group(1) in view_types:
                found.append((m.group(1), view_types[m.group(1)]))
        for m in re.finditer(r"(?<![\w.])(?:self\.)?([a-z_]\w*)\b", code):
            key = (tname, m.group(1))
            if tname and key in members:
                found.append((m.group(1), members[key]))
        for m in re.finditer(r"\.([a-z_]\w*)\(", code):
            if m.group(1) in view_modifiers:
                found.append(("." + m.group(1), view_modifiers[m.group(1)]))
        for m in re.finditer(r"\.modifier\(\s*([A-Z]\w*)", code):
            if m.group(1) in view_types:
                found.append((m.group(1), view_types[m.group(1)]))
        return found

    elements = {}
    stats = {"stamps": 0, "dynamic": 0, "named": 0, "own": 0, "inherited": 0, "via": 0}
    for f in files:
        for s in f.stamps:
            stats["stamps"] += 1
            if s.get("dynamic"):
                stats["dynamic"] += 1
                continue
            a, b = s["start"], s["end"]
            tokens = []
            seen = set()

            def push(t, src_file, extra=None):
                key = (src_file.rel, t["pos"])
                if key in seen or len(tokens) >= MAX_TOKENS:
                    return
                seen.add(key)
                tokens.append(public(t, src_file, extra))

            for t in tokens_in(f, a, b, own=s):
                push(t, f)

            # A font or colour that reaches the element through a property or a local.
            body = None
            for tname, member, o, c, header, theader in f.members:
                if o < a and b <= c and (body is None or o > body[0]):
                    body = (o, c)
            resolved = []
            for m in re.finditer(r"(?<![\w.])([a-z_]\w*)\b(?!\s*[:(])", f.code[a:b]):
                pos = a + m.start()
                name = m.group(1)
                ranges = value_members.get((s["type"], name), []) if s["type"] else []
                if not ranges and body:
                    known = [l for l in f.locals if l[0] == name and body[0] < l[1] < a]
                    if known:
                        ranges = [(f, known[-1][2], known[-1][3])]
                if not ranges or owned_elsewhere(f, pos, a, b, s):
                    continue
                call = f.enclosing_call(pos)[0]
                found = [(tf, t) for tf, o, c in ranges for t in tf.accessors if o <= t["pos"] < c]
                if found:
                    resolved.append(pos)
                for tf, t in found:
                    extra = {"via": name}
                    if call in PROPERTY:
                        extra["property"] = PROPERTY[call]
                    if len(found) > 1:
                        extra["cond"] = True
                    push(t, tf, extra)

            # A font or colour written on the element that is not a token: say so, so that
            # "no token" is never read as "nothing sets it".
            for m in re.finditer(r"\.(foregroundStyle|foregroundColor|font|tint|fill)\(", f.code[a:b]):
                o = a + m.end() - 1
                c = f.match.get(o)
                if c is None or owned_elsewhere(f, o, a, b, s):
                    continue
                if any(o < t["pos"] < c for t in f.accessors) or any(o < r < c for r in resolved):
                    continue
                text = " ".join(f.src[o + 1:c].split())
                if not text or text in (".clear", "Color.clear", "nil"):
                    continue
                tokens.append({"k": "other", "property": PROPERTY[m.group(1)], "line": f.line(o),
                               "src": text if len(text) <= 90 else text[:87] + "...", "file": f.rel})
            # A Button or Menu in the element with no foreground written: its label is the
            # control's tint, which no accessor names.
            for control in f.controls:
                if not (a <= control["start"] and control["end"] <= b) or control["style"]:
                    continue
                if "role:" in f.code[control["start"]:control["end"]]:
                    continue  # a destructive button is red, not the tint
                if any(x <= control["start"] < y for x, y in f.menus):
                    continue  # a menu draws its items in its own colours
                if owned_elsewhere(f, control["start"], a, b, s):
                    continue
                if re.search(r"\.(foregroundStyle|foregroundColor|tint)\(", f.code[control["start"]:b]):
                    continue
                token = {"k": "control", "name": "buttonTint", "ctl": control["name"], "line": f.line(control["start"]),
                         "file": f.rel}
                if any(x <= control["start"] < y for x, y in f.toolbars):
                    token["ctlIn"] = "toolbar"
                tokens.append(token)
                break
            own_count = len(tokens)

            # Modifiers on an enclosing view: the nearest one of each kind wins.
            nearest = {}
            for name, rstart, dot, o, c in f.modifiers:
                if dot < b:
                    continue
                if rstart <= a and b <= dot:
                    kind = "font" if name in ("font", "ripulTextStyle") else name
                    if kind == "foregroundColor":
                        kind = "foregroundStyle"
                    if kind not in nearest or (dot - rstart) < (nearest[kind][2] - nearest[kind][1]):
                        nearest[kind] = (name, rstart, dot, o, c)
            own_kinds = {("font" if t.get("call") in ("font", "ripulTextStyle") else t.get("call"))
                         for t in f.accessors if a <= t["pos"] < b and t.get("call") in INHERITING
                         and f.code[a:b].count("{") == 0}
            inherited_count = 0
            for kind, (name, rstart, dot, o, c) in nearest.items():
                same_chain = rstart == a
                if kind in own_kinds and not same_chain:
                    continue
                for t in f.accessors:
                    if o < t["pos"] < c or t["pos"] == dot:
                        push(t, f, None if same_chain else {"inherited": True})
                        inherited_count += 0 if same_chain else 1

            # Views the expression names.
            via_count = 0
            frontier = [(f, a, b, s["type"], [])]
            visited = set()
            depth = 0
            while frontier and depth < MAX_DEPTH:
                next_frontier = []
                for rf, ra, rb, rtype, path in frontier:
                    for name, ranges in references(rf, ra, rb, rtype):
                        for tf, o, c in ranges:
                            key = (tf.rel, o)
                            if key in visited or (tf is f and o <= a and b <= c):
                                continue
                            visited.add(key)
                            chain = path + [name]
                            for t in tokens_in(tf, o, c):
                                if via_count >= MAX_VIA:
                                    break
                                before = len(tokens)
                                push(t, tf, {"via": " › ".join(chain)})
                                via_count += len(tokens) - before
                            owner = name if name in view_types else rtype
                            next_frontier.append((tf, o, c, owner, chain))
                frontier = next_frontier
                depth += 1

            parts = sorted({p["id"] for p in f.stamps if not p.get("dynamic") and p is not s
                            and a <= p["start"] and p["end"] <= b and p["id"] != s["id"]})
            has_text = bool(re.search(r"\b(Text|Label|TextField|SecureField|Button|Toggle|Picker|Link)\(", f.code[a:b]))
            for t in tokens:
                # Written in one branch of an `if` or a `switch` inside the element: it is
                # one of the things the element can be drawn with, not the thing.
                origin = next((x for x in f.accessors if x.get("line") == t.get("line") and t.get("file") == f.rel
                               and a <= x["pos"] < b), None)
                if origin is not None and f.in_branch(origin["pos"], a):
                    t["cond"] = True
            for t in tokens:
                # The bundled file stays small: a token's file is its site's unless it says so,
                # and the source line is kept only where it is the whole answer.
                if t.get("file") == f.rel:
                    del t["file"]
                if t["k"] not in ("dynamic", "other"):
                    t.pop("src", None)
                if t.get("form") == "style":
                    del t["form"]
            site = {"file": f.rel, "line": s["line"], "tokens": tokens}
            if parts:
                site["parts"] = parts[:12]
            if has_text:
                site["text"] = True
            if len(tokens) >= MAX_TOKENS:
                site["truncated"] = True
            elements.setdefault(s["id"], []).append(site)
            if tokens:
                stats["named"] += 1
            stats["own"] += 1 if own_count else 0
            stats["inherited"] += 1 if inherited_count else 0
            stats["via"] += 1 if via_count else 0

    stats["wrappers"] = [name for name in stamps if name not in STAMPS]
    return {"schema": 1, "elements": elements}, stats


def value_of(argv, flag):
    return argv[argv.index(flag) + 1] if flag in argv and argv.index(flag) + 1 < len(argv) else None


def main(argv) -> int:
    env = os.environ
    in_xcode = bool(env.get("SRCROOT") and env.get("TARGET_BUILD_DIR"))
    asked = any(flag in argv for flag in ("--out", "--stats", "--explain"))
    if in_xcode and not asked:
        # The app's build phase. Debug only: the map names source files and lines, and the
        # View Explorer that reads it is a developer tool.
        if env.get("CONFIGURATION") != "Debug" and "--always" not in argv:
            print(f"Theme usage map: not written in a {env.get('CONFIGURATION', '')} build")
            return 0
        folder = env.get("UNLOCALIZED_RESOURCES_FOLDER_PATH", "")
        argv = argv + ["--out", str(pathlib.Path(env["TARGET_BUILD_DIR"]) / folder / "ripul-theme-usage.json")]
    base = value_of(argv, "--base") or env.get("SRCROOT") or os.getcwd()
    roots = ["."]
    if "--roots" in argv:
        i = argv.index("--roots")
        roots = []
        for a in argv[i + 1:]:
            if a.startswith("--"):
                break
            roots.append(a)
    if "--no-sdk" not in argv and SDK_SOURCES.is_dir():
        roots = roots + [str(SDK_SOURCES)]
    try:
        result, stats = build(roots, base)
    except Exception as error:
        print(f"warning: theme usage map not written: {error}", file=sys.stderr)
        result, stats = {"schema": 1, "elements": {}}, {}
    if "--explain" in argv:
        ident = argv[argv.index("--explain") + 1]
        print(json.dumps(result["elements"].get(ident, []), indent=2, ensure_ascii=False))
        return 0
    if "--stats" in argv:
        print(json.dumps(stats, indent=2))
        print(f"identifiers: {len(result['elements'])}")
        return 0
    if "--out" in argv:
        out = pathlib.Path(argv[argv.index("--out") + 1])
        try:
            out.parent.mkdir(parents=True, exist_ok=True)
            out.write_text(json.dumps(result, separators=(",", ":"), ensure_ascii=False, sort_keys=True), encoding="utf-8")
            also = f", following .{', .'.join(stats['wrappers'])}(" if stats.get("wrappers") else ""
            print(f"Theme usage map: {len(result['elements'])} identifiers, "
                  f"{stats.get('named', 0)} of {stats.get('stamps', 0)} stamps with tokens{also} -> {out}")
        except OSError as error:
            print(f"warning: theme usage map not written: {error}", file=sys.stderr)
        return 0
    print(__doc__)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
