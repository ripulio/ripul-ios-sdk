import SwiftUI

// ---------------------------------------------------------------------------
// RipulBuildUpdateBanner — "there is a build you have not installed"
// ---------------------------------------------------------------------------
// The build list already knew this and said so quietly, four taps down inside a
// collapsed "Advanced" group. Nobody opens Advanced to ask a question they did
// not know they had, so a shipped build could sit unnoticed for days.
//
// This is the same fact, hoisted to the first thing you see in Settings and
// coloured to be impossible to skim past. It renders NOTHING unless the running
// CFBundleVersion is genuinely behind the newest build in this app's own
// channel — an always-on bar that says "up to date" would train you to ignore
// the row, which is exactly the failure being fixed.
//
//     RipulBuildUpdateBanner(source: .ripulHosted(app: "ripul")) { route = .builds }
//
// It owns its own feed store on purpose. It is the one surface that must decide
// whether to exist BEFORE a view lifecycle can drive a fetch, so the store polls
// itself (see `autoRefresh`) rather than waiting for a `.task` that would never
// run while the banner is hidden.
// ---------------------------------------------------------------------------

@available(iOS 17.0, macOS 14.0, *)
public struct RipulBuildUpdateBanner: View {

    @StateObject private var store: RipulBuildFeedStore
    @State private var pendingInstall: RipulBuild?
    private let onOpenBuilds: () -> Void

    /// - Parameter onOpenBuilds: tapping the bar's body goes here — the full
    ///   build list, with history and release notes. The Install button is the
    ///   shortcut; this is the "what is this?" path.
    public init(
        source: RipulBuildFeedSource,
        baseURL: URL = AgentConfiguration.defaultBaseURL,
        tokenProvider: @escaping () -> String? = { MachineTokenStore.token },
        onOpenBuilds: @escaping () -> Void
    ) {
        _store = StateObject(wrappedValue: RipulBuildFeedStore(
            source: source,
            baseURL: baseURL,
            tokenProvider: tokenProvider,
            autoRefresh: true
        ))
        self.onOpenBuilds = onOpenBuilds
    }

    public var body: some View {
        if case .updateAvailable(let build) = store.status {
            Section {
                bar(for: build)
                    .alert(
                        "Install build \(pendingInstall?.build ?? "")?",
                        isPresented: Binding(
                            get: { pendingInstall != nil },
                            set: { if !$0 { pendingInstall = nil } }
                        )
                    ) {
                        Button("Cancel", role: .cancel) { pendingInstall = nil }
                        Button("Install") {
                            if let build = pendingInstall { install(build) }
                            pendingInstall = nil
                        }
                    } message: {
                        Text(pendingInstall.map { store.installWarning(for: $0) } ?? "")
                    }
                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                    .listRowBackground(Color.clear)
                    .uiKitIdentifier("SettingsScreen.buildUpdateBanner")
            }
        }
    }

    // MARK: - The bar

    @ViewBuilder
    private func bar(for build: RipulBuild) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.title2)

            VStack(alignment: .leading, spacing: 1) {
                Text("New build available")
                    .font(.headline)
                Text(subtitle(for: build))
                    .font(.caption)
                    .opacity(0.85)
            }

            Spacer(minLength: 8)

            if RipulBuildInstaller.canInstall {
                // Padding and background live INSIDE the label: applied outside
                // the Button they would draw a pill whose edges aren't part of
                // its hit area, and those taps would fall through to the bar's
                // own tap gesture — a button that misses when you aim at it.
                Button {
                    pendingInstall = build
                } label: {
                    Text("Install")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.orange)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(.white, in: Capsule())
                }
                .buttonStyle(.plain)
                .uiKitIdentifier("SettingsScreen.buildUpdateBanner.installButton")
            } else {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .opacity(0.8)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color.orange, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        // The whole bar is the "show me" target; the Install button consumes its
        // own taps, so the two never fight.
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onTapGesture { onOpenBuilds() }
    }

    private func subtitle(for build: RipulBuild) -> String {
        var parts = ["Build \(build.build)"]
        if let notes = build.notes, !notes.isEmpty {
            parts.append(notes)
        } else {
            parts.append("you're on \(RipulBuildFeedStore.runningBuild)")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Install

    /// The feed's install URLs are signed and short-lived, and this banner can
    /// sit on screen far longer than they last. Refetch before giving up, so a
    /// stale link costs a round trip rather than a dead button.
    private func install(_ build: RipulBuild) {
        if RipulBuildInstaller.unavailableReason(for: build) == .installLinkExpired {
            Task {
                await store.refresh()
                if case .updateAvailable(let fresh) = store.status, fresh.id == build.id {
                    RipulBuildInstaller.install(fresh)
                } else {
                    RipulLog.error("[Builds] install link expired and the refreshed feed no longer offers \(build.build)")
                }
            }
            return
        }
        RipulBuildInstaller.install(build)
    }
}
