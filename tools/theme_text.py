#!/usr/bin/env python3
"""Find the texts that have no colour of their own.

A `Text` with no foreground style is drawn in the system's label colour, and no root can
change that without also changing what `.secondary` draws and recolouring button labels
(docs/theming.md, "What a theme root cannot reach"). So the theme's `text` colour is given
to each such text itself, by one of two routes that share this file:

  the plug-in   the generated file carries the lines found here, and a `Text` made on one
                of them is given the theme's text colour when it is made; nothing is edited
  migrate       `ripul-theme migrate --text` writes `.ripulText()` after
                each, and `ripul-theme check --text` counts those still without it

A text is left alone, by both routes, when the system or the app colours it:
  - it has a `foregroundStyle` or `foregroundColor` in its own chain of modifiers, or a
    view that encloses it in the same expression has one;
  - it is inside a control that colours its label (a `Button`, `Link`, `NavigationLink`,
    `Menu`, `Picker`, a toolbar, a tab, a swipe action, an alert …), a section's header or
    footer, a `LabeledContent` or an empty state;
  - it is not a view of its own: an argument (`.navigationTitle(Text("…"))`), half of a
    `+`, a value kept in a `let`.

It reads text, not types, one file at a time. What it cannot see: a text inside a view of
your own that is used as a button's label somewhere else, or that an enclosing view in
another file colours. Under a theme such a text takes the theme's text colour where it
took the control's or the container's before, so look at the screens.
"""
import pathlib
import re

from theme_usage_map import File, call_end, chained_style, IDENT

# Views and modifiers whose content the system colours by itself.
CONTROLS = {"Button", "Link", "NavigationLink", "Menu", "Picker", "Toggle", "ShareLink", "LabeledContent",
            "ContentUnavailableView", "ProgressView", "Gauge", "DisclosureGroup", "TextField", "SecureField",
            "Stepper", "Slider", "DatePicker", "ColorPicker", "ToolbarItem", "ToolbarItemGroup",
            "ControlGroup", "EditButton", "PasteButton", "RenameButton", "SignInWithAppleButton", "Chart"}
CONTEXTS = {"toolbar", "tabItem", "navigationTitle", "alert", "confirmationDialog", "contextMenu", "swipeActions",
            "badge", "accessibilityLabel", "accessibilityHint", "accessibilityValue", "help", "searchable",
            "fileImporter", "fileExporter", "dialogSuggestedAction", "navigationSubtitle", "keyboardShortcut",
            "accessibilityAction", "accessibilityRepresentation", "searchSuggestions", "refreshable"}
CLOSURE_LABELS = {"header", "footer", "label", "prompt", "actions", "message", "description", "currentValueLabel",
                  "minimumValueLabel", "maximumValueLabel", "onIncrement", "onDecrement"}
COLOURING = {"foregroundStyle", "foregroundColor", "ripulText"}
KEYWORDS = {"if", "else", "for", "while", "switch", "do", "guard", "catch", "in", "return", "where", "case", "default"}
ADDED = ".ripulText()"


def chain_after(f, i):
    """The names of the modifiers applied from `i` on, and where the chain ends."""
    code, match, n = f.code, f.match, len(f.code)
    names = []
    for _ in range(80):
        m = re.match(r"\s*\.([A-Za-z_]\w*)", code[i:i + 600])
        if not m:
            break
        names.append(m.group(1))
        i += m.end()
        k = i
        while k < n and code[k] in " \t":
            k += 1
        if k < n and code[k] in "({" and k in match:
            i = call_end(f, k)
    return names, i


def callee_of_brace(f, brace):
    """For a `{` that is a closure given to a call: (the call's name, the closure's label or
    None, where the call ends). (None, None, None) for any other brace."""
    code, match = f.code, f.match
    label = None
    k = f.back(brace - 1)
    for _ in range(12):
        if k < 0:
            return None, None, None
        c = code[k]
        if c == ":":
            # `} label: {`: step back over the label to the closure before it.
            e = f.back(k - 1)
            s = f.ident_start(e + 1)
            if s > e:
                return None, None, None
            if label is None:
                label = code[s:e + 1]
            k = f.back(s - 1)
            if k < 0 or code[k] != "}":
                return None, None, None
            o = match.get(k)
            if o is None:
                return None, None, None
            k = f.back(o - 1)
            continue
        if c == ")":
            o = match.get(k)
            if o is None:
                return None, None, None
            s = f.ident_start(o)
            name = code[s:o]
            if not name or name in KEYWORDS:
                return None, None, None
            return name, label, call_end(f, o)
        if IDENT.match(c):
            s = f.ident_start(k + 1)
            name = code[s:k + 1]
            if name in KEYWORDS:
                return None, None, None
            # `VStack {`: the closure is the call's only argument.
            return name, label, call_end(f, k + 1)
        if c == "}":
            # A second trailing closure with no label does not exist; this is another block.
            return None, None, None
        return None, None, None
    return None, None, None


PLAIN_ABLE = {"Button", "NavigationLink", "Link"}


def coloured_by_something_else(f, pos):
    """True when a control, a labelled part or an enclosing view's own style colours the text at `pos`.

    A button or a link with `.buttonStyle(.plain)` leaves its label the text colour, and
    so does a navigation link that is a row of a list: a text in those is not coloured."""
    code, match = f.code, f.match
    i = pos - 1
    hops = 0
    link_awaiting_a_list = False
    while i >= 0 and hops < 60:
        c = code[i]
        if c in ")]}":
            i = match.get(i, i) - 1
            continue
        if c == "(":
            s = f.ident_start(i)
            name = code[s:i]
            if name in CONTROLS or name in CONTEXTS:
                # `NavigationLink(destination: Detail())`: where the link leads is not its label.
                if not re.search(r"\bdestination\s*:\s*[^,]*$", code[i + 1:pos]):
                    return True
            hops += 1
        elif c == "{":
            name, label, end = callee_of_brace(f, i)
            if name:
                # `NavigationLink { Detail() } label: { … }`: the first closure is where it leads.
                leads = name == "NavigationLink" and label is None and re.match(r"\s*label\s*:", code[match.get(i, i) + 1:match.get(i, i) + 30])
                if name in PLAIN_ABLE and not leads:
                    style, _ = chained_style(f, end)
                    if style == ".plain":
                        pass
                    elif name == "NavigationLink":
                        link_awaiting_a_list = True
                    else:
                        return True
                elif not leads and (name in CONTROLS or name in CONTEXTS or label in CLOSURE_LABELS):
                    return True
                if name in ("List", "Form", "Section"):
                    link_awaiting_a_list = False
                names, _ = chain_after(f, end)
                if COLOURING.intersection(names):
                    return True
            hops += 1
        elif c == "[":
            hops += 1
        i -= 1
    return link_awaiting_a_list


def a_view_of_its_own(f, pos):
    """True when the `Text(` at `pos` stands as a statement in a view builder."""
    code = f.code
    k = f.back(pos - 1)
    if k < 0:
        return False
    c = code[k]
    if c == "{":
        return True
    newline = "\n" in code[k:pos]
    if c in ")}]" or c == '"':
        return newline
    if c == ":":
        # `case .small:` on the line above, in a builder's switch.
        start = code.rfind("\n", 0, k) + 1
        return newline and re.match(r"\s*(?:case\b|default\b)", code[start:k + 1]) is not None
    if IDENT.match(c):
        word = code[f.ident_start(k + 1):k + 1]
        if word == "in":
            return True
        if word in ("return", "let", "var"):
            return False
        return newline
    return False


def colours_after(f, pos, close):
    """True when the view that starts at `pos` and closes its arguments at `close` has a colour
    in its own chain, is half of an expression, or is coloured by something round it."""
    names, end = chain_after(f, close + 1)
    if COLOURING.intersection(names):
        return True
    after = f.code[end:end + 40].lstrip()
    if after.startswith("+") or after.startswith("?") or after.startswith(":"):
        return True
    return coloured_by_something_else(f, pos)


def bare_texts(f):
    """[(position of `Text`, position just after its closing bracket)] for each text with no colour."""
    code, match = f.code, f.match
    found = []
    for m in re.finditer(r"(?<![\w.])Text\(", code):
        o = m.end() - 1
        close = match.get(o)
        if close is None or not a_view_of_its_own(f, m.start()):
            continue
        if not colours_after(f, m.start(), close):
            found.append((m.start(), close + 1))
    return found


LABEL = re.compile(r"(?<![\w.])Label\(")


def bare_labels(f):
    """[position of `Label`] for each `Label("Title", systemImage: …)` or `image:` with no colour.
    Only the plug-in themes these: a colour written on a label would colour its icon too."""
    code, match = f.code, f.match
    found = []
    for m in LABEL.finditer(code):
        o = m.end() - 1
        close = match.get(o)
        if close is None or not a_view_of_its_own(f, m.start()):
            continue
        if not re.search(r"\b(?:systemImage|image)\s*:", code[o:close]):
            continue
        if not colours_after(f, m.start(), close):
            found.append(m.start())
    return found


PROMINENT = re.compile(r"\.buttonStyle\(\s*\.(?:borderedProminent|glassProminent)\s*\)")


def accent_buttons(f):
    """[position of `.buttonStyle(.borderedProminent)`] for each button that has no `.tint`
    in its own chain and none on a view round it: its fill is the theme's accent."""
    code = f.code
    found = []
    for m in PROMINENT.finditer(code):
        start = f.chain_start(m.start())
        names, end = chain_after(f, m.end())
        own = code[start:end]
        if re.search(r"\.tint\(", own):
            continue
        if tinted_from_outside(f, start):
            continue
        found.append(m.start())
    return found


def tinted_from_outside(f, pos):
    """True when a view that encloses `pos` in the same expression has a `.tint(`."""
    code, match = f.code, f.match
    i, hops = pos - 1, 0
    while i >= 0 and hops < 60:
        c = code[i]
        if c in ")]}":
            i = match.get(i, i) - 1
            continue
        if c == "{":
            name, _, end = callee_of_brace(f, i)
            if name:
                names, _ = chain_after(f, end)
                if "tint" in names:
                    return True
            hops += 1
        elif c in "([":
            hops += 1
        i -= 1
    return False


def read(path):
    try:
        return File(str(path), pathlib.Path(path).read_text(encoding="utf-8", errors="replace"))
    except Exception:  # one unreadable file must not lose the rest
        return None


VIEW_TYPE = re.compile(r"\bstruct\s+([A-Z]\w*)\b[^{}\n]*\{")


def coloured_from_outside(files):
    """The names of the app's own views that some use colours: `Wordmark()` inside a stack
    with a foreground style, or as a button's label. A text inside such a view takes that
    colour, so it is left alone. Followed through views used inside those views."""
    bodies = {}   # name -> [(file, open, close)]
    for f in files:
        for m in VIEW_TYPE.finditer(f.code):
            o = m.end() - 1
            if o in f.match:
                bodies.setdefault(m.group(1), []).append((f, o, f.match[o]))
    if not bodies:
        return set()
    use = re.compile(r"(?<![\w.])(" + "|".join(re.escape(n) for n in bodies) + r")\s*[({]")
    uses = []     # (name, file, position, coloured where it stands)
    for f in files:
        for m in use.finditer(f.code):
            before = f.code[max(0, m.start() - 12):m.start()]
            if re.search(r"\b(?:struct|class|enum|extension)\s+$", before):
                continue
            names, _ = chain_after(f, call_end(f, m.end() - 1))
            uses.append((m.group(1), f, m.start(), bool(COLOURING.intersection(names)) or coloured_by_something_else(f, m.start())))
    coloured = {name for name, _, _, is_coloured in uses if is_coloured}
    changed = True
    while changed:
        changed = False
        for name, f, pos, _ in uses:
            if name in coloured:
                continue
            if any(g is f and o < pos < c for known in coloured for g, o, c in bodies[known]):
                coloured.add(name)
                changed = True
    return coloured


def analyse(paths, labels=False):
    """{path: (File, [(start of `Text`, just after its closing bracket)])} for the app's
    files read together, so that a view coloured where it is used is known in its own file.
    With `labels`, each entry also holds the bare labels: (File, texts, [start of `Label`])."""
    files = [(path, read(path)) for path in paths]
    files = [(path, f) for path, f in files if f is not None]
    coloured = coloured_from_outside([f for _, f in files])
    out = {}
    for path, f in files:
        ranges = [(m.end() - 1, f.match[m.end() - 1]) for m in VIEW_TYPE.finditer(f.code)
                  if m.group(1) in coloured and (m.end() - 1) in f.match]
        inside = lambda a: any(o < a < c for o, c in ranges)
        sites = [(a, b) for a, b in bare_texts(f) if not inside(a)]
        if labels:
            out[path] = (f, sites, [a for a in bare_labels(f) if not inside(a)])
        else:
            out[path] = (f, sites)
    return out


def whole_lines(f, sites, labels=()):
    """The lines on which every `Text(` and every `Label(` is one with no colour."""
    bare = {}
    for start in [a for a, _ in sites] + list(labels):
        bare[f.line(start)] = bare.get(f.line(start), 0) + 1
    whole = []
    for number, count in sorted(bare.items()):
        a = f.starts[number - 1]
        b = f.starts[number] if number < len(f.starts) else len(f.code)
        if len(re.findall(r"(?<![\w.])(?:Text|Label)\(", f.code[a:b])) == count:
            whole.append(number)
    return whole


def add_colour(f, sites):
    """The file's source with the theme's text colour written after each of its sites."""
    text = f.src
    for end in sorted((end for _, end in sites), reverse=True):
        text = text[:end] + ADDED + text[end:]
    return text


def swift_files(targets):
    from theme_check import swift_files as files
    return list(files(targets))


def site_table(sources):
    """{file name: [lines]} for the plug-in's generated file: texts and labels with no colour."""
    table = {}
    for path, (f, sites, labels) in analyse(sources, labels=True).items():
        whole = whole_lines(f, sites, labels)
        if whole:
            table[pathlib.Path(path).name] = whole
    return table


def button_table(sources):
    """{file name: [lines]} of the prominent buttons whose fill is the theme's accent."""
    table = {}
    for path in sources:
        f = read(path)
        if f is None:
            continue
        lines = sorted({f.line(p) for p in accent_buttons(f)})
        if lines:
            table[pathlib.Path(path).name] = lines
    return table


# ---------------------------------------------------------------- lists, for `migrate --lists`

LIST_ADDED = ".ripulThemedList()"
ROWS_ADDED = ".ripulThemedListRows()"


def list_sites(f):
    """[(position just after a `List`, `Form` or `Section`, what to write there)] for each
    that does not have it yet. A list takes its ground; a section its rows' background."""
    code = f.code
    found = []
    for m in re.finditer(r"(?<![\w.])(List|Form|Section)\s*[({]", code):
        before = code[max(0, m.start() - 12):m.start()]
        if re.search(r"\b(?:struct|class|enum|extension)\s+$", before):
            continue
        end = call_end(f, m.end() - 1)
        added = ROWS_ADDED if m.group(1) == "Section" else LIST_ADDED
        names, _ = chain_after(f, end)
        # One that sets its own ground or rows keeps them; one already done is left.
        if {"ripulThemedList", "ripulThemedListRows", "scrollContentBackground", "listRowBackground"}.intersection(names):
            continue
        found.append((end, added))
    return found


def add_lists(f):
    text = f.src
    sites = list_sites(f)
    for end, added in sorted(sites, reverse=True):
        text = text[:end] + added + text[end:]
    return text, len(sites)
