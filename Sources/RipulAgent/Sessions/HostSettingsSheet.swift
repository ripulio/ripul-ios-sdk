import SwiftUI

/// One setting as the host describes it (HostRemoteSettings.swift on the Mac,
/// plus the web allowlist). The host owns the schema, so this sheet draws
/// whatever arrives and a new Mac setting needs no phone release.
public struct HostSetting: Decodable, Identifiable {
    public struct Option: Decodable, Hashable {
        public let value: String
        public let label: String
        public let detail: String?
    }
    public enum Value: Decodable, Equatable {
        case bool(Bool), number(Double), text(String), list([String])
        public init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let v = try? c.decode(Bool.self) { self = .bool(v) }
            else if let v = try? c.decode(Double.self) { self = .number(v) }
            else if let v = try? c.decode(String.self) { self = .text(v) }
            else { self = .list(try c.decode([String].self)) }
        }
        var json: Any {
            switch self {
            case .bool(let v): return v
            case .number(let v): return v
            case .text(let v): return v
            case .list(let v): return v
            }
        }
    }
    public let key: String
    public let group: String
    public let kind: String
    public let label: String
    public let detail: String?
    public var value: Value
    public let options: [Option]?
    public let min: Double?
    public let max: Double?
    public let step: Double?
    public let unit: String?
    public var id: String { key }
}

public struct HostSettingsState: Decodable {
    public let ok: Bool
    public let settings: [HostSetting]?
    public let error: String?
}

extension AgentBridge {
    /// Read the host's settings, or change one and get the fresh snapshot back.
    public func hostSettings(machineId: String, setKey key: String? = nil, value: Any? = nil) async throws -> HostSettingsState {
        var params: [String: Any] = ["action": key == nil ? "get" : "set"]
        if let key { params["key"] = key; params["value"] = value ?? NSNull() }
        let data = try JSONSerialization.data(withJSONObject: ["machineId": machineId, "params": params], options: [.sortedKeys])
        let literal = String(decoding: data, as: UTF8.self)
        let result = try await callAsyncJavaScript("""
            const request = \(literal);
            if (!window.__ripulRemoteHostSettings) return { ok: false, error: 'Update Ripul to change Mac settings.' };
            return await window.__ripulRemoteHostSettings(request.machineId, request.params);
            """)
        guard let result else { throw NSError(domain: "HostSettings", code: 1, userInfo: [NSLocalizedDescriptionKey: "The Mac did not respond."]) }
        return try JSONDecoder().decode(HostSettingsState.self, from: JSONSerialization.data(withJSONObject: result))
    }
}

/// Holds the snapshot and sends changes. Numbers are debounced so a run of
/// Stepper taps becomes one relay call.
@MainActor
final class HostSettingsModel: ObservableObject {
    let machineId: String
    let bridge: AgentBridge
    @Published var settings: [HostSetting] = []
    @Published var error: String?
    @Published var loaded = false
    @Published var saving: Set<String> = []
    private var debounces: [String: Task<Void, Never>] = [:]

    init(machineId: String, bridge: AgentBridge) { self.machineId = machineId; self.bridge = bridge }

    var groups: [(name: String, settings: [HostSetting])] {
        var order: [String] = []
        for s in settings where !order.contains(s.group) { order.append(s.group) }
        return order.map { name in (name, settings.filter { $0.group == name }) }
    }

    func setting(_ key: String) -> HostSetting? { settings.first { $0.key == key } }

    func load() async {
        do { apply(try await bridge.hostSettings(machineId: machineId)) }
        catch { self.error = error.localizedDescription }
        loaded = true
    }

    func set(_ key: String, _ value: HostSetting.Value, debounce: Bool = false) {
        guard let index = settings.firstIndex(where: { $0.key == key }), settings[index].value != value else { return }
        settings[index].value = value
        debounces[key]?.cancel()
        debounces[key] = Task {
            if debounce {
                try? await Task.sleep(nanoseconds: 600_000_000)
                if Task.isCancelled { return }
            }
            saving.insert(key)
            defer { saving.remove(key) }
            do { apply(try await bridge.hostSettings(machineId: machineId, setKey: key, value: value.json)) }
            catch {
                // Re-read what the Mac holds, but keep this failure on screen.
                let message = error.localizedDescription
                await load()
                self.error = message
            }
        }
    }

    /// The reply always carries what the Mac actually holds, so a refused
    /// change snaps back to the real value.
    private func apply(_ state: HostSettingsState) {
        if let fresh = state.settings { settings = fresh }
        error = state.ok ? nil : (state.error ?? "The Mac did not save that setting.")
    }
}

/// The Mac's settings as a pushable screen: used from iPhone Settings
/// (via `HostSettingsListScreen`) and wrapped in a sheet from the machine panel.
public struct HostSettingsForm: View {
    let machineName: String
    @StateObject private var model: HostSettingsModel

    public init(machineId: String, machineName: String, bridge: AgentBridge) {
        self.machineName = machineName
        _model = StateObject(wrappedValue: HostSettingsModel(machineId: machineId, bridge: bridge))
    }

    public var body: some View {
        Form {
            if let error = model.error {
                Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            }
            if !model.loaded {
                Section { ProgressView("Reading \(machineName)'s settings…") }
            }
            ForEach(model.groups, id: \.name) { group in
                Section(group.name) {
                    ForEach(group.settings) { setting in HostSettingRow(setting: setting, model: model) }
                }
            }
        }
        .navigationTitle(machineName)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .refreshable { await model.load() }
        .task { await model.load() }
    }
}

public struct HostSettingsSheet: View {
    let machineId: String
    let machineName: String
    let bridge: AgentBridge
    @Environment(\.dismiss) private var dismiss

    public init(machineId: String, machineName: String, bridge: AgentBridge) {
        self.machineId = machineId; self.machineName = machineName; self.bridge = bridge
    }

    public var body: some View {
        NavigationStack {
            HostSettingsForm(machineId: machineId, machineName: machineName, bridge: bridge)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() }.uiKitIdentifier("HostSettings.done") } }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 520)
        #endif
        .ripulSheet(.page, detents: [.medium, .large])
    }
}

/// iPhone Settings → Mac Settings: every Mac you own that can host, each
/// opening its `HostSettingsForm`. Direct-paired and team Macs are left out —
/// the same rule as the machine panel's Host Settings row.
public struct HostSettingsListScreen: View {
    let bridge: AgentBridge
    @State private var machines: [RemoteMachine] = []
    @State private var loading = true

    public init(bridge: AgentBridge) { self.bridge = bridge }

    public var body: some View {
        List {
            if loading { ProgressView("Loading Macs…") }
            else if machines.isEmpty { Text("Pair with a Mac to change its settings from here.").foregroundStyle(.secondary) }
            ForEach(machines) { machine in
                NavigationLink {
                    HostSettingsForm(machineId: machine.machineId, machineName: machine.displayName, bridge: bridge)
                } label: {
                    LabeledContent {
                        Text(machine.isOnline ? "Online" : "Offline").foregroundStyle(.secondary)
                    } label: {
                        Label(machine.displayName, systemImage: "desktopcomputer")
                    }
                }
                .disabled(!machine.isOnline)
                .uiKitIdentifier("HostSettingsList.machine")
            }
        }
        .navigationTitle("Mac Settings")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        machines = await bridge.listMachines().filter {
            $0.can("cli") && $0.meta?["connection"] != "direct" && $0.teamId == nil
        }
        loading = false
    }
}

private struct HostSettingRow: View {
    let setting: HostSetting
    @ObservedObject var model: HostSettingsModel

    var body: some View {
        content
            .disabled(model.saving.contains(setting.key))
            .uiKitIdentifier("HostSettings.row")
    }

    @ViewBuilder private var content: some View {
        switch (setting.kind, setting.value) {
        case ("bool", .bool(let on)):
            Toggle(isOn: Binding(get: { on }, set: { model.set(setting.key, .bool($0)) })) { labelled }
        case ("number", .number(let n)):
            Stepper(value: Binding(get: { n }, set: { model.set(setting.key, .number(roundToStep($0)), debounce: true) }),
                    in: (setting.min ?? 0)...(setting.max ?? .greatestFiniteMagnitude), step: setting.step ?? 1) {
                HStack {
                    labelled
                    Spacer()
                    Text(format(n)).foregroundStyle(.secondary).monospacedDigit()
                }
            }
        case ("choice", .text(let current)):
            VStack(alignment: .leading, spacing: 4) {
                Picker(setting.label, selection: Binding(get: { current }, set: { model.set(setting.key, .text($0)) })) {
                    ForEach(setting.options ?? [], id: \.value) { Text($0.label).tag($0.value) }
                }
                if let detail = setting.options?.first(where: { $0.value == current })?.detail ?? setting.detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
        case ("multiChoice", .list(let chosen)):
            NavigationLink {
                HostMultiChoiceScreen(key: setting.key, model: model)
            } label: {
                LabeledContent { Text(chosen.isEmpty ? "None" : "\(chosen.count)") } label: { labelled }
            }
        case ("directory", .text(let path)):
            NavigationLink {
                HostDirectoryScreen(key: setting.key, model: model)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(setting.label)
                    Text(path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                }
            }
        case ("directoryList", .list(let paths)):
            NavigationLink {
                HostDirectoryListScreen(key: setting.key, model: model)
            } label: {
                LabeledContent { Text("\(paths.count)") } label: { labelled }
            }
        default:
            // A kind this phone doesn't know yet: show it rather than hide it.
            LabeledContent(setting.label) { Text("Update Ripul to change this").foregroundStyle(.secondary) }
        }
    }

    private var labelled: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(setting.label)
            if let detail = setting.detail, setting.kind != "choice" {
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func roundToStep(_ v: Double) -> Double {
        guard let step = setting.step, step > 0 else { return v }
        return (v / step).rounded() * step
    }

    private func format(_ n: Double) -> String {
        if setting.unit == "%" { return "\(Int((n * 100).rounded()))%" }
        let text = n == n.rounded() ? String(Int(n)) : String(format: "%.1f", n)
        return setting.unit.map { text + $0 } ?? text
    }
}

private struct HostMultiChoiceScreen: View {
    let key: String
    @ObservedObject var model: HostSettingsModel

    var body: some View {
        let setting = model.setting(key)
        let chosen: [String] = { if case .list(let l)? = setting?.value { return l }; return [] }()
        List {
            Section {
                ForEach(setting?.options ?? [], id: \.value) { option in
                    Button {
                        let next = chosen.contains(option.value) ? chosen.filter { $0 != option.value } : chosen + [option.value]
                        model.set(key, .list(next))
                    } label: {
                        HStack {
                            Text(option.label).foregroundStyle(.primary)
                            Spacer()
                            if chosen.contains(option.value) { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                        }
                    }
                    .uiKitIdentifier("HostSettings.multiChoice.option")
                }
            } footer: { if let detail = setting?.detail { Text(detail) } }
        }
        .disabled(model.saving.contains(key))
        .navigationTitle(setting?.label ?? "")
    }
}

/// Pick the working folder: a favourite, a folder browsed on the Mac, or a typed path.
private struct HostDirectoryScreen: View {
    let key: String
    @ObservedObject var model: HostSettingsModel
    @State private var typed = ""
    @State private var browsing = false

    var body: some View {
        let setting = model.setting(key)
        let current: String = { if case .text(let t)? = setting?.value { return t }; return "" }()
        List {
            if let error = model.error {
                Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            }
            Section {
                Text(current).font(.callout.monospaced()).textSelection(.enabled)
            } header: { Text("Current") } footer: { if let detail = setting?.detail { Text(detail) } }
            if let options = setting?.options, !options.isEmpty {
                Section("Favorites") {
                    ForEach(options, id: \.value) { option in
                        Button { model.set(key, .text(option.value)) } label: {
                            HStack {
                                DirectoryPathLabel(path: option.value).foregroundStyle(.primary)
                                Spacer()
                                if option.value == current { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                            }
                        }
                        .uiKitIdentifier("HostSettings.directory.favorite")
                    }
                }
            }
            Section {
                Button { browsing = true } label: { Label("Browse…", systemImage: "folder") }
                    .uiKitIdentifier("HostSettings.directory.browse")
                TextField("/Users/you/repos/project", text: $typed)
                    .font(.callout.monospaced())
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .uiKitIdentifier("HostSettings.directory.path")
                Button("Use This Folder") { model.set(key, .text(typed)); typed = "" }
                    .disabled(typed.trimmingCharacters(in: .whitespaces).isEmpty)
                    .uiKitIdentifier("HostSettings.directory.use")
            } header: { Text("Other Folder") } footer: { Text("Browse the Mac's folders, or type a path. ~ means its home folder. The folder must already exist.") }
        }
        .disabled(model.saving.contains(key))
        .navigationTitle(setting?.label ?? "")
        .sheet(isPresented: $browsing) {
            RemoteFolderBrowseSheet(bridge: model.bridge, machineId: model.machineId, actionTitle: "Use This Folder", identifierPrefix: "HostSettings.browse") { model.set(key, .text($0)) }
        }
    }
}

private struct HostDirectoryListScreen: View {
    let key: String
    @ObservedObject var model: HostSettingsModel
    @State private var typed = ""
    @State private var browsing = false

    var body: some View {
        let setting = model.setting(key)
        let paths: [String] = { if case .list(let l)? = setting?.value { return l }; return [] }()
        List {
            if let error = model.error {
                Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            }
            Section {
                ForEach(paths, id: \.self) { path in
                    DirectoryPathLabel(path: path, prominence: .compact)
                }
                .onDelete { offsets in
                    var next = paths
                    next.remove(atOffsets: offsets)
                    model.set(key, .list(next))
                }
                if paths.isEmpty { Text("No favorites yet").foregroundStyle(.secondary) }
            } footer: { if let detail = setting?.detail { Text(detail) } }
            Section {
                Button { browsing = true } label: { Label("Browse…", systemImage: "folder.badge.plus") }
                    .uiKitIdentifier("HostSettings.directoryList.browse")
                TextField("/Users/you/repos/project", text: $typed)
                    .font(.callout.monospaced())
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .uiKitIdentifier("HostSettings.directoryList.path")
                Button("Add Favorite") { model.set(key, .list(paths + [typed.trimmingCharacters(in: .whitespaces)])); typed = "" }
                    .disabled(typed.trimmingCharacters(in: .whitespaces).isEmpty)
                    .uiKitIdentifier("HostSettings.directoryList.add")
            } header: { Text("Add") } footer: { Text("Browse the Mac's folders, or type a path. ~ means its home folder.") }
        }
        .disabled(model.saving.contains(key))
        .navigationTitle(setting?.label ?? "")
        .sheet(isPresented: $browsing) {
            RemoteFolderBrowseSheet(bridge: model.bridge, machineId: model.machineId, actionTitle: "Add Favorite", identifierPrefix: "HostSettings.browse") { picked in
                if !paths.contains(picked) { model.set(key, .list(paths + [picked])) }
            }
        }
    }
}
