import Foundation
import Testing
@testable import SwitchcraftCore

struct UpdateTests {
    @Test(arguments: [
        ("1.0.1", "1.0.0"), ("1.1.0", "1.0.9"), ("2.0.0", "1.9.9"), ("1.10.0", "1.9.0"),
        ("v1.0.1", "1.0.0"), ("1.0.0.1", "1.0"),
    ])
    func newerVersionsCompareGreater(newer: String, older: String) throws {
        let a = try #require(AppVersion(newer)), b = try #require(AppVersion(older))
        #expect(a > b)
        #expect(!(b > a))
    }

    @Test func trailingZerosAreTheSameVersion() {
        #expect(AppVersion("v1.0") == AppVersion("1.0.0"))
    }

    @Test(arguments: ["", "v", "1..0", "1.0-beta", "latest"])
    func rejectsTextThatIsNotAVersion(text: String) {
        #expect(AppVersion(text) == nil)
    }

    @Test func readsTheDMGFromGitHubsLatestRelease() throws {
        let json = """
        {"tag_name": "v1.2.0", "html_url": "https://github.com/o/r/releases/tag/v1.2.0", "draft": false,
         "assets": [{"name": "notes.txt", "browser_download_url": "https://example.com/notes.txt"},
                    {"name": "Switchcraft.dmg", "browser_download_url": "https://example.com/Switchcraft.dmg"}]}
        """
        let release = try LatestRelease(gitHubJSON: Data(json.utf8))
        #expect(release.version == AppVersion("1.2.0"))
        #expect(release.downloadURL.absoluteString == "https://example.com/Switchcraft.dmg")
    }

    @Test func fallsBackToTheReleasePageWithoutADMG() throws {
        let json = #"{"tag_name": "v1.2.0", "html_url": "https://github.com/o/r/releases/tag/v1.2.0", "assets": []}"#
        let release = try LatestRelease(gitHubJSON: Data(json.utf8))
        #expect(release.downloadURL.absoluteString == "https://github.com/o/r/releases/tag/v1.2.0")
    }

    @Test func rejectsATagThatIsNotAVersion() {
        let json = #"{"tag_name": "nightly", "html_url": "https://github.com/o/r", "assets": []}"#
        #expect(throws: DecodingError.self) { try LatestRelease(gitHubJSON: Data(json.utf8)) }
    }
}
