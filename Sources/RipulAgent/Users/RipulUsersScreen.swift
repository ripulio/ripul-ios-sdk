#if os(iOS)
import SwiftUI

// ---------------------------------------------------------------------------
// Native USERS screen — the directory of Ripul accounts, read from Clerk via
// `GET /admin/users`.
//
// Sectioned by the role the API would actually resolve for each person, not by
// raw metadata: admins first (being an admin outranks any tier), then the tier
// bands. That ordering is the whole point of the screen — it answers "what can
// this person do" at a glance, which previously meant opening the Clerk
// dashboard on a desktop.
//
// Read-only: see the note in RipulUsersClient.
// ---------------------------------------------------------------------------

@available(iOS 16.0, *)
@MainActor
final class RipulUsersModel: ObservableObject {
    @Published private(set) var users: [RipulPlatformUser] = []
    @Published var loading = false
    @Published var errorMessage: String?

    let client: RipulUsersClient

    init(client: RipulUsersClient) {
        self.client = client
    }

    func load() async {
        loading = true
        errorMessage = nil
        do {
            users = try await client.list()
        } catch {
            errorMessage = error.localizedDescription
        }
        loading = false
    }

    var adminCount: Int { users.filter(\.isAdmin).count }
}

@available(iOS 16.0, *)
public struct RipulUsersScreen: View {
    @StateObject private var model: RipulUsersModel
    @State private var search = ""

    public init(client: RipulUsersClient) {
        _model = StateObject(wrappedValue: RipulUsersModel(client: client))
    }

    private struct UserGroup: Identifiable {
        let name: String
        let users: [RipulPlatformUser]
        var id: String { name }
    }

    /// Admins first, then descending tier — the reading order a person asking
    /// "who has power here" expects.
    private static let groupOrder = ["Admins", "Enterprise", "Pro", "Free"]

    private var filtered: [RipulPlatformUser] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return model.users }
        return model.users.filter {
            $0.displayName.lowercased().contains(q)
                || $0.email.lowercased().contains(q)
                || $0.id.lowercased().contains(q)
        }
    }

    private var groups: [UserGroup] {
        Dictionary(grouping: filtered, by: \.group)
            .map { name, members in
                UserGroup(name: name, users: members.sorted {
                    $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
                })
            }
            .sorted {
                let a = Self.groupOrder.firstIndex(of: $0.name) ?? Self.groupOrder.count
                let b = Self.groupOrder.firstIndex(of: $1.name) ?? Self.groupOrder.count
                return (a, $0.name) < (b, $1.name)
            }
    }

    public var body: some View {
        List {
            ForEach(groups) { group in
                Section("\(group.name) (\(group.users.count))") {
                    ForEach(group.users) { user in
                        NavigationLink {
                            RipulUserDetailView(user: user, client: model.client) {
                                Task { await model.load() }
                            }
                        } label: {
                            row(user)
                        }
                        .uiKitIdentifier("Users.row")
                    }
                }
            }
            if !model.users.isEmpty {
                Section {
                    Text("\(model.users.count) accounts · \(model.adminCount) admin\(model.adminCount == 1 ? "" : "s")")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .listRowBackground(Color.clear)
                }
            }
        }
        .searchable(text: $search, prompt: "Name, email or user id")
        .overlay { emptyState }
        .navigationTitle("Users")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    Task { await model.load() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .uiKitIdentifier("Users.refresh")
            }
        }
        .refreshable { await model.load() }
        .task { await model.load() }
    }

    @ViewBuilder
    private var emptyState: some View {
        if model.loading && model.users.isEmpty {
            ProgressView("Loading users…")
        } else if !model.loading && model.users.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "person.2")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text(model.errorMessage ?? "No Ripul accounts found")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Retry") { Task { await model.load() } }
                    .buttonStyle(.bordered)
            }
            .padding()
        }
    }

    @ViewBuilder
    private func row(_ user: RipulPlatformUser) -> some View {
        HStack(spacing: 12) {
            RipulUserAvatar(user: user)
            VStack(alignment: .leading, spacing: 1) {
                Text(user.displayName)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text(user.email)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if user.isAdmin {
                Image(systemName: "checkmark.shield.fill")
                    .font(.caption)
                    .foregroundStyle(.tint)
                    .accessibilityLabel("Admin")
            }
        }
        .padding(.vertical, 2)
    }
}

@available(iOS 16.0, *)
struct RipulUserAvatar: View {
    let user: RipulPlatformUser

    var body: some View {
        ZStack {
            Circle().fill(.tint.opacity(0.15))
            if let imageURL = user.imageURL, let url = URL(string: imageURL) {
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
    }

    private var initials: some View {
        Text(user.initials)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.tint)
    }
}

// ---------------------------------------------------------------------------
// Detail — every field the endpoint carries, with the derived platform role
// spelled out, and the one thing an admin can change: the plan. The user id is
// copyable because it is the join key to `site_key_owners`, which is where a
// person's *portal* role lives.
// ---------------------------------------------------------------------------

@available(iOS 16.0, *)
struct RipulUserDetailView: View {
    @State private var user: RipulPlatformUser
    private let client: RipulUsersClient
    private let onChange: () -> Void

    @State private var pendingTier: String?
    @State private var pendingRole: String?
    @State private var saving = false
    @State private var errorMessage: String?

    init(user: RipulPlatformUser, client: RipulUsersClient, onChange: @escaping () -> Void) {
        _user = State(initialValue: user)
        self.client = client
        self.onChange = onChange
    }

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    private static let tiers: [(id: String, label: String)] = [
        ("free", "Free"), ("pro", "Pro"), ("enterprise", "Enterprise"),
    ]

    private static func tierLabel(_ id: String) -> String {
        tiers.first { $0.id == id }?.label ?? id.capitalized
    }

    var body: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    RipulUserAvatar(user: user)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(user.displayName).font(.headline)
                        Text(user.email).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            planSection

            // Explicit header:/footer: closures — there is no
            // Section(_ titleKey:, content:, footer:) overload, so the string
            // form cannot carry a footer.
            Section {
                field("Resolved role", user.resolvedRoleId)
                field("Clerk role", user.role ?? "—")
                field("Tier", Self.tierLabel(user.tier))
            } header: {
                Text("Platform role")
            } footer: {
                Text(user.isAdmin
                     ? "Admin is granted by Clerk public_metadata.role and outranks the tier."
                     : "No admin claim, so the API resolves this account from its subscription tier.")
            }

            Section("Usage") {
                field("Quota used", user.quotaLimit > 0
                      ? "\(user.quotaUsed) / \(user.quotaLimit) (\(user.percentUsed)%)"
                      : "\(user.quotaUsed)")
                field("Last active", user.lastActive.map { Self.stamp.string(from: $0) } ?? "Never")
                field("Created", user.createdAt.map { Self.stamp.string(from: $0) } ?? "—")
            }

            Section("Identity") {
                if let username = user.username { field("Username", username) }
                copyableField("User ID", user.id)
                copyableField("Email", user.email)
            }
        }
        .navigationTitle(user.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .disabled(saving)
        .overlay {
            if saving { ProgressView().controlSize(.large) }
        }
        .confirmationDialog(
            "Set \(user.displayName) to \(Self.tierLabel(pendingTier ?? ""))?",
            isPresented: Binding(get: { pendingTier != nil }, set: { if !$0 { pendingTier = nil } }),
            titleVisibility: .visible,
            presenting: pendingTier
        ) { tier in
            Button("Set to \(Self.tierLabel(tier))") {
                Task { await apply(tier: tier, role: nil) }
            }
        } message: { tier in
            Text(tier == "free"
                 ? "Ends any manual plan. Billing events apply normally again."
                 : "Marked as set by an admin: their own Stripe or Apple events can raise it but won't lower it. No charge is made.")
        }
        .confirmationDialog(
            pendingRole == "admin" ? "Make \(user.displayName) a platform admin?" : "Remove admin from \(user.displayName)?",
            isPresented: Binding(get: { pendingRole != nil }, set: { if !$0 { pendingRole = nil } }),
            titleVisibility: .visible,
            presenting: pendingRole
        ) { role in
            Button(role == "admin" ? "Make Admin" : "Remove Admin", role: role == "admin" ? nil : .destructive) {
                Task { await apply(tier: nil, role: role) }
            }
        } message: { role in
            Text(role == "admin"
                 ? "Admins bypass every team check and reach site keys, the model catalog, accounts and billing."
                 : "They keep their subscription tier and lose every admin surface.")
        }
        .alert(
            "Couldn't change the plan",
            isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: Plan controls

    private var planSection: some View {
        Section {
            Picker("Tier", selection: Binding(
                get: { user.tier },
                set: { next in if next != user.tier { pendingTier = next } }
            )) {
                ForEach(Self.tiers, id: \.id) { tier in
                    Text(tier.label).tag(tier.id)
                }
            }
            .pickerStyle(.segmented)
            .uiKitIdentifier("UserDetail.plan.tier")

            Toggle("Platform admin", isOn: Binding(
                get: { user.isAdmin },
                set: { on in if on != user.isAdmin { pendingRole = on ? "admin" : "user" } }
            ))
            .uiKitIdentifier("UserDetail.plan.admin")
        } header: {
            Text("Plan")
        } footer: {
            Text(planFootnote)
        }
    }

    private var planFootnote: String {
        switch user.planSource {
        case "manual":
            return "Set by an admin. Billing events can raise this tier but won't lower it."
        case "billing":
            return "Owned by Stripe or Apple. Changing it here marks it as set by an admin."
        default:
            return "Changes apply on the person's next token refresh, within a minute."
        }
    }

    private func apply(tier: String?, role: String?) async {
        saving = true
        defer { saving = false }
        do {
            let plan = try await client.updatePlan(userId: user.id, tier: tier, role: role)
            user = user.withPlan(plan)
            onChange()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @ViewBuilder
    private func field(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.subheadline).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .font(.subheadline)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func copyableField(_ label: String, _ value: String) -> some View {
        Button {
            UIPasteboard.general.string = value
        } label: {
            HStack(alignment: .firstTextBaseline) {
                Text(label).font(.subheadline).foregroundStyle(.secondary)
                Spacer(minLength: 12)
                Text(value)
                    .font(.subheadline)
                    .multilineTextAlignment(.trailing)
                    .foregroundStyle(.primary)
                Image(systemName: "doc.on.doc")
                    .font(.caption2)
                    .foregroundStyle(.tint)
            }
        }
        .buttonStyle(.plain)
    }
}
#endif
