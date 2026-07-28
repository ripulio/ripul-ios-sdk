import SwiftUI

// ---------------------------------------------------------------------------
// RipulBuildsScreen — the build feed, rendered
// ---------------------------------------------------------------------------
// Replaces the per-app OTA install page. Any host that publishes to
// POST /v1/builds gets this screen by pointing it at its app slug:
//
//     RipulBuildsScreen(source: .ripulHosted(app: "ripul"))
//
// ---------------------------------------------------------------------------

@available(iOS 17.0, macOS 14.0, *)
public struct RipulBuildsScreen: View {

    @StateObject private var store: RipulBuildFeedStore
    @State private var pendingInstall: RipulBuild?

    public init(
        source: RipulBuildFeedSource,
        baseURL: URL = AgentConfiguration.defaultBaseURL,
        tokenProvider: @escaping () -> String? = { MachineTokenStore.token }
    ) {
        _store = StateObject(wrappedValue: RipulBuildFeedStore(
            source: source,
            baseURL: baseURL,
            tokenProvider: tokenProvider
        ))
    }

    public var body: some View {
        List {
            runningBuildSection

            if let error = store.lastError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                } footer: {
                    // Saying "no builds" when the fetch failed would be a lie,
                    // and the kind that reads as "nothing was ever published".
                    Text("Showing the last build list that loaded, which may be out of date.")
                }
            }

            ForEach(store.feed?.channels ?? []) { channel in
                channelSection(channel)
            }

            if store.feed?.channels.isEmpty == true {
                Section {
                    Text("No builds have been published yet.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Builds")
        .refreshable { await store.refresh() }
        .task { await store.refresh() }
        .alert(
            "Install build \(pendingInstall?.build ?? "")?",
            isPresented: Binding(
                get: { pendingInstall != nil },
                set: { if !$0 { pendingInstall = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) { pendingInstall = nil }
            Button("Install") {
                if let build = pendingInstall { RipulBuildInstaller.install(build) }
                pendingInstall = nil
            }
        } message: {
            Text(installWarning(for: pendingInstall))
        }
    }

    // MARK: - Running build

    @ViewBuilder
    private var runningBuildSection: some View {
        Section {
            LabeledContent("Version", value: RipulBuildFeedStore.runningVersion)
            LabeledContent("Build", value: RipulBuildFeedStore.runningBuild)
            statusRow
        } header: {
            Text("This app")
        } footer: {
            if store.ownChannel == nil && store.feed != nil {
                Text("No published channel matches this app's bundle id (\(RipulBuildFeedStore.runningBundleId)), so there is nothing to compare against.")
            }
        }
    }

    @ViewBuilder
    private var statusRow: some View {
        switch store.status {
        case .unknown:
            LabeledContent("Status") {
                if store.isLoading {
                    Text("Checking…").foregroundStyle(.secondary)
                } else {
                    Text("Unknown").foregroundStyle(.secondary)
                }
            }
        case .upToDate:
            LabeledContent("Status") {
                Label("Latest", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        case .updateAvailable(let build):
            LabeledContent("Status") {
                Label("Build \(build.build) available", systemImage: "arrow.down.circle.fill")
                    .foregroundStyle(.orange)
            }
        }
    }

    // MARK: - Channels

    @ViewBuilder
    private func channelSection(_ channel: RipulBuildChannel) -> some View {
        Section {
            ForEach(channel.builds) { build in
                buildRow(build, in: channel)
            }
        } header: {
            Text(channel.title)
        } footer: {
            // The distinction users actually need before tapping Install, and
            // the one no install page ever stated.
            if store.installReplacesRunningApp(channel) {
                Text("Installing from this channel replaces the app you're using now.")
            } else {
                Text("Bundle \(channel.bundleId) — installs alongside this app as a separate icon.")
            }
        }
    }

    @ViewBuilder
    private func buildRow(_ build: RipulBuild, in channel: RipulBuildChannel) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(build.build)
                    .font(.body.monospacedDigit())
                if isRunning(build, in: channel) {
                    Text("RUNNING")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.tint.opacity(0.15), in: Capsule())
                }
                Spacer()
                installButton(build, in: channel)
            }

            if let notes = build.notes, !notes.isEmpty {
                Text(notes)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Text("v\(build.version)")
                Text("·")
                Text(build.formattedSize)
                if let date = build.builtAtDate {
                    Text("·")
                    Text(date, style: .relative)
                }
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func installButton(_ build: RipulBuild, in channel: RipulBuildChannel) -> some View {
        if isRunning(build, in: channel) {
            EmptyView()
        } else if RipulBuildInstaller.canInstall {
            Button("Install") { pendingInstall = build }
                .modifier(InstallButtonStyle())
        }
    }

    private func isRunning(_ build: RipulBuild, in channel: RipulBuildChannel) -> Bool {
        channel.bundleId == RipulBuildFeedStore.runningBundleId
            && build.build == RipulBuildFeedStore.runningBuild
    }

    private func installWarning(for build: RipulBuild?) -> String {
        guard let build else { return "" }
        let channel = store.feed?.channels.first { $0.builds.contains(build) }
        let replaces = channel.map { store.installReplacesRunningApp($0) } ?? false
        var lines: [String] = []
        if replaces {
            lines.append("This replaces the app you're using now, and iOS will close it to do so.")
        } else if let channel {
            lines.append("This installs as a separate app (\(channel.bundleId)) alongside this one.")
        }
        // The constraint Ripul hosting does not remove: the build is
        // development-signed, so Apple still gates which devices may run it.
        lines.append("Development-signed: your device must be registered on the developer account, and you may need to trust the developer in Settings afterwards.")
        return lines.joined(separator: "\n\n")
    }
}

/// Liquid Glass on iOS 26+, bordered elsewhere.
@available(iOS 17.0, macOS 14.0, *)
private struct InstallButtonStyle: ViewModifier {
    func body(content: Content) -> some View {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            content.buttonStyle(.glassProminent)
        } else {
            content.buttonStyle(.bordered)
        }
        #else
        content.buttonStyle(.bordered)
        #endif
    }
}
