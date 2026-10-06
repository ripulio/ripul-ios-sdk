#if os(iOS)
import SwiftUI

// ---------------------------------------------------------------------------
// Native MESSAGES screen — an admin writes a push notification and sends it to
// people, a hand-picked set of people, or whole teams.
//
// Recipients come from the same directory as the Users screen, and the API
// demands the same permission (`admin:manage_users`), so the Solutions row
// that opens this carries that gate too.
//
// Sending is two steps on purpose: the server first resolves the audience
// (teams expanded, duplicates dropped, accounts with no device counted) as a
// dry run, and the confirmation states that count. A push cannot be recalled.
// ---------------------------------------------------------------------------

@available(iOS 16.0, *)
@MainActor
final class RipulMessagesModel: ObservableObject {
    enum LinkChoice: Hashable {
        case none
        case preset(RipulMessageLink)
        case custom
    }

    @Published private(set) var users: [RipulPlatformUser] = []
    @Published private(set) var teams: [RipulTeam] = []
    /// Registered devices per account id; absent means none.
    @Published private(set) var reach: [String: Int] = [:]
    @Published private(set) var loading = false
    @Published var loadError: String?

    @Published var selectedUserIds: Set<String> = []
    @Published var selectedTeamIds: Set<String> = []
    @Published var title = ""
    @Published var body = ""
    @Published var linkChoice: LinkChoice = .none
    @Published var customLink = ""

    /// A dry run awaiting confirmation.
    @Published var preview: RipulAdminMessageResult?
    @Published private(set) var working = false
    @Published private(set) var lastResult: RipulAdminMessageResult?
    @Published var sendError: String?

    let messaging: RipulMessagingClient
    let usersClient: RipulUsersClient
    let teamsClient: RipulTeamsClient

    init(baseURL: URL, tokenProvider: @escaping () -> String?) {
        messaging = RipulMessagingClient(baseURL: baseURL, tokenProvider: tokenProvider)
        usersClient = RipulUsersClient(baseURL: baseURL, tokenProvider: tokenProvider)
        teamsClient = RipulTeamsClient(baseURL: baseURL, tokenProvider: tokenProvider)
    }

    func load() async {
        loading = true
        loadError = nil
        async let users = usersClient.list()
        async let teams = teamsClient.listTeams()
        async let reach = messaging.reach()
        do {
            self.users = try await users.sorted {
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
            // Teams and reach only decorate the screen; people alone are enough to send.
            self.teams = (try? await teams)?.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            } ?? []
            self.reach = (try? await reach) ?? [:]
        } catch {
            loadError = error.localizedDescription
        }
        loading = false
    }

    var selectedUsers: [RipulPlatformUser] { users.filter { selectedUserIds.contains($0.id) } }
    var selectedTeams: [RipulTeam] { teams.filter { selectedTeamIds.contains($0.id) } }

    func devices(for userId: String) -> Int { reach[userId] ?? 0 }

    private var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedBody: String { body.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The link to send, or nil for none. A custom link that is not allowed
    /// yields nil too — `linkIsValid` is what blocks the send.
    var link: String? {
        switch linkChoice {
        case .none: return nil
        case .preset(let preset): return preset.url
        case .custom:
            let trimmed = customLink.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: trimmed), RipulMessageLink.isAllowed(url) else { return nil }
            return trimmed
        }
    }

    var linkIsValid: Bool { linkChoice != .custom || link != nil }

    var canSend: Bool {
        !trimmedTitle.isEmpty && !trimmedBody.isEmpty && linkIsValid
            && !(selectedUserIds.isEmpty && selectedTeamIds.isEmpty) && !working
    }

    private var message: RipulAdminMessage {
        RipulAdminMessage(
            title: trimmedTitle,
            body: trimmedBody,
            userIds: Array(selectedUserIds),
            teamIds: Array(selectedTeamIds),
            link: link
        )
    }

    /// Step one: ask the server who this would reach.
    func review() async {
        working = true
        defer { working = false }
        do {
            let result = try await messaging.send(message, dryRun: true)
            if result.devices == 0 {
                sendError = result.recipients == 0
                    ? "Those teams have no members."
                    : "None of these people has a device registered for notifications."
            } else {
                preview = result
            }
        } catch {
            sendError = error.localizedDescription
        }
    }

    /// Step two, after confirmation.
    func send() async {
        preview = nil
        working = true
        defer { working = false }
        do {
            lastResult = try await messaging.send(message, dryRun: false)
            title = ""
            body = ""
            linkChoice = .none
            customLink = ""
        } catch {
            sendError = error.localizedDescription
        }
    }
}

@available(iOS 16.0, *)
public struct RipulMessagesScreen: View {
    @StateObject private var model: RipulMessagesModel

    public init(baseURL: URL = AgentConfiguration.defaultBaseURL, tokenProvider: @escaping () -> String?) {
        _model = StateObject(wrappedValue: RipulMessagesModel(baseURL: baseURL, tokenProvider: tokenProvider))
    }

    public var body: some View {
        Form {
            recipientsSection
            messageSection
            linkSection
            Section {
                Button {
                    Task { await model.review() }
                } label: {
                    HStack {
                        Spacer()
                        if model.working {
                            ProgressView()
                        } else {
                            Label("Send", systemImage: "paperplane.fill")
                                .fontWeight(.semibold)
                        }
                        Spacer()
                    }
                }
                .disabled(!model.canSend)
                .uiKitIdentifier("Messages.send")
            }
            if let result = model.lastResult {
                lastSentSection(result)
            }
        }
        .overlay {
            if model.loading && model.users.isEmpty {
                ProgressView("Loading people…")
            }
        }
        .navigationTitle("Messages")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await model.load() }
        .task { await model.load() }
        .confirmationDialog(
            "Send this notification?",
            isPresented: Binding(
                get: { model.preview != nil },
                set: { if !$0 { model.preview = nil } }
            ),
            titleVisibility: .visible,
            presenting: model.preview
        ) { preview in
            Button("Send to \(Self.people(preview.reachable))") {
                Task { await model.send() }
            }
            Button("Cancel", role: .cancel) { model.preview = nil }
        } message: { preview in
            Text(Self.reachSummary(preview))
        }
        .alert(
            "Couldn't send",
            isPresented: Binding(
                get: { model.sendError != nil },
                set: { if !$0 { model.sendError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { model.sendError = nil }
        } message: {
            Text(model.sendError ?? "")
        }
    }

    // MARK: Sections

    private var recipientsSection: some View {
        Section {
            ForEach(model.selectedUsers) { user in
                HStack(spacing: 12) {
                    RipulUserAvatar(user: user)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(user.displayName)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                        Text(Self.deviceCaption(model.devices(for: user.id)))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .uiKitIdentifier("Messages.recipient")
            }
            .onDelete { offsets in
                let users = model.selectedUsers
                for index in offsets { model.selectedUserIds.remove(users[index].id) }
            }

            ForEach(model.selectedTeams) { team in
                Label {
                    Text(team.name)
                } icon: {
                    Image(systemName: "person.3.fill")
                }
                .uiKitIdentifier("Messages.recipientTeam")
            }
            .onDelete { offsets in
                let teams = model.selectedTeams
                for index in offsets { model.selectedTeamIds.remove(teams[index].id) }
            }

            NavigationLink {
                RipulMessagePeoplePicker(model: model)
            } label: {
                Label("Choose People", systemImage: "person.badge.plus")
            }
            .uiKitIdentifier("Messages.choosePeople")

            NavigationLink {
                RipulMessageTeamsPicker(model: model)
            } label: {
                Label("Choose Teams", systemImage: "person.3")
            }
            .disabled(model.teams.isEmpty)
            .uiKitIdentifier("Messages.chooseTeams")
        } header: {
            Text("To")
        } footer: {
            if let error = model.loadError {
                Text(error)
            } else if model.selectedUserIds.isEmpty && model.selectedTeamIds.isEmpty {
                Text("One person, several, or whole teams. Swipe a recipient to remove it.")
            }
        }
    }

    private var messageSection: some View {
        Section("Message") {
            TextField("Title", text: $model.title)
                .uiKitIdentifier("Messages.title")
            TextField("Message", text: $model.body, axis: .vertical)
                .lineLimit(3...10)
                .uiKitIdentifier("Messages.body")
        }
    }

    private var linkSection: some View {
        Section {
            Picker("Opens", selection: $model.linkChoice) {
                Text("The App").tag(RipulMessagesModel.LinkChoice.none)
                ForEach(RipulMessageLink.allCases) { link in
                    Text(link.label).tag(RipulMessagesModel.LinkChoice.preset(link))
                }
                Text("A Link…").tag(RipulMessagesModel.LinkChoice.custom)
            }
            .uiKitIdentifier("Messages.link")
            if model.linkChoice == .custom {
                TextField("https://… or ripul://share/…", text: $model.customLink)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .uiKitIdentifier("Messages.customLink")
            }
        } header: {
            Text("When Tapped")
        } footer: {
            if !model.linkIsValid && !model.customLink.isEmpty {
                Text("Use an https:// address, or ripul://share/<token>.")
                    .foregroundStyle(.red)
            }
        }
    }

    private func lastSentSection(_ result: RipulAdminMessageResult) -> some View {
        Section("Last Sent") {
            LabeledContent("Delivered", value: Self.devicesText(result.delivered))
            if result.failed > 0 {
                LabeledContent("Failed", value: Self.devicesText(result.failed))
            }
            if !result.unreachable.isEmpty {
                LabeledContent("No device", value: Self.people(result.unreachable.count))
            }
        }
    }

    // MARK: Wording

    static func people(_ count: Int) -> String { count == 1 ? "1 person" : "\(count) people" }
    static func devicesText(_ count: Int) -> String { count == 1 ? "1 device" : "\(count) devices" }

    static func deviceCaption(_ count: Int) -> String {
        count == 0 ? "No device — won't receive it" : devicesText(count)
    }

    static func reachSummary(_ result: RipulAdminMessageResult) -> String {
        var text = "\(people(result.reachable)) on \(devicesText(result.devices))."
        let missing = result.recipients - result.reachable
        if missing > 0 {
            text += " \(people(missing)) \(missing == 1 ? "has" : "have") no device and won't receive it."
        }
        return text + " A sent notification can't be recalled."
    }
}

// MARK: - Pickers

@available(iOS 16.0, *)
struct RipulMessagePeoplePicker: View {
    @ObservedObject var model: RipulMessagesModel
    @State private var search = ""

    private var filtered: [RipulPlatformUser] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return model.users }
        return model.users.filter {
            $0.displayName.lowercased().contains(q) || $0.email.lowercased().contains(q)
        }
    }

    var body: some View {
        // People who can receive it first; the rest stay pickable, because a
        // device may register before the message is sent.
        let reachable = filtered.filter { model.devices(for: $0.id) > 0 }
        let unreachable = filtered.filter { model.devices(for: $0.id) == 0 }
        List {
            if !reachable.isEmpty {
                Section("Can Receive (\(reachable.count))") {
                    ForEach(reachable) { row($0) }
                }
            }
            if !unreachable.isEmpty {
                Section("No Device (\(unreachable.count))") {
                    ForEach(unreachable) { row($0) }
                }
            }
        }
        .searchable(text: $search, prompt: "Name or email")
        .navigationTitle("People")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !model.selectedUserIds.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Clear") { model.selectedUserIds.removeAll() }
                }
            }
        }
    }

    private func row(_ user: RipulPlatformUser) -> some View {
        let selected = model.selectedUserIds.contains(user.id)
        return Button {
            if selected { model.selectedUserIds.remove(user.id) } else { model.selectedUserIds.insert(user.id) }
        } label: {
            HStack(spacing: 12) {
                RipulUserAvatar(user: user)
                VStack(alignment: .leading, spacing: 1) {
                    Text(user.displayName)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(user.email)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if selected {
                    Image(systemName: "checkmark")
                        .fontWeight(.semibold)
                        .foregroundStyle(.tint)
                }
            }
        }
        .accessibilityAddTraits(selected ? .isSelected : [])
        .uiKitIdentifier("Messages.personRow")
    }
}

@available(iOS 16.0, *)
struct RipulMessageTeamsPicker: View {
    @ObservedObject var model: RipulMessagesModel

    var body: some View {
        List(model.teams) { team in
            let selected = model.selectedTeamIds.contains(team.id)
            Button {
                if selected { model.selectedTeamIds.remove(team.id) } else { model.selectedTeamIds.insert(team.id) }
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(team.name)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)
                        if let description = team.description, !description.isEmpty {
                            Text(description)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    Spacer(minLength: 8)
                    if selected {
                        Image(systemName: "checkmark")
                            .fontWeight(.semibold)
                            .foregroundStyle(.tint)
                    }
                }
            }
            .accessibilityAddTraits(selected ? .isSelected : [])
            .uiKitIdentifier("Messages.teamRow")
        }
        .navigationTitle("Teams")
        .navigationBarTitleDisplayMode(.inline)
    }
}
#endif
