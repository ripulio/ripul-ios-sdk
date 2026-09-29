import Foundation
import CoreMedia
import CoreVideo
import VideoToolbox
import QuartzCore

// MARK: - Encoding (the app's end)

/// One encoded picture, ready for `LiveStreamWire.video`.
public struct LiveStreamEncodedFrame: Sendable {
    public let keyframe: Bool
    public let presentationMicros: UInt64
    /// Length-prefixed (4-byte, big-endian) NAL units.
    public let avcc: Data
    /// H.264 parameter sets, present on keyframes.
    public let parameterSets: (sps: Data, pps: Data)?
}

/// H.264 for a live picture: real time, no frame reordering (so nothing
/// waits on a later frame), low-latency rate control where the OS has it,
/// and a keyframe on request — a viewer joining or losing its place.
public final class LiveStreamEncoder: @unchecked Sendable {
    public let width: Int32
    public let height: Int32
    private var session: VTCompressionSession?
    private let output: @Sendable (LiveStreamEncodedFrame) -> Void
    private let lock = NSLock()
    private var inFlight = 0
    private var failed = 0
    private var produced = 0
    private var waitingSince: CFTimeInterval?

    /// Which encoder to ask for, and how. An encoder can take a picture and
    /// give none back: without hardware (the iOS Simulator has none) H.264
    /// encoders hold about 13 pictures before the first comes out, and a
    /// sender that waits for its picture never gives them that many. A sender
    /// that sees `stalledFor` grow moves on to the next kind.
    public enum Kind: String, Sendable, CaseIterable {
        /// Low-latency rate control: the one made for a live picture.
        case lowLatency
        /// Whatever encoder the system picks, in real time.
        case plain
        /// The system's pick, told after every picture to give back what it holds.
        case prompted
        /// No hardware, told the same.
        case software

        public var next: Kind? {
            switch self {
            case .lowLatency: .plain
            case .plain: .prompted
            case .prompted: .software
            case .software: nil
            }
        }

        /// Where to begin: a simulator has no hardware encoder to try.
        public static var first: Kind {
            #if targetEnvironment(simulator)
            .prompted
            #else
            .lowLatency
            #endif
        }

        /// After each picture, wait for the encoder to give back all it holds.
        /// About 9 ms a picture for the software encoder on a Mac, against
        /// nearly half a second of delay without.
        public var finishesEachPicture: Bool { self == .prompted || self == .software }

        fileprivate var specification: CFDictionary? {
            switch self {
            case .lowLatency: [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true] as CFDictionary
            case .plain, .prompted: nil
            case .software:
                ["EnableHardwareAcceleratedVideoEncoder": false, "RequireHardwareAcceleratedVideoEncoder": false] as CFDictionary
            }
        }
    }

    /// The kind that was made: one later than asked for, if that one couldn't be.
    public private(set) var kind: Kind

    /// `output` is called on VideoToolbox's thread, once per encoded picture.
    public init(width: Int32, height: Int32, fps: Int, bitrate: Int, kind: Kind = .first,
                output: @escaping @Sendable (LiveStreamEncodedFrame) -> Void) throws {
        self.width = width
        self.height = height
        self.output = output
        self.kind = kind
        var created: VTCompressionSession?
        var status: OSStatus = -1
        var trying: Kind? = kind
        while let candidate = trying {
            status = VTCompressionSessionCreate(
                allocator: nil, width: width, height: height, codecType: kCMVideoCodecType_H264,
                encoderSpecification: candidate.specification, imageBufferAttributes: nil, compressedDataAllocator: nil,
                outputCallback: nil, refcon: nil, compressionSessionOut: &created)
            if status == noErr, created != nil {
                self.kind = candidate
                break
            }
            // Not everywhere (older OSes, some Macs): the next kind instead.
            trying = candidate.next
        }
        guard status == noErr, let created else { throw LiveStreamError.refused("No H.264 encoder (\(status))") }
        session = created
        let properties: [CFString: Any] = [
            kVTCompressionPropertyKey_RealTime: true,
            kVTCompressionPropertyKey_AllowFrameReordering: false,
            // Give each picture back before taking the next. Hardware encoders
            // do anyway; the Simulator's hold a picture until they are given
            // more, which a sender that waits for its picture never does.
            kVTCompressionPropertyKey_MaxFrameDelayCount: 0,
            kVTCompressionPropertyKey_ProfileLevel: kVTProfileLevel_H264_High_AutoLevel,
            kVTCompressionPropertyKey_ExpectedFrameRate: fps,
            kVTCompressionPropertyKey_AverageBitRate: bitrate,
            kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: 4,
        ]
        for (key, value) in properties { VTSessionSetProperty(created, key: key, value: value as CFTypeRef) }
        VTCompressionSessionPrepareToEncodeFrames(created)
    }

    deinit { invalidate() }

    /// Pictures handed to the encoder and not yet out.
    public var pending: Int { lock.withLock { inFlight } }

    /// The sender skips a capture rather than queue more than this many. Not
    /// one: an encoder that holds a picture until it is given the next would
    /// never give any back.
    public static let mostPending = 3

    /// Too many pictures are in it already: skip this capture.
    public var isBehind: Bool { pending >= Self.mostPending }

    /// Pictures the encoder turned away or couldn't encode.
    public var failures: Int { lock.withLock { failed } }

    /// Pictures it has given back.
    public var outputs: Int { lock.withLock { produced } }

    /// How long it has held a picture without giving one back; 0 when it holds none.
    public var stalledFor: TimeInterval {
        lock.withLock { waitingSince.map { CACurrentMediaTime() - $0 } ?? 0 }
    }

    public func encode(_ buffer: CVPixelBuffer, micros: UInt64, keyframe: Bool) {
        guard let session else { return }
        lock.withLock {
            inFlight += 1
            if waitingSince == nil { waitingSince = CACurrentMediaTime() }
        }
        let options = keyframe ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        let status = VTCompressionSessionEncodeFrame(
            session, imageBuffer: buffer, presentationTimeStamp: CMTime(value: CMTimeValue(micros), timescale: 1_000_000),
            duration: .invalid, frameProperties: options, infoFlagsOut: nil
        ) { [weak self] status, _, sample in
            guard let self else { return }
            self.lock.withLock {
                self.inFlight -= 1
                self.waitingSince = self.inFlight > 0 ? CACurrentMediaTime() : nil
            }
            guard status == noErr, let sample, let frame = Self.frame(from: sample, micros: micros) else {
                self.lock.withLock { self.failed += 1 }
                return
            }
            self.lock.withLock { self.produced += 1 }
            self.output(frame)
        }
        if status != noErr {
            lock.withLock {
                inFlight -= 1
                failed += 1
                if inFlight == 0 { waitingSince = nil }
            }
        } else if kind.finishesEachPicture {
            VTCompressionSessionCompleteFrames(
                session, untilPresentationTimeStamp: CMTime(value: CMTimeValue(micros), timescale: 1_000_000))
        }
    }

    public func invalidate() {
        guard let session else { return }
        self.session = nil
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(session)
    }

    static func frame(from sample: CMSampleBuffer, micros: UInt64) -> LiveStreamEncodedFrame? {
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return nil }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let keyframe = !(attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
        let length = CMBlockBufferGetDataLength(block)
        var avcc = Data(count: length)
        let copied = avcc.withUnsafeMutableBytes { raw in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
        }
        guard copied == kCMBlockBufferNoErr else { return nil }
        var sets: (Data, Data)?
        if keyframe, let format = CMSampleBufferGetFormatDescription(sample) {
            sets = parameterSets(format)
        }
        return LiveStreamEncodedFrame(keyframe: keyframe, presentationMicros: micros, avcc: avcc,
                                      parameterSets: sets.map { (sps: $0.0, pps: $0.1) })
    }

    private static func parameterSets(_ format: CMFormatDescription) -> (Data, Data)? {
        func set(_ index: Int) -> Data? {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format, parameterSetIndex: index, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
                parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr, let pointer else { return nil }
            return Data(bytes: pointer, count: size)
        }
        guard let sps = set(0), let pps = set(1) else { return nil }
        return (sps, pps)
    }
}

// MARK: - Decoding (a viewer's end)

/// Turns received `format` and `video` payloads into sample buffers a
/// display layer (or a decompression session) takes.
public enum LiveStreamVideoFormat {
    public static func description(sps: Data, pps: Data) -> CMVideoFormatDescription? {
        var format: CMVideoFormatDescription?
        let status = sps.withUnsafeBytes { spsBytes in
            pps.withUnsafeBytes { ppsBytes in
                let pointers = [spsBytes.bindMemory(to: UInt8.self).baseAddress!, ppsBytes.bindMemory(to: UInt8.self).baseAddress!]
                let sizes = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: nil, parameterSetCount: 2, parameterSetPointers: pointers,
                    parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &format)
            }
        }
        return status == noErr ? format : nil
    }

    /// The picture's size in pixels.
    public static func dimensions(_ format: CMVideoFormatDescription) -> (width: Int, height: Int) {
        let size = CMVideoFormatDescriptionGetDimensions(format)
        return (Int(size.width), Int(size.height))
    }

    /// A sample buffer marked for immediate display: a live picture is shown
    /// as soon as it's decoded, never scheduled against a clock.
    public static func sample(avcc: Data, micros: UInt64, format: CMVideoFormatDescription) -> CMSampleBuffer? {
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: avcc.count, blockAllocator: nil, customBlockSource: nil,
            offsetToData: 0, dataLength: avcc.count, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block
        ) == kCMBlockBufferNoErr, let block else { return nil }
        let copied = avcc.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: avcc.count)
        }
        guard copied == kCMBlockBufferNoErr else { return nil }
        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: CMTime(value: CMTimeValue(micros), timescale: 1_000_000),
                                        decodeTimeStamp: .invalid)
        var size = avcc.count
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(
            allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 1,
            sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample
        ) == noErr, let sample else { return nil }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let first = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(first, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample
    }
}
