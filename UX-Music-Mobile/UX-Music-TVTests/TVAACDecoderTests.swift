import XCTest
@testable import UX_Music_TV

/// TDD for `TVAACDecoder` (see `progress/tvos-relay-reception.md`): decodes ADTS AAC-LC frames
/// (as parsed by `ADTSFrameParser`) to interleaved PCM Float32 via `AVAudioConverter`. Verified
/// against the real captured relay sample so a regression that silently produces silence (rather
/// than throwing) is still caught.
final class TVAACDecoderTests: XCTestCase {
    func testDecodingFixtureFramesProducesNonSilentPlausiblePCM() throws {
        let frames = try Self.fixtureFrames()
        XCTAssertGreaterThan(frames.count, 50)

        let decoder = try TVAACDecoder(header: frames[0].header)

        var allSamples: [Float] = []
        for frame in frames {
            let pcm = try decoder.decode(frame)
            allSamples.append(contentsOf: pcm)
        }

        XCTAssertGreaterThan(allSamples.count, 44100, "should have decoded well over one second of audio")

        let sumSquares = allSamples.reduce(Double(0)) { $0 + Double($1) * Double($1) }
        let rms = (sumSquares / Double(allSamples.count)).squareRoot()

        // A real music sample should decode to a plausible non-silent RMS. Silence (a decode bug
        // that returns zeroed buffers without erroring) would read as ~0.0.
        XCTAssertGreaterThan(rms, 0.01, "decoded PCM RMS is implausibly close to silence: \(rms)")
        XCTAssertLessThan(rms, 1.0, "decoded PCM RMS exceeds full scale, suggesting corrupt decode: \(rms)")
    }

    private static func fixtureFrames() throws -> [ADTSFrame] {
        let bundle = Bundle(for: TVAACDecoderTests.self)
        guard let url = bundle.url(forResource: "relay-sample", withExtension: "aac") else {
            throw XCTSkip("relay-sample.aac fixture not found in test bundle")
        }
        let data = try Data(contentsOf: url)
        var parser = ADTSFrameParser()
        return parser.feed(data)
    }
}
