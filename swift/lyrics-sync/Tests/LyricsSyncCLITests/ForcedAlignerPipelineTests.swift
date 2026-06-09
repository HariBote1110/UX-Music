import Testing
@testable import LyricsSyncCLI

@Test func speechAlignerTextOutputIsParsedIntoWordTimings() throws {
    let output = """
    Loading audio: sample.wav
    [0.24 - 0.48] Hello
    [0.48s - 0.72s] world
    [1.20 - 1.44] again
    """

    let words = try ForcedAlignerWordTiming.parseSpeechCLIOutput(output)

    #expect(words.count == 3)
    #expect(words[0].start == 0.24)
    #expect(words[0].end == 0.48)
    #expect(words[0].text == "Hello")
    #expect(words[2].start == 1.20)
    #expect(words[2].text == "again")
}

@Test func forcedAlignerWordsAreMappedBackToOriginalLyricLines() throws {
    let words = [
        ForcedAlignerWordTiming(start: 0.24, end: 0.48, text: "Hello"),
        ForcedAlignerWordTiming(start: 0.48, end: 0.72, text: "world"),
        ForcedAlignerWordTiming(start: 1.20, end: 1.44, text: "This"),
        ForcedAlignerWordTiming(start: 1.44, end: 1.68, text: "is"),
        ForcedAlignerWordTiming(start: 1.68, end: 1.92, text: "fine"),
    ]

    let lines = ForcedAlignerLineMapper.map(
        words: words,
        to: ["Hello world", "[間奏]", "This is fine"]
    )

    #expect(lines.count == 3)
    #expect(lines[0].timestamp == 0.24)
    #expect(lines[0].source == "match")
    #expect(lines[1].source == "interlude")
    #expect(lines[1].timestamp > lines[0].timestamp)
    #expect(lines[1].timestamp < lines[2].timestamp)
    #expect(lines[2].timestamp == 1.20)
    #expect(lines[2].source == "match")
}
