import Foundation

/// The microphone owns recording; a socket only borrows the unconfirmed audio.
/// Keep PCM until a transcript commit acknowledges an exact audio boundary.
/// All frame positions are absolute within this capture, including on reconnect.
final class BufferedSpeechAudio: @unchecked Sendable {
    struct Chunk {
        let pcm: Data
        let start: Int
        let end: Int
        let voiced: Bool
    }

    let sampleRate: Int
    private let capacity: Int
    private let lock = NSLock()
    private var chunks: [Chunk] = []
    private var captured = 0
    private var confirmed = 0
    private var accepting = true
    private var overflow = false
    private var lastCapture = Date()

    init(sampleRate: Int, seconds: Int = 60) {
        self.sampleRate = sampleRate
        capacity = sampleRate * seconds
    }

    func append(_ pcm: Data, voiced: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard accepting else { return }
        let frames = pcm.count / 2
        guard frames > 0 else { return }
        lastCapture = Date()
        guard captured - confirmed + frames <= capacity else {
            overflow = true
            accepting = false
            return
        }
        chunks.append(Chunk(pcm: pcm, start: captured, end: captured + frames, voiced: voiced))
        captured += frames
    }

    var snapshot: (captured: Int, confirmed: Int, overflow: Bool, recording: Bool, lastCapture: Date) {
        lock.lock(); defer { lock.unlock() }
        return (captured, confirmed, overflow, accepting, lastCapture)
    }

    func chunk(after frame: Int) -> Chunk? {
        lock.lock(); defer { lock.unlock() }
        return chunks.first { $0.start == frame }
    }

    func acknowledge(through frame: Int) {
        lock.lock(); defer { lock.unlock() }
        guard frame >= confirmed, frame <= captured else { return }
        confirmed = frame
        chunks.removeAll { $0.end <= frame }
    }

    func finishCapture() {
        lock.lock(); accepting = false; lock.unlock()
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        accepting = false
        chunks.removeAll()
    }
}
