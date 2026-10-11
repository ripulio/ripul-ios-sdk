#!/usr/bin/env python3
"""Tests of the theme tools on a small app that is not Ripul's: python3 tools/test_theme_tools.py"""
import json
import pathlib
import subprocess
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
TOOLS = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(TOOLS))
import theme_rewrite  # noqa: E402
import theme_usage_map  # noqa: E402

APP = '''import SwiftUI

extension View {
    func identified(_ name: String) -> some View {
        #if DEBUG
        return uiKitIdentifier(name)
        #else
        return accessibilityIdentifier(name)
        #endif
    }
    func named(as label: String) -> some View { self.identified(label) }
}

struct Stay: View {
    var body: some View {
        VStack {
            Text("Montauk")
                .font(.ripul(.title, family: .display))
                .foregroundStyle(.ripul(.text))
                .identified("stay.cottage")
            Text("Dogs welcome")
                .font(.ripul(.footnote))
                .named(as: "stay.dogs")
            Image(systemName: "house").font(.title2)
            Text("Old").font(.headline).foregroundStyle(.secondary).background(Color(.systemBackground))
            Button("Book") {}.buttonStyle(.borderedProminent)
            Text("Late").foregroundStyle(.red)
        }
    }
}
'''


class Tools(unittest.TestCase):
    def setUp(self):
        self.folder = pathlib.Path(tempfile.mkdtemp(prefix="ripul-theme-tools-"))
        (self.folder / "App").mkdir()
        (self.folder / "App" / "Stay.swift").write_text(APP)
        # A build folder holds copies of other people's source: never read.
        (self.folder / "build" / "SourcePackages").mkdir(parents=True)
        (self.folder / "build" / "SourcePackages" / "Other.swift").write_text('Text("x").font(.body).uiKitIdentifier("other")\n')

    def run_tool(self, *arguments):
        return subprocess.run([sys.executable, str(TOOLS / "ripul-theme"), *arguments], cwd=self.folder,
                              capture_output=True, text=True)

    def test_the_map_follows_a_hosts_own_identifier_modifier(self):
        result, stats = theme_usage_map.build(["."], self.folder)
        self.assertEqual(stats["wrappers"], ["identified", "named"])
        self.assertEqual(sorted(result["elements"]), ["stay.cottage", "stay.dogs"])
        roles = {t.get("role") for t in result["elements"]["stay.cottage"][0]["tokens"]}
        self.assertEqual(roles, {"title", "text"})
        self.assertEqual(result["elements"]["stay.cottage"][0]["file"], "App/Stay.swift")
        self.assertEqual([t["role"] for t in result["elements"]["stay.dogs"][0]["tokens"]], ["footnote"])

    def test_migrate_rewrites_what_keeps_its_value(self):
        new, changed = theme_rewrite.rewrite(APP)
        self.assertIn('Image(systemName: "house").font(.ripulIcon(.title2))', new)
        self.assertIn('.font(.ripul(.headline)).foregroundStyle(.ripul(.textSecondary)).background(Color.ripul(.canvas))', new)
        self.assertIn('Button("Book") {}.ripulProminentButtonStyle()', new)
        self.assertIn('.foregroundStyle(.red)', new, "a named colour is left without --named")
        self.assertEqual(changed, 3)
        named, _ = theme_rewrite.rewrite(APP, named=True)
        self.assertIn('.foregroundStyle(.ripul(.danger))', named)
        # Every replacement is one the lint reads as keeping its value.
        for old, replaced in zip(APP.split("\\n"), named.split("\\n")):
            if old != replaced:
                self.assertTrue(theme_rewrite.same_value(theme_rewrite.skeleton(old), theme_rewrite.skeleton(replaced)), replaced)

    def test_check_counts_then_reads_zero_and_a_baseline_only_falls(self):
        first = self.run_tool("check")
        self.assertEqual(first.returncode, 1)
        self.assertIn("5 direct fonts and colours in 1 files", first.stdout)
        self.assertNotIn("Other.swift", first.stdout)
        self.assertEqual(self.run_tool("check", "--baseline", "theme-baseline.json").returncode, 0)
        self.assertEqual(self.run_tool("check", "--baseline", "theme-baseline.json").returncode, 0)
        self.assertEqual(self.run_tool("migrate", "--named", ".").returncode, 0)
        after = self.run_tool("check")
        self.assertEqual(after.returncode, 0, after.stdout)
        self.assertEqual(self.run_tool("check", "--baseline", "theme-baseline.json", "--update").returncode, 0)
        self.assertEqual(json.loads((self.folder / "theme-baseline.json").read_text())["font"], 0)
        (self.folder / "App" / "New.swift").write_text('import SwiftUI\\nlet t = Text("x").font(.body)\\n')
        risen = self.run_tool("check", "--baseline", "theme-baseline.json")
        self.assertEqual(risen.returncode, 1)
        self.assertIn("above the baseline of 0", risen.stdout)

    def test_a_role_the_app_declares_is_known_to_every_tool(self):
        (self.folder / "App" / "Brand.swift").write_text(
            'import SwiftUI\n'
            'extension RipulColorRole {\n'
            '    static let navy = RipulColorRole(asset: "BrandNavy")\n'
            '    static let cream = RipulColorRole("cream", default: "#F4EBDD", dark: "#2A2418")\n'
            '}\n'
            'struct Sign: View {\n'
            '    var body: some View {\n'
            '        Text("Sandsend").foregroundStyle(Color("BrandNavy")).identified("sign.name")\n'
            '        Text("Retreats").foregroundStyle(.ripul(.cream)).identified("sign.kind")\n'
            '    }\n'
            '}\n')
        # The asset read directly goes round the role: counted, and the declaration is not.
        check = self.run_tool("check", "App/Brand.swift")
        self.assertEqual(check.returncode, 1)
        self.assertIn("1 colour", check.stdout)
        self.assertIn('Color("BrandNavy")', check.stdout)
        self.assertNotIn("static let navy", check.stdout)
        # migrate writes the role's accessor in its place, and then nothing is counted.
        self.assertIn("Brand.swift: 1 line", self.run_tool("migrate", "App/Brand.swift").stdout)
        text = (self.folder / "App" / "Brand.swift").read_text()
        self.assertIn(".foregroundStyle(Color.ripul(.navy))", text)
        self.assertEqual(self.run_tool("check", "App/Brand.swift").returncode, 0)
        # The map names each by what a theme document calls it: the asset's name, the role's name.
        result, _ = theme_usage_map.build(["App"], self.folder)
        roles = {i: [t.get("role") for site in result["elements"][i] for t in site["tokens"]] for i in ("sign.name", "sign.kind")}
        self.assertEqual(roles, {"sign.name": ["BrandNavy"], "sign.kind": ["cream"]})
        # The lint reads the asset and the accessor as one value.
        import theme_roles
        theme_roles.load([self.folder / "App"])
        self.assertEqual(theme_rewrite.skeleton('.fill(Color("BrandNavy"))'), theme_rewrite.skeleton(".fill(Color.ripul(.navy))"))
        self.assertNotEqual(theme_rewrite.skeleton('.fill(Color("BrandNavy"))'), theme_rewrite.skeleton(".fill(Color.ripul(.cream))"))
        theme_roles.ROLES.clear()

    def test_under_the_plug_in_an_asset_colour_is_a_role_of_its_own_name(self):
        (self.folder / "App" / "Sign.swift").write_text(
            'import SwiftUI\nstruct Sign: View {\n    var body: some View {\n'
            '        Text("Sandsend").foregroundStyle(Color("BrandNavy")).identified("sign.name")\n    }\n}\n')
        result, _ = theme_usage_map.build(["App"], self.folder, redirect=True)
        tokens = [t for site in result["elements"]["sign.name"] for t in site["tokens"]]
        self.assertEqual([(t["k"], t["role"]) for t in tokens], [("colour", "BrandNavy")])
        theme_usage_map.REDIRECTED["on"] = False

    def test_bare_texts_are_found_and_coloured_ones_left(self):
        import theme_text
        (self.folder / "App" / "Page.swift").write_text(
            'import SwiftUI\n'
            'struct Page: View {\n'
            '    var body: some View {\n'
            '        VStack {\n'
            '            Text("bare")\n'                                             # 5: found
            '                .font(.headline)\n'
            '            Text("grey").foregroundStyle(.secondary)\n'                 # 7: has a colour
            '            Button("Go") {}\n'
            '            Button { } label: { Text("in a button") }\n'                # 9: a control's label
            '            Button { } label: {\n'
            '                Text("plain button")\n'                                 # 11: found, the style is plain
            '            }\n'
            '            .buttonStyle(.plain)\n'
            '            HStack {\n'
            '                Text("white")\n'                                        # 15: the stack colours it
            '            }\n'
            '            .foregroundStyle(.white)\n'
            '            Badge()\n'
            '            Mark().foregroundStyle(.red)\n'
            '            List {\n'
            '                Section { Text("row") } header: { Text("head") }\n'     # 21: mixed, in the map but not a whole line
            '                NavigationLink(value: 1) {\n'
            '                    Text("list link")\n'                                # 23: found, a row of a list
            '                }\n'
            '            }\n'
            '        }\n'
            '        .navigationTitle(Text("title"))\n'                             # 27: an argument
            '    }\n'
            '}\n'
            'struct Badge: View { var body: some View {\n'
            '    Text("badge")\n'                                                   # 31: found
            '} }\n'
            'struct Mark: View { var body: some View {\n'
            '    Text("mark")\n'                                                    # 34: coloured where it is used
            '} }\n')
        path = self.folder / "App" / "Page.swift"
        f, sites = theme_text.analyse([path])[path]
        self.assertEqual([f.line(a) for a, _ in sites], [5, 11, 21, 23, 31])
        self.assertEqual(theme_text.whole_lines(f, sites), [5, 11, 23, 31])
        # check --text counts them; migrate --text writes the line; then none is left.
        self.assertIn("5 texts with no colour of their own", self.run_tool("check", "--text", "App/Page.swift").stdout)
        self.run_tool("migrate", "--text", "--lists", "App/Page.swift")
        text = path.read_text()
        self.assertIn('Text("bare").foregroundStyle(.ripul(.text))\n                .font(.ripul(.headline))', text)
        self.assertIn('Text("in a button") }', text)
        self.assertIn("}.ripulThemedList()", text)
        self.assertIn("header: { Text(\"head\") }.ripulThemedListRows()", text)
        self.assertIn("import RipulThemeKit", text)
        self.assertIn("0 texts with no colour of their own", self.run_tool("check", "--text", "App/Page.swift").stdout)
        # A second run adds nothing, and the lint reads what was added as no change of value.
        before = path.read_text()
        self.run_tool("migrate", "--text", "--lists", "App/Page.swift")
        self.assertEqual(path.read_text(), before)
        self.assertEqual(theme_rewrite.skeleton('Text("bare").foregroundStyle(.ripul(.text))'), theme_rewrite.skeleton('Text("bare")'))
        self.assertEqual(theme_rewrite.skeleton("}.ripulThemedList()"), theme_rewrite.skeleton("}"))

    def test_labels_and_accent_buttons_are_found_for_the_plug_in(self):
        import theme_text
        import theme_redirect
        path = self.folder / "App" / "More.swift"
        path.write_text(
            'import SwiftUI\n'
            'struct More: View {\n'
            '    var body: some View {\n'
            '        VStack {\n'
            '            Label("Dogs welcome", systemImage: "pawprint")\n'                 # 5: a bare label
            '            Label("Tinted", systemImage: "star").foregroundStyle(.tint)\n'    # 6: has a colour
            '            Label { Text("built") } icon: { Image(systemName: "x") }\n'       # 7: its text is a Text of its own
            '            Text(verbatim: "exact")\n'                                        # 8
            '            Text(paragraph.markdown)\n'                                       # 9
            '            Button("Book") {}\n'
            '                .buttonStyle(.borderedProminent)\n'                           # 11: takes the accent
            '            Button("Pay") {}\n'
            '                .buttonStyle(.borderedProminent)\n'                           # 13: tinted by the app
            '                .tint(.red)\n'
            '            Button("Go") {}.buttonStyle(.glassProminent)\n'                   # 15: takes the accent
            '        }\n'
            '        Form {\n'
            '            Button("Save") {}.buttonStyle(.borderedProminent)\n'              # 18: the form tints it
            '        }\n'
            '        .tint(.green)\n'
            '    }\n'
            '}\n')
        self.assertEqual(theme_text.site_table([path]), {"More.swift": [5, 7, 8, 9]})
        self.assertEqual(theme_text.button_table([path]), {"More.swift": [11, 15]})
        text, _ = theme_redirect.generate([path])
        self.assertTrue('"More.swift": [5, 7, 8, 9],' in text)
        self.assertTrue('"More.swift": [11, 15],' in text)
        self.assertNotIn("/*ACCENT-BUTTONS*/", text)
        # migrate --text writes a line on a text, never on a label: there it would colour the icon.
        self.run_tool("migrate", "--text", "App/More.swift")
        after = path.read_text()
        self.assertIn('Label("Dogs welcome", systemImage: "pawprint")\n', after)
        self.assertIn('Text(verbatim: "exact").foregroundStyle(.ripul(.text))', after)
        self.assertIn('Text(paragraph.markdown).foregroundStyle(.ripul(.text))', after)

    def test_the_build_phase_writes_only_in_debug(self):
        import os
        out = self.folder / "Products" / "App.app"
        env = dict(os.environ, SRCROOT=str(self.folder), TARGET_BUILD_DIR=str(self.folder / "Products"),
                   UNLOCALIZED_RESOURCES_FOLDER_PATH="App.app", CONFIGURATION="Release")
        command = [sys.executable, str(TOOLS / "ripul-theme"), "usage-map", "--no-sdk"]
        subprocess.run(command, env=env, check=True, capture_output=True)
        self.assertFalse((out / "ripul-theme-usage.json").exists())
        subprocess.run(command, env=dict(env, CONFIGURATION="Debug"), check=True, capture_output=True)
        self.assertEqual(sorted(json.loads((out / "ripul-theme-usage.json").read_text())["elements"]), ["stay.cottage", "stay.dogs"])



class Skill(unittest.TestCase):
    """The "theme an app" skill: one text, installed into a repository and served as a guide."""

    SKILL = TOOLS / "skills" / "theme-an-app" / "SKILL.md"

    def test_install_skill_copies_it_where_each_agent_looks(self):
        with tempfile.TemporaryDirectory() as folder:
            subprocess.run([sys.executable, str(TOOLS / "ripul-theme"), "install-skill", folder], check=True, capture_output=True)
            for home in (".claude/skills", ".agents/skills"):
                self.assertEqual((pathlib.Path(folder) / home / "theme-an-app" / "SKILL.md").read_text(), self.SKILL.read_text())

    def test_the_skill_says_what_it_is_and_names_only_what_the_package_ships(self):
        text = self.SKILL.read_text()
        self.assertTrue(text.startswith("---\nname: theme-an-app\ndescription: "))
        # The public package leaves out scripts/, and nothing of Ripul's own repository is in it.
        for absent in ("scripts/", "ripul-native-app", "chrome-extension"):
            self.assertNotIn(absent, text)

    def test_the_ripul_guide_is_the_same_text(self):
        # In Ripul's own repository the `theming` guide of ripul_guide is this file without
        # its front matter (chrome-extension/scripts/sync-theming-guide.mjs writes it).
        guide = TOOLS.parent.parent / "chrome-extension" / "public" / "guides" / "theming.md"
        if not guide.exists():
            self.skipTest("the released package has no guide beside it")
        body = self.SKILL.read_text().split("\n---\n", 1)[1].lstrip("\n")
        self.assertEqual(guide.read_text(), body, "run: node chrome-extension/scripts/sync-theming-guide.mjs")


UNEDITED = '''import SwiftUI

extension View {
    func identified(_ name: String) -> some View { uiKitIdentifier(name) }
}

extension Font {
    static var caption: Font { .custom("Georgia", size: 12) }
    static func system(size: CGFloat) -> Font { .custom("Georgia", size: size) }
}

struct WindowGroup {}

struct Stay: View {
    var body: some View {
        Text("Montauk").font(.title).foregroundStyle(.secondary).identified("stay.cottage")
    }
}
'''


class Redirect(unittest.TestCase):
    """The file the RipulThemeRedirect plug-in generates for a host that edits nothing."""

    def generate(self, source):
        import theme_redirect
        with tempfile.TemporaryDirectory() as folder:
            app = pathlib.Path(folder) / "App"
            app.mkdir()
            (app / "Stay.swift").write_text(source)
            return theme_redirect.generate([app / "Stay.swift"])

    def test_every_name_is_declared_for_a_host_with_none_of_its_own(self):
        text, left = self.generate("import SwiftUI\nstruct A {}\n")
        self.assertEqual(left, [])
        for name in ("static var body: Font", "static var caption: Font", "static func system(size: CGFloat",
                     "static var red: Color", "struct WindowGroup<Content: View>: Scene",
                     "func foregroundStyle(_ style: HierarchicalShapeStyle)"):
            self.assertIn(name, text)

    def test_lists_are_generated_and_left_out_where_a_use_is_not_covered(self):
        text, left = self.generate("import SwiftUI\nstruct A: View { var body: some View { List { Section(\"T\") { Text(\"a\") } } } }\n")
        self.assertEqual(left, [])
        bare = self.generate("import SwiftUI\nstruct A: View { var body: some View { Text(\"a\") } }\n")[0]
        self.assertTrue('"Stay.swift": [2],' in bare)
        for name in ("struct List<SelectionValue: Hashable, Content: View>: View", "struct Form<Content: View>: View",
                     "init(_ key: LocalizedStringKey, ripulFile: String = #fileID, ripulLine: UInt = #line)",
                     "struct Section<Parent: View, Content: View, Footer: View>: View",
                     "init(_ name: String, bundle: Bundle? = nil)"):
            self.assertIn(name, text)
        # A binding to the data, and a section that folds, are forms the generated ones lack.
        text, left = self.generate("import SwiftUI\nstruct A: View { @State var items: [Int] = []\n"
                                   "  var body: some View { List($items, id: \\.self) { _ in Section(\"T\", isExpanded: .constant(true)) { Form { } } } } }\n")
        self.assertEqual(sorted(k for k, _ in left), ["List", "Section"])
        self.assertNotIn("struct List<", text)
        self.assertNotIn("struct Section<", text)
        self.assertIn("struct Form<Content: View>: View", text)
        self.assertEqual(text.count("{"), text.count("}"))

    def test_a_name_the_host_declares_is_left_out_and_the_rest_stay(self):
        text, left = self.generate(UNEDITED)
        self.assertEqual(sorted(k for k, _ in left), ["WindowGroup", "static Font.caption"])
        self.assertNotIn("static var caption: Font", text)
        self.assertNotIn("struct WindowGroup<Content: View>: Scene", text)
        # A different parameter list is an overload, not a clash.
        self.assertIn("static func system(size: CGFloat, weight: Font.Weight? = nil, design: Font.Design? = nil)", text)
        self.assertIn("static var caption2: Font", text)
        self.assertEqual(text.count("{"), text.count("}"))

    def test_the_map_names_tokens_for_source_nobody_edited(self):
        text, _ = self.generate(UNEDITED)
        body = text.split('#"""\n', 1)[1].split('\n"""#', 1)[0]
        tokens = json.loads(body)["elements"]["stay.cottage"][0]["tokens"]
        self.assertIn(("type", "title"), [(t["k"], t.get("role")) for t in tokens])
        self.assertIn(("colour", "textSecondary"), [(t["k"], t.get("role")) for t in tokens])


if __name__ == "__main__":
    unittest.main()
