import SwiftUI

/// The rules of an in-app web page (`open: { web, title }`), shared with the web's
/// `cmsWebPage.ts` and held to `cmsWebPage.cases.json` by both.
enum CmsWebPage {
    /// Where a link the page follows goes.
    enum Route: Equatable {
        /// Loads in the page: https (and `about:` for frames).
        case inside
        /// Handed to the system: an email, a phone number, an app's own link.
        case system
        /// Never loaded: plain http, scripts, data and files.
        case refuse
    }

    static func route(_ url: URL) -> Route {
        route(scheme: url.scheme?.lowercased() ?? "")
    }

    static func route(scheme: String) -> Route {
        switch scheme {
        case "https", "about": return .inside
        case "http", "javascript", "data", "file", "blob", "": return .refuse
        default: return .system
        }
    }

    /// The address an action names, filled from its row: an https address with a
    /// host, or nil (nothing opens).
    static func address(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    /// Opens an action's page: its address and title filled from the row. On
    /// iPhone it is pushed on the tab's stack; where nothing can push (a page
    /// shown outside `CmsAppView`, a host tab) the system's browser opens it.
    @MainActor
    static func open(_ template: String, title: String?, row: [String: CmsJSON]?, runtime: CmsRuntime) {
        let fill: (String) -> String = { text in
            row.flatMap { CmsListRowLayout.fill(text, row: $0) { CmsColumnPresentation(key: $0, json: [:]) } } ?? text
        }
        guard let url = address(fill(template)) else { return }
        let heading = title.map(fill).flatMap { $0.isEmpty ? nil : $0 } ?? (url.host ?? "")
        #if os(iOS)
        let id = UUID()
        if let push = runtime.pushFormPage,
           push(id, { AnyView(CmsWebPageView(url: url, title: heading).environmentObject(runtime)) }) {
            return
        }
        UIApplication.shared.open(url)
        #endif
    }
}
