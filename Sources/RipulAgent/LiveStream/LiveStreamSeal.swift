import CryptoKit
import Foundation

// MARK: - Frames sealed for a relay

/// Seals each frame of a session that crosses a relay room
/// (`LiveStreamScreenRelay`), so the room carries bytes it can't read or
/// change. A direct connection gets the same from TLS keyed by the viewer's
/// one-time key; a relayed one uses that key here, on each frame.
///
/// Each direction has its own key, drawn from the viewer's with HKDF, and
/// counts its frames from zero: a frame is ChaCha20-Poly1305 with that count
/// as its nonce, sent as `[count: 8 bytes, big-endian][ciphertext][tag: 16]`.
/// A frame that fails to open, or arrives out of turn, ends the session.
public final class LiveStreamSeal: @unchecked Sendable {
    public enum Side: String, Sendable {
        /// The one looking at the screen; it made the key.
        case viewer
        /// The screen's end (the Mac).
        case source
    }

    /// Bytes a sealed frame adds: its count and its tag.
    public static let overhead = 8 + 16

    private let sending: SymmetricKey
    private let receiving: SymmetricKey
    private let lock = NSLock()
    private var sent: UInt64 = 0
    private var received: UInt64 = 0

    public init(key: Data, side: Side) {
        let master = SymmetricKey(data: key)
        func draw(_ direction: String) -> SymmetricKey {
            HKDF<SHA256>.deriveKey(inputKeyMaterial: master, salt: Data("ripul.screen.relay".utf8),
                                   info: Data("\(direction) v1".utf8), outputByteCount: 32)
        }
        let toSource = draw("viewer to source"), toViewer = draw("source to viewer")
        sending = side == .viewer ? toSource : toViewer
        receiving = side == .viewer ? toViewer : toSource
    }

    /// Seals the next frame. Frames must go out in the order they were sealed:
    /// the caller seals and hands each to the connection under one lock.
    public func seal(_ frame: Data) throws -> Data {
        let count = lock.withLock { () -> UInt64 in
            defer { sent += 1 }
            return sent
        }
        let box = try ChaChaPoly.seal(frame, using: sending, nonce: try Self.nonce(count))
        var message = Data(capacity: Self.overhead + frame.count)
        withUnsafeBytes(of: count.bigEndian) { message.append(contentsOf: $0) }
        message.append(box.ciphertext)
        message.append(box.tag)
        return message
    }

    /// Opens the next frame; throws for one that was changed, sealed with
    /// another key, or isn't the next in turn.
    public func open(_ message: Data) throws -> Data {
        guard message.count >= Self.overhead else { throw LiveStreamError.malformed }
        let bytes = [UInt8](message)
        let count = bytes[0..<8].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        let expected = lock.withLock { received }
        guard count == expected else { throw LiveStreamError.malformed }
        let box = try ChaChaPoly.SealedBox(nonce: try Self.nonce(count),
                                           ciphertext: Data(bytes[8..<(bytes.count - 16)]),
                                           tag: Data(bytes[(bytes.count - 16)...]))
        let frame: Data
        do {
            frame = try ChaChaPoly.open(box, using: receiving)
        } catch {
            throw LiveStreamError.malformed
        }
        lock.withLock { received += 1 }
        return frame
    }

    private static func nonce(_ count: UInt64) throws -> ChaChaPoly.Nonce {
        var bytes = [UInt8](repeating: 0, count: 4)
        withUnsafeBytes(of: count.bigEndian) { bytes.append(contentsOf: $0) }
        return try ChaChaPoly.Nonce(data: bytes)
    }
}
