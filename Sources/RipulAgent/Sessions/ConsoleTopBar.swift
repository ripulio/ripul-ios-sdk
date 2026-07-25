import SwiftUI

// MARK: - Background

/// Frosted glass backdrop behind the console unified top bar.
/// Fades at the bottom so content scrolling underneath reads cleanly.
/// Matches AgentScreen.safeAreaGlass / safeAreaMask in the native app.
@available(iOS 26.0, macOS 26.0, *)
struct ConsoleTopBarBackground: View {
    var body: some View {
        VStack(spacing: 0) {
            #if os(iOS)
            if #available(iOS 26.0, *) {
                Rectangle()
                    .fill(.clear)
                    .frame(height: 130)
                    .glassEffect(.clear, in: .rect)
                    .mask(topBarFadeMask)
            } else {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .opacity(0.6)
                    .frame(height: 130)
                    .mask(topBarFadeMask)
            }
            #endif
            Spacer()
        }
        .ignoresSafeArea(edges: .top)
        .allowsHitTesting(false)
    }

    private var topBarFadeMask: some View {
        VStack(spacing: 0) {
            SwiftUI.Color.black.frame(height: 98)
            LinearGradient(
                colors: [.black, .clear],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 32)
        }
    }
}

// MARK: - Unified top bar

/// Unified glass top bar for `RipulAgentConsole`. Mirrors AgentScreen's
/// `agentTopBarContent` — same uiKitIdentifiers, same button positions,
/// same animations so the experience is identical to the standalone app.
///
/// - `showingChat`: false = session-list state, true = chat state
/// - `session`: active ChatSession (nil when list is showing or no session focused)
/// - `onBack`: called when the leading chevron is tapped (chat state only)
/// - `menu`: context-sensitive trailing menu items
@available(iOS 26.0, macOS 26.0, *)
struct ConsoleTopBarContent<TrailingMenu: View>: View {
    @ObservedObject var bridge: AgentBridge
    let showingChat: Bool
    let session: ChatSession?
    let onBack: () -> Void
    var ns: Namespace.ID
    @ViewBuilder let menu: () -> TrailingMenu

    private var isFileViewer: Bool { bridge.fileViewerTitle != nil }
    private var showScrollUp: Bool { showingChat && !isFileViewer }

    // Horizontal padding on the title lozenge so it never clips under buttons.
    // Chat: leading(44+8) + trailing(44+8+44) = 52 + 96 → pad 108 symmetrically.
    // List / file viewer: just trailing menu → pad 56.
    private var lozengePad: CGFloat { showingChat && !isFileViewer ? 108 : 56 }

    var body: some View {
        ZStack {
            // ── Center layer: title lozenge ──
            titleLozenge
                .padding(.horizontal, lozengePad)

            // ── Edge layer: leading (optional) + scroll-up (optional) + menu ──
            HStack(spacing: 8) {
                if showingChat || isFileViewer {
                    Button(action: onBack) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.primary)
                            .frame(width: 44, height: 44)
                            .modifier(GlassCircleModifier(glassStyle: "regular"))
                            .modifier(GlassEffectIDModifier(id: "leading", namespace: ns))
                    }
                    .buttonStyle(.plain)
                    .uiKitIdentifier("AgentScreen.topBar.leadingButton")
                }

                Spacer()

                if showScrollUp {
                    Button {
                        bridge.scrollToUserMessage(direction: "up")
                    } label: {
                        Image(systemName: "chevron.up")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.primary)
                            .frame(width: 44, height: 44)
                            .modifier(GlassCircleModifier(glassStyle: "regular"))
                    }
                    .buttonStyle(.plain)
                    .transition(.scale.combined(with: .opacity))
                    .uiKitIdentifier("AgentScreen.topBar.scrollUpButton")
                }

                Menu {
                    menu()
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 44, height: 44)
                        .modifier(GlassCircleModifier(glassStyle: "regular"))
                        .modifier(GlassEffectIDModifier(id: "trailing", namespace: ns))
                }
                .uiKitIdentifier("AgentScreen.topBar.trailingMenu")
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
        // Mirror AgentScreen's animation: brake into chat, spring back to list.
        .animation(
            showingChat
                ? .timingCurve(0.22, 1.0, 0.36, 1.0, duration: 0.625)
                : .spring(response: 0.45, dampingFraction: 0.86),
            value: showingChat
        )
    }

    // MARK: Title lozenge

    @ViewBuilder
    private var titleLozenge: some View {
        let title: String = {
            if let fileTitle = bridge.fileViewerTitle { return fileTitle }
            if showingChat { return session?.displayName ?? "New Chat" }
            return "Agents"
        }()
        let subtitle: String? = {
            if bridge.fileViewerTitle != nil { return "Viewing File" }
            return showingChat ? session?.remoteMachineName : nil
        }()

        VStack(spacing: 1) {
            Text(title)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(.primary)
                .lineLimit(1)
                .contentTransition(.interpolate)
            if let sub = subtitle {
                Text(sub)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .contentTransition(.interpolate)
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 44)
        .modifier(GlassPillModifier())
        .modifier(GlassEffectIDModifier(id: "title", namespace: ns))
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 1.0).onEnded { _ in
                NotificationCenter.default.post(name: .ripulShowDevTools, object: nil)
            }
        )
        .onTapGesture(count: 2) {
            bridge.toggleElementDebugger()
        }
        .uiKitIdentifier("AgentScreen.topBar.titleLozenge")
    }
}
