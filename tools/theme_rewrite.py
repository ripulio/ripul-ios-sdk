#!/usr/bin/env python3
"""Rewrite the mechanical font and text-colour call sites to theme tokens.

Syntax only: every rewrite produces the accessor whose default is the very
value it replaces, so nothing changes on screen (the equalities are tested in
the SDK's Tests/RipulAgentTests/RipulThemeCoreTests.swift, and the pixel
identity of the hierarchy styles and of `.monospaced()` was measured; see
docs/theming.md). Anything that needs a decision is left alone
and still shows in `ripul-theme check`.

  ripul-theme migrate <file or directory>...        rewrite in place
  ripul-theme migrate --dry-run <file or directory>...   show what would change
  ripul-theme migrate --icons <file or directory>...     only move role fonts on an Image to ripulIcon
  ripul-theme migrate --named <file or directory>...     also the named colours, by the closed table
  ripul-theme migrate --text <file or directory>...      also `.foregroundStyle(.ripul(.text))` on each text with no colour of its own
  ripul-theme migrate --lists <file or directory>...     also `.ripulThemedList()` on each list and form, `.ripulThemedListRows()` on each section
  ripul-theme lint [<git range>] [-- <path>...]
        the mapping lint: read a migration diff (default: the working tree against
        HEAD) and accept a replacement only if the token's default is the very
        value it replaced, by the closed table in theming.md. Exit 1 otherwise.
        A deliberate exception takes `// theme-mapping: <reason>` on the new line.

What it rewrites:
  .font(.body)                                -> .font(.ripul(.body))
  .font(.caption.weight(.semibold))           -> .font(.ripul(.caption, weight: .semibold))
  .font(.caption) on an Image                 -> .font(.ripulIcon(.caption))           (an icon size, never themed)
  .font(.title.bold())                        -> .font(.ripul(.title).bold())        (kept as a call: bold() is not weight(.bold))
  .font(.caption.monospacedDigit())           -> .font(.ripul(.caption).monospacedDigit())
  .font(.caption.monospaced())                -> .font(.ripul(.caption, family: .code))
  .font(.system(.caption, design: .monospaced)) -> .font(.ripul(.caption, family: .code))
  .font(.system(size: 14, weight: .medium))   -> .font(.ripul(size: 14, weight: .medium))      on text
                                              -> .font(.ripulIcon(size: 14, weight: .medium))  on an Image
  .font(.system(size: 12, design: .monospaced)) -> .font(.ripul(size: 12, family: .code))
  .foregroundStyle(.secondary)                -> .foregroundStyle(.ripul(.textSecondary))
      (also foregroundColor, fill, stroke, strokeBorder, background, tint; .primary/.tertiary/.quaternary;
       and a ternary whose two sides are both of these)
  Color.primary / Color.secondary             -> Color.ripul(.text) / Color.ripul(.textSecondary)
  Color(.systemBackground), Color(uiColor: .systemBackground) -> Color.ripul(.canvas)
      (each system colour that is a role's default becomes the role; any other, the system
       form: Color(.systemGray5) -> Color.ripul(system: .systemGray5))
  UIColor.systemBackground / UIColor.label    -> UIColor.ripul(.canvas) / UIColor.ripul(.text)
  .buttonStyle(.borderedProminent)            -> .ripulProminentButtonStyle()
  .buttonStyle(.glassProminent)               -> .ripulGlassProminentButtonStyle()

With --named, the named colours too, each to the token whose default it is:
  Color.red, .foregroundStyle(.red)           -> Color.ripul(.danger), .foregroundStyle(.ripul(.danger))
      (orange: warning, green: success, blue: info, gray: neutral)
  Color.white, .fill(.black), Color.yellow    -> Color.ripul(system: .white), .fill(.ripul(system: .black)),
                                                 Color.ripul(system: .systemYellow)
Nothing changes on screen either way. What --named cannot do is decide: a white that sits on
an accent fill should be `.ripul(.onAccent)`, and a blue that is the app's own colour
`.ripul(accentOr: .info)`. Read its changes for those.

A fixed-size font is "on an Image" when the view its modifier chain hangs
from starts with `Image(`, and "on text" when it starts with `Text(`. Where
the script cannot tell, it leaves the line for you. Either way the pixels are
the same today; the choice only decides whether a theme's family will apply.

Never touched: a line marked `theme-exempt:`, a branch that compiles only for
macOS, CmsRender/, ThemeCore/, and
named colours (`Color.red`, `.foregroundStyle(.orange)`) unless --named is given.
"""
import pathlib
import re
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

STYLES = r"largeTitle|title[23]?|headline|subheadline|body|callout|footnote|caption2?"
HIERARCHY = {"primary": "text", "secondary": "textSecondary", "tertiary": "textTertiary", "quaternary": "textQuaternary"}
SKIPPED = ("/CmsRender/", "/ThemeCore/", "/RipulThemeKit/")

# A chain of simple calls after the style: .weight(.semibold).monospacedDigit()
CHAIN = r"(?:\.[A-Za-z]+\((?:[^()]|\([^()]*\))*\))*"
STYLE_FONT = re.compile(r"\.font\(\s*\.(" + STYLES + r")(" + CHAIN + r")\s*\)")
SYSTEM_STYLE_FONT = re.compile(r"\.font\(\s*\.system\(\s*\.(" + STYLES + r")\s*,\s*design:\s*\.monospaced\s*\)(" + CHAIN + r")\s*\)")
ARG = r"((?:[^,()]|\([^()]*\))+?)"
FIXED_FONT = re.compile(r"\.font\(\s*\.system\(\s*size:\s*" + ARG + r"(?:\s*,\s*weight:\s*" + ARG + r")?(?:\s*,\s*design:\s*\.(monospaced|default))?\s*\)(" + CHAIN + r")\s*\)")
STYLE_CALLS = r"foregroundStyle|foregroundColor|fill|stroke|strokeBorder|background|tint"
HIERARCHY_ARG = re.compile(r"\.(" + STYLE_CALLS + r")\(\s*\.(primary|secondary|tertiary|quaternary)\s*(?=[,)])")
HIERARCHY_TERNARY = re.compile(r"\.(" + STYLE_CALLS + r")\(\s*((?:[^()?:]|\([^()]*\))+?)\?\s*\.(primary|secondary|tertiary|quaternary)\s*:\s*\.(primary|secondary|tertiary|quaternary)\s*(?=[,)])")
COLOR_HIERARCHY = re.compile(r"\bColor\.(primary|secondary)\b")
WEIGHT_CALL = re.compile(r"^\.weight\(\s*(\.[A-Za-z]+)\s*\)")
MONO_CALL = re.compile(r"\.monospaced\(\)")


# System colours by name. One that is a role's default becomes the role, any other the system form.
SYSTEM_COLOURS = ("label|secondaryLabel|tertiaryLabel|quaternaryLabel|placeholderText|separator|opaqueSeparator|link|"
                  "systemBackground|secondarySystemBackground|tertiarySystemBackground|"
                  "systemGroupedBackground|secondarySystemGroupedBackground|tertiarySystemGroupedBackground|"
                  "systemFill|secondarySystemFill|tertiarySystemFill|quaternarySystemFill|"
                  "systemRed|systemOrange|systemYellow|systemGreen|systemMint|systemTeal|systemCyan|systemBlue|"
                  "systemIndigo|systemPurple|systemPink|systemBrown|systemGray[2-6]?")
WRAPPED_SYSTEM = re.compile(r"\bColor\(\s*(?:uiColor:\s*)?(?:UIColor)?\.(" + SYSTEM_COLOURS + r")\s*\)")
UIKIT_SYSTEM = re.compile(r"\bUIColor\.(" + SYSTEM_COLOURS + r")\b(?!\s*\()")
PROMINENT = re.compile(r"\.buttonStyle\(\s*\.(borderedProminent|glassProminent)\s*\)")
NAMED_COLOR = re.compile(r"\bColor\.(red|orange|yellow|green|mint|teal|cyan|blue|indigo|purple|pink|brown|gray|white|black)\b(?!\s*\()")
NAMED_ARG = re.compile(r"\.(" + STYLE_CALLS + r")\(\s*\.(red|orange|yellow|green|mint|teal|cyan|blue|indigo|purple|pink|brown|gray|white|black)\s*(?=[,)])")


def system_colour(name, uikit=False):
    """The accessor arguments for a system colour: the role it is the default of, else the system form."""
    roles = {"systemBackground": "canvas", "secondarySystemGroupedBackground": "surface",
             "systemGroupedBackground": "surfaceSunken", "separator": "separator", "systemGreen": "success",
             "systemOrange": "warning", "systemRed": "danger", "systemBlue": "info", "systemGray": "neutral"}
    if uikit:
        # UIKit's label colours are the text roles' defaults there; in SwiftUI they are not.
        roles.update(label="text", secondaryLabel="textSecondary", tertiaryLabel="textTertiary", quaternaryLabel="textQuaternary")
    return f".{roles[name]}" if name in roles else f"system: .{name}"


def named_colour(name):
    roles = {"red": "danger", "orange": "warning", "green": "success", "blue": "info", "gray": "neutral"}
    if name in roles:
        return f".{roles[name]}"
    return f"system: .{name}" if name in ("white", "black") else f"system: .system{name.capitalize()}"


def style_font(match):
    style, chain = match.group(1), match.group(2)
    arguments = [f".{style}"]
    weight = WEIGHT_CALL.match(chain)
    if weight:
        arguments.append(f"weight: {weight.group(1)}")
        chain = chain[weight.end():]
    if MONO_CALL.search(chain):
        chain = MONO_CALL.sub("", chain, count=1)
        arguments.append("family: .code")
    return f".font(.ripul({', '.join(arguments)}){chain})"


def system_style_font(match):
    return f".font(.ripul(.{match.group(1)}, family: .code){match.group(2)})"


def base_of_chain(lines, index, column):
    """The start of the view expression a modifier at lines[index][column] hangs from."""
    before = lines[index][:column].strip()
    if before and not before.startswith("."):
        return before
    for back in range(index - 1, max(index - 40, -1), -1):
        text = lines[back].split("//", 1)[0].strip()
        if not text:
            continue
        if text.startswith(".") or text in ("}", ")", "})"):
            # Still in the chain, or a closing line of a multi-line base: give up on the
            # second, a builder closure could hold anything.
            if not text.startswith("."):
                return ""
            continue
        return text
    return ""


# A text-style font already written as a role, with at most a weight: `.font(.ripul(.caption))`.
ROLE_FONT = re.compile(r"\.font\(\s*\.ripul\(\s*(\.(?:" + STYLES + r")(?:\s*,\s*weight:\s*(?:[^,()]|\([^()]*\))+)?)\s*\)")
VIEW_NAMED = re.compile(r"\b(Image|Text|Label|TextField|TextEditor|SecureField)\(")


def on_an_image(lines, index, column):
    """True when the modifier at lines[index][column] hangs from an `Image(...)`."""
    views = VIEW_NAMED.findall(base_of_chain(lines, index, column))
    # Only an Image, and nothing that draws text beside it: a font on `Label` or on a
    # stack holding a `Text` too is type.
    return bool(views) and all(view == "Image" for view in views)


def icon_fonts(lines, index, code):
    """A font on a symbol is an icon size, never type: `.ripul(.caption)` there is `.ripulIcon(.caption)`."""
    return ROLE_FONT.sub(lambda m: f".font(.ripulIcon({m.group(1)})" if on_an_image(lines, index, m.start()) else m.group(0), code)


def host_roles(code):
    """`Color("BrandNavy")` to the role the app declared for that asset: `Color.ripul(.navy)`."""
    import theme_roles
    for member, entry in theme_roles.ROLES.items():
        if entry["asset"] and '"' in code:
            code = theme_roles.asset_use(entry["asset"]).sub(f"Color.ripul(.{member})", code)
    return code


def rewrite(text, icons_only=False, named=False):
    lines = text.split("\n")
    changed = 0
    # A branch that compiles only for the Mac host is left exactly as it is.
    from theme_check import mac_only_lines
    mac_only = mac_only_lines(lines)
    for index, line in enumerate(lines):
        if index in mac_only:
            continue
        if "theme-exempt:" in line or (index and "theme-exempt:" in lines[index - 1]):
            continue
        code, slashes, comment = line.partition("//")
        original = code
        if icons_only:
            code = icon_fonts(lines, index, code)
            if code != original:
                lines[index] = code + slashes + comment
                changed += 1
            continue
        code = SYSTEM_STYLE_FONT.sub(system_style_font, code)
        code = STYLE_FONT.sub(style_font, code)
        code = icon_fonts(lines, index, code)

        def fixed_font(match, index=index):
            size, weight, design, chain = match.group(1).strip(), match.group(2), match.group(3), match.group(4)
            base = base_of_chain(lines, index, match.start())
            # The last view named before the modifier decides: `Image(...)` or `Text(...)`.
            views = re.findall(r"\b(Image|Text|Label|TextField|TextEditor|SecureField)\(", base)
            kind = views[-1] if views else None
            if design == "monospaced":
                kind = "Text" if kind in (None, "Text", "TextField", "TextEditor", "SecureField") else kind
            if kind == "Image" and design != "monospaced":
                name, family = "ripulIcon", ""
            elif kind in ("Text", "TextField", "TextEditor", "SecureField"):
                name, family = "ripul", ", family: .code" if design == "monospaced" else ""
            else:
                return match.group(0)
            weight_part = f", weight: {weight.strip()}" if weight else ""
            return f".font(.{name}(size: {size}{weight_part}{family}){chain})"

        code = FIXED_FONT.sub(fixed_font, code)
        code = HIERARCHY_TERNARY.sub(
            lambda m: f".{m.group(1)}({m.group(2)}? .ripul(.{HIERARCHY[m.group(3)]}) : .ripul(.{HIERARCHY[m.group(4)]})", code)
        code = HIERARCHY_ARG.sub(lambda m: f".{m.group(1)}(.ripul(.{HIERARCHY[m.group(2)]})", code)
        code = COLOR_HIERARCHY.sub(lambda m: f"Color.ripul(.{HIERARCHY[m.group(1)]})", code)
        code = WRAPPED_SYSTEM.sub(lambda m: f"Color.ripul({system_colour(m.group(1))})", code)
        code = UIKIT_SYSTEM.sub(lambda m: f"UIColor.ripul({system_colour(m.group(1), uikit=True)})", code)
        code = PROMINENT.sub(lambda m: ".ripulProminentButtonStyle()" if m.group(1) == "borderedProminent"
                             else ".ripulGlassProminentButtonStyle()", code)
        if named:
            code = NAMED_COLOR.sub(lambda m: f"Color.ripul({named_colour(m.group(1))})", code)
            code = NAMED_ARG.sub(lambda m: f".{m.group(1)}(.ripul({named_colour(m.group(2))})", code)
        code = host_roles(code)
        if code != original:
            lines[index] = code + slashes + comment
            changed += 1
    return "\n".join(lines), changed


# ---------------------------------------------------------------- the mapping lint
#
# Both sides of a changed line are reduced to a skeleton in which every literal and
# every accessor is replaced by a name for the VALUE IT DRAWS BY DEFAULT. If the two
# skeletons are equal, each replacement kept its value, so nothing changed on screen.

NAMED_ROLE = {"red": "danger", "orange": "warning", "green": "success", "blue": "info", "gray": "neutral", "white": "onAccent"}
HUES = "red|orange|yellow|green|mint|teal|cyan|blue|indigo|purple|pink|brown|gray|white|black"
# A system colour that is also a role's default, in both toolkits.
SYSTEM_ROLE = {"systemBackground": "canvas", "secondarySystemGroupedBackground": "surface",
               "systemGroupedBackground": "surfaceSunken", "separator": "separator", "systemGreen": "success",
               "systemOrange": "warning", "systemRed": "danger", "systemBlue": "info", "systemGray": "neutral",
               "white": "onAccent"}
# UIKit's label colours are the text roles' defaults there. In SwiftUI they are NOT:
# `Color(.secondaryLabel)` is a fixed colour, `.secondary` is the hierarchical style.
UIKIT_TEXT = {"label": "text", "secondaryLabel": "textSecondary", "tertiaryLabel": "textTertiary",
              "quaternaryLabel": "textQuaternary", "tintColor": "accent"}
SYSTEM_NAMES = (r"system[A-Z]\w*|label|secondaryLabel|tertiaryLabel|quaternaryLabel|separator|opaqueSeparator|"
                r"placeholderText|link|(?:secondary|tertiary)System\w+|quaternarySystemFill|tintColor|white|black")
UIFONT_STYLE = {"largeTitle": "largeTitle", "title1": "title", "title2": "title2", "title3": "title3", "headline": "headline",
                "body": "body", "callout": "callout", "subheadline": "subheadline", "footnote": "footnote",
                "caption1": "caption", "caption2": "caption2"}


def role(name):
    return f"\u00a7{name}\u00a7"


def system(name):
    return role(SYSTEM_ROLE[name]) if name in SYSTEM_ROLE else f"\u00a7sys:{name}\u00a7"


def hue(name):
    return role(NAMED_ROLE[name]) if name in NAMED_ROLE else system("black" if name == "black" else "system" + name.capitalize())


BARE_HIERARCHY = re.compile(r"(?<![\w)\]])\.(primary|secondary|tertiary|quaternary)\b(?!\s*\(|:)")
# Evidence of a Color beside a bare name: the word, or a colour's symbol. Not the accent's
# (`.tint` is a style) and not another hierarchy name.
# `tint ?? .primary` counts too: `??` makes both sides one type, and the optional beside a
# colour name in a style call is in practice a `Color?`.
COLOUR_BESIDE = re.compile(r"\?\?|\bColor\b|\u00a7(?!accent\u00a7|\??text)|(?<![\w)\]])\.(?:" + HUES + r")\b(?!\s*\(|:)")
STYLE_OPEN = re.compile(r"\.(?:" + STYLE_CALLS + r"|border|listRowBackground)\(")
TYPED_COLOR = re.compile(r":\s*\[?Color\b|->\s*Color\b")


def bare_hierarchy(code):
    if TYPED_COLOR.search(code):
        return BARE_HIERARCHY.sub(lambda m: role("C:" + HIERARCHY[m.group(1)]), code)
    spans = []
    for match in STYLE_OPEN.finditer(code):
        depth, start, end = 1, match.end(), len(code)
        for index in range(start, len(code)):
            depth += {"(": 1, ")": -1}.get(code[index], 0)
            if depth == 0:
                end = index
                break
        spans.append((start, end))
    out, last = [], 0
    for match in BARE_HIERARCHY.finditer(code):
        name = HIERARCHY[match.group(1)]
        inside = next(((a, b) for a, b in spans if a <= match.start() < b), None)
        if inside is None:
            symbol = role("?" + name)
        else:
            rest = code[inside[0]:match.start()] + code[match.end():inside[1]]
            rest = BARE_HIERARCHY.sub("", rest)
            is_color = COLOUR_BESIDE.search(rest) and "AnyShapeStyle(" not in rest
            # The other branch of a ternary is a name (`selected ? color : .secondary`): only the
            # compiler knows whether `color` is a Color, so either form is taken.
            beside_a_name = re.search(r"\?\s*[A-Za-z_]|\s:\s*[A-Za-z_]", rest) and "AnyShapeStyle(" not in rest
            symbol = role(("C:" if is_color else "?" if beside_a_name else "") + name)
        out.append(code[last:match.start()] + symbol)
        last = match.end()
    return "".join(out) + code[last:]


def same_value(before, after):
    """Equal skeletons, where an open `?name` on the old side takes either form on the new."""
    if before == after:
        return True
    pattern = re.escape(before)
    pattern = re.sub("\u00a7\\\\\\?(\\w+)\u00a7", lambda m: "\u00a7(?:C:|\\?)?" + m.group(1) + "\u00a7", pattern)
    return re.fullmatch(pattern, after) is not None


# The control modifiers of "Controls that style their own text" (docs/theming.md). With no
# theme each is the system's own style, or nothing at all, so the lint reads them that way.
CONTROL_IDENTITIES = [
    (re.compile(r"\.ripulProminentButtonStyle\(\)"), ".buttonStyle(.borderedProminent)"),
    (re.compile(r"\.ripulGlassProminentButtonStyle\(\)"), ".buttonStyle(.glassProminent)"),
    (re.compile(r"\.ripul(?:EmptyStateTitle|EmptyStateDescription|SectionHeader|SectionFooter)\(\)"), ""),
    # The accent once a theme names one; with no theme, the role it replaced.
    (re.compile(r"\.ripul\(\s*accentOr:\s*\.(\w+)\s*\)"), r".ripul(.\1)"),
    # What `migrate --text` and `--lists` write: with no theme, the text's own colour and the list's own look.
    (re.compile(r"(?<=\))\.foregroundStyle\(\.ripul\(\.text\)\)"), ""),
    (re.compile(r"\.ripulThemedList(?:Rows)?\(\)"), ""),
    # Not a token: the notification's name.
    (re.compile(r"\.ripulThemeDidChange\b"), ".themeDidChange"),
]


def control_identities(code):
    for pattern, replacement in CONTROL_IDENTITIES:
        code = pattern.sub(replacement, code)
    return code


def skeleton(code):
    code = control_identities(code)
    # A role the app declared for itself: the asset it is by default, and the accessor
    # in either form, are one value.
    import theme_roles
    if theme_roles.ROLES:
        code = host_roles(code)
        code = re.sub(r"(?:\bColor)?\.ripul\(\s*\.(" + theme_roles.members_pattern() + r")\s*\)", lambda m: role("host:" + m.group(1)), code)
    if TYPED_COLOR.search(code):
        # On a line whose type is Color, a bare `.ripul(.textSecondary)` is the Color form.
        code = re.sub(r"(?<![\w)\]])\.ripul\(\s*\.(text\w*)\s*\)", lambda m: role("C:" + m.group(1)), code)
    # A monospaced font whose style is chosen at run time: `.system(flag ? .caption : .callout, design: .monospaced)`.
    code = re.sub(r"\.system\(\s*([^,()]*\?\s*\.(?:" + STYLES + r")\s*:\s*\.(?:" + STYLES + r"))\s*,\s*design:\s*\.monospaced\s*\)",
                  lambda m: f".ripul({m.group(1).strip()}, family: .code)", code)
    # A design chosen at run time: `.system(.caption, design: flag ? .monospaced : .default)`.
    # Both spellings of its replacement are read as the first one.
    code = re.sub(r"\.system\(\s*\.(" + STYLES + r")\s*,\s*design:\s*([^?]+?)\s*\?\s*\.monospaced\s*:\s*\.default\s*\)",
                  lambda m: f".ripul(.{m.group(1)}, family: {m.group(2).strip()} ? .code : nil)", code)
    # Fonts first, by the same rules the rewrite applies, with every fixed size read as text.
    code = SYSTEM_STYLE_FONT.sub(system_style_font, code)
    code = STYLE_FONT.sub(style_font, code)
    code = FIXED_FONT.sub(lambda m: ".font(.ripul(size: %s%s%s)%s)" % (
        m.group(1).strip(), f", weight: {m.group(2).strip()}" if m.group(2) else "",
        ", family: .code" if m.group(3) == "monospaced" else "", m.group(4)), code)
    # The same forms with no type written before them (`v.font = .preferredFont(...)`, a
    # property typed Font, a branch of a ternary inside `.font(`).
    code = re.sub(r"(?<![\w)\]])\.system\(\s*\.(" + STYLES + r")\s*,\s*design:\s*\.monospaced\s*\)", r".ripul(.\1, family: .code)", code)
    code = re.sub(r"(?<![\w)\]])\.system\(\s*size:", ".ripul(size:", code)
    code = re.sub(r"(?<![\w)\]])\.preferredFont\(\s*forTextStyle:\s*\.(\w+)\s*\)",
                  lambda m: f".ripul(.{UIFONT_STYLE.get(m.group(1), m.group(1))})", code)
    code = re.sub(r"(?<![\w)\]])\.monospacedSystemFont\(\s*ofSize:\s*([^,()]+)(,\s*weight:\s*[^,()]+)?\)",
                  lambda m: f".ripul(size: {m.group(1).strip()}{m.group(2) or ''}, family: .code)", code)
    code = re.sub(r"(?<![\w)\]])\.systemFont\(\s*ofSize:", ".ripul(size:", code)
    code = re.sub(r"\bFont\.(" + STYLES + r")\b", r"Font.ripul(.\1)", code)
    # A bare text style wherever it stands (`return .headline`, `flag ? .caption2 : .caption`,
    # a property typed Font) is the same replacement as inside `.font(`. A name that is not a
    # font (an enum's `.body`) is changed on both sides alike, so it still compares equal.
    code = re.sub(r"(?<![\w.)\]])(?<!ripul\()(?<!Icon\()(?<!To: )(?<!Style: )\.(" + STYLES + r")\b(?!\s*\(|:)", r".ripul(.\1)", code)
    # `.ripul(.body).weight(w)` and `.ripul(.body, weight: w)` are one value, whatever `w` is.
    code = re.sub(r"\.ripul\(\s*\.(" + STYLES + r")\s*\)\.weight\(((?:[^()]|\([^()]*\))*)\)",
                  lambda m: f".ripul(.{m.group(1)}, weight: {m.group(2).strip()})", code)
    code = re.sub(r"\bFont\.system\(\s*size:", "Font.ripul(size:", code)
    code = re.sub(r"\bUIFont\.preferredFont\(\s*forTextStyle:\s*\.(\w+)\s*\)",
                  lambda m: f"UIFont.ripul(.{UIFONT_STYLE.get(m.group(1), m.group(1))})", code)
    code = re.sub(r"\bUIFont\.monospacedSystemFont\(\s*ofSize:\s*([^,()]+)(,\s*weight:\s*[^,()]+)?\)",
                  lambda m: f"UIFont.ripul(size: {m.group(1).strip()}{m.group(2) or ''}, family: .code)", code)
    code = re.sub(r"\bUIFont\.systemFont\(\s*ofSize:", "UIFont.ripul(size:", code)
    code = code.replace(".ripulIcon(", ".ripul(")
    # `UIFont.ripul(.body)` and a bare `.ripul(.body)` assigned to a UIFont are one thing.
    code = re.sub(r"\b(?:UIFont|Font)\.ripul\(", ".ripul(", code)
    # The ternary written outside is the same font as the ternary in the family.
    code = re.sub(r"\.font\(\s*([^?]+?)\s*\?\s*\.ripul\(\s*\.(" + STYLES + r")\s*,\s*family:\s*\.code\s*\)\s*:\s*\.ripul\(\s*\.\2\s*\)\s*\)",
                  lambda m: f".font(.ripul(.{m.group(2)}, family: {m.group(1).strip()} ? .code : nil))", code)
    # Colours. Wrapped UIKit colours in SwiftUI are fixed system colours.
    code = re.sub(r"\bColor\(\s*(?:uiColor:\s*)?(?:UIColor)?\.(" + SYSTEM_NAMES + r")\s*\)", lambda m: system(m.group(1)), code)
    code = re.sub(r"(?:\b(?:Color|UIColor))?\.ripul\(\s*system:\s*\.(\w+)\s*\)", lambda m: system(m.group(1)), code)
    code = re.sub(r"\bUIColor\.ripul\(\s*\.(\w+)\s*\)", lambda m: role(m.group(1)), code)
    code = re.sub(r"\bUIColor\.(" + SYSTEM_NAMES + r")\b",
                  lambda m: role(UIKIT_TEXT[m.group(1)]) if m.group(1) in UIKIT_TEXT else system(m.group(1)), code)
    # A Color is not the hierarchical style of the same name: `Color.secondary` and
    # `.secondary` draw differently in a list row, a button and a section header
    # (measured). `foregroundColor` takes a Color, so its argument is the Color form.
    code = re.sub(r"\.foregroundColor\(\s*\.(primary|secondary)\b", lambda m: ".foregroundColor(" + role("C:" + HIERARCHY[m.group(1)]), code)
    code = re.sub(r"\.foregroundColor\(\s*\.ripul\(\s*\.(text\w*)\s*\)", lambda m: ".foregroundColor(" + role("C:" + m.group(1)), code)
    code = re.sub(r"\bColor\.ripul\(\s*\.(text\w*)\s*\)", lambda m: role("C:" + m.group(1)), code)
    code = re.sub(r"\bColor\.ripul\(\s*\.(\w+)\s*\)", lambda m: role(m.group(1)), code)
    code = re.sub(r"(?<![\w)\]])\.ripul\(\s*\.(text\w*|accent|onAccent|canvas|surface\w*|separator|success|warning|danger|info|neutral)\s*\)",
                  lambda m: role(m.group(1)), code)
    code = re.sub(r"\bColor\.(primary|secondary)\b", lambda m: role("C:" + HIERARCHY[m.group(1)]), code)
    code = re.sub(r"\bColor\.accentColor\b|(?<![\w)\]])\.(?:tint|accentColor)\b(?!\s*\()", role("accent"), code)
    code = re.sub(r"\bColor\.(" + HUES + r")\b", lambda m: hue(m.group(1)), code)
    # A bare `.secondary` is the style or the Color depending on its type, which only the
    # compiler knows. Three cases can be told from the text:
    #  - the whole argument of a style call, with no colour beside it: the style;
    #  - in a style call beside a colour (`flag ? .white : .primary`): a Color, because the
    #    two branches must share one type and `.white` is only a Color;
    #  - on a line that says its type is Color: a Color.
    # Anywhere else (`tint: .secondary`, `return .secondary`) it is left open, and either
    # form is accepted in its place.
    code = bare_hierarchy(code)
    code = re.sub(r"(?<![\w)\]])\.(primary|secondary|tertiary|quaternary)\b(?!\s*\(|:)", lambda m: role(HIERARCHY[m.group(1)]), code)
    code = re.sub(r"(?<![\w)\]])\.(" + HUES + r")\b(?!\s*\(|:)", lambda m: hue(m.group(1)), code)
    code = re.sub(r"(?<![\w)\]])\.(label|secondaryLabel|tertiaryLabel|quaternaryLabel|tintColor)\b", lambda m: role(UIKIT_TEXT[m.group(1)]), code)
    code = re.sub(r"(?<![\w)\]])\.(system[A-Z]\w*|(?:secondary|tertiary)System\w+|quaternarySystemFill|separator|opaqueSeparator|placeholderText|link)\b(?!\s*\(|:)", lambda m: system(m.group(1)), code)
    return re.sub(r"\s+", "", code)


def lint(arguments):
    paths = []
    if "--" in arguments:
        cut = arguments.index("--")
        arguments, paths = arguments[:cut], arguments[cut + 1:]
    revision = arguments[0] if arguments else "HEAD"
    import subprocess
    import theme_roles
    theme_roles.load(["."])
    diff = subprocess.run(["git", "diff", "-U0", "--no-color", revision, "--", *(paths or ["*.swift"])],
                          capture_output=True, text=True, check=True).stdout
    problems, checked, file, removed, added, line = [], 0, "", [], [], 0

    def flush():
        nonlocal checked
        # The accessors' own implementation is not a call site (the check does not count it either).
        if "/ThemeCore/" in file or "/RipulThemeKit/" in file:
            return
        # A line whose only `.ripul` is a control modifier holds no token: nothing to pair.
        touched = [a for a in added if ".ripul" in control_identities(a[1])]
        if not touched:
            return
        if len(removed) != len(added):
            for number, text in touched:
                if "theme-mapping:" not in text:
                    problems.append((file, number, text, "the hunk adds and removes different numbers of lines; pair it by hand, "
                                                          "or mark the line `// theme-mapping: <reason>`"))
            return
        for (_, old), (number, new) in zip(removed, added):
            if ".ripul" not in new:
                continue
            if ".ripul" not in control_identities(new) and skeleton(old.split("//", 1)[0]) == skeleton(new.split("//", 1)[0]):
                checked += 1
                continue
            checked += 1
            if "theme-mapping:" in new or "theme-exempt:" in new:
                continue
            before, after = skeleton(old.split("//", 1)[0]), skeleton(new.split("//", 1)[0])
            if not same_value(before, after):
                problems.append((file, number, new, f"was: {old.strip()}"))

    for raw in diff.splitlines():
        if raw.startswith("+++ "):
            flush(); removed, added = [], []
            file = raw[6:] if raw.startswith("+++ b/") else raw[4:]
        elif raw.startswith("@@"):
            flush(); removed, added = [], []
            line = int(re.search(r"\+(\d+)", raw).group(1))
        elif raw.startswith("-") and not raw.startswith("---"):
            removed.append((0, raw[1:]))
        elif raw.startswith("+") and not raw.startswith("+++"):
            added.append((line, raw[1:])); line += 1
    flush()
    for file, number, text, why in problems:
        print(f"{file}:{number}: {text.strip()}\n    {why}")
    if problems:
        print(f"\nripul-theme lint: {len(problems)} of {checked + len(problems)} replacements do not keep the value they replaced.\n"
              "The closed table in docs/theming.md gives the one token for each literal. Where the\n"
              "change is meant, put `// theme-mapping: <reason>` on the new line.")
        return 1
    print(f"ripul-theme lint: {checked} replacements, each keeps the value it replaced")
    return 0


def main(argv) -> int:
    if argv[:1] == ["--lint"]:
        return lint(argv[1:])
    dry = "--dry-run" in argv
    icons_only = "--icons" in argv
    named = "--named" in argv
    targets = [a for a in argv if not a.startswith("--")]
    if not targets:
        print(__doc__)
        return 2
    total = 0
    import theme_roles
    theme_roles.load(targets)
    for target in targets:
        path = pathlib.Path(target)
        files = sorted(path.rglob("*.swift")) if path.is_dir() else [path]
        for file in files:
            if any(part in file.as_posix() for part in SKIPPED) or any(
                    part in ("build", ".build", "DerivedData", "Pods", "SourcePackages", "checkouts") or part.startswith("build-")
                    for part in file.parts[:-1]):
                continue
            text = file.read_text(encoding="utf-8")
            new, changed = rewrite(text, icons_only=icons_only, named=named)
            if not changed:
                continue
            total += changed
            print(f"{file}: {changed} line{'s' if changed != 1 else ''}")
            if dry:
                for old_line, new_line in zip(text.split("\n"), new.split("\n")):
                    if old_line != new_line:
                        print(f"  - {old_line.strip()}\n  + {new_line.strip()}")
            else:
                file.write_text(new, encoding="utf-8")
    print(f"ripul-theme migrate: {total} lines {'would change' if dry else 'changed'}")
    if "--text" in argv or "--lists" in argv:
        structure(targets, dry, text="--text" in argv, lists="--lists" in argv)
    if not dry:
        add_imports(targets)
    return 0


def structure(targets, dry, text, lists):
    """`--text`: the theme's text colour on each text that has no colour of its own.
    `--lists`: the theme's surfaces on each list, form and section. Both are what the
    plug-in does with no edit; here they are written into the source. On the line they
    belong to, so no line is added."""
    import theme_text
    files = theme_text.swift_files(targets)
    texts = lists_added = 0
    if lists:
        for path in files:
            f = theme_text.read(path)
            if f is None:
                continue
            new, count = theme_text.add_lists(f)
            if count:
                lists_added += count
                print(f"{path}: {count} list{'s' if count != 1 else ''} and section{'s' if count != 1 else ''}")
                if not dry:
                    pathlib.Path(path).write_text(new, encoding="utf-8")
        print(f"ripul-theme migrate --lists: {lists_added} lists, forms and sections {'would be' if dry else ''} given the theme's surfaces")
    if text:
        for path, (f, sites) in theme_text.analyse(files).items():
            if not sites:
                continue
            texts += len(sites)
            print(f"{path}: {len(sites)} text{'s' if len(sites) != 1 else ''} with no colour")
            if dry:
                for start, _ in sites:
                    print(f"  {f.line(start)}: {f.src[f.starts[f.line(start) - 1]:].split(chr(10), 1)[0].strip()}")
            else:
                pathlib.Path(path).write_text(theme_text.add_colour(f, sites), encoding="utf-8")
        print(f"ripul-theme migrate --text: {texts} texts {'would be' if dry else ''} given the theme's text colour. "
              "A text inside a view of your own that another file colours, or uses as a button's label, cannot be told "
              "apart: compare the screens under the system look.")


IMPORT = re.compile(r"(?m)^\s*(?:@\w+\s+)?import\s+(\w+)")


def add_imports(targets):
    """`import RipulThemeKit` in each file that calls an accessor and imports neither it nor
    the whole SDK. Not when the app has one `@_exported import` of either."""
    import theme_text
    files = [pathlib.Path(p) for p in theme_text.swift_files(targets)]
    sources = {}
    for path in files:
        try:
            sources[path] = path.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError):
            continue
    if any(re.search(r"@_exported\s+import\s+(?:RipulAgent|RipulThemeKit)\b", text) for text in sources.values()):
        return
    added = 0
    for path, text in sources.items():
        if "/Sources/RipulAgent/" in path.as_posix() or any(part in path.as_posix() for part in SKIPPED):
            continue   # the SDK's own module has it already
        if not re.search(r"\.ripul(?:Icon|ThemedList|ThemedListRows|TextStyle|ProminentButtonStyle|GlassProminentButtonStyle|ThemeRoot)?\(|\(themed:", text):
            continue
        modules = IMPORT.findall(text)
        if "RipulAgent" in modules or "RipulThemeKit" in modules:
            continue
        last = None
        for m in IMPORT.finditer(text):
            last = m
        at = text.index("\n", last.end()) + 1 if last else 0
        path.write_text(text[:at] + "import RipulThemeKit\n" + text[at:], encoding="utf-8")
        added += 1
    if added:
        print(f"ripul-theme migrate: `import RipulThemeKit` added to {added} file{'s' if added != 1 else ''}")


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
