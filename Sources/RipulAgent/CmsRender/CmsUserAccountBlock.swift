import SwiftUI

/// Native twin of `userAccount` (UserAccountBlock.tsx): the signed-in
/// person's avatar opening their account menu.
///
/// Semantics mirrored: initials from the name or email; the menu header shows
/// who is signed in, the email (`showEmail`) and the role (`showRole`); the
/// menu links are role-gated like nav items and a page the visitor can't open
/// is not offered; Sign out last.
///
/// Presentation: a circle avatar (`brand` = the portal gradient with white
/// initials, `light` = white with brand-coloured initials, otherwise the
/// system's tinted circle) opening a native `Menu`.
///
/// Degraded: the colour-mode switch (`showColorMode`) is the device's own
/// setting on iPhone and is not shown. Sign out appears when the host app
/// handles it (`CmsRuntime.onSignOut`).
struct CmsUserAccountBlockView: View {
    let block: CmsBlock
    @EnvironmentObject var runtime: CmsRuntime

    private var props: [String: CmsJSON] { block.props }
    /// `auth.user.email || membership.email`.
    private var email: String? { runtime.client.userEmail ?? runtime.membership?.email.flatMap { $0.isEmpty ? nil : $0 } }
    private var displayName: String { runtime.client.userName ?? email ?? "Account" }

    /// `initialsFrom(name, email)`: the first letter of up to two words.
    private var initials: String {
        let source = (runtime.client.userName ?? email ?? "").trimmingCharacters(in: .whitespaces)
        return source.split(whereSeparator: \.isWhitespace)
            .compactMap { $0.first.map(String.init) }
            .prefix(2).joined().uppercased()
    }

    private var menuLinks: [CmsNavItem] {
        let items = CmsNavItem.decodeList(props["menuItems"]).filter {
            !$0.label.trimmingCharacters(in: .whitespaces).isEmpty
                && $0.targetPageSlug.map { runtime.pageTitles[$0] != nil } == true
        }
        return CmsNavItem.visible(items, membership: runtime.membership, canDesign: runtime.canDesign)
    }

    var body: some View {
        Menu {
            Section {
                Text(displayName)
                if props.bool("showEmail") ?? true, let email, email != displayName {
                    Text(email)
                }
                if props.bool("showRole") ?? true, runtime.membership?.isMember == true,
                   let role = runtime.membership?.role {
                    Text(role.prefix(1).uppercased() + role.dropFirst())
                }
            }
            if !menuLinks.isEmpty {
                Section {
                    ForEach(menuLinks) { item in
                        Button {
                            if let slug = item.targetPageSlug { runtime.navigate(toPage: slug) }
                        } label: {
                            if let symbol = CmsNavIcon.symbol(for: item.icon) {
                                Label(item.label, systemImage: symbol)
                            } else {
                                Text(item.label)
                            }
                        }
                    }
                }
            }
            if let signOut = runtime.onSignOut {
                Button(role: .destructive, action: signOut) {
                    Label(props.string("signOutLabel").flatMap { $0.isEmpty ? nil : $0 } ?? "Sign out",
                          systemImage: "rectangle.portrait.and.arrow.right")
                }
            }
        } label: {
            HStack(spacing: 6) {
                avatar
                if props.string("display") == "avatarName" || !(props.string("label") ?? "").isEmpty {
                    Text(props.string("label").flatMap { $0.isEmpty ? nil : $0 } ?? displayName)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                }
            }
        }
        .accessibilityLabel(displayName)
        .cmsInspectorID("Cms.userAccount.avatar")
    }

    @ViewBuilder
    private var avatar: some View {
        let style = props.string("avatarStyle") ?? "auto"
        let mark = Group {
            if initials.isEmpty {
                Image(systemName: "person").font(.system(size: 14, weight: .semibold))
            } else {
                Text(initials).font(.system(size: 13, weight: .bold))
            }
        }
        .frame(width: 34, height: 34)
        switch style {
        case "light":
            mark.foregroundColor(runtime.theme.primary)
                .background(Circle().fill(Color.white)) // theme-exempt: the web's light avatar is white on a brand bar
        case "brand":
            mark.foregroundColor(runtime.theme.primaryContrast)
                .background(Circle().fill(runtime.theme.gradient))
        default:
            mark.foregroundColor(runtime.theme.primary)
                .background(Circle().fill(runtime.theme.primarySoft))
        }
    }
}
