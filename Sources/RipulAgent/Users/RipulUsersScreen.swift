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

    private let client: RipulUsersClient

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
                            RipulUserDetailView(user: user)
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
// spelled out. The user id is copyable because it is the join key to
// `site_key_owners`, which is where a person's *portal* role lives.
// ---------------------------------------------------------------------------

@available(iOS 16.0, *)
struct RipulUserDetailView: View {
    let user: RipulPlatformUser

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

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

            // Explicit header:/footer: closures — there is no
            // Section(_ titleKey:, content:, footer:) overload, so the string
            // form cannot carry a footer.
            Section {
                field("Resolved role", user.resolvedRoleId)
                field("Clerk role", user.role ?? "—")
                field("Tier", user.tier.capitalized)
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
