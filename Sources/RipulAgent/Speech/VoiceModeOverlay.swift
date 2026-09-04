import SwiftUI
import ThinkingOrbs
#if os(iOS)
import AVKit

/// The system audio-route picker — speaker, phone, AirPods, or the HomePod in
/// the kitchen. Deliberately the platform control rather than a hand-rolled
/// list: it enumerates AirPlay targets we have no way to discover ourselves,
/// and it is the affordance people already recognise from every other app.
private struct AudioRoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.tintColor = .white
        picker.activeTintColor = .white
        // Audio-only session; ranking video targets first would offer the
        // wrong devices.
        picker.prioritizesVideoDevices = false
        return picker
    }

    func updateUIView(_ picker: AVRoutePickerView, context: Context) {}
}
#endif

/// Maps a voice-loop phase to its thinking-orb animation. `nil` for phases
/// that keep a non-orb presentation (notice = warning icon, inactive = none).
///
/// `micLive` splits the listening phase in two: the mic takes a beat to come
/// up (permissions, audio session, engine start, and on ElevenLabs a token
/// mint plus a socket), and anything said before it does is lost. That
/// interval gets the `.connecting` orb, not the listening one.
///
/// `playbackLive` splits the speaking phase the same way: the reply is
/// synthesized over the network before a single sample plays, so the orb
/// shouldn't perform speech over silence.
private func voiceOrbState(
    for phase: VoiceModeController.Phase,
    micLive: Bool,
    playbackLive: Bool
) -> OrbState? {
    switch phase {
    case .listening: return micLive ? .weaving : .connecting
    case .sending: return .connecting
    case .thinking: return .working
    case .speaking: return playbackLive ? .composing : .connecting
    case .paused: return .breathing
    case .notice, .inactive: return nil
    }
}

/// Full-screen hands-free voice UI: a thinking orb keyed to the loop phase,
/// live transcript, and an exit button. Tap anywhere to interrupt playback
/// (or force-send while listening); the X ends the session. The keyboard
/// button opens a typed-command field — text sent there is treated exactly
/// as if it had been spoken (the reply is spoken back).
struct VoiceModeOverlay: View {
    @ObservedObject var controller: VoiceModeController
    /// Supplies the active session + live session-list store for the
    /// progress row. Optional so the overlay renders without a bridge
    /// (previews, hosts that don't pass one).
    var bridge: AgentBridge? = nil
    @State private var pulsing = false
    /// Typed-command entry: whether the field is up, its text, and whether
    /// we auto-paused the mic when the keyboard opened (resumed on dismiss).
    @State private var typingActive = false
    @State private var typedCommand = ""
    @State private var pausedForTyping = false
    @FocusState private var typedFieldFocused: Bool
    #if os(iOS)
    @StateObject private var keyboard = KeyboardObserver()
    #endif

    private var orbColor: Color {
        switch controller.phase {
        case .listening: return controller.captureLive ? .blue : .gray
        case .sending: return .gray
        case .thinking: return .orange
        // Grey, like every other not-yet-there state, until audio starts.
        case .speaking: return controller.playbackLive ? .green : .gray
        case .paused: return .yellow
        case .notice: return .red
        case .inactive: return .clear
        }
    }

    private var statusText: String {
        switch controller.phase {
        // Never claim to be listening before the mic is actually capturing —
        // speech in that gap is dropped, and the old copy invited it.
        case .listening:
            return controller.captureLive ? "Listening — pause to send" : "Starting mic…"
        case .sending: return "Sending…"
        case .thinking: return "Working… \(formattedElapsed)"
        // Likewise never claim to be speaking during the synthesis round-trip —
        // "tap to skip" over silence reads as a hang.
        case .speaking:
            return controller.playbackLive ? "Speaking — tap to skip" : "Preparing speech…"
        case .paused: return "Paused — tap to resume"
        case .notice(let message): return message
        case .inactive: return ""
        }
    }

    private var formattedElapsed: String {
        let minutes = controller.thinkingSeconds / 60
        let seconds = controller.thinkingSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    private var pulseDuration: Double {
        switch controller.phase {
        case .listening: return 1.1
        case .thinking: return 2.4
        case .speaking: return 0.7
        default: return 1.6
        }
    }

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(Color.black.opacity(0.45))
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {
                    // While the typed-command field is up, a tap outside it
                    // dismisses the keyboard rather than driving the loop.
                    if typingActive { dismissTypedEntry() } else { controller.handleTap() }
                }

            VStack(spacing: 28) {
                Spacer()

                ZStack {
                    if let orb = voiceOrbState(
                        for: controller.phase,
                        micLive: controller.captureLive,
                        playbackLive: controller.playbackLive
                    ) {
                        // White ink on the dark scrim, tinted to the phase
                        // color so the existing color language carries over.
                        ThinkingOrbView(state: orb, theme: .dark, renderSize: 180)
                            .colorMultiply(orbColor)
                    } else {
                        // Notice keeps the original glowing warning presentation.
                        Circle()
                            .fill(orbColor.opacity(0.25))
                            .frame(width: 190, height: 190)
                            .scaleEffect(pulsing ? 1.15 : 0.9)
                        Circle()
                            .fill(orbColor.opacity(0.85))
                            .frame(width: 120, height: 120)
                            .scaleEffect(pulsing ? 1.05 : 0.95)
                            .shadow(color: orbColor.opacity(0.6), radius: 30)
                        Image(systemName: orbIcon)
                            .font(.system(size: 40, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: 190, height: 190)
                .animation(
                    .easeInOut(duration: pulseDuration).repeatForever(autoreverses: true),
                    value: pulsing
                )
                .allowsHitTesting(false)
                .uiKitIdentifier("VoiceModeOverlay.orb")

                Text(statusText)
                    .font(.headline)
                    .foregroundStyle(.white.opacity(0.9))
                    .uiKitIdentifier("VoiceModeOverlay.status")

                if !controller.committedText.isEmpty || !controller.partialText.isEmpty {
                    (Text(controller.committedText)
                        + Text(controller.committedText.isEmpty ? "" : " ")
                        + Text(controller.partialText).foregroundStyle(.white.opacity(0.55)))
                        .font(.body)
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .lineLimit(5)
                        .padding(.horizontal, 32)
                        .uiKitIdentifier("VoiceModeOverlay.transcript")
                }

                Spacer()

                sessionProgressRow

                if typingActive {
                    typedEntryRow
                        .padding(.horizontal, 24)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                HStack(spacing: 16) {
                    if !typingActive {
                        // Send now — the override for the silence window.
                        // That window is deliberately forgiving of
                        // thinking-out-loud pauses, which is exactly what
                        // makes it feel slow once you know you've finished.
                        // Filled, and first in the row, because it is the one
                        // primary action among four pieces of chrome — and
                        // because it keeps the widest possible distance from
                        // the X that ends the conversation.
                        Button {
                            controller.sendNow()
                        } label: {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 20, weight: .bold))
                                .foregroundStyle(controller.canSendNow ? Color.black : Color.white.opacity(0.45))
                                .frame(width: 56, height: 56)
                                .background(
                                    controller.canSendNow ? Color.white : Color.white.opacity(0.15),
                                    in: Circle()
                                )
                                .contentShape(Circle())
                        }
                        // Kept in place rather than hidden when there's
                        // nothing to send: a control that appears and
                        // disappears mid-utterance would shuffle the whole
                        // row under the user's thumb.
                        .disabled(!controller.canSendNow)
                        .animation(.easeInOut(duration: 0.15), value: controller.canSendNow)
                        .uiKitIdentifier("VoiceModeOverlay.send")
                    }

                    #if os(iOS)
                    if !typingActive {
                        AudioRoutePicker()
                            .frame(width: 56, height: 56)
                            .background(.white.opacity(0.15), in: Circle())
                            .uiKitIdentifier("VoiceModeOverlay.routePicker")
                    }
                    #endif

                    if !typingActive {
                        // Minimise — NOT the same action as the X beside it.
                        // This drops to the docked pill so the chat is visible
                        // and usable while the conversation keeps running; the
                        // X ends the conversation.
                        Button {
                            withAnimation(.easeInOut(duration: 0.25)) {
                                controller.presentation = .compact
                            }
                        } label: {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 56, height: 56)
                                .background(.white.opacity(0.15), in: Circle())
                                .contentShape(Circle())
                        }
                        .uiKitIdentifier("VoiceModeOverlay.minimise")

                        Button {
                            showTypedEntry()
                        } label: {
                            Image(systemName: "keyboard")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 56, height: 56)
                                .background(.white.opacity(0.15), in: Circle())
                                .contentShape(Circle())
                        }
                        .uiKitIdentifier("VoiceModeOverlay.typeCommand")
                    }

                    Button {
                        controller.stop()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 56, height: 56)
                            .background(.white.opacity(0.15), in: Circle())
                            .contentShape(Circle())
                    }
                    .uiKitIdentifier("VoiceModeOverlay.exit")
                }
                .padding(.bottom, bottomPadding)
            }
        }
        .onAppear { pulsing = true }
        .onChange(of: typedFieldFocused) { focused in
            // Keyboard dismissed (or focus stolen) without a submit: close
            // the field and resume the mic if we paused it.
            if !focused, typingActive { dismissTypedEntry() }
        }
    }

    /// The same live session row the sessions list shows for a running
    /// session (minimised-state progress: current tool lozenge, plan N/M,
    /// phase indicator), so the thinking phase shows real activity instead
    /// of just elapsed seconds. Display-only: taps fall through to the
    /// overlay's whole-screen tap.
    @ViewBuilder
    private var sessionProgressRow: some View {
        if #available(iOS 26.0, macOS 26.0, *),
           let bridge, let chat = bridge.activeSession {
            UnifiedSessionRow(
                sessionStore: bridge.sessionList,
                session: UnifiedSession(
                    id: chat.id,
                    title: chat.displayName,
                    lastUsed: chat.createdAt,
                    gitBranch: nil,
                    messageCount: nil,
                    projectName: nil,
                    provider: chat.provider,
                    providerLabel: chat.providerLabel,
                    machineName: chat.remoteMachineName,
                    ripulSession: chat
                )
            )
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            .environment(\.colorScheme, .dark)
            .allowsHitTesting(false)
            .padding(.horizontal, 24)
            .uiKitIdentifier("VoiceModeOverlay.sessionRow")
        }
    }

    // MARK: - Typed command entry

    private var canSubmitTyped: Bool {
        !typedCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Bottom clearance for the control row. While the typed-command field
    /// is up it must clear the software keyboard (this overlay's VStack
    /// respects the bottom safe area, so the safe-area-adjusted height is
    /// the right inset).
    private var bottomPadding: CGFloat {
        guard typingActive else { return 36 }
        #if os(iOS)
        return max(keyboard.height + 10, 20)
        #else
        return 36
        #endif
    }

    /// Opens the typed-command field. A hot mic is held while typing — the
    /// silence window could otherwise auto-send ambient noise over a
    /// half-typed command. Pausing keeps any transcript; dismissing the
    /// keyboard resumes listening.
    private func showTypedEntry() {
        withAnimation { typingActive = true }
        switch controller.phase {
        case .listening, .notice:
            controller.pauseConversation()
            pausedForTyping = true
        default:
            break
        }
        typedFieldFocused = true
    }

    private func submitTypedCommand() {
        let text = typedCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        typedCommand = ""
        // The send path itself un-pauses the loop — don't resume on top.
        pausedForTyping = false
        typedFieldFocused = false
        withAnimation { typingActive = false }
        controller.submitTypedUtterance(text)
    }

    private func dismissTypedEntry() {
        typedCommand = ""
        typedFieldFocused = false
        withAnimation { typingActive = false }
        if pausedForTyping {
            pausedForTyping = false
            controller.resumeConversation()
        }
    }

    /// Single-line field (Return sends, like the chat composer) with a send
    /// button, styled for the dark scrim.
    private var typedEntryRow: some View {
        HStack(spacing: 8) {
            TextField("Type a voice command…", text: $typedCommand)
                .focused($typedFieldFocused)
                .onSubmit { submitTypedCommand() }
                .submitLabel(.send)
                .font(.body)
                .foregroundStyle(.white)
                .tint(.white)
                .padding(.leading, 14)
                .padding(.vertical, 10)
                .uiKitIdentifier("VoiceModeOverlay.typedField")
            Button {
                submitTypedCommand()
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(canSubmitTyped ? Color.black : Color.white.opacity(0.45))
                    .frame(width: 32, height: 32)
                    .background(canSubmitTyped ? Color.white : Color.white.opacity(0.2), in: Circle())
                    .contentShape(Circle())
            }
            .disabled(!canSubmitTyped)
            .padding(.trailing, 6)
            .uiKitIdentifier("VoiceModeOverlay.typedSend")
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(.white.opacity(0.25), lineWidth: 1)
        )
        .uiKitIdentifier("VoiceModeOverlay.typedEntry")
    }

    private var orbIcon: String {
        switch controller.phase {
        case .listening: return "waveform"
        case .sending: return "arrow.up"
        case .thinking: return "brain"
        case .speaking: return "speaker.wave.2.fill"
        case .paused: return "pause.fill"
        case .notice: return "exclamationmark.triangle"
        case .inactive: return ""
        }
    }
}

/// Compact voice-mode presentation — a docked pill above the composer that
/// keeps the chat visible and interactive while the hands-free loop runs.
/// Same controller, same tap semantics (skip playback / force-send).
struct VoiceModeCompactPanel: View {
    @ObservedObject var controller: VoiceModeController
    @State private var pulsing = false

    private var accentColor: Color {
        switch controller.phase {
        case .listening: return controller.captureLive ? .blue : .gray
        case .sending: return .gray
        case .thinking: return .orange
        case .speaking: return controller.playbackLive ? .green : .gray
        case .paused: return .yellow
        case .notice: return .red
        case .inactive: return .clear
        }
    }

    private var statusText: String {
        switch controller.phase {
        case .listening: return controller.captureLive ? "Listening" : "Starting mic…"
        case .sending: return "Sending…"
        case .thinking:
            let minutes = controller.thinkingSeconds / 60
            let seconds = controller.thinkingSeconds % 60
            return String(format: "Working %d:%02d", minutes, seconds)
        case .speaking:
            return controller.playbackLive ? "Speaking — tap to skip" : "Preparing speech…"
        case .paused: return "Paused — tap to resume"
        case .notice(let message): return message
        case .inactive: return ""
        }
    }

    private var transcriptLine: String {
        let joined = controller.committedText.isEmpty
            ? controller.partialText
            : controller.committedText + " " + controller.partialText
        return joined.trimmingCharacters(in: .whitespaces)
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                if let orb = voiceOrbState(
                    for: controller.phase,
                    micLive: controller.captureLive,
                    playbackLive: controller.playbackLive
                ) {
                    // Forced-dark ink so colorMultiply yields accent-colored
                    // dots on the material regardless of system appearance.
                    ThinkingOrbView(state: orb, size: .inline, theme: .dark, renderSize: 30)
                        .colorMultiply(accentColor)
                } else {
                    Circle()
                        .fill(accentColor.opacity(0.85))
                        .frame(width: 30, height: 30)
                        .scaleEffect(pulsing ? 1.12 : 0.9)
                        .shadow(color: accentColor.opacity(0.6), radius: 8)
                        .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true), value: pulsing)
                }
            }
            .frame(width: 30, height: 30)
            .allowsHitTesting(false)
            .uiKitIdentifier("VoiceModeCompactPanel.orb")

            VStack(alignment: .leading, spacing: 2) {
                Text(statusText)
                    .font(.footnote.weight(.semibold))
                    .lineLimit(1)
                    .uiKitIdentifier("VoiceModeCompactPanel.status")
                if !transcriptLine.isEmpty {
                    Text(transcriptLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .uiKitIdentifier("VoiceModeCompactPanel.transcript")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Back to the immersive view. Its counterpart is the overlay's
            // chevron-down; the X below still ends the conversation.
            Button {
                withAnimation(.easeInOut(duration: 0.25)) {
                    controller.presentation = .fullscreen
                }
            } label: {
                Image(systemName: "chevron.up")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .uiKitIdentifier("VoiceModeCompactPanel.expand")

            Button {
                controller.stop()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .uiKitIdentifier("VoiceModeCompactPanel.exit")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(accentColor.opacity(0.4), lineWidth: 1))
        .contentShape(Capsule())
        .onTapGesture { controller.handleTap() }
        .padding(.horizontal, 16)
        .onAppear { pulsing = true }
        .uiKitIdentifier("VoiceModeCompactPanel.panel")
    }
}
