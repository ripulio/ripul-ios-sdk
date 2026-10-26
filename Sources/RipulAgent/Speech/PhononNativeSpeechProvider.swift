import Foundation
import AVFoundation
import Compression
import CryptoKit

/// Injectable bridge to the compiled `PhononTTS` (`ptts`) Core ML runtime so
/// `RipulAgent` can drive Phonon on iPhone and Mac without forcing every SDK
/// target (such as Mac Catalyst or lightweight unit-test targets) to link the
/// platform-specific `PhononCore.xcframework`.
@available(iOS 26.0, macOS 26.0, *)
public struct PhononBackend: Sendable {
    public typealias SpeakClosure = @Sendable (
        _ directory: URL,
        _ voice: String,
        _ language: String,
        _ text: String,
        _ onAudioChunk: @escaping @Sendable ([Float]) -> Bool
    ) async throws -> Void

    public var needsCompiling: @Sendable (URL) -> Bool
    public var preload: @Sendable (URL, String, String) async throws -> [String]
    public var speak: SpeakClosure

    public init(
        needsCompiling: @escaping @Sendable (URL) -> Bool,
        preload: @escaping @Sendable (URL, String, String) async throws -> [String],
        speak: @escaping SpeakClosure
    ) {
        self.needsCompiling = needsCompiling
        self.preload = preload
        self.speak = speak
    }
}

/// Manages downloading, verifying, and caching the `phonon-31m-en-coreml` bundle
/// in `Application Support/PhononTTS/models` (excluded from backup) so the iOS
/// IPA stays well below the 100 MB OTA upload limit (`MAX_IPA_BYTES`).
@available(iOS 26.0, macOS 26.0, *)
@MainActor
public final class PhononModelStore: ObservableObject {
    public static let shared = PhononModelStore()

    public enum Status: Equatable {
        case notInstalled
        case downloading(Double)
        case extracting
        case compiling
        case ready
        case failed(String)
    }

    public static let releaseArchiveURL = URL(
        string: "https://github.com/gradium-ai/xn-ptts/releases/download/v0.4.0/phonon-31m-en-coreml.zip"
    )!

    public struct Manifest: Decodable {
        public struct File: Decodable {
            public let path: String
            public let size: Int
            public let sha256: String
        }
        public let built: Int
        public let files: [File]
        public let voices: [String]?
    }

    @Published public private(set) var status: Status = .notInstalled
    private var activeTask: Task<URL, Error>?

    public var modelsDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "PhononTTS/models", directoryHint: .isDirectory)
    }

    private init() {
        refreshStatus()
    }

    public func refreshStatus() {
        if Self.isInstalled(at: modelsDirectory) {
            status = .ready
        } else if case .downloading = status {
            // keep active download state
        } else if case .extracting = status {
            // keep active extraction state
        } else if case .compiling = status {
            // keep active compile state
        } else {
            status = .notInstalled
        }
    }

    func markCompiling() {
        status = .compiling
    }

    func markReady() {
        status = .ready
    }

    func markFailed(_ message: String) {
        status = .failed(message)
    }

    nonisolated public static func manifest(at dir: URL) -> Manifest? {
        guard let data = try? Data(contentsOf: dir.appending(path: "bundle.json")) else { return nil }
        return try? JSONDecoder().decode(Manifest.self, from: data)
    }

    nonisolated public static func isInstalled(at dir: URL) -> Bool {
        guard let manifest = manifest(at: dir) else { return false }
        let fm = FileManager.default
        return manifest.files.allSatisfy { file in
            fm.fileExists(atPath: dir.appending(path: file.path).path)
        }
    }

    /// Ensures the Core ML bundle is present on disk, installing from the app
    /// bundle if present or downloading from the official release archive.
    public func ensureInstalled() async throws -> URL {
        let dir = modelsDirectory
        if Self.isInstalled(at: dir) {
            if status != .ready && status != .compiling { status = .ready }
            return dir
        }
        if let bundled = Bundle.main.url(forResource: "Models", withExtension: nil),
           Self.isInstalled(at: bundled) {
            try Self.copyBundle(from: bundled, to: dir)
            status = .ready
            return dir
        }
        if let existing = activeTask {
            return try await existing.value
        }
        let task = Task<URL, Error> { @MainActor [self] in
            defer { self.activeTask = nil }
            do {
                self.status = .downloading(0)
                let archiveURL = try await self.downloadArchive { [weak self] fraction in
                    Task { @MainActor in
                        guard let self, case .downloading = self.status else { return }
                        self.status = .downloading(fraction)
                    }
                }
                defer { try? FileManager.default.removeItem(at: archiveURL) }
                self.status = .extracting
                try await Task.detached(priority: .userInitiated) {
                    try Self.extractAndVerifyArchive(at: archiveURL, to: dir)
                }.value
                self.status = .ready
                return dir
            } catch {
                self.status = .failed(error.localizedDescription)
                throw error
            }
        }
        activeTask = task
        return try await task.value
    }

    private func downloadArchive(onProgress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let delegate = DownloadProgressDelegate(onProgress: onProgress)
        // Ephemeral session so StandaloneNetworkPolicy's global URLProtocol does
        // not block a user-requested on-device voice model download.
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (tmpURL, response) = try await session.download(from: Self.releaseArchiveURL)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw PhononNativeSpeechProvider.ProviderError.downloadFailed("HTTP \(http.statusCode)")
        }
        let preserved = FileManager.default.temporaryDirectory
            .appendingPathComponent("phonon-31m-en-coreml-\(UUID().uuidString).zip")
        try? FileManager.default.removeItem(at: preserved)
        try FileManager.default.moveItem(at: tmpURL, to: preserved)
        return preserved
    }

    private nonisolated static func copyBundle(from source: URL, to dir: URL) throws {
        let fm = FileManager.default
        try? fm.removeItem(at: dir)
        try fm.createDirectory(at: dir.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: source, to: dir)
        try excludeFromBackup(dir)
    }

    nonisolated static func extractAndVerifyArchive(at zipURL: URL, to dir: URL) throws {
        let fm = FileManager.default
        let staging = dir.deletingLastPathComponent()
            .appending(path: "models.staging-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? fm.removeItem(at: staging)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        let data = try Data(contentsOf: zipURL, options: .mappedIfSafe)
        func u16(_ at: Int) -> Int { Int(data[at]) | (Int(data[at + 1]) << 8) }
        func u32(_ at: Int) -> Int { u16(at) | (u16(at + 2) << 16) }

        var offset = 0
        while offset + 30 <= data.count {
            let sig = u32(offset)
            if sig != 0x04034b50 { break }
            let method = u16(offset + 8)
            let compSize = u32(offset + 18)
            let uncompSize = u32(offset + 22)
            let nameLen = u16(offset + 26)
            let extraLen = u16(offset + 28)
            let nameStart = offset + 30
            let dataStart = nameStart + nameLen + extraLen
            guard dataStart >= 0, dataStart + compSize <= data.count else {
                throw PhononNativeSpeechProvider.ProviderError.downloadFailed("Corrupt model archive header")
            }
            let rawName = String(decoding: data[nameStart..<(nameStart + nameLen)], as: UTF8.self)
            offset = dataStart + compSize

            let parts = rawName.split(separator: "/", omittingEmptySubsequences: true)
            guard parts.count > 1 else { continue }
            let rel = parts.dropFirst().joined(separator: "/")
            if rel.isEmpty || rawName.hasSuffix("/") || parts.contains("..") { continue }

            let dest = staging.appending(path: rel)
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)

            if method == 0 {
                try data[dataStart..<(dataStart + compSize)].write(to: dest, options: .atomic)
            } else if method == 8 {
                var out = Data(count: uncompSize)
                let decoded = out.withUnsafeMutableBytes { dst -> Int in
                    data[dataStart..<(dataStart + compSize)].withUnsafeBytes { src -> Int in
                        guard let dstBase = dst.bindMemory(to: UInt8.self).baseAddress,
                              let srcBase = src.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                        return compression_decode_buffer(
                            dstBase, uncompSize,
                            srcBase, compSize,
                            nil, COMPRESSION_ZLIB
                        )
                    }
                }
                guard decoded == uncompSize else {
                    throw PhononNativeSpeechProvider.ProviderError.downloadFailed("Failed decompressing \(rel)")
                }
                try out.write(to: dest, options: .atomic)
            } else {
                throw PhononNativeSpeechProvider.ProviderError.downloadFailed("Unsupported archive compression \(method)")
            }
        }

        guard let manifest = manifest(at: staging) else {
            throw PhononNativeSpeechProvider.ProviderError.downloadFailed("Missing bundle.json in model archive")
        }
        for file in manifest.files {
            let fileURL = staging.appending(path: file.path)
            let fileData = try Data(contentsOf: fileURL, options: .mappedIfSafe)
            guard fileData.count == file.size else {
                throw PhononNativeSpeechProvider.ProviderError.downloadFailed("Size mismatch for \(file.path)")
            }
            let digest = SHA256.hash(data: fileData).map { String(format: "%02x", $0) }.joined()
            guard digest == file.sha256 else {
                throw PhononNativeSpeechProvider.ProviderError.downloadFailed("Checksum mismatch for \(file.path)")
            }
        }

        try fm.createDirectory(at: dir.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: dir)
        try fm.moveItem(at: staging, to: dir)
        try excludeFromBackup(dir)
    }

    private nonisolated static func excludeFromBackup(_ url: URL) throws {
        var mutable = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try mutable.setResourceValues(values)
    }

    private final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate, Sendable {
        let onProgress: @Sendable (Double) -> Void
        init(onProgress: @escaping @Sendable (Double) -> Void) {
            self.onProgress = onProgress
        }
        func urlSession(
            _ session: URLSession,
            downloadTask: URLSessionDownloadTask,
            didWriteData bytesWritten: Int64,
            totalBytesWritten: Int64,
            totalBytesExpectedToWrite: Int64
        ) {
            guard totalBytesExpectedToWrite > 0 else { return }
            onProgress(min(1.0, max(0.0, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))))
        }
        func urlSession(
            _ session: URLSession,
            downloadTask: URLSessionDownloadTask,
            didFinishDownloadingTo location: URL
        ) {}
    }
}

/// On-device neural text-to-speech provider powered by Gradium Phonon 31m
/// running on the Apple Neural Engine via Core ML.
@available(iOS 26.0, macOS 26.0, *)
@MainActor
public final class PhononNativeSpeechProvider: NativeSpeechProviding {
    public static let shared = PhononNativeSpeechProvider()

    public let id = "phonon"
    public let label = "Phonon (on-device)"
    public static let sampleRate: Double = 24_000
    public static let defaultVoiceId = "Zoey"

    /// All 37 built-in voices shipped in `phonon-31m-en-coreml` with region and
    /// gender metadata from `gradium/phonon-voices`, ordered with natural US/UK
    /// voices first and character voices after.
    public static let builtInVoiceCatalog: [SpeechService.Voice] = [
        // US — Female
        .init(id: "Zoey", name: "Zoey", region: "US", gender: "Female"),
        .init(id: "Juniper", name: "Juniper", region: "US", gender: "Female"),
        .init(id: "Everly", name: "Everly", region: "US", gender: "Female"),
        .init(id: "Harper", name: "Harper", region: "US", gender: "Female"),
        .init(id: "Hadley", name: "Hadley", region: "US", gender: "Female"),
        .init(id: "Delia", name: "Delia", region: "US", gender: "Female"),
        // US — Male
        .init(id: "Easton", name: "Easton", region: "US", gender: "Male"),
        .init(id: "Micah", name: "Micah", region: "US", gender: "Male"),
        .init(id: "Trevor", name: "Trevor", region: "US", gender: "Male"),
        .init(id: "Russell", name: "Russell", region: "US", gender: "Male"),
        .init(id: "Preston", name: "Preston", region: "US", gender: "Male"),
        .init(id: "Miles", name: "Miles", region: "US", gender: "Male"),
        // UK — Female
        .init(id: "Maeve", name: "Maeve", region: "UK", gender: "Female"),
        .init(id: "Freya", name: "Freya", region: "UK", gender: "Female"),
        .init(id: "Pippa", name: "Pippa", region: "UK", gender: "Female"),
        .init(id: "Elodie-Rose", name: "Elodie-Rose", region: "UK", gender: "Female"),
        .init(id: "Imogen", name: "Imogen", region: "UK", gender: "Female"),
        .init(id: "Lottie", name: "Lottie", region: "UK", gender: "Female"),
        .init(id: "Bryony", name: "Bryony", region: "UK", gender: "Female"),
        // UK — Male
        .init(id: "Alfie", name: "Alfie", region: "UK", gender: "Male"),
        .init(id: "Hugh", name: "Hugh", region: "UK", gender: "Male"),
        .init(id: "Edwin", name: "Edwin", region: "UK", gender: "Male"),
        .init(id: "Spencer", name: "Spencer", region: "UK", gender: "Male"),
        .init(id: "Toby", name: "Toby", region: "UK", gender: "Male"),
        .init(id: "Teddy", name: "Teddy", region: "UK", gender: "Male"),
        // Character voices
        .init(id: "Captain Silas Blackwater", name: "Captain Silas Blackwater", region: "UK · Character", gender: "Male"),
        .init(id: "Morwenna of the Deep", name: "Morwenna of the Deep", region: "Character", gender: "Female"),
        .init(id: "Old Mortlake", name: "Old Mortlake", region: "UK · Character", gender: "Male"),
        .init(id: "Azgorath", name: "Azgorath", region: "Character", gender: "Male"),
        .init(id: "Fennick the Young Elf", name: "Fennick the Young Elf", region: "Character", gender: "Male"),
        .init(id: "The Thing Under the Stairs", name: "The Thing Under the Stairs", region: "Character", gender: "Creature"),
        .init(id: "Vyrmathrax the Ancient", name: "Vyrmathrax the Ancient", region: "Character", gender: "Male"),
        .init(id: "Grub the Ogre", name: "Grub the Ogre", region: "Character", gender: "Male"),
        .init(id: "Master Aldric", name: "Master Aldric", region: "UK · Character", gender: "Male"),
        .init(id: "The Snow Queen", name: "The Snow Queen", region: "Character", gender: "Female"),
        .init(id: "Sir Bramwell", name: "Sir Bramwell", region: "UK · Character", gender: "Male"),
        .init(id: "Fairy Godmother", name: "Fairy Godmother", region: "Character", gender: "Female"),
    ]

    public static let builtInVoices: [String] = builtInVoiceCatalog.map(\.id)

    public enum ProviderError: LocalizedError {
        case runtimeUnavailable
        case downloadFailed(String)
        case transcriptionUnsupported

        public var errorDescription: String? {
            switch self {
            case .runtimeUnavailable:
                return "Phonon on-device runtime is not available on this platform build"
            case .downloadFailed(let detail):
                return "Phonon model setup failed: \(detail)"
            case .transcriptionUnsupported:
                return "Phonon is a text-to-speech model; select Apple or ElevenLabs for speech recognition"
            }
        }
    }

    private static var registeredBackend: PhononBackend?

    public static func registerBackend(_ backend: PhononBackend) {
        registeredBackend = backend
    }

    private let modelStore = PhononModelStore.shared
    private var engine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private let audioFormat = AVAudioFormat(standardFormatWithSampleRate: PhononNativeSpeechProvider.sampleRate, channels: 1)!
    private var speakTask: Task<Void, Never>?
    private var generation: Int = 0
    private var isPaused: Bool = false

    public init() {}

    public func listVoicesSync() -> [SpeechService.Voice] {
        Self.builtInVoiceCatalog
    }

    public func listVoices() async throws -> [SpeechService.Voice] {
        listVoicesSync()
    }

    public static func resolveVoiceName(_ requested: String?) -> String {
        if let requested, !requested.isEmpty, builtInVoices.contains(requested) {
            return requested
        }
        let preferred = SpeechPreferences.phononVoiceId
        if builtInVoices.contains(preferred) {
            return preferred
        }
        return defaultVoiceId
    }

    public func speak(
        text: String,
        voiceId: String?,
        onPlaybackEnd: (@MainActor () -> Void)?
    ) async throws {
        stopSpeaking()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            onPlaybackEnd?()
            return
        }
        guard let backend = Self.registeredBackend else {
            throw ProviderError.runtimeUnavailable
        }

        generation &+= 1
        let currentGen = generation
        isPaused = false

        let modelDir = try await modelStore.ensureInstalled()
        guard currentGen == generation else { return }

        if backend.needsCompiling(modelDir) {
            modelStore.markCompiling()
        }

        let voice = Self.resolveVoiceName(voiceId)
        VoiceAudioSession.configureForPlayback()
        try startAudioEngineIfNeeded()

        try await withCheckedThrowingContinuation { (started: CheckedContinuation<Void, Error>) in
            let resumeOnce = FirstChunkGate(continuation: started)
            self.speakTask = Task { @MainActor [weak self] in
                guard let self, self.generation == currentGen else {
                    resumeOnce.cancel()
                    return
                }
                let node = self.playerNode
                let format = self.audioFormat
                do {
                    try await backend.speak(modelDir, voice, "en", trimmed) { [weak self] samples in
                        guard !samples.isEmpty,
                              let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
                        else { return true }
                        buf.frameLength = AVAudioFrameCount(samples.count)
                        samples.withUnsafeBufferPointer { ptr in
                            if let base = ptr.baseAddress {
                                buf.floatChannelData?[0].update(from: base, count: samples.count)
                            }
                        }
                        node?.scheduleBuffer(buf)
                        if resumeOnce.markStarted() {
                            Task { @MainActor [weak self] in
                                self?.modelStore.markReady()
                            }
                        }
                        return true
                    }
                    guard self.generation == currentGen, !Task.isCancelled else {
                        resumeOnce.cancel()
                        return
                    }
                    self.modelStore.markReady()
                    _ = resumeOnce.markStarted()
                    self.schedulePlaybackCompletion(for: currentGen, onPlaybackEnd: onPlaybackEnd)
                } catch {
                    if self.generation == currentGen, !Task.isCancelled {
                        self.modelStore.markFailed(error.localizedDescription)
                        resumeOnce.fail(error)
                    } else {
                        resumeOnce.cancel()
                    }
                }
            }
        }
    }

    private func startAudioEngineIfNeeded() throws {
        if let engine, let playerNode {
            if !engine.isRunning {
                try engine.start()
            }
            if !playerNode.isPlaying {
                playerNode.play()
            }
            return
        }
        let newEngine = AVAudioEngine()
        let newNode = AVAudioPlayerNode()
        newEngine.attach(newNode)
        newEngine.connect(newNode, to: newEngine.mainMixerNode, format: audioFormat)
        try newEngine.start()
        newNode.play()
        self.engine = newEngine
        self.playerNode = newNode
    }

    private func schedulePlaybackCompletion(for gen: Int, onPlaybackEnd: (@MainActor () -> Void)?) {
        guard let onPlaybackEnd else { return }
        guard let node = playerNode,
              let sentinel = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: 1) else {
            onPlaybackEnd()
            return
        }
        sentinel.frameLength = 1
        sentinel.floatChannelData?[0][0] = 0
        node.scheduleBuffer(sentinel, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == gen else { return }
                onPlaybackEnd()
            }
        }
    }

    public func pauseSpeaking() {
        isPaused = true
        playerNode?.pause()
    }

    public func resumeSpeaking() {
        guard isPaused else { return }
        isPaused = false
        try? startAudioEngineIfNeeded()
        playerNode?.play()
    }

    public func stopSpeaking() {
        generation &+= 1
        isPaused = false
        speakTask?.cancel()
        speakTask = nil
        playerNode?.stop()
        if engine?.isRunning == true {
            playerNode?.play()
        }
    }

    public func startTranscription(onEvent: @escaping @MainActor (SpeechService.TranscriptionEvent) -> Void) async throws {
        throw ProviderError.transcriptionUnsupported
    }

    public func stopTranscription() {}
}

private final class FirstChunkGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?

    init(continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }

    func markStarted() -> Bool {
        lock.lock()
        guard let cont = continuation else {
            lock.unlock()
            return false
        }
        continuation = nil
        lock.unlock()
        cont.resume()
        return true
    }

    func fail(_ error: Error) {
        lock.lock()
        guard let cont = continuation else {
            lock.unlock()
            return
        }
        continuation = nil
        lock.unlock()
        cont.resume(throwing: error)
    }

    func cancel() {
        lock.lock()
        guard let cont = continuation else {
            lock.unlock()
            return
        }
        continuation = nil
        lock.unlock()
        cont.resume()
    }
}
