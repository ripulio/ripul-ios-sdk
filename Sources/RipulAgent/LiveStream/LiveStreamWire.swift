import Foundation

// MARK: - Live stream wire format
//
// A direct connection between a Live View viewer and the app it shows:
// H.264 one way, touches the other, inside `LiveStreamTLS`. Every message is
//
//     [type: UInt8][length: UInt32 big-endian][payload: length bytes]
//
// and nothing else crosses the connection — it carries this one session,
// never general commands. Pure and platform-neutral so both ends (and tests)
// share it.

public enum LiveStreamMessage: UInt8, Sendable {
    /// viewer → app, first: JSON {session, viewer?, maxLongSide?, fps?, bitrate?}
    case hello = 1
    /// app → viewer: JSON — window size in points, picture size in pixels, app and model
    case config = 2
    /// app → viewer: H.264 parameter sets, before every keyframe: [UInt16 length][SPS][UInt16 length][PPS]
    case format = 3
    /// app → viewer: [UInt8 flags (bit 0 = keyframe)][UInt64 presentation µs][AVCC NAL units]
    case video = 4
    /// viewer → app: JSON, the `touch` tool's arguments plus the gesture's `id`
    case touch = 5
    /// app → viewer: JSON {id, success, error?} — one per touch
    case touchResult = 6
    /// viewer → app: JSON {keyframe?, maxLongSide?, fps?, bitrate?}
    case control = 7
    /// either way: JSON {reason}; the sender closes after it
    case bye = 8
    /// either way: 8 opaque bytes, echoed back as pong, for round-trip time
    case ping = 9
    case pong = 10
    /// app → viewer, every couple of seconds: JSON {fps, captureMs, submitMs, kbps, skipped, pixelWidth, pixelHeight}
    case stats = 11
    /// viewer → app: fingers as they move. JSON {t, fingers: [{id, phase: down|move|up|cancel, x, y}]}
    /// — window points, and t the milliseconds since the first of the fingers now down came down, on
    /// the viewer's clock. One finger may be sent bare: {id, phase, x, y, t}. Sent only to an app
    /// whose config says pointer: true; more than one finger at once only if it says fingers: 2 or more.
    case pointer = 12
    /// viewer → app: typing into whatever has the keyboard. JSON {insert?: text, delete?: count,
    /// return?: true, dismiss?: true}. Sent only to an app whose config says keyboard: true.
    case key = 13
    /// app → viewer: the keyboard came up or went away. JSON {visible, type?, returnKey?, secure?}
    /// (UIKeyboardType and UIReturnKeyType raw values).
    case keyboard = 14
}

public enum LiveStreamWire {
    public static let headerLength = 5
    /// The most the app accepts in one message: it only takes small JSON.
    public static let maxToApp = 64 * 1024
    /// The most a viewer accepts: a keyframe of a full-resolution screen fits many times over.
    public static let maxToViewer = 8 * 1024 * 1024

    public static func frame(_ type: LiveStreamMessage, _ payload: Data) -> Data {
        var data = Data(capacity: headerLength + payload.count)
        data.append(type.rawValue)
        var length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        data.append(payload)
        return data
    }

    public static func frame(_ type: LiveStreamMessage, json: [String: Any]) -> Data {
        frame(type, (try? JSONSerialization.data(withJSONObject: json)) ?? Data("{}".utf8))
    }

    /// The type and payload length from a 5-byte header; nil for an unknown
    /// type or a length over `limit` — either means the stream can't be trusted.
    public static func header(_ bytes: Data, limit: Int) -> (type: LiveStreamMessage, length: Int)? {
        guard bytes.count >= headerLength, let type = LiveStreamMessage(rawValue: bytes[bytes.startIndex]) else {
            return nil
        }
        let length = bytes.dropFirst().prefix(4).reduce(0) { ($0 << 8) | Int($1) }
        return length <= limit ? (type, length) : nil
    }

    /// As `header`, for any kind: a peer built later may send kinds this
    /// build doesn't know, which the channel skips rather than fail on.
    public static func rawHeader(_ bytes: Data, limit: Int) -> (kind: UInt8, length: Int)? {
        guard bytes.count >= headerLength else { return nil }
        let length = bytes.dropFirst().prefix(4).reduce(0) { ($0 << 8) | Int($1) }
        return length <= limit ? (bytes[bytes.startIndex], length) : nil
    }

    public static func json(_ payload: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any] ?? [:]
    }

    // MARK: Video payloads

    public static func format(sps: Data, pps: Data) -> Data {
        var data = Data()
        for set in [sps, pps] {
            var length = UInt16(set.count).bigEndian
            withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
            data.append(set)
        }
        return data
    }

    public static func parseFormat(_ payload: Data) -> (sps: Data, pps: Data)? {
        var cursor = payload.startIndex
        var sets: [Data] = []
        for _ in 0..<2 {
            guard payload.endIndex - cursor >= 2 else { return nil }
            let length = Int(payload[cursor]) << 8 | Int(payload[cursor + 1])
            cursor += 2
            guard length > 0, payload.endIndex - cursor >= length else { return nil }
            sets.append(Data(payload[cursor..<(cursor + length)]))
            cursor += length
        }
        return cursor == payload.endIndex ? (sets[0], sets[1]) : nil
    }

    public static func video(keyframe: Bool, presentationMicros: UInt64, avcc: Data) -> Data {
        var data = Data(capacity: 9 + avcc.count)
        data.append(keyframe ? 1 : 0)
        var time = presentationMicros.bigEndian
        withUnsafeBytes(of: &time) { data.append(contentsOf: $0) }
        data.append(avcc)
        return data
    }

    public static func parseVideo(_ payload: Data) -> (keyframe: Bool, presentationMicros: UInt64, avcc: Data)? {
        guard payload.count > 9 else { return nil }
        let start = payload.startIndex
        let time = payload[(start + 1)..<(start + 9)].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        return (payload[start] & 1 == 1, time, Data(payload[(start + 9)...]))
    }
}

// MARK: - Live touches

/// Places a live finger's events on this device's clock. Each event says how
/// long after the finger came down it happened on the viewer; events can
/// arrive bunched (the network, a busy main thread), and stamping them with
/// their arrival time would turn an even flick into a standstill and a jump
/// — UIKit works out a scroll's momentum from these times. Times never go
/// backwards and never run ahead of now.
public struct LiveStreamPointerTimeline: Sendable {
    public let start: UInt64
    public let ticksPerMillisecond: Double
    public private(set) var last: UInt64

    /// `start` is this device's clock, in its own ticks, when the finger came down.
    public init(start: UInt64, ticksPerMillisecond: Double) {
        self.start = start
        self.ticksPerMillisecond = ticksPerMillisecond
        last = start
    }

    public mutating func time(offsetMilliseconds: Double, now: UInt64) -> UInt64 {
        let offset = offsetMilliseconds.isFinite ? min(max(offsetMilliseconds, 0), 600_000) : 0
        let wanted = start &+ UInt64(offset * ticksPerMillisecond)
        let time = max(min(wanted, now), last &+ 1)
        last = time
        return time
    }
}
