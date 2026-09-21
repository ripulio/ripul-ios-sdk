#if os(iOS)
import SwiftUI

// ---------------------------------------------------------------------------
// Native TEAMS screens — the account holder's own teams, the invitations
// waiting for them, and (for a team owner or admin) the members, roles and
// outstanding invitations of each team.
//
// Lives under the Profile hub, not Solutions: Solutions is the platform
// admin's workbench and is hidden from everyone else, whereas a paying
// account with `account:team_management` is exactly who this is for. What
// the screen offers is decided by `GET /v1/me` and by the role held on each
// team — never by the subscription tier. See RipulTeamsClient.
// ---------------------------------------------------------------------------

/// Cross-layer hand-off for `ripul://teams` and a tapped team-invite push:
/// the host flips the latch and posts the notification; whichever surface is
/// mounted consumes it (notification when live, latch at first appear). Same
/// shape as `RipulBillingDeepLink`.
public enum RipulTeamsDeepLink {
    public static let notification = Notification.Name("ripulOpenTeamsScreen")
    /// Consumed at appear when nothing was mounted to hear the notification.
    public static var pending = false

    public static func open() {
        pending = true
        NotificationCenter.default.post(name: notification, object: nil)
    }
}

/// The web app's "Team Scope" — which team's solution context scopes chats and
/// prompt lookups. It lives in the web app's storage (TeamScopeManager.ts),
/// so a host hands the screen a way to read and write it rather than the
/// screen guessing where it is.
public struct RipulActiveTeamScope {
    public let current: () async -> String?
    public let set: (String?) async -> Void

    public init(current: @escaping () async -> String?, set: @escaping (String?) async -> Void) {
        self.current = current
        self.set = set
    }

    /// Backed by the embedded web app's localStorage, matching the key and
    /// change event `TeamScopeManager.ts` uses, so the web composer's picker
    /// and this toggle always agree.
    public static func webApp(bridge: AgentBridge) -> RipulActiveTeamScope {
        RipulActiveTeamScope(
            current: {
                let result = try? await bridge.callAsyncJavaScript(
                    "try { return window.localStorage.getItem('ripul:activeTeamId'); } catch (e) { return null; }"
                )
                let value = (result as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                return (value?.isEmpty ?? true) ? nil : value
            },
            set: { teamId in
                let literal: String
                if let teamId,
                   let data = try? JSONSerialization.data(withJSONObject: [teamId]),
                   let array = String(data: data, encoding: .utf8) {
                    // JSON-encode via a one-element array to get a safely quoted literal.
                    literal = String(array.dropFirst().dropLast())
                } else {
                    literal = "null"
                }
                _ = try? await bridge.callAsyncJavaScript("""
                    try {
                        const id = \(literal);
                        if (id) { window.localStorage.setItem('ripul:activeTeamId', id); }
                        else { window.localStorage.removeItem('ripul:activeTeamId'); }
                        window.dispatchEvent(new Event('ripul:active-team-changed'));
                        return true;
                    } catch (e) { return false; }
                    """)
            }
        )
    }
}

// MARK: - Teams list

@available(iOS 17.0, *)
@MainActor
final class RipulTeamsModel: ObservableObject {
    @Published private(set) var me: RipulMe?
    @Published private(set) var memberships: [RipulTeamMembership] = []
    /// Admin only: every other team on the platform, for oversight.
    @Published private(set) var otherTeams: [RipulTeam] = []
    @Published private(set) var invites: [RipulTeamInvite] = []
    @Published var loading = false
    @Published var errorMessage: String?
    @Published var busyInviteId: String?

    let client: RipulTeamsClient

    init(client: RipulTeamsClient) {
        self.client = client
    }

    var isAdmin: Bool { me?.isAdmin ?? false }
    var canCreateTeams: Bool { me?.canManageTeams ?? false }
    var hasLoaded: Bool { me != nil }

    func load() async {
        loading = true
        errorMessage = nil
        do {
            async let me = client.me()
            async let memberships = client.myMemberships()
            async let invites = client.myInvites()
            let (resolvedMe, mine, inbox) = try await (me, memberships, invites)
            self.me = resolvedMe
            self.memberships = mine.sorted {
                $0.teamName.localizedCaseInsensitiveCompare($1.teamName) == .orderedAscending
            }
            self.invites = inbox
            if resolvedMe.isAdmin {
                let joined = Set(mine.map(\.teamId))
                otherTeams = try await client.listTeams()
                    .filter { !joined.contains($0.id) }
                    .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            } else {
                otherTeams = []
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        loading = false
    }

    func accept(_ invite: RipulTeamInvite) async {
        busyInviteId = invite.id
        defer { busyInviteId = nil }
        do {
            try await client.acceptInvite(invite.id)
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func decline(_ invite: RipulTeamInvite) async {
        busyInviteId = invite.id
        defer { busyInviteId = nil }
        do {
            try await client.declineInvite(invite.id)
            invites.removeAll { $0.id == invite.id }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func create(name: String, description: String?) async -> Bool {
        do {
            _ = try await client.createTeam(name: name, description: description)
            await load()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}

@available(iOS 17.0, *)
public struct RipulTeamsScreen: View {
    @StateObject private var model: RipulTeamsModel
    private let client: RipulTeamsClient
    private let activeTeam: RipulActiveTeamScope?
    @State private var showingCreate = false

    /// - Parameter activeTeam: how to read and write the chat team scope. nil
    ///   hides the "Use for my chats" control entirely.
    public init(client: RipulTeamsClient, activeTeam: RipulActiveTeamScope? = nil) {
        self.client = client
        self.activeTeam = activeTeam
        _model = StateObject(wrappedValue: RipulTeamsModel(client: client))
    }

    public var body: some View {
        List {
            if !model.invites.isEmpty {
                invitationsSection
            }
            myTeamsSection
            if model.isAdmin, !model.otherTeams.isEmpty {
                otherTeamsSection
            }
            if let me = model.me {
                Section {
                    Text(me.canManageTeams
                         ? "Your plan includes team management."
                         : "Creating teams needs the Lifetime plan or an admin role. You can still join teams you're invited to.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .listRowBackground(Color.clear)
                }
            }
        }
        .overlay { emptyState }
        .navigationTitle("Teams")
        .navigationBarTitleDisplayMode(.inline)
        .uiKitIdentifier("RipulTeamsScreen")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if model.canCreateTeams {
                    Button {
                        showingCreate = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("New team")
                    .uiKitIdentifier("Teams.create")
                }
            }
        }
        .refreshable { await model.load() }
        .task { await model.load() }
        .sheet(isPresented: $showingCreate) {
            RipulTeamEditorSheet(title: "New Team", name: "", description: "") { name, description in
                await model.create(name: name, description: description)
            }
        }
        .ripulTeamsErrorAlert($model.errorMessage)
    }

    private var invitationsSection: some View {
        Section("Invitations") {
            ForEach(model.invites) { invite in
                RipulTeamInviteInboxRow(
                    invite: invite,
                    busy: model.busyInviteId == invite.id,
                    onAccept: { Task { await model.accept(invite) } },
                    onDecline: { Task { await model.decline(invite) } }
                )
                .uiKitIdentifier("Teams.invite")
            }
        }
    }

    private var myTeamsSection: some View {
        Section {
            if model.memberships.isEmpty, model.hasLoaded {
                Text("You're not in any teams yet.")
                    .foregroundStyle(.secondary)
            }
            ForEach(model.memberships) { membership in
                NavigationLink {
                    RipulTeamDetailScreen(
                        client: client,
                        teamId: membership.teamId,
                        teamName: membership.teamName,
                        me: model.me,
                        activeTeam: activeTeam,
                        onChange: { Task { await model.load() } }
                    )
                } label: {
                    teamRow(name: membership.teamName, role: membership.role.label)
                }
                .uiKitIdentifier("Teams.row")
            }
        } header: {
            Text("My teams")
        } footer: {
            if !model.memberships.isEmpty {
                Text("Teams share deployed tools, prompts and artefacts, and can scope which solution context your chats use.")
            }
        }
    }

    private var otherTeamsSection: some View {
        Section {
            ForEach(model.otherTeams) { team in
                NavigationLink {
                    RipulTeamDetailScreen(
                        client: client,
                        teamId: team.id,
                        teamName: team.name,
                        me: model.me,
                        activeTeam: nil,
                        onChange: { Task { await model.load() } }
                    )
                } label: {
                    teamRow(name: team.name, role: "Not a member")
                }
            }
        } header: {
            Text("All teams")
        } footer: {
            Text("Visible because you're a platform admin.")
        }
    }

    @ViewBuilder
    private func teamRow(name: String, role: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "person.2.fill")
                .foregroundStyle(.tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text(role)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var emptyState: some View {
        if model.loading, !model.hasLoaded {
            ProgressView("Loading teams…")
        } else if !model.loading, !model.hasLoaded {
            VStack(spacing: 8) {
                Image(systemName: "person.2")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text(model.errorMessage ?? "Couldn't load your teams")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Retry") { Task { await model.load() } }
                    .buttonStyle(.bordered)
            }
            .padding()
        }
    }
}

@available(iOS 17.0, *)
struct RipulTeamInviteInboxRow: View {
    let invite: RipulTeamInvite
    let busy: Bool
    let onAccept: () -> Void
    let onDecline: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(invite.teamName ?? invite.teamId)
                .font(.subheadline.weight(.semibold))
            Text("\(invite.inviterName ?? "Someone") invited you to join as \(invite.role.label.lowercased()).")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let description = invite.teamDescription {
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            HStack(spacing: 8) {
                Button(action: onAccept) {
                    Label("Accept", systemImage: "checkmark")
                }
                .buttonStyle(.borderedProminent)
                .uiKitIdentifier("Teams.invite.accept")
                Button(role: .destructive, action: onDecline) {
                    Text("Decline")
                }
                .buttonStyle(.bordered)
                .uiKitIdentifier("Teams.invite.decline")
                if busy { ProgressView().controlSize(.small) }
            }
            .controlSize(.small)
            .disabled(busy)
            .padding(.top, 2)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Team detail

@available(iOS 17.0, *)
@MainActor
final class RipulTeamDetailModel: ObservableObject {
    @Published private(set) var detail: RipulTeamDetail?
    @Published private(set) var invites: [RipulTeamInvite] = []
    @Published var loading = false
    @Published var errorMessage: String?
    @Published private(set) var isActiveForChats = false
    @Published var busyMemberId: String?

    let client: RipulTeamsClient
    let teamId: String
    let me: RipulMe?
    let activeTeam: RipulActiveTeamScope?

    init(client: RipulTeamsClient, teamId: String, me: RipulMe?, activeTeam: RipulActiveTeamScope?) {
        self.client = client
        self.teamId = teamId
        self.me = me
        self.activeTeam = activeTeam
    }

    var myRole: RipulTeamRole? {
        detail?.members.first { $0.userId == me?.userId }?.role
    }

    /// Mirrors `requireTeamManager`: a global admin, or an owner/admin of THIS team.
    var canManage: Bool {
        (me?.isAdmin ?? false) || (myRole?.canManage ?? false)
    }

    /// Mirrors `handleDeleteTeam`: the team-management permission AND
    /// ownership of this team, unless a global admin.
    var canDelete: Bool {
        guard let me else { return false }
        if me.isAdmin { return true }
        return me.canManageTeams && myRole == .owner
    }

    var members: [RipulTeamMember] {
        (detail?.members ?? []).sorted {
            if $0.role != $1.role { return $0.role > $1.role }
            return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }

    func load() async {
        loading = true
        errorMessage = nil
        do {
            detail = try await client.team(teamId)
            if canManage {
                // Addresses are manager-only server-side; a member gets a 403
                // here, which is the ordinary case, not a fault.
                invites = (try? await client.invites(teamId: teamId)) ?? []
            } else {
                invites = []
            }
            if let activeTeam {
                isActiveForChats = await activeTeam.current() == teamId
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        loading = false
    }

    func setActiveForChats(_ on: Bool) async {
        guard let activeTeam else { return }
        await activeTeam.set(on ? teamId : nil)
        isActiveForChats = on
    }

    func invite(email: String?, userId: String?, role: RipulTeamRole) async -> Bool {
        do {
            if let userId = userId?.trimmingCharacters(in: .whitespacesAndNewlines), !userId.isEmpty {
                try await client.addMember(teamId: teamId, userId: userId, role: role)
            } else if let email = email?.trimmingCharacters(in: .whitespacesAndNewlines), !email.isEmpty {
                try await client.invite(teamId: teamId, email: email, role: role)
            } else {
                errorMessage = "Enter an email address."
                return false
            }
            await load()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func revoke(_ invite: RipulTeamInvite) async {
        do {
            try await client.revokeInvite(teamId: teamId, inviteId: invite.id)
            invites.removeAll { $0.id == invite.id }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func setRole(_ member: RipulTeamMember, _ role: RipulTeamRole) async {
        guard role != member.role else { return }
        busyMemberId = member.userId
        defer { busyMemberId = nil }
        do {
            try await client.updateMemberRole(teamId: teamId, userId: member.userId, role: role)
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func remove(_ member: RipulTeamMember) async {
        busyMemberId = member.userId
        defer { busyMemberId = nil }
        do {
            try await client.removeMember(teamId: teamId, userId: member.userId)
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func update(name: String, description: String?) async -> Bool {
        do {
            _ = try await client.updateTeam(teamId, name: name, description: description)
            await load()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func delete() async -> Bool {
        do {
            try await client.deleteTeam(teamId)
            if isActiveForChats { await activeTeam?.set(nil) }
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}

@available(iOS 17.0, *)
struct RipulTeamDetailScreen: View {
    @StateObject private var model: RipulTeamDetailModel
    private let initialName: String
    private let onChange: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var showingInvite = false
    @State private var showingEdit = false
    @State private var confirmDelete = false
    @State private var memberToRemove: RipulTeamMember?

    init(
        client: RipulTeamsClient,
        teamId: String,
        teamName: String,
        me: RipulMe?,
        activeTeam: RipulActiveTeamScope?,
        onChange: @escaping () -> Void
    ) {
        self.initialName = teamName
        self.onChange = onChange
        _model = StateObject(wrappedValue: RipulTeamDetailModel(
            client: client, teamId: teamId, me: me, activeTeam: activeTeam
        ))
    }

    private var team: RipulTeam? { model.detail?.team }

    var body: some View {
        List {
            aboutSection
            membersSection
            if model.canManage {
                invitationsSection
            }
        }
        .navigationTitle(team?.name ?? initialName)
        .navigationBarTitleDisplayMode(.inline)
        .uiKitIdentifier("RipulTeamDetailScreen")
        .toolbar {
            if model.canManage {
                ToolbarItem(placement: .topBarTrailing) {
                    // Invite lives in the Members section as a row; the menu keeps
                    // the rarer team-level actions.
                    Menu {
                        Button {
                            showingEdit = true
                        } label: {
                            Label("Edit name and description…", systemImage: "pencil")
                        }
                        if model.canDelete {
                            Divider()
                            Button(role: .destructive) {
                                confirmDelete = true
                            } label: {
                                Label("Delete team", systemImage: "trash")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .uiKitIdentifier("TeamDetail.menu")
                }
            }
        }
        .refreshable { await model.load() }
        .task { await model.load() }
        .sheet(isPresented: $showingInvite) {
            RipulTeamInviteSheet(allowUserId: model.me?.isAdmin ?? false) { email, userId, role in
                let ok = await model.invite(email: email, userId: userId, role: role)
                if ok { onChange() }
                return ok
            }
        }
        .sheet(isPresented: $showingEdit) {
            RipulTeamEditorSheet(
                title: "Edit Team",
                name: team?.name ?? initialName,
                description: team?.description ?? ""
            ) { name, description in
                let ok = await model.update(name: name, description: description)
                if ok { onChange() }
                return ok
            }
        }
        .confirmationDialog(
            "Delete \(team?.name ?? initialName)?",
            isPresented: $confirmDelete,
            titleVisibility: .visible
        ) {
            Button("Delete Team", role: .destructive) {
                Task {
                    if await model.delete() {
                        onChange()
                        dismiss()
                    }
                }
            }
        } message: {
            Text("Members lose access to everything shared with this team. This can't be undone.")
        }
        .confirmationDialog(
            "Remove \(memberToRemove?.title ?? "member")?",
            isPresented: Binding(get: { memberToRemove != nil }, set: { if !$0 { memberToRemove = nil } }),
            titleVisibility: .visible,
            presenting: memberToRemove
        ) { member in
            Button("Remove from Team", role: .destructive) {
                Task {
                    await model.remove(member)
                    onChange()
                }
            }
        } message: { _ in
            Text("They'll lose access to this team's tools, prompts and artefacts.")
        }
        .ripulTeamsErrorAlert($model.errorMessage)
    }

    private var aboutSection: some View {
        Section {
            if let description = team?.description {
                Text(description)
                    .font(.subheadline)
            }
            if let role = model.myRole {
                LabeledContent("Your role", value: role.label)
            } else if model.me?.isAdmin == true {
                LabeledContent("Your role", value: "Platform admin")
            }
            if model.activeTeam != nil, model.myRole != nil {
                Toggle(
                    "Use for my chats",
                    isOn: Binding(
                        get: { model.isActiveForChats },
                        set: { on in Task { await model.setActiveForChats(on) } }
                    )
                )
                .uiKitIdentifier("TeamDetail.activeForChats")
            }
        } footer: {
            if model.activeTeam != nil, model.myRole != nil {
                Text("When on, chats and prompt lookups are scoped to this team's solution context. If you're in several teams with different contexts, one must be chosen or requests are refused.")
            }
        }
    }

    private var membersSection: some View {
        Section {
            // The one thing a manager comes here to do sits in the list, not
            // behind the toolbar menu: a full-width row, first in the section.
            if model.canManage {
                Button {
                    showingInvite = true
                } label: {
                    Label(model.me?.isAdmin == true ? "Invite or add someone" : "Invite someone by email",
                          systemImage: "person.badge.plus")
                }
                .uiKitIdentifier("TeamDetail.members.invite")
            }
            if model.members.isEmpty, model.detail != nil {
                Text("No members yet.")
                    .foregroundStyle(.secondary)
            }
            ForEach(model.members) { member in
                memberRow(member)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        if model.canManage {
                            Button(role: .destructive) {
                                memberToRemove = member
                            } label: {
                                Label("Remove", systemImage: "person.badge.minus")
                            }
                        }
                    }
                    .uiKitIdentifier("TeamDetail.member")
            }
        } header: {
            HStack {
                Text("Members")
                if !model.members.isEmpty { Text("(\(model.members.count))") }
            }
        } footer: {
            if model.canManage {
                Text("Owners and admins can invite people and change roles. A team always keeps at least one owner.")
            }
        }
    }

    @ViewBuilder
    private func memberRow(_ member: RipulTeamMember) -> some View {
        HStack(spacing: 12) {
            RipulTeamMemberAvatar(member: member)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(member.title)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    if member.userId == model.me?.userId {
                        Text("you")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                if let subtitle = member.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if model.busyMemberId == member.userId {
                ProgressView().controlSize(.small)
            } else if model.canManage {
                Menu {
                    ForEach(RipulTeamRole.allCases, id: \.self) { role in
                        Button {
                            Task {
                                await model.setRole(member, role)
                                onChange()
                            }
                        } label: {
                            if role == member.role {
                                Label(role.label, systemImage: "checkmark")
                            } else {
                                Text(role.label)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 3) {
                        Text(member.role.label)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2)
                    }
                    .font(.caption)
                    .foregroundStyle(.tint)
                }
                .uiKitIdentifier("TeamDetail.member.role")
            } else {
                Text(member.role.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private var invitationsSection: some View {
        Section {
            if model.invites.isEmpty {
                Text("No outstanding invitations.")
                    .foregroundStyle(.secondary)
            }
            ForEach(model.invites) { invite in
                VStack(alignment: .leading, spacing: 1) {
                    Text(invite.email)
                        .font(.subheadline)
                        .lineLimit(1)
                    Text(inviteFootnote(invite))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        Task { await model.revoke(invite) }
                    } label: {
                        Label("Withdraw", systemImage: "xmark")
                    }
                }
                .uiKitIdentifier("TeamDetail.invite")
            }
        } header: {
            Text("Invitations")
        } footer: {
            Text("Invitations expire after two weeks. Swipe to withdraw one.")
        }
    }

    private func inviteFootnote(_ invite: RipulTeamInvite) -> String {
        var parts = ["As \(invite.role.label.lowercased())"]
        if let expires = invite.expiresAt {
            parts.append("expires \(expires.formatted(.relative(presentation: .named)))")
        }
        return parts.joined(separator: " · ")
    }
}

@available(iOS 17.0, *)
struct RipulTeamMemberAvatar: View {
    let member: RipulTeamMember

    var body: some View {
        ZStack {
            Circle().fill(.tint.opacity(0.15))
            if let imageURL = member.imageURL, let url = URL(string: imageURL) {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    initials
                }
                .clipShape(Circle())
            } else {
                initials
            }
        }
        .frame(width: 34, height: 34)
        .clipShape(Circle())
    }

    private var initials: some View {
        Text(member.initials)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.tint)
    }
}

// MARK: - Sheets

/// Create or rename a team. `onSave` returns whether it succeeded; the sheet
/// stays open on failure so the error alert behind it can be read.
@available(iOS 17.0, *)
struct RipulTeamEditorSheet: View {
    let title: String
    @State var name: String
    @State var description: String
    let onSave: (_ name: String, _ description: String?) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var saving = false

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Team name", text: $name)
                        .textInputAutocapitalization(.words)
                        .uiKitIdentifier("TeamEditor.name")
                }
                Section {
                    TextField("What this team is for", text: $description, axis: .vertical)
                        .lineLimit(2...5)
                        .uiKitIdentifier("TeamEditor.description")
                } header: {
                    Text("Description")
                } footer: {
                    Text("Optional. Shown to people you invite.")
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if saving {
                        ProgressView()
                    } else {
                        Button("Save") {
                            Task {
                                saving = true
                                let trimmedDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)
                                if await onSave(trimmedName, trimmedDescription.isEmpty ? nil : trimmedDescription) {
                                    dismiss()
                                }
                                saving = false
                            }
                        }
                        .disabled(trimmedName.isEmpty)
                        .uiKitIdentifier("TeamEditor.save")
                    }
                }
            }
        }
        .interactiveDismissDisabled(saving)
    }
}

/// Invite by email — or, for a platform admin who has the Users screen to
/// look one up, add a Clerk user id directly.
@available(iOS 17.0, *)
struct RipulTeamInviteSheet: View {
    let allowUserId: Bool
    let onSubmit: (_ email: String?, _ userId: String?, _ role: RipulTeamRole) async -> Bool

    private enum Mode: Hashable { case email, userId }

    @Environment(\.dismiss) private var dismiss
    @State private var mode: Mode = .email
    @State private var email = ""
    @State private var userId = ""
    @State private var role: RipulTeamRole = .member
    @State private var sending = false

    private var canSubmit: Bool {
        switch mode {
        case .email: return email.contains("@") && !email.trimmingCharacters(in: .whitespaces).isEmpty
        case .userId: return !userId.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                if allowUserId {
                    Picker("Add by", selection: $mode) {
                        Text("Email").tag(Mode.email)
                        Text("User ID").tag(Mode.userId)
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                }
                Section {
                    if mode == .email {
                        TextField("name@example.com", text: $email)
                            .keyboardType(.emailAddress)
                            .textContentType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .uiKitIdentifier("TeamInvite.email")
                    } else {
                        TextField("user_…", text: $userId)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .uiKitIdentifier("TeamInvite.userId")
                    }
                } header: {
                    Text(mode == .email ? "Email address" : "Clerk user ID")
                } footer: {
                    Text(mode == .email
                         ? "They'll see the invitation in Ripul and can accept or decline. Nothing is shared until they accept."
                         : "Adds the account to the team immediately.")
                }
                Section("Role") {
                    Picker("Role", selection: $role) {
                        ForEach(RipulTeamRole.allCases, id: \.self) { role in
                            Text(role.label).tag(role)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
            }
            .navigationTitle(mode == .email ? "Invite" : "Add Member")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(sending)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if sending {
                        ProgressView()
                    } else {
                        Button(mode == .email ? "Send" : "Add") {
                            Task {
                                sending = true
                                let ok = await onSubmit(
                                    mode == .email ? email : nil,
                                    mode == .userId ? userId : nil,
                                    role
                                )
                                if ok { dismiss() }
                                sending = false
                            }
                        }
                        .disabled(!canSubmit)
                        .uiKitIdentifier("TeamInvite.submit")
                    }
                }
            }
        }
        .interactiveDismissDisabled(sending)
    }
}

// MARK: - Error alert

@available(iOS 17.0, *)
private struct RipulTeamsErrorAlert: ViewModifier {
    @Binding var message: String?

    func body(content: Content) -> some View {
        content.alert(
            "Couldn't complete that",
            isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(message ?? "")
        }
    }
}

@available(iOS 17.0, *)
extension View {
    /// Server refusals are shown verbatim — "Cannot remove the last owner of a
    /// team" is better wording than anything the client would invent.
    func ripulTeamsErrorAlert(_ message: Binding<String?>) -> some View {
        modifier(RipulTeamsErrorAlert(message: message))
    }
}
#endif
