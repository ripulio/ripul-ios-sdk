import SwiftUI
import AVKit

/// A player is created only when the person presses Play. Off-screen rows do
/// not download recordings or keep audio playing after their view is recycled.
@MainActor
final class NativeChatVideoPlayback: ObservableObject {
    @Published private(set) var player: AVPlayer?
    @Published private(set) var failed = false
    private var status: NSKeyValueObservation?

    func play(_ source: String) {
        guard player == nil else { player?.play(); return }
        guard let url = URL(string: source), ["https", "http", "file"].contains(url.scheme?.lowercased() ?? "") else {
            failed = true
            return
        }
        let item = AVPlayerItem(url: url)
        status = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            let failed = item.status == .failed
            Task { @MainActor [weak self] in
                if failed, self?.player?.currentItem === item { self?.failed = true; self?.player?.pause() }
            }
        }
        let next = AVPlayer(playerItem: item)
        player = next
        next.play()
    }

    func stop() {
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        status = nil
        failed = false
    }
}

struct NativeChatVideoView: View {
    let attachment: NativeChatVideoAttachment
    @StateObject private var playback = NativeChatVideoPlayback()

    private var aspect: CGFloat {
        guard let w = attachment.width, let h = attachment.height, w > 0, h > 0 else { return 1.6 }
        return CGFloat(w) / CGFloat(h)
    }

    var body: some View {
        ZStack {
            Color.black // theme-exempt: video letterbox
            if playback.failed {
                Text("Video unavailable.")
                    .foregroundStyle(.white) // theme-exempt: video letterbox
                    .accessibilityIdentifier("NativeChat.video.unavailable")
            } else if let player = playback.player {
                VideoPlayer(player: player)
                    .accessibilityLabel(attachment.name ?? "Recording")
            } else {
                Button {
                    playback.play(attachment.url)
                } label: {
                    ZStack {
                        if let poster = attachment.posterUrl, let url = URL(string: poster) {
                            AsyncImage(url: url) { image in image.resizable().scaledToFit() }
                                placeholder: { Color.clear }
                        }
                        Image(systemName: "play.circle.fill")
                            .font(.ripulIcon(size: 48))
                            .foregroundStyle(.white) // theme-exempt: video controls
                            .shadow(radius: 4)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Play \(attachment.name ?? "recording")")
                .accessibilityIdentifier("NativeChat.video.play.\(attachment.id)")
            }
        }
        .aspectRatio(aspect, contentMode: .fit)
        .frame(maxWidth: min(640, 480 * aspect))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .onDisappear { playback.stop() }
        .onChange(of: attachment.url) { _ in playback.stop() }
    }
}

/// The option's picture is part of the option button, with a stable placeholder
/// so loading it cannot shift the choices under a finger.
struct NativeChatChoiceImage: View {
    let source: String

    var body: some View {
        AsyncImage(url: URL(string: source)) { phase in
            switch phase {
            case .success(let image): image.resizable().scaledToFit()
            case .failure: Label("Image unavailable", systemImage: "photo")
            default: ProgressView()
            }
        }
        .frame(maxWidth: 260)
        .frame(height: 140)
        .background(Color.ripul(.text).opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityIdentifier("NativeChat.askUser.picture")
    }
}
