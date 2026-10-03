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
    /// Version 2 adds, for a source that takes a mouse: {special?: "escape" | "tab" | "left" | …
    /// (`LiveStreamKeys.specials`), modifiers?: ["command", "shift", "option", "control"]} —
    /// a letter with modifiers is `insert` with them ("command" + "c" is copy).
    case key = 13
    /// app → viewer: the keyboard came up or went away. JSON {visible, type?, returnKey?, secure?}
    /// (UIKeyboardType and UIReturnKeyType raw values). A page or a Mac window sends it too, when
    /// a text field takes or loses focus.
    case keyboard = 14

    // Version 2: every remote screen, not only an app's (see `LiveStreamProtocol`).

    /// viewer → source: a mouse. JSON {t, action: move | down | up, x, y, button?: left | right |
    /// middle, clicks?: 1-3, modifiers?}. `move` with a button held is a drag. Picture points,
    /// top left 0,0; `t` in milliseconds on the viewer's clock, from the gesture's first event.
    /// A held button is repeated as `move` twice a second while still; the source lets go of a
    /// button it hasn't heard about for `LiveStreamHeldInput.silence`, and of all of them when
    /// the connection goes.
    case mouse = 15
    /// viewer → source: a scroll wheel or trackpad. JSON {t, dx, dy, x, y, phase: began | changed |
    /// ended | momentum | momentumEnded}. Points, in the direction the content moves under a finger
    /// (a finger dragging up has dy < 0). The phases are the gesture's own: the source passes them
    /// on, so an app animates one continuous scroll rather than a step per event.
    case wheel = 16
    /// source → viewer: what the source shows, whenever any of it changes (`LiveStreamState`).
    case state = 17
    /// source → viewer: a sharp picture of a screen that has stopped changing, sent once it has
    /// been still for a moment: [UInt64 µs][UInt32 x][UInt32 y][UInt32 full width][UInt32 full
    /// height][JPEG] (`LiveStreamWire.still`). Video is soft at rest where text is concerned; the
    /// viewer shows the still over the video until a video picture later than the still's µs.
    /// A whole still is at 0,0 and as big as its full size; while it shows, a small change (a
    /// caret, a word typed) comes as a patch — a still of just that part, drawn into it at x,y —
    /// rather than as video, so the text around it stays sharp.
    case still = 18
    /// either way: reading mode's frames (Remote Tabs' rrweb mirror), JSON {frame}. The session
    /// carries them as the relay would: the host page's tab mirror sees one more viewer, and the
    /// viewer's page its usual frames and RPC replies.
    case dom = 19
    /// either way: the shared clipboard. JSON {text, revision}.
    case clipboard = 20
    /// viewer → source: a command beside the picture. JSON {id, method, args}. The source answers
    /// only methods on its own allowlist.
    case invoke = 21
    /// source → viewer: JSON {id, result?, error?}, one per `invoke`.
    case reply = 22
    /// source → viewer: who is driving. JSON {driving, by?}. Several viewers may watch one screen;
    /// one drives, and a watcher's input is dropped until it asks to drive (control {drive: true}).
    case controller = 23
    /// room → either end, in a support session (`LiveStreamRelay`): what the room itself has to
    /// say. JSON {event: "peer", role: customer | supporter, present, name?, who?, expiresAt} when
    /// the other end comes or goes, and {event: "ended", reason} when the session is over. Only
    /// the room sends it: one from the other end is dropped on the way.
    case room = 24
}

/// Version 2 of the session: what the source is and what it takes. Version 1
/// is an app's screen with touches; a peer of either version reads the other,
/// since every addition is a new kind (skipped by a peer that doesn't know it)
/// or a new field (ignored).
public enum LiveStreamProtocol {
    public static let version = 2

    /// What the picture is of.
    public enum Source: String, Sendable, CaseIterable {
        /// An app built with the SDK, on an iPhone or a simulator.
        case app
        /// One window on a Mac.
        case macWindow
        /// A whole display of a Mac.
        case macDisplay
        /// A web page the Mac host runs for a viewer (Remote Tabs, authentic).
        case page
        /// A browser tab, as its structure rather than pixels (Remote Tabs, reading).
        case tab
    }

    /// The kind of input the source takes.
    public enum Input: String, Sendable {
        /// Fingers (`pointer`, `touch`).
        case touch
        /// A pointer with buttons and a wheel (`mouse`, `wheel`).
        case mouse
    }
}

/// A source's `config`, read by a viewer. A version 1 app says nothing of the
/// version 2 fields; they read as an app's screen that takes touches.
public struct LiveStreamConfig: Sendable, Equatable {
    public var version: Int
    public var source: LiveStreamProtocol.Source
    public var input: LiveStreamProtocol.Input
    /// What the source can do beyond the picture: "resize", "crop", "navigate", "clipboard", …
    public var controls: Set<String>
    /// The picture in points, which input is given in.
    public var width: Double
    public var height: Double
    public var pixelWidth: Int
    public var pixelHeight: Int
    /// The source sends `still` pictures when the screen rests.
    public var stills: Bool

    public init(json: [String: Any]) {
        version = (json["protocol"] as? NSNumber)?.intValue ?? 1
        source = (json["source"] as? String).flatMap(LiveStreamProtocol.Source.init) ?? .app
        input = (json["input"] as? String).flatMap(LiveStreamProtocol.Input.init) ?? .touch
        controls = Set(json["controls"] as? [String] ?? [])
        width = (json["width"] as? NSNumber)?.doubleValue ?? 0
        height = (json["height"] as? NSNumber)?.doubleValue ?? 0
        pixelWidth = (json["pixelWidth"] as? NSNumber)?.intValue ?? 0
        pixelHeight = (json["pixelHeight"] as? NSNumber)?.intValue ?? 0
        stills = json["stills"] as? Bool ?? false
    }

    /// The version 2 fields, for a source to add to the rest of its `config`.
    public static func fields(source: LiveStreamProtocol.Source, input: LiveStreamProtocol.Input,
                              controls: [String], stills: Bool) -> [String: Any] {
        ["protocol": LiveStreamProtocol.version, "source": source.rawValue, "input": input.rawValue,
         "controls": controls, "stills": stills]
    }
}

/// What a source shows beyond its picture (`LiveStreamMessage.state`). Sent
/// whole the first time, then only what changed; a viewer merges them. A
/// field that goes away is sent as JSON null.
public struct LiveStreamState: Sendable, Equatable {
    public var title: String?
    public var url: String?
    public var loading: Bool?
    public var canGoBack: Bool?
    public var canGoForward: Bool?
    /// The pointer's shape over the picture: "arrow", "text", "hand", "resize", …
    public var cursor: String?
    /// The Mac's screen is locked.
    public var locked: Bool?
    /// A dialog is showing, and the picture takes it in.
    public var dialog: Bool?
    /// The picture in points.
    public var width: Double?
    public var height: Double?
    /// The part of the source's own frame the picture shows, in its points: {x, y, width, height}.
    public var crop: [String: Double]?

    public init() {}

    static let keys = ["title", "url", "loading", "canGoBack", "canGoForward", "cursor", "locked", "dialog",
                       "width", "height", "crop"]

    public init(json: [String: Any]) {
        self.init()
        merge(json)
    }

    /// Takes what a `state` message says; null clears a field.
    public mutating func merge(_ json: [String: Any]) {
        func text(_ key: String) -> String?? { json.keys.contains(key) ? .some(json[key] as? String) : .none }
        func flag(_ key: String) -> Bool?? { json.keys.contains(key) ? .some(json[key] as? Bool) : .none }
        func number(_ key: String) -> Double?? {
            json.keys.contains(key) ? .some((json[key] as? NSNumber)?.doubleValue) : .none
        }
        if let value = text("title") { title = value }
        if let value = text("url") { url = value }
        if let value = flag("loading") { loading = value }
        if let value = flag("canGoBack") { canGoBack = value }
        if let value = flag("canGoForward") { canGoForward = value }
        if let value = text("cursor") { cursor = value }
        if let value = flag("locked") { locked = value }
        if let value = flag("dialog") { dialog = value }
        if let value = number("width") { width = value }
        if let value = number("height") { height = value }
        if json.keys.contains("crop") {
            crop = (json["crop"] as? [String: Any])?.compactMapValues { ($0 as? NSNumber)?.doubleValue }
        }
    }

    public var json: [String: Any] {
        var json: [String: Any] = [:]
        if let title { json["title"] = title }
        if let url { json["url"] = url }
        if let loading { json["loading"] = loading }
        if let canGoBack { json["canGoBack"] = canGoBack }
        if let canGoForward { json["canGoForward"] = canGoForward }
        if let cursor { json["cursor"] = cursor }
        if let locked { json["locked"] = locked }
        if let dialog { json["dialog"] = dialog }
        if let width { json["width"] = width }
        if let height { json["height"] = height }
        if let crop { json["crop"] = crop }
        return json
    }

    /// What differs from `before`: the fields that changed, and null for those that went away.
    public func changes(since before: LiveStreamState) -> [String: Any] {
        let now = json, then = before.json
        var changed: [String: Any] = [:]
        for key in Self.keys {
            switch (now[key], then[key]) {
            case (nil, nil): continue
            case (nil, _): changed[key] = NSNull()
            case (let value?, nil): changed[key] = value
            case (let value?, let old?):
                if !(value as AnyObject).isEqual(old) { changed[key] = value }
            }
        }
        return changed
    }
}

/// The keys a mouse source takes by name (`key` {special}), beyond text.
public enum LiveStreamKeys {
    public static let specials: Set<String> = [
        "return", "enter", "tab", "escape", "delete", "forwardDelete", "space",
        "left", "right", "up", "down", "home", "end", "pageUp", "pageDown",
        "f1", "f2", "f3", "f4", "f5", "f6", "f7", "f8", "f9", "f10", "f11", "f12",
    ]
    public static let modifiers: Set<String> = ["command", "shift", "option", "control", "function"]
}

/// Buttons a viewer is holding down on the source's screen, and when the
/// viewer last said anything about them. A button nobody lets go of — the
/// viewer's app went away, its network dropped — is let go of here, so the
/// source isn't left mid-drag. Pure, so either end and the tests share it.
public struct LiveStreamHeldInput: Sendable {
    /// How long a held button lasts without a word from the viewer, which
    /// repeats itself twice a second while it holds one still.
    public static let silence: TimeInterval = 2.5

    public private(set) var held: Set<String> = []
    public private(set) var heardAt: TimeInterval = 0
    /// Where the pointer was last put, in picture points.
    public private(set) var point: (x: Double, y: Double) = (0, 0)

    public init() {}

    /// Takes one `mouse` message: which buttons it leaves held, and where.
    public mutating func heard(action: String, button: String?, x: Double?, y: Double?, at time: TimeInterval) {
        heardAt = time
        if let x, let y { point = (x, y) }
        let button = button ?? "left"
        switch action {
        case "down": held.insert(button)
        case "up": held.remove(button)
        default: break
        }
    }

    /// Anything held that has gone unheard for too long, now; nothing if all is well.
    public func expired(now: TimeInterval) -> Bool {
        !held.isEmpty && now - heardAt > Self.silence
    }

    /// Lets go of everything; returns what was held, to release at `point`.
    public mutating func releaseAll() -> Set<String> {
        defer { held.removeAll() }
        return held
    }
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

    // MARK: Still pictures

    /// A still picture, or a patch of one: `jpeg` goes at `x`,`y` in a
    /// picture `fullWidth` by `fullHeight` pixels.
    public struct Still: Equatable, Sendable {
        public var presentationMicros: UInt64
        public var x: Int
        public var y: Int
        public var fullWidth: Int
        public var fullHeight: Int
        public var jpeg: Data

        public init(presentationMicros: UInt64, x: Int = 0, y: Int = 0, fullWidth: Int, fullHeight: Int, jpeg: Data) {
            self.presentationMicros = presentationMicros
            self.x = x
            self.y = y
            self.fullWidth = fullWidth
            self.fullHeight = fullHeight
            self.jpeg = jpeg
        }

        /// A whole picture rather than a patch of one.
        public var isWhole: Bool { x == 0 && y == 0 }
    }

    public static func still(_ still: Still) -> Data {
        var data = Data(capacity: 24 + still.jpeg.count)
        var time = still.presentationMicros.bigEndian
        withUnsafeBytes(of: &time) { data.append(contentsOf: $0) }
        for value in [still.x, still.y, still.fullWidth, still.fullHeight] {
            var word = UInt32(clamping: max(value, 0)).bigEndian
            withUnsafeBytes(of: &word) { data.append(contentsOf: $0) }
        }
        data.append(still.jpeg)
        return data
    }

    public static func parseStill(_ payload: Data) -> Still? {
        guard payload.count > 24 else { return nil }
        let start = payload.startIndex
        let time = payload[start..<(start + 8)].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        func word(_ offset: Int) -> Int {
            Int(payload[(start + offset)..<(start + offset + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
        }
        let still = Still(presentationMicros: time, x: word(8), y: word(12), fullWidth: word(16), fullHeight: word(20),
                          jpeg: Data(payload[(start + 24)...]))
        guard still.fullWidth > 0, still.fullHeight > 0, still.x < still.fullWidth, still.y < still.fullHeight else {
            return nil
        }
        return still
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
