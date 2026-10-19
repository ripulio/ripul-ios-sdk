import SwiftUI

// What an invited member's requests may use of the chat owner's.
//
// A chat's owner invites people, and a member's request to the agent runs on
// the owner's Mac. This screen is where the owner says what such a request may
// use without asking them each time: their devices, the folders on their Mac,
// the browser inside Ripul Host. It is reached from a person's row in the
// chat's Permissions (ChatPermissionsScreen), and from a member's row in the
// Invite by Email sheet.
//
// The Mac holds the record and decides. The screen draws what the Mac answers
// and sends each change as it is made; the answer to a change is the whole
// picture again, so a change the Mac refuses snaps back.
// The rules: chrome-extension/docs/architecture/chatMemberAuthority.md.

public struct MemberAuthorityState: Decodable {
    public struct Member: Decodable {
        public let userId: String
        public let name: String
        /// `ask`, `named` or `acts-as-me`.
        public let level: String
        public let permissions: [String]
        /// `ask` or `refuse`: what happens to a request for something they do not hold.
        public let whenNotHeld: String?
        public let summary: String?
        public let names: [String: String]?
    }
    public struct Choice: Decodable, Identifiable {
        public let permission: String
        public let label: String
        public let current: Bool?
        public var id: String { permission }
    }
    public struct Folder: Decodable, Identifiable {
        public let path: String
        public let name: String
        public let current: Bool?
        public var id: String { path }
    }
    public struct Choices: Decodable {
        public let devices: [Choice]
        public let folders: [Folder]
        public let browsers: [Choice]
    }
    public let members: [Member]?
    public let choices: Choices?
    public let error: String?
}

extension AgentBridge {
    /// Read what a chat's members may use, or change one member and get the fresh picture back.
    public func memberAuthority(chatId: String, set change: [String: Any]? = nil) async throws -> MemberAuthorityState {
        let request: [String: Any] = ["chatId": chatId, "set": change.map { $0 as Any } ?? NSNull()]
        let data = try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])
        let literal = String(decoding: data, as: UTF8.self)
        let result = try await callAsyncJavaScript("""
            const request = \(literal);
            if (!window.__ripulMemberAuthority) return { error: 'Update Ripul to set what a member may use.' };
            return await window.__ripulMemberAuthority(request.chatId, request.set);
            """)
        guard let result else {
            throw NSError(domain: "MemberAuthority", code: 1, userInfo: [NSLocalizedDescriptionKey: "The chat's Mac did not respond."])
        }
        return try JSONDecoder().decode(MemberAuthorityState.self, from: JSONSerialization.data(withJSONObject: result))
    }
}

/// How far a member may go in one folder.
enum MemberFolderStep: String, CaseIterable, Identifiable {
    case none, read, full
    var id: String { rawValue }
    var label: String {
        switch self {
        case .none: return "No"
        case .read: return "Read"
        case .full: return "Read and change"
        }
    }
}

@MainActor
final class MemberAuthorityModel: ObservableObject {
    static let allDevices = "device:*"

    let chatId: String
    let userId: String
    let name: String
    let bridge: AgentBridge

    @Published var level = "ask"
    @Published var permissions: Set<String> = []
    @Published var refusesTheRest = false
    @Published var devices: [MemberAuthorityState.Choice] = []
    @Published var folders: [MemberAuthorityState.Folder] = []
    @Published var browsers: [MemberAuthorityState.Choice] = []
    @Published var summary: String?
    @Published var error: String?
    @Published var loaded = false
    @Published var saving = false

    private var names: [String: String] = [:]

    init(chatId: String, userId: String, name: String, bridge: AgentBridge) {
        self.chatId = chatId; self.userId = userId; self.name = name; self.bridge = bridge
    }

    var firstName: String { name.split(separator: " ").first.map(String.init) ?? name }

    func load() async {
        do { apply(try await bridge.memberAuthority(chatId: chatId)) }
        catch { self.error = error.localizedDescription }
        loaded = true
    }

    func setLevel(_ next: String) {
        guard next != level else { return }
        level = next
        // "Only what I choose" with nothing chosen yet is nothing to tell the Mac.
        if next == "named" && permissions.isEmpty { return }
        send()
    }

    func setRefusesTheRest(_ refuse: Bool) {
        guard refuse != refusesTheRest else { return }
        refusesTheRest = refuse
        send()
    }

    func holds(_ permission: String) -> Bool { permissions.contains(permission) }

    func set(_ permission: String, _ on: Bool) {
        if on { permissions.insert(permission) } else { permissions.remove(permission) }
        send()
    }

    func step(for path: String) -> MemberFolderStep {
        if permissions.contains("repo:full:\(path)") { return .full }
        return permissions.contains("repo:read:\(path)") ? .read : .none
    }

    func setStep(_ step: MemberFolderStep, for path: String) {
        permissions.remove("repo:read:\(path)")
        permissions.remove("repo:full:\(path)")
        if step != .none { permissions.insert("repo:\(step.rawValue):\(path)") }
        send()
    }

    /// What they hold that the lists above do not offer: a browser of the owner's, a device that is away.
    var otherHeld: [(permission: String, label: String)] {
        let offered = Set(devices.map(\.permission) + browsers.map(\.permission))
        return permissions.sorted()
            .filter { !offered.contains($0) && !$0.hasPrefix("repo:") }
            .map { ($0, names[$0] ?? $0) }
    }

    private func send() {
        let change: [String: Any] = [
            "userId": userId, "name": name,
            "level": level == "named" && permissions.isEmpty ? "ask" : level,
            "permissions": level == "named" ? permissions.sorted() : [],
            "whenNotHeld": refusesTheRest ? "refuse" : "ask",
        ]
        Task {
            saving = true
            defer { saving = false }
            do { apply(try await bridge.memberAuthority(chatId: chatId, set: change)) }
            catch {
                // Re-read what the Mac holds, but keep this failure on screen.
                let message = error.localizedDescription
                await load()
                self.error = message
            }
        }
    }

    /// The reply always carries what the Mac holds, so a refused change snaps back.
    private func apply(_ state: MemberAuthorityState) {
        error = state.error
        if let choices = state.choices {
            devices = choices.devices
            browsers = choices.browsers
            folders = choices.folders
        }
        guard let members = state.members else { return }
        let mine = members.first { $0.userId == userId }
        let held = Set(mine?.level == "named" ? mine?.permissions ?? [] : [])
        // The owner picked "Only what I choose" and has chosen nothing yet: the Mac calls that Ask.
        let choosing = level == "named" && held.isEmpty && (mine?.level ?? "ask") == "ask"
        if !choosing { level = mine?.level ?? "ask" }
        permissions = held
        refusesTheRest = mine?.whenNotHeld == "refuse"
        summary = mine?.summary
        names = mine?.names ?? [:]
        // A folder they hold that the Mac no longer lists still shows, so it can be taken away.
        let listed = Set(folders.map(\.path))
        for permission in held.sorted() where permission.hasPrefix("repo:") {
            let path = String(permission.split(separator: ":", maxSplits: 2).last ?? "")
            if path.hasPrefix("/"), !listed.contains(path), !folders.contains(where: { $0.path == path }) {
                folders.append(.init(path: path, name: (path as NSString).lastPathComponent, current: nil))
            }
        }
    }
}

/// One member's authority in one chat, as a pushable screen.
public struct MemberAuthorityScreen: View {
    @StateObject private var model: MemberAuthorityModel

    public init(bridge: AgentBridge, chatId: String, userId: String, name: String) {
        _model = StateObject(wrappedValue: MemberAuthorityModel(chatId: chatId, userId: userId, name: name, bridge: bridge))
    }

    public var body: some View {
        Form {
            if let error = model.error {
                Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.ripul(.warning)) }.ripulThemedListRows()
            }
            if !model.loaded {
                Section { ProgressView("Asking the chat's Mac…") }.ripulThemedListRows()
            } else {
                levelSection
                if model.level == "named" {
                    devicesSection
                    foldersSection
                    browsersSection
                    if !model.otherHeld.isEmpty { otherSection }
                }
                if model.level != "acts-as-me" { restSection }
            }
        }.ripulThemedList()
        .navigationTitle(model.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .refreshable { await model.load() }
        .task { await model.load() }
    }

    private var levelSection: some View {
        Section {
            Picker("Their requests may use", selection: Binding(get: { model.level }, set: { model.setLevel($0) })) {
                Text("Nothing standing").tag("ask")
                Text("Only what I choose").tag("named")
                Text("Everything, as me").tag("acts-as-me")
            }
            .uiKitIdentifier("MemberAuthority.levelPicker")
        } header: {
            RipulSectionHeader { Text("When \(model.firstName) asks the agent") }
        } footer: {
            RipulSectionFooter { Text(levelDetail) }
        }.ripulThemedListRows()
    }

    private var levelDetail: String {
        switch model.level {
        case "named": return "The things you switch on below run without asking you. This is for this chat only."
        case "acts-as-me": return "The agent does for \(model.firstName) whatever it would do for you in this chat: your Mac, your devices and your sign-ins, with no asks."
        default: return "\(model.firstName)'s requests use nothing of yours unless you say so each time."
        }
    }

    private var devicesSection: some View {
        Section {
            ForEach(model.devices) { device in
                let all = device.permission == MemberAuthorityModel.allDevices
                Toggle(isOn: Binding(get: { model.holds(device.permission) || (!all && model.holds(MemberAuthorityModel.allDevices)) },
                                     set: { model.set(device.permission, $0) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(device.label).ripulText()
                        if device.current == true {
                            Text("Connected").font(.ripul(.caption)).foregroundStyle(.ripul(.textSecondary))
                        }
                    }
                }
                .disabled(!all && model.holds(MemberAuthorityModel.allDevices))
                .uiKitIdentifier("MemberAuthority.deviceToggle")
            }
        } header: {
            RipulSectionHeader { Text("Devices") }
        } footer: {
            RipulSectionFooter { Text("The agent can read a device's screen and logs and act on it, as you.") }
        }.ripulThemedListRows()
    }

    private var foldersSection: some View {
        Section {
            if model.folders.isEmpty {
                Text("The Mac listed no folders.").foregroundStyle(.ripul(.textSecondary))
            }
            ForEach(model.folders) { folder in
                Picker(selection: Binding(get: { model.step(for: folder.path) }, set: { model.setStep($0, for: folder.path) })) {
                    ForEach(MemberFolderStep.allCases) { Text($0.label).tag($0) }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(folder.name).ripulText()
                        Text(folder.current == true ? "This chat's folder" : folder.path)
                            .font(.ripul(.caption)).foregroundStyle(.ripul(.textSecondary))
                            .lineLimit(1).truncationMode(.head)
                    }
                }
                .uiKitIdentifier("MemberAuthority.folderPicker")
            }
        } header: {
            RipulSectionHeader { Text("Folders on the Mac") }
        } footer: {
            RipulSectionFooter {
                Text("Read lets the agent read and search a folder. Read and change also lets it edit files and run commands there. Each command is checked before it runs. That holds an agent doing what it was asked; it is not a sandbox.")
            }
        }.ripulThemedListRows()
    }

    private var browsersSection: some View {
        Section {
            ForEach(model.browsers) { browser in
                Toggle(isOn: Binding(get: { model.holds(browser.permission) }, set: { model.set(browser.permission, $0) })) {
                    Text(browser.label.prefix(1).uppercased() + browser.label.dropFirst()).ripulText()
                }
                .uiKitIdentifier("MemberAuthority.browserToggle")
            }
        } header: {
            RipulSectionHeader { Text("Browsers") }
        } footer: {
            RipulSectionFooter { Text("The browser inside Ripul Host is signed in as you.") }
        }.ripulThemedListRows()
    }

    private var otherSection: some View {
        Section {
            ForEach(model.otherHeld, id: \.permission) { held in
                Toggle(isOn: Binding(get: { true }, set: { if !$0 { model.set(held.permission, false) } })) {
                    Text(held.label).ripulText()
                }
                .uiKitIdentifier("MemberAuthority.otherToggle")
            }
        } header: {
            RipulSectionHeader { Text("Also allowed") }
        }.ripulThemedListRows()
    }

    private var restSection: some View {
        Section {
            Picker("Anything else", selection: Binding(get: { model.refusesTheRest }, set: { model.setRefusesTheRest($0) })) {
                Text("Ask me").tag(false)
                Text("Refuse").tag(true)
            }
            .uiKitIdentifier("MemberAuthority.restPicker")
        } footer: {
            RipulSectionFooter {
                Text(model.refusesTheRest
                     ? "A request that needs something else is refused, and you are not asked."
                     : "A request that needs something else puts a card in the chat for you: one hour, once, always, or no.")
            }
        }.ripulThemedListRows()
    }
}
