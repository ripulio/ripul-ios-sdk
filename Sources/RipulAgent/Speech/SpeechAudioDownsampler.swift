import AVFoundation

/// Converts microphone buffers to the 16 kHz mono PCM16 that Scribe works at.
///
/// The tap delivers the hardware rate, 48 kHz on an iPhone, and ElevenLabs
/// takes audio as base64 text. Sent unconverted that is about 1 Mbit/s of
/// upload, and 8 Mbit/s while a reconnect replays its backlog. On a weak
/// uplink the upload fell behind speech: a replay ran at real-time speed
/// instead of eight times it, and Send waited up to seven seconds for audio
/// that had not left the phone. 16 kHz is a third of the bytes and loses
/// nothing the recogniser uses.
///
/// Confined to the tap that owns it: the converter carries its filter state
/// from one buffer to the next and is not safe to share.
final class SpeechAudioDownsampler: @unchecked Sendable {
    /// The rate of the audio `convert` returns, for `audio_format=pcm_<rate>`.
    let sampleRate: Int

    private let converter: AVAudioConverter
    private let output: AVAudioFormat
    private let ratio: Double

    init?(input: AVAudioFormat) {
        // A narrowband Bluetooth headset records at 8 kHz, which ElevenLabs
        // takes as it is. Raising it to 16 kHz adds nothing, and the converter
        // holds back a quarter of a second when it raises a rate, which would
        // be cut off the end of every utterance.
        let rate = input.sampleRate == 8_000 ? 8_000 : 16_000
        guard input.sampleRate > 0,
              let output = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(rate),
                                         channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: input, to: output) else { return nil }
        // The first channel only, as before the conversion existed.
        if input.channelCount > 1 { converter.channelMap = [0] }
        self.converter = converter
        self.output = output
        sampleRate = rate
        ratio = Double(rate) / input.sampleRate
    }

    /// Little-endian PCM16 for one tap buffer. Nil when conversion failed;
    /// empty while the converter is still priming.
    func convert(_ buffer: AVAudioPCMBuffer) -> Data? {
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
        guard let converted = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else { return nil }
        var supplied = false
        var failure: NSError?
        let status = converter.convert(to: converted, error: &failure) { _, state in
            if supplied {
                state.pointee = .noDataNow
                return nil
            }
            supplied = true
            state.pointee = .haveData
            return buffer
        }
        guard status != .error, failure == nil, let samples = converted.int16ChannelData?[0] else { return nil }
        return Data(bytes: samples, count: Int(converted.frameLength) * 2)
    }
}
