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


if __name__ == "__main__":
    unittest.main()
