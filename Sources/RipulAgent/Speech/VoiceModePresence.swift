import SwiftUI

/// Where the rest of the app finds a voice conversation that is under way.
///
/// The controller belongs to the chat view, so the compact panel that says
/// "listening" was drawn inside the chat and nowhere else. That was enough
/// while voice mode only ever talked to the agent in the chat on screen. A
/// command session is used to move around the app, and on the chat list the
/// microphone was live with nothing on screen to say so (Peter, 10 October
/// 2026). So the chat view announces its controller here, and a host that
/// installs `voiceModeFloatingPanel()` at its root draws the compact panel
/// over every screen instead.
@MainActor
public final class VoiceModePresence: ObservableObject {
    public static let shared = VoiceModePresence()

    /// The conversation under way, if there is one.
    @Published public private(set) var controller: VoiceModeController?
    var tokenProvider: (() -> String?)?

    /// Whether a host has installed the floating panel. While it has, the chat
    /// view leaves the compact panel to it, so there is one panel, not two.
    /// A host that has not keeps the panel where it always was, in the chat.
    public private(set) var floats = false

    private init() {}

    func began(_ controller: VoiceModeController, tokenProvider: (() -> String?)?) {
        self.tokenProvider = tokenProvider
        if self.controller !== controller { self.controller = controller }
    }

    func ended(_ controller: VoiceModeController) {
        guard self.controller === controller else { return }
        self.controller = nil
        tokenProvider = nil
    }

    fileprivate func installed() { floats = true }
}

/// Draws the compact voice panel at the bottom of whatever it is attached to,
/// for as long as a conversation is under way in compact form.
private struct VoiceModeFloatingPanel: ViewModifier {
    @ObservedObject private var presence = VoiceModePresence.shared

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if let controller = presence.controller {
                    FloatingCompactPanel(controller: controller, tokenProvider: presence.tokenProvider)
                }
            }
            .onAppear { presence.installed() }
    }
}

/// Observes the controller itself, which the presence only points at.
private struct FloatingCompactPanel: View {
    @ObservedObject var controller: VoiceModeController
    var tokenProvider: (() -> String?)?

    var body: some View {
        if controller.isActive, controller.presentation == .compact {
            VoiceModeCompactPanel(controller: controller, tokenProvider: tokenProvider)
                // Where it sat in the chat: clear of the composer.
                .padding(.bottom, 92)
                .transition(.opacity)
        }
    }
}

public extension View {
    /// Attach once, at the root of the app's window. The compact voice panel
    /// then floats over every screen, not only the chat it was started in.
    func voiceModeFloatingPanel() -> some View { modifier(VoiceModeFloatingPanel()) }
}
