#!/usr/bin/env python3
"""Write the Swift file that makes a host's unedited source follow the theme.

The package's `RipulThemeRedirect` build-tool plug-in runs this on every build. The file it
writes declares SwiftUI's names again inside the host's own module (`Font.body`,
`Color.red`, `WindowGroup` …), each as one call into the SDK, so the host's existing
`.font(.body)` follows the theme with no line of it changed (docs/theming-for-hosts.md).

  ripul-theme redirect --out <file> [--sources <list file>] [<file or directory>...]

A name the host already declares for itself is left out of the file, and the host's own is
the one its code uses: without that, a host with `extension Font { static var caption }`
would not compile. It reads text, not types: a declaration it cannot see is a compile
error naming both places, and the cure is the flag the file's header gives.
"""
import pathlib
import re
import sys

TEMPLATE = pathlib.Path(__file__).resolve().parent / "redirect" / "RipulThemeRedirect.swift.txt"
SKIP_DIRS = {".git", ".build", ".swiftpm", "build", "DerivedData", "Pods", "Carthage", "SourcePackages", "node_modules"}
TYPES = "Font|Color|Image|Text|View|ShapeStyle"
EXTENSION = re.compile(r"^\s*(?:public\s+|internal\s+|fileprivate\s+|private\s+)?extension\s+(?:SwiftUI\.)?(" + TYPES + r")\b[^{]*\{")
MEMBER = re.compile(r"^\s*(?:@\w+(?:\([^)]*\))?\s+)*(?:public\s+|internal\s+|fileprivate\s+|private\s+)?(?:nonisolated\s+)?"
                    r"(static\s+)?(?:(var|let)\s+(\w+)|(func)\s+(\w+)\s*(?:<[^>]*>)?\s*\(|(init)\s*\()")
TOP_TYPE = re.compile(r"^(?:public\s+|internal\s+|fileprivate\s+|private\s+)?(?:final\s+)?(?:struct|class|enum|actor|typealias)\s+(\w+)")


def strip(line: str) -> str:
    """The line without a trailing comment or the insides of its strings: enough for a declaration."""
    line = re.sub(r'"(?:\\.|[^"\\])*"', '""', line)
    return line.split("//")[0]


def labels(text: str, open_paren: int) -> str:
    """`size:weight:design:` for the parameter list that opens at `open_paren`."""
    depth, i, start, out = 0, open_paren, open_paren + 1, []
    while i < len(text):
        c = text[i]
        if c in "([{<":
            depth += 1
        elif c in ")]}>" and not (c == ">" and text[i - 1] == "-"):
            depth -= 1
            if depth == 0:
                out.append(text[start:i])
                break
        elif c == "," and depth == 1:
            out.append(text[start:i])
            start = i + 1
        i += 1
    names = []
    for part in out:
        part = re.sub(r"@\w+(\([^)]*\))?\s*", "", part).strip()
        if part:
            names.append(part.split(":")[0].split()[0])
    return "".join(n + ":" for n in names)


def declarations(text: str):
    """(key, line index, last line index) for each member of an extension of one of the types,
    and each top-level type. A key is `Font.body`, `Font.system(size:weight:design:)`,
    `Color.init(_:)`, `WindowGroup`."""
    lines = text.split("\n")
    found, depth, current, base = [], 0, None, 0
    for index, raw in enumerate(lines):
        line = strip(raw)
        opened = None
        if current is None:
            m = EXTENSION.match(line)
            if m:
                opened = m.group(1)
            elif depth == 0:
                t = TOP_TYPE.match(line)
                if t:
                    found.append((t.group(1), index))
        elif depth == base + 1:
            m = MEMBER.match(line)
            if m:
                static = "static " if m.group(1) else ""
                if m.group(3):
                    key = f"{current}.{m.group(3)}"
                else:
                    name = m.group(5) or "init"
                    joined = "\n".join(strip(l) for l in lines[index:index + 12])
                    key = f"{current}.{name}({labels(joined, joined.index('(', joined.index(name) + len(name)))})"
                found.append((static + key, index))
        if opened:
            current, base = opened, depth
        depth += line.count("{") - line.count("}")
        if current is not None and depth <= base:
            current = None
    return found


USAGE_MARK = "/*USAGE-MAP*/"


def usage_map(sources) -> str:
    """The View Explorer's map of the target's own tokens, as the JSON the SDK reads. Its
    files are named from the folder they share. Empty when it cannot be made."""
    try:
        import os
        import json
        import theme_usage_map
        files = [str(p.resolve()) for p in sources if p.name != "RipulThemeRedirect.swift"]
        if not files:
            return ""
        base = os.path.commonpath([os.path.dirname(f) for f in files])
        result, _ = theme_usage_map.build(files, os.path.dirname(base) or base, redirect=True)
        text = json.dumps(result, separators=(",", ":"), ensure_ascii=False, sort_keys=True)
        return "" if '"""' in text else text
    except Exception as error:  # the map is an aid: it never stops a build
        print(f"warning: ripul-theme redirect: no usage map: {error}", file=sys.stderr)
        return ""


def swift_files(roots):
    for root in roots:
        root = pathlib.Path(root)
        if root.is_file():
            if root.suffix == ".swift":
                yield root
            continue
        for path in sorted(root.rglob("*.swift")):
            if not SKIP_DIRS.intersection(path.parts):
                yield path


def generate(sources, template: str = None):
    """The file's text, and what was left out: [(key, the host's file)]."""
    template = template if template is not None else TEMPLATE.read_text()
    mine = {}
    for path in sources:
        if path.name == "RipulThemeRedirect.swift":
            continue
        try:
            text = path.read_text(errors="replace")
        except OSError:
            continue
        for key, _ in declarations(text):
            mine.setdefault(key, path.name)
    lines = template.split("\n")
    drop, left = set(), []
    for key, index in declarations(template):
        if key not in mine:
            continue
        left.append((key, mine[key]))
        end = index
        if "{" in strip(lines[index]) and strip(lines[index]).count("{") > strip(lines[index]).count("}"):
            depth = 0
            for end in range(index, len(lines)):
                depth += strip(lines[end]).count("{") - strip(lines[end]).count("}")
                if depth <= 0:
                    break
        drop.update(range(index, end + 1))
    out = [line for i, line in enumerate(lines) if i not in drop]
    out = "\n".join(out).replace(USAGE_MARK, usage_map(sources)).split("\n")
    if left:
        note = ["", "// Left out, because this target declares its own:"]
        note += [f"//   {key.replace('static ', '')}  ({name})" for key, name in sorted(set(left))]
        out = out + note + [""]
    return "\n".join(out), left


def main(argv) -> int:
    out, roots, i = None, [], 0
    while i < len(argv):
        if argv[i] == "--out":
            out = argv[i + 1]; i += 2
        elif argv[i] == "--sources":
            roots += [l for l in pathlib.Path(argv[i + 1]).read_text().split("\n") if l]; i += 2
        else:
            roots.append(argv[i]); i += 1
    text, left = generate(list(swift_files(roots)))
    if out is None:
        sys.stdout.write(text)
        return 0
    target = pathlib.Path(out)
    target.parent.mkdir(parents=True, exist_ok=True)
    if not target.exists() or target.read_text() != text:
        target.write_text(text)
    for key, name in sorted(set(left)):
        print(f"ripul-theme redirect: {key.replace('static ', '')} is declared in {name}; the host's own is kept")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
