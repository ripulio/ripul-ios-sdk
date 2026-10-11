#!/usr/bin/env python3
"""Count fonts and colours written at the call site: the check that a tree stays themed.

Run it through `ripul-theme check` (the file beside this one). What to write in place of
each counted line is in docs/theming-for-hosts.md and docs/theming.md.

  ripul-theme check                      every Swift file under the current directory
  ripul-theme check <file or dir>...     those files
  ripul-theme check --baseline <file>    fail only when a count is above the one kept in <file>
  ripul-theme check --baseline <file> --update    lower the kept counts to today's

With no baseline it prints every counted line and exits 1 while any is left, so a finished
app can run it in its build. With a baseline it exits 1 only when a count has risen: an app
part way through a migration runs that, and its count only falls.

Counted, per line, comments stripped:
  font       .font(.body), Font.system(...), UIFont.systemFont(...) and the like
  colour     Color.red, .foregroundStyle(.orange), UIColor.systemBackground, Color(red:...), .cgColor of those
  hierarchy  .primary/.secondary/.tertiary/.quaternary as a style, Color.primary, Color.secondary
  stored     an accessor's result kept in a `static let`: it would never follow a theme change

Counted apart, never failing: the system form (`.ripul(system: ...)`), and exempt lines.

A bare name (`.orange`, `.secondary`) is counted inside a style call (`foregroundStyle`,
`fill`, `tint` and the rest), in an argument whose label names a colour (`tint: .blue`,
`colors: [.blue, .purple]`), on a line that says its type is `Color`, and after `return`.
A bare text style (`.caption`) is counted anywhere inside a `.font(...)` argument, on a
line that says its type is `Font`, and after `return`.
It cannot see every one: a bare name passed to an unlabelled parameter is invisible to
it, so a count of zero is not proof that a file is clean. Read the diff too.

Not counted: `.tint`, `Color.accentColor`, `UIColor.tintColor` (the theme's accent
reaches those through the window's tint with no edit), view-level `.fontWeight()`,
`.bold()` and `.italic()`, and anything in a branch that compiles only for macOS
(`#if os(macOS)`, `#elseif os(macOS)`, the `#else` of `#if os(iOS)`).

Exempt: a line marked `// theme-exempt: <reason>` (on the line or the line
above), and a file with `// theme-exempt-file: <reason>` in its first 30 lines.

The SDK's own repository runs the same counting over its own layout, by stream
(ripul-native-app/scripts/check_theme_tokens.py imports this file).
"""
import json
import pathlib
import re
import sys

# Folders that hold no source of the app's own.
SKIPPED_DIRS = {".git", ".build", ".swiftpm", "build", "DerivedData", "Pods", "Carthage", "SourcePackages",
                "node_modules", "checkouts"}
CATEGORIES = ("font", "colour", "hierarchy", "stored")

STYLES = r"largeTitle|title[23]?|headline|subheadline|body|callout|footnote|caption2?"
NAMED = r"red|orange|yellow|green|mint|teal|cyan|blue|indigo|purple|pink|brown|gray|white|black"
UIKIT = (r"system[A-Z]\w*|label|secondaryLabel|tertiaryLabel|quaternaryLabel|separator|opaqueSeparator|"
         r"placeholderText|link|(?:secondary|tertiary)System\w+|quaternarySystemFill|lightGray|darkGray|lightText|darkText|"
         + NAMED)
STYLE_CALL = re.compile(r"\.(foregroundStyle|foregroundColor|fill|stroke|strokeBorder|background|border|listRowBackground|shadow|tint)\(")
# Places outside a style call where a bare `.orange` is a colour: an argument whose label
# names a colour, a list of colours, a line that says its type is Color, and `return .green`.
COLOUR_LABEL = re.compile(r"\b\w*(?:[tT]int|[cC]olou?rs?|[fF]oreground|[bB]ackground|[fF]ill|[sS]troke|[aA]ccent)\w*\s*:\s*(\[[^\]]*\]|[^,)]*)")
COLOUR_TYPED = re.compile(r":\s*\[?Color\b|->\s*Color\b")
RETURN_COLOUR = re.compile(r"\breturn\s+\.(?:" + NAMED + r")\b(?!\s*\(|:)")
# A name that is being compared, or is a font weight, is not a colour: `style == .primary`, `weight: .black`.
NOT_A_COLOUR = re.compile(r"(?:==|!=)\s*\.\w+|\bcase\s+\.\w+|\b(?:weight|fontWeight|design)\s*[:(]\s*\.\w+")

FONT = [
    re.compile(r"\.font\(\s*\.(?:" + STYLES + r"|system|custom)\b"),
    re.compile(r"\bFont\.(?:" + STYLES + r"|system|custom)\b"),
    re.compile(r"\bUIFont\.(?:systemFont|preferredFont|monospacedSystemFont|monospacedDigitSystemFont|boldSystemFont|italicSystemFont)\b"),
    re.compile(r"\bUIFont\(\s*name:"),
    # UIKit with the type left out: `label.font = .systemFont(ofSize: 12)`.
    re.compile(r"(?<![\w)\]])\.(?:systemFont|preferredFont|monospacedSystemFont|monospacedDigitSystemFont|boldSystemFont|italicSystemFont)\("),
]
# A bare text style (`.caption`, `.body.weight(.bold)`) where its type is Font: anywhere in a
# `.font(...)` argument, on a line that says its type is Font, and after `return`.
BARE_STYLE = re.compile(r"(?<![\w.)\]])\.(?:" + STYLES + r")\b(?!\s*\(|:)")
FONT_CALL = re.compile(r"\.font\(")
FONT_TYPED = re.compile(r":\s*Font\b|->\s*Font\b")
RETURN_STYLE = re.compile(r"\breturn\s+\.(?:" + STYLES + r")\b(?!\s*\(|:)")
COLOUR = [
    re.compile(r"\bColor\.(?:" + NAMED + r")\b"),
    re.compile(r"\bUIColor\.(?:" + UIKIT + r")\b"),
    re.compile(r"\bColor\(\s*(?:uiColor:\s*)?\.(?:" + UIKIT + r")\b"),
    re.compile(r"\b(?:Color|UIColor)\(\s*(?:\.sRGB\s*,\s*|\.displayP3\s*,\s*)?(?:red|white|hue|displayP3Red)\s*:"),
    re.compile(r"\bColor\(\s*hex\s*:|#colorLiteral\("),
]
# UIKit with the type left out: `label.textColor = .secondaryLabel`.
COLOUR.append(re.compile(r"\b\w*[cC]olor\s*=\s*\.(?:" + UIKIT + r")\b(?!\s*\(|:)"))
HIERARCHY = [re.compile(r"\bColor\.(?:primary|secondary)\b")]
CANVAS_COLOUR = re.compile(r"\.color\(\s*\.(?:" + NAMED + r")\b")
CANVAS_HIERARCHY = re.compile(r"\.color\(\s*\.(?:primary|secondary)\b")
STORED = re.compile(r"\bstatic\s+let\b[^=]*=.*\.ripul(?:Icon)?\(")
SYSTEM_FORM = re.compile(r"\.ripul\(\s*system\s*:")
MAC_ONLY = re.compile(r"^\s*#if\s+os\(macOS\)\s*$")
IMPLICIT_COLOUR = re.compile(r"(?<![\w.)\]])\.(?:" + NAMED + r")\b(?!\s*\(|:)")
IMPLICIT_HIERARCHY = re.compile(r"(?<![\w.)\]])\.(?:primary|secondary|tertiary|quaternary)\b(?!\s*\(|:)")


def style_arguments(code: str):
    """The text inside each style modifier's parentheses on a line."""
    for match in STYLE_CALL.finditer(code):
        depth, start = 1, match.end()
        for index in range(start, len(code)):
            depth += {"(": 1, ")": -1}.get(code[index], 0)
            if depth == 0:
                yield code[start:index]
                break
        else:
            yield code[start:]


ACCESSOR_ARGUMENT = re.compile(r"\.ripul(?:Icon)?\((?:[^()]|\([^()]*\))*\)")


def count_line(code: str):
    stored = len(STORED.findall(code))
    # What is inside an accessor's parentheses is a token name, not a colour: `.ripul(system: .black)`.
    code = ACCESSOR_ARGUMENT.sub(".ripul()", code)
    # Bare text styles, each counted once. The `.font(.body)` pattern below already counts the
    # first name in a `.font(` call, so that position is left to it.
    compared = NOT_A_COLOUR.sub("", code)
    styles = set()
    for match in FONT_CALL.finditer(compared):
        depth, start, end = 1, match.end(), len(compared)
        for index in range(start, len(compared)):
            depth += {"(": 1, ")": -1}.get(compared[index], 0)
            if depth == 0:
                end = index
                break
        first = re.match(r"\s*\.(?:" + STYLES + r"|system|custom)\b", compared[start:end])
        skip = start + first.end() if first else start
        styles.update(skip + m.start() for m in BARE_STYLE.finditer(compared[skip:end]))
    if FONT_TYPED.search(compared):
        styles.update(m.start() for m in BARE_STYLE.finditer(compared))
    styles.update(m.start() + m.group(0).index(".") for m in RETURN_STYLE.finditer(compared))
    counts = {
        "font": sum(len(p.findall(code)) for p in FONT) + len(styles),
        "colour": sum(len(p.findall(code)) for p in COLOUR) + len(CANVAS_COLOUR.findall(code)),
        "hierarchy": sum(len(p.findall(code)) for p in HIERARCHY) + len(CANVAS_HIERARCHY.findall(code)),
        "stored": stored,
    }
    code = NOT_A_COLOUR.sub("", code)
    # Each implicit name is counted once, wherever on the line it was found to be a colour.
    colour, hierarchy = set(), set()

    def collect(text, offset):
        colour.update(offset + m.start() for m in IMPLICIT_COLOUR.finditer(text))
        hierarchy.update(offset + m.start() for m in IMPLICIT_HIERARCHY.finditer(text))

    for match in STYLE_CALL.finditer(code):
        depth, start = 1, match.end()
        end = len(code)
        for index in range(start, len(code)):
            depth += {"(": 1, ")": -1}.get(code[index], 0)
            if depth == 0:
                end = index
                break
        collect(code[start:end], start)
    for match in COLOUR_LABEL.finditer(code):
        collect(match.group(1), match.start(1))
    if COLOUR_TYPED.search(code):
        collect(code, 0)
    colour.update(m.start() + m.group(0).index(".") for m in RETURN_COLOUR.finditer(code))
    counts["colour"] += len(colour)
    counts["hierarchy"] += len(hierarchy)
    return counts


def mac_only_lines(lines):
    """Indexes of the lines that compile only for the Mac host.

    A branch is macOS-only when its condition is `os(macOS)`, `!os(iOS)` or
    `!canImport(UIKit)`, or when it is the `#else` of `#if os(iOS)` /
    `#if canImport(UIKit)` (the two platforms are iOS and macOS). Any other
    condition (DEBUG, a compound one) is taken to compile for iOS.
    """
    def kind(condition):
        condition = condition.strip()
        if condition in ("os(macOS)", "!os(iOS)", "!canImport(UIKit)"):
            return "mac"
        if condition in ("os(iOS)", "!os(macOS)", "canImport(UIKit)"):
            return "ios"
        return "other"

    skipped, stack = set(), []   # each frame: [kind of the #if, whether the current branch is macOS-only]
    for index, line in enumerate(lines):
        text = line.split("//", 1)[0].strip()
        if text.startswith("#if"):
            first = kind(text[3:])
            stack.append([first, first == "mac"])
        elif text.startswith("#elseif") and stack:
            stack[-1][1] = kind(text[7:]) == "mac"
        elif text.startswith("#else") and stack:
            stack[-1][1] = stack[-1][0] == "ios"
        elif text.startswith("#endif") and stack:
            stack.pop()
        elif any(mac for _, mac in stack):
            skipped.add(index)
    return skipped


def scan_file(path):
    """One file's counts per category, "system", "exempt", and "lines": [(number, text, categories)]."""
    lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    whole_file = any("theme-exempt-file:" in line for line in lines[:30])
    mac_only = mac_only_lines(lines)
    entry = {c: 0 for c in CATEGORIES}
    entry.update(system=0, exempt=0, lines=[])
    for index, line in enumerate(lines):
        if index in mac_only:
            continue
        code = line.split("//", 1)[0]
        entry["system"] += len(SYSTEM_FORM.findall(code))
        counts = count_line(code)
        total = sum(counts.values())
        if not total:
            continue
        if whole_file or "theme-exempt:" in line or (index and "theme-exempt:" in lines[index - 1]):
            entry["exempt"] += total
            continue
        for category in CATEGORIES:
            entry[category] += counts[category]
        entry["lines"].append((index + 1, line.strip(), [c for c in CATEGORIES if counts[c]]))
    return entry


def swift_files(targets):
    """Every Swift file in the given files and directories, build folders left out."""
    for target in targets:
        path = pathlib.Path(target)
        if path.is_file():
            yield path
            continue
        for file in sorted(path.rglob("*.swift")):
            parts = file.relative_to(path).parts[:-1]
            if not any(part in SKIPPED_DIRS or part.startswith("build-") or part.startswith(".") for part in parts):
                yield file


ADVICE = ("A font or colour was written at the call site. Use a theme token instead:\n"
          "  .font(.caption)                  ->  .font(.ripul(.caption))\n"
          "  .foregroundStyle(.secondary)     ->  .foregroundStyle(.ripul(.textSecondary))\n"
          "  Color.red for an error           ->  Color.ripul(.danger)\n"
          "`ripul-theme migrate <file or directory>` rewrites the mechanical ones. The full list is in the\n"
          "SDK's docs/theming-for-hosts.md. A colour that is data, not theme, takes\n"
          "`// theme-exempt: <reason>` on its line.")


def main(argv) -> int:
    baseline = None
    if "--baseline" in argv:
        i = argv.index("--baseline")
        if i + 1 >= len(argv):
            print("--baseline needs a file")
            return 2
        baseline = pathlib.Path(argv[i + 1])
        argv = argv[:i] + argv[i + 2:]
    update = "--update" in argv
    quiet = "--quiet" in argv
    targets = [a for a in argv if not a.startswith("--")] or ["."]
    now = {c: 0 for c in CATEGORIES + ("system", "exempt")}
    count = 0
    for file in swift_files(targets):
        entry = scan_file(file)
        count += 1
        for category in now:
            now[category] += entry[category]
        if not quiet and not (baseline and not update and baseline.exists()):
            for number, text, categories in entry["lines"]:
                print(f"{file}:{number}: [{','.join(categories)}] {text}")
    total = sum(now[c] for c in CATEGORIES)
    summary = (f"ripul-theme check: {total} direct fonts and colours in {count} files "
               f"({now['font']} font, {now['colour']} colour, {now['hierarchy']} hierarchy, {now['stored']} stored); "
               f"{now['system']} in the system form, {now['exempt']} exempt")
    if baseline is None:
        print(summary)
        if total:
            print(ADVICE)
        return 1 if total else 0
    kept = json.loads(baseline.read_text()) if baseline.exists() else None
    if update or kept is None:
        new = {c: min(now[c], int(kept.get(c, now[c]))) if kept else now[c] for c in CATEGORIES}
        new["stored"] = 0
        baseline.write_text(json.dumps(new, indent=2) + "\n")
        print(summary)
        print(f"ripul-theme check: baseline {'lowered' if kept else 'written'}: {baseline}")
        return 0
    risen = [(c, int(kept.get(c, 0)), now[c]) for c in CATEGORIES if now[c] > int(kept.get(c, 0))]
    print(summary)
    for category, was, is_now in risen:
        # Xcode shows a line that starts "error:" in the build log.
        print(f"error: ripul-theme check: {is_now} direct {category} uses, above the baseline of {was}.")
    if risen:
        print(ADVICE)
        print("To see the lines, run it with no --baseline.")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
