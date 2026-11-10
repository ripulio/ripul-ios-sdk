import Foundation

// A test identity's session handed to a simulator build by the Mac host
// (`device_cms_sign_in`, chrome-extension/docs/architecture/testIdentities.md).
// The host signs in with the identity's password itself, writes the session
// into this app's own data container, and relaunches the app; the store takes
// it from there into the Keychain and deletes the file. No agent sees it.
//
// Compiled into simulator developer builds only, under the same condition as
// `RipulSimulatorTools`: a device or store build has no way in.

enum CmsTestSessionDrop {
    /// Where the host puts a session, one file per site key:
    /// `Library/Caches/io.ripul.cms.test-session/<siteKey>.json`.
    static let folderName = "io.ripul.cms.test-session"

    static func file(siteKey: String, caches: URL) -> URL? {
        guard siteKey.range(of: #"^[A-Za-z0-9_-]{1,100}$"#, options: .regularExpression) != nil else { return nil }
        return caches.appendingPathComponent(folderName, isDirectory: true).appendingPathComponent(siteKey + ".json")
    }

    /// The dropped session for this site key, removed as it is read. Nil when
    /// there is none, it is unreadable, or it has run out.
    static func take(siteKey: String, caches: URL) -> CmsSiteSession? {
        guard let url = file(siteKey: siteKey, caches: caches), let data = try? Data(contentsOf: url) else { return nil }
        try? FileManager.default.removeItem(at: url)
        guard let session = try? JSONDecoder().decode(CmsSiteSession.self, from: data), session.isValid() else { return nil }
        return session
    }

    #if targetEnvironment(simulator) && (DEBUG || RIPUL_DEVELOPER_TOOLS || RIPUL_DEVELOPER_BUILD)
    static let enabled = true
    #else
    static let enabled = false
    #endif
}
