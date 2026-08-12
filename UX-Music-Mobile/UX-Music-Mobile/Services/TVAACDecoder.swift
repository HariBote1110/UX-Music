import AVFoundation
import Foundation

enum TVAACDecoderError: Error {
    case unsupportedFormat
    case converterCreationFailed
    case conversionFailed(Error?)
}

/// Decodes ADTS AAC-LC frames (as emitted by `ADTSFrameParser`) to interleaved PCM Float32 via
/// `AVAudioConverter`, used by `TVRelayStreamPlayer` in place of `AVPlayer` — see
/// `progress/tvos-relay-reception.md` for why `AVPlayer` cannot play the host's raw chunked ADTS
/// relay stream. One decoder instance is built for a stream's sample rate/channel count (which is
/// constant for the lifetime of a relay session) and then fed frames one at a time.
final class TVAACDecoder {
    let sampleRate: Double
    let channelCount: AVAudioChannelCount
    /// PCM frames (samples per channel) per ADTS frame — 1024 for AAC-LC, constant per stream.
    private static let framesPerAACPacket: UInt32 = 1024

    private let converter: AVAudioConverter
    private let sourceFormat: AVAudioFormat
    let outputFormat: AVAudioFormat

    init(header: ADTSFrameHeader) throws {
        guard header.profile == .lc else { throw TVAACDecoderError.unsupportedFormat }
        sampleRate = Double(header.sampleRate)
        channelCount = AVAudioChannelCount(header.channelCount)

        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: Self.framesPerAACPacket,
            mBytesPerFrame: 0,
            mChannelsPerFrame: channelCount,
            mBitsPerChannel: 0,
            mReserved: 0
        )
        guard let sourceFormat = AVAudioFormat(streamDescription: &asbd) else {
            throw TVAACDecoderError.unsupportedFormat
        }
        self.sourceFormat = sourceFormat

        // Non-interleaved: `AVAudioEngine`'s internal graph (`AVAudioEngine.connect(_:to:format:)`)
        // requires the engine's canonical non-interleaved format — connecting with an interleaved
        // format throws `kAudioUnitErr_FormatNotSupported` (-10868), confirmed when wiring this up
        // against the sim E2E harness (see `progress/tvos-relay-reception.md`).
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channelCount,
            interleaved: false
        ) else {
            throw TVAACDecoderError.unsupportedFormat
        }
        self.outputFormat = outputFormat

        guard let converter = AVAudioConverter(from: sourceFormat, to: outputFormat) else {
            throw TVAACDecoderError.converterCreationFailed
        }
        self.converter = converter
    }

    /// Decodes one ADTS frame's payload to interleaved PCM Float32 samples (all channels
    /// flattened into one array, `frameCount * channelCount` samples long).
    func decode(_ frame: ADTSFrame) throws -> [Float] {
        let compressedBuffer = AVAudioCompressedBuffer(
            format: sourceFormat,
            packetCapacity: 1,
            maximumPacketSize: frame.payload.count
        )
        frame.payload.withUnsafeBytes { raw in
            compressedBuffer.data.copyMemory(from: raw.baseAddress!, byteCount: frame.payload.count)
        }
        compressedBuffer.packetCount = 1
        compressedBuffer.byteLength = UInt32(frame.payload.count)
        compressedBuffer.packetDescriptions?[0] = AudioStreamPacketDescription(
            mStartOffset: 0,
            mVariableFramesInPacket: 0,
            mDataByteSize: UInt32(frame.payload.count)
        )

        guard let pcmBuffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: Self.framesPerAACPacket
        ) else {
            throw TVAACDecoderError.conversionFailed(nil)
        }

        var suppliedAlready = false
        var conversionError: NSError?
        let status = converter.convert(to: pcmBuffer, error: &conversionError) { _, outStatus in
            if suppliedAlready {
                outStatus.pointee = .noDataNow
                return nil
            }
            suppliedAlready = true
            outStatus.pointee = .haveData
            return compressedBuffer
        }

        guard status != .error else {
            throw TVAACDecoderError.conversionFailed(conversionError)
        }

        guard let channelData = pcmBuffer.floatChannelData else { return [] }
        let frameLength = Int(pcmBuffer.frameLength)
        guard frameLength > 0 else { return [] }

        var interleaved = [Float](repeating: 0, count: frameLength * Int(channelCount))
        for frameIndex in 0..<frameLength {
            for channel in 0..<Int(channelCount) {
                interleaved[frameIndex * Int(channelCount) + channel] = channelData[channel][frameIndex]
            }
        }
        return interleaved
    }
}
