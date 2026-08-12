import XCTest
@testable import UX_Music_TV

/// TDD for `ADTSFrameParser` (see `progress/tvos-relay-reception.md`, Phase 3-3 receiver
/// follow-up): `AVPlayer` was confirmed on real hardware to be unable to play the host's raw
/// chunked ADTS AAC-LC relay stream (`GET /v1/remote/relay`), so `TVRelayStreamPlayer` parses the
/// ADTS elementary stream itself. This parser is a pure incremental byte-stream → frame parser,
/// tested here against a real captured sample of the relay stream (`relay-sample.aac`, ~6s,
/// 256kbps/44.1kHz/stereo AAC-LC).
final class ADTSFrameParserTests: XCTestCase {
    func testFeedingFixtureInOneChunkEmitsManyValidFrames() throws {
        let data = try Self.fixtureData()

        var parser = ADTSFrameParser()
        let frames = parser.feed(data)

        XCTAssertGreaterThan(frames.count, 50, "a ~6s 256kbps AAC stream should contain well over 50 ADTS frames")
        for frame in frames {
            XCTAssertEqual(frame.header.sampleRate, 44100)
            XCTAssertEqual(frame.header.channelCount, 2)
            XCTAssertEqual(frame.header.profile, .lc)
            XCTAssertFalse(frame.payload.isEmpty)
        }
    }

    func testFeedingFixtureByteByByteEmitsTheSameFrameCountAsOneShot() throws {
        let data = try Self.fixtureData()

        var oneShotParser = ADTSFrameParser()
        let oneShotFrames = oneShotParser.feed(data)

        var incrementalParser = ADTSFrameParser()
        var incrementalFrames: [ADTSFrame] = []
        for byte in data {
            incrementalFrames.append(contentsOf: incrementalParser.feed(Data([byte])))
        }

        XCTAssertEqual(incrementalFrames.count, oneShotFrames.count)
        XCTAssertEqual(incrementalFrames.map(\.payload), oneShotFrames.map(\.payload))
    }

    func testFeedingFixtureInArbitraryChunkBoundariesEmitsTheSameFrames() throws {
        let data = try Self.fixtureData()

        var oneShotParser = ADTSFrameParser()
        let oneShotFrames = oneShotParser.feed(data)

        var chunkedParser = ADTSFrameParser()
        var chunkedFrames: [ADTSFrame] = []
        var offset = 0
        let chunkSize = 997 // deliberately not aligned with any frame boundary
        while offset < data.count {
            let end = min(offset + chunkSize, data.count)
            chunkedFrames.append(contentsOf: chunkedParser.feed(data.subdata(in: offset..<end)))
            offset = end
        }

        XCTAssertEqual(chunkedFrames.count, oneShotFrames.count)
        XCTAssertEqual(chunkedFrames.map(\.payload), oneShotFrames.map(\.payload))
    }

    func testGarbageBytesBeforeSyncwordAreSkippedWithoutLosingSubsequentFrames() throws {
        let data = try Self.fixtureData()
        let garbage = Data([0x00, 0x11, 0x22, 0xFF, 0x00]) // includes a lone 0xFF that is not a syncword
        var parser = ADTSFrameParser()

        let frames = parser.feed(garbage + data)

        var reference = ADTSFrameParser()
        let referenceFrames = reference.feed(data)

        XCTAssertEqual(frames.count, referenceFrames.count)
    }

    private static func fixtureData() throws -> Data {
        let bundle = Bundle(for: ADTSFrameParserTests.self)
        guard let url = bundle.url(forResource: "relay-sample", withExtension: "aac") else {
            throw XCTSkip("relay-sample.aac fixture not found in test bundle")
        }
        return try Data(contentsOf: url)
    }
}
