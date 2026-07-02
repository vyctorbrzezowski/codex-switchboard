import XCTest

final class AuthRefreshGuardTests: XCTestCase {
    func testSwitchboardNeverUsesRefreshTokenGrant() throws {
        let files = try productionTextFiles()

        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            let compact = text
                .lowercased()
                .replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)

            for snippet in forbiddenRefreshGrantSnippets {
                XCTAssertFalse(compact.contains(snippet), "\(file.path) must not spend refresh tokens")
            }

            for identifier in forbiddenRefreshGrantIdentifiers {
                XCTAssertFalse(text.contains(identifier), "\(file.path) must not define refresh-token grant flow")
            }

            for line in text.components(separatedBy: .newlines)
            where line.contains("grant_type") {
                XCTAssertTrue(
                    line.contains("authorization_code"),
                    "\(file.path) uses a non-login OAuth grant: \(line)"
                )
            }
        }
    }

    private var forbiddenRefreshGrantSnippets: [String] {
        [
            #""grant_type","refresh_token""#,
            #""grant_type":"refresh_token""#,
            #"grant_type=refresh_token"#,
            #"grant_type%3drefresh_token"#,
            #"grant_type\",value:\"refresh_token"#,
        ]
    }

    private var forbiddenRefreshGrantIdentifiers: [String] {
        [
            "refreshAccessToken",
            "refreshTokens",
            "RefreshedTokenResponse",
            "automaticTokenRefreshEnabled",
            "tokenRefreshFailedUsage",
        ]
    }

    private func productionTextFiles() throws -> [URL] {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let directories = [
            root.appendingPathComponent("Sources", isDirectory: true),
            root.appendingPathComponent("scripts", isDirectory: true),
        ]
        let roots = directories + [
            root.appendingPathComponent("build-app.sh"),
            root.appendingPathComponent("build-pkg.sh"),
        ]
        var files: [URL] = []

        for url in roots {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                files += FileManager.default.enumerator(
                    at: url,
                    includingPropertiesForKeys: [.isRegularFileKey]
                )?.compactMap { item -> URL? in
                    guard let url = item as? URL,
                          Self.productionExtensions.contains(url.pathExtension),
                          (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                        return nil
                    }
                    return url
                } ?? []
            } else if FileManager.default.fileExists(atPath: url.path) {
                files.append(url)
            }
        }

        return files
    }

    private static let productionExtensions: Set<String> = ["swift", "mjs", "js", "sh"]
}
