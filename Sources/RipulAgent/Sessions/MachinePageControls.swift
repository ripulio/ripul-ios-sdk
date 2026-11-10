import SwiftUI

/// Alerts stay near the machine's summary, including the existing repair and
/// account sign-in flows. Only a visible, online machine reads account state.
public struct MachinePageAlerts: View {
    let machine: RemoteMachine
    let bridge: AgentBridge
    let model: RipulSessionListModel
    let isVisible: Bool
    @Environment(\.scenePhase) private var scenePhase
    @State private var alerts: [HostAlert] = []
    @State private var toolsNotice: String?
    @State private var showingAlerts = false
    @State private var pendingProfile: String?
    @State private var signIn: SignIn?
    private struct SignIn: Identifiable { let id: String }

    public init(machine: RemoteMachine, bridge: AgentBridge, model: RipulSessionListModel, isVisible: Bool) {
        self.machine = machine
        self.bridge = bridge
        self.model = model
        self.isVisible = isVisible
    }

    private var active: Bool { isVisible && scenePhase == .active && machine.isOnline }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if machine.isOnline, !alerts.isEmpty {
                MachinePageControl(title: "\(alerts.count) \(alerts.count == 1 ? "alert" : "alerts")",
                    detail: alerts.map(\.title).joined(separator: " · "), icon: "bell.badge.fill",
                    tint: .ripul(.warning), identifier: "MachineLandingScreen.alerts") { showingAlerts = true }
            }
            if machine.isOnline, let toolsNotice {
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Agents here have no Ripul tools").font(.ripul(.headline))
                        Text(toolsNotice).font(.ripul(.subheadline))
                    }
                } icon: { Image(systemName: "exclamationmark.triangle.fill") }
                    .foregroundStyle(.ripul(.warning))
            }
        }
        .task(id: active ? machine.meta?["alerts"] ?? "" : nil) {
            guard active else { return }
            let encoded = machine.meta?["alerts"]
            let decoded = await Task.detached(priority: .utility) {
                guard let data = encoded?.data(using: .utf8) else { return [HostAlert]() }
                return (try? JSONDecoder().decode([HostAlert].self, from: data)) ?? []
            }.value
            guard !Task.isCancelled else { return }
            alerts = decoded
        }
        .task(id: active && machine.can("cli") && !machine.isSharedWithMe) {
            guard active, machine.can("cli"), !machine.isSharedWithMe else { return }
            let summary = await model.accountSummary(machineId: machine.machineId)
            guard !Task.isCancelled else { return }
            toolsNotice = summary.status.toolsNotice
        }
        .ripulSheet(isPresented: $showingAlerts, onDismiss: {
            if let profile = pendingProfile {
                pendingProfile = nil
                signIn = SignIn(id: profile)
            }
        }) {
            HostAlertsSheet(machineName: machine.displayName, machineId: machine.machineId, alerts: alerts,
                onExecute: machine.isSharedWithMe ? nil : { action in
                    await bridge.executeRemoteAction(machineId: machine.machineId, actionId: action.id)
                }, onSignIn: machine.isSharedWithMe ? nil : { pendingProfile = $0 })
        }
        .ripulSheet(item: $signIn) { request in
            HostSignInSheet(machine: machine, bridge: bridge, profile: request.id, startSignInImmediately: true)
        }
    }
}

/// The host's listed actions and script editor, in the page's own scroller.
/// A deleted last script clears the list too; old cached actions are never
/// substituted for an empty discovery response.
public struct MachinePageActions: View {
    let machine: RemoteMachine
    let bridge: AgentBridge
    let isVisible: Bool
    let refreshID: Int
    @Environment(\.scenePhase) private var scenePhase
    @State private var actions: [RemoteActionDescriptor] = []
    @State private var loading = false
    @State private var showingScripts = false
    @State private var scriptsRevision = 0
    @State private var request: ActionRequest?
    @State private var confirmation: RemoteActionDescriptor?
    private struct ActionRequest: Identifiable { let action: RemoteActionDescriptor; var id: String { action.id } }
    private struct RefreshKey: Equatable { let active: Bool; let refresh: Int; let scripts: Int }
    private var active: Bool { isVisible && scenePhase == .active && machine.isOnline }

    public init(machine: RemoteMachine, bridge: AgentBridge, isVisible: Bool, refreshID: Int) {
        self.machine = machine
        self.bridge = bridge
        self.isVisible = isVisible
        self.refreshID = refreshID
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Actions and scripts").font(.ripul(.title3, weight: .semibold))
                if loading { ProgressView().controlSize(.small) }
            }
            ForEach(actions) { action in
                MachinePageControl(title: action.displayName, detail: action.description,
                    icon: action.icon ?? "bolt", tint: action.destructive ? .ripul(.danger) : .accentColor,
                    enabled: machine.isOnline, identifier: "MachineLandingScreen.action.\(action.id)") {
                    if action.destructive { confirmation = action }
                    else { request = ActionRequest(action: action) }
                }
            }
            MachinePageControl(title: "Edit scripts", detail: "Create and edit the scripts available on this machine.",
                icon: "chevron.left.forwardslash.chevron.right", enabled: machine.isOnline,
                identifier: "MachineLandingScreen.scripts") { showingScripts = true }
        }
        .task(id: RefreshKey(active: active, refresh: refreshID, scripts: scriptsRevision)) {
            guard active else { loading = false; return }
            loading = true
            let raw = await bridge.discoverRemoteActions(machineId: machine.machineId)
            guard !Task.isCancelled else { return }
            actions = raw.compactMap { RemoteActionDescriptor(from: $0) }.filter(\.listed)
            loading = false
        }
        .ripulSheet(isPresented: $showingScripts) {
            HostScriptsSheet(machine: machine, bridge: bridge) { scriptsRevision += 1 }
        }
        .ripulSheet(item: $request) { request in
            RemoteActionSheet(action: request.action) { params in
                await bridge.executeRemoteAction(machineId: machine.machineId, actionId: request.action.id, params: params)
            }
        }
        .confirmationDialog(confirmation?.displayName ?? "Run action", isPresented: Binding(
            get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }
        ), titleVisibility: .visible, presenting: confirmation) { action in
            Button("Continue", role: .destructive) { request = ActionRequest(action: action); confirmation = nil }
        } message: { _ in Text("Runs on \(machine.displayName).") }
    }
}

/// Local preferences remain usable offline and while a machine is disabled.
/// Restart reuses the model's observed offline → online acknowledgement.
public struct MachinePagePreferences: View {
    let machine: RemoteMachine
    let model: RipulSessionListModel
    let cache: RipulSessionCache
    let allowsRestart: Bool
    @StoredDefault("ripulDefaultMachineId") private var defaultMachineID = ""
    @State private var showingIcon = false
    @State private var confirmingRestart = false
    @State private var restartError: String?
    @State private var icon: String?

    public init(machine: RemoteMachine, model: RipulSessionListModel, cache: RipulSessionCache, allowsRestart: Bool) {
        self.machine = machine
        self.model = model
        self.cache = cache
        self.allowsRestart = allowsRestart
        _defaultMachineID = StoredDefault(wrappedValue: "", "ripulDefaultMachineId", store: cache.userDefaults)
        _icon = State(initialValue: machine.icon(cache: cache))
    }

    public var body: some View {
        let disabled = model.isMachineDisabled(machine)
        let isDefault = defaultMachineID == machine.machineId
        let restarting = model.restartingMachineId == machine.machineId
        let restarted = model.restartSucceededId == machine.machineId
        VStack(alignment: .leading, spacing: 12) {
            Text("Machine preferences").font(.ripul(.title3, weight: .semibold))
            if machine.can("cli") {
                MachinePageControl(title: isDefault ? "Default machine" : "Set as default",
                    detail: isDefault ? "Used for new sessions. Tap to clear the default." : "Use this machine for new sessions.",
                    icon: isDefault ? "star.fill" : "star", enabled: !disabled || isDefault,
                    identifier: "MachineLandingScreen.default") {
                    defaultMachineID = isDefault ? "" : machine.machineId
                }
            }
            MachinePageControl(title: "Set icon", detail: "Choose how this machine appears in Ripul.",
                icon: icon ?? machine.defaultIconName, identifier: "MachineLandingScreen.icon") { showingIcon = true }
            MachinePageControl(title: disabled ? "Enable machine" : "Disable machine",
                detail: disabled ? "Make this machine available for new chats and tools." : "Exclude this machine from new chats and tools on this device.",
                icon: disabled ? "checkmark.circle" : "nosign", tint: disabled ? .ripul(.success) : .ripul(.textSecondary),
                identifier: "MachineLandingScreen.enabled") { model.toggleMachineDisabled(machine) }
            if allowsRestart {
                MachinePageControl(title: restarting ? "Restarting…" : restarted ? "Restarted" : "Restart host",
                    detail: "Relaunch the Ripul host on \(machine.displayName).", icon: "arrow.triangle.2.circlepath",
                    tint: .ripul(.warning), enabled: machine.isOnline && !disabled && model.restartingMachineId == nil,
                    busy: restarting, identifier: "MachineLandingScreen.restart") { confirmingRestart = true }
            }
        }
        .ripulSheet(isPresented: $showingIcon) {
            MachineIconPicker(machineName: machine.displayName, currentIcon: icon) { selected in
                icon = selected
                RemoteMachine.setIcon(selected, for: machine.machineId, cache: cache)
            }
        }
        .confirmationDialog("Restart \(machine.displayName)?", isPresented: $confirmingRestart, titleVisibility: .visible) {
            Button("Restart host", role: .destructive) {
                Task {
                    model.connectError = nil
                    await model.restartMachine(machine)
                    restartError = model.connectError
                    model.connectError = nil
                }
            }
        } message: { Text("Active connections will be interrupted while the host restarts.") }
        .alert("Could not restart host", isPresented: Binding(
            get: { restartError != nil }, set: { if !$0 { restartError = nil } }
        )) { Button("OK") { restartError = nil } } message: { Text(restartError ?? "") }
    }
}

private struct MachinePageControl: View {
    let title: String
    let detail: String
    let icon: String
    var tint: Color = .accentColor
    var enabled = true
    var busy = false
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon).font(.ripulIcon(size: 20)).foregroundStyle(tint).frame(width: 38, height: 38)
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.ripul(.headline)).foregroundStyle(.ripul(.text))
                    if !detail.isEmpty { Text(detail).font(.ripul(.subheadline)).foregroundStyle(.ripul(.textSecondary)) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                if busy { ProgressView().controlSize(.small) }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ripul(.surface), in: RoundedRectangle(cornerRadius: 16))
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled || busy ? 1 : 0.5)
        .uiKitIdentifier(identifier)
    }
}
