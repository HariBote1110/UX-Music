import XCTest

/// Guards against a regression of the watchOS background-audio bug: Xcode's generated-Info.plist
/// machinery does NOT honour `INFOPLIST_KEY_WKBackgroundModes` (verified by dumping the built
/// product's Info.plist — the key never made it in), so watchOS suspended audio as soon as the app
/// backgrounded. The fix is a source `Info.plist` for the watch target (merged in via
/// `INFOPLIST_FILE`, since `GENERATE_INFOPLIST_FILE = YES` merges generated keys with a source file)
/// that declares `WKBackgroundModes` directly. This test parses the source files under `SRCROOT`
/// rather than a built product, so it also runs from a plain `xcodebuild test` without first building
/// the watch scheme.
final class WatchBackgroundAudioInfoPlistTests: XCTestCase {
    /// Walks up from this test file's own path to the repository's `UX-Music-Mobile` project root.
    private func projectRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.pathComponents.count > 1 {
            url.deleteLastPathComponent()
            if url.lastPathComponent == "UX-Music-Mobile",
               FileManager.default.fileExists(atPath: url.appendingPathComponent("UX-Music-Mobile.xcodeproj").path) {
                return url
            }
        }
        throw XCTSkip("Could not locate the UX-Music-Mobile project root from \(#filePath)")
    }

    func testWatchInfoPlistDeclaresBackgroundAudioMode() throws {
        let root = try projectRoot()
        let plistURL = root.appendingPathComponent("UX-Music-Watch/Info.plist")
        let data = try XCTUnwrap(
            FileManager.default.contents(atPath: plistURL.path),
            "UX-Music-Watch/Info.plist must exist so INFOPLIST_FILE can merge it into the generated plist"
        )
        let plist = try XCTUnwrap(
            try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        )
        let modes = try XCTUnwrap(plist["WKBackgroundModes"] as? [String], "WKBackgroundModes key missing")
        XCTAssertTrue(modes.contains("audio"), "WKBackgroundModes must include \"audio\"")

        // Per Apple's watchOS Keys documentation, `UIBackgroundModes` (not `WKBackgroundModes`) is
        // what actually lets a watch app keep running to play audio after the user stops
        // interacting with it. Without it, playback stops when the app leaves the foreground even
        // though `WKBackgroundModes` and a `.longFormAudio` session activation both look fine.
        let uiModes = try XCTUnwrap(plist["UIBackgroundModes"] as? [String], "UIBackgroundModes key missing")
        XCTAssertTrue(uiModes.contains("audio"), "UIBackgroundModes must include \"audio\"")
    }

    func testWatchBuildConfigsReferenceInfoPlistFile() throws {
        let root = try projectRoot()
        let pbxprojURL = root.appendingPathComponent("UX-Music-Mobile.xcodeproj/project.pbxproj")
        let contents = try String(contentsOf: pbxprojURL, encoding: .utf8)

        // Locate each XCBuildConfiguration block whose PRODUCT_BUNDLE_IDENTIFIER identifies the
        // watch app target, then assert it references the watch target's own Info.plist via
        // INFOPLIST_FILE (and no longer relies on the ineffective INFOPLIST_KEY_WKBackgroundModes).
        let watchIdentifier = "com.uxlabs.uxMusicMobile.watchkitapp\""
        var searchRange = contents.startIndex..<contents.endIndex
        var watchConfigBlocksFound = 0

        while let identifierRange = contents.range(of: watchIdentifier, range: searchRange) {
            guard
                let blockStart = contents.range(of: "buildSettings = {", options: .backwards, range: contents.startIndex..<identifierRange.lowerBound)?.upperBound,
                let blockEnd = contents.range(of: "\n\t\t\t};", range: identifierRange.upperBound..<contents.endIndex)?.lowerBound
            else {
                break
            }
            let block = contents[blockStart..<blockEnd]
            watchConfigBlocksFound += 1

            XCTAssertTrue(
                block.contains("INFOPLIST_FILE = \"UX-Music-Watch/Info.plist\";"),
                "Watch build config must set INFOPLIST_FILE to UX-Music-Watch/Info.plist"
            )
            XCTAssertFalse(
                block.contains("INFOPLIST_KEY_WKBackgroundModes"),
                "INFOPLIST_KEY_WKBackgroundModes is ineffective under GENERATE_INFOPLIST_FILE and should be removed"
            )

            searchRange = blockEnd..<contents.endIndex
        }

        XCTAssertEqual(watchConfigBlocksFound, 2, "Expected exactly 2 watch target build configurations (Debug, Release)")
    }
}
