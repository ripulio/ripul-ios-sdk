import SwiftUI

// Glass container components used by the session list. The app has its own
// copies of these (Shared/GlassComponents.swift) which stay until the M7 rewire;
// these are the SDK-owned versions the extracted session list compiles against.
// Names are chosen to not collide with the SDK's existing glass modifiers
// (GlassButton.swift / GlassMastheadView.swift).

// MARK: - Glass Section Panel

/// Collapsible container with a header row (chevron, title, optional
/// subtitle, optional trailing actions) and a content slot.
/// On iOS 26+ renders with `.glassEffect`; on older versions uses
/// `.ultraThinMaterial` with a rounded rect. Works on all iOS versions
/// so call sites don't need `if #available` branching.
struct GlassSectionPanel<Content: View, Trailing: View, Center: View>: View {
    let title: String
    var subtitle: String? = nil
    @Binding var isExpanded: Bool
    let center: Center
    let trailing: Trailing
    let content: Content

    init(
        title: String,
        subtitle: String? = nil,
        isExpanded: Binding<Bool>,
        @ViewBuilder center: () -> Center = { EmptyView() },
        @ViewBuilder trailing: () -> Trailing = { EmptyView() },
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self._isExpanded = isExpanded
        self.center = center()
        self.trailing = trailing()
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .animation(.easeInOut(duration: 0.2), value: isExpanded)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                if let subtitle, !subtitle.isEmpty, !isExpanded {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 8)
                center
                Spacer(minLength: 8)
                trailing
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .onTapGesture {
                #if os(iOS)
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                #endif
                withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
            }

            if isExpanded {
                VStack(spacing: 0) {
                    content
                }
                .padding(.bottom, 8)
            }
        }
        .modifier(GlassPanelBackground())
    }
}

// MARK: - Glass Search Field

/// Search text field with magnifying glass icon, clear button, and
/// material background.
struct GlassSearchField: View {
    let placeholder: String
    @Binding var text: String
    @FocusState private var isFocused: Bool

    init(_ placeholder: String = "Search", text: Binding<String>) {
        self.placeholder = placeholder
        self._text = text
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.subheadline)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .focused($isFocused)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .uiKitIdentifier("GlassSearchField.clearButton")
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: .rect(cornerRadius: 10))
    }
}

// MARK: - Glass Select Button

/// Small pill button for toggling selection mode.
struct GlassSelectButton: View {
    let isSelecting: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: isSelecting ? "xmark" : "checkmark.circle")
                    .font(.caption2.weight(.semibold))
                Text(isSelecting ? "Cancel" : "Select")
                    .font(.caption.weight(.medium))
            }
            .textCase(nil)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .modifier(GlassCapsuleBackground())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Background modifiers

struct GlassPanelBackground: ViewModifier {
    func body(content: Content) -> some View {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            content.glassEffect(.clear, in: .rect(cornerRadius: 16))
        } else {
            content
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
        #else
        if #available(macOS 26.0, *) {
            content
                .background(.clear)
                .glassEffect(.clear, in: .rect(cornerRadius: 16))
        } else {
            content
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
        #endif
    }
}

struct GlassCapsuleBackground: ViewModifier {
    func body(content: Content) -> some View {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            content.glassEffect(.clear.interactive(), in: .capsule)
        } else {
            content
                .background(.ultraThinMaterial, in: Capsule())
        }
        #else
        if #available(macOS 26.0, *) {
            content
                .background(.clear)
                .glassEffect(.clear.interactive(), in: .capsule)
        } else {
            content
                .background(.ultraThinMaterial, in: Capsule())
        }
        #endif
    }
}
