import SwiftUI

/// PoC harness: browse the signed-in owner's CMS definitions and pages, then
/// render any page natively via CmsPageView. Host apps embed this with one
/// line — no cmsId plumbing needed to prove the renderer against real data.
///
/// Each definition carries a test-identity picker: **Owner** (your Clerk
/// identity + the linked site key's RLS — sees every page) or **Visitor via
/// a site key** (anonymous: site-key session token, embedded config, public
/// pages only) — the perspective a real portal visitor gets.
public struct CmsBrowserView: View {
    private let clientConfig: CmsClientConfig
    @StateObject private var loader: CmsDefinitionListLoader
    /// Per-definition test identity: nil/absent = owner; else the site key's
    /// publishable key for visitor mode.
    @State private var visitorKeyByCms: [String: String] = [:]
    /// The host app's "Native View Inspector" toggle (Settings). On iOS this
    /// AppStorage reads `.standard` — the SAME store the app writes
    /// (`UserDefaults.appDefaults` == `.standard`) — so the inspector state
    /// is shared. A portal opens in a full-screen cover, which presents ABOVE
    /// ContentView's own inspector overlay; so the cover carries its own
    /// overlay to float the inspector over the portal.
    @AppStorage("showNativeViewInspector") private var showNativeViewInspector = false
    /// Portal presentation — FULL SCREEN, not a navigation push. A portal
    /// is a self-contained app experience: pushing it hands the left screen
    /// edge to the host back-swipe, which fights the portal's own sidebar
    /// swipe. Full screen lets the portal own both edges; the unclaimed
    /// left-edge swipe (and the close button) exits.
    @State private var presented: PortalPresentation?

    private struct PortalPresentation: Identifiable {
        let cmsId: String
        let pageSlug: String
        let visitorKey: String?
        var id: String { "\(cmsId)|\(pageSlug)|\(visitorKey ?? "owner")" }
    }

    public init(clientConfig: CmsClientConfig) {
        self.clientConfig = clientConfig
        _loader = StateObject(wrappedValue: CmsDefinitionListLoader(clientConfig: clientConfig))
    }

    public var body: some View {
        List {
            switch loader.state {
            case .idle, .loading:
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
            case .error(let message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                Button("Retry") { loader.reload() }
            case .loaded(let definitions):
                if definitions.isEmpty {
                    Text("No CMS definitions")
                        .foregroundColor(.secondary)
                }
                ForEach(definitions, id: \.id) { definition in
                    Section {
                        ForEach(definition.pages ?? []) { page in
                            pageRow(definition: definition, page: page)
                        }
                    } header: {
                        sectionHeader(definition)
                    }
                }
            }
        }
        .navigationTitle("CMS Pages")
        .onAppear { loader.load() }
        .portalCover(item: $presented) { portal in
            CmsPageView(
                cmsId: portal.cmsId,
                pageSlug: portal.pageSlug,
                clientConfig: clientConfig,
                visitorSiteKey: portal.visitorKey,
                onEdgeExit: { presented = nil }
            )
            .overlay(alignment: .bottomLeading) {
                Button {
                    presented = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.footnote)
                        .padding(8)
                        .background(Circle().fill(Color.secondary.opacity(0.15)))
                }
                .buttonStyle(.plain)
                .padding(12)
            }
            // The View Explorer, floated ABOVE the portal (ContentView's own
            // overlay is below this full-screen cover). Same shared flag, so
            // toggling it in Settings lights it up here too.
            #if os(iOS)
            .overlay {
                if #available(iOS 16.0, *) {
                    ViewInspectorOverlay(isActive: $showNativeViewInspector)
                        .animation(nil)
                }
            }
            #endif
        }
    }

    @ViewBuilder
    private func pageRow(definition: CmsRenderDefinition, page: CmsPage) -> some View {
        let visitorKey = visitorKeyByCms[definition.id]
        let hiddenFromVisitor = visitorKey != nil && page.requiresAuth != false
        Button {
            presented = PortalPresentation(
                cmsId: definition.id,
                pageSlug: page.slug,
                visitorKey: visitorKey
            )
        } label: {
            HStack {
                Text(page.title.isEmpty ? page.slug : page.title)
                    .foregroundColor(hiddenFromVisitor ? .secondary : .primary)
                if hiddenFromVisitor {
                    Image(systemName: "lock")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Image(systemName: "arrow.up.forward.square")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func sectionHeader(_ definition: CmsRenderDefinition) -> some View {
        let linked = loader.siteKeys.filter { $0.cmsDefinitionId == definition.id }
        let activeKey = visitorKeyByCms[definition.id]
        let activeLabel = activeKey.flatMap { key in
            linked.first { $0.publishableKey == key }.map { "Visitor · \($0.name ?? "site key")" }
        } ?? "Owner"
        return HStack {
            Text(definition.name ?? definition.id)
            Spacer()
            Menu {
                Button {
                    visitorKeyByCms[definition.id] = nil
                } label: {
                    if activeKey == nil {
                        Label("Owner (Clerk)", systemImage: "checkmark")
                    } else {
                        Text("Owner (Clerk)")
                    }
                }
                ForEach(linked, id: \.id) { key in
                    if let publishable = key.publishableKey {
                        Button {
                            visitorKeyByCms[definition.id] = publishable
                        } label: {
                            if activeKey == publishable {
                                Label("Visitor · \(key.name ?? key.id)", systemImage: "checkmark")
                            } else {
                                Text("Visitor · \(key.name ?? key.id)")
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: activeKey == nil ? "person.badge.key" : "person")
                        .font(.caption2)
                    Text(activeLabel)
                        .font(.caption)
                }
            }
            .textCase(nil)
        }
    }
}

/// Full-screen presentation on iOS; a large sheet on macOS (no
/// fullScreenCover there).
private extension View {
    @ViewBuilder
    func portalCover<Item: Identifiable, Content: View>(
        item: Binding<Item?>,
        @ViewBuilder content: @escaping (Item) -> Content
    ) -> some View {
        #if os(iOS)
        fullScreenCover(item: item, content: content)
        #else
        sheet(item: item, content: content)
        #endif
    }
}

@MainActor
final class CmsDefinitionListLoader: ObservableObject {
    enum State {
        case idle
        case loading
        case loaded([CmsRenderDefinition])
        case error(String)
    }

    @Published var state: State = .idle
    @Published var siteKeys: [CmsSiteKeySummary] = []
    private let client: CmsClient

    init(clientConfig: CmsClientConfig) {
        self.client = CmsClient(config: clientConfig)
    }

    func load() {
        if case .idle = state {} else { return }
        reload()
    }

    func reload() {
        state = .loading
        Task {
            do {
                let summaries = try await client.listDefinitions()
                // The list endpoint returns summaries; fetch each definition
                // for its pages. Sequential is fine at PoC scale.
                var full: [CmsRenderDefinition] = []
                for summary in summaries {
                    if let detail = try? await client.fetchDefinition(cmsId: summary.id) {
                        full.append(detail)
                    } else {
                        full.append(summary)
                    }
                }
                self.siteKeys = (try? await client.listSiteKeys()) ?? []
                self.state = .loaded(full)
            } catch {
                self.state = .error(error.localizedDescription)
            }
        }
    }
}
