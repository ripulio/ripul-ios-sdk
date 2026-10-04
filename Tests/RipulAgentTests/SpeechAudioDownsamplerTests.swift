import XCTest
import AVFoundation
@testable import RipulAgent

final class SpeechAudioDownsamplerTests: XCTestCase {
    /// A 440 Hz tone at half scale on the first channel; other channels silent.
    private func tone(rate: Double, channels: AVAudioChannelCount, frames: AVAudioFrameCount,
                      phase: inout Double) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for frame in 0..<Int(frames) {
            buffer.floatChannelData![0][frame] = Float(sin(phase)) * 0.5
            for channel in 1..<Int(channels) { buffer.floatChannelData![channel][frame] = 0 }
            phase += 2 * .pi * 440 / rate
        }
        return buffer
    }

    /// Feeds two seconds through in tap-sized buffers, as the microphone does.
    private func convert(rate: Double, channels: AVAudioChannelCount) throws -> [Int16] {
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels)!
        let downsampler = try XCTUnwrap(SpeechAudioDownsampler(input: format))
        var phase = 0.0
        var pcm = Data()
        var remaining = Int(rate * 2)
        while remaining > 0 {
            let frames = min(4096, remaining)
            remaining -= frames
            let buffer = tone(rate: rate, channels: channels, frames: AVAudioFrameCount(frames), phase: &phase)
            pcm.append(try XCTUnwrap(downsampler.convert(buffer)))
        }
        return pcm.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
    }

    private func level(_ samples: [Int16]) -> Double {
        // Skip the converter's first tenth of a second while its filter fills.
        let steady = samples.dropFirst(1600)
        return (steady.reduce(0.0) { $0 + pow(Double($1) / 32768, 2) } / Double(steady.count)).squareRoot()
    }

    /// 48 kHz is what the iPhone microphone delivers. A third of the samples
    /// is a third of the upload.
    func testPhoneMicrophoneRateBecomesSixteenKilohertz() throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        XCTAssertEqual(SpeechAudioDownsampler(input: format)?.sampleRate, 16_000)
        let samples = try convert(rate: 48_000, channels: 1)
        XCTAssertEqual(Double(samples.count), 32_000, accuracy: 400)
        XCTAssertEqual(level(samples), 0.354, accuracy: 0.03, "The tone keeps its level")
    }

    func testOtherMicrophoneFormatsConvertToTheSameRate() throws {
        for rate in [44_100.0, 24_000, 16_000] {
            let samples = try convert(rate: rate, channels: 1)
            XCTAssertEqual(Double(samples.count), 32_000, accuracy: 400, "\(Int(rate)) Hz")
            XCTAssertEqual(level(samples), 0.354, accuracy: 0.03, "\(Int(rate)) Hz")
        }
    }

    /// Raising a rate makes the converter hold back a quarter of a second,
    /// which would be lost from the end of every utterance. A narrowband
    /// headset's 8 kHz is sent as it is, and every sample of it.
    func testNarrowbandHeadsetAudioIsNotUpsampled() throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1)!
        XCTAssertEqual(SpeechAudioDownsampler(input: format)?.sampleRate, 8_000)
        let samples = try convert(rate: 8_000, channels: 1)
        XCTAssertEqual(samples.count, 16_000)
        XCTAssertEqual(level(samples), 0.354, accuracy: 0.03)
    }

    /// The first channel only, as before: mixing in a silent second channel
    /// would halve the level and push quiet speech under the voiced threshold.
    func testStereoInputKeepsTheFirstChannel() throws {
        let samples = try convert(rate: 48_000, channels: 2)
        XCTAssertEqual(Double(samples.count), 32_000, accuracy: 400)
        XCTAssertEqual(level(samples), 0.354, accuracy: 0.03)
    }
}
