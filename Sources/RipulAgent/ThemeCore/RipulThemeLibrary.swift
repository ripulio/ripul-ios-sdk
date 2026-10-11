import Foundation
import CoreText

// MARK: - A theme by name
//
// What a host does to have a theme: put `<name>.json` in its bundle and name it once,
// `ripulThemeRoot(theme: "<name>")` or the Info.plist key `RipulTheme`. Everything else
// is here: finding the file, reading it, registering the fonts it names, keeping the
// person's choice between launches, falling back when a file is missing or refused, and
// the switch (`RipulTheme.select`, the launch argument, the theme link).
//
// Nothing here runs for a host that names no theme and has no kept choice: such a host
// keeps the system look, or whatever it gave `adopt(documentData:)` itself.
//
// The page for hosts is `docs/theming-for-hosts.md`.

extension RipulTheme {
    /// The name that means "no document": the system look. `select("system")` chooses it
    /// and keeps the choice, where `select(nil)` forgets the choice.
    public static let systemThemeName = "system"

    /// The Info.plist key under which a host may name its theme, in place of
    /// `ripulThemeRoot(theme:)`.
    public static let infoPlistKey = "RipulTheme"

    /// Where the person's choice is kept in `UserDefaults.standard`. Being a defaults key
    /// it is also the launch argument: `-ripul.theme.document <name>`.
    public static let choiceKey = "ripul.theme.document"

    /// A theme document found in the bundle.
    public struct BundledTheme: Identifiable, Equatable, Sendable {
        /// The file's name without `.json`: what `select` takes.
        public var name: String
        /// The document's own `name`, for people. The file's name when it has none.
        public var title: String
        public var id: String { name }
    }

    private struct Library {
        var bundle: Bundle = .main
        /// The host's theme, by name. nil: the system look.
        var defaultName: String?
        var keepsChoice = true
        /// What is in use: a document's name, or `systemThemeName`. nil until `install`.
        var selected: String?
        var installed = false
    }

    private static let libraryLock = NSLock()
    private static var library = Library()
    /// Font files already given to the system, so that a switch back does not ask again.
    private static var registeredFonts: Set<URL> = []

    // MARK: install

    /// Name the host's theme and put it, or the person's kept choice, in use. Call it
    /// before the first view is built: `ripulThemeRoot(theme:)` does, and so does an
    /// `App`'s `init`. Calling it again with the same name does nothing.
    ///
    /// - Parameters:
    ///   - name: a document in the bundle, without `.json`. nil reads the Info.plist key
    ///     `RipulTheme`, and with neither the host's own look is the system's.
    ///   - bundle: where the documents and font files are. The app's own by default.
    ///   - keepsChoice: false for a build that must show one theme whatever was chosen
    ///     before: the kept choice and the launch argument are then not read.
    public static func install(theme name: String? = nil, bundle: Bundle = .main, keepsChoice: Bool = true) {
        let named = name ?? bundle.object(forInfoDictionaryKey: infoPlistKey) as? String
        libraryLock.lock()
        if library.installed, library.defaultName == named, library.bundle == bundle, library.keepsChoice == keepsChoice {
            libraryLock.unlock()
            return
        }
        library.installed = true
        library.bundle = bundle
        library.defaultName = named
        library.keepsChoice = keepsChoice
        libraryLock.unlock()

        let chosen = keepsChoice ? UserDefaults.standard.string(forKey: choiceKey) : nil
        // A host that names nothing, with nothing chosen, is left exactly as it is: it may
        // have adopted a document of its own.
        guard named != nil || chosen != nil else { return }
        if let chosen, use(chosen) { return }
        if let named, use(named) { return }
        if chosen != nil { useSystem() }
    }

    /// The root's own call: installs once, from the Info.plist key, unless the host
    /// already has.
    static func installIfNeeded() {
        libraryLock.lock()
        let installed = library.installed
        libraryLock.unlock()
        if !installed { install() }
    }

    /// The install of a host that wrote no line (`RipulThemeRedirect.root`): the theme
    /// Info.plist names, or the bundle's only theme document when it names none. With two
    /// or more documents and no name, the system look, and a line in the log saying why.
    static func installForRedirect() {
        libraryLock.lock()
        let installed = library.installed
        libraryLock.unlock()
        if installed { return }
        if Bundle.main.object(forInfoDictionaryKey: infoPlistKey) is String { install(); return }
        let themes = bundledThemes
        if themes.count > 1 {
            NSLog("[RipulTheme] %d theme documents in the bundle and none named: add the Info.plist key %@", themes.count, infoPlistKey)
        }
        install(theme: themes.count == 1 ? themes[0].name : nil)
    }

    /// Forget everything `install` and `select` did but the kept choice. Tests only.
    static func resetLibraryForTests() {
        libraryLock.lock(); library = Library(); libraryLock.unlock()
    }

    // MARK: the switch

    /// The theme in use: a bundled document's name, or `systemThemeName`. Read in a
    /// SwiftUI body it follows a change, like every accessor.
    public static var selectedTheme: String {
        _ = version
        libraryLock.lock(); defer { libraryLock.unlock() }
        return library.selected ?? library.defaultName ?? systemThemeName
    }

    /// Change the theme of the running app and keep the choice for later launches.
    ///
    /// - Parameter name: a bundled document without `.json`; `systemThemeName` for the
    ///   system look; nil to forget the choice and go back to the host's own theme.
    /// - Returns: false when the document is missing or refused. The theme in use and
    ///   the kept choice are then left as they were.
    @discardableResult
    public static func select(_ name: String?) -> Bool {
        installIfNeeded()
        libraryLock.lock()
        let fallback = library.defaultName
        let keeps = library.keepsChoice
        libraryLock.unlock()
        guard let name else {
            UserDefaults.standard.removeObject(forKey: choiceKey)
            if let fallback, use(fallback) { return true }
            useSystem()
            return true
        }
        guard use(name) else { return false }
        if keeps { UserDefaults.standard.set(name, forKey: choiceKey) }
        return true
    }

    /// The theme documents in the bundle, in name order: every `.json` at the bundle's
    /// top level or in a `Themes` or `Theme` folder that reads as a theme document.
    /// A picker lists these, and `systemThemeName` beside them if it offers the system look.
    public static var bundledThemes: [BundledTheme] {
        libraryLock.lock()
        let bundle = library.bundle
        libraryLock.unlock()
        var found: [String: BundledTheme] = [:]
        for url in resources(in: bundle, extensions: ["json"], folders: themeFolders) {
            let name = url.deletingPathExtension().lastPathComponent
            guard found[name] == nil, let data = try? Data(contentsOf: url), let title = themeTitle(of: data) else { continue }
            found[name] = BundledTheme(name: name, title: title.isEmpty ? name : title)
        }
        return found.values.sorted { $0.name < $1.name }
    }

    /// Switch by a link: `<any scheme>://theme?name=<name>`, with `name=system` for the
    /// system look. A root handles these itself in a Debug build; a host that wants them
    /// elsewhere passes its incoming URLs here.
    ///
    /// - Returns: true when the URL was a theme link, whether or not the name was found.
    @discardableResult
    public static func handleThemeLink(_ url: URL) -> Bool {
        guard (url.host ?? "").lowercased() == "theme",
              let name = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                  .queryItems?.first(where: { $0.name == "name" })?.value, !name.isEmpty else { return false }
        if selectedTheme != name { select(name) }
        return true
    }

    // MARK: loading

    private static let themeFolders = ["Themes", "themes", "Theme", "theme"]
    private static let fontFolders = ["Fonts", "fonts", "Theme", "theme", "Themes", "themes"]

    /// Put a named document in use. False, with nothing changed, when it is not in the
    /// bundle, is not a theme document, or is refused.
    private static func use(_ name: String) -> Bool {
        if name == systemThemeName { useSystem(); return true }
        libraryLock.lock()
        let bundle = library.bundle
        libraryLock.unlock()
        guard let url = resources(in: bundle, extensions: ["json"], folders: themeFolders)
                .first(where: { $0.deletingPathExtension().lastPathComponent == name }),
              let data = try? Data(contentsOf: url) else {
            NSLog("[RipulTheme] %@.json is not in the bundle; keeping the theme in use", name)
            return false
        }
        guard themeTitle(of: data) != nil else {
            NSLog("[RipulTheme] %@.json is not a theme document; keeping the theme in use", name)
            return false
        }
        // Before the document is adopted, so that the first body to run finds its faces.
        registerFonts(namedBy: data, in: bundle)
        do { try adopt(documentData: data) } catch {
            NSLog("[RipulTheme] %@.json was refused (%@); keeping the theme in use", name, String(describing: error))
            return false
        }
        libraryLock.lock(); library.selected = name; libraryLock.unlock()
        return true
    }

    private static func useSystem() {
        libraryLock.lock(); library.selected = systemThemeName; libraryLock.unlock()
        resetToDefaults()
    }

    /// The document's `name` when the data is a theme document (it says `schema`, or has
    /// one of the sections), "" when it is one with no name, nil when it is something else:
    /// a bundle holds other JSON.
    private static func themeTitle(of data: Data) -> String? {
        guard let document = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let part = document[reservedKey] as? [String: Any] ?? document
        guard part["schema"] is NSNumber || part["palette"] is [String: Any] || part["roles"] is [String: Any]
                || part[typographyKey] is [String: Any] else { return nil }
        return part["name"] as? String ?? ""
    }

    /// Files with one of the extensions at the bundle's top level, then in each of the
    /// named folders. Not a deep search: an app's bundle can hold thousands of files.
    private static func resources(in bundle: Bundle, extensions: Set<String>, folders: [String]) -> [URL] {
        guard let root = bundle.resourceURL else { return [] }
        var seen: Set<URL> = []
        var out: [URL] = []
        for directory in [root] + folders.map({ root.appendingPathComponent($0, isDirectory: true) }) {
            let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            where extensions.contains(file.pathExtension.lowercased()) {
                // A file system that ignores case lists `Fonts` and `fonts` as one folder.
                let real = file.resolvingSymlinksInPath().standardizedFileURL
                if seen.insert(real).inserted { out.append(file) }
            }
        }
        return out
    }

    // MARK: fonts

    /// Give the system the bundled font files of the families a document names, so that
    /// the host registers nothing and lists nothing in its Info.plist. A file is read only
    /// when a document names a family that is not the system's, and registered only when
    /// it holds a face of that family. One already known to the system is left alone.
    static func registerFonts(namedBy data: Data, in bundle: Bundle) {
        guard let document = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        let part = document[reservedKey] as? [String: Any] ?? document
        let families = (part[typographyKey] as? [String: Any])?["families"] as? [String: Any] ?? [:]
        let wanted = Set(families.values.compactMap { $0 as? String }.filter { !$0.hasPrefix("system") }.map { $0.lowercased() })
        guard !wanted.isEmpty else { return }
        for url in resources(in: bundle, extensions: ["ttf", "otf", "ttc"], folders: fontFolders) {
            libraryLock.lock()
            let known = registeredFonts.contains(url)
            libraryLock.unlock()
            if known { continue }
            let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor] ?? []
            let holds = descriptors.contains { descriptor in
                (CTFontDescriptorCopyAttribute(descriptor, kCTFontFamilyNameAttribute) as? String).map { wanted.contains($0.lowercased()) } ?? false
            }
            guard holds else { continue }
            var error: Unmanaged<CFError>?
            if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
                let failure = error?.takeRetainedValue()
                // Listed in the host's Info.plist, or registered by the host: already there.
                if let failure, CFErrorGetCode(failure) != CTFontManagerError.alreadyRegistered.rawValue {
                    NSLog("[RipulTheme] %@ was not registered: %@", url.lastPathComponent, String(describing: failure))
                }
            }
            libraryLock.lock(); registeredFonts.insert(url); libraryLock.unlock()
        }
    }
}
