import SwiftUI

/// Speech is conversational content. Decode it once with the message, keeping
/// the original tool call for diagnostics rather than burying the words in it.
struct NativeChatSpeech: Equatable {
    enum Delivery: Equatable {
        case pending, sent, notSpoken, unavailable, unknown
    }

    let text: String
    let delivery: Delivery
    let detail: String

    var label: String? {
        switch delivery {
        case .notSpoken: return "Audio not played"
        case .unavailable: return "Audio unavailable"
        default: return nil
        }
    }

    init?(_ call: ToolCallDetail) {
        let name = call.toolName
            .replacingOccurrences(of: "^functions[._]+", with: "", options: .regularExpression)
            .replacingOccurrences(of: "^mcp__ripul_tools_+", with: "", options: .regularExpression)
        guard name == "device_speak" || name == "host_speak" else { return nil }
        let args = call.renderArguments?.objectValue ?? ToolValue.parse(call.arguments).objectValue
        guard let words = args?.string("text")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !words.isEmpty else { return nil }
        text = words

        let result = call.result.map { ToolValue.unwrap(ToolValue.parse($0)) }.flatMap(\.objectValue)
        if call.status == "error" || call.status == "failed" {
            delivery = .unavailable
            detail = call.error ?? "The audio could not be delivered."
        } else if result?["spoken"] == .bool(false) {
            delivery = .notSpoken
            detail = result?.string("reason") ?? "No active voice conversation."
        } else if result?["spoken"] == .bool(true) {
            // The tool confirms handoff to speech, not completed playback.
            delivery = .sent
            let device = result?.string("_deviceLabel")?.replacingOccurrences(of: "_", with: " ")
            detail = "Sent for speech" + (device.map { " on \($0)" } ?? "")
        } else if ["pending", "running", "in_progress", "streaming"].contains(call.status) {
            delivery = .pending
            detail = "Voice message; audio pending"
        } else {
            delivery = .unknown
            detail = "Voice message"
        }
    }
}

@available(iOS 16.0, macOS 14.0, *)
struct NativeChatSpeechDeliveryView: View {
    let speech: NativeChatSpeech
    let call: ToolCallDetail
    let chatId: String?
    let bridge: AgentBridge?

    var body: some View {
        Button {
            bridge?.toolCallDetails.apply(
                ToolCallDetailsRequest(
                    requestId: "\(chatId ?? "chat"):\(call.id)",
                    title: "Voice message",
                    calls: [call],
                    initialCallId: call.id,
                    chatId: chatId
                ),
                opening: true
            )
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "waveform")
                    .font(.ripulIcon(.caption))
                if let label = speech.label {
                    Text(label).font(.ripul(.caption))
                }
            }
            .foregroundStyle(speech.delivery == .unavailable ? Color.ripul(.danger) : Color.ripul(.textSecondary))
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(speech.label ?? speech.detail)
        .accessibilityHint("Show voice message details")
        .accessibilityIdentifier("NativeChat.speechDelivery.\(call.id)")
        .help(speech.detail)
    }
}
