#!/usr/bin/env python3
"""The colour roles an app declares for itself, read from its source.

An app adds a role of its own beside the SDK's fifteen by declaring it once:

    extension RipulColorRole {
        static let navy = RipulColorRole(asset: "BrandNavy")
        static let cream = RipulColorRole("cream", default: "#F4EBDD", dark: "#2A2418")
    }

The tools read those declarations so that `.ripul(.navy)` is a known role to the usage
map and the lint, `migrate` can write it where the asset was read directly, and `check`
counts a `Color("BrandNavy")` that goes round it. It reads text, not types: a role made
any other way (a name built at run time) is not seen.
"""
import pathlib
import re

DECLARATION = re.compile(
    r"\blet\s+(\w+)\s*(?::\s*RipulColorRole\s*)?=\s*(?:RipulColorRole|\.init)\(\s*"
    r"(?:asset:\s*\"([^\"]+)\"|\"([^\"]+)\"\s*,\s*default:\s*\"([^\"]+)\")")

# member -> {"name": the name in a theme document, "asset": the asset colour it is today, or None}
ROLES = {}


def declared(texts):
    roles = {}
    for text in texts:
        if "RipulColorRole" not in text:
            continue
        for member, asset, name, default in DECLARATION.findall(text):
            if asset:
                roles[member] = {"name": asset, "asset": asset}
            else:
                roles[member] = {"name": name, "asset": default[6:] if default.startswith("asset:") else None}
    return roles


def load(paths):
    """Read the declarations under the given files and directories into ROLES."""
    texts = []
    for target in paths:
        path = pathlib.Path(target)
        files = [path] if path.is_file() else sorted(path.rglob("*.swift")) if path.is_dir() else []
        for file in files:
            if any(part in ("build", ".build", "DerivedData", "Pods", "SourcePackages", "checkouts", ".git") or part.startswith("build-")
                   for part in file.parts[:-1]):
                continue
            try:
                texts.append(file.read_text(encoding="utf-8", errors="replace"))
            except OSError:
                continue
    ROLES.clear()
    ROLES.update(declared(texts))
    return ROLES


def asset_use(asset):
    """`Color("BrandNavy")`, with or without `bundle:`-less spacing."""
    return re.compile(r"\bColor\(\s*\"" + re.escape(asset) + r"\"\s*\)")


def members_pattern():
    """The declared members as a regular expression's alternatives, or one that matches nothing."""
    return "|".join(re.escape(m) for m in ROLES) or r"(?!x)x"
