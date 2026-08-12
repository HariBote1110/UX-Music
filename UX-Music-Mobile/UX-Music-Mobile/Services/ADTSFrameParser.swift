import Foundation

/// The MPEG-4 audio object type carried in an ADTS frame's `profile` field. Only `.lc` is
/// expected from the host's relay encoder (see `progress/tvos-relay-reception.md`), but the other
/// values are decoded for completeness/diagnostics.
enum ADTSAudioProfile: UInt8 {
    case main = 0
    case lc = 1
    case ssr = 2
    case ltp = 3
}

/// A parsed 7- or 9-byte ADTS header (ISO/IEC 13818-7 Annex A), holding just the fields needed to
/// build an `AVAudioCompressedBuffer`/`AudioStreamBasicDescription` for `AVAudioConverter`.
struct ADTSFrameHeader: Equatable {
    let profile: ADTSAudioProfile
    let sampleRate: Int
    let channelCount: Int
    /// Total ADTS frame length in bytes, header included (the 13-bit `aac_frame_length` field).
    let frameLength: Int
    /// Header length in bytes: 7 without CRC, 9 with CRC (`protection_absent == 0`).
    let headerLength: Int

    private static let sampleRatesByIndex: [Int] = [
        96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050,
        16000, 12000, 11025, 8000, 7350
    ]

    /// Parses a 7-byte ADTS fixed+variable header prefix starting at `bytes`'s first element.
    /// Returns `nil` if the syncword doesn't match or the sample-rate index is reserved.
    static func parse(_ bytes: some RandomAccessCollection<UInt8>) -> ADTSFrameHeader? {
        guard bytes.count >= 7 else { return nil }
        let b = Array(bytes.prefix(7))

        // Syncword: 0xFFF (12 bits) — b[0] == 0xFF, top nibble of b[1] == 0xF.
        guard b[0] == 0xFF, (b[1] & 0xF0) == 0xF0 else { return nil }

        let protectionAbsent = b[1] & 0x01
        let profileRaw = (b[2] & 0xC0) >> 6
        let sampleRateIndex = Int((b[2] & 0x3C) >> 2)
        guard sampleRateIndex < sampleRatesByIndex.count else { return nil }
        let channelConfig = ((b[2] & 0x01) << 2) | ((b[3] & 0xC0) >> 6)
        guard channelConfig > 0 else { return nil } // 0 = "defined in PCE", unsupported here

        let frameLength = (Int(b[3] & 0x03) << 11) | (Int(b[4]) << 3) | (Int(b[5] & 0xE0) >> 5)
        let headerLength = protectionAbsent == 1 ? 7 : 9
        guard frameLength >= headerLength else { return nil }

        guard let profile = ADTSAudioProfile(rawValue: profileRaw) else { return nil }

        return ADTSFrameHeader(
            profile: profile,
            sampleRate: sampleRatesByIndex[sampleRateIndex],
            channelCount: Int(channelConfig),
            frameLength: frameLength,
            headerLength: headerLength
        )
    }
}

/// One complete ADTS frame: its parsed header plus the raw AAC payload bytes (header stripped),
/// ready to hand to `AVAudioCompressedBuffer`.
struct ADTSFrame: Equatable {
    let header: ADTSFrameHeader
    let payload: Data
}

/// Pure incremental ADTS byte-stream parser. Feed it arbitrarily-sized chunks (as they arrive off
/// the network) via `feed(_:)`; it buffers partial data internally and returns only the complete
/// frames a chunk completes. Stateless w.r.t. `Foundation`/`AVFoundation` beyond `Data` — no I/O,
/// no threading — so it is fully unit-testable (see `ADTSFrameParserTests`).
struct ADTSFrameParser {
    private var buffer = Data()

    /// Appends `chunk` to the internal buffer and extracts every complete ADTS frame now
    /// available. Any trailing partial frame (or leading garbage before the next syncword) is
    /// retained in the buffer for the next call.
    mutating func feed(_ chunk: Data) -> [ADTSFrame] {
        buffer.append(chunk)

        var frames: [ADTSFrame] = []
        while true {
            // Resynchronise: drop bytes until the buffer starts with a syncword candidate, or
            // until fewer than 2 bytes remain (can't tell yet).
            while buffer.count >= 2 {
                let start = buffer.startIndex
                if buffer[start] == 0xFF, (buffer[buffer.index(after: start)] & 0xF0) == 0xF0 {
                    break
                }
                buffer.removeFirst()
            }

            guard let header = ADTSFrameHeader.parse(buffer) else { break }
            guard buffer.count >= header.frameLength else { break } // wait for more bytes

            let start = buffer.startIndex
            let payloadStart = buffer.index(start, offsetBy: header.headerLength)
            let frameEnd = buffer.index(start, offsetBy: header.frameLength)
            let payload = buffer.subdata(in: payloadStart..<frameEnd)
            frames.append(ADTSFrame(header: header, payload: payload))

            buffer.removeSubrange(start..<frameEnd)
        }
        return frames
    }
}
