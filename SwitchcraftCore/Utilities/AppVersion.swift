import Foundation

/// A release version such as "1.2.0", or a tag such as "v1.2.0". Missing trailing parts count as zero.
public struct AppVersion: Comparable, Sendable, CustomStringConvertible {
    public let description: String
    private let parts: [Int]

    public init?(_ text: String) {
        let pieces = text.drop(while: { $0 == "v" }).split(separator: ".", omittingEmptySubsequences: false)
        let parts = pieces.compactMap { Int($0) }
        guard !parts.isEmpty, parts.count == pieces.count else { return nil }
        self.parts = parts
        description = parts.map(String.init).joined(separator: ".")
    }

    public static func < (a: AppVersion, b: AppVersion) -> Bool {
        for index in 0..<max(a.parts.count, b.parts.count) where a.part(index) != b.part(index) {
            return a.part(index) < b.part(index)
        }
        return false
    }

    public static func == (a: AppVersion, b: AppVersion) -> Bool { !(a < b) && !(b < a) }

    private func part(_ index: Int) -> Int { index < parts.count ? parts[index] : 0 }
}

/// What Switchcraft reads from GitHub's "latest release" API response.
public struct LatestRelease: Sendable, Equatable {
    public let version: AppVersion
    /// The DMG when the release has one, otherwise the release page.
    public let downloadURL: URL

    public init(gitHubJSON data: Data) throws {
        struct Response: Decodable {
            struct Asset: Decodable {
                let name: String
                let browserDownloadUrl: URL
            }
            let tagName: String
            let htmlUrl: URL
            let assets: [Asset]
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let response = try decoder.decode(Response.self, from: data)
        guard let version = AppVersion(response.tagName) else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Unrecognised release tag \(response.tagName)"))
        }
        self.version = version
        downloadURL = response.assets.first { $0.name.hasSuffix(".dmg") }?.browserDownloadUrl ?? response.htmlUrl
    }
}
